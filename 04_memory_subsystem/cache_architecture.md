# Cache Architecture

## Overview

Cache design is one of the most frequently tested areas in SoC architecture interviews.
Every memory-system question eventually touches on cache geometry, write policy, and
replacement strategy. Interviewers test the ability to quantify trade-offs — not just
name them — and expect candidates to size a cache from first principles and explain
exactly what happens during a miss, eviction, and write-back.

---

## Concept Reference

### Address Decomposition

For any cache, a byte address is partitioned into three fields:

```
Address bits (from MSB to LSB):
  [ Tag | Index | Block Offset ]

Given:
  Cache capacity   C (bytes)
  Cache line size  L (bytes)   -- also called block size
  Associativity    N (ways)

  Number of sets   S = C / (N * L)
  Offset bits      = log2(L)
  Index bits       = log2(S)
  Tag bits         = address_width - index_bits - offset_bits
```

**Worked example:**

```
Cache: 32 KB, 4-way set-associative, 64-byte lines, 32-bit address.
  S = 32768 / (4 * 64) = 128 sets
  Offset bits = log2(64)  =  6
  Index bits  = log2(128) =  7
  Tag bits    = 32 - 7 - 6 = 19

Address [31:13] = tag (19 bits)
Address [12:6]  = set index (7 bits)
Address [5:0]   = block offset (6 bits)
```

### Cache Topologies Compared

| Property              | Direct-Mapped    | N-Way Set-Associative | Fully Associative   |
|-----------------------|------------------|-----------------------|---------------------|
| Sets                  | C / L            | C / (N * L)           | 1                   |
| Ways per set          | 1                | N                     | C / L               |
| Conflict misses       | High             | Reduced               | Zero                |
| Hardware complexity   | Simplest         | Moderate              | Complex (CAM)       |
| Access latency        | Single comparator| N comparators in //   | Full CAM lookup     |
| Replacement needed    | No               | Yes (N > 1)           | Always              |
| Typical use           | L1 I-cache tag   | L1/L2 data cache      | TLB, victim cache   |

### Write Policies

**Write-through:**
Every store is written to cache AND to the next memory level simultaneously. A write
buffer absorbs the latency so the CPU does not stall on every write.

- No dirty bit required.
- On eviction: no writeback needed (memory is always up-to-date).
- Memory bandwidth consumed by all write traffic, even hot variables in a loop.
- Simplifies coherency: memory always holds the latest data.

**Write-back:**
Stores update only the cache line. A dirty bit marks lines that differ from memory.
The dirty line is written to the next level only when it is evicted.

- Dirty bit required per line.
- On eviction of a dirty line: writeback is mandatory before the line is replaced.
- Write bandwidth reduced dramatically for write-heavy workloads.
- Complicates coherency: another bus master reading the same address sees stale memory.

**Write-allocate (fetch-on-write):**
On a write miss, the missing cache line is first fetched from memory (allocated),
then the store is applied to the cache. Used with write-back.

**No-write-allocate (write-around):**
On a write miss, the data is written directly to the next level without fetching the
line into cache. Used with write-through. Avoids polluting the cache with data that
will only be written once.

### Replacement Policies

| Policy                       | How it Works                                                | Cost               | Use Case                          |
|------------------------------|-------------------------------------------------------------|--------------------|-----------------------------------|
| LRU (Least Recently Used)    | Evict the line last accessed furthest in the past           | Age counter or stack per set | L1/L2, moderate N       |
| Pseudo-LRU (PLRU)            | Binary tree approximation of LRU, one bit per pair of ways  | N-1 bits per set   | L1 in most commercial CPUs        |
| FIFO                         | Evict the line that has been in the set the longest         | 1 pointer per set  | Simple, predictable               |
| Random                       | Evict a randomly selected way                               | LFSR              | GPU caches, avoids thrashing corner cases |
| LFU (Least Frequently Used)  | Evict the line with the fewest accesses since last install  | Counter per line   | Rare in hardware; used in software caches |
| NRU (Not Recently Used)      | Reference bit cleared periodically; evict a line with bit=0 | 1 bit per line    | Approximation used in OS page replacement |

**LRU vs PLRU in hardware:**

True LRU for an N-way set requires tracking the exact order of N items. For N=4 this
needs 5 state bits per set (one of 24 orderings). For N=8 it needs ceil(log2(8!)) = 16
bits. Hardware cost grows rapidly.

PLRU uses a binary tree of N-1 bits per set. Each tree bit indicates which subtree was
accessed more recently. On a hit, bits on the path to the hit way are updated. On a miss,
evict the way indicated by the "stale" leaf. Widely used in ARM Cortex-A processors.

```
PLRU tree for 4-way (3 bits: B0, B1, B2):

           B0
          /    \
        B1      B2
       / \      / \
     W0  W1  W2  W3

B0=0: left subtree (B1) was more recently used
B0=1: right subtree (B2) was more recently used

On access to W2: set B0=1 (right), B2=0 (left of right = W2 is recent)
Eviction candidate: follow the "stale" path
  B0=0 -> go left -> B1=0 -> evict W0
  B0=1 -> go right -> B2=1 -> evict W3
```

### Cache Line Size Trade-offs

| Line Size | Spatial Locality Benefit | Miss Penalty   | False Sharing Risk | Tag Overhead   |
|-----------|--------------------------|----------------|-------------------|----------------|
| Small (16B) | Low                    | Low per miss   | Minimal           | Higher (more lines, more tags) |
| Moderate (64B) | Good balance       | Moderate       | Moderate          | Standard        |
| Large (256B) | High for streaming   | High; pollutes cache on random access | High | Fewer tags, lower overhead |

**False sharing:** Two CPU cores write different variables that happen to reside in the
same cache line. Each write invalidates the other core's copy, causing unnecessary traffic.
Larger lines increase the probability of false sharing.

### Cache Miss Categories (3Cs Model)

| Miss Type     | Cause                                               | Mitigation                          |
|---------------|-----------------------------------------------------|-------------------------------------|
| Compulsory    | First access to a line — data was never in cache    | Hardware/software prefetch          |
| Capacity      | Cache too small to hold the working set             | Increase cache size                 |
| Conflict      | Multiple addresses map to the same set, evicting valid lines | Increase associativity or use a victim cache |
| Coherency     | Cache line invalidated by another CPU's write       | Improve data partitioning; lock-free structures |

---

## Tier 1 — Fundamentals

### Q1. What are the three address fields in a cache lookup and how are they sized?

**Answer:**

Every cache access uses three address fields:

1. **Block offset:** Selects the byte (or word) within the cache line. If the line is
   L bytes, offset = log2(L) bits. For a 64-byte line: 6 offset bits.

2. **Index (set select):** Selects which set to search. If there are S sets, index =
   log2(S) bits. Index = log2(C / (N * L)) where C is cache size and N is associativity.

3. **Tag:** The remaining high-order bits. Stored in the tag RAM alongside the data.
   On a cache lookup, the tag stored for the indexed set is compared against the tag
   bits of the incoming address. A match (plus valid bit set) is a hit.

**Why the index selects the set and not the tag:**
The index is used to directly address the set storage (like a RAM address), making the
lookup O(1). The tag is checked only for the ways in the selected set, keeping comparison
hardware small.

**Common mistake:** Beginners sometimes confuse the offset with the index or forget to
account for associativity when computing the number of sets. Remember: S = C / (N * L),
and the index is log2(S), not log2(C / L).

---

### Q2. What is the difference between write-through and write-back? Which is preferred in a high-performance CPU and why?

**Answer:**

**Write-through:** Every cache write simultaneously writes to the next memory level.
The cache line is updated and the same data is immediately propagated downward.
Advantage: memory always holds the current value; dirty bit not needed; coherency
is simplified. Disadvantage: every store generates a memory write, even if the
same address is written 100 times before anyone reads it. A write buffer is needed
to decouple the CPU from memory latency.

**Write-back:** Stores go only to the cache. The dirty bit is set. The line is written
to memory only when it is evicted from the cache.
Advantage: multiple writes to the same line generate only one memory write (on eviction).
Write bandwidth is dramatically reduced. Disadvantage: on eviction of a dirty line,
a writeback must happen before the replacement allocation — adding latency to the
miss path. Coherency requires the dirty-line protocol (MESI/MOESI).

**High-performance CPUs use write-back** because:
- Modern workloads perform many writes to the same variable (counters, accumulators,
  stack frames) before those variables are ever evicted. Write-back coalesces those
  writes into one memory transaction.
- Write-through would saturate the L1-to-L2 bus in any write-intensive workload.
- The write-back miss penalty is manageable with out-of-order execution and miss
  status holding registers (MSHRs) that allow the CPU to continue executing while
  the writeback and allocation complete.

**Write-through is appropriate for:**
- Small, simple embedded caches where coherency hardware is undesirable.
- L1 instruction caches (typically read-only; write-through simplifies verification).
- Write-combining buffers for frame-buffer writes (streaming writes, not random reads).

---

### Q3. Explain a direct-mapped cache conflict miss. Give a concrete numerical example.

**Answer:**

In a direct-mapped cache, each memory address maps to exactly one cache line (one
possible slot). A conflict miss occurs when two addresses that map to the same slot
are accessed alternately, each evicting the other on every access.

**Example:**

```
Cache: 1 KB (1024 bytes), direct-mapped, 16-byte lines
  Number of lines = 1024 / 16 = 64
  Offset bits  = log2(16) = 4
  Index bits   = log2(64) = 6
  Address (16-bit): [15:10] tag | [9:4] index | [3:0] offset
```

Address A = 0x0040 -> binary 0000 0000 0100 0000
  Index = bits[9:4] = 000001 = 1, Tag = 0x00

Address B = 0x0440 -> binary 0000 0100 0100 0000
  Index = bits[9:4] = 000001 = 1, Tag = 0x01

Both A and B map to set index 1. Access pattern: A, B, A, B, A, B...
Every access misses because the previous access placed a different tag in slot 1.

**Miss rate = 100%** despite the cache having plenty of empty lines.

**Solutions:**
- Increase associativity to 2-way: A and B can coexist in set 1's two ways.
- Add a small fully-associative victim cache that captures recently evicted lines.
- Pad data structures so hot variables land in different sets (software mitigation).

---

### Q4. What is a cache hit rate and how does it affect system performance? Give the formula for average memory access time (AMAT).

**Answer:**

**Cache hit rate (h):** The fraction of memory accesses that are satisfied from cache.
A miss rate of (1 - h) requires fetching from the next level of the hierarchy.

**Average Memory Access Time (AMAT):**

```
AMAT = Hit_time + Miss_rate * Miss_penalty

For a two-level hierarchy (L1 and main memory):
  AMAT = T_L1 + (1 - h_L1) * T_mem

For a three-level hierarchy (L1, L2, DRAM):
  AMAT = T_L1 + (1 - h_L1) * [T_L2 + (1 - h_L2) * T_mem]
```

**Typical numbers (modern server-class CPU):**

| Level     | Hit time | Hit rate |
|-----------|----------|----------|
| L1 cache  | 4 cycles | 95%      |
| L2 cache  | 12 cycles | 98% (of L1 misses) |
| L3 cache  | 40 cycles | 80% (of L2 misses) |
| DRAM      | 200 cycles | — |

```
AMAT = 4 + 0.05 * [12 + 0.02 * (40 + 0.20 * 200)]
     = 4 + 0.05 * [12 + 0.02 * 80]
     = 4 + 0.05 * [12 + 1.6]
     = 4 + 0.05 * 13.6
     = 4 + 0.68
     = 4.68 cycles
```

Improving the L1 hit rate from 95% to 97% reduces AMAT by approximately
0.02 * 13.6 = 0.27 cycles per access — significant at billions of operations per second.

**Common mistake:** Forgetting to multiply correctly for a three-level hierarchy.
The L2 miss penalty includes the L3 lookup time, not just the DRAM time.

---

## Tier 2 — Intermediate

### Q5. Design a 4-way set-associative cache lookup circuit. What comparators are needed and how is the hit signal generated?

**Answer:**

For a 4-way set-associative cache with a 32-bit address (6-bit offset, 7-bit index,
19-bit tag):

**On every access:**
1. Use the 7-bit index to address the tag RAM. The tag RAM has four columns (one per
   way) and returns four 19-bit tags simultaneously: tag_way0, tag_way1, tag_way2, tag_way3.
2. The valid RAM (4 bits per set) returns valid bits: v0, v1, v2, v3.
3. Four comparators check incoming_tag == tag_wayN for each way.
4. Hit for way N: `hit_N = (incoming_tag == tag_wayN) && v_N`
5. Overall hit: `hit = hit_0 | hit_1 | hit_2 | hit_3`
6. The hit_N one-hot signal selects which of the four data RAM columns to read.

```
Address[31:13] ─────────────────┬──────────────────────────────────────────┐
                                 │  19-bit tag                              │
Address[12:6]  ──┬──────────────┼───────────────────────────────────────── │
                 │  7-bit index │                                           │
                 │              ▼                                           ▼
                 │   ┌──────────────────────────────────────┐     ┌────────────────┐
                 │   │          Tag RAM (128x76)            │     │  Comparators   │
                 └──▶│  [tag_w0][tag_w1][tag_w2][tag_w3]   │────▶│  ==tag? x4     │
                     │  [  v0  ][  v1  ][  v2  ][  v3  ]   │     └───────┬────────┘
                     └──────────────────────────────────────┘             │ hit_0..3
                 │                                                         │
                 │   ┌──────────────────────────────────────┐             │
                 └──▶│     Data RAM (128x256, 4 ways)       │◀────────────┘ (mux select)
                     └──────────────────────────────────────┘
```

**Critical path:** address decoding -> tag RAM read -> comparators -> mux select -> data
mux -> output. This is the L1 cache access latency.

**VIPT (Virtually Indexed, Physically Tagged):**
In practice, L1 caches use the virtual address index bits (bits below the page offset)
to start the tag RAM access while the TLB translates the upper bits. This hides the
TLB latency. The constraint: `index_bits + offset_bits <= page_offset_bits` (12 for
4 KB pages), which limits the L1 cache size to `2^12 * N_ways = 4 KB * N_ways`.
A 4-way VIPT L1 can be up to 16 KB with no aliasing.

---

### Q6. Compare LRU and pseudo-LRU replacement policies. Why does PLRU dominate in commercial L1 caches?

**Answer:**

**True LRU for N ways** requires tracking all N! possible orderings of N lines.
For N=2: 1 bit (0=way0 more recent, 1=way1). For N=4: 4 bits encode one of 24
orderings. For N=8: 16 bits. Every hit must update the ordering. The ordering is
a priority queue — expensive in hardware for large N.

**Pseudo-LRU (PLRU) — tree-based:**
Uses N-1 bits per set arranged as a binary tree. Each bit points toward the
"more recently used" subtree. On a hit, flip bits along the path from the root
to the accessed way (pointing away from the hit way). On a miss, follow the
"stale" path (all bits pointing away from the root in the stale direction) to
find the victim.

```
4-way PLRU (3 state bits: T, L, R):

               T
             /   \
           L       R
          / \     / \
        W0  W1  W2  W3

Access W2: T=1 (right used), R=0 (left of right = W2)
Next miss: T=0 -> go left -> L=? -> stale leaf = eviction candidate
```

**Why PLRU dominates:**
- 4-way LRU: 5 state bits; PLRU: 3 bits. Area and power savings.
- Hit latency: LRU must update a priority queue; PLRU flips 2 bits (path length).
- Miss rate difference: PLRU miss rate is typically within 1-2% of true LRU for
  real workloads. The hardware savings outweigh the marginal miss-rate degradation.
- Scalability: 16-way LRU needs ~45 bits; 16-way PLRU needs 15 bits.

**When true LRU matters:** TLBs (8-64 entries, fully associative) and victim caches
often implement true LRU because the entry count is small and the hit rate benefit
of true LRU is more significant at small sizes.

---

### Q7. What is a write buffer and why is it essential for write-through caches?

**Answer:**

A **write buffer** is a small FIFO (typically 4-8 entries) inserted between the cache
and the next memory level. When the CPU performs a store:

1. The data is written to the cache (if write-allocate) or written directly to the buffer
   (if write-through).
2. The write buffer accepts the entry immediately (single-cycle from the CPU's view).
3. The write buffer drains entries to memory at memory bandwidth, in the background.
4. The CPU continues executing without waiting for memory to acknowledge the write.

**Without a write buffer (write-through):**
Every store stalls the CPU until memory confirms the write — typically 50-200 cycles for DRAM.
A tight write loop writing 1000 bytes at 200 cycles/write = 200,000 cycles of stalls.

**With a write buffer:**
The CPU writes to the buffer in 1 cycle. If the buffer is deep enough to absorb bursts,
stalls are rare. The buffer drains continuously to memory in the background.

**Write buffer hazards:**
If the CPU reads an address that is pending in the write buffer (not yet written to
memory), the read must snoop the write buffer and return the buffered value, not the
stale memory value. This is called **write buffer forwarding** and must be implemented
correctly to avoid read-after-write hazards.

```
CPU write: addr=0x1000, data=0xAB  -> Write buffer[0]
CPU read:  addr=0x1000             -> Snoop write buffer
                                   -> Found in buffer: return 0xAB (correct)
                                   -> Do NOT go to memory (would return stale value)
```

---

### Q8. What is cache inclusivity? Compare inclusive, exclusive, and non-inclusive caches in a two-level hierarchy.

**Answer:**

**Inclusive L2:** Every line present in L1 is also present in L2. L2 capacity is
not fully usable because it must hold all L1 content as a superset.

- Advantage: On a coherency snoop (another CPU checking if a line is cached),
  the L2 can respond on behalf of the entire hierarchy. No need to check L1.
- Advantage: On an L1 eviction, the line can simply be dropped (no writeback to L2
  for clean lines) because L2 already has it.
- Disadvantage: L2 wastes capacity holding L1's working set. Effective L2 size is
  reduced by the L1 capacity.
- Disadvantage: On an L2 eviction, the line must also be invalidated in L1
  (back-invalidation), adding complexity.

**Exclusive L2:** A line is present in at most one level. On an L1 miss, the evicted
L1 line is placed in L2 (swap), and the new line is placed in L1 only.

- Advantage: Combined L1 + L2 = maximum effective capacity; no duplication.
- Disadvantage: Coherency snoops must check both L1 and L2 (two tag lookups per snoop).
- Used by: AMD L1/L2 in older designs; some victim cache implementations.

**Non-inclusive (or non-exclusive) L2:** Lines may or may not be in both levels.
No explicit inclusion or exclusion invariant is maintained.

- Simplest policy to implement.
- Used by: ARM Cortex-A with separate L1 and L2 without strict inclusion.
- Snoops check both levels; eviction does not require back-invalidation.

**Interview rule of thumb:** Intel historically uses inclusive L3 (for easy coherency
directory); AMD uses non-inclusive shared L3. The trend in recent designs is toward
non-inclusive shared caches with a separate coherency directory.

---

## Tier 3 — Advanced

### Q9. Explain cache way prediction and its impact on L1 access latency and energy.

**Answer:**

**The problem:** A 4-way set-associative cache must read all four ways' tag RAMs
simultaneously and drive four comparators on every access. Each way access consumes
energy even if only one way holds valid data. In a 32 KB, 4-way L1 at 3 GHz, this
is billions of wasted tag reads per second.

**Way prediction:** A small, fast predictor (often a direct-mapped structure indexed
by the PC or the lower address bits) predicts which way of the set will be the hit.
On each access:

1. The predictor selects one way.
2. Only that way's tag and data RAMs are accessed (serial access).
3. If the prediction is correct: single-way latency (faster than all-ways-parallel,
   lower energy).
4. If the prediction is wrong: access the remaining ways (slower than all-ways-parallel
   in the worst case; energy cost of two accesses).

**Energy analysis:**
If prediction accuracy is 80%:
- Average energy = 0.80 * (1-way cost) + 0.20 * (4-way cost + mux overhead)
- For a 4-way cache with equal-area ways: 0.80 * 0.25 + 0.20 * 1.0 = 0.40 (40% of full energy)

**Latency analysis:**
- Hit with correct prediction: tag + data access serialized, but one-way access is
  faster than four-way (lower bit-line capacitance, smaller sense-amp).
- Hit with wrong prediction: add one extra cycle for the second-chance access.
  This must not degrade average CPI significantly, so predictors must be >85% accurate.

**Way prediction is used in** ARM Cortex-A53, Cortex-A57 L1 data caches and was
described in the original StAMP paper (stream-based way prediction).

---

### Q10. How does hardware prefetching interact with cache replacement? What is the "cache pollution" problem and how do prefetch filters address it?

**Answer:**

**Hardware prefetchers** (stride prefetcher, next-line prefetcher, stream detector)
predict future cache misses and issue prefetch requests before the CPU needs the data.
Prefetched lines are allocated in the cache proactively.

**Cache pollution:**
If the prefetcher predicts incorrectly (poor coverage or inaccurate stride detection),
it allocates lines that are never used. These useless lines occupy ways and evict
useful lines (demand-fetched data), increasing demand miss rate — the opposite of
the intended effect.

**Pollution is worst when:**
- Irregular access patterns confuse stride detectors.
- Short-lived streaming data is prefetched into the main cache, evicting hot data.
- Prefetch degree is too aggressive (too many lines fetched ahead).

**Prefetch filter — Bloom filter approach:**
A small Bloom filter tracks which prefetched lines have actually been used (demanded).
Unused prefetched lines are periodically evicted. Some designs implement a "prefetch
buffer" separate from the main cache. Prefetched lines reside in the buffer; on a
demand hit to the buffer, the line is promoted to the main cache. Only useful
prefetches consume main cache capacity.

**Prefetch-aware replacement:**
Tag each cache line with a bit indicating whether it was brought in by a prefetch
(P-bit). The replacement policy treats prefetch lines as having lower priority:

```
On miss: evict a prefetch-only line before evicting a demand-fetched line.
Order of eviction preference:
  1. Prefetch line, never accessed (P-bit set, reference bit clear)
  2. Prefetch line, accessed once (P-bit set, reference bit set)
  3. Demand line, LRU position (P-bit clear)
```

ARM Cortex-A72 and later cores implement a prefetch stream buffer separate from
the L1 data cache to avoid demand-cache pollution entirely.

**Interview answer framework:** Name the problem (pollution), explain the mechanism
(wrong allocation evicts useful lines), describe the metric (demand miss rate increases
while prefetch coverage stays high), and give two mitigations: prefetch buffers and
prefetch-aware replacement policies.
