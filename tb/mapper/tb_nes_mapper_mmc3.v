`timescale 1ns/1ps

module tb_nes_mapper_mmc3;

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
reg ppu_a12_fall;

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
wire [7:0] mmc3_ram_protect;
wire fall_irq;
wire [7:0] fall_irq_counter;
wire [7:0] fall_irq_latch;
wire fall_irq_pending;
wire fall_irq_reload;
wire fall_irq_enabled;
wire fall_a12_filtered;

reg [7:0] prg_rom [0:131071];
reg [7:0] chr_rom [0:65535];
reg [7:0] prg_ram [0:8191];
reg [7:0] cpu_din;
reg [7:0] captured_data;

integer init_index;
integer fail_count;
integer check_count;
integer tick_index;

nes_mapper #(
    .PRG_ADDR_BITS(17),
    .CHR_ADDR_BITS(17),
    .PRG_SIZE_BYTES(131072),
    .HEADER_MIRRORING(3'd0),
    .UxROM_BUS_CONFLICT(2'd0),
    .CNROM_BUS_CONFLICT(2'd0),
    .MMC3_A12_EDGE(2'd0),
    .MMC3_A12_COOLDOWN(2),
    .MMC3_CHR_RAM(1'b0)
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
    .mmc3_chr_inversion(mmc3_chr_inversion),
    .mmc3_ram_protect(mmc3_ram_protect)
);

nes_mapper_mmc3 #(
    .PRG_ADDR_BITS(17),
    .CHR_ADDR_BITS(17),
    .PRG_SIZE_BYTES(131072),
    .MMC3_A12_EDGE(2'd1),
    .MMC3_A12_COOLDOWN(2),
    .HEADER_MIRRORING(3'd0),
    .MMC3_CHR_RAM(1'b0)
) u_mmc3_fall (
    .clk(clk),
    .reset(reset),
    .cpu_addr(cpu_addr),
    .cpu_we(cpu_we && (mapper_select == 8'd4)),
    .cpu_dout(cpu_dout),
    .ppu_addr(ppu_addr),
    .ppu_a12(ppu_a12_fall),
    .prg_bank_offset(),
    .chr_bank_offset(),
    .mirroring(),
    .prg_ram_enable(),
    .chr_ram_enable(),
    .irq(fall_irq),
    .irq_counter(fall_irq_counter),
    .irq_latch(fall_irq_latch),
    .irq_pending(fall_irq_pending),
    .irq_reload(fall_irq_reload),
    .irq_enabled(fall_irq_enabled),
    .a12_filtered(fall_a12_filtered),
    .bank_select(),
    .prg_bank6(),
    .prg_bank7(),
    .prg_mode(),
    .chr_inversion(),
    .ram_protect()
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
        cpu_din = prg_rom[prg_bank_offset[16:0]];
end

always @(posedge clk) begin
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

task expect6;
    input [8*72-1:0] label;
    input [5:0] actual;
    input [5:0] expected;
    begin
        check_count = check_count + 1;
        if (actual !== expected) begin
            fail_count = fail_count + 1;
            $display("FAIL %0s: got %02h expected %02h", label, actual, expected);
        end
    end
endtask

task expect8b;
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

task select_bank;
    input [2:0] register_index;
    input [7:0] value;
    begin
        cpu_write(16'h8000, {5'b00000, register_index});
        cpu_write(16'h8001, value);
    end
endtask

task idle_clk;
    input [7:0] cycles;
    begin
        for (tick_index = 0; tick_index < cycles; tick_index = tick_index + 1) begin
            @(posedge clk);
            #1;
        end
    end
endtask

task a12_rise_accepted;
    begin
        ppu_a12 = 1'b0;
        idle_clk(2);
        ppu_a12 = 1'b1;
        idle_clk(2);
    end
endtask

task a12_fall_accepted;
    begin
        ppu_a12_fall = 1'b1;
        idle_clk(2);
        ppu_a12_fall = 1'b0;
        idle_clk(2);
    end
endtask

task test_reset_state;
    begin
        mapper_select = 8'd4;
        apply_reset;
        expect3("mmc3 mapper id", dbg_mapper_id, 3'd4);
        expect6("mmc3 prg bank6 reset", mmc3_prg_bank6, 6'd0);
        expect6("mmc3 prg bank7 reset", mmc3_prg_bank7, 6'd1);
        expect1("mmc3 prg mode reset", mmc3_prg_mode, 1'b0);
        expect1("mmc3 chr inversion reset", mmc3_chr_inversion, 1'b0);
        expect1("mmc3 bank select reset", mmc3_bank_select, 3'd0);
        expect1("mmc3 prg ram disabled", prg_ram_enable, 1'b0);
        expect3("mmc3 header mirroring", mirroring, 3'd0);
        expect1("mmc3 irq disabled after reset", mmc3_irq_enabled, 1'b0);
        expect1("mmc3 irq line low after reset", irq, 1'b0);
        expect8b("mmc3 irq counter reset", mmc3_irq_counter, 8'h00);
        expect8b("mmc3 irq latch reset", mmc3_irq_latch, 8'h00);
        expect1("mmc3 irq reload reset", mmc3_irq_reload, 1'b0);
        expect1("mmc3 irq pending reset", mmc3_irq_pending, 1'b0);
        cpu_read(16'h8000, captured_data);
        expect8("mmc3 reset 8000 uses bank6", captured_data, prg_signature(17'h00000));
        expect17("mmc3 reset 8000 offset", prg_bank_offset, 17'h00000);
        cpu_read(16'hA000, captured_data);
        expect8("mmc3 reset A000 uses bank7", captured_data, prg_signature(17'h02000));
        expect17("mmc3 reset A000 offset", prg_bank_offset, 17'h02000);
        cpu_read(16'hC000, captured_data);
        expect8("mmc3 reset C000 second last", captured_data, prg_signature(17'h1C000));
        expect17("mmc3 reset C000 offset", prg_bank_offset, 17'h1C000);
        cpu_read(16'hE000, captured_data);
        expect8("mmc3 reset E000 last", captured_data, prg_signature(17'h1E000));
        expect17("mmc3 reset E000 offset", prg_bank_offset, 17'h1E000);
        $display("MMC3 reset bank map bank6=0 bank7=1 last two banks fixed PASS");
    end
endtask

task test_prg_bank_mode;
    begin
        mapper_select = 8'd4;
        apply_reset;
        select_bank(3'd6, 8'h05);
        select_bank(3'd7, 8'h0A);
        expect6("prg bank6 = 5", mmc3_prg_bank6, 6'd5);
        expect6("prg bank7 = 10", mmc3_prg_bank7, 6'd10);
        cpu_read(16'h8000, captured_data);
        expect8("mode0 8000 bank6", captured_data, prg_signature(17'h0A000));
        expect17("mode0 8000 offset", prg_bank_offset, 17'h0A000);
        cpu_read(16'h9FFF, captured_data);
        expect17("mode0 9FFF offset", prg_bank_offset, 17'h0BFFF);
        cpu_read(16'hA000, captured_data);
        expect8("mode0 A000 bank7", captured_data, prg_signature(17'h14000));
        expect17("mode0 A000 offset", prg_bank_offset, 17'h14000);
        cpu_read(16'hC000, captured_data);
        expect8("mode0 C000 second last", captured_data, prg_signature(17'h1C000));
        expect17("mode0 C000 offset", prg_bank_offset, 17'h1C000);
        cpu_read(16'hE000, captured_data);
        expect8("mode0 E000 last", captured_data, prg_signature(17'h1E000));
        expect17("mode0 E000 offset", prg_bank_offset, 17'h1E000);
        cpu_write(16'h8000, 8'hC6);
        expect1("prg mode set", mmc3_prg_mode, 1'b1);
        cpu_read(16'h8000, captured_data);
        expect8("mode1 8000 second last", captured_data, prg_signature(17'h1C000));
        expect17("mode1 8000 offset", prg_bank_offset, 17'h1C000);
        cpu_read(16'hA000, captured_data);
        expect8("mode1 A000 bank7", captured_data, prg_signature(17'h14000));
        expect17("mode1 A000 offset", prg_bank_offset, 17'h14000);
        cpu_read(16'hC000, captured_data);
        expect8("mode1 C000 bank6", captured_data, prg_signature(17'h0A000));
        expect17("mode1 C000 offset", prg_bank_offset, 17'h0A000);
        cpu_read(16'hE000, captured_data);
        expect8("mode1 E000 last", captured_data, prg_signature(17'h1E000));
        expect17("mode1 E000 offset", prg_bank_offset, 17'h1E000);
        select_bank(3'd6, 8'hFC);
        expect6("prg bank6 masked to 6 bits", mmc3_prg_bank6, 6'h3C);
        select_bank(3'd6, 8'h0C);
        expect6("prg bank6 = 12", mmc3_prg_bank6, 6'h0C);
        cpu_read(16'h8000, captured_data);
        expect8("mode0 8000 bank6 12", captured_data, prg_signature(17'h18000));
        expect17("mode0 8000 bank6 12 offset", prg_bank_offset, 17'h18000);
        $display("MMC3 prg 8K bank mode swap and 6-bit bank mask PASS");
    end
endtask

task test_chr_banks;
    begin
        mapper_select = 8'd4;
        apply_reset;
        select_bank(3'd0, 8'h07);
        select_bank(3'd1, 8'h09);
        select_bank(3'd2, 8'h0A);
        select_bank(3'd3, 8'h0B);
        select_bank(3'd4, 8'h0C);
        select_bank(3'd5, 8'h0D);
        ppu_addr = 14'h0000;
        #1;
        expect16("R0 bit0 ignored window0", chr_bank_offset, 16'h1800);
        ppu_addr = 14'h07FF;
        #1;
        expect16("R0 bit0 ignored window0 top", chr_bank_offset, 16'h1BFF);
        ppu_addr = 14'h0800;
        #1;
        expect16("R0 high half window1", chr_bank_offset, 16'h1C00);
        ppu_addr = 14'h0FFF;
        #1;
        expect16("R0 high half window1 top", chr_bank_offset, 16'h1FFF);
        ppu_addr = 14'h1000;
        #1;
        expect16("R2 window4", chr_bank_offset, 16'h2800);
        ppu_addr = 14'h13FF;
        #1;
        expect16("R2 window4 top", chr_bank_offset, 16'h2BFF);
        ppu_addr = 14'h1400;
        #1;
        expect16("R3 window5", chr_bank_offset, 16'h2C00);
        ppu_addr = 14'h1800;
        #1;
        expect16("R4 window6", chr_bank_offset, 16'h3000);
        ppu_addr = 14'h1C00;
        #1;
        expect16("R5 window7", chr_bank_offset, 16'h3400);
        ppu_addr = 14'h1FFF;
        #1;
        expect16("R5 window7 top", chr_bank_offset, 16'h37FF);
        $display("MMC3 chr 2K/1K window mapping with R0/R1 bit0 ignored PASS");
    end
endtask

task test_chr_bank_addr_bits17;
    reg [16:0] offset_bank0;
    reg [16:0] offset_bank40;
    begin
        mapper_select = 8'd4;
        apply_reset;
        ppu_addr = 14'h0000;
        select_bank(3'd0, 8'h00);
        #1;
        offset_bank0 = chr_bank_offset;
        expect17("R0 bank 0x00 offset 0000", offset_bank0, 17'h00000);
        select_bank(3'd0, 8'h40);
        #1;
        offset_bank40 = chr_bank_offset;
        expect17("R0 bank 0x40 offset 10000", offset_bank40, 17'h10000);
        expect_distinct17("R0 bank 0x00 and 0x40 offsets differ", offset_bank0, offset_bank40);
        ppu_addr = 14'h03FF;
        #1;
        expect17("R0 bank 0x40 top of 2K window", chr_bank_offset, 17'h103FF);
        $display("MMC3 chr bank 0x40 needs 17-bit offset PASS");
    end
endtask


task test_chr_inversion;
    begin
        mapper_select = 8'd4;
        apply_reset;
        select_bank(3'd0, 8'h00);
        select_bank(3'd1, 8'h02);
        select_bank(3'd2, 8'h04);
        select_bank(3'd3, 8'h06);
        select_bank(3'd4, 8'h08);
        select_bank(3'd5, 8'h0A);
        cpu_write(16'h8000, 8'h80);
        expect1("chr inversion set", mmc3_chr_inversion, 1'b1);
        expect3("bank select untouched by inversion", mmc3_bank_select, 3'd0);
        ppu_addr = 14'h0000;
        #1;
        expect16("inverted 0000 uses R2", chr_bank_offset, 16'h1000);
        ppu_addr = 14'h03FF;
        #1;
        expect16("inverted 03FF uses R2 top", chr_bank_offset, 16'h13FF);
        ppu_addr = 14'h0800;
        #1;
        expect16("inverted 0800 uses R3", chr_bank_offset, 16'h1800);
        ppu_addr = 14'h1000;
        #1;
        expect16("inverted 1000 uses R0", chr_bank_offset, 16'h0000);
        ppu_addr = 14'h1400;
        #1;
        expect16("inverted 1400 uses R0 high half", chr_bank_offset, 16'h0400);
        ppu_addr = 14'h1800;
        #1;
        expect16("inverted 1800 uses R1", chr_bank_offset, 16'h0800);
        ppu_addr = 14'h1C00;
        #1;
        expect16("inverted 1C00 uses R1 high half", chr_bank_offset, 16'h0C00);
        cpu_write(16'h8000, 8'h00);
        expect1("chr inversion cleared", mmc3_chr_inversion, 1'b0);
        ppu_addr = 14'h0000;
        #1;
        expect16("normal 0000 uses R0", chr_bank_offset, 16'h0000);
        ppu_addr = 14'h1000;
        #1;
        expect16("normal 1000 uses R2", chr_bank_offset, 16'h1000);
        $display("MMC3 chr inversion swaps 0000-0FFF with 1000-1FFF PASS");
    end
endtask

task test_mirroring_and_ram;
    begin
        mapper_select = 8'd4;
        apply_reset;
        cpu_write(16'hA000, 8'h01);
        expect3("A000 bit0 1 horizontal", mirroring, 3'd0);
        expect32("nametable map horizontal", nametable_map, 32'h00000050);
        cpu_write(16'hA000, 8'h00);
        expect3("A000 bit0 0 vertical", mirroring, 3'd1);
        expect32("nametable map vertical", nametable_map, 32'h00000044);
        cpu_write(16'hA000, 8'h03);
        expect3("A000 ignores upper bits", mirroring, 3'd0);
        expect1("prg ram still disabled", prg_ram_enable, 1'b0);
        cpu_write(16'h8000, 8'h20);
        expect1("prg ram enabled by 8000 bit5", prg_ram_enable, 1'b1);
        expect8b("prg ram protect cleared by enable", mmc3_ram_protect, 8'h00);
        cpu_write(16'hA001, 8'hC0);
        expect8b("A001 sets prg ram protect", mmc3_ram_protect, 8'hC0);
        cpu_write(16'h8000, 8'h40);
        expect1("prg ram disabled by 8000", prg_ram_enable, 1'b0);
        expect8b("prg ram protect cleared on disable", mmc3_ram_protect, 8'h00);
        cpu_write(16'hA001, 8'hC0);
        expect8b("A001 ignored while disabled", mmc3_ram_protect, 8'h00);
        cpu_write(16'h8000, 8'h20);
        cpu_addr = 16'h6000;
        cpu_dout = 8'h3C;
        cpu_we = 1'b1;
        #1 expect1("prg ram we high at 6000", prg_ram_we, 1'b1);
        @(posedge clk);
        #1;
        cpu_we = 1'b0;
        cpu_dout = 8'h00;
        cpu_read(16'h6000, captured_data);
        expect8("prg ram readback", captured_data, 8'h3C);
        $display("MMC3 A000 mirroring, 8000 bit5 ram enable, A001 protect PASS");
    end
endtask

task test_irq_latch_and_reload;
    begin
        mapper_select = 8'd4;
        apply_reset;
        cpu_write(16'hC000, 8'h07);
        expect8b("latch stored", mmc3_irq_latch, 8'h07);
        expect8b("counter not changed by latch write", mmc3_irq_counter, 8'h00);
        cpu_write(16'hC001, 8'h00);
        expect1("reload requested", mmc3_irq_reload, 1'b1);
        expect8b("reload flag does not move counter", mmc3_irq_counter, 8'h00);
        a12_rise_accepted;
        expect8b("first a12 loads the latch", mmc3_irq_counter, 8'h07);
        expect1("reload consumed", mmc3_irq_reload, 1'b0);
        expect1("no irq while disabled", irq, 1'b0);
        a12_rise_accepted;
        expect8b("second a12 decrements", mmc3_irq_counter, 8'h06);
        a12_rise_accepted;
        expect8b("third a12 decrements", mmc3_irq_counter, 8'h05);
        cpu_write(16'hC001, 8'h00);
        a12_rise_accepted;
        expect8b("reload jumps back to the latch", mmc3_irq_counter, 8'h07);
        a12_rise_accepted;
        a12_rise_accepted;
        a12_rise_accepted;
        expect8b("counter at 5", mmc3_irq_counter, 8'h04);
        idle_clk(3);
        expect8b("counter frozen without a12", mmc3_irq_counter, 8'h04);
        expect1("still no irq", irq, 1'b0);
        $display("MMC3 irq latch load, reload and a12 decrement PASS");
    end
endtask

task test_irq_assert_and_ack;
    begin
        mapper_select = 8'd4;
        apply_reset;
        cpu_write(16'hC000, 8'h02);
        cpu_write(16'hC001, 8'h00);
        cpu_write(16'hE001, 8'h00);
        expect1("irq enabled", mmc3_irq_enabled, 1'b1);
        a12_rise_accepted;
        expect8b("latch 2 loaded", mmc3_irq_counter, 8'h02);
        expect1("no irq on the loading edge", irq, 1'b0);
        a12_rise_accepted;
        expect8b("counter reaches 1", mmc3_irq_counter, 8'h01);
        expect1("still no irq at counter 1", irq, 1'b0);
        expect1("pending not set at counter 1", mmc3_irq_pending, 1'b0);
        a12_rise_accepted;
        expect8b("counter reaches 0", mmc3_irq_counter, 8'h00);
        expect1("pending set at counter 0", mmc3_irq_pending, 1'b1);
        expect1("irq line asserted", irq, 1'b1);
        idle_clk(5);
        expect1("irq stays asserted while pending", irq, 1'b1);
        cpu_write(16'hE000, 8'h00);
        expect1("E000 disables irq", mmc3_irq_enabled, 1'b0);
        expect1("E000 acks pending", mmc3_irq_pending, 1'b0);
        expect1("irq line released", irq, 1'b0);
        idle_clk(3);
        expect1("irq stays released", irq, 1'b0);
        a12_rise_accepted;
        expect8b("counter reloads after ack", mmc3_irq_counter, 8'h02);
        expect1("no irq while disabled", irq, 1'b0);
        cpu_write(16'hE001, 8'h00);
        expect1("E001 enables irq", mmc3_irq_enabled, 1'b1);
        expect1("enable does not retrofire", irq, 1'b0);
        cpu_write(16'hE000, 8'h00);
        cpu_write(16'hC000, 8'h01);
        cpu_write(16'hC001, 8'h00);
        cpu_write(16'hE001, 8'h00);
        a12_rise_accepted;
        expect8b("new latch 1 loaded", mmc3_irq_counter, 8'h01);
        expect1("no irq on the new latch edge", irq, 1'b0);
        a12_rise_accepted;
        expect8b("new latch counted down", mmc3_irq_counter, 8'h00);
        expect1("irq reasserts after reload and enable", irq, 1'b1);
        $display("MMC3 irq latch countdown assert, disable/ack, enable PASS");
    end
endtask

task test_irq_zero_latch;
    begin
        mapper_select = 8'd4;
        apply_reset;
        cpu_write(16'hC000, 8'h00);
        cpu_write(16'hE001, 8'h00);
        a12_rise_accepted;
        expect8b("latch 0 counter stays 0", mmc3_irq_counter, 8'h00);
        expect1("latch 0 asserts immediately", irq, 1'b1);
        idle_clk(4);
        expect1("latch 0 irq stays asserted", irq, 1'b1);
        expect1("counter reloaded from latch 0", mmc3_irq_counter, 8'h00);
        cpu_write(16'hE000, 8'h00);
        expect1("ack releases latch 0 irq", irq, 1'b0);
        $display("MMC3 irq latch 0 asserts on every filtered edge PASS");
    end
endtask

task test_a12_cooldown;
    begin
        mapper_select = 8'd4;
        apply_reset;
        cpu_write(16'hC000, 8'h08);
        ppu_a12 = 1'b0;
        idle_clk(2);
        ppu_a12 = 1'b1;
        idle_clk(1);
        expect8b("first rise accepted", mmc3_irq_counter, 8'h08);
        ppu_a12 = 1'b0;
        idle_clk(1);
        ppu_a12 = 1'b1;
        idle_clk(1);
        expect8b("rise inside cooldown ignored", mmc3_irq_counter, 8'h08);
        expect1("a12 filter reported idle", mmc3_a12_filtered, 1'b0);
        idle_clk(2);
        ppu_a12 = 1'b0;
        idle_clk(1);
        ppu_a12 = 1'b1;
        idle_clk(1);
        expect8b("rise after cooldown accepted", mmc3_irq_counter, 8'h07);
        ppu_a12 = 1'b0;
        idle_clk(2);
        $display("MMC3 a12 rising edge filter with cooldown PASS");
    end
endtask

task test_a12_falling_edge;
    begin
        mapper_select = 8'd4;
        apply_reset;
        cpu_write(16'hC000, 8'h05);
        expect1("fall edge instance selected", (u_mmc3_fall.MMC3_A12_EDGE == 2'd1), 1'b1);
        expect1("rise edge instance selected", (dut.u_mmc3.MMC3_A12_EDGE == 2'd0), 1'b1);
        a12_fall_accepted;
        expect8b("falling edge loads latch", fall_irq_counter, 8'h05);
        expect1("fall instance no irq while disabled", fall_irq, 1'b0);
        expect8b("rise instance untouched by falling edges", mmc3_irq_counter, 8'h00);
        expect1("rise instance irq still low", irq, 1'b0);
        cpu_write(16'hC000, 8'h01);
        cpu_write(16'hC001, 8'h00);
        cpu_write(16'hE001, 8'h00);
        a12_fall_accepted;
        expect8b("fall instance loads latch 1", fall_irq_counter, 8'h01);
        expect1("fall instance no irq on the loading edge", fall_irq, 1'b0);
        a12_fall_accepted;
        expect8b("fall instance counter reaches 0", fall_irq_counter, 8'h00);
        expect1("fall edge instance asserts", fall_irq, 1'b1);
        expect1("rise edge instance unaffected", irq, 1'b0);
        expect8b("rise instance counter still 0", mmc3_irq_counter, 8'h00);
        ppu_a12_fall = 1'b0;
        idle_clk(2);
        $display("MMC3 configurable a12 edge polarity PASS");
    end
endtask

task test_unmapped_writes;
    begin
        mapper_select = 8'd4;
        apply_reset;
        select_bank(3'd6, 8'h03);
        cpu_write(16'h7FFF, 8'h07);
        expect6("write below 8000 ignored", mmc3_prg_bank6, 6'd3);
        cpu_write(16'hC002, 8'h01);
        expect8b("C002 is the same register as C000", mmc3_irq_latch, 8'h01);
        cpu_write(16'hE002, 8'h01);
        expect1("E002 is the same register as E000", mmc3_irq_enabled, 1'b0);
        cpu_write(16'hE000, 8'h00);
        cpu_write(16'h8002, 8'h01);
        expect3("8002 aliases 8000", mmc3_bank_select, 3'd1);
        cpu_write(16'h8000, 8'h02);
        expect3("8000 selects R2", mmc3_bank_select, 3'd2);
        cpu_write(16'h8003, 8'h05);
        expect3("8003 does not reselect the register", mmc3_bank_select, 3'd2);
        ppu_addr = 14'h1000;
        #1;
        expect16("8003 aliased R2 write reached chr_bank2", chr_bank_offset, 16'h1400);
        $display("MMC3 even/odd address aliasing and 8000 range gating PASS");
    end
endtask

initial begin
    clk = 1'b0;
    reset = 1'b1;
    mapper_select = 8'd4;
    cpu_addr = 16'h0000;
    cpu_we = 1'b0;
    cpu_dout = 8'h00;
    ppu_addr = 14'h0000;
    ppu_we = 1'b0;
    ppu_dout = 8'h00;
    ppu_a12 = 1'b0;
    fail_count = 0;
    check_count = 0;
    tick_index = 0;

    for (init_index = 0; init_index < 131072; init_index = init_index + 1)
        prg_rom[init_index] = prg_signature(init_index[16:0]);
    for (init_index = 0; init_index < 65536; init_index = init_index + 1)
        chr_rom[init_index] = chr_signature(init_index[15:0]);
    for (init_index = 0; init_index < 8192; init_index = init_index + 1)
        prg_ram[init_index] = 8'hE0;

    #23;
    @(negedge clk);
    reset = 1'b0;
    #1;

    test_reset_state;
    test_prg_bank_mode;
    test_chr_banks;
    test_chr_bank_addr_bits17;
    test_chr_inversion;
    test_mirroring_and_ram;
    test_irq_latch_and_reload;
    test_irq_assert_and_ack;
    test_irq_zero_latch;
    test_a12_cooldown;
    test_a12_falling_edge;
    test_unmapped_writes;

    $display("CHECKS %0d", check_count);
    if (fail_count != 0) begin
        $display("FAIL tb_nes_mapper_mmc3 with %0d failing checks", fail_count);
        $finish;
    end
    $display("PASS tb_nes_mapper_mmc3 banks/mirroring/a12-irq-latch-reload-ack");
    $finish;
end

initial begin
    #2000000;
    $display("FAIL tb_nes_mapper_mmc3 global timeout");
    $finish;
end

endmodule
