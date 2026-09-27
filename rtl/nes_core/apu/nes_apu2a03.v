`timescale 1ns/1ps

module nes_apu2a03 (
    input wire clk,
    input wire reset,
    input wire ce,
    input wire ce_sample,
    input wire reg_cs,
    input wire reg_we,
    input wire [4:0] reg_addr,
    input wire [7:0] reg_din,
    output reg [7:0] reg_dout,
    output wire irq,
    output wire dmc_bus_req,
    output wire [15:0] dmc_addr,
    input wire [7:0] dmc_rdata,
    input wire dmc_ack,
    output reg sample_valid,
    output reg [15:0] sample_left,
    output reg [15:0] sample_right,
    output wire [2:0] dbg_frame_phase,
    output wire dbg_frame_irq,
    output wire dbg_dmc_irq,
    output wire [15:0] dbg_frame_count,
    output wire [7:0] dbg_pulse1_length,
    output wire [7:0] dbg_pulse2_length,
    output wire [10:0] dbg_pulse1_period,
    output wire [10:0] dbg_pulse2_period,
    output wire [2:0] dbg_pulse1_duty_step,
    output wire [2:0] dbg_pulse2_duty_step,
    output wire [3:0] dbg_pulse1_level,
    output wire [3:0] dbg_pulse2_level,
    output wire [3:0] dbg_pulse1_env,
    output wire [3:0] dbg_pulse2_env,
    output wire [3:0] dbg_pulse1_env_div,
    output wire [3:0] dbg_pulse2_env_div,
    output wire dbg_pulse1_mute,
    output wire dbg_pulse2_mute,
    output wire [5:0] dbg_pulse_sum,
    output wire [7:0] dbg_tri_length,
    output wire [10:0] dbg_tri_period,
    output wire [4:0] dbg_tri_step,
    output wire [6:0] dbg_tri_linear,
    output wire dbg_tri_reload_flag,
    output wire [3:0] dbg_tri_level,
    output wire [7:0] dbg_noise_length,
    output wire [11:0] dbg_noise_period,
    output wire [14:0] dbg_noise_lfsr,
    output wire dbg_noise_mode,
    output wire dbg_noise_mute,
    output wire [3:0] dbg_noise_level,
    output wire [3:0] dbg_noise_env,
    output wire [3:0] dbg_noise_env_div,
    output wire [15:0] dbg_dmc_sample_addr,
    output wire [15:0] dbg_dmc_current_addr,
    output wire [11:0] dbg_dmc_bytes_remaining,
    output wire [8:0] dbg_dmc_rate_cnt,
    output wire [3:0] dbg_dmc_bits_remaining,
    output wire [7:0] dbg_dmc_bits,
    output wire [7:0] dbg_dmc_sample_buf,
    output wire [6:0] dbg_dmc_output,
    output wire dbg_dmc_silence,
    output wire dbg_dmc_buf_empty,
    output wire dbg_dmc_active,
    output wire [7:0] dbg_tnd_sum,
    output wire [15:0] dbg_mix_pulse,
    output wire [15:0] dbg_mix_tnd,
    output wire [16:0] dbg_mix_sum
);

localparam [15:0] FC_QUARTER_1 = 16'd7456;
localparam [15:0] FC_QUARTER_2 = 16'd14912;
localparam [15:0] FC_QUARTER_3 = 16'd22370;
localparam [15:0] FC_STEP_4 = 16'd29828;
localparam [15:0] FC_STEP_5 = 16'd37280;
localparam [15:0] FC_END_4 = 16'd29829;
localparam [15:0] FC_END_5 = 16'd37281;

reg frame_mode5;
reg frame_inhibit;
reg frame_irq_flag;
reg [15:0] frame_count;
reg [2:0] frame_step;

reg pulse1_enable;
reg pulse2_enable;
reg tri_enable;
reg noise_enable;

wire [7:0] pulse1_dout;
wire [7:0] pulse2_dout;
wire [7:0] tri_dout;
wire [7:0] noise_dout;
wire [7:0] dmc_dout;
wire [7:0] pulse1_length;
wire [7:0] pulse2_length;
wire [10:0] pulse1_period;
wire [10:0] pulse2_period;
wire [2:0] pulse1_duty_step;
wire [2:0] pulse2_duty_step;
wire [3:0] pulse1_level;
wire [3:0] pulse2_level;
wire [3:0] pulse1_env;
wire [3:0] pulse2_env;
wire [3:0] pulse1_env_div;
wire [3:0] pulse2_env_div;
wire pulse1_mute;
wire pulse2_mute;

wire [7:0] tri_length;
wire [10:0] tri_period;
wire [4:0] tri_step;
wire [6:0] tri_linear;
wire tri_reload_flag;
wire [3:0] tri_level;

wire [7:0] noise_length;
wire [11:0] noise_period;
wire [14:0] noise_lfsr;
wire noise_mode;
wire noise_mute;
wire [3:0] noise_level;
wire [3:0] noise_env;
wire [3:0] noise_env_div;

wire [15:0] dmc_sample_addr;
wire [15:0] dmc_current_addr;
wire [11:0] dmc_bytes_remaining;
wire [8:0] dmc_rate_cnt;
wire [3:0] dmc_bits_remaining;
wire [7:0] dmc_bits;
wire [7:0] dmc_sample_buf;
wire [6:0] dmc_output;
wire dmc_silence;
wire dmc_buf_empty;
wire dmc_active;
wire dmc_irq_flag;

wire [5:0] pulse_sum;
wire [7:0] tri_term;
wire [7:0] noise_term;
wire [7:0] tnd_sum;
wire [15:0] mix_pulse;
wire [15:0] mix_tnd;
wire [16:0] mix_sum;
wire [15:0] mixed_sample;

reg frame_quarter;
reg frame_half;
reg frame_irq_set;
reg frame_clear_now;

wire reg_wr_pulse1;
wire reg_wr_pulse2;
wire reg_wr_tri;
wire reg_wr_noise;
wire reg_wr_dmc;
wire reg_wr_status;
wire reg_rd_status;
wire reg_wr_frame;
wire dmc_status_clear;

assign irq = frame_irq_flag | dmc_irq_flag;
assign dbg_frame_irq = frame_irq_flag;
assign dbg_dmc_irq = dmc_irq_flag;
assign dbg_frame_count = frame_count;
assign dbg_frame_phase = frame_step;
assign dbg_pulse1_length = pulse1_length;
assign dbg_pulse2_length = pulse2_length;
assign dbg_pulse1_period = pulse1_period;
assign dbg_pulse2_period = pulse2_period;
assign dbg_pulse1_duty_step = pulse1_duty_step;
assign dbg_pulse2_duty_step = pulse2_duty_step;
assign dbg_pulse1_level = pulse1_level;
assign dbg_pulse2_level = pulse2_level;
assign dbg_pulse1_env = pulse1_env;
assign dbg_pulse2_env = pulse2_env;
assign dbg_pulse1_env_div = pulse1_env_div;
assign dbg_pulse2_env_div = pulse2_env_div;
assign dbg_pulse1_mute = pulse1_mute;
assign dbg_pulse2_mute = pulse2_mute;
assign dbg_pulse_sum = pulse_sum;
assign pulse_sum = {2'b00, pulse1_level} + {2'b00, pulse2_level};

assign dbg_tri_length = tri_length;
assign dbg_tri_period = tri_period;
assign dbg_tri_step = tri_step;
assign dbg_tri_linear = tri_linear;
assign dbg_tri_reload_flag = tri_reload_flag;
assign dbg_tri_level = tri_level;

assign dbg_noise_length = noise_length;
assign dbg_noise_period = noise_period;
assign dbg_noise_lfsr = noise_lfsr;
assign dbg_noise_mode = noise_mode;
assign dbg_noise_mute = noise_mute;
assign dbg_noise_level = noise_level;
assign dbg_noise_env = noise_env;
assign dbg_noise_env_div = noise_env_div;

assign dbg_dmc_sample_addr = dmc_sample_addr;
assign dbg_dmc_current_addr = dmc_current_addr;
assign dbg_dmc_bytes_remaining = dmc_bytes_remaining;
assign dbg_dmc_rate_cnt = dmc_rate_cnt;
assign dbg_dmc_bits_remaining = dmc_bits_remaining;
assign dbg_dmc_bits = dmc_bits;
assign dbg_dmc_sample_buf = dmc_sample_buf;
assign dbg_dmc_output = dmc_output;
assign dbg_dmc_silence = dmc_silence;
assign dbg_dmc_buf_empty = dmc_buf_empty;
assign dbg_dmc_active = dmc_active;

assign tri_term = {2'b00, tri_level, 2'b00} - {4'b0000, tri_level};
assign noise_term = {3'b000, noise_level, 1'b0};
assign tnd_sum = tri_term + noise_term + {1'b0, dmc_output};
assign dbg_tnd_sum = tnd_sum;
assign mix_pulse = pulse_mix_lut(pulse_sum);
assign mix_tnd = tnd_mix_lut(tnd_sum);
assign dbg_mix_pulse = mix_pulse;
assign dbg_mix_tnd = mix_tnd;
assign mix_sum = {1'b0, mix_pulse} + {1'b0, mix_tnd};
assign dbg_mix_sum = mix_sum;
assign mixed_sample = (mix_sum > 17'd32767) ? 16'd32767 : mix_sum[15:0];

assign reg_wr_pulse1 = reg_cs && reg_we && (reg_addr[4:2] == 3'd0);
assign reg_wr_pulse2 = reg_cs && reg_we && (reg_addr[4:2] == 3'd1);
assign reg_wr_tri = reg_cs && reg_we && (reg_addr[4:2] == 3'd2);
assign reg_wr_noise = reg_cs && reg_we && (reg_addr[4:2] == 3'd3);
assign reg_wr_dmc = reg_cs && reg_we && (reg_addr[4:2] == 3'd4);
assign reg_wr_status = reg_cs && reg_we && (reg_addr == 5'h15);
assign reg_rd_status = reg_cs && !reg_we && (reg_addr == 5'h15);
assign reg_wr_frame = reg_cs && reg_we && (reg_addr == 5'h17);
assign dmc_status_clear = reg_wr_status || reg_rd_status;

nes_apu_pulse #(
    .ONE_COMP(1'b1)
) u_pulse1 (
    .clk(clk),
    .reset(reset),
    .ce(ce),
    .quarter(frame_quarter),
    .half(frame_half),
    .enable(pulse1_enable),
    .enable_wr(reg_wr_status),
    .enable_wr_data(reg_din[0]),
    .reg_we(reg_wr_pulse1),
    .reg_index(reg_addr[1:0]),
    .reg_din(reg_din),
    .reg_dout(pulse1_dout),
    .length_cnt(pulse1_length),
    .period(pulse1_period),
    .mute(pulse1_mute),
    .volume(),
    .duty_step(pulse1_duty_step),
    .out_level(pulse1_level),
    .env_decay(pulse1_env),
    .env_div(pulse1_env_div)
);

nes_apu_pulse #(
    .ONE_COMP(1'b0)
) u_pulse2 (
    .clk(clk),
    .reset(reset),
    .ce(ce),
    .quarter(frame_quarter),
    .half(frame_half),
    .enable(pulse2_enable),
    .enable_wr(reg_wr_status),
    .enable_wr_data(reg_din[1]),
    .reg_we(reg_wr_pulse2),
    .reg_index(reg_addr[1:0]),
    .reg_din(reg_din),
    .reg_dout(pulse2_dout),
    .length_cnt(pulse2_length),
    .period(pulse2_period),
    .mute(pulse2_mute),
    .volume(),
    .duty_step(pulse2_duty_step),
    .out_level(pulse2_level),
    .env_decay(pulse2_env),
    .env_div(pulse2_env_div)
);

nes_apu_triangle u_triangle (
    .clk(clk),
    .reset(reset),
    .ce(ce),
    .quarter(frame_quarter),
    .half(frame_half),
    .enable(tri_enable),
    .enable_wr(reg_wr_status),
    .enable_wr_data(reg_din[2]),
    .reg_we(reg_wr_tri),
    .reg_index(reg_addr[1:0]),
    .reg_din(reg_din),
    .reg_dout(tri_dout),
    .length_cnt(tri_length),
    .period(tri_period),
    .seq_step(tri_step),
    .linear_cnt(tri_linear),
    .linear_reload_flag(tri_reload_flag),
    .out_level(tri_level)
);

nes_apu_noise u_noise (
    .clk(clk),
    .reset(reset),
    .ce(ce),
    .quarter(frame_quarter),
    .half(frame_half),
    .enable(noise_enable),
    .enable_wr(reg_wr_status),
    .enable_wr_data(reg_din[3]),
    .reg_we(reg_wr_noise),
    .reg_index(reg_addr[1:0]),
    .reg_din(reg_din),
    .reg_dout(noise_dout),
    .length_cnt(noise_length),
    .period(noise_period),
    .lfsr(noise_lfsr),
    .mode(noise_mode),
    .const_volume(),
    .volume(),
    .halt(),
    .env_decay(noise_env),
    .env_div(noise_env_div),
    .out_level(noise_level),
    .mute(noise_mute)
);

nes_apu_dmc u_dmc (
    .clk(clk),
    .reset(reset),
    .ce(ce),
    .status_wr(reg_wr_status),
    .status_wr_data(reg_din),
    .status_clear(dmc_status_clear),
    .reg_we(reg_wr_dmc),
    .reg_index(reg_addr[1:0]),
    .reg_din(reg_din),
    .reg_dout(dmc_dout),
    .dmc_bus_req(dmc_bus_req),
    .dmc_addr(dmc_addr),
    .dmc_rdata(dmc_rdata),
    .dmc_ack(dmc_ack),
    .irq_flag(dmc_irq_flag),
    .sample_addr(dmc_sample_addr),
    .current_addr(dmc_current_addr),
    .bytes_remaining(dmc_bytes_remaining),
    .rate_cnt(dmc_rate_cnt),
    .bits_remaining(dmc_bits_remaining),
    .bits(dmc_bits),
    .sample_buf(dmc_sample_buf),
    .output_level(dmc_output),
    .silence(dmc_silence),
    .buf_empty(dmc_buf_empty),
    .active(dmc_active)
);

function [15:0] pulse_mix_lut;
    input [5:0] index;
    begin
        case (index)
            6'd0: pulse_mix_lut = 16'd0;
            6'd1: pulse_mix_lut = 16'd382;
            6'd2: pulse_mix_lut = 16'd754;
            6'd3: pulse_mix_lut = 16'd1118;
            6'd4: pulse_mix_lut = 16'd1474;
            6'd5: pulse_mix_lut = 16'd1821;
            6'd6: pulse_mix_lut = 16'd2160;
            6'd7: pulse_mix_lut = 16'd2491;
            6'd8: pulse_mix_lut = 16'd2815;
            6'd9: pulse_mix_lut = 16'd3132;
            6'd10: pulse_mix_lut = 16'd3442;
            6'd11: pulse_mix_lut = 16'd3745;
            6'd12: pulse_mix_lut = 16'd4042;
            6'd13: pulse_mix_lut = 16'd4332;
            6'd14: pulse_mix_lut = 16'd4616;
            6'd15: pulse_mix_lut = 16'd4895;
            6'd16: pulse_mix_lut = 16'd5167;
            6'd17: pulse_mix_lut = 16'd5434;
            6'd18: pulse_mix_lut = 16'd5696;
            6'd19: pulse_mix_lut = 16'd5953;
            6'd20: pulse_mix_lut = 16'd6204;
            6'd21: pulse_mix_lut = 16'd6450;
            6'd22: pulse_mix_lut = 16'd6692;
            6'd23: pulse_mix_lut = 16'd6929;
            6'd24: pulse_mix_lut = 16'd7162;
            6'd25: pulse_mix_lut = 16'd7390;
            6'd26: pulse_mix_lut = 16'd7614;
            6'd27: pulse_mix_lut = 16'd7834;
            6'd28: pulse_mix_lut = 16'd8050;
            6'd29: pulse_mix_lut = 16'd8262;
            6'd30: pulse_mix_lut = 16'd8470;
            default: pulse_mix_lut = 16'd8470;
        endcase
    end
endfunction

function [15:0] tnd_mix_lut;
    input [7:0] index;
    begin
        case (index)
            8'd0: tnd_mix_lut = 16'd0;
            8'd1: tnd_mix_lut = 16'd220;
            8'd2: tnd_mix_lut = 16'd437;
            8'd3: tnd_mix_lut = 16'd653;
            8'd4: tnd_mix_lut = 16'd867;
            8'd5: tnd_mix_lut = 16'd1080;
            8'd6: tnd_mix_lut = 16'd1291;
            8'd7: tnd_mix_lut = 16'd1500;
            8'd8: tnd_mix_lut = 16'd1707;
            8'd9: tnd_mix_lut = 16'd1913;
            8'd10: tnd_mix_lut = 16'd2117;
            8'd11: tnd_mix_lut = 16'd2320;
            8'd12: tnd_mix_lut = 16'd2521;
            8'd13: tnd_mix_lut = 16'd2720;
            8'd14: tnd_mix_lut = 16'd2918;
            8'd15: tnd_mix_lut = 16'd3115;
            8'd16: tnd_mix_lut = 16'd3309;
            8'd17: tnd_mix_lut = 16'd3503;
            8'd18: tnd_mix_lut = 16'd3694;
            8'd19: tnd_mix_lut = 16'd3885;
            8'd20: tnd_mix_lut = 16'd4074;
            8'd21: tnd_mix_lut = 16'd4261;
            8'd22: tnd_mix_lut = 16'd4447;
            8'd23: tnd_mix_lut = 16'd4632;
            8'd24: tnd_mix_lut = 16'd4815;
            8'd25: tnd_mix_lut = 16'd4997;
            8'd26: tnd_mix_lut = 16'd5178;
            8'd27: tnd_mix_lut = 16'd5357;
            8'd28: tnd_mix_lut = 16'd5535;
            8'd29: tnd_mix_lut = 16'd5712;
            8'd30: tnd_mix_lut = 16'd5887;
            8'd31: tnd_mix_lut = 16'd6061;
            8'd32: tnd_mix_lut = 16'd6234;
            8'd33: tnd_mix_lut = 16'd6406;
            8'd34: tnd_mix_lut = 16'd6576;
            8'd35: tnd_mix_lut = 16'd6745;
            8'd36: tnd_mix_lut = 16'd6913;
            8'd37: tnd_mix_lut = 16'd7079;
            8'd38: tnd_mix_lut = 16'd7245;
            8'd39: tnd_mix_lut = 16'd7409;
            8'd40: tnd_mix_lut = 16'd7572;
            8'd41: tnd_mix_lut = 16'd7734;
            8'd42: tnd_mix_lut = 16'd7895;
            8'd43: tnd_mix_lut = 16'd8055;
            8'd44: tnd_mix_lut = 16'd8214;
            8'd45: tnd_mix_lut = 16'd8371;
            8'd46: tnd_mix_lut = 16'd8528;
            8'd47: tnd_mix_lut = 16'd8683;
            8'd48: tnd_mix_lut = 16'd8837;
            8'd49: tnd_mix_lut = 16'd8991;
            8'd50: tnd_mix_lut = 16'd9143;
            8'd51: tnd_mix_lut = 16'd9294;
            8'd52: tnd_mix_lut = 16'd9444;
            8'd53: tnd_mix_lut = 16'd9593;
            8'd54: tnd_mix_lut = 16'd9741;
            8'd55: tnd_mix_lut = 16'd9888;
            8'd56: tnd_mix_lut = 16'd10035;
            8'd57: tnd_mix_lut = 16'd10180;
            8'd58: tnd_mix_lut = 16'd10324;
            8'd59: tnd_mix_lut = 16'd10467;
            8'd60: tnd_mix_lut = 16'd10610;
            8'd61: tnd_mix_lut = 16'd10751;
            8'd62: tnd_mix_lut = 16'd10891;
            8'd63: tnd_mix_lut = 16'd11031;
            8'd64: tnd_mix_lut = 16'd11170;
            8'd65: tnd_mix_lut = 16'd11307;
            8'd66: tnd_mix_lut = 16'd11444;
            8'd67: tnd_mix_lut = 16'd11580;
            8'd68: tnd_mix_lut = 16'd11715;
            8'd69: tnd_mix_lut = 16'd11849;
            8'd70: tnd_mix_lut = 16'd11983;
            8'd71: tnd_mix_lut = 16'd12115;
            8'd72: tnd_mix_lut = 16'd12247;
            8'd73: tnd_mix_lut = 16'd12378;
            8'd74: tnd_mix_lut = 16'd12508;
            8'd75: tnd_mix_lut = 16'd12637;
            8'd76: tnd_mix_lut = 16'd12765;
            8'd77: tnd_mix_lut = 16'd12893;
            8'd78: tnd_mix_lut = 16'd13020;
            8'd79: tnd_mix_lut = 16'd13146;
            8'd80: tnd_mix_lut = 16'd13271;
            8'd81: tnd_mix_lut = 16'd13395;
            8'd82: tnd_mix_lut = 16'd13519;
            8'd83: tnd_mix_lut = 16'd13642;
            8'd84: tnd_mix_lut = 16'd13764;
            8'd85: tnd_mix_lut = 16'd13886;
            8'd86: tnd_mix_lut = 16'd14006;
            8'd87: tnd_mix_lut = 16'd14126;
            8'd88: tnd_mix_lut = 16'd14246;
            8'd89: tnd_mix_lut = 16'd14364;
            8'd90: tnd_mix_lut = 16'd14482;
            8'd91: tnd_mix_lut = 16'd14599;
            8'd92: tnd_mix_lut = 16'd14715;
            8'd93: tnd_mix_lut = 16'd14831;
            8'd94: tnd_mix_lut = 16'd14946;
            8'd95: tnd_mix_lut = 16'd15061;
            8'd96: tnd_mix_lut = 16'd15174;
            8'd97: tnd_mix_lut = 16'd15287;
            8'd98: tnd_mix_lut = 16'd15400;
            8'd99: tnd_mix_lut = 16'd15511;
            8'd100: tnd_mix_lut = 16'd15622;
            8'd101: tnd_mix_lut = 16'd15733;
            8'd102: tnd_mix_lut = 16'd15842;
            8'd103: tnd_mix_lut = 16'd15952;
            8'd104: tnd_mix_lut = 16'd16060;
            8'd105: tnd_mix_lut = 16'd16168;
            8'd106: tnd_mix_lut = 16'd16275;
            8'd107: tnd_mix_lut = 16'd16382;
            8'd108: tnd_mix_lut = 16'd16488;
            8'd109: tnd_mix_lut = 16'd16593;
            8'd110: tnd_mix_lut = 16'd16698;
            8'd111: tnd_mix_lut = 16'd16802;
            8'd112: tnd_mix_lut = 16'd16906;
            8'd113: tnd_mix_lut = 16'd17009;
            8'd114: tnd_mix_lut = 16'd17112;
            8'd115: tnd_mix_lut = 16'd17213;
            8'd116: tnd_mix_lut = 16'd17315;
            8'd117: tnd_mix_lut = 16'd17416;
            8'd118: tnd_mix_lut = 16'd17516;
            8'd119: tnd_mix_lut = 16'd17616;
            8'd120: tnd_mix_lut = 16'd17715;
            8'd121: tnd_mix_lut = 16'd17813;
            8'd122: tnd_mix_lut = 16'd17911;
            8'd123: tnd_mix_lut = 16'd18009;
            8'd124: tnd_mix_lut = 16'd18106;
            8'd125: tnd_mix_lut = 16'd18202;
            8'd126: tnd_mix_lut = 16'd18298;
            8'd127: tnd_mix_lut = 16'd18394;
            8'd128: tnd_mix_lut = 16'd18489;
            8'd129: tnd_mix_lut = 16'd18583;
            8'd130: tnd_mix_lut = 16'd18677;
            8'd131: tnd_mix_lut = 16'd18770;
            8'd132: tnd_mix_lut = 16'd18863;
            8'd133: tnd_mix_lut = 16'd18955;
            8'd134: tnd_mix_lut = 16'd19047;
            8'd135: tnd_mix_lut = 16'd19139;
            8'd136: tnd_mix_lut = 16'd19230;
            8'd137: tnd_mix_lut = 16'd19320;
            8'd138: tnd_mix_lut = 16'd19410;
            8'd139: tnd_mix_lut = 16'd19500;
            8'd140: tnd_mix_lut = 16'd19589;
            8'd141: tnd_mix_lut = 16'd19677;
            8'd142: tnd_mix_lut = 16'd19765;
            8'd143: tnd_mix_lut = 16'd19853;
            8'd144: tnd_mix_lut = 16'd19940;
            8'd145: tnd_mix_lut = 16'd20027;
            8'd146: tnd_mix_lut = 16'd20113;
            8'd147: tnd_mix_lut = 16'd20199;
            8'd148: tnd_mix_lut = 16'd20285;
            8'd149: tnd_mix_lut = 16'd20370;
            8'd150: tnd_mix_lut = 16'd20454;
            8'd151: tnd_mix_lut = 16'd20538;
            8'd152: tnd_mix_lut = 16'd20622;
            8'd153: tnd_mix_lut = 16'd20705;
            8'd154: tnd_mix_lut = 16'd20788;
            8'd155: tnd_mix_lut = 16'd20871;
            8'd156: tnd_mix_lut = 16'd20953;
            8'd157: tnd_mix_lut = 16'd21034;
            8'd158: tnd_mix_lut = 16'd21116;
            8'd159: tnd_mix_lut = 16'd21196;
            8'd160: tnd_mix_lut = 16'd21277;
            8'd161: tnd_mix_lut = 16'd21357;
            8'd162: tnd_mix_lut = 16'd21437;
            8'd163: tnd_mix_lut = 16'd21516;
            8'd164: tnd_mix_lut = 16'd21595;
            8'd165: tnd_mix_lut = 16'd21673;
            8'd166: tnd_mix_lut = 16'd21751;
            8'd167: tnd_mix_lut = 16'd21829;
            8'd168: tnd_mix_lut = 16'd21906;
            8'd169: tnd_mix_lut = 16'd21983;
            8'd170: tnd_mix_lut = 16'd22060;
            8'd171: tnd_mix_lut = 16'd22136;
            8'd172: tnd_mix_lut = 16'd22212;
            8'd173: tnd_mix_lut = 16'd22287;
            8'd174: tnd_mix_lut = 16'd22362;
            8'd175: tnd_mix_lut = 16'd22437;
            8'd176: tnd_mix_lut = 16'd22511;
            8'd177: tnd_mix_lut = 16'd22586;
            8'd178: tnd_mix_lut = 16'd22659;
            8'd179: tnd_mix_lut = 16'd22733;
            8'd180: tnd_mix_lut = 16'd22806;
            8'd181: tnd_mix_lut = 16'd22878;
            8'd182: tnd_mix_lut = 16'd22950;
            8'd183: tnd_mix_lut = 16'd23022;
            8'd184: tnd_mix_lut = 16'd23094;
            8'd185: tnd_mix_lut = 16'd23165;
            8'd186: tnd_mix_lut = 16'd23236;
            8'd187: tnd_mix_lut = 16'd23307;
            8'd188: tnd_mix_lut = 16'd23377;
            8'd189: tnd_mix_lut = 16'd23447;
            8'd190: tnd_mix_lut = 16'd23517;
            8'd191: tnd_mix_lut = 16'd23586;
            8'd192: tnd_mix_lut = 16'd23655;
            8'd193: tnd_mix_lut = 16'd23724;
            8'd194: tnd_mix_lut = 16'd23792;
            8'd195: tnd_mix_lut = 16'd23860;
            8'd196: tnd_mix_lut = 16'd23928;
            8'd197: tnd_mix_lut = 16'd23996;
            8'd198: tnd_mix_lut = 16'd24063;
            8'd199: tnd_mix_lut = 16'd24130;
            8'd200: tnd_mix_lut = 16'd24196;
            8'd201: tnd_mix_lut = 16'd24262;
            8'd202: tnd_mix_lut = 16'd24328;
            default: tnd_mix_lut = 16'd0;
        endcase
    end
endfunction

always @* begin
    frame_quarter = 1'b0;
    frame_half = 1'b0;
    frame_irq_set = 1'b0;
    if (frame_count == FC_QUARTER_1) begin
        frame_quarter = 1'b1;
    end else if (frame_count == FC_QUARTER_2) begin
        frame_quarter = 1'b1;
        frame_half = 1'b1;
    end else if (frame_count == FC_QUARTER_3) begin
        frame_quarter = 1'b1;
    end else if (frame_count == FC_STEP_4) begin
        if (!frame_mode5) begin
            frame_quarter = 1'b1;
            frame_half = 1'b1;
            frame_irq_set = 1'b1;
        end
    end else if (frame_count == FC_STEP_5) begin
        if (frame_mode5) begin
            frame_quarter = 1'b1;
            frame_half = 1'b1;
        end
    end
end

always @* begin
    frame_clear_now = 1'b0;
    if (reg_cs) begin
        if (reg_we) begin
            if (reg_addr == 5'h15)
                frame_clear_now = 1'b1;
            if ((reg_addr == 5'h17) && reg_din[6])
                frame_clear_now = 1'b1;
        end else begin
            if (reg_addr == 5'h15)
                frame_clear_now = 1'b1;
        end
    end
end

always @* begin
    reg_dout = 8'h00;
    if (reg_cs && !reset) begin
        case (reg_addr[4:2])
            3'd0: reg_dout = pulse1_dout;
            3'd1: reg_dout = pulse2_dout;
            3'd2: reg_dout = tri_dout;
            3'd3: reg_dout = noise_dout;
            3'd4: reg_dout = dmc_dout;
            3'd5: begin
                if (reg_addr == 5'h15)
                    reg_dout = {dmc_irq_flag, frame_irq_flag, 1'b0,
                                (dmc_bytes_remaining != 12'd0),
                                (noise_length != 8'd0),
                                (tri_length != 8'd0),
                                (pulse2_length != 8'd0),
                                (pulse1_length != 8'd0)};
            end
            default: reg_dout = 8'h00;
        endcase
    end
end

always @(posedge clk or posedge reset) begin
    if (reset) begin
        frame_mode5 <= 1'b0;
        frame_inhibit <= 1'b0;
        frame_irq_flag <= 1'b0;
        frame_count <= 16'd0;
        frame_step <= 3'd0;
        pulse1_enable <= 1'b0;
        pulse2_enable <= 1'b0;
        tri_enable <= 1'b0;
        noise_enable <= 1'b0;
        sample_valid <= 1'b0;
        sample_left <= 16'd0;
        sample_right <= 16'd0;
    end else begin
        if (reg_wr_status) begin
            pulse1_enable <= reg_din[0];
            pulse2_enable <= reg_din[1];
            tri_enable <= reg_din[2];
            noise_enable <= reg_din[3];
        end

        if (reg_wr_frame) begin
            frame_mode5 <= reg_din[7];
            frame_inhibit <= reg_din[6];
        end

        if (reg_wr_frame) begin
            frame_count <= 16'd0;
            frame_step <= 3'd0;
        end else if (ce) begin
            if (frame_count == FC_QUARTER_1) begin
                frame_count <= frame_count + 16'd1;
                frame_step <= 3'd1;
            end else if (frame_count == FC_QUARTER_2) begin
                frame_count <= frame_count + 16'd1;
                frame_step <= 3'd2;
            end else if (frame_count == FC_QUARTER_3) begin
                frame_count <= frame_count + 16'd1;
                frame_step <= 3'd3;
            end else if (frame_count == FC_STEP_4) begin
                frame_step <= frame_mode5 ? 3'd4 : 3'd0;
                frame_count <= FC_END_4;
            end else if (frame_count == FC_STEP_5) begin
                frame_step <= 3'd0;
                frame_count <= FC_END_5;
            end else if (!frame_mode5 && (frame_count == FC_END_4)) begin
                frame_step <= 3'd0;
                frame_count <= 16'd0;
            end else if (frame_mode5 && (frame_count == FC_END_5)) begin
                frame_step <= 3'd0;
                frame_count <= 16'd0;
            end else begin
                frame_count <= frame_count + 16'd1;
            end

            if (frame_irq_set && !frame_inhibit)
                frame_irq_flag <= 1'b1;
        end

        if (frame_clear_now)
            frame_irq_flag <= 1'b0;

        if (ce && ce_sample) begin
            sample_valid <= 1'b1;
            sample_left <= mixed_sample;
            sample_right <= mixed_sample;
        end else begin
            sample_valid <= 1'b0;
        end
    end
end

endmodule
