// =============================================================================
// Challenge 2: AXI4-Stream Width Adapter (Upsizer and Downsizer)
// =============================================================================
//
// Objective:
//   Implement a parameterised AXI4-Stream width adapter that can be configured
//   as either an upsizer (narrow -> wide) or a downsizer (wide -> narrow).
//   The ratio of output to input width must be a power of two.
//
// Upsizer (IN_WIDTH < OUT_WIDTH):
//   - Accumulates N input beats to form one output beat
//   - Handles early TLAST (short packets): partial output beat with correct TKEEP
//   - Propagates TUSER from the first input beat of each packet
//
// Downsizer (IN_WIDTH > OUT_WIDTH):
//   - Splits one input beat into N output beats
//   - Uses input TKEEP to determine the last valid output beat
//   - Asserts TLAST on the output beat corresponding to the last valid input byte
//   - Suppresses output beats for null bytes (TKEEP=0) past the last valid byte
//
// Key protocol rules maintained:
//   - TVALID not deasserted until TREADY (once a beat is presented)
//   - TKEEP correctly computed from input TKEEP on partial final beats
//   - Back-pressure propagated correctly in both directions
//
// Parameters:
//   IN_WIDTH:  Input TDATA width in bits  (must be multiple of 8)
//   OUT_WIDTH: Output TDATA width in bits (must be multiple of 8)
//   USER_WIDTH: TUSER sideband width
//
// When IN_WIDTH == OUT_WIDTH: pass-through (trivial; asserted for completeness)
// When IN_WIDTH  < OUT_WIDTH: upsizer mode (OUT_WIDTH/IN_WIDTH must be power-of-two)
// When IN_WIDTH  > OUT_WIDTH: downsizer mode (IN_WIDTH/OUT_WIDTH must be power-of-two)
//
// =============================================================================

`timescale 1ns/1ps

// =============================================================================
// AXI4-Stream Width Adapter (top-level selector)
// =============================================================================
module axis_width_adapter #(
    parameter int IN_WIDTH   = 32,   // Input data width in bits (multiple of 8)
    parameter int OUT_WIDTH  = 128,  // Output data width in bits (multiple of 8)
    parameter int USER_WIDTH = 1     // TUSER width
) (
    input  logic                     aclk,
    input  logic                     aresetn,

    // Slave (input) side
    input  logic [IN_WIDTH-1:0]      s_tdata,
    input  logic [IN_WIDTH/8-1:0]    s_tkeep,
    input  logic                     s_tlast,
    input  logic [USER_WIDTH-1:0]    s_tuser,
    input  logic                     s_tvalid,
    output logic                     s_tready,

    // Master (output) side
    output logic [OUT_WIDTH-1:0]     m_tdata,
    output logic [OUT_WIDTH/8-1:0]   m_tkeep,
    output logic                     m_tlast,
    output logic [USER_WIDTH-1:0]    m_tuser,
    output logic                     m_tvalid,
    input  logic                     m_tready
);

    // Compile-time ratio check
    localparam int RATIO = (IN_WIDTH < OUT_WIDTH) ? OUT_WIDTH / IN_WIDTH :
                           (IN_WIDTH > OUT_WIDTH) ? IN_WIDTH  / OUT_WIDTH :
                                                    1;

    // -------------------------------------------------------------------------
    // Pass-through: IN_WIDTH == OUT_WIDTH
    // -------------------------------------------------------------------------
    generate
        if (IN_WIDTH == OUT_WIDTH) begin : gen_passthrough
            assign m_tdata  = s_tdata;
            assign m_tkeep  = s_tkeep;
            assign m_tlast  = s_tlast;
            assign m_tuser  = s_tuser;
            assign m_tvalid = s_tvalid;
            assign s_tready = m_tready;

        // -------------------------------------------------------------------------
        // Upsizer: IN_WIDTH < OUT_WIDTH
        // -------------------------------------------------------------------------
        end else if (IN_WIDTH < OUT_WIDTH) begin : gen_upsizer

            // Number of input beats per output beat
            localparam int BEATS = OUT_WIDTH / IN_WIDTH;
            localparam int BEAT_BITS = $clog2(BEATS);

            // Accumulation buffer
            logic [OUT_WIDTH-1:0]   buf_data;
            logic [OUT_WIDTH/8-1:0] buf_keep;
            logic [USER_WIDTH-1:0]  buf_user;   // latched from first input beat
            logic                   buf_last;
            logic [BEAT_BITS:0]     beat_count; // 0 to BEATS-1

            // Output valid: held high until m_tready
            logic output_valid;

            // Accept input when we are filling (not presenting a complete output beat)
            // and (we have space or output was just consumed)
            assign s_tready = !output_valid || (output_valid && m_tready && buf_last);
            // More precisely: accept input when output buffer is not locked waiting for TREADY
            // In this implementation: accept when beat_count < BEATS and not outputting
            // (Simplified: accept whenever we're in FILL state)

            always_ff @(posedge aclk) begin
                if (!aresetn) begin
                    buf_data     <= '0;
                    buf_keep     <= '0;
                    buf_user     <= '0;
                    buf_last     <= 1'b0;
                    beat_count   <= '0;
                    output_valid <= 1'b0;
                    m_tdata      <= '0;
                    m_tkeep      <= '0;
                    m_tuser      <= '0;
                    m_tlast      <= 1'b0;
                    m_tvalid     <= 1'b0;
                end else begin

                    // Output consumed: clear valid
                    if (m_tvalid && m_tready) begin
                        m_tvalid     <= 1'b0;
                        output_valid <= 1'b0;
                    end

                    // Accept input beat when not locked
                    if (s_tvalid && s_tready) begin
                        // Pack input beat into accumulation buffer at the correct position
                        buf_data[beat_count * IN_WIDTH +: IN_WIDTH]   <= s_tdata;
                        buf_keep[beat_count * (IN_WIDTH/8) +: IN_WIDTH/8] <= s_tkeep;

                        if (beat_count == 0)
                            buf_user <= s_tuser; // capture TUSER from first beat only

                        if (s_tlast) begin
                            // Short packet or last beat of full packet
                            buf_last <= 1'b1;
                            // Zero out TKEEP for remaining beats (they are null)
                            for (int i = beat_count + 1; i < BEATS; i++) begin
                                buf_keep[i * (IN_WIDTH/8) +: IN_WIDTH/8] <= '0;
                            end
                            // Present output
                            m_tdata      <= buf_data;
                            m_tkeep      <= buf_keep;
                            m_tlast      <= 1'b1;
                            m_tuser      <= buf_user;
                            m_tvalid     <= 1'b1;
                            output_valid <= 1'b1;
                            beat_count   <= '0;
                        end else if (beat_count == BEATS - 1) begin
                            // Full packet beat reached: present output
                            buf_last <= 1'b0;
                            m_tdata      <= buf_data;
                            m_tkeep      <= {(OUT_WIDTH/8){1'b1}}; // all valid
                            m_tlast      <= 1'b0;
                            m_tuser      <= buf_user;
                            m_tvalid     <= 1'b1;
                            output_valid <= 1'b1;
                            beat_count   <= '0;
                        end else begin
                            beat_count <= beat_count + 1;
                        end
                    end
                end
            end

        // -------------------------------------------------------------------------
        // Downsizer: IN_WIDTH > OUT_WIDTH
        // -------------------------------------------------------------------------
        end else begin : gen_downsizer

            // Number of output beats per input beat
            localparam int BEATS     = IN_WIDTH / OUT_WIDTH;
            localparam int BEAT_BITS = $clog2(BEATS);

            // Registers holding the current input beat being serialized
            logic [IN_WIDTH-1:0]    buf_data;
            logic [IN_WIDTH/8-1:0]  buf_keep;
            logic [USER_WIDTH-1:0]  buf_user;
            logic                   buf_last;
            logic                   buf_valid;

            logic [BEAT_BITS-1:0]   beat_idx;       // current output beat index
            logic [BEAT_BITS-1:0]   last_valid_beat; // index of last beat with TKEEP != 0

            // Compute last valid beat from input TKEEP
            always_comb begin
                last_valid_beat = '0;
                for (int i = 0; i < BEATS; i++) begin
                    if (|buf_keep[i * (OUT_WIDTH/8) +: OUT_WIDTH/8])
                        last_valid_beat = BEAT_BITS'(i);
                end
            end

            // Accept input only when buffer is empty
            assign s_tready = !buf_valid;

            always_ff @(posedge aclk) begin
                if (!aresetn) begin
                    buf_data  <= '0;
                    buf_keep  <= '0;
                    buf_user  <= '0;
                    buf_last  <= 1'b0;
                    buf_valid <= 1'b0;
                    beat_idx  <= '0;
                    m_tvalid  <= 1'b0;
                    m_tdata   <= '0;
                    m_tkeep   <= '0;
                    m_tlast   <= 1'b0;
                    m_tuser   <= '0;
                end else begin

                    // Accept new input beat when buffer is empty
                    if (s_tvalid && s_tready) begin
                        buf_data  <= s_tdata;
                        buf_keep  <= s_tkeep;
                        buf_user  <= s_tuser;
                        buf_last  <= s_tlast;
                        buf_valid <= 1'b1;
                        beat_idx  <= '0;
                    end

                    // Emit output beats from buffer
                    if (buf_valid) begin
                        // Present current beat
                        m_tdata  <= buf_data[beat_idx * OUT_WIDTH +: OUT_WIDTH];
                        m_tkeep  <= buf_keep[beat_idx * (OUT_WIDTH/8) +: OUT_WIDTH/8];
                        m_tuser  <= buf_user;
                        m_tlast  <= buf_last && (beat_idx == last_valid_beat);
                        m_tvalid <= 1'b1;

                        // Advance on downstream acceptance
                        if (m_tvalid && m_tready) begin
                            if (beat_idx == last_valid_beat) begin
                                // Last valid beat emitted -- done with this input beat
                                buf_valid <= 1'b0;
                                m_tvalid  <= 1'b0;
                                beat_idx  <= '0;
                            end else begin
                                beat_idx <= beat_idx + 1;
                            end
                        end
                    end
                end
            end
        end
    endgenerate

endmodule : axis_width_adapter


// =============================================================================
// Testbench: AXI4-Stream Width Adapter
// =============================================================================
//
// Tests:
//   1. Upsizer 32->128: full 4-beat packet, then short 2-beat packet
//   2. Downsizer 128->32: full 4-output-beat packet, then partial (3 valid output beats)
//   3. Back-pressure: downstream stalls mid-packet
//
// =============================================================================
module tb_axis_width_adapter;

    localparam int CLK_PERIOD = 10;

    // -------------------------------------------------------------------------
    // Clk/reset
    // -------------------------------------------------------------------------
    logic aclk    = 1'b0;
    logic aresetn = 1'b0;
    always #(CLK_PERIOD/2) aclk = ~aclk;

    // -------------------------------------------------------------------------
    // Test 1: Upsizer 32 -> 128
    // -------------------------------------------------------------------------
    logic [31:0]   up_s_tdata;
    logic [3:0]    up_s_tkeep;
    logic          up_s_tlast;
    logic          up_s_tuser;
    logic          up_s_tvalid;
    logic          up_s_tready;

    logic [127:0]  up_m_tdata;
    logic [15:0]   up_m_tkeep;
    logic          up_m_tlast;
    logic          up_m_tuser;
    logic          up_m_tvalid;
    logic          up_m_tready;

    axis_width_adapter #(
        .IN_WIDTH   (32),
        .OUT_WIDTH  (128),
        .USER_WIDTH (1)
    ) upsizer (
        .aclk     (aclk),
        .aresetn  (aresetn),
        .s_tdata  (up_s_tdata),
        .s_tkeep  (up_s_tkeep),
        .s_tlast  (up_s_tlast),
        .s_tuser  (up_s_tuser),
        .s_tvalid (up_s_tvalid),
        .s_tready (up_s_tready),
        .m_tdata  (up_m_tdata),
        .m_tkeep  (up_m_tkeep),
        .m_tlast  (up_m_tlast),
        .m_tuser  (up_m_tuser),
        .m_tvalid (up_m_tvalid),
        .m_tready (up_m_tready)
    );

    // -------------------------------------------------------------------------
    // Test 2: Downsizer 128 -> 32
    // -------------------------------------------------------------------------
    logic [127:0]  dn_s_tdata;
    logic [15:0]   dn_s_tkeep;
    logic          dn_s_tlast;
    logic          dn_s_tuser;
    logic          dn_s_tvalid;
    logic          dn_s_tready;

    logic [31:0]   dn_m_tdata;
    logic [3:0]    dn_m_tkeep;
    logic          dn_m_tlast;
    logic          dn_m_tuser;
    logic          dn_m_tvalid;
    logic          dn_m_tready;

    axis_width_adapter #(
        .IN_WIDTH   (128),
        .OUT_WIDTH  (32),
        .USER_WIDTH (1)
    ) downsizer (
        .aclk     (aclk),
        .aresetn  (aresetn),
        .s_tdata  (dn_s_tdata),
        .s_tkeep  (dn_s_tkeep),
        .s_tlast  (dn_s_tlast),
        .s_tuser  (dn_s_tuser),
        .s_tvalid (dn_s_tvalid),
        .s_tready (dn_s_tready),
        .m_tdata  (dn_m_tdata),
        .m_tkeep  (dn_m_tkeep),
        .m_tlast  (dn_m_tlast),
        .m_tuser  (dn_m_tuser),
        .m_tvalid (dn_m_tvalid),
        .m_tready (dn_m_tready)
    );

    // -------------------------------------------------------------------------
    // Initial default values
    // -------------------------------------------------------------------------
    initial begin
        up_s_tdata  = '0; up_s_tkeep = 4'hF; up_s_tlast = 0;
        up_s_tuser  = 0;  up_s_tvalid = 0;
        up_m_tready = 1'b1;

        dn_s_tdata  = '0; dn_s_tkeep = '1; dn_s_tlast = 0;
        dn_s_tuser  = 0;  dn_s_tvalid = 0;
        dn_m_tready = 1'b1;
    end

    // -------------------------------------------------------------------------
    // Task: send one AXI-Stream beat (input side)
    // -------------------------------------------------------------------------
    task automatic axis_send_32 (
        input logic [31:0] data,
        input logic [3:0]  keep,
        input logic        last,
        input logic        user,
        ref   logic [31:0] s_tdata,
        ref   logic [3:0]  s_tkeep,
        ref   logic        s_tlast,
        ref   logic        s_tuser,
        ref   logic        s_tvalid,
        input logic        s_tready_sig
    );
        @(posedge aclk);
        #1;
        s_tdata  <= data;
        s_tkeep  <= keep;
        s_tlast  <= last;
        s_tuser  <= user;
        s_tvalid <= 1'b1;
        // Wait for acceptance
        do @(posedge aclk); while (!s_tready_sig);
        #1;
        s_tvalid <= 1'b0;
    endtask

    // -------------------------------------------------------------------------
    // Upsizer receive monitor
    // -------------------------------------------------------------------------
    always @(posedge aclk) begin
        if (up_m_tvalid && up_m_tready) begin
            $display("[UPSIZER OUT] data=0x%032h keep=0x%04h last=%b user=%b",
                     up_m_tdata, up_m_tkeep, up_m_tlast, up_m_tuser);
        end
    end

    // Downsizer receive monitor
    always @(posedge aclk) begin
        if (dn_m_tvalid && dn_m_tready) begin
            $display("[DOWNSIZER OUT] data=0x%08h keep=0x%01h last=%b user=%b",
                     dn_m_tdata, dn_m_tkeep, dn_m_tlast, dn_m_tuser);
        end
    end

    // -------------------------------------------------------------------------
    // Main stimulus
    // -------------------------------------------------------------------------
    initial begin
        // Reset
        aresetn = 1'b0;
        repeat(4) @(posedge aclk);
        aresetn = 1'b1;
        repeat(2) @(posedge aclk);

        // -----------------------------------------------------------------------
        // Upsizer test 1: Full 4-beat packet (32->128)
        // Input: [0xAABBCCDD, 0x11223344, 0x55667788, 0x99AABBCC], all TKEEP=1111
        // Expected output: one 128-bit beat, TKEEP=all-1, TLAST=1
        // -----------------------------------------------------------------------
        $display("=== Upsizer: Full 4-beat packet ===");
        axis_send_32(32'hAABBCCDD, 4'hF, 1'b0, 1'b1, up_s_tdata, up_s_tkeep, up_s_tlast, up_s_tuser, up_s_tvalid, up_s_tready);
        axis_send_32(32'h11223344, 4'hF, 1'b0, 1'b0, up_s_tdata, up_s_tkeep, up_s_tlast, up_s_tuser, up_s_tvalid, up_s_tready);
        axis_send_32(32'h55667788, 4'hF, 1'b0, 1'b0, up_s_tdata, up_s_tkeep, up_s_tlast, up_s_tuser, up_s_tvalid, up_s_tready);
        axis_send_32(32'h99AABBCC, 4'hF, 1'b1, 1'b0, up_s_tdata, up_s_tkeep, up_s_tlast, up_s_tuser, up_s_tvalid, up_s_tready);
        repeat(2) @(posedge aclk);

        // -----------------------------------------------------------------------
        // Upsizer test 2: Short 2-beat packet (32->128, TLAST on beat 1)
        // Expected output: one 128-bit beat with TKEEP=0000_0000_1111_1111 (8 valid bytes)
        // -----------------------------------------------------------------------
        $display("=== Upsizer: Short 2-beat packet ===");
        axis_send_32(32'hDEAD_0001, 4'hF, 1'b0, 1'b1, up_s_tdata, up_s_tkeep, up_s_tlast, up_s_tuser, up_s_tvalid, up_s_tready);
        axis_send_32(32'hDEAD_0002, 4'hF, 1'b1, 1'b0, up_s_tdata, up_s_tkeep, up_s_tlast, up_s_tuser, up_s_tvalid, up_s_tready);
        repeat(2) @(posedge aclk);

        // -----------------------------------------------------------------------
        // Downsizer test 1: Full 128-bit packet -> 4 x 32-bit output beats
        // -----------------------------------------------------------------------
        $display("=== Downsizer: Full 128-bit packet ===");
        @(posedge aclk);
        #1;
        dn_s_tdata  <= 128'h99AABBCC_55667788_11223344_AABBCCDD;
        dn_s_tkeep  <= 16'hFFFF;   // all 16 bytes valid
        dn_s_tlast  <= 1'b1;
        dn_s_tuser  <= 1'b0;
        dn_s_tvalid <= 1'b1;
        do @(posedge aclk); while (!dn_s_tready);
        #1; dn_s_tvalid <= 1'b0;
        repeat(6) @(posedge aclk);

        // -----------------------------------------------------------------------
        // Downsizer test 2: Partial 128-bit packet (10 valid bytes -> 3 output beats)
        // TKEEP = 16'h03FF (bytes 0-9 valid, bytes 10-15 null)
        // Expected: 3 full output beats (beat 0 full, beat 1 full, beat 2 partial)
        //           TLAST on beat 2 (beat index 2 = bytes 8-11, last byte index 9)
        // -----------------------------------------------------------------------
        $display("=== Downsizer: Partial packet (10 valid bytes) ===");
        @(posedge aclk);
        #1;
        dn_s_tdata  <= 128'h0;
        dn_s_tkeep  <= 16'h03FF;  // bytes 0-9 valid (10 bytes)
        dn_s_tlast  <= 1'b1;
        dn_s_tuser  <= 1'b1;
        dn_s_tvalid <= 1'b1;
        do @(posedge aclk); while (!dn_s_tready);
        #1; dn_s_tvalid <= 1'b0;
        repeat(6) @(posedge aclk);

        // -----------------------------------------------------------------------
        // Back-pressure test: upsizer with downstream stall mid-output
        // -----------------------------------------------------------------------
        $display("=== Upsizer: Back-pressure test ===");
        up_m_tready = 1'b0; // Stall downstream
        axis_send_32(32'hFACE_0001, 4'hF, 1'b0, 1'b0, up_s_tdata, up_s_tkeep, up_s_tlast, up_s_tuser, up_s_tvalid, up_s_tready);
        axis_send_32(32'hFACE_0002, 4'hF, 1'b0, 1'b0, up_s_tdata, up_s_tkeep, up_s_tlast, up_s_tuser, up_s_tvalid, up_s_tready);
        axis_send_32(32'hFACE_0003, 4'hF, 1'b0, 1'b0, up_s_tdata, up_s_tkeep, up_s_tlast, up_s_tuser, up_s_tvalid, up_s_tready);
        axis_send_32(32'hFACE_0004, 4'hF, 1'b1, 1'b0, up_s_tdata, up_s_tkeep, up_s_tlast, up_s_tuser, up_s_tvalid, up_s_tready);
        $display("[TB] Upstream fills complete; output stalled. Releasing TREADY in 3 cycles.");
        repeat(3) @(posedge aclk);
        #1; up_m_tready = 1'b1; // Release back-pressure
        repeat(3) @(posedge aclk);

        $display("=== Simulation complete ===");
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
    // SVA: TVALID stability on upsizer output
    // -------------------------------------------------------------------------
    property up_m_tvalid_stable;
        @(posedge aclk) disable iff (!aresetn)
        (up_m_tvalid && !up_m_tready) |=> up_m_tvalid;
    endproperty
    assert property (up_m_tvalid_stable)
        else $error("[SVA] Upsizer output TVALID deasserted before TREADY");

    // SVA: Downsizer output TVALID stability
    property dn_m_tvalid_stable;
        @(posedge aclk) disable iff (!aresetn)
        (dn_m_tvalid && !dn_m_tready) |=> dn_m_tvalid;
    endproperty
    assert property (dn_m_tvalid_stable)
        else $error("[SVA] Downsizer output TVALID deasserted before TREADY");

endmodule : tb_axis_width_adapter

// =============================================================================
// Expected Output (approximate -- exact data values depend on byte ordering):
//
//   === Upsizer: Full 4-beat packet ===
//   [UPSIZER OUT] data=0x99aabbcc556677881122334400aabbccdd keep=0xffff last=1 user=1
//
//   === Upsizer: Short 2-beat packet ===
//   [UPSIZER OUT] data=0x00000000000000000dead0002dead0001 keep=0x00ff last=1 user=1
//
//   === Downsizer: Full 128-bit packet ===
//   [DOWNSIZER OUT] data=0xaabbccdd keep=0xf last=0 user=0
//   [DOWNSIZER OUT] data=0x11223344 keep=0xf last=0 user=0
//   [DOWNSIZER OUT] data=0x55667788 keep=0xf last=0 user=0
//   [DOWNSIZER OUT] data=0x99aabbcc keep=0xf last=1 user=0
//
//   === Downsizer: Partial packet (10 valid bytes) ===
//   [DOWNSIZER OUT] data=0x...      keep=0xf last=0 user=1  (beat 0, bytes 0-3)
//   [DOWNSIZER OUT] data=0x...      keep=0xf last=0 user=1  (beat 1, bytes 4-7)
//   [DOWNSIZER OUT] data=0x...      keep=0x3 last=1 user=1  (beat 2, bytes 8-9)
//
//   === Upsizer: Back-pressure test ===
//   [TB] Upstream fills complete; output stalled. Releasing TREADY in 3 cycles.
//   [UPSIZER OUT] data=0x...  keep=0xffff last=1 user=0
//   === Simulation complete ===
// =============================================================================
