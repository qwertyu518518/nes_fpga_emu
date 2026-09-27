// nes_ppu2c02 : NTSC 341 x 262 dot PPU with an optional external CHR port.
//
// External CHR bus arbitration (EXTERNAL_CHR=1 only)
//   chr_req / chr_addr / chr_rdata form one external port, and g_chr_external now
//   has two masters for chr_req / chr_addr: the background tile fetcher
//   (nes_chr_fetch_unit, 1 tile = 2 bytes) and the sprite line prefetcher
//   (nes_sprite_chr_fetch, 8 slots x 2 planes = 16 bytes). Both units latch their
//   own chr_addr one ce ahead of the request beat, so chr_rdata is shared
//   unchanged: whoever won the arbitration is exactly who issued the beat.
//   chr_req and chr_addr are the outputs of a combinational priority mux (sprite
//   first, selected by sprite_fetch_busy). Nothing is registered between the two
//   units and the port, so the background request cadence, the bg_lo_q / bg_hi_q
//   latches and every background pixel are bit-identical to the single-fetcher
//   version.
//
// Why the two windows cannot collide. This is a measured property of the two
// trigger expressions, not a guarantee from the bus protocol:
//   * Background req_start is bg_fetch_due:
//       bg_fetch_mid       : (dot + fine_x)[2:0] == 7 and dot <= 246
//       bg_fetch_pre_first : dot == 324 and mask[1]
//       bg_fetch_pre_second: dot + fine_x == 340
//     The latest background trigger is therefore dot 246. nes_chr_fetch_unit
//     issues its two chr_req pulses at trigger+2 and trigger+4 and returns to
//     S_IDLE at trigger+7, so the last background request beat is at dot 250 and
//     the background master owns the bus from dot 253 onwards.
//   * The sprite prefetcher takes a one-ce start pulse at dot 257.
//     nes_sprite_chr_fetch needs 35 ce from start to shadow_valid (36 ce edges),
//     pulses chr_req at start+2 .. start+33 and drops busy at start+35, i.e.
//     dots 259..290 with busy high across dots 257..291.
//   * 253 < 257 and 291 < 324, so the sprite window [257,291] is disjoint from
//     both background windows ([.., 253] and [324, ..]); the 324 is
//     bg_fetch_pre_first = (dot == 9'd324) in g_chr_external, and the two
//     pre-render carries it starts are at dots 324+2..324+4 and
//     (340-fine_x)+2..(340-fine_x)+4, i.e. inside [326, ..]. No background
//     request beat is ever masked by the sprite, which is why the priority order
//     does not change any background behaviour today.
//
// What breaks if the non-overlap assumption is violated (a new background
// trigger inside dot 257..291, a different sprite start dot, a ce budget change
// in either unit, or a bus stall):
//   * With sprite priority the colliding background request loses its chr_req and
//     chr_addr beat. The unit keeps counting and bg_valid still rises 1 ce later,
//     so bg_lo_q / bg_hi_q latch the wrong bytes and the wrong tile is displayed
//     for that one tile window. Nothing back-pressures: there is no ready signal
//     on this port and bg_fetch_due is a pulse that is silently dropped.
//   * With background priority the colliding sprite request instead loses its
//     beat, the 16 bytes land in the wrong shadow slots, and the wrong sprite row
//     is displayed for the entire line.
//   Both failures are invisible except as wrong pixels, so any change to
//   bg_fetch_due, to the sprite start dot, or to either fetch unit's ce budget has
//   to re-derive the windows above before it can be trusted.
//
// Sprite shadow -> chr_sh (EXTERNAL_CHR=1)
//   nes_ppu_sprite's external generate splits one 16-bit chr_sh into the two
//   pattern planes (`assign s_plane_lo = chr_sh[7:0]; assign s_plane_hi =
//   chr_sh[15:8];`), so the PPU has to supply BOTH bytes of the row, not one
//   byte standing in for both. The slot index is taken from that unit's
//   cur_slot_o, which is the positional slot it already selected for this dot:
//   the lowest of its 0..7 in-range slots whose 8-pixel horizontal window covers
//   `dot`, or 4'h8 when nothing covers it. Recomputing that scan here would have
//   duplicated the 64-entry range scan and the 8 nth_set walks nes_ppu_sprite
//   already performs, which roughly doubled the external-CHR simulation cost
//   for a result that is bit-identical by construction: cur_slot_o is the same
//   (slot_index, x-window) rule, driven by the same sprite_oam_bus and the same
//   dot, and the 4'h8 sentinel only replaces the shadow bytes at dot >= 256,
//   vblank and reset, where nes_ppu_sprite has already forced sprite_pixel,
//   sprite_priority and sprite0_hit to zero without consulting chr_sh. For that
//   slot shadow[g*16 +: 8] is the low plane and shadow[g*16+8 +: 8] the high
//   plane, which are the same two bytes the internal path reaches as byte
//   s_pat_addr and byte s_pat_addr+8 of the tile. They are CONCATENATED here,
//   {sp_plane_hi, sp_plane_lo}, not combined: chr_sh[15:8] carries
//   CHR[s_pat_addr+8] and chr_sh[7:0] carries CHR[s_pat_addr], because
//   s_pat = {s_plane_hi[s_xbit], s_plane_lo[s_xbit]} makes bit 3 of a sprite
//   pattern the high plane on both paths. Presenting their OR (or the same byte
//   to both planes) would have kept the silhouette exact while forcing every
//   opaque pixel to palette index 3, which is a different image rather than an
//   approximation of the same one, and it could never be pixel-compared against
//   the internal path.
//   sp_shadow_valid gates the mux because nes_sprite_chr_fetch's shadow register
//   has no reset: before the first completed line it is X, and X on chr_sh would
//   make slot_opaque / sprite_pixel X inside nes_ppu_sprite and corrupt the pixel.
//
// Sprite prefetch timing: the start dot and the address line are separate axes
//   pat_addr_o is a NEXT-LINE address. nes_ppu_sprite hands out the pattern
//   addresses of scanline + 1 (wrapping 261 -> 0), and sp_start stays at dot 257
//   of the line whose hblank the fetch actually runs in. The two facts only
//   combine into the right schedule read together:
//     dot 257 of line L   sp_start pulses, the fetch unit latches pat_addr_o,
//                         which is line L+1's address set
//     dot 259..290        the 16 chr_req beats at line L+1's addresses
//     dot 292 of line L   shadow_valid rises holding line L+1's planes
//     dot 0..255 of L+1   the pixels of line L+1 consume that shadow
//   shadow_valid cannot rise before dot 292 of line L, and dots 0..255 of line L
//   are already displayed by then, so a line-L address latched at line L's own
//   dot 257 could never serve line L: it would always be one line late. The
//   retiming therefore lives in the address, not in the start dot, and sp_start
//   stays at (dot == 9'd257) on every scanline. Moving the start dot back to
//   line L-1's 257 would look equivalent and is not: it slides the whole
//   [257,291] window measured above onto line L-1's hblank without changing the
//   fetch latency, and it would no longer be the window derived from dot 257 that
//   the non-collision argument rests on. The cost of the duplicated next-line
//   derivation in nes_ppu_sprite is one extra 64-entry OAM range scan and 8 more
//   nth_set walks, both of which re-evaluate only when the scanline or OAM
//   changes, so it is a per-line rather than a per-dot cost.
//
// CHR address convention (EXTERNAL_CHR=1): the three notations now agree
//   All three fetchers name the same CHR byte with the same number, expressed
//   three ways:
//     nes_ppu_sprite, internal : chr[{s_pat_addr, 3'b000} +: 8] and
//                               chr[({s_pat_addr, 3'b000} + 13'd64) +: 8]. These
//                               are BIT part-selects into a 65536-bit vector, so
//                               their base is bit s_pat_addr*8, which is byte
//                               s_pat_addr, and 13'd64 bits is +8 bytes.
//     nes_ppu_sprite, external : slot g low plane at shadow[g*16 +: 8], high
//                               plane at shadow[g*16+8 +: 8]
//     nes_sprite_chr_fetch     : chr_addr = pat_addr + plane*8, computed in 14
//                               bits and masked with 14'h3FFF
//   There is no *8 scaling on the sprite side any more. pat_addr is already
//   tile*16 + fine after the 13-bit truncation, the two planes are 8 bytes
//   apart, and chr_addr[13] is driven by pat_addr[12] so a pattern in
//   0x1FF8..0x1FFF reaches the upper 8 KiB of a 16 KiB CHR; an 8 KiB CHR bus
//   mirrors that range back to 0x0000 rather than wrapping. nes_chr_fetch_unit
//   already drove the background pattern address unscaled the same way, so all
//   three agree. tb_nes_ppu2c02_ext_chr.v checks every sprite request address
//   and every shadow byte against its CHR model, and any reintroduction of a
//   *8 here surfaces there as an 8x-too-high address and a fatal, so the old
//   "sprite prefetcher is 8x above" hazard no longer exists.
//
// chr_addr is a LOCAL CHR byte address, and the mapper translates it
//   chr_addr is 14 bits and names a byte inside ONE 16 KiB CHR window. It is
//   NOT a CHR ROM/RAM address: the mapper is what turns it into the final one.
//   Every mapper's chr_bank_offset is already that final address, produced as
//   `(<bank> << K) | <local bits of ppu_addr>` -- nes_mapper_cnrom.v:41 is
//   `(chr_bank_ext << 13) | ppu_addr[12:0]`, nes_mapper_mmc1.v:65 is
//   `(chr_bank_ext << 12) | ppu_addr[11:0]`, nes_mapper_mmc3.v:135 is
//   `(chr_window_ext << 10) | ppu_addr[9:0]` -- and a memory owner indexes CHR
//   with it directly (`chr_rom[chr_bank_offset[15:0]]` in the mapper TBs). So
//   ppu_addr must be driven with the LOCAL address this port presents, and the
//   PPU adds no bank offset of any kind. A `chr_addr_final = chr_bank_offset +
//   ppu_local_addr` style adder on this side would be wrong twice over.
//   The mapper output is a COMBINATIONAL function of ppu_addr. Wiring
//   chr_addr -> mapper.ppu_addr -> chr_bank_offset -> back into chr_addr would
//   therefore be a zero-delay combinational loop through this PPU, which is the
//   whole reason the adder must not exist here. nes_system_v5.v currently hides
//   the loop behind `wire [13:0] mapper_ppu_addr = 14'h0000;`, so the loop is
//   latent rather than elaborated, but it exists the moment ppu_addr is wired
//   for real. The translation model is the hardware one: a cartridge mapper
//   decodes the PPU address bus, it does not post-add to it.
//
// chr_addr[13] is the pattern-table select, and no mapper looks at it
//   Background: chr_addr[13] is PPUCTRL[4] (bg_tile_base = {control_reg[4],
//   bg_name_target, 4'b0000} + fine_y). Sprite: chr_addr[13] is PPUCTRL[5] via
//   s_table, i.e. the 8x16 tile-pair bit. Every mapper drops it: the cnrom
//   expression keeps only ppu_addr[12:0], mmc1 only ppu_addr[11:0], mmc3 only
//   ppu_addr[9:0], nrom/uxrom only ppu_addr[12:0]. That is correct, because the
//   pattern table select is a PPU-internal decode of the same 8 KiB, and the
//   mapper has no business seeing it. A consequence for testbenches and for a
//   future CHR memory owner is that a CHR image is mirrored per 8 KiB: the
//   16-bit window chr_addr addresses wraps at bit 13, so an 8 KiB CHR RAM must
//   index on chr_addr[12:0]. tb_nes_ppu2c02_ext_chr.v already does exactly that
//   (`chr_rdata_q <= chr_mem[addr_b[12:0]]`), which is what g_chr_internal's
//   `chr_ram[address[12:0]]` does too, and it is why bit 13 is allowed to be 1
//   on the sprite side without the A/B comparison diverging.
//
// Known asymmetry between the two fetchers -- recorded, deliberately NOT fixed
//   The background tile index lands in chr_addr[11:4] (256 tiles at 16 B needs
//   8 index bits), while the sprite tile index lands in chr_addr[6:4], because
//   nes_ppu_sprite forms s_pat_addr as {s_table, 5'b00000, s_tile, 1'b0,
//   s_fine[2:0]}, i.e. a 13-bit value whose low 8 bits are the 128-tile
//   half-table the 8x8 sprite table actually has. So the two fetchers number
//   tiles differently and there is no single CHR layout on which both agree.
//   Do NOT unify them: tb_nes_ppu2c02_ext_chr.v's expected addresses are
//   recomputed on the background convention with bit 13 clear, so unifying the
//   sprite side onto the background's 8 index bits would move every sprite
//   request address and fail A3/S2. The asymmetry is a property of the sprite
//   pattern addressing on the 2C02 and is left as is.
//
// chr_addr is stale outside a request beat; the memory side must register
//   Both units REGISTER their chr_addr: nes_chr_fetch_unit latches it one ce
//   ahead of the beat and nes_sprite_chr_fetch does the same, so between beats
//   the port keeps presenting the previous address rather than a defined idle
//   value. chr_req is the only qualification of the address. A memory owner must
//   therefore register the read and gate it with chr_req, exactly as
//   tb_nes_ppu2c02_ext_chr.v does with its one-ce-late `chr_rdata_q`; a
//   combinational read of chr_addr would return the wrong byte for every beat
//   that follows an idle gap.

`timescale 1ns/1ps

module nes_ppu2c02 #(
    parameter MIRROR_VERTICAL = 1'b0,
    parameter EXTERNAL_CHR = 1'b0
)(
    input wire clk,
    input wire reset,
    input wire ce,
    input wire reg_cs,
    input wire reg_we,
    input wire [2:0] reg_addr,
    input wire [7:0] reg_din,
    output reg [7:0] reg_dout,
    output reg pixel_valid,
    output reg [7:0] pixel_x,
    output reg [7:0] pixel_y,
    output reg [3:0] pixel_index,
    output reg frame_done,
    output reg vblank,
    output reg nmi_o,
    output reg [8:0] dot,
    output reg [8:0] scanline,
    output wire [14:0] dbg_v,
    output wire [14:0] dbg_t,
    output wire [2:0] dbg_x,
    output wire dbg_w,
    output wire dbg_sprite0_hit,
    output wire dbg_sprite_overflow,
    output wire chr_req,
    output wire [13:0] chr_addr,
    output wire chr_we,
    output wire [7:0] chr_wdata,
    input wire [7:0] chr_rdata
);

reg [7:0] control_reg;
reg [7:0] mask_reg;
reg [7:0] oam_addr_reg;
reg [7:0] read_buffer_reg;
reg [14:0] v_addr;
reg [14:0] temp_addr;
reg [2:0] fine_x;
reg write_toggle;
reg sprite0_hit_reg;
reg sprite_overflow_reg;

reg [7:0] nametable_ram [0:2047];
reg [7:0] chr_ram [0:8191];
reg [7:0] oam_ram [0:255];
reg [7:0] palette_ram [0:31];

wire [8:0] bg_x_total;
wire [8:0] bg_y_total;
wire [5:0] bg_coarse_x_sum;
wire [6:0] bg_coarse_y_sum;
wire [6:0] bg_vertical_sections;
wire [4:0] bg_coarse_x;
wire [4:0] bg_coarse_y;
wire [1:0] bg_nametable;
wire [11:0] bg_nt_offset;
wire [11:0] bg_attr_offset;
wire [7:0] bg_name;
wire [7:0] bg_attribute_byte;
wire [2:0] bg_pattern_bit;
wire [12:0] bg_pattern_addr;
wire [7:0] bg_pattern_low;
wire [7:0] bg_pattern_high;
wire [1:0] bg_pattern_index;
wire       bg_pa_enable;
reg [1:0] bg_attribute;
reg [4:0] bg_palette_index;
reg [7:0] bg_palette_value;

function [11:0] mirror_nametable;
    input [11:0] address;
    reg [11:0] mapped;
    begin
        mapped = {1'b0, address[9:0]};
        if (MIRROR_VERTICAL)
            mapped[10] = address[10];
        else
            mapped[10] = address[11];
        mirror_nametable = mapped;
    end
endfunction

function [4:0] palette_index_map;
    input [4:0] address;
    begin
        case (address)
            5'h10: palette_index_map = 5'h00;
            5'h14: palette_index_map = 5'h04;
            5'h18: palette_index_map = 5'h08;
            5'h1C: palette_index_map = 5'h0C;
            default: palette_index_map = address;
        endcase
    end
endfunction

function [13:0] palette_underlay_address;
    input [14:0] address;
    reg [14:0] masked;
    begin
        masked = address & 15'h3FFF;
        if (masked < 15'h3F00) begin
            palette_underlay_address = masked[13:0];
        end else begin
            masked = masked - 15'h1000;
            palette_underlay_address = masked[13:0];
        end
    end
endfunction

function [14:0] increment_v;
    input [14:0] address;
    begin
        if (control_reg[2])
            increment_v = address + 15'd32;
        else
            increment_v = address + 15'd1;
    end
endfunction

function [14:0] increment_x;
    input [14:0] address;
    reg [14:0] result;
    begin
        result = address;
        if (address[4:0] == 5'd31) begin
            result[4:0] = 5'd0;
            result[10] = !address[10];
        end else begin
            result[4:0] = address[4:0] + 5'd1;
        end
        increment_x = result;
    end
endfunction

function [14:0] increment_y;
    input [14:0] address;
    reg [14:0] result;
    begin
        result = address;
        if (address[14:12] != 3'd7) begin
            result[14:12] = address[14:12] + 3'd1;
        end else begin
            result[14:12] = 3'd0;
            if (address[9:5] == 5'd29) begin
                result[9:5] = 5'd0;
                result[11] = !address[11];
            end else if (address[9:5] == 5'd31) begin
                result[9:5] = 5'd0;
            end else begin
                result[9:5] = address[9:5] + 5'd1;
            end
        end
        increment_y = result;
    end
endfunction

assign dbg_v = v_addr;
assign dbg_t = temp_addr;
assign dbg_x = fine_x;
assign dbg_w = write_toggle;
assign dbg_sprite0_hit = sprite0_hit_reg;
assign dbg_sprite_overflow = sprite_overflow_reg;

assign bg_x_total = {1'b0, dot} + {6'b0, fine_x} + ({4'b0, temp_addr[4:0]} << 3);
assign bg_y_total = {1'b0, scanline} + ({4'b0, temp_addr[9:5]} << 3) + {6'b0, temp_addr[14:12]};
assign bg_coarse_x_sum = {1'b0, temp_addr[4:0]} + {1'b0, bg_x_total[8:3]};
assign bg_coarse_y_sum = {2'b0, temp_addr[9:5]} + {1'b0, bg_y_total[8:3]};
assign bg_vertical_sections = bg_coarse_y_sum / 7'd30;
assign bg_coarse_x = bg_coarse_x_sum[4:0];
assign bg_coarse_y = bg_coarse_y_sum % 7'd30;
assign bg_nametable[0] = temp_addr[10] ^ bg_coarse_x_sum[5];
assign bg_nametable[1] = temp_addr[11] ^ bg_vertical_sections[0];
assign bg_nt_offset = {bg_nametable, bg_coarse_y, bg_coarse_x};
assign bg_attr_offset = {bg_nametable, 4'b1111, bg_coarse_y[4:2], bg_coarse_x[4:2]};
assign bg_name = nametable_ram[mirror_nametable(bg_nt_offset)];
assign bg_attribute_byte = nametable_ram[mirror_nametable(bg_attr_offset)];
assign bg_pattern_bit = 3'd7 - bg_x_total[2:0];
assign bg_pattern_addr = {control_reg[4], bg_name, 4'b0000} + {10'b0000000000, bg_y_total[2:0]};
assign bg_pattern_index = {bg_pattern_high[bg_pattern_bit], bg_pattern_low[bg_pattern_bit]};

always @* begin
    case ({bg_coarse_y[1], bg_coarse_x[1]})
        2'b00: bg_attribute = bg_attribute_byte[1:0];
        2'b01: bg_attribute = bg_attribute_byte[3:2];
        2'b10: bg_attribute = bg_attribute_byte[5:4];
        2'b11: bg_attribute = bg_attribute_byte[7:6];
        default: bg_attribute = 2'b0;
    endcase
    if (bg_pattern_index == 2'b00)
        bg_palette_index = 5'd0;
    else
        bg_palette_index = {bg_attribute, bg_pattern_index};
    bg_palette_value = palette_ram[palette_index_map(bg_palette_index)];
end

wire [2047:0] sprite_oam_bus;
wire [65535:0] sprite_chr_bus;
wire [103:0] sprite_pat_addr_bus;
wire [3:0] sprite_pixel;
wire [3:0] sprite_priority;
wire       sprite0_hit_raw;
wire       sprite_overflow_raw;
wire       bg_shown;
wire       bg_opaque;
wire [3:0] sprite_bg_input;
wire       sprite_opaque;
wire [7:0] sprite_palette_value;
reg  [7:0] mixed_pixel_value;

genvar flat_i;
generate
    for (flat_i = 0; flat_i < 64; flat_i = flat_i + 1) begin : g_oam_flatten
        assign sprite_oam_bus[flat_i * 32 + 0 +: 8] = oam_ram[flat_i * 4 + 0];
        assign sprite_oam_bus[flat_i * 32 + 8 +: 8] = oam_ram[flat_i * 4 + 1];
        assign sprite_oam_bus[flat_i * 32 + 16 +: 8] = oam_ram[flat_i * 4 + 2];
        assign sprite_oam_bus[flat_i * 32 + 24 +: 8] = oam_ram[flat_i * 4 + 3];
    end
endgenerate

generate
    if (!EXTERNAL_CHR) begin : g_chr_internal
        function [7:0] ppu_space_read;
            input [13:0] address;
            begin
                if (address < 14'h2000)
                    ppu_space_read = chr_ram[address[12:0]];
                else if (address < 14'h3F00)
                    ppu_space_read = nametable_ram[mirror_nametable(address[11:0])];
                else
                    ppu_space_read = palette_ram[palette_index_map(address[4:0])];
            end
        endfunction

        assign bg_pattern_low = chr_ram[bg_pattern_addr];
        assign bg_pattern_high = chr_ram[bg_pattern_addr + 13'd8];

        for (flat_i = 0; flat_i < 8192; flat_i = flat_i + 1) begin : g_chr_flatten
            assign sprite_chr_bus[flat_i * 8 +: 8] = chr_ram[flat_i];
        end

        nes_ppu_sprite #(
            .EXTERNAL_CHR(1'b0)
        ) u_sprite (
            .clk(clk),
            .reset(reset),
            .ce(ce),
            .oam(sprite_oam_bus),
            .chr(sprite_chr_bus),
            .chr_sh(16'h0000),
            .ctrl(control_reg),
            .mask(mask_reg),
            .scanline(scanline),
            .scanline_sel(scanline),
            .dot(dot),
            .bg_pixel(sprite_bg_input),
            .sprite_pixel(sprite_pixel),
            .sprite_priority(sprite_priority),
            .sprite0_hit(sprite0_hit_raw),
            .sprite_overflow(sprite_overflow_raw),
            .pat_addr_o(sprite_pat_addr_bus)
        );

        always @(posedge clk or posedge reset) begin
            if (!reset) begin
                if (reg_cs && reg_we && (reg_addr == 3'd7) && (v_addr < 15'h2000))
                    chr_ram[v_addr[12:0]] <= reg_din;
            end
        end

        always @(posedge clk or posedge reset) begin
            if (!reset) begin
                if (reg_cs && !reg_we && (reg_addr == 3'd7)) begin
                    if (v_addr < 15'h3F00)
                        read_buffer_reg <= ppu_space_read(v_addr[13:0]);
                    else
                        read_buffer_reg <= ppu_space_read(palette_underlay_address(v_addr));
                    v_addr <= increment_v(v_addr);
                end
            end
        end
    end else begin : g_chr_external
        function [7:0] ppu_space_read;
            input [13:0] address;
            begin
                if (address < 14'h2000)
                    ppu_space_read = 8'h00;
                else if (address < 14'h3F00)
                    ppu_space_read = nametable_ram[mirror_nametable(address[11:0])];
                else
                    ppu_space_read = palette_ram[palette_index_map(address[4:0])];
            end
        endfunction

        wire [8:0]  bg_dot_fine;
        wire        bg_fetch_mid;
        wire        bg_fetch_pre_first;
        wire        bg_fetch_pre_second;
        wire        bg_fetch_due;
        wire [8:0]  bg_look_dot;
        wire [8:0]  bg_target_dot;
        wire        bg_next_line;
        wire [8:0]  bg_xtot_target;
        wire [5:0]  bg_cxsum_target;
        wire [1:0]  bg_nametable_target;
        wire [11:0] bg_nt_offset_target;
        wire [7:0]  bg_name_target;
        wire [2:0]  bg_fine_y_target;
        wire [4:0]  bg_coarse_y_target;
        wire [12:0] bg_tile_base;
        wire [8:0]  bg_scanline_nl;
        wire [8:0]  bg_y_total_nl;
        wire [6:0]  bg_coarse_y_sum_nl;
        wire [6:0]  bg_vertical_sections_nl;
        wire [4:0]  bg_coarse_y_nl;
        wire        bg_nametable1_nl;
        wire [2:0]  bg_fine_y_nl;
        wire [7:0]  chr_fetch_bg_lo;
        wire [7:0]  chr_fetch_bg_hi;
        wire        chr_fetch_bg_valid;
        wire        chr_fetch_busy;
        reg  [7:0]  bg_lo_q;
        reg  [7:0]  bg_hi_q;
        reg         bg_ready;

        assign bg_dot_fine = dot + {6'b0, fine_x};
        assign bg_fetch_mid = (bg_dot_fine[2:0] == 3'd7) && (dot <= 9'd246);
        assign bg_fetch_pre_first = (dot == 9'd324) && mask_reg[1];
        assign bg_fetch_pre_second = (bg_dot_fine == 9'd340);
        assign bg_fetch_due = bg_fetch_mid || bg_fetch_pre_first || bg_fetch_pre_second;

        assign bg_look_dot = bg_fetch_pre_first ? (dot + 9'd17) : (dot + 9'd9);
        assign bg_next_line = (bg_look_dot >= 9'd341);
        assign bg_target_dot = bg_next_line ? (bg_look_dot - 9'd341) : bg_look_dot;
        assign bg_xtot_target = bg_target_dot + {6'b0, fine_x} + ({4'b0, temp_addr[4:0]} << 3);
        assign bg_cxsum_target = {1'b0, temp_addr[4:0]} + {1'b0, bg_xtot_target[8:3]};
        assign bg_scanline_nl = (scanline == 9'd261) ? 9'd0 : (scanline + 9'd1);
        assign bg_y_total_nl = {1'b0, bg_scanline_nl}
                             + ({4'b0, temp_addr[9:5]} << 3) + {6'b0, temp_addr[14:12]};
        assign bg_coarse_y_sum_nl = {2'b0, temp_addr[9:5]} + {1'b0, bg_y_total_nl[8:3]};
        assign bg_vertical_sections_nl = bg_coarse_y_sum_nl / 7'd30;
        assign bg_coarse_y_nl = bg_coarse_y_sum_nl % 7'd30;
        assign bg_nametable1_nl = temp_addr[11] ^ bg_vertical_sections_nl[0];
        assign bg_fine_y_nl = bg_y_total_nl[2:0];
        assign bg_coarse_y_target = bg_next_line ? bg_coarse_y_nl : bg_coarse_y;
        assign bg_fine_y_target = bg_next_line ? bg_fine_y_nl : bg_y_total[2:0];
        assign bg_nametable_target[1] = bg_next_line ? bg_nametable1_nl
                                                    : (temp_addr[11] ^ bg_vertical_sections[0]);
        assign bg_nametable_target[0] = temp_addr[10] ^ bg_cxsum_target[5];
        assign bg_nt_offset_target = {bg_nametable_target, bg_coarse_y_target, bg_cxsum_target[4:0]};
        assign bg_name_target = nametable_ram[mirror_nametable(bg_nt_offset_target)];
        assign bg_tile_base = {control_reg[4], bg_name_target, 4'b0000}
                            + {10'b0000000000, bg_fine_y_target};

        assign bg_pattern_low = (bg_ready && bg_pa_enable) ? bg_lo_q : 8'h00;
        assign bg_pattern_high = (bg_ready && bg_pa_enable) ? bg_hi_q : 8'h00;

        wire        bg_chr_req;
        wire [13:0] bg_chr_addr_raw;
        wire        sp_chr_req;
        wire [13:0] sp_chr_addr_raw;
        wire [127:0] sp_shadow;
        wire        sp_shadow_valid;
        wire        sp_busy;
        wire        sp_start;
        wire        sp_bus_sel;
        wire [3:0]  sp_slot;
        wire [6:0]  sp_base_lo;
        wire [6:0]  sp_base_hi;
        wire [7:0]  sp_plane_lo;
        wire [7:0]  sp_plane_hi;
        wire [15:0] sp_chr_sh;

        assign sp_start = (dot == 9'd257);
        assign sp_bus_sel = sp_busy;
        assign sp_base_lo = {sp_slot[2:0], 4'b0000};
        assign sp_base_hi = {sp_slot[2:0], 4'b1000};
        assign sp_plane_lo = (sp_slot == 4'h8) ? 8'h00 : sp_shadow[sp_base_lo +: 8];
        assign sp_plane_hi = (sp_slot == 4'h8) ? 8'h00 : sp_shadow[sp_base_hi +: 8];
        assign sp_chr_sh = sp_shadow_valid ? {sp_plane_hi, sp_plane_lo} : 16'h0000;

        nes_sprite_chr_fetch u_sprite_chr_fetch (
            .clk(clk),
            .ce(ce),
            .reset(reset),
            .start(sp_start),
            .pat_addr(sprite_pat_addr_bus),
            .chr_req(sp_chr_req),
            .chr_addr(sp_chr_addr_raw),
            .chr_rdata(chr_rdata),
            .shadow(sp_shadow),
            .shadow_valid(sp_shadow_valid),
            .busy(sp_busy)
        );

        nes_ppu_sprite #(
            .EXTERNAL_CHR(1'b1)
        ) u_sprite (
            .clk(clk),
            .reset(reset),
            .ce(ce),
            .oam(sprite_oam_bus),
            .chr(65536'd0),
            .chr_sh(sp_chr_sh),
            .ctrl(control_reg),
            .mask(mask_reg),
            .scanline(scanline),
            .scanline_sel(scanline),
            .dot(dot),
            .bg_pixel(sprite_bg_input),
            .sprite_pixel(sprite_pixel),
            .sprite_priority(sprite_priority),
            .sprite0_hit(sprite0_hit_raw),
            .sprite_overflow(sprite_overflow_raw),
            .pat_addr_o(sprite_pat_addr_bus),
            .cur_slot_o(sp_slot)
        );

        nes_chr_fetch_unit u_chr_fetch (
            .clk(clk),
            .ce(ce),
            .reset(reset),
            .req_start(bg_fetch_due),
            .tile_base(bg_tile_base),
            .tile_count(6'd1),
            .chr_req(bg_chr_req),
            .chr_addr(bg_chr_addr_raw),
            .chr_rdata(chr_rdata),
            .bg_lo(chr_fetch_bg_lo),
            .bg_hi(chr_fetch_bg_hi),
            .bg_valid(chr_fetch_bg_valid),
            .busy(chr_fetch_busy)
        );

        assign chr_req = sp_bus_sel ? sp_chr_req : bg_chr_req;
        assign chr_addr = sp_bus_sel ? sp_chr_addr_raw : bg_chr_addr_raw;

        assign chr_we = 1'b0;
        assign chr_wdata = 8'h00;

        always @(posedge clk) begin
            if (reset) begin
                bg_lo_q  <= 8'h00;
                bg_hi_q  <= 8'h00;
                bg_ready <= 1'b0;
            end else if (ce) begin
                if (chr_fetch_bg_valid) begin
                    bg_lo_q  <= chr_fetch_bg_lo;
                    bg_hi_q  <= chr_fetch_bg_hi;
                    bg_ready <= 1'b1;
                end
            end
        end

        always @(posedge clk or posedge reset) begin
            if (!reset) begin
                if (reg_cs && !reg_we && (reg_addr == 3'd7)) begin
                    if (v_addr < 15'h3F00)
                        read_buffer_reg <= ppu_space_read(v_addr[13:0]);
                    else
                        read_buffer_reg <= ppu_space_read(palette_underlay_address(v_addr));
                    v_addr <= increment_v(v_addr);
                end
            end
        end
    end
endgenerate

assign bg_shown = mask_reg[3] && ((dot >= 9'd8) || mask_reg[1]);
assign bg_pa_enable = !reset && mask_reg[3] && (scanline < 9'd240) && (dot < 9'd256)
                      && ((dot >= 9'd8) || mask_reg[1]);
assign bg_opaque = bg_shown && (bg_pattern_index != 2'b00);
assign sprite_bg_input = bg_opaque ? 4'hF : 4'h0;
assign sprite_opaque = mask_reg[4] && (sprite_pixel[1:0] != 2'b00);
assign sprite_palette_value = palette_ram[palette_index_map(5'h10 | {1'b0, sprite_pixel})];

always @* begin
    if (!bg_shown) begin
        if (sprite_opaque)
            mixed_pixel_value = sprite_palette_value;
        else
            mixed_pixel_value = 8'h00;
    end else if (bg_opaque) begin
        if (sprite_opaque && !sprite_priority[3])
            mixed_pixel_value = sprite_palette_value;
        else
            mixed_pixel_value = bg_palette_value;
    end else begin
        if (sprite_opaque)
            mixed_pixel_value = sprite_palette_value;
        else
            mixed_pixel_value = bg_palette_value;
    end
end

always @* begin
    pixel_valid = !reset && (scanline < 9'd240) && (dot < 9'd256);
    pixel_x = 8'h00;
    pixel_y = 8'h00;
    pixel_index = 4'h0;
    if (pixel_valid) begin
        pixel_x = dot[7:0];
        pixel_y = scanline[7:0];
        pixel_index = mixed_pixel_value[3:0];
    end
    if (mask_reg[0])
        pixel_index = pixel_index & 4'h3;
    if (reset)
        pixel_index = 4'h0;
end

always @* begin
    reg_dout = 8'h00;
    if (reg_cs && !reset) begin
        case (reg_addr)
            3'd2: reg_dout = {vblank, sprite_overflow_reg, sprite0_hit_reg, 1'b0, 4'b0000};
            3'd3: reg_dout = oam_addr_reg;
            3'd4: reg_dout = oam_ram[oam_addr_reg];
            3'd7: begin
                if (v_addr < 15'h3F00)
                    reg_dout = read_buffer_reg;
                else
                    reg_dout = palette_ram[palette_index_map(v_addr[4:0])];
            end
            default: reg_dout = 8'h00;
        endcase
    end
end

always @(posedge clk or posedge reset) begin
    if (reset) begin
        control_reg <= 8'h00;
        mask_reg <= 8'h00;
        oam_addr_reg <= 8'h00;
        read_buffer_reg <= 8'h00;
        v_addr <= 15'h0000;
        temp_addr <= 15'h0000;
        fine_x <= 3'd0;
        write_toggle <= 1'b0;
        sprite0_hit_reg <= 1'b0;
        sprite_overflow_reg <= 1'b0;
        frame_done <= 1'b0;
        vblank <= 1'b0;
        nmi_o <= 1'b0;
        dot <= 9'd0;
        scanline <= 9'd0;
    end else begin
        if (reg_cs && reg_we) begin
            case (reg_addr)
                3'd0: begin
                    control_reg <= reg_din;
                    temp_addr[11:10] <= reg_din[1:0];
                end
                3'd1: mask_reg <= reg_din;
                3'd2: begin
                end
                3'd3: oam_addr_reg <= reg_din;
                3'd4: begin
                    oam_ram[oam_addr_reg] <= reg_din;
                    oam_addr_reg <= oam_addr_reg + 8'd1;
                end
                3'd5: begin
                    if (!write_toggle) begin
                        temp_addr[4:0] <= reg_din[7:3];
                        fine_x <= reg_din[2:0];
                    end else begin
                        temp_addr[14:12] <= reg_din[2:0];
                        temp_addr[9:5] <= reg_din[7:3];
                    end
                    write_toggle <= !write_toggle;
                end
                3'd6: begin
                    if (!write_toggle) begin
                        temp_addr[14:8] <= {1'b0, reg_din[6:0]};
                    end else begin
                        temp_addr[7:0] <= reg_din;
                        v_addr <= {temp_addr[14:8], reg_din};
                    end
                    write_toggle <= !write_toggle;
                end
                3'd7: begin
                    if (v_addr < 15'h2000) begin
                    end else if (v_addr < 15'h3F00)
                        nametable_ram[mirror_nametable(v_addr[11:0])] <= reg_din;
                    else
                        palette_ram[palette_index_map(v_addr[4:0])] <= reg_din;
                    v_addr <= increment_v(v_addr);
                end
                default: begin
                end
            endcase
        end

        if (reg_cs && !reg_we && (reg_addr == 3'd3)) begin
        end else if (reg_cs && !reg_we && (reg_addr == 3'd4)) begin
            oam_addr_reg <= oam_addr_reg + 8'd1;
        end

        if (ce) begin
            frame_done <= 1'b0;

            if (mask_reg[4] && sprite0_hit_raw)
                sprite0_hit_reg <= 1'b1;
            if (mask_reg[4] && sprite_overflow_raw)
                sprite_overflow_reg <= 1'b1;

            if ((scanline == 9'd241) && (dot == 9'd0)) begin
                vblank <= 1'b1;
                if (control_reg[7])
                    nmi_o <= 1'b1;
            end

            if ((scanline == 9'd261) && (dot == 9'd0)) begin
                vblank <= 1'b0;
                nmi_o <= 1'b0;
            end

            if (mask_reg[3] && !reg_cs && ((scanline < 9'd240) || (scanline == 9'd261))) begin
                if (dot == 9'd256)
                    v_addr <= increment_y(increment_x(v_addr));
                else if ((dot >= 9'd8) && (dot <= 9'd248) && (dot[2:0] == 3'd0))
                    v_addr <= increment_x(v_addr);

                if (dot == 9'd257) begin
                    v_addr[4:0] <= temp_addr[4:0];
                    v_addr[10] <= temp_addr[10];
                end

                if ((scanline == 9'd261) && (dot >= 9'd280) && (dot <= 9'd304)) begin
                    v_addr[14:12] <= temp_addr[14:12];
                    v_addr[9:5] <= temp_addr[9:5];
                    v_addr[11] <= temp_addr[11];
                end
            end

            if (dot == 9'd340) begin
                dot <= 9'd0;
                if (scanline == 9'd261) begin
                    scanline <= 9'd0;
                    frame_done <= 1'b1;
                end else begin
                    scanline <= scanline + 9'd1;
                end
            end else begin
                dot <= dot + 9'd1;
            end
        end

        if (reg_cs && !reg_we && (reg_addr == 3'd2)) begin
            vblank <= 1'b0;
            nmi_o <= 1'b0;
            write_toggle <= 1'b0;
            sprite0_hit_reg <= 1'b0;
            sprite_overflow_reg <= 1'b0;
        end
    end
end

endmodule
