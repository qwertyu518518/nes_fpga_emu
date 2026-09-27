`timescale 1ns/1ps

module tb_nes_mapper_nrom128;

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

reg [7:0] prg_rom [0:16383];
reg [7:0] chr_ram [0:8191];
reg [7:0] prg_ram [0:8191];
reg [7:0] cpu_din;
reg [7:0] captured_data;

integer init_index;
integer fail_count;
integer check_count;

nes_mapper #(
    .PRG_ADDR_BITS(17),
    .CHR_ADDR_BITS(17),
    .PRG_SIZE_BYTES(16384),
    .HEADER_MIRRORING(3'd1),
    .NROM_PRG_SIZE_BYTES(16384),
    .NROM_PRG_RAM(1'b1),
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
    .mmc1_serial_count(),
    .mmc1_serial_value(),
    .mmc1_control(),
    .mmc1_chr_bank0(),
    .mmc1_chr_bank1(),
    .mmc1_prg_bank(),
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

always @* begin
    if (cpu_addr[15:13] == 3'b011)
        cpu_din = prg_ram[cpu_addr[12:0]];
    else
        cpu_din = prg_rom[prg_bank_offset[13:0]];
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
        reset = 1'b1;
        repeat (3) @(posedge clk);
        #1 reset = 1'b0;
        @(posedge clk);
        #1;
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

task test_16k_mirror;
    begin
        mapper_select = 8'd0;
        apply_reset;
        expect3("nrom128 mirroring vertical", mirroring, 3'd1);
        expect32("nrom128 nametable map vertical", nametable_map, 32'h00000044);
        expect1("nrom128 wram present", prg_ram_enable, 1'b1);
        expect1("nrom128 chram present", chr_ram_enable, 1'b1);
        cpu_read(16'h8000, captured_data);
        expect8("nrom128 8000", captured_data, prg_signature(17'h00000));
        expect17("nrom128 8000 offset", prg_bank_offset, 17'h00000);
        cpu_read(16'hBFFF, captured_data);
        expect8("nrom128 BFFF", captured_data, prg_signature(17'h03FFF));
        expect17("nrom128 BFFF offset", prg_bank_offset, 17'h03FFF);
        cpu_read(16'hC000, captured_data);
        expect8("nrom128 C000 mirrors 8000", captured_data, prg_signature(17'h00000));
        expect17("nrom128 C000 offset", prg_bank_offset, 17'h00000);
        cpu_read(16'hDFFF, captured_data);
        expect8("nrom128 DFFF mirrors C000", captured_data, prg_signature(17'h01000));
        cpu_read(16'hE000, captured_data);
        expect8("nrom128 E000 mirrors 8000", captured_data, prg_signature(17'h02000));
        cpu_read(16'hFFFF, captured_data);
        expect8("nrom128 FFFF mirrors BFFF", captured_data, prg_signature(17'h03FFF));
        $display("NROM 16K prg mirror across 8000-C000 PASS");
    end
endtask

task test_wram;
    begin
        mapper_select = 8'd0;
        cpu_addr = 16'h6000;
        cpu_dout = 8'hA5;
        cpu_we = 1'b1;
        #1 expect1("nrom128 prg ram we high at 6000", prg_ram_we, 1'b1);
        @(posedge clk);
        #1;
        cpu_we = 1'b0;
        cpu_dout = 8'h00;
        cpu_read(16'h6000, captured_data);
        expect8("nrom128 wram readback", captured_data, 8'hA5);
        cpu_addr = 16'h7FFF;
        cpu_dout = 8'h5C;
        cpu_we = 1'b1;
        #1 expect1("nrom128 prg ram we high at 7FFF", prg_ram_we, 1'b1);
        @(posedge clk);
        #1;
        cpu_we = 1'b0;
        cpu_dout = 8'h00;
        cpu_read(16'h6000, captured_data);
        expect8("nrom128 wram 6000 unaffected", captured_data, 8'hA5);
        cpu_read(16'h7FFF, captured_data);
        expect8("nrom128 wram 7FFF", captured_data, 8'h5C);
        cpu_addr = 16'h8000;
        cpu_dout = 8'h11;
        cpu_we = 1'b1;
        #1 expect1("nrom128 prg ram we low at 8000", prg_ram_we, 1'b0);
        @(posedge clk);
        #1;
        cpu_we = 1'b0;
        cpu_dout = 8'h00;
        expect8("nrom128 wram untouched by 8000 write", prg_ram[13'h0000], 8'hA5);
        $display("NROM 16K wram window at 6000-7FFF PASS");
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
    fail_count = 0;
    check_count = 0;

    for (init_index = 0; init_index < 16384; init_index = init_index + 1)
        prg_rom[init_index] = prg_signature(init_index[16:0]);
    for (init_index = 0; init_index < 8192; init_index = init_index + 1) begin
        chr_ram[init_index] = chr_signature(init_index[15:0]);
        prg_ram[init_index] = 8'hE0;
    end

    #23;
    @(negedge clk);
    reset = 1'b0;
    #1;

    test_16k_mirror;
    test_wram;

    $display("CHECKS %0d", check_count);
    if (fail_count != 0) begin
        $display("FAIL tb_nes_mapper_nrom128 with %0d failing checks", fail_count);
        $finish;
    end
    $display("PASS tb_nes_mapper_nrom128 16k-mirror/vertical-mirroring");
    $finish;
end

initial begin
    #2000000;
    $display("FAIL tb_nes_mapper_nrom128 global timeout");
    $finish;
end

endmodule
