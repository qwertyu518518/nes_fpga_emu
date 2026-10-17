`timescale 1ns/1ps

// ============================================================================
// nes_hdmi_tx : HDMI/DVI transmit core, mode independent.
// ----------------------------------------------------------------------------
// Standard parallel video in, T.M.D.S. pairs out.  Three colour-lane encoders
// feed three data serialisers, and a fourth serialiser drives the clock pair
// with the fixed DVI clock preamble 10'b1111100000.  Everything here is
// parameter-free and mode-independent: the pixel clock, the 5x serial clock and
// the sync/active timing all arrive from the caller, so the video mode is a
// decision the caller makes and not one this core bakes in.
//
//   rgb888[23:0] : {red[7:0], green[7:0], blue[7:0]}
//   hsync, vsync : encoded onto the blue lane's c0/c1 controls (the DVI channel
//                  mapping); the green and red lanes hold both controls low.
//   de           : high while the pixel is active video.  Low (blanking) makes
//                  every lane emit a control symbol and makes hsync/vsync
//                  visible on the blue pair.
//
// Reset.  reset_n is asynchronous to both clocks.  Two independent two-flop
// synchronisers inside this wrapper re-time it: one in pclk for the encoders
// (asynchronous assert, synchronous release) and one in pclk_x5 for the
// serialisers' RST.  The serialiser chain is the one the task calls out, but
// the encoder chain gets the same treatment rather than walking a board reset
// straight into pixel-domain flops.  The serialiser RST is active high, so the
// pclk_x5 synchroniser's reset is inverted for it.
//
// Integration.  This module IS instantiated, by nes_zynq_top.v, and the four
// Bank 35 pairs ARE constrained in nes_zynq_top.xdc as TMDS_33.  The video mode
// was chosen as 720x480p60, so pclk = 27.000 MHz and pclk_x5 = 135.000 MHz,
// both from the second MMCM (u_mmcm_hdmi, VCO 675 MHz).  The earlier text here
// said the module was deliberately not instantiated and that the mode was still
// open; both were true when it was written and were stale by the time the
// integration landed.  Clock arithmetic and the mode rationale are in
// docs/modules/hdmi-tx.md.
// ============================================================================

module nes_hdmi_tx (
    // Pixel clock, also the parallel load clock of every serialiser.
    input  wire        pclk,
    // Serial clock, five times pclk.
    input  wire        pclk_x5,
    // Asynchronous board reset, active low.
    input  wire        reset_n,
    // {red[7:0], green[7:0], blue[7:0]}.
    input  wire [23:0] rgb888,
    input  wire        hsync,
    input  wire        vsync,
    input  wire        de,
    // The four T.M.D.S. pairs.
    output wire [2:0]  tmds_data_p,
    output wire [2:0]  tmds_data_n,
    output wire        tmds_clk_p,
    output wire        tmds_clk_n
);

    // ---- reset synchronisers -------------------------------------------
    // Asynchronous assert, two-flop synchronous release, one per clock domain.
    reg pclk_sync_1;
    reg pclk_sync_n;
    reg x5_sync_1;
    reg x5_sync_n;

    always @(posedge pclk or negedge reset_n) begin
        if (!reset_n) begin
            pclk_sync_1 <= 1'b0;
            pclk_sync_n <= 1'b0;
        end
        else begin
            pclk_sync_1 <= 1'b1;
            pclk_sync_n <= pclk_sync_1;
        end
    end

    always @(posedge pclk_x5 or negedge reset_n) begin
        if (!reset_n) begin
            x5_sync_1 <= 1'b0;
            x5_sync_n <= 1'b0;
        end
        else begin
            x5_sync_1 <= 1'b1;
            x5_sync_n <= x5_sync_1;
        end
    end

    // The encoders take an active-low reset; the serialisers' primitive RST is
    // active high.
    wire rst_enc_n = pclk_sync_n;
    wire rst_ser   = ~x5_sync_n;

    // ---- three colour-lane encoders ------------------------------------
    wire [9:0] blue_symbol;
    wire [9:0] green_symbol;
    wire [9:0] red_symbol;

    nes_hdmi_tmds_encoder u_encoder_blue (
        .clk   (pclk),
        .rst_n (rst_enc_n),
        .din   (rgb888[7:0]),
        .de    (de),
        .c0    (hsync),
        .c1    (vsync),
        .dout  (blue_symbol)
    );

    nes_hdmi_tmds_encoder u_encoder_green (
        .clk   (pclk),
        .rst_n (rst_enc_n),
        .din   (rgb888[15:8]),
        .de    (de),
        .c0    (1'b0),
        .c1    (1'b0),
        .dout  (green_symbol)
    );

    nes_hdmi_tmds_encoder u_encoder_red (
        .clk   (pclk),
        .rst_n (rst_enc_n),
        .din   (rgb888[23:16]),
        .de    (de),
        .c0    (1'b0),
        .c1    (1'b0),
        .dout  (red_symbol)
    );

    // ---- four serialisers ----------------------------------------------
    // The clock lane is not encoded: it always sends the DVI preamble.
    wire [9:0] clock_symbol = 10'b1111100000;

    nes_hdmi_tmds_serializer u_serial_blue (
        .rst      (rst_ser),
        .pclk     (pclk),
        .pclk_x5  (pclk_x5),
        .symbol   (blue_symbol),
        .serial_p (tmds_data_p[0]),
        .serial_n (tmds_data_n[0])
    );

    nes_hdmi_tmds_serializer u_serial_green (
        .rst      (rst_ser),
        .pclk     (pclk),
        .pclk_x5  (pclk_x5),
        .symbol   (green_symbol),
        .serial_p (tmds_data_p[1]),
        .serial_n (tmds_data_n[1])
    );

    nes_hdmi_tmds_serializer u_serial_red (
        .rst      (rst_ser),
        .pclk     (pclk),
        .pclk_x5  (pclk_x5),
        .symbol   (red_symbol),
        .serial_p (tmds_data_p[2]),
        .serial_n (tmds_data_n[2])
    );

    nes_hdmi_tmds_serializer u_serial_clock (
        .rst      (rst_ser),
        .pclk     (pclk),
        .pclk_x5  (pclk_x5),
        .symbol   (clock_symbol),
        .serial_p (tmds_clk_p),
        .serial_n (tmds_clk_n)
    );

endmodule
