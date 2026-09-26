# Problem 03: SoC-Level Verification Test Plan

## Problem Statement

You are the lead verification architect for a mid-range mobile SoC. The chip contains:

- **CPU subsystem:** 4× Cortex-A55 cores, 64 KB L1 I + 64 KB L1 D and 256 KB private L2 (per core), CCI-500 coherent interconnect
- **GPU subsystem:** 4-core Mali-G57, 512 KB GPU L2
- **Memory subsystem:** Dual-channel LPDDR5 controller, 4 MB system L3 cache (DSU)
- **DMA subsystem:** 8-channel DMA-330 controller
- **Connectivity:** USB 3.0 (device mode), SDMMC, UART×4, SPI×3, I2C×6
- **Multimedia:** H.265 video decoder (HW), ISP (camera, 48 MP), display controller (4K@60)
- **Security:** TrustZone, hardware AES/SHA, secure key store, TRNG
- **Power management:** 9 power domains, DVFS (CPU, GPU), retention registers

The design team has 18 months to tapeout. You have 12 verification engineers and access to simulation, formal tools, a Palladium emulator, and an FPGA prototype board.

**Questions:**

1. Create a hierarchical verification plan covering IP-level, subsystem-level, and full-chip verification. For each level, define the scope, methodology, tools, and sign-off criteria.

2. Define the full-chip functional coverage model. What scenarios must be covered at the chip level (not IP level)?

3. Assign the 12 verification engineers to tasks and define the schedule milestone from project start to tapeout.

4. Identify the top five highest-risk verification items for this SoC and describe the specific strategy to mitigate each.

5. Define the simulation-to-emulation handoff criteria. At what point is it more efficient to move scenarios from simulation to the emulation platform?

---

## Worked Solution

### Step 1: Hierarchical Verification Plan

**Level 1: IP/Unit Verification**

Each IP block is verified in isolation against its specification.

```
Block              Methodology    VIP needed           Coverage target    Duration
─────────────────────────────────────────────────────────────────────────────────
CPU cluster        Simulation     Arm Fast Models      95% FC, 90% CC     8 weeks
                   (UVM + ISA     (golden reference)
                   simulator)
                   
GPU                Simulation     GPU driver model     90% FC, 85% CC     6 weeks
                   (UVM)          + OpenCL reference
                   
LPDDR5 ctrl        Simulation     JEDEC LPDDR5 VIP     99% FC, 95% CC     5 weeks
                   (UVM)
                   
DMA-330            Simulation     AXI4 master/slave    99% FC, 95% CC     4 weeks
                   (UVM + formal) VIP
                   
USB 3.0            Simulation     USB 3.0 VIP (Mentor/ 99% FC, 90% CC    6 weeks
                   (UVM)          Synopsys)
                   
H.265 decoder      Simulation     Bit-stream generator, 95% FC, 90% CC   5 weeks
                   (UVM)          reference decoder
                   
ISP                Simulation     Camera model,        90% FC, 85% CC     5 weeks
                   (UVM)          image reference
                   
Security (AES,     Simulation     NIST test vectors,   99% FC, 95% CC     4 weeks
SHA, TRNG)         + Formal       formal properties
                   
Display ctrl       Simulation     DSI/HDMI VIP,        95% FC, 90% CC     4 weeks
                   (UVM)          pixel checker
                   
Power management   Simulation     PMIC model,          95% FC, 90% CC     5 weeks
(PMU, isolation)   + Formal       UPF-aware sim
```

**IP-level sign-off criteria:**
- Functional coverage (all covergroups): ≥ target per block
- Code coverage (line): ≥ 92%
- Code coverage (branch): ≥ 88%
- Zero unresolved UVM_ERROR or UVM_FATAL messages
- All SVA assertions passing (zero assertion failures)
- Formal: all properties proved or bounded to depth ≥ 50 cycles

---

**Level 2: Subsystem Verification**

Subsystem testbenches verify integration of multiple IPs sharing a common interconnect.

```
Subsystem           IPs included                   Primary scenarios        Duration
──────────────────────────────────────────────────────────────────────────────────────
CPU memory          4× CPU cores, L2 caches,        Cache coherency,         6 weeks
subsystem           CCI-500, LPDDR5 ctrl,           coherent DMA,
                    DMA-330, L3 DSU                 multi-core races,
                                                    DVFS transitions
                                                    
Multimedia          ISP, H.265 decoder,             Camera → process →       5 weeks
pipeline            display ctrl, DMA               display dataflow,
                                                    frame rate control,
                                                    buffer overflow
                                                    
Security subsystem  TrustZone, AES, SHA,            Secure boot, TZASC       5 weeks
                    TRNG, key store, PMU             programming, world
                                                    switching, key
                                                    provisioning
                                                    
Power management    PMU, all 9 power domains,       Power up/down seq,       5 weeks
subsystem           isolation cells, level          DVFS ramp, retention
                    shifters, PMIC model            save/restore
                                                    
Connectivity        USB, SDMMC, UART, SPI,          Concurrent transfers,    4 weeks
subsystem           I2C, interrupt ctrl, DMA        interrupt handling,
                                                    FIFO overflow
```

**Subsystem sign-off criteria:**
- All IP-level coverage targets maintained in integrated context
- Subsystem-specific functional coverage model: ≥ 95%
- Integration-specific scenarios: 100% coverage (directed tests)
- Power management: all domain transitions simulated at least once (100% transition coverage)
- No protocol violations reported by VIP monitors

---

**Level 3: Full-Chip Verification**

```
Methodology         Scenarios                              Tools
──────────────────────────────────────────────────────────────────────
UVM full-chip TB    End-to-end data paths,                VCS/Xcelium
                    cross-domain interrupts,              + VIP suite
                    JTAG DFT access
                    
Formal (focused)    Power state machine deadlock,         JasperGold
                    security property (NS bit),           /Questa Formal
                    arbiter liveness
                    
Emulation           OS boot (Linux 5.15),                 Palladium Z2
                    DRM playback, camera pipeline,
                    long-running stress tests
                    
FPGA prototype      Performance benchmarks,               Protium X1
                    customer SW validation,
                    DDR bandwidth/latency
```

**Full-chip sign-off criteria:**

```
Criterion                                           Target
──────────────────────────────────────────────────────────────────
Full-chip functional coverage (all bins)            ≥ 95%
Code coverage (line, full chip)                     ≥ 88%
Code coverage (branch, full chip)                   ≥ 85%
Security properties (formal): all proved            100%
Power state transitions: all paths exercised        100%
Emulation: Linux boots to idle, no hangs            Pass
Emulation: 24-hour stress test (no crash)           Pass
DFT: stuck-at coverage                              ≥ 99%
DFT: transition fault coverage                      ≥ 95%
MBIST: all SRAM macros pass                         100%
SVA assertion pass rate (all simulations)           100%
```

---

### Step 2: Full-Chip Functional Coverage Model

The full-chip coverage model captures scenarios that only make sense at the integration level — they require multiple subsystems interacting.

**Coverage group 1: Cross-domain coherency**

```systemverilog
covergroup cg_cache_coherency @(posedge clk);
    
    // CPU and GPU simultaneously accessing same cache line
    cp_cpu_gpu_conflict: coverpoint (cpu_l2_request && gpu_l2_request &&
                                     cpu_request_addr == gpu_request_addr) {
        bins conflict_occurs = {1'b1};
    }
    
    // DMA transfer to/from CPU-cacheable region (coherent DMA)
    cp_dma_cache_interaction: coverpoint dma_axi_arcache[3:2] {
        bins non_cacheable = {2'b00};   // Normal Non-Cacheable
        bins write_back    = {2'b11};   // Write-Back, Write-Allocate (coherent)
    }
    
    // Multiple CPUs sharing a dirty cache line (snoop required)
    cp_snoop_type: coverpoint snoop_filter_type {
        bins read_unique      = {SNOOP_READ_UNIQUE};
        bins read_shared      = {SNOOP_READ_SHARED};
        bins clean_invalid    = {SNOOP_CLEAN_INVALID};
        bins make_invalid     = {SNOOP_MAKE_INVALID};
    }
    
endgroup
```

**Coverage group 2: Power state transitions**

```systemverilog
covergroup cg_power_transitions @(posedge pmu_clk);
    
    // Every possible domain → state transition
    cp_cpu_state: coverpoint cpu_power_state {
        bins on         = {CPU_ON};
        bins off        = {CPU_OFF};
        bins retention  = {CPU_RETENTION};
    }
    
    cp_gpu_state: coverpoint gpu_power_state {
        bins on         = {GPU_ON};
        bins off        = {GPU_OFF};
    }
    
    // Key cross: CPU off while GPU on (GPU computes without CPU involvement)
    cx_cpu_gpu: cross cp_cpu_state, cp_gpu_state {
        // Must hit: CPU_OFF × GPU_ON (background GPU compute)
        bins cpu_off_gpu_on = binsof(cp_cpu_state.off) &&
                              binsof(cp_gpu_state.on);
    }
    
    // DVFS transitions: all OPP level changes for CPU
    cp_cpu_opp_change: coverpoint cpu_opp_transition {
        bins opp_0_to_1 = (OPP_0 => OPP_1);    // 0.55V/800MHz → 0.65V/1.2GHz
        bins opp_1_to_2 = (OPP_1 => OPP_2);
        bins opp_2_to_3 = (OPP_2 => OPP_3);    // 0.9V/2.0GHz → 1.05V/2.4GHz
        bins opp_3_to_2 = (OPP_3 => OPP_2);    // downscale
        bins opp_2_to_1 = (OPP_2 => OPP_1);
        bins opp_1_to_0 = (OPP_1 => OPP_0);
    }
    
endgroup
```

**Coverage group 3: Security world transitions**

```systemverilog
covergroup cg_trustzone @(posedge clk);
    
    // SMC call types from Normal World
    cp_smc_type: coverpoint smc_function_id {
        bins psci_cpu_suspend = {PSCI_CPU_SUSPEND};
        bins psci_cpu_off     = {PSCI_CPU_OFF};
        bins psci_cpu_on      = {PSCI_CPU_ON};
        bins tee_invoke_cmd   = {OPTEE_SMC_CALL_WITH_ARG};
        bins fast_smc         = {[32'hBF00_0000:32'hBFFF_FFFF]};
    }
    
    // NS bit during memory accesses (must see both secure and non-secure)
    cp_mem_ns: coverpoint axi_mem_ns_bit {
        bins secure     = {1'b0};
        bins non_secure = {1'b1};
    }
    
    // World at time of interrupt arrival
    cp_irq_world: coverpoint (irq_pending && (current_world == SECURE_WORLD)) {
        bins irq_in_secure_world = {1'b1};
        bins irq_in_normal_world = {1'b0};
    }
    
    // FIQ during SMC (secure interrupt during world switch)
    cp_fiq_during_smc: coverpoint (fiq_pending && smc_in_progress) {
        bins fiq_during_smc_occurs = {1'b1};
    }
    
endgroup
```

**Coverage group 4: Interrupt handling**

```systemverilog
covergroup cg_interrupt_handling @(posedge clk);
    
    // Interrupt source types
    cp_irq_source: coverpoint irq_source_id {
        bins dma_done        = {IRQ_DMA_DONE};
        bins display_vsync   = {IRQ_DISP_VSYNC};
        bins usb_event       = {IRQ_USB};
        bins timer_overflow  = {IRQ_TIMER};
        bins sdmmc_transfer  = {IRQ_SDMMC};
        bins gpu_job_done    = {IRQ_GPU_JOB};
    }
    
    // Concurrent interrupt from multiple sources
    cp_concurrent_irq: coverpoint ($countones(irq_pending_vector) > 1) {
        bins multiple_irq = {1'b1};
    }
    
    // Interrupt arriving during world switch (stress test)
    cx_irq_world_switch: cross cp_irq_source, cp_irq_world;
    
endgroup
```

**Full-chip coverage model total bin count (approximate):**

| Coverage group | Bins | Notes |
|---|---|---|
| Cache coherency | 120 | All snoop types × access types |
| Power transitions | 85 | All OPP transitions, domain combinations |
| Security | 60 | SMC types, NS bit, world combinations |
| Interrupt handling | 150 | All sources × contexts |
| DMA end-to-end | 200 | All channel combinations, burst types |
| Multimedia pipeline | 100 | Frame sizes, formats, concurrent streams |
| System reset (warm/cold) | 30 | All reset scenarios |
| **Total** | **~745** | Manageable full-chip coverage model |

---

### Step 3: Engineer Assignment and Schedule

**Team of 12 verification engineers over 18 months:**

```
Engineer    Role                           Phase 1       Phase 2        Phase 3
           (months 1–6)   (months 7–12)  (months 13–18)
────────────────────────────────────────────────────────────────────────────────────
VE1        CPU cluster lead   CPU IP TB        CPU subsystem  Full-chip CPU
VE2        CPU cluster        CPU IP TB        CPU subsystem  Power verification
VE3        Memory/coherency   LPDDR5 IP TB     Memory subsys  Emulation/FPGA
VE4        DMA + interconnect DMA-330 IP TB    DMA subsystem  Full-chip DMA
VE5        GPU                GPU IP TB        GPU subsystem  Full-chip GPU
VE6        Multimedia          ISP IP TB        Multimedia     Emulation videos
           pipeline           + H.265 IP TB    subsystem
VE7        Security lead       AES/SHA TB       Security       Formal security
                              + TZ setup        subsystem      + full-chip sec
VE8        Power management    PMU IP TB        Power mgmt     DVFS full-chip
VE9        Connectivity        USB IP TB        Connectivity   Full-chip periph
                              + SDMMC IP TB     subsystem
VE10       Infrastructure      TB infra,        Full-chip TB   Coverage closure
           + full-chip lead    VIP integration  bring-up       director
VE11       Formal + SVA        SVA for all IPs  Formal subsys  Formal full-chip
VE12       Emulation/FPGA      Emulation setup, Emulation      FPGA prototype +
           + post-tapeout prep (parallel)        regressions    SI validation
```

**Schedule milestones:**

```
Month  Milestone                                     Exit criteria
──────────────────────────────────────────────────────────────────────────────────
  2    IP testbench RTL freeze                        All IP TBs running, no DRC errors
  4    IP verification complete: DMA, PMU, crypto     Coverage targets met, zero UVM_ERROR
  6    IP verification complete: CPU, GPU, memory     Coverage targets met
       First subsystem TB running (memory subsys)
  8    Subsystem verification complete: memory,       All subsystem scenarios pass
       connectivity                                    subsystem coverage ≥ 90%
 10    Subsystem verification complete: multimedia,   Security scenarios pass
       security, power management                     Formal security: all proved
 11    Full-chip UVM testbench running, first tests   SoC boots to BL1 in simulation
 13    Full-chip coverage baseline: 70%               Random regression converged
 14    Emulation platform ready; Linux boots          Linux boots, no hangs
 15    Full-chip coverage: 90%                        Directed tests for holes
 16    DFT sign-off: SA 99%, transition 95%           ATPG complete, MBIST pass
 17    Full-chip coverage: 95% + formal done          All formal properties proved
       Emulation stress test: 24 hours                Zero hangs or crashes
 18    TAPEOUT                                        All sign-off criteria met
```

---

### Step 4: Top Five Highest-Risk Verification Items

**Risk 1: Cache coherency between CPU, GPU, and DMA**

*Why high risk:* Cache coherency bugs are notoriously difficult to find with random testing. A coherency violation may produce incorrect computation results (not a visible crash) that only appear with specific memory access patterns across multiple threads. These bugs have caused significant post-silicon respins.

*Mitigation strategy:*
1. Deploy ACE-compliant AXI4 VIP (Arm, Synopsys VC Verification IP) with built-in coherency checker for CCI-500. The VIP models the full MOESI state machine for every cache line.
2. Implement a memory model scoreboard that tracks the coherent state of every address — any read that observes stale data is flagged immediately.
3. Write directed tests for every hazard scenario: CPU write / GPU read (no invalidation), DMA bypass of cache (CMO required), write-after-read with concurrent snoops.
4. Formal: prove the CCI-500 coherency protocol properties using the existing Arm formal verification kit for CCI.
5. Allocate VE3 specifically to coherency for months 7–14.

**Risk 2: Power domain sequencing bugs causing corruption or latch-up**

*Why high risk:* Power management bugs often manifest as low-probability events (wrong sequencing under specific timer/interrupt coincidence). On silicon, they cause either immediate failures (latch-up, device damage) or data corruption that is hard to attribute. UPF simulation may miss bugs that require cycle-accurate timing.

*Mitigation strategy:*
1. Use UPF-aware simulation (Synopsys MVSIM) throughout development — not just at tapeout.
2. Dedicated power domain testbench sequences for every legal and illegal transition (attempt illegal transition, verify PMU rejects it without damage).
3. Inject power switch delays: simulate MTCMOS switch with a programmable settling time (10 ns – 10 μs). Verify that isolation holds throughout.
4. Formal: verify all PMU state machine properties — "domain only powers on when all prerequisites are met."
5. Emulation: Run a 100,000-cycle power state stress test (random power events) on Palladium, monitoring supply voltage waveforms via virtual PMIC model.

**Risk 3: TrustZone TZASC misconfiguration allowing Normal World to access Secure DRAM**

*Why high risk:* A single TZASC misconfiguration can completely defeat the security architecture — Normal World code can read/write TEE memory. This is a Critical-severity silicon bug that would require an immediate security patch or respin.

*Mitigation strategy:*
1. Formal verification of all TZASC properties: "any Normal World AXI transaction to a Secure region is rejected with SLVERR" — prove this for all possible transaction types and addresses.
2. Write a comprehensive security testbench that attempts every class of illegal access from Normal World: read/write to secure DRAM, access to secure peripherals, DMA device targeting secure DRAM.
3. Security VE (VE7) performs dedicated red-team testing: treat the DUT as a black box and attempt to escalate privileges using every known TrustZone attack technique.
4. Verify TZASC lock: after BL2 configures and locks the TZASC, confirm that attempting to reconfigure it from Normal World is rejected.

**Risk 4: H.265 video decoder specification compliance and corner cases**

*Why high risk:* The H.265 bitstream specification has hundreds of profile/level combinations, NAL unit types, and error resilience features. An incomplete decoder will cause playback failures on video content from streaming services — an immediately visible product defect. Reference decoders are complex and may have their own bugs.

*Mitigation strategy:*
1. Use the JCT-VC H.265 conformance bit-stream suite (official ISO test vectors) as directed tests. All conformance bit-streams must decode identically to the reference decoder.
2. Generate constrained-random H.265 bit-streams using a bitstream fuzzer (Radamsa, or custom H.265-aware fuzzer). Feed outputs to both DUT and reference decoder; flag any divergence.
3. Test at all supported profiles (Main, Main10, Main Still Picture) and levels (up to Level 6.2 for 8K).
4. Test error resilience: corrupted NAL units, out-of-sequence slices, DPB (decoded picture buffer) overflow.

**Risk 5: DVFS voltage/frequency transition causing silent data corruption**

*Why high risk:* If the CPU begins operating at a new (higher) frequency before the supply voltage has reached the required level, setup timing violations cause flip-flops to capture incorrect values. This is a functional bug that produces wrong computation results with no error flag — extremely difficult to detect post-silicon.

*Mitigation strategy:*
1. Model the PMIC voltage ramp using a parameterised model with min/max slew rate (based on PMIC datasheet: 5 mV/μs – 25 mV/μs). Verify correct operation at both extremes.
2. Formal: prove that the PMU FSM requires VDD_PGOOD assertion before enabling the higher frequency clock. This must hold for every possible input sequence.
3. Directed test: attempt to transition frequency before voltage settles. Verify PMU blocks the transition.
4. At-speed simulation: run the SoC at each (V, F) OPP point with 5% voltage undershot (VDD = target − 5%). Verify no timing violations in post-layout STA.
5. Post-silicon: perform DVFS characterisation with voltage margining to confirm timing closure matches pre-silicon predictions.

---

### Step 5: Simulation-to-Emulation Handoff Criteria

The decision to move a test scenario from RTL simulation to emulation is based on runtime, debug requirements, and scenario complexity.

**Quantitative handoff thresholds:**

```
Criterion                           Simulation        Move to emulation
──────────────────────────────────────────────────────────────────────────────
Scenario runtime at sim speed        < 100K cycles     > 1M cycles
Waveform debug required?             Yes               No (or post-analysis)
Scenario requires OS execution       No                Yes (always)
Real-time constraints (video FPS)    Cannot achieve    Can achieve at 1–10 MHz
Number of iterations needed          < 100             > 10,000 (stress tests)
Synthesis/compile acceptable?        No (fast turnaround) Yes (4–12h is OK)
```

**Specific scenarios and their platform:**

```
Scenario                               Platform    Justification
──────────────────────────────────────────────────────────────────────────────────
AXI protocol violation test            Simulation  Requires waveform to debug
TZASC misconfiguration test            Simulation  Security check, needs waveforms
Single cache coherency transaction     Simulation  Debug needs cycle-level visibility
Power domain power-up sequence         Simulation  100K cycles, need waveform
Linux boot to idle                     Emulation   100M+ cycles, no per-cycle debug
Android application startup            Emulation   Requires OS
24-hour memory stress test             Emulation   Billions of cycles
H.265 decode of 1-minute video         Emulation   60 × 30fps × 1M cycles/frame
DDR bandwidth benchmark                Emulation   Statistical, many frames
DVFS ramp at OPP0→OPP3→OPP0           Simulation  Precise timing needed
Camera capture → ISP → display flow    Emulation   Full pipeline, many frames
USB enumeration handshake              Simulation  Protocol timing, short (< 10K cycles)
USB bulk transfer of 100 MB file       Emulation   Long duration, functional check
Power management 24h standby stress    Emulation   Requires realistic OS workload
Customer SW driver validation          FPGA        Real external hardware needed
DDR timing margin characterisation     FPGA        At-speed, silicon-speed LPDDR5
```

**Emulation readiness gate:**

Before moving scenarios to emulation, the following must be true:
1. Full-chip RTL simulation passes sanity test suite (boot to BL1 in simulation).
2. No unresolved UVM_ERROR in simulation regression (emulation debug is expensive).
3. Emulation compile completes without DRC errors (RTL must be synthesis-clean).
4. Emulation environment validated: virtual PMIC model, memory model, UART console working.
5. At least one engineer (VE12) trained on the Palladium debug environment.

The risk of moving to emulation prematurely: a bug that would take 10 minutes to debug in simulation may take 2 days in emulation (recompile, limited probes, no full waveform).

---

## Summary Table

| Parameter | Value |
|---|---|
| Verification levels | 3 (IP, subsystem, full-chip) |
| IP blocks requiring dedicated testbenches | 10 |
| Subsystems | 5 |
| Total verification engineers | 12 |
| Schedule to tapeout | 18 months |
| Full-chip functional coverage target | ≥ 95% |
| SA fault coverage target | ≥ 99% |
| Transition fault coverage target | ≥ 95% |
| Emulation handoff threshold | > 1M cycles or OS required |
| Highest-risk items | Coherency, power sequencing, TZ security, H.265, DVFS |

## Key Takeaways

1. **Bug-find rate drops exponentially with verification level.** A bug found at IP level costs 1x to fix; the same bug found at full-chip costs 10–50x; post-silicon costs 100–1000x. Invest heavily in IP-level verification.

2. **Coverage without a plan is noise.** Define a meaningful full-chip coverage model before running a single simulation — coverage bins must map directly to specification requirements, not to convenient RTL constructs.

3. **The five highest-risk items deserve disproportionate attention.** Identify them early, assign your best engineers, and apply multiple complementary techniques (simulation + formal + directed tests).

4. **Emulation is not a substitute for simulation.** Emulation is for scenarios that simulation cannot reach; simulation is for scenarios that need waveforms. Using emulation for debugging is expensive. Gate the transition.

5. **Schedule risk comes from late integration.** The most common programme failure is IPs completing verification late, delaying subsystem integration, compressing full-chip time. Manage IP completion milestones actively.
