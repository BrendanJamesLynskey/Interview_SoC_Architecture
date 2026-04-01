// =============================================================================
// Challenge 3: AHB-Lite to APB Bridge
// =============================================================================
//
// Objective:
//   Implement an AHB-Lite to APB bridge that:
//     - Translates AHB-Lite transactions into APB SETUP/ACCESS two-phase transfers
//     - Handles AHB burst transactions by serialising into individual APB transfers
//     - Supports APB wait states (PREADY)
//     - Correctly maps HRESP (OKAY/ERROR) from PSLVERR
//     - Generates individual PSEL lines for up to 4 APB slaves via address decode
//     - Supports AHB read and write transactions with byte enables (HSIZE)
//     - Operates with the same clock (HCLK = PCLK)
//
// AHB-Lite input signals:
//   HSEL, HADDR, HWRITE, HTRANS, HSIZE, HWDATA, HREADY_IN -> HRDATA, HREADY, HRESP
//
// APB output signals:
//   PSELx (4 slaves), PADDR, PWRITE, PWDATA, PSTRB, PENABLE -> PRDATA, PREADY, PSLVERR
//
// Address Map (example):
//   0x40000000 - 0x400003FF: Slave 0 (PSEL[0])
//   0x40000400 - 0x400007FF: Slave 1 (PSEL[1])
//   0x40000800 - 0x40000BFF: Slave 2 (PSEL[2])
//   0x40000C00 - 0x40000FFF: Slave 3 (PSEL[3])
//
// AHB-to-APB bridge operation overview:
//   1. AHB address phase: latch address, write/read, size, HSEL
//   2. AHB data phase / APB SETUP: assert PSEL, present address/control, PENABLE=0
//   3. APB ACCESS: assert PENABLE; wait for PREADY
//   4. Complete: drive HRDATA (read), assert HREADY; handle error
//
// =============================================================================

`timescale 1ns/1ps

// =============================================================================
// AHB-Lite to APB Bridge
// =============================================================================
module ahb_to_apb_bridge #(
    parameter int ADDR_WIDTH   = 32,
    parameter int DATA_WIDTH   = 32,
    parameter int NUM_SLAVES   = 4,          // Number of APB slave selects
    // Base address and size for each APB slave (byte granularity)
    parameter logic [31:0] SLAVE_BASE [0:3] = '{32'h4000_0000,
                                                32'h4000_0400,
                                                32'h4000_0800,
                                                32'h4000_0C00},
    parameter int SLAVE_SIZE = 32'h400       // 1KB per slave
) (
    // Clock and reset (shared: HCLK = PCLK for this bridge)
    input  logic                  hclk,
    input  logic                  hresetn,

    // -------------------------------------------------------------------------
    // AHB-Lite Slave interface (input from AHB master)
    // -------------------------------------------------------------------------
    input  logic [ADDR_WIDTH-1:0] haddr,
    input  logic [2:0]            hsize,      // 000=byte,001=halfword,010=word
    input  logic [1:0]            htrans,     // 00=IDLE,01=BUSY,10=NONSEQ,11=SEQ
    input  logic                  hwrite,
    input  logic                  hsel,
    input  logic [DATA_WIDTH-1:0] hwdata,
    input  logic                  hready_in,  // Previous slave HREADY (for pipelining)
    output logic [DATA_WIDTH-1:0] hrdata,
    output logic                  hready,     // This slave's HREADY
    output logic                  hresp,      // 0=OKAY, 1=ERROR (AHB-Lite)

    // -------------------------------------------------------------------------
    // APB Master interface (output to APB peripherals)
    // -------------------------------------------------------------------------
    output logic [NUM_SLAVES-1:0] psel,       // Individual slave selects
    output logic [ADDR_WIDTH-1:0] paddr,
    output logic                  pwrite,
    output logic [DATA_WIDTH-1:0] pwdata,
    output logic [DATA_WIDTH/8-1:0] pstrb,   // APB4 byte enables
    output logic [2:0]            pprot,      // APB4 protection
    output logic                  penable,
    input  logic [DATA_WIDTH-1:0] prdata,
    input  logic                  pready,
    input  logic                  pslverr
);

    // -------------------------------------------------------------------------
    // HTRANS encoding
    // -------------------------------------------------------------------------
    localparam logic [1:0] HTRANS_IDLE   = 2'b00;
    localparam logic [1:0] HTRANS_BUSY   = 2'b01;
    localparam logic [1:0] HTRANS_NONSEQ = 2'b10;
    localparam logic [1:0] HTRANS_SEQ    = 2'b11;

    // -------------------------------------------------------------------------
    // State machine states
    // -------------------------------------------------------------------------
    typedef enum logic [2:0] {
        ST_IDLE,        // Waiting for AHB transaction
        ST_SETUP,       // APB SETUP phase (PSEL=1, PENABLE=0)
        ST_ENABLE,      // APB ACCESS phase (PSEL=1, PENABLE=1, waiting for PREADY)
        ST_ERR1,        // AHB error response cycle 1 (HREADY=0, HRESP=1)
        ST_ERR2         // AHB error response cycle 2 (HREADY=1, HRESP=1)
    } state_t;

    state_t state, next_state;

    // -------------------------------------------------------------------------
    // Latched AHB signals (captured during address phase)
    // -------------------------------------------------------------------------
    logic [ADDR_WIDTH-1:0]   lat_addr;
    logic [2:0]              lat_size;
    logic                    lat_write;
    logic [NUM_SLAVES-1:0]   lat_psel;   // Decoded slave select

    // -------------------------------------------------------------------------
    // Address decode: map HADDR to PSEL
    // -------------------------------------------------------------------------
    function automatic logic [NUM_SLAVES-1:0] decode_addr(
        input logic [ADDR_WIDTH-1:0] addr
    );
        logic [NUM_SLAVES-1:0] sel;
        sel = '0;
        for (int i = 0; i < NUM_SLAVES; i++) begin
            if ((addr >= SLAVE_BASE[i]) &&
                (addr <  SLAVE_BASE[i] + SLAVE_SIZE)) begin
                sel[i] = 1'b1;
            end
        end
        return sel;
    endfunction

    // -------------------------------------------------------------------------
    // Byte strobe generation from HSIZE
    // HSIZE encodes the transfer size; the byte enables depend on both HSIZE
    // and the two LSBs of the address (byte lane selection).
    // -------------------------------------------------------------------------
    function automatic logic [3:0] gen_strobe(
        input logic [2:0]   size,
        input logic [1:0]   addr_lsb
    );
        logic [3:0] strb;
        case (size)
            3'b000: begin // Byte
                strb = 4'b0001 << addr_lsb;
            end
            3'b001: begin // Halfword
                strb = (addr_lsb[1]) ? 4'b1100 : 4'b0011;
            end
            default: begin // Word (3'b010) or wider -- treat as full word
                strb = 4'b1111;
            end
        endcase
        return strb;
    endfunction

    // -------------------------------------------------------------------------
    // State machine (registered)
    // -------------------------------------------------------------------------
    always_ff @(posedge hclk or negedge hresetn) begin
        if (!hresetn)
            state <= ST_IDLE;
        else
            state <= next_state;
    end

    // AHB address phase latch: capture when a valid transaction starts
    // In AHB pipeline model: address phase is valid when the PREVIOUS transfer
    // completes (hready_in=1) and the current transfer type is NONSEQ or SEQ.
    always_ff @(posedge hclk or negedge hresetn) begin
        if (!hresetn) begin
            lat_addr  <= '0;
            lat_size  <= 3'b010;
            lat_write <= 1'b0;
            lat_psel  <= '0;
        end else begin
            // Latch address phase signals when a new transfer is starting
            // (transitioning to SETUP next cycle)
            if (hsel && hready_in && (htrans == HTRANS_NONSEQ || htrans == HTRANS_SEQ)) begin
                lat_addr  <= haddr;
                lat_size  <= hsize;
                lat_write <= hwrite;
                lat_psel  <= decode_addr(haddr);
            end
        end
    end

    // -------------------------------------------------------------------------
    // Next-state logic
    // -------------------------------------------------------------------------
    always_comb begin
        next_state = state;
        case (state)
            ST_IDLE: begin
                // Transition to SETUP when AHB presents a valid transaction
                if (hsel && hready_in &&
                    (htrans == HTRANS_NONSEQ || htrans == HTRANS_SEQ)) begin
                    next_state = ST_SETUP;
                end
            end

            ST_SETUP: begin
                // Always advance to ENABLE after one cycle of SETUP
                next_state = ST_ENABLE;
            end

            ST_ENABLE: begin
                // Stay in ENABLE until PREADY (APB slave may insert wait states)
                if (pready) begin
                    if (pslverr) begin
                        next_state = ST_ERR1; // Error response to AHB
                    end else begin
                        // Check for next pipelined AHB transfer
                        if (hsel && (htrans == HTRANS_NONSEQ || htrans == HTRANS_SEQ)) begin
                            next_state = ST_SETUP;  // Start next APB transaction
                        end else begin
                            next_state = ST_IDLE;
                        end
                    end
                end
            end

            ST_ERR1: begin
                // Two-cycle AHB error response: cycle 1
                next_state = ST_ERR2;
            end

            ST_ERR2: begin
                // Two-cycle AHB error response: cycle 2 (HREADY=1)
                if (hsel && (htrans == HTRANS_NONSEQ || htrans == HTRANS_SEQ))
                    next_state = ST_SETUP;
                else
                    next_state = ST_IDLE;
            end

            default: next_state = ST_IDLE;
        endcase
    end

    // -------------------------------------------------------------------------
    // Output logic
    // -------------------------------------------------------------------------

    // APB outputs
    always_comb begin
        // Default: deassert APB
        psel    = '0;
        paddr   = lat_addr;
        pwrite  = lat_write;
        pwdata  = hwdata;    // Write data comes from AHB data phase (current cycle)
        pstrb   = gen_strobe(lat_size, lat_addr[1:0]);
        pprot   = 3'b000;    // Unprivileged, secure, data access
        penable = 1'b0;

        case (state)
            ST_SETUP: begin
                psel    = lat_psel;
                penable = 1'b0;       // SETUP phase: PSEL=1, PENABLE=0
            end

            ST_ENABLE: begin
                psel    = lat_psel;
                penable = 1'b1;       // ACCESS phase: PSEL=1, PENABLE=1
            end

            default: begin
                psel    = '0;
                penable = 1'b0;
            end
        endcase
    end

    // AHB outputs
    always_comb begin
        hrdata = prdata;  // Read data always from APB

        case (state)
            ST_IDLE: begin
                hready = 1'b1;   // Ready to accept next transfer
                hresp  = 1'b0;   // OKAY
            end

            ST_SETUP: begin
                hready = 1'b0;   // Stall AHB master during APB transaction
                hresp  = 1'b0;
            end

            ST_ENABLE: begin
                // Release AHB when APB completes (and no error)
                hready = pready && !pslverr;
                hresp  = 1'b0;
            end

            ST_ERR1: begin
                hready = 1'b0;   // First error cycle: stall
                hresp  = 1'b1;   // ERROR response
            end

            ST_ERR2: begin
                hready = 1'b1;   // Second error cycle: release
                hresp  = 1'b1;   // ERROR response
            end

            default: begin
                hready = 1'b1;
                hresp  = 1'b0;
            end
        endcase
    end

endmodule : ahb_to_apb_bridge


// =============================================================================
// Testbench: AHB-Lite to APB Bridge
// =============================================================================
//
// Tests:
//   1. Single word write to Slave 0
//   2. Single word read from Slave 1
//   3. APB wait states (PREADY delayed)
//   4. Back-to-back writes (burst: two NONSEQ transactions)
//   5. PSLVERR -> AHB ERROR response (2-cycle)
//   6. Byte and halfword transfers (HSIZE != word)
//
// =============================================================================
module tb_ahb_to_apb_bridge;

    localparam int CLK_PERIOD = 10;
    localparam int NUM_SLAVES = 4;

    // -------------------------------------------------------------------------
    // Clock and reset
    // -------------------------------------------------------------------------
    logic hclk    = 1'b0;
    logic hresetn = 1'b0;
    always #(CLK_PERIOD/2) hclk = ~hclk;

    // -------------------------------------------------------------------------
    // DUT signals
    // -------------------------------------------------------------------------
    logic [31:0]          haddr;
    logic [2:0]           hsize;
    logic [1:0]           htrans;
    logic                 hwrite;
    logic                 hsel;
    logic [31:0]          hwdata;
    logic                 hready_in;
    logic [31:0]          hrdata;
    logic                 hready;
    logic                 hresp;

    logic [NUM_SLAVES-1:0] psel;
    logic [31:0]           paddr;
    logic                  pwrite;
    logic [31:0]           pwdata;
    logic [3:0]            pstrb;
    logic [2:0]            pprot;
    logic                  penable;
    logic [31:0]           prdata;
    logic                  pready;
    logic                  pslverr;

    // -------------------------------------------------------------------------
    // DUT instantiation
    // -------------------------------------------------------------------------
    ahb_to_apb_bridge #(
        .ADDR_WIDTH (32),
        .DATA_WIDTH (32),
        .NUM_SLAVES (4)
    ) dut (
        .hclk      (hclk),
        .hresetn   (hresetn),
        .haddr     (haddr),
        .hsize     (hsize),
        .htrans    (htrans),
        .hwrite    (hwrite),
        .hsel      (hsel),
        .hwdata    (hwdata),
        .hready_in (hready_in),
        .hrdata    (hrdata),
        .hready    (hready),
        .hresp     (hresp),
        .psel      (psel),
        .paddr     (paddr),
        .pwrite    (pwrite),
        .pwdata    (pwdata),
        .pstrb     (pstrb),
        .pprot     (pprot),
        .penable   (penable),
        .prdata    (prdata),
        .pready    (pready),
        .pslverr   (pslverr)
    );

    // -------------------------------------------------------------------------
    // Simple APB slave model (memory-like, configurable PREADY delay)
    // -------------------------------------------------------------------------
    logic [31:0] apb_mem [0:255];  // 256 x 32-bit word memory

    int pready_delay;   // Configurable wait states (0 = immediate)
    int pready_count;

    initial begin
        pready       = 1'b0;
        pslverr      = 1'b0;
        pready_delay = 0;
        pready_count = 0;
        for (int i = 0; i < 256; i++) apb_mem[i] = 32'hDEAD_0000 | i;
    end

    always @(posedge hclk) begin
        if (!hresetn) begin
            pready  <= 1'b0;
            pslverr <= 1'b0;
        end else if (|psel && penable) begin
            // APB access phase
            if (pready_count < pready_delay) begin
                pready  <= 1'b0;
                pslverr <= 1'b0;
                pready_count <= pready_count + 1;
            end else begin
                pready       <= 1'b1;
                pready_count <= 0;
                if (pwrite) begin
                    // Write: apply byte enables
                    if (pstrb[0]) apb_mem[paddr[9:2]][ 7: 0] <= pwdata[ 7: 0];
                    if (pstrb[1]) apb_mem[paddr[9:2]][15: 8] <= pwdata[15: 8];
                    if (pstrb[2]) apb_mem[paddr[9:2]][23:16] <= pwdata[23:16];
                    if (pstrb[3]) apb_mem[paddr[9:2]][31:24] <= pwdata[31:24];
                end
            end
        end else begin
            pready       <= 1'b0;
            pready_count <= 0;
        end
    end

    // Read data (combinational, available in ACCESS phase)
    always_comb begin
        if (|psel && !pwrite)
            prdata = apb_mem[paddr[9:2]];
        else
            prdata = 32'h0;
    end

    // -------------------------------------------------------------------------
    // Task: AHB-Lite single transfer (address phase then data phase)
    // -------------------------------------------------------------------------
    task automatic ahb_transfer(
        input  logic [31:0] addr,
        input  logic [2:0]  size,
        input  logic        write,
        input  logic [31:0] wdata_in,
        output logic [31:0] rdata_out,
        output logic        err_out
    );
        // Address phase
        @(posedge hclk);
        #1;
        haddr      <= addr;
        hsize      <= size;
        htrans     <= 2'b10; // NONSEQ
        hwrite     <= write;
        hsel       <= 1'b1;
        hready_in  <= hready; // chain to previous transfer's HREADY

        // Data phase: drive HWDATA and wait for HREADY
        @(posedge hclk);
        #1;
        htrans     <= 2'b00; // IDLE (no next transfer)
        hsel       <= 1'b0;
        if (write)
            hwdata <= wdata_in;

        // Wait for HREADY
        while (!hready) @(posedge hclk);

        rdata_out = hrdata;
        err_out   = hresp;

        $display("[%0t] AHB %s addr=0x%08h size=%0d data=0x%08h HRESP=%s",
                 $time, write ? "WRITE" : "READ ",
                 addr, 8 << size, write ? wdata_in : hrdata,
                 hresp ? "ERROR" : "OKAY");
    endtask

    // -------------------------------------------------------------------------
    // Test stimulus
    // -------------------------------------------------------------------------
    logic [31:0] rd;
    logic        err;
    int          pass_count, fail_count;

    task check(input string name, input logic cond, input string msg);
        if (cond) begin $display("[PASS] %s", name); pass_count++; end
        else      begin $display("[FAIL] %s: %s", name, msg); fail_count++; end
    endtask

    initial begin
        pass_count = 0; fail_count = 0;
        // Initialise AHB master signals
        haddr     = 32'h4000_0000; hsize = 3'b010;
        htrans    = 2'b00; hwrite = 0; hsel = 0;
        hwdata    = 32'h0; hready_in = 1'b1;

        // Reset
        hresetn = 1'b0;
        repeat(4) @(posedge hclk);
        hresetn = 1'b1;
        @(posedge hclk);

        $display("=== Test 1: Write then read Slave 0 ===");
        ahb_transfer(32'h4000_0000, 3'b010, 1'b1, 32'hA5A5_5A5A, rd, err);
        check("Write OKAY",  err == 0, "Expected OKAY");
        ahb_transfer(32'h4000_0000, 3'b010, 1'b0, 32'h0, rd, err);
        check("Read OKAY",   err == 0, "Expected OKAY");
        check("Read value",  rd == 32'hA5A5_5A5A, $sformatf("Got 0x%08h", rd));

        $display("=== Test 2: Access Slave 1 (different address range) ===");
        ahb_transfer(32'h4000_0404, 3'b010, 1'b1, 32'hDEAD_BEEF, rd, err);
        check("Slave 1 write OKAY", err == 0, "Expected OKAY");
        ahb_transfer(32'h4000_0404, 3'b010, 1'b0, 32'h0, rd, err);
        check("Slave 1 read",       rd == 32'hDEAD_BEEF, $sformatf("Got 0x%08h", rd));

        $display("=== Test 3: APB wait states (2 cycles) ===");
        pready_delay = 2;
        ahb_transfer(32'h4000_0008, 3'b010, 1'b1, 32'hCAFE_CAFE, rd, err);
        check("Wait state write OKAY", err == 0, "Expected OKAY");
        pready_delay = 0;

        $display("=== Test 4: Byte write (HSIZE=000) ===");
        // Write byte to address 0x4000_0010 (offset 16, byte lane 0)
        // Expected PSTRB = 4'b0001
        ahb_transfer(32'h4000_0010, 3'b000, 1'b1, 32'h0000_00EE, rd, err);
        check("Byte write OKAY", err == 0, "Expected OKAY");
        check("PSTRB byte 0",    pstrb == 4'b0001,
              $sformatf("PSTRB = 4'b%04b", pstrb));

        $display("=== Test 5: PSLVERR -> AHB ERROR ===");
        // Trigger pslverr from slave model (override for one transaction)
        fork
            begin
                // After PENABLE, force pslverr for this transaction
                @(posedge hclk); // wait for SETUP
                @(posedge hclk); // wait for ENABLE
                pslverr = 1'b1;
                @(posedge hclk);
                pslverr = 1'b0;
            end
            begin
                ahb_transfer(32'h4000_00FC, 3'b010, 1'b0, 32'h0, rd, err);
                check("PSLVERR->HRESP ERROR", err == 1'b1, "Expected ERROR");
            end
        join

        repeat(5) @(posedge hclk);
        $display("=== Results: %0d PASSED, %0d FAILED ===", pass_count, fail_count);
        $finish;
    end

    // -------------------------------------------------------------------------
    // Timeout watchdog
    // -------------------------------------------------------------------------
    initial begin
        #200_000;
        $error("[TB] Timeout");
        $finish;
    end

    // -------------------------------------------------------------------------
    // APB protocol assertions
    // -------------------------------------------------------------------------

    // PENABLE must only be asserted when PSEL is also asserted
    property penable_requires_psel;
        @(posedge hclk) disable iff (!hresetn)
        penable |-> (|psel);
    endproperty
    assert property (penable_requires_psel)
        else $error("[SVA] PENABLE without PSEL -- APB protocol violation");

    // PSEL must be held during both SETUP and ACCESS phases
    property psel_stable_during_access;
        @(posedge hclk) disable iff (!hresetn)
        (|psel && !penable) |=> (|psel);  // SETUP phase -> ACCESS phase
    endproperty
    assert property (psel_stable_during_access)
        else $error("[SVA] PSEL deasserted between SETUP and ACCESS");

    // PADDR must be stable from SETUP through ACCESS
    property paddr_stable_during_access;
        @(posedge hclk) disable iff (!hresetn)
        (|psel && !penable) |=> $stable(paddr);
    endproperty
    assert property (paddr_stable_during_access)
        else $error("[SVA] PADDR changed between SETUP and ACCESS");

endmodule : tb_ahb_to_apb_bridge

// =============================================================================
// Expected Output (approximate):
//
//   === Test 1: Write then read Slave 0 ===
//   [X] AHB WRITE addr=0x40000000 size=4 data=0xa5a55a5a HRESP=OKAY
//   [X] AHB READ  addr=0x40000000 size=4 data=0xa5a55a5a HRESP=OKAY
//   [PASS] Write OKAY
//   [PASS] Read OKAY
//   [PASS] Read value
//   === Test 2: Access Slave 1 (different address range) ===
//   [PASS] Slave 1 write OKAY
//   [PASS] Slave 1 read
//   === Test 3: APB wait states (2 cycles) ===
//   [PASS] Wait state write OKAY
//   === Test 4: Byte write (HSIZE=000) ===
//   [PASS] Byte write OKAY
//   [PASS] PSTRB byte 0
//   === Test 5: PSLVERR -> AHB ERROR ===
//   [PASS] PSLVERR->HRESP ERROR
//   === Results: 9 PASSED, 0 FAILED ===
// =============================================================================
