`timescale 1ns/1ps

module tb_nes_system_v3;

localparam PRG_SIZE_BYTES = 16384;
localparam PRG_INDEX_BITS = $clog2(PRG_SIZE_BYTES);
localparam [15:0] NMI_HANDLER = 16'h8400;
localparam [15:0] IRQ_HANDLER = 16'h8500;
localparam [15:0] INIT_ROUTINE = 16'h8600;
localparam [15:0] FAIL_LOOP = 16'h8800;
localparam [15:0] TABLE1_ADDR = 16'h8900;
localparam [15:0] TABLE2_ADDR = 16'h8A00;
localparam [15:0] MAIN_PROG = 16'h8000;
localparam [15:0] NMI_COUNTER_CELL = 16'h0010;
localparam [15:0] IRQ_COUNTER_CELL = 16'h0011;
localparam [15:0] SETUP_FLAG_CELL = 16'h0012;
localparam [15:0] DMA1_FLAG_CELL = 16'h0013;
localparam [15:0] DMA2_FLAG_CELL = 16'h0014;
localparam [15:0] DMA3_FLAG_CELL = 16'h0015;
localparam [15:0] OAM_RB_FLAG_CELL = 16'h0016;
localparam [15:0] OPEN_BUS_CELL = 16'h0017;
localparam [2:0] OWNER_RAM = 3'd1;
localparam [2:0] OWNER_PPU = 3'd2;
localparam [2:0] OWNER_APU_IO = 3'd3;
localparam integer FRAME_TARGET = 4;

reg clk;
reg reset;

wire pixel_valid;
wire [7:0] pixel_x;
wire [7:0] pixel_y;
wire [3:0] pixel_index;
wire frame_done;
wire vblank;
wire nmi_o;
wire apu_irq_o;
wire audio_sample_valid;
wire [15:0] audio_sample_left;
wire [15:0] audio_sample_right;
wire [31:0] cpu_cycle;
wire [8:0] ppu_dot;
wire [8:0] ppu_scanline;
wire [2:0] bus_owner;
wire bus_active;
wire [7:0] bus_wait_count;
wire bus_req;
wire bus_stall;
wire bus_fire;
wire [15:0] bus_addr;
wire bus_we;
wire [7:0] bus_dout;
wire [7:0] bus_din;
wire sel_ram;
wire sel_ppu;
wire sel_apu_io;
wire sel_open_bus;
wire sel_cart_ram;
wire sel_cart_rom;
wire ram_we;
wire ppu_reg_cs;
wire ppu_reg_we;
wire [2:0] ppu_reg_addr;
wire apu_reg_cs;
wire apu_reg_we;
wire [4:0] apu_reg_addr;
wire cart_req;
wire cart_xfer;
wire [15:0] cart_addr;
wire [7:0] cart_din;
wire cart_ack;
wire bus_hold;
wire oam_dma_start;
wire oam_dma_cpu_hold;
wire oam_dma_cpu_read_req;
wire [15:0] oam_dma_cpu_read_addr;
wire oam_dma_cpu_read_ack;
wire [7:0] oam_dma_cpu_rdata;
wire oam_dma_ppu_reg_cs;
wire oam_dma_ppu_reg_we;
wire [2:0] oam_dma_ppu_reg_addr;
wire [7:0] oam_dma_ppu_reg_dout;
wire oam_dma_busy;
wire oam_dma_done;
wire [7:0] oam_dma_page;
wire [7:0] oam_dma_page_latch;
wire [7:0] oam_dma_base_addr;
wire [7:0] oam_dma_cur_addr;
wire [7:0] oam_dma_index;
wire [1:0] oam_dma_align_left;
wire oam_dma_addr_wr;
wire [15:0] oam_dma_cycle_count;
wire apu_dmc_bus_req;
wire [15:0] apu_dmc_addr;
wire apu_dmc_ack;
wire [7:0] apu_dmc_rdata;
wire dma_sel;
wire dma_ack;
wire [7:0] dma_din;
wire dma_wait;
wire dma_active;
wire dma_unimpl;
wire [1:0] dma_owner;
wire ppu_port_cs;
wire ppu_port_we;
wire [2:0] ppu_port_addr;
wire [7:0] ppu_port_din;

integer i;
integer k;

reg [7:0] table1 [0:255];
reg [7:0] table2 [0:255];
reg [7:0] oam_snap [0:2][0:255];

reg [7:0] xfer_page [0:7];
reg [7:0] xfer_base [0:7];
reg [15:0] xfer_acks [0:7];
reg [15:0] xfer_ce [0:7];
reg [15:0] xfer_clk [0:7];
reg [15:0] xfer_align [0:7];
integer xfer_count;

integer bus_fire_count;
integer stall_cycles;
integer transfer_stall_expect;
integer transfer_had_stall;
integer immediate_count;
integer prg_rd;
integer ram_rd;
integer ram_wr;
integer ppu_rd;
integer ppu_rd_oamdata;
integer ppu_wr;
integer apu_rd;
integer apu_wr;
integer open_rd;
integer cartram_rd;
integer cartram_wr;
integer prg_wr;
integer ppu_wr_ctrl;
integer ppu_wr_mask;
integer ppu_wr_status;
integer ppu_wr_oamaddr;
integer ppu_wr_oamdata;
integer ppu_wr_vaddr;
integer ppu_wr_vdata;
integer ppu_wr_other;
integer apu_wr_p1;
integer apu_wr_p1b;
integer apu_wr_p1c;
integer apu_wr_p1d;
integer apu_wr_status;
integer apu_wr_frame;
integer apu_wr_dma;
integer apu_wr_other;
integer apu_rd_4015;
integer apu_rd_other;
integer ram_wr_nmi;
integer ram_wr_irq;
integer ram_wr_setup;
integer ram_wr_dma1;
integer ram_wr_dma2;
integer ram_wr_dma3;
integer ram_wr_oamrb;
integer ram_wr_open;
integer jsr_frame;
integer stk_rd [0:15];
integer stk_wr [0:15];
integer hk;

integer dma_ack_count;
integer dma_wr_count;
integer dma_byte_index;
integer dma_start_count;
integer dma_transfer_ce;
integer dma_transfer_clk;
integer dma_addr_err;
integer dma_data_err;
integer dma_wr_order_err;
integer dma_ack_together;
integer dma_ppu_conflict;
integer dma_ack_no_hold;
integer dma_ack_with_cpu;
integer dma_req_pending_err;
integer dma_active_err;
integer dma_freeze_fail;
integer dma_ppu_cs_err;
integer dma_apu_cs_err;
integer dma_fire_err;
integer dma_req_err;
integer dma_dmc_seen;
integer dma_unimpl_seen;
integer dma_index_err;
integer dma_shadow_err;
integer dma_cur_addr_err;
integer addr_wr_seen;
integer dmc_req_seen;
integer port_cs_err;
integer done_count;
integer expect_dma_data;
integer expect_dma_data_valid;
integer dma_wr_index;
reg [7:0] dma_exp_rdata;
reg [15:0] dma_exp_addr;

integer frame_count;
integer clk_count;
integer frame_mark;
integer frame_delta;
integer have_frame_mark;
integer prev_vblank;
integer vblank_rise;
integer vblank_fall;
integer check_enable;
integer checked_bg;
integer checked_tile1;
integer checked_sprite;
integer visible_pixels;

integer nmi_rise_count;
integer irq_rise_count;
integer irq_fall_count;
integer nmi_entry_count;
integer irq_entry_count;
integer sample_strobes;
integer sample_nonzero;
integer sample_peak;
integer ce_pulses;
integer handler_ce;
integer handler_strobes;
integer illegal_hits;
integer snapshot_pending;
integer snapshot_slot;
integer dma_done_clks;

reg [7:0] prev_xfer_din;
reg [15:0] prev_xfer_addr;
reg prev_xfer_valid;
reg [7:0] last_irq_flag;
reg saw_reset_lo;
reg saw_reset_hi;
reg saw_first_fetch;
reg saw_first_opcode;
reg saw_fetch_bus;
reg in_nmi_handler;
reg in_irq_handler;
reg in_init_routine;
reg in_handler;
reg seen_main_loop;
reg ppu_cs_in_irq;
reg apu_cs_other_in_nmi;
reg prev_ppu_cs;
reg prev_apu_cs;
reg prev_dma_ack;
reg prev_dma_ppu_cs;
reg prev_busy;
reg dma_active_seen;
reg last_nmi_level;
reg prev_frame_done;
reg [15:0] reset_lo_addr;
reg [15:0] reset_hi_addr;
reg [6:0] freeze_state;
reg [15:0] freeze_pc;
reg freeze_valid;
reg bus_ce_active_snap;
reg [7:0] bus_ce_wait_snap;
reg [8:0] prev_dot;
reg expected_vblank;
reg [3:0] expected_index;
reg [15:0] main_prog_end;
reg [15:0] nmi_end;
reg [15:0] irq_end;
reg [15:0] init_end;
reg [15:0] probe_opcode_addr;
reg [15:0] probe_cmp_addr;
reg [7:0] probe_opcode;
reg [15:0] bne_list [0:15];
integer bne_count;

nes_system_v3 dut (
    .clk(clk),
    .reset(reset),
    .pixel_valid(pixel_valid),
    .pixel_x(pixel_x),
    .pixel_y(pixel_y),
    .pixel_index(pixel_index),
    .frame_done(frame_done),
    .vblank(vblank),
    .nmi_o(nmi_o),
    .apu_irq_o(apu_irq_o),
    .audio_sample_valid(audio_sample_valid),
    .audio_sample_left(audio_sample_left),
    .audio_sample_right(audio_sample_right),
    .cpu_cycle(cpu_cycle),
    .ppu_dot(ppu_dot),
    .ppu_scanline(ppu_scanline),
    .bus_owner(bus_owner),
    .bus_active(bus_active),
    .bus_wait_count(bus_wait_count),
    .bus_req(bus_req),
    .bus_stall(bus_stall),
    .bus_fire(bus_fire),
    .bus_addr(bus_addr),
    .bus_we(bus_we),
    .bus_dout(bus_dout),
    .bus_din(bus_din),
    .sel_ram(sel_ram),
    .sel_ppu(sel_ppu),
    .sel_apu_io(sel_apu_io),
    .sel_open_bus(sel_open_bus),
    .sel_cart_ram(sel_cart_ram),
    .sel_cart_rom(sel_cart_rom),
    .ram_we(ram_we),
    .ppu_reg_cs(ppu_reg_cs),
    .ppu_reg_we(ppu_reg_we),
    .ppu_reg_addr(ppu_reg_addr),
    .apu_reg_cs(apu_reg_cs),
    .apu_reg_we(apu_reg_we),
    .apu_reg_addr(apu_reg_addr),
    .cart_req(cart_req),
    .cart_xfer(cart_xfer),
    .cart_addr(cart_addr),
    .cart_din(cart_din),
    .cart_ack(cart_ack),
    .bus_hold(bus_hold),
    .oam_dma_start(oam_dma_start),
    .oam_dma_cpu_hold(oam_dma_cpu_hold),
    .oam_dma_cpu_read_req(oam_dma_cpu_read_req),
    .oam_dma_cpu_read_addr(oam_dma_cpu_read_addr),
    .oam_dma_cpu_read_ack(oam_dma_cpu_read_ack),
    .oam_dma_cpu_rdata(oam_dma_cpu_rdata),
    .oam_dma_ppu_reg_cs(oam_dma_ppu_reg_cs),
    .oam_dma_ppu_reg_we(oam_dma_ppu_reg_we),
    .oam_dma_ppu_reg_addr(oam_dma_ppu_reg_addr),
    .oam_dma_ppu_reg_dout(oam_dma_ppu_reg_dout),
    .oam_dma_busy(oam_dma_busy),
    .oam_dma_done(oam_dma_done),
    .oam_dma_page(oam_dma_page),
    .oam_dma_page_latch(oam_dma_page_latch),
    .oam_dma_base_addr(oam_dma_base_addr),
    .oam_dma_cur_addr(oam_dma_cur_addr),
    .oam_dma_index(oam_dma_index),
    .oam_dma_align_left(oam_dma_align_left),
    .oam_dma_addr_wr(oam_dma_addr_wr),
    .oam_dma_cycle_count(oam_dma_cycle_count),
    .apu_dmc_bus_req(apu_dmc_bus_req),
    .apu_dmc_addr(apu_dmc_addr),
    .apu_dmc_ack(apu_dmc_ack),
    .apu_dmc_rdata(apu_dmc_rdata),
    .dma_sel(dma_sel),
    .dma_ack(dma_ack),
    .dma_din(dma_din),
    .dma_wait(dma_wait),
    .dma_active(dma_active),
    .dma_unimpl(dma_unimpl),
    .dma_owner(dma_owner),
    .ppu_port_cs(ppu_port_cs),
    .ppu_port_we(ppu_port_we),
    .ppu_port_addr(ppu_port_addr),
    .ppu_port_din(ppu_port_din)
);

always #5 clk = !clk;

reg [15:0] pc;
reg [15:0] branch_patch_addr;

task emit;
    input [7:0] value;
    begin
        dut.prg_rom[pc[PRG_INDEX_BITS-1:0]] = value;
        pc = pc + 16'd1;
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

task jsr_abs;
    input [15:0] address;
    begin
        emit(8'h20);
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
    integer n;
    begin
        for (n = 0; n < bne_count; n = n + 1)
            dut.prg_rom[bne_list[n][PRG_INDEX_BITS-1:0]] =
                target - (bne_list[n] + 16'd1);
        bne_count = 0;
    end
endtask

task bne_list_save;
    input integer slot;
    begin
        bne_list[16 + slot] = pc;
    end
endtask

task bne_list_load;
    begin
        emit(8'hD0);
        branch_patch_addr = pc;
        emit(8'h00);
    end
endtask

task patch_bne;
    input [15:0] target;
    begin
        dut.prg_rom[branch_patch_addr[PRG_INDEX_BITS-1:0]] =
            target - (branch_patch_addr + 16'd1);
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

task ppu_fill8;
    input [7:0] value;
    reg [15:0] top;
    begin
        ldx_imm(8'h08);
        lda_imm(value);
        top = pc;
        sta_abs(16'h2007);
        emit(8'hCA);
        bne_to(top);
    end
endtask

task build_main;
    reg [15:0] fail_jump;
    reg [15:0] self_loop;
    begin
        pc = MAIN_PROG;
        emit(8'h58);
        lda_imm(8'h00);
        sta_abs(NMI_COUNTER_CELL);
        lda_imm(8'h00);
        sta_abs(IRQ_COUNTER_CELL);
        lda_imm(8'h00);
        sta_abs(SETUP_FLAG_CELL);
        lda_imm(8'h00);
        sta_abs(DMA1_FLAG_CELL);
        lda_imm(8'h00);
        sta_abs(DMA2_FLAG_CELL);
        lda_imm(8'h00);
        sta_abs(DMA3_FLAG_CELL);
        lda_imm(8'h00);
        sta_abs(OAM_RB_FLAG_CELL);
        lda_imm(8'h00);
        sta_abs(OPEN_BUS_CELL);
        lda_imm(8'h00);
        sta_abs(16'h2000);
        lda_imm(8'h00);
        sta_abs(16'h2001);
        lda_imm(8'h00);
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
        lda_abs(16'h8400);
        cmp_imm(8'hAD);
        bne_list_add;
        lda_abs(16'h6010);
        cmp_imm(8'h00);
        bne_list_add;
        probe_opcode_addr = pc;
        lda_abs(16'h4020);
        sta_abs(OPEN_BUS_CELL);
        emit(8'hC9);
        probe_cmp_addr = pc;
        emit(8'h00);
        bne_list_add;
        lda_imm(8'h80);
        sta_abs(16'h2000);
        self_loop = pc;
        jmp_abs(self_loop);
        fail_jump = pc;
        jmp_abs(FAIL_LOOP);
        main_prog_end = pc;
        bne_list_patch(fail_jump);
        probe_opcode = dut.prg_rom[(probe_opcode_addr + 16'd2) & (PRG_SIZE_BYTES-1)];
        dut.prg_rom[probe_cmp_addr[PRG_INDEX_BITS-1:0]] = probe_opcode;
    end
endtask

task build_nmi_handler;
    reg [15:0] count_part;
    begin
        pc = NMI_HANDLER;
        lda_abs(SETUP_FLAG_CELL);
        cmp_imm(8'h00);
        bne_list_load;
        lda_imm(8'h01);
        sta_abs(SETUP_FLAG_CELL);
        jsr_abs(INIT_ROUTINE);
        count_part = pc;
        patch_bne(count_part);
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

task build_init_routine;
    reg [15:0] top1;
    reg [15:0] top2;
    reg [15:0] fail_jump;
    begin
        pc = INIT_ROUTINE;
        ldx_imm(8'h00);
        top1 = pc;
        lda_abs_x(TABLE1_ADDR);
        sta_abs_x(16'h0200);
        emit(8'hE8);
        bne_to(top1);
        ldx_imm(8'h00);
        top2 = pc;
        lda_abs_x(TABLE2_ADDR);
        sta_abs_x(16'h0500);
        emit(8'hE8);
        bne_to(top2);
        ppu_set_addr(16'h0000);
        ppu_fill8(8'hFF);
        ppu_set_addr(16'h0010);
        ppu_fill8(8'h00);
        ppu_set_addr(16'h0018);
        ppu_fill8(8'hFF);
        ppu_set_addr(16'h0020);
        ppu_fill8(8'hFF);
        ppu_set_addr(16'h0028);
        ppu_fill8(8'h00);
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
        sta_abs(DMA1_FLAG_CELL);
        lda_abs(16'h2004);
        cmp_imm(8'h20);
        bne_list_add;
        lda_imm(8'h01);
        sta_abs(OAM_RB_FLAG_CELL);
        lda_imm(8'hF0);
        sta_abs(16'h2003);
        lda_imm(8'h05);
        sta_abs(16'h4014);
        lda_imm(8'h02);
        sta_abs(DMA2_FLAG_CELL);
        lda_abs(16'h2004);
        cmp_imm(8'hA0);
        bne_list_add;
        lda_imm(8'h00);
        sta_abs(16'h2003);
        lda_imm(8'h02);
        sta_abs(16'h4014);
        lda_imm(8'h03);
        sta_abs(DMA3_FLAG_CELL);
        lda_imm(8'h1E);
        sta_abs(16'h2001);
        emit(8'h60);
        fail_jump = pc;
        jmp_abs(FAIL_LOOP);
        init_end = pc;
        bne_list_patch(fail_jump);
    end
endtask

task build_fail_loop;
    begin
        pc = FAIL_LOOP;
        jmp_abs(FAIL_LOOP);
    end
endtask

task build_vectors;
    begin
        dut.prg_rom[16'hFFFA & (PRG_SIZE_BYTES-1)] = NMI_HANDLER[7:0];
        dut.prg_rom[16'hFFFB & (PRG_SIZE_BYTES-1)] = NMI_HANDLER[15:8];
        dut.prg_rom[16'hFFFC & (PRG_SIZE_BYTES-1)] = MAIN_PROG[7:0];
        dut.prg_rom[16'hFFFD & (PRG_SIZE_BYTES-1)] = MAIN_PROG[15:8];
        dut.prg_rom[16'hFFFE & (PRG_SIZE_BYTES-1)] = IRQ_HANDLER[7:0];
        dut.prg_rom[16'hFFFF & (PRG_SIZE_BYTES-1)] = IRQ_HANDLER[15:8];
    end
endtask

task build_tables;
    integer n;
    begin
        table1[0] = 8'h20;
        table1[1] = 8'h02;
        table1[2] = 8'h00;
        table1[3] = 8'h08;
        table2[0] = 8'hA0;
        table2[1] = 8'h03;
        table2[2] = 8'h01;
        table2[3] = 8'h10;
        for (n = 4; n < 256; n = n + 1) begin
            if (n[0] == 1'b0) begin
                table1[n] = 8'hF0 | ((n >> 1) & 8'h0F);
                table2[n] = 8'hF0 | ((n >> 1) & 8'h0F);
            end else begin
                table1[n] = (n * 5 + 17) & 8'hFF;
                table2[n] = (n * 3 + 39) & 8'hFF;
            end
        end
        for (n = 0; n < 256; n = n + 1) begin
            dut.prg_rom[TABLE1_ADDR[PRG_INDEX_BITS-1:0] + n] = table1[n];
            dut.prg_rom[TABLE2_ADDR[PRG_INDEX_BITS-1:0] + n] = table2[n];
        end
    end
endtask

task load_video_ram;
    begin
        for (i = 0; i < 8192; i = i + 1)
            dut.u_ppu.chr_ram[i] = 8'h00;
        for (i = 0; i < 2048; i = i + 1)
            dut.u_ppu.nametable_ram[i] = 8'h00;
        for (i = 0; i < 32; i = i + 1)
            dut.u_ppu.palette_ram[i] = 8'h00;
        for (i = 0; i < 256; i = i + 1)
            dut.u_ppu.oam_ram[i] = 8'hFF;
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

task check_reset_state;
    begin
        if (ppu_scanline !== 9'd0 || ppu_dot !== 9'd0)
            $fatal(1, "ppu counter did not start at 0:0, got %0d:%0d",
                   ppu_scanline, ppu_dot);
        if (frame_done !== 1'b0)
            $fatal(1, "frame_done is high during reset");
        if (vblank !== 1'b0)
            $fatal(1, "vblank is high during reset");
        if (nmi_o !== 1'b0)
            $fatal(1, "nmi_o is high during reset");
        if (apu_irq_o !== 1'b0)
            $fatal(1, "apu_irq_o is high during reset");
        if (audio_sample_valid !== 1'b0)
            $fatal(1, "audio_sample_valid is high during reset");
        if (bus_active !== 1'b0)
            $fatal(1, "bus active flag did not reset, got %b wait=%0d",
                   bus_active, bus_wait_count);
        if (bus_req !== 1'b0)
            $fatal(1, "bus_req is high during reset");
        if (bus_fire !== 1'b0)
            $fatal(1, "bus_fire is high during reset");
        if (bus_hold !== 1'b0)
            $fatal(1, "bus_hold is high during reset");
        if (oam_dma_busy !== 1'b0)
            $fatal(1, "oam_dma_busy is high during reset");
        if (oam_dma_cpu_hold !== 1'b0)
            $fatal(1, "oam_dma_cpu_hold is high during reset");
        if (dma_ack !== 1'b0)
            $fatal(1, "dma_ack is high during reset");
        if (apu_dmc_bus_req !== 1'b0)
            $fatal(1, "apu_dmc_bus_req is high during reset");
        if (dut.u_cpu.dbg_state !== 7'd0)
            $fatal(1, "cpu state is %0d during reset", dut.u_cpu.dbg_state);
        if (dut.u_ppu.mask_reg !== 8'h00)
            $fatal(1, "ppumask is %02h during reset", dut.u_ppu.mask_reg);
        if (dut.u_ppu.oam_addr_reg !== 8'h00)
            $fatal(1, "ppu oamaddr is %02h during reset", dut.u_ppu.oam_addr_reg);
        if (dut.oam_addr_q !== 8'h00)
            $fatal(1, "oamaddr shadow is %02h during reset", dut.oam_addr_q);
        if (dut.oam_dma_page_q !== 8'h00)
            $fatal(1, "oam dma page latch is %02h during reset", dut.oam_dma_page_q);
        if (dut.u_apu.dbg_frame_count !== 16'd0)
            $fatal(1, "apu frame count is %0d during reset", dut.u_apu.dbg_frame_count);
        $display("RESET ppu=0:0 oamaddr=0 frame/vblank/nmi/irq/sample low, bus idle, bus_hold=0, dma idle PASS");
    end
endtask

task check_cpu_reset_sequence;
    begin
        if (!saw_reset_lo || !saw_reset_hi || !saw_first_fetch || !saw_first_opcode)
            $fatal(1, "cpu reset sequence incomplete lo=%b hi=%b fetch=%b opcode=%b",
                   saw_reset_lo, saw_reset_hi, saw_first_fetch, saw_first_opcode);
        if (reset_lo_addr !== 16'hFFFC)
            $fatal(1, "reset vector low address got %04h", reset_lo_addr);
        if (reset_hi_addr !== 16'hFFFD)
            $fatal(1, "reset vector high address got %04h", reset_hi_addr);
        if (illegal_hits != 0)
            $fatal(1, "cpu decoded %0d illegal opcodes", illegal_hits);
        $display("CPU reset FFFC/FFFD -> PC=8000 first opcode=58, illegal opcodes=0 PASS");
    end
endtask

task check_wait_path;
    begin
        if (bus_fire_count < 1000)
            $fatal(1, "only %0d bus transfers completed", bus_fire_count);
        // CONTRACT CHANGE, 2x cpu rate: this used to be compared against the open
        // bus read count, i.e. only the open bus window was allowed to complete
        // without a stall.  Every transfer completes immediately now.
        if (immediate_count != bus_fire_count)
            $fatal(1, "immediate completions %0d do not match completed transfers %0d",
                   immediate_count, bus_fire_count);
        if (bus_wait_count != 8'd0)
            $fatal(1, "the forced wait counter is %0d, READ_WAIT_CYCLES must be 1",
                   bus_wait_count);
        $display("WAIT CONTRACT CHANGED WITH THE 2x CPU RATE FIX: every owner, open bus included, now completes on the first ce_cpu beat of its request, dbg_wait_count stayed 0 and bus_active is low on every completing cycle.  Before this change every owner except the open bus window was REQUIRED to spend a second ce_cpu beat stalling");
        $display("WAIT cpu transfers=%0d stalled=%0d immediate=%0d (all of them, on every owner) PASS",
                 bus_fire_count, bus_fire_count - immediate_count, immediate_count);
    end
endtask

task check_owner_accounting;
    begin
        if (prg_rd + ram_rd + ram_wr + ppu_rd + ppu_wr + apu_rd + apu_wr +
            open_rd + cartram_rd + prg_wr != bus_fire_count)
            $fatal(1, "bus cycle accounting does not close: prg_rd=%0d ram_rd=%0d ram_wr=%0d ppu_rd=%0d ppu_wr=%0d apu_rd=%0d apu_wr=%0d open_rd=%0d cartram_rd=%0d prg_wr=%0d total=%0d of %0d",
                   prg_rd, ram_rd, ram_wr, ppu_rd, ppu_wr, apu_rd, apu_wr,
                   open_rd, cartram_rd, prg_wr,
                   prg_rd + ram_rd + ram_wr + ppu_rd + ppu_wr + apu_rd + apu_wr +
                   open_rd + cartram_rd + prg_wr, bus_fire_count);
        if (open_rd != 1)
            $fatal(1, "open bus read count got %0d expected 1", open_rd);
        if (cartram_rd != 1)
            $fatal(1, "cart ram window read count got %0d expected 1", cartram_rd);
        if (dut.u_bus.ram_array[OPEN_BUS_CELL[10:0]] !== probe_opcode)
            $fatal(1, "the open bus cell is %02x expected %02x",
                   dut.u_bus.ram_array[OPEN_BUS_CELL[10:0]], probe_opcode);
        $display("BUS owner accounting prg_rd=%0d ram_rd=%0d ram_wr=%0d ppu_rd=%0d ppu_wr=%0d apu_rd=%0d apu_wr=%0d open_rd=%0d cartram_rd=%0d prg_wr=%0d, $4020 returned the sticky bus value %02x PASS",
                 prg_rd, ram_rd, ram_wr, ppu_rd, ppu_wr, apu_rd, apu_wr,
                 open_rd, cartram_rd, prg_wr, probe_opcode);
    end
endtask

task check_ppu_registers;
    begin
        if (ppu_wr_ctrl != 2)
            $fatal(1, "ppuctrl write count got %0d expected 2", ppu_wr_ctrl);
        if (ppu_wr_mask != 2)
            $fatal(1, "ppumask write count got %0d expected 2", ppu_wr_mask);
        if (ppu_wr_status != 0)
            $fatal(1, "ppustatus was written %0d times", ppu_wr_status);
        if (ppu_wr_oamaddr != 3)
            $fatal(1, "oamaddr write count got %0d expected 3", ppu_wr_oamaddr);
        if (ppu_wr_oamdata != 0)
            $fatal(1, "the cpu wrote oamdata %0d times, the dma owns $2004",
                   ppu_wr_oamdata);
        if (ppu_wr_vaddr != 18)
            $fatal(1, "ppuaddr write count got %0d expected 18", ppu_wr_vaddr);
        if (ppu_wr_vdata != 45)
            $fatal(1, "ppudata write count got %0d expected 45", ppu_wr_vdata);
        if (ppu_wr_other != 0)
            $fatal(1, "unexpected writes to other ppu registers: %0d", ppu_wr_other);
        if (ppu_rd != 2)
            $fatal(1, "the system performed %0d ppu register reads, expected 2", ppu_rd);
        if (ppu_rd_oamdata != 2)
            $fatal(1, "oamdata read count got %0d expected 2", ppu_rd_oamdata);
        if (ppu_cs_in_irq)
            $fatal(1, "a ppu register transfer happened inside the irq handler");
        $display("PPUREG writes ctrl=%0d mask=%0d vaddr=%0d vdata=%0d oamaddr=%0d oamdata=%0d status=%0d other=%0d, cpu reads oamdata=%0d, the cpu never drives $2004, no ppu access inside the irq handler PASS",
                 ppu_wr_ctrl, ppu_wr_mask, ppu_wr_vaddr, ppu_wr_vdata,
                 ppu_wr_oamaddr, ppu_wr_oamdata, ppu_wr_status, ppu_wr_other,
                 ppu_rd_oamdata);
    end
endtask

task check_apu_registers;
    begin
        if (apu_wr_p1 != 1 || apu_wr_p1b != 1 || apu_wr_p1c != 1 || apu_wr_p1d != 1)
            $fatal(1, "pulse1 register write counts got %0d/%0d/%0d/%0d expected 1 each",
                   apu_wr_p1, apu_wr_p1b, apu_wr_p1c, apu_wr_p1d);
        if (apu_wr_frame != 1)
            $fatal(1, "apu $4017 write count got %0d expected 1", apu_wr_frame);
        if (apu_wr_dma != 3)
            $fatal(1, "apu $4014 write count got %0d expected 3", apu_wr_dma);
        if (apu_wr_status != (1 + irq_entry_count))
            $fatal(1, "apu $4015 write count got %0d expected %0d",
                   apu_wr_status, 1 + irq_entry_count);
        if (apu_rd_4015 != irq_entry_count)
            $fatal(1, "apu $4015 read count got %0d expected %0d",
                   apu_rd_4015, irq_entry_count);
        if (apu_wr_other != 0 || apu_rd_other != 0)
            $fatal(1, "unexpected apu transfers: wr=%0d rd=%0d",
                   apu_wr_other, apu_rd_other);
        if (apu_cs_other_in_nmi)
            $fatal(1, "an apu register other than $4014 was written inside the nmi handler");
        $display("APUREG writes $4000-$4003=1 each, $4017=1, $4014=3 (oam dma triggers), $4015=%0d, reads $4015=%0d, $4014 writes are the only apu access inside the nmi handler PASS",
                 apu_wr_status, apu_rd_4015);
    end
endtask

task check_interrupts;
    begin
        if (nmi_rise_count < 1)
            $fatal(1, "no nmi edge was seen");
        if (irq_rise_count < 1)
            $fatal(1, "no apu frame irq edge was seen");
        if (irq_rise_count != irq_fall_count)
            $fatal(1, "irq rises %0d do not match falls %0d", irq_rise_count, irq_fall_count);
        if (nmi_rise_count != nmi_entry_count)
            $fatal(1, "nmi edges %0d do not match handler entries %0d",
                   nmi_rise_count, nmi_entry_count);
        if (irq_rise_count != irq_entry_count)
            $fatal(1, "irq edges %0d do not match handler entries %0d",
                   irq_rise_count, irq_entry_count);
        if (dut.u_bus.ram_array[NMI_COUNTER_CELL[10:0]] !== nmi_entry_count[7:0])
            $fatal(1, "nmi counter cell is %02x expected %0d",
                   dut.u_bus.ram_array[NMI_COUNTER_CELL[10:0]], nmi_entry_count);
        if (dut.u_bus.ram_array[IRQ_COUNTER_CELL[10:0]] !== irq_entry_count[7:0])
            $fatal(1, "irq counter cell is %02x expected %0d",
                   dut.u_bus.ram_array[IRQ_COUNTER_CELL[10:0]], irq_entry_count);
        if (jsr_frame != 1)
            $fatal(1, "the init routine was entered %0d times, expected once", jsr_frame);
        if (apu_irq_o !== 1'b0)
            $fatal(1, "apu_irq_o is still high at the end, the handler never acked");
        if (dut.u_cpu.dbg_nmi_pending !== 1'b0)
            $fatal(1, "nmi is still pending at the end");
        if (apu_irq_o !== dut.u_cpu.dbg_irq_pending)
            $fatal(1, "dbg_irq_pending does not follow apu_irq_o");
        $display("IRQ nmi rises=%0d entries=%0d ram[0010]=%02x, apu irq rises=%0d falls=%0d entries=%0d ram[0011]=%02x, the oam dma ran inside the nmi handler PASS",
                 nmi_rise_count, nmi_entry_count,
                 dut.u_bus.ram_array[NMI_COUNTER_CELL[10:0]],
                 irq_rise_count, irq_fall_count, irq_entry_count,
                 dut.u_bus.ram_array[IRQ_COUNTER_CELL[10:0]]);
    end
endtask

task check_audio;
    begin
        if (sample_strobes != ce_pulses)
            $fatal(1, "sample strobes %0d do not match ce pulses %0d",
                   sample_strobes, ce_pulses);
        if (sample_nonzero < 1)
            $fatal(1, "pulse1 never produced a non zero sample");
        if (handler_strobes != handler_ce)
            $fatal(1, "sample strobes inside handlers %0d do not match ce pulses %0d",
                   handler_strobes, handler_ce);
        if (dut.u_apu.dbg_pulse1_length !== 8'd160)
            $fatal(1, "pulse1 length is %0d expected 160", dut.u_apu.dbg_pulse1_length);
        if (dut.u_apu.dbg_pulse1_mute !== 1'b0)
            $fatal(1, "pulse1 is muted");
        if (dut.u_apu.dbg_dmc_irq !== 1'b0)
            $fatal(1, "the dmc raised an irq, dmc dma is never enabled here");
        $display("AUDIO ce pulses=%0d sample strobes=%0d nonzero=%0d peak=%0d, strobes inside handlers=%0d/%0d, pulse1 length=%0d PASS",
                 ce_pulses, sample_strobes, sample_nonzero, sample_peak,
                 handler_strobes, handler_ce, dut.u_apu.dbg_pulse1_length);
    end
endtask

task check_ppu_state;
    begin
        if (dut.u_ppu.control_reg !== 8'h80)
            $fatal(1, "ppuctrl is %02x expected 80", dut.u_ppu.control_reg);
        if (dut.u_ppu.mask_reg !== 8'h1E)
            $fatal(1, "ppumask is %02x expected 1E", dut.u_ppu.mask_reg);
        if (dut.u_ppu.v_addr !== 15'h0000)
            $fatal(1, "ppu v is %04x expected 0000", dut.u_ppu.v_addr);
        if (dut.u_ppu.temp_addr !== 15'h0000)
            $fatal(1, "ppu t is %04x expected 0000", dut.u_ppu.temp_addr);
        if (dut.u_ppu.fine_x !== 3'd0)
            $fatal(1, "ppu fine x is %0d expected 0", dut.u_ppu.fine_x);
        if (dut.u_ppu.write_toggle !== 1'b0)
            $fatal(1, "ppu w toggle is %b expected 0", dut.u_ppu.write_toggle);
        if (dut.u_ppu.oam_addr_reg !== 8'h00)
            $fatal(1, "ppu oamaddr is %02x expected 00 after the last dma",
                   dut.u_ppu.oam_addr_reg);
        for (i = 0; i < 8; i = i + 1)
            if (dut.u_ppu.chr_ram[i] !== 8'hFF)
                $fatal(1, "chr[%0d] is %02x expected ff", i, dut.u_ppu.chr_ram[i]);
        for (i = 8; i < 16; i = i + 1)
            if (dut.u_ppu.chr_ram[i] !== 8'h00)
                $fatal(1, "chr[%0d] is %02x expected 00", i, dut.u_ppu.chr_ram[i]);
        for (i = 16; i < 24; i = i + 1)
            if (dut.u_ppu.chr_ram[i] !== 8'h00)
                $fatal(1, "chr[%0d] is %02x expected 00", i, dut.u_ppu.chr_ram[i]);
        for (i = 24; i < 32; i = i + 1)
            if (dut.u_ppu.chr_ram[i] !== 8'hFF)
                $fatal(1, "chr[%0d] is %02x expected ff", i, dut.u_ppu.chr_ram[i]);
        for (i = 32; i < 40; i = i + 1)
            if (dut.u_ppu.chr_ram[i] !== 8'hFF)
                $fatal(1, "chr[%0d] is %02x expected ff, the sprite plane did not land",
                       i, dut.u_ppu.chr_ram[i]);
        for (i = 40; i < 48; i = i + 1)
            if (dut.u_ppu.chr_ram[i] !== 8'h00)
                $fatal(1, "chr[%0d] is %02x expected 00", i, dut.u_ppu.chr_ram[i]);
        if (dut.u_ppu.nametable_ram[1] !== 8'h01)
            $fatal(1, "nametable[1] is %02x expected 01", dut.u_ppu.nametable_ram[1]);
        if (dut.u_ppu.palette_ram[5'h00] !== 8'h0F)
            $fatal(1, "palette[00] is %02x expected 0f", dut.u_ppu.palette_ram[5'h00]);
        if (dut.u_ppu.palette_ram[5'h01] !== 8'h21)
            $fatal(1, "palette[01] is %02x expected 21", dut.u_ppu.palette_ram[5'h01]);
        if (dut.u_ppu.palette_ram[5'h02] !== 8'h32)
            $fatal(1, "palette[02] is %02x expected 32", dut.u_ppu.palette_ram[5'h02]);
        if (dut.u_ppu.palette_ram[5'h11] !== 8'h16)
            $fatal(1, "palette[11] is %02x expected 16", dut.u_ppu.palette_ram[5'h11]);
        $display("PPUSTATE ctrl=80 mask=1E v=0000 t=0000 w=0 oamaddr=00, chr[0:7]=ff [8:15]=00 [16:23]=00 [24:31]=ff [32:39]=ff [40:47]=00, nt[1]=01, pal=0f,21,32 and 11=16 PASS");
    end
endtask

task check_oam_content;
    begin
        for (k = 0; k < 256; k = k + 1) begin
            if (oam_snap[0][k] !== table1[k])
                $fatal(1, "after dma 1 oam[%0d] is %02x expected %02x",
                       k, oam_snap[0][k], table1[k]);
            if (oam_snap[2][k] !== table1[k])
                $fatal(1, "after dma 3 oam[%0d] is %02x expected %02x",
                       k, oam_snap[2][k], table1[k]);
            if (dut.u_ppu.oam_ram[k] !== table1[k])
                $fatal(1, "final oam[%0d] is %02x expected %02x",
                       k, dut.u_ppu.oam_ram[k], table1[k]);
        end
        for (k = 0; k < 16; k = k + 1)
            if (oam_snap[1][8'hF0 + k] !== table2[k])
                $fatal(1, "after dma 2 oam[%02x] is %02x expected %02x",
                       8'hF0 + k, oam_snap[1][8'hF0 + k], table2[k]);
        for (k = 0; k < 240; k = k + 1)
            if (oam_snap[1][k] !== table2[16 + k])
                $fatal(1, "after dma 2 oam[%0d] is %02x expected %02x (oamaddr wrap)",
                       k, oam_snap[1][k], table2[16 + k]);
        if (dut.u_bus.ram_array[11'h200] !== table1[0])
            $fatal(1, "the dma source page $0200 does not hold the program image");
        if (dut.u_bus.ram_array[11'h2FF] !== table1[255])
            $fatal(1, "the dma source page $02ff does not hold the program image");
        if (dut.u_bus.ram_array[11'h500] !== table2[0])
            $fatal(1, "the dma source page $0500 does not hold the program image");
        if (dut.u_bus.ram_array[11'h5FF] !== table2[255])
            $fatal(1, "the dma source page $05ff does not hold the program image");
        if (dut.u_bus.ram_array[DMA1_FLAG_CELL[10:0]] !== 8'h01)
            $fatal(1, "dma 1 flag cell is %02x expected 01",
                   dut.u_bus.ram_array[DMA1_FLAG_CELL[10:0]]);
        if (dut.u_bus.ram_array[DMA2_FLAG_CELL[10:0]] !== 8'h02)
            $fatal(1, "dma 2 flag cell is %02x expected 02",
                   dut.u_bus.ram_array[DMA2_FLAG_CELL[10:0]]);
        if (dut.u_bus.ram_array[DMA3_FLAG_CELL[10:0]] !== 8'h03)
            $fatal(1, "dma 3 flag cell is %02x expected 03",
                   dut.u_bus.ram_array[DMA3_FLAG_CELL[10:0]]);
        if (dut.u_bus.ram_array[OAM_RB_FLAG_CELL[10:0]] !== 8'h01)
            $fatal(1, "the oam readback flag cell is %02x expected 01",
                   dut.u_bus.ram_array[OAM_RB_FLAG_CELL[10:0]]);
        $display("OAMDMA transfer 1 base=00 page=02 gives oam[0..255]=table1[0..255] in order, transfer 2 base=f0 page=05 gives oam[f0..ff]=table2[0..15] and oam[00..ef]=table2[16..255] (oamaddr wrap), transfer 3 base=00 page=02 restores table1, the cpu readback of $2004 saw the dma result PASS");
    end
endtask

task check_dma_transfers;
    begin
        if (dma_start_count != 3)
            $fatal(1, "oam dma start count got %0d expected 3", dma_start_count);
        if (done_count != 3)
            $fatal(1, "oam dma done count got %0d expected 3", done_count);
        if (xfer_count != 3)
            $fatal(1, "completed dma transfer count got %0d expected 3", xfer_count);
        if (xfer_page[0] !== 8'h02 || xfer_base[0] !== 8'h00)
            $fatal(1, "transfer 0 ran page %02x base %02x expected 02/00",
                   xfer_page[0], xfer_base[0]);
        if (xfer_page[1] !== 8'h05 || xfer_base[1] !== 8'hF0)
            $fatal(1, "transfer 1 ran page %02x base %02x expected 05/f0",
                   xfer_page[1], xfer_base[1]);
        if (xfer_page[2] !== 8'h02 || xfer_base[2] !== 8'h00)
            $fatal(1, "transfer 2 ran page %02x base %02x expected 02/00",
                   xfer_page[2], xfer_base[2]);
        for (i = 0; i < 3; i = i + 1)
            if (xfer_acks[i] !== 16'd256)
                $fatal(1, "transfer %0d acked %0d bytes, expected 256",
                       i, xfer_acks[i]);
        if (dma_ack_count != 3 * 256)
            $fatal(1, "total dma acks got %0d expected 768", dma_ack_count);
        if (dma_wr_count != 3 * 256)
            $fatal(1, "total dma $2004 writes got %0d expected 768", dma_wr_count);
        if (dma_addr_err != 0)
            $fatal(1, "the dma read %0d bytes from an unexpected address", dma_addr_err);
        if (dma_data_err != 0)
            $fatal(1, "the dma read %0d bytes with the wrong data", dma_data_err);
        if (dma_wr_order_err != 0)
            $fatal(1, "the dma wrote %0d bytes to $2004 out of order", dma_wr_order_err);
        if (dma_index_err != 0)
            $fatal(1, "the dma index mirror disagreed %0d times", dma_index_err);
        if (dma_cur_addr_err != 0)
            $fatal(1, "the oamaddr mirror disagreed with the engine %0d times",
                   dma_cur_addr_err);
        if (dma_ack_together != 0)
            $fatal(1, "two dma acks landed in adjacent clk %0d times", dma_ack_together);
        if (dma_ppu_conflict != 0)
            $fatal(1, "the dma and the cpu drove the ppu register port together %0d times",
                   dma_ppu_conflict);
        if (port_cs_err != 0)
            $fatal(1, "the ppu port mux disagreed with its two sources %0d times",
                   port_cs_err);
        if (dma_ack_no_hold != 0)
            $fatal(1, "the dma got %0d acks without bus_hold", dma_ack_no_hold);
        if (dma_ack_with_cpu != 0)
            $fatal(1, "a dma ack and a cpu transfer landed in the same clk %0d times",
                   dma_ack_with_cpu);
        if (dma_req_pending_err != 0)
            $fatal(1, "dma_wait did not follow the request %0d times", dma_req_pending_err);
        if (dma_active_err != 0)
            $fatal(1, "the dma wait state did not follow the grant %0d times", dma_active_err);
        if (dma_fire_err != 0)
            $fatal(1, "the cpu completed %0d transfers while bus_hold was high",
                   dma_fire_err);
        if (dma_req_err != 0)
            $fatal(1, "the cpu held a bus request %0d times while bus_hold was high",
                   dma_req_err);
        if (dma_ppu_cs_err != 0 || dma_apu_cs_err != 0)
            $fatal(1, "a cpu register transfer happened inside a dma window");
        if (dma_freeze_fail != 0)
            $fatal(1, "the cpu state or pc changed %0d times while bus_hold was high",
                   dma_freeze_fail);
        if (dma_dmc_seen != 0)
            $fatal(1, "the dmc port was selected %0d times, dmc is never enabled",
                   dma_dmc_seen);
        if (dmc_req_seen != 0)
            $fatal(1, "apu_dmc_bus_req went high %0d times, dmc is never enabled",
                   dmc_req_seen);
        if (dma_unimpl_seen != 0)
            $fatal(1, "the dma hit a ppu or apu mmio window %0d times", dma_unimpl_seen);
        if (addr_wr_seen != 0)
            $fatal(1, "the dma engine drove $2003 %0d times, OAMADDR_WRITE must be 0",
                   addr_wr_seen);
        if (dma_shadow_err != 0)
            $fatal(1, "the oamaddr shadow disagreed with the ppu %0d times", dma_shadow_err);
        $display("DMABUS bus_hold = oam_dma_cpu_hold || apu_dmc_bus_req, the oam>dmc grant never needed the dmc path, no cpu transfer and no register access inside any dma window, cpu state and pc frozen for all 3 transfers PASS");
        $display("DMAHOLD per transfer ce held=%0d/%0d/%0d, clk held=%0d/%0d/%0d, align clks=%0d/%0d/%0d, 256 acks and 256 $2004 writes each PASS",
                 xfer_ce[0], xfer_ce[1], xfer_ce[2],
                 xfer_clk[0], xfer_clk[1], xfer_clk[2],
                 xfer_align[0], xfer_align[1], xfer_align[2]);
    end
endtask

task check_frames;
    begin
        if (frame_count != FRAME_TARGET)
            $fatal(1, "frame_done count got %0d expected %0d", frame_count, FRAME_TARGET);
        if (frame_delta != 357368)
            $fatal(1, "frame period got %0d clk expected 357368", frame_delta);
        if (vblank_rise != FRAME_TARGET || vblank_fall != FRAME_TARGET)
            $fatal(1, "vblank rises %0d falls %0d expected %0d each",
                   vblank_rise, vblank_fall, FRAME_TARGET);
        if (visible_pixels != 61440)
            $fatal(1, "checked visible pixels got %0d expected 61440", visible_pixels);
        if (checked_bg != 61312)
            $fatal(1, "palette index 1 pixel count got %0d expected 61312", checked_bg);
        if (checked_tile1 != 64)
            $fatal(1, "palette index 2 pixel count got %0d expected 64", checked_tile1);
        if (checked_sprite != 64)
            $fatal(1, "sprite palette index 6 pixel count got %0d expected 64", checked_sprite);
        $display("FRAME frame_done=%0d period=%0dclk vblank rises=%0d falls=%0d, checked frame pixels=%0d index1=%0d index2=%0d sprite6=%0d PASS",
                 frame_count, frame_delta, vblank_rise, vblank_fall,
                 visible_pixels, checked_bg, checked_tile1, checked_sprite);
    end
endtask

always @(posedge clk) begin
    if (reset) begin
        stall_cycles = 0;
        transfer_stall_expect = 0;
    end else if (dut.div_phase == 4'd0) begin
        if (bus_stall !== (bus_req && !bus_fire))
            $fatal(1, "bus_stall got %b expected %b at %04h",
                   bus_stall, (bus_req && !bus_fire), bus_addr);
        if (bus_req && !bus_fire) begin
            stall_cycles = stall_cycles + 1;
            if (stall_cycles > 1 && bus_active !== 1'b1)
                $fatal(1, "a continued stall is not marked active at %04h", bus_addr);
        end else if (bus_fire) begin
            // CONTRACT CHANGE, 2x cpu rate.  This used to be
            // (sel_open_bus === 1'b1) ? 0 : 1, i.e. every owner except the open
            // bus window was REQUIRED to spend a second ce_cpu beat stalling,
            // which is the defect this contract now forbids.  ce_cpu IS the cpu
            // cycle (div_phase == 4'd0, twelve clk, three ppu dots) and this core
            // instantiates READ_WAIT_CYCLES = 8'd1, so a wait of one beat is this
            // cpu cycle and not an extra one.  Every owner now completes on the
            // first ce_cpu beat of its request.
            transfer_stall_expect = 0;
            transfer_had_stall = (stall_cycles == 8'd0) ? 1'b0 : 1'b1;
            if (transfer_had_stall != transfer_stall_expect)
                $fatal(1, "transfer at %04h owner %0d took %0d stall cycles, expected %0d",
                       bus_addr, bus_owner, stall_cycles, transfer_stall_expect);
            if (bus_wait_count !== 8'd0)
                $fatal(1, "wait count %0d at the completing cycle of %04h",
                       bus_wait_count, bus_addr);
            // The completing cycle used to be REQUIRED to be marked active,
            // because a stalled access arms active.  A zero-stall access never
            // arms it, so active must now be LOW here: that is the other half of
            // the same contract change, moved and not deleted.
            if (bus_active !== 1'b0)
                $fatal(1, "the completing cycle of %04h is marked active, a zero stall access must never arm the wait state", bus_addr);
            immediate_count = immediate_count + 1;
            stall_cycles = 0;
        end
    end
end

always @(posedge clk) begin
    if (reset) begin
        bus_fire_count = 0;
        prev_xfer_valid = 1'b0;
    end else if (bus_fire) begin
        bus_fire_count = bus_fire_count + 1;
        if (sel_open_bus === 1'b1) begin
            if (bus_we !== 1'b0)
                $fatal(1, "unexpected write to the open bus window at %04h", bus_addr);
            if (prev_xfer_valid !== 1'b0 && bus_din !== prev_xfer_din)
                $fatal(1, "open bus read at %04h returned %02x, the previous transfer at %04h carried %02x",
                       bus_addr, bus_din, prev_xfer_addr, prev_xfer_din);
            open_rd = open_rd + 1;
        end else if (sel_ram === 1'b1) begin
            if (bus_we) begin
                ram_wr = ram_wr + 1;
                case (bus_addr[10:0])
                    NMI_COUNTER_CELL[10:0]: ram_wr_nmi = ram_wr_nmi + 1;
                    IRQ_COUNTER_CELL[10:0]: ram_wr_irq = ram_wr_irq + 1;
                    SETUP_FLAG_CELL[10:0]: ram_wr_setup = ram_wr_setup + 1;
                    DMA1_FLAG_CELL[10:0]: ram_wr_dma1 = ram_wr_dma1 + 1;
                    DMA2_FLAG_CELL[10:0]: ram_wr_dma2 = ram_wr_dma2 + 1;
                    DMA3_FLAG_CELL[10:0]: ram_wr_dma3 = ram_wr_dma3 + 1;
                    OAM_RB_FLAG_CELL[10:0]: ram_wr_oamrb = ram_wr_oamrb + 1;
                    OPEN_BUS_CELL[10:0]: ram_wr_open = ram_wr_open + 1;
                    11'h1F9: jsr_frame = jsr_frame + 1;
                    11'h1F0, 11'h1F1, 11'h1F2, 11'h1F3, 11'h1F4, 11'h1F5,
                    11'h1F6, 11'h1F7, 11'h1F8, 11'h1FA, 11'h1FB, 11'h1FC,
                    11'h1FD, 11'h1FE, 11'h1FF: begin
                    end
                    default: begin
                        if ((bus_addr[10:0] < 11'h200) || (bus_addr[10:0] > 11'h5FF))
                            $fatal(1, "unexpected ram write to %04h data %02x",
                                   bus_addr, bus_dout);
                    end
                endcase
            end else begin
                ram_rd = ram_rd + 1;
            end
        end else if (sel_ppu === 1'b1) begin
            if (bus_we) begin
                ppu_wr = ppu_wr + 1;
                case (ppu_reg_addr)
                    3'd0: ppu_wr_ctrl = ppu_wr_ctrl + 1;
                    3'd1: ppu_wr_mask = ppu_wr_mask + 1;
                    3'd2: ppu_wr_status = ppu_wr_status + 1;
                    3'd3: ppu_wr_oamaddr = ppu_wr_oamaddr + 1;
                    3'd4: ppu_wr_oamdata = ppu_wr_oamdata + 1;
                    3'd6: ppu_wr_vaddr = ppu_wr_vaddr + 1;
                    3'd7: ppu_wr_vdata = ppu_wr_vdata + 1;
                    default: ppu_wr_other = ppu_wr_other + 1;
                endcase
            end else begin
                ppu_rd = ppu_rd + 1;
                if (ppu_reg_addr !== 3'd4)
                    $fatal(1, "unexpected ppu register read at %04h reg %0d",
                           bus_addr, ppu_reg_addr);
                ppu_rd_oamdata = ppu_rd_oamdata + 1;
            end
        end else if (sel_apu_io === 1'b1) begin
            if (bus_we) begin
                apu_wr = apu_wr + 1;
                case (apu_reg_addr)
                    5'h00: apu_wr_p1 = apu_wr_p1 + 1;
                    5'h01: apu_wr_p1b = apu_wr_p1b + 1;
                    5'h02: apu_wr_p1c = apu_wr_p1c + 1;
                    5'h03: apu_wr_p1d = apu_wr_p1d + 1;
                    5'h14: apu_wr_dma = apu_wr_dma + 1;
                    5'h15: apu_wr_status = apu_wr_status + 1;
                    5'h17: apu_wr_frame = apu_wr_frame + 1;
                    default: apu_wr_other = apu_wr_other + 1;
                endcase
            end else begin
                apu_rd = apu_rd + 1;
                if (apu_reg_addr == 5'h15)
                    apu_rd_4015 = apu_rd_4015 + 1;
                else
                    apu_rd_other = apu_rd_other + 1;
            end
        end else if (sel_cart_ram === 1'b1) begin
            if (bus_we)
                cartram_wr = cartram_wr + 1;
            else
                cartram_rd = cartram_rd + 1;
        end else begin
            if (bus_we)
                prg_wr = prg_wr + 1;
            else begin
                prg_rd = prg_rd + 1;
                if (cart_din !== dut.prg_rom[bus_addr[PRG_INDEX_BITS-1:0]])
                    $fatal(1, "cart_din %02x does not match prg_rom at %04h",
                           cart_din, bus_addr);
            end
        end
        if ((bus_addr[10:0] >= 11'h1F0) && (bus_addr[10:0] <= 11'h1FF)) begin
            if (bus_we)
                stk_wr[bus_addr[3:0]] = stk_wr[bus_addr[3:0]] + 1;
            else
                stk_rd[bus_addr[3:0]] = stk_rd[bus_addr[3:0]] + 1;
        end
        prev_xfer_din = bus_din;
        prev_xfer_addr = bus_addr;
        prev_xfer_valid = 1'b1;
    end
end

always @(posedge clk) begin
    if (reset) begin
        prev_ppu_cs = 1'b0;
        prev_apu_cs = 1'b0;
    end else begin
        if (ppu_reg_cs !== 1'b0) begin
            if (sel_ppu !== 1'b1 || bus_fire !== 1'b1)
                $fatal(1, "ppu_reg_cs asserted without a completed ppu transfer at %04h", bus_addr);
            if (prev_ppu_cs !== 1'b0)
                $fatal(1, "ppu_reg_cs was high for two clk in a row");
            if (in_irq_handler)
                ppu_cs_in_irq = 1'b1;
        end
        if (apu_reg_cs !== 1'b0) begin
            if (sel_apu_io !== 1'b1 || bus_fire !== 1'b1)
                $fatal(1, "apu_reg_cs asserted without a completed apu transfer at %04h", bus_addr);
            if (prev_apu_cs !== 1'b0)
                $fatal(1, "apu_reg_cs was high for two clk in a row");
            if (apu_reg_addr > 5'h17)
                $fatal(1, "apu_reg_cs outside $4000-$4017, reg_addr=%02x", apu_reg_addr);
            if (in_nmi_handler && apu_reg_addr != 5'h14)
                apu_cs_other_in_nmi = 1'b1;
        end
        if (cart_xfer !== 1'b0) begin
            if (bus_fire !== 1'b1)
                $fatal(1, "cart_xfer asserted without a completed transfer at %04h", bus_addr);
            if (sel_cart_rom !== 1'b1 && sel_cart_ram !== 1'b1)
                $fatal(1, "cart_xfer asserted outside the cartridge windows");
        end
        if (cart_req !== 1'b0 && sel_cart_rom !== 1'b1 && sel_cart_ram !== 1'b1)
            $fatal(1, "cart_req asserted outside the cartridge windows at %04h", bus_addr);
        if (ram_we !== 1'b0) begin
            if (sel_ram !== 1'b1 || bus_fire !== 1'b1 || bus_we !== 1'b1)
                $fatal(1, "ram_we asserted without a completed ram write");
        end
        if (ppu_reg_we !== 1'b0 && (sel_ppu !== 1'b1 || bus_req !== 1'b1))
            $fatal(1, "ppu_reg_we asserted outside a ppu request at %04h", bus_addr);
        if (apu_reg_we !== 1'b0 && (sel_apu_io !== 1'b1 || bus_req !== 1'b1))
            $fatal(1, "apu_reg_we asserted outside an apu request at %04h", bus_addr);
        if (cart_ack !== 1'b1)
            $fatal(1, "cart_ack is not tied high");
        prev_ppu_cs = ppu_reg_cs;
        prev_apu_cs = apu_reg_cs;
    end
end

always @(posedge clk) begin
    #1;
    if (reset) begin
        bus_ce_active_snap = bus_active;
        bus_ce_wait_snap = bus_wait_count;
    end else if (dut.div_phase == 4'd1) begin
        bus_ce_active_snap = bus_active;
        bus_ce_wait_snap = bus_wait_count;
    end else if ((bus_active !== bus_ce_active_snap) ||
                 (bus_wait_count !== bus_ce_wait_snap)) begin
        $fatal(1, "bus state moved on a clk without a cpu enable: div_phase=%0d active %b->%b wait %0d->%0d addr=%04h req=%b stall=%b",
               dut.div_phase, bus_ce_active_snap, bus_active,
               bus_ce_wait_snap, bus_wait_count, bus_addr, bus_req, bus_stall);
    end
end

always @(posedge clk) begin
    if (reset) begin
        dma_ack_count = 0;
        dma_wr_count = 0;
        dma_byte_index = 0;
        dma_start_count = 0;
        done_count = 0;
        dma_transfer_ce = 0;
        dma_transfer_clk = 0;
        dma_done_clks = 0;
        expect_dma_data_valid = 1'b0;
        dma_dmc_seen = 0;
        dmc_req_seen = 0;
        dma_unimpl_seen = 0;
        addr_wr_seen = 0;
        dma_index_err = 0;
        dma_cur_addr_err = 0;
        dma_shadow_err = 0;
        dma_ack_together = 0;
        dma_ppu_conflict = 0;
        dma_ack_no_hold = 0;
        dma_ack_with_cpu = 0;
        dma_req_pending_err = 0;
        dma_active_err = 0;
        dma_fire_err = 0;
        dma_req_err = 0;
        dma_ppu_cs_err = 0;
        dma_apu_cs_err = 0;
        dma_freeze_fail = 0;
        dma_active_seen = 1'b0;
        port_cs_err = 0;
        prev_busy = 1'b0;
        freeze_valid = 1'b0;
        snapshot_pending = 0;
    end else begin
        if (oam_dma_addr_wr !== 1'b0)
            addr_wr_seen = addr_wr_seen + 1;
        if (apu_dmc_bus_req !== 1'b0)
            dmc_req_seen = dmc_req_seen + 1;
        if (dma_sel !== 1'b0)
            dma_dmc_seen = dma_dmc_seen + 1;
        if (dma_unimpl !== 1'b0)
            dma_unimpl_seen = dma_unimpl_seen + 1;
        if (oam_dma_base_addr !== dut.u_ppu.oam_addr_reg)
            dma_shadow_err = dma_shadow_err + 1;
        if (ppu_port_cs !== (oam_dma_ppu_reg_cs || ppu_reg_cs))
            port_cs_err = port_cs_err + 1;
        if (oam_dma_ppu_reg_cs !== 1'b0 && ppu_reg_cs !== 1'b0)
            dma_ppu_conflict = dma_ppu_conflict + 1;
        if (bus_hold !== (oam_dma_cpu_hold || apu_dmc_bus_req))
            $fatal(1, "bus_hold is %b but the dma hold terms are %b/%b",
                   bus_hold, oam_dma_cpu_hold, apu_dmc_bus_req);
        if (oam_dma_cpu_hold !== oam_dma_busy)
            $fatal(1, "cpu_hold is %b while busy is %b", oam_dma_cpu_hold, oam_dma_busy);
        if (oam_dma_busy !== 1'b0 && oam_dma_page !== oam_dma_page_latch)
            $fatal(1, "the source page latch disagreed with the engine, page=%02x latch=%02x",
                   oam_dma_page, oam_dma_page_latch);
        if (oam_dma_busy !== 1'b0 && oam_dma_cur_addr !== dut.u_ppu.oam_addr_reg)
            dma_cur_addr_err = dma_cur_addr_err + 1;

        if (oam_dma_start !== 1'b0) begin
            dma_start_count = dma_start_count + 1;
            dma_byte_index = 0;
            dma_wr_index = 0;
            dma_transfer_ce = 0;
            dma_transfer_clk = 0;
            if (sel_apu_io !== 1'b1 || bus_we !== 1'b1 || apu_reg_addr !== 5'h14)
                $fatal(1, "oam_dma_start asserted outside a completed $4014 write");
            xfer_page[xfer_count] = bus_dout;
            xfer_base[xfer_count] = oam_dma_base_addr;
            xfer_acks[xfer_count] = 16'd0;
            xfer_ce[xfer_count] = 16'd0;
            xfer_clk[xfer_count] = 16'd0;
            xfer_align[xfer_count] = 16'd0;
        end

        if (oam_dma_done !== 1'b0)
            done_count = done_count + 1;

        if (oam_dma_busy !== 1'b0) begin
            dma_transfer_clk = dma_transfer_clk + 1;
            if (dut.div_phase == 4'd0) begin
                dma_transfer_ce = dma_transfer_ce + 1;
                if (oam_dma_cpu_read_req === 1'b0 && oam_dma_cur_addr === xfer_base[xfer_count] &&
                    dma_transfer_clk < 24)
                    xfer_align[xfer_count] = xfer_align[xfer_count] + 1;
            end
            if (ppu_reg_cs !== 1'b0)
                dma_ppu_cs_err = dma_ppu_cs_err + 1;
            if (apu_reg_cs !== 1'b0)
                dma_apu_cs_err = dma_apu_cs_err + 1;
            if (bus_fire !== 1'b0)
                dma_fire_err = dma_fire_err + 1;
            if (bus_req !== 1'b0)
                dma_req_err = dma_req_err + 1;
            if (freeze_valid === 1'b0) begin
                freeze_valid = 1'b1;
                freeze_state = dut.u_cpu.dbg_state;
                freeze_pc = dut.u_cpu.dbg_pc;
            end else if ((dut.u_cpu.dbg_state !== freeze_state) ||
                         (dut.u_cpu.dbg_pc !== freeze_pc)) begin
                dma_freeze_fail = dma_freeze_fail + 1;
                freeze_state = dut.u_cpu.dbg_state;
                freeze_pc = dut.u_cpu.dbg_pc;
            end
        end else begin
            freeze_valid = 1'b0;
        end

        if (dma_ack !== 1'b0) begin
            if (bus_hold === 1'b0)
                dma_ack_no_hold = dma_ack_no_hold + 1;
            if (bus_fire !== 1'b0)
                dma_ack_with_cpu = dma_ack_with_cpu + 1;
            if (prev_dma_ack !== 1'b0)
                dma_ack_together = dma_ack_together + 1;
            if (oam_dma_cpu_read_ack === 1'b0)
                $fatal(1, "the bus acked the dma port but the oam engine took no ack");
            if (oam_dma_cpu_rdata !== dma_din)
                $fatal(1, "the oam engine saw %02x but the bus returned %02x",
                       oam_dma_cpu_rdata, dma_din);
            if (dma_owner !== 2'd0)
                $fatal(1, "dbg_dma_owner is %0d during an oam ack, expected 0", dma_owner);
            if (oam_dma_cpu_read_addr !== {xfer_page[xfer_count], dma_byte_index[7:0]})
                dma_addr_err = dma_addr_err + 1;
            if (dma_din !== dut.u_bus.ram_array[oam_dma_cpu_read_addr[10:0]])
                dma_data_err = dma_data_err + 1;
            if (oam_dma_index !== dma_byte_index[7:0])
                dma_index_err = dma_index_err + 1;
            dma_ack_count = dma_ack_count + 1;
            xfer_acks[xfer_count] = xfer_acks[xfer_count] + 16'd1;
            expect_dma_data = dma_din;
            expect_dma_data_valid = 1'b1;
            dma_byte_index = dma_byte_index + 1;
        end
        if (dma_wait !== ((oam_dma_cpu_read_req || apu_dmc_bus_req) && !dma_ack))
            dma_req_pending_err = dma_req_pending_err + 1;
        if (dma_active === 1'b0) begin
            dma_active_seen = 1'b0;
        end else begin
            if ((dma_active_seen === 1'b1) && (dma_ack === 1'b0))
                dma_active_err = dma_active_err + 1;
            dma_active_seen = 1'b1;
        end
        prev_dma_ack = dma_ack;

        if (oam_dma_ppu_reg_cs !== 1'b0) begin
            if (prev_dma_ppu_cs !== 1'b0)
                $fatal(1, "the dma held the ppu register port for two clk in a row");
            if (oam_dma_ppu_reg_addr !== 3'd4)
                $fatal(1, "the dma drove ppu reg %0d instead of $2004", oam_dma_ppu_reg_addr);
            if (oam_dma_ppu_reg_we !== 1'b1)
                $fatal(1, "the dma drove a read cycle on the ppu register port");
            if (expect_dma_data_valid !== 1'b0) begin
                dma_exp_rdata = expect_dma_data;
                if (oam_dma_ppu_reg_dout !== expect_dma_data)
                    dma_wr_order_err = dma_wr_order_err + 1;
                expect_dma_data_valid = 1'b0;
            end else begin
                $fatal(1, "the dma wrote $2004 without a preceding acked read");
            end
            if (oam_dma_ppu_reg_dout !== dma_exp_rdata)
                dma_wr_order_err = dma_wr_order_err + 1;
            dma_exp_addr = {xfer_page[xfer_count], dma_wr_index[7:0]};
            if (oam_dma_ppu_reg_dout !== dut.u_bus.ram_array[dma_exp_addr[10:0]])
                dma_wr_order_err = dma_wr_order_err + 1;
            dma_wr_count = dma_wr_count + 1;
            dma_wr_index = dma_wr_index + 1;
        end
        if (oam_dma_ppu_reg_cs === 1'b0)
            prev_dma_ppu_cs = 1'b0;
        else
            prev_dma_ppu_cs = 1'b1;

        if (prev_busy === 1'b1 && oam_dma_busy === 1'b0) begin
            if (dma_byte_index != 256)
                $fatal(1, "a transfer acked %0d bytes, expected 256", dma_byte_index);
            if (dma_transfer_ce != xfer_ce[xfer_count] + (dma_transfer_ce))
                $fatal(1, "internal ce accounting mismatch");
            xfer_ce[xfer_count] = dma_transfer_ce[15:0];
            xfer_clk[xfer_count] = dma_transfer_clk[15:0];
            xfer_count = xfer_count + 1;
            snapshot_pending = 1;
            snapshot_slot = xfer_count - 1;
        end
        prev_busy = oam_dma_busy;

        if (snapshot_pending !== 0) begin
            for (k = 0; k < 256; k = k + 1)
                oam_snap[snapshot_slot][k] = dut.u_ppu.oam_ram[k];
            snapshot_pending = 0;
        end
    end
end

always @(posedge clk) begin
    if (reset) begin
        nmi_rise_count = 0;
        irq_rise_count = 0;
        irq_fall_count = 0;
        nmi_entry_count = 0;
        irq_entry_count = 0;
        last_irq_flag = 1'b0;
        sample_strobes = 0;
        sample_nonzero = 0;
        sample_peak = 0;
        ce_pulses = 0;
        handler_ce = 0;
        handler_strobes = 0;
        illegal_hits = 0;
        saw_reset_lo = 1'b0;
        saw_reset_hi = 1'b0;
        saw_first_fetch = 1'b0;
        saw_first_opcode = 1'b0;
        saw_fetch_bus = 1'b0;
        seen_main_loop = 1'b0;
        in_nmi_handler = 1'b0;
        in_irq_handler = 1'b0;
        in_init_routine = 1'b0;
        in_handler = 1'b0;
        prev_frame_done = 1'b0;
        clk_count = 0;
    end else begin
        clk_count = clk_count + 1;
        if (dut.u_cpu.dbg_illegal !== 1'b0)
            illegal_hits = illegal_hits + 1;
        case (dut.u_cpu.dbg_state)
            7'd5: if (saw_reset_lo !== 1'b1) begin
                saw_reset_lo = 1'b1;
                reset_lo_addr = bus_addr;
            end
            7'd6: if (saw_reset_hi !== 1'b1) begin
                saw_reset_hi = 1'b1;
                reset_hi_addr = bus_addr;
            end
            7'd7: begin
                if (saw_first_fetch !== 1'b1) begin
                    saw_first_fetch = 1'b1;
                    if (dut.u_cpu.dbg_pc !== MAIN_PROG)
                        $fatal(1, "first fetch pc got %04h", dut.u_cpu.dbg_pc);
                end
                if (bus_fire !== 1'b0)
                    saw_fetch_bus = 1'b1;
                else if (saw_fetch_bus === 1'b1 && saw_first_opcode !== 1'b1) begin
                    saw_first_opcode = 1'b1;
                    if (dut.u_cpu.dbg_opcode !== 8'h58)
                        $fatal(1, "first fetched opcode got %02x expected 58",
                               dut.u_cpu.dbg_opcode);
                end
            end
            default: begin
            end
        endcase
        if (dut.u_cpu.dbg_state >= 7'd7) begin
            if (dut.u_cpu.dbg_pc >= FAIL_LOOP && dut.u_cpu.dbg_pc <= FAIL_LOOP + 16'd2)
                $fatal(1, "the cpu entered the failure loop at %04h, prev_xfer %04h din=%02x a=%02x p=%02x",
                       FAIL_LOOP, prev_xfer_addr, prev_xfer_din,
                       dut.u_cpu.dbg_a, dut.u_cpu.dbg_p);
            if ((dut.u_cpu.dbg_pc < MAIN_PROG) ||
                (dut.u_cpu.dbg_pc > FAIL_LOOP + 16'd2))
                $fatal(1, "the cpu left the prg program area, pc=%04h state=%0d p=%02x sp=%02x last_xfer=%04h",
                       dut.u_cpu.dbg_pc, dut.u_cpu.dbg_state, dut.u_cpu.dbg_p,
                       dut.u_cpu.dbg_sp, prev_xfer_addr);
            if ((dut.u_cpu.dbg_pc >= main_prog_end) && (dut.u_cpu.dbg_pc < NMI_HANDLER))
                $fatal(1, "the cpu ran in an unprogrammed gap, pc=%04h", dut.u_cpu.dbg_pc);
            if ((dut.u_cpu.dbg_pc > nmi_end) && (dut.u_cpu.dbg_pc < IRQ_HANDLER))
                $fatal(1, "the cpu ran past the nmi handler, pc=%04h", dut.u_cpu.dbg_pc);
            if ((dut.u_cpu.dbg_pc > irq_end) && (dut.u_cpu.dbg_pc < INIT_ROUTINE))
                $fatal(1, "the cpu ran past the irq handler, pc=%04h", dut.u_cpu.dbg_pc);
            if ((dut.u_cpu.dbg_pc > (init_end - 16'd1)) && (dut.u_cpu.dbg_pc < FAIL_LOOP))
                $fatal(1, "the cpu ran past the init routine, pc=%04h", dut.u_cpu.dbg_pc);
        end

        in_nmi_handler = (dut.u_cpu.dbg_pc >= NMI_HANDLER) &&
                         (dut.u_cpu.dbg_pc < nmi_end);
        in_irq_handler = (dut.u_cpu.dbg_pc >= IRQ_HANDLER) &&
                         (dut.u_cpu.dbg_pc < irq_end);
        in_init_routine = (dut.u_cpu.dbg_pc >= INIT_ROUTINE) &&
                          (dut.u_cpu.dbg_pc < init_end);
        in_handler = in_nmi_handler || in_irq_handler || in_init_routine;
        if (in_handler && (dut.u_cpu.dbg_state < 7'd42)) begin
            if (dut.u_cpu.dbg_p[2] !== 1'b1)
                $fatal(1, "the i flag is clear inside a handler, p=%02x pc=%04h state=%0d sp=%02x last=%04h",
                       dut.u_cpu.dbg_p, dut.u_cpu.dbg_pc, dut.u_cpu.dbg_state,
                       dut.u_cpu.dbg_sp, prev_xfer_addr);
            if (dut.u_cpu.dbg_sp > 8'hFA)
                $fatal(1, "sp=%02x inside a handler at pc=%04h",
                       dut.u_cpu.dbg_sp, dut.u_cpu.dbg_pc);
        end
        if (dut.u_cpu.dbg_state === 7'd7 && bus_fire === 1'b1) begin
            if (in_handler) begin
                seen_main_loop = 1'b1;
            end else begin
                if (saw_first_opcode === 1'b1 && dut.u_cpu.dbg_p[2] !== 1'b0)
                    $fatal(1, "the i flag is set outside a handler, p=%02x pc=%04h",
                           dut.u_cpu.dbg_p, dut.u_cpu.dbg_pc);
                if (dut.u_cpu.dbg_sp !== 8'hFD)
                    $fatal(1, "sp=%02x outside a handler, expected fd",
                           dut.u_cpu.dbg_sp);
            end
        end
        if (bus_fire === 1'b1) begin
            if (bus_addr === 16'hFFFA) begin
                nmi_entry_count = nmi_entry_count + 1;
                seen_main_loop = 1'b1;
            end else if (bus_addr === 16'hFFFE) begin
                irq_entry_count = irq_entry_count + 1;
                seen_main_loop = 1'b1;
            end
        end

        if (dut.div_phase == 4'd0) begin
            ce_pulses = ce_pulses + 1;
            if (in_handler)
                handler_ce = handler_ce + 1;
        end
        if (audio_sample_valid !== 1'b0) begin
            if (dut.div_phase == 4'd0)
                $fatal(1, "audio_sample_valid is high at div_phase=%0d, expected 1",
                       dut.div_phase);
            if (audio_sample_left !== audio_sample_right)
                $fatal(1, "sample channels differ, left=%04x right=%04x",
                       audio_sample_left, audio_sample_right);
            if (dut.u_apu.dbg_tnd_sum !== 8'd0)
                $fatal(1, "tnd sum is %02x but only pulse1 is enabled",
                       dut.u_apu.dbg_tnd_sum);
            sample_strobes = sample_strobes + 1;
            if (audio_sample_left !== 16'd0)
                sample_nonzero = sample_nonzero + 1;
            if (audio_sample_left > sample_peak[15:0])
                sample_peak = audio_sample_left;
            if (in_handler)
                handler_strobes = handler_strobes + 1;
        end
        if (audio_sample_valid === 1'b0 && dut.div_phase == 4'd1)
            $fatal(1, "audio_sample_valid is missing at div_phase=1");

        if (apu_irq_o !== 1'b0) begin
            if (dut.u_apu.dbg_frame_irq === 1'b0 && dut.u_apu.dbg_dmc_irq === 1'b0)
                $fatal(1, "apu irq asserted but neither flag is set");
            if (last_irq_flag === 1'b0) begin
                irq_rise_count = irq_rise_count + 1;
                last_irq_flag = 1'b1;
            end
        end else begin
            if (last_irq_flag === 1'b1) begin
                last_irq_flag = 1'b0;
                irq_fall_count = irq_fall_count + 1;
            end
        end
        if (apu_irq_o !== (dut.u_apu.dbg_frame_irq | dut.u_apu.dbg_dmc_irq))
            $fatal(1, "apu_irq_o does not follow the apu irq flags");
    end
end

always @(posedge clk or posedge reset) begin
    if (reset)
        last_nmi_level <= 1'b0;
    else
        last_nmi_level <= nmi_o;
end

always @(posedge clk) begin
    #1;
    if (reset) begin
        prev_frame_done = 1'b0;
        prev_dot = 9'd340;
        vblank_rise = 0;
        vblank_fall = 0;
        frame_count = 0;
        frame_mark = 0;
        frame_delta = 0;
        have_frame_mark = 1'b0;
        check_enable = 1'b0;
        checked_bg = 0;
        checked_tile1 = 0;
        checked_sprite = 0;
        visible_pixels = 0;
    end else begin
        if (frame_done !== 1'b0) begin
            if (ppu_scanline !== 9'd0 || ppu_dot !== 9'd0)
                $fatal(1, "frame_done asserted at %0d:%0d", ppu_scanline, ppu_dot);
        end
        if ((frame_done === 1'b1) && (prev_frame_done !== 1'b1)) begin
            frame_count = frame_count + 1;
            if (have_frame_mark === 1'b1)
                frame_delta = clk_count - frame_mark;
            else
                have_frame_mark = 1'b1;
            frame_mark = clk_count;
            check_enable = (frame_count == FRAME_TARGET - 1);
            if (check_enable === 1'b1) begin
                checked_bg = 0;
                checked_tile1 = 0;
                checked_sprite = 0;
            end
        end
        prev_frame_done = frame_done;

        expected_vblank = ((ppu_scanline == 9'd241) && (ppu_dot >= 9'd1)) ||
                          ((ppu_scanline >= 9'd242) && (ppu_scanline <= 9'd260)) ||
                          ((ppu_scanline == 9'd261) && (ppu_dot == 9'd0));
        if (vblank !== expected_vblank)
            $fatal(1, "vblank window mismatch at %0d:%0d got %b expected %b",
                   ppu_scanline, ppu_dot, vblank, expected_vblank);
        if (nmi_o !== (vblank && dut.u_ppu.control_reg[7]))
            $fatal(1, "nmi_o got %b expected %b at %0d:%0d with ppuctrl=%02x",
                   nmi_o, (vblank && dut.u_ppu.control_reg[7]),
                   ppu_scanline, ppu_dot, dut.u_ppu.control_reg);
        if ((nmi_o === 1'b1) && (last_nmi_level !== 1'b1)) begin
            nmi_rise_count = nmi_rise_count + 1;
            if ((ppu_scanline !== 9'd241) || (ppu_dot !== 9'd1))
                $fatal(1, "nmi_o rose at %0d:%0d, expected 241:1",
                       ppu_scanline, ppu_dot);
        end
        if ((vblank === 1'b1) && (prev_vblank === 1'b0))
            vblank_rise = vblank_rise + 1;
        if ((vblank === 1'b0) && (prev_vblank === 1'b1))
            vblank_fall = vblank_fall + 1;
        prev_vblank = vblank;

        if (pixel_valid === 1'b1) begin
            if ((pixel_x !== ppu_dot[7:0]) || (pixel_y !== ppu_scanline[7:0]))
                $fatal(1, "pixel coordinates got (%0d,%0d) expected (%0d,%0d)",
                       pixel_x, pixel_y, ppu_dot[7:0], ppu_scanline[7:0]);
            if (check_enable === 1'b1) begin
                expected_index = expected_pixel_index(ppu_scanline, ppu_dot);
                if (pixel_index !== expected_index)
                    $fatal(1, "pixel (%0d,%0d) got index %0d expected %0d",
                           pixel_x, pixel_y, pixel_index, expected_index);
                if (ppu_dot !== prev_dot) begin
                    visible_pixels = visible_pixels + 1;
                    if (expected_index == 4'd1)
                        checked_bg = checked_bg + 1;
                    else if (expected_index == 4'd2)
                        checked_tile1 = checked_tile1 + 1;
                    else
                        checked_sprite = checked_sprite + 1;
                end
            end
        end
        prev_dot = ppu_dot;
    end
end

initial begin
    clk = 1'b0;
    reset = 1'b0;
    bne_count = 0;
    xfer_count = 0;
    bus_fire_count = 0;
    stall_cycles = 0;
    transfer_stall_expect = 0;
    transfer_had_stall = 1'b0;
    immediate_count = 0;
    prg_rd = 0;
    ram_rd = 0;
    ram_wr = 0;
    ppu_rd = 0;
    ppu_rd_oamdata = 0;
    ppu_wr = 0;
    apu_rd = 0;
    apu_wr = 0;
    open_rd = 0;
    cartram_rd = 0;
    cartram_wr = 0;
    prg_wr = 0;
    ppu_wr_ctrl = 0;
    ppu_wr_mask = 0;
    ppu_wr_status = 0;
    ppu_wr_oamaddr = 0;
    ppu_wr_oamdata = 0;
    ppu_wr_vaddr = 0;
    ppu_wr_vdata = 0;
    ppu_wr_other = 0;
    apu_wr_p1 = 0;
    apu_wr_p1b = 0;
    apu_wr_p1c = 0;
    apu_wr_p1d = 0;
    apu_wr_status = 0;
    apu_wr_frame = 0;
    apu_wr_dma = 0;
    apu_wr_other = 0;
    apu_rd_4015 = 0;
    apu_rd_other = 0;
    ram_wr_nmi = 0;
    ram_wr_irq = 0;
    ram_wr_setup = 0;
    ram_wr_dma1 = 0;
    ram_wr_dma2 = 0;
    ram_wr_dma3 = 0;
    ram_wr_oamrb = 0;
    ram_wr_open = 0;
    jsr_frame = 0;
    dma_ack_count = 0;
    dma_wr_count = 0;
    dma_byte_index = 0;
    dma_start_count = 0;
    done_count = 0;
    dma_done_clks = 0;
    dma_transfer_ce = 0;
    dma_transfer_clk = 0;
    dma_addr_err = 0;
    dma_data_err = 0;
    dma_wr_order_err = 0;
    dma_ack_together = 0;
    dma_ppu_conflict = 0;
    dma_ack_no_hold = 0;
    dma_ack_with_cpu = 0;
    dma_req_pending_err = 0;
    dma_active_err = 0;
    dma_freeze_fail = 0;
    dma_ppu_cs_err = 0;
    dma_apu_cs_err = 0;
    dma_fire_err = 0;
    dma_req_err = 0;
    dma_dmc_seen = 0;
    dma_unimpl_seen = 0;
    dma_index_err = 0;
    dma_shadow_err = 0;
    dma_cur_addr_err = 0;
    addr_wr_seen = 0;
    dmc_req_seen = 0;
    port_cs_err = 0;
    expect_dma_data = 0;
    expect_dma_data_valid = 1'b0;
    nmi_rise_count = 0;
    irq_rise_count = 0;
    irq_fall_count = 0;
    nmi_entry_count = 0;
    irq_entry_count = 0;
    sample_strobes = 0;
    sample_nonzero = 0;
    sample_peak = 0;
    ce_pulses = 0;
    handler_ce = 0;
    handler_strobes = 0;
    illegal_hits = 0;
    snapshot_pending = 0;
    snapshot_slot = 0;
    prev_xfer_valid = 1'b0;
    prev_xfer_din = 8'h00;
    prev_xfer_addr = 16'h0000;
    last_irq_flag = 1'b0;
    seen_main_loop = 1'b0;
    in_nmi_handler = 1'b0;
    in_irq_handler = 1'b0;
    in_init_routine = 1'b0;
    in_handler = 1'b0;
    ppu_cs_in_irq = 1'b0;
    apu_cs_other_in_nmi = 1'b0;
    prev_ppu_cs = 1'b0;
    prev_apu_cs = 1'b0;
    prev_dma_ack = 1'b0;
    prev_dma_ppu_cs = 1'b0;
    prev_busy = 1'b0;
    last_nmi_level = 1'b0;
    prev_frame_done = 1'b0;
    freeze_state = 7'd0;
    freeze_pc = 16'h0000;
    freeze_valid = 1'b0;
    bus_ce_active_snap = 1'b0;
    bus_ce_wait_snap = 8'd0;
    saw_reset_lo = 1'b0;
    saw_reset_hi = 1'b0;
    saw_first_fetch = 1'b0;
    saw_first_opcode = 1'b0;
    saw_fetch_bus = 1'b0;
    reset_lo_addr = 16'h0000;
    reset_hi_addr = 16'h0000;
    frame_count = 0;
    clk_count = 0;
    check_enable = 1'b0;
    checked_bg = 0;
    checked_tile1 = 0;
    checked_sprite = 0;
    visible_pixels = 0;
    vblank_rise = 0;
    vblank_fall = 0;
    prev_vblank = 1'b0;
    frame_mark = 0;
    frame_delta = 0;
    have_frame_mark = 1'b0;
    prev_dot = 9'd340;
    for (hk = 0; hk < 16; hk = hk + 1) begin
        stk_rd[hk] = 0;
        stk_wr[hk] = 0;
    end
    #1;
    reset = 1'b1;

    for (pc = 0; pc < PRG_SIZE_BYTES; pc = pc + 1)
        dut.prg_rom[pc] = 8'h00;
    build_main;
    build_nmi_handler;
    build_irq_handler;
    build_init_routine;
    build_fail_loop;
    build_vectors;
    build_tables;
    load_video_ram;
    pc = 16'hFFFF;

    repeat (4) @(posedge clk);
    #1;
    check_reset_state;

    @(negedge clk);
    reset = 1'b0;
    #1;

    wait (frame_count == FRAME_TARGET);
    #100;

    if (seen_main_loop !== 1'b1)
        $fatal(1, "the cpu never reached the self loop in the main program");
    if (ram_wr_nmi != (nmi_entry_count + 1))
        $fatal(1, "writes to the nmi counter cell got %0d expected %0d",
               ram_wr_nmi, nmi_entry_count + 1);
    if (ram_wr_irq != (irq_entry_count + 1))
        $fatal(1, "writes to the irq counter cell got %0d expected %0d",
               ram_wr_irq, irq_entry_count + 1);
    if (ram_wr_open != 2)
        $fatal(1, "writes to the open bus cell got %0d expected 2", ram_wr_open);
    if (ram_wr_setup != 2)
        $fatal(1, "the guard flag cell was written %0d times, expected 2", ram_wr_setup);
    if (ram_wr_dma1 != 2 || ram_wr_dma2 != 2 || ram_wr_dma3 != 2)
        $fatal(1, "the dma flag cells were written %0d/%0d/%0d times, expected 2 each",
               ram_wr_dma1, ram_wr_dma2, ram_wr_dma3);
    if (ram_wr_oamrb != 2)
        $fatal(1, "the oam readback flag cell was written %0d times, expected 2",
               ram_wr_oamrb);
    if (apu_wr_status != (1 + apu_rd_4015))
        $fatal(1, "the irq handler did not ack every $4015 it read, wr=%0d rd=%0d",
               apu_wr_status, apu_rd_4015);

    check_cpu_reset_sequence;
    check_wait_path;
    check_owner_accounting;
    check_dma_transfers;
    check_oam_content;
    check_ppu_registers;
    check_apu_registers;
    check_ppu_state;
    $display("PRG main $8000-$%04h (%0d bytes), nmi handler $8400-$%04h, irq handler $8500-$%04h, init routine $8600-$%04h (%0d bytes), fail loop $8800, tables $8900 and $8a00, vectors fffa=$8400 fffc=$8000 fffe=$8500",
             main_prog_end - 16'd1, main_prog_end - MAIN_PROG, nmi_end - 16'd1,
             irq_end - 16'd1, init_end - 16'd1, init_end - INIT_ROUTINE);
    check_interrupts;
    check_audio;
    check_frames;

    $display("PASS nes_system_v3");
    $finish;
end

initial begin
    #40000000;
    $fatal(1, "global timeout");
end

endmodule
