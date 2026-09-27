`timescale 1ns/1ps

module nes_apu_noise (
    input wire clk,
    input wire reset,
    input wire ce,
    input wire quarter,
    input wire half,
    input wire enable,
    input wire enable_wr,
    input wire enable_wr_data,
    input wire reg_we,
    input wire [1:0] reg_index,
    input wire [7:0] reg_din,
    output reg [7:0] reg_dout,
    output reg [7:0] length_cnt,
    output reg [11:0] period,
    output reg [14:0] lfsr,
    output reg mode,
    output reg [3:0] env_decay,
    output reg [3:0] env_div,
    output reg const_volume,
    output reg [3:0] volume,
    output reg halt,
    output reg [3:0] out_level,
    output wire mute
);

reg [3:0] env_period;
reg env_restart;
reg [3:0] period_index;
reg [4:0] len_index;
reg [7:0] len_pending;
reg len_pending_valid;
reg [11:0] timer_cnt;
reg [11:0] timer_reload;

wire length_write_now;
wire [4:0] length_lut_index;
wire [7:0] length_lut_value;
wire timer_reload_now;
wire [3:0] env_level;
wire lfsr_feedback;
wire lfsr_output;

function [11:0] noise_period_ntsc;
    input [3:0] index;
    begin
        case (index)
            4'd0: noise_period_ntsc = 12'd4;
            4'd1: noise_period_ntsc = 12'd8;
            4'd2: noise_period_ntsc = 12'd16;
            4'd3: noise_period_ntsc = 12'd32;
            4'd4: noise_period_ntsc = 12'd64;
            4'd5: noise_period_ntsc = 12'd96;
            4'd6: noise_period_ntsc = 12'd128;
            4'd7: noise_period_ntsc = 12'd160;
            4'd8: noise_period_ntsc = 12'd202;
            4'd9: noise_period_ntsc = 12'd254;
            4'd10: noise_period_ntsc = 12'd380;
            4'd11: noise_period_ntsc = 12'd508;
            4'd12: noise_period_ntsc = 12'd762;
            4'd13: noise_period_ntsc = 12'd1016;
            4'd14: noise_period_ntsc = 12'd2034;
            default: noise_period_ntsc = 12'd4068;
        endcase
    end
endfunction

assign length_write_now = reg_we && (reg_index == 2'd3);
assign length_lut_index = length_write_now ? reg_din[7:3] : len_index;
assign timer_reload_now = (timer_cnt == 12'd0);
assign env_level = const_volume ? volume : env_decay;
assign lfsr_feedback = lfsr[0] ^ lfsr[mode ? 6 : 1];
assign lfsr_output = lfsr[0];
assign mute = (period == 12'd0);

nes_apu_length_lut u_length_lut (
    .index(length_lut_index),
    .value(length_lut_value)
);

always @* begin
    reg_dout = 8'h00;
    case (reg_index)
        2'd0: reg_dout = {1'b0, halt, const_volume, env_period};
        2'd2: reg_dout = {mode, 3'b000, period_index};
        2'd3: reg_dout = {len_index, 3'b000};
        default: reg_dout = 8'h00;
    endcase
    if (reset)
        reg_dout = 8'h00;
end

always @* begin
    if (enable && (length_cnt != 8'd0) && !mute && !lfsr_output)
        out_level = env_level;
    else
        out_level = 4'd0;
end

always @(posedge clk or posedge reset) begin
    if (reset) begin
        halt <= 1'b0;
        const_volume <= 1'b0;
        volume <= 4'd0;
        env_period <= 4'd0;
        env_restart <= 1'b0;
        env_decay <= 4'd0;
        env_div <= 4'd0;
        mode <= 1'b0;
        period_index <= 4'd0;
        period <= 12'd0;
        timer_reload <= 12'd3;
        len_index <= 5'd0;
        len_pending <= 8'd0;
        len_pending_valid <= 1'b0;
        length_cnt <= 8'd0;
        lfsr <= 15'd1;
        timer_cnt <= 12'd0;
    end else begin
        if (reg_we) begin
            case (reg_index)
                2'd0: begin
                    halt <= reg_din[5];
                    const_volume <= reg_din[4];
                    volume <= reg_din[3:0];
                    env_period <= reg_din[3:0];
                    if (reg_din[3:0] == 4'd0)
                        env_div <= 4'd15;
                    else
                        env_div <= reg_din[3:0];
                    env_restart <= 1'b1;
                end
                2'd2: begin
                    mode <= reg_din[7];
                    period_index <= reg_din[3:0];
                    period <= noise_period_ntsc(reg_din[3:0]);
                    timer_reload <= noise_period_ntsc(reg_din[3:0]) - 12'd1;
                end
                2'd3: begin
                    len_index <= reg_din[7:3];
                    env_decay <= 4'd15;
                    if (enable) begin
                        len_pending <= length_lut_value;
                        len_pending_valid <= 1'b1;
                    end
                end
            endcase
        end

        if (ce) begin
            if (len_pending_valid) begin
                length_cnt <= len_pending;
                len_pending_valid <= 1'b0;
            end

            if (timer_cnt != 12'd0) begin
                timer_cnt <= timer_cnt - 12'd1;
            end else begin
                timer_cnt <= timer_reload;
                lfsr <= {lfsr_feedback, lfsr[14:1]};
            end

            if (quarter) begin
                if (env_restart) begin
                    env_decay <= 4'd15;
                    if (env_period == 4'd0)
                        env_div <= 4'd15;
                    else
                        env_div <= env_period;
                    env_restart <= 1'b0;
                end else if (env_div != 4'd0) begin
                    env_div <= env_div - 4'd1;
                end else begin
                    if (env_period == 4'd0)
                        env_div <= 4'd15;
                    else
                        env_div <= env_period;
                    if (env_decay != 4'd0)
                        env_decay <= env_decay - 4'd1;
                    else if (halt)
                        env_decay <= 4'd15;
                end
            end

            if (half) begin
                if ((length_cnt != 8'd0) && !halt && !length_write_now)
                    length_cnt <= length_cnt - 8'd1;
            end
        end

        if (enable_wr && !enable_wr_data)
            length_cnt <= 8'd0;
    end
end

endmodule
