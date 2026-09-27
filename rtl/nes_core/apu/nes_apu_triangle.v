`timescale 1ns/1ps

module nes_apu_triangle (
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
    output reg [10:0] period,
    output reg [4:0] seq_step,
    output reg [6:0] linear_cnt,
    output reg linear_reload_flag,
    output reg [3:0] out_level
);

reg control;
reg [6:0] linear_reload;
reg [10:0] timer_cnt;
reg [4:0] len_index;
reg [7:0] len_pending;
reg len_pending_valid;

wire length_write_now;
wire [4:0] length_lut_index;
wire [7:0] length_lut_value;
wire [10:0] timer_reload;
wire silent;

function [3:0] tri_sequence;
    input [4:0] step;
    begin
        case (step[4])
            1'b0: tri_sequence = 4'd15 - {1'b0, step[3:0]};
            default: tri_sequence = {1'b0, step[3:0]};
        endcase
    end
endfunction

assign length_write_now = reg_we && (reg_index == 2'd3);
assign length_lut_index = length_write_now ? reg_din[7:3] : len_index;
assign timer_reload = (period == 11'd0) ? 11'd0 : (period - 11'd1);
assign silent = !enable || (length_cnt == 8'd0) || (linear_cnt == 7'd0);

nes_apu_length_lut u_length_lut (
    .index(length_lut_index),
    .value(length_lut_value)
);

always @* begin
    reg_dout = 8'h00;
    case (reg_index)
        2'd0: reg_dout = {control, linear_reload};
        2'd1: reg_dout = {3'b000, period[7:0]};
        2'd2: reg_dout = {5'b00000, period[10:8]};
        default: reg_dout = {len_index, period[10:8]};
    endcase
    if (reset)
        reg_dout = 8'h00;
end

always @* begin
    if (silent)
        out_level = 4'd0;
    else
        out_level = tri_sequence(seq_step);
end

always @(posedge clk or posedge reset) begin
    if (reset) begin
        control <= 1'b0;
        linear_reload <= 7'd0;
        linear_cnt <= 7'd0;
        linear_reload_flag <= 1'b0;
        period <= 11'd0;
        timer_cnt <= 11'd0;
        len_index <= 5'd0;
        len_pending <= 8'd0;
        len_pending_valid <= 1'b0;
        length_cnt <= 8'd0;
        seq_step <= 5'd0;
    end else begin
        if (reg_we) begin
            case (reg_index)
                2'd0: begin
                    control <= reg_din[7];
                    linear_reload <= reg_din[6:0];
                end
                2'd1: period[7:0] <= reg_din;
                2'd2: begin
                    period[10:8] <= reg_din[2:0];
                    linear_reload_flag <= 1'b1;
                end
                default: begin
                    len_index <= reg_din[7:3];
                    period[10:8] <= reg_din[2:0];
                    linear_reload_flag <= 1'b1;
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

            if (timer_cnt != 11'd0) begin
                timer_cnt <= timer_cnt - 11'd1;
            end else begin
                timer_cnt <= timer_reload;
                if (!silent)
                    seq_step <= seq_step + 5'd1;
            end

            if (quarter) begin
                if (linear_reload_flag)
                    linear_cnt <= linear_reload;
                else if (linear_cnt != 7'd0)
                    linear_cnt <= linear_cnt - 7'd1;
                if (!control)
                    linear_reload_flag <= 1'b0;
            end

            if (half) begin
                if ((length_cnt != 8'd0) && !control && !length_write_now)
                    length_cnt <= length_cnt - 8'd1;
            end
        end

        if (enable_wr && !enable_wr_data)
            length_cnt <= 8'd0;
    end
end

endmodule
