`timescale 1ns/1ps

// ============================================================================
// tb_bg_fetch_drop : DOES A DROPPED BACKGROUND FETCH COST A VISIBLE PIXEL?
// ----------------------------------------------------------------------------
// This bench exists to answer one question that the two CHR collision benches
// deliberately could not answer.  Both of them proved that a fetch unit frozen
// for one ce no longer CONSUMES a byte captured for another master.  Both of
// them then went on to prove that the picture is unchanged, and they could say
// so honestly, because both fill the nametable with tile $01 everywhere:
//
//   tb_chr_arb_collision.v:492  dut_*.nametable_ram[j] = 8'h01
//   tb_chr_wr_collision.v:492  dut_*.nametable_ram[j] = 8'h01
//
// With a uniform nametable every fetched tile is byte-identical, so a one-tile
// error in the fetch STREAM is arithmetically invisible.  That proves the drops
// are invisible FOR THAT CARTRIDGE.  It says nothing at all about a cartridge
// whose nametable is not uniform, which is to say most real ones.
//
// The freeze is not free.  bg_fetch_due fires every 8 ce and one background
// tile is 8 ce (S_PRE, S_ARM, S_BEAT, S_GRAB, S_BEAT, S_GRAB, S_DONE, S_IDLE),
// so the pipeline has ZERO slack and a one-ce freeze drops a whole request.
// NOTE ON THE DROP COUNTS: they are STIMULUS SPECIFIC and are not expected to
// reproduce any particular earlier number.  tb_chr_wr_collision's W7 line
// measures 25152 due / 22869 accepted / 2283 dropped over 3 frames after
// 00ca051 and 19914 / 5238 after 263f8c1, at ITS $2007 cadence; this bench
// runs one $2007 access per two to six div_phase windows and therefore drops
// more.  What has to hold is the ratio and the zero-slack arithmetic: one
// ce of freeze, one whole tile of cost.
//
// WHAT IS UNDER TEST
//   The same A/B shape the two collision benches use, with the ONE thing changed
//   that makes a stream error visible: the nametable is NOT uniform, and it is
//   not uniform in the WORST way the CHR model can express.
//
//   Two nametable patterns, selected by +nt, because the amount of damage a
//   wrong tile does depends entirely on how many bits of the tile NUMBER differ
//   between the tile that should be there and the tile that is:
//     +nt=1  DEFAULT.  Consecutive entries differ by 15 mod 32, i.e. in all four
//       tile-number bits the CHR model can see.  The model is
//       chr_mem[i] = {i4^i3, i5^i2, i6^i1, i7^i0, i3^i2, i2^i1, i1^i0, i[0]},
//       which depends on i[7:0] only, and a tile's byte address is name*16 + fine,
//       so i[7:4] = name[3:0] and those four tile-number bits land on CHR bits
//       7,6,5,4 -- which are exactly the four leftmost pixels of the 8x8 cell,
//       because bg_pattern_bit = 7 - x (nes_ppu2c02.v:645).  A substituted tile
//       is therefore visible on 4 of its 8 dots, which is the most damage a tile
//       substitution can do in this model and the number to quote.
//     +nt=0  entry j carries j[4:0] ^ (j[9] ? 5'h1F : 5'h00), so consecutive
//       entries differ in ONE tile-number bit and a substituted tile shows on 1 of
//       its 8 dots.  Low contrast, kept because it is what the first version of
//       this bench used; the ratio of the two numbers is the sensitivity of the
//       whole question.
//   S1 measures the adjacency property of whichever pattern is selected and
//   fatals if it is false, so this bench cannot silently degenerate back into the
//   uniform-nametable case that made the drops invisible in the two collision
//   benches.
//
//   Two PPU instances, same register stimulus, same CHR RAM contents:
//     dut_a  the arbitrated instance: its CHR read memory is addressed on
//            mapper_ppu_addr = ppu_chr_we ? ppu_chr_waddr : ppu_chr_addr, i.e.
//            nes_system_v6.v:334, so the $2007 write owns the address bus on its
//            own beat and the $2007 read arm owns it on its own beat.
//     dut_r  the reference: identical in every respect except that its CHR read
//            memory is addressed on its own chr_addr port, so nothing is ever
//            taken away from its fetch units.  It is the picture this PPU draws
//            when no master ever steals a CHR beat.
//
//   Both receive the SAME store at the SAME address with the SAME data (checked,
//   W6), so the two CHR arrays are byte identical and any pixel difference can
//   only be a missing or wrong fetch.  Both also get the same $2006/$2007
//   register stimulus, so v_addr / temp_addr / write_toggle evolve identically
//   (checked every beat, W8) and the reference cannot have drifted.
//
// THE STRUCTURAL FACT THAT MAKES THE ANSWER NON-OBVIOUS
//   nes_chr_fetch_unit does not consume from a stream.  Each accepted request
//   independently latches tile_base, and tile_base is a PURE COMBINATIONAL
//   FUNCTION OF THE CURRENT DOT (nes_ppu2c02.v:803-832: bg_look_dot is dot+9,
//   or dot+17 for the 324 pre-fetch, and bg_tile_base is derived from that).
//   So a dropped request is a HOLE in the tile sequence, not a SHIFT of it, and
//   the very next accepted request re-registers the correct target for its own
//   dot with no regard for what came before.  That predicts a drop costs a
//   small, BOUNDED number of dots and that the instance re-converges.  Whether
//   that prediction is right is measured here (W4) and not assumed, because a
//   dropped tile is also a dropped dot of the pipeline and the two effects have
//   to be told apart.
//
// WHAT IS ASSERTED, AND WHY EACH LINE IS WORTH FAILING ON
//   W1  A fetch unit never consumes a byte captured for another master.  The
//       expectation is read from the unit's OWN chr_addr register, so an arbiter
//       that overrode the bus cannot make it pass.  This must be 0, and it is
//       the reason any pixel difference below is a MISSING tile and not a
//       WRONG one.
//   W2  Pixel-for-pixel A/B against the reference over every gated visible dot.
//       This is the number the question asks for.  It is NOT asserted to be
//       zero: on the committed RTL it is expected to be non-zero, and the bench
//       says so out loud rather than hiding a defect behind a fatal.
//   W3  The drop census, split into drops whose target dot lands in the visible
//       field and drops whose target lands in vblank, because only the former
//       can cost a pixel.
//   W3  THE $2007 CHR READ IS STILL CORRECT.  The read arm is on the critical
//       path of this bench, so the byte it hands the CPU is checked.  The
//       expectation is the v_addr LATCHED AT THE ARM BEAT, not the v_addr at the
//       read beat, and getting that backwards is not cosmetic: the renderer
//       increments v_addr at every dot that is a multiple of 8
//       (nes_ppu2c02.v:1223), so with rendering enabled the two are different
//       numbers on most reads and the check fails on a correct design.  The
//       measurement that forced this is recorded here rather than hidden: the
//       first version of this bench compared against the read-beat v_addr and
//       reported 2542 of 9914 CHR reads "wrong", every one of them the byte at
//       v_addr - 1, which is precisely what a renderer increment_x between the
//       arm beat and the read beat produces.  This is the same two-deep arm
//       chain tb_chr_arb_collision's C3 uses.
//   W4  TRANSIENT OR PERMANENT.  Every episode during which the armed
//       bg_lo_q/bg_hi_q differ from the reference is counted at its start and
//       at its end; equal start and end counts is the statement "the difference
//       always healed", i.e. the stream re-phases rather than staying offset.
//       The run-length histogram of wrong-dot runs says how wide each wound is,
//       and the longest correct run between wounds says how far apart they are.
//   W5  CAUSAL LINK, and this is the line that makes the rest mean something.
//       The ROOT CAUSE is the freeze and the DROP is one of its consequences, so
//       every wrong dot is attributed to the nearest recorded FREEZE ce OR the
//       nearest recorded drop's TARGET dot within +-24 ce, and the bench fatals
//       if any wrong dot has neither.  Both offsets are histogrammed, so the
//       mechanism is a measurement rather than a story.  Two consequences, with
//       the drop's target dot T as the origin (the arithmetic; the histograms
//       confirm it and nothing else appears):
//         * ANY freeze delays the tile's latch by one ce, so the first dot of
//           that tile's window shows the previous tile.  A freeze that lands on
//           the unit's FIRST S_BEAT does this and loses nothing, so this wound
//           has no drop to point at -- that is why the freeze history exists.
//         * A freeze that lands on the LAST S_BEAT additionally pushes the
//           request past the next bg_fetch_due, so the request is DROPPED: the
//           dropped tile's own 8-dot window [T, T+7] is then served by whatever
//           bg_lo_q/bg_hi_q still held, which is the tile for T-8.
//   W9  HOW MUCH SLACK WOULD BE ENOUGH.  The freeze costs the pipeline ce, so
//       the number that decides whether a fix can work is not "how many freezes
//       happen" but "how many frozen ce land inside ONE background tile's 8-ce
//       occupancy".  One ce of added slack absorbs one; two absorb two.  W9
//       histograms that count per accepted fetch and prints the maximum, so the
//       "give the pipeline one more ce" option is costed against a measurement
//       rather than against an assumption.  MEASURED on the committed RTL over 3
//       frames in every mode: the maximum is 1, never 2.  That is consistent with
//       the source argument that two freezes cannot land on CONSECUTIVE ce (an
//       arm exists only at div_phase 8 and a write strobe only at div_phase 0,
//       and the div_phase-0 edge of the next window IS the retire beat of the
//       access whose arm was at div_phase 8, so it is a read whenever the arm
//       fired), but the bench does not rely on that argument: it measures the
//       number the option depends on.
//   W6  The two CHR arrays are byte identical and no store ever changed a byte:
//       the SAME store is applied to both at the same ce, the reference's own
//       $2007 write strobe is structurally absent (counted, and required to be 0),
//       the armed and reference write ADDRESSES must agree on every beat (they
//       both come from v_addr, which W8 checks), and every store's data is
//       required to EQUAL the byte already at that address.  That last one
//       replaces the fetch-address / store-address disjointness check the two
//       collision benches use, and it replaces it because DISJOINTNESS IS NOT
//       AVAILABLE HERE: both fetchers live inside the same 8 KiB CHR RAM, so no
//       store window is provably out of their reach.  The measured consequence
//       of not knowing that, with a data-changing store, was 48 wrong pixels in
//       +wr mode that no drop explained.
//   W7  The REFERENCE never drops.  If it did, the A/B would be comparing two
//       broken instances and the difference would prove nothing.
//   W8  The two instances agree on every PPU register that feeds the fetch
//       address, so the reference's picture is the picture the stimulus asked
//       for.
//   S1  SETUP.  The nametable really is non-uniform, really does have
//       horizontally distinct neighbours, and the mode really did provoke the
//       freezes and the drops it claims to have provoked.  Without these the
//       bench would silently degenerate back into the uniform case it exists to
//       leave behind.
//
// WHAT THIS BENCH IS, AND WHY IT IS NOT A GATE TARGET
//   It MEASURES a defect.  W2 is not asserted to be zero and on the committed
//   RTL it is thousands, so a target that ran this and passed would be a target
//   that had enshrined the defect, and a target that ran it and failed would
//   break the gate until the defect is fixed.  tools/sim_all.ps1 is therefore
//   deliberately left at 62 targets and this file is deliberately left out of
//   it.  It is a diagnostic to run by hand:
//       iverilog -g2012 -s tb_bg_fetch_drop -o drop.vvp \
//         rtl/nes_core/ppu/nes_ppu_sprite.v rtl/nes_core/ppu/nes_ppu2c02.v \
//         rtl/nes_core/ppu/nes_chr_fetch_unit.v \
//         rtl/nes_core/ppu/nes_sprite_chr_fetch.v tb/ppu/tb_bg_fetch_drop.v
//       vvp drop.vvp +rd=0 +wr=0 +nt=1 +frames=3   # the control
//       vvp drop.vvp +rd=1 +wr=0 +nt=1 +frames=3   # $2007 CHR reads
//       vvp drop.vvp +rd=0 +wr=1 +nt=1 +frames=3   # $2007 CHR writes
//       vvp drop.vvp +rd=1 +wr=1 +nt=1 +frames=3   # both
//   Roughly 35 s per measured frame plus 2 frames of reset hold under Icarus.
//   Every mode $fatal$ on the CONTROL run if the non-uniform nametable alone
//   produced a drop or a pixel difference, so a mode that drops nothing fatals
//   rather than reporting a vacuous zero.
//
// MODES (integer plusargs, so one file covers the control and both halves)
//   +rd=0 +wr=0   no $2007 CHR traffic at all.  THE CONTROL: the non-uniform
//                 nametable on its own must produce 0 drops and 0 pixel diffs,
//                 which is what makes the other three runs attributable to the
//                 arbitration and not to the stimulus.
//   +rd=1 +wr=0   only $2007 CHR READS.  Exercises the 00ca051 freeze alone.
//   +rd=0 +wr=1   only $2007 CHR WRITES.  Exercises the 263f8c1 freeze alone.
//   +rd=1 +wr=1   interleaved.  Both freezes at once.
//   +frames=N     measured frames, default 3, matching the other collision
//                 benches.
//   +nt=0|1       nametable contrast, see above.  Default 1 (maximum).
//   +void=1       force the control regardless of rd/wr, for A/B-ing a single
//                 run against a +rd/+wr run without a second binary.
// ============================================================================

module tb_bg_fetch_drop;

    // ---------------------------------------------------------------- modes
    // Integer plusargs rather than a %s string, so no Verilog string-literal
    // comparison width rule can silently turn one mode into another.
    integer m_rd, m_wr, n_frames_req;
    integer void_int;
    integer nt_mode;
    integer frames;
    integer i, j, k, t;
    reg [8*16-1:0] mode_name;

    // ------------------------------------------------------------ declarations
    reg        clk;
    reg        reset;
    reg  [3:0] div_phase;

    reg        acc_valid;
    reg  [2:0] acc_addr;
    reg        acc_we;
    reg  [7:0] acc_din_q;
    reg        acc_wr_tag;
    // The $2007 CHR WRITE'S DATA IS THE BYTE ALREADY AT THE ADDRESS, and that is
    // forced structurally rather than by computing a signature in advance,
    // because the address is not knowable a window early: nes_ppu2c02.v:1220-1229
    // mutates v_addr (increment_x at every dot that is a multiple of 8,
    // increment_y at dot 256, the temp copy at dot 257) and only three dots
    // separate an access's load edge from its retire edge, so the store lands
    // within a few bytes of wherever the $2006 pair aimed it and, on a coarse-Y
    // wrap, up to half a kilobyte away.  WHY IT HAS TO BE THIS WAY:
    //   * The CHR array is 8 KiB and BOTH fetchers live inside it (background at
    //     $1000-$11FF, sprite at $1010-$108F for PPUCTRL=$1A), so there is NO
    //     window in CHR RAM that the fetchers provably cannot reach and NO store
    //     address set that can be proved disjoint from the fetch address set.
    //   * Measured with a data-changing store, 2 words of the $1000-$11FFF half
    //     were both fetched and written over 3 frames, and that leaked a SECOND
    //     mechanism into the A/B: 48 of 8317 wrong pixels in +wr mode were not
    //     attributable to any drop.  They are read-during-write asymmetry -- the
    //     armed instance is frozen on the write beat and re-reads the address one
    //     ce later, by which time the store has landed, while the reference
    //     consumed the pre-store byte on its own beat.
    //   * Writing the byte that is already there removes that mechanism at the
    //     source while leaving everything this bench measures untouched: the
    //     strobe, the mapper address-bus takeover and the freeze that causes the
    //     drop are all still exercised on every single write beat.  W6 then
    //     asserts the property that actually matters -- that no store CHANGED a
    //     byte -- instead of the address disjointness it cannot have.
    wire [7:0] acc_din = acc_wr_tag ? chr_mem_a[waddr_a[12:0]] : acc_din_q;
    // The reference is driven by the SAME script with every $2007 write turned
    // into a $2007 read, so chr_we is structurally 0 on every reference beat and
    // the reference never freezes.  See the op-array comment below for why that
    // is required and why it is sound.
    reg  [2:0] acc_addr_r;
    reg        acc_we_r;
    reg  [7:0] acc_din_r;
    // Latched at the div_phase 0 edge at which acc_* is loaded, so it describes
    // the access that will RETIRE on the NEXT div_phase 0 edge.  The arm needs
    // exactly that one window of lead -- see the arm_a discussion below.
    reg        arm_pend;

    reg [7:0]  chr_mem_a [0:8191];
    reg [7:0]  chr_mem_r [0:8191];
    reg [7:0]  chr_rdata_a_q;
    reg [7:0]  chr_rdata_r_q;
    // W6 address census: every address any unit asked for, and every address a
    // store landed on.  With a non-uniform nametable the fetch set is large, so
    // the disjointness of the store window from the fetched set is a
    // measurement and not an assumption.
    reg [8191:0] fetch_bits = 8192'd0;
    reg [8191:0] write_bits = 8192'd0;

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

    wire [2:0]  bg_st   = dut_a.g_chr_external.u_chr_fetch.state;
    wire [2:0]  sp_st   = dut_a.g_chr_external.u_sprite_chr_fetch.state;
    wire        bg_mid  = dut_a.g_chr_external.u_chr_fetch.chr_req;
    wire        sp_mid  = dut_a.g_chr_external.u_sprite_chr_fetch.chr_req;
    wire [13:0] bg_qadr = dut_a.g_chr_external.u_chr_fetch.chr_addr;
    wire [13:0] sp_qadr = dut_a.g_chr_external.u_sprite_chr_fetch.chr_addr;
    wire [7:0]  bg_lo   = dut_a.g_chr_external.u_chr_fetch.bg_lo;
    wire [7:0]  bg_hi   = dut_a.g_chr_external.u_chr_fetch.bg_hi;
    wire [7:0]  bg_lo_r = dut_r.g_chr_external.u_chr_fetch.bg_lo;
    wire [7:0]  bg_hi_r = dut_r.g_chr_external.u_chr_fetch.bg_hi;

    localparam [2:0] ST_S_GRAB = 3'd4;

    // How far from a recorded drop's target dot a wrong dot is still attributed
    // to that drop.  The two mechanisms a drop has are measured, not assumed: the
    // freeze delays the PREVIOUS tile's latch (its target dot is T-8, so that
    // wound lands at offset -8) and the missing tile leaves the stale tile in
    // place for the dropped tile's own 8-dot window, which starts at T and, on
    // this bench's ce cadence, is still the displayed tile until the NEXT latch
    // one cadence later, i.e. through T+7.  -8..+8 is therefore the arithmetic
    // prediction and the fatal below uses +-16, which is twice the predicted
    // reach and still a tight causal claim: a wrong dot 17 ce from any drop in
    // the previous 16 drops would fail.
    localparam integer W5_WIN = 24;

    wire ce     = !reset && (div_phase[1:0] == 2'b00);
    wire reg_cs = (div_phase == 4'd0) && acc_valid;

    // The $2007 CHR read arm, at exactly the place nes_system_v6.v:331-332 puts
    // it: one clk whose pre-edge div_phase is 8, qualified by the access being a
    // $2007 read.  The one non-obvious requirement is the ONE WINDOW OF LEAD, and
    // getting it backwards is silent: the PPU retires a $2007 access on the
    // div_phase 0 edge, and it increments v_addr on that same edge, so an arm
    // raised during the window whose div_phase 0 edge already retired the access
    // captures the POST-increment address and the CPU is handed the byte of the
    // NEXT CHR location.  A first version of this bench did exactly that and
    // measured 2542 of 9914 reads returning chr_mem[v_addr + 1], which is a real
    // answer about a real hazard and the wrong answer about this one.  arm_pend
    // is therefore set at the div_phase 0 edge that LOADS the access, so the arm
    // at that window's div_phase 8 precedes the div_phase 0 edge that RETIRES it,
    // and v_addr is still the pre-increment value at the capture.
    wire arm_a = (div_phase == 4'd8) && arm_pend && (reset === 1'b0);

    // nes_system_v6.v:334.  This one line is what makes the $2007 write a bus
    // hazard at all, and it is the ONLY difference in the address path.
    wire [13:0] mapper_addr_a = (we_a !== 1'b0) ? waddr_a : chr_addr_a;
    wire [13:0] mapper_addr_r = (we_r !== 1'b0) ? waddr_r : chr_addr_r;

    // The reference's READ bus is not arbitrated: its memory is addressed on the
    // PPU's own chr_addr port, so nothing is ever taken away from its units.
    wire [7:0] ref_rdata_at = chr_mem_r[chr_addr_r[12:0]];

    // ---------------------------------------------------------------- program
    //
    // TWO OP ARRAYS, and the second one is the whole isolation argument of this
    // bench.  A $2007 op on addr 7 is a WRITE for the armed instance and a READ
    // for the reference.
    //
    // WHY THAT IS NECESSARY rather than clever, and why it was found by
    // measurement: chr_hold_bg lives INSIDE nes_ppu2c02
    // (nes_ppu2c02.v:962, `wire chr_hold_bg = (chr_rd_win || chr_we) && bg_chr_req`),
    // so it does not care whether that instance's memory is arbitrated.  A second
    // PPU handed the identical $2007 WRITE stimulus therefore freezes its own
    // fetch unit on exactly the same beats and drops exactly the same tiles: an
    // earlier version of this bench, and tb_chr_wr_collision.v before it, both
    // put the write on the reference too, and both would have measured 0 pixel
    // differences with a non-uniform nametable as readily as with a uniform one.
    // That is a SECOND reason the existing benches cannot see a dropped fetch,
    // independent of the uniform nametable, and it is worth recording.
    //
    // Substituting a READ is sound because the two directions are identical from
    // the PPU's point of view: nes_ppu2c02.v:1184 and :1193 are both
    // `v_addr <= increment_v(v_addr)`, and nothing else in the register file
    // reacts to $2007 at all -- write_toggle and fine_x are touched only by $2005
    // and $2006 (nes_ppu2c02.v:1159-1176).  So the reference's v_addr,
    // temp_addr, write_toggle and fine_x evolve identically to the armed
    // instance's, which W8 then checks on every ce rather than assuming, while
    // chr_we is structurally 0 on every reference beat and the reference
    // therefore NEVER freezes.
    //
    // In +rd mode the reference's non-freezing comes from its chr_rd_arm being
    // tied low instead, which is the same trick tb_chr_arb_collision uses.
    localparam integer MAX_OPS = 64;
    reg  [2:0]  op_addr [0:MAX_OPS-1];
    reg         op_we   [0:MAX_OPS-1];
    reg  [7:0]  op_din  [0:MAX_OPS-1];
    reg  [2:0]  op_addr_r [0:MAX_OPS-1];
    reg         op_we_r   [0:MAX_OPS-1];
    reg  [7:0]  op_din_r  [0:MAX_OPS-1];
    integer n_ops;
    integer n_ops_init;
    integer op_ptr;
    integer loop_start;
    integer loop_len;
    reg     looping;
    reg [7:0] wr_seq;
    reg [7:0] wr_seq_r;

    task set_op;
        input integer idx;
        input [2:0]  a;
        input        w;
        input [7:0]  d;
        begin
            op_addr[idx] = a;
            op_we[idx]   = w;
            op_din[idx]  = d;
            // The reference's copy of the same slot.  Only a $2007 write is
            // turned into a $2007 read; everything else, including every $2006
            // re-aim, is bit-identical, because those are what move v_addr.
            op_addr_r[idx] = a;
            op_we_r[idx]   = (a == 3'd7) ? 1'b0 : w;
            op_din_r[idx]  = d;
        end
    endtask

    // 8 sprites, all inside the visible field, all with tile indices whose
    // pattern addresses ($0010..$008F) stay clear of the $0C00/$1C00 store
    // window.  See W6.
    reg [7:0] spr_y [0:7];
    reg [7:0] spr_t [0:7];
    reg [7:0] spr_x [0:7];

    task build_script;
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
            // PPUCTRL = $1A: bit0 NMI off, bit1 master/slave set (which is
            // mask-independent and only matters for the sprite-0 hit path),
            // bit2 CLEAR so increment_v is +1, bit3 SET and bit4 SET, so the
            // sprite table is $1000 (nes_ppu_sprite.v:381 selects on
            // ctrl[3]) and the background table is $1000 as well.  The two
            // sharing $1000 is harmless here -- both fetch units are driven
            // identically in both instances and the arbiter keeps their time
            // windows disjoint -- and it is the sprite table that has to stay
            // clear of the $0C00/$0CFF store window below, which it does by a
            // wide margin either way.
            set_op(n_ops_init, 3'd0, 1'b1, 8'h1A); n_ops_init = n_ops_init + 1;
            set_op(n_ops_init, 3'd1, 1'b1, 8'h1E); n_ops_init = n_ops_init + 1;
            set_op(n_ops_init, 3'd5, 1'b1, 8'h00); n_ops_init = n_ops_init + 1;
            set_op(n_ops_init, 3'd5, 1'b1, 8'h00); n_ops_init = n_ops_init + 1;
            // v_addr = $0C00, inside the CHR window and clear of every tile the
            // non-uniform nametable can select ($1000..$120E) and of every sprite
            // address ($0010..$0097).  W6 intersects the measured fetch set
            // against the measured store set and requires them disjoint.
            set_op(n_ops_init, 3'd6, 1'b1, 8'h0C); n_ops_init = n_ops_init + 1;
            set_op(n_ops_init, 3'd6, 1'b1, 8'h00); n_ops_init = n_ops_init + 1;
            for (k = 0; k < 8; k = k + 1) begin
                set_op(n_ops_init, 3'd4, 1'b1, spr_y[k]); n_ops_init = n_ops_init + 1;
                set_op(n_ops_init, 3'd4, 1'b1, spr_t[k]); n_ops_init = n_ops_init + 1;
                set_op(n_ops_init, 3'd4, 1'b1, 8'h00);        n_ops_init = n_ops_init + 1;
                set_op(n_ops_init, 3'd4, 1'b1, spr_x[k]); n_ops_init = n_ops_init + 1;
            end

            loop_start = n_ops_init;
            // ---- the streaming loop: re-aim v_addr at $0C00, then ONE $2007
            //      access.  Two, three or five accesses per iteration depending
            //      on the mode, so a $2007 beat lands on one of every two or
            //      three ce_ppu edges of the run and the collisions are not
            //      something the cadence has to be lucky to produce.  The
            //      re-aim goes before EVERY access because
            //      nes_ppu2c02.v:1167-1183 moves v_addr during rendering three
            //      separate ways (increment_x at every dot that is a multiple of
            //      8, increment_y at dot 256 of every line, and increment_v on
            //      the access itself), so without it the accesses would walk
            //      out of the intended window.
            set_op(n_ops_init, 3'd6, 1'b1, 8'h0C); n_ops_init = n_ops_init + 1;
            set_op(n_ops_init, 3'd6, 1'b1, 8'h00); n_ops_init = n_ops_init + 1;
            if (m_rd) begin
                set_op(n_ops_init, 3'd7, 1'b0, 8'h00);
                n_ops_init = n_ops_init + 1;
            end
            if (m_wr) begin
                set_op(n_ops_init, 3'd6, 1'b1, 8'h0C); n_ops_init = n_ops_init + 1;
                set_op(n_ops_init, 3'd6, 1'b1, 8'h00); n_ops_init = n_ops_init + 1;
                set_op(n_ops_init, 3'd7, 1'b1, 8'h3C);
                n_ops_init = n_ops_init + 1;
            end
            loop_len = n_ops_init - loop_start;
        end
    endtask

    initial begin
        m_rd = 1;
        m_wr = 1;
        void_int = 0;
        nt_mode = 1;
        if (!$value$plusargs("rd=%d", m_rd))       m_rd = 1;
        if (!$value$plusargs("wr=%d", m_wr))       m_wr = 1;
        if (!$value$plusargs("void=%d", void_int)) void_int = 0;
        if (!$value$plusargs("nt=%d", nt_mode))    nt_mode = 1;
        if (void_int != 0) begin
            m_rd = 0;
            m_wr = 0;
        end
        if (!$value$plusargs("frames=%d", n_frames_req))
            n_frames_req = 3;
    end

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
    // Same signature the two collision benches use: every bit position of every
    // byte is a different function of the address, so a byte captured for the
    // wrong address differs in several bit positions at once AND in bit 7.  A
    // plain address signature is not enough, because this PPU takes ONE bit per
    // plane per pixel, so a signature with a constant bit 7 would make a whole
    // column of every tile transparent and hide the damage.
    initial begin
        for (i = 0; i < 8192; i = i + 1) begin
            chr_mem_a[i] = {i[4] ^ i[3], i[5] ^ i[2], i[6] ^ i[1], i[7] ^ i[0],
                            i[3] ^ i[2], i[2] ^ i[1], i[1] ^ i[0], i[0]};
            chr_mem_r[i] = {i[4] ^ i[3], i[5] ^ i[2], i[6] ^ i[1], i[7] ^ i[0],
                            i[3] ^ i[2], i[2] ^ i[1], i[1] ^ i[0], i[0]};
        end
    end

    // The two nametable patterns, selected by +nt.  Both are functions of the
    // ENTRY INDEX j only, so both instances get byte-identical nametables and
    // every run of the bench is reproducible from the plusargs alone.
    function [7:0] nt_pat;
        input integer idx;
        begin
            if (nt_mode)
                // Consecutive entries differ by exactly 15 mod 32, which is four
                // bits, and 15 is odd so the 32 entries of a row are all
                // distinct.  This is the maximum contrast the CHR model can
                // express: a substituted tile is wrong on 4 of its 8 dots.
                // The row term (5 per row) only affects VERTICAL neighbours, and
                // is here so the picture is not row-periodic.
                nt_pat = ((idx * 15) + ((idx / 32) * 5)) & 8'h1F;
            else
                // Consecutive entries differ in ONE tile-number bit, so a
                // substituted tile is wrong on 1 of its 8 dots.  Low contrast;
                // this is what the first version of this bench used, and the gap
                // between the two numbers IS the sensitivity of the question.
                nt_pat = idx[4:0] ^ (idx[9] ? 5'h1F : 5'h00);
        end
    endfunction

// THE ONE THING THIS BENCH CHANGES.  A non-uniform nametable, in one of two
    // contrast settings selected by +nt (see the header).  S1 measures the
    // adjacency property of the selected pattern and fatals if it is false, so
    // this bench cannot silently degenerate into the uniform-nametable case that
    // made the drops invisible in the two collision benches.
    integer nt_row0_neighbours;
    integer nt_row1_neighbours;
    integer nt_row0_dupes;

    initial begin
        nt_row0_neighbours = 0;
        nt_row1_neighbours = 0;
        nt_row0_dupes = 0;
        for (j = 0; j < 2048; j = j + 1) begin
            dut_a.nametable_ram[j] = nt_pat(j);
            dut_r.nametable_ram[j] = nt_pat(j);
        end
        for (j = 0; j < 32; j = j + 1) begin
            if (j < 31) begin
                if (dut_a.nametable_ram[j] != dut_a.nametable_ram[j+1])
                    nt_row0_neighbours = nt_row0_neighbours + 1;
                if (dut_a.nametable_ram[32 + j] != dut_a.nametable_ram[32 + j + 1])
                    nt_row1_neighbours = nt_row1_neighbours + 1;
            end
            for (t = 0; t < j; t = t + 1)
                if (dut_a.nametable_ram[j] == dut_a.nametable_ram[t])
                    nt_row0_dupes = nt_row0_dupes + 1;
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

    // A CHR-RAM board: the store is accepted on every strobe.  BOTH arrays take the
    // SAME store at the SAME ce, from the ARMED instance's address and data --
    // not from the reference's own chr_waddr, because the reference is driven
    // with every $2007 turned into a READ (see the op-array comment) and so
    // never raises a write strobe at all.  Mirroring the armed store is what
    // keeps the two arrays byte identical; writing chr_mem_r[waddr_r] instead
    // would leave the reference's whole window unwritten and the two images
    // different, which is both wrong and, in the first version of this bench,
    // a guaranteed $fatal on the store-count comparison in +wr and +both mode.
    integer mem_wr_a, wr_strobe_r;

    always @(posedge clk) begin
        if (reset) begin
            mem_wr_a     = 0;
            wr_strobe_r  = 0;
        end else if (ce) begin
            if (we_a !== 1'b0) begin
                chr_mem_a[waddr_a[12:0]] <= wdat_a;
                chr_mem_r[waddr_a[12:0]] <= wdat_a;
                mem_wr_a = mem_wr_a + 1;
            end
            if (we_r !== 1'b0)
                wr_strobe_r = wr_strobe_r + 1;
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
        .chr_rd_arm(arm_a), .chr_rdata(chr_rdata_a)
    );

    nes_ppu2c02 #(
        .MIRROR_VERTICAL(1'b0),
        .EXTERNAL_CHR(1'b1)
    ) dut_r (
        .clk(clk), .reset(reset), .ce(ce),
        .reg_cs(reg_cs), .reg_we(acc_we_r), .reg_addr(acc_addr_r), .reg_din(acc_din_r),
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
    // W1  A fetch unit must never CONSUME a beat whose byte was captured for
    //     another master.  The expectation is read from the unit's OWN
    //     chr_addr register, not from the muxed bus, so an arbiter that
    //     overrode the bus cannot make this pass by redefining it.
    //     This is the reason every pixel difference counted below is a MISSING
    //     tile and not a WRONG one.
    // ======================================================================
    reg  [7:0]  bg_want_q;
    reg  [7:0]  sp_want_q;
    reg  [13:0] bg_want_addr_q;
    reg  [13:0] sp_want_addr_q;

    integer c1_bg_beats, c1_bg_bad, c1_sp_beats, c1_sp_bad;
    integer c2_dots, c2_pix_diff, c2_idx_diff;
    integer c3_due_a, c3_acc_a, c3_drop_a, c3_drop_vis;
    integer c3_due_r, c3_drop_r;
    integer c4_ep_open, c4_ep_start, c4_ep_end;
    integer c5_wrong, c5_explained;
    integer c6_fetch_marks, c6_write_marks, c6_overlap, c6_write_distinct;
    integer c6_value_changing;
    integer c8_reg_mismatch;
    integer arm_beats, wr_bg_collide, wr_sp_collide;
    integer s0_loq_diff, s0_shadow_diff, s0_shadow_late, s0_shadow_checks;
    integer rd_checked, rd_wrong;
    integer lines_all_wrong, lines_no_wrong, lines_seen;
    integer max_correct_run;
    integer dbg_arm_x, dbg_pend_x, dbg_we_x, dbg_rdw_x;

    // Run-length histogram of wrong-dot runs, and of the correct-dot gaps
    // between them.  bucket 0 = a single wrong dot, bucket 8 = 2..9 dots,
    // 9 = 10..16, 10 = 17..32, 11 = 33 or more.  Buckets 1..7 are unused, which
    // is why the summary line reads "1" and "2..9" rather than eight numbers.
    function integer bucket;
        input integer n;
        begin
            if      (n <= 1)       bucket = 0;
            else if (n <= 9)       bucket = 8;
            else if (n <= 16)      bucket = 9;
            else if (n <= 32)      bucket = 10;
            else                   bucket = 11;
        end
    endfunction

    integer run_hist [0:11];
    integer gap_hist [0:11];

    reg        wrong_now;
    integer    run_len;
    integer    gap_len;
    integer    line_wrong;

    // 16-deep shift register of the ABSOLUTE frame-dot index of the most recent
    // drops' target dots, AND of the most recent freeze ce, so a wrong dot can be
    // attributed to whichever of the two actually explains it.  Absolute
    // (scanline*341 + dot) rather than (scanline, dot) pairs because the wounds
    // straddle the line boundary: a drop taken at dot 340 of line L has its
    // target on line L+1.
    reg  [17:0] drop_hist [0:15];
    reg  [17:0] frz_hist  [0:15];
    integer     drop_ptr;
    integer     frz_ptr;
    // off_d[d+32] counts wrong dots by their offset from the nearest recorded
    // drop's TARGET dot, off_f[d+32] by their offset from the nearest recorded
    // FREEZE ce.  d in [-32, +31].
    integer offset_hist [0:63];
    integer off_f_hist  [0:63];
    reg         found_drop;
    integer     cur_d;
    integer     cur_abs;
    integer     abs_now;
    integer     fd_best;
    integer     fd_abs;
    integer     fz_best;
    integer     fz_abs;
    integer     t2;
    // W9  How many ce of the freeze land INSIDE one background tile's 8-ce
    // occupancy.  This is the number that decides whether one ce of slack is
    // enough, so it is measured rather than argued: c9_hold_hist[k] is how many
    // of the accepted fetches saw exactly k frozen ce, and c9_hold_max is the
    // largest k seen.
    integer c9_hold_hist [0:9];
    integer c9_hold_max;
    integer c9_hold;
    reg     c9_window_open;
    integer c9_freeze_ce;
    integer c5_unexplained_shown;
    integer c5_drop_attr;
    integer c5_frz_attr;
    reg  [14:0] rd_pend_v;
    reg         rd_pend_ok;
    reg  [14:0] rd_deliver_v;
    reg         rd_deliver_ok;
    integer     rd_noarm;
    wire        c3_any_2007   = reg_cs && (acc_addr == 3'd7);
    wire        c3_read_beat  = c3_any_2007 && !acc_we && (dut_a.v_addr < 15'h2000);

    reg  [7:0]  c3_lat_data_q;
    reg  [13:0] c3_lat_addr_q;
    reg         c3_lat_v_q;

    wire [8:0]  tgt_sl;
    wire [8:0]  tgt_look;
    wire [8:0]  tgt_dot;
    // nes_ppu2c02.v:803-805, replicated so the drop record names the dot the
    // missing tile WAS for rather than the dot the request was made at.
    assign tgt_look = ((dot_a == 9'd324) && (dut_a.mask_reg[1] !== 1'b0))
                      ? (dot_a + 9'd17) : (dot_a + 9'd9);
    assign tgt_sl   = (tgt_look >= 9'd341)
                      ? ((sl_a == 9'd261) ? 9'd0 : (sl_a + 9'd1))
                      : sl_a;
    assign tgt_dot  = (tgt_look >= 9'd341) ? (tgt_look - 9'd341) : tgt_look;

    always @(posedge clk) begin
        if (reset) begin
            bg_want_q      <= 8'h00;
            sp_want_q      <= 8'h00;
            bg_want_addr_q <= 14'd0;
            sp_want_addr_q <= 14'd0;
            c1_bg_beats = 0; c1_bg_bad = 0; c1_sp_beats = 0; c1_sp_bad = 0;
            c2_dots = 0; c2_pix_diff = 0; c2_idx_diff = 0;
            c3_due_a = 0; c3_acc_a = 0; c3_drop_a = 0; c3_drop_vis = 0;
            c3_due_r = 0; c3_drop_r = 0;
            c9_hold_max = 0; c9_hold = 0; c9_window_open = 1'b0;
            c9_freeze_ce = 0;
            c5_unexplained_shown = 0;
            c5_drop_attr = 0;
            c5_frz_attr = 0;
            c4_ep_open = 0; c4_ep_start = 0; c4_ep_end = 0;
            c5_wrong = 0; c5_explained = 0;
            c6_fetch_marks = 0; c6_write_marks = 0; c6_overlap = 0;
            c6_write_distinct = 0;
            c6_value_changing = 0;
            c8_reg_mismatch = 0;
            arm_beats = 0; wr_bg_collide = 0; wr_sp_collide = 0;
            s0_loq_diff = 0; s0_shadow_diff = 0; s0_shadow_late = 0;
            s0_shadow_checks = 0;
            rd_checked = 0; rd_wrong = 0;
            rd_noarm = 0;
            rd_pend_v    <= 15'd0;
            rd_pend_ok   <= 1'b0;
            rd_deliver_v <= 15'd0;
            rd_deliver_ok<= 1'b0;
            lines_all_wrong = 0; lines_no_wrong = 0; lines_seen = 0;
            max_correct_run = 0;
            dbg_arm_x = 0; dbg_pend_x = 0; dbg_we_x = 0; dbg_rdw_x = 0;
            drop_ptr = 0;
            frz_ptr = 0;
            for (t = 0; t < 16; t = t + 1) begin
                drop_hist[t] = 18'd0;
                frz_hist[t]  = 18'd0;
            end
            for (t = 0; t < 64; t = t + 1) begin
                offset_hist[t] = 0;
                off_f_hist[t]  = 0;
            end
            for (t = 0; t < 12; t = t + 1) begin
                run_hist[t] = 0;
                gap_hist[t] = 0;
            end
            for (t = 0; t < 128; t = t + 1) offset_hist[t] = 0;
            for (t = 0; t < 128; t = t + 1) offset_hist[t] = 0;
            for (t = 0; t < 10; t = t + 1) c9_hold_hist[t] = 0;
            wrong_now = 1'b0;
            run_len = 0;
            gap_len = 0;
            line_wrong = 0;
            c3_lat_addr_q <= 14'd0;
            c3_lat_data_q <= 8'h00;
            c3_lat_v_q    <= 1'b0;
        end else if (ce) begin
            // ---------------------------------------------------------- W1
            // Re-record on every chr_req beat: a frozen unit repeats the same
            // address on the next ce, and if the frozen beat was a $2007 write's
            // own beat the second record is the post-store byte, which is the
            // byte the unit is then entitled to.
            if (bg_mid !== 1'b0) begin
                bg_want_q      <= chr_mem_a[bg_qadr[12:0]];
                bg_want_addr_q <= bg_qadr;
            end
            if (sp_mid !== 1'b0) begin
                sp_want_q      <= chr_mem_a[sp_qadr[12:0]];
                sp_want_addr_q <= sp_qadr;
            end
            if (bg_st === ST_S_GRAB) begin
                c1_bg_beats = c1_bg_beats + 1;
                if (chr_rdata_a !== bg_want_q) begin
                    c1_bg_bad = c1_bg_bad + 1;
                    if (c1_bg_bad < 4)
                        $display("W1 BG-WRONG-BYTE frame=%0d sl=%0d dot=%0d unit_addr=%04h expected=%02h chr_rdata=%02h",
                                 frames, sl_a, dot_a, bg_want_addr_q, bg_want_q,
                                 chr_rdata_a);
                end
            end
            if (sp_st === ST_S_GRAB) begin
                c1_sp_beats = c1_sp_beats + 1;
                if (chr_rdata_a !== sp_want_q) begin
                    c1_sp_bad = c1_sp_bad + 1;
                    if (c1_sp_bad < 4)
                        $display("W1 SP-WRONG-BYTE frame=%0d sl=%0d dot=%0d unit_addr=%04h expected=%02h chr_rdata=%02h",
                                 frames, sl_a, dot_a, sp_want_addr_q, sp_want_q,
                                 chr_rdata_a);
                end
            end

            // ---------------------------------------------------------- W9
            // Freezes landing inside one background tile's 8-ce occupancy.  A
            // fetch is "open" from the ce on which the unit leaves S_IDLE until
            // the ce on which it is idle again; c9_hold counts the frozen ce in
            // that window and the window's total is banked when it closes.
            if ((bg_st !== 3'd0) || (dut_a.g_chr_external.u_chr_fetch.busy !== 1'b0)) begin
                c9_window_open = 1'b1;
                if (dut_a.g_chr_external.chr_hold_bg !== 1'b0) begin
                    c9_hold       = c9_hold + 1;
                    c9_freeze_ce  = c9_freeze_ce + 1;
                end
            end else begin
                if (c9_window_open !== 1'b0) begin
                    if (c9_hold <= 9)
                        c9_hold_hist[c9_hold] = c9_hold_hist[c9_hold] + 1;
                    else
                        c9_hold_hist[9] = c9_hold_hist[9] + 1;
                    if (c9_hold > c9_hold_max)
                        c9_hold_max = c9_hold;
                end
                c9_window_open = 1'b0;
                c9_hold        = 0;
            end

            if (dut_a.g_chr_external.chr_hold_bg !== 1'b0) begin
                frz_hist[frz_ptr] = ({9'd0, sl_a} * 18'd341) + {9'd0, dot_a};
                frz_ptr = (frz_ptr == 15) ? 0 : (frz_ptr + 1);
            end

            // ---------------------------------------------------------- W3
            if (dut_a.g_chr_external.bg_fetch_due !== 1'b0) begin
                c3_due_a = c3_due_a + 1;
                if ((bg_st == 3'd0) && (dut_a.g_chr_external.u_chr_fetch.busy === 1'b0)) begin
                    c3_acc_a = c3_acc_a + 1;
                end else begin
                    c3_drop_a = c3_drop_a + 1;
                    drop_hist[drop_ptr] = ({9'd0, tgt_sl} * 18'd341)
                                        + {9'd0, tgt_dot};
                    drop_ptr = (drop_ptr == 15) ? 0 : (drop_ptr + 1);
                    if ((tgt_sl < 9'd240) && (tgt_dot < 9'd256))
                        c3_drop_vis = c3_drop_vis + 1;
                end
            end
            if (dut_r.g_chr_external.bg_fetch_due !== 1'b0) begin
                c3_due_r = c3_due_r + 1;
                if (!((dut_r.g_chr_external.u_chr_fetch.state == 3'd0) &&
                      (dut_r.g_chr_external.u_chr_fetch.busy === 1'b0)))
                    c3_drop_r = c3_drop_r + 1;
            end

            // ---------------------------------------------------------- W4
            // Every episode during which the armed bg_lo_q/bg_hi_q differ from
            // the reference's, counted at its start and at its end.  Equal start
            // and end counts is the statement "the difference always healed",
            // which is the transient-versus-permanent question stated as a
            // counter rather than as an opinion.
            if ((dut_a.g_chr_external.bg_lo_q  !== dut_r.g_chr_external.bg_lo_q) ||
                (dut_a.g_chr_external.bg_hi_q  !== dut_r.g_chr_external.bg_hi_q)) begin
                if (c4_ep_open == 0) begin
                    c4_ep_start = c4_ep_start + 1;
                    c4_ep_open  = 1;
                end
            end else if (c4_ep_open != 0) begin
                c4_ep_end   = c4_ep_end + 1;
                c4_ep_open  = 0;
            end

            // ---------------------------------------------------------- W2/W5
            // Gated on the REFERENCE's bg_ready, for the reason
            // tb_chr_wr_collision gives: the reference is the instance whose
            // fetch units were never displaced, and bg_ready is the statement
            // that its first tile has landed.  Before that dot the armed
            // instance has a tile and the reference has none, which is a startup
            // ordering rather than a corrupted fetch.
            if ((dot_a < 9'd256) && (sl_a < 9'd240) &&
                (dut_r.g_chr_external.bg_ready !== 1'b0)) begin
                c2_dots = c2_dots + 1;
                if (dut_a.bg_pattern_index !== dut_r.bg_pattern_index)
                    c2_idx_diff = c2_idx_diff + 1;
                if ((pidx_a !== pidx_r) || (ppal_a !== ppal_r)) begin
                    c2_pix_diff = c2_pix_diff + 1;
                    c5_wrong    = c5_wrong + 1;
                    // W5: is there a recorded drop whose TARGET dot, or a recorded FREEZE ce, within
                    // +-W5_WIN of this dot?  See the header for why both are
                    // needed: the freeze is the ROOT CAUSE and the drop is one of
                    // its consequences, so a freeze that lands on the unit's FIRST
                    // S_BEAT delays the latch without losing the request, and that
                    // wound has no drop to point at.  Both offsets are measured.
                    abs_now = ({9'd0, sl_a} * 18'd341) + {9'd0, dot_a};
                    fd_best = 1000; fd_abs = 1000;
                    fz_best = 1000; fz_abs = 1000;
                    for (t2 = 0; t2 < 16; t2 = t2 + 1) begin
                        if (drop_hist[t2] !== 18'd0) begin
                            cur_d = abs_now - drop_hist[t2];
                            if (cur_d < 0) cur_abs = -cur_d;
                            else           cur_abs =  cur_d;
                            if (cur_abs < fd_abs) begin
                                fd_abs = cur_abs;
                                fd_best = cur_d;
                            end
                        end
                        if (frz_hist[t2] !== 18'd0) begin
                            cur_d = abs_now - frz_hist[t2];
                            if (cur_d < 0) cur_abs = -cur_d;
                            else           cur_abs =  cur_d;
                            if (cur_abs < fz_abs) begin
                                fz_abs = cur_abs;
                                fz_best = cur_d;
                            end
                        end
                    end
                    if (fd_abs <= W5_WIN) begin
                        offset_hist[fd_best + 32] = offset_hist[fd_best + 32] + 1;
                        c5_drop_attr = c5_drop_attr + 1;
                    end
                    if (fz_abs <= W5_WIN) begin
                        off_f_hist[fz_best + 32] = off_f_hist[fz_best + 32] + 1;
                        c5_frz_attr = c5_frz_attr + 1;
                    end
                    found_drop = (fd_abs <= W5_WIN) || (fz_abs <= W5_WIN);
                    if (found_drop !== 1'b0) begin
                        c5_explained = c5_explained + 1;
                    end else begin
                        c5_unexplained_shown = c5_unexplained_shown + 1;
                        if (c5_unexplained_shown <= 8)
                            $display("W5 UNEXPLAINED-WRONG-DOT n=%0d frame=%0d sl=%0d dot=%0d armed_planes=%02h/%02h ref_planes=%02h/%02h bg_base=%04h sp_shadow_differs=%b",
                                     c5_unexplained_shown, frames, sl_a, dot_a,
                                     dut_a.g_chr_external.bg_lo_q,
                                     dut_a.g_chr_external.bg_hi_q,
                                     dut_r.g_chr_external.bg_lo_q,
                                     dut_r.g_chr_external.bg_hi_q,
                                     dut_a.g_chr_external.bg_tile_base,
                                     (dut_a.g_chr_external.sp_shadow
                                      !== dut_r.g_chr_external.sp_shadow));
                    end
                    if (c5_wrong <= 6)
                        $display("W5 WRONG-DOT frame=%0d sl=%0d dot=%0d armed=%02h ref=%02h armed_planes=%02h/%02h ref_planes=%02h/%02h",
                                 frames, sl_a, dot_a, ppal_a, ppal_r,
                                 dut_a.g_chr_external.bg_lo_q,
                                 dut_a.g_chr_external.bg_hi_q,
                                 dut_r.g_chr_external.bg_lo_q,
                                 dut_r.g_chr_external.bg_hi_q);
                end
                // run / gap bookkeeping
                if ((pidx_a !== pidx_r) || (ppal_a !== ppal_r)) begin
                    if (wrong_now == 1'b0) begin
                        if (gap_len > 0) gap_hist[bucket(gap_len)] = gap_hist[bucket(gap_len)] + 1;
                        gap_len = 0;
                    end
                    wrong_now = 1'b1;
                    run_len = run_len + 1;
                    line_wrong = line_wrong + 1;
                end else begin
                    if (wrong_now !== 1'b0) begin
                        run_hist[bucket(run_len)] = run_hist[bucket(run_len)] + 1;
                        run_len = 0;
                        wrong_now = 1'b0;
                    end
                    gap_len = gap_len + 1;
                    if (gap_len > max_correct_run) max_correct_run = gap_len;
                end
                if (dot_a == 9'd255) begin
                    lines_seen = lines_seen + 1;
                    if (line_wrong == 0)
                        lines_no_wrong = lines_no_wrong + 1;
                    if (line_wrong >= 240)
                        lines_all_wrong = lines_all_wrong + 1;
                    line_wrong = 0;
                end
            end

            // sprite shadow convergence, same construction as the write bench:
            // a deferred sprite beat shifts the 16 shadow writes one ce later,
            // so the shadows differ WHILE a line is written; what has to hold is
            // that they agree once the line's sprites are done.
            if (dut_a.g_chr_external.sp_shadow !== dut_r.g_chr_external.sp_shadow)
                s0_shadow_diff = s0_shadow_diff + 1;
            if ((dot_a == 9'd320) && (sl_a < 9'd240)) begin
                s0_shadow_checks = s0_shadow_checks + 1;
                if ((dut_a.g_chr_external.sp_shadow !== dut_r.g_chr_external.sp_shadow) ||
                    (dut_a.g_chr_external.sp_shadow_valid !== dut_r.g_chr_external.sp_shadow_valid))
                    s0_shadow_late = s0_shadow_late + 1;
            end

            // ---------------------------------------------------------- W6
            if (req_a !== 1'b0) c6_fetch_marks = c6_fetch_marks + 1;
            if (we_a  !== 1'b0) begin
                c6_write_marks = c6_write_marks + 1;
                if (write_bits[waddr_a[12:0]] !== 1'b1) begin
                    write_bits[waddr_a[12:0]] = 1'b1;
                    c6_write_distinct = c6_write_distinct + 1;
                end
            end
            if (req_a !== 1'b0) fetch_bits[chr_addr_a[12:0]] = 1'b1;

            // ---------------------------------------------------------- W8
            // The two instances get identical register stimulus, so every
            // register that feeds a fetch address must evolve identically.
            if ((dut_a.v_addr !== dut_r.v_addr) ||
                (dut_a.temp_addr !== dut_r.temp_addr) ||
                (dut_a.write_toggle !== dut_r.write_toggle) ||
                (dut_a.fine_x !== dut_r.fine_x) ||
                (dut_a.control_reg !== dut_r.control_reg) ||
                (dut_a.mask_reg !== dut_r.mask_reg) ||
                (dot_a !== dot_r) || (sl_a !== sl_r))
                c8_reg_mismatch = c8_reg_mismatch + 1;

            // ---------------------------------------------------------- census
            if (reset === 1'b0) begin
                if (^arm_a === 1'bx) dbg_arm_x = dbg_arm_x + 1;
                if (^arm_pend === 1'bx) dbg_pend_x = dbg_pend_x + 1;
                if (^we_a === 1'bx) dbg_we_x = dbg_we_x + 1;
                if (^dut_a.g_chr_external.chr_rd_win === 1'bx) dbg_rdw_x = dbg_rdw_x + 1;
            end
            if (dut_a.g_chr_external.chr_rd_win !== 1'b0)
                arm_beats = arm_beats + 1;
            if (we_a !== 1'b0) begin
                if (bg_mid !== 1'b0) wr_bg_collide = wr_bg_collide + 1;
                if (sp_mid !== 1'b0) wr_sp_collide = wr_sp_collide + 1;
            end

            // ------------------------------------------------------- W3 memory
            if (c3_lat_v_q !== 1'b0) begin
                if (chr_mem_a[c3_lat_addr_q[12:0]] !== c3_lat_data_q)
                    $display("W6 SETUP a $2007 CHR write of %02h had not reached chr_mem[%04h] one ce after its strobe",
                             c3_lat_data_q, c3_lat_addr_q);
                if (chr_mem_r[c3_lat_addr_q[12:0]] !== c3_lat_data_q)
                    c6_write_distinct = c6_write_distinct + 1000000;
            end
            c3_lat_v_q <= 1'b0;
            if (we_a !== 1'b0) begin
                c3_lat_addr_q <= waddr_a;
                c3_lat_data_q <= wdat_a;
                c3_lat_v_q    <= 1'b1;
                // W6 THE PROPERTY THAT ACTUALLY MATTERS.  Address disjointness
                // between the store set and the fetch set is IMPOSSIBLE in CHR
                // RAM -- both fetchers live inside the same 8 KiB -- so the check
                // is that no store ever CHANGED a byte, which is what keeps a
                // pixel difference attributable to the arbitration alone.  The
                // armed address must still equal the reference address, because
                // both come from v_addr and v_addr is checked equal by W8.
                if (wdat_a !== chr_mem_a[waddr_a[12:0]])
                    c6_value_changing = c6_value_changing + 1;
                if (waddr_a !== waddr_r)
                    c6_write_distinct = c6_write_distinct + 1000000;
            end

            // ------------------------------------------- $2007 CHR READ correct
            // The read arm is on the critical path of this bench, so the byte it
            // hands the CPU is checked.
            //
            // THE CHAIN IS TWO ARMS DEEP, not one, and getting that wrong is not
            // cosmetic.  nes_ppu2c02.v:1118 presents read_buffer_reg on reg_dout
            // for a $2007 read, and read_buffer_reg is latched at the read beat
            // from chr_rb_data (nes_ppu2c02.v:1191-1192), which for the CHR half
            // is chr_rdata itself (nes_ppu2c02.v:1061).  So the byte captured at
            // arm N appears on reg_dout only AFTER read beat N's edge, and the CPU
            // latches it at read beat N+1.  A one-deep chain therefore compares
            // byte(arm N) against byte(arm N-1) and reports every read wrong.  The
            // measurement that forced this is recorded rather than hidden: a
            // one-deep version reported 1714 of 9914 CHR reads wrong, every one of
            // them the byte at the neighbouring address, and the design was never
            // wrong there.  tb_chr_arb_collision's C3 carries the same two hangers
            // and says the same thing at nes_ppu2c02.v:446-458.
            if (c3_read_beat !== 1'b0) begin
                rd_checked = rd_checked + 1;
                if (rd_deliver_ok !== 1'b0) begin
                    if (dout_a !== chr_mem_a[rd_deliver_v[12:0]]) begin
                        rd_wrong = rd_wrong + 1;
                        if (rd_wrong < 4)
                            $display("W3 READ-BEAT frame=%0d sl=%0d dot=%0d $2007 CHR read returned %02h where the byte latched for the previous arm at v_addr=%04h is %02h",
                                     frames, sl_a, dot_a, dout_a, rd_deliver_v[14:0],
                                     chr_mem_a[rd_deliver_v[12:0]]);
                    end
                end else begin
                    rd_noarm = rd_noarm + 1;
                end
            end
            if (c3_any_2007 !== 1'b0) begin
                rd_deliver_v  <= rd_pend_v;
                rd_deliver_ok <= rd_pend_ok && c3_read_beat;
                rd_pend_ok    <= 1'b0;
            end
            if (dut_a.g_chr_external.chr_rd_win !== 1'b0) begin
                rd_pend_v  <= dut_a.v_addr;
                rd_pend_ok <= 1'b1;
            end
        end
    end

    // ======================================================================
    // Access sequencer: ONE PPU access per div_phase window, then loop the
    // streaming block forever.  Qualified on div_phase == 0 and not merely on
    // ce: ce is high at div_phase 0, 4 AND 8, so a sequencer that advanced on
    // every ce would burn three ops per window and deliver only the third of
    // each triple to the PPU, dropping $2001 and leaving nothing displayed.
    // ======================================================================
    always @(posedge clk) begin
        if (reset) begin
            op_ptr    <= 0;
            looping   <= 1'b0;
            acc_valid <= 1'b0;
            acc_addr  <= 3'd0;
            acc_we    <= 1'b0;
            acc_din_q <= 8'h00;
            acc_wr_tag<= 1'b0;
            acc_addr_r<= 3'd0;
            acc_we_r  <= 1'b0;
            acc_din_r <= 8'h00;
            arm_pend  <= 1'b0;
            wr_seq    <= 8'h00;
            wr_seq_r  <= 8'h00;
        end else if (ce && (div_phase == 4'd0)) begin
            if (!looping) begin
                if (op_ptr < n_ops) begin
                    acc_valid  <= 1'b1;
                    acc_addr   <= op_addr[op_ptr];
                    acc_we     <= op_we[op_ptr];
                    acc_din_q  <= op_din[op_ptr];
                    acc_wr_tag <= op_we[op_ptr] && (op_addr[op_ptr] == 3'd7);
                    acc_addr_r <= op_addr_r[op_ptr];
                    acc_we_r   <= op_we_r[op_ptr];
                    acc_din_r  <= op_din_r[op_ptr];
                    arm_pend   <= (op_addr[op_ptr] == 3'd7) && (op_we[op_ptr] == 1'b0);
                    op_ptr     <= op_ptr + 1;
                    if (op_ptr + 1 == loop_start)
                        looping <= 1'b1;
                end
            end else begin
                acc_valid  <= 1'b1;
                acc_addr   <= op_addr[op_ptr];
                acc_we     <= op_we[op_ptr];
                acc_din_q  <= op_din[op_ptr];
                acc_wr_tag <= op_we[op_ptr] && (op_addr[op_ptr] == 3'd7);
                acc_addr_r <= op_addr_r[op_ptr];
                acc_we_r   <= op_we_r[op_ptr];
                acc_din_r  <= op_din_r[op_ptr];
                arm_pend   <= (op_addr[op_ptr] == 3'd7) && (op_we[op_ptr] == 1'b0);
                if ((op_ptr + 1 == loop_start + loop_len)) begin
                    op_ptr   <= loop_start;
                    wr_seq   <= wr_seq + 8'd1;
                    wr_seq_r <= wr_seq_r + 8'd1;
                end else begin
                    op_ptr   <= op_ptr + 1;
                end
            end
        end
    end

    // ------------------------------------------------------------------ final
    always @(posedge clk) begin
        if (!reset && ce && fd_a) begin
            frames = frames + 1;
            if (frames >= n_frames_req) begin
                c6_overlap = 0;
                for (i = 0; i < 256; i = i + 1)
                    if ((fetch_bits[i*32 +: 32] & write_bits[i*32 +: 32]) !== 32'd0)
                        c6_overlap = c6_overlap + 1;
                if (wrong_now !== 1'b0)
                    run_hist[bucket(run_len)] = run_hist[bucket(run_len)] + 1;

                $display("--------------------------------------------------------------");
                $display("MODE=%0s frames=%0d", mode_name, frames);
                $display("W3 DROP CENSUS (armed)   bg_fetch_due=%0d accepted=%0d DROPPED=%0d  of which the missing tile's target dot is inside the visible field=%0d",
                         c3_due_a, c3_acc_a, c3_drop_a, c3_drop_vis);
                $display("W7 DROP CENSUS (reference) bg_fetch_due=%0d DROPPED=%0d -- the reference's read bus is never arbitrated, so anything non-zero here would void the A/B",
                         c3_due_r, c3_drop_r);
                $display("W2 PIXEL A/B vs reference: gated visible dots=%0d  PIXEL DIFFS=%0d  bg_pattern_index diffs=%0d",
                         c2_dots, c2_pix_diff, c2_idx_diff);
                $display("W5 CAUSAL LINK: wrong dots=%0d  of which within +-%0d ce of a recorded drop's target dot OR of a recorded freeze=%0d  (unexplained=%0d)",
                         c5_wrong, W5_WIN, c5_explained, c5_wrong - c5_explained);
                $display("W5   attributable to a drop target=%0d, to a freeze=%0d (a wrong dot can be within reach of both)",
                         c5_drop_attr, c5_frz_attr);
$display("W5 OFFSETS FROM THE NEAREST DROP'S TARGET DOT, in ce:");
                $display("W5   off:-12=%0d -11=%0d -10=%0d  -9=%0d  -8=%0d  -7=%0d  -6=%0d   0=%0d   1=%0d   2=%0d   3=%0d   4=%0d   5=%0d   6=%0d",
                         offset_hist[20], offset_hist[21], offset_hist[22], offset_hist[23],
                         offset_hist[24], offset_hist[25], offset_hist[26], offset_hist[32],
                         offset_hist[33], offset_hist[34], offset_hist[35], offset_hist[36],
                         offset_hist[37], offset_hist[38]);
                $display("W5   off:  7=%0d   8=%0d ... 16=%0d  ... rest of the +-%0d window=%0d, beyond the window=%0d",
                         offset_hist[39], offset_hist[40], offset_hist[48],
                         W5_WIN, c5_drop_attr - offset_hist[32] - offset_hist[33]
                         - offset_hist[34] - offset_hist[35] - offset_hist[36]
                         - offset_hist[37] - offset_hist[38] - offset_hist[39]
                         - offset_hist[40] - offset_hist[48],
                         c5_wrong - c5_drop_attr);
                $display("W5 OFFSETS FROM THE NEAREST FREEZE ce, in ce:");
                $display("W5   off: -8=%0d -7=%0d -6=%0d -5=%0d -4=%0d -3=%0d -2=%0d -1=%0d 0=%0d 1=%0d 2=%0d 3=%0d 4=%0d 5=%0d 6=%0d 7=%0d 8=%0d",
                         off_f_hist[24], off_f_hist[25], off_f_hist[26], off_f_hist[27],
                         off_f_hist[28], off_f_hist[29], off_f_hist[30], off_f_hist[31],
                         off_f_hist[32], off_f_hist[33], off_f_hist[34], off_f_hist[35],
                         off_f_hist[36], off_f_hist[37], off_f_hist[38], off_f_hist[39],
                         off_f_hist[40]);
                $display("W5   off: 9=%0d .. 16=%0d .. rest of the +-%0d window=%0d, beyond the window=%0d",
                         off_f_hist[41], off_f_hist[48], W5_WIN,
                         c5_frz_attr - off_f_hist[24] - off_f_hist[25] - off_f_hist[26]
                         - off_f_hist[27] - off_f_hist[28] - off_f_hist[29]
                         - off_f_hist[30] - off_f_hist[31] - off_f_hist[32]
                         - off_f_hist[33] - off_f_hist[34] - off_f_hist[35]
                         - off_f_hist[36] - off_f_hist[37] - off_f_hist[38]
                         - off_f_hist[39] - off_f_hist[40] - off_f_hist[41]
                         - off_f_hist[48],
                         c5_wrong - c5_frz_attr);
                $display("W4 TRANSIENT-OR-PERMANENT: bg_lo_q/bg_hi_q difference episodes opened=%0d closed=%0d  still open at end=%0d",
                         c4_ep_start, c4_ep_end, c4_ep_open);
                $display("W4 wrong-dot RUN histogram (dots wide: count) 1=%0d 2..9=%0d 10..16=%0d 17..32=%0d 33+=%0d",
                         run_hist[0], run_hist[8], run_hist[9], run_hist[10], run_hist[11]);
                $display("W4 correct-dot GAP histogram between runs (dots wide: count) 1=%0d 2..9=%0d 10..16=%0d 17..32=%0d 33+=%0d  longest correct run=%0d",
                         gap_hist[0], gap_hist[8], gap_hist[9], gap_hist[10], gap_hist[11],
                         max_correct_run);
                $display("W4 PER SCANLINE: %0d visible lines measured, %0d with no wrong dot at all, %0d wrong on every dot",
                         lines_seen, lines_no_wrong, lines_all_wrong);
                $display("W1 CONSUMED-THE-BYTE-IT-ASKED-FOR: bg consuming beats=%0d wrong=%0d   sp consuming beats=%0d wrong=%0d",
                         c1_bg_beats, c1_bg_bad, c1_sp_beats, c1_sp_bad);
                $display("S1 CONTENTION: $2007 read arms=%0d   $2007 CHR write beats=%0d, of which %0d found the BACKGROUND unit mid-beat and %0d the SPRITE unit mid-beat",
                         arm_beats, c6_write_marks, wr_bg_collide, wr_sp_collide);
                $display("W9 FROZEN ce INSIDE ONE BACKGROUND TILE: %0d freeze ce in total; per accepted fetch the count was 0 on %0d, 1 on %0d, 2 on %0d, 3 on %0d, 4+ on %0d.  MAX=%0d",
                         c9_freeze_ce, c9_hold_hist[0], c9_hold_hist[1], c9_hold_hist[2],
                         c9_hold_hist[3], c9_hold_hist[4]+c9_hold_hist[5]+c9_hold_hist[6]
                         + c9_hold_hist[7]+c9_hold_hist[8]+c9_hold_hist[9], c9_hold_max);
                $display("W3 THE $2007 CHR READ IS STILL CORRECT: %0d CHR read beats checked, %0d returned the wrong byte, %0d had no arm to check",
                         rd_checked, rd_wrong, rd_noarm);
                $display("W6 ADDRESS CENSUS: fetch request beats=%0d, write beats=%0d over %0d distinct addresses, of which %0d were also fetched (impossible to avoid inside CHR RAM; harmless because no store changes a byte), stores that CHANGED a byte=%0d, cross-instance address mismatches=%0d",
                         c6_fetch_marks, c6_write_marks, c6_write_distinct % 1000000,
                         c6_overlap, c6_value_changing, c6_write_distinct / 1000000);
                $display("W8 REGISTER-AGREEMENT between the two instances: mismatching ce=%0d (v_addr / temp_addr / write_toggle / fine_x / PPUCTRL / PPUMASK / dot / scanline)",
                         c8_reg_mismatch);
                $display("DBG X-CENSUS arm_a=%0d arm_pend=%0d we_a=%0d chr_rd_win=%0d", dbg_arm_x, dbg_pend_x, dbg_we_x, dbg_rdw_x);
                $display("S1 SPRITE shadow differs on %0d ce; checked at dot 320 of %0d visible lines, still differing on %0d",
                         s0_shadow_diff, s0_shadow_checks, s0_shadow_late);

                $display("S1 NAMETABLE CONTRAST=+%0d (adjacent entries differ in %0s tile-number bit(s) the CHR model can see)",
                         nt_mode, (nt_mode != 0) ? "ALL FOUR" : "ONE");
                // -------------------------------------------------------- S1
                if (nt_row0_neighbours < 31)
                    $fatal(1, "S1 the first nametable row has only %0d of 31 horizontally adjacent pairs different, so this bench has degenerated back into the uniform-nametable case it exists to leave behind",
                           nt_row0_neighbours);
                if (nt_row1_neighbours < 31)
                    $fatal(1, "S1 the second nametable row has only %0d of 31 horizontally adjacent pairs different", nt_row1_neighbours);
                if (dut_a.nametable_ram[0] === dut_a.nametable_ram[1])
                    $fatal(1, "S1 nametable entry 0 and 1 are equal, so the nametable is not non-uniform");
                // A row of 32 entries with D distinct values has (32*D - D*(D+1)/2) equal pairs;
                // requiring at least 8 distinct values is the cheap way to say the
                // row is varied rather than a two-value checkerboard.
                if (nt_row0_dupes > 24)
                    $fatal(1, "S1 the first nametable row has at most 7 distinct tile numbers (32 equal pairs out of 496), which is too uniform for a one-tile stream error to be measurable",
                           nt_row0_dupes);

                // -------------------------------------------------------- W1
                if (c1_bg_bad != 0 || c1_sp_bad != 0)
                    $fatal(1, "W1 %0d background and %0d sprite fetch units consumed a byte captured for another master, so a pixel difference below would not be attributable to a MISSING tile",
                           c1_bg_bad, c1_sp_bad);

                // -------------------------------------------------------- W7
                if (c3_drop_r != 0)
                    $fatal(1, "W7 the REFERENCE dropped %0d background fetches, so the A/B is comparing two broken instances and proves nothing",
                           c3_drop_r);

                // -------------------------------------------------------- W6
                if (c6_value_changing != 0)
                    $fatal(1, "W6 %0d $2007 CHR stores CHANGED a byte, so a legitimately changed byte could have reached a pixel and the A/B would not be a proof",
                           c6_value_changing);
                if (dbg_arm_x != 0 || dbg_pend_x != 0 || dbg_we_x != 0 || dbg_rdw_x != 0)
                    $fatal(1, "X-CENSUS arm_a was x on %0d ce, arm_pend on %0d, we_a on %0d, chr_rd_win on %0d, so the contention and arm counts above were counting unknowns",
                           dbg_arm_x, dbg_pend_x, dbg_we_x, dbg_rdw_x);
                if ((c6_write_distinct / 1000000) != 0)
                    $fatal(1, "W6 the two CHR arrays diverged on %0d stores, so the pixel A/B compares two different memories",
                           c6_write_distinct / 1000000);
                if (wr_strobe_r != 0)
                    $fatal(1, "W6 the reference asserted its own $2007 CHR write strobe on %0d ce, so its chr_hold would freeze its fetch units too and the A/B would be comparing two broken instances",
                           wr_strobe_r);

                // -------------------------------------------------------- W8
                if (c8_reg_mismatch != 0)
                    $fatal(1, "W8 the two instances disagreed on a PPU register that feeds the fetch address on %0d ce, so the reference is not the picture this stimulus asked for",
                           c8_reg_mismatch);

                // -------------------------------------------------------- W3
                if (rd_wrong != 0)
                    $fatal(1, "W3 %0d of %0d $2007 CHR reads returned the wrong byte", rd_wrong, rd_checked);

                // -------------------------------------------------------- W5
                if (c5_explained != c5_wrong)
                    $fatal(1, "W5 only %0d of %0d wrong pixels lie within +-%0d ce of a recorded drop, so the dropped fetches are NOT the whole mechanism and the verdict below would be unsound",
                           c5_explained, c5_wrong, W5_WIN);

                // -------------------------------------------------------- mode
                if (!m_rd && !m_wr)
                    $display("S1 mode=none: no $2007 CHR traffic was generated, so the control run must show zero drops and zero pixel diffs");
                if (!m_rd && !m_wr) begin
                    if (c3_drop_a != 0)
                        $fatal(1, "S1 the control run dropped %0d background fetches although it generated no $2007 CHR traffic at all", c3_drop_a);
                    if (c2_pix_diff != 0)
                        $fatal(1, "S1 the control run rendered %0d pixels differently from the reference although it generated no $2007 CHR traffic at all, so a non-uniform nametable alone is corrupting the picture and the other runs prove nothing", c2_pix_diff);
                end else begin
                    if (c3_drop_a == 0)
                        $fatal(1, "S1 this run dropped ZERO background fetches, so it does not exercise the zero-slack pipeline at all");
                    if (c2_pix_diff == 0)
                        $display("NOTE this run dropped %0d fetches and rendered 0 differing pixels", c3_drop_a);
                end

                $display("PASS tb_bg_fetch_drop");
                $finish;
            end
        end
    end

    initial begin
        void_int = 0;
        if (m_rd != 0 && m_wr != 0)      mode_name = "both";
        else if (m_rd != 0)              mode_name = "rd";
        else if (m_wr != 0)              mode_name = "wr";
        else                             mode_name = "none";
        $display("tb_bg_fetch_drop mode=%0s frames=%0d nt=%0d", mode_name, n_frames_req, nt_mode);
        build_script;
        n_ops = n_ops_init;
        $display("DBG m_rd=%0d m_wr=%0d n_ops_init=%0d loop_start=%0d loop_len=%0d",
                 m_rd, m_wr, n_ops_init, loop_start, loop_len);
        for (i = loop_start; i < n_ops_init; i = i + 1)
            $display("DBG loop op %0d addr=%0d we=%0d din=%02h", i - loop_start,
                     op_addr[i], op_we[i], op_din[i]);
        frames = 0;
        // Hold reset over two full frames so dot/scanline and both instances'
        // internal memories are in a known state.
        repeat (2 * 357368) @(posedge clk);
        reset <= 1'b0;
    end

    initial begin
        #200000000;
        $fatal(1, "WATCHDOG no frame_done within 200 ms of simulated time");
    end

endmodule
