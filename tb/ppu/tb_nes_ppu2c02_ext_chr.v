`timescale 1ns/1ps

module tb_nes_ppu2c02_ext_chr;

    localparam integer WARMUP_FRAMES  = 1;
    localparam integer COMPARE_FRAMES = 3;
    localparam integer TOTAL_FRAMES   = WARMUP_FRAMES + COMPARE_FRAMES;

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

    integer frame_cnt;
    integer pix_cmp;
    integer pix_nz;
    integer plo_nz;
    integer line_req;
    integer line_win;
    integer line_trig;
    integer line_checked;
    integer req_idx;
    integer latch_checked;
    integer addr_checked;
    integer dropped_trig;
    integer case_pix;
    integer case_pix_nz;
    integer case_req;
    integer case_trig;
    integer case_latch;
    integer case_pairs;
    integer case_frames;
    integer case_lines;

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
    reg [7:0]  trig_name;
    reg [8:0]  trig_sl;
    reg [8:0]  trig_dot;
    reg [12:0] lo_addr_q;
    reg [12:0] hi_addr_q;
    reg        latch_pend;
    reg        bg_valid_q;
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

    task load_memory;
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
            if (s0_a !== s0_b)
                $fatal(1, "sprite0_hit differs at %0d:%0d: A=%b B=%b", sl_a, dot_a, s0_a, s0_b);
            if (ovf_a !== ovf_b)
                $fatal(1, "sprite_overflow differs at %0d:%0d: A=%b B=%b", sl_a, dot_a, ovf_a, ovf_b);
            if (we_b !== 1'b0 || wdata_b !== 8'h00)
                $fatal(1, "chr_we/chr_wdata not tied low at %0d:%0d", sl_a, dot_a);

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

            if ((frame_cnt >= WARMUP_FRAMES) && (sl_a < 240) && (dot_a < 256)) begin
                if (pidx_a !== pidx_b)
                    $fatal(1, "A1 pixel mismatch frame %0d line %0d dot %0d: A=%0d B=%0d (A planes %02h/%02h, B planes %02h/%02h, A name %02h)",
                           frame_cnt, sl_a, dot_a, pidx_a, pidx_b,
                           dut_a.bg_pattern_low, dut_a.bg_pattern_high,
                           dut_b.bg_pattern_low,
                           dut_b.bg_pattern_high,
                           dut_a.bg_name);
                if (pxx_a !== pxx_b || pxy_a !== pxy_b)
                    $fatal(1, "A1 pixel coords differ at %0d:%0d", sl_a, dot_a);
                if (pv_a !== pv_b)
                    $fatal(1, "A1 pixel_valid differs at %0d:%0d", sl_a, dot_a);
                if (dut_a.bg_pattern_low !== 8'h00)
                    plo_nz = plo_nz + 1;
                if (pidx_a !== 4'h0)
                    pix_nz = pix_nz + 1;
                pix_cmp = pix_cmp + 1;
                case_pix = case_pix + 1;
                if (pidx_a !== 4'h0)
                    case_pix_nz = case_pix_nz + 1;
            end

            if ((sl_a < 240) && (dot_a < 256)) begin
                if (((dot_a + {6'b0, cfg_fx}) % 8) == 0)
                    line_win = line_win + 1;
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

            if (req_b === 1'b1) begin
                if (dut_b.g_chr_external.sp_bus_sel === 1'b1) begin
                    if (addr_b !== dut_b.g_chr_external.sp_chr_addr)
                        $fatal(1, "A3 line %0d dot %0d: sprite beat chr_addr %0d != sp_chr_addr %0d (arbitration mux corrupted the owner address)",
                               sl_b, dot_b, addr_b, dut_b.g_chr_external.sp_chr_addr);
                    sp_line_req = sp_line_req + 1;
                end else begin
                    x_addr = {1'b0, trig_base} + ((req_idx[0] == 1'b0) ? 14'd0 : 14'd8);
                    if (addr_b !== x_addr)
                        $fatal(1, "A3 line %0d dot %0d req %0d (parity %0d): chr_addr %0d != expected %0d; trigger was %0d:%0d name %02h base %0d (live A name %02h cxsum %0d)",
                               sl_b, dot_b, req_idx, req_idx[0], addr_b, x_addr,
                               trig_sl, trig_dot, trig_name, trig_base, dut_a.bg_name, dut_a.bg_coarse_x_sum);
                    if (addr_b !== dut_b.g_chr_external.bg_chr_addr)
                        $fatal(1, "A3 line %0d dot %0d: background beat chr_addr %0d != bg_chr_addr %0d (arbitration mux corrupted the owner address)",
                               sl_b, dot_b, addr_b, dut_b.g_chr_external.bg_chr_addr);
                    addr_checked = addr_checked + 1;
                    if (req_idx[0] == 1'b0)
                        lo_addr_q <= addr_b[12:0];
                    else
                        hi_addr_q <= addr_b[12:0];
                    line_req = line_req + 1;
                    req_idx = req_idx + 1;
                end
                case_req = case_req + 1;
            end

            if ((dut_b.g_chr_external.bg_fetch_due === 1'b1)
                && (dut_b.g_chr_external.chr_fetch_busy === 1'b1)) begin
                dropped_trig = dropped_trig + 1;
                if (frame_cnt >= WARMUP_FRAMES)
                    $fatal(1, "A2 tile trigger dropped at %0d:%0d inside a compared frame (pipeline desync)",
                           sl_b, dot_b);
            end

            if ((dut_b.g_chr_external.chr_fetch_bg_valid === 1'b1) && (bg_valid_q === 1'b0)) begin
                latch_lo = lo_addr_q;
                latch_hi = hi_addr_q;
                latch_sl = sl_b;
                latch_dot = dot_b;
                latch_pend = 1'b1;
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
                    latch_checked = latch_checked + 1;
                    case_pairs = case_pairs + 1;
                end
            end
            bg_valid_q = dut_b.g_chr_external.chr_fetch_bg_valid;

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
                    line_checked = line_checked + 1;
                    case_lines = case_lines + 1;
                end
                line_req = 0;
                line_win = 0;
                sp_line_req = 0;
                line_trig = 0;
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
        begin
            cfg_ctrl = ctrl_v;
            cfg_mask = mask_v;
            cfg_cx = cx_v;
            cfg_fx = fx_v;
            cfg_cy = cy_v;
            cfg_seed = seed_v;
            set_config;
            load_memory;

            exp_mid = (cfg_fx == 0) ? 30 : 31;
            exp_first = cfg_mask[1] ? 1 : 0;
            exp_spill_in = (cfg_fx <= 2) ? 2 : ((cfg_fx <= 4) ? 1 : 0);
            exp_spill_out = exp_spill_in;
            exp_tiles = exp_mid + exp_first + 1;
            exp_req = 2 * exp_tiles;
            if (exp_tiles !== ((cfg_fx == 0) ? 32 : 33) - (1 - exp_first))
                $fatal(1, "internal tile-count rule mismatch: %0d", exp_tiles);

            frame_cnt = 0;
            case_pix = 0;
            case_pix_nz = 0;
            case_req = 0;
            case_trig = 0;
            case_latch = 0;
            case_pairs = 0;
            case_frames = 0;
            case_lines = 0;
            line_req = 0;
            line_win = 0;
            line_trig = 0;
            $display("  case %0s start at %0d:%0d (fine_x=%0d coarse_x=%0d mask=%02h ctrl=%02h)",
                     name_str, sl_b, dot_b, cfg_fx, cfg_cx, cfg_mask, cfg_ctrl);
            while (frame_cnt < TOTAL_FRAMES)
                ce_tick;

            $display("  case %0s: frames=%0d pixels=%0d nonzero=%0d fetches=%0d requests=%0d (%0d/line) bg_valid=%0d plane_pairs_verified=%0d lines_checked=%0d",
                     name_str, case_frames, case_pix, case_pix_nz, case_trig, case_req,
                     exp_req, case_latch, case_pairs, case_lines);
            if (case_pix != COMPARE_FRAMES * 240 * 256)
                $fatal(1, "case %0s compared %0d pixels, expected %0d",
                       name_str, case_pix, COMPARE_FRAMES * 240 * 256);
            if (case_pix_nz == 0)
                $fatal(1, "case %0s comparison was vacuous: every pixel index was 0", name_str);
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
        trig_name = 8'h00;
        latch_pend = 1'b0;
        bg_valid_q = 1'b0;
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

        $display("A1 A/B pixel equivalence EXTERNAL_CHR=0 vs 1, %0d compared frames of 240x256, fine_x drives the fetch phase",
                 COMPARE_FRAMES);

        ce_div = 1;
        run_case("base-fx0-mask1E", 8'h00, 8'h1E, 5'd0, 3'd0, 5'd0, 8'h11);
        run_case("fx3-cx5", 8'h00, 8'h1E, 5'd5, 3'd3, 5'd0, 8'h27);
        run_case("spr16-cx12", 8'h20, 8'h1E, 5'd12, 3'd0, 5'd4, 8'h3D);
        ce_div = 3;
        run_case("cx31-fx7-table1", 8'h10, 8'h1E, 5'd31, 3'd7, 5'd0, 8'h59);
        ce_div = 1;
        run_case("left8clip-mask1C", 8'h00, 8'h1C, 5'd3, 3'd0, 5'd6, 8'h7E);

        $display("A1 total compared pixels=%0d nonzero_index=%0d nonzero_A_low_plane_cycles=%0d",
                 pix_cmp, pix_nz, plo_nz);
        $display("A2 lines_checked=%0d total_requests=%0d total_plane_latches=%0d (last case %0d/line from %0d tiles)",
                 line_checked, addr_checked, case_latch, exp_req, exp_tiles);
        $display("A3 verified request addresses=%0d verified latched plane pairs=%0d",
                 addr_checked, latch_checked);
        $display("PASS tb_nes_ppu2c02_ext_chr");
        $finish;
    end

    initial begin
        #400000000;
        $fatal(1, "TB timeout");
    end

endmodule
