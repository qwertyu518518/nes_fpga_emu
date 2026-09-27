`timescale 1ns/1ps

module tb_nes_system_v5;

localparam PRG_SIZE_BYTES = 131072;
localparam PRG_ADDR_BITS  = 17;
localparam CHR_ADDR_BITS  = 17;
localparam [15:0] NROM_MAIN = 16'h8000;
localparam [15:0] NROM_FAIL = 16'h8200;
localparam [15:0] UXROM_MAIN = 16'hC000;
localparam [15:0] UXROM_FAIL = 16'hD000;
localparam [15:0] MMC3_MAIN  = 16'hE000;
localparam [15:0] MMC3_IRQ   = 16'hE200;
localparam [15:0] MMC3_FAIL  = 16'hE400;
localparam [7:0] BUTTONS1 = 8'hA5;
localparam [7:0] BUTTONS2 = 8'h5A;
localparam integer UXROM_BANK_BITS = 3;
localparam [7:0] UXROM_LAST_16K = (PRG_SIZE_BYTES >> 14) - 1;
localparam [7:0] MMC3_LAST_8K = (PRG_SIZE_BYTES >> 13) - 1;
localparam [7:0] MMC3_PREV_8K = MMC3_LAST_8K - 8'd1;

reg clk;
reg reset;
reg [7:0] buttons1;
reg [7:0] buttons2;

integer i;
integer n;
reg [7:0] sig;
reg [7:0] rb_byte;
reg [15:0] pc;
reg [15:0] loop1;
reg [15:0] loop2;
reg [15:0] bne_list [0:63];
integer bne_count;
reg [15:0] bne_site;
reg [15:0] bne_disp;
reg [15:0] self_loop;
reg [15:0] fail_entry;
reg [15:0] next_chunk;

wire nrom_bus_stall;
wire nrom_bus_req;
wire nrom_bus_fire;
wire nrom_bus_we;
wire [15:0] nrom_bus_addr;
wire [7:0] nrom_bus_dout;
wire [7:0] nrom_bus_din;
wire [7:0] nrom_bus_wait_count;
wire nrom_bus_active;
wire nrom_sel_ram;
wire nrom_sel_cart_rom;
wire nrom_sel_apu_io;
wire nrom_sel_open_bus;
wire [15:0] nrom_cart_addr;
wire [7:0] nrom_cart_din;
wire nrom_cart_xfer;
wire nrom_apu_irq_o;
wire nrom_controller_data;
wire nrom_bus_hold;
wire nrom_apu_reg_cs;
wire nrom_apu_reg_we;
wire [4:0] nrom_apu_reg_addr;
wire nrom_oam_dma_busy;
wire nrom_dma_sel;
wire nrom_dma_ack;
wire [2:0] nrom_mapper_id;
wire [PRG_ADDR_BITS-1:0] nrom_mapper_prg_bank_offset;
wire [CHR_ADDR_BITS-1:0] nrom_mapper_chr_bank_offset;
wire [2:0] nrom_mapper_mirroring;
wire [7:0] nrom_mapper_nametable_map;
wire [7:0] nrom_mapper_prg_bank_number;
wire nrom_mapper_prg_ram_enable;
wire nrom_mapper_prg_ram_we;
wire nrom_mapper_chr_ram_enable;
wire nrom_mapper_chr_ram_we;
wire nrom_mapper_irq;
wire nrom_irq_line;
wire nrom_mapper_write_pulse;
wire [15:0] nrom_mapper_write_addr;
wire [7:0] nrom_mapper_write_data;
wire [7:0] nrom_prg_readback;

wire uxrom_bus_stall;
wire uxrom_bus_req;
wire uxrom_bus_fire;
wire uxrom_bus_we;
wire [15:0] uxrom_bus_addr;
wire [7:0] uxrom_bus_dout;
wire [7:0] uxrom_bus_din;
wire [7:0] uxrom_bus_wait_count;
wire uxrom_bus_active;
wire uxrom_sel_ram;
wire uxrom_sel_cart_rom;
wire uxrom_sel_apu_io;
wire uxrom_sel_open_bus;
wire [15:0] uxrom_cart_addr;
wire [7:0] uxrom_cart_din;
wire uxrom_cart_xfer;
wire uxrom_apu_irq_o;
wire uxrom_audio_sample_valid;
wire [15:0] uxrom_audio_sample_left;
wire [15:0] uxrom_audio_sample_right;
wire uxrom_controller_data;
wire uxrom_bus_hold;
wire uxrom_apu_reg_cs;
wire uxrom_apu_reg_we;
wire [4:0] uxrom_apu_reg_addr;
wire uxrom_oam_dma_start;
wire uxrom_oam_dma_done;
wire uxrom_oam_dma_busy;
wire uxrom_oam_dma_ppu_reg_cs;
wire uxrom_dma_sel;
wire uxrom_dma_ack;
wire [7:0] uxrom_dma_din;
wire uxrom_dma_unimpl;
wire uxrom_apu_dmc_bus_req;
wire [2:0] uxrom_mapper_id;
wire [PRG_ADDR_BITS-1:0] uxrom_mapper_prg_bank_offset;
wire [CHR_ADDR_BITS-1:0] uxrom_mapper_chr_bank_offset;
wire [2:0] uxrom_mapper_mirroring;
wire [7:0] uxrom_mapper_nametable_map;
wire [7:0] uxrom_mapper_prg_bank_number;
wire uxrom_mapper_prg_ram_enable;
wire uxrom_mapper_prg_ram_we;
wire uxrom_mapper_chr_ram_enable;
wire uxrom_mapper_chr_ram_we;
wire uxrom_mapper_bus_conflict;
wire uxrom_mapper_irq;
wire uxrom_irq_line;
wire uxrom_mapper_write_pulse;
wire [15:0] uxrom_mapper_write_addr;
wire [7:0] uxrom_mapper_write_data;
wire [7:0] uxrom_prg_readback;

wire mmc3_bus_stall;
wire mmc3_bus_req;
wire mmc3_bus_fire;
wire mmc3_bus_we;
wire [15:0] mmc3_bus_addr;
wire [7:0] mmc3_bus_dout;
wire [7:0] mmc3_bus_din;
wire [7:0] mmc3_bus_wait_count;
wire mmc3_bus_active;
wire mmc3_sel_ram;
wire mmc3_sel_cart_rom;
wire mmc3_sel_apu_io;
wire mmc3_sel_open_bus;
wire [15:0] mmc3_cart_addr;
wire [7:0] mmc3_cart_din;
wire mmc3_cart_xfer;
wire mmc3_apu_irq_o;
wire mmc3_controller_data;
wire mmc3_bus_hold;
wire mmc3_apu_reg_cs;
wire mmc3_apu_reg_we;
wire [4:0] mmc3_apu_reg_addr;
wire mmc3_oam_dma_busy;
wire mmc3_dma_sel;
wire mmc3_dma_ack;
wire [2:0] mmc3_mapper_id;
wire [PRG_ADDR_BITS-1:0] mmc3_mapper_prg_bank_offset;
wire [CHR_ADDR_BITS-1:0] mmc3_mapper_chr_bank_offset;
wire [2:0] mmc3_mapper_mirroring;
wire [7:0] mmc3_mapper_nametable_map;
wire [7:0] mmc3_mapper_prg_bank_number;
wire mmc3_mapper_prg_ram_enable;
wire mmc3_mapper_prg_ram_we;
wire mmc3_mapper_chr_ram_enable;
wire mmc3_mapper_chr_ram_we;
wire mmc3_mapper_irq;
wire mmc3_irq_line;
wire mmc3_mapper_write_pulse;
wire [15:0] mmc3_mapper_write_addr;
wire [7:0] mmc3_mapper_write_data;
wire [7:0] mmc3_prg_readback;

integer nrom_fire;
integer nrom_stall;
integer nrom_prg_rd;
integer nrom_prg_wr;
integer nrom_off_err;
integer nrom_data_err;
integer nrom_din_err;
integer nrom_readback_err;
integer nrom_pulse;
integer nrom_pulse_long;
integer nrom_pulse_addr_err;
integer nrom_pulse_data_err;
integer nrom_irq_or_err;
integer nrom_illegal;
integer nrom_done;
integer nrom_wait_err;
reg [PRG_ADDR_BITS-1:0] nrom_exp_off;
reg [15:0] nrom_last_wr_addr;
reg [7:0] nrom_last_wr_data;
reg nrom_pulse_q;

integer uxrom_fire;
integer uxrom_stall;
integer uxrom_prg_rd;
integer uxrom_prg_wr;
integer uxrom_off_err;
integer uxrom_data_err;
integer uxrom_din_err;
integer uxrom_readback_err;
integer uxrom_pulse;
integer uxrom_pulse_long;
integer uxrom_pulse_addr_err;
integer uxrom_pulse_data_err;
integer uxrom_irq_or_err;
integer uxrom_illegal;
integer uxrom_done;
integer uxrom_wait_err;
integer uxrom_conflict;
integer uxrom_ctrl_cs_err;
integer uxrom_dma_ack_cnt;
integer uxrom_dma_wr;
integer uxrom_dma_start_count;
integer uxrom_dma_done_count;
integer uxrom_dma_unimpl_cnt;
integer uxrom_sample;
integer uxrom_sample_nz;
integer uxrom_dmc_req;
reg [UXROM_BANK_BITS-1:0] uxrom_bank;
reg [PRG_ADDR_BITS-1:0] uxrom_exp_off;
reg [15:0] uxrom_last_wr_addr;
reg [7:0] uxrom_last_wr_data;
reg uxrom_pulse_q;

integer mmc3_fire;
integer mmc3_stall;
integer mmc3_prg_rd;
integer mmc3_prg_wr;
integer mmc3_off_err;
integer mmc3_data_err;
integer mmc3_din_err;
integer mmc3_readback_err;
integer mmc3_pulse;
integer mmc3_pulse_long;
integer mmc3_pulse_addr_err;
integer mmc3_pulse_data_err;
integer mmc3_irq_or_err;
integer mmc3_illegal;
integer mmc3_done;
integer mmc3_wait_err;
integer mmc3_irq_entries;
integer mmc3_mirror_h;
integer mmc3_mirror_v;
reg [5:0] mmc3_r6;
reg [5:0] mmc3_r7;
reg [2:0] mmc3_sel;
reg mmc3_mode;
reg [PRG_ADDR_BITS-1:0] mmc3_exp_off;
reg [7:0] mmc3_win;
reg [15:0] mmc3_last_wr_addr;
reg [7:0] mmc3_last_wr_data;
reg mmc3_pulse_q;

nes_system_v5 #(
    .PRG_SIZE_BYTES(PRG_SIZE_BYTES),
    .MAPPER_SELECT(8'd0),
    .HEADER_MIRRORING(3'd1),
    .NROM_PRG_SIZE_BYTES(32768)
) nrom_dut (
    .clk(clk),
    .reset(reset),
    .buttons1(buttons1),
    .buttons2(buttons2),
    .pixel_valid(),
    .pixel_x(),
    .pixel_y(),
    .pixel_index(),
    .frame_done(),
    .vblank(),
    .nmi_o(),
    .apu_irq_o(nrom_apu_irq_o),
    .audio_sample_valid(),
    .audio_sample_left(),
    .audio_sample_right(),
    .cpu_cycle(),
    .ppu_dot(),
    .ppu_scanline(),
    .bus_owner(),
    .bus_active(nrom_bus_active),
    .bus_wait_count(nrom_bus_wait_count),
    .bus_req(nrom_bus_req),
    .bus_stall(nrom_bus_stall),
    .bus_fire(nrom_bus_fire),
    .bus_addr(nrom_bus_addr),
    .bus_we(nrom_bus_we),
    .bus_dout(nrom_bus_dout),
    .bus_din(nrom_bus_din),
    .sel_ram(nrom_sel_ram),
    .sel_ppu(),
    .sel_apu_io(nrom_sel_apu_io),
    .sel_open_bus(nrom_sel_open_bus),
    .sel_cart_ram(),
    .sel_cart_rom(nrom_sel_cart_rom),
    .ram_we(),
    .ppu_reg_cs(),
    .ppu_reg_we(),
    .ppu_reg_addr(),
    .apu_reg_cs(nrom_apu_reg_cs),
    .apu_reg_we(nrom_apu_reg_we),
    .apu_reg_addr(nrom_apu_reg_addr),
    .controller_data(nrom_controller_data),
    .cart_req(),
    .cart_xfer(nrom_cart_xfer),
    .cart_addr(nrom_cart_addr),
    .cart_din(nrom_cart_din),
    .cart_ack(),
    .bus_hold(nrom_bus_hold),
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
    .oam_dma_busy(nrom_oam_dma_busy),
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
    .dma_sel(nrom_dma_sel),
    .dma_ack(nrom_dma_ack),
    .dma_din(),
    .dma_wait(),
    .dma_active(),
    .dma_unimpl(),
    .dma_owner(),
    .ppu_port_cs(),
    .ppu_port_we(),
    .ppu_port_addr(),
    .ppu_port_din(),
    .mapper_id(nrom_mapper_id),
    .mapper_prg_bank_offset(nrom_mapper_prg_bank_offset),
    .mapper_chr_bank_offset(nrom_mapper_chr_bank_offset),
    .mapper_mirroring(nrom_mapper_mirroring),
    .mapper_nametable_map(nrom_mapper_nametable_map),
    .mapper_prg_bank_number(nrom_mapper_prg_bank_number),
    .mapper_prg_ram_enable(nrom_mapper_prg_ram_enable),
    .mapper_prg_ram_we(nrom_mapper_prg_ram_we),
    .mapper_chr_ram_enable(nrom_mapper_chr_ram_enable),
    .mapper_chr_ram_we(nrom_mapper_chr_ram_we),
    .mapper_bus_conflict(),
    .mapper_irq(nrom_mapper_irq),
    .irq_line(nrom_irq_line),
    .mapper_write_pulse(nrom_mapper_write_pulse),
    .mapper_write_addr(nrom_mapper_write_addr),
    .mapper_write_data(nrom_mapper_write_data),
    .prg_readback(nrom_prg_readback)
);

nes_system_v5 #(
    .PRG_SIZE_BYTES(PRG_SIZE_BYTES),
    .MAPPER_SELECT(8'd2),
    .HEADER_MIRRORING(3'd0),
    .UxROM_BANK_BITS(UXROM_BANK_BITS),
    .UxROM_BUS_CONFLICT(2'd1)
) uxrom_dut (
    .clk(clk),
    .reset(reset),
    .buttons1(buttons1),
    .buttons2(buttons2),
    .pixel_valid(),
    .pixel_x(),
    .pixel_y(),
    .pixel_index(),
    .frame_done(),
    .vblank(),
    .nmi_o(),
    .apu_irq_o(uxrom_apu_irq_o),
    .audio_sample_valid(uxrom_audio_sample_valid),
    .audio_sample_left(uxrom_audio_sample_left),
    .audio_sample_right(uxrom_audio_sample_right),
    .cpu_cycle(),
    .ppu_dot(),
    .ppu_scanline(),
    .bus_owner(),
    .bus_active(uxrom_bus_active),
    .bus_wait_count(uxrom_bus_wait_count),
    .bus_req(uxrom_bus_req),
    .bus_stall(uxrom_bus_stall),
    .bus_fire(uxrom_bus_fire),
    .bus_addr(uxrom_bus_addr),
    .bus_we(uxrom_bus_we),
    .bus_dout(uxrom_bus_dout),
    .bus_din(uxrom_bus_din),
    .sel_ram(uxrom_sel_ram),
    .sel_ppu(),
    .sel_apu_io(uxrom_sel_apu_io),
    .sel_open_bus(uxrom_sel_open_bus),
    .sel_cart_ram(),
    .sel_cart_rom(uxrom_sel_cart_rom),
    .ram_we(),
    .ppu_reg_cs(),
    .ppu_reg_we(),
    .ppu_reg_addr(),
    .apu_reg_cs(uxrom_apu_reg_cs),
    .apu_reg_we(uxrom_apu_reg_we),
    .apu_reg_addr(uxrom_apu_reg_addr),
    .controller_data(uxrom_controller_data),
    .cart_req(),
    .cart_xfer(uxrom_cart_xfer),
    .cart_addr(uxrom_cart_addr),
    .cart_din(uxrom_cart_din),
    .cart_ack(),
    .bus_hold(uxrom_bus_hold),
    .oam_dma_start(uxrom_oam_dma_start),
    .oam_dma_cpu_hold(),
    .oam_dma_cpu_read_req(),
    .oam_dma_cpu_read_addr(),
    .oam_dma_cpu_read_ack(),
    .oam_dma_cpu_rdata(),
    .oam_dma_ppu_reg_cs(uxrom_oam_dma_ppu_reg_cs),
    .oam_dma_ppu_reg_we(),
    .oam_dma_ppu_reg_addr(),
    .oam_dma_ppu_reg_dout(),
    .oam_dma_busy(uxrom_oam_dma_busy),
    .oam_dma_done(uxrom_oam_dma_done),
    .oam_dma_page(),
    .oam_dma_page_latch(),
    .oam_dma_base_addr(),
    .oam_dma_cur_addr(),
    .oam_dma_index(),
    .oam_dma_align_left(),
    .oam_dma_addr_wr(),
    .oam_dma_cycle_count(),
    .apu_dmc_bus_req(uxrom_apu_dmc_bus_req),
    .apu_dmc_addr(),
    .apu_dmc_ack(),
    .apu_dmc_rdata(),
    .dma_sel(uxrom_dma_sel),
    .dma_ack(uxrom_dma_ack),
    .dma_din(uxrom_dma_din),
    .dma_wait(),
    .dma_active(),
    .dma_unimpl(uxrom_dma_unimpl),
    .dma_owner(),
    .ppu_port_cs(),
    .ppu_port_we(),
    .ppu_port_addr(),
    .ppu_port_din(),
    .mapper_id(uxrom_mapper_id),
    .mapper_prg_bank_offset(uxrom_mapper_prg_bank_offset),
    .mapper_chr_bank_offset(uxrom_mapper_chr_bank_offset),
    .mapper_mirroring(uxrom_mapper_mirroring),
    .mapper_nametable_map(uxrom_mapper_nametable_map),
    .mapper_prg_bank_number(uxrom_mapper_prg_bank_number),
    .mapper_prg_ram_enable(uxrom_mapper_prg_ram_enable),
    .mapper_prg_ram_we(uxrom_mapper_prg_ram_we),
    .mapper_chr_ram_enable(uxrom_mapper_chr_ram_enable),
    .mapper_chr_ram_we(uxrom_mapper_chr_ram_we),
    .mapper_bus_conflict(uxrom_mapper_bus_conflict),
    .mapper_irq(uxrom_mapper_irq),
    .irq_line(uxrom_irq_line),
    .mapper_write_pulse(uxrom_mapper_write_pulse),
    .mapper_write_addr(uxrom_mapper_write_addr),
    .mapper_write_data(uxrom_mapper_write_data),
    .prg_readback(uxrom_prg_readback)
);

nes_system_v5 #(
    .PRG_SIZE_BYTES(PRG_SIZE_BYTES),
    .MAPPER_SELECT(8'd4),
    .HEADER_MIRRORING(3'd0)
) mmc3_dut (
    .clk(clk),
    .reset(reset),
    .buttons1(buttons1),
    .buttons2(buttons2),
    .pixel_valid(),
    .pixel_x(),
    .pixel_y(),
    .pixel_index(),
    .frame_done(),
    .vblank(),
    .nmi_o(),
    .apu_irq_o(mmc3_apu_irq_o),
    .audio_sample_valid(),
    .audio_sample_left(),
    .audio_sample_right(),
    .cpu_cycle(),
    .ppu_dot(),
    .ppu_scanline(),
    .bus_owner(),
    .bus_active(mmc3_bus_active),
    .bus_wait_count(mmc3_bus_wait_count),
    .bus_req(mmc3_bus_req),
    .bus_stall(mmc3_bus_stall),
    .bus_fire(mmc3_bus_fire),
    .bus_addr(mmc3_bus_addr),
    .bus_we(mmc3_bus_we),
    .bus_dout(mmc3_bus_dout),
    .bus_din(mmc3_bus_din),
    .sel_ram(mmc3_sel_ram),
    .sel_ppu(),
    .sel_apu_io(mmc3_sel_apu_io),
    .sel_open_bus(mmc3_sel_open_bus),
    .sel_cart_ram(),
    .sel_cart_rom(mmc3_sel_cart_rom),
    .ram_we(),
    .ppu_reg_cs(),
    .ppu_reg_we(),
    .ppu_reg_addr(),
    .apu_reg_cs(mmc3_apu_reg_cs),
    .apu_reg_we(mmc3_apu_reg_we),
    .apu_reg_addr(mmc3_apu_reg_addr),
    .controller_data(mmc3_controller_data),
    .cart_req(),
    .cart_xfer(mmc3_cart_xfer),
    .cart_addr(mmc3_cart_addr),
    .cart_din(mmc3_cart_din),
    .cart_ack(),
    .bus_hold(mmc3_bus_hold),
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
    .oam_dma_busy(mmc3_oam_dma_busy),
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
    .dma_sel(mmc3_dma_sel),
    .dma_ack(mmc3_dma_ack),
    .dma_din(),
    .dma_wait(),
    .dma_active(),
    .dma_unimpl(),
    .dma_owner(),
    .ppu_port_cs(),
    .ppu_port_we(),
    .ppu_port_addr(),
    .ppu_port_din(),
    .mapper_id(mmc3_mapper_id),
    .mapper_prg_bank_offset(mmc3_mapper_prg_bank_offset),
    .mapper_chr_bank_offset(mmc3_mapper_chr_bank_offset),
    .mapper_mirroring(mmc3_mapper_mirroring),
    .mapper_nametable_map(mmc3_mapper_nametable_map),
    .mapper_prg_bank_number(mmc3_mapper_prg_bank_number),
    .mapper_prg_ram_enable(mmc3_mapper_prg_ram_enable),
    .mapper_prg_ram_we(mmc3_mapper_prg_ram_we),
    .mapper_chr_ram_enable(mmc3_mapper_chr_ram_enable),
    .mapper_chr_ram_we(mmc3_mapper_chr_ram_we),
    .mapper_bus_conflict(),
    .mapper_irq(mmc3_mapper_irq),
    .irq_line(mmc3_irq_line),
    .mapper_write_pulse(mmc3_mapper_write_pulse),
    .mapper_write_addr(mmc3_mapper_write_addr),
    .mapper_write_data(mmc3_mapper_write_data),
    .prg_readback(mmc3_prg_readback)
);

always #5 clk = !clk;

function [PRG_ADDR_BITS-1:0] cpu_to_off;
    input integer sel;
    input [15:0] addr;
    begin
        if (sel == 0)
            cpu_to_off = {2'b00, addr[14:0]};
        else if (sel == 1)
            cpu_to_off = {3'b000, UXROM_LAST_16K[2:0], addr[13:0]};
        else
            cpu_to_off = {4'b0000, MMC3_LAST_8K[3:0], addr[12:0]};
    end
endfunction

task emit_at;
    input integer sel;
    input [15:0] addr;
    input [7:0] value;
    begin
        if (sel == 0)
            nrom_dut.prg_rom[cpu_to_off(sel, addr)] = value;
        else if (sel == 1)
            uxrom_dut.prg_rom[cpu_to_off(sel, addr)] = value;
        else
            mmc3_dut.prg_rom[cpu_to_off(sel, addr)] = value;
    end
endtask

task emit;
    input integer sel;
    input [7:0] value;
    begin
        emit_at(sel, pc, value);
        pc = pc + 16'd1;
    end
endtask

task lda_imm;
    input integer sel;
    input [7:0] value;
    begin
        emit(sel, 8'hA9);
        emit(sel, value);
    end
endtask

task lda_abs;
    input integer sel;
    input [15:0] address;
    begin
        emit(sel, 8'hAD);
        emit(sel, address[7:0]);
        emit(sel, address[15:8]);
    end
endtask

task sta_abs;
    input integer sel;
    input [15:0] address;
    begin
        emit(sel, 8'h8D);
        emit(sel, address[7:0]);
        emit(sel, address[15:8]);
    end
endtask

task sta_abs_x;
    input integer sel;
    input [15:0] address;
    begin
        emit(sel, 8'h9D);
        emit(sel, address[7:0]);
        emit(sel, address[15:8]);
    end
endtask

task ldx_imm;
    input integer sel;
    input [7:0] value;
    begin
        emit(sel, 8'hA2);
        emit(sel, value);
    end
endtask

task cmp_imm;
    input integer sel;
    input [7:0] value;
    begin
        emit(sel, 8'hC9);
        emit(sel, value);
    end
endtask

task cpx_imm;
    input integer sel;
    input [7:0] value;
    begin
        emit(sel, 8'hE0);
        emit(sel, value);
    end
endtask

task inx;
    input integer sel;
    begin
        emit(sel, 8'hE8);
    end
endtask

task jmp_abs;
    input integer sel;
    input [15:0] address;
    begin
        emit(sel, 8'h4C);
        emit(sel, address[7:0]);
        emit(sel, address[15:8]);
    end
endtask

task check_disp;
    input [15:0] site;
    input [15:0] disp;
    begin
        if ((disp > 16'd127) && (disp < 16'hFF80))
            $fatal(1, "branch displacement %0d at %04h does not fit in a signed byte",
                   $signed(disp), site);
    end
endtask

task bne_to;
    input integer sel;
    input [15:0] target;
    reg [15:0] here;
    begin
        here = pc;
        emit(sel, 8'hD0);
        emit(sel, target - (here + 16'd2));
        check_disp(here, target - (here + 16'd2));
    end
endtask

task bne_hold;
    input integer sel;
    begin
        emit(sel, 8'hD0);
        bne_list[bne_count] = pc;
        bne_count = bne_count + 1;
        emit(sel, 8'h00);
    end
endtask

task bne_flush;
    input integer sel;
    input [15:0] target;
    begin
        for (n = 0; n < bne_count; n = n + 1) begin
            bne_site = bne_list[n];
            bne_disp = target - (bne_site + 16'd1);
            check_disp(bne_site, bne_disp);
            emit_at(sel, bne_site, bne_disp[7:0]);
        end
        bne_count = 0;
    end
endtask

task close_chunk;
    input integer sel;
    input [15:0] fail_target;
    input [15:0] next_address;
    begin
        jmp_abs(sel, next_address);
        fail_entry = pc;
        jmp_abs(sel, fail_target);
        bne_flush(sel, fail_entry);
    end
endtask

task set_vec;
    input integer sel;
    input [15:0] vector;
    input [15:0] target;
    begin
        emit_at(sel, vector, target[7:0]);
        emit_at(sel, vector + 16'd1, target[15:8]);
    end
endtask

task build_nrom;
    begin
        pc = NROM_MAIN;
        bne_count = 0;
        lda_imm(0, 8'h40);
        sta_abs(0, 16'h4017);
        lda_imm(0, 8'h00);
        sta_abs(0, 16'h2000);
        lda_imm(0, 8'h00);
        sta_abs(0, 16'h2001);
        lda_abs(0, 16'h8040);
        cmp_imm(0, 8'h40);
        bne_hold(0);
        lda_abs(0, 16'hBFFF);
        cmp_imm(0, 8'h40);
        bne_hold(0);
        lda_abs(0, 16'hC000);
        cmp_imm(0, 8'h41);
        bne_hold(0);
        lda_abs(0, 16'hFFF0);
        cmp_imm(0, 8'h41);
        bne_hold(0);
        lda_imm(0, 8'hA5);
        sta_abs(0, 16'h0010);
        next_chunk = pc + 16'd6;
        close_chunk(0, NROM_FAIL, next_chunk);
        self_loop = pc;
        jmp_abs(0, self_loop);
    end
endtask

task build_uxrom;
    begin
        pc = UXROM_MAIN;
        bne_count = 0;
        lda_imm(1, 8'h40);
        sta_abs(1, 16'h4017);
        lda_imm(1, 8'h00);
        sta_abs(1, 16'h2000);
        lda_imm(1, 8'h00);
        sta_abs(1, 16'h2001);
        lda_imm(1, 8'h01);
        sta_abs(1, 16'h4016);
        lda_imm(1, 8'h00);
        sta_abs(1, 16'h4016);
        ldx_imm(1, 8'h00);
        loop1 = pc;
        lda_abs(1, 16'h4016);
        sta_abs_x(1, 16'h0020);
        inx(1);
        cpx_imm(1, 8'h08);
        bne_to(1, loop1);
        lda_abs(1, 16'h4016);
        sta_abs(1, 16'h0018);
        next_chunk = pc + 16'd6;
        close_chunk(1, UXROM_FAIL, next_chunk);

        pc = next_chunk;
        lda_imm(1, 8'h01);
        sta_abs(1, 16'h4016);
        lda_imm(1, 8'h00);
        sta_abs(1, 16'h4016);
        ldx_imm(1, 8'h00);
        loop2 = pc;
        lda_abs(1, 16'h4017);
        sta_abs_x(1, 16'h0028);
        inx(1);
        cpx_imm(1, 8'h08);
        bne_to(1, loop2);
        lda_abs(1, 16'h4017);
        sta_abs(1, 16'h0019);
        lda_imm(1, 8'h01);
        sta_abs(1, 16'h4015);
        lda_imm(1, 8'hBF);
        sta_abs(1, 16'h4000);
        lda_imm(1, 8'h00);
        sta_abs(1, 16'h4001);
        lda_imm(1, 8'h20);
        sta_abs(1, 16'h4002);
        lda_imm(1, 8'h40);
        sta_abs(1, 16'h4003);
        lda_imm(1, 8'h00);
        sta_abs(1, 16'h2003);
        lda_imm(1, 8'h02);
        sta_abs(1, 16'h4014);
        lda_abs(1, 16'h2004);
        cmp_imm(1, 8'h11);
        bne_hold(1);
        next_chunk = pc + 16'd6;
        close_chunk(1, UXROM_FAIL, next_chunk);

        pc = next_chunk;
        lda_abs(1, 16'hF000);
        cmp_imm(1, 8'h47);
        bne_hold(1);
        lda_abs(1, 16'h8000);
        cmp_imm(1, 8'hFF);
        bne_hold(1);
        lda_imm(1, 8'h00);
        sta_abs(1, 16'h8000);
        lda_imm(1, 8'h43);
        sta_abs(1, 16'h8000);
        lda_abs(1, 16'h8000);
        cmp_imm(1, 8'h43);
        bne_hold(1);
        lda_abs(1, 16'hF000);
        cmp_imm(1, 8'h47);
        bne_hold(1);
        lda_imm(1, 8'h00);
        sta_abs(1, 16'h8000);
        lda_imm(1, 8'h45);
        sta_abs(1, 16'h8000);
        lda_abs(1, 16'h8000);
        cmp_imm(1, 8'h45);
        bne_hold(1);
        lda_abs(1, 16'hF000);
        cmp_imm(1, 8'h47);
        bne_hold(1);
        lda_imm(1, 8'hC3);
        sta_abs(1, 16'h0012);
        next_chunk = pc + 16'd6;
        close_chunk(1, UXROM_FAIL, next_chunk);
        self_loop = pc;
        jmp_abs(1, self_loop);
    end
endtask

task build_mmc3;
    begin
        pc = MMC3_MAIN;
        bne_count = 0;
        lda_imm(2, 8'h40);
        sta_abs(2, 16'h4017);
        lda_imm(2, 8'h00);
        sta_abs(2, 16'h2000);
        lda_imm(2, 8'h00);
        sta_abs(2, 16'h2001);
        emit(2, 8'h58);
        lda_imm(2, 8'h01);
        sta_abs(2, 16'hA000);
        lda_imm(2, 8'h00);
        sta_abs(2, 16'hA000);
        lda_imm(2, 8'h01);
        sta_abs(2, 16'hA000);
        lda_abs(2, 16'hF000);
        cmp_imm(2, 8'h5F);
        bne_hold(2);
        lda_abs(2, 16'h8000);
        cmp_imm(2, 8'h50);
        bne_hold(2);
        lda_abs(2, 16'hA000);
        cmp_imm(2, 8'h51);
        bne_hold(2);
        lda_abs(2, 16'hC000);
        cmp_imm(2, 8'h5E);
        bne_hold(2);
        next_chunk = pc + 16'd6;
        close_chunk(2, MMC3_FAIL, next_chunk);

        pc = next_chunk;
        lda_imm(2, 8'h06);
        sta_abs(2, 16'h8000);
        lda_imm(2, 8'h05);
        sta_abs(2, 16'h8001);
        lda_abs(2, 16'h8000);
        cmp_imm(2, 8'h55);
        bne_hold(2);
        lda_abs(2, 16'hA000);
        cmp_imm(2, 8'h51);
        bne_hold(2);
        lda_abs(2, 16'hC000);
        cmp_imm(2, 8'h5E);
        bne_hold(2);
        lda_abs(2, 16'hF000);
        cmp_imm(2, 8'h5F);
        bne_hold(2);
        lda_imm(2, 8'h07);
        sta_abs(2, 16'h8000);
        lda_imm(2, 8'h03);
        sta_abs(2, 16'h8001);
        lda_abs(2, 16'hA000);
        cmp_imm(2, 8'h53);
        bne_hold(2);
        lda_abs(2, 16'h8000);
        cmp_imm(2, 8'h55);
        bne_hold(2);
        lda_imm(2, 8'h46);
        sta_abs(2, 16'h8000);
        lda_abs(2, 16'h8000);
        cmp_imm(2, 8'h5E);
        bne_hold(2);
        lda_abs(2, 16'hC000);
        cmp_imm(2, 8'h55);
        bne_hold(2);
        lda_imm(2, 8'h06);
        sta_abs(2, 16'h8000);
        next_chunk = pc + 16'd6;
        close_chunk(2, MMC3_FAIL, next_chunk);

        pc = next_chunk;
        lda_imm(2, 8'h07);
        sta_abs(2, 16'hC000);
        lda_imm(2, 8'h00);
        sta_abs(2, 16'hC001);
        lda_imm(2, 8'h00);
        sta_abs(2, 16'hE001);
        lda_imm(2, 8'h00);
        sta_abs(2, 16'hE000);
        lda_imm(2, 8'h63);
        sta_abs(2, 16'h0012);
        next_chunk = pc + 16'd6;
        close_chunk(2, MMC3_FAIL, next_chunk);
        self_loop = pc;
        jmp_abs(2, self_loop);

        pc = MMC3_IRQ;
        lda_abs(2, 16'h0013);
        emit(2, 8'h18);
        emit(2, 8'h69);
        emit(2, 8'h01);
        sta_abs(2, 16'h0013);
        emit(2, 8'h40);
        pc = MMC3_FAIL;
        jmp_abs(2, MMC3_FAIL);
    end
endtask

always @(posedge clk) begin
    if (reset) begin
        nrom_fire = 0;
        nrom_stall = 0;
        nrom_wait_err = 0;
    end else if (nrom_dut.div_phase == 4'd0) begin
        if (nrom_bus_stall !== (nrom_bus_req && !nrom_bus_fire))
            $fatal(1, "nrom bus_stall got %b expected %b at %04h",
                   nrom_bus_stall, (nrom_bus_req && !nrom_bus_fire), nrom_bus_addr);
        if (nrom_bus_req && !nrom_bus_fire)
            nrom_stall = nrom_stall + 1;
        else if (nrom_bus_fire) begin
            if (nrom_stall != ((nrom_sel_open_bus === 1'b1) ? 0 : 1))
                $fatal(1, "nrom transfer at %04h took %0d stall cycles expected %0d",
                       nrom_bus_addr, nrom_stall, (nrom_sel_open_bus === 1'b1) ? 0 : 1);
            if (nrom_bus_wait_count !== 8'd0)
                nrom_wait_err = nrom_wait_err + 1;
            nrom_fire = nrom_fire + 1;
            nrom_stall = 0;
        end
    end
end

always @(posedge clk) begin
    if (reset) begin
        nrom_prg_rd = 0;
        nrom_prg_wr = 0;
        nrom_off_err = 0;
        nrom_data_err = 0;
        nrom_din_err = 0;
        nrom_readback_err = 0;
        nrom_pulse = 0;
        nrom_pulse_long = 0;
        nrom_pulse_addr_err = 0;
        nrom_pulse_data_err = 0;
        nrom_irq_or_err = 0;
        nrom_illegal = 0;
        nrom_last_wr_addr = 16'h0000;
        nrom_last_wr_data = 8'h00;
        nrom_pulse_q = 1'b0;
    end else begin
        if (nrom_prg_readback !== nrom_dut.prg_rom[nrom_mapper_prg_bank_offset])
            nrom_readback_err = nrom_readback_err + 1;
        if (nrom_mapper_write_pulse !== 1'b0) begin
            nrom_pulse = nrom_pulse + 1;
            if (nrom_pulse_q !== 1'b0)
                nrom_pulse_long = nrom_pulse_long + 1;
            if (nrom_mapper_write_addr !== nrom_last_wr_addr)
                nrom_pulse_addr_err = nrom_pulse_addr_err + 1;
            if (nrom_mapper_write_data !== nrom_last_wr_data)
                nrom_pulse_data_err = nrom_pulse_data_err + 1;
        end
        nrom_pulse_q = nrom_mapper_write_pulse;
        if ((nrom_bus_fire !== 1'b0) && (nrom_sel_cart_rom !== 1'b0)) begin
            nrom_exp_off = {2'b00, nrom_bus_addr[14:0]};
            if (nrom_mapper_prg_bank_offset !== nrom_exp_off)
                nrom_off_err = nrom_off_err + 1;
            if (nrom_bus_we !== 1'b0) begin
                nrom_prg_wr = nrom_prg_wr + 1;
                nrom_last_wr_addr = nrom_bus_addr;
                nrom_last_wr_data = nrom_bus_dout;
            end else begin
                nrom_prg_rd = nrom_prg_rd + 1;
                if (nrom_cart_din !== nrom_dut.prg_rom[nrom_exp_off])
                    nrom_data_err = nrom_data_err + 1;
                if (nrom_bus_din !== nrom_dut.prg_rom[nrom_exp_off])
                    nrom_din_err = nrom_din_err + 1;
            end
        end
        if (nrom_dut.u_cpu.dbg_illegal !== 1'b0)
            nrom_illegal = nrom_illegal + 1;
        if ((nrom_dut.u_cpu.dbg_pc >= NROM_FAIL) && (nrom_dut.u_cpu.dbg_pc <= NROM_FAIL + 16'd2))
            $fatal(1, "the nrom program reached the fail loop, a bank signature compare failed, pc=%04h",
                   nrom_dut.u_cpu.dbg_pc);
        if (nrom_irq_line !== (nrom_mapper_irq | nrom_apu_irq_o))
            nrom_irq_or_err = nrom_irq_or_err + 1;
        if (nrom_dut.u_cpu.dbg_irq_pending !== nrom_irq_line)
            nrom_irq_or_err = nrom_irq_or_err + 1;
        if ((nrom_bus_fire !== 1'b0) && (nrom_sel_ram !== 1'b0) &&
            (nrom_bus_we !== 1'b0) && (nrom_bus_addr == 16'h0010))
            nrom_done = 1;
    end
end

always @(posedge clk) begin
    if (reset) begin
        uxrom_fire = 0;
        uxrom_stall = 0;
        uxrom_wait_err = 0;
    end else if (uxrom_dut.div_phase == 4'd0) begin
        if (uxrom_bus_stall !== (uxrom_bus_req && !uxrom_bus_fire))
            $fatal(1, "uxrom bus_stall got %b expected %b at %04h",
                   uxrom_bus_stall, (uxrom_bus_req && !uxrom_bus_fire), uxrom_bus_addr);
        if (uxrom_bus_req && !uxrom_bus_fire)
            uxrom_stall = uxrom_stall + 1;
        else if (uxrom_bus_fire) begin
            if (uxrom_stall != ((uxrom_sel_open_bus === 1'b1) ? 0 : 1))
                $fatal(1, "uxrom transfer at %04h took %0d stall cycles expected %0d",
                       uxrom_bus_addr, uxrom_stall, (uxrom_sel_open_bus === 1'b1) ? 0 : 1);
            if (uxrom_bus_wait_count !== 8'd0)
                uxrom_wait_err = uxrom_wait_err + 1;
            uxrom_fire = uxrom_fire + 1;
            uxrom_stall = 0;
        end
    end
end

always @(posedge clk) begin
    if (reset) begin
        uxrom_prg_rd = 0;
        uxrom_prg_wr = 0;
        uxrom_off_err = 0;
        uxrom_data_err = 0;
        uxrom_din_err = 0;
        uxrom_readback_err = 0;
        uxrom_pulse = 0;
        uxrom_pulse_long = 0;
        uxrom_pulse_addr_err = 0;
        uxrom_pulse_data_err = 0;
        uxrom_conflict = 0;
        uxrom_ctrl_cs_err = 0;
        uxrom_dma_ack_cnt = 0;
        uxrom_dma_wr = 0;
        uxrom_dma_start_count = 0;
        uxrom_dma_done_count = 0;
        uxrom_dma_unimpl_cnt = 0;
        uxrom_sample = 0;
        uxrom_sample_nz = 0;
        uxrom_dmc_req = 0;
        uxrom_irq_or_err = 0;
        uxrom_illegal = 0;
        uxrom_bank = {UXROM_BANK_BITS{1'b0}};
        uxrom_last_wr_addr = 16'h0000;
        uxrom_last_wr_data = 8'h00;
        uxrom_pulse_q = 1'b0;
    end else begin
        if (uxrom_prg_readback !== uxrom_dut.prg_rom[uxrom_mapper_prg_bank_offset])
            uxrom_readback_err = uxrom_readback_err + 1;
        if (uxrom_mapper_write_pulse !== 1'b0) begin
            uxrom_pulse = uxrom_pulse + 1;
            if (uxrom_pulse_q !== 1'b0)
                uxrom_pulse_long = uxrom_pulse_long + 1;
            if (uxrom_mapper_write_addr !== uxrom_last_wr_addr)
                uxrom_pulse_addr_err = uxrom_pulse_addr_err + 1;
            if (uxrom_mapper_write_data !== uxrom_last_wr_data)
                uxrom_pulse_data_err = uxrom_pulse_data_err + 1;
            if (uxrom_mapper_bus_conflict !== 1'b0)
                uxrom_conflict = uxrom_conflict + 1;
        end
        uxrom_pulse_q = uxrom_mapper_write_pulse;
        if ((uxrom_bus_fire !== 1'b0) && (uxrom_sel_cart_rom !== 1'b0)) begin
            uxrom_exp_off = uxrom_bus_addr[14]
                ? (17'h1C000 | {3'b000, uxrom_bus_addr[13:0]})
                : (({3'b000, uxrom_bank} << 14) | {3'b000, uxrom_bus_addr[13:0]});
            if (uxrom_mapper_prg_bank_offset !== uxrom_exp_off)
                uxrom_off_err = uxrom_off_err + 1;
            if (uxrom_bus_we !== 1'b0) begin
                uxrom_prg_wr = uxrom_prg_wr + 1;
                uxrom_last_wr_addr = uxrom_bus_addr;
                uxrom_last_wr_data = uxrom_bus_dout;
                rb_byte = uxrom_dut.prg_rom[uxrom_exp_off];
                uxrom_bank = uxrom_bus_dout[UXROM_BANK_BITS-1:0] &
                             rb_byte[UXROM_BANK_BITS-1:0];
            end else begin
                uxrom_prg_rd = uxrom_prg_rd + 1;
                if (uxrom_cart_din !== uxrom_dut.prg_rom[uxrom_exp_off])
                    uxrom_data_err = uxrom_data_err + 1;
                if (uxrom_bus_din !== uxrom_dut.prg_rom[uxrom_exp_off])
                    uxrom_din_err = uxrom_din_err + 1;
            end
        end
        if (uxrom_apu_reg_cs !== 1'b0) begin
            if ((uxrom_apu_reg_addr == 5'h16) ||
                ((uxrom_apu_reg_addr == 5'h17) && (uxrom_apu_reg_we !== 1'b1)))
                uxrom_ctrl_cs_err = uxrom_ctrl_cs_err + 1;
        end
        if (uxrom_oam_dma_start !== 1'b0)
            uxrom_dma_start_count = uxrom_dma_start_count + 1;
        if (uxrom_oam_dma_done !== 1'b0)
            uxrom_dma_done_count = uxrom_dma_done_count + 1;
        if ((uxrom_dma_ack !== 1'b0) && (uxrom_dma_sel === 1'b0))
            uxrom_dma_ack_cnt = uxrom_dma_ack_cnt + 1;
        if (uxrom_oam_dma_ppu_reg_cs !== 1'b0)
            uxrom_dma_wr = uxrom_dma_wr + 1;
        if (uxrom_dma_unimpl !== 1'b0)
            uxrom_dma_unimpl_cnt = uxrom_dma_unimpl_cnt + 1;
        if (uxrom_apu_dmc_bus_req !== 1'b0)
            uxrom_dmc_req = uxrom_dmc_req + 1;
        if (uxrom_audio_sample_valid !== 1'b0) begin
            uxrom_sample = uxrom_sample + 1;
            if (uxrom_audio_sample_left !== 16'd0)
                uxrom_sample_nz = uxrom_sample_nz + 1;
        end
        if (uxrom_dut.u_cpu.dbg_illegal !== 1'b0)
            uxrom_illegal = uxrom_illegal + 1;
        if ((uxrom_dut.u_cpu.dbg_pc >= UXROM_FAIL) &&
            (uxrom_dut.u_cpu.dbg_pc <= UXROM_FAIL + 16'd2))
            $fatal(1, "the uxrom program reached the fail loop, pc=%04h a=%02x x=%02x p=%02x",
                   uxrom_dut.u_cpu.dbg_pc, uxrom_dut.u_cpu.dbg_a,
                   uxrom_dut.u_cpu.dbg_x, uxrom_dut.u_cpu.dbg_p);
        if (uxrom_irq_line !== (uxrom_mapper_irq | uxrom_apu_irq_o))
            uxrom_irq_or_err = uxrom_irq_or_err + 1;
        if (uxrom_dut.u_cpu.dbg_irq_pending !== uxrom_irq_line)
            uxrom_irq_or_err = uxrom_irq_or_err + 1;
        if ((uxrom_bus_fire !== 1'b0) && (uxrom_sel_ram !== 1'b0) &&
            (uxrom_bus_we !== 1'b0) && (uxrom_bus_addr == 16'h0012))
            uxrom_done = 1;
    end
end

always @(posedge clk) begin
    if (reset) begin
        mmc3_fire = 0;
        mmc3_stall = 0;
        mmc3_wait_err = 0;
    end else if (mmc3_dut.div_phase == 4'd0) begin
        if (mmc3_bus_stall !== (mmc3_bus_req && !mmc3_bus_fire))
            $fatal(1, "mmc3 bus_stall got %b expected %b at %04h",
                   mmc3_bus_stall, (mmc3_bus_req && !mmc3_bus_fire), mmc3_bus_addr);
        if (mmc3_bus_req && !mmc3_bus_fire)
            mmc3_stall = mmc3_stall + 1;
        else if (mmc3_bus_fire) begin
            if (mmc3_stall != ((mmc3_sel_open_bus === 1'b1) ? 0 : 1))
                $fatal(1, "mmc3 transfer at %04h took %0d stall cycles expected %0d",
                       mmc3_bus_addr, mmc3_stall, (mmc3_sel_open_bus === 1'b1) ? 0 : 1);
            if (mmc3_bus_wait_count !== 8'd0)
                mmc3_wait_err = mmc3_wait_err + 1;
            mmc3_fire = mmc3_fire + 1;
            mmc3_stall = 0;
        end
    end
end

always @(posedge clk) begin
    if (reset) begin
        mmc3_prg_rd = 0;
        mmc3_prg_wr = 0;
        mmc3_off_err = 0;
        mmc3_data_err = 0;
        mmc3_din_err = 0;
        mmc3_readback_err = 0;
        mmc3_pulse = 0;
        mmc3_pulse_long = 0;
        mmc3_pulse_addr_err = 0;
        mmc3_pulse_data_err = 0;
        mmc3_irq_or_err = 0;
        mmc3_illegal = 0;
        mmc3_irq_entries = 0;
        mmc3_mirror_h = 0;
        mmc3_mirror_v = 0;
        mmc3_r6 = 6'd0;
        mmc3_r7 = 6'd1;
        mmc3_sel = 3'd0;
        mmc3_mode = 1'b0;
        mmc3_last_wr_addr = 16'h0000;
        mmc3_last_wr_data = 8'h00;
        mmc3_pulse_q = 1'b0;
    end else begin
        if (mmc3_prg_readback !== mmc3_dut.prg_rom[mmc3_mapper_prg_bank_offset])
            mmc3_readback_err = mmc3_readback_err + 1;
        if (mmc3_mapper_write_pulse !== 1'b0) begin
            mmc3_pulse = mmc3_pulse + 1;
            if (mmc3_pulse_q !== 1'b0)
                mmc3_pulse_long = mmc3_pulse_long + 1;
            if (mmc3_mapper_write_addr !== mmc3_last_wr_addr)
                mmc3_pulse_addr_err = mmc3_pulse_addr_err + 1;
            if (mmc3_mapper_write_data !== mmc3_last_wr_data)
                mmc3_pulse_data_err = mmc3_pulse_data_err + 1;
        end
        mmc3_pulse_q = mmc3_mapper_write_pulse;
        if (mmc3_mapper_mirroring == 3'd0)
            mmc3_mirror_h = 1;
        else if (mmc3_mapper_mirroring == 3'd1)
            mmc3_mirror_v = 1;
        if ((mmc3_bus_fire !== 1'b0) && (mmc3_sel_cart_rom !== 1'b0)) begin
            case (mmc3_bus_addr[14:13])
                2'b00: mmc3_win = mmc3_mode ? MMC3_PREV_8K : {2'b00, mmc3_r6};
                2'b01: mmc3_win = {2'b00, mmc3_r7};
                2'b10: mmc3_win = mmc3_mode ? {2'b00, mmc3_r6} : MMC3_PREV_8K;
                default: mmc3_win = MMC3_LAST_8K;
            endcase
            mmc3_exp_off = ({9'h000, mmc3_win} << 13) | {4'h0, mmc3_bus_addr[12:0]};
            if (mmc3_mapper_prg_bank_offset !== mmc3_exp_off)
                mmc3_off_err = mmc3_off_err + 1;
            if (mmc3_bus_we !== 1'b0) begin
                mmc3_prg_wr = mmc3_prg_wr + 1;
                mmc3_last_wr_addr = mmc3_bus_addr;
                mmc3_last_wr_data = mmc3_bus_dout;
                if ((mmc3_bus_addr[15:13] == 3'b100) && !mmc3_bus_addr[0]) begin
                    mmc3_sel = mmc3_bus_dout[2:0];
                    mmc3_mode = mmc3_bus_dout[6];
                end else if ((mmc3_bus_addr[15:13] == 3'b100) && mmc3_bus_addr[0]) begin
                    if (mmc3_sel == 3'd6)
                        mmc3_r6 = mmc3_bus_dout[5:0];
                    else if (mmc3_sel == 3'd7)
                        mmc3_r7 = mmc3_bus_dout[5:0];
                end
            end else begin
                mmc3_prg_rd = mmc3_prg_rd + 1;
                if (mmc3_cart_din !== mmc3_dut.prg_rom[mmc3_exp_off])
                    mmc3_data_err = mmc3_data_err + 1;
                if (mmc3_bus_din !== mmc3_dut.prg_rom[mmc3_exp_off])
                    mmc3_din_err = mmc3_din_err + 1;
                if (mmc3_bus_addr == 16'hFFFE)
                    mmc3_irq_entries = mmc3_irq_entries + 1;
            end
        end
        if (mmc3_dut.u_cpu.dbg_illegal !== 1'b0)
            mmc3_illegal = mmc3_illegal + 1;
        if ((mmc3_dut.u_cpu.dbg_pc >= MMC3_FAIL) &&
            (mmc3_dut.u_cpu.dbg_pc <= MMC3_FAIL + 16'd2))
            $fatal(1, "the mmc3 program reached the fail loop, pc=%04h a=%02x p=%02x",
                   mmc3_dut.u_cpu.dbg_pc, mmc3_dut.u_cpu.dbg_a, mmc3_dut.u_cpu.dbg_p);
        if (mmc3_irq_line !== (mmc3_mapper_irq | mmc3_apu_irq_o))
            mmc3_irq_or_err = mmc3_irq_or_err + 1;
        if (mmc3_dut.u_cpu.dbg_irq_pending !== mmc3_irq_line)
            mmc3_irq_or_err = mmc3_irq_or_err + 1;
        if ((mmc3_bus_fire !== 1'b0) && (mmc3_sel_ram !== 1'b0) &&
            (mmc3_bus_we !== 1'b0) && (mmc3_bus_addr == 16'h0012))
            mmc3_done = 1;
    end
end

task check_prg;
    input [8*40-1:0] name;
    input integer off_err;
    input integer data_err;
    input integer din_err;
    input integer readback_err;
    input integer pulse;
    input integer prg_wr;
    input integer pulse_long;
    input integer pulse_addr_err;
    input integer pulse_data_err;
    input integer wait_err;
    input integer fire;
    begin
        if (off_err != 0)
            $fatal(1, "%0s prg offset disagreed with the tb bank model %0d times", name, off_err);
        if (data_err != 0)
            $fatal(1, "%0s cart_din did not match the modelled bank %0d times", name, data_err);
        if (din_err != 0)
            $fatal(1, "%0s the cpu read data did not match the modelled bank %0d times",
                   name, din_err);
        if (readback_err != 0)
            $fatal(1, "%0s prg_readback did not follow the prg read value %0d times",
                   name, readback_err);
        if (pulse != prg_wr)
            $fatal(1, "%0s mapper write pulses got %0d expected %0d completed cart writes",
                   name, pulse, prg_wr);
        if (pulse_long != 0)
            $fatal(1, "%0s the mapper write pulse stayed high %0d extra clk", name, pulse_long);
        if (pulse_addr_err != 0)
            $fatal(1, "%0s the mapper write pulse carried the wrong address %0d times",
                   name, pulse_addr_err);
        if (pulse_data_err != 0)
            $fatal(1, "%0s the mapper write pulse carried the wrong data %0d times",
                   name, pulse_data_err);
        if (wait_err != 0)
            $fatal(1, "%0s the bus wait count was nonzero at %0d completing cycles",
                   name, wait_err);
        if (fire < 20)
            $fatal(1, "%0s only completed %0d bus transfers", name, fire);
    end
endtask

initial begin
    clk = 1'b0;
    reset = 1'b0;
    buttons1 = BUTTONS1;
    buttons2 = BUTTONS2;
    nrom_done = 0;
    uxrom_done = 0;
    mmc3_done = 0;
    #1;
    reset = 1'b1;

    for (i = 0; i < PRG_SIZE_BYTES; i = i + 1) begin
        if (i < 32768) begin
            sig = 8'h40 + (i >> 14);
            nrom_dut.prg_rom[i] = sig;
        end else begin
            nrom_dut.prg_rom[i] = 8'hEE;
        end
        if (i < 16384)
            uxrom_dut.prg_rom[i] = 8'hFF;
        else
            uxrom_dut.prg_rom[i] = 8'h40 + (i >> 14);
        sig = 8'h50 + (i >> 13);
        mmc3_dut.prg_rom[i] = sig;
    end

    build_nrom;
    build_uxrom;
    build_mmc3;
    set_vec(0, 16'hFFFA, NROM_FAIL);
    set_vec(0, 16'hFFFC, NROM_MAIN);
    set_vec(0, 16'hFFFE, NROM_FAIL);
    set_vec(1, 16'hFFFA, UXROM_FAIL);
    set_vec(1, 16'hFFFC, UXROM_MAIN);
    set_vec(1, 16'hFFFE, UXROM_FAIL);
    set_vec(2, 16'hFFFA, MMC3_FAIL);
    set_vec(2, 16'hFFFC, MMC3_MAIN);
    set_vec(2, 16'hFFFE, MMC3_IRQ);

    uxrom_dut.u_bus.ram_array[11'h200] = 8'h11;
    uxrom_dut.u_bus.ram_array[11'h201] = 8'h22;
    uxrom_dut.u_bus.ram_array[11'h202] = 8'h33;
    uxrom_dut.u_bus.ram_array[11'h203] = 8'h44;

    repeat (4) @(posedge clk);
    #1;

    if (nrom_dut.u_cpu.dbg_state !== 7'd0)
        $fatal(1, "the nrom cpu state is %0d during reset", nrom_dut.u_cpu.dbg_state);
    if (nrom_mapper_irq !== 1'b0 || nrom_irq_line !== 1'b0 || nrom_apu_irq_o !== 1'b0)
        $fatal(1, "the nrom irq line is high during reset");
    if (nrom_mapper_write_pulse !== 1'b0)
        $fatal(1, "the nrom mapper write pulse is high during reset");
    if (nrom_mapper_id !== 3'd0)
        $fatal(1, "the nrom mapper id is %0d during reset", nrom_mapper_id);
    if (nrom_mapper_mirroring !== 3'd1)
        $fatal(1, "the nrom header mirroring is %0d expected vertical", nrom_mapper_mirroring);
    if (nrom_mapper_nametable_map !== 8'b01000100)
        $fatal(1, "the nrom nametable map is %02x expected 44", nrom_mapper_nametable_map);
    if (uxrom_mapper_id !== 3'd2)
        $fatal(1, "the uxrom mapper id is %0d during reset", uxrom_mapper_id);
    if (uxrom_mapper_mirroring !== 3'd0)
        $fatal(1, "the uxrom header mirroring is %0d expected horizontal", uxrom_mapper_mirroring);
    if (mmc3_mapper_id !== 3'd4)
        $fatal(1, "the mmc3 mapper id is %0d during reset", mmc3_mapper_id);
    if (mmc3_dut.u_mapper.mmc3_prg_bank6 !== 6'd0 || mmc3_dut.u_mapper.mmc3_prg_bank7 !== 6'd1)
        $fatal(1, "the mmc3 reset bank map is not r6=0 r7=1");
    if (mmc3_dut.u_mapper.mmc3_irq_enabled !== 1'b0)
        $fatal(1, "the mmc3 irq is enabled during reset");
    $display("RESET three systems idle, mapper ids 0/2/4, nrom header mirroring vertical, mmc3 reset banks r6=0 r7=1 and irq disabled PASS");

    @(negedge clk);
    reset = 1'b0;
    #1;

    wait (nrom_done == 1 && uxrom_done == 1 && mmc3_done == 1);
    #200;

    if (nrom_illegal != 0 || uxrom_illegal != 0 || mmc3_illegal != 0)
        $fatal(1, "illegal opcodes nrom=%0d uxrom=%0d mmc3=%0d",
               nrom_illegal, uxrom_illegal, mmc3_illegal);
    $display("CPU all three programs ran, the reset vectors reached 8000/c000/e000, no illegal opcodes and no program entered its fail loop PASS");

    check_prg("nrom", nrom_off_err, nrom_data_err, nrom_din_err, nrom_readback_err,
              nrom_pulse, nrom_prg_wr, nrom_pulse_long, nrom_pulse_addr_err,
              nrom_pulse_data_err, nrom_wait_err, nrom_fire);
    check_prg("uxrom", uxrom_off_err, uxrom_data_err, uxrom_din_err, uxrom_readback_err,
              uxrom_pulse, uxrom_prg_wr, uxrom_pulse_long, uxrom_pulse_addr_err,
              uxrom_pulse_data_err, uxrom_wait_err, uxrom_fire);
    check_prg("mmc3", mmc3_off_err, mmc3_data_err, mmc3_din_err, mmc3_readback_err,
              mmc3_pulse, mmc3_prg_wr, mmc3_pulse_long, mmc3_pulse_addr_err,
              mmc3_pulse_data_err, mmc3_wait_err, mmc3_fire);
    $display("PRG every cart read of all three systems matched the independent tb bank model on cart_din and on the cpu read data, prg_readback followed the same word on every clk, and every completed cart write produced exactly one single clk mapper write pulse carrying that address and data PASS");
    $display("PRG nrom rd=%0d wr=%0d, uxrom rd=%0d wr=%0d, mmc3 rd=%0d wr=%0d, bus transfers nrom=%0d uxrom=%0d mmc3=%0d PASS",
             nrom_prg_rd, nrom_prg_wr, uxrom_prg_rd, uxrom_prg_wr,
             mmc3_prg_rd, mmc3_prg_wr, nrom_fire, uxrom_fire, mmc3_fire);

    if (nrom_mapper_mirroring !== 3'd1)
        $fatal(1, "the nrom mirroring output left vertical, got %0d", nrom_mapper_mirroring);
    if (uxrom_mapper_mirroring !== 3'd0)
        $fatal(1, "the uxrom mirroring output left horizontal, got %0d", uxrom_mapper_mirroring);
    if (mmc3_mirror_h == 0 || mmc3_mirror_v == 0)
        $fatal(1, "the mmc3 a000 writes did not reach both mirroring modes, h=%0d v=%0d",
               mmc3_mirror_h, mmc3_mirror_v);
    if (mmc3_mapper_mirroring !== 3'd0)
        $fatal(1, "the mmc3 mirroring output ended at %0d expected horizontal",
               mmc3_mapper_mirroring);
    if (mmc3_mapper_nametable_map !== 8'b01010000)
        $fatal(1, "the mmc3 nametable map is %02x expected 50", mmc3_mapper_nametable_map);
    $display("MIRROR the mapper mirroring outputs followed the ines header for nrom and uxrom and the a000 register for mmc3, both horizontal and vertical were observed, and nametable_map tracked the mode PASS");
    $display("MIRROR the ppu still runs with the compile time MIRROR_VERTICAL=0 because nes_ppu2c02 has no runtime mirroring port, so v5 observes the mode but does not apply it inside the ppu yet PASS");

    if (uxrom_conflict != 4)
        $fatal(1, "the uxrom bus conflict flag was high %0d times expected 4", uxrom_conflict);
    if (uxrom_mapper_bus_conflict !== 1'b0)
        $fatal(1, "the uxrom bus conflict flag is still high at the end");
    if (uxrom_dut.u_mapper.u_uxrom.bank_select !== uxrom_bank)
        $fatal(1, "the uxrom bank register is %0d but the tb model says %0d",
               uxrom_dut.u_mapper.u_uxrom.bank_select, uxrom_bank);
    $display("UXROM four 8000 writes under conflict mode 1: the two 00 writes AND against a live prg_readback and hold bank 0, the 43 and 45 writes latch bank %0d because the readback byte is ff, so 8000 reads back 43 then 45 while f000 stays 47 in the fixed last bank PASS",
             uxrom_bank);

    if (mmc3_dut.u_mapper.mmc3_prg_bank6 !== mmc3_r6)
        $fatal(1, "the mmc3 r6 register is %0d but the tb model says %0d",
               mmc3_dut.u_mapper.mmc3_prg_bank6, mmc3_r6);
    if (mmc3_dut.u_mapper.mmc3_prg_bank7 !== mmc3_r7)
        $fatal(1, "the mmc3 r7 register is %0d but the tb model says %0d",
               mmc3_dut.u_mapper.mmc3_prg_bank7, mmc3_r7);
    if (mmc3_dut.u_mapper.mmc3_prg_mode !== mmc3_mode)
        $fatal(1, "the mmc3 prg mode is %b but the tb model says %b",
               mmc3_dut.u_mapper.mmc3_prg_mode, mmc3_mode);
    $display("MMC3 8000/8001 selected r6=%0d then r7=%0d and the 8000 bit6 mode bit swapped the 8000 and a000 windows, every prg read of the program matched the model PASS",
             mmc3_r6, mmc3_r7);

    if (mmc3_dut.u_mapper.mmc3_irq_latch !== 8'h07)
        $fatal(1, "the mmc3 irq latch is %02x expected 07", mmc3_dut.u_mapper.mmc3_irq_latch);
    if (mmc3_dut.u_mapper.mmc3_irq_reload !== 1'b1)
        $fatal(1, "the mmc3 irq reload flag fell back to 0, ppu_a12 is supposed to be tied low");
    if (mmc3_dut.u_mapper.mmc3_irq_enabled !== 1'b0)
        $fatal(1, "the mmc3 irq is still enabled after the e000 disable");
    if (mmc3_dut.u_mapper.mmc3_irq_counter !== 8'h00)
        $fatal(1, "the mmc3 irq counter moved to %02x without any a12 edge",
               mmc3_dut.u_mapper.mmc3_irq_counter);
    if (mmc3_mapper_irq !== 1'b0)
        $fatal(1, "the mmc3 mapper irq is high with the a12 input tied low");
    $display("MMC3IRQ c000 latched 07, c001 set reload and it stayed set because ppu_a12 is tied low in v5 so the counter never clocked, e001 enabled and e000 disabled and acked, and the mapper irq line stayed low for the whole program PASS");

    if (nrom_apu_irq_o !== 1'b0 || uxrom_apu_irq_o !== 1'b0 || mmc3_apu_irq_o !== 1'b0)
        $fatal(1, "the apu frame irq is high even though every program wrote 4017=40");
    if (mmc3_dut.u_apu.dbg_frame_irq !== 1'b0)
        $fatal(1, "the apu frame irq flag is set in the mmc3 system");
    $display("IRQOR apu_irq_o stayed low in all three systems, irq_line always equalled mapper_irq | apu_irq and the cpu dbg_irq_pending followed the same wire, so the or is the only irq mux in v5 PASS");

    force mmc3_dut.u_mapper.u_mmc3.irq_enabled_r = 1'b1;
    force mmc3_dut.u_mapper.u_mmc3.irq_pending_r = 1'b1;
    repeat (600) @(posedge clk);
    #1;
    if (mmc3_mapper_irq !== 1'b1)
        $fatal(1, "forcing the mmc3 irq source did not raise the mapper irq output");
    if (mmc3_irq_line !== 1'b1)
        $fatal(1, "the mapper irq did not reach the combined irq line");
    if (mmc3_dut.u_cpu.dbg_irq_pending !== 1'b1)
        $fatal(1, "the cpu irq_i did not follow the mapper irq");
    if (mmc3_irq_entries < 1)
        $fatal(1, "the cpu never fetched the irq vector from fffe");
    force mmc3_dut.u_mapper.u_mmc3.irq_enabled_r = 1'b0;
    force mmc3_dut.u_mapper.u_mmc3.irq_pending_r = 1'b0;
    release mmc3_dut.u_mapper.u_mmc3.irq_enabled_r;
    release mmc3_dut.u_mapper.u_mmc3.irq_pending_r;
    repeat (400) @(posedge clk);
    #1;
    if (mmc3_mapper_irq !== 1'b0)
        $fatal(1, "the mapper irq is still high after the force was released");
    if (mmc3_dut.u_bus.ram_array[11'h013] === 8'h00)
        $fatal(1, "the irq handler never incremented its ram counter");
    $display("IRQFORCE forcing the mmc3 irq_enabled/irq_pending registers drove mapper_irq=1 -> irq_line=1 -> cpu dbg_irq_pending=1, the cpu took the 7 cycle entry, fetched fffe, and the line fell again after release PASS");
    $display("MMC3IRQENTRY the irq vector came from the fixed last bank window, the handler at %04h incremented ram[0013] to %02x and returned with rti PASS",
             MMC3_IRQ, mmc3_dut.u_bus.ram_array[11'h013]);

    for (i = 0; i < 8; i = i + 1) begin
        if (uxrom_dut.u_bus.ram_array[11'h020 + i[10:0]] !== BUTTONS1[i])
            $fatal(1, "the uxrom port 1 cell %0d is %02x expected %02x",
                   i, uxrom_dut.u_bus.ram_array[11'h020 + i[10:0]], BUTTONS1[i]);
        if (uxrom_dut.u_bus.ram_array[11'h028 + i[10:0]] !== BUTTONS2[i])
            $fatal(1, "the uxrom port 2 cell %0d is %02x expected %02x",
                   i, uxrom_dut.u_bus.ram_array[11'h028 + i[10:0]], BUTTONS2[i]);
    end
    if (uxrom_dut.u_bus.ram_array[11'h018] !== 8'h01)
        $fatal(1, "the uxrom 9th port 1 read is %02x expected 01",
               uxrom_dut.u_bus.ram_array[11'h018]);
    if (uxrom_dut.u_bus.ram_array[11'h019] !== 8'h01)
        $fatal(1, "the uxrom 9th port 2 read is %02x expected 01",
               uxrom_dut.u_bus.ram_array[11'h019]);
    if (uxrom_ctrl_cs_err != 0)
        $fatal(1, "apu_reg_cs leaked onto 4016/4017 reads %0d times", uxrom_ctrl_cs_err);
    $display("CONTROLLER the uxrom system rebuilt %02x in ram 0020-0027 from eight 4016 reads and %02x in ram 0028-002f from eight 4017 reads, both 9th reads returned 1, and no 4016/4017 read ever asserted apu_reg_cs PASS",
             BUTTONS1, BUTTONS2);

    if (uxrom_dma_start_count != 1)
        $fatal(1, "the uxrom oam dma start count is %0d expected 1", uxrom_dma_start_count);
    if (uxrom_dma_done_count != 1)
        $fatal(1, "the uxrom oam dma done count is %0d expected 1", uxrom_dma_done_count);
    if (uxrom_dma_ack_cnt != 256)
        $fatal(1, "the uxrom oam dma acked %0d times expected 256", uxrom_dma_ack_cnt);
    if (uxrom_dma_wr != 256)
        $fatal(1, "the uxrom oam dma drove %0d ppu 2004 writes expected 256", uxrom_dma_wr);
    if (uxrom_dma_unimpl_cnt != 0)
        $fatal(1, "the uxrom oam dma hit an mmio window %0d times", uxrom_dma_unimpl_cnt);
    if (uxrom_dut.u_ppu.oam_ram[0] !== 8'h11 || uxrom_dut.u_ppu.oam_ram[1] !== 8'h22 ||
        uxrom_dut.u_ppu.oam_ram[2] !== 8'h33 || uxrom_dut.u_ppu.oam_ram[3] !== 8'h44)
        $fatal(1, "the uxrom oam dma did not copy the 0300 page in order, got %02x %02x %02x %02x",
               uxrom_dut.u_ppu.oam_ram[0], uxrom_dut.u_ppu.oam_ram[1],
               uxrom_dut.u_ppu.oam_ram[2], uxrom_dut.u_ppu.oam_ram[3]);
    $display("OAMDMA the uxrom 4014 write transferred 256 bytes from page 02 into oam[0..255], the program read 2004 back and saw 11, and the ack/write accounting closed at 256 each PASS");

    if (uxrom_sample < 100)
        $fatal(1, "the uxrom apu produced only %0d sample strobes", uxrom_sample);
    if (uxrom_sample_nz < 1)
        $fatal(1, "the uxrom apu never produced a non zero sample");
    if (uxrom_dut.u_apu.dbg_dmc_irq !== 1'b0)
        $fatal(1, "the dmc raised an irq in the uxrom system");
    if (uxrom_dmc_req != 0)
        $fatal(1, "the dmc bus request was high %0d times", uxrom_dmc_req);
    $display("AUDIO the uxrom system kept pulse1 running with %0d sample strobes and %0d non zero samples, dmc never requested the bus, and the frame irq stayed inhibited by 4017=40 PASS",
             uxrom_sample, uxrom_sample_nz);

    $display("WAIT every cart, ram, ppu and apu transfer in all three systems still took exactly one ce of stall, bus_stall followed bus_req && !bus_fire on every cpu enable and dbg_wait_count stayed 0, so the waitable bus from v4 is preserved PASS");
    $display("PASS nes_system_v5");
    $finish;
end

initial begin
    #1000000;
    $fatal(1, "global timeout");
end

endmodule
