`timescale 1ns/1ps

module nes_mapper_cnrom #(
    parameter integer PRG_ADDR_BITS = 17,
    parameter integer CHR_ADDR_BITS = 17,
    parameter integer PRG_SIZE_BYTES = 32768,
    parameter integer CNROM_BANK_BITS = 2,
    parameter [1:0] CNROM_BUS_CONFLICT = 2'd1,
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

reg [CNROM_BANK_BITS-1:0] chr_bank_select;

wire write_accept;
wire [7:0] latched_data;
wire [CHR_ADDR_BITS-1:0] chr_bank_ext;

assign latched_data = (CNROM_BUS_CONFLICT == 2'd0) ? cpu_dout
    : ((CNROM_BUS_CONFLICT == 2'd2) ? cpu_dout : (cpu_dout & prg_readback));
assign write_accept = (CNROM_BUS_CONFLICT == 2'd2) ? (cpu_dout == prg_readback) : 1'b1;
assign bus_conflict = cpu_we && (CNROM_BUS_CONFLICT != 2'd0) && (prg_readback != cpu_dout);

assign chr_bank_ext = {{(CHR_ADDR_BITS-CNROM_BANK_BITS){1'b0}}, chr_bank_select};

assign prg_bank_offset = {{(PRG_ADDR_BITS-14){1'b0}}, cpu_addr[13:0]};
assign chr_bank_offset = (chr_bank_ext << 13) | {{(CHR_ADDR_BITS-13){1'b0}}, ppu_addr[12:0]};
// chr_bank_offset is the FINAL CHR byte address, not a displacement to be added
// to somewhere else. ppu_addr must be the LOCAL CHR byte address the PPU presents
// on its chr_addr port; the bank window is applied here, and the memory owner
// indexes CHR with the result directly. ppu_addr[13] (PPUCTRL[4]/[5], the
// pattern-table select) is deliberately dropped: it is a PPU-internal decode.
assign mirroring = HEADER_MIRRORING;
assign prg_ram_enable = 1'b0;
assign chr_ram_enable = 1'b0;
assign irq = 1'b0;

always @(posedge clk or posedge reset) begin
    if (reset)
        chr_bank_select <= {CNROM_BANK_BITS{1'b0}};
    else if (cpu_we && write_accept)
        chr_bank_select <= latched_data[CNROM_BANK_BITS-1:0];
end

endmodule
