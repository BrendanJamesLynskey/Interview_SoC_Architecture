// =============================================================================
// Challenge 03: DMA Descriptor Engine
// =============================================================================
//
// PROBLEM STATEMENT
// -----------------
// Implement a scatter-gather DMA descriptor engine with a descriptor ring.
// The engine fetches descriptors from a memory-resident ring, executes the
// transfers they describe, and manages completion interrupts.
//
// Specification:
//   Descriptor ring    : 8 entries (wraps; indices 0–7)
//   Descriptor format  : 5 x 32-bit words (20 bytes, padded to 32-byte entry)
//     Word 0  [31]     OWN  — 1=hardware-owned, 0=software-owned
//             [30]     IRQ  — assert interrupt when this descriptor completes
//             [29]     EOL  — this is the last descriptor (stop after completion)
//             [15:0]   BYTE_COUNT — bytes to transfer (max 65535)
//     Word 1  [31:0]   SRC_ADDR  — source byte address (AXI master read)
//     Word 2  [31:0]   DST_ADDR  — destination byte address (AXI master write)
//     Word 3  [31:0]   NEXT_ADDR — physical address of next descriptor (ignored if EOL=1)
//     Word 4  [31:0]   STATUS    — written by hardware on completion
//             [31]     DONE      — set by HW when descriptor is complete
//             [30]     ERR       — set by HW on AXI error
//             [7:0]    ERR_CODE  — error code (0=none, 1=SLVERR, 2=DECERR, 3=timeout)
//
// AXI Master Interface (simplified):
//   axi_araddr / axi_arvalid / axi_arready — read address channel
//   axi_rdata  / axi_rvalid  / axi_rready  — read data channel
//   axi_awaddr / axi_awvalid / axi_awready — write address channel
//   axi_wdata  / axi_wvalid  / axi_wready  — write data channel (32-bit words)
//   axi_bvalid / axi_bready  / axi_bresp   — write response channel
//
// Control/Status Registers (MMIO, simplified):
//   ctrl_start      : start the engine (load head from reg_head_addr)
//   ctrl_stop       : stop after current descriptor
//   reg_head_addr   : physical address of the first descriptor in the ring
//   reg_irq_status  : bit per source: [0]=desc_done, [1]=desc_err, [2]=ring_empty
//   reg_irq_clear   : write 1 to clear the corresponding irq_status bit
//   irq_out         : interrupt output to the CPU
//
// State Machine:
//   IDLE            — waiting for ctrl_start
//   FETCH_DESC      — issue AXI read for descriptor words 0–3 (4 reads)
//   DECODE_DESC     — validate OWN, check EOL, extract fields
//   TRANSFER        — issue AXI reads (SRC) and writes (DST) for BYTE_COUNT bytes
//   UPDATE_DESC     — write STATUS word back to memory; clear OWN bit
//   ADVANCE         — move to next descriptor or stop if EOL
//   STOPPED         — engine halted; assert ring_empty IRQ if applicable
//
// Deliverables:
//   1. dma_descriptor_engine module — complete implementation.
//   2. tb_dma_descriptor_engine — testbench stub with a memory model and ring.
//
// Key scenarios to test:
//   Test 1: Two-descriptor chain with IRQ on the second (EOL) descriptor.
//   Test 2: Descriptor with ERR response (AXI SLVERR on write channel).
//   Test 3: Ring-empty detection (OWN=0 on first fetch).
//
// =============================================================================

// -----------------------------------------------------------------------------
// AXI4-Lite read/write helper package (shared typedefs)
// -----------------------------------------------------------------------------

package dma_pkg;
    // Descriptor word field positions
    localparam int DESC_OWN_BIT   = 31;
    localparam int DESC_IRQ_BIT   = 30;
    localparam int DESC_EOL_BIT   = 29;
    localparam int DESC_CNT_HIGH  = 15;
    localparam int DESC_CNT_LOW   = 0;

    // STATUS word field positions
    localparam int STAT_DONE_BIT  = 31;
    localparam int STAT_ERR_BIT   = 30;
    localparam int STAT_CODE_HIGH = 7;
    localparam int STAT_CODE_LOW  = 0;

    // IRQ status bits
    localparam int IRQ_DONE_BIT   = 0;
    localparam int IRQ_ERR_BIT    = 1;
    localparam int IRQ_EMPTY_BIT  = 2;
endpackage


// -----------------------------------------------------------------------------
// DMA Descriptor Engine
// -----------------------------------------------------------------------------

module dma_descriptor_engine
    import dma_pkg::*;
(
    input  logic        clk,
    input  logic        rst_n,

    // Control / Status registers (MMIO simplified to direct ports)
    input  logic        ctrl_start,       // pulse to start
    input  logic        ctrl_stop,        // pulse to request stop after current desc
    input  logic [31:0] reg_head_addr,    // physical address of first descriptor

    output logic [2:0]  reg_irq_status,   // [0]=done [1]=err [2]=empty
    input  logic [2:0]  reg_irq_clear,    // write-1-to-clear
    output logic        irq_out,          // interrupt to CPU

    // AXI4-Lite master interface (32-bit data, 32-bit address)
    // Read address channel
    output logic [31:0] axi_araddr,
    output logic        axi_arvalid,
    input  logic        axi_arready,

    // Read data channel
    input  logic [31:0] axi_rdata,
    input  logic        axi_rvalid,
    output logic        axi_rready,

    // Write address channel
    output logic [31:0] axi_awaddr,
    output logic        axi_awvalid,
    input  logic        axi_awready,

    // Write data channel
    output logic [31:0] axi_wdata,
    output logic [3:0]  axi_wstrb,
    output logic        axi_wvalid,
    input  logic        axi_wready,

    // Write response channel
    input  logic [1:0]  axi_bresp,
    input  logic        axi_bvalid,
    output logic        axi_bready
);

    // -------------------------------------------------------------------------
    // FSM state encoding
    // -------------------------------------------------------------------------
    typedef enum logic [2:0] {
        IDLE        = 3'd0,
        FETCH_DESC  = 3'd1,
        DECODE_DESC = 3'd2,
        TRANSFER    = 3'd3,
        UPDATE_DESC = 3'd4,
        ADVANCE     = 3'd5,
        STOPPED     = 3'd6
    } state_t;

    state_t state;

    // -------------------------------------------------------------------------
    // Descriptor fields (latched after fetch)
    // -------------------------------------------------------------------------
    logic        desc_own;
    logic        desc_irq;
    logic        desc_eol;
    logic [15:0] desc_count;
    logic [31:0] desc_src;
    logic [31:0] desc_dst;
    logic [31:0] desc_next;
    logic [31:0] desc_base_addr;  // address of the descriptor being processed

    // -------------------------------------------------------------------------
    // Transfer progress counters
    // -------------------------------------------------------------------------
    logic [15:0] bytes_remaining;
    logic [31:0] src_ptr;
    logic [31:0] dst_ptr;

    // -------------------------------------------------------------------------
    // Descriptor fetch sub-state (reads 4 words: words 0–3)
    // -------------------------------------------------------------------------
    logic [1:0]  fetch_word_idx;   // which word we are currently fetching
    logic [31:0] fetch_buf [0:3];  // latched descriptor words

    // -------------------------------------------------------------------------
    // Update sub-state (writes word 4 = STATUS, then word 0 = clears OWN)
    // -------------------------------------------------------------------------
    logic [1:0]  update_phase;     // 0=write STATUS, 1=clear OWN
    logic        axi_err;          // sticky AXI error flag for this transfer

    // -------------------------------------------------------------------------
    // Stop request latch
    // -------------------------------------------------------------------------
    logic stop_req;

    // -------------------------------------------------------------------------
    // IRQ status register
    // -------------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            reg_irq_status <= 3'b000;
        end else begin
            // Clear bits on software write
            reg_irq_status <= reg_irq_status & ~reg_irq_clear;

            // Set bits from hardware events (handled in main FSM below)
        end
    end

    assign irq_out = |reg_irq_status;

    // -------------------------------------------------------------------------
    // AXI default tie-offs (overridden inside FSM)
    // -------------------------------------------------------------------------
    // These are overridden cycle-by-cycle inside the FSM always_ff block.
    // Declared as logic; driven combinationally from registered "pending" flags
    // or directly in the sequential block below.

    // -------------------------------------------------------------------------
    // Main FSM
    // -------------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state            <= IDLE;
            stop_req         <= 1'b0;
            desc_base_addr   <= 32'b0;
            fetch_word_idx   <= 2'd0;
            update_phase     <= 2'd0;
            bytes_remaining  <= 16'd0;
            src_ptr          <= 32'b0;
            dst_ptr          <= 32'b0;
            axi_err          <= 1'b0;
            axi_arvalid      <= 1'b0;
            axi_araddr       <= 32'b0;
            axi_rready       <= 1'b0;
            axi_awvalid      <= 1'b0;
            axi_awaddr       <= 32'b0;
            axi_wvalid       <= 1'b0;
            axi_wdata        <= 32'b0;
            axi_wstrb        <= 4'hF;
            axi_bready       <= 1'b0;
        end else begin

            // Latch stop request; cleared when engine actually stops
            if (ctrl_stop) stop_req <= 1'b1;

            unique case (state)

                // --------------------------------------------------------------
                // IDLE: wait for ctrl_start
                // --------------------------------------------------------------
                IDLE: begin
                    axi_arvalid <= 1'b0;
                    axi_awvalid <= 1'b0;
                    axi_wvalid  <= 1'b0;
                    if (ctrl_start) begin
                        desc_base_addr  <= reg_head_addr;
                        fetch_word_idx  <= 2'd0;
                        stop_req        <= 1'b0;
                        state           <= FETCH_DESC;
                    end
                end

                // --------------------------------------------------------------
                // FETCH_DESC: read descriptor words 0–3 sequentially
                //   Word 0: CTRL  (own, irq, eol, byte_count)
                //   Word 1: SRC_ADDR
                //   Word 2: DST_ADDR
                //   Word 3: NEXT_ADDR
                // Each word requires one AXI read transaction.
                // --------------------------------------------------------------
                FETCH_DESC: begin
                    // Issue read address if not already accepted
                    if (!axi_arvalid) begin
                        axi_araddr  <= desc_base_addr + (32'(fetch_word_idx) << 2);
                        axi_arvalid <= 1'b1;
                        axi_rready  <= 1'b0;
                    end

                    // Address accepted by slave
                    if (axi_arvalid && axi_arready) begin
                        axi_arvalid <= 1'b0;
                        axi_rready  <= 1'b1;  // ready to accept read data
                    end

                    // Data arrives on read data channel
                    if (axi_rready && axi_rvalid) begin
                        axi_rready             <= 1'b0;
                        fetch_buf[fetch_word_idx] <= axi_rdata;

                        if (fetch_word_idx == 2'd3) begin
                            // All four words fetched; proceed to decode
                            state <= DECODE_DESC;
                        end else begin
                            fetch_word_idx <= fetch_word_idx + 1'b1;
                            // Stay in FETCH_DESC for the next word
                        end
                    end
                end

                // --------------------------------------------------------------
                // DECODE_DESC: extract fields and decide whether to run or stop
                // --------------------------------------------------------------
                DECODE_DESC: begin
                    desc_own   <= fetch_buf[0][DESC_OWN_BIT];
                    desc_irq   <= fetch_buf[0][DESC_IRQ_BIT];
                    desc_eol   <= fetch_buf[0][DESC_EOL_BIT];
                    desc_count <= fetch_buf[0][DESC_CNT_HIGH:DESC_CNT_LOW];
                    desc_src   <= fetch_buf[1];
                    desc_dst   <= fetch_buf[2];
                    desc_next  <= fetch_buf[3];
                    axi_err    <= 1'b0;

                    if (!fetch_buf[0][DESC_OWN_BIT]) begin
                        // OWN=0: software has not yet armed this descriptor
                        // Ring is empty from our perspective — stop and flag
                        reg_irq_status[IRQ_EMPTY_BIT] <= 1'b1;
                        state <= STOPPED;
                    end else begin
                        // Armed descriptor: set up transfer pointers
                        src_ptr         <= fetch_buf[1];
                        dst_ptr         <= fetch_buf[2];
                        bytes_remaining <= fetch_buf[0][DESC_CNT_HIGH:DESC_CNT_LOW];
                        state           <= TRANSFER;
                    end
                end

                // --------------------------------------------------------------
                // TRANSFER: copy bytes_remaining bytes from src_ptr to dst_ptr
                // Uses 32-bit word transactions for simplicity.
                // Full-width WSTRB; partial bytes at end handled by narrowing WSTRB.
                // For brevity: this model transfers one 32-bit word per AXI
                // read-then-write cycle. A production engine pipelines R and W.
                // --------------------------------------------------------------
                TRANSFER: begin
                    // Sub-FSM: READ phase
                    if (!axi_arvalid && !axi_rvalid && bytes_remaining > 0) begin
                        axi_araddr  <= src_ptr;
                        axi_arvalid <= 1'b1;
                        axi_rready  <= 1'b0;
                    end

                    if (axi_arvalid && axi_arready) begin
                        axi_arvalid <= 1'b0;
                        axi_rready  <= 1'b1;
                    end

                    if (axi_rready && axi_rvalid) begin
                        axi_rready  <= 1'b0;
                        // Latch read data and issue write
                        axi_awaddr  <= dst_ptr;
                        axi_awvalid <= 1'b1;
                        axi_wdata   <= axi_rdata;
                        // WSTRB: all bytes unless last partial word
                        axi_wstrb   <= (bytes_remaining >= 4) ? 4'hF :
                                       (bytes_remaining == 3) ? 4'h7 :
                                       (bytes_remaining == 2) ? 4'h3 : 4'h1;
                        axi_wvalid  <= 1'b1;
                        axi_bready  <= 1'b0;
                    end

                    if (axi_awvalid && axi_awready) axi_awvalid <= 1'b0;
                    if (axi_wvalid  && axi_wready)  axi_wvalid  <= 1'b0;

                    // Write response signals transfer completion
                    if (axi_bvalid && !axi_bready) begin
                        axi_bready <= 1'b1;
                    end

                    if (axi_bvalid && axi_bready) begin
                        axi_bready <= 1'b0;

                        // Check for AXI error response
                        if (axi_bresp != 2'b00) axi_err <= 1'b1;

                        // Advance pointers
                        if (bytes_remaining >= 4) begin
                            src_ptr         <= src_ptr + 4;
                            dst_ptr         <= dst_ptr + 4;
                            bytes_remaining <= bytes_remaining - 16'd4;
                        end else begin
                            bytes_remaining <= 16'd0;
                        end
                    end

                    // Transfer complete when all bytes moved
                    if (bytes_remaining == 16'd0 && !axi_awvalid && !axi_wvalid) begin
                        update_phase <= 2'd0;
                        state        <= UPDATE_DESC;
                    end
                end

                // --------------------------------------------------------------
                // UPDATE_DESC: write STATUS back to descriptor memory
                //   Phase 0: write STATUS word (word 4) — DONE, ERR, ERR_CODE
                //   Phase 1: clear OWN bit in word 0 (write-back)
                // --------------------------------------------------------------
                UPDATE_DESC: begin
                    if (update_phase == 2'd0) begin
                        // Write STATUS word (at offset 16 = 4*4 bytes)
                        if (!axi_awvalid) begin
                            axi_awaddr  <= desc_base_addr + 32'd16;
                            axi_awvalid <= 1'b1;
                            axi_wdata   <= {axi_err ? 2'b10 : 2'b10, 22'b0,
                                           axi_err ? 8'd1 : 8'd0};
                            // [31]=DONE=1, [30]=ERR, [7:0]=ERR_CODE
                            axi_wdata[STAT_DONE_BIT] <= 1'b1;
                            axi_wdata[STAT_ERR_BIT]  <= axi_err;
                            axi_wstrb  <= 4'hF;
                            axi_wvalid <= 1'b1;
                            axi_bready <= 1'b0;
                        end
                        if (axi_awvalid && axi_awready) axi_awvalid <= 1'b0;
                        if (axi_wvalid  && axi_wready)  axi_wvalid  <= 1'b0;
                        if (axi_bvalid && !axi_bready)  axi_bready  <= 1'b1;
                        if (axi_bvalid && axi_bready) begin
                            axi_bready    <= 1'b0;
                            update_phase  <= 2'd1;
                        end
                    end else begin
                        // Phase 1: clear OWN in word 0 (write word 0 with OWN=0)
                        if (!axi_awvalid) begin
                            axi_awaddr  <= desc_base_addr;
                            axi_awvalid <= 1'b1;
                            // Keep IRQ, EOL, BYTE_COUNT; clear OWN
                            axi_wdata   <= {1'b0, desc_irq, desc_eol, 13'b0, desc_count};
                            axi_wstrb   <= 4'hF;
                            axi_wvalid  <= 1'b1;
                            axi_bready  <= 1'b0;
                        end
                        if (axi_awvalid && axi_awready) axi_awvalid <= 1'b0;
                        if (axi_wvalid  && axi_wready)  axi_wvalid  <= 1'b0;
                        if (axi_bvalid && !axi_bready)  axi_bready  <= 1'b1;
                        if (axi_bvalid && axi_bready) begin
                            axi_bready <= 1'b0;
                            // Raise IRQ if desc_irq or error
                            if (desc_irq || axi_err) begin
                                reg_irq_status[IRQ_DONE_BIT] <= desc_irq;
                                reg_irq_status[IRQ_ERR_BIT]  <= axi_err;
                            end
                            state <= ADVANCE;
                        end
                    end
                end

                // --------------------------------------------------------------
                // ADVANCE: move to the next descriptor or stop
                // --------------------------------------------------------------
                ADVANCE: begin
                    if (desc_eol || stop_req) begin
                        // Last descriptor or stop was requested
                        stop_req <= 1'b0;
                        state    <= STOPPED;
                    end else begin
                        // Fetch the next descriptor
                        desc_base_addr <= desc_next;
                        fetch_word_idx <= 2'd0;
                        state          <= FETCH_DESC;
                    end
                end

                // --------------------------------------------------------------
                // STOPPED: engine idle, waiting for ctrl_start
                // --------------------------------------------------------------
                STOPPED: begin
                    axi_arvalid <= 1'b0;
                    axi_awvalid <= 1'b0;
                    axi_wvalid  <= 1'b0;
                    if (ctrl_start) begin
                        desc_base_addr  <= reg_head_addr;
                        fetch_word_idx  <= 2'd0;
                        stop_req        <= 1'b0;
                        state           <= FETCH_DESC;
                    end
                end

                default: state <= IDLE;

            endcase
        end
    end

endmodule


// =============================================================================
// Testbench — tb_dma_descriptor_engine
// =============================================================================
// Provides:
//   - A memory model (4 KB, word-addressed) acting as both descriptor memory
//     and data source/destination.
//   - AXI4-Lite slave with 2-cycle read/write latency.
//   - Three test scenarios as described in the problem statement.
// =============================================================================

module tb_dma_descriptor_engine
    import dma_pkg::*;
();

    // -------------------------------------------------------------------------
    // DUT signals
    // -------------------------------------------------------------------------
    logic        clk, rst_n;
    logic        ctrl_start, ctrl_stop;
    logic [31:0] reg_head_addr;
    logic [2:0]  reg_irq_status;
    logic [2:0]  reg_irq_clear;
    logic        irq_out;

    logic [31:0] axi_araddr;
    logic        axi_arvalid, axi_arready;
    logic [31:0] axi_rdata;
    logic        axi_rvalid, axi_rready;
    logic [31:0] axi_awaddr;
    logic        axi_awvalid, axi_awready;
    logic [31:0] axi_wdata;
    logic [3:0]  axi_wstrb;
    logic        axi_wvalid, axi_wready;
    logic [1:0]  axi_bresp;
    logic        axi_bvalid, axi_bready;

    // -------------------------------------------------------------------------
    // DUT instantiation
    // -------------------------------------------------------------------------
    dma_descriptor_engine dut (
        .clk           (clk),
        .rst_n         (rst_n),
        .ctrl_start    (ctrl_start),
        .ctrl_stop     (ctrl_stop),
        .reg_head_addr (reg_head_addr),
        .reg_irq_status(reg_irq_status),
        .reg_irq_clear (reg_irq_clear),
        .irq_out       (irq_out),
        .axi_araddr    (axi_araddr),
        .axi_arvalid   (axi_arvalid),
        .axi_arready   (axi_arready),
        .axi_rdata     (axi_rdata),
        .axi_rvalid    (axi_rvalid),
        .axi_rready    (axi_rready),
        .axi_awaddr    (axi_awaddr),
        .axi_awvalid   (axi_awvalid),
        .axi_awready   (axi_awready),
        .axi_wdata     (axi_wdata),
        .axi_wstrb     (axi_wstrb),
        .axi_wvalid    (axi_wvalid),
        .axi_wready    (axi_wready),
        .axi_bresp     (axi_bresp),
        .axi_bvalid    (axi_bvalid),
        .axi_bready    (axi_bready)
    );

    // -------------------------------------------------------------------------
    // Clock: 10 ns period
    // -------------------------------------------------------------------------
    initial clk = 0;
    always #5 clk = ~clk;

    // -------------------------------------------------------------------------
    // Memory model: 4 KB word-addressed (1024 x 32-bit words)
    // Byte address [31:2] selects the word; [1:0] ignored (word-aligned only).
    // -------------------------------------------------------------------------
    logic [31:0] mem [0:1023];

    // Initialise memory
    initial begin
        for (int i = 0; i < 1024; i++) mem[i] = 32'(i);
        // Source data region: 0x200–0x2FF (words 128–191)
        for (int i = 128; i < 192; i++) mem[i] = 32'hA0 | 32'(i - 128);
    end

    // AXI slave (memory model) — responds with 2-cycle latency
    // Simple model: accepts one transaction at a time; not fully pipelined.
    logic [1:0] rd_lat, wr_lat;
    logic [31:0] rd_addr_lat, wr_addr_lat, wr_data_lat;
    logic [3:0]  wr_strb_lat;
    logic        inject_slverr;   // set by test to inject an error response

    // Read channel
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            axi_arready <= 1'b0;
            axi_rvalid  <= 1'b0;
            axi_rdata   <= 32'b0;
            rd_lat      <= 2'd0;
        end else begin
            axi_arready <= 1'b0;
            axi_rvalid  <= 1'b0;

            if (axi_arvalid && !axi_arready && rd_lat == 2'd0) begin
                axi_arready <= 1'b1;
                rd_addr_lat <= axi_araddr;
                rd_lat      <= 2'd1;
            end else if (rd_lat == 2'd1) begin
                rd_lat <= 2'd2;
            end else if (rd_lat == 2'd2) begin
                axi_rdata  <= mem[rd_addr_lat[11:2]];  // word-addressed
                axi_rvalid <= 1'b1;
                rd_lat     <= 2'd0;
            end
        end
    end

    // Write channel
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            axi_awready <= 1'b0;
            axi_wready  <= 1'b0;
            axi_bvalid  <= 1'b0;
            axi_bresp   <= 2'b00;
            wr_lat      <= 2'd0;
        end else begin
            axi_awready <= 1'b0;
            axi_wready  <= 1'b0;
            axi_bvalid  <= 1'b0;

            if (axi_awvalid && !axi_awready && wr_lat == 2'd0) begin
                axi_awready  <= 1'b1;
                wr_addr_lat  <= axi_awaddr;
                wr_lat       <= 2'd1;
            end else if (wr_lat == 2'd1 && axi_wvalid) begin
                axi_wready  <= 1'b1;
                wr_data_lat <= axi_wdata;
                wr_strb_lat <= axi_wstrb;
                wr_lat      <= 2'd2;
            end else if (wr_lat == 2'd2) begin
                // Apply byte-strobe write to memory
                if (!inject_slverr) begin
                    for (int b = 0; b < 4; b++) begin
                        if (wr_strb_lat[b])
                            mem[wr_addr_lat[11:2]][b*8 +: 8] <= wr_data_lat[b*8 +: 8];
                    end
                    axi_bresp <= 2'b00;  // OKAY
                end else begin
                    axi_bresp <= 2'b10;  // SLVERR
                end
                axi_bvalid <= 1'b1;
                wr_lat     <= 2'd0;
            end
        end
    end

    // -------------------------------------------------------------------------
    // Helper task: write a descriptor into the memory model
    //   desc_addr : byte address of descriptor word 0
    //   own, irq, eol, byte_count, src, dst, next
    // -------------------------------------------------------------------------
    task automatic write_descriptor(
        input logic [31:0] desc_addr,
        input logic        own, irq, eol,
        input logic [15:0] byte_count,
        input logic [31:0] src, dst, next_desc
    );
        logic [9:0] base_word;
        base_word = desc_addr[11:2];
        mem[base_word + 0] = {own, irq, eol, 13'b0, byte_count};
        mem[base_word + 1] = src;
        mem[base_word + 2] = dst;
        mem[base_word + 3] = next_desc;
        mem[base_word + 4] = 32'b0;  // STATUS cleared
    endtask

    // -------------------------------------------------------------------------
    // Helper: wait for IRQ with timeout
    // -------------------------------------------------------------------------
    task automatic wait_for_irq(input int timeout_cycles);
        int i;
        for (i = 0; i < timeout_cycles; i++) begin
            @(posedge clk);
            if (irq_out) break;
        end
        if (i == timeout_cycles)
            $display("  TIMEOUT: IRQ not received within %0d cycles", timeout_cycles);
    endtask

    // -------------------------------------------------------------------------
    // Test sequence
    // -------------------------------------------------------------------------
    initial begin
        $display("=== DMA Descriptor Engine Test ===");

        // Initialise control signals
        ctrl_start    = 1'b0;
        ctrl_stop     = 1'b0;
        reg_head_addr = 32'b0;
        reg_irq_clear = 3'b0;
        inject_slverr = 1'b0;

        // Reset
        rst_n = 1'b0;
        repeat(4) @(posedge clk);
        rst_n = 1'b1;
        repeat(2) @(posedge clk);

        // -----------------------------------------------------------------------
        // Test 1: Two-descriptor chain
        //   Descriptor 0 (at byte addr 0x000): copy 8 bytes from 0x200 to 0x300
        //                                      IRQ=0, EOL=0, NEXT=0x020
        //   Descriptor 1 (at byte addr 0x020): copy 4 bytes from 0x240 to 0x340
        //                                      IRQ=1, EOL=1 (last descriptor)
        //
        //   Expected: single IRQ after descriptor 1 completes.
        // -----------------------------------------------------------------------
        $display("\n[T1] Two-descriptor chain (8 bytes + 4 bytes)");

        // Source data: mem[0x200>>2..] = mem[128..] already set to 0xA0+i
        write_descriptor(
            .desc_addr  (32'h000),
            .own        (1'b1),
            .irq        (1'b0),
            .eol        (1'b0),
            .byte_count (16'd8),
            .src        (32'h200),
            .dst        (32'h300),
            .next_desc  (32'h020)
        );
        write_descriptor(
            .desc_addr  (32'h020),
            .own        (1'b1),
            .irq        (1'b1),   // IRQ on completion
            .eol        (1'b1),   // last descriptor
            .byte_count (16'd4),
            .src        (32'h240),
            .dst        (32'h340),
            .next_desc  (32'hDEAD)
        );

        // Start engine
        @(posedge clk);
        reg_head_addr = 32'h000;
        ctrl_start    = 1'b1;
        @(posedge clk);
        ctrl_start    = 1'b0;

        // Wait for IRQ
        wait_for_irq(2000);

        if (irq_out) begin
            $display("  PASS: IRQ received after two-descriptor chain");
            // Verify destination data was written
            if (mem[32'h300 >> 2] == mem[32'h200 >> 2])
                $display("  PASS: destination word 0 matches source");
            else
                $display("  FAIL: destination word 0 mismatch (src=0x%08h, dst=0x%08h)",
                         mem[32'h200 >> 2], mem[32'h300 >> 2]);
        end else begin
            $display("  FAIL: IRQ not received");
        end

        // Clear IRQ
        @(posedge clk);
        reg_irq_clear = 3'b011;
        @(posedge clk);
        reg_irq_clear = 3'b000;

        // -----------------------------------------------------------------------
        // Test 2: AXI SLVERR error injection
        //   Descriptor 0 (at byte addr 0x040): copy 4 bytes, but the write will
        //   receive a SLVERR response. Expect IRQ_ERR to be set.
        // -----------------------------------------------------------------------
        $display("\n[T2] AXI SLVERR error injection");
        write_descriptor(
            .desc_addr  (32'h040),
            .own        (1'b1),
            .irq        (1'b1),
            .eol        (1'b1),
            .byte_count (16'd4),
            .src        (32'h200),
            .dst        (32'h400),
            .next_desc  (32'h0)
        );

        inject_slverr = 1'b1;  // inject error on all writes

        @(posedge clk);
        reg_head_addr = 32'h040;
        ctrl_start    = 1'b1;
        @(posedge clk);
        ctrl_start = 1'b0;

        wait_for_irq(2000);

        if (reg_irq_status[IRQ_ERR_BIT]) begin
            $display("  PASS: ERR IRQ received for SLVERR descriptor");
        end else begin
            $display("  FAIL: ERR IRQ not set (irq_status=0x%01h)", reg_irq_status);
        end

        inject_slverr = 1'b0;

        @(posedge clk);
        reg_irq_clear = 3'b111;
        @(posedge clk);
        reg_irq_clear = 3'b000;

        // -----------------------------------------------------------------------
        // Test 3: Ring-empty detection (OWN=0 on first fetch)
        //   Descriptor at 0x060 has OWN=0 → engine should stop and assert
        //   IRQ_EMPTY bit immediately.
        // -----------------------------------------------------------------------
        $display("\n[T3] Ring-empty detection (OWN=0)");
        write_descriptor(
            .desc_addr  (32'h060),
            .own        (1'b0),  // NOT armed — ring empty
            .irq        (1'b0),
            .eol        (1'b0),
            .byte_count (16'd4),
            .src        (32'h200),
            .dst        (32'h500),
            .next_desc  (32'h0)
        );

        @(posedge clk);
        reg_head_addr = 32'h060;
        ctrl_start    = 1'b1;
        @(posedge clk);
        ctrl_start = 1'b0;

        wait_for_irq(500);

        if (reg_irq_status[IRQ_EMPTY_BIT]) begin
            $display("  PASS: ring-empty IRQ received");
        end else begin
            $display("  FAIL: ring-empty IRQ not set (irq_status=0x%01h)", reg_irq_status);
        end

        // -----------------------------------------------------------------------
        // Summary
        // -----------------------------------------------------------------------
        repeat(4) @(posedge clk);
        $display("\n=== DMA Descriptor Engine test complete ===");
        $finish;
    end

    // Watchdog
    initial begin
        #500000;
        $display("TIMEOUT: simulation exceeded limit");
        $finish;
    end

endmodule
