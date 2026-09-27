`timescale 1ns/1ps

module tb_chr_fetch_feasibility;

localparam integer LINES = 262;
localparam integer DOTS  = 341;

reg clk;
reg reset;
reg ce;
reg reg_cs;
reg reg_we;
reg [2:0] reg_addr;
reg [7:0] reg_din;

wire [7:0] reg_dout;
wire pixel_valid;
wire [7:0] pixel_x;
wire [7:0] pixel_y;
wire [3:0] pixel_index;
wire frame_done;
wire vblank;
wire nmi_o;
wire [8:0] dot;
wire [8:0] scanline;
wire [14:0] dbg_v;
wire [14:0] dbg_t;
wire [2:0] dbg_x;
wire dbg_w;
wire dbg_sprite0_hit;
wire dbg_sprite_overflow;
wire chr_req;
wire [13:0] chr_addr;
wire chr_we;
wire [7:0] chr_wdata;
wire [7:0] chr_rdata;

nes_ppu2c02 #(
    .MIRROR_VERTICAL(1'b0),
    .EXTERNAL_CHR(1'b0)
) dut(
    .clk(clk),
    .reset(reset),
    .ce(ce),
    .reg_cs(reg_cs),
    .reg_we(reg_we),
    .reg_addr(reg_addr),
    .reg_din(reg_din),
    .reg_dout(reg_dout),
    .pixel_valid(pixel_valid),
    .pixel_x(pixel_x),
    .pixel_y(pixel_y),
    .pixel_index(pixel_index),
    .frame_done(frame_done),
    .vblank(vblank),
    .nmi_o(nmi_o),
    .dot(dot),
    .scanline(scanline),
    .dbg_v(dbg_v),
    .dbg_t(dbg_t),
    .dbg_x(dbg_x),
    .dbg_w(dbg_w),
    .dbg_sprite0_hit(dbg_sprite0_hit),
    .dbg_sprite_overflow(dbg_sprite_overflow),
    .chr_req(chr_req),
    .chr_addr(chr_addr),
    .chr_we(chr_we),
    .chr_wdata(chr_wdata),
    .chr_rdata(chr_rdata)
);

assign chr_rdata = 8'h00;

always #5 clk = !clk;

integer cfg_fine_x;
integer cfg_coarse_x;
integer cfg_coarse_y;
integer cfg_nt;
integer cfg_spr16;
integer cfg_mask;
integer win_lo;

integer line_vis_bound    [0:LINES-1];
integer line_emit_opp     [0:LINES-1];
integer line_full_bound   [0:LINES-1];
integer line_bgshown      [0:LINES-1];
integer line_render       [0:LINES-1];
integer line_pix          [0:LINES-1];
integer line_hb           [0:LINES-1];
integer line_win          [0:LINES-1];
integer line_range        [0:LINES-1];
integer line_bgcy         [0:LINES-1];
integer line_bgys         [0:LINES-1];
integer line_ovf          [0:LINES-1];
integer line_spix         [0:LINES-1];
integer line_xt340        [0:LINES-1];
integer line_rstart       [0:LINES-1];
integer line_rpartial     [0:LINES-1];
integer line_bn           [0:LINES-1];
integer line_bb           [0:LINES-1];
integer line_bq           [0:LINES-1];
integer line_bp           [0:LINES-1];
integer line_bc           [0:LINES-1];
integer range_hist        [0:64];

integer tot_vis_bound;
integer tot_frames;
integer tot_need;
integer tot_budget;
integer tot_win;
integer tot_hb;
integer tot_sprite_fix;
integer tot_sprite_use;
integer tot_win_vis;
integer tot_hb_vis;
integer tot_slots_vis;
integer tot_ovf_lines;
integer tot_xt340_bad;
integer tot_bn;
integer tot_bb;
integer tot_bq;
integer tot_bp;
integer tot_bc;
integer tot_render_cols;
integer min_gap_seen;
integer max_gap_seen;
integer max_tiles_seen;
integer min_tiles_seen;

reg [31:0] seen_cxc;
reg [31:0] bad_cxc;

reg [7:0] m0_name;
reg [7:0] m0_ab;
reg [1:0] m0_attr;
reg [1:0] m0_pat;
reg [4:0] m0_pal;
reg [7:0] m0_col;
reg [7:0] m1_name;
reg [7:0] m1_ab;
reg [1:0] m1_attr;
reg [1:0] m1_pat;
reg [4:0] m1_pal;
reg [7:0] m1_col;

integer li;
integer di;
reg [8:0] xt;
reg shown_now;
reg pix_now;
reg render_now;
reg [6:0] range_now;

function [10:0] nt_mirror;
    input [11:0] address;
    reg [11:0] mapped;
    begin
        mapped = {1'b0, address[9:0]};
        mapped[10] = address[11];
        nt_mirror = mapped[10:0];
    end
endfunction

function [7:0] pal_map5;
    input [4:0] a;
    begin
        case (a)
            5'h10: pal_map5 = 8'h00;
            5'h14: pal_map5 = 8'h04;
            5'h18: pal_map5 = 8'h08;
            5'h1C: pal_map5 = 8'h0C;
            default: pal_map5 = {3'b000, a};
        endcase
    end
endfunction

function integer popcount32;
    input [31:0] v;
    integer b;
    begin
        popcount32 = 0;
        for (b = 0; b < 32; b = b + 1)
            if (v[b])
                popcount32 = popcount32 + 1;
    end
endfunction

task bg_model;
    input [3:0] sh;
    output [7:0] o_name;
    output [7:0] o_ab;
    output [1:0] o_attr;
    output [1:0] o_pat;
    output [4:0] o_pal;
    output [7:0] o_col;
    reg [8:0] xts;
    reg [5:0] cxs;
    reg [4:0] cxc;
    reg [4:0] cyc;
    reg ntx;
    reg nty;
    reg [11:0] off;
    reg [12:0] pa;
    reg [7:0] lo_b;
    reg [7:0] hi_b;
    reg [2:0] bsel;
    reg [1:0] pi;
    reg [4:0] pil;
    reg [7:0] pb;
    reg [10:0] mi;
    begin
        xts = dut.bg_x_total + {5'b0, sh};
        cxs = {1'b0, dut.temp_addr[4:0]} + {1'b0, xts[8:3]};
        cxc = cxs[4:0];
        cyc = dut.bg_coarse_y;
        ntx = dut.temp_addr[10] ^ cxs[5];
        nty = dut.temp_addr[11] ^ dut.bg_vertical_sections[0];
        off = {nty, ntx, cyc, cxc};
        mi  = nt_mirror(off);
        o_name = dut.nametable_ram[mi];
        off = {nty, ntx, 4'b1111, cyc[4:2], cxc[4:2]};
        mi  = nt_mirror(off);
        o_ab  = dut.nametable_ram[mi];
        o_attr = o_ab[{cyc[1], cxc[1], 1'b0} +: 2];
        pa  = {dut.control_reg[4], o_name, 4'b0000} + {10'b0000000000, dut.bg_y_total[2:0]};
        lo_b = dut.chr_ram[pa];
        hi_b = dut.chr_ram[pa + 13'd8];
        bsel = 3'd7 - xts[2:0];
        pi   = {hi_b[bsel], lo_b[bsel]};
        o_pat = pi;
        if (pi == 2'b00)
            pil = 5'd0;
        else
            pil = {o_attr, pi};
        o_pal = pil;
        pb = pal_map5(pil);
        o_col = dut.palette_ram[pb[4:0]];
    end
endtask

task apply_reset;
    begin
        ce = 1'b0;
        reg_cs = 1'b0;
        reg_we = 1'b0;
        reg_addr = 3'd0;
        reg_din = 8'h00;
        reset = 1'b1;
        repeat (2) @(posedge clk);
        #1 reset = 1'b0;
    end
endtask

task tick_dot;
    begin
        ce = 1'b1;
        @(posedge clk);
        #1 ce = 1'b0;
    end
endtask

task write_register;
    input [2:0] address;
    input [7:0] data;
    begin
        reg_cs = 1'b1;
        reg_we = 1'b1;
        reg_addr = address;
        reg_din = data;
        @(posedge clk);
        #1;
        reg_cs = 1'b0;
        reg_we = 1'b0;
        reg_addr = 3'd0;
        reg_din = 8'h00;
    end
endtask

task set_config;
    begin
        write_register(3'd0, {2'b00, cfg_spr16[0], 3'b000, cfg_nt[1:0]});
        write_register(3'd1, cfg_mask[7:0]);
        write_register(3'd5, {cfg_coarse_x[4:0], cfg_fine_x[2:0]});
        write_register(3'd5, {cfg_coarse_y[4:0], 3'b000});
        if ((dut.fine_x !== cfg_fine_x[2:0]) || (dut.temp_addr[4:0] !== cfg_coarse_x[4:0]))
            $fatal(1, "scroll config did not reach temp: x=%0d t=%04h", dut.fine_x, dut.temp_addr);
        if (dut.temp_addr[9:5] !== cfg_coarse_y[4:0])
            $fatal(1, "coarse_y config did not reach temp: t=%04h", dut.temp_addr);
        if (dut.temp_addr[11:10] !== cfg_nt[1:0])
            $fatal(1, "nametable base did not reach temp: t=%04h", dut.temp_addr);
        if (dut.mask_reg !== cfg_mask[7:0])
            $fatal(1, "mask config did not reach mask_reg: %02h", dut.mask_reg);
        if (dut.control_reg !== {2'b00, cfg_spr16[0], 3'b000, cfg_nt[1:0]})
            $fatal(1, "control config did not reach control_reg: %02h", dut.control_reg);
        if (dut.g_chr_internal.u_sprite.sprite_height !== ((cfg_spr16 != 0) ? 9'd16 : 9'd8))
            $fatal(1, "sprite height did not follow PPUCTRL[5]: %0d", dut.g_chr_internal.u_sprite.sprite_height);
    end
endtask

task set_sprite;
    input integer idx;
    input [7:0] yv;
    input [7:0] tilev;
    input [7:0] attrv;
    input [7:0] xv;
    begin
        dut.oam_ram[idx*4 + 0] = yv;
        dut.oam_ram[idx*4 + 1] = tilev;
        dut.oam_ram[idx*4 + 2] = attrv;
        dut.oam_ram[idx*4 + 3] = xv;
    end
endtask

task load_oam;
    integer k;
    begin
        for (k = 0; k < 64; k = k + 1)
            set_sprite(k, 8'hF8, 8'h00, 8'h00, 8'd0);
        for (k = 0; k < 9; k = k + 1)
            set_sprite(k, 8'd0, 8'h01, 8'h00, k[7:0] * 8'd8);
        for (k = 0; k < 7; k = k + 1)
            set_sprite(9 + k, 8'd20, 8'h01, 8'h00, (k[7:0] * 8'd8) + 8'd4);
        for (k = 0; k < 4; k = k + 1)
            set_sprite(16 + k, 8'd60, 8'h01, 8'h00, (k[7:0] * 8'd8) + 8'd2);
        for (k = 0; k < 3; k = k + 1)
            set_sprite(20 + k, 8'd100, 8'h01, 8'h00, (k[7:0] * 8'd8) + 8'd6);
    end
endtask

task load_memory;
    integer k;
    integer row;
    integer col;
    reg [7:0] tv;
    begin
        for (k = 0; k < 2048; k = k + 1)
            dut.nametable_ram[k] = 8'h00;
        for (row = 0; row < 30; row = row + 1) begin
            for (col = 0; col < 32; col = col + 1) begin
                tv = ((row * 7) + (col * 3)) & 8'hFF;
                dut.nametable_ram[row*32 + col] = tv;
            end
        end
        for (k = 0; k < 64; k = k + 1) begin
            if (k[0] == 1'b0) begin
                dut.nametable_ram[12'h3C0 + k] = 8'h1B;
                dut.nametable_ram[12'h7C0 + k] = 8'h1B;
            end else begin
                dut.nametable_ram[12'h3C0 + k] = 8'hE4;
                dut.nametable_ram[12'h7C0 + k] = 8'hE4;
            end
        end
        for (k = 0; k < 8192; k = k + 1)
            dut.chr_ram[k] = ~k[7:0];
        for (k = 0; k < 32; k = k + 1)
            dut.palette_ram[k] = 8'h10 + k[7:0];
    end
endtask

task reset_counters;
    begin
        tot_vis_bound = 0;
        tot_frames = 0;
        tot_need = 0;
        tot_budget = 0;
        tot_win = 0;
        tot_hb = 0;
        tot_sprite_fix = 0;
        tot_sprite_use = 0;
        tot_win_vis = 0;
        tot_hb_vis = 0;
        tot_slots_vis = 0;
        tot_ovf_lines = 0;
        tot_xt340_bad = 0;
        tot_bn = 0;
        tot_bb = 0;
        tot_bq = 0;
        tot_bp = 0;
        tot_bc = 0;
        tot_render_cols = 0;
        min_gap_seen = 1000;
        max_gap_seen = 0;
        max_tiles_seen = 0;
        min_tiles_seen = 1000;
        seen_cxc = 32'd0;
        bad_cxc = 32'd0;
    end
endtask

task run_frame;
    input [8*64-1:0] tag;
    integer slots_now;
    integer tiles_now;
    integer exp_bgshown;
    integer exp_render;
    integer gap_now;
    integer prev_boundary;
    begin
        win_lo = dut.mask_reg[1] ? 0 : 8;
        exp_bgshown = dut.mask_reg[1] ? 341 : 333;
        exp_render = dut.mask_reg[1] ? 256 : 248;
        for (li = 0; li < LINES; li = li + 1) begin
            line_vis_bound[li] = 0;
            line_emit_opp[li] = 0;
            line_full_bound[li] = 0;
            line_bgshown[li] = 0;
            line_render[li] = 0;
            line_pix[li] = 0;
            line_hb[li] = 0;
            line_win[li] = 0;
            line_range[li] = 0;
            line_bgcy[li] = 0;
            line_bgys[li] = 0;
            line_ovf[li] = 0;
            line_spix[li] = 0;
            line_xt340[li] = 0;
            line_rstart[li] = 0;
            line_rpartial[li] = 0;
            line_bn[li] = 0;
            line_bb[li] = 0;
            line_bq[li] = 0;
            line_bp[li] = 0;
            line_bc[li] = 0;
        end
        for (li = 0; li <= 64; li = li + 1)
            range_hist[li] = 0;
        for (li = 0; li < LINES; li = li + 1) begin
            prev_boundary = -1;
            gap_now = 0;
            for (di = 0; di < DOTS; di = di + 1) begin
                if ((scanline !== li[8:0]) || (dot !== di[8:0]))
                    $fatal(1, "%0s counter mismatch got %0d:%0d expected %0d:%0d",
                           tag, scanline, dot, li, di);
                xt = dut.bg_x_total;
                shown_now = dut.bg_shown;
                pix_now = dut.g_chr_internal.u_sprite.pixel_active;
                render_now = (li < 240) && (di < 256) && shown_now;
                range_now = dut.g_chr_internal.u_sprite.range_count;

                if (xt[2:0] == 3'd7) begin
                    line_full_bound[li] = line_full_bound[li] + 1;
                    if (di < 256)
                        line_vis_bound[li] = line_vis_bound[li] + 1;
                    if (prev_boundary >= 0) begin
                        gap_now = di - prev_boundary;
                        if (gap_now < min_gap_seen)
                            min_gap_seen = gap_now;
                        if (gap_now > max_gap_seen)
                            max_gap_seen = gap_now;
                    end
                    prev_boundary = di;
                end
                if (xt[2:0] == 3'd6)
                    line_emit_opp[li] = line_emit_opp[li] + 1;
                if ((render_now) && (xt[2:0] == 3'd0))
                    line_rstart[li] = line_rstart[li] + 1;
                if (render_now && (di == win_lo) && (xt[2:0] != 3'd0))
                    line_rpartial[li] = 1;

                if (di >= 256)
                    line_hb[li] = line_hb[li] + 1;
                if ((di >= 257) && (di <= 272))
                    line_win[li] = line_win[li] + 1;
                if (shown_now)
                    line_bgshown[li] = line_bgshown[li] + 1;
                if (render_now)
                    line_render[li] = line_render[li] + 1;
                if (pix_now)
                    line_pix[li] = line_pix[li] + 1;
                if (dut.g_chr_internal.u_sprite.sprite_pixel[1:0] !== 2'b00)
                    line_spix[li] = line_spix[li] + 1;
                if (dut.g_chr_internal.u_sprite.sprite_overflow)
                    line_ovf[li] = line_ovf[li] + 1;

                if (di == 0) begin
                    line_range[li] = range_now;
                    line_bgcy[li] = dut.bg_coarse_y;
                    line_bgys[li] = dut.bg_y_total;
                end else begin
                    if (range_now !== line_range[li]) begin
                        $fatal(1, "%0s range_count changed inside line %0d: %0d -> %0d",
                               tag, li, line_range[li], range_now);
                    end
                    if (dut.bg_coarse_y !== line_bgcy[li][4:0]) begin
                        $fatal(1, "%0s bg_coarse_y changed inside line %0d: %0d -> %0d",
                               tag, li, line_bgcy[li], dut.bg_coarse_y);
                    end
                    if (dut.bg_y_total !== line_bgys[li][8:0]) begin
                        $fatal(1, "%0s bg_y_total changed inside line %0d: %0d -> %0d",
                               tag, li, line_bgys[li], dut.bg_y_total);
                    end
                end

                if (di == DOTS-1)
                    line_xt340[li] = xt;

                if (di < 256) begin
                    bg_model(4'd0, m0_name, m0_ab, m0_attr, m0_pat, m0_pal, m0_col);
                    if (m0_col !== dut.bg_palette_value)
                        $fatal(1, "%0s model selftest color mismatch at %0d:%0d got %02h expected %02h",
                               tag, li, di, m0_col, dut.bg_palette_value);
                    if (m0_pal !== dut.bg_palette_index)
                        $fatal(1, "%0s model selftest palette index mismatch at %0d:%0d", tag, li, di);
                    if (m0_attr !== dut.bg_attribute)
                        $fatal(1, "%0s model selftest attribute mismatch at %0d:%0d", tag, li, di);
                    if (render_now) begin
                        bg_model(4'd1, m1_name, m1_ab, m1_attr, m1_pat, m1_pal, m1_col);
                        seen_cxc = seen_cxc | (32'd1 << dut.bg_coarse_x[4:0]);
                        if (m1_name !== dut.bg_name)
                            line_bn[li] = line_bn[li] + 1;
                        if (m1_ab !== dut.bg_attribute_byte)
                            line_bb[li] = line_bb[li] + 1;
                        if (m1_attr !== dut.bg_attribute) begin
                            line_bq[li] = line_bq[li] + 1;
                            bad_cxc = bad_cxc | (32'd1 << dut.bg_coarse_x[4:0]);
                        end
                        if (m1_pal !== dut.bg_palette_index)
                            line_bp[li] = line_bp[li] + 1;
                        if (m1_col !== dut.bg_palette_value)
                            line_bc[li] = line_bc[li] + 1;
                    end
                end

                tick_dot;
            end
        end
        if ((scanline !== 9'd0) || (dot !== 9'd0))
            $fatal(1, "%0s frame did not wrap to 0:0, at %0d:%0d", tag, scanline, dot);

        for (li = 0; li < LINES; li = li + 1) begin
            if (line_vis_bound[li] !== 32)
                $fatal(1, "%0s visible tile boundaries on line %0d got %0d expected 32",
                       tag, li, line_vis_bound[li]);
            if ((line_full_bound[li] < 42) || (line_full_bound[li] > 43))
                $fatal(1, "%0s full line tile boundaries on line %0d got %0d expected 42 or 43",
                       tag, li, line_full_bound[li]);
            if ((line_emit_opp[li] - line_full_bound[li] > 1) ||
                (line_full_bound[li] - line_emit_opp[li] > 1))
                $fatal(1, "%0s emission opportunity count mismatch on line %0d: %0d vs %0d",
                       tag, li, line_emit_opp[li], line_full_bound[li]);
            if (line_hb[li] !== 85)
                $fatal(1, "%0s hblank dots on line %0d got %0d expected 85", tag, li, line_hb[li]);
            if (line_win[li] !== 16)
                $fatal(1, "%0s prefetch window dots on line %0d got %0d expected 16",
                       tag, li, line_win[li]);
            if (line_bgshown[li] !== exp_bgshown)
                $fatal(1, "%0s bg_shown dots on line %0d got %0d expected %0d",
                       tag, li, line_bgshown[li], exp_bgshown);
            if (li < 240) begin
                if (line_pix[li] !== 256)
                    $fatal(1, "%0s pixel_active dots on line %0d got %0d expected 256",
                           tag, li, line_pix[li]);
                if (line_render[li] !== exp_render)
                    $fatal(1, "%0s rendered bg columns on line %0d got %0d expected %0d",
                           tag, li, line_render[li], exp_render);
            end else begin
                if (line_pix[li] !== 0)
                    $fatal(1, "%0s pixel_active dots on line %0d got %0d expected 0",
                           tag, li, line_pix[li]);
                if (line_render[li] !== 0)
                    $fatal(1, "%0s rendered bg columns on line %0d got %0d expected 0",
                           tag, li, line_render[li]);
            end
            if (line_xt340[li][8:3] !== cfg_coarse_x[4:0])
                tot_xt340_bad = tot_xt340_bad + 1;
            range_hist[line_range[li]] = range_hist[line_range[li]] + 1;
            if (line_ovf[li] > 0)
                tot_ovf_lines = tot_ovf_lines + 1;
            if (li < 240) begin
                tiles_now = line_rstart[li] + line_rpartial[li];
                if (tiles_now > max_tiles_seen)
                    max_tiles_seen = tiles_now;
                if (tiles_now < min_tiles_seen)
                    min_tiles_seen = tiles_now;
                tot_need = tot_need + tiles_now * 2 + 2;
                tot_budget = tot_budget + DOTS;
                tot_sprite_fix = tot_sprite_fix + 16;
                tot_win_vis = tot_win_vis + line_win[li];
                tot_hb_vis = tot_hb_vis + line_hb[li];
                slots_now = (line_range[li] > 8) ? 8 : line_range[li];
                tot_sprite_use = tot_sprite_use + slots_now * 2;
                tot_slots_vis = tot_slots_vis + slots_now;
                tot_render_cols = tot_render_cols + line_render[li];
            end
            tot_vis_bound = tot_vis_bound + line_vis_bound[li];
            tot_win = tot_win + line_win[li];
            tot_hb = tot_hb + line_hb[li];
            tot_bn = tot_bn + line_bn[li];
            tot_bb = tot_bb + line_bb[li];
            tot_bq = tot_bq + line_bq[li];
            tot_bp = tot_bp + line_bp[li];
            tot_bc = tot_bc + line_bc[li];
        end
        tot_frames = tot_frames + 1;
    end
endtask

task report;
    input [8*64-1:0] tag;
    integer fmin;
    integer fmax;
    integer fline_min;
    integer fline_max;
    integer rmin;
    integer rmax;
    integer nmin;
    integer nmax;
    integer spmin;
    integer spmax;
    integer x340min;
    integer x340max;
    integer t340min;
    integer t340max;
    integer bqmin;
    integer bqmax;
    integer bbmin;
    integer bbmax;
    integer bnmin;
    integer bnmax;
    integer bpmax;
    integer bcmax;
    integer pct;
    integer pct2;
    integer pct3;
    integer pct4;
    integer slots_x100;
    integer k;
    begin
        fmin = 1000; fmax = -1; fline_min = -1; fline_max = -1;
        rmin = 1000; rmax = -1;
        nmin = 1000; nmax = -1;
        spmin = 1000; spmax = -1;
        x340min = 100000; x340max = -1;
        t340min = 1000; t340max = -1;
        bqmin = 1000; bqmax = -1;
        bbmin = 1000; bbmax = -1;
        bnmin = 1000; bnmax = -1;
        bpmax = -1;
        bcmax = -1;
        for (k = 0; k < LINES; k = k + 1) begin
            if (line_full_bound[k] < fmin) begin fmin = line_full_bound[k]; fline_min = k; end
            if (line_full_bound[k] > fmax) begin fmax = line_full_bound[k]; fline_max = k; end
            if (line_spix[k] < spmin) spmin = line_spix[k];
            if (line_spix[k] > spmax) spmax = line_spix[k];
            if (line_xt340[k] < x340min) x340min = line_xt340[k];
            if (line_xt340[k] > x340max) x340max = line_xt340[k];
            if ((line_xt340[k] >> 3) < t340min) t340min = line_xt340[k] >> 3;
            if ((line_xt340[k] >> 3) > t340max) t340max = line_xt340[k] >> 3;
            if (line_bq[k] < bqmin) bqmin = line_bq[k];
            if (line_bq[k] > bqmax) bqmax = line_bq[k];
            if (line_bb[k] < bbmin) bbmin = line_bb[k];
            if (line_bb[k] > bbmax) bbmax = line_bb[k];
            if (line_bn[k] < bnmin) bnmin = line_bn[k];
            if (line_bn[k] > bnmax) bnmax = line_bn[k];
            if (line_bp[k] > bpmax) bpmax = line_bp[k];
            if (line_bc[k] > bcmax) bcmax = line_bc[k];
            if (k < 240) begin
                if (line_range[k] < rmin) rmin = line_range[k];
                if (line_range[k] > rmax) rmax = line_range[k];
            end else begin
                if (line_range[k] < nmin) nmin = line_range[k];
                if (line_range[k] > nmax) nmax = line_range[k];
            end
        end
        pct  = (tot_need * 10000) / tot_budget;
        pct2 = (tot_need * 10000) / tot_render_cols;
        pct3 = (tot_sprite_fix * 10000) / tot_hb_vis;
        pct4 = (tot_sprite_use * 100) / (240 * tot_frames);
        slots_x100 = (tot_slots_vis * 100) / (240 * tot_frames);
        $display("PASS-FRAME %0s frames=%0d fine_x=%0d coarse_x=%0d coarse_y=%0d nt_base=%0d ctrl=%02h mask=%02h spr_height=%0d",
                 tag, tot_frames, cfg_fine_x, cfg_coarse_x, cfg_coarse_y, cfg_nt,
                 dut.control_reg, dut.mask_reg, dut.g_chr_internal.u_sprite.sprite_height);
        $display("  Q1 tile_boundaries_per_line: visible_dot0_255=%0d  whole_line_min=%0d(line %0d) whole_line_max=%0d(line %0d)  emission_opportunities=%0d..%0d  min_gap_between_boundaries=%0d",
                 (tot_vis_bound / (LINES * tot_frames)), fmin, fline_min, fmax, fline_max,
                 fmin, fmax, min_gap_seen);
        $display("  Q1 bg_tiles_per_line min=%0d max=%0d  bg_bytes_per_line min=%0d max=%0d (incl 1 prefetch tile)  avg_bytes_per_line=%0d  occupancy_of_341dot=%0d.%02d%%  occupancy_of_rendered_column=%0d.%02d%%",
                 min_tiles_seen, max_tiles_seen, min_tiles_seen * 2 + 2, max_tiles_seen * 2 + 2,
                 tot_need / (240 * tot_frames), pct / 100, pct % 100, pct2 / 100, pct2 % 100);
        $display("  Q1 dot340_bg_x_total min=%0d max=%0d  dot340_tile_index min=%0d max=%0d  lines_where_dot340_tile_index_equals_coarse_x=%0d/%0d",
                 x340min, x340max, t340min, t340max,
                 (LINES * tot_frames) - tot_xt340_bad, LINES * tot_frames);
        $display("  Q2 visible_lines_0_239: range_count min=%0d max=%0d  rendered_slots_per_line avg=%0d.%02d  lines_with_overflow=%0d  sprite_pixel_dots_per_line min=%0d max=%0d",
                 rmin, rmax, slots_x100 / 100, slots_x100 % 100,
                 tot_ovf_lines, spmin, spmax);
        $display("  Q2 non_visible_lines_240_261: range_count min=%0d max=%0d (frame_active=0, no sprite rendered, this is the OAM set an external prefetcher would have to use for the next line)",
                 nmin, nmax);
        $display("  Q2 prefetch_window_257_272: dots_per_line=%0d on all %0d lines  fixed_sprite_bytes_per_visible_line=16  useful_bytes_per_visible_line_avg=%0d.%02d  fixed_cost_vs_85dot_hblank=%0d.%02d%%  fixed_cost_vs_16dot_window=%0d%%  useful_cost_vs_16dot_window=%0d.%02d%%",
                 tot_win / (LINES * tot_frames), LINES, pct4 / 100, pct4 % 100,
                 pct3 / 100, pct3 % 100, (tot_sprite_fix * 100) / tot_win_vis,
                 (tot_sprite_use * 10000) / tot_win_vis / 100,
                 (tot_sprite_use * 10000) / tot_win_vis % 100);
        $display("  Q2 range_count histogram over %0d lines:", LINES);
        for (k = 0; k <= 64; k = k + 1)
            if (range_hist[k] > 0)
                $display("    range_count=%0d lines=%0d", k, range_hist[k]);
        $display("  Q3 per_rendered_line_bad_columns: name min=%0d max=%0d | attr_byte min=%0d max=%0d | attr_value min=%0d max=%0d | palette_index max=%0d | final_color max=%0d",
                 bnmin, bnmax, bbmin, bbmax, bqmin, bqmax, bpmax, bcmax);
        pct2 = (tot_bq * 10000) / tot_render_cols;
        pct3 = (tot_bc * 10000) / tot_render_cols;
        $display("  Q3 rendered_line_totals: name=%0d attr_byte=%0d attr_value=%0d palette_index=%0d final_color=%0d  rendered_columns=%0d  attr_value_rate=%0d.%02d%%  final_color_rate=%0d.%02d%%  distinct_coarseX_visited=%0d distinct_coarseX_with_bad_attr=%0d",
                 tot_bn, tot_bb, tot_bq, tot_bp, tot_bc, tot_render_cols,
                 pct2 / 100, pct2 % 100, pct3 / 100, pct3 % 100,
                 popcount32(seen_cxc), popcount32(bad_cxc));
    end
endtask

initial begin
    clk = 1'b0;
    reset = 1'b1;
    ce = 1'b0;
    reg_cs = 1'b0;
    reg_we = 1'b0;
    reg_addr = 3'd0;
    reg_din = 8'h00;
    cfg_fine_x = 0;
    cfg_coarse_x = 0;
    cfg_coarse_y = 0;
    cfg_nt = 0;
    cfg_spr16 = 0;
    cfg_mask = 8'h1C;
    win_lo = 8;
    #23;
    @(negedge clk);
    reset = 1'b0;
    #1;

    apply_reset;
    load_memory;
    load_oam;

    $display("=== chr fetch feasibility measurement, EXTERNAL_CHR=0, hierarchical probe of dot/scanline ===");

    reset_counters;
    cfg_fine_x = 0; cfg_coarse_x = 0;  cfg_coarse_y = 0;  cfg_nt = 0; cfg_spr16 = 0; cfg_mask = 8'h1C;
    set_config;
    run_frame("A0-warmup");
    run_frame("A-fx0-cx0-cy0");
    report("A-fine_x0-cx0-cy0-8x8");

    reset_counters;
    cfg_fine_x = 1; cfg_coarse_x = 0;  cfg_coarse_y = 0;  cfg_nt = 0; cfg_spr16 = 0; cfg_mask = 8'h1C;
    set_config;
    run_frame("B-fx1-cx0-cy0");
    report("B-fine_x1-cx0-cy0-8x8");

    reset_counters;
    cfg_fine_x = 2; cfg_coarse_x = 0;  cfg_coarse_y = 0;  cfg_nt = 0; cfg_spr16 = 0; cfg_mask = 8'h1C;
    set_config;
    run_frame("C-fx2-cx0-cy0");
    report("C-fine_x2-cx0-cy0-8x8");

    reset_counters;
    cfg_fine_x = 3; cfg_coarse_x = 0;  cfg_coarse_y = 0;  cfg_nt = 0; cfg_spr16 = 0; cfg_mask = 8'h1C;
    set_config;
    run_frame("D-fx3-cx0-cy0");
    report("D-fine_x3-cx0-cy0-8x8");

    reset_counters;
    cfg_fine_x = 4; cfg_coarse_x = 0;  cfg_coarse_y = 0;  cfg_nt = 0; cfg_spr16 = 0; cfg_mask = 8'h1C;
    set_config;
    run_frame("E-fx4-cx0-cy0");
    report("E-fine_x4-cx0-cy0-8x8");

    reset_counters;
    cfg_fine_x = 5; cfg_coarse_x = 0;  cfg_coarse_y = 0;  cfg_nt = 0; cfg_spr16 = 0; cfg_mask = 8'h1C;
    set_config;
    run_frame("F-fx5-cx0-cy0");
    report("F-fine_x5-cx0-cy0-8x8");

    reset_counters;
    cfg_fine_x = 6; cfg_coarse_x = 0;  cfg_coarse_y = 0;  cfg_nt = 0; cfg_spr16 = 0; cfg_mask = 8'h1C;
    set_config;
    run_frame("G-fx6-cx0-cy0");
    report("G-fine_x6-cx0-cy0-8x8");

    reset_counters;
    cfg_fine_x = 7; cfg_coarse_x = 0;  cfg_coarse_y = 0;  cfg_nt = 0; cfg_spr16 = 0; cfg_mask = 8'h1C;
    set_config;
    run_frame("H-fx7-cx0-cy0");
    report("H-fine_x7-cx0-cy0-8x8");

    reset_counters;
    cfg_fine_x = 0; cfg_coarse_x = 21; cfg_coarse_y = 29; cfg_nt = 0; cfg_spr16 = 0; cfg_mask = 8'h1C;
    set_config;
    run_frame("I-fx0-cx21");
    report("I-fine_x0-cx21-cy29-8x8");

    reset_counters;
    cfg_fine_x = 7; cfg_coarse_x = 31; cfg_coarse_y = 29; cfg_nt = 0; cfg_spr16 = 0; cfg_mask = 8'h1C;
    set_config;
    run_frame("J-fx7-cx31");
    report("J-fine_x7-cx31-cy29-8x8");

    reset_counters;
    cfg_fine_x = 6; cfg_coarse_x = 20; cfg_coarse_y = 15; cfg_nt = 1; cfg_spr16 = 0; cfg_mask = 8'h1E;
    set_config;
    run_frame("K-fx6-cx20-mask1e");
    report("K-fine_x6-cx20-cy15-nt1-mask1E-8x8");

    reset_counters;
    cfg_fine_x = 5; cfg_coarse_x = 12; cfg_coarse_y = 7;  cfg_nt = 0; cfg_spr16 = 1; cfg_mask = 8'h1C;
    set_config;
    run_frame("L0-warmup");
    run_frame("L-spr16");
    report("L-fine_x5-cx12-cy7-8x16");

    reset_counters;
    cfg_fine_x = 5; cfg_coarse_x = 12; cfg_coarse_y = 7;  cfg_nt = 0; cfg_spr16 = 0; cfg_mask = 8'h1C;
    set_config;
    run_frame("M0-warmup");
    run_frame("M-spr8");
    report("M-fine_x5-cx12-cy7-8x8");

    $display("Q2 per-line detail, pass M (8x8), lines 0..40 and 95..115 and 240..261:");
    for (li = 0; li <= 40; li = li + 1)
        $display("  M line %0d range_count=%0d sprite_pixel_dots=%0d overflow_dots=%0d rendered_bg_columns=%0d bad_attr_columns=%0d",
                 li, line_range[li], line_spix[li], line_ovf[li], line_render[li], line_bq[li]);
    for (li = 95; li <= 115; li = li + 1)
        $display("  M line %0d range_count=%0d sprite_pixel_dots=%0d overflow_dots=%0d rendered_bg_columns=%0d bad_attr_columns=%0d",
                 li, line_range[li], line_spix[li], line_ovf[li], line_render[li], line_bq[li]);
    for (li = 240; li <= 261; li = li + 1)
        $display("  M line %0d range_count=%0d sprite_pixel_dots=%0d overflow_dots=%0d rendered_bg_columns=%0d bad_attr_columns=%0d",
                 li, line_range[li], line_spix[li], line_ovf[li], line_render[li], line_bq[li]);

    $display("Q1 dot340 bg_x_total, pass M: line0=%0d line1=%0d line119=%0d line238=%0d line239=%0d line240=%0d line261=%0d (fine_x=%0d)",
             line_xt340[0], line_xt340[1], line_xt340[119], line_xt340[238], line_xt340[239],
             line_xt340[240], line_xt340[261], cfg_fine_x);

    $display("PASS chr_fetch_feasibility");
    $finish;
end

initial begin
    #400000000;
    $fatal(1, "global timeout");
end

endmodule
