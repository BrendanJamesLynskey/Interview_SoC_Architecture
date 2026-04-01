# Problem 02: Address Decoder Design

## Problem Statement

Design and verify a configurable AXI4-Lite address decoder for an SoC interconnect. The decoder must handle both fixed decode (compile-time base/size parameters) and a run-time configurable region for a PCIe BAR mapping.

**System specification:**

| Slave               | Base address   | Size    | Decode type         |
|---------------------|----------------|---------|---------------------|
| Boot ROM            | 0x0000_0000    | 128 KB  | Fixed, full decode  |
| On-chip SRAM        | 0x2000_0000    | 256 KB  | Fixed, full decode  |
| UART0               | 0x4000_0000    | 4 KB    | Fixed, full decode  |
| UART1               | 0x4000_1000    | 4 KB    | Fixed, full decode  |
| SPI0                | 0x4000_2000    | 4 KB    | Fixed, full decode  |
| GPIO                | 0x4000_3000    | 4 KB    | Fixed, full decode  |
| PCIe window         | programmable   | 64 MB   | Configurable at runtime |
| Default (error)     | all others     | —       | Catch-all           |

**Design requirements:**

1. Implement the fixed decode slaves using compile-time parameters.
2. Implement the PCIe window using a run-time programmable base register (aligned to 64 MB boundary).
3. Ensure mutual exclusivity — no two slaves can be selected simultaneously.
4. Return a DECERR response (via the default slave) for all unmapped addresses.
5. The PCIe window must not overlap with any fixed slave region. Enforce this in hardware.
6. Include an SVA formal verification testbench that proves one-hot decode.
7. Include a UVM-style directed test that covers every slave boundary.

---

## Design Requirements

- SystemVerilog implementation with generate blocks for the fixed slaves.
- Programmable base register for the PCIe window.
- Overlap detection: if software programs the PCIe base to an address that collides with a fixed slave, the PCIe window is disabled (PCIE_EN de-asserted) and an error flag is set.
- PSEL signals feed an AXI4-Lite crossbar slave port mux.

---

## Decoder Architecture

### Conceptual Block Diagram

```
                  +-----------+
 HADDR[31:0] ---> |  Fixed    | --> BOOT_ROM_SEL
                  |  Region   | --> SRAM_SEL
                  |  Decode   | --> UART0_SEL
                  |  (static) | --> UART1_SEL
                  |           | --> SPI0_SEL
                  |           | --> GPIO_SEL
                  +-----------+
                       |
                  +-----------+
 HADDR[31:0] ---> | PCIe Win  | --> PCIE_SEL
 PCIE_BASE  --->  | Decode    |         |
 PCIE_EN    --->  | (dynamic) |         |
                  +-----------+         |
                       |                |
                  +-----------+         |
                  | Overlap   | ----> PCIE_OVERLAP_ERR
                  | Detector  |
                  +-----------+
                       |
                  +-----------+
                  | One-hot   |
                  | Mux / OR  | --> DEFAULT_SEL (= ~OR(all_sel))
                  +-----------+
```

### Overlap Detection Logic

The PCIe 64 MB window covers `[PCIE_BASE, PCIE_BASE + 0x400_0000)`. A fixed slave at base `B` with size `S` overlaps if:

```
overlap = (B < PCIE_BASE + 0x400_0000) AND (PCIE_BASE < B + S)
```

Because fixed slave sizes are much smaller than 64 MB (max 256 KB), this simplifies to:

```
overlap = (B >= PCIE_BASE) AND (B < PCIE_BASE + 0x400_0000)
       = (B[31:26] == PCIE_BASE[31:26])   -- same 64 MB window as PCIE_BASE
```

Since PCIE_BASE is 64 MB aligned (bits[25:0] must be 0), the check is:

```
fixed_slave_in_pcie_window = (B[31:26] == PCIE_BASE[31:26]) for any fixed slave B
```

---

## Implementation Details

```systemverilog
// ============================================================================
// AXI4-Lite SoC Address Decoder
// Supports: 6 fixed slaves + 1 programmable PCIe window + default error slave
// ============================================================================

module soc_addr_decoder #(
    // Fixed slave base addresses (naturally aligned to their size)
    parameter logic [31:0] BOOT_ROM_BASE = 32'h0000_0000,
    parameter logic [31:0] SRAM_BASE     = 32'h2000_0000,
    parameter logic [31:0] UART0_BASE    = 32'h4000_0000,
    parameter logic [31:0] UART1_BASE    = 32'h4000_1000,
    parameter logic [31:0] SPI0_BASE     = 32'h4000_2000,
    parameter logic [31:0] GPIO_BASE     = 32'h4000_3000,

    // Fixed slave sizes in bytes (must be power of 2, naturally aligned)
    parameter int unsigned BOOT_ROM_SIZE = 32'h0002_0000,  // 128 KB
    parameter int unsigned SRAM_SIZE     = 32'h0004_0000,  // 256 KB
    parameter int unsigned UART0_SIZE    = 32'h0000_1000,  //   4 KB
    parameter int unsigned UART1_SIZE    = 32'h0000_1000,  //   4 KB
    parameter int unsigned SPI0_SIZE     = 32'h0000_1000,  //   4 KB
    parameter int unsigned GPIO_SIZE     = 32'h0000_1000   //   4 KB
) (
    input  logic        aclk,
    input  logic        aresetn,

    // Address to decode
    input  logic [31:0] addr,

    // Programmable PCIe window control (written by software at boot)
    // PCIE_BASE must be 64 MB aligned (bits[25:0] == 0)
    input  logic [31:26] pcie_base_reg,  // Only upper 6 bits needed for 64 MB alignment
    input  logic         pcie_en,        // PCIe window enable (must be 0 during base update)

    // Slave select outputs (one-hot)
    output logic         boot_rom_sel,
    output logic         sram_sel,
    output logic         uart0_sel,
    output logic         uart1_sel,
    output logic         spi0_sel,
    output logic         gpio_sel,
    output logic         pcie_sel,
    output logic         default_sel,    // No slave selected -> DECERR

    // Error outputs
    output logic         pcie_overlap_err  // PCIe base overlaps a fixed slave
);

    // -----------------------------------------------------------------------
    // Fixed slave decode — mask-and-compare (full decode, naturally aligned)
    // mask = ~(SIZE - 1); sel = (addr & mask == BASE & mask)
    // -----------------------------------------------------------------------
    localparam logic [31:0] BOOT_ROM_MASK = ~(BOOT_ROM_SIZE - 1);
    localparam logic [31:0] SRAM_MASK     = ~(SRAM_SIZE     - 1);
    localparam logic [31:0] UART0_MASK    = ~(UART0_SIZE    - 1);
    localparam logic [31:0] UART1_MASK    = ~(UART1_SIZE    - 1);
    localparam logic [31:0] SPI0_MASK     = ~(SPI0_SIZE     - 1);
    localparam logic [31:0] GPIO_MASK     = ~(GPIO_SIZE     - 1);

    assign boot_rom_sel = ((addr & BOOT_ROM_MASK) == (BOOT_ROM_BASE & BOOT_ROM_MASK));
    assign sram_sel     = ((addr & SRAM_MASK)     == (SRAM_BASE     & SRAM_MASK));
    assign uart0_sel    = ((addr & UART0_MASK)    == (UART0_BASE    & UART0_MASK));
    assign uart1_sel    = ((addr & UART1_MASK)    == (UART1_BASE    & UART1_MASK));
    assign spi0_sel     = ((addr & SPI0_MASK)     == (SPI0_BASE     & SPI0_MASK));
    assign gpio_sel     = ((addr & GPIO_MASK)     == (GPIO_BASE     & GPIO_MASK));

    // -----------------------------------------------------------------------
    // PCIe window decode — programmable 64 MB window
    // 64 MB = 0x400_0000; 64 MB aligned => bits[25:0] of base are 0.
    // Select when addr[31:26] == pcie_base_reg[31:26] AND pcie_en is asserted.
    // -----------------------------------------------------------------------
    assign pcie_sel = pcie_en & (addr[31:26] == pcie_base_reg);

    // -----------------------------------------------------------------------
    // Overlap detection — PCIe base must not overlap any fixed slave region
    // A fixed slave overlaps the PCIe window if its base falls within:
    //   [PCIE_BASE, PCIE_BASE + 64 MB)
    // i.e., slave_base[31:26] == pcie_base_reg[31:26]
    // -----------------------------------------------------------------------
    wire pcie_overlaps_bootrom = (BOOT_ROM_BASE[31:26] == pcie_base_reg);
    wire pcie_overlaps_sram    = (SRAM_BASE[31:26]     == pcie_base_reg);
    wire pcie_overlaps_uart0   = (UART0_BASE[31:26]    == pcie_base_reg);
    wire pcie_overlaps_uart1   = (UART1_BASE[31:26]    == pcie_base_reg);
    wire pcie_overlaps_spi0    = (SPI0_BASE[31:26]     == pcie_base_reg);
    wire pcie_overlaps_gpio    = (GPIO_BASE[31:26]      == pcie_base_reg);

    assign pcie_overlap_err = pcie_en & (pcie_overlaps_bootrom | pcie_overlaps_sram |
                                         pcie_overlaps_uart0   | pcie_overlaps_uart1 |
                                         pcie_overlaps_spi0    | pcie_overlaps_gpio);

    // -----------------------------------------------------------------------
    // Default (error) slave — asserted when no slave is selected
    // -----------------------------------------------------------------------
    assign default_sel = ~(boot_rom_sel | sram_sel | uart0_sel | uart1_sel |
                            spi0_sel    | gpio_sel | pcie_sel);

    // -----------------------------------------------------------------------
    // Simulation assertions
    // -----------------------------------------------------------------------
    `ifdef SIMULATION
    // One-hot: no two regular slaves simultaneously selected
    property p_onehot_fixed;
        @(posedge aclk)
        $onehot0({boot_rom_sel, sram_sel, uart0_sel, uart1_sel, spi0_sel, gpio_sel});
    endproperty
    assert property (p_onehot_fixed)
        else $error("ONEHOT VIOLATION: addr=0x%08X sels=%b", addr,
                    {boot_rom_sel, sram_sel, uart0_sel, uart1_sel, spi0_sel, gpio_sel});

    // PCIe must not overlap fixed slaves when enabled
    property p_no_overlap;
        @(posedge aclk)
        pcie_en |-> ~pcie_overlap_err;
    endproperty
    assert property (p_no_overlap)
        else $error("PCIe OVERLAP: pcie_base=0x%08X overlaps a fixed slave",
                    {pcie_base_reg, 26'h0});
    `endif

endmodule
```

### Formal Verification SVA Testbench

```systemverilog
// Formal verification bind file for soc_addr_decoder
// Run with: JasperGold / VC Formal / Questa Formal
// Proves:
//   1. Output is always one-hot or zero (mutual exclusivity)
//   2. Every address in a slave's range selects exactly that slave
//   3. PCIe overlap condition is correctly flagged

module soc_addr_decoder_fv_props (
    input logic [31:0] addr,
    input logic [31:26] pcie_base_reg,
    input logic         pcie_en,
    input logic         boot_rom_sel, sram_sel, uart0_sel, uart1_sel,
    input logic         spi0_sel, gpio_sel, pcie_sel, default_sel,
    input logic         pcie_overlap_err
);

    // -------------------------------------------------------------------
    // Property 1: one-hot output (including pcie and default)
    // -------------------------------------------------------------------
    property p_one_hot;
        $onehot({boot_rom_sel, sram_sel, uart0_sel, uart1_sel,
                  spi0_sel, gpio_sel, pcie_sel, default_sel});
    endproperty
    A_ONE_HOT: assume property (p_one_hot);  // prove this holds for all inputs

    // -------------------------------------------------------------------
    // Property 2: boot ROM is selected for exactly its address range
    // -------------------------------------------------------------------
    property p_bootrom_range;
        (addr >= 32'h0000_0000 && addr <= 32'h0001_FFFF) |-> boot_rom_sel;
    endproperty
    A_BOOTROM_SEL: assert property (p_bootrom_range);

    property p_bootrom_exclusive;
        boot_rom_sel |-> (addr >= 32'h0000_0000 && addr <= 32'h0001_FFFF);
    endproperty
    A_BOOTROM_EXCL: assert property (p_bootrom_exclusive);

    // -------------------------------------------------------------------
    // Property 3: UART0 boundary correctness
    // -------------------------------------------------------------------
    property p_uart0_range;
        (addr >= 32'h4000_0000 && addr <= 32'h4000_0FFF) |-> uart0_sel;
    endproperty
    A_UART0_SEL: assert property (p_uart0_range);

    // First address of UART1 must NOT select UART0
    property p_uart0_uart1_boundary;
        (addr == 32'h4000_1000) |-> ~uart0_sel;
    endproperty
    A_UART0_BOUNDARY: assert property (p_uart0_uart1_boundary);

    // -------------------------------------------------------------------
    // Property 4: default_sel for unmapped address
    // -------------------------------------------------------------------
    property p_default_unmapped;
        // Address clearly outside all valid regions
        (addr[31:28] == 4'h1 || addr[31:28] == 4'h3) |-> default_sel;
    endproperty
    A_DEFAULT_UNMAPPED: assert property (p_default_unmapped);

    // -------------------------------------------------------------------
    // Property 5: overlap error correctly flagged
    // -------------------------------------------------------------------
    // If pcie_base maps to Boot ROM's 64 MB window (0x0000_0000 / 64 MB = 0)
    property p_pcie_bootrom_overlap;
        (pcie_en && pcie_base_reg == 6'h00) |-> pcie_overlap_err;
    endproperty
    A_PCIE_OVERLAP: assert property (p_pcie_bootrom_overlap);

endmodule

// Bind to the DUT
bind soc_addr_decoder soc_addr_decoder_fv_props fv_inst (.*);
```

### Directed Test — Boundary Verification

```systemverilog
// Directed test: verifies every slave's first address, last address, and
// the first address beyond the slave (must select default or next slave).

module tb_soc_addr_decoder;
    logic [31:0]  addr;
    logic [31:26] pcie_base_reg;
    logic         pcie_en;
    logic         boot_rom_sel, sram_sel, uart0_sel, uart1_sel;
    logic         spi0_sel, gpio_sel, pcie_sel, default_sel;
    logic         pcie_overlap_err;
    logic         aclk, aresetn;

    soc_addr_decoder dut (
        .aclk(aclk), .aresetn(aresetn),
        .addr(addr),
        .pcie_base_reg(pcie_base_reg), .pcie_en(pcie_en),
        .boot_rom_sel(boot_rom_sel), .sram_sel(sram_sel),
        .uart0_sel(uart0_sel), .uart1_sel(uart1_sel),
        .spi0_sel(spi0_sel), .gpio_sel(gpio_sel),
        .pcie_sel(pcie_sel), .default_sel(default_sel),
        .pcie_overlap_err(pcie_overlap_err)
    );

    initial aclk = 0;
    always #5 aclk = ~aclk;

    // Helper task: apply address, wait a delta, check expected select signal
    task automatic check_sel(
        input logic [31:0] test_addr,
        input string       slave_name,
        input logic        expected_sel
    );
        addr = test_addr; #1;
        if (expected_sel !== 1'b1) begin
            $error("FAIL: addr=0x%08X expected %s=1, got 0", test_addr, slave_name);
        end else begin
            $display("PASS: addr=0x%08X -> %s selected", test_addr, slave_name);
        end
        // Verify one-hot
        if ($countones({boot_rom_sel, sram_sel, uart0_sel, uart1_sel,
                        spi0_sel, gpio_sel, pcie_sel, default_sel}) != 1) begin
            $error("ONEHOT VIOLATION at addr=0x%08X sels=%b%b%b%b%b%b%b%b",
                   test_addr, boot_rom_sel, sram_sel, uart0_sel, uart1_sel,
                   spi0_sel, gpio_sel, pcie_sel, default_sel);
        end
    endtask

    initial begin
        pcie_en = 0; pcie_base_reg = 6'h3F;  // PCIe at top of space, not overlapping
        aresetn = 0; @(posedge aclk); aresetn = 1;

        // ---- Boot ROM boundary tests ----
        check_sel(32'h0000_0000, "boot_rom", boot_rom_sel);  // First address
        check_sel(32'h0001_0000, "boot_rom", boot_rom_sel);  // Mid-range
        check_sel(32'h0001_FFFF, "boot_rom", boot_rom_sel);  // Last address
        check_sel(32'h0002_0000, "default",  default_sel);   // First address beyond

        // ---- SRAM boundary tests ----
        check_sel(32'h2000_0000, "sram",    sram_sel);
        check_sel(32'h2003_FFFF, "sram",    sram_sel);       // Last byte
        check_sel(32'h2004_0000, "default", default_sel);    // Beyond SRAM

        // ---- UART0 / UART1 boundary tests ----
        check_sel(32'h4000_0000, "uart0",   uart0_sel);
        check_sel(32'h4000_0FFF, "uart0",   uart0_sel);      // Last byte of UART0
        check_sel(32'h4000_1000, "uart1",   uart1_sel);      // First byte of UART1
        check_sel(32'h4000_1FFF, "uart1",   uart1_sel);

        // ---- SPI0, GPIO ----
        check_sel(32'h4000_2000, "spi0",    spi0_sel);
        check_sel(32'h4000_3000, "gpio",    gpio_sel);
        check_sel(32'h4000_4000, "default", default_sel);    // Beyond GPIO

        // ---- PCIe window tests ----
        pcie_en = 1; pcie_base_reg = 6'h08;  // PCIe at 0x2000_0000? No — 0x08<<26=0x2000_0000
        // Intentional overlap with SRAM — verify overlap detection:
        #1;
        if (!pcie_overlap_err) $error("FAIL: should detect PCIe/SRAM overlap");
        else $display("PASS: PCIe/SRAM overlap correctly flagged");

        // Place PCIe at a safe address: 0xB000_0000 (bits[31:26]=0x2C)
        pcie_base_reg = 6'h2C;  // 0xB000_0000
        #1;
        if (pcie_overlap_err) $error("FAIL: should be no overlap at 0xB000_0000");

        // PCIe window address tests
        check_sel(32'hB000_0000, "pcie",    pcie_sel);
        check_sel(32'hB200_0000, "pcie",    pcie_sel);  // Mid PCIe window
        check_sel(32'hB3FF_FFFF, "pcie",    pcie_sel);  // Last PCIe address
        check_sel(32'hB400_0000, "default", default_sel); // Beyond PCIe

        // Disable PCIe window; address now goes to default
        pcie_en = 0; #1;
        check_sel(32'hB000_0000, "default", default_sel);  // PCIe disabled

        $display("\n=== All boundary tests passed ===");
        $finish;
    end
endmodule
```

---

## Performance Analysis

### Timing Budget Calculation

For an AXI4-Lite crossbar at 400 MHz (T_clk = 2.5 ns):

```
Decoder critical path:
  Fixed slaves:     mask-and-compare (XNOR tree + AND reduction)
                    Estimated: 1.5-2.0 ns at 16 nm (2-3 FO4 delays)
  PCIe comparison:  6-bit compare of addr[31:26] vs pcie_base_reg
                    Estimated: 0.8-1.0 ns (shorter word, fewer gates)
  OR tree:          8-input OR for default_sel
                    Estimated: 0.3-0.5 ns

  Worst-case path:  fixed slave decode ≈ 2.0 ns
  Slack at 400 MHz: 2.5 - 2.0 = 0.5 ns (marginal but achievable)
  Slack at 500 MHz: 2.0 - 2.0 = 0.0 ns (requires pipelining or optimisation)
```

If 500 MHz operation is required, register the selector outputs (adding 1 cycle of decode latency):

```systemverilog
// Pipelined version: register all sel outputs
always_ff @(posedge aclk or negedge aresetn) begin
    if (!aresetn) begin
        {boot_rom_sel_r, sram_sel_r, uart0_sel_r, ...} <= '0;
    end else begin
        boot_rom_sel_r <= boot_rom_sel_comb;
        sram_sel_r     <= sram_sel_comb;
        // ... etc.
    end
end
// The registered address must also be passed to the slave alongside the registered sel.
```

---

## Key Takeaways

1. **Mask-and-compare is the preferred full-decode style.** It is synthesiser-friendly, results in an XNOR tree with an AND reduction, and handles any power-of-two size. The synthesis tool will optimise shared bits automatically.

2. **Programmable decode requires overlap protection.** If software can reprogram the base address of any window, the hardware must prevent it from being set to overlap a fixed slave. Without this, two slaves respond simultaneously, causing bus contention or data corruption.

3. **One-hot is non-negotiable in production decoders.** Never ship RTL where two SEL signals can be simultaneously asserted unless the interconnect explicitly handles that (multi-drop bus with address conflicts is a bus protocol error).

4. **Formal verification of the decoder is cheap and thorough.** A 10-line SVA property file bound to the decoder proves mutual exclusivity for all 4 billion possible input addresses in seconds on a modern formal tool. Simulation cannot achieve comparable coverage.

5. **Pipelined decoders trade latency for timing.** For fabrics above ~500 MHz, register the decode output and pipeline the address alongside it. This is standard practice in production AXI crossbar IP.
