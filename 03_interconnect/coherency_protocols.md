# Coherency Protocols

## Overview

Cache coherency is the property that all processors in a multi-core system observe a single, consistent view of memory. Without it, one CPU can write a value to its private cache, another CPU can read a stale copy of the same address from its own cache, and the two CPUs will compute on inconsistent data — producing silent data corruption with no exception or fault.

Coherency protocols are the hardware mechanisms that maintain this consistency. They operate at the interconnect layer: every cache line read, write, invalidate, and upgrade transaction is coordinated by the protocol to ensure that at any given moment, all copies of a cache line across all caches are in a consistent state.

This document covers write-through and write-back policies, invalidation-based vs update-based protocols, the MESI and MOESI state machines, directory-based coherency for large-scale systems, snoop filter design, and the coherency mechanisms in AMBA CHI — the production protocol for modern ARM-based SoCs.

---

## Tier 1: Fundamentals

### Q1. Define cache coherency. State the two invariants a coherent memory system must maintain.

**Answer:**

Cache coherency is the guarantee that all caches in a multi-processor system present a consistent view of each memory location. Formally, a memory system is coherent if and only if two invariants hold:

**Invariant 1 — Write propagation:**

A write to location X by processor P must eventually become visible to all other processors. It is not sufficient for P's own subsequent reads to observe the write; every other processor Q must also observe P's write when Q reads X, after a sufficient number of subsequent memory operations.

**Invariant 2 — Write serialisation:**

All writes to the same location X must be observed in the same order by all processors. If processor P writes value A to X, and then processor Q writes value B to X, every processor in the system must observe first value A and then value B when reading X. No processor may observe value B before value A, and no processor may observe A after observing B.

**Write serialisation is subtler than write propagation:**

Write propagation says writes eventually reach everyone. Write serialisation says all writes to a single location are seen in the same total order by everyone. A system that satisfies write propagation but not write serialisation can cause a processor to observe writes in a different order from another processor — violating coherency even though the writes are eventually visible.

**Example of a violation:**

P1 writes X=1. P2 writes X=2. Write propagation ensures both writes reach P3 and P4. Write serialisation ensures both P3 and P4 observe X=1 then X=2 (not P3 seeing X=1, X=2 and P4 seeing X=2, X=1).

**Relationship to memory consistency:**

Coherency is a per-location property: it governs the ordering of accesses to a single address. Memory consistency is a multi-location property: it governs the ordering of accesses across different addresses (e.g., whether a write to X followed by a write to Y is seen in that order by another processor). A coherent system may still have a relaxed memory consistency model. The two properties are orthogonal.

---

### Q2. What is the difference between write-through and write-back cache policies? How does each interact with a coherency protocol?

**Answer:**

**Write-through:**

On a cache write hit, the write is propagated to the next level of the memory hierarchy (typically the L2 cache or DRAM) in the same cycle. The cached copy and the backing store are always synchronised after any write. On a cache eviction, no write-back is required because the backing store is already up to date.

**Coherency interaction:** Write-through simplifies coherency. When one processor writes, the updated value immediately flows to the shared backing store. Other processors can read from the shared backing store on the next access and see the updated value. A simple snooping scheme that broadcasts writes to all caches suffices.

**Cost:** Every write generates a transaction to the backing store, even if the same address is written many times (e.g., loop counters, local variables). This generates high write traffic on the interconnect and limits write performance.

**Write-back:**

On a cache write hit, the cache line is marked dirty (modified) but the backing store is not updated. The updated value remains in the cache. The backing store is only updated when the dirty cache line is evicted (written back) or when another processor requests the line.

**Coherency interaction:** Write-back requires a more complex coherency protocol. The dirty line in one processor's cache is the only valid copy of the data. If another processor tries to read or write the same address:
1. The protocol must detect that a dirty copy exists elsewhere
2. The owning cache must either supply the data directly to the requesting cache (cache-to-cache transfer) or write the data back to memory first
3. The owning cache's copy is then either invalidated or downgraded

This requires explicit state tracking (which cache owns a dirty copy) and snoop or directory mechanisms to locate dirty copies.

**Write-back performance advantage:**

For a cache line written N times before eviction, write-through generates N backing-store writes. Write-back generates 1. For a write-intensive loop running at 3 GHz with 1 write/cycle to the same cache line, write-through would saturate the L2 write bandwidth at 8 bytes × 3 GHz = 24 GB/s per core. Write-back reduces this to 64 bytes per cache line eviction, roughly every 1–10 million cycles — negligible bandwidth.

**Production choice:** All modern out-of-order processors use write-back caches with an invalidation-based coherency protocol (MESI or MOESI). Write-through is used only for memory-mapped I/O regions and device memory where software explicitly marks pages as write-through via the MMU.

---

### Q3. Describe the four states of the MESI coherency protocol. Draw the state transition diagram for a single cache controller.

**Answer:**

**MESI states:**

| State | Abbreviation | Meaning |
|---|---|---|
| Modified | M | This cache has the only valid copy; it is dirty (different from memory) |
| Exclusive | E | This cache has the only valid copy; it is clean (matches memory) |
| Shared | S | This cache has a valid copy; other caches may also have valid copies; line matches memory |
| Invalid | I | This cache has no valid copy of this line |

**State transition diagram:**

Transitions are driven by two event types:
- **Processor events:** load (Ld) or store (St) by the local CPU
- **Bus/snoop events:** read (BusRd), read-exclusive (BusRdX), or write-back (BusWB) observed on the interconnect from other caches

```
                    ┌─────────────────────────────────────────┐
                    │           MESI State Machine             │
                    │          (single cache controller)       │
                    └─────────────────────────────────────────┘

State: INVALID (I)
  ─── Ld (cache miss) ──────────────────► SHARED (or EXCLUSIVE if no other sharers)
  ─── St (cache miss) ──────────────────► MODIFIED (send BusRdX, invalidate others)

State: SHARED (S)
  ─── Ld (cache hit) ───────────────────► SHARED (no transition, serve from cache)
  ─── St (cache hit) ───────────────────► MODIFIED (send BusUpgr or BusRdX)
  ─── BusRd (snoop from other) ─────────► SHARED (no action, other sharer added)
  ─── BusRdX (snoop from other) ────────► INVALID (other cache takes exclusive, invalidate)

State: EXCLUSIVE (E)
  ─── Ld (cache hit) ───────────────────► EXCLUSIVE (silent hit)
  ─── St (cache hit) ───────────────────► MODIFIED (silent upgrade, no bus transaction)
  ─── BusRd (snoop from other) ─────────► SHARED (supply data, downgrade to S)
  ─── BusRdX (snoop from other) ────────► INVALID (supply data, invalidate)

State: MODIFIED (M)
  ─── Ld (cache hit) ───────────────────► MODIFIED (silent hit)
  ─── St (cache hit) ───────────────────► MODIFIED (silent hit)
  ─── BusRd (snoop from other) ─────────► SHARED (write back to memory, supply data)
  ─── BusRdX (snoop from other) ────────► INVALID (write back to memory, supply data)
  ─── Eviction ────────────────────────► INVALID (write back to memory, BusWB)
```

**Key properties of MESI:**

- The E state is an optimisation over a 3-state MSI protocol. In MSI, a line that transitions from I to S (because no other cache has it, but the protocol cannot confirm this) must issue a bus upgrade (I→M requiring a BusRdX) on the first write. With the E state, if the interconnect confirms no other sharer exists, the line enters E. A subsequent store upgrades silently E→M without a bus transaction — saving one coherency transaction for the common case of private data.

- A cache line can be in state M in at most one cache at any time. Shared state (S) can exist in multiple caches simultaneously, but all S copies must match memory (a dirty Modified line must first be written back before others can enter S).

---

## Tier 2: Intermediate

### Q4. Describe the MOESI protocol. What does the Owned state add, and what is its performance benefit?

**Answer:**

**MOESI adds a fifth state — Owned (O):**

| State | Meaning |
|---|---|
| Modified (M) | Unique dirty copy; owner is responsible for supplying data on any snoop |
| Owned (O) | Dirty copy shared with other caches; this cache is responsible for supplying data and eventually writing back to memory |
| Exclusive (E) | Unique clean copy |
| Shared (S) | Clean copy; other caches may share |
| Invalid (I) | No valid copy |

**The performance benefit of Owned:**

In MESI, when a processor in state M receives a BusRd (another processor wants to read the line):
1. The M-state cache must write back the dirty line to memory (a write transaction)
2. Memory supplies the data to the requester
3. Both caches transition to S

This requires a write to memory for every M→S transition, even if the line will be written again shortly by the original owner.

In MOESI, the M-state cache instead:
1. Supplies the dirty data **directly** to the requesting cache (cache-to-cache transfer, no write to memory)
2. The supplying cache transitions to O (Owned)
3. The requesting cache receives the data and enters S
4. Memory is **not updated** at this point — the O-state cache retains responsibility for the dirty data

The write to memory is deferred until the O-state cache evicts the line or a BusRdX forces an invalidation. This avoids a full memory write on each M→S transition.

**MOESI state for the requester:**

In MOESI, a cache receiving data from an O-state cache enters S state (knows data is dirty, but it is the O-state cache's responsibility to maintain it). An alternative optimisation allows the requester to enter O directly if the original O-state cache relinquishes ownership — this is implementation-defined.

**When MOESI benefit matters most:**

Consider a producer-consumer pattern where P1 repeatedly writes a buffer and P2 repeatedly reads it:

- MESI: each read by P2 triggers M→S: P1 writes dirty line to memory, memory supplies P2. Memory bandwidth = 2 × cache line per producer-consumer handoff.
- MOESI: P1 supplies dirty data directly to P2, transitions P1→O. No memory write. Memory bandwidth = 0 per handoff (until eviction).

For applications with high producer-consumer sharing (e.g., graphics pipelines, audio buffers, ring buffers between cores), MOESI can halve the memory bandwidth consumption.

**Production use:** MOESI is used in AMD's Opteron/EPYC processor families. ARM's AMBA 5 CHI protocol implements an equivalent mechanism through the Unique Clean/Unique Dirty/Shared Clean/Shared Dirty state machine, which subsumes both MESI and MOESI.

---

### Q5. What is a snoop filter, and why is it necessary in a large multi-core system?

**Answer:**

**Broadcast snooping and its scaling problem:**

The original cache coherency implementation broadcasts every coherency transaction to all caches. Each cache examines the transaction's address against its own tags and responds if it has a matching line. This works well for 2–4 cores: the broadcast overhead is a small fraction of total traffic.

For 16 or 64 cores, broadcasting every coherency request to every cache:
1. Generates $N - 1$ snoop messages per transaction (one to each other cache)
2. Each cache must search its tag array on every snoop (power cost)
3. The snoop traffic grows as $O(N^2)$ with the number of cores
4. The interconnect must sustain the snoop broadcast bandwidth in addition to data traffic

At 64 cores, a 64-byte cache line read from a shared address generates 63 snoop requests. If 8 cores issue coherency requests simultaneously: 8 × 63 = 504 concurrent snoop messages. This overwhelms the interconnect at scale.

**Snoop filter:**

A snoop filter (also called a snoop directory or point-of-coherency filter) is a centralised or distributed structure that tracks which caches hold copies of each cache line. When a coherency request arrives, instead of broadcasting to all caches, the interconnect consults the snoop filter to determine exactly which caches have the line and sends snoops only to those caches.

**Snoop filter structure:**

The snoop filter is a tag-array, typically SRAM-based, organised as a directory with one entry per cache line address. Each entry contains:

- Tag: the upper address bits identifying the cache line
- Presence bits: one bit per cache (for $N$ caches, $N$ bits per entry), set if that cache holds a copy
- State bits: the coherency state of the line in the system (equivalent to the per-line state in the full directory protocol)

**Sizing example:**

For 16 cores, 1 MB L2 per core, 64-byte cache lines, 32-byte tag + state overhead per entry:
- Lines tracked per core: 1 MB / 64 B = 16,384 lines
- Total lines in system: 16 × 16,384 = 262,144 lines
- Per-entry size: 32-bit tag + 16 presence bits + 4 state bits = 52 bits ≈ 8 bytes
- Snoop filter size: 262,144 × 8 bytes = 2 MB

This is a substantial but feasible SRAM investment (typically implemented as part of the LLC or as a standalone coherency engine in an SoC).

**Snoop filter operation:**

```
Read miss at Core 3, address A:
1. Core 3 sends ReadShared request to snoop filter
2. Snoop filter looks up address A:
   - Entry present: presence bits = {Core_1: 1, Core_7: 1, others: 0}
   - State: Shared
3. Snoop filter sends snoop only to Core_1 and Core_7
4. Core_1 and Core_7 respond (data supplied or acknowledgement)
5. Snoop filter updates presence bits: add Core_3 bit
6. Core_3 receives data, enters Shared state
```

Without a snoop filter, step 3 would have required snooping all 15 other cores. With a snoop filter, only 2 caches are snooped — an 87% reduction in snoop traffic.

**Snoop filter replacement policy:**

When the snoop filter is full and a new entry must be added, an existing entry must be evicted. The eviction requires sending invalidation snoops to all caches with presence bits set for the evicted line (to force them to either write back or discard the line). This ensures the snoop filter accurately reflects cache contents. LRU replacement is standard; some implementations use pseudo-LRU for area efficiency.

---

### Q6. Describe directory-based coherency. How does it differ from snooping, and when is it preferred?

**Answer:**

**Snooping coherency:**

Snooping relies on shared broadcast medium (bus or shared network) where every cache observes every coherency transaction. Coherency state is distributed: each cache maintains its own per-line state, and the correct system-level state is implicit in the combination of all individual cache states.

**Snooping limitations:**
- Requires a globally ordered broadcast medium (all caches see transactions in the same order)
- Broadcast traffic scales as O(N²) with core count
- Not suitable for non-uniform topologies (e.g., multi-socket NUMA systems) where a global broadcast is impossible or prohibitively expensive

**Directory-based coherency:**

A directory centralises (or distributes) the coherency state. The directory stores, for each cache line in the system, the current coherency state and the identity of all caches that hold the line. Coherency transactions are point-to-point: a cache sends a request to the directory, the directory looks up the line's state and sharers, and issues targeted snoop messages only to the relevant caches.

**Directory operation example — ReadShared:**

```
Core A reads line X:
1. Core A sends ReadShared to directory (home node for address X)
2. Directory lookup: X is in M state at Core B
3. Directory sends Snoop(ReadShared) to Core B
4. Core B responds:
   a. Sends data to Core A (or to directory for forwarding)
   b. Transitions M → S (or M → I if directory uses strict sharing rules)
5. Directory updates entry: X is now S at {Core A, Core B}
6. Core A enters S state, completes load
```

No broadcast is required. The directory handles all coordination through point-to-point messages.

**Directory structure:**

Full directory: one entry per cache line in the entire memory. For a 16 GB system with 64-byte cache lines: 16 GB / 64 = 268 million entries. At 4 bytes per entry (presence bits + state): 1 GB of directory storage — prohibitively large.

**Practical alternatives:**

- **Limited directory (Dir_i/B):** Only $i$ presence bits per entry, tracking up to $i$ sharers. If a ($i+1$)-th sharer arrives, one existing sharer is broadcast-invalidated to make room. Limits sharer tracking to i caches.
- **Sparse directory:** Only tracks cache lines that are currently present in one or more caches. Entries are allocated on first demand and freed on eviction. Much smaller than a full directory for typical working sets; used in Arm CHI home nodes.
- **Hierarchical directory:** Directory is distributed, with each memory controller managing the directory for its local memory region. Requests to remote memory cross the interconnect; requests to local memory are handled locally. This is the standard structure for multi-socket NUMA systems.

**Snooping vs directory comparison:**

| Property | Snooping | Directory |
|---|---|---|
| Scalability | Poor (O(N²) broadcast) | Good (point-to-point, O(N)) |
| Latency | Low (parallel response) | Moderate (directory round-trip) |
| Topology requirement | Shared ordered medium | Any interconnect topology |
| State storage | Distributed in each cache | Centralised/distributed directory |
| Core count sweet spot | 2–16 | 8–1024+ |
| Implementation complexity | Lower | Higher |

**When to prefer directory:**

Directory-based coherency is preferred for: (a) systems with more than 16 cores, (b) multi-socket NUMA systems where a global broadcast medium does not exist, (c) heterogeneous SoCs where the coherency domain includes CPUs, GPUs, and accelerators on different physical dies. Arm AMBA 5 CHI (Coherent Hub Interface) uses a hybrid: a snoop filter at the Home Node implements directory-based coherency with targeted snoops on a mesh NoC.

---

## Tier 3: Advanced

### Q7. Walk through the AMBA CHI state machine for a ReadUnique transaction issued by a Requester Node when the target line is in Shared state in two other caches. Identify every message type, the roles of the Home Node and the Snoop Filter.

**Answer:**

**AMBA CHI roles:**

- **Requester Node (RN):** A CPU cache controller initiating a transaction
- **Home Node (HN):** The component responsible for a specific memory address range; manages the directory (snoop filter) and ordering for that range
- **Slave Node (SN):** The memory controller (DRAM) for the address range

**Initial state:**

- Line X is in Shared Clean state in Core_A (RN-A) and Core_B (RN-B)
- Directory at HN: line X is SharedClean, presence bits {RN-A, RN-B} set

**ReadUnique transaction (Core_C needs to write to line X):**

**Step 1: Core_C issues ReadUnique to HN**

```
RN-C → HN: ReadUnique(addr=X, srcID=RN-C, txnID=42)
  Channel: REQ
  Purpose: "I need exclusive ownership of line X for a write"
```

**Step 2: HN looks up snoop filter**

The HN's snoop filter finds line X is SharedClean at {RN-A, RN-B}. Since the line is shared and RN-C needs unique (exclusive dirty) ownership, HN must invalidate all existing sharers.

**Step 3: HN sends SnpUnique to both existing sharers**

```
HN → RN-A: SnpUnique(addr=X, fwdNID=RN-C)
HN → RN-B: SnpUnique(addr=X, fwdNID=RN-C)
  Channel: SNP
  Purpose: "Invalidate your copy; if you have dirty data, forward it to RN-C"
```

**Step 4: RN-A and RN-B respond**

Since the line is SharedClean (no dirty data), both caches simply invalidate:

```
RN-A → HN: SnpRespUnique(txnID, RESP=I, DataTransfer=0)
RN-B → HN: SnpRespUnique(txnID, RESP=I, DataTransfer=0)
  Channel: RSP
  Purpose: "I have invalidated; I did not forward data (clean)"
```

**Step 5: HN waits for all snoop responses**

HN must receive responses from all snooped caches before proceeding. This serialisation point ensures all sharers acknowledge invalidation before the new owner gets write permission.

**Step 6: HN fetches data from memory and responds to RN-C**

Since neither sharer forwarded data (both were clean), HN reads line X from the Slave Node (DRAM):

```
HN → SN: ReadNoSnp(addr=X)       [internal, may be omitted if HN caches it]
SN → HN: ReadNoSnpResp(data=X)
```

HN then grants RN-C exclusive ownership and sends the data:

```
HN → RN-C: CompData(txnID=42, data=X, RESP=UC)  [UniqueClean]
  Channel: DAT
  Purpose: "You have exclusive ownership; here is the current data"
```

**Step 7: HN updates snoop filter**

Directory entry for line X: state = UniqueDirty, present at {RN-C only}.

**Step 8: RN-C stores into the line**

RN-C transitions its cache line from Invalid to UniqueClean (on receipt of CompData), then the CPU store upgrades it to UniqueDirty — without another network transaction, because RN-C already has exclusive ownership.

**Message count summary:**

| Step | Message | Channel | Count |
|---|---|---|---|
| RN-C request | ReadUnique | REQ | 1 |
| HN to sharers | SnpUnique × 2 | SNP | 2 |
| Sharers to HN | SnpRespUnique × 2 | RSP | 2 |
| HN to memory | ReadNoSnp | (internal) | 1 |
| Memory to HN | ReadNoSnpResp | (internal) | 1 |
| HN to RN-C | CompData | DAT | 1 |
| **Total** | | | **8 messages** |

**If the line had been UniqueDirty at RN-A (not Shared):**

Step 2 would find UniqueDirty at RN-A. HN sends SnpUnique to RN-A only. RN-A forwards the dirty data directly to RN-C (cache-to-cache transfer, reducing memory bandwidth). RN-A transitions to Invalid. HN updates the directory. This reduces memory bandwidth at the cost of one additional message (the forward).

**Key CHI protocol properties illustrated:**

1. The HN serialises all coherency operations: ReadUnique cannot complete until all SnpUnique responses are received, preventing two RNs from concurrently believing they have exclusive ownership.
2. The snoop filter avoids broadcasting to all RNs — only {RN-A, RN-B} are snooped.
3. Separate channels (REQ, SNP, RSP, DAT) are carried on separate virtual channels in the NoC, preventing protocol deadlock.

---

### Q8. What is a false sharing problem? Describe how to detect it and explain how the interconnect and memory system interact to make its performance impact severe.

**Answer:**

**Definition:**

False sharing occurs when two processors repeatedly write to different variables that happen to reside in the same cache line. From the coherency protocol's perspective, the two processors are sharing the same cache line even though they are using independent data. The protocol must treat the writes as conflicting and ping-pong the cache line between the two processors, generating coherency traffic for accesses that are logically independent.

**Example:**

```c
// Struct with two counters used by different threads
struct Counters {
    volatile int counter_A;  // thread 0 writes this
    volatile int counter_B;  // thread 1 writes this
};
struct Counters cnt;
```

Assuming 64-byte cache lines and `sizeof(int) = 4`: both `counter_A` and `counter_B` are within the same 64-byte cache line (they are only 4 bytes apart).

**Sequence of events (false sharing, MESI):**

```
Initial: cache line [counter_A | counter_B] is Invalid in both caches

Step 1: Thread 0 (Core A) writes counter_A
  → Core A: ReadUnique → line enters Modified at Core A
  → counter_A updated; counter_B unchanged

Step 2: Thread 1 (Core B) writes counter_B
  → Core B: ReadUnique → snoop invalidates Core A's Modified copy
  → Core A must write back the ENTIRE cache line (including counter_A) to memory
  → Core B: line enters Modified at Core B
  → counter_B updated; counter_A data is "borrowed" from Core A's write-back

Step 3: Thread 0 writes counter_A again
  → Core A: ReadUnique → snoop invalidates Core B's Modified copy
  → Core B writes back the entire cache line to memory
  → Core A: line enters Modified again
  → And so on...
```

**Performance impact:**

Each write by either thread forces a full cache line invalidation and write-back cycle on the other core:

- Each write generates: 1 snoop, 1 write-back to memory (64 bytes), 1 ReadUnique round-trip
- At 3 GHz with tight inner loops (1 write/cycle): 3 × 10^9 write-backs per second × 64 bytes = 192 GB/s — equivalent to consuming the full DRAM bandwidth just for two counters

In practice the impact is detected as: (a) very high cache miss rate on a hot line despite no actual sharing, (b) high coherency traffic in performance counters, (c) performance that degrades super-linearly as thread count increases.

**Interconnect interaction:**

The severity of false sharing depends on the coherency latency round-trip:

- Each invalidation cycle = ReadUnique latency + WriteBack latency
- On a 2D mesh NoC: 6-hop worst case × 3 cycles/hop = 18 cycles interconnect, plus DRAM latency (~60 ns), plus snoop filter lookup (~10 cycles)
- Total round-trip: ~200 cycles = 67 ns at 3 GHz
- Maximum throughput: 3 GHz / 200 cycles = 15 million writes per second per thread
- This is 200× slower than a non-shared write (which completes in 1 cycle in the local cache)

**Detection:**

Hardware performance counters: look for L1/L2 cache miss rate that does not decrease with larger working sets, combined with high HITM (Hit Modified) events (Intel PMU event) which count invalidations of modified cache lines.

Tools: Intel VTune "Memory Access" analysis, Linux `perf stat -e cache-misses,L1-dcache-load-misses`, compiler sanitisers.

**Fixes:**

1. **Padding:** Insert padding between the two variables to place them in separate cache lines:
   ```c
   struct Counters {
       volatile int counter_A;
       char padding[60];        // force counter_B to next cache line
       volatile int counter_B;
   };
   ```

2. **Alignment:** Use `alignas(64)` or `__attribute__((aligned(64)))` to align each variable to a cache line boundary.

3. **Thread-local storage:** If possible, give each thread its own copy of the counter and reduce (sum) at the end. This eliminates sharing entirely.

4. **Atomic accumulation with reduced frequency:** Use `atomic_fetch_add` but batch updates locally for N iterations before committing — amortising the coherency cost.

---

## Quick Reference: Coherency Protocols

| State (MESI) | M | E | S | I |
|---|---|---|---|---|
| Valid | Yes | Yes | Yes | No |
| Dirty | Yes | No | No | N/A |
| Unique copy | Yes | Yes | No | N/A |
| Shareable | No | No | Yes | N/A |

| Protocol | States | Cache-to-cache transfer | Write-back on share | Used by |
|---|---|---|---|---|
| MSI | 3 | No | Yes | Early MESI derivation |
| MESI | 4 | No | Yes (M→S) | Most x86 (Intel) |
| MOESI | 5 | Yes (O state) | No (deferred) | AMD EPYC, ARM |
| MESIF | 5 | Yes (F state) | No | Intel QPI |
| CHI | Multi-bit | Yes (forwarding) | Selective | ARM multi-core SoC |

| Key CHI message types | Meaning |
|---|---|
| ReadShared | Request read access; willing to share |
| ReadUnique | Request exclusive read-write access |
| SnpShared | Snoop: supply data, may retain Shared copy |
| SnpUnique | Snoop: supply data, must invalidate local copy |
| WriteBack | Evict Modified line back to Home Node |
| CompData | Home Node supplies data + completion to Requester |

| Concept | Formula / Rule |
|---|---|
| Snoop filter size | (Total cache capacity / cache line size) × (presence bits + state) bytes |
| False sharing penalty | (Coherency round-trip cycles) / (cache line size / variable size) |
| Directory storage (full) | (Memory size / cache line size) × (N presence bits + state) |
| Max MESI sharers in S | Unlimited (S state can exist in all N caches simultaneously) |
| Max MESI owners in M | Always exactly 1 |
