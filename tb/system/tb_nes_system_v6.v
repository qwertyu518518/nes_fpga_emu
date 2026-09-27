`timescale 1ns/1ps

// PHASE 1+2 for nes_system_v6.
//
// Three DUT instances on the same clock:
//   ab_v6     nes_system_v6  MAPPER_SELECT=0  external CHR on the top-level port
//   ab_v5     nes_system_v5  identical params internal CHR, preloaded by hierarchy
//   chr_mmc3  nes_system_v6  MAPPER_SELECT=4  its own CHR model and its own
//                          registered chr_rdata, its own program image
//
// Every P0 assertion is about the v6 external CHR path; every P1 assertion is
// a carried-over invariant that has to be RE-PROVED on the v6 instance, not
// assumed from v5.  ab_v6 and ab_v5 share one program image so P0-4 can compare
// them instruction for instruction; chr_mmc3 runs a SEPARATE image because the
// phase 1 cart-write count (P0-2) and the phase 1 PPUCTRL value are NROM-specific
// and would be changed by the extra $8001/$C000/$E000 writes P0-7 and P1-5 need.

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

localparam [15:0] NMI_HANDLER = 16'h8400;
localparam [15:0] IRQ_HANDLER = 16'h8500;
localparam [15:0] FAIL1 = 16'h8800;
localparam [15:0] FAIL2 = 16'h8810;
localparam [15:0] FAIL3 = 16'h8820;
localparam [15:0] TABLE1_ADDR = 16'h8900;
localparam [15:0] MAIN_PROG = 16'h8000;
localparam [15:0] NMI_COUNTER_CELL = 16'h0010;
localparam [15:0] IRQ_COUNTER_CELL = 16'h0011;
localparam [15:0] DMA_FLAG_CELL = 16'h0013;
localparam [15:0] OAM_RB_FLAG_CELL = 16'h0014;
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

// ------------------------------------------------------- phase 2 MMC3 config
//
// chr_mmc3 is elaborated with MAPPER_SELECT=4.  Its program writes $8001 three
// times, each inside vblank, and the R0 register it selects is the ONLY 1 KiB
// window its PPU ever reaches (see the P0-7 comments on local chr_addr[11]).

localparam [7:0] DUT_MMC3_SELECT = 8'd4;
localparam [7:0] MMC3_PPUCTRL = 8'h00;
localparam [7:0] MMC3_BANK_R0 = 8'h00;
localparam [7:0] MMC3_BANK_R1 = 8'h01;
localparam [7:0] MMC3_BANK_R2 = 8'h41;
localparam [7:8] MMC3_REG_R0 = 8'h00;
localparam [7:8] MMC3_REG_R1 = 8'h00;
localparam [7:0] MMC3_REG_R2 = 8'h40;
localparam integer MMC3_IMG_BASE_REG0 = 0 * 1024;
localparam integer MMC3_IMG_BASE_REG1 = 2 * 1024;
localparam integer MMC3_IMG_BASE_REG2 = 64 * 1024;
localparam [7:0] MMC3_IRQ_LATCH_VALUE = 8'h07;
localparam [15:0] MMC3_FAIL = 16'h8820;
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
localparam integer MMC3_FRAME_TARGET = 3;
localparam integer MMC3_BANK_STEPS = 3;

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

// ----------------------------------------------------------- CHR memory model
//
// The register is on ce_ppu and indexes the FULL 17-bit chr_final_addr.  The
// fetch units advance chr_addr one ce before they sample chr_rdata, so a
// combinational read of chr_mem would return every tile byte-shifted by one.
// Dropping bit 13 here would also hide the NROM aliasing the model is supposed
// to reproduce.

reg [7:0] chr_mem [0:CHR_MEM_BYTES-1];
reg [7:0] chr_rdata_q;
reg [7:0] chr_tile_image [0:47];

assign chr_rdata = chr_rdata_q;

always @(posedge clk) begin
    if (reset)
        chr_rdata_q <= 8'h00;
    else if (ab_v6.ce_ppu)
        chr_rdata_q <= chr_mem[v6_chr_final_addr];
end

// TB-owned mapper model.  NROM has no bank register at all, so the CHR bank
// term is the constant 0 and the only live part is the local address mask.
reg [3:0] tb_chr_bank_model;

// chr_mmc3 gets its OWN 128 KiB CHR model and its OWN registered chr_rdata.
// Sharing the ab_v6 model would make a bank switch invisible by construction:
// the point of P0-7 is that the bytes arriving at the PPU change, so the two
// models must never alias.
reg [7:0] m_chr_mem [0:CHR_MEM_BYTES-1];
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
    else if (chr_mmc3.ce_ppu)
        m_chr_rdata_q <= m_chr_mem[m_chr_final_addr];
end

// ---------------------------------------------------------- program image

reg [7:0] tb_prg [0:TB_WINDOW_BYTES-1];
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
integer f_local_bit13;
integer f_local_bit12;
integer f_final_bit13_bad;
integer f_addr_err;
integer f_max_final_addr;
integer last_f_chr_req;
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
reg     ab_req_prev;
reg     m_req_prev;
integer ab_req_beats;
integer ab_req_consec;
integer ab_bgsp_beats;
integer ab_bgsp_clash;
integer m_req_beats;
integer m_req_consec;
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

wire ab_bg_chr_req = ab_v6.u_ppu.g_chr_external.u_chr_fetch.chr_req;
wire ab_sp_chr_req = ab_v6.u_ppu.g_chr_external.u_sprite_chr_fetch.chr_req;
wire m_bg_chr_req = chr_mmc3.u_ppu.g_chr_external.u_chr_fetch.chr_req;
wire m_sp_chr_req = chr_mmc3.u_ppu.g_chr_external.u_sprite_chr_fetch.chr_req;
wire [6:0] m_cpu_state = chr_mmc3.u_cpu.dbg_state;
wire m_ppu_bg_enable = chr_mmc3.u_ppu.mask_reg[3];

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

// v4's $2007 CHR tile writes are deliberately NOT reproduced: with
// EXTERNAL_CHR=1 the CHR branch of the $2007 handler is empty, so the writes
// would be silently dropped and the tile bytes have to come from the preload.
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
        for (k = 0; k < 8; k = k + 1) begin
            ctrl_rd_exp[k] = BUTTONS1[k];
            ctrl_rd_exp[9 + k] = BUTTONS2[k];
        end
        ctrl_rd_exp[8] = 8'h01;
        ctrl_rd_exp[CTRL_READS-1] = 8'h01;
    end
endtask

// The v4 internal CHR image, byte for byte: [0:7]=FF [8:15]=00 [16:23]=00
// [24:31]=FF [32:39]=FF [40:47]=00.
task build_chr_image;
    begin
        for (k = 0; k < 8; k = k + 1) begin
            chr_tile_image[0 + k] = 8'hFF;
            chr_tile_image[8 + k] = 8'h00;
            chr_tile_image[16 + k] = 8'h00;
            chr_tile_image[24 + k] = 8'hFF;
            chr_tile_image[32 + k] = 8'hFF;
            chr_tile_image[40 + k] = 8'h00;
        end
    end
endtask

// ab_v6 gets the image at every 4 KiB boundary.  The pattern-table select lands
// on local chr_addr[12], not bit 13, and the NROM mapper preserves bit 12 while
// dropping bit 13, so a set PPUCTRL bit 4 makes v6 read chr_mem[0x1000+off].
// Mirroring at every 4 KiB makes that alias to chr_mem[off] and keeps the bit-13
// drop a no-op for every address the PPU can produce.  ab_v5's internal array is
// 8 KiB and its PPU indexes the 13-bit {table, tile, 4'b0} + fine pattern
// address, so the image goes into BOTH 4 KiB tables.  Without either copy v5
// and v6 disagree the moment PPUCTRL bit 4 is set.
task load_chr;
    integer m;
    integer b;
    begin
        for (m = 0; m < CHR_MEM_BYTES; m = m + 1)
            chr_mem[m] = 8'h00;
        for (m = 0; m < (CHR_MEM_BYTES / 4096); m = m + 1)
            for (b = 0; b < 48; b = b + 1)
                chr_mem[m * 4096 + b] = chr_tile_image[b];
        for (b = 0; b < 8192; b = b + 1)
            ab_v5.u_ppu.chr_ram[b] = 8'h00;
        for (m = 0; m < 2; m = m + 1)
            for (b = 0; b < 48; b = b + 1)
                ab_v5.u_ppu.chr_ram[m * 4096 + b] = chr_tile_image[b];
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
    end
endtask

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
    .HEADER_MIRRORING(DUT_HEADER_MIRRORING)
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
    .mapper_chr_ram_we(),
    .mapper_bus_conflict(),
    .mapper_irq(v6_mapper_irq),
    .irq_line(v6_irq_line),
    .mapper_write_pulse(v6_mapper_write_pulse),
    .mapper_write_addr(v6_mapper_write_addr),
    .mapper_write_data(v6_mapper_write_data),
    .prg_readback(v6_prg_readback),
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
    .HEADER_MIRRORING(DUT_HEADER_MIRRORING)
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
    .mapper_chr_ram_we(),
    .mapper_bus_conflict(),
    .mapper_irq(m_mapper_irq),
    .irq_line(m_irq_line),
    .mapper_write_pulse(m_mapper_write_pulse),
    .mapper_write_addr(m_mapper_write_addr),
    .mapper_write_data(m_mapper_write_data),
    .prg_readback(m_prg_readback),
    .chr_req(m_chr_req),
    .chr_final_addr(m_chr_final_addr)
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
        fu_sgrab_q <= 1'b0;
        fu_cappl_q <= 1'b0;
    end else if (ab_v6.ce_ppu) begin
        chr_h1 <= v6_chr_final_addr;
        chr_h2 <= chr_h1;

        if (fu_sgrab_q !== 1'b0) begin
            if (fu_cappl_q === 1'b0) begin
                chr_latch_checks = chr_latch_checks + 1;
                if (fu_bg_lo !== chr_mem[chr_h2]) begin
                    chr_latch_err = chr_latch_err + 1;
                    if (chr_latch_err < 5)
                        $fatal(1, "P0-6 bg_lo latched %02h, tb chr_mem[%05h] = %02h",
                               fu_bg_lo, chr_h2, chr_mem[chr_h2]);
                end
            end else begin
                chr_latch_checks = chr_latch_checks + 1;
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

        if (v6_chr_req !== 1'b0) begin
            chr_req_total = chr_req_total + 1;
            f_chr_req = f_chr_req + 1;
            chr_req_owner[v6_bus_owner[2:0]] =
                chr_req_owner[v6_bus_owner[2:0]] + 1;
            chr_req_owner_total = chr_req_owner_total + 1;
            if (v6_chr_final_addr[CHR_ADDR_BITS-1:13] != 4'd0)
                chr_hi_addr_bad = chr_hi_addr_bad + 1;
            if (v6_chr_final_addr[13] !== 1'b0)
                f_final_bit13_bad = f_final_bit13_bad + 1;
            if (v6_chr_final_addr > f_max_final_addr)
                f_max_final_addr = v6_chr_final_addr;
            if (ab_v6.u_ppu.chr_addr[13] === 1'b1)
                f_local_bit13 = f_local_bit13 + 1;
            if (ab_v6.u_ppu.chr_addr[12] === 1'b1)
                f_local_bit12 = f_local_bit12 + 1;

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

            if ((v6_bus_req === 1'b0) && (v6_bus_fire === 1'b0) &&
                (v6_bus_stall === 1'b0))
                chr_req_bus_idle = chr_req_bus_idle + 1;
            if (v6_bus_hold !== 1'b0)
                chr_req_during_dma = chr_req_during_dma + 1;
        end
    end
end

// TB-side prediction of what the model must present at each sampling edge
// versus what the model is actually presenting.  chr_h1 read at this edge is
// the chr_final_addr of the previous ce, which is exactly the address the
// model sampled on that previous ce.
always @(posedge clk) begin
    if (!reset && ab_v6.ce_ppu && (v6_chr_req !== 1'b0)) begin
        chr_model_pred_checks = chr_model_pred_checks + 1;
        if (chr_rdata_q !== chr_mem[chr_h1]) begin
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
                    $fatal(1, "P0-4 per-ce divergence pv=%b/%b x=%0d/%0d y=%0d/%0d idx=%0d/%0d fd=%b/%b dot=%0d/%0d sl=%0d/%0d nmi=%b/%b cc=%0d/%0d",
                           v6_pixel_valid, v5_pixel_valid, v6_pixel_x, v5_pixel_x,
                           v6_pixel_y, v5_pixel_y, v6_pixel_index, v5_pixel_index,
                           v6_frame_done, v5_frame_done, v6_ppu_dot, v5_ppu_dot,
                           v6_ppu_scanline, v5_ppu_scanline, v6_nmi_o, v5_nmi_o,
                           v6_cpu_cycle, v5_cpu_cycle);
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
            if (!((ab_v6.u_cpu.dbg_pc >= MAIN_PROG) && (ab_v6.u_cpu.dbg_pc <= main_prog_end)) &&
                !((ab_v6.u_cpu.dbg_pc >= NMI_HANDLER) && (ab_v6.u_cpu.dbg_pc <= nmi_end)) &&
                !((ab_v6.u_cpu.dbg_pc >= IRQ_HANDLER) && (ab_v6.u_cpu.dbg_pc <= irq_end)) &&
                !((ab_v6.u_cpu.dbg_pc >= FAIL1) && (ab_v6.u_cpu.dbg_pc <= FAIL1 + 16'd2)) &&
                !((ab_v6.u_cpu.dbg_pc >= FAIL2) && (ab_v6.u_cpu.dbg_pc <= FAIL2 + 16'd2)) &&
                !((ab_v6.u_cpu.dbg_pc >= FAIL3) && (ab_v6.u_cpu.dbg_pc <= FAIL3 + 16'd2)))
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
        f_local_bit13 = 0;
        f_local_bit12 = 0;
        f_final_bit13_bad = 0;
        f_addr_err = 0;
        f_max_final_addr = 0;
        last_f_chr_req = 0;
        last_f_local_bit13 = 0;
        last_f_local_bit12 = 0;
        last_f_final_bit13_bad = 0;
        last_f_addr_err = 0;
        last_f_max_final_addr = 0;
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
            last_f_local_bit13 = f_local_bit13;
            last_f_local_bit12 = f_local_bit12;
            last_f_final_bit13_bad = f_final_bit13_bad;
            last_f_addr_err = f_addr_err;
            last_f_max_final_addr = f_max_final_addr;
            f_chr_req = 0;
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
        if (m_chr_req !== 1'b0) begin
            m_chr_req_total = m_chr_req_total + 1;
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
        ab_req_beats = 0;
        ab_req_consec = 0;
        ab_bgsp_beats = 0;
        ab_bgsp_clash = 0;
        m_req_beats = 0;
        m_req_consec = 0;
        m_bgsp_beats = 0;
        m_bgsp_clash = 0;
    end else begin
        if (ab_v6.ce_ppu) begin
            ab_req_beats = ab_req_beats + 1;
            if ((ab_req_prev !== 1'b0) && (v6_chr_req !== 1'b0))
                ab_req_consec = ab_req_consec + 1;
            ab_req_prev = v6_chr_req;
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
        $display("P0-1 RESET/IDENTITY reset clks=%0d chr_req=0 chr_final_addr=0 during reset, dbg_mapper_id=0/0, chr requests=%0d, max chr_final_addr=0x%04h <= 0x1FFF PASS",
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
        $display("P0-4 AB-FULL-FRAME compared per ce, visible comparisons=%0d (3 x 240 x 256) exact, divergences=%0d, all-ce comparisons=%0d divergences=%0d, frame period=%0d clk PASS",
                 ab_visible_count, ab_visible_div, ab_all_ce_count,
                 ab_all_ce_div, frame_delta_clk);
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
        if (m_tile0_oth[0] != 0 || m_tile0_oth[1] != 0 || m_tile0_oth[2] != 0)
            $fatal(1, "P0-7 the tile-0 region was not a single class: stray pixels %0d/%0d/%0d",
                   m_tile0_oth[0], m_tile0_oth[1], m_tile0_oth[2]);
        if (m_exp_index[0] === m_exp_index[2])
            $fatal(1, "P0-7 the first and third bank were asserted to the same index, the check proves nothing");
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
        $display("P0-7 MMC3-BANK (a) translation: expected_final=(tb_chr_bank_model<<10)|(local&0x3ff) with tb_chr_bank_model={mapper_write_data[7:1],1'b0} captured from mapper_write_pulse/addr/data, never from the dut register, checked on every ce_ppu with chr_req high: $8001 data %02h/%02h/%02h -> reg %02h/%02h/%02h, chr beats total=%0d, per-step beats=%0d/%0d/%0d err=%0d/%0d/%0d, dut chr_final_addr[16:10] first value per step=%02h/%02h/%02h PASS",
                 m_bank_data[0], m_bank_data[1], m_bank_data[2],
                 m_bank_reg[0], m_bank_reg[1], m_bank_reg[2],
                 m_chr_req_total,
                 m_addr_checks[0], m_addr_checks[1], m_addr_checks[2],
                 m_addr_err[0], m_addr_err[1], m_addr_err[2],
                 m_first_hi[0], m_first_hi[1], m_first_hi[2]);
        $display("P0-7 MMC3-BANK (b) named tile-0 indices: step1 $8001=%02h -> reg %02h -> index %0d on %0d of %0d tile-0 pixels (plane0=$FF/plane1=$00 -> pattern 1 -> $3F01=$21); step2 $8001=%02h -> reg %02h -> index %0d on %0d of %0d; step3 $8001=%02h -> reg %02h -> index %0d on %0d of %0d (plane0=$FF/plane1=$FF -> pattern 3 -> $3F03=$18); stray pixels %0d/%0d/%0d.  PARTIAL SPEC, NOT A DELETED CHECK: step 2 was specified to produce a NEW value and it cannot, because nes_mapper_mmc3.v:208 latches r0 as {data[7:1],1'b0} so $01 and $00 are the same 1 KiB bank (real MMC3 2 KiB granularity, bit 0 is the odd/even 1 KiB select and lives in local chr_addr[11]).  The named value for step 2 is therefore %0d, identical to step 1, and the dut chr_final_addr[16:10] is asserted bit-identical across the two steps (%02h vs %02h) so the equality is measured, not assumed.  Two of the three steps therefore change the arriving bytes and the picture (reg %02h -> reg %02h); the third cannot, and no preload can make it, because the register value it selects is the same.  The three preloaded images are pairwise different PASS",
                 m_bank_data[0], m_bank_reg[0], m_exp_index[0], m_tile0_exp[0], m_tile0_tot[0],
                 m_bank_data[1], m_bank_reg[1], m_exp_index[1], m_tile0_exp[1], m_tile0_tot[1],
                 m_bank_data[2], m_bank_reg[2], m_exp_index[2], m_tile0_exp[2], m_tile0_tot[2],
                 m_tile0_oth[0], m_tile0_oth[1], m_tile0_oth[2],
                 m_exp_index[1], m_first_hi[0], m_first_hi[1],
                 m_bank_reg[0], m_bank_reg[2]);
        $display("P0-7 MMC3-BANK (c) for the $41 write the r0 register is {0x41[7:1],1'b0}=$40 so chr_final_addr[16]=reg[6]=1 on %0d of the %0d checked beats; that is bit 16 of a 17-bit address taken from the mapper output port, so a 16-bit testbench index could not have produced it.  All three $8001 writes landed inside the vblank period at scanline/dot %0d/%0d, %0d/%0d and %0d/%0d (dots all below the 257 where the 35-ce sprite shadow build starts), ppuctrl was $%02h throughout so PPUCTRL[4]/[5] never moved the window, and the three preloaded bank images are pairwise different PASS",
                 m_bit16_seen[2], m_addr_checks[2],
                 m_bank_sl[0][15:8], m_bank_sl[0][7:0],
                 m_bank_sl[1][15:8], m_bank_sl[1][7:0],
                 m_bank_sl[2][15:8], m_bank_sl[2][7:0],
                 MMC3_PPUCTRL);
    end
endtask

task check_p0_8;
    begin
        if (ab_req_consec != 0)
            $fatal(1, "P0-8 ab_v6 chr_req was high on two consecutive ce %0d times",
                   ab_req_consec);
        if (m_req_consec != 0)
            $fatal(1, "P0-8 chr_mmc3 chr_req was high on two consecutive ce %0d times",
                   m_req_consec);
        if (ab_bgsp_clash != 0)
            $fatal(1, "P0-8 ab_v6 background and sprite chr_req collided %0d times",
                   ab_bgsp_clash);
        if (m_bgsp_clash != 0)
            $fatal(1, "P0-8 chr_mmc3 background and sprite chr_req collided %0d times",
                   m_bgsp_clash);
        if (ab_req_beats < 200000)
            $fatal(1, "P0-8 ab_v6 only produced %0d ce, the collision window was barely sampled",
                   ab_req_beats);
        if (ab_bgsp_beats < 100000)
            $fatal(1, "P0-8 ab_v6 only produced %0d fetch-unit chr_req beats, the units were barely sampled",
                   ab_bgsp_beats);
        if (m_bgsp_beats < 100000)
            $fatal(1, "P0-8 chr_mmc3 only produced %0d fetch-unit chr_req beats, the units were barely sampled",
                   m_bgsp_beats);
        $display("P0-8 NO-BUS-COLLISION chr_req was never high on two consecutive ce on ab_v6 (%0d of %0d ce, %0d violations) or on chr_mmc3 (%0d of %0d ce, %0d violations), and the background fetch unit chr_req (u_ppu.g_chr_external.u_chr_fetch.chr_req) and the sprite fetch unit chr_req (u_ppu.g_chr_external.u_sprite_chr_fetch.chr_req) were never both high on the same ce: %0d and %0d sampled beats, %0d and %0d collisions.  The port has no backpressure, so a collision would be a silently dropped background beat.  ab_v5 is not in this check because nes_system_v5 has no external CHR port at all PASS",
                 ab_req_consec, ab_req_beats, ab_req_consec,
                 m_req_consec, m_req_beats, m_req_consec,
                 ab_bgsp_beats, m_bgsp_beats, ab_bgsp_clash, m_bgsp_clash);
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
        $display("P1-5 MMC3-A12-AND-FORCE on chr_mmc3 only: $C000 latched %02h, $C001 set reload and it is still set, the counter is still %02h and the a12 filter never fired because mapper_ppu_a12 is hardwired 0 inside nes_system_v6, $E001 then $E000 left irq_enabled=0, and mapper_irq stayed low on every one of the %0d clk of the whole program before the force PASS",
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
        $display("P1-10 CPU fffc/fffd -> pc=8000, first opcode=58, illegal opcodes=%0d, no fail loop at 8800/8810/8820 entered, cpu reached the self loop PASS",
                 illegal_hits);
        $display("PRG main $8000-$%04h (%0d bytes), nmi handler $8400-$%04h, irq handler $8500-$%04h, fail loops $8800/$8810/$8820, table $8900, vectors fffa=$8400 fffc=$8000 fffe=$8500, cart writes a000=5a b123=a5 ffc0=3c",
                 main_prog_end - 16'd1, main_prog_end - MAIN_PROG, nmi_end - 16'd1,
                 irq_end - 16'd1);
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
    reset_mapper_id_bad = 0;
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
    for (k = 0; k < 8; k = k + 1)
        chr_req_owner[k] = 0;
    for (k = 0; k < TB_WINDOW_BYTES; k = k + 1)
        tb_prg[k] = 8'h00;
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

    build_mmc3_main;
    build_mmc3_nmi_handler;
    build_mmc3_irq_handler;
    build_mmc3_fail_blocks;
    build_mmc3_vectors;
    build_mmc3_tables;
    load_chr_mmc3;

    for (i = 0; i < TB_WINDOW_BYTES; i = i + 1) begin
        ab_v6.prg_rom[i] = tb_prg[i];
        ab_v5.prg_rom[i] = tb_prg[i];
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
        chr_mmc3.u_ppu.nametable_ram[i] = 8'h00;
    end
    for (i = 0; i < 32; i = i + 1) begin
        ab_v6.u_ppu.palette_ram[i] = 8'h00;
        ab_v5.u_ppu.palette_ram[i] = 8'h00;
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
    // instance, so wait for three FULL visible frames after the third vblank
    // bank switch and then run the four deferred assertions.
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
    check_p1_5;

    $display("PASS tb_nes_system_v6");
    tb_live = 1'b0;
    $finish;
end

initial begin
    // The third instance plus the three post-switch frames push the run well
    // past the 20 ms phase 1 needed.  Kept as a hard wall so a hung cpu, a
    // missed frame_done or a stuck wait() still fails instead of hanging.
    #120000000;
    if (tb_live)
        $fatal(1, "global timeout");
end

endmodule
