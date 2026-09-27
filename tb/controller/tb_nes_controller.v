`timescale 1ns/1ps

module tb_nes_controller;

    reg         clk;
    reg         reset;
    reg         latch_strobe;
    reg         read_strobe;
    reg         read_select;
    reg  [7:0]  buttons;
    reg  [7:0]  buttons2;

    wire        bit_tie;
    wire [7:0]  byte_tie;
    wire [7:0]  sr1_tie;
    wire [7:0]  sr2_tie;
    wire [7:0]  lat1_tie;
    wire [7:0]  lat2_tie;
    wire [3:0]  cnt1_tie;
    wire [3:0]  cnt2_tie;
    wire [7:0]  selsr_tie;
    wire [7:0]  sellat_tie;
    wire [3:0]  selcnt_tie;
    wire        past8_tie;

    wire        bit_hold;
    wire [7:0]  byte_hold;
    wire [7:0]  sr1_hold;
    wire [3:0]  cnt1_hold;
    wire        past8_hold;

    wire        bit_zero;
    wire [7:0]  byte_zero;
    wire [7:0]  sr1_zero;
    wire [3:0]  cnt1_zero;
    wire        past8_zero;

    integer     combo;
    integer     idx;
    integer     extra_reads;
    integer     read_cycles;
    reg   [7:0] word_tie;
    reg   [7:0] word_hold;
    reg   [7:0] word_zero;
    reg   [7:0] mask;
    reg         b_tie;
    reg         b_hold;
    reg         b_zero;

    always #5 clk = ~clk;

    nes_controller #(.EXTRA_READ(2'd0)) dut (
        .clk(clk),
        .reset(reset),
        .latch_strobe(latch_strobe),
        .read_strobe(read_strobe),
        .read_select(read_select),
        .buttons(buttons),
        .buttons2(buttons2),
        .data_bit(bit_tie),
        .data_out(byte_tie),
        .dbg_sr1(sr1_tie),
        .dbg_sr2(sr2_tie),
        .dbg_latch1(lat1_tie),
        .dbg_latch2(lat2_tie),
        .dbg_cnt1(cnt1_tie),
        .dbg_cnt2(cnt2_tie),
        .dbg_selected_sr(selsr_tie),
        .dbg_selected_latch(sellat_tie),
        .dbg_selected_cnt(selcnt_tie),
        .dbg_past8(past8_tie)
    );

    nes_controller #(.EXTRA_READ(2'd1)) dut_hold (
        .clk(clk),
        .reset(reset),
        .latch_strobe(latch_strobe),
        .read_strobe(read_strobe),
        .read_select(read_select),
        .buttons(buttons),
        .buttons2(buttons2),
        .data_bit(bit_hold),
        .data_out(byte_hold),
        .dbg_sr1(sr1_hold),
        .dbg_sr2(),
        .dbg_latch1(),
        .dbg_latch2(),
        .dbg_cnt1(cnt1_hold),
        .dbg_cnt2(),
        .dbg_selected_sr(),
        .dbg_selected_latch(),
        .dbg_selected_cnt(),
        .dbg_past8(past8_hold)
    );

    nes_controller #(.EXTRA_READ(2'd2)) dut_zero (
        .clk(clk),
        .reset(reset),
        .latch_strobe(latch_strobe),
        .read_strobe(read_strobe),
        .read_select(read_select),
        .buttons(buttons),
        .buttons2(buttons2),
        .data_bit(bit_zero),
        .data_out(byte_zero),
        .dbg_sr1(sr1_zero),
        .dbg_sr2(),
        .dbg_latch1(),
        .dbg_latch2(),
        .dbg_cnt1(cnt1_zero),
        .dbg_cnt2(),
        .dbg_selected_sr(),
        .dbg_selected_latch(),
        .dbg_selected_cnt(),
        .dbg_past8(past8_zero)
    );

    task apply_reset;
        begin
            latch_strobe = 1'b0;
            read_strobe  = 1'b0;
            read_select  = 1'b0;
            buttons      = 8'h00;
            buttons2     = 8'h00;
            reset        = 1'b1;
            repeat (3) @(posedge clk);
            #1 reset = 1'b0;
            @(posedge clk);
            #1;
        end
    endtask

    task hold_latch;
        input integer cycles;
        begin
            latch_strobe = 1'b1;
            repeat (cycles) @(posedge clk);
            #1 latch_strobe = 1'b0;
            @(posedge clk);
            #1;
        end
    endtask

    task sample_read;
        input  sel;
        output o_tie;
        output o_hold;
        output o_zero;
        begin
            read_select = sel;
            read_strobe = 1'b1;
            #1;
            o_tie  = bit_tie;
            o_hold = bit_hold;
            o_zero = bit_zero;
            if (byte_tie !== {7'b0, o_tie})
                $fatal(1, "tie data_out got %02h expected %02h", byte_tie, {7'b0, o_tie});
            if (byte_hold !== {7'b0, o_hold})
                $fatal(1, "hold data_out got %02h expected %02h", byte_hold, {7'b0, o_hold});
            if (byte_zero !== {7'b0, o_zero})
                $fatal(1, "zero data_out got %02h expected %02h", byte_zero, {7'b0, o_zero});
            @(posedge clk);
            #1;
            read_strobe = 1'b0;
            @(posedge clk);
            #1;
        end
    endtask

    task read8;
        input        sel;
        input [7:0]  expected;
        input integer tag;
        output [7:0] w_tie;
        output [7:0] w_hold;
        output [7:0] w_zero;
        integer r;
        begin
            w_tie  = 8'h00;
            w_hold = 8'h00;
            w_zero = 8'h00;
            for (r = 0; r < 8; r = r + 1) begin
                sample_read(sel, b_tie, b_hold, b_zero);
                w_tie[r]  = b_tie;
                w_hold[r] = b_hold;
                w_zero[r] = b_zero;
            end
            if (w_tie !== expected)
                $fatal(1, "tag %0d port %0d: tie word got %02h expected %02h",
                       tag, sel, w_tie, expected);
            if (w_hold !== expected)
                $fatal(1, "tag %0d port %0d: hold word got %02h expected %02h",
                       tag, sel, w_hold, expected);
            if (w_zero !== expected)
                $fatal(1, "tag %0d port %0d: zero word got %02h expected %02h",
                       tag, sel, w_zero, expected);
        end
    endtask

    task read8_port0;
        input [7:0]  expected;
        input integer tag;
        begin
            read8(1'b0, expected, tag, word_tie, word_hold, word_zero);
        end
    endtask

    task read8_port1;
        input [7:0]  expected;
        input integer tag;
        begin
            read8(1'b1, expected, tag, word_tie, word_hold, word_zero);
        end
    endtask

    task read8_past8_tie;
        input integer tag;
        integer r;
        begin
            for (r = 0; r < 8; r = r + 1) begin
                sample_read(1'b0, b_tie, b_hold, b_zero);
                if (b_tie !== 1'b1)
                    $fatal(1, "tag %0d: tie read %0d past 8 got %b expected 1", tag, r, b_tie);
            end
        end
    endtask

    task read_bits;
        input        sel;
        input integer n;
        input [7:0]  expected;
        input integer tag;
        integer r;
        begin
            for (r = 0; r < n; r = r + 1) begin
                sample_read(sel, b_tie, b_hold, b_zero);
                if (b_tie !== expected[r])
                    $fatal(1, "tag %0d port %0d: read %0d got %b expected %b",
                           tag, sel, r, b_tie, expected[r]);
            end
        end
    endtask

    task check_idle_state;
        input [8*40-1:0] name;
        begin
            if (sr1_tie !== 8'h00 || sr2_tie !== 8'h00)
                $fatal(1, "%0s: shift registers not zero sr1=%02h sr2=%02h", name, sr1_tie, sr2_tie);
            if (lat1_tie !== 8'h00 || lat2_tie !== 8'h00)
                $fatal(1, "%0s: parallel load registers not zero", name);
            if (cnt1_tie !== 4'd0 || cnt2_tie !== 4'd0)
                $fatal(1, "%0s: counters not zero cnt1=%0d cnt2=%0d", name, cnt1_tie, cnt2_tie);
            if (past8_tie !== 1'b0)
                $fatal(1, "%0s: dbg_past8 is high", name);
        end
    endtask

    task test_reset;
        begin
            apply_reset;
            check_idle_state("reset idle");
            if (bit_tie !== 1'b0 || bit_hold !== 1'b0 || bit_zero !== 1'b0)
                $fatal(1, "reset data_bit is not zero on all three instances");
            if (byte_tie !== 8'h00 || byte_hold !== 8'h00 || byte_zero !== 8'h00)
                $fatal(1, "reset data_out is not zero on all three instances");

            buttons  = 8'hFF;
            buttons2 = 8'h5A;
            #1;
            if (bit_tie !== 1'b0)
                $fatal(1, "a low strobe must not let data follow the live buttons");
            if (sr1_tie !== 8'h00)
                $fatal(1, "reset did not clear the shift register");

            reset = 1'b1;
            #1;
            if (bit_tie !== 1'b0 || cnt1_tie !== 4'd0 || sr1_tie !== 8'h00)
                $fatal(1, "reset is not asynchronous");
            reset = 1'b0;
            #1;
            if (bit_tie !== 1'b0)
                $fatal(1, "state did not stay cleared after reset release");

            hold_latch(1);
            if (lat1_tie !== 8'hFF || lat2_tie !== 8'h5A)
                $fatal(1, "post-reset latch did not capture the buttons");
            $display("CONTROLLER reset values and asynchronous clear PASS");
        end
    endtask

    task test_all_256_combinations;
        begin
            for (combo = 0; combo < 256; combo = combo + 1) begin
                buttons  = combo[7:0];
                buttons2 = ~combo[7:0];
                hold_latch(1);
                if (lat1_tie !== combo[7:0] || lat2_tie !== ~combo[7:0])
                    $fatal(1, "combo %0d: parallel load got %02h/%02h expected %02h/%02h",
                           combo, lat1_tie, lat2_tie, combo[7:0], ~combo[7:0]);
                if (sr1_tie !== combo[7:0] || sr2_tie !== ~combo[7:0])
                    $fatal(1, "combo %0d: shift register load got %02h/%02h",
                           combo, sr1_tie, sr2_tie);
                if (cnt1_tie !== 4'd0 || cnt2_tie !== 4'd0 || past8_tie !== 1'b0)
                    $fatal(1, "combo %0d: the strobe did not clear the counters", combo);
                read8_port0(combo[7:0], combo);
                if (cnt1_tie !== 4'd8 || past8_tie !== 1'b1)
                    $fatal(1, "combo %0d: port 1 count got %0d past8=%b",
                           combo, cnt1_tie, past8_tie);
                if (cnt2_tie !== 4'd0)
                    $fatal(1, "combo %0d: reading port 1 advanced the port 2 counter", combo);
                read8_port1(~combo[7:0], combo);
                if (cnt2_tie !== 4'd8 || past8_tie !== 1'b1)
                    $fatal(1, "combo %0d: port 2 count got %0d past8=%b",
                           combo, cnt2_tie, past8_tie);
            end
            $display("CONTROLLER all 256 button combinations on both ports PASS");
        end
    endtask

    task test_bit_order;
        begin
            apply_reset;
            for (idx = 0; idx < 8; idx = idx + 1) begin
                buttons  = 8'h01 << idx;
                buttons2 = 8'h00;
                hold_latch(1);
                for (extra_reads = 0; extra_reads < 8; extra_reads = extra_reads + 1) begin
                    sample_read(1'b0, b_tie, b_hold, b_zero);
                    if (b_tie !== ((extra_reads == idx) ? 1'b1 : 1'b0))
                        $fatal(1, "button bit %0d: read %0d got %b expected %b",
                               idx, extra_reads, b_tie, (extra_reads == idx) ? 1'b1 : 1'b0);
                    if (b_hold !== b_tie || b_zero !== b_tie)
                        $fatal(1, "button bit %0d: the three EXTRA_READ modes disagree on read %0d",
                               idx, extra_reads);
                end
            end
            buttons  = 8'h00;
            buttons2 = 8'h00;
            $display("CONTROLLER serial order A,B,Select,Start,Up,Down,Left,Right PASS");
        end
    endtask

    task test_strobe_reload;
        begin
            apply_reset;
            buttons  = 8'hFF;
            buttons2 = 8'hFF;
            hold_latch(1);
            read_bits(1'b0, 3, 8'h07, 400);
            if (cnt1_tie !== 4'd3)
                $fatal(1, "partial read count got %0d expected 3", cnt1_tie);
            buttons  = 8'h00;
            buttons2 = 8'h00;
            hold_latch(1);
            if (cnt1_tie !== 4'd0 || cnt2_tie !== 4'd0)
                $fatal(1, "re-latch did not clear the counters cnt1=%0d cnt2=%0d",
                       cnt1_tie, cnt2_tie);
            read8_port0(8'h00, 401);
            read8_port1(8'h00, 401);

            buttons  = 8'h0F;
            buttons2 = 8'hF0;
            hold_latch(1);
            read_bits(1'b0, 2, 8'h03, 402);
            hold_latch(1);
            if (sr1_tie !== 8'h0F)
                $fatal(1, "re-latch did not reload the shift register got %02h", sr1_tie);
            read8_port0(8'h0F, 402);
            read8_port1(8'hF0, 402);

            buttons  = 8'h00;
            buttons2 = 8'h81;
            latch_strobe = 1'b1;
            read_select  = 1'b0;
            @(posedge clk);
            #1;
            buttons = 8'h01;
            #1;
            if (bit_tie !== 1'b1)
                $fatal(1, "data does not follow the live buttons while the strobe is high");
            @(posedge clk);
            #1;
            if (sr1_tie !== 8'h01 || lat1_tie !== 8'h01)
                $fatal(1, "parallel load is not level sensitive sr=%02h lat=%02h",
                       sr1_tie, lat1_tie);
            buttons = 8'h00;
            #1;
            if (bit_tie !== 1'b0)
                $fatal(1, "data did not follow the buttons back to released");
            if (sr1_tie !== 8'h01 || lat1_tie !== 8'h01)
                $fatal(1, "the parallel register changed without a clock edge");
            if (sr2_tie !== 8'h81 || lat2_tie !== 8'h81)
                $fatal(1, "port 2 was not latched by the shared strobe");
            for (read_cycles = 0; read_cycles < 5; read_cycles = read_cycles + 1) begin
                buttons = (read_cycles[0]) ? 8'h01 : 8'h00;
                sample_read(1'b0, b_tie, b_hold, b_zero);
                if (b_tie !== buttons[0])
                    $fatal(1, "read %0d under a high strobe got %b expected %b",
                           read_cycles, b_tie, buttons[0]);
                if (cnt1_tie !== 4'd0)
                    $fatal(1, "a read under a high strobe advanced the counter to %0d", cnt1_tie);
                if (sr1_tie !== buttons)
                    $fatal(1, "a read under a high strobe disturbed the parallel load sr=%02h",
                           sr1_tie);
                if (lat1_tie !== buttons)
                    $fatal(1, "a read under a high strobe disturbed the parallel latch lat=%02h",
                           lat1_tie);
            end
            buttons = 8'hA5;
            @(posedge clk);
            #1 latch_strobe = 1'b0;
            @(posedge clk);
            #1;
            if (sr1_tie !== 8'hA5)
                $fatal(1, "releasing the strobe did not freeze the last parallel load got %02h",
                       sr1_tie);
            read8_port0(8'hA5, 403);
            read8_port1(8'h81, 403);
            $display("CONTROLLER strobe reload, level-sensitive latch and shared $4016/$4017 strobe PASS");
        end
    endtask

    task test_snapshot_semantics;
        begin
            apply_reset;
            buttons  = 8'h00;
            buttons2 = 8'h00;
            hold_latch(1);
            buttons  = 8'hFF;
            buttons2 = 8'hFF;
            #1;
            if (bit_tie !== 1'b0)
                $fatal(1, "data followed the live buttons without a strobe");
            read8_port0(8'h00, 501);
            read8_port1(8'h00, 501);
            buttons  = 8'h00;
            buttons2 = 8'h00;
            $display("CONTROLLER reads return the latched snapshot, not the live buttons PASS");
        end
    endtask

    task test_after_eight_reads;
        begin
            apply_reset;
            buttons  = 8'h02;
            buttons2 = 8'h00;
            hold_latch(1);
            read8_port0(8'h02, 601);
            if (sr1_tie !== 8'hFF || sr1_hold !== 8'h00 || sr1_zero !== 8'h00)
                $fatal(1, "post-8 shift register state got tie=%02h hold=%02h zero=%02h",
                       sr1_tie, sr1_hold, sr1_zero);
            if (past8_tie !== 1'b1 || past8_hold !== 1'b1 || past8_zero !== 1'b1)
                $fatal(1, "dbg_past8 did not assert after 8 reads");
            for (extra_reads = 0; extra_reads < 12; extra_reads = extra_reads + 1) begin
                sample_read(1'b0, b_tie, b_hold, b_zero);
                if (b_tie !== 1'b1)
                    $fatal(1, "EXTRA_READ=0 read %0d past 8 got %b expected 1", extra_reads, b_tie);
                if (b_hold !== 1'b0)
                    $fatal(1, "EXTRA_READ=1 read %0d past 8 got %b expected 0", extra_reads, b_hold);
                if (b_zero !== 1'b0)
                    $fatal(1, "EXTRA_READ=2 read %0d past 8 got %b expected 0", extra_reads, b_zero);
            end
            if (cnt1_tie !== 4'd9 || cnt1_hold !== 4'd9 || cnt1_zero !== 4'd9)
                $fatal(1, "the read counter did not saturate at 9: %0d/%0d/%0d",
                       cnt1_tie, cnt1_hold, cnt1_zero);

            buttons = 8'h80;
            hold_latch(1);
            read8_port0(8'h80, 602);
            for (extra_reads = 0; extra_reads < 6; extra_reads = extra_reads + 1) begin
                sample_read(1'b0, b_tie, b_hold, b_zero);
                if (b_tie !== 1'b1)
                    $fatal(1, "EXTRA_READ=0 bit7=1 read %0d past 8 got %b", extra_reads, b_tie);
                if (b_hold !== 1'b1)
                    $fatal(1, "EXTRA_READ=1 bit7=1 read %0d past 8 got %b expected 1",
                           extra_reads, b_hold);
                if (b_zero !== 1'b0)
                    $fatal(1, "EXTRA_READ=2 bit7=1 read %0d past 8 got %b expected 0",
                           extra_reads, b_zero);
            end

            buttons = 8'hFF;
            hold_latch(1);
            read8_port0(8'hFF, 603);
            for (extra_reads = 0; extra_reads < 4; extra_reads = extra_reads + 1) begin
                sample_read(1'b0, b_tie, b_hold, b_zero);
                if (b_tie !== 1'b1 || b_hold !== 1'b1 || b_zero !== 1'b0)
                    $fatal(1, "0xFF past 8 got tie=%b hold=%b zero=%b expected 1/1/0",
                           b_tie, b_hold, b_zero);
            end

            buttons = 8'h00;
            hold_latch(1);
            read8_port0(8'h00, 604);
            for (extra_reads = 0; extra_reads < 4; extra_reads = extra_reads + 1) begin
                sample_read(1'b0, b_tie, b_hold, b_zero);
                if (b_tie !== 1'b1 || b_hold !== 1'b0 || b_zero !== 1'b0)
                    $fatal(1, "0x00 past 8 got tie=%b hold=%b zero=%b expected 1/0/0",
                           b_tie, b_hold, b_zero);
            end

            buttons = 8'h3C;
            hold_latch(1);
            read8_port0(8'h3C, 605);
            read8_past8_tie(605);
            hold_latch(1);
            read8_port0(8'h3C, 606);
            if (cnt1_tie !== 4'd8 || past8_tie !== 1'b1)
                $fatal(1, "a re-latch after going past 8 did not restore a clean read window");
            $display("CONTROLLER read-9-and-beyond strategies for all three EXTRA_READ modes PASS");
        end
    endtask

    task test_dual_port;
        begin
            apply_reset;
            buttons  = 8'h0F;
            buttons2 = 8'hF0;
            hold_latch(1);
            for (idx = 0; idx < 8; idx = idx + 1) begin
                mask = 8'h0F;
                sample_read(1'b0, b_tie, b_hold, b_zero);
                if (b_tie !== mask[idx])
                    $fatal(1, "interleaved port 1 read %0d got %b", idx, b_tie);
                mask = 8'hF0;
                sample_read(1'b1, b_tie, b_hold, b_zero);
                if (b_tie !== mask[idx])
                    $fatal(1, "interleaved port 2 read %0d got %b", idx, b_tie);
            end
            if (cnt1_tie !== 4'd8 || cnt2_tie !== 4'd8)
                $fatal(1, "interleaved reads did not advance both counters");

            buttons  = 8'h3C;
            buttons2 = 8'hC3;
            hold_latch(1);
            read8_port0(8'h3C, 701);
            if (cnt2_tie !== 4'd0 || sr2_tie !== 8'hC3 || lat2_tie !== 8'hC3)
                $fatal(1, "exhausting port 1 disturbed port 2 cnt=%0d sr=%02h lat=%02h",
                       cnt2_tie, sr2_tie, lat2_tie);
            if (past8_tie !== 1'b1)
                $fatal(1, "dbg_past8 tracked the wrong port after reading port 1");
            read8_port1(8'hC3, 701);
            if (cnt1_tie !== 4'd8)
                $fatal(1, "exhausting port 2 advanced the port 1 counter to %0d", cnt1_tie);

            read_select = 1'b0;
            buttons  = 8'hA5;
            buttons2 = 8'h5A;
            hold_latch(1);
            read_bits(1'b0, 2, 8'h01, 702);
            if (cnt1_tie !== 4'd2)
                $fatal(1, "port 1 partial count got %0d expected 2", cnt1_tie);
            read8_port1(8'h5A, 702);
            if (cnt1_tie !== 4'd2)
                $fatal(1, "reading port 2 changed the port 1 count to %0d", cnt1_tie);
            read_bits(1'b0, 6, 8'h29, 702);
            if (cnt1_tie !== 4'd8)
                $fatal(1, "port 1 did not resume at the right bit, count %0d", cnt1_tie);
            read8_past8_tie(702);
            $display("CONTROLLER two ports, independent shift registers, shared strobe PASS");
        end
    endtask

    task test_select_and_idle_isolation;
        begin
            apply_reset;
            buttons  = 8'h69;
            buttons2 = 8'h96;
            hold_latch(1);
            for (read_cycles = 0; read_cycles < 20; read_cycles = read_cycles + 1) begin
                read_select = read_cycles[0];
                mask = read_cycles[0] ? 8'h96 : 8'h69;
                @(posedge clk);
                #1;
                if (cnt1_tie !== 4'd0 || cnt2_tie !== 4'd0)
                    $fatal(1, "read_select alone changed a counter at idle %0d", read_cycles);
                if (bit_tie !== mask[0])
                    $fatal(1, "read_select alone changed data_bit at idle %0d", read_cycles);
            end
            read_select = 1'b0;
            $display("CONTROLLER read_select and clock alone are side-effect free PASS");
        end
    endtask

    task test_pulse_width;
        begin
            apply_reset;
            buttons  = 8'h81;
            buttons2 = 8'h18;
            hold_latch(1);
            read_strobe = 1'b1;
            read_select = 1'b0;
            repeat (3) begin
                #1;
                b_tie = bit_tie;
                @(posedge clk);
                #1;
            end
            read_strobe = 1'b0;
            @(posedge clk);
            #1;
            if (cnt1_tie !== 4'd3)
                $fatal(1, "a 3 cycle read pulse produced %0d reads", cnt1_tie);
            if (sr1_tie !== 8'hF0)
                $fatal(1, "shift register after a 3 cycle read pulse got %02h expected F0", sr1_tie);
            read_bits(1'b0, 5, 8'h10, 801);
            read8_past8_tie(801);
            read8_port1(8'h18, 801);
            $display("CONTROLLER one read per asserted cycle, pulse width equals read count PASS");
        end
    endtask

    task test_reset_midstream;
        begin
            apply_reset;
            buttons  = 8'hFF;
            buttons2 = 8'hFF;
            hold_latch(1);
            for (idx = 0; idx < 5; idx = idx + 1)
                sample_read(1'b0, b_tie, b_hold, b_zero);
            if (cnt1_tie !== 4'd5)
                $fatal(1, "pre-reset count got %0d expected 5", cnt1_tie);
            reset = 1'b1;
            #1;
            if (bit_tie !== 1'b0 || cnt1_tie !== 4'd0 || sr1_tie !== 8'h00 || lat1_tie !== 8'h00)
                $fatal(1, "mid-stream reset did not clear the port 1 state immediately");
            reset = 1'b0;
            #1;
            if (bit_tie !== 1'b0)
                $fatal(1, "mid-stream reset left data high after release");
            buttons  = 8'h18;
            buttons2 = 8'h81;
            hold_latch(1);
            read8_port0(8'h18, 901);
            read8_port1(8'h81, 901);
            $display("CONTROLLER reset aborts a partial read and the port still works PASS");
        end
    endtask

    task test_repeated_strobes;
        begin
            apply_reset;
            buttons  = 8'hE7;
            buttons2 = 8'h1E;
            hold_latch(3);
            if (lat1_tie !== 8'hE7 || lat2_tie !== 8'h1E)
                $fatal(1, "a multi cycle strobe did not latch the buttons");
            read8_port0(8'hE7, 1001);
            read8_port1(8'h1E, 1001);
            read8_past8_tie(1002);
            $display("CONTROLLER repeated strobe cycles and back to back reads PASS");
        end
    endtask

    initial begin
        clk          = 1'b0;
        reset        = 1'b1;
        latch_strobe = 1'b0;
        read_strobe  = 1'b0;
        read_select  = 1'b0;
        buttons      = 8'h00;
        buttons2     = 8'h00;

        test_reset;
        test_all_256_combinations;
        test_bit_order;
        test_strobe_reload;
        test_snapshot_semantics;
        test_after_eight_reads;
        test_dual_port;
        test_select_and_idle_isolation;
        test_pulse_width;
        test_reset_midstream;
        test_repeated_strobes;

        $display("PASS nes_controller");
        $finish;
    end

    initial begin
        #4000000;
        $fatal(1, "global timeout");
    end

endmodule
