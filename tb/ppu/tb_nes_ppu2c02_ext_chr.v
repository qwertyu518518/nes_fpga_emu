`timescale 1ns/1ps

module tb_nes_ppu2c02_ext_chr;

    localparam integer WARMUP_FRAMES     = 1;
    localparam integer COMPARE_FRAMES    = 3;
    localparam integer TOTAL_FRAMES      = WARMUP_FRAMES + COMPARE_FRAMES;
    localparam integer SPR_COMPARE_FRAMES = 1;
    localparam integer SPR_TOTAL_FRAMES  = WARMUP_FRAMES + SPR_COMPARE_FRAMES;
    localparam integer SPR_DIAG_MAX      = 24;

    reg         clk;
    reg         reset;
    reg         ce;
    integer     ce_div;
    reg         reg_cs;
    reg         reg_we;
    reg  [2:0]  reg_addr;
    reg  [7:0]  reg_din;

    wire [7:0]  rd_a;
    wire [7:0]  rd_b;
    wire        pv_a;
    wire        pv_b;
    wire [7:0]  pxx_a;
    wire [7:0]  pxx_b;
    wire [7:0]  pxy_a;
    wire [7:0]  pxy_b;
    wire [3:0]  pidx_a;
    wire [3:0]  pidx_b;
    wire        fd_a;
    wire        fd_b;
    wire        vb_a;
    wire        vb_b;
    wire        nmi_a;
    wire        nmi_b;
    wire [8:0]  dot_a;
    wire [8:0]  dot_b;
    wire [8:0]  sl_a;
    wire [8:0]  sl_b;
    wire [14:0] dv_a;
    wire [14:0] dv_b;
    wire [14:0] dt_a;
    wire [14:0] dt_b;
    wire [2:0]  dx_a;
    wire [2:0]  dx_b;
    wire        dw_a;
    wire        dw_b;
    wire        s0_a;
    wire        s0_b;
    wire        ovf_a;
    wire        ovf_b;
    wire        req_b;
    wire [13:0] addr_b;
    wire        we_b;
    wire [7:0]  wdata_b;
    wire        pae_a;
    wire        pae_b;

    reg  [7:0]  chr_mem [0:8191];
    reg  [7:0]  chr_rdata_q;

    reg  [7:0]  cfg_ctrl;
    reg  [7:0]  cfg_mask;
    reg  [4:0]  cfg_cx;
    reg  [2:0]  cfg_fx;
    reg  [4:0]  cfg_cy;
    reg  [7:0]  cfg_seed;

    integer     frame_cnt;
    integer     pix_cmp;
    integer     pix_nz;
    integer     plo_nz;
    integer     line_req;
    integer     line_win;
    integer     line_trig;
    integer     line_checked;
    integer     req_idx;
    integer     latch_checked;
    integer     addr_checked;
    integer     dropped_trig;
    integer     case_pix;
    integer     case_pix_nz;
    integer     case_req;
    integer     case_trig;
    integer     case_latch;
    integer     case_frames;
    integer     case_lines;
    integer     case_pairs;
    integer     bg_exp_req;
    integer     bg_exp_tiles;
    integer     bg_case_latch;

    reg [8:0]  x_look;
    reg [8:0]  x_dot;
    reg [8:0]  x_xtot;
    reg [5:0]  x_cxsum;
    reg [4:0]  x_cy;
    reg [8:0]  x_nlsl;
    reg [8:0]  x_nly;
    reg [6:0]  x_nlsum;
    reg [2:0]  x_fy;
    reg        x_nt0;
    reg        x_nt1;
    reg        x_next;
    reg [10:0] x_nidx;
    reg [7:0]  x_name;
    reg [12:0] x_base;
    reg [13:0] x_addr;
    reg [12:0] trig_base;
    reg [12:0] req_base;
    reg [7:0]  trig_name;
    reg [8:0]  trig_sl;
    reg [8:0]  trig_dot;
    reg [12:0] lo_addr_q;
    reg [12:0] hi_addr_q;
    reg        latch_pend;
    reg        bg_valid_q;
    reg        bg_busy_q;
    reg [8:0]  latch_sl;
    reg [8:0]  latch_dot;
    reg [12:0] latch_lo;
    reg [12:0] latch_hi;

    integer exp_mid;
    integer exp_first;
    integer exp_spill_in;
    integer exp_spill_out;
    integer exp_req;
    integer exp_tiles;

    reg        run_bg;
    integer    cmp_frames;
    integer    sp_scn;

    integer    sp_pix;
    integer    sp_mism;
    integer    sp_mism_prevline;
    integer    sp_px_true;
    integer    sp_decided;
    integer    sp_over_bg;
    integer    sp_front;
    integer    sp_behind;
    integer    sp_ovf_dots;
    integer    sp_full8_dots;
    integer    sp_beat_ok;
    integer    sp_beat_tot;
    integer    sp_shadow_ok;
    integer    sp_shadow_bad;
    integer    sp_req_cycles;
    integer    sp_latch_checked;
    integer    sp_line_checked;
    integer    sp_diag_shown;
    integer    sp_px_mism;
    integer    sp_prio_mism;
    integer    sp_hitraw_mism;
    integer    sp_ovfraw_mism;
    integer    sp_hitreg_mism;
    integer    sp_ovfreg_mism;
    integer    sp_cnt_mism;
    integer    sp_line_checked_ok;

    integer    case_sp_mism;
    integer    case_sp_px;
    integer    case_sp_dec;
    integer    case_sp_over_bg;
    integer    case_sp_front;
    integer    case_sp_behind;
    integer    case_sp_ovf;
    integer    case_sp_full8;
    integer    case_sp_beat;
    integer    case_sp_shadow;
    integer    case_sp_latch;
    integer    case_sp_req;
    integer    case_sp_mism_prev;

    reg [3:0]  sp_line_pix [0:1][0:255];
    reg        sp_par;
    reg [8*6-1:0] phase_str;

    reg [103:0] sf_pat;
    reg [13:0]  sf_exp;
    integer     sf_beat;
    reg         sf_shadow_q;
    reg [12:0]  sf_pa;
    integer     sp_i;

    integer k;
    integer row;
    integer col;
    integer s;
    integer q;
    reg [7:0] nt_val;
    reg [7:0] ch_val;

    nes_ppu2c02 #(
        .MIRROR_VERTICAL(1'b0),
        .EXTERNAL_CHR(1'b0)
    ) dut_a (
        .clk(clk),
        .reset(reset),
        .ce(ce),
        .reg_cs(reg_cs),
        .reg_we(reg_we),
        .reg_addr(reg_addr),
        .reg_din(reg_din),
        .reg_dout(rd_a),
        .pixel_valid(pv_a),
        .pixel_x(pxx_a),
        .pixel_y(pxy_a),
        .pixel_index(pidx_a),
        .frame_done(fd_a),
        .vblank(vb_a),
        .nmi_o(nmi_a),
        .dot(dot_a),
        .scanline(sl_a),
        .dbg_v(dv_a),
        .dbg_t(dt_a),
        .dbg_x(dx_a),
        .dbg_w(dw_a),
        .dbg_sprite0_hit(s0_a),
        .dbg_sprite_overflow(ovf_a),
        .chr_req(),
        .chr_addr(),
        .chr_we(),
        .chr_wdata(),
        .chr_rdata(8'h00)
    );

    nes_ppu2c02 #(
        .MIRROR_VERTICAL(1'b0),
        .EXTERNAL_CHR(1'b1)
    ) dut_b (
        .clk(clk),
        .reset(reset),
        .ce(ce),
        .reg_cs(reg_cs),
        .reg_we(reg_we),
        .reg_addr(reg_addr),
        .reg_din(reg_din),
        .reg_dout(rd_b),
        .pixel_valid(pv_b),
        .pixel_x(pxx_b),
        .pixel_y(pxy_b),
        .pixel_index(pidx_b),
        .frame_done(fd_b),
        .vblank(vb_b),
        .nmi_o(nmi_b),
        .dot(dot_b),
        .scanline(sl_b),
        .dbg_v(dv_b),
        .dbg_t(dt_b),
        .dbg_x(dx_b),
        .dbg_w(dw_b),
        .dbg_sprite0_hit(s0_b),
        .dbg_sprite_overflow(ovf_b),
        .chr_req(req_b),
        .chr_addr(addr_b),
        .chr_we(we_b),
        .chr_wdata(wdata_b),
        .chr_rdata(chr_rdata_q)
    );

    always #5 clk = ~clk;

    always @(posedge clk) begin
        if (ce) begin
            chr_rdata_q <= chr_mem[addr_b[12:0]];
        end
    end

    task ce_tick;
        begin
            for (q = 1; q < ce_div; q = q + 1) begin
                ce = 1'b0;
                @(posedge clk);
                #1;
            end
            ce = 1'b1;
            @(posedge clk);
            #1;
            ce = 1'b0;
            monitor;
        end
    endtask

    task write_register;
        input [2:0] address;
        input [7:0] data;
        begin
            ce = 1'b0;
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

    task read_status;
        begin
            ce = 1'b0;
            reg_cs = 1'b1;
            reg_we = 1'b0;
            reg_addr = 3'd2;
            reg_din = 8'h00;
            @(posedge clk);
            #1;
            reg_cs = 1'b0;
            reg_addr = 3'd0;
        end
    endtask

    task set_config;
        begin
            read_status;
            write_register(3'd6, 8'h20);
            write_register(3'd6, 8'h00);
            write_register(3'd5, {cfg_cx, cfg_fx});
            write_register(3'd5, {cfg_cy, 3'b000});
            write_register(3'd0, cfg_ctrl);
            write_register(3'd1, cfg_mask);
            if (dut_a.fine_x !== cfg_fx)
                $fatal(1, "fine_x A %0d != cfg %0d", dut_a.fine_x, cfg_fx);
            if (dut_b.fine_x !== cfg_fx)
                $fatal(1, "fine_x B %0d != cfg %0d", dut_b.fine_x, cfg_fx);
            if (dut_a.temp_addr[4:0] !== cfg_cx)
                $fatal(1, "coarse_x %0d != cfg %0d", dut_a.temp_addr[4:0], cfg_cx);
            if (dut_a.temp_addr[9:5] !== cfg_cy)
                $fatal(1, "coarse_y %0d != cfg %0d", dut_a.temp_addr[9:5], cfg_cy);
            if (dut_a.mask_reg !== cfg_mask)
                $fatal(1, "mask A %02h != cfg %02h", dut_a.mask_reg, cfg_mask);
            if (dut_b.mask_reg !== cfg_mask)
                $fatal(1, "mask B %02h != cfg %02h", dut_b.mask_reg, cfg_mask);
            if (dut_a.control_reg !== cfg_ctrl)
                $fatal(1, "ctrl A %02h != cfg %02h", dut_a.control_reg, cfg_ctrl);
            if (dut_b.control_reg !== cfg_ctrl)
                $fatal(1, "ctrl B %02h != cfg %02h", dut_b.control_reg, cfg_ctrl);
        end
    endtask

    task load_scene_base;
        begin
            for (k = 0; k < 2048; k = k + 1) begin
                dut_a.nametable_ram[k] = 8'h00;
                dut_b.nametable_ram[k] = 8'h00;
            end
            for (row = 0; row < 30; row = row + 1) begin
                for (col = 0; col < 32; col = col + 1) begin
                    nt_val = ((row * 7) + (col * 3) + cfg_seed) & 8'hFF;
                    dut_a.nametable_ram[row * 32 + col] = nt_val;
                    dut_b.nametable_ram[row * 32 + col] = nt_val;
                end
            end
            for (k = 0; k < 64; k = k + 1) begin
                if (k[0] == 1'b0)
                    nt_val = 8'h1B;
                else
                    nt_val = 8'hE4;
                dut_a.nametable_ram[12'h3C0 + k] = nt_val;
                dut_b.nametable_ram[12'h3C0 + k] = nt_val;
            end
            for (k = 0; k < 32; k = k + 1) begin
                nt_val = 8'h10 + k[7:0];
                dut_a.palette_ram[k] = nt_val;
                dut_b.palette_ram[k] = nt_val;
            end
        end
    endtask

    task put_sprite;
        input [5:0] idx;
        input [7:0] yy;
        input [7:0] tile;
        input [7:0] attr;
        input [7:0] xx;
        begin
            dut_a.oam_ram[idx * 4 + 0] = yy;
            dut_b.oam_ram[idx * 4 + 0] = yy;
            dut_a.oam_ram[idx * 4 + 1] = tile;
            dut_b.oam_ram[idx * 4 + 1] = tile;
            dut_a.oam_ram[idx * 4 + 2] = attr;
            dut_b.oam_ram[idx * 4 + 2] = attr;
            dut_a.oam_ram[idx * 4 + 3] = xx;
            dut_b.oam_ram[idx * 4 + 3] = xx;
        end
    endtask

    task put_pattern_tile;
        input [7:0] tile;
        integer rr;
        reg [7:0] lo_b;
        reg [7:0] hi_b;
        begin
            for (rr = 0; rr < 8; rr = rr + 1) begin
                lo_b = {rr[2:0], 3'b101, tile[2:0]};
                hi_b = {tile[2:0], 3'b010, rr[2:0]};
                dut_a.chr_ram[tile * 16 + rr] = lo_b;
                dut_b.chr_ram[tile * 16 + rr] = lo_b;
                chr_mem[tile * 16 + rr] = lo_b;
                dut_a.chr_ram[tile * 16 + rr + 8] = hi_b;
                dut_b.chr_ram[tile * 16 + rr + 8] = hi_b;
                chr_mem[tile * 16 + rr + 8] = hi_b;
            end
        end
    endtask

    task load_memory;
        begin
            load_scene_base;
            for (s = 0; s < 64; s = s + 1) begin
                dut_a.oam_ram[s * 4 + 0] = 8'hF8;
                dut_b.oam_ram[s * 4 + 0] = 8'hF8;
                dut_a.oam_ram[s * 4 + 1] = 8'h08;
                dut_b.oam_ram[s * 4 + 1] = 8'h08;
                dut_a.oam_ram[s * 4 + 2] = 8'h00;
                dut_b.oam_ram[s * 4 + 2] = 8'h00;
                dut_a.oam_ram[s * 4 + 3] = 8'h00;
                dut_b.oam_ram[s * 4 + 3] = 8'h00;
            end
            for (s = 0; s < 12; s = s + 1) begin
                dut_a.oam_ram[s * 4 + 0] = 8'h20;
                dut_b.oam_ram[s * 4 + 0] = 8'h20;
                dut_a.oam_ram[s * 4 + 3] = 8'd8 * s[7:0];
                dut_b.oam_ram[s * 4 + 3] = 8'd8 * s[7:0];
            end
            dut_a.oam_ram[1 * 4 + 2] = 8'h20;
            dut_b.oam_ram[1 * 4 + 2] = 8'h20;
            dut_a.oam_ram[1 * 4 + 3] = 8'd100;
            dut_b.oam_ram[1 * 4 + 3] = 8'd100;
            for (k = 0; k < 8192; k = k + 1) begin
                if (k < 512)
                    ch_val = 8'h00;
                else
                    ch_val = (~k[7:0]) ^ 8'h5A ^ cfg_seed;
                dut_a.chr_ram[k] = ch_val;
                dut_b.chr_ram[k] = ch_val;
                chr_mem[k] = ch_val;
            end
        end
    endtask

    task load_sprite_scene;
        begin
            load_scene_base;
            for (s = 0; s < 64; s = s + 1) begin
                put_sprite(s[5:0], 8'hF8, 8'h08, 8'h00, 8'h00);
            end
            for (k = 0; k < 8192; k = k + 1) begin
                ch_val = {((~k[7:3]) ^ 5'h15) ^ cfg_seed[7:3], 3'b000};
                dut_a.chr_ram[k] = ch_val;
                dut_b.chr_ram[k] = ch_val;
                chr_mem[k] = ch_val;
            end
            for (k = 0; k < 17; k = k + 1) begin
                put_pattern_tile(k[7:0]);
            end
            for (k = 0; k < 16; k = k + 1) begin
                put_pattern_tile(8'h80 + k[7:0]);
            end
            case (sp_scn)
                1: begin
                    put_sprite(6'd0, 8'd40, 8'h80, 8'h01, 8'd0);
                end
                2: begin
                    put_sprite(6'd0, 8'd40, 8'h81, 8'h02, 8'd250);
                end
                3: begin
                    for (s = 0; s < 8; s = s + 1)
                        put_sprite(s[5:0], 8'd64, 8'h80 + s[7:0],
                                   (s[0] ? 8'h20 : 8'h00) | s[1:0],
                                   8'd16 * s[7:0]);
                end
                4: begin
                    for (s = 0; s < 10; s = s + 1)
                        put_sprite(s[5:0], 8'd64, 8'h80 + s[7:0],
                                   (s[0] ? 8'h20 : 8'h00) | s[1:0],
                                   8'd24 * s[7:0]);
                end
                5: begin
                    put_sprite(6'd0, 8'd40, 8'h84, 8'h43, 8'd64);
                end
                6: begin
                    put_sprite(6'd0, 8'd40, 8'h85, 8'h81, 8'd64);
                end
                7: begin
                    put_sprite(6'd0, 8'd40, 8'h86, 8'hC2, 8'd64);
                end
                8: begin
                    put_sprite(6'd0, 8'd40, 8'h8B, 8'h02, 8'd200);
                end
                9: begin
                    for (s = 0; s < 8; s = s + 1)
                        put_sprite(s[5:0], 8'd120, 8'h80 + (2 * s[7:0] + s[0]),
                                   (s[0] ? 8'h20 : 8'h00) | s[1:0],
                                   8'd16 * s[7:0]);
                end
                default: begin
                    $fatal(1, "unknown sprite scenario %0d", sp_scn);
                end
            endcase
        end
    endtask

    task sp_neq;
        input [8*40-1:0] what;
        input [7:0] va;
        input [7:0] vb;
        begin
            if (run_bg) begin
                $fatal(1, "A/B %0s differs at %0d:%0d: A=%02h B=%02h",
                       what, sl_a, dot_a, va, vb);
            end else begin
                if (sp_diag_shown < SPR_DIAG_MAX) begin
                    sp_diag_shown = sp_diag_shown + 1;
                    $display("    DIAG %0s A=%02h B=%02h at %0d:%0d frame %0d",
                             what, va, vb, sl_a, dot_a, frame_cnt);
                end
            end
        end
    endtask

    task sp_note_pix;
        begin
            sp_mism = sp_mism + 1;
            case_sp_mism = case_sp_mism + 1;
            if (pidx_b === sp_line_pix[~sp_par][dot_a[7:0]]) begin
                sp_mism_prevline = sp_mism_prevline + 1;
                case_sp_mism_prev = case_sp_mism_prev + 1;
            end
            if (sp_diag_shown < SPR_DIAG_MAX) begin
                sp_diag_shown = sp_diag_shown + 1;
                $display("    DIAG mixed pixel frame %0d line %0d dot %0d: A=%01h B=%01h | A_sprite_pixel=%01h B_sprite_pixel=%01h | A_prio=%01h B_prio=%01h | A_cur_slot=%0d B_cur_slot=%0d | B_chr_sh=%04h | A_slot0_pat_addr=%0d B_shadow_fetched_pat_addr=%0d | A_prevline_dot=%01h | A_range=%0d B_range=%0d",
                         frame_cnt, sl_a, dot_a, pidx_a, pidx_b,
                         dut_a.g_chr_internal.u_sprite.sprite_pixel,
                         dut_b.g_chr_external.u_sprite.sprite_pixel,
                         dut_a.g_chr_internal.u_sprite.sprite_priority,
                         dut_b.g_chr_external.u_sprite.sprite_priority,
                         dut_a.g_chr_internal.u_sprite.cur_slot,
                         dut_b.g_chr_external.u_sprite.cur_slot,
                         dut_b.g_chr_external.sp_chr_sh,
                         dut_a.g_chr_internal.u_sprite.pat_addr_o[12:0],
                         sf_pat[12:0],
                         sp_line_pix[~sp_par][dot_a[7:0]],
                         dut_a.g_chr_internal.u_sprite.range_count,
                         dut_b.g_chr_external.u_sprite.range_count);
            end
        end
    endtask

    task monitor;
        integer a_tiles;
        integer sp_line_req;
        begin
            if (dot_a !== dot_b || sl_a !== sl_b)
                $fatal(1, "A/B time base diverged: A %0d:%0d B %0d:%0d", sl_a, dot_a, sl_b, dot_b);
            if (pae_a !== pae_b)
                $fatal(1, "A5 bg_pa_enable differs at %0d:%0d: A=%b B=%b", sl_a, dot_a, pae_a, pae_b);
            if (fd_a !== fd_b)
                $fatal(1, "frame_done differs at %0d:%0d", sl_a, dot_a);
            if (vb_a !== vb_b || nmi_a !== nmi_b)
                $fatal(1, "vblank/nmi differ at %0d:%0d", sl_a, dot_a);
            if (dv_a !== dv_b || dt_a !== dt_b || dx_a !== dx_b || dw_a !== dw_b)
                $fatal(1, "scroll dbg differs at %0d:%0d", sl_a, dot_a);
            if (dut_a.g_chr_internal.u_sprite.range_count
                !== dut_b.g_chr_external.u_sprite.range_count)
                $fatal(1, "S1 OAM range scan differs at %0d:%0d: A=%0d B=%0d",
                       sl_a, dot_a,
                       dut_a.g_chr_internal.u_sprite.range_count,
                       dut_b.g_chr_external.u_sprite.range_count);
            if (s0_a !== s0_b) begin
                if (run_bg)
                    $fatal(1, "sprite0_hit differs at %0d:%0d: A=%b B=%b", sl_a, dot_a, s0_a, s0_b);
                if (frame_cnt >= WARMUP_FRAMES) begin
                    sp_hitreg_mism = sp_hitreg_mism + 1;
                    sp_neq("dbg_sprite0_hit", {7'b0, s0_a}, {7'b0, s0_b});
                end
            end
            if (ovf_a !== ovf_b) begin
                if (run_bg)
                    $fatal(1, "sprite_overflow differs at %0d:%0d: A=%b B=%b", sl_a, dot_a, ovf_a, ovf_b);
                if (frame_cnt >= WARMUP_FRAMES) begin
                    sp_ovfreg_mism = sp_ovfreg_mism + 1;
                    sp_neq("dbg_sprite_overflow", {7'b0, ovf_a}, {7'b0, ovf_b});
                end
            end
            if (we_b !== 1'b0 || wdata_b !== 8'h00)
                $fatal(1, "chr_we/chr_wdata not tied low at %0d:%0d", sl_a, dot_a);

            if (frame_cnt >= WARMUP_FRAMES) begin
                if (dut_a.g_chr_internal.u_sprite.sprite_pixel[1:0]
                    !== dut_b.g_chr_external.u_sprite.sprite_pixel[1:0]) begin
                    sp_px_mism = sp_px_mism + 1;
                    sp_neq("sprite_pixel",
                           {4'b0, dut_a.g_chr_internal.u_sprite.sprite_pixel},
                           {4'b0, dut_b.g_chr_external.u_sprite.sprite_pixel});
                end
                if (dut_a.g_chr_internal.u_sprite.sprite_priority
                    !== dut_b.g_chr_external.u_sprite.sprite_priority) begin
                    sp_prio_mism = sp_prio_mism + 1;
                    sp_neq("sprite_priority",
                           {4'b0, dut_a.g_chr_internal.u_sprite.sprite_priority},
                           {4'b0, dut_b.g_chr_external.u_sprite.sprite_priority});
                end
                if (dut_a.g_chr_internal.u_sprite.sprite0_hit
                    !== dut_b.g_chr_external.u_sprite.sprite0_hit) begin
                    sp_hitraw_mism = sp_hitraw_mism + 1;
                    sp_neq("raw_sprite0_hit",
                           {7'b0, dut_a.g_chr_internal.u_sprite.sprite0_hit},
                           {7'b0, dut_b.g_chr_external.u_sprite.sprite0_hit});
                end
                if (dut_a.g_chr_internal.u_sprite.sprite_overflow
                    !== dut_b.g_chr_external.u_sprite.sprite_overflow) begin
                    sp_ovfraw_mism = sp_ovfraw_mism + 1;
                    sp_neq("raw_sprite_overflow",
                           {7'b0, dut_a.g_chr_internal.u_sprite.sprite_overflow},
                           {7'b0, dut_b.g_chr_external.u_sprite.sprite_overflow});
                end
            end

            if (pae_b === 1'b0) begin
                if (dut_b.bg_pattern_low !== 8'h00)
                    $fatal(1, "A4 bg_pattern_low %02h != 0 with bg_pa_enable=0 at %0d:%0d",
                           dut_b.bg_pattern_low, sl_a, dot_a);
                if (dut_b.bg_pattern_high !== 8'h00)
                    $fatal(1, "A4 bg_pattern_high %02h != 0 with bg_pa_enable=0 at %0d:%0d",
                           dut_b.bg_pattern_high, sl_a, dot_a);
            end else if (frame_cnt >= WARMUP_FRAMES) begin
                if (dut_b.g_chr_external.bg_ready !== 1'b1)
                    $fatal(1, "A4 pipeline not primed while bg_pa_enable=1 at %0d:%0d", sl_a, dot_a);
            end

            if (dot_b == 9'd257) begin
                if (dut_b.g_chr_external.sp_start !== 1'b1)
                    $fatal(1, "S2 sprite prefetch start pulse missing at %0d:%0d", sl_b, dot_b);
            end
            if (dot_b == 9'd258) begin
                sf_pat  = dut_b.g_chr_external.u_sprite.pat_addr_o;
                sf_beat = 0;
            end

            if ((sl_a < 240) && (dot_a < 256) && (frame_cnt >= WARMUP_FRAMES)) begin
                sp_line_pix[sp_par][dot_a[7:0]] = pidx_a;
                if (run_bg == 1'b0)
                    sp_pix = sp_pix + 1;
                if (pidx_a !== pidx_b) begin
                    if (run_bg) begin
                        $fatal(1, "A1 pixel mismatch frame %0d line %0d dot %0d: A=%0d B=%0d (A planes %02h/%02h, B planes %02h/%02h, A name %02h)",
                               frame_cnt, sl_a, dot_a, pidx_a, pidx_b,
                               dut_a.bg_pattern_low, dut_a.bg_pattern_high,
                               dut_b.bg_pattern_low,
                               dut_b.bg_pattern_high,
                               dut_a.bg_name);
                    end else begin
                        sp_note_pix;
                    end
                end
                if (pxx_a !== pxx_b || pxy_a !== pxy_b)
                    $fatal(1, "A1 pixel coords differ at %0d:%0d", sl_a, dot_a);
                if (pv_a !== pv_b)
                    $fatal(1, "A1 pixel_valid differs at %0d:%0d", sl_a, dot_a);
                if ((run_bg == 1'b0) && (dut_a.g_chr_internal.u_sprite.sprite_pixel[1:0] != 2'b00)) begin
                    sp_px_true = sp_px_true + 1;
                    case_sp_px = case_sp_px + 1;
                end
                if ((run_bg == 1'b0) && (dut_a.sprite_opaque == 1'b1)) begin
                    sp_decided = sp_decided + 1;
                    case_sp_dec = case_sp_dec + 1;
                    if (dut_a.bg_opaque == 1'b1) begin
                        if (dut_a.g_chr_internal.u_sprite.sprite_priority[3] == 1'b1) begin
                            sp_behind = sp_behind + 1;
                            case_sp_behind = case_sp_behind + 1;
                        end else begin
                            sp_front = sp_front + 1;
                            case_sp_front = case_sp_front + 1;
                        end
                    end else begin
                        sp_over_bg = sp_over_bg + 1;
                        case_sp_over_bg = case_sp_over_bg + 1;
                    end
                end
                if ((run_bg == 1'b0) && (dut_a.g_chr_internal.u_sprite.range_count == 7'd8)) begin
                    sp_full8_dots = sp_full8_dots + 1;
                    case_sp_full8 = case_sp_full8 + 1;
                end
                if ((run_bg == 1'b0) && (dut_a.g_chr_internal.u_sprite.sprite_overflow == 1'b1)) begin
                    sp_ovf_dots = sp_ovf_dots + 1;
                    case_sp_ovf = case_sp_ovf + 1;
                end
                if ((run_bg == 1'b0) && (dut_b.g_chr_external.u_sprite.sprite_overflow === 1'b1)
                    && (dut_a.g_chr_internal.u_sprite.sprite_overflow === 1'b0)) begin
                    sp_cnt_mism = sp_cnt_mism + 1;
                end
                case_pix = case_pix + 1;
                if (run_bg) begin
                    pix_cmp = pix_cmp + 1;
                    if (dut_a.bg_pattern_low !== 8'h00) begin
                        plo_nz = plo_nz + 1;
                    end
                    if (pidx_a !== 4'h0) begin
                        pix_nz = pix_nz + 1;
                        case_pix_nz = case_pix_nz + 1;
                    end
                end
            end

            if ((sl_a < 240) && (dot_a < 256)) begin
                if (((dot_a + {6'b0, cfg_fx}) % 8) == 0) begin
                    line_win = line_win + 1;
                end
            end

            if ((dut_b.g_chr_external.bg_fetch_due === 1'b1)
                && (dut_b.g_chr_external.chr_fetch_busy === 1'b1)) begin
                dropped_trig = dropped_trig + 1;
                if (frame_cnt >= WARMUP_FRAMES)
                    $fatal(1, "A2 tile trigger dropped at %0d:%0d inside a compared frame (pipeline desync)",
                           sl_b, dot_b);
            end

            if (dut_b.g_chr_external.bg_fetch_due === 1'b1) begin
                line_trig = line_trig + 1;
                case_trig = case_trig + 1;
                x_look = (dot_b == 9'd324) ? (dot_b + 9'd17) : (dot_b + 9'd9);
                x_next = (x_look >= 9'd341);
                x_dot = x_next ? (x_look - 9'd341) : x_look;
                x_xtot = x_dot + {6'b0, dut_a.fine_x} + ({4'b0, dut_a.temp_addr[4:0]} << 3);
                x_cxsum = {1'b0, dut_a.temp_addr[4:0]} + {1'b0, x_xtot[8:3]};
                x_fy = dut_a.bg_y_total[2:0];
                x_cy = dut_a.bg_coarse_y;
                x_nt1 = dut_a.temp_addr[11] ^ dut_a.bg_vertical_sections[0];
                if (x_next) begin
                    x_nlsl = (sl_b == 261) ? 0 : (sl_b + 1);
                    x_nly = x_nlsl + ({4'b0, dut_a.temp_addr[9:5]} << 3) + {6'b0, dut_a.temp_addr[14:12]};
                    x_nlsum = {2'b0, dut_a.temp_addr[9:5]} + {1'b0, x_nly[8:3]};
                    x_fy = x_nly[2:0];
                    x_cy = x_nlsum % 30;
                    x_nt1 = dut_a.temp_addr[11] ^ ((x_nlsum / 30) & 1);
                end
                x_nt0 = dut_a.temp_addr[10] ^ x_cxsum[5];
                x_nidx = {x_nt1, x_cy, x_cxsum[4:0]};
                x_name = dut_a.nametable_ram[x_nidx];
                x_base = {dut_a.control_reg[4], x_name, 4'b0000} + {10'b0000000000, x_fy};
                trig_base <= x_base;
                trig_name <= x_name;
                trig_sl <= sl_b;
                trig_dot <= dot_b;
            end

            if ((dut_b.g_chr_external.chr_fetch_busy === 1'b1) && (bg_busy_q === 1'b0)) begin
                req_idx = 0;
                req_base = trig_base;
            end
            bg_busy_q = dut_b.g_chr_external.chr_fetch_busy;

            if (req_b === 1'b1) begin
                if (dut_b.g_chr_external.sp_bus_sel === 1'b1) begin
                    if (addr_b !== dut_b.g_chr_external.sp_chr_addr)
                        $fatal(1, "A3 line %0d dot %0d: sprite beat chr_addr %0d != sp_chr_addr %0d (arbitration mux corrupted the owner address)",
                               sl_b, dot_b, addr_b, dut_b.g_chr_external.sp_chr_addr);
                    if (sf_beat > 15)
                        $fatal(1, "S2 line %0d dot %0d: sprite beat %0d exceeds the 16 byte budget",
                               sl_b, dot_b, sf_beat);
                    sf_exp = {1'b0, sf_pat[sf_beat[3:1] * 13 +: 13]}
                             + (sf_beat[0] ? 14'd8 : 14'd0);
                    if (addr_b !== sf_exp) begin
                        $fatal(1, "S2 line %0d dot %0d: sprite beat %0d chr_addr %0d != pat_addr[slot %0d plane %0d] %0d",
                               sl_b, dot_b, sf_beat, addr_b, sf_beat[3:1], sf_beat[0], sf_exp);
                    end
                    sp_beat_tot = sp_beat_tot + 1;
                    sp_beat_ok = sp_beat_ok + 1;
                    case_sp_beat = case_sp_beat + 1;
                    sp_line_req = sp_line_req + 1;
                    if (run_bg == 1'b0)
                        sp_req_cycles = sp_req_cycles + 1;
                    sf_beat = sf_beat + 1;
                end else begin
                    x_addr = {1'b0, req_base} + ((req_idx[0] == 1'b0) ? 14'd0 : 14'd8);
                    if (addr_b !== x_addr)
                        $fatal(1, "A3 line %0d dot %0d req %0d (parity %0d): chr_addr %0d != expected %0d; trigger was %0d:%0d name %02h base %0d, fetch latched base %0d (live A name %02h cxsum %0d)",
                               sl_b, dot_b, req_idx, req_idx[0], addr_b, x_addr,
                               trig_sl, trig_dot, trig_name, trig_base, req_base, dut_a.bg_name, dut_a.bg_coarse_x_sum);
                    if (addr_b !== dut_b.g_chr_external.bg_chr_addr)
                        $fatal(1, "A3 line %0d dot %0d: background beat chr_addr %0d != bg_chr_addr %0d (arbitration mux corrupted the owner address)",
                               sl_b, dot_b, addr_b, dut_b.g_chr_external.bg_chr_addr);
                    if (run_bg)
                        addr_checked = addr_checked + 1;
                    if (req_idx[0] == 1'b0)
                        lo_addr_q <= addr_b[12:0];
                    else
                        hi_addr_q <= addr_b[12:0];
                    line_req = line_req + 1;
                    req_idx = req_idx + 1;
                end
                case_req = case_req + 1;
                if (run_bg == 1'b0)
                    case_sp_req = case_sp_req + 1;
            end

            if ((dut_b.g_chr_external.chr_fetch_bg_valid === 1'b1) && (bg_valid_q === 1'b0)) begin
                latch_lo = lo_addr_q;
                latch_hi = hi_addr_q;
                latch_sl = sl_b;
                latch_dot = dot_b;
                latch_pend = 1'b1;
                if (run_bg)
                    case_latch = case_latch + 1;
            end else if (latch_pend === 1'b1) begin
                latch_pend = 1'b0;
                if (frame_cnt >= WARMUP_FRAMES) begin
                    if (dut_b.g_chr_external.bg_lo_q !== chr_mem[latch_lo])
                        $fatal(1, "A3 latched low plane %02h != chr_mem[%0d] %02h (pulse at %0d:%0d)",
                               dut_b.g_chr_external.bg_lo_q, latch_lo,
                               chr_mem[latch_lo], latch_sl, latch_dot);
                    if (dut_b.g_chr_external.bg_hi_q !== chr_mem[latch_hi])
                        $fatal(1, "A3 latched high plane %02h != chr_mem[%0d] %02h (pulse at %0d:%0d)",
                               dut_b.g_chr_external.bg_hi_q, latch_hi,
                               chr_mem[latch_hi], latch_sl, latch_dot);
                    case_pairs = case_pairs + 1;
                    if (run_bg) begin
                        latch_checked = latch_checked + 1;
                    end else begin
                        sp_latch_checked = sp_latch_checked + 1;
                        case_sp_latch = case_sp_latch + 1;
                    end
                end
            end
            bg_valid_q = dut_b.g_chr_external.chr_fetch_bg_valid;

            if ((dut_b.g_chr_external.sp_shadow_valid === 1'b1) && (sf_shadow_q === 1'b0)) begin
                if (sf_beat !== 16)
                    $fatal(1, "S2 line %0d dot %0d: shadow_valid rose after %0d beats, expected 16",
                           sl_b, dot_b, sf_beat);
                for (sp_i = 0; sp_i < 8; sp_i = sp_i + 1) begin
                    sf_pa = sf_pat[sp_i[2:0] * 13 +: 13];
                    if (dut_b.g_chr_external.sp_shadow[sp_i[2:0] * 16 +: 8]
                        !== chr_mem[sf_pa]) begin
                        sp_shadow_bad = sp_shadow_bad + 1;
                        $fatal(1, "S2 line %0d dot %0d: shadow slot %0d low plane %02h != chr_mem[%0d] %02h",
                               sl_b, dot_b, sp_i,
                               dut_b.g_chr_external.sp_shadow[sp_i[2:0] * 16 +: 8],
                               sf_pa, chr_mem[sf_pa]);
                    end
                    if (dut_b.g_chr_external.sp_shadow[sp_i[2:0] * 16 + 8 +: 8]
                        !== chr_mem[sf_pa + 13'd8]) begin
                        sp_shadow_bad = sp_shadow_bad + 1;
                        $fatal(1, "S2 line %0d dot %0d: shadow slot %0d high plane %02h != chr_mem[%0d] %02h",
                               sl_b, dot_b, sp_i,
                               dut_b.g_chr_external.sp_shadow[sp_i[2:0] * 16 + 8 +: 8],
                               sf_pa + 13'd8, chr_mem[sf_pa + 13'd8]);
                    end
                    sp_shadow_ok = sp_shadow_ok + 1;
                    if (run_bg == 1'b0)
                        case_sp_shadow = case_sp_shadow + 1;
                end
            end
            sf_shadow_q = dut_b.g_chr_external.sp_shadow_valid;

            if (dot_a == 9'd340) begin
                if (frame_cnt >= WARMUP_FRAMES) begin
                    if (line_trig !== exp_tiles)
                        $fatal(1, "A2 line %0d: tile fetches %0d != %0d (fine_x=%0d mask=%02h)",
                               sl_a, line_trig, exp_tiles, cfg_fx, cfg_mask);
                    if (line_req !== exp_req)
                        $fatal(1, "A2 line %0d: chr_req cycles %0d != %0d (fine_x=%0d mask=%02h)",
                               sl_a, line_req, exp_req, cfg_fx, cfg_mask);
                    if (sp_line_req !== 16)
                        $fatal(1, "A5 line %0d: sprite chr_req cycles %0d != 16 (fine_x=%0d mask=%02h)",
                               sl_a, sp_line_req, cfg_fx, cfg_mask);
                    if (sl_a < 240) begin
                        a_tiles = line_win + ((cfg_fx != 0) ? 1 : 0);
                        if (a_tiles !== line_trig + (1 - exp_first))
                            $fatal(1, "A2 line %0d: A displayed tiles %0d != B fetches %0d + skipped first %0d",
                                   sl_a, a_tiles, line_trig, 1 - exp_first);
                    end
                    if (run_bg) begin
                        line_checked = line_checked + 1;
                    end else begin
                        sp_line_checked = sp_line_checked + 1;
                    end
                    case_lines = case_lines + 1;
                end
                line_req = 0;
                line_win = 0;
                sp_line_req = 0;
                line_trig = 0;
                sp_par = ~sp_par;
            end

            if (fd_b === 1'b1) begin
                frame_cnt = frame_cnt + 1;
                case_frames = case_frames + 1;
            end
        end
    endtask

    task run_case;
        input [8*40-1:0] name_str;
        input [7:0] ctrl_v;
        input [7:0] mask_v;
        input [4:0] cx_v;
        input [2:0] fx_v;
        input [4:0] cy_v;
        input [7:0] seed_v;
        input bg_v;
        input [7:0] cmp_v;
        begin
            cfg_ctrl = ctrl_v;
            cfg_mask = mask_v;
            cfg_cx = cx_v;
            cfg_fx = fx_v;
            cfg_cy = cy_v;
            cfg_seed = seed_v;
            run_bg = bg_v;
            cmp_frames = cmp_v;
            set_config;
            if (run_bg)
                load_memory;
            else
                load_sprite_scene;

            exp_mid = (cfg_fx == 0) ? 30 : 31;
            exp_first = cfg_mask[1] ? 1 : 0;
            exp_spill_in = (cfg_fx <= 2) ? 2 : ((cfg_fx <= 4) ? 1 : 0);
            exp_spill_out = exp_spill_in;
            exp_tiles = exp_mid + exp_first + 1;
            exp_req = 2 * exp_tiles;
            if (exp_tiles !== ((cfg_fx == 0) ? 32 : 33) - (1 - exp_first))
                $fatal(1, "internal tile-count rule mismatch: %0d", exp_tiles);
            if (run_bg) begin
                bg_exp_req = exp_req;
                bg_exp_tiles = exp_tiles;
            end

            frame_cnt = 0;
            case_pix = 0;
            case_pix_nz = 0;
            case_req = 0;
            case_trig = 0;
            case_latch = 0;
            case_frames = 0;
            case_lines = 0;
            line_req = 0;
            line_win = 0;
            line_trig = 0;
            case_sp_mism = 0;
            case_sp_px = 0;
            case_sp_dec = 0;
            case_sp_over_bg = 0;
            case_sp_front = 0;
            case_sp_behind = 0;
            case_sp_ovf = 0;
            case_sp_full8 = 0;
            case_sp_beat = 0;
            case_sp_shadow = 0;
            case_sp_latch = 0;
            case_sp_req = 0;
            case_sp_mism_prev = 0;
            if (run_bg)
                phase_str = "bg";
            else
                phase_str = "sprite";
            $display("  case %0s start at %0d:%0d (fine_x=%0d coarse_x=%0d mask=%02h ctrl=%02h phase=%0s scn=%0d)",
                     name_str, sl_b, dot_b, cfg_fx, cfg_cx, cfg_mask, cfg_ctrl,
                     phase_str, sp_scn);
            while (frame_cnt < (WARMUP_FRAMES + cmp_v))
                ce_tick;

            if (run_bg) begin
                $display("  case %0s: frames=%0d pixels=%0d nonzero=%0d fetches=%0d requests=%0d (%0d/line) bg_valid=%0d plane_pairs_verified=%0d lines_checked=%0d",
                         name_str, case_frames, case_pix, case_pix_nz, case_trig, case_req,
                         exp_req, case_latch, case_pairs, case_lines);
            end else begin
                $display("  case %0s: frames=%0d pixels=%0d bg_fetches=%0d bg_requests=%0d sprite_requests=%0d sprite_beat_address_ok=%0d sprite_shadow_bytes_ok=%0d bg_plane_latches=%0d sprite_pixel_dots=%0d sprite_decided=%0d over_transparent_bg=%0d in_front_of_opaque_bg=%0d behind_opaque_bg=%0d exactly8_in_range_dots=%0d overflow_dots=%0d mismatched_pixels=%0d (equals_A_prev_line=%0d)",
                         name_str, case_frames, case_pix, case_trig, case_req,
                         case_sp_beat, case_sp_beat, case_sp_shadow, case_sp_latch,
                         case_sp_px, case_sp_dec, case_sp_over_bg,
                         case_sp_front, case_sp_behind, case_sp_full8,
                         case_sp_ovf, case_sp_mism, case_sp_mism_prev);
            end
            if (run_bg)
                bg_case_latch = case_latch;
            if (case_pix != cmp_v * 240 * 256)
                $fatal(1, "case %0s compared %0d pixels, expected %0d",
                       name_str, case_pix, cmp_v * 240 * 256);
            if (run_bg) begin
                if (case_pix_nz == 0)
                    $fatal(1, "case %0s comparison was vacuous: every pixel index was 0", name_str);
            end else begin
                if (case_sp_px == 0)
                    $fatal(1, "case %0s sprite comparison was vacuous: sprite_pixel was zero on every compared dot", name_str);
                if (case_sp_dec == 0)
                    $fatal(1, "case %0s sprite comparison was vacuous: no compared pixel was decided by an opaque sprite", name_str);
                if (sp_scn == 4) begin
                    if (case_sp_ovf == 0)
                        $fatal(1, "case %0s was built to overflow but raw_sprite_overflow never rose", name_str);
                end else begin
                    if (case_sp_ovf != 0)
                        $fatal(1, "case %0s overflowed (%0d dots) but only scenario 4 has more than 8 sprites in range", name_str, case_sp_ovf);
                end
                if ((sp_scn == 3) || (sp_scn == 9)) begin
                    if (case_sp_full8 == 0)
                        $fatal(1, "case %0s was built with exactly 8 sprites in range but range_count never reached 8", name_str);
                end
            end
            if (case_trig == 0)
                $fatal(1, "case %0s issued no tile fetch at all", name_str);
        end
    endtask

    initial begin
        clk = 1'b0;
        reset = 1'b0;
        ce = 1'b0;
        ce_div = 1;
        reg_cs = 1'b0;
        reg_we = 1'b0;
        reg_addr = 3'd0;
        reg_din = 8'h00;
        chr_rdata_q = 8'h00;
        lo_addr_q = 13'd0;
        hi_addr_q = 13'd0;
        trig_base = 13'd0;
        req_base = 13'd0;
        trig_name = 8'h00;
        latch_pend = 1'b0;
        bg_valid_q = 1'b0;
        bg_busy_q = 1'b0;
        latch_lo = 13'd0;
        latch_hi = 13'd0;
        latch_sl = 9'd0;
        latch_dot = 9'd0;
        frame_cnt = 0;
        pix_cmp = 0;
        pix_nz = 0;
        plo_nz = 0;
        line_req = 0;
        line_win = 0;
        line_trig = 0;
        line_checked = 0;
        req_idx = 0;
        latch_checked = 0;
        addr_checked = 0;
        dropped_trig = 0;
        case_pix = 0;
        case_pix_nz = 0;
        case_req = 0;
        case_trig = 0;
        case_latch = 0;
        case_frames = 0;
        case_lines = 0;
        case_pairs = 0;
        bg_exp_req = 0;
        bg_exp_tiles = 0;
        bg_case_latch = 0;
        run_bg = 1'b1;
        cmp_frames = COMPARE_FRAMES;
        sp_scn = 0;
        sp_pix = 0;
        sp_mism = 0;
        sp_mism_prevline = 0;
        sp_px_true = 0;
        sp_decided = 0;
        sp_over_bg = 0;
        sp_front = 0;
        sp_behind = 0;
        sp_ovf_dots = 0;
        sp_full8_dots = 0;
        sp_beat_ok = 0;
        sp_beat_tot = 0;
        sp_shadow_ok = 0;
        sp_shadow_bad = 0;
        sp_req_cycles = 0;
        sp_latch_checked = 0;
        sp_line_checked = 0;
        sp_diag_shown = 0;
        sp_px_mism = 0;
        sp_prio_mism = 0;
        sp_hitraw_mism = 0;
        sp_ovfraw_mism = 0;
        sp_hitreg_mism = 0;
        sp_ovfreg_mism = 0;
        sp_cnt_mism = 0;
        sp_line_checked_ok = 0;
        sf_pat = 104'd0;
        sf_exp = 14'd0;
        sf_beat = 0;
        sf_shadow_q = 1'b0;
        sf_pa = 13'd0;
        sp_par = 1'b0;
        for (sp_i = 0; sp_i < 256; sp_i = sp_i + 1) begin
            sp_line_pix[0][sp_i] = 4'h0;
            sp_line_pix[1][sp_i] = 4'h0;
        end

        for (k = 0; k < 8192; k = k + 1)
            chr_mem[k] = 8'h00;

        reset = 1'b1;
        repeat (3) @(posedge clk);
        #1 reset = 1'b0;
        ce = 1'b0;
        @(posedge clk);
        #1;

        cfg_ctrl = 8'h00;
        cfg_mask = 8'h00;
        cfg_cx = 5'd0;
        cfg_fx = 3'd0;
        cfg_cy = 5'd0;
        cfg_seed = 8'h00;

        $display("A1 A/B pixel equivalence EXTERNAL_CHR=0 vs 1, background phase %0d compared frames of 240x256, fine_x drives the fetch phase",
                 COMPARE_FRAMES);
        $display("A1 A/B pixel equivalence EXTERNAL_CHR=0 vs 1, sprite phase %0d compared frame(s) of 240x256 over 9 sprite scenarios",
                 SPR_COMPARE_FRAMES);

        ce_div = 1;
        sp_scn = 0;
        run_case("base-fx0-mask1E", 8'h00, 8'h1E, 5'd0, 3'd0, 5'd0, 8'h11, 1'b1, 8'd3);
        run_case("fx3-cx5", 8'h00, 8'h1E, 5'd5, 3'd3, 5'd0, 8'h27, 1'b1, 8'd3);
        run_case("spr16-cx12", 8'h20, 8'h1E, 5'd12, 3'd0, 5'd4, 8'h3D, 1'b1, 8'd3);
        ce_div = 3;
        run_case("cx31-fx7-table1", 8'h10, 8'h1E, 5'd31, 3'd7, 5'd0, 8'h59, 1'b1, 8'd3);
        ce_div = 1;
        run_case("left8clip-mask1C", 8'h00, 8'h1C, 5'd3, 3'd0, 5'd6, 8'h7E, 1'b1, 8'd3);

        sp_scn = 1;
        run_case("sp1-8x8-x0", 8'h00, 8'h1E, 5'd0, 3'd0, 5'd0, 8'h05, 1'b0, 8'd1);
        sp_scn = 2;
        run_case("sp1-8x8-x255", 8'h00, 8'h1E, 5'd4, 3'd0, 5'd2, 8'h13, 1'b0, 8'd1);
        sp_scn = 3;
        run_case("sp8-8x8-limit", 8'h00, 8'h1E, 5'd7, 3'd3, 5'd3, 8'h29, 1'b0, 8'd1);
        sp_scn = 4;
        run_case("sp10-overflow", 8'h00, 8'h1E, 5'd2, 3'd1, 5'd5, 8'h37, 1'b0, 8'd1);
        sp_scn = 5;
        run_case("sp1-hflip", 8'h00, 8'h1E, 5'd11, 3'd0, 5'd1, 8'h41, 1'b0, 8'd1);
        sp_scn = 6;
        run_case("sp1-vflip", 8'h00, 8'h1E, 5'd19, 3'd0, 5'd6, 8'h4B, 1'b0, 8'd1);
        sp_scn = 7;
        run_case("sp1-hvflip", 8'h00, 8'h1E, 5'd23, 3'd0, 5'd7, 8'h53, 1'b0, 8'd1);
        sp_scn = 8;
        run_case("sp1-8x16-oddtile", 8'h20, 8'h1E, 5'd3, 3'd0, 5'd2, 8'h67, 1'b0, 8'd1);
        sp_scn = 9;
        run_case("sp8-8x16-mixprio", 8'h20, 8'h1E, 5'd15, 3'd5, 5'd9, 8'h71, 1'b0, 8'd1);

        $display("S1 sprite self-check: compared_dots=%0d sprite_pixel_nonzero_dots=%0d sprite_decided_pixels=%0d over_transparent_bg=%0d in_front_of_opaque_bg=%0d behind_opaque_bg=%0d exactly8_in_range_dots=%0d overflow_dots=%0d",
                 sp_pix, sp_px_true, sp_decided, sp_over_bg, sp_front,
                 sp_behind, sp_full8_dots, sp_ovf_dots);
        $display("S2 sprite fetch over the whole run: request_beats=%0d address_sequence_ok=%0d shadow_slot_bytes_verified=%0d shadow_byte_mismatches=%0d",
                 sp_beat_tot, sp_beat_ok, sp_shadow_ok, sp_shadow_bad);
        $display("S4 sprite phase: dots where B raw_sprite_overflow rose while A did not: %0d, background lines checked=%0d, background plane pairs verified=%0d",
                 sp_cnt_mism, sp_line_checked, sp_latch_checked);
        $display("S3 A/B sprite observable divergences: mixed_pixel=%0d sprite_pixel=%0d sprite_priority=%0d raw_sprite0_hit=%0d raw_sprite_overflow=%0d registered_sprite0_hit=%0d registered_sprite_overflow=%0d",
                 sp_mism, sp_px_mism, sp_prio_mism, sp_hitraw_mism,
                 sp_ovfraw_mism, sp_hitreg_mism, sp_ovfreg_mism);
        $display("S5 mixed-pixel divergences that B reproduced from A's PREVIOUS scanline: %0d of %0d",
                 sp_mism_prevline, sp_mism);
        if (sp_px_true == 0)
            $fatal(1, "sprite phase was vacuous: sprite_pixel was zero on every compared dot");
        if (sp_decided == 0)
            $fatal(1, "sprite phase was vacuous: no compared pixel was decided by an opaque sprite");
        if (sp_over_bg == 0)
            $fatal(1, "sprite phase never showed a sprite through a transparent background pixel");
        if (sp_front == 0)
            $fatal(1, "sprite phase never showed a sprite in front of an opaque background pixel");
        if (sp_behind == 0)
            $fatal(1, "sprite phase never exercised sprite-behind-background priority");
        if (sp_shadow_bad != 0)
            $fatal(1, "sprite shadow delivered %0d wrong bytes", sp_shadow_bad);
        $display("A1 total compared pixels=%0d nonzero_index=%0d nonzero_A_low_plane_cycles=%0d",
                 pix_cmp, pix_nz, plo_nz);
        $display("A2 lines_checked=%0d total_requests=%0d total_plane_latches=%0d (last case %0d/line from %0d tiles)",
                 line_checked, addr_checked, bg_case_latch, bg_exp_req, bg_exp_tiles);
        $display("A3 verified request addresses=%0d verified latched plane pairs=%0d",
                 addr_checked, latch_checked);
        if (sp_mism != 0 || sp_px_mism != 0 || sp_prio_mism != 0 || sp_hitraw_mism != 0
            || sp_ovfraw_mism != 0 || sp_hitreg_mism != 0 || sp_ovfreg_mism != 0
            || sp_cnt_mism != 0) begin
            $fatal(1, "A/B sprite pixel equivalence FAILED: %0d mixed-pixel, %0d sprite_pixel, %0d sprite_priority, %0d raw hit, %0d raw overflow, %0d registered hit, %0d registered overflow divergences",
                   sp_mism, sp_px_mism, sp_prio_mism, sp_hitraw_mism,
                   sp_ovfraw_mism, sp_hitreg_mism, sp_ovfreg_mism);
        end
        $display("PASS tb_nes_ppu2c02_ext_chr");
        $finish;
    end

    initial begin
        #2000000000;
        $fatal(1, "TB timeout");
    end

endmodule
