# Arbitration Schemes

## Overview

Arbitration is the process by which a shared resource — a bus, a memory port, a crossbar slave port, or a NoC router output — is allocated to one of multiple competing requesters. The choice of arbitration scheme directly determines the latency distribution, throughput fairness, and worst-case response time seen by each agent in the system.

Arbitration is not a theoretical nicety: in a real SoC, a poorly chosen arbitration scheme causes CPU stalls from display DMA monopolising DRAM, causes audio dropouts when large burst transfers win every arbitration cycle, or causes unpredictable latency that prevents real-time deadline satisfaction. Understanding arbitration is therefore central to both RTL design and system architecture.

This document covers fixed priority, round-robin, weighted round-robin, age-based, and least-recently-used arbitration. For each scheme: how it works, how to implement it in RTL, its fairness and starvation properties, and when to use it in a SoC context.

---

## Tier 1: Fundamentals

### Q1. What are the three fundamental properties a good arbitration scheme must satisfy?

**Answer:**

**1. Liveness (no starvation):**

Every requester that continuously asserts its request must eventually be granted. A scheme that can permanently deny a lower-priority requester violates liveness. Fixed priority arbitration violates liveness: if high-priority requesters are always present, low-priority requesters never win.

**2. Bounded latency:**

The maximum time between a request being asserted and the corresponding grant being issued must be finite and, ideally, determinable at design time. Real-time systems (audio, video, safety-critical control) require bounded latency guarantees. An arbiter that provides probabilistic fairness but no worst-case bound is insufficient for hard real-time.

**3. Efficiency (high utilisation):**

The arbiter must not leave the resource idle when requests are pending. If any request is active and the resource is free, a grant should be issued within a bounded number of cycles. Wasteful idle cycles reduce system throughput.

**Secondary properties** (desirable but not always achievable simultaneously):
- **Proportional fairness:** Each requester receives bandwidth proportional to its assigned weight
- **Low latency:** The arbitration decision is made in a single cycle, without multi-cycle look-ahead
- **Low area:** The arbiter circuit does not add significant area to the resource it guards
- **Determinism:** Given the same request pattern, the arbiter always produces the same grant sequence

**Tradeoff:** Liveness and bounded latency are often in tension with efficiency. Guaranteeing bounded latency for a low-priority requester may require reserving bandwidth (reducing efficiency) or temporarily blocking high-priority requesters (increasing their latency).

---

### Q2. Describe fixed priority arbitration. Implement a 4-requester fixed-priority arbiter in synthesisable SystemVerilog.

**Answer:**

**Mechanism:**

Fixed priority arbitration assigns a permanent priority rank to each requester. When multiple requesters are active simultaneously, the one with the highest priority wins. Requester 0 is always preferred over requester 1, which is always preferred over requester 2, and so on.

**Implementation:**

The simplest implementation is a priority encoder combined with a one-hot grant decoder:

```systemverilog
// Fixed-priority arbiter: 4 requesters, requester 0 has highest priority
// Inputs:  req[3:0]  — one-hot or binary-coded request signals (level-sensitive)
// Outputs: grant[3:0] — one-hot grant, asserted for one cycle when resource is free

module fixed_priority_arbiter #(
    parameter int N = 4  // number of requesters
) (
    input  logic        clk,
    input  logic        rst_n,
    input  logic [N-1:0] req,    // request vector, any bits may be high simultaneously
    output logic [N-1:0] grant   // one-hot grant output
);

    // Combinational priority encode: lowest index wins
    // For each bit i, grant[i] is set iff req[i] is asserted
    // and no lower-index request is asserted.
    always_comb begin
        grant = '0;
        for (int i = 0; i < N; i++) begin
            if (req[i] && (grant == '0)) begin
                grant[i] = 1'b1;
            end
        end
    end

endmodule
```

**Equivalent one-liner using priority masking:**

```systemverilog
// Compact form: grant lowest-set-bit using two's complement trick
// grant = req & (-req)  — isolates the least-significant set bit
always_comb begin
    grant = req & (~req + 1'b1);  // equivalent to req & (-req) in two's complement
end
```

**Test cases:**

```systemverilog
// req = 4'b0000 -> grant = 4'b0000 (no requests)
// req = 4'b0001 -> grant = 4'b0001 (only req 0)
// req = 4'b0110 -> grant = 4'b0010 (req 1 beats req 2)
// req = 4'b1111 -> grant = 4'b0001 (req 0 wins all)
// req = 4'b1100 -> grant = 4'b0100 (req 2 wins over req 3)
```

**Properties:**
- Requester 0: zero starvation risk, immediate grant whenever active
- Requester N-1: maximum starvation risk, grant only when all lower requesters are idle
- Latency for requester i: worst case unbounded if requesters 0..(i-1) are always active
- Area: O(N) gates

**When to use:** Fixed priority is appropriate when requesters have genuinely different real-time criticality — for example, granting interrupt acknowledge transactions higher priority than bulk DMA. It is inappropriate when multiple requesters of similar importance compete for bandwidth, as it creates starvation risk.

---

### Q3. Describe round-robin arbitration and explain how it solves the starvation problem. Implement a 4-requester round-robin arbiter.

**Answer:**

**Mechanism:**

Round-robin arbitration maintains a rotating priority pointer. After each grant, the pointer advances to the next requester (in modular arithmetic). The next arbitration cycle starts priority from the requester after the one most recently granted. All requesters get an equal share of grants over time.

**Starvation analysis:**

For N requesters all continuously asserting requests, each gets granted exactly once every N cycles. No requester can be starved. The worst-case wait time for any requester is (N-1) cycles — the time for all other requesters to receive their grant.

**RTL implementation:**

```systemverilog
// Round-robin arbiter: 4 requesters
// Priority rotates so the requester after the last-granted one
// has highest priority in the next cycle.
module round_robin_arbiter #(
    parameter int N = 4
) (
    input  logic         clk,
    input  logic         rst_n,
    input  logic [N-1:0] req,
    output logic [N-1:0] grant
);

    logic [N-1:0] priority_mask;  // one-hot: next requester to have highest priority
    logic [N-1:0] masked_grant;   // grant within masked (higher-priority) region
    logic [N-1:0] unmasked_grant; // fallback: grant with no masking (wrap-around)

    // Fixed-priority grant from a given start position.
    // Uses the two's-complement trick to isolate the lowest set bit.
    function automatic logic [N-1:0] priority_grant(
        input logic [N-1:0] requests,
        input logic [N-1:0] mask
    );
        logic [N-1:0] masked_req;
        masked_req = requests & ~(mask - 1'b1);  // zero bits below mask position
        // Isolate lowest set bit in masked region
        return masked_req & (~masked_req + 1'b1);
    endfunction

    // Priority pointer register: updated after each grant
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            priority_mask <= N'(1);  // start from requester 0
        end else if (|grant) begin
            // Advance pointer to the requester after the one just granted.
            // Rotate left by 1 from the granted bit position.
            priority_mask <= {grant[N-2:0], grant[N-1]};
        end
    end

    // Arbitration: try masked region first, fall back to unmasked
    always_comb begin
        // Try to grant a request at or above the current priority pointer
        masked_grant   = priority_grant(req, priority_mask);
        // If none pending in masked region, wrap around and grant from bit 0
        unmasked_grant = req & (~req + 1'b1);

        // Select masked grant if valid, else unmasked
        grant = (|masked_grant) ? masked_grant : unmasked_grant;
    end

endmodule
```

**Simulation example (4 requesters, all active):**

```
Cycle 0: priority_mask=0001, req=1111, grant=0001 (req 0)
Cycle 1: priority_mask=0010, req=1111, grant=0010 (req 1)
Cycle 2: priority_mask=0100, req=1111, grant=0100 (req 2)
Cycle 3: priority_mask=1000, req=1111, grant=1000 (req 3)
Cycle 4: priority_mask=0001, req=1111, grant=0001 (req 0) -- wraps
```

**Simulation example (sparse requests):**

```
Cycle 0: priority_mask=0001, req=1010, grant=0010 (req 1 -- lowest above mask)
Cycle 1: priority_mask=0100, req=1010, grant=1000 (req 3 -- lowest above mask)
Cycle 2: priority_mask=0001, req=1010, grant=0010 (wraps, req 1 again)
```

**Properties:**
- All requesters served equally when continuously requesting
- Worst-case grant latency = (N-1) cycles
- No starvation under any request pattern
- Area: O(N) flip-flops + O(N) combinational logic

---

## Tier 2: Intermediate

### Q4. What is weighted round-robin (WRR) arbitration, and how does it allocate bandwidth proportionally?

**Answer:**

**Motivation:**

Simple round-robin gives each requester equal bandwidth. In a real SoC, different agents have different bandwidth needs. A video display pipeline may need 70% of the memory bus bandwidth while a background firmware task needs only 5%. WRR allows a designer to allocate bandwidth in proportion to assigned weights while still preventing starvation.

**Mechanism:**

Each requester $i$ is assigned a weight $w_i$. The arbiter maintains a credit counter $c_i$ for each requester. In each round:
1. Each requesting agent receives $w_i$ credits at the start of the round.
2. Each grant deducts one credit from the winning agent's counter.
3. When all active agents have exhausted their credits, a new round starts (credits are replenished).
4. Within a round, a round-robin or fixed-priority order is used among agents with remaining credits.

**Example:**

Four agents: A(w=4), B(w=2), C(w=1), D(w=1). Total credits per round = 8.

Grant sequence for all four continuously requesting:

```
Round start: credits A=4, B=2, C=1, D=1
Grant A (c_A: 4→3), Grant A (c_A: 3→2), Grant B (c_B: 2→1),
Grant A (c_A: 2→1), Grant B (c_B: 1→0), Grant C (c_C: 1→0),
Grant A (c_A: 1→0), Grant D (c_D: 1→0).
New round: replenish all.
```

Over 8 grants: A gets 4 (50%), B gets 2 (25%), C gets 1 (12.5%), D gets 1 (12.5%). Proportional to weights.

**RTL implementation sketch:**

```systemverilog
// Weighted round-robin arbiter (simplified, combinational weight decode)
module wrr_arbiter #(
    parameter int N = 4,
    parameter int MAX_WEIGHT = 8
) (
    input  logic                          clk,
    input  logic                          rst_n,
    input  logic [N-1:0]                  req,
    input  logic [$clog2(MAX_WEIGHT):0]   weight [N],  // weight per agent
    output logic [N-1:0]                  grant
);

    logic [$clog2(MAX_WEIGHT):0] credits [N];   // remaining credits
    logic [N-1:0]                 eligible;      // agents with credits AND requests

    // Determine which agents are eligible this round
    always_comb begin
        for (int i = 0; i < N; i++) begin
            eligible[i] = req[i] & (credits[i] > '0);
        end
    end

    // Grant the lowest-index eligible agent (fixed priority within round)
    // In a full implementation this would be the round-robin pointer position.
    always_comb begin
        grant = eligible & (~eligible + 1'b1);  // lowest set bit
    end

    // Update credits on grant; replenish when all credits exhausted
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < N; i++) credits[i] <= weight[i];
        end else if (|grant) begin
            for (int i = 0; i < N; i++) begin
                if (grant[i]) credits[i] <= credits[i] - 1'b1;
            end
            // Replenish if no eligible agents remain after this grant
            if ((eligible & ~grant) == '0) begin
                for (int i = 0; i < N; i++) credits[i] <= weight[i];
            end
        end
    end

endmodule
```

**Starvation analysis:**

WRR prevents starvation: every agent with weight $w_i \geq 1$ receives at least one grant per round. The worst-case latency for agent $i$ is one full round = $\sum_j w_j$ cycles. For weights [4, 2, 1, 1], worst case = 8 cycles. This is bounded and deterministic.

**Limitation of basic WRR:**

The grant sequence within a round depends on whether other agents happen to be requesting. If agent A has weight 4 but only agent B is requesting for the first 4 grants, B gets all 4 grants even though A's weight says it should get them. This is correct behaviour (B is not stealing from A — A is not requesting), but means the achieved bandwidth ratio only equals the weight ratio when all agents are continuously requesting.

---

### Q5. What is deficit round-robin (DRR) and how does it handle variable-length transactions better than WRR?

**Answer:**

**Problem with WRR for variable-length transactions:**

WRR counts grants (transactions), not bytes. If agent A makes short 4-byte transactions and agent B makes long 64-byte transactions, giving them equal grant counts gives B 16× more bytes per round. The bandwidth split is not proportional to weights.

**DRR mechanism (Shreedhar and Varghese, 1995):**

Each agent maintains a deficit counter $D_i$ (a byte-level credit). Each round, agent $i$ receives a quantum $Q_i$ of bytes added to its deficit counter. The agent may send transactions until the cumulative byte count of those transactions exceeds $D_i$. Any unused deficit carries over to the next round (up to $D_i \leq Q_i + $ maximum transaction size).

```
Round structure:
  For each non-empty requester i:
    D_i += Q_i                  // add quantum
    While req[i] active AND next_packet_size[i] <= D_i:
        grant agent i
        D_i -= packet_size_of_granted_transaction
    // Leftover D_i carries to next round
```

**Example:**

Agents A (Q=400 bytes), B (Q=100 bytes). A makes 400-byte transactions, B makes 100-byte transactions.

Round 1: D_A = 400, send one 400-byte transaction (D_A→0). D_B = 100, send one 100-byte transaction (D_B→0).
Round 2: same.

Result: A gets 4× the bytes of B — proportional to quantum ratio. Importantly, this holds regardless of transaction size.

**Why DRR is preferred for interconnects with variable burst lengths:**

In an AXI interconnect, burst lengths of 1, 4, 8, 16, or 256 beats are all valid. A WRR arbiter that grants one AXI transaction per credit would give widely different byte bandwidths to agents depending on their burst length. DRR normalises by byte count, achieving true proportional bandwidth sharing.

**RTL complexity:**

DRR requires knowing the transaction size at the time of arbitration (to compare against the deficit counter). For AXI, the burst length field AWLEN/ARLEN is available with the request, making this feasible. The deficit counter must be wide enough to hold $Q_{max} + $ maximum transaction size.

---

### Q6. What is age-based arbitration? Under what SoC conditions is it particularly valuable?

**Answer:**

**Mechanism:**

Age-based arbitration (also called oldest-first or first-come-first-served) grants the resource to the requester whose request has been pending the longest. Each request is timestamped when it is asserted. The arbiter selects the request with the earliest (smallest) timestamp.

**RTL implementation:**

```systemverilog
// Age-based arbiter: timestamp each request when first asserted,
// grant the oldest request.
module age_based_arbiter #(
    parameter int N = 4,
    parameter int TIMESTAMP_WIDTH = 16
) (
    input  logic                            clk,
    input  logic                            rst_n,
    input  logic [N-1:0]                    req,
    output logic [N-1:0]                    grant
);

    // Timestamp each request entry
    logic [TIMESTAMP_WIDTH-1:0] timestamp [N];
    logic [TIMESTAMP_WIDTH-1:0] global_timer;
    logic [N-1:0]               active;  // has this request been timestamped?

    // Global free-running timer
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) global_timer <= '0;
        else        global_timer <= global_timer + 1'b1;
    end

    // Capture timestamp when new request arrives
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            active <= '0;
        end else begin
            for (int i = 0; i < N; i++) begin
                if (req[i] && !active[i]) begin
                    timestamp[i] <= global_timer;
                    active[i]    <= 1'b1;
                end else if (!req[i]) begin
                    active[i] <= 1'b0;  // clear when deasserted
                end
            end
        end
    end

    // Grant the oldest active request (minimum timestamp)
    always_comb begin
        logic [TIMESTAMP_WIDTH-1:0] oldest_ts;
        logic [N-1:0]               candidate;

        grant      = '0;
        oldest_ts  = '1;  // start at maximum
        candidate  = '0;

        for (int i = 0; i < N; i++) begin
            if (req[i] && active[i] && (timestamp[i] < oldest_ts)) begin
                oldest_ts = timestamp[i];
                candidate = N'(1 << i);
            end
        end
        grant = candidate;
    end

endmodule
```

**When age-based arbitration is valuable:**

1. **Transaction ordering correctness:** In a system where multiple masters issue requests to the same slave and ordering must be preserved (e.g., two CPU threads writing to a shared memory-mapped peripheral), age-based ordering ensures that the earlier-issued request is serviced first, preserving observable memory order.

2. **Latency fairness under bursty load:** Under intermittent bursty traffic, a round-robin arbiter can inadvertently delay a request that arrives between bursts while serving other agents. Age-based arbitration ensures the request waits only as long as older requests ahead of it — no agent leapfrogs a request that was earlier.

3. **Combined with QoS:** Age-based arbitration within a priority class is a standard component of QoS-aware systems. Traffic is first classified by priority level; within a level, age breaks ties. This prevents head-of-line blocking: a new high-priority request cannot skip over an older request of the same priority.

**Limitation:**

Age-based arbitration requires a timestamp per request entry and a minimum-of-N comparator tree. For N = 64 requesters, the comparator is a log2(64) = 6-level tree, adding latency to the arbitration critical path. For very large N, the timing closure challenge may require pipelining, which adds latency.

---

## Tier 3: Advanced

### Q7. Design a two-level priority arbiter with starvation prevention. The arbiter has 8 requesters: 2 real-time (RT) and 6 best-effort (BE). Real-time agents must receive grants within 16 cycles. Best-effort agents must not be starved indefinitely.

**Answer:**

**Requirements analysis:**

- RT agents: 16-cycle worst-case grant latency — use fixed priority within RT class
- BE agents: no starvation — use round-robin within BE class
- RT takes precedence over BE — two-level hierarchy
- Starvation prevention for BE: if a BE agent has waited more than T cycles, promote it to temporary RT priority

**Architecture:**

```
Level 1: RT arbiter (fixed priority, 2 agents)
Level 2: BE arbiter (round-robin, 6 agents)
Level 3: Merge: RT wins unless no RT request pending OR BE agent age exceeds threshold
```

**RTL implementation:**

```systemverilog
// Two-level priority arbiter with age-based starvation prevention
// RT agents [1:0], BE agents [7:2]
// RT_LATENCY_LIMIT: max cycles a BE agent waits before promotion
module two_level_arbiter #(
    parameter int N_RT     = 2,
    parameter int N_BE     = 6,
    parameter int N        = N_RT + N_BE,   // 8 total
    parameter int RT_LATENCY_LIMIT = 16,
    parameter int BE_STARVATION_LIMIT = 128  // promote BE after 128 cycles
) (
    input  logic        clk,
    input  logic        rst_n,
    input  logic [N-1:0] req,    // [1:0] RT, [7:2] BE
    output logic [N-1:0] grant
);

    // ---------- RT arbiter (fixed priority) ----------
    logic [N_RT-1:0] rt_req, rt_grant;
    assign rt_req = req[N_RT-1:0];

    always_comb begin
        rt_grant = rt_req & (~rt_req + 1'b1);  // lowest-index RT wins
    end

    // ---------- BE arbiter (round-robin) ----------
    logic [N_BE-1:0]     be_req, be_grant;
    logic [N_BE-1:0]     be_priority_mask;
    logic [N_BE-1:0]     be_masked_grant, be_unmasked_grant;

    assign be_req = req[N-1:N_RT];

    always_comb begin
        be_masked_grant   = be_req & ~(be_priority_mask - 1'b1) & (~(be_req & ~(be_priority_mask - 1'b1)) + 1'b1);
        be_unmasked_grant = be_req & (~be_req + 1'b1);
        be_grant = (|(be_req & ~(be_priority_mask - 1'b1))) ? be_masked_grant : be_unmasked_grant;
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) be_priority_mask <= N_BE'(1);
        else if (|be_grant && !starvation_promote)
            be_priority_mask <= {be_grant[N_BE-2:0], be_grant[N_BE-1]};
    end

    // ---------- Starvation prevention ----------
    // Track how long each BE agent has been waiting
    logic [$clog2(BE_STARVATION_LIMIT+1)-1:0] be_age [N_BE];
    logic [N_BE-1:0] starvation_flag;
    logic            starvation_promote;  // any BE agent has waited too long?

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < N_BE; i++) be_age[i] <= '0;
        end else begin
            for (int i = 0; i < N_BE; i++) begin
                if (be_grant[i]) begin
                    be_age[i] <= '0;            // reset age on grant
                end else if (be_req[i]) begin
                    if (be_age[i] < BE_STARVATION_LIMIT)
                        be_age[i] <= be_age[i] + 1'b1;
                end else begin
                    be_age[i] <= '0;            // not requesting: reset
                end
            end
        end
    end

    always_comb begin
        starvation_flag = '0;
        for (int i = 0; i < N_BE; i++) begin
            if (be_age[i] >= BE_STARVATION_LIMIT) starvation_flag[i] = 1'b1;
        end
        starvation_promote = |starvation_flag;
    end

    // ---------- Level merge ----------
    // RT wins unless: (a) no RT requests, OR (b) a BE agent has reached starvation limit
    always_comb begin
        if (starvation_promote) begin
            // Serve the oldest-waiting BE agent; use priority encode of starvation flags
            grant = {(starvation_flag & (~starvation_flag + 1'b1)), {N_RT{1'b0}}};
        end else if (|rt_req) begin
            grant = {{N_BE{1'b0}}, rt_grant};
        end else begin
            grant = {be_grant, {N_RT{1'b0}}};
        end
    end

endmodule
```

**Latency guarantee analysis:**

- RT agents: at most 2 RT agents; with fixed priority, RT[0] is granted in 1 cycle, RT[1] in at most 1 cycle after RT[0] finishes. If the resource takes 1 cycle per grant, RT[1] worst case = 2 cycles < 16 cycle requirement. ✓
- BE agents: worst case without starvation prevention = indefinite. With starvation limit of 128 cycles, any BE agent is guaranteed a grant within 128 + 1 cycles. ✓

**Key design decisions:**
1. Starvation threshold (128 cycles) is chosen to be large enough not to interfere with normal RT traffic but small enough to prevent perceptible starvation.
2. On promotion, the oldest-waiting BE agent wins over RT. This temporarily violates the RT priority hierarchy, which is acceptable only when BE starvation is deemed more harmful. For hard real-time systems, a stricter design would use a separate guaranteed-service slot rather than preempting RT.

---

### Q8. Explain the difference between work-conserving and non-work-conserving arbitration. Give a concrete SoC example where non-work-conserving arbitration is preferable.

**Answer:**

**Work-conserving arbiter:**

A work-conserving arbiter never leaves the resource idle when there is a pending request. If any requester is active, a grant is issued in the next available cycle. Round-robin, WRR, and fixed priority are all work-conserving.

**Non-work-conserving arbiter:**

A non-work-conserving arbiter may deliberately idle the resource even when requests are pending. It withholds grants to enforce a timing policy — typically to guarantee that future high-priority or time-sensitive requests encounter a predictable, low-latency resource state when they arrive.

**SoC example — display DMA and CPU coherency:**

Consider a DRAM controller serving a display DMA engine and a CPU L2 cache. The display DMA is a high-bandwidth, latency-tolerant burst consumer: it reads 64 bytes every 33 ns (for 60 Hz 4K). The CPU L2 cache is a low-bandwidth, latency-sensitive requester: it needs DRAM responses within 100 ns to avoid stalling the CPU pipeline.

A work-conserving WRR arbiter gives the display DMA its proportional bandwidth share. However, if the DMA issues a 256-beat AXI burst (32 KB at 64 bytes/beat), the DRAM controller spends 256 cycles serving the DMA. A CPU cache miss that arrives during this burst must wait 256 cycles — potentially 256 ns at 1 GHz, far exceeding the 100 ns latency budget.

**Solution — non-work-conserving arbiter with credit-based pacing:**

The DMA is given a credit that allows it to inject a burst only once every $T$ cycles. Between bursts, the arbiter deliberately does not grant the DMA even if it has pending requests, holding the DRAM available for CPU accesses. The DMA burst is broken into smaller sub-bursts paced by the credit timer.

```
DMA credit: 1 credit per 50 ns (sufficient for 64 bytes at 51.2 GB/s bandwidth)
DMA burst size: limited to 8 beats (512 bytes) per credit
Between DMA bursts: DRAM is reserved for CPU requests
```

Result: DMA achieves its required bandwidth (64 bytes per 33 ns = 1.9 GB/s, which 1 credit per 50 ns with 512-byte bursts provides). CPU latency worst case = 8-beat DMA burst duration = 8 cycles = 8 ns — well within the 100 ns budget.

**Cost of non-work-conserving arbitration:**

The DRAM controller may sit idle between DMA credits if no CPU requests are pending. This reduces peak throughput. However, in a real system the CPU is almost always generating some demand, so the DRAM is rarely truly idle. The latency guarantee is worth the small throughput reduction.

**Use cases:** Non-work-conserving arbitration (also called rate-controlled or metered arbitration) is standard in DRAM controllers for mixed real-time/best-effort workloads, in GPU memory schedulers, and in network routers implementing CBQ (Class-Based Queueing).

---

## Quick Reference: Arbitration Scheme Comparison

| Scheme | Starvation | Worst-case Latency | Bandwidth Allocation | Complexity | Use Case |
|---|---|---|---|---|---|
| Fixed priority | Yes (low priorities) | Unbounded | All to highest priority | O(N) | RT + best-effort, distinct criticality |
| Round-robin | No | (N-1) cycles | Equal share | O(N) | Homogeneous masters |
| WRR | No | Sum(weights) cycles | Proportional (by count) | O(N×W) | Heterogeneous bandwidth needs |
| DRR | No | Sum(quanta)/min(Q) | Proportional (by bytes) | O(N×W) | Variable burst lengths |
| Age-based | No | Bounded by queue depth | FCFS | O(N log N) | Ordering preservation, fairness |
| Two-level | No (with timer) | Configurable per class | Class-weighted | O(M+N) | Mixed RT/BE systems |

| Key formula | Meaning |
|---|---|
| WRR latency bound = $\sum_i w_i$ cycles | Worst-case grant wait per round |
| DRR quantum ratio = $Q_i / Q_j$ | Achieved bandwidth ratio between agents i and j |
| Age-based comparator depth = $\log_2 N$ levels | Critical path of N-way minimum finder |
| Starvation threshold $T$ | Maximum BE wait before promotion; set T > max RT burst duration |
