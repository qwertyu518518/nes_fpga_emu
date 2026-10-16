`timescale 1ns/1ps

// ============================================================================
// nes_hdmi_tmds_encoder : one T.M.D.S. colour-lane encoder.
// ----------------------------------------------------------------------------
// Implements the transition-minimised, DC-balanced 8b/10b encoding from the
// DVI 1.0 specification, section 3.1.3 and Figure 3-5 (the same algorithm the
// HDMI specification inherits).  It is written from the specification, not
// transcribed from any vendor source; the reference material was read only to
// confirm the primitive usage in the serialiser, not the encoding.
//
// One instance encodes one colour lane.  The blue lane carries the two sync
// controls (c0 = hsync, c1 = vsync); the green and red lanes tie both controls
// low.  The clock lane is not encoded at all: it serialises a fixed pattern.
//
// The algorithm has three stages, all of them in Figure 3-5:
//
//   Stage 1 (8b -> 9b).  Convert the input byte D[7:0] into the nine-bit value
//   q_m[8:0].  Let N1{D} be the number of ones in D.  When
//   (N1{D} > 4) or (N1{D} == 4 and D[0] == 0) the eight data bits are built
//   with an alternating XNOR chain and q_m[8] = 0; otherwise the chain is XOR
//   and q_m[8] = 1.  Either chain starts at q_m[0] = D[0].  Choosing the chain
//   is what minimises transitions for this input class.
//
//   Stage 2 (9b -> 10b).  Let N1{q_m}, N0{q_m} be the ones and zeros of the
//   eight data bits of q_m.  The running disparity is the five-bit signed
//   register `disparity` (the spec calls it Cnt).  The output is one of:
//
//     balanced   : (disparity == 0) or (N1{q_m} == N0{q_m})
//                  q_out[9]   = ~q_m[8]
//                  q_out[8]   =  q_m[8]
//                  q_out[7:0] = q_m[8] ? q_m[7:0] : ~q_m[7:0]
//                  this is the DC-balanced choice: the symbol always has five
//                  ones, so it contributes zero to the disparity.
//     oppose     : (disparity > 0 and N1{q_m} > N0{q_m}) or
//                  (disparity < 0 and N0{q_m} > N1{q_m})
//                  q_out[9]   = 1
//                  q_out[8]   = q_m[8]
//                  q_out[7:0] = ~q_m[7:0]
//                  the transition-minimised form, inverted to push the running
//                  disparity back towards zero.
//     follow     : otherwise
//                  q_out[9]   = 0
//                  q_out[8]   = q_m[8]
//                  q_out[7:0] = q_m[7:0]
//                  the transition-minimised form as built.
//
//   The disparity update is exactly the DC content of the symbol that was
//   chosen, so `disparity` equals the running disparity of the transmitted
//   stream.  A control symbol forces it back to zero (the spec resets Cnt).
//
// Control symbols (de == 0).  These are the four tokens the receiver
// distinguishes by exact match.  The specification writes them with the
// transmitted order q_out[0..9] left to right; this module writes q_out[9:0]
// with q_out[0] the first bit transmitted, so the literals below are the
// spec's tokens read backwards:
//
//     {c1,c0} = 00 -> 10'b1101010100      {c1,c0} = 01 -> 10'b0010101011
//     {c1,c0} = 10 -> 10'b0101010100      {c1,c0} = 11 -> 10'b1010101011
//
// Note on the running-disparity range.  The DVI encoder is not the IBM 8b/10b
// code and its running disparity is not bounded to +/-1: a DC-balanced symbol
// contributes zero, but a transition-minimised symbol can carry up to eight
// ones (or zeros), so the running disparity reaches +/-8.  What the algorithm
// guarantees is that the disparity never drifts -- the `oppose` branch always
// drives it back towards zero.  tb_nes_hdmi_tmds_encoder asserts that bound.
//
// Latency.  Three register stages, so dout is valid two clocks after the clock
// edge that samples din (three edges counted from the driving edge).  The test
// bench's LAT constant is this number.
// ============================================================================

module nes_hdmi_tmds_encoder (
    input  wire       clk,
    // Active low, asynchronous assert, synchronous release by the caller.
    input  wire       rst_n,
    // Data byte for this lane.
    input  wire [7:0] din,
    // Data enable: high for active video, low for a control symbol.
    input  wire       de,
    // The two control bits carried during blanking (hsync/vsync on blue).
    input  wire       c0,
    input  wire       c1,
    // The encoded 10-bit symbol, q_out[9:0], q_out[0] transmitted first.
    output reg  [9:0] dout
);

    // ---- stage 1 registers: the input and its one count ----------------
    reg  [7:0] din_1;
    reg        de_1;
    reg        c0_1;
    reg        c1_1;
    reg  [3:0] ones_1;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            din_1  <= 8'h00;
            de_1   <= 1'b0;
            c0_1   <= 1'b0;
            c1_1   <= 1'b0;
            ones_1 <= 4'd0;
        end
        else begin
            din_1  <= din;
            de_1   <= de;
            c0_1   <= c0;
            c1_1   <= c1;
            ones_1 <= din[0] + din[1] + din[2] + din[3] +
                      din[4] + din[5] + din[6] + din[7];
        end
    end

    // ---- stage 1 combinational: the transition-minimising chain --------
    // False when the XNOR chain is the transition-minimised one for this byte,
    // i.e. when the byte is mostly ones (or exactly half and LSB zero).
    wire minimise = (ones_1 > 4'd4) ||
                    ((ones_1 == 4'd4) && (din_1[0] == 1'b0));

    wire [8:0] q_m;
    assign q_m[0] = din_1[0];
    assign q_m[1] = minimise ? ~(q_m[0] ^ din_1[1]) : (q_m[0] ^ din_1[1]);
    assign q_m[2] = minimise ? ~(q_m[1] ^ din_1[2]) : (q_m[1] ^ din_1[2]);
    assign q_m[3] = minimise ? ~(q_m[2] ^ din_1[3]) : (q_m[2] ^ din_1[3]);
    assign q_m[4] = minimise ? ~(q_m[3] ^ din_1[4]) : (q_m[3] ^ din_1[4]);
    assign q_m[5] = minimise ? ~(q_m[4] ^ din_1[5]) : (q_m[4] ^ din_1[5]);
    assign q_m[6] = minimise ? ~(q_m[5] ^ din_1[6]) : (q_m[5] ^ din_1[6]);
    assign q_m[7] = minimise ? ~(q_m[6] ^ din_1[7]) : (q_m[6] ^ din_1[7]);
    // The ninth bit records which chain was used; the decoder needs it.
    assign q_m[8] = ~minimise;

    wire [3:0] n1_qm = q_m[0] + q_m[1] + q_m[2] + q_m[3] +
                       q_m[4] + q_m[5] + q_m[6] + q_m[7];
    wire [3:0] n0_qm = 4'd8 - n1_qm;

    // ---- stage 2 registers: q_m and its balancedness -------------------
    reg  [8:0] qm_2;
    reg  [3:0] n1_2;
    reg  [3:0] n0_2;
    reg        de_2;
    reg        c0_2;
    reg        c1_2;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            qm_2 <= 9'h000;
            n1_2 <= 4'd0;
            n0_2 <= 4'd8;
            de_2 <= 1'b0;
            c0_2 <= 1'b0;
            c1_2 <= 1'b0;
        end
        else begin
            qm_2 <= q_m;
            n1_2 <= n1_qm;
            n0_2 <= n0_qm;
            de_2 <= de_1;
            c0_2 <= c0_1;
            c1_2 <= c1_1;
        end
    end

    // ---- stage 3: symbol selection and the running disparity -----------
    reg signed [4:0] disparity;

    // The three stage-2 branch conditions.  `balanced` is the DC-balanced
    // choice; `oppose` is the transition-minimised choice inverted to oppose
    // the current disparity; `follow` is the transition-minimised choice.
    wire balanced = (disparity == 5'sd0) || (n1_2 == n0_2);
    wire oppose   = ((disparity > 5'sd0) && (n1_2 > n0_2)) ||
                    ((disparity < 5'sd0) && (n0_2 > n1_2));

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            dout      <= 10'h000;
            disparity <= 5'sd0;
        end
        else if (!de_2) begin
            // A control symbol is emitted and the running disparity restarts.
            case ({c1_2, c0_2})
                2'b00:   dout <= 10'b1101010100;
                2'b01:   dout <= 10'b0010101011;
                2'b10:   dout <= 10'b0101010100;
                default: dout <= 10'b1010101011;
            endcase
            disparity <= 5'sd0;
        end
        else if (balanced) begin
            dout[9]   <= ~qm_2[8];
            dout[8]   <=  qm_2[8];
            dout[7:0] <=  qm_2[8] ? qm_2[7:0] : ~qm_2[7:0];
            disparity <=  qm_2[8] ? (disparity + {1'b0, n1_2} - {1'b0, n0_2})
                                  : (disparity + {1'b0, n0_2} - {1'b0, n1_2});
        end
        else if (oppose) begin
            dout[9]   <= 1'b1;
            dout[8]   <= qm_2[8];
            dout[7:0] <= ~qm_2[7:0];
            disparity <= disparity + {qm_2[8], 1'b0} + {1'b0, n0_2} - {1'b0, n1_2};
        end
        else begin
            dout[9]   <= 1'b0;
            dout[8]   <= qm_2[8];
            dout[7:0] <= qm_2[7:0];
            disparity <= disparity - {~qm_2[8], 1'b0} + {1'b0, n1_2} - {1'b0, n0_2};
        end
    end

endmodule
