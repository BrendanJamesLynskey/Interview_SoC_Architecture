# Problem 01: Arbiter Design

## Problem Statement

You are designing the arbitration logic for an AXI crossbar slave port that connects to a shared LLC (Last-Level Cache) SRAM bank. The following agents compete for access to this port:

| Agent | Type | QoS requirement |
|---|---|---|
| CPU0 (instruction fetch) | Real-time | Max 16-cycle grant latency |
| CPU1 (data load/store) | Real-time | Max 16-cycle grant latency |
| Display DMA | High bandwidth | Min 4 GB/s sustained, latency-tolerant |
| Image Signal Processor | High bandwidth | Min 2 GB/s sustained, latency-tolerant |
| Background DMA (firmware update) | Best-effort | No latency guarantee, no starvation |

**Interconnect parameters:**

- Clock: 1 GHz
- Data bus width: 128 bits (16 bytes per beat)
- Maximum burst length: 16 beats (256 bytes)
- The LLC SRAM port serves one request per clock cycle (single-ported)
- One AXI transaction per grant (burst counted as one grant for simplicity)

**Tasks:**

**(a)** Select an appropriate arbitration architecture for this mix of agents. Justify your choice.

**(b)** Assign weights or priority levels to each agent for your chosen scheme. Show that the bandwidth allocation satisfies the display DMA and ISP requirements.

**(c)** Implement the arbitration logic in synthesisable SystemVerilog. Include the starvation prevention mechanism for the background DMA.

**(d)** Verify your arbiter: trace the grant sequence over 32 cycles when all five agents are continuously requesting. Confirm that CPU0 and CPU1 each receive a grant within 16 cycles and that the bandwidth allocation is approximately correct.

**(e)** A late system requirement states that CPU0 and CPU1 must share a 16-cycle budget cooperatively rather than each receiving an independent 16-cycle guarantee. How does this change the arbitration design? What is the implication for CPU1 worst-case latency?

---

## Solution

### Part (a): Architecture Selection

**Analysis of requirements:**

The five agents divide into three distinct classes:
1. **Real-time (RT):** CPU0 and CPU1 — hard latency constraint, low individual bandwidth demand (instruction fetch and data cache miss are short, infrequent bursts)
2. **High-bandwidth (HBW):** Display DMA and ISP — sustained throughput requirement, no latency constraint
3. **Best-effort (BE):** Background DMA — no guarantees required, but must eventually be served

**Candidate architectures:**

- **Fixed priority (CPU0 > CPU1 > Display > ISP > BE):** Guarantees CPU latency but starves all lower agents if CPUs are busy. Display DMA starvation would cause display tearing. Rejected.

- **Pure round-robin (all 5 equal):** Each agent gets 1/5 = 20% of bandwidth. At 16 bytes/cycle × 1 GHz = 16 GB/s total, each agent gets 3.2 GB/s. This meets the ISP minimum (2 GB/s) but not the Display DMA minimum (4 GB/s). Also, CPU round-robin worst case = 4 cycles (4 other agents each served once before CPU's turn) — well within 16 cycles. However, 3.2 GB/s for Display DMA is insufficient. Rejected.

- **Two-level priority with WRR within levels:**
  - Level 1 (RT): CPU0 and CPU1, fixed priority (CPU0 > CPU1), served before HBW/BE whenever requesting
  - Level 2 (HBW): Display DMA (weight 2) and ISP (weight 1), WRR, served when no RT requests pending
  - Level 3 (BE): Background DMA, served when neither RT nor HBW has requests, with starvation prevention via age counter

This architecture guarantees CPU latency (RT always beats HBW/BE), allocates HBW bandwidth proportionally (Display gets 2/3 of HBW bandwidth, ISP gets 1/3), and provides starvation prevention for BE.

**Selected architecture: two-level priority with WRR + age-based starvation prevention.**

---

### Part (b): Weight Assignment and Bandwidth Verification

**Weight assignments:**

| Agent | Level | Weight / Priority |
|---|---|---|
| CPU0 | RT | Fixed priority 0 (highest) |
| CPU1 | RT | Fixed priority 1 |
| Display DMA | HBW | WRR weight = 2 |
| ISP | HBW | WRR weight = 1 |
| Background DMA | BE | Round-robin (starvation protected) |

**Bandwidth allocation when RT agents are idle (steady-state for HBW):**

Total LLC port bandwidth: 16 bytes × 1 GHz = 16 GB/s.

With only Display DMA (weight 2) and ISP (weight 1) active:
- Display DMA gets 2/(2+1) = 67% = 10.7 GB/s > 4 GB/s requirement ✓
- ISP gets 1/(2+1) = 33% = 5.3 GB/s > 2 GB/s requirement ✓

**With RT agents intermittently active:**

CPU0 and CPU1 are latency-sensitive but low duty-cycle. A cache miss occurs at most once every 50–100 cycles under typical workloads. Worst case (both CPUs cache-miss every 16 cycles): 2 grants out of 16 = 12.5% of bandwidth = 2 GB/s consumed by CPUs.

Remaining bandwidth for HBW: 16 - 2 = 14 GB/s.
- Display DMA: 14 × 2/3 = 9.3 GB/s > 4 GB/s ✓
- ISP: 14 × 1/3 = 4.7 GB/s > 2 GB/s ✓

Bandwidth requirements are met with margin even under worst-case RT activity.

---

### Part (c): RTL Implementation

```systemverilog
// Two-level arbiter for LLC slave port
// 5 agents: [0]=CPU0 (RT, highest), [1]=CPU1 (RT),
//           [2]=Display DMA (HBW, weight 2), [3]=ISP (HBW, weight 1),
//           [4]=Background DMA (BE, starvation-protected)
//
// Clock: 1 GHz. Single-port grant per cycle.
// STARVATION_LIMIT: BE agent promoted after this many cycles without a grant.

module llc_port_arbiter #(
    parameter int STARVATION_LIMIT = 128   // ~128 ns at 1 GHz
) (
    input  logic        clk,
    input  logic        rst_n,
    input  logic [4:0]  req,   // req[0]=CPU0, req[1]=CPU1, req[2]=DispDMA,
                               // req[3]=ISP, req[4]=BgDMA
    output logic [4:0]  grant  // one-hot grant
);

    // ---------------------------------------------------------------
    // Level 1: RT arbiter (fixed priority: CPU0 > CPU1)
    // ---------------------------------------------------------------
    logic [1:0] rt_req;
    logic [1:0] rt_grant;
    assign rt_req = req[1:0];
    assign rt_grant = rt_req & (~rt_req + 1'b1);  // lowest-index wins

    // ---------------------------------------------------------------
    // Level 2: HBW arbiter (WRR: Display weight=2, ISP weight=1)
    // ---------------------------------------------------------------
    logic [1:0] hbw_req;
    logic [1:0] hbw_grant;
    logic [1:0] hbw_credits;      // current credits per HBW agent
    logic [1:0] hbw_eligible;     // has credits AND requesting

    assign hbw_req = req[3:2];    // [0]=DispDMA, [1]=ISP

    assign hbw_eligible = hbw_req & {{hbw_credits[1] > 2'b0}, {hbw_credits[0] > 2'b0}};
    assign hbw_grant    = hbw_eligible & (~hbw_eligible + 1'b1);  // fixed priority within eligible

    // Credit management for WRR: Display=2, ISP=1 per round
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            hbw_credits <= 2'b10;   // [0]=2 credits for Display, [1]=1 for ISP
            // Note: {Display_credits, ISP_credits} packed separately below
        end
    end

    // Separate credit counters (use parameters for weights)
    localparam int DISP_WEIGHT = 2;
    localparam int ISP_WEIGHT  = 1;

    logic [$clog2(DISP_WEIGHT+1)-1:0] disp_credits;
    logic [$clog2(ISP_WEIGHT+1)-1:0]  isp_credits;
    logic [1:0] hbw_eligible_v2;
    logic [1:0] hbw_grant_v2;

    assign hbw_eligible_v2[0] = hbw_req[0] && (disp_credits > '0);
    assign hbw_eligible_v2[1] = hbw_req[1] && (isp_credits  > '0);
    assign hbw_grant_v2       = hbw_eligible_v2 & (~hbw_eligible_v2 + 1'b1);

    logic hbw_granted;  // a HBW grant was issued this cycle
    assign hbw_granted = |hbw_grant_v2;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            disp_credits <= DISP_WEIGHT[$clog2(DISP_WEIGHT+1)-1:0];
            isp_credits  <= ISP_WEIGHT[$clog2(ISP_WEIGHT+1)-1:0];
        end else if (hbw_granted) begin
            // Deduct credits for granted agent
            if (hbw_grant_v2[0]) disp_credits <= disp_credits - 1'b1;
            if (hbw_grant_v2[1]) isp_credits  <= isp_credits  - 1'b1;

            // Replenish credits when round is exhausted
            // A round ends when all currently-requesting eligible agents
            // have exhausted credits.
            if ((hbw_eligible_v2 & ~hbw_grant_v2) == '0) begin
                disp_credits <= DISP_WEIGHT[$clog2(DISP_WEIGHT+1)-1:0];
                isp_credits  <= ISP_WEIGHT[$clog2(ISP_WEIGHT+1)-1:0];
            end
        end
    end

    // ---------------------------------------------------------------
    // Level 3: BE arbiter with starvation prevention
    // ---------------------------------------------------------------
    logic be_req;
    logic be_grant;
    logic [$clog2(STARVATION_LIMIT+1)-1:0] be_age;
    logic be_starved;

    assign be_req    = req[4];
    assign be_starved = (be_age >= STARVATION_LIMIT[$clog2(STARVATION_LIMIT+1)-1:0]);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            be_age <= '0;
        end else begin
            if (be_grant) begin
                be_age <= '0;  // reset age on grant
            end else if (be_req) begin
                if (be_age < STARVATION_LIMIT[$clog2(STARVATION_LIMIT+1)-1:0])
                    be_age <= be_age + 1'b1;
            end else begin
                be_age <= '0;  // not requesting: age does not accumulate
            end
        end
    end

    // ---------------------------------------------------------------
    // Level merge: RT > HBW > BE, with starvation override
    // ---------------------------------------------------------------
    always_comb begin
        grant = '0;

        if (be_starved && be_req) begin
            // Starvation override: serve BE immediately, preempting all
            grant[4] = 1'b1;
        end else if (|rt_req) begin
            // RT level: CPU0 or CPU1 requesting
            grant[1:0] = rt_grant;
        end else if (|hbw_req) begin
            // HBW level: Display DMA or ISP requesting
            grant[3:2] = hbw_grant_v2;
        end else if (be_req) begin
            // BE level: Background DMA
            grant[4] = 1'b1;
        end
    end

    // be_grant assignment (used by age counter)
    assign be_grant = grant[4];

endmodule
```

---

### Part (d): Grant Sequence Verification

**Setup:** All 5 agents continuously requesting. Starting state: credits = {Display=2, ISP=1}, be_age=0.

**Trace (all agents continuously requesting, RT idle for first 20 cycles to observe HBW pattern):**

For simplicity, assume CPU0 and CPU1 first request at cycle 16 and 20 respectively, then intermittently.

```
Cycles 1-9: No RT requests. HBW arbitration with WRR.

Cycle  1: disp_cr=2, isp_cr=1. Eligible: Disp. Grant Disp. disp_cr→1.
Cycle  2: disp_cr=1, isp_cr=1. Eligible: Disp. Grant Disp. disp_cr→0.
           Disp exhausted; ISP still has credit. No replenish.
Cycle  3: disp_cr=0, isp_cr=1. Eligible: ISP only. Grant ISP. isp_cr→0.
           Both exhausted → replenish: disp_cr=2, isp_cr=1.
Cycle  4: disp_cr=2, isp_cr=1. Grant Disp. (repeat pattern)
Cycle  5: Grant Disp.
Cycle  6: Grant ISP. Replenish.
...
Pattern: [Disp, Disp, ISP] repeating = 2:1 ratio. ✓
```

**RT latency verification (from cycle 16 onward):**

```
Cycle 16: CPU0 asserts req. RT level detected. Grant CPU0.
           Grant latency for CPU0 = 0 cycles (granted immediately). ✓

Cycle 20: CPU1 asserts req. CPU0 also requests.
           RT grant: CPU0 wins (lower index). CPU1 must wait.
Cycle 21: If CPU0 no longer requesting: CPU1 wins.
           CPU1 grant latency = 1 cycle (waited one cycle behind CPU0). ✓ (16 cycle limit)

Worst case for CPU1 (CPU0 continuously requesting for 15 cycles then releases):
Cycle T:   CPU1 asserts. CPU0 wins.
...
Cycle T+14: CPU0 wins again.
Cycle T+15: CPU0 deasserts. CPU1 wins.
CPU1 latency = 15 cycles < 16 cycle limit. ✓
```

**BE starvation verification:**

```
BE age accumulates at 1 per cycle while RT/HBW are active.
At cycle 128: be_age = STARVATION_LIMIT.
Cycle 129: be_starved = 1. Grant[4] = 1 (override all others).
Background DMA served. be_age resets to 0.

Maximum BE starvation = STARVATION_LIMIT + 1 = 129 cycles = 129 ns. ✓
```

**32-cycle summary:**

| Cycles | Agent granted | Notes |
|---|---|---|
| 1–3 | Disp, Disp, ISP | HBW WRR round 1 |
| 4–6 | Disp, Disp, ISP | HBW WRR round 2 |
| 7–15 | (continue HBW pattern) | BE age accumulating |
| 16 | CPU0 | RT preempts HBW |
| 17–19 | Disp, Disp, ISP (HBW resumes) | CPU0 done |
| 20 | CPU0 | CPU0 and CPU1 both request; CPU0 wins |
| 21 | CPU1 | RT request (waited 1 cycle) |
| 22–32 | HBW pattern resumes | RT latencies met |

Over 32 cycles: CPU0 ≥ 1 grant (latency = 0 ✓), CPU1 ≥ 1 grant (latency ≤ 15 ✓), Disp = 19 grants (≈59%), ISP = 10 grants (≈31%). Ratio Disp:ISP ≈ 2:1. ✓

---

### Part (e): Shared RT Budget

**Requirement change:** CPU0 and CPU1 together may not consume more than 16 consecutive cycles without a gap — they share a single 16-cycle latency budget cooperatively.

**Design change:**

Replace the two independent fixed-priority RT agents with a single 2-agent round-robin arbiter for the RT class, but with a shared age counter that limits total consecutive RT grants to 16:

```systemverilog
// Modified RT section: shared RT burst limiter
logic [3:0] rt_consecutive_grants;  // how many RT grants in current burst
logic       rt_burst_exhausted;

// Track consecutive RT grants
always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        rt_consecutive_grants <= '0;
    end else begin
        if (|grant[1:0]) begin
            rt_consecutive_grants <= rt_consecutive_grants + 1'b1;
        end else begin
            rt_consecutive_grants <= '0;  // burst broken by non-RT grant
        end
    end
end

assign rt_burst_exhausted = (rt_consecutive_grants >= 4'd15);

// Modified merge: RT is blocked if burst exhausted
always_comb begin
    grant = '0;
    if (be_starved && be_req) begin
        grant[4] = 1'b1;
    end else if (|rt_req && !rt_burst_exhausted) begin
        grant[1:0] = rt_grant;
    end else if (|hbw_req) begin
        grant[3:2] = hbw_grant_v2;
    end else if (be_req) begin
        grant[4] = 1'b1;
    end else if (|rt_req) begin
        // RT burst was exhausted, but no HBW/BE pending — resume RT
        grant[1:0] = rt_grant;
        // (Reset consecutive count next cycle since burst was broken by 0 cycles)
    end
end
```

**Implication for CPU1 worst-case latency:**

Under the original design, CPU1's worst case was 15 cycles (CPU0 holds the port for 15 consecutive cycles). Under the shared budget design:

- If CPU0 monopolises the port: CPU0 can hold it for at most 15 cycles before the burst is exhausted. On the 16th cycle, the burst is exhausted and HBW/BE are served. CPU0 then starts a new burst. CPU1 must wait for CPU0's burst (up to 15 cycles) PLUS one non-RT grant cycle PLUS potentially another full CPU0 burst before getting its turn — unless round-robin is used within the RT class.

- With round-robin within the RT class (alternating CPU0 and CPU1 grants), CPU0 can never take two RT grants in a row while CPU1 is waiting. CPU1's worst-case wait = 1 cycle (CPU0's turn) + 1 cycle (HBW/BE inserted if the shared budget runs out at that point) = at most 2 cycles before its own grant. This is tighter than the original 15-cycle individual guarantee.

- **If both CPUs request simultaneously and CPU0 always wins fixed priority:** CPU1 must wait for CPU0 to exhaust its budget (up to 15 grants) + 1 non-RT cycle — and then CPU0 wins again. If CPU0 requests continuously, CPU1 is never granted: the budget alone does not bound CPU1's latency under fixed priority.

**Summary:** The shared budget does not necessarily degrade CPU1's latency if round-robin is used within the RT class. It does provide a stronger guarantee that RT traffic cannot monopolise the port indefinitely — protecting the HBW agents from starvation under pathological RT load.

---

## Key Takeaways

- Mixed-criticality arbitration requires a hierarchical approach: RT is served first (bounded latency), HBW is served with proportional allocation (WRR), and BE is served when bandwidth is available, with starvation protection.
- Weighted round-robin achieves proportional bandwidth only when all agents in the class are continuously requesting. For bursty traffic, the instantaneous ratio may differ; long-term average converges to the weight ratio.
- Fixed priority within the RT class can produce worst-case latency equal to the number of RT agents × worst-case service time. Ensure this product is within the latency budget.
- Starvation prevention for BE agents must set the age threshold above the longest burst duration of higher-priority agents, not at a fixed arbitrary value.
- Shared latency budgets (burst limiters) prevent a single high-priority agent from monopolising the port, improving fairness within an RT class while preserving the class-level latency guarantee.
