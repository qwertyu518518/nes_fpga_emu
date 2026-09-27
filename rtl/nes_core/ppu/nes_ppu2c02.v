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
//     both background windows ([.., 253] and [326, ..]). No background request
//     beat is ever masked by the sprite, which is why the priority order does
//     not change any background behaviour today.
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
//   nes_ppu_sprite's external generate hands every slot the same 8-bit chr_sh for
//   both planes (`assign s_plane_lo = chr_sh; assign s_plane_hi = chr_sh;`), so
//   the PPU has to choose the byte. The slot index is taken from that unit's
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
//   plane. One byte has to serve both planes, so their OR is presented: that
//   makes the sprite silhouette exact and forces every opaque pixel to palette
//   index 3, whereas a single plane would shrink the silhouette to that plane's
//   bits and the high plane cannot be delivered at all through the 8-bit port.
//   sp_shadow_valid gates the mux because nes_sprite_chr_fetch's shadow register
//   has no reset: before the first completed line it is X, and X on chr_sh would
//   make slot_opaque / sprite_pixel X inside nes_ppu_sprite and corrupt the pixel.
//
// Two hazards this integration inherits rather than creates:
//   * pat_addr_o is computed from scanline_sel, which the PPU wires to the current
//     scanline, and the prefetch that latches it only completes at dot 292 of the
//     same line. The shadow a line's own pixels consume is therefore the one
//     latched at the previous line's dot 257, i.e. one line off. Closing that
//     needs pat_addr_o evaluated for the next scanline, or start issued a line
//     early; both are nes_ppu_sprite / integration changes, not this mux.
//   * nes_sprite_chr_fetch drives chr_addr = {pat_addr[10:0] + plane*8, 3'b000},
//     i.e. pattern address times 8, while nes_ppu_sprite's internal path indexes
//     its flat chr bus at {s_pat_addr, 3'b000} and therefore reads byte
//     s_pat_addr, and nes_chr_fetch_unit likewise uses the pattern address
//     directly. The sprite prefetcher is therefore 8x above the address the
//     internal sprite path and the background fetcher use. The two conventions
//     have to be reconciled in nes_sprite_chr_fetch (or by pre-scaling pat_addr,
//     which is impossible for a pattern address that is not a multiple of 8)
//     before the fetched shadow can be pixel-compared against the internal path.

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
            .chr_sh(8'h00),
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
        wire [13:0] bg_chr_addr;
        wire        sp_chr_req;
        wire [13:0] sp_chr_addr;
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
        wire [7:0]  sp_chr_sh;

        assign sp_start = (dot == 9'd257);
        assign sp_bus_sel = sp_busy;
        assign sp_base_lo = {sp_slot[2:0], 4'b0000};
        assign sp_base_hi = {sp_slot[2:0], 4'b1000};
        assign sp_plane_lo = (sp_slot == 4'h8) ? 8'h00 : sp_shadow[sp_base_lo +: 8];
        assign sp_plane_hi = (sp_slot == 4'h8) ? 8'h00 : sp_shadow[sp_base_hi +: 8];
        assign sp_chr_sh = sp_shadow_valid ? (sp_plane_lo | sp_plane_hi) : 8'h00;

        nes_sprite_chr_fetch u_sprite_chr_fetch (
            .clk(clk),
            .ce(ce),
            .reset(reset),
            .start(sp_start),
            .pat_addr(sprite_pat_addr_bus),
            .chr_req(sp_chr_req),
            .chr_addr(sp_chr_addr),
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
            .chr_addr(bg_chr_addr),
            .chr_rdata(chr_rdata),
            .bg_lo(chr_fetch_bg_lo),
            .bg_hi(chr_fetch_bg_hi),
            .bg_valid(chr_fetch_bg_valid),
            .busy(chr_fetch_busy)
        );

        assign chr_req = sp_bus_sel ? sp_chr_req : bg_chr_req;
        assign chr_addr = sp_bus_sel ? sp_chr_addr : bg_chr_addr;

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
