`timescale 1ns/1ps

module nes_ppu_sprite #(
    parameter EXTERNAL_CHR = 1'b0
)(
    input  wire           clk,
    input  wire           reset,
    input  wire           ce,
    input  wire [2047:0]  oam,
    input  wire [65535:0] chr,
    input  wire [7:0]     chr_sh,
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
    output wire [103:0]   pat_addr_o
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
            wire [2:0]  s_tile;
            wire        s_table;
            wire [12:0] s_pat_addr;
            wire [7:0]  s_plane_lo;
            wire [7:0]  s_plane_hi;
            wire [3:0]  s_pat;
            wire [9:0]  s_xoff;
            wire [2:0]  s_xbit;

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
            assign s_tile = ctrl[5] ? (s_tile_byte[3:1] + {2'b00, s_row[3]}) : s_tile_byte[2:0];
            assign s_fine = slot_attr[g][7] ? ({1'b0, sprite_height} - 10'd1 - s_row) : s_row;
            assign s_pat_addr = {s_table, 5'b00000, s_tile, 1'b0, s_fine[2:0]};
            assign pat_addr_o[g*13 +: 13] = s_pat_addr;
            if (!EXTERNAL_CHR) begin : g_chr_internal
                assign s_plane_lo = chr[{s_pat_addr, 3'b000} +: 8];
                assign s_plane_hi = chr[({s_pat_addr, 3'b000} + 13'd64) +: 8];
            end else begin : g_chr_external
                assign s_plane_lo = chr_sh;
                assign s_plane_hi = chr_sh;
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

endmodule
