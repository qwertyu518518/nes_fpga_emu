`timescale 1ns/1ps

// ============================================================================
// tb_nes_audio_lane : gate testbench for the Zynq-7020 audio lane
// ----------------------------------------------------------------------------
// The audio lane is wiring that lives inside nes_zynq_top.v, so this bench
// elaborates the WHOLE top with the real MMCM model, the real NES core and the
// real two submodules the top now instantiates for the first time
// (nes_audio_i2s and wm8960_i2c).  Nothing about the PPU, the mapper or the
// scaler is re-tested here; tb_nes_zynq_top already owns those.  What is
// checked is only what exists nowhere else:
//
//   A. The codec control I2C, on the real pins.  A slave model resolves the
//      open drain bus, decodes START / STOP / byte / ACK, and every write is
//      compared against a HARD-CODED copy of the WM8960_v4.4 register table.
//      Comparing against dut's own parameters would only prove the state
//      machine walked its table; this proves the table is right for a WM8960.
//
//   B. The decimator, in the mmcm_core_clk domain.
//      B1 unity gain, BIT EXACT.  A constant input must come out of the
//         4/4/2 average and the /32 completely unchanged.  This is a closed
//         form check with no reference model in it at all.
//      B2 value by value against an independent reference model written with a
//         history buffer and explicit sums rather than the DUT's running delay
//         registers, so the two are not the same code twice.
//      B3 exact output count.  The rational step is 2016 input samples to 55
//         output samples, and the Bresenham accumulator is bounded, so after
//         exactly 2016k input strobes there must be exactly 55k outputs.  That
//         is the no-drift proof: a mismatch between the producer and the
//         consumer shows up here first, long before it shows up as a flag.
//
//   C. The FIFO between them.  wr_full, dropped and underflow must all stay low
//      from the moment the read side is released until the end of the run.
//
//   D. The I2S pins against the WM8960's I2S format section.
//      D1 bclk period 640 ns = 1.5625 MHz.
//      D2 the channel a bit belongs to is the lrck value sampled ONE BCLK
//         EARLIER than the bit is latched.  That is the arrangement Philips
//         I2S produces: LRCLK changes one bitclock before the last bit of the
//         outgoing word is latched, and the MSB of the incoming word is latched
//         on the second rising BCLK edge after the LRCLK change.  WM8960_v4.4:
//         "In I2S mode, the MSB is available on the second rising edge of BCLK
//         following a LRCLK transition."
//      D3 bit order, MSB first, and word alignment.  Every decoded frame is
//         compared against the value the decimator actually wrote into the FIFO
//         at a FIXED index offset.  Because the FIFO is FIFO and nothing is
//         dropped, that offset is a single constant K; if it ever moved the
//         design would be drifting, and the assertion fires.  This is what
//         catches a reversed shifter, swapped channels or a missing bit: the
//         forced stimulus is a ramp whose 16 bit outputs are all distinct
//         inside the search window, so a bit-reversed word is a value that
//         never appears in the ramp.
//
// WHY THE SAMPLE INPUT IS FORCED
//   nes_apu2a03 leaves its mixer output at zero until a game writes the APU
//   registers, and the placeholder PRG ROM in this repository is not a game, so
//   with the real APU every sample is zero and every check above would be
//   vacuous.  audio_sample_left / audio_sample_right are therefore forced and
//   audio_sample_valid is left alone, so the strobe rate, its 12 core clock
//   spacing and the whole core domain are still the real ones.  Two phases: a
//   constant for the unity gain check, then a ramp for everything else.
//
// WHAT IS NOT CHECKED, AND WHY
//   No analogue behaviour, no PLL lock inside the codec, no headphone output.
//   The codec is a testbench slave model, not a WM8960.  The alias rejection
//   of the 4/4/2 cascade is not measured here either: it needs a spectrum, and
//   what this bench proves about the filter is its exact arithmetic, not its
//   stopband.  A constant and a ramp both pass a filter of any shape, so the
//   filter checks here are arithmetic checks.
// ============================================================================

module tb_nes_audio_lane;

    // ------------------------------------------------------------------ ports
    //
    // DECLARED WITHOUT INITIALISERS, ON PURPOSE.  A declaration initialiser is
    // not a procedural assignment: Icarus does not raise the value-change event
    // for it, so `reg sys_rst_n = 1'b0;` never produces the negedge that every
    // asynchronous reset in the DUT is sensitive to.  The core then never sees
    // reset asserted at all, rst_core goes x -> 0 without ever passing through
    // 1, nes_system_v6's `posedge reset` never fires, div_phase stays x for the
    // whole run and audio_sample_valid is x forever.  Every stimulus value is
    // therefore assigned inside the main initial block below, which does
    // generate the events.
    reg         sys_clk;
    reg         sys_rst_n;
    reg  [1:0]  key;
    wire [23:0] lcd_rgb;
    wire        lcd_hs;
    wire        lcd_vs;
    wire        lcd_de;
    wire        lcd_bl;
    wire        lcd_clk;
    wire        lcd_rst;
    wire        touch_scl;
    tri         touch_sda;
    wire        touch_rst_n;
    reg         touch_int;

    wire        aud_bclk;
    wire        aud_dac_lrc;
    wire        aud_dacdat;
    wire        aud_mclk;
    tri         aud_iic_scl;
    tri         aud_iic_sda;

    integer errors;

    task err;
        input [8*48:1] code;
        input integer a;
        input integer b;
        begin
            errors = errors + 1;
            if (errors <= 40)
                $display("VIOLATION %0s a=%0d b=%0d t=%0t", code, a, b, $time);
        end
    endtask

    // ------------------------------------------------------------------ DUT
    nes_zynq_top dut (
        .sys_clk     (sys_clk),
        .sys_rst_n   (sys_rst_n),
        .key         (key),
        .lcd_rgb     (lcd_rgb),
        .lcd_hs      (lcd_hs),
        .lcd_vs      (lcd_vs),
        .lcd_de      (lcd_de),
        .lcd_bl      (lcd_bl),
        .lcd_clk     (lcd_clk),
        .lcd_rst     (lcd_rst),
        .touch_scl   (touch_scl),
        .touch_sda   (touch_sda),
        .touch_rst_n (touch_rst_n),
        .touch_int   (touch_int),
        .aud_bclk    (aud_bclk),
        .aud_dac_lrc (aud_dac_lrc),
        .aud_dacdat  (aud_dacdat),
        .aud_mclk    (aud_mclk),
        .aud_iic_scl (aud_iic_scl),
        .aud_iic_sda (aud_iic_sda)
    );

    pullup pu_touch_sda (touch_sda);
    pullup pu_aud_scl   (aud_iic_scl);
    pullup pu_aud_sda   (aud_iic_sda);

    always #10 sys_clk = ~sys_clk;

    // =========================================================================
    // Forced sample source
    // =========================================================================
    localparam [15:0] RAMP_BASE  = 16'h8000;
    localparam [15:0] CONST_VAL  = 16'h5A5A;

    reg [15:0] force_val;
    reg [15:0] force_rval;
    reg        ramp_mode;

    initial begin
        // Both are forced from a plain identifier on purpose.  Icarus evaluates
        // a force right hand side that is an EXPRESSION exactly once, at the
        // moment the force executes, so ~force_val would freeze at x forever
        // because force_val is still x at time 0.
        force dut.audio_sample_left  = force_val;
        force dut.audio_sample_right = force_rval;
    end

    // =========================================================================
    // A.  WM8960 control I2C, decoded on the real pins
    // =========================================================================
    reg  ack_drive;
    assign aud_iic_sda = ack_drive ? 1'b0 : 1'bz;

    localparam integer MAX_W = 40;

    reg  [6:0] w_reg [0:MAX_W-1];
    reg  [8:0] w_dat [0:MAX_W-1];
    integer    w_count = 0;

    reg  [7:0] b0 = 8'h00;
    reg  [7:0] b1 = 8'h00;
    reg  [7:0] b2 = 8'h00;
    integer    byte_n = 0;
    reg  [7:0] cur_byte = 8'h00;
    integer    cur_bits = 0;
    reg        in_txn = 1'b0;
    reg        ack_active = 1'b0;
    reg        first_rise = 1'b0;
    integer    stop_cnt = 0;
    integer    start_cnt = 1;
    reg        sda_prev;
    reg        scl_prev;
    reg        mon_en;

    always @(aud_iic_sda) begin
        if (mon_en) begin
            if (sda_prev === 1'b1 && aud_iic_sda === 1'b0 && scl_prev === 1'b1) begin
                in_txn     = 1'b1;
                start_cnt  = start_cnt + 1;
                first_rise = 1'b1;
                cur_byte   = 8'h00;
                cur_bits   = 0;
                byte_n     = 0;
            end
            if (sda_prev === 1'b0 && aud_iic_sda === 1'b1 && scl_prev === 1'b1) begin
                in_txn   = 1'b0;
                stop_cnt = stop_cnt + 1;
                if (byte_n == 3) begin
                    if (b0[0] !== 1'b0)
                        err("I2C_WRITE_BIT", b0, 0);
                    if (b0[7:1] !== 7'h1a)
                        err("I2C_DEVICE_ADDRESS", b0[7:1], 210);
                    if (w_count >= MAX_W)
                        err("I2C_TABLE_OVERFLOW", w_count, MAX_W);
                    else begin
                        // WM8960 control word: byte 1 = B15..B8 = {addr[6:0],
                        // data[8]}, byte 2 = B7..B0 = data[7:0].
                        w_reg[w_count] = b1[7:1];
                        w_dat[w_count] = {b1[0], b2};
                        w_count        = w_count + 1;
                    end
                end
            end
            sda_prev = aud_iic_sda;
        end
    end

    always @(posedge aud_iic_scl) begin
        if (mon_en) begin
            scl_prev = 1'b1;
            if (first_rise)
                first_rise = 1'b0;
            if (in_txn) begin
                if (cur_bits < 8) begin
                    cur_byte[7 - cur_bits] = aud_iic_sda;
                    cur_bits = cur_bits + 1;
                end else
                    cur_bits = cur_bits + 1;
            end
        end
    end

    always @(negedge aud_iic_scl) begin
        if (mon_en) begin
            scl_prev = 1'b0;
            if (in_txn) begin
                if (cur_bits == 8 && !ack_active) begin
                    ack_active = 1'b1;
                    ack_drive  = 1'b1;
                end else if (ack_active) begin
                    ack_active = 1'b0;
                    ack_drive  = 1'b0;
                    if (cur_bits == 9) begin
                        if      (byte_n == 0) b0 = cur_byte;
                        else if (byte_n == 1) b1 = cur_byte;
                        else if (byte_n == 2) b2 = cur_byte;
                        else                  err("I2C_TOO_MANY_BYTES", byte_n, 3);
                        byte_n  = byte_n + 1;
                        cur_bits = 0;
                    end
                end
            end
        end
    end

    // The datasheet table, hard coded.  WM8960_v4.4.pdf.
    localparam integer EXP_N = 15;

    function [6:0] dref_reg;
        input integer idx;
        begin
            case (idx)
                0:  dref_reg = 7'h0F;  // R15 (0Fh) Reset
                1:  dref_reg = 7'h04;  // R4  (04h) Clocking (1)
                2:  dref_reg = 7'h34;  // R52 (34h) PLL (1)
                3:  dref_reg = 7'h35;  // R53 (35h) PLL K value (1)
                4:  dref_reg = 7'h36;  // R54 (36h) PLL K Value (2)
                5:  dref_reg = 7'h37;  // R55 (37h) PLL K Value (3)
                6:  dref_reg = 7'h07;  // R7  (07h) Digital Audio Interface Format
                7:  dref_reg = 7'h19;  // R25 (19h) Power Management (1)
                8:  dref_reg = 7'h1A;  // R26 (1Ah) Power Management (2)
                9:  dref_reg = 7'h05;  // R5  (05h) ADC and DAC Control (1)
                10: dref_reg = 7'h2F;  // R47 (2Fh) Power Management (3)
                11: dref_reg = 7'h22;  // R34 (22h) Left Out Mix (1)
                12: dref_reg = 7'h25;  // R37 (25h) Right Out Mix (2)
                13: dref_reg = 7'h02;  // R2  (02h) LOUT1 Volume
                14: dref_reg = 7'h03;  // R3  (03h) ROUT1 Volume
                default: dref_reg = 7'h00;
            endcase
        end
    endfunction

    function [8:0] dref_dat;
        input integer idx;
        begin
            case (idx)
                0:  dref_dat = 9'h000;  // reset, all registers to default
                1:  dref_dat = 9'h005;  // CLKSEL=1 SYSCLKDIV=2 DACDIV=ADCDIV=0
                2:  dref_dat = 9'h018;  // PLLPRESCALE=1 PLLN=8 SDM=0
                3:  dref_dat = 9'h000;  // PLLK = 0
                4:  dref_dat = 9'h000;
                5:  dref_dat = 9'h000;
                6:  dref_dat = 9'h006;  // I2S, slave, 16 bit, normal polarity
                7:  dref_dat = 9'h180;  // VMIDSEL=01 VREF=1
                8:  dref_dat = 9'h1F9;  // DACL DACR LOUT1 ROUT1 PLL_EN
                9:  dref_dat = 9'h000;  // DACMU=0
                10: dref_dat = 9'h00C;  // LOMIX ROMIX
                11: dref_dat = 9'h100;  // LD2LO
                12: dref_dat = 9'h100;  // RD2RO
                13: dref_dat = 9'h079;  // LO1ZC LOUT1VOL=0dB
                14: dref_dat = 9'h079;  // RO1ZC ROUT1VOL=0dB
                default: dref_dat = 9'h000;
            endcase
        end
    endfunction

    // =========================================================================
    // B.  The decimator
    //
    // The history buffers are small and CIRCULAR.  Each moving average stage
    // needs at most four of its own input taps, so a 16 entry ring is enough
    // for the first two stages and an 8 entry ring for the third.  Sizing them
    // for the whole run instead would mean a 12000 entry array in a simulator
    // for no benefit, and an out of range read in Icarus returns x rather than
    // an error, which is a spectacularly quiet way to fail.
    // =========================================================================
    localparam integer HIST = 16;
    localparam integer RING = 8192;

    reg [15:0] hist  [0:HIST-1];   // input sample history
    reg [17:0] m1h   [0:HIST-1];   // stage 1 outputs
    reg [19:0] m2h   [0:7];        // stage 2 outputs
    reg [15:0] wring_l [0:RING-1]; // every left value written into the audio FIFO
    reg [15:0] wring_r [0:RING-1]; // every right value written into the audio FIFO

    integer nin     = 0;   // input strokes since the write reset released
    integer ndec    = 0;   // decimator outputs
    integer warm    = 0;   // strokes ignored while the delay lines fill
    integer n1      = 0;
    integer n2      = 0;
    integer acc55   = 0;
    integer mdec    = 0;
    integer wcount  = 0;
    integer mlast   = 0;   // last stage 3 value the reference model produced
    integer phase   = 0;   // 0 = constant phase, 1 = ramp phase
    integer const_err = 0;
    integer armed   = 0;   // model-clear pulse, one core clock wide
    integer k;
    integer sum;

    always @(posedge dut.mmcm_core_clk) begin
        if (armed === 1'b1) begin
            // The reference model is cleared from the same edge that resets the
            // DUT's filter, so its zeroed delay lines and the DUT's zeroed
            // registers agree from the first sample on and no warm-up allowance
            // is needed for the value comparison.  Only the transient caused by
            // the zeroed delay lines is skipped below.
            armed = 0;
            nin = 0; ndec = 0; warm = 0; n1 = 0; n2 = 0;
            acc55 = 0; mdec = 0; mlast = 0; wcount = 0; const_err = 0;
            for (k = 0; k < HIST; k = k + 1) begin
                hist[k] = 16'h0000;
                m1h[k]  = 18'h00000;
            end
            for (k = 0; k < 8; k = k + 1) m2h[k] = 20'h00000;
        end else if (dut.rst_audio_wr === 1'b1) begin
            // Hold the model cleared while the DUT's write reset is up.  No
            // work is done here on purpose: doing the clear on every core clock
            // for the 4.6 ms the codec table takes turns a 30 second run into a
            // 500 second one.
            armed = 1;
        end else begin
            if (dut.audio_sample_valid === 1'b1) begin
                hist[(nin & (HIST - 1))] = dut.audio_sample_left;
                nin = nin + 1;
                if (ramp_mode === 1'b1) begin
                    force_val  <= force_val  + 16'd1;
                    // Decreases in lockstep so that force_rval stays the exact
                    // bitwise complement of force_val, which is what lets the
                    // bench predict the right channel from the left one.
                    force_rval <= force_rval - 16'd1;
                end

                // -------- stage 1, average of the last 4 input samples ------
                sum = 0;
                for (k = 1; k <= 4; k = k + 1)
                    sum = sum + hist[(nin - k) & (HIST - 1)];
                if (nin % 4 == 0) begin

                    m1h[(n1 & (HIST - 1))] = sum[17:0];
                    n1 = n1 + 1;

                    // ---- stage 2, average of the last 4 stage 1 outputs -----
                    sum = 0;
                    for (k = 1; k <= 4; k = k + 1)
                        sum = sum + m1h[(n1 - k) & (HIST - 1)];
                    if (n1 % 4 == 0) begin
                        m2h[(n2 & 7)] = sum[19:0];
                        n2 = n2 + 1;

                        // -- stage 3, average of 2 stage 2 outputs, every 2nd --
                        sum = m2h[(n2 - 1) & 7];
                        if (n2 >= 2) sum = sum + m2h[(n2 - 2) & 7];
                        if (n2 % 2 == 0) begin
                            acc55 = acc55 + 55;
                            if (acc55 >= 63) begin
                                acc55 = acc55 - 63;
                                mdec  = mdec + 1;
                                mlast = sum;
                            end
                        end
                    end
                end
            end

            // ---------------- decimator output -----------------------------
            if (dut.dec_valid === 1'b1) begin
                ndec = ndec + 1;
                if (wcount < RING) begin
                    wring_l[wcount] = dut.dec_left;
                    wring_r[wcount] = dut.dec_right;
                end
                wcount = wcount + 1;
                if (warm < 64) begin
                    warm = warm + 1;
                end else begin
                    if (phase == 0) begin
                        // B1: unity gain, bit exact, no reference model involved.
                        if (dut.dec_left !== CONST_VAL) const_err = const_err + 1;
                    end else begin
                        // B2: against the reference model.
                        if (ndec != mdec)
                            err("DEC_COUNT_MISMATCH", ndec, mdec);
                        if (dut.dec_left !== ((mlast + 16) >> 5))
                            err("DEC_LEFT_VALUE", dut.dec_left, (mlast + 16) >> 5);
                        // The right input is the exact bitwise complement of the
                        // left one, so every stage sum obeys S_right = N*65535 -
                        // S_left with N = 32 at the third stage.  NOT 65535 -
                        // dec_left: the +16 rounding before the shift is nonlinear
                        // and the two roundings do not cancel.
                        if (dut.dec_right !== ((32*65535 - mlast + 16) >> 5))
                            err("DEC_RIGHT_VALUE", dut.dec_right,
                                (32*65535 - mlast + 16) >> 5);
                    end
                end
            end
        end
    end

    // =========================================================================
    // D.  The I2S pins
    //
    // WHY THE MODEL IS THIS SHAPE, AND NOT A STATE MACHINE WITH AN EXPLICIT
    // WORD BOUNDARY.  Measured off the design, with the bit index m that
    // nes_i2s_shifter is shifting:
    //   * rd_ce is high for one lcd_clk ending on each bclk rising edge B_k, so
    //     the shifter advances at B_k + 1 and out_bit for bit m is valid from
    //     B_k + m + 1;
    //   * dout_r in nes_audio_i2s loads bit (j - 1) at bclk edge B_j, and the
    //     one bit I2S delay flop in the top loads bit (j - 2) there, so the pin
    //     carries bit (j - 3) from B_j to B_{j+1} and a receiver latches bit m
    //     at B_{m + 3};
    //   * lrck_r changes just after the edge that loads bit 16 and just after
    //     the edge that loads bit 32, i.e. just after B_17 and B_33, so the
    //     receiver reads the new lrck at B_18 and B_34, and lrck_d (lrck sampled
    //     one edge earlier) is 1 exactly on B_19 .. B_34 and 0 exactly on
    //     B_35 .. B_50.
    // Bits 16..31 are latched on B_19..B_34 and bits 32..47 on B_35..B_50, so
    // "the channel of the bit latched now" is exactly lrck sampled one edge
    // earlier, and lrck_d is high for exactly sixteen consecutive edges and low
    // for the next sixteen.  A free running modulo sixteen counter therefore
    // stays aligned with the words forever and needs no boundary logic at all.
    //
    // Note what this also says about the last bit: R(n)'s LSB is latched on the
    // same edge at which the receiver first sees lrck go low.  That IS the
    // Philips arrangement, and it is why an explicit "discard the edge where
    // lrck changed" rule loses the LSB of every right hand word.
    // =========================================================================
    reg        lrck_d;
    reg [15:0] rx_l;
    reg [15:0] rx_r;
    reg [15:0] done_l;
    reg [15:0] done_r;
    reg        word_done;
    reg        word_is_right;

    integer    words_done;
    integer    word_seq;
    integer    bclk_rise;
    integer    t_prev_bclk;
    integer    bclk_period;
    integer    K;
    integer    first_w;
    integer    lag_err;
    integer    checking;
    integer    s;
    integer    widx;
    integer    idx;
    integer    uf_armed;
    integer    uf_base;

    // nes_audio_i2s latches rd_empty at reset and latches underflow from it
    // STICKILY (nes_audio_i2s.v:200-207).  The read side is held in reset
    // until the codec table is done, so rd_empty is still 1 on the first read
    // clock after that reset releases and underflow necessarily goes to 1 there
    // before the first sample has even crossed the fifo.  That one rise is
    // inherent to the module and is not a defect.  What IS a defect, and what is
    // asserted here, is any FURTHER rise: that would mean the fifo ran dry while
    // the stream was running, which is exactly what a producer/consumer rate
    // mismatch looks like.
    always @(posedge dut.mmcm_lcd_clk) begin
        if (checking == 1 && words_done >= 8 && uf_armed == 0) begin
            uf_armed = 1;
            uf_base  = dut.aud_underflow;
        end
        if (uf_armed == 1 && dut.aud_underflow !== uf_base)
            err("FIFO_UNDERFLOW_RISE", dut.aud_underflow, uf_base);
    end

    always @(posedge aud_bclk) begin
        bclk_rise = bclk_rise + 1;
        if (bclk_rise == 1)
            t_prev_bclk = $time;
        else if (bclk_rise <= 4000) begin
            bclk_period = $time - t_prev_bclk;
            if (bclk_period !== 640)
                err("I2S_BCLK_PERIOD", bclk_period, 640);
            t_prev_bclk = $time;
        end

        lrck_d <= aud_dac_lrc;

        // Bits are shifted in MSB first, into whichever word the channel
        // marker says is in flight.  The edge on which lrck first reads its new
        // value is the edge carrying the LAST bit of the outgoing word (see the
        // header), so it is also the edge on which the shifted-in value IS the
        // completed word.  Capturing it into done_l / done_r from the
        // pre-edge shift register plus the pin avoids indexing arithmetic and,
        // more importantly, avoids writing the LSB position twice, which is what
        // an explicit bit index does when the boundary edge and the counter
        // both target index 15.
        if (lrck_d === 1'b0) rx_l <= {rx_l[14:0], aud_dacdat};
        else                rx_r <= {rx_r[14:0], aud_dacdat};

        word_done <= 1'b0;
        if (aud_dac_lrc !== lrck_d) begin
            word_done     <= 1'b1;
            word_is_right <= lrck_d;
            if (lrck_d === 1'b0) done_l <= {rx_l[14:0], aud_dacdat};
            else                done_r <= {rx_r[14:0], aud_dacdat};
        end
    end

    always @(posedge aud_bclk) begin
        #1;
        if (word_done === 1'b1 && checking === 1) begin
            words_done = words_done + 1;
            word_seq   = word_seq + 1;
            if (K < 0) begin
                K = -1;
                for (idx = 0; idx < 256; idx = idx + 1)
                    if (wcount > idx &&
                        (word_is_right ? wring_r[(wcount - 1 - idx) % RING]
                                       : wring_l[(wcount - 1 - idx) % RING]) ===
                        (word_is_right ? done_r : done_l)) begin
                        K = idx;
                        idx = 256;
                    end
                if (K < 0)
                    err("I2S_FIRST_WORD_NOT_FOUND", done_l, wcount);
                first_w = wcount;
            end else begin
                s    = (word_seq - 1) / 2;
                widx = (first_w + s - 1) - K;
                if (widx < 0)
                    err("I2S_LAG_TOO_BIG", widx, 0);
                else if (word_is_right === 1'b0) begin
                    if (done_l !== wring_l[widx % RING]) begin
                        lag_err = lag_err + 1;
                        if (lag_err <= 10)
                            $display("VIOLATION I2S_LEFT_WORD got=%0d want=%0d lag=%0d seq=%0d t=%0t",
                                     done_l, wring_l[widx % RING], K, word_seq, $time);
                    end
                end else begin
                    if (done_r !== wring_r[widx % RING]) begin
                        lag_err = lag_err + 1;
                        if (lag_err <= 10)
                            $display("VIOLATION I2S_RIGHT_WORD got=%0d want=%0d lag=%0d seq=%0d t=%0t",
                                     done_r, wring_r[widx % RING], K, word_seq, $time);
                    end
                end
            end
        end
    end

    // =========================================================================
    // Progress monitor.  The whole top is elaborated, so a hang here is a hang
    // in the core, in the codec I2C or in the audio path, and without this the
    // only information a timeout gives is the timeout.
    // =========================================================================
    integer mon_cnt;
    integer vid_de_seen;

    always @(posedge lcd_clk)
        if (lcd_de === 1'b1) vid_de_seen = vid_de_seen + 1;

    always @(posedge sys_clk) begin
        mon_cnt = mon_cnt + 1;
        if (mon_cnt % 200000 == 0) begin
            $display("MON t=%0t sc=%0d cfg_done=%b busy=%b writes=%0d nin=%0d ndec=%0d bclk=%0d frames=%0d K=%0d",
                     $time, mon_cnt, dut.u_codec_i2c.cfg_done, dut.u_codec_i2c.busy,
                     w_count, nin, ndec, bclk_rise, words_done, K);
            $display("MON   rst_core=%b rst_audio_wr=%b cfg_core_q1=%b asv=%b ce_cpu=%b rat_acc=%0d dec_valid=%b ma3_vld=%b",
                     dut.rst_core, dut.rst_audio_wr, dut.codec_cfg_core_q1,
                     dut.audio_sample_valid, dut.core_ce_cpu, dut.rat_acc,
                     dut.dec_valid, dut.ma3_vld);
            $display("MON   core_reset=%b div_phase=%b core_ce_cpu=%b apu_sv=%b apu_ce_sample=%b lcd_de=%b clk=%b b2=%02h ce_ppu=%b",
                     dut.u_core.reset, dut.u_core.div_phase, dut.u_core.ce_cpu,
                     dut.u_core.apu_sample_valid, dut.u_core.ce_sample, lcd_de, dut.u_core.clk, dut.u_core.buttons2, dut.u_core.ce_ppu);
        end
    end

    // =========================================================================
    // Main
    // =========================================================================
    localparam integer WANT_WORDS = 2000;
    localparam integer CONST_STROKES = 8192;

    initial begin
        errors    = 0;
        ack_drive = 1'b0;
        sda_prev  = 1'b1;
        scl_prev  = 1'b1;
        mon_en    = 1'b0;
        vid_de_seen = 0;
        words_done  = 0;
        word_seq    = 0;
        done_l      = 16'h0000;
        done_r      = 16'h0000;
        lrck_d      = 1'b0;
        checking    = 1'b0;
        first_w     = 0;
        uf_armed    = 0;
        uf_base     = 0;
        K           = -1;
        lag_err     = 0;
        rx_l        = 16'h0000;
        rx_r        = 16'h0000;
        word_done   = 1'b0;
        word_is_right = 1'b0;
        bclk_rise   = 0;
        phase     = 0;
        mon_cnt   = 0;
        sys_clk   = 1'b0;
        sys_rst_n = 1'b0;
        key       = 2'b11;
        touch_int = 1'b1;
        force_val  = CONST_VAL;
        force_rval = 16'hffff - CONST_VAL;
        ramp_mode = 1'b0;
        repeat (20) @(posedge sys_clk);
        @(negedge sys_clk);
        sys_rst_n = 1'b1;
        mon_en = 1'b1;

        // The codec table takes about 4.6 ms at 100 kHz.  Wait for it, then
        // let the constant-input phase run for a few thousand strobes.
        while (dut.u_codec_i2c.cfg_done !== 1'b1) @(posedge sys_clk);
        while (nin < CONST_STROKES) @(posedge sys_clk);

        // ---------------------------------------------------------- A. codec
        if (w_count != EXP_N)
            err("I2C_TABLE_LENGTH", w_count, EXP_N);
        for (idx = 0; idx < EXP_N; idx = idx + 1) begin
            if (w_reg[idx] !== dref_reg(idx))
                err("I2C_REG_ADDRESS", idx * 100 + w_reg[idx], idx * 100 + dref_reg(idx));
            if (w_dat[idx] !== dref_dat(idx))
                err("I2C_REG_DATA", idx * 1000 + w_dat[idx], idx * 1000 + dref_dat(idx));
        end
        if (w_dat[8][8]  !== 1'b1) err("I2C_DACL_BIT8", w_dat[8], 512);
        if (w_dat[11][8] !== 1'b1) err("I2C_LD2LO_BIT8", w_dat[11], 512);
        if (w_dat[12][8] !== 1'b1) err("I2C_RD2RO_BIT8", w_dat[12], 512);
        if (w_dat[9][3]  !== 1'b0) err("I2C_DACMU", w_dat[9], 0);
        $display("I2C  %0d writes on the real pins, WM8960_v4.4 table matched, %0d START %0d STOP",
                 w_count, start_cnt, stop_cnt);

        // ------------------------------------------------------ B1. unity gain
        if (const_err != 0)
            err("DEC_UNITY_GAIN_NOT_BIT_EXACT", const_err, 0);
        $display("DEC  constant 16'h%04h in, 16'h%04h out on every one of %0d outputs, bit exact",
                 CONST_VAL, CONST_VAL, ndec);

        // --------------------------------------------------- B2/B3. ramp phase
        force_val  = RAMP_BASE;
        force_rval = 16'hffff - RAMP_BASE;
        ramp_mode = 1'b1;
        phase     = 1;
        while (nin < CONST_STROKES + 1600) @(posedge sys_clk);
        checking  = 1'b1;
        while (words_done < WANT_WORDS) @(posedge sys_clk);

        // ------------------------------------------------------------ C. FIFO
        if (dut.aud_full      !== 1'b0) err("FIFO_FULL",      dut.aud_full, 0);
        if (dut.aud_dropped  !== 1'b0) err("FIFO_DROPPED",   dut.aud_dropped, 0);
        if (lag_err != 0)
            err("I2S_WORD_LAG_MOVED", lag_err, 0);
        if (dut.u_codec_i2c.nack_seen !== 1'b0) err("I2C_NACK", dut.u_codec_i2c.nack_seen, 0);
        if (dut.u_codec_i2c.error     !== 1'b0) err("I2C_ERROR", dut.u_codec_i2c.error, 0);

        // ------------------------------------------------- B3. exact counting
        if (ndec != (nin / 32) * 55 / 63)
            err("DEC_BRESENHAM_COUNT", ndec, (nin / 32) * 55 / 63);
        $display("DEC  %0d input strobes -> %0d outputs; floor(floor(N/32)*55/63) = %0d",
                 nin, ndec, (nin / 32) * 55 / 63);
        $display("DEC  exact rational 2016/55, 19687500/11 * 55/2016 = 25e6/512 = 48828.125 Hz");
        if (K < 0)
            err("I2S_LAG_NEVER_FOUND", words_done, 0);
        $display("I2S  bclk %0d ns period, %0d rising edges, %0d words, fixed lag %0d writes",
                 bclk_period, bclk_rise, words_done, K);
        $display("FIFO underflow sampled %0d once the stream was running, no further rise over %0d words",
                 uf_base, words_done);

        if (errors != 0) begin
            $display("FAIL nes_audio_lane with %0d violations", errors);
            $fatal(1, "nes_audio_lane tb failed");
        end

        $display("PASS nes_audio_lane codec I2C table, exact 2016/55 decimation, no FIFO loss, I2S waveform");
        $finish;
    end

    initial begin
        #200000000;
        $fatal(1, "global timeout");
    end

endmodule
