`timescale 1ns/1ps

module tb_nes_mapper;

reg clk;
reg reset;
reg [7:0] mapper_select;
reg [15:0] cpu_addr;
reg cpu_we;
reg [7:0] cpu_dout;
reg [13:0] ppu_addr;
reg ppu_we;
reg [7:0] ppu_dout;
reg ppu_a12;
reg readback_force_enable;
reg [7:0] readback_force_data;

wire [16:0] prg_bank_offset;
wire [16:0] chr_bank_offset;
wire [2:0] mirroring;
wire [7:0] nametable_map;
wire prg_ram_enable;
wire prg_ram_we;
wire chr_ram_enable;
wire chr_ram_we;
wire irq;
wire bus_conflict;
wire [7:0] dbg_prg_bank_number;
wire [7:0] dbg_chr_bank_number;
wire [2:0] dbg_mapper_id;
wire [2:0] mmc1_serial_count;
wire [4:0] mmc1_serial_value;
wire [4:0] mmc1_control;
wire [4:0] mmc1_chr_bank0;
wire [4:0] mmc1_chr_bank1;
wire [4:0] mmc1_prg_bank;
wire [7:0] mmc3_irq_counter;
wire [7:0] mmc3_irq_latch;
wire mmc3_irq_pending;
wire mmc3_irq_reload;
wire mmc3_irq_enabled;
wire mmc3_a12_filtered;
wire [2:0] mmc3_bank_select;
wire [5:0] mmc3_prg_bank6;
wire [5:0] mmc3_prg_bank7;
wire mmc3_prg_mode;
wire mmc3_chr_inversion;

wire [16:0] reject_prg_bank_offset;
wire [16:0] reject_chr_bank_offset;
wire [2:0] reject_mirroring;
wire reject_prg_ram_enable;
wire reject_chr_ram_enable;
wire reject_irq;
wire reject_bus_conflict;

reg [7:0] prg_rom [0:131071];
reg [7:0] chr_rom [0:65535];
reg [7:0] chr_ram [0:8191];
reg [7:0] prg_ram [0:8191];
reg [7:0] cpu_din;
wire [7:0] prg_readback;

integer init_index;
integer fail_count;
integer check_count;
reg [7:0] captured_data;

nes_mapper #(
    .PRG_ADDR_BITS(17),
    .CHR_ADDR_BITS(17),
    .PRG_SIZE_BYTES(131072),
    .HEADER_MIRRORING(3'd0),
    .UxROM_BANK_BITS(3),
    .CNROM_BANK_BITS(2),
    .UxROM_BUS_CONFLICT(2'd1),
    .CNROM_BUS_CONFLICT(2'd1),
    .NROM_PRG_SIZE_BYTES(32768),
    .NROM_CHR_RAM(1'b1)
) dut (
    .clk(clk),
    .reset(reset),
    .mapper_select(mapper_select),
    .cpu_addr(cpu_addr),
    .cpu_we(cpu_we),
    .cpu_dout(cpu_dout),
    .ppu_addr(ppu_addr),
    .ppu_we(ppu_we),
    .ppu_dout(ppu_dout),
    .ppu_a12(ppu_a12),
    .prg_readback(prg_readback),
    .prg_bank_offset(prg_bank_offset),
    .chr_bank_offset(chr_bank_offset),
    .mirroring(mirroring),
    .nametable_map(nametable_map),
    .prg_ram_enable(prg_ram_enable),
    .prg_ram_we(prg_ram_we),
    .chr_ram_enable(chr_ram_enable),
    .chr_ram_we(chr_ram_we),
    .irq(irq),
    .bus_conflict(bus_conflict),
    .dbg_prg_bank_number(dbg_prg_bank_number),
    .dbg_chr_bank_number(dbg_chr_bank_number),
    .dbg_mapper_id(dbg_mapper_id),
    .mmc1_serial_count(mmc1_serial_count),
    .mmc1_serial_value(mmc1_serial_value),
    .mmc1_control(mmc1_control),
    .mmc1_chr_bank0(mmc1_chr_bank0),
    .mmc1_chr_bank1(mmc1_chr_bank1),
    .mmc1_prg_bank(mmc1_prg_bank),
    .mmc3_irq_counter(mmc3_irq_counter),
    .mmc3_irq_latch(mmc3_irq_latch),
    .mmc3_irq_pending(mmc3_irq_pending),
    .mmc3_irq_reload(mmc3_irq_reload),
    .mmc3_irq_enabled(mmc3_irq_enabled),
    .mmc3_a12_filtered(mmc3_a12_filtered),
    .mmc3_bank_select(mmc3_bank_select),
    .mmc3_prg_bank6(mmc3_prg_bank6),
    .mmc3_prg_bank7(mmc3_prg_bank7),
    .mmc3_prg_mode(mmc3_prg_mode),
    .mmc3_chr_inversion(mmc3_chr_inversion)
);

nes_mapper_uxrom #(
    .PRG_ADDR_BITS(17),
    .CHR_ADDR_BITS(17),
    .PRG_SIZE_BYTES(131072),
    .UxROM_BANK_BITS(3),
    .UxROM_BUS_CONFLICT(2'd2),
    .HEADER_MIRRORING(3'd0)
) u_uxrom_reject (
    .clk(clk),
    .reset(reset),
    .cpu_addr(cpu_addr),
    .cpu_we(cpu_we && (mapper_select == 8'd2)),
    .cpu_dout(cpu_dout),
    .ppu_addr(ppu_addr),
    .prg_readback(prg_readback),
    .prg_bank_offset(reject_prg_bank_offset),
    .chr_bank_offset(reject_chr_bank_offset),
    .mirroring(reject_mirroring),
    .prg_ram_enable(reject_prg_ram_enable),
    .chr_ram_enable(reject_chr_ram_enable),
    .irq(reject_irq),
    .bus_conflict(reject_bus_conflict)
);

always #5 clk = ~clk;

function [7:0] prg_signature;
    input [16:0] offset;
    begin
        prg_signature = 8'h40 + offset[16:13];
    end
endfunction

function [7:0] chr_signature;
    input [15:0] offset;
    begin
        chr_signature = 8'h80 + offset[15:10];
    end
endfunction

function [7:0] chr_data;
    input [12:0] ppu_offset;
    begin
        if (chr_ram_enable)
            chr_data = chr_ram[ppu_offset];
        else
            chr_data = chr_rom[chr_bank_offset[15:0]];
    end
endfunction

assign prg_readback = readback_force_enable
    ? readback_force_data
    : prg_rom[prg_bank_offset[16:0]];

always @* begin
    if (cpu_addr[15:13] == 3'b011)
        cpu_din = prg_ram[cpu_addr[12:0]];
    else
        cpu_din = prg_rom[prg_bank_offset[16:0]];
end

always @(posedge clk) begin
    if (chr_ram_we)
        chr_ram[ppu_addr[12:0]] <= ppu_dout;
    if (prg_ram_we)
        prg_ram[cpu_addr[12:0]] <= cpu_dout;
end

task expect8;
    input [8*72-1:0] label;
    input [7:0] actual;
    input [7:0] expected;
    begin
        check_count = check_count + 1;
        if (actual !== expected) begin
            fail_count = fail_count + 1;
            $display("FAIL %0s: got %02h expected %02h", label, actual, expected);
        end
    end
endtask

task expect1;
    input [8*72-1:0] label;
    input actual;
    input expected;
    begin
        check_count = check_count + 1;
        if (actual !== expected) begin
            fail_count = fail_count + 1;
            $display("FAIL %0s: got %b expected %b", label, actual, expected);
        end
    end
endtask

task expect2;
    input [8*72-1:0] label;
    input [1:0] actual;
    input [1:0] expected;
    begin
        check_count = check_count + 1;
        if (actual !== expected) begin
            fail_count = fail_count + 1;
            $display("FAIL %0s: got %0d expected %0d", label, actual, expected);
        end
    end
endtask

task expect3;
    input [8*72-1:0] label;
    input [2:0] actual;
    input [2:0] expected;
    begin
        check_count = check_count + 1;
        if (actual !== expected) begin
            fail_count = fail_count + 1;
            $display("FAIL %0s: got %0d expected %0d", label, actual, expected);
        end
    end
endtask

task expect5;
    input [8*72-1:0] label;
    input [4:0] actual;
    input [4:0] expected;
    begin
        check_count = check_count + 1;
        if (actual !== expected) begin
            fail_count = fail_count + 1;
            $display("FAIL %0s: got %02h expected %02h", label, actual, expected);
        end
    end
endtask

task expect17;
    input [8*72-1:0] label;
    input [16:0] actual;
    input [16:0] expected;
    begin
        check_count = check_count + 1;
        if (actual !== expected) begin
            fail_count = fail_count + 1;
            $display("FAIL %0s: got %05h expected %05h", label, actual, expected);
        end
    end
endtask

task expect16;
    input [8*72-1:0] label;
    input [15:0] actual;
    input [15:0] expected;
    begin
        check_count = check_count + 1;
        if (actual !== expected) begin
            fail_count = fail_count + 1;
            $display("FAIL %0s: got %04h expected %04h", label, actual, expected);
        end
    end
endtask

task expect32;
    input [8*72-1:0] label;
    input [31:0] actual;
    input [31:0] expected;
    begin
        check_count = check_count + 1;
        if (actual !== expected) begin
            fail_count = fail_count + 1;
            $display("FAIL %0s: got %08h expected %08h", label, actual, expected);
        end
    end
endtask

task apply_reset;
    begin
        cpu_we = 1'b0;
        cpu_dout = 8'h00;
        ppu_we = 1'b0;
        ppu_dout = 8'h00;
        ppu_a12 = 1'b0;
        cpu_addr = 16'h0000;
        ppu_addr = 14'h0000;
        readback_force_enable = 1'b1;
        readback_force_data = 8'hFF;
        reset = 1'b1;
        repeat (3) @(posedge clk);
        #1 reset = 1'b0;
        @(posedge clk);
        #1;
    end
endtask

task cpu_write;
    input [15:0] address;
    input [7:0] data;
    begin
        cpu_addr = address;
        cpu_dout = data;
        cpu_we = 1'b1;
        #1;
        @(posedge clk);
        #1;
        cpu_we = 1'b0;
        cpu_dout = 8'h00;
    end
endtask

task cpu_read;
    input [15:0] address;
    output [7:0] data;
    begin
        cpu_addr = address;
        cpu_we = 1'b0;
        #1 data = cpu_din;
        @(posedge clk);
        #1;
    end
endtask

task ppu_write;
    input [13:0] address;
    input [7:0] data;
    begin
        ppu_addr = address;
        ppu_dout = data;
        ppu_we = 1'b1;
        #1;
        @(posedge clk);
        #1;
        ppu_we = 1'b0;
        ppu_dout = 8'h00;
    end
endtask

task test_nrom_32k;
    begin
        mapper_select = 8'd0;
        apply_reset;
        expect3("nrom mapper id", dbg_mapper_id, 3'd0);
        expect3("nrom header mirroring horizontal", mirroring, 3'd0);
        expect32("nrom nametable map horizontal", nametable_map, 32'h00000050);
        expect1("nrom chram present", chr_ram_enable, 1'b1);
        expect1("nrom prg ram absent", prg_ram_enable, 1'b0);
        expect1("nrom irq low", irq, 1'b0);
        cpu_addr = 16'h6000;
        cpu_dout = 8'h11;
        cpu_we = 1'b1;
        #1 expect1("nrom prg ram we low at 6000", prg_ram_we, 1'b0);
        @(posedge clk);
        #1;
        cpu_we = 1'b0;
        cpu_dout = 8'h00;
        cpu_read(16'h8000, captured_data);
        expect8("nrom 8000 8k bank0", captured_data, prg_signature(17'h00000));
        expect17("nrom 8000 offset", prg_bank_offset, 17'h00000);
        cpu_read(16'hBFFF, captured_data);
        expect8("nrom BFFF 8k bank1", captured_data, prg_signature(17'h02000));
        expect17("nrom BFFF offset", prg_bank_offset, 17'h03FFF);
        cpu_read(16'hC000, captured_data);
        expect8("nrom C000 8k bank2", captured_data, prg_signature(17'h04000));
        expect17("nrom C000 offset", prg_bank_offset, 17'h04000);
        cpu_read(16'hFFFF, captured_data);
        expect8("nrom FFFF 8k bank3", captured_data, prg_signature(17'h06000));
        ppu_addr = 14'h0000;
        #1;
        expect8("nrom chr 0000", chr_data(13'h0000), chr_signature(16'h0000));
        ppu_addr = 14'h1000;
        #1;
        expect8("nrom chr 1000", chr_data(13'h1000), chr_signature(16'h1000));
        expect16("nrom chr offset 1000", chr_bank_offset, 16'h1000);
        ppu_addr = 14'h1FFF;
        #1;
        expect8("nrom chr 1FFF", chr_data(13'h1FFF), chr_signature(16'h1FFF));
        expect16("nrom chr offset 1FFF", chr_bank_offset, 16'h1FFF);
        ppu_write(14'h0123, 8'h5A);
        expect8("nrom chr ram writeback", chr_ram[13'h0123], 8'h5A);
        expect8("nrom chr ram neighbours untouched", chr_ram[13'h0122], chr_signature(16'h0122));
        expect8("nrom chr rom untouched", chr_rom[16'h0123], chr_signature(16'h0123));
        expect16("nrom chr ram index is ppu addr", chr_bank_offset, 16'h0123);
        ppu_write(14'h2123, 8'h77);
        expect8("nrom ppu write above chr ignored", chr_ram[13'h0123], 8'h5A);
        $display("NROM 32K prg windows, chr ram writes, header mirroring PASS");
    end
endtask

task test_uxrom_banks;
    begin
        mapper_select = 8'd2;
        apply_reset;
        expect3("uxrom mapper id", dbg_mapper_id, 3'd2);
        expect1("uxrom prg ram absent", prg_ram_enable, 1'b0);
        expect1("uxrom chram present", chr_ram_enable, 1'b1);
        expect3("uxrom header mirroring", mirroring, 3'd0);
        expect1("uxrom irq low", irq, 1'b0);
        cpu_read(16'h8000, captured_data);
        expect8("uxrom reset bank0", captured_data, prg_signature(17'h00000));
        cpu_read(16'hC000, captured_data);
        expect8("uxrom reset fixed last", captured_data, prg_signature(17'h1C000));
        expect17("uxrom fixed last offset", prg_bank_offset, 17'h1C000);
        cpu_write(16'h8000, 8'h05);
        cpu_read(16'h8000, captured_data);
        expect8("uxrom bank5 window", captured_data, prg_signature(17'h14000));
        cpu_read(16'hBFFF, captured_data);
        expect8("uxrom bank5 window end", captured_data, prg_signature(17'h17FFF));
        cpu_read(16'hC000, captured_data);
        expect8("uxrom fixed last unchanged", captured_data, prg_signature(17'h1C000));
        cpu_write(16'hFFFF, 8'h02);
        cpu_read(16'h8000, captured_data);
        expect8("uxrom bank2 from FFFF write", captured_data, prg_signature(17'h08000));
        cpu_read(16'hC000, captured_data);
        expect8("uxrom fixed last still unchanged", captured_data, prg_signature(17'h1C000));
        cpu_write(16'h9ABC, 8'h06);
        cpu_read(16'h8000, captured_data);
        expect8("uxrom bank6 from 9ABC write", captured_data, prg_signature(17'h18000));
        cpu_write(16'h8000, 8'h1F);
        cpu_read(16'h8000, captured_data);
        expect8("uxrom bank bits masked to 3", captured_data, prg_signature(17'h1C000));
        cpu_write(16'h7FFF, 8'h01);
        cpu_read(16'h8000, captured_data);
        expect8("uxrom write below 8000 ignored", captured_data, prg_signature(17'h1C000));
        ppu_write(14'h05A5, 8'h77);
        expect8("uxrom chr ram write", chr_ram[13'h05A5], 8'h77);
        expect16("uxrom chr offset follows ppu addr", chr_bank_offset, 16'h05A5);
        $display("UXROM 16K bank register, fixed last bank, chr ram PASS");
    end
endtask

task test_uxrom_bus_conflict_and;
    begin
        mapper_select = 8'd2;
        apply_reset;
        expect2("uxrom and mode selected", dut.UxROM_BUS_CONFLICT, 2'd1);
        expect2("uxrom and mode on submodule", dut.u_uxrom.UxROM_BUS_CONFLICT, 2'd1);
        readback_force_data = 8'h5A;
        cpu_addr = 16'h8000;
        cpu_dout = 8'h07;
        cpu_we = 1'b1;
        #1 expect1("uxrom conflict flagged", bus_conflict, 1'b1);
        expect8("uxrom readback comes from the bus", prg_readback, 8'h5A);
        @(posedge clk);
        #1;
        cpu_we = 1'b0;
        cpu_dout = 8'h00;
        cpu_read(16'h8000, captured_data);
        expect8("uxrom 07 and 5A latches bank2", captured_data, prg_signature(17'h08000));
        readback_force_data = 8'h03;
        cpu_addr = 16'h8000;
        cpu_dout = 8'h03;
        cpu_we = 1'b1;
        #1 expect1("uxrom matching write not flagged", bus_conflict, 1'b0);
        @(posedge clk);
        #1;
        cpu_we = 1'b0;
        cpu_dout = 8'h00;
        cpu_read(16'h8000, captured_data);
        expect8("uxrom clean write selects bank3", captured_data, prg_signature(17'h0C000));
        readback_force_enable = 1'b0;
        cpu_addr = 16'h8000;
        #1 expect8("uxrom unforced readback is the rom byte", prg_readback, prg_signature(17'h0C000));
        cpu_dout = 8'h06;
        cpu_we = 1'b1;
        #1 expect1("uxrom rom driven write flagged", bus_conflict, 1'b1);
        @(posedge clk);
        #1;
        cpu_we = 1'b0;
        cpu_dout = 8'h00;
        cpu_read(16'h8000, captured_data);
        expect8("uxrom 06 and 46 latches bank6", captured_data, prg_signature(17'h18000));
        readback_force_enable = 1'b1;
        $display("UXROM bus conflict AND latch driven by external rom readback PASS");
    end
endtask

task test_uxrom_bus_conflict_reject;
    begin
        mapper_select = 8'd2;
        apply_reset;
        expect2("uxrom reject mode on submodule", u_uxrom_reject.UxROM_BUS_CONFLICT, 2'd2);
        readback_force_data = 8'h5A;
        cpu_addr = 16'h8000;
        cpu_dout = 8'h07;
        cpu_we = 1'b1;
        #1 expect1("uxrom reject flags conflict", reject_bus_conflict, 1'b1);
        @(posedge clk);
        #1;
        cpu_we = 1'b0;
        cpu_dout = 8'h00;
        expect17("uxrom reject keeps bank0", reject_prg_bank_offset, 17'h00000);
        cpu_addr = 16'h8000;
        cpu_dout = 8'h5A;
        cpu_we = 1'b1;
        #1 expect1("uxrom reject clean write not flagged", reject_bus_conflict, 1'b0);
        @(posedge clk);
        #1;
        cpu_we = 1'b0;
        cpu_dout = 8'h00;
        expect17("uxrom reject clean write applies", reject_prg_bank_offset, 17'h08000);
        readback_force_data = 8'h03;
        cpu_addr = 16'h8000;
        cpu_dout = 8'h02;
        cpu_we = 1'b1;
        #1 expect1("uxrom reject mismatch flagged", reject_bus_conflict, 1'b1);
        @(posedge clk);
        #1;
        cpu_we = 1'b0;
        cpu_dout = 8'h00;
        expect17("uxrom reject still bank2", reject_prg_bank_offset, 17'h08000);
        cpu_addr = 16'h8000;
        cpu_dout = 8'h03;
        cpu_we = 1'b1;
        #1 expect1("uxrom reject match not flagged", reject_bus_conflict, 1'b0);
        @(posedge clk);
        #1;
        cpu_we = 1'b0;
        cpu_dout = 8'h00;
        expect17("uxrom reject match applies", reject_prg_bank_offset, 17'h0C000);
        $display("UXROM bus conflict reject-on-mismatch mode PASS");
    end
endtask

task test_cnrom;
    begin
        mapper_select = 8'd3;
        apply_reset;
        expect3("cnrom mapper id", dbg_mapper_id, 3'd3);
        expect1("cnrom chr ram absent", chr_ram_enable, 1'b0);
        expect1("cnrom prg ram absent", prg_ram_enable, 1'b0);
        expect1("cnrom irq low", irq, 1'b0);
        ppu_addr = 14'h0000;
        #1;
        expect8("cnrom chr bank0", chr_data(13'h0000), chr_signature(16'h0000));
        expect16("cnrom chr bank0 offset", chr_bank_offset, 16'h0000);
        ppu_addr = 14'h1FFF;
        #1;
        expect8("cnrom chr bank0 high", chr_data(13'h1FFF), chr_signature(16'h1FFF));
        expect16("cnrom chr bank0 high offset", chr_bank_offset, 16'h1FFF);
        cpu_read(16'h8000, captured_data);
        expect8("cnrom prg fixed low", captured_data, prg_signature(17'h00000));
        cpu_read(16'hFFFF, captured_data);
        expect8("cnrom prg fixed high", captured_data, prg_signature(17'h03FFF));
        expect17("cnrom prg mirrors 16k", prg_bank_offset, 17'h03FFF);
        cpu_addr = 16'h6000;
        cpu_we = 1'b1;
        cpu_dout = 8'h00;
        #1 expect1("cnrom prg ram we low", prg_ram_we, 1'b0);
        @(posedge clk);
        #1;
        cpu_we = 1'b0;
        cpu_write(16'h8000, 8'h02);
        ppu_addr = 14'h0000;
        #1;
        expect8("cnrom chr bank2 low", chr_data(13'h0000), chr_signature(16'h4000));
        expect16("cnrom chr bank2 low offset", chr_bank_offset, 16'h4000);
        ppu_addr = 14'h1FFF;
        #1;
        expect8("cnrom chr bank2 high", chr_data(13'h1FFF), chr_signature(16'h5FFF));
        expect16("cnrom chr bank2 high offset", chr_bank_offset, 16'h5FFF);
        cpu_read(16'h8000, captured_data);
        expect8("cnrom prg unchanged by bank write", captured_data, prg_signature(17'h00000));
        cpu_write(16'hC000, 8'h03);
        ppu_addr = 14'h0000;
        #1;
        expect8("cnrom chr bank3 low", chr_data(13'h0000), chr_signature(16'h6000));
        ppu_addr = 14'h1234;
        #1;
        expect8("cnrom chr bank3 mid", chr_data(13'h1234), chr_signature(16'h7234));
        expect16("cnrom chr bank3 mid offset", chr_bank_offset, 16'h7234);
        ppu_write(14'h0000, 8'hEE);
        expect8("cnrom chr rom write ignored", chr_rom[16'h0000], chr_signature(16'h0000));
        $display("CNROM 8K chr bank, fixed 16K prg, chr rom write ignore PASS");
    end
endtask

task test_cnrom_bus_conflict;
    begin
        mapper_select = 8'd3;
        apply_reset;
        expect2("cnrom and mode selected", dut.CNROM_BUS_CONFLICT, 2'd1);
        expect2("cnrom and mode on submodule", dut.u_cnrom.CNROM_BUS_CONFLICT, 2'd1);
        readback_force_data = 8'h5A;
        cpu_addr = 16'h8000;
        cpu_dout = 8'h03;
        cpu_we = 1'b1;
        #1 expect1("cnrom conflict flagged", bus_conflict, 1'b1);
        expect8("cnrom readback at 8000", prg_readback, 8'h5A);
        @(posedge clk);
        #1;
        cpu_we = 1'b0;
        cpu_dout = 8'h00;
        ppu_addr = 14'h0000;
        #1;
        expect16("cnrom 03 and 5A selects chr bank2", chr_bank_offset, 16'h4000);
        readback_force_data = 8'h02;
        cpu_addr = 16'h8000;
        cpu_dout = 8'h02;
        cpu_we = 1'b1;
        #1 expect1("cnrom matching write not flagged", bus_conflict, 1'b0);
        @(posedge clk);
        #1;
        cpu_we = 1'b0;
        cpu_dout = 8'h00;
        ppu_addr = 14'h0000;
        #1;
        expect16("cnrom clean write keeps chr bank2", chr_bank_offset, 16'h4000);
        readback_force_enable = 1'b0;
        cpu_addr = 16'h8000;
        #1 expect8("cnrom unforced readback is the rom byte", prg_readback, prg_signature(17'h00000));
        cpu_dout = 8'h03;
        cpu_we = 1'b1;
        #1 expect1("cnrom rom driven write flagged", bus_conflict, 1'b1);
        @(posedge clk);
        #1;
        cpu_we = 1'b0;
        cpu_dout = 8'h00;
        ppu_addr = 14'h0000;
        #1;
        expect16("cnrom 03 and 40 selects chr bank0", chr_bank_offset, 16'h0000);
        readback_force_enable = 1'b1;
        $display("CNROM bus conflict AND latch uses per-address rom readback PASS");
    end
endtask

task test_select_isolation;
    begin
        mapper_select = 8'd2;
        apply_reset;
        cpu_write(16'h8000, 8'h05);
        mapper_select = 8'd3;
        cpu_write(16'h8000, 8'h03);
        mapper_select = 8'd2;
        cpu_read(16'h8000, captured_data);
        expect8("uxrom keeps its bank across select", captured_data, prg_signature(17'h14000));
        mapper_select = 8'd3;
        ppu_addr = 14'h0000;
        #1;
        expect16("cnrom kept its chr bank", chr_bank_offset, 16'h6000);
        mapper_select = 8'd0;
        cpu_read(16'h8000, captured_data);
        expect8("nrom ignores uxrom bank", captured_data, prg_signature(17'h00000));
        expect1("mmc3 irq low under mapper 0", irq, 1'b0);
        $display("MAPPER select gating prevents cross-mapper register writes PASS");
    end
endtask

initial begin
    clk = 1'b0;
    reset = 1'b1;
    mapper_select = 8'd0;
    cpu_addr = 16'h0000;
    cpu_we = 1'b0;
    cpu_dout = 8'h00;
    ppu_addr = 14'h0000;
    ppu_we = 1'b0;
    ppu_dout = 8'h00;
    ppu_a12 = 1'b0;
    readback_force_enable = 1'b1;
    readback_force_data = 8'hFF;
    fail_count = 0;
    check_count = 0;

    for (init_index = 0; init_index < 131072; init_index = init_index + 1)
        prg_rom[init_index] = prg_signature(init_index[16:0]);
    for (init_index = 0; init_index < 65536; init_index = init_index + 1)
        chr_rom[init_index] = chr_signature(init_index[15:0]);
    for (init_index = 0; init_index < 8192; init_index = init_index + 1) begin
        chr_ram[init_index] = chr_signature(init_index[15:0]);
        prg_ram[init_index] = 8'hE0;
    end

    #23;
    @(negedge clk);
    reset = 1'b0;
    #1;

    test_nrom_32k;
    test_uxrom_banks;
    test_uxrom_bus_conflict_and;
    test_uxrom_bus_conflict_reject;
    test_cnrom;
    test_cnrom_bus_conflict;
    test_select_isolation;

    $display("CHECKS %0d", check_count);
    if (fail_count != 0) begin
        $display("FAIL tb_nes_mapper with %0d failing checks", fail_count);
        $finish;
    end
    $display("PASS tb_nes_mapper nrom/uxrom/cnrom/mirroring/bus-conflict");
    $finish;
end

initial begin
    #2000000;
    $display("FAIL tb_nes_mapper global timeout");
    $finish;
end

endmodule
