# SoC Verification Strategy

## Overview

SoC verification is the largest single engineering effort in a modern chip development programme, consuming 50–70% of total project headcount and schedule. Getting it wrong means a silicon respin — typically six months and tens of millions of dollars. Getting it right requires a structured, hierarchical strategy that scales from individual IP blocks through subsystems to full-chip simulation, emulation, and FPGA prototyping.

This document covers the UVM-based verification methodology, subsystem vs. full-chip testbench organisation, formal verification techniques, coverage closure, emulation, and FPGA prototyping. Topics reflect real-world practice at leading semiconductor companies.

---

## Tier 1: Fundamentals

### Q1. What is the verification hierarchy and why is it structured that way?

**Answer:**

The verification hierarchy mirrors the design hierarchy: individual IPs are verified in isolation, then integrated and verified at subsystem level, then integrated into a full-chip testbench. Each level has distinct goals, environments, and metrics.

```
Level           Scope                   Primary goal              Typical engineers
──────────────  ──────────────────────  ────────────────────────  ─────────────────
IP / Unit       Single IP block         Protocol compliance,       1–2 per IP
                (e.g., UART, DMA,       corner cases, coverage
                AXI slave)

Subsystem       Multiple IPs +          Integration, dataflow,     2–4 per subsystem
                shared interconnect     coherency, power states
                (e.g., CPU cluster,
                memory subsystem)

Full-chip       Entire SoC netlist      End-to-end scenarios,      4–8
(top-level)     or RTL                  boot, OS, software
                                        co-verification

Silicon         Real hardware           Post-silicon characterisation Hardware + SW team
validation
```

**Why this decomposition:**

1. **Debug efficiency:** A bug found in a unit-level testbench (DUT = 5k gates) is trivially debugged with waveforms. The same bug found at full-chip (DUT = 500M gates) requires weeks to reproduce and localise. Moving bug discovery to the lowest possible level drastically reduces debug cost.

2. **Parallel execution:** IP-level verification of the CPU, GPU, memory controller, and DMA can run concurrently — different teams in parallel. Full-chip simulation cannot begin until all IPs are integrated.

3. **Coverage convergence:** Achieving 100% functional coverage at IP level with targeted directed tests is practical. Achieving the same at full-chip via random simulation alone is impractical — state spaces are too large.

4. **Regression speed:** A unit-level UVM testbench runs in seconds to minutes. Full-chip simulations run in hours. Keeping unit regressions fast enables daily CI runs; full-chip simulations run on weekly schedules.

---

### Q2. What is UVM and what problem does it solve compared to plain SystemVerilog testbenches?

**Answer:**

UVM (Universal Verification Methodology, IEEE 1800.2) is a standardised class library and methodology for building reusable, structured verification environments in SystemVerilog. It solves the problem of testbench non-portability and non-reusability that plagued the industry before standardisation.

**Problems with non-UVM testbenches:**

1. Each team invented their own stimulus generation, checking, and coverage framework — incompatible with other teams' IPs.
2. Moving a testbench from one project to another required extensive rework.
3. VIP (Verification IP) vendors could not provide plug-in components without knowing the customer's methodology.

**UVM architecture:**

```
┌─────────────────────────────────────────────────────────┐
│                   UVM Testbench (top)                    │
│                                                          │
│  ┌──────────────────────────────────────────────────┐   │
│  │                  UVM Test                        │   │
│  │  (configures env, selects sequence, starts run)  │   │
│  └──────────────────────┬───────────────────────────┘   │
│                         │                               │
│  ┌──────────────────────▼───────────────────────────┐   │
│  │               UVM Environment                    │   │
│  │                                                  │   │
│  │  ┌──────────┐  ┌────────────┐  ┌──────────────┐ │   │
│  │  │  Agent   │  │ Scoreboard │  │  Coverage    │ │   │
│  │  │ (AXI     │  │ (checks    │  │  Collector   │ │   │
│  │  │  master) │  │  responses)│  │              │ │   │
│  │  │          │  └────────────┘  └──────────────┘ │   │
│  │  │ ┌──────┐ │                                    │   │
│  │  │ │Seqr  │ │  ┌──────────┐                     │   │
│  │  │ └──┬───┘ │  │  Agent   │                     │   │
│  │  │    │     │  │ (APB     │                     │   │
│  │  │ ┌──▼───┐ │  │  slave)  │                     │   │
│  │  │ │ Drv  │ │  └──────────┘                     │   │
│  │  │ └──────┘ │                                    │   │
│  │  │ ┌──────┐ │                                    │   │
│  │  │ │ Mon  │ │                                    │   │
│  │  │ └──────┘ │                                    │   │
│  │  └──────────┘                                    │   │
│  └──────────────────────────────────────────────────┘   │
│                         │                               │
│            ┌────────────▼────────────┐                  │
│            │    DUT (RTL under test) │                  │
│            └─────────────────────────┘                  │
└─────────────────────────────────────────────────────────┘
```

**Key UVM components:**

| Component | Role |
|---|---|
| `uvm_test` | Top-level test class; configures environment and starts sequences |
| `uvm_env` | Container for agents, scoreboards, coverage; models a logical subsystem |
| `uvm_agent` | Models one interface (AXI, APB, etc.); contains sequencer, driver, monitor |
| `uvm_sequencer` | Manages sequence execution order; pulls transactions from sequences |
| `uvm_driver` | Converts transaction objects into pin-level signal activity on the DUT interface |
| `uvm_monitor` | Observes DUT interface signals and produces transaction objects for checking |
| `uvm_scoreboard` | Checks DUT output transactions against expected values (reference model) |
| `uvm_sequence` | Generator of transaction objects; encodes stimulus scenarios |
| `uvm_transaction` | Data object representing a single bus operation (e.g., AXI write) |

**UVM factory and configuration:**

The UVM factory allows overriding component types at runtime without modifying testbench source code:

```systemverilog
// Override AXI driver with an error-injection variant for fault coverage
uvm_factory::get().set_type_override_by_type(
    axi_driver::get_type(),
    axi_error_injection_driver::get_type()
);
```

This enables a single testbench codebase to support multiple test configurations (functional, fault injection, power-aware).

---

### Q3. What is functional coverage and how does it differ from code coverage?

**Answer:**

**Code coverage** measures which parts of the RTL source code were exercised during simulation:
- **Line coverage:** Which lines of RTL were executed.
- **Branch coverage:** Which branches of `if/else/case` were taken.
- **Toggle coverage:** Which nets switched from 0→1 and 1→0.
- **FSM coverage:** Which states were visited, which transitions were taken.

Code coverage is computed automatically by the simulator — no user effort required. However, 100% code coverage does not mean the design has been correctly verified. Code coverage says what was exercised, not what was checked.

**Functional coverage** measures whether the verification has exercised the design's functional specification. It answers: "Have we tested the scenarios that matter?"

```systemverilog
// Functional coverage for an AXI read transaction
covergroup axi_read_coverage @(posedge clk);

    // Cover all burst length values (1, 2, 4, 8, 16 beats)
    cp_burst_len: coverpoint arlen {
        bins single    = {0};           // ARLEN=0: 1-beat burst
        bins burst_2   = {1};           // ARLEN=1: 2-beat burst
        bins burst_4   = {3};           // ARLEN=3: 4-beat burst
        bins burst_8   = {7};
        bins burst_16  = {15};
        bins other     = default;
    }

    // Cover all burst types
    cp_burst_type: coverpoint arburst {
        bins fixed  = {2'b00};   // FIXED: same address each beat
        bins incr   = {2'b01};   // INCR: incrementing address
        bins wrap   = {2'b10};   // WRAP: wrapping burst
    }

    // Cross coverage: burst_type × burst_length combinations
    cx_burst: cross cp_burst_len, cp_burst_type;

    // Cover narrow transfers
    cp_size: coverpoint arsize {
        bins byte_transfer     = {3'b000};
        bins halfword          = {3'b001};
        bins word              = {3'b010};
        bins doubleword        = {3'b011};
    }

endgroup
```

**Relationship:**

| Metric | What it measures | Can miss |
|---|---|---|
| Code coverage | RTL lines/branches exercised | Unimplemented features, wrong functionality |
| Functional coverage | Protocol scenarios exercised | RTL bugs that don't affect the exercised scenarios |

Both are necessary but neither alone is sufficient. The standard methodology:
1. Run constrained-random simulation until functional coverage converges.
2. Use code coverage to identify dead code (may indicate unimplemented features or constraints that are too narrow).
3. Write directed tests to close remaining coverage holes.

---

### Q4. What is a reference model (or golden model) and what is a scoreboard?

**Answer:**

A **reference model** is a behavioural (often transaction-level) implementation of the DUT that computes the expected response to any input. It is typically written in a higher-level language or at a higher abstraction level than the RTL — prioritising correctness and readability over synthesis.

A **scoreboard** is a UVM component that:
1. Receives input transactions observed by input-side monitors.
2. Feeds those transactions to the reference model to compute the expected output.
3. Receives output transactions observed by output-side monitors.
4. Compares actual DUT output with expected reference model output.
5. Reports mismatches as UVM errors.

**Example — AXI DMA scoreboard:**

```systemverilog
class dma_scoreboard extends uvm_scoreboard;
    `uvm_component_utils(dma_scoreboard)
    
    // Input: descriptor writes from CPU
    uvm_analysis_imp_descriptor #(dma_descriptor_t, dma_scoreboard) descriptor_export;
    
    // Output: data written to destination memory by DMA
    uvm_analysis_imp_write #(mem_write_t, dma_scoreboard) mem_write_export;
    
    // Reference model: compute expected memory writes from descriptors
    dma_reference_model ref_model;
    
    // Queue of expected transactions
    mem_write_t expected_writes[$];
    
    function void write_descriptor(dma_descriptor_t desc);
        // Feed to reference model to predict all resulting memory writes
        mem_write_t predicted[$];
        ref_model.compute_expected_transfers(desc, predicted);
        foreach (predicted[i])
            expected_writes.push_back(predicted[i]);
    endfunction
    
    function void write_mem_write(mem_write_t actual);
        if (expected_writes.size() == 0) begin
            `uvm_error("SCOREBOARD", "Unexpected write: no pending expected transactions")
            return;
        end
        
        mem_write_t expected = expected_writes.pop_front();
        
        if (actual.addr != expected.addr || actual.data != expected.data ||
            actual.byte_en != expected.byte_en) begin
            `uvm_error("SCOREBOARD", $sformatf(
                "MISMATCH: expected addr=0x%08h data=0x%016h, got addr=0x%08h data=0x%016h",
                expected.addr, expected.data, actual.addr, actual.data))
        end else begin
            `uvm_info("SCOREBOARD", "Transaction match", UVM_HIGH)
        end
    endfunction

endclass
```

**Reference model sources:**

1. **Software model:** A C/C++ model of the IP, often derived from the design specification or a pre-existing simulator. Wrapped in DPI-C calls from the UVM scoreboard.
2. **Architectural model:** For CPU verification, the Instruction Set Architecture simulator (e.g., Arm Fast Models) serves as the golden reference.
3. **Transaction-level model:** A SystemVerilog class that models the DUT at transaction level (no clock cycles, no timing) — sufficient for functional checking.

---

## Tier 2: Intermediate

### Q5. Describe a complete UVM subsystem testbench for a memory controller. What components are needed and how do they interact?

**Answer:**

A memory controller (e.g., DDR4 controller with AXI4 slave interface and LPDDR4 PHY interface) requires:

**Subsystem testbench components:**

```
┌──────────────────────────────────────────────────────────────────────┐
│                    Memory Controller Testbench                       │
│                                                                      │
│  ┌─────────────────┐  ┌──────────────────┐  ┌──────────────────┐   │
│  │  AXI4 Master    │  │  Scoreboard       │  │  Coverage        │   │
│  │  Agent (VIP)    │  │  (AXI cmd →       │  │  (AXI protocol,  │   │
│  │                 │  │   expected DDR    │  │   DDR timing,    │   │
│  │  ┌───────────┐  │  │   transactions)   │  │   QoS fairness,  │   │
│  │  │ Sequencer │  │  └──────────────────┘  │   burst types)   │   │
│  │  └─────┬─────┘  │                        └──────────────────┘   │
│  │  ┌─────▼─────┐  │  ┌──────────────────┐                        │
│  │  │  Driver   │  │  │  DDR4 SDRAM      │                        │
│  │  └───────────┘  │  │  VIP (memory     │                        │
│  │  ┌───────────┐  │  │  model + check)  │                        │
│  │  │  Monitor  │  │  │                  │                        │
│  │  └───────────┘  │  │  ┌────────────┐  │                        │
│  └─────────────────┘  │  │  Monitor   │  │                        │
│                        │  └────────────┘  │                        │
│  ┌─────────────────┐  └──────────────────┘                        │
│  │  Register Model │                                               │
│  │  (UVM RAL)      │  ┌──────────────────┐                        │
│  │  (controller    │  │  System Memory   │                        │
│  │   config regs)  │  │  Model           │                        │
│  └─────────────────┘  │  (tracks expected│                        │
│                        │   DRAM state)    │                        │
│  ┌─────────────────┐  └──────────────────┘                        │
│  │  Virtual        │                                               │
│  │  Sequencer      │  ┌──────────────────────────────────────┐    │
│  │  (coordinates   │  │        DUT: DDR Memory Controller    │    │
│  │   AXI+DDR       │  │  AXI4 slave ──► ctrl logic ──► PHY   │    │
│  │   sequences)    │  └──────────────────────────────────────┘    │
│  └─────────────────┘                                               │
└──────────────────────────────────────────────────────────────────────┘
```

**Component responsibilities:**

**AXI4 Master Agent (VIP):**
Drives AXI read/write transactions to the memory controller. Sources can include:
- Constrained-random sequences (random address, burst length, ID combinations)
- Directed sequences (back-to-back writes to test write buffer merge)
- Multiple-master sequences (bank conflicts, QoS arbitration scenarios)

**DDR4 SDRAM VIP:**
Models the DRAM device. Both drives the DRAM electrical interface signals (DQ, DQS, CK, CMD) and checks that the memory controller issues legal DDR4 command sequences (refresh timing, tRCD, tRP, tCAS, etc.).

**System Memory Model:**
A transaction-level model of the DRAM contents, independent of DDR4 protocol. The scoreboard writes to this model when a DDR4 write is observed; reads from this model to verify DDR4 read data correctness.

**UVM RAL (Register Abstraction Layer):**
Models the controller's configuration registers. Tests use RAL to configure DRAM timing parameters, ECC mode, and QoS settings through the same AXI4 interface, exercising the register programming path.

**Virtual Sequencer:**
Coordinates sequences on multiple agents. Example: "Write 256 bytes to address 0x1000, then read them back, verifying the data" requires coordinated writes on the AXI master agent, monitoring on the DDR4 agent, and response checking in the scoreboard — all orchestrated by a virtual sequence.

---

### Q6. What is constrained-random verification? How do you write effective constraints?

**Answer:**

Constrained-random verification (CRV) uses a constraint solver to automatically generate stimulus that satisfies user-defined legal and interesting ranges for input variables. The simulator's built-in solver (SystemVerilog's `rand` + `constraint` blocks) explores the stimulus space far more efficiently than manually written directed tests.

**Basic constraint syntax:**

```systemverilog
class axi_write_transaction extends uvm_sequence_item;
    `uvm_object_utils(axi_write_transaction)

    // Randomisable fields
    rand logic [31:0] awaddr;    // write address
    rand logic [7:0]  awlen;     // burst length (0=1 beat, 255=256 beats)
    rand logic [2:0]  awsize;    // beat size (0=1B, 1=2B, 2=4B, 3=8B)
    rand logic [1:0]  awburst;   // burst type
    rand logic [63:0] wdata [];  // write data (dynamic array)

    // CONSTRAINT 1: Legal address alignment
    // AXI spec: start address must be aligned to beat size
    constraint c_alignment {
        awaddr[2:0] == 3'b000;  // always word-aligned for simplicity
        // More precise: lower (awsize) bits of awaddr must be 0
    }

    // CONSTRAINT 2: Burst length matches data array size
    constraint c_data_size {
        wdata.size() == (awlen + 1);  // N beats = awlen+1 data words
    }

    // CONSTRAINT 3: Bias toward shorter bursts (more interesting protocol corners)
    constraint c_burst_len_distribution {
        awlen dist {
            0        := 40,   // single beat: 40% probability
            [1:3]    := 30,   // 2–4 beats:   30%
            [4:15]   := 20,   // 5–16 beats:  20%
            [16:255] := 10    // long bursts:  10%
        };
    }

    // CONSTRAINT 4: Keep addresses in a meaningful range
    constraint c_addr_range {
        awaddr inside {[32'h8000_0000 : 32'hBFFF_FFFF]};
    }

    // CONSTRAINT 5: WRAP burst requires power-of-2 length
    constraint c_wrap_len {
        if (awburst == 2'b10) {  // WRAP
            awlen inside {1, 3, 7, 15};  // ARLEN = 1, 3, 7, 15 → 2, 4, 8, 16 beats
        }
    }

endclass
```

**Effective constraint design principles:**

1. **Correctness first:** Constraints must exclude illegal stimulus that would be undefined behaviour. An illegal AXI transaction (unaligned WRAP burst) will cause the DUT to behave unpredictably, making bug identification impossible.

2. **Distribution over uniform random:** Uniform random over a 32-bit address space generates no interesting corner cases. Use `dist` to bias toward boundary values, unaligned accesses, and configuration changes.

3. **Cross-coverage guided constraints:** If a coverage bin for `(burst_len=16, burst_type=WRAP)` is not being hit, add a directed constraint override:

```systemverilog
class axi_write_wrap16_test extends axi_write_transaction;
    constraint c_force_wrap16 {
        awburst == 2'b10;
        awlen   == 15;      // 16-beat WRAP burst
    }
endclass
```

4. **Solve order:** The SystemVerilog solver resolves constraints simultaneously by default. If one variable must be solved before another (e.g., burst type before length), use `solve awburst before awlen`.

5. **Weight adjustments via objections:** Instead of separate test classes, use the configuration database to pass constraint weights:

```systemverilog
// In test class:
axi_write_transaction::set_default_constraint_weight("c_burst_len_distribution", 0);
axi_write_transaction::add_constraint(new_dist_constraint);
```

---

### Q7. What is formal verification and when should it be used instead of simulation?

**Answer:**

Formal verification mathematically proves (or disproves) that a property holds for all possible inputs and all time steps — not just the inputs exercised by simulation. It exhaustively explores the state space of the design bounded by the property specification.

**Two main formal techniques:**

**Model Checking (property checking):**
Prove that an assertion holds for all reachable states. Example:

```systemverilog
// Assertion: an AXI read response must follow the read address within 64 cycles
property p_axi_read_latency;
    @(posedge clk)
    arvalid && arready |-> ##[1:64] rvalid;
endproperty

// Formal tool proves this for ALL possible input sequences
ck_axi_read_latency: assert property (p_axi_read_latency);
```

The formal tool generates a complete proof or returns a counterexample trace (the shortest input sequence that violates the property).

**Equivalence Checking:**
Proves that two designs compute identical outputs for all inputs. Used in synthesis and ECO (Engineering Change Order) flows to verify the RTL-to-netlist transformation preserved functionality.

**When to use formal vs. simulation:**

| Scenario | Formal | Simulation |
|---|---|---|
| Protocol compliance (AXI handshake rules) | Preferred | Difficult (rare corner cases) |
| Control path correctness (FSM, arbitration) | Preferred | Limited coverage |
| Arithmetic correctness (multiply unit, divider) | Preferred for small designs | Preferred for large datapaths |
| System-level performance scenarios | Not scalable | Preferred |
| Bug hunting in > 1M-gate designs | State space too large | Preferred with random stimulus |
| Safety-critical properties (no deadlock, no livelock) | Required (ISO 26262) | Not sufficient |

**Formal verification limitations:**

1. **State explosion:** Formal tools struggle with designs larger than ~500K gates (or ~100K state elements) for unbounded model checking. Techniques like abstraction, assume-guarantee reasoning, and k-induction extend the reach but require expertise.

2. **Environment modelling:** The formal tool must know the constraints on the design's inputs. Incorrect or over-constrained assume-properties can lead to vacuous proofs (the property trivially holds because inputs are over-restricted).

3. **Completeness:** Bounded model checking (BMC) proves the property for all paths up to depth k. It does not prove the property for all time — a deeper bug may exist. Unbounded proofs require k-induction or abstraction.

**Practical usage in SoC verification:**

Formal is most cost-effective for IP-level verification of control-path-dominant blocks: arbiters, interrupt controllers, power management FSMs, protocol bridges. A 2-week formal analysis of an AXI crossbar arbiter may find deadlock conditions that would take months of simulation to uncover.

---

### Q8. What is an emulation platform and how does it differ from RTL simulation?

**Answer:**

An emulation platform compiles the RTL design into a specialised hardware platform — either a reconfigurable FPGA-based array (Cadence Palladium, Synopsys ZeBu) or a custom ASIC emulator — and executes the design at hardware speeds (1–10 MHz) rather than simulator speeds (100 Hz–10 kHz for complex SoC RTL).

**Speed comparison:**

| Platform | Simulation speed | Primary use |
|---|---|---|
| RTL simulation (VCS/Xcelium) | 1 Hz – 100 kHz | Unit/subsystem verification, waveform debug |
| Transaction-level model (SystemC) | 10k – 1M cycles/sec | Architectural exploration |
| Emulation (Palladium/ZeBu) | 100 kHz – 10 MHz | Software bringup, long-running tests |
| FPGA prototype (Xilinx/Intel board) | 10 – 300 MHz | System validation, SW development |

**Emulation advantages:**

1. **Boot an OS:** A full Linux boot takes ~100M clock cycles. At 1 kHz simulation speed, that is 100,000 seconds (28 hours). At 1 MHz emulation speed: 100 seconds. This enables pre-silicon OS bringup and driver development.

2. **Hardware/software co-verification:** Real device drivers, RTOS kernels, and application code can run on the emulated SoC. Software bugs found at this stage are far cheaper to fix than post-silicon.

3. **Long-running stress tests:** Ethernet packet flow verification, audio streaming, video decode — workloads that require millions of frames or packets to exercise — are only practical in emulation.

**Emulation limitations vs. simulation:**

1. **Debug visibility:** RTL simulation provides complete waveform visibility of every signal at every cycle. Emulators have limited probe bandwidth — typically a small number of "debug probes" that trace signals to a logic analyser. Finding the root cause of a failure in emulation requires re-running with targeted probes, making debug iteration slower.

2. **Compile time:** Mapping an SoC RTL to an emulation platform takes hours to compile. Simulation starts in minutes.

3. **Accuracy:** Emulation platforms have their own timing models that may not perfectly match the simulation semantics. Races and non-determinism in the RTL are resolved differently by the emulator's synthesis.

4. **Cost:** Emulation hardware costs $1M–$10M per rack.

---

## Tier 3: Advanced

### Q9. Describe a coverage closure strategy for a complex SoC full-chip testbench. How do you manage the transition from random to directed testing?

**Answer:**

Coverage closure is the process of driving all defined functional coverage bins to their target hit counts while maintaining reasonable regression time. The challenge at full-chip level is that the state space is too large for purely random tests to converge — directed effort is required for the final 15–20% of coverage.

**Phase 1: Baseline coverage with regression (0% → 70%)**

Start with a suite of constrained-random tests running in parallel:

```
Test category                     Purpose                         Coverage contribution
──────────────────────────────────────────────────────────────────────────────────────
sanity_test                       Basic connectivity, reset        5%
axi_random_traffic                AXI protocol coverage           25%
memory_access_patterns            DRAM access type coverage       15%
interrupt_random                  Interrupt handling coverage     10%
power_state_random                DVFS transitions                 8%
dma_descriptor_random             DMA operation coverage          7%
```

After this phase, analyse coverage holes:

```
Coverage report (70% overall):
UNCOVERED BINS:
  axi_coverage.cx_burst[wrap × burst_16]:     0/100 hits  ← architectural hole
  dma_coverage.scatter_gather_chain_3:        0/50  hits  ← scenario not triggered
  power_coverage.cpu_to_off_to_on_gpu:        0/20  hits  ← complex transition
  interrupt_coverage.nested_secure_irq:       0/10  hits  ← TrustZone not tested
```

**Phase 2: Coverage-driven constraint tuning (70% → 85%)**

For bins that random testing should be able to hit but hasn't:

```systemverilog
// Force WRAP bursts with 16 beats: add weight to random test
class close_wrap16_test extends base_random_test;
    function void configure_env();
        super.configure_env();
        // Override AXI sequence to only generate WRAP16 transactions
        // for the first 1000 transactions
        uvm_config_db#(int)::set(this, "env.axi_agent.seqr.*",
            "force_wrap16_count", 1000);
    endfunction
endclass
```

**Phase 3: Directed tests for architectural holes (85% → 95%)**

Directed tests target specific scenarios that constrained-random cannot reach efficiently:

```systemverilog
// Directed test: secure interrupt during TEE world switch
class secure_irq_during_smc_test extends base_test;
    task run_phase(uvm_phase phase);
        // Step 1: Trigger an SMC from Normal World
        axi_write(PSCI_SMC_REGISTER, PSCI_CPU_SUSPEND);
        
        // Step 2: At precise cycle, inject a FIQ (secure interrupt)
        // Must be timed to hit during EL3 world-switch processing
        @(posedge clk iff (smc_in_progress));
        force_fiq_injection();
        
        // Step 3: Verify FIQ is pended correctly and serviced after SMC
        check_fiq_pending_in_icc();
        check_fiq_serviced_after_smc_return();
    endtask
endclass
```

**Phase 4: Formal assist for remaining holes (95% → 99%)**

Bins that directed simulation cannot efficiently close often have deep sequential dependencies. Formal tools can prove these properties or find counterexamples:

```tcl
# Formal tool: prove no deadlock when CPU and DMA simultaneously access same cache line
check_property p_no_cpu_dma_deadlock
# Tool returns: PROVED (bounded depth 150) or COUNTEREXAMPLE: trace file
```

**Regression management at full-chip scale:**

```
Regression tier      Frequency    Duration    Purpose
───────────────────  ───────────  ──────────  ────────────────────────────
Nightly regress      Daily        12 hours    All random + targeted tests
Weekly full regress  Weekly       48 hours    Full pattern sweep, coverage merge
Pre-tapeout regress  Once         1 week      Maximum effort, all directed + formal
```

Coverage results are merged across all regression runs using a tool's coverage database (VCS/Xcelium merge). A dashboard tracks bins per-component over time.

**Coverage sign-off criteria:**

```
Metric                              Target         Rationale
──────────────────────────────────  ─────────────  ─────────────────────────
Functional coverage (all bins)       ≥ 99%          Protocol completeness
Code coverage (line)                 ≥ 95%          Dead code identification
Code coverage (branch)               ≥ 90%          Conditional logic
Code coverage (toggle)               ≥ 85%          Net activity
FSM state coverage                   100%           All modes exercised
FSM transition coverage              ≥ 95%          All arcs exercised
Assertion pass rate                  100%           No outstanding failures
```

---

### Q10. Compare FPGA prototyping with emulation for SoC pre-silicon validation. When would you choose each?

**Answer:**

**FPGA prototyping platforms** (e.g., Cadence Protium X1, Synopsys HAPS) compile the SoC RTL to a multi-FPGA board and run at near-functional speeds. Speed: 10–300 MHz depending on design partitioning across FPGAs.

**Emulation platforms** (e.g., Cadence Palladium Z2, Synopsys ZeBu EV) compile RTL to a custom ASIC-like emulation fabric. Speed: 100 kHz–10 MHz.

**Detailed comparison:**

| Criterion | FPGA Prototype | Emulation |
|---|---|---|
| Speed | 10–300 MHz | 100 kHz–10 MHz |
| Compile time | 4–12 hours | 1–4 hours |
| Debug visibility | Limited (ChipScope/ILA) | Better (ICE debug environment) |
| RTL fidelity | Some constructs not synthesisable | Higher fidelity; supports more RTL constructs |
| Power modelling | Approximate (FPGA power ≠ ASIC power) | Not a power platform either |
| Memory modelling | External DDR on board | On-platform memory models |
| Board bring-up | Requires hardware bringup | Software-only setup |
| Cost | $100k–$2M | $1M–$10M |
| Use case primary | Software development, performance validation | OS bringup, long-running tests, power state testing |

**When to choose FPGA prototype:**

1. **Customer software development:** External software teams need to develop and debug device drivers months before silicon. FPGA speed (100+ MHz) allows running actual application software.

2. **Performance validation:** Measuring latency and throughput of memory subsystem, network interfaces, or display pipelines at realistic data rates requires MHz-range simulation.

3. **Board-level integration testing:** Connecting the prototype board to real external peripherals (DDR DRAM, PCIe endpoint, HDMI monitor) for system-level validation.

4. **Late-project schedule pressure:** If the design is near tapeout, FPGA compiles are faster to set up than emulation; software teams can start immediately.

**When to choose emulation:**

1. **Early OS and firmware bringup:** OS boot requires a stable, low-latency debug environment. Emulators provide ICE (In-Circuit Emulation) debug access to all registers without recompiling.

2. **Power management verification:** DVFS state machine testing requires precise cycle-level control of power signals and simulation of PMIC behaviour — emulation's virtual PMIC models support this better than FPGA.

3. **Fault injection and security testing:** Emulators support precision fault injection (corrupt a specific memory location at a specific cycle) to test error recovery code paths.

4. **Regression regression:** Running 10,000+ test cases on an emulator for coverage is practical; FPGA prototypes require more complex test infrastructure.

**Hybrid strategy (used in production SoC teams):**

```
Timeline (months before tapeout):
────────────────────────────────────────────────────────────
  -18 months: Start emulation setup; OS and driver bringup begins
  -12 months: FPGA prototype board ready; customer SW team access
  -9  months: Emulation regression for all system scenarios (power, security)
  -6  months: FPGA at-speed performance measurements (memory BW, latency)
  -3  months: Emulation tapeout regression (final coverage closure)
   0  months: Tapeout
  +3  months: First silicon validation; compare against emulation baselines
```

The emulation and FPGA platforms serve complementary roles. Leading SoC teams run both in parallel with different engineering teams and test suites.

---

## Quick Reference: Key Terms

| Term | Definition |
|---|---|
| UVM | Universal Verification Methodology (IEEE 1800.2); standard class library for SystemVerilog testbenches |
| Testbench | The verification environment surrounding the DUT; drives stimulus, checks responses |
| Agent | UVM component modelling one interface; contains sequencer, driver, and monitor |
| Sequence | Generator of transaction objects encoding a test scenario |
| Scoreboard | Compares DUT actual outputs against reference model expected outputs |
| Functional coverage | Measures whether verification has exercised specified scenarios (covergroups, coverpoints, bins) |
| Code coverage | Measures which RTL lines, branches, and nets were exercised (automatic) |
| Constrained-random | Verification approach using constraint-solving to auto-generate legal, interesting stimulus |
| Reference model | Behavioural implementation of the DUT computing expected outputs; often in C/C++ |
| UVM RAL | Register Abstraction Layer; models DUT register map; enables register-level test sequences |
| Formal verification | Mathematical proof that a property holds for all inputs and all time steps |
| Property | SVA assertion expressing a temporal requirement (e.g., "valid ∧ ready → data captured next cycle") |
| Emulation | RTL compiled to hardware emulation fabric; runs at 100 kHz–10 MHz; enables OS bringup |
| FPGA prototype | RTL mapped to FPGA arrays; runs at 10–300 MHz; enables SW development and performance measurement |
| Coverage closure | The process of driving all coverage bins to their target counts through test execution and directed tests |
| Regression | Automated repeated execution of the full test suite; typically nightly or weekly |
| VIP | Verification IP; pre-verified agent/environment for standard protocols (AXI, PCIe, USB, DDR) |
| DPI-C | Direct Programming Interface; SystemVerilog mechanism to call C functions from testbenches |
