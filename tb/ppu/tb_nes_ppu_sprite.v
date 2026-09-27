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

    reg [2047:0]  oam_bus;
    reg [65535:0] chr_bus;

    reg [7:0] ctrl_probe [0:9];
    reg [7:0] mask_probe [0:9];
    reg [3:0] bg_probe  [0:3];

    integer scan_row;
    integer probe_i;

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
        .sprite_overflow(sprite_overflow)
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
            fill_tile(13'd4096, 8'd2, 8'h40, 8'h00);
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
            expect_all("8x16 tile 3 top half lit", 4'h1, 4'h0, 1'b0, 1'b0);
            probe(9'd80, 9'd105);
            expect_all("8x16 tile 3 bottom half lit", 4'h1, 4'h0, 1'b0, 1'b0);
            probe(9'd88, 9'd104);
            expect_all("8x16 past 16 pixel height", 4'h0, 4'h0, 1'b0, 1'b0);
            $display("SPRITE 8x16 tile pair, table from tile bit0, PPUCTRL[3] ignored PASS");
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
        test_flips;
        test_palette_and_priority;
        test_left8_clip;
        test_eight_sprite_limit;
        test_sprite0_hit;
        test_dot_vblank_and_reset_masking;
        test_oam_boundaries;
        test_mask_ctrl_and_bg_isolation;
        $display("PASS nes_ppu_sprite");
        $finish;
    end

    initial begin
        #200000;
        $fatal(1, "global timeout");
    end


endmodule
