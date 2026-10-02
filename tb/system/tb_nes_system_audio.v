`timescale 1ns/1ps

module tb_nes_system_audio;

localparam PRG_SIZE_BYTES = 16384;
localparam PRG_INDEX_BITS = $clog2(PRG_SIZE_BYTES);
localparam [14:0] PRG_WINDOW_MASK = 15'h7FFF >> (15 - PRG_INDEX_BITS);
localparam [14:0] PRG_RESET_VECTOR_IDX = 16'hFFFC & PRG_WINDOW_MASK;
localparam [14:0] PRG_RESET_VECTOR_HI_IDX = 16'hFFFD & PRG_WINDOW_MASK;
localparam [14:0] PRG_NMI_VECTOR_IDX = 16'hFFFA & PRG_WINDOW_MASK;
localparam [14:0] PRG_NMI_VECTOR_HI_IDX = 16'hFFFB & PRG_WINDOW_MASK;
localparam [14:0] PRG_IRQ_VECTOR_IDX = 16'hFFFE & PRG_WINDOW_MASK;
localparam [14:0] PRG_IRQ_VECTOR_HI_IDX = 16'hFFFF & PRG_WINDOW_MASK;
localparam [15:0] MAIN_LOOP = 16'h8046;
localparam [15:0] FAIL_LOOP = 16'h8049;
localparam [15:0] IRQ_HANDLER = 16'h8200;
localparam [15:0] IRQ_COUNTER = 16'h0010;
localparam [15:0] STACK_PC_HI = 16'h01FC;
localparam [15:0] STACK_PC_LO = 16'h01FB;
localparam [15:0] STACK_P = 16'h01FA;
localparam FRAME_PERIOD_CLK = 357368;
localparam FRAME_COUNT_TARGET = 3;
localparam IRQ_ENTRIES_EXPECTED = 2;
localparam FRAME_IRQ_CE_PERIOD = 29830;
localparam FRAME_IRQ_CE_TRIGGER = 29829;
localparam FRAME_COUNTER_HOLD = 29829;
localparam IRQ_ENTRY_CPU_CYCLES = 7;
localparam [10:0] EXPECTED_PULSE1_PERIOD = 11'h020;
localparam [7:0] EXPECTED_PULSE1_LENGTH_MIN = 8'd140;
localparam [7:0] EXPECTED_PULSE1_LENGTH = 8'd160;

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
wire oam_dma_req;
wire [7:0] oam_dma_count;
wire [31:0] cpu_cycle;
wire [8:0] ppu_dot;
wire [8:0] ppu_scanline;

reg prev_frame_done;
reg prev_vblank;
reg prev_apu_irq;
reg prev_apu_reg_cs;
reg prev_frame_irq;
reg prev_dmc_irq;
reg saw_first_fetch;
reg saw_fetch_bus;
reg saw_first_opcode;
reg saw_reset_lo;
reg saw_reset_hi;
reg handler_active;
reg handler_status_read;
reg irq_taken_pending;
reg [7:0] status_read_value;
reg [15:0] mixed_sample_prev;
reg [5:0] pulse_sum_prev;
reg [7:0] tnd_sum_prev;
reg [15:0] frame_irq_ce_mark;
reg [7:0] expected_vblank;
reg [7:0] expected_nmi;

integer clk_count;
integer frame_count;
integer frame_mark;
integer frame_clk_delta;
integer cpu_bus_count;
integer cpu_bus_count_mapped;
integer rd_ram;
integer wr_ram;
integer rd_ppu;
integer wr_ppu;
integer rd_apu;
integer wr_apu;
integer rd_openbus;
integer rd_prg;
integer apu_ce_count;
integer sample_valid_count;
integer sample_nonzero_count;
integer sample_lut_checks;
integer sample_max;
integer apu_wr_total;
integer apu_rd_total;
integer apu_wr_4000;
integer apu_wr_4001;
integer apu_wr_4002;
integer apu_wr_4003;
integer apu_wr_4014;
integer apu_wr_4015;
integer apu_wr_4017;
integer apu_wr_other;
integer apu_rd_4014;
integer apu_rd_4015;
integer apu_rd_4018;
integer apu_rd_401f;
integer apu_rd_other;
integer oam_dma_req_count;
integer outside_apu_read;
integer ppu_wr_total;
integer ppu_wr_ctrl;
integer ppu_wr_mask;
integer ppu_wr_other;
integer ppu_rd_total;
integer prg_rd_upper;
integer prg_rd_fffa;
integer prg_rd_fffb;
integer prg_rd_fffc;
integer prg_rd_fffd;
integer prg_rd_fffe;
integer prg_rd_ffff;
integer ram_wr_total;
integer ram_wr_counter;
integer ram_wr_counter_nonzero;
integer ram_push_pc_hi;
integer ram_push_pc_lo;
integer ram_push_p;
integer ram_push_p_brk;
integer irq_entry_count;
integer irq_take_cycle;
integer irq_entry_cycle_delta;
integer irq_ack_count;
integer apu_irq_rise_count;
integer apu_irq_fall_count;
integer frame_irq_rise_count;
integer frame_irq_ce_delta;
integer frame_irq_ce_delta_count;
integer handler_sample_strobes;
integer handler_ce_count;
integer max_frame_count;
integer level15_count;
integer vblank_rise_count;
integer vblank_fall_count;
integer clear_index;
integer have_frame_mark;
integer rate_frames;
integer rate_bad;
integer rate_ce_frame;
integer rate_fire_frame;
integer rate_ce_mark;
integer rate_fire_mark;
integer rate_ce_min;
integer rate_ce_max;
integer rate_fire_min;
integer rate_fire_max;
integer rate_bad_ce;
integer rate_bad_fire;
reg     rate_warm;
integer have_frame_irq_mark;

nes_system_v1 dut (
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
    .oam_dma_req(oam_dma_req),
    .oam_dma_count(oam_dma_count),
    .cpu_cycle(cpu_cycle),
    .ppu_dot(ppu_dot),
    .ppu_scanline(ppu_scanline)
);

always #5 clk = !clk;

function [7:0] prg_mirror_read;
    input [15:0] address;
    begin
        prg_mirror_read = dut.prg_rom[address[PRG_INDEX_BITS-1:0]];
    end
endfunction

function [7:0] ram_mirror_read;
    input [15:0] address;
    begin
        ram_mirror_read = dut.cpu_ram[address[10:0]];
    end
endfunction

function [15:0] ref_pulse_lut;
    input [5:0] index;
    reg [63:0] num;
    reg [63:0] den;
    begin
        if (index == 6'd0) begin
            ref_pulse_lut = 16'd0;
        end else begin
            num = 64'd9588 * 64'd32767 * index;
            den = 64'd100 * (64'd8128 + 64'd100 * index);
            ref_pulse_lut = ((num + (den / 64'd2)) / den);
        end
    end
endfunction

task put_prg_byte;
    input [15:0] address;
    input [7:0] value;
    begin
        dut.prg_rom[address[PRG_INDEX_BITS-1:0]] = value;
    end
endtask

task load_prg_rom;
    begin
        for (clear_index = 0; clear_index < PRG_SIZE_BYTES; clear_index = clear_index + 1)
            dut.prg_rom[clear_index] = 8'h00;
        for (clear_index = 0; clear_index < 2048; clear_index = clear_index + 1)
            dut.cpu_ram[clear_index] = 8'h00;
        dut.prg_rom[PRG_RESET_VECTOR_IDX] = 8'h00;
        dut.prg_rom[PRG_RESET_VECTOR_HI_IDX] = 8'h80;
        dut.prg_rom[PRG_NMI_VECTOR_IDX] = 8'h00;
        dut.prg_rom[PRG_NMI_VECTOR_HI_IDX] = 8'h81;
        dut.prg_rom[PRG_IRQ_VECTOR_IDX] = 8'h00;
        dut.prg_rom[PRG_IRQ_VECTOR_HI_IDX] = 8'h82;
        put_prg_byte(16'h8000, 8'h58);
        put_prg_byte(16'h8001, 8'hA9);
        put_prg_byte(16'h8002, 8'h00);
        put_prg_byte(16'h8003, 8'h8D);
        put_prg_byte(16'h8004, 8'h17);
        put_prg_byte(16'h8005, 8'h40);
        put_prg_byte(16'h8006, 8'hAD);
        put_prg_byte(16'h8007, 8'h15);
        put_prg_byte(16'h8008, 8'h40);
        put_prg_byte(16'h8009, 8'hC9);
        put_prg_byte(16'h800A, 8'h00);
        put_prg_byte(16'h800B, 8'hD0);
        put_prg_byte(16'h800C, 8'h3C);
        put_prg_byte(16'h800D, 8'hA9);
        put_prg_byte(16'h800E, 8'h01);
        put_prg_byte(16'h800F, 8'h8D);
        put_prg_byte(16'h8010, 8'h15);
        put_prg_byte(16'h8011, 8'h40);
        put_prg_byte(16'h8012, 8'hA9);
        put_prg_byte(16'h8013, 8'hBF);
        put_prg_byte(16'h8014, 8'h8D);
        put_prg_byte(16'h8015, 8'h00);
        put_prg_byte(16'h8016, 8'h40);
        put_prg_byte(16'h8017, 8'hA9);
        put_prg_byte(16'h8018, 8'h00);
        put_prg_byte(16'h8019, 8'h8D);
        put_prg_byte(16'h801A, 8'h01);
        put_prg_byte(16'h801B, 8'h40);
        put_prg_byte(16'h801C, 8'hA9);
        put_prg_byte(16'h801D, 8'h20);
        put_prg_byte(16'h801E, 8'h8D);
        put_prg_byte(16'h801F, 8'h02);
        put_prg_byte(16'h8020, 8'h40);
        put_prg_byte(16'h8021, 8'hA9);
        put_prg_byte(16'h8022, 8'h40);
        put_prg_byte(16'h8023, 8'h8D);
        put_prg_byte(16'h8024, 8'h03);
        put_prg_byte(16'h8025, 8'h40);
        put_prg_byte(16'h8026, 8'hA9);
        put_prg_byte(16'h8027, 8'h00);
        put_prg_byte(16'h8028, 8'h8D);
        put_prg_byte(16'h8029, 8'h00);
        put_prg_byte(16'h802A, 8'h20);
        put_prg_byte(16'h802B, 8'h8D);
        put_prg_byte(16'h802C, 8'h01);
        put_prg_byte(16'h802D, 8'h20);
        put_prg_byte(16'h802E, 8'h8D);
        put_prg_byte(16'h802F, 8'h10);
        put_prg_byte(16'h8030, 8'h00);
        put_prg_byte(16'h8031, 8'hAD);
        put_prg_byte(16'h8032, 8'h14);
        put_prg_byte(16'h8033, 8'h40);
        put_prg_byte(16'h8034, 8'hC9);
        put_prg_byte(16'h8035, 8'h00);
        put_prg_byte(16'h8036, 8'hD0);
        put_prg_byte(16'h8037, 8'h11);
        put_prg_byte(16'h8038, 8'hAD);
        put_prg_byte(16'h8039, 8'h18);
        put_prg_byte(16'h803A, 8'h40);
        put_prg_byte(16'h803B, 8'hC9);
        put_prg_byte(16'h803C, 8'h00);
        put_prg_byte(16'h803D, 8'hD0);
        put_prg_byte(16'h803E, 8'h0A);
        put_prg_byte(16'h803F, 8'hAD);
        put_prg_byte(16'h8040, 8'h1F);
        put_prg_byte(16'h8041, 8'h40);
        put_prg_byte(16'h8042, 8'hC9);
        put_prg_byte(16'h8043, 8'h00);
        put_prg_byte(16'h8044, 8'hD0);
        put_prg_byte(16'h8045, 8'h03);
        put_prg_byte(16'h8046, 8'h4C);
        put_prg_byte(16'h8047, 8'h46);
        put_prg_byte(16'h8048, 8'h80);
        put_prg_byte(16'h8049, 8'h4C);
        put_prg_byte(16'h804A, 8'h49);
        put_prg_byte(16'h804B, 8'h80);
        put_prg_byte(16'h8200, 8'hAD);
        put_prg_byte(16'h8201, 8'h15);
        put_prg_byte(16'h8202, 8'h40);
        put_prg_byte(16'h8203, 8'h8D);
        put_prg_byte(16'h8204, 8'h15);
        put_prg_byte(16'h8205, 8'h40);
        put_prg_byte(16'h8206, 8'hAD);
        put_prg_byte(16'h8207, 8'h10);
        put_prg_byte(16'h8208, 8'h00);
        put_prg_byte(16'h8209, 8'h18);
        put_prg_byte(16'h820A, 8'h69);
        put_prg_byte(16'h820B, 8'h01);
        put_prg_byte(16'h820C, 8'h8D);
        put_prg_byte(16'h820D, 8'h10);
        put_prg_byte(16'h820E, 8'h00);
        put_prg_byte(16'h820F, 8'h40);
    end
endtask

task load_video_ram;
    begin
        for (clear_index = 0; clear_index < 8192; clear_index = clear_index + 1)
            dut.u_ppu.chr_ram[clear_index] = 8'h00;
        for (clear_index = 0; clear_index < 2048; clear_index = clear_index + 1)
            dut.u_ppu.nametable_ram[clear_index] = 8'h00;
        for (clear_index = 0; clear_index < 256; clear_index = clear_index + 1)
            dut.u_ppu.oam_ram[clear_index] = 8'h00;
        for (clear_index = 0; clear_index < 32; clear_index = clear_index + 1)
            dut.u_ppu.palette_ram[clear_index] = 8'h00;
    end
endtask

always @(posedge clk) begin
    if (reset)
        clk_count = 0;
    else
        clk_count = clk_count + 1;
end

always @(posedge clk) begin
    if (!reset) begin
        if (dut.ce_cpu) begin
            apu_ce_count = apu_ce_count + 1;
            if (handler_active === 1'b1)
                handler_ce_count = handler_ce_count + 1;
            mixed_sample_prev = dut.u_apu.mixed_sample;
            pulse_sum_prev = dut.u_apu.dbg_pulse_sum;
            tnd_sum_prev = dut.u_apu.dbg_tnd_sum;
        end

        if (dut.u_apu.dbg_frame_count > max_frame_count)
            max_frame_count = dut.u_apu.dbg_frame_count;

        if (dut.u_apu.dbg_frame_irq && !prev_frame_irq) begin
            frame_irq_rise_count = frame_irq_rise_count + 1;
            if (dut.u_apu.dbg_frame_count !== FRAME_IRQ_CE_TRIGGER[15:0])
                $fatal(1, "frame irq asserted with frame count %0d, expected %0d",
                       dut.u_apu.dbg_frame_count, FRAME_IRQ_CE_TRIGGER);
            if (have_frame_irq_mark == 1) begin
                frame_irq_ce_delta = apu_ce_count - frame_irq_ce_mark;
                frame_irq_ce_delta_count = frame_irq_ce_delta_count + 1;
            end else begin
                have_frame_irq_mark = 1;
            end
            frame_irq_ce_mark = apu_ce_count[15:0];
        end
        prev_frame_irq = dut.u_apu.dbg_frame_irq;

        if (apu_irq_o && !prev_apu_irq)
            apu_irq_rise_count = apu_irq_rise_count + 1;
        if (!apu_irq_o && prev_apu_irq)
            apu_irq_fall_count = apu_irq_fall_count + 1;
        prev_apu_irq = apu_irq_o;

        if (dut.u_apu.dbg_dmc_irq && !prev_dmc_irq)
            $fatal(1, "dmc irq asserted, dmc dma is not wired in this version");
        prev_dmc_irq = dut.u_apu.dbg_dmc_irq;

        if (apu_irq_o !== (dut.u_apu.dbg_frame_irq | dut.u_apu.dbg_dmc_irq))
            $fatal(1, "apu_irq_o got %b expected %b from frame=%b dmc=%b",
                   apu_irq_o, (dut.u_apu.dbg_frame_irq | dut.u_apu.dbg_dmc_irq),
                   dut.u_apu.dbg_frame_irq, dut.u_apu.dbg_dmc_irq);
        if (dut.u_cpu.dbg_irq_pending !== apu_irq_o)
            $fatal(1, "cpu dbg_irq_pending got %b expected %b",
                   dut.u_cpu.dbg_irq_pending, apu_irq_o);

        if (dut.apu_reg_cs) begin
            if (!dut.cpu_bus_fire)
                $fatal(1, "apu_reg_cs asserted without cpu_bus_fire");
            if (!dut.ce_cpu)
                $fatal(1, "apu_reg_cs is not aligned with ce_cpu at div_phase=%0d",
                       dut.div_phase);
            if (prev_apu_reg_cs)
                $fatal(1, "apu_reg_cs stayed high for two clk cycles");
            if (dut.cpu_addr[15:5] !== 11'h200)
                $fatal(1, "apu_reg_cs asserted outside $4000-$401F at %04h",
                       dut.cpu_addr);
            if (dut.cpu_addr[4:0] > 5'h17)
                $fatal(1, "apu_reg_cs asserted outside $4000-$4017 at %04h",
                       dut.cpu_addr);
            if (dut.u_apu.reg_we) begin
                apu_wr_total = apu_wr_total + 1;
                case (dut.u_apu.reg_addr)
                    5'h00: apu_wr_4000 = apu_wr_4000 + 1;
                    5'h01: apu_wr_4001 = apu_wr_4001 + 1;
                    5'h02: apu_wr_4002 = apu_wr_4002 + 1;
                    5'h03: apu_wr_4003 = apu_wr_4003 + 1;
                    5'h14: apu_wr_4014 = apu_wr_4014 + 1;
                    5'h15: begin
                        apu_wr_4015 = apu_wr_4015 + 1;
                        if (handler_active === 1'b1) begin
                            if (handler_status_read !== 1'b1)
                                $fatal(1, "handler wrote $4015 before reading it");
                            if (dut.u_apu.reg_din !== status_read_value)
                                $fatal(1, "handler ack write data %02h differs from the read %02h",
                                       dut.u_apu.reg_din, status_read_value);
                            irq_ack_count = irq_ack_count + 1;
                        end
                    end
                    5'h17: apu_wr_4017 = apu_wr_4017 + 1;
                    default: apu_wr_other = apu_wr_other + 1;
                endcase
            end else begin
                apu_rd_total = apu_rd_total + 1;
                case (dut.u_apu.reg_addr)
                    5'h14: begin
                        apu_rd_4014 = apu_rd_4014 + 1;
                        if (dut.cpu_din !== 8'h00)
                            $fatal(1, "$4014 read %02h, oam dma is not wired and must read 00",
                                   dut.cpu_din);
                    end
                    5'h15: begin
                        apu_rd_4015 = apu_rd_4015 + 1;
                        if (dut.cpu_din !== dut.u_apu.reg_dout)
                            $fatal(1, "cpu_din %02h does not match apu reg_dout %02h",
                                   dut.cpu_din, dut.u_apu.reg_dout);
                        if (dut.cpu_din[7] !== 1'b0)
                            $fatal(1, "$4015 reported a dmc irq in bit 7");
                        if (handler_active === 1'b1) begin
                            if (handler_status_read !== 1'b0)
                                $fatal(1, "the irq handler read $4015 twice");
                            if (dut.cpu_din[6] !== 1'b1)
                                $fatal(1, "$4015 read %02h inside the handler has no frame irq bit",
                                       dut.cpu_din);
                            if (dut.cpu_din[1:0] !== 2'b01)
                                $fatal(1, "$4015 read %02h, pulse1 length bit is not set",
                                       dut.cpu_din);
                            handler_status_read = 1'b1;
                        end else begin
                            if (dut.cpu_din[6] !== 1'b0)
                                $fatal(1, "$4015 read %02h outside the handler, $4017=$00 must leave the frame irq able to fire",
                                       dut.cpu_din);
                            if (dut.cpu_din[1:0] !== 2'b00)
                                $fatal(1, "$4015 read %02h before $4015 was written, no channel length can be set",
                                       dut.cpu_din);
                        end
                        status_read_value = dut.cpu_din;
                    end
                    5'h18: apu_rd_4018 = apu_rd_4018 + 1;
                    5'h1F: apu_rd_401f = apu_rd_401f + 1;
                    default: apu_rd_other = apu_rd_other + 1;
                endcase
            end
        end
        prev_apu_reg_cs = dut.apu_reg_cs;

        if (oam_dma_req) begin
            oam_dma_req_count = oam_dma_req_count + 1;
            if (dut.cpu_addr[15:0] !== 16'h4014)
                $fatal(1, "oam_dma_req asserted at %04h", dut.cpu_addr);
            if (dut.oam_dma_count !== 8'd0)
                $fatal(1, "oam_dma_count advanced to %0d before the request edge",
                       dut.oam_dma_count);
        end

        if (dut.ppu_reg_cs) begin
            if (dut.u_ppu.reg_we) begin
                ppu_wr_total = ppu_wr_total + 1;
                case (dut.u_ppu.reg_addr)
                    3'd0: ppu_wr_ctrl = ppu_wr_ctrl + 1;
                    3'd1: ppu_wr_mask = ppu_wr_mask + 1;
                    default: ppu_wr_other = ppu_wr_other + 1;
                endcase
            end else begin
                ppu_rd_total = ppu_rd_total + 1;
            end
        end

        if (dut.cpu_bus_fire) begin
            cpu_bus_count = cpu_bus_count + 1;
            if (!dut.ce_cpu)
                $fatal(1, "cpu bus fire without ce_cpu at div_phase=%0d", dut.div_phase);
            if (dut.u_cpu.dbg_state >= 7'd5) begin
                cpu_bus_count_mapped = cpu_bus_count_mapped + 1;
                if (dut.u_cpu.bus_we) begin
                    if (dut.sel_ram === 1'b1)
                        wr_ram = wr_ram + 1;
                    else if (dut.sel_ppu === 1'b1)
                        wr_ppu = wr_ppu + 1;
                    else if (dut.sel_apu === 1'b1)
                        wr_apu = wr_apu + 1;
                    else
                        $fatal(1, "cpu write to an unmapped region at %04h",
                               dut.u_cpu.bus_addr);
                end else begin
                    if (dut.sel_ram === 1'b1)
                        rd_ram = rd_ram + 1;
                    else if (dut.sel_ppu === 1'b1)
                        rd_ppu = rd_ppu + 1;
                    else if (dut.sel_apu === 1'b1)
                        rd_apu = rd_apu + 1;
                    else if ((dut.u_cpu.bus_addr[15:13] == 3'b010) ||
                             (dut.u_cpu.bus_addr[15:13] == 3'b011))
                        rd_openbus = rd_openbus + 1;
                    else
                        rd_prg = rd_prg + 1;
                end
                if ((dut.sel_ram === 1'b0) && (dut.sel_ppu === 1'b0) &&
                    (dut.cpu_addr[15] === 1'b1)) begin
                    if (dut.prg_index >= PRG_SIZE_BYTES)
                        $fatal(1, "prg index %03h out of range for %04h",
                               dut.prg_index, dut.u_cpu.bus_addr);
                    if (dut.prg_index !== dut.u_cpu.bus_addr[13:0])
                        $fatal(1, "prg index got %03h expected %03h for %04h (nrom-128 mirror)",
                               dut.prg_index, dut.u_cpu.bus_addr[13:0], dut.u_cpu.bus_addr);
                    if (dut.u_cpu.bus_addr[14] === 1'b1) begin
                        prg_rd_upper = prg_rd_upper + 1;
                        case (dut.u_cpu.bus_addr)
                            16'hFFFA: begin
                                prg_rd_fffa = prg_rd_fffa + 1;
                                $fatal(1, "nmi vector fetch happened, ppuctrl nmi is off");
                            end
                            16'hFFFB: begin
                                prg_rd_fffb = prg_rd_fffb + 1;
                                $fatal(1, "nmi vector fetch happened, ppuctrl nmi is off");
                            end
                            16'hFFFC: begin
                                prg_rd_fffc = prg_rd_fffc + 1;
                                if (dut.cpu_din !== 8'h00)
                                    $fatal(1, "reset vector low got %02h expected 00", dut.cpu_din);
                            end
                            16'hFFFD: begin
                                prg_rd_fffd = prg_rd_fffd + 1;
                                if (dut.cpu_din !== 8'h80)
                                    $fatal(1, "reset vector high got %02h expected 80", dut.cpu_din);
                            end
                            16'hFFFE: begin
                                prg_rd_fffe = prg_rd_fffe + 1;
                                if (dut.cpu_din !== 8'h00)
                                    $fatal(1, "irq vector low got %02h expected 00", dut.cpu_din);
                            end
                            16'hFFFF: begin
                                prg_rd_ffff = prg_rd_ffff + 1;
                                if (dut.cpu_din !== 8'h82)
                                    $fatal(1, "irq vector high got %02h expected 82", dut.cpu_din);
                            end
                            default: begin
                                $fatal(1, "unexpected prg read from %04h", dut.u_cpu.bus_addr);
                            end
                        endcase
                    end
                end
                if (!dut.u_cpu.bus_we && (dut.u_cpu.bus_addr[15:5] == 11'h200) &&
                    (dut.u_cpu.bus_addr[4:0] > 5'h17)) begin
                    outside_apu_read = outside_apu_read + 1;
                    if (dut.apu_reg_cs !== 1'b0)
                        $fatal(1, "apu_reg_cs asserted at %04h outside $4000-$4017",
                               dut.u_cpu.bus_addr);
                    if (dut.cpu_din !== 8'h00)
                        $fatal(1, "read at %04h got %02h expected 00",
                               dut.u_cpu.bus_addr, dut.cpu_din);
                end
                if ((dut.sel_ram === 1'b1) && (dut.u_cpu.bus_we === 1'b1)) begin
                    if (dut.ram_index !== dut.u_cpu.bus_addr[10:0])
                        $fatal(1, "ram_index got %03h expected %03h for %04h",
                               dut.ram_index, dut.u_cpu.bus_addr[10:0], dut.u_cpu.bus_addr);
                    ram_wr_total = ram_wr_total + 1;
                    case (dut.u_cpu.bus_addr)
                        IRQ_COUNTER: begin
                            ram_wr_counter = ram_wr_counter + 1;
                            if (dut.u_cpu.bus_dout !== 8'h00)
                                ram_wr_counter_nonzero = ram_wr_counter_nonzero + 1;
                        end
                        STACK_PC_HI: begin
                            ram_push_pc_hi = ram_push_pc_hi + 1;
                            if (dut.u_cpu.bus_dout !== MAIN_LOOP[15:8])
                                $fatal(1, "irq push pc high got %02h expected %02h",
                                       dut.u_cpu.bus_dout, MAIN_LOOP[15:8]);
                        end
                        STACK_PC_LO: begin
                            ram_push_pc_lo = ram_push_pc_lo + 1;
                            if (dut.u_cpu.bus_dout !== MAIN_LOOP[7:0])
                                $fatal(1, "irq push pc low got %02h expected %02h",
                                       dut.u_cpu.bus_dout, MAIN_LOOP[7:0]);
                        end
                        STACK_P: begin
                            ram_push_p = ram_push_p + 1;
                            if (dut.u_cpu.bus_dout !== (dut.u_cpu.dbg_p | 8'h20))
                                $fatal(1, "irq push p got %02h, expected p with b5 forced (%02h)",
                                       dut.u_cpu.bus_dout, (dut.u_cpu.dbg_p | 8'h20));
                            if (dut.u_cpu.bus_dout[4] !== 1'b0)
                                ram_push_p_brk = ram_push_p_brk + 1;
                        end
                        default: begin
                            $fatal(1, "unexpected ram write to %04h data %02h",
                                   dut.u_cpu.bus_addr, dut.u_cpu.bus_dout);
                        end
                    endcase
                end
            end
        end
        if (dut.u_cpu.dbg_illegal !== 1'b0)
            $fatal(1, "dbg_illegal asserted, pc=%04h state=%0d opcode=%02h",
                   dut.u_cpu.dbg_pc, dut.u_cpu.dbg_state, dut.u_cpu.dbg_opcode);
        if (dut.cpu_bus_fire && (dut.u_cpu.dbg_state === 7'd7)) begin
            if ((dut.u_cpu.dbg_pc[15:8] !== 8'h80) && (dut.u_cpu.dbg_pc[15:8] !== 8'h82))
                $fatal(1, "cpu pc left the prg program area, pc=%04h", dut.u_cpu.dbg_pc);
            if ((dut.u_cpu.dbg_pc[15:8] === 8'h80) &&
                (dut.u_cpu.dbg_pc[7:0] > 8'h49) && (dut.u_cpu.dbg_pc < 16'h8200))
                $fatal(1, "cpu pc left the main program block, pc=%04h", dut.u_cpu.dbg_pc);
            if (dut.u_cpu.dbg_pc === FAIL_LOOP)
                $fatal(1, "the program jumped into the fail dead loop at %04h", FAIL_LOOP);
            if (dut.u_cpu.dbg_pc === IRQ_HANDLER) begin
                if (handler_active !== 1'b1) begin
                    handler_active = 1'b1;
                    handler_status_read = 1'b0;
                    irq_entry_count = irq_entry_count + 1;
                    if (irq_taken_pending == 1'b1) begin
                        irq_entry_cycle_delta = cpu_cycle - irq_take_cycle;
                        irq_taken_pending = 1'b0;
                    end else begin
                        $fatal(1, "the irq handler was entered without a taken irq");
                    end
                end
            end
            if (dut.u_cpu.dbg_pc === MAIN_LOOP) begin
                handler_active = 1'b0;
                if (dut.u_cpu.dbg_p[2] !== 1'b0)
                    $fatal(1, "i flag is %b in the main loop, the program runs with sei",
                           dut.u_cpu.dbg_p[2]);
                if (apu_irq_o === 1'b1) begin
                    irq_taken_pending = 1'b1;
                    irq_take_cycle = cpu_cycle;
                end
            end
        end
        if (dut.cpu_bus_fire && (dut.u_cpu.dbg_state === 7'd42))
            handler_active = 1'b0;
        if (dut.cpu_bus_fire && (handler_active === 1'b1)) begin
            if (dut.u_cpu.dbg_sp !== 8'hFA)
                $fatal(1, "sp is %02h inside the irq handler, expected FA", dut.u_cpu.dbg_sp);
            if (dut.u_cpu.dbg_p[2] !== 1'b1)
                $fatal(1, "i flag is clear inside the irq handler, p=%02h", dut.u_cpu.dbg_p);
        end
        case (dut.u_cpu.dbg_state)
            7'd5: begin
                if (!saw_first_fetch || !saw_reset_lo) begin
                    saw_reset_lo = 1'b1;
                    if (dut.u_cpu.bus_addr !== 16'hFFFC)
                        $fatal(1, "reset vector low fetch address got %04h expected FFFC",
                               dut.u_cpu.bus_addr);
                end
            end
            7'd6: begin
                if (!saw_reset_hi) begin
                    saw_reset_hi = 1'b1;
                    if (dut.u_cpu.bus_addr !== 16'hFFFD)
                        $fatal(1, "reset vector high fetch address got %04h expected FFFD",
                               dut.u_cpu.bus_addr);
                end
            end
            7'd7: begin
                if (!saw_first_fetch) begin
                    saw_first_fetch = 1'b1;
                    if (dut.u_cpu.dbg_pc !== 16'h8000)
                        $fatal(1, "first fetch pc got %04h expected 8000", dut.u_cpu.dbg_pc);
                end
                if (dut.cpu_bus_fire)
                    saw_fetch_bus = 1'b1;
                else if (saw_fetch_bus && !saw_first_opcode) begin
                    saw_first_opcode = 1'b1;
                    if (dut.u_cpu.dbg_opcode !== 8'h58)
                        $fatal(1, "first fetched opcode got %02h expected 58 (cli)",
                               dut.u_cpu.dbg_opcode);
                end
            end
            default: begin
            end
        endcase
    end
end

always @(posedge clk) begin
    #1;
    if (!reset) begin
        if (audio_sample_valid) begin
            if (audio_sample_left !== audio_sample_right)
                $fatal(1, "sample left %0d differs from right %0d",
                       audio_sample_left, audio_sample_right);
            if (dut.div_phase !== 4'd1)
                $fatal(1, "audio_sample_valid asserted at div_phase=%0d, expected 1",
                       dut.div_phase);
            if (tnd_sum_prev !== 8'd0)
                $fatal(1, "tnd sum is %0d, this program only plays pulse1", tnd_sum_prev);
            if (audio_sample_left !== ref_pulse_lut(pulse_sum_prev))
                $fatal(1, "sample %0d does not match ref_pulse_lut(%0d) = %0d",
                       audio_sample_left, pulse_sum_prev, ref_pulse_lut(pulse_sum_prev));
            if (audio_sample_left > sample_max)
                sample_max = audio_sample_left;
            if (audio_sample_left !== 16'd0)
                sample_nonzero_count = sample_nonzero_count + 1;
            if (handler_active === 1'b1)
                handler_sample_strobes = handler_sample_strobes + 1;
            sample_lut_checks = sample_lut_checks + 1;
        end
        sample_valid_count = sample_valid_count + audio_sample_valid;

        if (frame_done !== 1'b0) begin
            if ((ppu_scanline !== 9'd0) || (ppu_dot !== 9'd0))
                $fatal(1, "frame_done asserted at %0d:%0d, expected 0:0",
                       ppu_scanline, ppu_dot);
        end
        if ((frame_done === 1'b1) && (prev_frame_done !== 1'b1)) begin
            frame_count = frame_count + 1;
            if (have_frame_mark === 1)
                frame_clk_delta = clk_count - frame_mark;
            else
                have_frame_mark = 1;
            frame_mark = clk_count;
            // RATE-CPU, the apu cross-check.  The apu's frame sequencer is
            // clocked by the SAME ce_cpu the cpu uses (nes_system_v1.v's APU
            // .ce(ce_cpu)), and the frame irq above proves that ce_cpu is 29829
            // long.  So ce_cpu is the wall-time base both halves share, and in
            // this version the cpu has no bus arbiter at all, which makes it the
            // reference that says what a correct cpu access rate looks like: one
            // completed access per ce_cpu, one to one.  A frame is 357368 clk, so
            // ce_cpu fires 357368/12 = 29780 or 29781 times in it.  v2..v6 add the
            // arbiter and have to MEASURE the same ratio; this is the number they
            // are measured against, and it is why the apu is not separated from
            // ce_cpu.
            if (rate_warm === 1'b1) begin
                rate_ce_frame = apu_ce_count - rate_ce_mark;
                rate_fire_frame = cpu_bus_count - rate_fire_mark;
                rate_frames = rate_frames + 1;
                if (rate_ce_frame < rate_ce_min)
                    rate_ce_min = rate_ce_frame;
                if (rate_ce_frame > rate_ce_max)
                    rate_ce_max = rate_ce_frame;
                if (rate_fire_frame < rate_fire_min)
                    rate_fire_min = rate_fire_frame;
                if (rate_fire_frame > rate_fire_max)
                    rate_fire_max = rate_fire_frame;
                if ((rate_ce_frame != rate_fire_frame) ||
                    (rate_ce_frame < 29780) || (rate_ce_frame > 29781)) begin
                    rate_bad = rate_bad + 1;
                    if (rate_bad == 1) begin
                        rate_bad_ce = rate_ce_frame;
                        rate_bad_fire = rate_fire_frame;
                    end
                end
            end else begin
                rate_warm = 1'b1;
            end
            rate_ce_mark = apu_ce_count;
            rate_fire_mark = cpu_bus_count;
        end
        prev_frame_done = frame_done;

        expected_vblank = ((ppu_scanline == 9'd241) && (ppu_dot >= 9'd1)) ||
                          ((ppu_scanline >= 9'd242) && (ppu_scanline <= 9'd260)) ||
                          ((ppu_scanline == 9'd261) && (ppu_dot == 9'd0));
        if (vblank !== expected_vblank[0])
            $fatal(1, "vblank got %b expected %b at %0d:%0d",
                   vblank, expected_vblank[0], ppu_scanline, ppu_dot);
        if (vblank && !prev_vblank)
            vblank_rise_count = vblank_rise_count + 1;
        if (!vblank && prev_vblank)
            vblank_fall_count = vblank_fall_count + 1;
        prev_vblank = vblank;

        expected_nmi = vblank & dut.u_ppu.control_reg[7];
        if (nmi_o !== expected_nmi[0])
            $fatal(1, "nmi_o got %b expected %b at %0d:%0d with ppuctrl=%02h",
                   nmi_o, expected_nmi[0], ppu_scanline, ppu_dot,
                   dut.u_ppu.control_reg);

        if (pixel_index !== 4'h0)
            $fatal(1, "pixel_index is %0d at %0d:%0d with ppumask=%02h, expected 0",
                   pixel_index, ppu_scanline, ppu_dot, dut.u_ppu.mask_reg);
        if (pixel_valid === 1'b1) begin
            if ((pixel_x !== ppu_dot[7:0]) || (pixel_y !== ppu_scanline[7:0]))
                $fatal(1, "pixel coordinates got (%0d,%0d) expected (%0d,%0d)",
                       pixel_x, pixel_y, ppu_dot[7:0], ppu_scanline[7:0]);
        end

        if (dut.u_apu.dbg_pulse1_level === 4'd15)
            level15_count = level15_count + 1;
    end
end

initial begin
    clk = 1'b0;
    reset = 1'b1;
    prev_frame_done = 1'b0;
    prev_vblank = 1'b0;
    prev_apu_irq = 1'b0;
    prev_apu_reg_cs = 1'b0;
    prev_frame_irq = 1'b0;
    prev_dmc_irq = 1'b0;
    saw_first_fetch = 1'b0;
    saw_fetch_bus = 1'b0;
    saw_first_opcode = 1'b0;
    saw_reset_lo = 1'b0;
    saw_reset_hi = 1'b0;
    handler_active = 1'b0;
    handler_status_read = 1'b0;
    irq_taken_pending = 1'b0;
    status_read_value = 8'h00;
    mixed_sample_prev = 16'h0000;
    pulse_sum_prev = 6'd0;
    tnd_sum_prev = 8'd0;
    frame_irq_ce_mark = 16'd0;
    expected_vblank = 8'd0;
    expected_nmi = 8'd0;
    clk_count = 0;
    frame_count = 0;
    frame_mark = 0;
    frame_clk_delta = 0;
    cpu_bus_count = 0;
    cpu_bus_count_mapped = 0;
    rd_ram = 0;
    wr_ram = 0;
    rd_ppu = 0;
    wr_ppu = 0;
    rd_apu = 0;
    wr_apu = 0;
    rd_openbus = 0;
    rd_prg = 0;
    apu_ce_count = 0;
    sample_valid_count = 0;
    sample_nonzero_count = 0;
    sample_lut_checks = 0;
    sample_max = 0;
    apu_wr_total = 0;
    apu_rd_total = 0;
    apu_wr_4000 = 0;
    apu_wr_4001 = 0;
    apu_wr_4002 = 0;
    apu_wr_4003 = 0;
    apu_wr_4014 = 0;
    apu_wr_4015 = 0;
    apu_wr_4017 = 0;
    apu_wr_other = 0;
    apu_rd_4014 = 0;
    apu_rd_4015 = 0;
    apu_rd_4018 = 0;
    apu_rd_401f = 0;
    apu_rd_other = 0;
    oam_dma_req_count = 0;
    outside_apu_read = 0;
    ppu_wr_total = 0;
    ppu_wr_ctrl = 0;
    ppu_wr_mask = 0;
    ppu_wr_other = 0;
    ppu_rd_total = 0;
    prg_rd_upper = 0;
    prg_rd_fffa = 0;
    prg_rd_fffb = 0;
    prg_rd_fffc = 0;
    prg_rd_fffd = 0;
    prg_rd_fffe = 0;
    prg_rd_ffff = 0;
    ram_wr_total = 0;
    ram_wr_counter = 0;
    ram_wr_counter_nonzero = 0;
    ram_push_pc_hi = 0;
    ram_push_pc_lo = 0;
    ram_push_p = 0;
    ram_push_p_brk = 0;
    irq_entry_count = 0;
    irq_take_cycle = 0;
    irq_entry_cycle_delta = 0;
    irq_ack_count = 0;
    apu_irq_rise_count = 0;
    apu_irq_fall_count = 0;
    frame_irq_rise_count = 0;
    frame_irq_ce_delta = 0;
    frame_irq_ce_delta_count = 0;
    handler_sample_strobes = 0;
    handler_ce_count = 0;
    max_frame_count = 0;
    level15_count = 0;
    vblank_rise_count = 0;
    vblank_fall_count = 0;
    have_frame_mark = 0;
    rate_frames = 0;
    rate_bad = 0;
    rate_ce_frame = 0;
    rate_fire_frame = 0;
    rate_ce_mark = 0;
    rate_fire_mark = 0;
    rate_ce_min = 1000000;
    rate_ce_max = -1;
    rate_fire_min = 1000000;
    rate_fire_max = -1;
    rate_bad_ce = 0;
    rate_bad_fire = 0;
    rate_warm = 1'b0;
    have_frame_irq_mark = 0;
    load_prg_rom;
    load_video_ram;

    repeat (4) @(posedge clk);
    #1;
    if ((ppu_scanline !== 9'd0) || (ppu_dot !== 9'd0))
        $fatal(1, "ppu counter did not start at 0:0, got %0d:%0d", ppu_scanline, ppu_dot);
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
    if (oam_dma_count !== 8'd0)
        $fatal(1, "oam_dma_count is %0d during reset", oam_dma_count);
    if (dut.u_cpu.dbg_state !== 7'd0)
        $fatal(1, "cpu state is %0d during reset, expected 0", dut.u_cpu.dbg_state);
    if (dut.u_apu.dbg_frame_count !== 16'd0)
        $fatal(1, "apu frame count is %0d during reset, expected 0",
               dut.u_apu.dbg_frame_count);
    if (dut.u_ppu.mask_reg !== 8'h00)
        $fatal(1, "ppumask is %02h during reset, expected 00", dut.u_ppu.mask_reg);

    @(negedge clk);
    reset = 1'b0;
    #1;

    wait (frame_count == FRAME_COUNT_TARGET);
    #100;

    if (!saw_reset_lo || !saw_reset_hi || !saw_first_fetch || !saw_first_opcode)
        $fatal(1, "cpu reset sequence incomplete lo=%b hi=%b fetch=%b opcode=%b",
               saw_reset_lo, saw_reset_hi, saw_first_fetch, saw_first_opcode);
    if (prg_mirror_read(16'h8000) !== 8'h58)
        $fatal(1, "prg image load failed at 8000, got %02h", prg_mirror_read(16'h8000));
    if (prg_mirror_read(MAIN_LOOP) !== 8'h4C)
        $fatal(1, "prg image load failed at 8046, got %02h", prg_mirror_read(MAIN_LOOP));
    if (prg_mirror_read(FAIL_LOOP) !== 8'h4C)
        $fatal(1, "prg image load failed at 8049, got %02h", prg_mirror_read(FAIL_LOOP));
    if (prg_mirror_read(IRQ_HANDLER) !== 8'hAD)
        $fatal(1, "prg image load failed at 8200, got %02h", prg_mirror_read(IRQ_HANDLER));
    if (prg_mirror_read(IRQ_HANDLER + 16'd15) !== 8'h40)
        $fatal(1, "prg image load failed at 820F, got %02h",
               prg_mirror_read(IRQ_HANDLER + 16'd15));
    if ((prg_mirror_read(16'hFFFE) !== 8'h00) || (prg_mirror_read(16'hFFFF) !== 8'h82))
        $fatal(1, "irq vector got %02h%02h expected 8200",
               prg_mirror_read(16'hFFFF), prg_mirror_read(16'hFFFE));
    $display("PRG nrom-128 %0d bytes, reset vector FFFC/FFFD=%02h%02h, irq vector FFFE/FFFF=%02h%02h, handler=%04h PASS",
             PRG_SIZE_BYTES, prg_mirror_read(16'hFFFD), prg_mirror_read(16'hFFFC),
             prg_mirror_read(16'hFFFF), prg_mirror_read(16'hFFFE), IRQ_HANDLER);
    if ((prg_rd_fffc != 1) || (prg_rd_fffd != 1))
        $fatal(1, "reset vector fetch counts got %0d/%0d expected 1/1",
               prg_rd_fffc, prg_rd_fffd);
    if (prg_rd_upper != (2 + (2 * irq_entry_count)))
        $fatal(1, "prg reads from the mirrored window got %0d expected %0d",
               prg_rd_upper, 2 + (2 * irq_entry_count));
    if ((prg_rd_fffe != irq_entry_count) || (prg_rd_ffff != irq_entry_count))
        $fatal(1, "irq vector fetch counts got %0d/%0d, expected one pair per entry (%0d)",
               prg_rd_fffe, prg_rd_ffff, irq_entry_count);
    if ((prg_rd_fffa != 0) || (prg_rd_fffb != 0))
        $fatal(1, "nmi vector was fetched %0d/%0d times", prg_rd_fffa, prg_rd_fffb);
    $display("MIRROR every vector is fetched through $C000-$FFFF, upper window reads=%0d, irq pairs=%0d, nmi pairs=0 PASS",
             prg_rd_upper, prg_rd_fffe);

    if (apu_wr_4017 != 1)
        $fatal(1, "$4017 write count got %0d expected 1", apu_wr_4017);
    if (apu_wr_4015 != (1 + irq_entry_count))
        $fatal(1, "$4015 write count got %0d expected %0d",
               apu_wr_4015, 1 + irq_entry_count);
    if (apu_wr_4000 != 1)
        $fatal(1, "$4000 write count got %0d expected 1", apu_wr_4000);
    if (apu_wr_4001 != 1)
        $fatal(1, "$4001 write count got %0d expected 1", apu_wr_4001);
    if (apu_wr_4002 != 1)
        $fatal(1, "$4002 write count got %0d expected 1", apu_wr_4002);
    if (apu_wr_4003 != 1)
        $fatal(1, "$4003 write count got %0d expected 1", apu_wr_4003);
    if (apu_wr_4014 != 0)
        $fatal(1, "$4014 was written %0d times, the program only reads it", apu_wr_4014);
    if (apu_wr_other != 0)
        $fatal(1, "unexpected writes to other apu registers: %0d", apu_wr_other);
    if (apu_rd_4015 != (1 + irq_entry_count))
        $fatal(1, "$4015 read count got %0d expected %0d",
               apu_rd_4015, 1 + irq_entry_count);
    if (apu_rd_4014 != 1)
        $fatal(1, "$4014 read count got %0d expected 1", apu_rd_4014);
    if ((apu_rd_4018 != 0) || (apu_rd_401f != 0))
        $fatal(1, "$4018/$401F reached the apu bridge %0d/%0d times",
               apu_rd_4018, apu_rd_401f);
    if (apu_rd_other != 0)
        $fatal(1, "unexpected reads of other apu registers: %0d", apu_rd_other);
    if (outside_apu_read != 2)
        $fatal(1, "reads of $4018/$401F got %0d expected 2", outside_apu_read);
    if ((apu_wr_total + apu_rd_total) != (8 + (2 * irq_entry_count)))
        $fatal(1, "apu transactions got %0d, expected %0d",
               (apu_wr_total + apu_rd_total), 8 + (2 * irq_entry_count));
    $display("REGISTER program wrote $4000/$4001/$4002/$4003/$4015/$4017 once each and read $4015/$4014 once each, handler read+wrote $4015 %0d times, $4018/$401F never reached the apu PASS",
             irq_entry_count);
    if (oam_dma_req_count != 1)
        $fatal(1, "oam_dma_req count got %0d expected 1", oam_dma_req_count);
    if (oam_dma_count != 8'd1)
        $fatal(1, "oam_dma_count is %0d expected 1", oam_dma_count);
    $display("OAMDMA $4014 read returned 00, oam_dma_req pulsed %0d time, oam_dma_count=%0d, no cpu stall and no oam write PASS",
             oam_dma_req_count, oam_dma_count);

    if (dut.u_apu.dbg_pulse1_period !== EXPECTED_PULSE1_PERIOD[10:0])
        $fatal(1, "pulse1 period is %03h expected %03h",
               dut.u_apu.dbg_pulse1_period, EXPECTED_PULSE1_PERIOD);
    if (dut.u_apu.dbg_pulse1_mute !== 1'b0)
        $fatal(1, "pulse1 is muted at the end, period %03h",
               dut.u_apu.dbg_pulse1_period);
    if (dut.u_apu.dbg_pulse1_length < EXPECTED_PULSE1_LENGTH_MIN)
        $fatal(1, "pulse1 length decayed to %0d, the counter should still be running",
               dut.u_apu.dbg_pulse1_length);
    if (dut.u_apu.dbg_pulse1_length !== EXPECTED_PULSE1_LENGTH)
        $fatal(1, "pulse1 length is %0d, the $4003 length load never happened or $4000[5] did not halt it",
               dut.u_apu.dbg_pulse1_length);
    if (dut.u_apu.dbg_pulse2_length !== 8'd0)
        $fatal(1, "pulse2 length is %0d, only pulse1 was enabled",
               dut.u_apu.dbg_pulse2_length);
    if (dut.u_apu.dbg_tri_length !== 8'd0)
        $fatal(1, "triangle length is %0d, only pulse1 was enabled",
               dut.u_apu.dbg_tri_length);
    if (dut.u_apu.dbg_noise_length !== 8'd0)
        $fatal(1, "noise length is %0d, only pulse1 was enabled",
               dut.u_apu.dbg_noise_length);
    $display("PULSE1 period=%03h, length %0d of %0d (halted by $4000[5]), not muted, pulse2/tri/noise lengths all 0 PASS",
             dut.u_apu.dbg_pulse1_period, dut.u_apu.dbg_pulse1_length,
             EXPECTED_PULSE1_LENGTH);

    if (irq_entry_count != IRQ_ENTRIES_EXPECTED)
        $fatal(1, "irq handler entries got %0d expected %0d",
               irq_entry_count, IRQ_ENTRIES_EXPECTED);
    if (irq_ack_count != irq_entry_count)
        $fatal(1, "$4015 acks inside the handler got %0d, entries %0d",
               irq_ack_count, irq_entry_count);
    if (irq_entry_cycle_delta != IRQ_ENTRY_CPU_CYCLES)
        $fatal(1, "irq entry took %0d cpu cycles, expected %0d",
               irq_entry_cycle_delta, IRQ_ENTRY_CPU_CYCLES);
    if (ram_push_pc_hi != irq_entry_count)
        $fatal(1, "irq pc-high pushes %0d do not match %0d entries",
               ram_push_pc_hi, irq_entry_count);
    if (ram_push_pc_lo != irq_entry_count)
        $fatal(1, "irq pc-low pushes %0d do not match %0d entries",
               ram_push_pc_lo, irq_entry_count);
    if (ram_push_p != irq_entry_count)
        $fatal(1, "irq p pushes %0d do not match %0d entries", ram_push_p, irq_entry_count);
    if (ram_push_p_brk != 0)
        $fatal(1, "%0d pushed p values had the b flag set, the cpu took a brk not an irq",
               ram_push_p_brk);
    if (ram_wr_counter != (1 + irq_entry_count))
        $fatal(1, "ram %04h write count got %0d expected %0d",
               IRQ_COUNTER, ram_wr_counter, 1 + irq_entry_count);
    if (ram_wr_counter_nonzero != irq_entry_count)
        $fatal(1, "ram counter increments got %0d expected %0d",
               ram_wr_counter_nonzero, irq_entry_count);
    if (ram_wr_total != (1 + (4 * irq_entry_count)))
        $fatal(1, "ram write total got %0d expected %0d",
               ram_wr_total, 1 + (4 * irq_entry_count));
    if (dut.cpu_ram[16'h010] !== irq_entry_count[7:0])
        $fatal(1, "cpu_ram[0010] is %02h expected %02h",
               dut.cpu_ram[16'h010], irq_entry_count[7:0]);
    if (ram_mirror_read(16'h1810) !== irq_entry_count[7:0])
        $fatal(1, "ram mirror cell for 1810 is %02h expected %02h",
               ram_mirror_read(16'h1810), irq_entry_count[7:0]);
    $display("IRQ entries=%0d, handler=%04h took %0d cpu cycles, pushed pc=%02h%02h to 01FC/01FB and p with b5 set b4 clear to 01FA, ram[0010]=%02h PASS",
             irq_entry_count, IRQ_HANDLER, irq_entry_cycle_delta,
             MAIN_LOOP[15:8], MAIN_LOOP[7:0], dut.cpu_ram[16'h010]);

    if (frame_irq_rise_count != IRQ_ENTRIES_EXPECTED)
        $fatal(1, "frame irq rises got %0d expected %0d",
               frame_irq_rise_count, IRQ_ENTRIES_EXPECTED);
    if (frame_irq_ce_delta_count != (IRQ_ENTRIES_EXPECTED - 1))
        $fatal(1, "only %0d frame irq periods were measured", frame_irq_ce_delta_count);
    if (frame_irq_ce_delta != FRAME_IRQ_CE_PERIOD)
        $fatal(1, "frame irq to frame irq period got %0d ce expected %0d",
               frame_irq_ce_delta, FRAME_IRQ_CE_PERIOD);
    if (apu_irq_rise_count != frame_irq_rise_count)
        $fatal(1, "apu_irq_o rises %0d do not match frame irq rises %0d",
               apu_irq_rise_count, frame_irq_rise_count);
    if (apu_irq_fall_count != apu_irq_rise_count)
        $fatal(1, "apu_irq_o rise %0d does not match fall %0d, the handler did not ack",
               apu_irq_rise_count, apu_irq_fall_count);
    if (apu_irq_o !== 1'b0)
        $fatal(1, "apu_irq_o is still high at the end of the run");
    if (dut.u_apu.dbg_frame_irq !== 1'b0)
        $fatal(1, "the apu frame irq flag is still set at the end of the run");
    if (max_frame_count > FRAME_COUNTER_HOLD)
        $fatal(1, "apu frame counter reached %0d, it must hold at %0d",
               max_frame_count, FRAME_COUNTER_HOLD);
    $display("FRAMEIRQ raised on the ce edge that leaves frame count at %0d, then again every %0d ce, rises=%0d falls=%0d, counter max=%0d PASS",
             FRAME_IRQ_CE_TRIGGER, FRAME_IRQ_CE_PERIOD, apu_irq_rise_count,
             apu_irq_fall_count, max_frame_count);

    if (sample_valid_count != apu_ce_count)
        $fatal(1, "sample strobes %0d do not match apu ce pulses %0d",
               sample_valid_count, apu_ce_count);
    if (sample_lut_checks != apu_ce_count)
        $fatal(1, "lut checked strobes %0d do not match apu ce pulses %0d",
               sample_lut_checks, apu_ce_count);
    if (sample_nonzero_count < 1)
        $fatal(1, "every audio sample was zero, pulse1 never reached the mixer");
    if (handler_sample_strobes != handler_ce_count)
        $fatal(1, "sample strobes inside the irq handler got %0d, apu ce pulses inside it got %0d",
               handler_sample_strobes, handler_ce_count);
    if (handler_sample_strobes < (IRQ_ENTRY_CPU_CYCLES * irq_entry_count))
        $fatal(1, "only %0d sample strobes were emitted while the cpu served %0d irqs",
               handler_sample_strobes, irq_entry_count);
    if (level15_count < 1)
        $fatal(1, "pulse1 output level never reached 15");
    if (sample_max != 16'd4895)
        $fatal(1, "peak sample is %0d, expected 4895 for pulse1 level 15", sample_max);
    $display("SAMPLE valid strobes=%0d (one per apu ce, one clk wide at div_phase=1), nonzero=%0d, peak=%0d, every strobe matched ref_pulse_lut, left=right, %0d strobes kept flowing while the cpu served the irqs PASS",
             sample_valid_count, sample_nonzero_count, sample_max,
             handler_sample_strobes);

    if (ppu_wr_total != 2)
        $fatal(1, "ppu register write count got %0d expected 2", ppu_wr_total);
    if (ppu_wr_ctrl != 1)
        $fatal(1, "ppuctrl write count got %0d expected 1", ppu_wr_ctrl);
    if (ppu_wr_mask != 1)
        $fatal(1, "ppumask write count got %0d expected 1", ppu_wr_mask);
    if (ppu_wr_other != 0)
        $fatal(1, "unexpected writes to other ppu registers: %0d", ppu_wr_other);
    if (ppu_rd_total != 0)
        $fatal(1, "the audio program never polls the ppu, got %0d ppu reads", ppu_rd_total);
    if (dut.u_ppu.control_reg !== 8'h00)
        $fatal(1, "ppuctrl is %02h at the end, expected 00", dut.u_ppu.control_reg);
    if (dut.u_ppu.mask_reg !== 8'h00)
        $fatal(1, "ppumask is %02h at the end, expected 00", dut.u_ppu.mask_reg);
    if (vblank_rise_count != FRAME_COUNT_TARGET)
        $fatal(1, "vblank rises got %0d expected %0d", vblank_rise_count, FRAME_COUNT_TARGET);
    if (vblank_rise_count != vblank_fall_count)
        $fatal(1, "vblank rise %0d does not match fall %0d",
               vblank_rise_count, vblank_fall_count);
    $display("PPU writes=%0d (ctrl=%0d mask=%0d) reads=%0d, ppuctrl=00 ppumask=00, nmi_o stayed low, pixel_index stayed 0, vblank rises=%0d PASS",
             ppu_wr_total, ppu_wr_ctrl, ppu_wr_mask, ppu_rd_total, vblank_rise_count);

    if (frame_count != FRAME_COUNT_TARGET)
        $fatal(1, "frame_done count got %0d expected %0d", frame_count, FRAME_COUNT_TARGET);
    if (frame_clk_delta != FRAME_PERIOD_CLK)
        $fatal(1, "frame period got %0d clk expected %0d", frame_clk_delta, FRAME_PERIOD_CLK);
    $display("TIMING frame period=%0dclk over %0d frames, apu ce pulses=%0d, cpu bus cycles=%0d PASS",
             frame_clk_delta, frame_count, apu_ce_count, cpu_bus_count);

    if (rate_frames < 1)
        $fatal(1, "RATE-CPU no full frame window was measured");
    if (rate_bad != 0)
        $fatal(1, "RATE-CPU %0d of %0d frames broke the identity; FIRST: ce_cpu=%0d completed cpu bus cycles=%0d, required one for one and 29780/29781",
               rate_bad, rate_frames, rate_bad_ce, rate_bad_fire);
    $display("RATE-CPU one ce_cpu IS one cpu cycle and the apu frame sequencer is clocked by it, so this is the reference ratio the bus-arbitrated cores are measured against.  Over %0d full frame windows of %0d clk: ce_cpu per frame %0d..%0d, completed cpu bus cycles per frame %0d..%0d, and on every one of them the two counts are EQUAL (violations=%0d).  A frame is 357368/12 = 29780 or 29781 ce_cpu PASS",
             rate_frames, FRAME_PERIOD_CLK, rate_ce_min, rate_ce_max,
             rate_fire_min, rate_fire_max, rate_bad);

    if (cpu_cycle !== cpu_bus_count[31:0])
        $fatal(1, "cpu_cycle %0d does not match bus fire count %0d", cpu_cycle, cpu_bus_count);
    if (cpu_bus_count_mapped != (cpu_bus_count - 5))
        $fatal(1, "mapped bus cycles %0d does not match %0d non-reset bus cycles",
               cpu_bus_count_mapped, cpu_bus_count - 5);
    if (wr_ram != ram_wr_total)
        $fatal(1, "ram write region count %0d does not match the ram write probe %0d",
               wr_ram, ram_wr_total);
    if (wr_ppu != ppu_wr_total)
        $fatal(1, "ppu write region count %0d does not match the ppu write probe %0d",
               wr_ppu, ppu_wr_total);
    if (wr_apu != apu_wr_total)
        $fatal(1, "apu write region count %0d does not match the apu write probe %0d",
               wr_apu, apu_wr_total);
    if (rd_apu != apu_rd_total)
        $fatal(1, "apu read region count %0d does not match the apu read probe %0d",
               rd_apu, apu_rd_total);
    if (rd_ppu != ppu_rd_total)
        $fatal(1, "ppu read region count %0d does not match the ppu read probe %0d",
               rd_ppu, ppu_rd_total);
    if ((rd_ram + rd_ppu + rd_apu + rd_openbus + rd_prg +
         wr_ram + wr_ppu + wr_apu) != cpu_bus_count_mapped)
        $fatal(1, "region totals %0d do not add up to %0d mapped bus cycles",
               (rd_ram + rd_ppu + rd_apu + rd_openbus + rd_prg +
                wr_ram + wr_ppu + wr_apu), cpu_bus_count_mapped);
    if (rd_openbus != outside_apu_read)
        $fatal(1, "open bus read count %0d does not match the $4018/$401F probes %0d",
               rd_openbus, outside_apu_read);
    $display("BUS cpu_cycles=%0d rd(ram=%0d ppu=%0d apu=%0d openbus=%0d prg=%0d) wr(ram=%0d ppu=%0d apu=%0d) all regions classified PASS",
             cpu_cycle, rd_ram, rd_ppu, rd_apu, rd_openbus, rd_prg,
             wr_ram, wr_ppu, wr_apu);
    if (dut.u_cpu.dbg_sp !== 8'hFD)
        $fatal(1, "sp is %02h after the irq handler returned, expected FD", dut.u_cpu.dbg_sp);
    if (dut.u_cpu.dbg_p[2] !== 1'b0)
        $fatal(1, "i flag is %b after the irq handler returned, expected 0",
               dut.u_cpu.dbg_p[2]);
    $display("CPU rti restored sp=FD and the i flag, cpu_cycle=%0d equals the counted bus fires PASS",
             cpu_cycle);

    $display("PASS nes_system_audio");
    $finish;
end

initial begin
    #40000000;
    $fatal(1, "global timeout");
end

endmodule
