// =============================================================================
// Challenge 01: Direct-Mapped Cache Controller
// =============================================================================
//
// PROBLEM STATEMENT
// -----------------
// Implement a direct-mapped, write-back, write-allocate cache controller.
//
// Specification:
//   Cache capacity  : 1 KB  (1024 bytes)
//   Cache line size : 16 bytes
//   Associativity   : 1 (direct-mapped)
//   Number of lines : 1024 / 16 = 64
//   Address width   : 16-bit byte address
//   Data bus        : 8-bit (byte-addressed CPU interface)
//   Write policy    : Write-back (dirty bit per line)
//   Allocation      : Write-allocate (write miss fetches the full line)
//
// Address decomposition (16-bit):
//   [15:10]  Tag    (6 bits)   — stored in tag RAM
//   [9:4]    Index  (6 bits)   — selects one of 64 cache lines
//   [3:0]    Offset (4 bits)   — selects byte within the 16-byte line
//
// CPU Interface:
//   cpu_req   : CPU has a pending memory request
//   cpu_we    : 1 = write, 0 = read
//   cpu_addr  : 16-bit byte address
//   cpu_wdata : 8-bit write data
//   cpu_rdata : 8-bit read data (valid when cpu_ready is asserted)
//   cpu_ready : asserted for one cycle when the request is complete
//   cpu_stall : asserted while the cache is busy (CPU must hold its request)
//
// Memory Interface (main memory / next cache level):
//   mem_req   : assert to initiate a memory transaction
//   mem_we    : 1 = write (writeback), 0 = read (line fill)
//   mem_addr  : 16-bit byte address (always line-aligned; lower 4 bits = 0)
//   mem_wdata : 128-bit line to write back
//   mem_rdata : 128-bit line returned on a read
//   mem_ready : memory asserts for one cycle when transaction is complete
//
// State Machine:
//   IDLE      — waiting for a CPU request
//   COMPARE   — tag comparison; determine hit or miss
//   WRITEBACK — evict dirty line to memory before replacing
//   ALLOCATE  — fetch new line from memory; merge write data if write-miss
//
// Deliverables:
//   1. Complete SystemVerilog implementation of the cache_controller module.
//   2. Simulation testbench (tb_cache_controller) exercising:
//        a. Read hit
//        b. Read miss (clean line replaced)
//        c. Write hit
//        d. Write miss (write-allocate: fetch + merge)
//        e. Dirty eviction (write miss on a dirty line)
//
// =============================================================================

// -----------------------------------------------------------------------------
// Cache controller implementation
// -----------------------------------------------------------------------------

module cache_controller #(
    parameter int ADDR_W     = 16,   // byte address width
    parameter int DATA_W     = 8,    // CPU data bus width (bytes)
    parameter int LINE_W     = 128,  // cache line width in bits (16 bytes)
    parameter int NUM_LINES  = 64,   // number of cache lines
    parameter int INDEX_W    = 6,    // log2(NUM_LINES)
    parameter int OFFSET_W   = 4,    // log2(LINE_W/8)
    parameter int TAG_W      = ADDR_W - INDEX_W - OFFSET_W  // 6 bits
) (
    input  logic              clk,
    input  logic              rst_n,

    // CPU interface
    input  logic              cpu_req,
    input  logic              cpu_we,
    input  logic [ADDR_W-1:0] cpu_addr,
    input  logic [DATA_W-1:0] cpu_wdata,
    output logic [DATA_W-1:0] cpu_rdata,
    output logic              cpu_ready,
    output logic              cpu_stall,

    // Memory interface
    output logic              mem_req,
    output logic              mem_we,
    output logic [ADDR_W-1:0] mem_addr,
    output logic [LINE_W-1:0] mem_wdata,
    input  logic [LINE_W-1:0] mem_rdata,
    input  logic              mem_ready
);

    // -------------------------------------------------------------------------
    // Cache storage arrays (registers — synthesise to SRAM in real design)
    // -------------------------------------------------------------------------
    logic               valid [NUM_LINES-1:0];
    logic               dirty [NUM_LINES-1:0];
    logic [TAG_W-1:0]   tag   [NUM_LINES-1:0];
    logic [LINE_W-1:0]  data  [NUM_LINES-1:0];

    // -------------------------------------------------------------------------
    // Address decomposition (registered request, held across multi-cycle ops)
    // -------------------------------------------------------------------------
    logic [TAG_W-1:0]    req_tag;
    logic [INDEX_W-1:0]  req_idx;
    logic [OFFSET_W-1:0] req_off;
    logic                req_we;
    logic [DATA_W-1:0]   req_wdata;

    // Combinational decomposition of the current CPU address
    wire [TAG_W-1:0]    addr_tag = cpu_addr[ADDR_W-1 : INDEX_W+OFFSET_W];
    wire [INDEX_W-1:0]  addr_idx = cpu_addr[INDEX_W+OFFSET_W-1 : OFFSET_W];
    wire [OFFSET_W-1:0] addr_off = cpu_addr[OFFSET_W-1 : 0];

    // -------------------------------------------------------------------------
    // Hit detection (combinational; uses the latched request)
    // -------------------------------------------------------------------------
    wire hit = valid[req_idx] && (tag[req_idx] == req_tag);

    // -------------------------------------------------------------------------
    // FSM state encoding
    // -------------------------------------------------------------------------
    typedef enum logic [1:0] {
        IDLE      = 2'b00,
        COMPARE   = 2'b01,
        WRITEBACK = 2'b10,
        ALLOCATE  = 2'b11
    } state_t;

    state_t state;

    // -------------------------------------------------------------------------
    // State register and cache array initialisation
    // -------------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= IDLE;
            for (int i = 0; i < NUM_LINES; i++) begin
                valid[i] <= 1'b0;
                dirty[i] <= 1'b0;
            end
            cpu_ready <= 1'b0;
            cpu_stall <= 1'b0;
            mem_req   <= 1'b0;
            mem_we    <= 1'b0;
        end else begin
            // Default outputs de-asserted each cycle
            cpu_ready <= 1'b0;
            mem_req   <= 1'b0;

            unique case (state)

                // ------------------------------------------------------------------
                // IDLE: sample CPU request and latch address fields
                // ------------------------------------------------------------------
                IDLE: begin
                    cpu_stall <= 1'b0;
                    if (cpu_req) begin
                        // Latch the request for use in subsequent states
                        req_tag   <= addr_tag;
                        req_idx   <= addr_idx;
                        req_off   <= addr_off;
                        req_we    <= cpu_we;
                        req_wdata <= cpu_wdata;
                        cpu_stall <= 1'b1;   // stall CPU while processing
                        state     <= COMPARE;
                    end
                end

                // ------------------------------------------------------------------
                // COMPARE: tag lookup — determine hit or miss and take action
                // ------------------------------------------------------------------
                COMPARE: begin
                    if (hit) begin
                        //
                        // Cache hit: serve the request immediately
                        //
                        if (req_we) begin
                            // Write hit: update the byte within the cached line
                            // Byte-enable: req_off selects the byte position
                            data[req_idx][req_off * DATA_W +: DATA_W] <= req_wdata;
                            dirty[req_idx] <= 1'b1;
                        end else begin
                            // Read hit: return the byte from the cached line
                            cpu_rdata <= data[req_idx][req_off * DATA_W +: DATA_W];
                        end
                        cpu_ready <= 1'b1;
                        cpu_stall <= 1'b0;
                        state     <= IDLE;

                    end else begin
                        //
                        // Cache miss: check if eviction is required
                        //
                        if (valid[req_idx] && dirty[req_idx]) begin
                            // Dirty line must be written back before replacement
                            mem_req   <= 1'b1;
                            mem_we    <= 1'b1;
                            // Reconstruct the writeback address from the stored tag + index
                            mem_addr  <= {{tag[req_idx]}, {req_idx}, {OFFSET_W{1'b0}}};
                            mem_wdata <= data[req_idx];
                            state     <= WRITEBACK;
                        end else begin
                            // Clean (or invalid) line: go directly to allocate
                            mem_req  <= 1'b1;
                            mem_we   <= 1'b0;
                            mem_addr <= {req_tag, req_idx, {OFFSET_W{1'b0}}};  // line-aligned
                            state    <= ALLOCATE;
                        end
                    end
                end

                // ------------------------------------------------------------------
                // WRITEBACK: wait for dirty-line eviction to complete
                // ------------------------------------------------------------------
                WRITEBACK: begin
                    mem_req <= 1'b1;    // hold request asserted until mem_ready
                    mem_we  <= 1'b1;
                    if (mem_ready) begin
                        // Eviction complete; now fetch the new line
                        dirty[req_idx] <= 1'b0;
                        mem_we         <= 1'b0;
                        mem_addr       <= {req_tag, req_idx, {OFFSET_W{1'b0}}};
                        state          <= ALLOCATE;
                    end
                end

                // ------------------------------------------------------------------
                // ALLOCATE: wait for new line fill to complete, install in cache
                // ------------------------------------------------------------------
                ALLOCATE: begin
                    mem_req <= 1'b1;
                    mem_we  <= 1'b0;
                    if (mem_ready) begin
                        // Install the fetched line into the cache array
                        data[req_idx]  <= mem_rdata;
                        tag[req_idx]   <= req_tag;
                        valid[req_idx] <= 1'b1;

                        if (req_we) begin
                            // Write-miss: merge the CPU write data into the new line
                            // This write happens one cycle after mem_rdata is stored;
                            // in practice a write-merge mux handles this combinationally
                            data[req_idx][req_off * DATA_W +: DATA_W] <= req_wdata;
                            dirty[req_idx] <= 1'b1;
                        end else begin
                            // Read-miss: return the requested byte
                            cpu_rdata      <= mem_rdata[req_off * DATA_W +: DATA_W];
                            dirty[req_idx] <= 1'b0;
                        end

                        cpu_ready <= 1'b1;
                        cpu_stall <= 1'b0;
                        mem_req   <= 1'b0;
                        state     <= IDLE;
                    end
                end

                default: state <= IDLE;

            endcase
        end
    end

endmodule


// =============================================================================
// Testbench stub — tb_cache_controller
// =============================================================================
// Exercises five scenarios:
//   Test 1: Read miss (cold cache) → allocate line → read hit on same address
//   Test 2: Write hit (modify a cached byte, check dirty bit set)
//   Test 3: Write miss (write-allocate: fetch line, merge byte)
//   Test 4: Dirty eviction (two addresses map to the same index; second access
//            must write back the dirty first-address line)
//   Test 5: Clean replacement (evict a clean line with no writeback)
// =============================================================================

module tb_cache_controller;

    // -------------------------------------------------------------------------
    // DUT signal declarations
    // -------------------------------------------------------------------------
    logic        clk, rst_n;
    logic        cpu_req, cpu_we;
    logic [15:0] cpu_addr;
    logic [7:0]  cpu_wdata;
    logic [7:0]  cpu_rdata;
    logic        cpu_ready, cpu_stall;
    logic        mem_req, mem_we;
    logic [15:0] mem_addr;
    logic [127:0] mem_wdata;
    logic [127:0] mem_rdata;
    logic        mem_ready;

    // -------------------------------------------------------------------------
    // DUT instantiation
    // -------------------------------------------------------------------------
    cache_controller dut (
        .clk       (clk),
        .rst_n     (rst_n),
        .cpu_req   (cpu_req),
        .cpu_we    (cpu_we),
        .cpu_addr  (cpu_addr),
        .cpu_wdata (cpu_wdata),
        .cpu_rdata (cpu_rdata),
        .cpu_ready (cpu_ready),
        .cpu_stall (cpu_stall),
        .mem_req   (mem_req),
        .mem_we    (mem_we),
        .mem_addr  (mem_addr),
        .mem_wdata (mem_wdata),
        .mem_rdata (mem_rdata),
        .mem_ready (mem_ready)
    );

    // -------------------------------------------------------------------------
    // Clock generation: 10 ns period
    // -------------------------------------------------------------------------
    initial clk = 0;
    always #5 clk = ~clk;

    // -------------------------------------------------------------------------
    // Simple memory model: returns a fixed pattern on reads; accepts writes
    // Memory latency: 3 cycles (holds mem_ready high for 1 cycle after 2-cycle delay)
    // -------------------------------------------------------------------------
    logic [127:0] mem_model [0:4095];  // 64 KB / 16 bytes = 4096 lines

    initial begin
        // Pre-fill memory with recognisable patterns
        for (int i = 0; i < 4096; i++)
            mem_model[i] = {16{8'(i & 8'hFF)}};  // each line = repeated index byte
    end

    // Memory response driver
    logic [1:0] mem_latency_cnt;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mem_ready       <= 1'b0;
            mem_rdata       <= 128'b0;
            mem_latency_cnt <= 2'd0;
        end else begin
            mem_ready <= 1'b0;

            if (mem_req && mem_latency_cnt == 2'd0) begin
                mem_latency_cnt <= 2'd1;
            end else if (mem_latency_cnt == 2'd1) begin
                mem_latency_cnt <= 2'd2;
            end else if (mem_latency_cnt == 2'd2) begin
                // Respond on the third cycle
                if (!mem_we) begin
                    // Read: return the memory model line
                    mem_rdata <= mem_model[mem_addr[15:4]];
                end else begin
                    // Write: store the written-back line
                    mem_model[mem_addr[15:4]] <= mem_wdata;
                end
                mem_ready       <= 1'b1;
                mem_latency_cnt <= 2'd0;
            end
        end
    end

    // -------------------------------------------------------------------------
    // Task: issue a CPU read and wait for completion
    // -------------------------------------------------------------------------
    task automatic cpu_read(input logic [15:0] addr, output logic [7:0] rdata);
        @(posedge clk);
        cpu_req   <= 1'b1;
        cpu_we    <= 1'b0;
        cpu_addr  <= addr;
        cpu_wdata <= 8'h00;

        // Wait until the cache completes (cpu_ready asserted)
        do @(posedge clk); while (!cpu_ready);

        rdata   = cpu_rdata;
        cpu_req <= 1'b0;
    endtask

    // -------------------------------------------------------------------------
    // Task: issue a CPU write and wait for completion
    // -------------------------------------------------------------------------
    task automatic cpu_write(input logic [15:0] addr, input logic [7:0] wdata);
        @(posedge clk);
        cpu_req   <= 1'b1;
        cpu_we    <= 1'b1;
        cpu_addr  <= addr;
        cpu_wdata <= wdata;

        do @(posedge clk); while (!cpu_ready);

        cpu_req <= 1'b0;
    endtask

    // -------------------------------------------------------------------------
    // Test sequence
    // -------------------------------------------------------------------------
    logic [7:0] rd_data;
    int         errors;

    initial begin
        errors = 0;

        // Initialise inputs
        cpu_req   = 0; cpu_we = 0; cpu_addr = 0; cpu_wdata = 0;

        // Reset
        rst_n = 0;
        repeat(4) @(posedge clk);
        rst_n = 1;
        repeat(2) @(posedge clk);

        // ------------------------------------------------------------------
        // Test 1: Cold read miss then read hit on same address
        //
        // Address 0x0010:  tag=0x00, index=1, offset=0
        // Memory model line 1 = {16{8'h01}} → each byte = 0x01
        // ------------------------------------------------------------------
        $display("[T1] Read miss: addr=0x0010");
        cpu_read(16'h0010, rd_data);
        if (rd_data !== 8'h01)
            $display("  FAIL: expected 0x01, got 0x%02h", rd_data);
        else
            $display("  PASS: rdata=0x%02h", rd_data);

        $display("[T1] Read hit: addr=0x0010 (should not access memory)");
        cpu_read(16'h0010, rd_data);
        if (rd_data !== 8'h01)
            $display("  FAIL: expected 0x01, got 0x%02h", rd_data);
        else
            $display("  PASS: cache hit, rdata=0x%02h", rd_data);

        // ------------------------------------------------------------------
        // Test 2: Write hit — write 0xAB to addr 0x0012 (same line as 0x0010)
        //         index=1, offset=2; line must already be cached from T1
        // ------------------------------------------------------------------
        $display("[T2] Write hit: addr=0x0012, data=0xAB");
        cpu_write(16'h0012, 8'hAB);
        // Read back to confirm the byte was updated
        cpu_read(16'h0012, rd_data);
        if (rd_data !== 8'hAB)
            $display("  FAIL: expected 0xAB, got 0x%02h", rd_data);
        else
            $display("  PASS: write hit confirmed, rdata=0x%02h", rd_data);

        // ------------------------------------------------------------------
        // Test 3: Write miss to a previously-unaccessed address (0x0030)
        //         index=3, offset=0
        //         Expect write-allocate: fetch line 3, merge 0xDE at offset 0
        // ------------------------------------------------------------------
        $display("[T3] Write miss (write-allocate): addr=0x0030, data=0xDE");
        cpu_write(16'h0030, 8'hDE);
        // Read back the written byte from cache (should be a hit now)
        cpu_read(16'h0030, rd_data);
        if (rd_data !== 8'hDE)
            $display("  FAIL: expected 0xDE, got 0x%02h", rd_data);
        else
            $display("  PASS: write-allocate confirmed, rdata=0x%02h", rd_data);

        // ------------------------------------------------------------------
        // Test 4: Dirty eviction
        //         addr 0x0010 (index=1) is dirty (modified in T2 with 0xAB at off=2)
        //         Access addr 0x0410: tag=0x01, index=1 → same index, different tag
        //         This must:
        //           a) Detect dirty line at index 1
        //           b) Write back the dirty line to memory (addr 0x0000 line)
        //           c) Fetch the new line (addr 0x0410)
        // ------------------------------------------------------------------
        $display("[T4] Dirty eviction: access addr=0x0410 (conflicts with dirty line at index=1)");
        cpu_read(16'h0410, rd_data);
        $display("  INFO: eviction completed, rdata=0x%02h (line 0x041 byte 0)", rd_data);
        // Verify the writeback reached the memory model
        // Dirty line had tag=0, index=1 → line address = 0x0010 → mem_model[1]
        // Byte at offset 2 should now be 0xAB in memory model
        begin
            logic [7:0] expected_wb_byte;
            expected_wb_byte = mem_model[1][2*8 +: 8];  // offset 2 of line 1
            if (expected_wb_byte !== 8'hAB)
                $display("  FAIL: writeback not seen in memory model; byte=0x%02h", expected_wb_byte);
            else
                $display("  PASS: writeback confirmed in memory model");
        end

        // ------------------------------------------------------------------
        // Test 5: Clean replacement — access addr 0x0050 (index=5, line not yet cached)
        //         then access addr 0x0450 (index=5, different tag, clean line)
        //         No writeback should occur on the second access
        // ------------------------------------------------------------------
        $display("[T5] Clean replacement: addr=0x0050 then addr=0x0450 (no writeback)");
        cpu_read(16'h0050, rd_data);
        $display("  INFO: loaded line at 0x0050, rdata=0x%02h", rd_data);
        cpu_read(16'h0450, rd_data);
        $display("  INFO: replaced clean line, rdata=0x%02h (no writeback expected)", rd_data);

        // ------------------------------------------------------------------
        // Summary
        // ------------------------------------------------------------------
        repeat(4) @(posedge clk);
        $display("=== Simulation complete ===");
        $finish;
    end

    // Timeout watchdog
    initial begin
        #100000;
        $display("TIMEOUT: simulation exceeded maximum cycles");
        $finish;
    end

endmodule
