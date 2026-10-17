`timescale 1ns/1ps

// ============================================================================
// nes_zynq_pl_top : the PL-only binding of nes_zynq_top
// ----------------------------------------------------------------------------
// nes_zynq_top can no longer be the top of a PL-only build directly.  It now
// carries eight ps_* inputs that the block design in ../ps/ drives from the
// Zynq PS.  With no PS those inputs have no driver at all, and an undriven
// ps_console_hold reaches the core-domain reset through its two-flop
// synchroniser as an unknown, which holds the console (and ps_gamepad would be
// an unknown button byte).  ps_load_enable and ps_ld_valid undriven would leave
// the cartridge-load bridge in an undefined state.
//
// This wrapper is the PL-only equivalent of what the board-independent
// testbenches already do.  tb/platform/tb_nes_zynq_top.v and
// tb/peripheral/tb_nes_audio_lane.v both instantiate nes_zynq_top with every
// ps_* input tied to zero and ps_ld_ready open; this file does exactly the
// same, so a PL-only build is byte-for-byte the console those benches prove.
//
// It adds no behaviour and does not touch the RTL.  The port list is exactly
// nes_zynq_top's minus the eight ps_* ports, so this design places 53 pins --
// the same number the historical PL-only builds placed, and the number
// tools/pl/finish.tcl asserts.
//
// SYNTHESIS ONLY.  Only tools/pl/build.tcl and tools/pl/ph_build.tcl read this
// file; the simulation gate never does.
// ============================================================================

module nes_zynq_pl_top (
    input  wire        sys_clk,
    input  wire        sys_rst_n,
    input  wire [1:0]  key,
    input  wire        touch_key,
    inout  wire [23:0] lcd_rgb,
    output wire        lcd_hs,
    output wire        lcd_vs,
    output wire        lcd_de,
    output wire        lcd_bl,
    output wire        lcd_clk,
    output wire        lcd_rst,
    inout  wire        touch_scl,
    inout  wire        touch_sda,
    output wire        touch_rst_n,
    input  wire        touch_int,
    output wire        aud_bclk,
    output wire        aud_dac_lrc,
    output wire        aud_dacdat,
    output wire        aud_mclk,
    inout  wire        aud_iic_scl,
    inout  wire        aud_iic_sda,
    output wire [2:0]  tmds_data_p,
    output wire [2:0]  tmds_data_n,
    output wire        tmds_clk_p,
    output wire        tmds_clk_n
);

    nes_zynq_top u_top (
        .sys_clk         (sys_clk),
        .sys_rst_n       (sys_rst_n),
        .key             (key),
        .touch_key       (touch_key),
        .lcd_rgb         (lcd_rgb),
        .lcd_hs          (lcd_hs),
        .lcd_vs          (lcd_vs),
        .lcd_de          (lcd_de),
        .lcd_bl          (lcd_bl),
        .lcd_clk         (lcd_clk),
        .lcd_rst         (lcd_rst),
        .touch_scl       (touch_scl),
        .touch_sda       (touch_sda),
        .touch_rst_n     (touch_rst_n),
        .touch_int       (touch_int),
        .aud_bclk        (aud_bclk),
        .aud_dac_lrc     (aud_dac_lrc),
        .aud_dacdat      (aud_dacdat),
        .aud_mclk        (aud_mclk),
        .aud_iic_scl     (aud_iic_scl),
        .aud_iic_sda     (aud_iic_sda),
        .tmds_data_p     (tmds_data_p),
        .tmds_data_n     (tmds_data_n),
        .tmds_clk_p      (tmds_clk_p),
        .tmds_clk_n      (tmds_clk_n),
        .ps_ld_valid     (1'b0),
        .ps_ld_target    (1'b0),
        .ps_ld_addr      (17'd0),
        .ps_ld_data      (8'h00),
        .ps_ld_ready     (),
        .ps_load_enable  (1'b0),
        .ps_console_hold (1'b0),
        .ps_gamepad      (8'h00)
    );

endmodule
