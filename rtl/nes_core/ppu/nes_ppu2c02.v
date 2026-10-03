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
//     both background windows ([.., 253] and [324, ..]); the 324 is
//     bg_fetch_pre_first = (dot == 9'd324) in g_chr_external, and the two
//     pre-render carries it starts are at dots 324+2..324+4 and
//     (340-fine_x)+2..(340-fine_x)+4, i.e. inside [326, ..]. No background
//     request beat is ever masked by the sprite, which is why the priority order
//     does not change any background behaviour today.
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
//   nes_ppu_sprite's external generate splits one 16-bit chr_sh into the two
//   pattern planes (`assign s_plane_lo = chr_sh[7:0]; assign s_plane_hi =
//   chr_sh[15:8];`), so the PPU has to supply BOTH bytes of the row, not one
//   byte standing in for both. The slot index is taken from that unit's
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
//   plane, which are the same two bytes the internal path reaches as byte
//   s_pat_addr and byte s_pat_addr+8 of the tile. They are CONCATENATED here,
//   {sp_plane_hi, sp_plane_lo}, not combined: chr_sh[15:8] carries
//   CHR[s_pat_addr+8] and chr_sh[7:0] carries CHR[s_pat_addr], because
//   s_pat = {s_plane_hi[s_xbit], s_plane_lo[s_xbit]} makes bit 3 of a sprite
//   pattern the high plane on both paths. Presenting their OR (or the same byte
//   to both planes) would have kept the silhouette exact while forcing every
//   opaque pixel to palette index 3, which is a different image rather than an
//   approximation of the same one, and it could never be pixel-compared against
//   the internal path.
//   sp_shadow_valid gates the mux because nes_sprite_chr_fetch's shadow register
//   has no reset: before the first completed line it is X, and X on chr_sh would
//   make slot_opaque / sprite_pixel X inside nes_ppu_sprite and corrupt the pixel.
//
// Sprite prefetch timing: the start dot and the address line are separate axes
//   pat_addr_o is a NEXT-LINE address. nes_ppu_sprite hands out the pattern
//   addresses of scanline + 1 (wrapping 261 -> 0), and sp_start stays at dot 257
//   of the line whose hblank the fetch actually runs in. The two facts only
//   combine into the right schedule read together:
//     dot 257 of line L   sp_start pulses, the fetch unit latches pat_addr_o,
//                         which is line L+1's address set
//     dot 259..290        the 16 chr_req beats at line L+1's addresses
//     dot 292 of line L   shadow_valid rises holding line L+1's planes
//     dot 0..255 of L+1   the pixels of line L+1 consume that shadow
//   shadow_valid cannot rise before dot 292 of line L, and dots 0..255 of line L
//   are already displayed by then, so a line-L address latched at line L's own
//   dot 257 could never serve line L: it would always be one line late. The
//   retiming therefore lives in the address, not in the start dot, and sp_start
//   stays at (dot == 9'd257) on every scanline. Moving the start dot back to
//   line L-1's 257 would look equivalent and is not: it slides the whole
//   [257,291] window measured above onto line L-1's hblank without changing the
//   fetch latency, and it would no longer be the window derived from dot 257 that
//   the non-collision argument rests on. The cost of the duplicated next-line
//   derivation in nes_ppu_sprite is one extra 64-entry OAM range scan and 8 more
//   nth_set walks, both of which re-evaluate only when the scanline or OAM
//   changes, so it is a per-line rather than a per-dot cost.
//
// CHR address convention (EXTERNAL_CHR=1): the three notations now agree
//   All three fetchers name the same CHR byte with the same number, expressed
//   three ways:
//     nes_ppu_sprite, internal : chr[{s_pat_addr, 3'b000} +: 8] and
//                               chr[({s_pat_addr, 3'b000} + 13'd64) +: 8]. These
//                               are BIT part-selects into a 65536-bit vector, so
//                               their base is bit s_pat_addr*8, which is byte
//                               s_pat_addr, and 13'd64 bits is +8 bytes.
//     nes_ppu_sprite, external : slot g low plane at shadow[g*16 +: 8], high
//                               plane at shadow[g*16+8 +: 8]
//     nes_sprite_chr_fetch     : chr_addr = pat_addr + plane*8, computed in 14
//                               bits and masked with 14'h3FFF
//   There is no *8 scaling on the sprite side any more. pat_addr is already
//   tile*16 + fine after the 13-bit truncation, the two planes are 8 bytes
//   apart, and that byte address is what chr_addr carries, which is how
//   nes_chr_fetch_unit already drove the background pattern address, so all
//   three agree. tb_nes_ppu2c02_ext_chr.v checks every sprite request address
//   and every shadow byte against its CHR model, and any reintroduction of a
//   *8 here surfaces there as an 8x-too-high address and a fatal, so the old
//   "sprite prefetcher is 8x above" hazard no longer exists.
//   The port is 14 bits wide and the address is 13, so bit 13 has no address
//   to carry; the third section below gives the arithmetic that keeps it 0.
//
// chr_addr is a LOCAL CHR byte address, and the mapper translates it
//   The local space is ONE 8 KiB pattern window, $0000-$1FFF, addressed by
//   {table, tile[7:0], 1'b0, fine_y[2:0]}. PPUCTRL[3] / [4] select WITHIN that
//   one space; they do not address two separate 4 KiB banks, and there is no
//   second 8 KiB up there for chr_addr[13] to name. chr_addr is NOT a CHR
//   ROM/RAM address: the mapper is what makes it the final one. Every mapper's
//   chr_bank_offset is already that final address, produced as
//   `(<bank> << K) | <local bits of ppu_addr>` -- nes_mapper_cnrom.v:41 is
//   `(chr_bank_ext << 13) | ppu_addr[12:0]`, nes_mapper_mmc1.v:65 is
//   `(chr_bank_ext << 12) | ppu_addr[11:0]`, nes_mapper_mmc3.v:135 is
//   `(chr_window_ext << 10) | ppu_addr[9:0]` -- and a memory owner indexes CHR
//   with it directly (`chr_rom[chr_bank_offset[15:0]]` in the mapper TBs). So
//   ppu_addr must be driven with the LOCAL address this port presents, and the
//   PPU adds no bank offset of any kind. A `chr_addr_final = chr_bank_offset +
//   ppu_local_addr` style adder on this side would be wrong twice over.
//   chr_bank_offset IS a COMBINATIONAL function of ppu_addr, so chr_addr ->
//   mapper.ppu_addr -> chr_bank_offset -> back into chr_addr would be a
//   zero-delay combinational loop, which is the whole reason the adder must
//   not exist here. That wiring is real now, not hypothetical:
//   nes_system_v5.v:212 parked it on `wire [13:0] mapper_ppu_addr = 14'h0000;`
//   and left the loop latent, whereas nes_system_v6.v:231 binds
//   `wire [13:0] mapper_ppu_addr = ppu_chr_addr;` and drives ppu_addr for
//   real. It is still NOT a loop, and the reason is on this side of the port:
//   chr_addr is a combinational mux between two REGISTERED fetch-unit outputs
//   (`assign chr_addr = sp_bus_sel ? sp_chr_addr_raw : bg_chr_addr_raw;`),
//   the mapper's chr_bank_offset is a function of the mapper's own bank
//   registers and ppu_addr alone, and in v6 it leaves the PPU on a top-level
//   port (`assign chr_final_addr = mapper_chr_bank_offset;`) while chr_rdata
//   is that module's own input port. Nothing in the mapper reaches back into a
//   PPU address, and chr_rdata only ever lands in register destinations
//   (bg_lo_q / bg_hi_q and the 128-bit shadow), so there is no combinational
//   path at all from CHR data to chr_addr. The translation model is the
//   hardware one: a cartridge mapper decodes the PPU address bus, it does not
//   post-add to it.
//
// chr_addr[12] is the pattern-table select, and chr_addr[13] is dead weight
//   Both fetchers build {table, tile, 1'b0, fine}, so the select lands on bit
//   12 and the tile number lands in bits [11:4]. Background: bg_tile_base is
//   13 bits wide and is assigned
//   {control_reg[4], bg_name_target, 4'b0000} + {10'b0, bg_fine_y_target},
//   i.e. 1 + 8 + 4 bits, so control_reg[4] -- PPUCTRL[4], the 2C02's
//   background pattern-table address bit -- is bit 12.
//   Sprite: s_pat_addr is assigned {s_table, s_tile, 1'b0, s_fine[2:0]} at
//   nes_ppu_sprite.v:295, i.e. 1 + 8 + 1 + 3 bits, so s_table sits on bit 12
//   too, and it is ctrl[5] ? s_tile_byte[0] : ctrl[3]
//   (nes_ppu_sprite.v:292), which is the 8x16 tile-pair bit in 8x16 mode.
//   2 tables x 256 tiles x 16 B is 8 KiB, so both halves of the PPUCTRL
//   [3] / [4] pair select inside ONE window and the local address is 13 bits
//   on a 14-bit port. chr_addr[13] is therefore declared but never driven:
//     background : nxt_addr = base_q + {3'b0, idx_q, 4'd0} + (pl_q ? 8 : 0)
//                  (nes_chr_fetch_unit.v:35) over a 13-bit base_q that tops
//                  out at 0x1FF7, and this PPU instantiates the unit with
//                  tile_count = 1, so idx_q stays 0 and the largest address is
//                  0x1FF7 + 8 = 0x1FFF
//     sprite     : plane_byte = {1'b0, pat} + (p ? 8 : 0), masked 14'h3FFF
//                  (nes_sprite_chr_fetch.v:85-86) over a 13-bit pat whose bit 3
//                  is the hard 1'b0, so pat <= 0x1FF7 and 0x1FF7 + 8 = 0x1FFF.
//                  The mask therefore never fires and bit 13 stays clear.
//   A run of tb_nes_system_v6.v counted 62678 CHR requests in total, 20960 of
//   them in its last frame, and found local chr_addr[13] set on none of them
//   while local chr_addr[12] was set on 16768 of that frame's 20960 -- so the
//   table select really does cross the port and the bit above it really does
//   not. That is a structural bound rather than a coverage gap: no stimulus
//   can raise a bit that neither fetch unit can produce. So every mapper may
//   drop it, and none of them loses anything by doing so: cnrom keeps only
//   ppu_addr[12:0], mmc1 only ppu_addr[11:0], mmc3 only ppu_addr[9:0], nrom and
//   uxrom only ppu_addr[12:0] (nes_mapper_cnrom.v:41, nes_mapper_mmc1.v:65,
//   nes_mapper_mmc3.v:135, nes_mapper_nrom.v:26, nes_mapper_uxrom.v:47).
//   The pattern-table select is a PPU-internal decode of the same 8 KiB, and a
//   mapper has no business seeing it. What the mappers do instead is consume
//   bit 12 for their own banking, because that is where their bank number
//   lives once the bank is smaller than 8 KiB:
//     cnrom                (chr_bank_ext << 13) | ppu_addr[12:0] -- an 8 KiB
//                         bank, so the table select stays an address bit
//     nrom, uxrom          ppu_addr[12:0] -- no banking at all, so the select
//                         is simply the CHR address bit it always was
//     mmc1                (chr_bank_ext << 12) | ppu_addr[11:0] -- 4 KiB banks,
//                         so the select is absorbed into the bank number
//     mmc3                (chr_window_ext << 10) | ppu_addr[9:0] -- 1 KiB
//                         windows, so bits [12:10] are absorbed the same way
//   The single consequence left for a testbench or a future CHR memory owner
//   is that a CHR image is mirrored per 8 KiB, so an 8 KiB CHR RAM must index
//   on chr_addr[12:0]. tb_nes_ppu2c02_ext_chr.v already does exactly that
//   (`chr_rdata_q <= chr_mem[addr_b[12:0]]`), which is what g_chr_internal's
//   `chr_ram[address[12:0]]` does too, and since the address never exceeds
//   0x1FFF that truncation is lossless rather than a mirror of anything.
//
// Both fetchers number tiles the same way: one layout, no half-table
//   An earlier revision of this block recorded an asymmetry here and told the
//   reader not to remove it: the background tile index in chr_addr[11:4] versus
//   the sprite tile index in chr_addr[6:4], the latter because s_pat_addr used
//   to be formed as {s_table, 5'b00000, s_tile, 1'b0, s_fine[2:0]} over a
//   3-bit s_tile, i.e. a 128-tile half-table. That is no longer the code. The
//   sprite tile number is 8 bits wide today, and there is no half-table left
//   anywhere in the unit: s_tile is the OAM tile byte in 8x8 mode and
//   {s_tile_byte[7:1], s_row[3]} in 8x16 mode (nes_ppu_sprite.v:293), with no
//   bit of it masked off, and s_table is a one-bit decode of ctrl and the OAM
//   tile byte rather than a separate table register (nes_ppu_sprite.v:292).
//   So the sprite unit now numbers all 256 tiles of a table in 8x8 mode, and
//   the full tile pairs in 8x16 mode, where the 32-byte pair is picked by
//   rounding the OAM number down to a multiple of 2 and the row picks the half.
//   Both fetchers therefore put the tile number in the same 8 bits, so there
//   is a single CHR layout on which background and sprite agree, and the
//   address checks in tb_nes_ppu2c02_ext_chr.v are recomputed on that layout.
//   Treat this as settled rather than as a deliberate deviation. Re-narrowing
//   s_tile would not preserve a distinction, it would reintroduce the
//   aliasing a 3-bit add cannot escape: tile 8 and above folding onto tiles
//   0..7, and in 8x16 the lower half of tile 7 landing on tile 0.
//
// chr_addr is stale outside a request beat; the memory side must register
//   Both units REGISTER their chr_addr: nes_chr_fetch_unit latches it one ce
//   ahead of the beat and nes_sprite_chr_fetch does the same, so between beats
//   the port keeps presenting the previous address rather than a defined idle
//   value. chr_req is the only qualification of the address. A memory owner must
//   therefore register the read and gate it with chr_req, exactly as
//   tb_nes_ppu2c02_ext_chr.v does with its one-ce-late `chr_rdata_q`; a
//   combinational read of chr_addr would return the wrong byte for every beat
//   that follows an idle gap.
//
// chr_waddr/chr_we/chr_wdata are the $2007 write half of that same port, and in
//   the external branch they are the only way a byte reaches CHR: the write is
//   not mirrored into a local array, it is handed to whatever owns the CHR bus.
//   chr_waddr carries the write address, which is the PRE-increment v_addr:
//   reg_cs is a one-clk pulse taken at div_phase == 0, and v_addr is incremented
//   by that same beat, so the address is only correct while it is combinational.
//   A registered strobe would have to be paired with a new 14-bit address
//   register (because v_addr has already moved) and would land one ce late.
//   The guard v_addr < 15'h2000 implies v_addr[14:13] == 0, so chr_waddr and
//   v_addr[12:0] are the same number; the mask on the port is wire hygiene, not
//   a behavioural guard. v_addr[12] is a REAL address bit that selects the
//   $1000-$1FFF half of the window, exactly as it does for a read. PPUCTRL[4]
//   and PPUCTRL[5] are FETCH table selects: they steer the two fetch units and
//   play no part in forming a $2007 write address.
//   chr_we is a one-clk strobe qualified by reg_cs && reg_we && reg_addr == 3'd7
//   and the $2000 guard, so it is one clk wide, and it NEVER qualifies a read:
//   chr_req is the statement that whoever owns the CHR bus reads chr_addr on
//   this ce, and it now also covers the $2007 read arm: it is
//   chr_rd_win || (sp_bus_sel ? sp_chr_req : bg_chr_req), and chr_addr is
//   chr_rd_win ? v_addr[13:0] : (sp_bus_sel ? sp_chr_addr_raw : bg_chr_addr_raw),
//   so the read arm and the fetch arbiter can each put an address on the bus.
//   g_chr_internal has no external bus, so there it drives chr_waddr to
//   14'h0000 and leaves chr_we/chr_wdata at 0.
//
// $2007 external-CHR read-back (chr_rd_arm, EXTERNAL_CHR=1)
//   chr_rd_arm is the $2007 read half of the external CHR port and completes the
//   pair with chr_waddr/chr_we/chr_wdata. A nametable or palette $2007 read is
//   answered from PPU-internal RAM exactly as before and does not use this path;
//   only v_addr < 15'h2000 does, because only that half lives on the CHR bus.
//
//   The beat and the $2007 access are SKEWED, and that skew is what sets the arm
//     In nes_system_v6 the CPU sees bus_din and latches it on the posedge whose
//     PRE-EDGE div_phase is 0, while this PPU's reg_cs (ppu_xfer) is a level that
//     is high only while div_phase is 0, so the consuming $2007 read and the arm
//     can never be the same clk: the arm is 4 clk ahead of the read beat. That
//     skew is not cosmetic, it is load bearing, and the derivation is:
//       * the external CHR memory registers chr_rdata on every ce_ppu edge, and
//         ce_ppu is high at div_phase 0, 4 and 8
//       * for the byte to be VALID while the CPU latches, it must have been
//         captured at the div_phase == 8 edge, so the address has to be on the
//         bus during div_phase 8
//       * v_addr only changes on a $2007 access, so it is stable across the
//         whole 0..8 window and no $2007 timing guess enters this
//     The arm is therefore raised by the SYSTEM on exactly one clk: the one whose
//     pre-edge div_phase is 8, gated by cpu_bus_ready so that exactly one arm is
//     raised per $2007 read (the PPU access costs the CPU two cycles and
//     cpu_bus_ready is still low during the first of them).
//
//   THE LEAD HAS ZERO SLACK. There is no spare ce anywhere in
//     v_addr -> chr_addr -> mapper -> chr_final_addr -> CHR memory -> chr_rdata
//   so ANY register inserted anywhere in that chain -- a one-clk address pipe, a
//   "cleaner" registered chr_addr, a registered mapper bank offset -- moves the
//   capture one ce later and returns the PREVIOUS byte. It will not error, it
//   will silently return a stale pattern byte, and nothing in this module or in
//   the testbenches will fail. That is why chr_addr is still a combinational
//   mux over REGISTERED fetch-unit outputs, why mapper_ppu_addr is a
//   combinational expression, and why the read address deliberately RIDES
//   chr_addr rather than getting a port of its own.
//
//   What the read costs, and what it no longer costs
//     The byte the CPU receives is CORRECT, at the mapper-translated address, in
//     any scanline state, and it still is: the arm phase did not move, no
//     register was added to the read address path, and read_buffer_reg still
//     latches the same chr_rdata on the same ce edge.  See "CHR read arm versus
//     the two fetch units" at the arbiter for why a deferred arm was not an
//     option.
//
//     It used to cost one in-flight fetch BYTE: an arm landing on a fetch unit's
//     S_BEAT took the address, the memory captured the $2007 pattern byte, and
//     the unit consumed it one ce later with bg_valid asserted.  One background
//     8x8 cell or one sprite slot plane, silently wrong, confined to the scanline
//     the read was issued on.  That is FIXED: a fetch unit found mid-beat on an
//     arm beat has its clock enable suppressed for that one ce, so the beat is
//     deferred and repeated rather than consumed with the wrong byte.  Measured,
//     both directions, on tb/ppu/tb_chr_arb_collision.v (regression target
//     chr-arb-tb), which streams $2007 CHR reads through the visible field with
//     PPUMASK showing background and sprites and therefore has no invisible-set
//     guard at all:
//       before: 25164 arms, 4713 against a background mid-beat, 1194 against a
//         sprite one; 4694 background and 1186 sprite units consumed a byte
//         captured for the arm; 14943 of 184320 rendered pixels differed from an
//         otherwise identical PPU with chr_rd_arm tied low.
//       after: 2652 and 3352 displaced beats, every one of them deferred; 0
//         background and 0 sprite units consumed a foreign byte; 0 of 184320
//         pixels differ; the $2007 read itself is still correct on all 25070
//         checked accesses.
//     The sprite shadow now lags by one ce WHILE a line is being written and has
//     converged by dot 320 on all 720 visible lines, and the background plane
//     latches differ on 226 of 268326 ce with no pixel consequence.  Both are the
//     one-ce deferral, not a lost byte.
//
//     What is STILL true and still costs something: the contention itself.  An
//     arm and a fetch beat still ask for the bus on the same ce -- 90 of 396 arms
//     in tb_nes_system_v6, which fatals if that count is ever zero so a design
//     that stopped contending could not pass silently -- and the arm still takes
//     the address, because the read has zero slack and must.  What changed is
//     that the loser no longer CONSUMES anything.  Two consequences a memory
//     owner must know:
//       * a fetch beat can now be serviced one ce later than it used to be, so
//         chr_req can be high on two consecutive ce for a longer reason than the
//         arm (below), and
//       * the $2007 CHR WRITE still takes the mapper address bus away from a
//         fetch unit on its own beat (risk L-17, unresolved, 22 of 96 write beats
//         in tb_nes_system_v6, 0 of them on a displayed line).  This change does
//         not touch it and must not be read as having fixed it.
//     Scanline 261 is EXPLICITLY NOT in the invisible set that W3-10 uses and
//     must not be lumped in with it: the pre-render line still runs a background
//     carry fetch at dot 340 and a sprite prefetch at dots 259..290, and both of
//     those feed line 0.
//     Mid-frame CHR reads with rendering enabled ARE now claimed safe against
//     the fetch units, and that claim rests on the byte check, not on the scanline
//     the read happened to land on.
//
//   Consecutiveness of chr_req, which the read master can affect
//     chr_rd_win feeds chr_req directly, so a read arm that lands on the ce_ppu
//     edge immediately after a fetch request beat makes chr_req high on two
//     consecutive ce. This is why the read arm RAISES chr_req instead of riding
//     chr_addr quietly: the memory contract stays "capture the address on every
//     ce where chr_req is high, deliver it registered one ce later" rather than
//     being weakened to "capture unconditionally, the PPU will only ever ask on
//     some of those ce". A memory owner must therefore honour chr_req for read
//     arms too, and must not treat a read arm as a beat it can skip.  The two
//     beats are each serviced correctly; what is lost is the beat the loser
//     expected, exactly as the sprite-vs-background argument above describes.
//     tb_nes_system_v6's P0-8 currently asserts the STRONGER property that
//     chr_req is never high on two consecutive ce, and this read master is the
//     first producer that can break it. MEASURED, not assumed: a throwaway bench
//     (outside the repo, so it gates nothing) drove a back-to-back $2007 read
//     loop at the maximum rate the two-cycle $2007 cost allows, with PPUMASK=$1E
//     and two sprites in OAM, over two frames:
//       178684 ce, 7938 arm beats, 29781 read beats
//       3750 ce with chr_req high on two consecutive ce, and ALL 3750 of them
//         touch a read arm -- 2999 against a background beat, 751 against a
//         sprite beat. The identical run with chr_rd_arm tied to 1'b0 gives 0.
//       7938 of 7938 arm beats returned the CORRECT mapper-translated byte, the
//         check being the direct one: at the read beat, one ce after the arm
//         beat, chr_rdata already holds chr_mem[the address the arm presented].
//       with chr_rd_arm tied to 1'b0, read_buffer_reg was 8'h00 on all 7935
//         CHR-half reads, so the fail-safe degrades to the documented 8'h00 and
//         never to a fetch byte.
//     So the honest statement is that chr_req may now be consecutive whenever the
//     CPU reads $2007 while a fetch unit is asking for the bus; the read itself
//     is correct either way. Generalising P0-8 is a testbench question, not an
//     rtl one, and it is NOT done here.
//     The freeze adds a second, independent way for two consecutive ce to carry
//     chr_req: a deferred unit re-raises it on the ce after the arm.  That is the
//     same contract from the memory's point of view -- capture the address on
//     every ce where chr_req is high -- and on the repeated ce the address is the
//     SAME one, so a memory that captured it on the frozen beat simply captures
//     the same byte again.
//
//   g_chr_internal: unchanged behaviour. It drives chr_waddr to 14'h0000,
//   leaves chr_we/chr_wdata at 0, answers $2007 reads from its own chr_ram, and
//   consumes nothing, so chr_rd_arm is left unconnected in that branch.
//
//   pixel_pal is the full palette byte for the pixel currently on the pin, and is
//     the intended key for the colour LUT that lives in the platform top.  pixel_index
//     stays a 4-bit output and is now exactly pixel_pal[3:0] on every pixel, by
//     construction, so the two ports can never describe different colours.
//
//     The byte layout is the 2C02 palette RAM layout.  This PPU stores the byte the
//     CPU wrote to $3F00-family verbatim (palette_ram[palette_index_map(v_addr[4:0])]
//     <= reg_din, no field is ever split out), so the layout is whatever the ROM
//     wrote and the PPU places no structure on it:
//       bits [5:4] colour/level, bits [3:0] luminance, bits [7:6] NOT colour.
//     The colour axis is [5:4], not [7:6].  Both in-repo references agree: cNES
//     .slim/clonedeps/repos/caseif__cNES/src/ppu.c:94-111 tabulates exactly 64 RGB
//     entries in 4 rows of 16 and indexes them with `palette_index % 64` at line 1125,
//     so the key is the low 6 bits; and ObaraEmmanuel__NES/src/ppu.c:164 forms the
//     readable byte as `palette[..] & 0x3f | (latch & 0xc0)`, naming bits 7:6 as open
//     bus that palette RAM does not store at all.  Exporting only mixed_pixel_value[3:0]
//     therefore dropped the colour axis (bits 5:4), halving the reachable colours from
//     64 to 16, which is what made the previous 4-bit top-level table render the NES
//     in only one quarter of its palette.
//
//     Because bits 7:6 are open bus on real hardware but this PPU stores the whole
//     byte, a top-level LUT must treat only bits [5:0] as meaningful: either index a
//     64-entry table with pixel_pal[5:0], or replicate the 64 canonical entries across
//     all four values of bits 7:6 in the 256-entry image.
//
//     greyscale (PPUMASK[0]) masks the byte with 8'h30, which clears the luminance
//     nibble and leaves the colour/level bits alone.  Reachable values under greyscale
//     are therefore exactly four: 8'h00, 8'h10, 8'h20, 8'h30 -- the four grey levels,
//     which is what the real chip does.  Same conclusion from both references:
//     cNES ppu.c:469-471 applies `index &= 0x30` on monochrome, and
//     ObaraEmmanuel__NES/src/ppu.c:165-167 applies `val & 0xf0`, which over a palette
//     RAM byte contributing 6 bits is again `pal & 0x30`.  The previous
//     `pixel_index & 4'h3` was wrong twice over: it kept only luminance bits [3:2], so
//     it kept 4 of the wrong 16 luminance values and discarded the colour axis
//     entirely.  Masking with 8'h3F instead would clear bits 7:6, which carry no
//     colour, and would make greyscale a no-op on all 64 reachable bytes.
//
//     KNOWN DEVIATION, not implemented here: colour emphasis, PPUMASK[7].  mask_reg[7]
//     is never read anywhere in this PPU, so emphasis is a genuine no-op.  That is
//     correct to leave alone here, because emphasis scales the output of the LUT in
//     the platform top and so is not a property of this byte at all.

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
    output reg [7:0] pixel_pal,
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
    output wire [13:0] chr_waddr,
    output wire chr_req,
    output wire [13:0] chr_addr,
    output wire chr_we,
    output wire [7:0] chr_wdata,
    input wire chr_rd_arm,
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
wire        bg_cys_ge30;
wire        bg_cys_ge60;
wire        bg_cys_ge90;
wire        bg_cys_ge120;
wire [6:0]  bg_cys_s1;
wire [6:0]  bg_cys_s2;
wire [6:0]  bg_cys_s3;
wire [6:0]  bg_cys_s4;
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
assign bg_cys_ge30  = (bg_coarse_y_sum >= 7'd30);
assign bg_cys_ge60  = (bg_coarse_y_sum >= 7'd60);
assign bg_cys_ge90  = (bg_coarse_y_sum >= 7'd90);
assign bg_cys_ge120 = (bg_coarse_y_sum >= 7'd120);
assign bg_cys_s1 = bg_cys_ge30 ? (bg_coarse_y_sum - 7'd30) : bg_coarse_y_sum;
assign bg_cys_s2 = (bg_cys_s1 >= 7'd30) ? (bg_cys_s1 - 7'd30) : bg_cys_s1;
assign bg_cys_s3 = (bg_cys_s2 >= 7'd30) ? (bg_cys_s2 - 7'd30) : bg_cys_s2;
assign bg_cys_s4 = (bg_cys_s3 >= 7'd30) ? (bg_cys_s3 - 7'd30) : bg_cys_s3;
assign bg_coarse_x = bg_coarse_x_sum[4:0];
assign bg_vertical_sections = {6'b0, (bg_cys_ge30 ^ bg_cys_ge60 ^ bg_cys_ge90 ^ bg_cys_ge120)};
assign bg_coarse_y = bg_cys_s4[4:0];
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
wire        chr_rb_cs;
wire [7:0]  chr_rb_data;
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
        assign bg_pattern_low = chr_ram[bg_pattern_addr];
        assign bg_pattern_high = chr_ram[bg_pattern_addr + 13'd8];

        wire [103:0] sprite_pat_cur_bus;
        wire [127:0] sprite_chr_slots;

        for (flat_i = 0; flat_i < 8; flat_i = flat_i + 1) begin : g_sprite_chr_slots
            assign sprite_chr_slots[flat_i * 16 + 0 +: 8]
                = chr_ram[sprite_pat_cur_bus[flat_i * 13 +: 13]];
            assign sprite_chr_slots[flat_i * 16 + 8 +: 8]
                = chr_ram[sprite_pat_cur_bus[flat_i * 13 +: 13] + 13'd8];
        end

        nes_ppu_sprite #(
            .EXTERNAL_CHR(1'b0),
            .PER_SLOT_CHR(1'b1)
        ) u_sprite (
            .clk(clk),
            .reset(reset),
            .ce(ce),
            .oam(sprite_oam_bus),
            .chr(65536'd0),
            .chr_sh(16'h0000),
            .chr_slots(sprite_chr_slots),
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
            .pat_addr_cur_o(sprite_pat_cur_bus)
        );

        always @(posedge clk) begin
            if (!reset) begin
                if (reg_cs && reg_we && (reg_addr == 3'd7) && (v_addr < 15'h2000))
                    chr_ram[v_addr[12:0]] <= reg_din;
            end
        end

        assign chr_waddr = 14'h0000;

        wire [13:0] chr_rb_eff;
        assign chr_rb_eff  = (v_addr < 15'h3F00) ? v_addr[13:0]
                                                 : palette_underlay_address(v_addr);
        assign chr_rb_cs   = !reset && reg_cs && !reg_we && (reg_addr == 3'd7);
        assign chr_rb_data = (chr_rb_eff < 14'h2000) ? chr_ram[chr_rb_eff[12:0]]
                            : (chr_rb_eff < 14'h3F00) ? nametable_ram[mirror_nametable(chr_rb_eff[11:0])]
                                                      : palette_ram[palette_index_map(chr_rb_eff[4:0])];
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
        wire        bg_cys_ge30_nl;
        wire        bg_cys_ge60_nl;
        wire        bg_cys_ge90_nl;
        wire        bg_cys_ge120_nl;
        wire [6:0]  bg_cys_s1_nl;
        wire [6:0]  bg_cys_s2_nl;
        wire [6:0]  bg_cys_s3_nl;
        wire [6:0]  bg_cys_s4_nl;
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
        assign bg_cys_ge30_nl  = (bg_coarse_y_sum_nl >= 7'd30);
        assign bg_cys_ge60_nl  = (bg_coarse_y_sum_nl >= 7'd60);
        assign bg_cys_ge90_nl  = (bg_coarse_y_sum_nl >= 7'd90);
        assign bg_cys_ge120_nl = (bg_coarse_y_sum_nl >= 7'd120);
        assign bg_cys_s1_nl = bg_cys_ge30_nl ? (bg_coarse_y_sum_nl - 7'd30) : bg_coarse_y_sum_nl;
        assign bg_cys_s2_nl = (bg_cys_s1_nl >= 7'd30) ? (bg_cys_s1_nl - 7'd30) : bg_cys_s1_nl;
        assign bg_cys_s3_nl = (bg_cys_s2_nl >= 7'd30) ? (bg_cys_s2_nl - 7'd30) : bg_cys_s2_nl;
        assign bg_cys_s4_nl = (bg_cys_s3_nl >= 7'd30) ? (bg_cys_s3_nl - 7'd30) : bg_cys_s3_nl;
        assign bg_vertical_sections_nl = {6'b0, (bg_cys_ge30_nl ^ bg_cys_ge60_nl ^ bg_cys_ge90_nl ^ bg_cys_ge120_nl)};
        assign bg_coarse_y_nl = bg_cys_s4_nl[4:0];
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
        wire [13:0] bg_chr_addr_raw;
        wire        sp_chr_req;
        wire [13:0] sp_chr_addr_raw;
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
        wire [15:0] sp_chr_sh;
        wire        chr_rd_win;
        reg         chr_rd_armed_q;

        // CHR read arm versus the two fetch units.
        //
        // WHY THE ARM CANNOT BE DEFERRABLE, and why the BEAT is deferred
        // instead.  The arm has zero slack and that is arithmetic, not caution:
        // nes_system_v6 raises it on the single clk whose pre-edge div_phase is
        // 8; the external CHR memory registers chr_rdata on every ce_ppu edge;
        // the ce_ppu edge that ends div_phase 8 is followed by div_phase 9, 10,
        // 11, 0, and the edge that ends div_phase 0 is the one the $2007 access
        // retires on, where read_buffer_reg latches chr_rdata.  NO ce_ppu edge
        // exists strictly between the arm edge and the consume edge.  So the
        // address has to be on the bus during div_phase 8, and parking it in a
        // pending register does not make the arm one beat later, it makes it one
        // beat STALE: the register cannot be loaded before the edge that is
        // supposed to carry the address, because the arm does not exist yet on
        // any earlier ce.  A deferred arm is not a slower arm, it is a wrong arm.
        //
        // The fetch units are the deferrable party, and they have to be, because
        // they are fixed-latency and non-retrying: chr_req is high for exactly
        // one beat (state S_BEAT) and the byte captured in S_GRAB one ce later
        // is whatever chr_rdata holds, with no tag, no retry and no way to
        // notice it was handed the wrong one.  A unit that finds its own chr_req
        // already high on an arm beat is therefore FROZEN for exactly that one
        // ce: its ce is gated off, so its state and its chr_addr and chr_req
        // registers do not move, and the beat it asked for is neither serviced
        // nor consumed.  On the next ce it re-runs S_BEAT with the address
        // register untouched, the memory captures that address one ce later, and
        // S_GRAB consumes the right byte one ce later.  The address a unit
        // presents is stable across S_ARM and S_BEAT anyway, which is why the
        // repeat is the same beat rather than a different one.
        //
        // The cost is bounded and was measured rather than assumed.  A unit can
        // be frozen only on a div_phase 8 clk, the arm is a one-clk level there,
        // and ce_ppu edges are 4 clk apart, so a unit can never be frozen twice
        // in a row.  A background tile costs 5 ce of the 24 ce its cadence
        // allows (bg_fetch_due fires every 8 dots and a dot is 3 ce), and the
        // sprite prefetch costs 35 ce of the 444 ce between its start at dot 257
        // and the first dot of the next line that reads its shadow, so neither
        // unit can miss a start and neither cadence changes.
        //
        // The hold is the arm ANDed with that unit's own chr_req, which is high
        // in S_BEAT and in no other state.  Two neighbouring cases cost nothing
        // and are left alone on purpose:
        //   * an arm landing while a unit is in S_ARM -- chr_req is still low
        //     there, so the memory captures the arm's byte, the unit then
        //     presents its own address for a whole beat in S_BEAT, and its
        //     capture lands on the following edge;
        //   * an arm landing while a unit is in S_GRAB -- the unit consumes the
        //     byte the S_BEAT edge delivered and merely overwrites chr_rdata
        //     with the arm's byte afterwards.
        //
        // Contention itself is NOT removed and is not meant to be: an arm and a
        // fetch beat still ask for the bus on the same ce, and the arm still
        // takes the address, because the read has to be on time.  What is now
        // impossible is the loser CONSUMING anything.
        wire chr_hold_bg = chr_rd_win && bg_chr_req;
        wire chr_hold_sp = chr_rd_win && sp_chr_req;

        assign sp_start = (dot == 9'd257);
        assign sp_bus_sel = sp_busy;
        assign sp_base_lo = {sp_slot[2:0], 4'b0000};
        assign sp_base_hi = {sp_slot[2:0], 4'b1000};
        assign sp_plane_lo = (sp_slot == 4'h8) ? 8'h00 : sp_shadow[sp_base_lo +: 8];
        assign sp_plane_hi = (sp_slot == 4'h8) ? 8'h00 : sp_shadow[sp_base_hi +: 8];
        assign sp_chr_sh = sp_shadow_valid ? {sp_plane_hi, sp_plane_lo} : 16'h0000;

        nes_sprite_chr_fetch u_sprite_chr_fetch (
            .clk(clk),
            .ce(ce && !chr_hold_sp),
            .reset(reset),
            .start(sp_start),
            .pat_addr(sprite_pat_addr_bus),
            .chr_req(sp_chr_req),
            .chr_addr(sp_chr_addr_raw),
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
            .ce(ce && !chr_hold_bg),
            .reset(reset),
            .req_start(bg_fetch_due),
            .tile_base(bg_tile_base),
            .tile_count(6'd1),
            .chr_req(bg_chr_req),
            .chr_addr(bg_chr_addr_raw),
            .chr_rdata(chr_rdata),
            .bg_lo(chr_fetch_bg_lo),
            .bg_hi(chr_fetch_bg_hi),
            .bg_valid(chr_fetch_bg_valid),
            .busy(chr_fetch_busy)
        );

        assign chr_rd_win = chr_rd_arm && (v_addr < 15'h2000);

        assign chr_req = chr_rd_win || (sp_bus_sel ? sp_chr_req : bg_chr_req);
        assign chr_addr = chr_rd_win ? v_addr[13:0]
                                     : (sp_bus_sel ? sp_chr_addr_raw : bg_chr_addr_raw);

        assign chr_waddr = (v_addr < 15'h2000) ? v_addr[13:0] : 14'h0000;
        assign chr_we    = !reset && reg_cs && reg_we && (reg_addr == 3'd7)
                           && (v_addr < 15'h2000);
        assign chr_wdata = reg_din;

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
            if (reset)
                chr_rd_armed_q <= 1'b0;
            else if (reg_cs && (reg_addr == 3'd7))
                chr_rd_armed_q <= 1'b0;
            else if (chr_rd_win)
                chr_rd_armed_q <= 1'b1;
        end

        assign chr_rb_cs   = !reset && reg_cs && !reg_we && (reg_addr == 3'd7);
        assign chr_rb_data = (v_addr < 15'h2000) ? (chr_rd_armed_q ? chr_rdata : 8'h00)
                            : (v_addr < 15'h3F00) ? ppu_space_read(v_addr[13:0])
                                                  : ppu_space_read(palette_underlay_address(v_addr));
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
    pixel_pal = 8'h00;
    if (pixel_valid) begin
        pixel_x = dot[7:0];
        pixel_y = scanline[7:0];
        pixel_pal = mixed_pixel_value;
    end
    if (mask_reg[0])
        pixel_pal = pixel_pal & 8'h30;
    pixel_index = pixel_pal[3:0];
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

        if (chr_rb_cs) begin
            read_buffer_reg <= chr_rb_data;
            v_addr <= increment_v(v_addr);
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
