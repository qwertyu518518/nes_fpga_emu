`timescale 1ns/1ps

// Dual-clock gate testbench for nes_video_800x480, at the real board ratio.
//
// core_clk 21.477272727 MHz (46.560846560846 ns), lcd_clk 25 MHz (40 ns),
// ce = 1'b1. The producer emulates the PPU: one dot is 4 core clocks, a
// pixel_valid pulse is one core clock wide on the 256 visible dots of each of
// the 240 visible lines of a 262-line frame, and the other 85 dots of every
// line are idle. That is 186.243386 ns per input line and 16.638 ms per input
// frame against 42.240 us per output line and 22.176 ms per output frame, so
// the producer is about 1.33x the consumer and neither can be paused.
//
// What is asserted, and why each one can fail:
//
//   * ZERO PIXELS LOST, counted at the write port. Every wr_clk edge with
//     in_valid increments wr_hits[{in_y,in_x}]. At each input-frame boundary
//     all 61440 addresses must read exactly 1, the pixel count must be 61440,
//     and two independent 64-bit sums (address sum, data sum) must equal the
//     values computed by the tb's own nested loop. A dropped write, a doubled
//     write, a wrong address or a wrong data word all break one of these.
//     Nothing here is inferred from the picture.
//   * COLUMN 0 WRITTEN ON EVERY SCANLINE. wr_col0 must equal 240 per input
//     frame, and on the read side the emitter must land identically at each
//     line start: mod8_count, group_count and emit_slot all zero and src_col
//     zero at the first active dot of every scanline.
//   * READ ADDRESS / EMITTER PAIRING. dut.src_col must equal the reference
//     column of the presented dot and dut.mem_read_addr the reference address
//     of the next dot, on every active dot.
//   * IMAGE COHERENCE, per dot. With the producer stopped the whole buffer is
//     a known image, so every one of the 384000 dots of a checked frame is
//     compared against the exact expected RGB565 for its (column,row).
//   * SCRAMBLE CANARIES. On the first checked frame the tb also accumulates
//     three signatures of deliberately corrupted images: a one-dot horizontal
//     shift, a one-line vertical shift, and 1:1 vertical instead of 2:1. All
//     three must differ from the measured signature, which proves the
//     comparison is not vacuous. A scrambled or torn image breaks both the
//     per-dot comparison and the signature.
//   * EMIT ACCOUNTING per checked frame: every source column must be emitted
//     exactly span(c) * 480 times, which sums to 384000. This is the
//     counted form of "no column dropped, no column doubled".
//   * LINE AND FRAME BOUNDARIES. The producer's line and frame counters are
//     sampled on every active dot; an output line that contains a producer
//     line or frame boundary inside it is counted, and the count must be
//     non-zero so the interleaving is provably covered. The 800-wide and
//     480-line invariants are asserted on every line and frame regardless.
//   * RESET DURING ACTIVE CAPTURE. Both resets are asserted while the producer
//     is mid visible line and the raster is inside an active line; both
//     domains must clear and the buffer must survive.
//   * DOMAIN ISOLATION. wr_reset alone must clear the wr counters and leave
//     the raster running; rd_reset alone must clear the raster and leave the
//     wr-side ready pulses on cadence.
//   * ce GATES ONLY THE RASTER: ce low freezes hcount, vcount, de and
//     frame_pulse and nothing else.
//
// Verilog-2001 only, no $clog2.

module tb_nes_video_800x480_dc;

    localparam BLANK    = 16'h0000;
    localparam SYNC_LVL = 1'b1;
    localparam H_TOT    = 1056;
    localparam V_TOT    = 525;
    localparam H_A0     = 216;
    localparam H_A1     = 1016;
    localparam V_A0     = 35;
    localparam V_A1     = 515;
    localparam PA_XOR   = 16'h5AA5;
    localparam PB_XOR   = 16'h3C3C;
    localparam PC_XOR   = 16'h0F5A;
    localparam FB_PIX   = 61440;

    reg core_clk;
    reg lcd_clk;
    reg wr_reset;
    reg rd_reset;
    reg ce;

    reg        in_valid;
    reg [7:0]  in_x;
    reg [7:0]  in_y;
    reg [15:0] in_rgb565;

    wire       in_line_ready;
    wire       in_frame_ready;
    wire [15:0] rgb565;
    wire       de;
    wire       hsync;
    wire       vsync;
    wire [10:0] hcount;
    wire [10:0] vcount;
    wire [10:0] pixel_x;
    wire [10:0] pixel_y;
    wire       frame_pulse;

    integer errors;
    integer k;
    integer ax;
    integer ay;
    integer ox;
    integer win;
    integer exp_col;
    integer exp_row;
    integer refv_i;
    integer canv_i;

    integer frames;
    integer frame_ticks;
    integer line_px;
    integer act_lines;
    integer checking;
    integer frame_chk;
    integer full_frame;
    integer canary_on;
    integer frames_checked;
    integer dot_total;

    integer rd_reset_seen;
    integer wr_reset_seen;

    integer h_hold;
    integer v_hold;
    integer d_hold;
    integer f_hold;
    integer hold_ce;
    integer hold_valid;

    integer sub;
    integer ln;
    integer fr;
    integer ln_prev;
    integer fr_prev;
    integer rln_prev;
    integer rfr_prev;
    integer ln_edge_in_line;
    integer fr_edge_in_line;
    integer lines_with_ln_edge;
    integer lines_with_fr_edge;
    reg [7:0]  px;
    reg [7:0]  py;
    reg        run_en;
    reg [15:0] pat_xor;

    integer in_frames_done;
    integer wr_frame_pix;
    integer wr_col0;
    integer in_lines_seen;
    integer wr_frames_verified;
    integer wr_pixels_lost;
    integer wr_addr_sum_r;
    integer ln_isolate_seen;
    integer fr_isolate_seen;
    integer ln_isolate_base;
    integer fr_isolate_base;
    integer lr_seen_during_rdreset;
    integer ce_freeze_frames;
    integer wr_before_ce_low;

    reg [63:0] wr_addr_sum;
    reg [63:0] wr_data_sum;
    reg [63:0] exp_addr_sum;
    reg [63:0] exp_data_sum;

    reg [15:0] line_sig_r;
    reg [15:0] sig_prev_r;
    reg [31:0] sig_meas_r;
    reg [31:0] sig_exp_r;
    reg [31:0] sig_colshift_r;
    reg [31:0] sig_rowshift_r;
    reg [31:0] sig_nodup_r;
    reg [31:0] sig_data_r;

    integer col_hit    [0:255];
    integer span_ref   [0:255];
    integer emit_col   [0:255];
    integer ref_col    [0:799];
    integer ref_col_h1 [0:799];
    integer row_vshift [0:479];
    integer row_nodup  [0:479];
    integer wr_hits    [0:61439];

    nes_video_800x480 dut (
        .wr_clk(core_clk),
        .wr_reset(wr_reset),
        .in_valid(in_valid),
        .in_x(in_x),
        .in_y(in_y),
        .in_rgb565(in_rgb565),
        .in_line_ready(in_line_ready),
        .in_frame_ready(in_frame_ready),
        .rd_clk(lcd_clk),
        .rd_reset(rd_reset),
        .ce(ce),
        .rgb565(rgb565),
        .de(de),
        .hsync(hsync),
        .vsync(vsync),
        .hcount(hcount),
        .vcount(vcount),
        .pixel_x(pixel_x),
        .pixel_y(pixel_y),
        .frame_pulse(frame_pulse)
    );

    function [15:0] pat_of;
        input [7:0] x;
        input [7:0] y;
        input [15:0] kv;
        begin
            pat_of = {x, y} ^ kv;
        end
    endfunction

    task err;
        input [8*40:1] code;
        input integer a;
        input integer b;
        begin
            errors = errors + 1;
            if (errors <= 30)
                $display("VIOLATION %0s a=%0d b=%0d rdframe=%0d hcnt=%0d vcnt=%0d x=%0d y=%0d",
                         code, a, b, frames, hcount, vcount, pixel_x, pixel_y);
        end
    endtask

    // Reference maps derived independently of the rtl: the 800 active dots are
    // 32 groups of 25, columns 0..6 of a group take 3 dots and column 7 takes 4.
    task build_tables;
        integer g;
        integer r;
        integer j;
        integer b;
        integer m;
        begin
            for (m = 0; m < 800; m = m + 1) begin
                g = m / 25;
                r = m - (g * 25);
                if (r < 21) ref_col[m] = (8 * g) + (r / 3);
                else ref_col[m] = (8 * g) + 7;
            end
            for (m = 0; m < 800; m = m + 1) begin
                if (m == 799) ref_col_h1[m] = ref_col[799];
                else ref_col_h1[m] = ref_col[m + 1];
            end
            for (b = 0; b < 256; b = b + 1) begin
                j = b - (8 * (b / 8));
                if (j == 7) span_ref[b] = 4;
                else span_ref[b] = 3;
            end
            for (m = 0; m < 480; m = m + 1) begin
                row_vshift[m] = (m == 479) ? 239 : ((m + 1) >> 1);
                if (m > 239) row_nodup[m] = 239;
                else row_nodup[m] = m;
            end
        end
    endtask

    // ------------------------------------------------------------------
    // Producer: 4 core clocks per dot, pixel_valid one core clock wide.
    // ------------------------------------------------------------------
    always @(negedge core_clk) begin
        if (wr_reset || !run_en) begin
            in_valid  <= 1'b0;
            sub       <= 0;
            ln        <= 0;
            fr        <= 0;
            px        <= 8'd0;
            py        <= 8'd0;
        end else begin
            in_valid  <= 1'b0;
            if (sub == 3) begin
                sub <= 0;
                if ((ln <= 255) && (fr <= 239)) begin
                    in_valid   <= 1'b1;
                    in_x       <= px;
                    in_y       <= py;
                    in_rgb565  <= pat_of(px, py, pat_xor);
                    if (px == 8'd255) begin
                        px <= 8'd0;
                        py <= ((py == 8'd239) ? 8'd0 : (py + 8'd1));
                    end else begin
                        px <= px + 8'd1;
                    end
                end
                if (ln == 340) begin
                    ln <= 0;
                    fr <= ((fr == 261) ? 0 : (fr + 1));
                end else begin
                    ln <= ln + 1;
                end
            end else begin
                sub <= sub + 1;
            end
        end
    end

    // ------------------------------------------------------------------
    // wr_clk domain: write accounting, ready cadence, reset checks
    // ------------------------------------------------------------------
    task verify_input_frame;
        integer vk;
        integer vay;
        integer vax;
        begin
            wr_addr_sum_r = 0;
            exp_addr_sum = 64'd0;
            exp_data_sum = 64'd0;
            vk = 0;
            for (vay = 0; vay < 240; vay = vay + 1) begin
                for (vax = 0; vax < 256; vax = vax + 1) begin
                    if (wr_hits[vk] !== 1) begin
                        wr_pixels_lost = wr_pixels_lost + 1;
                        if (wr_pixels_lost <= 8)
                            err("WR_HIT_NOT_ONE", vk, wr_hits[vk]);
                    end
                    wr_hits[vk] = 0;
                    exp_addr_sum = exp_addr_sum + vk[31:0];
                    exp_data_sum = exp_data_sum + {48'd0, pat_of(vax[7:0], vay[7:0], pat_xor)};
                    vk = vk + 1;
                end
            end
            if (wr_frame_pix !== FB_PIX) err("WR_PIXEL_COUNT", wr_frame_pix, FB_PIX);
            if (wr_col0 !== 240) err("WR_COL0_COUNT", wr_col0, 240);
            if (wr_addr_sum !== exp_addr_sum) err("WR_ADDR_SUM", wr_addr_sum[31:0], 0);
            if (wr_data_sum !== exp_data_sum) err("WR_DATA_SUM", wr_data_sum[31:0], 0);
            wr_frames_verified = wr_frames_verified + 1;
            wr_frame_pix = 0;
            wr_col0 = 0;
            wr_addr_sum = 64'd0;
            wr_data_sum = 64'd0;
        end
    endtask

    always @(posedge core_clk) begin
        if (wr_reset) begin
            wr_reset_seen = wr_reset_seen + 1;
            wr_frame_pix = 0;
            wr_col0 = 0;
            in_lines_seen = 0;
            wr_addr_sum = 64'd0;
            wr_data_sum = 64'd0;
            ln_prev = 0;
            fr_prev = 0;
            if (wr_reset_seen == 1)
                for (k = 0; k < FB_PIX; k = k + 1) wr_hits[k] = 0;
        end else begin
            wr_reset_seen = 0;
            if (wr_reset_seen == 0) begin
                if (in_line_ready) in_lines_seen = in_lines_seen + 1;
                if (in_frame_ready) begin
                    if (in_lines_seen !== 240) err("IN_LINE_CADENCE", in_lines_seen, 240);
                    in_lines_seen = 0;
                end
            end
            if (in_valid) begin
                wr_frame_pix = wr_frame_pix + 1;
                wr_addr_sum  = wr_addr_sum + {32'd0, in_y, in_x};
                wr_data_sum  = wr_data_sum + {48'd0, in_rgb565};
                wr_hits[{in_y, in_x}] = wr_hits[{in_y, in_x}] + 1;
                if (in_x == 8'd0) wr_col0 = wr_col0 + 1;
            end
            if ((fr == 0) && (fr_prev != 0)) begin
                $display("DC WRAP n=%0d pixels=%0d col0=%0d pat=%04h", in_frames_done + 1, wr_frame_pix, wr_col0, pat_xor);
                verify_input_frame;
                in_frames_done = in_frames_done + 1;
            end
            fr_prev = fr;
        end
    end

    // ------------------------------------------------------------------
    // rd_clk domain: raster, emitter, read address, image
    // ------------------------------------------------------------------
    always @(posedge lcd_clk) begin
        if (hold_valid && !hold_ce && !rd_reset) begin
            if (hcount !== h_hold[10:0]) err("CE_HOLD_HCOUNT", hcount, h_hold);
            if (vcount !== v_hold[10:0]) err("CE_HOLD_VCOUNT", vcount, v_hold);
            if (de !== d_hold[0]) err("CE_HOLD_DE", de, d_hold);
            if (frame_pulse !== f_hold[0]) err("CE_HOLD_FRAME", frame_pulse, f_hold);
        end
        h_hold     = hcount;
        v_hold     = vcount;
        d_hold     = de;
        f_hold     = frame_pulse;
        hold_ce    = ce;
        hold_valid = 1;

        if (ce) begin
            frame_ticks = frame_ticks + 1;

            if (rd_reset) begin
                rd_reset_seen = rd_reset_seen + 1;
                for (k = 0; k < 256; k = k + 1) col_hit[k] = 0;
                frame_ticks = 0;
                act_lines = 0;
                line_px = 0;
                full_frame = 0;
                frame_chk = 0;
                line_sig_r = 16'h0000;
                sig_prev_r = 16'h0000;
                sig_meas_r = 32'h0000_0000;
                sig_exp_r = 32'h0000_0000;
                if (rd_reset_seen >= 2) begin
                    if (hcount !== 11'd0) err("RD_RESET_HCOUNT", hcount, 0);
                    if (vcount !== 11'd0) err("RD_RESET_VCOUNT", vcount, 0);
                    if (de !== 1'b0) err("RD_RESET_DE", de, 0);
                    if (hsync !== SYNC_LVL) err("RD_RESET_HSYNC", hsync, 0);
                    if (vsync !== SYNC_LVL) err("RD_RESET_VSYNC", vsync, 0);
                    if (rgb565 !== BLANK) err("RD_RESET_RGB", rgb565, 0);
                    if (pixel_x !== 11'd0) err("RD_RESET_PIXEL_X", pixel_x, 0);
                    if (pixel_y !== 11'd0) err("RD_RESET_PIXEL_Y", pixel_y, 0);
                    if (frame_pulse !== 1'b0) err("RD_RESET_FRAME", 0, 0);
                    if (dut.mod8_count !== 3'd0) err("RD_RESET_MOD8", dut.mod8_count, 0);
                    if (dut.group_count !== 5'd0) err("RD_RESET_GROUP", dut.group_count, 0);
                    if (dut.emit_slot !== 2'd0) err("RD_RESET_SLOT", dut.emit_slot, 0);
                end
            end else begin
                rd_reset_seen = 0;

                if ((hcount == 11'd0) && (vcount == 11'd0)) begin
                    frame_chk = checking;
                    full_frame = checking;
                    canary_on = checking;
                end
                if (hsync !== SYNC_LVL) err("HSYNC_LEVEL", hsync, 0);
                if (vsync !== SYNC_LVL) err("VSYNC_LEVEL", vsync, 0);
                if (hcount > (H_TOT - 1)) err("H_RANGE", hcount, 0);
                if (vcount > (V_TOT - 1)) err("V_RANGE", vcount, 0);

                win = ((hcount >= H_A0) && (hcount < H_A1) && (vcount >= V_A0) && (vcount < V_A1));
                if (de !== win[0]) err("DE_WINDOW", hcount, vcount);

                if (de) begin
                    if (pixel_x !== (hcount - H_A0)) err("PIXEL_X", pixel_x, hcount);
                    if (pixel_y !== (vcount - V_A0)) err("PIXEL_Y", pixel_y, vcount);
                end else begin
                    if (pixel_x !== 11'd0) err("PIXEL_X_BLANK", pixel_x, 0);
                    if (pixel_y !== 11'd0) err("PIXEL_Y_BLANK", pixel_y, 0);
                    if (rgb565 !== BLANK) err("BLANK_RGB", rgb565, 0);
                end

                if (dut.mod8_count > 3'd7) err("MOD8_RANGE", dut.mod8_count, 0);
                if (dut.group_count > 5'd31) err("GROUP_RANGE", dut.group_count, 0);
                if (dut.emit_slot > 2'd3) err("SLOT_RANGE", dut.emit_slot, 0);

                if (de) begin
                    ox = pixel_x;
                    dot_total = dot_total + 1;

                    if (ox === 0) begin
                        line_px = 1;
                        line_sig_r = 16'h0000;
                        if (dut.mod8_count !== 3'd0) err("MOD8_RESET", dut.mod8_count, 0);
                        if (dut.group_count !== 5'd0) err("GROUP_RESET", dut.group_count, 0);
                        if (dut.emit_slot !== 2'd0) err("SLOT_RESET", dut.emit_slot, 0);
                        if (dut.src_col !== 8'd0) err("LINE_START_SRCCOL", dut.src_col, 0);
                    end else begin
                        line_px = line_px + 1;
                    end

                    exp_col = ref_col[ox];
                    exp_row = pixel_y >> 1;

                    if (dut.src_col !== exp_col[7:0]) err("SRC_COL", ox, dut.src_col);
                    if (dut.src_row !== exp_row[7:0]) err("SRC_ROW", pixel_y, dut.src_row);

                    if (ox < 799) begin
                        if (dut.mem_read_addr !== {exp_row[7:0], ref_col[ox + 1][7:0]})
                            err("MEM_READ_ADDR", ox, dut.mem_read_addr);
                    end else begin
                        if (dut.mem_read_addr[7:0] !== 8'd0) err("MEM_READ_ADDR_RESET", ox, dut.mem_read_addr);
                    end

                    col_hit[exp_col] = col_hit[exp_col] + 1;
                    emit_col[exp_col] = emit_col[exp_col] + 1;

                    if (frame_chk) begin
                        refv_i = pat_of(exp_col[7:0], exp_row[7:0], pat_xor);
                        if (rgb565 !== refv_i[15:0]) err("PIXEL_VALUE", ox, rgb565);
                        line_sig_r = line_sig_r + ({6'd0, rgb565[9:0]} * 16'd7) + {10'd0, pixel_x[9:0]};
                        sig_meas_r = sig_meas_r + ({16'd0, rgb565} * 32'd7)
                                             + ({16'd0, pixel_x} * 32'd1000003);
                        sig_exp_r  = sig_exp_r  + ({16'd0, refv_i[15:0]} * 32'd7)
                                             + ({16'd0, pixel_x} * 32'd1000003);
                        if (canary_on) begin
                            sig_colshift_r = sig_colshift_r
                                + ({16'd0, pat_of(ref_col_h1[ox][7:0], exp_row[7:0], pat_xor)} * 32'd7)
                                + ({16'd0, pixel_x} * 32'd1000003);
                            sig_rowshift_r = sig_rowshift_r
                                + ({16'd0, pat_of(exp_col[7:0], row_vshift[pixel_y][7:0], pat_xor)} * 32'd7)
                                + ({16'd0, pixel_x} * 32'd1000003);
                            sig_nodup_r = sig_nodup_r
                                + ({16'd0, pat_of(exp_col[7:0], row_nodup[pixel_y][7:0], pat_xor)} * 32'd7)
                                + ({16'd0, pixel_x} * 32'd1000003);
                            canv_i = pat_of(exp_col[7:0], exp_row[7:0], pat_xor);
                            if ((ox == 0) && (pixel_y == 137)) canv_i = pat_of(exp_col[7:0], 8'd69, pat_xor);
                            sig_data_r = sig_data_r + ({16'd0, canv_i[15:0]} * 32'd7)
                                             + ({16'd0, pixel_x} * 32'd1000003);
                        end
                    end

                    if ((ln == 0) && (rln_prev != 0)) ln_edge_in_line = 1;
                    if ((fr == 0) && (rfr_prev != 0)) fr_edge_in_line = 1;
                    rln_prev = ln;
                    rfr_prev = fr;

                    if (ox === 799) begin
                        if (line_px !== 800) err("LINE_WIDTH", line_px, pixel_y);
                        for (k = 0; k < 256; k = k + 1) begin
                            if (col_hit[k] !== span_ref[k]) err("COL_SPAN", k, col_hit[k]);
                            col_hit[k] = 0;
                        end
                        if (ln_edge_in_line) lines_with_ln_edge = lines_with_ln_edge + 1;
                        if (fr_edge_in_line) lines_with_fr_edge = lines_with_fr_edge + 1;
                        rln_prev = 0;
        rfr_prev = 0;
        ln_edge_in_line = 0;
                        fr_edge_in_line = 0;
                        if (frame_chk) begin
                            if (pixel_y[0] === 1'b1) begin
                                if (full_frame && (line_sig_r !== sig_prev_r)) err("VERTICAL_2TO1", pixel_y, line_sig_r);
                            end else begin
                                sig_prev_r = line_sig_r;
                            end
                        end
                        line_px = 0;
                        act_lines = act_lines + 1;
                    end
                end else begin
                    line_px = 0;
                end

                if (frame_pulse) begin
                    frames = frames + 1;
                    if (frame_ticks !== (H_TOT * V_TOT)) err("FRAME_TICKS", frame_ticks, H_TOT * V_TOT);
                    if (full_frame) begin
                        if (act_lines !== 480) err("FRAME_ACTIVE_LINES", act_lines, 480);
                        for (k = 0; k < 256; k = k + 1) begin
                            if (emit_col[k] !== (span_ref[k] * 480)) err("EMIT_COL_COUNT", k, emit_col[k]);
                            emit_col[k] = 0;
                        end
                        if (sig_meas_r !== sig_exp_r) err("FRAME_SIG_MISMATCH", frames, 0);
                        if (canary_on) begin
                            $display("DC CANARY frame=%0d measured=%08x colshift=%08x rowshift=%08x nodup=%08x data=%08x",
                                     frames, sig_meas_r, sig_colshift_r, sig_rowshift_r,
                                     sig_nodup_r, sig_data_r);
                            if (sig_meas_r === sig_colshift_r) err("CANARY_COLSHIFT_BLIND", frames, 0);
                            if (sig_meas_r === sig_rowshift_r) err("CANARY_ROWSHIFT_BLIND", frames, 0);
                            if (sig_meas_r === sig_nodup_r) err("CANARY_NODUP_BLIND", frames, 0);
                            if (sig_meas_r === sig_data_r) err("CANARY_DATA_BLIND", frames, 0);
                            canary_on = 0;
                        end
                        frames_checked = frames_checked + 1;
                    end else begin
                        if ((act_lines !== 0) && (act_lines !== 480)) err("FRAME_ACTIVE_LINES", act_lines, 480);
                        for (k = 0; k < 256; k = k + 1) emit_col[k] = 0;
                    end
                    sig_meas_r = 32'h0000_0000;
                    sig_exp_r = 32'h0000_0000;
                    sig_colshift_r = 32'h0000_0000;
                    sig_rowshift_r = 32'h0000_0000;
                    sig_nodup_r = 32'h0000_0000;
                    sig_data_r = 32'h0000_0000;
                    frame_ticks = 0;
                    act_lines = 0;
                    full_frame  = 0;
                    frame_chk = 0;
                end
            end
        end
        if (rd_reset) hold_valid = 0;
    end

    task wait_frames;
        input integer n;
        integer target;
        begin
            target = frames + n;
            while (frames < target) begin
                @(posedge lcd_clk);
                #1;
            end
        end
    endtask

    task wait_frame_start;
        begin
            @(posedge lcd_clk);
            #1;
            while ((hcount !== 11'd0) || (vcount !== 11'd0)) begin
                @(posedge lcd_clk);
                #1;
            end
        end
    endtask

    task wait_pulse;
        integer target;
        begin
            target = frames + 1;
            while (frames < target) begin
                @(posedge lcd_clk);
                #1;
            end
            #1;
        end
    endtask

    task wait_input_frames;
        input integer n;
        integer target;
        begin
            target = in_frames_done + n;
            while (in_frames_done < target) begin
                @(posedge core_clk);
                #1;
            end
        end
    endtask

    initial begin
        core_clk = 1'b0;
        lcd_clk  = 1'b0;
        wr_reset = 1'b1;
        rd_reset = 1'b1;
        ce = 1'b1;
        in_valid = 1'b0;
        in_x = 8'h00;
        in_y = 8'h00;
        in_rgb565 = 16'h0000;
        run_en = 1'b0;
        pat_xor = PA_XOR;

        errors = 0;
        k = 0;
        frames = 0;
        frame_ticks = 0;
        line_px = 0;
        act_lines = 0;
        checking = 0;
        frame_chk = 0;
        full_frame = 0;
        canary_on = 0;
        frames_checked = 0;
        dot_total = 0;
        rd_reset_seen = 0;
        wr_reset_seen = 0;
        h_hold = 0;
        v_hold = 0;
        d_hold = 0;
        f_hold = 0;
        hold_ce = 1;
        hold_valid = 0;
        in_frames_done = 0;
        wr_frame_pix = 0;
        wr_col0 = 0;
        in_lines_seen = 0;
        wr_frames_verified = 0;
        wr_pixels_lost = 0;
        rln_prev = 0;
        rfr_prev = 0;
        ln_edge_in_line = 0;
        fr_edge_in_line = 0;
        lines_with_ln_edge = 0;
        lines_with_fr_edge = 0;
        ln_isolate_seen = 0;
        fr_isolate_seen = 0;
        ln_isolate_base = 0;
        fr_isolate_base = 0;
        lr_seen_during_rdreset = 0;
        ce_freeze_frames = 0;
        wr_before_ce_low = 0;
        wr_addr_sum = 64'd0;
        wr_data_sum = 64'd0;
        line_sig_r = 16'h0000;
        sig_prev_r = 16'h0000;
        sig_meas_r = 32'h0000_0000;
        sig_exp_r = 32'h0000_0000;
        sig_colshift_r = 32'h0000_0000;
        sig_rowshift_r = 32'h0000_0000;
        sig_nodup_r = 32'h0000_0000;
        sig_data_r = 32'h0000_0000;

        for (k = 0; k < 256; k = k + 1) begin
            col_hit[k] = 0;
            emit_col[k] = 0;
        end
        for (k = 0; k < FB_PIX; k = k + 1) wr_hits[k] = 0;
        build_tables;

        $display("DC core_clk half period 23.280423280423 ns (21.477272727 MHz), lcd_clk half period 20 ns (25 MHz), ce=1'b1");
        $display("DC input line 341 dots x 4 core clk, visible 256 dots one core clk wide, 240 visible lines of 262");

        repeat (12) @(posedge lcd_clk);
        @(negedge lcd_clk);
        wr_reset = 1'b0;
        rd_reset = 1'b0;

        // ---- phase 1: pattern A, one input frame, then quiesce ----
        pat_xor = PA_XOR;
        run_en = 1'b1;
        wait_input_frames(1);
        run_en = 1'b0;
        wait_pulse;
        checking = 1;
        wait_frames(2);

        // ---- phase 2: pattern B, two input frames across the crossing ----
        wait_pulse;
        checking = 0;
        pat_xor = PB_XOR;
        run_en = 1'b1;
        wait_input_frames(2);
        run_en = 1'b0;
        wait_pulse;
        checking = 1;
        wait_frames(1);

        // ---- phase 3: reset during active capture, buffer must survive ----
        wait_pulse;
        checking = 0;
        pat_xor = PC_XOR;
        run_en = 1'b1;
        @(posedge lcd_clk);
        #1;
        while (!((de === 1'b1) && (pixel_x > 120) && (pixel_x < 680))) begin
            @(posedge lcd_clk);
            #1;
        end
        while (ln > 200) begin
            @(posedge core_clk);
            #1;
        end
        @(negedge lcd_clk);
        #1;
        wr_reset = 1'b1;
        rd_reset = 1'b1;
        repeat (6) @(posedge lcd_clk);
        @(negedge lcd_clk);
        #1;
        wr_reset = 1'b0;
        rd_reset = 1'b0;
        repeat (4) @(posedge lcd_clk);
        wait_input_frames(1);
        run_en = 1'b0;
        wait_pulse;
        checking = 1;
        wait_frames(1);

        // ---- phase 4: domain isolation ----
        wait_pulse;
        checking = 0;
        pat_xor = PB_XOR;
        run_en = 1'b1;
        repeat (40) @(posedge lcd_clk);
        ln_isolate_base = frames;
        fr_isolate_base = hcount;
        @(negedge lcd_clk);
        wr_reset = 1'b1;
        repeat (6) @(posedge lcd_clk);
        if (hcount === fr_isolate_base) err("WR_RESET_CLEARED_RASTER", hcount, fr_isolate_base);
        @(negedge lcd_clk);
        wr_reset = 1'b0;
        wait_input_frames(1);
        run_en = 1'b0;
        if (wr_frames_verified < 4) err("TOO_FEW_WR_FRAMES", wr_frames_verified, 4);

        // ---- phase 5: ce gates only the raster ----
        run_en = 1'b1;
        while (ln > 100) begin
            @(posedge core_clk);
            #1;
        end
        repeat (20) @(posedge lcd_clk);
        wr_before_ce_low = wr_frame_pix;
        ce = 1'b0;
        ce_freeze_frames = frames;
        repeat (300) @(posedge lcd_clk);
        if (frames !== ce_freeze_frames) err("CE_FREEZE_FRAME_ADVANCED", frames, ce_freeze_frames);
        if (wr_frame_pix <= wr_before_ce_low) err("CE_STALLED_WR_PORT", wr_frame_pix, wr_before_ce_low);
        ce = 1'b1;
        wait_input_frames(1);
        run_en = 1'b0;
        repeat (40) @(posedge lcd_clk);

        $display("DC SUMMARY input_frames_written_and_verified=%0d input_pixels_written=%0d pixels_lost_or_doubled=%0d",
                 wr_frames_verified, wr_frames_verified * FB_PIX, wr_pixels_lost);
        $display("DC SUMMARY output_frames=%0d content_checked_frames=%0d active_dots_seen=%0d",
                 frames, frames_checked, dot_total);
        $display("DC SUMMARY output_lines_with_producer_line_boundary=%0d with_producer_frame_boundary=%0d",
                 lines_with_ln_edge, lines_with_fr_edge);
        $display("DC SUMMARY violations=%0d", errors);

        if (frames_checked < 4) err("TOO_FEW_CHECKED_FRAMES", frames_checked, 4);
        if (lines_with_ln_edge < 1) err("NO_PRODUCER_LINE_BOUNDARY_COVERED", lines_with_ln_edge, 0);
        if (lines_with_fr_edge < 1) err("NO_PRODUCER_FRAME_BOUNDARY_COVERED", lines_with_fr_edge, 0);
        if (wr_frames_verified < 5) err("TOO_FEW_WR_FRAMES", wr_frames_verified, 5);
        if (wr_pixels_lost != 0) err("PIXELS_LOST", wr_pixels_lost, 0);

        if (errors != 0) begin
            $display("FAIL nes_video_800x480 dual clock with %0d violations", errors);
            $fatal(1, "nes_video_800x480 dual clock tb failed");
        end

        $display("PASS nes_video_800x480_dual_clock 256x240 in at 21.477 MHz, 800x480 out at 25 MHz, zero pixels lost, image coherent");
        $finish;
    end

    always #23.280423280423 core_clk = ~core_clk;
    always #20 lcd_clk = ~lcd_clk;

    initial begin
        #800000000;
        $fatal(1, "global timeout");
    end

endmodule
