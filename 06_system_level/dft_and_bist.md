# DFT and BIST

## Overview

Design for Testability (DFT) is the set of design techniques that make a manufactured chip testable at low cost with high fault coverage. Without DFT, internal nodes of a chip are inaccessible to external test equipment — the only observable outputs are package pins. With DFT, test engineers can shift known patterns through every flip-flop in the design, sensitise paths to specific faults, and verify that manufactured devices match their specification.

This document covers scan chain architecture, Automatic Test Pattern Generation (ATPG), memory Built-In Self-Test (BIST), boundary scan (JTAG), and fault coverage metrics. These topics appear consistently in SoC integration, physical design, and verification engineering interviews at major semiconductor companies.

---

## Tier 1: Fundamentals

### Q1. What is a scan chain and how does it make internal flip-flops testable?

**Answer:**

A scan chain converts all flip-flops in a design into a long serial shift register by adding a multiplexer at the input of each flip-flop. In normal (functional) mode, the FF captures its design-specified data input. In scan (test) mode, every FF captures the output of the preceding FF in the scan chain — the entire chain shifts like a LFSR or shift register.

**Scan flip-flop structure:**

```
 SI (scan in) ──────┐
                    │  ┌──────────────────────────────────────┐
 D (functional) ──►[MUX]──► D         FF              Q ──► SO (scan out)
                    │        │                         │
 SE (scan enable) ──┘        │    ┌────────────────────┘
                             │    │
 CLK ────────────────────────┘    └──► Q (functional output)
```

When SE (scan enable) = 1: the FF captures `SI` (shifts the scan chain).
When SE (scan enable) = 0: the FF captures `D` (functional operation).

**Test procedure (shift-capture-shift):**

```
Cycle 1 (SHIFT): SE = 1, CLK toggles N times (N = chain length)
  → Shift a known test pattern into all flip-flops via the chain
  
Cycle 2 (CAPTURE): SE = 0, apply functional clocks for 1–2 cycles
  → The circuit computes based on the loaded state; responses are captured
    into the flip-flops by the functional clock
  
Cycle 3 (SHIFT OUT): SE = 1, CLK toggles N times
  → Shift the captured response out through SO while shifting the
    next test pattern in simultaneously
  
Cycle 4: Compare shifted-out data with expected (fault-free) response
```

This scheme means test time is proportional to (number of patterns × chain length), not (patterns × total flip-flop count) — a crucial efficiency gain.

**Why scan is universally adopted:**

Without scan, testing a 10 million flip-flop design would require finding input sequences at the package pins that sensitise internal nodes — an NP-hard combinatorial problem with no practical solution. With scan, ATPG tools can observe and control any FF directly.

---

### Q2. What is stuck-at fault modelling? Why is it the standard fault model for digital logic?

**Answer:**

A stuck-at fault models a physical defect (short circuit, open circuit, contamination) as a net that is permanently at logic 0 (stuck-at-0, SA0) or logic 1 (stuck-at-1, SA1), regardless of the correct logic value that should appear on that net.

**Example:**

```
          A ──┐
              AND ──► Y
          B ──┘

Net A has a SA0 fault (stuck at 0).

Normal operation: A=1, B=1 → Y=1
With SA0 fault on A: A sees 0 (fault), B=1 → Y=0 (incorrect)

Test vector: apply A=1, B=1; observe Y
  - Fault-free: Y=1
  - SA0 fault present: Y=0
→ This vector detects the SA0 fault on A.
```

**Why stuck-at is the standard model:**

1. **Tractable:** The number of stuck-at faults in a gate-level netlist is bounded (2 faults per net: SA0 and SA1). A 1M-gate design has ~4–8M stuck-at fault sites. This is manageable for ATPG.

2. **Good physical correlation:** Oxide shorts, interconnect shorts to power/ground, and opens in driving transistors all create stuck-at-like behaviour. Historical data shows 85–95% of manufacturing defects are detected by good stuck-at coverage.

3. **Tool maturity:** 40 years of ATPG development has made SA coverage highly efficient. State-of-the-art tools achieve 98–99.9% SA fault coverage with very compact pattern sets.

**Limitations:**

Stuck-at does not model all defect types:
- **Transition faults (slow path faults):** A net that can switch but not fast enough for the timing constraint. Stuck-at patterns may not sensitise the slow paths at speed.
- **Bridging faults:** Two nets shorted together. The combined behaviour depends on the driving strength of both drivers, not simply stuck-at one value.
- **Cell-internal defects:** Transistor degradation within a cell's pre-characterised abstraction.

Production DFT uses stuck-at in conjunction with transition delay and path delay fault models to achieve comprehensive defect coverage.

---

### Q3. What is JTAG and what does the IEEE 1149.1 standard specify?

**Answer:**

JTAG (Joint Test Action Group) is the industry-standard interface for in-system testing, debugging, and programming of integrated circuits. The IEEE 1149.1 standard defines:

**The four (mandatory) JTAG signals:**

| Pin | Direction | Function |
|---|---|---|
| TCK | Input | Test Clock; shifts data on rising edge |
| TMS | Input | Test Mode Select; controls TAP state machine |
| TDI | Input | Test Data In; serial data shifted into device |
| TDO | Output | Test Data Out; serial data shifted out |
| TRST# | Input (optional) | Asynchronous TAP controller reset |

**TAP (Test Access Port) State Machine:**

The TAP is a 16-state FSM driven by TMS and TCK. Key states:

```
Test-Logic-Reset
      │ TMS=0
      ▼
  Run-Test/Idle
      │ TMS=1
      ▼
  Select-DR-Scan ──TMS=1──► Select-IR-Scan
      │ TMS=0                     │ TMS=0
      ▼                           ▼
  Capture-DR                 Capture-IR
      │                           │
  Shift-DR                   Shift-IR  ◄── shifts new instruction
      │                           │
  Update-DR                  Update-IR ◄── latches instruction to IR
```

**Instruction Register (IR) and Data Registers (DR):**

The IR holds the current instruction. Standard mandatory instructions:
- `BYPASS` (all 1s): shortest path through the device (1-bit bypass register)
- `SAMPLE/PRELOAD`: samples/drives boundary scan cells without affecting function
- `EXTEST`: enables external test; drives boundary scan cells onto pins

Optional but common:
- `IDCODE`: shifts out a 32-bit device identification code
- `INTEST`: internal test using scan chains
- `RUNBIST`: triggers an internal BIST operation

**Boundary Scan Register:**

The boundary scan register is a chain of cells placed at every I/O pin. Each cell can:
1. Observe the pin value during normal function (SAMPLE)
2. Force a specific value onto the pin independent of the core logic (EXTEST)
3. Capture the value driven by the core and shift it out

This enables board-level interconnect testing: drive known values onto outputs, observe them at adjacent device inputs, verify board-level shorts and opens without ICT (in-circuit test) needle probes.

---

### Q4. What is Memory BIST (MBIST) and why is SRAM testing different from logic testing?

**Answer:**

SRAM arrays cannot be tested with scan chains — the bit cells are not flip-flops and cannot be inserted into scan paths. SRAM defects include:

- **Stuck-at faults in bit cells:** A cell permanently reads 0 or 1.
- **Transition faults:** A cell cannot switch from 0→1 or 1→0.
- **Address decoder faults:** Multiple cells respond to a single address, or a cell is unreachable.
- **Coupling faults:** Writing to one cell disturbs a neighbouring cell (due to capacitive or resistive coupling).
- **Data retention failures:** A cell loses its value within the specified hold time.

**MBIST architecture:**

Memory BIST adds a hardware controller (MBIST engine) that replaces the normal read/write ports with test-controlled access:

```
                    ┌───────────────┐
Normal logic ──────►│     MUX       │──► SRAM Address/Data/Control
                    │ (functional / │
MBIST Engine ───────►│   test)       │
                    └───────────────┘
                           │
                    MBIST controller drives:
                    - Address (sequential or interleaved)
                    - Data patterns (march algorithms)
                    - Read/Write control
                    - Pass/fail comparison
```

**March algorithms:**

March tests are the standard algorithms for comprehensive SRAM fault detection. They specify a sequence of read/write operations over the address space:

**March C- algorithm:**
```
↑(w0)          Write 0 to all cells in ascending address order
↑(r0, w1)      Read 0 (verify), write 1 — ascending
↑(r1, w0)      Read 1 (verify), write 0 — ascending
↓(r0, w1)      Read 0 (verify), write 1 — descending
↓(r1, w0)      Read 1 (verify), write 0 — descending
↑(r0)          Read 0 and verify — ascending
```

Notation: `↑` = ascending address, `↓` = descending, `rX` = read expecting X, `wX` = write X.

March C- detects all stuck-at faults and all coupling faults between adjacent cells.

**MBIST in SoC context:**

An SoC may contain hundreds of SRAM instances (register files, caches, FIFOs, lookup tables). A centralised MBIST controller with an IEEE 1500 wrapper (or JTAG-based access) can test all memories serially. Results are reported via a pass/fail register accessible through JTAG.

BIRA (Built-In Redundancy Analysis) accompanies MBIST in many products. When a failing cell is identified, BIRA determines whether it can be repaired using the spare rows and columns designed into the SRAM (redundancy). On advanced processes, SRAMs ship with 2–4 spare rows/columns precisely because cell failures at 5–7 nm are common enough to require in-field repair.

---

## Tier 2: Intermediate

### Q5. How are scan chains organised for efficient manufacturing test? Describe the tradeoffs in chain count and length.

**Answer:**

An SoC with 5 million flip-flops cannot be put into a single scan chain of 5 million bits — shifting 5M bits at a 100 MHz test clock would take 50 ms per pattern, and with 10,000 patterns the total test time would be 500 seconds. Production test requires seconds, not minutes.

**Multiple scan chains:**

The solution is to divide the flip-flops into multiple parallel chains, all clocked simultaneously and all shifting in/out in parallel through dedicated test I/O pins:

```
TDI_0 ──► [Chain 0: 5000 FFs] ──► TDO_0
TDI_1 ──► [Chain 1: 5000 FFs] ──► TDO_1
...
TDI_N ──► [Chain N: 5000 FFs] ──► TDO_N
```

With 1000 parallel chains each of length 5000, the shift time per pattern is 5000/100MHz = 50 μs, and 10,000 patterns complete in 500 ms — acceptable for production test.

**Tradeoffs:**

| Parameter | Fewer, longer chains | More, shorter chains |
|---|---|---|
| Test time | Longer (more shifts per pattern) | Shorter |
| Tester channel count | Fewer (lower tester cost) | More (higher tester cost) |
| Routing congestion | Lower (fewer scan in/out nets) | Higher |
| Pattern count per fault | Lower (more FFs per pattern) | Higher (diminishing returns) |
| Diagnosis resolution | Coarser | Finer (shorter chains isolate failures) |

**Compression (EDT — Embedded Deterministic Test):**

Test compression reduces the number of tester channels needed while maintaining short test time. An on-chip decompressor expands a small number of tester channels (e.g., 8) into a large number of internal scan chains (e.g., 100):

```
8 tester channels ──► [On-chip decompressor (LFSR-based)] ──► 100 scan chain inputs
100 scan chain outputs ──► [On-chip compactor (XOR trees)] ──► 8 tester channels
```

Typical compression ratios of 50–200x are achievable while maintaining 99%+ fault coverage. Synopsys DFT Compiler and Cadence Modus are the leading tools.

**Chain balance:**

ATPG tools achieve maximum efficiency when all chains have equal length. Unbalanced chains (one chain of 100 FFs, another of 10,000 FFs) waste time shifting zeros through the short chain. Physical design tools (Synopsys ICC2, Cadence Innovus) balance scan chains by considering physical proximity of FFs (shorter wiring) while maintaining equal chain lengths.

---

### Q6. Explain ATPG (Automatic Test Pattern Generation). How does it generate patterns for stuck-at faults?

**Answer:**

ATPG is the algorithmic process of generating a set of test vectors (input patterns) that, when applied to the gate-level netlist, will detect the maximum number of faults with the minimum number of patterns.

**The D-Algorithm (conceptual basis):**

For each target fault (e.g., SA0 on net X):

**Step 1 — Fault activation (excitation):**
Drive the faulty net to the opposite of the stuck value. For SA0 on net X, drive X = 1.

**Step 2 — Fault propagation (path sensitisation):**
Find a path from net X to an observable output (scan FF output or primary output) where the fault value can propagate. Assign non-controlling values to all other inputs along this path.

**Step 3 — Justification (line justification):**
Work backwards from the fault site to primary inputs, assigning values to all inputs that justify the required logic values at each gate.

**Example:**

```
A ──┐
    AND(G1) ──► X (SA0 fault) ──┐
B ──┘                             AND(G2) ──► Y (observable)
                              C ──┘

Target: SA0 on X
Step 1: Need X=1 to activate SA0. Set A=1, B=1 → X=1 (but fault makes it 0).
Step 2: Propagate through G2. Set C=1 (non-controlling for AND). 
        Fault-free: Y = X AND C = 1 AND 1 = 1
        With SA0: Y = 0 AND 1 = 0
        Difference observable at Y.
Step 3: Already justified: A=1, B=1, C=1.

Test vector: A=1, B=1, C=1
Expected output: Y=1 (fault-free) or Y=0 (SA0 present)
```

**Modern ATPG — SAT-based:**

Classical D-algorithm and PODEM are incomplete for complex sequential circuits. Modern tools use SAT (Boolean Satisfiability) solvers to generate patterns:

1. Encode the circuit netlist as a Boolean formula.
2. Add fault activation and propagation constraints.
3. Run a CDCL SAT solver to find an assignment satisfying all constraints.
4. The satisfying assignment is the test vector.

SAT-based ATPG handles high-complexity circuits, X-state sources (tri-state buses, asynchronous FFs), and partial scan with high efficiency.

**Fault classes:**

| Class | Percentage | Implication |
|---|---|---|
| Detected (D) | Target ≥ 99% | Pattern activates and observes the fault |
| Possibly detected (PD) | < 0.5% | Pattern may detect the fault depending on X-state resolution |
| Untestable (UT) | 0–2% | Structural proof that no test vector can detect the fault |
| Undetected (AU) | Must minimise | No pattern found yet; target < 0.1% |

Untestable faults arise from redundant logic (gates whose removal does not change functionality). Redundant logic should be eliminated — it adds area and leakage with no functional benefit.

---

### Q7. What is transition fault testing and how does it complement stuck-at testing?

**Answer:**

A transition fault (also called a slow-to-rise or slow-to-fall fault) models a timing defect: a net that can transition logically, but the transition arrives too late relative to the clock edge. The fault is not detectable by static logic tests (stuck-at patterns clock at functional frequency; a slow transition that just barely misses setup time will not be caught).

**Types:**

- **Slow-to-rise (STR):** Net transitions 0→1 but too slowly. Rising transition exceeds setup time.
- **Slow-to-fall (STF):** Net transitions 1→0 but too slowly.

**Detection requirement:**

A transition fault on net N is detected by a pattern that:
1. **Initialises** the net to the opposite value (e.g., 0 for STR fault).
2. **Launches** a transition on net N at a clock edge (clock V1).
3. **Captures** the result at the observation point one clock period later (clock V2).

This is called **Launch-on-Capture (LOC)** or **Launch-on-Shift (LOS)** testing.

**Launch-on-Shift (LOS):**

```
Phase 1: SHIFT — shift the initialising pattern into the scan chain
Phase 2: SHIFT (last bit) — the last shift clock edge launches the transition
Phase 3: CAPTURE — one functional clock edge captures the response
Phase 4: SHIFT — shift out the response
```

The last shift clock edge must run at functional speed (the actual clock frequency). This requires the tester to switch clock frequency between shift mode and capture mode — a tester capability called "at-speed test."

**At-speed testing requirement:**

Transition fault testing must run at the operational clock frequency to detect timing-dependent defects. A 2 GHz processor must be tested at 2 GHz capture clocks. This drives significant test infrastructure cost:
- Tester pin electronics must support ≥ 2 GHz signalling.
- Clock generation circuits must produce clean 2 GHz test clocks.
- Alternative: on-chip PLLs generate the test clocks; ATPG patterns control the PLL via scan.

**Stuck-at vs. transition fault coverage relationship:**

High stuck-at coverage does not guarantee high transition fault coverage. Stuck-at patterns exercise logic functionality but do not systematically exercise timing paths. A chip with 99.9% SA coverage may have only 85% transition fault coverage — the remaining 15% represents potential timing marginal paths that could fail at temperature extremes or voltage corners.

Industry target: ≥ 95% transition fault coverage for high-reliability applications; ≥ 98% for automotive (ISO 26262 ASIL-D).

---

### Q8. How is JTAG used beyond manufacturing test? Describe its role in debug and programming workflows.

**Answer:**

IEEE 1149.1 JTAG was designed for board-level testing, but its universal adoption made it the standard debug interface for embedded processors and the primary programming interface for flash memories.

**Processor debug via JTAG (ARM CoreSight):**

Arm's CoreSight debug architecture extends JTAG with a higher-level protocol:

```
JTAG TAP → JTAG-AP (Access Port) → APB bus → DAP (Debug Access Port)
                                                   │
                                            ┌──────┴──────┐
                                            │             │
                                        MEM-AP        AHB-AP
                                         │                │
                                    System memory    CoreSight components:
                                    (read/write)     - CTI (Cross-Trigger)
                                                     - ETM (Trace)
                                                     - CPU debug registers
```

Through this chain, a debugger (GDB + OpenOCD) can:
1. Halt the processor (write DBGDRCR halt bit).
2. Read/write CPU registers (DBGDTRTX/DBGDTRRX through JTAG).
3. Set hardware breakpoints and watchpoints (BVR/BCR registers).
4. Single-step execution.
5. Read/write arbitrary memory addresses via MEM-AP.
6. Receive instruction trace via ETM→ATB→TPIU → external trace.

**Flash programming:**

JTAG is used to program flash memories (NOR flash, eMMC, NAND) before the device has any software loaded:
1. JTAG shifts in a small flash programming algorithm into device SRAM.
2. JTAG releases the processor from reset; the algorithm executes.
3. The algorithm reads flash data from JTAG (via a memory-mapped JTAG debug register) and writes it to the flash controller.
4. After completion, the device is reset and boots from the newly programmed flash.

**JTAG security considerations:**

JTAG provides complete control over a running processor. In production devices:
- JTAG must be disabled or authentication-gated before shipping to prevent reverse engineering.
- Common mechanisms: OTP fuse bit that disables JTAG; or JTAG requires a cryptographic challenge-response (signed debug certificate from OEM).
- ARM CoreSight supports authentication signals (DBGEN, NIDEN, SPIDEN, SPNIDEN) that can be tied to fuse values to selectively disable debug visibility.

---

## Tier 3: Advanced

### Q9. An SoC has achieved 97.5% stuck-at fault coverage and 88% transition fault coverage after ATPG. The product target is 99% SA and 95% transition. Describe the systematic approach to close the coverage gap.

**Answer:**

**Step 1 — Analyse the coverage report by category.**

Modern ATPG tools (Synopsys TetraMAX, Cadence Modus) produce detailed fault classification reports:

```
Fault Summary Report:
─────────────────────────────────────────────────────
Total fault count:        2,450,000
Detected (D):             2,388,750  (97.5%)
Possibly Detected (PD):      12,250  (0.5%)
Untestable (UT):             24,500  (1.0%)
ATPG Undetected (AU):        24,500  (1.0%)
─────────────────────────────────────────────────────

Transition Fault Summary:
Detected:                 2,156,000  (88.0%)
ATPG Undetected:            294,000  (12.0%)
```

**Step 2 — Address stuck-at gap (target: 97.5% → 99%).**

The 1% ATPG undetected faults are the priority. Causes and fixes:

**A. X-state blocking:**
RTL has uninitialized registers or tri-state buses that propagate X values (unknown) into the observation path, masking fault detection.

```tcl
# In ATPG tool:
report_x_sources -all > x_sources.rpt
# Identify modules contributing most X values

# Fix options:
# 1. Add scan-specific initialization to reset all FFs to 0/1
# 2. Constrain tri-state enables to non-tristate during scan
set_attribute -cell [get_cells *tri_en*] x_capture_value 0
```

**B. Combinational feedback loops (asynchronous latches):**
Asynchronous latches create combinational loops that ATPG cannot break. Fix: convert to synchronous design, or add `set_false_path -through` constraints to exclude latch outputs from full ATPG consideration.

**C. Black boxes (unmodelled IPs):**
Memory macros, analog IP, and third-party hard macros appear as black boxes. Their internal faults are untestable through the top-level scan chain. Fix: ensure each memory has an MBIST controller; for analog blocks, add test bypass modes.

**D. Clock domain crossing cells:**
CDC synchroniser flip-flops (double-flop synchronisers) often appear undetected because the ATPG tool cannot apply patterns that cross the clock domain. Fix: add `set_dft_signal -type MasterClock` constraints to allow the ATPG tool to control both clock domains simultaneously.

**Step 3 — Address transition fault gap (target: 88% → 95%).**

**A. Timing-based X sources:**
Some paths have multiple clocks with non-integer frequency ratios. The ATPG tool cannot guarantee the capture clock edge aligns with the fault sensitisation. Fix: constrain multi-cycle paths explicitly; provide an at-speed test clock spec.

**B. Path length distribution:**
Transition faults on very short paths (single gate delay) are hard to detect because they require single-cycle launch-to-capture. Add `set_min_transition_delay` constraints so ATPG focuses on longer, more reliably testable paths.

**C. Insufficient at-speed patterns:**
Increase the ATPG run effort and pattern count limits:

```tcl
set_atpg_limit -max_patterns 50000  ;# increase from default 10000
set_atpg_effort high
run_atpg -transition_fault -coverage_target 95
```

**D. Functional broadside patterns:**
Functional test patterns derived from RTL simulation (converted to scan patterns) often provide 3–8% additional transition fault coverage on paths that ATPG finds difficult. Use Synopsys DPGen or equivalent to extract functional patterns from RTL regression simulations.

**Step 4 — Validate coverage improvement.**

After each fix, re-run ATPG and measure:
- Total fault count (adding constraints can change the total)
- Coverage percentage
- Pattern count (monitor for explosion — too many patterns increase test time and cost)

Coverage report after fixes:
```
After X-source reduction and at-speed tuning:
SA coverage:           99.1% (target achieved)
Transition coverage:   95.3% (target achieved)
Pattern count:         +12% increase (acceptable)
Test time increase:    +8% (acceptable)
```

---

### Q10. Describe the DFT architecture for a heterogeneous SoC with CPU cluster, GPU, DSP, and multiple SRAM macros. How are scan chains organised across clock domains and power domains?

**Answer:**

A heterogeneous SoC with multiple clock domains and power domains requires a structured DFT architecture that:
1. Isolates scan chains by clock domain (each domain uses its own test clock).
2. Handles power domain boundaries (a powered-off domain cannot participate in scan).
3. Provides independent testability of each subsystem.
4. Integrates with MBIST for all memory macros.

**Top-level DFT architecture:**

```
                         JTAG TAP Controller
                               │
                    ┌──────────┼──────────┐
                    │          │          │
              Test Control    IR         DR Mux
             (TCLK gen,                   │
              TM/SE)               ┌──────┴──────┐
                                   │  Scan chains │
                               ┌───┴───┐       ┌──┴───┐
                              CPU       GPU/DSP   MBIST
                            cluster    cluster   engine
                            chains      chains
                          (CLK_CPU)   (CLK_GPU)
```

**Scan chain partitioning by clock domain:**

Each clock domain has a dedicated set of scan chains and a dedicated test clock (derived from JTAG TCK via a test clock controller):

```
Test clock controller:
  TCK (50 MHz from tester) ──► Divider/Mux ──► TCLK_CPU (for CPU scan chains)
                                          └──► TCLK_GPU (for GPU scan chains)
                                          └──► TCLK_DSP (for DSP scan chains)
```

During scan shift, all chains shift at TCLK (slow, matching tester capability). During at-speed capture for transition fault testing, each domain uses its own functional clock (2 GHz for CPU, 1 GHz for GPU).

**Scan chain partitioning by power domain:**

Power-gated domains must be handled carefully:

1. **When the domain is on:** Scan chains in the domain participate normally.
2. **When the domain is off:** The scan chain path through the powered-off domain is broken (FFs lose state). The DFT controller must exclude these chains or route around the domain.

Implementation: **Scan enable muxing with power domain status:**

```
                    ┌────────────┐
Power_domain_on ───►│     AND    │──► SE_for_domain_FFs
Scan_enable ───────►│            │
                    └────────────┘
```

When `Power_domain_on = 0`, the scan enable for that domain's FFs is masked off. The MBIST controller and top-level scan controller track domain power state (via PMU status registers readable through JTAG).

**MBIST integration:**

Each SRAM macro has a dedicated MBIST controller or shares a centralised MBIST engine. An IEEE 1500 wrapper (IJTAG) provides a standardised scan path through each MBIST controller for diagnostics.

```
JTAG TAP ──► IJTAG (IEEE 1687) ──► MBIST for L1 cache (CPU domain)
                                ├──► MBIST for L2 cache (CPU domain)
                                ├──► MBIST for GPU local SRAM
                                └──► MBIST for DSP scratchpad
```

Advantages of IEEE 1687 (IJTAG): hierarchical access, each instrument has a standard wrapper, scan path length is minimised to only the selected instrument at test time.

**DFT sign-off checklist:**

```
□ SA fault coverage ≥ 99.0%
□ Transition fault coverage ≥ 95.0%
□ MBIST coverage for all SRAMs: 100% of cells
□ Boundary scan functional (IDCODE readable, SAMPLE/EXTEST functional)
□ Scan chain continuity verified (shift register mode, all FFs captured)
□ At-speed test pattern set validated at Fmax × 1.05 (guardband)
□ Power domain scan interactions verified (domain off, scan routes correctly)
□ JTAG security (debug disable fuse, authentication mechanism verified)
□ Test time within budget: total test time ≤ 15 s per device at target ATE throughput
```

---

## Quick Reference: Key Terms

| Term | Definition |
|---|---|
| Scan chain | Series connection of scan flip-flops forming a shift register for test data access |
| Scan flip-flop (SFF) | FF with an additional MUX on input, selecting between functional data and scan-in |
| Stuck-at fault | Fault model: net permanently at 0 (SA0) or 1 (SA1) regardless of correct value |
| ATPG | Automatic Test Pattern Generation; tool-generated input patterns to detect faults |
| Fault coverage | Percentage of modelled faults detected by the test pattern set |
| Transition fault | Fault model: net can switch logically but too slowly for the timing constraint |
| At-speed test | Running capture clocks at functional frequency during transition fault testing |
| MBIST | Memory Built-In Self-Test; hardware controller running march algorithms on SRAM |
| March algorithm | Sequential read/write test procedure for SRAM fault coverage (e.g., March C-) |
| BIRA | Built-In Redundancy Analysis; hardware that maps detected SRAM failures to spare rows/cols |
| JTAG | IEEE 1149.1; TAP controller with TDI/TDO/TMS/TCK for external serial test access |
| Boundary scan | Chain of cells at I/O pins; enables board-level interconnect testing |
| TAP | Test Access Port; the 16-state FSM governed by TMS that controls JTAG operation |
| EDT | Embedded Deterministic Test; on-chip compression/decompression for scan patterns |
| X-state | Unknown logic value (tri-state, uninitialized FF); blocks fault propagation in ATPG |
| CoreSight | Arm debug and trace architecture built on JTAG; used for processor debug and ETM trace |
| IJTAG (IEEE 1687) | Hierarchical instrument access standard; standardised wrappers for MBIST, sensors |
