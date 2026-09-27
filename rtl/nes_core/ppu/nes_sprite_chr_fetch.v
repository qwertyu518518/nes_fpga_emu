// nes_sprite_chr_fetch : fetch the 8 visible sprite patterns into a 128-bit shadow.
//
// Handshake and ordering
//   * ce is the only enable; every register freezes while ce is 0.
//   * start is accepted only while busy is 0; a start seen while busy is 1 is dropped.
//   * Byte order is fixed: slot0.lo, slot0.hi, slot1.lo, slot1.hi, ... slot7.hi.
//   * Shadow landing: slot g low plane -> shadow[g*16 +: 8],
//                    slot g high plane -> shadow[g*16+8 +: 8].
//   * Address per slot: chr_addr is a byte address into the local 8 KiB CHR window.
//     The port is 14 bits wide but only 13 bits of address exist (see Integration
//     limits below), and one tile is 16 bytes, so the two planes of a tile are
//     8 bytes apart:
//                       low  plane = pat_addr[g*13 +: 13]
//                       high plane = pat_addr[g*13 +: 13] + 8
//     pat_addr[g*13 +: 13] is {s_table, s_tile[7:0], 1'b0, s_fine[2:0]} as produced
//     by nes_ppu_sprite (nes_ppu_sprite.v:295), i.e. 1 + 8 + 1 + 3 = 13 bits: it is
//     already tile*16 + fine, with fine the row inside the tile. s_tile is the full
//     8-bit OAM tile byte in 8x8 mode and {s_tile_byte[7:1], s_row[3]} in 8x16 mode
//     (nes_ppu_sprite.v:293), with no bit masked off, so there is no 128-tile
//     half-table anywhere in the sprite path. No scaling is applied here: this unit
//     drives the same byte address that nes_chr_fetch_unit drives for the background.
//     Example pat 0x1F8: low = 0x01F8, high = 0x0200.
//     Same two bytes, other notation: nes_ppu_sprite's internal path reads them
//     from its flat 65536-bit chr bus as chr[{pat,3'b000} +: 8] and
//     chr[{pat,3'b000} + 13'd64 +: 8]. That is a *bit* index taken 8 bits at a
//     time, so {pat,3'b000} bits is byte pat and +13'd64 bits is +8 bytes. Both
//     notations name the same bytes; only this unit's output is a byte address.
//
// Timing in ce cycles, numbering the start-accepting edge as edge 1
//   edge 1          : start latched, busy=1, shadow_valid=0.
//   edge 2          : chr_addr registered for byte 0 (1-beat address prefetch).
//   edges 3,5..33   : chr_req pulses, 16 pulses, one ce wide, one every 2 ce.
//   edges 4,6..34   : chr_rdata valid; chr_addr for the next byte registered.
//   edges 5,7..35   : chr_rdata written into shadow.
//   edge 36         : shadow_valid=1 (held until the next start), busy=0.
//   start to shadow_valid is therefore 35 ce cycles (36 ce edges): 4 ce for the
//   first byte, 2 ce for every later byte. This is the same
//   "1-beat prefetch + back-to-back issue" cadence as nes_chr_fetch_unit, so the
//   shared CHR bus needs no change when both fetchers are instantiated.
//
// Integration limits
//   * The local address is 13 bits of pattern address on a 14-bit port, so
//     chr_addr[13] is declared but structurally always 0 and no stimulus can raise
//     it. plane_byte forms the sum in 14 bits as {1'b0, pat} + (p ? 14'd8 :
//     14'd0); pat is 13 bits, so pat[12] -- the pattern-table select -- lands on bit
//     12 of the sum and never on bit 13. pat is {s_table, s_tile[7:0], 1'b0,
//     s_fine[2:0]}, so its bit 3 is the hard 1'b0 of the 16-byte alignment and
//     pat <= 0x1FF7; the largest address this unit can emit is 0x1FF7 + 8 = 0x1FFF,
//     the top of the one 8 KiB window. The `sum & 14'h3FFF` mask is therefore
//     lossless rather than a wrap: nothing reaches 0x2000, so the mask never
//     actually fires and there is no second 8 KiB above the window for it to name
//     or mirror.  An 8 KiB CHR memory indexed on chr_addr[12:0] therefore loses
//     nothing.  PPUCTRL[4] / [5] select WITHIN that one window rather than
//     choosing between two banks, which is why every mapper may drop
//     chr_addr[13] and instead consumes bit 12 as its own window select.
//   * Prefetch runs one line ahead of the pixels that use it, and it is the
//     ADDRESS that has to lead, not the start dot. shadow_valid rises 35 ce
//     after start, which lands at dot 292 of the issuing line, i.e. after
//     that line's dots 0..255 have already been displayed. So a same-line
//     address can never serve that line's own pixels, at any start dot.
//     pat_addr therefore must already be the NEXT line's addresses when it
//     arrives here, which is what pat_addr_o now provides, and start stays at
//     dot 257 of every line. Issuing start a line earlier is NOT equivalent:
//     pat_addr derives from the scanline port, so at line L-1 it would still
//     carry line L-1's addresses and fetch one line too early.
//   * shadow_valid stays high until the next start; shadow itself is not cleared
//     by reset, only by the 16 writes of the current fetch.

`timescale 1ns/1ps

module nes_sprite_chr_fetch (
  input  wire         clk,
  input  wire         ce,
  input  wire         reset,
  input  wire         start,
  input  wire [103:0] pat_addr,
  output reg          chr_req,
  output reg  [13:0]  chr_addr,
  input  wire [7:0]   chr_rdata,
  output reg  [127:0] shadow,
  output reg          shadow_valid,
  output reg          busy
);

  localparam [2:0] S_IDLE = 3'd0;
  localparam [2:0] S_PRE  = 3'd1;
  localparam [2:0] S_ARM  = 3'd2;
  localparam [2:0] S_BEAT = 3'd3;
  localparam [2:0] S_GRAB = 3'd4;
  localparam [2:0] S_DONE = 3'd5;

  function [13:0] plane_byte;
    input [103:0] pa;
    input [2:0]   g;
    input         p;
    reg   [12:0]  pat;
    reg   [13:0]  sum;
    begin
      pat        = pa[g * 13 +: 13];
      sum        = {1'b0, pat} + (p ? 14'd8 : 14'd0);
      plane_byte = sum & 14'h3FFF;
    end
  endfunction

  reg  [2:0]   state;
  reg  [103:0] pat_q;
  reg  [2:0]   grp_q;
  reg          pl_q;
  reg          cap_pl;
  reg  [2:0]   cap_grp;
  reg          fin_q;

  wire         last_byte = pl_q && (grp_q == 3'd7);
  wire [13:0]  cur_addr  = plane_byte(pat_q, grp_q, pl_q);
  wire [13:0]  fwd_addr  = pl_q ? plane_byte(pat_q, grp_q + 3'd1, 1'b0)
                                 : plane_byte(pat_q, grp_q, 1'b1);

  always @(posedge clk) begin
    if (reset) begin
      state        <= S_IDLE;
      pat_q        <= 104'd0;
      grp_q        <= 3'd0;
      pl_q         <= 1'b0;
      cap_pl       <= 1'b0;
      cap_grp      <= 3'd0;
      fin_q        <= 1'b0;
      chr_req      <= 1'b0;
      chr_addr     <= 14'd0;
      shadow_valid <= 1'b0;
      busy         <= 1'b0;
    end else if (ce) begin
      case (state)
        S_IDLE: begin
          if (start && !busy) begin
            pat_q        <= pat_addr;
            grp_q        <= 3'd0;
            pl_q         <= 1'b0;
            state        <= S_PRE;
            busy         <= 1'b1;
            shadow_valid <= 1'b0;
          end
        end

        S_PRE: begin
          chr_addr <= cur_addr;
          state    <= S_ARM;
        end

        S_ARM: begin
          chr_req <= 1'b1;
          state   <= S_BEAT;
        end

        S_BEAT: begin
          chr_req <= 1'b0;
          cap_pl  <= pl_q;
          cap_grp <= grp_q;
          fin_q   <= last_byte;
          if (pl_q) grp_q <= grp_q + 3'd1;
          pl_q     <= ~pl_q;
          if (!last_byte) chr_addr <= fwd_addr;
          state    <= S_GRAB;
        end

        S_GRAB: begin
          if (cap_pl) shadow[cap_grp * 16 + 8 +: 8] <= chr_rdata;
          else        shadow[cap_grp * 16 +: 8]     <= chr_rdata;
          if (fin_q) begin
            state <= S_DONE;
          end else begin
            chr_req <= 1'b1;
            state   <= S_BEAT;
          end
        end

        S_DONE: begin
          busy         <= 1'b0;
          shadow_valid <= 1'b1;
          state        <= S_IDLE;
        end

        default: state <= S_IDLE;
      endcase
    end
  end

endmodule
