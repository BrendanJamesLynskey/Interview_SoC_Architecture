# Quiz: Memory Subsystem

15 multiple-choice questions covering cache architecture, MESI/MOESI coherency protocols, MMU and virtual memory, and DMA controller design. Questions span three difficulty tiers. Answers with explanations are collected at the end.

---

## Instructions

Select the single best answer for each question. After completing all questions, check your answers against the answer key. For each incorrect answer, read the full explanation before moving on.

Suggested time: 25 minutes.

---

## Questions

### Fundamentals (Q1 -- Q5)

**Q1.** A direct-mapped cache with 1024 sets and 64-byte cache lines is used with 32-bit physical addresses. How many bits are used for the cache line offset, index, and tag respectively?

- A) Offset: 4, Index: 10, Tag: 18
- B) Offset: 6, Index: 10, Tag: 16
- C) Offset: 6, Index: 8, Tag: 18
- D) Offset: 5, Index: 10, Tag: 17

---

**Q2.** In the MESI cache coherency protocol, what does the "E" (Exclusive) state mean?

- A) The cache line is valid, clean, and the only copy in the system; the cache is free to promote it to Modified without a bus transaction
- B) The cache line is valid, dirty, and the only copy in the system; it must be written back before eviction
- C) The cache line is valid and shared among multiple caches, but no cache may write to it
- D) The cache line has been invalidated and must be fetched from memory on the next access

---

**Q3.** What is the purpose of the Translation Lookaside Buffer (TLB) in an MMU?

- A) To buffer recently evicted dirty cache lines before they are written to DRAM
- B) To cache recently used virtual-to-physical address translations and avoid repeated page table walks
- C) To translate between different bus protocols (for example, AXI to AHB)
- D) To store the physical addresses of DMA descriptors used by peripheral controllers

---

**Q4.** A DMA controller is programmed with a source address, destination address, transfer length, and burst size. Which bus master drives the read transactions to the source memory?

- A) The CPU core that programmed the DMA registers
- B) The DMA controller itself
- C) The memory controller, which fetches data when it detects a DMA request
- D) The peripheral device that requested the DMA transfer

---

**Q5.** A write-through cache policy means:

- A) Every write to the cache also immediately writes the same data to main memory
- B) Writes update only the cache line; the modified line is written back to memory only on eviction
- C) Writes are buffered in a write-combine buffer and flushed periodically
- D) The cache is bypassed on every write; only reads use the cache

---

### Intermediate (Q6 -- Q11)

**Q6.** A 4-way set-associative cache has 256 sets and 32-byte cache lines. The system uses 40-bit physical addresses. What is the total cache capacity?

- A) 256 KB
- B) 32 KB
- C) 128 KB
- D) 64 KB

---

**Q7.** In the MOESI protocol, the "O" (Owned) state is added to MESI. Which scenario does the Owned state address that MESI cannot handle efficiently?

- A) A cache needs to hold a dirty line while allowing other caches to share and read the same dirty data without first writing it back to memory
- B) A cache needs to perform an atomic read-modify-write operation without releasing the line
- C) A cache needs to hold a line that has been accessed more than a threshold number of times for replacement policy purposes
- D) A cache receives a line from another cache but cannot determine whether it is clean or dirty

---

**Q8.** A CPU performs the following sequence on a multicore system with MESI protocol and write-invalidate policy:

1. Core 0 reads address X -- line enters Shared state in Core 0's cache
2. Core 1 reads address X -- line enters Shared state in Core 1's cache
3. Core 0 writes to address X

What state does the cache line in Core 1 transition to after step 3?

- A) Shared -- Core 1 is notified of the write but retains a valid copy
- B) Modified -- Core 1 adopts the new value written by Core 0
- C) Invalid -- Core 0's write generates an invalidation message to Core 1
- D) Exclusive -- Core 1 now holds the only remaining valid copy

---

**Q9.** An MMU page table uses a two-level structure with 4 KB pages, 10 bits for level-1 index, 10 bits for level-2 index, and a 12-bit offset on a 32-bit virtual address system. How many level-2 page tables would a process that uses exactly 2 MB of contiguous virtual memory need?

- A) 1
- B) 2
- C) 512
- D) 1024

---

**Q10.** A DMA controller uses a descriptor-based design. Each descriptor specifies a source address, destination address, length, and a next-descriptor pointer. What is the primary advantage of chained descriptors over programming a single large transfer?

- A) Chained descriptors allow the DMA to operate at higher clock frequency
- B) Chained descriptors allow scatter-gather operation: collecting data from (or distributing data to) non-contiguous physical memory regions without CPU intervention between transfers
- C) Chained descriptors reduce the number of AXI channels required by the DMA controller
- D) Chained descriptors provide hardware ECC protection on the transferred data

---

**Q11.** A cache uses the LRU (Least Recently Used) replacement policy. A 2-way set-associative cache processes the following access sequence to a single set: A, B, A, C. The cache starts empty. Which line is evicted when C is accessed?

- A) A
- B) B
- C) C cannot be loaded without evicting both lines
- D) No eviction occurs; C fills the second way

---

### Advanced (Q12 -- Q15)

**Q12.** A software driver performs a DMA transfer from a peripheral to a buffer in uncached memory. The driver then reads the buffer from the CPU. It observes that the CPU reads garbage values. Cache is disabled for the buffer region. What is the most likely cause?

- A) The DMA controller wrote to a different physical address due to a misconfigured descriptor
- B) The CPU read values from a stale cache line because the memory region was not properly marked as non-cacheable
- C) The DMA transfer was completed before the peripheral had valid data to send
- D) A write-ordering issue: the CPU read before the DMA write transaction had propagated to the point of coherency on the system bus

---

**Q13.** A VIPT (Virtually Indexed, Physically Tagged) L1 cache avoids aliasing only when the index bits fall within the page offset. A system has 4 KB pages, 64-byte cache lines, and a cache with 256 sets (8-way associative). Does this cache require aliasing protection?

- A) Yes -- the index requires 8 bits and the offset requires 6 bits; combined they exceed the 12-bit page offset, causing virtual aliasing
- B) No -- the index (8 bits) plus offset (6 bits) = 14 bits, which exceeds the 12-bit page offset; aliasing is possible
- C) No -- because the cache is 8-way associative, aliasing is automatically prevented regardless of index width
- D) Yes -- aliasing only occurs in direct-mapped caches; an 8-way cache is unaffected

---

**Q14.** In a multi-core system with per-core L1 caches and a shared L2 cache, the L2 maintains a "snoop filter" (also called a directory or tag directory). What is the primary purpose of the snoop filter?

- A) To filter out redundant ECC errors before they propagate to the L1 caches
- B) To track which L1 caches hold copies of each cache line, so that coherency snoops are sent only to caches that actually hold the line rather than broadcasting to all caches
- C) To prevent speculative L1 cache fills from polluting the shared L2 cache
- D) To translate virtual L1 addresses to physical L2 addresses during snoop operations

---

**Q15.** A NUMA (Non-Uniform Memory Access) system has two nodes, each with four CPU cores and local DRAM. A core on Node 0 repeatedly accesses data that is physically located in Node 1's DRAM. What is the primary performance concern, and what is the standard software mitigation?

- A) Cache thrashing: the cache line repeatedly bounces between L1 caches; mitigate by pinning the cache line to Node 1's L2
- B) High remote memory access latency: every access crosses the inter-node interconnect; mitigate by migrating the data or the thread to the node where the data resides using NUMA-aware memory allocation
- C) Coherency protocol overhead: every access triggers a snoop to Node 1; mitigate by marking the data as non-cacheable to avoid snoops
- D) DMA bandwidth saturation: the inter-node link is shared with DMA; mitigate by scheduling DMA transfers during periods of low CPU activity



---

## Answer Key

| Q  | Answer |
|----|--------|
| 1  | B      |
| 2  | A      |
| 3  | B      |
| 4  | B      |
| 5  | A      |
| 6  | B      |
| 7  | A      |
| 8  | C      |
| 9  | B      |
| 10 | B      |
| 11 | B      |
| 12 | D      |
| 13 | B      |
| 14 | B      |
| 15 | B      |

---

## Detailed Explanations

**Q1 -- Answer: B**

A 64-byte cache line requires log2(64) = 6 offset bits to address each byte within the line. With 1024 sets, the index requires log2(1024) = 10 bits. The remaining bits form the tag: 32 - 6 - 10 = 16 bits. Option A uses a 4-bit offset (16-byte lines). Option C uses an 8-bit index (256 sets). Option D uses a 5-bit offset (32-byte lines). Correctly decomposing a physical address into tag, index, and offset is a foundational cache design calculation.

---

**Q2 -- Answer: A**

The Exclusive state means the line is clean (matches memory), present only in this one cache (no other cache holds a copy), and can be written to without any bus transaction -- the write simply promotes the line to Modified state silently. Option B describes the Modified state (dirty). Option C describes the Shared state. Option D describes the Invalid state. The distinction between Exclusive and Shared is important: in Shared state, writing requires an invalidation broadcast; in Exclusive state, no such broadcast is needed, saving a bus transaction.

---

**Q3 -- Answer: B**

A page table walk involves multiple memory accesses (one per page table level) to resolve a virtual address to a physical address. The TLB caches the results of recent walks so that most address translations are resolved in a single cycle. Without a TLB, every memory access would require 2 to 4 additional memory accesses for the page table walk, reducing effective memory bandwidth by 3 to 5x. Option A describes a write buffer. Option C describes a bridge or protocol converter. Option D describes a descriptor cache, which is used in some DMA controllers, not the MMU.

---

**Q4 -- Answer: B**

The DMA controller is a hardware bus master. Once programmed by the CPU, it independently issues read transactions to the source address and write transactions to the destination address on the system bus, without further CPU involvement. This is the entire point of DMA: to offload data movement from the CPU. Option A is wrong; the CPU sets up the DMA but does not execute the transfers. Option C is wrong; the memory controller responds to requests but does not initiate them. Option D is wrong; the peripheral may signal the DMA controller (via a request line), but the DMA controller itself drives the bus transactions.

---

**Q5 -- Answer: A**

In a write-through cache, every write to the cache immediately propagates to the next level of the hierarchy (typically main memory). This keeps memory always up-to-date but consumes additional write bandwidth. Option B describes a write-back (also called copy-back) policy, which is more common in modern caches because it reduces memory bus traffic. Option C describes a write-combine buffer optimisation, which is a separate mechanism. Option D describes write-bypass or non-temporal stores, not write-through caching.

---

**Q6 -- Answer: B**

Total cache capacity = ways * sets * line_size = 4 * 256 * 32 = 32,768 bytes = 32 KB. Option A (256 KB) would require either 4 * 256 * 256 (256-byte lines) or 4 * 2048 * 32 (2048 sets), neither of which matches the stated parameters. Option C (128 KB) and option D (64 KB) are also inconsistent with the given values. The 40-bit physical address width is used for tag field calculation (40 - log2(32) - log2(256) = 40 - 5 - 8 = 27-bit tag) but does not affect the cache storage capacity.

---

**Q7 -- Answer: A**

In MESI, when a cache line is dirty (Modified) and another cache requests a read, the holding cache must write the line back to memory before the requesting cache can read it, involving a memory write and a subsequent memory read -- two full memory transactions. MOESI's Owned state allows the holder of a dirty line to supply it directly to the requesting cache without writing to memory first. Both caches then hold copies: the original is Owned (dirty, responsible for eventual writeback) and the new copy is Shared. This eliminates a full round-trip to memory for each sharing event. Option B describes an atomic operation, which is handled by locking or exclusive access mechanisms, not the Owned state. Options C and D are not related to the Owned state purpose.

---

**Q8 -- Answer: C**

MESI uses a write-invalidate protocol. When Core 0 writes to a Shared line, it broadcasts an invalidation message to all other caches holding a copy. Core 1 receives the invalidation and transitions its copy to Invalid. Core 0's line transitions to Modified (it now holds the only valid, dirty copy). On Core 1's next access to address X, it will miss and must fetch the updated value from Core 0's cache (via an intervention) or from memory. Option A (write-update or write-broadcast) is an alternative protocol not used by standard MESI. Option B is wrong; Core 1 cannot adopt a new value without receiving it explicitly. Option D is wrong; invalidation removes Core 1's copy entirely, not promotes it to Exclusive.

---

**Q9 -- Answer: B**

A two-level page table with 10-bit L1 index and 10-bit L2 index covers 2^10 = 1024 level-2 page tables, each mapping 2^10 = 1024 pages of 4 KB = 4 MB per L2 table. For 2 MB of contiguous memory starting at any 4 MB-aligned address, all pages fall within a single 4 MB region covered by one L2 page table. However, if the 2 MB region spans a 4 MB boundary, it requires two L2 page tables. The worst case is when the 2 MB region starts just after a 4 MB boundary, consuming one L2 table. Since 2 MB = 512 pages and each L2 table holds 1024 PTEs, a single L2 table suffices if the region is aligned. For the general worst case (crossing a 4 MB L1 entry boundary), 2 tables are needed. Option B (2) is the correct worst-case answer. Option A (1) is only valid when the region is 4 MB-aligned. Options C and D are far too many.

---

**Q10 -- Answer: B**

Scatter-gather DMA allows non-contiguous regions of physical memory to be collected (scatter) or distributed (gather) in a single DMA operation without CPU intervention between segments. A driver builds a descriptor chain where each descriptor points to one physically contiguous segment. The DMA hardware follows the chain autonomously, processing each segment in sequence. This is essential for transferring data that the OS has allocated across multiple physical pages. Option A is wrong; descriptor chaining does not affect clock frequency. Option C is wrong; the number of AXI channels is determined by the DMA architecture, not by descriptor format. Option D is wrong; ECC is a separate memory subsystem function.

---

**Q11 -- Answer: B**

Trace the LRU state through the access sequence:
- Access A: Cache empty. A fills way 0. LRU order (MRU to LRU): [A, -]
- Access B: B fills way 1. Order: [B, A]
- Access A: Hit on A. Order updates: [A, B]
- Access C: Cache full, miss. LRU victim is B (least recently used). B is evicted, C fills way 1. Order: [C, A]

Option A is wrong; A was accessed most recently before C's access. Option C is wrong; only one eviction is needed (the set has 2 ways). Option D is wrong; both ways are occupied after accessing A and B.

---

**Q12 -- Answer: D**

The memory region is marked non-cacheable, so the CPU read bypasses the cache and goes directly to main memory. The problem is write ordering: the DMA write transaction must have become visible at the point of coherency (PoC) -- typically the memory controller -- before the CPU issues its read. If the CPU read reaches the memory controller before the DMA write has propagated through the interconnect and posted write buffers, the CPU reads stale data. The fix is a read memory barrier (DMB or DSB on ARM) after the DMA completion interrupt and before the CPU read, ensuring all DMA writes are visible. Option A describes a descriptor misconfiguration -- possible but less likely when the issue is consistent garbage rather than random corruption. Option B is wrong; the region is already marked non-cacheable. Option C is wrong; completion is signalled by an interrupt after data is ready.

---

**Q13 -- Answer: B**

VIPT aliasing analysis: index bits = log2(256 sets) = 8 bits; offset bits = log2(64 bytes/line) = 6 bits. The combined index + offset = 8 + 6 = 14 bits. Since 4 KB pages have a 12-bit offset, the top 2 index bits (bits [13:12]) come from the virtual page number. Two virtual pages that map to the same physical page may have different values for bits [13:12], creating different cache indices for the same physical data -- this is aliasing. The correct answer is B (aliasing is possible; the question statement says "No -- aliasing is possible", which means aliasing protection IS required). To be precise: the cache DOES require aliasing protection because the index exceeds the page offset boundary. Option C is wrong; associativity does not automatically prevent aliasing -- it can allow aliasing to be resolved by restricting how physical addresses may be placed (page colouring), but 8-way associativity alone does not prevent the problem. Option D has the logic backwards.

---

**Q14 -- Answer: B**

Without a snoop filter, a coherency broadcast must be sent to every L1 cache on every snoop request, which wastes bandwidth and power as the number of cores scales. The snoop filter maintains a directory of which lines each L1 cache holds (similar to a cache of cache tags). When a snoop is needed, it is directed only to the L1 caches that actually have the relevant line, dramatically reducing snoop traffic in large clusters. This is essential for scalability in 8-core and larger clusters. Option A is wrong; ECC error filtering is a separate mechanism in the memory controller. Option C describes a cache insertion policy, unrelated to the snoop filter. Option D is wrong; L2 operates on physical addresses; no virtual-to-physical translation is needed between L1 and L2 in a PIPT or VIPT cache hierarchy.

---

**Q15 -- Answer: B**

In a NUMA system, accessing remote memory (on a different node) incurs significantly higher latency due to the inter-node interconnect (often 1.5 to 3x higher than local memory latency). If a thread repeatedly accesses remote data, it pays this penalty on every cache miss. The standard mitigations are: (1) NUMA-aware memory allocation, placing the thread's data on the same node as the thread (first-touch or explicit allocation policy); and (2) thread migration, moving the thread to the node where the data resides. Operating systems such as Linux provide numactl and mbind APIs for this purpose. Option A is wrong; cache thrashing is a separate issue involving capacity conflicts, not NUMA topology. Option C is wrong; caching remote data is desirable -- it is the fetch latency, not coherency snoops, that is the bottleneck. Option D conflates DMA traffic with CPU remote access patterns.
