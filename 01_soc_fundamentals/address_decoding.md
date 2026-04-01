# Address Decoding

## Prerequisites
- Binary and hexadecimal arithmetic
- Memory map concepts (base addresses, region sizes, alignment)
- Basic combinational logic (AND, OR, comparators, multiplexers)
- SoC interconnect fundamentals (AXI, APB bus structure)

---

## Concept Reference

### What Address Decoding Does

When a bus master (CPU, DMA) issues a transaction, the interconnect fabric must determine which slave should receive it. The address decoder examines the address presented on the bus and asserts exactly one slave-select signal. It is part of the critical timing path for every bus transaction.

```
Bus master issues:  ADDR = 0x4000_1000
                    WDATA = 0xDEAD_BEEF

         +------------------+
ADDR --->|  Address Decoder | ---> UART0_SEL  = 0
         |                  | ---> UART1_SEL  = 1  (0x4000_1000 is UART1)
         |                  | ---> SPI0_SEL   = 0
         |                  | ---> SRAM_SEL   = 0
         +------------------+

Only UART1 receives the transaction data and generates a response.
```

### Full Decode vs Partial Decode

**Full decode:** Every address bit that can distinguish this slave from any other is checked. Only the intended address range asserts the select.

```
Full decode — UART1 at 0x4000_1000 (4 KB page, 32-bit address):
  addr[31:12] == 20'h40001

  Decodes as: 0100 0000 0000 0000 0001 xxxx xxxx xxxx
              ^^^^^^^^^^^^^^^^^^^^^^^^^^^
              These 20 bits checked; lower 12 bits are offset within UART1.

  Exactly one 4 KB page maps to UART1 — no aliases.
```

**Partial decode:** Only a subset of address bits are checked. Bits not checked create aliases — multiple addresses map to the same slave.

```
Partial decode — UART1 checked only on bits [15:12]:
  addr[15:12] == 4'h1

  Matches: 0x????_1??? — any address where bits[15:12]==1, regardless of upper bits.
  Aliases: 0x0000_1000, 0x0001_1000, 0x4000_1000, 0x8000_1000, 0xFFFF_1000 all select UART1.
  Alias stride: 2^16 = 64 KB (every 64 KB boundary with bits[15:12]==1 is an alias).
```

### Decoder Architectures

**1. Combinational case statement / if-else chain (small designs)**

```verilog
// 4-slave decoder, naturally aligned 4 KB pages
always_comb begin
    sel = 4'b0000;
    if      (addr[31:12] == 20'h00000) sel[0] = 1'b1; // FLASH
    else if (addr[31:12] == 20'h20000) sel[1] = 1'b1; // SRAM
    else if (addr[31:12] == 20'h40000) sel[2] = 1'b1; // UART0
    else if (addr[31:12] == 20'h40001) sel[3] = 1'b1; // UART1
    // else: default slave (returns error)
end
```

**2. Parallel AND-gate decoder (best timing)**

```verilog
// All select lines computed simultaneously — one gate level
wire [3:0] sel;
assign sel[0] = (addr[31:12] == 20'h00000); // FLASH
assign sel[1] = (addr[31:12] == 20'h20000); // SRAM
assign sel[2] = (addr[31:12] == 20'h40000); // UART0
assign sel[3] = (addr[31:12] == 20'h40001); // UART1
```

**3. Priority encoder (when ranges overlap or for default-slave logic)**

```verilog
// Useful when a range-based decode is needed or default slave is required
always_comb begin
    sel = '0;
    casez (addr[31:20])
        12'h000:        sel[0] = 1;  // 0x000?_????  (Flash, 16 MB range)
        12'h200:        sel[1] = 1;  // 0x200?_????  (SRAM)
        12'h400:        sel[2] = 1;  // 0x400?_????  (Peripherals)
        default:        sel[3] = 1;  // All others -> default/error slave
    endcase
end
```

### Address Aliasing Consequences

| Scenario                    | Risk                                              |
|-----------------------------|---------------------------------------------------|
| Peripheral aliased into DRAM range | Software bug reads peripheral instead of DRAM     |
| Secure peripheral aliased into non-secure range | Security bypass — attacker accesses privileged register |
| SRAM aliased at multiple addresses | Debugger confusion; MPU protection bypass        |
| Two peripherals decode identically | Both driven simultaneously; bus contention (if tri-state bus) or both respond (X propagation in simulation) |

---

## Tier 1 — Fundamentals

### Question F1
**Explain the difference between full address decoding and partial address decoding. Which is used in modern SoC designs and why?**

**Answer:**

**Full address decoding** checks every address bit that is needed to uniquely identify a slave. The decoder ensures one and only one slave is selected for any given address, and every other address maps to a default slave (which returns a bus error).

**Partial address decoding** checks only a subset of address bits, typically to save gate count in designs with small address spaces where the unused regions are never populated. The unchecked bits create address aliases.

**Modern SoC practice — full decode:**

Modern SoCs exclusively use full address decoding for four reasons:

1. **Security:** Partial decode creates unintended access paths to privileged registers. An attacker who knows a peripheral is partially decoded can access it from an address that the MMU/MPU has not restricted.

2. **Address space density:** Modern SoCs populate large fractions of their address space. Aliases would cause accidental peripheral accesses when software iterates through memory (e.g., during memory test or DMA operations).

3. **Tooling:** EDA tools (address map generators, UVM register model generators) assume full decode. Partial decode must be documented explicitly and handled as a special case in verification.

4. **Gate count is not the bottleneck:** The area cost of a complete comparator for a 32-bit address is negligible compared to the data path logic of the peripheral itself. The design tools implement equality comparators efficiently as XNOR trees.

**The only accepted use of partial decode today:** AMBA interconnect IP sometimes uses partial decode internally within the interconnect fabric (e.g., a pre-decoded region select signal derived from a fast top-level decode), but this is a controlled optimisation with all aliases accounted for, not an unintentional side effect.

---

### Question F2
**Derive the decoder logic for a 4-slave system with the following memory map. State the exact logic equation for each slave select signal.**

```
Slave      Base address    Size
------     ---------------  -----
ROM        0x0000_0000      64 KB
SRAM       0x2000_0000      32 KB
UART0      0x4000_0000       4 KB
UART1      0x4000_1000       4 KB
```

**Answer:**

**Step 1 — Identify the number of address bits needed per slave:**

- ROM (64 KB = 2^16): addr[31:16] selects the 64 KB page, addr[15:0] is the offset.
- SRAM (32 KB = 2^15): addr[31:15] selects the 32 KB block, addr[14:0] is offset.
- UART0 (4 KB = 2^12): addr[31:12] selects the 4 KB page, addr[11:0] is offset.
- UART1 (4 KB = 2^12): addr[31:12] selects the 4 KB page, addr[11:0] is offset.

**Step 2 — Extract the comparison values:**

```
ROM:   base = 0x0000_0000 => addr[31:16] = 16'h0000
SRAM:  base = 0x2000_0000 => addr[31:15] = 17'h10000
UART0: base = 0x4000_0000 => addr[31:12] = 20'h40000
UART1: base = 0x4000_1000 => addr[31:12] = 20'h40001
```

**Step 3 — Write the logic equations:**

```verilog
module addr_decoder (
    input  wire [31:0] addr,
    output wire        rom_sel,
    output wire        sram_sel,
    output wire        uart0_sel,
    output wire        uart1_sel,
    output wire        default_sel  // bus error / no slave selected
);

    assign rom_sel    = (addr[31:16] == 16'h0000);
    assign sram_sel   = (addr[31:15] == 17'h10000);
    assign uart0_sel  = (addr[31:12] == 20'h40000);
    assign uart1_sel  = (addr[31:12] == 20'h40001);

    // Default slave: asserted when no other slave is selected
    assign default_sel = ~(rom_sel | sram_sel | uart0_sel | uart1_sel);

endmodule
```

**Step 4 — Verify mutual exclusivity:**

No two slaves can be selected simultaneously because:
- ROM and SRAM have different bits[31:28] (0x0 vs 0x2).
- UART0 and UART1 have different bits[31:12] (0x40000 vs 0x40001) — they differ at bit[12].
- ROM/SRAM and UARTs have different bits[31:28] (0x0/0x2 vs 0x4).

The decoder is one-hot: at most one select is asserted at any time. The default_sel is asserted for all other addresses.

---

### Question F3
**Why is address decoder placement on the critical timing path a concern? What techniques are used to keep the decoder fast?**

**Answer:**

**Why timing matters:**

In an AXI or AHB bus, the address phase begins on the rising clock edge. The slave-select signal must be valid before the first data transfer can occur. The sequence is:

```
Cycle N:   Master presents ADDR on bus
           Address decoder evaluates: ADDR -> slave_sel
           Slave uses slave_sel to enable its response

Timing constraint: T_decode must satisfy the setup time of the slave's
                   address registers:
                   T_decode + T_routing + T_setup <= T_clk

At 500 MHz (T_clk = 2 ns), with T_routing = 0.3 ns and T_setup = 0.2 ns:
  T_decode_max = 2.0 - 0.3 - 0.2 = 1.5 ns
```

For a 32-slave AXI crossbar running at 1 GHz, T_decode_max may be as low as 0.5-0.7 ns.

**Techniques to keep the decoder fast:**

1. **Parallel (one-hot) comparison:** Compute all slave-selects simultaneously using independent comparators rather than a priority chain. A priority chain (if-else-if) has a critical path that grows linearly with the number of slaves.

2. **Reduce bits under comparison:** Use naturally aligned regions so only log2(size) bits determine the select, not all 32. A 1 MB aligned region requires checking only 12 bits rather than 20.

3. **Hierarchical decode:** A two-stage decoder checks a few high-order bits in stage 1 (selects a subsystem bus) and a few low-order bits in stage 2. Each stage has a short critical path. The total latency is the sum of two small delays, which is less than one large delay for the same number of slaves.

4. **Register the decode output:** For AXI designs where the address phase and data phase are already pipelined, register the slave-select signal and accept 1-cycle decode latency. This trades area (a set of flip-flops) for timing headroom.

5. **Pre-decode in the interconnect:** Many AXI crossbar implementations pre-decode the upper address bits into a "region" signal that the top-level router uses, deferring fine-grained page-select to the regional decoder.

---

## Tier 2 — Intermediate

### Question I1
**Implement a parameterisable APB address decoder in SystemVerilog that supports N slaves, each with a configurable base address and size (both power-of-two, naturally aligned). Include protection against double-mapping.**

**Answer:**

```systemverilog
// Parameterisable APB address decoder
// Supports N naturally-aligned, power-of-two slaves
// Parameters: N = number of slaves
//             BASE[N] = array of base addresses
//             SIZE[N] = array of region sizes in bytes (must be power of 2)
//
// Outputs: PSEL[N] — one-hot slave select
//          PSEL_NONE — high when no slave is addressed (bus error)

module apb_addr_decoder #(
    parameter int unsigned N = 4,
    // Default: 4 slaves at 4 KB pages in peripheral space
    parameter logic [31:0] BASE [N] = '{32'h4000_0000,
                                        32'h4000_1000,
                                        32'h4000_2000,
                                        32'h4000_3000},
    parameter int unsigned SIZE [N] = '{4096, 4096, 4096, 4096}
) (
    input  logic [31:0] PADDR,
    output logic [N-1:0] PSEL,
    output logic         PSEL_NONE  // asserted when no slave selected
);

    // For each slave i, compute the number of offset bits = log2(SIZE[i])
    // The mask for comparison is ~(SIZE[i]-1), covering all non-offset bits.
    // PSEL[i] is asserted when (PADDR & mask[i]) == BASE[i]

    // Synthesis-time computation of masks
    // In practice, SIZE is always a power of 2 so SIZE-1 is all ones in lower bits.

    genvar i;
    generate
        for (i = 0; i < N; i++) begin : gen_sel
            // mask: all 1s in bits above the offset, 0s in offset bits
            // mask = ~(SIZE[i] - 1)
            localparam logic [31:0] MASK_i = ~(SIZE[i] - 1);

            assign PSEL[i] = ((PADDR & MASK_i) == (BASE[i] & MASK_i));
        end
    endgenerate

    // PSEL_NONE: no slave claimed this address
    assign PSEL_NONE = (PSEL == '0);

    // Assertion: PSEL must be one-hot or zero (no two slaves decode same address)
    // This checks for double-mapping at elaboration time if the parameter values
    // cause an overlap. Simulators evaluate this; formal tools prove it statically.
    `ifdef SIMULATION
    always_comb begin
        if ($countones(PSEL) > 1) begin
            $error("APB decoder: multiple slaves selected simultaneously! PADDR=0x%08X PSEL=0b%b",
                   PADDR, PSEL);
        end
    end
    `endif

endmodule
```

**Double-mapping detection — static check:**

To catch overlapping regions at elaboration time, add a module-level assertion or generate block:

```systemverilog
// Static overlap check (evaluated at elaboration, not runtime)
generate
    for (genvar j = 0; j < N; j++) begin : chk_outer
        for (genvar k = j+1; k < N; k++) begin : chk_inner
            // Region j: [BASE[j], BASE[j]+SIZE[j])
            // Region k: [BASE[k], BASE[k]+SIZE[k])
            // Overlap if: BASE[j] < BASE[k]+SIZE[k] && BASE[k] < BASE[j]+SIZE[j]
            if ((BASE[j] < (BASE[k] + SIZE[k])) && (BASE[k] < (BASE[j] + SIZE[j]))) begin
                // This generate block will instantiate only if overlap exists
                // Use initial + $fatal to abort elaboration on overlap
                initial begin
                    $fatal(1, "APB decoder: Region %0d and Region %0d overlap!", j, k);
                end
            end
        end
    end
endgenerate
```

**Testbench verification:**

```systemverilog
module tb_apb_addr_decoder;
    logic [31:0] paddr;
    logic [3:0]  psel;
    logic        psel_none;

    // 4 slaves: UART0 @ 0x4000_0000, UART1 @ 0x4000_1000,
    //           SPI0  @ 0x4000_2000, I2C0  @ 0x4000_3000 (each 4 KB)
    apb_addr_decoder #(
        .N(4),
        .BASE('{32'h40000000, 32'h40001000, 32'h40002000, 32'h40003000}),
        .SIZE('{4096, 4096, 4096, 4096})
    ) dut (.PADDR(paddr), .PSEL(psel), .PSEL_NONE(psel_none));

    task check(input [31:0] addr, input [3:0] exp_sel, input exp_none);
        paddr = addr; #1;
        assert (psel == exp_sel && psel_none == exp_none)
            else $error("FAIL: addr=0x%08X got psel=%b psel_none=%b, expected psel=%b none=%b",
                        addr, psel, psel_none, exp_sel, exp_none);
        $display("PASS: addr=0x%08X psel=%b psel_none=%b", addr, psel, psel_none);
    endtask

    initial begin
        check(32'h40000000, 4'b0001, 1'b0); // UART0 base
        check(32'h40000FFF, 4'b0001, 1'b0); // UART0 last byte
        check(32'h40001000, 4'b0010, 1'b0); // UART1 base
        check(32'h40002800, 4'b0100, 1'b0); // SPI0 mid-page
        check(32'h40003FFF, 4'b1000, 1'b0); // I2C0 last byte
        check(32'h40004000, 4'b0000, 1'b1); // Beyond all slaves -> default
        check(32'h00000000, 4'b0000, 1'b1); // ROM space -> not in this decoder
        $finish;
    end
endmodule
```

---

### Question I2
**What is a default slave (or error slave) in an AMBA interconnect? When is it triggered, and what response should it return?**

**Answer:**

A **default slave** is the target of any transaction that does not decode to a valid slave in the address map. Without one, an unmapped access would stall the bus indefinitely — no slave would ever assert PREADY (APB) or RVALID/BVALID (AXI).

**When it is triggered:**
- Software bug: a null pointer dereference or unchecked pointer arithmetic reaches an unmapped region.
- Memory test: a sweep of the address space intentionally probes all addresses.
- Fuzzing: a security researcher or automated tool sends random addresses.
- Speculative fetch: a CPU branch predictor speculatively reads an instruction from a non-existent address.

**Required response by AMBA specification:**

For APB: the default slave must assert PREADY and return PSLVERR=1 (slave error). It must not hang indefinitely.

For AXI4: the default slave must:
- On a read: return RVALID with RRESP = 2'b10 (SLVERR) or 2'b11 (DECERR). DECERR is preferred to indicate the address did not decode to a valid slave.
- On a write: return BVALID with BRESP = 2'b11 (DECERR).
- Accept the full burst (RDATA can be 0 or don't-care; the requester receives RRESP=DECERR for each beat).

```verilog
// Minimal AXI4-Lite default/error slave
// Returns DECERR for all accesses — used as the AMBA "default slave"
module axi4lite_default_slave (
    input  wire        aclk, aresetn,
    // Write address channel
    input  wire        awvalid,
    output wire        awready,
    // Write data channel
    input  wire        wvalid,
    output wire        wready,
    // Write response channel
    output wire [1:0]  bresp,
    output wire        bvalid,
    input  wire        bready,
    // Read address channel
    input  wire        arvalid,
    output wire        arready,
    // Read data channel
    output wire [31:0] rdata,
    output wire [1:0]  rresp,
    output wire        rvalid,
    input  wire        rready
);
    // Accept addresses immediately; return DECERR on response channels
    assign awready = 1'b1;
    assign wready  = 1'b1;
    assign arready = 1'b1;

    // Write response: DECERR (2'b11)
    assign bvalid  = 1'b1;   // always valid (simplification; a full impl tracks AWvalid)
    assign bresp   = 2'b11;  // DECERR

    // Read response: DECERR, data = 0
    assign rvalid  = 1'b1;
    assign rdata   = 32'h0;
    assign rresp   = 2'b11;  // DECERR

    // Note: a production implementation should use a proper state machine
    // to track outstanding transactions and return one DECERR per transaction,
    // not continuously assert bvalid/rvalid. This simplified version works
    // for single-outstanding-transaction buses.
endmodule
```

**Processor response to DECERR:**

- ARM Cortex-M: generates a HardFault or BusFault (if BusFault is enabled and not escalated). The fault handler reads the BFAR (Bus Fault Address Register) to identify the offending address.
- ARM Cortex-A: generates a synchronous external abort (SEA), handled as an abort exception. The OS can catch this and send SIGSEGV to the offending process.

---

## Tier 3 — Advanced

### Question A1
**An AXI crossbar with 8 masters and 16 slaves must decode addresses within 1 ns at 1 GHz. Describe the decoder architecture you would choose, justify the timing, and discuss how address mapping registers (programmable memory maps) change the problem.**

**Answer:**

**Static decode at 1 GHz (1 ns budget):**

With 16 slaves and a 1 ns budget, the decoder must complete in approximately 3-4 CMOS gate delays at a typical 7-16 nm process (FO4 delay ~30-50 ps at 7 nm, ~50-80 ps at 16 nm).

**Architecture: Two-level hierarchical parallel decode**

```
Level 1 (checks addr[31:24] — upper 8 bits, 3 or 4 gate delays):
  Divides 16 slaves into 4 groups of 4:
    Group 0: addr[31:24] == 8'h00  (Code space: Flash, ROM)
    Group 1: addr[31:24] == 8'h20  (SRAM space)
    Group 2: addr[31:24] == 8'h40  (Peripheral space: UARTs, SPI, I2C, Timers)
    Group 3: addr[31:24] == 8'hE0  (System/Private space: NVIC, debug)

Level 2 (checks addr[23:12] — next 12 bits, run in parallel with Level 1):
  Each group's secondary decoder fires only when its group is selected.
  The group select gates the secondary outputs via an AND.

Combined output:
  slave_sel[i] = group_sel[group_of_i] AND page_sel_within_group[i]

  The AND is one additional gate delay.
  Total: Level1_delay + 1 AND ≈ 4 gate delays ≈ 0.2-0.4 ns at 7nm.
  Well within 1 ns budget.
```

**Why not a flat 16-way decoder?**

A flat parallel decoder for 16 slaves also has only one level of comparators — it is not inherently slower than hierarchical. The hierarchical approach is preferred because:

1. Routing is localised — only 4 wires fan out from the primary decoder to the secondary decoders, rather than 32-bit address fanning out to 16 comparators globally.
2. Power is saved — only the secondary decoder for the addressed group evaluates; the other three are clock-gated or input-stable.
3. Physical design is cleaner — each secondary decoder is placed near its slave group.

**Programmable address maps (configurable decode):**

Some SoCs require run-time configurable address maps: a PCIe root complex that maps BARs, a hypervisor that remaps guest physical addresses, or a boot ROM alias that remaps at reset. This changes the decoder from a purely combinational compare to a register-based lookup.

```
Option 1: CAM (Content-Addressable Memory) decoder
  Each slave has a base register and mask register:
    slave_sel[i] = (addr & mask_reg[i]) == base_reg[i]
  One comparator per slave, using registered values.
  Timing impact: the comparator now drives off registers which have a clock-to-Q delay,
  but the compare itself is the same logic.

Option 2: TCAM-style ternary match
  Used in PCIe root complexes and IOMMUs.
  Each entry has a base, a mask, and a valid bit.
  Hardware is essentially a small TCAM (typically 32-256 entries).
  Results are OR'd with a priority encoder for overlapping entries.

Option 3: Page-table walker (IOMMU / SMMU)
  For DMA devices, the SMMU intercepts DMA bus addresses and translates them
  through a page table in memory. This is orders of magnitude slower than
  CAM-based decode (multiple memory accesses for a TLB miss) but provides
  full virtual address support and OS-controlled I/O protection.

Timing with programmable decode:
  The register read adds T_clk_to_Q (~100-150 ps at 7 nm) to the compare start.
  For a 1 GHz design, this is still manageable if the comparison logic itself
  is optimised (XNOR tree, fast carry chain for masked compare).
  At frequencies above ~1.5 GHz, the programmable decoder is likely pipelined:
  Stage 1 (cycle N):   Read base/mask registers, begin address comparison
  Stage 2 (cycle N+1): Complete comparison, assert slave_sel
  This adds 1 cycle of decode latency — acceptable for APB; requires back-pressure
  for AXI (the master must insert a wait state or the crossbar must buffer the address).
```

**Key interview insight:** Large AXI crossbars (e.g., Arm CoreLink NIC-400, NIC-450) implement configurable address decode via programmable region registers with the CAM approach, accepting the 1-cycle pipeline delay and absorbing it into the crossbar's buffering stages.

---

### Question A2
**Describe address aliasing as a security vulnerability. Give a concrete attack scenario and describe the hardware and software countermeasures that prevent it.**

**Answer:**

**Attack scenario — peripheral alias bypasses TrustZone:**

```
SoC configuration (intended):
  0x4000_0000 - 0x4000_0FFF : Secure UART (TrustZone-protected, NS=0 only)
  0x4000_1000 - 0x4000_1FFF : Non-Secure UART (any software can access)

Partial decode bug in APB decoder:
  // WRONG: decoder only checks bits [11:0] for UART select, not bits [31:12]
  wire secure_uart_sel   = (addr[11:8] == 4'h0) & txz_ns_bit == 0;
  wire nonsecure_uart_sel = (addr[11:8] == 4'h1);

  Aliases created for secure UART:
    0x4000_0000 -> secure_uart_sel (correct)
    0x4000_0100 -> secure_uart_sel (bits[11:8]==0 matches — alias within same page)
    ...
    But more dangerously, if the decoder is in a different bus segment:
    0x4002_0000 -> also selects secure_uart_sel if bits[11:8] happen to be 0
    (depends on exactly which bits the partial decoder checks)

Attack:
  1. Non-secure software finds the alias at 0x4002_0000 (via scanning or disclosed
     in a technical reference manual that incorrectly describes the memory map).
  2. The Non-Secure UART's NS bit grants NS=1 access to address 0x4002_0000.
  3. The partial decoder routes the NS=1 access to the Secure UART at 0x4000_0000.
  4. Non-secure software reads the Secure UART TX buffer, which may contain
     cryptographic keys, passwords, or secure debug output.
```

**Hardware countermeasures:**

1. **Full address decode:** Every bit of the address that distinguishes one slave from another is checked. Aliases are structurally impossible if the comparators are correct.

   ```verilog
   // Correct: checks all 20 distinguishing bits
   assign secure_uart_sel = (addr[31:12] == 20'h40000) & (tz_ns == 1'b0);
   ```

2. **TrustZone address space controller (TZASC / TZC-400):** A dedicated hardware block inserted on the interconnect that enforces NS/S access policy on address ranges. Even if the peripheral decoder has a bug, the TZASC rejects NS transactions to S-assigned regions before they reach the decoder.

   ```
   TZASC configuration (one-time, from Secure firmware):
     Region 0: 0x4000_0000 - 0x4000_0FFF, Secure only
     Region 1: 0x4000_1000 - 0x4000_1FFF, Non-Secure allowed
   
   Any NS access to 0x4000_0000 - 0x4000_0FFF is blocked and generates
   a DECERR response regardless of the downstream decoder behaviour.
   ```

3. **Formal verification of address decoder:** Run the decoder RTL through a property checker to prove mutual exclusivity (no two slaves selected simultaneously) and completeness (every valid address maps to exactly one slave or the default slave).

   ```
   SVA properties for decoder verification:
   // One-hot: at most one slave selected at any time
   property p_onehot;
     @(posedge clk) $onehot0(slave_sel);
   endproperty
   assert property (p_onehot);

   // No alias: if slave[i] is selected, addr must be in slave[i]'s legal range
   // (stated per slave; checked exhaustively by formal tool)
   ```

**Software countermeasures:**

1. **MPU / MMU mapping:** Mark the alias region (if it cannot be eliminated) as inaccessible in the OS page tables. Attempts to access it generate a permission fault before reaching the bus.

2. **Fuzz testing of address space:** Run a non-privileged process that systematically reads every aligned 4 KB page in the NS address space and checks for unexpected responses (data that should not be readable, or unexpected DECERR patterns that reveal decoder structure).

3. **Static analysis of memory map definition:** Tooling that checks for overlapping regions in the SystemRDL or IP-XACT source of the address map, flagging potential aliases at design time rather than during security review.
