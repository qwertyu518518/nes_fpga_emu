`timescale 1ns/1ps

// Gate testbench for nes_video_800x480.
//
// Structural assertions run on every ce tick of every output frame, so they
// cover many lines and several frames:
//   * lcd_de equals the vendor 0x4384 DE window recomputed from hcount/vcount
//   * lcd_hs and lcd_vs sit at the vendor DE-mode idle level 1'b1 at all times
//   * the bus is BLANK_RGB565 whenever lcd_de is low
//   * every lcd_de run on a scanline is exactly 800 dots wide
//   * every scanline contributes exactly 800 emit hits spread 3,3,3,3,3,3,3,4
//     over the 256 input columns, the 4 landing on every 8th column
//   * the mod-8 emitter (mod8_count/group_count/emit_slot) is all zero at the
//     first active dot of every scanline and stays inside 0..7 / 0..31 / 0..3
//   * dut.src_col equals the reference column of the presented dot and
//     dut.mem_read_addr equals the reference address of the next dot
//   * the raster holds completely still on every cycle where ce is low
//   * one output frame is exactly H_TOTAL*V_TOTAL ce ticks and 480 active lines
// Content assertions run on whole frames whose buffer content is known:
//   * every RGB565 equals the reference for the mapped (column,row)
//   * consecutive output line pairs are identical, i.e. exact 2:1 vertical
//   * consecutive checked frames are bit-identical, and the frame signature
//     changes when the input pattern changes
//   * pixel identity is asserted explicitly at input columns 0,1,2,3,6,7,8,9,
//     15,16,17,248,249,250,255 and at their mapped output dot positions

module tb_nes_video_800x480;

    localparam BLANK    = 16'h0000;
    localparam SYNC_LVL = 1'b1;
    localparam H_TOT    = 1056;
    localparam V_TOT    = 525;
    localparam H_A0     = 216;
    localparam H_A1     = 1016;
    localparam V_A0     = 35;
    localparam V_A1     = 515;
    localparam P0_XOR   = 16'h5AA5;
    localparam P1_XOR   = 16'h3C3C;
    localparam PROBE_N  = 15;

    reg clk;
    reg reset;
    reg ce;
    integer ce_div;
    integer ce_cnt;
    reg in_valid;
    reg [7:0] in_x;
    reg [7:0] in_y;
    reg [15:0] in_rgb565;

    wire [15:0] rgb565;
    wire de;
    wire hsync;
    wire vsync;
    wire [10:0] hcount;
    wire [10:0] vcount;
    wire [10:0] pixel_x;
    wire [10:0] pixel_y;
    wire frame_pulse;
    wire in_line_ready;
    wire in_frame_ready;

    integer errors;
    integer ce_total;
    integer frames;
    integer frame_ticks;
    integer line_px;
    integer act_lines;
    integer checking;
    integer full_frame;
    integer expect_pat;
    integer k;
    integer ox;
    integer pk;
    integer win;
    integer exp_col;
    integer exp_row;
    integer h_hold;
    integer v_hold;
    integer d_hold;
    integer f_hold;
    integer hold_ce;
    integer hold_valid;
    integer frames_checked;
    integer frames_stable;
    integer have_prev_frame_sig;
    integer reset_seen;
    integer in_lines;
    reg [15:0] xor_sel;

    reg [15:0] line_sig_r;
    reg [15:0] sig_prev_r;
    reg [31:0] frame_sig_r;
    reg [31:0] prev_frame_sig_r;
    reg [31:0] sig0_r;
    reg [31:0] sig1_r;

    integer col_hit   [0:255];
    integer span_ref  [0:255];
    integer ref_col   [0:799];
    integer probe_at  [0:799];

    integer probe     [0:14];
    integer probe_lo  [0:14];
    integer probe_hi  [0:14];
    integer probe_hit [0:14];
    integer probe_first [0:14];

    // Dual-clock DUT under test: both clocks are tied to this bench's single
    // clock and both resets to this bench's single reset, so every assertion
    // below runs in the single-clock regime it was written for. ce gates only
    // the raster, as before.
    nes_video_800x480 dut (
        .wr_clk(clk),
        .wr_reset(reset),
        .rd_clk(clk),
        .rd_reset(reset),
        .ce(ce),
        .in_valid(in_valid),
        .in_x(in_x),
        .in_y(in_y),
        .in_rgb565(in_rgb565),
        .rgb565(rgb565),
        .de(de),
        .hsync(hsync),
        .vsync(vsync),
        .hcount(hcount),
        .vcount(vcount),
        .pixel_x(pixel_x),
        .pixel_y(pixel_y),
        .frame_pulse(frame_pulse),
        .in_line_ready(in_line_ready),
        .in_frame_ready(in_frame_ready)
    );

    // Reference column map, derived independently of the RTL: the 800 active
    // dots are 32 groups of 25, and inside a group columns 0..6 take 3 dots
    // each while column 7 takes the remaining 4.
    task build_tables;
        integer g;
        integer r;
        integer j;
        integer b;
        integer e;
        begin
            for (ox = 0; ox < 800; ox = ox + 1) begin
                g = ox / 25;
                r = ox - (g * 25);
                if (r < 21) ref_col[ox] = (8 * g) + (r / 3);
                else ref_col[ox] = (8 * g) + 7;
                probe_at[ox] = 0;
            end
            for (b = 0; b < 256; b = b + 1) begin
                j = b - (8 * (b / 8));
                if (j == 7) span_ref[b] = 4;
                else span_ref[b] = 3;
            end
            for (k = 0; k < PROBE_N; k = k + 1) begin
                g = probe[k] / 8;
                j = probe[k] - (8 * g);
                if (j == 7) begin
                    probe_lo[k] = (25 * g) + 21;
                    probe_hi[k] = probe_lo[k] + 4;
                end else begin
                    probe_lo[k] = (25 * g) + (3 * j);
                    probe_hi[k] = probe_lo[k] + 3;
                end
                for (e = probe_lo[k]; e < probe_hi[k]; e = e + 1) probe_at[e] = k + 1;
            end
        end
    endtask

    task err;
        input [8*40:1] code;
        input integer a;
        input integer b;
        begin
            errors = errors + 1;
            if (errors <= 24)
                $display("VIOLATION %0s a=%0d b=%0d frame=%0d hcnt=%0d vcnt=%0d x=%0d y=%0d",
                         code, a, b, frames, hcount, vcount, pixel_x, pixel_y);
        end
    endtask

    task write_frame;
        input [15:0] xor_val;
        integer xx;
        integer yy;
        begin
            if (ce_div != 1) err("WRITE_CE_DIV", ce_div, 0);
            @(negedge clk);
            in_valid = 1'b1;
            for (yy = 0; yy < 240; yy = yy + 1) begin
                for (xx = 0; xx < 256; xx = xx + 1) begin
                    in_x      = xx[7:0];
                    in_y      = yy[7:0];
                    in_rgb565 = {xx[7:0], yy[7:0]} ^ xor_val;
                    @(negedge clk);
                end
            end
            if (in_frame_ready !== 1'b1) err("IN_FRAME_READY_MISSED", 0, 0);
            in_valid  = 1'b0;
            in_x      = 8'd0;
            in_y      = 8'd0;
            in_rgb565 = 16'h0000;
            @(negedge clk);
        end
    endtask

    always #5 clk = ~clk;

    always @(negedge clk) begin
        if (ce_cnt >= (ce_div - 1)) ce_cnt = 0;
        else ce_cnt = ce_cnt + 1;
        ce = (ce_cnt == 0);
    end

    always @(posedge clk) begin
        if (hold_valid && !hold_ce && !reset) begin
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
            ce_total    = ce_total + 1;
            frame_ticks = frame_ticks + 1;

            if (reset) begin
                reset_seen = reset_seen + 1;
                frame_ticks  = 0;
                act_lines    = 0;
                line_px      = 0;
                full_frame   = 0;
                in_lines     = 0;
                line_sig_r   = 16'h0000;
                sig_prev_r   = 16'h0000;
                frame_sig_r  = 32'h0000_0000;
                if (reset_seen < 2) begin
                end else begin
                    if (hcount !== 11'd0) err("RESET_HCOUNT", hcount, 0);
                    if (vcount !== 11'd0) err("RESET_VCOUNT", vcount, 0);
                    if (de !== 1'b0) err("RESET_DE", de, 0);
                    if (hsync !== SYNC_LVL) err("RESET_HSYNC", hsync, 0);
                    if (vsync !== SYNC_LVL) err("RESET_VSYNC", vsync, 0);
                    if (rgb565 !== BLANK) err("RESET_RGB", rgb565, 0);
                    if (pixel_x !== 11'd0) err("RESET_PIXEL_X", pixel_x, 0);
                    if (pixel_y !== 11'd0) err("RESET_PIXEL_Y", pixel_y, 0);
                    if (frame_pulse !== 1'b0) err("RESET_FRAME", frame_pulse, 0);
                    if (in_line_ready !== 1'b0) err("RESET_LR", in_line_ready, 0);
                    if (in_frame_ready !== 1'b0) err("RESET_FR", in_frame_ready, 0);
                    if (dut.mod8_count !== 3'd0) err("RESET_MOD8", dut.mod8_count, 0);
                    if (dut.group_count !== 5'd0) err("RESET_GROUP", dut.group_count, 0);
                    if (dut.emit_slot !== 2'd0) err("RESET_SLOT", dut.emit_slot, 0);
                    for (k = 0; k < PROBE_N; k = k + 1) probe_hit[k] = 0;
                end
            end else begin
                reset_seen = 0;
                if (in_line_ready) in_lines = in_lines + 1;
                if (in_frame_ready) begin
                    if (in_lines !== 240) err("IN_LINE_COUNT", in_lines, 240);
                    in_lines = 0;
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
                    if (ox === 0) begin
                        line_px = 1;
                        line_sig_r = 16'h0000;
                        if (dut.mod8_count !== 3'd0) err("MOD8_RESET", dut.mod8_count, 0);
                        if (dut.group_count !== 5'd0) err("GROUP_RESET", dut.group_count, 0);
                        if (dut.emit_slot !== 2'd0) err("SLOT_RESET", dut.emit_slot, 0);
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

                    pk = probe_at[ox];
                    if (pk > 0) begin
                        if (dut.src_col !== probe[pk - 1][7:0]) err("PROBE_SRCCOL", probe[pk - 1], dut.src_col);
                        if (checking && (rgb565 !== ({exp_col[7:0], exp_row[7:0]} ^ xor_sel)))
                            err("PROBE_PIXEL", probe[pk - 1], rgb565);
                        probe_hit[pk - 1] = probe_hit[pk - 1] + 1;
                        if (probe_first[pk - 1] < 0) probe_first[pk - 1] = ox;
                    end

                    if (checking) begin
                        if (rgb565 !== ({exp_col[7:0], exp_row[7:0]} ^ xor_sel))
                            err("PIXEL_VALUE", ox, rgb565);
                        line_sig_r  = line_sig_r + ({6'd0, rgb565[9:0]} * 16'd7) + {10'd0, pixel_x[9:0]};
                        frame_sig_r = frame_sig_r + ({16'd0, rgb565} * 32'd7)
                                              + ({16'd0, pixel_x} * 32'd1000003);
                    end

                    if (ox === 799) begin
                        if (line_px !== 800) err("LINE_WIDTH", line_px, pixel_y);
                        for (k = 0; k < 256; k = k + 1) begin
                            if (col_hit[k] !== span_ref[k]) err("COL_SPAN", k, col_hit[k]);
                            col_hit[k] = 0;
                        end
                        if (checking) begin
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
                        for (k = 0; k < PROBE_N; k = k + 1) begin
                            if (probe_hit[k] !== (span_ref[probe[k]] * 480)) err("PROBE_HIT_COUNT", probe[k], probe_hit[k]);
                            probe_hit[k] = 0;
                        end
                        if (have_prev_frame_sig && (frame_sig_r !== prev_frame_sig_r))
                            err("FRAME_UNSTABLE", frames, 0);
                        if (have_prev_frame_sig) frames_stable = frames_stable + 1;
                        prev_frame_sig_r  = frame_sig_r;
                        have_prev_frame_sig = 1;
                        frames_checked = frames_checked + 1;
                        if (expect_pat == 0) sig0_r = frame_sig_r;
                        else sig1_r = frame_sig_r;
                    end else begin
                        if ((act_lines !== 0) && (act_lines !== 480)) err("FRAME_ACTIVE_LINES", act_lines, 480);
                        for (k = 0; k < PROBE_N; k = k + 1) probe_hit[k] = 0;
                    end
                    frame_sig_r = 32'h0000_0000;
                    frame_ticks = 0;
                    act_lines   = 0;
                    full_frame  = checking;
                end
            end
        end
        if (reset) hold_valid = 0;
    end

    task wait_frames;
        input integer n;
        integer target;
        begin
            target = frames + n;
            while (frames < target) begin
                @(posedge clk);
                #1;
            end
        end
    endtask

    task wait_frame_start;
        begin
            @(posedge clk);
            #1;
            while ((hcount !== 11'd0) || (vcount !== 11'd0)) begin
                @(posedge clk);
                #1;
            end
        end
    endtask

    initial begin
        clk       = 1'b0;
        reset     = 1'b1;
        ce        = 1'b0;
        ce_div    = 1;
        ce_cnt    = 1;
        in_valid  = 1'b0;
        in_x      = 8'h00;
        in_y      = 8'h00;
        in_rgb565 = 16'h0000;

        errors     = 0;
        ce_total   = 0;
        frames     = 0;
        frame_ticks = 0;
        line_px    = 0;
        act_lines  = 0;
        checking   = 0;
        full_frame = 0;
        expect_pat = 0;
        ox         = 0;
        pk         = 0;
        win        = 0;
        exp_col    = 0;
        exp_row    = 0;
        h_hold     = 0;
        v_hold     = 0;
        d_hold     = 0;
        f_hold     = 0;
        hold_ce    = 1;
        hold_valid = 0;
        frames_checked = 0;
        frames_stable  = 0;
        have_prev_frame_sig = 0;
        reset_seen = 0;
        in_lines = 0;
        xor_sel    = P0_XOR;
        line_sig_r  = 16'h0000;
        sig_prev_r  = 16'h0000;
        frame_sig_r = 32'h0000_0000;
        prev_frame_sig_r = 32'h0000_0000;
        sig0_r = 32'h0000_0000;
        sig1_r = 32'h0000_0000;

        probe[0]  =   0; probe[1]  =   1; probe[2]  =   2; probe[3]  =   3;
        probe[4]  =   6; probe[5]  =   7; probe[6]  =   8; probe[7]  =   9;
        probe[8]  =  15; probe[9]  =  16; probe[10] =  17;
        probe[11] = 248; probe[12] = 249; probe[13] = 250; probe[14] = 255;
        for (k = 0; k < 256; k = k + 1) col_hit[k] = 0;
        for (k = 0; k < PROBE_N; k = k + 1) begin
            probe_hit[k]  = 0;
            probe_first[k] = -1;
        end
        build_tables;

        $display("PROBE reference map: input column -> output dot range");
        for (k = 0; k < PROBE_N; k = k + 1)
            $display("PROBE col=%0d dots=%0d..%0d span=%0d", probe[k], probe_lo[k], probe_hi[k] - 1, span_ref[probe[k]]);

        repeat (8) @(posedge clk);
        @(negedge clk);
        reset = 1'b0;

        write_frame(P0_XOR);
        @(posedge clk);
        #1;
        checking   = 1;
        expect_pat = 0;
        xor_sel    = P0_XOR;

        wait_frames(4);

        repeat (20) @(posedge clk);
        @(negedge clk);
        reset = 1'b1;
        repeat (8) @(posedge clk);
        @(negedge clk);
        reset = 1'b0;

        checking   = 0;
        expect_pat = 1;
        xor_sel    = P1_XOR;
        have_prev_frame_sig = 0;
        wait_frame_start;
        write_frame(P1_XOR);
        @(posedge clk);
        #1;
        checking = 1;

        wait_frames(2);

        wait_frame_start;
        ce_div = 4;
        wait_frames(1);
        ce_div = 1;

        repeat (20) @(posedge clk);

        $display("SUMMARY ce_ticks=%0d output_frames=%0d checked_frames=%0d stable_pairs=%0d violations=%0d",
                 ce_total, frames, frames_checked, frames_stable, errors);
        for (k = 0; k < PROBE_N; k = k + 1)
            $display("PROBE observed col=%0d first_output_dot=%0d", probe[k], probe_first[k]);

        if (frames_checked < 5) err("TOO_FEW_CHECKED_FRAMES", frames_checked, 5);
        if (frames_stable < 2) err("TOO_FEW_STABLE_FRAMES", frames_stable, 2);
        if (sig0_r === sig1_r) err("SIGNATURE_NOT_DISCRIMINATING", sig0_r, sig1_r);
        if (sig0_r === 32'h0000_0000) err("SIGNATURE_ZERO", sig0_r, 0);
        if (sig1_r === 32'h0000_0000) err("SIGNATURE_ZERO", sig1_r, 0);

        if (errors != 0) begin
            $display("FAIL nes_video_800x480 with %0d violations", errors);
            $fatal(1, "nes_video_800x480 tb failed");
        end

        $display("PASS nes_video_800x480 exactly 800 active dots on every line, exactly 480 lines per frame, vendor 0x4384 raster");
        $finish;
    end

    initial begin
        #400000000;
        $fatal(1, "global timeout");
    end

endmodule
