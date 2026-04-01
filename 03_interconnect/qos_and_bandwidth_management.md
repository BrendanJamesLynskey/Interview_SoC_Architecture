# QoS and Bandwidth Management

## Overview

Quality of Service (QoS) in SoC interconnects is the set of mechanisms that guarantees differentiated service levels to different traffic classes. Without QoS, a GPU bulk transfer can starve a CPU instruction fetch; a background firmware update can cause audio dropouts; a hardware security monitor can miss a timing deadline. With QoS, each traffic class receives the bandwidth, latency, and ordering guarantees it needs — regardless of what other agents are doing.

QoS is not a single mechanism. It is a stack of interacting policies: traffic classification by tagging, priority-based and bandwidth-regulated arbitration, buffering and traffic shaping to absorb bursts, congestion signalling to prevent collapse, and performance monitoring to verify that SLAs (service-level agreements) are met in silicon. This document covers the full stack, from the ARPROT/AWQOS signals in AXI to the memory scheduler policies in a production DRAM controller.

---

## Tier 1: Fundamentals

### Q1. What is a QoS tag, and how is it used in an AXI interconnect?

**Answer:**

A QoS tag is a numeric value carried with each transaction that identifies the traffic class and therefore the service level the transaction should receive. In the AMBA AXI4 specification, the QoS signal is:

- **AWQOS[3:0]:** 4-bit QoS tag on the write address channel
- **ARQOS[3:0]:** 4-bit QoS tag on the read address channel

The value 4'b0000 is the default, indicating no QoS preference (best effort). Values 4'b0001 to 4'b1111 indicate increasing priority, though the exact interpretation is implementation-defined by the interconnect.

**How the interconnect uses QoS tags:**

An AXI crossbar or NoC arbitration engine reads the QoS field of each pending transaction and uses it to prioritise grant decisions. The mapping from QoS value to arbitration behaviour is configured by a QoS regulator register in the interconnect, typically set during boot by a power management or OS scheduler.

Example mapping for a 4-level priority scheme:

| ARQOS value | Traffic class | Arbitration behaviour |
|---|---|---|
| 4'b1111 | Real-time (audio/video decode) | Fixed priority, always preempts lower classes |
| 4'b1010 | Interactive (CPU instruction fetch) | Low-latency WRR, weight = 4 |
| 4'b0101 | Background DMA | WRR, weight = 2 |
| 4'b0000 | Best-effort | Round-robin, weight = 1 |

**Limitations of AXI QoS:**

The AXI specification defines the QoS field but does not mandate how the interconnect uses it. An AXI master must assert the appropriate QoS value, but whether the interconnect provides the corresponding service level depends entirely on the interconnect's QoS policy configuration. Two SoC vendors using the same AXI interconnect IP may configure QoS policies very differently.

**Common mistake:** Asserting a high QoS value (e.g., 4'b1111) for all transactions from a master in an attempt to always win arbitration. If every master asserts maximum QoS, the differentiation is lost and the result is equivalent to round-robin. QoS is only meaningful when different masters are assigned different values.

---

### Q2. What are the three fundamental traffic quality metrics in a SoC interconnect?

**Answer:**

**1. Bandwidth (throughput):**

The sustained data transfer rate a traffic class can maintain over time, measured in bytes per second or GB/s. Bandwidth requirements are specified for streaming consumers and producers: a 4K@60Hz display requires ~1.5 GB/s read bandwidth; an H.265 encode block requires ~2 GB/s read + 1 GB/s write.

A bandwidth guarantee means the interconnect will allocate enough capacity that the specified traffic class achieves its minimum throughput even under maximum competing load. This is implemented via weighted arbitration, traffic metering, or reserved bandwidth slots.

**2. Latency:**

The time from a request being issued to the first data beat being returned (read latency) or the write acknowledge being received (write latency). Latency requirements are specified for latency-sensitive agents: a CPU L2 cache miss must be completed within ~100–200 cycles to avoid pipeline stalls; a hardware real-time clock update may require sub-microsecond latency.

A latency guarantee means the interconnect bounds the worst-case time the specified traffic class waits in arbitration queues before reaching the target slave. This is implemented via priority elevation or non-work-conserving credit pacing that keeps the interconnect path clear.

**3. Ordering and coherency:**

Some traffic classes require that transactions from the same master arrive at the target slave in the order they were issued (transaction ordering), or that writes from one master are visible to reads from another master within a bounded time (coherency flushing latency).

The interconnect maintains ordering through per-source-ID transaction tracking, preventing a later transaction from completing before an earlier transaction to the same address range.

**The fundamental tradeoff:**

These three metrics are not simultaneously optimisable for all traffic classes. Guaranteeing bandwidth to class A requires withholding bandwidth from class B during class A's reserved windows — increasing class B's latency. Guaranteeing latency for class C requires expediting its transactions past class D, reducing class D's throughput. A QoS design must explicitly choose which classes get hard guarantees and which get best-effort service.

---

### Q3. What is traffic shaping, and why is it required even in a system with correct priority arbitration?

**Answer:**

Traffic shaping controls the rate and burst size at which a traffic class injects transactions into the interconnect, regardless of the maximum rate the source can generate. It is necessary because priority arbitration alone does not prevent bandwidth starvation of lower-priority classes.

**The burst starvation problem:**

Consider a memory controller serving a high-priority video DMA and a lower-priority CPU cache. The DMA is assigned higher priority. When the DMA issues a 4 KB burst (64 AXI beats), it holds the DRAM port for approximately 64 cycles. During this time, any CPU cache miss is blocked even though the DMA's aggregate bandwidth need (say 1 GB/s) does not justify monopolising the 50 GB/s DRAM.

Without shaping, the DMA can issue an unlimited number of consecutive bursts. Even though each individual burst has a bounded length, a DMA engine with deep hardware queues can continuously issue back-to-back bursts, creating an effective monopoly on the DRAM port. CPU latency becomes unbounded even though DMA priority is technically correct.

**Traffic shaping mechanisms:**

**Token bucket:** A token accumulates at rate $r$ tokens/second up to a maximum bucket depth $B$ tokens. Each transaction consumes tokens proportional to its size. When the bucket is empty, the transaction is held (throttled). This limits the sustained rate to $r$ and the burst size to $B$.

```
Parameters:
  r = 1 GB/s  (sustained rate)
  B = 4 KB    (burst tolerance)
Effect:
  Allows one 4 KB burst immediately, then limits to 1 GB/s sustained.
  A 256 KB bulk transfer is spread over 256 microseconds.
```

**Leaky bucket:** Transactions are released from a queue at a fixed rate $r$ regardless of arrival rate. This converts bursty input traffic to smoothed output traffic. The "leak" rate guarantees that downstream arbiters see a predictable traffic load.

**Credit-based shaping (AXI4 QoS regulator):**

The AXI interconnect's QoS regulator allocates a bandwidth credit to each master port on a fixed time window (e.g., every 100 ns, each master is allowed to issue up to $C_i$ AXI transactions). When the credit is exhausted, the master's outstanding transaction count is throttled at the regulator, even if the master continues to issue requests.

**Why shaping is required in addition to priority:**

Priority determines who wins when two requests compete. Shaping determines how many requests are in the competition at any time. Without shaping, a high-burst-rate master can flood the arbitration queues, increasing latency for all competing requesters even if its priority is not the highest. Shaping reduces the offered load to a manageable level, making priority decisions faster and latency bounds tighter.

---

## Tier 2: Intermediate

### Q4. Describe how a DRAM controller implements per-traffic-class latency and bandwidth QoS. What is the role of the memory scheduler?

**Answer:**

A DRAM controller sits at the convergence point of all memory traffic. It receives AXI transactions from the SoC interconnect and converts them into DRAM commands (ACTIVATE, READ/WRITE, PRECHARGE, REFRESH). The memory scheduler is the component that decides, on each DRAM clock cycle, which pending request to service.

**DRAM timing constraints:**

DRAM has complex timing constraints that prevent naive first-come-first-served scheduling:
- tRCD (RAS-to-CAS delay): a row must be activated before reads/writes
- tRP (precharge time): a row must be precharged before a different row can be activated
- tCL (CAS latency): time from READ command to first data
- tRC (row cycle time): minimum time between successive ACTIVATEs to the same bank

These constraints mean that servicing requests out-of-order (row-hit reordering) can be 2–4× more efficient than strict ordering. The scheduler exploits this by batching row-hit requests, but must be controlled to prevent QoS violations.

**QoS-aware memory scheduling:**

A production DRAM scheduler implements multiple priority queues feeding a per-class scheduler:

```
Incoming AXI transactions → QoS tagger → Priority queues
                                          [RT queue: ARQOS = 15]
                                          [High queue: ARQOS = 8-14]
                                          [Normal queue: ARQOS = 4-7]
                                          [BE queue: ARQOS = 0-3]
                                          ↓
                                    Scheduler policy:
                                    1. Service RT queue (with reorder limit)
                                    2. Service High queue if RT empty
                                    3. Service Normal with WRR weight 4
                                    4. Service BE with WRR weight 1
                                    ↓
                                    DRAM command generator
```

**Latency guarantee implementation:**

For the RT queue, the scheduler enforces a worst-case latency bound by tracking the age of the oldest pending RT request. If the oldest RT request has been waiting for more than $T_{max}$ cycles:
1. The scheduler immediately issues an ACTIVATE for the RT request's row (aborting any in-progress reorder optimisation for lower-priority requests)
2. Issues the READ/WRITE command immediately after tRCD
3. Resumes lower-priority scheduling after the RT request completes

This guarantees that the RT request latency = queue wait time (bounded by $T_{max}$) + tRCD + tCL + burst length.

**Bandwidth guarantee implementation:**

The scheduler maintains a running byte count per traffic class within a sliding 1 ms window. If a lower-priority class's count falls below its minimum allocation, it is temporarily elevated in priority to reclaim bandwidth. This implements a soft bandwidth floor without violating the latency bound for RT traffic.

**Refresh handling:**

DRAM requires periodic REFRESH commands (every 7.8 µs for DDR4 at standard temperature, 3.9 µs for extended temperature). Each REFRESH takes approximately tRFC (150–550 ns depending on DRAM density). During REFRESH, no read or write commands can be issued. This creates mandatory latency spikes. A QoS-aware controller schedules REFRESH during periods when RT queue is empty, and delays REFRESH by up to 2× tREFI if an RT transaction is in progress, issuing two REFRESH commands back-to-back afterward.

---

### Q5. What is head-of-line blocking in a QoS context, and how do virtual output queues eliminate it?

**Answer:**

**Head-of-line (HOL) blocking:**

HOL blocking occurs when a high-priority transaction is blocked behind a lower-priority transaction in a shared queue, even though the high-priority transaction's path to its destination is free. The earlier transaction at the head of the queue blocks all subsequent transactions, regardless of their priority or destination.

**Concrete example:**

A shared 4-entry request queue in an AXI interconnect:

```
Queue (head → tail): [BE burst, destination DRAM_ctrl_0] →
                     [RT read,  destination DRAM_ctrl_1] →
                     [RT read,  destination DRAM_ctrl_1] →
                     [BE write, destination GPU_mem]
```

DRAM_ctrl_0 is busy (serving a prior burst). DRAM_ctrl_1 is idle. Despite DRAM_ctrl_1 being free and two RT reads targeting it, the BE burst at the head of the queue blocks everything. The RT reads cannot be issued until the BE burst either progresses or is preempted.

**HOL blocking impact on latency:**

In the worst case, an RT transaction must wait for all ahead-of-it transactions to drain before it can be issued, even if its target slave is available. This can add tens to hundreds of cycles of unnecessary latency — violating the RT latency guarantee.

**Virtual output queues (VOQ):**

VOQ eliminates HOL blocking by maintaining a separate queue per (source, destination) pair or per (source, priority class) combination. Instead of one shared queue, each destination has its own queue:

```
DRAM_ctrl_0 queue: [BE burst]
DRAM_ctrl_1 queue: [RT read] → [RT read]
GPU_mem queue:     [BE write]
```

The scheduler for DRAM_ctrl_1 sees its own queue and immediately issues the RT reads, without any interference from the BE burst in the DRAM_ctrl_0 queue.

**Cost of VOQ:**

VOQ requires $M \times N$ queues (M sources, N destinations). Each queue has head, tail, and count pointers plus storage for outstanding transactions. For a 16×8 crossbar, this is 128 queues. The storage overhead is significant but manageable: at 2–4 entries per queue and 16 bytes per entry (AXI address + metadata), 128 queues × 4 entries × 16 bytes = 8 KB of SRAM — negligible in a modern SoC.

**Practical implementation:**

Commercial AXI interconnects (Arm NIC-400, Synopsys DesignWare AXI) implement per-destination QoS queues rather than full VOQ. A transaction is placed in the queue for its destination slave. Each slave port has its own arbiter selecting from all master queues targeting it, using WRR or priority arbitration. This is equivalent to VOQ for the non-blocking crossbar topology.

---

### Q6. Describe the AMBA QoS Virtual Network (QVN) extension. How does it provide bandwidth and latency guarantees beyond what standard AXI QoS provides?

**Answer:**

**Limitation of standard AXI QoS:**

Standard AXI QoS (AWQOS/ARQOS) provides a hint to the interconnect but does not define a contract. The interconnect may choose any QoS policy. There is no mechanism for a master to reserve bandwidth in advance, and there is no backpressure mechanism that tells a master its transactions are being throttled.

**AMBA QVN (introduced in AMBA 5 AXI5):**

QVN extends AXI5 with a virtual network model. Each master is assigned one or more virtual networks (VNs), numbered 0–N. VNs have different service guarantees:

- **VN0:** Best-effort, no bandwidth or latency guarantee
- **VN1–VN3:** Reserved bandwidth channels with configurable minimum bandwidth and maximum latency

**QVN mechanism:**

The QVN arbiter at each slave port maintains a credit pool per VN. Credits are replenished at a rate equal to the allocated bandwidth share. A master may only issue a transaction on VN$_i$ if VN$_i$ has a credit available. This is a closed-loop rate control:

1. Master checks: does VN$_i$ have a credit?
2. If yes: issue transaction, deduct credit.
3. If no: either downgrade to VN0 (best-effort) or hold the transaction.
4. The slave port replenishes credits at the configured rate.

**Latency guarantee:**

Because VN1–VN3 credits are controlled, the maximum number of outstanding VN transactions is bounded by the credit pool size. A transaction entering a VN queue finds at most $C_{max}$ transactions ahead of it. Since each transaction takes at most $T_{service}$ cycles, the worst-case latency = $C_{max} \times T_{service}$.

By choosing $C_{max}$ and the replenishment rate, the designer can guarantee both bandwidth and latency simultaneously.

**QVN vs standard QoS comparison:**

| Property | AXI QoS (AWQOS) | AMBA QVN |
|---|---|---|
| Bandwidth guarantee | Soft (weight-based, approximates) | Hard (credit-controlled) |
| Latency guarantee | None (priority only) | Bounded (by credit pool size) |
| Feedback to master | None | Credit availability (stall signal) |
| Configuration | Priority mapping table | Bandwidth rate + credit pool |
| Standard support | AXI4 onwards | AXI5 / CHI onwards |

**When to use QVN:**

QVN is appropriate for SoCs with hard real-time constraints — automotive safety controllers, 5G baseband processing, professional audio/video — where both bandwidth and latency must be contractually guaranteed, not merely probabilistically managed.

---

## Tier 3: Advanced

### Q7. Design a token bucket rate limiter for an AXI master port. The master must be limited to 4 GB/s sustained with a burst tolerance of 512 bytes. Implement in synthesisable SystemVerilog.

**Answer:**

**Token bucket parameters:**

- Sustained rate: $r = 4$ GB/s
- Burst size: $B = 512$ bytes (maximum instantaneous burst before throttling)
- AXI data width: 128 bits (16 bytes per beat)
- Interconnect clock: 1 GHz

Token replenishment rate: $r / $ (data width per beat) = 4 × 10^9 / 16 = 250 million tokens per second = 1 token per 4 clock cycles.

Maximum token depth (bucket size): $B$ / (bytes per token) = 512 / 16 = 32 tokens.

```systemverilog
// AXI token bucket rate limiter
// Limits an AXI master to 4 GB/s sustained, 512-byte burst tolerance
// Each token represents one 128-bit (16-byte) AXI data beat.
//
// Interface: sits between the AXI master and the downstream interconnect.
// When the bucket is empty, ARVALID/AWVALID are suppressed (transaction held).
module axi_token_bucket #(
    parameter int TOKEN_MAX       = 32,   // bucket depth in tokens (512 B / 16 B)
    parameter int REPLEN_PERIOD   = 4,    // clock cycles per token replenishment
    parameter int ADDR_WIDTH      = 32,
    parameter int DATA_WIDTH      = 128,
    parameter int LEN_WIDTH       = 8     // AXI ARLEN/AWLEN width
) (
    input  logic                    clk,
    input  logic                    rst_n,

    // From master (upstream side)
    input  logic                    m_arvalid,
    input  logic [ADDR_WIDTH-1:0]   m_araddr,
    input  logic [LEN_WIDTH-1:0]    m_arlen,   // number of beats - 1
    output logic                    m_arready,

    // To interconnect (downstream side)
    output logic                    s_arvalid,
    output logic [ADDR_WIDTH-1:0]   s_araddr,
    output logic [LEN_WIDTH-1:0]    s_arlen,
    input  logic                    s_arready
);

    // Token bucket state
    logic [$clog2(TOKEN_MAX+1)-1:0] tokens;        // current token count
    logic [$clog2(REPLEN_PERIOD)-1:0] replen_ctr;  // replenishment counter
    logic [$clog2(TOKEN_MAX+1)-1:0] burst_tokens;  // tokens required for this burst

    // Tokens required = number of beats = ARLEN + 1
    assign burst_tokens = {1'b0, m_arlen} + 1'b1;

    // Gate: allow transaction only if sufficient tokens are available
    logic token_ok;
    assign token_ok = (tokens >= burst_tokens);

    // Downstream valid: only assert if master wants to transfer AND tokens available
    assign s_arvalid = m_arvalid && token_ok;
    assign s_araddr  = m_araddr;
    assign s_arlen   = m_arlen;

    // Master ready: only indicate ready when downstream accepts AND tokens available
    assign m_arready = s_arready && token_ok;

    // Transaction accepted: handshake on downstream channel
    logic txn_accepted;
    assign txn_accepted = s_arvalid && s_arready;

    // Token bucket management
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tokens     <= TOKEN_MAX[$clog2(TOKEN_MAX+1)-1:0]; // start full
            replen_ctr <= '0;
        end else begin
            // Replenishment: add 1 token every REPLEN_PERIOD cycles
            if (replen_ctr == REPLEN_PERIOD - 1) begin
                replen_ctr <= '0;
                if (!txn_accepted) begin
                    // Add token if not simultaneously consuming
                    tokens <= (tokens < TOKEN_MAX) ? tokens + 1'b1 : TOKEN_MAX[$clog2(TOKEN_MAX+1)-1:0];
                end
                // If simultaneously consuming, the replenish and consume cancel or offset
            end else begin
                replen_ctr <= replen_ctr + 1'b1;
                // Consume tokens on accepted transaction (non-replenishment cycle)
                if (txn_accepted) begin
                    tokens <= tokens - burst_tokens[$clog2(TOKEN_MAX+1)-1:0];
                end
            end
        end
    end

    // Note: In a complete implementation, write channel (AW/W) would be
    // handled similarly. The W channel beat count determines token consumption
    // for writes. Read and write token buckets may be separate or shared
    // depending on the bandwidth allocation policy.

endmodule
```

**Verification plan:**

```systemverilog
// Test 1: Single burst within bucket capacity
// Send ARLEN=31 (32 beats = 512 bytes = TOKEN_MAX tokens)
// Expect: transaction passes immediately (tokens = TOKEN_MAX = 32 >= 32)
// After: tokens = 0, subsequent transactions held until bucket refills

// Test 2: Sustained rate
// Continuously assert ARVALID with ARLEN=3 (4-beat, 64-byte bursts)
// Tokens consumed: 4 per transaction; replenished 1 per 4 cycles
// Expected throughput: 1 token/4 cycles × 16 bytes/token = 4 GB/s
// At 1 GHz: 16 bytes / 4 cycles = 4 GB/s. Correct.

// Test 3: Burst followed by sustained
// Send 32-beat burst (depletes bucket), then continuous 4-beat bursts
// Expect: burst immediate, then 4-beat bursts at 1 per 16 cycles
// (16 cycles to replenish 4 tokens at 1 token/4 cycles)
// Sustained throughput: 64 bytes / 16 cycles = 4 GB/s. Correct.
```

**Key design notes:**

1. The token deduction uses ARLEN (burst length) rather than a fixed count per transaction. This correctly weights long bursts more heavily than short ones.
2. The token bucket starts full, allowing an initial burst up to TOKEN_MAX beats before the rate limit engages.
3. A production implementation would include a bypass mode (token_ok override) for diagnostic purposes and a register interface for runtime reconfiguration of REPLEN_PERIOD.

---

### Q8. Explain congestion avoidance in a NoC. What is the difference between backpressure, credit-based flow control, and explicit congestion notification (ECN)?

**Answer:**

Congestion in a NoC occurs when incoming traffic exceeds a router's output link capacity or buffer depth, causing flits to be dropped or stalled. Congestion avoidance mechanisms prevent this state from degrading into congestion collapse — where retransmissions and retries amplify the overload condition.

**Backpressure (ready/valid handshake):**

Backpressure is the simplest mechanism. When a router's input buffer is full, it deasserts the ready signal to the upstream router. The upstream router stalls, holding its current flit in place. The stall propagates upstream hop-by-hop until it reaches the source agent, which is throttled.

```
Source → Router_A → Router_B → Router_C (buffer full)
                                    ↑
                               ready = 0 (backpressure)
                    ↑
               ready = 0 (propagated)
↑
Source stalls
```

**Advantages:** Simple to implement; no lost flits; no explicit flow control messages required.

**Disadvantages:** Backpressure propagates stalls across the network. A congested output on Router_C stalls all traffic through Router_B, including traffic destined for Router_D (a different output). This is HOL blocking extended to the network level. Stall propagation can create back-pressure trees that throttle distant unrelated traffic.

**Credit-based flow control:**

Credit-based flow control maintains per-link credit counters that track available buffer space in the downstream router. Before sending a flit, the upstream router checks that a credit is available. After the downstream router consumes a flit from its buffer, it returns a credit to the upstream router.

```
Initial state: Router_A has 8 credits (= Router_B's buffer depth)
Flit sent: Router_A credit count → 7
Flit consumed downstream: Router_B returns credit → Router_A credit → 8
When credits = 0: Router_A stalls (does not send) without backpressure
```

**Advantage over backpressure:** The upstream router knows in advance whether to send (based on its credit count) rather than discovering the downstream is full after injecting the flit. This prevents head-of-line blocking: a full buffer for destination A does not block traffic to destination B, because the credit count is per-destination.

**Disadvantage:** Credit return messages consume link bandwidth (typically a small fraction — 1 credit return per N flits). Credit counters add state per link per VC.

**Explicit Congestion Notification (ECN):**

ECN is a rate-reduction mechanism for best-effort traffic. When a router detects early congestion (buffer occupancy above a threshold, but not yet full), it sets a congestion flag in passing flits. The destination endpoint forwards the congestion signal to the source endpoint, which reduces its injection rate.

```
Router_B buffer: 6/8 entries occupied → ECN threshold = 75% → set ECN bit
Destination receives flit with ECN bit set
Destination sends congestion notification to source
Source reduces injection rate by 25% for the next 1 ms
```

**Comparison:**

| Mechanism | Response to congestion | Granularity | Latency to act | HOL blocking |
|---|---|---|---|---|
| Backpressure | Stall immediately | Per link | 0 cycles (instantaneous) | Yes |
| Credit-based | Pre-stall (never injects when credit=0) | Per link per VC | N/A (preventive) | No |
| ECN | Rate reduction (gradual) | End-to-end flow | Round-trip latency | No |

**Production usage:**

Commercial NoC implementations (Arm CMN-700, Arteris FlexNoC) combine all three:
- Credit-based flow control at every router hop (within the NoC)
- Backpressure from the destination agent when its local buffers are full
- ECN or congestion notification signals for long-lived flows to reduce source injection rate and allow congestion to drain

---

## Quick Reference: QoS and Bandwidth Management

| Concept | Definition | Implementation |
|---|---|---|
| QoS tag | Priority indicator carried with each transaction | ARQOS/AWQOS[3:0] in AXI4 |
| Token bucket | Rate limiter with burst tolerance | Credits at rate r, depth B |
| Leaky bucket | Smooth traffic to constant rate | Fixed-rate release from queue |
| WRR | Bandwidth allocation by weight | Credit counts per class |
| DRR | Byte-proportional bandwidth | Quantum per class, byte-counted |
| HOL blocking | Earlier transaction blocks later transactions in shared queue | Eliminated by VOQ |
| VOQ | Per-destination queues | M×N queues in crossbar |
| Backpressure | Downstream full → upstream stall | ready signal deasserted |
| Credit flow control | Pre-stall based on downstream buffer state | Per-link credit counters |
| ECN | Early congestion → source rate reduction | Congestion bit in flit header |

| Formula | Meaning |
|---|---|
| Token rate = BW / beat_bytes | Tokens per second for token bucket at given bandwidth |
| Bucket depth = burst_bytes / beat_bytes | Tokens for burst tolerance |
| Replenishment period = 1 / token_rate × f_clk | Cycles between token additions |
| HOL latency overhead = N_ahead × T_service | Extra latency from N blocked transactions |
| Bisection BW ≥ 2× DRAM BW | Rule of thumb for interconnect capacity headroom |
