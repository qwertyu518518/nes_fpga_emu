`timescale 1ns/1ps

// ============================================================================
// nes_hdmi_tmds_serializer : 10:1 T.M.D.S. lane serialiser for one pair.
// ----------------------------------------------------------------------------
// Takes the 10-bit symbol a colour-lane encoder produced and shifts it out at
// ten times the pixel rate, least significant bit first, on an differential
// pair.  One instance drives one T.M.D.S. data pair, and a fourth instance
// (fed the fixed 10'b1111100000 preamble) drives the clock pair.
//
// Seven-series OSERDESE2 has only eight parallel inputs, so a 10-bit word is
// built from two cascaded blocks: the MASTER shifts D1..D8 while the SLAVE
// supplies the last two bits through SHIFTOUT1/SHIFTOUT2 into the master's
// SHIFTIN1/SHIFTIN2.  The slave therefore takes symbol[8] on D3 and symbol[9]
// on D4 -- that is the position pair whose SHIFTOUTs land on the master's two
// extension inputs for DATA_WIDTH = 10.  Both blocks run DATA_RATE_OQ = "DDR"
// on the 5x serial clock, two bits per serial clock, so the ten bits of a
// symbol occupy one pixel clock period.
//
// The output stage is one OBUFDS with IOSTANDARD "TMDS_33".  The vendor board
// XDC constrains only the P-side pin of each pair; the N-side is inferred from
// the package pin table, which is why this module names both halves.
//
// Icarus Verilog has no OSERDESE2 or OBUFDS primitive.  Those two are supplied
// by the behavioural models in tb/platform/nes_hdmi_tmds_prim_sim.v, which the
// simulation gate compiles for every target that elaborates this module.  The
// same source elaborates in Vivado against the real primitives because that
// file is testbench-only and is never added to a synthesis file set.
// ============================================================================

module nes_hdmi_tmds_serializer (
    // Active high reset, for the primitive RST inputs.
    input  wire       rst,
    // Parallel (pixel) clock; the OSERDESE2 CLKDIV input.
    input  wire       pclk,
    // Serial clock, five times pclk; the OSERDESE2 CLK input.  DDR doubles
    // this to the ten bits per pixel clock.
    input  wire       pclk_x5,
    // The 10-bit symbol, symbol[0] transmitted first.
    input  wire [9:0] symbol,
    // The serial stream and its complement, one T.M.D.S. pair.
    output wire       serial_p,
    output wire       serial_n
);

    // The two bits the slave hands to the master.
    wire cascade_1;
    wire cascade_2;
    // The serial stream before the output buffer.
    wire serial;

    OSERDESE2 #(
        .DATA_RATE_OQ   ("DDR"),
        .DATA_RATE_TQ   ("SDR"),
        .DATA_WIDTH     (10),
        .SERDES_MODE    ("MASTER"),
        .TRISTATE_WIDTH (1)
    ) u_master (
        .OQ        (serial),
        .CLK       (pclk_x5),
        .CLKDIV    (pclk),
        .D1        (symbol[0]),
        .D2        (symbol[1]),
        .D3        (symbol[2]),
        .D4        (symbol[3]),
        .D5        (symbol[4]),
        .D6        (symbol[5]),
        .D7        (symbol[6]),
        .D8        (symbol[7]),
        .OCE       (1'b1),
        .SHIFTIN1  (cascade_1),
        .SHIFTIN2  (cascade_2),
        .SHIFTOUT1 (),
        .SHIFTOUT2 (),
        .OFB       (),
        .TQ        (),
        .TFB       (),
        .TBYTEOUT  (),
        .T1        (1'b0),
        .T2        (1'b0),
        .T3        (1'b0),
        .T4        (1'b0),
        .TBYTEIN   (1'b0),
        .TCE       (1'b0),
        .RST       (rst)
    );

    OSERDESE2 #(
        .DATA_RATE_OQ   ("DDR"),
        .DATA_RATE_TQ   ("SDR"),
        .DATA_WIDTH     (10),
        .SERDES_MODE    ("SLAVE"),
        .TRISTATE_WIDTH (1)
    ) u_slave (
        .OQ        (),
        .CLK       (pclk_x5),
        .CLKDIV    (pclk),
        .D1        (1'b0),
        .D2        (1'b0),
        .D3        (symbol[8]),
        .D4        (symbol[9]),
        .D5        (1'b0),
        .D6        (1'b0),
        .D7        (1'b0),
        .D8        (1'b0),
        .OCE       (1'b1),
        .SHIFTIN1  (1'b0),
        .SHIFTIN2  (1'b0),
        .SHIFTOUT1 (cascade_1),
        .SHIFTOUT2 (cascade_2),
        .OFB       (),
        .TQ        (),
        .TFB       (),
        .TBYTEOUT  (),
        .T1        (1'b0),
        .T2        (1'b0),
        .T3        (1'b0),
        .T4        (1'b0),
        .TBYTEIN   (1'b0),
        .TCE       (1'b0),
        .RST       (rst)
    );

    OBUFDS #(
        .IOSTANDARD ("TMDS_33")
    ) u_pair (
        .I  (serial),
        .O  (serial_p),
        .OB (serial_n)
    );

endmodule
