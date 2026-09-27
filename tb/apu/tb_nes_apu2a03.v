`timescale 1ns/1ps

module tb_nes_apu2a03;

reg clk;
reg reset;
reg ce;
reg ce_sample;
reg reg_cs;
reg reg_we;
reg [4:0] reg_addr;
reg [7:0] reg_din;
wire [7:0] reg_dout;
wire irq;
wire dmc_bus_req;
wire [15:0] dmc_addr;
reg [7:0] dmc_rdata;
reg dmc_ack;
wire sample_valid;
wire [15:0] sample_left;
wire [15:0] sample_right;
wire [2:0] dbg_frame_phase;
wire dbg_frame_irq;
wire dbg_dmc_irq;
wire [15:0] dbg_frame_count;
wire [7:0] dbg_pulse1_length;
wire [7:0] dbg_pulse2_length;
wire [10:0] dbg_pulse1_period;
wire [10:0] dbg_pulse2_period;
wire [2:0] dbg_pulse1_duty_step;
wire [2:0] dbg_pulse2_duty_step;
wire [3:0] dbg_pulse1_level;
wire [3:0] dbg_pulse2_level;
wire [3:0] dbg_pulse1_env;
wire [3:0] dbg_pulse2_env;
wire [3:0] dbg_pulse1_env_div;
wire [3:0] dbg_pulse2_env_div;
wire dbg_pulse1_mute;
wire dbg_pulse2_mute;
wire [5:0] dbg_pulse_sum;
wire [7:0] dbg_tri_length;
wire [10:0] dbg_tri_period;
wire [4:0] dbg_tri_step;
wire [6:0] dbg_tri_linear;
wire dbg_tri_reload_flag;
wire [3:0] dbg_tri_level;
wire [7:0] dbg_noise_length;
wire [11:0] dbg_noise_period;
wire [14:0] dbg_noise_lfsr;
wire dbg_noise_mode;
wire dbg_noise_mute;
wire [3:0] dbg_noise_level;
wire [3:0] dbg_noise_env;
wire [3:0] dbg_noise_env_div;
wire [15:0] dbg_dmc_sample_addr;
wire [15:0] dbg_dmc_current_addr;
wire [11:0] dbg_dmc_bytes_remaining;
wire [8:0] dbg_dmc_rate_cnt;
wire [3:0] dbg_dmc_bits_remaining;
wire [7:0] dbg_dmc_bits;
wire [7:0] dbg_dmc_sample_buf;
wire [6:0] dbg_dmc_output;
wire dbg_dmc_silence;
wire dbg_dmc_buf_empty;
wire dbg_dmc_active;
wire [7:0] dbg_tnd_sum;
wire [15:0] dbg_mix_pulse;
wire [15:0] dbg_mix_tnd;
wire [16:0] dbg_mix_sum;

integer i;
integer j;
integer k;
integer guard;
integer duty_idx;
integer ce_edges;
integer mark;
integer clamp_hits;
integer mixer_checks;
reg [7:0] rd_tmp;
reg [7:0] rd2;
reg [3:0] exp_env;
reg [2:0] prev_step;
reg [3:0] duty_level_log [0:7];
reg [2:0] duty_step_log [0:7];
reg [15:0] duty_sample_log [0:7];
reg [15:0] snap_phase;
reg [15:0] snap_count;
reg [7:0] snap_len1;
reg [7:0] snap_len2;
reg [10:0] snap_per1;
reg [2:0] snap_dst1;
reg [3:0] snap_lvl1;
reg [3:0] snap_env1;
reg [3:0] snap_edv1;
reg snap_irq;
reg snap_mute1;
reg dmc_pending;
reg dmc_grant_enable;

reg [14:0] lfsr_model;
reg [4:0] tri_step_model;
reg [6:0] dmc_level_exp;
reg [6:0] pre_level;
reg pre_byte;
reg pre_silence;
reg [15:0] snap_sample;

nes_apu2a03 dut(
    .clk(clk),
    .reset(reset),
    .ce(ce),
    .ce_sample(ce_sample),
    .reg_cs(reg_cs),
    .reg_we(reg_we),
    .reg_addr(reg_addr),
    .reg_din(reg_din),
    .reg_dout(reg_dout),
    .irq(irq),
    .dmc_bus_req(dmc_bus_req),
    .dmc_addr(dmc_addr),
    .dmc_rdata(dmc_rdata),
    .dmc_ack(dmc_ack),
    .sample_valid(sample_valid),
    .sample_left(sample_left),
    .sample_right(sample_right),
    .dbg_frame_phase(dbg_frame_phase),
    .dbg_frame_irq(dbg_frame_irq),
    .dbg_dmc_irq(dbg_dmc_irq),
    .dbg_frame_count(dbg_frame_count),
    .dbg_pulse1_length(dbg_pulse1_length),
    .dbg_pulse2_length(dbg_pulse2_length),
    .dbg_pulse1_period(dbg_pulse1_period),
    .dbg_pulse2_period(dbg_pulse2_period),
    .dbg_pulse1_duty_step(dbg_pulse1_duty_step),
    .dbg_pulse2_duty_step(dbg_pulse2_duty_step),
    .dbg_pulse1_level(dbg_pulse1_level),
    .dbg_pulse2_level(dbg_pulse2_level),
    .dbg_pulse1_env(dbg_pulse1_env),
    .dbg_pulse2_env(dbg_pulse2_env),
    .dbg_pulse1_env_div(dbg_pulse1_env_div),
    .dbg_pulse2_env_div(dbg_pulse2_env_div),
    .dbg_pulse1_mute(dbg_pulse1_mute),
    .dbg_pulse2_mute(dbg_pulse2_mute),
    .dbg_pulse_sum(dbg_pulse_sum),
    .dbg_tri_length(dbg_tri_length),
    .dbg_tri_period(dbg_tri_period),
    .dbg_tri_step(dbg_tri_step),
    .dbg_tri_linear(dbg_tri_linear),
    .dbg_tri_reload_flag(dbg_tri_reload_flag),
    .dbg_tri_level(dbg_tri_level),
    .dbg_noise_length(dbg_noise_length),
    .dbg_noise_period(dbg_noise_period),
    .dbg_noise_lfsr(dbg_noise_lfsr),
    .dbg_noise_mode(dbg_noise_mode),
    .dbg_noise_mute(dbg_noise_mute),
    .dbg_noise_level(dbg_noise_level),
    .dbg_noise_env(dbg_noise_env),
    .dbg_noise_env_div(dbg_noise_env_div),
    .dbg_dmc_sample_addr(dbg_dmc_sample_addr),
    .dbg_dmc_current_addr(dbg_dmc_current_addr),
    .dbg_dmc_bytes_remaining(dbg_dmc_bytes_remaining),
    .dbg_dmc_rate_cnt(dbg_dmc_rate_cnt),
    .dbg_dmc_bits_remaining(dbg_dmc_bits_remaining),
    .dbg_dmc_bits(dbg_dmc_bits),
    .dbg_dmc_sample_buf(dbg_dmc_sample_buf),
    .dbg_dmc_output(dbg_dmc_output),
    .dbg_dmc_silence(dbg_dmc_silence),
    .dbg_dmc_buf_empty(dbg_dmc_buf_empty),
    .dbg_dmc_active(dbg_dmc_active),
    .dbg_tnd_sum(dbg_tnd_sum),
    .dbg_mix_pulse(dbg_mix_pulse),
    .dbg_mix_tnd(dbg_mix_tnd),
    .dbg_mix_sum(dbg_mix_sum)
);

always #5 clk = !clk;

always @(posedge clk) begin
    if (!reset && ce)
        ce_edges = ce_edges + 1;
end

always @(posedge clk) begin
    if (reset)
        dmc_pending = 1'b0;
    else begin
        if (dmc_ack)
            dmc_pending = 1'b0;
        else if (dmc_bus_req)
            dmc_pending = 1'b1;
    end
end

assign dmc_ack = dmc_grant_enable && dmc_pending && dmc_bus_req;
assign dmc_rdata = dmc_sample_byte(dmc_addr);

function [7:0] dmc_sample_byte;
    input [15:0] address;
    begin
        dmc_sample_byte = address[7:0] ^ 8'h5A;
    end
endfunction

function [15:0] ref_pulse_lut;
    input [5:0] index;
    reg [63:0] num;
    reg [63:0] den;
    begin
        if (index == 6'd0) begin
            ref_pulse_lut = 16'd0;
        end else begin
            num = 64'd9588 * 64'd32767 * index;
            den = 64'd100 * (64'd8128 + 64'd100 * index);
            ref_pulse_lut = ((num + (den / 64'd2)) / den);
        end
    end
endfunction

function [15:0] ref_tnd_lut;
    input [7:0] index;
    reg [63:0] num;
    reg [63:0] den;
    begin
        if (index == 8'd0) begin
            ref_tnd_lut = 16'd0;
        end else begin
            num = 64'd16367 * 64'd32767 * index;
            den = 64'd100 * (64'd24329 + 64'd100 * index);
            ref_tnd_lut = ((num + (den / 64'd2)) / den);
        end
    end
endfunction

function [11:0] ref_noise_period;
    input [3:0] index;
    begin
        case (index)
            4'd0: ref_noise_period = 12'd4;
            4'd1: ref_noise_period = 12'd8;
            4'd2: ref_noise_period = 12'd16;
            4'd3: ref_noise_period = 12'd32;
            4'd4: ref_noise_period = 12'd64;
            4'd5: ref_noise_period = 12'd96;
            4'd6: ref_noise_period = 12'd128;
            4'd7: ref_noise_period = 12'd160;
            4'd8: ref_noise_period = 12'd202;
            4'd9: ref_noise_period = 12'd254;
            4'd10: ref_noise_period = 12'd380;
            4'd11: ref_noise_period = 12'd508;
            4'd12: ref_noise_period = 12'd762;
            4'd13: ref_noise_period = 12'd1016;
            4'd14: ref_noise_period = 12'd2034;
            default: ref_noise_period = 12'd4068;
        endcase
    end
endfunction

function [3:0] ref_tri_sequence;
    input [4:0] step;
    begin
        if (step[4] == 1'b0)
            ref_tri_sequence = 4'd15 - {1'b0, step[3:0]};
        else
            ref_tri_sequence = {1'b0, step[3:0]};
    end
endfunction

initial begin
    #400000000;
    $fatal(1, "global timeout");
end

task check1;
    input [8*64-1:0] name;
    input actual;
    input expected;
    begin
        if (actual !== expected)
            $fatal(1, "%0s: got %b expected %b", name, actual, expected);
    end
endtask

task check3;
    input [8*64-1:0] name;
    input [2:0] actual;
    input [2:0] expected;
    begin
        if (actual !== expected)
            $fatal(1, "%0s: got %0d expected %0d", name, actual, expected);
    end
endtask

task check4;
    input [8*64-1:0] name;
    input [3:0] actual;
    input [3:0] expected;
    begin
        if (actual !== expected)
            $fatal(1, "%0s: got %0d expected %0d", name, actual, expected);
    end
endtask

task check5;
    input [8*64-1:0] name;
    input [4:0] actual;
    input [4:0] expected;
    begin
        if (actual !== expected)
            $fatal(1, "%0s: got %0d expected %0d", name, actual, expected);
    end
endtask

task check6;
    input [8*64-1:0] name;
    input [5:0] actual;
    input [5:0] expected;
    begin
        if (actual !== expected)
            $fatal(1, "%0s: got %0d expected %0d", name, actual, expected);
    end
endtask

task check7;
    input [8*64-1:0] name;
    input [6:0] actual;
    input [6:0] expected;
    begin
        if (actual !== expected)
            $fatal(1, "%0s: got %0d expected %0d", name, actual, expected);
    end
endtask

task check8;
    input [8*64-1:0] name;
    input [7:0] actual;
    input [7:0] expected;
    begin
        if (actual !== expected)
            $fatal(1, "%0s: got %02h expected %02h", name, actual, expected);
    end
endtask

task check9;
    input [8*64-1:0] name;
    input [8:0] actual;
    input [8:0] expected;
    begin
        if (actual !== expected)
            $fatal(1, "%0s: got %0d expected %0d", name, actual, expected);
    end
endtask

task check11;
    input [8*64-1:0] name;
    input [10:0] actual;
    input [10:0] expected;
    begin
        if (actual !== expected)
            $fatal(1, "%0s: got %03h expected %03h", name, actual, expected);
    end
endtask

task check12;
    input [8*64-1:0] name;
    input [11:0] actual;
    input [11:0] expected;
    begin
        if (actual !== expected)
            $fatal(1, "%0s: got %0d expected %0d", name, actual, expected);
    end
endtask

task check15;
    input [8*64-1:0] name;
    input [14:0] actual;
    input [14:0] expected;
    begin
        if (actual !== expected)
            $fatal(1, "%0s: got %0d expected %0d", name, actual, expected);
    end
endtask

task check16;
    input [8*64-1:0] name;
    input [15:0] actual;
    input [15:0] expected;
    begin
        if (actual !== expected)
            $fatal(1, "%0s: got %0d expected %0d", name, actual, expected);
    end
endtask

task check17;
    input [8*64-1:0] name;
    input [16:0] actual;
    input [16:0] expected;
    begin
        if (actual !== expected)
            $fatal(1, "%0s: got %0d expected %0d", name, actual, expected);
    end
endtask

task apply_reset;
    begin
        ce = 1'b0;
        ce_sample = 1'b0;
        reg_cs = 1'b0;
        reg_we = 1'b0;
        reg_addr = 5'd0;
        reg_din = 8'h00;
        ce_edges = 0;
        mark = 0;
        dmc_pending = 1'b0;
        dmc_grant_enable = 1'b1;
        @(negedge clk);
        reset = 1'b1;
        repeat (2) @(posedge clk);
        #1 reset = 1'b0;
    end
endtask

task tick;
    input integer n;
    integer t;
    begin
        @(negedge clk);
        ce = 1'b1;
        for (t = 0; t < n; t = t + 1) begin
            @(posedge clk);
        end
        #1 ce = 1'b0;
    end
endtask

task freeze;
    input integer n;
    integer t;
    begin
        ce = 1'b0;
        for (t = 0; t < n; t = t + 1) begin
            @(posedge clk);
        end
        #1;
    end
endtask

task tick_to_count;
    input [15:0] target;
    reg [16:0] cur;
    reg [16:0] delta;
    begin
        cur = {1'b0, dbg_frame_count};
        if (target >= cur)
            delta = {1'b0, target} - cur;
        else
            delta = 17'd29830 + {1'b0, target} - cur;
        tick(delta[15:0]);
        if (dbg_frame_count !== target)
            $fatal(1, "tick_to_count(%0d) landed on %0d", target, dbg_frame_count);
    end
endtask

task quarter_next;
    input integer qn;
    integer q;
    begin
        q = (qn - 1) % 4;
        if (q == 0) begin
            tick_to_count(16'd7456);
            tick(1);
        end else if (q == 1) begin
            tick_to_count(16'd14912);
            tick(1);
        end else if (q == 2) begin
            tick_to_count(16'd22370);
            tick(1);
        end else begin
            tick_to_count(16'd29828);
            tick(1);
        end
    end
endtask

task apu_write;
    input [4:0] a;
    input [7:0] d;
    begin
        ce = 1'b0;
        @(negedge clk);
        reg_cs = 1'b1;
        reg_we = 1'b1;
        reg_addr = a;
        reg_din = d;
        @(negedge clk);
        reg_cs = 1'b0;
        reg_we = 1'b0;
        reg_addr = 5'd0;
        reg_din = 8'h00;
    end
endtask

task apu_read;
    input [4:0] a;
    output [7:0] d;
    begin
        ce = 1'b0;
        @(negedge clk);
        reg_cs = 1'b1;
        reg_we = 1'b0;
        reg_addr = a;
        #1 d = reg_dout;
        @(negedge clk);
        reg_cs = 1'b0;
        reg_addr = 5'd0;
    end
endtask

task check_state_frozen;
    input [8*64-1:0] name;
    begin
        if (dbg_frame_phase !== snap_phase) $fatal(1, "%0s: frame phase moved", name);
        if (dbg_frame_count !== snap_count) $fatal(1, "%0s: frame count moved", name);
        if (dbg_pulse1_length !== snap_len1) $fatal(1, "%0s: length1 moved", name);
        if (dbg_pulse2_length !== snap_len2) $fatal(1, "%0s: length2 moved", name);
        if (dbg_pulse1_period !== snap_per1) $fatal(1, "%0s: period1 moved", name);
        if (dbg_pulse1_duty_step !== snap_dst1) $fatal(1, "%0s: duty step moved", name);
        if (dbg_pulse1_level !== snap_lvl1) $fatal(1, "%0s: level1 moved", name);
        if (dbg_pulse1_env !== snap_env1) $fatal(1, "%0s: envelope moved", name);
        if (dbg_pulse1_env_div !== snap_edv1) $fatal(1, "%0s: envelope divider moved", name);
        if (irq !== snap_irq) $fatal(1, "%0s: irq changed", name);
        if (dbg_pulse1_mute !== snap_mute1) $fatal(1, "%0s: mute changed", name);
    end
endtask

task take_snapshot;
    begin
        snap_phase = {13'b0, dbg_frame_phase};
        snap_count = dbg_frame_count;
        snap_len1 = dbg_pulse1_length;
        snap_len2 = dbg_pulse2_length;
        snap_per1 = dbg_pulse1_period;
        snap_dst1 = dbg_pulse1_duty_step;
        snap_lvl1 = dbg_pulse1_level;
        snap_env1 = dbg_pulse1_env;
        snap_edv1 = dbg_pulse1_env_div;
        snap_irq = irq;
        snap_mute1 = dbg_pulse1_mute;
        snap_sample = sample_left;
    end
endtask

task quarter_env_check;
    input integer qn;
    input [3:0] expected;
    begin
        quarter_next(qn);
        if (dbg_pulse1_env !== expected)
            $fatal(1, "envelope quarter %0d: got %0d expected %0d",
                   qn, dbg_pulse1_env, expected);
    end
endtask

task check_mixer_now;
    reg [15:0] tnd_calc;
    reg [63:0] total;
    begin
        tnd_calc = dbg_tri_level * 3 + dbg_noise_level * 2 + dbg_dmc_output;
        if (dbg_tnd_sum !== tnd_calc[7:0])
            $fatal(1, "tnd index: got %0d expected %0d", dbg_tnd_sum, tnd_calc);
        if (dbg_mix_pulse !== ref_pulse_lut(dbg_pulse_sum))
            $fatal(1, "pulse lut(%0d): got %0d expected %0d", dbg_pulse_sum,
                   dbg_mix_pulse, ref_pulse_lut(dbg_pulse_sum));
        if (dbg_mix_tnd !== ref_tnd_lut(tnd_calc[7:0]))
            $fatal(1, "tnd lut(%0d): got %0d expected %0d", tnd_calc,
                   dbg_mix_tnd, ref_tnd_lut(tnd_calc[7:0]));
        total = ref_pulse_lut(dbg_pulse_sum) + ref_tnd_lut(tnd_calc[7:0]);
        if (dbg_mix_sum !== total[16:0])
            $fatal(1, "mix sum at %0d: got %0d expected %0d", tnd_calc, dbg_mix_sum, total);
        if (total > 64'd32767)
            clamp_hits = clamp_hits + 1;
        mixer_checks = mixer_checks + 1;
    end
endtask

task test_reset_state;
    begin
        apply_reset;
        check1("reset irq", irq, 1'b0);
        check1("reset dbg_frame_irq", dbg_frame_irq, 1'b0);
        check1("reset dbg_dmc_irq", dbg_dmc_irq, 1'b0);
        check3("reset frame phase", dbg_frame_phase, 3'd0);
        check16("reset frame count", dbg_frame_count, 16'd0);
        check8("reset length1", dbg_pulse1_length, 8'd0);
        check8("reset length2", dbg_pulse2_length, 8'd0);
        check11("reset period1", dbg_pulse1_period, 11'd0);
        check11("reset period2", dbg_pulse2_period, 11'd0);
        check3("reset duty step1", dbg_pulse1_duty_step, 3'd0);
        check3("reset duty step2", dbg_pulse2_duty_step, 3'd0);
        check4("reset level1", dbg_pulse1_level, 4'd0);
        check4("reset level2", dbg_pulse2_level, 4'd0);
        check4("reset env1", dbg_pulse1_env, 4'd0);
        check4("reset env2", dbg_pulse2_env, 4'd0);
        check4("reset env div1", dbg_pulse1_env_div, 4'd0);
        check1("reset mute1 (period<8)", dbg_pulse1_mute, 1'b1);
        check1("reset mute2 (period<8)", dbg_pulse2_mute, 1'b1);
        check6("reset pulse sum", dbg_pulse_sum, 6'd0);
        check8("reset tri length", dbg_tri_length, 8'd0);
        check11("reset tri period", dbg_tri_period, 11'd0);
        check5("reset tri step", dbg_tri_step, 5'd0);
        check7("reset tri linear", dbg_tri_linear, 7'd0);
        check1("reset tri reload flag", dbg_tri_reload_flag, 1'b0);
        check4("reset tri level", dbg_tri_level, 4'd0);
        check8("reset noise length", dbg_noise_length, 8'd0);
        check12("reset noise period", dbg_noise_period, 12'd0);
        check15("reset noise lfsr is 1", dbg_noise_lfsr, 15'd1);
        check1("reset noise mode", dbg_noise_mode, 1'b0);
        check1("reset noise mute (period 0)", dbg_noise_mute, 1'b1);
        check4("reset noise level", dbg_noise_level, 4'd0);
        check4("reset noise env", dbg_noise_env, 4'd0);
        check4("reset noise env div", dbg_noise_env_div, 4'd0);
        check16("reset dmc sample addr", dbg_dmc_sample_addr, 16'hC000);
        check16("reset dmc current addr", dbg_dmc_current_addr, 16'hC000);
        check12("reset dmc bytes remaining", dbg_dmc_bytes_remaining, 12'd0);
        check4("reset dmc bits remaining", dbg_dmc_bits_remaining, 4'd0);
        check7("reset dmc output", dbg_dmc_output, 7'd0);
        check1("reset dmc silence", dbg_dmc_silence, 1'b1);
        check1("reset dmc buffer empty", dbg_dmc_buf_empty, 1'b1);
        check1("reset dmc inactive", dbg_dmc_active, 1'b0);
        check1("reset dmc bus idle", dmc_bus_req, 1'b0);
        check8("reset tnd sum", dbg_tnd_sum, 8'd0);
        check16("reset mix pulse", dbg_mix_pulse, 16'd0);
        check16("reset mix tnd", dbg_mix_tnd, 16'd0);
        check17("reset mix sum", dbg_mix_sum, 17'd0);
        check1("reset sample_valid", sample_valid, 1'b0);
        check16("reset sample_left", sample_left, 16'd0);
        check16("reset sample_right", sample_right, 16'd0);
        for (i = 0; i < 24; i = i + 1) begin
            apu_read(i[4:0], rd_tmp);
            check8("reset register readback", rd_tmp, 8'h00);
        end
        $display("RESET all-zero state and 24 register readbacks PASS");
    end
endtask

task test_pulse_registers;
    begin
        apply_reset;
        apu_write(5'h00, 8'h8F);
        apu_read(5'h00, rd_tmp);
        check8("$4000 readback", rd_tmp, 8'h8F);
        apu_write(5'h01, 8'h9C);
        apu_read(5'h01, rd_tmp);
        check8("$4001 readback", rd_tmp, 8'h9C);
        apu_write(5'h02, 8'hA5);
        apu_read(5'h02, rd_tmp);
        check8("$4002 readback", rd_tmp, 8'hA5);
        apu_write(5'h03, 8'h1F);
        apu_read(5'h03, rd_tmp);
        check8("$4003 readback", rd_tmp, 8'h1F);
        check11("$4002+$4003 period1", dbg_pulse1_period, 11'h7A5);
        check11("$4003 length index1", {3'b000, dbg_pulse1_length}, 11'd0);

        apu_write(5'h04, 8'hCF);
        apu_read(5'h04, rd_tmp);
        check8("$4004 readback", rd_tmp, 8'hCF);
        apu_write(5'h05, 8'h52);
        apu_read(5'h05, rd_tmp);
        check8("$4005 readback", rd_tmp, 8'h52);
        apu_write(5'h06, 8'h3C);
        apu_read(5'h06, rd_tmp);
        check8("$4006 readback", rd_tmp, 8'h3C);
        apu_write(5'h07, 8'h0A);
        apu_read(5'h07, rd_tmp);
        check8("$4007 readback", rd_tmp, 8'h0A);
        check11("$4006+$4007 period2", dbg_pulse2_period, 11'h23C);

        apu_write(5'h00, 8'h00);
        apu_read(5'h00, rd_tmp);
        check8("$4000 clear readback", rd_tmp, 8'h00);
        apu_write(5'h01, 8'h00);
        apu_read(5'h01, rd_tmp);
        check8("$4001 clear readback", rd_tmp, 8'h00);
        apu_write(5'h02, 8'h00);
        apu_read(5'h02, rd_tmp);
        check8("$4002 clear readback", rd_tmp, 8'h00);
        apu_write(5'h03, 8'h00);
        apu_read(5'h03, rd_tmp);
        check8("$4003 clear readback", rd_tmp, 8'h00);
        check11("period1 cleared", dbg_pulse1_period, 11'd0);

        apu_read(5'h14, rd_tmp);
        check8("$4014 unimplemented readback", rd_tmp, 8'h00);
        apu_read(5'h16, rd_tmp);
        check8("$4016 unimplemented readback", rd_tmp, 8'h00);
        apu_read(5'h17, rd_tmp);
        check8("$4017 unimplemented readback", rd_tmp, 8'h00);
        $display("REGISTER $4000-$4007 readback and $4014/$4016/$4017 reads PASS");
    end
endtask

task test_ce_freeze;
    begin
        apply_reset;
        apu_write(5'h15, 8'h01);
        apu_write(5'h00, 8'h8F);
        apu_write(5'h01, 8'h00);
        apu_write(5'h02, 8'h08);
        apu_write(5'h03, 8'h08);
        tick(1);
        check8("freeze length loaded", dbg_pulse1_length, 8'd254);
        ce_sample = 1'b1;
        take_snapshot;
        freeze(2000);
        check1("freeze sample_valid low", sample_valid, 1'b0);
        check_state_frozen("ce=0 freeze");
        freeze(2000);
        check_state_frozen("ce=0 freeze twice");
        check16("freeze holds sample_left", sample_left, snap_sample);
        tick(1);
        if (dbg_frame_count === snap_count)
            $fatal(1, "ce=1 did not advance the frame counter");
        check1("ce=1 restarts sample_valid", sample_valid, 1'b1);
        ce_sample = 1'b0;
        tick(1);
        check1("ce_sample=0 clears sample_valid", sample_valid, 1'b0);
        $display("CE=0 freeze of frame/length/period/duty/envelope/irq PASS");
    end
endtask

task test_status_and_length;
    begin
        apply_reset;
        apu_read(5'h15, rd_tmp);
        check8("$4015 after reset", rd_tmp, 8'h00);

        apu_write(5'h01, 8'h00);
        apu_write(5'h02, 8'h08);
        apu_write(5'h03, 8'h08);
        apu_write(5'h05, 8'h00);
        apu_write(5'h06, 8'h08);
        apu_write(5'h07, 8'h08);
        apu_write(5'h15, 8'h03);
        apu_write(5'h03, 8'h08);
        apu_write(5'h07, 8'h08);
        apu_read(5'h15, rd_tmp);
        check8("$4015 before length load", rd_tmp, 8'h00);
        tick(1);
        check8("length1 table index1", dbg_pulse1_length, 8'd254);
        check8("length2 table index1", dbg_pulse2_length, 8'd254);
        apu_read(5'h15, rd_tmp);
        check8("$4015 both lengths nonzero", rd_tmp, 8'h03);

        tick_to_count(16'd14912);
        tick(1);
        check8("length1 after first half clock", dbg_pulse1_length, 8'd253);
        check8("length2 after first half clock", dbg_pulse2_length, 8'd253);
        check3("frame phase after half 1", dbg_frame_phase, 3'd2);

        tick_to_count(16'd22370);
        check8("length1 stable without half clock", dbg_pulse1_length, 8'd253);
        tick(1);
        check8("length1 stable after quarter 3", dbg_pulse1_length, 8'd253);
        tick_to_count(16'd29828);
        tick(1);
        check8("length1 after second half clock", dbg_pulse1_length, 8'd252);

        apu_write(5'h15, 8'h02);
        apu_read(5'h15, rd_tmp);
        check8("$4015 pulse1 disabled", rd_tmp, 8'h02);
        check8("pulse1 length zeroed on disable", dbg_pulse1_length, 8'd0);
        check8("pulse2 length kept on disable", dbg_pulse2_length, 8'd252);

        apu_write(5'h15, 8'h03);
        apu_read(5'h15, rd_tmp);
        check8("$4015 re-enable does not reload length", rd_tmp, 8'h02);
        apu_write(5'h03, 8'h08);
        tick(1);
        check8("pulse1 length reloaded", dbg_pulse1_length, 8'd254);
        apu_read(5'h15, rd_tmp);
        check8("$4015 after reload", rd_tmp, 8'h03);

        apu_write(5'h03, 8'h00);
        tick(1);
        check8("length1 table index0", dbg_pulse1_length, 8'd10);
        apu_write(5'h07, 8'h00);
        tick(1);
        check8("length2 table index0", dbg_pulse2_length, 8'd10);

        for (k = 0; k < 3; k = k + 1) begin
            tick_to_count(16'd14912);
            tick(1);
            tick_to_count(16'd29828);
            tick(1);
        end
        check8("length1 after 6 half clocks", dbg_pulse1_length, 8'd4);
        check8("length2 after 6 half clocks", dbg_pulse2_length, 8'd4);
        tick_to_count(16'd7456);
        tick(1);
        tick_to_count(16'd14912);
        tick(1);
        tick_to_count(16'd29828);
        tick(1);
        check8("length1 after 8 half clocks", dbg_pulse1_length, 8'd2);
        tick_to_count(16'd7456);
        tick(1);
        tick_to_count(16'd14912);
        tick(1);
        tick_to_count(16'd29828);
        tick(1);
        check8("length1 after 10 half clocks", dbg_pulse1_length, 8'd0);
        check8("length2 after 10 half clocks", dbg_pulse2_length, 8'd0);
        apu_read(5'h15, rd_tmp);
        check8("$4015 both lengths exhausted", {2'b00, rd_tmp[1:0]}, 8'h00);
        apu_read(5'h15, rd2);
        check8("$4015 frame flag cleared by read", rd2, 8'h00);
        check4("level1 silent at length 0", dbg_pulse1_level, 4'd0);
        check4("level2 silent at length 0", dbg_pulse2_level, 4'd0);
        check6("pulse sum silent at length 0", dbg_pulse_sum, 6'd0);
        $display("STATUS $4015 length status, disable and exhaustion PASS");
    end
endtask

task test_duty_and_mix;
    begin
        apply_reset;
        apu_write(5'h15, 8'h01);
        apu_write(5'h01, 8'h00);
        apu_write(5'h02, 8'h08);
        apu_write(5'h03, 8'h08);
        apu_write(5'h00, 8'h8F);
        tick(1);
        check8("duty test length", dbg_pulse1_length, 8'd254);
        check1("duty test not muted", dbg_pulse1_mute, 1'b0);
        check3("duty step reset by $4003", dbg_pulse1_duty_step, 3'd0);
        ce_sample = 1'b1;
        prev_step = dbg_pulse1_duty_step;
        duty_idx = 0;
        guard = 0;
        while ((duty_idx < 8) && (guard < 4000)) begin
            tick(1);
            guard = guard + 1;
            if (dbg_pulse1_duty_step !== prev_step) begin
                prev_step = dbg_pulse1_duty_step;
                duty_step_log[duty_idx] = prev_step;
                duty_level_log[duty_idx] = dbg_pulse1_level;
                tick(1);
                duty_sample_log[duty_idx] = sample_left;
                duty_idx = duty_idx + 1;
            end
        end
        if (duty_idx != 8)
            $fatal(1, "duty sequence only produced %0d steps", duty_idx);
        for (i = 0; i < 8; i = i + 1) begin
            if (duty_step_log[i] !== ((i + 1) & 7))
                $fatal(1, "duty step %0d: got %0d", i, duty_step_log[i]);
        end
        for (i = 0; i < 4; i = i + 1)
            check4("duty=2 level high", duty_level_log[i], 4'd15);
        for (i = 4; i < 8; i = i + 1)
            check4("duty=2 level low", duty_level_log[i], 4'd0);
        for (i = 0; i < 4; i = i + 1)
            check16("mixer lut(15)", duty_sample_log[i], 16'd4895);
        for (i = 4; i < 8; i = i + 1)
            check16("mixer lut(0)", duty_sample_log[i], 16'd0);
        check16("sample_left equals sample_right", sample_left, sample_right);

        apu_write(5'h15, 8'h03);
        apu_write(5'h04, 8'hAF);
        apu_write(5'h05, 8'h00);
        apu_write(5'h06, 8'h08);
        apu_write(5'h07, 8'h08);
        apu_write(5'h00, 8'hAF);
        apu_write(5'h01, 8'h00);
        apu_write(5'h02, 8'h08);
        apu_write(5'h03, 8'h08);
        tick(1);
        guard = 0;
        while (((dbg_pulse1_duty_step != 3'd1) || (dbg_pulse2_duty_step != 3'd1)) && (guard < 2000)) begin
            tick(1);
            guard = guard + 1;
        end
        if ((dbg_pulse1_duty_step != 3'd1) || (dbg_pulse2_duty_step != 3'd1))
            $fatal(1, "both pulses never reached duty step 1 together");
        check4("pulse1 level 15", dbg_pulse1_level, 4'd15);
        check4("pulse2 level 15", dbg_pulse2_level, 4'd15);
        check6("pulse sum 30", dbg_pulse_sum, 6'd30);
        tick(1);
        check16("mixer lut(30)", sample_left, 16'd8470);
        check16("mixer lut(30) right", sample_right, 16'd8470);

        ce_sample = 1'b0;
        $display("DUTY sequence 01234567 level/mixer samples PASS");
    end
endtask

task test_envelope;
    begin
        apply_reset;
        apu_write(5'h15, 8'h01);
        apu_write(5'h01, 8'h00);
        apu_write(5'h02, 8'h08);
        apu_write(5'h03, 8'h08);
        apu_write(5'h00, 8'h21);
        tick(1);
        check4("envelope $4003 write sets decay 15", dbg_pulse1_env, 4'd15);
        check4("envelope $4000 write sets divider 1", dbg_pulse1_env_div, 4'd1);
        check8("envelope halt freezes length", dbg_pulse1_length, 8'd254);

        quarter_env_check(1, 4'd15);
        check4("envelope divider after Q1", dbg_pulse1_env_div, 4'd1);
        quarter_env_check(2, 4'd15);
        check4("envelope divider after Q2", dbg_pulse1_env_div, 4'd0);
        quarter_env_check(3, 4'd14);
        check4("envelope divider after Q3", dbg_pulse1_env_div, 4'd1);
        for (i = 4; i <= 33; i = i + 1) begin
            k = 15 - ((i - 1) / 2);
            if (k < 0)
                k = 15;
            exp_env = k[3:0];
            quarter_env_check(i, exp_env);
        end
        check8("envelope halt keeps length", dbg_pulse1_length, 8'd254);

        apu_write(5'h00, 8'h98);
        check4("const volume write keeps env register", dbg_pulse1_env, 4'd15);
        check11("period still legal", dbg_pulse1_period, 11'h008);
        guard = 0;
        while ((dbg_pulse1_duty_step != 3'd1) && (guard < 2000)) begin
            tick(1);
            guard = guard + 1;
        end
        if (dbg_pulse1_duty_step != 3'd1)
            $fatal(1, "const volume test never reached duty step 1");
        check4("constant volume 8 used", dbg_pulse1_level, 4'd8);
        check16("mixer lut(8)", dut.mixed_sample, 16'd2815);

        apu_write(5'h00, 8'h08);
        check4("const cleared env register unchanged", dbg_pulse1_env, 4'd15);
        guard = 0;
        while ((dbg_pulse1_duty_step != 3'd1) && (guard < 2000)) begin
            tick(1);
            guard = guard + 1;
        end
        if (dbg_pulse1_duty_step != 3'd1)
            $fatal(1, "decay test never reached duty step 1");
        if (dbg_pulse1_env === 4'd8)
            $fatal(1, "envelope decayed to 8, decay check would be vacuous");
        if (dbg_pulse1_level !== dbg_pulse1_env)
            $fatal(1, "decay volume: got %0d expected %0d",
                   dbg_pulse1_level, dbg_pulse1_env);
        $display("ENVELOPE decay, halt wraparound and constant volume PASS");
    end
endtask

task test_sweep;
    begin
        apply_reset;
        apu_write(5'h00, 8'h8F);
        apu_write(5'h01, 8'h81);
        apu_write(5'h02, 8'hFF);
        apu_write(5'h03, 8'h07);
        check11("period set to 7FF", dbg_pulse1_period, 11'h7FF);
        check1("sweep target overflow mutes", dbg_pulse1_mute, 1'b1);
        check4("muted channel outputs 0", dbg_pulse1_level, 4'd0);
        check6("muted channel sum", dbg_pulse_sum, 6'd0);

        apu_write(5'h02, 8'h00);
        apu_write(5'h03, 8'h01);
        check11("period back to 100", dbg_pulse1_period, 11'h100);
        check1("legal sweep target unmutes", dbg_pulse1_mute, 1'b0);

        apu_write(5'h02, 8'h04);
        apu_write(5'h03, 8'h00);
        check11("period set to 4", dbg_pulse1_period, 11'h004);
        check1("period below 8 mutes", dbg_pulse1_mute, 1'b1);
        apu_write(5'h03, 8'h01);
        check1("period above 8 unmutes", dbg_pulse1_mute, 1'b0);

        apu_write(5'h05, 8'h89);
        apu_write(5'h06, 8'h00);
        apu_write(5'h07, 8'h09);
        apu_write(5'h01, 8'h89);
        apu_write(5'h02, 8'h00);
        apu_write(5'h03, 8'h09);
        check11("pulse1 pre-sweep period", dbg_pulse1_period, 11'h100);
        check11("pulse2 pre-sweep period", dbg_pulse2_period, 11'h100);
        apu_write(5'h15, 8'h03);
        apu_write(5'h17, 8'h00);
        tick(1);
        check16("frame counter restarted by $4017", dbg_frame_count, 16'd1);
        tick_to_count(16'd14912);
        tick(1);
        check11("pulse1 period after half clock 1", dbg_pulse1_period, 11'h100);
        check11("pulse2 period after half clock 1", dbg_pulse2_period, 11'h100);
        tick_to_count(16'd29828);
        tick(1);
        check11("pulse1 negative sweep subtracts one extra", dbg_pulse1_period, 11'h07F);
        check11("pulse2 negative sweep target", dbg_pulse2_period, 11'h080);

        apu_write(5'h01, 8'h80);
        apu_write(5'h02, 8'h00);
        apu_write(5'h03, 8'h09);
        apu_write(5'h17, 8'h00);
        tick(1);
        tick_to_count(16'd14912);
        tick(1);
        tick_to_count(16'd29828);
        tick(1);
        check11("sweep shift zero does not change period", dbg_pulse1_period, 11'h100);

        apu_write(5'h01, 8'h81);
        apu_write(5'h02, 8'hFF);
        apu_write(5'h03, 8'h07);
        check1("mute again after period write", dbg_pulse1_mute, 1'b1);
        $display("SWEEP target overflow, period floor, negate difference and shift gate PASS");
    end
endtask

task test_frame_irq_4step;
    begin
        apply_reset;
        check1("no irq right after reset", irq, 1'b0);
        ce_edges = 0;
        tick_to_count(16'd7456);
        tick(1);
        check3("4-step quarter 1", dbg_frame_phase, 3'd1);
        check1("no irq at quarter 1", irq, 1'b0);
        tick_to_count(16'd14912);
        tick(1);
        check3("4-step quarter 2", dbg_frame_phase, 3'd2);
        check1("no irq at quarter 2", irq, 1'b0);
        tick_to_count(16'd22370);
        tick(1);
        check3("4-step quarter 3", dbg_frame_phase, 3'd3);
        check1("no irq at quarter 3", irq, 1'b0);
        tick_to_count(16'd29828);
        check1("no irq before quarter 4", irq, 1'b0);
        check3("phase still 3 before quarter 4", dbg_frame_phase, 3'd3);
        tick(1);
        check1("irq asserted at quarter 4", irq, 1'b1);
        check1("dbg_frame_irq follows irq", dbg_frame_irq, 1'b1);
        check16("4-step step 4 event on ce 29829", ce_edges, 16'd29829);
        mark = ce_edges;
        check16("4-step holds 29829 for one ce", dbg_frame_count, 16'd29829);
        check3("phase wraps to 0 after quarter 4", dbg_frame_phase, 3'd0);
        apu_read(5'h15, rd_tmp);
        check8("$4015 reports frame irq", rd_tmp, 8'h40);
        check1("reading $4015 clears irq", irq, 1'b0);
        apu_read(5'h15, rd_tmp);
        check8("$4015 frame irq cleared", rd_tmp, 8'h00);
        tick(1);
        check16("4-step counter zeroes on ce 29830", dbg_frame_count, 16'd0);

        guard = 0;
        while ((irq !== 1'b1) && (guard < 40000)) begin
            tick(1);
            guard = guard + 1;
        end
        if (irq !== 1'b1)
            $fatal(1, "4-step frame irq did not re-assert in the second frame");
        check16("4-step irq to irq period is 29830 ce", ce_edges - mark, 16'd29830);
        check16("4-step second event holds 29829", dbg_frame_count, 16'd29829);
        check3("4-step second frame phase is 0", dbg_frame_phase, 3'd0);
        tick(1);
        check16("4-step counter zeroes on ce 29830 again", dbg_frame_count, 16'd0);

        apu_write(5'h15, 8'h00);
        check1("writing $4015 clears irq", irq, 1'b0);
        apu_read(5'h15, rd_tmp);
        check8("$4015 clear by write", rd_tmp, 8'h00);
        $display("FRAME 4-step quarter/half phase and 29830 ce IRQ period PASS");
    end
endtask

task test_frame_5step;
    begin
        apply_reset;
        apu_write(5'h17, 8'h80);
        check16("5-step restart", dbg_frame_count, 16'd0);
        ce_edges = 0;
        for (k = 0; k < 2; k = k + 1) begin
            tick_to_count(16'd7456);
            tick(1);
            check3("5-step quarter 1", dbg_frame_phase, 3'd1);
            if (k == 0) begin
                mark = ce_edges;
            end else begin
                check16("5-step step 1 to step 1 period is 37282 ce",
                        ce_edges - mark, 16'd37282);
            end
            tick_to_count(16'd14912);
            tick(1);
            check3("5-step quarter 2", dbg_frame_phase, 3'd2);
            tick_to_count(16'd22370);
            tick(1);
            check3("5-step quarter 3", dbg_frame_phase, 3'd3);
            tick_to_count(16'd29828);
            tick(1);
            check3("5-step idle step 4", dbg_frame_phase, 3'd4);
            check16("5-step idle step holds 29829", dbg_frame_count, 16'd29829);
            check1("5-step never sets frame irq", irq, 1'b0);
            tick_to_count(16'd37280);
            tick(1);
            check3("5-step wraps to phase 0", dbg_frame_phase, 3'd0);
            check16("5-step step 5 event holds 37281", dbg_frame_count, 16'd37281);
            check1("5-step no irq after full frame", irq, 1'b0);
            tick(1);
            check16("5-step counter zeroes on ce 37282", dbg_frame_count, 16'd0);
        end
        apu_read(5'h15, rd_tmp);
        check8("$4015 bit6 stays clear in 5-step", rd_tmp[6], 1'b0);
        apu_write(5'h17, 8'h00);
        ce_edges = 0;
        tick_to_count(16'd29828);
        tick(1);
        check1("irq returns after switching to 4-step", irq, 1'b1);
        check16("4-step event lands on ce 29829 again", ce_edges, 16'd29829);
        $display("FRAME 5-step no IRQ and 37282 ce period PASS");
    end
endtask

task test_frame_inhibit;
    begin
        apply_reset;
        apu_write(5'h17, 8'h40);
        check16("inhibit restart", dbg_frame_count, 16'd0);
        ce_edges = 0;
        tick_to_count(16'd7456);
        tick(1);
        check3("inhibit still clocks quarter 1", dbg_frame_phase, 3'd1);
        tick_to_count(16'd29828);
        tick(1);
        check1("inhibit blocks frame irq", irq, 1'b0);
        check3("inhibit still runs step 4", dbg_frame_phase, 3'd0);
        check16("inhibited frame holds 29829", dbg_frame_count, 16'd29829);
        check16("inhibit step 4 event on ce 29829", ce_edges, 16'd29829);

        mark = ce_edges;
        guard = 0;
        while ((dbg_frame_count != 16'd29828) && (guard < 40000)) begin
            tick(1);
            guard = guard + 1;
        end
        if (dbg_frame_count != 16'd29828)
            $fatal(1, "inhibited frame never reached the second step 4");
        tick(1);
        check16("inhibit frame period is 29830 ce", ce_edges - mark, 16'd29830);
        check1("inhibit blocks the second irq too", irq, 1'b0);
        check3("inhibit step 4 ran again", dbg_frame_phase, 3'd0);
        tick(1);
        check16("inhibited frame zeroes on ce 29830", dbg_frame_count, 16'd0);

        apu_write(5'h17, 8'h00);
        ce_edges = 0;
        tick_to_count(16'd29828);
        tick(1);
        check1("irq asserts after inhibit is cleared", irq, 1'b1);
        check16("cleared inhibit irqs on ce 29829", ce_edges, 16'd29829);

        apu_write(5'h17, 8'h40);
        check1("writing $4017 with inhibit acks irq", irq, 1'b0);
        apu_read(5'h15, rd_tmp);
        check8("$4015 clear after ack", rd_tmp, 8'h00);

        apu_write(5'h17, 8'h00);
        tick_to_count(16'd29828);
        tick(1);
        check1("irq asserts again after re-enable", irq, 1'b1);
        $display("FRAME inhibit and acknowledge contract PASS");
    end
endtask

task test_triangle_registers;
    begin
        apply_reset;
        apu_write(5'h08, 8'hFF);
        apu_read(5'h08, rd_tmp);
        check8("$4008 readback", rd_tmp, 8'hFF);
        apu_write(5'h09, 8'hA5);
        apu_read(5'h09, rd_tmp);
        check8("$4009 readback", rd_tmp, 8'hA5);
        apu_write(5'h0A, 8'h1E);
        apu_read(5'h0A, rd_tmp);
        check8("$400A readback is the shared period high bits", rd_tmp, 8'h06);
        apu_write(5'h0B, 8'h1F);
        apu_read(5'h0B, rd_tmp);
        check8("$400B readback", rd_tmp, 8'h1F);
        check11("triangle period assembled", dbg_tri_period, 11'h7A5);
        apu_write(5'h0B, 8'h40);
        apu_read(5'h0B, rd_tmp);
        check8("$400B length index field readback", rd_tmp, 8'h40);
        check8("triangle length stays 0 while disabled", dbg_tri_length, 8'd0);
        apu_write(5'h09, 8'h5A);
        apu_write(5'h0B, 8'h08);
        check11("triangle period from $400B high bits", dbg_tri_period, 11'h05A);
        $display("TRIANGLE $4008-$400B readback and period assembly PASS");
    end
endtask

task test_triangle_waveform;
    begin
        apply_reset;
        apu_write(5'h15, 8'h04);
        apu_write(5'h08, 8'hFF);
        apu_write(5'h09, 8'h00);
        apu_write(5'h0A, 8'h00);
        apu_write(5'h0B, 8'h08);
        tick(1);
        check8("triangle length loaded", dbg_tri_length, 8'd254);
        check11("triangle period is 0", dbg_tri_period, 11'd0);
        check1("triangle reload flag set by $400B", dbg_tri_reload_flag, 1'b1);
        check4("triangle silent before first quarter", dbg_tri_level, 4'd0);
        quarter_next(1);
        check7("triangle linear reloaded to 127", dbg_tri_linear, 7'd127);
        check1("control=1 keeps reload flag", dbg_tri_reload_flag, 1'b1);
        check5("triangle step still 0 before any timer tick", dbg_tri_step, 5'd0);
        for (i = 1; i <= 32; i = i + 1) begin
            tick(1);
            k = i % 32;
            if (dbg_tri_step !== k[4:0])
                $fatal(1, "triangle step %0d: got %0d", i, dbg_tri_step);
            if (dbg_tri_level !== ref_tri_sequence(k[4:0]))
                $fatal(1, "triangle level at step %0d: got %0d expected %0d",
                       k, dbg_tri_level, ref_tri_sequence(k[4:0]));
            check_mixer_now;
        end
        check5("triangle step wraps to 0", dbg_tri_step, 5'd0);
        $display("TRIANGLE 32-step sequence 15..0..0..15 and mixer inputs PASS");
    end
endtask

task test_triangle_linear;
    begin
        apply_reset;
        apu_write(5'h15, 8'h04);
        apu_write(5'h08, 8'h7F);
        apu_write(5'h09, 8'h00);
        apu_write(5'h0A, 8'h00);
        apu_write(5'h0B, 8'h08);
        tick(1);
        check7("linear counter idle before quarter", dbg_tri_linear, 7'd0);
        check1("reload flag set by $400B", dbg_tri_reload_flag, 1'b1);
        quarter_next(1);
        check7("Q1 reloads linear to 127", dbg_tri_linear, 7'd127);
        check1("control=0 clears reload flag", dbg_tri_reload_flag, 1'b0);
        quarter_next(2);
        check7("Q2 decrements linear", dbg_tri_linear, 7'd126);
        quarter_next(3);
        check7("Q3 decrements linear", dbg_tri_linear, 7'd125);
        quarter_next(4);
        check7("Q4 decrements linear", dbg_tri_linear, 7'd124);
        quarter_next(5);
        check7("next frame Q1 decrements linear", dbg_tri_linear, 7'd123);
        quarter_next(6);
        check7("Q6 decrements linear", dbg_tri_linear, 7'd122);
        check1("reload flag stays clear", dbg_tri_reload_flag, 1'b0);

        apu_write(5'h08, 8'h00);
        apu_write(5'h0B, 8'h08);
        check1("write $400B re-arms reload", dbg_tri_reload_flag, 1'b1);
        quarter_next(7);
        check7("reload value 0 keeps linear 0", dbg_tri_linear, 7'd0);
        check1("flag consumed by the quarter clock", dbg_tri_reload_flag, 1'b0);
        check4("linear 0 silences triangle", dbg_tri_level, 4'd0);
        tri_step_model = {1'b0, dbg_tri_step};
        tick(500);
        if (dbg_tri_step !== tri_step_model[4:0])
            $fatal(1, "triangle step advanced with linear counter 0: %0d -> %0d",
                   tri_step_model, dbg_tri_step);

        apu_write(5'h08, 8'hFF);
        check1("$4008 does not re-arm the reload flag", dbg_tri_reload_flag, 1'b0);
        quarter_next(8);
        check7("linear stays 0 without a reload request", dbg_tri_linear, 7'd0);
        apu_write(5'h0B, 8'h08);
        quarter_next(9);
        check7("control=1 reload 127 restores linear", dbg_tri_linear, 7'd127);
        check1("control=1 keeps reload flag set", dbg_tri_reload_flag, 1'b1);
        for (i = 0; i < 6; i = i + 1) begin
            quarter_next(10 + i);
            check7("held linear counter stays 127", dbg_tri_linear, 7'd127);
        end
        if (dbg_tri_level !== ref_tri_sequence(dbg_tri_step))
            $fatal(1, "triangle level does not follow the step");
        $display("TRIANGLE linear counter reload, halt, step gate and re-arm PASS");
    end
endtask

task test_triangle_length;
    begin
        apply_reset;
        apu_write(5'h08, 8'h00);
        apu_write(5'h0B, 8'h08);
        tick(1);
        check8("length not loaded while disabled", dbg_tri_length, 8'd0);
        apu_read(5'h15, rd_tmp);
        check8("$4015 triangle length bit clear", rd_tmp[2], 1'b0);

        apu_write(5'h15, 8'h04);
        apu_write(5'h0B, 8'h08);
        tick(1);
        check8("triangle length loaded on write", dbg_tri_length, 8'd254);
        apu_read(5'h15, rd_tmp);
        check8("$4015 triangle length bit set", rd_tmp[2], 1'b1);

        tick_to_count(16'd14912);
        tick(1);
        check8("triangle length after first half", dbg_tri_length, 8'd253);
        tick_to_count(16'd22370);
        tick(1);
        check8("triangle length stable on quarter", dbg_tri_length, 8'd253);
        tick_to_count(16'd29828);
        tick(1);
        check8("triangle length after second half", dbg_tri_length, 8'd252);

        apu_write(5'h08, 8'h80);
        tick_to_count(16'd7456);
        tick(1);
        tick_to_count(16'd14912);
        tick(1);
        check8("control bit halts triangle length", dbg_tri_length, 8'd252);
        apu_write(5'h08, 8'h00);
        tick_to_count(16'd22370);
        tick(1);
        tick_to_count(16'd29828);
        tick(1);
        check8("length resumes after clearing control", dbg_tri_length, 8'd251);

        apu_write(5'h0B, 8'h08);
        tick_to_count(16'd7456);
        tick(1);
        check8("length load beats the same-edge half clock", dbg_tri_length, 8'd254);
        apu_write(5'h15, 8'h00);
        check8("disable zeroes triangle length", dbg_tri_length, 8'd0);
        check4("triangle silent when disabled", dbg_tri_level, 4'd0);
        $display("TRIANGLE length load gate, half clock, control halt and disable PASS");
    end
endtask

task test_noise_registers;
    begin
        apply_reset;
        apu_write(5'h0C, 8'hBF);
        apu_read(5'h0C, rd_tmp);
        check8("$400C readback (bit7 unused)", rd_tmp, 8'h3F);
        apu_write(5'h0E, 8'h85);
        apu_read(5'h0E, rd_tmp);
        check8("$400E readback", rd_tmp, 8'h85);
        apu_write(5'h0F, 8'h1F);
        apu_read(5'h0F, rd_tmp);
        check8("$400F readback is the length index field", rd_tmp, 8'h18);
        check1("noise mode bit from $400E[7]", dbg_noise_mode, 1'b1);
        for (i = 0; i < 16; i = i + 1) begin
            apu_write(5'h0E, i[3:0]);
            if (dbg_noise_period !== ref_noise_period(i[3:0]))
                $fatal(1, "noise period table [%0d]: got %0d expected %0d",
                       i, dbg_noise_period, ref_noise_period(i[3:0]));
        end
        apu_write(5'h0E, 8'h05);
        check12("noise period index 5", dbg_noise_period, 12'd96);
        apu_write(5'h0C, 8'h00);
        apu_read(5'h0C, rd_tmp);
        check8("$400C clear readback", rd_tmp, 8'h00);
        $display("NOISE $400C-$400F readback and full NTSC period table PASS");
    end
endtask

task test_noise_lfsr;
    begin
        apply_reset;
        apu_write(5'h15, 8'h08);
        apu_write(5'h0C, 8'h1F);
        apu_write(5'h0E, 8'h00);
        apu_write(5'h0F, 8'h08);
        check12("noise period index 0", dbg_noise_period, 12'd4);
        check1("noise period 4 unmuted", dbg_noise_mute, 1'b0);
        check15("noise lfsr reset value", dbg_noise_lfsr, 15'd1);
        check4("noise silent while lfsr bit0 is set", dbg_noise_level, 4'd0);
        tick(1);
        check8("noise length loaded", dbg_noise_length, 8'd254);
        lfsr_model = 15'd1;
        lfsr_model = {lfsr_model[0] ^ lfsr_model[1], lfsr_model[14:1]};
        check15("first short-mode lfsr tick", dbg_noise_lfsr, 15'h4000);
        if (dbg_noise_level !== 4'd15)
            $fatal(1, "noise level did not follow the cleared lfsr bit0");
        for (i = 0; i < 64; i = i + 1) begin
            tick(4);
            lfsr_model = {lfsr_model[0] ^ lfsr_model[1], lfsr_model[14:1]};
            if (dbg_noise_lfsr !== lfsr_model)
                $fatal(1, "noise short-mode lfsr tick %0d: got %0d expected %0d",
                       i, dbg_noise_lfsr, lfsr_model);
            if (dbg_noise_level !== (dbg_noise_lfsr[0] ? 4'd0 : 4'd15))
                $fatal(1, "noise level gate at lfsr %0d: got %0d",
                       dbg_noise_lfsr, dbg_noise_level);
            check_mixer_now;
        end
        $display("NOISE short-mode LFSR sequence and output gate PASS");

        apply_reset;
        apu_write(5'h15, 8'h08);
        apu_write(5'h0C, 8'h1F);
        apu_write(5'h0E, 8'h80);
        apu_write(5'h0F, 8'h08);
        check1("noise long mode selected", dbg_noise_mode, 1'b1);
        lfsr_model = 15'd1;
        tick(1);
        lfsr_model = {lfsr_model[0] ^ lfsr_model[6], lfsr_model[14:1]};
        check15("first long-mode lfsr tick", dbg_noise_lfsr, 15'h4000);
        for (i = 0; i < 32; i = i + 1) begin
            tick(4);
            lfsr_model = {lfsr_model[0] ^ lfsr_model[6], lfsr_model[14:1]};
            if (dbg_noise_lfsr !== lfsr_model)
                $fatal(1, "noise long-mode lfsr tick %0d: got %0d expected %0d",
                       i, dbg_noise_lfsr, lfsr_model);
        end
        $display("NOISE long-mode LFSR feedback tap 6 PASS");

        apu_write(5'h15, 8'h00);
        check4("noise disabled by $4015", dbg_noise_level, 4'd0);
        $display("NOISE $4015 disable gate PASS");
    end
endtask

task test_noise_envelope_length;
    begin
        apply_reset;
        apu_write(5'h15, 8'h08);
        apu_write(5'h0E, 8'h00);
        apu_write(5'h0F, 8'h08);
        apu_write(5'h0C, 8'h01);
        tick(1);
        check4("noise $400F write sets decay 15", dbg_noise_env, 4'd15);
        check4("noise $400C write sets divider 1", dbg_noise_env_div, 4'd1);
        check8("noise length loaded", dbg_noise_length, 8'd254);
        quarter_next(1);
        check4("noise envelope quarter 1", dbg_noise_env, 4'd15);
        quarter_next(2);
        check4("noise envelope quarter 2", dbg_noise_env, 4'd15);
        check8("one half clock decremented the length", dbg_noise_length, 8'd253);
        quarter_next(3);
        check4("noise envelope quarter 3", dbg_noise_env, 4'd14);
        quarter_next(4);
        check4("noise envelope quarter 4", dbg_noise_env, 4'd14);
        quarter_next(5);
        check4("noise envelope next frame", dbg_noise_env, 4'd13);
        check8("two half clocks decremented the length", dbg_noise_length, 8'd252);
        apu_read(5'h15, rd_tmp);
        check8("$4015 noise length bit set", rd_tmp[3], 1'b1);

        apu_write(5'h17, 8'h00);
        tick(1);
        check16("frame counter restarted for the length part", dbg_frame_count, 16'd1);
        tick_to_count(16'd14912);
        tick(1);
        check8("noise length after first half clock", dbg_noise_length, 8'd251);
        tick_to_count(16'd22370);
        tick(1);
        check8("noise length stable on a quarter clock", dbg_noise_length, 8'd251);
        tick_to_count(16'd29828);
        tick(1);
        check8("noise length after second half clock", dbg_noise_length, 8'd250);

        apu_write(5'h0C, 8'h21);
        tick_to_count(16'd7456);
        tick(1);
        tick_to_count(16'd14912);
        tick(1);
        check8("halt freezes the noise length", dbg_noise_length, 8'd250);
        apu_write(5'h0C, 8'h01);
        tick_to_count(16'd22370);
        tick(1);
        tick_to_count(16'd29828);
        tick(1);
        check8("length resumes after clearing halt", dbg_noise_length, 8'd249);

        apu_write(5'h15, 8'h00);
        check8("noise length zeroed on disable", dbg_noise_length, 8'd0);
        check4("noise silent after disable", dbg_noise_level, 4'd0);
        $display("NOISE envelope, length status, halt and disable PASS");
    end
endtask

task test_dmc_registers;
    begin
        apply_reset;
        apu_write(5'h10, 8'h8F);
        apu_read(5'h10, rd_tmp);
        check8("$4010 readback", rd_tmp, 8'h8F);
        apu_write(5'h11, 8'h7F);
        apu_read(5'h11, rd_tmp);
        check8("$4011 readback", rd_tmp, 8'h7F);
        apu_write(5'h12, 8'h34);
        apu_read(5'h12, rd_tmp);
        check8("$4012 readback", rd_tmp, 8'h34);
        apu_write(5'h13, 8'h12);
        apu_read(5'h13, rd_tmp);
        check8("$4013 readback", rd_tmp, 8'h12);
        check16("$4012 sample address", dbg_dmc_sample_addr, 16'hCD00);
        apu_write(5'h11, 8'h00);
        apu_read(5'h11, rd_tmp);
        check8("$4011 clear readback", rd_tmp, 8'h00);
        apu_write(5'h12, 8'h00);
        apu_write(5'h13, 8'h00);
        check16("sample address minimum", dbg_dmc_sample_addr, 16'hC000);
        apu_write(5'h12, 8'hFF);
        check16("sample address maximum", dbg_dmc_sample_addr, 16'hFFC0);
        $display("DMC $4010-$4013 readback and sample address decode PASS");
    end
endtask

task test_dmc_bus_request;
    begin
        apply_reset;
        apu_write(5'h10, 8'h0F);
        apu_write(5'h11, 8'h40);
        apu_write(5'h12, 8'h40);
        apu_write(5'h13, 8'h00);
        check16("dmc sample addr before enable", dbg_dmc_sample_addr, 16'hD000);
        check12("dmc idle before enable", dbg_dmc_bytes_remaining, 12'd0);
        check1("dmc never requests while disabled", dmc_bus_req, 1'b0);
        apu_write(5'h15, 8'h10);
        check1("dmc active after $4015", dbg_dmc_active, 1'b1);
        check12("dmc sample length 1 byte", dbg_dmc_bytes_remaining, 12'd1);
        check16("dmc current addr = sample addr", dbg_dmc_current_addr, 16'hD000);
        check1("dmc raises a bus request", dmc_bus_req, 1'b1);
        apu_read(5'h15, rd_tmp);
        check8("$4015 bit4 set while playing", rd_tmp[4], 1'b1);
        freeze(3);
        check1("bus request cleared after ack", dmc_bus_req, 1'b0);
        check8("dmc sample buffer latched", dbg_dmc_sample_buf,
               dmc_sample_byte(16'hD000));
        check1("dmc buffer no longer empty", dbg_dmc_buf_empty, 1'b0);
        check16("dmc current addr advanced", dbg_dmc_current_addr, 16'hD001);
        check12("dmc bytes remaining hits 0", dbg_dmc_bytes_remaining, 12'd0);
        check1("dmc still active until the byte is played", dbg_dmc_active, 1'b1);
        apu_read(5'h15, rd_tmp);
        check8("$4015 bit4 clear once all bytes are fetched", rd_tmp[4], 1'b0);
        $display("DMC bus request/ack/address contract PASS");

        apply_reset;
        apu_write(5'h10, 8'h0F);
        apu_write(5'h12, 8'h40);
        apu_write(5'h13, 8'h08);
        apu_write(5'h15, 8'h10);
        check1("dmc request raised again", dmc_bus_req, 1'b1);
        apu_write(5'h15, 8'h00);
        check1("disable aborts the pending request", dmc_bus_req, 1'b0);
        check1("dmc inactive after abort", dbg_dmc_active, 1'b0);
        check12("abort clears bytes remaining", dbg_dmc_bytes_remaining, 12'd0);
        freeze(6);
        check1("aborted request never returns", dmc_bus_req, 1'b0);
        check16("abort leaves the address where the DMA stopped",
                dbg_dmc_current_addr, 16'hD001);
        apu_write(5'h15, 8'h10);
        check12("re-enable restarts the sample", dbg_dmc_bytes_remaining, 12'd129);
        check16("re-enable resets current addr", dbg_dmc_current_addr, 16'hD000);
        check1("buffered byte survives the restart, no immediate request",
               dmc_bus_req, 1'b0);
        guard = 0;
        while ((dmc_bus_req !== 1'b1) && (guard < 5000)) begin
            tick(1);
            guard = guard + 1;
        end
        if (dmc_bus_req !== 1'b1)
            $fatal(1, "dmc never requested a byte after the restart");
        check16("the new request points at the sample address",
                dbg_dmc_current_addr, 16'hD000);
        freeze(3);
        check8("fetched byte matches the sample address", dbg_dmc_sample_buf,
               dmc_sample_byte(16'hD000));
        check16("fetch advanced the address", dbg_dmc_current_addr, 16'hD001);
        check12("fetch decremented bytes remaining", dbg_dmc_bytes_remaining, 12'd128);
        $display("DMC abort on $4015 disable and restart contract PASS");
    end
endtask

task test_dmc_rate_and_output;
    begin
        apply_reset;
        apu_write(5'h10, 8'h0F);
        apu_write(5'h11, 8'h00);
        apu_write(5'h12, 8'h40);
        apu_write(5'h13, 8'h01);
        check16("rate test sample addr", dbg_dmc_sample_addr, 16'hD000);
        check12("rate test sample length", dbg_dmc_bytes_remaining, 12'd0);
        dmc_grant_enable = 1'b0;
        apu_write(5'h15, 8'h10);
        check12("sample length 17 bytes", dbg_dmc_bytes_remaining, 12'd17);
        check1("enable raises a bus request immediately", dmc_bus_req, 1'b1);
        tick(1);
        check9("first tick reloads the rate counter to 53", dbg_dmc_rate_cnt, 9'd53);
        check4("first tick loads 8 output bits", dbg_dmc_bits_remaining, 4'd8);
        check1("an empty buffer leaves the output unit silent", dbg_dmc_silence, 1'b1);
        check1("the request is still outstanding", dmc_bus_req, 1'b1);
        dmc_grant_enable = 1'b1;
        freeze(3);
        check8("first byte fetched from $D000", dbg_dmc_sample_buf,
               dmc_sample_byte(16'hD000));
        check16("addr moved to the second byte", dbg_dmc_current_addr, 16'hD001);
        check12("bytes remaining 16", dbg_dmc_bytes_remaining, 12'd16);

        tick(53);
        check9("rate counter reaches zero 53 ce after a tick", dbg_dmc_rate_cnt, 9'd0);
        check4("the output tick has not fired yet", dbg_dmc_bits_remaining, 4'd8);
        tick(1);
        check9("the 54th ce fires the output tick", dbg_dmc_rate_cnt, 9'd53);
        check4("tick 1 lands 54 ce after tick 0", dbg_dmc_bits_remaining, 4'd7);
        check1("no new request while the byte is still buffered", dmc_bus_req, 1'b0);
        dmc_level_exp = 7'd0;
        for (i = 0; i < 23; i = i + 1) begin
            pre_level = dbg_dmc_output;
            pre_byte = dbg_dmc_bits[0];
            pre_silence = dbg_dmc_silence;
            tick(54);
            if (!pre_silence) begin
                if (pre_byte) begin
                    if (pre_level > 7'd125)
                        dmc_level_exp = 7'd127;
                    else
                        dmc_level_exp = pre_level + 7'd2;
                end else begin
                    if (pre_level < 7'd2)
                        dmc_level_exp = 7'd0;
                    else
                        dmc_level_exp = pre_level - 7'd2;
                end
            end else begin
                dmc_level_exp = pre_level;
            end
            if (dbg_dmc_output !== dmc_level_exp)
                $fatal(1, "dmc level after bit %0d: got %0d expected %0d",
                       i, dbg_dmc_output, dmc_level_exp);
        end
        check7("two bytes of delta bits end at level 6", dbg_dmc_output, 7'd6);
        check16("two bytes played, third prefetched", dbg_dmc_current_addr, 16'hD003);
        check12("bytes remaining 14", dbg_dmc_bytes_remaining, 12'd14);
        $display("DMC rate table reload, 54 ce tick spacing and 8 bits per byte PASS");
    end
endtask

task test_dmc_delta_and_irq;
    begin
        apply_reset;
        apu_write(5'h10, 8'h8F);
        apu_write(5'h11, 8'h00);
        apu_write(5'h12, 8'h80);
        apu_write(5'h13, 8'h00);
        check16("dmc sample addr for delta test", dbg_dmc_sample_addr, 16'hE000);
        apu_write(5'h15, 8'h10);
        tick(1);
        freeze(3);
        check8("byte 1 loaded into the shift register", dbg_dmc_bits, 8'h5A);
        check4("8 delta bits pending", dbg_dmc_bits_remaining, 4'd8);
        check1("output unit leaves silence", dbg_dmc_silence, 1'b0);
        $display("  delta test byte = %02h", dbg_dmc_bits);
        dmc_level_exp = 7'd0;
        for (i = 0; i < 8; i = i + 1) begin
            pre_level = dbg_dmc_output;
            pre_byte = dbg_dmc_bits[0];
            pre_silence = dbg_dmc_silence;
            tick(54);
            if (!pre_silence && pre_byte)
                dmc_level_exp = (pre_level > 7'd125) ? 7'd127 : (pre_level + 7'd2);
            else if (!pre_silence && (pre_level >= 7'd2))
                dmc_level_exp = pre_level - 7'd2;
            if (dbg_dmc_output !== dmc_level_exp)
                $fatal(1, "delta level after bit %0d: got %0d expected %0d",
                       i, dbg_dmc_output, dmc_level_exp);
        end
        if (dmc_level_exp === 7'd0)
            $fatal(1, "delta test never moved the output level");
        check7("the 8 delta bits of $5A end at level 2", dbg_dmc_output, 7'd2);
        check1("dmc irq asserted after the last bit is played", dbg_dmc_irq, 1'b1);
        check1("dmc irq reaches the irq line", irq, 1'b1);
        check1("dmc stopped", dbg_dmc_active, 1'b0);
        check4("dmc bit counter parked at 0", dbg_dmc_bits_remaining, 4'd0);
        check1("dmc output unit silent after the sample", dbg_dmc_silence, 1'b1);
        apu_read(5'h15, rd_tmp);
        check8("$4015 bit7 reports dmc irq", rd_tmp[7], 1'b1);
        check8("$4015 bit4 clear after stop", rd_tmp[4], 1'b0);
        check1("reading $4015 clears dmc irq", dbg_dmc_irq, 1'b0);
        check1("irq line low after read", irq, 1'b0);

        apu_write(5'h15, 8'h10);
        guard = 0;
        while ((dbg_dmc_irq !== 1'b1) && (guard < 2000)) begin
            tick(1);
            guard = guard + 1;
        end
        check1("dmc irq re-asserted on replay", dbg_dmc_irq, 1'b1);
        apu_write(5'h10, 8'h0F);
        check1("writing $4010 with irq disable acks", dbg_dmc_irq, 1'b0);
        check1("irq line low after $4010 ack", irq, 1'b0);

        apu_write(5'h10, 8'h8F);
        apu_write(5'h15, 8'h10);
        guard = 0;
        while ((dbg_dmc_irq !== 1'b1) && (guard < 2000)) begin
            tick(1);
            guard = guard + 1;
        end
        check1("dmc irq set again", dbg_dmc_irq, 1'b1);
        apu_write(5'h15, 8'h00);
        check1("writing $4015 clears dmc irq", dbg_dmc_irq, 1'b0);
        check1("irq line low after the $4015 ack", irq, 1'b0);
        $display("DMC delta modulation, output unit refill and end-of-sample IRQ PASS");
    end
endtask

task test_dmc_loop_and_wrap;
    begin
        apply_reset;
        apu_write(5'h10, 8'h4F);
        apu_write(5'h11, 8'h00);
        apu_write(5'h12, 8'hFF);
        apu_write(5'h13, 8'h04);
        check16("loop sample addr $FFC0", dbg_dmc_sample_addr, 16'hFFC0);
        apu_write(5'h15, 8'h10);
        check12("loop sample length 65", dbg_dmc_bytes_remaining, 12'd65);
        check1("dmc loop does not set irq", dbg_dmc_irq, 1'b0);
        guard = 0;
        while ((dbg_dmc_bytes_remaining != 12'd64) && (guard < 4000)) begin
            tick(1);
            guard = guard + 1;
        end
        if (dbg_dmc_bytes_remaining != 12'd64)
            $fatal(1, "loop mode never delivered the first byte");
        check16("first loop byte read from $FFC0", dbg_dmc_sample_buf,
                dmc_sample_byte(16'hFFC0));
        check16("loop addr advanced to $FFC1", dbg_dmc_current_addr, 16'hFFC1);
        guard = 0;
        while ((dbg_dmc_current_addr != 16'h8000) && (guard < 200000)) begin
            tick(1);
            guard = guard + 1;
            check_mixer_now;
        end
        if (dbg_dmc_current_addr != 16'h8000)
            $fatal(1, "dmc address never wrapped from $FFFF to $8000");
        guard = 0;
        while ((dbg_dmc_bytes_remaining != 12'd65) && (guard < 200000)) begin
            tick(1);
            guard = guard + 1;
            check_mixer_now;
        end
        if (dbg_dmc_bytes_remaining != 12'd65)
            $fatal(1, "loop mode never reloaded the sample length");
        check16("loop returned to the sample address", dbg_dmc_current_addr, 16'hFFC0);
        check1("loop never raises dmc irq", dbg_dmc_irq, 1'b0);
        check1("loop keeps the channel active", dbg_dmc_active, 1'b1);
        $display("DMC $FFFF to $8000 address wrap, loop reload and no IRQ PASS");
    end
endtask

task test_status_all_channels;
    begin
        apply_reset;
        apu_write(5'h15, 8'h0F);
        apu_read(5'h15, rd_tmp);
        check8("$4015 enables but no lengths yet", {3'b000, rd_tmp[4:0]}, 8'h00);
        check8("$4015 bit5 is always zero", rd_tmp[5], 1'b0);

        apu_write(5'h11, 8'h00);
        apu_write(5'h12, 8'h40);
        apu_write(5'h13, 8'h08);
        apu_write(5'h01, 8'h00);
        apu_write(5'h02, 8'h08);
        apu_write(5'h03, 8'h08);
        apu_write(5'h05, 8'h00);
        apu_write(5'h06, 8'h08);
        apu_write(5'h07, 8'h08);
        apu_write(5'h09, 8'h00);
        apu_write(5'h0A, 8'h00);
        apu_write(5'h0B, 8'h08);
        apu_write(5'h0E, 8'h00);
        apu_write(5'h0F, 8'h08);
        apu_write(5'h15, 8'h1F);
        apu_write(5'h03, 8'h08);
        apu_write(5'h07, 8'h08);
        apu_write(5'h0B, 8'h08);
        apu_write(5'h0F, 8'h08);
        tick(1);
        apu_read(5'h15, rd_tmp);
        check8("$4015 all five channels active", {3'b000, rd_tmp[4:0]}, 8'h1F);
        check8("$4015 bit5 still zero", rd_tmp[5], 1'b0);
        check8("pulse1 length status", dbg_pulse1_length, 8'd254);
        check8("pulse2 length status", dbg_pulse2_length, 8'd254);
        check8("triangle length status", dbg_tri_length, 8'd254);
        check8("noise length status", dbg_noise_length, 8'd254);
        check12("dmc already fetched its first byte", dbg_dmc_bytes_remaining, 12'd128);

        apu_write(5'h15, 8'h0E);
        check8("pulse1 length zeroed", dbg_pulse1_length, 8'd0);
        check8("pulse2 length kept while enabled", dbg_pulse2_length, 8'd254);
        check8("triangle length kept", dbg_tri_length, 8'd254);
        check8("noise length kept", dbg_noise_length, 8'd254);
        apu_read(5'h15, rd_tmp);
        check8("$4015 after disabling pulse 1", {3'b000, rd_tmp[4:0]}, 8'h0E);
        apu_write(5'h15, 8'h0C);
        check8("pulse2 length zeroed", dbg_pulse2_length, 8'd0);
        apu_read(5'h15, rd_tmp);
        check8("$4015 after disabling both pulses", {3'b000, rd_tmp[4:0]}, 8'h0C);
        $display("STATUS $4015 bits 0-4 and the bit5 open-bus stub PASS");
    end
endtask

task test_mixer_lut;
    begin
        apply_reset;
        for (i = 0; i < 128; i = i + 1) begin
            apu_write(5'h11, i[7:0]);
            if (dbg_dmc_output !== i[6:0])
                $fatal(1, "$4011 write %0d did not stick", i);
            if (dbg_tnd_sum !== i[7:0])
                $fatal(1, "tnd index %0d: got %0d", i, dbg_tnd_sum);
            if (dbg_mix_tnd !== ref_tnd_lut(i[7:0]))
                $fatal(1, "tnd lut[%0d]: got %0d expected %0d", i,
                       dbg_mix_tnd, ref_tnd_lut(i[7:0]));
        end
        for (i = 1; i < 31; i = i + 1) begin
            if (i == 15 && ref_pulse_lut(i[5:0]) !== 16'd4895)
                $fatal(1, "pulse reference self-check failed at %0d", i);
            if (i == 30 && ref_pulse_lut(i[5:0]) !== 16'd8470)
                $fatal(1, "pulse reference self-check failed at %0d", i);
        end
        $display("MIXER tnd lut indices 0-127 and pulse lut match the reference formula PASS");
    end
endtask

task test_sample_output;
    begin
        apply_reset;
        apu_write(5'h15, 8'h01);
        apu_write(5'h01, 8'h00);
        apu_write(5'h02, 8'h08);
        apu_write(5'h03, 8'h08);
        apu_write(5'h00, 8'h8F);
        tick(1);
        ce_sample = 1'b1;
        guard = 0;
        while ((dbg_pulse1_duty_step != 3'd1) && (guard < 4000)) begin
            tick(1);
            guard = guard + 1;
        end
        if (dbg_pulse1_duty_step != 3'd1)
            $fatal(1, "sample output test never reached duty step 1");
        check4("pulse1 level 15", dbg_pulse1_level, 4'd15);
        check16("mixer pulse lut(15)", dbg_mix_pulse, 16'd4895);
        check16("combinational mixed sample", dut.mixed_sample, 16'd4895);
        check1("sample_valid asserted", sample_valid, 1'b1);
        tick(1);
        check16("sample_left tracks the pulse mixer", sample_left, 16'd4895);
        check16("sample_right tracks the pulse mixer", sample_right, 16'd4895);
        check_mixer_now;
        ce_sample = 1'b0;
        tick(1);
        check1("sample_valid drops without ce_sample", sample_valid, 1'b0);
        check16("sample_left holds the last value", sample_left, 16'd4895);
        check16("sample_right holds the last value", sample_right, 16'd4895);
        $display("SAMPLE register latch, hold and sample_valid strobe PASS");
    end
endtask

task test_five_channel_mix;
    begin
        apply_reset;
        apu_write(5'h11, 8'h7F);
        apu_write(5'h13, 8'h00);
        apu_write(5'h0C, 8'h1F);
        apu_write(5'h0E, 8'h00);
        apu_write(5'h0F, 8'h08);
        apu_write(5'h08, 8'hFF);
        apu_write(5'h09, 8'h00);
        apu_write(5'h0A, 8'h00);
        apu_write(5'h0B, 8'h08);
        apu_write(5'h15, 8'h0C);
        apu_write(5'h0F, 8'h08);
        apu_write(5'h0B, 8'h08);
        apu_write(5'h15, 8'h0D);
        apu_write(5'h01, 8'h00);
        apu_write(5'h02, 8'h0F);
        apu_write(5'h03, 8'h08);
        apu_write(5'h00, 8'h8F);
        apu_write(5'h15, 8'h0F);
        apu_write(5'h04, 8'h8F);
        apu_write(5'h05, 8'h00);
        apu_write(5'h06, 8'h0F);
        apu_write(5'h07, 8'h08);
        tick(1);
        check11("pulse1 period 0x00F for the clamp hunt", dbg_pulse1_period, 11'h00F);
        check11("pulse2 period 0x00F for the clamp hunt", dbg_pulse2_period, 11'h00F);
        check11("triangle period 0 for the clamp hunt", dbg_tri_period, 11'h0);
        check12("noise shortest period", dbg_noise_period, 12'd4);
        check8("triangle length loaded", dbg_tri_length, 8'd254);
        check8("noise length loaded", dbg_noise_length, 8'd254);
        check8("pulse1 length loaded", dbg_pulse1_length, 8'd254);
        check8("pulse2 length loaded", dbg_pulse2_length, 8'd254);
        check7("dmc output parked at 127", dbg_dmc_output, 7'd127);
        clamp_hits = 0;
        guard = 0;
        while ((clamp_hits == 0) && (guard < 40000)) begin
            tick(1);
            guard = guard + 1;
            check_mixer_now;
        end
        if (clamp_hits == 0)
            $fatal(1, "mixer never reached the clamped operating point in %0d ce", guard);
        check4("triangle level 15 at the clamp point", dbg_tri_level, 4'd15);
        check4("noise level 15 at the clamp point", dbg_noise_level, 4'd15);
        check6("pulse sum 30 at the clamp point", dbg_pulse_sum, 6'd30);
        check8("tnd index 202 at the clamp point", dbg_tnd_sum, 8'd202);
        check16("pulse lut(30)", dbg_mix_pulse, 16'd8470);
        check16("tnd lut(202)", dbg_mix_tnd, 16'd24328);
        check17("mix sum exceeds 16 bit before clamping", dbg_mix_sum, 17'd32798);
        check16("mixed sample clamped to 32767", dut.mixed_sample, 16'd32767);
        $display("MIXER five-channel sum and the 32767 clamp PASS after %0d ce", guard);
        $display("MIXER validated %0d operating points against the reference formula",
                 mixer_checks);
    end
endtask

task test_dmc_irq_frame_mix;
    begin
        apply_reset;
        apu_write(5'h10, 8'h8F);
        apu_write(5'h12, 8'h50);
        apu_write(5'h13, 8'h00);
        apu_write(5'h15, 8'h10);
        guard = 0;
        while ((dbg_dmc_irq !== 1'b1) && (guard < 4000)) begin
            tick(1);
            guard = guard + 1;
        end
        check1("dmc irq asserted", dbg_dmc_irq, 1'b1);
        apu_read(5'h15, rd_tmp);
        check8("$4015 reports only the dmc irq", rd_tmp & 8'hC0, 8'h80);
        check1("reading $4015 clears the dmc irq", dbg_dmc_irq, 1'b0);
        check1("irq line low after the read", irq, 1'b0);

        apu_write(5'h15, 8'h10);
        guard = 0;
        while ((dbg_dmc_irq !== 1'b1) && (guard < 4000)) begin
            tick(1);
            guard = guard + 1;
        end
        check1("dmc irq re-asserted on the replay", dbg_dmc_irq, 1'b1);
        guard = 0;
        while ((dbg_frame_irq !== 1'b1) && (guard < 40000)) begin
            tick(1);
            guard = guard + 1;
        end
        if (dbg_frame_irq !== 1'b1)
            $fatal(1, "frame irq never asserted while the dmc irq was held");
        check1("irq line stays high with both sources", irq, 1'b1);
        apu_read(5'h15, rd_tmp);
        check8("$4015 reports both irq flags", rd_tmp & 8'hC0, 8'hC0);
        check1("read clears the frame irq", dbg_frame_irq, 1'b0);
        check1("read clears the dmc irq", dbg_dmc_irq, 1'b0);
        check1("irq line low after one read", irq, 1'b0);

        guard = 0;
        while ((dbg_frame_irq !== 1'b1) && (guard < 40000)) begin
            tick(1);
            guard = guard + 1;
        end
        if (dbg_frame_irq !== 1'b1)
            $fatal(1, "frame irq never re-asserted after the aggregated clear");
        mark = ce_edges;
        apu_read(5'h15, rd_tmp);
        guard = 0;
        while ((dbg_frame_irq !== 1'b1) && (guard < 40000)) begin
            tick(1);
            guard = guard + 1;
        end
        if (dbg_frame_irq !== 1'b1)
            $fatal(1, "frame irq never came back a second time");
        check16("frame irq to irq period is still 29830 ce",
                ce_edges - mark, 16'd29830);
        $display("IRQ frame+dmc aggregation, independent clear and 29830 ce period PASS");
    end
endtask

initial begin
    clk = 1'b0;
    reset = 1'b0;
    ce = 1'b0;
    ce_sample = 1'b0;
    reg_cs = 1'b0;
    reg_we = 1'b0;
    reg_addr = 5'd0;
    reg_din = 8'h00;
    dmc_pending = 1'b0;
    dmc_grant_enable = 1'b1;
    clamp_hits = 0;
    mixer_checks = 0;

    test_reset_state;
    test_pulse_registers;
    test_ce_freeze;
    test_status_and_length;
    test_duty_and_mix;
    test_envelope;
    test_sweep;
    test_frame_irq_4step;
    test_frame_5step;
    test_frame_inhibit;
    test_triangle_registers;
    test_triangle_waveform;
    test_triangle_linear;
    test_triangle_length;
    test_noise_registers;
    test_noise_lfsr;
    test_noise_envelope_length;
    test_dmc_registers;
    test_dmc_bus_request;
    test_dmc_rate_and_output;
    test_dmc_delta_and_irq;
    test_dmc_loop_and_wrap;
    test_status_all_channels;
    test_mixer_lut;
    test_sample_output;
    test_five_channel_mix;
    test_dmc_irq_frame_mix;

    $display("PASS nes_apu2a03 v1");
    $finish;
end

endmodule
