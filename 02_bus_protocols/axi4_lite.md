# AXI4-Lite Protocol

## Overview

AXI4-Lite is a simplified subset of the full AXI4 protocol, defined in the ARM AMBA 4.0
specification. It retains the five-channel structure and VALID/READY handshake mechanism of
AXI4 but removes bursts, transaction IDs, exclusive access, and unaligned transfers. This
makes AXI4-Lite the standard interface for register-mapped control and status register (CSR)
blocks throughout the AMBA ecosystem.

Understanding when to use AXI4-Lite versus full AXI4, and how to implement a correct slave
register bank, are common interview topics at companies designing SoC IP blocks, DMA engines,
and accelerators.

```
AXI4-Lite vs AXI4 Full:

  AXI4 Full:  bursts, IDs, exclusive, unaligned, QoS, out-of-order
  AXI4-Lite:  single-beat only, no IDs, no exclusive, word-aligned, optional QoS

  Both retain: 5-channel structure, VALID/READY handshake, AXPROT, AXCACHE
```

---

## Fundamentals

### Q1. What signals are present in AXI4-Lite? What is omitted compared to full AXI4?

**Question:** List the AXI4-Lite signals for each channel and explain which AXI4 full signals
are absent and why.

**Answer:**

**AXI4-Lite channel signals:**

| Channel | Signal | Width | Direction (master=M, slave=S) |
|---------|--------|-------|-------------------------------|
| AW | AWVALID | 1 | M->S |
| AW | AWREADY | 1 | S->M |
| AW | AWADDR | Addr width | M->S |
| AW | AWPROT | 3 | M->S |
| W | WVALID | 1 | M->S |
| W | WREADY | 1 | S->M |
| W | WDATA | 32 or 64 | M->S |
| W | WSTRB | 4 or 8 | M->S |
| B | BVALID | 1 | S->M |
| B | BREADY | 1 | M->S |
| B | BRESP | 2 | S->M |
| AR | ARVALID | 1 | M->S |
| AR | ARREADY | 1 | S->M |
| AR | ARADDR | Addr width | M->S |
| AR | ARPROT | 3 | M->S |
| R | RVALID | 1 | S->M |
| R | RREADY | 1 | M->S |
| R | RDATA | 32 or 64 | S->M |
| R | RRESP | 2 | S->M |

**Signals removed from AXI4 full:**

| Removed Signal | Reason |
|----------------|--------|
| AXID (AWID, ARID, BID, RID) | No outstanding transactions; no out-of-order completion needed |
| AXLEN, AXSIZE, AXBURST | No burst support; all transfers are single-beat |
| AXLOCK | No exclusive access |
| AXCACHE | Not required (often tied to 4'b0010 fixed) |
| AXQOS | Not required (often tied to 4'h0) |
| AXREGION | Not required |
| WLAST | Always 1 (only one beat) -- can be omitted or tied high |

**Data width restriction:** AXI4-Lite only supports 32-bit or 64-bit data paths. Full AXI4
supports up to 1024 bits. This restriction suits register access patterns which rarely exceed
64 bits per register.

---

### Q2. How does an AXI4-Lite write transaction work? What are the timing requirements?

**Question:** Describe the AXI4-Lite write transaction flow. Can AW and W phases occur
simultaneously? Does the slave need to accept them in a specific order?

**Answer:**

**Write transaction phases:**

An AXI4-Lite write uses three channels: AW (address), W (data), and B (response).

```
Clk:      _|--|_|--|_|--|_|--|_|--|_
AWVALID:  ____|---------|___________
AWREADY:  _________|---|___________    (slave accepts address)
WVALID:   ____|---------|___________
WREADY:   _________|---|___________    (slave accepts data)
BVALID:   _____________|---|_______    (slave returns response)
BREADY:   _______________________    (master accepts, assume always 1)

              ^ AW and W both accepted at cycle 3
```

**Key rules for AXI4-Lite writes:**

1. **AW and W may be presented simultaneously.** The master does not need to wait for AW to be
   accepted before asserting WVALID. Both channels are independent.

2. **Slave may accept AW and W in any order.** The slave may accept the address first, or the
   data first, or both simultaneously. A well-designed slave accepts both on the same cycle if
   both VALID signals are asserted.

3. **BVALID must only be asserted after both AW and W have been accepted.** The slave has
   received neither complete address nor data until both handshakes complete. Returning BRESP
   before accepting both is a protocol violation.

4. **BREADY may be pre-asserted.** The master may assert BREADY before BVALID appears,
   enabling zero-stall response acceptance.

**Minimum latency write (3 cycles):**

```
Cycle 1: AWVALID=1, WVALID=1, AWREADY=1, WREADY=1  -> AW and W accepted simultaneously
Cycle 2: BVALID=1, BREADY=1                          -> B accepted
(Transaction complete in 2 cycles after assertion)
```

---

### Q3. How does an AXI4-Lite read transaction work?

**Question:** Describe the AXI4-Lite read transaction timing. Can a master have multiple
outstanding reads on an AXI4-Lite interface?

**Answer:**

**Read transaction flow (AR then R channels):**

```
Clk:      _|--|_|--|_|--|_|--|_
ARVALID:  ____|-------|________
ARREADY:  _______|----|________  (slave accepts address)
RVALID:   ____________|----|__  (slave returns data)
RREADY:   ________________________ (master always ready, tied high)
RDATA:    ____________[DDDDD]__
RRESP:    ____________[RESP]___
```

**Key rules for AXI4-Lite reads:**

1. The master asserts ARVALID with the read address. The slave accepts when ARREADY is high.
2. After accepting the address, the slave fetches the register value and asserts RVALID.
3. The master accepts the data when RREADY is asserted (may be pre-asserted for zero-wait reads).
4. RRESP carries the response: OKAY (2'b00) for success, SLVERR (2'b10) for error (e.g.,
   read of a write-only register).

**Outstanding reads on AXI4-Lite:**

The AXI4-Lite specification does not mandate a single-outstanding constraint in the protocol
itself (no rule prevents issuing AR before the previous R data is accepted). However:

- Since there are no transaction IDs, responses must be returned in order.
- The slave must not reorder read responses.
- Most AXI4-Lite slaves are implemented as single-outstanding (new AR not accepted until
  R is delivered), because the slave has no mechanism to track which response matches which
  request without IDs.

**Practical implication:** AXI4-Lite masters that need high throughput (e.g., a register dump
routine) should pipeline: assert the next ARVALID as soon as the current ARREADY is seen,
without waiting for RVALID. The slave must be designed to queue the second address.

---

### Q4. When should you choose AXI4-Lite over full AXI4?

**Question:** List the criteria that should drive the choice between AXI4-Lite and full AXI4
for a new IP block's configuration interface.

**Answer:**

**Choose AXI4-Lite when:**

1. **Access pattern is register-mapped, word-at-a-time.** The interface is used for CSR
   (Control and Status Register) access: reading status, writing control words, clearing
   interrupts. No burst transfers are needed.

2. **Bandwidth is low.** A UART configuration interface accessed once every millisecond needs
   at most tens of bytes per second. AXI4 burst machinery is wasteful overhead.

3. **Area budget is tight.** An AXI4-Lite slave consumes approximately 200-500 gates for
   the protocol logic alone (plus register logic). A full AXI4 slave with burst support,
   outstanding transaction tracking, and ID matching requires 2,000-5,000 gates.

4. **Implementation simplicity is preferred.** AXI4-Lite has a well-understood, minimal state
   machine. Many EDA vendors (Xilinx, Intel, Synopsys) provide template generators for
   AXI4-Lite register banks that require only a few hours to customise.

5. **The IP will be connected through a standard AMBA interconnect.** Full AXI4 masters
   (CPU, DMA) can issue single-beat, unaliased transactions that are fully AXI4-Lite compatible.
   No protocol bridge is needed between a full AXI4 master and an AXI4-Lite slave.

**Choose full AXI4 when:**

1. **Burst memory access is required.** Cache line fills/evictions, DMA transfers, video frame
   buffers -- all benefit from burst efficiency.

2. **High bandwidth is needed.** A GPU memory controller, PCIe endpoint, or network DMA engine
   cannot afford the per-transaction overhead of AXI4-Lite.

3. **Outstanding transactions are needed.** Hiding latency to DRAM or external memory requires
   multiple in-flight transactions to maintain throughput.

4. **Exclusive access (atomic operations) is required.** Mutexes, spinlocks, and semaphores
   in a shared-memory system require the EXOKAY exclusive access mechanism.

**Summary rule of thumb:**

```
CSR access / configuration / status registers -> AXI4-Lite
Data movement / memory / DMA / video / network -> Full AXI4
```

---

### Q5. What is WSTRB in AXI4-Lite and how should a slave use it?

**Question:** Explain WSTRB and describe how a 32-bit AXI4-Lite slave should implement byte
enable support for a 32-bit register.

**Answer:**

WSTRB (Write Strobe) is a byte-enable signal with one bit per byte of WDATA. For a 32-bit
data bus, WSTRB is 4 bits wide. A bit value of 1 means the corresponding byte is valid and
should be written; a bit value of 0 means the corresponding byte should be preserved.

| WSTRB bit | Controls |
|-----------|----------|
| WSTRB[0] | WDATA[7:0] |
| WSTRB[1] | WDATA[15:8] |
| WSTRB[2] | WDATA[23:16] |
| WSTRB[3] | WDATA[31:24] |

**Example -- partial write to a 32-bit register:**

```
Current register value: 32'hAABBCCDD
WDATA:  32'h00FF0000
WSTRB:  4'b0100       (only byte 2 is valid: WDATA[23:16] = 8'hFF)

Result: register[23:16] = 8'hFF
        register[31:24] = 8'hAA  (preserved)
        register[15:8]  = 8'hBB  (preserved)
        register[7:0]   = 8'hDD  (preserved)
New value: 32'hAAFFCCDD
```

**Slave implementation for byte-enable writes:**

```systemverilog
// Apply byte enables per register
always_ff @(posedge aclk or negedge aresetn) begin
    if (!aresetn) begin
        reg_ctrl <= 32'h0;
    end else if (write_en && (waddr == CTRL_OFFSET)) begin
        // Apply byte enables individually
        if (wstrb[0]) reg_ctrl[ 7: 0] <= wdata[ 7: 0];
        if (wstrb[1]) reg_ctrl[15: 8] <= wdata[15: 8];
        if (wstrb[2]) reg_ctrl[23:16] <= wdata[23:16];
        if (wstrb[3]) reg_ctrl[31:24] <= wdata[31:24];
    end
end
```

**When WSTRB is all-ones (4'b1111):** Normal full-word write -- all bytes are updated.
This is the most common case for CSR access.

**When WSTRB is all-zeros (4'b0000):** The write contains no valid data. The slave should
complete the transaction (return BRESP=OKAY) without modifying any register. This is a legal
AXI4-Lite transaction.

---

## Intermediate

### Q6. Design a minimal AXI4-Lite slave state machine. What states are required?

**Question:** Describe the state machine for an AXI4-Lite slave that handles writes and reads
with correct protocol ordering. What edge cases must the state machine handle?

**Answer:**

**Write path state machine:**

```
States: WR_IDLE -> WR_ADDR_RCVD | WR_DATA_RCVD -> WR_BOTH_RCVD -> WR_RESP

WR_IDLE:
  - Monitor AWVALID and WVALID
  - If AWVALID only:  assert AWREADY (1 cycle), capture address -> WR_ADDR_RCVD
  - If WVALID only:   assert WREADY (1 cycle), capture data    -> WR_DATA_RCVD
  - If both VALID:    assert both READY (1 cycle), capture both -> WR_BOTH_RCVD

WR_ADDR_RCVD:
  - Address captured, waiting for data
  - Assert WREADY when WVALID arrives, capture data -> WR_BOTH_RCVD

WR_DATA_RCVD:
  - Data captured, waiting for address
  - Assert AWREADY when AWVALID arrives, capture address -> WR_BOTH_RCVD

WR_BOTH_RCVD:
  - Both address and data captured
  - Perform register write (combinational or registered)
  - Assert BVALID -> WR_RESP

WR_RESP:
  - Hold BVALID, BRESP
  - When BREADY asserted -> WR_IDLE
```

**Read path state machine:**

```
States: RD_IDLE -> RD_WAIT -> RD_DATA

RD_IDLE:
  - Monitor ARVALID
  - When ARVALID: assert ARREADY (1 cycle), capture address -> RD_WAIT

RD_WAIT:
  - Perform register read (may take 1 or more cycles for registered read)
  - Assert RVALID with RDATA and RRESP -> RD_DATA

RD_DATA:
  - Hold RVALID, RDATA, RRESP
  - When RREADY asserted -> RD_IDLE
```

**Edge cases that must be handled:**

1. **AW and W arrive in the same cycle.** The slave must accept both in a single cycle
   (WR_IDLE -> WR_BOTH_RCVD directly). Not handling this reduces throughput.

2. **Master pre-asserts BREADY.** The slave must not stay in WR_RESP if BREADY is already
   high when BVALID is first asserted. This is legal and should result in a 1-cycle B phase.

3. **Pipelined reads.** If the master sends the next ARVALID before RVALID is asserted for
   the previous read, the slave must either queue the second address or deassert ARREADY to
   stall the master until the first read completes.

4. **Read of undefined address.** The slave should return RRESP=SLVERR and RDATA=32'h0 (or
   a fixed error pattern) rather than returning stale or X data.

---

### Q7. How do you implement a read-clear register and a write-1-to-clear register in an AXI4-Lite slave?

**Question:** Describe the implementation of read-clear and write-1-to-clear semantics, which
are common patterns in interrupt status registers.

**Answer:**

These register behaviours are critical in interrupt status registers (ISR) and error status
registers where software reads or writes to acknowledge and clear individual event bits.

**Read-Clear (RC):**
The register bits are cleared automatically when the register is read. Software reads the ISR
to discover which interrupts are pending; the act of reading clears those bits.

```systemverilog
// Read-clear interrupt status register
logic [31:0] isr_reg;   // interrupt status
logic [31:0] isr_set;   // set by hardware events (pulse or level)

always_ff @(posedge aclk or negedge aresetn) begin
    if (!aresetn) begin
        isr_reg <= 32'h0;
    end else begin
        // Hardware sets bits (interrupt sources)
        isr_reg <= isr_reg | isr_set;
        // Software read-clears the entire register
        if (axi_read_en && (araddr == ISR_OFFSET)) begin
            isr_reg <= isr_set;  // capture new events from THIS cycle only
            // (don't clear bits set in same cycle as read)
        end
    end
end

// Read data: present current value before clearing
assign rdata_isr = isr_reg;
```

**Write-1-to-Clear (W1C):**
Software writes a 1 to each bit position it wants to clear. Writing a 0 has no effect.
This is safer than read-clear for multi-core systems: two cores can each clear their own
bits without a race (no read-modify-write needed).

```systemverilog
// Write-1-to-clear interrupt status register
always_ff @(posedge aclk or negedge aresetn) begin
    if (!aresetn) begin
        isr_reg <= 32'h0;
    end else begin
        // Hardware sets bits
        isr_reg <= (isr_reg | isr_set);
        // Software write: bits set in WDATA (with WSTRB applied) are cleared
        if (axi_write_en && (awaddr == ISR_OFFSET)) begin
            isr_reg <= (isr_reg | isr_set) & ~(wdata & {{8{wstrb[3]}},
                                                         {8{wstrb[2]}},
                                                         {8{wstrb[1]}},
                                                         {8{wstrb[0]}}});
        end
    end
end
```

**Other common register types:**

| Type | Abbreviation | Behaviour |
|------|-------------|-----------|
| Read-Write | RW | Standard; software reads and writes freely |
| Read-Only | RO | Software reads only; writes ignored |
| Write-Only | WO | Software writes only; reads return 0 or SLVERR |
| Read-Set | RS | Reading a bit sets it to 1 |
| Write-1-to-Set | W1S | Writing 1 sets the bit; writing 0 has no effect |
| Clear-on-Write | COW | Writing any value clears the register |

---

### Q8. How do you handle an AXI4-Lite bridge from a full AXI4 master? What conversions are needed?

**Question:** A full AXI4 master needs to access an AXI4-Lite slave. What does the bridge need
to do? Can the bridge be zero-logic in some cases?

**Answer:**

**Compatibility:** AXI4-Lite is a strict subset of AXI4. A full AXI4 master issuing single-beat,
word-aligned transactions with AXLEN=0 and AXBURST=INCR is already issuing AXI4-Lite-compatible
transactions. In this case, the "bridge" is simply:

- Tie AWID/ARID inputs (from master) to a constant on the slave side (AXI4-Lite has no ID signals)
- Tie WLAST=1 (always last beat since only single-beat transfers occur)
- The BVALID/RVALID timing can connect directly

**Cases where active logic is needed:**

1. **Burst transactions from master.** The bridge must split an N-beat burst into N individual
   AXI4-Lite transactions, issuing them sequentially (one per AXI4-Lite write or read cycle)
   and buffering responses. This adds latency proportional to burst length.

   ```
   AXI4 master: AWLEN=3 (4 beats) to register address 0x100
   Bridge issues:
     AXI4-Lite write to 0x100 (beat 0)
     AXI4-Lite write to 0x104 (beat 1)
     AXI4-Lite write to 0x108 (beat 2)
     AXI4-Lite write to 0x10C (beat 3)
   Returns single BRESP to AXI4 master (aggregating responses)
   ```

2. **Unaligned transfers.** AXI4-Lite only supports aligned accesses. An unaligned AXI4
   transaction must either be rejected (SLVERR) or decomposed into two aligned transactions.

3. **ID stripping.** The bridge must strip AWID/ARID from the master and return the correct
   BID/RID by tracking pending transactions.

4. **Outstanding transaction serialization.** AXI4-Lite cannot have multiple outstanding
   transactions (no IDs to distinguish them). The bridge must serialize: only one AXI4-Lite
   transaction may be in flight at a time, queuing any additional requests from the AXI4 master.

**Common implementation pattern:**
ARM Cortex-A series CPUs include a built-in AXI-to-APB bridge in their peripheral port logic.
Xilinx and Intel provide AXI4-to-AXI4-Lite bridge IP in their standard IP catalogues,
implementing exactly the burst-splitting and serialization described above.

---

## Advanced

### Q9. How would you verify an AXI4-Lite slave using SystemVerilog assertions?

**Question:** Write SVA assertions covering the three most critical AXI4-Lite protocol rules for
a slave implementation. Explain what each assertion checks.

**Answer:**

```systemverilog
// Bind to the AXI4-Lite slave interface

// -------------------------------------------------------------------------
// Assertion 1: AWVALID stability
// Once AWVALID is asserted, it must remain high until AWREADY is seen.
// Rule: A source cannot withdraw a transaction (handshake rule 2).
// -------------------------------------------------------------------------
property awvalid_stable_until_ready;
    @(posedge aclk) disable iff (!aresetn)
    (awvalid && !awready) |=> awvalid;
endproperty
assert property (awvalid_stable_until_ready)
    else $error("[AXI4-L] AWVALID deasserted before AWREADY -- protocol violation");

// -------------------------------------------------------------------------
// Assertion 2: BVALID only after both AW and W are accepted
// The slave must not return a write response until it has received both
// the write address (AW handshake) and write data (W handshake).
// This is checked by verifying BVALID implies aw_received && w_received.
// -------------------------------------------------------------------------
logic aw_accepted, w_accepted, both_accepted;
assign aw_accepted   = awvalid && awready;
assign w_accepted    = wvalid  && wready;

// Track state: have both been received for current transaction?
logic aw_done, w_done;
always_ff @(posedge aclk or negedge aresetn) begin
    if (!aresetn) begin
        aw_done <= 1'b0;
        w_done  <= 1'b0;
    end else begin
        if (bvalid && bready) begin
            // Transaction complete, reset for next
            aw_done <= aw_accepted;  // may start new transaction same cycle
            w_done  <= w_accepted;
        end else begin
            if (aw_accepted) aw_done <= 1'b1;
            if (w_accepted)  w_done  <= 1'b1;
        end
    end
end

property bvalid_requires_both_channels;
    @(posedge aclk) disable iff (!aresetn)
    bvalid |-> (aw_done && w_done);
endproperty
assert property (bvalid_requires_both_channels)
    else $error("[AXI4-L] BVALID asserted before both AW and W were accepted");

// -------------------------------------------------------------------------
// Assertion 3: RVALID only after AR accepted
// The slave must not assert RVALID before the read address is accepted.
// -------------------------------------------------------------------------
logic ar_accepted_r;
always_ff @(posedge aclk or negedge aresetn) begin
    if (!aresetn)
        ar_accepted_r <= 1'b0;
    else if (arvalid && arready)
        ar_accepted_r <= 1'b1;
    else if (rvalid && rready)
        ar_accepted_r <= 1'b0;   // transaction complete
end

property rvalid_requires_ar_accepted;
    @(posedge aclk) disable iff (!aresetn)
    rvalid |-> (ar_accepted_r || (arvalid && arready));
endproperty
assert property (rvalid_requires_ar_accepted)
    else $error("[AXI4-L] RVALID asserted without prior AR acceptance");

// -------------------------------------------------------------------------
// Coverage: ensure both write and read paths are exercised
// -------------------------------------------------------------------------
covergroup axi4_lite_coverage @(posedge aclk);
    cp_write_transaction: coverpoint (awvalid && awready && wvalid && wready);
    cp_read_transaction:  coverpoint (arvalid && arready);
    cp_slverr_write:      coverpoint (bvalid  && bready  && bresp == 2'b10);
    cp_slverr_read:       coverpoint (rvalid  && rready  && rresp == 2'b10);
endgroup
```

**What these assertions catch:**
- Assertion 1 catches slaves that deassert AWREADY prematurely or masters that
  deassert AWVALID before handshake (either side violating rule 2).
- Assertion 2 catches the common implementation bug of returning BRESP before the
  W channel data has been fully received.
- Assertion 3 catches slaves that pipeline RDATA assembly incorrectly and return
  read data ahead of the AR acceptance.

---

### Q10. How would you implement an AXI4-Lite to APB adapter? What are the key considerations?

**Question:** Describe the state machine for an AXI4-Lite to APB bridge. What signals require
level adaptation and what is the minimum latency in clock cycles?

**Answer:**

An AXI4-Lite to APB bridge converts the VALID/READY handshake world into APB's SETUP/ACCESS
two-phase model.

**Signal mapping:**

| AXI4-Lite | APB | Notes |
|-----------|-----|-------|
| AWADDR | PADDR | Latched when AW accepted |
| AWPROT[1] | PPROT (if supported) | Security bit mapping |
| WDATA | PWDATA | Latched when W accepted |
| WSTRB | PSTRB | Byte enables (APB3 and later) |
| ARADDR | PADDR | Latched when AR accepted |
| WVALID+AWVALID | PSEL | Assert when both address and data ready |
| (after PSEL) | PENABLE | Assert 1 cycle after PSEL |
| PREADY | BVALID/RVALID | Assert when PREADY deasserts PENABLE |
| PRDATA | RDATA | Capture when ACCESS phase completes |
| PSLVERR | BRESP/RRESP | Map PSLVERR to SLVERR (2'b10) |

**Bridge state machine:**

```
IDLE:
  Monitor AWVALID+WVALID (write) or ARVALID (read).
  When write: latch AWADDR, WDATA, WSTRB, assert AWREADY, WREADY.
              Set PWRITE=1, PADDR, PWDATA, PSTRB.
              -> APB_SETUP
  When read:  latch ARADDR, assert ARREADY.
              Set PWRITE=0, PADDR.
              -> APB_SETUP

APB_SETUP:
  Assert PSEL.
  PENABLE=0.                    (1 cycle)
  -> APB_ENABLE

APB_ENABLE:
  Assert PENABLE.
  Monitor PREADY.
  While !PREADY: stay here (APB wait states).
  When PREADY:
    If write: capture PSLVERR. Assert BVALID, BRESP. -> RESP
    If read:  capture PRDATA, PSLVERR. Assert RVALID, RDATA, RRESP. -> RESP

RESP:
  Deassert PSEL, PENABLE.
  Hold BVALID or RVALID.
  When BREADY or RREADY: -> IDLE
```

**Minimum latency (zero wait states, PREADY always asserted):**

```
Cycle 1: AXI4-Lite AW and W accepted (IDLE -> APB_SETUP)
Cycle 2: PSEL=1, PENABLE=0 (APB_SETUP -> APB_ENABLE)
Cycle 3: PSEL=1, PENABLE=1, PREADY=1 (APB_ENABLE, accept PREADY)
Cycle 4: BVALID=1, BREADY=1 (RESP -> IDLE)

Total: 4 cycles from AXI transaction start to write response
       5 cycles for a read (add 1 cycle for RDATA propagation to master)
```

**Additional considerations:**
- If PCLK (APB clock) is derived from ACLK (AXI clock) at a lower frequency, the PREADY
  signal must be synchronised to ACLK before the bridge state machine can use it.
- The bridge should not accept the next AXI4-Lite transaction (AWREADY/ARREADY deasserted)
  until the current APB transaction completes and BVALID/RVALID is accepted. This ensures
  the single-outstanding constraint.

---

## Summary Reference Table

| Feature | AXI4-Lite | AXI4 Full |
|---------|-----------|-----------|
| Burst length | Always 1 | 1-256 beats |
| Data width | 32 or 64 bit | 32 to 1024 bit |
| Transaction IDs | Not used | AWID, ARID, BID, RID |
| Out-of-order completion | Not supported | Supported (per ID) |
| Exclusive access | Not supported | ARLOCK/AWLOCK |
| Unaligned transfers | Not supported | Supported |
| QoS (AXQOS) | Not required | Optional |
| Memory type (AXCACHE) | Not required | Optional |
| WLAST signal | Not required (always 1) | Required |
| Typical use | CSR / register file | Memory / DMA / streaming |
| Slave complexity | ~200-500 gates | ~2,000-5,000 gates |
| Common masters | CPU config port | CPU data port, GPU, DMA |
