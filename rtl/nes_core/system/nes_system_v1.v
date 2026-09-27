`timescale 1ns/1ps

module nes_system_v1 #(
    parameter PRG_SIZE_BYTES = 16384
)(
    input wire clk,
    input wire reset,
    output wire pixel_valid,
    output wire [7:0] pixel_x,
    output wire [7:0] pixel_y,
    output wire [3:0] pixel_index,
    output wire frame_done,
    output wire vblank,
    output wire nmi_o,
    output wire apu_irq_o,
    output wire audio_sample_valid,
    output wire [15:0] audio_sample_left,
    output wire [15:0] audio_sample_right,
    output wire oam_dma_req,
    output wire [7:0] oam_dma_count,
    output wire [31:0] cpu_cycle,
    output wire [8:0] ppu_dot,
    output wire [8:0] ppu_scanline
);

localparam PRG_INDEX_BITS = $clog2(PRG_SIZE_BYTES);
localparam [10:0] APU_PAGE_HIGH = 11'h200;
localparam [4:0] APU_REG_LAST = 5'h17;
localparam [4:0] APU_REG_DMA = 5'h14;

reg [3:0] div_phase;
wire ce_ppu;
wire ce_cpu;
wire ce_sample;

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

reg [7:0] cpu_ram [0:2047];
reg [7:0] prg_rom [0:PRG_SIZE_BYTES-1];
reg [7:0] oam_dma_count_reg;

wire [15:0] cpu_addr;
wire cpu_we;
wire [7:0] cpu_dout;
reg [7:0] cpu_din;
wire cpu_bus_req;
wire cpu_bus_fire;
wire [3:0] cpu_cycle_phase;
wire [7:0] ppu_reg_dout;
wire ppu_nmi;
wire [7:0] apu_reg_dout;
wire apu_irq;
wire apu_sample_valid;
wire [15:0] apu_sample_left;
wire [15:0] apu_sample_right;
wire sel_ram;
wire sel_ppu;
wire sel_apu;
wire [10:0] ram_index;
wire [14:0] prg_addr_window;
wire [PRG_INDEX_BITS-1:0] prg_index;
wire ppu_reg_cs;
wire apu_reg_cs;

assign sel_ram = (cpu_addr[15:13] == 3'b000);
assign sel_ppu = (cpu_addr[15:13] == 3'b001);
assign sel_apu = (cpu_addr[15:5] == APU_PAGE_HIGH) && (cpu_addr[4:0] <= APU_REG_LAST);
assign ram_index = cpu_addr[10:0];
assign prg_addr_window = cpu_addr[14:0];
assign prg_index = prg_addr_window[PRG_INDEX_BITS-1:0];
assign ppu_reg_cs = cpu_bus_fire && sel_ppu;
assign apu_reg_cs = cpu_bus_fire && sel_apu;
assign nmi_o = ppu_nmi;
assign apu_irq_o = apu_irq;
assign audio_sample_valid = apu_sample_valid;
assign audio_sample_left = apu_sample_left;
assign audio_sample_right = apu_sample_right;
assign oam_dma_req = cpu_bus_fire && sel_apu && (cpu_addr[4:0] == APU_REG_DMA);
assign oam_dma_count = oam_dma_count_reg;

always @* begin
    case (cpu_addr[15:13])
        3'b000: cpu_din = cpu_ram[ram_index];
        3'b001: cpu_din = ppu_reg_dout;
        3'b010: cpu_din = sel_apu ? apu_reg_dout : 8'h00;
        3'b011: cpu_din = 8'h00;
        default: cpu_din = prg_rom[prg_index];
    endcase
end

always @(posedge clk) begin
    if (cpu_bus_fire && cpu_we && sel_ram)
        cpu_ram[ram_index] <= cpu_dout;
end

always @(posedge clk or posedge reset) begin
    if (reset)
        oam_dma_count_reg <= 8'd0;
    else if (oam_dma_req)
        oam_dma_count_reg <= oam_dma_count_reg + 8'd1;
end

nes_cpu6502 u_cpu (
    .clk(clk),
    .reset(reset),
    .ce(ce_cpu),
    .bus_hold(1'b0),
    .bus_din(cpu_din),
    .bus_ready(!reset),
    .nmi_i(ppu_nmi),
    .irq_i(apu_irq),
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

nes_ppu2c02 #(
    .MIRROR_VERTICAL(1'b0)
) u_ppu (
    .clk(clk),
    .reset(reset),
    .ce(ce_ppu),
    .reg_cs(ppu_reg_cs),
    .reg_we(cpu_we),
    .reg_addr(cpu_addr[2:0]),
    .reg_din(cpu_dout),
    .reg_dout(ppu_reg_dout),
    .pixel_valid(pixel_valid),
    .pixel_x(pixel_x),
    .pixel_y(pixel_y),
    .pixel_index(pixel_index),
    .frame_done(frame_done),
    .vblank(vblank),
    .nmi_o(ppu_nmi),
    .dot(ppu_dot),
    .scanline(ppu_scanline),
    .dbg_v(),
    .dbg_t(),
    .dbg_x(),
    .dbg_w()
);

nes_apu2a03 u_apu (
    .clk(clk),
    .reset(reset),
    .ce(ce_cpu),
    .ce_sample(ce_sample),
    .reg_cs(apu_reg_cs),
    .reg_we(cpu_we),
    .reg_addr(cpu_addr[4:0]),
    .reg_din(cpu_dout),
    .reg_dout(apu_reg_dout),
    .irq(apu_irq),
    .dmc_bus_req(),
    .dmc_addr(),
    .dmc_rdata(8'h00),
    .dmc_ack(1'b0),
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
    .dbg_pulse2_period(),
    .dbg_pulse1_duty_step(),
    .dbg_pulse2_duty_step(),
    .dbg_pulse1_level(),
    .dbg_pulse2_level(),
    .dbg_pulse1_env(),
    .dbg_pulse2_env(),
    .dbg_pulse1_env_div(),
    .dbg_pulse2_env_div(),
    .dbg_pulse1_mute(),
    .dbg_pulse2_mute(),
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

endmodule
