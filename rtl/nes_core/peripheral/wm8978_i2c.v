`timescale 1ns/1ps

// WM8978 stereo audio codec I2C master (Verilog-2001, synthesisable).
//
// Bus interface uses explicit tri-state control instead of `inout`:
//   scl_o  open drain SCL drive request, 0 = pull SCL low, 1 = release SCL
//          (the master never sources current on SCL, an external pull-up sets
//          the high level)
//   sda_o  SDA level, only meaningful while sda_oe is high
//   sda_oe 1 = drive sda_o, 0 = release SDA
//   sda_i  SDA level resolved on the wire, sampled during the ACK slot
// Typical hookup:  assign scl = scl_o  ? 1'bz : 1'b0;
//                  assign sda = sda_oe ? sda_o : 1'bz;
// A logic one on SDA is sent by releasing the line, sda_oe is only asserted for
// a logic zero, so the master never sources current on SDA either. A slave
// that pulls SDA low during the ACK slot therefore wins over the pull-up, and
// the master samples it through sda_i.
//
// Write transaction (wr_req is a one clock pulse, reg_addr and wdata must be
// valid in that same cycle):
//   ST_IDLE -> ST_START_H -> ST_START_L -> ST_BIT -> ST_STOP_L -> ST_STOP_H
//   -> ST_STOP_HOLD -> ST_IDLE
// ST_BIT clocks nine slots per byte over the three bytes {DEV_ADDR,1'b0},
// reg_addr[7:0] and wdata[7:0], the ninth slot being the ACK slot where the
// master releases SDA and samples sda_i. ST_GAP delays separate the power-on
// configuration items.
// A NACK on any ACK slot raises nack_seen and error, aborts the byte train
// and still emits the STOP so the bus is handed back cleanly; wr_done does
// not pulse for an aborted write. A wr_req that arrives while busy is
// dropped and raises error. Both flags are sticky until reset.
//
// Timing: SCL comes from a CLK_HZ/(4*I2C_HZ) quarter-period divider, so one
// bit period is four divider ticks. SDA is only ever driven in the tick that
// follows an SCL falling edge, which leaves one quarter period of hold and
// two of setup. START and STOP each hold their SCL/SDA levels for a full bit
// period, well past the standard-mode minima (tSU;STA 6.0us, tHD;STA 0.6us,
// tSU;STO 0.6us, tHD;STO 0.4us, tBUF 5.0us).
//
// Power-on configuration: after reset the module walks the case-form constant
// table CFG_REG()/CFG_DATA() (CFG_COUNT items, in table order) and latches
// cfg_done high once the table is exhausted; CFG_GAP clocks of delay are
// inserted before the first item and between items. Every register address and
// value is a parameter, so a board can retune the sequence without edits.
//
//   0x00          software reset. Writing 0x1F resets every register to its
//                 power-on default and must be the first item of the table.
//   0x01 / 0x02   channel enable. 0x1F enables the LOUT/ROUT channels, the
//                 mixer path and the line outputs.
//   0x0C          digital audio interface format. 0x10 selects master mode,
//                 I2S format and a 256*Fs MCLK/word-clock ratio.
//   0x0D          digital audio interface control. 0x02 selects 16 bit sample
//                 words with data driven from the rising word-clock edge.
//   0x19 / 0x1A   sample rate. 0x34/0x00 set the oversampling ratio and the
//                 audio sample rate divider for the supplied system clock.
//   0x32 / 0x33   digital volume. 0x32/0x32 is the left/right playback volume
//                 step (0x00 is -57dB, 0xFF is +12dB).
//
// CFG_COUNT must not exceed the number of table entries implemented below
// (CFG_REG 0x00, 0x01, 0x02, 0x0c, 0x0d, 0x19, 0x1a, 0x32, 0x33); indices past
// the table read back 0x00.

module wm8978_i2c #(
    parameter integer CLK_HZ       = 50000000,
    parameter integer I2C_HZ       = 100000,
    parameter [6:0]   DEV_ADDR     = 7'h1a,
    parameter integer CFG_COUNT    = 9,
    parameter integer CFG_GAP      = 2500,
    parameter [7:0] CFG_RST_REG   = 8'h00,
    parameter [7:0] CFG_RST_DAT   = 8'h1f,
    parameter [7:0] CFG_EN1_REG   = 8'h01,
    parameter [7:0] CFG_EN1_DAT   = 8'h1f,
    parameter [7:0] CFG_EN2_REG   = 8'h02,
    parameter [7:0] CFG_EN2_DAT   = 8'h1f,
    parameter [7:0] CFG_FMT_REG   = 8'h0c,
    parameter [7:0] CFG_FMT_DAT   = 8'h10,
    parameter [7:0] CFG_FMD_REG   = 8'h0d,
    parameter [7:0] CFG_FMD_DAT   = 8'h02,
    parameter [7:0] CFG_SR1_REG   = 8'h19,
    parameter [7:0] CFG_SR1_DAT   = 8'h34,
    parameter [7:0] CFG_SR2_REG   = 8'h1a,
    parameter [7:0] CFG_SR2_DAT   = 8'h00,
    parameter [7:0] CFG_VOLL_REG  = 8'h32,
    parameter [7:0] CFG_VOLL_DAT  = 8'h32,
    parameter [7:0] CFG_VOLR_REG  = 8'h33,
    parameter [7:0] CFG_VOLR_DAT  = 8'h32
)(
    input  wire       clk,
    input  wire       reset,
    input  wire       wr_req,
    input  wire [7:0] reg_addr,
    input  wire [7:0] wdata,
    input  wire       sda_i,
    output wire       scl_o,
    output wire       sda_o,
    output wire       sda_oe,
    output wire       busy,
    output wire       wr_done,
    output wire       nack_seen,
    output wire       error,
    output wire       cfg_done
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

    function [7:0] CFG_REG;
        input [7:0] idx;
        begin
            case (idx)
                8'd0    : CFG_REG = CFG_RST_REG;
                8'd1    : CFG_REG = CFG_EN1_REG;
                8'd2    : CFG_REG = CFG_EN2_REG;
                8'd3    : CFG_REG = CFG_FMT_REG;
                8'd4    : CFG_REG = CFG_FMD_REG;
                8'd5    : CFG_REG = CFG_SR1_REG;
                8'd6    : CFG_REG = CFG_SR2_REG;
                8'd7    : CFG_REG = CFG_VOLL_REG;
                8'd8    : CFG_REG = CFG_VOLR_REG;
                default : CFG_REG = 8'h00;
            endcase
        end
    endfunction

    function [7:0] CFG_DATA;
        input [7:0] idx;
        begin
            case (idx)
                8'd0    : CFG_DATA = CFG_RST_DAT;
                8'd1    : CFG_DATA = CFG_EN1_DAT;
                8'd2    : CFG_DATA = CFG_EN2_DAT;
                8'd3    : CFG_DATA = CFG_FMT_DAT;
                8'd4    : CFG_DATA = CFG_FMD_DAT;
                8'd5    : CFG_DATA = CFG_SR1_DAT;
                8'd6    : CFG_DATA = CFG_SR2_DAT;
                8'd7    : CFG_DATA = CFG_VOLL_DAT;
                8'd8    : CFG_DATA = CFG_VOLR_DAT;
                default : CFG_DATA = 8'h00;
            endcase
        end
    endfunction

    localparam [3:0] ST_IDLE      = 4'd0;
    localparam [3:0] ST_START_H   = 4'd1;
    localparam [3:0] ST_START_L   = 4'd2;
    localparam [3:0] ST_BIT       = 4'd3;
    localparam [3:0] ST_STOP_L    = 4'd4;
    localparam [3:0] ST_STOP_H    = 4'd5;
    localparam [3:0] ST_STOP_HOLD = 4'd6;
    localparam [3:0] ST_GAP       = 4'd7;

    localparam [1:0] TICK_LAST    = 2'd3;

    localparam integer QTR_RAW    = CLK_HZ / (4 * I2C_HZ);
    localparam integer QTR        = (QTR_RAW < 1) ? 1 : QTR_RAW;
    localparam integer QW_RAW     = clog2(QTR + 1);
    localparam integer QW         = (QW_RAW < 1) ? 1 : QW_RAW;
    localparam [QW-1:0] QTR_M1    = QTR - 1;

    localparam integer GW_RAW     = clog2(CFG_GAP + 1);
    localparam integer GW         = (GW_RAW < 1) ? 1 : GW_RAW;
    localparam [GW-1:0] GAP_MAX   = CFG_GAP - 1;

    reg [QW-1:0] div_cnt_q;
    reg [GW-1:0] gap_cnt_q;
    reg [3:0]    state_q;
    reg [1:0]    phase_q;
    reg [1:0]    hold_cnt_q;
    reg [3:0]    bit_idx_q;
    reg [1:0]    byte_sel_q;
    reg [7:0]    cfg_idx_q;
    reg [7:0]    reg_addr_q;
    reg [7:0]    wdata_q;
    reg          scl_q;
    reg          sda_val_q;
    reg          sda_oe_q;
    reg          ack_sample_q;
    reg          started_q;
    reg          txn_cfg_q;
    reg          wr_done_q;
    reg          nack_seen_q;
    reg          error_q;
    reg          cfg_done_q;

    wire tick = (div_cnt_q == QTR_M1);

    wire [7:0] cur_byte = (byte_sel_q == 2'd0) ? {DEV_ADDR, 1'b0} :
                          (byte_sel_q == 2'd1) ? reg_addr_q :
                                                wdata_q;

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            div_cnt_q    <= {QW{1'b0}};
        end else if (tick) begin
            div_cnt_q    <= {QW{1'b0}};
        end else begin
            div_cnt_q    <= div_cnt_q + 1'b1;
        end
    end

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            state_q      <= ST_IDLE;
            phase_q      <= 2'd0;
            hold_cnt_q   <= 2'd0;
            bit_idx_q    <= 4'd0;
            byte_sel_q   <= 2'd0;
            cfg_idx_q    <= 8'd0;
            reg_addr_q   <= 8'h00;
            wdata_q      <= 8'h00;
            scl_q        <= 1'b1;
            sda_val_q    <= 1'b1;
            sda_oe_q     <= 1'b0;
            ack_sample_q <= 1'b1;
            started_q    <= 1'b0;
            txn_cfg_q    <= 1'b0;
            wr_done_q    <= 1'b0;
            nack_seen_q  <= 1'b0;
            error_q      <= 1'b0;
            cfg_done_q   <= 1'b0;
            gap_cnt_q    <= {GW{1'b0}};
        end else begin
            wr_done_q <= 1'b0;

            if (!started_q) begin
                started_q <= 1'b1;
                state_q   <= ST_GAP;
                gap_cnt_q <= {GW{1'b0}};
            end else if (tick) begin
                case (state_q)
                    ST_START_H: begin
                        if (hold_cnt_q == TICK_LAST) begin
                            hold_cnt_q <= 2'd0;
                            scl_q      <= 1'b0;
                            state_q    <= ST_START_L;
                        end else begin
                            hold_cnt_q <= hold_cnt_q + 2'd1;
                        end
                    end
                    ST_START_L: begin
                        if (hold_cnt_q == TICK_LAST) begin
                            hold_cnt_q <= 2'd0;
                            phase_q    <= 2'd0;
                            bit_idx_q  <= 4'd0;
                            state_q    <= ST_BIT;
                        end else begin
                            hold_cnt_q <= hold_cnt_q + 2'd1;
                        end
                    end
                    ST_BIT: begin
                        if (phase_q == 2'd0) begin
                            if (bit_idx_q == 4'd8) begin
                                sda_oe_q  <= 1'b0;
                                sda_val_q <= 1'b1;
                            end else begin
                                sda_val_q <= cur_byte[7 - bit_idx_q];
                                sda_oe_q  <= ~cur_byte[7 - bit_idx_q];
                            end
                        end
                        if (phase_q == 2'd1) begin
                            scl_q <= 1'b1;
                        end else if (phase_q == 2'd2) begin
                            ack_sample_q <= sda_i;
                        end else if (phase_q == 2'd3) begin
                            scl_q <= 1'b0;
                            if (bit_idx_q == 4'd8) begin
                                if (ack_sample_q == 1'b0) begin
                                    if (byte_sel_q == 2'd2) begin
                                        state_q <= ST_STOP_L;
                                    end else begin
                                        byte_sel_q <= byte_sel_q + 2'd1;
                                        bit_idx_q  <= 4'd0;
                                    end
                                end else begin
                                    nack_seen_q <= 1'b1;
                                    error_q     <= 1'b1;
                                    state_q     <= ST_STOP_L;
                                end
                            end else begin
                                bit_idx_q <= bit_idx_q + 4'd1;
                            end
                        end
                        phase_q <= phase_q + 2'd1;
                    end
                    ST_STOP_L: begin
                        if (phase_q == 2'd0) begin
                            sda_oe_q  <= 1'b1;
                            sda_val_q <= 1'b0;
                        end
                        if (hold_cnt_q == TICK_LAST) begin
                            hold_cnt_q <= 2'd0;
                            scl_q      <= 1'b1;
                            state_q    <= ST_STOP_H;
                        end else begin
                            hold_cnt_q <= hold_cnt_q + 2'd1;
                        end
                    end
                    ST_STOP_H: begin
                        if (hold_cnt_q == TICK_LAST) begin
                            hold_cnt_q <= 2'd0;
                            sda_oe_q   <= 1'b0;
                            sda_val_q  <= 1'b1;
                            state_q    <= ST_STOP_HOLD;
                        end else begin
                            hold_cnt_q <= hold_cnt_q + 2'd1;
                        end
                    end
                    ST_STOP_HOLD: begin
                        if (hold_cnt_q == TICK_LAST) begin
                            hold_cnt_q <= 2'd0;
                            phase_q    <= 2'd0;
                            if (txn_cfg_q) begin
                                cfg_idx_q <= cfg_idx_q + 8'd1;
                                gap_cnt_q <= {GW{1'b0}};
                                state_q   <= ST_GAP;
                            end else begin
                                wr_done_q <= 1'b1;
                                state_q   <= ST_IDLE;
                            end
                        end else begin
                            hold_cnt_q <= hold_cnt_q + 2'd1;
                        end
                    end
                    ST_GAP: begin
                        if (gap_cnt_q >= GAP_MAX) begin
                            gap_cnt_q <= {GW{1'b0}};
                            if (cfg_idx_q >= CFG_COUNT) begin
                                cfg_done_q <= 1'b1;
                                state_q    <= ST_IDLE;
                            end else begin
                                reg_addr_q <= CFG_REG(cfg_idx_q);
                                wdata_q    <= CFG_DATA(cfg_idx_q);
                                byte_sel_q <= 2'd0;
                                bit_idx_q  <= 4'd0;
                                phase_q    <= 2'd0;
                                hold_cnt_q <= 2'd0;
                                txn_cfg_q  <= 1'b1;
                                scl_q      <= 1'b1;
                                sda_oe_q   <= 1'b1;
                                sda_val_q  <= 1'b0;
                                state_q    <= ST_START_H;
                            end
                        end
                    end
                    default: begin
                        state_q <= ST_IDLE;
                    end
                endcase
            end else if (state_q == ST_GAP) begin
                if (gap_cnt_q < GAP_MAX) begin
                    gap_cnt_q <= gap_cnt_q + 1'b1;
                end
            end

            if (started_q && wr_req && state_q == ST_IDLE) begin
                reg_addr_q <= reg_addr;
                wdata_q    <= wdata;
                byte_sel_q <= 2'd0;
                bit_idx_q  <= 4'd0;
                phase_q    <= 2'd0;
                hold_cnt_q <= 2'd0;
                txn_cfg_q  <= 1'b0;
                scl_q      <= 1'b1;
                sda_oe_q   <= 1'b1;
                sda_val_q  <= 1'b0;
                state_q    <= ST_START_H;
            end else if (started_q && wr_req) begin
                error_q <= 1'b1;
            end
        end
    end

    assign scl_o     = scl_q;
    assign sda_o     = sda_val_q;
    assign sda_oe    = sda_oe_q;
    assign busy      = (state_q != ST_IDLE);
    assign wr_done   = wr_done_q;
    assign nack_seen = nack_seen_q;
    assign error     = error_q;
    assign cfg_done  = cfg_done_q;

endmodule
