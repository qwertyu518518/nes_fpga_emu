`timescale 1ns/1ps

// nes_cart_rom : the cartridge's two ROMs, in block RAM, initialised from
// committed hex files so their content ships INSIDE the bitstream.  There is no
// card reader and no boot-time loader: on this Zynq board the TF card and the
// QSPI flash are on the PS MIO pins and are unreachable from the PL, so a ROM
// that is not in the bitstream is a ROM the PL cannot see.  This module is the
// only place in the design that carries cartridge content.
//
// One module, not two
//   PRG and CHR are different arrays with different port shapes, but they share
//   the clock, the reset, the file-initialisation idiom and the answer to "where
//   does the cartridge content come from".  Splitting them would duplicate that
//   idiom and leave the board integrator holding two files' worth of
//   parameters to keep consistent.  They are also never used together and never
//   arbitrate: PRG is a one-clock synchronous CPU-side read, CHR is a
//   ce_ppu-gated read/write on the PPU's external bus.  One module is clean.
//
// Where it connects
//   CHR needs NO change to nes_system_v6.  chr_rdata is already an input port of
//   the core and chr_req/chr_addr/chr_waddr/chr_we/chr_wdata are already its
//   output ports, so this module sits ABOVE the core: chr_rdata drives the
//   core's chr_rdata port, and the five core outputs drive this module's ports.
//   The port is one master-multiplexed bus, so whoever won chr_req is exactly
//   who put its address on chr_addr that beat, and there is nothing to arbitrate
//   here.
//   PRG does need a change to nes_system_v6, which is NOT made in this change
//   and is reported instead.  prg_rom is declared INSIDE nes_system_v6 and has
//   no driver anywhere, so Vivado dissolves it (Synth 8-3848) and it contributes
//   zero logic and zero memory.  Backing it from outside the module is not
//   possible in Verilog: a hierarchical reference only points downward.  See the
//   PRG LATENCY section for the timing consequence of the two ports the core
//   would have to change.
//
// SIZES
//   PRG_SIZE_BYTES/PRG_ADDR_BITS honour nes_system_v6's own parameters: its
//   PRG_SIZE_BYTES is 131072 (128 KiB) and its PRG_ADDR_BITS is $clog2 of that,
//   17.  They are restated here as parameters rather than derived, because
//   $clog2 is Verilog-2005 and this file is compiled under -g2001 as well as
//   -g2012.  The caller's invariant is 1 << PRG_ADDR_BITS == PRG_SIZE_BYTES;
//   that is what stops prg_addr from indexing outside the array, so prg_addr is
//   exactly the width mapper_prg_bank_offset already is.
//   CHR_SIZE_BYTES is 8192 and CHR_LOCAL_BITS is 13, so the mapper-translated
//   17-bit chr_final_addr is indexed on [12:0] and every bank bit above 12 is
//   dropped.  That is exact for NROM and UxROM, whose CHR is 8 KiB, and an alias
//   for CNROM (32 KiB), MMC1 (up to 64 KiB) and MMC3 (up to 64 KiB), whose banks
//   fold onto 0..7.  It is the same class of accepted limitation nes_system_v6
//   already documents for MMC3 CHR bank bit 7 at CHR_ADDR_BITS = 17, and it is
//   widened by raising CHR_LOCAL_BITS and CHR_SIZE_BYTES, which is a parameter
//   change and nothing else.  The testbench asserts the aliasing explicitly
//   rather than leaving it as an accident.
//
// CHR READ LATENCY -- the contract that must not be broken
//   nes_ppu2c02.v's header states that the chain
//     v_addr -> chr_addr -> mapper -> chr_final_addr -> CHR memory -> chr_rdata
//   has ZERO SLACK: chr_rdata is registered on every ce_ppu edge, and a register
//   inserted anywhere in that chain will not error, it will silently return the
//   PREVIOUS pattern byte.  The arithmetic, so the choice of edge is auditable:
//     clk is 21.477272727 MHz and div_phase runs 0..11, one increment per clk.
//     ce_ppu = (div_phase[1:0] == 2'b00), so ce_ppu is high AT div_phase 0, 4
//     and 8: one PPU dot is 4 clk and the enable is high 3 of every 4.  The ce
//     EDGES are therefore the posedges that END div_phase 0, 4 and 8.
//     The arm: nes_system_v6 raises ppu_chr_rd_arm on the single clk whose
//     pre-edge div_phase is 8, so during div_phase 8 chr_req is high and
//     chr_addr carries v_addr[13:0].  div_phase 8 is a ce_ppu beat.
//     This module: it latches chr_addr on that edge, so chr_rdata holds
//     chr_rom[chr_addr[12:0]] from the start of div_phase 9.
//     The consume: the PPU's read buffer is loaded at the next ce edge after the
//     arm, which is the edge that ends div_phase 0 of the following dot, because
//     div_phase 9, 10, 11, 0 is the run between the arm edge and that edge.
//     Window: address on the bus at div_phase 8 -> consume at the div_phase 0
//     edge is FIVE clk periods (8, 9, 10, 11, 0); the read itself costs ONE, the
//     arm edge.  Slack is FOUR clk periods, 186 ns, and the byte is HELD across
//     all of them because nothing re-latches between div_phase 9 and the consume.
//   Hence the read is gated on ce_ppu, and NOT on clk.  A read clocked on every
//   clk would re-latch chr_addr at the end of div_phase 9 -- by which time the
//   fetch units, which register their own chr_addr on every ce edge, have moved
//   a fetch address onto the bus -- and would overwrite the armed byte with a
//   fetch byte three clk before the CPU consumes it.  That is the stale-byte
//   failure mode, and nothing anywhere would report it.  Gating on
//   ce_ppu && chr_req also honours the two documented properties of the bus:
//   chr_addr is stale outside a beat, so chr_req is the only qualification of
//   the address; and chr_req MAY be high on two consecutive ce when a $2007 arm
//   lands next to a fetch beat, so both beats are serviced and each returns its
//   own address's byte.
//
// CHR WRITE
//   The write half of the bus is chr_waddr/chr_we/chr_wdata, and it is only
//   honoured when chr_ram_enable is high.  chr_ram_enable is the core's
//   mapper_chr_ram_enable, and mapper_chr_ram_we
//   (nes_mapper.v:221) = chr_ram_enable && ppu_we && (ppu_addr[13] == 1'b0),
//   so the gate implemented here, chr_ram_enable && chr_we, is that expression
//   with ppu_we == chr_we and ppu_addr == chr_waddr.  The ppu_addr[13] == 0 term
//   is already implied: chr_waddr is only meaningful under the PPU's
//   v_addr < $2000 guard, which forces v_addr[14:13] == 0, and v_addr[12] is a
//   real address bit that this module keeps.  With chr_ram_enable low the write
//   is not merely discarded from the bus, it does not reach the array at all, so
//   a CHR ROM cannot be written by a $2007 store and its contents stay whatever
//   $readmemh put there.
//
// PRG LATENCY (why backing prg_rom is not a drop-in)
//   The core reads prg_rom combinationally, in the same clk:
//     assign prg_readback = prg_rom[prg_index];
//     assign cart_din = (cart_addr[15] == 1'b1) ? prg_rom[prg_index] : 8'h00;
//   A block RAM has a one-clk read latency, so it cannot answer a combinational
//   read.  It does not need to: the CPU latches bus_din on the posedge whose
//   pre-edge div_phase is 0, nes_cpu6502's bus_addr is a registered output, and
//   nes_mapper's prg_bank_offset_r is an always @* function of it, so
//   mapper_prg_bank_offset is stable for the whole 12-clk CPU cycle.  A free
//   running read, latching the address on every clk, therefore presents the
//   address at the end of div_phase 0 and holds the byte across div_phase
//   1..11, which the CPU latches at the end of div_phase 0 with a full clk of
//   address setup.  prg_en exists for power only: with it low prg_rdata HOLDS
//   the last byte rather than returning zero, so gating it is only safe where
//   the address is also being held.
//
// RESET
//   Synchronous, and it clears only the two output registers.  It does not and
//   cannot clear the arrays: their content is the bitstream.  prg_rdata and
//   chr_rdata are 8'h00 while reset is high, which is also the PPU's documented
//   $2007 fail-safe, so a read that somehow arrives before the first serviced
//   beat returns the fail-safe rather than X.

module nes_cart_rom #(
    parameter integer PRG_SIZE_BYTES = 131072,
    parameter integer PRG_ADDR_BITS  = 17,
    parameter integer CHR_SIZE_BYTES = 8192,
    parameter integer CHR_LOCAL_BITS = 13,
    parameter integer CHR_ADDR_BITS  = 17,
    parameter PRG_INIT_FILE = "rtl/nes_core/cart/prg_placeholder.hex",
    parameter CHR_INIT_FILE = "rtl/nes_core/cart/chr_placeholder.hex"
)(
    input  wire                     clk,
    input  wire                     reset,

    input  wire                     prg_en,
    input  wire [PRG_ADDR_BITS-1:0] prg_addr,
    output reg  [7:0]               prg_rdata,

    input  wire                     ce_ppu,
    input  wire                     chr_req,
    input  wire [CHR_ADDR_BITS-1:0] chr_addr,
    output reg  [7:0]               chr_rdata,
    input  wire [13:0]              chr_waddr,
    input  wire                     chr_we,
    input  wire [7:0]               chr_wdata,
    input  wire                     chr_ram_enable
);

    reg [7:0] prg_rom [0:PRG_SIZE_BYTES-1];
    reg [7:0] chr_rom [0:CHR_SIZE_BYTES-1];

    initial begin
        $readmemh(PRG_INIT_FILE, prg_rom);
        $readmemh(CHR_INIT_FILE, chr_rom);
    end

    wire [CHR_LOCAL_BITS-1:0] chr_rindex;
    wire [CHR_LOCAL_BITS-1:0] chr_windex;
    wire                       chr_write;

    assign chr_rindex  = chr_addr[CHR_LOCAL_BITS-1:0];
    assign chr_windex  = chr_waddr[CHR_LOCAL_BITS-1:0];
    assign chr_write   = chr_ram_enable && chr_we;

    always @(posedge clk) begin
        if (reset) begin
            prg_rdata <= 8'h00;
            chr_rdata <= 8'h00;
        end else begin
            if (prg_en)
                prg_rdata <= prg_rom[prg_addr];
            if (ce_ppu && chr_req)
                chr_rdata <= chr_rom[chr_rindex];
            if (chr_write)
                chr_rom[chr_windex] <= chr_wdata;
        end
    end

endmodule
