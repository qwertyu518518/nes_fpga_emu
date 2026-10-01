`timescale 1ns/1ps

// ============================================================================
// nes_zynq_clk : Zynq-7020 clock generator for the NES core
// ----------------------------------------------------------------------------
// The board oscillator is 50 MHz (package pin U18, net sys_clk, vendor XDC
// NAVIGATOR_ZYNQ_IO.xdc line 4).  The vendor material carries no
// 21.477272727 MHz clock of any kind, so the NES core clock is synthesised
// from the 50 MHz input with one MMCME2_BASE.
//
// Which output carries which clock, and why
//   MMCME2_BASE gives CLKOUT0 a fractional divide, CLKOUT0_DIVIDE_F, and only
//   integer divides to CLKOUT1..CLKOUT6.  The NES core clock therefore goes on
//   CLKOUT1, whose divide is an exact integer, and the LCD clock goes on
//   CLKOUT0, where the fractional divide is allowed to be a non-integer
//   multiple of 0.125.  Putting the core clock on CLKOUT0 instead would force
//   the LCD divide to be an integer, which is impossible from a 50 MHz input:
//   see the arithmetic below.
//
// Frequency derivation
//   The core clock is exactly 945/44 MHz = 21.477272727272... MHz.  The core
//   divides it by 4 with the 12 phase div_phase counter and ce_ppu is one core
//   clock in four, so the PPU dot rate is 945/176 MHz = 5.369318 MHz, which is
//   the NTSC dot rate.  The clock is therefore not "about 21.5 MHz": any other
//   frequency moves every PPU timing window.
//
//   Write CLKFBOUT_MULT_F = m/8 with m an integer, so f_vco = 50*m/8.  The core
//   divide is the integer k, so
//
//       f_core = (50*m/8)/k = 945/44    ->    2200*m = 7560*k
//                                        ->    55*m   = 189*k
//
//   55 and 189 are coprime, so m must be a multiple of 189 and k a multiple of
//   55.  The smallest pair is m = 189, k = 55:
//
//       CLKFBOUT_MULT_F  = 189/8 = 23.625          (primitive range 2.0 to 64.0)
//       DIVCLK_DIVIDE    = 1
//       f_vco            = 50 * 23.625 / 1 = 1181.25 MHz
//                                      (7-series MMCM VCO range 600 to 1200)
//       CLKOUT1_DIVIDE   = 55        (integer, 1 to 128)
//       f_core           = 1181.25 / 55       = 21.477272727272 MHz
//
//   Then the LCD divide must be f_vco/25 = 47.25, and 47.25 = 378/8, so it is an
//   exact multiple of the 0.125 step CLKOUT0_DIVIDE_F allows:
//
//       CLKOUT0_DIVIDE_F = 378/8 = 47.25
//       f_lcd            = 1181.25 / 47.25 = 25.000000000 MHz
//
//   Nothing in that chain is rounded, so the achieved frequencies are the
//   targets to the last bit the dividers can encode.
//
//   Why not a 1000 MHz VCO, the usual first guess.  A 1000 MHz VCO would need
//   CLKOUT1_DIVIDE = 1000/(945/44) = 46.560846560846..., which is not an
//   integer, and CLKOUT0_DIVIDE_F = 46.5625, the nearest multiple of 0.125,
//   gives 1000/46.5625 = 21.476510067114 MHz, 763 Hz low.  The CPU and PPU would
//   then run 0.0036 percent slow and the frame period would be visibly long.
//   The 1181.25 MHz VCO hits the frequency exactly instead.
//
// LCD clock
//   The vendor panel is 1056x525 with an 800x480 active area in DE mode.  The
//   vendor demo drives it with a divide by two of the 50 MHz input, which is
//   25 MHz and 45.1 Hz refresh.  A true 60 Hz would want 1056*525*60 =
//   33.264 MHz, which is awkward to reach from 50 MHz and is a separate design
//   decision, so 25 MHz is produced here to match the vendor and the divider is
//   a parameter so the platform top can change it later without touching this
//   module.  A different LCD target needs the derivation above re-run, because
//   the pair m/k that makes the core clock exact can move.
//
// locked, and why the platform top must use it
//   MMCME2_BASE LOCKED deasserts while the VCO is settling and its outputs are
//   not usable before that point.  locked is passed straight out of the
//   primitive with no masking and no resynchronisation here.  The platform top
//   must hold the NES core in reset until locked is high, for example
//
//       assign core_rst_n = rst_in_n & nes_locked;
//       nes_sync_rst_n  <= core_rst_n & nes_locked;   // released in core_clk
//
//   Releasing the core before locked means the core starts counting on a clock
//   that is still slewing, and the reset release lands at an arbitrary point in
//   the settling window.
//
// Simulation
//   MMCME2_BASE is a device primitive and cannot be simulated by Icarus, so the
//   instantiation is selected by macro.  Vivado defines SYNTHESIS during
//   synthesis and gets the real primitive and the real feedback BUFG; anything
//   else gets a plain wire for the feedback and the behavioural
//   mmcm_e2_base_sim model, which lives in tb/platform/tb_nes_zynq_clk.v.  The
//   model derives its output periods from the same parameters the primitive
//   takes, so a parameter error shows up as a frequency error in the testbench
//   edge count rather than as a silent elaboration success.
// ============================================================================

`ifdef SYNTHESIS
  `define NES_ZYNQ_MMCM_CELL MMCME2_BASE
  `define NES_ZYNQ_MMCM_FB   nes_zynq_clk_fb_bufg
`else
  `define NES_ZYNQ_MMCM_CELL mmcm_e2_base_sim
  `define NES_ZYNQ_MMCM_FB   nes_zynq_clk_fb_wire
`endif

module nes_zynq_clk #(
    // f_in in Hz.  Documentation only, the primitive is told the period.
    parameter CLK_IN_HZ         = 50_000_000,
    // CLKIN1_PERIOD in ns, 20.000 ns for the 50 MHz board oscillator.  Vivado
    // times the MMCM from this value, so it must match the real input.
    parameter CLK_IN_PERIOD     = 20.000,
    // MMCM parameters, see the derivation in the header.
    parameter CLKFBOUT_MULT_F   = 23.625,
    parameter DIVCLK_DIVIDE     = 1,
    // CLKOUT0 carries the LCD clock and is the only fractional divide.
    parameter CLKOUT0_DIVIDE_F  = 47.25,
    // CLKOUT1 carries the NES core clock on an integer divide.
    parameter CLKOUT1_DIVIDE    = 55
) (
    // 50 MHz board oscillator, package pin U18.
    input  wire clk_in,
    // Active high, drives the primitive RST input.  Hold high until the board
    // power rails and the oscillator are stable.
    input  wire rst_in,
    // 25 MHz LCD dot clock.  Parameter driven, see the header.
    output wire lcd_clk,
    // 21.477272727272 MHz NES core clock.
    output wire core_clk,
    // MMCM LOCKED, straight from the primitive.  The platform top must keep
    // the NES core in reset while this is low.
    output wire locked
);

    wire clkfb_out;
    wire clkfb_in;

// Every port of MMCME2_BASE is connected.  The primitive declares 18 ports and
// Vivado treats an omitted one as an error, even when it is an unused output,
// so the unused CLKOUT2..6 and the inverted outputs are tied off explicitly.
`NES_ZYNQ_MMCM_CELL #(
    .CLKFBOUT_MULT_F    (CLKFBOUT_MULT_F),
    .CLKOUT0_DIVIDE_F   (CLKOUT0_DIVIDE_F),
    .CLKOUT1_DIVIDE     (CLKOUT1_DIVIDE),
    .DIVCLK_DIVIDE      (DIVCLK_DIVIDE),
    .CLKIN1_PERIOD      (CLK_IN_PERIOD),
    .BANDWIDTH          ("OPTIMIZED"),
    .STARTUP_WAIT       ("FALSE")
) u_mmcm (
    .CLKIN1   (clk_in),
    .PWRDWN   (1'b0),
    .RST      (rst_in),
    .LOCKED   (locked),
    .CLKFBOUT (clkfb_out),
    .CLKFBOUTB(),
    .CLKFBIN  (clkfb_in),
    .CLKOUT0  (lcd_clk),
    .CLKOUT0B (),
    .CLKOUT1  (core_clk),
    .CLKOUT1B (),
    .CLKOUT2  (),
    .CLKOUT2B (),
    .CLKOUT3  (),
    .CLKOUT3B (),
    .CLKOUT4  (),
    .CLKOUT5  (),
    .CLKOUT6  ()
);

`NES_ZYNQ_MMCM_FB u_fb (
    .I(clkfb_out),
    .O(clkfb_in)
);

endmodule


// Synthesis only feedback buffer.  The MMCM feedback path needs a BUFG and
// Vivado does not insert one for a hand written primitive instance.
module nes_zynq_clk_fb_bufg (
    input  wire I,
    output wire O
);

    BUFG u_bufg (
        .I(I),
        .O(O)
    );

endmodule


// Simulation only feedback passthrough, so the same RTL source elaborates
// under Icarus without a BUFG primitive.
module nes_zynq_clk_fb_wire (
    input  wire I,
    output wire O
);

    assign O = I;

endmodule
