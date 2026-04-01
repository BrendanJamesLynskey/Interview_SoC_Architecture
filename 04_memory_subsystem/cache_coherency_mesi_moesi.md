# Cache Coherency: MESI and MOESI

## Overview

Cache coherency is one of the deepest topics in SoC interviews. Any multi-core design
with private caches must implement a coherency protocol to ensure that all processors
observe a consistent view of memory. Interviewers test understanding of state machines,
protocol transitions, snoop traffic, and the design trade-offs between MESI and MOESI.
The ability to trace a complete read-modify-write scenario through the protocol state
machine — without hesitation — is expected from senior candidates.

---

## Concept Reference

### The Coherency Problem

Consider two cores, Core 0 and Core 1, each with a private L1 cache:

```
Memory: addr X = 0x00

Core 0 reads X:  Core 0 cache holds X = 0x00
Core 1 reads X:  Core 1 cache holds X = 0x00
Core 0 writes X = 0xFF:  Core 0 cache now holds X = 0xFF
Core 1 reads X:  Without coherency, Core 1 returns X = 0x00 (STALE)
```

A coherent memory system guarantees that after Core 0's write is visible, any subsequent
read by Core 1 returns 0xFF — the correct value. This requires either **invalidation**
(Core 1's copy is marked invalid before Core 0 writes) or **update** (Core 1's copy
is overwritten with the new value).

**Coherency invariants (Lamport/Gharachorloo):**
1. **Single-writer invariant:** At any time, at most one cache may hold a line in writable state.
2. **Data-value invariant:** When a read is satisfied, it returns the value written by
   the most recent write to that location.

### MESI Protocol State Diagram

MESI is the standard four-state invalidation-based protocol used by Intel, ARM, RISC-V
systems, and most SoC interconnects.

**States:**

| State    | Line Valid? | Dirty? | Shared? | Who can modify? |
|----------|-------------|--------|---------|-----------------|
| Modified | Yes         | Yes    | No (exclusive) | This cache only |
| Exclusive | Yes        | No     | No (exclusive) | This cache (without bus transaction) |
| Shared   | Yes         | No     | Yes (possibly others) | No one (must upgrade first) |
| Invalid  | No          | —      | —       | No one          |

**MESI state machine (per cache line, per CPU):**

```
                    Local read hit
                    ┌─────────────┐
                    │             │
    BusRd (no one  ▼             │         BusRd (another CPU reads)
    else has it) ┌────┐          │         ─────────────────────────▶
    ─────────────▶ E  ◀──────────┘         Supply data (intervention)
                 └────┘                                │
                   │  │                                │
    Local write    │  │ BusRd (snoop: another           │
    ───────────    │  │ CPU reads our E line)           │
          │        │  │ → supply data, go to S         ▼
          ▼        │  └──────────────────────▶ ┌────┐
        ┌───┐      │                            │ S  │
        │ M │◀─────┘  Local write               └────┘
        └───┘  (upgrade: BusUpgr;                │  │
          │    invalidate others)                 │  │ Local read miss
          │                                       │  │ (another CPU has it)
          │ BusRd (snoop: another CPU reads)      │  │ ──────────────────▶
          │ → flush to memory/peer, go to S       │  │ Go to S
          ▼                                       │  │
        ┌───┐◀──────────────────────────────────  │  │
        │ I  │◀──────────────────────────────────┘  │
        └───┘  BusRdX / BusUpgr (invalidation)      │
          │    ─────────────────────────────────────┘
          │
          │ Local read (miss)
          │ Issue BusRd; go to E (if no sharers) or S (if sharers exist)
          ▼
      Back to E or S
```

**Transactions:**

| Bus Transaction | Issued By     | Meaning                                       |
|-----------------|---------------|-----------------------------------------------|
| BusRd           | Cache with miss | Request to read a cache line (shared or excl) |
| BusRdX          | Cache wanting to write | Request for exclusive ownership (read + invalidate others) |
| BusUpgr         | Cache in S state wanting to write | Upgrade S → M; invalidate other sharers |
| BusWB           | Cache evicting M line | Writeback dirty line to memory              |
| BusInv          | Cache in M/E wanting to write | Invalidate other caches' copies           |

### MOESI Protocol Extension

MOESI adds the **Owned (O)** state, allowing a Modified line to be shared without
writing back to memory first.

**Additional state:**

| State | Valid? | Dirty? | Shared? | Memory up-to-date? |
|-------|--------|--------|---------|---------------------|
| Owned | Yes    | Yes    | Yes (others may hold Shared copies) | No |

**Why Owned matters:**
In MESI, when Core 0 has a line in M state and Core 1 performs a BusRd:
- Core 0 must write the dirty line back to memory, then supply it to Core 1.
- Both transition to S (clean). Memory is updated.
- Cost: one memory write + one cache-to-cache transfer.

In MOESI, Core 0 transitions M → O, Core 1 enters S:
- Core 0 supplies the data directly to Core 1 (cache-to-cache transfer).
- Memory is NOT updated yet (line is still dirty — owned by Core 0).
- Cost: one cache-to-cache transfer only. Memory write deferred to eviction.

**Owned state obligations:**
The O-state cache is responsible for supplying the line to any future BusRd requests
and for writing the line back to memory on eviction. There is exactly one O-state
holder per line at any time.

**MOESI transitions (O state):**

```
M ──BusRd──▶ O   (another cache reads; supply data; remain responsible for writeback)
O ──BusRd──▶ O   (more caches read; supply data; stay in O)
O ──BusRdX─▶ I   (another cache takes exclusive ownership; transfer data; go invalid)
O (eviction) ──▶ write line to memory; remove from O state
S ──local write─▶ issue BusUpgr; if no M/O: go to M; if another has O: O-holder writes back
```

### MESI vs MOESI Comparison

| Scenario                         | MESI Traffic         | MOESI Traffic        | Winner  |
|----------------------------------|----------------------|----------------------|---------|
| Cold read (no sharer)            | BusRd + mem read     | Same                 | Tie     |
| Core A writes, Core B reads      | BusRd + WB to mem + read | BusRd + cache-to-cache | MOESI |
| Multiple readers after one writer | WB + read (each new reader) | Cache-to-cache (owner stays) | MOESI |
| Producer-consumer (write, then read by new owner) | BusRdX + WB | BusRdX + O→I | Near tie |
| Write-intensive (many writes, no sharing) | Standard M transitions | Same | Tie |

MOESI reduces memory traffic in sharing scenarios at the cost of more complex state
machine and the Owned obligation logic.

### Snoop Filter

In a system with many cores (16+), broadcasting every bus transaction to all cores
is expensive. A **snoop filter** (also called a coherency directory or tag directory)
caches information about which cores hold copies of each cache line.

**Snoop filter operation:**

```
On BusRd from Core 5, addr X:
  Snoop filter lookup: who has X?
  Result: Cores 2 and 7 have X in S state; no M state.
  Action: Forward BusRd to memory only; no need to interrupt Cores 2, 7.
          Update snoop filter: Core 5 added to sharers of X.

On BusRdX from Core 3, addr Y:
  Snoop filter: Core 1 has Y in M state.
  Action: Send targeted snoop to Core 1 only. Core 1 supplies data.
          Core 1 transitions M → I. Core 3 transitions I → M.
          Memory not accessed (Core 1 supplied the data).
```

**Snoop filter implementations:**
- **Inclusive directory:** The filter holds presence bits for every cache line in the
  system. Exact but large (many presence bits per entry for large core counts).
- **Limited directory:** Only tracks a fixed number of sharers per line; overflow evicts
  a sharer (sharer must be invalidated).
- **Duplicate tag directory:** A copy of all L1 cache tags kept at the L2/L3. On a
  snoop, only the L2 directory is consulted, not all L1 caches. Used by ARM CCI-400,
  CCI-500.

---

## Tier 1 — Fundamentals

### Q1. Name the four MESI states and their meanings. When is a line in each state?

**Answer:**

**Modified (M):**
The cache line has been written and is dirty — it differs from the memory copy.
This cache is the sole holder of a valid copy. Memory is stale. The cache is
responsible for servicing any future requests for this line and for writing the
data back to memory on eviction.

*When:* After a local write to a line that was in Exclusive or Modified state.

**Exclusive (E):**
The cache line matches memory exactly (clean). This is the only cache that holds
a copy. Because no other cache has a copy, this cache can write to the line without
issuing a bus transaction (transitions directly to M without a BusRdX).

*When:* After a read miss where no other cache had a copy of the line (the memory
controller or snoop filter confirms no sharers).

**Shared (S):**
The cache line is clean and may be present in one or more other caches. No cache
can write to a Shared line without first issuing a BusUpgr/BusRdX to invalidate
all other copies.

*When:* After a read miss when at least one other cache already had the line in M,
E, or S state. The supplying cache transitions to S (if it was in E); the M-state
cache flushes and may transition to S (MESI) or O (MOESI).

**Invalid (I):**
The cache line does not contain valid data. Any access to an Invalid line is a miss
and triggers a bus transaction.

*When:* Power-on default; after another cache issues BusRdX or BusUpgr for the same
line; after an explicit cache flush instruction.

---

### Q2. Trace the MESI state transitions for this scenario: Core 0 reads addr X; Core 1 reads addr X; Core 0 writes addr X; Core 1 reads addr X.

**Answer:**

Initial state: Both caches Invalid. Memory[X] = 0x00.

**Step 1: Core 0 reads addr X.**
- Core 0: I → issues BusRd. No sharer exists. Memory supplies data.
- Core 0: I **→ Exclusive** (sole holder, clean copy).
- Core 1: remains I.

**Step 2: Core 1 reads addr X.**
- Core 1: I → issues BusRd. Core 0 snoops and sees it has E.
- Core 0 may supply data (intervention) or allow memory to supply.
- Core 0: E **→ Shared** (another cache now has a copy).
- Core 1: I **→ Shared**.

**Step 3: Core 0 writes addr X = 0xFF.**
- Core 0 is in Shared → must invalidate other copies.
- Core 0 issues **BusUpgr** (upgrade, not a full BusRdX since Core 0 already has the data).
- Core 1 snoops BusUpgr: Core 1: S **→ Invalid**.
- Core 0: S **→ Modified** (writes to cache; memory is now stale).

**Step 4: Core 1 reads addr X.**
- Core 1: I → issues BusRd.
- Core 0 snoops BusRd and recognises it holds the dirty line (Modified).
- Core 0 asserts a stall on the bus (HITM — hit-to-modified).
- Core 0 flushes the line: writes 0xFF back to memory (or directly to Core 1's cache
  via cache-to-cache transfer, depending on implementation).
- Core 0: M **→ Shared** (MESI) or M **→ Owned** (MOESI).
- Core 1: I **→ Shared**.
- Core 1 reads X = 0xFF. Correct.

**Key insight:** Without step 3's invalidation of Core 1, Core 1 would have read
the stale value 0x00 in step 4. The BusUpgr is the mechanism that maintains coherency.

---

### Q3. What is the difference between BusRd and BusRdX? When is each used?

**Answer:**

**BusRd (Bus Read):**
Issued when a cache has a read miss (wants shared or exclusive read access).
The requesting cache does not intend to write to the line (at least not immediately).
Other caches may retain their copies if they are in S state; if any cache has M state,
it must supply the data.

*Use cases:* Any read miss — loading a variable, instruction fetch, read-only access.

**BusRdX (Bus Read Exclusive):**
Issued when a cache wants to write to a line it does not currently own exclusively.
The transaction simultaneously:
1. Fetches the current line data (if not already present).
2. Invalidates all other copies of the line in any other cache.

After BusRdX completes, the requesting cache is guaranteed to be the sole holder.

*Use cases:* Write miss (line not in cache at all) — BusRdX fetches and invalidates.
             Write to a Shared line — can use BusUpgr instead (cheaper, see below).

**BusUpgr (Bus Upgrade):**
A cheaper alternative to BusRdX when the requesting cache already has the line
in Shared state. The cache does not need to re-fetch the data (it already has it);
it only needs to invalidate all other sharers. BusUpgr sends an invalidation without
a data transfer, saving bus bandwidth.

```
Cache has line in S, CPU performs a store:
  BusUpgr: tells all other caches to invalidate their S copies.
  No data phase (requester already has the data).
  Requester: S → M.

vs.

Cache has line in I, CPU performs a store:
  BusRdX: fetches the data AND invalidates other caches.
  Data phase required (requester needs the data).
  Requester: I → M.
```

---

## Tier 2 — Intermediate

### Q4. What is the HITM (Hit to Modified) condition and how does it affect bus latency?

**Answer:**

**HITM** occurs when a cache with a line in Modified state detects that another cache
is performing a BusRd for the same address. The M-state cache must intervene because:
1. Memory holds a stale copy of the line.
2. If memory responds to the BusRd, the reading cache receives incorrect data.

**HITM sequence:**
1. Core 1 issues BusRd for addr X.
2. Memory begins responding (it sees the BusRd on the bus).
3. Core 0 snoops the BusRd and detects HITM (it has X in Modified state).
4. Core 0 **asserts HITM# on the bus** — a signal telling everyone that a modified
   copy exists and memory's response should be ignored or aborted.
5. Memory aborts its response.
6. Core 0 flushes the dirty line onto the bus (cache-to-cache transfer).
7. Core 1 receives the correct data. Core 1 goes to Shared.
8. Core 0 transitions M → Shared (MESI) or M → Owned (MOESI).

**Latency impact:**
A normal BusRd miss: memory latency (~200 cycles DRAM).
A HITM miss: the M-state core must write its dirty line to the bus. This is a
cache-to-cache transfer and is much faster (typically 5-20 cycles for L1-to-L1
over an L2 interconnect), but introduces the overhead of:
- Snoop detection latency (all caches must snoop simultaneously).
- HITM# assertion and bus turnaround.
- The M-state cache must pause whatever it was doing to perform the flush.

**In MOESI:** HITM leads to Owned state. The O-state cache provides data to all
future readers without memory involvement, reducing repeated HITM events.

---

### Q5. Design a MESI snoop controller at the block diagram level. What state must it maintain and what are the snoop response signals?

**Answer:**

A MESI snoop controller sits between the L1 cache tag array and the system bus. It
monitors all bus transactions and:
- Responds to transactions for lines it holds.
- Issues transactions on behalf of the local CPU.
- Updates the L1 tag state based on observed bus activity.

**State maintained per cache line (in the tag RAM):**
```
Per-line fields (in addition to tag bits and data):
  valid    : 1 bit  (line contains valid data)
  mesi     : 2 bits (00=Invalid, 01=Shared, 10=Exclusive, 11=Modified)
  dirty    : 1 bit  (could be derived from mesi==11, but explicit bit aids timing)
  tag      : N bits (address tag)
```

**Snoop response signals (driven onto the coherency bus):**

| Signal    | Meaning                                                       |
|-----------|---------------------------------------------------------------|
| SHARED#   | Asserted by any cache that has the line in S or E state. Tells the requester to enter S (not E). |
| HITM#     | Asserted by the M-state cache. Tells everyone the data in memory is stale; this cache will supply data. |
| STALL#    | Asserted during writeback operations; bus must wait before completing the transaction. |
| CLEAN     | Asserted when supplying data from E state (data matches memory; no WB needed). |

**Snoop controller block diagram:**

```
System Bus
    │
    │  BusRd / BusRdX / BusUpgr / BusWB
    ▼
┌──────────────────────────────────────────────────────┐
│                  Snoop Controller                      │
│                                                        │
│  ┌──────────────┐     ┌─────────────────────────┐     │
│  │ Bus Monitor  │────▶│ Tag Lookup (parallel    │     │
│  │ (decode txn) │     │ with tag RAM access)    │     │
│  └──────────────┘     └──────────┬──────────────┘     │
│                                  │ hit/miss, state     │
│                       ┌──────────▼──────────────┐     │
│                       │ Coherency State Machine  │     │
│                       │  - Assert SHARED# / HITM#│     │
│                       │  - Issue writeback       │     │
│                       │  - Update tag state      │     │
│                       └──────────┬──────────────┘     │
│                                  │                     │
│  ┌────────────────────────────┐  │                     │
│  │ L1 Tag / Data RAM          │◀─┘ state update        │
│  │ (valid, mesi, dirty, tag)  │                        │
│  └────────────────────────────┘                        │
└──────────────────────────────────────────────────────┘
    │
    ▼
CPU pipeline (hit/miss, stall, data)
```

---

### Q6. Explain the false sharing problem in MESI. How does padding eliminate it?

**Answer:**

**False sharing** occurs when two cores repeatedly write to different variables that
share the same cache line. Even though the cores are writing to distinct memory
locations, the MESI protocol treats the entire line as the shared unit.

**Example with 64-byte cache lines:**
```c
// Shared counter array
int counters[16];  // 16 * 4 = 64 bytes = exactly one cache line

// Core 0 increments counters[0]
// Core 1 increments counters[1]
```

Both `counters[0]` and `counters[1]` reside in the same 64-byte cache line.

**Sequence:**
1. Core 0 writes counters[0]: issues BusRdX; Core 1 → Invalid.
2. Core 1 writes counters[1]: issues BusRdX; Core 0 → Invalid.
3. Repeat. Every iteration generates a BusRdX from both cores.
4. Despite no actual data sharing, the ping-pong invalidation causes cache line
   traffic equivalent to massive true sharing.

**Performance impact:** Can reduce throughput by 10x–100x compared to cores accessing
genuinely independent memory locations.

**Elimination by padding:**
```c
// Padded to force each counter onto its own cache line
struct alignas(64) padded_counter {
    int value;
    char pad[60];  // Padding to fill the 64-byte cache line
};

padded_counter counters[16];
// Core 0 writes counters[0].value: its own line, no sharing.
// Core 1 writes counters[1].value: different line, no invalidation traffic.
```

**Alternative:** Use thread-local storage so each core has its own copy and a
periodic reduction merges results.

**Detection:** Hardware performance counters (HITM events, coherency miss rate)
and tools like Intel VTune Amplifier or perf c2c highlight cache lines with
high false-sharing traffic.

---

## Tier 3 — Advanced

### Q7. Compare snooping bus protocols with directory protocols. At what point does a directory become necessary and why?

**Answer:**

**Snooping protocols** rely on a shared bus. Every cache controller monitors all
bus transactions. The bus provides a globally ordered sequence of transactions —
the bus serialization naturally enforces a total order, which MESI exploits to
maintain coherency.

**Why snooping fails at scale:**
- A shared bus has finite bandwidth. With N cores, each generating C cache misses/second,
  the bus must handle N * C transactions per second.
- Bus serialization is a single point of contention: only one transaction at a time.
- Broadcast: every BusRd/BusRdX is seen by all N caches, even if N-1 of them
  have no copy. Snoop energy = N * (transaction rate).

**Approximate scaling limit:** 16-32 cores for a single-bus design before coherency
bus bandwidth exceeds memory bandwidth and becomes the bottleneck.

**Directory protocols** replace the broadcast bus with a directory that records
which caches hold each line (as a presence vector or limited sharer list).

```
Core 5 issues a read miss for addr X:
  1. Request sent to home node (the node that owns addr X's memory).
  2. Directory lookup: Cores 2 and 7 hold X in Shared state.
  3. Directory sends data from memory to Core 5. No interruption of Core 2 or Core 7.
  4. Directory updates presence vector: Core 5 added.

Core 3 issues a write (BusRdX) for addr X:
  1. Request to home node.
  2. Directory: Cores 2, 5, 7 are sharers.
  3. Directory sends targeted invalidation to Cores 2, 5, 7 only.
  4. Cores 2, 5, 7 invalidate and acknowledge.
  5. Directory grants exclusive ownership to Core 3.
  6. Total messages: 1 (request) + 3 (invalidations) + 3 (acks) + 1 (grant) = 8.
  7. In a 128-core snooping bus: 128 snoop messages per transaction.
```

**Directory overhead:**
- N-bit presence vector per cache line: for 128 cores and 8 MB directory (LLC),
  that is 128 * (8M / 64) = 128 * 128K = 16M bits = 2 MB of directory storage.
- Sparse encoding (limited pointers): track only 8-16 sharers per line; on overflow,
  broadcast or use a coarse vector. ARM CCIX and Arm CMN-700 use this approach.

**NUMA and directory integration:**
In NUMA systems, the directory home node is determined by the physical address
(typically by interleaving across nodes). A remote memory access adds one extra hop
(local → home → memory), increasing coherency latency for remote lines.

---

### Q8. Describe the MOESI Owned state's role in a producer-consumer workload. When does it improve performance and when does it not?

**Answer:**

**Producer-consumer workload:**
A producer core writes a buffer and a consumer core reads it. If the buffer is large
enough that its cache lines are not evicted between production and consumption, the
sequence is:

```
1. Producer writes line X:      Modified (dirty, producer has exclusive ownership)
2. Consumer reads line X:       BusRd observed by producer
   MESI:  M → Shared, write back to memory, consumer reads from memory.
          Total: 1 memory write + 1 memory read per line.
   MOESI: M → Owned, cache-to-cache transfer to consumer (Shared copy).
          Memory NOT updated. Producer retains responsibility for writeback.
          Total: 1 cache-to-cache transfer per line. No memory involved.
```

**MOESI benefit:**
- Eliminates one memory write and one memory read per producer-consumer handoff.
- For a 64-byte cache line, saves 128 bytes of memory traffic.
- Critical in NUMA systems: memory writes are expensive (cross-node traffic).
- Measured speedup in producer-consumer benchmarks: 20-40% on memory-latency-bound
  workloads.

**When MOESI does NOT help:**
1. **Write-intensive with no sharing:** If the producer writes and never shares
   (writes large buffers that are only written, not read by others), MOESI adds
   complexity with no benefit. The M state is used throughout.

2. **Many readers:** If 8 cores all need to read the producer's line:
   - First BusRd: M → O, cache-to-cache to first reader. Good.
   - Subsequent BusRd: O-state cache must supply data each time (or memory supplies
     after the O-state cache writes back). If the O-state cache is evicted, it must
     write back to memory before eviction — the deferred writeback then happens.
   - With many readers, the O-state cache becomes a bottleneck for data supply.
   - Better solution: after M → O, the O-state cache writes back (transitioning to S)
     and lets memory serve subsequent readers. MOESI's benefit diminishes.

3. **Remote NUMA access:** Cache-to-cache transfers across NUMA nodes can be slower
   than reading from the local memory node if the NUMA fabric has higher bandwidth
   than the inter-node coherency link.

**Design guideline:** AMD processors (Zen architecture) implement MOESI in their L2/L3
coherency domain because producer-consumer and mutex patterns dominate their workload
mix. Intel processors use MESIF (where F = Forward, a specific sharer designated to
supply data — similar in concept to Owned) for similar reasons.
