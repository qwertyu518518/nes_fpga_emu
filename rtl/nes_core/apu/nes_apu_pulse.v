`timescale 1ns/1ps

module nes_apu_pulse #(
    parameter ONE_COMP = 1'b0
)(
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
    output wire mute,
    output wire volume,
    output reg [2:0] duty_step,
    output reg [3:0] out_level,
    output reg [3:0] env_decay,
    output reg [3:0] env_div
);

reg [1:0] duty;
reg halt;
reg const_volume;
reg [3:0] vol;
reg [3:0] env_period;
reg env_restart;

reg [4:0] len_index;
reg [7:0] len_pending;
reg len_pending_valid;

reg sweep_enabled;
reg [2:0] sweep_period;
reg sweep_neg;
reg [2:0] sweep_shift;
reg [3:0] sweep_div_reload;
reg [3:0] sweep_div;
reg sweep_reload;

reg [10:0] timer_cnt;
reg [3:0] timer_prescale;

reg signed [13:0] sweep_period_signed;
reg signed [13:0] sweep_change;
reg signed [13:0] sweep_target;
reg [10:0] sweep_target_period;
wire sweep_mute;

wire [3:0] env_level;
wire length_write_now;
wire duty_out;

wire [4:0] length_lut_index;
wire [7:0] length_lut_value;

function duty_bit;
    input [1:0] duty_sel;
    input [2:0] step;
    begin
        case (duty_sel)
            2'd0: duty_bit = (step == 3'd1);
            2'd1: duty_bit = (step == 3'd1) || (step == 3'd2);
            2'd2: duty_bit = (step >= 3'd1) && (step <= 3'd4);
            default: duty_bit = (step == 3'd0) || (step >= 3'd3);
        endcase
    end
endfunction

assign duty_out = duty_bit(duty, duty_step);
assign env_level = const_volume ? vol : env_decay;
assign volume = env_level;
assign length_write_now = reg_we && (reg_index == 2'd3);
assign mute = sweep_mute;
assign sweep_mute = (period < 11'd8) || (sweep_target > 14'sd2047);
assign length_lut_index = length_write_now ? reg_din[7:3] : len_index;

nes_apu_length_lut u_length_lut (
    .index(length_lut_index),
    .value(length_lut_value)
);
always @* begin
    sweep_period_signed = $signed({3'b000, period});
    sweep_change = sweep_period_signed >>> sweep_shift;
    if (sweep_neg) begin
        if (ONE_COMP)
            sweep_target = sweep_period_signed - sweep_change - 14'sd1;
        else
            sweep_target = sweep_period_signed - sweep_change;
    end else begin
        sweep_target = sweep_period_signed + sweep_change;
    end
    if (sweep_target < 0)
        sweep_target_period = 11'd0;
    else if (sweep_target > 14'sd2047)
        sweep_target_period = 11'd2047;
    else
        sweep_target_period = sweep_target[10:0];
end

always @* begin
    reg_dout = 8'h00;
    case (reg_index)
        2'd0: reg_dout = {duty, halt, const_volume, vol};
        2'd1: reg_dout = {sweep_enabled, sweep_period, sweep_neg, sweep_shift};
        2'd2: reg_dout = {3'b000, period[7:0]};
        default: reg_dout = {len_index, period[10:8]};
    endcase
    if (reset)
        reg_dout = 8'h00;
end

always @* begin
    if (enable && (length_cnt != 8'd0) && !sweep_mute && duty_out)
        out_level = env_level;
    else
        out_level = 4'd0;
end

always @(posedge clk or posedge reset) begin
    if (reset) begin
        duty <= 2'd0;
        halt <= 1'b0;
        const_volume <= 1'b0;
        vol <= 4'd0;
        env_period <= 4'd0;
        env_restart <= 1'b0;
        env_decay <= 4'd0;
        env_div <= 4'd0;
        len_index <= 5'd0;
        len_pending <= 8'd0;
        len_pending_valid <= 1'b0;
        length_cnt <= 8'd0;
        sweep_enabled <= 1'b0;
        sweep_period <= 3'd0;
        sweep_neg <= 1'b0;
        sweep_shift <= 3'd0;
        sweep_div_reload <= 4'd1;
        sweep_div <= 4'd0;
        sweep_reload <= 1'b0;
        period <= 11'd0;
        timer_cnt <= 11'd0;
        timer_prescale <= 4'd0;
        duty_step <= 3'd0;
    end else begin
        if (reg_we) begin
            case (reg_index)
                2'd0: begin
                    duty <= reg_din[7:6];
                    halt <= reg_din[5];
                    const_volume <= reg_din[4];
                    vol <= reg_din[3:0];
                    env_period <= reg_din[3:0];
                    if (reg_din[3:0] == 4'd0)
                        env_div <= 4'd15;
                    else
                        env_div <= reg_din[3:0];
                    env_restart <= 1'b1;
                end
                2'd1: begin
                    sweep_enabled <= reg_din[7];
                    sweep_period <= reg_din[6:4];
                    sweep_neg <= reg_din[3];
                    sweep_shift <= reg_din[2:0];
                    sweep_div_reload <= {1'b0, reg_din[6:4]} + 4'd1;
                    sweep_div <= 4'd0;
                    sweep_reload <= 1'b1;
                end
                2'd2: period[7:0] <= reg_din;
                default: begin
                    len_index <= reg_din[7:3];
                    period[10:8] <= reg_din[2:0];
                    duty_step <= 3'd0;
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

            if (timer_prescale == 4'd15) begin
                timer_prescale <= 4'd0;
                if (timer_cnt == 11'd0) begin
                    timer_cnt <= period;
                    duty_step <= duty_step + 3'd1;
                end else begin
                    timer_cnt <= timer_cnt - 11'd1;
                end
            end else begin
                timer_prescale <= timer_prescale + 4'd1;
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
                if (sweep_reload) begin
                    sweep_reload <= 1'b0;
                    sweep_div <= 4'd0;
                end else if (sweep_div != 4'd0) begin
                    sweep_div <= sweep_div - 4'd1;
                end else begin
                    sweep_div <= sweep_div_reload;
                    if (sweep_enabled && (sweep_shift != 3'd0) && !sweep_mute)
                        period <= sweep_target_period;
                end

                if ((length_cnt != 8'd0) && !halt && !length_write_now)
                    length_cnt <= length_cnt - 8'd1;
            end
        end

        if (enable_wr && !enable_wr_data)
            length_cnt <= 8'd0;
    end
end

endmodule
