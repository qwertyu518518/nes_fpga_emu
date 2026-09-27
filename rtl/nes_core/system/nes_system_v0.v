`timescale 1ns/1ps

module nes_system_v0 #(
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
    output wire [31:0] cpu_cycle,
    output wire [8:0] ppu_dot,
    output wire [8:0] ppu_scanline
);

localparam PRG_INDEX_BITS = $clog2(PRG_SIZE_BYTES);

reg [3:0] div_phase;
wire ce_ppu;
wire ce_cpu;

assign ce_ppu = !reset && (div_phase[1:0] == 2'b00);
assign ce_cpu = !reset && (div_phase == 4'd0);

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

wire [15:0] cpu_addr;
wire cpu_we;
wire [7:0] cpu_dout;
reg [7:0] cpu_din;
wire cpu_bus_req;
wire cpu_bus_fire;
wire [3:0] cpu_cycle_phase;
wire [7:0] ppu_reg_dout;
wire ppu_nmi;
wire sel_ram;
wire sel_ppu;
wire [10:0] ram_index;
wire [14:0] prg_addr_window;
wire [PRG_INDEX_BITS-1:0] prg_index;
wire ppu_reg_cs;

assign sel_ram = (cpu_addr[15:13] == 3'b000);
assign sel_ppu = (cpu_addr[15:13] == 3'b001);
assign ram_index = cpu_addr[10:0];
assign prg_addr_window = cpu_addr[14:0];
assign prg_index = prg_addr_window[PRG_INDEX_BITS-1:0];
assign ppu_reg_cs = cpu_bus_fire && sel_ppu;
assign nmi_o = ppu_nmi;

always @* begin
    case (cpu_addr[15:13])
        3'b000: cpu_din = cpu_ram[ram_index];
        3'b001: cpu_din = ppu_reg_dout;
        3'b010: cpu_din = 8'h00;
        3'b011: cpu_din = 8'h00;
        default: cpu_din = prg_rom[prg_index];
    endcase
end

always @(posedge clk) begin
    if (cpu_bus_fire && cpu_we && sel_ram)
        cpu_ram[ram_index] <= cpu_dout;
end

nes_cpu6502 u_cpu (
    .clk(clk),
    .reset(reset),
    .ce(ce_cpu),
    .bus_hold(1'b0),
    .bus_din(cpu_din),
    .bus_ready(!reset),
    .nmi_i(ppu_nmi),
    .irq_i(1'b0),
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

endmodule
