# Power Management and Clock Gating

## Overview

Power management is one of the most consequential areas of modern SoC architecture. Mobile SoCs must balance peak performance against a battery budget measured in milliwatt-hours; server SoCs must stay within a thermal design point while sustaining throughput across hundreds of cores. Poor power architecture decisions made early in a project are expensive to reverse — power domains, isolation strategies, and clock gating topologies shape the entire physical design flow.

This document covers the full stack: from individual clock gating cells through multi-voltage power domains, dynamic voltage and frequency scaling (DVFS), and full-chip power state machines. All techniques described here are in production use at companies including Arm, Apple, Qualcomm, Intel, and AMD.

---

## Tier 1: Fundamentals

### Q1. What is clock gating, and why is it the first technique applied to reduce dynamic power?

**Answer:**

Dynamic power in a CMOS circuit is:

$$P_{dynamic} = \alpha \cdot C \cdot V_{DD}^2 \cdot f$$

where $\alpha$ is the activity factor (fraction of clock cycles in which a node switches), $C$ is the switched capacitance, $V_{DD}$ is the supply voltage, and $f$ is the clock frequency.

Clock gating directly sets $\alpha = 0$ for an entire register or functional block when that block is idle — the clock signal is suppressed so the flip-flops stop switching entirely. Because the clock network typically accounts for 20–40% of a chip's total dynamic power, even modest clock gating coverage produces large power savings.

Clock gating is applied first because:

1. It requires no supply voltage change — no level shifters, no isolation cells, no power switches.
2. It is transparent to the functional design if implemented correctly — the gated block retains its state.
3. Tools (synthesis, place-and-route) handle clock gating cells automatically with minimal design effort.
4. The power saving is immediate: a fully idle block dissipates essentially no dynamic power.

**Implementation — ICG (Integrated Clock Gating) cell:**

A standard clock gating cell comprises a latch followed by an AND gate:

```
                   ┌────────┐
 ENABLE ──────────►│        │
                   │  LATCH │──► ENABLE_LATCHED ──┐
 CLK ─────────────►│ (negedge)│                    │
                   └────────┘                    AND──► GATED_CLK
 CLK ──────────────────────────────────────────────┘
```

The latch is transparent on the falling edge of CLK. This ensures ENABLE_LATCHED is stable for the entire high phase of CLK, preventing glitches on GATED_CLK. A glitch on the clock is a functional error — it would cause unintended register captures.

**Common mistake:** Gating the clock with a combinational AND gate directly (no latch). This creates a glitch risk whenever ENABLE transitions while CLK is high. Every synthesis tool flags this as a DRC violation.

---

### Q2. What is a power domain, and why would a SoC have multiple power domains?

**Answer:**

A power domain is a region of the chip that shares a common power supply rail. All cells in the domain are powered from the same voltage source and can be independently powered on or off.

Multiple power domains are used for three reasons:

**1. Power gating (complete shutdown):**
A domain that is idle can have its supply switched off entirely. This eliminates both dynamic power (no switching) and static (leakage) power. On a 16 nm process, leakage current can dominate total power in active standby — power gating a dormant video decoder or modem subsystem saves tens of milliwatts.

**2. Multi-voltage operation:**
Different IP blocks have different optimal operating voltages. A high-performance CPU core may run at 0.9 V for maximum speed; a SRAM compiler typically requires a minimum voltage for reliable read/write; a digital baseband might run at 0.6 V at low datarates. Separate power domains allow each block to operate at its required voltage.

**3. Fine-grained DVFS:**
Independent power domains allow different blocks to scale voltage and frequency independently. The GPU domain can reduce to 0.5 V / 500 MHz while the CPU domain operates at 0.85 V / 2 GHz, matching supply to workload for each subsystem.

**Typical power domains in a mobile SoC:**

| Domain | Contents | Power-off use case |
|---|---|---|
| Always-on (AON) | PMU, RTC, wakeup logic | Never powered off |
| CPU cluster | Application processor cores | Deep sleep |
| GPU | Graphics processor | No active rendering |
| DSP | Audio/sensor processing | No active audio |
| Modem | Cellular/Wi-Fi | Airplane mode |
| Display | Display controller, DSI | Screen off |
| Memory controller | DDR controller | Retention mode |

---

### Q3. What are isolation cells? Where must they be placed, and what happens if they are missing?

**Answer:**

When a power domain is powered off, all outputs from that domain become undefined — the supply is zero, so internal nodes float to indeterminate voltages. Any cell in an always-on domain that receives a signal from a powered-off domain may see a partial voltage on its input, causing the receiving cell to enter a linear (crowbar) state that draws substantial DC current and may damage the device.

Isolation cells clamp the output of a powered-off domain to a known logic value (typically 0 or 1) before the domain is shut down. They are inserted at every output crossing from a power-gated domain to any always-on or differently-powered domain.

**Standard isolation cell types:**

| Type | Function | Output when domain off |
|---|---|---|
| ISO_AND | AND of data with ENABLE | Logic 0 |
| ISO_OR | OR of data with ENABLE | Logic 1 |
| ISO_BUF | Buffer with high-impedance override | Defined (tool selects) |

```
                    ┌─────────────┐
 DATA (from         │             │
 powered-off   ────►│  ISO_AND    │──► TO_AON_DOMAIN
 domain)            │             │
                    └──────┬──────┘
                           │
 ISOLATE_EN ───────────────┘
 (active high = domain off)
```

When ISOLATE_EN is high (domain powered off), the AND gate output is clamped to 0 regardless of DATA. The receiving cells in the always-on domain see a clean logic 0.

**Consequence of missing isolation cells:**

Without isolation, a CMOS gate in the always-on domain receiving a floating input draws continuous DC current through its PMOS and NMOS transistors simultaneously (crowbar current). This manifests as:

- Abnormally high current draw in standby mode
- Potential latch-up triggering
- Functional corruption of the receiving domain
- Thermal runaway in severe cases

Power management verification tools (UPF-aware simulation, Synopsys MVSIM) flag missing isolation as a critical violation.

---

### Q4. What is a level shifter, and when is one needed?

**Answer:**

A level shifter translates signal levels between two power domains operating at different supply voltages. They are required at every signal crossing where $V_{DD1} \ne V_{DD2}$.

**Why a standard cell cannot do the job:**

A CMOS inverter in domain B (operating at $V_{DD,B} = 0.6\ \text{V}$) receiving a signal from domain A (operating at $V_{DD,A} = 1.0\ \text{V}$) has a logic-high input of 1.0 V applied to a 0.6 V supply cell. The NMOS pull-down transistor turns on strongly while the PMOS pull-up may also be partially on (since $V_{GS,P} = 0.6 - 1.0 = -0.4\ \text{V}$, near threshold). The result is crowbar current, degraded output swing, and possible oxide stress.

**High-to-low level shifter (simple case):**

A simple resistor divider or voltage clamp is insufficient for dynamic signals. A proper level shifter uses a cross-coupled latch topology:

```
VDD_A (1.0V)            VDD_B (0.6V)
   │                        │
  [P1]                    [P2]
   │                        │
   ├──────────────────────►[G of P1]
   │                        │
  [N1]◄─ IN_A             [N2]◄─ IN_A_BAR
   │                        │
  GND                      GND
                            │
                         OUT_B ──► (0 to 0.6V swing)
```

The cross-coupled PMOS latch (P1/P2) ensures full rail-to-rail swing at $V_{DD,B}$.

**Low-to-high level shifter:**

More complex; requires a separate enable or uses a source-follower topology with the higher supply. Many cells use an NMOS pass gate technique combined with a CMOS latch powered by $V_{DD,A}$.

**Placement rule:** Level shifters belong in the domain boundary, after isolation cells (when the source domain is power-gateable). If the source domain is off, the isolation cell must clamp the input to the level shifter to a defined value before the level shifter sees it — a floating level shifter input can draw high current or latch incorrectly.

---

### Q5. What is DVFS? Describe the sequence of steps to scale from high-performance mode to low-power mode.

**Answer:**

Dynamic Voltage and Frequency Scaling (DVFS) adjusts the operating voltage and clock frequency of a power domain at runtime to match the performance requirement of the current workload. Power scales as $P \propto V^2 f$, so operating at half the voltage and half the frequency reduces dynamic power by a factor of approximately eight.

**Sequence for scaling DOWN (high-performance to low-power):**

Frequency must be reduced before voltage, because the timing slack at lower voltage may not accommodate the original frequency.

```
Step 1: Request new operating point (OS/firmware → PMU)

Step 2: Reduce clock frequency
  - PMU programs the PLL to a lower output frequency
  - Or switches to a pre-configured lower-frequency PLL output
  - Wait for PLL lock or clock mux settling (typically 10–100 μs)
  - New frequency is stable and operating point is f_new, V_old

Step 3: Reduce voltage
  - PMU issues voltage request to PMIC (via I2C/SPI/PWM)
  - PMIC ramps VDD down at a controlled slew rate (e.g., 10 mV/μs)
  - PMU monitors voltage through ADC or power-good signal
  - Wait for VDD to settle at V_new

Step 4: Update software performance state (OPP table updated)
```

**Sequence for scaling UP (low-power to high-performance):**

Voltage must be raised before frequency:

```
Step 1: Raise voltage to V_new (higher value)
  - PMU requests PMIC ramp-up
  - Wait for power-good assertion

Step 2: Switch to higher frequency
  - Program PLL for new frequency
  - Wait for PLL lock
  - Enable higher-frequency clock

Step 3: Update OPP state
```

**Why the ordering matters:**

At V_low, the critical path delay is T_critical(V_low). If frequency is increased before voltage rises, the required clock period T_clk = 1/f_new < T_critical(V_low), causing setup time violations and flip-flop metastability. This produces silent data corruption — the chip will appear to function but produce incorrect results.

**Common mistake:** Assuming PLL relock is instantaneous. A PLL typically requires 50–200 μs to acquire the new frequency. During this window, the clock is unstable. The PMU must hold the domain in reset or assert a clock-safe signal, not begin normal operation.

---

## Tier 2: Intermediate

### Q6. Describe the UPF (Unified Power Format) flow for implementing multi-voltage design. What key commands are used?

**Answer:**

UPF (IEEE 1801) is the industry-standard specification language for power intent. It describes power domains, supplies, isolation requirements, level shifting, and power state machines in a separate file that accompanies the RTL. The same UPF file drives synthesis, place-and-route, and simulation, ensuring consistent power intent across all design tools.

**Key UPF commands:**

```tcl
# 1. Create power domains
create_power_domain PD_CPU \
    -elements {cpu_core0 cpu_core1} \
    -scope /top/cpu_cluster

create_power_domain PD_GPU \
    -elements {gpu_core} \
    -scope /top/gpu

create_power_domain PD_AON \
    -include_scope  ;# default domain, always on

# 2. Create supply nets and ports
create_supply_net VDD_CPU -domain PD_CPU
create_supply_net VDD_GPU -domain PD_GPU
create_supply_net VDD_AON -domain PD_AON
create_supply_net VSS

# 3. Connect supply ports to nets
create_supply_port VDD_CPU_PORT -direction in -domain PD_CPU
connect_supply_net VDD_CPU -ports VDD_CPU_PORT

# 4. Assign primary/secondary power to domains
set_domain_supply_net PD_CPU \
    -primary_power_net VDD_CPU \
    -primary_ground_net VSS

# 5. Define power switches (power gating transistors)
create_power_switch SW_CPU \
    -domain PD_CPU \
    -output_supply_port {vout VDD_CPU} \
    -input_supply_port  {vin VDD_MAIN} \
    -control_port       {en CPU_PWR_EN} \
    -on_state           {on_state vin {en}} \
    -off_state          {off_state {!en}}

# 6. Isolation strategy
set_isolation ISO_CPU_OUT \
    -domain PD_CPU \
    -applies_to outputs \
    -clamp_value 0 \
    -isolation_power_net VDD_AON \
    -isolation_ground_net VSS \
    -location parent  ;# insert in the receiving domain

# 7. Level shifting
set_level_shifter LS_CPU_TO_AON \
    -domain PD_CPU \
    -applies_to outputs \
    -rule low_to_high \
    -location parent

# 8. Retention registers
set_retention RET_CPU \
    -domain PD_CPU \
    -save_signal  {PMU_SAVE  posedge} \
    -restore_signal {PMU_RESTORE posedge}

# 9. Power state table
add_power_state PD_CPU \
    -state {ON       {supply_expr {VDD_CPU == FULL}}} \
    -state {OFF      {supply_expr {VDD_CPU == OFF}}} \
    -state {RETENTION {supply_expr {VDD_CPU == RETENTION_V}}}
```

**Tool flow:**

1. **Synthesis (Synopsys DC / Cadence Genus):** Reads RTL + UPF. Inserts ICG cells, isolation cells, level shifters, and retention flip-flops in the netlist.
2. **Equivalence checking (Formality / Conformal):** Verifies the power-aware netlist against RTL with UPF.
3. **Place-and-route (ICC2 / Innovus):** Reads netlist + UPF. Places power switches, routes power domains with separate power grids, inserts well-ties, checks domain boundary crossings.
4. **Power-aware simulation (VCS + MVSIM / Xcelium):** Simulates power up/down sequences, checks for missing isolation, undefined values on domain boundaries.

---

### Q7. What are retention flip-flops and when are they used instead of full power gating?

**Answer:**

A retention flip-flop (also called a shadow flip-flop or balloon flip-flop) is a special cell that contains both a primary storage element (in the main power domain) and a shadow storage element (in an always-on or retention power domain). The shadow latch uses a much smaller, low-leakage supply voltage sufficient only to maintain state.

**Internal structure:**

```
 CLK  ──────────────────────────────────────────────────┐
                                                         │
 D ──►[MAIN FF (VDD_MAIN)]──► Q                         │
           │                                            ┌▼┐
           │ SAVE pulse                                 │ │ Shadow
           └─────────────────►[SHADOW LATCH (VDD_RET)]  │ │ latch
                                        │               └┬┘
                                        │ RESTORE        │
                                        └────────────────► Q (restored)
```

During normal operation, only the main flip-flop switches; the shadow latch is idle. When the PMU initiates a power-down sequence:

1. **SAVE:** A PMU-generated pulse copies the main FF state to the shadow latch.
2. **Domain power off:** $V_{DD,MAIN}$ is removed. The main FF loses its state. The shadow latch, on $V_{DD,RET}$ (typically 0.5–0.7 V), retains the value.
3. **Domain power on:** $V_{DD,MAIN}$ ramps up. Once stable, a RESTORE pulse copies the shadow latch value back to the main FF.
4. Normal operation resumes with state preserved.

**Retention voltage selection:**

$V_{DD,RET}$ must be high enough to maintain SRAM/latch state against leakage currents. Typical values are 0.5–0.65 V on 16 nm FinFET. The retention power is dominated by leakage of the shadow latches — typically 10–100x lower than full-power leakage.

**When to use retention vs. full power gating:**

| Criterion | Use Retention | Use Full Power Gate |
|---|---|---|
| Wake-up latency requirement | < 1 μs (state must be immediately available) | Can tolerate 10–100 μs restore + re-init |
| State size | Large (many FFs that would take long to reload from memory) | Small or re-initialised from memory |
| Idle duration | Short to medium (μs to ms) | Long (ms to seconds) |
| Leakage reduction requirement | Moderate (60–80% reduction) | Maximum (>99% reduction) |
| Examples | CPU L1 cache tags, GIC state | DSP subsystem, video codec |

**Common mistake:** Using retention flip-flops for a block that also has embedded SRAM. The SRAM requires a separate retention strategy (SRAM compilers provide a retention mode with a dedicated supply pin); retention flip-flops do not protect SRAM arrays.

---

### Q8. Explain power state machines in a SoC. What is the PSCI standard and how does it interact with the PMU hardware?

**Answer:**

A SoC power state machine defines the legal power states of the system (or individual subsystem), the transitions between states, and the sequencing constraints governing those transitions. It is a hierarchical structure: chip-level states decompose into per-cluster and per-core states.

**Arm PSCI (Power State Coordination Interface):**

PSCI is the Arm specification (DEN0022) for a software interface between the OS/hypervisor and the firmware responsible for power management. It defines a set of SMC (Secure Monitor Call) functions that the OS calls to request power state changes:

| PSCI Function | Operation |
|---|---|
| `CPU_SUSPEND` | Place a CPU into a low-power idle state |
| `CPU_OFF` | Power down a CPU core permanently (until `CPU_ON`) |
| `CPU_ON` | Power on a CPU core and start it at a specified address |
| `SYSTEM_SUSPEND` | Suspend the entire system (DRAM self-refresh, all cores off) |
| `SYSTEM_RESET` | Warm reset |

**Hardware interaction flow:**

```
Linux kernel (cpuidle framework)
        │
        │ PSCI SMC call (e.g., CPU_SUSPEND with power state = CLUSTER_OFF)
        ▼
EL3 Secure Monitor (ATF - Arm Trusted Firmware)
        │
        │ 1. Validates power state request
        │ 2. Saves CPU architectural state (if required by power level)
        │ 3. Programs PMU registers via memory-mapped I/O
        ▼
PMU Hardware block (always-on domain)
        │
        │ 4. Issues power-down sequence:
        │    a. Assert isolation enables for CPU cluster domain
        │    b. Disable CPU PLLs and clock trees
        │    c. Trigger power switch off (MTCMOS header/footer)
        │    d. Release DRAM from self-refresh if only some cores off
        ▼
Power domain transitions complete
```

**Wake-up path:**

A wakeup interrupt (timer, GPIO, GIC) asserts a signal to the PMU. The PMU:
1. Powers up the domain (sequence is the reverse: power switch on → clock enable → isolation release)
2. Triggers a reset vector entry or restores CPU state
3. ATF returns control to the kernel

**Power state hierarchy example (Arm big.LITTLE SoC):**

```
SYSTEM
├── CLUSTER_0 (big cores, A76)
│   ├── CPU_0
│   ├── CPU_1
│   └── L2 cache (shared, powers off when both CPUs off)
├── CLUSTER_1 (LITTLE cores, A55)
│   ├── CPU_2
│   ├── CPU_3
│   └── L2 cache
└── SYSTEM_CACHE (L3, DSU)
```

The cluster L2 can only power off when all CPUs in the cluster have entered CPU_OFF. The L3 can only power off when all clusters are off. These ordering constraints are enforced by the PMU state machine hardware.

---

### Q9. What is a power mesh and how is it designed for a multi-voltage SoC?

**Answer:**

The power mesh is the on-chip distribution network of metal stripes that delivers supply voltage from package bumps (or bond wire pads) to every standard cell and macro in the design. A multi-voltage SoC has separate, electrically isolated meshes for each supply.

**Design objectives:**

1. **IR drop:** The resistive voltage drop from the package bump to the cell must be less than 2–5% of $V_{DD}$ (tool-specific constraint, typically 20–50 mV at full operating voltage). Excessive IR drop shifts the effective supply voltage, reducing timing slack and potentially causing functional failures.

2. **Electromigration (EM):** Current density in metal stripes must remain below the process EM limit (typically 1–5 mA/μm for M1, higher for upper metals). Violations reduce long-term reliability.

3. **Decoupling capacitance:** Parasitic capacitance from $V_{DD}$ to $V_{SS}$ stripes provides charge reservoirs for transient current demand. Dedicated decap cells supplement the parasitic capacitance.

**Mesh structure (typical):**

```
M9 (top metal, coarse pitch):   ════════════════  VDD_AON horizontal
M8:                              |||||||||||||||   VSS  vertical
M7:                              ════════════════  VDD_CPU horizontal
M6:                              |||||||||||||||   VSS  vertical
...
M3-M5: Standard cell power rails (fine pitch, per-domain)
M1-M2: Standard cell local routing
```

**Multi-voltage domain boundary in the mesh:**

Domain boundaries require a physical gap between adjacent domain meshes. The gap prevents accidental shorting of VDD_CPU to VDD_GPU. Level shifter cells and isolation cells bridge the signal crossings at these boundaries; they have power connections to both domains.

**Power switch placement:**

MTCMOS (Multi-Threshold CMOS) power switches are header (PMOS) or footer (NMOS) transistors inserted in the power distribution between the always-on supply rail (VDD_MAIN) and the switchable domain rail (VDD_SW). They are typically distributed across the domain (not placed at the periphery) to avoid localised IR drop hot spots.

```
VDD_MAIN ────[PMOS header switches, distributed]──── VDD_SW ──► domain cells
```

The switches are sized to limit the IR drop across them to <10 mV at peak current. The number and width of switches are determined by the domain's peak current demand and the process $R_{on}$ per unit width.

---

## Tier 3: Advanced

### Q10. A mobile SoC is in standby with all application cores off but the modem active. The system exhibits unexpectedly high standby current (5 mA measured at the battery vs 1 mA expected). Describe your systematic debug approach.

**Answer:**

Unexpectedly high standby current has several possible root causes. The debugging approach isolates each power rail sequentially, then isolates within the offending domain.

**Step 1 — Identify which supply rail is consuming excess current.**

Use a bench power supply with current logging or a dedicated power analyser (e.g., Monsoon Solutions Power Monitor) to measure current on each supply rail independently. The SoC typically has separate pins for:
- VDD_CPU (should be 0 in core-off state)
- VDD_GPU (should be 0 if GPU is off)
- VDD_MODEM (should be 30–80 mA if actively processing, or ~3 mA in idle)
- VDD_AON (should be ~200–500 μA)
- VDD_MEM (DDR in self-refresh, ~1 mA)

If VDD_CPU is drawing 3 mA when it should be 0, the CPU power domain has not fully gated off.

**Step 2 — Check power switch state.**

Read the PMU register file. Each power domain has a status register reflecting whether the power switch is open or closed. If the register shows the CPU domain power switch is open but current is still flowing, suspect:
- A PMU register write that did not complete (AHB bus hang)
- A stuck power switch (MTCMOS transistor in linear region due to gate voltage leakage)
- Current leaking through a level shifter or isolation cell whose control signal is incorrect

**Step 3 — Check isolation cell control signals.**

If isolation cells are not asserting when the domain powers off, the data path from the powered-off domain drives logic in an active domain, creating crowbar current. Use a logic analyser or JTAG-based register scan to verify isolation enable signals.

```
Expected during CPU domain off:
  CPU_ISO_EN = 1  (isolation enabled, outputs clamped)
  CPU_CLK_EN = 0  (clocks disabled)
  CPU_PWR_SW_EN = 0 (power switch open)
```

**Step 4 — Check for wake-up source holding domain active.**

An unmasked interrupt or a PMU wakeup source (GPIO, timer) may be continuously waking the CPU before it reaches the low-power state. Check the wakeup interrupt pending register. A common bug is a peripheral (e.g., a UART in loopback mode) generating continuous interrupts that prevent the CPU from reaching C-state.

**Step 5 — Check SRAM retention state.**

SRAM in retention mode draws leakage. If SRAM retention voltage is higher than specified (PMIC output regulation error), or if more SRAM banks are held in retention than necessary, leakage increases. Read the PMIC voltage output on VDD_RET and compare to the target.

**Step 6 — Thermal effects.**

Elevated junction temperature increases leakage exponentially ($I_{leak} \propto e^{T/T_0}$). If the modem is dissipating more heat than expected, the AON domain temperature rises, increasing its leakage. Measure die temperature via the thermal sensor registers.

**Root-cause summary matrix:**

| Symptom | Likely cause |
|---|---|
| VDD_CPU current > 0 with cores off | Power switch not opening, PMU sequencing bug |
| All rails elevated uniformly | SRAM retention voltage too high, elevated temperature |
| VDD_AON current elevated | Crowbar from missing isolation, continuous wakeup interrupt |
| Intermittent current spikes | CPU waking/sleeping rapidly (interrupt storm) |

---

### Q11. Describe the design of a clock gating cell for a 64-bit accumulator with enable, and explain how activity-based power analysis is performed during RTL development.

**Answer:**

**Clock gating insertion for a 64-bit accumulator:**

```systemverilog
// RTL before clock gating (tool infers ICG from this pattern)
module accumulator_64 (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        acc_en,     // accumulate enable
    input  logic [63:0] data_in,
    output logic [63:0] acc_out
);

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)
        acc_out <= '0;
    else if (acc_en)
        acc_out <= acc_out + data_in;
    // No else: retains value when acc_en = 0
    // This pattern DIRECTLY maps to an ICG cell
end

endmodule
```

The synthesis tool recognises the `if (acc_en)` pattern with no else-branch as a clock gating opportunity. It inserts an ICG cell:

```
 acc_en ──────────────► [LATCH]──►[AND]──► gated_clk ──► 64-bit register clock
 clk ──────────────────────────────[AND]
 clk (to latch) ──────► [LATCH negedge]
```

**Manual ICG instantiation (when tool inference fails):**

```systemverilog
// Instantiate ICG cell explicitly
CLKGATETST_X4 u_icg_acc (
    .CLK  (clk),
    .EN   (acc_en),
    .TE   (scan_test_en),   // test enable overrides gate during scan
    .GCLK (gclk_acc)        // gated clock output
);

always_ff @(posedge gclk_acc or negedge rst_n) begin
    if (!rst_n)
        acc_out <= '0;
    else
        acc_out <= acc_out + data_in;
end
```

The `TE` (test enable) pin is mandatory — during scan test, all clocks must be ungated so shift operations can clock through every register.

**Activity-based power analysis at RTL:**

RTL power analysis uses switching activity annotation to estimate power before synthesis. The flow:

**1. Generate switching activity file (VCD or SAIF):**

```bash
# Run RTL simulation with representative workload
vcs -sverilog accumulator_tb.sv accumulator_64.sv \
    +define+DUMP_VCD \
    -o sim_out

./sim_out +vcd_file=activity.vcd

# Convert VCD to SAIF (Switching Activity Interchange Format)
vcd2saif -input activity.vcd -output activity.saif
```

**2. RTL power estimation (Synopsys Power Compiler or Cadence Joules):**

```tcl
# In Power Compiler
read_verilog accumulator_64.sv
read_saif activity.saif -strip_path /tb/dut
set_wire_load_model -name "medium_wire_load"

compile_ultra  ;# synthesise with the activity file loaded

report_power -hier > power_report.txt
```

**3. Interpreting the report:**

```
Instance      Cell     Int Power  Switch Power  Leak Power  Total Power
-----------   ------   ---------  ------------  ----------  -----------
accumulator   -        0.00 mW    0.00 mW       0.01 mW     0.01 mW
  reg_acc[63:0] DFF_X2  0.05 mW  0.12 mW       0.08 mW     0.25 mW
  add_tree      ADD_X4  0.02 mW   0.08 mW       0.01 mW     0.11 mW
  u_icg_acc    ICG_X4  0.00 mW   0.01 mW       0.00 mW     0.01 mW

Clock gating effectiveness:
  Registers without gating: 0.25 mW (accum activity = 15%)
  Registers with gating:    0.05 mW (clock switched 15% of cycles)
  Saving: 80%
```

The tool computes `Switch Power = alpha * C * V^2 * f` using the activity factor derived from the SAIF file and the estimated capacitance from the wire load model.

**Key metric — toggle rate:** The SAIF-annotated toggle rate for the acc_out register should be approximately `2 * acc_en_activity * f`. If the toggle rate is unexpectedly high (close to 2f), the accumulator is incrementing nearly every cycle — the clock gating saves little. If toggle rate is near zero despite acc_en being high, check for data-identical inputs that suppress switching.

---

## Quick Reference: Key Terms

| Term | Definition |
|---|---|
| Dynamic power | $P = \alpha C V^2 f$; power from charging/discharging capacitances each clock cycle |
| Static (leakage) power | Sub-threshold and gate-oxide leakage; present regardless of switching activity |
| ICG cell | Integrated Clock Gate; latch + AND gate that suppresses clock transitions to idle registers |
| Power domain | Region sharing a common power supply; can be independently power-gated |
| Isolation cell | Clamps outputs of a powered-off domain to a defined logic value to prevent crowbar current |
| Level shifter | Translates signal swing between two voltage domains |
| Power switch (MTCMOS) | PMOS header or NMOS footer transistor that disconnects a domain from its supply |
| DVFS | Dynamic Voltage and Frequency Scaling; adjusts $V_{DD}$ and $f$ at runtime to match workload |
| Retention flip-flop | FF with a shadow latch in an always-on domain; preserves state across power gating |
| UPF | Unified Power Format (IEEE 1801); Tcl-based specification language for multi-voltage design intent |
| PSCI | Power State Coordination Interface (Arm DEN0022); API between OS and firmware for power states |
| IR drop | Resistive voltage drop in the power mesh; $\Delta V = I \cdot R_{mesh}$ |
| OPP | Operating Performance Point; a (voltage, frequency) pair in the DVFS table |
| Power state machine | Hardware FSM in the PMU controlling valid power state transitions and sequencing |
