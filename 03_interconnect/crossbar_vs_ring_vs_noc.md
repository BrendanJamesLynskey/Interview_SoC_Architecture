# Crossbar vs Ring vs NoC Topologies

## Overview

The interconnect fabric is the nervous system of a SoC. Every memory access, DMA transfer, and inter-block communication traverses it. The choice of topology determines the chip's peak bandwidth ceiling, latency floor, area cost, and scalability to future product generations. Getting this decision wrong at architecture phase is expensive to fix — the interconnect is deeply embedded in the floorplan and verified against a complex set of ordering and coherency rules.

This document covers the four dominant interconnect topologies used in production SoC design: point-to-point (shared bus baseline), crossbar switch, ring, and network-on-chip (NoC) mesh/torus. For each topology the material covers structure, bandwidth model, latency model, area/power cost, and the real-world conditions under which it is the right choice.

---

## Tier 1: Fundamentals

### Q1. What is a shared bus, and why does it fail to scale beyond a small number of masters?

**Answer:**

A shared bus is a single set of wires carrying address, data, and control signals that is driven by exactly one master at a time. All attached masters and slaves observe every transaction. Access is serialised by an arbiter: only the master that wins arbitration may place its address on the bus during a given cycle.

**Why it fails to scale:**

The fundamental limitation is that bus bandwidth is fixed regardless of how many masters are attached. If the bus is 128 bits wide at 400 MHz, its peak bandwidth is 128/8 × 400 × 10^6 = 6.4 GB/s. The first master can use all of it. Adding a second master does not increase the bandwidth — it halves each master's average share. Adding eight masters reduces average throughput to 800 MB/s per master.

A second failure mode is arbitration overhead. Every cycle where the bus is idle between transactions (while the arbiter selects the next master and the new master drives its address) is wasted bandwidth. For short transfers this overhead is proportionally high.

A third failure mode is wire loading. A shared bus must be driven to all attached agents. As master and slave counts grow, the bus becomes a long, heavily loaded wire with high capacitance. The maximum operating frequency falls. Repeater insertion adds latency.

**Practical limit:** AHB (a shared bus) works well for up to approximately 4–8 masters at low-to-moderate frequencies. Beyond that, a crossbar or hierarchical bus structure is required.

---

### Q2. Describe a crossbar interconnect. What is the key property that makes it superior to a shared bus for a multi-master system?

**Answer:**

A crossbar is a switching matrix that connects $M$ masters to $N$ slaves. It provides a dedicated data path from any master to any slave. The key property is **concurrent non-conflicting transactions**: master 0 accessing slave 0 simultaneously with master 1 accessing slave 1. A shared bus cannot do this — it serialises all transactions regardless of whether they conflict.

**Structure:**

The crossbar contains $M \times N$ switch points. Each switch point is a tri-state buffer or multiplexer cell that can connect its master input to its slave output. At each clock cycle, the arbitration logic in each slave selects at most one master to connect, and the routing matrix configures the corresponding paths.

**Bandwidth model:**

For an $M \times N$ crossbar with data width $W$ bits at frequency $f$:
- Peak aggregate bandwidth = $\min(M, N) \times W/8 \times f$ bytes/second
- This assumes no two masters target the same slave simultaneously

For example, 4 masters, 4 slaves, 128-bit wide at 800 MHz: peak aggregate = 4 × 16 × 800 × 10^6 = 51.2 GB/s, compared to 12.8 GB/s for a single shared bus at the same width and frequency.

**Cost:**

Area scales as $O(M \times N)$. A 4×4 crossbar is practical. A 16×16 crossbar has 256 switch points, becomes very large, and has long routing wires at each switch point that limit frequency. AXI interconnects (NIC-400, CoreLink NIC-450) are implemented as crossbars for mainstream SoC configurations up to roughly 16 masters.

**Common mistake:** Assuming a crossbar eliminates all contention. It eliminates path contention between masters targeting different slaves. It does not eliminate contention at a single slave — if three masters all request DRAM simultaneously, two must wait, even in a crossbar.

---

### Q3. What is a ring interconnect? Describe the structure and the bandwidth/latency model.

**Answer:**

A ring interconnect connects agents in a loop. Each agent has a single input port (from the previous agent) and a single output port (to the next agent). Messages hop from agent to agent around the ring until they reach their destination. A message that misses its stop must continue around the full ring.

**Structure:**

A ring typically consists of multiple parallel "rings" (also called slices), one for each of: request, response, acknowledge, and sometimes snoop. Each ring carries fixed-width flits (flow control units) — commonly 18–72 bits wide per slice. Agents inject flits into an empty slot on the ring; the ring rotates continuously at the operating clock frequency.

**Bandwidth model:**

For a ring of $N$ nodes, ring width $W$ bits per flit, frequency $f$, and assuming all slots equally available:
- Maximum injection bandwidth per node = (1/N) × $W/8 \times f$ bytes/second
- This assumes round-robin slot allocation and full ring utilisation

For N = 8 nodes, 64-bit flit width, 1 GHz: per-node bandwidth = 1/8 × 8 × 1 × 10^9 = 1 GB/s. This is a fundamental scalability limit — bandwidth per node shrinks as node count grows.

**Latency model:**

Average hop count = N/4 (random destination on a ring of N nodes, taking the shorter of two directions for a bidirectional ring).

For N = 8 bidirectional ring, with 1 cycle per hop at 1 GHz: average latency = 2 hops × 1 ns = 2 ns plus injection and ejection pipeline latency (typically 4–8 cycles).

**Advantages:**
- Very low area: only nearest-neighbour wiring required
- Deterministic latency: worst case is N/2 hops (unidirectional) or N/4 hops (bidirectional)
- Wire-length efficient for floorplans where agents form a natural ring

**Use in practice:** Intel's Sandy Bridge and subsequent architectures used a bidirectional ring connecting cores, L3 cache slices, memory controllers, and PCIe. The ring frequency was 3+ GHz with multiple parallel rings. This worked well at 4–8 nodes; at larger node counts Intel migrated to a mesh.

---

### Q4. What is a Network-on-Chip (NoC), and what problems does it solve that rings and crossbars cannot?

**Answer:**

A Network-on-Chip (NoC) applies packet-switching network principles to on-chip communication. Agents connect to routers via local ports. Routers are connected to neighbouring routers via links in a regular topology (mesh, torus, fat-tree, butterfly). Messages are packetised into flits and routed hop-by-hop from source router to destination router, then delivered to the destination agent.

**Problems solved:**

1. **Scalability beyond crossbar area limits:** A 2D mesh of $N$ nodes requires only $O(N)$ routers and $O(\sqrt{N})$ maximum hop count. A crossbar requires $O(N^2)$ switch points. For $N > 16$, the mesh is smaller than the full crossbar.

2. **Bandwidth scalability:** Each link in the mesh is a point-to-point wire, and multiple links can carry traffic simultaneously. Aggregate bisection bandwidth scales as $O(\sqrt{N})$ for a 2D mesh. A shared bus and a ring both have fixed total bandwidth independent of node count.

3. **Modularity and reuse:** A NoC with standardised router interfaces can be instantiated with different topologies by changing which routers are connected. Agents connect to routers through a standard network interface; no agent-specific modification is required when scaling from 16 to 64 nodes.

**Latency cost:**

Each router hop adds latency. A typical NoC router pipeline is 2–5 cycles per hop. A 4×4 mesh has a maximum of 6 hops (corner to corner), adding 12–30 cycles. For latency-sensitive traffic (cache fills, CPU stalls), this can be problematic. Many commercial NoC implementations provide virtual cut-through switching to minimise router pipeline latency.

**Use in practice:** Arm's CoreLink CMN-600 and CMN-700 implement a 2D mesh NoC for large CPU clusters, GPU, memory controllers, and accelerators in premium mobile and server SoCs. GPU SoCs (NVIDIA, AMD) use 2D mesh or torus topologies for inter-tile communication.

---

## Tier 2: Intermediate

### Q5. Compare crossbar, ring, and 2D mesh topologies across bandwidth, latency, area, and scalability. When would you choose each?

**Answer:**

**Comparative table:**

| Property | Shared Bus | Crossbar | Ring | 2D Mesh (NoC) |
|---|---|---|---|---|
| Peak aggregate bandwidth | Fixed, O(1) | O(min(M,N)) | Fixed, O(1) | O(N) bisection |
| Bandwidth per node | Decreases as 1/N | Near-constant (no conflict) | Decreases as 1/N | Near-constant |
| Best-case latency | 1 hop + arb | 1 hop + arb | ~N/4 hops | 1 hop (local) |
| Worst-case latency | N masters waiting | N masters at same slave | N/2 hops | ~2√N hops |
| Area scaling | O(N) (wires only) | O(M×N) switch fabric | O(N) (ring wires) | O(N) (routers + links) |
| Frequency scaling | Poor (long wires) | Moderate (distributed arb) | Good (short hops) | Good (pipelined links) |
| Design complexity | Low | Moderate | Low-Moderate | High |
| Node count sweet spot | 2–8 | 4–16 | 4–12 | 8–256+ |

**Selection guidance:**

**Shared bus (AHB/APB):** Choose for peripheral subsystems with low bandwidth requirements and infrequent access — UARTs, timers, GPIO. Traffic is irregular and latency tolerance is high. Bandwidth ceiling is not a bottleneck.

**Crossbar (AXI crossbar):** Choose for the main SoC interconnect fabric connecting CPU cluster, DMA, GPU, video pipeline, and DRAM controller when node count is 4–16. The non-blocking property is critical: DMA burst transfers must not stall the CPU's instruction fetch path. Arm CoreLink NIC-400 is a production example.

**Ring:** Choose when nodes form a natural linear or ring floorplan, latency is bounded and predictable, and bandwidth per node is moderate. Useful for connecting L3 cache slices to memory controllers and cores in a CPU subsystem (Intel Ring Bus). The low area cost relative to a crossbar is the primary advantage at 4–10 nodes.

**2D Mesh NoC:** Choose for large-scale SoCs with 16+ agents, heterogeneous traffic patterns, and high aggregate bandwidth requirements. Required when scalability beyond a single node generation is an explicit goal — adding cores or accelerators should not require redesigning the interconnect. Premium mobile AP, HPC, and server SoCs.

---

### Q6. Derive the bisection bandwidth of a 2D mesh NoC and explain why it is the relevant metric for traffic-intensive workloads.

**Answer:**

**Bisection bandwidth definition:**

Bisection bandwidth is the minimum bandwidth across any cut that divides the network into two equal halves. It represents the bottleneck bandwidth for the worst-case traffic pattern in which half the nodes are sending to the other half.

**2D mesh derivation:**

Consider an $N = k \times k$ 2D mesh (so $N$ total nodes, $\sqrt{N}$ nodes per row/column). Each link carries bandwidth $b$ (in GB/s).

To bisect the mesh, cut along the middle column. This severs $k = \sqrt{N}$ links (the links connecting column $k/2$ to column $k/2 + 1$).

$$\text{Bisection bandwidth} = \sqrt{N} \times b$$

For a 64-node mesh (8×8), with 32 GB/s per link: bisection bandwidth = 8 × 32 = 256 GB/s.

**Comparison to ring bisection:**

A ring bisection cuts the ring at two points, severing 2 links:

$$\text{Bisection bandwidth (ring)} = 2 \times b$$

For the same 64-node ring with 32 GB/s per link: bisection bandwidth = 64 GB/s — four times less than the mesh.

**Why bisection bandwidth matters:**

For all-to-all traffic (typical in GPU shader invocations, multi-core cache coherency storms, or transformer model inference), the traffic matrix has significant cross-chip communication. Bisection bandwidth is the fundamental limit: no scheduling, routing, or QoS policy can deliver more than the bisection bandwidth to cross-chip flows. A network with insufficient bisection bandwidth will throttle at high load regardless of per-node bandwidth figures.

**Common mistake:** Comparing peak per-node bandwidth between a ring and a mesh and concluding they are equivalent. The ring's per-link bandwidth may be higher, but its bisection bandwidth is fixed at 2 links regardless of node count. The mesh bisection bandwidth grows with node count.

---

### Q7. What are virtual channels in a NoC router, and why are they necessary to prevent deadlock?

**Answer:**

**Virtual channels (VCs):**

A virtual channel is a logical queue inside a physical link. Multiple VCs share the same physical wires but maintain separate flit buffers and flow control state. From the sender's perspective, multiple independent logical channels exist on the same physical link.

**Why deadlock occurs without VCs:**

In a wormhole-switched network (where the head flit reserves a path and body flits follow), a circular dependency can form. Consider four packets in a 2×2 mesh:

- Packet A: (0,0) → (1,1), occupying link (0,0)→(1,0), waiting for (1,0)→(1,1)
- Packet B: (1,0) → (0,0), occupying link (1,0)→(0,0), waiting for (0,0)→(0,0) — already occupied by Packet A

If each packet holds a link and waits for the link ahead (also held), a circular dependency forms: A waits for B's link, B waits for A's link. Neither can advance. This is a routing-induced deadlock.

**How VCs break deadlock:**

The standard solution is Dally and Seitz's turn-model or the use of VC classes. Packets are assigned to different VC classes based on their position in the routing path. The assignment rule ensures no circular dependency can form across VC classes:

1. Escape VCs: A restricted set of VCs that use a deadlock-free routing algorithm (e.g., dimension-order routing). Any packet that would otherwise contribute to a cycle is routed through an escape VC.
2. Adaptive VCs: Packets may use any route in non-escape VCs, but if blocked, they must fall back to the escape VC.

Because the escape VCs are deadlock-free, and the adaptive VCs always have an escape, the network as a whole is deadlock-free.

**Practical VC counts:** Commercial NoC routers typically implement 4–8 VCs per port. Each additional VC requires additional buffer area. The tradeoff between deadlock avoidance, throughput improvement, and area cost drives VC count selection. For cache coherency traffic (request, response, snoop channels), separate VCs for each channel class are the minimum requirement.

---

### Q8. What is the difference between a fat-tree topology and a 2D mesh, and when would you choose a fat-tree for a SoC?

**Answer:**

**2D Mesh:**

A 2D mesh connects nodes in a grid. Each internal node has 4 neighbours (N, S, E, W) plus its local agent port. Links are all the same width. Bisection bandwidth is $O(\sqrt{N})$, which means it becomes the bottleneck at high node counts under adversarial traffic.

**Fat-tree:**

A fat-tree is a hierarchy of switches where links toward the root are wider (more ports or higher bandwidth) than links toward the leaves. In a k-ary fat-tree, each switch has $k$ ports upward and $k$ ports downward. The bandwidth of upward links equals the bandwidth of downward links — the "fat" ensures that bandwidth is non-blocking from leaves to root.

For a $k$-ary, $\ell$-level fat-tree: $N = (k/2)^\ell \times k$ leaf ports. All-to-all traffic is non-blocking if the up-links have the same aggregate bandwidth as the down-links.

**Fat-tree advantages:**
- Non-blocking (or nearly so) under arbitrary traffic patterns, because the bandwidth at each level equals the leaf bandwidth
- Lower average hop count for random traffic compared to 2D mesh of same node count
- Natural mapping to hierarchical SoC structures (e.g., clusters of cores connected to cluster switches, which connect to a system switch)

**Fat-tree disadvantages:**
- The root-level switches are large and long-reach wires from leaves to root are costly in area and power
- The topology is harder to map to a 2D floorplan than a regular mesh
- As node count grows, the number of physical root-level switch ports becomes very large

**When to choose fat-tree for SoC:**

Choose a fat-tree when traffic is highly non-uniform (bursty all-to-all, e.g., multi-core coherency) and the SoC has a hierarchical cluster structure. A 4-core cluster with shared L2, connected to a system interconnect, maps naturally to a 2-level fat-tree. ARM's AMBA 5 CHI uses a hierarchical cross-point structure (Home Node, Slave Node, Request Node) that is conceptually a fat-tree. Tile-based GPU SoCs also use fat-tree topologies for inter-tile shared memory traffic.

---

## Tier 3: Advanced

### Q9. A SoC has 8 CPU cores, 4 accelerator blocks, 2 DRAM controllers, and 1 PCIe controller. Walk through an architectural analysis to select between a crossbar, a ring, and a 2D mesh. Quantify the bandwidth requirements and justify the topology choice.

**Answer:**

**Step 1 — Estimate bandwidth requirements:**

Assume:
- Each CPU core: peak 32 GB/s read bandwidth (2 load units × 64B cache line × 2 GHz × 0.25 load-per-cycle = ~16 GB/s; round to 32 GB/s peak including prefetch)
- Each accelerator: 64 GB/s peak (bulk DMA streaming)
- Each DRAM controller: 51.2 GB/s (LPDDR5-6400, 64-bit channel)
- PCIe controller: 32 GB/s (PCIe 5.0 ×8)

CPU aggregate: 8 × 32 = 256 GB/s
Accelerator aggregate: 4 × 64 = 256 GB/s
Total peak demand: 512 GB/s
DRAM supply: 2 × 51.2 = 102.4 GB/s

The DRAM supply is always the bottleneck at sustained load. Interconnect bandwidth must not be a secondary bottleneck. Target: interconnect should sustain at least 128 GB/s aggregate (1.25× DRAM capacity as headroom).

**Step 2 — Evaluate crossbar:**

A 15-master × 3-slave crossbar (15 agents: 8 CPU + 4 accel + 1 PCIe; 3 slaves: 2 DRAM + shared LLC or system cache). At 128-bit data paths, 1 GHz:

- Per-link bandwidth: 16 GB/s
- 3 slave ports aggregate: 48 GB/s — far short of 128 GB/s target

To reach 128 GB/s, need 128/16 = 8 slave ports minimum. This makes the crossbar 15×8 = 120 switch points. Feasible but area-costly, and 15-master arbitration per slave port has significant timing pressure at 1 GHz.

**Step 3 — Evaluate ring:**

A 15-node ring at 256-bit flit width, 2 GHz: per-link bandwidth = 32/8 × 2 × 10^9 = 64 GB/s total ring bandwidth shared across all nodes. With 15 nodes, average per-node share = 64/15 ≈ 4.3 GB/s — far below the 32 GB/s each CPU needs. Ring is disqualified.

**Step 4 — Evaluate 2D mesh (4×4 = 16 nodes, one unused):**

A 4×4 mesh with 15 active nodes, 256-bit links, 2 GHz:
- Per-link bandwidth = 64 GB/s
- Bisection bandwidth (cut along centre column, 4 links severed): 4 × 64 = 256 GB/s
- This exceeds the 128 GB/s target with 2× headroom

Router latency: 3 cycles per hop, worst case 6 hops (corner to corner) = 18 cycles = 9 ns at 2 GHz. For cache fill (200–400 cycle penalty), this is acceptable.

**Step 5 — Decision:**

The 2D mesh (NoC) is the appropriate choice:
- Bisection bandwidth 256 GB/s vs 128 GB/s target: adequate headroom
- Scales to future products by adding nodes
- Area cost is lower than an equivalent-bandwidth crossbar at this node count
- Latency (9 ns worst-case) is acceptable relative to DRAM latency (60+ ns)

**Implementation note:** Use Arm CoreLink CMN-700 or equivalent commercial NoC IP. Map 8 CPU cores to 8 Request Nodes, 4 accelerators to Slave Nodes with DMA capability, DRAM controllers to 2 Home Nodes, PCIe to a Slave/Request Node. Configure 4 VCs (REQ, RSP, SNP, DAT channels) for AMBA CHI coherency.

---

### Q10. Explain how turn model routing prevents deadlock in a 2D mesh without requiring virtual channels. What are its limitations?

**Answer:**

**Turn model background (Dally and Seitz, Glass and Ni):**

In a 2D mesh, there are eight possible turns a packet can make at a router: North-to-East, North-to-West, East-to-North, East-to-South, South-to-East, South-to-West, West-to-North, West-to-South.

Deadlock in wormhole-switched networks requires a cycle in the channel dependency graph. A cycle requires at least one turn in each of the four quadrants (e.g., E→N turn followed by N→W turn followed by W→S turn followed by S→E turn). If any single turn in each of two complementary pairs is prohibited, no cycle can form.

**West-first routing (one turn model example):**

Rule: packets must complete all westward hops before turning. Westward (W) movement is always allowed. After turning north or south (away from west), no further westward movement is allowed. After turning east, no westward turns are allowed.

This prohibits the turns: N→W and S→W (once a packet has moved east, it cannot re-enter western links). With these turns prohibited, a cyclic channel dependency cannot form, because any cycle would require an N→W or S→W turn.

**Other turn models:**

- **North-last:** Complete all non-northward hops before moving north
- **Negative-first:** Complete all negative-direction hops first
- **Odd-even:** Based on column parity — specific turns are allowed only on even/odd columns

**Advantages over VC-based deadlock avoidance:**
- No additional buffer area for VCs
- Simpler router microarchitecture
- Lower latency (no VC allocation step)

**Limitations:**

1. **Suboptimal routing:** By prohibiting certain turns, the routing algorithm cannot use the shortest path for all source-destination pairs. Some packets must take longer routes, increasing average hop count and latency by up to 20–30% for adversarial traffic patterns.

2. **Load imbalance:** Prohibited turns concentrate traffic on allowed paths. In a west-first mesh, eastern links carry less traffic than western links for uniformly distributed traffic, leaving bandwidth stranded.

3. **Not applicable to complex topologies:** Turn models apply directly to 2D mesh and torus. For fat-tree, butterfly, or irregular topologies, VC-based deadlock avoidance is the standard approach.

4. **Coherency protocol interaction:** Cache coherency protocols introduce additional message dependency constraints beyond routing. Turn-model routing alone may not prevent protocol-level deadlock (where a protocol message waiting for a response is blocked by an earlier protocol message that cannot advance). VCs with separate channel classes are the standard solution for coherency-aware NoCs.

**Production usage:** Arm's AMBA 5 CHI specification separates traffic into REQ, RSP, DAT, and SNP channels, each carried on separate virtual channels in the NoC. This is not turn-model routing — it is VC-based channel separation for both routing deadlock and protocol deadlock avoidance.

---

## Quick Reference: Interconnect Topologies

| Topology | Area | Latency | Bandwidth Scaling | Node Count |
|---|---|---|---|---|
| Shared bus | O(N) wires | Arb + 1 hop | Fixed | 2–8 |
| Crossbar | O(M×N) | 1 hop + arb | O(min(M,N)) | 4–16 |
| Ring | O(N) | O(N/4) hops | Fixed (total) | 4–12 |
| 2D mesh | O(N) routers | O(√N) hops | O(√N) bisection | 8–256+ |
| Fat-tree | O(N log N) | O(log N) hops | O(N) bisection | 8–512+ |

| Formula | Meaning |
|---|---|
| BW = W/8 × f | Link bandwidth (bytes/s) from width W (bits) and frequency f |
| BW_bisection (mesh) = √N × b | Bisection bandwidth for N-node 2D mesh, b per-link bandwidth |
| BW_bisection (ring) = 2b | Bisection bandwidth for any ring regardless of N |
| Avg hops (bidi ring) = N/4 | Average hop count, bidirectional ring |
| Avg hops (2D mesh) ≈ 2√N/3 | Average hop count, random traffic, 2D mesh |
