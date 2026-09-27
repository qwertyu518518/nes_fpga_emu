`timescale 1ns/1ps

module tb_nes_video_scaler;

    reg         clk;
    reg         reset;
    reg         pixel_valid;
    reg  [7:0]  in_pixel_x;
    reg  [7:0]  in_pixel_y;
    reg  [3:0]  in_pixel_index;

    wire [9:0]  out_pixel_x;
    wire [9:0]  out_pixel_y;
    wire [15:0] rgb565;
    wire        line_ready;
    wire        frame_ready;

    integer     i;
    reg   [3:0] exp_idx;
    reg  [15:0] exp_rgb;
    reg  [15:0] block_c;

    always #5 clk = ~clk;

    nes_video_scaler dut (
        .clk(clk),
        .reset(reset),
        .pixel_valid(pixel_valid),
        .in_pixel_x(in_pixel_x),
        .in_pixel_y(in_pixel_y),
        .in_pixel_index(in_pixel_index),
        .out_pixel_x(out_pixel_x),
        .out_pixel_y(out_pixel_y),
        .rgb565(rgb565),
        .line_ready(line_ready),
        .frame_ready(frame_ready)
    );

    function [15:0] pal_ref;
        input [3:0] color_index;
        begin
            case (color_index)
                4'h0:  pal_ref = 16'h630C;
                4'h1:  pal_ref = 16'h00F1;
                4'h2:  pal_ref = 16'h0884;
                4'h3:  pal_ref = 16'h310C;
                4'h4:  pal_ref = 16'h4008;
                4'h5:  pal_ref = 16'h5807;
                4'h6:  pal_ref = 16'h6080;
                4'h7:  pal_ref = 16'h7140;
                4'h8:  pal_ref = 16'h79E0;
                4'h9:  pal_ref = 16'h6A80;
                4'hA:  pal_ref = 16'h5B20;
                4'hB:  pal_ref = 16'h4360;
                4'hC:  pal_ref = 16'h2B21;
                4'hD:  pal_ref = 16'h0AA2;
                4'hE:  pal_ref = 16'h0204;
                4'hF:  pal_ref = 16'h0184;
                'h10: pal_ref = 16'h0000;
                'h11: pal_ref = 16'hBDF7;
                'h12: pal_ref = 16'h039C;
                'h13: pal_ref = 16'h1C5E;
                'h14: pal_ref = 16'h6D1E;
                'h15: pal_ref = 16'h9D1E;
                'h16: pal_ref = 16'hC55E;
                'h17: pal_ref = 16'hE59E;
                'h18: pal_ref = 16'hED38;
                'h19: pal_ref = 16'hD454;
                'h1A: pal_ref = 16'hCB8F;
                'h1B: pal_ref = 16'hA32E;
                'h1C: pal_ref = 16'h82CC;
                'h1D: pal_ref = 16'h628C;
                'h1E: pal_ref = 16'h4A2A;
                'h1F: pal_ref = 16'h0000;
                'h20: pal_ref = 16'hFFFF;
                'h21: pal_ref = 16'h053F;
                'h22: pal_ref = 16'h3DDF;
                'h23: pal_ref = 16'h6E3F;
                'h24: pal_ref = 16'h9E9F;
                'h25: pal_ref = 16'hC6DF;
                'h26: pal_ref = 16'hD71F;
                'h27: pal_ref = 16'hEF3F;
                'h28: pal_ref = 16'hFF3F;
                'h29: pal_ref = 16'hFE3B;
                'h2A: pal_ref = 16'hFD37;
                'h2B: pal_ref = 16'hF494;
                'h2C: pal_ref = 16'hEC12;
                'h2D: pal_ref = 16'hDBAF;
                'h2E: pal_ref = 16'hC34E;
                'h2F: pal_ref = 16'h9AEE;
                'h30: pal_ref = 16'hFEDB;
                'h31: pal_ref = 16'h05DF;
                'h32: pal_ref = 16'h6E7F;
                'h33: pal_ref = 16'h9EDE;
                'h34: pal_ref = 16'hC71E;
                'h35: pal_ref = 16'hE77E;
                'h36: pal_ref = 16'hF7BE;
                'h37: pal_ref = 16'hFFDF;
                'h38: pal_ref = 16'hFE3D;
                'h39: pal_ref = 16'hFD5A;
                'h3A: pal_ref = 16'hF518;
                'h3B: pal_ref = 16'hF516;
                'h3C: pal_ref = 16'hF514;
                'h3D: pal_ref = 16'hF532;
                'h3E: pal_ref = 16'hF594;
                'h3F: pal_ref = 16'hF594;
                default: pal_ref = 16'h0000;
            endcase
        end
    endfunction

    function [3:0] pattern_index;
        input [7:0]  sx;
        input [7:0]  sy;
        input integer pat;
        reg   [10:0] t;
        begin
            if (pat == 0)
                t = {3'b0, sx} + 3 * {3'b0, sy} + 11'd3;
            else
                t = {3'b0, sx} + 5 * {3'b0, sy} + 11'd7;
            pattern_index = t[3:0];
        end
    endfunction

    task apply_reset;
        begin
            pixel_valid = 1'b0;
            in_pixel_x  = 8'h00;
            in_pixel_y  = 8'h00;
            in_pixel_index = 4'h0;
            reset = 1'b1;
            repeat (3) @(posedge clk);
            #1 reset = 1'b0;
            @(posedge clk);
            #1;
        end
    endtask

    task scan_start;
        begin
            reset = 1'b1;
            @(posedge clk);
            #1 reset = 1'b0;
            @(posedge clk);
            #1;
        end
    endtask

    task write_pixel;
        input [7:0]  sx;
        input [7:0]  sy;
        input [3:0]  ci;
        begin
            in_pixel_x = sx;
            in_pixel_y = sy;
            in_pixel_index = ci;
            pixel_valid = 1'b1;
            @(posedge clk);
            #1;
        end
    endtask

    task write_frame;
        input  integer pat;
        input  integer idle_every;
        output integer o_line;
        output integer o_frame;
        integer ix;
        integer iy;
        integer lc;
        integer fc;
        integer wc;
        integer prev;
        begin
            lc = 0;
            fc = 0;
            wc = 0;
            prev = 0;
            pixel_valid = 1'b0;
            in_pixel_x  = 8'h00;
            in_pixel_y  = 8'h00;
            in_pixel_index = 4'h0;
            @(posedge clk);
            #1;
            for (iy = 0; iy < 240; iy = iy + 1) begin
                for (ix = 0; ix < 256; ix = ix + 1) begin
                    in_pixel_x = ix[7:0];
                    in_pixel_y = iy[7:0];
                    in_pixel_index = pattern_index(ix[7:0], iy[7:0], pat);
                    pixel_valid = 1'b1;
                    @(posedge clk);
                    #1;
                    wc = wc + 1;
                    if ((line_ready === 1'b1) && (prev === 1))
                        $fatal(1, "line_ready stayed high for two cycles at source x=%0d y=%0d", ix, iy);
                    prev = (line_ready === 1'b1) ? 1 : 0;
                    if (line_ready === 1'b1) begin
                        if (ix != 255)
                            $fatal(1, "line_ready asserted at source x=%0d y=%0d, expected x=255", ix, iy);
                        lc = lc + 1;
                    end
                    if (frame_ready === 1'b1) begin
                        if (line_ready !== 1'b1)
                            $fatal(1, "frame_ready asserted without line_ready at source x=%0d y=%0d", ix, iy);
                        if (ix != 255 || iy != 239)
                            $fatal(1, "frame_ready asserted at source x=%0d y=%0d, expected x=255 y=239", ix, iy);
                        fc = fc + 1;
                    end
                    if ((idle_every != 0) && ((wc % idle_every) == 0)) begin
                        pixel_valid = 1'b0;
                        @(posedge clk);
                        #1;
                        if (line_ready !== 1'b0 || frame_ready !== 1'b0)
                            $fatal(1, "a ready pulse appeared on an idle cycle after %0d writes", wc);
                        @(posedge clk);
                        #1;
                        pixel_valid = 1'b1;
                    end
                end
            end
            pixel_valid = 1'b0;
            @(posedge clk);
            #1;
            if (wc != 61440)
                $fatal(1, "wrote %0d pixels, expected 61440", wc);
            o_line = lc;
            o_frame = fc;
        end
    endtask

    task scan_check;
        input integer count;
        input integer pat;
        input integer color_mode;
        input integer check_block;
        input integer x0;
        input integer y0;
        integer x;
        integer y;
        integer n;
        begin
            x = out_pixel_x;
            y = out_pixel_y;
            if ((x !== x0) || (y !== y0))
                $fatal(1, "scan_check expected to start at (%0d,%0d), got (%0d,%0d)", x0, y0, x, y);
            for (n = 0; n < count; n = n + 1) begin
                if (out_pixel_x !== x)
                    $fatal(1, "read pointer x got %0d expected %0d at step %0d", out_pixel_x, x, n);
                if (out_pixel_y !== y)
                    $fatal(1, "read pointer y got %0d expected %0d at step %0d", out_pixel_y, y, n);
                if (color_mode != 0) begin
                    if (color_mode == 1) begin
                        exp_idx = pattern_index((x >> 1), (y >> 1), pat);
                        exp_rgb = pal_ref(exp_idx);
                    end else begin
                        exp_idx = (x >> 1);
                        exp_rgb = pal_ref(exp_idx);
                    end
                    if (rgb565 !== exp_rgb)
                        $fatal(1, "rgb565 at output (%0d,%0d) source (%0d,%0d) got %04h expected %04h",
                               x, y, (x >> 1), (y >> 1), rgb565, exp_rgb);
                end
                if (check_block != 0) begin
                    if ((n & 1) == 0)
                        block_c = rgb565;
                    else if (rgb565 !== block_c)
                        $fatal(1, "2x2 block at output (%0d,%0d) is not a copy: top/left %04h right/bottom %04h",
                               (x & 10'h3FE), (y & 10'h3FE), block_c, rgb565);
                end
                x = x + 1;
                if (x == 512) begin
                    x = 0;
                    y = y + 1;
                    if (y == 480)
                        y = 0;
                end
                @(posedge clk);
                #1;
            end
        end
    endtask

    task check_source_pixel;
        input integer sx;
        input integer sy;
        input integer pat;
        integer k;
        begin
            scan_start;
            for (k = 0; k < ((sy * 2) * 512) + (sx * 2); k = k + 1) begin
                @(posedge clk);
                #1;
            end
            if (out_pixel_x !== (sx * 2) || out_pixel_y !== (sy * 2))
                $fatal(1, "check_source_pixel landed on (%0d,%0d) expected (%0d,%0d)",
                       out_pixel_x, out_pixel_y, sx * 2, sy * 2);
            exp_rgb = pal_ref(pattern_index(sx[7:0], sy[7:0], pat));
            if (rgb565 !== exp_rgb)
                $fatal(1, "source pixel (%0d,%0d) got %04h expected %04h", sx, sy, rgb565, exp_rgb);
        end
    endtask

    task test_reset_initial;
        begin
            apply_reset;
            if (out_pixel_x !== 10'd0 || out_pixel_y !== 10'd0)
                $fatal(1, "reset did not clear the read pointer, got (%0d,%0d)", out_pixel_x, out_pixel_y);
            if (line_ready !== 1'b0 || frame_ready !== 1'b0)
                $fatal(1, "reset left a ready pulse high");
            for (i = 0; i < 5; i = i + 1) begin
                reset = 1'b1;
                @(posedge clk);
                #1;
                if (out_pixel_x !== 10'd0 || out_pixel_y !== 10'd0 || rgb565 !== 16'h0000)
                    $fatal(1, "outputs moved while reset was held high on hold %0d", i);
                if (line_ready !== 1'b0 || frame_ready !== 1'b0)
                    $fatal(1, "a ready pulse appeared while reset was held high on hold %0d", i);
            end
            reset = 1'b0;
            @(posedge clk);
            #1;
            if (out_pixel_x !== 10'd0 || out_pixel_y !== 10'd0)
                $fatal(1, "the read pointer did not start at the origin after reset release");
            $display("VIDEO reset clears the read pointer, the pixel stream and the ready pulses PASS");
        end
    endtask

    task test_palette_64;
        integer ix;
        begin
            apply_reset;
            for (ix = 0; ix < 64; ix = ix + 1)
                write_pixel(ix[7:0], 8'd0, ix[3:0]);
            if (line_ready !== 1'b0 || frame_ready !== 1'b0)
                $fatal(1, "64 pixels of a 256 pixel line must not raise any ready pulse");
            pixel_valid = 1'b0;
            @(posedge clk);
            #1;
            scan_start;
            scan_check(128, 0, 2, 1, 0, 0);
            scan_check(384, 0, 0, 0, 128, 0);
            scan_check(128, 0, 2, 1, 0, 1);
            $display("VIDEO all 64 palette entries reach the 2x2 replicated read stream PASS");
        end
    endtask

    task test_frame_a;
        integer lc;
        integer fc;
        begin
            apply_reset;
            write_frame(0, 7, lc, fc);
            if (lc != 240)
                $fatal(1, "frame A raised line_ready %0d times, expected 240", lc);
            if (fc != 1)
                $fatal(1, "frame A raised frame_ready %0d times, expected 1", fc);
            scan_start;
            scan_check(245760, 0, 1, 1, 0, 0);
            if (out_pixel_x !== 10'd0 || out_pixel_y !== 10'd0)
                $fatal(1, "245760 output pixels did not land back on (0,0), got (%0d,%0d)",
                       out_pixel_x, out_pixel_y);
            $display("VIDEO full 256x240 frame A: 240 line_ready, 1 frame_ready, 512x480 stream PASS");
        end
    endtask

    task test_frame_b;
        integer lc;
        integer fc;
        begin
            write_frame(1, 0, lc, fc);
            if (lc != 240)
                $fatal(1, "frame B raised line_ready %0d times, expected 240", lc);
            if (fc != 1)
                $fatal(1, "frame B raised frame_ready %0d times, expected 1", fc);
            scan_start;
            scan_check(245760, 1, 1, 1, 0, 0);
            $display("VIDEO consecutive frame B overwrites the buffer and restarts the read pointer PASS");
        end
    endtask

    task test_frame_c;
        integer lc;
        integer fc;
        begin
            write_frame(1, 0, lc, fc);
            if (lc != 240)
                $fatal(1, "frame C raised line_ready %0d times, expected 240", lc);
            if (fc != 1)
                $fatal(1, "frame C raised frame_ready %0d times, expected 1", fc);
            check_source_pixel(0, 0, 1);
            check_source_pixel(255, 239, 1);
            check_source_pixel(128, 64, 1);
            $display("VIDEO third consecutive frame keeps 240 lines and one frame pulse PASS");
        end
    endtask

    task test_reset_mid_frame;
        integer ix;
        integer iy;
        integer lc;
        integer fc;
        begin
            for (iy = 0; iy < 100; iy = iy + 1)
                for (ix = 0; ix < 256; ix = ix + 1)
                    write_pixel(ix[7:0], iy[7:0], pattern_index(ix[7:0], iy[7:0], 0));
            pixel_valid = 1'b0;
            @(posedge clk);
            #1;
            if (line_ready !== 1'b0 || frame_ready !== 1'b0)
                $fatal(1, "a ready pulse appeared after 100 complete lines");
            reset = 1'b1;
            repeat (2) @(posedge clk);
            #1;
            if (line_ready !== 1'b0 || frame_ready !== 1'b0)
                $fatal(1, "reset did not drop the ready pulses");
            if (out_pixel_x !== 10'd0 || out_pixel_y !== 10'd0)
                $fatal(1, "reset did not re-home the read pointer");
            check_source_pixel(200, 110, 1);
            reset = 1'b0;
            @(posedge clk);
            #1;
            write_frame(0, 3, lc, fc);
            if (lc != 240)
                $fatal(1, "the frame after a mid frame reset raised line_ready %0d times, expected 240", lc);
            if (fc != 1)
                $fatal(1, "the frame after a mid frame reset raised frame_ready %0d times, expected 1", fc);
            $display("VIDEO mid frame reset restarts the line counter, keeps the buffer and drops the partial frame PASS");
        end
    endtask

    task test_read_pointer_free_running;
        integer cx;
        integer cy;
        integer px;
        integer py;
        begin
            apply_reset;
            scan_start;
            for (i = 0; i < 300; i = i + 1) begin
                px = out_pixel_x;
                py = out_pixel_y;
                in_pixel_x = i[1:0];
                in_pixel_y = 8'd0;
                in_pixel_index = i[3:0];
                pixel_valid = 1'b1;
                @(posedge clk);
                #1;
                cx = (px == 511) ? 0 : (px + 1);
                cy = (px == 511) ? ((py == 479) ? 0 : (py + 1)) : py;
                if (out_pixel_x !== cx || out_pixel_y !== cy)
                    $fatal(1, "the read pointer stalled or skipped at cycle %0d: (%0d,%0d) to (%0d,%0d)",
                           i, px, py, out_pixel_x, out_pixel_y);
                if ((out_pixel_x > 511) || (out_pixel_y > 479))
                    $fatal(1, "the read pointer left the 512x480 raster: (%0d,%0d)", out_pixel_x, out_pixel_y);
            end
            pixel_valid = 1'b0;
            @(posedge clk);
            #1;
            if (frame_ready !== 1'b0)
                $fatal(1, "300 writes must not raise frame_ready");
            if (line_ready !== 1'b0)
                $fatal(1, "a line pulse must not survive the idle cycle after 300 writes");
            $display("VIDEO the read pointer never stalls on writes, line_ready or frame_ready PASS");
        end
    endtask

    task test_stream_geometry;
        integer n;
        integer row;
        begin
            apply_reset;
            scan_start;
            n = 0;
            if (out_pixel_x !== 0 || out_pixel_y !== 0)
                $fatal(1, "the scan did not start at the origin, got (%0d,%0d)", out_pixel_x, out_pixel_y);
            for (row = 0; row < 480; row = row + 1) begin
                if (out_pixel_x !== 0)
                    $fatal(1, "output row %0d started at x=%0d expected 0, no left border is implemented", row, out_pixel_x);
                for (i = 0; i < 512; i = i + 1) begin
                    if (out_pixel_x !== i)
                        $fatal(1, "output row %0d x got %0d expected %0d", row, out_pixel_x, i);
                    if (out_pixel_y !== row)
                        $fatal(1, "output x=%0d y got %0d expected %0d", i, out_pixel_y, row);
                    @(posedge clk);
                    #1;
                    n = n + 1;
                end
            end
            if ((out_pixel_x !== 0) || (out_pixel_y !== 0))
                $fatal(1, "the raster did not wrap to (0,0) after 512x480 pixels, got (%0d,%0d)",
                       out_pixel_x, out_pixel_y);
            if (n != 245760)
                $fatal(1, "walked %0d output pixels, expected 245760", n);
            $display("VIDEO raster is exactly 512x480 with no border, no blanking and no padding PASS");
        end
    endtask

    initial begin
        clk            = 1'b0;
        reset          = 1'b1;
        pixel_valid    = 1'b0;
        in_pixel_x     = 8'h00;
        in_pixel_y     = 8'h00;
        in_pixel_index = 4'h0;

        test_reset_initial;
        test_palette_64;
        test_frame_a;
        test_frame_b;
        test_frame_c;
        test_reset_mid_frame;
        test_read_pointer_free_running;
        test_stream_geometry;

        $display("PASS nes_video_scaler");
        $finish;
    end

    initial begin
        #20000000;
        $fatal(1, "global timeout");
    end

endmodule
