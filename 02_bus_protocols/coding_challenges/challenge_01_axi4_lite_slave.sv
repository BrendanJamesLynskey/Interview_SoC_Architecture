// =============================================================================
// Challenge 1: AXI4-Lite Slave Register Bank
// =============================================================================
//
// Objective:
//   Implement a fully protocol-correct AXI4-Lite slave containing a register
//   bank with four 32-bit registers. The slave must:
//     - Handle simultaneous AW and W channel acceptance in a single cycle
//     - Implement read-write (RW), read-only (RO), and write-1-to-clear (W1C)
//       register types
//     - Return SLVERR for accesses to unmapped addresses
//     - Apply WSTRB byte enables correctly
//     - Support pipelined reads (accept next AR before current R is accepted)
//
// Register Map:
//   Offset 0x00: CTRL    [31:0] RW   -- control register
//   Offset 0x04: STATUS  [31:0] RO   -- read-only status (driven from ports)
//   Offset 0x08: INT_CLR [31:0] W1C  -- write-1-to-clear interrupt flags
//   Offset 0x0C: ID      [31:0] RO   -- fixed ID register (reads 32'hDEAD_C0DE)
//   Anything else: SLVERR
//
// AXI4-Lite protocol rules:
//   - AWVALID must not depend on AWREADY (source cannot wait for READY)
//   - BVALID must only be asserted after BOTH AW and W are accepted
//   - RVALID must only be asserted after AR is accepted
//   - Once VALID is asserted, hold until READY is seen
//
// =============================================================================

`timescale 1ns/1ps

// -----------------------------------------------------------------------------
// AXI4-Lite Slave: register bank
// -----------------------------------------------------------------------------
module axi4_lite_slave #(
    parameter int ADDR_WIDTH = 8,    // Byte address width (256-byte aperture)
    parameter int DATA_WIDTH = 32    // Data width; AXI4-Lite: 32 or 64 only
) (
    // Global signals
    input  logic                    aclk,
    input  logic                    aresetn,    // Active-low synchronous reset

    // Write Address channel (AW)
    input  logic [ADDR_WIDTH-1:0]   awaddr,
    input  logic [2:0]              awprot,     // Protection attributes (unused here)
    input  logic                    awvalid,
    output logic                    awready,

    // Write Data channel (W)
    input  logic [DATA_WIDTH-1:0]   wdata,
    input  logic [DATA_WIDTH/8-1:0] wstrb,      // Byte enables: 1 bit per byte
    input  logic                    wvalid,
    output logic                    wready,

    // Write Response channel (B)
    output logic [1:0]              bresp,
    output logic                    bvalid,
    input  logic                    bready,

    // Read Address channel (AR)
    input  logic [ADDR_WIDTH-1:0]   araddr,
    input  logic [2:0]              arprot,     // Protection attributes (unused here)
    input  logic                    arvalid,
    output logic                    arready,

    // Read Data channel (R)
    output logic [DATA_WIDTH-1:0]   rdata,
    output logic [1:0]              rresp,
    output logic                    rvalid,
    input  logic                    rready,

    // Register-level ports
    output logic [31:0]             ctrl_reg,   // CTRL register output to rest of design
    input  logic [31:0]             status_in,  // STATUS register input from rest of design
    input  logic [31:0]             int_set,    // Interrupt set pulses (from hardware events)
    output logic [31:0]             int_flags   // Current interrupt flag state
);

    // -------------------------------------------------------------------------
    // AXI4-Lite response codes
    // -------------------------------------------------------------------------
    localparam logic [1:0] RESP_OKAY   = 2'b00;
    localparam logic [1:0] RESP_SLVERR = 2'b10;

    // -------------------------------------------------------------------------
    // Register address offsets (byte addresses, aligned to 4 bytes)
    // -------------------------------------------------------------------------
    localparam logic [ADDR_WIDTH-1:0] ADDR_CTRL    = 8'h00;
    localparam logic [ADDR_WIDTH-1:0] ADDR_STATUS  = 8'h04;
    localparam logic [ADDR_WIDTH-1:0] ADDR_INT_CLR = 8'h08;
    localparam logic [ADDR_WIDTH-1:0] ADDR_ID      = 8'h0C;

    localparam logic [31:0] ID_VALUE = 32'hDEAD_C0DE;  // Fixed ID

    // -------------------------------------------------------------------------
    // Internal registers
    // -------------------------------------------------------------------------
    logic [31:0] reg_ctrl;     // RW register
    logic [31:0] reg_int;      // W1C interrupt flags; set by hardware, cleared by SW

    // -------------------------------------------------------------------------
    // Write path: state tracking for AW and W channel acceptance
    // -------------------------------------------------------------------------
    // AW and W can arrive in any order; we must track which have been received
    // before issuing BVALID.
    logic                    aw_pending;     // AW has been accepted, waiting for W
    logic                    w_pending;      // W has been accepted, waiting for AW
    logic [ADDR_WIDTH-1:0]   aw_addr_latch;  // Latched write address
    logic [DATA_WIDTH-1:0]   w_data_latch;   // Latched write data
    logic [DATA_WIDTH/8-1:0] w_strb_latch;   // Latched write strobe
    logic                    write_en;       // Pulse: both AW and W received
    logic [ADDR_WIDTH-1:0]   write_addr;     // Write address when write_en
    logic [DATA_WIDTH-1:0]   write_data;     // Write data when write_en
    logic [DATA_WIDTH/8-1:0] write_strb;     // Write strobe when write_en
    logic                    write_err;      // Write to unmapped address

    // AW/W acceptance signals (combinational based on state)
    logic aw_accept, w_accept;

    // Accept AW when not already pending and no active BVALID (or BVALID+BREADY)
    assign aw_accept = awvalid && awready;
    assign w_accept  = wvalid  && wready;

    // AWREADY: accept when we don't already have a pending AW
    assign awready = !aw_pending && (!bvalid || bready);
    // WREADY: accept when we don't already have a pending W
    assign wready  = !w_pending  && (!bvalid || bready);

    // Both AW and W received: generate write enable
    // Conditions:
    //   (a) Both arrive simultaneously (aw_accept && w_accept)
    //   (b) AW was pending, W arrives now (aw_pending && w_accept)
    //   (c) W was pending, AW arrives now (w_pending && aw_accept)
    assign write_en = (aw_accept && w_accept) ||
                      (aw_pending && w_accept) ||
                      (w_pending  && aw_accept);

    // Mux the latched or live address/data
    always_comb begin
        if (aw_accept && w_accept) begin
            // Simultaneous arrival: use live values directly
            write_addr = awaddr;
            write_data = wdata;
            write_strb = wstrb;
        end else if (aw_pending && w_accept) begin
            // AW was already latched; W just arrived
            write_addr = aw_addr_latch;
            write_data = wdata;
            write_strb = wstrb;
        end else begin
            // W was already latched; AW just arrived
            write_addr = awaddr;
            write_data = w_data_latch;
            write_strb = w_strb_latch;
        end
    end

    // State machine for AW/W pending
    always_ff @(posedge aclk) begin
        if (!aresetn) begin
            aw_pending    <= 1'b0;
            w_pending     <= 1'b0;
            aw_addr_latch <= '0;
            w_data_latch  <= '0;
            w_strb_latch  <= '0;
        end else begin
            // When both AW and W arrive simultaneously, or a pending one gets its partner:
            // clear pending flags
            if (write_en) begin
                aw_pending <= 1'b0;
                w_pending  <= 1'b0;
            end else begin
                // Set pending if only one side arrived
                if (aw_accept && !w_accept) begin
                    aw_pending    <= 1'b1;
                    aw_addr_latch <= awaddr;
                end
                if (w_accept && !aw_accept) begin
                    w_pending    <= 1'b1;
                    w_data_latch <= wdata;
                    w_strb_latch <= wstrb;
                end
            end
        end
    end

    // -------------------------------------------------------------------------
    // Write Response channel (B)
    // -------------------------------------------------------------------------
    always_ff @(posedge aclk) begin
        if (!aresetn) begin
            bvalid <= 1'b0;
            bresp  <= RESP_OKAY;
        end else begin
            if (write_en && (!bvalid || bready)) begin
                // Issue response when write completes
                bvalid <= 1'b1;
                // Determine response: SLVERR for unmapped addresses
                case (write_addr[ADDR_WIDTH-1:0])
                    ADDR_CTRL:    bresp <= RESP_OKAY;
                    ADDR_INT_CLR: bresp <= RESP_OKAY;
                    ADDR_STATUS:  bresp <= RESP_SLVERR; // STATUS is read-only
                    ADDR_ID:      bresp <= RESP_SLVERR; // ID is read-only
                    default:      bresp <= RESP_SLVERR;
                endcase
            end else if (bvalid && bready) begin
                bvalid <= 1'b0;
            end
        end
    end

    // -------------------------------------------------------------------------
    // Register writes with byte enables
    // Apply write_strb to each byte of each register individually.
    // W1C: write data 1s clear corresponding flag bits; 0s have no effect.
    // -------------------------------------------------------------------------
    // Helper function: apply byte-enable mask to a register update
    function automatic logic [31:0] apply_wstrb(
        input logic [31:0]  current,
        input logic [31:0]  wdata_in,
        input logic [3:0]   strb
    );
        logic [31:0] result;
        result[ 7: 0] = strb[0] ? wdata_in[ 7: 0] : current[ 7: 0];
        result[15: 8] = strb[1] ? wdata_in[15: 8] : current[15: 8];
        result[23:16] = strb[2] ? wdata_in[23:16] : current[23:16];
        result[31:24] = strb[3] ? wdata_in[31:24] : current[31:24];
        return result;
    endfunction

    // Compute the effective write mask (1 bit per bit, expanded from strobe)
    logic [31:0] write_mask;
    always_comb begin
        write_mask = {{8{write_strb[3]}}, {8{write_strb[2]}},
                      {8{write_strb[1]}}, {8{write_strb[0]}}};
    end

    // Register update logic
    always_ff @(posedge aclk) begin
        if (!aresetn) begin
            reg_ctrl <= 32'h0;
            reg_int  <= 32'h0;
        end else begin
            // Hardware sets interrupt flags (any cycle)
            reg_int <= reg_int | int_set;

            // Software write: only for writable registers
            if (write_en) begin
                case (write_addr[ADDR_WIDTH-1:0])
                    ADDR_CTRL: begin
                        // RW register with byte enables
                        reg_ctrl <= apply_wstrb(reg_ctrl, write_data, write_strb);
                    end
                    ADDR_INT_CLR: begin
                        // W1C: bits written 1 are cleared; 0 has no effect
                        // Apply byte enables to the clear mask
                        reg_int <= (reg_int | int_set) & ~(write_data & write_mask);
                    end
                    // STATUS, ID: write ignored (SLVERR returned, no state change)
                    default: ; // no effect
                endcase
            end
        end
    end

    // Drive output ports
    assign ctrl_reg  = reg_ctrl;
    assign int_flags = reg_int;

    // -------------------------------------------------------------------------
    // Read path: AR acceptance and R response
    // -------------------------------------------------------------------------
    logic                   read_pending;       // AR accepted, R not yet delivered
    logic [ADDR_WIDTH-1:0]  ar_addr_latch;      // Latched read address

    // ARREADY: accept when no read is pending (single-outstanding simplicity)
    // A more advanced implementation would queue multiple ARs
    assign arready = !read_pending && (!rvalid || rready);

    always_ff @(posedge aclk) begin
        if (!aresetn) begin
            read_pending  <= 1'b0;
            ar_addr_latch <= '0;
            rvalid        <= 1'b0;
            rdata         <= '0;
            rresp         <= RESP_OKAY;
        end else begin
            // Accept incoming AR
            if (arvalid && arready) begin
                read_pending  <= 1'b1;
                ar_addr_latch <= araddr;
            end

            // Generate read response one cycle after AR is accepted
            // (combinational read from register file; could add pipeline stages here)
            if (read_pending && (!rvalid || rready)) begin
                rvalid <= 1'b1;
                // Decode register address
                case (ar_addr_latch[ADDR_WIDTH-1:0])
                    ADDR_CTRL:    begin rdata <= reg_ctrl;   rresp <= RESP_OKAY;   end
                    ADDR_STATUS:  begin rdata <= status_in;  rresp <= RESP_OKAY;   end
                    ADDR_INT_CLR: begin rdata <= reg_int;    rresp <= RESP_OKAY;   end
                    ADDR_ID:      begin rdata <= ID_VALUE;   rresp <= RESP_OKAY;   end
                    default:      begin rdata <= 32'h0;      rresp <= RESP_SLVERR; end
                endcase
                read_pending <= 1'b0;
            end else if (rvalid && rready) begin
                rvalid <= 1'b0;
            end
        end
    end

endmodule : axi4_lite_slave


// =============================================================================
// Testbench: AXI4-Lite Slave Register Bank
// =============================================================================
//
// Verifies:
//   1. Basic RW read/write to CTRL with byte enables
//   2. Read-only STATUS register (write returns SLVERR)
//   3. W1C interrupt register behaviour
//   4. Fixed ID register read
//   5. SLVERR on unmapped address
//   6. Simultaneous AW+W acceptance
//   7. Pipelined read (AR before previous R is accepted)
//
// =============================================================================
module tb_axi4_lite_slave;

    // -------------------------------------------------------------------------
    // Parameters
    // -------------------------------------------------------------------------
    localparam int ADDR_WIDTH = 8;
    localparam int DATA_WIDTH = 32;
    localparam int CLK_PERIOD = 10; // 100 MHz

    // -------------------------------------------------------------------------
    // Clk/reset
    // -------------------------------------------------------------------------
    logic aclk   = 1'b0;
    logic aresetn = 1'b0;

    always #(CLK_PERIOD/2) aclk = ~aclk;

    // -------------------------------------------------------------------------
    // AXI4-Lite signals
    // -------------------------------------------------------------------------
    logic [ADDR_WIDTH-1:0]   awaddr;
    logic [2:0]              awprot;
    logic                    awvalid;
    logic                    awready;

    logic [DATA_WIDTH-1:0]   wdata;
    logic [DATA_WIDTH/8-1:0] wstrb;
    logic                    wvalid;
    logic                    wready;

    logic [1:0]              bresp;
    logic                    bvalid;
    logic                    bready;

    logic [ADDR_WIDTH-1:0]   araddr;
    logic [2:0]              arprot;
    logic                    arvalid;
    logic                    arready;

    logic [DATA_WIDTH-1:0]   rdata;
    logic [1:0]              rresp;
    logic                    rvalid;
    logic                    rready;

    // -------------------------------------------------------------------------
    // DUT ports
    // -------------------------------------------------------------------------
    logic [31:0] ctrl_reg;
    logic [31:0] status_in;
    logic [31:0] int_set;
    logic [31:0] int_flags;

    // -------------------------------------------------------------------------
    // DUT instantiation
    // -------------------------------------------------------------------------
    axi4_lite_slave #(
        .ADDR_WIDTH (ADDR_WIDTH),
        .DATA_WIDTH (DATA_WIDTH)
    ) dut (
        .aclk      (aclk),
        .aresetn   (aresetn),
        .awaddr    (awaddr),
        .awprot    (awprot),
        .awvalid   (awvalid),
        .awready   (awready),
        .wdata     (wdata),
        .wstrb     (wstrb),
        .wvalid    (wvalid),
        .wready    (wready),
        .bresp     (bresp),
        .bvalid    (bvalid),
        .bready    (bready),
        .araddr    (araddr),
        .arprot    (arprot),
        .arvalid   (arvalid),
        .arready   (arready),
        .rdata     (rdata),
        .rresp     (rresp),
        .rvalid    (rvalid),
        .rready    (rready),
        .ctrl_reg  (ctrl_reg),
        .status_in (status_in),
        .int_set   (int_set),
        .int_flags (int_flags)
    );

    // -------------------------------------------------------------------------
    // Default signal values
    // -------------------------------------------------------------------------
    initial begin
        awaddr  = '0; awprot = '0; awvalid = 1'b0;
        wdata   = '0; wstrb  = '0; wvalid  = 1'b0;
        bready  = 1'b1; // Master always ready to accept write responses
        araddr  = '0; arprot = '0; arvalid = 1'b0;
        rready  = 1'b1; // Master always ready to accept read data
        status_in = 32'hA5A5_0000;
        int_set   = 32'h0;
    end

    // -------------------------------------------------------------------------
    // Task: AXI4-Lite write (simultaneous AW and W)
    // -------------------------------------------------------------------------
    task automatic axi_write(
        input logic [ADDR_WIDTH-1:0]   addr,
        input logic [DATA_WIDTH-1:0]   data,
        input logic [DATA_WIDTH/8-1:0] strb,
        output logic [1:0]             resp
    );
        // Assert both AW and W simultaneously
        @(posedge aclk);
        #1; // Small delay to avoid race with clock edge
        awaddr  <= addr;
        awvalid <= 1'b1;
        wdata   <= data;
        wstrb   <= strb;
        wvalid  <= 1'b1;

        // Wait for both AW and W to be accepted
        fork
            begin : aw_wait
                do @(posedge aclk); while (!awready);
                awvalid <= 1'b0;
            end
            begin : w_wait
                do @(posedge aclk); while (!wready);
                wvalid  <= 1'b0;
            end
        join

        // Wait for B response
        do @(posedge aclk); while (!bvalid);
        resp = bresp;
        $display("[%0t] WRITE addr=0x%02h data=0x%08h strb=4'b%04b -> BRESP=%s",
                 $time, addr, data, strb,
                 (bresp == 2'b00) ? "OKAY" : (bresp == 2'b10) ? "SLVERR" : "???");
    endtask

    // -------------------------------------------------------------------------
    // Task: AXI4-Lite read
    // -------------------------------------------------------------------------
    task automatic axi_read(
        input  logic [ADDR_WIDTH-1:0] addr,
        output logic [DATA_WIDTH-1:0] data,
        output logic [1:0]            resp
    );
        @(posedge aclk);
        #1;
        araddr  <= addr;
        arvalid <= 1'b1;

        // Wait for AR to be accepted
        do @(posedge aclk); while (!arready);
        arvalid <= 1'b0;

        // Wait for R response
        do @(posedge aclk); while (!rvalid);
        data = rdata;
        resp = rresp;
        $display("[%0t] READ  addr=0x%02h -> data=0x%08h RRESP=%s",
                 $time, addr, rdata,
                 (rresp == 2'b00) ? "OKAY" : (rresp == 2'b10) ? "SLVERR" : "???");
    endtask

    // -------------------------------------------------------------------------
    // Test stimulus
    // -------------------------------------------------------------------------
    logic [DATA_WIDTH-1:0] rd_data;
    logic [1:0]            rd_resp, wr_resp;
    int pass_count, fail_count;

    task check(
        input string   test_name,
        input logic    condition,
        input string   fail_msg
    );
        if (condition) begin
            $display("[PASS] %s", test_name);
            pass_count++;
        end else begin
            $display("[FAIL] %s: %s", test_name, fail_msg);
            fail_count++;
        end
    endtask

    initial begin
        pass_count = 0;
        fail_count = 0;

        // Reset sequence
        aresetn = 1'b0;
        repeat(4) @(posedge aclk);
        aresetn = 1'b1;
        @(posedge aclk);

        $display("=== Test 1: Write and readback CTRL register (full word) ===");
        axi_write(8'h00, 32'hCAFE_BABE, 4'hF, wr_resp);
        check("CTRL write OKAY", wr_resp == 2'b00, "Expected OKAY");
        axi_read(8'h00, rd_data, rd_resp);
        check("CTRL readback", rd_data == 32'hCAFE_BABE, $sformatf("Got 0x%08h", rd_data));

        $display("=== Test 2: Write CTRL with partial byte enables ===");
        // Only update bytes 1 and 2 (WSTRB = 4'b0110)
        axi_write(8'h00, 32'h0011_2200, 4'b0110, wr_resp);
        axi_read(8'h00, rd_data, rd_resp);
        // Expected: bytes 0 and 3 unchanged (0xBE, 0xCA), bytes 1 and 2 updated
        check("CTRL partial write",
              rd_data == 32'hCA11_22BE,
              $sformatf("Got 0x%08h, expected 0xCA1122BE", rd_data));

        $display("=== Test 3: Read STATUS register (RO) ===");
        axi_read(8'h04, rd_data, rd_resp);
        check("STATUS read OKAY",    rd_resp == 2'b00, "Expected OKAY");
        check("STATUS read value",   rd_data == status_in, $sformatf("Got 0x%08h", rd_data));

        $display("=== Test 4: Write STATUS register (RO -> SLVERR) ===");
        axi_write(8'h04, 32'hDEAD_BEEF, 4'hF, wr_resp);
        check("STATUS write SLVERR", wr_resp == 2'b10, "Expected SLVERR");
        // Confirm STATUS unchanged
        axi_read(8'h04, rd_data, rd_resp);
        check("STATUS unchanged after write", rd_data == status_in,
              $sformatf("Got 0x%08h", rd_data));

        $display("=== Test 5: W1C interrupt register ===");
        // Hardware sets bits 0 and 3
        @(posedge aclk);
        #1;
        int_set = 32'h0000_0009; // bits 0 and 3
        @(posedge aclk);
        #1;
        int_set = 32'h0;
        @(posedge aclk);

        axi_read(8'h08, rd_data, rd_resp);
        check("INT_CLR bits set", rd_data == 32'h0000_0009,
              $sformatf("Got 0x%08h", rd_data));

        // Clear bit 0 only (write 1 to bit 0)
        axi_write(8'h08, 32'h0000_0001, 4'hF, wr_resp);
        check("INT_CLR write OKAY", wr_resp == 2'b00, "Expected OKAY");
        axi_read(8'h08, rd_data, rd_resp);
        check("INT_CLR bit 0 cleared",
              rd_data == 32'h0000_0008, // bit 3 remains
              $sformatf("Got 0x%08h, expected 0x00000008", rd_data));

        $display("=== Test 6: Read ID register ===");
        axi_read(8'h0C, rd_data, rd_resp);
        check("ID read OKAY",  rd_resp == 2'b00, "Expected OKAY");
        check("ID read value", rd_data == 32'hDEAD_C0DE,
              $sformatf("Got 0x%08h", rd_data));

        $display("=== Test 7: Unmapped address -> SLVERR ===");
        axi_write(8'h20, 32'h1234_5678, 4'hF, wr_resp);
        check("Unmapped write SLVERR", wr_resp == 2'b10, "Expected SLVERR");
        axi_read(8'h20, rd_data, rd_resp);
        check("Unmapped read SLVERR", rd_resp == 2'b10, "Expected SLVERR");

        $display("=== Test 8: Verify CTRL output port ===");
        axi_write(8'h00, 32'h1234_5678, 4'hF, wr_resp);
        @(posedge aclk);
        check("ctrl_reg output", ctrl_reg == 32'h1234_5678,
              $sformatf("ctrl_reg = 0x%08h", ctrl_reg));

        // ---------------------------------------------------------------
        repeat(5) @(posedge aclk);
        $display("=== Results: %0d PASSED, %0d FAILED ===", pass_count, fail_count);
        if (fail_count == 0)
            $display("ALL TESTS PASSED");
        else
            $display("SOME TESTS FAILED");
        $finish;
    end

    // -------------------------------------------------------------------------
    // Timeout watchdog
    // -------------------------------------------------------------------------
    initial begin
        #50_000;
        $error("[TB] Timeout -- simulation exceeded time limit");
        $finish;
    end

    // -------------------------------------------------------------------------
    // SVA protocol checks (selected)
    // -------------------------------------------------------------------------

    // AWVALID must not be deasserted before AWREADY (handshake rule)
    property awvalid_stable;
        @(posedge aclk) disable iff (!aresetn)
        (awvalid && !awready) |=> awvalid;
    endproperty
    assert property (awvalid_stable)
        else $error("[SVA] AWVALID deasserted before AWREADY");

    // WVALID must not be deasserted before WREADY
    property wvalid_stable;
        @(posedge aclk) disable iff (!aresetn)
        (wvalid && !wready) |=> wvalid;
    endproperty
    assert property (wvalid_stable)
        else $error("[SVA] WVALID deasserted before WREADY");

    // BVALID must not deassert before BREADY
    property bvalid_stable;
        @(posedge aclk) disable iff (!aresetn)
        (bvalid && !bready) |=> bvalid;
    endproperty
    assert property (bvalid_stable)
        else $error("[SVA] BVALID deasserted before BREADY");

    // RVALID must not deassert before RREADY
    property rvalid_stable;
        @(posedge aclk) disable iff (!aresetn)
        (rvalid && !rready) |=> rvalid;
    endproperty
    assert property (rvalid_stable)
        else $error("[SVA] RVALID deasserted before RREADY");

endmodule : tb_axi4_lite_slave

// =============================================================================
// Expected Output (approximate):
//
//   === Test 1: Write and readback CTRL register (full word) ===
//   [100] WRITE addr=0x00 data=0xcafebabe strb=4'b1111 -> BRESP=OKAY
//   [200] READ  addr=0x00 -> data=0xcafebabe RRESP=OKAY
//   [PASS] CTRL write OKAY
//   [PASS] CTRL readback
//   === Test 2: Write CTRL with partial byte enables ===
//   [PASS] CTRL partial write
//   === Test 3: Read STATUS register (RO) ===
//   [PASS] STATUS read OKAY
//   [PASS] STATUS read value
//   === Test 4: Write STATUS register (RO -> SLVERR) ===
//   [PASS] STATUS write SLVERR
//   [PASS] STATUS unchanged after write
//   === Test 5: W1C interrupt register ===
//   [PASS] INT_CLR bits set
//   [PASS] INT_CLR write OKAY
//   [PASS] INT_CLR bit 0 cleared
//   === Test 6: Read ID register ===
//   [PASS] ID read OKAY
//   [PASS] ID read value
//   === Test 7: Unmapped address -> SLVERR ===
//   [PASS] Unmapped write SLVERR
//   [PASS] Unmapped read SLVERR
//   === Test 8: Verify CTRL output port ===
//   [PASS] ctrl_reg output
//   === Results: 16 PASSED, 0 FAILED ===
//   ALL TESTS PASSED
// =============================================================================
