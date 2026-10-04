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
//   coordinates are used as reported, no axis swap for the GT family
//   the host clears the touch flag by writing 0x00 to 16'h814E
//   reset: ct_rst_n low for 10 ms, released, then 50 ms before the first access
// The GT family takes no configuration writes, so the vendor's FT-only
// register table is not reproduced here.
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
    output wire        poll_done
);

    localparam [15:0] X_LEFT_EDGE  = (PANEL_W * EDGE_L_NUM) / EDGE_L_DEN;
    localparam [15:0] X_RIGHT_EDGE = (PANEL_W * EDGE_R_NUM) / EDGE_R_DEN;
    localparam [15:0] Y_MID_EDGE   = (PANEL_H * MID_NUM)   / MID_DEN;

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
        SQ_ABORT    = 6'd24;

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
                        seq_q       <= SQ_WAIT;
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
                                touch_x_q <= {x_hi_q, x_lo_q};
                                touch_y_q <= {rx_data, y_lo_q};
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

    wire       region_left   = (touch_x_q <  X_LEFT_EDGE);
    wire       region_right  = (touch_x_q >= X_RIGHT_EDGE);
    wire       region_middle = ~region_left & ~region_right;
    wire       region_upper  = (touch_y_q <  Y_MID_EDGE);

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
