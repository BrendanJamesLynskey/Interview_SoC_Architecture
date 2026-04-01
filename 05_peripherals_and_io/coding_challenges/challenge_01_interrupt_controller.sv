// =============================================================================
// Challenge 01: Priority Interrupt Controller
// =============================================================================
//
// PROBLEM STATEMENT
// -----------------
// Implement a 4-source priority interrupt controller with the following spec:
//
//   - 4 interrupt sources: irq_i[3:0], level-sensitive, active-high
//   - Each source has an independent 2-bit priority register (0=highest, 3=lowest)
//   - Each source has an independent enable bit
//   - A 2-bit global threshold register masks all interrupts with priority
//     numerically >= threshold (i.e. lower urgency than threshold)
//   - Outputs:
//       irq_valid_o : 1 if any enabled, unmasked, pending interrupt exists
//       irq_id_o    : 2-bit ID of the highest-priority pending interrupt
//       irq_prio_o  : 2-bit priority of the selected interrupt
//   - A claim register read clears the pending bit for the currently selected
//     interrupt (simulated here as a single-cycle claim pulse)
//   - APB slave interface for register access
//
// REGISTER MAP (byte-addressed, 32-bit APB)
// -----------------------------------------
//   0x00  ENABLE     [3:0]     Per-source enable (1=enabled)
//   0x04  PENDING    [3:0]     Pending status, read-only; write 1 to clear (W1C)
//   0x08  PRIORITY0  [1:0]     Priority for source 0
//   0x0C  PRIORITY1  [1:0]     Priority for source 1
//   0x10  PRIORITY2  [1:0]     Priority for source 2
//   0x14  PRIORITY3  [1:0]     Priority for source 3
//   0x18  THRESHOLD  [1:0]     Only sources with priority < threshold are forwarded
//   0x1C  CLAIM      [1:0]     Read: returns current irq_id, clears pending (R/W1C)
//
// CONSTRAINTS
// -----------
//   - All combinational logic for priority selection must be RTL (no $clog2 tricks)
//   - Pending bits are set on the rising edge of irq_i and cleared by claim write
//   - If two sources have equal priority, the lower-numbered source wins
//   - APB read/write with 1 wait state (PREADY asserted one cycle after PSEL)
//
// =============================================================================

`timescale 1ns / 1ps
`default_nettype none

// =============================================================================
// Module: prio_irq_ctrl
// =============================================================================
module prio_irq_ctrl (
    // Clock and reset
    input  wire        clk_i,
    input  wire        rst_ni,       // Active-low synchronous reset

    // Interrupt sources (level-sensitive, active-high)
    input  wire [3:0]  irq_i,

    // Interrupt outputs to processor
    output logic       irq_valid_o,
    output logic [1:0] irq_id_o,
    output logic [1:0] irq_prio_o,

    // APB slave interface
    input  wire        psel_i,
    input  wire        penable_i,
    input  wire        pwrite_i,
    input  wire [7:0]  paddr_i,      // Byte address
    input  wire [31:0] pwdata_i,
    output logic [31:0] prdata_o,
    output logic       pready_o,
    output logic       pslverr_o
);

    // -------------------------------------------------------------------------
    // Internal registers
    // -------------------------------------------------------------------------
    logic [3:0]  enable_q;           // Per-source enable
    logic [3:0]  pending_q;          // Per-source pending latch
    logic [1:0]  priority_q [3:0];   // Per-source priority (0=highest)
    logic [1:0]  threshold_q;        // Global priority threshold

    // -------------------------------------------------------------------------
    // Edge detection for irq_i (level → pending set)
    // -------------------------------------------------------------------------
    // We treat irq_i as level-sensitive: pending is set while irq_i is asserted
    // and can only be cleared by a claim write. This mirrors the PLIC model.
    logic [3:0]  irq_d;              // One-cycle delayed irq_i for edge detect

    always_ff @(posedge clk_i) begin
        if (!rst_ni) begin
            irq_d <= 4'h0;
        end else begin
            irq_d <= irq_i;
        end
    end

    // Rising-edge detect
    wire [3:0] irq_rising = irq_i & ~irq_d;

    // -------------------------------------------------------------------------
    // APB state machine (one wait state)
    // -------------------------------------------------------------------------
    // PREADY is driven combinatorially here: asserted on the second cycle
    // (when penable_i is high). This gives the required 1 wait state.

    typedef enum logic [1:0] {
        APB_IDLE    = 2'b00,
        APB_SETUP   = 2'b01,
        APB_ACCESS  = 2'b10
    } apb_state_t;

    apb_state_t apb_state;

    // Claim pulse: single-cycle signal when software reads the CLAIM register
    logic claim_pulse;
    logic [1:0] claim_id;

    assign pready_o  = (apb_state == APB_ACCESS);
    assign pslverr_o = 1'b0;         // No error response in this implementation

    always_ff @(posedge clk_i) begin
        if (!rst_ni) begin
            apb_state <= APB_IDLE;
        end else begin
            case (apb_state)
                APB_IDLE:   apb_state <= psel_i ? APB_SETUP  : APB_IDLE;
                APB_SETUP:  apb_state <= APB_ACCESS;
                APB_ACCESS: apb_state <= psel_i ? APB_SETUP  : APB_IDLE;
                default:    apb_state <= APB_IDLE;
            endcase
        end
    end

    // -------------------------------------------------------------------------
    // Register write logic
    // -------------------------------------------------------------------------
    always_ff @(posedge clk_i) begin
        if (!rst_ni) begin
            enable_q    <= 4'h0;
            priority_q[0] <= 2'b11;  // All sources start at lowest priority
            priority_q[1] <= 2'b11;
            priority_q[2] <= 2'b11;
            priority_q[3] <= 2'b11;
            threshold_q <= 2'b00;    // No masking by default (pass all)
        end else if (pready_o && pwrite_i) begin
            case (paddr_i[7:0])
                8'h00: enable_q       <= pwdata_i[3:0];
                8'h08: priority_q[0]  <= pwdata_i[1:0];
                8'h0C: priority_q[1]  <= pwdata_i[1:0];
                8'h10: priority_q[2]  <= pwdata_i[1:0];
                8'h14: priority_q[3]  <= pwdata_i[1:0];
                8'h18: threshold_q    <= pwdata_i[1:0];
                default: ; // Ignore writes to read-only registers
            endcase
        end
    end

    // -------------------------------------------------------------------------
    // Pending register: set on rising edge of irq_i, clear by W1C or claim
    // -------------------------------------------------------------------------
    // W1C: write 1 to PENDING register clears the bit
    wire [3:0] pending_clr_apb = (pready_o && pwrite_i && paddr_i == 8'h04)
                                  ? pwdata_i[3:0]
                                  : 4'h0;

    // Claim also clears the pending bit for the selected source
    wire [3:0] pending_clr_claim;
    assign pending_clr_claim = claim_pulse ? (4'h1 << claim_id) : 4'h0;

    always_ff @(posedge clk_i) begin
        if (!rst_ni) begin
            pending_q <= 4'h0;
        end else begin
            // Priority: clear takes precedence over set to avoid a stuck bit
            // when both claim and a new rising edge occur on the same cycle
            pending_q <= (pending_q | irq_rising)
                         & ~pending_clr_apb
                         & ~pending_clr_claim;
        end
    end

    // -------------------------------------------------------------------------
    // Register read logic
    // -------------------------------------------------------------------------
    always_comb begin
        prdata_o   = 32'h0;
        claim_pulse = 1'b0;
        claim_id    = 2'h0;

        if (pready_o && !pwrite_i) begin
            case (paddr_i[7:0])
                8'h00: prdata_o = {28'h0, enable_q};
                8'h04: prdata_o = {28'h0, pending_q};
                8'h08: prdata_o = {30'h0, priority_q[0]};
                8'h0C: prdata_o = {30'h0, priority_q[1]};
                8'h10: prdata_o = {30'h0, priority_q[2]};
                8'h14: prdata_o = {30'h0, priority_q[3]};
                8'h18: prdata_o = {30'h0, threshold_q};
                8'h1C: begin
                    // Claim: return current irq_id, trigger pending clear
                    prdata_o    = {30'h0, irq_id_o};
                    claim_pulse = irq_valid_o;
                    claim_id    = irq_id_o;
                end
                default: prdata_o = 32'hDEAD_BEEF; // Unmapped address indicator
            endcase
        end
    end

    // -------------------------------------------------------------------------
    // Priority selection: combinational tournament tree
    // -------------------------------------------------------------------------
    // For each source, compute the effective sort key: {priority, source_id}
    // Lower sort key wins (lower priority number = higher urgency;
    // lower source ID breaks ties).
    //
    // A source is "eligible" if it is: enabled AND pending AND priority < threshold
    // Note: threshold=0 means all sources are masked (nothing < 0).

    typedef struct packed {
        logic [1:0] prio;
        logic [1:0] id;
        logic       valid;
    } candidate_t;

    candidate_t cand [3:0];

    genvar g;
    generate
        for (g = 0; g < 4; g++) begin : gen_candidates
            assign cand[g].valid = enable_q[g]
                                && pending_q[g]
                                && (priority_q[g] < threshold_q);
            assign cand[g].prio  = priority_q[g];
            assign cand[g].id    = g[1:0];
        end
    endgenerate

    // Two-level tournament: compare pairs, then compare winners
    candidate_t win_01, win_23, winner;

    function automatic candidate_t compare_cands(
        input candidate_t a,
        input candidate_t b
    );
        // Returns the higher-priority (lower sort key) candidate
        // If neither is valid, returns a with valid=0
        if (!a.valid && !b.valid) begin
            compare_cands = a;  // both invalid, doesn't matter
        end else if (!a.valid) begin
            compare_cands = b;
        end else if (!b.valid) begin
            compare_cands = a;
        end else if ({a.prio, a.id} <= {b.prio, b.id}) begin
            compare_cands = a;  // a wins (lower sort key, or tie broken by id)
        end else begin
            compare_cands = b;
        end
    endfunction

    always_comb begin
        win_01 = compare_cands(cand[0], cand[1]);
        win_23 = compare_cands(cand[2], cand[3]);
        winner = compare_cands(win_01, win_23);

        irq_valid_o = winner.valid;
        irq_id_o    = winner.id;
        irq_prio_o  = winner.prio;
    end

endmodule : prio_irq_ctrl


// =============================================================================
// Testbench stub: prio_irq_ctrl_tb
// =============================================================================
// Instantiates the DUT and provides basic stimulus.
// Expand with the test scenarios listed in the TODO sections.
// =============================================================================
module prio_irq_ctrl_tb;

    // -------------------------------------------------------------------------
    // Parameters
    // -------------------------------------------------------------------------
    localparam CLK_PERIOD_NS = 10;  // 100 MHz

    // -------------------------------------------------------------------------
    // DUT signals
    // -------------------------------------------------------------------------
    logic        clk;
    logic        rst_n;
    logic [3:0]  irq;
    logic        irq_valid;
    logic [1:0]  irq_id;
    logic [1:0]  irq_prio;
    logic        psel;
    logic        penable;
    logic        pwrite;
    logic [7:0]  paddr;
    logic [31:0] pwdata;
    logic [31:0] prdata;
    logic        pready;
    logic        pslverr;

    // -------------------------------------------------------------------------
    // DUT instantiation
    // -------------------------------------------------------------------------
    prio_irq_ctrl dut (
        .clk_i      (clk),
        .rst_ni     (rst_n),
        .irq_i      (irq),
        .irq_valid_o(irq_valid),
        .irq_id_o   (irq_id),
        .irq_prio_o (irq_prio),
        .psel_i     (psel),
        .penable_i  (penable),
        .pwrite_i   (pwrite),
        .paddr_i    (paddr),
        .pwdata_i   (pwdata),
        .prdata_o   (prdata),
        .pready_o   (pready),
        .pslverr_o  (pslverr)
    );

    // -------------------------------------------------------------------------
    // Clock generation
    // -------------------------------------------------------------------------
    initial clk = 1'b0;
    always #(CLK_PERIOD_NS / 2) clk = ~clk;

    // -------------------------------------------------------------------------
    // APB helper tasks
    // -------------------------------------------------------------------------
    task apb_write(input [7:0] addr, input [31:0] data);
        @(negedge clk);
        psel   = 1'b1;
        pwrite = 1'b1;
        paddr  = addr;
        pwdata = data;
        penable = 1'b0;
        @(negedge clk);
        penable = 1'b1;
        @(posedge clk);
        while (!pready) @(posedge clk);
        @(negedge clk);
        psel    = 1'b0;
        penable = 1'b0;
    endtask

    task apb_read(input [7:0] addr, output [31:0] data);
        @(negedge clk);
        psel    = 1'b1;
        pwrite  = 1'b0;
        paddr   = addr;
        penable = 1'b0;
        @(negedge clk);
        penable = 1'b1;
        @(posedge clk);
        while (!pready) @(posedge clk);
        data = prdata;
        @(negedge clk);
        psel    = 1'b0;
        penable = 1'b0;
    endtask

    // -------------------------------------------------------------------------
    // Checker helper
    // -------------------------------------------------------------------------
    int pass_count = 0;
    int fail_count = 0;

    task check(
        input string  test_name,
        input logic   got_valid,
        input logic [1:0] got_id,
        input logic   exp_valid,
        input logic [1:0] exp_id
    );
        if (got_valid === exp_valid && (!exp_valid || got_id === exp_id)) begin
            $display("PASS: %s  (valid=%0b id=%0d)", test_name, got_valid, got_id);
            pass_count++;
        end else begin
            $display("FAIL: %s  got valid=%0b id=%0d  expected valid=%0b id=%0d",
                     test_name, got_valid, got_id, exp_valid, exp_id);
            fail_count++;
        end
    endtask

    // -------------------------------------------------------------------------
    // Test sequence
    // -------------------------------------------------------------------------
    logic [31:0] rdata;

    initial begin
        // Initialise signals
        rst_n   = 1'b0;
        irq     = 4'h0;
        psel    = 1'b0;
        penable = 1'b0;
        pwrite  = 1'b0;
        paddr   = 8'h0;
        pwdata  = 32'h0;

        // Release reset
        repeat (4) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);

        // ------------------------------------------------------------------
        // Test 1: No interrupts asserted, no valid output
        // ------------------------------------------------------------------
        @(posedge clk);
        check("T1_no_irq", irq_valid, irq_id, 1'b0, 2'bxx);

        // ------------------------------------------------------------------
        // Test 2: Enable all sources, set priorities, assert IRQ2
        //   Priority: IRQ0=3(low), IRQ1=2, IRQ2=1, IRQ3=0(high)
        //   Threshold=3 (pass sources with prio < 3, i.e. prio 0,1,2)
        // ------------------------------------------------------------------
        apb_write(8'h00, 32'hF);    // Enable all 4 sources
        apb_write(8'h08, 32'h3);    // IRQ0 priority = 3
        apb_write(8'h0C, 32'h2);    // IRQ1 priority = 2
        apb_write(8'h10, 32'h1);    // IRQ2 priority = 1
        apb_write(8'h14, 32'h0);    // IRQ3 priority = 0
        apb_write(8'h18, 32'h3);    // Threshold = 3

        irq = 4'b0100;              // Assert IRQ2
        repeat (3) @(posedge clk);  // Allow edge detect and pending set
        check("T2_irq2_only", irq_valid, irq_id, 1'b1, 2'd2);

        // ------------------------------------------------------------------
        // Test 3: Assert IRQ3 (higher priority) simultaneously — IRQ3 wins
        // ------------------------------------------------------------------
        irq = 4'b1100;              // Assert IRQ2 and IRQ3
        repeat (2) @(posedge clk);
        check("T3_irq3_wins", irq_valid, irq_id, 1'b1, 2'd3);

        // ------------------------------------------------------------------
        // Test 4: Claim IRQ3, check IRQ2 becomes selected
        // ------------------------------------------------------------------
        apb_read(8'h1C, rdata);     // Claim: should return ID=3, clear pending[3]
        repeat (2) @(posedge clk);
        check("T4_after_claim_irq2", irq_valid, irq_id, 1'b1, 2'd2);

        // ------------------------------------------------------------------
        // Test 5: Threshold masks IRQ2 (prio=1 is NOT < threshold=1)
        //   Only IRQ3 (prio=0) should pass through
        //   IRQ3 pending was cleared; re-assert it
        // ------------------------------------------------------------------
        apb_write(8'h18, 32'h1);    // Threshold = 1 (only prio 0 passes)
        irq = 4'b1100;              // Both IRQ2 and IRQ3
        repeat (3) @(posedge clk);
        check("T5_threshold_masks_irq2", irq_valid, irq_id, 1'b1, 2'd3);

        // ------------------------------------------------------------------
        // Test 6: Disable IRQ3, check no valid output (IRQ2 masked by threshold)
        // ------------------------------------------------------------------
        apb_write(8'h00, 32'h7);    // Disable IRQ3 (bit3=0)
        repeat (2) @(posedge clk);
        check("T6_all_masked_or_disabled", irq_valid, irq_id, 1'b0, 2'bxx);

        // ------------------------------------------------------------------
        // Test 7: Equal priority — lower source ID wins (IRQ0 vs IRQ1, both prio=2)
        // ------------------------------------------------------------------
        apb_write(8'h00, 32'hF);    // Re-enable all
        apb_write(8'h08, 32'h2);    // IRQ0 prio = 2
        apb_write(8'h0C, 32'h2);    // IRQ1 prio = 2
        apb_write(8'h18, 32'h3);    // Threshold = 3
        irq = 4'b0011;              // Assert IRQ0 and IRQ1
        repeat (3) @(posedge clk);
        check("T7_equal_prio_lower_id_wins", irq_valid, irq_id, 1'b1, 2'd0);

        // ------------------------------------------------------------------
        // Test 8: W1C on PENDING register clears bit
        // ------------------------------------------------------------------
        irq = 4'h0;                 // Deassert all
        repeat (2) @(posedge clk);
        apb_read(8'h04, rdata);
        $display("INFO: PENDING before W1C = 0x%0h", rdata[3:0]);
        apb_write(8'h04, 32'h3);    // Clear pending[0] and pending[1]
        repeat (2) @(posedge clk);
        apb_read(8'h04, rdata);
        if (rdata[1:0] == 2'b00)
            $display("PASS: T8_w1c_pending  (pending[1:0]=00)");
        else
            $display("FAIL: T8_w1c_pending  got pending=%0b", rdata[1:0]);

        // ------------------------------------------------------------------
        // Summary
        // ------------------------------------------------------------------
        repeat (4) @(posedge clk);
        $display("--------------------------------------------");
        $display("Results: %0d passed, %0d failed", pass_count, fail_count);
        $display("--------------------------------------------");
        $finish;
    end

    // -------------------------------------------------------------------------
    // Timeout watchdog
    // -------------------------------------------------------------------------
    initial begin
        #100_000;
        $display("TIMEOUT: simulation exceeded 100us");
        $finish;
    end

    // -------------------------------------------------------------------------
    // Waveform dump
    // -------------------------------------------------------------------------
    initial begin
        $dumpfile("challenge_01_irq_ctrl.vcd");
        $dumpvars(0, prio_irq_ctrl_tb);
    end

    // TODO: Add the following additional test scenarios:
    // - Rapid successive interrupts to stress edge detection
    // - Multiple simultaneous claim attempts via software (ICPR equivalent)
    // - All 4 sources at unique priorities, assert all simultaneously
    // - Verify pending bit is NOT cleared on a claim when irq_valid is 0
    // - Randomised priority and enable configurations with scoreboard checking

endmodule : prio_irq_ctrl_tb
