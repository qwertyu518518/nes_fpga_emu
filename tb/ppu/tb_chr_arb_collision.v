`timescale 1ns/1ps

// ============================================================================
// tb_chr_arb_collision : provoke the $2007-CHR-read-arm vs fetch-unit collision
// ----------------------------------------------------------------------------
// WHAT IS UNDER TEST
//   nes_ppu2c02's g_chr_external CHR bus has three masters: the background
//   fetch unit, the sprite fetch unit, and the $2007 CHR read arm
//   (chr_rd_win).  The arbiter gave the read arm STRICT PRIORITY, so an arm that
//   landed on a fetch unit's S_BEAT clk took the address bus, the memory
//   captured the $2007 pattern byte instead of the tile byte, and the fetch unit
//   then consumed that byte unconditionally one ce later with bg_valid asserted.
//   One 8x8 cell of background, or one sprite slot plane, silently wrong.
//
//   No existing bench could see this.  tb_nes_system_v6's W3-10 fatals on any
//   read arm outside a provably invisible set (scanlines 240..260, or
//   bg_pa_enable low with sprites off), and its program is written to keep every
//   $2007 read inside that set, so W3-10 passing says nothing about real play.
//   This bench does the opposite: it streams $2007 CHR reads through the whole
//   visible field with PPUMASK showing background AND sprites, so the reads are
//   visible and the collisions are unavoidable.
//
// THE CADENCE IS NOT INVENTED HERE
//   The read arm's lead is ZERO SLACK and that is a property of the SYSTEM's
//   div_phase cadence, not of this bench:
//       ce_ppu is high at div_phase 0, 4 and 8;
//       nes_system_v6 raises the arm on the single clk whose pre-edge div_phase
//       is 8; the memory registers chr_rdata on every ce_ppu edge; and the
//       consuming $2007 access retires on the ce_ppu edge that ends div_phase 0
//       of the NEXT group.  The sequence after 8 is 9, 10, 11, 0, so NO ce_ppu
//       edge exists strictly between the arm edge and the consume edge.
//   This bench rebuilds exactly that 12-clk window, raises the arm on exactly
//   that clk, and keeps one register access per window, so the arm-to-consume
//   skew here is the skew the silicon has.  Anything that moved the arm to a
//   later ce edge would return a stale byte and C3 below would catch it.
//
// TWO INDEPENDENT PROOFS, PLUS A REFERENCE INSTANCE
//   A1  THE BYTE THE UNIT ASKED FOR.  A fetch unit presents its address in
//       S_ARM and S_BEAT and captures in S_GRAB, one ce after the ce edge at
//       which its chr_req was high.  So the byte it is entitled to is
//       chr_mem[its own chr_addr register] as captured on that edge.  C1 checks,
//       at every consuming beat, that chr_rdata holds exactly that.  This is the
//       defect stated as a check: a beat consumed with a byte captured for
//       another master.  It reads the UNIT's address register, not the muxed
//       bus, so an arbiter that overrode the bus cannot make it pass by
//       redefining the expectation.
//
//   A2  AN INDEPENDENT REFERENCE PPU.  dut_ref is identical to dut_a except
//       that its chr_rd_arm is tied to 1'b0.  It receives the SAME register
//       stimulus, so v_addr, temp_addr, write_toggle and the
//       nametable/palette/OAM writes evolve identically -- a $2007 read
//       increments v_addr whether or not the arm fired -- and its fetch units
//       are never displaced.  C2 compares the rendered pixel dot by dot.  Every
//       difference is, by construction, a corrupted pixel.
//
//   C3  THE READ STILL RETURNS THE RIGHT BYTE.  A fix that protected the fetch
//       units by deferring the arm by one ce would break this.  The check uses
//       the MEASURED 2C02 skew, not an assumed one: the byte latched at read N
//       is the byte the memory captured for read N-1's address.
//
// BENIGN CONTENTION IS NOT WHAT C1 ASSERTS
//   "The arm and a fetch beat both asked for the bus on this ce" is normal and
//   is counted and printed (C4), never fatal.  Only "a fetch unit CONSUMED a
//   beat whose byte was captured for a different master" is fatal (C1).  Those
//   are different things and only the second one is the defect.  C5 then makes
//   the fix's contract explicit: on every arm beat that found a unit mid-beat,
//   that unit's clock enable must have been suppressed, i.e. the beat was
//   DEFERRED, not out-voted.
// ============================================================================

module tb_chr_arb_collision;

    // ------------------------------------------------------------ declarations
    reg        clk;
    reg        reset;
    reg  [3:0] div_phase;

    reg        acc_valid;
    reg  [2:0] acc_addr;
    reg        acc_we;
    reg  [7:0] acc_din;

    reg [7:0]  chr_mem [0:8191];
    reg [7:0]  chr_rdata_a;
    reg [7:0]  chr_rdata_r;

    wire [7:0]  dout_a,  dout_r;
    wire        pv_a,    pv_r;
    wire [7:0]  pxx_a,   pxx_r;
    wire [7:0]  pxy_a,   pxy_r;
    wire [3:0]  pidx_a,  pidx_r;
    wire [7:0]  ppal_a,  ppal_r;
    wire        fd_a,    fd_r;
    wire        vb_a,    vb_r;
    wire        nmi_a,   nmi_r;
    wire [8:0]  dot_a,   dot_r;
    wire [8:0]  sl_a,    sl_r;
    wire [14:0] dv_a,    dv_r;
    wire [14:0] dt_a,    dt_r;
    wire [2:0]  dx_a,    dx_r;
    wire        dw_a,    dw_r;
    wire        s0_a,    s0_r;
    wire        ovf_a,   ovf_r;
    wire [13:0] waddr_a, waddr_r;
    wire        we_a,    we_r;
    wire [7:0]  wdat_a,  wdat_r;
    wire        req_a,   req_r;
    wire [13:0] chr_addr_a;
    wire [13:0] chr_addr_r;

    wire [2:0]  bg_st    = dut_a.g_chr_external.u_chr_fetch.state;
    wire [2:0]  sp_st    = dut_a.g_chr_external.u_sprite_chr_fetch.state;
    wire        bg_mid   = dut_a.g_chr_external.u_chr_fetch.chr_req;
    wire        sp_mid   = dut_a.g_chr_external.u_sprite_chr_fetch.chr_req;
    wire [13:0] bg_qaddr = dut_a.g_chr_external.u_chr_fetch.chr_addr;
    wire [13:0] sp_qaddr = dut_a.g_chr_external.u_sprite_chr_fetch.chr_addr;
    wire [7:0]  bg_lo    = dut_a.g_chr_external.u_chr_fetch.bg_lo;
    wire [7:0]  bg_hi    = dut_a.g_chr_external.u_chr_fetch.bg_hi;
    wire        bg_ce_in = dut_a.g_chr_external.u_chr_fetch.ce;
    wire        sp_ce_in = dut_a.g_chr_external.u_sprite_chr_fetch.ce;
    wire        arm_win  = dut_a.g_chr_external.chr_rd_win;

    wire [1:0]  bus_owner = arm_win ? 2'd1 :
                            (dut_a.g_chr_external.sp_bus_sel ? 2'd2 :
                             (bg_mid ? 2'd3 : 2'd0));

    localparam [2:0] ST_S_GRAB = 3'd4;

    wire       ce = !reset && (div_phase[1:0] == 2'b00);
    wire       reg_cs = (div_phase == 4'd0) && acc_valid;
    wire       chr_rd_arm = (div_phase == 4'd8) && acc_valid && !acc_we &&
                            (acc_addr == 3'd7);
    wire       c3_read_beat = reg_cs && !acc_we && (acc_addr == 3'd7) &&
                              (dut_a.v_addr < 15'h2000);

    reg  [7:0]  bg_want_q;
    reg  [7:0]  sp_want_q;
    reg  [13:0] bg_want_addr_q;
    reg  [13:0] sp_want_addr_q;

    // 16-entry ring of the last ce edges, dumped with any C1 failure so the
    // signature can be read against the beat that produced it.
    localparam integer TR = 16;
    reg [39:0]  tr_bgst  [0:TR-1];
    reg [13:0]  tr_qadr  [0:TR-1];
    reg [13:0]  tr_badr  [0:TR-1];
    reg [7:0]   tr_rdat  [0:TR-1];
    reg [7:0]   tr_want  [0:TR-1];
    reg [7:0]   tr_arm   [0:TR-1];
    reg [7:0]   tr_mid   [0:TR-1];
    integer     tr_idx;
    integer     t;

    task dump_trace;
        begin
            // chronological order: the current edge is at tr_idx, so the oldest
            // of the 16 is the next slot round
            for (t = 0; t < TR; t = t + 1) begin
                $display("C1 TRACE t=%02d bg_st=%0d mid=%02h q_addr=%04h bus_addr=%04h arm=%02h rdata=%02h want=%02h",
                         t,
                         tr_bgst[(tr_idx + 1 + t) % TR][2:0],
                         tr_mid [(tr_idx + 1 + t) % TR],
                         tr_qadr [(tr_idx + 1 + t) % TR],
                         tr_badr [(tr_idx + 1 + t) % TR],
                         tr_arm  [(tr_idx + 1 + t) % TR],
                         tr_rdat [(tr_idx + 1 + t) % TR],
                         tr_want [(tr_idx + 1 + t) % TR]);
            end
        end
    endtask
    reg         c5_prev_arm_bg;
    reg         c5_prev_arm_sp;
    reg         c5_prev_bg_ce;
    reg         c5_prev_sp_ce;

    integer frames;
    integer i;
    integer ntk;

    integer c1_bg_beats, c1_bg_bad, c1_sp_beats, c1_sp_bad;
    integer c2_dots;
    integer c2_pix_diff;
    integer c2_lo_diff;
    integer c2_hi_diff;
    integer c2_flag_diff;
    integer c2_loq_diff;
    integer c2_hiq_diff;
    integer c2_shadow_diff;
    integer c2_shadow_checks;
    integer c2_shadow_late;
    integer c2_first_loq;
    integer c2_ref_opaque;
    integer c2_armed_opaque;
    integer c2_idx_diff;
    integer c3_reads, c3_checked, c3_bad;
    integer c4_arms, c4_arm_bg_collide, c4_arm_sp_collide;
    integer c4_vis_arms;
    integer c5_bg_checked, c5_bg_not_frozen, c5_sp_checked, c5_sp_not_frozen;

    localparam integer MAX_OPS = 64;
    reg  [2:0]  op_addr [0:MAX_OPS-1];
    reg         op_we   [0:MAX_OPS-1];
    reg  [7:0]  op_din  [0:MAX_OPS-1];
    integer n_ops;
    integer op_ptr;
    reg     run_reads;

    // ------------------------------------------------------------- clock / ce
    initial begin
        clk       = 1'b0;
        reset     = 1'b1;
        div_phase = 4'd0;
    end

    always #5 clk = ~clk;

    always @(posedge clk or posedge reset) begin
        if (reset)
            div_phase <= 4'd0;
        else if (div_phase == 4'd11)
            div_phase <= 4'd0;
        else
            div_phase <= div_phase + 4'd1;
    end

    // ------------------------------------------------------------- CHR model
    // The documented contract: chr_rdata is a REGISTERED output and the address
    // is captured on EVERY ce_ppu edge, not only where chr_req is high, so the
    // model registers unconditionally exactly as the platform memory owner must.
    initial begin
        // Every bit position of every byte is a DIFFERENT function of the
        // address, so a byte captured for the wrong address differs from the
        // byte the unit asked for in several bit positions at once, and in
        // bit 7 as well.  A plain address signature is not enough here: this
        // PPU takes ONE bit per plane per pixel, at bg_pattern_bit =
        // 7 - (dot + fine_x) mod 8, so a signature with a constant bit 7 would
        // make one whole column of every tile transparent and hide the damage.
        for (i = 0; i < 8192; i = i + 1)
            chr_mem[i] = {i[4] ^ i[3], i[5] ^ i[2], i[6] ^ i[1], i[7] ^ i[0],
                          i[3] ^ i[2], i[2] ^ i[1], i[1] ^ i[0], i[0]};
    end

    // Both PPUs' on-board memories have no reset path in nes_ppu2c02.v, so an
    // unwritten cell is X.  That matters here rather than being cosmetic:
    // bg_tile_base reads nametable_ram, so an X there makes bg_fetch_unit's
    // chr_addr X, which makes chr_rdata X, which makes bg_lo X -- and an X
    // comparison would hide the very wrong byte this bench exists to catch.
    // The nametable is filled with tile $01 everywhere so the background is
    // opaque over the whole field and no wrong plane byte can be invisible.
    integer j;
    initial begin
        for (j = 0; j < 2048; j = j + 1) begin
            dut_a.nametable_ram[j] = 8'h01;
            dut_r.nametable_ram[j] = 8'h01;
        end
        for (j = 0; j < 256; j = j + 1) begin
            dut_a.oam_ram[j] = 8'h00;
            dut_r.oam_ram[j] = 8'h00;
        end
        for (j = 0; j < 32; j = j + 1) begin
            dut_a.palette_ram[j] = {2'b00, j[3:0], 2'b00};
            dut_r.palette_ram[j] = {2'b00, j[3:0], 2'b00};
        end
        for (j = 0; j < 8192; j = j + 1) begin
            dut_a.chr_ram[j] = 8'h00;
            dut_r.chr_ram[j] = 8'h00;
        end
    end

    always @(posedge clk) begin
        if (ce) begin
            chr_rdata_a <= chr_mem[chr_addr_a[12:0]];
            chr_rdata_r <= chr_mem[chr_addr_r[12:0]];
        end
    end

    // --------------------------------------------------------------- the PPUs
    nes_ppu2c02 #(
        .MIRROR_VERTICAL(1'b0),
        .EXTERNAL_CHR(1'b1)
    ) dut_a (
        .clk(clk), .reset(reset), .ce(ce),
        .reg_cs(reg_cs), .reg_we(acc_we), .reg_addr(acc_addr), .reg_din(acc_din),
        .reg_dout(dout_a), .pixel_valid(pv_a), .pixel_x(pxx_a), .pixel_y(pxy_a),
        .pixel_index(pidx_a), .pixel_pal(ppal_a), .frame_done(fd_a),
        .vblank(vb_a), .nmi_o(nmi_a), .dot(dot_a), .scanline(sl_a),
        .dbg_v(dv_a), .dbg_t(dt_a), .dbg_x(dx_a), .dbg_w(dw_a),
        .dbg_sprite0_hit(s0_a), .dbg_sprite_overflow(ovf_a),
        .chr_waddr(waddr_a), .chr_req(req_a), .chr_addr(chr_addr_a),
        .chr_we(we_a), .chr_wdata(wdat_a),
        .chr_rd_arm(chr_rd_arm), .chr_rdata(chr_rdata_a)
    );

    // The reference.  Identical except chr_rd_arm is tied low, so it never
    // contends and its fetch units always get the byte they asked for.
    nes_ppu2c02 #(
        .MIRROR_VERTICAL(1'b0),
        .EXTERNAL_CHR(1'b1)
    ) dut_r (
        .clk(clk), .reset(reset), .ce(ce),
        .reg_cs(reg_cs), .reg_we(acc_we), .reg_addr(acc_addr), .reg_din(acc_din),
        .reg_dout(dout_r), .pixel_valid(pv_r), .pixel_x(pxx_r), .pixel_y(pxy_r),
        .pixel_index(pidx_r), .pixel_pal(ppal_r), .frame_done(fd_r),
        .vblank(vb_r), .nmi_o(nmi_r), .dot(dot_r), .scanline(sl_r),
        .dbg_v(dv_r), .dbg_t(dt_r), .dbg_x(dx_r), .dbg_w(dw_r),
        .dbg_sprite0_hit(s0_r), .dbg_sprite_overflow(ovf_r),
        .chr_waddr(waddr_r), .chr_req(req_r), .chr_addr(chr_addr_r),
        .chr_we(we_r), .chr_wdata(wdat_r),
        .chr_rd_arm(1'b0), .chr_rdata(chr_rdata_r)
    );

    // ======================================================================
    // C1  THE DECISIVE CHECK: a fetch unit must never CONSUME a beat whose
    //     byte was captured for another master.
    // ======================================================================
    always @(posedge clk) begin
        if (reset) begin
            bg_want_q       <= 8'h00;
            sp_want_q       <= 8'h00;
            bg_want_addr_q  <= 14'd0;
            sp_want_addr_q  <= 14'd0;
            c1_bg_beats     = 0;
            c1_bg_bad       = 0;
            c1_sp_beats     = 0;
            c1_sp_bad       = 0;
            tr_idx          = 0;
        end else if (ce) begin
            // Remember what each unit was entitled to on the beat it asked for.
            // A unit that is frozen for that beat repeats the same address on
            // the next ce, so re-recording it is harmless.
            if (bg_mid !== 1'b0) begin
                bg_want_q      <= chr_mem[bg_qaddr[12:0]];
                bg_want_addr_q <= bg_qaddr;
            end
            if (sp_mid !== 1'b0) begin
                sp_want_q      <= chr_mem[sp_qaddr[12:0]];
                sp_want_addr_q <= sp_qaddr;
            end
            // Blocking stores on purpose: the dump below runs in the same time
            // step, so non-blocking stores would print the window from 16 ce
            // edges ago instead of the window that produced the failure.
            tr_bgst[tr_idx] = {37'd0, bg_st};
            tr_qadr[tr_idx] = bg_qaddr;
            tr_badr[tr_idx] = chr_addr_a;
            tr_rdat[tr_idx] = chr_rdata_a;
            tr_want[tr_idx] = bg_want_q;
            tr_arm [tr_idx] = {7'd0, arm_win};
            tr_mid [tr_idx] = {7'd0, bg_mid};
            if (bg_st === ST_S_GRAB) begin
                c1_bg_beats = c1_bg_beats + 1;
                if (chr_rdata_a !== bg_want_q) begin
                    c1_bg_bad = c1_bg_bad + 1;
                    $display("C1 BG-WRONG-BYTE frame=%0d sl=%0d dot=%0d unit_addr=%04h expected=%02h chr_rdata=%02h bus_addr=%04h owner=%0d",
                             frames, sl_a, dot_a, bg_want_addr_q, bg_want_q,
                             chr_rdata_a, chr_addr_a, bus_owner);
                    if (c1_bg_bad < 3) dump_trace;
                end
            end
            if (sp_st === ST_S_GRAB) begin
                c1_sp_beats = c1_sp_beats + 1;
                if (chr_rdata_a !== sp_want_q) begin
                    c1_sp_bad = c1_sp_bad + 1;
                    $display("C1 SP-WRONG-BYTE frame=%0d sl=%0d dot=%0d unit_addr=%04h expected=%02h chr_rdata=%02h bus_addr=%04h owner=%0d",
                             frames, sl_a, dot_a, sp_want_addr_q, sp_want_q,
                             chr_rdata_a, chr_addr_a, bus_owner);
                    if (c1_sp_bad < 3) dump_trace;
                end
            end
            tr_idx = (tr_idx == TR - 1) ? 0 : tr_idx + 1;
        end
    end

    // ======================================================================
    // C4  BENIGN CONTENTION, counted and NEVER fatal: the arm and a fetch beat
    //     both asking for the bus on one ce is normal arbitration, and the
    //     loser must simply not consume anything.  Deliberately not the same
    //     assertion as C1.
    // ======================================================================
    //     chr_req is high for exactly the S_BEAT clk, so at a ce edge chr_req is
    //     already 1 exactly on the beat that asked for the bus.  It is read here
    //     with no delay: an earlier version delayed it by one ce and then
    //     disagreed with C1 about which beats were mid-beat.
    always @(posedge clk) begin
        if (reset) begin
            c4_arms           = 0;
            c4_arm_bg_collide = 0;
            c4_arm_sp_collide = 0;
            c4_vis_arms       = 0;
        end else if (ce) begin
            if (arm_win !== 1'b0) begin
                c4_arms = c4_arms + 1;
                if (bg_mid !== 1'b0) c4_arm_bg_collide = c4_arm_bg_collide + 1;
                if (sp_mid !== 1'b0) c4_arm_sp_collide = c4_arm_sp_collide + 1;
                // "visible" means the read could have changed a rendered pixel:
                // bg_pa_enable high, or sprites shown below vblank.  EVERY arm in
                // this run is meant to be in that set, which is the whole
                // difference from tb_nes_system_v6's W3-10 program.
                if ((dut_a.bg_pa_enable !== 1'b0) ||
                    ((dut_a.mask_reg[2] !== 1'b0) && (sl_a < 9'd240)))
                    c4_vis_arms = c4_vis_arms + 1;
            end
        end
    end

    // ======================================================================
    // C5  EVERY DISPLACED BEAT WAS DEFERRED, NOT OUT-VOTED.  On the ce AFTER
    //     an arm beat that found a unit mid-beat, that unit's clock enable must
    //     have been low, which is what "the arm never steals a fetch beat" means
    //     in gates.
    // ======================================================================
    always @(posedge clk) begin
        if (reset) begin
            c5_bg_checked    = 0;
            c5_bg_not_frozen = 0;
            c5_sp_checked    = 0;
            c5_sp_not_frozen = 0;
            c5_prev_arm_bg   <= 1'b0;
            c5_prev_arm_sp   <= 1'b0;
            c5_prev_bg_ce    <= 1'b0;
            c5_prev_sp_ce    <= 1'b0;
        end else if (ce) begin
            if (c5_prev_arm_bg !== 1'b0) begin
                c5_bg_checked = c5_bg_checked + 1;
                if (c5_prev_bg_ce !== 1'b0)
                    c5_bg_not_frozen = c5_bg_not_frozen + 1;
            end
            if (c5_prev_arm_sp !== 1'b0) begin
                c5_sp_checked = c5_sp_checked + 1;
                if (c5_prev_sp_ce !== 1'b0)
                    c5_sp_not_frozen = c5_sp_not_frozen + 1;
            end
            c5_prev_arm_bg <= (arm_win !== 1'b0) && (bg_mid !== 1'b0);
            c5_prev_arm_sp <= (arm_win !== 1'b0) && (sp_mid !== 1'b0);
            c5_prev_bg_ce  <= bg_ce_in;
            c5_prev_sp_ce  <= sp_ce_in;
        end
    end

    // ======================================================================
    // C3  THE READ STILL RETURNS THE RIGHT BYTE.  A fix that protected the
    //     fetch units by deferring the arm by one ce would break this, because
    //     there is no ce_ppu edge between the arm edge and the consume edge for
    //     the deferred address to be captured on.
    //
    //     The indexing is the MEASURED one, and it is two accesses deep, not
    //     one.  Read beat N is the ce edge that ends div_phase 0 of window N;
    //     its arm is div_phase 8 of window N-1; the only ce edge between them is
    //     the read beat itself, so chr_rdata holds byte(arm N) AT read beat N,
    //     read_buffer_reg latches byte(arm N) there, and the CPU therefore
    //     latches byte(arm N-1) at read beat N.  That is what tb_nes_system_v6's
    //     W3-2 measures.
    //
    //     The chain is carried as two one-deep hangers rather than a shift
    //     register over arms, because not every $2007 access in this run is a
    //     CHR read: once the reads have walked v_addr past $1FFF the access is
    //     answered from the PPU's own nametable/palette RAM and raises no arm,
    //     so a naive "previous arm" index would silently compare against the
    //     wrong address and blame the rtl for a testbench bookkeeping error.
    // ======================================================================
    reg  [14:0] c3_pend_arm_v_q;
    reg         c3_pend_arm_ok_q;
    reg  [14:0] c3_deliver_v_q;
    reg         c3_deliver_ok_q;

    wire c3_any_2007 = reg_cs && (acc_addr == 3'd7);

    always @(posedge clk) begin
        if (reset) begin
            c3_pend_arm_v_q   <= 15'd0;
            c3_pend_arm_ok_q  <= 1'b0;
            c3_deliver_v_q    <= 15'd0;
            c3_deliver_ok_q   <= 1'b0;
            c3_reads          = 0;
            c3_checked        = 0;
            c3_bad            = 0;
        end else if (ce) begin
            if (c3_read_beat !== 1'b0) begin
                c3_reads = c3_reads + 1;
                if (c3_deliver_ok_q !== 1'b0) begin
                    c3_checked = c3_checked + 1;
                    if (dout_a !== chr_mem[c3_deliver_v_q[12:0]]) begin
                        c3_bad = c3_bad + 1;
                        if (c3_bad < 3)
                            $display("C3 WRONG-BYTE frame=%0d sl=%0d dot=%0d got=%02h want=%02h at %04h",
                                     frames, sl_a, dot_a, dout_a,
                                     chr_mem[c3_deliver_v_q[12:0]],
                                     c3_deliver_v_q);
                    end
                end
            end
            if (c3_any_2007 !== 1'b0) begin
                c3_deliver_v_q   <= c3_pend_arm_v_q;
                c3_deliver_ok_q  <= c3_pend_arm_ok_q && c3_read_beat;
                c3_pend_arm_ok_q <= 1'b0;
            end
            if (arm_win !== 1'b0) begin
                c3_pend_arm_v_q  <= dut_a.v_addr;
                c3_pend_arm_ok_q <= 1'b1;
            end
        end
    end

    // ======================================================================
    // C2  PIXEL A/B AGAINST THE REFERENCE PPU.  Same stimulus, same v_addr
    //     evolution, arm on one side only.  c2_lo/c2_hi/c2_flag are REPORTED,
    //     not fatal: with a correct fix the armed instance's bg_valid pulses one
    //     ce later than the reference's on a deferred tile, so those register
    //     comparisons see the retiming.  The pixel is the thing that must not
    //     change, and that is what is fatal.
    // ======================================================================
    always @(posedge clk) begin
        if (reset) begin
            c2_dots      = 0;
            c2_pix_diff  = 0;
            c2_lo_diff   = 0;
            c2_hi_diff   = 0;
            c2_flag_diff = 0;
            c2_loq_diff  = 0;
            c2_hiq_diff  = 0;
            c2_shadow_diff = 0;
            c2_shadow_checks = 0;
            c2_shadow_late = 0;
            c2_first_loq = 0;
            c2_ref_opaque = 0;
            c2_armed_opaque = 0;
            c2_idx_diff = 0;
        end else if (ce) begin
            if ((dot_a < 9'd256) && (sl_a < 9'd240)) begin
                c2_dots = c2_dots + 1;
                if (dut_r.bg_pattern_index !== 2'b00) c2_ref_opaque = c2_ref_opaque + 1;
                if (dut_a.bg_pattern_index !== 2'b00) c2_armed_opaque = c2_armed_opaque + 1;
                if (dut_a.bg_pattern_index !== dut_r.bg_pattern_index) begin
                    c2_idx_diff = c2_idx_diff + 1;
                    if (c2_idx_diff < 4)
                        $display("C2 PATTERN-INDEX-DIFF frame=%0d sl=%0d dot=%0d armed=%0b reference=%0b armed planes=%02h/%02h reference planes=%02h/%02h",
                                 frames, sl_a, dot_a, dut_a.bg_pattern_index,
                                 dut_r.bg_pattern_index,
                                 dut_a.g_chr_external.bg_lo_q,
                                 dut_a.g_chr_external.bg_hi_q,
                                 dut_r.g_chr_external.bg_lo_q,
                                 dut_r.g_chr_external.bg_hi_q);
                end
                if ((pidx_a !== pidx_r) || (ppal_a !== ppal_r)) begin
                    c2_pix_diff = c2_pix_diff + 1;
                    if (c2_pix_diff < 8)
                        $display("C2 PIXEL-DIFF frame=%0d sl=%0d dot=%0d x=%0d y=%0d armed=%02h reference=%02h armed_bg=%02h/%02h reference_bg=%02h/%02h",
                                 frames, sl_a, dot_a, pxx_a, pxy_a,
                                 ppal_a, ppal_r, bg_lo, bg_hi, bg_ref_lo, bg_ref_hi);
                end
            end
            if (bg_lo !== bg_ref_lo) c2_lo_diff = c2_lo_diff + 1;
            if (bg_hi !== bg_ref_hi) c2_hi_diff = c2_hi_diff + 1;
            if ((s0_a !== s0_r) || (ovf_a !== ovf_r)) c2_flag_diff = c2_flag_diff + 1;
            if ((dut_a.g_chr_external.bg_lo_q !==
                 dut_r.g_chr_external.bg_lo_q) ||
                (dut_a.g_chr_external.bg_hi_q !==
                 dut_r.g_chr_external.bg_hi_q)) begin
                if (c2_first_loq == 0) begin
                    c2_first_loq = 1;
                    $display("C2 FIRST-LATCH-DIFF frame=%0d sl=%0d dot=%0d armed bg_lo_q=%02h bg_hi_q=%02h  reference bg_lo_q=%02h bg_hi_q=%02h  armed pixel=%02h reference pixel=%02h",
                             frames, sl_a, dot_a,
                             dut_a.g_chr_external.bg_lo_q,
                             dut_a.g_chr_external.bg_hi_q,
                             dut_r.g_chr_external.bg_lo_q,
                             dut_r.g_chr_external.bg_hi_q,
                             ppal_a, ppal_r);
                end
                c2_loq_diff = c2_loq_diff + 1;
            end
            if (dut_a.g_chr_external.sp_shadow !==
                dut_r.g_chr_external.sp_shadow)
                c2_shadow_diff = c2_shadow_diff + 1;
            // A deferred sprite beat shifts that unit's 16 shadow writes one ce
            // later, so the two shadows differ WHILE the line is being written.
            // What has to hold is that they agree once the line's sprites are
            // done, so that is what is asserted: at dot 320 the prefetch is long
            // finished (it starts at dot 257 and costs 35 ce, about 12 dots) and
            // every sprite byte for the next line has landed in both.
            if ((dot_a == 9'd320) && (sl_a < 9'd240)) begin
                c2_shadow_checks = c2_shadow_checks + 1;
                if (dut_a.g_chr_external.sp_shadow !==
                        dut_r.g_chr_external.sp_shadow ||
                    dut_a.g_chr_external.sp_shadow_valid !==
                        dut_r.g_chr_external.sp_shadow_valid) begin
                    c2_shadow_late = c2_shadow_late + 1;
                    if (c2_shadow_late < 3)
                        $display("C2 SHADOW-NOT-CONVERGED frame=%0d sl=%0d dot=320 armed %032h valid=%b, reference %032h valid=%b",
                                 frames, sl_a,
                                 dut_a.g_chr_external.sp_shadow,
                                 dut_a.g_chr_external.sp_shadow_valid,
                                 dut_r.g_chr_external.sp_shadow,
                                 dut_r.g_chr_external.sp_shadow_valid);
                end
            end
        end
    end

    wire [7:0] bg_ref_lo = dut_r.g_chr_external.u_chr_fetch.bg_lo;
    wire [7:0] bg_ref_hi = dut_r.g_chr_external.u_chr_fetch.bg_hi;

    // ======================================================================
    // Access sequencer: one PPU access per div_phase window, then an
    // unconditional stream of $2007 CHR reads.
    // ======================================================================
    task set_op;
        input integer idx;
        input [2:0]  a;
        input        w;
        input [7:0]  d;
        begin
            op_addr[idx] = a;
            op_we[idx]   = w;
            op_din[idx]  = d;
        end
    endtask

    integer n_ops_init;

    task build_script;
        begin
            n_ops_init = 0;
            set_op(n_ops_init, 3'd0, 1'b1, 8'h00); n_ops_init = n_ops_init + 1;
            set_op(n_ops_init, 3'd1, 1'b1, 8'h00); n_ops_init = n_ops_init + 1;
            set_op(n_ops_init, 3'd5, 1'b1, 8'h00); n_ops_init = n_ops_init + 1;
            set_op(n_ops_init, 3'd5, 1'b1, 8'h00); n_ops_init = n_ops_init + 1;
            set_op(n_ops_init, 3'd6, 1'b1, 8'h00); n_ops_init = n_ops_init + 1;
            set_op(n_ops_init, 3'd6, 1'b1, 8'h00); n_ops_init = n_ops_init + 1;
            for (ntk = 0; ntk < 32; ntk = ntk + 1) begin
                set_op(n_ops_init, 3'd7, 1'b1, 8'h01);
                n_ops_init = n_ops_init + 1;
            end
            set_op(n_ops_init, 3'd6, 1'b1, 8'h3F); n_ops_init = n_ops_init + 1;
            set_op(n_ops_init, 3'd6, 1'b1, 8'h00); n_ops_init = n_ops_init + 1;
            set_op(n_ops_init, 3'd7, 1'b1, 8'h00); n_ops_init = n_ops_init + 1;
            set_op(n_ops_init, 3'd7, 1'b1, 8'h02); n_ops_init = n_ops_init + 1;
            set_op(n_ops_init, 3'd7, 1'b1, 8'h04); n_ops_init = n_ops_init + 1;
            set_op(n_ops_init, 3'd7, 1'b1, 8'h06); n_ops_init = n_ops_init + 1;
            set_op(n_ops_init, 3'd3, 1'b1, 8'h00); n_ops_init = n_ops_init + 1;
            set_op(n_ops_init, 3'd4, 1'b1, 8'd50); n_ops_init = n_ops_init + 1;
            set_op(n_ops_init, 3'd4, 1'b1, 8'd1);  n_ops_init = n_ops_init + 1;
            set_op(n_ops_init, 3'd4, 1'b1, 8'd0);  n_ops_init = n_ops_init + 1;
            set_op(n_ops_init, 3'd4, 1'b1, 8'd20); n_ops_init = n_ops_init + 1;
            set_op(n_ops_init, 3'd0, 1'b1, 8'h00); n_ops_init = n_ops_init + 1;
            set_op(n_ops_init, 3'd1, 1'b1, 8'h1E); n_ops_init = n_ops_init + 1;
        end
    endtask

    always @(posedge clk) begin
        if (reset) begin
            run_reads <= 1'b0;
            op_ptr    <= 0;
            acc_valid <= 1'b0;
            acc_addr  <= 3'd0;
            acc_we    <= 1'b0;
            acc_din   <= 8'h00;
        end else if (ce) begin
            if (!run_reads) begin
                if (op_ptr < n_ops) begin
                    acc_valid <= 1'b1;
                    acc_addr  <= op_addr[op_ptr];
                    acc_we    <= op_we[op_ptr];
                    acc_din   <= op_din[op_ptr];
                    op_ptr    <= op_ptr + 1;
                end else begin
                    run_reads <= 1'b1;
                    acc_valid <= 1'b1;
                    acc_addr  <= 3'd7;
                    acc_we    <= 1'b0;
                    acc_din   <= 8'h00;
                end
            end
        end
    end

    always @(posedge clk) begin
        if (!reset && ce && fd_a) begin
            frames = frames + 1;
            if (frames >= 3) begin
                $display("--------------------------------------------------------------");
                $display("C4 CONTENTION, benign and counted: arms=%0d  collided with a background mid-beat=%0d  with a sprite mid-beat=%0d",
                         c4_arms, c4_arm_bg_collide, c4_arm_sp_collide);
                $display("C4 arms that landed where a rendered pixel could change: %0d of %0d  (this run has NO invisible-set guard; that is the point)",
                         c4_vis_arms, c4_arms);
                $display("C5 DISPLACED-BEAT-DEFERRED: bg checks=%0d ce-not-suppressed=%0d   sp checks=%0d ce-not-suppressed=%0d",
                         c5_bg_checked, c5_bg_not_frozen,
                         c5_sp_checked, c5_sp_not_frozen);
                $display("C1 CONSUMED-THE-BYTE-IT-ASKED-FOR: bg consuming beats=%0d wrong=%0d   sp consuming beats=%0d wrong=%0d",
                         c1_bg_beats, c1_bg_bad, c1_sp_beats, c1_sp_bad);
                $display("C3 READ-RETURNED-THE-RIGHT-BYTE: reads=%0d checked=%0d wrong=%0d",
                         c3_reads, c3_checked, c3_bad);
                $display("C2 PIXEL-AB-AGAINST-REFERENCE: visible dots=%0d pixel diffs=%0d (reported-only bg_lo retimings=%0d bg_hi=%0d sprite-flag=%0d)",
                         c2_dots, c2_pix_diff, c2_lo_diff, c2_hi_diff, c2_flag_diff);
                $display("C2 LATCH-DIFFERENCE: bg_lo_q/bg_hi_q differ on %0d ce, sprite shadow differs on %0d ce; sprite shadow checked at dot 320 of %0d visible lines, still differing on %0d",
                         c2_loq_diff, c2_shadow_diff, c2_shadow_checks, c2_shadow_late);
                $display("C2 VISIBILITY-CENSUS: reference bg opaque on %0d of %0d visible dots, armed on %0d; bg_pattern_index differs on %0d dots",
                         c2_ref_opaque, c2_dots, c2_armed_opaque, c2_idx_diff);
                if (c4_arm_bg_collide + c4_arm_sp_collide < 1)
                    $fatal(1, "SETUP the run provoked ZERO collisions, so it proves nothing");
                if (c4_vis_arms < 1)
                    $fatal(1, "SETUP no read arm landed where a rendered pixel could change, so the run proves nothing");
                if (c1_bg_bad != 0 || c1_sp_bad != 0)
                    $fatal(1, "C1 %0d background and %0d sprite fetch units consumed a byte captured for the $2007 read arm",
                           c1_bg_bad, c1_sp_bad);
                if (c5_bg_not_frozen != 0 || c5_sp_not_frozen != 0)
                    $fatal(1, "C5 %0d background and %0d sprite beats were out-voted rather than deferred",
                           c5_bg_not_frozen, c5_sp_not_frozen);
                if (c2_pix_diff != 0)
                    $fatal(1, "C2 the armed PPU rendered %0d pixels differently from the unarmed reference",
                           c2_pix_diff);
                if (c2_shadow_late != 0)
                    $fatal(1, "C2 the sprite shadow had not converged by dot 320 on %0d of %0d visible lines",
                           c2_shadow_late, c2_shadow_checks);
                if (c3_bad != 0)
                    $fatal(1, "C3 %0d $2007 CHR reads returned the wrong byte", c3_bad);
                $display("PASS tb_chr_arb_collision");
                $finish;
            end
        end
    end

    initial begin
        build_script;
        n_ops = n_ops_init;
        frames = 0;
        // hold reset over two full frames so dot/scanline and both instances'
        // internal memories are in a known state
        repeat (2 * 357368) @(posedge clk);
        reset <= 1'b0;
    end

    initial begin
        #200000000;
        $fatal(1, "WATCHDOG no frame_done within 200 ms of simulated time");
    end

endmodule
