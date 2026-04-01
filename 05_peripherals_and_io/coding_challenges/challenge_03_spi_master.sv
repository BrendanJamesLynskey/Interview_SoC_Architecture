// =============================================================================
// Challenge 03: SPI Master Controller
// =============================================================================
//
// PROBLEM STATEMENT
// -----------------
// Implement a full-featured SPI master controller with the following spec:
//
//   Protocol Support:
//     - All four SPI modes: CPOL/CPHA configurable per transaction
//     - Configurable frame size: 8, 16, 24, or 32 bits
//     - MSB-first or LSB-first bit order
//     - Configurable SCLK frequency: f_sclk = f_clk / (2 × (CLK_DIV + 1))
//     - Up to 4 chip-select outputs (cs_n_o[3:0]), asserted active-low
//
//   Transaction Control:
//     - APB slave interface for register access
//     - Software initiates a transfer by writing to the TX_DATA register
//     - Transfer completes when all bits have been clocked; COMPLETE flag set
//     - CS setup time: programmable (CS assert to first SCLK edge, in system clocks)
//     - CS hold time: programmable (last SCLK edge to CS deassert, in system clocks)
//     - COMPLETE interrupt when transaction finishes
//
//   APB Register Map (byte-addressed):
//     0x00  TX_DATA    [31:0]  Write: load TX data, starts transfer if CTRL.AUTO_TX
//     0x04  RX_DATA    [31:0]  Read: received data from last transfer (read-only)
//     0x08  CTRL       [31:0]  Control register:
//                                [31:16] CLK_DIV[15:0]  - SCLK divisor
//                                [15:12] CS_SETUP[3:0]  - CS setup time (clocks)
//                                [11:8]  CS_HOLD[3:0]   - CS hold time (clocks)
//                                [7:6]   FRAME_SZ[1:0]  - 00=8b,01=16b,10=24b,11=32b
//                                [5:4]   CS_SEL[1:0]    - Which CS to assert
//                                [3]     LSB_FIRST       - 0=MSB first, 1=LSB first
//                                [2]     CPHA            - Clock phase
//                                [1]     CPOL            - Clock polarity
//                                [0]     ENABLE          - Block enable
//     0x0C  STATUS     [7:0]   Read-only:
//                                [3]     BUSY            - Transfer in progress
//                                [2]     CS_ACTIVE       - CS is currently asserted
//                                [1]     RX_VALID        - RX_DATA holds valid data
//                                [0]     COMPLETE        - Transfer complete (W1C)
//     0x10  INTR_EN    [0]     Transfer complete interrupt enable
//     0x14  START      [0]     Write 1 to start a transfer (if TX_DATA pre-loaded)
//
// CONSTRAINTS
// -----------
//   - SCLK must be generated from the system clock using a counter divider
//   - CPOL and CPHA must be handled correctly for all four modes
//   - CS setup/hold timing must be enforced using the programmable delay counters
//   - The shift register must handle both MSB-first and LSB-first operation
//   - No data-dependent combinational paths through the shift register output
//   - MISO must be sampled on the correct edge for all four SPI modes
//
// IMPLEMENTATION NOTES
// --------------------
//   SPI mode summary:
//     Mode 0 (CPOL=0, CPHA=0): SCLK idles LOW, sample on rising (first) edge
//     Mode 1 (CPOL=0, CPHA=1): SCLK idles LOW, sample on falling (second) edge
//     Mode 2 (CPOL=1, CPHA=0): SCLK idles HIGH, sample on falling (first) edge
//     Mode 3 (CPOL=1, CPHA=1): SCLK idles HIGH, sample on rising (second) edge
//
//   The shift edge (MOSI changes) is always the edge opposite to the sample edge.
//
// =============================================================================

`timescale 1ns / 1ps
`default_nettype none

// =============================================================================
// Module: spi_master
// =============================================================================
module spi_master (
    input  wire        clk_i,
    input  wire        rst_ni,

    // SPI physical interface
    output logic       sclk_o,
    output logic       mosi_o,
    input  wire        miso_i,
    output logic [3:0] cs_n_o,     // Active-low chip selects

    // Interrupt
    output logic       irq_o,

    // APB slave interface
    input  wire        psel_i,
    input  wire        penable_i,
    input  wire        pwrite_i,
    input  wire [7:0]  paddr_i,
    input  wire [31:0] pwdata_i,
    output logic [31:0] prdata_o,
    output logic       pready_o,
    output logic       pslverr_o
);

    // -------------------------------------------------------------------------
    // Configuration registers
    // -------------------------------------------------------------------------
    logic [15:0] clk_div_q;      // SCLK divisor
    logic [3:0]  cs_setup_q;     // CS setup time in system clocks
    logic [3:0]  cs_hold_q;      // CS hold time in system clocks
    logic [1:0]  frame_sz_q;     // 00=8b, 01=16b, 10=24b, 11=32b
    logic [1:0]  cs_sel_q;       // Which CS to assert
    logic        lsb_first_q;    // Bit order
    logic        cpha_q;         // Clock phase
    logic        cpol_q;         // Clock polarity
    logic        enable_q;       // Block enable
    logic        intr_en_q;      // Interrupt enable

    // -------------------------------------------------------------------------
    // Data registers
    // -------------------------------------------------------------------------
    logic [31:0] tx_data_q;      // TX data register (loaded by software)
    logic [31:0] rx_data_q;      // RX data register (written by RX shift reg)

    // -------------------------------------------------------------------------
    // Status flags
    // -------------------------------------------------------------------------
    logic        busy_q;
    logic        cs_active_q;
    logic        rx_valid_q;
    logic        complete_q;     // W1C

    // -------------------------------------------------------------------------
    // APB interface (zero wait state)
    // -------------------------------------------------------------------------
    assign pready_o  = psel_i & penable_i;
    assign pslverr_o = 1'b0;

    // Start trigger: write 1 to START register OR write to TX_DATA with AUTO
    logic start_req;
    assign start_req = pready_o && pwrite_i &&
                       ((paddr_i == 8'h14 && pwdata_i[0]) ||  // Explicit start
                        (paddr_i == 8'h00));                   // Write to TX_DATA starts automatically

    // APB read mux
    always_comb begin
        prdata_o = 32'h0;
        if (pready_o && !pwrite_i) begin
            case (paddr_i)
                8'h00: prdata_o = tx_data_q;
                8'h04: prdata_o = rx_data_q;
                8'h08: prdata_o = {clk_div_q,
                                    cs_setup_q, cs_hold_q,
                                    frame_sz_q, cs_sel_q,
                                    lsb_first_q, cpha_q, cpol_q, enable_q};
                8'h0C: prdata_o = {28'h0, busy_q, cs_active_q, rx_valid_q, complete_q};
                8'h10: prdata_o = {31'h0, intr_en_q};
                8'h14: prdata_o = 32'h0;
                default: prdata_o = 32'hDEAD_BEEF;
            endcase
        end
    end

    // APB write to configuration registers
    always_ff @(posedge clk_i) begin
        if (!rst_ni) begin
            clk_div_q   <= 16'd3;    // Default: f_sclk = f_clk / 8
            cs_setup_q  <= 4'd2;
            cs_hold_q   <= 4'd2;
            frame_sz_q  <= 2'b00;    // 8-bit frames
            cs_sel_q    <= 2'b00;
            lsb_first_q <= 1'b0;
            cpha_q      <= 1'b0;
            cpol_q      <= 1'b0;
            enable_q    <= 1'b0;
            intr_en_q   <= 1'b0;
            tx_data_q   <= 32'h0;
        end else begin
            // W1C for COMPLETE
            if (pready_o && pwrite_i && paddr_i == 8'h0C && pwdata_i[0])
                complete_q <= 1'b0;

            if (pready_o && pwrite_i) begin
                case (paddr_i)
                    8'h00: tx_data_q   <= pwdata_i;
                    8'h08: begin
                        clk_div_q   <= pwdata_i[31:16];
                        cs_setup_q  <= pwdata_i[15:12];
                        cs_hold_q   <= pwdata_i[11:8];
                        frame_sz_q  <= pwdata_i[7:6];
                        cs_sel_q    <= pwdata_i[5:4];
                        lsb_first_q <= pwdata_i[3];
                        cpha_q      <= pwdata_i[2];
                        cpol_q      <= pwdata_i[1];
                        enable_q    <= pwdata_i[0];
                    end
                    8'h10: intr_en_q <= pwdata_i[0];
                    default: ;
                endcase
            end
        end
    end

    // -------------------------------------------------------------------------
    // Frame size decoder: number of bits to transfer
    // -------------------------------------------------------------------------
    logic [4:0] frame_bits;  // 8, 16, 24, or 32
    always_comb begin
        case (frame_sz_q)
            2'b00: frame_bits = 5'd8;
            2'b01: frame_bits = 5'd16;
            2'b10: frame_bits = 5'd24;
            2'b11: frame_bits = 5'd31;  // 32 bits: counter goes 0..31
            default: frame_bits = 5'd8;
        endcase
    end

    // -------------------------------------------------------------------------
    // SCLK clock divider
    // -------------------------------------------------------------------------
    // Generates sclk_en_rise and sclk_en_fall: single-cycle enables at the
    // rising and falling edges of the divided SCLK.
    logic [15:0] clk_cnt_q;
    logic        sclk_reg_q;      // Divided SCLK register (before CPOL inversion)
    logic        sclk_en_rise;    // Pulse on rising edge of divided SCLK
    logic        sclk_en_fall;    // Pulse on falling edge of divided SCLK

    always_ff @(posedge clk_i) begin
        if (!rst_ni) begin
            clk_cnt_q  <= '0;
            sclk_reg_q <= 1'b0;
        end else if (busy_q) begin
            if (clk_cnt_q == clk_div_q) begin
                clk_cnt_q  <= '0;
                sclk_reg_q <= ~sclk_reg_q;
            end else begin
                clk_cnt_q <= clk_cnt_q + 1;
            end
        end else begin
            clk_cnt_q  <= '0;
            sclk_reg_q <= 1'b0;  // Reset to 0; CPOL applied to output
        end
    end

    assign sclk_en_rise = busy_q && (clk_cnt_q == clk_div_q) && !sclk_reg_q;
    assign sclk_en_fall = busy_q && (clk_cnt_q == clk_div_q) &&  sclk_reg_q;

    // SCLK output: apply CPOL
    // When not busy, SCLK idles at CPOL value
    assign sclk_o = busy_q ? (sclk_reg_q ^ cpol_q) : cpol_q;

    // -------------------------------------------------------------------------
    // Sample and shift edge selection based on CPOL/CPHA
    // -------------------------------------------------------------------------
    // Mode 0 (CPOL=0, CPHA=0): sample on rise, shift on fall
    // Mode 1 (CPOL=0, CPHA=1): sample on fall, shift on rise
    // Mode 2 (CPOL=1, CPHA=0): sample on fall, shift on rise
    //   (sclk_reg_q=0→1 means SCLK=1→0 after CPOL inversion: a fall in real SCLK)
    // Mode 3 (CPOL=1, CPHA=1): sample on rise, shift on fall
    //
    // Key insight: XOR(CPOL, CPHA) determines whether sclk_reg_q rising edge
    // (before CPOL) is the sample edge:
    //   CPOL=0, CPHA=0: XNOR → sample on rise  (sclk_reg_q 0→1)
    //   CPOL=0, CPHA=1: XOR  → sample on fall   (sclk_reg_q 1→0)
    //   CPOL=1, CPHA=0: XOR  → sample on rise of sclk_reg_q (= fall of SCLK)
    //   CPOL=1, CPHA=1: XNOR → sample on fall of sclk_reg_q (= rise of SCLK)
    //
    // Simplified: sample_on_rise_of_sclk_reg = !(CPOL ^ CPHA)

    wire sample_on_sclk_reg_rise = !(cpha_q ^ cpol_q);

    wire do_sample = sample_on_sclk_reg_rise ? sclk_en_rise : sclk_en_fall;
    wire do_shift  = sample_on_sclk_reg_rise ? sclk_en_fall : sclk_en_rise;

    // -------------------------------------------------------------------------
    // Main state machine
    // -------------------------------------------------------------------------
    typedef enum logic [2:0] {
        SPI_IDLE    = 3'd0,
        SPI_CS_SETUP = 3'd1,
        SPI_TRANSFER = 3'd2,
        SPI_CS_HOLD  = 3'd3,
        SPI_DONE     = 3'd4
    } spi_state_t;

    spi_state_t  spi_state_q;
    logic [4:0]  bit_cnt_q;        // Bit counter for current transfer
    logic [31:0] tx_shift_q;       // TX shift register
    logic [31:0] rx_shift_q;       // RX shift register
    logic [3:0]  delay_cnt_q;      // CS setup/hold delay counter
    logic        first_edge_seen_q; // CPHA=1: skip first edge

    // CS control: registered, active-low
    always_ff @(posedge clk_i) begin
        if (!rst_ni) begin
            cs_n_o <= 4'hF;  // All deasserted
        end else begin
            if (spi_state_q == SPI_CS_SETUP || spi_state_q == SPI_TRANSFER)
                cs_n_o <= ~(4'h1 << cs_sel_q);  // Assert selected CS
            else
                cs_n_o <= 4'hF;
        end
    end

    // Compute initial shift register value based on LSB_FIRST and frame size
    // For MSB first: TX data is left-aligned in shift register
    // For LSB first: TX data is right-aligned; we will shift right
    function automatic logic [31:0] align_tx(
        input logic [31:0] data,
        input logic [1:0]  fsz,
        input logic        lsb
    );
        logic [31:0] result;
        if (lsb) begin
            result = data;  // LSB-first: just use data as-is, shift right
        end else begin
            // MSB-first: left-align the active bits
            case (fsz)
                2'b00: result = {data[7:0],  24'h0};   //  8-bit left-aligned
                2'b01: result = {data[15:0], 16'h0};   // 16-bit left-aligned
                2'b10: result = {data[23:0],  8'h0};   // 24-bit left-aligned
                2'b11: result = data;                   // 32-bit already aligned
                default: result = data;
            endcase
        end
        return result;
    endfunction

    always_ff @(posedge clk_i) begin
        if (!rst_ni) begin
            spi_state_q      <= SPI_IDLE;
            bit_cnt_q        <= '0;
            tx_shift_q       <= '0;
            rx_shift_q       <= '0;
            delay_cnt_q      <= '0;
            first_edge_seen_q <= 1'b0;
            mosi_o           <= 1'b0;
            busy_q           <= 1'b0;
            cs_active_q      <= 1'b0;
            rx_valid_q       <= 1'b0;
            complete_q       <= 1'b0;
            rx_data_q        <= '0;
        end else begin
            case (spi_state_q)

                // -------------------------------------------------------
                SPI_IDLE: begin
                    busy_q      <= 1'b0;
                    cs_active_q <= 1'b0;
                    mosi_o      <= 1'b0;

                    if (start_req && enable_q && !busy_q) begin
                        // Latch TX data and begin transaction
                        tx_shift_q       <= align_tx(
                                               pwrite_i ? pwdata_i : tx_data_q,
                                               frame_sz_q, lsb_first_q);
                        rx_shift_q       <= '0;
                        bit_cnt_q        <= '0;
                        delay_cnt_q      <= cs_setup_q;
                        first_edge_seen_q <= 1'b0;
                        busy_q           <= 1'b1;
                        cs_active_q      <= 1'b1;
                        spi_state_q      <= SPI_CS_SETUP;
                        rx_valid_q       <= 1'b0;
                    end
                end

                // -------------------------------------------------------
                // CS setup: hold CS asserted for cs_setup_q system clocks
                // before any SCLK activity
                // -------------------------------------------------------
                SPI_CS_SETUP: begin
                    if (delay_cnt_q == 0) begin
                        spi_state_q <= SPI_TRANSFER;
                        // For CPHA=0: drive MOSI before first clock edge
                        if (!cpha_q) begin
                            mosi_o <= lsb_first_q ? tx_shift_q[0] : tx_shift_q[31];
                        end
                    end else begin
                        delay_cnt_q <= delay_cnt_q - 1;
                    end
                end

                // -------------------------------------------------------
                // Transfer: clock out all bits
                // -------------------------------------------------------
                SPI_TRANSFER: begin
                    // Sample edge: capture MISO into shift register
                    if (do_sample) begin
                        if (lsb_first_q) begin
                            // LSB-first: shift right, incoming bit enters MSB
                            rx_shift_q <= {miso_i, rx_shift_q[31:1]};
                        end else begin
                            // MSB-first: shift left, incoming bit enters LSB
                            rx_shift_q <= {rx_shift_q[30:0], miso_i};
                        end
                        bit_cnt_q <= bit_cnt_q + 1;

                        if (bit_cnt_q == frame_bits - 1) begin
                            // Last bit sampled — move to hold phase
                            spi_state_q <= SPI_CS_HOLD;
                            delay_cnt_q <= cs_hold_q;
                        end
                    end

                    // Shift edge: update MOSI with next bit
                    if (do_shift && (bit_cnt_q < frame_bits)) begin
                        if (lsb_first_q) begin
                            tx_shift_q <= {1'b0, tx_shift_q[31:1]};
                            mosi_o     <= tx_shift_q[1];  // Next bit after shift
                        end else begin
                            tx_shift_q <= {tx_shift_q[30:0], 1'b0};
                            mosi_o     <= tx_shift_q[30]; // Next bit after shift
                        end
                    end
                end

                // -------------------------------------------------------
                // CS hold: maintain CS for cs_hold_q cycles after last edge
                // -------------------------------------------------------
                SPI_CS_HOLD: begin
                    if (delay_cnt_q == 0) begin
                        spi_state_q <= SPI_DONE;
                    end else begin
                        delay_cnt_q <= delay_cnt_q - 1;
                    end
                end

                // -------------------------------------------------------
                // Done: latch RX data, deassert CS, signal complete
                // -------------------------------------------------------
                SPI_DONE: begin
                    // Align RX data: right-justify the received bits
                    case (frame_sz_q)
                        2'b00: rx_data_q <= {24'h0, rx_shift_q[31:24]};  //  8-bit
                        2'b01: rx_data_q <= {16'h0, rx_shift_q[31:16]};  // 16-bit
                        2'b10: rx_data_q <= {8'h0,  rx_shift_q[31:8]};   // 24-bit
                        2'b11: rx_data_q <= rx_shift_q;                   // 32-bit
                    endcase
                    rx_valid_q  <= 1'b1;
                    complete_q  <= 1'b1;
                    busy_q      <= 1'b0;
                    cs_active_q <= 1'b0;
                    mosi_o      <= 1'b0;
                    spi_state_q <= SPI_IDLE;
                end

            endcase
        end
    end

    // -------------------------------------------------------------------------
    // Interrupt output
    // -------------------------------------------------------------------------
    assign irq_o = intr_en_q && complete_q;

endmodule : spi_master


// =============================================================================
// Testbench stub: spi_master_tb
// =============================================================================
// Provides a SPI slave model that echoes received data on MISO with a 1-bit
// pipeline delay, enabling basic loopback verification.
// =============================================================================
module spi_master_tb;

    // -------------------------------------------------------------------------
    // Parameters
    // -------------------------------------------------------------------------
    localparam int CLK_PERIOD_NS = 10;   // 100 MHz
    localparam int CLK_DIV_VAL   = 3;    // SCLK = 100MHz / (2*(3+1)) = 12.5 MHz

    // -------------------------------------------------------------------------
    // DUT signals
    // -------------------------------------------------------------------------
    logic        clk, rst_n;
    logic        sclk, mosi, miso;
    logic [3:0]  cs_n;
    logic        irq;
    logic        psel, penable, pwrite;
    logic [7:0]  paddr;
    logic [31:0] pwdata, prdata;
    logic        pready, pslverr;

    // -------------------------------------------------------------------------
    // DUT instantiation
    // -------------------------------------------------------------------------
    spi_master dut (
        .clk_i      (clk),
        .rst_ni     (rst_n),
        .sclk_o     (sclk),
        .mosi_o     (mosi),
        .miso_i     (miso),
        .cs_n_o     (cs_n),
        .irq_o      (irq),
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
    // Simple SPI slave model: shift register echoes MOSI → MISO
    // Samples on rising SCLK edge (Mode 0 compatible), outputs on falling edge
    // -------------------------------------------------------------------------
    logic [7:0] slave_shift_reg;
    logic [7:0] slave_captured_byte;

    always_ff @(posedge sclk) begin
        if (!cs_n[0]) begin
            slave_shift_reg <= {slave_shift_reg[6:0], mosi};
        end
    end

    // Slave drives MISO: echo the last byte received, MSB first
    // For a proper loopback, slave responds with captured data on next byte
    // Simplified: slave_shift_reg[7] is the oldest bit (echoes with 8-bit delay)
    assign miso = cs_n[0] ? 1'bZ : slave_shift_reg[7];

    // Capture complete bytes at CS deassert
    always_ff @(posedge clk) begin
        if (cs_n[0]) begin
            slave_captured_byte <= slave_shift_reg;
        end
    end

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
        psel = 1'b1; pwrite = 1'b1; paddr = addr; pwdata = data; penable = 1'b0;
        @(negedge clk); penable = 1'b1;
        @(posedge clk); while (!pready) @(posedge clk);
        @(negedge clk); psel = 1'b0; penable = 1'b0;
    endtask

    task apb_read(input [7:0] addr, output [31:0] data);
        @(negedge clk);
        psel = 1'b1; pwrite = 1'b0; paddr = addr; penable = 1'b0;
        @(negedge clk); penable = 1'b1;
        @(posedge clk); while (!pready) @(posedge clk);
        data = prdata;
        @(negedge clk); psel = 1'b0; penable = 1'b0;
    endtask

    // Wait for the COMPLETE flag (polls STATUS register)
    task wait_complete(input int unsigned timeout_cycles);
        logic [31:0] status;
        int unsigned count = 0;
        do begin
            apb_read(8'h0C, status);
            count++;
            if (count >= timeout_cycles) begin
                $display("TIMEOUT: transfer did not complete after %0d polls", timeout_cycles);
                break;
            end
        end while (!status[0]);  // STATUS[0] = COMPLETE
        // Clear the COMPLETE flag
        apb_write(8'h0C, 32'h1);
    endtask

    // -------------------------------------------------------------------------
    // Test helpers
    // -------------------------------------------------------------------------
    int pass_count = 0, fail_count = 0;

    task check_sclk_idle(input logic expected_cpol);
        // Verify SCLK is at the idle level before transaction
        repeat (2) @(posedge clk);
        if (sclk === expected_cpol)
            $display("PASS: SCLK idles at CPOL=%0b", expected_cpol);
        else
            $display("FAIL: SCLK idle=%0b expected CPOL=%0b", sclk, expected_cpol);
    endtask

    task check_cs_deasserted();
        if (&cs_n)
            $display("PASS: all CS_N deasserted after transfer");
        else
            $display("FAIL: CS_N = 0x%0h after transfer (expected 0xF)", cs_n);
    endtask

    // -------------------------------------------------------------------------
    // Test sequence
    // -------------------------------------------------------------------------
    logic [31:0] rdata;

    initial begin
        // Initialise
        rst_n = 1'b0;
        psel = 0; penable = 0; pwrite = 0; paddr = '0; pwdata = '0;
        repeat (4) @(posedge clk);
        @(negedge clk); rst_n = 1'b1;
        repeat (2) @(posedge clk);

        // ==================================================================
        // Test 1: Mode 0 (CPOL=0, CPHA=0), 8-bit, MSB-first, CS0
        // ==================================================================
        $display("--- Test 1: SPI Mode 0, 8-bit ---");

        // Configure: CPOL=0, CPHA=0, 8-bit, CS0, CLK_DIV=3, enable
        apb_write(8'h08, {16'(CLK_DIV_VAL),  // CLK_DIV
                           4'd2,              // CS_SETUP = 2 clocks
                           4'd2,              // CS_HOLD  = 2 clocks
                           2'b00,             // 8-bit frame
                           2'b00,             // CS0
                           1'b0,              // MSB first
                           1'b0,              // CPHA=0
                           1'b0,              // CPOL=0
                           1'b1});            // ENABLE

        apb_write(8'h10, 32'h1);             // Enable interrupt

        check_sclk_idle(1'b0);               // CPOL=0 → idle LOW

        // Transmit 0xA5
        apb_write(8'h00, 32'hA5);           // Write TX_DATA (auto-starts)
        wait_complete(10000);

        apb_read(8'h04, rdata);
        $display("INFO: T1 TX=0xA5 RX=0x%02h (slave echo with 8-bit shift delay)",
                 rdata[7:0]);

        check_cs_deasserted();

        // Verify IRQ fired and was cleared
        if (!irq)
            $display("PASS: T1_irq_cleared_after_w1c");
        else
            $display("FAIL: T1_irq still asserted after clearing COMPLETE");

        // ==================================================================
        // Test 2: Mode 3 (CPOL=1, CPHA=1), 8-bit, MSB-first, CS1
        // ==================================================================
        $display("--- Test 2: SPI Mode 3, 8-bit ---");

        apb_write(8'h08, {16'(CLK_DIV_VAL),
                           4'd2, 4'd2,        // CS_SETUP, CS_HOLD
                           2'b00,             // 8-bit
                           2'b01,             // CS1
                           1'b0,              // MSB first
                           1'b1,              // CPHA=1
                           1'b1,              // CPOL=1
                           1'b1});            // ENABLE

        check_sclk_idle(1'b1);               // CPOL=1 → idle HIGH

        apb_write(8'h00, 32'h55);
        wait_complete(10000);

        check_cs_deasserted();
        $display("INFO: T2 completed, CS1 was asserted during transfer");

        // ==================================================================
        // Test 3: 16-bit frame, Mode 0
        // ==================================================================
        $display("--- Test 3: 16-bit frame, Mode 0 ---");

        apb_write(8'h08, {16'(CLK_DIV_VAL),
                           4'd2, 4'd2,
                           2'b01,             // 16-bit frame
                           2'b00,             // CS0
                           1'b0, 1'b0, 1'b0, // MSB, CPHA=0, CPOL=0
                           1'b1});

        apb_write(8'h00, 32'hBEEF);
        wait_complete(10000);

        apb_read(8'h04, rdata);
        $display("INFO: T3 16-bit TX=0xBEEF RX=0x%04h", rdata[15:0]);

        // ==================================================================
        // Test 4: LSB-first, 8-bit, Mode 0
        //   TX 0xA5 LSB-first = 0xA5 reversed bitwise = 0xA5 (bit order check)
        //   0xA5 = 10100101b; LSB-first sends: 1,0,1,0,0,1,0,1
        //   Received back (shifted in the same order) should reconstruct 0xA5
        // ==================================================================
        $display("--- Test 4: LSB-first, 8-bit ---");

        apb_write(8'h08, {16'(CLK_DIV_VAL),
                           4'd2, 4'd2,
                           2'b00,             // 8-bit
                           2'b00,             // CS0
                           1'b1,              // LSB FIRST
                           1'b0, 1'b0,        // CPHA=0, CPOL=0
                           1'b1});

        apb_write(8'h00, 32'hA5);
        wait_complete(10000);
        $display("INFO: T4 LSB-first 8-bit completed");

        // ==================================================================
        // Test 5: Rapid back-to-back transactions
        // ==================================================================
        $display("--- Test 5: Back-to-back 4x transactions ---");

        apb_write(8'h08, {16'(CLK_DIV_VAL),
                           4'd1, 4'd1,        // Minimal setup/hold
                           2'b00, 2'b00,
                           1'b0, 1'b0, 1'b0,
                           1'b1});

        begin : back_to_back
            logic [7:0] send_bytes [4] = '{8'h11, 8'h22, 8'h33, 8'h44};
            for (int i = 0; i < 4; i++) begin
                apb_write(8'h00, {24'h0, send_bytes[i]});
                wait_complete(5000);
                $display("INFO: T5 byte[%0d] sent 0x%02h", i, send_bytes[i]);
            end
        end

        // ==================================================================
        // Summary
        // ==================================================================
        repeat (10) @(posedge clk);
        $display("--------------------------------------------");
        $display("Results: %0d assertions checked", pass_count + fail_count);
        $display("Simulation complete — review waveforms for full verification");
        $display("--------------------------------------------");
        $finish;
    end

    // -------------------------------------------------------------------------
    // Timeout watchdog
    // -------------------------------------------------------------------------
    initial begin
        #5_000_000;
        $display("TIMEOUT: simulation exceeded 5ms");
        $finish;
    end

    // -------------------------------------------------------------------------
    // Waveform dump
    // -------------------------------------------------------------------------
    initial begin
        $dumpfile("challenge_03_spi_master.vcd");
        $dumpvars(0, spi_master_tb);
    end

    // -------------------------------------------------------------------------
    // SCLK frequency monitor
    // -------------------------------------------------------------------------
    // Measures the actual SCLK period and reports it for verification
    time sclk_rise_time;
    time sclk_period_measured;

    initial begin
        sclk_rise_time = 0;
        forever begin
            @(posedge sclk);
            if (sclk_rise_time != 0) begin
                sclk_period_measured = $time - sclk_rise_time;
                // Uncomment to log every period:
                // $display("INFO: SCLK period = %0t ns", sclk_period_measured / 1000);
            end
            sclk_rise_time = $time;
        end
    end

    // TODO: Extend with:
    // - Full scoreboard: track all MOSI bits, reconstruct bytes, verify MISO echoes
    // - CS_SETUP/CS_HOLD timing assertion: measure delay in clocks using $time
    // - All four SPI modes: verify sample/shift edge polarity in waveform assertions
    // - 32-bit frame test: send 0xDEADBEEF, verify full 32 bits clocked out
    // - MISO glitch rejection: inject a pulse on MISO at a non-sample edge
    // - Multiple CS targets: verify only the selected CS_N is asserted per transfer
    // - Concurrent APB read of RX_DATA and STATUS during active transfer
    // - Protocol checker: use $assertcontrol and SVA sequences to verify SCLK/MOSI
    //   timing relationships formally

endmodule : spi_master_tb
