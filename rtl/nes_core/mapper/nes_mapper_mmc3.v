`timescale 1ns/1ps

module nes_mapper_mmc3 #(
    parameter integer PRG_ADDR_BITS = 17,
    parameter integer CHR_ADDR_BITS = 17,
    parameter integer PRG_SIZE_BYTES = 131072,
    parameter [1:0] MMC3_A12_EDGE = 2'd0,
    parameter integer MMC3_A12_COOLDOWN = 2,
    parameter [2:0] HEADER_MIRRORING = 3'd0,
    parameter MMC3_CHR_RAM = 1'b0
)(
    input wire clk,
    input wire reset,
    input wire [15:0] cpu_addr,
    input wire cpu_we,
    input wire [7:0] cpu_dout,
    input wire [13:0] ppu_addr,
    input wire ppu_a12,
    output wire [PRG_ADDR_BITS-1:0] prg_bank_offset,
    output wire [CHR_ADDR_BITS-1:0] chr_bank_offset,
    output wire [2:0] mirroring,
    output wire prg_ram_enable,
    output wire chr_ram_enable,
    output wire irq,
    output wire [7:0] irq_counter,
    output wire [7:0] irq_latch,
    output wire irq_pending,
    output wire irq_reload,
    output wire irq_enabled,
    output wire a12_filtered,
    output wire [2:0] bank_select,
    output wire [5:0] prg_bank6,
    output wire [5:0] prg_bank7,
    output wire prg_mode,
    output wire chr_inversion,
    output wire [7:0] ram_protect
);

localparam [7:0] MMC3_LAST_BANK_8K = (PRG_SIZE_BYTES >> 13) - 1;
localparam [7:0] MMC3_SECOND_LAST_BANK_8K = (PRG_SIZE_BYTES >> 13) - 2;
localparam [7:0] MMC3_A12_COOLDOWN_VALUE = MMC3_A12_COOLDOWN;

reg [2:0] bank_select_r;
reg prg_mode_r;
reg chr_inversion_r;
reg ram_enable_r;
reg [7:0] ram_protect_r;
reg [7:0] chr_bank0_r;
reg [7:0] chr_bank1_r;
reg [7:0] chr_bank2_r;
reg [7:0] chr_bank3_r;
reg [7:0] chr_bank4_r;
reg [7:0] chr_bank5_r;
reg [5:0] prg_bank6_r;
reg [5:0] prg_bank7_r;
reg [7:0] irq_latch_r;
reg [7:0] irq_counter_r;
reg irq_reload_r;
reg irq_enabled_r;
reg irq_pending_r;
reg [2:0] mirroring_r;

reg ppu_a12_d;
reg [7:0] a12_cooldown;

wire write_8000;
wire write_8001;
wire write_A000;
wire write_A001;
wire write_C000;
wire write_C001;
wire write_E000;
wire write_E001;

wire a12_edge;
wire [7:0] irq_counter_next;
reg [7:0] prg_window_bank;
wire [2:0] chr_window_base;
wire [2:0] chr_window_index;
reg [7:0] chr_window_bank;
wire [PRG_ADDR_BITS-1:0] prg_window_ext;
wire [CHR_ADDR_BITS-1:0] chr_window_ext;

assign write_8000 = cpu_we && (cpu_addr[15:13] == 3'b100) && !cpu_addr[0];
assign write_8001 = cpu_we && (cpu_addr[15:13] == 3'b100) && cpu_addr[0];
assign write_A000 = cpu_we && (cpu_addr[15:13] == 3'b101) && !cpu_addr[0];
assign write_A001 = cpu_we && (cpu_addr[15:13] == 3'b101) && cpu_addr[0];
assign write_C000 = cpu_we && (cpu_addr[15:13] == 3'b110) && !cpu_addr[0];
assign write_C001 = cpu_we && (cpu_addr[15:13] == 3'b110) && cpu_addr[0];
assign write_E000 = cpu_we && (cpu_addr[15:13] == 3'b111) && !cpu_addr[0];
assign write_E001 = cpu_we && (cpu_addr[15:13] == 3'b111) && cpu_addr[0];

assign a12_edge = (MMC3_A12_EDGE == 2'd0)
    ? (ppu_a12 & ~ppu_a12_d)
    : (~ppu_a12 & ppu_a12_d);
assign a12_filtered = (a12_cooldown == 8'd0) && a12_edge;
assign irq_counter_next = (irq_reload_r || (irq_counter_r == 8'd0))
    ? irq_latch_r
    : (irq_counter_r - 8'd1);

always @* begin
    case (cpu_addr[14:13])
        2'b00: prg_window_bank = prg_mode_r ? MMC3_SECOND_LAST_BANK_8K : {2'b00, prg_bank6_r};
        2'b01: prg_window_bank = {2'b00, prg_bank7_r};
        2'b10: prg_window_bank = prg_mode_r ? {2'b00, prg_bank6_r} : MMC3_SECOND_LAST_BANK_8K;
        default: prg_window_bank = MMC3_LAST_BANK_8K;
    endcase
end

assign chr_window_base = ppu_addr[12]
    ? {1'b1, ppu_addr[11:10]}
    : {2'b00, ppu_addr[11]};

assign chr_window_index = chr_inversion_r
    ? (chr_window_base ^ 3'b100)
    : chr_window_base;

always @* begin
    case (chr_window_index)
        3'd0: chr_window_bank = chr_bank0_r;
        3'd1: chr_window_bank = {chr_bank0_r[7:1], 1'b1};
        3'd2: chr_window_bank = chr_bank1_r;
        3'd3: chr_window_bank = {chr_bank1_r[7:1], 1'b1};
        3'd4: chr_window_bank = chr_bank2_r;
        3'd5: chr_window_bank = chr_bank3_r;
        3'd6: chr_window_bank = chr_bank4_r;
        default: chr_window_bank = chr_bank5_r;
    endcase
end

assign prg_window_ext = {{(PRG_ADDR_BITS-8){1'b0}}, prg_window_bank};
assign chr_window_ext = {{(CHR_ADDR_BITS-8){1'b0}}, chr_window_bank};

assign prg_bank_offset = (prg_window_ext << 13) | {{(PRG_ADDR_BITS-13){1'b0}}, cpu_addr[12:0]};
assign chr_bank_offset = (chr_window_ext << 10) | {{(CHR_ADDR_BITS-10){1'b0}}, ppu_addr[9:0]};
// chr_bank_offset is the FINAL CHR byte address, not a displacement to be added
// to somewhere else. ppu_addr must be the LOCAL CHR byte address the PPU presents
// on its chr_addr port; the 1 KiB window placement is applied here and the memory
// owner indexes CHR with the result directly. ppu_addr[13] (PPUCTRL[4]/[5], the
// pattern-table select) is deliberately dropped: it is a PPU-internal decode, not
// a cartridge address bit. The same dropping is what makes ppu_addr[12] -- the
// A12 line the scanline IRQ counter clocks from -- a distinct, lower address bit.
assign mirroring = mirroring_r;
assign prg_ram_enable = ram_enable_r;
assign chr_ram_enable = MMC3_CHR_RAM;
assign irq = irq_enabled_r && irq_pending_r;
assign irq_counter = irq_counter_r;
assign irq_latch = irq_latch_r;
assign irq_pending = irq_pending_r;
assign irq_reload = irq_reload_r;
assign irq_enabled = irq_enabled_r;
assign bank_select = bank_select_r;
assign prg_bank6 = prg_bank6_r;
assign prg_bank7 = prg_bank7_r;
assign prg_mode = prg_mode_r;
assign chr_inversion = chr_inversion_r;
assign ram_protect = ram_protect_r;

always @(posedge clk or posedge reset) begin
    if (reset) begin
        bank_select_r <= 3'd0;
        prg_mode_r <= 1'b0;
        chr_inversion_r <= 1'b0;
        ram_enable_r <= 1'b0;
        ram_protect_r <= 8'h00;
        chr_bank0_r <= 8'd0;
        chr_bank1_r <= 8'd0;
        chr_bank2_r <= 8'd0;
        chr_bank3_r <= 8'd0;
        chr_bank4_r <= 8'd0;
        chr_bank5_r <= 8'd0;
        prg_bank6_r <= 6'd0;
        prg_bank7_r <= 6'd1;
        irq_latch_r <= 8'd0;
        irq_counter_r <= 8'd0;
        irq_reload_r <= 1'b0;
        irq_enabled_r <= 1'b0;
        irq_pending_r <= 1'b0;
        mirroring_r <= HEADER_MIRRORING;
        ppu_a12_d <= 1'b0;
        a12_cooldown <= 8'd0;
    end else begin
        ppu_a12_d <= ppu_a12;

        if (a12_cooldown != 8'd0)
            a12_cooldown <= a12_cooldown - 8'd1;
        else if (a12_filtered)
            a12_cooldown <= MMC3_A12_COOLDOWN_VALUE;

        if (a12_filtered) begin
            irq_counter_r <= irq_counter_next;
            irq_reload_r <= 1'b0;
            if ((irq_counter_next == 8'd0) && irq_enabled_r)
                irq_pending_r <= 1'b1;
        end

        if (write_8000) begin
            bank_select_r <= cpu_dout[2:0];
            prg_mode_r <= cpu_dout[6];
            chr_inversion_r <= cpu_dout[7];
            ram_enable_r <= cpu_dout[5];
            if (!cpu_dout[5])
                ram_protect_r <= 8'h00;
        end

        if (write_8001) begin
            case (bank_select_r)
                3'd0: chr_bank0_r <= {cpu_dout[7:1], 1'b0};
                3'd1: chr_bank1_r <= {cpu_dout[7:1], 1'b0};
                3'd2: chr_bank2_r <= cpu_dout;
                3'd3: chr_bank3_r <= cpu_dout;
                3'd4: chr_bank4_r <= cpu_dout;
                3'd5: chr_bank5_r <= cpu_dout;
                3'd6: prg_bank6_r <= cpu_dout[5:0];
                default: prg_bank7_r <= cpu_dout[5:0];
            endcase
        end

        if (write_A000)
            mirroring_r <= cpu_dout[0] ? 3'd0 : 3'd1;

        if (write_A001) begin
            if (ram_enable_r)
                ram_protect_r <= cpu_dout;
        end

        if (write_C000)
            irq_latch_r <= cpu_dout;

        if (write_C001)
            irq_reload_r <= 1'b1;

        if (write_E000) begin
            irq_enabled_r <= 1'b0;
            irq_pending_r <= 1'b0;
        end

        if (write_E001)
            irq_enabled_r <= 1'b1;
    end
end

endmodule
