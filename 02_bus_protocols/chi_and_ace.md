# CHI and ACE Protocols

## Overview

AMBA CHI (Coherent Hub Interface) and ACE (AXI Coherency Extensions) are ARM's protocols for
cache-coherent multi-processor interconnects. They extend the memory transaction model to include
snoop operations, cache state tracking, and coherency maintenance, enabling multiple CPU clusters
to share a consistent view of memory without software-managed cache flushing on every shared
data access.

CHI (introduced in AMBA 5) is the newer protocol, used in high-performance ARM cluster interconnects
(CoreLink CMN-600, CMN-700) for Neoverse and Cortex-A series multi-cluster systems. ACE (AMBA 4)
is the predecessor, extending AXI4 with coherency channels.

```
Coherency Protocol Hierarchy:

  AXI4         -- no coherency; software must maintain coherency explicitly
  ACE          -- AXI4 + snoop channels (AC, CD, CR); full cache coherency
  ACE-Lite     -- AXI4 + one-way snooping; for IO coherent masters (DMA, GPU)
  CHI          -- new layered protocol; replaces ACE in ARMv8+ systems
               -- request/response/snoop/data sub-channels
               -- supports larger cluster counts, NUMA, domain-based coherency
```

---

## Fundamentals

### Q1. Why is cache coherency needed in a multi-processor SoC?

**Question:** Two Cortex-A72 cores share a 1 MB L2 cache. Core 0 writes to address 0x4000.
Core 1 subsequently reads address 0x4000. Without coherency hardware, what problem occurs?
How does hardware coherency prevent it?

**Answer:**

**The coherency problem without hardware support:**

```
Initial state: Memory[0x4000] = 0x00

Core 0 writes:
  Core 0 cache line for 0x4000 -> MODIFIED (dirty, value = 0xAA)
  Memory[0x4000] still = 0x00   (write-back policy: not yet written to memory)

Core 1 reads 0x4000:
  Core 1 cache: MISS (line not present)
  Core 1 fetches from memory: gets 0x00  (STALE -- Core 0's write is invisible)
  Core 1 sees wrong value!
```

This is the **coherency problem**: multiple caches hold different values for the same address.
Without hardware coherency:
- Software must explicitly flush Core 0's cache before Core 1 reads.
- This requires OS-level barriers (cache maintenance operations -- CMO), which are expensive
  (tens to hundreds of cycles per cache line) and error-prone.

**Hardware coherency solution (MESI/MOESI protocol via ACE/CHI):**

```
Core 0 writes to 0x4000:
  Core 0 issues a write request to the interconnect.
  Interconnect: snoops Core 1's cache for 0x4000.
  Core 1 response: MISS (line not cached) -> no action needed.
  Core 0's cache line state: MODIFIED (dirty, valid data).

Core 1 reads 0x4000:
  Core 1 issues a read request to the interconnect.
  Interconnect: snoops Core 0's cache (which has the dirty line).
  Core 0 response: MODIFIED line hit -> supplies data to Core 1 (cache-to-cache transfer).
  Core 0 state change: MODIFIED -> SHARED or INVALID (protocol dependent).
  Core 1 receives data: 0xAA (correct value, up-to-date).
  Memory may be updated (write-back) or not, depending on protocol.
```

Hardware coherency eliminates the need for software cache maintenance in normal shared-memory
operations, enabling transparent multi-core programming models.

---

### Q2. What are the ACE coherency channels? How do they extend AXI4?

**Question:** ACE adds three channels to AXI4. Name them, describe their direction and purpose,
and explain how they implement the snoop mechanism.

**Answer:**

ACE (AXI Coherency Extensions) adds three channels to the standard AXI4 five-channel set:

| Channel | Abbreviation | Direction | Purpose |
|---------|-------------|-----------|---------|
| Snoop Address | AC | Interconnect to Master | Interconnect sends a snoop request to the master's cache |
| Snoop Data | CD | Master to Interconnect | Master returns dirty cache line data in response to a snoop |
| Snoop Response | CR | Master to Interconnect | Master returns cache state information (hit/miss/dirty/clean) |

**Full ACE channel set:**

| Channel | Direction | Type |
|---------|-----------|------|
| AW, W, B | Master to Slave (write) | Standard AXI4 |
| AR, R | Master to Slave (read) | Standard AXI4 with coherency transactions |
| AC | Interconnect to Master | Snoop request |
| CD | Master to Interconnect | Snoop data |
| CR | Master to Interconnect | Snoop response |

**ACE snoop operation flow (CleanUnique example):**

```
Scenario: Core 0 wants exclusive write access to a shared cache line at 0x8000
  (line currently SHARED in Core 0 and Core 1)

Step 1: Core 0 issues ReadUnique on AR channel (ARSNOOP=ReadUnique)
Step 2: Interconnect receives request. Sends snoop:
  AC channel -> Core 1: SNOOP(CleanInvalid, 0x8000)

Step 3: Core 1's snoop filter responds:
  CR channel: CRRESP indicating line was SHARED, now INVALID (clean, no data)
  (since Core 1's copy was clean, no CD data response needed)

Step 4: Interconnect forwards data to Core 0 (from memory or from another cache).
  R channel -> Core 0: data + RespUnique (exclusive granted)

Step 5: Core 0 line state: UNIQUE/MODIFIED
  Core 1 line state: INVALID
  Core 0 can now write without further coherency actions.
```

**ACSNOOP encoding (partial):**

| ACSNOOP | Operation |
|---------|-----------|
| 4'b0000 | ReadClean |
| 4'b0001 | ReadShared |
| 4'b0010 | ReadUnique |
| 4'b1000 | ReadOnce |
| 4'b1001 | CleanShared |
| 4'b1010 | CleanInvalid |
| 4'b1101 | MakeInvalid |

---

### Q3. What is ACE-Lite and when is it used?

**Question:** Describe ACE-Lite. What does it provide that standard AXI4 does not? What does it
lack compared to full ACE? Give a concrete use case.

**Answer:**

**ACE-Lite** is a subset of ACE designed for **IO-coherent masters** -- devices that need to
observe the coherency domain (see up-to-date data from CPU caches) but that do not themselves
have a local cache that can be snooped.

**ACE-Lite feature set:**

| Feature | AXI4 | ACE-Lite | ACE Full |
|---------|------|----------|---------|
| Snoop outgoing (receive AC snoop) | No | No | Yes |
| Issue coherent reads | No | Yes | Yes |
| Issue coherent writes | No | Yes | Yes |
| Barrier operations | No | Yes (domain barriers) | Yes |
| RRESP domain/status | No | Yes | Yes |
| CD/CR channels | No | No (cannot be snooped) | Yes |
| Cache maintenance operations | No | Yes (limited) | Yes |

**Key characteristic:** ACE-Lite masters can issue transactions with coherency attributes
(ARDOMAIN, AWDOMAIN) so the interconnect knows to look up the snoop filter before going to
memory. The interconnect ensures the master reads up-to-date data even if it resides in a CPU
cache. However, the interconnect cannot send snoop requests back to an ACE-Lite master because
ACE-Lite masters have no AC/CD/CR channels.

**Use case: DMA engine accessing shared memory**

A DMA engine transfers data to a GPU from a buffer that a CPU core has recently written (and
the data is in the CPU's L1/L2 cache, not yet written back to DRAM).

Without coherency: The DMA reads stale data from DRAM. Software must explicitly flush the CPU
cache before initiating the DMA.

With ACE-Lite DMA: The DMA issues a coherent read on the AR channel (ARDOMAIN=OuterShareable).
The interconnect snoops the CPU cluster, finds the dirty line, and returns the up-to-date data
to the DMA directly (cache-to-device transfer). No software cache flush required.

**Other ACE-Lite users:** GPU shader engines, video encoders/decoders, network DMA, PCIe endpoint DMA.

---

### Q4. What is AMBA CHI? How does it differ from ACE?

**Question:** AMBA 5 introduced the CHI protocol. What architectural problems with ACE did CHI
address? What are the main structural differences?

**Answer:**

**Problems with ACE that motivated CHI:**

1. **Scalability.** ACE extends AXI4 channels. For a system with 16+ CPU clusters, the point-to-point
   AXI channel approach requires a very large, physically centralised interconnect. CHI uses a
   layered, packet-based approach suitable for mesh/ring topologies (CMN mesh).

2. **Channel count and wiring.** ACE adds AC, CD, CR channels per master. With full ACE, each
   master interface has 8 channels. CHI reduces this to 3 virtual channels: Request, Response,
   and Data -- multiplexed over fewer physical wires.

3. **NUMA and domain support.** Modern ARM server chips (Neoverse N1, V1) have multiple
   NUMA nodes. CHI has built-in support for system-level address spaces, multiple home nodes
   (HN-F, HN-I), and request nodes (RN-F, RN-I) across a mesh.

4. **Protocol complexity.** ACE required per-transaction tracking at the interconnect with
   complex merge logic. CHI formalises the state machine into a well-defined transaction
   protocol with explicit message types.

**CHI structural differences from ACE:**

| Aspect | ACE | CHI |
|--------|-----|-----|
| Physical structure | Extended AXI4 channels | Layered packet protocol |
| Channels | 8 (5 AXI + AC/CD/CR) | 3 virtual channels (REQ/RSP/DAT) per direction |
| Node model | Master/Slave | Request Node (RN), Home Node (HN), Subordinate Node (SN) |
| Topology | Star (centralised interconnect) | Mesh/ring (CHI links between nodes) |
| Transaction types | ARSNOOP/AWSNOOP encodings | Named transaction types (ReadUnique, WriteBack, etc.) |
| Exclusive access | ARLOCK/AWLOCK | CHI has dedicated exclusive sequence |
| QoS | AXQOS | CHI QoS with starvation avoidance |
| DVM (TLB maintenance) | Via separate AMBA DVM messages | Built-in DVM transaction type |

**CHI node types:**

```
RN-F (Request Node - Full):     CPU cluster; has a local cache; can be snooped
RN-I (Request Node - IO):       IO master; like ACE-Lite; no cache; cannot be snooped
RN-D (Request Node - DVM):      Only issues DVM (TLB) messages
HN-F (Home Node - Full):        Manages coherency for a memory region; issues snoops
HN-I (Home Node - IO):          Manages non-cacheable memory regions
SN-F (Subordinate Node - Full): DRAM controller; receives memory requests from HN-F
SN-I (Subordinate Node - IO):   Peripheral (like APB); receives non-cacheable requests
```

---

## Intermediate

### Q5. Explain the MESI protocol states and how they map to ACE/CHI transactions.

**Question:** Describe the four MESI states. For a SharedClean line, what transactions does the
cache issue when it needs to: (a) write to the line, and (b) evict the line?

**Answer:**

**MESI cache line states:**

| State | Abbreviation | Meaning |
|-------|-------------|---------|
| Modified | M | Line is valid, dirty (different from memory), exclusive ownership. Cache must write back on eviction. |
| Exclusive | E | Line is valid, clean (same as memory), exclusive (no other cache has it). Can write without bus transaction. |
| Shared | S | Line is valid, clean. May be present in other caches. Cannot write without first upgrading. |
| Invalid | I | Line is not present in this cache (or has been invalidated). |

**State transition diagram:**

```
         READ HIT              WRITE HIT
   S ─────────────> S      S ──────────> M  (upgrade: ReadUnique, invalidate others)
   E ─────────────> E      E ──────────> M  (silent upgrade: no bus transaction)
   M ─────────────> M      M ──────────> M  (no transaction: already exclusive)
   I ─read─────────> S/E   I ─write──> M   (ReadUnique or MakeInvalid from I state)

   Snoop received:
   M ─CleanInvalid─> I  (must write back data: dirty data supplied via CD channel)
   S ─CleanInvalid─> I  (clean: only CR response needed, no data)
   E ─CleanInvalid─> I  (clean: only CR response needed, no data)
```

**Scenario (a): Write to a SharedClean line**

The cache has the line in S (Shared) state and needs to write. It cannot write without first
obtaining exclusive ownership and invalidating other copies:

```
ACE transaction: MakeUnique (or CleanUnique / ReadUnique depending on situation)
  AWSNOOP = CleanUnique (upgrade request: "I want unique ownership, data is clean in my cache")

Interconnect action:
  1. Issue CleanInvalid snoop (AC channel) to all other caches sharing the line.
  2. Other caches respond (CR channel): line invalidated, no dirty data.
  3. Return upgrade response to requesting cache (RRESP with UniqueClean).

Cache state transition: S -> M (after receiving UniqueClean response)
```

**Scenario (b): Evict a SharedClean line**

When the cache needs to evict a Shared (clean) line to make room for another allocation:

```
ACE transaction: Evict (or simply drop the line -- clean evictions can be silent)
  In ACE, SharedClean evictions may be silent (no transaction needed since memory is up-to-date).
  The cache simply invalidates the line: S -> I.
  Optional: send a CleanShared to release any exclusive hint.

In CHI: WriteEvictFull or WriteEvictorEvict depending on whether a snoop filter
        needs to be notified.
```

**MOESI extension:** The MOESI protocol adds the **Owned** state (O) -- dirty data shared with
other caches. In MOESI, the owner cache holds the most up-to-date copy (possibly dirty) and is
responsible for supplying data to other caches on snoop. This reduces write-back traffic to memory
but adds complexity to the state machine.

---

### Q6. What is a snoop filter and why is it critical for CHI/ACE performance?

**Question:** Describe the purpose and operation of a snoop filter. What is the difference between
a full directory and a partial (limited) snoop filter? What happens on a snoop filter miss?

**Answer:**

**Without a snoop filter:**

In a naive coherency implementation, every read or write transaction requires the interconnect to
broadcast a snoop request to ALL caches in the system. This is called **broadcast snooping**:

```
Core 0 reads address X:
  Interconnect broadcasts snoop to all 16 caches
  15 caches respond "no data"
  1 cache may respond with data (or all respond miss -> memory fetch)

Overhead: 16 snoop messages + 16 responses for every transaction.
At 100 MHz transaction rate with 16 cores: 1.6 billion snoop messages per second.
```

This is impractical beyond 4-8 cores.

**Snoop filter purpose:**

A snoop filter (also called a directory) maintains a record of which caches hold a copy of each
cache line. The interconnect consults the snoop filter before issuing snoops and only sends
snoops to caches that actually hold the line.

**Full directory:**

Every cache line in the system has a directory entry. For a 1 MB LLC with 64-byte lines and 16
cores: 16K entries x 16 bits (one bit per core) = 256 KB of directory storage. Exact: the
interconnect knows precisely which caches have each line. No false positive snoops.

**Partial (limited) snoop filter:**

Stores only a subset of the lines (those most recently accessed or those cached by multiple nodes).
Lines not in the filter use broadcast snooping as a fallback. Lower area cost but occasional
unnecessary snoops. Common in CMN-600/CMN-700 where the snoop filter stores state for a
configurable fraction of the total LLC capacity.

**Snoop filter miss handling:**

If the snoop filter has no entry for a requested address (capacity miss or cold miss):
1. The interconnect must broadcast the snoop to all caches in the coherency domain.
2. Any cache with the line responds; others respond miss.
3. After the transaction, the snoop filter may install an entry (evicting a less-recently-used entry).

**False sharing and snoop filter thrashing:**

If two CPU cores alternately write to the same 64-byte cache line (even to different bytes within
the line), each write requires the other's copy to be invalidated. The snoop filter correctly
tracks this and generates snoops, but the performance impact is severe: the line "ping-pongs"
between Modified states. This is the **false sharing** problem -- software must pad data
structures to separate cache lines.

---

### Q7. Describe the CHI transaction flow for a ReadUnique request from an RN-F.

**Question:** Core 0 (RN-F) needs exclusive write access to address 0xA000. The line is currently
held in Shared state by Core 1's cache. Walk through the CHI transaction sequence step by step.

**Answer:**

**CHI node roles in this scenario:**
- RN-F0 (Core 0): requesting node
- HN-F (Home Node): manages coherency for the 0xA000 region; contains the snoop filter
- RN-F1 (Core 1): has a Shared copy of the line
- SN-F (DRAM controller): memory backing store

**Step-by-step CHI ReadUnique sequence:**

```
Step 1: RN-F0 issues ReadUnique request
  RN-F0 -> HN-F:  REQ channel
                  Opcode = ReadUnique
                  Addr   = 0xA000
                  TxnID  = 0x5 (transaction ID for tracking)

Step 2: HN-F consults snoop filter
  Snoop filter: line 0xA000 is Shared in {RN-F1} (and possibly others)
  HN-F decides: must snoop RN-F1

Step 3: HN-F issues snoop to RN-F1
  HN-F -> RN-F1:  SNP channel
                  SnpOpcode = SnpCleanInvalid (invalidate and return data if dirty)
                  Addr = 0xA000
                  FwdNID = RN-F0 (optional: direct forward to requester)
                  DoNotGoToSD = 1 (do not transition to SD state)

Step 4: RN-F1 responds to snoop
  Line is Shared (clean). No write-back data needed.
  RN-F1 -> HN-F:  RSP channel
                  Opcode = SnpResp
                  RespErr = NormalOkay
                  Resp    = I (transitioning to Invalid)
  (No DAT response because line was clean)
  RN-F1 cache line state: SharedClean -> Invalid

Step 5: HN-F collects all snoop responses, then sends data to RN-F0
  HN-F has confirmed all sharers have invalidated.
  HN-F fetches data from SN-F (DRAM) since no dirty copy existed.
  HN-F -> RN-F0:  DAT channel
                  Opcode = CompData
                  TxnID  = 0x5 (matches original request)
                  Data   = [line data from DRAM]
                  Resp   = UC (Unique-Clean: granted exclusive clean ownership)

Step 6: RN-F0 receives CompData
  RN-F0 cache line state: Invalid -> UniqueClean (or Exclusive in MESI terms)
  RN-F0 sends ACK to HN-F (completion acknowledgement):
  RN-F0 -> HN-F:  RSP channel: CompAck

Step 7: RN-F0 writes to the line
  Line is now Exclusive; write upgrades to Modified silently (no bus transaction).
```

**Total message count: 7 messages** (REQ + SNP + RSP + RSP + DAT + RSP + optional ACK)

Compare to a broadcast system: 1 REQ + 16 SNP + 16 RSP + 1 DAT = 34 messages for the same operation.

---

## Advanced

### Q8. What is DVM (Distributed Virtual Memory) messaging in CHI/ACE?

**Question:** Explain why TLB maintenance requires a coherency-like broadcast mechanism.
What is a DVM message and how does CHI implement TLB shootdown?

**Answer:**

**The TLB coherency problem:**

Every CPU core has a TLB (Translation Lookaside Buffer) that caches virtual-to-physical address
mappings. When the OS modifies a page table entry (mapping a new page, changing permissions,
or unmapping a page), all TLBs in the system that cached that mapping must be invalidated.
Otherwise, a core may continue using a stale virtual-to-physical mapping -- accessing the wrong
physical page or a page that no longer exists.

This TLB invalidation is called a **TLB shootdown**. In software it requires:
1. OS sends IPI (inter-processor interrupt) to all other cores.
2. Each core executes TLBI instructions to flush relevant TLB entries.
3. Each core sends an acknowledgement.
4. OS waits for all acks before continuing.

This is expensive (hundreds to thousands of cycles) and requires OS-level orchestration.

**DVM (Distributed Virtual Memory) in CHI/ACE:**

DVM offloads TLB shootdown to hardware. The CHI Home Node can broadcast DVM messages to all
RN-F nodes on behalf of the requesting core:

```
DVM Sync sequence:
1. Core 0 (OS) issues TLBI instruction -> generates DVM Sync message on CHI
   RN-F0 -> HN-F: REQ, Opcode=DVMOp, DVMOpcode=TLBIxxx, VA/ASID/VMID fields

2. HN-F broadcasts DVM Operation to all RN-F nodes:
   HN-F -> RN-F1..N: SNP, Opcode=SnpDVMOp

3. Each RN-F:
   - Invalidates matching TLB entries (hardware or microcode level)
   - Responds: RN-Fx -> HN-F: RSP, Opcode=SnpRespFwded or SnpResp

4. HN-F collects all responses, sends completion to Core 0:
   HN-F -> RN-F0: RSP, Opcode=DVMComplete

5. Core 0 can now safely update the page table -- all stale TLB entries are flushed.
```

**DVM operation types (subset):**

| DVM Opcode | ARM Architecture Instruction |
|------------|------------------------------|
| TLBI VA | TLBI VAEx -- invalidate by virtual address |
| TLBI ASID | TLBI ASIDx -- invalidate by ASID |
| TLBI VMID | TLBI VMIDx -- invalidate by VMID (EL2 hypervisor) |
| TLBI All | TLBI ALL -- invalidate all TLB entries |
| BP Inv | BPIALLIS -- branch predictor invalidate |
| Sync | DSB/ISB -- memory barrier synchronisation |

**Performance benefit:** Hardware DVM eliminates the software IPI-based shootdown, reducing
TLB invalidation latency from O(microseconds) to O(tens of nanoseconds) on a CMN mesh.

---

### Q9. How does CHI handle out-of-order completion and ordering between related transactions?

**Question:** A CHI RN-F issues a WriteBackFull (eviction) and then a ReadShared to the same
address. Is there a risk of the read returning before the write completes? How does CHI
enforce ordering?

**Answer:**

**The out-of-order risk:**

CHI allows requests to be processed by the Home Node out of order (subject to constraints).
If RN-F0 issues:
1. WriteBackFull to 0xB000 (evicting a dirty line)
2. ReadShared to 0xB000 (immediately after)

And if the Home Node processes ReadShared before WriteBackFull, the read may return stale data
from DRAM (the dirty line has not yet been written back).

**CHI ordering mechanisms:**

1. **Request ordering (same node, same address):**
   A CHI RN-F is required to track outstanding transactions and must not issue a new request to
   an address that has a pending WriteBackFull or Evict for the same address. This is enforced
   by the RN-F's transaction tracker -- it must wait for Comp/CompAck of the WriteBackFull before
   issuing the ReadShared.

2. **Home Node ordering:**
   Even if requests arrive out of order at the HN-F, the HN-F maintains a request buffer that
   detects address hazards. A ReadShared for an address with a pending WriteBackFull will be
   **stalled** until the WriteBackFull completes (data absorbed by HN-F or forwarded to SN-F).

3. **Database (DB) responses:**
   For WriteBackFull, the HN-F may send a CompDBIDResp:
   - Comp: the write is acknowledged (ordering point reached)
   - DBIDResp: the data buffer ID for the RN-F to send the write data

   The RN-F must wait for Comp (ordering guarantee) before issuing any subsequent transaction
   that requires the write to be visible.

4. **Domain-level ordering:**

   CHI defines shareable domains (Inner Shareable, Outer Shareable, System) that determine the
   scope of ordering guarantees. A barrier transaction (DVMOp Sync) ensures all prior transactions
   within the specified domain are visible before the barrier completes.

**Practical sequence:**

```
RN-F0:
  Cycle 1: Issues WriteBackFull (0xB000), TxnID=0x1
  Cycle 2: Waits -- cannot issue ReadShared until WriteBackFull Comp is received

HN-F:
  Cycle 3: Receives WriteBackFull
  Cycle 4: Sends CompDBIDResp back to RN-F0 (ready to receive dirty data)
  
RN-F0:
  Cycle 5: Sends WriteData (dirty line data) to HN-F
  Cycle 6: Receives Comp from HN-F (ordering point: write is globally visible)
  Cycle 7: NOW issues ReadShared (0xB000) -- safe, write is committed
```

---

### Q10. How do you verify a CHI interconnect? What are the key protocol invariants to check?

**Question:** You are tasked with verifying a CHI Home Node (HN-F) implementation. Describe
the five most important protocol invariants to check using simulation or formal verification.

**Answer:**

**Invariant 1: Data uniqueness (no simultaneous multiple exclusive owners)**

At any point in time, for any given cache line address, at most one RN-F may hold the line in a
state that permits writes (Unique-Dirty, Unique-Clean, or Exclusive). If two RN-Fs ever
simultaneously hold a line in an exclusive state, data corruption can occur.

```
Formal property: For all addresses A and all pairs (RN-Fi, RN-Fj) where i != j:
  NOT (state[i][A] in {UD, UC, SD_owned} AND state[j][A] in {UD, UC, SD_owned})
```

**Invariant 2: Dirty data not lost (write-back protocol)**

If the snoop filter records a line as Unique-Dirty (UD) at RN-Fi, and a subsequent transaction
causes RN-Fi to invalidate its copy, the dirty data MUST be returned to the HN-F (via WriteData
or SnpRespData) before the HN-F forwards data to any other requester or memory.

```
Simulation check: Monitor all snoop operations. When SnpCleanInvalid or SnpUnique targets
  a UD line: assert that CompData returned to the requester contains the same data as the
  SnpRespData supplied by the snooped node (not stale memory data).
```

**Invariant 3: Transaction completion (liveness)**

Every REQ transaction must eventually receive a Comp or CompData response. No transaction may
remain pending indefinitely (deadlock or livelock). This is critical in interconnects that
implement retry mechanisms.

```
SVA property: 
  @(posedge clk) disable iff (!rst_n)
  $rose(req_valid[i]) |-> ##[1:MAX_LATENCY] comp_valid[i];
  // MAX_LATENCY = worst-case coherency resolution cycles
```

**Invariant 4: Snoop filter consistency**

The HN-F's snoop filter must accurately reflect the set of caches holding each line.
An RN-F must not hold a line in its cache without the snoop filter recording it.

```
Simulation check: Bind monitors to all RN-F cache tag arrays and to the HN-F snoop filter.
  After every transaction that modifies cache state (ReadShared grants Shared, snoop
  invalidates a line, etc.), assert:
  For all (RN-F, address): RN-F_cache_state[addr] != Invalid => snoop_filter[addr] includes RN-F
```

**Invariant 5: No protocol deadlock from VALID dependency**

CHI request channels must not create a cyclic dependency where:
- RN-F cannot send a response until HN-F sends a request
- HN-F cannot send a request until it has a free response buffer
- HN-F response buffers are full waiting for RN-F responses

Formal verification must prove there is no cycle in the "waits-for" graph between message
channels. This is typically addressed in the protocol specification by mandating minimum buffer
depths (e.g., each node must be able to accept at least N outstanding snoops regardless of
pending transaction load).

---

## Summary Reference Table

| Feature | AXI4 | ACE | ACE-Lite | CHI |
|---------|------|-----|----------|-----|
| Cache coherency | No | Full | IO-only | Full |
| Snoop channels | No | AC/CD/CR | No (cannot be snooped) | Integrated SNP |
| Topology | Star | Star | Star | Mesh/ring |
| Scalability | N/A | ~8-16 cores | N/A | 100+ cores |
| Transaction types | Read/Write | Read/Write + coherent | Coherent read/write | Named types (ReadUnique, WriteBack, etc.) |
| Exclusive access | ARLOCK/AWLOCK | ARLOCK/AWLOCK | No | CHI exclusive sequence |
| TLB maintenance | Software IPI | DVM via AMBA DVM | No | Built-in DVMOp |
| Ordering | ID-based | ID-based + domains | Domain barriers | Request ordering + barriers |
| Directory support | No | Optional snoop filter | No | HN-F directory |
| AMBA version | AMBA 4 | AMBA 4 | AMBA 4 | AMBA 5 |
| Primary use | Non-coherent interconnect | Multi-core CPU clusters | IO masters (DMA, GPU) | Large ARM clusters (Neoverse) |
