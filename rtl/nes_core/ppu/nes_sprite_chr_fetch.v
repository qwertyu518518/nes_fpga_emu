// nes_sprite_chr_fetch : fetch the 8 visible sprite patterns into a 128-bit shadow.
//
// Handshake and ordering
//   * ce is the only enable; every register freezes while ce is 0.
//   * start is accepted only while busy is 0; a start seen while busy is 1 is dropped.
//   * Byte order is fixed: slot0.lo, slot0.hi, slot1.lo, slot1.hi, ... slot7.hi.
//   * Shadow landing: slot g low plane -> shadow[g*16 +: 8],
//                    slot g high plane -> shadow[g*16+8 +: 8].
//   * Address per slot: low  plane = {1'b0, pat_addr[g*13 +: 13], 3'b000}
//                       high plane = low plane + 64, reduced modulo 2**14.
//     pat_addr[g*13 +: 13] is {table, 5'b0, tile[2:0], 1'b0, fine[2:0]} as produced
//     by nes_ppu_sprite, so fine is the row and the *8 scaling is done here.
//     Example pat 0x1FF: low = 0x0FF8, low+64 = 0x1038, modulo 2**14 = 0x0038.
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
//   * chr_addr[13] is always 0, so pat_addr bits [12:10] (the pattern table
//     select) never reach the bus and a pattern above 0x1FF*8 mirrors inside the
//     internal 8 KiB CHR window. Driving the upper 8 KiB of an external 16 KiB
//     CHR needs address bit 13, which this unit cannot produce.
//   * Prefetch runs a full line ahead of the pixels that use it: pat_addr must be
//     the value computed from the NEXT line's scanline_sel (nes_ppu_sprite feeds
//     scanline_sel into pat_addr_o) and start must be issued one scanline early.
//     Prefetching with the current line's pat_addr latches the wrong row.
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
    reg   [10:0]  rom;
    begin
      pat       = pa[g * 13 +: 13];
      rom       = pat[10:0] + (p ? 11'd8 : 11'd0);
      plane_byte = {rom, 3'b000};
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
