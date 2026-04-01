# Problem 01: Power Domain Design for a Mobile SoC

## Problem Statement

You are the power architecture lead for a mid-range mobile SoC targeting a smartphone with a 4,000 mAh battery. The SoC must meet the following system requirements:

**Active performance targets:**
- Peak CPU performance: quad-core A75-class cluster at up to 2.4 GHz
- GPU: 6-core GPU at up to 850 MHz
- Image signal processor (ISP): 500 MHz, activated only during camera capture
- Neural processing unit (NPU): 1 GHz, activated for on-device AI inference
- Display controller: 400 MHz, active whenever screen is on
- Modem (integrated): 400 MHz, active during cellular data

**Standby targets:**
- Active standby (screen off, modem active): ≤ 3 mA from 3.8 V battery = ≤ 11.4 mW
- Deep sleep (airplane mode): ≤ 300 μA = ≤ 1.14 mW

**Voltage rail constraints (PMIC provides):**
- VDD_MAIN: 0.5 – 1.05 V (buck converter, 50 mV steps, ±3% regulation)
- VDD_GPU: 0.45 – 0.95 V (dedicated buck, 25 mV steps)
- VDD_MODEM: 0.8 V fixed
- VDD_MEM: 1.1 V (LPDDR5 VDD2H)
- VDD_AON: 0.75 V (always-on, LDO)
- VDD_IO: 1.8 V / 3.3 V (I/O ring)

**Questions:**

1. Define the power domain partitioning for this SoC. Specify which blocks belong to each domain, the supply voltage range, and the power-gating strategy.

2. Identify all required isolation cells and level shifters at domain boundaries. Justify the clamp values for isolation cells.

3. Design the power-up and power-down sequencing for the CPU cluster domain.

4. Calculate the leakage power budget allocation per domain to meet the deep sleep target of 300 μA at 3.8 V.

5. The display domain must remain active while the CPU, GPU, ISP, and NPU domains are all powered off. Identify all the interface signals that cross from powered-off domains into the display domain, and specify the required isolation strategy.

---

## Worked Solution

### Step 1: Power Domain Partitioning

Define domains based on functional independence, power-gating granularity, and voltage requirements:

```
Domain Name      Contents                      Voltage Range       Power Gate?   Notes
────────────────────────────────────────────────────────────────────────────────────────
PD_AON           PMU, RTC, wakeup logic,       0.75 V (fixed)      Never         Root domain
                 OTP controller, boot ROM
                 
PD_CPU           4× A75-class cores,           0.55 – 1.05 V       Yes (MTCMOS)  DVFS domain
                 L2 cache (1 MB shared),        (VDD_MAIN)
                 GIC CPU interface
                 
PD_GPU           6-core GPU, GPU L2 cache      0.45 – 0.95 V       Yes           Dedicated supply
                 (512 KB), tile buffer           (VDD_GPU)
                 
PD_ISP           Image signal processor,        0.55 – 0.95 V       Yes           Camera only
                 raw buffer SRAM (8 MB)          (VDD_MAIN)
                 
PD_NPU           Neural processing unit,        0.55 – 0.95 V       Yes           AI inference only
                 weight SRAM (4 MB)              (VDD_MAIN)
                 
PD_DISPLAY       Display controller,            0.55 – 0.85 V       Yes (but      Always on if
                 DSI PHY controller,             (VDD_MAIN)          rare)         screen on
                 video scaler
                 
PD_MODEM         Cellular modem, Wi-Fi,         0.8 V (fixed)       Yes           Radio subsystem
                 Bluetooth, GNSS                 (VDD_MODEM)
                 
PD_MEM_CTRL      DDR memory controller,         0.55 – 0.95 V       Retention     Partial off:
                 PHY (digital part)              (VDD_MAIN)          only          self-refresh
                 
PD_PERIPH        USB, SDMMC, I2C, SPI,          0.75 – 0.95 V       Per-block     Peripheral cluster
                 UART, GPIO, PCIe            
```

**Domain hierarchy:**

```
PD_AON (always on)
   ├── PD_CPU (power-gatable, DVFS)
   ├── PD_GPU (power-gatable, DVFS, separate supply)
   ├── PD_ISP (power-gatable)
   ├── PD_NPU (power-gatable)
   ├── PD_DISPLAY (rarely off, but power-gatable)
   ├── PD_MODEM (power-gatable, fixed voltage)
   ├── PD_MEM_CTRL (retention mode, not full off)
   └── PD_PERIPH (per-peripheral gating)
```

**Rationale for key decisions:**

- **GPU on separate VDD_GPU supply:** GPU voltage scaling follows a different OPP curve from the CPU. At light GPU load (video decode), GPU can run at 0.55 V / 200 MHz while CPU remains at 0.8 V / 1.5 GHz. A shared supply would force both domains to the higher voltage.

- **ISP and NPU on VDD_MAIN:** These blocks are rarely active simultaneously. A shared supply is acceptable since their DVFS points are compatible. Separate supplies would add cost without meaningful power benefit.

- **Modem at fixed voltage:** The RF analog front-end requires a stable, low-noise supply. The digital modem baseband runs at 0.8 V to match the RF section. DVFS is handled at the modem subsystem level internally.

- **Memory controller in retention mode (not full off):** Turning the memory controller completely off requires the DRAM to exit self-refresh, which takes ~200 μs and requires re-initialisation. Retention mode keeps the controller logic in a low-leakage state, reducing wake-up latency to ~10 μs.

---

### Step 2: Isolation Cells and Level Shifters

**Isolation cell requirements:**

At each domain boundary where a power-gated domain drives signals into an always-on or differently-powered domain, isolation cells are mandatory.

**CPU domain → AON domain crossings:**

```
Signal category                Example signals          Clamp value   Justification
─────────────────────────────────────────────────────────────────────────────────────
PMU status/interrupt           CPU_IDLE, CPU_WFI        0 (ISO_AND)   Idle = not requesting;
                                                                       safe to clamp to 0
Interrupt output to GIC        CPU_FIQ, CPU_IRQ         0 (ISO_AND)   No active interrupt
                                                                       when domain off
DMA request outputs            CPU_DMA_REQ[3:0]         0 (ISO_AND)   No DMA pending
AXI address/control            CPU_ARADDR, CPU_AWADDR   0 (ISO_AND)   No transactions
AXI valid signals              ARVALID, AWVALID, WVALID 0 (ISO_AND)   No active transfers
AMBA coherency                 CPU_SNOOP_REQ            0 (ISO_AND)   No snoops from off domain
```

All CPU domain outputs to AON are clamped to 0. This is safe because:
- A 0 on a control signal means "idle" or "no request" in AXI/AMBA.
- Clamping to 0 prevents spurious transactions or interrupts being generated when the CPU powers up and has undefined state.

**GPU domain → AON domain crossings:**

```
Signal                         Clamp value   Notes
─────────────────────────────────────────────────────────────
GPU_AXI_ARVALID, AWVALID, WVALID  0         No outstanding transactions
GPU_IRQ                           0         No pending interrupt
GPU_PERF_COUNTER[31:0]            0         Performance data invalid
```

**Level shifter requirements:**

Level shifters are required wherever two domains operate at different voltages and both are powered on.

```
Crossing                  Direction   Voltage shift      LS type required
────────────────────────────────────────────────────────────────────────────
CPU (0.55–1.05V) → AON (0.75V)  Either    Could be H→L or L→H  Bidirectional LS
GPU (0.45–0.95V) → AON (0.75V)  Either    Could be H→L or L→H  Bidirectional LS
MODEM (0.80V) → AON (0.75V)     Either    Close voltages        Rail-tolerant or LS
ISP → AON                       Either    H→L possible          Standard LS
```

**Critical note on LS placement:**

The isolation cell must be placed *before* the level shifter (closer to the source domain). If the domain is off and no isolation cell is present, the level shifter sees a floating input — it draws crowbar current and may latch unpredictably.

```
CPU domain (off) ──► [ISO_AND, clamp=0] ──► [Level Shifter] ──► AON domain
                     In AON power domain    In AON power domain
```

Both the isolation cell and level shifter are placed in the AON (receiving) domain so they remain powered when the CPU domain is off.

---

### Step 3: CPU Cluster Power-Up and Power-Down Sequencing

**Power-down sequence (CPU cluster entering deep sleep):**

```
T=0    OS/firmware requests CPU_OFF via PSCI SMC call
T=1    ATF Secure Monitor takes over (EL3)
T=2    ATF saves architectural CPU state to Secure DRAM (if retention not used)
T=3    ATF programs PMU: assert CPU_ISO_EN[3:0] = 1 (enable isolation)
         → All CPU outputs to AON are now clamped to 0
T=4    ATF programs PMU: CPU_CLK_EN = 0 (gate CPU PLL output)
         → Wait 5 cycles for clock to propagate through tree
T=5    PMU de-asserts CPU_PLL_EN → PLL powers down
T=6    PMU triggers CPU retention save (SAVE pulse to retention FFs, if using retention)
         → All CPU architectural state saved to shadow latches in PD_AON voltage island
T=7    PMU opens CPU power switch: CPU_PWR_SW_EN = 0
         → VDD_CPU ramps down; MTCMOS header transistors turn off
T=8    VDD_CPU reaches 0 V (power good de-asserted by PMIC)
T=9    PMU logs power state: CPU = OFF
         Total time: ~15 μs (dominated by PLL powerdown and VDD ramp)
```

**Power-up sequence (CPU cluster waking from deep sleep):**

```
T=0    PMU receives wakeup event (timer, interrupt from modem)
T=1    PMU closes CPU power switch: CPU_PWR_SW_EN = 1
         → VDD_CPU ramps up from 0 to nominal (e.g., 0.75 V for boot OPP)
T=2    VDD_CPU_PGOOD asserts (PMIC power good signal to PMU)
         Typical ramp time: 20–50 μs at 10 mV/μs PMIC slew rate
T=3    PMU asserts CPU_PLL_EN → PLL starts, waits for lock
         PLL lock time: 50–100 μs
T=4    PMU enables CPU clocks: CPU_CLK_EN = 1
T=5    PMU triggers CPU retention restore (RESTORE pulse)
         → Shadow latch state copied back to main flip-flops
T=6    PMU de-asserts CPU isolation: CPU_ISO_EN = 0
         → CPU outputs to AON are now driven by CPU core logic
T=7    ATF releases CPU from reset; PSCI resumes execution context
         Total time: ~100–200 μs (dominated by PLL lock)
```

**Ordering constraints and rationale:**

| Constraint | Violation consequence |
|---|---|
| VDD stable before PLL enable | PLL with unstable supply produces incorrect frequency; CPU fetches from wrong address |
| PLL locked before clock enable | Clock frequency overshoots during lock; setup violations cause silent data corruption |
| Clock stable before isolation release | If isolation releases while clock is transitioning, metastable capture in receiving domain |
| Isolation enabled before power switch opens | Without isolation, floating CPU outputs drive AON logic with undefined values |

---

### Step 4: Leakage Budget Allocation for Deep Sleep

**Target:** 300 μA from 3.8 V battery = 1.14 mW total SoC leakage.

In deep sleep: CPU off, GPU off, ISP off, NPU off, Display off, Modem off. Active: PD_AON, PD_MEM_CTRL (retention), PD_PERIPH (clock gated, limited active).

**Process assumption:** 7 nm FinFET, 25°C junction temperature.

Typical leakage figures for 7 nm:
- Standard cell leakage: ~0.05 nA/gate at nominal Vt, scales with area
- High-Vt (retention) standard cell: ~0.005 nA/gate (10x reduction)
- SRAM leakage: ~1–5 nA/bit at minimum retention voltage (0.5 V)

**Budget allocation:**

```
Domain                   State        Cells/Size           Leakage    Budget
──────────────────────────────────────────────────────────────────────────────
PD_AON                   Active       ~50k std cells       40 μA      50 μA
                                      (PMU, RTC, boot)
                                      
PD_MEM_CTRL              Retention    ~200k std cells      30 μA      50 μA
                                      (low-Vt → high-Vt   
                                      swap in retention)
                                      
L3 cache SRAM            Retention    4 MB SRAM            80 μA      90 μA
(in MEM_CTRL domain)                  @ 0.55V retention
                                      
CPU retention latches    On (AON)     32k shadow FFs       10 μA      15 μA
(in PD_AON)                           (high-Vt cells)
                                      
DRAM (LPDDR5)            Self-refresh External device      60 μA      80 μA
(off-chip, for reference)
                                      
PD_PERIPH clock-gated    Idle         ~100k std cells      15 μA      25 μA
                                      (GPIO, RTC periph)
                                      
Miscellaneous (power      ─            Level shifters,      15 μA      15 μA  
switches, isolation cells)             isolation cells
                                      
Margin                    ─            ─                    ─          25 μA (8%)
──────────────────────────────────────────────────────────────────────────────
TOTAL (on-SoC only)                                        250 μA     350 μA
```

The on-chip leakage budget is 250 μA, leaving 50 μA for PMIC quiescent current and voltage regulators (not shown in SoC budget).

**Why the L3 SRAM dominates:**

4 MB = 33.5 Mbit. At 5 nA/bit in full-power retention: 167 mA — far exceeding the budget. Therefore:

1. L3 SRAM must use a purpose-designed retention supply (0.5 V, not 0.75 V). At 0.5 V, leakage drops to ~2 nA/bit.
2. At 2 nA/bit × 33.5 Mbit = 67 mA — still too high. The solution: **partial L3 flush**. Before entering deep sleep, flush and power off most of the L3 cache. Retain only the smallest viable portion (e.g., 256 KB for OS kernel hot data). 256 KB = 2 Mbit × 2 nA/bit = 4 mA... still high.
3. For true deep sleep, the L3 SRAM is **fully powered off**. Contents are flushed to DRAM before sleep. Wake-up requires L3 refill, which increases wake latency by ~500 μs. This is acceptable for deep sleep scenarios.

Revised budget with L3 fully off: 250 μA → 170 μA (below the 300 μA target with comfortable margin).

---

### Step 5: Display Domain Isolation During CPU/GPU/ISP/NPU Off

The display domain must remain active to drive an ongoing display refresh (e.g., ambient display, clock face) while all other major compute domains are off.

**Input signals to the Display Controller from powered-off domains:**

```
Signal                     Source domain   Direction   Required by display?
────────────────────────────────────────────────────────────────────────────
AXI frame buffer addr      CPU/DMA         → Display   Yes (frame buffer DMA)
AXI read data              MEM_CTRL        → Display   Yes (pixel data)
ISP processed frame ptr    ISP             → Display   No (camera off in this scenario)
NPU overlay frame ptr      NPU             → Display   No (NPU off)
CPU display config regs    CPU (via APB)   → Display   No (pre-programmed before sleep)
Interrupt (display to CPU) Display         → CPU       No (CPU off, interrupt pended)
```

**Isolation strategy for each category:**

**AXI DMA from CPU:** Before CPU enters sleep, the display controller DMA must be configured with a self-refreshing buffer arrangement. Two options:

1. **Dedicated display buffer in PD_AON-accessible SRAM:** A small frame buffer (compressed, e.g., 512 KB for a 1/4-resolution ambient display) in SRAM within a low-power domain that remains active. The display controller reads from this buffer without CPU involvement.

2. **DRAM self-refresh with memory controller retained:** If the full-resolution frame buffer is in DRAM, the memory controller remains in retention mode (not full power off), and the display DMA continues reading from DRAM. This is the common implementation for OLED ambient display.

**ISP frame pointer signals:** These cross from PD_ISP (which is off) into PD_DISPLAY. Isolation cells (ISO_AND, clamp=0) are inserted at every ISP→Display signal crossing. The clamp value of 0 means "no new frame available from ISP" — the display controller is pre-programmed to use a static buffer address when ISP frame pointers are clamped off.

**APB configuration registers:** The display controller must be programmed with all required parameters (frame buffer address, resolution, pixel format, refresh rate) *before* the CPU domain powers off. After power-off, the ISO cells clamp the APB data/address/valid signals to 0. The display controller must implement internal register retention so its configuration survives even if the APB port is isolated.

**Interrupt signals (display → CPU):** The display controller may generate vsync interrupts. With the CPU domain off, these interrupts must be:
1. Masked in the GIC before CPU powers off (so they do not prevent power-down).
2. Maintained as pending in the GIC (which is in PD_AON), so they are serviced immediately when the CPU wakes.
3. The display → GIC path does NOT cross through a powered-off domain, so no isolation is needed here (GIC is in AON, display sends directly to GIC).

**Complete isolation cell inventory for Display domain:**

```
Signal group                     Count   Cell type    Clamp    Control signal
─────────────────────────────────────────────────────────────────────────────
ISP → Display frame data         64      ISO_AND      0        ISP_ISO_EN
ISP → Display config valid        1      ISO_AND      0        ISP_ISO_EN
NPU → Display overlay addr       32      ISO_AND      0        NPU_ISO_EN
NPU → Display overlay valid       1      ISO_AND      0        NPU_ISO_EN
CPU → Display APB data           32      ISO_AND      0        CPU_ISO_EN
CPU → Display APB addr           12      ISO_AND      0        CPU_ISO_EN
CPU → Display APB write           1      ISO_AND      0        CPU_ISO_EN
CPU → Display APB select          1      ISO_AND      0        CPU_ISO_EN
─────────────────────────────────────────────────────────────────────────────
Total                            144
```

Level shifters are required on all paths where VDD_MAIN (0.55–1.05 V, variable) crosses to VDD_DISPLAY (0.55–0.85 V, variable). Because both rails use VDD_MAIN and their ranges overlap, the level shifters must be bidirectional and rail-tolerant (support input higher than output and vice versa). Most standard cell libraries provide an "any-to-any" level shifter cell for this purpose.

---

## Summary Table

| Parameter | Value |
|---|---|
| Number of power domains | 9 (including PD_AON) |
| Domains with DVFS | PD_CPU, PD_GPU, PD_ISP, PD_NPU, PD_DISPLAY |
| Domains with full power gating | PD_CPU, PD_GPU, PD_ISP, PD_NPU, PD_MODEM, PD_PERIPH |
| Domains with retention only | PD_MEM_CTRL |
| Total isolation cells (approximate) | ~800–1200 across all boundaries |
| CPU power-down time | ~15 μs |
| CPU power-up time | ~100–200 μs |
| Deep sleep SoC leakage | ~170 μA (L3 cache fully off) |
| Display isolation cells | 144 |

## Key Takeaways

1. **Voltage domain granularity is determined by independent DVFS requirements.** Blocks that share an OPP curve share a supply rail; blocks with divergent performance/power tradeoffs benefit from independent supplies.

2. **Isolation cells must be placed in the always-on domain**, not the power-gated domain. They must be powered when the source domain is off.

3. **Power sequencing order is critical and asymmetric.** Power-down: isolate → stop clock → power off. Power-up: power on → start clock → release isolation. Reversing any step risks data corruption or crowbar current.

4. **SRAM leakage dominates deep sleep power on advanced nodes.** Cache flush and retention supply voltage reduction are essential techniques — not optional optimisations.

5. **Always-on domain complexity grows with per-domain granularity.** Each additional power domain adds isolation cells, level shifters, power switch control, and sequencing logic to the AON domain. Excessive domain count increases AON area and complexity.
