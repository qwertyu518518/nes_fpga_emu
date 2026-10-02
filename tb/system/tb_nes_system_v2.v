`timescale 1ns/1ps

module tb_nes_system_v2;

localparam PRG_SIZE_BYTES = 16384;
localparam PRG_INDEX_BITS = $clog2(PRG_SIZE_BYTES);
localparam [15:0] NMI_HANDLER = 16'h8400;
localparam [15:0] NMI_HANDLER_LAST = 16'h841F;
localparam [15:0] IRQ_HANDLER = 16'h8500;
localparam [15:0] IRQ_HANDLER_LAST = 16'h851F;
localparam [15:0] SETUP_ROUTINE = 16'h8600;
localparam [15:0] SETUP_ROUTINE_LAST = 16'h87FF;
localparam [15:0] FAIL_LOOP = 16'h8800;
localparam [15:0] MAIN_PROG = 16'h8000;
localparam [15:0] NMI_COUNTER_CELL = 16'h0010;
localparam [15:0] IRQ_COUNTER_CELL = 16'h0011;
localparam [15:0] SETUP_FLAG_CELL = 16'h0012;
localparam [15:0] OPEN_BUS_CELL = 16'h0013;
localparam [2:0] OWNER_OPEN = 3'd0;
localparam [2:0] OWNER_RAM = 3'd1;
localparam [2:0] OWNER_PPU = 3'd2;
localparam [2:0] OWNER_APU_IO = 3'd3;
localparam [2:0] OWNER_CART_RAM = 3'd4;
localparam [2:0] OWNER_CART_ROM = 3'd5;
localparam integer FRAME_TARGET = 3;

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

integer frame_count;
integer clk_count;
integer frame_mark;
integer frame_delta;
integer have_frame_mark;
integer prev_frame_done;
integer prev_vblank;
integer vblank_rise;
integer vblank_fall;
integer check_enable;
integer checked_bg;
integer checked_tile1;
integer checked_sprite;
integer visible_pixels;

integer bus_fire_count;
integer stall_cycles;
integer transfer_stall_expect;
integer transfer_had_stall;
integer prg_rd;
integer ram_rd;
integer ram_wr;
integer ppu_rd;
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
integer apu_wr_other;
integer apu_rd_other;
integer apu_wr_4015;
integer apu_rd_4015;
integer ram_wr_nmi;
integer ram_wr_irq;
integer ram_wr_open;
integer ram_wr_setup;
integer frame_push;
integer jsr_frame;
integer stk_rd [0:15];
integer stk_wr [0:15];
integer hk;
integer nmi_rise_count;
integer irq_rise_count;
integer irq_fall_count;
integer nmi_entry_count;
integer irq_entry_count;
integer sample_strobes;
integer sample_nonzero;
integer ce_pulses;
integer handler_ce;
integer handler_strobes;
integer prev_ppu_cs;
integer prev_apu_cs;
integer illegal_hits;
integer poll_reads;

reg [7:0] prev_xfer_din;
reg [15:0] prev_xfer_addr;
reg prev_xfer_valid;
reg [7:0] last_vblank_flag;
reg saw_reset_lo;
reg saw_reset_hi;
reg saw_first_fetch;
reg saw_fetch_bus;
reg saw_first_opcode;
reg in_nmi_handler;
reg in_irq_handler;
reg in_setup_routine;
reg in_handler;
reg seen_main_loop;
reg ppu_cs_in_handler;
reg apu_cs_in_handler;
reg [15:0] reset_lo_addr;
reg [15:0] reset_hi_addr;
reg bus_ce_active_snap;
reg [7:0] bus_ce_wait_snap;

nes_system_v2 dut (
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
    .cart_ack(cart_ack)
);

always #5 clk = !clk;

reg [15:0] pc;

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

task lda_abs;
    input [15:0] address;
    begin
        emit(8'hAD);
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

reg [15:0] branch_patch_addr;
reg [15:0] main_prog_end;
reg [15:0] setup_end;

task bne_to;
    input [15:0] target;
    reg [15:0] here;
    begin
        here = pc;
        emit(8'hD0);
        emit(target - (here + 16'd2));
    end
endtask

task bne_patch;
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
        emit(8'hA2);
        emit(8'h08);
        lda_imm(value);
        top = pc;
        sta_abs(16'h2007);
        emit(8'hCA);
        bne_to(top);
    end
endtask

task build_main;
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
        lda_abs(16'h6010);
        cmp_imm(8'h00);
        bne_to(FAIL_LOOP);
        lda_abs(16'h8400);
        cmp_imm(8'hAD);
        bne_to(FAIL_LOOP);
        lda_abs(16'hC400);
        cmp_imm(8'hAD);
        bne_to(FAIL_LOOP);
        lda_abs(16'h4020);
        sta_abs(OPEN_BUS_CELL);
        lda_imm(8'h80);
        sta_abs(16'h2000);
        self_loop = pc;
        jmp_abs(self_loop);
        main_prog_end = pc;
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

task build_nmi_handler;
    reg [15:0] count_part;
    begin
        pc = NMI_HANDLER;
        lda_abs(SETUP_FLAG_CELL);
        cmp_imm(8'h00);
        bne_patch;
        lda_imm(8'h01);
        sta_abs(SETUP_FLAG_CELL);
        jsr_abs(SETUP_ROUTINE);
        count_part = pc;
        patch_bne(count_part);
        lda_abs(NMI_COUNTER_CELL);
        emit(8'h18);
        emit(8'h69);
        emit(8'h01);
        sta_abs(NMI_COUNTER_CELL);
        emit(8'h40);
    end
endtask

task build_setup_routine;
    begin
        pc = SETUP_ROUTINE;
        lda_imm(8'h80);
        sta_abs(16'h2000);
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
        lda_imm(8'h20);
        sta_abs(16'h2004);
        lda_imm(8'h02);
        sta_abs(16'h2004);
        lda_imm(8'h00);
        sta_abs(16'h2004);
        lda_imm(8'h08);
        sta_abs(16'h2004);
        lda_imm(8'h1E);
        sta_abs(16'h2001);
        emit(8'h60);
        setup_end = pc;
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

task load_video_ram;
    integer i;
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
    input [9:0] column;
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

task check_decode;
    input [15:0] address;
    input [2:0] expected_owner;
    input [5:0] expected_sel;
    reg [2:0] decode_owner;
    reg [5:0] decode_sel;
    begin
        if (address[15:13] == 3'b000)
            decode_owner = OWNER_RAM;
        else if (address[15:13] == 3'b001)
            decode_owner = OWNER_PPU;
        else if (address[15:13] == 3'b010)
            decode_owner = ((address[15:5] == 11'h200) ? OWNER_APU_IO : OWNER_OPEN);
        else if (address[15:13] == 3'b011)
            decode_owner = OWNER_CART_RAM;
        else
            decode_owner = OWNER_CART_ROM;
        decode_sel = {sel_cart_rom, sel_cart_ram, sel_open_bus,
                      sel_apu_io, sel_ppu, sel_ram};
        if (decode_owner !== expected_owner)
            $fatal(1, "owner for %04h got %0d expected %0d",
                   address, decode_owner, expected_owner);
        if (decode_sel !== expected_sel)
            $fatal(1, "sel word for %04h got %b expected %b",
                   address, decode_sel, expected_sel);
    end
endtask

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
            $fatal(1, "bus active flag did not reset, got %b wait=%0d req=%b ce=%b",
                   bus_active, bus_wait_count, bus_req, dut.div_phase);
        if (bus_wait_count !== 8'd0)
            $fatal(1, "bus wait count is %0d during reset", bus_wait_count);
        if (bus_req !== 1'b0)
            $fatal(1, "bus_req is high during reset");
        if (bus_fire !== 1'b0)
            $fatal(1, "bus_fire is high during reset");
        if (dut.u_cpu.dbg_state !== 7'd0)
            $fatal(1, "cpu state is %0d during reset", dut.u_cpu.dbg_state);
        if (dut.u_ppu.mask_reg !== 8'h00)
            $fatal(1, "ppumask is %02h during reset", dut.u_ppu.mask_reg);
        if (dut.u_apu.dbg_frame_count !== 16'd0)
            $fatal(1, "apu frame count is %0d during reset",
                   dut.u_apu.dbg_frame_count);
        $display("RESET ppu=0:0 frame/vblank/nmi/irq/sample low, bus idle, cpu state 0 PASS");
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
        $display("WAIT completed transfers=%0d stalled=%0d immediate=%0d (all of them, on every owner) PASS",
                 bus_fire_count, bus_fire_count - immediate_count, immediate_count);
    end
endtask

integer immediate_count;

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
        if (prg_wr != 0)
            $fatal(1, "unexpected writes to the prg window: %0d", prg_wr);
        $display("BUS owner accounting prg_rd=%0d ram_rd=%0d ram_wr=%0d ppu_rd=%0d ppu_wr=%0d apu_rd=%0d apu_wr=%0d open_rd=%0d cartram_rd=%0d, the five reset dummies are counted as ram reads PASS",
                 prg_rd, ram_rd, ram_wr, ppu_rd, ppu_wr, apu_rd, apu_wr,
                 open_rd, cartram_rd);
    end
endtask

task check_ppu_registers;
    begin
        if (ppu_wr_ctrl != 3)
            $fatal(1, "ppuctrl write count got %0d expected 3", ppu_wr_ctrl);
        if (ppu_wr_mask != 2)
            $fatal(1, "ppumask write count got %0d expected 2", ppu_wr_mask);
        if (ppu_wr_status != 0)
            $fatal(1, "ppustatus was written %0d times", ppu_wr_status);
        if (ppu_wr_oamaddr != 1)
            $fatal(1, "oamaddr write count got %0d expected 1", ppu_wr_oamaddr);
        if (ppu_wr_oamdata != 4)
            $fatal(1, "oamdata write count got %0d expected 4", ppu_wr_oamdata);
        if (ppu_wr_vaddr != 18)
            $fatal(1, "ppuaddr write count got %0d expected 18", ppu_wr_vaddr);
        if (ppu_wr_vdata != 45)
            $fatal(1, "ppudata write count got %0d expected 45", ppu_wr_vdata);
        if (ppu_wr_other != 0)
            $fatal(1, "unexpected writes to other ppu registers: %0d", ppu_wr_other);
        if (poll_reads != 0)
            $fatal(1, "the program read $2002 %0d times, the vblank window must stay intact", poll_reads);
        if (ppu_rd != 0)
            $fatal(1, "the system performed %0d ppu register reads, expected none", ppu_rd);
        if (ppu_cs_in_handler)
            $fatal(1, "a ppu register transfer happened inside the irq handler");
        $display("PPUREG writes ctrl=%0d mask=%0d vaddr=%0d vdata=%0d oamaddr=%0d oamdata=%0d status=%0d other=%0d, reads=%0d, no ppu access inside the irq handler PASS",
                 ppu_wr_ctrl, ppu_wr_mask, ppu_wr_vaddr, ppu_wr_vdata,
                 ppu_wr_oamaddr, ppu_wr_oamdata, ppu_wr_status, ppu_wr_other,
                 ppu_rd);
    end
endtask

task check_apu_registers;
    begin
        if (apu_wr_p1 != 1 || apu_wr_p1b != 1 || apu_wr_p1c != 1 || apu_wr_p1d != 1)
            $fatal(1, "pulse1 register write counts got %0d/%0d/%0d/%0d expected 1 each",
                   apu_wr_p1, apu_wr_p1b, apu_wr_p1c, apu_wr_p1d);
        if (apu_wr_frame != 1)
            $fatal(1, "apu $4017 write count got %0d expected 1", apu_wr_frame);
        if (apu_wr_status != (1 + irq_entry_count))
            $fatal(1, "apu $4015 write count got %0d expected %0d",
                   apu_wr_status, 1 + irq_entry_count);
        if (apu_rd_4015 != irq_entry_count)
            $fatal(1, "apu $4015 read count got %0d expected %0d",
                   apu_rd_4015, irq_entry_count);
        if (apu_wr_other != 0 || apu_rd_other != 0)
            $fatal(1, "unexpected apu transfers: wr=%0d rd=%0d",
                   apu_wr_other, apu_rd_other);
        if (apu_cs_in_handler && nmi_entry_count > 0)
            $fatal(1, "an apu register transfer happened inside the nmi handler");
        $display("APUREG writes $4000-$4003=1 each, $4017=1, $4015=%0d, reads $4015=%0d, no apu access inside the nmi handler PASS",
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
            $fatal(1, "irq rises %0d do not match falls %0d",
                   irq_rise_count, irq_fall_count);
        if (nmi_rise_count != nmi_entry_count)
            $fatal(1, "nmi edges %0d do not match handler entries %0d",
                   nmi_rise_count, nmi_entry_count);
        if (irq_rise_count != irq_entry_count)
            $fatal(1, "irq edges %0d do not match handler entries %0d",
                   irq_rise_count, irq_entry_count);
        if (dut.u_bus.ram_array[NMI_COUNTER_CELL[10:0]] != nmi_entry_count[7:0])
            $fatal(1, "nmi counter cell is %02x expected %0d",
                   dut.u_bus.ram_array[NMI_COUNTER_CELL[10:0]], nmi_entry_count);
        if (dut.u_bus.ram_array[IRQ_COUNTER_CELL[10:0]] != irq_entry_count[7:0])
            $fatal(1, "irq counter cell is %02x expected %0d",
                   dut.u_bus.ram_array[IRQ_COUNTER_CELL[10:0]], irq_entry_count);
        if (frame_push != 3 * (nmi_entry_count + irq_entry_count))
            $fatal(1, "interrupt frame pushes got %0d expected %0d",
                   frame_push, 3 * (nmi_entry_count + irq_entry_count));
        if (stk_wr[4'd8] != 1 || stk_wr[4'd9] != 1 || jsr_frame != 2)
            $fatal(1, "the setup routine was entered %0d/%0d/%0d times, expected once",
                   stk_wr[4'd9], stk_wr[4'd8], jsr_frame);
        if (stk_rd[4'd11] != (nmi_entry_count + irq_entry_count))
            $fatal(1, "status restores from $01FB got %0d expected %0d",
                   stk_rd[4'd11], nmi_entry_count + irq_entry_count);
        if (stk_rd[4'd12] != (nmi_entry_count + irq_entry_count))
            $fatal(1, "pc low restores from $01FC got %0d expected %0d",
                   stk_rd[4'd12], nmi_entry_count + irq_entry_count);
        if (stk_rd[4'd10] < (nmi_entry_count + irq_entry_count))
            $fatal(1, "frame reads from $01FA got %0d expected at least %0d",
                   stk_rd[4'd10], nmi_entry_count + irq_entry_count);
        if (apu_irq_o !== 1'b0)
            $fatal(1, "apu_irq_o is still high at the end, the handler never acked");
        if (dut.u_cpu.dbg_nmi_pending !== 1'b0)
            $fatal(1, "nmi is still pending at the end");
        if (apu_irq_o !== dut.u_cpu.dbg_irq_pending)
            $fatal(1, "dbg_irq_pending does not follow apu_irq_o");
        $display("IRQ nmi rises=%0d handler entries=%0d ram[0010]=%02x, apu irq rises=%0d falls=%0d entries=%0d ram[0011]=%02x PASS",
                 nmi_rise_count, nmi_entry_count,
                 dut.u_bus.ram_array[NMI_COUNTER_CELL[10:0]],
                 irq_rise_count, irq_fall_count, irq_entry_count,
                 dut.u_bus.ram_array[IRQ_COUNTER_CELL[10:0]]);
        $display("STACK every entry pushed pch/pcl/p to 01fa-01fc (%0d frames of 3) and the rti pulled p and the pc low byte back (%0d and %0d), the setup jsr/rts touched 01f8-01f9 once",
                 frame_push, stk_rd[4'd11], stk_rd[4'd12]);
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
            $fatal(1, "pulse1 length is %0d expected 160",
                   dut.u_apu.dbg_pulse1_length);
        if (dut.u_apu.dbg_pulse1_mute !== 1'b0)
            $fatal(1, "pulse1 is muted");
        $display("AUDIO ce pulses=%0d sample strobes=%0d nonzero=%0d peak=%0d, strobes inside handlers=%0d/%0d PASS",
                 ce_pulses, sample_strobes, sample_nonzero, sample_peak,
                 handler_strobes, handler_ce);
    end
endtask

integer sample_peak;

task check_ppu_state;
    integer i;
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
        for (i = 0; i < 8; i = i + 1)
            if (dut.u_ppu.chr_ram[i] !== 8'hFF)
                $fatal(1, "chr[%0d] is %02x expected ff, the cpu ppudata write did not land",
                       i, dut.u_ppu.chr_ram[i]);
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
        if (dut.u_ppu.oam_ram[0] !== 8'h20)
            $fatal(1, "oam[0] is %02x expected 20", dut.u_ppu.oam_ram[0]);
        if (dut.u_ppu.oam_ram[1] !== 8'h02)
            $fatal(1, "oam[1] is %02x expected 02", dut.u_ppu.oam_ram[1]);
        if (dut.u_ppu.oam_ram[2] !== 8'h00)
            $fatal(1, "oam[2] is %02x expected 00", dut.u_ppu.oam_ram[2]);
        if (dut.u_ppu.oam_ram[3] !== 8'h08)
            $fatal(1, "oam[3] is %02x expected 08", dut.u_ppu.oam_ram[3]);
        $display("PPUSTATE ctrl=80 mask=1E v=0000 t=0000 w=0, chr[0:7]=ff [8:15]=00 [16:23]=00 [24:31]=ff [32:39]=ff [40:47]=00, nt[1]=01, pal=0f,21,32 and 11=16, oam=20,02,00,08 PASS");
    end
endtask

task check_open_bus_capture;
    begin
        if (dut.u_bus.ram_array[OPEN_BUS_CELL[10:0]] !== 8'h40)
            $fatal(1, "open bus capture cell is %02x expected 40",
                   dut.u_bus.ram_array[OPEN_BUS_CELL[10:0]]);
        $display("OPENBUS $4020 returned the previous completed transfer (40) and $6010 in the cart ram window returned 00 PASS");
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
    end else begin

        if (dut.div_phase == 4'd0) begin
            if (bus_stall !== (bus_req && !bus_fire))
                $fatal(1, "bus_stall got %b expected %b at %04h",
                       bus_stall, (bus_req && !bus_fire), bus_addr);
            if (bus_req && !bus_fire) begin
                stall_cycles = stall_cycles + 1;
                if (sel_open_bus !== 1'b0)
                    $fatal(1, "the open bus window stalled at %04h", bus_addr);
                if (stall_cycles > 1 && bus_active !== 1'b1)
                    $fatal(1, "a continued stall is not marked active at %04h", bus_addr);
            end else if (bus_fire) begin
                // CONTRACT CHANGE, 2x cpu rate.  This used to be
                // (sel_open_bus === 1'b1) ? 0 : 1, i.e. every owner except the
                // open bus window was REQUIRED to spend a second ce_cpu beat
                // stalling, which is the defect this contract now forbids.  ce_cpu
                // IS the cpu cycle (div_phase == 4'd0, twelve clk, three ppu
                // dots) and this core instantiates READ_WAIT_CYCLES = 8'd1, so a
                // wait of one beat is this cpu cycle and not an extra one.  Every
                // owner now completes on the first ce_cpu beat of its request.
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
                // arms it, so active must now be LOW here: that is the other half
                // of the same contract change, moved and not deleted.
                if (bus_active !== 1'b0)
                    $fatal(1, "the completing cycle of %04h is marked active, a zero stall access must never arm the wait state", bus_addr);
                immediate_count = immediate_count + 1;
                stall_cycles = 0;
            end
        end
    end
end

always @(posedge clk) begin
    if (reset) begin
        bus_fire_count = 0;
        prg_rd = 0;
        ram_rd = 0;
        ram_wr = 0;
        ppu_rd = 0;
        ppu_wr = 0;
        apu_rd = 0;
        apu_wr = 0;
        open_rd = 0;
        cartram_rd = 0;
        cartram_wr = 0;
        prg_wr = 0;
        prev_xfer_valid = 1'b0;
    end else begin
        check_decode(bus_addr, bus_owner, {sel_cart_rom, sel_cart_ram, sel_open_bus,
                                           sel_apu_io, sel_ppu, sel_ram});
        if (ppu_reg_cs !== 1'b0) begin
            if (sel_ppu !== 1'b1 || bus_fire !== 1'b1)
                $fatal(1, "ppu_reg_cs asserted without a completed ppu transfer at %04h", bus_addr);
            if (prev_ppu_cs !== 1'b0)
                $fatal(1, "ppu_reg_cs was high for two clk in a row");
            if (in_irq_handler)
                ppu_cs_in_handler = 1'b1;
        end
        if (apu_reg_cs !== 1'b0) begin
            if (sel_apu_io !== 1'b1 || bus_fire !== 1'b1)
                $fatal(1, "apu_reg_cs asserted without a completed apu transfer at %04h", bus_addr);
            if (prev_apu_cs !== 1'b0)
                $fatal(1, "apu_reg_cs was high for two clk in a row");
            if (apu_reg_addr > 5'h17)
                $fatal(1, "apu_reg_cs outside $4000-$4017, reg_addr=%02x", apu_reg_addr);
            if (in_nmi_handler || in_setup_routine)
                apu_cs_in_handler = 1'b1;
        end
        if (cart_xfer !== 1'b0) begin
            if (bus_fire !== 1'b1)
                $fatal(1, "cart_xfer asserted without a completed transfer at %04h", bus_addr);
            if (sel_cart_rom !== 1'b1 && sel_cart_ram !== 1'b1)
                $fatal(1, "cart_xfer asserted outside the cartridge windows");
        end
        if (cart_req !== 1'b0 && (sel_cart_rom !== 1'b1 && sel_cart_ram !== 1'b1))
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

        if (bus_fire) begin
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
                        OPEN_BUS_CELL[10:0]: ram_wr_open = ram_wr_open + 1;
                        11'h1F8, 11'h1F9: begin
                            jsr_frame = jsr_frame + 1;
                        end
                        11'h1FA, 11'h1FB, 11'h1FC: frame_push = frame_push + 1;
                        default: begin
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
                    if (ppu_reg_addr !== 3'd2)
                        $fatal(1, "unexpected ppu register read at %04h reg %0d",
                               bus_addr, ppu_reg_addr);
                    poll_reads = poll_reads + 1;
                end
            end else if (sel_apu_io === 1'b1) begin
                if (bus_we) begin
                    apu_wr = apu_wr + 1;
                    case (apu_reg_addr)
                        5'h00: apu_wr_p1 = apu_wr_p1 + 1;
                        5'h01: apu_wr_p1b = apu_wr_p1b + 1;
                        5'h02: apu_wr_p1c = apu_wr_p1c + 1;
                        5'h03: apu_wr_p1d = apu_wr_p1d + 1;
                        5'h15: begin
                            apu_wr_status = apu_wr_status + 1;
                            apu_wr_4015 = apu_wr_4015 + 1;
                        end
                        5'h17: apu_wr_frame = apu_wr_frame + 1;
                        default: apu_wr_other = apu_wr_other + 1;
                    endcase
                end else begin
                    apu_rd = apu_rd + 1;
                    if (apu_reg_addr == 5'h15) begin
                        apu_rd_4015 = apu_rd_4015 + 1;
                    end else begin
                        apu_rd_other = apu_rd_other + 1;
                    end
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
                    if (dut.prg_index !== bus_addr[PRG_INDEX_BITS-1:0])
                        $fatal(1, "prg index %04x does not follow addr %04h",
                               dut.prg_index, bus_addr);
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
        nmi_rise_count = 0;
        irq_rise_count = 0;
        irq_fall_count = 0;
        nmi_entry_count = 0;
        irq_entry_count = 0;
        last_vblank_flag = 1'b0;
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
        saw_fetch_bus = 1'b0;
        saw_first_opcode = 1'b0;
        seen_main_loop = 1'b0;
        in_nmi_handler = 1'b0;
        in_irq_handler = 1'b0;
        in_setup_routine = 1'b0;
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
                $fatal(1, "the cpu entered the failure loop at %04h", FAIL_LOOP);
            if ((dut.u_cpu.dbg_pc < 16'h8000) || (dut.u_cpu.dbg_pc > FAIL_LOOP + 16'd2))
                $fatal(1, "the cpu left the prg program area, pc=%04h state=%0d p=%02x sp=%02x last_xfer=%04h",
                       dut.u_cpu.dbg_pc, dut.u_cpu.dbg_state, dut.u_cpu.dbg_p,
                       dut.u_cpu.dbg_sp, prev_xfer_addr);
            if ((dut.u_cpu.dbg_pc >= main_prog_end) && (dut.u_cpu.dbg_pc < NMI_HANDLER))
                $fatal(1, "the cpu ran in an unprogrammed gap, pc=%04h", dut.u_cpu.dbg_pc);
            if ((dut.u_cpu.dbg_pc > NMI_HANDLER_LAST) && (dut.u_cpu.dbg_pc < IRQ_HANDLER))
                $fatal(1, "the cpu ran past the nmi handler, pc=%04h", dut.u_cpu.dbg_pc);
            if ((dut.u_cpu.dbg_pc > IRQ_HANDLER_LAST) && (dut.u_cpu.dbg_pc < SETUP_ROUTINE))
                $fatal(1, "the cpu ran past the irq handler, pc=%04h", dut.u_cpu.dbg_pc);
            if ((dut.u_cpu.dbg_pc > SETUP_ROUTINE_LAST) && (dut.u_cpu.dbg_pc < FAIL_LOOP))
                $fatal(1, "the cpu ran past the setup routine, pc=%04h", dut.u_cpu.dbg_pc);
        end

        in_nmi_handler = (dut.u_cpu.dbg_pc >= NMI_HANDLER) &&
                         (dut.u_cpu.dbg_pc <= NMI_HANDLER_LAST);
        in_irq_handler = (dut.u_cpu.dbg_pc >= IRQ_HANDLER) &&
                         (dut.u_cpu.dbg_pc <= IRQ_HANDLER_LAST);
        in_setup_routine = (dut.u_cpu.dbg_pc >= SETUP_ROUTINE) &&
                           (dut.u_cpu.dbg_pc <= SETUP_ROUTINE_LAST);
        in_handler = in_nmi_handler || in_irq_handler || in_setup_routine;
        if (in_handler && (dut.u_cpu.dbg_state < 7'd42)) begin
            if (dut.u_cpu.dbg_p[2] !== 1'b1)
                $fatal(1, "i flag is clear inside a handler, p=%02x pc=%04h state=%0d op=%02x sp=%02x last=%04h",
                       dut.u_cpu.dbg_p, dut.u_cpu.dbg_pc, dut.u_cpu.dbg_state,
                       dut.u_cpu.dbg_opcode, dut.u_cpu.dbg_sp, prev_xfer_addr);
            if (dut.u_cpu.dbg_sp > 8'hFA)
                $fatal(1, "sp=%02x inside a handler at pc=%04h",
                       dut.u_cpu.dbg_sp, dut.u_cpu.dbg_pc);
        end
        if (dut.u_cpu.dbg_state === 7'd7 && bus_fire === 1'b1) begin
            if (in_handler) begin
                seen_main_loop = 1'b1;
            end else begin
                if (saw_first_opcode === 1'b1 && dut.u_cpu.dbg_p[2] !== 1'b0)
                    $fatal(1, "i flag is set outside a handler, p=%02x pc=%04h",
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
            if (dut.u_apu.dbg_frame_irq !== 1'b0 && dut.u_apu.dbg_dmc_irq !== 1'b0)
                $fatal(1, "apu irq asserted but neither flag is set");
            if (dut.u_apu.dbg_dmc_irq !== 1'b0)
                $fatal(1, "dmc irq asserted, dmc dma is not wired up");
            if (last_vblank_flag === 1'b0) begin
                irq_rise_count = irq_rise_count + 1;
                last_vblank_flag = 1'b1;
            end
        end else begin
            if (last_vblank_flag === 1'b1) begin
                last_vblank_flag = 1'b0;
                irq_fall_count = irq_fall_count + 1;
            end
        end
        if (apu_irq_o !== dut.u_apu.dbg_frame_irq && dut.u_apu.dbg_dmc_irq === 1'b0)
            $fatal(1, "apu_irq_o does not follow dbg_frame_irq");
    end
end

always @(posedge clk or posedge reset) begin
    if (reset)
        last_nmi_level <= 1'b0;
    else
        last_nmi_level <= nmi_o;
end

reg last_nmi_level;
reg last_frame_done;
reg [8:0] prev_dot;
reg expected_vblank;
reg [3:0] expected_index;

always @(posedge clk) begin
    #1;
    if (reset) begin
        last_frame_done = 1'b0;
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
        clk_count = 0;
    end else begin
        if (frame_done !== 1'b0) begin
            if (ppu_scanline !== 9'd0 || ppu_dot !== 9'd0)
                $fatal(1, "frame_done asserted at %0d:%0d", ppu_scanline, ppu_dot);
        end
        if ((frame_done === 1'b1) && (last_frame_done !== 1'b1)) begin
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
        last_frame_done = frame_done;

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
    frame_count = 0;
    clk_count = 0;
    prev_frame_done = 1'b0;
    prev_vblank = 1'b0;
    bus_fire_count = 0;
    stall_cycles = 0;
    transfer_stall_expect = 0;
    transfer_had_stall = 1'b0;
    immediate_count = 0;
    prg_rd = 0;
    ram_rd = 0;
    ram_wr = 0;
    ppu_rd = 0;
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
    apu_wr_other = 0;
    apu_rd_other = 0;
    apu_wr_4015 = 0;
    apu_rd_4015 = 0;
    ram_wr_nmi = 0;
    ram_wr_irq = 0;
    ram_wr_open = 0;
    ram_wr_setup = 0;
    frame_push = 0;
    jsr_frame = 0;
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
    poll_reads = 0;
    ppu_cs_in_handler = 1'b0;
    apu_cs_in_handler = 1'b0;
    prev_ppu_cs = 1'b0;
    prev_apu_cs = 1'b0;
    prev_xfer_valid = 1'b0;
    prev_xfer_din = 8'h00;
    prev_xfer_addr = 16'h0000;
    last_vblank_flag = 1'b0;
    seen_main_loop = 1'b0;
    in_nmi_handler = 1'b0;
    in_irq_handler = 1'b0;
    in_setup_routine = 1'b0;
    in_handler = 1'b0;
    saw_reset_lo = 1'b0;
    saw_reset_hi = 1'b0;
    saw_first_fetch = 1'b0;
    saw_fetch_bus = 1'b0;
    saw_first_opcode = 1'b0;
    reset_lo_addr = 16'h0000;
    reset_hi_addr = 16'h0000;
    check_enable = 1'b0;
    checked_bg = 0;
    checked_tile1 = 0;
    checked_sprite = 0;
    visible_pixels = 0;
    vblank_rise = 0;
    vblank_fall = 0;
    frame_mark = 0;
    frame_delta = 0;
    have_frame_mark = 1'b0;
    prev_dot = 9'd340;
    last_nmi_level = 1'b0;
    last_frame_done = 1'b0;
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
    build_setup_routine;
    build_irq_handler;
    build_fail_loop;
    build_vectors;
    load_video_ram;
    pc = 16'hFFFF;

    repeat (4) @(posedge clk);
    #1;
    check_reset_state;
    $display("OWNER the owner and the six sel bits are re-derived from cpu_addr and compared on every clk PASS");

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
    if (ram_wr_open != 1)
        $fatal(1, "writes to the open bus capture cell got %0d expected 1", ram_wr_open);
    if (ram_wr_setup != 2)
        $fatal(1, "the guard flag cell was written %0d times, expected the program clear plus one handler set", ram_wr_setup);
    if (apu_wr_status != (1 + apu_rd_4015))
        $fatal(1, "the irq handler did not ack every $4015 it read, wr=%0d rd=%0d",
               apu_wr_status, apu_rd_4015);

    check_cpu_reset_sequence;
    check_wait_path;
    check_owner_accounting;
    check_ppu_registers;
    check_apu_registers;
    check_open_bus_capture;
    check_ppu_state;
    $display("PRG main $8000-$%04h (%0d bytes), nmi handler $8400, setup routine $8600-$%04h (%0d bytes), irq handler $8500, fail loop $8800, vectors fffa=$8400 fffc=$8000 fffe=$8500",
             main_prog_end - 16'd1, main_prog_end - MAIN_PROG, setup_end - 16'd1,
             setup_end - SETUP_ROUTINE);
    check_interrupts;
    check_audio;
    check_frames;

    $display("PASS nes_system_v2");
    $finish;
end

initial begin
    #40000000;
    $fatal(1, "global timeout");
end

endmodule
