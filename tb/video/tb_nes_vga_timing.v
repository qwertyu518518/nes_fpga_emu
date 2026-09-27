`timescale 1ns/1ps

module tb_nes_vga_timing;

    reg clk;
    reg reset;
    reg ce;
    reg line_read_start;
    reg px_valid;
    reg [15:0] px_rgb565;

    wire        hsync;
    wire        vsync;
    wire        de;
    wire [15:0] rgb565;
    wire [9:0]  hcount;
    wire [9:0]  vcount;
    wire        active_pixels;
    wire        frame_pulse;
    wire        line_read_sync;

    integer mx;
    integer my;
    integer nx;
    integer ny;
    integer s_col;
    integer s_row;
    integer n_cycle;
    integer n_frame;
    integer first_fp;
    integer last_fp;
    integer n_de_pix;
    integer n_lrs;
    integer n_drop;
    integer n_nodeata;
    integer hs_run;
    integer vs_lines;
    integer drop_list [0:2];
    integer n_drops;
    integer skip_strobe_y;
    integer extra_x;
    integer extra_y;
    integer wrap_y;
    integer zero_strobe_y;
    integer guard;

    reg        line_ok;
    reg        e_hs;
    reg        e_vs;
    reg        e_de;
    reg        e_fp;
    reg        e_lrs;
    reg        e_act;
    integer    e_kind;
    reg [15:0] e_rgb;

    reg        p_hold_lrs;
    reg        p_hold_pv;
    reg [15:0] p_hold_rgb;

    reg [9:0]  f_hcount;
    reg [9:0]  f_vcount;
    reg        f_hsync;
    reg        f_vsync;
    reg        f_de;
    reg [15:0] f_rgb;
    reg        f_act;
    reg        f_fp;
    reg        f_lrs;

    always #20 clk = ~clk;

    nes_vga_timing dut (
        .clk             (clk),
        .reset           (reset),
        .ce              (ce),
        .line_read_start (line_read_start),
        .px_valid        (px_valid),
        .px_rgb565       (px_rgb565),
        .hsync           (hsync),
        .vsync           (vsync),
        .de              (de),
        .rgb565          (rgb565),
        .hcount          (hcount),
        .vcount          (vcount),
        .active_pixels   (active_pixels),
        .frame_pulse     (frame_pulse),
        .line_read_sync  (line_read_sync)
    );

    function [15:0] src_pat;
        input integer yy;
        input integer xx;
        begin
            src_pat = {yy[7:0], xx[7:0]} + 16'h0001;
        end
    endfunction

    task zero_check;
        begin
            if (hcount !== 10'd0)
                $fatal(1, "VGAT reset left hcount at %0d", hcount);
            if (vcount !== 10'd0)
                $fatal(1, "VGAT reset left vcount at %0d", vcount);
            if (hsync !== 1'b0)
                $fatal(1, "VGAT reset left hsync asserted");
            if (vsync !== 1'b0)
                $fatal(1, "VGAT reset left vsync asserted");
            if (de !== 1'b0)
                $fatal(1, "VGAT reset left de asserted");
            if (rgb565 !== 16'h0000)
                $fatal(1, "VGAT reset left rgb565 at %04h", rgb565);
            if (active_pixels !== 1'b0)
                $fatal(1, "VGAT reset left active_pixels asserted");
            if (frame_pulse !== 1'b0)
                $fatal(1, "VGAT reset left frame_pulse asserted");
            if (line_read_sync !== 1'b0)
                $fatal(1, "VGAT reset left line_read_sync asserted");
        end
    endtask

    task drive;
        input integer tx;
        input integer ty;
        integer   k;
        begin
            e_hs  = (tx >= 656 && tx < 752);
            e_vs  = (ty >= 490 && ty < 493);
            e_de  = (tx >= 64 && tx < 576) && (ty >= 0 && ty < 480);
            e_fp  = (tx == 799 && ty == 524);

            e_lrs = 1'b0;
            if (tx == 64 && ty != skip_strobe_y)
                e_lrs = 1'b1;
            if (tx == extra_x && ty == extra_y)
                e_lrs = 1'b1;
            if (tx == 799 && ty == wrap_y)
                e_lrs = 1'b1;
            if (tx == 0 && ty == zero_strobe_y)
                e_lrs = 1'b1;
            line_read_start = e_lrs;
            if (e_lrs) begin
                s_row = ty;
                s_col = 0;
            end

            if (e_lrs)
                line_ok = 1'b1;
            else if (mx == 799)
                line_ok = 1'b0;

            px_valid  = 1'b1;
            px_rgb565 = src_pat(s_row, s_col);
            for (k = 0; k < n_drops; k = k + 1) begin
                if (s_col == drop_list[k]) begin
                    px_valid  = 1'b0;
                    px_rgb565 = 16'hDEAD;
                end
            end
            s_col = s_col + 1;
            if (s_col == 512) begin
                s_col = 0;
                if (s_row == 479)
                    s_row = 0;
                else
                    s_row = s_row + 1;
            end

            e_act = e_de & line_ok & px_valid;
            e_rgb = e_act ? px_rgb565 : 16'h0000;

            if (e_de && !line_ok)
                e_kind = 2;
            else if (e_de && !px_valid)
                e_kind = 1;
            else
                e_kind = 0;

            p_hold_lrs = line_read_start;
            p_hold_pv  = px_valid;
            p_hold_rgb = px_rgb565;
        end
    endtask

    task drive_rearm;
        begin
            line_read_start = p_hold_lrs;
            px_valid        = p_hold_pv;
            px_rgb565       = p_hold_rgb;
        end
    endtask

    task landmarks;
        begin
            if (mx == 0 && hsync !== 1'b0)
                $fatal(1, "VGAT hsync must be low at x=0");
            if (mx == 655 && hsync !== 1'b0)
                $fatal(1, "VGAT hsync must still be low at x=655");
            if (mx == 656 && hsync !== 1'b1)
                $fatal(1, "VGAT hsync must start at x=656");
            if (mx == 751 && hsync !== 1'b1)
                $fatal(1, "VGAT hsync must be high through x=751");
            if (mx == 752 && hsync !== 1'b0)
                $fatal(1, "VGAT hsync must end after x=751");
            if (mx == 63 && de !== 1'b0)
                $fatal(1, "VGAT de must be low at x=63");
            if (my < 480 && mx == 64 && de !== 1'b1)
                $fatal(1, "VGAT de must start at x=64 on row %0d", my);
            if (my < 480 && mx == 575 && de !== 1'b1)
                $fatal(1, "VGAT de must be high through x=575 on row %0d", my);
            if (mx == 576 && de !== 1'b0)
                $fatal(1, "VGAT de must end after x=575");
            if (mx == 64 && my == 0 && de !== 1'b1)
                $fatal(1, "VGAT de must be high on the first visible row");
            if (mx == 64 && my == 479 && de !== 1'b1)
                $fatal(1, "VGAT de must be high on row 479");
            if (mx == 64 && my == 480 && de !== 1'b0)
                $fatal(1, "VGAT de must be low from row 480");
            if (mx == 799 && my == 480 && de !== 1'b0)
                $fatal(1, "VGAT row 480 must be blank from x=64 to the end of the line");
            if (mx == 799 && my == 479 && de !== 1'b0)
                $fatal(1, "VGAT row 479 must stay active up to x=575 and blank after it");
            if (mx == 64 && my == 489 && vsync !== 1'b0)
                $fatal(1, "VGAT vsync must be low on row 489");
            if (mx == 64 && my == 490 && vsync !== 1'b1)
                $fatal(1, "VGAT vsync must start on row 490");
            if (mx == 64 && my == 492 && vsync !== 1'b1)
                $fatal(1, "VGAT vsync must be high through row 492");
            if (mx == 64 && my == 493 && vsync !== 1'b0)
                $fatal(1, "VGAT vsync must end after row 492");
            if (mx == 63 && hsync === 1'b1)
                $fatal(1, "VGAT hsync must not overlap the start of the active area");
            if (mx == 575 && hsync === 1'b1)
                $fatal(1, "VGAT hsync must not overlap the end of the active area");
            if (mx == 799 && my == 524 && frame_pulse !== 1'b1)
                $fatal(1, "VGAT frame_pulse must ride the last pixel of the frame");
            if (mx == 799 && my != 524 && frame_pulse === 1'b1)
                $fatal(1, "VGAT frame_pulse fired on row %0d", my);
            if (mx == 0 && my == 0 && frame_pulse === 1'b1)
                $fatal(1, "VGAT frame_pulse must not ride the first pixel of a frame");
        end
    endtask

    task check_now;
        begin
            if (hcount !== mx)
                $fatal(1, "VGAT hcount is %0d, expected %0d at vcount %0d", hcount, mx, my);
            if (vcount !== my)
                $fatal(1, "VGAT vcount is %0d, expected %0d at hcount %0d", vcount, my, hcount);
            if (hsync !== e_hs)
                $fatal(1, "VGAT hsync is %b at (%0d,%0d), expected %b", hsync, mx, my, e_hs);
            if (vsync !== e_vs)
                $fatal(1, "VGAT vsync is %b at (%0d,%0d), expected %b", vsync, mx, my, e_vs);
            if (de !== e_de)
                $fatal(1, "VGAT de is %b at (%0d,%0d), expected %b", de, mx, my, e_de);
            if (frame_pulse !== e_fp)
                $fatal(1, "VGAT frame_pulse is %b at (%0d,%0d), expected %b", frame_pulse, mx, my, e_fp);
            if (line_read_sync !== e_lrs)
                $fatal(1, "VGAT line_read_sync is %b at (%0d,%0d), expected %b", line_read_sync, mx, my, e_lrs);
            if (active_pixels !== e_act)
                $fatal(1, "VGAT active_pixels is %b at (%0d,%0d), expected %b", active_pixels, mx, my, e_act);
            if (rgb565 !== e_rgb)
                $fatal(1, "VGAT rgb565 is %04h at (%0d,%0d), expected %04h", rgb565, mx, my, e_rgb);

            if (e_kind == 1) begin
                n_drop = n_drop + 1;
                if (de !== 1'b1)
                    $fatal(1, "VGAT de must stay high at the dropped pixel (%0d,%0d)", mx, my);
                if (active_pixels !== 1'b0)
                    $fatal(1, "VGAT active_pixels must be low without px_valid at (%0d,%0d)", mx, my);
                if (rgb565 !== 16'h0000)
                    $fatal(1, "VGAT a missing pixel must come out black at (%0d,%0d), got %04h", mx, my, rgb565);
            end

            if (e_kind == 2) begin
                n_nodeata = n_nodeata + 1;
                if (de !== 1'b1)
                    $fatal(1, "VGAT de must stay high on a line without line_read_start at (%0d,%0d)", mx, my);
                if (active_pixels !== 1'b0)
                    $fatal(1, "VGAT active_pixels must be low without line_read_start at (%0d,%0d)", mx, my);
                if (rgb565 !== 16'h0000)
                    $fatal(1, "VGAT an unaligned line must come out black at (%0d,%0d), got %04h", mx, my, rgb565);
            end

            landmarks;

            if (frame_pulse === 1'b1) begin
                if (n_frame == 0)
                    first_fp = n_cycle;
                last_fp = n_cycle;
                n_frame  = n_frame + 1;
                if (n_de_pix !== 245760)
                    $fatal(1, "VGAT the frame carried %0d active pixels, expected 245760", n_de_pix);
                if (vs_lines !== 3)
                    $fatal(1, "VGAT the frame carried %0d vsync lines, expected 3", vs_lines);
                n_de_pix = 0;
                vs_lines = 0;
            end
            if (de === 1'b1)
                n_de_pix = n_de_pix + 1;
            if (hsync === 1'b1)
                hs_run = hs_run + 1;
            if (mx == 0 && vsync === 1'b1)
                vs_lines = vs_lines + 1;
            if (line_read_sync === 1'b1)
                n_lrs = n_lrs + 1;
            if (mx == 799 && hs_run !== 96)
                $fatal(1, "VGAT line %0d carried %0d hsync cycles, expected 96", my, hs_run);
            if (mx == 799)
                hs_run = 0;
        end
    endtask

    task step;
        begin
            @(posedge clk);
            #1;
            n_cycle = n_cycle + 1;
            check_now;
            if (mx == 799) begin
                nx = 0;
                ny = (my == 524) ? 0 : my + 1;
            end else begin
                nx = mx + 1;
                ny = my;
            end
            drive(nx, ny);
            mx = nx;
            my = ny;
        end
    endtask

    task run_steps;
        input integer n;
        integer k;
        begin
            for (k = 0; k < n; k = k + 1)
                step;
        end
    endtask

    task goto_xy;
        input integer tx;
        input integer ty;
        begin
            guard = 0;
            while (!((mx == tx) && (my == ty))) begin
                if (guard > 2000000)
                    $fatal(1, "VGAT the raster never reached (%0d,%0d), it is at (%0d,%0d)", tx, ty, mx, my);
                guard = guard + 1;
                step;
            end
            step;
        end
    endtask

    task apply_reset;
        begin
            ce              = 1'b0;
            reset           = 1'b1;
            line_read_start = 1'b0;
            px_valid        = 1'b0;
            px_rgb565       = 16'h0000;
            mx              = 0;
            my              = 0;
            line_ok         = 1'b0;
            s_col           = 0;
            s_row           = 0;
            n_cycle         = 0;
            n_frame         = 0;
            first_fp        = 0;
            last_fp         = 0;
            n_de_pix        = 0;
            n_lrs           = 0;
            n_drop          = 0;
            n_nodeata       = 0;
            hs_run          = 0;
            vs_lines        = 0;
            n_drops         = 0;
            skip_strobe_y   = -1;
            extra_x         = -1;
            extra_y         = -1;
            wrap_y          = -1;
            zero_strobe_y   = -1;
            repeat (3) begin
                @(posedge clk);
                #1;
                zero_check;
            end
            reset = 1'b0;
        end
    endtask

    task raster_arm;
        begin
            mx       = 1;
            my       = 0;
            line_ok  = 1'b0;
            s_col    = 0;
            s_row    = 0;
            hs_run   = 0;
            n_de_pix = 0;
            vs_lines = 0;
            n_lrs    = 0;
            n_drop   = 0;
            n_nodeata = 0;
            drive(1, 0);
        end
    endtask

    task snap;
        begin
            f_hcount = hcount;
            f_vcount = vcount;
            f_hsync  = hsync;
            f_vsync  = vsync;
            f_de     = de;
            f_rgb    = rgb565;
            f_act    = active_pixels;
            f_fp     = frame_pulse;
            f_lrs    = line_read_sync;
        end
    endtask

    task snap_check;
        input integer cycles;
        begin
            if (hcount !== f_hcount || vcount !== f_vcount)
                $fatal(1, "VGAT ce=0 moved the raster from (%0d,%0d) to (%0d,%0d)", f_hcount, f_vcount, hcount, vcount);
            if (hsync !== f_hsync || vsync !== f_vsync || de !== f_de)
                $fatal(1, "VGAT ce=0 moved the sync window at freeze cycle %0d", cycles);
            if (rgb565 !== f_rgb || active_pixels !== f_act)
                $fatal(1, "VGAT ce=0 moved the pixel bus at freeze cycle %0d, got %04h expected %04h", cycles, rgb565, f_rgb);
            if (frame_pulse !== f_fp || line_read_sync !== f_lrs)
                $fatal(1, "VGAT ce=0 moved a strobe at freeze cycle %0d", cycles);
        end
    endtask

    task test_reset_contract;
        integer k;
        begin
            apply_reset;
            line_read_start = 1'b1;
            px_valid        = 1'b1;
            px_rgb565       = 16'hFFFF;
            for (k = 0; k < 12; k = k + 1) begin
                @(posedge clk);
                #1;
                zero_check;
            end
            $display("VGAT reset clears hsync, vsync, de, the pixel bus and both strobes PASS");
        end
    endtask

    task test_reset_mid_frame;
        begin
            apply_reset;
            ce = 1'b1;
            raster_arm;
            step;
            goto_xy(100, 3);
            if (de !== 1'b1 || active_pixels !== 1'b1)
                $fatal(1, "VGAT the mid frame reset test needs a live pixel at (100,3)");
            if (rgb565 === 16'h0000)
                $fatal(1, "VGAT the mid frame reset test needs a nonzero pixel at (100,3)");
            ce              = 1'b0;
            reset           = 1'b1;
            line_read_start = 1'b1;
            px_valid        = 1'b1;
            px_rgb565       = 16'hFFFF;
            repeat (2) begin
                @(posedge clk);
                #1;
                zero_check;
            end
            reset           = 1'b0;
            line_read_start = 1'b0;
            px_valid        = 1'b0;
            px_rgb565       = 16'h0000;
            @(posedge clk);
            #1;
            zero_check;
            ce = 1'b1;
            raster_arm;
            step;
            goto_xy(64, 0);
            if (rgb565 !== src_pat(0, 0))
                $fatal(1, "VGAT after the reset the first active pixel is %04h, expected %04h", rgb565, src_pat(0, 0));
            if (n_lrs !== 1)
                $fatal(1, "VGAT after the reset line 0 raised %0d line starts, expected 1", n_lrs);
            $display("VGAT reset wins over ce=0, homes the raster and restarts the line stream PASS");
        end
    endtask

    task test_ce_freeze;
        integer k;
        begin
            apply_reset;
            ce = 1'b1;
            raster_arm;
            step;
            goto_xy(200, 7);
            if (de !== 1'b1 || active_pixels !== 1'b1 || rgb565 === 16'h0000)
                $fatal(1, "VGAT the ce freeze test needs a live pixel at (200,7)");
            snap;
            ce              = 1'b0;
            line_read_start = 1'b1;
            px_valid        = 1'b1;
            px_rgb565       = 16'hFFFF;
            for (k = 0; k < 16; k = k + 1) begin
                @(posedge clk);
                #1;
                snap_check(k);
            end
            ce = 1'b1;
            drive_rearm;
            step;
            if (hcount !== 10'd201)
                $fatal(1, "VGAT the raster did not resume at x=201, it is at %0d", hcount);
            if (rgb565 !== src_pat(7, 137))
                $fatal(1, "VGAT after the freeze the stream is %04h at x=201, expected %04h", rgb565, src_pat(7, 137));
            skip_strobe_y = 8;
            goto_xy(10, 8);
            if (line_read_sync !== 1'b0)
                $fatal(1, "VGAT line_read_sync must be low on a fresh line before its strobe");
            if (n_nodeata !== 0)
                $fatal(1, "VGAT line 8 counted %0d unaligned pixels before x=10", n_nodeata);
            snap;
            ce              = 1'b0;
            line_read_start = 1'b1;
            px_valid        = 1'b1;
            px_rgb565       = 16'hFFFF;
            for (k = 0; k < 16; k = k + 1) begin
                @(posedge clk);
                #1;
                snap_check(k);
            end
            ce = 1'b1;
            drive_rearm;
            goto_xy(575, 8);
            if (n_nodeata !== 512)
                $fatal(1, "VGAT the line without a strobe produced %0d black pixels, expected 512", n_nodeata);
            skip_strobe_y = -1;
            goto_xy(64, 9);
            if (rgb565 !== src_pat(9, 0))
                $fatal(1, "VGAT line 9 is %04h, expected source column 0 %04h", rgb565, src_pat(9, 0));
            $display("VGAT ce=0 freezes the whole raster, the pixel bus and the strobes PASS");
        end
    endtask

    task test_missing_pixels;
        begin
            apply_reset;
            ce = 1'b1;
            raster_arm;
            step;
            goto_xy(0, 10);
            drop_list[0] = 5;
            drop_list[1] = 6;
            drop_list[2] = 511;
            n_drops      = 3;
            goto_xy(68, 10);
            if (rgb565 !== src_pat(10, 4))
                $fatal(1, "VGAT a pending drop must not shift the stream, got %04h expected %04h", rgb565, src_pat(10, 4));
            goto_xy(69, 10);
            if (n_drop !== 1 || rgb565 !== 16'h0000)
                $fatal(1, "VGAT the dropped column 5 produced %0d black pixels, got %04h", n_drop, rgb565);
            goto_xy(70, 10);
            if (n_drop !== 2 || rgb565 !== 16'h0000)
                $fatal(1, "VGAT the dropped column 6 produced %0d black pixels, got %04h", n_drop, rgb565);
            goto_xy(71, 10);
            if (rgb565 !== src_pat(10, 7))
                $fatal(1, "VGAT the stream did not resume after the holes, got %04h expected %04h", rgb565, src_pat(10, 7));
            goto_xy(575, 10);
            if (n_drop !== 3 || rgb565 !== 16'h0000)
                $fatal(1, "VGAT the dropped last column produced %0d black pixels, got %04h", n_drop, rgb565);
            goto_xy(576, 10);
            if (de !== 1'b0 || rgb565 !== 16'h0000)
                $fatal(1, "VGAT x=576 must leave the active area and go black");
            n_drops       = 0;
            skip_strobe_y = 11;
            goto_xy(0, 12);
            if (n_nodeata !== 512)
                $fatal(1, "VGAT line 11 without a strobe produced %0d black pixels, expected 512", n_nodeata);
            if (n_drop !== 3)
                $fatal(1, "VGAT the dropped pixel counter moved to %0d", n_drop);
            goto_xy(64, 12);
            if (rgb565 !== src_pat(12, 0))
                $fatal(1, "VGAT line 12 did not restart at source column 0, got %04h expected %04h", rgb565, src_pat(12, 0));
            $display("VGAT missing pixels and a missing line start both come out black while de stays high PASS");
        end
    endtask

    task test_line_read_align;
        integer n0;
        begin
            apply_reset;
            ce = 1'b1;
            raster_arm;
            step;
            n0 = n_lrs;
            goto_xy(63, 20);
            n0 = n_lrs;
            goto_xy(64, 20);
            if (rgb565 !== src_pat(20, 0))
                $fatal(1, "VGAT the first active pixel is %04h, expected source column 0 %04h", rgb565, src_pat(20, 0));
            goto_xy(575, 20);
            if (rgb565 !== src_pat(20, 511))
                $fatal(1, "VGAT the last active pixel is %04h, expected source column 511 %04h", rgb565, src_pat(20, 511));
            if (n_lrs - n0 !== 1)
                $fatal(1, "VGAT line 20 raised %0d line starts, expected 1", n_lrs - n0);
            extra_x = 300;
            extra_y = 21;
            goto_xy(299, 21);
            n0 = n_lrs;
            goto_xy(300, 21);
            if (line_read_sync !== 1'b1)
                $fatal(1, "VGAT line_read_sync did not echo the mid line strobe");
            if (rgb565 !== src_pat(21, 0))
                $fatal(1, "VGAT a mid line strobe did not re-home the stream, got %04h expected %04h", rgb565, src_pat(21, 0));
            if (hcount !== 10'd300 || vcount !== 10'd21)
                $fatal(1, "VGAT the mid line strobe moved the raster to (%0d,%0d)", hcount, vcount);
            if (n_lrs - n0 !== 1)
                $fatal(1, "VGAT line 21 raised %0d line starts, expected 1", n_lrs - n0);
            goto_xy(301, 21);
            if (rgb565 !== src_pat(21, 1))
                $fatal(1, "VGAT the re-homed stream is %04h at x=301, expected %04h", rgb565, src_pat(21, 1));
            goto_xy(575, 21);
            if (rgb565 !== src_pat(21, 275))
                $fatal(1, "VGAT the re-homed line is %04h at x=575, expected %04h", rgb565, src_pat(21, 275));
            extra_x = -1;
            extra_y = -1;
            goto_xy(63, 22);
            n0 = n_lrs;
            goto_xy(64, 22);
            if (rgb565 !== src_pat(22, 0))
                $fatal(1, "VGAT line 22 is %04h, expected source column 0 %04h", rgb565, src_pat(22, 0));
            if (n_lrs - n0 !== 1)
                $fatal(1, "VGAT line 22 raised %0d line starts, expected 1", n_lrs - n0);
            $display("VGAT line_read_start re-homes the stream at x=0 of a line without touching the frame counter PASS");
        end
    endtask

    task test_last_pixel_strobe;
        integer n0;
        begin
            apply_reset;
            ce = 1'b1;
            raster_arm;
            step;
            goto_xy(300, 12);
            wrap_y        = 12;
            skip_strobe_y = 13;
            goto_xy(798, 12);
            n0 = n_lrs;
            goto_xy(799, 12);
            if (line_read_sync !== 1'b1)
                $fatal(1, "VGAT a line_read_start on the last pixel of a line must still be echoed");
            if (n_lrs - n0 !== 1)
                $fatal(1, "VGAT the last pixel of line 12 raised %0d line starts, expected 1", n_lrs - n0);
            goto_xy(575, 13);
            if (n_nodeata !== 512)
                $fatal(1, "VGAT a line_read_start on the last pixel must not align the next line, %0d of 512 pixels are black", n_nodeata);
            $display("VGAT a line_read_start on the last pixel of a line is echoed but the wrap still clears it PASS");
        end
    endtask

    task test_zero_strobe;
        begin
            apply_reset;
            ce = 1'b1;
            raster_arm;
            step;
            goto_xy(300, 12);
            zero_strobe_y = 13;
            skip_strobe_y = 13;
            goto_xy(799, 12);
            goto_xy(64, 13);
            if (rgb565 !== src_pat(13, 64))
                $fatal(1, "VGAT a line_read_start at x=0 must home the stream at x=0, got %04h expected %04h", rgb565, src_pat(13, 64));
            if (active_pixels !== 1'b1)
                $fatal(1, "VGAT a line_read_start at x=0 must keep the next line aligned");
            goto_xy(575, 13);
            if (rgb565 !== src_pat(14, 63))
                $fatal(1, "VGAT the x=0 aligned line is %04h at x=575, expected %04h", rgb565, src_pat(14, 63));
            if (n_nodeata !== 0)
                $fatal(1, "VGAT the x=0 aligned line still has %0d black pixels", n_nodeata);
            skip_strobe_y = -1;
            goto_xy(64, 14);
            if (rgb565 !== src_pat(14, 0))
                $fatal(1, "VGAT line 14 is %04h, expected source column 0 %04h", rgb565, src_pat(14, 0));
            $display("VGAT a line_read_start presented at x=0 wins over the wrap clear and keeps the line aligned PASS");
        end
    endtask

    task test_full_frame;
        begin
            apply_reset;
            ce = 1'b1;
            raster_arm;
            step;
            run_steps(840199);
            if (n_frame !== 2)
                $fatal(1, "VGAT 840200 cycles produced %0d frame pulses, expected 2", n_frame);
            if (first_fp !== 419999)
                $fatal(1, "VGAT the first frame pulse came at cycle %0d, expected 419999", first_fp);
            if (last_fp - first_fp !== 420000)
                $fatal(1, "VGAT the frame period is %0d cycles, expected 420000", last_fp - first_fp);
            if (n_lrs !== 1051)
                $fatal(1, "VGAT 840200 cycles raised %0d line starts, expected 1051", n_lrs);
            if (n_de_pix !== 137)
                $fatal(1, "VGAT the partial third frame carried %0d active pixels, expected 137", n_de_pix);
            if (hcount !== 10'd200 || vcount !== 10'd0)
                $fatal(1, "VGAT after 840200 cycles the raster is at (%0d,%0d), expected (200,0)", hcount, vcount);
            $display("VGAT 800x525 free running raster, 96 hsync, 3 vsync, 245760 active pixels, 420000 cycle frame PASS");
        end
    endtask

    initial begin
        clk             = 1'b0;
        reset           = 1'b1;
        ce              = 1'b0;
        line_read_start = 1'b0;
        px_valid        = 1'b0;
        px_rgb565       = 16'h0000;
        mx              = 0;
        my              = 0;
        s_col           = 0;
        s_row           = 0;
        n_cycle         = 0;
        n_frame         = 0;
        first_fp        = 0;
        last_fp         = 0;
        n_de_pix        = 0;
        n_lrs           = 0;
        n_drop          = 0;
        n_nodeata       = 0;
        hs_run          = 0;
        vs_lines        = 0;
        n_drops         = 0;
        skip_strobe_y   = -1;
        extra_x         = -1;
        extra_y         = -1;
        wrap_y          = -1;
        zero_strobe_y   = -1;
        line_ok         = 1'b0;
        p_hold_lrs      = 1'b0;
        p_hold_pv       = 1'b0;
        p_hold_rgb      = 16'h0000;

        test_reset_contract;
        test_reset_mid_frame;
        test_ce_freeze;
        test_missing_pixels;
        test_line_read_align;
        test_last_pixel_strobe;
        test_zero_strobe;
        test_full_frame;

        $display("PASS nes_vga_timing");
        $finish;
    end

    initial begin
        #120000000;
        $fatal(1, "VGAT global timeout");
    end

endmodule
