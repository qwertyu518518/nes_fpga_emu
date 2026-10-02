`timescale 1ns/1ps

// ============================================================================
// nes_zynq_top : Zynq-7020 platform top for the NES emulator
// ----------------------------------------------------------------------------
// This is the wiring layer.  Every block below it is built and gated on its own;
// the job here is to connect them and to own exactly the two things no submodule
// can own: the clock tree and the reset network.
//
// CLOCK DOMAINS, three, and nothing crosses between core_clk and lcd_clk except
// the pixels.  25 MHz is not an integer multiple of 21.477 MHz, so the panel
// output stage cannot be clocked from the core with a clock enable: pixel data
// must leave on real 25 MHz edges.
//
//   sys_clk   50 MHz, board pin U18
//       nes_touch_input                     clk = sys_clk, reset = rst_sys
//       lcd_rst / lcd_bl power-on counter   clk = sys_clk
//       locked synchroniser stage 1         clk = sys_clk
//   core_clk  21.477272727 MHz, MMCM CLKOUT1
//       nes_system_v6                       clk = core_clk, reset = rst_core
//       nes_cart_rom, CHR half only         clk = core_clk, reset = rst_core
//       palette LUT (combinational)         pixel_pal[5:0] -> RGB565
//       nes_video_800x480 write port        wr_clk = core_clk, reset = rst_core
//   lcd_clk   25 MHz, MMCM CLKOUT0
//       nes_video_800x480 read port         rd_clk = lcd_clk, reset = rst_lcd
//       RGB565 -> RGB888 expansion          combinational
//       lcd_de / lcd_hs / lcd_vs / lcd_rgb  panel pins
//
// The two cross-domain boundaries, and only two:
//   1. touch buttons: sys_clk -> core_clk, a 2-flop synchroniser.  The core
//      samples a controller port and cannot tolerate a metastable bit.
//   2. frame_mem inside nes_video_800x480: core_clk write port, lcd_clk read
//      port.  This is a true simple-dual-port RAM, so the crossing costs no
//      logic at all: no synchroniser, no toggle, no handshake, no backpressure.
// There is deliberately no third CDC.  If one is ever needed between core_clk
// and lcd_clk the architecture has been broken, because the pixels already
// carry everything across.
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
// ROM FILES

//
// NOT PRESENT THIS PASS: the audio lane.  The XDC keeps aud_* commented out and
// no audio ports are declared, so nes_system_v6's audio_sample_* outputs are
// left open.  Two PL keys are not a controller and are wired to the touch
// module's key0/key1, which handles their active-low polarity and debouncing.
// ============================================================================

module nes_zynq_top #(
    // sys_clk cycles the panel reset pin is held low before release.
    // 5000 cycles = 100 us at 50 MHz, far longer than any panel needs.
    parameter integer LCD_RST_HOLD_CYCLES = 5000,
    // sys_clk cycles before the backlight is asserted.
    // 20000 cycles = 400 us, so it comes up after the reset pulse has finished
    // and the panel has had time to settle.
    parameter integer LCD_BL_ON_CYCLES   = 20000,
    // CHR_INIT_FILE is a parameter so an integrator that relocates the tree, or
    // the throwaway synthesis tree under D:\vivadoProject\zynq_top_probe, can
    // point it somewhere absolute.  The default is nes_cart_rom's own, relative
    // to the repository root.  A $readmemh that cannot find its file leaves the
    // array uninitialised and Vivado then optimises it away silently, so
    // tb_nes_zynq_top.v asserts that the array holds non-constant content.
    //
    // The PRG path is NOT a parameter here and cannot be: nes_system_v6 has no
    // such parameter and instantiates nes_cart_rom with PRG_ENABLE(1) using
    // nes_cart_rom's own default, so the PRG hex path is fixed at
    // "rtl/nes_core/cart/prg_placeholder.hex" relative to whatever directory
    // the simulator or Vivado was started in.  Every consumer of this design,
    // including the throwaway synthesis tree, must therefore replicate
    // rtl/nes_core/cart/*.hex at that relative path.  Making the PRG path
    // relocatable needs a parameter added to nes_system_v6, which is a change to
    // a gated module and therefore out of scope for the platform top.
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
    input  wire        touch_int
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
    wire [7:0] chr_rdata;

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
    nes_system_v6 u_core (
        .clk                     (mmcm_core_clk),
        .reset                   (rst_core),
        .buttons1                (btn_sync_q),
        .buttons2                (8'h00),
        .chr_rdata               (chr_rdata),
        .pixel_valid             (core_pixel_valid),
        .pixel_x                 (core_pixel_x),
        .pixel_y                 (core_pixel_y),
        .pixel_index             (),
        .pixel_pal               (core_pixel_pal),
        .frame_done              (core_frame_done),
        .ce_ppu                  (core_ce_ppu),
        .ce_cpu                  (),
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

endmodule
