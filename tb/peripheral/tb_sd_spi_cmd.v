`timescale 1ns/1ps

// SD/eMMC SPI command frame transmitter testbench.
//
// A card model answers the frame: while CS is low it samples MOSI on every
// spi_clk rising edge and rebuilds the six command bytes bit by bit, and it only
// changes MISO on a falling edge, the first one after CS presents bit 7 of byte
// 0, so byte 6 and byte 7 of the frame carry a preset resp0/resp1 pair. The
// reference CRC7 is a long division (multiply by x^7, reduce by 0x89), not the
// DUT's shift register, and the real spi_clk edges are counted for the divider
// ratio and the duty cycle.

module tb_sd_spi_cmd;

    localparam integer CLK_HZ = 21477272;
    localparam integer SPI_HZ = 400000;
    localparam integer HALF   = CLK_HZ / (2 * SPI_HZ);

    reg clk = 1'b0, reset = 1'b1, start = 1'b0, crc_check_en = 1'b0, stray = 1'b0;
    reg spi_miso = 1'b1, meas = 1'b0, have_rise = 1'b0;
    reg [5:0] cmd = 6'd0;
    reg [31:0] arg = 32'd0;
    reg [7:0] resp0_set = 8'h00, resp1_set = 8'h00, out_byte_n = 4'd0, out_bit_n = 4'd7;
    reg [7:0] in_byte [0:5];
    reg bit_log [0:119];
    wire spi_clk, spi_cs_n, spi_mosi, busy, done, crc7_err;
    wire [7:0] resp0, resp1;
    wire [7:0] out_byte = (out_byte_n == 4'd6) ? resp0_set : (out_byte_n == 4'd7) ? resp1_set : 8'hff;
    integer in_bit_n = 0, in_byte_n = 0, in_total = 0, before_cs = 0, frame_starts = 0, cyc = 0;
    integer frames = 0, done_pulses = 0, duty_bad = 0, n_rise = 0, n_fall = 0, prev_rise = 0;
    integer prev_fall = 0, lo_len = 0, hi_len = 0, half_min = 0, half_max = 0;

    sd_spi_cmd #(.CLK_HZ(CLK_HZ), .SPI_HZ(SPI_HZ)) dut (
        .clk(clk), .reset(reset), .start(start), .cmd(cmd), .arg(arg),
        .spi_clk(spi_clk), .spi_cs_n(spi_cs_n), .spi_mosi(spi_mosi), .spi_miso(spi_miso),
        .resp0(resp0), .resp1(resp1), .busy(busy), .done(done), .crc7_err(crc7_err),
        .crc_check_en(crc_check_en));

    always #5 clk = ~clk;

    always @(posedge spi_cs_n) begin
        out_byte_n = 0; out_bit_n = 4'd6; spi_miso = 1'b1; have_rise = 1'b0;
    end

    always @(negedge spi_cs_n) begin
        in_byte_n = 0; in_bit_n = 0; in_total = 0;
    end

    always @(negedge spi_clk) if (spi_cs_n === 1'b0) begin
        if (have_rise) begin
            spi_miso <= out_byte[out_bit_n[2:0]];
            out_bit_n <= (out_bit_n == 0) ? 4'd7 : out_bit_n - 4'd1;
            if (out_bit_n == 0 && out_byte_n < 4'd14) out_byte_n <= out_byte_n + 4'd1;
        end else begin
            spi_miso <= out_byte[4'd7];
            frame_starts = frame_starts + 1;
        end
    end

    always @(posedge spi_clk) if (spi_cs_n === 1'b0) begin
        have_rise = 1'b1;
        if (in_byte_n < 6) in_byte[in_byte_n] <= {in_byte[in_byte_n][6:0], spi_mosi};
        bit_log[in_total] <= spi_mosi;
        in_total = in_total + 1;
        in_bit_n <= (in_bit_n == 7) ? 0 : in_bit_n + 1;
        if (in_bit_n == 7 && in_byte_n < 6) in_byte_n <= in_byte_n + 1;
    end

    always @(posedge clk) begin
        if (reset) cyc = 0; else cyc = cyc + 1;
        if (done) done_pulses = done_pulses + 1;
        if (cyc > 2000000) $fatal(1, "watchdog, the test made no progress");
    end

    always @(posedge spi_clk) if (meas) begin
        if (n_fall > 0) lo_len = cyc - prev_fall;
        prev_rise = cyc;
        n_rise = n_rise + 1;
    end

    always @(negedge spi_clk) if (meas) begin
        if (n_rise > 0) begin
            hi_len = cyc - prev_rise;
            if (hi_len != lo_len) duty_bad = duty_bad + 1;
            if (hi_len < half_min) half_min = hi_len;
            if (hi_len > half_max) half_max = hi_len;
        end
        prev_fall = cyc;
        n_fall = n_fall + 1;
    end

    function [6:0] ref_crc7;
        input [39:0] msg;
        integer k;
        reg [46:0] acc;
        begin
            acc = {7'd0, msg};
            for (k = 0; k < 7; k = k + 1) acc = acc << 1;
            for (k = 46; k >= 7; k = k - 1)
                if (acc[k]) acc = acc ^ (47'h89 << (k - 7));
            ref_crc7 = acc[6:0];
        end
    endfunction

    function [47:0] exp_frame;
        input [5:0] c;
        input [31:0] a;
        begin
            exp_frame = {2'b01, c[5:0], a, ref_crc7({2'b01, c[5:0], a}), 1'b1};
        end
    endfunction

    task do_reset;
        begin
            start = 1'b0; reset = 1'b1;
            repeat (3) @(posedge clk);
            @(negedge clk);
            reset = 1'b0;
            @(negedge clk);
            if (spi_cs_n !== 1'b1 || busy !== 1'b0 || done !== 1'b0 || crc7_err !== 1'b0)
                $fatal(1, "reset left cs=%b busy=%b done=%b err=%b", spi_cs_n, busy, done, crc7_err);
        end
    endtask

    task issue;
        input [5:0] c;
        input [31:0] a;
        begin
            @(negedge clk);
            if (busy !== 1'b0) $fatal(1, "issue while busy");
            cmd = c; arg = a; start = 1'b1;
            @(negedge clk);
            start = 1'b0;
            if (busy !== 1'b1) $fatal(1, "busy did not follow start");
            if (spi_cs_n !== 1'b0) $fatal(1, "CS did not fall on start");
            if (stray) begin
                before_cs = frame_starts;
                repeat (40) @(posedge clk);
                if (busy !== 1'b1 || spi_cs_n !== 1'b0) $fatal(1, "stray start setup");
                cmd = 6'h37; arg = 32'hdeadbeef; start = 1'b1;
                @(negedge clk);
                start = 1'b0;
                if (busy !== 1'b1) $fatal(1, "busy dropped on a start during a frame");
            end
        end
    endtask

    task wait_done;
        begin
            frames = frames + 1;
            @(posedge done);
            if (spi_cs_n !== 1'b1) $fatal(1, "CS low when done rose");
            if (busy !== 1'b1) $fatal(1, "busy not high in the done clock");
            @(negedge clk);
            @(negedge clk);
            if (done !== 1'b0) $fatal(1, "done held longer than one clock");
            if (busy !== 1'b0) $fatal(1, "busy still high after done");
        end
    endtask

    task check_frame;
        input [5:0] c;
        input [31:0] a;
        reg [31:0] got_arg;
        reg [47:0] exp_bits;
        integer k;
        begin
            if (in_byte[0] !== {2'b01, c[5:0]}) $fatal(1, "cmd byte %02x", in_byte[0]);
            got_arg = {in_byte[1], in_byte[2], in_byte[3], in_byte[4]};
            if (got_arg !== a) $fatal(1, "arg %08x, expected %08x", got_arg, a);
            if (in_byte[5] !== {ref_crc7({2'b01, c[5:0], a}), 1'b1}) $fatal(1, "crc byte %02x", in_byte[5]);
            exp_bits = exp_frame(c, a);
            for (k = 0; k < 48; k = k + 1)
                if (bit_log[k] !== exp_bits[47 - k]) $fatal(1, "bit %0d is %b, expected %b", k, bit_log[k], exp_bits[47 - k]);
            for (k = 48; k < 120; k = k + 1)
                if (bit_log[k] !== 1'b1) $fatal(1, "dummy bit %0d is %b", k, bit_log[k]);
            if (in_total !== 120) $fatal(1, "%0d clocks in one frame", in_total);
        end
    endtask

    task run_frame;
        input [5:0] c; input [31:0] a;
        input [7:0] r0; input [7:0] r1;
        begin
            resp0_set = r0; resp1_set = r1;
            issue(c, a);
            wait_done;
            if (resp0 !== r0 || resp1 !== r1) $fatal(1, "reply %02x %02x", resp0, resp1);
            check_frame(c, a);
        end
    endtask

    task check_timing;
        begin
            meas = 1'b0;
            if (duty_bad !== 0) $fatal(1, "%0d spi_clk periods not 50%% duty", duty_bad);
            if (half_min < HALF - 1 || half_max > HALF + 1)
                $fatal(1, "half period %0d..%0d clocks, expected %0d +-1", half_min, half_max, HALF);
            if (n_rise !== 121 || n_fall !== 121)
                $fatal(1, "%0d rising / %0d falling edges, expected 121/121", n_rise, n_fall);
        end
    endtask

    initial begin
        do_reset;
        $display("A1 reset leaves cs_n=1 busy=0 done=0 crc7_err=0");
        meas = 1'b1; n_rise = 0; n_fall = 0; duty_bad = 0; half_min = 1000000; half_max = 0;
        run_frame(6'h11, 32'h00001234, 8'h51, 8'h00);
        $display("A2 CMD17 sent as 51 00 00 12 34 %02x, reply %02x %02x", in_byte[5], resp0, resp1);
        check_timing;
        stray = 1'b1;
        run_frame(6'h00, 32'h00000000, 8'h09, 8'h00);
        stray = 1'b0;
        if (frame_starts !== before_cs) $fatal(1, "a start during a frame opened a new frame");
        if (in_byte[5] !== 8'h95) $fatal(1, "CMD00 crc byte %02x, the SD spec value is 95", in_byte[5]);
        run_frame(6'h08, 32'h000001aa, 8'h51, 8'h00);
        run_frame(6'h29, 32'h40000000, 8'h51, 8'h00);
        run_frame(6'h11, 32'hffff0000, 8'h51, 8'h00);
        $display("A3 CMD00/08/29/11: bit order and 4 CRC7 bytes match, CMD00 byte is 0x95");
        crc_check_en = 1'b1;
        run_frame(6'h37, 32'h00000000, 8'h00, 8'h00);
        if (crc7_err !== 1'b0) $fatal(1, "all zero reply raised crc7_err");
        run_frame(6'h37, 32'h00000000, 8'hff, 8'hff);
        if (crc7_err !== 1'b0) $fatal(1, "all ones reply raised crc7_err");
        run_frame(6'h17, 32'h00001234, 8'h51, 8'h00);
        if (crc7_err !== 1'b1) $fatal(1, "bad reply CRC7 was not flagged");
        $display("A4 crc_check_en skips 0x00 and 0xff, flags 0x51, sticky until reset");
        do_reset;
        crc_check_en = 1'b0;
        issue(6'h00, 32'h00000000);
        repeat (60) @(posedge clk);
        if (spi_cs_n !== 1'b0) $fatal(1, "CS already high, frame too short");
        reset = 1'b1;
        repeat (3) @(posedge clk);
        if (spi_cs_n !== 1'b1 || busy !== 1'b0 || done !== 1'b0 || crc7_err !== 1'b0)
            $fatal(1, "mid frame reset left cs=%b busy=%b", spi_cs_n, busy);
        reset = 1'b0;
        meas = 1'b1; n_rise = 0; n_fall = 0; duty_bad = 0; half_min = 1000000; half_max = 0;
        run_frame(6'h08, 32'h000001aa, 8'h00, 8'h00);
        check_timing;
        $display("A7 reset 40 bits into a frame restores CS, next frame is complete");
        $display("A6 half period %0d..%0d clocks (want %0d +-1), 50%% duty, 121/121 edges", half_min, half_max, HALF);
        if (done_pulses !== frames) $fatal(1, "%0d done pulses for %0d frames", done_pulses, frames);
        if (frame_starts !== frames + 1) $fatal(1, "%0d CS assertions for %0d done frames", frame_starts, frames);
        $display("A5 one done pulse per frame, a start while busy is ignored");
        $display("PASS sd_spi_cmd");
        $finish;
    end

endmodule
