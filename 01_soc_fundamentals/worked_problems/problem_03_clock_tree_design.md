# Problem 03: Clock Tree Design

## Problem Statement

Design a complete clock and reset architecture for a multi-domain mobile application SoC. The SoC must support DVFS on the CPU cluster and must pass a full CDC structural check.

**SoC specification:**

| Domain         | Target frequency   | Source          | DVFS support | Notes                          |
|----------------|--------------------|-----------------|--------------|--------------------------------|
| CPU cluster    | 1600 MHz (max)     | CPU PLL         | Yes          | Steps: 400/800/1200/1600 MHz   |
| GPU            | 850 MHz (max)      | GPU PLL         | Yes          | Steps: 200/400/600/850 MHz     |
| System NOC     | 400 MHz            | SYS PLL         | No           | Fixed; all masters route here  |
| Video codec    | 300 MHz            | SYS PLL / 4     | No           | Derive from SYS PLL div-4      |
| APB peripheral | 100 MHz            | SYS PLL / 16    | No           | All low-speed peripherals      |
| Always-on (AO) | 32.768 kHz / 24 MHz| XO              | No           | RTC, PMU, wakeup logic         |
| DDR PHY        | 800 MHz (DDR1600)  | DDR PLL         | No           | Separate DDR PLL               |

**Constraints:**

1. Reference oscillator: 24 MHz crystal.
2. Total PLL count: maximum 3 (cost constraint).
3. SYS PLL must serve NOC, Video, and APB via clock dividers.
4. APB clock must be derived by integer division from SYS PLL with no additional jitter.
5. CPU domain must be able to transition between DVFS states without corrupting architectural state.
6. DDR PHY requires a separate isolated PLL (jitter < 5 ps RMS on DDR clock).
7. Every clock domain crossing must use a recognised CDC structure.
8. Reset de-assertion must be synchronised per domain.
9. APB domain must not exit reset before the NOC domain (dependency: APB slaves must be ready before NOC routes traffic to them).

---

## Design Requirements

1. Compute PLL VCO frequencies and divider settings for all clocks.
2. Draw the clock distribution hierarchy.
3. Design the glitch-free DVFS clock switch for the CPU domain.
4. List every CDC crossing in the system and specify the synchronisation method for each.
5. Design the reset sequencer, showing the per-domain reset synchroniser implementation.
6. Identify the clock gating strategy for each domain.

---

## Clock Tree Architecture

### Step 1 — PLL Configuration

With only 3 PLLs available: CPU PLL, GPU PLL, SYS PLL. DDR PLL is additional (justified as a hard IP requirement for DDR timing).

**CPU PLL:**

```
Target: 1600 MHz maximum output (VCO runs at 3200 MHz with output divider /2 for flexibility)

F_out = F_ref * M / (N * OD)

F_ref = 24 MHz
Choose: N=1, M=133, OD=2  =>  24 * 133 / (1 * 2) = 1596 MHz ≈ 1600 MHz (close enough)
Better: N=3, M=200, OD=1  =>  24 * 200 / (3 * 1) = 1600 MHz (exact)

CPU PLL output: 1600 MHz
DVFS divider:
  /1  = 1600 MHz  (max performance)
  /2  =  800 MHz
  /4  =  400 MHz  (minimum active)
  Switch done via programmable output divider or via clock mux (see DVFS section)
```

**GPU PLL:**

```
Target: 850 MHz
N=1, M=71, OD=2  =>  24 * 71 / (1 * 2) = 852 MHz ≈ 850 MHz (acceptable, within 0.3%)
DVFS divider:
  /1  = 852 MHz
  /2  = 426 MHz
  /4  = 213 MHz
```

**SYS PLL:**

```
Target: 1600 MHz VCO to derive all of NOC/Video/APB
  NOC   = 400 MHz: SYS PLL / 4 = 400 MHz
  Video = 300 MHz: Requires 300 MHz. 1600/4 = 400, 1600/5 = 320, 1600/6 = 267.
                   Use 300 MHz target: N=1, M=25, OD=2 => 24*25/2 = 300 MHz VCO=600 MHz.
                   Then NOC: 300/1=300 (too slow). Constraint requires NOC@400 MHz.
                   Revise: set SYS PLL to 2400 MHz VCO (N=1, M=100, OD=1 = 2400 MHz).
                     NOC:   2400/6  = 400 MHz ✓
                     Video: 2400/8  = 300 MHz ✓
                     APB:   2400/24 = 100 MHz ✓
                   OD values: 6, 8, 24 — all integer, no jitter penalty.

SYS PLL: F_ref=24 MHz, N=1, M=100, OD=1 => 2400 MHz internal
  Derived clocks:
    SYS_CLK_NOC   = 2400/6  = 400 MHz
    SYS_CLK_VIDEO = 2400/8  = 300 MHz
    SYS_CLK_APB   = 2400/24 = 100 MHz
```

**DDR PLL (separate hard IP):**

```
Target: 800 MHz (DDR1600 — double data rate)
N=1, M=100, OD=3 => 24*100/3 = 800 MHz
Jitter: hard PLL specification < 5 ps RMS (process-guaranteed by foundry PLL IP)
This PLL is isolated on its own power supply ring to prevent substrate noise coupling.
```

### Step 2 — Clock Distribution Hierarchy

```
                     24 MHz crystal XO
                     |
         +-----------+-----------+-----------+
         |           |           |           |
     [CPU PLL]   [GPU PLL]   [SYS PLL]   [DDR PLL]
     1600 MHz     852 MHz    2400 MHz     800 MHz
         |           |           |           |
      [/1-/4]     [/1-/4]   [/6][/8][/24]   |
         |           |       |    |    |     |
      1600/800  852/426  [400][300][100]  [800]
      400 MHz   213 MHz   MHz  MHz  MHz   MHz
         |           |       |    |    |     |
      [CG][CTS]  [CG][CTS] [CG] [CG] [CG] [CTS]
         |           |      [CTS][CTS][CTS]   |
      CPU cores   GPU        NOC  VID  APB  DDR PHY
      L1 L2 L3   shader     xbar codec uart  DQ/DQS
                 tensor     DMA  ISP  spi   strobes

CG = ICG (integrated clock gate, gated by PMU when domain inactive)
CTS = Clock tree synthesis (balanced buffer tree, target skew < 50 ps)
```

---

## DVFS Clock Switch Design

The CPU must transition between 400/800/1200/1600 MHz without glitching the clock or corrupting state.

### DVFS Transition Procedure

```
Transition from 1600 MHz to 800 MHz:

  Phase 1 — Prepare slow clock:
    The CPU PLL output divider is pre-configured to /2 but not yet active.
    A bypass path from SYS_CLK (400 MHz) is available as a safe intermediate.

  Phase 2 — Switch CPU clock to bypass:
    1. Software (PMU firmware in AO domain) asserts cpu_clk_bypass_req.
    2. Glitch-free MUX (GFM) transitions CPU clock source from PLL to bypass (24 MHz XO
       or SYS_CLK_NOC at 400 MHz). This takes 2 cycles of the slower clock.
    3. CPU runs at lower speed — still correct, just slower.

  Phase 3 — Reprogram PLL divider:
    1. Write new divider value to PLL configuration register.
    2. PLL remains locked at 1600 MHz VCO; only the output divider changes.
    3. For M/N reprogramming (full relock): wait for PLL_LOCK signal (10-50 µs).

  Phase 4 — Switch back to PLL:
    1. Assert cpu_clk_pll_req.
    2. GFM transitions CPU clock source from bypass back to PLL output.
    3. CPU now running at 800 MHz.

  Phase 5 — Voltage adjustment (if stepping down):
    4. PMU reduces V_DD_CPU after frequency reduction is complete.
    (For frequency increase: V_DD is raised in Phase 1 before Phase 2.)
```

### Glitch-Free Multiplexer Implementation

```systemverilog
// Glitch-free 2-input clock multiplexer
// Ensures no partial clock pulses on output during source switching.
// Uses a latch-based handshake: each source disables in its own clock domain
// before the output switches.

module glitch_free_clk_mux (
    input  wire clk_a,       // Clock A (e.g., bypass clock, 400 MHz)
    input  wire clk_b,       // Clock B (e.g., PLL clock, 1600 MHz)
    input  wire sel,         // 0 = select clk_a, 1 = select clk_b
    output wire clk_out
);

    reg  en_a_latch, en_b_latch;
    wire en_a, en_b;

    // Latch for clock A's enable, transparent when clk_a is LOW
    // Ensures en_a transitions only during the LOW phase of clk_a (prevents glitch)
    always @(*) begin
        if (!clk_a) en_a_latch <= (~sel) & (~en_b_latch);
    end

    // Latch for clock B's enable, transparent when clk_b is LOW
    always @(*) begin
        if (!clk_b) en_b_latch <= sel & (~en_a_latch);
    end

    assign en_a   = en_a_latch;
    assign en_b   = en_b_latch;

    // Output: gated versions of each clock OR'd together.
    // At any given time, only one branch is enabled (handshake ensures mutual exclusion).
    assign clk_out = (clk_a & en_a) | (clk_b & en_b);

    // Timing constraint note:
    // set_false_path -from [get_ports sel] -to [get_cells en_a_latch]
    // set_false_path -from [get_ports sel] -to [get_cells en_b_latch]
    // The sel signal is an asynchronous control that is handled by the latch structure.

endmodule
```

---

## CDC Crossing Inventory

Every inter-domain path must be identified and the synchronisation method specified:

```
#   Source domain   Dest domain     Signal type     Width   Method
--- --------------- --------------- --------------- ------- -----------------------
1   CPU (1600 MHz)  NOC (400 MHz)   AXI4 bus        128-bit Async FIFO in AXI bridge
                                    (addr+data)             (8-entry, Gray-coded ptr)
2   GPU (852 MHz)   NOC (400 MHz)   AXI4 bus        128-bit Async FIFO in AXI bridge
3   NOC (400 MHz)   CPU (1600 MHz)  AXI4 read data  128-bit Async FIFO in AXI bridge
4   NOC (400 MHz)   APB (100 MHz)   AXI-APB bridge  32-bit  Handshake (req/ack)
5   CPU (1600 MHz)  AO (24 MHz)     Interrupt flags  1-bit  Two-flop synchroniser
6   AO (24 MHz)     CPU (1600 MHz)  Wakeup event     1-bit  Two-flop synchroniser + pulse stretch
7   CPU (1600 MHz)  GPU (852 MHz)   Job dispatch     1-bit  Two-flop synchroniser
8   GPU (852 MHz)   CPU (1600 MHz)  Job completion   1-bit  Two-flop synchroniser
9   Video (300 MHz) NOC (400 MHz)   DMA burst        64-bit Async FIFO (16-entry)
10  AO (24 MHz)     CPU (1600 MHz)  DVFS frequency   3-bit  Enable synchroniser
                                    request                  (multi-bit stable signal)
11  CPU (1600 MHz)  DDR (800 MHz)   Write data       256-bit Async FIFO in DDR ctrl
12  DDR (800 MHz)   CPU (1600 MHz)  Read data        256-bit Async FIFO in DDR ctrl
```

**Notes on entry #10 (multi-bit stable signal):**

The DVFS frequency request from the AO domain is a 3-bit encoding. It changes infrequently and only after a handshake sequence. The enable synchroniser (also called "data-with-valid" synchroniser) is appropriate:

```verilog
// Enable-based multi-bit CDC synchroniser
// The 3-bit dvfs_req is stable for many cycles before and after the
// synchronised valid pulse. The receiver samples dvfs_req only when valid_sync
// is asserted — by this time, dvfs_req has been stable long enough to be safe.

module dvfs_req_sync (
    input  wire       clk_dst,
    input  wire [2:0] dvfs_req,   // AO domain, stable multi-bit
    input  wire       dvfs_valid, // AO domain, one-cycle pulse indicating new req
    output wire [2:0] dvfs_req_sync,
    output wire       dvfs_valid_sync
);
    // Synchronise the valid pulse (two-flop synchroniser)
    reg valid_meta, valid_sync_r;
    always_ff @(posedge clk_dst) begin
        valid_meta   <= dvfs_valid;
        valid_sync_r <= valid_meta;
    end

    // The data is stable when valid_sync rises — safe to register at this point
    // The 3-bit data requires no synchroniser because it is stable before/during valid
    // and the valid synchroniser provides the required two-cycle delay for data stability
    reg [2:0] req_capture;
    always_ff @(posedge clk_dst) begin
        if (valid_sync_r) req_capture <= dvfs_req;
    end

    assign dvfs_req_sync   = req_capture;
    assign dvfs_valid_sync = valid_sync_r;
endmodule
```

---

## Reset Sequencer

### Reset Sources and Priority

```systemverilog
// Reset priority encoder and gating
// All sources assert rst_global_n low. Higher priority sources override lower.

module reset_controller (
    input  wire por_n,        // Power-on reset (from supply supervisor)
    input  wire nrst_n,       // External reset pin
    input  wire wdt_rst_n,    // Watchdog timeout reset
    input  wire sw_rst_n,     // Software-initiated reset (register write)
    input  wire debug_rst_n,  // Debugger reset (JTAG)
    output wire rst_global_n, // Global reset (to all domain synchronisers)
    output wire rst_debug_n,  // Debug-only reset
    output wire rst_ao_n      // Always-on domain reset (POR only)
);
    // Global reset: assert on any active-low source
    assign rst_global_n = por_n & nrst_n & wdt_rst_n & sw_rst_n;
    // AO domain only resets on POR (retains state through WDT/SW/NRST)
    assign rst_ao_n     = por_n;
    // Debug reset: only from debug source (or POR)
    assign rst_debug_n  = por_n & debug_rst_n;
endmodule
```

### Per-Domain Reset Synchronisers

```systemverilog
// Reset synchroniser (async assert, synchronous de-assert)
// Must be instantiated once per clock domain.

module reset_sync #(
    parameter int STAGES = 2  // 2 flops for standard CDC; 3 for very high frequency
) (
    input  wire clk,
    input  wire rst_async_n,   // From reset controller (global, asynchronous)
    output wire rst_sync_n     // Synchronised reset for this domain
);
    logic [STAGES-1:0] pipe;

    always_ff @(posedge clk or negedge rst_async_n) begin
        if (!rst_async_n)
            pipe <= '0;
        else
            pipe <= {pipe[STAGES-2:0], 1'b1};  // Shift in 1s on de-assertion
    end

    assign rst_sync_n = pipe[STAGES-1];

endmodule
```

### Reset Sequencer State Machine

```systemverilog
// Reset sequencer: controls the order of domain de-assertion
// Constraint: APB must not exit reset before NOC.

module reset_sequencer (
    input  wire clk_ao,           // Always-on clock (24 MHz, always running)
    input  wire por_n,            // Power-on reset (raw, async)
    input  wire cpu_pll_locked,   // PLL lock indicators
    input  wire gpu_pll_locked,
    input  wire sys_pll_locked,
    input  wire ddr_pll_locked,

    output wire rst_noc_n,        // NOC domain reset (released first among slaves)
    output wire rst_apb_n,        // APB domain reset (released after NOC)
    output wire rst_video_n,      // Video domain reset
    output wire rst_cpu_n,        // CPU reset (released last)
    output wire rst_gpu_n         // GPU reset
);

    // Internal reset synchronised to AO clock
    wire por_sync_n;
    reset_sync #(.STAGES(2)) i_por_sync (
        .clk(clk_ao), .rst_async_n(por_n), .rst_sync_n(por_sync_n)
    );

    // Sequencing state machine (runs in AO domain at 24 MHz)
    typedef enum logic [2:0] {
        SEQ_RESET         = 3'd0,  // All domains in reset; waiting for PLLs
        SEQ_WAIT_PLLS     = 3'd1,  // PLLs locking
        SEQ_RELEASE_NOC   = 3'd2,  // Release NOC and Video first
        SEQ_RELEASE_APB   = 3'd3,  // Release APB after NOC is up (8 AO cycles)
        SEQ_RELEASE_CPU   = 3'd4,  // Release CPU/GPU last (slaves must be ready)
        SEQ_RUNNING       = 3'd5   // All domains active
    } seq_state_t;

    seq_state_t state;
    logic [7:0] delay_cnt;  // Counter for inter-release delays

    // Raw enable signals (fed to per-domain reset synchronisers below)
    logic noc_rst_en, apb_rst_en, video_rst_en, cpu_rst_en, gpu_rst_en;

    always_ff @(posedge clk_ao or negedge por_sync_n) begin
        if (!por_sync_n) begin
            state        <= SEQ_RESET;
            delay_cnt    <= '0;
            noc_rst_en   <= '0;
            apb_rst_en   <= '0;
            video_rst_en <= '0;
            cpu_rst_en   <= '0;
            gpu_rst_en   <= '0;
        end else begin
            case (state)
                SEQ_RESET: begin
                    if (sys_pll_locked)
                        state <= SEQ_WAIT_PLLS;
                end
                SEQ_WAIT_PLLS: begin
                    if (cpu_pll_locked & gpu_pll_locked & ddr_pll_locked) begin
                        noc_rst_en   <= 1'b1;  // Release NOC
                        video_rst_en <= 1'b1;  // Release Video simultaneously
                        delay_cnt    <= 8'd8;  // Count 8 AO cycles before APB release
                        state        <= SEQ_RELEASE_NOC;
                    end
                end
                SEQ_RELEASE_NOC: begin
                    if (delay_cnt == 0) begin
                        apb_rst_en <= 1'b1;    // Release APB after NOC has settled
                        delay_cnt  <= 8'd16;   // Wait another 16 cycles before CPU
                        state      <= SEQ_RELEASE_APB;
                    end else begin
                        delay_cnt <= delay_cnt - 1;
                    end
                end
                SEQ_RELEASE_APB: begin
                    if (delay_cnt == 0) begin
                        cpu_rst_en <= 1'b1;    // CPU fetches first instruction now
                        gpu_rst_en <= 1'b1;
                        state      <= SEQ_RUNNING;
                    end else begin
                        delay_cnt <= delay_cnt - 1;
                    end
                end
                SEQ_RUNNING: begin
                    // Steady state; all domains active
                end
                default: state <= SEQ_RESET;
            endcase
        end
    end

    // Per-domain reset synchronisers (async assert, synchronous de-assert)
    // Each feeds the reset pin of all flip-flops in that domain.
    // The synchroniser is the *domain's* clock (not AO clock).
    // (Domain clocks must be running; the PLL-locked check above guarantees this.)

    // Note: In actual implementation, these synchronisers would be instantiated
    // in the top-level with the domain clocks available. Shown here as a conceptual
    // model only — in reality, the reset controller outputs noc_rst_en etc. as
    // asynchronous enables, and the domain-level synchroniser receives its own clock.

    assign rst_noc_n   = noc_rst_en;   // Fed to NOC-domain reset_sync
    assign rst_apb_n   = apb_rst_en;   // Fed to APB-domain reset_sync
    assign rst_video_n = video_rst_en;
    assign rst_cpu_n   = cpu_rst_en;
    assign rst_gpu_n   = gpu_rst_en;

endmodule
```

---

## Timing Analysis

### Clock Skew Budget

```
Domain           Frequency   CTS skew target   Why
-----------      ---------   ---------------   -----------------------------------
CPU cluster      1600 MHz    < 20 ps           1 clock period = 625 ps; setup guard
GPU              852 MHz     < 40 ps           1 clock period = 1175 ps; relaxed
NOC              400 MHz     < 80 ps           2.5 ns period; plenty of guard
APB              100 MHz     < 200 ps          10 ns period; CTS effort minimal
DDR PHY          800 MHz     < 10 ps           Special CTS: uses dedicated H-tree
                                                layout to minimise DDR clock skew
```

### PLL Lock Time and Power-On Sequence Timing

```
POR assertion to first CPU instruction (worst case):
  T_supply_ramp          = 1 ms     (PMIC output stabilisation)
  T_por_logic            = 10 µs    (POR circuit deglitch)
  T_xo_startup           = 500 µs   (crystal oscillator startup, amplitude stable)
  T_sys_pll_lock         = 50 µs    (SYS PLL acquisition from 24 MHz)
  T_cpu_pll_lock         = 50 µs    (CPU PLL acquisition)
  T_gpu_pll_lock         = 50 µs    (GPU PLL, in parallel with CPU PLL)
  T_ddr_pll_lock         = 100 µs   (DDR PLL, longer — stricter phase noise req)
  T_reset_sequencer      = 1 µs     (8 + 16 = 24 AO cycles @ 24 MHz for sequencing delays)
  T_boot_rom_access      = 10 ns    (first instruction fetch after CPU exits reset)
  ---
  Total to first instruction: ~1.7 ms (dominated by supply ramp + XO startup)

Acceptable for mobile SoC boot (full OS boot typically takes 2-10 seconds).
```

---

## Power Optimisation

### Clock Gating Strategy per Domain

```
Domain     ICG placement              Gating condition
---------  -------------------------  -----------------------------------------------
CPU cores  Per-core ICG at CTS root   Core idle: Linux cpu_idle governor; WFI instruction
           Per-pipeline-stage ICG     Stage stalled: bubble in pipeline detected
GPU        Top-level ICG              GPU not scheduled: power manager asserts gate_gpu
Video      Top-level ICG              No active video session
APB periph Per-peripheral ICG (x14)  PSEL not asserted to that peripheral (bus-activity gating)
           Fine-grained register ICG  Data register write-enable as clock enable to DFF
NOC        Per-link ICG               AXI channel idle for > 8 cycles (low-watermark gating)
```

**Fine-grained register clock gating example:**

```systemverilog
// UART TX data register with clock gating
// Only the TX_DATA register is updated on a write; the baud rate register
// is rarely written. Clock-gate each register individually.

module uart_ctrl_regs (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        psel, penable, pwrite,
    input  wire [11:0] paddr,
    input  wire [31:0] pwdata,
    output logic [31:0] prdata
);
    logic [7:0]  tx_data_reg;
    logic [15:0] baud_div_reg;

    // Clock gate for TX_DATA register: only clocked when APB write targets it
    wire tx_data_wr_en = psel & penable & pwrite & (paddr[11:2] == 10'd0);

    // ICG for tx_data_reg — eliminates clock power when not written
    wire clk_tx_gated;
    icg tx_data_icg (
        .clk(clk), .enable(tx_data_wr_en), .test_enable(scan_mode),
        .gated_clk(clk_tx_gated)
    );

    always_ff @(posedge clk_tx_gated or negedge rst_n) begin
        if (!rst_n) tx_data_reg <= '0;
        else        tx_data_reg <= pwdata[7:0];
    end

    // baud_div_reg: similar structure, gated on its own write-enable
    // ...

endmodule
```

---

## Verification

### CDC Verification Checklist

```
1. Structural CDC analysis (SpyGlass CDC or Questa CDC):
   [ ] Run on complete RTL; zero violations before tapeout
   [ ] All 12 CDC crossings in the inventory have recognised synchroniser structures
   [ ] No reconvergence: multiple synchronised signals from same source do not
       recombine in combinational logic in the destination domain
   [ ] Set_false_path / set_max_delay constraints applied to all sync chains

2. Async FIFO functional verification:
   [ ] Simultaneous read and write at maximum rates — verify no overflow/underflow
   [ ] Empty/full flags verified at all fill levels (0, 1, N/2, N-1, N)
   [ ] Corner case: write burst fills FIFO to exactly full; subsequent write is
       back-pressured; read drains one entry; write resumes
   [ ] Near-integer frequency ratios: clk_w = 400.001 MHz, clk_r = 400.000 MHz
       (simulates worst-case pointer timing)

3. DVFS transition simulation:
   [ ] All 12 CPU DVFS transitions (4 states x 3 other states = 12 ordered pairs)
   [ ] Verify no glitch on clk_out of glitch-free MUX during transition
       (check: period of clk_out never < shortest clock period of either input)
   [ ] Verify CPU architectural register file retains values through transition
       (run: compute and store 64 values before transition; verify after)

4. Reset sequencing simulation:
   [ ] POR sequence: verify NOC exits reset before APB (measure delay_cnt cycles)
   [ ] CPU does not attempt bus access during APB reset (verified by bus monitor)
   [ ] WDT reset: verify all domains reset except AO; AO retains RTC count
```

---

## Key Takeaways

1. **Three PLLs can serve six clock domains via integer dividers.** The key insight is choosing VCO frequencies that produce all required output frequencies via integer division. Non-integer ratios require fractional-N PLLs, which have higher jitter.

2. **Glitch-free clock switching is mandatory for DVFS.** A combinational AND of a clock with a selector is never acceptable. The latch-based handshake ensures the output transitions only on a clean, full-width clock edge.

3. **Reset sequencing order must match the dependency order.** Slaves must be ready before masters. A CPU that executes before its peripheral bus is out of reset will hang or take an exception on the first bus access.

4. **The CDC inventory is a deliverable, not a side effect.** Maintaining a documented list of every clock domain crossing, with the synchronisation method, enables systematic verification. Undocumented CDC crossings are a leading cause of first-silicon functional failures.

5. **Clock gating saves 30-50% of dynamic power at no performance cost.** Fine-grained ICG placement (per pipeline stage, per register) compounds these savings. All ICG cells must include test_enable for DFT scan compatibility.
