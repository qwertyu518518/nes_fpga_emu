`timescale 1ns/1ps

// Capacitive touch screen to NES controller input, Verilog-2001 synthesisable.
//
// Touch controller register map, I2C address, reset sequence and report format
// are taken from the board vendor's own driver, extracted read-only from
//   ...\4_SourceCode\1_FPGA_Design\ZYNQ_7020_FPGA.zip
//     ZYNQ_7020_FPGA/17_top_lcd_touch/top_lcd_touch.srcs/sources_1/new/touch/
//       touch_dri.v      (family select, GT register map, valid decode, reset)
//       i2c_dri_m.v      (START / addr+W / addr16 / Sr / addr+R / data / STOP)
//     ZYNQ_7020_FPGA/17_top_lcd_touch/top_lcd_touch.srcs/sources_1/new/lcd/
//       rd_id.v          (4.3" 800x480 RGB panel reports lcd_id 16'h4384)
// touch_dri.v selects the GT9147 family whenever lcd_id is 16'h4384 (4.3" RGB
// 800x480), 16'h4342 (4.3" RGB 480x272) or 16'h1018 (10" RGB 1280x800), and this
// board's panel is the 4.3" 800x480, so the GT branch is the one in force:
//   I2C slave address 7'h14, 16-bit register pointers
//   16'h814E status / touch flag register, 1 byte
//   16'h8150 touch point 1 coordinates, 4 bytes, X low, X high, Y low, Y high
//   status bit 7 = data ready, status[3:0] = number of touch points
//   valid when status[7] is set and 1 <= status[3:0] <= 5
//   the host clears the touch flag by writing 0x00 to 16'h814E
//   reset: ct_rst_n low for 10 ms, released, then 50 ms before the first access
// The GT family takes no configuration writes, so the vendor's FT-only
// register table is not reproduced here.
//
// THE AXIS SWAP AND THE FRAME ARE ASKED FOR, NOT ASSUMED
//   This header used to say "coordinates are used as reported, no axis swap for
//   the GT family".  That was an assumption copied out of the vendor driver's GT
//   branch, which is a pass-through (touch_dri.v:464-474), and the vendor never
//   configured the controller to do otherwise.  The vendor's only FPGA example
//   prints the two numbers as digits, in which a transposed frame looks
//   perfectly correct, so "the vendor passes it through" is not evidence that the
//   frame arriving on the bus is the frame the code assumes.  The d-pad from a
//   screen touch was wrong in all four directions on a board that is otherwise
//   correct, with the region map geometrically right, which is the signature of
//   the coordinates being in a different frame from the one hardcoded below.
//
//   The GT9147 does not have to be asked indirectly.  It detects its own module
//   parameters and generates its own configuration at power up (GT9147 datasheet
//   p.3, "the module detects the parameters and generates its configuration
//   automatically") and publishes the result in read-only registers:
//     GT9147编程指南.pdf p.4 section 3.2
//       16'h8047  Config_Version
//       16'h8048  X Output Max low   / 16'h8049 X Output Max high
//       16'h804A  Y Output Max low   / 16'h804B Y Output Max high
//       16'h804C  Touch_Number[3:0]
//       16'h804D  Module_Switch1 = Water_SpeedLimi_En Water_LargeRestraIn_En
//                                  Stretch_rank[5:4] X2Y Sito INT
//   p.11 of the same document gives bit 3 of 16'h804D as X2Y, the coordinate
//   swap flag, and confirms bits [5:4] are Stretch_rank, so the bit is read by
//   position and not decoded from a guess at the field layout.
//
//   A one-time calibration after the post-reset wait reads those five bytes and
//   derives the three region cuts from the two maxima, so neither the panel size
//   nor the axis orientation is a guess any more.  That covers a transposed
//   frame (H1, fixed by X2Y) and a module from the same family that is not
//   800x480 (H2, the ATK-4342 of this family is 480x272, fixed by the maxima)
//   without needing to know which of them applies.  H3, point 1 living at 16'h8158
//   rather than 16'h8150 on firmware 1030+, is not what this addresses; the fetch
//   stays on CT_COORD_REG, whose default is 16'h8150 and which a later build can
//   re-point at 16'h8158 without touching anything here.
//
// Bus hookup, identical in convention to wm8978_i2c:
//   assign scl = scl_o ? 1'bz : 1'b0;
//   assign sda = sda_oe ? sda_o : 1'bz;
// scl_o is an open drain SCL drive request, 0 pulls SCL low, 1 releases it.
// sda_oe is only asserted for a logic zero, so the master never sources current
// on either line. A logic one is sent by releasing SDA, which lets a slave that
// pulls SDA low during an ACK slot win over the pull-up.
//
// The region map is a total function of (x, y): the left EDGE_L fraction of the
// panel width is Left, the right EDGE_R fraction is Right, and the band between
// them is split at the MID fraction of the panel height into Up and Down. The
// cuts are the first pixel of the higher region, so x == X_LEFT_EDGE is already
// in the middle band and x == X_RIGHT_EDGE is already Right, y == Y_MID_EDGE is
// already Down. No (x, y) falls outside all five regions.
//
// WHAT CHANGED, AND WHAT DID NOT: the SEMANTICS above are untouched -- still left
// / middle-up / middle-down / right, still the left quarter and right quarter of
// the width with up and down in the middle band. Only where the three NUMBERS come
// from changed. They are no longer localparams; they are registers reset to the
// compile-time PANEL_W/PANEL_H arithmetic and then overwritten once, at
// calibration, from the maxima the controller publishes. If the calibration reads
// are NACKed or come back all ones the registers keep the compile-time values, so
// a failed calibration is exactly the behaviour of the previous build and cannot
// make the d-pad worse than it is today. touch_calib_ok says which happened.
//
// The three comparisons read three registers. There is no arithmetic anywhere in
// the per-report path, which is the whole point of doing the multiply and the
// shifts once during configuration instead of per frame.
//
// buttons[7:0] drives nes_controller.v: bit 0 is the first bit shifted out on
// $4016, so the order is A, B, Select, Start, Up, Down, Left, Right, and
// buttons[7:4] is exactly the touch dpad {Up, Down, Left, Right}.
// key[0] and key[1] are the two active low PL keys.  touch_key is the board
// TPAD, a third discrete button on its own pin.  While it is held the two keys
// drive Start and Select instead of A and B, because those two pairs of NES
// buttons are never needed at the same time.

module nes_touch_input #(
    parameter integer CLK_HZ             = 50_000_000,
    parameter integer I2C_HZ             = 250_000,
    parameter [6:0]   DEV_ADDR           = 7'h14,
    parameter [15:0]  CT_STATUS_REG      = 16'h814E,
    parameter [15:0]  CT_COORD_REG       = 16'h8150,
    parameter integer PANEL_W            = 800,
    parameter integer PANEL_H            = 480,
    parameter integer EDGE_L_NUM         = 1,
    parameter integer EDGE_L_DEN         = 4,
    parameter integer EDGE_R_NUM         = 3,
    parameter integer EDGE_R_DEN         = 4,
    parameter integer MID_NUM            = 1,
    parameter integer MID_DEN            = 2,
    parameter integer DEBOUNCE_CYCLES    = 800,
    parameter integer CT_RST_LOW_CYCLES  = 500_000,
    parameter integer CT_RST_WAIT_CYCLES = 2_500_000,
    parameter integer POLL_CYCLES        = 1_000_000,
    parameter integer USE_CT_INT         = 1
) (
    input  wire        clk,
    input  wire        reset,
    input  wire        ct_int,
    output wire        ct_rst_n,
    output wire        scl_o,
    output wire        sda_o,
    output wire        sda_oe,
    input  wire        sda_i,
    input  wire        key0,
    input  wire        key1,
    input  wire        touch_key,
    output wire [7:0]  buttons,
    output wire [3:0]  dpad,
    output wire        touch_valid,
    output wire [15:0] touch_x,
    output wire [15:0] touch_y,
    output wire        touch_int,
    output wire        init_done,
    output wire        touch_error,
    output wire        bus_busy,
    output wire        poll_done,
    // ------------------------------------------------------ calibration results
    // Published so a later diagnostic can read what the controller said without
    // going back over I2C.  Nothing consumes them yet; they exist to be looked at.
    // X Output Max and Y Output Max as the controller reported them, i.e. the
    // frame it says it is reporting in, and the three region cuts derived from
    // them.  touch_x2y is bit 3 of 16'h804D, the axis swap flag.  touch_calib_ok is
    // 1 only when the calibration reads completed AND produced a usable frame; on
    // 0 the three cuts are the compile-time PANEL_W/PANEL_H fractions and
    // touch_x2y is forced to 0.
    output wire [15:0] touch_x_max,
    output wire [15:0] touch_y_max,
    output wire        touch_x2y,
    output wire [15:0] touch_x_left_edge,
    output wire [15:0] touch_x_right_edge,
    output wire [15:0] touch_y_mid_edge,
    output wire        touch_calib_ok
);

    localparam [15:0] X_LEFT_EDGE  = (PANEL_W * EDGE_L_NUM) / EDGE_L_DEN;
    localparam [15:0] X_RIGHT_EDGE = (PANEL_W * EDGE_R_NUM) / EDGE_R_DEN;
    localparam [15:0] Y_MID_EDGE   = (PANEL_H * MID_NUM)   / MID_DEN;

    // The three read-only registers the calibration asks the controller about.
    // Fixed addresses, not parameters: the whole point is that the frame is read
    // rather than chosen, so there is nothing here for a build to point
    // somewhere else.  tb_nes_touch_input.v hard-codes the same three values and
    // asserts the driver reads exactly them, so a typo is a failing bench and not
    // a silently mis-addressed read.
    localparam [15:0] CT_XMAX_REG   = 16'h8048;   // X Output Max, low byte
    localparam [15:0] CT_YMAX_REG   = 16'h804A;   // Y Output Max, low byte
    localparam [15:0] CT_SWITCH_REG = 16'h804D;   // Module_Switch1, bit 3 = X2Y

    function integer clog2;
        input integer value;
        integer rest;
        begin
            rest = value - 1;
            clog2 = 0;
            while (rest > 0) begin
                rest = rest >> 1;
                clog2 = clog2 + 1;
            end
        end
    endfunction

    localparam integer WAIT_MAXV = (CT_RST_LOW_CYCLES  > CT_RST_WAIT_CYCLES) ?
                                  CT_RST_LOW_CYCLES  : CT_RST_WAIT_CYCLES;
    localparam integer WAIT_ALLV = (WAIT_MAXV > POLL_CYCLES) ? WAIT_MAXV : POLL_CYCLES;
    localparam integer WAIT_CW  = clog2(WAIT_ALLV + 1);

    localparam [WAIT_CW-1:0] RST_LO_M1 = CT_RST_LOW_CYCLES  - 1;
    localparam [WAIT_CW-1:0] RST_HI_M1 = CT_RST_WAIT_CYCLES - 1;
    localparam [WAIT_CW-1:0] POLL_M1   = POLL_CYCLES        - 1;

    localparam integer DB_RAW = clog2(DEBOUNCE_CYCLES + 1);
    localparam integer DB_CW  = (DB_RAW < 1) ? 1 : DB_RAW;
    localparam [DB_CW-1:0]  DB_M1 = DEBOUNCE_CYCLES - 1;

    localparam [5:0]
        SQ_RST_LO   = 6'd0,
        SQ_RST_HI   = 6'd1,
        SQ_WAIT     = 6'd2,
        SQ_ST_WR    = 6'd3,
        SQ_ST_REGH  = 6'd4,
        SQ_ST_REGL  = 6'd5,
        SQ_ST_RD    = 6'd6,
        SQ_ST_RX    = 6'd7,
        SQ_ST_STOP  = 6'd8,
        SQ_EVAL     = 6'd9,
        SQ_CO_WR    = 6'd10,
        SQ_CO_REGH  = 6'd11,
        SQ_CO_REGL  = 6'd12,
        SQ_CO_RD    = 6'd13,
        SQ_CO_RX0   = 6'd14,
        SQ_CO_RX1   = 6'd15,
        SQ_CO_RX2   = 6'd16,
        SQ_CO_RX3   = 6'd17,
        SQ_CO_STOP  = 6'd18,
        SQ_CLR_WR   = 6'd19,
        SQ_CLR_REGH = 6'd20,
        SQ_CLR_REGL = 6'd21,
        SQ_CLR_DAT  = 6'd22,
        SQ_CLR_STOP = 6'd23,
        SQ_ABORT    = 6'd24,
        // ---- the one-time calibration, between the post-reset wait and the
        // first poll.  One generic read-a-byte-block sequence reused for all three
        // reads, selected by cal_step_q, so the register pointer, the byte count
        // and the ACK pattern are one small mux rather than three near-copies of
        // the status read.
        SQ_CAL_SEL   = 6'd25,   // pick the pointer for this step
        SQ_CAL_WR    = 6'd26,
        SQ_CAL_REGH  = 6'd27,
        SQ_CAL_REGL  = 6'd28,
        SQ_CAL_RD    = 6'd29,
        SQ_CAL_RX    = 6'd30,
        SQ_CAL_STOP  = 6'd31,
        SQ_CAL_STEP  = 6'd32,   // byte captured: advance the index or the step
        SQ_CAL_DONE  = 6'd33,   // derive the three cuts, once, then poll
        SQ_CAL_ABORT = 6'd34;   // NACKed: STOP, then fall back to the constants

    reg  [5:0]        seq_q;
    reg  [WAIT_CW-1:0] wait_cnt_q;
    reg               ct_rst_n_q;
    reg               init_done_q;
    reg               touch_valid_q;
    reg  [15:0]       touch_x_q;
    reg  [15:0]       touch_y_q;
    reg  [7:0]        status_q;
    reg  [7:0]        x_lo_q;
    reg  [7:0]        x_hi_q;
    reg  [7:0]        y_lo_q;
    reg               error_q;
    reg               poll_ok_q;
    reg               poll_done_q;

    // ---- calibration state.  All of it lives in the configuration path.
    reg  [1:0]        cal_step_q;    // 0 = X max, 1 = Y max, 2 = Module_Switch1
    reg  [1:0]        cal_idx_q;     // which byte of the current block has landed
    reg               calib_fail_q;  // a calibration read NACKed
    reg  [15:0]       x_out_max_q;
    reg  [15:0]       y_out_max_q;
    reg  [7:0]        mod_switch_q;
    reg               x2y_q;
    reg               calib_ok_q;
    reg  [15:0]       x_left_edge_q;
    reg  [15:0]       x_right_edge_q;
    reg  [15:0]       y_mid_edge_q;

    reg               ct_int_meta_q;
    reg               ct_int_sync_q;

    reg        req_start;
    reg        req_rep;
    reg        req_cont;
    reg        req_stop;
    reg        req_dir;
    reg        req_ack_out;
    reg  [7:0] req_tx;

    wire [7:0] rx_data;
    wire       byte_done;
    wire       byte_nack;
    wire       stop_done;
    wire       i2c_busy;

    wire ct_int_early_wake = (USE_CT_INT != 0) && poll_ok_q && (ct_int_sync_q == 1'b0);

    // ---- calibration decode.  All of these are combinational functions of two
    // counters, used only while seq_q is inside the calibration, so none of this
    // reaches the per-report region comparisons.
    wire [15:0] cal_ptr       = (cal_step_q == 2'd0) ? CT_XMAX_REG   :
                                 (cal_step_q == 2'd1) ? CT_YMAX_REG   : CT_SWITCH_REG;
    wire       cal_two_bytes = (cal_step_q != 2'd2);
    // ACK every byte except the last of the block: the GT9147 addresses read data
    // back, so a two byte read ACKs the first byte and NACKs the second, and a one
    // byte read NACKs it.  Getting this wrong on the last byte is what makes a
    // multi-byte read hang on some controllers.
    wire       cal_rx_ack    = cal_two_bytes & (cal_idx_q == 2'd0);

    // A NACK anywhere in the sequence invalidates the whole calibration rather than
    // leaving the later reads to overwrite part of an answer that never arrived.
    //
    // All ones on the wire is a controller that never drove SDA at all, which is
    // what a stuck-high bus or an unpowered panel looks like to a master that is
    // otherwise getting ACKs.  16'hFFFF is the direct case; a high byte of 8'hFF on
    // its own is the same fault with a low byte that happened to arrive, and no
    // module in this family reports a maximum above 0x0FFF, so it is rejected too.
    wire calib_stuck_high = (x_out_max_q == 16'hFFFF) || (y_out_max_q == 16'hFFFF) ||
                            (x_out_max_q[15:8] == 8'hFF) || (y_out_max_q[15:8] == 8'hFF) ||
                            (mod_switch_q == 8'hFF);
    // A maximum of zero is not a real panel either, and taking it at face value
    // would put both horizontal cuts at zero and send every touch to Right.  The
    // GT9147 has no way to report a zero maximum, so this is a failed read too.
    wire calib_degenerate  = (x_out_max_q == 16'h0000) || (y_out_max_q == 16'h0000);
    wire calib_valid       = ~calib_fail_q & ~calib_stuck_high & ~calib_degenerate;

    always @(*) begin
        req_start   = 1'b0;
        req_rep     = 1'b0;
        req_cont    = 1'b0;
        req_stop    = 1'b0;
        req_dir     = 1'b1;
        req_ack_out = 1'b1;
        req_tx      = 8'h00;
        case (seq_q)
            SQ_ST_WR   : begin req_start = 1'b1; req_tx = {DEV_ADDR, 1'b0}; end
            SQ_ST_REGH : begin req_cont  = 1'b1; req_tx = CT_STATUS_REG[15:8]; end
            SQ_ST_REGL : begin req_cont  = 1'b1; req_tx = CT_STATUS_REG[7:0];  end
            SQ_ST_RD   : begin req_rep   = 1'b1; req_tx = {DEV_ADDR, 1'b1}; end
            SQ_ST_RX   : begin req_cont  = 1'b1; req_dir = 1'b0; req_ack_out = 1'b0; end
            SQ_ST_STOP : begin req_stop  = 1'b1; end
            SQ_CO_WR   : begin req_start = 1'b1; req_tx = {DEV_ADDR, 1'b0}; end
            SQ_CO_REGH : begin req_cont  = 1'b1; req_tx = CT_COORD_REG[15:8]; end
            SQ_CO_REGL : begin req_cont  = 1'b1; req_tx = CT_COORD_REG[7:0];  end
            SQ_CO_RD   : begin req_rep   = 1'b1; req_tx = {DEV_ADDR, 1'b1}; end
            SQ_CO_RX0  : begin req_cont  = 1'b1; req_dir = 1'b0; req_ack_out = 1'b1; end
            SQ_CO_RX1  : begin req_cont  = 1'b1; req_dir = 1'b0; req_ack_out = 1'b1; end
            SQ_CO_RX2  : begin req_cont  = 1'b1; req_dir = 1'b0; req_ack_out = 1'b1; end
            SQ_CO_RX3  : begin req_cont  = 1'b1; req_dir = 1'b0; req_ack_out = 1'b0; end
            SQ_CO_STOP : begin req_stop  = 1'b1; end
            SQ_CLR_WR  : begin req_start = 1'b1; req_tx = {DEV_ADDR, 1'b0}; end
            SQ_CLR_REGH: begin req_cont  = 1'b1; req_tx = CT_STATUS_REG[15:8]; end
            SQ_CLR_REGL: begin req_cont  = 1'b1; req_tx = CT_STATUS_REG[7:0];  end
            SQ_CLR_DAT : begin req_cont  = 1'b1; req_tx = 8'h00; end
            SQ_CLR_STOP: begin req_stop  = 1'b1; end
            SQ_ABORT   : begin req_stop  = 1'b1; end
            SQ_CAL_WR   : begin req_start = 1'b1; req_tx = {DEV_ADDR, 1'b0}; end
            SQ_CAL_REGH : begin req_cont  = 1'b1; req_tx = cal_ptr[15:8]; end
            SQ_CAL_REGL : begin req_cont  = 1'b1; req_tx = cal_ptr[7:0];  end
            SQ_CAL_RD   : begin req_rep   = 1'b1; req_tx = {DEV_ADDR, 1'b1}; end
            SQ_CAL_RX   : begin req_cont  = 1'b1; req_dir = 1'b0; req_ack_out = cal_rx_ack; end
            SQ_CAL_STOP : begin req_stop  = 1'b1; end
            SQ_CAL_ABORT: begin req_stop  = 1'b1; end
            default    : ;
        endcase
    end

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            seq_q         <= SQ_RST_LO;
            wait_cnt_q    <= {WAIT_CW{1'b0}};
            ct_rst_n_q    <= 1'b0;
            init_done_q   <= 1'b0;
            touch_valid_q <= 1'b0;
            touch_x_q     <= 16'h0000;
            touch_y_q     <= 16'h0000;
            status_q      <= 8'h00;
            x_lo_q        <= 8'h00;
            x_hi_q        <= 8'h00;
            y_lo_q        <= 8'h00;
            error_q       <= 1'b0;
            poll_ok_q     <= 1'b0;
            poll_done_q   <= 1'b0;
            cal_step_q    <= 2'd0;
            cal_idx_q     <= 2'd0;
            calib_fail_q  <= 1'b0;
            x_out_max_q   <= 16'h0000;
            y_out_max_q   <= 16'h0000;
            mod_switch_q  <= 8'h00;
            x2y_q         <= 1'b0;
            calib_ok_q    <= 1'b0;
            x_left_edge_q  <= X_LEFT_EDGE;
            x_right_edge_q <= X_RIGHT_EDGE;
            y_mid_edge_q   <= Y_MID_EDGE;
        end else begin
            poll_done_q <= 1'b0;
            case (seq_q)
                SQ_RST_LO: begin
                    ct_rst_n_q <= 1'b0;
                    if (wait_cnt_q == RST_LO_M1) begin
                        wait_cnt_q <= {WAIT_CW{1'b0}};
                        ct_rst_n_q <= 1'b1;
                        seq_q      <= SQ_RST_HI;
                    end else begin
                        wait_cnt_q <= wait_cnt_q + 1'b1;
                    end
                end
                SQ_RST_HI: begin
                    if (wait_cnt_q == RST_HI_M1) begin
                        wait_cnt_q  <= {WAIT_CW{1'b0}};
                        init_done_q <= 1'b1;
                        // init_done still means "the reset sequence and the vendor's
                        // 50 ms wait are over", exactly as before.  The calibration
                        // runs after it and before the first poll, so a caller that
                        // watches init_done still gets a bus that is about to be
                        // used and a driver that has not yet touched the panel's
                        // configuration registers.
                        seq_q       <= SQ_CAL_SEL;
                    end else begin
                        wait_cnt_q <= wait_cnt_q + 1'b1;
                    end
                end
                SQ_WAIT: begin
                    if ((wait_cnt_q == POLL_M1) || ct_int_early_wake) begin
                        wait_cnt_q <= {WAIT_CW{1'b0}};
                        seq_q      <= SQ_ST_WR;
                    end else begin
                        wait_cnt_q <= wait_cnt_q + 1'b1;
                    end
                end
                SQ_ST_WR  : if (byte_nack) seq_q <= SQ_ABORT; else if (byte_done) seq_q <= SQ_ST_REGH;
                SQ_ST_REGH: if (byte_nack) seq_q <= SQ_ABORT; else if (byte_done) seq_q <= SQ_ST_REGL;
                SQ_ST_REGL: if (byte_nack) seq_q <= SQ_ABORT; else if (byte_done) seq_q <= SQ_ST_RD;
                SQ_ST_RD  : if (byte_nack) seq_q <= SQ_ABORT; else if (byte_done) seq_q <= SQ_ST_RX;
                SQ_ST_RX  : if (byte_nack) seq_q <= SQ_ABORT;
                            else if (byte_done) begin
                                status_q <= rx_data;
                                seq_q    <= SQ_ST_STOP;
                            end
                SQ_ST_STOP: if (stop_done) seq_q <= SQ_EVAL;
                SQ_EVAL   : begin
                    if (status_q[7] && (status_q[3:0] >= 4'd1) && (status_q[3:0] <= 4'd5)) begin
                        touch_valid_q <= 1'b1;
                        seq_q         <= SQ_CO_WR;
                    end else begin
                        touch_valid_q <= 1'b0;
                        seq_q         <= SQ_CLR_WR;
                    end
                end
                SQ_CO_WR  : if (byte_nack) seq_q <= SQ_ABORT; else if (byte_done) seq_q <= SQ_CO_REGH;
                SQ_CO_REGH: if (byte_nack) seq_q <= SQ_ABORT; else if (byte_done) seq_q <= SQ_CO_REGL;
                SQ_CO_REGL: if (byte_nack) seq_q <= SQ_ABORT; else if (byte_done) seq_q <= SQ_CO_RD;
                SQ_CO_RD  : if (byte_nack) seq_q <= SQ_ABORT; else if (byte_done) seq_q <= SQ_CO_RX0;
                SQ_CO_RX0 : if (byte_nack) seq_q <= SQ_ABORT;
                            else if (byte_done) begin
                                x_lo_q <= rx_data;
                                seq_q  <= SQ_CO_RX1;
                            end
                SQ_CO_RX1 : if (byte_nack) seq_q <= SQ_ABORT;
                            else if (byte_done) begin
                                x_hi_q <= rx_data;
                                seq_q  <= SQ_CO_RX2;
                            end
                SQ_CO_RX2 : if (byte_nack) seq_q <= SQ_ABORT;
                            else if (byte_done) begin
                                y_lo_q <= rx_data;
                                seq_q  <= SQ_CO_RX3;
                            end
                SQ_CO_RX3 : if (byte_nack) seq_q <= SQ_ABORT;
                            else if (byte_done) begin
                                // THE SWAP, AND WHY IT IS HERE.
                                // The byte order above is untouched: x_lo, x_hi,
                                // y_lo, y_hi is what the four bytes are, in the
                                // order they arrived, for a swapped controller just
                                // as much as an unswapped one.  What X2Y means is
                                // that the first 16 bit word is the Y coordinate.
                                // So the two words are assembled first, from the
                                // registers, and then exchanged by x2y_q: two
                                // 16-bit 2:1 muxes on the last byte of the fetch.
                                // Doing it inside the fetch instead would mean two
                                // different byte orders depending on a
                                // configuration bit read once at power up, and the
                                // fetch would no longer be the one sequence that
                                // was verified against a byte-level model.
                                touch_x_q <= x2y_q ? coord_y_raw : coord_x_raw;
                                touch_y_q <= x2y_q ? coord_x_raw : coord_y_raw;
                                seq_q     <= SQ_CO_STOP;
                            end
                SQ_CO_STOP: if (stop_done) seq_q <= SQ_CLR_WR;
                SQ_CLR_WR  : if (byte_nack) seq_q <= SQ_ABORT; else if (byte_done) seq_q <= SQ_CLR_REGH;
                SQ_CLR_REGH: if (byte_nack) seq_q <= SQ_ABORT; else if (byte_done) seq_q <= SQ_CLR_REGL;
                SQ_CLR_REGL: if (byte_nack) seq_q <= SQ_ABORT; else if (byte_done) seq_q <= SQ_CLR_DAT;
                SQ_CLR_DAT : if (byte_nack) seq_q <= SQ_ABORT; else if (byte_done) seq_q <= SQ_CLR_STOP;
                SQ_CLR_STOP: if (stop_done) begin
                                 poll_done_q <= 1'b1;
                                 poll_ok_q   <= 1'b1;
                                 seq_q       <= SQ_WAIT;
                             end
                SQ_ABORT   : if (stop_done) begin
                                 error_q       <= 1'b1;
                                 touch_valid_q <= 1'b0;
                                 poll_ok_q     <= 1'b0;
                                 poll_done_q   <= 1'b1;
                                 wait_cnt_q    <= {WAIT_CW{1'b0}};
                                 seq_q         <= SQ_WAIT;
                             end
                // ---- calibration.  START, addr+W, two pointer bytes,
                // repeated START, addr+R, the block, STOP -- the same shape as
                // the status read, driven by cal_ptr / cal_rx_ack above.
                SQ_CAL_SEL  : seq_q <= SQ_CAL_WR;
                SQ_CAL_WR   : if (byte_nack) seq_q <= SQ_CAL_ABORT;
                              else if (byte_done) seq_q <= SQ_CAL_REGH;
                SQ_CAL_REGH : if (byte_nack) seq_q <= SQ_CAL_ABORT;
                              else if (byte_done) seq_q <= SQ_CAL_REGL;
                SQ_CAL_REGL : if (byte_nack) seq_q <= SQ_CAL_ABORT;
                              else if (byte_done) seq_q <= SQ_CAL_RD;
                SQ_CAL_RD   : if (byte_nack) seq_q <= SQ_CAL_ABORT;
                              else if (byte_done) seq_q <= SQ_CAL_RX;
                SQ_CAL_RX   : if (byte_nack) seq_q <= SQ_CAL_ABORT;
                              else if (byte_done) begin
                                  // The byte order here is the GT9147's own: low
                                  // byte first, then high, for both maxima.
                                  case (cal_step_q)
                                      2'd0 : if (cal_idx_q == 2'd0)
                                                 x_out_max_q[7:0]  <= rx_data;
                                             else
                                                 x_out_max_q[15:8] <= rx_data;
                                      2'd1 : if (cal_idx_q == 2'd0)
                                                 y_out_max_q[7:0]  <= rx_data;
                                             else
                                                 y_out_max_q[15:8] <= rx_data;
                                      default: mod_switch_q <= rx_data;
                                  endcase
                                  // The block is read back to back in ONE
                                  // transaction.  cal_rx_ack is high for every
                                  // byte except the last, so it is also the "there
                                  // is another byte to fetch" flag: keep asserting
                                  // cont until the byte that is NACKed arrives, and
                                  // STOP after that one.  Stopping on the first
                                  // byte_done instead would read the high byte as a
                                  // second transaction of its own, which still lands
                                  // the right value but spends a whole bus sequence
                                  // per byte and, worse, would still be reading the
                                  // low byte if the slave ever NACKed the first.
                                  if (cal_rx_ack) begin
                                      cal_idx_q <= cal_idx_q + 2'd1;
                                      seq_q     <= SQ_CAL_RX;
                                  end else begin
                                      seq_q     <= SQ_CAL_STOP;
                                  end
                              end
                SQ_CAL_STOP : if (stop_done) seq_q <= SQ_CAL_STEP;
                SQ_CAL_STEP : begin
                                  cal_idx_q  <= 2'd0;
                                  cal_step_q <= cal_step_q + 2'd1;
                                  seq_q      <= (cal_step_q == 2'd2) ? SQ_CAL_DONE
                                                                    : SQ_CAL_SEL;
                              end
                SQ_CAL_DONE : begin
                                  // THE ONLY ARITHMETIC, AND IT RUNS ONCE.
                                  // One shift, one subtract and one shift, on the
                                  // way out of configuration, into the three
                                  // registers the region map then reads as plain
                                  // constants for the rest of time.  The horizontal
                                  // cut is the quarter and the three-quarter, so the
                                  // right one is a subtraction from the same shifted
                                  // value rather than a second shift and an add.
                                  if (calib_valid) begin
                                      x_left_edge_q  <= x_out_max_q >> 2;
                                      x_right_edge_q <= x_out_max_q - (x_out_max_q >> 2);
                                      y_mid_edge_q   <= y_out_max_q >> 1;
                                      x2y_q          <= mod_switch_q[3];
                                      calib_ok_q     <= 1'b1;
                                  end else begin
                                      // The constants, which is what this module did
                                      // before the calibration existed, so a failed
                                      // read is the previous behaviour and not a new
                                      // one.  x2y_q is forced low rather than taken
                                      // from a block that never arrived.
                                      x_left_edge_q  <= X_LEFT_EDGE;
                                      x_right_edge_q <= X_RIGHT_EDGE;
                                      y_mid_edge_q   <= Y_MID_EDGE;
                                      x2y_q          <= 1'b0;
                                      calib_ok_q     <= 1'b0;
                                  end
                                  seq_q <= SQ_WAIT;
                              end
                // A NACK inside the calibration.  STOP so the bus is handed back
                // the same clean way SQ_ABORT hands it back, then fall through to
                // SQ_CAL_DONE with calib_fail_q set, which takes the fallback branch
                // there.  touch_error is deliberately NOT raised: this is a
                // calibration outcome the design absorbs on purpose, it is reported
                // through touch_calib_ok, and the polling loop that follows is
                // unaffected.
                SQ_CAL_ABORT: begin
                                  calib_fail_q <= 1'b1;
                                  if (stop_done) seq_q <= SQ_CAL_DONE;
                              end
                default    : seq_q <= SQ_WAIT;
            endcase
        end
    end

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            ct_int_meta_q <= 1'b1;
            ct_int_sync_q <= 1'b1;
        end else begin
            ct_int_meta_q <= ct_int;
            ct_int_sync_q <= ct_int_meta_q;
        end
    end

    // touch_key is the board TPAD: a discrete momentary button on its own pin F16,
    // NOT a point on the GT9147, so the substitution is keyed off it and not off
    // touch_valid_q.  Gating the substitution on touch_valid_q, as this did, meant
    // that touching the screen to steer turned the two keys into Start and Select,
    // making steering and firing mutually exclusive.  The polarity is also the
    // opposite of key0/key1: touch_key is ACTIVE HIGH, idle low, from the vendor's
    // own RTL for this pin (touch_led.v:51 detects a RISING edge as the press,
    // tb_touch_led.v:22 drives 1 to press).  Hence the idle vector below is 3'b011:
    // bits [1:0] are the two active low keys idle high, bit [2] is the active high
    // TPAD idle low.
    wire [2:0] key_async = {touch_key, key1, key0};

    reg [2:0] key_meta_q;
    reg [2:0] key_sync_q;
    reg [2:0] key_candidate_q;
    reg [2:0] key_stable_q;
    reg [DB_CW-1:0] key_cnt_q;

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            key_meta_q <= 3'b011;
            key_sync_q <= 3'b011;
        end else begin
            key_meta_q <= key_async;
            key_sync_q <= key_meta_q;
        end
    end

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            key_candidate_q <= 3'b011;
            key_stable_q    <= 3'b011;
            key_cnt_q       <= {DB_CW{1'b0}};
        end else if (key_sync_q == key_candidate_q) begin
            key_cnt_q <= {DB_CW{1'b0}};
        end else if (key_cnt_q == DB_M1) begin
            key_candidate_q <= key_sync_q;
            key_stable_q    <= key_sync_q;
            key_cnt_q       <= {DB_CW{1'b0}};
        end else begin
            key_cnt_q <= key_cnt_q + 1'b1;
        end
    end

    wire       key0_pressed  = ~key_stable_q[0];
    wire       key1_pressed  = ~key_stable_q[1];
    wire       touch_key_debounced = key_stable_q[2];
    wire       ab_substituted = touch_key_debounced;   // was: touch_valid_q
    wire       key_start     = ab_substituted & key0_pressed;
    wire       key_select    = ab_substituted & key1_pressed;
    wire       btn_a         = ~ab_substituted & key0_pressed;
    wire       btn_b         = ~ab_substituted & key1_pressed;

    // The two 16 bit words exactly as the four bytes read from CT_COORD_REG
    // assemble them, before any axis decision.
    wire [15:0] coord_x_raw  = {x_hi_q, x_lo_q};
    wire [15:0] coord_y_raw  = {rx_data, y_lo_q};

    // The region map, reading three REGISTERS.  These are the same three
    // comparisons, with the same meaning, as the ones this module made against
    // X_LEFT_EDGE, X_RIGHT_EDGE and Y_MID_EDGE; the only difference is that the
    // cut values are now whatever the controller said the frame is.  Three
    // compares, no arithmetic, nothing per frame that was not there before.
    wire       region_left   = (touch_x_q <  x_left_edge_q);
    wire       region_right  = (touch_x_q >= x_right_edge_q);
    wire       region_middle = ~region_left & ~region_right;
    wire       region_upper  = (touch_y_q <  y_mid_edge_q);

    wire [3:0] touch_dpad    = {touch_valid_q & region_middle &  region_upper,
                                touch_valid_q & region_middle & ~region_upper,
                                touch_valid_q & region_left,
                                touch_valid_q & region_right};

    assign buttons     = {touch_dpad, key_start, key_select, btn_b, btn_a};
    assign dpad        = touch_dpad;
    assign touch_valid = touch_valid_q;
    assign touch_x     = touch_x_q;
    assign touch_y     = touch_y_q;
    assign touch_int   = ~ct_int_sync_q;
    assign ct_rst_n    = ct_rst_n_q;
    assign init_done   = init_done_q;
    assign touch_error = error_q;
    assign bus_busy    = i2c_busy;
    assign poll_done   = poll_done_q;
    assign touch_x_max        = x_out_max_q;
    assign touch_y_max        = y_out_max_q;
    assign touch_x2y          = x2y_q;
    assign touch_x_left_edge  = x_left_edge_q;
    assign touch_x_right_edge = x_right_edge_q;
    assign touch_y_mid_edge   = y_mid_edge_q;
    assign touch_calib_ok     = calib_ok_q;

    nes_touch_i2c #(
        .CLK_HZ(CLK_HZ),
        .I2C_HZ(I2C_HZ)
    ) u_i2c (
        .clk       (clk),
        .reset     (reset),
        .start     (req_start),
        .rep_start (req_rep),
        .cont      (req_cont),
        .stop      (req_stop),
        .tx_dir    (req_dir),
        .tx_data   (req_tx),
        .ack_out   (req_ack_out),
        .sda_i     (sda_i),
        .scl_o     (scl_o),
        .sda_o     (sda_o),
        .sda_oe    (sda_oe),
        .byte_done (byte_done),
        .byte_nack (byte_nack),
        .stop_done (stop_done),
        .rx_data   (rx_data),
        .busy      (i2c_busy)
    );

endmodule

// General purpose I2C master, Verilog-2001 synthesisable, one byte per request.
// The bus interface is the same open drain convention as wm8978_i2c: scl_o is a
// drive request where 0 pulls SCL low and 1 releases it, sda_oe asserts sda_o
// only for a logic zero, and sda_i is the level resolved on the wire. A request
// is a level that stays presented until the matching byte_done, byte_nack or
// stop_done pulse, so start, rep_start, cont and stop never race the bit engine.
module nes_touch_i2c #(
    parameter integer CLK_HZ = 50_000_000,
    parameter integer I2C_HZ = 250_000
) (
    input  wire       clk,
    input  wire       reset,
    input  wire       start,
    input  wire       rep_start,
    input  wire       cont,
    input  wire       stop,
    input  wire       tx_dir,
    input  wire [7:0] tx_data,
    input  wire       ack_out,
    input  wire       sda_i,
    output wire       scl_o,
    output wire       sda_o,
    output wire       sda_oe,
    output wire       byte_done,
    output wire       byte_nack,
    output wire       stop_done,
    output wire [7:0] rx_data,
    output wire       busy
);

    function integer clog2;
        input integer value;
        integer rest;
        begin
            rest = value - 1;
            clog2 = 0;
            while (rest > 0) begin
                rest = rest >> 1;
                clog2 = clog2 + 1;
            end
        end
    endfunction

    localparam integer QTR_RAW = CLK_HZ / (4 * I2C_HZ);
    localparam integer QTR     = (QTR_RAW < 1) ? 1 : QTR_RAW;
    localparam integer QW_RAW  = clog2(QTR + 1);
    localparam integer QW      = (QW_RAW < 1) ? 1 : QW_RAW;
    localparam [QW-1:0] QTR_M1 = QTR - 1;

    localparam [3:0]
        E_IDLE      = 4'd0,
        E_START_H   = 4'd1,
        E_START_L   = 4'd2,
        E_REP_PRE_A = 4'd3,
        E_REP_PRE_B = 4'd4,
        E_REP_H     = 4'd5,
        E_REP_L     = 4'd6,
        E_BIT       = 4'd7,
        E_PEND      = 4'd8,
        E_BUSLOW    = 4'd9,
        E_BUSHIGH   = 4'd10,
        E_STOP_L    = 4'd11,
        E_STOP_H    = 4'd12,
        E_TBUF_A    = 4'd13,
        E_TBUF_B    = 4'd14;

    localparam [1:0] TICK_LAST = 2'd3;

    reg [QW-1:0] div_cnt_q;
    reg [3:0]    e_state;
    reg [1:0]    e_phase;
    reg [3:0]    e_bit;
    reg [1:0]    e_hold;
    reg [7:0]    e_rx;
    reg          e_ack_sample;
    reg          scl_q;
    reg          sda_val_q;
    reg          sda_oe_q;
    reg          byte_done_q;
    reg          byte_nack_q;
    reg          stop_done_q;

    wire tick    = (div_cnt_q == QTR_M1);
    wire fin_ok  = tx_dir ? (e_ack_sample == 1'b0) :
                            (ack_out ? (e_ack_sample == 1'b0) : 1'b1);

    assign byte_done = byte_done_q;
    assign byte_nack = byte_nack_q;
    assign stop_done = stop_done_q;
    assign scl_o     = scl_q;
    assign sda_o     = sda_val_q;
    assign sda_oe    = sda_oe_q;
    assign rx_data   = e_rx;
    assign busy      = (e_state != E_IDLE);

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            div_cnt_q <= {QW{1'b0}};
        end else if (tick) begin
            div_cnt_q <= {QW{1'b0}};
        end else begin
            div_cnt_q <= div_cnt_q + 1'b1;
        end
    end

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            e_state      <= E_IDLE;
            e_phase      <= 2'd0;
            e_bit        <= 4'd0;
            e_hold       <= 2'd0;
            e_rx         <= 8'h00;
            e_ack_sample <= 1'b1;
            scl_q        <= 1'b1;
            sda_val_q    <= 1'b1;
            sda_oe_q     <= 1'b0;
            byte_done_q  <= 1'b0;
            byte_nack_q  <= 1'b0;
            stop_done_q  <= 1'b0;
        end else begin
            byte_done_q <= 1'b0;
            byte_nack_q <= 1'b0;
            stop_done_q <= 1'b0;
            if (tick) begin
            case (e_state)
                E_IDLE: begin
                    scl_q     <= 1'b1;
                    sda_oe_q  <= 1'b0;
                    sda_val_q <= 1'b1;
                    if (start) begin
                        e_bit     <= 4'd0;
                        e_phase   <= 2'd0;
                        e_hold    <= 2'd0;
                        sda_oe_q  <= 1'b1;
                        sda_val_q <= 1'b0;
                        e_state   <= E_START_H;
                    end
                end
                E_START_H: begin
                    if (e_hold == TICK_LAST) begin
                        e_hold  <= 2'd0;
                        scl_q   <= 1'b0;
                        e_state <= E_START_L;
                    end else begin
                        e_hold <= e_hold + 2'd1;
                    end
                end
                E_START_L: begin
                    if (e_hold == TICK_LAST) begin
                        e_hold  <= 2'd0;
                        e_bit   <= 4'd0;
                        e_phase <= 2'd0;
                        e_state <= E_BIT;
                    end else begin
                        e_hold <= e_hold + 2'd1;
                    end
                end
                E_REP_PRE_A: begin
                    scl_q     <= 1'b1;
                    sda_oe_q  <= 1'b0;
                    sda_val_q <= 1'b1;
                    if (e_hold == TICK_LAST) begin
                        e_hold  <= 2'd0;
                        e_state <= E_REP_PRE_B;
                    end else begin
                        e_hold <= e_hold + 2'd1;
                    end
                end
                E_REP_PRE_B: begin
                    scl_q     <= 1'b1;
                    sda_oe_q  <= 1'b0;
                    sda_val_q <= 1'b1;
                    if (e_hold == TICK_LAST) begin
                        e_hold    <= 2'd0;
                        sda_oe_q  <= 1'b1;
                        sda_val_q <= 1'b0;
                        e_state   <= E_REP_H;
                    end else begin
                        e_hold <= e_hold + 2'd1;
                    end
                end
                E_REP_H: begin
                    if (e_hold == TICK_LAST) begin
                        e_hold  <= 2'd0;
                        scl_q   <= 1'b0;
                        e_state <= E_REP_L;
                    end else begin
                        e_hold <= e_hold + 2'd1;
                    end
                end
                E_REP_L: begin
                    if (e_hold == TICK_LAST) begin
                        e_hold  <= 2'd0;
                        e_bit   <= 4'd0;
                        e_phase <= 2'd0;
                        e_state <= E_BIT;
                    end else begin
                        e_hold <= e_hold + 2'd1;
                    end
                end
                E_BIT: begin
                    if (e_phase == 2'd0) begin
                        if (e_bit == 4'd8) begin
                            if (!tx_dir && ack_out) begin
                                sda_val_q <= 1'b0;
                                sda_oe_q  <= 1'b1;
                            end else begin
                                sda_oe_q  <= 1'b0;
                                sda_val_q <= 1'b1;
                            end
                        end else if (tx_dir) begin
                            sda_val_q <= tx_data[7 - e_bit];
                            sda_oe_q  <= ~tx_data[7 - e_bit];
                        end else begin
                            sda_oe_q  <= 1'b0;
                            sda_val_q <= 1'b1;
                        end
                    end
                    if (e_phase == 2'd1) begin
                        scl_q <= 1'b1;
                    end else if (e_phase == 2'd2) begin
                        if (e_bit == 4'd8) begin
                            e_ack_sample <= sda_i;
                        end else if (!tx_dir) begin
                            e_rx[7 - e_bit] <= sda_i;
                        end
                    end else if (e_phase == 2'd3) begin
                        scl_q <= 1'b0;
                        if (e_bit == 4'd8) begin
                            e_state <= E_PEND;
                            if (fin_ok) begin
                                byte_done_q <= 1'b1;
                            end else begin
                                byte_nack_q <= 1'b1;
                            end
                        end else begin
                            e_bit <= e_bit + 4'd1;
                        end
                    end
                    e_phase <= e_phase + 2'd1;
                end
                E_PEND: begin
                    scl_q     <= 1'b0;
                    sda_oe_q  <= 1'b0;
                    sda_val_q <= 1'b1;
                    e_state   <= E_BUSLOW;
                end
                E_BUSLOW: begin
                    scl_q     <= 1'b0;
                    sda_oe_q  <= 1'b0;
                    sda_val_q <= 1'b1;
                    if (cont) begin
                        e_bit   <= 4'd0;
                        e_phase <= 2'd0;
                        e_state <= E_BIT;
                    end else if (stop) begin
                        e_hold    <= 2'd0;
                        sda_oe_q  <= 1'b1;
                        sda_val_q <= 1'b0;
                        e_state   <= E_STOP_L;
                    end else if (rep_start || start) begin
                        e_state <= E_BUSHIGH;
                    end
                end
                E_BUSHIGH: begin
                    scl_q     <= 1'b1;
                    sda_oe_q  <= 1'b0;
                    sda_val_q <= 1'b1;
                    if (rep_start) begin
                        e_bit    <= 4'd0;
                        e_phase  <= 2'd0;
                        e_hold   <= 2'd0;
                        e_state  <= E_REP_PRE_A;
                    end else if (start) begin
                        e_bit     <= 4'd0;
                        e_phase   <= 2'd0;
                        e_hold    <= 2'd0;
                        sda_oe_q  <= 1'b1;
                        sda_val_q <= 1'b0;
                        e_state   <= E_START_H;
                    end else begin
                        e_state <= E_BUSLOW;
                    end
                end
                E_STOP_L: begin
                    if (e_hold == TICK_LAST) begin
                        e_hold  <= 2'd0;
                        scl_q   <= 1'b1;
                        e_state <= E_STOP_H;
                    end else begin
                        e_hold <= e_hold + 2'd1;
                    end
                end
                E_STOP_H: begin
                    sda_oe_q  <= 1'b0;
                    sda_val_q <= 1'b1;
                    if (e_hold == TICK_LAST) begin
                        e_hold      <= 2'd0;
                        stop_done_q <= 1'b1;
                        e_state     <= E_TBUF_A;
                    end else begin
                        e_hold <= e_hold + 2'd1;
                    end
                end
                E_TBUF_A: begin
                    scl_q     <= 1'b1;
                    sda_oe_q  <= 1'b0;
                    sda_val_q <= 1'b1;
                    if (e_hold == TICK_LAST) begin
                        e_hold  <= 2'd0;
                        e_state <= E_TBUF_B;
                    end else begin
                        e_hold <= e_hold + 2'd1;
                    end
                end
                E_TBUF_B: begin
                    scl_q     <= 1'b1;
                    sda_oe_q  <= 1'b0;
                    sda_val_q <= 1'b1;
                    if (e_hold == TICK_LAST) begin
                        e_hold  <= 2'd0;
                        e_state <= E_IDLE;
                    end else begin
                        e_hold <= e_hold + 2'd1;
                    end
                end
                default: e_state <= E_IDLE;
            endcase
            end
        end
    end

endmodule
