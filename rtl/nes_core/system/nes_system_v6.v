`timescale 1ns/1ps

// v6 = v5 plus the PPU external-CHR read path, wired through the mapper.
// Address convention: the PPU emits a LOCAL CHR byte address on chr_addr.  That
// port is 14 bits wide but only 13 bits of pattern address exist:
// {table, tile[7:0], 1'b0, fine_y[2:0]} = $0000-$1FFF, one 8 KiB pattern window.
// The pattern-table select is bit 12 (PPUCTRL[4] for the background, PPUCTRL[5]
// for sprites), NOT a second 8 KiB bank; bit 13 has no address to carry and is
// declared but structurally 0, which is why every mapper's drop of ppu_addr[13]
// costs nothing, and why an 8 KiB CHR memory indexes the local address on
// [12:0] with no mirroring.  The mapper translates that local address into the
// FINAL 17-bit CHR byte address on chr_bank_offset, and chr_final_addr exports
// exactly that final address.  The PPU performs no bank arithmetic, and the
// mapper never adds anything to the PPU address beyond its own bank offset.
// That translation is not a combinational loop even though the mapper is fed the
// address it translates: chr_rdata is this module's own input port and goes
// straight into the PPU, chr_final_addr is an output that nothing reads back, and
// the PPU's chr_addr is a mux between two registered fetch-unit outputs, so both
// halves of the path stop at the port.
// CHR_ADDR_BITS = 17 (128 KiB) is forwarded unchanged to nes_mapper; this
// ceiling is exactly sufficient for MMC1 (5-bit 4 KiB banks, at most
// 0x1F000|0x0FFF = 0x1FFFF) and TRUNCATES MMC3 CHR bank bit 7, since
// nes_mapper_mmc3.v:135 shifts an 8-bit bank number by 10 inside a 17-bit word,
// so MMC3 CHR banks 0x80-0xFF alias onto 0x00-0x7F at the current width.  That is
// a known, accepted limitation; do not lower CHR_ADDR_BITS below 17.
// chr_waddr/chr_we/chr_wdata are the $2007 write half of that same local CHR
// port, exported here as observability taps rather than as a second bus. The
// PPU increments v_addr on the very $2007 beat that drives the write, so
// chr_waddr carries the PRE-increment v_addr[13:0] and is only meaningful
// while chr_we is high; chr_we is a one-clk strobe and chr_wdata is the
// $2007 write data. Whether the mapper actually accepts the write is decided by
// mapper_chr_ram_we (chr_ram_enable_r && ppu_we && ppu_addr[13] == 1'b0,
// nes_mapper.v:221), which is the authoritative post-gate signal; the CHR
// memory behind this module must observe chr_waddr/chr_we/chr_wdata itself,
// because external CHR data comes from the top-level chr_rdata port only and
// has no write-back path.  mapper_ppu_addr is ppu_chr_addr UNCONDITIONALLY --
// there is no write-priority mux in front of the mapper's read-side banking
// any more, and the derivation of every consumer that that could have touched,
// including chr_ram_we's ppu_addr[13] term, is written out at the wire below.
// mapper_ppu_a12 is tied 0, so MMC3 scanline IRQ still cannot self-clock at
// system level.
// The external CHR port has no ready/backpressure signal: the CHR memory must
// present registered data one ce after the address, as the fetch units expect.
module nes_system_v6 #(
    parameter PRG_SIZE_BYTES = 131072,
    parameter integer PRG_ADDR_BITS = $clog2(PRG_SIZE_BYTES),
    // Which hex image the internal PRG half of nes_cart_rom is loaded from.  The
    // default is nes_cart_rom's own default, so every existing instance, and the
    // committed gate, is byte-for-byte unaffected: the placeholder is still what
    // $readmemh reads.  Only a caller that deliberately wants a different
    // cartridge image overrides it.
    //
    // NOTE THIS IS NOT RELOCATABLE AND CANNOT BE.  $readmemh resolves a relative
    // path against the SIMULATOR'S WORKING DIRECTORY, not against this source
    // file's directory, so an override is only meaningful to whoever sets that
    // working directory.  tools/sim_all.ps1 therefore does Push-Location to the
    // repository root before compiling, which is what makes the default path
    // resolve at all.
    parameter PRG_INIT_FILE = "rtl/nes_core/cart/prg_placeholder.hex",
    parameter integer CHR_ADDR_BITS = 17,
    parameter [7:0] MAPPER_SELECT = 8'd0,
    parameter [2:0] HEADER_MIRRORING = 3'd0,
    parameter integer UxROM_BANK_BITS = 3,
    parameter integer CNROM_BANK_BITS = 2,
    parameter [1:0] UxROM_BUS_CONFLICT = 2'd1,
    parameter [1:0] CNROM_BUS_CONFLICT = 2'd1,
    parameter [1:0] MMC3_A12_EDGE = 2'd0,
    parameter integer MMC3_A12_COOLDOWN = 2,
    parameter integer NROM_PRG_SIZE_BYTES = 32768,
    parameter NROM_PRG_RAM = 1'b0,
    parameter NROM_CHR_RAM = 1'b0,
    parameter MMC1_CHR_RAM = 1'b0,
    parameter MMC3_CHR_RAM = 1'b0
)(
    input wire clk,
    input wire reset,
    input wire [7:0] buttons1,
    input wire [7:0] buttons2,
    input wire [7:0] chr_rdata,
    output wire pixel_valid,
    output wire [7:0] pixel_x,
    output wire [7:0] pixel_y,
    output wire [3:0] pixel_index,
    output wire [7:0] pixel_pal,
    output wire frame_done,
    output wire vblank,
    output wire nmi_o,
    output wire apu_irq_o,
    output wire audio_sample_valid,
    output wire [15:0] audio_sample_left,
    output wire [15:0] audio_sample_right,
    output wire [31:0] cpu_cycle,
    output wire [8:0] ppu_dot,
    output wire [8:0] ppu_scanline,
    output wire [2:0] bus_owner,
    output wire bus_active,
    output wire [7:0] bus_wait_count,
    output wire bus_req,
    output wire bus_stall,
    output wire bus_fire,
    output wire [15:0] bus_addr,
    output wire bus_we,
    output wire [7:0] bus_dout,
    output wire [7:0] bus_din,
    output wire sel_ram,
    output wire sel_ppu,
    output wire sel_apu_io,
    output wire sel_open_bus,
    output wire sel_cart_ram,
    output wire sel_cart_rom,
    output wire ram_we,
    output wire ppu_reg_cs,
    output wire ppu_reg_we,
    output wire [2:0] ppu_reg_addr,
    output wire apu_reg_cs,
    output wire apu_reg_we,
    output wire [4:0] apu_reg_addr,
    output wire controller_data,
    output wire cart_req,
    output wire cart_xfer,
    output wire [15:0] cart_addr,
    output wire [7:0] cart_din,
    output wire cart_ack,
    output wire bus_hold,
    output wire oam_dma_start,
    output wire oam_dma_cpu_hold,
    output wire oam_dma_cpu_read_req,
    output wire [15:0] oam_dma_cpu_read_addr,
    output wire oam_dma_cpu_read_ack,
    output wire [7:0] oam_dma_cpu_rdata,
    output wire oam_dma_ppu_reg_cs,
    output wire oam_dma_ppu_reg_we,
    output wire [2:0] oam_dma_ppu_reg_addr,
    output wire [7:0] oam_dma_ppu_reg_dout,
    output wire oam_dma_busy,
    output wire oam_dma_done,
    output wire [7:0] oam_dma_page,
    output wire [7:0] oam_dma_page_latch,
    output wire [7:0] oam_dma_base_addr,
    output wire [7:0] oam_dma_cur_addr,
    output wire [7:0] oam_dma_index,
    output wire [1:0] oam_dma_align_left,
    output wire oam_dma_addr_wr,
    output wire [15:0] oam_dma_cycle_count,
    output wire apu_dmc_bus_req,
    output wire [15:0] apu_dmc_addr,
    output wire apu_dmc_ack,
    output wire [7:0] apu_dmc_rdata,
    output wire dma_sel,
    output wire dma_ack,
    output wire [7:0] dma_din,
    output wire dma_wait,
    output wire dma_active,
    output wire dma_unimpl,
    output wire [1:0] dma_owner,
    output wire ppu_port_cs,
    output wire ppu_port_we,
    output wire [2:0] ppu_port_addr,
    output wire [7:0] ppu_port_din,
    output wire [2:0] mapper_id,
    output wire [PRG_ADDR_BITS-1:0] mapper_prg_bank_offset,
    output wire [CHR_ADDR_BITS-1:0] mapper_chr_bank_offset,
    output wire [2:0] mapper_mirroring,
    output wire [7:0] mapper_nametable_map,
    output wire [7:0] mapper_prg_bank_number,
    output wire mapper_prg_ram_enable,
    output wire mapper_prg_ram_we,
    output wire mapper_chr_ram_enable,
    output wire mapper_chr_ram_we,
    output wire mapper_bus_conflict,
    output wire mapper_irq,
    output wire irq_line,
    output wire mapper_write_pulse,
    output wire [15:0] mapper_write_addr,
    output wire [7:0] mapper_write_data,
    output wire [7:0] prg_readback,
    output wire [13:0] chr_waddr,
    output wire chr_we,
    output wire [7:0] chr_wdata,
    output wire chr_req,
    output wire [CHR_ADDR_BITS-1:0] chr_final_addr,
    output wire ce_ppu,
    output wire ce_cpu
);

localparam [4:0] APU_REG_OAMDMA = 5'h14;
localparam [4:0] APU_REG_CTRL1 = 5'h16;
localparam [4:0] APU_REG_CTRL2 = 5'h17;

reg [3:0] div_phase;
wire ce_sample;

// ce_ppu and ce_cpu are output ports, not private wires: the top must gate the CHR
// ROM latch and the PPU register file on this module's own enable, never on a
// regenerated div_phase.  nes_cart_rom's read path is phase sensitive, so a 1-to-3
// beat offset between a re-derived enable and this one returns wrong tile bytes
// without failing anything.  Both keep the existing !reset gate, which is also what
// nes_cart_rom does with its own reset, so a top that ANDs them together still sees
// no ce edge during reset.
assign ce_ppu = !reset && (div_phase[1:0] == 2'b00);
assign ce_cpu = !reset && (div_phase == 4'd0);
assign ce_sample = 1'b1;

always @(posedge clk or posedge reset) begin
    if (reset)
        div_phase <= 4'd0;
    else if (div_phase == 4'd11)
        div_phase <= 4'd0;
    else
        div_phase <= div_phase + 4'd1;
end

wire [15:0] cpu_addr;
wire cpu_we;
wire [7:0] cpu_dout;
wire [7:0] bus_cpu_din;
wire [7:0] cpu_din;
wire cpu_bus_req;
wire cpu_bus_fire;
wire cpu_bus_ready;
wire cpu_bus_stall;
wire [3:0] cpu_cycle_phase;
wire [10:0] ram_addr;
wire ppu_req;
wire ppu_we;
wire ppu_wr;
wire ppu_xfer;
wire [2:0] ppu_addr;
wire [7:0] ppu_dout;
wire [7:0] ppu_reg_dout;
wire ppu_ack;
wire apu_req;
wire apu_we;
wire apu_wr;
wire apu_xfer;
wire [4:0] apu_addr;
wire [7:0] apu_dout;
wire [7:0] apu_reg_dout;
wire apu_ack;
wire [7:0] cart_dout;
wire cart_we;
wire cart_wr;
wire cart_ram_cs;
wire ppu_nmi;
wire apu_sample_valid;
wire [15:0] apu_sample_left;
wire [15:0] apu_sample_right;
wire apu_irq;

assign ppu_ack = 1'b1;
assign apu_ack = 1'b1;
assign cart_ack = 1'b1;

reg cart_wr_pending_q;
reg [15:0] cart_wr_addr_q;
reg [7:0] cart_wr_data_q;

always @(posedge clk or posedge reset) begin
    if (reset) begin
        cart_wr_pending_q <= 1'b0;
        cart_wr_addr_q <= 16'h0000;
        cart_wr_data_q <= 8'h00;
    end else begin
        cart_wr_pending_q <= cart_xfer && cart_we;
        cart_wr_addr_q <= cart_addr;
        cart_wr_data_q <= cart_dout;
    end
end

wire mapper_we = cart_wr_pending_q;
wire [15:0] mapper_cpu_addr = cart_wr_pending_q ? cart_wr_addr_q : cart_addr;
wire [7:0] mapper_cpu_dout = cart_wr_pending_q ? cart_wr_data_q : cart_dout;
wire [13:0] ppu_chr_addr;
wire [13:0] ppu_chr_waddr;
wire        ppu_chr_we;
wire [7:0]  ppu_chr_wdata;
wire        ppu_chr_rd_arm;

// One $2007 CHR read is armed on the single clk whose pre-edge div_phase is
// 8.  The durable reason is the shape of the window, not a cost: the external
// CHR memory registers chr_rdata on every ce_ppu edge, the arm is raised on the
// clk whose div_phase is 8, and div_phase 8 is the LAST ce_ppu beat of the
// eleven-clk window in which the cpu has already presented the address.  The
// consume edge is the next ce_ppu edge, which is the one ending div_phase 0, and
// NO ce_ppu edge exists strictly between the two: the sequence after 8 is 9, 10,
// 11, 0.  So nothing can re-latch chr_rdata between the arm and the consume and
// the byte the cpu latches is the byte the arm asked for.  That argument holds
// identically whether the access took one ce_cpu beat or two.
//
// WHAT CHANGED HERE, and the claim that had to be retired: this comment used to
// justify div_phase 8 by saying that "a PPU access costs two CPU cycles" and
// that the arm had to sit one ce_cpu beat inside the resulting wait window,
// because READ_WAIT_CYCLES was 8'd1 here so nes_cpu_bus.v armed active with
// wait_cnt 0 on the first beat and only then raised ready_c.  That was true of
// the old bus and is false of this one: ce_cpu IS the cpu cycle, so a wait of
// one ce_cpu beat is not a second cycle, ready_c is now high for the whole
// window that contains the arm, and a PPU access costs exactly one CPU cycle.
// The arm's POSITION is unchanged and the phase-selecting logic below is
// unchanged; only the reason is restated, because the reason it gave was the
// thing the fix removed.
//
// The rest of the argument is unchanged and still load bearing:
// BUG BEING FIXED HERE, do not reintroduce it: this condition used to require
// ppu_req, and ppu_req is structurally zero at div_phase 8.  ppu_req needs
// cpu_req (nes_cpu_bus.v:238), cpu_req is u_cpu.bus_req, and nes_cpu6502.v:755
// forces bus_req to 0 whenever cpu_active is 0, with cpu_active = ce && !bus_hold
// (nes_cpu6502.v:215) and ce = ce_cpu = (div_phase == 4'd0).  ppu_req is
// therefore high on the div_phase 0 clk ONLY, so ppu_req && (div_phase == 4'd8)
// was a self-contradiction: the arm never fired and every $2007 CHR read
// returned the fail-safe 8'h00.  Every term of this predicate must HOLD across
// the eleven clk of the window, and only these kinds do:
//   sel_ppu and ppu_addr are pure functions of cpu_addr (nes_cpu_bus.v:124 is an
//     ungated always @* and :189 is a bare slice of the same wire), and
//     nes_cpu6502.v:755 clears only bus_req, never bus_addr or bus_we, so the
//     cpu's address and its direction are unchanged from the first beat
//     through the completing one.  sel_ppu is load bearing rather than
//     decorative: ppu_addr is cpu_addr[2:0] on its own, so without it an APU-IO
//     read of $4007 would decode as $2007 and put v_addr on the CHR bus.
//   cpu_bus_ready is the ready described above, the "will fire" predicate.  It
//     is high across the whole window and low only on the clk that carries the
//     request, so div_phase == 4'd8 is the one clk inside that window that
//     satisfies both terms: one access, one arm.
// The read direction is !cpu_we, NOT !ppu_we: ppu_we is ppu_req && cpu_we
// (nes_cpu_bus.v:239), so at div_phase 8 it is 0 for a read AND for a write and
// would qualify nothing.  The write strobe chr_we needs reg_cs, which is
// ppu_xfer and therefore ce-gated (nes_cpu_bus.v:240, nes_ppu2c02.v:814), so a
// read arm is a div_phase 8 level and can neither ride the write strobe's
// capture edge nor raise mapper_chr_ram_we.  mapper_ppu_addr needs no change --
// the read address rides chr_addr.  v_addr is PPU state, so the CHR-half test
// stays in the PPU: nes_ppu2c02.v:807 gates it on v_addr < $2000, so a nametable
// or palette read does raise this arm but never takes the CHR address bus and
// is answered from internal RAM.  Reset holds div_phase at 0 asynchronously,
// so the arm is low throughout reset.
assign ppu_chr_rd_arm = sel_ppu && !cpu_we && (ppu_addr == 3'd7) &&
                         cpu_bus_ready && (div_phase == 4'd8);

// The mapper's CHR address is the READ address, UNCONDITIONALLY.  It used to be
// a 14-bit 2:1 mux with the write taking priority:
//
//     wire [13:0] mapper_ppu_addr = ppu_chr_we ? ppu_chr_waddr : ppu_chr_addr;
//
// WHY IT IS GONE.  The CHR array already has a write address that is
// independent of the read address: nes_cart_rom.v:193-197 declares
// chr_rindex = chr_addr[CHR_LOCAL_BITS-1:0] and
// chr_windex = chr_waddr[CHR_LOCAL_BITS-1:0] as two separate index wires, and
// rtl/platform/zynq/nes_zynq_top.v wires the raw core chr_waddr (the port
// exported below, unchanged) straight into chr_windex.  So nothing about the
// CHR memory ever needed the write address on the mapper's read port; what
// shared ONE address was the mapper's banking.  That is what has changed.
//
// WHAT THE MUX COST, and it was not free in either direction.
//
//   1. WRONG BYTES, paid for with a freeze.  On a write beat the fetch unit's
//      address never reached the CHR memory, so a fetch unit that happened to be
//      in S_BEAT on that ce consumed the write address's byte one ce later, with
//      no tag on it.  The mitigation was to freeze the fetch unit for that one
//      ce (chr_hold_bg/chr_hold_sp included chr_we).  That stopped the wrong
//      byte, and it also DROPPED the request outright, because the background
//      fetch pipeline has zero slack: bg_fetch_due fires every 8 ce and one tile
//      occupies 8 ce, so a freeze on the last S_BEAT pushes the request past the
//      next bg_fetch_due.  Measured on a deliberately non-uniform nametable in
//      tb/ppu/tb_bg_fetch_drop.v over 3 frames: with $2007 CHR writes only,
//      25152 requests due, 22010 accepted, 3142 DROPPED, 8317 of 184304 visible
//      pixels wrong; at tb_chr_wr_collision.v's cadence 2955 of 5238 drops were
//      the write's share.
//
//   2. TIMING.  This is a 14-bit 2:1 mux sitting in the CHR read address chain
//      v_addr -> chr_addr -> mapper -> chr_final_addr -> CHR memory, which
//      nes_ppu2c02's module header declares to have ZERO SLACK.  Removing a mux
//      from a zero-slack path is a gain, not a wash.
//
// With the mux gone the fetch unit receives its own byte on a write beat, so
// nes_ppu2c02 no longer freezes for chr_we and there is nothing left to arbitrate
// on the write side.  The array is now read and written in the same clk, which
// is the first same-address read-during-write on this CHR port; it needs the
// write address to EQUAL the fetch address, and the bound is one dot of one tile
// versus the 2.4 pixels per dropped request the freeze caused.  Read-during-write
// ORDER remains a modelling choice (every bench here is READ-FIRST) and is
// reported from the routed design rather than from simulation.
//
// WHAT IS TRUE OF mapper_ppu_addr NOW, and had to be re-derived rather than
// assumed.  Every consumer of it was read before the mux was removed:
//
//   nes_mapper.v:39 ppu_addr          -- the module port, fed straight from here.
//   nes_mapper.v:221 chr_ram_we       -- chr_ram_enable_r && ppu_we && !ppu_addr[13].
//   nes_mapper.v:237/257/285/309/334  -- ppu_addr into all four mapper leaf modules.
//   nes_mapper.v:335                  -- ppu_a12, which is the separate
//                                        mapper_ppu_a12 = 1'b0 tap below and is
//                                        NOT affected.
//
//   * All four leaf mappers use ppu_addr[12:0] ONLY (nes_mapper_nrom.v:26,
//     nes_mapper_uxrom.v:47, nes_mapper_cnrom.v:41, nes_mapper_mmc1.v:56/65,
//     nes_mapper_mmc3.v:110-135), and ppu_addr[13] is dropped by every one of
//     them, which is why an 8 KiB CHR memory indexes the local address on [12:0]
//     with no mirroring.  None of them can tell the difference.
//
//   * chr_ram_we's ppu_addr[13] TERM IS THE ONE PLACE THE CHANGE DID MATTER,
//     and it is handled explicitly on the wire below rather than left implicit.
//     It is a write-side gate: chr_ram_enable_r && ppu_we && !ppu_addr[13]
//     (nes_mapper.v:221).  On a write beat it used to see ppu_chr_waddr[13] and
//     now sees the bit-13 substitution at the wire below.
//
//       ppu_chr_waddr[13] == 0 ALWAYS on a write beat: chr_waddr is
//         (v_addr < $2000) ? v_addr[13:0] : 14'h0000 (nes_ppu2c02.v:1032) and
//         chr_we is itself qualified on v_addr < $2000 (:1033-1034), so
//         v_addr[14:13] == 0.  The term was therefore a constant 1 on every beat
//         where ppu_we is high, and it must stay one.
//
//       ppu_chr_addr[13] IS STRUCTURALLY 0, and an EARLIER version of this
//         comment claimed the opposite.  That claim was wrong, it was caught by
//         a probe, and the corrected arithmetic is worth writing out because the
//         wrong version was believed for a long time:
//
//         chr_addr = chr_rd_win ? v_addr[13:0] : (sp_bus_sel ?
//         sp_chr_addr_raw : bg_chr_addr_raw) (nes_ppu2c02.v:1094-1095).  Only
//         the fetch units' own address registers are in question, and they
//         cannot produce bit 13:
//
//         BACKGROUND.  bg_chr_addr_raw is nes_chr_fetch_unit's chr_addr, which
//         holds nxt_addr = base_q + {3'b0, idx_q, 4'd0} + (pl_q ? 8 : 0)
//         (nes_chr_fetch_unit.v:34) on the first beat and fwd_addr = nxt_addr + 8
//         (:35) on the second, advanced under `if (!last_byte)` at :82-84.  With
//         tile_count = 1 there are exactly TWO beats, not one: last_byte is
//         pl_q && (idx_q == cnt_q - 1) (:33), so it is FALSE on the low-plane
//         beat and TRUE on the high-plane beat.  The guard therefore lets
//         fwd_addr be presented for the high plane and refuses only the
//         base+16 that no tile needs.  idx_q stays 0 for the whole fetch, so the
//         address sequence is base_q then base_q + 8 and the largest address the
//         unit can present is base_q + 8.
//         base_q is bg_tile_base = {control_reg[4], bg_name_target, 4'b0000} +
//         {10'b0, bg_fine_y_target} (nes_ppu2c02.v:841-842).  THAT IS 1 + 8 + 4
//         = 13 bits with the tile number in bits [11:4] and the low FOUR bits
//         hard zero, so the largest {table,name,4'b0} is 0x1FF0 -- NOT 0x1FF8 --
//         because name is 8 bits and cannot fill bit 3.  fine_y is 3 bits, so
//         bg_tile_base tops out at 0x1FF0 + 7 = 0x1FF7 and the largest address
//         presented is 0x1FF7 + 8 = 0x1FFF.  Bit 13 cannot be set.  (The earlier
//         text here wrote "0x1FF8 + 7", which is the same error one octal step
//         out, and that single wrong constant is what produced 0x2007 and the
//         whole claim that the read address reaches into bit 13.)
//         SPRITE.  plane_byte = {1'b0, pat} + (p ? 8 : 0), masked 14'h3FFF
//         (nes_sprite_chr_fetch.v:85-86), over a 13-bit pat_addr whose bit 3 is
//         the hard 1'b0, so pat <= 0x1FF7 and the mask never fires.
//
//         MEASURED, not argued.  A probe drove this PPU for 4 frames with a
//         nametable of $FF everywhere, PPUCTRL[4]=1 and Y scroll 0x27 (coarse 4,
//         fine 7) so that bg_tile_base's maximum was actually reachable, and
//         watched the real chr_addr port: 67070 background request beats, largest
//         chr_addr 0x1FFF, largest bg_tile_base latched 0x1FF7, and bit 13 set
//         on NONE of them.  tb/system/tb_nes_system_v6.v P0-3 measures the same
//         thing at system level and reports local chr_addr[12] -- the real
//         pattern-table select -- set on thousands of requests with bit 13 set
//         on none, which is what makes the bound structural rather than a
//         coverage gap.  The high-plane address that the earlier text called
//         0x2007 is 0x1FFF.
//
//         CONSEQUENCE FOR chr_ram_we, and it is now a property rather than a
//         rescue.  chr_ram_we's ppu_addr[13] term used to be fed somebody
//         else's address bit, and the earlier comment reported that this
//         refused 11 of tb_nes_system_v6's chr_ram_b $2007 write beats.  With
//         the arithmetic above, ppu_addr[13] is 0 on a write beat for two
//         INDEPENDENT reasons -- the write address's own bit 13 is structurally
//         0, and so is the fetch address now -- so the substitution below is
//         belt-and-braces rather than a fix.  It is kept because it costs one
//         LUT on a signal nothing in the hardware consumes (see below), it
//         makes the gate's meaning independent of that arithmetic staying true,
//         and it keeps chr_ram_we bit-identical to its pre-mux behaviour.  What
//         it is NOT is evidence that the read address reaches bit 13; that
//         claim was measured false and is withdrawn.
//
//     So bit 13 is substituted, not the whole word.  The write address's bit 13
//     is put back on a write beat, which makes chr_ram_we bit-identical to what
//     it was, and bits [12:0] -- which is every bit any mapper leaf and every
//     CHR bank decode actually consumes -- stay mux-free.  The substitution lands
//     on ppu_addr[13], whose only consumer in the whole tree is that one
//     comparison, so the LUT level it costs is on chr_ram_we and on nothing else:
//     chr_ram_we is an output port of this module that rtl/platform/zynq/
//     nes_zynq_top.v does not even consume (the top gates the array on
//     chr_ram_enable), so it is not on the zero-slack chain the module header
//     talks about, and the 13-bit win on the real CHR read address is intact.
//
//     The alternative -- a second 14-bit address port on nes_mapper -- was
//     rejected for a concrete reason rather than taste: nes_mapper is
//     instantiated by nes_system_v5.v as well, that file is not part of this
//     change, and a mandatory input left unconnected there would be a latent
//     hazard rather than a clean interface.  tb/mapper/tb_nes_mapper.v:402-403
//     ("nrom ppu write above chr ignored", ppu_write(14'h2123)) is the check
//     that keeps the gate's meaning pinned for a generic caller, and it is
//     untouched by all of this.
//
//   * chr_final_addr = mapper_chr_bank_offset (:343) is therefore computed from
//     the fetch address on a write beat instead of from chr_waddr.  That is a
//     READ-side observability tap; the top wires it to the CHR memory's read
//     port only (nes_zynq_top.v:563), and the write port takes chr_waddr.  Every
//     mapper drops ppu_addr[13], so chr_final_addr is bit-identical on a write
//     beat for every mapper that has no CHR bank register in ppu_addr[12] or
//     ppu_addr[11] either; for MMC3, which does read those two bits, chr_final_addr
//     on a write beat is now the fetch's window rather than the write's, so
//     tb/system/tb_nes_system_v6.v P0-2 and W2 were rewritten to assert the NEW
//     contract (on a write beat the read port carries the PPU's own read address)
//     and to check the write's translation where it is actually observable, which
//     is the byte that lands in the tb's CHR model.
//
//   * mapper_ppu_we = ppu_chr_we and mapper_ppu_dout = ppu_chr_wdata are
//     unchanged, so the write path still reaches chr_ram_we with the correct
//     write data, and the CHR memory still observes chr_waddr/chr_we/chr_wdata
//     itself.
//
// WHAT DID NOT MOVE: the arm.  ppu_chr_rd_arm is raised on div_phase 8 and rides
// chr_addr, which nes_ppu2c02 still muxes in front of the fetch arbiter, so the
// $2007 CHR READ is exactly as it was -- same phase, same zero-slack lead, same
// byte.
// BIT 13 IS THE ONE SUBSTITUTION, and it is the whole of the write side's
// interest in this port.  chr_ram_we (nes_mapper.v:221) is
// chr_ram_enable_r && ppu_we && !ppu_addr[13], a WRITE-side gate, and before
// this change ppu_addr[13] on a write beat was ppu_chr_waddr[13] -- which is
// structurally 0, because chr_we is qualified on v_addr < $2000.  The read
// address is ALSO structurally 0 there, which an earlier version of this comment
// denied: bg_tile_base tops out at 0x1FF7, not 0x1FFF, because
// {control_reg[4], name, 4'b0} has its low FOUR bits hard zero and name is only
// 8 bits, so the fetch unit's largest presentable address is 0x1FFF rather than
// 0x2007.  The full derivation and the probe that measured it are at this wire.
// Putting the write address's bit 13 back on a write beat therefore costs one
// LUT on a signal nothing in the hardware consumes, leaves bits [12:0] -- every
// bit the mapper bank decodes -- mux-free, and keeps chr_ram_we independent of
// that arithmetic rather than resting on it.
wire [13:0] mapper_ppu_addr = {ppu_chr_we ? 1'b0 : ppu_chr_addr[13],
                               ppu_chr_addr[12:0]};
wire mapper_ppu_we = ppu_chr_we;
wire [7:0] mapper_ppu_dout = ppu_chr_wdata;
wire mapper_ppu_a12 = 1'b0;

assign chr_waddr = ppu_chr_waddr;
assign chr_we = ppu_chr_we;
assign chr_wdata = ppu_chr_wdata;

assign chr_final_addr = mapper_chr_bank_offset;

// The PRG ROM lives in nes_cart_rom, not in this module.  It used to be declared
// here as prg_rom with no driver anywhere, which Vivado dissolved with Synth
// 8-3848, and a hierarchical reference only points downward so no parent could
// have supplied it either.  The core's own instance is the only way in.  CHR is
// NOT here: it is a board-level instance above the core, because the five CHR
// ports of this module are already inputs and outputs of the right shape, so
// CHR_ENABLE is 0 here and the 8 KiB CHR array is not built a second time.
//
// The read is registered, one clk behind mapper_prg_bank_offset, and that is the
// right byte rather than a stale one because mapper_prg_bank_offset is an
// always @* function of nes_cpu6502's bus_addr, which is itself always @* and
// only moves on the single posedge per 12 clk where ce_cpu is high.  The address
// is therefore identical across the whole div_phase 1..11 + div_phase 0 window,
// which spans the clk that latched prg_rdata and the clk that latched bus_din.
// nes_cart_rom.v states the same argument for the mapper's bus-conflict compare.
wire [7:0] prg_rdata;
wire [7:0] prg_chr_rdata_unused;

nes_cart_rom #(
    .PRG_SIZE_BYTES(PRG_SIZE_BYTES),
    .PRG_ADDR_BITS(PRG_ADDR_BITS),
    .PRG_ENABLE(1),
    .CHR_ENABLE(0),
    .PRG_INIT_FILE(PRG_INIT_FILE)
) u_prg_rom (
    .clk(clk),
    .reset(reset),
    .prg_en(1'b1),
    .prg_addr(mapper_prg_bank_offset),
    .prg_rdata(prg_rdata),
    .ce_ppu(1'b0),
    .chr_req(1'b0),
    .chr_addr({CHR_ADDR_BITS{1'b0}}),
    .chr_rdata(prg_chr_rdata_unused),
    .chr_waddr(14'h0000),
    .chr_we(1'b0),
    .chr_wdata(8'h00),
    .chr_ram_enable(1'b0)
);

assign prg_readback = prg_rdata;
assign cart_din = (cart_addr[15] == 1'b1) ? prg_rdata : 8'h00;

assign bus_req = cpu_bus_req;
assign bus_stall = cpu_bus_stall;
assign bus_fire = cpu_bus_fire;
assign bus_addr = cpu_addr;
assign bus_we = cpu_we;
assign bus_dout = cpu_dout;
assign bus_din = cpu_din;
assign ppu_reg_cs = ppu_xfer;
assign ppu_reg_we = ppu_we;
assign ppu_reg_addr = ppu_addr;
assign nmi_o = ppu_nmi;
assign apu_irq_o = apu_irq;
assign audio_sample_valid = apu_sample_valid;
assign audio_sample_left = apu_sample_left;
assign audio_sample_right = apu_sample_right;

assign irq_line = mapper_irq | apu_irq;
assign mapper_write_pulse = cart_wr_pending_q;
assign mapper_write_addr = cart_wr_addr_q;
assign mapper_write_data = cart_wr_data_q;

wire apu_addr_ctrl1 = (apu_addr == APU_REG_CTRL1);
wire apu_addr_ctrl2 = (apu_addr == APU_REG_CTRL2);
wire apu_addr_ctrl_owned = apu_addr_ctrl1 || (apu_addr_ctrl2 && !apu_we);
wire apu_ctrl_xfer = apu_xfer && apu_addr_ctrl_owned;
wire apu_ctrl_read = apu_ctrl_xfer && !apu_we;
wire apu_port_cs = apu_xfer && !apu_addr_ctrl_owned;

assign apu_reg_cs = apu_port_cs;
assign apu_reg_we = apu_we;
assign apu_reg_addr = apu_addr;

assign cpu_din = apu_ctrl_xfer ? {7'b0, controller_data} : bus_cpu_din;

reg latch_strobe_q;

always @(posedge clk or posedge reset) begin
    if (reset)
        latch_strobe_q <= 1'b0;
    else if (apu_xfer && apu_we && apu_addr_ctrl1)
        latch_strobe_q <= cpu_dout[0];
end

wire ctrl_read_strobe = apu_ctrl_read;
wire ctrl_read_select = apu_addr_ctrl2;

wire [7:0] oam_dma_page_latch_wire;
reg  [7:0] oam_dma_page_q;
reg  [7:0] oam_addr_q;
wire [15:0] dma_addr;

assign bus_hold = oam_dma_cpu_hold || apu_dmc_bus_req;
assign dma_addr = oam_dma_cpu_read_req ? oam_dma_cpu_read_addr : apu_dmc_addr;
assign oam_dma_cpu_rdata = dma_din;
assign oam_dma_cpu_read_ack = dma_ack && !dma_sel;
assign apu_dmc_ack = dma_ack && dma_sel;
assign apu_dmc_rdata = dma_din;
assign oam_dma_start = apu_xfer && apu_we && (apu_addr == APU_REG_OAMDMA);

always @(posedge clk or posedge reset) begin
    if (reset)
        oam_dma_page_q <= 8'h00;
    else if (oam_dma_start)
        oam_dma_page_q <= apu_dout;
end

assign oam_dma_page = oam_dma_page_q;
assign oam_dma_page_latch = oam_dma_page_latch_wire;

always @(posedge clk or posedge reset) begin
    if (reset)
        oam_addr_q <= 8'h00;
    else if (ppu_port_cs) begin
        if (ppu_port_we) begin
            if (ppu_port_addr == 3'd3)
                oam_addr_q <= ppu_port_din;
            else if (ppu_port_addr == 3'd4)
                oam_addr_q <= oam_addr_q + 8'd1;
        end else if (ppu_port_addr == 3'd4) begin
            oam_addr_q <= oam_addr_q + 8'd1;
        end
    end
end

assign ppu_port_cs = oam_dma_ppu_reg_cs ? 1'b1 : ppu_xfer;
assign ppu_port_we = oam_dma_ppu_reg_cs ? oam_dma_ppu_reg_we : ppu_we;
assign ppu_port_addr = oam_dma_ppu_reg_cs ? oam_dma_ppu_reg_addr : ppu_addr;
assign ppu_port_din = oam_dma_ppu_reg_cs ? oam_dma_ppu_reg_dout : ppu_dout;
assign oam_dma_base_addr = oam_addr_q;

nes_cpu6502 u_cpu (
    .clk(clk),
    .reset(reset),
    .ce(ce_cpu),
    .bus_hold(bus_hold),
    .bus_din(cpu_din),
    .bus_ready(cpu_bus_ready),
    .nmi_i(ppu_nmi),
    .irq_i(irq_line),
    .bus_req(cpu_bus_req),
    .bus_fire(cpu_bus_fire),
    .cpu_cycle(cpu_cycle),
    .cpu_cycle_phase(cpu_cycle_phase),
    .bus_addr(cpu_addr),
    .bus_we(cpu_we),
    .bus_dout(cpu_dout),
    .dbg_pc(),
    .dbg_a(),
    .dbg_x(),
    .dbg_y(),
    .dbg_sp(),
    .dbg_p(),
    .dbg_opcode(),
    .dbg_state(),
    .dbg_nmi_pending(),
    .dbg_irq_pending(),
    .dbg_illegal()
);

nes_cpu_bus #(
    .READ_WAIT_CYCLES(8'd1),
    .RAM_ADDR_BITS(11),
    .RAM_READ_SYNC(1'b1),
    .RAM_INIT(8'h00),
    .DMA_PRESENT(1'b1),
    .DMA_MMIO_VALUE(8'h00)
) u_bus (
    .clk(clk),
    .reset(reset),
    .ce(ce_cpu),
    .bus_hold(bus_hold),
    .cpu_req(cpu_bus_req),
    .cpu_we(cpu_we),
    .cpu_addr(cpu_addr),
    .cpu_dout(cpu_dout),
    .cpu_din(bus_cpu_din),
    .cpu_ready(cpu_bus_ready),
    .cpu_fire(),
    .cpu_stall(cpu_bus_stall),
    .dma_req_oam(oam_dma_cpu_read_req),
    .dma_req_dmc(apu_dmc_bus_req),
    .dma_addr(dma_addr),
    .dma_sel(dma_sel),
    .dma_din(dma_din),
    .dma_ack(dma_ack),
    .dma_wait(dma_wait),
    .dma_active(dma_active),
    .dma_unimpl(dma_unimpl),
    .sel_ram(sel_ram),
    .sel_ppu(sel_ppu),
    .sel_apu_io(sel_apu_io),
    .sel_open_bus(sel_open_bus),
    .sel_cart_ram(sel_cart_ram),
    .sel_cart_rom(sel_cart_rom),
    .owner(bus_owner),
    .ram_addr(ram_addr),
    .ram_we(ram_we),
    .ppu_req(ppu_req),
    .ppu_we(ppu_we),
    .ppu_wr(ppu_wr),
    .ppu_xfer(ppu_xfer),
    .ppu_addr(ppu_addr),
    .ppu_dout(ppu_dout),
    .ppu_din(ppu_reg_dout),
    .ppu_ack(ppu_ack),
    .apu_req(apu_req),
    .apu_we(apu_we),
    .apu_wr(apu_wr),
    .apu_xfer(apu_xfer),
    .apu_addr(apu_addr),
    .apu_dout(apu_dout),
    .apu_din(apu_reg_dout),
    .apu_ack(apu_ack),
    .cart_req(cart_req),
    .cart_we(cart_we),
    .cart_wr(cart_wr),
    .cart_xfer(cart_xfer),
    .cart_ram_cs(cart_ram_cs),
    .cart_addr(cart_addr),
    .cart_dout(cart_dout),
    .cart_din(cart_din),
    .cart_ack(cart_ack),
    .dbg_active(bus_active),
    .dbg_wait_count(bus_wait_count),
    .dbg_open_bus(),
    .dbg_dma_owner(dma_owner),
    .dbg_dma_wait_count()
);

nes_ppu2c02 #(
    .MIRROR_VERTICAL(1'b0),
    .EXTERNAL_CHR(1'b1)
) u_ppu (
    .clk(clk),
    .reset(reset),
    .ce(ce_ppu),
    .reg_cs(ppu_port_cs),
    .reg_we(ppu_port_we),
    .reg_addr(ppu_port_addr),
    .reg_din(ppu_port_din),
    .reg_dout(ppu_reg_dout),
    .pixel_valid(pixel_valid),
    .pixel_x(pixel_x),
    .pixel_y(pixel_y),
    .pixel_index(pixel_index),
    .pixel_pal(pixel_pal),
    .frame_done(frame_done),
    .vblank(vblank),
    .nmi_o(ppu_nmi),
    .dot(ppu_dot),
    .scanline(ppu_scanline),
    .dbg_v(),
    .dbg_t(),
    .dbg_x(),
    .dbg_w(),
    .dbg_sprite0_hit(),
    .dbg_sprite_overflow(),
    .chr_waddr(ppu_chr_waddr),
    .chr_req(chr_req),
    .chr_addr(ppu_chr_addr),
    .chr_we(ppu_chr_we),
    .chr_wdata(ppu_chr_wdata),
    .chr_rd_arm(ppu_chr_rd_arm),
    .chr_rdata(chr_rdata)
);

nes_apu2a03 u_apu (
    .clk(clk),
    .reset(reset),
    .ce(ce_cpu),
    .ce_sample(ce_sample),
    .reg_cs(apu_port_cs),
    .reg_we(apu_we),
    .reg_addr(apu_addr),
    .reg_din(apu_dout),
    .reg_dout(apu_reg_dout),
    .irq(apu_irq),
    .dmc_bus_req(apu_dmc_bus_req),
    .dmc_addr(apu_dmc_addr),
    .dmc_rdata(apu_dmc_rdata),
    .dmc_ack(apu_dmc_ack),
    .sample_valid(apu_sample_valid),
    .sample_left(apu_sample_left),
    .sample_right(apu_sample_right),
    .dbg_frame_phase(),
    .dbg_frame_irq(),
    .dbg_dmc_irq(),
    .dbg_frame_count(),
    .dbg_pulse1_length(),
    .dbg_pulse2_length(),
    .dbg_pulse1_period(),
    .dbg_pulse1_duty_step(),
    .dbg_pulse1_level(),
    .dbg_pulse1_env(),
    .dbg_pulse1_env_div(),
    .dbg_pulse1_mute(),
    .dbg_pulse_sum(),
    .dbg_tri_length(),
    .dbg_tri_period(),
    .dbg_tri_step(),
    .dbg_tri_linear(),
    .dbg_tri_reload_flag(),
    .dbg_tri_level(),
    .dbg_noise_length(),
    .dbg_noise_period(),
    .dbg_noise_lfsr(),
    .dbg_noise_mode(),
    .dbg_noise_mute(),
    .dbg_noise_level(),
    .dbg_noise_env(),
    .dbg_noise_env_div(),
    .dbg_dmc_sample_addr(),
    .dbg_dmc_current_addr(),
    .dbg_dmc_bytes_remaining(),
    .dbg_dmc_rate_cnt(),
    .dbg_dmc_bits_remaining(),
    .dbg_dmc_bits(),
    .dbg_dmc_sample_buf(),
    .dbg_dmc_output(),
    .dbg_dmc_silence(),
    .dbg_dmc_buf_empty(),
    .dbg_dmc_active(),
    .dbg_tnd_sum(),
    .dbg_mix_pulse(),
    .dbg_mix_tnd(),
    .dbg_mix_sum()
);

nes_controller u_controller (
    .clk(clk),
    .reset(reset),
    .latch_strobe(latch_strobe_q),
    .read_strobe(ctrl_read_strobe),
    .read_select(ctrl_read_select),
    .buttons(buttons1),
    .buttons2(buttons2),
    .data_bit(controller_data),
    .data_out(),
    .dbg_sr1(),
    .dbg_sr2(),
    .dbg_latch1(),
    .dbg_latch2(),
    .dbg_cnt1(),
    .dbg_cnt2(),
    .dbg_selected_sr(),
    .dbg_selected_latch(),
    .dbg_selected_cnt(),
    .dbg_past8()
);

nes_oam_dma #(
    .OAMADDR_WRITE(1'b0)
) u_oam_dma (
    .clk(clk),
    .reset(reset),
    .start(oam_dma_start),
    .src_page(oam_dma_start ? apu_dout : oam_dma_page),
    .oam_addr(oam_dma_base_addr),
    .cpu_read_ack(oam_dma_cpu_read_ack),
    .cpu_rdata(oam_dma_cpu_rdata),
    .cpu_hold(oam_dma_cpu_hold),
    .cpu_read_addr(oam_dma_cpu_read_addr),
    .cpu_read_req(oam_dma_cpu_read_req),
    .ppu_reg_cs(oam_dma_ppu_reg_cs),
    .ppu_reg_we(oam_dma_ppu_reg_we),
    .ppu_reg_addr(oam_dma_ppu_reg_addr),
    .ppu_reg_dout(oam_dma_ppu_reg_dout),
    .busy(oam_dma_busy),
    .done(oam_dma_done),
    .cycle_count(oam_dma_cycle_count),
    .dbg_page(oam_dma_page_latch_wire),
    .dbg_oam_addr(oam_dma_cur_addr),
    .dbg_index(oam_dma_index),
    .dbg_align_left(oam_dma_align_left),
    .dbg_addr_wr(oam_dma_addr_wr)
);

nes_mapper #(
    .PRG_ADDR_BITS(PRG_ADDR_BITS),
    .CHR_ADDR_BITS(CHR_ADDR_BITS),
    .PRG_SIZE_BYTES(PRG_SIZE_BYTES),
    .HEADER_MIRRORING(HEADER_MIRRORING),
    .UxROM_BANK_BITS(UxROM_BANK_BITS),
    .CNROM_BANK_BITS(CNROM_BANK_BITS),
    .UxROM_BUS_CONFLICT(UxROM_BUS_CONFLICT),
    .CNROM_BUS_CONFLICT(CNROM_BUS_CONFLICT),
    .MMC3_A12_EDGE(MMC3_A12_EDGE),
    .MMC3_A12_COOLDOWN(MMC3_A12_COOLDOWN),
    .NROM_PRG_SIZE_BYTES(NROM_PRG_SIZE_BYTES),
    .NROM_PRG_RAM(NROM_PRG_RAM),
    .NROM_CHR_RAM(NROM_CHR_RAM),
    .MMC1_CHR_RAM(MMC1_CHR_RAM),
    .MMC3_CHR_RAM(MMC3_CHR_RAM)
) u_mapper (
    .clk(clk),
    .reset(reset),
    .mapper_select(MAPPER_SELECT),
    .cpu_addr(mapper_cpu_addr),
    .cpu_we(mapper_we),
    .cpu_dout(mapper_cpu_dout),
    .ppu_addr(mapper_ppu_addr),
    .ppu_we(mapper_ppu_we),
    .ppu_dout(mapper_ppu_dout),
    .ppu_a12(mapper_ppu_a12),
    .prg_readback(prg_readback),
    .prg_bank_offset(mapper_prg_bank_offset),
    .chr_bank_offset(mapper_chr_bank_offset),
    .mirroring(mapper_mirroring),
    .nametable_map(mapper_nametable_map),
    .prg_ram_enable(mapper_prg_ram_enable),
    .prg_ram_we(mapper_prg_ram_we),
    .chr_ram_enable(mapper_chr_ram_enable),
    .chr_ram_we(mapper_chr_ram_we),
    .irq(mapper_irq),
    .bus_conflict(mapper_bus_conflict),
    .dbg_prg_bank_number(mapper_prg_bank_number),
    .dbg_chr_bank_number(),
    .dbg_mapper_id(mapper_id),
    .mmc1_serial_count(),
    .mmc1_serial_value(),
    .mmc1_control(),
    .mmc1_chr_bank0(),
    .mmc1_chr_bank1(),
    .mmc1_prg_bank(),
    .mmc3_irq_counter(),
    .mmc3_irq_latch(),
    .mmc3_irq_pending(),
    .mmc3_irq_reload(),
    .mmc3_irq_enabled(),
    .mmc3_a12_filtered(),
    .mmc3_bank_select(),
    .mmc3_prg_bank6(),
    .mmc3_prg_bank7(),
    .mmc3_prg_mode(),
    .mmc3_chr_inversion(),
    .mmc3_ram_protect()
);

endmodule
