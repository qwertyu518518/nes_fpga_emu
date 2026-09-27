`timescale 1ns/1ps

module nes_system_v4 #(
    parameter PRG_SIZE_BYTES = 16384
)(
    input wire clk,
    input wire reset,
    input wire [7:0] buttons1,
    input wire [7:0] buttons2,
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
    output wire [7:0] ppu_port_din
);

localparam PRG_INDEX_BITS = $clog2(PRG_SIZE_BYTES);
localparam [4:0] APU_REG_OAMDMA = 5'h14;
localparam [4:0] APU_REG_CTRL1 = 5'h16;
localparam [4:0] APU_REG_CTRL2 = 5'h17;

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

reg [7:0] prg_rom [0:PRG_SIZE_BYTES-1];

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
wire [PRG_INDEX_BITS-1:0] prg_index;
wire ppu_nmi;
wire apu_sample_valid;
wire [15:0] apu_sample_left;
wire [15:0] apu_sample_right;
wire apu_irq;

assign ppu_ack = 1'b1;
assign apu_ack = 1'b1;
assign cart_ack = 1'b1;
assign prg_index = cart_addr[PRG_INDEX_BITS-1:0];
assign cart_din = (cart_addr[15] == 1'b1) ? prg_rom[prg_index] : 8'h00;

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
    .cpu_fire(cpu_bus_fire),
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
    .MIRROR_VERTICAL(1'b0)
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
    .dbg_sprite_overflow()
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
    .dbg_pulse2_period(),
    .dbg_pulse1_duty_step(),
    .dbg_pulse2_duty_step(),
    .dbg_pulse1_level(),
    .dbg_pulse2_level(),
    .dbg_pulse1_env(),
    .dbg_pulse1_env_div(),
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

endmodule
