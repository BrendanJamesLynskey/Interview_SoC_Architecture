// =============================================================================
// Challenge 02: MESI Cache Coherency State Machine
// =============================================================================
//
// PROBLEM STATEMENT
// -----------------
// Implement the MESI cache coherency state machine for a single cache controller.
// The module represents one CPU's coherency logic. It receives local CPU requests
// (read, write) and snooped bus transactions from other CPUs, and drives the
// appropriate bus transactions and state transitions.
//
// MESI States:
//   INVALID   (2'b00) — line not present; any access is a miss
//   SHARED    (2'b01) — clean, may be present in other caches
//   EXCLUSIVE (2'b10) — clean, only this cache has a copy
//   MODIFIED  (2'b11) — dirty, only this cache has a valid copy
//
// Local CPU events:
//   cpu_read    : CPU requests a read of the line
//   cpu_write   : CPU requests a write to the line
//
// Bus transactions (issued by this cache to the shared coherency bus):
//   bus_rd      : BusRd  — read request (shared or exclusive)
//   bus_rdx     : BusRdX — read-exclusive request (write miss)
//   bus_upgr    : BusUpgr — upgrade S → M (write hit on shared line; already have data)
//   bus_wb      : BusWB  — writeback dirty line to memory
//
// Snooped bus transactions (from other CPUs):
//   snoop_rd    : another CPU issued BusRd for this line
//   snoop_rdx   : another CPU issued BusRdX for this line
//   snoop_upgr  : another CPU issued BusUpgr for this line
//
// Snoop response outputs:
//   supply_data : this cache supplies the line data (intervenes on behalf of memory)
//   writeback   : this cache must write back its Modified line before responding
//   shared_out  : assert SHARED# on the bus (other caches still hold this line)
//
// Assumptions:
//   - One event per clock cycle; events are mutually exclusive per cycle.
//   - Bus grants are not modelled (focus on coherency FSM logic).
//   - This module tracks the MESI state of a SINGLE cache line.
//     A real design instantiates one such machine per cache-line slot (or implements
//     the same logic once with indexed state storage).
//   - On a cpu_read or cpu_write, the bus responds in the same cycle by setting
//     bus_rd/rdx; the transaction completes (data_valid) one cycle later.
//
// DELIVERABLES:
//   1. mesi_line_ctrl module — MESI state machine for one cache line.
//   2. mesi_cache_ctrl module — wraps mesi_line_ctrl with indexed storage for
//      a 16-entry, directly-mapped tag array to demonstrate realistic wiring.
//   3. tb_mesi — testbench stub exercising the core MESI transition sequences.
//
// KEY SCENARIOS TO VERIFY:
//   Scenario A: Cold read → I → E (no other sharer)
//   Scenario B: Cold read → I → S (another CPU has the line → shared_out asserted)
//   Scenario C: Write to S line → S → M (BusUpgr; others invalidate)
//   Scenario D: Write to I line → I → M (BusRdX)
//   Scenario E: Snoop BusRd on M line → M → S (supply data, writeback to memory)
//   Scenario F: Snoop BusRdX on S line → S → I (invalidation)
//   Scenario G: Snoop BusRdX on M line → M → I (supply data + eviction)
//
// =============================================================================

// -----------------------------------------------------------------------------
// MESI line controller — one instance per cache line (or one shared FSM with
// indexed storage; see mesi_cache_ctrl below)
// -----------------------------------------------------------------------------

module mesi_line_ctrl (
    input  logic clk,
    input  logic rst_n,

    // Local CPU events for this line
    input  logic cpu_read,       // CPU read miss: line was Invalid; issue BusRd
    input  logic cpu_write,      // CPU write: line was Invalid or Shared; issue BusRdX/BusUpgr
    input  logic data_valid,     // bus transaction complete; data is now available

    // Whether another cache acknowledged SHARED# when we issued BusRd
    input  logic other_shared,   // 1 = another cache has this line → go to S not E

    // Snooped bus transactions targeting this line
    input  logic snoop_rd,       // another CPU issued BusRd
    input  logic snoop_rdx,      // another CPU issued BusRdX or BusInv
    input  logic snoop_upgr,     // another CPU issued BusUpgr (had S, wants M)

    // Bus transaction outputs (drive onto coherency bus)
    output logic bus_rd,         // issue BusRd
    output logic bus_rdx,        // issue BusRdX
    output logic bus_upgr,       // issue BusUpgr
    output logic bus_wb,         // issue writeback

    // Snoop response outputs
    output logic supply_data,    // this cache supplies the line (cache-to-cache)
    output logic shared_out,     // assert SHARED# (this cache holds the line in S/E)

    // Current MESI state (for inspection and tag-array wiring)
    output logic [1:0] mesi_state
);

    // -------------------------------------------------------------------------
    // State encoding
    // -------------------------------------------------------------------------
    localparam logic [1:0] INVALID   = 2'b00;
    localparam logic [1:0] SHARED    = 2'b01;
    localparam logic [1:0] EXCLUSIVE = 2'b10;
    localparam logic [1:0] MODIFIED  = 2'b11;

    logic [1:0] state, next_state;

    // -------------------------------------------------------------------------
    // Combinational outputs (Mealy — depend on state AND current event)
    // -------------------------------------------------------------------------
    always_comb begin
        // Default: no bus activity, no snoop response
        bus_rd      = 1'b0;
        bus_rdx     = 1'b0;
        bus_upgr    = 1'b0;
        bus_wb      = 1'b0;
        supply_data = 1'b0;
        shared_out  = 1'b0;
        next_state  = state;

        unique case (state)

            // ------------------------------------------------------------------
            // INVALID: line not present
            // ------------------------------------------------------------------
            INVALID: begin
                if (cpu_read) begin
                    bus_rd     = 1'b1;   // request the line (shared or excl)
                    // State transition happens when data_valid arrives (see below)
                end
                if (cpu_write) begin
                    bus_rdx    = 1'b1;   // request the line with exclusive ownership
                end
                // Snoops on Invalid lines: nothing to respond to
            end

            // ------------------------------------------------------------------
            // SHARED: clean, possibly present in other caches
            // ------------------------------------------------------------------
            SHARED: begin
                // Local CPU events
                if (cpu_write) begin
                    // Write hit on a Shared line: issue BusUpgr (already have data)
                    bus_upgr   = 1'b1;
                    // Transition to Modified when BusUpgr is acknowledged
                end
                if (cpu_read) begin
                    // Read hit — no bus transaction needed; stay Shared
                    // (cpu_read on Shared is a hit; this FSM only receives it on misses
                    //  in a real design — modelling for completeness)
                end

                // Snoop events
                if (snoop_rdx || snoop_upgr) begin
                    // Another CPU wants exclusive ownership: invalidate
                    next_state  = INVALID;
                end
                if (snoop_rd) begin
                    // Another CPU reads: stay Shared; assert SHARED# so requester
                    // knows it cannot enter Exclusive
                    shared_out  = 1'b1;
                end
            end

            // ------------------------------------------------------------------
            // EXCLUSIVE: clean, only this cache has a copy
            // ------------------------------------------------------------------
            EXCLUSIVE: begin
                // Local CPU events
                if (cpu_write) begin
                    // Silent upgrade: no bus transaction needed (sole owner)
                    next_state  = MODIFIED;
                end
                if (cpu_read) begin
                    // Read hit; stay Exclusive
                end

                // Snoop events
                if (snoop_rd) begin
                    // Another CPU reads our Exclusive line
                    // We must acknowledge; supply the data (memory may be stale
                    // if E was silently upgraded — but in E state line is clean,
                    // so memory is up-to-date; no writeback needed)
                    supply_data = 1'b1;
                    shared_out  = 1'b1;
                    next_state  = SHARED;  // we lose exclusive ownership
                end
                if (snoop_rdx) begin
                    // Another CPU wants exclusive: we must give it up
                    supply_data = 1'b1;
                    next_state  = INVALID;
                end
            end

            // ------------------------------------------------------------------
            // MODIFIED: dirty, only this cache has the valid copy
            // ------------------------------------------------------------------
            MODIFIED: begin
                // Local CPU events: read and write hits — no bus activity
                if (cpu_read || cpu_write) begin
                    // Hit on Modified line: serve locally; stay Modified
                end

                // Snoop events
                if (snoop_rd) begin
                    // Another CPU reads our Modified line
                    // Memory is stale; we must supply the data (HITM)
                    // In MESI: write back to memory, then both go to Shared
                    // (In MOESI: we could go to Owned and skip the writeback,
                    //  but this module implements MESI)
                    bus_wb      = 1'b1;   // writeback to memory
                    supply_data = 1'b1;   // supply data to requestor simultaneously
                    shared_out  = 1'b1;   // line is now shared
                    next_state  = SHARED;
                end
                if (snoop_rdx) begin
                    // Another CPU wants exclusive write access to our Modified line
                    // Must supply current data and invalidate our copy
                    bus_wb      = 1'b1;
                    supply_data = 1'b1;
                    next_state  = INVALID;
                end
            end

            default: next_state = INVALID;

        endcase

        // ------------------------------------------------------------------
        // State transitions triggered by data_valid (bus transaction complete)
        // ------------------------------------------------------------------
        // Override next_state if we were waiting for a bus response
        if (data_valid) begin
            unique case (state)
                INVALID: begin
                    if (bus_rd) begin
                        // BusRd complete: enter E or S based on other_shared
                        next_state = other_shared ? SHARED : EXCLUSIVE;
                    end
                    if (bus_rdx) begin
                        // BusRdX complete: enter Modified
                        next_state = MODIFIED;
                    end
                end
                SHARED: begin
                    if (bus_upgr) begin
                        // BusUpgr acknowledged: all other sharers invalidated
                        next_state = MODIFIED;
                    end
                end
                default: ; // no data_valid expected in E or M (local ops only)
            endcase
        end
    end

    // -------------------------------------------------------------------------
    // State register
    // -------------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) state <= INVALID;
        else        state <= next_state;
    end

    // -------------------------------------------------------------------------
    // Output assignment
    // -------------------------------------------------------------------------
    assign mesi_state = state;

endmodule


// -----------------------------------------------------------------------------
// mesi_cache_ctrl — 16-line indexed wrapper
// Instantiates mesi_line_ctrl for each of 16 cache lines and routes the
// address-decoded signals from the CPU and snoop interfaces.
// In a real design, MESI state bits are stored in the tag RAM array and the
// FSM is shared; this module demonstrates the wiring pattern.
// -----------------------------------------------------------------------------

module mesi_cache_ctrl #(
    parameter int NUM_LINES = 16,
    parameter int IDX_W     = 4    // log2(NUM_LINES)
) (
    input  logic clk,
    input  logic rst_n,

    // CPU interface (one request per cycle, one line at a time)
    input  logic              cpu_req,
    input  logic              cpu_we,
    input  logic [IDX_W-1:0]  cpu_idx,    // cache line index (from address)
    input  logic              data_valid,  // bus transaction for the current cpu_idx is complete
    input  logic              other_shared, // another cache asserted SHARED# for cpu_idx

    // Snoop interface (bus-wide; idx indicates which line is being snooped)
    input  logic [IDX_W-1:0]  snoop_idx,
    input  logic              snoop_rd,
    input  logic              snoop_rdx,
    input  logic              snoop_upgr,

    // Bus outputs (ORed across all lines; only one line should drive per cycle)
    output logic              bus_rd,
    output logic              bus_rdx,
    output logic              bus_upgr,
    output logic              bus_wb,

    // Snoop response (from the snooped line)
    output logic              supply_data,
    output logic              shared_out,

    // MESI state array (for inspection)
    output logic [1:0]        mesi_state [NUM_LINES-1:0]
);

    // -------------------------------------------------------------------------
    // Per-line signal buses
    // -------------------------------------------------------------------------
    logic [NUM_LINES-1:0] line_bus_rd,  line_bus_rdx, line_bus_upgr, line_bus_wb;
    logic [NUM_LINES-1:0] line_supply,  line_shared;
    logic [NUM_LINES-1:0] line_cpu_rd,  line_cpu_wr;
    logic [NUM_LINES-1:0] line_data_v,  line_other_s;
    logic [NUM_LINES-1:0] line_snp_rd,  line_snp_rdx, line_snp_upgr;

    // -------------------------------------------------------------------------
    // Decode: route CPU and snoop signals to the addressed line only
    // -------------------------------------------------------------------------
    always_comb begin
        for (int i = 0; i < NUM_LINES; i++) begin
            // CPU signals: target cpu_idx
            line_cpu_rd  [i] = cpu_req && !cpu_we  && (cpu_idx   == IDX_W'(i));
            line_cpu_wr  [i] = cpu_req &&  cpu_we  && (cpu_idx   == IDX_W'(i));
            line_data_v  [i] = data_valid           && (cpu_idx   == IDX_W'(i));
            line_other_s [i] = other_shared         && (cpu_idx   == IDX_W'(i));

            // Snoop signals: target snoop_idx
            line_snp_rd  [i] = snoop_rd             && (snoop_idx == IDX_W'(i));
            line_snp_rdx [i] = snoop_rdx            && (snoop_idx == IDX_W'(i));
            line_snp_upgr[i] = snoop_upgr           && (snoop_idx == IDX_W'(i));
        end
    end

    // -------------------------------------------------------------------------
    // Generate one mesi_line_ctrl per cache line
    // -------------------------------------------------------------------------
    genvar g;
    generate
        for (g = 0; g < NUM_LINES; g++) begin : gen_mesi_line
            mesi_line_ctrl u_mesi (
                .clk         (clk),
                .rst_n       (rst_n),
                .cpu_read    (line_cpu_rd  [g]),
                .cpu_write   (line_cpu_wr  [g]),
                .data_valid  (line_data_v  [g]),
                .other_shared(line_other_s [g]),
                .snoop_rd    (line_snp_rd  [g]),
                .snoop_rdx   (line_snp_rdx [g]),
                .snoop_upgr  (line_snp_upgr[g]),
                .bus_rd      (line_bus_rd  [g]),
                .bus_rdx     (line_bus_rdx [g]),
                .bus_upgr    (line_bus_upgr[g]),
                .bus_wb      (line_bus_wb  [g]),
                .supply_data (line_supply  [g]),
                .shared_out  (line_shared  [g]),
                .mesi_state  (mesi_state   [g])
            );
        end
    endgenerate

    // -------------------------------------------------------------------------
    // OR-reduce bus outputs (only one line should drive per cycle in a real design)
    // -------------------------------------------------------------------------
    assign bus_rd      = |line_bus_rd;
    assign bus_rdx     = |line_bus_rdx;
    assign bus_upgr    = |line_bus_upgr;
    assign bus_wb      = |line_bus_wb;
    assign supply_data = |line_supply;
    assign shared_out  = |line_shared;

endmodule


// =============================================================================
// Testbench — tb_mesi
// =============================================================================
// Exercises the seven core MESI scenarios described in the problem statement.
// Uses mesi_line_ctrl directly (one line under test).
// =============================================================================

module tb_mesi;

    // -------------------------------------------------------------------------
    // DUT signals
    // -------------------------------------------------------------------------
    logic clk, rst_n;
    logic cpu_read, cpu_write, data_valid, other_shared;
    logic snoop_rd, snoop_rdx, snoop_upgr;
    logic bus_rd, bus_rdx, bus_upgr, bus_wb;
    logic supply_data, shared_out;
    logic [1:0] mesi_state;

    // -------------------------------------------------------------------------
    // DUT instantiation
    // -------------------------------------------------------------------------
    mesi_line_ctrl dut (
        .clk         (clk),
        .rst_n       (rst_n),
        .cpu_read    (cpu_read),
        .cpu_write   (cpu_write),
        .data_valid  (data_valid),
        .other_shared(other_shared),
        .snoop_rd    (snoop_rd),
        .snoop_rdx   (snoop_rdx),
        .snoop_upgr  (snoop_upgr),
        .bus_rd      (bus_rd),
        .bus_rdx     (bus_rdx),
        .bus_upgr    (bus_upgr),
        .bus_wb      (bus_wb),
        .supply_data (supply_data),
        .shared_out  (shared_out),
        .mesi_state  (mesi_state)
    );

    // -------------------------------------------------------------------------
    // Clock: 10 ns period
    // -------------------------------------------------------------------------
    initial clk = 0;
    always #5 clk = ~clk;

    // -------------------------------------------------------------------------
    // State name function for display
    // -------------------------------------------------------------------------
    function automatic string state_name(input logic [1:0] s);
        case (s)
            2'b00: return "INVALID";
            2'b01: return "SHARED";
            2'b10: return "EXCLUSIVE";
            2'b11: return "MODIFIED";
            default: return "UNKNOWN";
        endcase
    endfunction

    // -------------------------------------------------------------------------
    // Helper: assert a one-cycle event and optionally wait for data_valid
    // -------------------------------------------------------------------------
    task automatic do_cpu_read(input logic shared_response);
        @(posedge clk);
        cpu_read    = 1'b1;
        other_shared = shared_response;
        @(posedge clk);
        cpu_read    = 1'b0;
        // Simulate bus latency (2 cycles) then deliver data
        repeat(2) @(posedge clk);
        data_valid  = 1'b1;
        other_shared = shared_response;  // hold for this cycle
        @(posedge clk);
        data_valid  = 1'b0;
        other_shared = 1'b0;
    endtask

    task automatic do_cpu_write();
        @(posedge clk);
        cpu_write = 1'b1;
        @(posedge clk);
        cpu_write = 1'b0;
        repeat(2) @(posedge clk);
        data_valid = 1'b1;
        @(posedge clk);
        data_valid = 1'b0;
    endtask

    task automatic do_snoop(input logic rd, rdx, upgr);
        @(posedge clk);
        snoop_rd   = rd;
        snoop_rdx  = rdx;
        snoop_upgr = upgr;
        @(posedge clk);
        snoop_rd   = 1'b0;
        snoop_rdx  = 1'b0;
        snoop_upgr = 1'b0;
    endtask

    task automatic check_state(input logic [1:0] expected, input string scenario);
        if (mesi_state !== expected)
            $display("  FAIL [%s]: expected %s, got %s",
                     scenario, state_name(expected), state_name(mesi_state));
        else
            $display("  PASS [%s]: state = %s", scenario, state_name(mesi_state));
    endtask

    // -------------------------------------------------------------------------
    // Reset helper
    // -------------------------------------------------------------------------
    task automatic reset_dut();
        rst_n        = 1'b0;
        cpu_read     = 1'b0;
        cpu_write    = 1'b0;
        data_valid   = 1'b0;
        other_shared = 1'b0;
        snoop_rd     = 1'b0;
        snoop_rdx    = 1'b0;
        snoop_upgr   = 1'b0;
        repeat(4) @(posedge clk);
        rst_n = 1'b1;
        repeat(2) @(posedge clk);
    endtask

    // -------------------------------------------------------------------------
    // Test sequence
    // -------------------------------------------------------------------------
    initial begin
        $display("=== MESI State Machine Test ===");

        // -----------------------------------------------------------------------
        // Scenario A: Cold read, no other sharer → I → E
        // -----------------------------------------------------------------------
        $display("\n[A] Cold read, no other sharer: I → E");
        reset_dut();
        do_cpu_read(1'b0);   // no_shared = 0 means no other cache has it
        @(posedge clk);
        check_state(2'b10, "A: I→E");

        // -----------------------------------------------------------------------
        // Scenario B: Cold read, another cache has the line → I → S
        // -----------------------------------------------------------------------
        $display("\n[B] Cold read, another sharer: I → S");
        reset_dut();
        do_cpu_read(1'b1);   // other_shared = 1: another cache asserts SHARED#
        @(posedge clk);
        check_state(2'b01, "B: I→S");

        // -----------------------------------------------------------------------
        // Scenario C: Write hit on Shared line → S → M (BusUpgr)
        // -----------------------------------------------------------------------
        $display("\n[C] Write hit on S line: S → M via BusUpgr");
        reset_dut();
        do_cpu_read(1'b1);   // put line in S state
        @(posedge clk);
        check_state(2'b01, "C: confirm S");
        do_cpu_write();      // write to S line: issue BusUpgr
        @(posedge clk);
        check_state(2'b11, "C: S→M");
        $display("  INFO: bus_upgr should have been asserted (check waveform)");

        // -----------------------------------------------------------------------
        // Scenario D: Write miss (line Invalid) → I → M via BusRdX
        // -----------------------------------------------------------------------
        $display("\n[D] Write miss: I → M via BusRdX");
        reset_dut();
        do_cpu_write();
        @(posedge clk);
        check_state(2'b11, "D: I→M");
        $display("  INFO: bus_rdx should have been asserted (check waveform)");

        // -----------------------------------------------------------------------
        // Scenario E: Snoop BusRd on M line → M → S (supply + writeback)
        // -----------------------------------------------------------------------
        $display("\n[E] Snoop BusRd on M line: M → S");
        reset_dut();
        do_cpu_write();      // put line in M
        @(posedge clk);
        check_state(2'b11, "E: confirm M");
        do_snoop(1'b1, 1'b0, 1'b0);  // snoop_rd
        @(posedge clk);
        check_state(2'b01, "E: M→S");
        $display("  INFO: bus_wb and supply_data should both have been asserted");

        // -----------------------------------------------------------------------
        // Scenario F: Snoop BusRdX on S line → S → I
        // -----------------------------------------------------------------------
        $display("\n[F] Snoop BusRdX on S line: S → I");
        reset_dut();
        do_cpu_read(1'b1);   // put in S
        @(posedge clk);
        check_state(2'b01, "F: confirm S");
        do_snoop(1'b0, 1'b1, 1'b0);  // snoop_rdx
        @(posedge clk);
        check_state(2'b00, "F: S→I");

        // -----------------------------------------------------------------------
        // Scenario G: Snoop BusRdX on M line → M → I (supply + writeback)
        // -----------------------------------------------------------------------
        $display("\n[G] Snoop BusRdX on M line: M → I");
        reset_dut();
        do_cpu_write();      // put in M
        @(posedge clk);
        check_state(2'b11, "G: confirm M");
        do_snoop(1'b0, 1'b1, 1'b0);  // snoop_rdx
        @(posedge clk);
        check_state(2'b00, "G: M→I");
        $display("  INFO: bus_wb and supply_data should both have been asserted");

        // -----------------------------------------------------------------------
        // Scenario H: Silent upgrade E → M (local write, no bus transaction)
        // -----------------------------------------------------------------------
        $display("\n[H] Silent upgrade: E → M (no bus transaction)");
        reset_dut();
        do_cpu_read(1'b0);   // put in E
        @(posedge clk);
        check_state(2'b10, "H: confirm E");
        // Write hit on E line: no bus transaction needed
        @(posedge clk);
        cpu_write = 1'b1;
        @(posedge clk);
        cpu_write = 1'b0;
        @(posedge clk);
        check_state(2'b11, "H: E→M silent");
        $display("  INFO: no bus_rdx or bus_upgr should have been asserted for H");

        // -----------------------------------------------------------------------
        // Done
        // -----------------------------------------------------------------------
        repeat(4) @(posedge clk);
        $display("\n=== MESI test complete ===");
        $finish;
    end

    // Watchdog
    initial begin
        #50000;
        $display("TIMEOUT");
        $finish;
    end

endmodule
