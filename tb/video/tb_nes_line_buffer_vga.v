`timescale 1ns/1ps

module tb_nes_line_buffer_vga;

    localparam integer MAX_LINES = 32;

    reg wr_clk;
    reg wr_reset;
    reg wr_ce;
    reg wr_pixel_valid;
    reg [7:0] wr_x;
    reg [3:0] wr_index;

    reg rd_clk;
    reg rd_reset;
    reg rd_ce;

    wire rep_toggle;
    wire rep_done;
    wire rep_valid;
    wire rep_start;
    wire [8:0] rep_x;
    wire [15:0] rep_rgb;

    wire nre_toggle;
    wire nre_done;
    wire nre_valid;
    wire nre_start;
    wire [8:0] nre_x;
    wire [15:0] nre_rgb;

    integer line_no;
    integer i;
    integer j;
    integer sim_cycles;
    integer conc_cycles;
    integer n_rep_starts;
    integer n_nre_starts;
    integer xw;
    integer tog;
    reg  bw;
    reg  lat_rep;
    reg  lat_nre;
    reg  lat_strict;
    time wr_done_time;
    reg  [15:0] want;
    reg  [8:0] hold_x;
    reg  [15:0] hold_rgb;
    reg         hold_valid;
    reg         hold_start;
    reg  [8:0]  nre_hold_x;
    reg  [15:0] nre_hold_rgb;
    reg         nre_hold_valid;
    reg         nre_hold_start;
    reg  rdbank_seen;
    reg  rdbank_prev;

    reg  [8:0]  md_x    [0:1];
    reg  [15:0] md_prev [0:1];
    integer     md_line [0:1];
    integer     md_pass [0:1];
    integer     md_done [0:1];

    reg        h_valid [0:1];
    reg        h_start [0:1];
    reg  [8:0] h_x     [0:1];
    reg  [15:0] h_rgb   [0:1];

    always #5 rd_clk = ~rd_clk;

    initial begin
        wr_clk = 1'b0;
        #2;
        forever #25 wr_clk = ~wr_clk;
    end

    nes_line_buffer_vga dut_rep (
        .wr_clk            (wr_clk),
        .wr_reset          (wr_reset),
        .wr_ce             (wr_ce),
        .wr_pixel_valid    (wr_pixel_valid),
        .wr_x              (wr_x),
        .wr_index          (wr_index),
        .line_ready_toggle (rep_toggle),
        .line_done         (rep_done),
        .rd_clk            (rd_clk),
        .rd_reset          (rd_reset),
        .rd_ce             (rd_ce),
        .frame_line_valid  (rep_valid),
        .line_read_start   (rep_start),
        .read_x            (rep_x),
        .read_rgb565       (rep_rgb)
    );

    nes_line_buffer_vga #(.REPEAT_LINE(0)) dut_norep (
        .wr_clk            (wr_clk),
        .wr_reset          (wr_reset),
        .wr_ce             (wr_ce),
        .wr_pixel_valid    (wr_pixel_valid),
        .wr_x              (wr_x),
        .wr_index          (wr_index),
        .line_ready_toggle (nre_toggle),
        .line_done         (nre_done),
        .rd_clk            (rd_clk),
        .rd_reset          (rd_reset),
        .rd_ce             (rd_ce),
        .frame_line_valid  (nre_valid),
        .line_read_start   (nre_start),
        .read_x            (nre_x),
        .read_rgb565       (nre_rgb)
    );

    function [3:0] pat_idx;
        input [8:0] x;
        input integer l;
        integer t;
        begin
            t = x + 7 * l + 3;
            pat_idx = t[3:0];
        end
    endfunction

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

    task wait_wr;
        input integer n;
        begin
            repeat (n) @(posedge wr_clk);
        end
    endtask

    task wait_rd;
        input integer n;
        begin
            repeat (n) @(posedge rd_clk);
            #2;
        end
    endtask

    task rd_ce_set;
        input v;
        begin
            @(posedge rd_clk);
            #2;
            rd_ce = v;
        end
    endtask

    task rd_reset_set;
        input v;
        begin
            @(posedge rd_clk);
            #2;
            rd_reset = v;
        end
    endtask

    task model_rearm;
        input integer inst;
        begin
            md_x[inst]    = 9'd0;
            md_prev[inst] = 16'h0000;
            md_line[inst] = 0;
            md_pass[inst] = 0;
            md_done[inst] = 0;
        end
    endtask

    task all_reset;
        begin
            wait_rd(1);
            wr_ce          = 1'b0;
            wr_pixel_valid = 1'b0;
            wr_x           = 8'd0;
            wr_index       = 4'd0;
            wr_reset       = 1'b1;
            rd_ce          = 1'b0;
            rd_reset       = 1'b1;
            line_no        = 0;
            conc_cycles    = 0;
            n_rep_starts   = 0;
            n_nre_starts   = 0;
            sim_cycles     = 0;
            lat_rep        = 1'b0;
            lat_nre        = 1'b0;
            lat_strict     = 1'b0;
            rdbank_seen    = 1'b0;
            rdbank_prev    = 1'b0;
            model_rearm(0);
            model_rearm(1);
            h_valid[0] = rep_valid;
            h_start[0] = rep_start;
            h_x[0]     = rep_x;
            h_rgb[0]   = rep_rgb;
            h_valid[1] = nre_valid;
            h_start[1] = nre_start;
            h_x[1]     = nre_x;
            h_rgb[1]   = nre_rgb;
            wait_wr(3);
            wait_rd(3);
            if (dut_rep.wr_bank !== 1'b0)
                $fatal(1, "LINBUF wr_reset did not home the write bank");
            if (dut_norep.wr_bank !== 1'b0)
                $fatal(1, "LINBUF wr_reset did not home the REPEAT_LINE=0 write bank");
            wr_reset = 1'b0;
            rd_reset = 1'b0;
        end
    endtask

    task rd_check;
        input integer inst;
        input        v;
        input        s;
        input [8:0]  x;
        input [15:0] rgb;
        begin
            if (v === 1'b1) begin
                if (md_line[inst] >= MAX_LINES)
                    $fatal(1, "LINBUF inst %0d scanned line %0d, no such line was written", inst, md_line[inst]);
                if (x !== md_x[inst])
                    $fatal(1, "LINBUF inst %0d read_x got %0d expected %0d while scanning line %0d",
                           inst, x, md_x[inst], md_line[inst]);
                if (s !== (x === 9'd0))
                    $fatal(1, "LINBUF inst %0d line_read_start got %0b at read_x %0d, expected %0b",
                           inst, s, x, (x === 9'd0));
                want = pal_ref(pat_idx(x[8:1], md_line[inst]));
                if (rgb !== want)
                    $fatal(1, "LINBUF inst %0d rgb565 at line %0d read_x %0d got %04h expected %04h",
                           inst, md_line[inst], x, rgb, want);
                if (x[0] === 1'b1) begin
                    if (rgb !== md_prev[inst])
                        $fatal(1, "LINBUF inst %0d broke the 2x horizontal copy at line %0d read_x %0d got %04h previous %04h",
                               inst, md_line[inst], x, rgb, md_prev[inst]);
                end else begin
                    md_prev[inst] = rgb;
                end
                if (s === 1'b1) begin
                    if (inst == 0) begin
                        n_rep_starts = n_rep_starts + 1;
                        if (md_pass[inst] == 0) begin
                            if (rdbank_seen === 1'b0) begin
                                if (dut_rep.rd_bank !== 1'b0)
                                    $fatal(1, "LINBUF the first read line after reset did not start on bank 0");
                                rdbank_seen = 1'b1;
                            end else begin
                                if (dut_rep.rd_bank !== (~rdbank_prev))
                                    $fatal(1, "LINBUF the read bank stayed %0b across two source lines, ping pong is broken", dut_rep.rd_bank);
                            end
                            rdbank_prev = dut_rep.rd_bank;
                        end
                    end else begin
                        n_nre_starts = n_nre_starts + 1;
                    end
                    if (lat_rep === 1'b1) begin
                        if (($time - wr_done_time) < 30)
                            $fatal(1, "LINBUF inst 0 read a line %0d ns after the write toggle, the 2 flip flop synchronizer is bypassed",
                                   $time - wr_done_time);
                        if ((lat_strict === 1'b1) && (($time - wr_done_time) > 60))
                            $fatal(1, "LINBUF inst 0 read a line %0d ns after the write toggle, expected 3 to 4 rd cycles", $time - wr_done_time);
                        lat_rep = 1'b0;
                    end
                    if (lat_nre === 1'b1) begin
                        if (($time - wr_done_time) < 30)
                            $fatal(1, "LINBUF inst 1 read a line %0d ns after the write toggle, the 2 flip flop synchronizer is bypassed",
                                   $time - wr_done_time);
                        lat_nre = 1'b0;
                    end
                end
                if ((wr_ce === 1'b1) && (wr_pixel_valid === 1'b1)) begin
                    if (inst == 0)
                        conc_cycles = conc_cycles + 1;
                end
                if (x === 9'd511) begin
                    md_x[inst] = 9'd0;
                    md_pass[inst] = md_pass[inst] + 1;
                    if (md_pass[inst] > (inst == 0 ? 1 : 0)) begin
                        md_pass[inst] = 0;
                        md_line[inst] = md_line[inst] + 1;
                        md_done[inst] = md_done[inst] + 1;
                    end
                end else begin
                    md_x[inst] = x + 9'd1;
                end
            end else begin
                if (s !== 1'b0)
                    $fatal(1, "LINBUF inst %0d raised line_read_start outside a valid line", inst);
                if (x !== 9'd0)
                    $fatal(1, "LINBUF inst %0d parked read_x at %0d while idle, expected 0", inst, x);
            end
        end
    endtask

    always @(posedge rd_clk) begin
        #1;
        if (rd_reset === 1'b0) begin
            if (rd_ce === 1'b1) begin
                rd_check(0, rep_valid, rep_start, rep_x, rep_rgb);
                rd_check(1, nre_valid, nre_start, nre_x, nre_rgb);
            end else begin
                if ((rep_valid !== h_valid[0]) || (rep_start !== h_start[0]) ||
                    (rep_x !== h_x[0]) || (rep_rgb !== h_rgb[0]))
                    $fatal(1, "LINBUF inst 0 moved while rd_ce was low: valid %0b/%0b start %0b/%0b x %0d/%0d rgb %04h/%04h",
                           rep_valid, h_valid[0], rep_start, h_start[0], rep_x, h_x[0], rep_rgb, h_rgb[0]);
                if ((nre_valid !== h_valid[1]) || (nre_start !== h_start[1]) ||
                    (nre_x !== h_x[1]) || (nre_rgb !== h_rgb[1]))
                    $fatal(1, "LINBUF inst 1 moved while rd_ce was low: valid %0b/%0b start %0b/%0b x %0d/%0d rgb %04h/%04h",
                           nre_valid, h_valid[1], nre_start, h_start[1], nre_x, h_x[1], nre_rgb, h_rgb[1]);
            end
        end else begin
            rdbank_seen = 1'b0;
        end
        h_valid[0] = rep_valid;
        h_start[0] = rep_start;
        h_x[0]     = rep_x;
        h_rgb[0]   = rep_rgb;
        h_valid[1] = nre_valid;
        h_start[1] = nre_start;
        h_x[1]     = nre_x;
        h_rgb[1]   = nre_rgb;
    end

    task wr_pixel;
        input [7:0] x;
        input [3:0] ci;
        input       pv;
        begin
            wr_x           = x;
            wr_index       = ci;
            wr_pixel_valid = pv;
            @(posedge wr_clk);
            #1;
            if (rep_done !== nre_done)
                $fatal(1, "LINBUF the two instances disagree on line_done at x=%0d", x);
            if (rep_toggle !== nre_toggle)
                $fatal(1, "LINBUF the two instances disagree on line_ready_toggle at x=%0d", x);
        end
    endtask

    task wr_line;
        input integer l;
        integer x;
        integer t0;
        begin
            wr_ce = 1'b1;
            t0    = rep_toggle;
            bw    = dut_rep.wr_bank;
            for (x = 0; x < 256; x = x + 1) begin
                wr_pixel(x[7:0], pat_idx(x[8:0], l), 1'b1);
                if (x == 255) begin
                    if (rep_done !== 1'b1)
                        $fatal(1, "LINBUF line %0d finished at x=255 without line_done", l);
                    if (rep_toggle !== (t0 ^ 1'b1))
                        $fatal(1, "LINBUF line %0d finished without flipping line_ready_toggle", l);
                end else begin
                    if (rep_done !== 1'b0)
                        $fatal(1, "LINBUF line %0d raised line_done at x=%0d, expected only x=255", l, x);
                    if (rep_toggle !== t0)
                        $fatal(1, "LINBUF line_ready_toggle moved at x=%0d of line %0d", x, l);
                end
            end
            if (dut_rep.wr_bank !== (~bw))
                $fatal(1, "LINBUF the write bank stayed %0b across line %0d, ping pong is broken", bw, l);
            wr_pixel_valid = 1'b0;
            wr_done_time   = $time;
            lat_rep        = 1'b1;
            lat_nre        = 1'b1;
            line_no        = line_no + 1;
        end
    endtask

    task drain;
        input integer expect_rep;
        input integer expect_nre;
        begin
            sim_cycles = 0;
            while ((md_done[0] < expect_rep) || (md_done[1] < expect_nre)) begin
                wait_rd(1);
                sim_cycles = sim_cycles + 1;
                if (sim_cycles > 20000)
                    $fatal(1, "LINBUF the read side did not reach %0d/%0d lines, it stalled at %0d/%0d",
                           expect_rep, expect_nre, md_done[0], md_done[1]);
            end
            wait_rd(30);
            if (md_done[0] !== expect_rep)
                $fatal(1, "LINBUF inst 0 delivered %0d lines, expected %0d", md_done[0], expect_rep);
            if (md_done[1] !== expect_nre)
                $fatal(1, "LINBUF inst 1 delivered %0d lines, expected %0d", md_done[1], expect_nre);
            if (rep_valid !== 1'b0 || rep_start !== 1'b0)
                $fatal(1, "LINBUF inst 0 kept scanning after the last line");
            if (nre_valid !== 1'b0 || nre_start !== 1'b0)
                $fatal(1, "LINBUF inst 1 kept scanning after the last line");
        end
    endtask

    task test_reset_contract;
        integer c;
        begin
            all_reset;
            rd_ce_set(1'b1);
            wait_rd(40);
            if (rep_done !== 1'b0 || rep_toggle !== 1'b0)
                $fatal(1, "LINBUF the write side raised a line pulse with no pixel written");
            if (rep_valid !== 1'b0 || rep_start !== 1'b0 || rep_x !== 9'd0 || rep_rgb !== 16'h0000)
                $fatal(1, "LINBUF the read side produced output with no line written");
            if (nre_valid !== 1'b0 || nre_start !== 1'b0)
                $fatal(1, "LINBUF the REPEAT_LINE=0 read side produced output with no line written");
            rd_ce_set(1'b0);
            wr_ce = 1'b1;
            for (c = 0; c < 12; c = c + 1) begin
                wr_pixel(8'd0, 4'd0, 1'b0);
                if (rep_done !== 1'b0 || rep_toggle !== 1'b0)
                    $fatal(1, "LINBUF an idle wr_ce cycle raised a line pulse");
            end
            wr_ce = 1'b0;
            for (c = 0; c < 6; c = c + 1) begin
                wr_pixel(8'd255, 4'd15, 1'b1);
                if (rep_done !== 1'b0 || rep_toggle !== 1'b0)
                    $fatal(1, "LINBUF wr_ce=0 still completed a line at x=255");
            end
            wr_ce = 1'b1;
            for (c = 0; c < 100; c = c + 1) begin
                wr_pixel(8'd0, pat_idx(c[8:0], 0), 1'b1);
                if (rep_valid !== 1'b0 || rep_start !== 1'b0)
                    $fatal(1, "LINBUF a gated write produced a read line");
                if (n_rep_starts != 0)
                    $fatal(1, "LINBUF a gated write produced %0d line starts", n_rep_starts);
            end
            wr_ce = 1'b0;
            wait_wr(4);
            if (rep_done !== 1'b0 || rep_toggle !== 1'b0)
                $fatal(1, "LINBUF a partial line survived without wr_reset");
            $display("LINBUF reset and wr_ce gating raise no line_done, no toggle and no read line PASS");
        end
    endtask

    task test_rd_ce_gate;
        integer c;
        integer lim;
        begin
            all_reset;
            wr_ce = 1'b1;
            for (c = 0; c < 100; c = c + 1)
                wr_pixel(c[7:0], pat_idx(c[8:0], 0), 1'b1);
            if (rep_done !== 1'b0 || rep_toggle !== 1'b0)
                $fatal(1, "LINBUF a 100 pixel partial line raised a line pulse");
            wr_ce = 1'b0;
            wr_reset = 1'b1;
            wait_wr(2);
            if (rep_done !== 1'b0 || rep_toggle !== 1'b0)
                $fatal(1, "LINBUF wr_reset did not drop the partial line");
            wr_reset = 1'b0;
            wr_ce    = 1'b1;
            wr_line(0);
            wr_ce = 1'b0;
            wait_rd(60);
            if (rep_valid !== 1'b0 || rep_start !== 1'b0)
                $fatal(1, "LINBUF rd_ce=0 let a completed line through");
            if (n_rep_starts != 0 || n_nre_starts != 0)
                $fatal(1, "LINBUF a line start appeared while rd_ce was low");
            rd_ce_set(1'b1);
            lim = 0;
            while (rep_x !== 9'd200) begin
                wait_rd(1);
                lim = lim + 1;
                if (lim > 4000)
                    $fatal(1, "LINBUF the read side never reached read_x=200");
            end
            rd_ce_set(1'b0);
            hold_valid     = rep_valid;
            hold_start     = rep_start;
            hold_x         = rep_x;
            hold_rgb       = rep_rgb;
            nre_hold_valid = nre_valid;
            nre_hold_start = nre_start;
            nre_hold_x     = nre_x;
            nre_hold_rgb   = nre_rgb;
            if (hold_valid !== 1'b1)
                $fatal(1, "LINBUF the read side was not scanning when the gate test froze it");
            if (nre_hold_valid !== 1'b1)
                $fatal(1, "LINBUF the REPEAT_LINE=0 read side was not scanning when the gate test froze it");
            for (c = 0; c < 12; c = c + 1) begin
                wait_rd(1);
                if ((rep_valid !== hold_valid) || (rep_start !== hold_start) ||
                    (rep_x !== hold_x) || (rep_rgb !== hold_rgb))
                    $fatal(1, "LINBUF inst 0 moved while rd_ce was low: valid %0b/%0b start %0b/%0b x %0d/%0d rgb %04h/%04h",
                           rep_valid, hold_valid, rep_start, hold_start, rep_x, hold_x, rep_rgb, hold_rgb);
                if ((nre_valid !== nre_hold_valid) || (nre_start !== nre_hold_start) ||
                    (nre_x !== nre_hold_x) || (nre_rgb !== nre_hold_rgb))
                    $fatal(1, "LINBUF inst 1 moved while rd_ce was low: valid %0b/%0b start %0b/%0b x %0d/%0d rgb %04h/%04h",
                           nre_valid, nre_hold_valid, nre_start, nre_hold_start,
                           nre_x, nre_hold_x, nre_rgb, nre_hold_rgb);
            end
            rd_ce_set(1'b1);
            drain(1, 1);
            if (n_rep_starts != 2)
                $fatal(1, "LINBUF inst 0 raised %0d line starts for one line, expected 2 passes", n_rep_starts);
            if (n_nre_starts != 1)
                $fatal(1, "LINBUF inst 1 raised %0d line starts for one line, expected 1 pass", n_nre_starts);
            $display("LINBUF rd_ce gates the whole read side and REPEAT_LINE replays one line as two passes PASS");
        end
    endtask

    task test_ping_pong;
        integer c;
        begin
            all_reset;
            lat_strict = 1'b1;
            rd_ce_set(1'b1);
            for (c = 0; c < 8; c = c + 1) begin
                if (c == 3) begin
                    wr_ce = 1'b0;
                    wait_wr(7);
                    wr_ce = 1'b1;
                end
                wr_line(line_no);
                if (c == 5) begin
                    wr_ce = 1'b0;
                    wait_wr(5);
                    wr_ce = 1'b1;
                end
            end
            wr_ce = 1'b0;
            drain(8, 8);
            if (n_rep_starts != 16)
                $fatal(1, "LINBUF inst 0 raised %0d line starts for 8 lines, expected 16", n_rep_starts);
            if (n_nre_starts != 8)
                $fatal(1, "LINBUF inst 1 raised %0d line starts for 8 lines, expected 8", n_nre_starts);
            if (conc_cycles < 3000)
                $fatal(1, "LINBUF the read and write sides overlapped for only %0d cycles, the concurrent check is void", conc_cycles);
            $display("LINBUF 8 concurrent lines ping pong in order, %0d write/read overlap cycles, no torn read PASS", conc_cycles);
        end
    endtask

    task test_rd_reset_mid_line;
        integer c;
        integer lim;
        begin
            all_reset;
            lat_strict = 1'b1;
            rd_ce_set(1'b1);
            wr_ce = 1'b1;
            wr_line(line_no);
            lim = 0;
            while ((md_done[0] < 1) || (md_done[1] < 1)) begin
                wait_rd(1);
                lim = lim + 1;
                if (lim > 4000)
                    $fatal(1, "LINBUF line 0 was never delivered");
            end
            wr_line(line_no);
            lim = 0;
            while (rep_start !== 1'b1) begin
                wait_rd(1);
                lim = lim + 1;
                if (lim > 4000)
                    $fatal(1, "LINBUF line 1 never started");
            end
            wait_rd(150);
            if (rep_valid !== 1'b1)
                $fatal(1, "LINBUF the read side stopped before the mid line reset");
            if (md_done[0] !== 1 || md_done[1] !== 1)
                $fatal(1, "LINBUF the mid line reset landed on a pass boundary");
            wr_ce = 1'b0;
            rd_reset_set(1'b1);
            wait_rd(3);
            if (rep_valid !== 1'b0 || rep_start !== 1'b0 || rep_x !== 9'd0 || rep_rgb !== 16'h0000)
                $fatal(1, "LINBUF rd_reset did not clear the read side");
            if (nre_valid !== 1'b0 || nre_start !== 1'b0 || nre_x !== 9'd0 || nre_rgb !== 16'h0000)
                $fatal(1, "LINBUF rd_reset did not clear the REPEAT_LINE=0 read side");
            model_rearm(0);
            model_rearm(1);
            md_line[0] = 2;
            md_line[1] = 2;
            wait_rd(200);
            if (rep_valid !== 1'b0 || rep_start !== 1'b0)
                $fatal(1, "LINBUF the read side resumed on its own after rd_reset");
            if (n_rep_starts != 3)
                $fatal(1, "LINBUF inst 0 raised %0d line starts before the mid line reset, expected 3", n_rep_starts);
            if (n_nre_starts != 2)
                $fatal(1, "LINBUF inst 1 raised %0d line starts before the mid line reset, expected 2", n_nre_starts);
            rd_reset_set(1'b0);
            wr_ce = 1'b1;
            for (c = 0; c < 4; c = c + 1)
                wr_line(line_no);
            wr_ce = 1'b0;
            drain(4, 4);
            if (n_rep_starts != 11)
                $fatal(1, "LINBUF inst 0 raised %0d line starts in total, expected 11", n_rep_starts);
            if (n_nre_starts != 6)
                $fatal(1, "LINBUF inst 1 raised %0d line starts in total, expected 6", n_nre_starts);
            $display("LINBUF rd_reset mid pass drops the partial line, homes the bank and resumes on the next toggle PASS");
        end
    endtask

    initial begin
        wr_clk         = 1'b0;
        wr_reset       = 1'b1;
        wr_ce          = 1'b0;
        wr_pixel_valid = 1'b0;
        wr_x           = 8'd0;
        wr_index       = 4'd0;
        rd_clk         = 1'b0;
        rd_reset       = 1'b1;
        rd_ce          = 1'b0;
        line_no        = 0;
        n_rep_starts   = 0;
        n_nre_starts   = 0;
        conc_cycles    = 0;
        sim_cycles     = 0;
        lat_rep        = 1'b0;
        lat_nre        = 1'b0;
        rdbank_seen    = 1'b0;
        rdbank_prev    = 1'b0;
        h_valid[0]     = 1'b0;
        h_start[0]     = 1'b0;
        h_x[0]         = 9'd0;
        h_rgb[0]       = 16'h0000;
        h_valid[1]     = 1'b0;
        h_start[1]     = 1'b0;
        h_x[1]         = 9'd0;
        h_rgb[1]       = 16'h0000;
        model_rearm(0);
        model_rearm(1);

        test_reset_contract;
        test_rd_ce_gate;
        test_ping_pong;
        test_rd_reset_mid_line;

        $display("PASS nes_line_buffer_vga");
        $finish;
    end

    initial begin
        #20000000;
        $fatal(1, "LINBUF global timeout");
    end

endmodule
