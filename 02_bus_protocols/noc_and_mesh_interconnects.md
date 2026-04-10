# Network-on-Chip and Mesh Interconnects — Interview Questions

**Subject:** SoC Architecture
**Topic:** NoC, Mesh, Ring, Routing, Quality of Service
**Difficulty tiers:** Fundamentals / Intermediate / Advanced

---

## Fundamentals

### Q1. What is a Network-on-Chip (NoC), and why do modern SoCs use them?

**Answer:**

A **Network-on-Chip (NoC)** is an on-die interconnect that uses packet-switched routing to carry data between blocks, rather than dedicated point-to-point wires or shared buses. It applies networking concepts (routers, packets, flow control) to on-chip communication.

**Why NoCs are needed:**

Traditional bus-based interconnects (AXI bus, AHB) don't scale beyond ~10–20 masters. The reasons:

1. **Bus contention.** A shared bus serializes all transactions. With many masters, latency grows linearly.

2. **Wire complexity.** Crossbars (the alternative to buses) have $O(N^2)$ wire complexity for N masters and N slaves. Routing becomes impossible at large N.

3. **Frequency scaling.** Long bus wires limit clock frequency. As designs grow, the wires get longer and slower.

4. **Power.** Long wires consume significant power. Shared buses force every master to drive long wires for every access.

NoCs solve these problems by using:

- **Packet switching** instead of dedicated paths.
- **Distributed routers** instead of monolithic crossbars.
- **Multiple links** carrying different traffic in parallel.
- **Localised wires** (each link only spans one router-to-router segment).

**Conceptual structure:**

A NoC consists of:

1. **Routers (or switches):** small blocks that receive packets on their input ports and forward them to output ports based on a routing decision.

2. **Links:** wires between routers, often with flow control.

3. **Network interfaces (NIs):** adapters between IP blocks (CPUs, GPUs, memory controllers) and the NoC. Convert master/slave transactions into NoC packets.

4. **Topology:** the arrangement of routers and links — mesh, ring, torus, fat tree, etc.

**Example — 4×4 mesh:**

```
[R]--[R]--[R]--[R]
 |    |    |    |
[R]--[R]--[R]--[R]
 |    |    |    |
[R]--[R]--[R]--[R]
 |    |    |    |
[R]--[R]--[R]--[R]
```

16 routers in a 2D grid, each with 4 (or 5) ports. Each router connects to one IP block via its local port and to up to 4 neighbours via its mesh ports.

**Traffic flow:**

A packet from router (0,0) to router (3,3) hops through routers along some path: 6 hops minimum. At each hop, the packet enters an input port, the router decides the output port, and forwards.

**Comparison to bus:**

| Property | Bus | NoC |
|---|---|---|
| Scalability | Poor (~10 masters) | Good (100s of nodes) |
| Latency | Constant (depends on bus width) | Variable (depends on hops) |
| Bandwidth | Shared | Distributed across links |
| Wire complexity | $O(1)$ for the shared bus | $O(N)$ links, $O(\sqrt{N})$ longest wire (for mesh) |
| Power | High (long wires) | Lower (short links) |

**Use cases:**

NoCs are ubiquitous in modern SoCs with many cores:

- **Multi-core CPUs:** Intel ring (12+ cores), Intel mesh (24+ cores).
- **GPUs:** NVIDIA's NoC connects SMs to L2 cache slices.
- **Mobile SoCs:** Apple, Qualcomm, MediaTek all use NoCs.
- **AI accelerators:** TPUs, Cerebras, Graphcore use NoCs for compute fabric communication.

**Interview insight:** A candidate who knows NoCs replace shared buses in large SoCs and can articulate why (scalability, power, parallel bandwidth) shows real SoC architecture knowledge.

### Q2. What are the main NoC topologies, and how do they compare?

**Answer:**

The **topology** of a NoC is the arrangement of routers and links. Different topologies have different trade-offs in latency, bandwidth, area, and routing complexity.

**1. Bus / Crossbar:**

Not strictly NoCs but the baseline for comparison.

- **Bus:** all nodes share one wire. $O(N^2)$ contention, worst case.
- **Crossbar:** $N$ inputs to $M$ outputs, all paths possible. $O(NM)$ wires.

Both don't scale.

**2. Ring:**

Routers arranged in a circle, each connected to two neighbours.

```
[R]--[R]--[R]--[R]
 |              |
[R]            [R]
 |              |
[R]--[R]--[R]--[R]
```

- **Pros:** simple, low wire count, regular structure.
- **Cons:** average $N/4$ hops to traverse, latency scales linearly with size.
- **Used by:** Intel Sandy Bridge through Broadwell (12+ cores). Bidirectional ring for shorter average path.

**3. Mesh (2D):**

Routers in a grid.

- **Pros:** good balance of latency and wires. Average hops scale as $\sqrt{N}$.
- **Cons:** corners and edges have asymmetry. Routing more complex.
- **Used by:** Intel Skylake-X+ (mesh of cores), Tilera, many academic designs.

**4. Torus:**

Mesh with wrap-around links.

- **Pros:** more uniform than mesh (no edge effects). Lower diameter.
- **Cons:** wrap-around wires are long. Layout-unfriendly.

**5. Tree / Fat tree:**

Hierarchical, root at the top.

- **Pros:** logarithmic diameter. Good for many-to-one or one-to-many traffic.
- **Cons:** root is a bottleneck. Asymmetric.
- **Used by:** some HPC interconnects, less common on-chip.

**6. Hypercube:**

Each router has $\log_2 N$ neighbours, hypercube structure.

- **Pros:** logarithmic diameter, good throughput.
- **Cons:** wire complexity grows. Layout is very irregular for high dimensions.

**7. Hierarchical / Cluster:**

Combine multiple topologies. E.g., a small ring within each cluster, mesh between clusters.

- **Pros:** can combine the best of different topologies.
- **Cons:** non-uniform, complex routing.

**Comparison metrics:**

| Topology | Diameter | Bisection BW | Wire complexity | Layout |
|---|---|---|---|---|
| Bus | 1 | 1 | 1 | Simple |
| Ring | $N/2$ | 2 | $N$ | Simple |
| 2D Mesh ($\sqrt{N} \times \sqrt{N}$) | $2\sqrt{N}$ | $\sqrt{N}$ | $2N$ | Simple |
| 2D Torus | $\sqrt{N}$ | $2\sqrt{N}$ | $2N$ | Hard (long wires) |
| Hypercube | $\log_2 N$ | $N/2$ | $N \log_2 N$ | Very hard |

**Diameter:** maximum number of hops between any two nodes.
**Bisection BW:** the bandwidth across a "cut" splitting the network in two — measures how much traffic can flow across the network.

**Practical choice — 2D mesh:**

Most modern on-chip NoCs use 2D mesh because:

1. **Layout-friendly.** The 2D grid maps naturally to a 2D chip layout.
2. **Reasonable diameter.** $O(\sqrt{N})$ hops scales acceptably.
3. **Simple routing.** Dimension-order routing (X first, then Y) is easy and deadlock-free.
4. **Good wire utilisation.** Wires only span router-to-router, no long paths.

For smaller designs (< 16 nodes), rings are simpler and adequate.

**Interview insight:** A candidate who can compare topologies and explain why 2D mesh is the modern default shows breadth of NoC knowledge.

### Q3. What is "deadlock" in a NoC, and how is it prevented?

**Answer:**

**Deadlock** in a NoC occurs when packets in different routers wait for each other in a cyclic dependency, with no packet able to make progress. The classic case: A waits for B's resource, B waits for C's, C waits for A's.

**The conditions for deadlock:**

The same Coffman conditions as in OS deadlock:

1. **Mutual exclusion:** routers/buffers are exclusively held.
2. **Hold and wait:** packets hold a buffer while waiting for the next.
3. **No preemption:** packets aren't kicked out.
4. **Circular wait:** a cycle of packets each waiting for the next.

**Why NoCs are prone:**

NoCs use **buffered routers**: each router has buffers to hold packets while waiting for output ports. If two packets going opposite directions both need each other's buffer to proceed, they deadlock.

**Example:**

Two routers, each with one buffer.

- Router A's buffer holds packet P1, going to B.
- Router B's buffer holds packet P2, going to A.
- P1 waits for B's buffer to free. P2 waits for A's buffer to free.
- Neither can proceed. Deadlock.

This is called **buffer deadlock**.

**Prevention strategies:**

**1. Dimension-order routing (XY routing) for mesh:**

Always route in X dimension first, then Y. Never route Y before X.

Why this works: any path goes through a sequence of routers in a strictly increasing X coordinate (until X target is reached), then strictly increasing Y coordinate. There's no way to form a cycle because X always comes before Y.

Simple and deadlock-free, but may not be the shortest path.

**2. Virtual channels:**

Each link has multiple virtual channels (logically separate buffers using the same physical wire). Packets are assigned to specific virtual channels based on routing rules that prevent cycles.

The classic Dally construction uses virtual channels to break dependency cycles.

**3. Bubble flow control:**

Maintain at least one "free" bubble in the buffer chain so packets can always advance.

**4. Deflection routing:**

If a packet can't enter its preferred output port, route it elsewhere instead of waiting. The packet may take a longer path but never waits indefinitely.

Avoids deadlock but increases average latency.

**5. Restricted routing:**

Only allow paths that don't form cycles. E.g., turn-model routing for mesh: forbid certain "turns" (e.g., U-turns) that would create cycles.

**6. Order-based protocols:**

Tag packets with priorities so that lower-priority packets always defer to higher. Ensures progress for high-priority flows.

**Verification:**

Deadlock-freedom is a critical property. Verifying it is hard:

- **Static analysis:** prove the routing function doesn't allow cycles.
- **Simulation:** stress-test under many scenarios.
- **Formal methods:** model the NoC and prove deadlock-freedom mathematically.

A NoC that deadlocks even rarely is broken — silicon failure waiting to happen.

**Interview insight:** A candidate who knows about XY routing as the canonical deadlock-free scheme and can explain why it works (no cycles in the dependency graph) shows real NoC knowledge.

---

## Intermediate

### Q4. What is a "virtual channel" in a NoC, and why is it needed?

**Answer:**

A **virtual channel (VC)** is a logically separate buffer at a router, sharing the same physical link with other VCs but operating independently. VCs let multiple "streams" of packets share one physical link without blocking each other.

**The problem VCs solve:**

Without VCs, each link has one buffer per direction. If a packet at the head of the buffer is blocked (because its destination buffer is full), all packets behind it are also blocked — even if they want to go elsewhere. This is **head-of-line blocking**.

Worse: with one buffer per link, deadlock prevention is hard. Multiple flows on the same buffer can create cycles.

**With VCs:**

Each link has multiple buffers, one per VC. Each packet is tagged with a VC. Different VCs are independent — a blocked packet in VC 0 doesn't block packets in VC 1.

**Multiple flows:**

VCs let different "classes" of traffic share a link without interference:

- **Request and response.** Memory requests on VC 0; responses on VC 1. They can't deadlock each other.
- **Different priority levels.** Latency-critical traffic on VC 0; bulk traffic on VC 1. The router serves VC 0 first.
- **Different protocols.** Coherent traffic on one VC, non-coherent on another.

**Deadlock prevention with VCs:**

A more powerful technique: assign VCs to packets based on routing progress. For example:

- VC 0: packets that haven't yet reached their X destination.
- VC 1: packets that have completed X routing and are doing Y.

Then deadlock can't form because packets always migrate to higher VC indices, breaking the cycle.

**Cost:**

VCs require:

- **More buffer storage.** $K$ VCs need $K$ times the buffer area per link.
- **More complex arbitration.** The router must decide which VC to serve from each input.
- **More control logic.** Tracking which VC each packet uses.

For small NoCs, the overhead is significant. For large NoCs, VCs are essential.

**Typical configurations:**

- **2-4 VCs** for small mesh NoCs: enough for deadlock prevention and basic class separation.
- **8+ VCs** for high-end designs with many traffic classes (Intel mesh, AMD Infinity Fabric).

**Interview insight:** A candidate who can explain that VCs prevent head-of-line blocking AND enable deadlock prevention shows nuanced NoC understanding.

### Q5. What is "wormhole switching" in a NoC?

**Answer:**

**Wormhole switching** is a packet routing technique where a packet is split into smaller units called **flits** (FLow control unITs), and the flits are forwarded one at a time through the network. The first flit (head flit) reserves the path; subsequent flits follow without waiting.

**The "worm" analogy:**

The flits of a packet flow through the network like a worm crawling through a tunnel — the head leads the way, and the body follows in sequence.

**How it works:**

1. **Head flit:** contains routing information (destination address). It enters the source router and is forwarded based on the routing function.

2. **Subsequent flits (body and tail):** follow the head, hop by hop, on the same path. They don't carry routing info — they just follow the head's footsteps.

3. **Tail flit:** the last flit. Marks the end of the packet.

The path from source to destination is "reserved" by the head and held until the tail releases it.

**Comparison to other switching schemes:**

**1. Store-and-forward:**

- Each router waits for the entire packet to arrive before forwarding.
- Buffer must hold the whole packet.
- Latency = packet length × number of hops.

**2. Cut-through:**

- Each router can start forwarding the head once it has enough info, before the rest arrives.
- Buffer must still hold the whole packet (in case forwarding stalls).
- Latency = head latency + packet length / link bandwidth.

**3. Wormhole:**

- Flits flow continuously, end-to-end.
- Buffer only needs to hold a few flits (not the whole packet).
- Latency = head latency + packet length / link bandwidth.

**Advantages of wormhole:**

1. **Small buffers.** Routers don't need to hold whole packets — just a few flits per VC.

2. **Low latency.** Head flit reaches the destination quickly; body follows.

3. **High throughput.** Flits stream through pipelined routers continuously.

**Disadvantages:**

1. **Head-of-line blocking.** If the head is blocked at some router, the entire packet (the whole worm) is stuck. Subsequent packets behind it are also stuck.

2. **More complex deadlock.** A packet's flits across multiple routers can be involved in deadlock cycles.

3. **VCs needed for performance.** Without VCs, head-of-line blocking is severe.

**Mitigations:**

- **Virtual channels** to reduce head-of-line blocking (different worms on different VCs).
- **Adaptive routing** to bypass congested links.
- **Sophisticated arbitration** at routers.

**Used by:**

Almost all modern on-chip NoCs use wormhole switching with multiple VCs. The combination is the "standard" NoC architecture.

**Interview insight:** A candidate who can describe wormhole switching, the role of flits, and head-of-line blocking shows real packet-switched NoC knowledge.

### Q6. How does QoS work in a NoC?

**Answer:**

**Quality of Service (QoS)** in a NoC ensures that different classes of traffic get appropriate latency and bandwidth, even under contention. Critical when the NoC carries a mix of latency-sensitive and bandwidth-sensitive traffic.

**Why it matters:**

Modern SoCs have very different traffic types:

- **CPU memory traffic:** latency-critical. A cache miss waiting on the NoC stalls the CPU.
- **GPU compute traffic:** bandwidth-intensive but latency-tolerant. The GPU has many warps to hide latency.
- **Display refresh:** strict deadline. Must arrive in time for the next frame.
- **Bulk DMA:** background, can wait.

Without QoS, all of these compete equally. The display might miss its deadline because GPU traffic clogged the NoC.

**QoS mechanisms:**

**1. Priority levels:**

Assign each class a priority. High-priority packets are served first at routers.

```
QoS levels:
- Level 0: latency-critical (CPU, display)
- Level 1: response (memory return)
- Level 2: standard (general I/O)
- Level 3: best-effort (DMA, prefetch)
```

Routers' arbiters select the highest-priority packet that's ready.

**2. Bandwidth reservation:**

Allocate a fixed share of link bandwidth to each class. Even under contention, each class gets at least its share.

Example: "GPU gets 50% of the NoC bandwidth, CPU gets 30%, others share the remaining 20%."

**3. Traffic shaping:**

Limit how much traffic each class can inject. Prevents any single class from saturating the network.

**4. Separate VCs per class:**

Assign each class to its own VC. They can't interfere with each other (head-of-line blocking is per-VC).

**5. Deadline-aware routing:**

Each packet carries a deadline. Routers prefer packets with closest deadlines.

**Combination:**

A typical SoC NoC uses several mechanisms together:

- VCs separate traffic classes.
- Priorities ensure latency-critical packets are served first.
- Bandwidth reservation prevents starvation.
- Shaping prevents bursts from overwhelming the network.

**Verification:**

QoS verification requires testing under many scenarios:

- **Worst-case workload.** What latency does CPU traffic see when GPU is at full bandwidth?
- **Mixed workloads.** Do all classes meet their requirements?
- **Burst handling.** What happens when several high-priority bursts arrive simultaneously?

**Performance counters:**

Production NoCs include counters tracking per-class latency and bandwidth. The OS or PMU can monitor and adjust priorities dynamically.

**Standards:**

ARM AMBA defines QoS extensions for AXI-based NoCs (AXI QoS bits). Other standards (CHI for cache-coherent links) include similar facilities.

**Interview insight:** A candidate who can articulate the need for QoS in mixed-traffic SoCs and describe specific mechanisms (priorities, VCs, reservation) shows real SoC interconnect experience.

---

## Advanced

### Q7. How does a coherent NoC differ from a non-coherent one?

**Answer:**

A **coherent NoC** carries cache coherence traffic in addition to plain data. It implements (or supports) a cache coherence protocol like MESI, MOESI, or ARM's CHI.

**The challenge:**

Cache coherence requires complex protocol exchanges:

- A CPU read miss triggers a snoop request to other caches.
- The snoop response may carry data (cache-to-cache transfer).
- Invalidations must propagate to all relevant caches.
- Writeback messages move dirty data to the next level.

These operations involve multiple message types with different semantics and ordering requirements. The NoC must handle them all.

**Differences from a non-coherent NoC:**

**1. Multiple message types.**

Non-coherent: requests and responses (read, write).

Coherent: requests, snoop requests, snoop responses, invalidations, acks, writebacks, completions, etc. Easily 10+ distinct message types.

**2. Multiple VCs.**

Each message type often requires its own VC to prevent deadlock between message classes. A coherence response can't be blocked by a coherence request, or you get a protocol-level deadlock.

CHI specifies 4-7 message classes, each with its own VC.

**3. Strict ordering rules.**

Coherent traffic has ordering constraints:

- Invalidations must be delivered before new data.
- Acknowledgements must reach the originator in order.
- Some operations are "ordered globally"; others are not.

The NoC must enforce these orderings.

**4. Snoop filters / directories.**

To avoid snooping every cache on every miss, coherent NoCs include snoop filters or directory structures that track which caches have copies of which lines.

**5. Larger headers.**

Coherent packets carry more metadata: transaction ID, message type, ordering tags. Headers may be twice the size of non-coherent.

**6. More complex routers.**

Routers in a coherent NoC may need to inspect message contents (e.g., identify snoop requests for filtering) rather than just forwarding blindly.

**Examples:**

- **Intel mesh:** carries coherence between cores and the LLC slices. Multi-VC design.

- **AMD Infinity Fabric:** within a CCD, snoop-based; between CCDs, directory-based with coherence over the fabric.

- **ARM CHI (Coherent Hub Interface):** standard for coherent NoCs. Used in Cortex-A75+, Neoverse, custom ARM SoCs.

- **NVIDIA NVLink:** carries coherence between GPUs and CPUs in some configurations.

**Comparison:**

| Property | Non-coherent | Coherent |
|---|---|---|
| Message types | 2 (req, resp) | 5-15 |
| VCs needed | 2-4 | 4-8+ |
| Ordering | Weak | Per-protocol |
| Router complexity | Low | High |
| Bandwidth overhead | Low | 20-50% from headers and control |

**When to use which:**

- **Non-coherent NoC:** when caches don't share data, or coherence is handled at a different layer (e.g., software). Simpler and faster.

- **Coherent NoC:** when multiple caches need to share data transparently. Required for SMP (symmetric multiprocessing).

Most modern multi-core SoCs use coherent NoCs because the software (OS, applications) expects coherent shared memory.

**Interview insight:** A candidate who can explain why coherent NoCs need multiple VCs and message classes shows real coherence-aware SoC architecture knowledge.

### Q8. Compare ring and mesh topologies for an 8-core CPU. Which is better?

**Answer:**

This is a classic SoC architecture trade-off. Both have been used in real designs.

**Ring (8 cores in a circle):**

```
[Core0]--[Core1]--[Core2]--[Core3]
   |                          |
[Core7]--[Core6]--[Core5]--[Core4]
```

8 routers, 8 links forming a ring. Messages travel around the ring.

**Mesh (3×3 with one hole, or 2×4):**

```
[Core0]--[Core1]--[Core2]--[Core3]
   |       |       |       |
[Core4]--[Core5]--[Core6]--[Core7]
```

8 routers in a 2D grid with mesh links.

**Comparison metrics:**

| Metric | Ring | 2×4 Mesh |
|---|---|---|
| Diameter (max hops) | 4 | 5 |
| Average hops | 2 | 1.875 |
| Bisection bandwidth | 2 links | 2 links |
| Wire complexity | 8 links | 10 links |
| Layout simplicity | Very simple | Moderately simple |
| Scalability | Poor (O(N) diameter) | Better (O(√N)) |

**Surprisingly, for 8 cores, the ring is competitive.**

The ring's average path length (2 hops) is comparable to the mesh's (1.875). The diameter (4 vs 5) is similar. The ring has fewer links and simpler layout.

**Where ring loses:**

1. **Latency at higher core counts.** A 16-core ring averages 4 hops (vs 3 for mesh). At 32+ cores, the difference grows.

2. **Bisection bandwidth.** As core count grows, the mesh's bisection bandwidth grows (more links across the middle). The ring stays at 2 links — a bottleneck for many-to-many traffic.

3. **Hot spots.** The ring's links can saturate under uneven traffic. The mesh distributes load better.

**Where ring wins:**

1. **Simplicity.** Easier to layout, smaller routers, less verification.

2. **Power.** Simpler routers consume less.

3. **Latency for nearby cores.** A ring with cores in adjacent slots has 1-hop latency, often as fast as the mesh's local hop.

**Real-world choices:**

- **Intel Sandy Bridge through Broadwell (2011-2014):** 4-12 core CPUs used a bidirectional ring. Simple, effective.

- **Intel Skylake-X (2017+) and Xeon Scalable:** transitioned to a mesh for 12-28 cores. The mesh scales better at higher core counts.

- **AMD Ryzen / EPYC:** uses a chiplet architecture with rings within each chiplet (8 cores per CCD), connected via Infinity Fabric.

**The transition point:**

Intel's transition from ring to mesh happened around 12-16 cores. Below that, ring is fine; above that, mesh becomes necessary.

**Verdict for 8 cores:**

Both work. Ring is simpler and has lower router complexity. Mesh has slightly better bisection bandwidth and scales better if the core count grows. For exactly 8 cores, the choice often comes down to:

- **Ring if minimising area and complexity.**
- **Mesh if planning for future scaling.**

Most 2024 designs at 8 cores would lean mesh because they anticipate scaling up.

**Interview insight:** A candidate who can quantify the trade-offs and reference real industrial choices (Intel Sandy Bridge → Skylake-X) shows real exposure to NoC architecture decisions.

### Q9. What are the implications of "chiplet" designs for on-chip and inter-chip NoCs?

**Answer:**

**Chiplet** designs split a chip into multiple smaller dies (chiplets) connected in the same package via specialised interconnects. This affects NoCs in important ways.

**The architecture:**

```
Package
├── Compute chiplet 1 (16 cores + L3)
├── Compute chiplet 2 (16 cores + L3)
├── Compute chiplet 3 (16 cores + L3)
├── Compute chiplet 4 (16 cores + L3)
└── I/O chiplet (memory controllers, PCIe, ...)
```

Each chiplet has its own internal NoC (mesh, ring, etc.). The chiplets communicate via an **inter-chiplet interconnect** (Infinity Fabric on AMD, EMIB on Intel).

**Two NoC layers:**

**1. Intra-chiplet NoC.**

Inside each chiplet, a traditional NoC (mesh, ring) connects cores, L3, and the chiplet's external interface.

This is conventional NoC design.

**2. Inter-chiplet interconnect.**

Between chiplets, a different fabric connects each chiplet's external interface to the others. This may be:

- **Mesh between chiplets:** if there are many chiplets.
- **Ring between chiplets:** if 4-8 chiplets.
- **Hub-and-spoke:** if there's a central I/O chiplet (AMD's design).

**Differences from monolithic NoC:**

1. **Higher latency for cross-chiplet traffic.** Off-die signaling has more delay than on-die. Typical: ~10-30 ns extra per chiplet hop.

2. **Limited bandwidth.** Each chiplet has a fixed number of pins for its external interface. Bandwidth is bounded.

3. **Different power per bit.** Off-die signaling uses ~1-5 pJ/bit vs ~0.1-0.5 pJ/bit on-die. Communication is more expensive.

4. **NUMA-like behavior within a package.** Different chiplets have different memory access latencies. Software must be aware.

**Coherence across chiplets:**

If the chiplets are coherent, the coherence protocol must extend across chiplets. This means:

- Snoop requests cross the inter-chiplet fabric.
- Invalidations propagate across chiplets.
- Cache-to-cache transfers go across chiplets.

The inter-chiplet fabric must support coherent traffic — typically with multiple VCs and the same protocol as the intra-chiplet NoC.

**Topology examples:**

**AMD EPYC (Zen 2+):**

- 8 compute chiplets (CCDs), each with 8 cores + 32 MB L3.
- 1 I/O chiplet (IOD) with memory controllers and PCIe.
- All CCDs connect to the IOD via Infinity Fabric.
- Hub-and-spoke topology: every CCD ↔ IOD ↔ every other CCD.

Result: cross-CCD memory access goes through the IOD, adding latency.

**Intel Sapphire Rapids:**

- 4 compute tiles connected via EMIB (Embedded Multi-Die Interconnect Bridge).
- Mesh topology between tiles.
- Internally, each tile has its own mesh.

Result: more uniform topology, but more complex interconnect technology.

**NUMA implications:**

Software (OS, runtime) must consider chiplet placement:

- **Memory allocation:** prefer the chiplet's local memory controller.
- **Thread scheduling:** prefer the chiplet where the thread's data lives.
- **Cache placement:** L3 inside each chiplet is local; cross-chiplet L3 access is slower.

Linux's NUMA support handles this for AMD EPYC; Intel Xeon similarly.

**Future directions:**

- **More chiplets per package.** Designs with 10+ chiplets are emerging.
- **3D stacking.** Chiplets stacked vertically with TSV (through-silicon via) interconnects. Much higher bandwidth, lower latency.
- **Heterogeneous chiplets.** Mix of CPU, GPU, NPU, IO chiplets in one package.

**UCIe (Universal Chiplet Interconnect Express):**

A standard for inter-chiplet communication, supported by major vendors. Aims to enable mix-and-match chiplets from different vendors. Released 2022.

**Interview insight:** A candidate who knows about chiplet NoC layering and the NUMA implications shows current awareness of advanced packaging trends. Chiplets are reshaping interconnect design.

### Q10. How do you verify a NoC for correctness and performance?

**Answer:**

NoC verification is challenging because the design is concurrent, has many interacting parts, and must work for arbitrary traffic patterns.

**Functional verification:**

**1. Directed tests:**

Hand-written tests exercise specific scenarios:

- A → B simple transaction.
- All cores accessing the same memory location.
- Two cores exchanging data.
- Edge cases at routers.

Provides initial confidence but can't cover all cases.

**2. Constrained-random tests:**

A test generator produces random traffic patterns:

- Random source/destination pairs.
- Random packet sizes.
- Random injection rates.
- Random VCs and priorities.

Constraints ensure the patterns are realistic (no impossible addresses, valid protocols). Coverage tracks which scenarios have been exercised.

**3. Stress tests:**

Push the NoC to its limits:

- All sources injecting at max rate.
- Worst-case traffic patterns (hot spots, all-to-all).
- Sustained heavy load.

Look for deadlock, livelock, throughput collapse.

**4. Protocol checkers:**

Assertion-based verification of protocol invariants:

- "Every request gets a response."
- "Responses come in the right order."
- "No cycle in dependencies."
- "Coherence rules are respected."

Failures fire as assertion violations.

**5. Formal verification:**

For critical properties (deadlock-freedom, coherence correctness), use formal model checking. The router's state machine and the routing function are modelled mathematically; the tool proves properties hold for all inputs.

Especially valuable for proving deadlock-freedom of the routing algorithm.

**Performance verification:**

**1. Synthetic traffic patterns:**

- **Uniform random:** each source picks a random destination per packet. Tests average-case behaviour.
- **Hot spot:** all sources target one destination. Tests congestion handling.
- **Bit-reversal:** structured pattern that stresses certain topology hot spots.
- **All-to-all:** every source talks to every destination.

For each pattern, measure:
- Throughput (achieved vs theoretical).
- Latency (average and tail).
- Network saturation point.

**2. Application traces:**

Real workload traces from the target applications (e.g., GPU workloads, databases) replayed through the NoC simulator.

Most realistic but requires having the traces.

**3. Latency vs offered load curves:**

Standard benchmark: plot latency as offered load increases. The curve should be flat at low load, then start rising, then "knee" where latency rapidly grows.

The knee defines the saturation point. For a healthy NoC, saturation should be at ~70-90% of theoretical max throughput.

**Tools:**

- **gem5:** academic simulator with NoC support.
- **BookSim:** standalone NoC simulator, popular in research.
- **Garnet:** part of gem5, full-detail NoC simulation.
- **Commercial simulators:** Synopsys Platform Architect, others.

**Coverage closure:**

Define coverage points for:

- Every router state.
- Every packet type.
- Every VC.
- Every routing decision.
- Every buffer occupancy level.

Track coverage; iterate until full.

**Tape-out signoff:**

NoC must pass:

- 100% functional regression.
- Stress tests with no failures.
- Deadlock-free under all conditions.
- Performance targets met under representative workloads.
- Formal verification of critical properties.

Bugs found in silicon are catastrophic — re-spin a multi-million-dollar mask set. Verification effort is justified.

**Interview insight:** A candidate who can describe both functional and performance verification, name specific traffic patterns, and mention formal verification for deadlock shows mature NoC verification methodology.
