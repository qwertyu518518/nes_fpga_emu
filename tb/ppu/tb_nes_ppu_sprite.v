`timescale 1ns/1ps

module tb_nes_ppu_sprite;

    reg         clk;
    reg         reset;
    reg         ce;
    reg  [7:0]  ctrl;
    reg  [7:0]  mask;
    reg  [8:0]  scanline;
    reg  [8:0]  dot;
    reg  [3:0]  bg_pixel;

    wire [2047:0]  oam;
    wire [65535:0] chr;
    wire [3:0]     sprite_pixel;
    wire [3:0]     sprite_priority;
    wire           sprite0_hit;
    wire           sprite_overflow;
    wire [3:0]     cur_slot;

    reg [2047:0]  oam_bus;
    reg [65535:0] chr_bus;

    reg [7:0] ctrl_probe [0:9];
    reg [7:0] mask_probe [0:9];
    reg [3:0] bg_probe  [0:3];

    integer scan_row;
    integer probe_i;
    integer cs_i;
    integer cs_j;

    reg [3:0] cs_exp;
    reg [3:0] cs_found;
    reg [3:0] cs_only;
    reg [3:0] cs_cover;
    reg [2:0] cs_pick;
    reg [9:0] cs_xoff;
    reg [2:0] cs_opaque_src;

    integer tr_i;
    integer tr_j;
    integer tr_c;
    integer tr_lit;
    reg [8:0] tr_y9;
    reg [8:0] tr_x9;
    reg [7:0] tr_exp;
    reg [7:0] tr_tile [0:11];
    reg [7:0] tr_pair  [0:3];
    reg [7:0] tr_byte  [0:1];
    reg [8*96-1:0] tr_name;

    nes_ppu_sprite dut (
        .clk(clk),
        .reset(reset),
        .ce(ce),
        .oam(oam),
        .chr(chr),
        .ctrl(ctrl),
        .mask(mask),
        .scanline(scanline),
        .dot(dot),
        .bg_pixel(bg_pixel),
        .sprite_pixel(sprite_pixel),
        .sprite_priority(sprite_priority),
        .sprite0_hit(sprite0_hit),
        .sprite_overflow(sprite_overflow),
        .cur_slot_o(cur_slot)
    );

    assign oam = oam_bus;
    assign chr = chr_bus;

    always #5 clk = ~clk;

    task clear_scene;
        begin
            oam_bus = {2048{1'b0}};
            chr_bus = {65536{1'b0}};
            ctrl = 8'h00;
            mask = 8'h1C;
            bg_pixel = 4'h0;
            scanline = 9'd32;
            dot = 9'd32;
            reset = 1'b0;
            ce = 1'b0;
            #1;
        end
    endtask

    task set_sprite;
        input [5:0] index;
        input [7:0] y;
        input [7:0] tile;
        input [7:0] attr;
        input [7:0] x;
        integer base;
        begin
            base = index * 4;
            oam_bus[base * 8 + 0 +: 8] = y;
            oam_bus[base * 8 + 8 +: 8] = tile;
            oam_bus[base * 8 + 16 +: 8] = attr;
            oam_bus[base * 8 + 24 +: 8] = x;
        end
    endtask

    task fill_tile;
        input [12:0] table_base;
        input [7:0] tile;
        input [7:0] lo;
        input [7:0] hi;
        integer base;
        integer row;
        begin
            for (row = 0; row < 8; row = row + 1) begin
                base = table_base + tile * 16 + row;
                chr_bus[base * 8 +: 8] = lo;
                chr_bus[(base + 8) * 8 +: 8] = hi;
            end
        end
    endtask

    task fill_tile_row;
        input [12:0] table_base;
        input [7:0] tile;
        input [3:0] row;
        input [7:0] lo;
        input [7:0] hi;
        integer base;
        begin
            base = table_base + tile * 16 + row;
            chr_bus[base * 8 +: 8] = lo;
            chr_bus[(base + 8) * 8 +: 8] = hi;
        end
    endtask

    task fill_tile_number_table;
        input [12:0] table_base;
        integer tn;
        begin
            for (tn = 0; tn < 256; tn = tn + 1)
                fill_tile(table_base, tn[7:0], tn[7:0], ~tn[7:0]);
        end
    endtask

    function [3:0] tr_pixel;
        input [7:0] t;
        input [2:0] xbit;
        begin
            tr_pixel = {2'b00, ~t[xbit], t[xbit]};
        end
    endfunction

    function [31:0] tr_row_sig;
        input [7:0] t;
        integer k;
        begin
            tr_row_sig = 32'd0;
            for (k = 0; k < 8; k = k + 1)
                tr_row_sig[k * 4 +: 4] = tr_pixel(t, 3'd7 - k[2:0]);
        end
    endfunction

    task probe;
        input [8:0] line;
        input [8:0] xpos;
        begin
            scanline = line;
            dot = xpos;
            #1;
        end
    endtask

    task expect_pixel;
        input [8*96-1:0] name;
        input [3:0] expected_pixel;
        input [3:0] expected_priority;
        begin
            if (sprite_pixel !== expected_pixel)
                $fatal(1, "%0s: sprite_pixel got %01h expected %01h at %0d:%0d",
                       name, sprite_pixel, expected_pixel, scanline, dot);
            if (sprite_priority !== expected_priority)
                $fatal(1, "%0s: sprite_priority got %01h expected %01h at %0d:%0d",
                       name, sprite_priority, expected_priority, scanline, dot);
        end
    endtask

    task expect_flags;
        input [8*96-1:0] name;
        input expected_hit;
        input expected_overflow;
        begin
            if (sprite0_hit !== expected_hit)
                $fatal(1, "%0s: sprite0_hit got %b expected %b at %0d:%0d",
                       name, sprite0_hit, expected_hit, scanline, dot);
            if (sprite_overflow !== expected_overflow)
                $fatal(1, "%0s: sprite_overflow got %b expected %b at %0d:%0d",
                       name, sprite_overflow, expected_overflow, scanline, dot);
        end
    endtask

    task expect_all;
        input [8*96-1:0] name;
        input [3:0] expected_pixel;
        input [3:0] expected_priority;
        input expected_hit;
        input expected_overflow;
        begin
            expect_pixel(name, expected_pixel, expected_priority);
            expect_flags(name, expected_hit, expected_overflow);
        end
    endtask

    task test_reset_and_clock_independence;
        begin
            clear_scene;
            fill_tile(13'd0, 8'd0, 8'hFF, 8'hFF);
            set_sprite(6'd0, 8'd32, 8'd0, 8'h00, 8'd32);
            set_sprite(6'd1, 8'd32, 8'd0, 8'h00, 8'd40);
            set_sprite(6'd2, 8'd32, 8'd0, 8'h00, 8'd48);
            set_sprite(6'd3, 8'd32, 8'd0, 8'h00, 8'd56);
            set_sprite(6'd4, 8'd32, 8'd0, 8'h00, 8'd64);
            set_sprite(6'd5, 8'd32, 8'd0, 8'h00, 8'd72);
            set_sprite(6'd6, 8'd32, 8'd0, 8'h00, 8'd80);
            set_sprite(6'd7, 8'd32, 8'd0, 8'h00, 8'd88);
            set_sprite(6'd8, 8'd32, 8'd0, 8'h00, 8'd96);
            probe(9'd32, 9'd32);
            expect_all("reset low opaque sprite", 4'h3, 4'h0, 1'b0, 1'b1);
            reset = 1'b1;
            #1;
            expect_all("reset high gates all outputs", 4'h0, 4'h0, 1'b0, 1'b0);
            reset = 1'b0;
            #1;
            expect_all("reset released restores output", 4'h3, 4'h0, 1'b0, 1'b1);
            ce = 1'b1;
            repeat (4) @(posedge clk);
            #1;
            expect_all("ce high does not change output", 4'h3, 4'h0, 1'b0, 1'b1);
            ce = 1'b0;
            repeat (4) @(posedge clk);
            #1;
            expect_all("ce low does not change output", 4'h3, 4'h0, 1'b0, 1'b1);
            bg_pixel = 4'hF;
            #1;
            expect_all("bg opaque raises sprite0 hit", 4'h3, 4'h0, 1'b1, 1'b1);
            bg_pixel = 4'h0;
            #1;
            expect_all("bg clear leaves sprite0 hit low", 4'h3, 4'h0, 1'b0, 1'b1);
            reset = 1'b1;
            ce = 1'b1;
            repeat (2) @(posedge clk);
            #1;
            expect_all("reset high also masks overflow", 4'h0, 4'h0, 1'b0, 1'b0);
            reset = 1'b0;
            ce = 1'b0;
            #1;
            $display("SPRITE reset gating and no clock/ce dependence PASS");
        end
    endtask

    task test_8x8;
        begin
            clear_scene;
            fill_tile(13'd0, 8'd1, 8'h80, 8'h00);
            set_sprite(6'd0, 8'd32, 8'd1, 8'h00, 8'd32);
            for (scan_row = 0; scan_row < 8; scan_row = scan_row + 1) begin
                probe(9'd32 + scan_row[8:0], 9'd32);
                expect_all("8x8 plane0 bit7 at xoffset 0", 4'h1, 4'h0, 1'b0, 1'b0);
                probe(9'd32 + scan_row[8:0], 9'd33);
                expect_all("8x8 plane0 xoffset 1 dark", 4'h0, 4'h0, 1'b0, 1'b0);
            end
            probe(9'd31, 9'd32);
            expect_all("8x8 row above sprite top", 4'h0, 4'h0, 1'b0, 1'b0);
            probe(9'd40, 9'd32);
            expect_all("8x8 row below sprite bottom", 4'h0, 4'h0, 1'b0, 1'b0);
            probe(9'd32, 9'd31);
            expect_all("8x8 column left of sprite", 4'h0, 4'h0, 1'b0, 1'b0);
            probe(9'd32, 9'd40);
            expect_all("8x8 column right of sprite", 4'h0, 4'h0, 1'b0, 1'b0);
            fill_tile(13'd0, 8'd1, 8'h00, 8'h80);
            probe(9'd32, 9'd32);
            expect_all("8x8 plane1 only", 4'h2, 4'h0, 1'b0, 1'b0);
            fill_tile(13'd0, 8'd1, 8'h80, 8'h80);
            probe(9'd32, 9'd32);
            expect_all("8x8 both planes", 4'h3, 4'h0, 1'b0, 1'b0);
            fill_tile(13'd0, 8'd1, 8'hFF, 8'h00);
            probe(9'd32, 9'd32);
            expect_all("8x8 solid first column", 4'h1, 4'h0, 1'b0, 1'b0);
            probe(9'd32, 9'd39);
            expect_all("8x8 solid last column", 4'h1, 4'h0, 1'b0, 1'b0);
            probe(9'd32, 9'd40);
            expect_all("8x8 solid past last column", 4'h0, 4'h0, 1'b0, 1'b0);
            $display("SPRITE 8x8 row/column addressing and both pattern planes PASS");
        end
    endtask

    task test_pattern_table;
        begin
            clear_scene;
            fill_tile(13'd0, 8'd2, 8'h80, 8'h00);
            fill_tile(13'd4096, 8'd5, 8'h80, 8'h00);
            set_sprite(6'd0, 8'd32, 8'd2, 8'h00, 8'd32);
            set_sprite(6'd1, 8'd32, 8'd5, 8'h00, 8'd64);
            ctrl = 8'h00;
            probe(9'd32, 9'd32);
            expect_all("table0 tile2 lit", 4'h1, 4'h0, 1'b0, 1'b0);
            probe(9'd32, 9'd64);
            expect_all("table0 tile5 dark", 4'h0, 4'h0, 1'b0, 1'b0);
            ctrl = 8'h08;
            probe(9'd32, 9'd32);
            expect_all("table1 tile2 dark", 4'h0, 4'h0, 1'b0, 1'b0);
            probe(9'd32, 9'd64);
            expect_all("table1 tile5 lit", 4'h1, 4'h0, 1'b0, 1'b0);
            ctrl = 8'h00;
            probe(9'd32, 9'd64);
            expect_all("table0 restored tile5 dark", 4'h0, 4'h0, 1'b0, 1'b0);
            $display("SPRITE 8x8 pattern table selection via PPUCTRL[3] PASS");
        end
    endtask

    task test_8x16;
        begin
            clear_scene;
            ctrl = 8'h20;
            fill_tile(13'd4096, 8'd0, 8'h80, 8'h00);
            fill_tile(13'd4096, 8'd1, 8'h40, 8'h00);
            set_sprite(6'd0, 8'd40, 8'h01, 8'h00, 8'd40);
            for (scan_row = 0; scan_row < 8; scan_row = scan_row + 1) begin
                probe(9'd40 + scan_row[8:0], 9'd40);
                expect_all("8x16 top tile xoffset 0", 4'h1, 4'h0, 1'b0, 1'b0);
                probe(9'd40 + scan_row[8:0], 9'd41);
                expect_all("8x16 top tile xoffset 1", 4'h0, 4'h0, 1'b0, 1'b0);
                probe(9'd48 + scan_row[8:0], 9'd41);
                expect_all("8x16 bottom tile xoffset 1", 4'h1, 4'h0, 1'b0, 1'b0);
                probe(9'd48 + scan_row[8:0], 9'd40);
                expect_all("8x16 bottom tile xoffset 0", 4'h0, 4'h0, 1'b0, 1'b0);
            end
            probe(9'd39, 9'd40);
            expect_all("8x16 above top row", 4'h0, 4'h0, 1'b0, 1'b0);
            probe(9'd56, 9'd40);
            expect_all("8x16 below bottom row", 4'h0, 4'h0, 1'b0, 1'b0);
            fill_tile(13'd0, 8'd1, 8'hAA, 8'h00);
            ctrl = 8'h00;
            probe(9'd40, 9'd40);
            expect_all("PPUCTRL[5]=0 draws 8x8 from table 0", 4'h1, 4'h0, 1'b0, 1'b0);
            probe(9'd40, 9'd41);
            expect_all("PPUCTRL[5]=0 column 1 dark", 4'h0, 4'h0, 1'b0, 1'b0);
            probe(9'd48, 9'd41);
            expect_all("PPUCTRL[5]=0 hides the lower half", 4'h0, 4'h0, 1'b0, 1'b0);
            ctrl = 8'h20;
            probe(9'd40, 9'd40);
            expect_all("PPUCTRL[5]=1 draws 8x16 from table 1", 4'h1, 4'h0, 1'b0, 1'b0);
            clear_scene;
            fill_tile(13'd0, 8'd0, 8'h80, 8'h00);
            fill_tile(13'd0, 8'd1, 8'h40, 8'h00);
            fill_tile(13'd4096, 8'd1, 8'h80, 8'h00);
            fill_tile(13'd4096, 8'd2, 8'h81, 8'h00);
            fill_tile(13'd4096, 8'd3, 8'h42, 8'h00);
            set_sprite(6'd0, 8'd40, 8'h00, 8'h00, 8'd40);
            set_sprite(6'd1, 8'd72, 8'h01, 8'h00, 8'd72);
            set_sprite(6'd2, 8'd72, 8'h03, 8'h00, 8'd104);
            ctrl = 8'h20;
            probe(9'd40, 9'd40);
            expect_all("8x16 tilebit0=0 top in table 0", 4'h1, 4'h0, 1'b0, 1'b0);
            probe(9'd48, 9'd41);
            expect_all("8x16 tilebit0=0 bottom in table 0", 4'h1, 4'h0, 1'b0, 1'b0);
            ctrl = 8'h28;
            probe(9'd40, 9'd40);
            expect_all("8x16 ignores PPUCTRL[3] top", 4'h1, 4'h0, 1'b0, 1'b0);
            probe(9'd48, 9'd41);
            expect_all("8x16 ignores PPUCTRL[3] bottom", 4'h1, 4'h0, 1'b0, 1'b0);
            probe(9'd72, 9'd72);
            expect_all("8x16 odd tile top half dark", 4'h0, 4'h0, 1'b0, 1'b0);
            probe(9'd80, 9'd72);
            expect_all("8x16 odd tile bottom half lit", 4'h1, 4'h0, 1'b0, 1'b0);
            probe(9'd72, 9'd104);
            expect_all("8x16 pair 2/3 top half reads table1 tile2", 4'h1, 4'h0, 1'b0, 1'b0);
            probe(9'd80, 9'd105);
            expect_all("8x16 pair 2/3 bottom half reads table1 tile3", 4'h1, 4'h0, 1'b0, 1'b0);
            $display("SPRITE 8x16 pair 2/3 from tile byte 03: table1 tile2 low plane %02h bit7 at xoffset 0 gives %01h, table1 tile3 low plane %02h bit6 at xoffset 1 gives %01h", 8'h81, 4'h1, 8'h42, 4'h1);
            probe(9'd88, 9'd104);
            expect_all("8x16 past 16 pixel height", 4'h0, 4'h0, 1'b0, 1'b0);
            $display("SPRITE 8x16 tile pair, table from tile bit0, PPUCTRL[3] ignored PASS");
        end
    endtask

    task test_8x8_tile_range;
        begin
            clear_scene;
            fill_tile_number_table(13'd0);
            tr_tile[0]  = 8'd0;
            tr_tile[1]  = 8'd6;
            tr_tile[2]  = 8'd7;
            tr_tile[3]  = 8'd8;
            tr_tile[4]  = 8'd9;
            tr_tile[5]  = 8'd15;
            tr_tile[6]  = 8'd16;
            tr_tile[7]  = 8'd63;
            tr_tile[8]  = 8'd127;
            tr_tile[9]  = 8'd128;
            tr_tile[10] = 8'd200;
            tr_tile[11] = 8'd255;
            for (tr_i = 0; tr_i < 12; tr_i = tr_i + 1)
                for (tr_j = tr_i + 1; tr_j < 12; tr_j = tr_j + 1)
                    if (tr_row_sig(tr_tile[tr_i]) === tr_row_sig(tr_tile[tr_j]))
                        $fatal(1, "8x8 tile range: tiles %0d and %0d would expect the same 8 pixel row",
                               tr_tile[tr_i], tr_tile[tr_j]);
            if (tr_row_sig(tr_tile[0]) === tr_row_sig(tr_tile[3]))
                $fatal(1, "8x8 tile range: tile 0 and tile 8 would expect the same 8 pixel row");
            if (tr_row_sig(tr_tile[2]) === tr_row_sig(tr_tile[11]))
                $fatal(1, "8x8 tile range: tile 7 and tile 255 would expect the same 8 pixel row");
            $display("SPRITE 8x8 tile range: table 0 tiles 0..255 each have low plane equal to the tile number and high plane equal to its complement, tiles 0 6 7 8 9 15 16 63 127 128 200 255 checked, tile 8 differs from tile 0 and tile 255 differs from tile 7");
            ctrl = 8'h00;
            tr_lit = 0;
            for (tr_i = 0; tr_i < 12; tr_i = tr_i + 1) begin
                tr_y9 = 9'd32 + tr_i[8:0] * 9'd8;
                set_sprite(tr_i[5:0], tr_y9[7:0], tr_tile[tr_i], 8'h00, 8'd32);
                for (tr_c = 0; tr_c < 8; tr_c = tr_c + 1) begin
                    $sformat(tr_name, "8x8 tile %0d column %0d", tr_tile[tr_i], tr_c);
                    probe(tr_y9, 9'd32 + tr_c[8:0]);
                    expect_all(tr_name, tr_pixel(tr_tile[tr_i], 3'd7 - tr_c[2:0]), 4'h0, 1'b0, 1'b0);
                    if (sprite_pixel !== 4'h0)
                        tr_lit = tr_lit + 1;
                end
                $sformat(tr_name, "8x8 tile %0d past last column", tr_tile[tr_i]);
                probe(tr_y9, 9'd40);
                expect_all(tr_name, 4'h0, 4'h0, 1'b0, 1'b0);
            end
            if (tr_lit != 96)
                $fatal(1, "8x8 tile range: %0d of 96 probed sprite pixels were opaque, expected 96",
                       tr_lit);
            $display("SPRITE 8x8 tile number 0..255 each reads its own 8 pixel row, %0d opaque pixels PASS", tr_lit);
        end
    endtask

    task test_8x16_tile_pair_range;
        begin
            clear_scene;
            fill_tile_number_table(13'd0);
            tr_byte[0] = 8'hFE;
            tr_byte[1] = 8'h80;
            for (tr_i = 0; tr_i < 2; tr_i = tr_i + 1) begin
                tr_exp = {tr_byte[tr_i][7:1], 1'b0};
                tr_pair[tr_i * 2]     = tr_exp;
                tr_pair[tr_i * 2 + 1] = tr_exp + 8'd1;
            end
            for (tr_i = 0; tr_i < 4; tr_i = tr_i + 1) begin
                for (tr_j = tr_i + 1; tr_j < 4; tr_j = tr_j + 1)
                    if (tr_row_sig(tr_pair[tr_i]) === tr_row_sig(tr_pair[tr_j]))
                        $fatal(1, "8x16 pair: tiles %0d and %0d would expect the same 8 pixel row",
                               tr_pair[tr_i], tr_pair[tr_j]);
                for (tr_j = 0; tr_j < 8; tr_j = tr_j + 1)
                    if (tr_row_sig(tr_pair[tr_i]) === tr_row_sig(tr_j[7:0]))
                        $fatal(1, "8x16 pair: tile %0d would be indistinguishable from tile %0d, so a truncated tile field could not be caught",
                               tr_pair[tr_i], tr_j);
            end
            $display("SPRITE 8x16 pair range: tile byte FE pairs 254/255, tile byte 80 pairs 64/65, all four rows differ from each other and from every tile 0..7");
            ctrl = 8'h20;
            tr_lit = 0;
            for (tr_i = 0; tr_i < 2; tr_i = tr_i + 1) begin
                if (tr_i == 0) begin
                    tr_y9 = 9'd32;
                    tr_x9 = 9'd32;
                end else begin
                    tr_y9 = 9'd64;
                    tr_x9 = 9'd72;
                end
                set_sprite(tr_i[5:0], tr_y9[7:0], tr_byte[tr_i], 8'h00, tr_x9[7:0]);
                for (tr_j = 0; tr_j < 16; tr_j = tr_j + 1) begin
                    for (tr_c = 0; tr_c < 8; tr_c = tr_c + 1) begin
                        $sformat(tr_name, "8x16 tile byte %02h row %0d column %0d",
                                 tr_byte[tr_i], tr_j, tr_c);
                        probe(tr_y9 + tr_j[8:0], tr_x9 + tr_c[8:0]);
                        if (tr_j < 8)
                            expect_all(tr_name, tr_pixel(tr_pair[tr_i * 2], 3'd7 - tr_c[2:0]), 4'h0, 1'b0, 1'b0);
                        else
                            expect_all(tr_name, tr_pixel(tr_pair[tr_i * 2 + 1], 3'd7 - tr_c[2:0]), 4'h0, 1'b0, 1'b0);
                        if (sprite_pixel !== 4'h0)
                            tr_lit = tr_lit + 1;
                    end
                end
                $sformat(tr_name, "8x16 tile byte %02h past 16 pixel height", tr_byte[tr_i]);
                probe(tr_y9 + 9'd16, tr_x9);
                expect_all(tr_name, 4'h0, 4'h0, 1'b0, 1'b0);
            end
            if (tr_lit != 256)
                $fatal(1, "8x16 pair: %0d of 256 probed sprite pixels were opaque, expected 256",
                       tr_lit);
            $display("SPRITE 8x16 tile pairs 254/255 and 64/65 read their own 8 pixel rows, %0d opaque pixels PASS", tr_lit);
        end
    endtask

    task test_flips;
        begin
            clear_scene;
            for (probe_i = 0; probe_i < 4; probe_i = probe_i + 1)
                fill_tile_row(13'd0, probe_i[7:0], 4'd0, 8'h80, 8'h00);
            set_sprite(6'd0, 8'd32, 8'd0, 8'h00, 8'd16);
            set_sprite(6'd1, 8'd32, 8'd1, 8'h40, 8'd32);
            set_sprite(6'd2, 8'd32, 8'd2, 8'h80, 8'd48);
            set_sprite(6'd3, 8'd32, 8'd3, 8'hC0, 8'd64);
            probe(9'd32, 9'd16);
            expect_all("no flip xoffset 0 lit", 4'h1, 4'h0, 1'b0, 1'b0);
            probe(9'd32, 9'd17);
            expect_all("no flip xoffset 1 dark", 4'h0, 4'h0, 1'b0, 1'b0);
            probe(9'd32, 9'd39);
            expect_all("h flip xoffset 7 lit", 4'h1, 4'h0, 1'b0, 1'b0);
            probe(9'd32, 9'd32);
            expect_all("h flip xoffset 0 dark", 4'h0, 4'h0, 1'b0, 1'b0);
            probe(9'd32, 9'd48);
            expect_all("v flip top row dark", 4'h0, 4'h0, 1'b0, 1'b0);
            probe(9'd32, 9'd64);
            expect_all("both flip top row dark", 4'h0, 4'h0, 1'b0, 1'b0);
            probe(9'd34, 9'd16);
            expect_all("no flip blank row", 4'h0, 4'h0, 1'b0, 1'b0);
            probe(9'd34, 9'd39);
            expect_all("h flip blank row", 4'h0, 4'h0, 1'b0, 1'b0);
            probe(9'd39, 9'd16);
            expect_all("no flip bottom row dark", 4'h0, 4'h0, 1'b0, 1'b0);
            probe(9'd39, 9'd48);
            expect_all("v flip bottom row xoffset 0 lit", 4'h1, 4'h0, 1'b0, 1'b0);
            probe(9'd39, 9'd71);
            expect_all("both flip bottom row xoffset 7 lit", 4'h1, 4'h0, 1'b0, 1'b0);
            probe(9'd40, 9'd48);
            expect_all("past flipped sprite bottom", 4'h0, 4'h0, 1'b0, 1'b0);
            fill_tile_row(13'd0, 8'd4, 4'd0, 8'h81, 8'h00);
            set_sprite(6'd4, 8'd32, 8'd4, 8'h00, 8'd96);
            set_sprite(6'd5, 8'd32, 8'd4, 8'h40, 8'd112);
            probe(9'd32, 9'd96);
            expect_all("bit7 at xoffset 0", 4'h1, 4'h0, 1'b0, 1'b0);
            probe(9'd32, 9'd97);
            expect_all("no flip middle dark", 4'h0, 4'h0, 1'b0, 1'b0);
            probe(9'd32, 9'd103);
            expect_all("bit0 at xoffset 7", 4'h1, 4'h0, 1'b0, 1'b0);
            probe(9'd32, 9'd104);
            expect_all("past no flip sprite", 4'h0, 4'h0, 1'b0, 1'b0);
            probe(9'd32, 9'd112);
            expect_all("h flip bit0 at xoffset 0", 4'h1, 4'h0, 1'b0, 1'b0);
            probe(9'd32, 9'd113);
            expect_all("h flip middle dark", 4'h0, 4'h0, 1'b0, 1'b0);
            probe(9'd32, 9'd119);
            expect_all("h flip bit7 at xoffset 7", 4'h1, 4'h0, 1'b0, 1'b0);
            probe(9'd32, 9'd120);
            expect_all("past h flip sprite", 4'h0, 4'h0, 1'b0, 1'b0);
            $display("SPRITE horizontal, vertical and combined flip PASS");
        end
    endtask

    task test_palette_and_priority;
        begin
            clear_scene;
            for (probe_i = 0; probe_i < 4; probe_i = probe_i + 1)
                fill_tile(13'd0, probe_i[7:0], 8'hFF, 8'h00);
            set_sprite(6'd0, 8'd32, 8'd0, 8'h00, 8'd16);
            set_sprite(6'd1, 8'd32, 8'd1, 8'h01, 8'd32);
            set_sprite(6'd2, 8'd32, 8'd2, 8'h02, 8'd48);
            set_sprite(6'd3, 8'd32, 8'd3, 8'h03, 8'd64);
            probe(9'd32, 9'd16);
            expect_all("palette 0 pattern 1", 4'h1, 4'h0, 1'b0, 1'b0);
            probe(9'd32, 9'd32);
            expect_all("palette 1 pattern 1", 4'h5, 4'h0, 1'b0, 1'b0);
            probe(9'd32, 9'd48);
            expect_all("palette 2 pattern 1", 4'h9, 4'h0, 1'b0, 1'b0);
            probe(9'd32, 9'd64);
            expect_all("palette 3 pattern 1", 4'hD, 4'h0, 1'b0, 1'b0);
            probe(9'd32, 9'd72);
            expect_all("past last sprite", 4'h0, 4'h0, 1'b0, 1'b0);
            set_sprite(6'd3, 8'd32, 8'd3, 8'h23, 8'd64);
            probe(9'd32, 9'd64);
            expect_all("palette 3 behind background", 4'hD, 4'hF, 1'b0, 1'b0);
            set_sprite(6'd3, 8'd32, 8'd3, 8'h2B, 8'd64);
            probe(9'd32, 9'd64);
            expect_all("palette 3 hflip behind background", 4'hD, 4'hF, 1'b0, 1'b0);
            set_sprite(6'd3, 8'd32, 8'd3, 8'hA3, 8'd64);
            probe(9'd32, 9'd64);
            expect_all("palette 3 vflip behind background", 4'hD, 4'hF, 1'b0, 1'b0);
            set_sprite(6'd0, 8'd32, 8'd0, 8'h20, 8'd16);
            bg_pixel = 4'h1;
            probe(9'd32, 9'd16);
            expect_all("priority bit does not gate sprite0 hit", 4'h1, 4'hF, 1'b1, 1'b0);
            probe(9'd32, 9'd17);
            expect_all("hit follows the priority sprite", 4'h1, 4'hF, 1'b1, 1'b0);
            $display("SPRITE palette index and priority output PASS");
        end
    endtask

    task test_left8_clip;
        begin
            clear_scene;
            fill_tile(13'd0, 8'd0, 8'h80, 8'h00);
            fill_tile(13'd0, 8'd1, 8'h01, 8'h00);
            fill_tile(13'd0, 8'd2, 8'hFF, 8'h00);
            set_sprite(6'd0, 8'd32, 8'd0, 8'h00, 8'd0);
            set_sprite(6'd1, 8'd32, 8'd1, 8'h00, 8'd0);
            set_sprite(6'd2, 8'd32, 8'd2, 8'h20, 8'd4);
            mask = 8'h1C;
            probe(9'd32, 9'd0);
            expect_all("mask2 set xoffset 0 lit", 4'h1, 4'h0, 1'b0, 1'b0);
            probe(9'd32, 9'd1);
            expect_all("mask2 set xoffset 1 dark", 4'h0, 4'h0, 1'b0, 1'b0);
            probe(9'd32, 9'd4);
            expect_all("mask2 set spanning sprite at xoffset 0", 4'h1, 4'hF, 1'b0, 1'b0);
            probe(9'd32, 9'd7);
            expect_all("mask2 set bit0 sprite wins at xoffset 7", 4'h1, 4'h0, 1'b0, 1'b0);
            probe(9'd32, 9'd8);
            expect_all("mask2 set spanning sprite at xoffset 4", 4'h1, 4'hF, 1'b0, 1'b0);
            probe(9'd32, 9'd11);
            expect_all("mask2 set spanning sprite at xoffset 7", 4'h1, 4'hF, 1'b0, 1'b0);
            probe(9'd32, 9'd12);
            expect_all("mask2 set past spanning sprite", 4'h0, 4'h0, 1'b0, 1'b0);
            mask = 8'h18;
            probe(9'd32, 9'd0);
            expect_all("clip hides xoffset 0", 4'h0, 4'h0, 1'b0, 1'b0);
            probe(9'd32, 9'd1);
            expect_all("clip hides xoffset 1", 4'h0, 4'h0, 1'b0, 1'b0);
            probe(9'd32, 9'd4);
            expect_all("clip hides spanning sprite and its priority", 4'h0, 4'h0, 1'b0, 1'b0);
            probe(9'd32, 9'd7);
            expect_all("clip hides xoffset 7", 4'h0, 4'h0, 1'b0, 1'b0);
            probe(9'd32, 9'd8);
            expect_all("dot 8 is outside the clipped window", 4'h1, 4'hF, 1'b0, 1'b0);
            probe(9'd32, 9'd12);
            expect_all("past spanning sprite with clip", 4'h0, 4'h0, 1'b0, 1'b0);
            bg_pixel = 4'h1;
            probe(9'd32, 9'd0);
            expect_all("clip suppresses sprite0 hit at dot 0", 4'h0, 4'h0, 1'b0, 1'b0);
            mask = 8'h1C;
            probe(9'd32, 9'd0);
            expect_all("mask2 set raises sprite0 hit at dot 0", 4'h1, 4'h0, 1'b1, 1'b0);
            $display("SPRITE left-8 clipping via PPUMASK[2] PASS");
        end
    endtask

    task test_eight_sprite_limit;
        begin
            clear_scene;
            fill_tile(13'd0, 8'd0, 8'hFF, 8'h00);
            set_sprite(6'd0, 8'd250, 8'd0, 8'h00, 8'd0);
            set_sprite(6'd1, 8'd32, 8'd0, 8'h00, 8'd32);
            set_sprite(6'd2, 8'd32, 8'd0, 8'h01, 8'd32);
            set_sprite(6'd3, 8'd32, 8'd0, 8'h02, 8'd32);
            set_sprite(6'd4, 8'd32, 8'd0, 8'h03, 8'd32);
            set_sprite(6'd5, 8'd32, 8'd0, 8'h00, 8'd32);
            set_sprite(6'd6, 8'd32, 8'd0, 8'h01, 8'd32);
            set_sprite(6'd7, 8'd32, 8'd0, 8'h02, 8'd32);
            set_sprite(6'd8, 8'd32, 8'd0, 8'h03, 8'd200);
            set_sprite(6'd9, 8'd250, 8'd0, 8'h00, 8'd200);
            probe(9'd32, 9'd32);
            expect_all("lowest OAM index wins overlap", 4'h1, 4'h0, 1'b0, 1'b0);
            probe(9'd32, 9'd200);
            expect_all("eighth in range sprite renders", 4'hD, 4'h0, 1'b0, 1'b0);
            probe(9'd32, 9'd208);
            expect_all("past eighth sprite", 4'h0, 4'h0, 1'b0, 1'b0);
            set_sprite(6'd9, 8'd32, 8'd0, 8'h00, 8'd200);
            probe(9'd32, 9'd32);
            expect_all("nine in range keeps lowest index", 4'h1, 4'h0, 1'b0, 1'b1);
            probe(9'd32, 9'd200);
            expect_all("ninth in range sprite dropped", 4'hD, 4'h0, 1'b0, 1'b1);
            set_sprite(6'd8, 8'd250, 8'd0, 8'h00, 8'd200);
            set_sprite(6'd9, 8'd250, 8'd0, 8'h00, 8'd200);
            probe(9'd32, 9'd200);
            expect_all("seven in range drops slot 8", 4'h0, 4'h0, 1'b0, 1'b0);
            probe(9'd32, 9'd32);
            expect_all("seven in range clears overflow", 4'h1, 4'h0, 1'b0, 1'b0);
            set_sprite(6'd8, 8'd32, 8'd0, 8'h03, 8'd200);
            set_sprite(6'd9, 8'd32, 8'd0, 8'h01, 8'd200);
            mask = 8'h00;
            probe(9'd32, 9'd32);
            expect_all("PPUMASK[4] is not honoured", 4'h1, 4'h0, 1'b0, 1'b1);
            mask = 8'h1C;
            probe(9'd32, 9'd256);
            expect_all("overflow ignores dot count", 4'h0, 4'h0, 1'b0, 1'b1);
            probe(9'd32, 9'd340);
            expect_all("overflow at last dot", 4'h0, 4'h0, 1'b0, 1'b1);
            set_sprite(6'd0, 8'd236, 8'd0, 8'h00, 8'd0);
            set_sprite(6'd1, 8'd236, 8'd0, 8'h00, 8'd0);
            set_sprite(6'd2, 8'd236, 8'd0, 8'h00, 8'd0);
            set_sprite(6'd3, 8'd236, 8'd0, 8'h00, 8'd0);
            set_sprite(6'd4, 8'd236, 8'd0, 8'h00, 8'd0);
            set_sprite(6'd5, 8'd236, 8'd0, 8'h00, 8'd0);
            set_sprite(6'd6, 8'd236, 8'd0, 8'h00, 8'd0);
            set_sprite(6'd7, 8'd236, 8'd0, 8'h00, 8'd0);
            set_sprite(6'd8, 8'd236, 8'd0, 8'h00, 8'd0);
            set_sprite(6'd9, 8'd236, 8'd0, 8'h00, 8'd0);
            probe(9'd239, 9'd8);
            expect_all("last visible line overflows", 4'h0, 4'h0, 1'b0, 1'b1);
            probe(9'd240, 9'd8);
            expect_all("vblank line masks overflow", 4'h0, 4'h0, 1'b0, 1'b0);
            $display("SPRITE 8-sprite-per-line limit, OAM order and overflow PASS");
        end
    endtask

    task test_sprite0_hit;
        begin
            clear_scene;
            fill_tile(13'd0, 8'd0, 8'hFF, 8'hFF);
            fill_tile(13'd0, 8'd1, 8'h80, 8'h00);
            set_sprite(6'd0, 8'd32, 8'd0, 8'h00, 8'd32);
            probe(9'd32, 9'd32);
            expect_all("transparent bg gives no hit", 4'h3, 4'h0, 1'b0, 1'b0);
            bg_pixel = 4'h1;
            probe(9'd32, 9'd32);
            expect_all("opaque bg raises hit", 4'h3, 4'h0, 1'b1, 1'b0);
            probe(9'd32, 9'd33);
            expect_all("hit follows every sprite pixel", 4'h3, 4'h0, 1'b1, 1'b0);
            probe(9'd32, 9'd40);
            expect_all("no hit past the sprite", 4'h0, 4'h0, 1'b0, 1'b0);
            probe(9'd31, 9'd32);
            expect_all("no hit on the row above", 4'h0, 4'h0, 1'b0, 1'b0);
            set_sprite(6'd0, 8'd32, 8'd0, 8'h20, 8'd32);
            probe(9'd32, 9'd32);
            expect_all("priority bit does not block the hit", 4'h3, 4'hF, 1'b1, 1'b0);
            set_sprite(6'd0, 8'd32, 8'd1, 8'h00, 8'd32);
            probe(9'd32, 9'd32);
            expect_all("hit on a lit pixel", 4'h1, 4'h0, 1'b1, 1'b0);
            probe(9'd32, 9'd33);
            expect_all("no hit on a transparent pixel", 4'h0, 4'h0, 1'b0, 1'b0);
            set_sprite(6'd0, 8'd32, 8'd0, 8'h00, 8'd248);
            probe(9'd32, 9'd247);
            expect_all("no hit left of sprite 0", 4'h0, 4'h0, 1'b0, 1'b0);
            probe(9'd32, 9'd248);
            expect_all("hit at sprite 0 left edge", 4'h3, 4'h0, 1'b1, 1'b0);
            probe(9'd32, 9'd255);
            expect_all("hit at dot 255 is not suppressed", 4'h3, 4'h0, 1'b1, 1'b0);
            probe(9'd32, 9'd256);
            expect_all("no hit at dot 256", 4'h0, 4'h0, 1'b0, 1'b0);
            set_sprite(6'd0, 8'd250, 8'd0, 8'h00, 8'd32);
            set_sprite(6'd1, 8'd32, 8'd0, 8'h01, 8'd32);
            probe(9'd32, 9'd32);
            expect_all("slot 0 substitutes the first in range sprite", 4'h7, 4'h0, 1'b1, 1'b0);
            set_sprite(6'd1, 8'd32, 8'd0, 8'h01, 8'd40);
            probe(9'd32, 9'd32);
            expect_all("substituted slot 0 is transparent here", 4'h0, 4'h0, 1'b0, 1'b0);
            probe(9'd32, 9'd40);
            expect_all("substituted slot 0 can raise the hit", 4'h7, 4'h0, 1'b1, 1'b0);
            $display("SPRITE sprite 0 hit conditions and slot substitution PASS");
        end
    endtask

    task test_dot_vblank_and_reset_masking;
        begin
            clear_scene;
            fill_tile(13'd0, 8'd0, 8'hFF, 8'hFF);
            set_sprite(6'd0, 8'd32, 8'd0, 8'h00, 8'd32);
            set_sprite(6'd1, 8'd32, 8'd0, 8'h00, 8'd64);
            set_sprite(6'd2, 8'd32, 8'd0, 8'h00, 8'd72);
            set_sprite(6'd3, 8'd32, 8'd0, 8'h00, 8'd80);
            set_sprite(6'd4, 8'd32, 8'd0, 8'h00, 8'd88);
            set_sprite(6'd5, 8'd32, 8'd0, 8'h00, 8'd96);
            set_sprite(6'd6, 8'd32, 8'd0, 8'h00, 8'd104);
            set_sprite(6'd7, 8'd32, 8'd0, 8'h00, 8'd112);
            set_sprite(6'd8, 8'd32, 8'd0, 8'h00, 8'd120);
            bg_pixel = 4'h1;
            probe(9'd32, 9'd32);
            expect_all("visible pixel and overflow", 4'h3, 4'h0, 1'b1, 1'b1);
            probe(9'd32, 9'd255);
            expect_all("dot 255 still renders", 4'h0, 4'h0, 1'b0, 1'b1);
            probe(9'd32, 9'd256);
            expect_all("dot 256 masks the pixel", 4'h0, 4'h0, 1'b0, 1'b1);
            probe(9'd32, 9'd257);
            expect_all("dot 257 masks the pixel", 4'h0, 4'h0, 1'b0, 1'b1);
            probe(9'd32, 9'd340);
            expect_all("dot 340 keeps overflow", 4'h0, 4'h0, 1'b0, 1'b1);
            probe(9'd32, 9'd511);
            expect_all("dot 511 masks the pixel", 4'h0, 4'h0, 1'b0, 1'b1);
            set_sprite(6'd0, 8'd232, 8'd0, 8'h00, 8'd32);
            set_sprite(6'd1, 8'd232, 8'd0, 8'h00, 8'd64);
            set_sprite(6'd2, 8'd232, 8'd0, 8'h00, 8'd72);
            set_sprite(6'd3, 8'd232, 8'd0, 8'h00, 8'd80);
            set_sprite(6'd4, 8'd232, 8'd0, 8'h00, 8'd88);
            set_sprite(6'd5, 8'd232, 8'd0, 8'h00, 8'd96);
            set_sprite(6'd6, 8'd232, 8'd0, 8'h00, 8'd104);
            set_sprite(6'd7, 8'd232, 8'd0, 8'h00, 8'd112);
            set_sprite(6'd8, 8'd232, 8'd0, 8'h00, 8'd120);
            probe(9'd239, 9'd32);
            expect_all("last visible scanline renders", 4'h3, 4'h0, 1'b1, 1'b1);
            probe(9'd240, 9'd32);
            expect_all("scanline 240 masks everything", 4'h0, 4'h0, 1'b0, 1'b0);
            probe(9'd241, 9'd1);
            expect_all("scanline 241 masks everything", 4'h0, 4'h0, 1'b0, 1'b0);
            probe(9'd255, 9'd32);
            expect_all("scanline 255 masks everything", 4'h0, 4'h0, 1'b0, 1'b0);
            probe(9'd261, 9'd0);
            expect_all("pre-render line masks everything", 4'h0, 4'h0, 1'b0, 1'b0);
            probe(9'd511, 9'd32);
            expect_all("scanline 511 masks everything", 4'h0, 4'h0, 1'b0, 1'b0);
            set_sprite(6'd1, 8'd250, 8'd0, 8'h00, 8'd64);
            set_sprite(6'd2, 8'd250, 8'd0, 8'h00, 8'd72);
            set_sprite(6'd3, 8'd250, 8'd0, 8'h00, 8'd80);
            set_sprite(6'd4, 8'd250, 8'd0, 8'h00, 8'd88);
            set_sprite(6'd5, 8'd250, 8'd0, 8'h00, 8'd96);
            set_sprite(6'd6, 8'd250, 8'd0, 8'h00, 8'd104);
            set_sprite(6'd7, 8'd250, 8'd0, 8'h00, 8'd112);
            set_sprite(6'd8, 8'd250, 8'd0, 8'h00, 8'd120);
            probe(9'd239, 9'd32);
            expect_all("single in range sprite has no overflow", 4'h3, 4'h0, 1'b1, 1'b0);
            reset = 1'b1;
            probe(9'd239, 9'd32);
            expect_all("reset masks a valid pixel", 4'h0, 4'h0, 1'b0, 1'b0);
            reset = 1'b0;
            probe(9'd239, 9'd32);
            expect_all("reset release restores the pixel", 4'h3, 4'h0, 1'b1, 1'b0);
            $display("SPRITE dot>=256, vblank and reset masking PASS");
        end
    endtask

    task test_oam_boundaries;
        begin
            clear_scene;
            fill_tile(13'd0, 8'd0, 8'hFF, 8'hFF);
            bg_pixel = 4'h1;
            set_sprite(6'd63, 8'd32, 8'd0, 8'h00, 8'd40);
            probe(9'd32, 9'd40);
            expect_all("OAM entry 63 renders", 4'h3, 4'h0, 1'b1, 1'b0);
            probe(9'd32, 9'd39);
            expect_all("OAM entry 63 honours its X", 4'h0, 4'h0, 1'b0, 1'b0);
            probe(9'd32, 9'd47);
            expect_all("OAM entry 63 last column", 4'h3, 4'h0, 1'b1, 1'b0);
            probe(9'd32, 9'd48);
            expect_all("OAM entry 63 past its X", 4'h0, 4'h0, 1'b0, 1'b0);
            set_sprite(6'd63, 8'd32, 8'd0, 8'h00, 8'd32);
            set_sprite(6'd0, 8'd32, 8'd0, 8'h01, 8'd32);
            probe(9'd32, 9'd32);
            expect_all("OAM entry 0 outranks entry 63", 4'h7, 4'h0, 1'b1, 1'b0);
            clear_scene;
            fill_tile(13'd0, 8'd0, 8'hFF, 8'h00);
            for (probe_i = 0; probe_i < 64; probe_i = probe_i + 1)
                set_sprite(probe_i[5:0], 8'd250, 8'd0, 8'h00, 8'd0);
            set_sprite(6'd0, 8'd0, 8'd0, 8'h00, 8'd32);
            probe(9'd0, 9'd32);
            expect_all("Y=0 sprite on scanline 0", 4'h1, 4'h0, 1'b0, 1'b0);
            probe(9'd7, 9'd32);
            expect_all("Y=0 sprite last row", 4'h1, 4'h0, 1'b0, 1'b0);
            probe(9'd8, 9'd32);
            expect_all("Y=0 sprite row 8 is out of range", 4'h0, 4'h0, 1'b0, 1'b0);
            probe(9'd239, 9'd32);
            expect_all("Y=0 sprite is not on scanline 239", 4'h0, 4'h0, 1'b0, 1'b0);
            set_sprite(6'd0, 8'd255, 8'd0, 8'h00, 8'd32);
            probe(9'd0, 9'd32);
            expect_all("Y=255 does not wrap onto scanline 0", 4'h0, 4'h0, 1'b0, 1'b0);
            probe(9'd239, 9'd32);
            expect_all("Y=255 is out of range on scanline 239", 4'h0, 4'h0, 1'b0, 1'b0);
            probe(9'd255, 9'd32);
            expect_all("Y=255 is masked by the visible area limit", 4'h0, 4'h0, 1'b0, 1'b0);
            set_sprite(6'd0, 8'd248, 8'd0, 8'h00, 8'd32);
            probe(9'd247, 9'd32);
            expect_all("Y=248 starts below the visible area", 4'h0, 4'h0, 1'b0, 1'b0);
            probe(9'd248, 9'd32);
            expect_all("Y=248 is never visible", 4'h0, 4'h0, 1'b0, 1'b0);
            set_sprite(6'd0, 8'd232, 8'd0, 8'h00, 8'd32);
            probe(9'd232, 9'd32);
            expect_all("Y=232 first visible row", 4'h1, 4'h0, 1'b0, 1'b0);
            probe(9'd239, 9'd32);
            expect_all("Y=232 fills the last visible row", 4'h1, 4'h0, 1'b0, 1'b0);
            probe(9'd240, 9'd32);
            expect_all("scanline 240 clips Y=232", 4'h0, 4'h0, 1'b0, 1'b0);
            ctrl = 8'h20;
            fill_tile(13'd0, 8'd1, 8'hFF, 8'h00);
            set_sprite(6'd0, 8'd224, 8'd0, 8'h00, 8'd32);
            probe(9'd224, 9'd32);
            expect_all("8x16 Y=224 row 0", 4'h1, 4'h0, 1'b0, 1'b0);
            probe(9'd232, 9'd32);
            expect_all("8x16 Y=224 lower tile", 4'h1, 4'h0, 1'b0, 1'b0);
            probe(9'd239, 9'd32);
            expect_all("8x16 Y=224 last visible row", 4'h1, 4'h0, 1'b0, 1'b0);
            probe(9'd240, 9'd32);
            expect_all("8x16 Y=224 is clipped by vblank", 4'h0, 4'h0, 1'b0, 1'b0);
            set_sprite(6'd0, 8'd240, 8'd0, 8'h00, 8'd32);
            probe(9'd239, 9'd32);
            expect_all("8x16 Y=240 starts below the visible area", 4'h0, 4'h0, 1'b0, 1'b0);
            $display("SPRITE OAM entry 63, Y wrap boundaries and 8x16 bottom edge PASS");
        end
    endtask

    task test_mask_ctrl_and_bg_isolation;
        begin
            clear_scene;
            fill_tile(13'd0, 8'd0, 8'hFF, 8'h00);
            set_sprite(6'd0, 8'd32, 8'd0, 8'h00, 8'd32);
            set_sprite(6'd1, 8'd40, 8'd0, 8'h20, 8'd32);
            ctrl_probe[0] = 8'h00;
            ctrl_probe[1] = 8'h01;
            ctrl_probe[2] = 8'h02;
            ctrl_probe[3] = 8'h04;
            ctrl_probe[4] = 8'h10;
            ctrl_probe[5] = 8'h40;
            ctrl_probe[6] = 8'h80;
            ctrl_probe[7] = 8'h81;
            ctrl_probe[8] = 8'hC6;
            ctrl_probe[9] = 8'h92;
            for (probe_i = 0; probe_i < 10; probe_i = probe_i + 1) begin
                ctrl = ctrl_probe[probe_i];
                probe(9'd32, 9'd32);
                expect_all("irrelevant PPUCTRL bit", 4'h1, 4'h0, 1'b0, 1'b0);
                probe(9'd40, 9'd32);
                expect_all("irrelevant PPUCTRL bit with priority", 4'h1, 4'hF, 1'b0, 1'b0);
            end
            ctrl = 8'h00;
            mask_probe[0] = 8'h00;
            mask_probe[1] = 8'h04;
            mask_probe[2] = 8'h08;
            mask_probe[3] = 8'h0C;
            mask_probe[4] = 8'h10;
            mask_probe[5] = 8'h14;
            mask_probe[6] = 8'h18;
            mask_probe[7] = 8'h1C;
            mask_probe[8] = 8'h1F;
            mask_probe[9] = 8'hFF;
            for (probe_i = 0; probe_i < 10; probe_i = probe_i + 1) begin
                mask = mask_probe[probe_i];
                probe(9'd32, 9'd32);
                expect_all("PPUMASK does not gate sprites", 4'h1, 4'h0, 1'b0, 1'b0);
            end
            mask = 8'h1C;
            bg_probe[0] = 4'h0;
            bg_probe[1] = 4'h1;
            bg_probe[2] = 4'h7;
            bg_probe[3] = 4'hF;
            for (probe_i = 0; probe_i < 4; probe_i = probe_i + 1) begin
                bg_pixel = bg_probe[probe_i];
                probe(9'd32, 9'd32);
                if (bg_probe[probe_i] == 4'h0)
                    expect_all("bg 0 gives no hit", 4'h1, 4'h0, 1'b0, 1'b0);
                else
                    expect_all("bg nonzero gives a hit", 4'h1, 4'h0, 1'b1, 1'b0);
            end
            $display("SPRITE PPUCTRL/PPUMASK/bg_pixel isolation PASS");
        end
    endtask

    task expect_cur_slot;
        input [8*96-1:0] name;
        input [3:0] expected;
        begin
            if (cur_slot !== expected)
                $fatal(1, "%0s: cur_slot_o got %0d expected %0d at %0d:%0d",
                       name, cur_slot, expected, scanline, dot);
        end
    endtask

    task expect_cur_slot_derived;
        input [8*96-1:0] name;
        begin
            cs_exp = 4'h8;
            if (!reset && (scanline < 9'd240) && (dot < 9'd256)) begin
                for (cs_i = 0; cs_i < 8; cs_i = cs_i + 1) begin
                    cs_pick = cs_i[2:0];
                    cs_xoff = {2'b00, dot[7:0]} - {2'b00, dut.slot_x[cs_pick]};
                    if ((cs_exp == 4'h8) && (cs_pick < {1'b0, dut.range_count})
                        && (cs_xoff[9:3] == 8'd0))
                        cs_exp = {1'b0, cs_pick};
                end
            end
            if (cur_slot !== cs_exp)
                $fatal(1, "%0s: cur_slot_o got %0d expected %0d at %0d:%0d",
                       name, cur_slot, cs_exp, scanline, dot);
        end
    endtask

    task expect_cur_slot_opaque_source;
        input [8*96-1:0] name;
        begin
            cs_found = 4'h8;
            cs_only = 4'h8;
            cs_cover = 4'h0;
            for (cs_i = 0; cs_i < 8; cs_i = cs_i + 1) begin
                cs_pick = cs_i[2:0];
                cs_xoff = {2'b00, dot[7:0]} - {2'b00, dut.slot_x[cs_pick]};
                if ((cs_pick < {1'b0, dut.range_count}) && (cs_xoff[9:3] == 8'd0)) begin
                    cs_cover = cs_cover + 4'd1;
                    cs_only = {1'b0, cs_pick};
                    if (dut.slot_opaque[cs_pick] === 1'b1 && (cs_found == 4'h8))
                        cs_found = {1'b0, cs_pick};
                end
            end
            if (cs_cover === 4'h0) begin
                if (cur_slot !== 4'h8)
                    $fatal(1, "%0s: cur_slot_o got %0d but no slot covers the dot at %0d:%0d",
                           name, cur_slot, scanline, dot);
            end else begin
                if (cur_slot === 4'h8)
                    $fatal(1, "%0s: cur_slot_o is the none sentinel but %0d slots cover the dot at %0d:%0d",
                           name, cs_cover, scanline, dot);
                if (cur_slot >= 4'h8)
                    $fatal(1, "%0s: cur_slot_o got %0d, only 0..7 are real slots at %0d:%0d",
                           name, cur_slot, scanline, dot);
                if (cur_slot >= {1'b0, dut.range_count})
                    $fatal(1, "%0s: cur_slot_o got %0d but range_count is %0d at %0d:%0d",
                           name, cur_slot, dut.range_count, scanline, dot);
                cs_xoff = {2'b00, dot[7:0]} - {2'b00, dut.slot_x[cur_slot[2:0]]};
                if (cs_xoff[9:3] !== 8'd0)
                    $fatal(1, "%0s: cur_slot_o got %0d but its x window misses the dot at %0d:%0d",
                           name, cur_slot, scanline, dot);
                if ((cs_cover === 4'h1) && (cur_slot !== cs_only))
                    $fatal(1, "%0s: exactly one slot covers the dot but cur_slot_o got %0d and the covering slot is %0d at %0d:%0d",
                           name, cur_slot, cs_only, scanline, dot);
            end
            if (sprite_pixel[1:0] !== 2'b00) begin
                if (cs_found === 4'h8)
                    $fatal(1, "%0s: sprite_pixel %01h is opaque but no slot_opaque is set at %0d:%0d",
                           name, sprite_pixel, scanline, dot);
                if (cur_slot === 4'h8)
                    $fatal(1, "%0s: sprite_pixel %01h is opaque but cur_slot_o is the none sentinel at %0d:%0d",
                           name, sprite_pixel, scanline, dot);
                if (cur_slot > cs_found)
                    $fatal(1, "%0s: cur_slot_o got %0d above the opaque source slot %0d at %0d:%0d",
                           name, cur_slot, cs_found, scanline, dot);
                if (cur_slot === cs_found) begin
                    cs_opaque_src = {1'b0, cur_slot[2:0]};
                    if (dut.slot_opaque[cs_opaque_src[2:0]] !== 1'b1)
                        $fatal(1, "%0s: cur_slot_o names the opaque source slot %0d but slot_opaque is low at %0d:%0d",
                               name, cs_opaque_src, scanline, dot);
                    if (sprite_pixel
                        !== {dut.slot_attr[cs_opaque_src[2:0]][1:0],
                             dut.slot_pat[cs_opaque_src[2:0]][1:0]})
                        $fatal(1, "%0s: sprite_pixel %01h is not the slot %0d pattern/attr at %0d:%0d",
                               name, sprite_pixel, cs_opaque_src, scanline, dot);
                end
            end
        end
    endtask

    task test_cur_slot_gating;
        begin
            clear_scene;
            fill_tile(13'd0, 8'd0, 8'hFF, 8'hFF);
            set_sprite(6'd0, 8'd32, 8'd0, 8'h00, 8'd32);
            set_sprite(6'd1, 8'd32, 8'd0, 8'h00, 8'd40);
            probe(9'd32, 9'd32);
            expect_cur_slot("visible dot names slot 0", 4'd0);
            expect_cur_slot_derived("visible dot derived");
            probe(9'd32, 9'd39);
            expect_cur_slot("last column still names slot 0", 4'd0);
            probe(9'd32, 9'd40);
            expect_cur_slot("second sprite window names slot 1", 4'd1);
            probe(9'd32, 9'd255);
            expect_cur_slot_derived("dot 255 derived");
            probe(9'd32, 9'd256);
            expect_cur_slot("dot 256 is the none sentinel", 4'h8);
            probe(9'd32, 9'd257);
            expect_cur_slot("dot 257 is the none sentinel", 4'h8);
            probe(9'd32, 9'd340);
            expect_cur_slot("dot 340 is the none sentinel", 4'h8);
            probe(9'd32, 9'd511);
            expect_cur_slot("dot 511 is the none sentinel", 4'h8);
            probe(9'd239, 9'd32);
            expect_cur_slot_derived("last visible scanline derived");
            probe(9'd240, 9'd32);
            expect_cur_slot("vblank scanline 240 is the none sentinel", 4'h8);
            probe(9'd241, 9'd32);
            expect_cur_slot("vblank scanline 241 is the none sentinel", 4'h8);
            probe(9'd255, 9'd32);
            expect_cur_slot("vblank scanline 255 is the none sentinel", 4'h8);
            probe(9'd261, 9'd32);
            expect_cur_slot("pre-render scanline 261 is the none sentinel", 4'h8);
            probe(9'd511, 9'd32);
            expect_cur_slot("scanline 511 is the none sentinel", 4'h8);
            probe(9'd32, 9'd32);
            expect_cur_slot("reset released names slot 0", 4'd0);
            reset = 1'b1;
            probe(9'd32, 9'd32);
            expect_cur_slot("reset high is the none sentinel", 4'h8);
            probe(9'd32, 9'd32);
            expect_cur_slot("reset high stays the none sentinel", 4'h8);
            reset = 1'b0;
            probe(9'd32, 9'd32);
            expect_cur_slot("reset release restores slot 0", 4'd0);
            mask = 8'h18;
            probe(9'd32, 9'd32);
            expect_cur_slot("left-8 clip does not gate the positional slot", 4'd0);
            expect_cur_slot_derived("left-8 clip derived");
            mask = 8'h1C;
            $display("SPRITE cur_slot_o dot>=256, vblank and reset gating PASS");
        end
    endtask

    task test_cur_slot_priority_encode;
        begin
            clear_scene;
            for (probe_i = 0; probe_i < 8; probe_i = probe_i + 1) begin
                fill_tile(13'd0, probe_i[7:0] + 8'd1, 8'h80, 8'h00);
                set_sprite(probe_i[5:0], 8'd32, probe_i[7:0] + 8'd1, 8'h00,
                           8'd16 * probe_i[7:0]);
            end
            probe(9'd32, 9'd16);
            expect_cur_slot("encode slot 1 first column", 4'd1);
            expect_cur_slot_opaque_source("encode slot 1 first column source");
            probe(9'd32, 9'd23);
            expect_cur_slot("encode slot 1 last column", 4'd1);
            expect_cur_slot_opaque_source("encode slot 1 last column source");
            probe(9'd32, 9'd24);
            expect_cur_slot("gap before slot 2 is the none sentinel", 4'h8);
            probe(9'd32, 9'd31);
            expect_cur_slot("gap before slot 2 stays the none sentinel", 4'h8);
            probe(9'd32, 9'd32);
            expect_cur_slot("encode slot 2 first column", 4'd2);
            probe(9'd32, 9'd48);
            expect_cur_slot("encode slot 3 first column", 4'd3);
            probe(9'd32, 9'd64);
            expect_cur_slot("encode slot 4 first column", 4'd4);
            probe(9'd32, 9'd80);
            expect_cur_slot("encode slot 5 first column", 4'd5);
            probe(9'd32, 9'd96);
            expect_cur_slot("encode slot 6 first column", 4'd6);
            probe(9'd32, 9'd112);
            expect_cur_slot("encode slot 7 first column", 4'd7);
            expect_cur_slot_opaque_source("encode slot 7 first column source");
            probe(9'd32, 9'd119);
            expect_cur_slot("encode slot 7 last column", 4'd7);
            probe(9'd32, 9'd120);
            expect_cur_slot("gap after slot 7 is the none sentinel", 4'h8);
            probe(9'd32, 9'd16);
            expect_cur_slot_derived("eight in range derived");
            set_sprite(6'd7, 8'd32, 8'd1, 8'h00, 8'd112);
            set_sprite(6'd8, 8'd32, 8'd1, 8'h00, 8'd128);
            probe(9'd32, 9'd112);
            expect_cur_slot("ninth in range keeps slot 7 at x=112", 4'd7);
            probe(9'd32, 9'd128);
            expect_cur_slot("ninth in range sprite is dropped", 4'h8);
            expect_cur_slot_derived("nine in range derived");
            probe(9'd32, 9'd16);
            expect_cur_slot_opaque_source("nine in range slot 1 source");
            probe(9'd32, 9'd32);
            expect_cur_slot_opaque_source("nine in range slot 2 source");
            $display("SPRITE cur_slot_o lowest-covering-slot encode over 8 slots PASS");
        end
    endtask

    task test_cur_slot_opaque_source;
        begin
            clear_scene;
            fill_tile(13'd0, 8'd1, 8'hFF, 8'h00);
            fill_tile(13'd0, 8'd2, 8'h80, 8'h00);
            set_sprite(6'd0, 8'd32, 8'd1, 8'h01, 8'd32);
            set_sprite(6'd1, 8'd32, 8'd2, 8'h02, 8'd32);
            probe(9'd32, 9'd32);
            expect_all("single covering slot 0 is the opaque source", 4'h5, 4'h0, 1'b0, 1'b0);
            expect_cur_slot("single covering slot names slot 0", 4'd0);
            expect_cur_slot_opaque_source("single covering slot is the opaque source");
            probe(9'd32, 9'd39);
            expect_all("single covering slot 0 last column", 4'h5, 4'h0, 1'b0, 1'b0);
            expect_cur_slot_opaque_source("single covering slot last column source");
            set_sprite(6'd0, 8'd32, 8'd2, 8'h01, 8'd32);
            set_sprite(6'd1, 8'd32, 8'd1, 8'h02, 8'd32);
            probe(9'd32, 9'd33);
            expect_all("slot 0 transparent at xoffset 1, slot 1 supplies", 4'h9, 4'h0, 1'b0, 1'b0);
            expect_cur_slot("overlapping pair names the lower slot 0", 4'd0);
            expect_cur_slot_opaque_source("opaque source is at or above cur_slot_o");
            set_sprite(6'd1, 8'd32, 8'd2, 8'h02, 8'd32);
            probe(9'd32, 9'd33);
            expect_all("transparent covering slot has no opaque source", 4'h0, 4'h0, 1'b0, 1'b0);
            expect_cur_slot("transparent covering slot is still named", 4'd0);
            expect_cur_slot_opaque_source("transparent covering slot has no opaque source");
            set_sprite(6'd1, 8'd32, 8'd1, 8'h00, 8'd32);
            probe(9'd32, 9'd33);
            expect_all("slot 1 supplies the opaque pixel", 4'h1, 4'h0, 1'b0, 1'b0);
            expect_cur_slot("overlapping pair names the lower slot 0", 4'd0);
            expect_cur_slot_opaque_source("opaque source is at or above cur_slot_o");
            set_sprite(6'd0, 8'd32, 8'd1, 8'h00, 8'd24);
            probe(9'd32, 9'd33);
            expect_all("slot 0 no longer covers the dot", 4'h1, 4'h0, 1'b0, 1'b0);
            expect_cur_slot("sole covering slot moves to slot 1", 4'd1);
            expect_cur_slot_opaque_source("sole covering slot 1 is the opaque source");
            $display("SPRITE cur_slot_o agrees with the slot_opaque/sprite_pixel source PASS");
        end
    endtask

    initial begin
        clk = 1'b0;
        reset = 1'b1;
        ce = 1'b0;
        ctrl = 8'h00;
        mask = 8'h00;
        scanline = 9'd0;
        dot = 9'd0;
        bg_pixel = 4'h0;
        oam_bus = {2048{1'b0}};
        chr_bus = {65536{1'b0}};
        scan_row = 0;
        probe_i = 0;
        #1;
        test_reset_and_clock_independence;
        test_8x8;
        test_pattern_table;
        test_8x16;
        test_8x8_tile_range;
        test_8x16_tile_pair_range;
        test_flips;
        test_palette_and_priority;
        test_left8_clip;
        test_eight_sprite_limit;
        test_sprite0_hit;
        test_dot_vblank_and_reset_masking;
        test_oam_boundaries;
        test_mask_ctrl_and_bg_isolation;
        test_cur_slot_gating;
        test_cur_slot_priority_encode;
        test_cur_slot_opaque_source;
        $display("PASS nes_ppu_sprite");
        $finish;
    end

    initial begin
        #200000;
        $fatal(1, "global timeout");
    end


endmodule
