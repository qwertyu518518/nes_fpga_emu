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
// PRG connects INSIDE nes_system_v6
//   prg_rom used to be declared inside nes_system_v6 with no driver anywhere, so
//   Vivado dissolved it (Synth 8-3848) and it contributed zero logic and zero
//   memory, and backing it from a parent is not possible in Verilog because a
//   hierarchical reference only points downward.  nes_system_v6 therefore
//   instantiates this module with PRG_ENABLE=1 and CHR_ENABLE=0 and reads
//   prg_rdata.  See the PRG LATENCY section for why the registered read is the
//   correct byte for the core's bus.
//
// PRG_ENABLE / CHR_ENABLE
//   The board instantiates this module once, above the core, with both halves
//   enabled.  The core instantiates it a second time with PRG_ENABLE=1 and
//   CHR_ENABLE=0, because the core may only reach its PRG.  Without these the
//   core's instance would build and $readmemh a second copy of the 8 KiB CHR
//   array, i.e. the CHR hex would be read twice and eight more KiB of content
//   would be inferred than the board needs.  When a half is disabled its array
//   is not declared at all -- it is inside the generate -- so nothing can infer
//   it, and the corresponding output register is still driven, from reset only,
//   so no output is ever left undriven.
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
//     and 8: one PPU dot is 4 clk and div_phase runs 0..11, so the enable is
//     high 3 of every 12 clk.  The ce
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
// CARTRIDGE LOAD PORT -- the PS writes a cartridge image in at runtime
//   A second, independent write port per array lets the Zynq PS load PRG and CHR
//   from the TF card instead of shipping them inside the bitstream.  It is
//   INERT BY DEFAULT: nothing reaches either array unless prg_ld_en/chr_ld_en is
//   high AND the matching prg_ld_we/chr_ld_we strobe is high, and every existing
//   instance leaves those ports unconnected.  An unconnected input is z, and a
//   z condition in an if is false, so with no caller driving them this file's
//   behaviour is bit-for-bit what it was: the 69-strong gate, and every bench
//   that instantiates this module, pass unmodified.
//
//   GRANULARITY IS ONE BYTE PER STROBE, and the enable is a level:
//     prg_ld_en/prg_ld_addr/prg_ld_data/prg_ld_we   one PRG byte
//     chr_ld_en/chr_ld_addr/chr_ld_data/chr_ld_we   one CHR byte
//   Both arrays are 8 bits wide, so a byte is one array word and one strobe is
//   exactly one write to the single block-RAM write port.  A 32-bit load port
//   would need four simultaneous writes to four consecutive array words on one
//   clock edge, which is not a shape a byte-wide block RAM can take: the tool
//   would either build four separate byte-wide RAMs (four cells where there is
//   one today) or fail to map it to RAM at all.  The AXI side is 32 bits wide,
//   so axi_lite_regs expands one 32-bit WSTRB write into up to four of these
//   byte strobes, one per core clock; the arrays stay byte-wide and keep the
//   primitive they already had.
//
//   THE LOAD WRITE IS NOT GATED BY reset.  The console is held in reset while
//   the PS loads, and the hold and the load are the same control bit upstream,
//   so a load write that reset suppressed could never happen.  The read path is
//   still gated by reset exactly as before (both output registers clear to
//   8'h00).  Gating the write on the mapper's own chr_ram_enable && chr_we is
//   unchanged: with the console held the CPU performs no $2007 store, so the
//   mapper write can never be asserted during a load, and the load is given
//   priority in the one write-if so a stray mapper write cannot corrupt a
//   streaming image.
//
//   ONE WRITE PORT, NOT TWO.  The CHR array had a read port and one write port
//   (the mapper's $2007 path); the load shares that write port through a SINGLE
//   muxed write statement (mux on enable, address and data), so the inference is
//   still a simple dual-port RAM with ONE write port and one read port.  A
//   two-branch if/else on the array would be TWO write statements, which Vivado
//   cannot map to a simple dual port and silently implements as distributed RAM;
//   see the comment on the CHR block.  PRG gains a write port it did not have,
//   so it goes from a read-only ROM to the same simple dual-port RAM, still one
//   write port; no second write port is created anywhere.  This is why no array
//   changes primitive and why RAMB18 stays 0 and LUT-as-Memory stays 2 (both read
//   back from a routed build; see docs/modules/ps-rom-load.md).
//
// PRG LATENCY (why the registered read returns the right byte)
//   The core reads prg_rom combinationally, in the same clk:
//     assign prg_readback = prg_rom[prg_index];
//     assign cart_din = (cart_addr[15] == 1'b1) ? prg_rom[prg_index] : 8'h00;
//   where prg_index is mapper_prg_bank_offset.  A block RAM has a one-clk read
//   latency, so it cannot answer a combinational read.  It does not need to.
//   mapper_prg_bank_offset is an always @* function of nes_cpu6502's bus_addr,
//   which is itself always @*, and bus_addr only moves when the CPU's state_reg
//   moves, i.e. on the one posedge per 12 clk where ce_cpu is high.  So the PRG
//   address is stable for div_phase 1..11 and for the following div_phase 0 --
//   twelve clk in which it does not move at all.  The CPU latches bus_din on
//   the posedge whose pre-edge div_phase is 0, so it samples the byte this
//   module latched at the posedge one clk earlier, when the address was the
//   same value.  The mapper's bus-conflict compare is safe for the same reason:
//   mapper_we is the registered cart_wr_pending_q, so it is high on one clk
//   while mapper_cpu_addr is the latched cart_wr_addr_q, and the write itself
//   only reaches bank_select on the NEXT posedge, one clk after the compare.
//   The address therefore has not moved between the compare and the read that
//   fed it.  prg_en exists for power only: with it low prg_rdata HOLDS the last
//   byte rather than returning zero, so gating it is only safe where the
//   address is also being held.
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
    parameter integer PRG_ENABLE     = 1,
    parameter integer CHR_ENABLE     = 1,
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
    input  wire                     chr_ram_enable,

    // Cartridge load port.  Inert by default: both halves are written only while
    // the matching enable is high AND the strobe is high.  See CARTRIDGE LOAD
    // PORT above.  Left unconnected by every pre-existing instance.
    input  wire                     prg_ld_en,
    input  wire [PRG_ADDR_BITS-1:0] prg_ld_addr,
    input  wire [7:0]               prg_ld_data,
    input  wire                     prg_ld_we,
    input  wire                     chr_ld_en,
    input  wire [CHR_LOCAL_BITS-1:0] chr_ld_addr,
    input  wire [7:0]               chr_ld_data,
    input  wire                     chr_ld_we
);

    generate

    if (PRG_ENABLE != 0) begin : g_prg
        reg [7:0] prg_rom [0:PRG_SIZE_BYTES-1];

        initial
            $readmemh(PRG_INIT_FILE, prg_rom);

        always @(posedge clk) begin
            if (reset)
                prg_rdata <= 8'h00;
            else if (prg_en)
                prg_rdata <= prg_rom[prg_addr];

            // The load write is independent of reset on purpose: the console is
            // held in reset for the whole load and must still be writable.  It
            // is the only write port on PRG, so this is one write port whether
            // the design loads or not.
            if (prg_ld_en && prg_ld_we)
                prg_rom[prg_ld_addr] <= prg_ld_data;
        end
    end else begin : g_prg_off
        always @(posedge clk) begin
            if (reset)
                prg_rdata <= 8'h00;
        end
    end

    if (CHR_ENABLE != 0) begin : g_chr
        reg [7:0] chr_rom [0:CHR_SIZE_BYTES-1];
        wire [CHR_LOCAL_BITS-1:0] chr_rindex;
        wire [CHR_LOCAL_BITS-1:0] chr_windex;
        wire [CHR_LOCAL_BITS-1:0] chr_lindex;
        wire                      chr_ld_wr;
        wire                      chr_wenable;
        wire [CHR_LOCAL_BITS-1:0] chr_wsel;
        wire [7:0]                chr_wdat;

        assign chr_rindex = chr_addr[CHR_LOCAL_BITS-1:0];
        assign chr_windex = chr_waddr[CHR_LOCAL_BITS-1:0];
        assign chr_lindex = chr_ld_addr[CHR_LOCAL_BITS-1:0];

        // ONE write statement, ONE write port.  The load and the mapper share the
        // port through a mux on the enable, address and data -- not through an
        // if/else that names the array twice.  An if/else on the array is TWO
        // write statements, which Vivado reads as two write ports, cannot map to a
        // simple-dual-port RAM, and silently falls back to distributed RAM: that
        // measured as CHR leaving block RAM (2 tiles -> 0) with LUT-as-Memory
        // going 2 -> 3074.  The muxed single write keeps the primitive a RAMB36.
        // Load is the priority: with the console held the mapper condition is
        // never true, so this only guarantees a straggling $2007 store cannot
        // corrupt a streaming image, and with the load disabled it is the mapper
        // write byte-for-byte.  The select uses === so that an unconnected load
        // enable (z in simulation) reads as "not selected" and can never leak z
        // into the mapper's write address; synthesis treats === as ==, so the
        // hardware is unaffected.
        assign chr_ld_wr    = (chr_ld_en === 1'b1) && (chr_ld_we === 1'b1);
        assign chr_wenable  = chr_ld_wr | (chr_ram_enable && chr_we);
        assign chr_wsel     = chr_ld_wr ? chr_lindex : chr_windex;
        assign chr_wdat     = chr_ld_wr ? chr_ld_data : chr_wdata;

        initial
            $readmemh(CHR_INIT_FILE, chr_rom);

        always @(posedge clk) begin
            if (reset)
                chr_rdata <= 8'h00;
            else if (ce_ppu && chr_req)
                chr_rdata <= chr_rom[chr_rindex];

            // Not gated by reset: the console is held in reset for the whole load
            // and the array must still be writable.
            if (chr_wenable)
                chr_rom[chr_wsel] <= chr_wdat;
        end
    end else begin : g_chr_off
        always @(posedge clk) begin
            if (reset)
                chr_rdata <= 8'h00;
        end
    end

endgenerate

endmodule
