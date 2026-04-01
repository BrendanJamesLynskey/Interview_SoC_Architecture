# Memory Map Design

## Prerequisites
- Binary and hexadecimal number representation
- Basic bus transaction concepts (address, data, read/write)
- SoC building blocks (processor cores, memory, peripherals)

---

## Concept Reference

### Memory-Mapped vs Port-Mapped I/O

| Property                 | Memory-Mapped I/O (MMIO)            | Port-Mapped I/O (PMIO)                     |
|--------------------------|-------------------------------------|--------------------------------------------|
| Address space            | Unified with memory                 | Separate I/O port address space (x86: 16-bit)|
| CPU instructions         | Ordinary load / store               | Dedicated IN / OUT instructions            |
| Protection mechanism     | MMU page table attributes           | Privilege level (IOPL on x86)              |
| Address range            | Full address bus width              | Typically 64 KB (x86)                      |
| Adoption                 | ARM, RISC-V, MIPS, all modern SoCs  | x86 legacy only                            |
| Cache/speculative access | Controlled via memory type (Normal vs Device) | N/A                            |

Modern SoCs exclusively use MMIO. The rest of this file deals with MMIO only.

### Address Space Anatomy

For a 32-bit processor with a 4 GB address space (0x0000_0000 to 0xFFFF_FFFF):

```
0xFFFF_FFFF
            +-------------------+
            |  Private periph.  |  0xE000_0000 - 0xFFFF_FFFF (512 MB)
            |  (ARM PPB region) |  NVIC, SysTick, CoreSight
            +-------------------+
            |    Reserved /     |  0xA000_0000 - 0xDFFF_FFFF (1 GB)
            |    External dev   |
            +-------------------+
            |   Peripheral bus  |  0x4000_0000 - 0x9FFF_FFFF (1.5 GB)
            |   (APB/AHB slaves)|
            +-------------------+
            |  On-chip SRAM /   |  0x2000_0000 - 0x3FFF_FFFF (512 MB)
            |   TCM regions     |
            +-------------------+
            |   Code / ROM /    |  0x0000_0000 - 0x1FFF_FFFF (512 MB)
            |   Flash / DRAM    |
0x0000_0000
```

Specific SoCs adjust these regions. ARM Cortex-M uses a fixed SAU (Secure Attribution Unit) partition; Cortex-A uses MMU page tables for full software control.

### Alignment Rules

A peripheral region of size S must be aligned to an address that is a multiple of S:

```
4 KB region:   must start at address with bits[11:0]  == 0  (e.g., 0x4000_1000)
64 KB region:  must start at address with bits[15:0]  == 0  (e.g., 0x4001_0000)
1 MB region:   must start at address with bits[19:0]  == 0  (e.g., 0x4010_0000)
```

**Why alignment matters:** Power-of-two aligned regions allow the address decoder to use a simple AND-mask comparison rather than a range comparator. Unaligned regions require two comparators (base address <= addr AND addr < base+size), which is larger and slower. Most AMBA address decode specifications require naturally aligned regions.

### Typical Peripheral Address Stride

Each peripheral is allocated a page (4 KB minimum, often 64 KB for future expansion):

```
Base + 0x0000 : UART0 control registers   (actual regs may occupy only 32 bytes)
Base + 0x1000 : UART1 control registers
Base + 0x2000 : SPI0 control registers
Base + 0x3000 : I2C0 control registers
Base + 0x4000 : Timer0 registers
...
```

Using 4 KB pages even when a peripheral has only 8 registers (32 bytes used, 4064 bytes wasted) simplifies decoder logic and future expansion without breaking backward compatibility.

---

## Tier 1 — Fundamentals

### Question F1
**What is an address map? Why does every SoC need one and who consumes it?**

**Answer:**

An **address map** (also called a memory map or register map) is the authoritative specification that assigns a physical address range to every resource visible on a bus: memories, peripheral register banks, configuration registers, and system control registers.

**Why it is essential:**

1. **Hardware implementation:** Address decoders in the interconnect fabric use the address map to route transactions to the correct slave. Without it, there is no defined behaviour for any bus access.

2. **Software development:** Drivers, bootloaders, and operating system HAL layers all hard-code or load-time configure base addresses from the address map. An error in the address map immediately causes software to access the wrong peripheral or crash.

3. **Verification:** UVM test environments use the register model (built from the address map) to generate directed and random register accesses, check reset values, and verify read/write behaviour.

4. **Security:** An MPU or IOASID in a hypervisor uses the address map to constrain which physical addresses each virtual machine or process is permitted to access.

**Consumers of the address map:**

| Consumer                    | Format it needs                              |
|-----------------------------|----------------------------------------------|
| RTL engineer                | Verilog parameters / header file constants   |
| Software / firmware team    | C header file (#define BASE_UART 0x40000000) |
| Verification engineer       | SystemVerilog UVM `uvm_reg_block` model      |
| Documentation               | PDF register map (IP-XACT generated)         |
| EDA tools (synthesis, P&R)  | SDC constraints referencing memory regions   |

**Single source of truth:** Most SoC teams maintain the address map in a structured format (IP-XACT XML, SystemRDL, or a spreadsheet with tooling) and generate all derivative views automatically to prevent inconsistencies.

---

### Question F2
**What is the difference between a naturally aligned memory region and an arbitrary base-address region? Give examples of each with their decoder equations.**

**Answer:**

**Naturally aligned region:** The base address is a multiple of the region size. The size is always a power of two.

```
Example: UART0 at base 0x4000_0000, size 4 KB (0x1000)

Region is hit when:  addr[31:12] == 0x4000_0000 >> 12
                 i.e. addr[31:12] == 20'h40000

Decoder logic:
  wire uart0_sel = (addr[31:12] == 20'h40000);

This is a single equality comparison — synthesises to a 20-bit XNOR tree, typically
1-2 gate delays regardless of address bus width.
```

**Arbitrary base-address region (not power-of-two aligned or sized):**

```
Example: a legacy block at 0x4001_2800, size 0x600 (1536 bytes)

Region is hit when:  (addr >= 32'h40012800) && (addr < 32'h40012E00)

Decoder logic requires:
  wire uart_legacy_sel = (addr >= 32'h40012800) && (addr <= 32'h40012DFF);

This requires two 32-bit magnitude comparators — roughly 5x the gate count of the
aligned version, and potentially 2-3 additional gate delays on the decode path.
```

**Why the difference matters in an SoC interconnect:**

The address decoder sits on the critical path of every bus transaction. Every nanosecond of decode latency either:
- Adds directly to the peripheral access latency (for single-cycle peripherals), or
- Reduces the maximum bus frequency for the entire fabric.

For a 500 MHz AXI bus with a 2 ns clock period, a decoder that takes 1.5 ns leaves only 0.5 ns of margin. Adding even a single non-aligned region can push the decoder off-critical-path onto the timing-critical path, requiring the entire crossbar to be replicated or pipelined.

**Best practice:** Enforce natural alignment for all regions. Legacy blocks that must live at inconvenient addresses should be wrapped in a naturally-aligned page with the remainder of the page reserved.

---

### Question F3
**Explain the concept of memory-mapped register fields: read-write (RW), read-only (RO), write-1-to-clear (W1C), and write-only (WO). Give a practical example of each in a real peripheral.**

**Answer:**

Peripheral registers are built from fields with access semantics that differ from ordinary SRAM:

**Read-Write (RW):** The field retains whatever value software writes. Subsequent reads return the written value.

```
Example: UART Baud Rate Divisor register
  Address: 0x4000_000C
  Bits[15:0] = DIVISOR (RW)
  Reset value: 0x0000 (baud rate undefined until programmed)
  Behaviour: write sets the baud rate; read returns the current divisor.
```

**Read-Only (RO):** Software cannot write this field; writes are ignored (or bus-errored). The value reflects hardware state.

```
Example: UART Status register
  Address: 0x4000_0008
  Bit[0] = TX_FIFO_EMPTY (RO)  -- 1 if TX FIFO has space, 0 if full
  Bit[1] = RX_FIFO_FULL  (RO)  -- 1 if RX FIFO is full
  Behaviour: read returns current FIFO status; writes have no effect.
```

**Write-1-to-Clear (W1C):** Writing a 1 to a bit position clears that bit to 0. Writing a 0 has no effect. This allows clearing individual interrupt flags without affecting others using a read-modify-write.

```
Example: UART Interrupt Status register
  Address: 0x4000_0010
  Bit[0] = TX_DONE_IRQ   (W1C)  -- set by HW when TX completes
  Bit[1] = RX_READY_IRQ  (W1C)  -- set by HW when data arrives
  Bit[2] = PARITY_ERR    (W1C)  -- set by HW on parity error

  To clear only the TX_DONE interrupt (leave others untouched):
    *(volatile uint32_t *)0x40000010 = (1 << 0);   // Write 1 to bit 0 only
    // Writing 0 to bits 1 and 2 has no effect — they are not cleared.

  WRONG approach (corrupts other bits):
    uint32_t val = *(volatile uint32_t *)0x40000010; // read
    val |= (1 << 0);                                 // set bit 0
    *(volatile uint32_t *)0x40000010 = val;          // write back
    // Between read and write, hardware may have SET bit[1]. The write-back
    // now clears bit[1] too, which was not intended. W1C avoids this race.
```

**Write-Only (WO):** Software can write but reads return 0 (or an undefined value). Used for FIFO push registers and command trigger registers where a "current value" is meaningless.

```
Example: UART TX data register
  Address: 0x4000_0000
  Bits[7:0] = TX_DATA (WO)
  Behaviour: Writing pushes one byte into the TX FIFO.
             Reading returns 0x00 (field has no readable state).

  Why WO for TX_DATA: There is no "current transmit byte" to read back —
  the byte immediately moves to the FIFO and may already be shifting out.
  Making it WO prevents software from incorrectly reading back what it wrote.
```

---

## Tier 2 — Intermediate

### Question I1
**Design a memory map for an MCU-class SoC with the following resources: 256 KB Flash (boot), 64 KB SRAM, 32 KB ROM, UART x2, SPI x1, I2C x1, Timer x4, GPIO x1, Interrupt controller, and System control registers. Assign addresses and justify your choices.**

**Answer:**

**Design approach:**

1. Place boot code (Flash/ROM) at or near 0x0000_0000 (ARM reset vector).
2. Place SRAM in the canonical ARM code/SRAM split (0x2000_0000 for data, or use TCM).
3. Group all peripherals in the 0x4000_0000 range using 4 KB pages.
4. Place system control (SCS/NVIC/SysTick) at 0xE000_0000 per ARM Cortex-M specification.

```
Address Range               Size    Region          Notes
--------------------------  ------  --------------  ------------------------------------
0x0000_0000 - 0x0003_FFFF   256 KB  Flash (XIP)     Reset vector at 0x0000_0000 (ARM)
0x0004_0000 - 0x0007_FFFF   256 KB  Reserved        Future Flash expansion
0x1FFF_0000 - 0x1FFF_7FFF    32 KB  ROM             Boot ROM (IAP, USB DFU routines)
0x1FFF_8000 - 0x1FFF_FFFF    32 KB  Reserved
0x2000_0000 - 0x2000_FFFF    64 KB  SRAM            Data, stack, heap
0x2001_0000 - 0x3FFF_FFFF    ~     Reserved
0x4000_0000 - 0x4000_0FFF     4 KB  UART0           8 registers x 4 bytes each
0x4000_1000 - 0x4000_1FFF     4 KB  UART1
0x4000_2000 - 0x4000_2FFF     4 KB  SPI0
0x4000_3000 - 0x4000_3FFF     4 KB  I2C0
0x4000_4000 - 0x4000_4FFF     4 KB  Timer0
0x4000_5000 - 0x4000_5FFF     4 KB  Timer1
0x4000_6000 - 0x4000_6FFF     4 KB  Timer2
0x4000_7000 - 0x4000_7FFF     4 KB  Timer3
0x4000_8000 - 0x4000_8FFF     4 KB  GPIO0
0x4000_9000 - 0x4000_9FFF     4 KB  Interrupt Ctrl
0x4000_A000 - 0x4000_AFFF     4 KB  System Control  (Clock, Reset, Power)
0x4000_B000 - 0x4FFF_FFFF    ~    Reserved          Future peripherals
0xE000_0000 - 0xE000_0FFF     4 KB  SysTick         ARM Cortex-M private
0xE000_E000 - 0xE000_EFFF     4 KB  NVIC / SCB      ARM Cortex-M private
0xE004_0000 - 0xE004_0FFF     4 KB  CoreSight / ITM ARM Cortex-M private
```

**Justification of key decisions:**

1. **Flash at 0x0000_0000:** ARM Cortex-M reads the reset vector from 0x0000_0004 and the initial stack pointer from 0x0000_0000. Flash must appear here for XIP boot.

2. **ROM at 0x1FFF_0000:** Separate from Flash to allow separate MPU protection (ROM is always read-only; Flash may need write access for in-application programming). Using the upper half of the 512 MB Code region mirrors the STM32/NXP convention.

3. **SRAM at 0x2000_0000:** ARM canonical SRAM region. The Cortex-M bit-band alias at 0x2200_0000 provides atomic single-bit access to SRAM bytes — a useful capability for interrupt flag manipulation in embedded code.

4. **Peripherals starting at 0x4000_0000 with 4 KB stride:** Each 4 KB page requires only addr[31:12] comparison in the APB decoder. All 11 peripherals fit in a contiguous 44 KB window (0x4000_0000 - 0x4000_AFFF) with a single 64 KB top-level select (addr[31:16] == 0x4000) simplifying the primary decoder.

5. **Private ARM peripheral bus at 0xE000_0000:** Fixed by ARM architecture specification; the SoC designer cannot move these.

---

### Question I2
**What is a memory map conflict (alias)? Describe how it arises from partial address decoding and give a concrete example with the decode logic.**

**Answer:**

A **memory map alias** occurs when multiple different addresses map to the same physical resource. It is caused by **partial address decoding** — a decoder that checks only a subset of the address bits, leaving the ignored bits free to take any value.

**Example — partial decoder for a UART:**

Suppose the designer writes a decoder that only checks bits [15:12] to save gates:

```
// Decoder checks only addr[15:12], ignores addr[31:16] and addr[11:0]
wire uart0_sel = (addr[15:12] == 4'h0);   // WRONG: partial decode

Intended: UART0 selected at exactly 0x4000_0000 - 0x4000_0FFF

Actual behaviour:
  0x4000_0000 -> UART0 selected (addr[15:12] == 0x0, addr[31:16] == 0x4000) CORRECT
  0x4000_1000 -> UART0 selected (addr[15:12] == 0x1 -- WRONG, not 0x0)
  
Wait — this particular example doesn't select at 0x4000_1000. Let's make it clearer:
```

```
// A worse partial decoder for an SRAM — only checks bits [15:14]:
wire sram_sel = (addr[15:14] == 2'b00);

Intended: SRAM at 0x2000_0000 - 0x2000_3FFF (16 KB)

Actual aliases (all address bits except [15:14] are ignored):
  0x2000_0000 -> SRAM selected (correct)
  0x2001_0000 -> SRAM selected (bits[15:14]=00, ignored bits differ)
  0x2002_0000 -> SRAM selected
  0x2003_0000 -> SRAM selected
  ...
  0x3FFF_C000 -> SRAM selected (any addr where bits[15:14]==00 and upper bits irrelevant)

Physical address within SRAM = addr[13:0] (lower bits used as SRAM word address).
The alias stride is 2^16 = 64 KB: accesses at 0x2000_0000 and 0x2001_0000 hit the
SAME 16 KB SRAM, accessing the same physical words.
```

**Why partial decoding is sometimes intentional:**

Embedded microcontrollers (e.g., original 8051) used partial decode to save gates when the full address space was never going to be populated. The programmer was aware of aliases and avoided them.

**Why partial decoding is dangerous in SoC design:**

1. **Software bugs:** Code that accidentally accesses an alias region may appear to work in simulation but fails on silicon if the address space is later populated.

2. **Security holes:** A peripheral that should only be accessible at 0x4000_0000 may be accidentally accessible from a memory region that a less-privileged execution context can reach.

3. **Debugging confusion:** A logic analyser or debugger shows an access at 0x2001_0000 but the software developer expects only 0x2000_0000 to reach the SRAM.

**Full decode fix:**

```
// Full decode: check all bits that distinguish this peripheral from all others
wire sram_sel = (addr[31:14] == 18'h80000);  // 0x2000_0000 >> 14 = 0x80000
                                               // Only exactly 16 KB at 0x2000_0000
```

---

### Question I3
**What are the key differences between a flat address map and a hierarchical address map? When is each approach preferred?**

**Answer:**

**Flat address map:** Every resource is decoded by a single centralised decoder that examines the full address and generates one select signal per slave. Used in simple, small SoCs.

```
Single decoder example (4 slaves):
  addr[31:12] == 20'h00000 => FLASH_SEL
  addr[31:12] == 20'h20000 => SRAM_SEL
  addr[31:12] == 20'h40000 => UART0_SEL
  addr[31:12] == 20'h40001 => UART1_SEL

All four comparisons run in parallel; one gate-delay level for the final mux.
```

**Hierarchical (two-stage) address map:** A primary decoder routes transactions to one of several subsystem buses. Each subsystem has its own secondary decoder.

```
Primary decoder (checks addr[31:28]):
  4'h0 => CODE_BUS    (Flash, ROM)
  4'h2 => SRAM_BUS
  4'h4 => PERIPH_BUS  (all peripherals)
  4'hE => SYSTEM_BUS  (NVIC, CoreSight)

Secondary decoder on PERIPH_BUS (checks addr[15:12]):
  4'h0 => UART0
  4'h1 => UART1
  4'h2 => SPI0
  4'h3 => I2C0
  4'h4 => TIMER0
  ...
```

**Comparison:**

| Property              | Flat                            | Hierarchical                          |
|-----------------------|---------------------------------|---------------------------------------|
| Decoder latency       | One stage (fast)                | Two stages (slight added latency)     |
| Scalability           | Poor (comparator count = slaves)| Good (each level has few entries)     |
| Power                 | All comparators active always   | Only relevant secondary decoder active|
| Congestion            | All select wires fan out globally| Contained within subsystem            |
| Typical slave count   | < 16                            | 16 to hundreds                        |

**When to use flat:** Simple MCU SoCs with fewer than 16 peripherals, or for the highest-performance bus tier (AXI crossbar) where every cycle of latency matters and the number of slaves is small and fixed.

**When to use hierarchical:** Application processor SoCs with many peripherals. The APB bus matrix is inherently hierarchical — the AXI-to-APB bridge is the first-level decode, and the APB decoder is the second level. This structure also enables independent power gating of peripheral subsystems.

---

## Tier 3 — Advanced

### Question A1
**An SoC ships with the memory map shown below. Firmware is byte-addressable. A new silicon revision adds a new 8 KB cryptographic accelerator that must live in the existing peripheral space. Walk through the process of adding it without breaking backward compatibility, and identify all the artefacts that must be updated.**

```
Existing peripheral space: 0x4000_0000 - 0x4000_BFFF (48 KB, 12 peripherals x 4 KB)
  0x4000_0000 : UART0
  0x4000_1000 : UART1
  ... (10 more peripherals)
  0x4000_B000 : System Control
  0x4000_C000 - 0x4FFF_FFFF : RESERVED
```

**Answer:**

**Step 1 — Verify address space availability**

The crypto block requires 8 KB = 0x2000 bytes. It must be naturally aligned (start address is a multiple of 8 KB = 0x2000). The first free naturally-aligned 8 KB slot after the existing 12 peripherals:

```
Next 4 KB boundary after 0x4000_B000 = 0x4000_C000
8 KB alignment: 0x4000_C000 is divisible by 0x2000? 0xC000 / 0x2000 = 6 exactly. Yes.
Assignment: CRYPTO0 at 0x4000_C000 - 0x4000_DFFF (8 KB)
```

**Step 2 — Verify no backward compatibility breakage**

The new block occupies 0x4000_C000 - 0x4000_DFFF, which was previously RESERVED. No existing peripheral is displaced. Existing software accessing 0x4000_0000 through 0x4000_BFFF is unaffected.

**Step 3 — Verify decoder changes**

The APB bus matrix secondary decoder currently generates 12 PSEL signals. It must be updated to generate 13 PSEL signals:

```
// Before: secondary decoder partial logic
wire [11:0] periph_sel;
always_comb begin
    periph_sel = '0;
    case (addr[15:12])        // 4 KB pages
        4'h0: periph_sel[0]  = 1; // UART0
        4'h1: periph_sel[1]  = 1; // UART1
        ...
        4'hB: periph_sel[11] = 1; // System Control
        default: periph_sel = '0; // bus error / default slave
    endcase
end

// After: must expand to support 8 KB block at 0xC000-0xDFFF
// addr[15:12] for 0xC000 = 4'hC, for 0xD000 = 4'hD
// Need to add two entries that both map to crypto:
always_comb begin
    periph_sel = '0;
    case (addr[15:12])
        4'hC: periph_sel[12] = 1; // CRYPTO0 lower 4 KB
        4'hD: periph_sel[12] = 1; // CRYPTO0 upper 4 KB (same peripheral)
        ...
    endcase
end
// The CRYPTO0 peripheral uses addr[12] to distinguish its two 4 KB halves internally.
```

**Step 4 — All artefacts that must be updated**

| Artefact                          | Change required                                                  |
|-----------------------------------|------------------------------------------------------------------|
| RTL: APB bus matrix decoder       | Add two case entries (0xC, 0xD) mapping to CRYPTO0 PSEL          |
| RTL: top-level address map param  | Add `CRYPTO0_BASE = 32'h4000_C000`                               |
| C header (`soc_memory_map.h`)     | Add `#define CRYPTO0_BASE 0x40000C000UL`                         |
| Device Tree Source (`.dts`)       | Add `crypto0: crypto@40000C000 { reg = <0x40000C000 0x2000>; }` |
| UVM register model                | Add `crypto0_reg_block` to address map at offset 0x4000_C000     |
| IP-XACT / SystemRDL               | Add CRYPTO0 component to SoC-level address map                   |
| MPU / TrustZone configuration     | Assign appropriate security attribute to CRYPTO0 region          |
| Software driver                   | New crypto driver using base address from header                  |
| Verification plan                 | Add test cases for CRYPTO0 register access, APB bus behaviour    |
| Chip datasheet / TRM              | New register map chapter for CRYPTO0                             |

**Common mistake:** Teams update the C header and driver but forget to update the UVM register model. The result is that the verification environment does not exercise the new peripheral, and first-silicon bugs in CRYPTO0 are discovered late in validation.

---

### Question A2
**Explain how NUMA (Non-Uniform Memory Access) manifests in a multi-cluster SoC, and describe how the memory map design can either exacerbate or mitigate its effects on software performance.**

**Answer:**

**NUMA in SoC context:**

A multi-cluster SoC (e.g., ARM DynamIQ with a big cluster and a LITTLE cluster sharing an L3 cache and DRAM controller via a CCI or CMN interconnect) exhibits NUMA-like characteristics because the latency to reach different memory regions differs depending on which cluster is the requester.

```
Typical DynamIQ topology:
  Cluster A (Cortex-A55, LITTLE): 4 cores, 512 KB L2
  Cluster B (Cortex-A78, big):    4 cores, 4 MB L3
  Shared CMN-700 interconnect
  LPDDR5 controller (1 or 2 channels)

Access latencies (approximate):
  A55 core -> A55 L1 hit:           4 cycles
  A55 core -> A55 L2 hit:          12 cycles
  A55 core -> CMN L3 hit:          40 cycles  (traverses CMN)
  A55 core -> LPDDR5 (CMN miss): ~200 cycles  (DRAM latency + CMN routing)

  A78 core -> A78 L1 hit:           4 cycles
  A78 core -> CMN L3 hit:          20 cycles  (closer to L3 in CMN topology)
  A78 core -> LPDDR5 (CMN miss): ~200 cycles  (same DRAM, shorter CMN path)
```

The A55 core sees a higher latency to the shared L3 than the A78 because of additional hops in the CMN mesh. This is a NUMA effect within a single die.

**How memory map design exacerbates NUMA:**

1. **All DMA buffers in one DRAM region:** If DMA video buffers are allocated at low physical addresses that map to DRAM channel 0, and the GPU (big cluster) is physically closer to DRAM channel 1 in the floor plan, the GPU's requests must traverse additional CMN hops to reach channel 0. Peak bandwidth to the GPU is reduced.

2. **Interleaved vs non-interleaved DRAM:** A flat interleaved DRAM address map (address bits distributed across channels) gives maximum bandwidth for large streaming workloads but prevents pinning data to a near channel. A non-interleaved map allows NUMA-aware allocation but wastes bandwidth when one channel is saturated.

**How memory map design mitigates NUMA:**

1. **NUMA-aware physical address layout:** Reserve the upper half of DRAM for high-bandwidth GPU and media workloads, mapped to the DRAM channel with shorter latency/routing to the GPU cluster. The kernel allocator is taught to prefer this region for GPU buffer allocations.

   ```
   0x80_0000_0000 - 0xBF_FFFF_FFFF : DRAM channel 0 (mapped to A55-side DRAM)
   0xC0_0000_0000 - 0xFF_FFFF_FFFF : DRAM channel 1 (mapped to A78/GPU-side DRAM)
   ```

2. **On-chip SRAM scratchpads per cluster:** Tight-coupled SRAM mapped into each cluster's private address range guarantees zero-latency data with no NUMA effects for real-time workloads.

3. **Device Tree / ACPI NUMA topology tables:** The memory map exposed to the OS includes NUMA node IDs for each physical address range. Linux `numactl` and the kernel slab allocator use this to make NUMA-aware allocation decisions.

**Key interview insight:** NUMA management is primarily a software concern, but the hardware architect makes it tractable or intractable through the memory map and interconnect topology choices made at architecture time.
