`timescale 1ns/1ps

// nes_ppu_sprite : per-dot combinational 8-slot sprite pixel selector.
//   Scans the 64 OAM entries for the ones whose vertical range covers the line,
//   picks the first 8 in OAM order, reads both pattern planes out of the CHR
//   bus, resolves horizontal position / mirroring / priority, and reports
//   sprite0 hit and the >8 range overflow flag. Nothing here is registered:
//   the caller supplies scanline / dot / ce and gets the answer in the same
//   dot. pat_addr_o exposes the 8 per-slot pattern addresses as 8 x 13 bits
//   for a parent that wants to prefetch them ahead of the line.
//
// pat_addr_o : the pattern addresses of the NEXT scanline, not of this one
//   pat_addr_o[g*13 +: 13] is the byte address the parent must have prefetched
//   for slot g of the scanline that follows the one on the `scanline` port. The
//   width, the 13-bit truncation and the slot ordering are unchanged; only the
//   scanline the address is derived from is one further on. It is
//   scanline + 1, wrapping 261 -> 0 at the end of the frame, so the pre-render
//   line 261 hands out line 0's addresses and the vblank lines hand out the
//   following line's addresses, which nothing renders anyway.
//   The parent issues its prefetch start at dot 257 and needs shadow_valid 35 ce
//   later, at dot 292 of that same line, which is after dots 0..255 have already
//   been displayed. A same-line address latched at dot 257 therefore cannot serve
//   the pixels of its own line; the pixels of line L need the fetch started at
//   dot 257 of line L-1, and an address that is already for line L is what makes
//   that work. Address and start dot are therefore split: the start dot stays
//   where the parent's bus arbitration assumes it, and only the address moves
//   forward. Feeding the next scanline in through `scanline`/`scanline_sel`
//   instead is not available here, because the same chain also selects
//   s_pat_addr, and s_pat_addr is what the EXTERNAL_CHR=0 path renders this dot
//   from. retiming `scanline_sel` to the next line would move the pattern row
//   of every internally rendered pixel, so the next-line chain is duplicated
//   (a second 64-entry range scan, a second 8-way nth_set walk, and a second
//   row/tile/fine derivation) instead of being shared.
//
// cur_slot_o : observation-only export of which slot this dot is positioned on.
//   4 bits wide, purely positional, and it never feeds back into any other
//   signal in this module, so it is safe to consume from a parent that drives
//   chr_sh from data derived from it (EXTERNAL_CHR=1). It is deliberately NOT
//   the pattern-dependent winner below, because that would close a combinational
//   loop chr_sh -> s_pat -> slot_opaque -> cur_slot_o -> chr_sh. The positional
//   rule is the first two terms of slot_opaque: the lowest g in 0..7 that is in
//   range for this scanline (g < range_count) and whose 8-pixel window covers
//   dot. Because slot_opaque adds a third term (s_pat != 0), the opaque source
//   slot is always >= cur_slot_o, and cur_slot_o == the opaque source whenever
//   no earlier slot covers the dot.
//     0..7   the slot this dot is positioned on, per the rule above
//     4'h8   no sprite covers this dot, or the index is not meaningful
//   4'h8 is also driven unconditionally whenever reset is high, whenever
//   scanline >= 240 (vblank and the pre-render line) and whenever dot >= 256,
//   because in all of those states pixel_active is low and sprite_pixel,
//   sprite_priority and sprite0_hit are already forced to zero without
//   consulting the pattern planes, so a parent may substitute a zero word for
//   the whole slot without changing any output of this unit. sprite_overflow
//   is not gated by dot or by reset, and cur_slot_o carries no overflow
//   information. cur_slot_o is also independent of mask: it reports the dot's
//   position, not whether the left-8 clip suppresses the pixel.
//
// chr_sh : both pattern planes of one sprite row, 16 bits wide
//   Only the EXTERNAL_CHR=1 generate branch reads this port. The EXTERNAL_CHR=0
//   branch never looks at it and indexes the flat 65536-bit chr vector itself,
//   so a parent must tie chr_sh off in that configuration (nes_ppu2c02 drives
//   16'h0000 there), and tb_nes_ppu_sprite.v legitimately leaves it
//   unconnected. Fixed bit assignment, agreed with the g_chr_external generate:
//       chr_sh[7:0]   plane 0, the low  plane
//       chr_sh[15:8]  plane 1, the high plane
//   16 bits is the minimum that can carry the two planes and there is no
//   slack in it: the internal branch reads two DIFFERENT CHR bytes for a given
//   row (byte s_pat_addr and byte s_pat_addr+8), and a sprite pattern value is
//   {plane1[bit], plane0[bit]} per pixel. An 8-bit port can express only one of
//   the two planes, so no wiring of it can reproduce the internal path's pixel
//   for any tile whose planes differ. Collapsing the pair into one byte (their
//   OR, or handing the same byte to both planes) does keep the silhouette exact,
//   but it forces every opaque pixel to palette index 3, which is a different
//   image rather than an approximation of the same one, so it can never be
//   pixel-compared against the internal path. Two planes of 8 pixels is 16 bits,
//   so 16 is also exactly the width the data needs and nothing more.
//
//   Correspondence with the internal flat-bus indexing, same layout expressed
//   with different arithmetic:
//       internal low  plane   chr[{s_pat_addr, 3'b000} +: 8]
//       internal high plane   chr[({s_pat_addr, 3'b000} + 13'd64) +: 8]
//   {s_pat_addr, 3'b000} is s_pat_addr times 8 BITS, so the part-select base is
//   bit s_pat_addr*8 and the low plane lands on BYTE s_pat_addr. +13'd64 is +64
//   BITS = +8 BYTES, so the high plane part-selects the matching position inside
//   the next 8 bytes of the same 16-byte tile. An external fetcher therefore
//   delivers, for the tile row at byte address s_pat_addr, the two bytes
//   CHR[s_pat_addr] and CHR[s_pat_addr+8] packed as
//   {CHR[s_pat_addr+8], CHR[s_pat_addr]}. The high plane goes in the UPPER byte
//   because s_pat = {s_plane_hi[s_xbit], s_plane_lo[s_xbit]}: bit 3 of a sprite
//   pattern is the high plane, on both paths.
//

// Sprite pattern byte addresses
//   s_pat_addr is {table, tile[7:0], 1'b0, fine[2:0]}, 13 bits, and equals
//   table*0x1000 + tile*16 + fine with nothing truncated: the largest value is
//   1*0x1000 + 255*16 + 7 = 8183 = 8192-9, so all 2 x 256 tiles of a table stay
//   inside one 4 KiB pattern table. Its bit layout, from bit 12 down:
//       s_pat_addr[12]    pattern table: ctrl[5] ? tile_byte[0] : ctrl[3]
//       s_pat_addr[11:4]  tile number within that table, 0..255
//       s_pat_addr[3]     always 0, the tile is 16-byte aligned
//       s_pat_addr[2:0]   fine Y, the row inside the tile, 0..7
//   A tile occupies 16 bytes because that is the 2C02 pattern-table layout, not
//   an arbitrary choice: 2 tables x 256 tiles x 16 B = 8 KiB, and within a tile
//   plane 0 occupies bytes 0..7 and plane 1 occupies bytes 8..15. So the byte
//   addresses of the two planes are:
//       low  plane = tile*16 + fine
//       high plane = tile*16 + fine + 8
//   The tile number therefore has to be 8 bits wide. With only 3 bits (or 3 bits
//   of usable range for 8x16) the address can only reach tiles 0..7, and every
//   tile 8 and above aliases onto tiles 0..7: a 3-bit add cannot carry, so the
//   8x16 upper half of tile 7 would also land back on tile 0.
//   Tile number source, and why:
//     8x8  (ctrl[5] == 0)   tile[7:0] of the OAM tile byte, the full 0..255
//     8x16 (ctrl[5] == 1)   {tile[7:1], row[3]}
//   For 8x16 the sprite covers two vertically adjacent tiles, a 32-byte block,
//   selected by the OAM tile number rounded DOWN to a multiple of 2, so
//   tile[0] only picks the pattern table and never enters the tile number.
//   {tile[7:1], row[3]} implements that: row 0..7 (top half) reads the even
//   tile, row 8..15 (bottom half) the next one, and fine = row[2:0] selects
//   within the 16-byte tile. Concatenation, not addition, so nothing can carry
//   or wrap out of the 8 bits.
//   This is the same layout the background path uses (nes_ppu2c02 reads
//   chr_ram[bg_pattern_addr] and chr_ram[bg_pattern_addr + 13'd8], and
//   nes_chr_fetch_unit computes
//   nxt_addr = base_q + {3'b0, idx_q, 4'd0} + (pl_q ? 14'd8 : 14'd0)), and the
//   same layout tb/ppu/tb_nes_ppu_sprite.v writes in fill_tile / fill_tile_row
//   (byte tile*16+row for the low plane, byte tile*16+row+8 for the high plane).
//   16 bytes per tile with plane 1 at byte offset +8 is the 2C02 pattern-table
//   layout (2 tables x 256 tiles x 16 B = 8 KiB, plane 0 = bytes 0..7,
//   plane 1 = bytes 8..15), so this is not a deviation from hardware.
//
//   The two plane constants are NOT interchangeable: chr[{s_pat_addr, 3'b000}
//   +: 8] is an indexed part-select, so its base is a BIT offset into the
//   65536-bit vector, not a byte address. {s_pat_addr, 3'b000} is s_pat_addr*8
//   bits, which is why the low plane lands on byte s_pat_addr. A +8 byte step
//   between the planes is therefore a +64 BIT step, which is why the high plane
//   adds 13'd64 and not 13'd8. Adding 13'd8 would read byte s_pat_addr+1, i.e.
//   the next row of the low plane, so both planes would come out of the plane-0
//   block and every sprite pattern would be wrong. Do not "fix" 13'd64 to
//   13'd8: tb_nes_ppu_sprite.v and tb_nes_ppu2c02.v both fail on that.
//

module nes_ppu_sprite #(
    parameter EXTERNAL_CHR = 1'b0,
    parameter PER_SLOT_CHR = 1'b0
)(
    input  wire           clk,
    input  wire           reset,
    input  wire           ce,
    input  wire [2047:0]  oam,
    input  wire [65535:0] chr,
    input  wire [15:0]    chr_sh,
    input  wire [127:0]   chr_slots,
    input  wire [7:0]     ctrl,
    input  wire [7:0]     mask,
    input  wire [8:0]     scanline,
    input  wire [8:0]     scanline_sel,
    input  wire [8:0]     dot,
    input  wire [3:0]     bg_pixel,
    output reg  [3:0]     sprite_pixel,
    output reg  [3:0]     sprite_priority,
    output reg            sprite0_hit,
    output reg            sprite_overflow,
    output wire [103:0]   pat_addr_o,
    output wire [103:0]   pat_addr_cur_o,
    output wire [3:0]     cur_slot_o
);

    function [5:0] nth_set;
        input [63:0] vec;
        input [2:0]  pick;
        integer      b;
        reg [6:0]    c;
        reg          taken;
        begin
            nth_set = 6'd0;
            c = 7'd0;
            taken = 1'b0;
            for (b = 0; b < 64; b = b + 1) begin
                if (!taken && vec[b]) begin
                    if (c[2:0] == pick) begin
                        nth_set = b[5:0];
                        taken = 1'b1;
                    end else begin
                        c = c + 7'd1;
                    end
                end
            end
        end
    endfunction

    wire [8:0] sprite_height = ctrl[5] ? 9'd16 : 9'd8;
    wire       frame_active = !reset && (scanline < 9'd240);
    wire       pixel_active = frame_active && (dot < 9'd256) && ((dot >= 9'd8) || mask[2]);

    wire [8:0] scanline_chain;
    assign scanline_chain = (^scanline_sel === 1'bx) ? scanline : scanline_sel;

    wire [8:0] scanline_next;
    assign scanline_next = (scanline == 9'd261) ? 9'd0 : (scanline + 9'd1);

    reg  [63:0] in_range;
    reg  [6:0]  range_count;
    reg  [8:0]  scan_addr;
    reg  [11:0] scan_bit;
    reg  [7:0]  scan_y;
    reg  [9:0]  scan_row;
    reg         scan_hit;
    integer     si;

    always @* begin
        in_range = 64'd0;
        range_count = 7'd0;
        for (si = 0; si < 64; si = si + 1) begin
            scan_addr = {1'b0, si[5:0], 2'b00};
            scan_bit = {3'b000, scan_addr} << 3;
            scan_y = (scan_addr > 9'd255) ? 8'h00 : oam[scan_bit +: 8];
            scan_row = {1'b0, scanline} - {2'b0, scan_y};
            scan_hit = (scan_row < {1'b0, sprite_height});
            in_range[si] = scan_hit;
            if (scan_hit)
                range_count = range_count + 7'd1;
        end
    end

    reg  [63:0] nl_in_range;
    reg  [8:0]  nl_scan_addr;
    reg  [11:0] nl_scan_bit;
    reg  [7:0]  nl_scan_y;
    reg  [9:0]  nl_scan_row;
    reg         nl_scan_hit;
    integer     ni;

    always @* begin
        nl_in_range = 64'd0;
        for (ni = 0; ni < 64; ni = ni + 1) begin
            nl_scan_addr = {1'b0, ni[5:0], 2'b00};
            nl_scan_bit = {3'b000, nl_scan_addr} << 3;
            nl_scan_y = (nl_scan_addr > 9'd255) ? 8'h00 : oam[nl_scan_bit +: 8];
            nl_scan_row = {1'b0, scanline_next} - {2'b0, nl_scan_y};
            nl_scan_hit = (nl_scan_row < {1'b0, sprite_height});
            nl_in_range[ni] = nl_scan_hit;
        end
    end

    wire [7:0] slot_index  [0:7];
    wire [7:0] slot_x      [0:7];
    wire [7:0] slot_attr   [0:7];
    wire [3:0] slot_pat    [0:7];
    wire       slot_opaque [0:7];

    genvar g;
    generate
        for (g = 0; g < 8; g = g + 1) begin : g_slot
            localparam integer SLOT_N = g;
            localparam [7:0]   SLOT_U8 = SLOT_N[7:0];
            localparam [2:0]   SLOT_PICK = SLOT_N[2:0];

            wire [5:0]  s_idx;
            wire [8:0]  s_addr;
            wire [11:0] s_bit0;
            wire [7:0]  s_y;
            wire [7:0]  s_tile_byte;
            wire [9:0]  s_row;
            wire [9:0]  s_fine;
            wire [7:0]  s_tile;
            wire        s_table;
            wire [12:0] s_pat_addr;
            wire [7:0]  s_plane_lo;
            wire [7:0]  s_plane_hi;
            wire [3:0]  s_pat;
            wire [9:0] s_xoff;
            wire [2:0] s_xbit;
            wire [5:0]  nl_idx;
            wire [8:0]  nl_addr;
            wire [11:0] nl_bit0;
            wire [7:0]  nl_y;
            wire [7:0]  nl_tile_byte;
            wire [7:0]  nl_attr;
            wire [9:0]  nl_row;
            wire [7:0]  nl_tile;
            wire        nl_table;
            wire [9:0]  nl_fine;
            wire [12:0] nl_pat_addr;

            assign s_idx = nth_set(in_range, SLOT_PICK);
            assign slot_index[g] = {2'b00, s_idx};
            assign s_addr = {1'b0, s_idx, 2'b00};
            assign s_bit0 = {3'b000, s_addr} << 3;
            assign s_y = (s_addr > 9'd255) ? 8'h00 : oam[s_bit0 +: 8];
            assign s_tile_byte = ((s_addr + 9'd1) > 9'd255) ? 8'h00 : oam[(s_bit0 + 12'd8) +: 8];
            assign slot_attr[g] = ((s_addr + 9'd2) > 9'd255) ? 8'h00 : oam[(s_bit0 + 12'd16) +: 8];
            assign slot_x[g] = ((s_addr + 9'd3) > 9'd255) ? 8'h00 : oam[(s_bit0 + 12'd24) +: 8];
            assign s_row = {1'b0, scanline_chain} - {2'b0, s_y};
            assign s_table = ctrl[5] ? s_tile_byte[0] : ctrl[3];
            assign s_tile = ctrl[5] ? {s_tile_byte[7:1], s_row[3]} : s_tile_byte[7:0];
            assign s_fine = slot_attr[g][7] ? ({1'b0, sprite_height} - 10'd1 - s_row) : s_row;
            assign s_pat_addr = {s_table, s_tile, 1'b0, s_fine[2:0]};
            assign nl_idx = nth_set(nl_in_range, SLOT_PICK);
            assign nl_addr = {1'b0, nl_idx, 2'b00};
            assign nl_bit0 = {3'b000, nl_addr} << 3;
            assign nl_y = (nl_addr > 9'd255) ? 8'h00 : oam[nl_bit0 +: 8];
            assign nl_tile_byte = ((nl_addr + 9'd1) > 9'd255) ? 8'h00 : oam[(nl_bit0 + 12'd8) +: 8];
            assign nl_attr = ((nl_addr + 9'd2) > 9'd255) ? 8'h00 : oam[(nl_bit0 + 12'd16) +: 8];
            assign nl_row = {1'b0, scanline_next} - {2'b0, nl_y};
            assign nl_table = ctrl[5] ? nl_tile_byte[0] : ctrl[3];
            assign nl_tile = ctrl[5] ? {nl_tile_byte[7:1], nl_row[3]} : nl_tile_byte[7:0];
            assign nl_fine = nl_attr[7] ? ({1'b0, sprite_height} - 10'd1 - nl_row) : nl_row;
            assign nl_pat_addr = {nl_table, nl_tile, 1'b0, nl_fine[2:0]};
            assign pat_addr_o[g*13 +: 13] = nl_pat_addr;
            assign pat_addr_cur_o[g*13 +: 13] = s_pat_addr;
            if (!EXTERNAL_CHR) begin : g_chr_internal
                if (PER_SLOT_CHR) begin : g_chr_per_slot
                    assign s_plane_lo = chr_slots[{SLOT_U8, 4'b0000} +: 8];
                    assign s_plane_hi = chr_slots[{SLOT_U8, 4'b1000} +: 8];
                end else begin : g_chr_flat
                    assign s_plane_lo = chr[{s_pat_addr, 3'b000} +: 8];
                    assign s_plane_hi = chr[({s_pat_addr, 3'b000} + 13'd64) +: 8];
                end
            end else begin : g_chr_external
                assign s_plane_lo = chr_sh[7:0];
                assign s_plane_hi = chr_sh[15:8];
            end
            assign s_xoff = {2'b00, dot[7:0]} - {2'b00, slot_x[g]};
            assign s_xbit = slot_attr[g][6] ? s_xoff[2:0] : (3'd7 - s_xoff[2:0]);
            assign s_pat = {s_plane_hi[s_xbit], s_plane_lo[s_xbit]};
            assign slot_pat[g] = s_pat;
            assign slot_opaque[g] = (SLOT_U8 < range_count) && (s_xoff[9:3] == 8'd0) && (s_pat != 2'b00);
        end
    endgenerate

    reg       found;
    integer   j;

    always @* begin
        sprite_pixel = 4'h0;
        sprite_priority = 4'h0;
        sprite0_hit = 1'b0;
        sprite_overflow = 1'b0;
        found = 1'b0;
        for (j = 0; j < 8; j = j + 1) begin
            if (!found && slot_opaque[j]) begin
                sprite_pixel = {slot_attr[j][1:0], slot_pat[j][1:0]};
                sprite_priority = {4{slot_attr[j][5]}};
                found = 1'b1;
            end
        end
        if (pixel_active) begin
            if (slot_opaque[0] && (bg_pixel != 4'h0))
                sprite0_hit = 1'b1;
        end else begin
            sprite_pixel = 4'h0;
            sprite_priority = 4'h0;
        end
        if (frame_active && (range_count > 7'd8))
            sprite_overflow = 1'b1;
    end

    reg  [3:0] cur_slot;
    reg  [9:0] cur_xoff;
    reg  [2:0] cur_pick;
    reg        cur_cover;
    integer    k;

    always @* begin
        cur_slot = 4'h8;
        for (k = 0; k < 8; k = k + 1) begin
            cur_pick = k[2:0];
            cur_xoff = {2'b00, dot[7:0]} - {2'b00, slot_x[cur_pick]};
            cur_cover = (cur_pick < {1'b0, range_count}) && (cur_xoff[9:3] == 8'd0);
            if (cur_cover && (cur_slot == 4'h8))
                cur_slot = {1'b0, cur_pick};
        end
        if (!(frame_active && (dot < 9'd256)))
            cur_slot = 4'h8;
    end

    assign cur_slot_o = cur_slot;

endmodule
