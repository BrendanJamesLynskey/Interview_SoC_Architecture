# SoC Building Blocks

## Prerequisites
- Basic digital logic: gates, flip-flops, finite state machines
- Computer architecture fundamentals: CPU pipeline, memory hierarchy
- Bus and interconnect concepts at a high level

---

## Concept Reference

### SoC Definition and Motivation

A System-on-Chip (SoC) integrates all functional blocks of a complete system onto a single die: processor cores, memory, peripherals, analog front-ends, and the interconnect fabric that links them. The primary drivers are power efficiency (short on-chip wires consume far less energy than PCB traces), latency (on-chip bandwidth is orders of magnitude higher than off-chip), cost (single package), and physical size.

### Top-Level Block Hierarchy

```
+------------------------------------------------------------------+
|                          SoC Die                                 |
|                                                                  |
|  +----------+   +----------+   +----------+   +----------+      |
|  | CPU Core |   | GPU/DSP  |   |  Neural  |   | Security |      |
|  | Cluster  |   | Cluster  |   |  Engine  |   | Enclave  |      |
|  +----+-----+   +----+-----+   +----+-----+   +----+-----+      |
|       |              |              |               |            |
|  +----+--------------+--------------+---------------+------+    |
|  |              High-Performance Interconnect (AXI/CHI)    |    |
|  +----+--------------+--------------+---------------+------+    |
|       |              |              |               |            |
|  +----+-----+   +----+-----+   +----+-----+   +----+-----+      |
|  |  L2/L3   |   |   DMA    |   |  Video   |   |  PCIe /  |      |
|  |  Cache   |   |Controller|   | Display  |   |  USB     |      |
|  +----------+   +----------+   +----------+   +----------+      |
|                                                                  |
|  +--------------------------------------------------------------+|
|  |          Low-Power Peripheral Bus (APB / AHB-Lite)          ||
|  +--+-------+--------+--------+--------+--------+-----------+--+|
|     |       |        |        |        |        |           |   |
|  [UART] [SPI/I2C] [Timer] [WDT]  [GPIO]  [RTC]  [Power Mgmt] |
|                                                                  |
|  +----------+   +-----+   +----------+   +----+                 |
|  | On-chip  |   | ROM /|   | External |   | PLL|                 |
|  |  SRAM    |   | OTP  |   | DDR PHY  |   | /ClkGen|            |
|  +----------+   +------+   +----------+   +--------+             |
+------------------------------------------------------------------+
```

### The Five Categories of SoC IP Blocks

| Category          | Examples                                 | Interface standard |
|-------------------|------------------------------------------|--------------------|
| Compute cores     | ARM Cortex-A/M/R, RISC-V, DSP, GPU       | AXI4, CHI          |
| Memory            | SRAM, ROM, Flash, DRAM controller/PHY    | AXI4, custom       |
| Interconnect      | Crossbar, NI (Network Interface), bridge | AXI4, AHB, APB     |
| Peripherals       | UART, SPI, I2C, USB, PCIe, Ethernet      | APB, AHB-Lite      |
| Analog / Mixed    | PLL, ADC, DAC, USB PHY, SerDes           | Custom / digital   |

### Processor Core Types

| Core class  | Pipeline depth | Cache    | FPU  | Typical use                     |
|-------------|----------------|----------|------|---------------------------------|
| Cortex-M0+  | 2-stage        | None     | No   | Ultra-low-power IoT             |
| Cortex-M4/7 | 3-6 stage      | Optional | Yes  | Embedded control, DSP           |
| Cortex-A53  | 8-stage in-order | L1+L2  | Yes  | Mobile application processors   |
| Cortex-A72  | Out-of-order   | L1+L2+L3 | Yes  | High-performance application    |
| Cortex-R52  | In-order, ECC  | L1       | Yes  | Safety-critical real-time       |

### Memory Taxonomy on SoC

```
On-die (tightly coupled):
  TCM  (Tightly Coupled Memory) — zero-latency, accessed by core directly
  L1 cache  — private to core, 32-64 KB typical, 1-4 cycle latency
  L2 cache  — private or shared, 256 KB - 4 MB, 8-20 cycle latency
  L3 cache  — shared, 4-32 MB, 30-50 cycle latency

On-die (fabric-attached):
  On-chip SRAM — software-visible scratchpad, AXI-connected
  ROM / OTP    — boot code, fuses, non-volatile configuration

Off-die (via PHY):
  LPDDR4/5   — main memory for application processors
  NAND Flash  — storage (via NAND controller)
  NOR Flash   — XIP (execute in place) for MCU boot
```

### Interconnect Hierarchy

A well-designed SoC uses multiple bus tiers matched to bandwidth and latency requirements:

```
Tier 1 (High performance):  AXI4 / CHI    — CPUs, GPU, DMA, memory controllers
Tier 2 (Medium bandwidth):  AHB            — DMA targets, on-chip SRAM
Tier 3 (Low-speed periph):  APB            — UARTs, timers, GPIO, power control
```

Bridges connect tiers. An AHB-to-APB bridge converts AHB transactions into the slower two-phase APB handshake, allowing low-speed peripherals to share a narrow, low-power bus without burdening the high-performance fabric.

---

## Tier 1 — Fundamentals

### Question F1
**What are the five main functional blocks found in almost every SoC? Briefly describe the role of each.**

**Answer:**

1. **Processor core(s):** Execute software. One or more CPUs (often ARM Cortex or RISC-V) provide general-purpose computation. Real-time domains may include an R-class or M-class core alongside an A-class application processor.

2. **Memory subsystem:** Provides storage at multiple latency/capacity points — L1/L2/L3 caches private or shared among cores, on-chip SRAM scratchpads for deterministic-latency data, ROM/OTP for immutable boot code, and a DRAM controller + PHY for large off-chip main memory.

3. **Interconnect fabric:** Routes transactions between masters (CPU, DMA, GPU) and slaves (memory, peripherals). Implemented as a bus (AHB), crossbar, or Network-on-Chip. The fabric enforces ordering, arbitration, and access control.

4. **Peripherals:** Implement standardised I/O protocols (UART, SPI, I2C, USB, PCIe, Ethernet, GPIO). Connected to the fabric via a peripheral bus (typically APB) to minimise wiring overhead on the main interconnect.

5. **Clock and power management:** Generates and distributes all on-chip clocks (PLLs, dividers, clock gates) and manages power domains (voltage regulators, power switches, retention logic).

**Common mistake:** Candidates omit the clock/power subsystem, which is a first-class design concern occupying dedicated IP blocks and significant die area on real SoCs.

---

### Question F2
**Explain the difference between a hard macro IP, a soft IP, and a firm IP in the context of SoC integration.**

**Answer:**

| Type       | Delivery format           | Portability         | Flexibility          | Typical examples                  |
|------------|---------------------------|---------------------|----------------------|-----------------------------------|
| **Hard IP**| Pre-placed GDS-II layout  | Process-specific    | None (fixed layout)  | ARM CPU clusters, SerDes PHY, PLL |
| **Soft IP**| RTL source (Verilog/VHDL) | Fully portable      | High (re-synthesised)| UART, SPI, open-source RISC-V     |
| **Firm IP**| Gate-level netlist        | Limited             | Low                  | Memory compilers (SRAM, ROM)      |

**Hard IP:** Layout is fixed for a specific process node. The foundry or IP vendor has optimised the transistor-level design for maximum performance and density. The integrator must use it as a black box — they cannot change internals, only configure via external parameters. PLLs and high-speed PHYs are almost always hard because analog performance depends on exact transistor sizing.

**Soft IP:** Delivered as synthesisable RTL. The integrator runs synthesis, placement, and routing themselves, tuning area/performance tradeoffs for their specific process and timing budget. The downside is unpredictable performance and more integration effort.

**Firm IP:** Pre-synthesised but not placed/routed. More predictable timing than soft IP, but less portable than soft. Memory macros (SRAM compilers) fall here — the compiler generates a verified gate-level block with timing models (.lib, .db) for a specific process.

**Interview insight:** Interviewers ask this to probe understanding of the SoC integration flow. Hard IP drives the floor-planning process because its location may be constrained (e.g., a SerDes PHY must be adjacent to die edge pads).

---

### Question F3
**What is a memory-mapped peripheral? How does a CPU communicate with a UART over a memory-mapped interface?**

**Answer:**

In memory-mapped I/O (MMIO), peripheral registers are assigned addresses in the processor's address space. The CPU issues ordinary load/store instructions targeting those addresses. The interconnect decodes the address and routes the transaction to the peripheral instead of to main memory.

**Example — UART communication at address 0x4000_0000:**

```
CPU address space view:
  0x0000_0000 -- 0x0FFF_FFFF : DRAM (1 GB)
  0x4000_0000 -- 0x4000_FFFF : UART0 register block

UART register map:
  0x4000_0000 : TX_DATA   (WO) -- write byte here to transmit
  0x4000_0004 : RX_DATA   (RO) -- read byte received
  0x4000_0008 : STATUS    (RO) -- bit[0]=TX_EMPTY, bit[1]=RX_FULL
  0x4000_000C : CTRL      (RW) -- enable, baud rate divider

Software sequence to transmit 'A' (0x41):
  1. Poll STATUS until TX_EMPTY == 1:
       while (*(volatile uint32_t *)0x40000008 & 0x1) == 0) {}
  2. Write byte to TX_DATA:
       *(volatile uint32_t *)0x40000000 = 0x41;

The `volatile` qualifier tells the compiler not to cache or re-order the memory access,
which is essential for MMIO — registers have side effects the compiler cannot see.
```

**Why MMIO over port-mapped I/O:** x86 architectures historically use IN/OUT instructions with a separate 16-bit I/O port space. ARM and RISC-V use only MMIO, which simplifies the ISA, uses the same protection mechanisms as memory (MPU/MMU), and allows arbitrary register widths. Port I/O requires dedicated instructions and a separate address decoder.

---

### Question F4
**What is the role of a DMA controller in an SoC? Why is it more efficient than CPU-driven data transfer?**

**Answer:**

A Direct Memory Access (DMA) controller transfers data between memory locations or between memory and peripherals without continuous CPU involvement.

**CPU-driven (PIO) transfer cost:**

```
CPU transfers N bytes from UART RX FIFO to SRAM:
  For each byte:
    1. Check UART STATUS register  (1 load instruction)
    2. Read UART RX_DATA register  (1 load instruction)
    3. Write to SRAM destination   (1 store instruction)
    4. Increment pointer           (1 arithmetic instruction)
    5. Check for completion        (1 branch instruction)
  Total: ~5 instructions per byte
  At 1 GHz, 1 byte/5ns => 200 MB/s max, but CPU is fully occupied
```

**DMA-driven transfer:**

```
CPU setup (one time):
  1. Program DMA source address   (UART RX FIFO register)
  2. Program DMA destination      (SRAM buffer address)
  3. Program transfer count       (N bytes)
  4. Program burst size           (4 bytes)
  5. Enable DMA channel
  6. CPU continues other work

DMA hardware runs independently:
  - Issues bus requests to interconnect
  - Reads UART FIFO, writes SRAM
  - On completion, asserts interrupt to CPU

CPU cost: ~6 register writes for setup + interrupt handler
```

**Efficiency gains:**
- CPU is free to run application code during the transfer.
- DMA can issue burst transactions, improving bus utilisation.
- Multiple DMA channels can run simultaneously (audio, video, networking in parallel).
- On-chip DMA avoids cache pollution that PIO causes (every PIO load/store touches the cache).

**Common interview question follow-up:** "What must the software do to ensure DMA-written data is visible to the CPU?" Answer: The CPU cache must be invalidated for the destination buffer before reading it, because DMA writes to physical memory and bypasses the cache hierarchy.

---

## Tier 2 — Intermediate

### Question I1
**Describe the AXI4 master/slave handshake model and explain why five separate channels are used instead of a single shared bus.**

**Answer:**

AXI4 uses five independent unidirectional channels, each with its own VALID/READY handshake:

```
Master -> Slave channels:          Slave -> Master channels:
  AW : Write Address               B  : Write Response
  W  : Write Data                  R  : Read Data (with address response embedded)
  AR : Read Address
```

**Handshake rule:** A transfer occurs on a rising clock edge when both VALID and READY are asserted simultaneously. Either party can assert its signal independently; neither is permitted to make READY or VALID conditional on the other's signal in the same cycle (this would create combinational loops).

**Why five channels instead of one:**

1. **Read/Write decoupling:** An AXI4 read and write can proceed simultaneously. A single shared bus would force serialisation — while reading, the write data path is idle.

2. **Address/data decoupling:** The write address (AW) can be accepted by the slave before the slave is ready to accept write data (W). This allows pipelining: the master can issue multiple write addresses speculatively while earlier write data transfers are still in flight.

3. **Out-of-order responses:** By assigning an ID field to transactions, the slave can respond on the R or B channel in any order relative to other transactions with different IDs. A shared bus would force in-order responses and stall the bus on a slow memory access.

4. **Separate flow control per channel:** A slow peripheral that processes read responses slowly only stalls the R channel. The AW and W channels remain fully available for write transactions or other masters' traffic through a crossbar.

**Practical consequence in design:** A designer adding a new slave only needs to implement the channels it uses. A read-only status register slave implements only AR and R. A write-only logging FIFO implements only AW, W, and B. This reduces gate count and verification effort.

---

### Question I2
**What is an IP integration bus (such as APB) and why are low-speed peripherals not connected directly to the high-performance AXI bus?**

**Answer:**

APB (Advanced Peripheral Bus) is a simple, low-bandwidth, low-power bus designed for peripherals that do not need burst transfers or pipelining: UARTs, timers, GPIO, I2C controllers, watchdog timers, power management registers.

**APB characteristics:**
- 2-phase non-pipelined protocol (SETUP phase, ACCESS phase — minimum 2 cycles per transfer).
- No burst support, no out-of-order transactions, single address/data bus.
- Gate count per slave interface: approximately 200-400 gates versus 2000-5000 for a minimal AXI4-Lite slave.

**Why not connect peripherals directly to AXI:**

1. **Bus load and timing:** Every additional slave on an AXI bus adds capacitance to the shared address decode and arbitration logic, increasing interconnect latency and power for all masters, including the CPU cores. High-performance masters should not be penalised by low-speed peripherals.

2. **Implementation cost per slave:** Every APB peripheral needs only ~50 gates for a compliant interface (ADDRESS, PSEL, PENABLE, PWRITE, PWDATA, PRDATA, PREADY). An AXI4-Lite slave requires full 5-channel handshake logic even for a single register. For 30 peripherals, APB is vastly more area-efficient.

3. **Power:** APB transactions involve fewer switching nodes. The bridge from AXI to APB can be clock-gated when no peripheral accesses are in progress.

4. **Separation of concerns:** Faults on the peripheral bus (a misbehaving peripheral hanging PREADY) are isolated at the bridge and do not affect the high-performance fabric.

**Typical integration:**

```
CPU (AXI Master)
      |
 AXI4 Crossbar
      |
 AHB-to-APB Bridge (contains APB bus matrix with PSEL decode)
      |
 APB bus
  |     |     |     |     |
UART  Timer  GPIO  I2C  Watchdog
```

---

### Question I3
**Explain what a cache-coherent interconnect is. Why does a multi-core SoC with a DMA engine need coherency support?**

**Answer:**

A **cache-coherent interconnect** ensures that every master in the system always observes the most recent value of any memory location, regardless of which master last wrote it and regardless of where cached copies exist.

**Without coherency — the stale data problem:**

```
Time 0: SRAM[0x1000] = 0xFF  (initial value in main memory)

Time 1: CPU Core 0 reads SRAM[0x1000]
        => Cache line loaded: Core0.L1[0x1000] = 0xFF

Time 2: CPU Core 1 writes SRAM[0x1000] = 0xAB via its own cache
        => Core1.L1[0x1000] = 0xAB (dirty, not yet written to SRAM)
        => Main memory still holds 0xFF

Time 3: Core 0 reads SRAM[0x1000] again
        => Cache hit: returns 0xFF  (WRONG — Core 1 wrote 0xAB)

Time 4: DMA engine reads SRAM[0x1000] from main memory
        => Gets 0xFF                (WRONG — neither Core 1's write is visible)
```

**Cache coherency protocols (MESI, MOESI) solve this by:**
- Tracking the state of each cache line across all caches (Modified, Exclusive, Shared, Invalid).
- Issuing snoop requests when a write occurs: all other caches holding the same line are notified and must invalidate or update their copy.
- Ensuring a DMA read either snoops all L1/L2 caches or forces a write-back before the DMA proceeds.

**For a DMA engine specifically:**

A DMA that is not coherent must be treated as follows by software:
1. Before DMA reads (device-to-memory): invalidate CPU cache lines covering the DMA destination buffer so that when the CPU reads after DMA, it fetches from memory rather than its stale cache.
2. Before DMA writes (memory-to-device): clean (write-back) CPU cache lines covering the DMA source buffer so that DMA reads the CPU's most recent writes from memory.

A coherent DMA (e.g., attached to a CCI or CMN interconnect that supports ACE-Lite) performs these snoops automatically, eliminating the software maintenance burden and the data-corruption bugs that arise when software forgets them.

---

### Question I4
**What is a power domain in an SoC? Describe a typical multi-domain architecture and its trade-offs.**

**Answer:**

A **power domain** is a group of logic cells that share a common supply voltage and can be powered on or off independently of other domains. Separate power domains are the primary mechanism for reducing standby power in SoCs running battery-powered or thermally-constrained applications.

**Typical multi-domain partition:**

```
+-------------------+  +-------------------+  +-------------------+
|   Always-On (AO)  |  |  Application CPU  |  |    GPU / Media    |
|  domain (0.75V)   |  |  domain (0.8-1.0V)|  |  domain (0.8-1.0V)|
|                   |  |                   |  |                   |
| RTC, PMU, wakeup  |  | Cortex-A cores    |  | GPU, video codec  |
| logic, boot ROM   |  | L2/L3 cache       |  | image signal proc.|
+-------------------+  +-------------------+  +-------------------+
         |                      |                       |
         +------ Always powered +----- Power-switchable +----- Power-switchable

Voltage levels may also differ between domains:
  AO domain: 0.75 V (low-power retention)
  CPU domain: 0.8 V at 600 MHz (idle) to 1.0 V at 2.4 GHz (full speed)
  GPU domain: OFF when not rendering, 0.9 V during 3D workloads
```

**Cross-domain interface requirements:**

```
1. Level shifters:    Translate signal levels at domain boundaries when VDD differs
2. Isolation cells:   Clamp outputs of a powered-off domain to a known value (0 or 1)
                      to prevent floating inputs in the receiving domain
3. Retention cells:   Special flip-flops that preserve state from a shadow latch when
                      the main supply is removed (allows fast wakeup without re-init)
4. Power switches:    PMOS header or NMOS footer transistors that gate the domain supply
```

**Trade-offs:**

| Approach               | Power saving          | Wakeup latency   | Cost / complexity |
|------------------------|-----------------------|------------------|-------------------|
| Single domain          | None                  | None             | Lowest            |
| Clock gating only      | Low-moderate (dynamic)| Zero             | Low               |
| Retention power domain | Moderate (leakage)    | < 1 µs           | Medium            |
| Full power-off domain  | Maximum (all leakage) | 10s of µs - ms   | High              |

---

## Tier 3 — Advanced

### Question A1
**A CPU core issues a speculative read that targets a peripheral register with a read side-effect (e.g., clearing an interrupt status bit). How should the SoC architect prevent incorrect behaviour, and what hardware mechanisms support this?**

**Answer:**

Speculative reads to memory-mapped I/O regions are dangerous because peripheral register reads frequently have side effects: reading an RX_DATA register drains the FIFO, reading an interrupt status register clears the pending bit. If the CPU speculates the access but later squashes it (branch misprediction), the side effect has already occurred and cannot be reversed.

**The correct architectural solution is to mark MMIO regions as Device memory, not Normal memory.**

In ARM architecture:

```
Memory type attributes (set in page table / MPU region):
  Normal memory:    Speculative reads allowed, write-combining allowed,
                    accesses may be re-ordered or merged by the CPU and bus.
  Device memory:    No speculative reads, no write-combining, strictly ordered.
    Device-nGnRnE:  Non-Gathering, Non-Reordering, Non-Early write acknowledgement
                    Most restrictive; all accesses in program order, one-at-a-time.
    Device-nGnRE:   Non-Gathering, Non-Reordering, Early write acknowledgement
                    Write responses may come from a buffer rather than the peripheral.
    Device-GRE:     Gathering and reordering allowed (rare — only for benign MMIO).
```

For a peripheral with read side effects (UART FIFO, interrupt controller), the mapping must be `Device-nGnRnE`:
- The CPU will not issue the load speculatively.
- The CPU will not merge two 32-bit writes into one 64-bit write.
- All accesses from one thread appear at the peripheral in program order.

**Hardware enforcement mechanism:**

The MMU (or MPU in Cortex-M) checks the memory attribute for every load/store. The attribute is stored in the TLB alongside the physical address. The CPU microarchitecture inhibits speculation for Device-type accesses at the load/store unit level.

**Interconnect enforcement:**

AXI4 carries AxPROT[1] (non-secure/secure) and AxCACHE[3:0] (memory type) signals alongside every address transaction. A Cortex-A CPU propagates the memory type from the TLB entry into AxCACHE so that any intermediate buffer or reorder buffer in the interconnect fabric also respects the non-speculative, non-reorderable requirement.

---

### Question A2
**Describe the concept of SoC floorplanning. What are the key constraints that drive macro placement, and what happens if floorplanning is done poorly?**

**Answer:**

**Floorplanning** is the physical design step where the positions and shapes of all major blocks (macros: hard IPs, SRAMs, CPU clusters) are determined before detailed cell placement and routing. It sets the die area, aspect ratio, power grid topology, and pin assignment for each block.

**Key constraints driving macro placement:**

1. **Connectivity and wire length:** Blocks that communicate frequently (e.g., CPU cluster and L2/L3 SRAM) must be placed adjacent to minimise interconnect length, which directly reduces latency and dynamic power.

   ```
   Rule of thumb: 1 mm of global wire at 1 GHz in 7nm ≈ 50 fJ/bit dynamic energy.
   CPU <-> L2 SRAM distance should be <0.5 mm to meet cycle-accurate timing.
   ```

2. **Hard IP positional requirements:** SerDes PHYs must be at the die edge (adjacent to bump rows or bond pads). USB and PCIe PHYs typically require specific locations relative to package balls. PLLs need quiet power domains away from switching logic noise.

3. **Power grid topology:** Large macros with high current draw (GPU, DRAM PHY) must be placed beneath power grid stripes that can deliver the required current without excessive IR drop. Standard cell regions must be arranged to allow vertical and horizontal power stripes to reach all cells.

4. **Thermal constraints:** High-power blocks (CPU cluster, GPU) should not be adjacent to each other, or to analog/mixed-signal blocks sensitive to thermal noise.

5. **Signal integrity and routing congestion:** Clock spine placement, reset distribution trees, and high-fanout nets require clear routing channels between macros.

**Consequences of poor floorplanning:**

```
Problem                       Consequence
-----------------------------  -----------------------------------------------
CPU too far from SRAM          Interconnect wire delay exceeds 1-2 clock cycles;
                               timing closure requires frequency reduction or
                               pipeline stage insertion.

PHY not at die edge            Cannot route differential pairs to package pins;
                               respin required.

Power grid undersized          IR drop > 50 mV; flip-flops near the droopy
                               supply fail timing; chip fails at target frequency.

Congested routing channels     Auto-router cannot complete connections;
                               manual ECOs or floorplan changes required after
                               weeks of P&R effort.

Hard IP crossing power domain  Level-shifter cells cannot be inserted;
boundary without ISO cells     powered-off domain drives floating inputs
                               into active domain; functional failures.
```

**Interview insight:** Floorplanning mistakes are among the most expensive in chip design — they can require a full respin (new mask set, 3-6 months, $1-5M for advanced nodes). Senior architects are expected to identify floorplan risks early, during architecture definition, not after RTL freeze.

---

### Question A3
**What is the difference between a synchronous and an asynchronous reset in a flip-flop? What are the SoC-level implications of each choice, and which is preferred in large synchronous designs and why?**

**Answer:**

**Synchronous reset:**

```verilog
always_ff @(posedge clk) begin
    if (rst_n == 1'b0)
        q <= '0;
    else
        q <= d;
end
// Reset is sampled on the clock edge; only takes effect if clock is running.
// rst_n is a data-path input to the flip-flop (D input mux).
```

**Asynchronous reset:**

```verilog
always_ff @(posedge clk or negedge rst_n) begin
    if (rst_n == 1'b0)
        q <= '0;
    else
        q <= d;
end
// Reset takes effect immediately on assertion, independent of clock.
// Requires synchronous de-assertion to avoid metastability on release.
```

**Comparative analysis:**

| Property                       | Synchronous                  | Asynchronous                        |
|--------------------------------|------------------------------|-------------------------------------|
| Works without clock            | No                           | Yes                                 |
| Reset glitch sensitivity       | Immune (clock filters glitches) | Vulnerable to short glitches      |
| STA treatment                  | Normal data-path timing check | Asynchronous recovery/removal check|
| Reset de-assertion metastability | No risk                    | Risk if not synchronised            |
| Area (per FF)                  | Slightly larger (MUX)        | Slightly smaller (direct FF pin)   |
| Applicable to clock-gated logic | Requires careful handling   | Can reset independently of gating  |

**SoC-level implications:**

1. **Reset distribution:** An SoC has many clock domains. Asynchronous resets must be de-asserted synchronously in every domain separately via a reset synchroniser (two-flop synchroniser on the reset release edge). Failing to do this causes metastability when reset is released while flops in different domains emerge from reset at different, non-deterministic times.

2. **Power domains:** Logic in a powered-off domain must be reset before or immediately after power-on. An asynchronous reset allows reset assertion before the clock is stable — relevant when a power domain wakes up and the PLL is still locking.

3. **Scan / DFT:** Synchronous resets are simpler for scan chain insertion because reset logic is in the data path. Asynchronous resets require specific handling to ensure the scan shift clock does not accidentally trigger reset logic.

**Recommendation for large synchronous SoC designs:**

Most major design houses and ARM's own reference designs use **asynchronous assert, synchronous de-assert** reset strategy:

```
Reset assertion:   Asynchronous — immediately clears all state when rst_n goes low,
                   even if PLL has not locked and clock is absent.

Reset de-assertion: Synchronous per clock domain — a dedicated reset synchroniser
                    samples the reset release on the local domain clock:

    module reset_sync (
        input  wire clk, rst_async_n,
        output reg  rst_sync_n
    );
        reg meta;
        always_ff @(posedge clk or negedge rst_async_n) begin
            if (!rst_async_n) begin meta <= 1'b0; rst_sync_n <= 1'b0; end
            else              begin meta <= 1'b1; rst_sync_n <= meta;  end
        end
    endmodule
```

This gives the best of both: reliable reset without clock, glitch-immune de-assertion, no metastability on release, and STA-friendly timing because the release path is a synchronous two-flop chain.
