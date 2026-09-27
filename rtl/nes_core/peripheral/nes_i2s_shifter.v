`timescale 1ns/1ps

// nes_i2s_shifter: single sample bit serialiser for the I2S audio path
// (Verilog-2001, synthesisable, fully synchronous).
//
// Scope
//   This block owns nothing but the bit stream. There is no sample FIFO, no
//   bit clock divider and no clock domain crossing in here: one 32 bit stereo
//   sample is pushed in with sample_valid and 32 bits are popped out, one per
//   ce enabled clock, in I2S order. Rate conversion, buffering and CDC are
//   the job of the surrounding modules.
//
// Sample format
//   sample_data[15:0]  left  channel
//   sample_data[31:16] right channel
//   The left channel always leaves first: bit positions 0..15 of the stream
//   carry the left sample with out_lrck low, positions 16..31 carry the right
//   sample with out_lrck high, so out_lrck flips exactly on the 17th bit.
//
// Bit order
//   BIT_REVERSED = 0 (default) is MSB first: the left sample leaves as
//   left[15], left[14] ... left[0], then the right sample the same way.
//   BIT_REVERSED = 1 reverses the order inside each channel, left[0] ...
//   left[15] then right[0] ... right[15]. The channel order is untouched, the
//   left channel still occupies the first 16 positions.
//
// Throughput
//   One sample occupies exactly 32 ce enabled clocks: the 32nd of those clocks
//   shifts out bit 31 and empties the register, and a sample offered on that
//   very edge is loaded in the same clock, so the following edge already
//   shifts out bit 0 of the new sample. There is no dead clock between samples
//   and no 33rd done pulse; a sample that is not refilled simply leaves busy
//   low and the stream stops, with out_bit and out_lrck holding their last
//   value.
//
// Intake
//   A sample is taken on any clock edge that has sample_valid high while busy
//   is low, independent of ce: busy rises on that edge and the first bit
//   appears on the next ce enabled edge, never on the load edge itself.
//   The other accepting edge is the one that shifts out bit 31, which frees the
//   register in the same clock it is filled, so back to back samples stream
//   without a gap.
//   sample_valid raised while busy is high is discarded, unless that same edge
//   is a ce enabled bit 31 edge, which is the only case in which a busy shifter
//   can still take the sample. A discarded sample leaves the sample in flight
//   completely untouched and raises the sticky dropped flag until reset, so
//   dropped means the sample genuinely had nowhere to go.
//
// Outputs
//   out_valid is a one cycle strobe per output bit, so one sample produces
//   exactly 32 out_valid cycles. With ce low the state machine is frozen:
//   out_valid keeps its level, out_bit and out_lrck keep the current bit and
//   busy keeps its level, so a ce gap stretches the stream instead of losing
//   bits. dropped is a status flag and is not gated by ce.
//
// ready
//   ready = !busy || freeing is the intake permit of this block. It is high
//   exactly when a sample presented on sample_valid at the coming clock edge is
//   guaranteed to be taken: either the register is idle, or this very edge
//   shifts out bit 31 and refills in the same clock, which is the only edge on
//   which a busy shifter can still accept. A producer that shares this clock
//   may therefore drive sample_valid with it and never cause a drop, and a
//   producer that wants a sample waiting for the bit 31 edge can use it to know
//   that such an edge is coming.
//   ready is a pure observation of the two conditions the intake logic already
//   uses, so nothing about the existing behaviour changes: sample_valid raised
//   while the shifter cannot take it is still discarded, dropped is still
//   sticky, a sample still occupies 32 ce clocks, and back to back samples
//   still stream without a gap. It is a combinational function of busy, bit_cnt
//   and ce alone, all of which are already in this module's own clock domain,
//   so a driving block on the same clock can use it with no synchroniser.
//   ready is NOT a look ahead: it says nothing about any later edge. A
//   producer must therefore have its data in hand before an accepting edge
//   rather than fetch it on that edge, because the data cannot be produced in
//   the same clock the edge is evaluated.

module nes_i2s_shifter #(
    parameter BIT_REVERSED = 0
) (
    input  wire        clk,
    input  wire        reset,
    input  wire        ce,
    input  wire        sample_valid,
    input  wire [31:0] sample_data,
    output reg         out_valid,
    output reg         out_bit,
    output reg         out_lrck,
    output reg         busy,
    output reg         dropped,
    output wire        ready
);

    localparam [4:0] LAST_BIT = 5'd31;

    reg  [31:0] shift_reg;
    reg  [4:0]  bit_cnt;

    wire [4:0]  sel;
    wire        lrck_next;
    wire        freeing;

    assign sel       = (BIT_REVERSED != 0) ? bit_cnt : (bit_cnt ^ 5'h0f);
    assign lrck_next = bit_cnt[4];
    assign freeing   = ce && busy && (bit_cnt == LAST_BIT);
    assign ready     = !busy || freeing;

    always @(posedge clk) begin
        if (reset) begin
            shift_reg <= 32'h0;
            bit_cnt   <= 5'h0;
            out_valid <= 1'b0;
            out_bit   <= 1'b0;
            out_lrck  <= 1'b0;
            busy      <= 1'b0;
            dropped   <= 1'b0;
        end else begin
            if (sample_valid) begin
                if (busy && !freeing) begin
                    dropped <= 1'b1;
                end else begin
                    shift_reg <= sample_data;
                    bit_cnt   <= 5'h0;
                    busy      <= 1'b1;
                end
            end

            if (ce) begin
                out_valid <= 1'b0;
                if (busy) begin
                    out_valid <= 1'b1;
                    out_bit   <= shift_reg[sel];
                    out_lrck  <= lrck_next;
                    if (bit_cnt == LAST_BIT) begin
                        bit_cnt <= 5'd0;
                        busy    <= sample_valid;
                    end else begin
                        bit_cnt <= bit_cnt + 5'd1;
                    end
                end
            end
        end
    end

endmodule
