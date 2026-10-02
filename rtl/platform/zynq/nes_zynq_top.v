`timescale 1ns/1ps

// ============================================================================
// nes_zynq_top : Zynq-7020 platform top for the NES emulator
// ----------------------------------------------------------------------------
// This is the wiring layer.  Every block below it is built and gated on its own;
// the job here is to connect them and to own exactly the two things no submodule
// can own: the clock tree and the reset network.
//
// CLOCK DOMAINS, three, and nothing crosses between core_clk and lcd_clk except
// the pixels and the audio sample stream.  25 MHz is not an integer multiple of
// 21.477 MHz, so the panel output stage cannot be clocked from the core with a
// clock enable: pixel data must leave on real 25 MHz edges.
//
//   sys_clk   50 MHz, board pin U18
//       nes_touch_input                     clk = sys_clk, reset = rst_sys
//       wm8960_i2c codec configuration      clk = sys_clk, reset = rst_sys
//       lcd_rst / lcd_bl power-on counter   clk = sys_clk
//       locked synchroniser stage 1         clk = sys_clk
//   core_clk  21.477272727 MHz, MMCM CLKOUT1
//       nes_system_v6                       clk = core_clk, reset = rst_core
//       nes_cart_rom, CHR half only         clk = core_clk, reset = rst_core
//       audio decimation filter             clk = core_clk, reset = rst_audio_wr
//       palette LUT (combinational)         pixel_pal[5:0] -> RGB565
//       nes_video_800x480 write port        wr_clk = core_clk, reset = rst_core
//   lcd_clk   25 MHz, MMCM CLKOUT0
//       nes_video_800x480 read port         rd_clk = lcd_clk, reset = rst_lcd
//       nes_audio_i2s read side and bclk    rd_clk = mclk = lcd_clk
//       RGB565 -> RGB888 expansion          combinational
//       lcd_de / lcd_hs / lcd_vs / lcd_rgb  panel pins
//       aud_mclk                            = mmcm_lcd_clk, see AUDIO LANE
//
// The cross-domain boundaries, three of them now:
//   1. touch buttons: sys_clk -> core_clk, a 2-flop synchroniser.  The core
//      samples a controller port and cannot tolerate a metastable bit.
//   2. frame_mem inside nes_video_800x480: core_clk write port, lcd_clk read
//      port.  This is a true simple-dual-port RAM, so the crossing costs no
//      logic at all: no synchroniser, no toggle, no handshake, no backpressure.
//   3. the audio sample FIFO inside nes_audio_i2s: core_clk write port, lcd_clk
//      read port.  Same primitive as 2 but a real dual-clock FIFO with Gray
//      coded pointers and two-flop synchronisers, so unlike 2 it does contain
//      core_clk -> lcd_clk flip-flop arcs.  They are bounded with
//      set_max_delay -datapath_only in the XDC, for the reason documented
//      there for the touch buttons.
//
// AUDIO LANE
//   The audio path is core_clk -> decimator -> nes_audio_i2s FIFO -> I2S
//   shifter -> wm8960_i2c -> WM8960 pins.  Four things in it are not obvious
//   and each is derived in place.
//
//   1. audio_sample_valid IS NOT AN AUDIO SAMPLE RATE.
//      nes_system_v6.v:186 sets ce_sample = 1'b1 and nes_apu2a03.v:739 fires
//      sample_valid on ce && ce_sample with ce = ce_cpu, which is one core
//      clock in twelve.  So the strobe rate is
//          21477272.727 / 12 = 1789772.727 Hz
//      That is the APU's natural rate, about 37x anything usable.  Feeding it
//      straight into an I2S shifter would serialise noise at 1.79 MHz.
//
//   2. THE DECIMATOR, AND WHY 37 IS NOT USABLE.
//      The obvious choice, take every 37th sample, gives
//          1789772.727 / 37 = 48372.235 Hz, which is 101/13024 = 0.7755
//      percent above 48000 Hz.  The error is the problem, not the audio: the
//      FIFO between the decimator and the I2S shifter has one producer and one
//      consumer, so a rate mismatch of any size at all makes the level walk
//      until the FIFO is permanently full (dropped) or permanently empty
//      (underflow).  A 0.78 percent mismatch drains or fills a 1024 entry FIFO
//      in about 26 seconds.  An "acceptable" sample rate error is not an
//      option here.
//
//      The only integer decimation that is exactly matched to a usable I2S
//      frame rate is /126 at 14204 Hz, which is a 7.1 kHz Nyquist and barely
//      better than a telephone line.  The arithmetic: nes_i2s_shifter emits
//      16 + 16 bits per stereo sample, one per BCLK, so a frame is 32 BCLK
//      and the frame rate is 25e6/(32*D) for BCLK_DIV = D.  The ratio to the
//      strobe rate is then
//          (19687500/11) * (32*D/25000000) = 126*D/55.
//      For that to be an integer, 55 must divide D, so D = 55 is the only
//      possibility and it gives 14204.5 Hz.  D = 16, the sane choice, gives
//          126*16/55 = 2016/55 = 36.6545454...
//      which is not an integer.  So the decimation is a RATIONAL 2016/55,
//      implemented as an exact Bresenham accumulator: 2016 input samples in,
//      55 output samples out, forever, with no accumulating error because the
//      accumulator is a bounded integer whose state depends only on the count
//      of samples seen.
//
//   3. WHY THERE IS NO /37 ANYWHERE, AND WHAT FILTERS INSTEAD.
//      A fixed-length box filter of N input samples has unity gain only if it
//      is divided by N, and N must then be an integer.  With a rational ratio
//      the number of samples averaged alternates between 1 and 2 and a fixed
//      gain cannot exist, so the usual "average 37 then take every 37th" is
//      both impossible here and, at that length, useless as a filter: a
//      37-tap moving average has its first null at 1789772/37 = 48.4 kHz, so
//      it attenuates nothing in the 24 kHz band that actually aliases into the
//      output.  What is used instead is three short moving averages in series,
//      4, 4 and 2 taps, followed by the rational step.  Their nulls land at
//      447 kHz, 447 kHz and 894 kHz, all inside the input band and well above
//      the audio band, so the cascade is flat to within 0.35 dB at the frame
//      rate and about -33 dB at 700 kHz while still having exactly unity DC
//      gain: each stage sums K samples and the final divide is by 4*4*2 = 32.
//      The peak attenuation of the cascade is bounded by the null at 894 kHz
//      and the side lobes around it, and it is NOT a complete anti-alias
//      filter.  Getting -40 dB flat to 20 kHz out of a 36.65:1 decimation
//      needs a proper 16-tap FIR at 1.79 MHz, which is a separate piece of
//      work and is not here.  What is here removes the worst of the images
//      for about 300 flip-flops and zero DSP.
//
//   4. rd_clk AND mclk ARE THE SAME NET, ON PURPOSE.
//      nes_audio_i2s.v:241-249 samples sh_out_bit and sh_out_lrck on
//      posedge bclk with no synchroniser, crossing from the rd_clk domain into
//      the mclk-derived domain.  If mclk and rd_clk were unrelated nets that
//      would be an unsynchronised two-bit crossing.  Driving both from
//      mmcm_lcd_clk makes bclk a divided version of the same clock, so the
//      sampling edge is phase related to the driving edge and each bit is
//      stable for a whole BCLK period, which is eight lcd_clk.  It also means
//      the read side is in the lcd_clk domain and NOT a new one, and that
//      mclk is not a new clock at all: it is the net the MMCM already drives.
//
//   5. THE CODEC FREQUENCY PLAN, AND WHY NO THIRD MMCM OUTPUT IS NEEDED.
//      With mclk = 25 MHz and the shifter a slave, BCLK comes from BCLK_DIV and
//      a frame is 32 BCLK, so
//          BCLK_DIV = 16 -> BCLK = 1.5625 MHz, fs = 48828.125 Hz
//      and that is EXACTLY 1789772.727 * 55/2016, so the producer and the
//      consumer agree to the last bit and the FIFO level cannot walk.  The
//      WM8960 is told to sample at 48828.125 Hz by its own PLL, from the 25 MHz
//      on MCLK:
//          f1    = 25 / 2^PLLPRESCALE = 25 / 2 = 12.5 MHz
//          R     = PLLN + PLLK/2^24   = 8 + 0    = 8
//          f2    = R * f1             = 100 MHz      (PLL VCO)
//          SYSCLK= f2 / (4 * 2)       = 12.5 MHz
//          fs    = SYSCLK / 256       = 48828.125 Hz
//      f2 sits on the upper edge of the datasheet's "performs best between
//      90MHz and 100MHz" and PLLN = 8 is its "stability peaks at N=8" case,
//      with PLLK = 0 so there is no fractional divider jitter at all.  The
//      alternative of a third MMCM output at 12.288 MHz would give an exact
//      48 kHz and would need no PLL, but it re-opens the core clock
//      derivation, whose only job is to hit 21.477272727 MHz exactly, and it
//      buys 0.78 percent of sample rate that nothing in this design requires.
//      See wm8960_i2c.v for the register-by-register citation.
//
//   6. THE PINES.
//      aud_bclk, aud_dac_lrc and aud_dacdat are outputs; aud_mclk is an output
//      because it is the mmcm_lcd_clk net leaving the chip.  aud_iic_scl and
//      aud_iic_sda are a genuine inout pair, open drain, shared with the board
//      EEPROM and RTC.  aud_adc_lrc (L20) and aud_adcdat (M17) have no
//      counterpart in nes_audio_i2s.v, which is transmit only, so they are
//      NOT declared as ports here and are NOT constrained; the ADC path is not
//      invented.  The pins are left as they were, connected to nothing.
//
// CHR MEMORY IS NOT IN THE CORE
//   chr_rdata is an INPUT of nes_system_v6.  A CHR-only nes_cart_rom sits above
//   the core with PRG_ENABLE(0) CHR_ENABLE(1): its ce_ppu is the core's exported
//   ce_ppu and its chr_rdata drives the core's chr_rdata port.  The core
//   instantiates the same module a second time for PRG only, with
//   CHR_ENABLE(0), so the 8 KiB CHR array is not built twice.
//   ce_ppu is used verbatim.  nes_system_v6 drives
//       ce_ppu = !reset && (div_phase[1:0] == 2'b00)
//   and div_phase is NOT regenerated here.  nes_cart_rom's CHR read path is
//   phase sensitive by design (nes_cart_rom.v header, CHR READ LATENCY): a
//   regenerated div_phase one to three beats out of phase latches chr_addr on
//   the wrong ce_ppu edge and returns the previous pattern byte, silently.
//
// NO SECOND nes_controller
//   nes_system_v6 owns the whole $4016/$4017 shift sequence internally
//   (nes_system_v6.v:384-394 latch_strobe_q / ctrl_read_strobe, controller_data
//   muxed into cpu_din at :382).  buttons1 is fed straight in.  A second
//   instance would double-drive controller_data and break every controller
//   read.  buttons2 is tied to 8'h00: there is no player 2.
//
// PALETTE
//   pixel_pal[7:0] is the raw byte the PPU stores; bits [5:4] are the colour
//   axis and [3:0] the luminance axis, so only [5:0] indexes a palette.  The 64
//   entries are the cNES reference table at
//   .slim/clonedeps/repos/caseif__cNES/src/ppu.c:94-111, which is
//   typedef struct { uint8_t r; uint8_t g; uint8_t b; } RGBValue  (ppu.h), so
//   each triple is (r, g, b) and the table is four rows of sixteen indexed by
//   {colour, luminance}.  Each RGB888 triple is converted to RGB565 by
//   R5 = R8 >> 3, G6 = G8 >> 2, B5 = B8 >> 3, so the red channel lands in
//   rgb565[15:11], green in [10:5] and blue in [4:0].
//   nes_line_buffer_vga.v:54-69 is NOT reused: that is a hue sweep, not the NES
//   palette, and it would render Mario in rainbow colours.
//
// RGB565 -> RGB888
//   nes_video_800x480 passes its 16-bit word through untouched, so
//   rgb565[15:11] is red.  Each channel is widened to 8 bits by appending as
//   many of its own MSBs as are needed: {r5, r5[4:2]} and {b5, b5[4:2]} from five
//   bits, {g6, g6[5:4]} from six.  That is full-scale replication, so white
//   stays white and the panel is not dimmed.  Red lands in lcd_rgb[23:16].
//
// PANEL RESET AND BACKLIGHT
//   The vendor never resets the panel: lcd_driver.v:132 is
//       assign lcd_rst = 1'b1;
//   which on this panel means "held out of reset".  lcd_rst is therefore active
//   high and driven low here for LCD_RST_HOLD_CYCLES sys_clk after sys_rst_n
//   releases, then high.  lcd_bl is the vendor's constant 1 replaced with a
//   real counter (lcd_driver.v:130), asserted later than the panel reset
//   completes, so the backlight never comes up on an unreset panel.
//
// RESET NETWORK
//   The board pin sys_rst_n is active low.  Each domain gets its own chain:
//   asynchronous assertion on !sys_rst_n, synchronous release through two
//   flops, ANDed with a two-flop synchroniser of the MMCM's locked for that
//   same domain.  No reset register is shared between domains.  core_clk and
//   lcd_clk only run after the MMCM locks, so their async-asserted flops simply
//   hold the reset until their clock starts, which is exactly the required
//   behaviour: the core must not come out of reset onto a clock that is still
//   slewing.  Idiom follows rtl/platform/ep4ce10/nes_ep4ce10_top.v:98-121.
//
//   The audio lane adds one more per-domain qualifier on top of that chain.
//   wm8960_i2c walks its 15-entry power-on table on sys_clk and raises
//   cfg_done when the table is exhausted, about 4.6 ms after reset release at
//   100 kHz.  Neither end of the audio FIFO may run before that, because
//   nes_audio_i2s.v:200-207 latches rd_empty at reset and latches underflow
//   from it STICKILY, so a read side released early would report underflow for
//   the rest of the run no matter how well the stream behaved afterwards, and
//   the read side would emit BCLK into a codec that is still in its
//   power-on default state.  So cfg_done is synchronised into each domain with
//   its own two flops and ORed into the reset, exactly as locked is:
//     rst_audio_wr = rst_core | ~codec_cfg_core_q1
//     rst_audio_rd = rst_lcd  | ~codec_cfg_lcd_q1
//   Both are active high and both assert asynchronously on !sys_rst_n, because
//   they inherit it from the term they are ORed with.
//
// ROM FILES

//
// TWO PL keys are not a controller and are wired to the touch module's
// key0/key1, which handles their active-low polarity and debouncing.
// ============================================================================

module nes_zynq_top #(
    // sys_clk cycles the panel reset pin is held low before release.
    // 5000 cycles = 100 us at 50 MHz, far longer than any panel needs.
    parameter integer LCD_RST_HOLD_CYCLES = 5000,
    // sys_clk cycles before the backlight is asserted.
    // 20000 cycles = 400 us, so it comes up after the reset pulse has finished
    // and the panel has had time to settle.
    parameter integer LCD_BL_ON_CYCLES   = 20000,
    // CHR_INIT_FILE and PRG_INIT_FILE are parameters so an integrator that
    // relocates the tree, or a throwaway synthesis tree, can point them at a
    // real cartridge image.  Both defaults are the committed placeholders, so
    // every existing instance, and the committed gate, is byte-for-byte
    // unchanged: the defaults are what $readmemh reads.
    //
    // A $readmemh that cannot find its file, or that finds a file of the wrong
    // length, leaves the array partly uninitialised and Vivado then optimises
    // it away SILENTLY: the Block RAM Tile count falls from 50 to 0 and the
    // design still meets timing and still places all 44 pins.  A bitstream built
    // that way looks perfect and carries no cartridge.  tb_nes_zynq_top.v
    // asserts the CHR array holds non-constant content; for a synthesis build
    // the equivalent check is that report_utilization reports 50 Block RAM
    // Tiles and not 0.
    //
    // NEITHER PATH IS RELOCATABLE BY ITSELF.  $readmemh resolves a relative path
    // against the SIMULATOR'S OR VIVADO'S WORKING DIRECTORY, not against this
    // source file's own directory, so a relative default only resolves when the
    // tool is launched from the repository root.  tools/sim_all.ps1 does
    // Push-Location to the repository root for exactly that reason.
    //
    // The PRG half lives inside nes_system_v6, which instantiates nes_cart_rom
    // with PRG_ENABLE(1) itself; PRG_INIT_FILE below is forwarded to
    // nes_system_v6's own PRG_INIT_FILE, which forwards it again to that
    // instance.  The CHR half lives here, in the u_cart_chr instance below,
    // because nes_system_v6 has CHR_ENABLE(0) on its own instance and therefore
    // contains no CHR array at all.  So the two paths reach their $readmemh
    // from opposite ends of the hierarchy and both must be overridden to build
    // a real cartridge.
    parameter         PRG_INIT_FILE       = "rtl/nes_core/cart/prg_placeholder.hex",
    parameter         CHR_INIT_FILE       = "rtl/nes_core/cart/chr_placeholder.hex"
) (
    input  wire        sys_clk,
    input  wire        sys_rst_n,
    // The two PL keys, active low on the board.  nes_touch_input debounces them
    // and owns their polarity; it drives A/B or Select/Start depending on
    // whether the touch panel is being used.
    input  wire [1:0]  key,
    // Genuinely bidirectional: the vendor reads the panel ID back over these
    // pins (lcd_rgb_char.v:54).  Tri-stated whenever lcd_de is low.
    inout  wire [23:0] lcd_rgb,
    output wire        lcd_hs,
    output wire        lcd_vs,
    output wire        lcd_de,
    output wire        lcd_bl,
    output wire        lcd_clk,
    // Active high, held low during power-on reset then released.  See header.
    output wire        lcd_rst,
    // I2C is open drain: the controller pulls low and releases, the panel pulls
    // low in an ACK.  A push-pull output would break the bus.
    inout  wire        touch_scl,
    inout  wire        touch_sda,
    output wire        touch_rst_n,
    input  wire        touch_int,
    // ------------------------------------------------------------- audio lane
    // I2S bit clock to the WM8960.  Derived from mmcm_lcd_clk inside
    // nes_audio_i2s, so this is a pure output and its period is
    // 25 MHz / BCLK_DIV = 3.125 MHz.
    output wire        aud_bclk,
    // DAC word clock, i.e. I2S LRCLK.  Low is the left channel.
    output wire        aud_dac_lrc,
    // DAC data, one bit, sampled by the codec on the rising edge of BCLK.
    output wire        aud_dacdat,
    // Codec master clock INPUT to the WM8960, which is why this is an output
    // here: it is the mmcm_lcd_clk net leaving the chip.  25 MHz, not
    // 12.288 MHz; the codec's own PLL turns it into SYSCLK.  See the AUDIO LANE
    // block in the header for the arithmetic.
    output wire        aud_mclk,
    // Codec control I2C.  Open drain in both directions, and SHARED with the
    // board EEPROM and RTC, so only one master may drive it at a time.  Not
    // the same pins as touch_scl / touch_sda, which are R19 / P20.
    inout  wire        aud_iic_scl,
    inout  wire        aud_iic_sda
);

    // ------------------------------------------------------------------ 复位
    // rst_sys / rst_core / rst_lcd are ACTIVE HIGH (1 = in reset).
    // Async assert on !sys_rst_n, sync release, ANDed with the per-domain
    // two-flop synchroniser of the MMCM locked.
    // MAX_FANOUT: without it opt_design leaves ONE flop driving the whole
    // domain's asynchronous clear.  Measured on the routed design this was
    // rst_core_q[1]/C -> */CLR at 9.4..10.3 ns, about 94% routing, one logic
    // level, hundreds of endpoints: a 32k-load net pushed through one LUT2.
    // 32 makes opt_design replicate the driver and build a reset tree instead.
    // It is a synthesis directive only; it does not change behaviour and it is
    // not a timing exception.
    (* MAX_FANOUT = 32 *) reg [1:0] rst_sys_q;
    (* MAX_FANOUT = 32 *) reg [1:0] rst_core_q;
    (* MAX_FANOUT = 32 *) reg [1:0] rst_lcd_q;

    reg locked_sys_q0;
    reg locked_sys_q1;
    reg locked_core_q0;
    reg locked_core_q1;
    reg locked_lcd_q0;
    reg locked_lcd_q1;

    always @(posedge sys_clk or negedge sys_rst_n) begin
        if (!sys_rst_n)
            rst_sys_q <= 2'b11;
        else
            rst_sys_q <= {rst_sys_q[0], 1'b0};
    end

    always @(posedge mmcm_core_clk or negedge sys_rst_n) begin
        if (!sys_rst_n)
            rst_core_q <= 2'b11;
        else
            rst_core_q <= {rst_core_q[0], 1'b0};
    end

    always @(posedge mmcm_lcd_clk or negedge sys_rst_n) begin
        if (!sys_rst_n)
            rst_lcd_q <= 2'b11;
        else
            rst_lcd_q <= {rst_lcd_q[0], 1'b0};
    end

    always @(posedge sys_clk or negedge sys_rst_n) begin
        if (!sys_rst_n) begin
            locked_sys_q0 <= 1'b0;
            locked_sys_q1 <= 1'b0;
        end else begin
            locked_sys_q0 <= mmcm_locked;
            locked_sys_q1 <= locked_sys_q0;
        end
    end

    always @(posedge mmcm_core_clk or negedge sys_rst_n) begin
        if (!sys_rst_n) begin
            locked_core_q0 <= 1'b0;
            locked_core_q1 <= 1'b0;
        end else begin
            locked_core_q0 <= mmcm_locked;
            locked_core_q1 <= locked_core_q0;
        end
    end

    always @(posedge mmcm_lcd_clk or negedge sys_rst_n) begin
        if (!sys_rst_n) begin
            locked_lcd_q0 <= 1'b0;
            locked_lcd_q1 <= 1'b0;
        end else begin
            locked_lcd_q0 <= mmcm_locked;
            locked_lcd_q1 <= locked_lcd_q0;
        end
    end

    wire rst_sys  = rst_sys_q[1]  | ~locked_sys_q1;
    wire rst_core = rst_core_q[1] | ~locked_core_q1;
    wire rst_lcd  = rst_lcd_q[1]  | ~locked_lcd_q1;

    // ------------------------------------------------- 音频域复位限定 (cfg_done)
    // wm8960_i2c raises cfg_done on sys_clk when its power-on table is done.
    // Each audio clock domain gets its own two-flop synchroniser of it and
    // ORs the inverse into that domain's reset, so neither end of the audio
    // FIFO runs before the codec has been configured.  Same idiom as locked,
    // same per-domain isolation, same active-high sense.  See the RESET
    // NETWORK block in the header for why.
    wire codec_cfg_done;

    reg codec_cfg_core_q0;
    reg codec_cfg_core_q1;
    reg codec_cfg_lcd_q0;
    reg codec_cfg_lcd_q1;

    always @(posedge mmcm_core_clk or negedge sys_rst_n) begin
        if (!sys_rst_n) begin
            codec_cfg_core_q0 <= 1'b0;
            codec_cfg_core_q1 <= 1'b0;
        end else begin
            codec_cfg_core_q0 <= codec_cfg_done;
            codec_cfg_core_q1 <= codec_cfg_core_q0;
        end
    end

    always @(posedge mmcm_lcd_clk or negedge sys_rst_n) begin
        if (!sys_rst_n) begin
            codec_cfg_lcd_q0 <= 1'b0;
            codec_cfg_lcd_q1 <= 1'b0;
        end else begin
            codec_cfg_lcd_q0 <= codec_cfg_done;
            codec_cfg_lcd_q1 <= codec_cfg_lcd_q0;
        end
    end

    wire rst_audio_wr = rst_core | ~codec_cfg_core_q1;
    wire rst_audio_rd = rst_lcd  | ~codec_cfg_lcd_q1;

    // ------------------------------------------------------------------ 时钟
    wire mmcm_lcd_clk;
    wire mmcm_core_clk;
    wire mmcm_locked;

    nes_zynq_clk u_clk (
        .clk_in  (sys_clk),
        .rst_in  (!sys_rst_n),
        .lcd_clk (mmcm_lcd_clk),
        .core_clk(mmcm_core_clk),
        .locked  (mmcm_locked)
    );

    // The MMCM output is the panel dot clock.  This is a data output, not a new
    // clock domain: lcd_de / lcd_rgb are registered on the same net.
    assign lcd_clk = mmcm_lcd_clk;

    // ---------------------------------------------------- 面板复位与背光
    // 16 bits covers both thresholds with room; LCD_BL_ON_CYCLES must stay
    // below 65536 for the counter to reach it.
    reg [15:0] lcd_pwr_cnt;

    always @(posedge sys_clk or negedge sys_rst_n) begin
        if (!sys_rst_n)
            lcd_pwr_cnt <= 16'd0;
        else
            lcd_pwr_cnt <= lcd_pwr_cnt + 16'd1;
    end

    wire lcd_rst_released = (lcd_pwr_cnt >= LCD_RST_HOLD_CYCLES[15:0]);
    wire lcd_bl_on        = (lcd_pwr_cnt >= LCD_BL_ON_CYCLES[15:0]);

    // lcd_rst is high meaning "out of reset", the same sense as the vendor's
    // constant 1 on the EP4CE10 board.  So it is 0 while the counter is below
    // the hold threshold and 1 from the threshold onwards.  Do NOT invert this:
    // the inverted form drives the panel out of reset at t=0 and then asserts
    // reset on it once the counter reaches the threshold.
    assign lcd_rst = lcd_rst_released;
    assign lcd_bl  = lcd_bl_on;

    // ------------------------------------------------------------ 手柄 CDC
    // The only non-pixel cross-domain path in the design: sys_clk -> core_clk.
    // ASYNC_REG keeps the two stages adjacent and gives the tool the
    // metastability attribute it needs to place them together.
    (* ASYNC_REG = "TRUE" *) reg [7:0] btn_meta_q;
    (* ASYNC_REG = "TRUE" *) reg [7:0] btn_sync_q;

    always @(posedge mmcm_core_clk or negedge sys_rst_n) begin
        if (!sys_rst_n) begin
            btn_meta_q <= 8'h00;
            btn_sync_q <= 8'h00;
        end else begin
            btn_meta_q <= touch_buttons;
            btn_sync_q <= btn_meta_q;
        end
    end

    // ------------------------------------------------------------ 触摸面板
    wire [7:0] touch_buttons;
    wire [3:0] touch_dpad;
    wire       touch_valid;
    wire [15:0] touch_x;
    wire [15:0] touch_y;
    wire       touch_int_o;
    wire       touch_init_done;
    wire       touch_error;
    wire       touch_bus_busy;
    wire       touch_poll_done;
    wire       ct_rst_n;
    wire       touch_scl_o;
    wire       touch_sda_o;
    wire       touch_sda_oe;
    wire       touch_sda_i;

    nes_touch_input u_touch (
        .clk        (sys_clk),
        .reset      (rst_sys),
        .ct_int     (touch_int),
        .ct_rst_n   (ct_rst_n),
        .scl_o      (touch_scl_o),
        .sda_o      (touch_sda_o),
        .sda_oe     (touch_sda_oe),
        .sda_i      (touch_sda_i),
        .key0       (key[0]),
        .key1       (key[1]),
        .buttons    (touch_buttons),
        .dpad       (touch_dpad),
        .touch_valid(touch_valid),
        .touch_x    (touch_x),
        .touch_y    (touch_y),
        .touch_int  (touch_int_o),
        .init_done  (touch_init_done),
        .touch_error(touch_error),
        .bus_busy   (touch_bus_busy),
        .poll_done  (touch_poll_done)
    );

    assign touch_scl     = touch_scl_o;
    assign touch_sda     = touch_sda_oe ? touch_sda_o : 1'bz;
    assign touch_sda_i   = touch_sda;
    assign touch_rst_n   = ct_rst_n;

    // ---------------------------------------------------------- CHR 存储器
    // PRG is inside the core (PRG_ENABLE=1, CHR_ENABLE=0).  CHR is here.
    wire [7:0]  chr_rdata;
    wire        core_ce_cpu;


    wire       core_chr_req;
    wire [16:0] core_chr_final_addr;
    wire [13:0] core_chr_waddr;
    wire        core_chr_we;
    wire [7:0]  core_chr_wdata;
    wire        core_mapper_chr_ram_enable;
    wire        core_ce_ppu;
    wire        core_pixel_valid;
    wire [7:0]  core_pixel_x;
    wire [7:0]  core_pixel_y;
    wire [7:0]  core_pixel_pal;
    wire        core_frame_done;
    wire        audio_sample_valid;
    wire [15:0] audio_sample_left;
    wire [15:0] audio_sample_right;

    nes_cart_rom #(
        .PRG_ENABLE(0),
        .CHR_ENABLE(1),
        .CHR_INIT_FILE(CHR_INIT_FILE)
    ) u_cart_chr (
        .clk          (mmcm_core_clk),
        .reset        (rst_core),
        .prg_en       (1'b0),
        .prg_addr     (17'd0),
        .prg_rdata    (),
        .ce_ppu       (core_ce_ppu),
        .chr_req      (core_chr_req),
        .chr_addr     (core_chr_final_addr),
        .chr_rdata    (chr_rdata),
        .chr_waddr    (core_chr_waddr),
        .chr_we       (core_chr_we),
        .chr_wdata    (core_chr_wdata),
        .chr_ram_enable(core_mapper_chr_ram_enable)
    );

    // ---------------------------------------------------------------- 核心
    nes_system_v6 #(
        .PRG_INIT_FILE(PRG_INIT_FILE)
    ) u_core (
        .clk                     (mmcm_core_clk),
        .reset                   (rst_core),
        .buttons1                (btn_sync_q),
        .buttons2                (8'h00),
        .chr_rdata               (chr_rdata),
        .audio_sample_valid      (audio_sample_valid),
        .audio_sample_left       (audio_sample_left),
        .audio_sample_right      (audio_sample_right),
        .pixel_valid             (core_pixel_valid),
        .pixel_x                 (core_pixel_x),
        .pixel_y                 (core_pixel_y),
        .pixel_index             (),
        .pixel_pal               (core_pixel_pal),
        .frame_done              (core_frame_done),
        .ce_ppu                  (core_ce_ppu),
        .ce_cpu                  (core_ce_cpu),
        .chr_req                 (core_chr_req),
        .chr_final_addr          (core_chr_final_addr),
        .chr_waddr               (core_chr_waddr),
        .chr_we                  (core_chr_we),
        .chr_wdata               (core_chr_wdata),
        .mapper_chr_ram_enable   (core_mapper_chr_ram_enable)
    );

    // -------------------------------------------------------------- 调色板
    // cNES reference table, ppu.c:94-111, RGBValue = {r, g, b}.
    // R5 = R8>>3, G6 = G8>>2, B5 = B8>>3.
    // A function, not an always block, so the same table can be read
    // combinationally for the debug tap and one stage later out of the pixel
    // pipeline register below.  pal_rgb565 stays a net with the same value it
    // always had; tb_nes_zynq_top.v drives core_pixel_pal with a force and
    // reads pal_rgb565 combinationally to check every one of the 64 entries.
    function [15:0] pal_to_rgb565;
        input [5:0] idx;
        begin
        case (idx)
            6'h00: pal_to_rgb565 = 16'h632C;  // 66 66 66
            6'h01: pal_to_rgb565 = 16'h00F3;  // 00 1E 9A
            6'h02: pal_to_rgb565 = 16'h0855;  // 0E 09 A8
            6'h03: pal_to_rgb565 = 16'h4012;  // 44 00 93
            6'h04: pal_to_rgb565 = 16'h700C;  // 71 00 60
            6'h05: pal_to_rgb565 = 16'h8803;  // 89 01 1D
            6'h06: pal_to_rgb565 = 16'h8080;  // 86 13 00
            6'h07: pal_to_rgb565 = 16'h6940;  // 69 29 00
            6'h08: pal_to_rgb565 = 16'h39E0;  // 39 3E 00
            6'h09: pal_to_rgb565 = 16'h0260;  // 04 4C 00
            6'h0A: pal_to_rgb565 = 16'h0260;  // 00 4F 00
            6'h0B: pal_to_rgb565 = 16'h0225;  // 00 47 2B
            6'h0C: pal_to_rgb565 = 16'h01AD;  // 00 35 6C
            6'h0D: pal_to_rgb565 = 16'h0000;  // 00 00 00
            6'h0E: pal_to_rgb565 = 16'h0000;  // 00 00 00
            6'h0F: pal_to_rgb565 = 16'h0000;  // 00 00 00  blanking entry, black
            6'h10: pal_to_rgb565 = 16'hAD75;  // AD AD AD
            6'h11: pal_to_rgb565 = 16'h029E;  // 00 50 F1
            6'h12: pal_to_rgb565 = 16'h39BF;  // 3B 34 FF
            6'h13: pal_to_rgb565 = 16'h811D;  // 80 22 E8
            6'h14: pal_to_rgb565 = 16'hB8F4;  // BB 1E A5
            6'h15: pal_to_rgb565 = 16'hD949;  // DB 29 4E
            6'h16: pal_to_rgb565 = 16'hD200;  // D7 40 00
            6'h17: pal_to_rgb565 = 16'hB2E0;  // B1 5E 00
            6'h18: pal_to_rgb565 = 16'h73C0;  // 73 79 00
            6'h19: pal_to_rgb565 = 16'h2C40;  // 2D 8B 00
            6'h1A: pal_to_rgb565 = 16'h0461;  // 00 8F 08
            6'h1B: pal_to_rgb565 = 16'h042C;  // 00 84 60
            6'h1C: pal_to_rgb565 = 16'h0376;  // 00 6D B5
            6'h1D: pal_to_rgb565 = 16'h0000;  // 00 00 00
            6'h1E: pal_to_rgb565 = 16'h0000;  // 00 00 00
            6'h1F: pal_to_rgb565 = 16'h0000;  // 00 00 00
            6'h20: pal_to_rgb565 = 16'hFFFF;  // FF FF FF
            6'h21: pal_to_rgb565 = 16'h4D1F;  // 4B A0 FF
            6'h22: pal_to_rgb565 = 16'h8C3F;  // 8A 84 FF
            6'h23: pal_to_rgb565 = 16'hD39F;  // D1 72 FF
            6'h24: pal_to_rgb565 = 16'hFB7E;  // FF 6D F7
            6'h25: pal_to_rgb565 = 16'hFBD3;  // FF 79 9E
            6'h26: pal_to_rgb565 = 16'hFC88;  // FF 90 47  salmon / orange
            6'h27: pal_to_rgb565 = 16'hFD61;  // FF AE 0A
            6'h28: pal_to_rgb565 = 16'hC640;  // C4 CA 00
            6'h29: pal_to_rgb565 = 16'h7EE2;  // 7D DC 13
            6'h2A: pal_to_rgb565 = 16'h470A;  // 41 E1 57
            6'h2B: pal_to_rgb565 = 16'h26B6;  // 21 D5 B0
            6'h2C: pal_to_rgb565 = 16'h25FF;  // 25 BE FF
            6'h2D: pal_to_rgb565 = 16'h4A69;  // 4F 4F 4F
            6'h2E: pal_to_rgb565 = 16'h0000;  // 00 00 00
            6'h2F: pal_to_rgb565 = 16'h0000;  // 00 00 00
            6'h30: pal_to_rgb565 = 16'hFFFF;  // FF FF FF
            6'h31: pal_to_rgb565 = 16'hB6DF;  // B6 D8 FF
            6'h32: pal_to_rgb565 = 16'hD67F;  // D0 CD FF
            6'h33: pal_to_rgb565 = 16'hEE3F;  // ED C6 FF
            6'h34: pal_to_rgb565 = 16'hFE3F;  // FF C4 FC
            6'h35: pal_to_rgb565 = 16'hFE5B;  // FF C8 D8
            6'h36: pal_to_rgb565 = 16'hFE96;  // FF D2 B4
            6'h37: pal_to_rgb565 = 16'hFEF3;  // FF DE 9C
            6'h38: pal_to_rgb565 = 16'hE752;  // E7 E9 94
            6'h39: pal_to_rgb565 = 16'hCF93;  // CA F1 9F
            6'h3A: pal_to_rgb565 = 16'hB797;  // B2 F3 BB
            6'h3B: pal_to_rgb565 = 16'hA77B;  // A5 EE DF
            6'h3C: pal_to_rgb565 = 16'hA73F;  // A6 E5 FF
            6'h3D: pal_to_rgb565 = 16'hBDD7;  // B8 B8 B8
            6'h3E: pal_to_rgb565 = 16'h0000;  // 00 00 00
            6'h3F: pal_to_rgb565 = 16'h0000;  // 00 00 00
            default: pal_to_rgb565 = 16'h0000;
        endcase
        end
    endfunction

    wire [15:0] pal_rgb565 = pal_to_rgb565(core_pixel_pal[5:0]);

    // ------------------------------------------------------------ 视频输出
    // The write port is core_clk and the read port is lcd_clk; frame_mem is the
    // crossing.  ce is tied high: the raster always runs at one dot per lcd_clk,
    // which is the 25 MHz the panel is driven at.
    wire [15:0] vid_rgb565;
    wire        vid_de;
    wire        vid_hsync;
    wire        vid_vsync;
    wire [10:0] vid_hcount;
    wire [10:0] vid_vcount;
    wire [10:0] vid_pixel_x;
    wire [10:0] vid_pixel_y;
    wire        vid_frame_pulse;

    // ---------------------------------------------------- 像素流水线寄存器
    // Two register stages between the PPU and the video write port, so the
    // frame memory's DIADI pins are driven from flops rather than from the
    // PPU's combinational output.
    //
    // ONE WRITE PER DOT, AND WHY THE LEVEL CANNOT BE USED DIRECTLY
    //   core_pixel_valid is a LEVEL, not a pulse.  It is high for the whole
    //   window in which the PPU's dot register holds one value, which is four
    //   core clocks per dot (nes_ppu2c02.v:949 gates it on dot < 256).
    //   nes_video_800x480.v:186 writes frame_mem on EVERY wr_clk edge with
    //   in_valid high, so presenting the level would write one dot four times
    //   into the same address.
    //   The strobe is therefore core_ce_ppu AND core_pixel_valid.
    //   core_ce_ppu is the core's own exported enable and
    //   nes_system_v6.v drives it as !reset && (div_phase[1:0] == 2'b00), so it
    //   is high on exactly the one core clock edge per dot on which the PPU's
    //   dot register advances.  The conjunction is therefore high once per dot,
    //   for the 256 visible dots of a line and not for the 85 blanked ones.
    //   Nothing here regenerates or re-phases div_phase, which nes_cart_rom's
    //   read path is sensitive to.
    //
    //   At that edge dot still holds its pre-increment value, so the x, y and
    //   palette byte captured are those of one specific visible dot, and the
    //   256 captured dots of a line are exactly x = 0..255, once each.  Data
    //   and strobe move together through both stages, so the colour written
    //   always belongs to the address it is written to.
    //
    //   frame_mem is addressed by {in_y, in_x}, so neither the write order nor
    //   the two clocks of added latency matter; only that each visible dot is
    //   written exactly once with its own colour, which the strobe guarantees.
    //   The second stage exists so the 64-entry palette table sits between two
    //   registers instead of between the PPU and one.
    reg        px_we_q;
    reg [7:0]  px_x_q;
    reg [7:0]  px_y_q;
    reg [5:0]  px_pal_q;
    reg        vid_we_q;
    reg [7:0]  vid_in_x_q;
    reg [7:0]  vid_in_y_q;
    reg [15:0] vid_in_rgb_q;

    always @(posedge mmcm_core_clk or negedge sys_rst_n) begin
        if (!sys_rst_n) begin
            px_we_q      <= 1'b0;
            px_x_q       <= 8'h00;
            px_y_q       <= 8'h00;
            px_pal_q     <= 6'h00;
            vid_we_q     <= 1'b0;
            vid_in_x_q   <= 8'h00;
            vid_in_y_q   <= 8'h00;
            vid_in_rgb_q <= 16'h0000;
        end else begin
            px_we_q <= core_ce_ppu && core_pixel_valid;
            if (core_ce_ppu && core_pixel_valid) begin
                px_x_q   <= core_pixel_x;
                px_y_q   <= core_pixel_y;
                px_pal_q <= core_pixel_pal[5:0];
            end
            vid_we_q <= px_we_q;
            if (px_we_q) begin
                vid_in_x_q   <= px_x_q;
                vid_in_y_q   <= px_y_q;
                vid_in_rgb_q <= pal_to_rgb565(px_pal_q);
            end
        end
    end

    nes_video_800x480 u_video (
        .wr_clk        (mmcm_core_clk),
        .wr_reset      (rst_core),
        .in_valid      (vid_we_q),
        .in_x          (vid_in_x_q),
        .in_y          (vid_in_y_q),
        .in_rgb565     (vid_in_rgb_q),
        .in_line_ready (),
        .in_frame_ready(),
        .rd_clk        (mmcm_lcd_clk),
        .rd_reset      (rst_lcd),
        .ce            (1'b1),
        .rgb565        (vid_rgb565),
        .de            (vid_de),
        .hsync         (vid_hsync),
        .vsync         (vid_vsync),
        .hcount        (vid_hcount),
        .vcount        (vid_vcount),
        .pixel_x       (vid_pixel_x),
        .pixel_y       (vid_pixel_y),
        .frame_pulse   (vid_frame_pulse)
    );

    // ------------------------------------------------------ RGB565 -> RGB888
    // rgb565 passes through nes_video_800x480 untouched: [15:11] red,
    // [10:5] green, [4:0] blue.  Each channel is widened to eight bits by
    // appending the TOP bits of its own field, so that 0x0000 -> 0x000000,
    // 0xFFFF -> 0xFFFFFF and every channel is monotonic in its input.
    // The replicated bits are the field's own MSBs: red [15:13], green [10:9],
    // blue [4:2].  Replication is exact at both ends and never overshoots.
    wire [7:0] lcd_r8 = {vid_rgb565[15:11], vid_rgb565[15:13]};
    wire [7:0] lcd_g8 = {vid_rgb565[10:5],  vid_rgb565[10:9]};
    wire [7:0] lcd_b8 = {vid_rgb565[4:0],   vid_rgb565[4:2]};

    // The bus is bidirectional: the vendor reads the panel ID back over these
    // pins, so it is released whenever the panel is not being driven.
    assign lcd_rgb = vid_de ? {lcd_r8, lcd_g8, lcd_b8} : 24'hz;

    assign lcd_de = vid_de;
    assign lcd_hs = vid_hsync;
    assign lcd_vs = vid_vsync;

    // ================================================================ 音频通路
    // audio_sample_valid 是 1789772.727 Hz 的单拍 strobe，不是音频采样率。
    // 完整推导见文件头 AUDIO LANE 一节，这里只给结果：
    //     in  19687500/11 = 1789772.7272727273 Hz（精确）
    //     4、4、2 抽头滑动平均级联，总增益恒为 1，求和值不做除法
    //     精确有理 63/55，即 2016 个输入样点 -> 55 个输出样点
    //     out 25e6/512 = 48828.125 Hz（精确）
    // 而 19687500/11 * 55/2016 正好等于 25e6/512，所以生产者与消费者的
    // 速率逐位相等，FIFO 水位不会随时间走动。
    //
    // 为什么不用 /37：1789772.727/37 = 48372.235 Hz，比 48000 高 0.7755%
    // （= 101/13024）。这个误差不是音质问题而是可用性问题——FIFO 两侧速率只要
    // 不等，水位就会一路走到满或一路走到空，0.78% 的失配大约 26 秒就能填满
    // 1024 项。而整数抽取要与 25 MHz 侧的帧率精确相等，只有 126*D/55 为整数
    // 才行，55 整除 D，D=55 时帧率 14204 Hz，D=16 时是 2016/55 =
    // 36.654545...，不是整数。所以用精确有理抽取。
    //
    // 为什么不是 37 抽头的箱式平均：固定长度的箱式平均只有除以整数长度才有
    //  unity 增益，而有理比值下平均长度在 1 和 2 之间交替，不存在固定增益；
    // 而且 37 抽头的第一个零点在 1789772/37 = 48.4 kHz，对真正会折叠进输出
    // 的 24 kHz 带几乎无衰减。改用 4/4/2 三个短滑动平均串联，零点落在
    // 447 kHz、447 kHz、894 kHz，都在输入带内、远高于音频带：帧率处
    // 约 0.35 dB，700 kHz 处约 -33 dB，而 DC 增益精确为 1（4*4*2 = 32）。
    // 这不是完整的抗混叠滤波器——要把 20 kHz 以内做到 -40 dB 需要 1.79 MHz
    // 下 16 抽头的 FIR，是另一件工作，这里没有做。

    // --- 第一级：4 抽头滑动平均，速率 /4，输出 18 位（未除，和 = 4 倍幅值）
    reg [15:0] ma1_d1_l, ma1_d2_l, ma1_d3_l;
    reg [15:0] ma1_d1_r, ma1_d2_r, ma1_d3_r;
    reg [17:0] ma1_sum_l, ma1_sum_r;
    reg [1:0]  ma1_cnt;
    reg        ma1_vld;

    always @(posedge mmcm_core_clk or posedge rst_audio_wr) begin
        if (rst_audio_wr) begin
            ma1_d1_l  <= 16'h0000; ma1_d2_l  <= 16'h0000; ma1_d3_l  <= 16'h0000;
            ma1_d1_r  <= 16'h0000; ma1_d2_r  <= 16'h0000; ma1_d3_r  <= 16'h0000;
            ma1_sum_l <= 18'h00000; ma1_sum_r <= 18'h00000;
            ma1_cnt   <= 2'd0;
            ma1_vld   <= 1'b0;
        end else begin
            ma1_vld <= 1'b0;
            if (audio_sample_valid) begin
                ma1_d1_l <= audio_sample_left;
                ma1_d2_l <= ma1_d1_l;
                ma1_d3_l <= ma1_d2_l;
                ma1_d1_r <= audio_sample_right;
                ma1_d2_r <= ma1_d1_r;
                ma1_d3_r <= ma1_d2_r;
                // 4 x 65535 = 262140 < 2^18，所以 18 位加减链不会溢出。
                // 若写成 18 位操作数相加但结果仍按 18 位截断，这里会静默回绕。
                ma1_sum_l <= {2'b00, audio_sample_left} + {2'b00, ma1_d1_l}
                           + {2'b00, ma1_d2_l} + {2'b00, ma1_d3_l};
                ma1_sum_r <= {2'b00, audio_sample_right} + {2'b00, ma1_d1_r}
                           + {2'b00, ma1_d2_r} + {2'b00, ma1_d3_r};
                ma1_cnt   <= ma1_cnt + 2'd1;
                ma1_vld   <= (ma1_cnt == 2'd3);
            end
        end
    end

    // --- 第二级：4 抽头滑动平均，速率 /16，输出 20 位
    reg [17:0] ma2_d1_l, ma2_d2_l, ma2_d3_l;
    reg [17:0] ma2_d1_r, ma2_d2_r, ma2_d3_r;
    reg [19:0] ma2_sum_l, ma2_sum_r;
    reg [1:0]  ma2_cnt;
    reg        ma2_vld;

    always @(posedge mmcm_core_clk or posedge rst_audio_wr) begin
        if (rst_audio_wr) begin
            ma2_d1_l  <= 18'h00000; ma2_d2_l  <= 18'h00000; ma2_d3_l  <= 18'h00000;
            ma2_d1_r  <= 18'h00000; ma2_d2_r  <= 18'h00000; ma2_d3_r  <= 18'h00000;
            ma2_sum_l <= 20'h00000; ma2_sum_r <= 20'h00000;
            ma2_cnt   <= 2'd0;
            ma2_vld   <= 1'b0;
        end else begin
            ma2_vld <= 1'b0;
            if (ma1_vld) begin
                ma2_d1_l <= ma1_sum_l;
                ma2_d2_l <= ma2_d1_l;
                ma2_d3_l <= ma2_d2_l;
                ma2_d1_r <= ma1_sum_r;
                ma2_d2_r <= ma2_d1_r;
                ma2_d3_r <= ma2_d2_r;
                // 4 x 262140 = 1048560 < 2^20，必须显式加宽到 20 位。
                ma2_sum_l <= {2'b00, ma1_sum_l} + {2'b00, ma2_d1_l}
                           + {2'b00, ma2_d2_l} + {2'b00, ma2_d3_l};
                ma2_sum_r <= {2'b00, ma1_sum_r} + {2'b00, ma2_d1_r}
                           + {2'b00, ma2_d2_r} + {2'b00, ma2_d3_r};
                ma2_cnt   <= ma2_cnt + 2'd1;
                ma2_vld   <= (ma2_cnt == 2'd3);
            end
        end
    end

    // --- 第三级：2 抽头滑动平均后再 2 选 1，速率 /32，输出 21 位
    // 两个要点：
    //   * 2 抽头平均本身速率不变（每来一个输入出一个平均），要真的把速率再
    //     减半必须显式每两个取一个。如果写成每个 ma2_vld 都出一个输出，总比
    //     只变成 /16，后面 63/55 的有理抽取就配不上 2016/55 了。
    //   * ma3_tog 必须是 1 bit 而不是 2 bit 计数。2 bit 计数器 mod 4，
    //     ma3_tog == 1 只在第 2、6、10... 次命中，那等于再除以 2 而不是 2，
    //     总比变成 /64，有理抽取的 63/55 立刻配不上。这里踩过一次。
    reg [19:0] ma3_d1_l, ma3_d1_r;
    reg [20:0] ma3_sum_l, ma3_sum_r;
    reg        ma3_tog;
    reg        ma3_vld;

    always @(posedge mmcm_core_clk or posedge rst_audio_wr) begin
        if (rst_audio_wr) begin
            ma3_d1_l  <= 20'h00000;
            ma3_d1_r  <= 20'h00000;
            ma3_sum_l <= 21'h000000;
            ma3_sum_r <= 21'h000000;
            ma3_tog   <= 1'b0;
            ma3_vld   <= 1'b0;
        end else begin
            ma3_vld <= 1'b0;
            if (ma2_vld) begin
                ma3_d1_l  <= ma2_sum_l;
                ma3_d1_r  <= ma2_sum_r;
                // 2 x 1048560 = 2097120 < 2^21。
                ma3_sum_l <= {1'b0, ma2_sum_l} + {1'b0, ma3_d1_l};
                ma3_sum_r <= {1'b0, ma2_sum_r} + {1'b0, ma3_d1_r};
                ma3_tog   <= ~ma3_tog;
                // 第 2、4、6... 个第二级输出才取，所以 4*4*2 = 32。
                ma3_vld   <= ma3_tog;
            end
        end
    end

    // --- 精确有理 63/55，加上 /32
    // 2016 个输入样点产生 63 个第三级输出，而 63*55 = 3465 = 55*63，
    // 所以 2016 进 55 出、余数为零，累加器是有界整数，周期严格重复。
    reg [6:0]  rat_acc;
    reg        dec_valid;
    reg [15:0] dec_left;
    reg [15:0] dec_right;

    wire rat_hit = ma3_vld && ((rat_acc + 7'd55) >= 7'd63);

    // >>5 之前 +16 是把 32 点平均四舍五入到最近整数，这样常数输入可以逐位
    // 相等，而不会恒定偏低最多 31/32 个 LSB。最大值
    // (2097120 + 16) >> 5 = 65535，正好在 16 位内。
    wire [20:0] ma3_rnd_l = {1'b0, ma3_sum_l} + 21'd16;
    wire [20:0] ma3_rnd_r = {1'b0, ma3_sum_r} + 21'd16;

    always @(posedge mmcm_core_clk or posedge rst_audio_wr) begin
        if (rst_audio_wr) begin
            rat_acc   <= 7'd0;
            dec_valid <= 1'b0;
            dec_left  <= 16'h0000;
            dec_right <= 16'h0000;
        end else begin
            dec_valid <= rat_hit;
            if (ma3_vld)
                rat_acc <= rat_hit ? ((rat_acc + 7'd55) - 7'd63) : (rat_acc + 7'd55);
            if (rat_hit) begin
                dec_left  <= ma3_rnd_l[20:5];
                dec_right <= ma3_rnd_r[20:5];
            end
        end
    end

    // ----------------------------------------------------------------- I2S
    wire aud_bclk_i;
    wire aud_lrck_i;
    wire aud_dout_i;
    wire aud_full;
    wire aud_dropped;
    wire aud_underflow;
    wire aud_i2s_sample_valid;

    // bclk 是 mmcm_lcd_clk 的分频，所以它的上升沿和推进移位器的 lcd_clk 沿
    // 相位相关。一个宽度为一个 lcd_clk、在 bclk 上升沿结束的脉冲就是移位器
    // 的时钟使能：这一位在驱动引脚的输出寄存器采样它之前整整一个 BCLK 周期
    // 就已经就位。
    reg bclk_d_q;

    always @(posedge mmcm_lcd_clk or posedge rst_audio_rd) begin
        if (rst_audio_rd)
            bclk_d_q <= 1'b0;
        else
            bclk_d_q <= aud_bclk_i;
    end

    wire i2s_rd_ce = aud_bclk_i & ~bclk_d_q;

    nes_audio_i2s #(
        // 25 MHz / 16 = 1.5625 MHz BCLK。nes_i2s_shifter 每立体声样点出
        // 16+16 位、一位一个 BCLK，所以一帧是 32 个 BCLK，帧率
        // 1.5625e6 / 32 = 48828.125 Hz。
        .BCLK_DIV    (16),
        // ADDR_WIDTH 是 FIFO 深度，深度 10（1024 项）会把片上寄存器吃光：
        // nes_cdc_fifo 的存储阵列是每 bit 一对触发器，1024*32*2 = 65536 个
        // 触发器，加上原有设计的 36495 个就是 102031，接近 xc7z020 的 106400，
        // 而且配不上的触发器还要各吃一个 LUT。实测 93.7% LUT / 66.3% FF 的
        // 综合结果让 placer 直接报 [Place 30-4] "Design utilization is very
        // high" 而失败。深度 6（64 项）只多 4096 个触发器，1.31 ms 的缓冲，
        // 而这条通路是精确等速率的，实测 tb_nes_audio_lane 观测到的写入到
        // 引脚的固定延迟只有 1 个采样，64 项绰绰有余。
        .ADDR_WIDTH  (6),
        .BIT_REVERSED(0)
    ) u_audio_i2s (
        .wr_clk      (mmcm_core_clk),
        .wr_reset    (rst_audio_wr),
        .wr_en       (dec_valid),
        .wr_left     (dec_left),
        .wr_right    (dec_right),
        .wr_full     (aud_full),
        .dropped     (aud_dropped),
        .rd_clk      (mmcm_lcd_clk),
        .rd_reset    (rst_audio_rd),
        // mclk 与 rd_clk 是同一个网络，这是有意的，见文件头 AUDIO LANE 第 4 条。
        .mclk        (mmcm_lcd_clk),
        .rd_ce       (i2s_rd_ce),
        .underflow   (aud_underflow),
        .bclk        (aud_bclk_i),
        .lrck        (aud_lrck_i),
        .dout        (aud_dout_i),
        .sample_valid(aud_i2s_sample_valid)
    );

    // I2S 的一位延迟。
    // nes_i2s_shifter 在同一个沿上同时更新 out_bit 和 out_lrck，所以 dout 和
    // lrck 一起在 posedge bclk 上寄存时，新字的 MSB 会落在与 lrck 跳变同一个
    // bclk 时隙里。WM8960_v4.4.pdf AUDIO DATA FORMATS 写的是 "In I2S mode,
    // the MSB is available on the second rising edge of BCLK following a LRCLK
    // transition."。在 dout 上再加一级 bclk 寄存器，正好把 MSB 推进第二个
    // 时隙，别的一概不动；延迟时隙里数据线保持上一个字的尾巴，和 Figure 28
    // 画的一致。lrck 不加延迟，因为 lrck 是给接收方的通道标记。
    reg aud_dout_d_q;

    always @(posedge aud_bclk_i or posedge rst_audio_rd) begin
        if (rst_audio_rd)
            aud_dout_d_q <= 1'b0;
        else
            aud_dout_d_q <= aud_dout_i;
    end

    assign aud_bclk    = aud_bclk_i;
    assign aud_dac_lrc = aud_lrck_i;
    assign aud_dacdat  = aud_dout_d_q;
    assign aud_mclk    = mmcm_lcd_clk;

    // ------------------------------------------------------------- codec I2C
    wire codec_scl_o;
    wire codec_sda_o;
    wire codec_sda_oe;
    wire codec_sda_i;
    wire codec_busy;
    wire codec_wr_done;
    wire codec_nack;
    wire codec_error;

    // 15 项上电常量表在 100 kHz 下约 4.6 ms 走完。寄存器表与时钟方案的
    // 逐项数据手册引用在 rtl/nes_core/peripheral/wm8960_i2c.v 的文件头。
    wm8960_i2c #(
        .CLK_HZ   (50000000),
        .I2C_HZ   (100000),
        .DEV_ADDR (7'h1a)
    ) u_codec_i2c (
        .clk      (sys_clk),
        .reset    (rst_sys),
        // 本设计只用上电常量表；单次写口是留给 bring-up 的，这里没有生产者。
        .wr_req   (1'b0),
        .reg_addr (7'h00),
        .wdata    (9'h000),
        .sda_i    (codec_sda_i),
        .scl_o    (codec_scl_o),
        .sda_o    (codec_sda_o),
        .sda_oe   (codec_sda_oe),
        .busy     (codec_busy),
        .wr_done  (codec_wr_done),
        .nack_seen(codec_nack),
        .error    (codec_error),
        .cfg_done (codec_cfg_done)
    );

    assign aud_iic_scl = codec_scl_o ? 1'bz : 1'b0;
    assign aud_iic_sda = codec_sda_oe ? codec_sda_o : 1'bz;
    assign codec_sda_i = aud_iic_sda;

endmodule
