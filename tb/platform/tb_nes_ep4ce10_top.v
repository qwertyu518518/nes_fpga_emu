`timescale 1ns/1ps

// ============================================================================
// tb_nes_ep4ce10_top : EP4CE10 平台顶层 testbench
// ----------------------------------------------------------------------------
// 两个理想时钟驱动 rtl/platform/ep4ce10/nes_ep4ce10_top.v：
//   clk_ntsc  21.477272 MHz（半周期 23.275 ns）—— 文档 12 定义的 NES 主时钟。
//             核内 div_phase 再分出 ce_cpu = /12 (1.789773 MHz, 558.7 ns) 与
//             ce_ppu = /4 (5.369318 MHz)。1.789773 MHz 是 CPU 速率，不是本顶层
//             的时钟输入。
//   clk_vga   25 MHz（半周期 20 ns）
//   clk_sys   50 MHz（半周期 10 ns），只用于按键消抖
// 消抖窗口用参数缩短（DEBOUNCE_US = 16，即 800 个 clk_sys），出厂默认仍是
// 16000 us = 16 ms @ 50 MHz，见 rtl/platform/ep4ce10/nes_ep4ce10_top.v 的模块头。
//
// 断言清单：
//   1. VGA：hsync/vsync/de 逐像素与 800x525 模型一致；每行 96 个 hsync 周期；
//      可见行 512 个 de 周期、消隐行 0 个；vsync 恰好 3 行；帧周期 420000 拍。
//   2. PPU 像素进入行缓冲：wr_ce 每个 dot 采一次，pixel_x 严格逐个递增 0..255，
//      每行 341 个 dot（一帧内 239 次，帧边界处 23*341 因为 240..261 消隐行
//      不产生可见像素）；line_done 在 x=255 之后一拍拉高；line_ready_toggle
//      每写一行翻一次。
//   3. 按键：clk_sys 域两级同步 + 消抖后才允许电平变化（>= DEBOUNCE_CYCLES 拍），
//      变化后 <= 4 个 clk_ntsc 内出现在 buttons1[3:0]，高 4 位恒为 1。
//   4. 音频：audio_valid 是 1 拍宽 strobe，复位期间为 0，出现非零样点。
//   5. 非零像素：vga_r/vga_g/vga_b 出现非零，说明 PPU -> 行缓冲 -> VGA 时序打通。
// ============================================================================

module tb_nes_ep4ce10_top;

    localparam real NTSC_HALF_NS = 23.275;
    localparam real VGA_HALF_NS  = 20.0;
    localparam real SYS_HALF_NS  = 10.0;

    localparam integer TB_DEBOUNCE_US     = 16;
    localparam integer TB_DEBOUNCE_CYCLES = (50_000_000 / 1_000_000) * TB_DEBOUNCE_US;

    localparam integer NES_FRAMES_TARGET = 3;
    localparam integer VGA_FRAME_CYCLES  = 420000;
    localparam integer DOTS_PER_LINE     = 341;
    localparam integer DOTS_PER_FRAME    = DOTS_PER_LINE * 262;
    localparam integer VISIBLE_LINES     = 240;
    localparam integer FRAME_WRAP_DOTS   = 23 * DOTS_PER_LINE;

    localparam [15:0] MAIN_PROG = 16'h8000;
    localparam [15:0] NMI_PROG  = 16'h8400;
    localparam integer PRG_BYTES = 16384;

    reg clk_sys;
    reg clk_ntsc;
    reg clk_vga;
    reg reset_n;
    reg [3:0] key_vec;

    wire        vga_hsync;
    wire        vga_vsync;
    wire        vga_de;
    wire [4:0]  vga_r;
    wire [5:0]  vga_g;
    wire [4:0]  vga_b;
    wire        audio_valid;
    wire [15:0] audio_left;

    integer i;
    reg [15:0] pc;

    reg [7:0] toggle_prev;
    reg [7:0] x_expect;
    reg [3:0] key_stable_prev;
    reg       have_x;
    reg       line_pending;
    reg       fd_prev;
    reg       ntsc_reset_edge;
    reg       audio_run;
    reg       exp_hs;
    reg       exp_vs;
    reg       exp_de;

    integer nes_frames;
    integer nes_lines;
    integer nes_line_ce;
    integer last_line_ce;
    integer line_period;
    integer lines_short;
    integer lines_wrap;
    integer line_done_count;
    integer lb_toggles;
    integer index0;
    integer index1;
    integer ppu_ce_total;

    integer vga_cycles;
    integer vga_frames;
    integer vga_frame_mark;
    integer vga_frame_delta;
    integer hs_run;
    integer de_run;
    integer vs_lines;
    integer nonzero_px;
    integer de_px;

    integer audio_strobes;
    integer audio_nonzero;
    integer guard;

    nes_ep4ce10_top #(
        .CLK_SYS_HZ (50_000_000),
        .DEBOUNCE_US(TB_DEBOUNCE_US)
    ) dut (
        .clk_sys    (clk_sys),
        .clk_ntsc   (clk_ntsc),
        .clk_vga    (clk_vga),
        .reset_n    (reset_n),
        .key0       (key_vec[0]),
        .key1       (key_vec[1]),
        .key2       (key_vec[2]),
        .key3       (key_vec[3]),
        .vga_hsync  (vga_hsync),
        .vga_vsync  (vga_vsync),
        .vga_de     (vga_de),
        .vga_r      (vga_r),
        .vga_g      (vga_g),
        .vga_b      (vga_b),
        .audio_valid(audio_valid),
        .audio_left (audio_left)
    );

    always #(NTSC_HALF_NS) clk_ntsc = ~clk_ntsc;
    always #(VGA_HALF_NS)  clk_vga  = ~clk_vga;
    always #(SYS_HALF_NS)  clk_sys  = ~clk_sys;

    // ------------------------------------------------------------- ROM 构建
    task emit;
        input [7:0] value;
        begin
            dut.u_nes.prg_rom[pc[13:0]] = value;
            pc = pc + 16'd1;
        end
    endtask

    task lda_imm;
        input [7:0] value;
        begin
            emit(8'hA9);
            emit(value);
        end
    endtask

    task sta_abs;
        input [15:0] address;
        begin
            emit(8'h8D);
            emit(address[7:0]);
            emit(address[15:8]);
        end
    endtask

    task jmp_abs;
        input [15:0] address;
        begin
            emit(8'h4C);
            emit(address[7:0]);
            emit(address[15:8]);
        end
    endtask

    task set_vector;
        input [15:0] vector;
        input [15:0] target;
        begin
            dut.u_nes.prg_rom[vector[13:0]]     = target[7:0];
            dut.u_nes.prg_rom[vector[13:0] + 1] = target[15:8];
        end
    endtask

    task build_program;
        reg [15:0] self_loop;
        begin
            for (i = 0; i < PRG_BYTES; i = i + 1)
                dut.u_nes.prg_rom[i[13:0]] = 8'hEA;

            pc = MAIN_PROG;
            emit(8'h58);
            emit(8'hD8);

            lda_imm(8'h0F);
            sta_abs(16'h4015);
            lda_imm(8'hBF);
            sta_abs(16'h4000);
            lda_imm(8'h00);
            sta_abs(16'h4001);
            lda_imm(8'h20);
            sta_abs(16'h4002);
            lda_imm(8'h40);
            sta_abs(16'h4003);
            lda_imm(8'h40);
            sta_abs(16'h4017);
            lda_imm(8'h1E);
            sta_abs(16'h2001);

            self_loop = pc;
            jmp_abs(self_loop);

            pc = NMI_PROG;
            emit(8'h40);

            set_vector(16'hFFFA, NMI_PROG);
            set_vector(16'hFFFC, MAIN_PROG);
            set_vector(16'hFFFE, NMI_PROG);
        end
    endtask

    task load_video_ram;
        begin
            for (i = 0; i < 2048; i = i + 1)
                dut.u_nes.u_ppu.nametable_ram[i] = 8'h00;
            for (i = 0; i < 32; i = i + 1)
                dut.u_nes.u_ppu.palette_ram[i] = 8'h21;
            for (i = 0; i < 256; i = i + 1)
                dut.u_nes.u_ppu.oam_ram[i] = 8'hFF;
            for (i = 0; i < 16; i = i + 1)
                dut.u_nes.u_ppu.chr_ram[i] = 8'hFF;
        end
    endtask

    // --------------------------------------------------------- 按键消抖检查
    task press;
        input [3:0] raw;
        input [3:0] expect_buttons;
        begin
            key_vec = raw;
            #1;
            guard = 0;
            while (dut.key_stable_q !== raw) begin
                @(posedge clk_sys);
                guard = guard + 1;
                if (guard > TB_DEBOUNCE_CYCLES + 64)
                    $fatal(1, "TOP the debounced level never reached %b", raw);
            end
            if (guard < TB_DEBOUNCE_CYCLES)
                $fatal(1, "TOP the debounce committed after %0d clk_sys, at least %0d are required",
                       guard, TB_DEBOUNCE_CYCLES);
            if (guard > TB_DEBOUNCE_CYCLES + 8)
                $fatal(1, "TOP the debounce took %0d clk_sys, expected %0d",
                       guard, TB_DEBOUNCE_CYCLES + 2);
            guard = 0;
            while (dut.buttons1[3:0] !== expect_buttons) begin
                @(posedge clk_ntsc);
                guard = guard + 1;
                if (guard > 8)
                    $fatal(1, "TOP buttons1[3:0] stayed at %b, expected %b",
                           dut.buttons1[3:0], expect_buttons);
            end
        end
    endtask

    task wait_frames;
        input integer target;
        begin
            guard = 0;
            while (nes_frames < target) begin
                @(posedge clk_ntsc);
                guard = guard + 1;
                if (guard > 4000000)
                    $fatal(1, "TOP only %0d nes frames completed, expected %0d", nes_frames, target);
            end
        end
    endtask

    // --------------------------------------------------------------- clk_sys
    always @(posedge clk_sys) begin
        if (!reset_n) begin
            if (dut.key_stable_q !== 4'b1111)
                $fatal(1, "TOP key_stable_q is %b during reset", dut.key_stable_q);
            key_stable_prev = 4'b1111;
        end else begin
            if (dut.key_stable_q !== dut.key_candidate_q)
                $fatal(1, "TOP key_stable_q %b and key_candidate_q %b disagree",
                       dut.key_stable_q, dut.key_candidate_q);
            if ((dut.key_sync_q == dut.key_candidate_q) && (dut.key_cnt_q !== 0))
                $fatal(1, "TOP the debounce counter is %0d while the input already matches the candidate",
                       dut.key_cnt_q);
            if ((dut.key_stable_q !== key_stable_prev) && (dut.key_stable_q !== dut.key_sync_q))
                $fatal(1, "TOP key_stable_q jumped to %b, which is neither the previous level nor the input",
                       dut.key_stable_q);
            key_stable_prev = dut.key_stable_q;
        end
    end

    // -------------------------------------------------------------- clk_ntsc
    always @(posedge clk_ntsc) begin
        if (dut.rst_ntsc) begin
            if (ntsc_reset_edge && (audio_valid !== 1'b0))
                $fatal(1, "TOP audio_valid is high during the ntsc reset");
            ntsc_reset_edge = 1'b1;
            have_x         = 1'b0;
            line_pending   = 1'b0;
            x_expect       = 8'd0;
            nes_line_ce    = 0;
            last_line_ce   = 0;
            toggle_prev    = 8'd0;
            fd_prev        = 1'b0;
            audio_run      = 1'b0;
        end else begin
            if (line_pending) begin
                if (dut.u_lb.line_done !== 1'b1)
                    $fatal(1, "TOP line_done did not follow the last pixel of line %0d", nes_lines - 1);
                line_pending      = 1'b0;
                line_done_count   = line_done_count + 1;
            end

            if (dut.buttons1[3:0] !== ~dut.btn_sync_q[3:0])
                $fatal(1, "TOP buttons1[3:0] is %b but the synchronized debounced level is %b",
                       dut.buttons1[3:0], ~dut.btn_sync_q[3:0]);
            if (dut.buttons1[7:4] !== 4'b1111)
                $fatal(1, "TOP buttons1[7:4] is %b, expected 1111", dut.buttons1[7:4]);
            if (dut.buttons2 !== 8'hFF)
                $fatal(1, "TOP buttons2 is %02h, expected ff", dut.buttons2);

            if (audio_valid === 1'b1) begin
                audio_strobes = audio_strobes + 1;
                audio_run     = audio_run + 1;
                if (audio_left !== 16'h0000)
                    audio_nonzero = audio_nonzero + 1;
            end else begin
                audio_run = 1'b0;
            end
            if (audio_run > 1)
                $fatal(1, "TOP audio_valid stayed high for %0d clk_ntsc, it must be a one clk strobe", audio_run);

            if (dut.ppu_ce) begin
                ppu_ce_total = ppu_ce_total + 1;
                nes_line_ce  = nes_line_ce + 1;
                if (dut.ppu_pixel_valid) begin
                    if (have_x && (dut.ppu_pixel_x !== x_expect))
                        $fatal(1, "TOP the line buffer write clock enable sampled x=%0d, expected %0d",
                               dut.ppu_pixel_x, x_expect);
                    have_x   = 1'b1;
                    x_expect = (dut.ppu_pixel_x == 8'd255) ? 8'd0 : (dut.ppu_pixel_x + 8'd1);
                    if (dut.ppu_pixel_index === 4'd0)
                        index0 = index0 + 1;
                    else
                        index1 = index1 + 1;
                    if (dut.ppu_pixel_x == 8'd255) begin
                        line_pending = 1'b1;
                        if (nes_lines > 0) begin
                            line_period = nes_line_ce - last_line_ce;
                            if (line_period == DOTS_PER_LINE)
                                lines_short = lines_short + 1;
                            else if (line_period == FRAME_WRAP_DOTS)
                                lines_wrap = lines_wrap + 1;
                            else
                                $fatal(1, "TOP the dot clock enable period before line %0d is %0d, expected %0d or %0d",
                                       nes_lines, line_period, DOTS_PER_LINE, FRAME_WRAP_DOTS);
                        end
                        last_line_ce = nes_line_ce;
                        nes_lines    = nes_lines + 1;
                    end
                end
            end

            if (toggle_prev !== dut.u_lb.line_ready_toggle) begin
                toggle_prev = dut.u_lb.line_ready_toggle;
                lb_toggles  = lb_toggles + 1;
            end

            if (dut.nes_frame_done && !fd_prev)
                nes_frames = nes_frames + 1;
            fd_prev = dut.nes_frame_done;
        end
    end

    // --------------------------------------------------------------- clk_vga
    always @(posedge clk_vga) begin
        if (dut.rst_vga) begin
            vga_cycles      = 0;
            vga_frames      = 0;
            vga_frame_mark  = 0;
            vga_frame_delta = 0;
            hs_run          = 0;
            de_run          = 0;
            vs_lines        = 0;
        end else begin
            vga_cycles = vga_cycles + 1;

            exp_hs = (dut.u_vga.hcount >= 10'd656) && (dut.u_vga.hcount < 10'd752);
            exp_vs = (dut.u_vga.vcount >= 10'd490) && (dut.u_vga.vcount < 10'd493);
            exp_de = (dut.u_vga.hcount >= 10'd64) && (dut.u_vga.hcount < 10'd576) &&
                     (dut.u_vga.vcount < 10'd480);

            if (vga_hsync !== exp_hs)
                $fatal(1, "TOP hsync is %b at (%0d,%0d), expected %b",
                       vga_hsync, dut.u_vga.hcount, dut.u_vga.vcount, exp_hs);
            if (vga_vsync !== exp_vs)
                $fatal(1, "TOP vsync is %b at (%0d,%0d), expected %b",
                       vga_vsync, dut.u_vga.hcount, dut.u_vga.vcount, exp_vs);
            if (vga_de !== exp_de)
                $fatal(1, "TOP de is %b at (%0d,%0d), expected %b",
                       vga_de, dut.u_vga.hcount, dut.u_vga.vcount, exp_de);

            if (vga_hsync === 1'b1)
                hs_run = hs_run + 1;
            if (vga_de === 1'b1) begin
                de_run  = de_run + 1;
                de_px   = de_px + 1;
                if ((vga_r !== 5'd0) || (vga_g !== 6'd0) || (vga_b !== 5'd0))
                    nonzero_px = nonzero_px + 1;
            end

            if (dut.u_vga.hcount == 10'd799) begin
                if (hs_run !== 96)
                    $fatal(1, "TOP line %0d carried %0d hsync cycles, expected 96",
                           dut.u_vga.vcount, hs_run);
                if (dut.u_vga.vcount < 10'd480) begin
                    if (de_run !== 512)
                        $fatal(1, "TOP visible line %0d carried %0d de cycles, expected 512",
                               dut.u_vga.vcount, de_run);
                end else begin
                    if (de_run !== 0)
                        $fatal(1, "TOP blanking line %0d carried %0d de cycles, expected 0",
                               dut.u_vga.vcount, de_run);
                end
                hs_run   = 0;
                de_run   = 0;
            end

            if ((dut.u_vga.hcount == 10'd0) && (vga_vsync === 1'b1))
                vs_lines = vs_lines + 1;

            if (dut.u_vga.frame_pulse === 1'b1) begin
                if (vs_lines !== 3)
                    $fatal(1, "TOP the frame carried %0d vsync lines, expected 3", vs_lines);
                if (vga_frames > 0) begin
                    vga_frame_delta = vga_cycles - vga_frame_mark;
                    if (vga_frame_delta != VGA_FRAME_CYCLES)
                        $fatal(1, "TOP the vga frame period is %0d cycles, expected %0d",
                               vga_frame_delta, VGA_FRAME_CYCLES);
                end
                vga_frame_mark = vga_cycles;
                vga_frames     = vga_frames + 1;
                vs_lines       = 0;
            end
        end
    end

    // ----------------------------------------------------------------- 主流程
    initial begin
        clk_sys          = 1'b0;
        clk_ntsc         = 1'b0;
        clk_vga          = 1'b0;
        reset_n          = 1'b1;
        key_vec          = 4'b1111;
        pc               = 16'h0000;
        toggle_prev      = 8'd0;
        x_expect         = 8'd0;
        key_stable_prev  = 4'b1111;
        have_x           = 1'b0;
        line_pending     = 1'b0;
        fd_prev          = 1'b0;
        ntsc_reset_edge  = 1'b0;
        audio_run        = 1'b0;
        exp_hs           = 1'b0;
        exp_vs           = 1'b0;
        exp_de           = 1'b0;
        nes_frames       = 0;
        nes_lines        = 0;
        nes_line_ce      = 0;
        last_line_ce     = 0;
        line_period      = 0;
        lines_short      = 0;
        lines_wrap       = 0;
        line_done_count  = 0;
        lb_toggles       = 0;
        index0           = 0;
        index1           = 0;
        ppu_ce_total     = 0;
        vga_cycles       = 0;
        vga_frames       = 0;
        vga_frame_mark   = 0;
        vga_frame_delta  = 0;
        hs_run           = 0;
        de_run           = 0;
        vs_lines         = 0;
        nonzero_px       = 0;
        de_px            = 0;
        audio_strobes    = 0;
        audio_nonzero    = 0;
        guard            = 0;

        build_program;
        load_video_ram;

        #1 reset_n = 1'b0;
        repeat (20) @(posedge clk_sys);
        reset_n = 1'b1;

        #5_000_000;
        press(4'b1110, 4'b0001);
        press(4'b1111, 4'b0000);
        press(4'b0111, 4'b1000);
        press(4'b1111, 4'b0000);

        #1_000_000;
        wait_frames(NES_FRAMES_TARGET);

        if (nes_frames != NES_FRAMES_TARGET)
            $fatal(1, "TOP nes_frames is %0d, expected %0d", nes_frames, NES_FRAMES_TARGET);
        if (nes_lines != VISIBLE_LINES * nes_frames)
            $fatal(1, "TOP the line buffer took %0d visible lines, expected %0d",
                   nes_lines, VISIBLE_LINES * nes_frames);
        if (lines_short != VISIBLE_LINES * nes_frames - nes_frames)
            $fatal(1, "TOP %0d lines took 341 dots, expected %0d",
                   lines_short, VISIBLE_LINES * nes_frames - nes_frames);
        if (lines_wrap != nes_frames - 1)
            $fatal(1, "TOP %0d frame boundaries took 23*341 dots, expected %0d (the wrap after the last frame is still in progress when the run stops)",
                   lines_wrap, nes_frames - 1);
        if (line_done_count != nes_lines)
            $fatal(1, "TOP line_done pulsed %0d times for %0d written lines",
                   line_done_count, nes_lines);
        if (lb_toggles != nes_lines)
            $fatal(1, "TOP line_ready_toggle changed %0d times for %0d written lines",
                   lb_toggles, nes_lines);
        if (index1 == 0)
            $fatal(1, "TOP every ppu sample carried palette index 0, no palette reached the line buffer");
        if ((ppu_ce_total < DOTS_PER_FRAME * nes_frames) ||
            (ppu_ce_total > DOTS_PER_FRAME * nes_frames + 4))
            $fatal(1, "TOP ppu_ce fired %0d times, expected about %0d",
                   ppu_ce_total, DOTS_PER_FRAME * nes_frames);
        if (dut.u_nes.u_ppu.mask_reg !== 8'h1E)
            $fatal(1, "TOP the boot program left ppumask at %02h, expected 1e", dut.u_nes.u_ppu.mask_reg);
        if (vga_frames < 2)
            $fatal(1, "TOP only %0d vga frames completed", vga_frames);
        if ((de_px < 245760 * vga_frames) || (de_px > 245760 * (vga_frames + 1)))
            $fatal(1, "TOP carried %0d de pixels, expected between %0d and %0d",
                   de_px, 245760 * vga_frames, 245760 * (vga_frames + 1));
        if (nonzero_px == 0)
            $fatal(1, "TOP vga_r/vga_g/vga_b never left zero, the pixel chain is broken");
        if (audio_strobes == 0)
            $fatal(1, "TOP audio_valid never asserted");
        if (audio_nonzero == 0)
            $fatal(1, "TOP every audio sample was zero");

        $display("VGA %0d frames, frame period %0d clk_vga, de pixels %0d, nonzero rgb %0d PASS",
                 vga_frames, vga_frame_delta, de_px, nonzero_px);
        $display("PPU %0d frames, %0d visible lines (%0d x 341 dots, %0d frame wraps of 23 x 341), line_done %0d, line_ready_toggle %0d, ppu_ce %0d PASS",
                 nes_frames, nes_lines, lines_short, lines_wrap, line_done_count, lb_toggles, ppu_ce_total);
        $display("PIX palette index 0 %0d, index nonzero %0d PASS", index0, index1);
        $display("KEY debounce %0d clk_sys (factory default 16000 us = 800000 clk_sys at 50 MHz), buttons1 followed within 4 clk_ntsc PASS",
                 TB_DEBOUNCE_CYCLES);
        $display("AUDIO audio_valid strobes %0d, nonzero samples %0d PASS", audio_strobes, audio_nonzero);

        $display("PASS nes_ep4ce10_top");
        $finish;
    end

    initial begin
        #60_000_000;
        $fatal(1, "TOP the global timeout expired, nes_frames %0d nes_lines %0d vga_frames %0d",
               nes_frames, nes_lines, vga_frames);
    end

endmodule
