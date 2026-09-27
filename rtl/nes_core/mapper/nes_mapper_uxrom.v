`timescale 1ns/1ps

module nes_mapper_uxrom #(
    parameter integer PRG_ADDR_BITS = 17,
    parameter integer CHR_ADDR_BITS = 17,
    parameter integer PRG_SIZE_BYTES = 131072,
    parameter integer UxROM_BANK_BITS = 4,
    parameter [1:0] UxROM_BUS_CONFLICT = 2'd1,
    parameter [2:0] HEADER_MIRRORING = 3'd0
)(
    input wire clk,
    input wire reset,
    input wire [15:0] cpu_addr,
    input wire cpu_we,
    input wire [7:0] cpu_dout,
    input wire [13:0] ppu_addr,
    input wire [7:0] prg_readback,
    output wire [PRG_ADDR_BITS-1:0] prg_bank_offset,
    output wire [CHR_ADDR_BITS-1:0] chr_bank_offset,
    output wire [2:0] mirroring,
    output wire prg_ram_enable,
    output wire chr_ram_enable,
    output wire irq,
    output wire bus_conflict
);

localparam [7:0] UXROM_LAST_BANK_16K = (PRG_SIZE_BYTES >> 14) - 1;

reg [UxROM_BANK_BITS-1:0] bank_select;

wire write_accept;
wire [7:0] latched_data;
wire [PRG_ADDR_BITS-1:0] bank_select_ext;
wire [PRG_ADDR_BITS-1:0] bank_base;

assign latched_data = (UxROM_BUS_CONFLICT == 2'd0) ? cpu_dout
    : ((UxROM_BUS_CONFLICT == 2'd2) ? cpu_dout : (cpu_dout & prg_readback));
assign write_accept = (UxROM_BUS_CONFLICT == 2'd2) ? (cpu_dout == prg_readback) : 1'b1;
assign bus_conflict = cpu_we && (UxROM_BUS_CONFLICT != 2'd0) && (prg_readback != cpu_dout);

assign bank_select_ext = {{(PRG_ADDR_BITS-UxROM_BANK_BITS){1'b0}}, bank_select};
assign bank_base = cpu_addr[14]
    ? ({{(PRG_ADDR_BITS-8){1'b0}}, UXROM_LAST_BANK_16K} << 14)
    : (bank_select_ext << 14);

assign prg_bank_offset = bank_base | {{(PRG_ADDR_BITS-14){1'b0}}, cpu_addr[13:0]};
assign chr_bank_offset = {{(CHR_ADDR_BITS-13){1'b0}}, ppu_addr[12:0]};
assign mirroring = HEADER_MIRRORING;
assign prg_ram_enable = 1'b0;
assign chr_ram_enable = 1'b1;
assign irq = 1'b0;

always @(posedge clk or posedge reset) begin
    if (reset)
        bank_select <= {UxROM_BANK_BITS{1'b0}};
    else if (cpu_we && write_accept)
        bank_select <= latched_data[UxROM_BANK_BITS-1:0];
end

endmodule
