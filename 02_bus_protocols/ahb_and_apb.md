# AHB and APB Protocols

## Overview

AHB (Advanced High-performance Bus) and APB (Advanced Peripheral Bus) are the two lower-tier
members of the ARM AMBA bus family. They predate AXI4 and remain in widespread use in SoC
designs today: AHB for moderate-bandwidth on-chip memory and DMA connections, APB for slow
peripheral configuration interfaces. Understanding the protocol hierarchy, bridge design, and
the precise timing of each protocol is essential knowledge for SoC architecture interviews.

```
AMBA Protocol Hierarchy:

  APB  (low bandwidth, low area, non-pipelined, 2 cycles/transfer)
   |
  AHB/AHB-Lite  (pipelined, shared bus, 1 cycle/beat at peak)
   |
  AXI4  (5-channel, decoupled, multiple outstanding, out-of-order)

  Bridges connect the tiers:
  AXI-to-AHB: burst splitting, width conversion
  AHB-to-APB: sequential decomposition, SETUP/ACCESS generation
```

---

## Fundamentals

### Q1. What are the fundamental differences between APB and AHB?

**Question:** Compare APB and AHB on the dimensions of pipelining, burst support, bandwidth,
and area cost. Give a use case where each is the correct choice.

**Answer:**

| Dimension | APB | AHB / AHB-Lite |
|-----------|-----|----------------|
| Pipelining | None (strictly sequential) | Address phase overlaps previous data phase |
| Burst support | No | Yes (HBURST: SINGLE, INCR, WRAP4/8/16, INCR4/8/16) |
| Peak bandwidth | 1 beat per 2 cycles | 1 beat per cycle (after pipeline fill) |
| Multiple masters | No (single master implied) | Yes (full AHB with arbiter; AHB-Lite: single master) |
| Outstanding transactions | No | No (in-order; split/retry in full AHB only) |
| Area per slave | ~100-200 gates | ~400-800 gates |
| Clock frequency | Typically 50-200 MHz | Typically 200-500 MHz |
| Error response | PSLVERR (1 bit) | HRESP (OKAY / ERROR, 2-cycle error) |

**APB use case:** A UART peripheral with configuration registers for baud rate, data format, and
FIFO threshold. The UART is configured once during boot and occasionally polled for status. A
two-cycle per register access is perfectly adequate; the area saving over AHB is significant when
multiplied across 20-30 such peripherals on an SoC.

**AHB use case:** An on-chip SRAM accessed by a DMA engine transferring audio buffers. The DMA
issues burst reads and writes; the 1-beat/cycle sustained throughput of AHB is needed, and burst
support reduces address-phase overhead.

---

### Q2. Describe the APB transaction model. Walk through a write and a read.

**Question:** Show the signal timing for an APB write transaction and a read transaction
with one wait state. Name all signals involved.

**Answer:**

**APB key signals:**

| Signal | Direction | Purpose |
|--------|-----------|---------|
| PCLK | -- | Bus clock |
| PRESETn | -- | Active-low reset |
| PSEL | Master to Slave | Selects the target peripheral; one PSEL per peripheral |
| PENABLE | Master to Slave | Second phase indicator |
| PWRITE | Master to Slave | 1=write, 0=read |
| PADDR | Master to Slave | Address bus |
| PWDATA | Master to Slave | Write data |
| PRDATA | Slave to Master | Read data |
| PREADY | Slave to Master | 1=slave ready; 0=insert wait state |
| PSLVERR | Slave to Master | 1=error; 0=OK |
| PSTRB | Master to Slave | Byte enables (APB3+, 1 bit per data byte) |
| PPROT | Master to Slave | Protection attributes (privilege, secure) |

**APB write transaction (no wait states):**

```
Cycle:    1        2
          SETUP    ACCESS

PCLK:    _|--|_|--|_
PSEL:    _____|---|__   (asserted in SETUP, held through ACCESS)
PENABLE: _________|_   (asserted only in ACCESS phase)
PWRITE:  _____|---|__   (1 = write)
PADDR:   ___[ADDR]__   (stable from SETUP)
PWDATA:  ___[DATA]__   (stable from SETUP)
PREADY:  _________|_   (slave asserts at end of ACCESS: accept)
PSLVERR: _________0_   (no error)
```

**APB read transaction with one wait state:**

```
Cycle:    1        2       3
          SETUP    ACCESS  ACCESS+1

PCLK:    _|--|_|--|_|--|_
PSEL:    _____|---------|__
PENABLE: _________|-----|__
PWRITE:  _________0_____
PADDR:   ___[ADDR]______
PRDATA:  ___________[DAT]  (slave drives when ready)
PREADY:  _______________|   (wait state: PREADY=0 in cycle 2, =1 in cycle 3)
                         ^
             Transfer completes here
```

**How wait states work:** The slave deasserts PREADY during the ACCESS phase to insert
additional cycles. The master holds all signals stable (PSEL, PENABLE, PADDR) for as many
cycles as the slave requires. PRDATA must be valid by the rising edge of PCLK when PREADY is
finally asserted.

**Minimum transfer time:** 2 clock cycles (1 SETUP + 1 ACCESS with PREADY always asserted).

---

### Q3. How does AHB pipelining work? Explain the address and data phases.

**Question:** Draw the AHB pipeline timing for three back-to-back word writes. Show what
happens when the slave inserts a wait state on the second transfer.

**Answer:**

AHB overlaps the address phase of the next transfer with the data phase of the current transfer.
At peak throughput, the bus issues one address per cycle while simultaneously completing the
previous transfer's data.

**AHB key signals:**

| Signal | Purpose |
|--------|---------|
| HCLK | Bus clock |
| HRESETn | Reset |
| HADDR[31:0] | Address |
| HWDATA[31:0] | Write data |
| HRDATA[31:0] | Read data |
| HWRITE | 1=write, 0=read |
| HTRANS[1:0] | IDLE=0, BUSY=1, NONSEQ=2, SEQ=3 |
| HSIZE[2:0] | Transfer size (byte/halfword/word) |
| HBURST[2:0] | Burst type and length |
| HREADY | 1=data phase complete; 0=wait state |
| HRESP[1:0] | OKAY=0, ERROR=1 |
| HSEL | Slave select (decoded from HADDR) |

**Three back-to-back INCR4 burst writes:**

```
Cycle:    1         2         3         4         5         6
HADDR:  [A0]     [A1]      [A2]      [A3]      idle      idle
HTRANS: [NONSEQ] [SEQ]     [SEQ]     [SEQ]     [IDLE]
HWDATA: [---]    [D0]      [D1]      D2 held   [D2]      [D3]
HWRITE: [1]      [1]       [1]       [1]
HREADY: [1]      [1]       [0]       [1]       [1]
                                 ^
                      Slave inserts wait state on transfer 2
                      HADDR[A3] held, HWDATA[D2] held
```

**Key observations:**

1. **Pipelining:** At cycle 2, A1 is on HADDR while D0 is on HWDATA -- the data for A0 is
   presented one cycle after A0 was on the address bus.

2. **Wait state:** In cycle 3, the slave deasserts HREADY. The master must hold A2 (already
   on HADDR from cycle 3) and D1 (the data for A1) stable. When HREADY returns (cycle 4),
   A3 appears on HADDR and D2 appears on HWDATA.

3. **HTRANS encoding:**
   - NONSEQ: start of a new burst (or single transfer)
   - SEQ: continuation of a burst (address is sequential/wrapping from previous)
   - IDLE: no transfer (bus is idle)
   - BUSY: master needs a pause within a burst (rare; indicates master not ready)

4. **HWDATA timing:** The data for address Ax appears on HWDATA in the cycle AFTER Ax was
   driven on HADDR (when HREADY=1 was seen). This one-cycle offset is fundamental to AHB.

---

### Q4. How does AHB burst encoding work? What are the HBURST values?

**Question:** An AHB master wants to read a 32-byte aligned cache line starting at 0x1000.
What HBURST, HTRANS, and HSIZE values should it use?

**Answer:**

**HBURST[2:0] encoding:**

| Value | Name | Description |
|-------|------|-------------|
| 3'b000 | SINGLE | Single transfer; no burst |
| 3'b001 | INCR | Incrementing burst of undefined length |
| 3'b010 | WRAP4 | 4-beat wrapping burst |
| 3'b011 | INCR4 | 4-beat incrementing burst |
| 3'b100 | WRAP8 | 8-beat wrapping burst |
| 3'b101 | INCR8 | 8-beat incrementing burst |
| 3'b110 | WRAP16 | 16-beat wrapping burst |
| 3'b111 | INCR16 | 16-beat incrementing burst |

**Cache line read (32 bytes, 4 beats x 8 bytes = 32 bytes):**

Assumptions: AHB data width = 64 bits (8 bytes), 4-beat burst.

```
Signal values:
  HBURST = 3'b011  (INCR4: 4-beat incrementing burst)
  HSIZE  = 3'b011  (8 bytes per beat, 64-bit)
  HWRITE = 0       (read)

Transfer sequence:
  Beat 0: HADDR=0x1000, HTRANS=NONSEQ (start of burst)
  Beat 1: HADDR=0x1008, HTRANS=SEQ
  Beat 2: HADDR=0x1010, HTRANS=SEQ
  Beat 3: HADDR=0x1018, HTRANS=SEQ (final beat; after this HTRANS=IDLE or next NONSEQ)
```

**WRAP4 vs INCR4 for cache fills:**

WRAP4 is preferred for cache line fills where the critical word comes first. If the
cache miss is at address 0x1018, a WRAP4 burst delivers beats in order:
0x1018, 0x1000, 0x1008, 0x1010 -- the requested data arrives immediately.

**4KB boundary rule (inherited from AXI):** Incrementing bursts must not cross 4KB address
boundaries. The slave is permitted to return an error or the master must split the burst at
the boundary.

---

### Q5. What is the role of HTRANS in controlling AHB transfers?

**Question:** A DMA engine is performing an INCR8 burst but needs to pause after the 4th beat
(it is waiting for data to be available). What HTRANS values does it use? What must the slave do?

**Answer:**

HTRANS[1:0] gives the slave visibility into the master's intentions:

| HTRANS | Value | Meaning |
|--------|-------|---------|
| IDLE | 2'b00 | No transfer; slave must ignore bus (treat as idle) |
| BUSY | 2'b01 | Master is within a burst but needs extra cycles (pausing) |
| NONSEQ | 2'b10 | Start of a new burst or single transfer |
| SEQ | 2'b11 | Continuation of the current burst |

**BUSY pause within an INCR8 burst:**

```
Cycle:    1         2         3         4         5         6         7
HADDR:  [A0]     [A1]      [A2]      [A3]      [A3]      [A4]      [A5]
HTRANS: [NONSEQ] [SEQ]     [SEQ]     [BUSY]    [BUSY]    [SEQ]     [SEQ]
HWDATA: ---      [D0]      [D1]      [D2]      [D2]      [D3]      [D4]
```

At cycle 4 and 5, the master drives HTRANS=BUSY and repeats the next address (A3). This signals
to the slave: "I am in the middle of a burst but I am not ready to proceed." The slave can
acknowledge immediately (HREADY=1) but must hold state -- no data transfer occurs on a BUSY beat.

When the master is ready, it drives HTRANS=SEQ and the burst resumes at A4.

**Slave behaviour during BUSY:** The slave must accept the BUSY indication (typically by
asserting HREADY immediately) but should not latch address or data, and must not advance
internal state (e.g., auto-increment an internal address counter).

**Important distinction:** BUSY is used when the master pauses; HREADY=0 (wait state) is used
when the slave needs more time. Either side can insert cycles, but for different reasons.

---

## Intermediate

### Q6. How does an AHB-to-APB bridge work? Design its state machine.

**Question:** An AHB-to-APB bridge connects a high-performance AHB bus to a cluster of APB
peripherals. Describe the bridge state machine, minimum latency, and how it handles AHB burst
transactions.

**Answer:**

The AHB-to-APB bridge is one of the most common bridge types in SoC designs. Its role is to
translate the pipelined AHB model into the strict two-phase APB SETUP/ACCESS model.

**Bridge architecture:**

```
AHB Master --> [AHB-to-APB Bridge] --> APB Peripheral 0
                                   --> APB Peripheral 1
                                   --> APB Peripheral N
```

The bridge decodes HADDR to generate individual PSEL signals for each APB peripheral.

**Bridge state machine:**

```
IDLE:
  Monitor HSEL, HTRANS.
  When HSEL && HTRANS != IDLE:
    Latch HADDR, HWRITE, HSIZE, HWDATA (for writes).
    HREADY = 0 (stall AHB master while APB transaction proceeds).
    APB_SETUP -> APB_ENABLE

APB_SETUP:
  Assert PSELx (decoded from latched address).
  PADDR = latched address.
  PWRITE = latched HWRITE.
  PWDATA = latched HWDATA (for write).
  PENABLE = 0.
  (1 clock cycle in this state)
  -> APB_ENABLE

APB_ENABLE:
  Assert PENABLE.
  Monitor PREADY:
    While !PREADY: remain (APB wait states consumed here).
  When PREADY:
    Deassert PSEL, PENABLE.
    For reads: capture PRDATA; drive HRDATA = PRDATA.
    Capture PSLVERR -> drive HRESP accordingly.
    HREADY = 1 (release AHB master).
    -> IDLE (or APB_SETUP for next burst beat)
```

**Minimum latency (no wait states):**

```
Cycle 1: AHB address phase (HSEL, HADDR, HTRANS presented)
         Bridge latches address; HREADY=0 starts
Cycle 2: APB SETUP (PSEL=1, PENABLE=0, PADDR valid)
Cycle 3: APB ACCESS (PSEL=1, PENABLE=1, PREADY=1) -- APB transfer completes
         Bridge drives HRDATA, HREADY=1
Cycle 4: AHB data phase completes (master sees HREADY=1)

Total: 3 cycles overhead per AHB-to-APB access (vs 1 cycle for AHB-to-AHB)
```

**AHB burst handling:**

AHB supports burst transfers; APB does not. The bridge must:
1. Accept each AHB burst beat sequentially (one at a time).
2. For each AHB beat: latch address and data, execute one APB transaction.
3. Hold HREADY=0 throughout the APB transaction for each beat.
4. For writes, HWDATA for beat N+1 is presented on the AHB bus while beat N's APB
   transaction is in progress -- the bridge must latch it before accepting the next APB cycle.

This means a 4-beat AHB burst to APB requires 4 x (APB latency) cycles, versus 4 cycles for
the same burst to an AHB slave. The bridge serializes the burst into 4 sequential APB
transactions.

---

### Q7. How does the AHB error response (HRESP) work? Why does it take two cycles?

**Question:** Explain the AHB ERROR response mechanism. Why does AHB require two cycles to
signal an error, and what must the master do when it receives an error response?

**Answer:**

In AHB, error responses are communicated via HRESP[1:0] (OKAY=2'b00, ERROR=2'b01 in
AHB-Lite). Full AHB also defined RETRY and SPLIT, but these are not present in AHB-Lite.

**Why two cycles?**

The AHB pipelining model means that when the address phase of transfer N is active, the data
phase of transfer N-1 is also active. When a slave needs to signal an error for transfer N-1:

1. The slave has already accepted the address for transfer N (it appeared on HADDR while
   HREADY was high for the previous beat).
2. The slave cannot retroactively "un-accept" that address.
3. The two-cycle error response gives the master one cycle to de-pipeline and cancel the
   inadvertently-issued next transfer.

**Two-cycle error response timing:**

```
Cycle:    1         2         3
HADDR:  [A1]      [A2]      [A2]   <- master re-drives A2 (cancelled transfer)
HTRANS: [NONSEQ]  [SEQ]     [IDLE] <- master converts SEQ to IDLE
HREADY: [1]       [0]       [1]    <- cycle 2: wait; cycle 3: error completes
HRESP:  [OKAY]    [ERROR]   [ERROR]<- two consecutive ERROR cycles
```

**Cycle 2:** HREADY=0 and HRESP=ERROR. The master sees ERROR but cannot act yet.
**Cycle 3:** HREADY=1 and HRESP=ERROR. The master latches the error response.
The master must cancel any in-progress next transfer (set HTRANS=IDLE at cycle 3).

**What the master must do on error:**

1. The current transfer (the one that caused the error) is terminated.
2. The next transfer that was already in the address phase is automatically cancelled by the
   master (HTRANS forced to IDLE or NONSEQ).
3. Software is notified (bus fault exception, error interrupt) to handle the failed access.

**Common mistake:** Candidates assume a single cycle is sufficient for the error response.
The two-cycle requirement is fundamental to AHB pipelining and is non-negotiable in
the protocol.

---

### Q8. Compare AHB-Lite with full AHB. What features does AHB-Lite omit?

**Question:** Describe what was removed in the transition from AHB to AHB-Lite. What are the
architectural implications for SoC design?

**Answer:**

**Full AHB features removed in AHB-Lite:**

| Feature | Full AHB | AHB-Lite |
|---------|----------|---------|
| Multiple masters | Yes (with arbiter, HMASTER, HMASTLOCK) | No (single master) |
| Split transactions | Yes (HRESP=SPLIT, target slaves must support) | No |
| Retry transactions | Yes (HRESP=RETRY) | No |
| HMASTLOCK | Yes (locked sequence for atomic read-modify-write) | No |
| HMASTER | Yes (identifies which master is on the bus) | No |
| HBUSREQ / HGRANT | Yes (bus request/grant for multi-master) | No |
| Bus arbitration | External arbiter required | Not needed (single master) |

**Split transactions in full AHB:**

Split was a mechanism for a slow slave to release the bus mid-transaction:
1. Slave asserts HRESP=SPLIT, releasing the bus to other masters.
2. When ready, the slave signals the arbiter via HSPLIT vector.
3. The arbiter grants the original master the bus again; the slave re-executes the transfer.

This increased bus utilisation for high-latency slaves but required complex arbiter and slave
implementations. AXI4 solved this more elegantly with decoupled channels and transaction IDs.

**AHB-Lite implications for SoC design:**

1. **Single master only.** If multiple masters need to share an AHB-Lite bus, an external
   multiplexer (not an arbiter) must be used. Typically, only one master is active at a time
   (time-division multiplexing), or the interconnect level promotes to AXI.

2. **No priority among masters.** Without arbitration, AHB-Lite cannot implement QoS. For
   multi-master systems, the interconnect must be AXI4 or use a full AHB fabric.

3. **Simpler slave implementations.** Slaves do not need to implement split or retry logic.
   HRESP is a single bit (OKAY / ERROR) rather than a two-bit field. This significantly
   reduces slave gate count.

4. **Standard for CPU-to-peripheral subsystems.** ARM Cortex-M series processors use AHB-Lite
   as their primary bus interface. Most Cortex-M SoCs have one AHB-Lite master (the CPU's I/D
   code/system bus) connected to a bus matrix that fans out to individual AHB-Lite slaves.

---

## Advanced

### Q9. How do you design a multi-layer AHB system for a Cortex-M SoC?

**Question:** A Cortex-M3 SoC has three AHB masters (I-CODE bus, D-CODE bus, system bus) and
five AHB-Lite slaves (Flash, SRAM, peripheral bridge, DMA, external bus). Describe the
multi-layer AHB matrix topology.

**Answer:**

**Multi-layer AHB (ARM Bus Matrix):**

ARM Cortex-M series processors expose multiple AHB-Lite master ports:
- **I-CODE:** Instruction fetches (word-aligned, read-only)
- **D-CODE:** Data accesses to the Code region (0x00000000-0x1FFFFFFF)
- **System bus:** All other master accesses (SRAM, peripherals, external)

A bus matrix (not a single shared bus) connects these masters to slaves independently:

```
              I-CODE  D-CODE  System (DMA as 4th master)
                |       |       |       |
          ------+-------+-------+-------+------  Bus Matrix
                |       |       |       |
              Flash   SRAM   APB-Bridge  EBI

Access rights matrix:
  I-CODE  -> Flash (instruction fetch), SRAM (vectors)
  D-CODE  -> Flash (data in code region), SRAM
  System  -> SRAM, APB-Bridge, EBI, DMA control registers
  DMA     -> SRAM, EBI
```

**Arbitration in the bus matrix:**

Each slave port within the bus matrix has an arbiter for the masters that can access it.
For SRAM (accessible by D-CODE, System, and DMA):

```
Priority scheme (example):
  D-CODE (CPU data) = highest priority
  System (CPU other) = medium priority
  DMA = lowest priority (background transfers)

When two masters simultaneously request SRAM:
  Higher-priority master wins; lower-priority master is held with HREADY=0
  until the current transaction completes.
```

**Benefits of the bus matrix over a shared AHB bus:**

1. **Simultaneous accesses to different slaves:** The CPU can fetch from Flash (I-CODE) while
   the DMA transfers data to SRAM. These access different slaves and proceed in parallel.

2. **No bus contention for non-overlapping accesses:** Only collisions at the same slave cause
   stalls. I-CODE + System accessing different slaves never conflict.

3. **Deterministic latency:** With priority-based arbitration, the CPU always gets SRAM access
   over DMA, bounding worst-case instruction fetch latency.

**Implementation note:** ARM provides the Cortex-M Bus Matrix as a configurable synthesisable
block. Third-party implementations (Synopsys DesignWare, Cadence, Mentor) also supply
compatible multi-layer AHB matrix IP.

---

### Q10. What are the key timing analysis challenges for AHB and APB buses at high clock frequencies?

**Question:** An AHB bus runs at 400 MHz. What are the critical timing paths? How does the
bridge insertion latency affect system performance?

**Answer:**

**AHB timing critical paths at 400 MHz (2.5 ns cycle time):**

1. **HREADY fanout.** HREADY is driven by a wire-OR (or mux) of all slaves' HREADY outputs.
   With 8+ slaves, the wiring fanout creates significant capacitance. A registered HREADY
   centralisation stage may be needed, adding 1 cycle of fixed latency.

2. **Address decode to HSEL.** The combinational decode of HADDR[31:0] to individual HSEL
   signals must complete within one clock cycle. At 400 MHz, the combinational delay budget
   is tight, especially with many address ranges. Priority encoder + ROM-based decode is
   often used.

3. **Write data pipeline.** HWDATA is valid one cycle after the address phase. The slave must
   latch HWDATA on the correct clock edge. If HWDATA originates in a different clock domain
   or from a source with long combinational output delay, the setup time at the slave FF may
   be violated.

4. **Read data path.** HRDATA must be valid before the rising edge of HCLK when HREADY is
   asserted. For SRAM with 1.5 ns access time at 400 MHz, the read data may not be valid in
   time. The slave inserts a wait state (HREADY=0 for one cycle), extending effective cycle
   time to 5 ns = 200 MHz SRAM throughput.

**APB bridge insertion latency impact:**

Every AHB-to-APB access costs a minimum of 3 AHB cycles (1 address + 2 APB). For software
polling a status register at 1 MHz, the overhead is negligible. For a configuration sequence
that writes 100 registers at boot:

```
100 registers x 3 cycles x (1/400 MHz) = 750 ns
```

This is insignificant. But for a latency-critical path (e.g., an interrupt handler reading
a status register within a 5 us deadline):

```
Interrupt detection -> register read -> response
  = interrupt latency + AHB arbitration + 3 APB cycles + processing
```

The 3-cycle bridge latency (7.5 ns at 400 MHz) is negligible here. Bridge latency only
becomes a concern in the following cases:

- **Burst register access:** Reading 256 registers via AHB burst to APB is serialized into
  256 individual APB transactions = 256 x 3 = 768 cycles. Alternative: use AHB SRAM-mapped
  register block instead of APB for bulk register access.

- **Low APB clock (PCLK):** If PCLK is 50 MHz and ACLK is 400 MHz, each APB transaction
  takes 8 ACLK cycles, making the bridge penalty 1 + 8 = 9 ACLK cycles per access.
  Synchronisation FIFOs or handshake logic between clock domains must be correctly timed to
  prevent metastability.

---

## Summary Reference Table

| Feature | APB | AHB-Lite | AHB Full |
|---------|-----|----------|---------|
| Pipeline model | None (SETUP/ACCESS) | Address overlaps data | Address overlaps data |
| Burst support | No | Yes (HBURST) | Yes (HBURST) |
| Multiple masters | No | No | Yes (arbiter) |
| Outstanding transactions | No | No | Split (limited) |
| Minimum transfer latency | 2 cycles | 1 cycle (pipelined) | 1 cycle (pipelined) |
| Wait state mechanism | PREADY | HREADY | HREADY |
| Error response | PSLVERR (1 bit) | HRESP (2-cycle) | HRESP (2-cycle) |
| Split/Retry | No | No | Yes (SPLIT/RETRY in HRESP) |
| Byte enables | PSTRB (APB3+) | HSIZE (transfer size) | HSIZE |
| Security | PPROT | HPROT | HPROT |
| Area per slave | ~100-200 gates | ~400-800 gates | ~600-1200 gates |
| Typical frequency | 50-200 MHz | 200-500 MHz | 200-400 MHz |
| Primary use | Peripheral config | CPU bus (Cortex-M) | High-performance shared bus |
| AMBA version | AMBA 2 / APB3 / APB4 | AMBA 3 | AMBA 2 / 3 |
