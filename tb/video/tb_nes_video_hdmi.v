`timescale 1ns/1ps

// Gate testbench for nes_video_hdmi (720x480p60, CEA-861 480p).
//
// Structural assertions run on every ce tick of every output frame:
//   * de equals the CEA-861 480p active window recomputed from hcount/vcount
//   * hsync is low on exactly [0,62) of each line and high elsewhere (negative
//     polarity), vsync is low on exactly [0,6) of each frame and high elsewhere
//   * the bus is BLANK_RGB565 whenever de is low
//   * every de run on a scanline is exactly 720 dots wide
//   * the raster holds completely still on every cycle where ce is low
//   * one output frame is exactly H_TOTAL*V_TOTAL ce ticks and 480 active lines
//   * dut.src_col equals the rational reference column of the presented dot and
//     dut.mem_read_addr equals the reference address of the next dot
//   * the horizontal accumulator stays inside 0..719 and src_col inside 0..255
// Content assertions run on whole frames whose buffer content is known:
//   * every RGB565 equals the reference for the mapped (column,row)
//   * consecutive output line pairs are identical, i.e. exact 2:1 vertical
//   * every source column is emitted 2 or 3 times, and 256 columns account for
//     exactly 720 dots (the 45/16 rational law)
//
// The reference column map is derived independently of the RTL: output dot n
// reads source column floor(n*256/720).

module tb_nes_video_hdmi;

    localparam BLANK    = 16'h0000;
    localparam H_TOT    = 858;
    localparam V_TOT    = 525;
    localparam H_A0     = 122;
    localparam H_A1     = 842;
    localparam V_A0     = 36;
    localparam V_A1     = 516;
    localparam H_S0     = 0;
    localparam H_S1     = 62;
    localparam V_S0     = 0;
    localparam V_S1     = 6;
    localparam P0_XOR   = 16'h5AA5;
    localparam P1_XOR   = 16'h3C3C;

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
    integer k;
    integer ox;
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
    integer hsync_low_dots;
    integer vsync_low_lines;
    reg [15:0] xor_sel;

    reg [15:0] line_sig_r;
    reg [15:0] sig_prev_r;
    reg [31:0] frame_sig_r;
    reg [31:0] prev_frame_sig_r;
    reg [31:0] sig0_r;
    reg [31:0] sig1_r;

    integer col_hit [0:255];
    integer ref_col [0:719];

    // Both clocks are tied to the bench clock, both resets to the bench reset,
    // so every assertion runs in the single-clock regime it was written for.
    nes_video_hdmi dut (
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

    task build_tables;
        integer j;
        begin
            for (j = 0; j < 720; j = j + 1) ref_col[j] = (j * 256) / 720;
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
                hsync_low_dots = 0;
                vsync_low_lines = 0;
                line_sig_r   = 16'h0000;
                sig_prev_r   = 16'h0000;
                frame_sig_r  = 32'h0000_0000;
                if (reset_seen >= 2) begin
                    if (hcount !== 11'd0) err("RESET_HCOUNT", hcount, 0);
                    if (vcount !== 11'd0) err("RESET_VCOUNT", vcount, 0);
                    if (de !== 1'b0) err("RESET_DE", de, 0);
                    if (hsync !== 1'b0) err("RESET_HSYNC", hsync, 0);
                    if (vsync !== 1'b0) err("RESET_VSYNC", vsync, 0);
                    if (rgb565 !== BLANK) err("RESET_RGB", rgb565, 0);
                    if (pixel_x !== 11'd0) err("RESET_PIXEL_X", pixel_x, 0);
                    if (pixel_y !== 11'd0) err("RESET_PIXEL_Y", pixel_y, 0);
                    if (frame_pulse !== 1'b0) err("RESET_FRAME", frame_pulse, 0);
                    if (dut.h_acc !== 11'd0) err("RESET_HACC", dut.h_acc, 0);
                    if (dut.src_col !== 8'd0) err("RESET_SRCCOL", dut.src_col, 0);
                end
            end else begin
                reset_seen = 0;
                if (in_line_ready) in_lines = in_lines + 1;
                if (in_frame_ready) begin
                    if (in_lines !== 240) err("IN_LINE_COUNT", in_lines, 240);
                    in_lines = 0;
                end

                if (hcount > (H_TOT - 1)) err("H_RANGE", hcount, 0);
                if (vcount > (V_TOT - 1)) err("V_RANGE", vcount, 0);
                if (dut.h_acc > 11'd719) err("HACC_RANGE", dut.h_acc, 0);
                if (dut.src_col > 8'd255) err("SRCCOL_RANGE", dut.src_col, 0);

                // Sync windows and polarity, recomputed from hcount/vcount.
                if ((hcount >= H_S0) && (hcount < H_S1)) begin
                    if (hsync !== 1'b0) err("HSYNC_LOW_WINDOW", hcount, hsync);
                    hsync_low_dots = hsync_low_dots + 1;
                end else begin
                    if (hsync !== 1'b1) err("HSYNC_HIGH_OUTSIDE", hcount, hsync);
                end
                if ((vcount >= V_S0) && (vcount < V_S1)) begin
                    if (vsync !== 1'b0) err("VSYNC_LOW_WINDOW", vcount, vsync);
                    if (hcount === 11'd0) vsync_low_lines = vsync_low_lines + 1;
                end else begin
                    if (vsync !== 1'b1) err("VSYNC_HIGH_OUTSIDE", vcount, vsync);
                end

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

                if (de) begin
                    ox = pixel_x;
                    if (ox === 0) begin
                        line_px = 1;
                        line_sig_r = 16'h0000;
                    end else begin
                        line_px = line_px + 1;
                    end

                    exp_col = ref_col[ox];
                    exp_row = pixel_y >> 1;

                    if (dut.src_col !== exp_col[7:0]) err("SRC_COL", ox, dut.src_col);
                    if (dut.src_row !== exp_row[7:0]) err("SRC_ROW", pixel_y, dut.src_row);

                    if (ox < 719) begin
                        if (dut.mem_read_addr !== {exp_row[7:0], ref_col[ox + 1][7:0]})
                            err("MEM_READ_ADDR", ox, dut.mem_read_addr);
                    end else begin
                        if (dut.mem_read_addr[7:0] !== 8'd0) err("MEM_READ_ADDR_RESET", ox, dut.mem_read_addr);
                    end

                    col_hit[exp_col] = col_hit[exp_col] + 1;

                    if (checking) begin
                        if (rgb565 !== ({exp_col[7:0], exp_row[7:0]} ^ xor_sel))
                            err("PIXEL_VALUE", ox, rgb565);
                        line_sig_r  = line_sig_r + ({6'd0, rgb565[9:0]} * 16'd7) + {10'd0, pixel_x[9:0]};
                        frame_sig_r = frame_sig_r + ({16'd0, rgb565} * 32'd7)
                                              + ({16'd0, pixel_x} * 32'd1000003);
                    end

                    if (ox === 719) begin
                        if (line_px !== 720) err("LINE_WIDTH", line_px, pixel_y);
                        for (k = 0; k < 256; k = k + 1) begin
                            if (col_hit[k] < 2 || col_hit[k] > 3) err("COL_SPAN", k, col_hit[k]);
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
                    if (hsync_low_dots !== (H_S1 * V_TOT)) err("FRAME_HSYNC_DOTS", hsync_low_dots, H_S1 * V_TOT);
                    if (vsync_low_lines !== V_S1) err("FRAME_VSYNC_LINES", vsync_low_lines, V_S1);
                    if (full_frame) begin
                        if (act_lines !== 480) err("FRAME_ACTIVE_LINES", act_lines, 480);
                        if (have_prev_frame_sig && (frame_sig_r !== prev_frame_sig_r))
                            err("FRAME_UNSTABLE", frames, 0);
                        if (have_prev_frame_sig) frames_stable = frames_stable + 1;
                        prev_frame_sig_r  = frame_sig_r;
                        have_prev_frame_sig = 1;
                        frames_checked = frames_checked + 1;
                        if (checking && (xor_sel === P0_XOR)) sig0_r = frame_sig_r;
                        else if (checking) sig1_r = frame_sig_r;
                    end else begin
                        if ((act_lines !== 0) && (act_lines !== 480)) err("FRAME_ACTIVE_LINES", act_lines, 480);
                    end
                    frame_sig_r = 32'h0000_0000;
                    frame_ticks = 0;
                    act_lines   = 0;
                    hsync_low_dots = 0;
                    vsync_low_lines = 0;
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
        ox         = 0;
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
        hsync_low_dots = 0;
        vsync_low_lines = 0;
        xor_sel    = P0_XOR;
        line_sig_r  = 16'h0000;
        sig_prev_r  = 16'h0000;
        frame_sig_r = 32'h0000_0000;
        prev_frame_sig_r = 32'h0000_0000;
        sig0_r = 32'h0000_0000;
        sig1_r = 32'h0000_0000;

        for (k = 0; k < 256; k = k + 1) col_hit[k] = 0;
        build_tables;

        repeat (8) @(posedge clk);
        @(negedge clk);
        reset = 1'b0;

        write_frame(P0_XOR);
        @(posedge clk);
        #1;
        checking = 1;
        xor_sel  = P0_XOR;

        wait_frames(4);

        repeat (20) @(posedge clk);
        @(negedge clk);
        reset = 1'b1;
        repeat (8) @(posedge clk);
        @(negedge clk);
        reset = 1'b0;

        checking = 0;
        xor_sel  = P1_XOR;
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

        if (frames_checked < 5) err("TOO_FEW_CHECKED_FRAMES", frames_checked, 5);
        if (frames_stable < 2) err("TOO_FEW_STABLE_FRAMES", frames_stable, 2);
        if (sig0_r === sig1_r) err("SIGNATURE_NOT_DISCRIMINATING", sig0_r, sig1_r);
        if (sig0_r === 32'h0000_0000) err("SIGNATURE_ZERO", sig0_r, 0);
        if (sig1_r === 32'h0000_0000) err("SIGNATURE_ZERO", sig1_r, 0);

        if (errors != 0) begin
            $display("FAIL nes_video_hdmi with %0d violations", errors);
            $fatal(1, "nes_video_hdmi tb failed");
        end

        $display("PASS nes_video_hdmi exactly 720 active dots on every line, exactly 480 lines per frame, CEA-861 480p raster");
        $finish;
    end

    initial begin
        #400000000;
        $fatal(1, "global timeout");
    end

endmodule
