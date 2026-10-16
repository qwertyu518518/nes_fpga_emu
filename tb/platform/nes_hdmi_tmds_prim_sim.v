`timescale 1ns/1ps

// ============================================================================
// nes_hdmi_tmds_prim_sim : behavioural stand-ins for the two Xilinx 7-series
// primitives that rtl/platform/zynq/nes_hdmi_tmds_serializer.v instantiates.
// ----------------------------------------------------------------------------
// Testbench only, not part of the RTL.  Icarus Verilog has no OSERDESE2 and no
// OBUFDS, and silently resolving either to nothing would make the serialiser
// target elaborate against a hole, so both are modelled here with the real
// primitive port lists.  This file is compiled by tools/sim_all.ps1 for every
// gate target that elaborates the serialiser (hdmi-serializer-core and
// hdmi-tx-core); it is never added to a synthesis file set, so Vivado still
// binds the real primitives.
//
// OSERDESE2 model
//   The only configuration this project uses is DATA_WIDTH = 10, DDR, cascaded
//   MASTER + SLAVE.  The model reproduces exactly that:
//
//     * a MASTER latches a ten-bit word on CLKDIV from its own D1..D8 plus
//       SHIFTIN1/SHIFTIN2 (the two bits the slave supplies); the word is
//       {SHIFTIN2, SHIFTIN1, D8..D1}, which is the parallel symbol with bit 0
//       first, and it shifts out two bits per CLK period (DDR), LSB first;
//     * a SLAVE presents the two extension bits on SHIFTOUT1/SHIFTOUT2.  The
//       serialiser wires symbol[8] to the slave's D3 and symbol[9] to D4, so the
//       model drives SHIFTOUT1 = D3 / SHIFTOUT2 = D4, which is what lands on
//       the master's SHIFTIN1/SHIFTIN2 for DATA_WIDTH = 10.
//
//   It is a functional model for elaboration and coarse simulation, not a
//   bit-accurate replica: it assumes CLK is the exact 5x of CLKDIV that the
//   interface promises, and it does not model the tristate path (T1..T4, TQ,
//   TFB, TBYTEOUT are inert).  Nothing in the gate depends on its exact edge
//   placement; the encoder's correctness is proven by tb_nes_hdmi_tmds_encoder
//   against the DVI specification, not against this model.
//
// OBUFDS model
//   A plain differential output buffer: O = I, OB = ~I.  It exists only so the
//   TMDS_33 pair the serialiser instantiates can elaborate.
// ============================================================================

module OSERDESE2 #(
    parameter DATA_RATE_OQ   = "DDR",
    parameter DATA_RATE_TQ   = "DDR",
    parameter DATA_WIDTH     = 8,
    parameter INIT_OQ        = 1'b0,
    parameter INIT_TQ        = 1'b0,
    parameter SERDES_MODE    = "MASTER",
    parameter SRVAL_OQ       = 1'b0,
    parameter SRVAL_TQ       = 1'b0,
    parameter TBYTE_CTL      = "FALSE",
    parameter TBYTE_SRC      = "FALSE",
    parameter TRISTATE_WIDTH = 4
) (
    output wire OFB,
    output reg  OQ,
    output wire SHIFTOUT1,
    output wire SHIFTOUT2,
    output wire TBYTEOUT,
    output wire TFB,
    output wire TQ,
    input  wire CLK,
    input  wire CLKDIV,
    input  wire D1,
    input  wire D2,
    input  wire D3,
    input  wire D4,
    input  wire D5,
    input  wire D6,
    input  wire D7,
    input  wire D8,
    input  wire OCE,
    input  wire RST,
    input  wire SHIFTIN1,
    input  wire SHIFTIN2,
    input  wire T1,
    input  wire T2,
    input  wire T3,
    input  wire T4,
    input  wire TBYTEIN,
    input  wire TCE
);

    // Mode is selected once at time zero so the continuous assignments below
    // need no string comparison.
    reg master_mode;
    reg slave_mode;
    initial begin
        master_mode = (SERDES_MODE == "MASTER");
        slave_mode  = (SERDES_MODE == "SLAVE");
    end

    // A slave's two extension bits are its D3 and D4.
    assign SHIFTOUT1 = slave_mode ? D3 : 1'b0;
    assign SHIFTOUT2 = slave_mode ? D4 : 1'b0;

    // Tristate path is not modelled.
    assign OFB      = 1'b0;
    assign TFB      = 1'b0;
    assign TQ       = 1'b0;
    assign TBYTEOUT = 1'b0;

    // The word a master shifts out: bit 0 is D1, bit 9 is SHIFTIN2.
    wire [9:0] load_word = {SHIFTIN2, SHIFTIN1, D8, D7, D6, D5, D4, D3, D2, D1};

    reg  [9:0] shift_reg;
    reg  [3:0] phase;

    // A master latches the parallel word on the parallel clock.
    always @(posedge CLKDIV or posedge RST) begin
        if (RST)
            shift_reg <= 10'd0;
        else if (master_mode)
            shift_reg <= load_word;
    end

    // DDR: two bits shift out per serial clock, LSB first, wrapping every ten.
    always @(CLK or posedge RST) begin
        if (RST) begin
            OQ    <= INIT_OQ;
            phase <= 4'd0;
        end
        else if (master_mode && OCE) begin
            OQ    <= shift_reg[phase];
            phase <= (phase == 4'd9) ? 4'd0 : phase + 4'd1;
        end
    end

endmodule


module OBUFDS #(
    parameter IOSTANDARD = "DEFAULT",
    parameter SLEW       = "SLOW"
) (
    input  wire I,
    output wire O,
    output wire OB
);

    assign O  =  I;
    assign OB = ~I;

endmodule
