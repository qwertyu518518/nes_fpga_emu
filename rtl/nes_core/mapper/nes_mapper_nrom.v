`timescale 1ns/1ps

module nes_mapper_nrom #(
    parameter integer PRG_ADDR_BITS = 17,
    parameter integer CHR_ADDR_BITS = 17,
    parameter integer PRG_SIZE_BYTES = 32768,
    parameter NROM_MIRROR_16K = (PRG_SIZE_BYTES <= 16384),
    parameter [2:0] HEADER_MIRRORING = 3'd0,
    parameter NROM_PRG_RAM = 1'b0,
    parameter NROM_CHR_RAM = 1'b0
)(
    input wire [15:0] cpu_addr,
    input wire [13:0] ppu_addr,
    output wire [PRG_ADDR_BITS-1:0] prg_bank_offset,
    output wire [CHR_ADDR_BITS-1:0] chr_bank_offset,
    output wire [2:0] mirroring,
    output wire prg_ram_enable,
    output wire chr_ram_enable,
    output wire irq
);

assign prg_bank_offset = NROM_MIRROR_16K
    ? {{(PRG_ADDR_BITS-14){1'b0}}, cpu_addr[13:0]}
    : {{(PRG_ADDR_BITS-15){1'b0}}, cpu_addr[14:0]};

assign chr_bank_offset = {{(CHR_ADDR_BITS-13){1'b0}}, ppu_addr[12:0]};
assign mirroring = HEADER_MIRRORING;
assign prg_ram_enable = NROM_PRG_RAM;
assign chr_ram_enable = NROM_CHR_RAM;
assign irq = 1'b0;

endmodule
