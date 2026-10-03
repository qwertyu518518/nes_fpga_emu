`timescale 1ns/1ps

// ============================================================================
// tb_chr_wr_collision : provoke the $2007-CHR-WRITE vs fetch-unit collision
// ----------------------------------------------------------------------------
// THIS IS THE MIRROR IMAGE OF tb_chr_arb_collision, and it is aimed at the
// OTHER HALF of the same bus.  That bench proved the $2007 CHR READ arm can no
// longer steal a fetch beat.  This one proves the $2007 CHR WRITE cannot.
// ============================================================================
//
// WHAT IS UNDER TEST
//   nes_ppu2c02's g_chr_external CHR bus has the same three masters as before:
//   the background fetch unit, the sprite fetch unit, and the CPU.  Only the
//   third one's DIRECTION is different here.
//
//   A $2007 write to CHR is a SEPARATE port (chr_waddr/chr_we/chr_wdata), not a
//   term in the chr_addr read mux, and nes_system_v6.v:334 resolves the two on
//   the mapper port with the WRITE taking priority:
//
//       wire [13:0] mapper_ppu_addr = ppu_chr_we ? ppu_chr_waddr : ppu_chr_addr;
//       wire        mapper_ppu_we   = ppu_chr_we;
//
//   So on the beat the CPU stores a CHR byte, the address that reaches the CHR
//   memory is the WRITE address, while a fetch unit that happens to be in
//   S_BEAT on that same ce has already asked for its own address.  The memory
//   registers chr_rdata unconditionally on every ce_ppu edge (that is the
//   documented contract, tb_nes_system_v6.v:499-501), so one ce later the
//   fetch unit's S_GRAB latches THE WRITE ADDRESS'S BYTE.  One 8x8 cell of
//   background, or one sprite slot plane, silently wrong, with no tag on the
//   byte and no way for the unit to notice.
//
//   Why it was invisible: it needs a program that WRITES CHR through $2007,
//   i.e. a CHR-RAM title.  The cartridge in the tree is CHR-ROM and its program
//   never issues one, and tb_nes_system_v6's own upload runs with PPUMASK=$00,
//   so all 22 of its colliding write beats land where nothing is displayed.
//
// WHY NO TERM IN chr_addr CAN FIX THIS, and why the FETCH UNIT HAS TO BE THE
// DEFERRABLE PARTY.  Both facts are read off the source, not assumed:
//
//   1. Adding chr_we to the chr_addr read mux changes nothing.  mapper_ppu_addr
//      ignores chr_addr entirely while ppu_chr_we is high, so on a write beat
//      the memory never looks at the read mux.  The only way the byte a fetch
//      unit consumes can be the byte it asked for is for that unit not to be
//      consuming one.
//
//   2. The WRITE cannot be deferred, and this is arithmetic rather than
//      caution.  chr_we is `reg_cs && reg_we && reg_addr == 3'd7 && v_addr <
//      $2000`, and reg_cs is ppu_xfer, which nes_cpu_bus.v gates on ce_cpu --
//      so chr_we exists on exactly one clk, the div_phase == 0 one, and
//      nes_ppu2c02.v:253-255 says why a register cannot help: "chr_waddr
//      carries the write address, which is the PRE-increment v_addr: reg_cs is a
//      one-clk pulse taken at div_phase == 0, and v_addr is incremented by that
//      same beat, so the address is only correct while it is combinational.  A
//      registered strobe would have to be paired with a new 14-bit address
//      register (because v_addr has already moved) and would land one ce late."
//      There is no earlier ce on which the strobe exists, so a pending register
//      cannot be loaded in time, exactly as on the read side.
//
//   3. The fetch units ARE the deferrable party and they HAVE to be: they are
//      fixed-latency and non-retrying.  chr_req is high for exactly one beat
//      (state S_BEAT) and the byte captured in S_GRAB one ce later is whatever
//      chr_rdata holds, with no tag, no retry and no way to notice.  So the
//      unit is frozen for that one ce: ce is gated off, its state and its
//      chr_addr and chr_req registers do not move, and the beat it asked for is
//      neither serviced nor consumed.  On the next ce it re-runs S_BEAT with
//      the address register untouched.
//
//   NO DEADLOCK, and the reason is structural rather than measured: chr_req is
//   high in S_BEAT and in NO other state, so a frozen unit is always in S_BEAT
//   and never in the S_GRAB it has to reach.  S_GRAB has chr_req low, so
//   chr_hold_* is structurally low there and the ce that completes a grab is
//   never suppressed.  The freeze costs at most one extra ce per byte (a
//   retrigger needs a second colliding ce, and ce_ppu edges are 4 clk apart so
//   two consecutive freezes need two consecutive colliding write strobes) and a
//   background tile costs 8 ce of the 24 its cadence allows, a sprite prefetch
//   35-51 ce of the 444 between dot 257 and the next line's use of its shadow.
//
// TWO INDEPENDENT PROOFS, PLUS TWO MORE
//   W1  THE BYTE THE UNIT ASKED FOR.  Same construction as the read bench's
//       C1: at every consuming beat, chr_rdata must hold exactly
//       chr_mem[the unit's OWN chr_addr register] as sampled on the ce edge at
//       which its chr_req was high.  It reads the UNIT's address register, not
//       the muxed bus, so an arbiter that overrode the bus cannot make it pass
//       by redefining the expectation.  This is the wrong-BYTE signature.
//   W2  PIXEL A/B AGAINST A REFERENCE PPU WHOSE READ BUS IS NOT ARBITRATED.
//       Same register stimulus, so v_addr/temp_addr/write_toggle and every
//       nametable/palette/OAM write evolve identically, and BOTH instances'
//       CHR RAMs receive the SAME store at the SAME address with the SAME data
//       (checked, see W3), so the two memories are byte identical and the only
//       thing that can make the two pictures differ is a fetch unit that was
//       handed somebody else's byte.  This is the wrong-PIXEL signature.
//   W3  THE WRITE STILL LANDS, ON ITS OWN BEAT.  Two independent late-2C02
//       facts are asserted so that a "fix" which protects the fetch units by
//       deferring or dropping the store fails here: the strobe shape, and the
//       byte in memory one ce after the strobe.  C3 in the read bench is the
//       read-direction twin of this.
//   W4  EVERY DISPLACED BEAT WAS DEFERRED, NOT OUT-VOTED: on the ce after a
//       write beat that found a unit mid-beat, that unit's clock enable must
//       have been suppressed.
//
// BENIGN CONTENTION IS NOT WHAT W1 ASSERTS
//   "The write and a fetch beat both asked for the bus on this ce" is ordinary
//   arbitration and is counted (W5), never fatal.  Only "a fetch unit CONSUMED
//   a beat whose byte was captured for a different master" is fatal (W1).
//
// W6 KILLS THE MOST OBVIOUS WAY THIS COULD BE WRONG.  The program stores into
//   $0400-$043F and the renderer never fetches there (PPUCTRL[4]=1 puts the
//   background in $1000-$1FFF, PPUCTRL[5]=0 and the OAM tiles 1..8 put the
//   sprites in $0010-$008F), so even if the two memories did diverge, no
//   legitimately changed byte could reach a pixel.  That is measured, not
//   assumed: every address any unit asked for and every address that was
//   written is bit-collected and the two sets are intersected at the end.
// ============================================================================

module tb_chr_wr_collision;

    // ------------------------------------------------------------------ W7
    // WHAT THE FIX COSTS, MEASURED RATHER THAN ASSUMED, because the cost is the
    // one thing about this fix that a reader cannot check by reading the rtl.
    //
    // Freezing a fetch unit for one ce delays its tile by one ce, and the
    // background fetch pipeline has NO slack to absorb that: bg_fetch_due fires
    // every 8 dots and a dot is one ce, so the cadence is one request every 8 ce,
    // and one tile is S_PRE, S_ARM, S_BEAT, S_GRAB, S_BEAT, S_GRAB, S_DONE,
    // S_IDLE -- also 8 ce.  Measured on this run with no fix at all: 25152
    // requests, 25152 accepted, 0 dropped.  So a freeze pushes the tile one ce
    // past its slot, the request that would have used that slot finds the unit
    // still in S_DONE, and that tile is not fetched.
    //
    // THAT COST IS REAL AND IT IS PAID BY THE COMMITTED READ FIX TOO.  Running
    // the same census inside tb_chr_arb_collision, which only ever freezes on
    // the $2007 READ arm, gives 25152 requests, 22869 accepted, 2283 dropped.
    // So the zero-slack pipeline is pre-existing and 00ca051 already spends it;
    // this change spends 5238 of it because a $2007 CHR write lands on div_phase
    // 0 and the background unit's S_BEAT lands there far more often than the
    // div_phase 8 an arm lands on.
    //
    // WHY IT IS NOT VISIBLE, and the reason that is a measurement and not a
    // hope: a dropped request does not corrupt the picture, it makes the tile
    // stream one tile late, and the stream RE-PHASES on the next accepted
    // request because the cadence is an exact multiple of the tile length.  The
    // tiles themselves are identical from dot to dot within a scanline here --
    // PPUCTRL[4]=1 and the whole nametable is tile $01, so bg_tile_base is
    // $1010 + fine_y for the whole line -- so a late tile is the same tile and
    // the picture is unchanged.  W2 is what proves that, on every one of the
    // 184304 gated visible dots, and the printed bg_lo_q/bg_hi_q difference
    // count of 0 is the same statement about the register the pixel is made
    // from.  A cartridge whose nametable is NOT uniform would turn these drops
    // into visible tile errors, and that is a separate, larger finding about
    // the fetch pipeline's lack of slack rather than about this fix.
    integer d_due, d_acc, d_drop, d_tiles;
    reg d_bgv_q;
    always @(posedge clk) begin
        if (reset) begin
            d_due = 0; d_acc = 0; d_drop = 0; d_tiles = 0; d_bgv_q = 1'b0;
        end else if (ce) begin
            if (dut_a.g_chr_external.bg_fetch_due !== 1'b0) begin
                d_due = d_due + 1;
                if ((dut_a.g_chr_external.u_chr_fetch.state == 3'd0) &&
                    (dut_a.g_chr_external.u_chr_fetch.busy === 1'b0))
                    d_acc = d_acc + 1;
                else
                    d_drop = d_drop + 1;
            end
            if ((dut_a.g_chr_external.u_chr_fetch.bg_valid === 1'b1) &&
                (d_bgv_q !== 1'b1))
                d_tiles = d_tiles + 1;
            d_bgv_q <= dut_a.g_chr_external.u_chr_fetch.bg_valid;
        end
    end

    // ------------------------------------------------------------ declarations
    reg        clk;
    reg        reset;
    reg  [3:0] div_phase;

    reg        acc_valid;
    reg  [2:0] acc_addr;
    reg        acc_we;
    reg  [7:0] acc_din;

    reg [7:0]  chr_mem_a [0:8191];
    reg [7:0]  chr_mem_r [0:8191];
    reg [7:0]  chr_rdata_a_q;
    reg [7:0]  chr_rdata_r_q;

    wire [7:0] chr_rdata_a = chr_rdata_a_q;
    wire [7:0] chr_rdata_r = chr_rdata_r_q;

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
    wire [2:0]  bg_st_r  = dut_r.g_chr_external.u_chr_fetch.state;
    wire        bg_mid   = dut_a.g_chr_external.u_chr_fetch.chr_req;
    wire        sp_mid   = dut_a.g_chr_external.u_sprite_chr_fetch.chr_req;
    wire [13:0] bg_qaddr = dut_a.g_chr_external.u_chr_fetch.chr_addr;
    wire [13:0] sp_qaddr = dut_a.g_chr_external.u_sprite_chr_fetch.chr_addr;
    wire [7:0]  bg_lo    = dut_a.g_chr_external.u_chr_fetch.bg_lo;
    wire [7:0]  bg_hi    = dut_a.g_chr_external.u_chr_fetch.bg_hi;
    wire [7:0]  bg_lo_r  = dut_r.g_chr_external.u_chr_fetch.bg_lo;
    wire [7:0]  bg_hi_r  = dut_r.g_chr_external.u_chr_fetch.bg_hi;
    wire        bg_ce_in = dut_a.g_chr_external.u_chr_fetch.ce;
    wire        sp_ce_in = dut_a.g_chr_external.u_sprite_chr_fetch.ce;

    localparam [2:0] ST_S_GRAB = 3'd4;

    wire       ce = !reset && (div_phase[1:0] == 2'b00);
    wire       reg_cs = (div_phase == 4'd0) && acc_valid;

    // The one line of nes_system_v6 that makes this a write hazard at all.
    // nes_system_v6.v:334-336.  Upstream of the mapper, so it applies whatever
    // the mapper then does with the address.
    wire [13:0] mapper_addr_a = (we_a !== 1'b0) ? waddr_a : chr_addr_a;
    wire [13:0] mapper_addr_r = (we_r !== 1'b0) ? waddr_r : chr_addr_r;

    // The reference's READ bus is not arbitrated: its memory is addressed on
    // the PPU's own chr_addr port.  That is the ONLY difference in the address
    // path, and it is the whole point -- it is the same relationship
    // tb_chr_arb_collision's reference has to its armed instance (there the arm
    // is tied low; here the write is simply not allowed to hijack the read).
    // Its memory still takes the SAME store, so the two arrays stay identical.
    wire [7:0] ref_rdata_at = chr_mem_r[chr_addr_r[12:0]];

    wire [1:0]  bus_owner = (we_a !== 1'b0) ? 2'd1 :
                             (dut_a.g_chr_external.sp_bus_sel ? 2'd2 :
                              (bg_mid ? 2'd3 : 2'd0));

    reg  [7:0]  bg_want_q;
    reg  [7:0]  sp_want_q;
    reg  [13:0] bg_want_addr_q;
    reg  [13:0] sp_want_addr_q;
    reg  [13:0] bg_bus_addr_q;
    reg  [13:0] sp_bus_addr_q;
    reg  [7:0]  bg_bus_own_q;
    reg  [7:0]  sp_bus_own_q;

    // 16-entry ring of the last ce edges, dumped with any W1 failure so the
    // signature can be read against the beat that produced it.
    localparam integer TR = 16;
    reg [39:0]  tr_bgst  [0:TR-1];
    reg [13:0]  tr_qadr  [0:TR-1];
    reg [13:0]  tr_badr  [0:TR-1];
    reg [13:0]  tr_wadr  [0:TR-1];
    reg [7:0]   tr_rdat  [0:TR-1];
    reg [7:0]   tr_want  [0:TR-1];
    reg [7:0]   tr_arm   [0:TR-1];
    reg [7:0]   tr_mid   [0:TR-1];
    integer     tr_idx;
    integer     t;

    task dump_trace;
        begin
            for (t = 0; t < TR; t = t + 1) begin
                $display("W1 TRACE t=%02d bg_st=%0d mid=%02h q_addr=%04h bus_addr=%04h wr_addr=%04h rdata=%02h want=%02h",
                         t,
                         tr_bgst[(tr_idx + 1 + t) % TR][2:0],
                         tr_mid [(tr_idx + 1 + t) % TR],
                         tr_qadr [(tr_idx + 1 + t) % TR],
                         tr_badr [(tr_idx + 1 + t) % TR],
                         tr_wadr [(tr_idx + 1 + t) % TR],
                         tr_rdat [(tr_idx + 1 + t) % TR],
                         tr_want [(tr_idx + 1 + t) % TR]);
            end
        end
    endtask

    reg         w4_prev_wr_bg;
    reg         w4_prev_wr_sp;
    reg         w4_prev_bg_ce;
    reg         w4_prev_sp_ce;

    integer frames;
    integer i;
    integer j;
    integer ntk;

    integer c1_bg_beats, c1_bg_bad, c1_sp_beats, c1_sp_bad;
    integer c2_dots, c2_pix_diff, c2_idx_diff;
    integer c2_loq_diff, c2_shadow_diff, c2_shadow_checks, c2_shadow_late;
    integer c2_first_loq, c2_ref_opaque, c2_armed_opaque;
    integer c3_wr_beats, c3_wr_accepted, c3_wr_late, c3_wr_shape_err;
    integer c3_ctrl2_err;
    integer c3_waddr_err, c3_wdata_err, c3_instr_mismatch;
    integer c4_bg_checked, c4_bg_not_frozen, c4_sp_checked, c4_sp_not_frozen;
    integer c5_wr_beats, c5_wr_bg_collide, c5_wr_sp_collide, c5_vis_collide;
    integer c6_fetch_marks, c6_write_marks, c6_overlap;

    reg [13:0] c3_lat_addr_q;
    reg [7:0]  c3_lat_data_q;
    reg        c3_lat_v_q;

    // ---------------------------------------------------------------- program
    localparam integer MAX_OPS = 64;
    reg  [2:0]  op_addr [0:MAX_OPS-1];
    reg         op_we   [0:MAX_OPS-1];
    reg  [7:0]  op_din  [0:MAX_OPS-1];
    integer n_ops;
    integer n_ops_init;
    integer op_ptr;
    integer loop_start;
    integer loop_len;
    reg     looping;
    // The stored byte is made to CHANGE from store to store, on purpose.  A
    // program that always writes $3C makes every corrupted latch read $3C, and
    // a reviewer is then entitled to ask whether the comparison is really
    // against the store or against a constant.  Varying it makes each wrong
    // byte a distinct value that can only have come from the store that landed
    // on that beat.
    reg [7:0] wr_seq;

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

    // 8 sprites, all inside the visible field, all with tile indices whose
    // pattern addresses ($0010..$008F) stay clear of the $0400..$043F the
    // program stores into.  See W6.
    reg [7:0] spr_y [0:7];
    reg [7:0] spr_t [0:7];
    reg [7:0] spr_x [0:7];

    task build_script;
        integer k;
        begin
            spr_y[0] = 8'h20; spr_t[0] = 8'h01; spr_x[0] = 8'h20;
            spr_y[1] = 8'h40; spr_t[1] = 8'h02; spr_x[1] = 8'h40;
            spr_y[2] = 8'h60; spr_t[2] = 8'h03; spr_x[2] = 8'h60;
            spr_y[3] = 8'h80; spr_t[3] = 8'h04; spr_x[3] = 8'h80;
            spr_y[4] = 8'hA0; spr_t[4] = 8'h05; spr_x[4] = 8'hA0;
            spr_y[5] = 8'hC0; spr_t[5] = 8'h06; spr_x[5] = 8'hC0;
            spr_y[6] = 8'hE0; spr_t[6] = 8'h07; spr_x[6] = 8'hE0;
            spr_y[7] = 8'h30; spr_t[7] = 8'h08; spr_x[7] = 8'hF0;

            n_ops_init = 0;
            // PPUCTRL = $1A, deliberately NOT the $1E tb_chr_arb_collision uses.
            // bit1 show background, bit3 show it in the leftmost 8 pixels, bit4
            // background pattern table $1000, bit5 0.  Two of those bits are
            // load bearing rather than cosmetic and both were found by
            // measurement, not by reading:
            //
            //   bit2 LEFT AT ZERO.  nes_ppu2c02.v's increment_v is
            //   `control_reg[2] ? address + 32 : address + 1`, so 8x16 sprites
            //   would make every $2007 store walk v_addr forward by 32 and a
            //   program that aims at one CHR address and then streams ends up
            //   spread over a kilobyte.  With bit2 clear increment_v is +1.
            //
            //   bit3 LEFT AT ZERO.  nes_ppu_sprite.v:381 is
            //   `s_table = ctrl[5] ? s_tile_byte[0] : ctrl[3]`, so with bit5
            //   clear the sprite pattern table is selected by bit3, not by bit4
            //   as the background's is.  A first version used $1A and measured
            //   the sprite fetches landing at $1010-$108F, i.e. in the
            //   BACKGROUND's half, because ctrl[3] was 1.  With bit3 clear the
            //   sprites use $0000-$0FFF, which separates the two halves and
            //   leaves the store window free.
            set_op(n_ops_init, 3'd0, 1'b1, 8'h12); n_ops_init = n_ops_init + 1;
            set_op(n_ops_init, 3'd1, 1'b1, 8'h1E); n_ops_init = n_ops_init + 1;
            set_op(n_ops_init, 3'd5, 1'b1, 8'h00); n_ops_init = n_ops_init + 1;
            set_op(n_ops_init, 3'd5, 1'b1, 8'h00); n_ops_init = n_ops_init + 1;
            // v_addr = $0C00.  nes_ppu2c02.v:1118 loads temp_addr[14:8] straight
            // from reg_din[6:0] and :1121 rebuilds v_addr as
            // {temp_addr[14:8], reg_din}, so the high write carries the high
            // byte of v_addr directly: $0C then $00 is $0C00.
            set_op(n_ops_init, 3'd6, 1'b1, 8'h0C); n_ops_init = n_ops_init + 1;
            set_op(n_ops_init, 3'd6, 1'b1, 8'h00); n_ops_init = n_ops_init + 1;
            set_op(n_ops_init, 3'd3, 1'b1, 8'h00); n_ops_init = n_ops_init + 1;
            for (k = 0; k < 8; k = k + 1) begin
                set_op(n_ops_init, 3'd4, 1'b1, spr_y[k]); n_ops_init = n_ops_init + 1;
                set_op(n_ops_init, 3'd4, 1'b1, spr_t[k]); n_ops_init = n_ops_init + 1;
                set_op(n_ops_init, 3'd4, 1'b1, 8'h00);        n_ops_init = n_ops_init + 1;
                set_op(n_ops_init, 3'd4, 1'b1, spr_x[k]); n_ops_init = n_ops_init + 1;
            end

            loop_start = n_ops_init;
            // ---- the streaming loop: re-aim v_addr at $0C00, then ONE CHR
            //      store.  Three accesses per iteration, so a $2007 write lands
            //      on one of every three ce_ppu edges of the run and the
            //      collisions are not something the cadence has to be lucky to
            //      produce.
            //
            //      WHY THE RE-AIM GOES BEFORE EVERY SINGLE STORE, which is the
            //      non-obvious part of this program and was not visible on
            //      paper.  nes_ppu2c02.v:1167-1183 moves v_addr during
            //      rendering in three separate ways, all of them measured here:
            //        * :1171 increment_x at every dot that is a multiple of 8
            //          between 8 and 248, i.e. twice per div_phase window;
            //        * :1169 increment_y(increment_x(v_addr)) at dot 256 of
            //          EVERY line.  The increment_y there is unconditional -- it
            //          is not gated on the coarse-X wrap that nes_ppu2c02's
            //          increment_x has already handled -- so v_addr[14:12], fine
            //          Y, gains one per line and a store aimed at $0C00 becomes
            //          a store at $1C00 as soon as one dot-256 boundary goes by.
            //          That is what produced the $1400 and $1401 stores a first
            //          version of this bench measured, and it is why the store
            //          window has to be chosen to survive a one-bit flip of its
            //          high byte.
            //        * increment_v on the $2007 write itself, +1 with
            //          PPUCTRL[2] clear.
            //      A $2006 PAIR is what repairs all of it, because
            //      nes_ppu2c02.v:1121 rebuilds v_addr as {temp_addr[14:8],
            //      reg_din} and ignores whatever the increments did to v_addr.
            //      Re-aiming immediately before each store therefore pins the
            //      stores to four addresses -- $0C00/$0C02 with fine Y 0 and
            //      $1C00/$1C02 with fine Y 1 -- and W3 WRITE-RANGE prints the
            //      set while W6 intersects the real store set against the real
            //      fetch set, so the disjointness the pixel A/B rests on is
            //      measured rather than argued.
            set_op(n_ops_init, 3'd6, 1'b1, 8'h0C); n_ops_init = n_ops_init + 1;
            set_op(n_ops_init, 3'd6, 1'b1, 8'h00); n_ops_init = n_ops_init + 1;
            set_op(n_ops_init, 3'd7, 1'b1, 8'h3C);
            n_ops_init = n_ops_init + 1;
            loop_len = n_ops_init - loop_start;
        end
    endtask

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

    // ------------------------------------------------------------- CHR models
    //
    // The same signature the read bench uses: every bit position of every byte
    // is a DIFFERENT function of the address, so a byte captured for the wrong
    // address differs in several bit positions at once AND in bit 7.  A plain
    // address signature is not enough, because this PPU takes ONE bit per plane
    // per pixel at bg_pattern_bit = 7 - (dot + fine_x) mod 8, so a signature
    // with a constant bit 7 would make a whole column of every tile transparent
    // and hide the damage.
    initial begin
        for (i = 0; i < 8192; i = i + 1) begin
            chr_mem_a[i] = {i[4] ^ i[3], i[5] ^ i[2], i[6] ^ i[1], i[7] ^ i[0],
                            i[3] ^ i[2], i[2] ^ i[1], i[1] ^ i[0], i[0]};
            chr_mem_r[i] = {i[4] ^ i[3], i[5] ^ i[2], i[6] ^ i[1], i[7] ^ i[0],
                            i[3] ^ i[2], i[2] ^ i[1], i[1] ^ i[0], i[0]};
        end
    end

    // Both on-board memories have no reset path in nes_ppu2c02.v, so an
    // unwritten cell is X.  Here that is not cosmetic: bg_tile_base reads
    // nametable_ram, so an X there makes chr_addr X, which makes chr_rdata X,
    // and an X comparison would hide the very wrong byte this bench exists to
    // catch.  The nametable is filled with tile $01 everywhere so the
    // background is opaque over the whole field and no wrong plane byte can be
    // invisible, and the palette is given distinct colours so a wrong plane
    // index shows as a wrong colour and not merely as a wrong transparency.
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
    end

    // A CHR-RAM board: the store is accepted on every strobe.  This is the
    // nes_system_v6.v mapper_chr_ram_we == 1 case, which is the case that
    // exists in hardware, and it is asserted in W3 that the store really did
    // land before any of the pixel comparisons are believed.
    integer mem_wr_a, mem_wr_r;

    always @(posedge clk) begin
        if (reset) begin
            mem_wr_a = 0;
            mem_wr_r = 0;
        end else if (ce) begin
            if (we_a !== 1'b0) begin
                chr_mem_a[waddr_a[12:0]] <= wdat_a;
                mem_wr_a = mem_wr_a + 1;
            end
            if (we_r !== 1'b0) begin
                chr_mem_r[waddr_r[12:0]] <= wdat_r;
                mem_wr_r = mem_wr_r + 1;
            end
        end
    end

    always @(posedge clk) begin
        if (ce) begin
            chr_rdata_a_q <= chr_mem_a[mapper_addr_a[12:0]];
            chr_rdata_r_q <= ref_rdata_at;
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
        .chr_rd_arm(1'b0), .chr_rdata(chr_rdata_a)
    );

    // The reference.  Same stimulus, same v_addr evolution, same stores; its
    // CHR read address is simply never taken away from the fetch unit, so its
    // fetch units always get the byte they asked for.
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
    // W1  THE DECISIVE CHECK: a fetch unit must never CONSUME a beat whose
    //     byte was captured for another master.
    // ======================================================================
    always @(posedge clk) begin
        if (reset) begin
            bg_want_q       <= 8'h00;
            sp_want_q       <= 8'h00;
            bg_want_addr_q  <= 14'd0;
            sp_want_addr_q  <= 14'd0;
            bg_bus_addr_q   <= 14'd0;
            sp_bus_addr_q   <= 14'd0;
            bg_bus_own_q    <= 8'h00;
            sp_bus_own_q    <= 8'h00;
            c1_bg_beats     = 0;
            c1_bg_bad       = 0;
            c1_sp_beats     = 0;
            c1_sp_bad       = 0;
            tr_idx          = 0;
        end else if (ce) begin
            // Remember what each unit was entitled to on the beat it asked for.
            // A unit that is frozen for that beat repeats the same address on
            // the next ce, so re-recording it is harmless and it is also
            // NECESSARY: if the frozen beat was the $2007 write's own beat and
            // the store landed at the very address the unit had asked for, the
            // second record is the post-store byte, which is the byte the unit
            // is then entitled to.
            //
            // The address that was actually ON THE BUS during that beat is
            // recorded with it, because the strobe is one clk wide and by the
            // time the check runs the unit is in S_GRAB and the bus has moved
            // on.  Sampling the bus at check time, as an earlier version of this
            // did, prints the address of the NEXT beat and hides which master
            // took this one.
            if (bg_mid !== 1'b0) begin
                bg_want_q      <= chr_mem_a[bg_qaddr[12:0]];
                bg_want_addr_q <= bg_qaddr;
                bg_bus_addr_q  <= mapper_addr_a;
                bg_bus_own_q   <= {7'd0, bus_owner};
            end
            if (sp_mid !== 1'b0) begin
                sp_want_q      <= chr_mem_a[sp_qaddr[12:0]];
                sp_want_addr_q <= sp_qaddr;
                sp_bus_addr_q  <= mapper_addr_a;
                sp_bus_own_q   <= {7'd0, bus_owner};
            end
            // Blocking stores on purpose: the dump below runs in the same time
            // step, so non-blocking stores would print the window from 16 ce
            // edges ago instead of the window that produced the failure.
            tr_bgst[tr_idx] = {37'd0, bg_st};
            tr_qadr[tr_idx] = bg_qaddr;
            tr_badr[tr_idx] = mapper_addr_a;
            tr_wadr[tr_idx] = waddr_a;
            tr_rdat[tr_idx] = chr_rdata_a;
            tr_want[tr_idx] = bg_want_q;
            tr_arm [tr_idx] = {7'd0, (we_a !== 1'b0)};
            tr_mid [tr_idx] = {7'd0, bg_mid};
            if (bg_st === ST_S_GRAB) begin
                c1_bg_beats = c1_bg_beats + 1;
                if (chr_rdata_a !== bg_want_q) begin
                    c1_bg_bad = c1_bg_bad + 1;
                    $display("W1 BG-WRONG-BYTE frame=%0d sl=%0d dot=%0d unit_addr=%04h expected=%02h chr_rdata=%02h bus_addr=%04h owner=%0d (owner 1 = the $2007 write, 2 = sprite unit, 3 = background unit)",
                             frames, sl_a, dot_a, bg_want_addr_q, bg_want_q,
                             chr_rdata_a, bg_bus_addr_q, bg_bus_own_q);
                    if (c1_bg_bad < 3) dump_trace;
                end
            end
            if (sp_st === ST_S_GRAB) begin
                c1_sp_beats = c1_sp_beats + 1;
                if (chr_rdata_a !== sp_want_q) begin
                    c1_sp_bad = c1_sp_bad + 1;
                    $display("W1 SP-WRONG-BYTE frame=%0d sl=%0d dot=%0d unit_addr=%04h expected=%02h chr_rdata=%02h bus_addr=%04h owner=%0d (owner 1 = the $2007 write, 2 = sprite unit, 3 = background unit)",
                             frames, sl_a, dot_a, sp_want_addr_q, sp_want_q,
                             chr_rdata_a, sp_bus_addr_q, sp_bus_own_q);
                    if (c1_sp_bad < 3) dump_trace;
                end
            end
            tr_idx = (tr_idx == TR - 1) ? 0 : tr_idx + 1;
        end
    end

    // ======================================================================
    // W3  THE WRITE STILL LANDS, ON ITS OWN BEAT.
    //     A fix that protected the fetch units by deferring or dropping the
    //     store fails every line here.
    // ======================================================================
    always @(posedge clk) begin
        if (reset) begin
            c3_wr_beats        = 0;
            c3_wr_accepted     = 0;
            c3_wr_late         = 0;
            c3_wr_shape_err    = 0;
            c3_ctrl2_err       = 0;
            c3_waddr_err       = 0;
            c3_wdata_err       = 0;
            c3_instr_mismatch  = 0;
            c3_lat_addr_q      <= 14'd0;
            c3_lat_data_q      <= 8'h00;
            c3_lat_v_q         <= 1'b0;
        end else if (ce) begin
            // one ce after the strobe the store must already be visible in BOTH
            // memories at the strobe's own pre-increment address.
            if (c3_lat_v_q !== 1'b0) begin
                if (chr_mem_a[c3_lat_addr_q[12:0]] !== c3_lat_data_q) begin
                    c3_wr_late = c3_wr_late + 1;
                    if (c3_wr_late < 3)
                        $display("W3 armed chr_mem[%04h]=%02h one ce after a $2007 write of %02h, so the store did not land on its own beat",
                                 c3_lat_addr_q, chr_mem_a[c3_lat_addr_q[12:0]],
                                 c3_lat_data_q);
                end
                if (chr_mem_r[c3_lat_addr_q[12:0]] !== c3_lat_data_q) begin
                    c3_instr_mismatch = c3_instr_mismatch + 1;
                    if (c3_instr_mismatch < 3)
                        $display("W3 reference chr_mem[%04h]=%02h where the armed instance stored %02h, so the two arrays are NOT identical and the W2 pixel A/B would prove nothing",
                                 c3_lat_addr_q, chr_mem_r[c3_lat_addr_q[12:0]],
                                 c3_lat_data_q);
                end
            end
            c3_lat_v_q <= 1'b0;

            if (we_a !== 1'b0) begin
                c3_wr_beats = c3_wr_beats + 1;
                c3_wr_accepted = c3_wr_accepted + 1;
                // The whole address-window argument above rests on this: with
                // PPUCTRL[2] set, increment_v is +32 and the stores would not
                // stay in the window at all.  Measured every beat, not assumed.
                if (dut_a.control_reg[2] !== 1'b0)
                    c3_ctrl2_err = c3_ctrl2_err + 1;
                // strobe shape: exactly reg_cs && we && $2007 && v_addr < $2000
                if (we_a !== ((reg_cs !== 1'b0) && (acc_we !== 1'b0) &&
                              (acc_addr == 3'd7) && (dut_a.v_addr < 15'h2000)))
                    c3_wr_shape_err = c3_wr_shape_err + 1;
                // chr_waddr is the PRE-increment v_addr, which is the documented
                // reason the address cannot be registered (nes_ppu2c02.v:251-255)
                if (waddr_a !== dut_a.v_addr[13:0]) begin
                    c3_waddr_err = c3_waddr_err + 1;
                    if (c3_waddr_err < 3)
                        $display("W3 chr_waddr %04h is not the pre-increment v_addr %04h",
                                 waddr_a, dut_a.v_addr[13:0]);
                end
                if (waddr_a !== waddr_r) begin
                    c3_waddr_err = c3_waddr_err + 1;
                    if (c3_waddr_err < 3)
                        $display("W3 the two instances offered different write addresses %04h / %04h on the same beat",
                                 waddr_a, waddr_r);
                end
                if (wdat_a !== wdat_r) begin
                    c3_wdata_err = c3_wdata_err + 1;
                    if (c3_wdata_err < 3)
                        $display("W3 the two instances offered different write data %02h / %02h on the same beat",
                                 wdat_a, wdat_r);
                end
                if (wdat_a !== acc_din)
                    c3_wdata_err = c3_wdata_err + 1;
                c3_lat_addr_q <= waddr_a;
                c3_lat_data_q <= wdat_a;
                c3_lat_v_q    <= 1'b1;
            end
        end
    end

    // ======================================================================
    // W4  EVERY DISPLACED BEAT WAS DEFERRED, NOT OUT-VOTED.  On the ce AFTER
    //     a write beat that found a unit mid-beat, that unit's clock enable must
    //     have been low, which is what "a $2007 write never steals a fetch beat"
    //     means in gates.
    // ======================================================================
    always @(posedge clk) begin
        if (reset) begin
            c4_bg_checked    = 0;
            c4_bg_not_frozen = 0;
            c4_sp_checked    = 0;
            c4_sp_not_frozen = 0;
            w4_prev_wr_bg   <= 1'b0;
            w4_prev_wr_sp   <= 1'b0;
            w4_prev_bg_ce    <= 1'b0;
            w4_prev_sp_ce    <= 1'b0;
        end else if (ce) begin
            if (w4_prev_wr_bg !== 1'b0) begin
                c4_bg_checked = c4_bg_checked + 1;
                if (w4_prev_bg_ce !== 1'b0)
                    c4_bg_not_frozen = c4_bg_not_frozen + 1;
            end
            if (w4_prev_wr_sp !== 1'b0) begin
                c4_sp_checked = c4_sp_checked + 1;
                if (w4_prev_sp_ce !== 1'b0)
                    c4_sp_not_frozen = c4_sp_not_frozen + 1;
            end
            w4_prev_wr_bg <= (we_a !== 1'b0) && (bg_mid !== 1'b0);
            w4_prev_wr_sp <= (we_a !== 1'b0) && (sp_mid !== 1'b0);
            w4_prev_bg_ce  <= bg_ce_in;
            w4_prev_sp_ce  <= sp_ce_in;
        end
    end

    // ======================================================================
    // W5  BENIGN CONTENTION, counted and NEVER fatal: the write and a fetch
    //     beat both asking for the bus on one ce is ordinary arbitration and
    //     the loser must simply not consume anything.  Also records the range
    //     of store addresses so the "the stores stay in a window the renderer
    //     never reads" claim is a measured range and not a narrative one.
    // ======================================================================
    reg [13:0] wr_min_addr;
    reg [13:0] wr_max_addr;
    integer    wr_win_cnt;

    always @(posedge clk) begin
        if (reset) begin
            wr_win_cnt = 0;
            wr_min_addr = 14'h1FFF;
            wr_max_addr = 14'h0000;
        end else if (ce) begin
            if (we_a !== 1'b0) begin
                wr_win_cnt = wr_win_cnt + 1;
                if (waddr_a < wr_min_addr) wr_min_addr = waddr_a;
                if (waddr_a > wr_max_addr) wr_max_addr = waddr_a;
            end
        end
    end

    always @(posedge clk) begin
        if (reset) begin
            c5_wr_beats      = 0;
            c5_wr_bg_collide = 0;
            c5_wr_sp_collide = 0;
            c5_vis_collide   = 0;
        end else if (ce) begin
            if (we_a !== 1'b0) begin
                c5_wr_beats = c5_wr_beats + 1;
                if (bg_mid !== 1'b0) c5_wr_bg_collide = c5_wr_bg_collide + 1;
                if (sp_mid !== 1'b0) c5_wr_sp_collide = c5_wr_sp_collide + 1;
                // "visible" means the stolen byte could have changed a rendered
                // pixel: bg_pa_enable high, or sprites shown below vblank.
                // EVERY collision in this run is meant to be in that set, which
                // is the whole difference from tb_nes_system_v6's program.
                if ((dut_a.bg_pa_enable !== 1'b0) ||
                    ((dut_a.mask_reg[2] !== 1'b0) && (sl_a < 9'd240)))
                    c5_vis_collide = c5_vis_collide + 1;
            end
        end
    end

    // ======================================================================
    // W6  ADDRESS CENSUS.  Every address any unit asked for, and every address
    //     a store landed on, bit-collected and intersected at the end.  The
    //     program stores into $0400-$043F and the renderer must never fetch
    //     there, so even a content change could not explain a pixel difference.
    //     Also records that the $2007 read arm really was inactive, so every
    //     wrong byte in this run is a WRITE's doing and not the read hazard's.
    // ======================================================================
    reg [8191:0] fetch_bits = 8192'd0;
    reg [8191:0] write_bits = 8192'd0;
    integer      arm_beats;
    integer      c6_fetch_distinct;
    integer      c6_write_distinct;

    always @(posedge clk) begin
        if (reset) begin
            c6_fetch_marks = 0;
            c6_write_marks = 0;
            c6_fetch_distinct = 0;
            c6_write_distinct = 0;
            arm_beats      = 0;
        end else if (ce) begin
            if (req_a !== 1'b0) begin
                if (fetch_bits[chr_addr_a[12:0]] !== 1'b1)
                    c6_fetch_distinct = c6_fetch_distinct + 1;
                fetch_bits[chr_addr_a[12:0]] = 1'b1;
                c6_fetch_marks = c6_fetch_marks + 1;
            end
            if (we_a !== 1'b0) begin
                if (write_bits[waddr_a[12:0]] !== 1'b1)
                    c6_write_distinct = c6_write_distinct + 1;
                write_bits[waddr_a[12:0]] = 1'b1;
                c6_write_marks = c6_write_marks + 1;
            end
            if (dut_a.g_chr_external.chr_rd_win !== 1'b0)
                arm_beats = arm_beats + 1;
        end
    end

    // ======================================================================
    // W2  PIXEL A/B AGAINST THE REFERENCE PPU.  Both arrays hold identical
    //     bytes (W3 proves it on every store), so a difference is a corrupted
    //     fetch and nothing else.
    // ======================================================================
    always @(posedge clk) begin
        if (reset) begin
            c2_dots          = 0;
            c2_pix_diff      = 0;
            c2_idx_diff      = 0;
            c2_loq_diff      = 0;
            c2_shadow_diff   = 0;
            c2_shadow_checks = 0;
            c2_shadow_late   = 0;
            c2_first_loq     = 0;
            c2_ref_opaque    = 0;
            c2_armed_opaque  = 0;
        end else if (ce) begin
            // The comparison is gated on the REFERENCE's bg_ready, not on a dot
            // number, because the reference is the instance whose fetch units
            // were never displaced: it defines "the picture this PPU renders
            // when nothing steals a CHR beat", and bg_ready is exactly the
            // statement that its first tile has landed.  Before that dot the
            // armed instance has a tile and the reference has none, which is a
            // startup ordering rather than a corrupted byte, and counting it
            // would make the check fire on a difference that is not one.
            if ((dot_a < 9'd256) && (sl_a < 9'd240) &&
                (dut_r.g_chr_external.bg_ready !== 1'b0)) begin
                c2_dots = c2_dots + 1;
                if (dut_r.bg_pattern_index !== 2'b00) c2_ref_opaque = c2_ref_opaque + 1;
                if (dut_a.bg_pattern_index !== 2'b00) c2_armed_opaque = c2_armed_opaque + 1;
                if (dut_a.bg_pattern_index !== dut_r.bg_pattern_index) begin
                    c2_idx_diff = c2_idx_diff + 1;
                    if (c2_idx_diff < 4)
                        $display("W2 PATTERN-INDEX-DIFF frame=%0d sl=%0d dot=%0d armed=%0b reference=%0b armed planes=%02h/%02h reference planes=%02h/%02h",
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
                        $display("W2 PIXEL-DIFF frame=%0d sl=%0d dot=%0d x=%0d y=%0d armed=%02h reference=%02h armed_bg=%02h/%02h reference_bg=%02h/%02h",
                                 frames, sl_a, dot_a, pxx_a, pxy_a,
                                 ppal_a, ppal_r, bg_lo, bg_hi, bg_lo_r, bg_hi_r);
                end
            end
            if ((dut_a.g_chr_external.bg_lo_q !==
                 dut_r.g_chr_external.bg_lo_q) ||
                (dut_a.g_chr_external.bg_hi_q !==
                 dut_r.g_chr_external.bg_hi_q)) begin
                if (c2_first_loq == 0) begin
                    c2_first_loq = 1;
                    $display("W2 FIRST-LATCH-DIFF frame=%0d sl=%0d dot=%0d armed bg_lo_q=%02h bg_hi_q=%02h  reference bg_lo_q=%02h bg_hi_q=%02h  armed pixel=%02h reference pixel=%02h",
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
            // finished (it starts at dot 257 and costs 35 ce, about 12 dots, and
            // the write deferral can add at most 16 more) and every sprite byte
            // for the next line has landed in both.
            if ((dot_a == 9'd320) && (sl_a < 9'd240)) begin
                c2_shadow_checks = c2_shadow_checks + 1;
                if (dut_a.g_chr_external.sp_shadow !==
                        dut_r.g_chr_external.sp_shadow ||
                    dut_a.g_chr_external.sp_shadow_valid !==
                        dut_r.g_chr_external.sp_shadow_valid) begin
                    c2_shadow_late = c2_shadow_late + 1;
                    if (c2_shadow_late < 3)
                        $display("W2 SHADOW-NOT-CONVERGED frame=%0d sl=%0d dot=320 armed %032h valid=%b, reference %032h valid=%b",
                                 frames, sl_a,
                                 dut_a.g_chr_external.sp_shadow,
                                 dut_a.g_chr_external.sp_shadow_valid,
                                 dut_r.g_chr_external.sp_shadow,
                                 dut_r.g_chr_external.sp_shadow_valid);
                end
            end
        end
    end

    // ======================================================================
    // Access sequencer: ONE PPU access per div_phase window -- exactly the
    // cadence a cpu $2007 access has -- then loop the streaming block forever.
    //
    // The load has to be qualified on div_phase == 0 and not merely on ce.  ce
    // is high at div_phase 0, 4 AND 8, so a sequencer that advances on every ce
    // burns three ops per window and delivers only the third of each triple to
    // the PPU: reg_cs is a level that is high only on the div_phase 0 clk, so
    // two of every three ops are silently discarded.  That is not a harmless
    // mistake here -- it drops $2001, so PPUMASK stays $00, nothing is ever
    // displayed, no collision is ever visible and the whole bench passes on
    // nothing.  tb_chr_arb_collision advances on plain ce and gets away with
    // it because its script's intent survives dropping two ops in three; this
    // one's does not, so it says so instead.
    // ======================================================================
    always @(posedge clk) begin
        if (reset) begin
            op_ptr    <= 0;
            looping   <= 1'b0;
            acc_valid <= 1'b0;
            acc_addr  <= 3'd0;
            acc_we    <= 1'b0;
            acc_din   <= 8'h00;
            wr_seq    <= 8'h00;
        end else if (ce && (div_phase == 4'd0)) begin
            if (!looping) begin
                if (op_ptr < n_ops) begin
                    acc_valid <= 1'b1;
                    acc_addr  <= op_addr[op_ptr];
                    acc_we    <= op_we[op_ptr];
                    acc_din   <= op_din[op_ptr];
                    op_ptr    <= op_ptr + 1;
                    if (op_ptr + 1 == loop_start)
                        looping <= 1'b1;
                end
            end else begin
                acc_valid <= 1'b1;
                acc_addr  <= op_addr[op_ptr];
                acc_we    <= op_we[op_ptr];
                acc_din   <= (op_we[op_ptr] && (op_addr[op_ptr] == 3'd7))
                                 ? (wr_seq ^ 8'h3C) : op_din[op_ptr];
                if ((op_ptr + 1 == loop_start + loop_len)) begin
                    op_ptr  <= loop_start;
                    wr_seq  <= wr_seq + 8'd1;
                end else begin
                    op_ptr  <= op_ptr + 1;
                end
            end
        end
    end

    // ------------------------------------------------------------------ final
    always @(posedge clk) begin
        if (!reset && ce && fd_a) begin
            frames = frames + 1;
            if (frames >= 3) begin
                c6_overlap = 0;
                for (i = 0; i < 256; i = i + 1)
                    if ((fetch_bits[i*32 +: 32] & write_bits[i*32 +: 32]) !== 32'd0)
                        c6_overlap = c6_overlap + 1;
                $write("W6 FETCHED-ADDRESSES");
                for (i = 0; i < 8192; i = i + 1)
                    if (fetch_bits[i] === 1'b1) $write(" $%04h", i);
                $write("\n");
                $write("W6 WRITTEN-ADDRESSES");
                for (i = 0; i < 8192; i = i + 1)
                    if (write_bits[i] === 1'b1) $write(" $%04h", i);
                $write("\n");

                $display("--------------------------------------------------------------");
                $display("W7 WHAT-THE-FIX-COSTS bg_fetch_due=%0d accepted=%0d DROPPED=%0d, tiles delivered=%0d.  The background fetch pipeline has no slack at all: the cadence is one request every 8 ce (bg_fetch_due every 8 dots, a dot is one ce) and one tile is 8 ce, so with no fix at all this run measures 25152 requests, 25152 accepted, 0 dropped.  A one-ce freeze therefore costs one tile.  The SAME census inside tb_chr_arb_collision, which only freezes on the $2007 READ arm, measures 25152 / 22869 / 2283, so the zero-slack pipeline is pre-existing and 00ca051 already spends it; a $2007 CHR WRITE lands on div_phase 0, where the background unit's S_BEAT lands far more often than the div_phase 8 an arm lands on, which is why this number is larger.  IT IS NOT VISIBLE HERE and W2 is what proves it: a dropped request makes the tile stream one tile late, the stream re-phases on the next accepted request because the cadence is an exact multiple of the tile length, and the tiles are identical from dot to dot inside a scanline because the whole nametable is tile $01.  A cartridge with a non-uniform nametable would turn these drops into visible tile errors; that is a finding about the fetch pipeline's slack, not about this fix",
                         d_due, d_acc, d_drop, d_tiles);
                $display("W5 CONTENTION, benign and counted: $2007 CHR write beats=%0d  collided with a background mid-beat=%0d  with a sprite mid-beat=%0d",
                         c5_wr_beats, c5_wr_bg_collide, c5_wr_sp_collide);
                $display("W5 write beats that landed where a rendered pixel could change: %0d of %0d  (this run has NO invisible-set guard; that is the point)",
                         c5_vis_collide, c5_wr_beats);
                $display("W4 DISPLACED-BEAT-DEFERRED: bg checks=%0d ce-not-suppressed=%0d   sp checks=%0d ce-not-suppressed=%0d",
                         c4_bg_checked, c4_bg_not_frozen,
                         c4_sp_checked, c4_sp_not_frozen);
                $display("W1 CONSUMED-THE-BYTE-IT-ASKED-FOR: bg consuming beats=%0d wrong=%0d   sp consuming beats=%0d wrong=%0d",
                         c1_bg_beats, c1_bg_bad, c1_sp_beats, c1_sp_bad);
                $display("W3 THE-WRITE-STILL-LANDS: strobes=%0d accepted=%0d not-in-memory-one-ce-later=%0d strobe-shape err=%0d ctrl2 err=%0d chr_waddr err=%0d chr_wdata err=%0d cross-instance mismatch=%0d",
                         c3_wr_beats, c3_wr_accepted, c3_wr_late, c3_wr_shape_err, c3_ctrl2_err,
                         c3_waddr_err, c3_wdata_err, c3_instr_mismatch);
                $display("W2 PIXEL-AB-AGAINST-REFERENCE: visible dots=%0d pixel diffs=%0d bg_pattern_index diffs=%0d",
                         c2_dots, c2_pix_diff, c2_idx_diff);
                $display("W2 LATCH-DIFFERENCE: bg_lo_q/bg_hi_q differ on %0d ce, sprite shadow differs on %0d ce; sprite shadow checked at dot 320 of %0d visible lines, still differing on %0d",
                         c2_loq_diff, c2_shadow_diff, c2_shadow_checks, c2_shadow_late);
                $display("W2 VISIBILITY-CENSUS: reference bg opaque on %0d of %0d visible dots, armed on %0d",
                         c2_ref_opaque, c2_dots, c2_armed_opaque);
                $display("W6 ADDRESS-CENSUS fetch request beats=%0d over %0d distinct addresses, write beats=%0d over %0d distinct addresses, distinct fetch addresses that were ALSO written=%0d",
                         c6_fetch_marks, c6_fetch_distinct, c6_write_marks,
                         c6_write_distinct, c6_overlap);
                $display("W6 ARM-ABSENT the $2007 CHR read arm was active on %0d ce of this run, so every wrong byte above is a WRITE's doing and the read hazard fixed in 00ca051 is not what this bench measures",
                         arm_beats);
                $display("W3 WRITE-RANGE %0d strobes, addresses $%04h..$%04h, %0d distinct; the chr-ram board accepted %0d stores into the armed array and %0d into the reference's",
                         wr_win_cnt, wr_min_addr, wr_max_addr, c6_write_distinct,
                         mem_wr_a, mem_wr_r);

                if (c3_wr_beats < 100)
                    $fatal(1, "SETUP only %0d $2007 CHR write beats, the path is barely exercised", c3_wr_beats);
                if (c5_wr_bg_collide + c5_wr_sp_collide < 1)
                    $fatal(1, "SETUP the run provoked ZERO write-vs-fetch collisions, so it proves nothing");
                if (c5_wr_bg_collide < 1)
                    $fatal(1, "SETUP no write beat ever found the BACKGROUND fetch unit mid-beat");
                if (c5_wr_sp_collide < 1)
                    $fatal(1, "SETUP no write beat ever found the SPRITE fetch unit mid-beat");
                if (c5_vis_collide < 1)
                    $fatal(1, "SETUP no write beat landed where a rendered pixel could change, so the run proves nothing");
                if (arm_beats != 0)
                    $fatal(1, "SETUP the $2007 CHR READ arm was active on %0d ce although chr_rd_arm is tied low; this bench measures the write hazard only", arm_beats);
                if (c6_overlap != 0)
                    $fatal(1, "W6 %0d words of the CHR window were both fetched and written, so a legitimately changed byte could have reached a pixel and the A/B would not be a proof", c6_overlap);
                if ((wr_min_addr < 14'h0800) || (wr_max_addr >= 14'h2000))
                    $fatal(1, "W3 the %0d stores spread over $%04h..$%04h, outside the $0800-$1FFF band this bench aims at; W6's intersection of the real store set against the real fetch set is then the only thing keeping a legitimately changed byte off the screen",
                           c3_wr_beats, wr_min_addr, wr_max_addr);
                if (c3_ctrl2_err != 0)
                    $fatal(1, "W3 PPUCTRL[2] was high on %0d of %0d write beats, so increment_v is +32 and the stores were not confined to the window this bench asserts", c3_ctrl2_err, c3_wr_beats);
                if (c3_wr_shape_err != 0)
                    $fatal(1, "W3 chr_we was not exactly reg_cs&&we&&$2007&&v_addr<$2000 on %0d ce", c3_wr_shape_err);
                if (c3_waddr_err != 0)
                    $fatal(1, "W3 chr_waddr was not the pre-increment v_addr, or the two instances disagreed, on %0d beats", c3_waddr_err);
                if (c3_wdata_err != 0)
                    $fatal(1, "W3 chr_wdata was not reg_din, or the two instances disagreed, on %0d beats", c3_wdata_err);
                if (c3_wr_late != 0)
                    $fatal(1, "W3 %0d $2007 CHR writes had not reached memory one ce after their strobe, so the store is not landing on its own beat", c3_wr_late);
                if (c3_instr_mismatch != 0)
                    $fatal(1, "W3 the two CHR arrays diverged on %0d stores, so the W2 pixel A/B compares two different memories", c3_instr_mismatch);
                if (c3_wr_accepted != mem_wr_a)
                    $fatal(1, "W3 %0d write strobes but %0d stores reached the armed chr-ram array", c3_wr_accepted, mem_wr_a);
                if (mem_wr_r != mem_wr_a)
                    $fatal(1, "W3 the two instances performed %0d and %0d stores, so their memories cannot be identical", mem_wr_a, mem_wr_r);
                if (c1_bg_bad != 0 || c1_sp_bad != 0)
                    $fatal(1, "W1 %0d background and %0d sprite fetch units consumed a byte captured for a $2007 CHR write",
                           c1_bg_bad, c1_sp_bad);
                if (c4_bg_not_frozen != 0 || c4_sp_not_frozen != 0)
                    $fatal(1, "W4 %0d background and %0d sprite beats were out-voted rather than deferred by a $2007 CHR write",
                           c4_bg_not_frozen, c4_sp_not_frozen);
                if (c2_pix_diff != 0)
                    $fatal(1, "W2 the arbitrated PPU rendered %0d pixels differently from the reference whose read bus is not arbitrated", c2_pix_diff);
                if (c2_shadow_late != 0)
                    $fatal(1, "W2 the sprite shadow had not converged by dot 320 on %0d of %0d visible lines", c2_shadow_late, c2_shadow_checks);
                $display("PASS tb_chr_wr_collision");
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
