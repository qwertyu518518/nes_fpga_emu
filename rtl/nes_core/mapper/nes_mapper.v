`timescale 1ns/1ps

// CHR_ADDR_BITS is the width of chr_bank_offset and must cover the whole CHR
// address space. 17 bits = 128 KiB, which is exactly what MMC1 needs: its 5-bit
// 4 KiB bank reaches 0x1F000 and the 4 KiB intra-window offset adds at most
// 0xFFF, giving 0x1FFFF. Do not lower it below 17 or MMC1 bank >= 16 aliases back
// into the low 64 KiB.
// 17 is NOT enough for MMC3. nes_mapper_mmc3.v forms an 8 KiB window as
// (chr_window_bank << 10) | ppu_addr[9:0] from a full 8-bit R register, so a
// window above 0x7F needs address bit 17: bank 0xFF reaches 0x2FC00. At 17 bits
// that bit is shifted out and MMC3 CHR banks 0x80-0xFF alias onto 0x00-0x7F.
// This is a known, accepted limitation at the current width -- widening to 18
// would remove the alias, and it is not the cause of it.
module nes_mapper #(
    parameter integer PRG_ADDR_BITS = 17,
    parameter integer CHR_ADDR_BITS = 17,
    parameter integer PRG_SIZE_BYTES = 131072,
    parameter [2:0] HEADER_MIRRORING = 3'd0,
    parameter integer UxROM_BANK_BITS = 4,
    parameter integer CNROM_BANK_BITS = 2,
    parameter [1:0] UxROM_BUS_CONFLICT = 2'd1,
    parameter [1:0] CNROM_BUS_CONFLICT = 2'd1,
    parameter [1:0] MMC3_A12_EDGE = 2'd0,
    parameter integer MMC3_A12_COOLDOWN = 2,
    parameter integer NROM_PRG_SIZE_BYTES = 32768,
    parameter NROM_PRG_RAM = 1'b0,
    parameter NROM_CHR_RAM = 1'b0,
    parameter MMC1_CHR_RAM = 1'b0,
    parameter MMC3_CHR_RAM = 1'b0
)(
    input wire clk,
    input wire reset,
    input wire [7:0] mapper_select,

    input wire [15:0] cpu_addr,
    input wire cpu_we,
    input wire [7:0] cpu_dout,

    input wire [13:0] ppu_addr,
    input wire ppu_we,
    input wire [7:0] ppu_dout,
    input wire ppu_a12,

    input wire [7:0] prg_readback,

    output wire [PRG_ADDR_BITS-1:0] prg_bank_offset,
    output wire [CHR_ADDR_BITS-1:0] chr_bank_offset,
    output wire [2:0] mirroring,
    output wire [7:0] nametable_map,
    output wire prg_ram_enable,
    output wire prg_ram_we,
    output wire chr_ram_enable,
    output wire chr_ram_we,
    output wire irq,
    output wire bus_conflict,

    output wire [7:0] dbg_prg_bank_number,
    output wire [7:0] dbg_chr_bank_number,
    output wire [2:0] dbg_mapper_id,
    output wire [2:0] mmc1_serial_count,
    output wire [4:0] mmc1_serial_value,
    output wire [4:0] mmc1_control,
    output wire [4:0] mmc1_chr_bank0,
    output wire [4:0] mmc1_chr_bank1,
    output wire [4:0] mmc1_prg_bank,
    output wire [7:0] mmc3_irq_counter,
    output wire [7:0] mmc3_irq_latch,
    output wire mmc3_irq_pending,
    output wire mmc3_irq_reload,
    output wire mmc3_irq_enabled,
    output wire mmc3_a12_filtered,
    output wire [2:0] mmc3_bank_select,
    output wire [5:0] mmc3_prg_bank6,
    output wire [5:0] mmc3_prg_bank7,
    output wire mmc3_prg_mode,
    output wire mmc3_chr_inversion,
    output wire [7:0] mmc3_ram_protect
);

wire select_nrom;
wire select_mmc1;
wire select_uxrom;
wire select_cnrom;
wire select_mmc3;
wire mapper_write;
wire we_mmc1;
wire we_uxrom;
wire we_cnrom;
wire we_mmc3;

wire [PRG_ADDR_BITS-1:0] prg_offset_nrom;
wire [PRG_ADDR_BITS-1:0] prg_offset_mmc1;
wire [PRG_ADDR_BITS-1:0] prg_offset_uxrom;
wire [PRG_ADDR_BITS-1:0] prg_offset_cnrom;
wire [PRG_ADDR_BITS-1:0] prg_offset_mmc3;

wire [CHR_ADDR_BITS-1:0] chr_offset_nrom;
wire [CHR_ADDR_BITS-1:0] chr_offset_mmc1;
wire [CHR_ADDR_BITS-1:0] chr_offset_uxrom;
wire [CHR_ADDR_BITS-1:0] chr_offset_cnrom;
wire [CHR_ADDR_BITS-1:0] chr_offset_mmc3;

wire [2:0] mirroring_nrom;
wire [2:0] mirroring_mmc1;
wire [2:0] mirroring_uxrom;
wire [2:0] mirroring_cnrom;
wire [2:0] mirroring_mmc3;

wire prg_ram_nrom;
wire prg_ram_mmc1;
wire prg_ram_uxrom;
wire prg_ram_cnrom;
wire prg_ram_mmc3;

wire chr_ram_nrom;
wire chr_ram_mmc1;
wire chr_ram_uxrom;
wire chr_ram_cnrom;
wire chr_ram_mmc3;

wire irq_nrom;
wire irq_mmc1;
wire irq_uxrom;
wire irq_cnrom;
wire irq_mmc3;

wire bus_conflict_uxrom;
wire bus_conflict_cnrom;

reg [PRG_ADDR_BITS-1:0] prg_bank_offset_r;
reg [CHR_ADDR_BITS-1:0] chr_bank_offset_r;
reg [2:0] mirroring_r;
reg prg_ram_enable_r;
reg chr_ram_enable_r;
reg irq_r;
reg bus_conflict_r;
reg [2:0] dbg_mapper_id_r;

assign select_nrom = (mapper_select == 8'd0);
assign select_mmc1 = (mapper_select == 8'd1);
assign select_uxrom = (mapper_select == 8'd2);
assign select_cnrom = (mapper_select == 8'd3);
assign select_mmc3 = (mapper_select == 8'd4);

assign mapper_write = cpu_we && cpu_addr[15];

assign we_mmc1 = mapper_write && select_mmc1;
assign we_uxrom = mapper_write && select_uxrom;
assign we_cnrom = mapper_write && select_cnrom;
assign we_mmc3 = mapper_write && select_mmc3;

function [7:0] nametable_map_decode;
    input [2:0] mode;
    begin
        case (mode)
            3'd0: nametable_map_decode = 8'b01010000;
            3'd1: nametable_map_decode = 8'b01000100;
            3'd2: nametable_map_decode = 8'b00000000;
            3'd3: nametable_map_decode = 8'b01010101;
            default: nametable_map_decode = 8'b11100100;
        endcase
    end
endfunction

always @* begin
    if (select_nrom) begin
        prg_bank_offset_r = prg_offset_nrom;
        chr_bank_offset_r = chr_offset_nrom;
        mirroring_r = mirroring_nrom;
        prg_ram_enable_r = prg_ram_nrom;
        chr_ram_enable_r = chr_ram_nrom;
        irq_r = irq_nrom;
        bus_conflict_r = 1'b0;
        dbg_mapper_id_r = 3'd0;
    end else if (select_mmc1) begin
        prg_bank_offset_r = prg_offset_mmc1;
        chr_bank_offset_r = chr_offset_mmc1;
        mirroring_r = mirroring_mmc1;
        prg_ram_enable_r = prg_ram_mmc1;
        chr_ram_enable_r = chr_ram_mmc1;
        irq_r = irq_mmc1;
        bus_conflict_r = 1'b0;
        dbg_mapper_id_r = 3'd1;
    end else if (select_uxrom) begin
        prg_bank_offset_r = prg_offset_uxrom;
        chr_bank_offset_r = chr_offset_uxrom;
        mirroring_r = mirroring_uxrom;
        prg_ram_enable_r = prg_ram_uxrom;
        chr_ram_enable_r = chr_ram_uxrom;
        irq_r = irq_uxrom;
        bus_conflict_r = bus_conflict_uxrom;
        dbg_mapper_id_r = 3'd2;
    end else if (select_cnrom) begin
        prg_bank_offset_r = prg_offset_cnrom;
        chr_bank_offset_r = chr_offset_cnrom;
        mirroring_r = mirroring_cnrom;
        prg_ram_enable_r = prg_ram_cnrom;
        chr_ram_enable_r = chr_ram_cnrom;
        irq_r = irq_cnrom;
        bus_conflict_r = bus_conflict_cnrom;
        dbg_mapper_id_r = 3'd3;
    end else begin
        prg_bank_offset_r = prg_offset_mmc3;
        chr_bank_offset_r = chr_offset_mmc3;
        mirroring_r = mirroring_mmc3;
        prg_ram_enable_r = prg_ram_mmc3;
        chr_ram_enable_r = chr_ram_mmc3;
        irq_r = irq_mmc3;
        bus_conflict_r = 1'b0;
        dbg_mapper_id_r = 3'd4;
    end
end

assign prg_bank_offset = prg_bank_offset_r;
assign chr_bank_offset = chr_bank_offset_r;
assign mirroring = mirroring_r;
assign nametable_map = nametable_map_decode(mirroring_r);
assign prg_ram_enable = prg_ram_enable_r;
assign prg_ram_we = prg_ram_enable_r && cpu_we && (cpu_addr[15:13] == 3'b011);
assign chr_ram_enable = chr_ram_enable_r;
assign chr_ram_we = chr_ram_enable_r && ppu_we && (ppu_addr[13] == 1'b0);
assign irq = irq_r;
assign bus_conflict = bus_conflict_r;
assign dbg_prg_bank_number = prg_bank_offset_r[PRG_ADDR_BITS-1:13];
assign dbg_chr_bank_number = chr_bank_offset_r[CHR_ADDR_BITS-1:10];
assign dbg_mapper_id = dbg_mapper_id_r;

nes_mapper_nrom #(
    .PRG_ADDR_BITS(PRG_ADDR_BITS),
    .CHR_ADDR_BITS(CHR_ADDR_BITS),
    .PRG_SIZE_BYTES(NROM_PRG_SIZE_BYTES),
    .HEADER_MIRRORING(HEADER_MIRRORING),
    .NROM_PRG_RAM(NROM_PRG_RAM),
    .NROM_CHR_RAM(NROM_CHR_RAM)
) u_nrom (
    .cpu_addr(cpu_addr),
    .ppu_addr(ppu_addr),
    .prg_bank_offset(prg_offset_nrom),
    .chr_bank_offset(chr_offset_nrom),
    .mirroring(mirroring_nrom),
    .prg_ram_enable(prg_ram_nrom),
    .chr_ram_enable(chr_ram_nrom),
    .irq(irq_nrom)
);

nes_mapper_mmc1 #(
    .PRG_ADDR_BITS(PRG_ADDR_BITS),
    .CHR_ADDR_BITS(CHR_ADDR_BITS),
    .PRG_SIZE_BYTES(PRG_SIZE_BYTES),
    .MMC1_CHR_RAM(MMC1_CHR_RAM)
) u_mmc1 (
    .clk(clk),
    .reset(reset),
    .cpu_addr(cpu_addr),
    .cpu_we(we_mmc1),
    .cpu_dout(cpu_dout),
    .ppu_addr(ppu_addr),
    .prg_bank_offset(prg_offset_mmc1),
    .chr_bank_offset(chr_offset_mmc1),
    .mirroring(mirroring_mmc1),
    .prg_ram_enable(prg_ram_mmc1),
    .chr_ram_enable(chr_ram_mmc1),
    .irq(irq_mmc1),
    .serial_count(mmc1_serial_count),
    .serial_value(mmc1_serial_value),
    .control(mmc1_control),
    .chr_bank0(mmc1_chr_bank0),
    .chr_bank1(mmc1_chr_bank1),
    .prg_bank(mmc1_prg_bank)
);

nes_mapper_uxrom #(
    .PRG_ADDR_BITS(PRG_ADDR_BITS),
    .CHR_ADDR_BITS(CHR_ADDR_BITS),
    .PRG_SIZE_BYTES(PRG_SIZE_BYTES),
    .UxROM_BANK_BITS(UxROM_BANK_BITS),
    .UxROM_BUS_CONFLICT(UxROM_BUS_CONFLICT),
    .HEADER_MIRRORING(HEADER_MIRRORING)
) u_uxrom (
    .clk(clk),
    .reset(reset),
    .cpu_addr(cpu_addr),
    .cpu_we(we_uxrom),
    .cpu_dout(cpu_dout),
    .ppu_addr(ppu_addr),
    .prg_readback(prg_readback),
    .prg_bank_offset(prg_offset_uxrom),
    .chr_bank_offset(chr_offset_uxrom),
    .mirroring(mirroring_uxrom),
    .prg_ram_enable(prg_ram_uxrom),
    .chr_ram_enable(chr_ram_uxrom),
    .irq(irq_uxrom),
    .bus_conflict(bus_conflict_uxrom)
);

nes_mapper_cnrom #(
    .PRG_ADDR_BITS(PRG_ADDR_BITS),
    .CHR_ADDR_BITS(CHR_ADDR_BITS),
    .PRG_SIZE_BYTES(PRG_SIZE_BYTES),
    .CNROM_BANK_BITS(CNROM_BANK_BITS),
    .CNROM_BUS_CONFLICT(CNROM_BUS_CONFLICT),
    .HEADER_MIRRORING(HEADER_MIRRORING)
) u_cnrom (
    .clk(clk),
    .reset(reset),
    .cpu_addr(cpu_addr),
    .cpu_we(we_cnrom),
    .cpu_dout(cpu_dout),
    .ppu_addr(ppu_addr),
    .prg_readback(prg_readback),
    .prg_bank_offset(prg_offset_cnrom),
    .chr_bank_offset(chr_offset_cnrom),
    .mirroring(mirroring_cnrom),
    .prg_ram_enable(prg_ram_cnrom),
    .chr_ram_enable(chr_ram_cnrom),
    .irq(irq_cnrom),
    .bus_conflict(bus_conflict_cnrom)
);

nes_mapper_mmc3 #(
    .PRG_ADDR_BITS(PRG_ADDR_BITS),
    .CHR_ADDR_BITS(CHR_ADDR_BITS),
    .PRG_SIZE_BYTES(PRG_SIZE_BYTES),
    .MMC3_A12_EDGE(MMC3_A12_EDGE),
    .MMC3_A12_COOLDOWN(MMC3_A12_COOLDOWN),
    .HEADER_MIRRORING(HEADER_MIRRORING),
    .MMC3_CHR_RAM(MMC3_CHR_RAM)
) u_mmc3 (
    .clk(clk),
    .reset(reset),
    .cpu_addr(cpu_addr),
    .cpu_we(we_mmc3),
    .cpu_dout(cpu_dout),
    .ppu_addr(ppu_addr),
    .ppu_a12(ppu_a12),
    .prg_bank_offset(prg_offset_mmc3),
    .chr_bank_offset(chr_offset_mmc3),
    .mirroring(mirroring_mmc3),
    .prg_ram_enable(prg_ram_mmc3),
    .chr_ram_enable(chr_ram_mmc3),
    .irq(irq_mmc3),
    .irq_counter(mmc3_irq_counter),
    .irq_latch(mmc3_irq_latch),
    .irq_pending(mmc3_irq_pending),
    .irq_reload(mmc3_irq_reload),
    .irq_enabled(mmc3_irq_enabled),
    .a12_filtered(mmc3_a12_filtered),
    .bank_select(mmc3_bank_select),
    .prg_bank6(mmc3_prg_bank6),
    .prg_bank7(mmc3_prg_bank7),
    .prg_mode(mmc3_prg_mode),
    .chr_inversion(mmc3_chr_inversion),
    .ram_protect(mmc3_ram_protect)
);

endmodule
