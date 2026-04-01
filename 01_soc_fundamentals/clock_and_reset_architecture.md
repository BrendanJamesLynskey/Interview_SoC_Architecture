# Clock and Reset Architecture

## Prerequisites
- Sequential logic fundamentals: flip-flops, setup/hold time, metastability
- PLL operation at a conceptual level
- Clock domain crossing (CDC) basics
- SoC building blocks and memory map concepts

---

## Concept Reference

### Clock Hierarchy in a Modern SoC

```
External reference oscillator (e.g., 24 MHz crystal)
             |
       +-----+------+
       |  PLL / FLL |   Multiplies reference to high frequency
       +-----+------+   (e.g., 24 MHz x 100 = 2400 MHz VCO)
             |
    +--------+---------+
    |   Clock dividers  |   Divide VCO output to derive multiple clocks:
    +--+---+---+---+---+    2400/2 = 1200 MHz (CPU)
       |   |   |   |        2400/4 =  600 MHz (GPU)
    1200  600  400  200      2400/6 =  400 MHz (Fabric)
    MHz  MHz  MHz  MHz       2400/12 = 200 MHz (UART/I2C/SPI)
       |   |   |   |
  [CTS] [CTS] [CTS] [CTS]   Clock tree synthesis: buffers, inverter pairs
       |   |   |   |         distributed to flip-flops within each domain
   CPU  GPU  NOC  PERIPH     (skew < 50 ps within domain at 7 nm)
   domain domain domain domain
```

### Clock Domain Crossing (CDC)

A clock domain crossing occurs whenever a signal originates in a flip-flop clocked by clock domain A and is sampled by a flip-flop clocked by clock domain B (different frequency or phase relationship).

```
Safe CDC methods:
  1. Two-flop synchroniser (single-bit control signals)
  2. Handshake protocol (multi-bit, asynchronous request/acknowledge)
  3. Asynchronous FIFO (data streams, Gray-coded pointers)
  4. MUX-based synchroniser (for clock switching)
  5. Enable / data valid synchronisation (for multi-bit data with infrequent updates)
```

### Reset Architecture: Key Principles

```
Golden rule:
  Reset assertion:    Asynchronous  (works even if clock is absent / unstable)
  Reset de-assertion: Synchronous   (prevents metastability on release)

Reset sources (typical SoC):
  POR   — Power-on reset: fired when supply exceeds threshold, held until stable
  NRST  — External reset pin: board-level reset from supervisor or debug
  WDT   — Watchdog reset: fires if software fails to kick watchdog within period
  SW    — Software reset: written to a software-accessible reset control register
  DEBUG — Debug reset: issued by JTAG/SWD debugger

Reset domains:
  AO    — Always-on: never reset except on POR (loses state only on total power loss)
  FULL  — All logic: full chip reset on POR, NRST, WDT, SW reset
  DEBUG — Debug logic only: reset by DEBUG reset without affecting application logic
```

### PLL Parameters

| Parameter     | Meaning                                    | Typical value           |
|---------------|--------------------------------------------|-------------------------|
| VCO frequency | Internal oscillator frequency              | 1-4 GHz                 |
| M (feedback)  | Feedback divider                           | Integer 4-512           |
| N (input)     | Input reference divider                    | Integer 1-16            |
| OD (output)   | Output divider                             | Integer 1-128           |
| Lock time     | Time from enable to locked output          | 10-100 µs               |
| Jitter        | RMS phase noise on output                  | 0.1-1 ps RMS (on-chip)  |

Output frequency = (F_ref * M) / (N * OD)

---

## Tier 1 — Fundamentals

### Question F1
**What is a clock domain? Why does an SoC have multiple clock domains rather than one global clock?**

**Answer:**

A **clock domain** is a set of flip-flops all driven by the same clock signal (same source, same phase relationship). Logic within a domain can be statically timed; transfers between domains require special treatment.

**Reasons for multiple clock domains:**

1. **Different performance requirements:** The CPU core may need 2 GHz while the UART peripheral runs correctly at 48 MHz. Running everything at 2 GHz wastes enormous power — dynamic power scales with frequency (P = C V² f), so a UART running at 2 GHz rather than 48 MHz wastes 42x more dynamic power for zero performance benefit.

2. **Power domains:** When a subsystem (e.g., the GPU domain) is power-gated, its clock must also be stopped. Multiple clock domains allow precise per-domain clock control.

3. **Off-chip interfaces:** USB requires a 48 MHz (or 480 MHz for HS) clock derived from a USB-specific PLL. PCIe requires specific reference clocks. DDR requires memory clocks phase-aligned to the data strobe. These cannot all be derived from a single internal clock without incurring unacceptable jitter or phase error.

4. **Area and power optimisation:** A lower-frequency domain can use longer, more resistive wires with smaller repeaters — the clock tree for a 200 MHz domain is far less power-hungry than one for a 2 GHz domain.

5. **Spread-spectrum clocking:** Intentionally spreading the spectrum of the clock to reduce EMI requires the affected clock to be independent of timing-critical domains.

**Cost of multiple clock domains:**

Every boundary between clock domains requires CDC synchronisation logic. This adds gates, latency, and verification complexity. Each CDC crossing must be analysed by CDC tools (Mentor Questa CDC, Synopsys SpyGlass CDC) because standard STA cannot check inter-domain paths. Excessive CDC complexity is a primary source of first-silicon functional bugs.

---

### Question F2
**Explain setup time and hold time for a flip-flop. How do clock skew and clock jitter affect timing margins?**

**Answer:**

**Setup time (T_su):** The minimum time before a clock edge that the data input (D) must be stable and valid. Violating setup causes the flip-flop to enter a metastable state — the output Q may take an unpredictable value or oscillate for an extended period.

**Hold time (T_h):** The minimum time after the clock edge that the data input must remain stable. Violating hold causes the flip-flop to capture the wrong (new) data value before the flip-flop has properly latched the old value.

```
Data timeline:
                                  |<-- T_su -->|
                                  |            |
  D: ---XXXXXXXX_stable_data_XXXXXXXXXXXXXXXXX[setup window]---new_data--
                                               ^
                                          Clock edge
                                               |<-- T_h -->|
                                                              D must hold here
```

**Setup time constraint:**

```
For a path from FF_src to FF_dst through combinational logic of delay T_comb:

T_launch + T_comb + T_su <= T_clk + T_skew_beneficial

Where:
  T_launch  = clock-to-Q delay of FF_src (typically 100-200 ps)
  T_comb    = sum of all combinational gate delays on the path
  T_su      = setup time of FF_dst
  T_clk     = clock period
  T_skew_beneficial = arrival_time(FF_dst_clock) - arrival_time(FF_src_clock)
                      (positive if destination clock is later — gives more time)

Setup slack = T_clk + T_skew_beneficial - T_jitter - T_launch - T_comb - T_su
```

**Hold time constraint:**

```
T_launch + T_comb_min >= T_hold + T_skew_harmful

Where:
  T_comb_min     = minimum (fastest) combinational path delay
  T_skew_harmful = arrival_time(FF_dst_clock) - arrival_time(FF_src_clock)
                   (positive if destination clock is earlier — hurts hold)

Hold slack = T_launch + T_comb_min - T_hold - T_skew_harmful
```

**Effect of clock skew:**

Skew is the static (deterministic) difference in clock arrival times. Positive skew (destination later) helps setup but hurts hold. Hold violations are fixed with buffer insertion (adding delay to the data path) — they cannot be fixed by reducing clock frequency. Setup violations can be fixed by reducing frequency or adding pipeline stages.

**Effect of clock jitter:**

Jitter is a random cycle-to-cycle variation in clock edge arrival time. It tightens setup margin because it may cause the clock at FF_dst to arrive earlier than expected (reducing the effective clock period). A standard STA tool derates the clock period by a "clock uncertainty" value that accounts for jitter.

```
Typical clock uncertainty values:
  On-chip generated clock (PLL output): 50-150 ps (dominated by PLL phase noise)
  Off-chip clock across PCB:           200-500 ps (board-level jitter + EMI)
  DDR interface:                        < 10 ps (requires dedicated PLL and layout)
```

---

### Question F3
**What is a clock gate and why is it used? What is the risk of implementing a clock gate incorrectly?**

**Answer:**

A **clock gate** is a circuit element that conditionally enables or disables the clock to a register or group of registers. When the enable is deasserted, the clock output is held low (or high, depending on convention), preventing the flip-flops from switching and eliminating all dynamic power consumption in the gated sub-tree.

**Why clock gating is essential:**

Dynamic power is P = C V² f. For a flip-flop whose output does not change, the clock edge still causes the internal nodes to toggle (clock buffer drives, inverter pair switches, output latch samples). Gating the clock to idle registers eliminates this wasted switching.

On a typical SoC, 30-50% of dynamic power is saved by aggressive clock gating. The CPU pipeline stall logic, cache controllers, and peripheral datapaths all have clock gates.

**Correct implementation — ICG (Integrated Clock Gating cell):**

```
Incorrect (introduces glitch):
  assign gated_clk = clk & enable;   // Gate with combinational AND
  // Problem: if 'enable' changes while clk is HIGH, a glitch is produced.
  // The glitch is a short clock pulse that can latch wrong data.

Correct (glitch-free ICG):
  // Use a latch-based ICG cell:
  //   When clk is LOW (latch transparent), latch samples the enable.
  //   Latched enable drives the AND gate.
  //   When clk goes HIGH, the AND gate output can only change while clk is HIGH,
  //   which means the transition of gated_clk is a legitimate clock edge.

  // Behavioural model of an ICG cell:
  module icg (
      input  wire clk, enable, test_enable,
      output wire gated_clk
  );
      reg latch_en;
      // Latch: transparent when clk is LOW
      always @(*) begin
          if (!clk) latch_en <= enable | test_enable;
          // test_enable overrides for DFT scan shift
      end
      assign gated_clk = clk & latch_en;
  endmodule
```

**The latch timing ensures:**

```
Timeline:
  clk _____|‾‾‾‾‾|_____|‾‾‾‾‾|_____
  enable __________|‾‾‾‾‾‾‾‾‾‾‾|___
  latch_en ____________|‾‾‾‾‾‾‾‾‾‾|  (sampled during LOW phase, stable before rising edge)
  gated_clk _____________|‾‾‾|___   (first full clock cycle after enable, no glitch)
```

**Risks of incorrect clock gating:**

1. **Glitch on gated clock:** A combinational AND without a latch allows the enable signal to generate spurious clock edges. Flip-flops capture wrong data; the bug is often intermittent (depends on timing of enable relative to clock).

2. **Enable not registered:** An enable that changes on the same clock edge creates a setup/hold conflict within the gate itself.

3. **Test mode:** If test_enable is not included, DFT scan shifting is impossible — the scan clock cannot propagate through the gate. All production ICG cells include a test_enable input to bypass the gate during scan.

---

## Tier 2 — Intermediate

### Question I1
**Design a two-flop synchroniser for a single-bit control signal crossing from a 100 MHz domain to a 250 MHz domain. Explain the metastability mechanics and calculate the Mean Time Between Failures (MTBF) given typical flip-flop parameters.**

**Answer:**

**Two-flop synchroniser circuit:**

```verilog
// Single-bit CDC synchroniser: 100 MHz source to 250 MHz destination
// The source flip-flop (in 100 MHz domain) is not shown — this is the destination
// synchroniser chain (both flops clocked by the 250 MHz domain clock)

module sync_2ff (
    input  wire clk_dst,   // 250 MHz destination clock
    input  wire rst_n,     // synchronous de-assertion reset (250 MHz domain)
    input  wire d_async,   // asynchronous input from 100 MHz source
    output wire q_sync     // synchronised output, safe to use in 250 MHz domain
);
    reg meta, sync;   // meta = first stage (metastability reduction)
                      // sync = second stage (output)

    always_ff @(posedge clk_dst or negedge rst_n) begin
        if (!rst_n) begin
            meta <= 1'b0;
            sync <= 1'b0;
        end else begin
            meta <= d_async;   // First stage: samples async input, may go metastable
            sync <= meta;      // Second stage: samples first stage, gives metastability
                               // one full clock period to resolve before this capture
        end
    end

    assign q_sync = sync;

    // IMPORTANT: The wire between 'meta' and 'sync' must NOT have any logic.
    // The place-and-route tool must be constrained to minimise routing delay on
    // this wire so the metastable node has the maximum possible time to resolve
    // before 'sync' is sampled.
    // SDC constraint:
    //   set_false_path -from [get_ports d_async] -to [get_cells meta_reg]
    // This tells STA to not report the crossing path as a timing violation.

endmodule
```

**Metastability mechanics:**

When a flip-flop's setup or hold time is violated, its output enters a metastable state — the cross-coupled inverter pair of the storage element has both high and low simultaneously and slowly resolves to one. The probability that metastability has not resolved by time T after the clock edge is:

```
P(metastable after time T) = (f_src * f_dst) / (f_src + f_dst) * (1/τ) * exp(-T/τ)

Where:
  f_src = 100 MHz (source frequency)
  f_dst = 250 MHz (destination frequency)
  τ     = metastability resolution time constant (process-dependent, ~20-50 ps for 16 nm)
  T     = time available for resolution = T_clk_dst - T_setup = 4 ns - 0.1 ns = 3.9 ns

Simplified formula (standard approximation):
  MTBF = exp(T / τ) / (f_src * f_dst * T_w)

Where T_w is the metastability window (≈ setup + hold violation window ≈ 50-100 ps)
```

**Numerical example (16 nm process, τ = 30 ps):**

```
T = T_clk_dst - T_launch - T_routing - T_setup_stage2
  = 4 ns - 0.15 ns - 0.05 ns - 0.10 ns
  = 3.7 ns

MTBF = exp(T / τ) / (f_src * f_dst * T_w)
     = exp(3700 ps / 30 ps) / (100×10^6 * 250×10^6 * 80×10^-12)
     = exp(123.3) / (100×10^6 * 250×10^6 * 80×10^-12)
     = (enormous number) / 2000

The exponential dominates overwhelmingly:
exp(123) ≈ 2.6 × 10^53

MTBF ≈ 2.6×10^53 / 2×10^3 ≈ 1.3 × 10^50 seconds

This is many orders of magnitude larger than the age of the universe (~4×10^17 s).
```

**Practical conclusion:** A two-flop synchroniser in 16 nm (or most modern processes) provides essentially infinite MTBF because the exponential growth of the resolution probability with time is enormous. The 1T resolution time (3.7 ns at 250 MHz) is 100+ time constants, making unresolved metastability astronomically improbable.

**Why two flops rather than one:** With one flop, T available = T_clk - T_setup_of_next_stage (everything after the synchroniser). One clock period may not be sufficient for high-frequency designs. With two flops, the first stage has a full clock period to resolve before the second stage captures, and the output of the second stage feeds normal logic.

---

### Question I2
**Describe the key components of a chip-level reset architecture. What is a reset synchroniser and why is one needed per clock domain?**

**Answer:**

**Chip-level reset sources and their priority:**

```
Priority    Reset source    Affects              Typical cause
--------    ------------    -------              -------------
1 (highest) POR             All domains          Supply ramp, VDD first applied
2           NRST (pin)      All except RTC/AON   Board-level supervisor, JTAG reset
3           WDT reset       All except RTC/AON   Software hang
4           SW full reset   All except RTC/AON   OS-initiated reboot
5           SW partial      Specific domain       Domain reboot (e.g., GPU only)
6 (lowest)  Debug reset     CPU + debug only      JTAG connect/reconnect
```

**Reset controller block:**

```
POR ------+
NRST -----+----> [Priority logic] ----> rst_global_n (asserted asynchronously)
WDT  -----+                              |
SW   -----+                              |
DEBUG ----+                         [Per-domain reset synchronisers]
                                         |         |          |
                                    rst_cpu_n  rst_gpu_n  rst_periph_n
                                    (sync to   (sync to   (sync to
                                    CPU clock) GPU clock) periph clock)
```

**Reset synchroniser — required per domain:**

When rst_global_n is released (goes from 0 to 1 — i.e., reset de-asserts), all flip-flops in the system must exit reset cleanly. If the de-assertion edge is asynchronous relative to a domain's clock, the flip-flops at the front of that domain's reset tree may sample the rising edge of rst_n in violation of their setup time, causing metastability at reset release.

```verilog
// Reset synchroniser for one clock domain
// Asserts reset asynchronously (immediately), de-asserts synchronously (after 2 cycles)
module reset_sync (
    input  wire clk,          // Domain clock
    input  wire rst_async_n,  // Asynchronous reset input (from reset controller)
    output wire rst_sync_n    // Synchronised reset for this domain
);
    reg [1:0] sync_chain;

    // Asynchronous assert: when rst_async_n goes low, both flops are immediately cleared.
    // Synchronous de-assert: when rst_async_n goes high, chain fills with 1s over 2 cycles.
    always_ff @(posedge clk or negedge rst_async_n) begin
        if (!rst_async_n)
            sync_chain <= 2'b00;
        else
            sync_chain <= {sync_chain[0], 1'b1};  // Shift in 1s from the top
    end

    assign rst_sync_n = sync_chain[1];  // Output: 0 during reset, rises 2 cycles after release

endmodule
```

**Why one synchroniser per domain:**

Each clock domain has an independent clock. The de-assertion of rst_async_n is asynchronous to all of them. Without per-domain synchronisers:

1. CPU domain (2 GHz) and peripheral domain (200 MHz) exit reset at different times based on where rst_async_n was sampled relative to each clock. In extreme cases, the CPU tries to fetch instructions from a peripheral bus that has not yet come out of reset.

2. The reset release edge may be metastable in one domain while clean in another, causing one domain's reset output to oscillate briefly, creating spurious clock pulses (since many logic functions depend on reset).

3. Scan testing requires each domain's reset to be independently controllable to test the reset path in isolation.

**Reset sequencing consideration:**

For a multi-power-domain SoC, the reset de-assertion order matters:

```
Correct sequence for a CPU+peripheral SoC:
  1. Assert reset to ALL domains
  2. Power on and stabilise all power rails
  3. Wait for PLLs to lock (on all clock sources)
  4. De-assert reset to clock infrastructure (PLL, clock dividers)
  5. De-assert reset to peripheral domains (so slaves are ready to respond)
  6. De-assert reset to CPU domain last (CPU immediately begins fetching instructions;
     all slaves must be ready before the first fetch completes)

Failure mode of incorrect sequencing:
  CPU de-asserts first, fetches reset vector, issues bus transactions to peripherals
  that are still in reset. The peripheral bus returns X or 0, the CPU takes a boot
  exception, and the SoC appears to be dead on first power-up.
```

---

### Question I3
**What is an asynchronous FIFO? Explain how Gray coding of the read and write pointers makes it safe for CDC.**

**Answer:**

An **asynchronous FIFO** (async FIFO) stores data written from one clock domain and allows it to be read from a different clock domain. It is the standard solution for transferring streams of data across a CDC boundary.

**Structure:**

```
Write domain (clk_w)        Dual-port        Read domain (clk_r)
                             SRAM
  wptr (binary) -----> [wr_addr]   [rd_addr] <---- rptr (binary)
  wptr -> Gray ---sync---> wptr_gray_r          rptr -> Gray ---sync---> rptr_gray_w
  empty/full calculated                          empty/full calculated
  from wptr and rptr_gray_w                      from rptr and wptr_gray_r
```

**Why binary pointers cannot be directly synchronised:**

A binary counter can change multiple bits simultaneously. For example, counter going 0111 -> 1000 changes all 4 bits in one clock cycle. If this change is sampled in the other domain during the transition, an intermediate value (e.g., 1001, 0110) may be captured, which is a completely wrong pointer value. This would cause the FIFO to appear at an incorrect fill level, leading to data loss or corruption.

**Gray code solution:**

Gray code (reflected binary code) changes exactly ONE bit per count step:

```
Decimal  Binary  Gray
0        0000    0000
1        0001    0001
2        0010    0011
3        0011    0010
4        0100    0110
5        0101    0111
6        0110    0101
7        0111    0100
...

Conversion: gray[n] = binary[n] XOR binary[n+1]
            (each bit is XOR of the corresponding and next higher binary bit)
```

When a Gray-coded pointer transitions, only ONE bit changes. A two-flop synchroniser that samples this one-bit transition either:
- Captures the old value (transition not yet propagated), or
- Captures the new value (transition propagated).

Either outcome is a valid FIFO pointer value. Metastability on the one changing bit resolves to one valid state or the other — never to an invalid pointer value.

**FIFO empty and full conditions (with Gray pointers):**

```
// N-deep FIFO requires log2(N)+1 bit pointers (extra bit distinguishes full from empty)
// Pointers wrap around at 2*N, not N

// Empty: all bits of Gray-coded pointers are equal
assign empty = (rptr_gray == wptr_gray_r);

// Full: MSB and second-MSB differ (the extra pointer bit technique):
// Full when wptr_gray = {~rptr_gray_w[MSB:MSB-1], rptr_gray_w[MSB-2:0]}
// (Top 2 bits inverted, lower bits equal)
assign full = (wptr_gray == {~rptr_gray_w[PTR_WIDTH:PTR_WIDTH-1],
                              rptr_gray_w[PTR_WIDTH-2:0]});
```

**Key implementation rules:**

1. The SRAM must be dual-port (simultaneous independent read and write access).
2. Pointer width must be log2(DEPTH) + 1 to correctly distinguish full from empty.
3. The sync chain must be exactly 2 (or 3 for very high-frequency designs) flops, with no logic between them.
4. STA must have a `set_false_path` or `set_max_delay -datapath_only` on the sync chains to prevent the tool from treating the inter-domain path as a normal timing arc.

---

## Tier 3 — Advanced

### Question A1
**A mobile SoC has a CPU cluster running at 2.4 GHz, a GPU running at 850 MHz, a media engine at 600 MHz, and a peripheral bus at 200 MHz. The CPU and GPU must communicate at low latency. Describe the clock tree architecture, the synchronisation strategy for each domain boundary, and how you would validate the CDC crossings.**

**Answer:**

**Clock tree architecture:**

```
24 MHz XO (crystal oscillator)
     |
  CPU PLL: 24 MHz x 100 = 2400 MHz VCO
     |---- /1  = 2400 MHz -> CPU cluster CTS (skew target < 20 ps within cluster)
     |---- /4  =  600 MHz -> Media engine CTS (skew < 50 ps)
     |
  GPU PLL: 24 MHz x 71 = 1704 MHz VCO
     |---- /2  =  852 MHz -> GPU CTS (skew < 30 ps, DFS: can step down to /8 = 213 MHz)
     |
  PERIPH PLL: 24 MHz x 50 = 1200 MHz VCO
     |---- /6  = 200 MHz -> APB peripheral CTS (skew < 100 ps; relaxed, low freq)
     |---- /3  = 400 MHz -> Interconnect/NoC CTS (skew < 40 ps)

Note: Using separate PLLs for CPU and GPU allows independent DVFS (dynamic voltage
and frequency scaling) — CPU can ramp to 2.4 GHz under compute load while GPU
stays at 213 MHz during light 3D work, saving power independently.
```

**Clock gating hierarchy:**

```
Each domain has a top-level ICG cell driven by the power management unit (PMU).
The PMU asserts enable only when:
  1. The domain's power rail is stable (checked via power-good detector).
  2. The domain's PLL is locked (checked via PLL lock signal, synchronised to AO domain).
  3. No reset is asserted to the domain.

If any condition fails, the ICG shuts off the domain clock before (or simultaneously with)
power removal, preventing partial transitions on clock edges.
```

**Synchronisation strategy per domain boundary:**

```
CPU (2400 MHz) <-> GPU (852 MHz):
  - Primary path: Shared L3 cache (coherent; same physical memory, no CDC needed
    for the data itself — the CMN-700 or DSU interconnect handles coherency).
  - Control signals (e.g., GPU job completion interrupt to CPU):
    Two-flop synchroniser from GPU to CPU clock domain.
    Latency: 2 cycles at 2400 MHz = ~0.83 ns (acceptable for interrupt delivery).

CPU (2400 MHz) <-> Media engine (600 MHz):
  - Data: Async FIFO, 16-entry, 128-bit wide (video line buffer DMA path).
    Gray-coded pointers with 2-flop sync.
  - Control (start/stop, frame sync):
    Two-flop synchroniser for single-bit events.
    Pulse stretcher for pulses narrower than destination clock period.

CPU (2400 MHz) <-> APB peripheral (200 MHz):
  - All CPU accesses are through the AXI-to-APB bridge.
  - The bridge itself contains the CDC synchronisation: AXI side runs at
    interconnect frequency (400 MHz), APB side runs at 200 MHz.
  - Bridge implementation: handshake-based CDC (request/acknowledge).
    AXI request -> synchroniser -> APB; APB complete -> synchroniser -> AXI response.
    Latency: ~6 APB cycles + 4 synchroniser cycles ≈ 50 ns (acceptable; peripheral accesses
    are infrequent and latency-tolerant).

GPU (852 MHz) <-> Media engine (600 MHz):
  - Async FIFO (texture cache miss data path, 512-bit wide, 32-entry).
  - Control: two-flop synchronisers.
```

**CDC validation methodology:**

```
1. Structural CDC analysis (automated tools: SpyGlass CDC, Questa CDC):
   - Tool identifies all flip-flops where the fanout clock differs from the source clock.
   - Checks that all inter-domain paths have a recognised synchronisation structure.
   - Reports violations: missing synchronisers, improperly driven synchronisers,
     reconvergence (multiple synchronised bits from same source recombining in logic).

2. Formal verification (Cadence JasperGold CDC):
   - Proves the property: no multi-bit bus sampled in destination domain without
     all bits having been stable for at least 1 destination clock cycle.
   - Proves FIFO can never overflow or underflow given correct operational constraints.

3. Simulation with pessimistic CDC models:
   - Replace two-flop synchronisers with a CDC model that randomly delays the
     output by 0, 1, or 2 cycles (reflecting metastability resolution time).
   - Run directed tests: simultaneously toggle source signals and sample in destination;
     verify that downstream logic handles all possible synchroniser output delays.

4. Silicon bring-up checklist:
   - Scope the synchronised signal and verify no glitches on gated_clk output of ICGs.
   - Run a frequency sweep: vary PLL settings to create near-integer frequency ratios
     (worst case for synchroniser MTBF) and verify no CDC failures.
   - Enable CDC-specific silicon debug features (e.g., error injection registers that
     force a synchroniser to output a random value to test software error handling).
```

---

### Question A2
**Explain Dynamic Voltage and Frequency Scaling (DVFS). What clock architecture features are required to support DVFS, and what are the risks during a frequency transition?**

**Answer:**

**DVFS principle:**

DVFS reduces dynamic and static power by simultaneously reducing the operating voltage and frequency during periods of low workload:

```
Power relationships:
  Dynamic power: P_dyn = alpha * C * V_DD^2 * f
  Static power:  P_static = I_leak * V_DD

At half frequency (1.2 GHz vs 2.4 GHz) and reduced voltage (0.75V vs 1.0V):
  P_dyn reduction: (0.75/1.0)^2 * (1.2/2.4) = 0.5625 * 0.5 = 0.28x of original
  Static power reduction: (0.75/1.0) = 0.75x of original
  Combined: significant power saving at reduced performance.
```

**Clock architecture requirements for DVFS:**

1. **Fractional-N PLL or multiple output dividers:**

   ```
   The PLL must be able to change output frequency without temporarily losing lock
   entirely (which would corrupt all clocked state).
   
   Safe frequency change with divider-based DVFS:
     1. Switch CPU clock source from PLL output to a slow, stable bypass clock
        (e.g., 24 MHz XO or a low-speed ring oscillator).
     2. Reprogram the PLL feedback divider (M) for new target frequency.
     3. Wait for PLL to re-lock (typically 10-50 µs).
     4. Switch CPU clock source back to PLL output.
   
   The bypass clock ensures the CPU continues to tick (slowly but correctly)
   during the PLL re-lock interval.
   ```

2. **Glitch-free clock multiplexer:**

   ```
   Switching the CPU clock source must not produce a glitch (partial clock pulse).
   A glitch would violate hold time at every flip-flop in the CPU domain simultaneously.
   
   Glitch-free MUX implementation (same principle as ICG):
   - Use latch-based synchronisation to ensure each source is deselected in its own
     clock domain, and the new source is selected only on a clean clock edge.
   
   module clk_mux_glitch_free (
       input  wire clk_a, clk_b,  // two candidate clocks
       input  wire sel,           // 0 = clk_a, 1 = clk_b
       output wire clk_out
   );
       reg sel_a_lat, sel_b_lat;
       wire sel_a, sel_b;
   
       // Synchronise sel into each clock domain using a latch
       always @(*) if (!clk_a) sel_a_lat <= ~sel & ~sel_b_lat;
       always @(*) if (!clk_b) sel_b_lat <=  sel & ~sel_a_lat;
   
       assign sel_a  = sel_a_lat;
       assign sel_b  = sel_b_lat;
       assign clk_out = (clk_a & sel_a) | (clk_b & sel_b);
   endmodule
   ```

3. **Voltage scaling coordination:**

   The voltage regulator (PMIC) must change V_DD before the frequency increases, and after the frequency decreases:
   
   ```
   Increasing performance (f up, V up):
     Step 1: Raise V_DD to new (higher) level. Wait for voltage to settle (10-100 µs).
     Step 2: Increase PLL output frequency.
   
   Decreasing performance (f down, V down):
     Step 1: Decrease PLL output frequency. Wait for new frequency to be active.
     Step 2: Lower V_DD. Wait for voltage to settle.
   
   Violation: if frequency is increased before V_DD is high enough, timing margin
   is insufficient and setup violations occur — corrupting flip-flop state silently.
   ```

**Risks during frequency transition:**

| Risk | Mechanism | Mitigation |
|------|-----------|------------|
| Glitch during source switch | Non-glitch-free MUX creates partial pulse | Latch-based glitch-free MUX |
| Metastability on source switch | MUX handshake synchroniser fails | Add sufficient margin cycles in bypass mode |
| Voltage undershoot during step-up | PMIC response is not instantaneous | Firmware waits for PMIC voltage-good signal before stepping frequency |
| Cache coherency during transition | Pending cache operations may see different timing before and after switch | Halt cache bus traffic (idle the interconnect) before switching |
| PLL lock lost during reprogramming | PLL output is invalid while relocking | Always switch to bypass clock before reprogramming PLL |
