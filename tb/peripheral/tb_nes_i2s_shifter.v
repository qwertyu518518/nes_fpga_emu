`timescale 1ns/1ps

// tb_nes_i2s_shifter: self checking testbench for the I2S bit serialiser.
//
// Two instances are driven from the same stimulus, one with BIT_REVERSED = 0
// and one with BIT_REVERSED = 1. The reference model is written from the
// channel semantics instead of from the RTL index arithmetic: for the plain
// instance the left sample leaves as left[15] ... left[0] followed by the right
// sample as right[15] ... right[0], for the reversed instance each channel
// leaves least significant bit first, and in both cases the left channel
// occupies the first 16 bit positions. Every ce enabled clock is compared
// against that model, so a swapped channel, a stuck bit, a wrong bit order, a
// lost ce gap and a corrupted sample all fail.
//
// out_lrck is checked on every bit and again at the end of a run, where the
// flip is required exactly on the 17th bit. busy, out_valid and dropped are
// checked at every state transition, a ce gap is checked to freeze all four
// stream pins, and the five back to back samples are checked as one flat 160
// bit stream so that a sample overwriting the one in flight cannot hide.

module tb_nes_i2s_shifter;

    localparam [15:0] L_A = 16'h1234;
    localparam [15:0] R_A = 16'habcd;
    localparam [15:0] L_B = 16'h0f96;
    localparam [15:0] R_B = 16'h69f0;
    localparam [15:0] L_C = 16'h1234;
    localparam [15:0] R_C = 16'habcd;
    localparam [15:0] L_D = 16'h0f0f;
    localparam [15:0] R_D = 16'hf0f0;
    localparam [15:0] L_E = 16'h5555;
    localparam [15:0] R_E = 16'haaaa;
    localparam [15:0] L_F = 16'h1b0f;
    localparam [15:0] R_F = 16'hf0b1;
    localparam [15:0] L_G = 16'hbeef;
    localparam [15:0] R_G = 16'hdead;

    localparam [31:0] SAMPLE_A = {R_A, L_A};
    localparam [31:0] SAMPLE_B = {R_B, L_B};
    localparam [31:0] SAMPLE_C = {R_C, L_C};
    localparam [31:0] SAMPLE_D = {R_D, L_D};
    localparam [31:0] SAMPLE_E = {R_E, L_E};
    localparam [31:0] SAMPLE_F = {R_F, L_F};
    localparam [31:0] SAMPLE_G = {R_G, L_G};

    localparam integer SAMPLE_COUNT = 5;
    localparam integer BURST_BITS  = 32 * SAMPLE_COUNT;

    reg        clk = 1'b0;
    reg        reset = 1'b0;
    reg        ce = 1'b0;
    reg        sample_valid = 1'b0;
    reg  [31:0] sample_data = 32'h0;

    wire       out_valid;
    wire       out_bit;
    wire       out_lrck;
    wire       busy;
    wire       dropped;

    wire       out_valid_rev;
    wire       out_bit_rev;
    wire       out_lrck_rev;
    wire       busy_rev;
    wire       dropped_rev;

    nes_i2s_shifter #(
        .BIT_REVERSED(0)
    ) dut (
        .clk(clk),
        .reset(reset),
        .ce(ce),
        .sample_valid(sample_valid),
        .sample_data(sample_data),
        .out_valid(out_valid),
        .out_bit(out_bit),
        .out_lrck(out_lrck),
        .busy(busy),
        .dropped(dropped)
    );

    nes_i2s_shifter #(
        .BIT_REVERSED(1)
    ) dut_rev (
        .clk(clk),
        .reset(reset),
        .ce(ce),
        .sample_valid(sample_valid),
        .sample_data(sample_data),
        .out_valid(out_valid_rev),
        .out_bit(out_bit_rev),
        .out_lrck(out_lrck_rev),
        .busy(busy_rev),
        .dropped(dropped_rev)
    );

    always #5 clk = ~clk;

    reg        exp_msb  [0:BURST_BITS-1];
    reg        exp_lsb  [0:BURST_BITS-1];
    reg        got_msb  [0:BURST_BITS-1];
    reg        got_lrck0[0:BURST_BITS-1];
    reg        got_lsb  [0:BURST_BITS-1];
    reg        got_lrck1[0:BURST_BITS-1];

    reg [31:0] ref_word = 32'h0;
    reg [31:0] ref_swap = 32'h0;

    integer    nbit = 0;
    integer    nbit_rev = 0;
    integer    exp_total = 32;
    integer    i;
    integer    k;
    integer    n;
    integer    diffs;

    reg        fz_valid = 1'b0;
    reg        fz_bit   = 1'b0;
    reg        fz_lrck  = 1'b0;
    reg        fz_busy  = 1'b0;
    reg        fz_drop  = 1'b0;
    reg        fz_rvalid= 1'b0;
    reg        fz_rbit  = 1'b0;
    reg        fz_rlrck = 1'b0;
    reg        fz_rbusy = 1'b0;
    integer    fz_nbit = 0;
    integer    fz_nrev = 0;

    task build_pair;
        input [15:0] l;
        input [15:0] r;
        input integer base;
        integer b;
        begin
            for (b = 0; b < 16; b = b + 1) begin
                exp_msb[base + b]     = l[15 - b];
                exp_lsb[base + b]     = l[b];
            end
            for (b = 0; b < 16; b = b + 1) begin
                exp_msb[base + 16 + b] = r[15 - b];
                exp_lsb[base + 16 + b] = r[b];
            end
        end
    endtask

    task capture;
        begin
            if (out_valid === 1'b1) begin
                if (nbit >= exp_total)
                    $fatal(1, "instance 0 produced more than %0d valid bit cycles", exp_total);
                if (out_bit !== exp_msb[nbit])
                    $fatal(1, "instance 0 bit %0d is %b, the reference is %b", nbit, out_bit, exp_msb[nbit]);
                got_msb[nbit]   = out_bit;
                got_lrck0[nbit] = out_lrck;
                nbit = nbit + 1;
            end else if (out_valid !== 1'b0) begin
                $fatal(1, "instance 0 out_valid is %b, not a clean 0 or 1", out_valid);
            end

            if (out_valid_rev === 1'b1) begin
                if (nbit_rev >= exp_total)
                    $fatal(1, "instance 1 produced more than %0d valid bit cycles", exp_total);
                if (out_bit_rev !== exp_lsb[nbit_rev])
                    $fatal(1, "instance 1 bit %0d is %b, the reference is %b", nbit_rev, out_bit_rev, exp_lsb[nbit_rev]);
                got_lsb[nbit_rev]   = out_bit_rev;
                got_lrck1[nbit_rev] = out_lrck_rev;
                nbit_rev = nbit_rev + 1;
            end else if (out_valid_rev !== 1'b0) begin
                $fatal(1, "instance 1 out_valid is %b, not a clean 0 or 1", out_valid_rev);
            end

            if (nbit !== nbit_rev)
                $fatal(1, "instance 0 has emitted %0d bits but instance 1 has emitted %0d", nbit, nbit_rev);
        end
    endtask

    task step;
        input c;
        input sv;
        input [31:0] sd;
        begin
            @(negedge clk);
            ce           = c;
            sample_valid = sv;
            sample_data  = sd;
            @(posedge clk);
            #1;
            if (c === 1'b1)
                capture;
        end
    endtask

    task freeze_mark;
        begin
            fz_valid  = out_valid;
            fz_bit    = out_bit;
            fz_lrck   = out_lrck;
            fz_busy   = busy;
            fz_drop   = dropped;
            fz_rvalid = out_valid_rev;
            fz_rbit   = out_bit_rev;
            fz_rlrck  = out_lrck_rev;
            fz_rbusy  = busy_rev;
            fz_nbit   = nbit;
            fz_nrev   = nbit_rev;
        end
    endtask

    task freeze_check;
        input integer gap;
        begin
            if (out_valid !== fz_valid || out_bit !== fz_bit || out_lrck !== fz_lrck ||
                busy !== fz_busy || dropped !== fz_drop)
                $fatal(1, "instance 0 moved while ce was low (ce gap %0d): valid %b/%b bit %b/%b lrck %b/%b busy %b/%b",
                       gap, out_valid, fz_valid, out_bit, fz_bit, out_lrck, fz_lrck, busy, fz_busy);
            if (out_valid_rev !== fz_rvalid || out_bit_rev !== fz_rbit || out_lrck_rev !== fz_rlrck ||
                busy_rev !== fz_rbusy)
                $fatal(1, "instance 1 moved while ce was low (ce gap %0d): valid %b/%b bit %b/%b lrck %b/%b busy %b/%b",
                       gap, out_valid_rev, fz_rvalid, out_bit_rev, fz_rbit, out_lrck_rev, fz_rlrck, busy_rev, fz_rbusy);
            if (nbit !== fz_nbit || nbit_rev !== fz_nrev)
                $fatal(1, "the bit counter advanced while ce was low (ce gap %0d)", gap);
        end
    endtask

    task drain;
        input integer target;
        integer guard;
        begin
            guard = 0;
            while (nbit < target) begin
                if (guard > 96)
                    $fatal(1, "the stream stalled at %0d bits, %0d expected, the serialiser stopped early",
                           nbit, target);
                guard = guard + 1;
                step(1, 0, 32'h0);
            end
        end
    endtask

    task do_reset;
        begin
            @(negedge clk);
            reset = 1'b1;
            repeat (3) begin
                @(posedge clk);
                #1;
            end
            if (busy !== 1'b0 || out_valid !== 1'b0 || dropped !== 1'b0 ||
                out_bit !== 1'b0 || out_lrck !== 1'b0)
                $fatal(1, "reset must clear busy, out_valid, out_bit, out_lrck and dropped, got %b/%b/%b/%b/%b",
                       busy, out_valid, out_bit, out_lrck, dropped);
            if (busy_rev !== 1'b0 || out_valid_rev !== 1'b0 || dropped_rev !== 1'b0 ||
                out_bit_rev !== 1'b0 || out_lrck_rev !== 1'b0)
                $fatal(1, "reset must clear the reversed instance, got %b/%b/%b/%b/%b",
                       busy_rev, out_valid_rev, out_bit_rev, out_lrck_rev, dropped_rev);
            @(negedge clk);
            reset = 1'b0;
            @(posedge clk);
            #1;
            if (busy !== 1'b0 || out_valid !== 1'b0 || dropped !== 1'b0)
                $fatal(1, "busy, out_valid and dropped must stay low after reset is released");
            if (busy_rev !== 1'b0 || out_valid_rev !== 1'b0 || dropped_rev !== 1'b0)
                $fatal(1, "the reversed instance must stay idle after reset is released");
        end
    endtask

    task check_lrck_split;
        input integer count;
        input        tag;
        begin
            for (i = 0; i < count; i = i + 1) begin
                if ((i % 32) < 16) begin
                    if (got_lrck0[i] !== 1'b0)
                        $fatal(1, "%s: out_lrck is high at bit %0d, the left channel must come first", tag, i);
                    if (got_lrck1[i] !== 1'b0)
                        $fatal(1, "%s: reversed out_lrck is high at bit %0d, the left channel must come first", tag, i);
                end else begin
                    if (got_lrck0[i] !== 1'b1)
                        $fatal(1, "%s: out_lrck is low at bit %0d, the right channel must follow the left one", tag, i);
                    if (got_lrck1[i] !== 1'b1)
                        $fatal(1, "%s: reversed out_lrck is low at bit %0d, the right channel must follow the left one", tag, i);
                end
            end
            if (got_lrck0[16] === got_lrck0[15])
                $fatal(1, "%s: out_lrck must flip on the 17th bit", tag);
            if (got_lrck1[16] === got_lrck1[15])
                $fatal(1, "%s: reversed out_lrck must flip on the 17th bit", tag);
        end
    endtask

    initial begin
        exp_total = 32;
        do_reset;

        if (busy !== 1'b0 || out_valid !== 1'b0 || dropped !== 1'b0)
            $fatal(1, "busy, out_valid and dropped must all be low after reset");
        if (out_bit !== 1'b0 || out_lrck !== 1'b0)
            $fatal(1, "out_bit and out_lrck must be low after reset");

        // ---------------------------------------------------------------
        // single sample: 32 bits, lrck split, ce freeze in the middle
        // ---------------------------------------------------------------
        nbit = 0;
        nbit_rev = 0;
        exp_total = 32;
        build_pair(L_A, R_A, 0);
        ref_word = SAMPLE_A;
        ref_swap = {SAMPLE_A[15:0], SAMPLE_A[31:16]};

        step(1, 1, SAMPLE_A);
        if (busy !== 1'b1)
            $fatal(1, "busy must rise on the sample_valid clock");
        if (busy_rev !== 1'b1)
            $fatal(1, "busy must rise on the reversed instance too");
        if (nbit !== 0)
            $fatal(1, "the load clock must not emit a bit, %0d bits came out", nbit);

        step(1, 0, 32'h0);
        step(1, 0, 32'h0);
        if (nbit !== 2)
            $fatal(1, "two ce clocks produced %0d bits, 2 expected", nbit);

        freeze_mark;
        for (i = 0; i < 5; i = i + 1) begin
            step(0, 0, 32'h5aa5_5aa5);
            freeze_check(i);
        end
        if (out_valid !== fz_valid)
            $fatal(1, "out_valid must hold across a ce gap");

        step(1, 0, 32'h0);
        if (nbit !== 3)
            $fatal(1, "the first ce clock after a gap must emit exactly one bit, %0d bits total", nbit);

        drain(32);
        if (nbit !== 32)
            $fatal(1, "one sample produced %0d valid bit cycles, 32 expected", nbit);

        step(1, 0, 32'h0);
        if (out_valid !== 1'b0)
            $fatal(1, "out_valid must fall on the clock after the 32nd bit");
        if (busy !== 1'b0)
            $fatal(1, "busy must fall once 32 bits have been shifted out");
        if (dropped !== 1'b0)
            $fatal(1, "dropped must stay low when no sample was lost");

        repeat (4)
            step(1, 0, 32'h0);
        if (nbit !== 32)
            $fatal(1, "idle clocks produced %0d extra bits", nbit - 32);

        check_lrck_split(32, "single sample");

        for (i = 0; i < 32; i = i + 1) begin
            if (got_msb[i] !== ref_swap[31 - i])
                $fatal(1, "instance 0 bit %0d is not the MSB first half swapped sample word", i);
            if (got_lsb[i] !== ref_word[i])
                $fatal(1, "instance 1 bit %0d is not the LSB first sample word", i);
        end
        diffs = 0;
        for (i = 0; i < 32; i = i + 1)
            if (got_msb[i] !== got_lsb[i])
                diffs = diffs + 1;
        if (diffs == 0)
            $fatal(1, "the MSB first and LSB first streams are identical, the test sample cannot tell them apart");

        // ---------------------------------------------------------------
        // a sample that arrives while busy is dropped
        // ---------------------------------------------------------------
        nbit = 0;
        nbit_rev = 0;
        exp_total = 32;
        build_pair(L_B, R_B, 0);
        ref_word = SAMPLE_B;
        if (ref_word === SAMPLE_A)
            $fatal(1, "the dropped sample must differ from the sample in flight");

        step(1, 1, SAMPLE_B);
        step(1, 0, 32'h0);
        step(1, 0, 32'h0);
        step(1, 0, 32'h0);
        if (nbit !== 3)
            $fatal(1, "three ce clocks produced %0d bits, 3 expected", nbit);
        if (dropped !== 1'b0)
            $fatal(1, "dropped must be low before the colliding sample arrives");

        step(1, 1, SAMPLE_C);
        if (dropped !== 1'b1)
            $fatal(1, "dropped must rise when sample_valid arrives while busy");
        if (dropped_rev !== 1'b1)
            $fatal(1, "dropped must rise on the reversed instance too");
        if (nbit !== 4)
            $fatal(1, "a dropped sample must not disturb the bit stream, %0d bits came out", nbit);
        if (busy !== 1'b1)
            $fatal(1, "busy must stay high while a dropped sample arrives");

        drain(32);
        step(1, 0, 32'h0);
        if (nbit !== 32)
            $fatal(1, "the sample in flight produced %0d bits, 32 expected", nbit);
        if (busy !== 1'b0)
            $fatal(1, "busy must fall after the sample in flight is finished");
        if (dropped !== 1'b1)
            $fatal(1, "dropped must be sticky until reset");

        for (i = 0; i < 32; i = i + 1) begin
            if (got_msb[i] !== exp_msb[i])
                $fatal(1, "bit %0d does not belong to the sample that was in flight", i);
            if (got_lsb[i] !== exp_lsb[i])
                $fatal(1, "reversed bit %0d does not belong to the sample that was in flight", i);
        end
        check_lrck_split(32, "dropped sample");

        repeat (4)
            step(0, 0, 32'h0);
        if (nbit !== 32)
            $fatal(1, "the dropped sample must not be emitted later, %0d extra bits", nbit - 32);

        do_reset;
        if (dropped !== 1'b0 || dropped_rev !== 1'b0)
            $fatal(1, "reset must clear the sticky dropped flag");

        // ---------------------------------------------------------------
        // five back to back samples, one ce gap between them
        // ---------------------------------------------------------------
        nbit = 0;
        nbit_rev = 0;
        exp_total = BURST_BITS;
        build_pair(L_A, R_A, 0);
        build_pair(L_D, R_D, 32);
        build_pair(L_E, R_E, 64);
        build_pair(L_F, R_F, 96);
        build_pair(L_G, R_G, 128);

        for (k = 0; k < SAMPLE_COUNT; k = k + 1) begin
            if (k == 0) step(1, 1, SAMPLE_A);
            if (k == 1) step(1, 1, SAMPLE_D);
            if (k == 2) step(1, 1, SAMPLE_E);
            if (k == 3) step(1, 1, SAMPLE_F);
            if (k == 4) step(1, 1, SAMPLE_G);
            for (n = 0; n < 32; n = n + 1)
                step(1, 0, 32'h0);
            step(0, 0, 32'h0);
        end

        if (nbit !== BURST_BITS)
            $fatal(1, "the back to back burst produced %0d bits, %0d expected", nbit, BURST_BITS);
        if (dropped !== 1'b0 || dropped_rev !== 1'b0)
            $fatal(1, "a back to back burst must not drop a sample");
        check_lrck_split(BURST_BITS, "back to back burst");

        for (i = 0; i < BURST_BITS; i = i + 1) begin
            if (got_msb[i] !== exp_msb[i])
                $fatal(1, "back to back bit %0d is %b, the reference is %b", i, got_msb[i], exp_msb[i]);
            if (got_lsb[i] !== exp_lsb[i])
                $fatal(1, "back to back reversed bit %0d is %b, the reference is %b", i, got_lsb[i], exp_lsb[i]);
        end

        repeat (4)
            step(1, 0, 32'h0);
        if (nbit !== BURST_BITS)
            $fatal(1, "the burst produced %0d trailing bits", nbit - BURST_BITS);
        if (busy !== 1'b0 || busy_rev !== 1'b0)
            $fatal(1, "both instances must be idle after the burst");

        do_reset;
        if (busy !== 1'b0 || out_valid !== 1'b0 || dropped !== 1'b0)
            $fatal(1, "busy, out_valid and dropped must be low after the final reset");

        $display("tb_nes_i2s_shifter: %0d bits checked per instance, 5 samples", BURST_BITS);
        $display("PASS nes_i2s_shifter");
        $finish;
    end

    initial begin
        #2000000;
        $fatal(1, "tb_nes_i2s_shifter global timeout");
    end

endmodule
