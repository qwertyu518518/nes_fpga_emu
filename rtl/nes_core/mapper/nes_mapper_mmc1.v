`timescale 1ns/1ps

module nes_mapper_mmc1 #(
    parameter integer PRG_ADDR_BITS = 17,
    parameter integer CHR_ADDR_BITS = 17,
    parameter integer PRG_SIZE_BYTES = 131072,
    parameter MMC1_CHR_RAM = 1'b0
)(
    input wire clk,
    input wire reset,
    input wire [15:0] cpu_addr,
    input wire cpu_we,
    input wire [7:0] cpu_dout,
    input wire [13:0] ppu_addr,
    output wire [PRG_ADDR_BITS-1:0] prg_bank_offset,
    output wire [CHR_ADDR_BITS-1:0] chr_bank_offset,
    output wire [2:0] mirroring,
    output wire prg_ram_enable,
    output wire chr_ram_enable,
    output wire irq,
    output wire [2:0] serial_count,
    output wire [4:0] serial_value,
    output wire [4:0] control,
    output wire [4:0] chr_bank0,
    output wire [4:0] chr_bank1,
    output wire [4:0] prg_bank
);

localparam [7:0] MMC1_LAST_BANK_16K = (PRG_SIZE_BYTES >> 14) - 1;
localparam [4:0] MMC1_CONTROL_RESET = 5'b01100;
localparam [4:0] MMC1_SERIAL_LAST_BIT = 3'd4;

reg [2:0] serial_count_r;
reg [4:0] serial_value_r;
reg [4:0] control_r;
reg [4:0] chr_bank0_r;
reg [4:0] chr_bank1_r;
reg [4:0] prg_bank_r;

reg [4:0] prg_bank16_select;
reg [4:0] chr_bank4k_select;
reg [2:0] mirroring_select;
wire [PRG_ADDR_BITS-1:0] prg_bank_ext;
wire [CHR_ADDR_BITS-1:0] chr_bank_ext;

always @* begin
    case (control_r[3:2])
        2'b00, 2'b01: prg_bank16_select = {prg_bank_r[4:1], cpu_addr[14]};
        2'b10: prg_bank16_select = cpu_addr[14] ? prg_bank_r : 5'd0;
        2'b11: prg_bank16_select = cpu_addr[14] ? MMC1_LAST_BANK_16K : prg_bank_r;
    endcase
end

always @* begin
    if (control_r[4])
        chr_bank4k_select = ppu_addr[12] ? chr_bank1_r : chr_bank0_r;
    else
        chr_bank4k_select = {chr_bank0_r[4:1], ppu_addr[12]};
end

assign prg_bank_ext = {{(PRG_ADDR_BITS-5){1'b0}}, prg_bank16_select};
assign chr_bank_ext = {{(CHR_ADDR_BITS-5){1'b0}}, chr_bank4k_select};

assign prg_bank_offset = (prg_bank_ext << 14) | {{(PRG_ADDR_BITS-14){1'b0}}, cpu_addr[13:0]};
assign chr_bank_offset = (chr_bank_ext << 12) | {{(CHR_ADDR_BITS-12){1'b0}}, ppu_addr[11:0]};
// chr_bank_offset is the FINAL CHR byte address, not a displacement to be added
// to somewhere else. ppu_addr must be the LOCAL CHR byte address the PPU presents
// on its chr_addr port; the 4 KiB window select and its placement are applied
// here, and the memory owner indexes CHR with the result directly. ppu_addr[13]
// (PPUCTRL[4]/[5], the pattern-table select) is deliberately dropped: it is a
// PPU-internal decode, not a cartridge address bit.
assign prg_ram_enable = ~prg_bank_r[4];
assign chr_ram_enable = MMC1_CHR_RAM;
assign irq = 1'b0;
assign serial_count = serial_count_r;
assign serial_value = serial_value_r;
assign control = control_r;
assign chr_bank0 = chr_bank0_r;
assign chr_bank1 = chr_bank1_r;
assign prg_bank = prg_bank_r;

assign mirroring = mirroring_select;

always @* begin
    case (control_r[1:0])
        2'd0: mirroring_select = 3'd2;
        2'd1: mirroring_select = 3'd3;
        2'd2: mirroring_select = 3'd1;
        default: mirroring_select = 3'd0;
    endcase
end

always @(posedge clk or posedge reset) begin
    if (reset) begin
        serial_count_r <= 3'd0;
        serial_value_r <= 5'd0;
        control_r <= MMC1_CONTROL_RESET;
        chr_bank0_r <= 5'd0;
        chr_bank1_r <= 5'd0;
        prg_bank_r <= 5'd0;
    end else if (cpu_we) begin
        if (cpu_dout[7]) begin
            serial_count_r <= 3'd0;
            serial_value_r <= 5'd0;
            control_r <= MMC1_CONTROL_RESET;
            chr_bank0_r <= 5'd0;
            chr_bank1_r <= 5'd0;
            prg_bank_r <= 5'd0;
        end else begin
            serial_value_r[serial_count_r] <= cpu_dout[0];
            if (serial_count_r == MMC1_SERIAL_LAST_BIT) begin
                serial_count_r <= 3'd0;
                serial_value_r <= 5'd0;
                case (cpu_addr[14:13])
                    2'b00: control_r <= {cpu_dout[0], serial_value_r[3:0]};
                    2'b01: chr_bank0_r <= {cpu_dout[0], serial_value_r[3:0]};
                    2'b10: chr_bank1_r <= {cpu_dout[0], serial_value_r[3:0]};
                    default: prg_bank_r <= {cpu_dout[0], serial_value_r[3:0]};
                endcase
            end else begin
                serial_count_r <= serial_count_r + 3'd1;
            end
        end
    end
end

endmodule
