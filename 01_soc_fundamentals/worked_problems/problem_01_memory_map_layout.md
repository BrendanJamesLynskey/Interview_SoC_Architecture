# Problem 01: Memory Map Layout

## Problem Statement

You are architecting a microcontroller-class SoC with the following resource list. Your task is to produce a complete, justified memory map for a 32-bit address space, design the first-level address decoder, write the C header file, and verify the map is correct and complete.

**SoC resources:**

| Resource                   | Size    | Notes                                      |
|----------------------------|---------|--------------------------------------------|
| Boot ROM                   | 64 KB   | Read-only, executed on reset               |
| Embedded Flash             | 512 KB  | XIP (execute-in-place), erasable           |
| On-chip SRAM               | 128 KB  | Read/write, volatile                       |
| Backup SRAM (always-on)    | 4 KB    | Retains data through sleep modes           |
| UART (x2)                  | 4 KB ea | Serial interfaces                          |
| SPI (x2)                   | 4 KB ea | Serial peripheral interfaces               |
| I2C (x1)                   | 4 KB    | Two-wire serial bus                        |
| Timer / Counter (x4)       | 4 KB ea | General-purpose timers                     |
| Watchdog Timer             | 4 KB    | System watchdog                            |
| GPIO controller            | 4 KB    | 32-bit GPIO bank                           |
| ADC controller             | 4 KB    | 12-bit ADC, 8 channels                    |
| DMA controller             | 4 KB    | 8-channel DMA                              |
| Interrupt controller       | 4 KB    | NVIC (ARM-compatible)                      |
| Power Management Unit      | 4 KB    | Clock control, voltage, power domains      |
| System Control block       | 4 KB    | Chip ID, debug config, boot strap          |
| CoreSight debug            | 64 KB   | JTAG/SWD debug infrastructure             |
| ARM Private Peripheral Bus | 4 KB    | SysTick, ITM (fixed ARM location)          |

**Constraints:**
1. The ARM Cortex-M4 reset vector must be at 0x0000_0000.
2. ARM Private Peripheral Bus must appear at 0xE000_E000 (fixed by ARM architecture).
3. All regions must be naturally aligned to their size (power-of-two boundary).
4. All peripheral regions must be a minimum of 4 KB (even if the peripheral uses fewer registers).
5. The map must leave at least 50% of the peripheral space reserved for future expansion.

---

## Design Requirements

1. Assign a base address and size to every resource.
2. Verify natural alignment for all regions.
3. Produce the address decoder logic (first-level, SystemVerilog).
4. Generate the C header file with `#define` base address constants.
5. Verify correctness: no overlaps, mutual exclusivity, no gaps that alias to existing peripherals.

---

## Solution Approach

### Step 1 — Understand the ARM Cortex-M4 Address Map Convention

ARM Cortex-M4 defines a fixed address map layout. Adherence to this layout is strongly recommended to be compatible with standard tools (CMSIS, OpenOCD, etc.):

```
ARM Cortex-M4 recommended address regions:
  0x0000_0000 - 0x1FFF_FFFF  (512 MB) : Code region (Flash, ROM, aliased SRAM)
  0x2000_0000 - 0x3FFF_FFFF  (512 MB) : SRAM region
  0x4000_0000 - 0x5FFF_FFFF  (512 MB) : Peripheral region
  0x6000_0000 - 0x9FFF_FFFF  (  1 GB) : External RAM
  0xA000_0000 - 0xDFFF_FFFF  (  1 GB) : External device
  0xE000_0000 - 0xFFFF_FFFF  (512 MB) : System region (PPB, vendor-specific)
```

### Step 2 — Place Memory Regions

**Code region (0x0000_0000):**

- Boot ROM must be at or alias 0x0000_0000 (reset vector).
- Flash follows Boot ROM in contiguous code space.

```
Boot ROM: 64 KB at 0x0000_0000.  Alignment: 64 KB = 0x10000. 0x0000_0000 / 0x10000 = 0 ✓
Flash:   512 KB at 0x0008_0000.  Alignment: 512 KB = 0x80000. 0x0008_0000 / 0x80000 = 1 ✓
         Flash ends at 0x000F_FFFF.
         Next 64 KB boundary: 0x0010_0000. Place reserved region here.
```

**SRAM region (0x2000_0000):**

```
SRAM:        128 KB at 0x2000_0000. Alignment: 0x20000. 0x2000_0000 / 0x20000 = 0x1000 ✓
             SRAM ends at 0x2001_FFFF.
Backup SRAM: 4 KB at 0x4000_0000 is wrong (peripheral space).
             Backup SRAM is always-on, often placed near the PMU in peripheral space,
             or in a dedicated AO region. Place at 0x4000_B000 alongside PMU.
             (Decision rationale: backup SRAM is software-accessible memory but is
             in the AO power domain with the PMU. Placing it in peripheral space
             adjacent to PMU registers makes sense for driver organisation.)
```

**Peripheral region (0x4000_0000):**

Peripherals are allocated 4 KB pages starting at 0x4000_0000 with contiguous 4 KB stride:

```
0x4000_0000 : UART0         (4 KB)
0x4000_1000 : UART1         (4 KB)
0x4000_2000 : SPI0          (4 KB)
0x4000_3000 : SPI1          (4 KB)
0x4000_4000 : I2C0          (4 KB)
0x4000_5000 : TIMER0        (4 KB)
0x4000_6000 : TIMER1        (4 KB)
0x4000_7000 : TIMER2        (4 KB)
0x4000_8000 : TIMER3        (4 KB)
0x4000_9000 : WATCHDOG      (4 KB)
0x4000_A000 : GPIO0         (4 KB)
0x4000_B000 : ADC0          (4 KB)
0x4000_C000 : DMA           (4 KB)
0x4000_D000 : INTC (NVIC)   (4 KB)
0x4000_E000 : PMU           (4 KB)
0x4000_F000 : BACKUP_SRAM   (4 KB)
0x4001_0000 : SYSCTRL       (4 KB)
0x4001_1000 - 0x5FFF_FFFF  RESERVED (~511 MB) -- >99% reserved, far exceeds 50% requirement
```

Peripheral space used: 17 x 4 KB = 68 KB out of 512 MB = 0.013%. Constraint satisfied.

**System region (0xE000_0000):**

```
0xE000_0000 : CoreSight    (64 KB — contains ETM, FPB, DWT, ITM sub-blocks)
              Alignment: 64 KB. 0xE000_0000 / 0x10000 = 0xE000 ✓
0xE000_E000 : ARM PPB      (4 KB — fixed by ARM architecture; contains NVIC, SysTick, SCB)
              Note: SysTick and NVIC are in PPB, separate from our INTC peripheral.
              The INTC at 0x4000_D000 is a vendor interrupt controller that feeds the
              NVIC, not a replacement for it.
```

---

## Implementation Details

### Complete Memory Map Table

```
Address Range               Size      Resource            Notes
--------------------------  --------  ------------------  --------------------------------
0x0000_0000 - 0x0000_FFFF    64 KB   Boot ROM            XIP, reset vector, read-only
0x0001_0000 - 0x0007_FFFF   448 KB   RESERVED            Future ROM expansion
0x0008_0000 - 0x000F_FFFF   512 KB   Embedded Flash      XIP, erasable via Flash ctrl
0x0010_0000 - 0x1FFF_FFFF   ~511 MB  RESERVED            Future code space
0x2000_0000 - 0x2001_FFFF   128 KB   On-chip SRAM        Data, BSS, stack, heap
0x2002_0000 - 0x3FFF_FFFF   ~511 MB  RESERVED            Future SRAM expansion
0x4000_0000 - 0x4000_0FFF     4 KB   UART0
0x4000_1000 - 0x4000_1FFF     4 KB   UART1
0x4000_2000 - 0x4000_2FFF     4 KB   SPI0
0x4000_3000 - 0x4000_3FFF     4 KB   SPI1
0x4000_4000 - 0x4000_4FFF     4 KB   I2C0
0x4000_5000 - 0x4000_5FFF     4 KB   TIMER0
0x4000_6000 - 0x4000_6FFF     4 KB   TIMER1
0x4000_7000 - 0x4000_7FFF     4 KB   TIMER2
0x4000_8000 - 0x4000_8FFF     4 KB   TIMER3
0x4000_9000 - 0x4000_9FFF     4 KB   WATCHDOG
0x4000_A000 - 0x4000_AFFF     4 KB   GPIO0
0x4000_B000 - 0x4000_BFFF     4 KB   ADC0
0x4000_C000 - 0x4000_CFFF     4 KB   DMA controller
0x4000_D000 - 0x4000_DFFF     4 KB   Interrupt controller
0x4000_E000 - 0x4000_EFFF     4 KB   PMU (Power Mgmt)
0x4000_F000 - 0x4000_FFFF     4 KB   Backup SRAM         Always-on power domain
0x4001_0000 - 0x4001_0FFF     4 KB   System Control
0x4001_1000 - 0x5FFF_FFFF  ~511 MB   RESERVED            Future peripheral expansion
0xE000_0000 - 0xE000_FFFF    64 KB   CoreSight           ETM, DWT, FPB, ITM, ROM table
0xE000_E000 - 0xE000_EFFF     4 KB   ARM PPB             NVIC, SysTick, SCB (fixed ARM)
0xE001_0000 - 0xFFFF_FFFF   ~511 MB  RESERVED
```

### Address Decoder (SystemVerilog)

The first-level decoder divides the 32-bit space into major regions. A second-level APB decoder handles the peripheral page select.

```systemverilog
// First-level address decoder for Cortex-M4 SoC
// Generates region-select signals used by the AHB/AXI interconnect
// All regions naturally aligned; full decode on all 32 address bits.

module soc_addr_decoder_lvl1 (
    input  logic [31:0] haddr,          // AHB-Lite address from CPU
    output logic        boot_rom_sel,   // 0x0000_0000 - 0x0000_FFFF
    output logic        flash_sel,      // 0x0008_0000 - 0x000F_FFFF
    output logic        sram_sel,       // 0x2000_0000 - 0x2001_FFFF
    output logic        periph_sel,     // 0x4000_0000 - 0x4001_0FFF (feeds APB decoder)
    output logic        coresight_sel,  // 0xE000_0000 - 0xE000_FFFF
    output logic        ppb_sel,        // 0xE000_E000 - 0xE000_EFFF (subset of coresight)
    output logic        default_sel     // all other addresses -> bus error
);

    // Boot ROM: 64 KB at 0x0000_0000. Check bits[31:16] == 16'h0000.
    assign boot_rom_sel   = (haddr[31:16] == 16'h0000);

    // Flash: 512 KB at 0x0008_0000. Check bits[31:19] == 13'b0000000000100.
    // 0x0008_0000 = 32'b0000_0000_0000_1000_0000_0000_0000_0000
    // bits[31:19] = 0000_0000_0000_1 = 13'h0004 (0x0008_0000 >> 19 = 4)
    assign flash_sel      = (haddr[31:19] == 13'h0004);

    // SRAM: 128 KB at 0x2000_0000. Check bits[31:17] == 15'h1000.
    // 0x2000_0000 >> 17 = 0x1000
    assign sram_sel       = (haddr[31:17] == 15'h1000);

    // Peripheral space: covers 0x4000_0000 - 0x4001_0FFF (slightly over 64 KB).
    // Use a 128 KB region select (bits[31:17]) to cover all peripheral pages:
    // 0x4000_0000 / 0x20000 = 0x2000 -> bits[31:17] == 15'h2000
    // This covers 0x4000_0000 - 0x4001_FFFF (128 KB), which is safe because
    // 0x4001_1000 - 0x4001_FFFF is RESERVED and the APB decoder returns an error.
    assign periph_sel     = (haddr[31:17] == 15'h2000);

    // CoreSight: 64 KB at 0xE000_0000. Check bits[31:16] == 16'hE000.
    assign coresight_sel  = (haddr[31:16] == 16'hE000);

    // ARM PPB is a subset of CoreSight at 0xE000_E000 - 0xE000_EFFF.
    // PPB select is refined from within the CoreSight region by the sub-decoder.
    // Top-level: route all CoreSight accesses to the PPB/CoreSight sub-system.
    // The sub-system internally distinguishes PPB from CoreSight sub-blocks.
    assign ppb_sel        = (haddr[31:12] == 20'hE000E);  // exact 4 KB page

    // Default slave: no valid slave selected
    assign default_sel    = ~(boot_rom_sel | flash_sel | sram_sel |
                               periph_sel  | coresight_sel);

    // Simulation assertion: one-hot check (at most one main region selected)
    // periph_sel and coresight_sel/ppb_sel are in different address regions so cannot
    // overlap; ppb_sel is a subset of coresight_sel (handled at next level).
    `ifdef SIMULATION
    always_comb begin
        automatic int count = 0;
        if (boot_rom_sel)  count++;
        if (flash_sel)     count++;
        if (sram_sel)      count++;
        if (periph_sel)    count++;
        if (coresight_sel) count++;
        if (count > 1)
            $error("Decoder: multiple regions selected! addr=0x%08X", haddr);
    end
    `endif

endmodule
```

```systemverilog
// Second-level APB address decoder
// Input: APB address (the 17-bit word address within peripheral space)
// Output: 18 PSEL signals (one per peripheral + default)

module apb_decoder (
    input  logic [31:0] paddr,
    output logic [17:0] psel,     // [16:0] = peripherals, [17] = default/error
    output logic        psel_none
);

    // All peripherals are 4 KB pages; compare addr[31:12]
    // Base: 0x4000_0000, stride: 0x1000
    // Page number = (addr - 0x4000_0000) >> 12 = addr[31:12] - 20'h40000

    always_comb begin
        psel = '0;
        case (paddr[31:12])
            20'h40000: psel[0]  = 1'b1;  // UART0
            20'h40001: psel[1]  = 1'b1;  // UART1
            20'h40002: psel[2]  = 1'b1;  // SPI0
            20'h40003: psel[3]  = 1'b1;  // SPI1
            20'h40004: psel[4]  = 1'b1;  // I2C0
            20'h40005: psel[5]  = 1'b1;  // TIMER0
            20'h40006: psel[6]  = 1'b1;  // TIMER1
            20'h40007: psel[7]  = 1'b1;  // TIMER2
            20'h40008: psel[8]  = 1'b1;  // TIMER3
            20'h40009: psel[9]  = 1'b1;  // WATCHDOG
            20'h4000A: psel[10] = 1'b1;  // GPIO0
            20'h4000B: psel[11] = 1'b1;  // ADC0
            20'h4000C: psel[12] = 1'b1;  // DMA
            20'h4000D: psel[13] = 1'b1;  // INTC
            20'h4000E: psel[14] = 1'b1;  // PMU
            20'h4000F: psel[15] = 1'b1;  // BACKUP_SRAM
            20'h40010: psel[16] = 1'b1;  // SYSCTRL
            default:   psel[17] = 1'b1;  // Reserved / error slave
        endcase
    end

    assign psel_none = (psel == '0);

endmodule
```

### C Header File

```c
/* soc_memory_map.h
 * Auto-generated memory map header for XYZ-SoC rev 1.0
 * Source of truth: soc_memory_map.yaml (SystemRDL)
 * DO NOT EDIT MANUALLY — regenerate from source.
 */

#ifndef SOC_MEMORY_MAP_H
#define SOC_MEMORY_MAP_H

#include <stdint.h>

/* -----------------------------------------------------------------------
 * Code Region
 * --------------------------------------------------------------------- */
#define BOOT_ROM_BASE       (0x00000000UL)
#define BOOT_ROM_SIZE       (0x00010000UL)   /* 64 KB */

#define FLASH_BASE          (0x00080000UL)
#define FLASH_SIZE          (0x00080000UL)   /* 512 KB */

/* -----------------------------------------------------------------------
 * SRAM Region
 * --------------------------------------------------------------------- */
#define SRAM_BASE           (0x20000000UL)
#define SRAM_SIZE           (0x00020000UL)   /* 128 KB */

/* -----------------------------------------------------------------------
 * Peripheral Region — base addresses
 * --------------------------------------------------------------------- */
#define PERIPH_BASE         (0x40000000UL)

#define UART0_BASE          (PERIPH_BASE + 0x00000000UL)  /* 0x4000_0000 */
#define UART1_BASE          (PERIPH_BASE + 0x00001000UL)  /* 0x4000_1000 */
#define SPI0_BASE           (PERIPH_BASE + 0x00002000UL)  /* 0x4000_2000 */
#define SPI1_BASE           (PERIPH_BASE + 0x00003000UL)  /* 0x4000_3000 */
#define I2C0_BASE           (PERIPH_BASE + 0x00004000UL)  /* 0x4000_4000 */
#define TIMER0_BASE         (PERIPH_BASE + 0x00005000UL)  /* 0x4000_5000 */
#define TIMER1_BASE         (PERIPH_BASE + 0x00006000UL)  /* 0x4000_6000 */
#define TIMER2_BASE         (PERIPH_BASE + 0x00007000UL)  /* 0x4000_7000 */
#define TIMER3_BASE         (PERIPH_BASE + 0x00008000UL)  /* 0x4000_8000 */
#define WDT_BASE            (PERIPH_BASE + 0x00009000UL)  /* 0x4000_9000 */
#define GPIO0_BASE          (PERIPH_BASE + 0x0000A000UL)  /* 0x4000_A000 */
#define ADC0_BASE           (PERIPH_BASE + 0x0000B000UL)  /* 0x4000_B000 */
#define DMA_BASE            (PERIPH_BASE + 0x0000C000UL)  /* 0x4000_C000 */
#define INTC_BASE           (PERIPH_BASE + 0x0000D000UL)  /* 0x4000_D000 */
#define PMU_BASE            (PERIPH_BASE + 0x0000E000UL)  /* 0x4000_E000 */
#define BKPSRAM_BASE        (PERIPH_BASE + 0x0000F000UL)  /* 0x4000_F000 */
#define SYSCTRL_BASE        (PERIPH_BASE + 0x00010000UL)  /* 0x4001_0000 */

/* -----------------------------------------------------------------------
 * System Region
 * --------------------------------------------------------------------- */
#define CORESIGHT_BASE      (0xE0000000UL)
#define CORESIGHT_SIZE      (0x00010000UL)   /* 64 KB */

#define ARM_PPB_BASE        (0xE000E000UL)   /* ARM fixed: NVIC, SysTick, SCB */

/* -----------------------------------------------------------------------
 * Convenience macros for register access
 * Usage: REG32(UART0_BASE + UART_CTRL_OFFSET) = value;
 * --------------------------------------------------------------------- */
#define REG32(addr)         (*(volatile uint32_t *)(addr))
#define REG16(addr)         (*(volatile uint16_t *)(addr))
#define REG8(addr)          (*(volatile uint8_t  *)(addr))

#endif /* SOC_MEMORY_MAP_H */
```

---

## Verification

### Alignment Check

Verify each region is naturally aligned (base_address % size == 0):

```
Boot ROM:    0x0000_0000 % 0x10000 = 0  ✓
Flash:       0x0008_0000 % 0x80000 = 0  ✓
SRAM:        0x2000_0000 % 0x20000 = 0  ✓
Backup SRAM: 0x4000_F000 % 0x1000  = 0  ✓
UART0:       0x4000_0000 % 0x1000  = 0  ✓
...all 4 KB peripherals: stride is 0x1000, all bases are multiples of 0x1000  ✓
CoreSight:   0xE000_0000 % 0x10000 = 0  ✓
```

### Overlap Check

All regions are in distinct 512 MB ARM architecture regions:

```
0x0000_xxxx (Code):      Boot ROM + Flash -- no overlap (Boot ROM ends at 0x0000_FFFF,
                          Flash starts at 0x0008_0000, gap of 448 KB is RESERVED)
0x2000_xxxx (SRAM):       SRAM only -- no overlap
0x4000_xxxx (Peripheral): All 4 KB-aligned, sequential pages -- no overlap
0xE000_xxxx (System):     CoreSight and PPB share the 64 KB region; PPB is a
                           sub-region within CoreSight, handled by the CoreSight sub-decoder
```

### Future Expansion Headroom

```
Code space available:   511 MB - 64 KB - 512 KB ≈ 510 MB remaining (99.9% free)
SRAM space available:   512 MB - 128 KB ≈ 511 MB remaining (99.97% free)
Peripheral space used:  17 x 4 KB = 68 KB of 512 MB (0.013% used, 99.99% free)
```

The 50% reservation constraint is far exceeded.

---

## Key Takeaways

1. **Follow the ARM Cortex-M memory map template.** Placing Flash at 0x0000_0000 and SRAM at 0x2000_0000 is not a convention — it enables CMSIS compatibility, correct MPU region configuration, and tool support out of the box.

2. **Use 4 KB minimum peripheral pages, even for small peripherals.** The 4 KB alignment requirement simplifies the decoder and guarantees compatibility with the MMU / MPU, which operates on 4 KB page granularity.

3. **Always generate C headers from the RTL address map.** Manual transcription from the RTL address map to the header file is a common source of bugs. Use IP-XACT / SystemRDL tooling to auto-generate both.

4. **Reserve address space aggressively.** Peripheral I/O space costs nothing (it is just a virtual range, not physical silicon), and reserved space enables adding peripherals in future silicon revisions without breaking the existing address map. Breaking the address map breaks all existing firmware.

5. **Verify the decoder with a formal tool or exhaustive simulation.** A one-hot property on the PSEL output, proven formally, eliminates an entire class of decoder bugs. Run this verification before tapeout, not after.
