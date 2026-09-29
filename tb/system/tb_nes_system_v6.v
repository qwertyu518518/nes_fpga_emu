`timescale 1ns/1ps

// PHASE 1+2 for nes_system_v6.
//
// Five DUT instances on the same clock:
//   ab_v6     nes_system_v6  MAPPER_SELECT=0  NROM_CHR_RAM=1  external CHR on
//                          the top-level port.  THIS IS THE $2007-TO-CHR RAM
//                          INSTANCE (W1).  Its CHR model is preloaded with a
//                          SENTINEL and only the program's own $2007 writes put
//                          the rendered image there.
//   ab_v5     nes_system_v5  identical params internal CHR, preloaded by hierarchy
//   chr_rom   nes_system_v6  MAPPER_SELECT=0  NROM_CHR_RAM=0  the CHR-ROM twin of
//                          ab_v6: byte-identical program, its own 128 KiB CHR
//                          model already holding the bytes the program uploads.
//                          This is the ROM half of the RAM/ROM ignore pair.
//   chr_ram_b nes_system_v6  MAPPER_SELECT=0  NROM_CHR_RAM=1  ab_v6 again, same
//                          program code, one PRG data byte changed so the program
//                          uploads the COMPLEMENT image.  Self-validating pair.
//   chr_mmc3  nes_system_v6  MAPPER_SELECT=4  MMC3_CHR_RAM=1  its own CHR model
//                          and its own registered chr_rdata, its own program image
//
// Every P0 assertion is about the v6 external CHR path; every P1 assertion is
// a carried-over invariant that has to be RE-PROVED on the v6 instance, not
// assumed from v5.  ab_v6 and ab_v5 share one program image so P0-4 can compare
// them instruction for instruction; chr_mmc3 runs a SEPARATE image because the
// phase 1 cart-write count (P0-2) and the phase 1 PPUCTRL value are NROM-specific
// and would be changed by the extra $8001/$C000/$E000 writes P0-7 and P1-5 need.
//
// WHY ab_v6 IS NROM_CHR_RAM=1 AND WHY THAT IS NOT A WEAKENING.
//   With NROM_CHR_RAM=0 mapper_chr_ram_we (nes_mapper.v:221) is a hard 0 and the
//   new $2007 write path would be structurally dead in this tb: the tb chr_mem
//   write is gated on chr_we && mapper_chr_ram_we, so it would never fire and
//   nothing below would be observed.  chr_rom is the same program with
//   NROM_CHR_RAM=0 and is where the ignore behaviour is proven.  Making the
//   phase 1 instance a RAM board is what lets P0-4 itself become the strongest
//   check in the file: ab_v5's internal chr_ram and ab_v6's external chr_mem
//   both start at the SENTINEL and both end at the same 48 bytes ONLY if the
//   external $2007 write really lands.

module tb_nes_system_v6;

// ---------------------------------------------------------------- parameters

localparam integer CHR_ADDR_BITS = 17;
localparam integer CHR_MEM_BYTES = 131072;
localparam integer FRAME_TARGET = 3;
localparam integer PIXELS_PER_FRAME = 240 * 256;
localparam integer AB_VISIBLE_TARGET = FRAME_TARGET * PIXELS_PER_FRAME;

// Both instances get exactly these parameters.  HEADER_MIRRORING=1 is the
// iNES "vertical arrangement" bit, chosen so P1-3 has a non-zero header to
// observe.  PRG_SIZE_BYTES has to exceed 32 KiB or nes_mapper_nrom's 16 KiB
// concatenation branch goes negative, so the image is 128 KiB and
// NROM_PRG_SIZE_BYTES is the standard 32 KiB NROM board.
localparam integer DUT_PRG_SIZE_BYTES = 131072;
localparam integer DUT_PRG_ADDR_BITS = $clog2(DUT_PRG_SIZE_BYTES);
localparam integer DUT_NROM_PRG_SIZE_BYTES = 32768;
localparam [7:0] DUT_MAPPER_SELECT = 8'd0;
localparam [2:0] DUT_HEADER_MIRRORING = 3'd1;

// NROM keeps a 16 KiB window only when NROM_PRG_SIZE_BYTES <= 16384.  With the
// standard 32 KiB board it keeps the full 15-bit window, so the TB PRG bank
// model is the low 15 bits of the CPU address.  The TB image therefore only
// needs the 32 KiB window the mapper can actually reach.
localparam integer TB_NROM_16K_MIRROR = (DUT_NROM_PRG_SIZE_BYTES <= 16384);
localparam integer TB_WINDOW_BITS = (TB_NROM_16K_MIRROR != 0) ? 14 : 15;
localparam integer TB_WINDOW_BYTES = (1 << TB_WINDOW_BITS);

// The nmi handler lives at $8B80, past the $8A80 table, because W3's loop B puts
// roughly 250 bytes of read-back code in it and the handler has to stay a
// single contiguous region for the unprogrammed-region tripwire below.
localparam [15:0] NMI_HANDLER = 16'h8B80;
localparam [15:0] IRQ_HANDLER = 16'h8A30;
localparam [15:0] FAIL1 = 16'h8A50;
localparam [15:0] FAIL2 = 16'h8A60;
localparam [15:0] FAIL3 = 16'h8A70;
localparam [15:0] TABLE1_ADDR = 16'h8A80;
localparam [15:0] MAIN_PROG = 16'h8000;
localparam [15:0] NMI_COUNTER_CELL = 16'h0010;
localparam [15:0] IRQ_COUNTER_CELL = 16'h0011;
localparam [15:0] DMA_FLAG_CELL = 16'h0013;
localparam [15:0] OAM_RB_FLAG_CELL = 16'h0014;
localparam [15:0] CHR_UPLOAD_FLAG_CELL = 16'h0015;
localparam [15:0] PORT1_9TH_CELL = 16'h0018;
localparam [15:0] PORT2_9TH_CELL = 16'h0019;
localparam [15:0] PORT1_CELL_BASE = 16'h0020;
localparam [15:0] PORT2_CELL_BASE = 16'h0028;
localparam [7:0] BUTTONS1 = 8'hA5;
localparam [7:0] BUTTONS2 = 8'h5A;
localparam integer CTRL_READS = 18;
localparam [7:0] FRAME_IRQ_INHIBIT = 8'h40;
localparam [7:0] PPUCTRL_FINAL = 8'h90;
localparam [7:0] PPUMASK_FINAL = 8'h1E;
localparam [7:0] OAM_RB_EXPECT = 8'h11;

// ------------------------------------------------------ W1 CHR upload shapes
//
// The program uploads the 48-byte three-tile image v4 used, one $2007 byte at a
// time, from two PRG DATA bytes rather than from immediates.  That is what lets
// chr_ram_b run BYTE-IDENTICAL CODE: only 8A00/8A01 differ between the two
// images, so "the same program" is literally true at the instruction level and
// the only thing that changes is which pattern the loop stores.
//
//   run A (ab_v6, chr_rom): 8A00=$FF 8A01=$00 -> the v4 image
//   run B (chr_ram_b):      8A00=$00 8A01=$FF -> its exact complement
//
// Run A's image is what P0-5's named pixel classes were derived from, so ab_v6
// keeps it.  The two images differ on EVERY one of the 48 bytes, which is what
// makes each instance's own preload a usable sentinel against its own upload.
localparam [15:0] CHR_FILL_ON_ADDR = 16'h8A00;
localparam [15:0] CHR_FILL_OFF_ADDR = 16'h8A01;
localparam [7:0] CHR_FILL_RUN_A_ON = 8'hFF;
localparam [7:0] CHR_FILL_RUN_A_OFF = 8'h00;
localparam [7:0] CHR_FILL_RUN_B_ON = 8'h00;
localparam [7:0] CHR_FILL_RUN_B_OFF = 8'hFF;
localparam integer CHR_TILE_BYTES = 48;

// ----------------------------------------------------- W3 $2007 CHR read-back
//
// chr_rd_arm completes the pair chr_waddr/chr_we/chr_wdata opened by the $2007
// CHR WRITE: a $2007 CHR READ now has a path out of the external CHR bus.  No
// instruction anywhere above ever READ $2007, so the whole read half was dead
// code in this file and a green run proved nothing about it.  Two loops are
// added, in the same PRG image so all five instances run them:
//
//   loop A  build_main, immediately after the upload, with PPUMASK still $00
//           (nothing is displayed, so a displaced fetch byte is unobservable).
//           It re-reads the 8 bytes the upload just stored at $0000.
//   loop B  build_nmi_handler, with PPUMASK=$1E and rendering ON.  NMI fires at
//           scanline 241, inside the provably invisible set, and the loop is
//           sized to finish around scanline 250, so it cannot drift onto a
//           visible line without W3-10 killing the run.  It re-reads two windows
//           the program wrote and one window it NEVER wrote, then restores t and
//           v to $0000 -- necessary, because nes_ppu2c02 drives the background
//           from temp_addr (bg_coarse_x_sum / bg_y_total / bg_nametable all read
//           temp_addr), so a $2006 write left in place WOULD move the picture.
//
// Both loops put their eight bytes into eight RAM cells as well as comparing
// them, so the testbench holds the value the cpu received somewhere it can read
// on all five instances independently of what the ppu is doing.  That cell is
// what the cross-DUT A/B in W3-8 compares.
//
// The expected bytes come from their own PRG data cells, not from the two cells
// the fill loop reads, so chr_ram_b still runs byte-identical CODE with
// complementary DATA: the main initial below swaps the new cells exactly the way
// it swaps CHR_FILL_ON_ADDR / CHR_FILL_OFF_ADDR.
localparam [15:0] CHR_RB_FAIL = 16'h8A40;
localparam [15:0] CHR_RB_EXP_ON_ADDR = 16'h8A02;
localparam [15:0] CHR_RB_EXP_OFF_ADDR = 16'h8A03;
localparam [15:0] CHR_RB_EXP_UNW_ADDR = 16'h8A04;
// The three windows loop B reads.  The upload's ON/OFF layout is
// [0:7]=FF [8:15]=00 [16:23]=00 [24:31]=FF [32:39]=FF [40:47]=00 in BOTH halves,
// so block1+32 ($1020) is ON and block1+40 ($1028) is OFF, and block1+64
// ($1040) is past the 48 bytes the upload touches and holds the tb's load
// value.  Naming them from the image is what keeps the expectations honest.
localparam [15:0] CHR_RB_LOOP_A_ADDR = 16'h0000;
localparam [15:0] CHR_RB_LOOP_B_ON = 16'h1020;
localparam [15:0] CHR_RB_LOOP_B_OFF = 16'h1028;
localparam [15:0] CHR_RB_LOOP_B_UNW = 16'h1040;
localparam [15:0] CHR_RB_STORE_A = 16'h0030;
localparam [15:0] CHR_RB_STORE_BON = 16'h0040;
localparam [15:0] CHR_RB_STORE_BOFF = 16'h0050;
localparam [15:0] CHR_RB_STORE_BUNW = 16'h0060;
localparam [7:0] CHR_RB_UNWRITTEN_EXPECT = 8'h00;
localparam integer CHR_RB_WINDOWS = 4;
localparam integer CHR_RB_WINDOW_BYTES = 8;

// ------------------------------------------------------- phase 2 MMC3 config
//
// chr_mmc3 is elaborated with MAPPER_SELECT=4 and MMC3_CHR_RAM=1.  Its program
// writes $8001 five times, each inside vblank.  Steps 1-3 are the original three
// and step 4-5 are the W2 pair that proves a $2007 CHR write is bank-qualified
// by the mapper.  MMC3_PPUCTRL is $00, so local chr_addr[12] is 0 and local
// chr_addr[11] selects window 0 (r0) or window 1 (the odd 1 KiB half of r0).
// Nothing ever sets $8000, so chr_inversion_r stays 0 and window index
// {ppu_addr[12], ppu_addr[11:10]} resolves as 0/1 for bit 12 clear and 4/5/6/7
// for bit 12 set; r1/r3 are unreachable in this configuration and never written.

localparam [7:0] DUT_MMC3_SELECT = 8'd4;
localparam [7:0] MMC3_PPUCTRL = 8'h00;
localparam [7:0] MMC3_BANK_R0 = 8'h00;
localparam [7:0] MMC3_BANK_R1 = 8'h01;
localparam [7:0] MMC3_BANK_R2 = 8'h41;
// W2.  Step 4 puts r0 back to $00 so the write lands at (reg<<10)|0x040 =
// 0x00040, step 5 moves r0 to $42 -> reg {0x42[7:1],1'b0} = $42 -> (0x42<<10)|
// 0x040 = 0x10840 for the same local address.  A third write at local $0840 puts
// ppu_addr[11] high, so chr_window_base is index 1 = {reg[7:1],1'b1} = $43 ->
// (0x43<<10)|0x040 = 0x10C40.  ($0840, not $0440: the sub-select is ppu_addr[11],
// and $0400 is bit 10.)  All three sit OUTSIDE the 48-byte preloads P0-7 compares
// pairwise (reg $00 at 0x0000, reg $00 image 2 at 0x0800, reg $40 at 0x10000,
// the W2 image at 0x10800), which is why P0-7 needed no image change to
// accommodate them.
localparam [7:0] MMC3_W2_R0_LOW = 8'h00;
localparam [7:0] MMC3_W2_R0_HIGH = 8'h42;
localparam [15:0] MMC3_W2_ADDR_LOW = 16'h0040;
localparam [15:0] MMC3_W2_ADDR_ODD = 16'h0840;
localparam [7:0] MMC3_W2_BYTE_LOW = 8'hA1;
localparam [7:0] MMC3_W2_BYTE_HIGH = 8'hB2;
localparam [7:0] MMC3_W2_BYTE_ODD = 8'hC3;
localparam [16:0] MMC3_W2_CANARY_OFF = 17'h0041;
localparam [7:0] MMC3_W2_CANARY = 8'h5A;
localparam [16:0] MMC3_W2_ADDR_LOW_EXP = 17'h00040;
localparam [16:0] MMC3_W2_ADDR_HIGH_EXP = 17'h10840;
localparam [16:0] MMC3_W2_ADDR_ODD_EXP = 17'h10C40;
localparam [16:0] MMC3_W2_IMG_BASE = 17'h10800;
localparam [7:8] MMC3_REG_R0 = 8'h00;
localparam [7:8] MMC3_REG_R1 = 8'h00;
localparam [7:0] MMC3_REG_R2 = 8'h40;
localparam integer MMC3_IMG_BASE_REG0 = 0 * 1024;
localparam integer MMC3_IMG_BASE_REG1 = 2 * 1024;
localparam integer MMC3_IMG_BASE_REG2 = 64 * 1024;
localparam [7:0] MMC3_IRQ_LATCH_VALUE = 8'h07;
localparam [15:0] MMC3_FAIL = 16'h8A70;
localparam [15:0] MMC3_IRQ_CELL = 16'h0013;
localparam [7:0] MMC3_OAM_RB_EXPECT = 8'hF0;
localparam [7:0] MMC3_OAM_Y = 8'hF0;
localparam [7:0] MMC3_OAM_TILE = 8'h02;
localparam [3:0] MMC3_EXP_INDEX_0 = 4'd1;
// The $01 write is the honest, documented exception.  nes_mapper_mmc3.v:208
// latches R0 as {cpu_dout[7:1], 1'b0}, so $01 and $00 are the SAME 1 KiB bank
// (that is the real MMC3 2 KiB granularity: bit 0 is the odd/even 1 KiB select
// and it lives in local chr_addr[11], not in the register).  The named value
// for this step is therefore 1, the same concrete index the reg $00 image
// produces, and check_p0_7 additionally asserts that the DUT's own
// chr_final_addr[16:10] is bit-identical across the two steps so the equality is
// a measured fact rather than an unverified assumption.
localparam [3:0] MMC3_EXP_INDEX_1 = 4'd1;
localparam [3:0] MMC3_EXP_INDEX_2 = 4'd8;
// W2 steps 4 and 5.  Step 4 returns r0 to $00, so the tile-0 window is reg $00
// again and the named index goes back to 1; step 5 selects reg $42 whose
// preloaded tile-0 is still plane0=$FF / plane1=$FF, so the index is 8 again.
localparam [3:0] MMC3_EXP_INDEX_3 = 4'd1;
localparam [3:0] MMC3_EXP_INDEX_4 = 4'd8;
localparam integer MMC3_FRAME_TARGET = 3;
localparam integer MMC3_BANK_STEPS = 5;

reg clk;
reg reset;
reg [7:0] buttons1;
reg [7:0] buttons2;
reg tb_live;

integer i;
integer k;

// ------------------------------------------------------------ v6 observable

wire [7:0] chr_rdata;
wire        v6_pixel_valid;
wire [7:0]  v6_pixel_x;
wire [7:0]  v6_pixel_y;
wire [3:0]  v6_pixel_index;
wire        v6_frame_done;
wire        v6_vblank;
wire        v6_nmi_o;
wire        v6_apu_irq_o;
wire        v6_audio_sample_valid;
wire [15:0] v6_audio_sample_left;
wire [15:0] v6_audio_sample_right;
wire [31:0] v6_cpu_cycle;
wire [8:0]  v6_ppu_dot;
wire [8:0]  v6_ppu_scanline;
wire [2:0]  v6_bus_owner;
wire        v6_bus_active;
wire [7:0]  v6_bus_wait_count;
wire        v6_bus_req;
wire        v6_bus_stall;
wire        v6_bus_fire;
wire [15:0] v6_bus_addr;
wire        v6_bus_we;
wire [7:0]  v6_bus_dout;
wire [7:0]  v6_bus_din;
wire        v6_sel_ram;
wire        v6_sel_ppu;
wire        v6_sel_apu_io;
wire        v6_sel_open_bus;
wire        v6_sel_cart_ram;
wire        v6_sel_cart_rom;
wire        v6_ram_we;
wire        v6_ppu_reg_cs;
wire        v6_ppu_reg_we;
wire [2:0]  v6_ppu_reg_addr;
wire        v6_apu_reg_cs;
wire        v6_apu_reg_we;
wire [4:0]  v6_apu_reg_addr;
wire        v6_controller_data;
wire        v6_cart_req;
wire        v6_cart_xfer;
wire [15:0] v6_cart_addr;
wire [7:0]  v6_cart_din;
wire        v6_cart_ack;
wire        v6_bus_hold;
wire        v6_oam_dma_start;
wire        v6_oam_dma_cpu_hold;
wire        v6_oam_dma_cpu_read_ack;
wire [15:0] v6_oam_dma_cpu_read_addr;
wire [7:0]  v6_oam_dma_cpu_rdata;
wire        v6_oam_dma_ppu_reg_cs;
wire        v6_oam_dma_ppu_reg_we;
wire [2:0]  v6_oam_dma_ppu_reg_addr;
wire [7:0]  v6_oam_dma_ppu_reg_dout;
wire        v6_oam_dma_busy;
wire        v6_oam_dma_done;
wire [7:0]  v6_oam_dma_page;
wire [7:0]  v6_oam_dma_base_addr;
wire [7:0]  v6_oam_dma_index;
wire        v6_apu_dmc_bus_req;
wire        v6_dma_sel;
wire        v6_dma_ack;
wire [7:0]  v6_dma_din;
wire        v6_dma_unimpl;
wire        v6_ppu_port_cs;
wire        v6_ppu_port_we;
wire [2:0]  v6_ppu_port_addr;
wire [7:0]  v6_ppu_port_din;
wire [2:0]  v6_mapper_id;
wire [DUT_PRG_ADDR_BITS-1:0] v6_mapper_prg_bank_offset;
wire [CHR_ADDR_BITS-1:0] v6_mapper_chr_bank_offset;
wire [2:0]  v6_mapper_mirroring;
wire [7:0]  v6_mapper_nametable_map;
wire        v6_mapper_irq;
wire        v6_irq_line;
wire        v6_mapper_write_pulse;
wire [15:0] v6_mapper_write_addr;
wire [7:0]  v6_mapper_write_data;
wire [7:0]  v6_prg_readback;
wire        v6_chr_req;
wire [CHR_ADDR_BITS-1:0] v6_chr_final_addr;
wire [13:0] v6_chr_waddr;
wire        v6_chr_we;
wire [7:0]  v6_chr_wdata;
wire        v6_mapper_chr_ram_we;

// ------------------------------------------------------------ v5 observable

wire        v5_pixel_valid;
wire [7:0]  v5_pixel_x;
wire [7:0]  v5_pixel_y;
wire [3:0]  v5_pixel_index;
wire        v5_frame_done;
wire        v5_vblank;
wire        v5_nmi_o;
wire        v5_apu_irq_o;
wire        v5_audio_sample_valid;
wire [15:0] v5_audio_sample_left;
wire [15:0] v5_audio_sample_right;
wire [31:0] v5_cpu_cycle;
wire [8:0]  v5_ppu_dot;
wire [8:0]  v5_ppu_scanline;
wire [2:0]  v5_bus_owner;
wire        v5_bus_active;
wire [7:0]  v5_bus_wait_count;
wire        v5_bus_req;
wire        v5_bus_stall;
wire        v5_bus_fire;
wire [15:0] v5_bus_addr;
wire        v5_bus_we;
wire [7:0]  v5_bus_dout;
wire [7:0]  v5_bus_din;
wire        v5_sel_ram;
wire        v5_sel_ppu;
wire        v5_sel_apu_io;
wire        v5_sel_open_bus;
wire        v5_sel_cart_ram;
wire        v5_sel_cart_rom;
wire        v5_ram_we;
wire        v5_ppu_reg_cs;
wire        v5_ppu_reg_we;
wire [2:0]  v5_ppu_reg_addr;
wire        v5_apu_reg_cs;
wire        v5_apu_reg_we;
wire [4:0]  v5_apu_reg_addr;
wire        v5_controller_data;
wire        v5_cart_req;
wire        v5_cart_xfer;
wire [15:0] v5_cart_addr;
wire [7:0]  v5_cart_din;
wire        v5_cart_ack;
wire        v5_bus_hold;
wire        v5_oam_dma_start;
wire        v5_oam_dma_cpu_hold;
wire        v5_oam_dma_cpu_read_ack;
wire [15:0] v5_oam_dma_cpu_read_addr;
wire [7:0]  v5_oam_dma_cpu_rdata;
wire        v5_oam_dma_ppu_reg_cs;
wire        v5_oam_dma_ppu_reg_we;
wire [2:0]  v5_oam_dma_ppu_reg_addr;
wire [7:0]  v5_oam_dma_ppu_reg_dout;
wire        v5_oam_dma_busy;
wire        v5_oam_dma_done;
wire [7:0]  v5_oam_dma_page;
wire [7:0]  v5_oam_dma_base_addr;
wire [7:0]  v5_oam_dma_index;
wire        v5_apu_dmc_bus_req;
wire        v5_dma_sel;
wire        v5_dma_ack;
wire [7:0]  v5_dma_din;
wire        v5_dma_unimpl;
wire        v5_ppu_port_cs;
wire        v5_ppu_port_we;
wire [2:0]  v5_ppu_port_addr;
wire [7:0]  v5_ppu_port_din;
wire [2:0]  v5_mapper_id;
wire [DUT_PRG_ADDR_BITS-1:0] v5_mapper_prg_bank_offset;
wire [CHR_ADDR_BITS-1:0] v5_mapper_chr_bank_offset;
wire [2:0]  v5_mapper_mirroring;
wire [7:0]  v5_mapper_nametable_map;
wire        v5_mapper_irq;
wire        v5_irq_line;
wire        v5_mapper_write_pulse;
wire [15:0] v5_mapper_write_addr;
wire [7:0]  v5_mapper_write_data;
wire [7:0]  v5_prg_readback;

// ---------------------------------------------------------- mmc3 observable

wire        m_pixel_valid;
wire [7:0]  m_pixel_x;
wire [7:0]  m_pixel_y;
wire [3:0]  m_pixel_index;
wire        m_frame_done;
wire        m_vblank;
wire        m_nmi_o;
wire        m_apu_irq_o;
wire [31:0] m_cpu_cycle;
wire [8:0]  m_ppu_dot;
wire [8:0]  m_ppu_scanline;
wire [2:0]  m_bus_owner;
wire        m_bus_fire;
wire [15:0] m_bus_addr;
wire        m_bus_we;
wire [7:0]  m_bus_dout;
wire [7:0]  m_bus_din;
wire        m_ram_we;
wire        m_sel_ram;
wire        m_sel_ppu;
wire        m_cart_xfer;
wire [15:0] m_cart_addr;
wire [7:0]  m_cart_din;
wire [2:0]  m_mapper_id;
wire [2:0]  m_mapper_mirroring;
wire [7:0]  m_mapper_nametable_map;
wire        m_mapper_irq;
wire        m_irq_line;
wire        m_mapper_write_pulse;
wire [15:0] m_mapper_write_addr;
wire [7:0]  m_mapper_write_data;
wire [7:0]  m_prg_readback;
wire        m_chr_req;
wire [CHR_ADDR_BITS-1:0] m_chr_final_addr;
wire [13:0] m_chr_addr;
wire [13:0] m_chr_waddr;
wire        m_chr_we;
wire [7:0]  m_chr_wdata;
wire        m_mapper_chr_ram_we;

// ---------------------------------------------------- chr_rom / chr_ram_b
//
// chr_rom is ab_v6 with NROM_CHR_RAM=0 and chr_ram_b is ab_v6 with the two PRG
// fill bytes swapped.  Everything else about them is identical, so any pixel
// difference between them and ab_v6 can only come from what the program stored.

wire        r_pixel_valid;
wire [7:0]  r_pixel_x;
wire [7:0]  r_pixel_y;
wire [3:0]  r_pixel_index;
wire        r_frame_done;
wire [8:0]  r_ppu_dot;
wire [8:0]  r_ppu_scanline;
wire [CHR_ADDR_BITS-1:0] r_chr_final_addr;
wire [13:0] r_chr_waddr;
wire        r_chr_we;
wire [7:0]  r_chr_wdata;
wire        r_mapper_chr_ram_we;
wire        r_mapper_chr_ram_enable;
wire [31:0] r_cpu_cycle;

wire        rb_pixel_valid;
wire [7:0]  rb_pixel_x;
wire [7:0]  rb_pixel_y;
wire [3:0]  rb_pixel_index;
wire        rb_frame_done;
wire [8:0]  rb_ppu_dot;
wire [8:0]  rb_ppu_scanline;
wire [CHR_ADDR_BITS-1:0] rb_chr_final_addr;
wire [13:0] rb_chr_waddr;
wire        rb_chr_we;
wire [7:0]  rb_chr_wdata;
wire        rb_mapper_chr_ram_we;
wire [31:0] rb_cpu_cycle;

// ----------------------------------------------------------- CHR memory model
//
// The register is on ce_ppu and indexes the FULL 17-bit chr_final_addr.  The
// fetch units advance chr_addr one ce before they sample chr_rdata, so a
// combinational read of chr_mem would return every tile byte-shifted by one.
// Dropping bit 13 here would also hide the NROM aliasing the model is supposed
// to reproduce.
//
// THE WRITE HALF.  The byte that lands is the MAPPER'S OUTPUT address, not the
// PPU's local chr_waddr, and it is accepted only when the mapper agrees, so
//     accept_write = chr_we && mapper_chr_ram_we
//     chr_mem[chr_final_addr] <= chr_wdata
// Gating the array on chr_we alone would let a CHR-ROM build store into a local
// RAM and the whole ROM/RAM distinction would be untestable.  The write shares
// the ce_ppu edge with the read so both sides of the array sit on one enable.

reg [7:0] chr_mem [0:CHR_MEM_BYTES-1];
reg [7:0] chr_rdata_q;
reg [7:0] chr_tile_image [0:47];
reg [7:0] chr_tile_image_b [0:47];

assign chr_rdata = chr_rdata_q;

always @(posedge clk) begin
    if (reset)
        chr_rdata_q <= 8'h00;
    else if (ab_v6.ce_ppu) begin
        chr_rdata_q <= chr_mem[v6_chr_final_addr];
        if ((v6_chr_we !== 1'b0) && (v6_mapper_chr_ram_we !== 1'b0)) begin
            chr_mem[v6_chr_final_addr] <= v6_chr_wdata;
            chr_wr_accepted = chr_wr_accepted + 1;
        end
    end
end

// TB-owned mapper model.  NROM has no bank register at all, so the CHR bank
// term is the constant 0 and the only live part is the local address mask.
reg [3:0] tb_chr_bank_model;

// chr_mmc3 gets its OWN 128 KiB CHR model and its OWN registered chr_rdata.
// Sharing the ab_v6 model would make a bank switch invisible by construction:
// the point of P0-7 is that the bytes arriving at the PPU change, so the two
// models must never alias.
reg [7:0] m_chr_mem [0:CHR_MEM_BYTES-1];
reg [7:0] m_chr_pre [0:CHR_MEM_BYTES-1];
reg [7:0] m_chr_rdata_q;
wire [7:0] m_chr_rdata;

assign m_chr_rdata = m_chr_rdata_q;

// m_chr_addr is the LOCAL 14-bit address the PPU presents on its own chr_addr
// port.  chr_final_addr is the mapper's output one net downstream, so the
// translation comparison in P0-7 is not circular.
assign m_chr_addr = chr_mmc3.u_ppu.chr_addr;

always @(posedge clk) begin
    if (reset)
        m_chr_rdata_q <= 8'h00;
    else if (chr_mmc3.ce_ppu) begin
        m_chr_rdata_q <= m_chr_mem[m_chr_final_addr];
        if ((m_chr_we !== 1'b0) && (m_mapper_chr_ram_we !== 1'b0)) begin
            m_chr_mem[m_chr_final_addr] <= m_chr_wdata;
            m_wr_accepted = m_wr_accepted + 1;
        end
    end
end

// chr_rom / chr_ram_b get their OWN 128 KiB models and their OWN registered
// chr_rdata for the same reason chr_mmc3 does: a shared model would make the
// board type invisible by construction, which is the whole point of the
// RAM/ROM ignore pair.  rom_chr_pre is a full pre-run snapshot of the ROM
// model's contents so "byte identical to before" is a real comparison and not a
// re-derivation of the same load loop.

reg [7:0] rom_chr_mem [0:CHR_MEM_BYTES-1];
reg [7:0] rom_chr_pre [0:CHR_MEM_BYTES-1];
reg [7:0] rom_chr_rdata_q;
wire [7:0] rom_chr_rdata;

assign rom_chr_rdata = rom_chr_rdata_q;

always @(posedge clk) begin
    if (reset)
        rom_chr_rdata_q <= 8'h00;
    else if (chr_rom.ce_ppu) begin
        rom_chr_rdata_q <= rom_chr_mem[r_chr_final_addr];
        if ((r_chr_we !== 1'b0) && (r_mapper_chr_ram_we !== 1'b0))
            rom_chr_mem[r_chr_final_addr] <= r_chr_wdata;
    end
end

reg [7:0] ramb_chr_mem [0:CHR_MEM_BYTES-1];
reg [7:0] ramb_chr_rdata_q;
wire [7:0] ramb_chr_rdata;

assign ramb_chr_rdata = ramb_chr_rdata_q;

always @(posedge clk) begin
    if (reset)
        ramb_chr_rdata_q <= 8'h00;
    else if (chr_ram_b.ce_ppu) begin
        ramb_chr_rdata_q <= ramb_chr_mem[rb_chr_final_addr];
        if ((rb_chr_we !== 1'b0) && (rb_mapper_chr_ram_we !== 1'b0))
            ramb_chr_mem[rb_chr_final_addr] <= rb_chr_wdata;
    end
end

// ---------------------------------------------------------- program image

reg [7:0] tb_prg [0:TB_WINDOW_BYTES-1];
reg [7:0] tb_prg_b [0:TB_WINDOW_BYTES-1];
reg [7:0] m_prg [0:TB_WINDOW_BYTES-1];
reg [7:0] table1 [0:255];
reg [7:0] m_table1 [0:255];
reg [7:0] ctrl_rd_exp [0:CTRL_READS-1];
reg [15:0] bne_list [0:31];
integer bne_count;
reg     image_is_mmc3;
reg [15:0] pc;
reg [15:0] main_prog_end;
reg [15:0] nmi_end;
reg [15:0] irq_end;
reg [15:0] self_loop_addr;
reg [15:0] m_main_prog_end;
reg [15:0] m_nmi_end;
reg [15:0] m_irq_end;
reg [15:0] m_self_loop_addr;

// ---------------------------------------------------------------- counters

integer reset_clks;
integer reset_chr_req_bad;
integer reset_chr_addr_bad;
integer reset_chr_we_bad;
integer reset_chr_waddr_bad;
integer reset_mapper_id_bad;

integer frames_seen;
reg     prev_frame_done;
integer frame_delta_clk;
integer clk_count;
integer frame_mark_clk;
reg     have_frame_mark;

integer chr_req_total;
integer chr_addr_checks;
integer chr_addr_err;
integer chr_hi_addr_bad;
integer chr_req_bus_idle;
integer chr_req_during_dma;
integer chr_req_owner [0:7];
integer chr_req_owner_total;

integer chr_model_pred_checks;
integer chr_model_pred_err;
integer chr_latch_checks;
integer chr_latch_err;

reg [CHR_ADDR_BITS-1:0] chr_h1;
reg [CHR_ADDR_BITS-1:0] chr_h2;
reg     fu_sgrab_q;
reg     fu_cappl_q;
wire [2:0] fu_state;
wire       fu_cap_pl;
wire [7:0] fu_bg_lo;
wire [7:0] fu_bg_hi;

// P0-6 race window.  The tb chr_mem array now changes mid-run, so a shadow
// comparison whose address was itself written in the last two ce is comparing
// against a different epoch of the array.  Those beats are counted and skipped
// rather than silently compared; everything else is still checked.
reg [CHR_ADDR_BITS-1:0] chr_wq0;
reg [CHR_ADDR_BITS-1:0] chr_wq1;
reg                      chr_wq0_v;
reg                      chr_wq1_v;
integer chr_pred_race_skip;
integer chr_latch_race_skip;

// ---------------------------------------------------- W1 / W2 / ignore counters
integer chr_wr_beats;          // ab_v6 strobe beats
integer chr_wr_exp_total;      // $2007 writes the tb bus monitor saw in the chr half
integer chr_wr_checks;         // translation checks performed on write beats
integer chr_wr_addr_err;
integer chr_wr_req_clash;      // write beat with chr_req high
integer chr_wr_clash_visible;  // ... and with bg or sprites enabled
integer chr_wr_bit13_bad;
integer chr_wr_not_accepted;   // mapper refused a chr-ram board's write
integer chr_wr_consec;         // two consecutive ce_ppu with chr_we high
reg     chr_wr_prev;
reg     chr_write_on_port;
reg [CHR_ADDR_BITS-1:0] chr_wr_exp_final;

integer chr_wr_accepted;       // bytes the ab_v6 model actually stored

integer chr_up_flag_seen;
integer chr_up_snap_err;
integer chr_up_snap_nochange;
integer chr_up_addr_err;
integer chr_v5_snap_err;
integer rom_pre_bytes;
integer rom_pre_err;
integer rom_wr_beats;
integer rom_wr_ramwe_bad;
integer rom_wr_bad_wdata;
integer rom_final_bytes;
integer rom_tile_err;
integer rb_wr_beats;
integer rb_wr_not_accepted;
integer rb_tile_err;
integer rb_tile0_same;

integer pic_rom_cmp;
integer pic_rom_idx_diff;
integer pic_rom_geom_diff;
integer pic_rb_cmp;
integer pic_rb_idx_diff;
integer pic_rb_geom_diff;
integer pic_rb_tile0_diff;
integer m_wr_beats;
integer m_wr_exp_total;
integer m_wr_checks;
integer m_wr_addr_err;
integer m_wr_req_clash;
integer m_wr_clash_visible;
integer m_wr_bit13_bad;
integer m_wr_not_accepted;
integer m_wr_consec;
integer m_wr_accepted;
reg     m_wr_prev;
reg     m_write_on_port;
reg [CHR_ADDR_BITS-1:0] m_wr_exp_final;
integer m_wr_low_hit;
integer m_wr_high_hit;
integer m_wr_odd_hit;
integer m_wr_low_flat;
integer m_wr_high_flat;
integer m_wr_odd_flat;
integer m_wr_low_before;
integer m_wr_high_before;
integer m_wr_odd_before;

// ------------------------------------------- W3 $2007 CHR read-back counters
//
// rb_arm is u_ppu.g_chr_external.chr_rd_win, the window on which the third
// CHR-bus master puts the $2007 read address on chr_addr.  rb_read is the ce on
// which the two-cycle $2007 access COMPLETES and the cpu latches bus_din.  The
// two are always adjacent ce: nes_system_v6 raises the arm on the single clk
// whose pre-edge div_phase is 8, and the access completes on the next ce_cpu,
// which is div_phase 0.  So an arm that is not consumed on the very next ce_ppu
// was stranded, and that is checked rather than assumed.
//
// THE ONE-READ SKEW, MEASURED.  reg_cs (ppu_xfer) is high only on the cycle
// that COMPLETES the two-cycle $2007 access, and read_buffer_reg is refilled on
// that same edge, so the value the cpu latches on access N is the byte the port
// presented for access N-1.  That is the real 2C02 read buffer, not a defect.
// rb_prev_rdata_q / rb_prev_addr_q carry exactly that one-access pair, so the
// chain asserted in W3-2 is
//     bus_din(at read beat N) == chr_rdata(at read beat N-1)
//                             == chr_mem[address the arm of access N-1 carried]
// and every term in it is measured at a different point in time.
integer rb_arm_beats;
integer rb_arm_data_checks;
integer rb_arm_data_err;
integer rb_read_beats;
integer rb_read_checks;
integer rb_read_err;
integer rb_noprev;
integer rb_armed_missing;
integer rb_stranded;
integer rb_addr_err;
integer rb_arm_addr_err;
integer rb_ramwe_bad;
integer rb_we_overlap;
integer rb_coll_bg;
integer rb_coll_sp;
integer rb_race_skip;
integer rb_vis_bad;
integer rb_min_sl;
integer rb_max_sl;
integer rb_arms_mask0;
integer rb_arms_mask1;
integer rb_arms_vblank;
integer rb_loopa_arms;
integer rb_loopb_arms;
reg [CHR_ADDR_BITS-1:0] rb_pend_addr_q;
reg [7:0] rb_pend_byte_q;
reg rb_pend_valid_q;
reg [CHR_ADDR_BITS-1:0] rb_prev_addr_q;
reg [7:0] rb_prev_rdata_q;
reg rb_prev_valid_q;
reg [7:0] chr_rb_snap [0:(CHR_RB_WINDOWS * CHR_RB_WINDOW_BYTES)-1];
integer rb_snap_i;

assign fu_state = ab_v6.u_ppu.g_chr_external.u_chr_fetch.state;
assign fu_cap_pl = ab_v6.u_ppu.g_chr_external.u_chr_fetch.cap_pl;
assign fu_bg_lo = ab_v6.u_ppu.g_chr_external.u_chr_fetch.bg_lo;
assign fu_bg_hi = ab_v6.u_ppu.g_chr_external.u_chr_fetch.bg_hi;

integer cart_wr_total;
integer cart_pulse_total;
integer cart_pulse_err;
integer cart_pulse_width_err;
integer cart_pulse_spurious;
integer cart_pulse_multi;
reg     cart_pulse_due;
reg [15:0] cart_pulse_exp_addr;
reg [7:0]  cart_pulse_exp_data;
reg     prev_cart_pulse;

integer ab_visible_count;
integer ab_visible_div;
integer ab_all_ce_count;
integer ab_all_ce_div;

integer pix_index_mismatch;
integer pix_checked;
integer pix_cnt1;
integer pix_cnt2;
integer pix_cnt6;
integer pix_other;
reg     final_frame_active;
reg [3:0] expected_index;
integer visible_pixels;

integer bus_stall_err;
integer bus_wait_count_bad;
integer bus_fire_count;
integer prg_rd_count;
integer prg_wr_count;
integer prg_rd_err;
integer cartram_rd_count;
integer ram_rd_count;
integer ram_wr_count;
integer ppu_rd_count;
integer ppu_wr_count;
integer apu_rd_count;
integer apu_wr_count;
integer open_rd_count;
integer apu_rd_ctrl1;
integer apu_rd_ctrl2;
integer apu_wr_ctrl;
integer apu_wr_frame;
integer apu_wr_status;
integer apu_rd_4015;
integer apu_wr_dma;
integer ppu_wr_ctrl;
integer ppu_wr_mask;
integer ppu_wr_status;
integer ppu_wr_oamaddr;
integer ppu_wr_vaddr;
integer ppu_wr_vdata;
integer ppu_wr_other;
integer ram_wr_src;
integer ram_wr_nmi;
integer ram_wr_dma;
integer ram_wr_oamrb;
integer ram_wr_p1n;
integer ram_wr_p2n;

integer ctrl_rd_seen;
integer ctrl_wr_count;
integer ctrl_data_err;
integer ctrl_cs_err;

integer dma_start_count;
integer dma_done_count;
integer dma_ack_count;
integer dma_wr_count;
integer dma_addr_err;
integer dma_data_err;
integer dma_unimpl_seen;
integer dma_ppu_addr_err;
integer dma_ppu_we_err;

integer nmi_rise_count;
integer nmi_entry_count;
integer irq_rise_count;
integer irq_fall_count;
integer irq_line_err;
integer irq_pending_err;
integer mapper_irq_high;
integer apu_irq_high;

integer sample_strobes;
integer sample_nonzero;
integer sample_peak;
integer dmc_req_seen;
integer dmc_sel_seen;
integer illegal_hits;

reg saw_reset_lo;
reg saw_reset_hi;
reg saw_first_fetch;
reg saw_first_opcode;
reg saw_fetch_bus;
reg seen_main_loop;
reg in_nmi_handler;
reg in_irq_handler;
reg last_nmi_level;
reg [15:0] reset_lo_addr;
reg [15:0] reset_hi_addr;
reg [8:0] prev_dot;
reg [7:0] last_irq_flag;
reg prev_dma_ppu_cs;
reg prev_dma_ack;
reg [7:0] dma_byte_index;
reg [7:0] dma_wr_index;
reg [7:0] dma_exp_rdata;
reg expect_dma_data_valid;

// per-frame P0-3 bucket
integer f_chr_req;
integer f_chr_wr;
integer f_wr_final_bit13_bad;
integer f_local_bit13;
integer f_local_bit12;
integer f_final_bit13_bad;
integer f_addr_err;
integer f_max_final_addr;
integer last_f_chr_req;
integer last_f_chr_wr;
integer last_f_wr_final_bit13_bad;
integer last_f_local_bit13;
integer last_f_local_bit12;
integer last_f_final_bit13_bad;
integer last_f_addr_err;
integer last_f_max_final_addr;

// ----------------------------------------------------- phase 2 MMC3 counters

integer m_frames_seen;
integer m_post_switch_frames;
reg     m_prev_frame_done;
reg [8:0] m_prev_dot;

// P0-7.  m_bank_epoch counts COMPLETED $8001 writes minus one: it stays -1 until
// the first write lands, so no tile-0 pixel is bucketed before the program's
// first bank switch and a pre-render frame can never dilute a bucket.
integer m_bank_epoch;
reg [7:0] m_bank_model;
reg [7:0] m_bank_data  [0:MMC3_BANK_STEPS-1];
reg [7:0] m_bank_reg   [0:MMC3_BANK_STEPS-1];
reg [7:0] m_bank_ok    [0:MMC3_BANK_STEPS-1];
reg [15:0] m_bank_sl    [0:MMC3_BANK_STEPS-1];
integer m_bank_writes;
integer m_addr_checks [0:MMC3_BANK_STEPS-1];
integer m_addr_err    [0:MMC3_BANK_STEPS-1];
integer m_bit16_seen  [0:MMC3_BANK_STEPS-1];
integer m_first_hi    [0:MMC3_BANK_STEPS-1];
reg     m_first_hi_ok [0:MMC3_BANK_STEPS-1];
integer m_tile0_tot   [0:MMC3_BANK_STEPS-1];
integer m_tile0_exp   [0:MMC3_BANK_STEPS-1];
integer m_tile0_oth   [0:MMC3_BANK_STEPS-1];
reg [3:0] m_exp_index  [0:MMC3_BANK_STEPS-1];
integer m_chr_req_total;
integer m_cart_wr_total;
integer m_fail_hits;
reg     m_seen_self_loop;
integer z;

// P0-8.  Two independent collision checks per instance: the top level chr_req
// never high on two consecutive ce_ppu, and the two fetch units' chr_req never
// both high on the same ce.  ab_v5 has no external CHR port at all, so only
// ab_v6 and chr_mmc3 can be checked.
//
// RE-SCOPED FOR THE THIRD CHR MASTER.  chr_rd_win feeds chr_req directly, so a
// read arm that lands on the ce_ppu edge immediately after a fetch request beat
// makes chr_req high on two consecutive ce.  "chr_req is never high on two
// consecutive ce" therefore stopped being an invariant of the design the moment
// a $2007 CHR read could reach the bus, and it is NOT asserted any more.  What
// replaced it is strictly more specific, in the same style as the existing
// P0-2 WRITE-READ-ARBITRATION line:
//
//   * ab_consec_noread counts the consecutive pairs on which NEITHER beat was a
//     read arm.  That is exactly the case the old invariant covered -- the case
//     a run with chr_rd_arm tied to 1'b0 would have measured -- and it is still
//     asserted to be 0, so the fetch-vs-fetch property is not given up, only
//     re-expressed over the beats that can now legitimately collide.
//   * every consecutive pair is attributed to the master that won its SECOND
//     beat, by the same expression the ppu uses to drive chr_addr.  A pair whose
//     second beat is won by the read arm is then split by which fetch unit held
//     the first beat, so the collision the contract names (one displaced
//     background tile or one displaced sprite slot plane) is counted rather
//     than argued about.
//   * chr_mmc3 runs a program with no $2007 reads at all, so nothing can raise
//     an arm there and m_req_consec == 0 is still asserted untouched.
//
// That a read arm's ADDRESS is never corrupted by the colliding fetch master is
// a separate assertion, in the W3 monitor: on every arm beat chr_addr must equal
// the ppu's own v_addr[13:0] and chr_final_addr must equal the tb's own
// translation of it.  P0-8 counts the collision; W3-3 proves the arbitration.
reg     ab_req_prev;
reg     m_req_prev;
reg     ab_we_prev;
reg     m_we_prev;
reg [1:0] ab_prev_win;
integer ab_req_beats;
integer ab_req_consec;
integer ab_consec_arm;
integer ab_consec_arm_vs_bg;
integer ab_consec_arm_vs_sp;
integer ab_consec_bg;
integer ab_consec_sp;
integer ab_consec_noread;
integer ab_consec_rr;
integer ab_consec_arm_first_bg;
integer ab_we_consec;
integer ab_bgsp_beats;
integer ab_bgsp_clash;
integer m_req_beats;
integer m_req_consec;
integer m_we_consec;
integer m_bgsp_beats;
integer m_bgsp_clash;

// P1-5
integer m_irq_line_err;
integer m_irq_pending_err;
integer m_irq_high;
integer m_irq_rise;
reg     m_irq_prev;
integer m_irq_vec_fetch;
integer m_irq_entries;
integer m_irq_entry_bad;
integer m_irq_entry_min;
integer m_irq_entry_max;
integer m_irq_entry_stall;
integer m_irq_seq_bad;
integer m_irq_high_at_force;
integer m_irq_masked;
reg [6:0] m_prev_fire_state;
integer m_entry_hist [0:15];
integer m_bad_ce_n;
reg [6:0] m_bad_seq [0:15];
reg     m_irq_active;
integer m_irq_ce_n;
integer m_irq_seq_n;
reg [6:0] m_irq_seq [0:7];

// ---------------------------------------------- P1-11 tb-side mmc3 a12
//
// WHY THERE IS NO REAL A12.  The production ppu has no vrAM address bus, so
// there is no a12 to hand the mapper: bg_pattern_addr is 13 bits wide with bit
// 12 = PPUCTRL[4] and bit 11 a tile index bit, so no address carry ever reaches
// bit 12, the bg_fetch_* nets only exist inside the g_chr_external branch, and
// nes_system_v6 ties mapper_ppu_a12 to 1'b0.  That tie-off is CORRECT for this
// board rather than a gap.  control_reg is $00, so real hardware drives the ppu
// pattern address bit 12 low on every rendering line and clocks the mmc3
// scanline counter ZERO times per frame.  A synthesized dot-derived a12 would
// therefore report 241 where the hardware reports 0: a green test certifying
// the wrong answer.  So a12 is injected from here, as pure stimulus, using the
// nesdev canonical mmc3 case (one rising edge per RENDERING scanline, at ppu
// dot 260).
//
// The three terms are the same three the canonical case is written from, plus
// the rendering-line gate that "rendering" implies: scanlines 0..239 and the
// pre-render line 261.  241 lines a frame.  Without that gate the dot counter
// of this ppu free-runs through the 21 vblank lines as well, so the dot-only
// expression would report 262 rises per frame and clock the counter 21 times
// per frame that real hardware never clocks it.  a12_dotonly below measures
// exactly that ungated expression so the difference is a printed number and
// not an argument.
//
// All three inputs are REGISTERED (dot, scanline, mask_reg[3]), so the
// expression is a pure AND of three clk-domain registers: it is glitch-free,
// changes only in the delta right after a clk edge, and has no sub-clk pulse
// for the filter to miss.  dot advances on ce_ppu, a 1-in-4 pulse, so the
// window is 60 dots = 240 clk and the period is 341 dots = 1364 clk, giving
// exactly one rise per 1364 clk.  MMC3_A12_COOLDOWN is 2, so accepted edges
// have to be 3 clk apart; 1364 is 454x that margin, which the window measures
// as a12_gap_min and the task prints.
wire a12_model = chr_mmc3.u_ppu.mask_reg[3] &&
                 ((chr_mmc3.u_ppu.scanline < 9'd240) ||
                  (chr_mmc3.u_ppu.scanline == 9'd261)) &&
                 (chr_mmc3.u_ppu.dot >= 9'd260) &&
                 (chr_mmc3.u_ppu.dot <= 9'd319);
wire a12_dotonly = chr_mmc3.u_ppu.mask_reg[3] &&
                   (chr_mmc3.u_ppu.dot >= 9'd260) &&
                   (chr_mmc3.u_ppu.dot <= 9'd319);
reg  a12_win;
reg [1:0] a12_phase;
reg  a12_model_d;
reg  a12_dotonly_d;
reg  a12_filt_d;
reg  a12_fd_d;
reg  a12_snap_pend;
reg  a12_hi_armed;
reg  a12_irq_seen;
reg  a12_early_armed;
reg  a12_c0;
reg  a12_in_reload;
reg [7:0] a12_in_counter;
integer a12_clk_n;
integer a12_gap_min;
integer a12_last_filt_clk;
integer a12_edge_idx;
integer a12_snap_idx;
integer a12_snap_counter;
integer a12_snap_reload;
integer a12_snap_pending;
integer a12_snap1_counter;
reg     a12_snap1_reload;
integer a12_snap1_pending;
integer a12_snap2_idx;
integer a12_seq_err;
integer a12_rise;
integer a12_rise_last;
integer a12_dotonly_rise;
integer a12_dotonly_rise_last;
integer a12_filt;
integer a12_filt_last;
integer a12_hi_clk;
integer a12_hi_clk_last;
integer a12_hi_bad;
integer a12_hi_lines;
integer a12_hi_lines_last;
integer a12_vb_hi;
integer a12_vb_hi_last;
integer a12_fd_n;
integer a12_pending_hi;
integer a12_mapper_hi;
integer a12_mapper_base;
integer a12_apu_hi;
integer a12_net_hi;
integer a12_cart_wr;
integer a12_early_hi_err;
integer a12_idx_at_irq;
integer a12_handler_clk;
integer a12_edge_at_enable;
integer a12_line_hi_2b;
integer a12_entry_at_enable;
integer a12_vec_at_enable;
integer a12_cell_at_enable;
integer a12_cell_at_entry;
integer a12_drain_entry_n;
integer a12_counter_at_enable;

wire ab_bg_chr_req = ab_v6.u_ppu.g_chr_external.u_chr_fetch.chr_req;
wire ab_sp_chr_req = ab_v6.u_ppu.g_chr_external.u_sprite_chr_fetch.chr_req;
wire m_bg_chr_req = chr_mmc3.u_ppu.g_chr_external.u_chr_fetch.chr_req;
wire m_sp_chr_req = chr_mmc3.u_ppu.g_chr_external.u_sprite_chr_fetch.chr_req;
wire [6:0] m_cpu_state = chr_mmc3.u_cpu.dbg_state;
wire m_ppu_bg_enable = chr_mmc3.u_ppu.mask_reg[3];

// ------------------------------------------------------- W3 read predicates
//
// The read arm, the held arm register, and the completed $2007 CHR read.  The
// v_addr term in rb_read is the PRE-increment one, sampled on the same clk the
// ppu samples reg_cs, so it is the address the access actually asked for.
wire rb_arm = (ab_v6.u_ppu.g_chr_external.chr_rd_win !== 1'b0);
wire rb_armed = (ab_v6.u_ppu.g_chr_external.chr_rd_armed_q !== 1'b0);
wire rb_read = (v6_bus_fire !== 1'b0) && (v6_bus_we === 1'b0) &&
               (v6_sel_ppu === 1'b1) && (v6_ppu_reg_addr == 3'd7) &&
               (ab_v6.u_ppu.v_addr < 15'h2000);
// The provably invisible set, spelled out and not proxied through a mask bit:
//   * scanlines 240..260, where nothing is rendered and no fetch feeds a pixel
//   * any scanline on which the ppu's OWN bg_pa_enable is low AND mask_reg[2]
//     (show sprites) is low, which is loop A's PPUMASK=$00 window
// Scanline 261 is deliberately NOT in the set.
wire rb_vis_ok = ((ab_v6.u_ppu.scanline >= 9'd240) &&
                  (ab_v6.u_ppu.scanline <= 9'd260)) ||
                 ((ab_v6.u_ppu.bg_pa_enable === 1'b0) &&
                  (ab_v6.u_ppu.mask_reg[2] === 1'b0));

// A write that steals the mapper port from the fetch unit only damages a RENDERED
// pixel if something the fetch feeds is actually on screen.  bg_pa_enable is the
// ppu's own term for that on the background side, and sprites only reach the
// output on scanlines below 240, so a vblank-time write is harmless even with
// PPUMASK bits 2/3/4 set.  This is the exact enable, not a mask-bit proxy.
wire ab_chr_wr_displayed = ab_v6.u_ppu.bg_pa_enable ||
                           ((ab_v6.u_ppu.mask_reg[2] !== 1'b0) &&
                            (ab_v6.u_ppu.scanline < 9'd240));
wire m_chr_wr_displayed = chr_mmc3.u_ppu.bg_pa_enable ||
                          ((chr_mmc3.u_ppu.mask_reg[2] !== 1'b0) &&
                           (chr_mmc3.u_ppu.scanline < 9'd240));

// ----------------------------------------------------------------- helpers

// put is the only place that writes a program byte, so the same assembler
// tasks can fill either image.  image_is_mmc3 is the selector; every build
// task sets it explicitly on entry and on exit so no task can inherit a
// stale value.
task put;
    input [15:0] address;
    input [7:0] value;
    begin
        if (image_is_mmc3 === 1'b1)
            m_prg[address[TB_WINDOW_BITS-1:0]] = value;
        else
            tb_prg[address[TB_WINDOW_BITS-1:0]] = value;
    end
endtask

task emit;
    input [7:0] value;
    begin
        put(pc, value);
        pc = pc + 16'd1;
    end
endtask

task and_imm;
    input [7:0] value;
    begin
        emit(8'h29);
        emit(value);
    end
endtask

task lda_imm;
    input [7:0] value;
    begin
        emit(8'hA9);
        emit(value);
    end
endtask

task ldx_imm;
    input [7:0] value;
    begin
        emit(8'hA2);
        emit(value);
    end
endtask

task lda_abs;
    input [15:0] address;
    begin
        emit(8'hAD);
        emit(address[7:0]);
        emit(address[15:8]);
    end
endtask

task lda_abs_x;
    input [15:0] address;
    begin
        emit(8'hBD);
        emit(address[7:0]);
        emit(address[15:8]);
    end
endtask

task sta_abs;
    input [15:0] address;
    begin
        emit(8'h8D);
        emit(address[7:0]);
        emit(address[15:8]);
    end
endtask

task sta_abs_x;
    input [15:0] address;
    begin
        emit(8'h9D);
        emit(address[7:0]);
        emit(address[15:8]);
    end
endtask

task cmp_imm;
    input [7:0] value;
    begin
        emit(8'hC9);
        emit(value);
    end
endtask

task jmp_abs;
    input [15:0] address;
    begin
        emit(8'h4C);
        emit(address[7:0]);
        emit(address[15:8]);
    end
endtask

task bne_to;
    input [15:0] target;
    reg [15:0] here;
    begin
        here = pc;
        emit(8'hD0);
        emit(target - (here + 16'd2));
    end
endtask

task beq_to;
    input [15:0] target;
    reg [15:0] here;
    begin
        here = pc;
        emit(8'hF0);
        emit(target - (here + 16'd2));
    end
endtask

task bne_list_add;
    begin
        emit(8'hD0);
        bne_list[bne_count] = pc;
        bne_count = bne_count + 1;
        emit(8'h00);
    end
endtask

task bne_list_patch;
    input [15:0] target;
    integer m;
    begin
        for (m = 0; m < bne_count; m = m + 1)
            put(bne_list[m], target - (bne_list[m] + 16'd1));
    bne_count = 0;
    end
endtask

task jmp_patch;
    input [15:0] operand_addr;
    input [15:0] target;
    begin
        put(operand_addr, target[7:0]);
        put(operand_addr + 16'd1, target[15:8]);
    end
endtask

task ppu_set_addr;
    input [15:0] value;
    begin
        lda_imm(value[15:8]);
        sta_abs(16'h2006);
        lda_imm(value[7:0]);
        sta_abs(16'h2006);
    end
endtask

task ppu_write_data;
    input [7:0] value;
    begin
        lda_imm(value);
        sta_abs(16'h2007);
    end
endtask

// Eight $2007 writes of the byte held in a PRG DATA cell.  Taking the value
// from memory instead of an immediate is what lets chr_ram_b run byte-identical
// CODE: only the two data cells differ between the two images.
task ppu_fill8_src;
    input [15:0] source;
    reg [15:0] top;
    begin
        ldx_imm(8'h08);
        lda_abs(source);
        top = pc;
        sta_abs(16'h2007);
        emit(8'hCA);
        bne_to(top);
    end
endtask

task cmp_abs;
    input [15:0] address;
    begin
        emit(8'hCD);
        emit(address[7:0]);
        emit(address[15:8]);
    end
endtask

// W3 read-back.  Both loops below start with ONE priming read and that is not
// decoration.  ppu_xfer (reg_cs) is high only on the cycle that COMPLETES the
// two-cycle $2007 access, and read_buffer_reg is refilled on that same edge, so
// the byte the cpu latches on access N is the byte the port presented for
// access N-1 -- the real 2C02 read buffer.  One priming read is therefore
// exactly what puts the FIRST byte of a freshly addressed window in the cpu's
// hands, and the eight verified reads after it return base+0 .. base+7.
//
// ppu_read8 additionally parks the eight bytes in ram at store_base+1 .. +8.
// X counts 8..1, so STA abs,X walks the window DOWNWARDS and the first byte read
// lands in the highest cell: cell store_base+1 holds the byte at the window's
// base address, cell store_base+8 the last one.
task ppu_read8;
    input [15:0] store_base;
    reg [15:0] top;
    begin
        lda_abs(16'h2007);
        ldx_imm(8'h08);
        top = pc;
        lda_abs(16'h2007);
        sta_abs_x(store_base);
        emit(8'hCA);
        bne_to(top);
    end
endtask

// The compare loop.  The expected byte is a PRG DATA cell, addressed absolutely
// with CMP abs, so the instruction bytes are identical in both images and only
// the cell's CONTENTS differ.  The failure exit is BEQ over a three-byte JMP
// rather than a two-byte BNE because CHR_RB_FAIL is out of a branch's +-127
// range from the nmi handler: the shape is still "compare, branch to the fail
// loop if different, otherwise keep counting down", and the fail loop is
// reachable from every window.
task ppu_verify8;
    input [15:0] source;
    reg [15:0] top;
    begin
        lda_abs(16'h2007);
        ldx_imm(8'h08);
        top = pc;
        lda_abs(16'h2007);
        cmp_abs(source);
        beq_to(pc + 16'd5);
        jmp_abs(CHR_RB_FAIL);
        emit(8'hCA);
        bne_to(top);
    end
endtask

// v4's $2007 CHR tile writes ARE reproduced here, in the same order and the same
// addresses, which is what makes the A/B in P0-4 non-vacuous: ab_v6's external
// chr_mem starts at the SENTINEL (run B's image) and only these writes can put
// run A's image there, while ab_v5's internal chr_ram starts at the same
// sentinel and is filled by its own internal $2007 handler.  $2007 CHR writes
// were previously omitted because nes_ppu2c02's external branch dropped them;
// they are live now (chr_waddr/chr_we/chr_wdata), so the omission is gone.
task build_main;
    reg [15:0] self_loop;
    reg [15:0] copy_top;
    reg [15:0] loop1;
    reg [15:0] loop2;
    reg [15:0] tramp;
    reg [15:0] skip_op;
    begin
        image_is_mmc3 = 1'b0;
        pc = MAIN_PROG;
        emit(8'h58);
        lda_imm(8'h00);
        sta_abs(NMI_COUNTER_CELL);
        lda_imm(8'h00);
        sta_abs(IRQ_COUNTER_CELL);
        lda_imm(8'h00);
        sta_abs(DMA_FLAG_CELL);
        lda_imm(8'h00);
        sta_abs(OAM_RB_FLAG_CELL);
        lda_imm(8'h00);
        sta_abs(PORT1_9TH_CELL);
        lda_imm(8'h00);
        sta_abs(PORT2_9TH_CELL);

        lda_imm(8'h01);
        sta_abs(16'h4016);
        lda_imm(8'h00);
        sta_abs(16'h4016);
        ldx_imm(8'h00);
        loop1 = pc;
        lda_abs(16'h4016);
        sta_abs_x(PORT1_CELL_BASE);
        emit(8'hE8);
        emit(8'hE0);
        emit(8'h08);
        bne_to(loop1);
        lda_abs(16'h4016);
        sta_abs(PORT1_9TH_CELL);
        tramp = pc;
        emit(8'h4C);
        skip_op = pc;
        emit(8'h00);
        emit(8'h00);
        jmp_abs(FAIL1);
        jmp_patch(skip_op, pc);
        for (k = 0; k < 8; k = k + 1) begin
            lda_abs(PORT1_CELL_BASE + k[15:0]);
            cmp_imm(BUTTONS1[k]);
            bne_list_add;
        end
        lda_abs(PORT1_9TH_CELL);
        cmp_imm(8'h01);
        bne_list_add;
        bne_list_patch(tramp + 16'd3);
        k = 0;

        lda_imm(8'h01);
        sta_abs(16'h4016);
        lda_imm(8'h00);
        sta_abs(16'h4016);
        ldx_imm(8'h00);
        loop2 = pc;
        lda_abs(16'h4017);
        sta_abs_x(PORT2_CELL_BASE);
        emit(8'hE8);
        emit(8'hE0);
        emit(8'h08);
        bne_to(loop2);
        lda_abs(16'h4017);
        sta_abs(PORT2_9TH_CELL);
        tramp = pc;
        emit(8'h4C);
        skip_op = pc;
        emit(8'h00);
        emit(8'h00);
        jmp_abs(FAIL2);
        jmp_patch(skip_op, pc);
        for (k = 0; k < 8; k = k + 1) begin
            lda_abs(PORT2_CELL_BASE + k[15:0]);
            cmp_imm(BUTTONS2[k]);
            bne_list_add;
        end
        lda_abs(PORT2_9TH_CELL);
        cmp_imm(8'h01);
        bne_list_add;
        bne_list_patch(tramp + 16'd3);
        k = 0;

        // $4017 with bit 6 set inhibits the frame IRQ outright, which is what
        // P1-4 wants to observe.
        lda_imm(FRAME_IRQ_INHIBIT);
        sta_abs(16'h4017);
        lda_imm(8'h01);
        sta_abs(16'h4015);
        lda_imm(8'hBF);
        sta_abs(16'h4000);
        lda_imm(8'h00);
        sta_abs(16'h4001);
        lda_imm(8'h20);
        sta_abs(16'h4002);
        lda_imm(8'h40);
        sta_abs(16'h4003);

        lda_imm(8'h00);
        sta_abs(16'h2000);
        lda_imm(8'h00);
        sta_abs(16'h2001);

        ldx_imm(8'h00);
        copy_top = pc;
        lda_abs_x(TABLE1_ADDR);
        sta_abs_x(16'h0200);
        emit(8'hE8);
        bne_to(copy_top);

        // ---- the $2007 CHR upload, v4's exact address and byte order ----
        //
        // It has to be done TWICE.  PPUCTRL bit 4 is set, so the background
        // fetches at local $1000+off; nes_mapper_nrom.v:26 returns
        // ppu_addr[12:0] UNCHANGED, so bit 12 is a real address bit and
        // chr_mem[$1000+off] is a different cell from chr_mem[$0000+off].  The
        // sprite fetches at local $0020 because bit 5 of PPUCTRL is clear.  Both
        // halves are written by the program, so nothing the renderer reads comes
        // from the preload.
        ppu_set_addr(16'h0000);
        ppu_fill8_src(CHR_FILL_ON_ADDR);
        ppu_set_addr(16'h0008);
        ppu_fill8_src(CHR_FILL_OFF_ADDR);
        ppu_set_addr(16'h0010);
        ppu_fill8_src(CHR_FILL_OFF_ADDR);
        ppu_set_addr(16'h0018);
        ppu_fill8_src(CHR_FILL_ON_ADDR);
        ppu_set_addr(16'h0020);
        ppu_fill8_src(CHR_FILL_ON_ADDR);
        ppu_set_addr(16'h0028);
        ppu_fill8_src(CHR_FILL_OFF_ADDR);
        ppu_set_addr(16'h1000);
        ppu_fill8_src(CHR_FILL_ON_ADDR);
        ppu_set_addr(16'h1008);
        ppu_fill8_src(CHR_FILL_OFF_ADDR);
        ppu_set_addr(16'h1010);
        ppu_fill8_src(CHR_FILL_OFF_ADDR);
        ppu_set_addr(16'h1018);
        ppu_fill8_src(CHR_FILL_ON_ADDR);
        ppu_set_addr(16'h1020);
        ppu_fill8_src(CHR_FILL_ON_ADDR);
        ppu_set_addr(16'h1028);
        ppu_fill8_src(CHR_FILL_OFF_ADDR);

        // ---- W3 loop A: the $2007 CHR READ half, with PPUMASK still $00 ----
        //
        // Nothing is displayed, so a fetch byte the read arm displaces cannot
        // reach a pixel, which is what makes this the safe place for the first
        // read loop.  $0000..$0007 are the eight bytes the first fill above
        // stored, so this reads back the program's own write through the
        // external CHR bus.  ppu_read8 parks the bytes in ram[$0031..$0038] and
        // ppu_verify8 compares the same eight against $8A02.
        ppu_set_addr(CHR_RB_LOOP_A_ADDR);
        ppu_read8(CHR_RB_STORE_A);
        ppu_set_addr(CHR_RB_LOOP_A_ADDR);
        ppu_verify8(CHR_RB_EXP_ON_ADDR);

        lda_imm(8'h01);
        sta_abs(CHR_UPLOAD_FLAG_CELL);

        ppu_set_addr(16'h2001);
        ppu_write_data(8'h01);
        ppu_set_addr(16'h3F00);
        ppu_write_data(8'h0F);
        ppu_write_data(8'h21);
        ppu_write_data(8'h32);
        ppu_set_addr(16'h3F11);
        ppu_write_data(8'h16);
        ppu_set_addr(16'h0000);

        lda_imm(8'h00);
        sta_abs(16'h2003);
        lda_imm(8'h02);
        sta_abs(16'h4014);
        lda_imm(8'h01);
        sta_abs(DMA_FLAG_CELL);
        tramp = pc;
        emit(8'h4C);
        skip_op = pc;
        emit(8'h00);
        emit(8'h00);
        jmp_abs(FAIL3);
        jmp_patch(skip_op, pc);
        lda_abs(16'h2004);
        cmp_imm(OAM_RB_EXPECT);
        bne_list_add;
        bne_list_patch(tramp + 16'd3);
        lda_imm(8'h01);
        sta_abs(OAM_RB_FLAG_CELL);

        // Three cart writes so P0-2's mapper_write_pulse model has something
        // to predict.  They address PRG addresses the program never executes.
        lda_imm(8'h5A);
        sta_abs(16'hA000);
        lda_imm(8'hA5);
        sta_abs(16'hB123);
        lda_imm(8'h3C);
        sta_abs(16'hFFC0);

        // PPUCTRL bit 4 selects the $1000 BG pattern table, so a nonzero
        // pattern-table select crosses the mapper on every background fetch.
        // The CHR preload mirrors the image so the visible result is unchanged.
        lda_imm(PPUMASK_FINAL);
        sta_abs(16'h2001);
        lda_imm(PPUCTRL_FINAL);
        sta_abs(16'h2000);
        self_loop = pc;
        self_loop_addr = self_loop;
        jmp_abs(self_loop);
        main_prog_end = pc;
    end
endtask

task build_nmi_handler;
    begin
        pc = NMI_HANDLER;
        lda_abs(NMI_COUNTER_CELL);
        emit(8'h18);
        emit(8'h69);
        emit(8'h01);
        sta_abs(NMI_COUNTER_CELL);

        // ---- W3 loop B: the same read-back with RENDERING ON ----
        //
        // NMI fires at scanline 241, dot 0, which is inside the provably
        // invisible set, and the four windows below are sized to finish around
        // scanline 250.  If that ever stops being true W3-10 kills the run on
        // the arm beat rather than letting it corrupt a visible line.
        //
        //   $1020  written by the upload with the ON constant   -> $8A02
        //   $1028  written by the upload with the OFF constant  -> $8A03
        //   $1040  NEVER written by anything                     -> $8A04
        //
        // $1040 is inside the reachable pattern table and past every address
        // the upload touches (0..47 and 4096..4143), so the only thing that can
        // ever be there is the tb's own load value.  It is the address that
        // makes "always returns the last byte written" observable.
        //
        // The trailing ppu_set_addr is not optional.  $2006 writes temp_addr as
        // well as v_addr, and nes_ppu2c02 derives the background pattern address
        // from temp_addr (bg_coarse_x_sum, bg_y_total, bg_nametable), so leaving
        // t at $1040 would move the picture on the next frame and break P0-4 and
        // P0-5 for a reason that has nothing to do with the read path.
        ppu_set_addr(CHR_RB_LOOP_B_ON);
        ppu_read8(CHR_RB_STORE_BON);
        ppu_set_addr(CHR_RB_LOOP_B_ON);
        ppu_verify8(CHR_RB_EXP_ON_ADDR);
        ppu_set_addr(CHR_RB_LOOP_B_OFF);
        ppu_read8(CHR_RB_STORE_BOFF);
        ppu_set_addr(CHR_RB_LOOP_B_OFF);
        ppu_verify8(CHR_RB_EXP_OFF_ADDR);
        ppu_set_addr(CHR_RB_LOOP_B_UNW);
        ppu_read8(CHR_RB_STORE_BUNW);
        ppu_set_addr(CHR_RB_LOOP_B_UNW);
        ppu_verify8(CHR_RB_EXP_UNW_ADDR);
        ppu_set_addr(16'h0000);

        emit(8'h40);
        nmi_end = pc;
    end
endtask

task build_irq_handler;
    begin
        pc = IRQ_HANDLER;
        lda_abs(16'h4015);
        sta_abs(16'h4015);
        lda_abs(IRQ_COUNTER_CELL);
        emit(8'h18);
        emit(8'h69);
        emit(8'h01);
        sta_abs(IRQ_COUNTER_CELL);
        emit(8'h40);
        irq_end = pc;
    end
endtask

task build_fail_blocks;
    begin
        pc = FAIL1;
        jmp_abs(FAIL1);
        pc = FAIL2;
        jmp_abs(FAIL2);
        pc = FAIL3;
        jmp_abs(FAIL3);
        pc = CHR_RB_FAIL;
        jmp_abs(CHR_RB_FAIL);
    end
endtask

task build_vectors;
    begin
        put(16'hFFFA, NMI_HANDLER[7:0]);
        put(16'hFFFB, NMI_HANDLER[15:8]);
        put(16'hFFFC, MAIN_PROG[7:0]);
        put(16'hFFFD, MAIN_PROG[15:8]);
        put(16'hFFFE, IRQ_HANDLER[7:0]);
        put(16'hFFFF, IRQ_HANDLER[15:8]);
    end
endtask

// OAM page 2 source image.  Entry 0 carries the 11 22 33 44 pattern that P1-2
// checks, entry 1 is the visible sprite at y=32 / x=8 with tile 2 so the
// index-6 pixel class still lands on lines 32-39, columns 8-15.
task build_tables;
    begin
        table1[0] = 8'h11;
        table1[1] = 8'h22;
        table1[2] = 8'h33;
        table1[3] = 8'h44;
        table1[4] = 8'h20;
        table1[5] = 8'h02;
        table1[6] = 8'h00;
        table1[7] = 8'h08;
        for (k = 8; k < 256; k = k + 1)
            table1[k] = 8'hFF;
        for (k = 0; k < 256; k = k + 1)
            put(TABLE1_ADDR + k[15:0], table1[k]);
        // Run A's CHR fill constants.  These two cells are the ONLY difference
        // between the two program images, so chr_ram_b executes identical code.
        put(CHR_FILL_ON_ADDR, CHR_FILL_RUN_A_ON);
        put(CHR_FILL_OFF_ADDR, CHR_FILL_RUN_A_OFF);
        // W3's read-back expectations.  Deliberately their OWN cells, holding
        // the same two values: the fill loop reads $8A00/$8A01 and the verify
        // loop reads $8A02/$8A03, so a fill that stored the wrong byte is caught
        // instead of being compared against itself.  $8A04 is the tb's load
        // value for an address nothing ever writes, and it is the same in both
        // images because every model holds $00 there.
        put(CHR_RB_EXP_ON_ADDR, CHR_FILL_RUN_A_ON);
        put(CHR_RB_EXP_OFF_ADDR, CHR_FILL_RUN_A_OFF);
        put(CHR_RB_EXP_UNW_ADDR, CHR_RB_UNWRITTEN_EXPECT);
        for (k = 0; k < 8; k = k + 1) begin
            ctrl_rd_exp[k] = BUTTONS1[k];
            ctrl_rd_exp[9 + k] = BUTTONS2[k];
        end
        ctrl_rd_exp[8] = 8'h01;
        ctrl_rd_exp[CTRL_READS-1] = 8'h01;
    end
endtask

// The v4 internal CHR image, byte for byte: [0:7]=FF [8:15]=00 [16:23]=00
// [24:31]=FF [32:39]=FF [40:47]=00.  That is run A's image and it is what P0-5's
// named pixel classes were derived from, so ab_v6 has to end up holding exactly
// it.
task build_chr_image;
    begin
        for (k = 0; k < 8; k = k + 1) begin
            chr_tile_image[0 + k] = 8'hFF;
            chr_tile_image[8 + k] = 8'h00;
            chr_tile_image[16 + k] = 8'h00;
            chr_tile_image[24 + k] = 8'hFF;
            chr_tile_image[32 + k] = 8'hFF;
            chr_tile_image[40 + k] = 8'h00;
            // Run B's image is its exact complement, so it differs on all 48
            // bytes and can serve as run A's sentinel and vice versa.
            chr_tile_image_b[0 + k] = 8'h00;
            chr_tile_image_b[8 + k] = 8'hFF;
            chr_tile_image_b[16 + k] = 8'hFF;
            chr_tile_image_b[24 + k] = 8'h00;
            chr_tile_image_b[32 + k] = 8'h00;
            chr_tile_image_b[40 + k] = 8'hFF;
        end
    end
endtask

// ab_v6 (NROM_CHR_RAM=1) and ab_v5 get the SENTINEL, which is run B's image.
// That is the whole point: the rendered image has to arrive through the
// program's own $2007 writes, not through the preload.
//
// Where the image has to sit differs per board, and that difference is the point
// of the check rather than a nuisance:
//
//   ab_v6  external CHR, 128 KiB model.  nes_mapper_nrom.v:26 returns
//          ppu_addr[12:0] unchanged, so bit 12 is a REAL address bit: with
//          PPUCTRL[4]=1 the background reads chr_mem[$1000+off] and with
//          PPUCTRL[5]=0 the sprite reads chr_mem[$0020+off].  The program
//          writes both halves, so both end at run A.
//   ab_v5  internal CHR.  bg_pattern_addr carries the table select too, so the
//          background reads chr_ram[$1000+off] and the sprite chr_ram[$0020+off],
//          i.e. exactly the same two cells.  Its $2007 handler writes
//          chr_ram[v_addr[12:0]], so a write to $1000 lands on $0000 as well;
//          the program writes both halves anyway and both land correctly.
//
// The sentinel therefore goes at bytes 0..47 of EVERY 4 KiB block in both
// arrays, which covers $0000 and $1000 and costs nothing.  Bytes $2000+ are
// never addressed (chr_final_addr tops out at 0x1FFF) and stay at the sentinel
// as the untouched-address control.
task load_chr;
    integer m;
    integer b;
    begin
        for (m = 0; m < CHR_MEM_BYTES; m = m + 1)
            chr_mem[m] = 8'h00;
        for (m = 0; m < (CHR_MEM_BYTES / 4096); m = m + 1)
            for (b = 0; b < CHR_TILE_BYTES; b = b + 1)
                chr_mem[m * 4096 + b] = chr_tile_image_b[b];
        for (b = 0; b < 8192; b = b + 1)
            ab_v5.u_ppu.chr_ram[b] = 8'h00;
        for (m = 0; m < 2; m = m + 1)
            for (b = 0; b < CHR_TILE_BYTES; b = b + 1)
                ab_v5.u_ppu.chr_ram[m * 4096 + b] = chr_tile_image_b[b];
    end
endtask

// chr_rom is the CHR-ROM board.  Its ROM image already holds exactly the bytes
// the program tries to write (checked byte for byte by W1), so a cartridge built
// this way needs no upload at all, and rom_chr_pre is a byte-for-byte snapshot of
// that image so "the memory never changed" is a measured comparison.
task load_chr_rom;
    integer m;
    integer b;
    begin
        for (m = 0; m < CHR_MEM_BYTES; m = m + 1) begin
            rom_chr_mem[m] = 8'h00;
            rom_chr_pre[m] = 8'h00;
        end
        for (m = 0; m < (CHR_MEM_BYTES / 4096); m = m + 1)
            for (b = 0; b < CHR_TILE_BYTES; b = b + 1) begin
                rom_chr_mem[m * 4096 + b] = chr_tile_image[b];
                rom_chr_pre[m * 4096 + b] = chr_tile_image[b];
            end
    end
endtask

// chr_ram_b is ab_v6 with run B's program: sentinel here is run A's image and
// the program stores run B's complement into it.
task load_chr_ram_b;
    integer m;
    integer b;
    begin
        for (m = 0; m < CHR_MEM_BYTES; m = m + 1)
            ramb_chr_mem[m] = 8'h00;
        for (m = 0; m < (CHR_MEM_BYTES / 4096); m = m + 1)
            for (b = 0; b < CHR_TILE_BYTES; b = b + 1)
                ramb_chr_mem[m * 4096 + b] = chr_tile_image[b];
    end
endtask

// ===================================================================
// phase 2: the chr_mmc3 image, its bank-switch program and its CHR model
// ===================================================================
//
// Same shape as the phase 1 program: same reset vectors, same fail-loop idea,
// same nametable / palette / OAM-DMA setup, same self loop at the end.  Three
// things differ and every one of them is forced by the specification:
//
//  1. No $A000 / $B123 / $FFC0 dummy cart writes.  On MMC3 those addresses are
//     the $A000 mirroring register and the $E000 IRQ disable, not the NROM
//     no-ops P0-2 counts.  Writing them would silently change what P1-5 is
//     measuring.
//  2. PPUCTRL is $00, written once and never touched again.  bit 4 and bit 5
//     are the pattern-table selects and both are 0, so local chr_addr[12] is 0
//     and every background and sprite beat lands in the MMC3 R0 1 KiB window.
//     bit 7 is 0, so no NMI can preempt the forced IRQ entry P1-5 measures.
//     "keep that value constant across the bank-switch steps" is therefore
//     satisfied by construction.
//  3. A vblank wait before each $8001 write.  The loop is
//         LDA $2002 / AND #$80 / BEQ loop
//     and the PPU clears its vblank latch on the $2002 read, so the loop exits
//     on the first read that sees the flag and stays put until the next frame.
//     The writes land at vblank dots ~10-25, i.e. before dot 257, so they can
//     never interrupt the 35-ce sprite shadow build that starts at dot 257.

task build_mmc3_main;
    reg [15:0] self_loop;
    reg [15:0] copy_top;
    reg [15:0] loop1;
    reg [15:0] loop2;
    reg [15:0] tramp;
    reg [15:0] skip_op;
    reg [15:0] wait_vb;
    begin
        image_is_mmc3 = 1'b1;
        pc = MAIN_PROG;
        emit(8'h58);
        lda_imm(8'h00);
        sta_abs(NMI_COUNTER_CELL);
        lda_imm(8'h00);
        sta_abs(IRQ_COUNTER_CELL);
        lda_imm(8'h00);
        sta_abs(MMC3_IRQ_CELL);
        lda_imm(8'h00);
        sta_abs(OAM_RB_FLAG_CELL);
        lda_imm(8'h00);
        sta_abs(PORT1_9TH_CELL);
        lda_imm(8'h00);
        sta_abs(PORT2_9TH_CELL);

        lda_imm(8'h01);
        sta_abs(16'h4016);
        lda_imm(8'h00);
        sta_abs(16'h4016);
        ldx_imm(8'h00);
        loop1 = pc;
        lda_abs(16'h4016);
        sta_abs_x(PORT1_CELL_BASE);
        emit(8'hE8);
        emit(8'hE0);
        emit(8'h08);
        bne_to(loop1);
        lda_abs(16'h4016);
        sta_abs(PORT1_9TH_CELL);
        tramp = pc;
        emit(8'h4C);
        skip_op = pc;
        emit(8'h00);
        emit(8'h00);
        jmp_abs(MMC3_FAIL);
        jmp_patch(skip_op, pc);
        for (k = 0; k < 8; k = k + 1) begin
            lda_abs(PORT1_CELL_BASE + k[15:0]);
            cmp_imm(BUTTONS1[k]);
            bne_list_add;
        end
        lda_abs(PORT1_9TH_CELL);
        cmp_imm(8'h01);
        bne_list_add;
        bne_list_patch(tramp + 16'd3);
        k = 0;

        lda_imm(8'h01);
        sta_abs(16'h4016);
        lda_imm(8'h00);
        sta_abs(16'h4016);
        ldx_imm(8'h00);
        loop2 = pc;
        lda_abs(16'h4017);
        sta_abs_x(PORT2_CELL_BASE);
        emit(8'hE8);
        emit(8'hE0);
        emit(8'h08);
        bne_to(loop2);
        lda_abs(16'h4017);
        sta_abs(PORT2_9TH_CELL);
        tramp = pc;
        emit(8'h4C);
        skip_op = pc;
        emit(8'h00);
        emit(8'h00);
        jmp_abs(MMC3_FAIL);
        jmp_patch(skip_op, pc);
        for (k = 0; k < 8; k = k + 1) begin
            lda_abs(PORT2_CELL_BASE + k[15:0]);
            cmp_imm(BUTTONS2[k]);
            bne_list_add;
        end
        lda_abs(PORT2_9TH_CELL);
        cmp_imm(8'h01);
        bne_list_add;
        bne_list_patch(tramp + 16'd3);
        k = 0;

        lda_imm(FRAME_IRQ_INHIBIT);
        sta_abs(16'h4017);
        lda_imm(8'h01);
        sta_abs(16'h4015);
        lda_imm(8'hBF);
        sta_abs(16'h4000);
        lda_imm(8'h00);
        sta_abs(16'h4001);
        lda_imm(8'h20);
        sta_abs(16'h4002);
        lda_imm(8'h40);
        sta_abs(16'h4003);

        lda_imm(8'h00);
        sta_abs(16'h2000);
        lda_imm(8'h00);
        sta_abs(16'h2001);

        ldx_imm(8'h00);
        copy_top = pc;
        lda_abs_x(TABLE1_ADDR);
        sta_abs_x(16'h0200);
        emit(8'hE8);
        bne_to(copy_top);

        ppu_set_addr(16'h2001);
        ppu_write_data(8'h01);
        ppu_set_addr(16'h3F00);
        ppu_write_data(8'h0F);
        ppu_write_data(8'h21);
        ppu_write_data(8'h32);
        ppu_write_data(8'h18);
        ppu_set_addr(16'h3F11);
        ppu_write_data(8'h16);
        ppu_set_addr(16'h0000);

        lda_imm(8'h00);
        sta_abs(16'h2003);
        lda_imm(8'h02);
        sta_abs(16'h4014);
        lda_imm(8'h01);
        sta_abs(OAM_RB_FLAG_CELL);
        tramp = pc;
        emit(8'h4C);
        skip_op = pc;
        emit(8'h00);
        emit(8'h00);
        jmp_abs(MMC3_FAIL);
        jmp_patch(skip_op, pc);
        lda_abs(16'h2004);
        cmp_imm(MMC3_OAM_RB_EXPECT);
        bne_list_add;
        bne_list_patch(tramp + 16'd3);
        lda_imm(8'h01);
        sta_abs(OAM_RB_FLAG_CELL);

        lda_imm(PPUMASK_FINAL);
        sta_abs(16'h2001);
        lda_imm(MMC3_PPUCTRL);
        sta_abs(16'h2000);

        // ---- vblank bank switch 1: R0 = 0
        wait_vb = pc;
        lda_abs(16'h2002);
        and_imm(8'h80);
        beq_to(wait_vb);
        lda_imm(MMC3_BANK_R0);
        sta_abs(16'h8001);
        // ---- vblank bank switch 2: R0 = 1
        wait_vb = pc;
        lda_abs(16'h2002);
        and_imm(8'h80);
        beq_to(wait_vb);
        lda_imm(MMC3_BANK_R1);
        sta_abs(16'h8001);
        // ---- vblank bank switch 3: R0 = 0x41
        wait_vb = pc;
        lda_abs(16'h2002);
        and_imm(8'h80);
        beq_to(wait_vb);
        lda_imm(MMC3_BANK_R2);
        sta_abs(16'h8001);

        // $C000 latches the reload value, $C001 arms reload, $E001 enables and
        // $E000 disables and acknowledges.  mapper_ppu_a12 is tied 0 inside
        // nes_system_v6, so the counter never clocks and irq never rises on its
        // own; P1-5 checks exactly that and then forces the source.
        lda_imm(MMC3_IRQ_LATCH_VALUE);
        sta_abs(16'hC000);
        lda_imm(8'h00);
        sta_abs(16'hC001);
        lda_imm(8'h00);
        sta_abs(16'hE001);
        lda_imm(8'h00);
        sta_abs(16'hE000);

        // ---- W2: prove a $2007 CHR write is bank-qualified by the mapper ----
        //
        // Step 4 returns r0 to $00 and writes one byte at local $0040, which is
        // in window 0, so the byte has to land at (reg $00 << 10) | 0x040.
        // Step 5 moves r0 to $42 -> reg {0x42[7:1],1'b0} = $42 and writes the
        // SAME local address again; if the store went to a flat local RAM the
        // second write would overwrite the first, so landing at a different cell
        // is the proof.  A third write at local $0440 raises local bit 11, which
        // is the odd/even 1 KiB sub-select inside r0's 2 KiB, so it has to land
        // at ({reg[7:1],1'b1} << 10) | 0x040 and not in r0's own even half.
        wait_vb = pc;
        lda_abs(16'h2002);
        and_imm(8'h80);
        beq_to(wait_vb);
        lda_imm(MMC3_W2_R0_LOW);
        sta_abs(16'h8001);
        ppu_set_addr(MMC3_W2_ADDR_LOW);
        ppu_write_data(MMC3_W2_BYTE_LOW);

        wait_vb = pc;
        lda_abs(16'h2002);
        and_imm(8'h80);
        beq_to(wait_vb);
        lda_imm(MMC3_W2_R0_HIGH);
        sta_abs(16'h8001);
        ppu_set_addr(MMC3_W2_ADDR_LOW);
        ppu_write_data(MMC3_W2_BYTE_HIGH);
        ppu_set_addr(MMC3_W2_ADDR_ODD);
        ppu_write_data(MMC3_W2_BYTE_ODD);

        self_loop = pc;
        m_self_loop_addr = self_loop;
        jmp_abs(self_loop);
        m_main_prog_end = pc;
        image_is_mmc3 = 1'b0;
    end
endtask

task build_mmc3_nmi_handler;
    begin
        image_is_mmc3 = 1'b1;
        pc = NMI_HANDLER;
        lda_abs(NMI_COUNTER_CELL);
        emit(8'h18);
        emit(8'h69);
        emit(8'h01);
        sta_abs(NMI_COUNTER_CELL);
        emit(8'h40);
        m_nmi_end = pc;
        image_is_mmc3 = 1'b0;
    end
endtask

// The handler increments ram[0013] and nothing else, so P1-5 can say "the
// handler ran" from one byte with no other writer in the image.
task build_mmc3_irq_handler;
    begin
        image_is_mmc3 = 1'b1;
        pc = IRQ_HANDLER;
        lda_abs(MMC3_IRQ_CELL);
        emit(8'h18);
        emit(8'h69);
        emit(8'h01);
        sta_abs(MMC3_IRQ_CELL);
        emit(8'h40);
        m_irq_end = pc;
        image_is_mmc3 = 1'b0;
    end
endtask

task build_mmc3_fail_blocks;
    begin
        image_is_mmc3 = 1'b1;
        pc = MMC3_FAIL;
        jmp_abs(MMC3_FAIL);
        image_is_mmc3 = 1'b0;
    end
endtask

task build_mmc3_vectors;
    begin
        image_is_mmc3 = 1'b1;
        put(16'hFFFA, NMI_HANDLER[7:0]);
        put(16'hFFFB, NMI_HANDLER[15:8]);
        put(16'hFFFC, MAIN_PROG[7:0]);
        put(16'hFFFD, MAIN_PROG[15:8]);
        put(16'hFFFE, IRQ_HANDLER[7:0]);
        put(16'hFFFF, IRQ_HANDLER[15:8]);
        image_is_mmc3 = 1'b0;
    end
endtask

// OAM page 2 source image for chr_mmc3.  Every one of the 64 entries is
// {y=$F0, tile=$02, attr=$00, x=$00}:
//
//  * y=$F0 = 240 puts every entry in range only for scanlines 240..247, which
//    are outside pixel_valid (scanline < 240), so nothing ever renders inside
//    the tile-0 region P0-7(b) samples.
//  * tile=$02 keeps tile index bit 7 clear for EVERY slot the fetcher can
//    select.  That matters because the P0-7 translation model is specified as
//    (bank << 10) | (local & 14'h03FF), which drops local bit 11 -- and on this
//    rtl local bit 11 IS tile index bit 7, because the pattern-table select is
//    local bit 12 and MMC3 turns bits 12/11 into its 1 KiB window index.  A
//    tile index >= 128 routes its 16 sprite beats through window index 1 or 3
//    (the R1 register, never written) and the specified model could not hold.
//    The phase 1 OAM image is 0xFF-filled from entry 2 on, and y=$FF is in
//    range for scanline_next 255..261, so those slots do select tile $FF.
//  * the readback tripwire is oam_ram[0] = y = $F0.
task build_mmc3_tables;
    integer n;
    begin
        image_is_mmc3 = 1'b1;
        for (n = 0; n < 64; n = n + 1) begin
            m_table1[n * 4 + 0] = MMC3_OAM_Y;
            m_table1[n * 4 + 1] = MMC3_OAM_TILE;
            m_table1[n * 4 + 2] = 8'h00;
            m_table1[n * 4 + 3] = 8'h00;
        end
        for (n = 0; n < 256; n = n + 1)
            put(TABLE1_ADDR + n[15:0], m_table1[n]);
        image_is_mmc3 = 1'b0;
    end
endtask

// The three 1 KiB bank images.  MMC3 R0 is a 2 KiB register, so the register
// value is {data[7:1],1'b0} and the byte base is register << 10:
//
//   data $00 -> reg $00 -> 1 KiB at 0x0000   the v4 image, byte for byte
//   data $01 -> reg $00 -> 1 KiB at 0x0000   IDENTICAL to the line above
//   data $41 -> reg $40 -> 1 KiB at 0x10000
//
// The middle line is the point P0-7 has to be honest about: a 1 KiB-granular
// R0 register has no bit 0, so writing $01 cannot move the window and cannot
// change a single arriving byte.  The preload still carries three pairwise
// different images so that the 0x41 step is provably observable, and
// check_p0_7 asserts the three 48-byte images are pairwise distinct so the
// "the picture changed" claim can never be satisfied by three identical banks.
//
// Tile 0 (bytes 0..15) is what the tile-0 region of the screen is made of:
//
//   reg $00  plane0 $FF / plane1 $00 -> pattern value 1 -> $3F01 = $21 -> index 1
//   reg $40  plane0 $FF / plane1 $FF -> pattern value 3 -> $3F03 = $18 -> index 8
//
// ($3F03 is written only by the chr_mmc3 program; the phase 1 program leaves it
// 0 and never needs it because its image only produces values 1 and 2.)
task load_chr_mmc3;
    integer m;
    integer b;
    begin
        for (m = 0; m < CHR_MEM_BYTES; m = m + 1)
            m_chr_mem[m] = 8'h00;
        for (b = 0; b < 8; b = b + 1) begin
            m_chr_mem[MMC3_IMG_BASE_REG0 + 0 + b] = 8'hFF;
            m_chr_mem[MMC3_IMG_BASE_REG0 + 8 + b] = 8'h00;
            m_chr_mem[MMC3_IMG_BASE_REG0 + 16 + b] = 8'h00;
            m_chr_mem[MMC3_IMG_BASE_REG0 + 24 + b] = 8'hFF;
            m_chr_mem[MMC3_IMG_BASE_REG0 + 32 + b] = 8'hFF;
            m_chr_mem[MMC3_IMG_BASE_REG0 + 40 + b] = 8'h00;

            m_chr_mem[MMC3_IMG_BASE_REG1 + 0 + b] = 8'hFF;
            m_chr_mem[MMC3_IMG_BASE_REG1 + 8 + b] = 8'h3C;
            m_chr_mem[MMC3_IMG_BASE_REG1 + 16 + b] = 8'h81;
            m_chr_mem[MMC3_IMG_BASE_REG1 + 24 + b] = 8'h18;
            m_chr_mem[MMC3_IMG_BASE_REG1 + 32 + b] = 8'h66;
            m_chr_mem[MMC3_IMG_BASE_REG1 + 40 + b] = 8'h99;

            m_chr_mem[MMC3_IMG_BASE_REG2 + 0 + b] = 8'hFF;
            m_chr_mem[MMC3_IMG_BASE_REG2 + 8 + b] = 8'hFF;
            m_chr_mem[MMC3_IMG_BASE_REG2 + 16 + b] = 8'h0F;
            m_chr_mem[MMC3_IMG_BASE_REG2 + 24 + b] = 8'hF0;
            m_chr_mem[MMC3_IMG_BASE_REG2 + 32 + b] = 8'h55;
            m_chr_mem[MMC3_IMG_BASE_REG2 + 40 + b] = 8'hAA;
        end
        // W2 control cell.  It sits one byte above the $0040 write target inside
        // the same 1 KiB window, so it proves the store was a single-cell write
        // at a mapper-translated address and not a bulk or misaligned one.  It
        // is outside the 48-byte images P0-7 compares and outside the tile-0
        // region P0-7 samples (columns 0..7), so neither check is disturbed.
        m_chr_mem[MMC3_W2_CANARY_OFF] = MMC3_W2_CANARY;
        // The fourth 1 KiB image.  Step 5 moves r0 to $42 -> reg $42, whose
        // window is at 0x10800, which no earlier step reaches, so it needs its
        // own preloaded tile-0 or the named index for that step would be a
        // measurement of an empty bank.  It is byte-for-byte the reg $40 image
        // (plane0=$FF/plane1=$FF -> pattern 3 -> $3F03=$18 -> index 8), so the
        // rule P0-7(b) states still applies unchanged.  It is outside the four
        // images P0-7 compares pairwise and outside all three W2 write targets.
        for (b = 0; b < 8; b = b + 1) begin
            m_chr_mem[MMC3_W2_IMG_BASE + 0 + b] = 8'hFF;
            m_chr_mem[MMC3_W2_IMG_BASE + 8 + b] = 8'hFF;
            m_chr_mem[MMC3_W2_IMG_BASE + 16 + b] = 8'hFF;
            m_chr_mem[MMC3_W2_IMG_BASE + 24 + b] = 8'hFF;
            m_chr_mem[MMC3_W2_IMG_BASE + 32 + b] = 8'hFF;
            m_chr_mem[MMC3_W2_IMG_BASE + 40 + b] = 8'hFF;
        end
    end
endtask

// W2 write-beat window decode, built only from the tb's own r0 register model.
// nes_mapper_mmc3.v:110-135 does exactly this: ppu_addr[12] picks the half,
// ppu_addr[11] is the odd/even 1 KiB sub-select, and window 1 is
// {chr_bank0_r[7:1],1'b1}, i.e. the odd 1 KiB of the SAME 2 KiB r0.  chr_inversion
// is 0 because this program never writes $8000.  ppu_addr[12] set would select
// windows 4..7 (r2..r5), which this program never does, so the function returns
// a sentinel instead of a guess and the comparison fatals with the real address.
function [8:0] chr_mmc3_window_bank;
    input [13:0] loc;
    input [7:0] reg0;
    begin
        if (loc[12] === 1'b0) begin
            if (loc[11] === 1'b0)
                chr_mmc3_window_bank = {1'b0, reg0};
            else
                chr_mmc3_window_bank = {1'b0, reg0[7:1], 1'b1};
        end else begin
            chr_mmc3_window_bank = 9'h1FF;
        end
    end
endfunction

function [3:0] expected_pixel_index;
    input [8:0] line;
    input [8:0] column;
    begin
        if ((line >= 9'd32) && (line <= 9'd39) &&
            (column >= 9'd8) && (column <= 9'd15))
            expected_pixel_index = 4'd6;
        else if ((line < 9'd8) && (column >= 9'd8) && (column <= 9'd15))
            expected_pixel_index = 4'd2;
        else
            expected_pixel_index = 4'd1;
    end
endfunction

// ------------------------------------------------------------------- DUTs

nes_system_v6 #(
    .PRG_SIZE_BYTES(DUT_PRG_SIZE_BYTES),
    .NROM_PRG_SIZE_BYTES(DUT_NROM_PRG_SIZE_BYTES),
    .MAPPER_SELECT(DUT_MAPPER_SELECT),
    .HEADER_MIRRORING(DUT_HEADER_MIRRORING),
    .NROM_CHR_RAM(1'b1)
) ab_v6 (
    .clk(clk),
    .reset(reset),
    .buttons1(buttons1),
    .buttons2(buttons2),
    .chr_rdata(chr_rdata),
    .pixel_valid(v6_pixel_valid),
    .pixel_x(v6_pixel_x),
    .pixel_y(v6_pixel_y),
    .pixel_index(v6_pixel_index),
    .frame_done(v6_frame_done),
    .vblank(v6_vblank),
    .nmi_o(v6_nmi_o),
    .apu_irq_o(v6_apu_irq_o),
    .audio_sample_valid(v6_audio_sample_valid),
    .audio_sample_left(v6_audio_sample_left),
    .audio_sample_right(v6_audio_sample_right),
    .cpu_cycle(v6_cpu_cycle),
    .ppu_dot(v6_ppu_dot),
    .ppu_scanline(v6_ppu_scanline),
    .bus_owner(v6_bus_owner),
    .bus_active(v6_bus_active),
    .bus_wait_count(v6_bus_wait_count),
    .bus_req(v6_bus_req),
    .bus_stall(v6_bus_stall),
    .bus_fire(v6_bus_fire),
    .bus_addr(v6_bus_addr),
    .bus_we(v6_bus_we),
    .bus_dout(v6_bus_dout),
    .bus_din(v6_bus_din),
    .sel_ram(v6_sel_ram),
    .sel_ppu(v6_sel_ppu),
    .sel_apu_io(v6_sel_apu_io),
    .sel_open_bus(v6_sel_open_bus),
    .sel_cart_ram(v6_sel_cart_ram),
    .sel_cart_rom(v6_sel_cart_rom),
    .ram_we(v6_ram_we),
    .ppu_reg_cs(v6_ppu_reg_cs),
    .ppu_reg_we(v6_ppu_reg_we),
    .ppu_reg_addr(v6_ppu_reg_addr),
    .apu_reg_cs(v6_apu_reg_cs),
    .apu_reg_we(v6_apu_reg_we),
    .apu_reg_addr(v6_apu_reg_addr),
    .controller_data(v6_controller_data),
    .cart_req(v6_cart_req),
    .cart_xfer(v6_cart_xfer),
    .cart_addr(v6_cart_addr),
    .cart_din(v6_cart_din),
    .cart_ack(v6_cart_ack),
    .bus_hold(v6_bus_hold),
    .oam_dma_start(v6_oam_dma_start),
    .oam_dma_cpu_hold(v6_oam_dma_cpu_hold),
    .oam_dma_cpu_read_req(),
    .oam_dma_cpu_read_addr(v6_oam_dma_cpu_read_addr),
    .oam_dma_cpu_read_ack(v6_oam_dma_cpu_read_ack),
    .oam_dma_cpu_rdata(v6_oam_dma_cpu_rdata),
    .oam_dma_ppu_reg_cs(v6_oam_dma_ppu_reg_cs),
    .oam_dma_ppu_reg_we(v6_oam_dma_ppu_reg_we),
    .oam_dma_ppu_reg_addr(v6_oam_dma_ppu_reg_addr),
    .oam_dma_ppu_reg_dout(v6_oam_dma_ppu_reg_dout),
    .oam_dma_busy(v6_oam_dma_busy),
    .oam_dma_done(v6_oam_dma_done),
    .oam_dma_page(v6_oam_dma_page),
    .oam_dma_page_latch(),
    .oam_dma_base_addr(v6_oam_dma_base_addr),
    .oam_dma_cur_addr(),
    .oam_dma_index(v6_oam_dma_index),
    .oam_dma_align_left(),
    .oam_dma_addr_wr(),
    .oam_dma_cycle_count(),
    .apu_dmc_bus_req(v6_apu_dmc_bus_req),
    .apu_dmc_addr(),
    .apu_dmc_ack(),
    .apu_dmc_rdata(),
    .dma_sel(v6_dma_sel),
    .dma_ack(v6_dma_ack),
    .dma_din(v6_dma_din),
    .dma_wait(),
    .dma_active(),
    .dma_unimpl(v6_dma_unimpl),
    .dma_owner(),
    .ppu_port_cs(v6_ppu_port_cs),
    .ppu_port_we(v6_ppu_port_we),
    .ppu_port_addr(v6_ppu_port_addr),
    .ppu_port_din(v6_ppu_port_din),
    .mapper_id(v6_mapper_id),
    .mapper_prg_bank_offset(v6_mapper_prg_bank_offset),
    .mapper_chr_bank_offset(v6_mapper_chr_bank_offset),
    .mapper_mirroring(v6_mapper_mirroring),
    .mapper_nametable_map(v6_mapper_nametable_map),
    .mapper_prg_bank_number(),
    .mapper_prg_ram_enable(),
    .mapper_prg_ram_we(),
    .mapper_chr_ram_enable(),
    .mapper_chr_ram_we(v6_mapper_chr_ram_we),
    .mapper_bus_conflict(),
    .mapper_irq(v6_mapper_irq),
    .irq_line(v6_irq_line),
    .mapper_write_pulse(v6_mapper_write_pulse),
    .mapper_write_addr(v6_mapper_write_addr),
    .mapper_write_data(v6_mapper_write_data),
    .prg_readback(v6_prg_readback),
    .chr_waddr(v6_chr_waddr),
    .chr_we(v6_chr_we),
    .chr_wdata(v6_chr_wdata),
    .chr_req(v6_chr_req),
    .chr_final_addr(v6_chr_final_addr)
);

nes_system_v5 #(
    .PRG_SIZE_BYTES(DUT_PRG_SIZE_BYTES),
    .NROM_PRG_SIZE_BYTES(DUT_NROM_PRG_SIZE_BYTES),
    .MAPPER_SELECT(DUT_MAPPER_SELECT),
    .HEADER_MIRRORING(DUT_HEADER_MIRRORING)
) ab_v5 (
    .clk(clk),
    .reset(reset),
    .buttons1(buttons1),
    .buttons2(buttons2),
    .pixel_valid(v5_pixel_valid),
    .pixel_x(v5_pixel_x),
    .pixel_y(v5_pixel_y),
    .pixel_index(v5_pixel_index),
    .frame_done(v5_frame_done),
    .vblank(v5_vblank),
    .nmi_o(v5_nmi_o),
    .apu_irq_o(v5_apu_irq_o),
    .audio_sample_valid(v5_audio_sample_valid),
    .audio_sample_left(v5_audio_sample_left),
    .audio_sample_right(v5_audio_sample_right),
    .cpu_cycle(v5_cpu_cycle),
    .ppu_dot(v5_ppu_dot),
    .ppu_scanline(v5_ppu_scanline),
    .bus_owner(v5_bus_owner),
    .bus_active(v5_bus_active),
    .bus_wait_count(v5_bus_wait_count),
    .bus_req(v5_bus_req),
    .bus_stall(v5_bus_stall),
    .bus_fire(v5_bus_fire),
    .bus_addr(v5_bus_addr),
    .bus_we(v5_bus_we),
    .bus_dout(v5_bus_dout),
    .bus_din(v5_bus_din),
    .sel_ram(v5_sel_ram),
    .sel_ppu(v5_sel_ppu),
    .sel_apu_io(v5_sel_apu_io),
    .sel_open_bus(v5_sel_open_bus),
    .sel_cart_ram(v5_sel_cart_ram),
    .sel_cart_rom(v5_sel_cart_rom),
    .ram_we(v5_ram_we),
    .ppu_reg_cs(v5_ppu_reg_cs),
    .ppu_reg_we(v5_ppu_reg_we),
    .ppu_reg_addr(v5_ppu_reg_addr),
    .apu_reg_cs(v5_apu_reg_cs),
    .apu_reg_we(v5_apu_reg_we),
    .apu_reg_addr(v5_apu_reg_addr),
    .controller_data(v5_controller_data),
    .cart_req(v5_cart_req),
    .cart_xfer(v5_cart_xfer),
    .cart_addr(v5_cart_addr),
    .cart_din(v5_cart_din),
    .cart_ack(v5_cart_ack),
    .bus_hold(v5_bus_hold),
    .oam_dma_start(v5_oam_dma_start),
    .oam_dma_cpu_hold(v5_oam_dma_cpu_hold),
    .oam_dma_cpu_read_req(),
    .oam_dma_cpu_read_addr(v5_oam_dma_cpu_read_addr),
    .oam_dma_cpu_read_ack(v5_oam_dma_cpu_read_ack),
    .oam_dma_cpu_rdata(v5_oam_dma_cpu_rdata),
    .oam_dma_ppu_reg_cs(v5_oam_dma_ppu_reg_cs),
    .oam_dma_ppu_reg_we(v5_oam_dma_ppu_reg_we),
    .oam_dma_ppu_reg_addr(v5_oam_dma_ppu_reg_addr),
    .oam_dma_ppu_reg_dout(v5_oam_dma_ppu_reg_dout),
    .oam_dma_busy(v5_oam_dma_busy),
    .oam_dma_done(v5_oam_dma_done),
    .oam_dma_page(v5_oam_dma_page),
    .oam_dma_page_latch(),
    .oam_dma_base_addr(v5_oam_dma_base_addr),
    .oam_dma_cur_addr(),
    .oam_dma_index(v5_oam_dma_index),
    .oam_dma_align_left(),
    .oam_dma_addr_wr(),
    .oam_dma_cycle_count(),
    .apu_dmc_bus_req(v5_apu_dmc_bus_req),
    .apu_dmc_addr(),
    .apu_dmc_ack(),
    .apu_dmc_rdata(),
    .dma_sel(v5_dma_sel),
    .dma_ack(v5_dma_ack),
    .dma_din(v5_dma_din),
    .dma_wait(),
    .dma_active(),
    .dma_unimpl(v5_dma_unimpl),
    .dma_owner(),
    .ppu_port_cs(v5_ppu_port_cs),
    .ppu_port_we(v5_ppu_port_we),
    .ppu_port_addr(v5_ppu_port_addr),
    .ppu_port_din(v5_ppu_port_din),
    .mapper_id(v5_mapper_id),
    .mapper_prg_bank_offset(v5_mapper_prg_bank_offset),
    .mapper_chr_bank_offset(v5_mapper_chr_bank_offset),
    .mapper_mirroring(v5_mapper_mirroring),
    .mapper_nametable_map(v5_mapper_nametable_map),
    .mapper_prg_bank_number(),
    .mapper_prg_ram_enable(),
    .mapper_prg_ram_we(),
    .mapper_chr_ram_enable(),
    .mapper_chr_ram_we(),
    .mapper_bus_conflict(),
    .mapper_irq(v5_mapper_irq),
    .irq_line(v5_irq_line),
    .mapper_write_pulse(v5_mapper_write_pulse),
    .mapper_write_addr(v5_mapper_write_addr),
    .mapper_write_data(v5_mapper_write_data),
    .prg_readback(v5_prg_readback)
);

nes_system_v6 #(
    .PRG_SIZE_BYTES(DUT_PRG_SIZE_BYTES),
    .NROM_PRG_SIZE_BYTES(DUT_NROM_PRG_SIZE_BYTES),
    .MAPPER_SELECT(DUT_MMC3_SELECT),
    .HEADER_MIRRORING(DUT_HEADER_MIRRORING),
    .MMC3_CHR_RAM(1'b1)
) chr_mmc3 (
    .clk(clk),
    .reset(reset),
    .buttons1(buttons1),
    .buttons2(buttons2),
    .chr_rdata(m_chr_rdata),
    .pixel_valid(m_pixel_valid),
    .pixel_x(m_pixel_x),
    .pixel_y(m_pixel_y),
    .pixel_index(m_pixel_index),
    .frame_done(m_frame_done),
    .vblank(m_vblank),
    .nmi_o(m_nmi_o),
    .apu_irq_o(m_apu_irq_o),
    .audio_sample_valid(),
    .audio_sample_left(),
    .audio_sample_right(),
    .cpu_cycle(m_cpu_cycle),
    .ppu_dot(m_ppu_dot),
    .ppu_scanline(m_ppu_scanline),
    .bus_owner(m_bus_owner),
    .bus_active(),
    .bus_wait_count(),
    .bus_req(),
    .bus_stall(),
    .bus_fire(m_bus_fire),
    .bus_addr(m_bus_addr),
    .bus_we(m_bus_we),
    .bus_dout(m_bus_dout),
    .bus_din(m_bus_din),
    .sel_ram(m_sel_ram),
    .sel_ppu(m_sel_ppu),
    .sel_apu_io(),
    .sel_open_bus(),
    .sel_cart_ram(),
    .sel_cart_rom(),
    .ram_we(m_ram_we),
    .ppu_reg_cs(),
    .ppu_reg_we(),
    .ppu_reg_addr(),
    .apu_reg_cs(),
    .apu_reg_we(),
    .apu_reg_addr(),
    .controller_data(),
    .cart_req(),
    .cart_xfer(m_cart_xfer),
    .cart_addr(m_cart_addr),
    .cart_din(m_cart_din),
    .cart_ack(),
    .bus_hold(),
    .oam_dma_start(),
    .oam_dma_cpu_hold(),
    .oam_dma_cpu_read_req(),
    .oam_dma_cpu_read_addr(),
    .oam_dma_cpu_read_ack(),
    .oam_dma_cpu_rdata(),
    .oam_dma_ppu_reg_cs(),
    .oam_dma_ppu_reg_we(),
    .oam_dma_ppu_reg_addr(),
    .oam_dma_ppu_reg_dout(),
    .oam_dma_busy(),
    .oam_dma_done(),
    .oam_dma_page(),
    .oam_dma_page_latch(),
    .oam_dma_base_addr(),
    .oam_dma_cur_addr(),
    .oam_dma_index(),
    .oam_dma_align_left(),
    .oam_dma_addr_wr(),
    .oam_dma_cycle_count(),
    .apu_dmc_bus_req(),
    .apu_dmc_addr(),
    .apu_dmc_ack(),
    .apu_dmc_rdata(),
    .dma_sel(),
    .dma_ack(),
    .dma_din(),
    .dma_wait(),
    .dma_active(),
    .dma_unimpl(),
    .dma_owner(),
    .ppu_port_cs(),
    .ppu_port_we(),
    .ppu_port_addr(),
    .ppu_port_din(),
    .mapper_id(m_mapper_id),
    .mapper_prg_bank_offset(),
    .mapper_chr_bank_offset(),
    .mapper_mirroring(m_mapper_mirroring),
    .mapper_nametable_map(m_mapper_nametable_map),
    .mapper_prg_bank_number(),
    .mapper_prg_ram_enable(),
    .mapper_prg_ram_we(),
    .mapper_chr_ram_enable(),
    .mapper_chr_ram_we(m_mapper_chr_ram_we),
    .mapper_bus_conflict(),
    .mapper_irq(m_mapper_irq),
    .irq_line(m_irq_line),
    .mapper_write_pulse(m_mapper_write_pulse),
    .mapper_write_addr(m_mapper_write_addr),
    .mapper_write_data(m_mapper_write_data),
    .prg_readback(m_prg_readback),
    .chr_waddr(m_chr_waddr),
    .chr_we(m_chr_we),
    .chr_wdata(m_chr_wdata),
    .chr_req(m_chr_req),
    .chr_final_addr(m_chr_final_addr)
);

// The CHR-ROM twin of ab_v6.  Same elaboration, same PRG image, only
// NROM_CHR_RAM differs, so mapper_chr_ram_we (nes_mapper.v:221) is a hard 0 on
// this board while ab_v6's is live.  That is the named gate the ignore pair is
// measured at: the strobe has to be generated and has to REACH the mapper
// before the mapper can refuse it.
nes_system_v6 #(
    .PRG_SIZE_BYTES(DUT_PRG_SIZE_BYTES),
    .NROM_PRG_SIZE_BYTES(DUT_NROM_PRG_SIZE_BYTES),
    .MAPPER_SELECT(DUT_MAPPER_SELECT),
    .HEADER_MIRRORING(DUT_HEADER_MIRRORING),
    .NROM_CHR_RAM(1'b0)
) chr_rom (
    .clk(clk),
    .reset(reset),
    .buttons1(buttons1),
    .buttons2(buttons2),
    .chr_rdata(rom_chr_rdata),
    .pixel_valid(r_pixel_valid),
    .pixel_x(r_pixel_x),
    .pixel_y(r_pixel_y),
    .pixel_index(r_pixel_index),
    .frame_done(r_frame_done),
    .vblank(),
    .nmi_o(),
    .apu_irq_o(),
    .audio_sample_valid(),
    .audio_sample_left(),
    .audio_sample_right(),
    .cpu_cycle(r_cpu_cycle),
    .ppu_dot(r_ppu_dot),
    .ppu_scanline(r_ppu_scanline),
    .bus_owner(),
    .bus_active(),
    .bus_wait_count(),
    .bus_req(),
    .bus_stall(),
    .bus_fire(),
    .bus_addr(),
    .bus_we(),
    .bus_dout(),
    .bus_din(),
    .sel_ram(),
    .sel_ppu(),
    .sel_apu_io(),
    .sel_open_bus(),
    .sel_cart_ram(),
    .sel_cart_rom(),
    .ram_we(),
    .ppu_reg_cs(),
    .ppu_reg_we(),
    .ppu_reg_addr(),
    .apu_reg_cs(),
    .apu_reg_we(),
    .apu_reg_addr(),
    .controller_data(),
    .cart_req(),
    .cart_xfer(),
    .cart_addr(),
    .cart_din(),
    .cart_ack(),
    .bus_hold(),
    .oam_dma_start(),
    .oam_dma_cpu_hold(),
    .oam_dma_cpu_read_req(),
    .oam_dma_cpu_read_addr(),
    .oam_dma_cpu_read_ack(),
    .oam_dma_cpu_rdata(),
    .oam_dma_ppu_reg_cs(),
    .oam_dma_ppu_reg_we(),
    .oam_dma_ppu_reg_addr(),
    .oam_dma_ppu_reg_dout(),
    .oam_dma_busy(),
    .oam_dma_done(),
    .oam_dma_page(),
    .oam_dma_page_latch(),
    .oam_dma_base_addr(),
    .oam_dma_cur_addr(),
    .oam_dma_index(),
    .oam_dma_align_left(),
    .oam_dma_addr_wr(),
    .oam_dma_cycle_count(),
    .apu_dmc_bus_req(),
    .apu_dmc_addr(),
    .apu_dmc_ack(),
    .apu_dmc_rdata(),
    .dma_sel(),
    .dma_ack(),
    .dma_din(),
    .dma_wait(),
    .dma_active(),
    .dma_unimpl(),
    .dma_owner(),
    .ppu_port_cs(),
    .ppu_port_we(),
    .ppu_port_addr(),
    .ppu_port_din(),
    .mapper_id(),
    .mapper_prg_bank_offset(),
    .mapper_chr_bank_offset(),
    .mapper_mirroring(),
    .mapper_nametable_map(),
    .mapper_prg_bank_number(),
    .mapper_prg_ram_enable(),
    .mapper_prg_ram_we(),
    .mapper_chr_ram_enable(r_mapper_chr_ram_enable),
    .mapper_chr_ram_we(r_mapper_chr_ram_we),
    .mapper_bus_conflict(),
    .mapper_irq(),
    .irq_line(),
    .mapper_write_pulse(),
    .mapper_write_addr(),
    .mapper_write_data(),
    .prg_readback(),
    .chr_waddr(r_chr_waddr),
    .chr_we(r_chr_we),
    .chr_wdata(r_chr_wdata),
    .chr_req(),
    .chr_final_addr(r_chr_final_addr)
);

// ab_v6 run a second time with the two PRG fill bytes swapped, so the program
// stores the complement image into the same external CHR RAM.  If the write
// path were ignored, this instance would render exactly what ab_v6 renders
// BEFORE its own upload, i.e. the two pictures would agree and the whole
// self-validating pair would collapse.
nes_system_v6 #(
    .PRG_SIZE_BYTES(DUT_PRG_SIZE_BYTES),
    .NROM_PRG_SIZE_BYTES(DUT_NROM_PRG_SIZE_BYTES),
    .MAPPER_SELECT(DUT_MAPPER_SELECT),
    .HEADER_MIRRORING(DUT_HEADER_MIRRORING),
    .NROM_CHR_RAM(1'b1)
) chr_ram_b (
    .clk(clk),
    .reset(reset),
    .buttons1(buttons1),
    .buttons2(buttons2),
    .chr_rdata(ramb_chr_rdata),
    .pixel_valid(rb_pixel_valid),
    .pixel_x(rb_pixel_x),
    .pixel_y(rb_pixel_y),
    .pixel_index(rb_pixel_index),
    .frame_done(rb_frame_done),
    .vblank(),
    .nmi_o(),
    .apu_irq_o(),
    .audio_sample_valid(),
    .audio_sample_left(),
    .audio_sample_right(),
    .cpu_cycle(rb_cpu_cycle),
    .ppu_dot(rb_ppu_dot),
    .ppu_scanline(rb_ppu_scanline),
    .bus_owner(),
    .bus_active(),
    .bus_wait_count(),
    .bus_req(),
    .bus_stall(),
    .bus_fire(),
    .bus_addr(),
    .bus_we(),
    .bus_dout(),
    .bus_din(),
    .sel_ram(),
    .sel_ppu(),
    .sel_apu_io(),
    .sel_open_bus(),
    .sel_cart_ram(),
    .sel_cart_rom(),
    .ram_we(),
    .ppu_reg_cs(),
    .ppu_reg_we(),
    .ppu_reg_addr(),
    .apu_reg_cs(),
    .apu_reg_we(),
    .apu_reg_addr(),
    .controller_data(),
    .cart_req(),
    .cart_xfer(),
    .cart_addr(),
    .cart_din(),
    .cart_ack(),
    .bus_hold(),
    .oam_dma_start(),
    .oam_dma_cpu_hold(),
    .oam_dma_cpu_read_req(),
    .oam_dma_cpu_read_addr(),
    .oam_dma_cpu_read_ack(),
    .oam_dma_cpu_rdata(),
    .oam_dma_ppu_reg_cs(),
    .oam_dma_ppu_reg_we(),
    .oam_dma_ppu_reg_addr(),
    .oam_dma_ppu_reg_dout(),
    .oam_dma_busy(),
    .oam_dma_done(),
    .oam_dma_page(),
    .oam_dma_page_latch(),
    .oam_dma_base_addr(),
    .oam_dma_cur_addr(),
    .oam_dma_index(),
    .oam_dma_align_left(),
    .oam_dma_addr_wr(),
    .oam_dma_cycle_count(),
    .apu_dmc_bus_req(),
    .apu_dmc_addr(),
    .apu_dmc_ack(),
    .apu_dmc_rdata(),
    .dma_sel(),
    .dma_ack(),
    .dma_din(),
    .dma_wait(),
    .dma_active(),
    .dma_unimpl(),
    .dma_owner(),
    .ppu_port_cs(),
    .ppu_port_we(),
    .ppu_port_addr(),
    .ppu_port_din(),
    .mapper_id(),
    .mapper_prg_bank_offset(),
    .mapper_chr_bank_offset(),
    .mapper_mirroring(),
    .mapper_nametable_map(),
    .mapper_prg_bank_number(),
    .mapper_prg_ram_enable(),
    .mapper_prg_ram_we(),
    .mapper_chr_ram_enable(),
    .mapper_chr_ram_we(rb_mapper_chr_ram_we),
    .mapper_bus_conflict(),
    .mapper_irq(),
    .irq_line(),
    .mapper_write_pulse(),
    .mapper_write_addr(),
    .mapper_write_data(),
    .prg_readback(),
    .chr_waddr(rb_chr_waddr),
    .chr_we(rb_chr_we),
    .chr_wdata(rb_chr_wdata),
    .chr_req(),
    .chr_final_addr(rb_chr_final_addr)
);

always #5 clk = !clk;

initial begin
    clk = 1'b0;
    reset = 1'b0;
    tb_live = 1'b1;
end

// ------------------------------------------------- reset window / P0-1

always @(posedge clk) begin
    if (reset) begin
        reset_clks = reset_clks + 1;
        // The first reset edge is the edge that applies the reset, so the DUT
        // nets are still X when it is sampled; start checking on the next one.
        if (reset_clks > 1) begin
            if (v6_chr_req !== 1'b0)
                reset_chr_req_bad = reset_chr_req_bad + 1;
            if (v6_chr_final_addr !== 17'd0)
                reset_chr_addr_bad = reset_chr_addr_bad + 1;
            // chr_we carries a !reset term, so a strobe inside the reset window
            // would be a write into a model that is still being cleared.
            if (v6_chr_we !== 1'b0)
                reset_chr_we_bad = reset_chr_we_bad + 1;
            if (v6_chr_waddr !== 14'd0)
                reset_chr_waddr_bad = reset_chr_waddr_bad + 1;
            if ((v6_mapper_id !== 3'd0) || (v5_mapper_id !== 3'd0))
                reset_mapper_id_bad = reset_mapper_id_bad + 1;
        end
    end
end

// ------------------------------------- P0-2 / P0-3 / P0-6 CHR path monitors
//
// The local 14-bit address is read from ab_v6.u_ppu.chr_addr, the PPU port
// itself.  chr_final_addr is the mapper's OUTPUT one net downstream, so the
// comparison is not circular.

always @(posedge clk) begin
    if (reset) begin
        chr_h1 <= 17'd0;
        chr_h2 <= 17'd0;
        chr_wq0 <= 17'd0;
        chr_wq1 <= 17'd0;
        chr_wq0_v <= 1'b0;
        chr_wq1_v <= 1'b0;
        fu_sgrab_q <= 1'b0;
        fu_cappl_q <= 1'b0;
    end else if (ab_v6.ce_ppu) begin
        chr_write_on_port = 1'b0;
        chr_h1 <= v6_chr_final_addr;
        chr_h2 <= chr_h1;
        chr_wq1 <= chr_wq0;
        chr_wq1_v <= chr_wq0_v;
        if ((v6_chr_we !== 1'b0) && (v6_mapper_chr_ram_we !== 1'b0)) begin
            chr_wq0 <= v6_chr_final_addr;
            chr_wq0_v <= 1'b1;
        end else begin
            chr_wq0_v <= 1'b0;
        end

        // P0-6.  The tb chr_mem array changes mid-run now that the program can
        // store into it, so a latched byte whose address was itself written in
        // the last two ce is being compared against a different epoch of the
        // array.  Those beats are counted and skipped, everything else is
        // still compared, and both counts are printed.
        if (fu_sgrab_q !== 1'b0) begin
            chr_latch_checks = chr_latch_checks + 1;
            if (((chr_wq0_v !== 1'b0) && (chr_wq0 === chr_h2)) ||
                ((chr_wq1_v !== 1'b0) && (chr_wq1 === chr_h2))) begin
                chr_latch_race_skip = chr_latch_race_skip + 1;
            end else if (fu_cappl_q === 1'b0) begin
                if (fu_bg_lo !== chr_mem[chr_h2]) begin
                    chr_latch_err = chr_latch_err + 1;
                    if (chr_latch_err < 5)
                        $fatal(1, "P0-6 bg_lo latched %02h, tb chr_mem[%05h] = %02h",
                               fu_bg_lo, chr_h2, chr_mem[chr_h2]);
                end
            end else begin
                if (fu_bg_hi !== chr_mem[chr_h2]) begin
                    chr_latch_err = chr_latch_err + 1;
                    if (chr_latch_err < 5)
                        $fatal(1, "P0-6 bg_hi latched %02h, tb chr_mem[%05h] = %02h",
                               fu_bg_hi, chr_h2, chr_mem[chr_h2]);
                end
            end
        end
        fu_sgrab_q <= (fu_state == 3'd4);
        fu_cappl_q <= fu_cap_pl;

        // ------------------------------------------------ $2007 WRITE BEATS
        // Measured FIRST because the write owns the mapper port on its beat
        // (mapper_ppu_addr = ppu_chr_we ? ppu_chr_waddr : ppu_chr_addr), so the
        // read check below has to know whether a write is driving chr_final_addr
        // this ce.  The expected final address is built from the SAME
        // independent tb bank model the read path uses, with chr_waddr (the
        // PPU's LOCAL address) as the local term, and chr_final_addr is the
        // mapper's output one net downstream, so this is not circular.
        if (v6_chr_we !== 1'b0) begin
            chr_wr_beats = chr_wr_beats + 1;
            f_chr_wr = f_chr_wr + 1;
            if (v6_chr_req !== 1'b0) begin
                chr_wr_req_clash = chr_wr_req_clash + 1;
                chr_write_on_port = 1'b1;
                // The colliding beat steals the mapper port from the fetch unit,
                // so the byte the fetch unit latches that ce is the WRITE
                // address's byte.  That only reaches the screen if something the
                // fetch feeds is actually being displayed.
                if (ab_chr_wr_displayed === 1'b1)
                    chr_wr_clash_visible = chr_wr_clash_visible + 1;
            end
            if (v6_chr_final_addr[13] !== 1'b0) begin
                chr_wr_bit13_bad = chr_wr_bit13_bad + 1;
                f_wr_final_bit13_bad = f_wr_final_bit13_bad + 1;
            end
            if (v6_chr_final_addr > f_max_final_addr)
                f_max_final_addr = v6_chr_final_addr;
            chr_wr_exp_final = ({13'b0, tb_chr_bank_model} << 13) |
                              (v6_chr_waddr & 14'h1FFF);
            chr_wr_checks = chr_wr_checks + 1;
            if (v6_chr_final_addr !== chr_wr_exp_final) begin
                chr_wr_addr_err = chr_wr_addr_err + 1;
                if (chr_wr_addr_err < 5)
                    $fatal(1, "P0-2 write beat chr_final_addr %05h != tb model %05h (local chr_waddr %04h, ppu v_addr %04h)",
                           v6_chr_final_addr, chr_wr_exp_final, v6_chr_waddr,
                           ab_v6.u_ppu.v_addr);
            end
            if (v6_chr_waddr[12:0] !== v6_chr_final_addr[12:0]) begin
                chr_wr_addr_err = chr_wr_addr_err + 1;
                if (chr_wr_addr_err < 5)
                    $fatal(1, "P0-2 write beat local chr_waddr[12:0] %03h != final[12:0] %03h",
                           v6_chr_waddr[12:0], v6_chr_final_addr[12:0]);
            end
            if (v6_chr_final_addr[16:13] !== 4'd0)
                chr_wr_addr_err = chr_wr_addr_err + 1;
            // chr_waddr must be the PRE-increment v_addr, and the $2000 guard
            // means both of its top bits are clear.
            if (v6_chr_waddr !== ab_v6.u_ppu.v_addr[13:0]) begin
                chr_wr_addr_err = chr_wr_addr_err + 1;
                if (chr_wr_addr_err < 5)
                    $fatal(1, "P0-2 write beat chr_waddr %04h is not the pre-increment ppu v_addr %04h",
                           v6_chr_waddr, ab_v6.u_ppu.v_addr);
            end
            if (v6_chr_waddr[13] !== 1'b0)
                chr_wr_addr_err = chr_wr_addr_err + 1;
            if (v6_chr_wdata !== ab_v6.u_ppu.reg_din) begin
                chr_wr_addr_err = chr_wr_addr_err + 1;
                if (chr_wr_addr_err < 5)
                    $fatal(1, "P0-2 write beat chr_wdata %02h is not the ppu reg_din %02h",
                           v6_chr_wdata, ab_v6.u_ppu.reg_din);
            end
            if (v6_mapper_chr_ram_we !== 1'b1)
                chr_wr_not_accepted = chr_wr_not_accepted + 1;
            if ((chr_wr_prev !== 1'b0) && (v6_chr_we !== 1'b0))
                chr_wr_consec = chr_wr_consec + 1;
        end
        chr_wr_prev = v6_chr_we;

        // READ BEATS.  On the ce where a $2007 write and a fetch collide the
        // mapper port is carrying the WRITE address (write priority in
        // mapper_ppu_addr), so chr_final_addr is the write model's address and
        // NOT the fetch address.  That beat is counted as a read-on-write beat
        // and its address is checked against the WRITE model; every other read
        // beat is checked against the READ model exactly as before.
        if (v6_chr_req !== 1'b0) begin
            chr_req_total = chr_req_total + 1;
            f_chr_req = f_chr_req + 1;
            chr_req_owner[v6_bus_owner[2:0]] =
                chr_req_owner[v6_bus_owner[2:0]] + 1;
            chr_req_owner_total = chr_req_owner_total + 1;
            if (v6_chr_final_addr[CHR_ADDR_BITS-1:13] != 4'd0)
                chr_hi_addr_bad = chr_hi_addr_bad + 1;
            if (v6_chr_final_addr[13] !== 1'b0) begin
                f_final_bit13_bad = f_final_bit13_bad + 1;
            end
            if (v6_chr_final_addr > f_max_final_addr)
                f_max_final_addr = v6_chr_final_addr;
            if (ab_v6.u_ppu.chr_addr[13] === 1'b1)
                f_local_bit13 = f_local_bit13 + 1;
            if (ab_v6.u_ppu.chr_addr[12] === 1'b1)
                f_local_bit12 = f_local_bit12 + 1;

            if (chr_write_on_port === 1'b0) begin
                chr_addr_checks = chr_addr_checks + 1;
                if (v6_chr_final_addr !==
                    (({13'b0, tb_chr_bank_model} << 13) |
                     (ab_v6.u_ppu.chr_addr & 14'h1FFF))) begin
                    chr_addr_err = chr_addr_err + 1;
                    f_addr_err = f_addr_err + 1;
                    if (chr_addr_err < 5)
                        $fatal(1, "P0-2 chr_final_addr %05h != tb model %05h (local %04h)",
                               v6_chr_final_addr,
                               (({13'b0, tb_chr_bank_model} << 13) |
                                (ab_v6.u_ppu.chr_addr & 14'h1FFF)),
                               ab_v6.u_ppu.chr_addr);
                end
                if (ab_v6.u_ppu.chr_addr[12:0] !== v6_chr_final_addr[12:0]) begin
                    chr_addr_err = chr_addr_err + 1;
                    f_addr_err = f_addr_err + 1;
                    if (chr_addr_err < 5)
                        $fatal(1, "P0-2 local[12:0] %03h != final[12:0] %03h",
                               ab_v6.u_ppu.chr_addr[12:0], v6_chr_final_addr[12:0]);
                end
                if (v6_chr_final_addr[16:13] !== 4'd0) begin
                    chr_addr_err = chr_addr_err + 1;
                    f_addr_err = f_addr_err + 1;
                end
            end

            if ((v6_bus_req === 1'b0) && (v6_bus_fire === 1'b0) &&
                (v6_bus_stall === 1'b0))
                chr_req_bus_idle = chr_req_bus_idle + 1;
            if (v6_bus_hold !== 1'b0)
                chr_req_during_dma = chr_req_during_dma + 1;
        end
        chr_write_on_port = 1'b0;
    end
end

// The bus monitor supplies the independent expected count of $2007 writes that
// land in the CHR half of the address space.  v_addr is sampled on the same clk
// the PPU samples reg_cs, i.e. BEFORE it increments, so this counts exactly the
// cycles on which nes_ppu2c02 can raise chr_we.  The palette writes the program
// also issues ($3F00..$3F11) have v_addr >= $2000 and are correctly excluded.
always @(posedge clk) begin
    if (reset)
        chr_wr_exp_total = 0;
    else if ((v6_bus_fire !== 1'b0) && (v6_bus_we !== 1'b0) &&
             (v6_sel_ppu === 1'b1) && (v6_ppu_reg_addr == 3'd7) &&
             (ab_v6.u_ppu.v_addr < 15'h2000))
        chr_wr_exp_total = chr_wr_exp_total + 1;
end

// TB-side prediction of what the model must present at each sampling edge
// versus what the model is actually presenting.  chr_h1 read at this edge is
// the chr_final_addr of the previous ce, which is exactly the address the
// model sampled on that previous ce.
always @(posedge clk) begin
    if (!reset && ab_v6.ce_ppu && (v6_chr_req !== 1'b0)) begin
        chr_model_pred_checks = chr_model_pred_checks + 1;
        if (((chr_wq0_v !== 1'b0) && (chr_wq0 === chr_h1)) ||
            ((chr_wq1_v !== 1'b0) && (chr_wq1 === chr_h1))) begin
            chr_pred_race_skip = chr_pred_race_skip + 1;
        end else if (chr_rdata_q !== chr_mem[chr_h1]) begin
            chr_model_pred_err = chr_model_pred_err + 1;
            if (chr_model_pred_err < 5)
                $fatal(1, "P0-6 model presented %02h, tb chr_mem[%05h] = %02h",
                       chr_rdata_q, chr_h1, chr_mem[chr_h1]);
        end
    end
end

// --------------------------------------------- P0-2 cart write pulse model
//
// The prediction is built only from exported ports (cart_xfer && bus_we) plus
// the values the TB itself watched on cart_addr / bus_dout.  mapper_write_pulse
// is a different net entirely, so a missing, doubled, mistimed or wrong-value
// pulse is a failure.

always @(posedge clk) begin
    if (reset) begin
        cart_pulse_due = 1'b0;
        cart_pulse_exp_addr = 16'h0000;
        cart_pulse_exp_data = 8'h00;
        prev_cart_pulse = 1'b0;
    end else begin
        if (v6_mapper_write_pulse !== 1'b0) begin
            cart_pulse_total = cart_pulse_total + 1;
            if (prev_cart_pulse !== 1'b0)
                cart_pulse_width_err = cart_pulse_width_err + 1;
            if (cart_pulse_due !== 1'b1)
                cart_pulse_spurious = cart_pulse_spurious + 1;
            else begin
                if (v6_mapper_write_addr !== cart_pulse_exp_addr)
                    cart_pulse_err = cart_pulse_err + 1;
                if (v6_mapper_write_data !== cart_pulse_exp_data)
                    cart_pulse_err = cart_pulse_err + 1;
            end
        end else if (prev_cart_pulse !== 1'b0) begin
            if (cart_pulse_due === 1'b1) begin
                cart_pulse_err = cart_pulse_err + 1;
                cart_pulse_multi = cart_pulse_multi + 1;
            end
        end
        prev_cart_pulse = v6_mapper_write_pulse;

        if ((v6_cart_xfer !== 1'b0) && (v6_bus_we !== 1'b0)) begin
            cart_wr_total = cart_wr_total + 1;
            cart_pulse_due = 1'b1;
            cart_pulse_exp_addr = v6_cart_addr;
            cart_pulse_exp_data = v6_bus_dout;
        end else begin
            cart_pulse_due = 1'b0;
        end
    end
end

// --------------------------------------------------------------- P0-4 A/B

always @(posedge clk) begin
    if (reset) begin
        ab_visible_count = 0;
        ab_visible_div = 0;
        ab_all_ce_count = 0;
        ab_all_ce_div = 0;
    end else if (ab_v6.ce_ppu) begin
        if (frames_seen < FRAME_TARGET) begin
            ab_all_ce_count = ab_all_ce_count + 1;
            if ((v6_pixel_valid !== v5_pixel_valid) ||
                (v6_pixel_x !== v5_pixel_x) ||
                (v6_pixel_y !== v5_pixel_y) ||
                (v6_pixel_index !== v5_pixel_index) ||
                (v6_frame_done !== v5_frame_done) ||
                (v6_ppu_dot !== v5_ppu_dot) ||
                (v6_ppu_scanline !== v5_ppu_scanline) ||
                (v6_nmi_o !== v5_nmi_o) ||
                (v6_cpu_cycle !== v5_cpu_cycle)) begin
                ab_all_ce_div = ab_all_ce_div + 1;
                if (ab_all_ce_div === 1)
                    $fatal(1, "P0-4 per-ce divergence pv=%b/%b x=%0d/%0d y=%0d/%0d idx=%0d/%0d fd=%b/%b dot=%0d/%0d sl=%0d/%0d nmi=%b/%b cc=%0d/%0d | v6 mask=%02h ctrl=%02h bg=%02h/%02h chr_addr=%04h final=%05h | v5 mask=%02h ctrl=%02h bg=%02h/%02h bgpat=%04h",
                           v6_pixel_valid, v5_pixel_valid, v6_pixel_x, v5_pixel_x,
                           v6_pixel_y, v5_pixel_y, v6_pixel_index, v5_pixel_index,
                           v6_frame_done, v5_frame_done, v6_ppu_dot, v5_ppu_dot,
                           v6_ppu_scanline, v5_ppu_scanline, v6_nmi_o, v5_nmi_o,
                           v6_cpu_cycle, v5_cpu_cycle,
                           ab_v6.u_ppu.mask_reg, ab_v6.u_ppu.control_reg,
                           ab_v6.u_ppu.bg_pattern_low, ab_v6.u_ppu.bg_pattern_high,
                           ab_v6.u_ppu.chr_addr, v6_chr_final_addr,
                           ab_v5.u_ppu.mask_reg, ab_v5.u_ppu.control_reg,
                           ab_v5.u_ppu.bg_pattern_low, ab_v5.u_ppu.bg_pattern_high,
                           ab_v5.u_ppu.bg_pattern_addr);
            end
            if (v6_pixel_valid !== 1'b0) begin
                ab_visible_count = ab_visible_count + 1;
                if ((v6_pixel_x !== v5_pixel_x) ||
                    (v6_pixel_y !== v5_pixel_y) ||
                    (v6_pixel_index !== v5_pixel_index))
                    ab_visible_div = ab_visible_div + 1;
            end
        end
    end
end

// ------------------------------------- P1-1 bus / P1-7 controller / P1-8 audio

always @(posedge clk) begin
    if (reset) begin
        bus_fire_count = 0;
        prg_rd_count = 0;
        prg_wr_count = 0;
        cartram_rd_count = 0;
        ram_rd_count = 0;
        ram_wr_count = 0;
        ppu_rd_count = 0;
        ppu_wr_count = 0;
        apu_rd_count = 0;
        apu_wr_count = 0;
        open_rd_count = 0;
        prg_rd_err = 0;
    end else begin
        if (v6_bus_wait_count !== 8'd0)
            bus_wait_count_bad = bus_wait_count_bad + 1;
        if (v6_audio_sample_valid !== 1'b0) begin
            sample_strobes = sample_strobes + 1;
            if (v6_audio_sample_left !== 16'd0)
                sample_nonzero = sample_nonzero + 1;
            if (v6_audio_sample_left > sample_peak[15:0])
                sample_peak = v6_audio_sample_left;
        end
        if (v6_apu_dmc_bus_req !== 1'b0)
            dmc_req_seen = dmc_req_seen + 1;
        if (v6_dma_sel !== 1'b0)
            dmc_sel_seen = dmc_sel_seen + 1;
        if (ab_v6.u_cpu.dbg_illegal !== 1'b0)
            illegal_hits = illegal_hits + 1;

        if (v6_bus_fire !== 1'b0) begin
            bus_fire_count = bus_fire_count + 1;
            if (v6_sel_open_bus === 1'b1) begin
                open_rd_count = open_rd_count + 1;
            end else if (v6_sel_ram === 1'b1) begin
                if (v6_bus_we !== 1'b0) begin
                    ram_wr_count = ram_wr_count + 1;
                    if ((v6_bus_addr[10:0] >= 11'h200) &&
                        (v6_bus_addr[10:0] <= 11'h2FF))
                        ram_wr_src = ram_wr_src + 1;
                    else if (v6_bus_addr[10:0] == NMI_COUNTER_CELL[10:0])
                        ram_wr_nmi = ram_wr_nmi + 1;
                    else if (v6_bus_addr[10:0] == DMA_FLAG_CELL[10:0])
                        ram_wr_dma = ram_wr_dma + 1;
                    else if (v6_bus_addr[10:0] == OAM_RB_FLAG_CELL[10:0])
                        ram_wr_oamrb = ram_wr_oamrb + 1;
                    else if (v6_bus_addr[10:0] == PORT1_9TH_CELL[10:0])
                        ram_wr_p1n = ram_wr_p1n + 1;
                    else if (v6_bus_addr[10:0] == PORT2_9TH_CELL[10:0])
                        ram_wr_p2n = ram_wr_p2n + 1;
                end else begin
                    ram_rd_count = ram_rd_count + 1;
                end
            end else if (v6_sel_ppu === 1'b1) begin
                if (v6_bus_we !== 1'b0) begin
                    ppu_wr_count = ppu_wr_count + 1;
                    case (v6_ppu_reg_addr)
                        3'd0: ppu_wr_ctrl = ppu_wr_ctrl + 1;
                        3'd1: ppu_wr_mask = ppu_wr_mask + 1;
                        3'd2: ppu_wr_status = ppu_wr_status + 1;
                        3'd3: ppu_wr_oamaddr = ppu_wr_oamaddr + 1;
                        3'd6: ppu_wr_vaddr = ppu_wr_vaddr + 1;
                        3'd7: ppu_wr_vdata = ppu_wr_vdata + 1;
                        default: ppu_wr_other = ppu_wr_other + 1;
                    endcase
                end else begin
                    ppu_rd_count = ppu_rd_count + 1;
                end
            end else if (v6_sel_apu_io === 1'b1) begin
                if (v6_bus_we !== 1'b0) begin
                    apu_wr_count = apu_wr_count + 1;
                    if (v6_apu_reg_addr == 5'h16)
                        apu_wr_ctrl = apu_wr_ctrl + 1;
                    else if (v6_apu_reg_addr == 5'h17)
                        apu_wr_frame = apu_wr_frame + 1;
                    else if (v6_apu_reg_addr == 5'h15)
                        apu_wr_status = apu_wr_status + 1;
                    else if (v6_apu_reg_addr == 5'h14)
                        apu_wr_dma = apu_wr_dma + 1;
                end else begin
                    apu_rd_count = apu_rd_count + 1;
                    if (v6_apu_reg_addr == 5'h15)
                        apu_rd_4015 = apu_rd_4015 + 1;
                    else if (v6_apu_reg_addr == 5'h16)
                        apu_rd_ctrl1 = apu_rd_ctrl1 + 1;
                    else if (v6_apu_reg_addr == 5'h17)
                        apu_rd_ctrl2 = apu_rd_ctrl2 + 1;
                end
            end else if (v6_sel_cart_ram === 1'b1) begin
                if (v6_bus_we === 1'b0)
                    cartram_rd_count = cartram_rd_count + 1;
            end else begin
                if (v6_bus_we === 1'b0) begin
                    prg_rd_count = prg_rd_count + 1;
                    // Independent TB PRG bank model: NROM keeps the 15-bit
                    // window, so the bank is the low 15 bits of the address.
                    if (v6_mapper_prg_bank_offset !==
                        v6_bus_addr[TB_WINDOW_BITS-1:0])
                        prg_rd_err = prg_rd_err + 1;
                    if (v6_cart_din !== tb_prg[v6_bus_addr[TB_WINDOW_BITS-1:0]])
                        prg_rd_err = prg_rd_err + 1;
                    if (v6_bus_din !== tb_prg[v6_bus_addr[TB_WINDOW_BITS-1:0]])
                        prg_rd_err = prg_rd_err + 1;
                end else begin
                    prg_wr_count = prg_wr_count + 1;
                end
            end
        end
    end
end

always @(posedge clk) begin
    if (reset) begin
        bus_stall_err = 0;
    end else if (ab_v6.ce_cpu) begin
        if (v6_bus_stall !== (v6_bus_req && !v6_bus_fire))
            bus_stall_err = bus_stall_err + 1;
    end
end

// ------------------------------------------------- W1 upload-flag snapshot
//
// The program raises ram[0015] only after its last $2007 CHR write, and the
// store itself is a cpu bus cycle that lands several ce after that write, so the
// tb chr_mem array is already fully updated at this edge.  Snapshotting here
// rather than at the end of the run is what makes this a per-byte verification
// of the upload instead of a restatement of the preload loop.
always @(posedge clk) begin
    if (reset) begin
        chr_up_flag_seen = 0;
        chr_up_snap_err = 0;
        chr_up_snap_nochange = 0;
        chr_up_addr_err = 0;
        chr_v5_snap_err = 0;
        rom_pre_bytes = 0;
        rom_pre_err = 0;
        rom_wr_beats = 0;
        rom_wr_ramwe_bad = 0;
        rom_wr_bad_wdata = 0;
        rom_final_bytes = 0;
        rom_tile_err = 0;
        rb_wr_beats = 0;
        rb_wr_not_accepted = 0;
        rb_tile_err = 0;
        rb_tile0_same = 0;
    end else begin
        // The ROM board runs the identical program, so its strobe count has to
        // come out identical.  If it does not, the two runs are not comparable
        // and the paired line below would mean nothing.
        if (r_chr_we !== 1'b0) begin
            rom_wr_beats = rom_wr_beats + 1;
            if (r_mapper_chr_ram_we !== 1'b0)
                rom_wr_ramwe_bad = rom_wr_ramwe_bad + 1;
            if (r_chr_wdata !== chr_rom.u_ppu.reg_din)
                rom_wr_bad_wdata = rom_wr_bad_wdata + 1;
        end
        if (rb_chr_we !== 1'b0) begin
            rb_wr_beats = rb_wr_beats + 1;
            if (rb_mapper_chr_ram_we !== 1'b1)
                rb_wr_not_accepted = rb_wr_not_accepted + 1;
        end
        if ((v6_bus_fire !== 1'b0) && (v6_bus_we !== 1'b0) &&
            (v6_sel_ram === 1'b1) &&
            (v6_bus_addr[10:0] == CHR_UPLOAD_FLAG_CELL[10:0]) &&
            (v6_bus_dout === 8'h01) && (chr_up_flag_seen == 0)) begin
            chr_up_flag_seen = 1;
            for (k = 0; k < CHR_TILE_BYTES; k = k + 1) begin
                // Both halves the program addresses, on the external model.
                if (chr_mem[k] !== chr_tile_image[k]) begin
                    chr_up_snap_err = chr_up_snap_err + 1;
                    if (chr_up_snap_err < 5)
                        $fatal(1, "W1 chr_mem[%0d] is %02h at the upload flag, expected the program's own byte %02h",
                               k, chr_mem[k], chr_tile_image[k]);
                end
                if (chr_mem[4096 + k] !== chr_tile_image[k]) begin
                    chr_up_snap_err = chr_up_snap_err + 1;
                    if (chr_up_snap_err < 5)
                        $fatal(1, "W1 chr_mem[%0d] is %02h at the upload flag, expected the program's own byte %02h",
                               4096 + k, chr_mem[4096 + k], chr_tile_image[k]);
                end
                // non-vacuity: every one of the 96 bytes must have CHANGED
                // relative to the sentinel this board started from.
                if (chr_mem[k] === chr_tile_image_b[k])
                    chr_up_snap_nochange = chr_up_snap_nochange + 1;
                if (chr_mem[4096 + k] === chr_tile_image_b[k])
                    chr_up_snap_nochange = chr_up_snap_nochange + 1;
                // untouched-address control: $2000 is past the end of every
                // address the PPU or a $2007 write can produce (chr_final_addr
                // tops out at 0x1FFF), so those cells must still be the
                // sentinel.  A stray write anywhere else would show up here.
                if (chr_mem[8192 + k] !== chr_tile_image_b[k])
                    chr_up_addr_err = chr_up_addr_err + 1;
                // ab_v5's internal handler also writes chr_ram[v_addr[12:0]],
                // and the background reads its $1000 table, so both halves of
                // v5's array have to have been filled by the program as well.
                if (ab_v5.u_ppu.chr_ram[k] !== chr_tile_image[k])
                    chr_v5_snap_err = chr_v5_snap_err + 1;
                if (ab_v5.u_ppu.chr_ram[4096 + k] !== chr_tile_image[k])
                    chr_v5_snap_err = chr_v5_snap_err + 1;
            end
            k = 0;
            for (k = 0; k < CHR_MEM_BYTES; k = k + 1) begin
                rom_pre_bytes = rom_pre_bytes + 1;
                if (rom_chr_mem[k] !== rom_chr_pre[k])
                    rom_pre_err = rom_pre_err + 1;
            end
            k = 0;
            for (k = 0; k < CHR_TILE_BYTES; k = k + 1) begin
                if (rom_chr_mem[k] !== chr_tile_image[k])
                    rom_tile_err = rom_tile_err + 1;
                if (rom_chr_mem[4096 + k] !== chr_tile_image[k])
                    rom_tile_err = rom_tile_err + 1;
                if (ramb_chr_mem[k] !== chr_tile_image_b[k])
                    rb_tile_err = rb_tile_err + 1;
                if (ramb_chr_mem[4096 + k] !== chr_tile_image_b[k])
                    rb_tile_err = rb_tile_err + 1;
                // chr_ram_b must hold the COMPLEMENT everywhere, so a single
                // byte that still equals run A's image would already mean the
                // two boards ended up rendering the same picture.
                if ((ramb_chr_mem[k] === chr_tile_image[k]) ||
                    (ramb_chr_mem[4096 + k] === chr_tile_image[k]))
                    rb_tile0_same = rb_tile0_same + 1;
            end
            k = 0;
            for (k = 0; k < CHR_MEM_BYTES; k = k + 1) begin
                if (rom_chr_mem[k] !== rom_chr_pre[k])
                    rom_final_bytes = rom_final_bytes + 1;
            end
            k = 0;
            // W3: snapshot the four windows the read-back loops address, here and
            // now.  Loop A has already run (it sits above the flag store), so
            // this is the state the nmi-time loop B has to leave untouched.  If a
            // read ever raised chr_we, or if the model accepted a store the
            // mapper should have refused, these bytes would move and the end of
            // run comparison in check_w3_readback fails.
            for (rb_snap_i = 0; rb_snap_i < CHR_RB_WINDOW_BYTES; rb_snap_i = rb_snap_i + 1) begin
                chr_rb_snap[0 * CHR_RB_WINDOW_BYTES + rb_snap_i] =
                    chr_mem[CHR_RB_LOOP_A_ADDR + rb_snap_i[15:0]];
                chr_rb_snap[1 * CHR_RB_WINDOW_BYTES + rb_snap_i] =
                    chr_mem[CHR_RB_LOOP_B_ON + rb_snap_i[15:0]];
                chr_rb_snap[2 * CHR_RB_WINDOW_BYTES + rb_snap_i] =
                    chr_mem[CHR_RB_LOOP_B_OFF + rb_snap_i[15:0]];
                chr_rb_snap[3 * CHR_RB_WINDOW_BYTES + rb_snap_i] =
                    chr_mem[CHR_RB_LOOP_B_UNW + rb_snap_i[15:0]];
            end
            rb_snap_i = 0;
        end
    end
end

// P1-7 controller: serial bit train and the apu_reg_cs leak check.
always @(posedge clk) begin
    if (reset) begin
        ctrl_rd_seen = 0;
        ctrl_wr_count = 0;
        ctrl_data_err = 0;
        ctrl_cs_err = 0;
    end else begin
        if ((v6_apu_reg_cs !== 1'b0) &&
            ((v6_apu_reg_addr == 5'h16) ||
             ((v6_apu_reg_addr == 5'h17) && (v6_apu_reg_we !== 1'b1))))
            ctrl_cs_err = ctrl_cs_err + 1;
        if (ab_v6.apu_ctrl_xfer !== 1'b0) begin
            if (ab_v6.apu_we !== 1'b0) begin
                ctrl_wr_count = ctrl_wr_count + 1;
            end else begin
                if (ctrl_rd_seen >= CTRL_READS)
                    $fatal(1, "the program read a controller port more than %0d times",
                           CTRL_READS);
                if (v6_bus_din[0] !== ctrl_rd_exp[ctrl_rd_seen])
                    ctrl_data_err = ctrl_data_err + 1;
                if (v6_bus_din[7:1] !== 7'h00)
                    ctrl_data_err = ctrl_data_err + 1;
                ctrl_rd_seen = ctrl_rd_seen + 1;
            end
        end
    end
end

// ------------------------------------------------------------------ P1-2

always @(posedge clk) begin
    if (reset) begin
        dma_start_count = 0;
        dma_done_count = 0;
        dma_ack_count = 0;
        dma_wr_count = 0;
        dma_byte_index = 8'd0;
        dma_wr_index = 8'd0;
        dma_addr_err = 0;
        dma_data_err = 0;
        dma_unimpl_seen = 0;
        dma_ppu_addr_err = 0;
        dma_ppu_we_err = 0;
        expect_dma_data_valid = 1'b0;
        prev_dma_ack = 1'b0;
        prev_dma_ppu_cs = 1'b0;
    end else begin
        if (v6_dma_unimpl !== 1'b0)
            dma_unimpl_seen = dma_unimpl_seen + 1;
        if (v6_oam_dma_start !== 1'b0) begin
            dma_start_count = dma_start_count + 1;
            dma_byte_index = 8'd0;
            dma_wr_index = 8'd0;
        end
        if (v6_oam_dma_done !== 1'b0)
            dma_done_count = dma_done_count + 1;
        if (v6_dma_ack !== 1'b0) begin
            dma_ack_count = dma_ack_count + 1;
            if (prev_dma_ack !== 1'b0)
                $fatal(1, "two dma acks landed in adjacent clk");
            if (v6_oam_dma_cpu_read_ack !== 1'b1)
                $fatal(1, "the bus acked the dma port but the engine took no ack");
            if (v6_oam_dma_cpu_read_addr !== {8'h02, dma_byte_index})
                dma_addr_err = dma_addr_err + 1;
            if (v6_dma_din !== ab_v6.u_bus.ram_array[v6_oam_dma_cpu_read_addr[10:0]])
                dma_data_err = dma_data_err + 1;
            if (v6_oam_dma_index !== dma_byte_index)
                dma_data_err = dma_data_err + 1;
            dma_byte_index = dma_byte_index + 8'd1;
            dma_exp_rdata = v6_dma_din;
            expect_dma_data_valid = 1'b1;
        end
        if (v6_oam_dma_ppu_reg_cs !== 1'b0) begin
            if (prev_dma_ppu_cs !== 1'b0)
                $fatal(1, "the dma held the ppu register port for two clk in a row");
            dma_wr_count = dma_wr_count + 1;
            if (v6_oam_dma_ppu_reg_addr !== 3'd4)
                dma_ppu_addr_err = dma_ppu_addr_err + 1;
            if (v6_oam_dma_ppu_reg_we !== 1'b1)
                dma_ppu_we_err = dma_ppu_we_err + 1;
            if (expect_dma_data_valid === 1'b0)
                $fatal(1, "the dma wrote $2004 without a preceding acked read");
            if (v6_oam_dma_ppu_reg_dout !== dma_exp_rdata)
                dma_data_err = dma_data_err + 1;
            if (v6_oam_dma_ppu_reg_dout !== table1[dma_wr_index])
                dma_data_err = dma_data_err + 1;
            dma_wr_index = dma_wr_index + 8'd1;
            expect_dma_data_valid = 1'b0;
        end
        prev_dma_ppu_cs = v6_oam_dma_ppu_reg_cs;
        prev_dma_ack = v6_dma_ack;
    end
end

// ------------------------------------------------------------------ P1-4

always @(posedge clk) begin
    if (reset) begin
        irq_line_err = 0;
        irq_pending_err = 0;
        mapper_irq_high = 0;
        apu_irq_high = 0;
        last_irq_flag = 1'b0;
        irq_rise_count = 0;
        irq_fall_count = 0;
    end else begin
        if (v6_irq_line !== (v6_mapper_irq | v6_apu_irq_o))
            irq_line_err = irq_line_err + 1;
        if (ab_v6.u_cpu.dbg_irq_pending !== v6_irq_line)
            irq_pending_err = irq_pending_err + 1;
        if (v6_mapper_irq !== 1'b0)
            mapper_irq_high = mapper_irq_high + 1;
        if (v6_apu_irq_o !== 1'b0) begin
            apu_irq_high = apu_irq_high + 1;
            if (last_irq_flag === 1'b0) begin
                irq_rise_count = irq_rise_count + 1;
                last_irq_flag = 1'b1;
            end
        end else begin
            if (last_irq_flag === 1'b1) begin
                irq_fall_count = irq_fall_count + 1;
                last_irq_flag = 1'b0;
            end
        end
    end
end

// ------------------------------------------- P1-6 NMI / P1-10 CPU hygiene

always @(posedge clk or posedge reset) begin
    if (reset)
        last_nmi_level <= 1'b0;
    else
        last_nmi_level <= v6_nmi_o;
end

always @(posedge clk) begin
    if (reset) begin
        saw_reset_lo = 1'b0;
        saw_reset_hi = 1'b0;
        saw_first_fetch = 1'b0;
        saw_first_opcode = 1'b0;
        saw_fetch_bus = 1'b0;
        seen_main_loop = 1'b0;
        in_nmi_handler = 1'b0;
        in_irq_handler = 1'b0;
        nmi_rise_count = 0;
        nmi_entry_count = 0;
        reset_lo_addr = 16'h0000;
        reset_hi_addr = 16'h0000;
    end else begin
        case (ab_v6.u_cpu.dbg_state)
            7'd5: if (saw_reset_lo !== 1'b1) begin
                saw_reset_lo = 1'b1;
                reset_lo_addr = v6_bus_addr;
            end
            7'd6: if (saw_reset_hi !== 1'b1) begin
                saw_reset_hi = 1'b1;
                reset_hi_addr = v6_bus_addr;
            end
            7'd7: if (saw_first_fetch !== 1'b1) begin
                saw_first_fetch = 1'b1;
                if (ab_v6.u_cpu.dbg_pc !== MAIN_PROG)
                    $fatal(1, "first fetch pc got %04h", ab_v6.u_cpu.dbg_pc);
            end
            default: begin
            end
        endcase
        if (ab_v6.u_cpu.dbg_state === 7'd7) begin
            if (v6_bus_fire !== 1'b0) begin
                saw_fetch_bus = 1'b1;
            end else if ((saw_fetch_bus === 1'b1) && (saw_first_opcode !== 1'b1)) begin
                saw_first_opcode = 1'b1;
                if (ab_v6.u_cpu.dbg_opcode !== 8'h58)
                    $fatal(1, "first fetched opcode got %02x expected 58",
                           ab_v6.u_cpu.dbg_opcode);
            end
        end
        if ((v6_bus_fire !== 1'b0) && (v6_bus_addr === 16'hFFFA))
            nmi_entry_count = nmi_entry_count + 1;
        if (ab_v6.u_cpu.dbg_state >= 7'd7) begin
            if ((ab_v6.u_cpu.dbg_pc >= FAIL1) && (ab_v6.u_cpu.dbg_pc <= FAIL1 + 16'd2))
                $fatal(1, "the port 1 controller read failed, x=%02x p=%02x",
                       ab_v6.u_cpu.dbg_x, ab_v6.u_cpu.dbg_p);
            if ((ab_v6.u_cpu.dbg_pc >= FAIL2) && (ab_v6.u_cpu.dbg_pc <= FAIL2 + 16'd2))
                $fatal(1, "the port 2 controller read failed, x=%02x p=%02x",
                       ab_v6.u_cpu.dbg_x, ab_v6.u_cpu.dbg_p);
            if ((ab_v6.u_cpu.dbg_pc >= FAIL3) && (ab_v6.u_cpu.dbg_pc <= FAIL3 + 16'd2))
                $fatal(1, "the oam dma readback failed, x=%02x p=%02x",
                       ab_v6.u_cpu.dbg_x, ab_v6.u_cpu.dbg_p);
            if ((ab_v6.u_cpu.dbg_pc >= CHR_RB_FAIL) && (ab_v6.u_cpu.dbg_pc <= CHR_RB_FAIL + 16'd2))
                $fatal(1, "W3 a $2007 chr read returned a byte the program did not expect, a=%02x x=%02x p=%02x ppu v=%04h",
                       ab_v6.u_cpu.dbg_a, ab_v6.u_cpu.dbg_x, ab_v6.u_cpu.dbg_p,
                       ab_v6.u_ppu.v_addr);
            if (!((ab_v6.u_cpu.dbg_pc >= MAIN_PROG) && (ab_v6.u_cpu.dbg_pc <= main_prog_end)) &&
                !((ab_v6.u_cpu.dbg_pc >= NMI_HANDLER) && (ab_v6.u_cpu.dbg_pc <= nmi_end)) &&
                !((ab_v6.u_cpu.dbg_pc >= IRQ_HANDLER) && (ab_v6.u_cpu.dbg_pc <= irq_end)) &&
                !((ab_v6.u_cpu.dbg_pc >= FAIL1) && (ab_v6.u_cpu.dbg_pc <= FAIL1 + 16'd2)) &&
                !((ab_v6.u_cpu.dbg_pc >= FAIL2) && (ab_v6.u_cpu.dbg_pc <= FAIL2 + 16'd2)) &&
                !((ab_v6.u_cpu.dbg_pc >= FAIL3) && (ab_v6.u_cpu.dbg_pc <= FAIL3 + 16'd2)) &&
                !((ab_v6.u_cpu.dbg_pc >= CHR_RB_FAIL) && (ab_v6.u_cpu.dbg_pc <= CHR_RB_FAIL + 16'd2)))
                $fatal(1, "the cpu ran in an unprogrammed region, pc=%04h state=%0d p=%02x sp=%02x",
                       ab_v6.u_cpu.dbg_pc, ab_v6.u_cpu.dbg_state,
                       ab_v6.u_cpu.dbg_p, ab_v6.u_cpu.dbg_sp);
            if ((ab_v6.u_cpu.dbg_pc >= self_loop_addr) &&
                (ab_v6.u_cpu.dbg_pc < main_prog_end))
                seen_main_loop = 1'b1;
        end
        in_nmi_handler = (ab_v6.u_cpu.dbg_pc >= NMI_HANDLER) &&
                         (ab_v6.u_cpu.dbg_pc < nmi_end);
        in_irq_handler = (ab_v6.u_cpu.dbg_pc >= IRQ_HANDLER) &&
                         (ab_v6.u_cpu.dbg_pc < irq_end);
    end
end

// ------------------------------------------- frame / pixel / P0-3 bookkeeping

always @(posedge clk) begin
    #1;
    if (reset) begin
        frames_seen = 0;
        prev_frame_done = 1'b0;
        clk_count = 0;
        have_frame_mark = 1'b0;
        frame_delta_clk = 0;
        pix_index_mismatch = 0;
        pix_checked = 0;
        pix_cnt1 = 0;
        pix_cnt2 = 0;
        pix_cnt6 = 0;
        pix_other = 0;
        visible_pixels = 0;
        final_frame_active = 1'b0;
        prev_dot = 9'd340;
        f_chr_req = 0;
        f_chr_wr = 0;
        f_wr_final_bit13_bad = 0;
        f_local_bit13 = 0;
        f_local_bit12 = 0;
        f_final_bit13_bad = 0;
        f_addr_err = 0;
        f_max_final_addr = 0;
        last_f_chr_req = 0;
        last_f_chr_wr = 0;
        last_f_wr_final_bit13_bad = 0;
        last_f_local_bit13 = 0;
        last_f_local_bit12 = 0;
        last_f_final_bit13_bad = 0;
        last_f_addr_err = 0;
        last_f_max_final_addr = 0;
        pic_rom_cmp = 0;
        pic_rom_idx_diff = 0;
        pic_rom_geom_diff = 0;
        pic_rb_cmp = 0;
        pic_rb_idx_diff = 0;
        pic_rb_geom_diff = 0;
        pic_rb_tile0_diff = 0;
    end else begin
        clk_count = clk_count + 1;

        // P1-6
        if (v6_nmi_o !== (v6_vblank && ab_v6.u_ppu.control_reg[7]))
            $fatal(1, "P1-6 nmi_o got %b expected %b at %0d:%0d with ppuctrl=%02x",
                   v6_nmi_o, (v6_vblank && ab_v6.u_ppu.control_reg[7]),
                   v6_ppu_scanline, v6_ppu_dot, ab_v6.u_ppu.control_reg);
        if ((v6_nmi_o === 1'b1) && (last_nmi_level !== 1'b1))
            nmi_rise_count = nmi_rise_count + 1;

        if ((v6_frame_done === 1'b1) && (prev_frame_done !== 1'b1)) begin
            frames_seen = frames_seen + 1;
            if (have_frame_mark === 1'b1)
                frame_delta_clk = clk_count - frame_mark_clk;
            else
                have_frame_mark = 1'b1;
            frame_mark_clk = clk_count;
            last_f_chr_req = f_chr_req;
            last_f_chr_wr = f_chr_wr;
            last_f_wr_final_bit13_bad = f_wr_final_bit13_bad;
            last_f_local_bit13 = f_local_bit13;
            last_f_local_bit12 = f_local_bit12;
            last_f_final_bit13_bad = f_final_bit13_bad;
            last_f_addr_err = f_addr_err;
            last_f_max_final_addr = f_max_final_addr;
            f_chr_req = 0;
            f_chr_wr = 0;
            f_wr_final_bit13_bad = 0;
            f_local_bit13 = 0;
            f_local_bit12 = 0;
            f_final_bit13_bad = 0;
            f_addr_err = 0;
            f_max_final_addr = 0;
            if (frames_seen == FRAME_TARGET - 1)
                final_frame_active = 1'b1;
            if (frames_seen >= FRAME_TARGET)
                final_frame_active = 1'b0;
        end

        if (v6_pixel_valid === 1'b1) begin
            if ((v6_pixel_x !== v6_ppu_dot[7:0]) || (v6_pixel_y !== v6_ppu_scanline[7:0]))
                $fatal(1, "pixel coordinates got (%0d,%0d) expected (%0d,%0d)",
                       v6_pixel_x, v6_pixel_y, v6_ppu_dot[7:0], v6_ppu_scanline[7:0]);
            if (final_frame_active === 1'b1) begin
                expected_index = expected_pixel_index(v6_ppu_scanline, v6_ppu_dot);
                pix_checked = pix_checked + 1;
                if (v6_pixel_index !== expected_index)
                    pix_index_mismatch = pix_index_mismatch + 1;
                if (v6_ppu_dot !== prev_dot) begin
                    visible_pixels = visible_pixels + 1;
                    case (expected_index)
                        4'd1: pix_cnt1 = pix_cnt1 + 1;
                        4'd2: pix_cnt2 = pix_cnt2 + 1;
                        4'd6: pix_cnt6 = pix_cnt6 + 1;
                        default: pix_other = pix_other + 1;
                    endcase
                end
            end

            // ---------------------------------------------- rendered-picture pair
            // Two independent pictures, both compared against ab_v6's over the
            // whole final frame, at the 4-clk-per-dot clk granularity P0-5
            // already uses:
            //   chr_rom   must be IDENTICAL  (same program, writes refused,
            //                                  CHR ROM already holds the bytes)
            //   chr_ram_b must DIFFER        (same program code, complement
            //                                  image stored into CHR RAM)
            // A dropped write path makes chr_ram_b render what ab_v6 renders
            // BEFORE its own upload, so the "must differ" half is what stops
            // this whole file from passing on a dead $2007 strobe.
            if (final_frame_active === 1'b1) begin
                pic_rom_cmp = pic_rom_cmp + 1;
                pic_rb_cmp = pic_rb_cmp + 1;
                if ((r_pixel_valid !== v6_pixel_valid) ||
                    (r_pixel_x !== v6_pixel_x) || (r_pixel_y !== v6_pixel_y))
                    pic_rom_geom_diff = pic_rom_geom_diff + 1;
                if (r_pixel_index !== v6_pixel_index) begin
                    pic_rom_idx_diff = pic_rom_idx_diff + 1;
                    if (pic_rom_idx_diff === 1)
                        $display("    DIAG W1 chr_rom first index divergence at %0d:%0d: ab_v6=%0d chr_rom=%0d",
                                 v6_ppu_scanline, v6_ppu_dot, v6_pixel_index,
                                 r_pixel_index);
                end
                if ((rb_pixel_valid !== v6_pixel_valid) ||
                    (rb_pixel_x !== v6_pixel_x) || (rb_pixel_y !== v6_pixel_y))
                    pic_rb_geom_diff = pic_rb_geom_diff + 1;
                if (rb_pixel_index !== v6_pixel_index) begin
                    pic_rb_idx_diff = pic_rb_idx_diff + 1;
                    if (pic_rb_idx_diff === 1)
                        $display("    DIAG W1 chr_ram_b first index divergence at %0d:%0d: ab_v6=%0d chr_ram_b=%0d",
                                 v6_ppu_scanline, v6_ppu_dot, v6_pixel_index,
                                 rb_pixel_index);
                end
                // Non-vacuity on top of the global count: the difference has to
                // be concentrated where the two upload values differ, i.e. on
                // the tiles the program wrote, and the leftmost 16 columns of
                // every visible line are exactly where BG tile 0 and tile 1 live.
                if ((rb_pixel_index !== v6_pixel_index) &&
                    (v6_ppu_scanline < 9'd240) && (v6_ppu_dot < 9'd16))
                    pic_rb_tile0_diff = pic_rb_tile0_diff + 1;
            end
        end
        prev_dot = v6_ppu_dot;
        prev_frame_done = v6_frame_done;
    end
end

// ---------------------------------------------- phase 2: P0-7 bank switch
//
// P0-7(a) translation model, per ce while chr_req is high:
//     expected_final = (tb_chr_bank_model << 10) | (local_chr_addr & 14'h03FF)
// and tb_chr_bank_model is the 8-bit R0 REGISTER value, built from the observed
// cart write, never from the DUT's register:
//     tb_chr_bank_model = {mapper_write_data[7:1], 1'b0}
// nes_mapper_mmc3.v:208 latches exactly that, because R0 is a 2 KiB register and
// bit 0 is the sub-window select that lives in local chr_addr[11], not in the
// register.  The model update is a NON-BLOCKING assignment and the check reads
// m_bank_model, so at the clk edge of the write pulse the check still sees the
// OLD model against the OLD chr_final_addr, and from the next clk on it sees the
// new model against the new chr_final_addr.  Nothing here can race.
//
// P0-7(b) the tile-0 region is scanline 0..239, column 0..7.  Only nametable
// bytes 0 and 1 are non-zero, so that region is always BG tile 0 and the visible
// sprite is at x=8, i.e. outside it.  Buckets are gated on m_ppu_bg_enable so
// pre-render frames (PPUCTRL written after PPUMASK) cannot dilute them.
//
// P0-7(c) bank $41 -> register $20 -> chr_final_addr[16] = reg[6] = 1.  That is
// the 17th bit of a 17-bit address, one net downstream of the mapper, so a
// testbench that indexed its own model with 16 bits could not produce it.

always @(posedge clk) begin
    if (reset) begin
        m_frames_seen = 0;
        m_post_switch_frames = 0;
        m_prev_frame_done = 1'b0;
        m_prev_dot = 9'd340;
        m_bank_epoch = -1;
        m_bank_model = 8'h00;
        m_bank_writes = 0;
        m_chr_req_total = 0;
        m_cart_wr_total = 0;
        m_fail_hits = 0;
        m_seen_self_loop = 1'b0;
        for (z = 0; z < MMC3_BANK_STEPS; z = z + 1) begin
            m_addr_checks[k] = 0;
            m_addr_err[k] = 0;
            m_bit16_seen[k] = 0;
            m_first_hi[k] = 0;
            m_first_hi_ok[k] = 1'b0;
            m_tile0_tot[k] = 0;
            m_tile0_exp[k] = 0;
            m_tile0_oth[k] = 0;
            m_bank_data[k] = 8'h00;
            m_bank_reg[k] = 8'h00;
            m_bank_ok[k] = 1'b0;
            m_bank_sl[k] = 16'h0000;
        end
    end else begin
        if ((m_frame_done === 1'b1) && (m_prev_frame_done !== 1'b1)) begin
            m_frames_seen = m_frames_seen + 1;
            if (m_bank_epoch == (MMC3_BANK_STEPS - 1))
                m_post_switch_frames = m_post_switch_frames + 1;
        end
        m_prev_frame_done = m_frame_done;

        // the cpu must stay inside its own image
        if (m_cpu_state >= 7'd7) begin
            if ((m_cpu_state >= 7'd7) &&
                !((chr_mmc3.u_cpu.dbg_pc >= MAIN_PROG) &&
                  (chr_mmc3.u_cpu.dbg_pc <= m_main_prog_end)) &&
                !((chr_mmc3.u_cpu.dbg_pc >= NMI_HANDLER) &&
                  (chr_mmc3.u_cpu.dbg_pc <= m_nmi_end)) &&
                !((chr_mmc3.u_cpu.dbg_pc >= IRQ_HANDLER) &&
                  (chr_mmc3.u_cpu.dbg_pc <= m_irq_end)) &&
                !((chr_mmc3.u_cpu.dbg_pc >= MMC3_FAIL) &&
                  (chr_mmc3.u_cpu.dbg_pc <= MMC3_FAIL + 16'd2)))
                $fatal(1, "the mmc3 cpu ran in an unprogrammed region, pc=%04h state=%0d p=%02x sp=%02x",
                       chr_mmc3.u_cpu.dbg_pc, m_cpu_state,
                       chr_mmc3.u_cpu.dbg_p, chr_mmc3.u_cpu.dbg_sp);
            if ((chr_mmc3.u_cpu.dbg_pc >= MMC3_FAIL) &&
                (chr_mmc3.u_cpu.dbg_pc <= MMC3_FAIL + 16'd2)) begin
                m_fail_hits = m_fail_hits + 1;
                $fatal(1, "the mmc3 program entered its fail loop at %04h, a=%02x x=%02x p=%02x",
                       chr_mmc3.u_cpu.dbg_pc, chr_mmc3.u_cpu.dbg_a,
                       chr_mmc3.u_cpu.dbg_x, chr_mmc3.u_cpu.dbg_p);
            end
            if ((chr_mmc3.u_cpu.dbg_pc >= m_self_loop_addr) &&
                (chr_mmc3.u_cpu.dbg_pc < m_main_prog_end))
                m_seen_self_loop = 1'b1;
        end
    end
end

always @(posedge clk) begin
    if (reset) begin
        m_bank_epoch = -1;
        m_bank_model = 8'h00;
        m_bank_writes = 0;
        m_cart_wr_total = 0;
    end else begin
        if (m_mapper_write_pulse !== 1'b0) begin
            m_cart_wr_total = m_cart_wr_total + 1;
            if (m_mapper_write_addr == 16'h8001) begin
                if (m_bank_epoch < (MMC3_BANK_STEPS - 1)) begin
                    m_bank_data[m_bank_epoch + 1] = m_mapper_write_data;
                    m_bank_reg[m_bank_epoch + 1] = {m_mapper_write_data[7:1], 1'b0};
                    // "during vblank" is the scanline PERIOD, not the latch:
                    // nes_ppu2c02 clears its vblank register on every $2002 read
                    // and only re-asserts it at (241,0), and the program has just
                    // read $2002 to get there, so the vblank output is already
                    // low at this clk by design.  Scanlines 241..260 dots 1..256
                    // is the window, and dot < 257 additionally keeps the write
                    // out of the 35-ce sprite shadow build that starts at 257.
                    m_bank_ok[m_bank_epoch + 1] =
                        (m_ppu_scanline >= 9'd241) && (m_ppu_scanline <= 9'd260) &&
                        (m_ppu_dot < 9'd257);
                    m_bank_sl[m_bank_epoch + 1] = {m_ppu_scanline[7:0], m_ppu_dot[7:0]};
                end
                m_bank_epoch <= m_bank_epoch + 1;
                m_bank_model <= {m_mapper_write_data[7:1], 1'b0};
                m_bank_writes <= m_bank_writes + 1;
            end
        end
    end
end

always @(posedge clk) begin
    if (reset) begin
        m_chr_req_total = 0;
        for (z = 0; z < MMC3_BANK_STEPS; z = z + 1) begin
            m_addr_checks[z] = 0;
            m_addr_err[z] = 0;
            m_bit16_seen[z] = 0;
            m_first_hi[z] = 0;
            m_first_hi_ok[z] = 1'b0;
        end
    end else if (chr_mmc3.ce_ppu) begin
        m_write_on_port = 1'b0;

        // ------------------------------------------------ W2 WRITE BEATS
        // Measured first, for the same reason as the phase 1 monitor: the write
        // owns the mapper port on its beat, so the read check below has to know
        // whether chr_final_addr is carrying a write address this ce.  The point
        // of the whole group is that m_chr_final_addr, not m_chr_waddr, is
        // where the byte goes, and m_chr_final_addr moves with r0.
        if (m_chr_we !== 1'b0) begin
            m_wr_beats = m_wr_beats + 1;
            if (m_chr_req !== 1'b0) begin
                m_wr_req_clash = m_wr_req_clash + 1;
                m_write_on_port = 1'b1;
                if (m_chr_wr_displayed === 1'b1)
                    m_wr_clash_visible = m_wr_clash_visible + 1;
            end
            if (m_chr_final_addr[13] !== 1'b0)
                m_wr_bit13_bad = m_wr_bit13_bad + 1;
            m_wr_exp_final =
                ({8'b0, chr_mmc3_window_bank(m_chr_waddr, m_bank_model)} << 10) |
                (m_chr_waddr & 14'h03FF);
            m_wr_checks = m_wr_checks + 1;
            if (m_chr_final_addr !== m_wr_exp_final) begin
                m_wr_addr_err = m_wr_addr_err + 1;
                if (m_wr_addr_err < 4)
                    $fatal(1, "W2 write beat chr_final_addr %05h != tb model %05h (local chr_waddr %04h, model reg %02h)",
                           m_chr_final_addr, m_wr_exp_final, m_chr_waddr,
                           m_bank_model);
            end
            if (m_chr_waddr !== chr_mmc3.u_ppu.v_addr[13:0]) begin
                m_wr_addr_err = m_wr_addr_err + 1;
                if (m_wr_addr_err < 4)
                    $fatal(1, "W2 write beat chr_waddr %04h is not the pre-increment ppu v_addr %04h",
                           m_chr_waddr, chr_mmc3.u_ppu.v_addr);
            end
            if (m_chr_wdata !== chr_mmc3.u_ppu.reg_din) begin
                m_wr_addr_err = m_wr_addr_err + 1;
                if (m_wr_addr_err < 4)
                    $fatal(1, "W2 write beat chr_wdata %02h is not the ppu reg_din %02h",
                           m_chr_wdata, chr_mmc3.u_ppu.reg_din);
            end
            if (m_mapper_chr_ram_we !== 1'b1)
                m_wr_not_accepted = m_wr_not_accepted + 1;
            if ((m_wr_prev !== 1'b0) && (m_chr_we !== 1'b0))
                m_wr_consec = m_wr_consec + 1;
            // The three writes are told apart by the model address they land on.
            // Recording the byte the array HELD BEFORE the store is what proves
            // the store really changed that one cell and nothing else.
            if (m_chr_final_addr == MMC3_W2_ADDR_LOW_EXP) begin
                m_wr_low_hit = m_wr_low_hit + 1;
                m_wr_low_before = m_chr_mem[MMC3_W2_ADDR_LOW_EXP];
            end else if (m_chr_final_addr == MMC3_W2_ADDR_HIGH_EXP) begin
                m_wr_high_hit = m_wr_high_hit + 1;
                m_wr_high_before = m_chr_mem[MMC3_W2_ADDR_HIGH_EXP];
            end else if (m_chr_final_addr == MMC3_W2_ADDR_ODD_EXP) begin
                m_wr_odd_hit = m_wr_odd_hit + 1;
                m_wr_odd_before = m_chr_mem[MMC3_W2_ADDR_ODD_EXP];
            end else begin
                m_wr_addr_err = m_wr_addr_err + 1;
            end
        end
        m_wr_prev = m_chr_we;

        // READ BEATS, unchanged except that a beat the write has taken over is
        // counted as a read-on-write beat and excluded from the read model, for
        // the same reason P0-2 spells out.
        if (m_chr_req !== 1'b0) begin
            m_chr_req_total = m_chr_req_total + 1;
            if (m_write_on_port === 1'b0) begin
                if ((m_bank_epoch >= 0) && (m_bank_epoch < MMC3_BANK_STEPS)) begin
                    m_addr_checks[m_bank_epoch] = m_addr_checks[m_bank_epoch] + 1;
                    if (m_first_hi_ok[m_bank_epoch] !== 1'b1) begin
                        m_first_hi_ok[m_bank_epoch] = 1'b1;
                        m_first_hi[m_bank_epoch] = m_chr_final_addr[16:10];
                    end
                    if (m_chr_final_addr !==
                        (({9'b0, m_bank_model} << 10) | (m_chr_addr & 14'h03FF))) begin
                        m_addr_err[m_bank_epoch] = m_addr_err[m_bank_epoch] + 1;
                        if (m_addr_err[m_bank_epoch] < 4)
                            $fatal(1, "P0-7 chr_final_addr %05h != tb model %05h (local %04h, model reg %02h, epoch %0d)",
                                   m_chr_final_addr,
                                   (({9'b0, m_bank_model} << 10) | (m_chr_addr & 14'h03FF)),
                                   m_chr_addr, m_bank_model, m_bank_epoch);
                    end
                    if (m_chr_final_addr[16] !== 1'b0)
                        m_bit16_seen[m_bank_epoch] = m_bit16_seen[m_bank_epoch] + 1;
                end
            end
        end
    end
end

// The bus-side expected count for chr_mmc3, built the same way as the phase 1
// one: a $2007 write whose PRE-increment v_addr is still in the CHR half.
always @(posedge clk) begin
    if (reset)
        m_wr_exp_total = 0;
    else if ((m_bus_fire !== 1'b0) && (m_bus_we !== 1'b0) &&
             (m_sel_ppu === 1'b1) && (chr_mmc3.u_ppu.reg_addr == 3'd7) &&
             (chr_mmc3.u_ppu.v_addr < 15'h2000))
        m_wr_exp_total = m_wr_exp_total + 1;
end

always @(posedge clk) begin
    if (reset) begin
        for (z = 0; z < MMC3_BANK_STEPS; z = z + 1) begin
            m_tile0_tot[z] = 0;
            m_tile0_exp[z] = 0;
            m_tile0_oth[z] = 0;
        end
    end else begin
        if (m_pixel_valid === 1'b1) begin
            if ((m_pixel_x !== m_ppu_dot[7:0]) || (m_pixel_y !== m_ppu_scanline[7:0]))
                $fatal(1, "P0-7 mmc3 pixel coordinates got (%0d,%0d) expected (%0d,%0d)",
                       m_pixel_x, m_pixel_y, m_ppu_dot[7:0], m_ppu_scanline[7:0]);
            if ((m_prev_dot !== m_ppu_dot) && (m_ppu_bg_enable === 1'b1) &&
                (m_ppu_scanline < 9'd240) && (m_ppu_dot < 9'd8) &&
                (m_bank_epoch >= 0) && (m_bank_epoch < MMC3_BANK_STEPS)) begin
                m_tile0_tot[m_bank_epoch] = m_tile0_tot[m_bank_epoch] + 1;
                if (m_pixel_index === m_exp_index[m_bank_epoch])
                    m_tile0_exp[m_bank_epoch] = m_tile0_exp[m_bank_epoch] + 1;
                else
                    m_tile0_oth[m_bank_epoch] = m_tile0_oth[m_bank_epoch] + 1;
            end
        end
        m_prev_dot = m_ppu_dot;
    end
end

// ----------------------------------------------------------------- P0-8
//
// ab_v5 is not checked: nes_system_v5 has no external CHR port, so there is no
// chr_req to collide on there.

always @(posedge clk) begin
    if (reset) begin
        ab_req_prev = 1'b0;
        m_req_prev = 1'b0;
        ab_we_prev = 1'b0;
        m_we_prev = 1'b0;
        ab_prev_win = 2'd0;
        ab_req_beats = 0;
        ab_req_consec = 0;
        ab_consec_arm = 0;
        ab_consec_arm_vs_bg = 0;
        ab_consec_arm_vs_sp = 0;
        ab_consec_bg = 0;
        ab_consec_sp = 0;
        ab_consec_noread = 0;
        ab_consec_rr = 0;
        ab_consec_arm_first_bg = 0;
        ab_we_consec = 0;
        ab_bgsp_beats = 0;
        ab_bgsp_clash = 0;
        m_req_beats = 0;
        m_req_consec = 0;
        m_we_consec = 0;
        m_bgsp_beats = 0;
        m_bgsp_clash = 0;
    end else begin
        if (ab_v6.ce_ppu) begin
            ab_req_beats = ab_req_beats + 1;
            if ((ab_req_prev !== 1'b0) && (v6_chr_req !== 1'b0)) begin
                ab_req_consec = ab_req_consec + 1;
                // attribute the pair to the master that drove chr_addr on the
                // SECOND beat, using the ppu's own selection expression
                if (rb_arm !== 1'b0) begin
                    ab_consec_arm = ab_consec_arm + 1;
                    if (ab_prev_win == 2'd3)
                        ab_consec_arm_vs_bg = ab_consec_arm_vs_bg + 1;
                    else if (ab_prev_win == 2'd2)
                        ab_consec_arm_vs_sp = ab_consec_arm_vs_sp + 1;
                    else
                        ab_consec_rr = ab_consec_rr + 1;
                end else if (ab_prev_win == 2'd2) begin
                    ab_consec_sp = ab_consec_sp + 1;
                end else begin
                    ab_consec_bg = ab_consec_bg + 1;
                end
                // the first beat was the arm and the second beat is a fetch
                // master: the same collision, counted from the other side
                if ((ab_prev_win == 2'd1) && (rb_arm === 1'b0))
                    ab_consec_arm_first_bg = ab_consec_arm_first_bg + 1;
                // NEITHER beat was a read arm.  This is the only case the old
                // "never two consecutive ce" invariant covered, and it is the
                // case a run with chr_rd_arm tied to 1'b0 would have measured.
                if ((ab_prev_win != 2'd1) && (rb_arm === 1'b0))
                    ab_consec_noread = ab_consec_noread + 1;
            end
            ab_req_prev = v6_chr_req;
            ab_prev_win = (rb_arm !== 1'b0) ? 2'd1 :
                          ((ab_v6.u_ppu.g_chr_external.sp_bus_sel !== 1'b0) ? 2'd2 :
                           ((ab_bg_chr_req !== 1'b0) ? 2'd3 : 2'd0));
        end
        if (chr_mmc3.ce_ppu) begin
            m_req_beats = m_req_beats + 1;
            if ((m_req_prev !== 1'b0) && (m_chr_req !== 1'b0))
                m_req_consec = m_req_consec + 1;
            m_req_prev = m_chr_req;
        end
        if (ab_bg_chr_req !== 1'b0) begin
            ab_bgsp_beats = ab_bgsp_beats + 1;
            if (ab_sp_chr_req !== 1'b0) begin
                ab_bgsp_clash = ab_bgsp_clash + 1;
                $fatal(1, "P0-8 ab_v6 background and sprite chr_req were both high");
            end
        end
        if (ab_sp_chr_req !== 1'b0) begin
            ab_bgsp_beats = ab_bgsp_beats + 1;
            if (ab_bg_chr_req !== 1'b0) begin
                ab_bgsp_clash = ab_bgsp_clash + 1;
                $fatal(1, "P0-8 ab_v6 sprite and background chr_req were both high");
            end
        end
        if (m_bg_chr_req !== 1'b0) begin
            m_bgsp_beats = m_bgsp_beats + 1;
            if (m_sp_chr_req !== 1'b0) begin
                m_bgsp_clash = m_bgsp_clash + 1;
                $fatal(1, "P0-8 chr_mmc3 background and sprite chr_req were both high");
            end
        end
        if (m_sp_chr_req !== 1'b0) begin
            m_bgsp_beats = m_bgsp_beats + 1;
            if (m_bg_chr_req !== 1'b0) begin
                m_bgsp_clash = m_bgsp_clash + 1;
                $fatal(1, "P0-8 chr_mmc3 sprite and background chr_req were both high");
            end
        end
        // The write strobe shares the mapper port with the read arbiter, so the
        // new path could in principle collide with a fetch or run long.  chr_we
        // must be one ce_ppu wide: the counter only advances when this beat AND
        // the previous ce beat both carried a strobe.
        if (ab_v6.ce_ppu) begin
            if ((ab_we_prev !== 1'b0) && (v6_chr_we !== 1'b0)) begin
                ab_we_consec = ab_we_consec + 1;
                $fatal(1, "P0-8 ab_v6 chr_we was high on two consecutive ce");
            end
            ab_we_prev = v6_chr_we;
        end
        if (chr_mmc3.ce_ppu) begin
            if ((m_we_prev !== 1'b0) && (m_chr_we !== 1'b0)) begin
                m_we_consec = m_we_consec + 1;
                $fatal(1, "P0-8 chr_mmc3 chr_we was high on two consecutive ce");
            end
            m_we_prev = m_chr_we;
        end
    end
end

// ----------------------------------------------------- W3 $2007 CHR read-back
//
// One monitor for the whole read path, driven by the two net events it needs:
//   rb_arm   the ce on which the read address rides chr_addr
//   rb_read  the ce on which the two-cycle $2007 access completes and the cpu
//            latches bus_din
// They are adjacent ce by construction, so the block below runs in this order:
// consume a pending arm, handle the read beat, then raise a new arm.
//
// Nothing here compares against chr_rdata itself.  Every expectation is built
// from the TB's OWN bank model and the PPU's OWN v_addr, and the byte side is
// compared against the TB's OWN chr_mem, which the program can only have changed
// through chr_we && mapper_chr_ram_we.  Asserting
// returned == chr_mem[u_ppu.v_addr & 0x1fff] would be circular: the address the
// ppu asked for is the address the check would look up.
always @(posedge clk) begin
    if (reset) begin
        rb_arm_beats = 0;
        rb_arm_data_checks = 0;
        rb_arm_data_err = 0;
        rb_read_beats = 0;
        rb_read_checks = 0;
        rb_read_err = 0;
        rb_noprev = 0;
        rb_armed_missing = 0;
        rb_stranded = 0;
        rb_addr_err = 0;
        rb_arm_addr_err = 0;
        rb_ramwe_bad = 0;
        rb_we_overlap = 0;
        rb_coll_bg = 0;
        rb_coll_sp = 0;
        rb_race_skip = 0;
        rb_vis_bad = 0;
        rb_min_sl = 999;
        rb_max_sl = 9'd0;
        rb_arms_mask0 = 0;
        rb_arms_mask1 = 0;
        rb_arms_vblank = 0;
        rb_loopa_arms = 0;
        rb_loopb_arms = 0;
        rb_pend_addr_q <= 17'd0;
        rb_pend_byte_q <= 8'h00;
        rb_pend_valid_q <= 1'b0;
        rb_prev_addr_q <= 17'd0;
        rb_prev_rdata_q <= 8'h00;
        rb_prev_valid_q <= 1'b0;
    end else if (ab_v6.ce_ppu) begin

        // ---- an arm raised on the previous ce has to land HERE ----
        if (rb_pend_valid_q !== 1'b0) begin
            if (rb_read !== 1'b1) begin
                rb_stranded = rb_stranded + 1;
                $fatal(1, "W3-1 an armed $2007 chr read was not followed by a read beat on the next ce_ppu (bus_fire=%b we=%b sel_ppu=%b reg=%0d v=%04h armed=%b)",
                       v6_bus_fire, v6_bus_we, v6_sel_ppu, v6_ppu_reg_addr,
                       ab_v6.u_ppu.v_addr, rb_armed);
            end
            // The external memory captured chr_mem[the arm's address] on the
            // arm edge, so chr_rdata must ALREADY hold it one ce later, which is
            // this edge.  That is the whole zero-slack lead the rtl comment
            // talks about, measured from the outside.
            if (((chr_wq0_v !== 1'b0) && (chr_wq0 === rb_pend_addr_q)) ||
                ((chr_wq1_v !== 1'b0) && (chr_wq1 === rb_pend_addr_q))) begin
                rb_race_skip = rb_race_skip + 1;
            end else begin
                rb_arm_data_checks = rb_arm_data_checks + 1;
                if (chr_rdata !== rb_pend_byte_q) begin
                    rb_arm_data_err = rb_arm_data_err + 1;
                    if (rb_arm_data_err < 5)
                        $fatal(1, "W3-2 chr_rdata is %02h one ce after the arm, tb chr_mem[%05h] is %02h",
                               chr_rdata, rb_pend_addr_q, rb_pend_byte_q);
                end
            end
            rb_pend_valid_q <= 1'b0;
        end

        // ---- the completed $2007 CHR read ----
        if (rb_read !== 1'b0) begin
            rb_read_beats = rb_read_beats + 1;
            if (rb_armed !== 1'b1) begin
                rb_armed_missing = rb_armed_missing + 1;
                $fatal(1, "W3-1 a $2007 chr read beat at v=%04h saw chr_rd_armed_q=0, the arm never fired (%0d read arms so far in this run).  DIAGNOSIS IF THIS IS THE FIRST FAILURE: the arm did not fire at all, not that it fired late, because in nes_system_v6 ppu_chr_rd_arm = sel_ppu && !cpu_we && (ppu_addr==3'd7) && cpu_bus_ready && (div_phase==4'd8), and this arm beat is 4 clk ahead of the $2007 read beat the cpu latches, so chr_rd_armed_q must already be 1 by the time that read beat retires.  A zero here therefore means one of those five terms changed: the sel_ppu decode, the !cpu_we read direction, the ppu_addr==3'd7 register select, cpu_bus_ready, or the div_phase==4'd8 phase.  This arm must NOT be rebuilt out of ppu_req/ppu_we: only bus_req is cleared by !cpu_active (nes_cpu6502.v:755), while bus_addr and bus_we are not, and ppu_req derives from cpu_req (nes_cpu_bus.v:189), so a ppu_req based arm is structurally zero at div_phase==4'd8 because ppu_req is high on the div_phase==0 clk ONLY.  Every $2007 chr read on this board would then return the fail-safe 8'h00, which is what the program's own compare loop below reports next.  This is an rtl fix in nes_system_v6 and is outside this file's write scope",
                       ab_v6.u_ppu.v_addr, rb_arm_beats);
            end
            if (rb_prev_valid_q !== 1'b1) begin
                // the very first $2007 chr read of the run: there is no previous
                // byte for the read buffer to be holding yet
                rb_noprev = rb_noprev + 1;
            end else begin
                rb_read_checks = rb_read_checks + 1;
                // the byte the cpu latched is the byte chr_rdata held at the
                // previous $2007 beat (the 2C02 read-buffer skew, measured)
                if (v6_bus_din !== rb_prev_rdata_q) begin
                    rb_read_err = rb_read_err + 1;
                    if (rb_read_err < 5)
                        $fatal(1, "W3-2 the cpu latched %02h, chr_rdata held %02h at the previous $2007 beat",
                               v6_bus_din, rb_prev_rdata_q);
                end
                // and that byte is the model's byte at the address the previous
                // arm carried, so the whole chain is external
                if (rb_prev_rdata_q !== chr_mem[rb_prev_addr_q]) begin
                    rb_read_err = rb_read_err + 1;
                    if (rb_read_err < 5)
                        $fatal(1, "W3-2 the cpu's byte %02h is not tb chr_mem[%05h] = %02h",
                               rb_prev_rdata_q, rb_prev_addr_q,
                               chr_mem[rb_prev_addr_q]);
                end
            end
            rb_prev_rdata_q <= chr_rdata;
            rb_prev_addr_q <= rb_pend_addr_q;
            rb_prev_valid_q <= 1'b1;
        end else if (rb_armed !== 1'b0) begin
            // chr_rd_armed_q is set and the next completed $2007 access was not
            // a read, so the arm was consumed by something it was not meant for
            rb_stranded = rb_stranded + 1;
            $fatal(1, "W3-1 an armed $2007 chr read was cleared by a non-read $2007 access (reg=%0d we=%b v=%04h)",
                   v6_ppu_reg_addr, v6_bus_we, ab_v6.u_ppu.v_addr);
        end

        // ---- a new read arm ----
        if (rb_arm !== 1'b0) begin
            rb_arm_beats = rb_arm_beats + 1;
            // the read address has to be on the PPU's own chr_addr port, and the
            // port has to come out of the mapper as the tb's own translation of
            // the PPU's own v_addr.  chr_final_addr is one net downstream of
            // mapper_ppu_addr, so neither comparison is circular.
            if (ab_v6.u_ppu.chr_addr !== ab_v6.u_ppu.v_addr[13:0]) begin
                rb_arm_addr_err = rb_arm_addr_err + 1;
                if (rb_arm_addr_err < 5)
                    $fatal(1, "W3-3 on a read arm chr_addr is %04h, not the ppu's own v_addr %04h",
                           ab_v6.u_ppu.chr_addr, ab_v6.u_ppu.v_addr[13:0]);
            end
            if (v6_chr_final_addr !==
                (({13'b0, tb_chr_bank_model} << 13) |
                 (ab_v6.u_ppu.v_addr[13:0] & 14'h1FFF))) begin
                rb_addr_err = rb_addr_err + 1;
                if (rb_addr_err < 5)
                    $fatal(1, "W3-3 on a read arm chr_final_addr is %05h, tb model is %05h (local chr_addr %04h, ppu v_addr %04h)",
                           v6_chr_final_addr,
                           (({13'b0, tb_chr_bank_model} << 13) |
                            (ab_v6.u_ppu.v_addr[13:0] & 14'h1FFF)),
                           ab_v6.u_ppu.chr_addr, ab_v6.u_ppu.v_addr);
            end
            // a read arm is raised only for a cpu READ, so it can never ride the
            // same ce as the $2007 write strobe and can never raise the store
            if (v6_chr_we !== 1'b0)
                rb_we_overlap = rb_we_overlap + 1;
            if (v6_mapper_chr_ram_we !== 1'b0)
                rb_ramwe_bad = rb_ramwe_bad + 1;
            // the collision the contract names, counted not argued
            if (ab_bg_chr_req !== 1'b0)
                rb_coll_bg = rb_coll_bg + 1;
            if (ab_sp_chr_req !== 1'b0)
                rb_coll_sp = rb_coll_sp + 1;
            // loop B runs with rendering on inside vblank, loop A with PPUMASK=$00
            if ((ab_v6.u_ppu.scanline >= 9'd240) &&
                (ab_v6.u_ppu.scanline <= 9'd260)) begin
                rb_arms_vblank = rb_arms_vblank + 1;
                rb_loopb_arms = rb_loopb_arms + 1;
            end else begin
                rb_loopa_arms = rb_loopa_arms + 1;
            end
            if (ab_v6.u_ppu.mask_reg[2] === 1'b0)
                rb_arms_mask0 = rb_arms_mask0 + 1;
            else
                rb_arms_mask1 = rb_arms_mask1 + 1;
            if (ab_v6.u_ppu.scanline < rb_min_sl)
                rb_min_sl = ab_v6.u_ppu.scanline;
            if (ab_v6.u_ppu.scanline > rb_max_sl)
                rb_max_sl = ab_v6.u_ppu.scanline;
            if (rb_vis_ok !== 1'b1) begin
                rb_vis_bad = rb_vis_bad + 1;
                $fatal(1, "W3-10 a $2007 chr read arm landed on scanline %0d dot %0d, outside the provably invisible set (240-260, or bg_pa_enable low with sprites off); mask=%02h bg_pa_enable=%b",
                       ab_v6.u_ppu.scanline, ab_v6.u_ppu.dot,
                       ab_v6.u_ppu.mask_reg, ab_v6.u_ppu.bg_pa_enable);
            end
            rb_pend_addr_q <= (({13'b0, tb_chr_bank_model} << 13) |
                              (ab_v6.u_ppu.v_addr[13:0] & 14'h1FFF));
            rb_pend_byte_q <= chr_mem[({13'b0, tb_chr_bank_model} << 13) |
                                     (ab_v6.u_ppu.v_addr[13:0] & 14'h1FFF)];
            rb_pend_valid_q <= 1'b1;
        end
    end
end

// ----------------------------------------------------------------- P1-5
//
// The entry length is measured, not asserted in prose: the monitor latches the
// cpu the clk it is in ST_FETCH (7) with irq_i high, then counts ce_cpu until
// ST_INT_VEC_HI (59).  The real 6502 IRQ sequence is 7 cycles
// (fetch, dummy, push hi, push lo, push p, vector lo, vector hi) and that is
// exactly the state list the monitor records, so m_irq_entry_* is a measurement
// of the 7-cycle entry and m_irq_seq_bad catches any other ordering.

always @(posedge clk) begin
    integer d;
    if (reset) begin
        m_irq_line_err = 0;
        m_irq_pending_err = 0;
        m_irq_high = 0;
        m_irq_rise = 0;
        m_irq_prev = 1'b0;
        m_irq_vec_fetch = 0;
        m_irq_entries = 0;
        m_irq_entry_bad = 0;
        m_irq_entry_min = 0;
        m_irq_entry_max = 0;
        m_irq_entry_stall = 0;
        m_irq_seq_bad = 0;
        m_irq_active = 1'b0;
        m_irq_ce_n = 0;
        m_irq_seq_n = 0;
        m_irq_masked = 0;
        m_prev_fire_state = 7'd0;
        m_bad_ce_n = 0;
        for (z = 0; z < 8; z = z + 1)
            m_irq_seq[z] = 7'd0;
        for (z = 0; z < 16; z = z + 1)
            m_entry_hist[z] = 0;
        for (z = 0; z < 16; z = z + 1)
            m_bad_seq[z] = 7'd0;
    end else begin
        if (m_irq_line !== (m_mapper_irq | m_apu_irq_o))
            m_irq_line_err = m_irq_line_err + 1;
        if (chr_mmc3.u_cpu.dbg_irq_pending !== m_irq_line)
            m_irq_pending_err = m_irq_pending_err + 1;
        if (m_irq_line !== 1'b0) begin
            m_irq_high = m_irq_high + 1;
            if (m_irq_prev !== 1'b1)
                m_irq_rise = m_irq_rise + 1;
        end
        m_irq_prev = m_irq_line;
        if (m_bus_fire !== 1'b0) begin
            if (m_bus_addr == 16'hFFFE)
                m_irq_vec_fetch = m_irq_vec_fetch + 1;
        end

        if (m_bus_fire !== 1'b0) begin
            if (m_bus_addr == 16'hFFFE)
                m_irq_vec_fetch = m_irq_vec_fetch + 1;
            // The entry is counted in BUS-FIRE cycles, which is the only cycle
            // granularity this cpu has: nes_cpu6502 advances state_reg on
            // bus_fire and its own cpu_cycle output increments there too.
            // ce_cpu is NOT a cycle counter, because a read state with
            // READ_WAIT_CYCLES=1 spans two ce_cpu and would report a 10 "cycle"
            // entry.  Seven bus-fire cycles is the real 6502 IRQ sequence:
            // opcode fetch / dummy / push hi / push lo / push p / vector lo /
            // vector hi.
            //
            // The entry is anchored on the COMMIT transition (a bus fire in
            // ST_INT_DUMMY2 whose immediately preceding bus fire was in
            // ST_FETCH), not on "some fetch while the line is high".  Every
            // instruction is at least two cycles, so ST_FETCH is never followed
            // by ST_FETCH, and a fetch that is masked by the I flag (the RTI
            // inside the handler) goes to the RTI states instead of 54 and is
            // correctly not counted.  The preceding ST_FETCH cycle is cycle 1.
            if ((m_irq_line !== 1'b0) && (m_cpu_state == 7'd54) &&
                (m_prev_fire_state == 7'd7) && (m_irq_active !== 1'b1)) begin
                m_irq_active = 1'b1;
                m_irq_ce_n = 1;
                m_irq_seq_n = 1;
                m_irq_seq[0] = 7'd7;
                if (chr_mmc3.u_cpu.dbg_p[2] !== 1'b0)
                    m_irq_masked = m_irq_masked + 1;
            end
            if (m_irq_active !== 1'b0) begin
                m_irq_ce_n = m_irq_ce_n + 1;
                if (m_irq_seq_n < 8) begin
                    m_irq_seq[m_irq_seq_n] = m_cpu_state;
                    m_irq_seq_n = m_irq_seq_n + 1;
                end
                if (m_cpu_state == 7'd59) begin
                    m_irq_active = 1'b0;
                    m_irq_entries = m_irq_entries + 1;
                    if (m_irq_ce_n < 16)
                        m_entry_hist[m_irq_ce_n] = m_entry_hist[m_irq_ce_n] + 1;
                    if (m_irq_ce_n == 7) begin
                        if ((m_irq_entry_min == 0) || (m_irq_ce_n < m_irq_entry_min))
                            m_irq_entry_min = m_irq_ce_n;
                        if (m_irq_ce_n > m_irq_entry_max)
                            m_irq_entry_max = m_irq_ce_n;
                    end else begin
                        m_irq_entry_bad = m_irq_entry_bad + 1;
                        m_bad_ce_n = m_irq_ce_n;
                        for (d = 0; d < 8; d = d + 1)
                            m_bad_seq[d] = m_irq_seq[d];
                    end
                    if ((m_irq_seq_n != 7) ||
                        (m_irq_seq[0] != 7'd7) || (m_irq_seq[1] != 7'd54) ||
                        (m_irq_seq[2] != 7'd55) || (m_irq_seq[3] != 7'd56) ||
                        (m_irq_seq[4] != 7'd57) || (m_irq_seq[5] != 7'd58) ||
                        (m_irq_seq[6] != 7'd59))
                        m_irq_seq_bad = m_irq_seq_bad + 1;
                end
                if (m_irq_ce_n > 12) begin
                    m_irq_active = 1'b0;
                    m_irq_entry_stall = m_irq_entry_stall + 1;
                end
            end
            m_prev_fire_state = m_cpu_state;
        end
    end
end

// ------------------------------------------------- P1-11 a12 window monitor
//
// Every branch that counts or checks anything is inside a12_win, which is 1
// only for the duration of check_p1_11's force window.  Outside it the block
// does nothing but keep the four edge detectors in step, so nothing here can
// fire while the port is not forced and nothing carries stale state into the
// window.  No $fatal lives in here: this block only accumulates, and the task
// reads the totals once its own waits are done.
always @(posedge clk) begin
    if (a12_win !== 1'b1) begin
        a12_model_d = a12_model;
        a12_dotonly_d = a12_dotonly;
        a12_filt_d = chr_mmc3.u_mapper.mmc3_a12_filtered;
        a12_fd_d = chr_mmc3.u_ppu.frame_done;
    end else begin
        a12_clk_n = a12_clk_n + 1;

        // ---- the register state ONE CLK AFTER an accepted edge ----------
        // a12_filtered is high for exactly the clk between the sampling of
        // ppu_a12 and the next one, so the counter has already been written
        // by the time the next posedge reads it back.
        if (a12_snap_pend !== 1'b0) begin
            a12_snap_pend = 1'b0;
            a12_snap_idx = a12_edge_idx;
            a12_snap_counter = chr_mmc3.u_mapper.mmc3_irq_counter;
            a12_snap_reload = chr_mmc3.u_mapper.mmc3_irq_reload;
            a12_snap_pending = chr_mmc3.u_mapper.mmc3_irq_pending;
            if (a12_snap_idx == 1) begin
                a12_snap1_counter = a12_snap_counter;
                a12_snap1_reload = a12_snap_reload;
                a12_snap1_pending = a12_snap_pending;
            end
            // $C001 reload makes the first value the latch; from there the
            // counter is 7,6,5,4,3,2,1,0,7,... with latch 7.  A wrong reload or
            // a wrong decrement shows up here as a sequence error, not as a
            // single sampled value.
            if (a12_snap_counter !== (MMC3_IRQ_LATCH_VALUE -
                                      ((a12_edge_idx - 1) % 8)))
                a12_seq_err = a12_seq_err + 1;
        end

        // ---- accepted edges --------------------------------------------
        // mmc3_a12_filtered is a combinational one-clk pulse, so this change
        // detect has to live inside a posedge block to see it at all.
        if (chr_mmc3.u_mapper.mmc3_a12_filtered !== a12_filt_d) begin
            if (chr_mmc3.u_mapper.mmc3_a12_filtered === 1'b1) begin
                a12_filt = a12_filt + 1;
                a12_snap_pend = 1'b1;
                if (a12_last_filt_clk != 0) begin
                    if ((a12_gap_min == 0) ||
                        ((a12_clk_n - a12_last_filt_clk) < a12_gap_min))
                        a12_gap_min = a12_clk_n - a12_last_filt_clk;
                end
                a12_last_filt_clk = a12_clk_n;
            end
            a12_filt_d = chr_mmc3.u_mapper.mmc3_a12_filtered;
        end

        // ---- the testbench's own model ----------------------------------
        // A rise is the dot 259 -> 260 transition, a fall is dot 319 -> 320.
        // The high window is credited only for lines whose RISE was observed
        // inside the window, so a window that opens mid-line cannot invent a
        // short window.
        if (a12_model !== a12_model_d) begin
            if (a12_model === 1'b1) begin
                a12_rise = a12_rise + 1;
                a12_edge_idx = a12_edge_idx + 1;
                a12_hi_clk = 0;
                a12_hi_armed = 1'b1;
            end else begin
                if (a12_hi_armed !== 1'b0) begin
                    if (a12_hi_clk != 240)
                        a12_hi_bad = a12_hi_bad + 1;
                    a12_hi_clk_last = a12_hi_clk;
                    a12_hi_lines = a12_hi_lines + 1;
                    a12_hi_armed = 1'b0;
                end
                a12_hi_clk = 0;
            end
            a12_model_d = a12_model;
        end
        if ((a12_model === 1'b1) && (a12_hi_armed !== 1'b0))
            a12_hi_clk = a12_hi_clk + 1;
        if ((a12_model === 1'b1) &&
            (chr_mmc3.u_ppu.scanline >= 9'd240) &&
            (chr_mmc3.u_ppu.scanline <= 9'd260))
            a12_vb_hi = a12_vb_hi + 1;

        if (a12_dotonly !== a12_dotonly_d) begin
            if (a12_dotonly === 1'b1)
                a12_dotonly_rise = a12_dotonly_rise + 1;
            a12_dotonly_d = a12_dotonly;
        end

        // ---- per-frame rate, measured between two frame_done edges ------
        // The window opens mid-frame, so the FIRST frame_done closes a partial
        // frame and the task reads the second one.
        if (chr_mmc3.u_ppu.frame_done !== a12_fd_d) begin
            if (chr_mmc3.u_ppu.frame_done === 1'b1) begin
                a12_fd_n = a12_fd_n + 1;
                a12_rise_last = a12_rise;
                a12_dotonly_rise_last = a12_dotonly_rise;
                a12_filt_last = a12_filt;
                a12_hi_lines_last = a12_hi_lines;
                a12_vb_hi_last = a12_vb_hi;
                a12_rise = 0;
                a12_dotonly_rise = 0;
                a12_filt = 0;
                a12_hi_lines = 0;
                a12_vb_hi = 0;
            end
            a12_fd_d = chr_mmc3.u_ppu.frame_done;
        end

        // ---- phase 2b line attribution ----------------------------------
        // irq_pending_r is a rtl register here, so mapper_irq rises in the
        // delta right after the edge that set it, and a12_edge_idx still holds
        // that edge's index.  The index and the line-high count are LATCHED at
        // the transition: a12_edge_idx keeps running, so a continuously
        // updated copy would report the edge index of whenever the task next
        // looked, not the edge that raised the line.
        if (a12_irq_seen !== 1'b1) begin
            if (m_mapper_irq === 1'b1) begin
                a12_irq_seen = 1'b1;
                a12_idx_at_irq = a12_edge_idx;
            end
        end
        if (a12_early_armed !== 1'b0) begin
            if ((a12_irq_seen !== 1'b1) && (m_irq_line !== 1'b0))
                a12_early_hi_err = a12_early_hi_err + 1;
            if (m_irq_line !== 1'b0)
                a12_line_hi_2b = a12_line_hi_2b + 1;
        end
        // The counter is at its reload point, 0, for one whole edge period out
        // of every eight.  Arming the enable there is what makes "exactly 8
        // accepted edges later" a true statement instead of an arbitrary one:
        // from 0 the walk is reload-to-7 on the first edge and then 6,5,4,3,
        // 2,1,0, so irq_counter_next == 0 lands on the eighth.  From any other
        // value the rtl needs exactly that many edges, which is why the
        // second assertion below is the phase-free form of the same claim.
        if (chr_mmc3.u_mapper.mmc3_irq_counter === 8'h00)
            a12_c0 = 1'b1;
        if ((a12_phase == 2'd2) &&
            (chr_mmc3.u_cpu.dbg_pc == IRQ_HANDLER))
            a12_handler_clk = a12_handler_clk + 1;
        if (m_apu_irq_o === 1'b1)
            a12_apu_hi = a12_apu_hi + 1;
        if (m_mapper_irq === 1'b1)
            a12_mapper_hi = a12_mapper_hi + 1;
        if (chr_mmc3.mapper_ppu_a12 === 1'b1)
            a12_net_hi = a12_net_hi + 1;
        if (m_mapper_write_pulse !== 1'b0)
            a12_cart_wr = a12_cart_wr + 1;
    end
end

// ------------------------------------------------------------ check tasks

task check_p0_1;
    begin
        if (reset_clks < 4)
            $fatal(1, "P0-1 only %0d reset clk were observed", reset_clks);
        if (reset_chr_req_bad != 0)
            $fatal(1, "P0-1 chr_req was high %0d times during reset",
                   reset_chr_req_bad);
        if (reset_chr_addr_bad != 0)
            $fatal(1, "P0-1 chr_final_addr was nonzero %0d times during reset",
                   reset_chr_addr_bad);
        if (reset_chr_we_bad != 0)
            $fatal(1, "P0-1 chr_we was high %0d times during reset", reset_chr_we_bad);
        if (reset_chr_waddr_bad != 0)
            $fatal(1, "P0-1 chr_waddr was nonzero %0d times during reset",
                   reset_chr_waddr_bad);
        if (reset_mapper_id_bad != 0)
            $fatal(1, "P0-1 dbg_mapper_id was nonzero %0d times during reset",
                   reset_mapper_id_bad);
        if (v6_mapper_id !== 3'd0 || v5_mapper_id !== 3'd0)
            $fatal(1, "P0-1 dbg_mapper_id is %0d/%0d, NROM must be 0",
                   v6_mapper_id, v5_mapper_id);
        if (chr_hi_addr_bad != 0)
            $fatal(1, "P0-1 chr_final_addr exceeded 0x1FFF %0d times", chr_hi_addr_bad);
        if (last_f_max_final_addr > 17'h1FFF)
            $fatal(1, "P0-1 chr_final_addr %05h exceeded 0x1FFF in the last frame",
                   last_f_max_final_addr);
        $display("P0-1 RESET/IDENTITY reset clks=%0d chr_req=0 chr_final_addr=0 chr_we=0 chr_waddr=0 during reset, dbg_mapper_id=0/0, chr requests=%0d, max chr_final_addr=0x%04h <= 0x1FFF PASS",
                 reset_clks, chr_req_total, last_f_max_final_addr);
    end
endtask

task check_p0_2;
    begin
        if (chr_addr_err != 0)
            $fatal(1, "P0-2 chr translation mismatched %0d times", chr_addr_err);
        if (chr_addr_checks < 50000)
            $fatal(1, "P0-2 only %0d chr translations were checked", chr_addr_checks);
        if (cart_pulse_err != 0)
            $fatal(1, "P0-2 mapper_write_pulse addr/data mismatched or went missing %0d times",
                   cart_pulse_err);
        if (cart_pulse_width_err != 0)
            $fatal(1, "P0-2 mapper_write_pulse stayed high for two clk %0d times",
                   cart_pulse_width_err);
        if (cart_pulse_spurious != 0)
            $fatal(1, "P0-2 mapper_write_pulse fired %0d times with no cart write",
                   cart_pulse_spurious);
        if (cart_pulse_multi != 0)
            $fatal(1, "P0-2 %0d cart writes produced no pulse", cart_pulse_multi);
        if (cart_wr_total != 3)
            $fatal(1, "P0-2 the program issued %0d cart writes expected 3",
                   cart_wr_total);
        if (cart_pulse_total != cart_wr_total)
            $fatal(1, "P0-2 %0d cart writes produced %0d pulses",
                   cart_wr_total, cart_pulse_total);
        $display("P0-2 CHR-TRANSLATION tb model = (tb_chr_bank_model<<13)|(ab_v6.u_ppu.chr_addr & 0x1fff), the local term read from the ppu port itself, checked=%0d err=%0d, plus local[12:0]==final[12:0] and final[16:13]==0, NROM bank term const 0 PASS",
                 chr_addr_checks, chr_addr_err);
        if (chr_wr_addr_err != 0)
            $fatal(1, "P0-2 WRITE chr translation mismatched %0d times", chr_wr_addr_err);
        if (chr_wr_checks < CHR_TILE_BYTES)
            $fatal(1, "P0-2 only %0d write beats were translation-checked", chr_wr_checks);
        if (chr_wr_req_clash > chr_wr_beats)
            $fatal(1, "P0-2 %0d read/write collisions on %0d write beats, more than one per write",
                   chr_wr_req_clash, chr_wr_beats);
        if (chr_wr_clash_visible != 0)
            $fatal(1, "P0-2 %0d read/write collisions happened while the background or the sprites were being displayed, so a rendered pixel was fed the write address's byte",
                   chr_wr_clash_visible);
        if (chr_wr_not_accepted != 0)
            $fatal(1, "P0-2 a chr-ram board's mapper refused %0d $2007 write beats",
                   chr_wr_not_accepted);
        if (chr_wr_beats != chr_wr_exp_total)
            $fatal(1, "P0-2 the ppu raised chr_we on %0d beats but the bus saw %0d $2007 writes into the chr half",
                   chr_wr_beats, chr_wr_exp_total);
        $display("P0-2 WRITE-TRANSLATION chr_we never raises chr_req, so the read-beat check above gave ZERO coverage of the write address before this line existed.  On every $2007 write beat the tb now rebuilds the expected final address from its own bank model and the ppu's LOCAL chr_waddr, expected=(tb_chr_bank_model<<13)|(chr_waddr & 0x1fff), and compares it with chr_final_addr one net downstream; it also asserts chr_waddr==(pre-increment u_ppu.v_addr), chr_waddr[13]==0, local[12:0]==final[12:0], final[16:13]==0 and chr_wdata==reg_din.  write beats=%0d checked=%0d err=%0d, refused by the mapper on a chr-ram board=%0d, and the strobe count EQUALS the bus-side count of $2007 writes into the chr half=%0d PASS",
                 chr_wr_beats, chr_wr_checks, chr_wr_addr_err,
                 chr_wr_not_accepted, chr_wr_exp_total);
        $display("P0-2 WRITE-READ-ARBITRATION MEASURED, NOT ASSUMED.  mapper_ppu_addr = ppu_chr_we ? ppu_chr_waddr : ppu_chr_addr gives the WRITE priority, and chr_req is produced by the free-running fetch units and is NOT suppressed by a write, so the two CAN be high on the same ce_ppu.  That happened on %0d of the %0d $2007 write beats.  On such a beat chr_final_addr carries the write address, so that beat is checked against the WRITE model instead of the read model (%0d such read beats were excluded from the read translation count, which stayed exact on the remaining %0d).  The cost is that the fetch unit latches the write address's byte for that one ce, so a $2007 write issued while the background or the sprites are actually being displayed would corrupt one tile beat.  That did NOT happen here: %0d of the %0d collisions occurred while the ppu's own bg_pa_enable was high or with sprites enabled below scanline 240.  The upload runs with PPUMASK=$00, so P0-4's pixel A/B and P0-5's named classes are unaffected.  KNOWN LIMITATION, not a deleted check PASS",
                 chr_wr_req_clash, chr_wr_beats, chr_wr_req_clash,
                 chr_addr_checks, chr_wr_clash_visible, chr_wr_req_clash);
        $display("P0-2 CART-WRITE tb model fires from exported cart_xfer&&bus_we only and predicts addr/data one clk later, cart writes=%0d pulses=%0d addr/data err=%0d width err=%0d spurious=%0d missing=%0d (a000=5a b123=a5 ffc0=3c) PASS",
                 cart_wr_total, cart_pulse_total, cart_pulse_err,
                 cart_pulse_width_err, cart_pulse_spurious, cart_pulse_multi);
    end
endtask

task check_p0_3;
    begin
        if (last_f_final_bit13_bad != 0)
            $fatal(1, "P0-3 chr_final_addr[13] was set %0d times in the last frame",
                   last_f_final_bit13_bad);
        if (last_f_wr_final_bit13_bad != 0)
            $fatal(1, "P0-3 chr_final_addr[13] was set on %0d $2007 write beats",
                   last_f_wr_final_bit13_bad);
        if (chr_wr_bit13_bad != 0)
            $fatal(1, "P0-3 chr_final_addr[13] was set on %0d of %0d $2007 write beats over the whole run",
                   chr_wr_bit13_bad, chr_wr_beats);
        if (last_f_addr_err != 0)
            $fatal(1, "P0-3 the translation model disagreed %0d times in the last frame",
                   last_f_addr_err);
        if (last_f_chr_req < 10000)
            $fatal(1, "P0-3 only %0d chr requests landed in the last frame, the drop was not exercised at all",
                   last_f_chr_req);
        if (last_f_local_bit12 < 1)
            $fatal(1, "P0-3 the ppu pattern-table select (local chr_addr[12]) was never set, no table select crossed the mapper at all");
        $display("P0-3 BIT13-DROP last frame chr requests=%0d, chr_final_addr[13] set on %0d of them, max chr_final_addr=0x%04h, translation model err=%0d PASS",
                 last_f_chr_req, last_f_final_bit13_bad, last_f_max_final_addr,
                 last_f_addr_err);
        $display("P0-3 WRITE-STREAM the request stream is no longer the whole chr stream: the program issues %0d $2007 CHR writes and chr_we fired on %0d of them (last frame: %0d), so the bit-13 assertion is now also made on every write beat.  chr_final_addr[13] was set on %0d of %0d write beats over the whole run and on %0d of the %0d in the last frame, max chr_final_addr across read AND write beats in the last frame = 0x%04h.  It holds because chr_we is qualified by v_addr < $2000, i.e. local bit 13 is structurally zero PASS",
                 chr_wr_beats, chr_wr_beats, last_f_chr_wr,
                 chr_wr_bit13_bad, chr_wr_beats,
                 last_f_wr_final_bit13_bad, chr_wr_beats,
                 last_f_max_final_addr);
        $display("P0-3 NONVACUITY-PROBE last frame ppu local chr_addr[13] set on %0d requests, local chr_addr[12] (the pattern-table select PPUCTRL bit 4 drives) set on %0d requests.  chr_addr[13] is UNREACHABLE BY STIMULUS in this rtl: nes_chr_fetch_unit is wired tile_count=1 and its 13-bit tile_base {table,tile,4'b0}+fine tops out at 0x1ff7, so nxt_addr=tile_base+8 <= 0x1fff; nes_sprite_chr_fetch's plane_byte adds at most 8 to a 13-bit pat_addr with bit 3 forced low, so it also tops out at 0x1fff.  The table select therefore lands on local bit 12, which the mapper preserves.  KNOWN GAP, not a deleted check: chr_final_addr[13]==0 is still asserted on every request and (bank<<13)|local is still asserted against the ppu's own port, so a reintroduced post-adder would still fail.  What cannot be proven here is that a hypothetical set bit 13 survives the drop, because no stimulus can raise it.  Observed local bit 13 = %0d PASS",
                 last_f_local_bit13, last_f_local_bit12, last_f_local_bit13);
    end
endtask

task check_p0_4;
    begin
        if (frames_seen != FRAME_TARGET)
            $fatal(1, "P0-4 frame_done count got %0d expected %0d",
                   frames_seen, FRAME_TARGET);
        if (ab_visible_count != AB_VISIBLE_TARGET)
            $fatal(1, "P0-4 the visible comparison count is %0d, expected exactly %0d",
                   ab_visible_count, AB_VISIBLE_TARGET);
        if (ab_visible_div != 0)
            $fatal(1, "P0-4 v5 and v6 diverged on %0d visible pixels",
                   ab_visible_div);
        if (ab_all_ce_div != 0)
            $fatal(1, "P0-4 v5 and v6 diverged on %0d of %0d ce",
                   ab_all_ce_div, ab_all_ce_count);
        if (chr_up_flag_seen != 1)
            $fatal(1, "P0-4 the program never raised ram[%04h], so no CHR upload happened",
                   CHR_UPLOAD_FLAG_CELL);
        if (chr_up_snap_err != 0)
            $fatal(1, "P0-4 %0d of %0d uploaded CHR bytes were wrong in v6's external model",
                   chr_up_snap_err, 2 * CHR_TILE_BYTES);
        if (chr_v5_snap_err != 0)
            $fatal(1, "P0-4 %0d of %0d uploaded CHR bytes are missing from v5's internal array",
                   chr_v5_snap_err, 2 * CHR_TILE_BYTES);
        $display("P0-4 AB-FULL-FRAME compared per ce, visible comparisons=%0d (3 x 240 x 256) exact, divergences=%0d, all-ce comparisons=%0d divergences=%0d, frame period=%0d clk PASS",
                 ab_visible_count, ab_visible_div, ab_all_ce_count,
                 ab_all_ce_div, frame_delta_clk);
        $display("P0-4 AB-NONVACUITY this comparison used to be a statement about the CHR PRELOAD: both boards were handed the rendered image.  They no longer are.  v6's external chr_mem and v5's internal chr_ram both start at the SENTINEL image (ff/00/00/ff/ff/00 complemented) in both pattern tables and the only thing that can put run A's image (ff 00 00 ff ff 00) into them is the program's own %0d $2007 writes, which the two paths take completely differently (v6 external port through the mapper, v5 internal chr_ram).  At the program-set flag ram[%04h] all %0d bytes of v6's external model matched the program's bytes (err=%0d, none left at the sentinel) and all %0d bytes of v5's two tables matched too (err=%0d).  Had the external write been dropped, v6 would still be showing the sentinel and this per-ce comparison would have failed PASS",
                 chr_wr_beats, CHR_UPLOAD_FLAG_CELL, 2 * CHR_TILE_BYTES,
                 chr_up_snap_err, 2 * CHR_TILE_BYTES, chr_v5_snap_err);
    end
endtask

task check_p0_5;
    begin
        if (pix_index_mismatch != 0)
            $fatal(1, "P0-5 %0d final-frame pixels had the wrong index",
                   pix_index_mismatch);
        if (visible_pixels != PIXELS_PER_FRAME)
            $fatal(1, "P0-5 the final frame delivered %0d distinct dots expected %0d (clk samples %0d, 4 clk per ppu ce)",
                   visible_pixels, PIXELS_PER_FRAME, pix_checked);
        if (pix_cnt2 < 1)
            $fatal(1, "P0-5 VACUOUS: index 2 never appeared in the final frame");
        if (pix_cnt6 < 1)
            $fatal(1, "P0-5 VACUOUS: index 6 never appeared in the final frame");
        if (pix_cnt1 < 1)
            $fatal(1, "P0-5 VACUOUS: index 1 never appeared in the final frame");
        $display("P0-5 PIXEL-CLASSES final frame distinct dots=%0d (clk samples %0d, 4 clk per ppu ce) index2(lines<8,cols8-15)=%0d index6(lines32-39,cols8-15)=%0d index1(elsewhere)=%0d other=%0d, index mismatches=%0d PASS",
                 visible_pixels, pix_checked, pix_cnt2, pix_cnt6, pix_cnt1,
                 pix_other, pix_index_mismatch);
    end
endtask

task check_p0_6;
    begin
        if (chr_model_pred_err != 0)
            $fatal(1, "P0-6 the chr model presented %0d wrong bytes",
                   chr_model_pred_err);
        if (chr_latch_err != 0)
            $fatal(1, "P0-6 the fetch unit latched %0d wrong bytes", chr_latch_err);
        if (chr_model_pred_checks < 50000)
            $fatal(1, "P0-6 only %0d model presentations were shadowed",
                   chr_model_pred_checks);
        if (chr_latch_checks < 1000)
            $fatal(1, "P0-6 only %0d fetch-unit latches were shadowed",
                   chr_latch_checks);
        $display("P0-6 CHR-MODEL registered chr_rdata shadowed against chr_mem[chr_final_addr delayed 1 ce] on %0d request beats (err=%0d), fetch unit bg_lo/bg_hi latches shadowed against chr_mem[chr_final_addr delayed 2 ce] on %0d beats (err=%0d) PASS",
                 chr_model_pred_checks, chr_model_pred_err, chr_latch_checks,
                 chr_latch_err);
        $display("P0-6 TB-MODEL-CHANGES the tb chr_mem array is no longer write-once: the program now stores %0d bytes into it, so a shadow comparison whose address was itself written in the last two ce would be comparing against a different epoch of the array.  Those beats are COUNTED and skipped rather than compared, and nothing else is skipped: %0d of %0d registered-read beats and %0d of %0d fetch-unit latch beats were excluded this way, leaving err=%0d and err=%0d on the rest PASS",
                 chr_wr_accepted, chr_pred_race_skip, chr_model_pred_checks,
                 chr_latch_race_skip, chr_latch_checks,
                 chr_model_pred_err, chr_latch_err);
    end
endtask

task check_p0_7;
    integer d;
    begin
        if (m_bank_writes != MMC3_BANK_STEPS)
            $fatal(1, "P0-7 the mmc3 program issued %0d $8001 writes expected %0d",
                   m_bank_writes, MMC3_BANK_STEPS);
        for (d = 0; d < MMC3_BANK_STEPS; d = d + 1) begin
            if (m_bank_ok[d] !== 1'b1)
                $fatal(1, "P0-7 $8001 write %0d (data %02h) landed at scanline %0d dot %0d, outside vblank scanlines 241-260 dots 1-256",
                       d + 1, m_bank_data[d], m_bank_sl[d][15:8], m_bank_sl[d][7:0]);
            if (m_addr_err[d] != 0)
                $fatal(1, "P0-7 the translation model disagreed %0d times on $8001 write %0d",
                       m_addr_err[d], d + 1);
            if (m_addr_checks[d] < 20000)
                $fatal(1, "P0-7 only %0d chr beats were checked on $8001 write %0d, the window was not exercised",
                       m_addr_checks[d], d + 1);
            if (m_tile0_tot[d] < 1000)
                $fatal(1, "P0-7 only %0d tile-0 pixels were sampled on $8001 write %0d",
                       m_tile0_tot[d], d + 1);
            if (m_tile0_exp[d] < 1000)
                $fatal(1, "P0-7 the named index %0d appeared on only %0d of %0d tile-0 pixels for $8001 write %0d",
                       m_exp_index[d], m_tile0_exp[d], m_tile0_tot[d], d + 1);
        end
        // the preload itself must be capable of showing a difference.  Pairwise
        // image identity is what has to be ruled out, not every single byte: the
        // two patterns deliberately share their plane-0 byte 0xFF and differ on
        // plane 1, which is exactly the kind of difference that is easy to hide
        // behind an all-constant bank.
        for (d = 0; d < 48; d = d + 1) begin
            if (m_chr_mem[MMC3_IMG_BASE_REG0 + d] !== chr_tile_image[d])
                $fatal(1, "P0-7 the reg %02h image is not the v4 image at byte %0d",
                       MMC3_REG_R0, d);
        end
        if (m_chr_mem[MMC3_IMG_BASE_REG1 + 8] === m_chr_mem[MMC3_IMG_BASE_REG0 + 8])
            $fatal(1, "P0-7 reg %02h and reg %02h carry the same tile-0 plane-1 byte, the switch is unobservable by construction",
                   MMC3_REG_R0, MMC3_REG_R1);
        if (m_chr_mem[MMC3_IMG_BASE_REG2 + 8] === m_chr_mem[MMC3_IMG_BASE_REG0 + 8])
            $fatal(1, "P0-7 reg %02h and reg %02h carry the same tile-0 plane-1 byte, the switch is unobservable by construction",
                   MMC3_REG_R0, MMC3_REG_R2);
        z = 0;
        for (d = 0; d < 48; d = d + 1) begin
            if (m_chr_mem[MMC3_IMG_BASE_REG1 + d] !== m_chr_mem[MMC3_IMG_BASE_REG0 + d])
                z = z + 1;
        end
        if (z == 0)
            $fatal(1, "P0-7 the reg %02h and reg %02h images are byte identical",
                   MMC3_REG_R0, MMC3_REG_R1);
        if (z == 48)
            $fatal(1, "P0-7 the reg %02h and reg %02h images differ on every byte, the low plane-0 byte $FF must be shared or the named index would change for the wrong reason",
                   MMC3_REG_R0, MMC3_REG_R1);
        z = 0;
        for (d = 0; d < 48; d = d + 1) begin
            if (m_chr_mem[MMC3_IMG_BASE_REG2 + d] !== m_chr_mem[MMC3_IMG_BASE_REG0 + d])
                z = z + 1;
        end
        if (z == 0)
            $fatal(1, "P0-7 the reg %02h and reg %02h images are byte identical",
                   MMC3_REG_R0, MMC3_REG_R2);
        z = 0;
        for (d = 0; d < 48; d = d + 1) begin
            if (m_chr_mem[MMC3_IMG_BASE_REG2 + d] !== m_chr_mem[MMC3_IMG_BASE_REG1 + d])
                z = z + 1;
        end
        if (z == 0)
            $fatal(1, "P0-7 the reg %02h and reg %02h images are byte identical",
                   MMC3_REG_R1, MMC3_REG_R2);
        z = 0;
        if (m_bit16_seen[2] < 1000)
            $fatal(1, "P0-7 chr_final_addr[16] was set on only %0d beats for the reg %02h step, the 17th bit is not real",
                   m_bit16_seen[2], MMC3_REG_R2);
        if (m_tile0_oth[0] != 0 || m_tile0_oth[1] != 0 || m_tile0_oth[2] != 0 ||
            m_tile0_oth[3] != 0 || m_tile0_oth[4] != 0)
            $fatal(1, "P0-7 the tile-0 region was not a single class: stray pixels %0d/%0d/%0d/%0d/%0d",
                   m_tile0_oth[0], m_tile0_oth[1], m_tile0_oth[2],
                   m_tile0_oth[3], m_tile0_oth[4]);
        if (m_exp_index[0] === m_exp_index[2])
            $fatal(1, "P0-7 the first and third bank were asserted to the same index, the check proves nothing");
        // W2 added two more $8001 steps, so the "same register means the same
        // window index, different register means a different one" relation is
        // now asserted for every adjacent pair instead of only the two the old
        // three-step program needed.
        for (d = 0; d < (MMC3_BANK_STEPS - 1); d = d + 1) begin
            if (m_first_hi_ok[d] !== 1'b1 || m_first_hi_ok[d+1] !== 1'b1)
                $fatal(1, "P0-7 step %0d or %0d produced no chr beat to sample", d + 1, d + 2);
            if (m_bank_reg[d] === m_bank_reg[d+1]) begin
                if (m_first_hi[d] !== m_first_hi[d+1])
                    $fatal(1, "P0-7 steps %0d/%0d select the SAME r0 register %02h but the dut chr_final_addr[16:10] moved from %02h to %02h, so the reg model is wrong",
                           d + 1, d + 2, m_bank_reg[d], m_first_hi[d], m_first_hi[d+1]);
            end else begin
                if (m_first_hi[d] === m_first_hi[d+1])
                    $fatal(1, "P0-7 steps %0d/%0d select different r0 registers %02h/%02h but the dut chr_final_addr[16:10] did not move, the bank switch is not observable",
                           d + 1, d + 2, m_bank_reg[d], m_bank_reg[d+1]);
            end
        end
        if (m_first_hi_ok[0] !== 1'b1 || m_first_hi_ok[1] !== 1'b1 ||
            m_first_hi_ok[2] !== 1'b1)
            $fatal(1, "P0-7 an epoch produced no chr beat to sample");
        if (m_first_hi[0] !== m_first_hi[1])
            $fatal(1, "P0-7 the dut chr_final_addr[16:10] moved from %02h to %02h across the $01 write, so this rtl DOES keep r0 bit 0 and the reg model is wrong",
                   m_first_hi[0], m_first_hi[1]);
        if (m_first_hi[0] === m_first_hi[2])
            $fatal(1, "P0-7 the dut chr_final_addr[16:10] did not move across the $41 write, the bank switch is not observable");
        if (m_seen_self_loop !== 1'b1)
            $fatal(1, "P0-7 the mmc3 cpu never reached its self loop");
        $display("P0-7 MMC3-BANK (a) translation: expected_final=(tb_chr_bank_model<<10)|(local&0x3ff) with tb_chr_bank_model={mapper_write_data[7:1],1'b0} captured from mapper_write_pulse/addr/data, never from the dut register, checked on every ce_ppu with chr_req high: $8001 data %02h/%02h/%02h/%02h/%02h -> reg %02h/%02h/%02h/%02h/%02h, chr beats total=%0d, per-step beats=%0d/%0d/%0d/%0d/%0d err=%0d/%0d/%0d/%0d/%0d, dut chr_final_addr[16:10] first value per step=%02h/%02h/%02h/%02h/%02h.  Steps 4 and 5 are the W2 bank pair and are deliberately included here so the per-step bucketing keeps covering every write PASS",
                 m_bank_data[0], m_bank_data[1], m_bank_data[2],
                 m_bank_data[3], m_bank_data[4],
                 m_bank_reg[0], m_bank_reg[1], m_bank_reg[2],
                 m_bank_reg[3], m_bank_reg[4],
                 m_chr_req_total,
                 m_addr_checks[0], m_addr_checks[1], m_addr_checks[2],
                 m_addr_checks[3], m_addr_checks[4],
                 m_addr_err[0], m_addr_err[1], m_addr_err[2],
                 m_addr_err[3], m_addr_err[4],
                 m_first_hi[0], m_first_hi[1], m_first_hi[2],
                 m_first_hi[3], m_first_hi[4]);
        $display("P0-7 MMC3-BANK (b) named tile-0 indices: step1 $8001=%02h -> reg %02h -> index %0d on %0d of %0d tile-0 pixels (plane0=$FF/plane1=$00 -> pattern 1 -> $3F01=$21); step2 $8001=%02h -> reg %02h -> index %0d on %0d of %0d; step3 $8001=%02h -> reg %02h -> index %0d on %0d of %0d (plane0=$FF/plane1=$FF -> pattern 3 -> $3F03=$18); stray pixels %0d/%0d/%0d.  PARTIAL SPEC, NOT A DELETED CHECK: step 2 was specified to produce a NEW value and it cannot, because nes_mapper_mmc3.v:208 latches r0 as {data[7:1],1'b0} so $01 and $00 are the same 1 KiB bank (real MMC3 2 KiB granularity, bit 0 is the odd/even 1 KiB select and lives in local chr_addr[11]).  The named value for step 2 is therefore %0d, identical to step 1, and the dut chr_final_addr[16:10] is asserted bit-identical across the two steps (%02h vs %02h) so the equality is measured, not assumed.  Two of the three steps therefore change the arriving bytes and the picture (reg %02h -> reg %02h); the third cannot, and no preload can make it, because the register value it selects is the same.  The four preloaded images are pairwise different PASS",
                 m_bank_data[0], m_bank_reg[0], m_exp_index[0], m_tile0_exp[0], m_tile0_tot[0],
                 m_bank_data[1], m_bank_reg[1], m_exp_index[1], m_tile0_exp[1], m_tile0_tot[1],
                 m_bank_data[2], m_bank_reg[2], m_exp_index[2], m_tile0_exp[2], m_tile0_tot[2],
                 m_tile0_oth[0], m_tile0_oth[1], m_tile0_oth[2],
                 m_exp_index[1], m_first_hi[0], m_first_hi[1],
                 m_bank_reg[0], m_bank_reg[2]);
        $display("P0-7 MMC3-BANK (b2) the two W2 steps are held to the same named-index rule as steps 1-3: step4 $8001=%02h -> reg %02h -> index %0d on %0d of %0d tile-0 pixels with %0d strays; step5 $8001=%02h -> reg %02h -> index %0d on %0d of %0d with %0d strays.  Step 4 sends r0 back to $00 so its window is reg $00 again, and step 5 selects reg $42 whose 1 KiB image is the same reg-$40 image, so both named indices are the ones already used above and neither had to be invented PASS",
                 m_bank_data[3], m_bank_reg[3], m_exp_index[3],
                 m_tile0_exp[3], m_tile0_tot[3], m_tile0_oth[3],
                 m_bank_data[4], m_bank_reg[4], m_exp_index[4],
                 m_tile0_exp[4], m_tile0_tot[4], m_tile0_oth[4]);
        $display("P0-7 MMC3-BANK (c) for the $41 write the r0 register is {0x41[7:1],1'b0}=$40 so chr_final_addr[16]=reg[6]=1 on %0d of the %0d checked beats; that is bit 16 of a 17-bit address taken from the mapper output port, so a 16-bit testbench index could not have produced it.  All five $8001 writes landed inside the vblank period at scanline/dot %0d/%0d, %0d/%0d, %0d/%0d, %0d/%0d and %0d/%0d (dots all below the 257 where the 35-ce sprite shadow build starts), ppuctrl was $%02h throughout so PPUCTRL[4]/[5] never moved the window, and the four preloaded bank images are pairwise different PASS",
                 m_bit16_seen[2], m_addr_checks[2],
                 m_bank_sl[0][15:8], m_bank_sl[0][7:0],
                 m_bank_sl[1][15:8], m_bank_sl[1][7:0],
                 m_bank_sl[2][15:8], m_bank_sl[2][7:0],
                 m_bank_sl[3][15:8], m_bank_sl[3][7:0],
                 m_bank_sl[4][15:8], m_bank_sl[4][7:0],
                 MMC3_PPUCTRL);
    end
endtask

task check_p0_8;
    begin
        if (ab_consec_noread != 0)
            $fatal(1, "P0-8 ab_v6 chr_req was high on two consecutive ce %0d times with NO read arm on either beat, so a fetch master still beats another one",
                   ab_consec_noread);
        if (m_req_consec != 0)
            $fatal(1, "P0-8 chr_mmc3 chr_req was high on two consecutive ce %0d times",
                   m_req_consec);
        if (ab_consec_rr != 0)
            $fatal(1, "P0-8 two read arms landed back to back on consecutive ce %0d times, one $2007 read cannot arm twice",
                   ab_consec_rr);
        if (ab_bgsp_clash != 0)
            $fatal(1, "P0-8 ab_v6 background and sprite chr_req collided %0d times",
                   ab_bgsp_clash);
        if (m_bgsp_clash != 0)
            $fatal(1, "P0-8 chr_mmc3 background and sprite chr_req collided %0d times",
                   m_bgsp_clash);
        if (ab_we_consec != 0)
            $fatal(1, "P0-8 ab_v6 chr_we was high on two consecutive ce %0d times",
                   ab_we_consec);
        if (m_we_consec != 0)
            $fatal(1, "P0-8 chr_mmc3 chr_we was high on two consecutive ce %0d times",
                   m_we_consec);
        if (ab_req_beats < 200000)
            $fatal(1, "P0-8 ab_v6 only produced %0d ce, the collision window was barely sampled",
                   ab_req_beats);
        if (ab_bgsp_beats < 100000)
            $fatal(1, "P0-8 ab_v6 only produced %0d fetch-unit chr_req beats, the units were barely sampled",
                   ab_bgsp_beats);
        if (m_bgsp_beats < 100000)
            $fatal(1, "P0-8 chr_mmc3 only produced %0d fetch-unit chr_req beats, the units were barely sampled",
                   m_bgsp_beats);
        $display("P0-8 NO-BUS-COLLISION RE-SCOPED, NOT WEAKENED.  WHAT CHANGED AND WHY: the old line asserted that chr_req is NEVER high on two consecutive ce on ab_v6.  chr_rd_win now feeds chr_req directly, so a $2007 CHR read that lands on the ce_ppu edge right after a fetch request beat makes that assertion false by construction, and qualifying it on mask_reg[3] is not available because the fetch units are free-running regardless of the mask.  So the invariant is restated over the beats that can legitimately collide, and it is still asserted.  On all %0d ce_ppu of ab_v6 there were %0d consecutive chr_req pairs.  Of those, %0d had NO read arm on EITHER beat -- exactly the case the old assertion covered, exactly what a run with chr_rd_arm tied to 1'b0 would have measured -- and that count is %0d.  Every one of the remaining pairs touches a read arm, and each is attributed by the same expression the ppu uses to drive chr_addr: %0d had the READ ARM winning the second beat (%0d against a background beat on the first, %0d against a sprite beat, %0d arm after arm) and %0d had a fetch unit winning the second beat, of which %0d followed a background read arm and %0d followed a sprite read arm.  chr_mmc3 runs a program with no $2007 reads at all, so nothing can raise an arm there and chr_req was never high on two consecutive ce there either (%0d of %0d ce, %0d violations).  The background fetch unit chr_req (u_ppu.g_chr_external.u_chr_fetch.chr_req) and the sprite fetch unit chr_req (u_ppu.g_chr_external.u_sprite_chr_fetch.chr_req) were never both high on the same ce: %0d and %0d sampled beats, %0d and %0d collisions.  The port has no backpressure, so a fetch-vs-fetch collision would be a silently dropped background beat.  That a read arm's ADDRESS survives the collision is asserted separately in W3-3, on every arm beat.  ab_v5 is not in this check because nes_system_v5 has no external CHR port at all PASS",
                 ab_req_beats, ab_req_consec,
                 ab_req_consec - ab_consec_arm - ab_consec_arm_first_bg,
                 ab_consec_noread,
                 ab_consec_arm, ab_consec_arm_vs_bg, ab_consec_arm_vs_sp,
                 ab_consec_rr,
                 ab_consec_bg + ab_consec_sp, ab_consec_arm_first_bg,
                 ab_consec_sp,
                 m_req_consec, m_req_beats, m_req_consec,
                 ab_bgsp_beats, m_bgsp_beats, ab_bgsp_clash, m_bgsp_clash);
        $display("P0-8 WRITE-STROBE the new write path takes the same mapper port the fetch arbiter uses, so it was re-checked for contention: chr_we was never high on two consecutive ce_ppu on ab_v6 (%0d violations) or on chr_mmc3 (%0d violations), and the arbitration between the two was counted rather than assumed -- %0d and %0d of the %0d and %0d write beats coincided with a chr_req beat (write wins in mapper_ppu_addr), with %0d and %0d of those while bg or sprites were enabled PASS",
                 ab_we_consec, m_we_consec, chr_wr_req_clash, m_wr_req_clash,
                 chr_wr_beats, m_wr_beats,
                 chr_wr_clash_visible, m_wr_clash_visible);
    end
endtask

// =====================================================================
// W1  NROM + CHR RAM: $2007 write, then render from what the write left
// =====================================================================

task check_w1_chr_upload;
    integer d;
    begin
        if (chr_up_flag_seen != 1)
            $fatal(1, "W1 the program never raised ram[%04h]", CHR_UPLOAD_FLAG_CELL);
        if (chr_wr_beats < (2 * CHR_TILE_BYTES))
            $fatal(1, "W1 only %0d $2007 write beats were seen, the upload is smaller than the %0d bytes it claims to store",
                   chr_wr_beats, 2 * CHR_TILE_BYTES);
        if (chr_wr_beats != chr_wr_exp_total)
            $fatal(1, "W1 chr_we fired %0d times but the bus saw %0d $2007 writes into the chr half",
                   chr_wr_beats, chr_wr_exp_total);
        if (chr_wr_accepted != chr_wr_beats)
            $fatal(1, "W1 the mapper accepted %0d of %0d $2007 write beats on a chr-ram board",
                   chr_wr_accepted, chr_wr_beats);
        if (chr_up_snap_err != 0)
            $fatal(1, "W1 %0d of the %0d uploaded bytes are wrong in v6's external chr model",
                   chr_up_snap_err, 2 * CHR_TILE_BYTES);
        if (chr_up_snap_nochange != 0)
            $fatal(1, "W1 %0d of the %0d uploaded bytes still held the sentinel, so they were not written",
                   chr_up_snap_nochange, 2 * CHR_TILE_BYTES);
        if (chr_up_addr_err != 0)
            $fatal(1, "W1 %0d bytes at chr_mem[8192+d] are not the sentinel; $2000 is unreachable and must be untouched",
                   chr_up_addr_err);
        if (chr_v5_snap_err != 0)
            $fatal(1, "W1 %0d of the %0d uploaded bytes are missing from v5's internal chr_ram",
                   chr_v5_snap_err, 2 * CHR_TILE_BYTES);
        $display("W1 NROM-CHR-RAM-WRITE the program stores a 48-byte three-tile image into BOTH halves the renderer reads -- chr_mem[$0000+off] for the sprite (PPUCTRL[5]=0) and chr_mem[$1000+off] for the background (PPUCTRL[4]=1, and nes_mapper_nrom.v:26 preserves bit 12) -- on ab_v6 (NROM_CHR_RAM=1).  $2007 write beats=%0d, bus-side $2007 writes into the chr half=%0d (the count is equal, so every write produced exactly one strobe), mapper accepted=%0d, translation errors=%0d, beats on two consecutive ce=%0d.  At the program-set flag ram[%04h] all %0d bytes of the external chr model equalled the constant the program itself supplied (err=%0d) and none of them was still the sentinel (%0d bytes unchanged) PASS",
                 chr_wr_beats, chr_wr_exp_total, chr_wr_accepted,
                 chr_wr_addr_err, chr_wr_consec,
                 CHR_UPLOAD_FLAG_CELL, 2 * CHR_TILE_BYTES, chr_up_snap_err,
                 chr_up_snap_nochange);
        $display("W1 SENTINEL v6's external model started at the COMPLEMENT of what the program writes (sentinel %02h %02h %02h %02h %02h %02h per plane pair, upload %02h %02h %02h %02h %02h %02h per plane pair), and v5's internal chr_ram started at the same sentinel in both tables.  If a single one of those %0d writes had been dropped the render would have shown the sentinel pattern value 2 where it now shows 1, so P0-4's per-ce A/B and P0-5's named pixel classes both fail on a dropped write.  chr_mem[$2000+d] is past every address the ppu can produce (chr_final_addr tops out at $1FFF) and all %0d of those bytes are still the sentinel (mismatches=%0d), so the store went exactly where the program aimed it and nowhere else PASS",
                 chr_tile_image_b[0], chr_tile_image_b[8], chr_tile_image_b[16],
                 chr_tile_image_b[24], chr_tile_image_b[32], chr_tile_image_b[40],
                 chr_tile_image[0], chr_tile_image[8], chr_tile_image[16],
                 chr_tile_image[24], chr_tile_image[32], chr_tile_image[40],
                 chr_wr_beats, CHR_TILE_BYTES, chr_up_addr_err);
    end
endtask

// The self-validating pair.  chr_ram_b is ab_v6 running BYTE-IDENTICAL CODE with
// the two PRG fill bytes swapped, so the only difference between the two runs is
// which pattern the same loop stores.  If $2007-to-CHR were ignored on both, both
// would render their own sentinel and this comparison would come out EQUAL and
// fail, which is what makes the pair immune to a completely dead write path.
task check_w1_self_validating_pair;
    begin
        if (rb_wr_beats != chr_wr_beats)
            $fatal(1, "W1 chr_ram_b raised chr_we %0d times against ab_v6's %0d, the two runs are not comparable",
                   rb_wr_beats, chr_wr_beats);
        if (rb_wr_not_accepted != 0)
            $fatal(1, "W1 chr_ram_b's mapper refused %0d write beats on a chr-ram board",
                   rb_wr_not_accepted);
        if (rb_tile_err != 0)
            $fatal(1, "W1 %0d of the %0d bytes in chr_ram_b's external model are not run B's image",
                   rb_tile_err, 2 * CHR_TILE_BYTES);
        if (rb_tile0_same != 0)
            $fatal(1, "W1 %0d bytes of chr_ram_b's model still hold run A's image, the two boards would render the same picture",
                   rb_tile0_same);
        if (pic_rb_cmp != PIXELS_PER_FRAME * 4)
            $fatal(1, "W1 the self-validating pair compared %0d clk samples, expected %0d",
                   pic_rb_cmp, PIXELS_PER_FRAME * 4);
        if (pic_rb_geom_diff != 0)
            $fatal(1, "W1 chr_ram_b and ab_v6 disagreed on pixel geometry %0d times, so the two programs are not in lockstep",
                   pic_rb_geom_diff);
        if (pic_rb_idx_diff < 1)
            $fatal(1, "W1 VACUOUS: the two different uploads produced identical pictures, so nothing proves the writes were consumed");
        if (pic_rb_tile0_diff < 1)
            $fatal(1, "W1 VACUOUS: the two pictures differ only outside the columns the program wrote, so the difference is not coming from the uploaded bytes");
        $display("W1 SELF-VALIDATING-PAIR ab_v6 (upload ff/00/00/ff/ff/00) and chr_ram_b (upload 00/ff/ff/00/00/ff) run the SAME CODE -- the only difference between the two PRG images is the contents of the two data cells the fill loop reads -- through the same external CHR RAM write path, from opposite sentinels.  Strobe beats ab_v6=%0d chr_ram_b=%0d (equal), chr_ram_b bytes that ended at run B's image=%0d of %0d, bytes that wrongly still held run A's image=%0d.  Rendered over the whole final frame at 4 clk per dot (%0d clk samples, %0d geometry differences so the runs really are in lockstep) the pictures DIFFER on %0d clk samples, of which %0d are in the leftmost 16 columns of a visible scanline, i.e. exactly where BG tiles 0 and 1 that the program wrote are drawn.  A dead $2007-to-CHR path would leave both boards rendering their own sentinel and the two pictures would MATCH, which is exactly what this check forbids PASS",
                 chr_wr_beats, rb_wr_beats, 2 * CHR_TILE_BYTES - rb_tile_err,
                 2 * CHR_TILE_BYTES, rb_tile0_same, pic_rb_cmp, pic_rb_geom_diff,
                 pic_rb_idx_diff, pic_rb_tile0_diff);
    end
endtask

// =====================================================================
// The CHR-ROM / CHR-RAM ignore pair, on the same program
// =====================================================================

task check_chr_ram_rom_pair;
    begin
        if (rom_wr_beats != chr_wr_beats)
            $fatal(1, "PAIR the chr-rom board produced %0d chr_we beats against the chr-ram board's %0d, the paired result below would be meaningless",
                   rom_wr_beats, chr_wr_beats);
        if (chr_wr_beats < 1)
            $fatal(1, "PAIR neither board produced a single chr_we beat");
        if (rom_wr_ramwe_bad != 0)
            $fatal(1, "PAIR mapper_chr_ram_we was HIGH on %0d of %0d chr_we beats on the chr-rom board, the writes were not refused at the gate",
                   rom_wr_ramwe_bad, rom_wr_beats);
        if (rom_wr_bad_wdata != 0)
            $fatal(1, "PAIR chr_wdata did not equal the ppu's reg_din on %0d of %0d chr_we beats on the chr-rom board",
                   rom_wr_bad_wdata, rom_wr_beats);
        if (rom_pre_err != 0)
            $fatal(1, "PAIR %0d of the %0d bytes of the chr-rom board's memory were not the same as before the upload",
                   rom_pre_err, rom_pre_bytes);
        if (rom_final_bytes != 0)
            $fatal(1, "PAIR %0d bytes of the chr-rom board's 128 KiB memory changed during the run", rom_final_bytes);
        if (rom_tile_err != 0)
            $fatal(1, "PAIR the chr-rom board's image is not the image the program uploads (%0d bytes wrong)",
                   rom_tile_err);
        if (rom_pre_bytes != CHR_MEM_BYTES)
            $fatal(1, "PAIR only %0d of the %0d bytes were compared against the pre-run snapshot",
                   rom_pre_bytes, CHR_MEM_BYTES);
        if (pic_rom_cmp != PIXELS_PER_FRAME * 4)
            $fatal(1, "PAIR the picture comparison covered %0d clk samples, expected %0d",
                   pic_rom_cmp, PIXELS_PER_FRAME * 4);
        if (pic_rom_idx_diff != 0)
            $fatal(1, "PAIR the chr-rom board rendered %0d different pixels than the chr-ram board that stored the same bytes",
                   pic_rom_idx_diff);
        if (pic_rom_geom_diff != 0)
            $fatal(1, "PAIR the chr-rom board disagreed on pixel geometry %0d times, so the two runs are not in lockstep",
                   pic_rom_geom_diff);
        $display("PAIR CHR-RAM-vs-CHR-ROM identical program, identical addresses, identical bytes offered; the only difference is NROM_CHR_RAM.  IDENTICAL STROBE: chr_we beats chr-ram=%0d chr-rom=%0d.  REFUSED AT A NAMED GATE: mapper_chr_ram_we (chr_ram_enable_r && ppu_we && ppu_addr[13]==0, nes_mapper.v:221) was low on %0d of %0d chr-rom write beats and chr_ram_enable itself is %b on that board, while on the chr-ram board it was high on every one.  MEMORY: %0d of %0d bytes of the rom board's array are byte-identical to the pre-run snapshot and %0d bytes of the whole 128 KiB changed.  BEHAVIOURAL EQUIVALENCE WITH A ROM CARTRIDGE: the rom board's CHR already held the %0d bytes the program tries to write (err=%0d), the store was refused, and the two boards rendered IDENTICAL pictures over the whole final frame (%0d clk samples, %0d pixel-index differences, %0d geometry differences).  That is what a CHR-ROM cartridge does with the same code PASS",
                 chr_wr_beats, rom_wr_beats, rom_wr_ramwe_bad, rom_wr_beats,
                 r_mapper_chr_ram_enable, rom_pre_err, rom_pre_bytes,
                 rom_final_bytes, 2 * CHR_TILE_BYTES, rom_tile_err,
                 pic_rom_cmp, pic_rom_idx_diff, pic_rom_geom_diff);
        $display("PAIR NON-VACUITY the chr-ram half of this line is a live control, not a formality: on the SAME program and the SAME addresses the chr-ram board changed %0d bytes of its array (every one of the %0d uploaded bytes verified against the program's own constant, none left at the sentinel), while the chr-rom board changed 0.  Same strobe, same address, same data, opposite outcomes decided by one parameter PASS",
                 chr_wr_accepted, 2 * CHR_TILE_BYTES);
    end
endtask

// =====================================================================
// W3  NROM + CHR RAM: $2007 external-CHR read-back
// =====================================================================
//
// Ten checks, each aimed at one named failure mode.  Four of them (2, 4, 6, 8)
// exist to kill "the byte came from somewhere inside the ppu", and they are
// built so that the byte side of every comparison is the TB's OWN memory array,
// never chr_rdata, never read_buffer_reg, never a value derived from the dut's
// own answer.

task check_w3_readback;
    integer d;
    integer w;
    integer rb_v6_err;
    integer rb_v5_err;
    integer rb_rom_err;
    integer rb_rb_err;
    integer rb_rb_diff;
    integer rb_rom_same;
    integer rb_snap_err;
    integer rb_unw_err;
    integer rb_unw_ne_win;
    integer rb_unw_ne_win_v5;
    integer rb_unw_ne_win_rom;
    integer rb_unw_ne_win_b;
    integer rb_v6_diff_v5;
    integer rb_cells;
    reg [15:0] w_addr [0:(CHR_RB_WINDOWS-1)];
    reg [15:0] w_store [0:(CHR_RB_WINDOWS-1)];
    begin
        w_addr[0] = CHR_RB_LOOP_A_ADDR;
        w_addr[1] = CHR_RB_LOOP_B_ON;
        w_addr[2] = CHR_RB_LOOP_B_OFF;
        w_addr[3] = CHR_RB_LOOP_B_UNW;
        w_store[0] = CHR_RB_STORE_A;
        w_store[1] = CHR_RB_STORE_BON;
        w_store[2] = CHR_RB_STORE_BOFF;
        w_store[3] = CHR_RB_STORE_BUNW;

        // ---- 1. armed, always ----
        if (rb_armed_missing != 0)
            $fatal(1, "W3-1 %0d $2007 chr read beats saw chr_rd_armed_q low", rb_armed_missing);
        if (rb_stranded != 0)
            $fatal(1, "W3-1 %0d read arms were never consumed by a read beat", rb_stranded);
        if (rb_arm_beats != rb_read_beats)
            $fatal(1, "W3-1 %0d read arms and %0d $2007 chr read beats, they must pair one for one",
                   rb_arm_beats, rb_read_beats);
        if (rb_arm_beats < 100)
            $fatal(1, "W3-1 only %0d read arms fired, the path is barely exercised", rb_arm_beats);

        // ---- 2. round trip observed, not re-derived ----
        if (rb_arm_data_err != 0)
            $fatal(1, "W3-2 chr_rdata held the wrong byte on %0d arm captures", rb_arm_data_err);
        if (rb_read_err != 0)
            $fatal(1, "W3-2 the cpu latched or the model held the wrong byte on %0d read beats", rb_read_err);
        if (rb_arm_data_checks < 100)
            $fatal(1, "W3-2 only %0d arm captures were checked", rb_arm_data_checks);
        if (rb_read_checks < 100)
            $fatal(1, "W3-2 only %0d read beats were checked", rb_read_checks);

        // ---- 3. crosses the mapper ----
        if (rb_arm_addr_err != 0)
            $fatal(1, "W3-3 chr_addr was not the ppu's own v_addr on %0d arm beats", rb_arm_addr_err);
        if (rb_addr_err != 0)
            $fatal(1, "W3-3 chr_final_addr was not the tb's own translation on %0d arm beats", rb_addr_err);
        if (rb_ramwe_bad != 0)
            $fatal(1, "W3-3 mapper_chr_ram_we was HIGH on %0d read arm beats, a read raised the store enable", rb_ramwe_bad);
        if (rb_we_overlap != 0)
            $fatal(1, "W3-3 chr_we was HIGH on %0d read arm beats, a read rode the write strobe", rb_we_overlap);

        // ---- 4/5/6/8: the per-instance value work, all byte for byte ----
        rb_v6_err = 0;
        rb_v5_err = 0;
        rb_rom_err = 0;
        rb_rb_err = 0;
        rb_rb_diff = 0;
        rb_rom_same = 0;
        rb_v6_diff_v5 = 0;
        rb_snap_err = 0;
        rb_unw_err = 0;
        rb_unw_ne_win = 0;
        rb_unw_ne_win_v5 = 0;
        rb_unw_ne_win_rom = 0;
        rb_unw_ne_win_b = 0;
        for (w = 0; w < CHR_RB_WINDOWS; w = w + 1)
            for (d = 0; d < CHR_RB_WINDOW_BYTES; d = d + 1) begin
                // every instance's read-back must equal THAT instance's own chr
                // memory at the address the loop asked for
                if (ab_v6.u_bus.ram_array[w_store[w][10:0] + 1 + d] !== chr_mem[w_addr[w] + d[15:0]])
                    rb_v6_err = rb_v6_err + 1;
                if (ab_v5.u_bus.ram_array[w_store[w][10:0] + 1 + d] !== ab_v5.u_ppu.chr_ram[w_addr[w][13:0]])
                    rb_v5_err = rb_v5_err + 1;
                if (chr_rom.u_bus.ram_array[w_store[w][10:0] + 1 + d] !== rom_chr_pre[w_addr[w][13:0]])
                    rb_rom_err = rb_rom_err + 1;
                if (chr_ram_b.u_bus.ram_array[w_store[w][10:0] + 1 + d] !== ramb_chr_mem[w_addr[w] + d[15:0]])
                    rb_rb_err = rb_rb_err + 1;
                // the cross-DUT A/B: ab_v5 answers $2007 out of its own INTERNAL
                // chr_ram, ab_v6 out of a top-level registered memory through the
                // mapper.  Two unrelated datapaths, one program, one answer.
                if (ab_v5.u_bus.ram_array[w_store[w][10:0] + 1 + d] !==
                    ab_v6.u_bus.ram_array[w_store[w][10:0] + 1 + d])
                    rb_v6_diff_v5 = rb_v6_diff_v5 + 1;
                if (chr_ram_b.u_bus.ram_array[w_store[w][10:0] + 1 + d] !==
                    ab_v6.u_bus.ram_array[w_store[w][10:0] + 1 + d])
                    rb_rb_diff = rb_rb_diff + 1;
                if (chr_rom.u_bus.ram_array[w_store[w][10:0] + 1 + d] ===
                    ab_v6.u_bus.ram_array[w_store[w][10:0] + 1 + d])
                    rb_rom_same = rb_rom_same + 1;
                // 5: the unwritten window must not answer with the written byte
                if (w == 3) begin
                    if (ab_v6.u_bus.ram_array[w_store[w][10:0] + 1 + d] !== CHR_RB_UNWRITTEN_EXPECT)
                        rb_unw_err = rb_unw_err + 1;
                    if (ab_v6.u_bus.ram_array[w_store[w][10:0] + 1 + d] !==
                        ab_v6.u_bus.ram_array[w_store[1][10:0] + 1 + d])
                        rb_unw_ne_win = rb_unw_ne_win + 1;
                    if (ab_v5.u_bus.ram_array[w_store[w][10:0] + 1 + d] !==
                        ab_v5.u_bus.ram_array[w_store[1][10:0] + 1 + d])
                        rb_unw_ne_win_v5 = rb_unw_ne_win_v5 + 1;
                    if (chr_rom.u_bus.ram_array[w_store[w][10:0] + 1 + d] !==
                        chr_rom.u_bus.ram_array[w_store[1][10:0] + 1 + d])
                        rb_unw_ne_win_rom = rb_unw_ne_win_rom + 1;
                    if (chr_ram_b.u_bus.ram_array[w_store[w][10:0] + 1 + d] !==
                        chr_ram_b.u_bus.ram_array[w_store[1][10:0] + 1 + d])
                        rb_unw_ne_win_b = rb_unw_ne_win_b + 1;
                end
                // 6: the sentinel survives.  These are the four windows the
                // read-back loops address, snapshotted when the program raised
                // the upload flag (loop A had already run) and re-read now.
                if (chr_mem[w_addr[w] + d[15:0]] !==
                    chr_rb_snap[w * CHR_RB_WINDOW_BYTES + d])
                    rb_snap_err = rb_snap_err + 1;
            end
        d = 0;
        w = 0;

        if (rb_v6_err != 0)
            $fatal(1, "W3-4 %0d of %0d read-back bytes on ab_v6 are not ab_v6's own chr_mem byte",
                   rb_v6_err, CHR_RB_WINDOWS * CHR_RB_WINDOW_BYTES);
        if (rb_v5_err != 0)
            $fatal(1, "W3-4 %0d of %0d read-back bytes on ab_v5 are not ab_v5's own internal chr_ram byte",
                   rb_v5_err, CHR_RB_WINDOWS * CHR_RB_WINDOW_BYTES);
        if (rb_rom_err != 0)
            $fatal(1, "W3-4 %0d of %0d read-back bytes on chr_rom are not its own PRE-LOAD byte",
                   rb_rom_err, CHR_RB_WINDOWS * CHR_RB_WINDOW_BYTES);
        if (rb_rb_err != 0)
            $fatal(1, "W3-4 %0d of %0d read-back bytes on chr_ram_b are not chr_ram_b's own chr_mem byte",
                   rb_rb_err, CHR_RB_WINDOWS * CHR_RB_WINDOW_BYTES);
        if (rb_rb_diff < 1)
            $fatal(1, "W3-4 VACUOUS: chr_ram_b's read-back is byte identical to ab_v6's, the two programs did not return different bytes");
        if (rb_v6_diff_v5 != 0)
            $fatal(1, "W3-8 %0d of %0d ram cells differ between the internal-chr board and the external-chr board",
                   rb_v6_diff_v5, CHR_RB_WINDOWS * CHR_RB_WINDOW_BYTES);
        if (rb_rom_same != (CHR_RB_WINDOWS * CHR_RB_WINDOW_BYTES))
            $fatal(1, "W3-4 the chr-rom board's read-back does not agree with the chr-ram board's on every byte, the two boards are not in lockstep");
        if (rb_unw_err != 0)
            $fatal(1, "W3-5 %0d of %0d unwritten-window bytes did not read back as the tb's load value",
                   rb_unw_err, CHR_RB_WINDOW_BYTES);
        if (rb_unw_ne_win < CHR_RB_WINDOW_BYTES)
            $fatal(1, "W3-5 only %0d of the %0d unwritten bytes differ from the just-written byte on ab_v6, the comparison is degenerate",
                   rb_unw_ne_win, CHR_RB_WINDOW_BYTES);
        if (rb_unw_ne_win_v5 < CHR_RB_WINDOW_BYTES ||
            rb_unw_ne_win_rom < CHR_RB_WINDOW_BYTES)
            $fatal(1, "W3-5 the unwritten-vs-written comparison is degenerate on ab_v5 (%0d) or chr_rom (%0d)",
                   rb_unw_ne_win_v5, rb_unw_ne_win_rom);
        if (rb_snap_err != 0)
            $fatal(1, "W3-6 %0d of the %0d read-back window bytes changed after the program raised the upload flag, a read wrote something",
                   rb_snap_err, CHR_RB_WINDOWS * CHR_RB_WINDOW_BYTES);
        if (chr_up_addr_err != 0)
            $fatal(1, "W3-6 chr_mem[$2000+d] moved, the $2000 control is broken");
        if (rom_pre_err != 0 || rom_final_bytes != 0)
            $fatal(1, "W3-6 the chr-rom board's memory changed (%0d bytes differ from the pre-run snapshot, %0d changed overall)",
                   rom_pre_err, rom_final_bytes);

        // ---- 9. the collision count has to be real ----
        if ((rb_coll_bg + rb_coll_sp) < 1)
            $fatal(1, "W3-9 no read arm ever coincided with a fetch request, the contention this design admits was never actually produced");
        if (ab_consec_arm < 1)
            $fatal(1, "W3-9 no consecutive chr_req pair was ever won by a read arm, the bus-steal case was never produced");

        // ---- 10. invisibility proven, not assumed ----
        if (rb_vis_bad != 0)
            $fatal(1, "W3-10 %0d read arms landed outside the provably invisible set", rb_vis_bad);
        if (ab_visible_div != 0)
            $fatal(1, "W3-10 the per-ce v5/v6 A/B diverged on %0d visible pixels, a read arm reached a pixel", ab_visible_div);
        if (ab_all_ce_div != 0)
            $fatal(1, "W3-10 the per-ce v5/v6 A/B diverged on %0d of %0d ce", ab_all_ce_div, ab_all_ce_count);
        rb_cells = CHR_RB_WINDOWS * CHR_RB_WINDOW_BYTES;

        $display("W3-1 ARMED-ALWAYS %0d $2007 CHR read beats and %0d read arms, one for one.  Every read beat saw u_ppu.g_chr_external.chr_rd_armed_q=1 (violations=%0d) and every arm was consumed by a read beat on the immediately following ce_ppu (stranded=%0d, two arms back to back=%0d).  KILLS the dead path: an arm that never fires leaves no read beat behind, and a read beat without an arm cannot pass, so this cannot go green on a path that is structurally disconnected PASS",
                 rb_read_beats, rb_arm_beats, rb_armed_missing, rb_stranded,
                 ab_consec_rr);
        $display("W3-2 ROUND-TRIP read beats checked=%0d, errors=%0d (one of them, the very first $2007 read of the run, has no predecessor and is excluded: %0d).  Arm captures checked=%0d, errors=%0d, and %0d were skipped for a write race in the same two ce.  NOTHING HERE COMPARES AGAINST chr_rdata ITSELF.  The expectation is built from the TB's OWN bank model and the PPU's OWN v_addr, expected_final_addr=(tb_chr_bank_model<<13)|(u_ppu.v_addr[13:0]&0x1fff), and the byte side is the TB's OWN chr_mem.  Chain, each term sampled at a different time: at the arm's ce edge the address went on the bus, one ce later chr_rdata ALREADY held chr_mem[that address], and the byte the cpu latched on the FOLLOWING $2007 beat equalled that same chr_rdata AND equalled chr_mem[the address the previous arm carried].  THE ONE-READ SKEW IS MEASURED, NOT ASSUMED: reg_cs is high only on the cycle that COMPLETES the two-cycle $2007 access and read_buffer_reg is refilled on that same edge, so the cpu receives access N-1's byte on access N, which is the real 2C02 read buffer.  Loop A primes once, loop B primes once per window, so each window's base+0..base+7 is what the verify loops actually compare PASS",
                 rb_read_checks, rb_read_err, rb_noprev, rb_arm_data_checks,
                 rb_arm_data_err, rb_race_skip);
        $display("W3-3 CROSSES-THE-MAPPER on all %0d read arm beats, chr_addr == u_ppu.v_addr[13:0] (err=%0d) and chr_final_addr == (tb_chr_bank_model<<13)|(v_addr[13:0]&0x1fff) (err=%0d).  chr_final_addr is mapper_chr_bank_offset, one net downstream of mapper_ppu_addr, so the read address provably left the ppu on the same port the fetch arbiter uses and came back translated, not on a private side channel.  mapper_chr_ram_we was HIGH on %0d arm beats and chr_we on %0d, so a read arm can neither raise the store enable nor coincide with the write strobe's capture edge: ppu_chr_rd_arm is qualified by !cpu_we, not by !ppu_we: ppu_we is ppu_req && cpu_we and ppu_req is structurally 0 at div_phase 8, so !ppu_we is trivially true and qualifies nothing; and a read and a write are different cpu cycles PASS",
                 rb_arm_beats, rb_arm_addr_err, rb_addr_err, rb_ramwe_bad,
                 rb_we_overlap);
        $display("W3-4 VALUE-TRACKS-CHR-CONTENT every one of the %0d read-back bytes was compared against THAT instance's own CHR memory at the address the loop asked for: ab_v6 external chr_mem err=%0d, ab_v5 INTERNAL chr_ram err=%0d, chr_ram_b external chr_mem err=%0d, chr_rom against its own PRE-LOAD err=%0d.  Window $0000 (written with the ON constant) reads back %02h on ab_v6 / %02h on ab_v5 / %02h on chr_rom / %02h on chr_ram_b, so the two boards running BYTE-IDENTICAL CODE with complementary DATA returned different bytes on %0d of the %0d cells.  That is what kills a constant and what kills a shadow of the writes: chr_ram_b's shadow would have to have tracked run B's upload, and chr_rom's board refused EVERY $2007 write at mapper_chr_ram_we (%0d of %0d write beats with the enable high) and still read back its ROM contents, so a value that could only come from a store the mapper refused would be visible.  HONEST LIMITATION: chr_rom's read-back is NOT different from ab_v6's byte for byte -- it cannot be, because chr_rom's CHR is preloaded with exactly the image the program uploads.  What differs is the PROVENANCE, and that is what is measured: chr_mem[$0000] was %02h before the run (the sentinel) and is %02h now, while rom_chr_mem[$0000] was %02h before the run and is %02h now, on a board whose writes were all refused (%0d of %0d bytes of its 128 KiB changed) PASS",
                 rb_cells, rb_v6_err, rb_v5_err, rb_rb_err, rb_rom_err,
                 ab_v6.u_bus.ram_array[CHR_RB_STORE_A[10:0] + 1],
                 ab_v5.u_bus.ram_array[CHR_RB_STORE_A[10:0] + 1],
                 chr_rom.u_bus.ram_array[CHR_RB_STORE_A[10:0] + 1],
                 chr_ram_b.u_bus.ram_array[CHR_RB_STORE_A[10:0] + 1],
                 rb_rb_diff, rb_cells,
                 rom_wr_ramwe_bad, rom_wr_beats,
                 chr_tile_image_b[0], chr_tile_image[0],
                 rom_chr_pre[0], rom_chr_mem[0],
                 rom_final_bytes, rom_pre_bytes);
        $display("W3-5 UNWRITTEN-ADDRESS $1040 is inside the reachable pattern table and past every address the upload touches (0..47 and 4096..4143), so the only thing that can be there is the tb's own load value.  All %0d of the unwritten bytes read back as $%02h on ab_v6 (err=%0d), and on the three run-A boards every one of them is provably DIFFERENT from the just-written byte at $1020 (ab_v6 %0d of %0d, ab_v5 %0d of %0d, chr_rom %0d of %0d), so a read that always answered with the last byte written could not have produced them.  HONEST LIMITATION: chr_ram_b is degenerate HERE, %0d of %0d, because run B's ON constant is $00 and the tb's load value is $00 too, so on that board the two bytes coincide and this particular pair proves nothing.  Its two boards are held apart by window $0000 above, where run A reads $FF and run B reads $00, and by the per-instance model comparison.  chr_mmc3 has no $2007 read at all: its program never issues one PASS",
                 CHR_RB_WINDOW_BYTES, CHR_RB_UNWRITTEN_EXPECT, rb_unw_err,
                 rb_unw_ne_win, CHR_RB_WINDOW_BYTES,
                 rb_unw_ne_win_v5, CHR_RB_WINDOW_BYTES,
                 rb_unw_ne_win_rom, CHR_RB_WINDOW_BYTES,
                 rb_unw_ne_win_b, CHR_RB_WINDOW_BYTES);
        $display("W3-6 SENTINEL-SURVIVES this EXTENDS the W1 SENTINEL check rather than restating it.  W1 proves the $2000 control region was never written; here the four windows the read-back loops address are snapshotted at the moment the program raised ram[%04h] (loop A has already run at that point) and re-read at the end of the run: %0d of the %0d bytes moved, so neither loop A nor the %0d read arms loop B issued per nmi wrote anything.  chr_mem[$2000+d] still holds the sentinel on all %0d bytes (err=%0d), and the chr-rom board's whole 128 KiB is still byte identical to its pre-run snapshot (%0d of %0d bytes differ).  A read path that raised chr_we, or a model that accepted a store the mapper refused, would move one of these PASS",
                 CHR_UPLOAD_FLAG_CELL, rb_snap_err, rb_cells, rb_loopb_arms,
                 CHR_TILE_BYTES, chr_up_addr_err, rom_pre_err, rom_pre_bytes);
        $display("W3-7 MODEL-CREDIBILITY no new shadow model is introduced here on purpose: W3-2 reuses P0-6's existing per-ce shadow of the registered chr_rdata against chr_mem[chr_final_addr delayed 1 ce] and of the fetch unit's bg_lo/bg_hi against chr_mem[chr_final_addr delayed 2 ce], which is what already makes the memory model itself auditable.  Over the whole run that shadow ran on %0d request beats (err=%0d) and %0d fetch-unit latches (err=%0d), with %0d and %0d beats skipped for a write race.  A read arm is a request beat like any other, so it is inside those numbers: the model is asked for the byte at whatever address was on the bus, whoever put it there PASS",
                 chr_model_pred_checks, chr_model_pred_err, chr_latch_checks,
                 chr_latch_err, chr_pred_race_skip, chr_latch_race_skip);
        $display("W3-8 CROSS-DUT-VALUE-AB the strongest single check in the group.  ab_v5 runs the SAME program on the INTERNAL chr path: g_chr_internal answers $2007 out of nes_ppu2c02's own chr_ram with no external port, no mapper and no bus at all.  ab_v6 answers the same $2007 reads out of a top-level registered 128 KiB array addressed through mapper_ppu_addr.  All %0d ram cells holding a read-back byte are byte identical between the two (differing cells=%0d).  Two completely different storage mechanisms, one program, one answer, so the byte cannot have come from a ppu-side cache of the writes: ab_v5 never performed the external write that put run A's image into chr_mem, and it still returns it.  The same cells on chr_ram_b differ from ab_v6 on %0d of %0d, which is the non-vacuity half: identical code, different data, different answer PASS",
                 rb_cells, rb_v6_diff_v5, rb_rb_diff, rb_cells);
        $display("W3-9 COLLISION-IS-REAL %0d read arms were raised and %0d of them coincided with a fetch request on the very same ce: %0d against a background fetch beat and %0d against a sprite fetch beat.  That is the displacement the contract names -- one background tile or one sprite slot plane, confined to the scanline the $2007 read was issued on -- produced for real rather than argued about.  P0-8's independent account agrees from the other side: of the %0d consecutive chr_req pairs, %0d had a read arm winning the second beat, %0d of those against a background beat and %0d against a sprite beat.  Arms by where they landed: %0d inside vblank scanlines 240-260 (loop B, rendering ON) and %0d outside it (loop A, PPUMASK=$00), scanlines %0d..%0d.  Without this assertion a design that never actually contended would pass silently PASS",
                 rb_arm_beats, rb_coll_bg + rb_coll_sp, rb_coll_bg, rb_coll_sp,
                 ab_req_consec, ab_consec_arm, ab_consec_arm_vs_bg,
                 ab_consec_arm_vs_sp,
                 rb_arms_vblank, rb_loopa_arms, rb_min_sl, rb_max_sl);
        $display("W3-9b P0-8'S INDEPENDENT ACCOUNT agrees from the other side: of the %0d consecutive chr_req pairs on ab_v6, %0d had a read arm winning the second beat (%0d against a background beat, %0d against a sprite beat) and %0d had a read arm on the first beat with a fetch unit winning the second (%0d against a background beat, %0d against a sprite beat).  A pair with no read arm on either beat, the case the removed invariant covered, is %0d PASS",
                 ab_req_consec, ab_consec_arm, ab_consec_arm_vs_bg,
                 ab_consec_arm_vs_sp,
                 ab_consec_arm_first_bg + ab_consec_sp, ab_consec_arm_first_bg,
                 ab_consec_sp, ab_consec_noread);
        $display("W3-10 INVISIBILITY-PROVEN every one of the %0d read arms was checked, on the arm beat itself, against the provably invisible set spelled out and not proxied: scanlines 240..260, or any scanline on which the ppu's OWN bg_pa_enable is low AND mask_reg[2] is low.  Violations=%0d, and any violation $fataled on the beat instead of being counted after the fact, so loop B drifting past scanline 260 fails the run loudly rather than quietly corrupting a line.  Scanline 261 is deliberately not in the set.  %0d arms landed with sprites shown and %0d with the mask off, and the consequence of a displaced fetch byte is then measured, not assumed: P0-4's per-ce v5/v6 comparison is still %0d visible comparisons with %0d divergences and %0d all-ce comparisons with %0d divergences.  loop A runs with PPUMASK=$00, where bg_shown and sprite_opaque are both low and mixed_pixel_value is 0 whatever the pattern byte latches, so the displacement there cannot reach a pixel PASS",
                 rb_arm_beats, rb_vis_bad, rb_arms_mask1, rb_arms_mask0,
                 ab_visible_count, ab_visible_div, ab_all_ce_count,
                 ab_all_ce_div);
    end
endtask

// =====================================================================
// W2  MMC3 + CHR RAM: the write is bank-qualified by the mapper
// =====================================================================

task check_w2_mmc3_chr_write;
    integer c;
    begin
        m_wr_low_flat = 0;
        m_wr_high_flat = 0;
        m_wr_odd_flat = 0;
        for (c = 0; c < CHR_MEM_BYTES; c = c + 1) begin
            if (m_chr_mem[c] !== m_chr_pre[c]) begin
                if (c == MMC3_W2_ADDR_LOW_EXP)
                    m_wr_low_flat = m_wr_low_flat + 1;
                else if (c == MMC3_W2_ADDR_HIGH_EXP)
                    m_wr_high_flat = m_wr_high_flat + 1;
                else if (c == MMC3_W2_ADDR_ODD_EXP)
                    m_wr_odd_flat = m_wr_odd_flat + 1;
                else
                    $fatal(1, "W2 byte %0d of the chr model changed (%02h -> %02h) but none of the three writes targeted it",
                           c, m_chr_pre[c], m_chr_mem[c]);
            end
        end
        if (m_wr_beats < 3)
            $fatal(1, "W2 only %0d $2007 write beats were seen on chr_mmc3", m_wr_beats);
        if (m_wr_beats != m_wr_exp_total)
            $fatal(1, "W2 chr_we fired %0d times but the bus saw %0d $2007 writes into the chr half",
                   m_wr_beats, m_wr_exp_total);
        if (m_wr_addr_err != 0)
            $fatal(1, "W2 %0d write-beat translation errors", m_wr_addr_err);
        if (m_wr_req_clash > m_wr_beats)
            $fatal(1, "W2 %0d read/write collisions on %0d write beats", m_wr_req_clash, m_wr_beats);
        if (m_wr_clash_visible != 0)
            $fatal(1, "W2 %0d read/write collisions happened while the background or the sprites were being displayed", m_wr_clash_visible);
        if (m_wr_not_accepted != 0)
            $fatal(1, "W2 the mapper refused %0d of %0d write beats on an mmc3 chr-ram board",
                   m_wr_not_accepted, m_wr_beats);
        if (m_wr_consec != 0)
            $fatal(1, "W2 chr_we was high on two consecutive ce %0d times", m_wr_consec);
        if (m_wr_low_hit != 1 || m_wr_high_hit != 1 || m_wr_odd_hit != 1)
            $fatal(1, "W2 the three writes landed at %0d/%0d/%0d of the expected translated addresses, expected 1/1/1",
                   m_wr_low_hit, m_wr_high_hit, m_wr_odd_hit);
        if (m_wr_low_before !== 8'h00)
            $fatal(1, "W2 m_chr_mem[%05h] held %02h before the store, expected the 00 preload",
                   MMC3_W2_ADDR_LOW_EXP, m_wr_low_before);
        if (m_wr_high_before !== 8'h00)
            $fatal(1, "W2 m_chr_mem[%05h] held %02h before the store, expected the 00 preload",
                   MMC3_W2_ADDR_HIGH_EXP, m_wr_high_before);
        if (m_wr_odd_before !== 8'h00)
            $fatal(1, "W2 m_chr_mem[%05h] held %02h before the store, expected the 00 preload",
                   MMC3_W2_ADDR_ODD_EXP, m_wr_odd_before);
        if (m_chr_mem[MMC3_W2_ADDR_LOW_EXP] !== MMC3_W2_BYTE_LOW)
            $fatal(1, "W2 m_chr_mem[%05h] is %02h expected %02h",
                   MMC3_W2_ADDR_LOW_EXP, m_chr_mem[MMC3_W2_ADDR_LOW_EXP],
                   MMC3_W2_BYTE_LOW);
        if (m_chr_mem[MMC3_W2_ADDR_HIGH_EXP] !== MMC3_W2_BYTE_HIGH)
            $fatal(1, "W2 m_chr_mem[%05h] is %02h expected %02h",
                   MMC3_W2_ADDR_HIGH_EXP, m_chr_mem[MMC3_W2_ADDR_HIGH_EXP],
                   MMC3_W2_BYTE_HIGH);
        if (m_chr_mem[MMC3_W2_ADDR_ODD_EXP] !== MMC3_W2_BYTE_ODD)
            $fatal(1, "W2 m_chr_mem[%05h] is %02h expected %02h",
                   MMC3_W2_ADDR_ODD_EXP, m_chr_mem[MMC3_W2_ADDR_ODD_EXP],
                   MMC3_W2_BYTE_ODD);
        if (m_wr_low_flat != 1 || m_wr_high_flat != 1 || m_wr_odd_flat != 1)
            $fatal(1, "W2 exactly one byte per target should have changed, got %0d/%0d/%0d",
                   m_wr_low_flat, m_wr_high_flat, m_wr_odd_flat);
        if (m_chr_mem[MMC3_W2_CANARY_OFF] !== MMC3_W2_CANARY)
            $fatal(1, "W2 the untouched-address control at $%05h is %02h expected the %02h preload",
                   MMC3_W2_CANARY_OFF, m_chr_mem[MMC3_W2_CANARY_OFF],
                   MMC3_W2_CANARY);
        $display("W2 MMC3-CHR-RAM-WRITE chr_we beats=%0d, bus-side $2007 writes into the chr half=%0d (equal), mapper accepted=%0d, beats on two consecutive ce=%0d, write-beat translation errors=%0d against the tb's own r0 register model and window decode.  Read/write arbitration on the shared mapper port collided on %0d of the %0d write beats, none of them with bg or sprites enabled (%0d visible), for the same reason P0-2 spells out PASS",
                 m_wr_beats, m_wr_exp_total, m_wr_accepted, m_wr_consec,
                 m_wr_addr_err, m_wr_req_clash, m_wr_beats,
                 m_wr_clash_visible);
        $display("W2 BANK-QUALIFIED r0=$%02h (reg $%02h) plus one $2007 byte %02h at local $%04h landed at chr_final_addr $%05h; r0 then moved to $%02h (reg $%02h) and THE SAME local address $%04h landed at $%05h with byte %02h instead, and a third byte %02h at local $%04h raised local bit 11 so it selected the odd 1 KiB of r0 and landed at $%05h.  Three writes, three different translated addresses, so the store is bank-qualified by nes_mapper_mmc3 and not a flat local RAM.  Each target held the $00 preload before its store and holds the program's own byte after it.  NON-VACUITY: the two r0 values are $%02h and $%02h and the two resulting addresses are %0d bytes apart; the control cell at $%05h one byte above the first target still holds its $%02h preload; and across the whole 128 KiB array exactly %0d/%0d/%0d bytes changed, one at each of the three targets and NOTHING else PASS",
                 MMC3_W2_R0_LOW, m_bank_reg[3], MMC3_W2_BYTE_LOW,
                 MMC3_W2_ADDR_LOW, MMC3_W2_ADDR_LOW_EXP,
                 MMC3_W2_R0_HIGH, m_bank_reg[4], MMC3_W2_ADDR_LOW,
                 MMC3_W2_ADDR_HIGH_EXP, m_chr_mem[MMC3_W2_ADDR_HIGH_EXP],
                 MMC3_W2_BYTE_ODD, MMC3_W2_ADDR_ODD, MMC3_W2_ADDR_ODD_EXP,
                 MMC3_W2_R0_LOW, MMC3_W2_R0_HIGH,
                 (MMC3_W2_ADDR_HIGH_EXP - MMC3_W2_ADDR_LOW_EXP),
                 MMC3_W2_CANARY_OFF, MMC3_W2_CANARY,
                 m_wr_low_flat, m_wr_high_flat, m_wr_odd_flat);
    end
endtask

// =====================================================================
// P1-11 MMC3 SCANLINE IRQ OFF A REAL, SELF-CLOCKING A12
//
// P1-5 proves the counter does NOT move, by forcing irq_pending_r.  That
// leaves the interesting half of the mmc3 untested: nothing had ever driven
// ppu_a12, so no edge had ever been filtered, no edge had ever reloaded the
// counter from the latch, and irq_pending_r had never been PRODUCED by the rtl.
// This task supplies the missing stimulus instead of the missing result.
//
// It is called as the last statement of check_p1_5, so the latch is already
// programmed, the handler, the $FFFE vector, the idle self loop and the whole
// cpu entry accounting are already in place.  It is not a gate target: it
// lives inside the existing system-v6 run.
//
// A12 IS FORCED AT ONE PLACE ONLY, on the production net itself:
// chr_mmc3.mapper_ppu_a12, the very object nes_system_v6 hardwires low.  A
// smoke test on iverilog 12.0 confirmed that force on that net does arrive at
// the object the rtl samples, chr_mmc3.u_mapper.u_mmc3.ppu_a12, and that both
// read 0 again after the release, so the two assertions below are the
// net and the port the rtl actually sees.  irq_pending_r IS NEVER FORCED HERE.
// Only irq_enabled_r is, in 2b, and it is the enable bit alone.  irq_pending_r
// is left to the rtl to set out of irq_counter_next == 0.
// =====================================================================

task check_p1_11;
    integer guard;
    integer entries_now;
    integer cell_now;
    begin
        // ---------------------------------------------------------- entry
        // $C001 wrote reload and nothing has clocked it away yet.
        if (chr_mmc3.u_mapper.mmc3_irq_reload !== 1'b1)
            $fatal(1, "P1-11 on entry the mmc3 reload flag is %b, $C001 is supposed to still be armed",
                   chr_mmc3.u_mapper.mmc3_irq_reload);
        if (chr_mmc3.u_mapper.mmc3_irq_counter !== 8'h00)
            $fatal(1, "P1-11 on entry the mmc3 counter is %02h, no a12 edge has been driven yet",
                   chr_mmc3.u_mapper.mmc3_irq_counter);
        if (chr_mmc3.u_mapper.mmc3_irq_enabled !== 1'b0)
            $fatal(1, "P1-11 on entry the mmc3 irq is enabled, 2a has to start with it off");
        if (chr_mmc3.u_ppu.mask_reg[3] !== 1'b1)
            $fatal(1, "P1-11 the ppu bg enable (PPUMASK bit 3) is %b, the a12 model would be dead",
                   chr_mmc3.u_ppu.mask_reg[3]);
        a12_in_reload = chr_mmc3.u_mapper.mmc3_irq_reload;
        a12_in_counter = chr_mmc3.u_mapper.mmc3_irq_counter;

        a12_win = 1'b0;
        a12_phase = 2'd1;
        a12_model_d = a12_model;
        a12_dotonly_d = a12_dotonly;
        a12_filt_d = chr_mmc3.u_mapper.mmc3_a12_filtered;
        a12_fd_d = chr_mmc3.u_ppu.frame_done;
        a12_snap_pend = 1'b0;
        a12_hi_armed = 1'b0;
        a12_irq_seen = 1'b0;
        a12_early_armed = 1'b0;
        a12_clk_n = 0;
        a12_gap_min = 0;
        a12_last_filt_clk = 0;
        a12_edge_idx = 0;
        a12_snap_idx = 0;
        a12_snap_counter = -1;
        a12_snap_reload = -1;
        a12_snap_pending = -1;
        a12_snap1_counter = -1;
        a12_snap1_reload = -1;
        a12_snap1_pending = -1;
        a12_snap2_idx = 0;
        a12_seq_err = 0;
        a12_rise = 0;
        a12_rise_last = -1;
        a12_dotonly_rise = 0;
        a12_dotonly_rise_last = -1;
        a12_filt = 0;
        a12_filt_last = -1;
        a12_hi_clk = 0;
        a12_hi_clk_last = -1;
        a12_hi_bad = 0;
        a12_hi_lines = 0;
        a12_hi_lines_last = -1;
        a12_vb_hi = 0;
        a12_vb_hi_last = -1;
        a12_fd_n = 0;
        a12_pending_hi = 0;
        a12_mapper_hi = 0;
        a12_mapper_base = 0;
        a12_apu_hi = 0;
        a12_net_hi = 0;
        a12_cart_wr = 0;
        a12_early_hi_err = 0;
        a12_idx_at_irq = 0;
        a12_handler_clk = 0;
        a12_edge_at_enable = 0;
        a12_line_hi_2b = 0;
        a12_entry_at_enable = 0;
        a12_vec_at_enable = 0;
        a12_cell_at_enable = 0;
        a12_cell_at_entry = 0;
        a12_drain_entry_n = 0;

        // ------------------------------------------- PHASE 2a + RATE CHECK
        // The force is the only stimulus.  Nothing else in the run changes.
        #1;
        force chr_mmc3.mapper_ppu_a12 = a12_model;
        #1;
        if (chr_mmc3.mapper_ppu_a12 !== a12_model)
            $fatal(1, "P1-11 the force did not land on chr_mmc3.mapper_ppu_a12");
        if (chr_mmc3.u_mapper.u_mmc3.ppu_a12 !== a12_model)
            $fatal(1, "P1-11 the forced a12 did not arrive at the mmc3 ppu_a12 port the rtl samples");
        a12_win = 1'b1;
        #1;

        // two frame_done edges: the first closes the partial frame the window
        // opened into, the second closes one whole frame of 241 rises.  A frame
        // is 341*262*4 = 357368 clk, so the worst case is just over two of
        // them from an arbitrary open.
        guard = 0;
        while ((a12_fd_n < 2) && (guard < 800000)) begin
            @(posedge clk);
            guard = guard + 1;
        end
        #1;
        if (a12_fd_n < 2)
            $fatal(1, "P1-11 only %0d frame_done edges arrived in the %0d clk of the a12 window",
                   a12_fd_n, guard);

        if (a12_rise_last != 241)
            $fatal(1, "P1-11 the tb a12 model rose %0d times in one whole frame, the nesdev canonical mmc3 case is 241 (scanlines 0..239 plus the pre-render line 261)",
                   a12_rise_last);
        if (a12_filt_last != a12_rise_last)
            $fatal(1, "P1-11 the mmc3 filter accepted %0d edges for %0d model rises in one whole frame",
                   a12_filt_last, a12_rise_last);
        if (a12_gap_min < 3)
            $fatal(1, "P1-11 the closest two accepted edges were %0d clk apart, MMC3_A12_COOLDOWN is 2 so the filter needs 3", a12_gap_min);
        if (a12_hi_lines_last != 241)
            $fatal(1, "P1-11 the a12 model held a full 60-dot window on %0d lines in one whole frame, expected 241",
                   a12_hi_lines_last);
        if (a12_vb_hi_last != 0)
            $fatal(1, "P1-11 the a12 model was high on %0d clk inside scanlines 240..260, ppuctrl is $00 so the counter must not clock in vblank",
                   a12_vb_hi_last);
        if (a12_hi_bad != 0)
            $fatal(1, "P1-11 %0d a12 model high windows were not exactly 240 clk (60 dots at 4 clk per dot) long",
                   a12_hi_bad);
        if (a12_hi_clk_last != 240)
            $fatal(1, "P1-11 the last a12 model high window was %0d clk, expected 240",
                   a12_hi_clk_last);
        if (a12_edge_idx < 241)
            $fatal(1, "P1-11 only %0d model rises were seen in the window", a12_edge_idx);
        if (a12_snap1_counter != MMC3_IRQ_LATCH_VALUE)
            $fatal(1, "P1-11 one clk after the FIRST accepted edge the counter is %0d, the $C001 reload has to load the %02h latch on that same clk",
                   a12_snap1_counter, MMC3_IRQ_LATCH_VALUE);
        if (a12_snap1_reload !== 1'b0)
            $fatal(1, "P1-11 reload is still %b one clk after the first accepted edge, it is only cleared inside the a12_filtered block",
                   a12_snap1_reload);
        if (a12_snap1_pending !== 1'b0)
            $fatal(1, "P1-11 irq_pending is %b one clk after the first accepted edge with the irq disabled",
                   a12_snap1_pending);
        if (a12_seq_err != 0)
            $fatal(1, "P1-11 the counter did not walk 7,6,5,4,3,2,1,0 across the accepted edges on %0d of them",
                   a12_seq_err);
        if (a12_pending_hi != 0)
            $fatal(1, "P1-11 irq_pending was high on %0d clk of phase 2a with the irq DISABLED, the rtl must not set it there",
                   a12_pending_hi);
        if (a12_mapper_hi != 0)
            $fatal(1, "P1-11 mapper_irq was high on %0d clk of phase 2a with the counter running and the irq DISABLED",
                   a12_mapper_hi);
        if (a12_apu_hi != 0)
            $fatal(1, "P1-11 the apu irq line was high on %0d clk inside the window, irq_line would not be attributable to the mapper",
                   a12_apu_hi);
        if (a12_cart_wr != 0)
            $fatal(1, "P1-11 the mmc3 cpu issued %0d cart writes inside the a12 window, it is supposed to stay in its idle self loop",
                   a12_cart_wr);
        $display("P1-11 A12-PHASE-2A the tb ppu-dot a12 model was forced onto chr_mmc3.mapper_ppu_a12, the very net nes_system_v6 hardwires low, and it arrived at chr_mmc3.u_mapper.u_mmc3.ppu_a12, the port nes_mapper_mmc3 samples on posedge clk.  The mmc3 then self-clocked OFF REAL RTL with the irq still DISABLED: on entry reload=%b and counter=%02h, so $C001's reload was still armed when the first edge arrived, and on that same clk the counter became %0d and reload fell to %b.  Over %0d accepted edges the counter walked 7,6,5,4,3,2,1,0 with %0d sequence errors, irq_pending stayed 0 on all of it (%0d clk high) and mapper_irq stayed 0 on all of it (%0d clk high) PASS",
                 a12_in_reload, a12_in_counter, a12_snap1_counter,
                 a12_snap1_reload, a12_edge_idx, a12_seq_err, a12_pending_hi,
                 a12_mapper_hi);
        $display("P1-11 A12-RATE counted per chr_mmc3.u_ppu.frame_done: the model rose %0d times in one whole frame (241 = scanlines 0..239 plus the pre-render line 261, one rise each at the dot 259->260 transition), mmc3_a12_filtered accepted %0d of them so nothing was lost and nothing was invented, the smallest gap between two accepted edges was %0d clk against the %0d clk MMC3_A12_COOLDOWN needs so the filter never rejected anything, the high window was exactly 60 dots = %0d clk on all %0d lines, and the model was high on %0d clk across the 21 vblank lines.  FOR THE RECORD the ungated dot-only expression (mask_reg[3] && dot 260..319, no rendering-line term) rose %0d times in the same frame on this ppu, whose dot counter free-runs through vblank: that is the 262-versus-241 gap the rendering-line gate closes, and the real hardware clocks the counter 0 times a frame here because PPUCTRL is $00 PASS",
                 a12_rise_last, a12_filt_last, a12_gap_min, 3, a12_hi_clk_last,
                 a12_hi_lines_last, a12_vb_hi_last, a12_dotonly_rise_last);

        // -------------------------------------------------------- PHASE 2b
        a12_phase = 2'd2;
        a12_irq_seen = 1'b0;
        a12_early_armed = 1'b0;
        a12_c0 = 1'b0;
        a12_early_hi_err = 0;
        a12_idx_at_irq = 0;
        a12_handler_clk = 0;
        a12_line_hi_2b = 0;
        a12_mapper_base = a12_mapper_hi;
        a12_entry_at_enable = m_irq_entries;
        a12_vec_at_enable = m_irq_vec_fetch;
        a12_cell_at_enable = chr_mmc3.u_bus.ram_array[11'h013];
        a12_cell_at_entry = 0;
        a12_counter_at_enable = 0;

        // The counter has been free-running through phase 2a, so it sits at an
        // arbitrary point of its 8-edge cycle when 2b starts and "8 edges
        // later" is only true from the reload point.  Arming the enable there
        // makes the claim exact and measures the whole reload-then-decrement
        // walk in one shot.  The counter sits there for a full 1364 clk edge
        // period, so there is no race between seeing it and forcing.
        guard = 0;
        while ((a12_c0 !== 1'b1) && (guard < 20000)) begin
            @(posedge clk);
            guard = guard + 1;
        end
        #1;
        if (a12_c0 !== 1'b1)
            $fatal(1, "P1-11 the mmc3 counter never came back to its reload point 00 in %0d clk, it is supposed to reload every 8 accepted edges",
                   guard);
        a12_counter_at_enable = chr_mmc3.u_mapper.mmc3_irq_counter;
        a12_edge_at_enable = a12_edge_idx;
        if (a12_counter_at_enable != 0)
            $fatal(1, "P1-11 the counter is %0d at the enable, phase 2b arms the enable on the reload point 00",
                   a12_counter_at_enable);

        // THE ONLY BIT FORCED IN 2b.  irq_pending_r is deliberately left alone
        // so the rtl has to produce it out of irq_counter_next == 0.
        force chr_mmc3.u_mapper.u_mmc3.irq_enabled_r = 1'b1;
        a12_early_armed = 1'b1;
        #1;
        if (chr_mmc3.u_mapper.mmc3_irq_pending !== 1'b0)
            $fatal(1, "P1-11 irq_pending was already 1 when the irq got enabled, phase 2a was supposed to leave it at 0");
        if (m_mapper_irq !== 1'b0)
            $fatal(1, "P1-11 mapper_irq rose the instant the enable was forced, irq is irq_enabled_r && irq_pending_r so it has to wait for the counter to reach 0");

        guard = 0;
        while ((a12_irq_seen !== 1'b1) && (guard < 40000)) begin
            @(posedge clk);
            guard = guard + 1;
        end
        #1;
        if (a12_irq_seen !== 1'b1)
            $fatal(1, "P1-11 mapper_irq never went high within %0d clk of enabling the irq", guard);
        if (a12_idx_at_irq != (a12_edge_at_enable + 8))
            $fatal(1, "P1-11 mapper_irq first went high on accepted edge %0d, latch %02h armed on the counter's reload point 00 has to take exactly 8 (reload to 7, then 6,5,4,3,2,1,0) after the edge index %0d recorded at the enable",
                   a12_idx_at_irq, MMC3_IRQ_LATCH_VALUE, a12_edge_at_enable);
        // the same measurement stated without the phase pin: from a counter of
        // c the rtl needs exactly c accepted edges to reach 0, and 8 when c is
        // the reload point, so the two claims agree and neither alone would
        // catch a single-edge slip.
        if ((a12_idx_at_irq - a12_edge_at_enable) !=
            ((a12_counter_at_enable == 0) ? 8 : a12_counter_at_enable))
            $fatal(1, "P1-11 mapper_irq took %0d accepted edges from a counter of %0d, the next-value walk needs exactly that many",
                   a12_idx_at_irq - a12_edge_at_enable, a12_counter_at_enable);
        if (a12_early_hi_err != 0)
            $fatal(1, "P1-11 irq_line was already high on %0d clk before the 8th accepted edge after the enable, so m_irq_high moved before the line did",
                   a12_early_hi_err);

        // ram[0013] is latched at the FIRST entry, not at the end: with the
        // line high the cpu re-enters continuously and the cell wraps through
        // zero, so an end-of-task != 0 read would prove nothing.
        a12_cell_at_entry = chr_mmc3.u_bus.ram_array[11'h013];
        if (a12_cell_at_entry !== a12_cell_at_enable)
            $fatal(1, "P1-11 ram[0013] was %02x at the first irq entry but %02x at the enable, something ran the handler before the first entry",
                   a12_cell_at_entry, a12_cell_at_enable);

        repeat (600) @(posedge clk);
        #1;
        entries_now = m_irq_entries - a12_entry_at_enable;
        cell_now = chr_mmc3.u_bus.ram_array[11'h013];
        if (entries_now < 1)
            $fatal(1, "P1-11 the cpu took no irq entry at all in the %0d clk after the enable", 600);
        if (m_irq_vec_fetch <= a12_vec_at_enable)
            $fatal(1, "P1-11 the cpu never fetched the irq vector from fffe after the enable");
        if (a12_handler_clk < 1)
            $fatal(1, "P1-11 the cpu pc never sat at the irq handler %04h after the enable", IRQ_HANDLER);
        if (m_irq_line_err != 0)
            $fatal(1, "P1-11 irq_line != (mapper_irq|apu_irq) on %0d clk", m_irq_line_err);
        if (m_irq_pending_err != 0)
            $fatal(1, "P1-11 dbg_irq_pending != irq_line on %0d clk", m_irq_pending_err);
        if (m_irq_entry_bad != 0)
            $fatal(1, "P1-11 %0d irq entries were not 7 bus-fire cycles long, offending entry was %0d ce with the state list %0d %0d %0d %0d %0d %0d %0d %0d",
                   m_irq_entry_bad, m_bad_ce_n,
                   m_bad_seq[0], m_bad_seq[1], m_bad_seq[2], m_bad_seq[3],
                   m_bad_seq[4], m_bad_seq[5], m_bad_seq[6], m_bad_seq[7]);
        if (m_irq_entry_stall != 0)
            $fatal(1, "P1-11 %0d irq sequences stalled instead of completing", m_irq_entry_stall);
        if (m_irq_seq_bad != 0)
            $fatal(1, "P1-11 %0d irq entries ran a state list other than fetch,dummy,push-hi,push-lo,push-p,vec-lo,vec-hi",
                   m_irq_seq_bad);
        if (m_irq_masked != 0)
            $fatal(1, "P1-11 the cpu took %0d irq entries with the i flag set", m_irq_masked);
        if (cell_now === a12_cell_at_entry)
            $fatal(1, "P1-11 ram[0013] is still %02x after %0d irq entries, the handler at %04h never ran",
                   cell_now, entries_now, IRQ_HANDLER);
        if (a12_apu_hi != 0)
            $fatal(1, "P1-11 the apu irq line was high on %0d clk of phase 2b, irq_line would not be attributable to the mapper",
                   a12_apu_hi);
        $display("P1-11 A12-PHASE-2B ONLY irq_enabled_r was forced to 1; irq_pending_r was never forced and had to be produced by the rtl out of irq_counter_next == 0.  The enable was armed while the counter sat on its reload point %0d, so the whole canonical 8-edge walk (reload to %02h, then 6,5,4,3,2,1,0) sits between the enable and the assertion.  mapper_irq stayed low for the first %0d accepted edges after the enable and irq_line was high on %0d clk before the line out of the %0d clk it was high in for phase 2b, so m_irq_high could not have moved first, then the line went high on accepted edge %0d, which is exactly 8 after the edge index %0d recorded at the enable and exactly what the counter's own next-value walk owes.  The whole existing machinery then carried it: irq_line == (mapper_irq|apu_irq) on every clk (%0d err), dbg_irq_pending == irq_line (%0d err), %0d entries of exactly 7 bus-fire cycles (min=%0d max=%0d, %0d not-7, %0d wrong state lists, %0d stalled, %0d taken with the i flag set), fffe fetched %0d times, the pc sat at the handler %04h on %0d clk, and ram[0013] moved %02x -> %02x over %0d entries (latched at the FIRST entry, not at the end) PASS",
                 a12_counter_at_enable, MMC3_IRQ_LATCH_VALUE,
                 a12_idx_at_irq - a12_edge_at_enable, a12_early_hi_err,
                 a12_line_hi_2b,
                 a12_idx_at_irq, a12_edge_at_enable,
                 m_irq_line_err,
                 m_irq_pending_err, entries_now, m_irq_entry_min,
                 m_irq_entry_max, m_irq_entry_bad, m_irq_seq_bad,
                 m_irq_entry_stall, m_irq_masked,
                 m_irq_vec_fetch - a12_vec_at_enable, IRQ_HANDLER,
                 a12_handler_clk, a12_cell_at_entry[7:0],
                 chr_mmc3.u_bus.ram_array[11'h013], entries_now);

        // -------------------------------------------------------- PHASE 2c
        a12_phase = 2'd3;
        a12_early_armed = 1'b0;
        // force-to-0 BEFORE release, the v5 idiom, so the fall is caused by the
        // AND at irq = irq_enabled_r && irq_pending_r and not by the rtl
        // re-deciding the value.
        force chr_mmc3.u_mapper.u_mmc3.irq_enabled_r = 1'b0;
        #1;
        if (chr_mmc3.u_mapper.mmc3_irq_pending !== 1'b1)
            $fatal(1, "P1-11 irq_pending is %b with the counter at 0 and the irq just disabled, the rtl is supposed to be holding it set",
                   chr_mmc3.u_mapper.mmc3_irq_pending);
        if (m_mapper_irq !== 1'b0)
            $fatal(1, "P1-11 mapper_irq stayed high with irq_pending=1 and irq_enabled_r forced to 0, so irq is not enabled && pending");
        if (m_irq_line !== 1'b0)
            $fatal(1, "P1-11 irq_line stayed high with the mapper irq driven low and the apu irq low");
        release chr_mmc3.u_mapper.u_mmc3.irq_enabled_r;
        release chr_mmc3.mapper_ppu_a12;

        // BOTH sides of the tie-off, re-proved on the far side of the window.
        #1;
        if (chr_mmc3.mapper_ppu_a12 !== 1'b0)
            $fatal(1, "P1-11 mapper_ppu_a12 is %b after the release, nes_system_v6 is supposed to tie it low",
                   chr_mmc3.mapper_ppu_a12);
        if (chr_mmc3.u_mapper.u_mmc3.ppu_a12 !== 1'b0)
            $fatal(1, "P1-11 the mmc3 a12 input is %b after the release, it is supposed to be tied low",
                   chr_mmc3.u_mapper.u_mmc3.ppu_a12);

        // the monitor keeps running (a12_win is still 1, a12_phase is 0 so it
        // only tracks edges) so the "no edge, no filter" claim is measured.
        a12_phase = 2'd0;
        a12_snap2_idx = a12_snap_idx;
        a12_drain_entry_n = m_irq_entries;
        a12_mapper_base = a12_mapper_hi;
        repeat (400) @(posedge clk);
        #1;
        if (a12_snap_idx != a12_snap2_idx)
            $fatal(1, "P1-11 the mmc3 a12 filter fired %0d more times in the 400 clk after the release, with ppu_a12 back at its production tie-off",
                   a12_snap_idx - a12_snap2_idx);
        if (a12_edge_idx != a12_snap2_idx)
            $fatal(1, "P1-11 the model rose %0d more times after the release without reaching the port",
                   a12_edge_idx - a12_snap2_idx);
        if (m_mapper_irq !== 1'b0)
            $fatal(1, "P1-11 mapper_irq is high again after the release");
        if (m_irq_line !== 1'b0)
            $fatal(1, "P1-11 irq_line is high again after the release");
        if (a12_mapper_hi != a12_mapper_base)
            $fatal(1, "P1-11 mapper_irq was high on %0d more clk in the 400 clk after the mapper irq was disabled",
                   a12_mapper_hi - a12_mapper_base);
        if (m_irq_entries != a12_drain_entry_n)
            $fatal(1, "P1-11 the cpu took %0d more irq entries in the 400 clk after the mapper irq fell",
                   m_irq_entries - a12_drain_entry_n);
        if (m_irq_line_err != 0)
            $fatal(1, "P1-11 irq_line != (mapper_irq|apu_irq) on %0d clk", m_irq_line_err);
        if (m_irq_pending_err != 0)
            $fatal(1, "P1-11 dbg_irq_pending != irq_line on %0d clk", m_irq_pending_err);
        a12_win = 1'b0;
        $display("P1-11 A12-PHASE-2C forcing irq_enabled_r to 0 with irq_pending_r still 1, a state only the rtl can be in here, dropped mapper_irq and irq_line combinationally, which is the AND at nes_mapper_mmc3 irq = irq_enabled_r && irq_pending_r and not a register clearing.  Both forces were then released and the window left: the tb had driven the production net chr_mmc3.mapper_ppu_a12 high on %0d clk of the window, and after the release that net reads %b and chr_mmc3.u_mapper.u_mmc3.ppu_a12 reads %b again, so the production tie-off is re-proved on BOTH sides of the force window.  mmc3_a12_filtered did not fire once in the following 400 clk (%0d accepted edges, %0d model rises), mapper_irq stayed low on all of them, and the cpu took %0d new irq entries PASS",
                 a12_net_hi, chr_mmc3.mapper_ppu_a12,
                 chr_mmc3.u_mapper.u_mmc3.ppu_a12,
                 a12_snap_idx - a12_snap2_idx, a12_edge_idx - a12_snap2_idx,
                 m_irq_entries - a12_drain_entry_n);
    end
endtask

task check_p1_5;
    begin
        if (chr_mmc3.u_mapper.mmc3_irq_latch !== MMC3_IRQ_LATCH_VALUE)
            $fatal(1, "P1-5 the mmc3 irq latch is %02h expected %02h",
                   chr_mmc3.u_mapper.mmc3_irq_latch, MMC3_IRQ_LATCH_VALUE);
        if (chr_mmc3.u_mapper.mmc3_irq_reload !== 1'b1)
            $fatal(1, "P1-5 the mmc3 reload flag fell back to 0, mapper_ppu_a12 is supposed to be tied low");
        if (chr_mmc3.u_mapper.mmc3_irq_counter !== 8'h00)
            $fatal(1, "P1-5 the mmc3 irq counter moved to %02h without any a12 edge",
                   chr_mmc3.u_mapper.mmc3_irq_counter);
        if (chr_mmc3.mapper_ppu_a12 !== 1'b0)
            $fatal(1, "P1-5 mapper_ppu_a12 is %b, nes_system_v6 is supposed to tie it low",
                   chr_mmc3.mapper_ppu_a12);
        if (chr_mmc3.u_mapper.u_mmc3.ppu_a12 !== 1'b0)
            $fatal(1, "P1-5 the mmc3 a12 input is %b, it is supposed to be tied low",
                   chr_mmc3.u_mapper.u_mmc3.ppu_a12);
        if (chr_mmc3.u_mapper.mmc3_a12_filtered !== 1'b0)
            $fatal(1, "P1-5 the mmc3 a12 filter fired without an a12 edge");
        if (chr_mmc3.u_mapper.mmc3_irq_enabled !== 1'b0)
            $fatal(1, "P1-5 the mmc3 irq is still enabled after the e000 write");
        if (m_irq_high_at_force != 0)
            $fatal(1, "P1-5 the mmc3 irq line was already high on %0d clk before the force", m_irq_high_at_force);
        if (m_mapper_irq !== 1'b0)
            $fatal(1, "P1-5 the mmc3 mapper irq is high with the a12 input tied low");
        m_irq_high_at_force = m_irq_high;
        $display("P1-5 MMC3-A12-AND-FORCE on chr_mmc3 only: $C000 latched %02h, $C001 set reload and it is still set, the counter is still %02h and the a12 filter never fired because mapper_ppu_a12 is hardwired 0 inside nes_system_v6, $E001 then $E000 left irq_enabled=0, and mapper_irq stayed low on every one of the %0d clk of the whole program before the force.  The two tie-off assertions above are therefore measured with no force anywhere on this instance; the force block below only overrides the two irq registers for 600 clk, and check_p1_11 then runs immediately afterwards on the same instance, driving the mmc3 a12 from a testbench-side ppu-dot model so the counter, irq_pending_r and the whole irq entry chain come out of real rtl instead of a forced value, and re-proves both tie-offs on the far side of its own force window PASS",
                 MMC3_IRQ_LATCH_VALUE, chr_mmc3.u_mapper.mmc3_irq_counter, m_irq_high_at_force);

        force chr_mmc3.u_mapper.u_mmc3.irq_enabled_r = 1'b1;
        force chr_mmc3.u_mapper.u_mmc3.irq_pending_r = 1'b1;
        repeat (600) @(posedge clk);
        #1;
        if (m_mapper_irq !== 1'b1)
            $fatal(1, "P1-5 forcing the mmc3 irq source did not raise the mapper irq output");
        if (m_irq_line !== 1'b1)
            $fatal(1, "P1-5 the mapper irq did not reach the combined irq line");
        if (chr_mmc3.u_cpu.dbg_irq_pending !== 1'b1)
            $fatal(1, "P1-5 the cpu irq_i did not follow the mapper irq");
        if (m_irq_line_err != 0)
            $fatal(1, "P1-5 irq_line != (mapper_irq|apu_irq) on %0d clk", m_irq_line_err);
        if (m_irq_pending_err != 0)
            $fatal(1, "P1-5 dbg_irq_pending != irq_line on %0d clk", m_irq_pending_err);
        if (m_irq_rise < 1)
            $fatal(1, "P1-5 the forced irq line never rose");
        if (m_irq_entries < 1)
            $fatal(1, "P1-5 the cpu never entered the irq sequence");
        if (m_irq_entry_bad != 0)
            $fatal(1, "P1-5 %0d irq entries were not 7 bus-fire cycles long, offending entry was %0d ce with the state list %0d %0d %0d %0d %0d %0d %0d %0d, entry-length histogram",
                   m_irq_entry_bad, m_bad_ce_n,
                   m_bad_seq[0], m_bad_seq[1], m_bad_seq[2], m_bad_seq[3],
                   m_bad_seq[4], m_bad_seq[5], m_bad_seq[6], m_bad_seq[7]);
        if (m_irq_entry_stall != 0)
            $fatal(1, "P1-5 %0d irq sequences stalled instead of completing", m_irq_entry_stall);
        if (m_irq_seq_bad != 0)
            $fatal(1, "P1-5 %0d irq entries ran a state list other than fetch,dummy,push-hi,push-lo,push-p,vec-lo,vec-hi",
                   m_irq_seq_bad);
        if (m_irq_masked != 0)
            $fatal(1, "P1-5 the cpu took %0d irq entries with the i flag set", m_irq_masked);
        if (m_irq_vec_fetch < 1)
            $fatal(1, "P1-5 the cpu never fetched the irq vector from fffe");
        if (chr_mmc3.u_bus.ram_array[11'h013] === 8'h00)
            $fatal(1, "P1-5 the irq handler never incremented ram[0013]");
        // The v5 idiom: force to 0 BEFORE release, so the line is observably
        // driven low by the release rather than by the rtl re-deciding.
        force chr_mmc3.u_mapper.u_mmc3.irq_enabled_r = 1'b0;
        force chr_mmc3.u_mapper.u_mmc3.irq_pending_r = 1'b0;
        release chr_mmc3.u_mapper.u_mmc3.irq_enabled_r;
        release chr_mmc3.u_mapper.u_mmc3.irq_pending_r;
        repeat (400) @(posedge clk);
        #1;
        if (m_mapper_irq !== 1'b0)
            $fatal(1, "P1-5 the mapper irq is still high after the force was released");
        $display("P1-5 IRQ-FORCE forcing chr_mmc3.u_mapper.u_mmc3.irq_enabled_r and .irq_pending_r drove mapper_irq=1 -> irq_line=1 -> u_cpu.dbg_irq_pending=1 (irq_line=(mapper_irq|apu_irq) on every clk, %0d err; dbg_irq_pending==irq_line, %0d err), and the cpu took %0d irq entries of exactly 7 bus-fire cycles each (min=%0d max=%0d, %0d not-7, %0d wrong state lists, %0d stalled, %0d taken with the i flag set) and fetched fffe %0d times and the handler at %04h incremented ram[0013] to %02x; after force-to-0 and release the line fell again PASS",
                 m_irq_line_err, m_irq_pending_err, m_irq_entries,
                 m_irq_entry_min, m_irq_entry_max, m_irq_entry_bad,
                 m_irq_seq_bad, m_irq_entry_stall, m_irq_masked, m_irq_vec_fetch,
                 IRQ_HANDLER, chr_mmc3.u_bus.ram_array[11'h013]);

        // The counter, irq_pending_r and the cpu entry chain have just been
        // driven by a force instead of by an a12 edge.  check_p1_11 is what
        // turns that around: it supplies the missing a12 and re-derives all
        // three from the rtl, so the assertions above are not left resting on
        // a forced value.  It runs last, after both forces are released, and
        // it cleans up after itself.
        check_p1_11;
    end
endtask

task check_p1_1;
    begin
        if (bus_stall_err != 0)
            $fatal(1, "P1-1 bus_stall != bus_req&&!bus_fire on %0d ce_cpu",
                   bus_stall_err);
        if (bus_wait_count_bad != 0)
            $fatal(1, "P1-1 dbg_wait_count was nonzero on %0d clk",
                   bus_wait_count_bad);
        if (prg_rd_err != 0)
            $fatal(1, "P1-1 %0d cart reads disagreed with the tb prg bank model",
                   prg_rd_err);
        if (prg_rd_count < 1000)
            $fatal(1, "P1-1 only %0d cart reads were checked", prg_rd_count);
        if (chr_req_bus_idle < 1000)
            $fatal(1, "P1-1 the chr port only produced %0d requests with the cpu bus idle, it looks coupled to the bus",
                   chr_req_bus_idle);
        if (chr_req_owner[3'd0] + chr_req_owner[3'd1] + chr_req_owner[3'd2] +
            chr_req_owner[3'd3] + chr_req_owner[3'd5] < 100)
            $fatal(1, "P1-1 chr requests never appeared across the cpu bus owners");
        $display("P1-1 BUS stall=req&&!fire on every ce_cpu (%0d err), dbg_wait_count=0 on every clk (%0d err), cart reads=%0d matched the independent tb prg bank model for mapper_prg_bank_offset, cart_din and bus_din (err=%0d), transfers=%0d PASS",
                 bus_stall_err, bus_wait_count_bad, prg_rd_count, prg_rd_err,
                 bus_fire_count);
        $display("P1-1 CHR-OFF-BUS chr requests with the cpu bus idle=%0d of %0d, while the dma held the bus=%0d, by bus_owner open/ram/ppu/apu/cartrom=%0d/%0d/%0d/%0d/%0d, so the chr port is structurally off the cpu bus PASS",
                 chr_req_bus_idle, chr_req_total, chr_req_during_dma,
                 chr_req_owner[3'd0], chr_req_owner[3'd1], chr_req_owner[3'd2],
                 chr_req_owner[3'd3], chr_req_owner[3'd5]);
    end
endtask

task check_p1_2;
    begin
        if (dma_start_count != 1)
            $fatal(1, "P1-2 oam dma start count got %0d expected 1", dma_start_count);
        if (dma_done_count != 1)
            $fatal(1, "P1-2 oam dma done count got %0d expected 1", dma_done_count);
        if (dma_ack_count != 256)
            $fatal(1, "P1-2 total dma acks got %0d expected 256", dma_ack_count);
        if (dma_wr_count != 256)
            $fatal(1, "P1-2 total dma $2004 writes got %0d expected 256", dma_wr_count);
        if (dma_addr_err != 0)
            $fatal(1, "P1-2 the dma read %0d bytes from an unexpected address",
                   dma_addr_err);
        if (dma_data_err != 0)
            $fatal(1, "P1-2 the dma moved %0d bytes with the wrong data",
                   dma_data_err);
        if (dma_unimpl_seen != 0)
            $fatal(1, "P1-2 the dma hit an mmio window %0d times", dma_unimpl_seen);
        if (dma_ppu_addr_err != 0)
            $fatal(1, "P1-2 the dma drove %0d ppu cycles at the wrong register",
                   dma_ppu_addr_err);
        if (dma_ppu_we_err != 0)
            $fatal(1, "P1-2 the dma drove %0d read cycles on the ppu port",
                   dma_ppu_we_err);
        if (ab_v6.u_ppu.oam_ram[0] !== 8'h11 || ab_v6.u_ppu.oam_ram[1] !== 8'h22 ||
            ab_v6.u_ppu.oam_ram[2] !== 8'h33 || ab_v6.u_ppu.oam_ram[3] !== 8'h44)
            $fatal(1, "P1-2 oam_ram[0..3] = %02h %02h %02h %02h expected 11 22 33 44",
                   ab_v6.u_ppu.oam_ram[0], ab_v6.u_ppu.oam_ram[1],
                   ab_v6.u_ppu.oam_ram[2], ab_v6.u_ppu.oam_ram[3]);
        for (k = 0; k < 256; k = k + 1) begin
            if (ab_v6.u_ppu.oam_ram[k] !== table1[k])
                $fatal(1, "P1-2 oam[%0d] is %02x expected %02x",
                       k, ab_v6.u_ppu.oam_ram[k], table1[k]);
            if (ab_v5.u_ppu.oam_ram[k] !== table1[k])
                $fatal(1, "P1-2 v5 oam[%0d] is %02x expected %02x",
                       k, ab_v5.u_ppu.oam_ram[k], table1[k]);
        end
        k = 0;
        $display("P1-2 OAMDMA starts=%0d done=%0d acks=%0d $2004 writes=%0d addr err=%0d data err=%0d mmio hits=%0d wrong-reg=%0d, reg_addr=4 still lands in the EXTERNAL_CHR ppu: oam_ram[0..3]=%02h %02h %02h %02h and all 256 bytes match the source page PASS",
                 dma_start_count, dma_done_count, dma_ack_count, dma_wr_count,
                 dma_addr_err, dma_data_err, dma_unimpl_seen, dma_ppu_addr_err,
                 ab_v6.u_ppu.oam_ram[0], ab_v6.u_ppu.oam_ram[1],
                 ab_v6.u_ppu.oam_ram[2], ab_v6.u_ppu.oam_ram[3]);
    end
endtask

task check_p1_3;
    begin
        if (v6_mapper_mirroring !== DUT_HEADER_MIRRORING)
            $fatal(1, "P1-3 mapper_mirroring is %0d, the iNES header says %0d",
                   v6_mapper_mirroring, DUT_HEADER_MIRRORING);
        if (v5_mapper_mirroring !== DUT_HEADER_MIRRORING)
            $fatal(1, "P1-3 v5 mapper_mirroring is %0d, the header says %0d",
                   v5_mapper_mirroring, DUT_HEADER_MIRRORING);
        if (v6_mapper_nametable_map !== 8'b01000100)
            $fatal(1, "P1-3 nametable_map is %02h, vertical mode decodes to 44",
                   v6_mapper_nametable_map);
        if (v6_mapper_nametable_map !== v5_mapper_nametable_map)
            $fatal(1, "P1-3 the two instances disagree on nametable_map");
        $display("P1-3 MIRRORING ines header=%0d -> mapper_mirroring=%0d/%0d, nametable_map=%02h/%02h, KNOWN GAP: nes_ppu2c02 has no runtime mirroring port and both instances are elaborated with MIRROR_VERTICAL=0, so the mode is observed but not applied PASS",
                 DUT_HEADER_MIRRORING, v6_mapper_mirroring, v5_mapper_mirroring,
                 v6_mapper_nametable_map, v5_mapper_nametable_map);
    end
endtask

task check_p1_4;
    begin
        if (irq_line_err != 0)
            $fatal(1, "P1-4 irq_line != (mapper_irq|apu_irq) on %0d clk", irq_line_err);
        if (irq_pending_err != 0)
            $fatal(1, "P1-4 dbg_irq_pending != irq_line on %0d clk", irq_pending_err);
        if (mapper_irq_high != 0)
            $fatal(1, "P1-4 NROM mapper_irq was high on %0d clk", mapper_irq_high);
        if (apu_irq_high != 0)
            $fatal(1, "P1-4 apu_irq_o was high on %0d clk under $4017=%02h",
                   apu_irq_high, FRAME_IRQ_INHIBIT);
        $display("P1-4 IRQ irq_line=(mapper_irq|apu_irq) on every clk (err=%0d), u_cpu.dbg_irq_pending==irq_line (err=%0d), NROM mapper_irq high on %0d clk, apu_irq_o high on %0d clk under $4017=%02h PASS",
                 irq_line_err, irq_pending_err, mapper_irq_high, apu_irq_high,
                 FRAME_IRQ_INHIBIT);
    end
endtask

task check_p1_6;
    begin
        if (nmi_rise_count != nmi_entry_count)
            $fatal(1, "P1-6 nmi rises %0d do not match vector fetches %0d",
                   nmi_rise_count, nmi_entry_count);
        if (nmi_rise_count < 1)
            $fatal(1, "P1-6 no nmi edge was seen");
        if (ab_v6.u_bus.ram_array[NMI_COUNTER_CELL[10:0]] !== nmi_entry_count[7:0])
            $fatal(1, "P1-6 nmi counter cell is %02x expected %0d",
                   ab_v6.u_bus.ram_array[NMI_COUNTER_CELL[10:0]], nmi_entry_count);
        $display("P1-6 NMI nmi_o == vblank && ppuctrl[7] asserted on every clk of %0d frames, rises=%0d fffa vector fetches=%0d ram[0010]=%02x PASS",
                 frames_seen, nmi_rise_count, nmi_entry_count,
                 ab_v6.u_bus.ram_array[NMI_COUNTER_CELL[10:0]]);
    end
endtask

task check_p1_7;
    begin
        if (ctrl_rd_seen != CTRL_READS)
            $fatal(1, "P1-7 controller read count got %0d expected %0d",
                   ctrl_rd_seen, CTRL_READS);
        if (apu_rd_ctrl1 != 9 || apu_rd_ctrl2 != 9)
            $fatal(1, "P1-7 controller read counts got %0d/%0d expected 9 each",
                   apu_rd_ctrl1, apu_rd_ctrl2);
        if (ctrl_data_err != 0)
            $fatal(1, "P1-7 the cpu saw %0d wrong controller data bits", ctrl_data_err);
        if (ctrl_cs_err != 0)
            $fatal(1, "P1-7 apu_reg_cs leaked onto the controller reads %0d times",
                   ctrl_cs_err);
        if (ab_v6.u_bus.ram_array[PORT1_9TH_CELL[10:0]] !== 8'h01)
            $fatal(1, "P1-7 the 9th port 1 read gave %02x expected 01",
                   ab_v6.u_bus.ram_array[PORT1_9TH_CELL[10:0]]);
        if (ab_v6.u_bus.ram_array[PORT2_9TH_CELL[10:0]] !== 8'h01)
            $fatal(1, "P1-7 the 9th port 2 read gave %02x expected 01",
                   ab_v6.u_bus.ram_array[PORT2_9TH_CELL[10:0]]);
        for (k = 0; k < 8; k = k + 1) begin
            if (ab_v6.u_bus.ram_array[PORT1_CELL_BASE[10:0] + k] !== BUTTONS1[k])
                $fatal(1, "P1-7 port 1 bit %0d cell is %02x expected %02x",
                       k, ab_v6.u_bus.ram_array[PORT1_CELL_BASE[10:0] + k],
                       BUTTONS1[k]);
            if (ab_v6.u_bus.ram_array[PORT2_CELL_BASE[10:0] + k] !== BUTTONS2[k])
                $fatal(1, "P1-7 port 2 bit %0d cell is %02x expected %02x",
                       k, ab_v6.u_bus.ram_array[PORT2_CELL_BASE[10:0] + k],
                       BUTTONS2[k]);
        end
        k = 0;
        $display("P1-7 CONTROLLER $4016 written 1 then 0 four times (%0d writes), 8 reads rebuilt %02h into ram 0020-0027 and 8 reads of $4017 rebuilt %02h into ram 0028-002f, the 9th read of each returned 1, apu_reg_cs never leaked onto those reads PASS",
                 ctrl_wr_count, BUTTONS1, BUTTONS2);
    end
endtask

task check_p1_8;
    begin
        if (sample_strobes < 1)
            $fatal(1, "P1-8 no audio sample strobes were seen");
        if (sample_nonzero < 1)
            $fatal(1, "P1-8 pulse1 never produced a non zero sample");
        if (dmc_req_seen != 0)
            $fatal(1, "P1-8 apu_dmc_bus_req went high %0d times", dmc_req_seen);
        if (dmc_sel_seen != 0)
            $fatal(1, "P1-8 the dmc port was selected %0d times", dmc_sel_seen);
        if (ab_v6.u_apu.dbg_dmc_irq !== 1'b0)
            $fatal(1, "P1-8 the dmc raised an irq");
        $display("P1-8 AUDIO sample strobes=%0d nonzero=%0d peak=%0d, dmc bus requests=%0d dmc bus grants=%0d, frame irq inhibited by $4017=%02h PASS",
                 sample_strobes, sample_nonzero, sample_peak, dmc_req_seen,
                 dmc_sel_seen, FRAME_IRQ_INHIBIT);
    end
endtask

task check_p1_9;
    begin
        if (ab_v6.u_ppu.control_reg !== PPUCTRL_FINAL)
            $fatal(1, "P1-9 v6 ppuctrl is %02x expected %02x",
                   ab_v6.u_ppu.control_reg, PPUCTRL_FINAL);
        if (ab_v5.u_ppu.control_reg !== PPUCTRL_FINAL)
            $fatal(1, "P1-9 v5 ppuctrl is %02x expected %02x",
                   ab_v5.u_ppu.control_reg, PPUCTRL_FINAL);
        if (ab_v6.u_ppu.mask_reg !== PPUMASK_FINAL)
            $fatal(1, "P1-9 v6 ppumask is %02x expected %02x",
                   ab_v6.u_ppu.mask_reg, PPUMASK_FINAL);
        if (ab_v5.u_ppu.mask_reg !== PPUMASK_FINAL)
            $fatal(1, "P1-9 v5 ppumask is %02x expected %02x",
                   ab_v5.u_ppu.mask_reg, PPUMASK_FINAL);
        if (ab_v6.u_ppu.v_addr !== 15'h0000 || ab_v5.u_ppu.v_addr !== 15'h0000)
            $fatal(1, "P1-9 ppu v is %04x/%04x expected 0000",
                   ab_v6.u_ppu.v_addr, ab_v5.u_ppu.v_addr);
        if (ab_v6.u_ppu.temp_addr !== 15'h0000 || ab_v5.u_ppu.temp_addr !== 15'h0000)
            $fatal(1, "P1-9 ppu t is %04x/%04x expected 0000",
                   ab_v6.u_ppu.temp_addr, ab_v5.u_ppu.temp_addr);
        if (ab_v6.u_ppu.fine_x !== 3'd0 || ab_v5.u_ppu.fine_x !== 3'd0)
            $fatal(1, "P1-9 ppu fine x is %0d/%0d expected 0",
                   ab_v6.u_ppu.fine_x, ab_v5.u_ppu.fine_x);
        if (ab_v6.u_ppu.write_toggle !== 1'b0 || ab_v5.u_ppu.write_toggle !== 1'b0)
            $fatal(1, "P1-9 ppu w is %b/%b expected 0",
                   ab_v6.u_ppu.write_toggle, ab_v5.u_ppu.write_toggle);
        if (ab_v6.u_ppu.oam_addr_reg !== 8'h01 || ab_v5.u_ppu.oam_addr_reg !== 8'h01)
            $fatal(1, "P1-9 ppu oamaddr is %02x/%02x expected 01",
                   ab_v6.u_ppu.oam_addr_reg, ab_v5.u_ppu.oam_addr_reg);
        if (ab_v6.u_ppu.nametable_ram[1] !== 8'h01)
            $fatal(1, "P1-9 v6 nametable[1] is %02x expected 01",
                   ab_v6.u_ppu.nametable_ram[1]);
        if (ab_v6.u_ppu.palette_ram[5'h00] !== 8'h0F ||
            ab_v6.u_ppu.palette_ram[5'h01] !== 8'h21 ||
            ab_v6.u_ppu.palette_ram[5'h02] !== 8'h32 ||
            ab_v6.u_ppu.palette_ram[5'h11] !== 8'h16)
            $fatal(1, "P1-9 v6 palette is %02h %02h %02h / %02h expected 0f 21 32 / 16",
                   ab_v6.u_ppu.palette_ram[5'h00], ab_v6.u_ppu.palette_ram[5'h01],
                   ab_v6.u_ppu.palette_ram[5'h02], ab_v6.u_ppu.palette_ram[5'h11]);
        $display("P1-9 PPUREG checkpoint v6/v5 ctrl=%02h/%02h mask=%02h/%02h v=%04h/%04h t=%04h/%04h w=%b/%b finex=%0d/%0d oamaddr=%02x/%02h, nt[1]=%02h pal=0f,21,32 and 11=16, $2005/$2006 did not drift PASS",
                 ab_v6.u_ppu.control_reg, ab_v5.u_ppu.control_reg,
                 ab_v6.u_ppu.mask_reg, ab_v5.u_ppu.mask_reg,
                 ab_v6.u_ppu.v_addr, ab_v5.u_ppu.v_addr,
                 ab_v6.u_ppu.temp_addr, ab_v5.u_ppu.temp_addr,
                 ab_v6.u_ppu.write_toggle, ab_v5.u_ppu.write_toggle,
                 ab_v6.u_ppu.fine_x, ab_v5.u_ppu.fine_x,
                 ab_v6.u_ppu.oam_addr_reg, ab_v5.u_ppu.oam_addr_reg,
                 ab_v6.u_ppu.nametable_ram[1]);
    end
endtask

task check_p1_10;
    begin
        if (!saw_reset_lo || !saw_reset_hi || !saw_first_fetch || !saw_first_opcode)
            $fatal(1, "P1-10 cpu reset sequence incomplete lo=%b hi=%b fetch=%b opcode=%b",
                   saw_reset_lo, saw_reset_hi, saw_first_fetch, saw_first_opcode);
        if (reset_lo_addr !== 16'hFFFC || reset_hi_addr !== 16'hFFFD)
            $fatal(1, "P1-10 reset vector read %04h/%04h expected fffc/fffd",
                   reset_lo_addr, reset_hi_addr);
        if (illegal_hits != 0)
            $fatal(1, "P1-10 the cpu decoded %0d illegal opcodes", illegal_hits);
        if (seen_main_loop !== 1'b1)
            $fatal(1, "P1-10 the cpu never reached the main program self loop");
        $display("P1-10 CPU fffc/fffd -> pc=8000, first opcode=58, illegal opcodes=%0d, no fail loop at %04h/%04h/%04h entered, cpu reached the self loop PASS",
                 illegal_hits, FAIL1, FAIL2, FAIL3);
        $display("PRG main $%04h-$%04h (%0d bytes), nmi handler $%04h-$%04h, irq handler $%04h-$%04h, fail loops $%04h/$%04h/$%04h, chr fill constants $%04h=$%02h/$%04h=$%02h, table $%04h, vectors fffa=$%04h fffc=$%04h fffe=$%04h, cart writes a000=5a b123=a5 ffc0=3c",
                 MAIN_PROG, main_prog_end - 16'd1, main_prog_end - MAIN_PROG,
                 NMI_HANDLER, nmi_end - 16'd1,
                 IRQ_HANDLER, irq_end - 16'd1,
                 FAIL1, FAIL2, FAIL3,
                 CHR_FILL_ON_ADDR, CHR_FILL_RUN_A_ON,
                 CHR_FILL_OFF_ADDR, CHR_FILL_RUN_A_OFF,
                 TABLE1_ADDR, NMI_HANDLER, MAIN_PROG, IRQ_HANDLER);
    end
endtask

task check_bus_accounting;
    begin
        if (prg_rd_count + prg_wr_count + ram_rd_count + ram_wr_count +
            ppu_rd_count + ppu_wr_count + apu_rd_count + apu_wr_count +
            open_rd_count + cartram_rd_count != bus_fire_count)
            $fatal(1, "bus cycle accounting does not close: prgrd=%0d prgwr=%0d ramrd=%0d ramwr=%0d ppurd=%0d ppuwr=%0d apurd=%0d apuwr=%0d open=%0d cartram=%0d of %0d",
                   prg_rd_count, prg_wr_count, ram_rd_count, ram_wr_count,
                   ppu_rd_count, ppu_wr_count, apu_rd_count, apu_wr_count,
                   open_rd_count, cartram_rd_count, bus_fire_count);
        if (ram_wr_src != 256)
            $fatal(1, "the dma source page got %0d ram writes expected 256",
                   ram_wr_src);
        if (ram_wr_dma != 2)
            $fatal(1, "the dma flag cell was written %0d times expected 2",
                   ram_wr_dma);
        if (ram_wr_oamrb != 2)
            $fatal(1, "the oam readback flag cell was written %0d times expected 2",
                   ram_wr_oamrb);
        $display("BUS owner accounting prg_rd=%0d prg_wr=%0d ram_rd=%0d ram_wr=%0d ppu_rd=%0d ppu_wr=%0d apu_rd=%0d apu_wr=%0d open=%0d cartram_rd=%0d of %0d transfers PASS",
                 prg_rd_count, prg_wr_count, ram_rd_count, ram_wr_count,
                 ppu_rd_count, ppu_wr_count, apu_rd_count, apu_wr_count,
                 open_rd_count, cartram_rd_count, bus_fire_count);
    end
endtask

// ------------------------------------------------------------------- main

initial begin
    reset_clks = 0;
    reset_chr_req_bad = 0;
    reset_chr_addr_bad = 0;
    reset_chr_we_bad = 0;
    reset_chr_waddr_bad = 0;
    reset_mapper_id_bad = 0;
    chr_pred_race_skip = 0;
    chr_latch_race_skip = 0;
    chr_wr_beats = 0;
    chr_wr_exp_total = 0;
    chr_wr_checks = 0;
    chr_wr_addr_err = 0;
    chr_wr_req_clash = 0;
    chr_wr_clash_visible = 0;
    chr_wr_bit13_bad = 0;
    chr_wr_not_accepted = 0;
    chr_wr_consec = 0;
    chr_wr_prev = 1'b0;
    chr_write_on_port = 1'b0;
    chr_wr_exp_final = 17'd0;
    chr_wr_accepted = 0;
    m_wr_beats = 0;
    m_wr_exp_total = 0;
    m_wr_checks = 0;
    m_wr_addr_err = 0;
    m_wr_req_clash = 0;
    m_wr_clash_visible = 0;
    m_wr_bit13_bad = 0;
    m_wr_not_accepted = 0;
    m_wr_consec = 0;
    m_wr_accepted = 0;
    m_wr_prev = 1'b0;
    m_write_on_port = 1'b0;
    m_wr_exp_final = 17'd0;
    m_wr_low_hit = 0;
    m_wr_high_hit = 0;
    m_wr_odd_hit = 0;
    m_wr_low_flat = 0;
    m_wr_high_flat = 0;
    m_wr_odd_flat = 0;
    m_wr_low_before = 0;
    m_wr_high_before = 0;
    m_wr_odd_before = 0;
    rom_tile_err = 0;
    rb_tile_err = 0;
    rb_tile0_same = 0;
    frames_seen = 0;
    clk_count = 0;
    chr_req_total = 0;
    chr_addr_checks = 0;
    chr_addr_err = 0;
    chr_hi_addr_bad = 0;
    chr_req_bus_idle = 0;
    chr_req_during_dma = 0;
    chr_req_owner_total = 0;
    chr_model_pred_checks = 0;
    chr_model_pred_err = 0;
    chr_latch_checks = 0;
    chr_latch_err = 0;
    cart_wr_total = 0;
    cart_pulse_total = 0;
    cart_pulse_err = 0;
    cart_pulse_width_err = 0;
    cart_pulse_spurious = 0;
    cart_pulse_multi = 0;
    ab_visible_count = 0;
    ab_visible_div = 0;
    ab_all_ce_count = 0;
    ab_all_ce_div = 0;
    pix_index_mismatch = 0;
    pix_checked = 0;
    pix_cnt1 = 0;
    pix_cnt2 = 0;
    pix_cnt6 = 0;
    pix_other = 0;
    visible_pixels = 0;
    bus_stall_err = 0;
    bus_wait_count_bad = 0;
    bus_fire_count = 0;
    prg_rd_count = 0;
    prg_wr_count = 0;
    prg_rd_err = 0;
    cartram_rd_count = 0;
    ram_rd_count = 0;
    ram_wr_count = 0;
    ppu_rd_count = 0;
    ppu_wr_count = 0;
    apu_rd_count = 0;
    apu_wr_count = 0;
    open_rd_count = 0;
    apu_rd_ctrl1 = 0;
    apu_rd_ctrl2 = 0;
    apu_wr_ctrl = 0;
    apu_wr_frame = 0;
    apu_wr_status = 0;
    apu_rd_4015 = 0;
    apu_wr_dma = 0;
    ppu_wr_ctrl = 0;
    ppu_wr_mask = 0;
    ppu_wr_status = 0;
    ppu_wr_oamaddr = 0;
    ppu_wr_vaddr = 0;
    ppu_wr_vdata = 0;
    ppu_wr_other = 0;
    ram_wr_src = 0;
    ram_wr_nmi = 0;
    ram_wr_dma = 0;
    ram_wr_oamrb = 0;
    ram_wr_p1n = 0;
    ram_wr_p2n = 0;
    ctrl_rd_seen = 0;
    ctrl_wr_count = 0;
    ctrl_data_err = 0;
    ctrl_cs_err = 0;
    dma_start_count = 0;
    dma_done_count = 0;
    dma_ack_count = 0;
    dma_wr_count = 0;
    dma_addr_err = 0;
    dma_data_err = 0;
    dma_unimpl_seen = 0;
    dma_ppu_addr_err = 0;
    dma_ppu_we_err = 0;
    nmi_rise_count = 0;
    nmi_entry_count = 0;
    irq_rise_count = 0;
    irq_fall_count = 0;
    irq_line_err = 0;
    irq_pending_err = 0;
    mapper_irq_high = 0;
    apu_irq_high = 0;
    sample_strobes = 0;
    sample_nonzero = 0;
    sample_peak = 0;
    dmc_req_seen = 0;
    dmc_sel_seen = 0;
    illegal_hits = 0;
    bne_count = 0;
    tb_chr_bank_model = 4'd0;
    image_is_mmc3 = 1'b0;
    m_exp_index[0] = MMC3_EXP_INDEX_0;
    m_exp_index[1] = MMC3_EXP_INDEX_1;
    m_exp_index[2] = MMC3_EXP_INDEX_2;
    m_exp_index[3] = MMC3_EXP_INDEX_3;
    m_exp_index[4] = MMC3_EXP_INDEX_4;
    for (k = 0; k < 8; k = k + 1)
        chr_req_owner[k] = 0;
    for (k = 0; k < TB_WINDOW_BYTES; k = k + 1)
        tb_prg[k] = 8'h00;
    for (k = 0; k < TB_WINDOW_BYTES; k = k + 1)
        tb_prg_b[k] = 8'h00;
    for (k = 0; k < TB_WINDOW_BYTES; k = k + 1)
        m_prg[k] = 8'h00;

    build_chr_image;
    build_main;
    build_nmi_handler;
    build_irq_handler;
    build_fail_blocks;
    build_vectors;
    build_tables;
    load_chr;

    // Run B is run A's image with ONLY the two fill constants swapped.  Every
    // instruction byte is identical, which is what makes "the same program ran
    // with a different upload value" literally true rather than approximately
    // true, and it is also why chr_ram_b's sentinel has to be run A's image.
    for (k = 0; k < TB_WINDOW_BYTES; k = k + 1)
        tb_prg_b[k] = tb_prg[k];
    tb_prg_b[CHR_FILL_ON_ADDR[TB_WINDOW_BITS-1:0]] = CHR_FILL_RUN_B_ON;
    tb_prg_b[CHR_FILL_OFF_ADDR[TB_WINDOW_BITS-1:0]] = CHR_FILL_RUN_B_OFF;
    // W3's read-back expectations get the same treatment, so chr_ram_b still
    // executes byte-identical CODE while expecting the COMPLEMENT of everything
    // ab_v6 expects.  $8A04 is deliberately NOT swapped: an address nothing
    // writes holds the tb's load value in every model, so the unwritten read
    // expects the same byte in both images.
    tb_prg_b[CHR_RB_EXP_ON_ADDR[TB_WINDOW_BITS-1:0]] = CHR_FILL_RUN_B_ON;
    tb_prg_b[CHR_RB_EXP_OFF_ADDR[TB_WINDOW_BITS-1:0]] = CHR_FILL_RUN_B_OFF;
    k = 0;

    load_chr_rom;
    load_chr_ram_b;

    build_mmc3_main;
    build_mmc3_nmi_handler;
    build_mmc3_irq_handler;
    build_mmc3_fail_blocks;
    build_mmc3_vectors;
    build_mmc3_tables;
    load_chr_mmc3;
    // W2's untouched-address control needs a pre-run snapshot of the whole
    // 128 KiB array so "only these three bytes changed" is measured.
    for (i = 0; i < CHR_MEM_BYTES; i = i + 1)
        m_chr_pre[i] = m_chr_mem[i];

    for (i = 0; i < TB_WINDOW_BYTES; i = i + 1) begin
        ab_v6.prg_rom[i] = tb_prg[i];
        ab_v5.prg_rom[i] = tb_prg[i];
        chr_rom.prg_rom[i] = tb_prg[i];
        chr_ram_b.prg_rom[i] = tb_prg_b[i];
    end
    // MMC3 splits PRG into four 8 KiB windows: $8000 through r6 (=0), $A000
    // through r7 (=1), $C000 through the fixed second-last 8 KiB bank
    // (PRG_SIZE_BYTES>>13 - 2 = 14) and $E000 through the fixed last one
    // (PRG_SIZE_BYTES>>13 - 1 = 15).  So one 32 KiB image has to be scattered
    // to byte offsets 0, 8 KiB, 112 KiB and 120 KiB, and the 0x1C000/0x1E000
    // copies are the ones the $FFFC reset vector and the $FFFE irq vector are
    // actually read from.  Without them the mmc3 cpu would never start.
    for (i = 0; i < DUT_PRG_SIZE_BYTES; i = i + 1)
        chr_mmc3.prg_rom[i] = 8'h00;
    for (i = 0; i < 8192; i = i + 1) begin
        chr_mmc3.prg_rom[0 * 8192 + i] = m_prg[0 * 8192 + i];
        chr_mmc3.prg_rom[1 * 8192 + i] = m_prg[1 * 8192 + i];
        chr_mmc3.prg_rom[14 * 8192 + i] = m_prg[2 * 8192 + i];
        chr_mmc3.prg_rom[15 * 8192 + i] = m_prg[3 * 8192 + i];
    end
    for (i = 0; i < 2048; i = i + 1) begin
        ab_v6.u_ppu.nametable_ram[i] = 8'h00;
        ab_v5.u_ppu.nametable_ram[i] = 8'h00;
        chr_rom.u_ppu.nametable_ram[i] = 8'h00;
        chr_ram_b.u_ppu.nametable_ram[i] = 8'h00;
        chr_mmc3.u_ppu.nametable_ram[i] = 8'h00;
    end
    for (i = 0; i < 32; i = i + 1) begin
        ab_v6.u_ppu.palette_ram[i] = 8'h00;
        ab_v5.u_ppu.palette_ram[i] = 8'h00;
        chr_rom.u_ppu.palette_ram[i] = 8'h00;
        chr_ram_b.u_ppu.palette_ram[i] = 8'h00;
        chr_mmc3.u_ppu.palette_ram[i] = 8'h00;
    end
    for (i = 0; i < 256; i = i + 1) begin
        ab_v6.u_ppu.oam_ram[i] = 8'hFF;
        ab_v5.u_ppu.oam_ram[i] = 8'hFF;
        chr_mmc3.u_ppu.oam_ram[i] = 8'hFF;
    end

    buttons1 = BUTTONS1;
    buttons2 = BUTTONS2;
    #1;
    reset = 1'b1;

    repeat (4) @(posedge clk);
    #1;

    @(negedge clk);
    reset = 1'b0;
    #1;

    wait (frames_seen == FRAME_TARGET);
    #100;

    if (seen_main_loop !== 1'b1)
        $fatal(1, "the cpu never reached the self loop in the main program");
    if (ram_wr_nmi != (nmi_entry_count + 1))
        $fatal(1, "writes to the nmi counter cell got %0d expected %0d",
               ram_wr_nmi, nmi_entry_count + 1);
    if (ram_wr_p1n != 2)
        $fatal(1, "the port 1 ninth read cell was written %0d times expected 2",
               ram_wr_p1n);
    if (ram_wr_p2n != 2)
        $fatal(1, "the port 2 ninth read cell was written %0d times expected 2",
               ram_wr_p2n);
    if (ppu_wr_ctrl != 2 || ppu_wr_mask != 2 || ppu_wr_status != 0 ||
        ppu_wr_oamaddr != 1 || ppu_wr_other != 0)
        $fatal(1, "unexpected ppu write breakdown ctrl=%0d mask=%0d status=%0d oamaddr=%0d other=%0d",
               ppu_wr_ctrl, ppu_wr_mask, ppu_wr_status, ppu_wr_oamaddr,
               ppu_wr_other);
    if (apu_wr_frame != 1)
        $fatal(1, "the $4017 write count got %0d expected 1", apu_wr_frame);
    if (apu_wr_ctrl != 4)
        $fatal(1, "the $4016 write count got %0d expected 4", apu_wr_ctrl);
    if (apu_wr_dma != 1)
        $fatal(1, "the $4014 write count got %0d expected 1", apu_wr_dma);

    check_p0_1;
    check_p0_2;
    check_p0_3;
    check_p0_4;
    check_p0_5;
    check_p0_6;
    check_w1_chr_upload;
    check_w1_self_validating_pair;
    check_chr_ram_rom_pair;
    check_p1_1;
    check_p1_2;
    check_p1_3;
    check_p1_4;
    check_p1_6;
    check_p1_7;
    check_p1_8;
    check_p1_9;
    check_p1_10;
    check_bus_accounting;

    // ------------------------------------------------------------- phase 2
    // The phase 1 gate above is untouched.  Phase 2 only adds the third
    // instance, so wait for three FULL visible frames after the LAST vblank
    // bank switch and then run the deferred assertions.
    wait (m_post_switch_frames >= MMC3_FRAME_TARGET);
    #100;

    if (m_bank_writes != MMC3_BANK_STEPS)
        $fatal(1, "the mmc3 program issued %0d $8001 writes expected %0d",
               m_bank_writes, MMC3_BANK_STEPS);
    for (i = 0; i < 256; i = i + 1) begin
        if (chr_mmc3.u_ppu.oam_ram[i] !== m_table1[i])
            $fatal(1, "P0-7 mmc3 oam[%0d] is %02x expected %02x",
                   i, chr_mmc3.u_ppu.oam_ram[i], m_table1[i]);
    end
    if (chr_mmc3.u_ppu.oam_ram[0] !== MMC3_OAM_RB_EXPECT)
        $fatal(1, "P0-7 the mmc3 oam readback gave %02x expected %02x",
               chr_mmc3.u_ppu.oam_ram[0], MMC3_OAM_RB_EXPECT);
    if (m_mapper_id !== 3'd4)
        $fatal(1, "P0-7 the mmc3 instance reports mapper id %0d expected 4", m_mapper_id);
    if (chr_mmc3.u_ppu.control_reg !== MMC3_PPUCTRL)
        $fatal(1, "P0-7 the mmc3 ppuctrl is %02x expected %02x",
               chr_mmc3.u_ppu.control_reg, MMC3_PPUCTRL);
    if (m_cart_wr_total != (MMC3_BANK_STEPS + 4))
        $fatal(1, "P0-7 the mmc3 program issued %0d cart writes expected %0d",
               m_cart_wr_total, MMC3_BANK_STEPS + 4);

    check_p0_7;
    check_p0_8;
    check_w3_readback;
    check_w2_mmc3_chr_write;
    check_p1_5;

    $display("PASS tb_nes_system_v6");
    tb_live = 1'b0;
    $finish;
end

initial begin
    // The five DUT instances plus the three post-switch frames push the run well
    // past the 20 ms phase 1 needed.  Kept as a hard wall so a hung cpu, a
    // missed frame_done or a stuck wait() still fails instead of hanging.
    #120000000;
    if (tb_live)
        $fatal(1, "global timeout");
end

endmodule
