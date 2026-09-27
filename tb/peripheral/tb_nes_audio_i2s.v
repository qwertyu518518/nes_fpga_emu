`timescale 1ns/1ps

// tb_nes_audio_i2s: self checking testbench for the I2S assembly layer.
//
// Timing of the bench
//   wr_clk is 10 ns, rd_clk and mclk are 20 ns, BCLK_DIV = 1 so bclk is mclk
//   and therefore has the same period and phase as rd_clk. One sample is 32
//   serialiser clocks, that is 640 ns, and rd_ce is tied high.
//
// Why the four samples are written back to back
//   The serialiser takes a new sample only on its bit 31 edge, the one edge on
//   which a busy serialiser accepts anything, so a gapless stream requires the
//   next sample to be in hand before that edge arrives. That is a property of
//   the reader having buffered the samples in advance, not of the spacing of
//   the writes. The old stimulus wrote the four samples 1000 ns apart, which is
//   50 rd_clk against the 32 rd_clk one sample needs, so the fifo was provably
//   empty at the moment each bit 31 edge arrived and idle cycles in the output
//   were unavoidable. The old collector then took one bit per bclk rising edge
//   whatever sample_valid said, so it folded the idle hold values into the data:
//   the old bench measured FAIL at dout bit 32, that is sample 1 bit 0, got 0
//   against a reference of 1.
//   Writing the four samples on consecutive wr_clk cycles puts all of them into
//   the fifo up front. The reader then holds the next sample in the fifo read
//   register until its bit 31 edge arrives, so a gapless stream becomes the
//   only legal outcome and the gap can be asserted instead of tolerated.
//
// What is checked
//   A bit is collected for every bclk rising edge that has sample_valid high,
//   and any bclk rising edge between the first and the last of those strobes
//   that has sample_valid low is a fatal gap, so the collector cannot hide an
//   idle period by skipping it. The collected bits are then compared one by one
//   against a reference model built from the channel semantics, and lrck is
//   required to be 16 low bits followed by 16 high bits inside every 32 bit
//   sample, with the flip on the 17th bit of each of the four samples.
//   dropped must never rise, which is the observable form of the back pressure
//   holding: no sample is lost to a busy serialiser and the fifo is never full.
//   underflow is not checked and is expected to be asserted, since the reader
//   keeps only one sample in hand and the fifo runs empty between samples.
//
// Two corrections to the previous bench, both from measuring the serialiser
//   It collected 64 bits while writing four samples. A sample is 32 bits, so
//   four samples are 128 bits and the old 64 bit window and its reference model
//   only ever covered the first two of the four written samples, the other two
//   were streamed and never looked at. The window is now the full 128 bits.
//   Its lrck criterion was 32 low bits followed by 32 high bits with the flip on
//   the 33rd bit, which is the criterion for a stream of one sample: lrck is a
//   channel marker, it is low for the 16 left bits of every sample and high for
//   its 16 right bits, so a four sample stream is 16 low then 16 high, repeated,
//   and the flip lands on bit 17 of each sample, that is on bit index 16, 48, 80
//   and 112 of the stream. The old criterion rejects that measured pattern. The
//   replacement checks all four 16/16 splits and all four flips, which is
//   strictly more than the one split the old bench looked at.
//
// Why the data is taken one bclk edge after the strobe
//   dout and lrck are registered on the bclk rising edge out of the serialiser
//   pins, and the serialiser updates its own pins on the same rd_clk edge, so
//   the registered data is the bit of the previous rd_clk edge while
//   sample_valid, which is that serialiser strobe, already reports the current
//   one: the strobe leads the data by exactly one bclk edge. The collector
//   therefore arms on a sample_valid strobe and takes the data on the following
//   bclk rising edge, which is the data that strobe belongs to. Sampling on the
//   strobe edge itself instead yields the whole stream shifted by one bit, which
//   is what a first cut of this bench did.

module tb_nes_audio_i2s;

    localparam integer NSAMP    = 4;
    localparam integer SAMPLEB  = 32;
    localparam integer NBITS    = NSAMP * SAMPLEB;
    localparam integer TIMEOUT  = 500000;

    reg          wr_clk = 1'b0;
    reg          rd_clk = 1'b1;
    reg          mclk   = 1'b0;

    reg          wr_reset = 1'b1;
    reg          rd_reset = 1'b1;
    reg          wr_en    = 1'b0;
    reg  [15:0]  wr_left  = 16'h0000;
    reg  [15:0]  wr_right = 16'h0000;

    wire         wr_full;
    wire         dropped;
    wire         underflow;
    wire         bclk;
    wire         lrck;
    wire         dout;
    wire         sample_valid;

    reg  [31:0]  ref_word [0:NSAMP-1];
    reg  [NBITS-1:0] got_bit  = {NBITS{1'b0}};
    reg  [NBITS-1:0] got_lrck = {NBITS{1'b0}};
    reg  [NBITS-1:0] exp_bit  = {NBITS{1'b0}};

    reg          streaming = 1'b0;
    reg          armed     = 1'b0;
    reg          drop_seen = 1'b0;
    reg  [15:0]  n16 = 16'd0;
    integer      nstrk = 0;
    integer      nbit = 0;
    integer      i;
    integer      b;
    integer      n;
    integer      k;
    integer      bad;

    always #5  wr_clk = ~wr_clk;
    always #10 rd_clk = ~rd_clk;
    always #10 mclk   = ~mclk;

    nes_audio_i2s #(
        .BCLK_DIV(1)
    ) dut (
        .wr_clk      (wr_clk),
        .wr_reset    (wr_reset),
        .wr_en       (wr_en),
        .wr_left     (wr_left),
        .wr_right    (wr_right),
        .wr_full     (wr_full),
        .dropped     (dropped),
        .rd_clk      (rd_clk),
        .rd_reset    (rd_reset),
        .mclk        (mclk),
        .rd_ce       (1'b1),
        .underflow   (underflow),
        .bclk        (bclk),
        .lrck        (lrck),
        .dout        (dout),
        .sample_valid(sample_valid)
    );

    task write_sample;
        input integer idx;
        begin
            @(negedge wr_clk);
            wr_left  = ref_word[idx][15:0];
            wr_right = ref_word[idx][31:16];
            wr_en    = 1'b1;
            @(negedge wr_clk);
            wr_en    = 1'b0;
        end
    endtask

    always @(posedge bclk) begin
        if (dropped === 1'b1)
            drop_seen <= 1'b1;
        if (armed === 1'b1) begin
            got_bit [nbit] <= dout;
            got_lrck[nbit] <= lrck;
            nbit  <= nbit + 1;
            armed <= 1'b0;
        end
        if (nstrk < NBITS) begin
            if (sample_valid === 1'b1) begin
                nstrk     <= nstrk + 1;
                armed     <= 1'b1;
                streaming <= 1'b1;
            end else if (streaming === 1'b1) begin
                $fatal(1, "FAIL nes_audio_i2s: bclk rising edge after %0d gapless sample_valid strobes has sample_valid low, the bit stream is not gapless",
                       nstrk);
            end
        end
    end

    initial begin
        for (n16 = 16'd0; n16 < NSAMP; n16 = n16 + 16'd1)
            ref_word[n16] = {16'hb000 + n16, 16'ha000 + n16};

        for (b = 0; b < NBITS; b = b + 1) begin
            n = b / SAMPLEB;
            k = b % SAMPLEB;
            exp_bit[b] = (k < 16) ? ref_word[n][15-k] : ref_word[n][47-k];
        end

        repeat (20) @(posedge wr_clk);
        #1;
        wr_reset = 1'b0;
        rd_reset = 1'b0;

        for (i = 0; i < NSAMP; i = i + 1)
            write_sample(i);

        wait (nbit == NBITS);
        #1;

        if (nstrk !== NBITS)
            $fatal(1, "FAIL nes_audio_i2s: %0d sample_valid strobes were seen but %0d bits were collected",
                   nstrk, NBITS);

        if (drop_seen !== 1'b0) begin
            $display("FAIL nes_audio_i2s: dropped rose while streaming, a sample was lost to the serialiser or the fifo filled");
            $fatal(1, "FAIL nes_audio_i2s: the read side must not lose a sample the fifo accepted");
        end

        bad = -1;
        for (b = 0; b < NBITS; b = b + 1)
            if (bad < 0 && got_bit[b] !== exp_bit[b])
                bad = b;
        if (bad >= 0) begin
            $display("FAIL nes_audio_i2s: dout bit %0d (sample %0d, bit %0d) is %b, the reference is %b",
                     bad, bad / SAMPLEB, bad % SAMPLEB, got_bit[bad], exp_bit[bad]);
            $fatal(1, "FAIL nes_audio_i2s: the dout bit stream does not match the reference model");
        end

        bad = -1;
        for (b = 0; b < NBITS; b = b + 1) begin
            k = b % SAMPLEB;
            if (bad < 0 && got_lrck[b] !== ((k < 16) ? 1'b0 : 1'b1))
                bad = b;
        end
        if (bad >= 0) begin
            $display("FAIL nes_audio_i2s: lrck is %b at stream bit %0d, that is sample %0d bit %0d, the reference is %b",
                     got_lrck[bad], bad, bad / SAMPLEB, bad % SAMPLEB, (bad % SAMPLEB < 16) ? 1'b0 : 1'b1);
            $fatal(1, "FAIL nes_audio_i2s: lrck is not 16 low bits followed by 16 high bits in every sample");
        end

        for (n = 0; n < NSAMP; n = n + 1) begin
            if (got_lrck[SAMPLEB*n + 16] === got_lrck[SAMPLEB*n + 15])
                $fatal(1, "FAIL nes_audio_i2s: lrck must flip on the 17th bit of sample %0d, it is %b then %b",
                       n, got_lrck[SAMPLEB*n + 15], got_lrck[SAMPLEB*n + 16]);
        end

        $display("tb_nes_audio_i2s: %0d bits checked on %0d consecutive sample_valid bclk edges, %0d samples back to back",
                 NBITS, NBITS, NSAMP);
        $display("PASS nes_audio_i2s");
        $finish;
    end

    initial begin
        #TIMEOUT;
        $fatal(1, "FAIL nes_audio_i2s: global timeout, only %0d of %0d bits collected",
               nbit, NBITS);
    end

endmodule
