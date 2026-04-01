# Quiz: System-Level Design

15 multiple-choice questions covering power management, clock gating, security and TrustZone, DFT and BIST, and SoC verification strategy. Questions span three difficulty tiers. Answers with explanations are collected at the end.

---

## Instructions

Select the single best answer for each question. After completing all questions, check your answers against the answer key. For each incorrect answer, read the full explanation before moving on.

Suggested time: 25 minutes.

---

## Questions

### Fundamentals (Q1 -- Q5)

**Q1.** Dynamic power dissipation in CMOS logic is primarily described by which equation?

- A) P = I^2 * R (resistive heating from leakage current)
- B) P = alpha * C * V^2 * f (switching activity, capacitance, supply voltage squared, frequency)
- C) P = V * I_leak (static power from subthreshold leakage)
- D) P = C * V * f (capacitance, voltage, frequency without squaring)

---

**Q2.** Clock gating inserts an enable-controlled gate on a clock path to a register or block. What is the primary benefit of clock gating for power reduction?

- A) It reduces the supply voltage to the gated logic block
- B) It prevents the clock tree from toggling when the downstream logic does not need to compute, eliminating dynamic switching power in both the clock tree and the data logic
- C) It reduces the threshold voltage of the transistors in the gated block
- D) It allows the gated block to run at a higher frequency during active periods

---

**Q3.** In ARM TrustZone architecture, software executing in the Secure World:

- A) Runs at a higher CPU privilege level (EL3) than normal-world OS kernel code (EL1) and can access all physical memory regardless of NS bit settings
- B) Is isolated from Normal World software; Secure World code can access both Secure and Normal World memory, but Normal World code cannot access Secure World memory regions
- C) Must be executed from ROM only and cannot write to any DRAM
- D) Is equivalent in privilege to Normal World kernel mode but has exclusive access to cryptographic hardware accelerators

---

**Q4.** Scan chain insertion is a fundamental DFT technique. What does it replace within the design?

- A) Combinational logic gates with multiplexers to allow in-system logic probing
- B) Standard flip-flops with scan flip-flops that have an additional scan input and mode select, allowing all state elements to be shifted in and out as a serial shift register
- C) Memories (SRAMs) with shift-register-based shadow copies for test access
- D) The clock tree with a test clock that runs at a much lower frequency to improve ATPG coverage

---

**Q5.** Formal verification of a hardware design uses mathematical proof techniques. Which of the following is a correct statement about formal verification compared to simulation?

- A) Formal verification requires a complete testbench with stimulus vectors; simulation does not
- B) Formal verification can prove the absence of a class of bugs across all possible input combinations; simulation can only demonstrate correctness for the applied stimulus
- C) Formal verification is always faster than simulation because it avoids running test vectors
- D) Formal verification cannot check timing properties; it is limited to functional correctness

---

### Intermediate (Q6 -- Q11)

**Q6.** A power domain is isolated from its supply and enters a retention state. The isolation cells on the domain's outputs are required to hold their outputs at a safe logic value during power-down. Why is a safe value required?

- A) To prevent current leakage through the output drivers of the powered-down domain
- B) To prevent unpredictable (floating) signals from propagating into the always-on power domain and causing spurious transitions or corruption in logic that remains powered
- C) To allow the powered-down domain to receive wake-up signals from the always-on domain
- D) To maintain the PLL lock in the powered-down domain by holding the feedback clock stable

---

**Q7.** An SoC implements DVFS (Dynamic Voltage and Frequency Scaling). The operating point is changed from (1.0 V, 1 GHz) to (0.8 V, 800 MHz). In which order must the voltage and frequency changes be applied, and why?

- A) Frequency first, then voltage: the lower frequency must be established before reducing voltage to avoid hold-time violations
- B) Voltage first, then frequency: the voltage must be confirmed stable at the new level before the frequency is increased to avoid setup violations. When reducing, frequency first then voltage to maintain timing margin
- C) Voltage and frequency must be changed simultaneously to avoid any transient operating point that violates timing
- D) The order does not matter; DVFS hardware manages the transition automatically

---

**Q8.** Memory BIST (Built-In Self Test) for an embedded SRAM typically uses a March algorithm. Which statement best describes what a March algorithm tests?

- A) It applies a fixed test pattern (all zeros, all ones, checkerboard) to verify basic bit storage
- B) It performs a sequence of read and write operations in a defined order over all addresses to detect stuck-at faults, transition faults, coupling faults between adjacent cells, and address decoder faults
- C) It uses a linear feedback shift register (LFSR) to generate pseudo-random patterns for maximum fault coverage with minimal test time
- D) It performs a single write-then-read pass with an incrementing data pattern to verify address decoder uniqueness

---

**Q9.** A TrustZone-aware SoC uses a TZASC (TrustZone Address Space Controller) to partition DRAM into Secure and Non-Secure regions. A Normal World DMA controller attempts to write to a Secure DRAM region. Which outcome is architecturally correct?

- A) The write is permitted because DMA controllers bypass TrustZone protection
- B) The TZASC detects the Non-Secure access to a Secure region and returns a bus error (DECERR or SLVERR) to the DMA controller, blocking the write
- C) The write is silently dropped; the DMA controller receives a success response to avoid denial-of-service
- D) The TZASC redirects the write to a Non-Secure shadow copy of the Secure memory region

---

**Q10.** At-speed testing in structural DFT is more demanding than slow-speed scan testing. What additional fault class does at-speed testing target that slow-speed scan does not?

- A) Stuck-at faults, where a node is permanently stuck at logic 0 or 1
- B) Bridging faults, where two nodes are shorted together
- C) Transition (delay) faults, where a path meets functional timing requirements but has a marginal delay that would fail under worst-case conditions
- D) Open faults, where a net is broken and no longer connects two gates

---

**Q11.** An SoC verification plan adopts a layered strategy: block-level UVM testbenches, subsystem-level integration tests, and full-chip simulation. Coverage closure is tracked using both code coverage and functional coverage. Which statement correctly distinguishes functional coverage from code coverage?

- A) Code coverage measures whether all HDL lines were executed; functional coverage measures whether all architecturally significant scenarios (protocol corner cases, error conditions, state machine transitions) have been exercised, as defined by the verification plan
- B) Code coverage requires directed tests; functional coverage can only be achieved by random simulation
- C) Functional coverage is automatically computed by the simulator; code coverage must be manually defined by the verification engineer
- D) Code coverage applies to RTL simulation only; functional coverage applies to gate-level simulation only

---

### Advanced (Q12 -- Q15)

**Q12.** An SoC uses a power sequencing controller to manage the power-up order of multiple voltage rails: VDD_CORE, VDD_IO, VDD_PLL, and VDD_MEM. Which constraint governs the correct sequencing order?

- A) All rails must reach their target voltage simultaneously to avoid latch-up; the sequencer must ramp all rails in parallel
- B) Sequencing depends on the specific device requirements, but a common rule is to power core rails before IO rails to prevent forward-biased ESD protection diodes from injecting current, and to satisfy any vendor-specified rail interdependency constraints to avoid undefined input states on powered IO pins
- C) IO rails must always power up before core rails to ensure that the device can receive the enable signal that starts the core power-up sequence
- D) The sequencing order is irrelevant for modern FinFET process nodes because latch-up immunity is guaranteed by the process design rules

---

**Q13.** A block-level formal verification run reports that a property is "vacuously true". What does this mean and why is it a problem?

- A) The property holds under all simulation conditions but has not been formally proved
- B) The property's assumption (precondition) is unreachable -- the formal tool could not find any input sequence that satisfies the precondition, so the implication "if P then Q" is trivially true without Q ever being evaluated; the test provides no coverage of Q
- C) The property was proven true but only for input combinations that cover less than 50% of the state space
- D) The property was simplified by the formal tool and the simplified version no longer matches the original intent

---

**Q14.** A design-for-test engineer wants to maximise structural test coverage for an SoC that includes several large embedded SRAMs. The SRAMs cannot be directly tested by the scan chain. Which DFT technique combination provides the most complete coverage?

- A) ATPG patterns for the combinational logic around the SRAMs, plus Memory BIST (MBIST) controllers embedded in the design for each SRAM macro
- B) Boundary scan (JTAG IEEE 1149.1) alone, because it can drive all internal nodes including SRAM address and data lines
- C) Functional simulation test vectors applied through the scan chain to emulate normal read/write operations on the SRAM
- D) Logic BIST (LBIST) using an LFSR seeded with the SRAM address to generate test patterns

---

**Q15.** During silicon bring-up, a new SoC revision shows a systematic failure: the chip boots correctly at room temperature and 1.0 V but fails when the supply is reduced to 0.95 V (still within the specification). Post-silicon analysis using scan dump reveals that the failing flip-flops are all on paths in the memory controller that cross from the DDR PHY clock domain to the system clock domain. No timing violations were flagged in pre-silicon static timing analysis (STA). What is the most likely root cause and what corrective action is appropriate?

- A) The DDR PHY has a manufacturing defect; replace the PHY macro
- B) The CDC synchroniser paths were not constrained correctly in the STA run, so setup violations at reduced voltage were not detected; the fix is to add correct max-delay constraints and two-flop synchronisers with appropriate MTBF budgets, then re-characterise the timing at the relevant PVT corners
- C) The memory controller has a stuck-at fault on the data bus; apply ATPG vectors to isolate the failing bit
- D) The flip-flops were mapped to a non-default library cell with incorrect timing models; re-run synthesis with the correct library and retape out



---

## Answer Key

| Q  | Answer |
|----|--------|
| 1  | B      |
| 2  | B      |
| 3  | B      |
| 4  | B      |
| 5  | B      |
| 6  | B      |
| 7  | B      |
| 8  | B      |
| 9  | B      |
| 10 | C      |
| 11 | A      |
| 12 | B      |
| 13 | B      |
| 14 | A      |
| 15 | B      |

---

## Detailed Explanations

**Q1 -- Answer: B**

Dynamic CMOS power is P = alpha * C_L * V_DD^2 * f, where alpha is the switching activity factor (fraction of clock cycles during which a node switches), C_L is the load capacitance, V_DD is the supply voltage, and f is the clock frequency. The squared dependence on voltage is the key insight: halving the supply voltage reduces dynamic power by 4x (ignoring frequency). Option A describes static power from resistance (joule heating due to leakage, a different mechanism). Option C describes static leakage power, which is the dominant concern in deep-submicron processes at low activity. Option D omits the V^2 term, which is incorrect -- the energy to charge the capacitor to V_DD includes the V^2 relationship.

---

**Q2 -- Answer: B**

Every clock edge causes a toggle, which charges and discharges the clock tree capacitance -- the largest single power component on many SoCs. When downstream registers do not need to capture new data (the block is idle), clock gating inserts an AND gate (or a clock gating cell with integrated latch) between the clock tree and the registers. When the enable is de-asserted, the clock to the registers stays low and does not toggle. This eliminates both the clock tree switching power for that branch and the data path switching power (since data inputs do not propagate to outputs when the clock is gated). Option A describes voltage scaling (DVFS). Option C describes threshold voltage adjustment (body biasing). Option D describes overclocking, which is the opposite of what clock gating achieves.

---

**Q3 -- Answer: B**

TrustZone creates two software environments sharing one processor. The Secure World (EL3 in AArch64, or Secure EL1/EL0 for OS/apps) can access all physical addresses. The Normal World (EL2/EL1/EL0) is restricted by the NS (Non-Secure) bit on the AXI bus: accesses from Normal World carry NS=1, and the TZASC or TZPC will reject NS=1 accesses to Secure-marked memory regions. Option A is partially correct (Secure World has broad access) but misidentifies EL3 as the Secure OS level -- EL3 is the Secure Monitor (firmware), while the Secure OS typically runs at Secure EL1. Option C is incorrect; Secure World code executes from DRAM if the region is marked Secure. Option D is wrong; Normal World kernel at EL1 does not have access to Secure World memory.

---

**Q4 -- Answer: B**

Scan chain DFT replaces standard D flip-flops with scan flip-flops. A scan flip-flop has an additional multiplexer at its data input: in normal mode, the D input comes from the functional data path; in scan mode, the D input comes from the scan-in (SI) of the previous flip-flop in the chain. The scan enable (SE) signal selects between these two paths. In test mode, all scan flip-flops form a long shift register: a test pattern is shifted in serially, the circuit is clocked once (or a few times) to capture the response, and the result is shifted out serially for comparison against the expected value. This provides controllability and observability for every state element in the design. Option A describes logic probing, not standard scan. Option C describes memory shadow registers, a different technique. Option D describes clock frequency reduction, which is incidental to scan test operation, not the mechanism itself.

---

**Q5 -- Answer: B**

Simulation is exhaustive only if every possible input is tested -- computationally infeasible for any non-trivial design. Instead, simulation demonstrates correctness for the applied stimulus, leaving the untested space unchecked. Formal verification uses mathematical proof engines (model checking, theorem proving) to exhaustively explore all reachable states and prove or disprove properties such as "this FIFO can never overflow" for all possible input sequences. When a property fails, the tool provides a concrete counterexample. Option A reverses the requirements: simulation needs a testbench; formal verification needs properties (assertions) and constraints, not traditional testbenches. Option C is wrong; formal verification can be slower than simulation for large state spaces (state explosion problem). Option D is wrong; temporal logic (CTL, LTL) allows formal verification of timing properties such as "signal A is always followed by signal B within 5 cycles".

---

**Q6 -- Answer: B**

When a power domain is switched off, its output drivers lose their supply and their outputs float to unknown logic levels. If these floating signals feed into gates in an always-on domain, the receiving gates see an undefined input, which can cause short-circuit current (both pull-up and pull-down networks may partially conduct simultaneously), incorrect logic evaluations, and high power consumption. Isolation cells clamp the output of the powered-down domain to a predefined safe value (typically 0 or 1, chosen by the designer based on the function) before power is removed. This is a mandatory step in any power domain power-down sequence. Option A is wrong; isolation primarily protects the receiving always-on logic, not the powered-down output drivers. Option C is wrong; isolation is for output signals, not input wake signals. Option D is wrong; PLLs in powered-down domains should be disabled, not maintained through isolation.

---

**Q7 -- Answer: B**

When scaling up (increasing performance): raise the voltage first, confirm it has settled, then raise the frequency. If frequency were raised first, the logic would be running faster than the current voltage supports, potentially causing setup violations and incorrect operation. When scaling down (reducing performance): reduce the frequency first, then reduce the voltage. If voltage were reduced first, the logic would still be at the old (higher) frequency with less voltage, potentially causing setup violations. The general rule is: voltage must always be sufficient for the operating frequency. Option A gets the scale-up direction wrong. Option C is impractical -- power supplies have ramp rates and cannot change instantaneously. Option D is wrong; software typically coordinates the OPP (Operating Performance Point) change through the PMIC and frequency divider, and the order matters.

---

**Q8 -- Answer: B**

March algorithms are a class of memory test algorithms that perform a specific sequence of read (r0, r1) and write (w0, w1) operations traversing addresses in ascending and descending order. The systematic traversal order and the specific read/write sequence are designed to sensitise and detect stuck-at faults, transition faults (a cell cannot change state), coupling faults (writing one cell affects another), and address decoder faults (two addresses alias to the same cell). Well-known March algorithms include March C-, March X, and MATS+. Option A describes simpler but less thorough checkerboard or walking-1s patterns. Option C describes LFSR-based pseudo-random BIST, which has good fault coverage but is harder to analyse for specific fault models. Option D describes an incrementing-data pattern, which has weak coupling fault coverage.

---

**Q9 -- Answer: B**

The TZASC is a programmable firewall that sits in the DRAM access path and enforces NS/S attribute checking on every transaction. Each AXI transaction carries the AxPROT[1] bit (NS bit): 0 = Secure, 1 = Non-Secure. A Normal World DMA controller drives NS=1 on all its transactions. If the target address is configured as a Secure region in the TZASC, the controller detects the mismatch and returns a bus error (SLVERR or DECERR). The DMA write does not reach the DRAM. Option A is wrong; the TZASC does not have a DMA bypass. Option C is wrong; a silent success response would be a security vulnerability, allowing Non-Secure masters to corrupt Secure data without detection. Option D is wrong; no shadow copy mechanism exists in standard TZASC.

---

**Q10 -- Answer: C**

Slow-speed scan testing shifts patterns through the scan chain at a low clock rate and captures the logic response one cycle later. This is effective for stuck-at and bridging faults but cannot detect paths that are functionally correct at slow speeds and fail only at-speed. Transition fault testing (also called at-speed or delay testing) applies a pattern that launches a transition on the path under test and captures the result after one or two fast clock cycles to verify that the path meets its timing requirement. This catches marginally slow paths caused by process variation, increased resistance in metal lines, or design optimisations that push timing close to the limit. Option A (stuck-at) and option B (bridging) are both detectable by slow-speed scan. Option D (open) is also detectable by slow-speed scan.

---

**Q11 -- Answer: A**

Code coverage is automatically extracted by the simulator and measures structural exercise: which HDL lines, branches, FSM states, and toggle events were reached during simulation. It does not tell you whether interesting functional scenarios were tested. Functional coverage is defined by the verification engineer in a coverage model (SystemVerilog covergroups and coverpoints) and captures whether the specific scenarios deemed important for correctness have been exercised -- protocol corner cases, back-to-back transactions, error injection, boundary conditions. Coverage closure requires both metrics: high code coverage without functional coverage leaves unspecified scenarios untested; high functional coverage without code coverage may leave dead or unreachable code unexercised. Option B is wrong; directed tests can achieve functional coverage; random simulation often drives code coverage automatically. Option C has the definitions reversed. Option D is wrong; both metrics apply at RTL and gate level.

---

**Q12 -- Answer: B**

Power-up sequencing must satisfy two primary constraints. First, ESD protection diodes (protection structures between IO pads and power rails) can become forward-biased if the IO rail rises above the core rail plus a diode drop, injecting current into the core supply in an uncontrolled manner -- potentially causing latch-up or device damage. Powering the core rail first prevents this. Second, device datasheets specify required sequencing to avoid undefined input states (an IO pin receiving a voltage when its input buffer supply is off). The exact order is device-specific. Option A is wrong; simultaneous ramp is generally not required and may be impractical; controlled sequential ramp is the norm. Option C has a common-case order wrong -- IO-before-core is specifically the dangerous scenario for ESD clamping. Option D is wrong; FinFET processes still require sequencing; latch-up characteristics change but power sequencing requirements remain.

---

**Q13 -- Answer: B**

Formal properties are written as implication: "if precondition (assume) then consequence (assert)". If the assume constraints prevent the tool from finding any legal input sequence that satisfies the precondition, the implication is vacuously true -- it says nothing about whether the asserted consequence holds in any real scenario. This is a verification blind spot. The property appears to pass but provides zero coverage of the intended assertion. Engineers must audit assume constraints carefully and use coverage properties to confirm that the property's precondition is actually reachable. Option A describes passing simulation, not formal proof. Option C describes incomplete state space coverage, which is a different formal concern (typically a completeness problem). Option D describes constraint simplification, which could lead to vacuity but is not the definition of it.

---

**Q14 -- Answer: A**

SRAMs are black-box macros not accessible via the standard scan chain -- their internal cells are not scan flip-flops. The correct approach is to use dedicated MBIST controllers: small state machines embedded around each SRAM macro that can independently drive address, data, and control signals to run March or other algorithms. MBIST is a well-established industry standard included in most SoC design methodologies. ATPG test patterns are generated for the combinational logic and sequential logic in the rest of the design (the "wrapper" logic around the SRAMs). Together, these two techniques provide high coverage for both the SRAM arrays and the surrounding logic. Option B is wrong; JTAG boundary scan tests IO pins and board-level connectivity, not embedded SRAM macros. Option C is wrong; functional vectors applied through the scan chain cannot reach the SRAM's internal test nodes. Option D is wrong; LBIST targets combinational and sequential logic in the scan chain; embedded SRAMs require MBIST.

---

**Q15 -- Answer: B**

The failure signature -- works at nominal voltage, fails at reduced voltage but still within spec, concentrated on clock domain crossing paths in STA-clean design -- is a classic indicator of inadequate CDC constraint coverage. Clock domain crossing paths between asynchronous domains are typically set as false paths or maximum-delay exceptions in STA (because they pass through synchronisers and no single-cycle timing path is valid). If the constraints were incorrect (too relaxed, applied to the wrong paths, or omitted), the STA would not flag the violation. At nominal voltage, synchronisers resolve metastability quickly enough to avoid problems. At reduced voltage, transistor drive strength decreases, synchroniser resolution time increases, and the effective MTBF degrades -- causing intermittent failures. The corrective action is to audit CDC constraints, verify two-flop synchroniser insertion, and re-run STA with correct constraints at the reduced-voltage corner. Option A is wrong; a PHY defect would typically be process-correlated (specific units), not systematic across voltage. Option C describes a stuck-at fault, which would be temperature and voltage independent. Option D is wrong; a library mapping error would be caught during synthesis and timing sign-off.
