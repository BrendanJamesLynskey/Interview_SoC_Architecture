# Quiz: Interconnect Design

15 multiple-choice questions covering crossbar, ring, network-on-chip, arbitration, QoS, and coherency. Questions span three difficulty tiers. Answers with explanations are collected at the end.

---

## Instructions

Select the single best answer for each question. After completing all questions, check your answers against the answer key. For each incorrect answer, read the full explanation before moving on.

Suggested time: 25 minutes.

---

## Questions

### Fundamentals (Q1 -- Q5)

**Q1.** In a full crossbar interconnect with M masters and N slaves, how many independent data paths can theoretically be active simultaneously?

- A) M + N
- B) M * N
- C) min(M, N)
- D) max(M, N)

---

**Q2.** A ring interconnect topology connects IP blocks in a loop with unidirectional or bidirectional links. Compared to a full crossbar, what is the primary disadvantage of a ring?

- A) A ring cannot support burst transactions
- B) Latency increases with the number of hops between non-adjacent nodes
- C) A ring requires more arbitration logic per node than a crossbar
- D) A ring cannot support more than eight nodes

---

**Q3.** In round-robin arbitration between four masters with equal priority, master A issues requests at a high rate while masters B, C, and D issue occasional requests. What is the maximum number of consecutive grants that master A can receive?

- A) Unlimited -- master A gets all grants as long as it is the only one requesting
- B) 1 -- the arbiter always moves to the next master after each grant
- C) 4 -- after four consecutive grants the arbiter resets
- D) As many as the configurable token bucket allows

---

**Q4.** A Network-on-Chip (NoC) uses wormhole routing. Which statement best describes wormhole routing?

- A) A packet is buffered in full at each router before being forwarded to the next hop
- B) A packet is cut into flits; the header flit reserves a path and subsequent flits follow immediately without full buffering at intermediate nodes
- C) A packet is split into cells of fixed size and each cell is routed independently
- D) The routing path is computed at the source and embedded in a header; the packet travels along this path atomically

---

**Q5.** What is the primary purpose of QoS (Quality of Service) signalling in an AXI interconnect?

- A) To encrypt sensitive transactions from the master before they reach the slave
- B) To allow a master to indicate the relative priority of a transaction, enabling the interconnect to service higher-priority transactions preferentially
- C) To verify that the slave has received the transaction without errors
- D) To reduce power consumption by gating low-priority transaction paths

---

### Intermediate (Q6 -- Q11)

**Q6.** A crossbar has 4 masters and 4 slaves. Masters 1 and 2 both request access to slave 3 simultaneously. Masters 3 and 4 simultaneously request slaves 1 and 2 respectively. How many of these transactions can proceed in the same clock cycle?

- A) 1 -- only one master may use the crossbar at a time
- B) 2 -- only masters with no contention may proceed
- C) 3 -- all except one of the conflicting transactions on slave 3
- D) 4 -- all transactions can proceed because they target independent slaves except for the slave 3 conflict; three non-conflicting paths can be opened simultaneously

---

**Q7.** In a TDMA (time-division multiple access) interconnect, bandwidth is allocated in fixed time slots. A master with a 10% TDMA allocation on a 64-bit, 1 GHz bus achieves what maximum sustained throughput?

- A) 800 MB/s
- B) 6.4 GB/s
- C) 640 MB/s
- D) 8 GB/s

---

**Q8.** An SoC interconnect implements weighted round-robin (WRR) arbitration. Master A has weight 4 and master B has weight 1. Over a long observation window, what fraction of the total bus bandwidth is allocated to master A?

- A) 4x the bandwidth of master B, meaning 80% for A and 20% for B
- B) 4 bytes per transaction for A versus 1 byte for B
- C) Master A receives four grants for every single grant to master B, so A gets 4/5 of bandwidth
- D) Both A and C are equivalent and correct statements

---

**Q9.** In a mesh NoC, dimension-order routing (DOR, also called XY routing) routes a packet first along the X dimension then the Y dimension. What is a known limitation of XY routing?

- A) It requires global knowledge of all link utilisation to compute optimal paths
- B) It cannot route packets to nodes located in the same row as the source
- C) It is not deadlock-free because channels in the Y direction can form a dependency cycle
- D) It may produce suboptimal paths and cannot use some available links, but is deadlock-free under standard channel dependency analysis

---

**Q10.** A bus interconnect offers two QoS levels: QoS=15 (high priority, latency-sensitive) and QoS=0 (low priority, best effort). A designer routes all DMA bulk-data transfers at QoS=15. What is the likely system-level impact?

- A) DMA transfers will complete faster with no effect on other masters
- B) The QoS mechanism will be bypassed because DMA is a hardware master and QoS only applies to software-initiated transactions
- C) Other latency-sensitive masters such as a display controller or CPU instruction fetches may be starved, causing system-level degradation despite fast DMA
- D) The interconnect will automatically lower the DMA QoS to prevent starvation

---

**Q11.** A point-to-coherency (PoC) in an ARM-based SoC is distinct from a point-to-unification (PoU). Which of the following correctly describes the PoC?

- A) The PoC is typically the L1 cache, which is the first point at which all observers within a core share a unified view of instruction and data memory
- B) The PoC is the point in the memory hierarchy at which all bus masters (CPUs, DMA, GPUs) share a coherent view -- typically main memory or a last-level cache with a coherency directory
- C) The PoC is the AXI interconnect fabric, which arbitrates between masters and provides ordering guarantees
- D) The PoC is defined by the OS as the highest-level cache that has been configured for coherent operation

---

### Advanced (Q12 -- Q15)

**Q12.** An SoC interconnect must guarantee that a write from master A to address X followed by a read from master B to the same address X returns the written value. Which interconnect property is required to ensure this?

- A) Write-after-read (WAR) ordering at the interconnect level
- B) Observability at the point of coherency: master B's read must be able to observe master A's write
- C) An exclusive access lock preventing master B from reading during master A's write window
- D) Speculative execution must be disabled in both masters to prevent prefetching the old value

---

**Q13.** A designer replaces a flat crossbar with a hierarchical interconnect: a local high-speed sub-fabric for the CPU cluster and a global fabric for all other masters. The CPU cluster masters connect to both fabrics via a bridge. What is the primary benefit and primary risk of this change?

- A) Benefit: reduced latency for intra-cluster traffic; Risk: the bridge may become a bottleneck for CPU-to-peripheral traffic and adds ordering complexity
- B) Benefit: eliminates the need for arbitration in the CPU cluster; Risk: the peripheral masters lose access to the CPU cluster slaves
- C) Benefit: lower clock frequency requirement for the global fabric; Risk: clock domain crossings are eliminated in the cluster
- D) Benefit: the CPU cluster can use a proprietary protocol; Risk: the global fabric must be replaced entirely

---

**Q14.** In a CHI network, a Slave Node (SN-F) receives write transactions from the Home Node. The SN-F must acknowledge writes with a CompDBIDResp. Why does the write protocol use this two-phase acknowledgement rather than a simple single-phase write?

- A) To allow the Home Node to pipeline multiple write addresses before the data channel opens
- B) To decouple the data buffer allocation (DBIDResp provides a data buffer ID) from the write data transfer, enabling flow control and preventing deadlock when buffer resources are limited
- C) To allow the SN-F to perform error correction before acknowledging the write
- D) To signal the requester that the write has reached main memory and is persistent

---

**Q15.** An interconnect implements token-based credit flow control on the request channel. Each master starts with 8 credits. Each request consumes one credit; the target returns a credit when it processes the request. Master A sends 8 requests back-to-back, consuming all its credits, and then sends a 9th request. What happens?

- A) The 9th request is issued and the oldest request is dropped to free a credit
- B) The 9th request is issued with a special "no credit" flag that the target processes at lower priority
- C) Master A must stall and cannot issue the 9th request until at least one credit is returned from the target
- D) The 9th request is buffered in a separate overflow queue with no credit cost



---

## Answer Key

| Q  | Answer |
|----|--------|
| 1  | C      |
| 2  | B      |
| 3  | A      |
| 4  | B      |
| 5  | B      |
| 6  | C      |
| 7  | C      |
| 8  | D      |
| 9  | D      |
| 10 | C      |
| 11 | B      |
| 12 | B      |
| 13 | A      |
| 14 | B      |
| 15 | C      |

---

## Detailed Explanations

**Q1 -- Answer: C**

A full crossbar can open one path from each master to a different slave simultaneously, but a single slave can only service one master at a time. Therefore the maximum number of simultaneous active paths is limited by min(M, N) -- whichever pool is smaller. With M=4 masters and N=6 slaves, at most 4 paths can be active (one per master, each to a different slave). With M=6 and N=4, at most 4 paths can be active (one per slave, each from a different master). Option B (M * N) describes the total number of possible paths in the crossbar fabric, not the simultaneous throughput. Option D is incorrect for the same reason.

---

**Q2 -- Answer: B**

In a ring, a packet travelling between two nodes that are k hops apart must traverse k intermediate nodes, each adding at least one cycle of latency (pipeline stage or serialisation delay). In a crossbar, every master-to-slave path is direct and single-hop. The latency disadvantage of a ring becomes significant as the number of nodes grows, making rings most suitable for small node counts or bandwidth-dominated designs where latency is not the bottleneck. Option A is wrong; burst transactions are supported by buffering at each ring node. Option C is incorrect; rings require less arbitration logic per node, not more. Option D is a practical guideline rather than a fundamental limit.

---

**Q3 -- Answer: A**

In a standard round-robin scheme, the arbiter advances its pointer only when there are competing requests. If master A is the only one requesting, the arbiter grants A continuously -- there is no other master to rotate to. Only when masters B, C, or D also request does the arbiter rotate away from A. This is called "work-conserving" behaviour. Option B (always rotating after each grant) is a strict round-robin implementation that rotates the pointer even when other masters have no request, which wastes bandwidth. Option C describes a fixed-count wrap, which is not standard round-robin. Option D describes a token bucket, a different mechanism.

---

**Q4 -- Answer: B**

Wormhole routing divides a packet into flits (flow-control units). The header flit carries the routing information and establishes a virtual circuit through the network one hop at a time. Subsequent body and tail flits follow the header immediately, requiring only small per-hop buffers (typically one flit deep per virtual channel). This reduces buffering requirements compared to store-and-forward (option A). Option A describes store-and-forward routing. Option C describes ATM-style cell switching. Option D describes source routing, which can be combined with any forwarding strategy but is not wormhole routing itself.

---

**Q5 -- Answer: B**

AXI4 includes a 4-bit QoS field (AWQOS, ARQOS) on the address channels. Masters use this to signal the urgency of each transaction to the interconnect. The interconnect arbiters use QoS values to prefer higher-priority transactions when contention occurs. This allows latency-sensitive traffic (display, audio, real-time control) to be prioritised over bulk transfers (DMA background copies) without dedicated hardware paths. Option A describes encryption, which is a security function unrelated to QoS. Option C describes an error-checking mechanism. Option D describes a power management strategy, not QoS.

---

**Q6 -- Answer: C**

The crossbar has separate paths to each slave. Masters 1 and 2 both contend for slave 3 -- the arbiter grants one of them (say master 1) and holds master 2. Meanwhile, master 3 accesses slave 1 and master 4 accesses slave 2 -- these are completely independent paths with no contention. So three transactions proceed simultaneously: master 1 to slave 3, master 3 to slave 1, and master 4 to slave 2. Master 2 must wait. Option A is wrong; a crossbar allows parallel non-conflicting paths. Option B is wrong; there are three non-conflicting transactions (two of the four). Option D is wrong; four transactions cannot proceed because slave 3 has a conflict.

---

**Q7 -- Answer: C**

A 64-bit bus at 1 GHz has a peak bandwidth of 8 bytes * 1 GHz = 8 GB/s. A 10% TDMA allocation gives 10% of 8 GB/s = 800 MB/s. Wait -- let us recheck: 8 GB/s * 0.10 = 0.8 GB/s = 800 MB/s. This matches option C. Option A (800 MB/s) is the same numerical value but expressed ambiguously -- let us confirm: 8 GB/s = 8192 MB/s; 10% = 819 MB/s if 1 GB = 1024 MB, but using 1 GB = 1000 MB, 8 GB/s * 0.10 = 800 MB/s. Option B (6.4 GB/s) corresponds to an 80% allocation. Option D (8 GB/s) is the full bus bandwidth without any TDMA restriction.

---

**Q8 -- Answer: D**

Weighted round-robin with weights 4 and 1 means the arbiter grants master A 4 times for every 1 grant to master B within each arbitration round. Over a long window, master A receives 4/5 = 80% of grants and master B receives 1/5 = 20%. Options A and C both state this correctly (A is 4x B's bandwidth = 80%; C is the fractional expression 4/5). They are equivalent statements of the same result, making D the correct choice. Option B misinterprets weights as byte counts per transaction, which is not how WRR operates.

---

**Q9 -- Answer: D**

XY (dimension-order) routing in a 2D mesh is formally proven to be deadlock-free under standard channel dependency analysis (Dally and Seitz's channel dependency graph has no cycles for XY routing). However, it cannot use all available paths -- specifically, it cannot route directly in the Y direction when the source and destination share the same X coordinate (it must still start with any X traversal, even if zero hops). More significantly, it may produce longer paths than the minimum when traffic is unbalanced, and it cannot adaptively route around congested links. Option C is wrong; the formal proof shows XY routing has no cyclic channel dependencies and is deadlock-free. Option A describes adaptive routing algorithms. Option B is wrong; XY routing handles same-row destinations by taking zero X steps.

---

**Q10 -- Answer: C**

QoS is a tool that must be used correctly. Assigning QoS=15 to bulk DMA transfers elevates them to the highest priority, which means they preempt all other traffic at arbitration. Latency-sensitive masters such as a display controller (which has hard real-time deadlines to avoid screen tearing) or a CPU instruction cache miss may then be delayed, causing visible artefacts or CPU stalls. The correct design practice is to assign lower QoS to bulk transfers and reserve high QoS for latency-critical masters. Option A ignores the impact on other masters. Option B is wrong; QoS applies equally to hardware masters. Option D is wrong; no standard interconnect automatically overrides QoS settings.

---

**Q11 -- Answer: B**

In ARM architecture terminology, the Point of Coherency (PoC) is the point in the memory system at which all observers that can access memory share a coherent view of a memory location. For most multi-core SoCs this is main memory or a coherent last-level cache backed by a coherency directory (such as DSU/CHI HN-F). Separate from this, the Point of Unification (PoU) is the point -- typically the L2 cache -- at which instruction cache, data cache, and page table walks for a core are unified. Option A describes the PoU, not the PoC. Option C is wrong; the interconnect fabric provides ordering and routing but is not the definition of PoC. Option D is wrong; the PoC is an architectural property of the hardware, not a software configuration.

---

**Q12 -- Answer: B**

For master B's read to observe master A's write, both masters must observe the write at the same point in the memory hierarchy -- the Point of Coherency. This requires either: the interconnect ordering the transactions so B's read issues only after A's write is visible at the PoC, or a cache coherency protocol (such as MESI/CHI) that ensures A's written data propagates to or is snooped from B before B's read completes. Option A (WAR ordering) addresses write-after-read hazards -- the reverse scenario. Option C (exclusive lock) is not the standard mechanism; it would serialise access unnecessarily and is not what most coherent interconnects implement. Option D (disable speculation) is a software workaround that does not address the fundamental architectural coherency requirement.

---

**Q13 -- Answer: A**

A hierarchical interconnect clusters high-bandwidth, low-latency transactions (CPU core-to-L2 cache, for example) on a local sub-fabric with a shorter, faster interconnect, reducing the average transaction latency for the most frequent traffic patterns. The bridge between the local and global fabrics introduces additional latency for transactions that cross the boundary (CPU to peripheral, for example) and must handle ordering, protocol conversion, and potentially clock domain crossing -- all sources of complexity and potential bottleneck. Option B is wrong; arbitration is still needed within the sub-fabric among CPU cores. Option C is wrong; the global fabric clock frequency is set by its own performance requirements, not by the sub-fabric. Option D is wrong; the global fabric does not need to be replaced; it continues to serve all other masters.

---

**Q14 -- Answer: B**

CHI uses a credit/buffer-based protocol for write data. When a Home Node issues a write to a Slave Node, it must first obtain a Data Buffer ID (DBID) from the SN-F by receiving DBIDResp. This tells the HN that the SN-F has allocated a buffer slot to receive the write data. The HN then sends the write data tagged with the DBID. This two-phase approach prevents the SN-F from being overwhelmed with data it has no buffer for, which would cause deadlock if the data channel filled while the SN-F could not accept it. Option A describes AXI4 behaviour, not CHI. Option C is wrong; ECC errors are handled separately from the protocol flow control. Option D is wrong; CompDBIDResp does not guarantee persistence to non-volatile storage -- that requires a separate persistence acknowledgement.

---

**Q15 -- Answer: C**

Credit-based flow control is a hard guarantee mechanism. A master may only issue a request if it holds at least one credit. The credit represents a guaranteed buffer slot at the target. When master A exhausts its 8 credits, it must stall and wait for the target to return credits as it processes requests. This prevents buffer overflow at the target and eliminates the need for the target to drop requests or signal backpressure via a separate mechanism. Option A (dropping oldest) would violate ordering guarantees and corrupt data. Option B (no-credit flag) would undermine the flow control contract. Option D (overflow queue) would allow unbounded buffering at the master, which defeats the purpose of credit-based flow control and could cause memory pressure at the master.
