// =============================================================================
// Challenge 4: Round-Robin Arbiter for AXI Crossbar
// =============================================================================
//
// Objective:
//   Implement a parameterised round-robin arbiter suitable for use in an AXI
//   crossbar interconnect. The arbiter:
//     - Accepts N requestors competing for a single resource (slave port)
//     - Implements strict round-robin fairness with configurable priority weight
//     - Supports QoS-weighted priority (optional)
//     - Holds grant stable for the full duration of an AXI burst
//     - Implements a starvation-prevention mechanism via a timeout counter
//     - Returns the grant one-hot vector and the grant index
//
// Design variants implemented:
//   1. Pure round-robin arbiter (fair, no priority)
//   2. Weighted round-robin arbiter (QoS-weighted slots per round)
//   3. Priority arbiter with starvation avoidance (escalation after timeout)
//
// AXI crossbar context:
//   Each slave port in an AXI crossbar has one of these arbiters.
//   The arbiter selects which master port currently drives the address channel
//   to the slave. Once a master is granted, it holds the grant for the entire
//   burst (until the slave accepts WLAST or the final R beat).
//
// Interface:
//   req[N-1:0]       -- request vector (1 = this master has a pending transaction)
//   lock[N-1:0]      -- lock: hold grant until lock is deasserted (burst in progress)
//   qos[N-1:0][3:0]  -- QoS level per requestor (0=lowest, 15=highest)
//   grant[N-1:0]     -- one-hot grant output
//   grant_idx        -- binary grant index
//   grant_valid      -- a grant is active
//
// =============================================================================

`timescale 1ns/1ps

// =============================================================================
// Module 1: Pure Round-Robin Arbiter
// =============================================================================
//
// Algorithm: rotating priority vector.
// After granting to master i, the lowest-priority slot rotates to i+1,
// so on the next arbitration cycle, masters i+1 .. N-1 .. 0 .. i-1 are
// tried in order. This guarantees that every master is served in at most
// N consecutive cycles.
//
module round_robin_arbiter #(
    parameter int N = 4    // Number of requestors
) (
    input  logic           clk,
    input  logic           rst_n,

    input  logic [N-1:0]   req,        // Request vector
    input  logic [N-1:0]   lock,       // Hold grant while burst is active
    output logic [N-1:0]   grant,      // One-hot grant
    output logic [$clog2(N)-1:0] grant_idx, // Binary grant index
    output logic           grant_valid  // At least one grant is active
);

    // -------------------------------------------------------------------------
    // Rotating priority register
    // After a grant, the priority pointer moves to (grant_idx + 1) % N
    // -------------------------------------------------------------------------
    logic [N-1:0] priority_ptr;  // One-hot: highest priority position

    // -------------------------------------------------------------------------
    // Arbitration function: masked priority encoder
    // Finds the highest-priority requester starting from priority_ptr,
    // wrapping around. Uses two copies of the request vector (double-length)
    // to simplify the wrap-around logic.
    // -------------------------------------------------------------------------
    function automatic logic [N-1:0] masked_rr_grant(
        input logic [N-1:0] request,
        input logic [N-1:0] priority_vec
    );
        logic [2*N-1:0] req_dbl;
        logic [2*N-1:0] pri_dbl;
        logic [2*N-1:0] masked;
        logic [N-1:0]   result;
        int first_set;

        req_dbl = {request, request};
        // Find the starting bit position (one-hot priority_vec -> binary index)
        first_set = 0;
        for (int i = 0; i < N; i++) begin
            if (priority_vec[i]) first_set = i;
        end

        // Mask: only look at bits from first_set onwards
        masked = req_dbl >> first_set;

        // Find lowest set bit in masked (first requester in priority order)
        result = '0;
        for (int i = 2*N-1; i >= 0; i--) begin
            if (masked[i]) result = N'(1 << ((i + first_set) % N));
        end
        return result;
    endfunction

    // -------------------------------------------------------------------------
    // Current grant (registered)
    // -------------------------------------------------------------------------
    logic [N-1:0] grant_r;
    logic         grant_active;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            grant_r      <= '0;
            priority_ptr <= N'(1); // Start with requestor 0 as highest priority
            grant_active <= 1'b0;
        end else begin
            if (grant_active && |(grant_r & lock)) begin
                // Burst in progress: hold current grant
                // (Do not re-arbitrate until lock is released)
            end else if (|req) begin
                // Arbitrate: find next grant
                grant_r      <= masked_rr_grant(req, priority_ptr);
                grant_active <= 1'b1;

                // Rotate priority to one past the current winner
                // This is done combinatorially before registering
            end else begin
                grant_r      <= '0;
                grant_active <= 1'b0;
            end
        end
    end

    // Rotate priority pointer one cycle after a grant is issued
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            priority_ptr <= N'(1);
        end else begin
            if (grant_active && !(|(grant_r & lock))) begin
                // Grant was just issued (not locked): rotate pointer
                // priority_ptr = one-hot rotate left by one
                priority_ptr <= {priority_ptr[N-2:0], priority_ptr[N-1]};
            end
        end
    end

    // -------------------------------------------------------------------------
    // Output assignments
    // -------------------------------------------------------------------------
    assign grant       = grant_r;
    assign grant_valid = grant_active && |grant_r;

    // Binary grant index from one-hot grant
    always_comb begin
        grant_idx = '0;
        for (int i = 0; i < N; i++) begin
            if (grant_r[i]) grant_idx = $clog2(N)'(i);
        end
    end

endmodule : round_robin_arbiter


// =============================================================================
// Module 2: Weighted Round-Robin Arbiter (QoS-aware)
// =============================================================================
//
// Each requestor is assigned a weight (1 to MAX_WEIGHT = 16 slots per round).
// In each arbitration round, a requestor gets weight[i] grant opportunities
// before the priority advances past it. A requestor with weight=8 gets 8x
// more bandwidth than one with weight=1 (in a saturated system).
//
// This models AXI QoS: AXQOS=15 -> weight=16, AXQOS=0 -> weight=1.
//
module weighted_rr_arbiter #(
    parameter int N          = 4,   // Number of requestors
    parameter int MAX_WEIGHT = 16   // Maximum weight per requestor
) (
    input  logic                        clk,
    input  logic                        rst_n,

    input  logic [N-1:0]                req,
    input  logic [N-1:0]                lock,
    input  logic [$clog2(MAX_WEIGHT):0] weight [0:N-1],  // Per-requestor weights

    output logic [N-1:0]                grant,
    output logic [$clog2(N)-1:0]        grant_idx,
    output logic                        grant_valid
);

    // -------------------------------------------------------------------------
    // Per-requestor credit counters
    // Each requestor starts each round with weight[i] credits.
    // Each grant to requestor i decrements its credit. When credits reach 0,
    // the requestor is excluded from the current round until all are exhausted
    // and credits are refilled.
    // -------------------------------------------------------------------------
    logic [$clog2(MAX_WEIGHT):0] credits [0:N-1];
    logic [N-1:0]                has_credit;

    // A requestor can be granted if it has both a pending request and credits
    logic [N-1:0] eligible;

    genvar gi;
    generate
        for (gi = 0; gi < N; gi++) begin : gen_credit_check
            assign has_credit[gi] = (credits[gi] != '0);
        end
    endgenerate

    assign eligible = req & has_credit;

    // -------------------------------------------------------------------------
    // Round-robin pointer among eligible requestors
    // -------------------------------------------------------------------------
    logic [N-1:0] priority_ptr;
    logic [N-1:0] grant_r;
    logic         grant_active;

    // Simplified masked priority encoder (inline for weighted case)
    function automatic logic [N-1:0] first_eligible(
        input logic [N-1:0] eligible_vec,
        input logic [N-1:0] ptr
    );
        // Try from ptr position, wrap around
        for (int offset = 0; offset < N; offset++) begin
            automatic int idx;
            idx = 0;
            for (int b = 0; b < N; b++) begin
                if (ptr[b]) idx = b;
            end
            idx = (idx + offset) % N;
            if (eligible_vec[idx]) return N'(1 << idx);
        end
        return '0;
    endfunction

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            grant_r      <= '0;
            priority_ptr <= N'(1);
            grant_active <= 1'b0;
            for (int i = 0; i < N; i++) credits[i] <= weight[i];
        end else begin
            if (grant_active && |(grant_r & lock)) begin
                // Burst held: keep grant
            end else begin
                // Decrement credit for previous grant winner (if any)
                if (grant_active) begin
                    for (int i = 0; i < N; i++) begin
                        if (grant_r[i]) begin
                            if (credits[i] > 0)
                                credits[i] <= credits[i] - 1;
                        end
                    end
                end

                // Refill credits if no eligible requestors remain
                if (!|eligible || (grant_active && credits[grant_idx] == 1)) begin
                    for (int i = 0; i < N; i++)
                        credits[i] <= weight[i];
                end

                // Arbitrate among eligible
                if (|eligible) begin
                    grant_r      <= first_eligible(eligible, priority_ptr);
                    grant_active <= 1'b1;
                    // Advance pointer
                    priority_ptr <= {priority_ptr[N-2:0], priority_ptr[N-1]};
                end else begin
                    grant_r      <= '0;
                    grant_active <= 1'b0;
                end
            end
        end
    end

    assign grant       = grant_r;
    assign grant_valid = grant_active && |grant_r;

    always_comb begin
        grant_idx = '0;
        for (int i = 0; i < N; i++)
            if (grant_r[i]) grant_idx = $clog2(N)'(i);
    end

endmodule : weighted_rr_arbiter


// =============================================================================
// Module 3: Priority Arbiter with Starvation Avoidance
// =============================================================================
//
// Normally uses strict priority (QoS level). After a configurable number of
// cycles, a low-priority requestor that has been starved has its effective
// priority escalated to the maximum level (starvation avoidance).
//
module priority_arbiter_no_starve #(
    parameter int N              = 4,
    parameter int STARVE_TIMEOUT = 16   // Cycles before priority escalation
) (
    input  logic              clk,
    input  logic              rst_n,

    input  logic [N-1:0]      req,
    input  logic [N-1:0]      lock,
    input  logic [3:0]        qos [0:N-1],  // QoS per requestor (0-15)

    output logic [N-1:0]      grant,
    output logic [$clog2(N)-1:0] grant_idx,
    output logic              grant_valid
);

    // -------------------------------------------------------------------------
    // Starvation counters: incremented while a requestor is pending but not granted
    // -------------------------------------------------------------------------
    logic [$clog2(STARVE_TIMEOUT+1)-1:0] starve_count [0:N-1];
    logic [3:0]  effective_qos [0:N-1];  // QoS after escalation

    // Escalate QoS when starvation counter reaches threshold
    always_comb begin
        for (int i = 0; i < N; i++) begin
            if (starve_count[i] >= $clog2(STARVE_TIMEOUT+1)'(STARVE_TIMEOUT))
                effective_qos[i] = 4'hF;  // Escalate to maximum
            else
                effective_qos[i] = qos[i];
        end
    end

    // -------------------------------------------------------------------------
    // Priority encode: find highest effective_qos among requesting masters
    // -------------------------------------------------------------------------
    function automatic logic [N-1:0] priority_grant(
        input logic [N-1:0] request,
        input logic [3:0]   eff_qos [0:N-1]
    );
        logic [3:0] best_qos;
        logic [N-1:0] result;
        best_qos = 4'h0;
        result   = '0;
        for (int i = 0; i < N; i++) begin
            if (request[i] && eff_qos[i] >= best_qos) begin
                best_qos = eff_qos[i];
                result   = N'(1 << i);
            end
        end
        return result;
    endfunction

    logic [N-1:0] grant_r;
    logic         grant_active;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            grant_r      <= '0;
            grant_active <= 1'b0;
            for (int i = 0; i < N; i++) starve_count[i] <= '0;
        end else begin
            // Update starvation counters
            for (int i = 0; i < N; i++) begin
                if (req[i] && !grant_r[i]) begin
                    // Pending but not granted: increment counter (saturate at max)
                    if (starve_count[i] < $clog2(STARVE_TIMEOUT+1)'(STARVE_TIMEOUT))
                        starve_count[i] <= starve_count[i] + 1;
                end else if (grant_r[i]) begin
                    // Being served: reset counter
                    starve_count[i] <= '0;
                end
            end

            if (grant_active && |(grant_r & lock)) begin
                // Burst held: keep grant
            end else if (|req) begin
                grant_r      <= priority_grant(req, effective_qos);
                grant_active <= 1'b1;
            end else begin
                grant_r      <= '0;
                grant_active <= 1'b0;
            end
        end
    end

    assign grant       = grant_r;
    assign grant_valid = grant_active && |grant_r;

    always_comb begin
        grant_idx = '0;
        for (int i = 0; i < N; i++)
            if (grant_r[i]) grant_idx = $clog2(N)'(i);
    end

endmodule : priority_arbiter_no_starve


// =============================================================================
// Testbench: All three arbiters
// =============================================================================
module tb_axi_crossbar_arbiter;

    localparam int N           = 4;
    localparam int CLK_PERIOD  = 10;
    localparam int MAX_WEIGHT  = 16;

    // -------------------------------------------------------------------------
    // Clock and reset
    // -------------------------------------------------------------------------
    logic clk   = 1'b0;
    logic rst_n = 1'b0;
    always #(CLK_PERIOD/2) clk = ~clk;

    // -------------------------------------------------------------------------
    // Round-robin arbiter signals
    // -------------------------------------------------------------------------
    logic [N-1:0]        rr_req;
    logic [N-1:0]        rr_lock;
    logic [N-1:0]        rr_grant;
    logic [$clog2(N)-1:0] rr_grant_idx;
    logic                rr_grant_valid;

    round_robin_arbiter #(.N(N)) rr_arb (
        .clk         (clk),
        .rst_n       (rst_n),
        .req         (rr_req),
        .lock        (rr_lock),
        .grant       (rr_grant),
        .grant_idx   (rr_grant_idx),
        .grant_valid (rr_grant_valid)
    );

    // -------------------------------------------------------------------------
    // Weighted round-robin arbiter signals
    // -------------------------------------------------------------------------
    logic [N-1:0]                  wrr_req;
    logic [N-1:0]                  wrr_lock;
    logic [$clog2(MAX_WEIGHT):0]   wrr_weight [0:N-1];
    logic [N-1:0]                  wrr_grant;
    logic [$clog2(N)-1:0]          wrr_grant_idx;
    logic                          wrr_grant_valid;

    weighted_rr_arbiter #(
        .N          (N),
        .MAX_WEIGHT (MAX_WEIGHT)
    ) wrr_arb (
        .clk         (clk),
        .rst_n       (rst_n),
        .req         (wrr_req),
        .lock        (wrr_lock),
        .weight      (wrr_weight),
        .grant       (wrr_grant),
        .grant_idx   (wrr_grant_idx),
        .grant_valid (wrr_grant_valid)
    );

    // -------------------------------------------------------------------------
    // Priority arbiter (no-starve) signals
    // -------------------------------------------------------------------------
    logic [N-1:0]          pa_req;
    logic [N-1:0]          pa_lock;
    logic [3:0]            pa_qos [0:N-1];
    logic [N-1:0]          pa_grant;
    logic [$clog2(N)-1:0]  pa_grant_idx;
    logic                  pa_grant_valid;

    priority_arbiter_no_starve #(
        .N              (N),
        .STARVE_TIMEOUT (8)
    ) pa_arb (
        .clk         (clk),
        .rst_n       (rst_n),
        .req         (pa_req),
        .lock        (pa_lock),
        .qos         (pa_qos),
        .grant       (pa_grant),
        .grant_idx   (pa_grant_idx),
        .grant_valid (pa_grant_valid)
    );

    // -------------------------------------------------------------------------
    // Grant counting for fairness verification
    // -------------------------------------------------------------------------
    int rr_grant_count [0:N-1];   // How many times each master was granted (RR)

    always @(posedge clk) begin
        for (int i = 0; i < N; i++) begin
            if (rr_grant[i] && rr_grant_valid)
                rr_grant_count[i]++;
        end
    end

    // -------------------------------------------------------------------------
    // Stimulus
    // -------------------------------------------------------------------------
    int pass_count, fail_count;
    task check(input string name, input logic cond, input string msg);
        if (cond) begin $display("[PASS] %s", name); pass_count++; end
        else      begin $display("[FAIL] %s: %s", name, msg); fail_count++; end
    endtask

    initial begin
        pass_count = 0; fail_count = 0;
        rr_req  = '0; rr_lock  = '0;
        wrr_req = '0; wrr_lock = '0;
        pa_req  = '0; pa_lock  = '0;

        // Initialise WRR weights: M0=4, M1=2, M2=1, M3=1
        wrr_weight[0] = 4; wrr_weight[1] = 2;
        wrr_weight[2] = 1; wrr_weight[3] = 1;

        // Initialise priority QoS: M0=15, M1=8, M2=4, M3=0
        pa_qos[0] = 4'hF; pa_qos[1] = 4'h8;
        pa_qos[2] = 4'h4; pa_qos[3] = 4'h0;

        // Reset
        rst_n = 1'b0;
        repeat(4) @(posedge clk);
        rst_n = 1'b1;
        @(posedge clk);

        // -----------------------------------------------------------------------
        // Test 1: Round-robin with all 4 requestors active -- verify rotation
        // -----------------------------------------------------------------------
        $display("=== Test 1: Round-Robin -- all 4 requestors ===");
        rr_req = 4'b1111; // All masters requesting
        repeat(16) @(posedge clk);  // Run 16 cycles

        $display("RR grant counts after 16 cycles:");
        for (int i = 0; i < N; i++) begin
            $display("  Master %0d: %0d grants", i, rr_grant_count[i]);
        end
        // Each master should get roughly 4 grants (16/4) in pure round-robin
        check("RR fairness M0", rr_grant_count[0] >= 3 && rr_grant_count[0] <= 5,
              $sformatf("M0 got %0d grants (expected ~4)", rr_grant_count[0]));
        check("RR fairness M1", rr_grant_count[1] >= 3 && rr_grant_count[1] <= 5,
              $sformatf("M1 got %0d grants (expected ~4)", rr_grant_count[1]));
        rr_req = '0;
        repeat(2) @(posedge clk);

        // -----------------------------------------------------------------------
        // Test 2: Round-robin -- burst lock
        // -----------------------------------------------------------------------
        $display("=== Test 2: Burst lock -- M0 holds grant for 3 cycles ===");
        @(posedge clk);
        #1;
        rr_req  = 4'b0011; // M0 and M1 request
        @(posedge clk);    // M0 likely wins (first priority position)
        #1;
        rr_lock = rr_grant; // Lock current winner for burst
        $display("[TB] Grant: %04b (locked)", rr_grant);
        logic [N-1:0] locked_master;
        locked_master = rr_grant;

        repeat(3) @(posedge clk);  // Burst: 3 cycles
        check("Lock held M0", rr_grant == locked_master,
              $sformatf("Grant changed to %04b during lock", rr_grant));
        #1;
        rr_lock = '0; // Release lock
        @(posedge clk);
        check("After lock: M1 gets grant",
              (rr_grant != locked_master) && rr_grant_valid,
              $sformatf("Expected different master, got %04b", rr_grant));
        rr_req = '0;

        // -----------------------------------------------------------------------
        // Test 3: Weighted RR -- verify M0 (weight=4) gets more grants than M3 (weight=1)
        // -----------------------------------------------------------------------
        $display("=== Test 3: Weighted Round-Robin ===");
        int wrr_count [0:N-1];
        for (int i = 0; i < N; i++) wrr_count[i] = 0;

        wrr_req = 4'b1111;
        repeat(32) @(posedge clk) begin
            for (int i = 0; i < N; i++) begin
                if (wrr_grant[i] && wrr_grant_valid) wrr_count[i]++;
            end
        end
        wrr_req = '0;

        $display("WRR grant counts (weights: M0=4, M1=2, M2=1, M3=1):");
        for (int i = 0; i < N; i++)
            $display("  Master %0d: %0d grants", i, wrr_count[i]);

        check("WRR: M0 > M3", wrr_count[0] > wrr_count[3],
              $sformatf("M0=%0d M3=%0d (expected M0 > M3)", wrr_count[0], wrr_count[3]));
        check("WRR: M1 >= M2", wrr_count[1] >= wrr_count[2],
              $sformatf("M1=%0d M2=%0d", wrr_count[1], wrr_count[2]));

        // -----------------------------------------------------------------------
        // Test 4: Priority arbiter -- high QoS master gets preference
        // -----------------------------------------------------------------------
        $display("=== Test 4: Priority Arbiter (QoS: M0=15, M1=8, M2=4, M3=0) ===");
        pa_req = 4'b1111;
        @(posedge clk);
        check("Priority: M0 granted first",
              pa_grant[0] && pa_grant_valid,
              $sformatf("Expected M0 grant, got %04b", pa_grant));

        // -----------------------------------------------------------------------
        // Test 5: Priority arbiter -- starvation avoidance
        // All requests, but M3 (QoS=0) should eventually get a grant via escalation
        // -----------------------------------------------------------------------
        $display("=== Test 5: Starvation avoidance for M3 (QoS=0) ===");
        pa_req  = 4'b1111;
        pa_lock = '0;
        int m3_grant_count;
        m3_grant_count = 0;

        // Run for 20 cycles -- M3 should get at least 1 grant via escalation
        repeat(20) @(posedge clk) begin
            if (pa_grant[3] && pa_grant_valid) m3_grant_count++;
        end
        pa_req = '0;
        $display("M3 received %0d grants in 20 cycles", m3_grant_count);
        check("M3 starvation avoided",
              m3_grant_count >= 1,
              $sformatf("M3 received %0d grants (expected >= 1)", m3_grant_count));

        repeat(5) @(posedge clk);
        $display("=== Results: %0d PASSED, %0d FAILED ===", pass_count, fail_count);
        $finish;
    end

    // -------------------------------------------------------------------------
    // Timeout watchdog
    // -------------------------------------------------------------------------
    initial begin
        #100_000;
        $error("[TB] Timeout");
        $finish;
    end

    // -------------------------------------------------------------------------
    // SVA: At most one grant asserted at a time (mutual exclusion)
    // -------------------------------------------------------------------------
    property rr_mutual_exclusion;
        @(posedge clk) disable iff (!rst_n)
        $onehot0(rr_grant);
    endproperty
    assert property (rr_mutual_exclusion)
        else $error("[SVA] RR arbiter: multiple grants asserted simultaneously");

    property pa_mutual_exclusion;
        @(posedge clk) disable iff (!rst_n)
        $onehot0(pa_grant);
    endproperty
    assert property (pa_mutual_exclusion)
        else $error("[SVA] Priority arbiter: multiple grants asserted simultaneously");

    // SVA: Grant implies there was a request
    property rr_grant_implies_req;
        @(posedge clk) disable iff (!rst_n)
        rr_grant_valid |-> (|(rr_grant & rr_req));
    endproperty
    assert property (rr_grant_implies_req)
        else $error("[SVA] RR grant issued to master with no pending request");

    // SVA: Lock holds grant stable
    property rr_lock_holds_grant;
        @(posedge clk) disable iff (!rst_n)
        (rr_grant_valid && |(rr_grant & rr_lock)) |=> $stable(rr_grant);
    endproperty
    assert property (rr_lock_holds_grant)
        else $error("[SVA] RR grant changed while lock was asserted");

endmodule : tb_axi_crossbar_arbiter

// =============================================================================
// Expected Output (approximate):
//
//   === Test 1: Round-Robin -- all 4 requestors ===
//   RR grant counts after 16 cycles:
//     Master 0: 4 grants
//     Master 1: 4 grants
//     Master 2: 4 grants
//     Master 3: 4 grants
//   [PASS] RR fairness M0
//   [PASS] RR fairness M1
//   === Test 2: Burst lock -- M0 holds grant for 3 cycles ===
//   [TB] Grant: 0001 (locked)
//   [PASS] Lock held M0
//   [PASS] After lock: M1 gets grant
//   === Test 3: Weighted Round-Robin ===
//   WRR grant counts (weights: M0=4, M1=2, M2=1, M3=1):
//     Master 0: 16 grants
//     Master 1: 8 grants
//     Master 2: 4 grants
//     Master 3: 4 grants
//   [PASS] WRR: M0 > M3
//   [PASS] WRR: M1 >= M2
//   === Test 4: Priority Arbiter ===
//   [PASS] Priority: M0 granted first
//   === Test 5: Starvation avoidance for M3 (QoS=0) ===
//   M3 received 1 grants in 20 cycles
//   [PASS] M3 starvation avoided
//   === Results: 8 PASSED, 0 FAILED ===
// =============================================================================
