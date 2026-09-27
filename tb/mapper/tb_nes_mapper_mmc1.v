`timescale 1ns/1ps

module tb_nes_mapper_mmc1;

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

reg [7:0] prg_rom [0:131071];
reg [7:0] chr_rom [0:65535];
reg [7:0] chr_ram [0:8191];
reg [7:0] prg_ram [0:8191];
reg [7:0] cpu_din;
reg [7:0] captured_data;

integer init_index;
integer fail_count;
integer check_count;
integer serial_index;

nes_mapper #(
    .PRG_ADDR_BITS(17),
    .CHR_ADDR_BITS(17),
    .PRG_SIZE_BYTES(131072),
    .HEADER_MIRRORING(3'd0),
    .UxROM_BUS_CONFLICT(2'd0),
    .CNROM_BUS_CONFLICT(2'd0),
    .MMC1_CHR_RAM(1'b0)
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
    .prg_readback(8'hFF),
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
    .mmc3_irq_counter(),
    .mmc3_irq_latch(),
    .mmc3_irq_pending(),
    .mmc3_irq_reload(),
    .mmc3_irq_enabled(),
    .mmc3_a12_filtered(),
    .mmc3_bank_select(),
    .mmc3_prg_bank6(),
    .mmc3_prg_bank7(),
    .mmc3_prg_mode(),
    .mmc3_chr_inversion()
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

task expect3c;
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

task expect_distinct17;
    input [8*72-1:0] label;
    input [16:0] first;
    input [16:0] second;
    begin
        check_count = check_count + 1;
        if (first === second) begin
            fail_count = fail_count + 1;
            $display("FAIL %0s: both chr_bank_offset are %05h", label, first);
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

task mmc1_serial_write;
    input [15:0] address;
    input [4:0] value;
    begin
        for (serial_index = 0; serial_index < 5; serial_index = serial_index + 1)
            cpu_write(address, {7'b0000000, value[serial_index]});
    end
endtask

task test_reset_state;
    begin
        mapper_select = 8'd1;
        apply_reset;
        expect3("mmc1 mapper id", dbg_mapper_id, 3'd1);
        expect3c("mmc1 serial count reset", mmc1_serial_count, 3'd0);
        expect5("mmc1 serial value reset", mmc1_serial_value, 5'h00);
        expect5("mmc1 control reset 0x0C", mmc1_control, 5'b01100);
        expect3("mmc1 prg mode 3 single lower", mirroring, 3'd2);
        expect32("mmc1 nametable map single lower", nametable_map, 32'h00000000);
        expect1("mmc1 prg ram enabled", prg_ram_enable, 1'b1);
        expect1("mmc1 irq low", irq, 1'b0);
        expect1("mmc1 bus conflict unused", bus_conflict, 1'b0);
        cpu_read(16'h8000, captured_data);
        expect8("mmc1 reset 8000 bank0", captured_data, prg_signature(17'h00000));
        cpu_read(16'hC000, captured_data);
        expect8("mmc1 reset C000 last bank", captured_data, prg_signature(17'h1C000));
        $display("MMC1 reset state control=0x0C prg mode 3 single lower PASS");
    end
endtask

task test_serial_needs_five_writes;
    begin
        mapper_select = 8'd1;
        apply_reset;
        cpu_write(16'hE000, 8'h00);
        expect3c("serial count after 1 write", mmc1_serial_count, 3'd1);
        expect5("serial value after 1 write", mmc1_serial_value, 5'h00);
        expect5("prg bank not committed", mmc1_prg_bank, 5'h00);
        cpu_read(16'h8000, captured_data);
        expect8("prg unchanged after 1 write", captured_data, prg_signature(17'h00000));
        cpu_write(16'hE000, 8'h00);
        expect3c("serial count after 2 writes", mmc1_serial_count, 3'd2);
        cpu_write(16'hE000, 8'h00);
        expect3c("serial count after 3 writes", mmc1_serial_count, 3'd3);
        cpu_write(16'hE000, 8'h00);
        expect3c("serial count after 4 writes", mmc1_serial_count, 3'd4);
        expect5("prg bank still not committed", mmc1_prg_bank, 5'h00);
        cpu_read(16'h8000, captured_data);
        expect8("prg unchanged after 4 writes", captured_data, prg_signature(17'h00000));
        cpu_write(16'hE000, 8'h01);
        expect3c("serial count cleared after 5th", mmc1_serial_count, 3'd0);
        expect5("serial value cleared after 5th", mmc1_serial_value, 5'h00);
        expect5("prg bank committed on 5th", mmc1_prg_bank, 5'h10);
        $display("MMC1 serial register commits only on the fifth write PASS");
    end
endtask

task test_serial_bit_order;
    begin
        mapper_select = 8'd1;
        apply_reset;
        cpu_write(16'hE000, 8'h00);
        cpu_write(16'hE000, 8'h01);
        cpu_write(16'hE000, 8'h00);
        cpu_write(16'hE000, 8'h01);
        expect5("serial bits 0..3 accumulated", mmc1_serial_value, 5'h0A);
        cpu_write(16'hE000, 8'h01);
        expect5("prg bank bit4 set by fifth bit", mmc1_prg_bank, 5'h1A);
        apply_reset;
        mmc1_serial_write(16'hE000, 5'b00101);
        expect5("serial 00101 to prg bank", mmc1_prg_bank, 5'h05);
        mmc1_serial_write(16'hE000, 5'b11110);
        expect5("serial 11110 to prg bank", mmc1_prg_bank, 5'h1E);
        expect1("prg ram disabled by bank bit4", prg_ram_enable, 1'b0);
        mmc1_serial_write(16'hE000, 5'b00100);
        expect1("prg ram re-enabled", prg_ram_enable, 1'b1);
        $display("MMC1 serial bit order lsb first and prg ram bit4 PASS");
    end
endtask

task test_register_decode;
    begin
        mapper_select = 8'd1;
        apply_reset;
        mmc1_serial_write(16'h8000, 5'b00101);
        expect5("8000 writes control", mmc1_control, 5'b00101);
        expect5("8000 does not touch chr0", mmc1_chr_bank0, 5'h00);
        mmc1_serial_write(16'hA000, 5'b00111);
        expect5("A000 writes chr bank0", mmc1_chr_bank0, 5'h07);
        expect5("A000 leaves control", mmc1_control, 5'b00101);
        mmc1_serial_write(16'hC000, 5'b11010);
        expect5("C000 writes chr bank1", mmc1_chr_bank1, 5'h1A);
        mmc1_serial_write(16'hE000, 5'b00011);
        expect5("E000 writes prg bank", mmc1_prg_bank, 5'h03);
        $display("MMC1 8000/A000/C000/E000 serial register decode PASS");
    end
endtask

task test_prg_modes;
    begin
        mapper_select = 8'd1;
        apply_reset;
        mmc1_serial_write(16'hE000, 5'b00100);
        mmc1_serial_write(16'h8000, 5'b01100);
        expect5("control prg mode 3", mmc1_control[3:2], 2'b11);
        cpu_read(16'h8000, captured_data);
        expect8("mode3 8000 selectable bank4", captured_data, prg_signature(17'h10000));
        cpu_read(16'hC000, captured_data);
        expect8("mode3 C000 fixed last", captured_data, prg_signature(17'h1C000));
        mmc1_serial_write(16'h8000, 5'b01000);
        expect5("control prg mode 2", mmc1_control[3:2], 2'b10);
        cpu_read(16'h8000, captured_data);
        expect8("mode2 8000 fixed bank0", captured_data, prg_signature(17'h00000));
        cpu_read(16'hC000, captured_data);
        expect8("mode2 C000 selectable bank4", captured_data, prg_signature(17'h10000));
        mmc1_serial_write(16'h8000, 5'b00100);
        expect5("control prg mode 1", mmc1_control[3:2], 2'b01);
        cpu_read(16'h8000, captured_data);
        expect8("mode1 8000 bank from reg>>1", captured_data, prg_signature(17'h10000));
        cpu_read(16'hC000, captured_data);
        expect8("mode1 C000 bank from reg>>1 plus one", captured_data, prg_signature(17'h14000));
        mmc1_serial_write(16'h8000, 5'b00000);
        expect5("control prg mode 0", mmc1_control[3:2], 2'b00);
        cpu_read(16'h8000, captured_data);
        expect8("mode0 8000 same as mode1", captured_data, prg_signature(17'h10000));
        cpu_read(16'hC000, captured_data);
        expect8("mode0 C000 same as mode1", captured_data, prg_signature(17'h14000));
        mmc1_serial_write(16'hE000, 5'b00101);
        expect5("prg bank 5", mmc1_prg_bank, 5'h05);
        mmc1_serial_write(16'h8000, 5'b00100);
        cpu_read(16'h8000, captured_data);
        expect8("mode1 ignores prg bank bit0", captured_data, prg_signature(17'h10000));
        cpu_read(16'hC000, captured_data);
        expect8("mode1 C000 with prg bank 5", captured_data, prg_signature(17'h14000));
        mmc1_serial_write(16'h8000, 5'b01000);
        cpu_read(16'h8000, captured_data);
        expect8("mode2 8000 still bank0 after bank write", captured_data, prg_signature(17'h00000));
        cpu_read(16'hC000, captured_data);
        expect8("mode2 C000 follows prg bank 5", captured_data, prg_signature(17'h14000));
        $display("MMC1 prg bank modes 0/1/2/3 window mapping PASS");
    end
endtask

task test_chr_modes;
    begin
        mapper_select = 8'd1;
        apply_reset;
        mmc1_serial_write(16'hA000, 5'b00101);
        mmc1_serial_write(16'hC000, 5'b00010);
        expect5("chr mode 0 by default", mmc1_control[4], 1'b0);
        ppu_addr = 14'h0000;
        #1;
        expect16("chr mode0 0000 low half of bank5", chr_bank_offset, 16'h4000);
        expect8("chr mode0 0000 data", chr_data(13'h0000), chr_signature(16'h4000));
        ppu_addr = 14'h0FFF;
        #1;
        expect16("chr mode0 0FFF top of low half", chr_bank_offset, 16'h4FFF);
        expect8("chr mode0 0FFF data", chr_data(13'h0FFF), chr_signature(16'h4FFF));
        ppu_addr = 14'h1000;
        #1;
        expect16("chr mode0 1000 high half of bank5", chr_bank_offset, 16'h5000);
        expect8("chr mode0 1000 data", chr_data(13'h0000), chr_signature(16'h5000));
        ppu_addr = 14'h1FFF;
        #1;
        expect16("chr mode0 1FFF top of high half", chr_bank_offset, 16'h5FFF);
        expect8("chr mode0 1FFF data", chr_data(13'h1FFF), chr_signature(16'h5FFF));
        mmc1_serial_write(16'h8000, 5'b11100);
        expect5("control chr mode 1 prg mode 3", mmc1_control, 5'b11100);
        ppu_addr = 14'h0000;
        #1;
        expect16("chr mode1 0000 chr bank0", chr_bank_offset, 16'h5000);
        expect8("chr mode1 0000 data", chr_data(13'h0000), chr_signature(16'h5000));
        ppu_addr = 14'h0FFF;
        #1;
        expect16("chr mode1 0FFF still bank0", chr_bank_offset, 16'h5FFF);
        ppu_addr = 14'h1000;
        #1;
        expect16("chr mode1 1000 chr bank1", chr_bank_offset, 16'h2000);
        expect8("chr mode1 1000 data", chr_data(13'h0000), chr_signature(16'h2000));
        ppu_addr = 14'h1FFF;
        #1;
        expect16("chr mode1 1FFF top of bank1", chr_bank_offset, 16'h2FFF);
        expect8("chr mode1 1FFF data", chr_data(13'h1FFF), chr_signature(16'h2FFF));
        mmc1_serial_write(16'hA000, 5'b01111);
        ppu_addr = 14'h0000;
        #1;
        expect16("chr bank0 15 used as is", chr_bank_offset, 16'hF000);
        ppu_addr = 14'h1000;
        #1;
        expect16("chr bank1 unaffected by chr bank0 write", chr_bank_offset, 16'h2000);
        $display("MMC1 chr bank modes 0/1 window mapping PASS");
    end
endtask

task test_chr_bank_addr_bits17;
    reg [16:0] offset_bank0;
    reg [16:0] offset_bank16;
    begin
        mapper_select = 8'd1;
        apply_reset;
        ppu_addr = 14'h0000;
        mmc1_serial_write(16'hA000, 5'b00000);
        #1;
        expect5("chr bank0 program 0", mmc1_chr_bank0, 5'h00);
        offset_bank0 = chr_bank_offset;
        expect17("chr mode0 bank0 offset 0000", offset_bank0, 17'h00000);
        mmc1_serial_write(16'hA000, 5'b10000);
        #1;
        expect5("chr bank0 program 0x10", mmc1_chr_bank0, 5'h10);
        offset_bank16 = chr_bank_offset;
        expect17("chr mode0 bank0x10 offset 10000", offset_bank16, 17'h10000);
        expect_distinct17("chr bank 0 and 0x10 offsets differ", offset_bank0, offset_bank16);
        ppu_addr = 14'h0FFF;
        #1;
        expect17("chr bank0x10 top of 4K window", chr_bank_offset, 17'h10FFF);
        $display("MMC1 chr bank 0x10 needs 17-bit offset PASS");
    end
endtask

task test_mirroring_control;
    begin
        mapper_select = 8'd1;
        apply_reset;
        mmc1_serial_write(16'h8000, 5'b00000);
        expect3("control mirror single lower", mirroring, 3'd2);
        expect32("nametable map single lower", nametable_map, 32'h00000000);
        mmc1_serial_write(16'h8000, 5'b01101);
        expect3("control mirror single upper", mirroring, 3'd3);
        expect32("nametable map single upper", nametable_map, 32'h00000055);
        mmc1_serial_write(16'h8000, 5'b01110);
        expect3("control mirror vertical", mirroring, 3'd1);
        expect32("nametable map vertical", nametable_map, 32'h00000044);
        mmc1_serial_write(16'h8000, 5'b01111);
        expect3("control mirror horizontal", mirroring, 3'd0);
        expect32("nametable map horizontal", nametable_map, 32'h00000050);
        $display("MMC1 mirroring control bits 0-1 PASS");
    end
endtask

task test_reset_bit;
    begin
        mapper_select = 8'd1;
        apply_reset;
        mmc1_serial_write(16'hA000, 5'b00101);
        mmc1_serial_write(16'hC000, 5'b00010);
        mmc1_serial_write(16'hE000, 5'b10100);
        mmc1_serial_write(16'h8000, 5'b00111);
        expect5("pre reset chr bank0", mmc1_chr_bank0, 5'h05);
        expect5("pre reset chr bank1", mmc1_chr_bank1, 5'h02);
        expect5("pre reset prg bank", mmc1_prg_bank, 5'h14);
        expect1("pre reset prg ram disabled", prg_ram_enable, 1'b0);
        expect3("pre reset mirroring", mirroring, 3'd0);
        cpu_write(16'hE000, 8'h80);
        expect5("reset bit clears chr bank0", mmc1_chr_bank0, 5'h00);
        expect5("reset bit clears chr bank1", mmc1_chr_bank1, 5'h00);
        expect5("reset bit clears prg bank", mmc1_prg_bank, 5'h00);
        expect5("reset bit restores control 0x0C", mmc1_control, 5'b01100);
        expect3c("reset bit clears serial count", mmc1_serial_count, 3'd0);
        expect3("reset bit restores single lower", mirroring, 3'd2);
        expect1("reset bit re-enables prg ram", prg_ram_enable, 1'b1);
        cpu_read(16'h8000, captured_data);
        expect8("reset bit bank0", captured_data, prg_signature(17'h00000));
        cpu_read(16'hC000, captured_data);
        expect8("reset bit last bank", captured_data, prg_signature(17'h1C000));
        cpu_write(16'h8000, 8'hC0);
        expect5("reset bit works at any serial address", mmc1_control, 5'b01100);
        $display("MMC1 reset bit clears serial register and control PASS");
    end
endtask

task test_partial_write_reset;
    begin
        mapper_select = 8'd1;
        apply_reset;
        cpu_write(16'hE000, 8'h00);
        cpu_write(16'hE000, 8'h01);
        expect3c("partial serial count", mmc1_serial_count, 3'd2);
        cpu_write(16'hE000, 8'h80);
        expect3c("reset bit clears partial serial", mmc1_serial_count, 3'd0);
        expect5("reset bit keeps prg bank zero", mmc1_prg_bank, 5'h00);
        cpu_write(16'h7FFF, 8'h01);
        expect3c("write below 8000 not shifted", mmc1_serial_count, 3'd0);
        $display("MMC1 reset bit aborts a partial serial sequence PASS");
    end
endtask

initial begin
    clk = 1'b0;
    reset = 1'b1;
    mapper_select = 8'd1;
    cpu_addr = 16'h0000;
    cpu_we = 1'b0;
    cpu_dout = 8'h00;
    ppu_addr = 14'h0000;
    ppu_we = 1'b0;
    ppu_dout = 8'h00;
    ppu_a12 = 1'b0;
    fail_count = 0;
    check_count = 0;
    serial_index = 0;

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

    test_reset_state;
    test_serial_needs_five_writes;
    test_serial_bit_order;
    test_register_decode;
    test_prg_modes;
    test_chr_modes;
    test_chr_bank_addr_bits17;
    test_mirroring_control;
    test_reset_bit;
    test_partial_write_reset;

    $display("CHECKS %0d", check_count);
    if (fail_count != 0) begin
        $display("FAIL tb_nes_mapper_mmc1 with %0d failing checks", fail_count);
        $finish;
    end
    $display("PASS tb_nes_mapper_mmc1 serial/prg-mode/chr-mode/mirroring/reset");
    $finish;
end

initial begin
    #2000000;
    $display("FAIL tb_nes_mapper_mmc1 global timeout");
    $finish;
end

endmodule