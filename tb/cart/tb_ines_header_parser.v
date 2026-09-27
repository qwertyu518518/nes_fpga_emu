`timescale 1ns/1ps

module tb_ines_header_parser;

reg clk;
reg reset;
reg start;
reg [127:0] header;
reg [31:0] actual_size;

wire busy;
wire done;
wire valid;
wire [3:0] error;
wire nes2;
wire dirty_ines;
wire [11:0] mapper_id;
wire [3:0] submapper_id;
wire [25:0] prg_size_bytes;
wire [25:0] chr_size_bytes;
wire [1:0] mirroring;
wire four_screen;
wire trainer;
wire battery;
wire [3:0] prg_ram_shift;
wire [3:0] chr_ram_shift;
wire [1:0] cpu_ppu_timing;
wire prg_rom_exponent;
wire chr_rom_exponent;
wire prg_ram_exponent;
wire chr_ram_exponent;
wire [27:0] expected_size;
wire size_trailing;
wire [3:0] dbg_byte_index;
wire [127:0] dbg_header;

wire done_alt;
wire valid_alt;
wire [11:0] mapper_id_alt;
wire [3:0] prg_ram_shift_alt;
wire [3:0] chr_ram_shift_alt;

reg [3:0] idx_log [0:31];
reg [3:0] exp_idx;
integer idx_log_count;
integer busy_cycles;
integer done_count;
integer done_mismatch;
integer log_overflow;
integer fail_count;
integer check_count;

ines_header_parser dut (
    .clk(clk),
    .reset(reset),
    .start(start),
    .header(header),
    .actual_size(actual_size),
    .busy(busy),
    .done(done),
    .valid(valid),
    .error(error),
    .nes2(nes2),
    .dirty_ines(dirty_ines),
    .mapper_id(mapper_id),
    .submapper_id(submapper_id),
    .prg_size_bytes(prg_size_bytes),
    .chr_size_bytes(chr_size_bytes),
    .mirroring(mirroring),
    .four_screen(four_screen),
    .trainer(trainer),
    .battery(battery),
    .prg_ram_shift(prg_ram_shift),
    .chr_ram_shift(chr_ram_shift),
    .cpu_ppu_timing(cpu_ppu_timing),
    .prg_rom_exponent(prg_rom_exponent),
    .chr_rom_exponent(chr_rom_exponent),
    .prg_ram_exponent(prg_ram_exponent),
    .chr_ram_exponent(chr_ram_exponent),
    .expected_size(expected_size),
    .size_trailing(size_trailing),
    .dbg_byte_index(dbg_byte_index),
    .dbg_header(dbg_header)
);

ines_header_parser #(
    .INES_DEFAULT_RAM_SHIFT(4'd0)
) dut_alt (
    .clk(clk),
    .reset(reset),
    .start(start),
    .header(header),
    .actual_size(actual_size),
    .busy(),
    .done(done_alt),
    .valid(valid_alt),
    .error(),
    .nes2(),
    .dirty_ines(),
    .mapper_id(mapper_id_alt),
    .submapper_id(),
    .prg_size_bytes(),
    .chr_size_bytes(),
    .mirroring(),
    .four_screen(),
    .trainer(),
    .battery(),
    .prg_ram_shift(prg_ram_shift_alt),
    .chr_ram_shift(chr_ram_shift_alt),
    .cpu_ppu_timing(),
    .prg_rom_exponent(),
    .chr_rom_exponent(),
    .prg_ram_exponent(),
    .chr_ram_exponent(),
    .expected_size(),
    .size_trailing(),
    .dbg_byte_index(),
    .dbg_header()
);

always #5 clk = ~clk;

always @(posedge clk) begin
    if (busy) begin
        busy_cycles = busy_cycles + 1;
        if (!done) begin
            if (idx_log_count < 32) begin
                idx_log[idx_log_count] = dbg_byte_index;
                idx_log_count = idx_log_count + 1;
            end else begin
                log_overflow = log_overflow + 1;
            end
        end
    end
    if (done)
        done_count = done_count + 1;
    if (done != done_alt)
        done_mismatch = done_mismatch + 1;
end

task expect_bool;
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

task expect4;
    input [8*72-1:0] label;
    input [3:0] actual;
    input [3:0] expected;
    begin
        check_count = check_count + 1;
        if (actual !== expected) begin
            fail_count = fail_count + 1;
            $display("FAIL %0s: got %0d expected %0d", label, actual, expected);
        end
    end
endtask

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

task expect12;
    input [8*72-1:0] label;
    input [11:0] actual;
    input [11:0] expected;
    begin
        check_count = check_count + 1;
        if (actual !== expected) begin
            fail_count = fail_count + 1;
            $display("FAIL %0s: got %03h expected %03h", label, actual, expected);
        end
    end
endtask

task expect26;
    input [8*72-1:0] label;
    input [25:0] actual;
    input [25:0] expected;
    begin
        check_count = check_count + 1;
        if (actual !== expected) begin
            fail_count = fail_count + 1;
            $display("FAIL %0s: got %0d expected %0d", label, actual, expected);
        end
    end
endtask

task expect28;
    input [8*72-1:0] label;
    input [27:0] actual;
    input [27:0] expected;
    begin
        check_count = check_count + 1;
        if (actual !== expected) begin
            fail_count = fail_count + 1;
            $display("FAIL %0s: got %0d expected %0d", label, actual, expected);
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
            $display("FAIL %0s: got %0d expected %0d", label, actual, expected);
        end
    end
endtask

task expect128;
    input [8*72-1:0] label;
    input [127:0] actual;
    input [127:0] expected;
    begin
        check_count = check_count + 1;
        if (actual !== expected) begin
            fail_count = fail_count + 1;
            $display("FAIL %0s: got %032h expected %032h", label, actual, expected);
        end
    end
endtask

task load_ines;
    input [7:0] b0;
    input [7:0] b1;
    input [7:0] b2;
    input [7:0] b3;
    input [7:0] b4;
    input [7:0] b5;
    input [7:0] b6;
    input [7:0] b7;
    input [63:0] tail;
    begin
        header = {tail, b7, b6, b5, b4, b3, b2, b1, b0};
    end
endtask

task run_parse;
    input [31:0] size;
    begin
        actual_size   = size;
        idx_log_count = 0;
        busy_cycles   = 0;
        done_count    = 0;
        start = 1'b1;
        @(posedge clk);
        #1 start = 1'b0;
        wait (done_count == 1);
        #1;
    end
endtask

task test_byte_index_fsm;
    integer i;
    begin
        load_ines(8'h4E, 8'h45, 8'h53, 8'h1A, 8'h02, 8'h01, 8'hB9, 8'h00, 64'd0);
        actual_size   = 32'd40976;
        idx_log_count = 0;
        busy_cycles   = 0;
        done_count    = 0;
        start = 1'b1;
        @(posedge clk);
        #1;
        expect_bool("fsm busy asserted after start", busy, 1'b1);
        expect_bool("fsm done low during fetch", done, 1'b0);
        expect4("fsm index zero on first fetch", dbg_byte_index, 4'd0);
        start = 1'b0;
        wait (done_count == 1);
        #1;
        expect32("fsm busy cycles", busy_cycles, 32'd17);
        expect32("fsm single done pulse", done_count, 32'd1);
        expect32("fsm fetch index samples", idx_log_count, 32'd16);
        for (i = 0; i < 16; i = i + 1) begin
            exp_idx = i;
            expect4("fsm byte index order", idx_log[i], exp_idx);
        end
        expect_bool("fsm busy low after done", busy, 1'b0);
        expect_bool("fsm done low after done", done, 1'b0);
        expect4("fsm index cleared after decode", dbg_byte_index, 4'd0);
        expect128("fsm captured header word", dbg_header,
                  {8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00,
                   8'h00, 8'hB9, 8'h01, 8'h02, 8'h1A, 8'h53, 8'h45, 8'h4E});
        $display("byte index fsm walks 16 header bytes and decodes in 17 cycles PASS");
    end
endtask

task test_clean_ines_nrom128;
    begin
        load_ines(8'h4E, 8'h45, 8'h53, 8'h1A, 8'h01, 8'h00, 8'h40, 8'h00, 64'd0);
        run_parse(32'd16400);
        expect_bool("nrom128 valid", valid, 1'b1);
        expect4("nrom128 error none", error, 4'd0);
        expect_bool("nrom128 not nes2", nes2, 1'b0);
        expect_bool("nrom128 not dirty", dirty_ines, 1'b0);
        expect12("nrom128 mapper from flags6 and flags7", mapper_id, 12'd4);
        expect4("nrom128 submapper zero", submapper_id, 4'd0);
        expect26("nrom128 prg size", prg_size_bytes, 26'd16384);
        expect26("nrom128 chr size zero means chr ram", chr_size_bytes, 26'd0);
        expect2("nrom128 horizontal mirroring", mirroring, 2'd0);
        expect_bool("nrom128 no four screen", four_screen, 1'b0);
        expect_bool("nrom128 no trainer", trainer, 1'b0);
        expect_bool("nrom128 no battery", battery, 1'b0);
        expect4("nrom128 default prg ram shift", prg_ram_shift, 4'd7);
        expect4("nrom128 default chr ram shift", chr_ram_shift, 4'd7);
        expect2("nrom128 timing default ntsc", cpu_ppu_timing, 2'd0);
        expect28("nrom128 expected size", expected_size, 28'd16400);
        expect_bool("nrom128 no trailing bytes", size_trailing, 1'b0);
        expect4("nrom128 alt default prg shift", prg_ram_shift_alt, 4'd0);
        expect4("nrom128 alt default chr shift", chr_ram_shift_alt, 4'd0);
        expect_bool("nrom128 alt valid", valid_alt, 1'b1);
        expect12("nrom128 alt mapper", mapper_id_alt, 12'd4);
        $display("clean ines header mapper mirroring sizes and default ram shift PASS");
    end
endtask

task test_flag6_bits;
    begin
        load_ines(8'h4E, 8'h45, 8'h53, 8'h1A, 8'h01, 8'h00, 8'h02, 8'h00, 64'd0);
        run_parse(32'd16400);
        expect_bool("f6 battery bit", battery, 1'b1);
        expect_bool("f6 battery keeps trainer low", trainer, 1'b0);
        expect2("f6 bit0 clear is horizontal", mirroring, 2'd0);
        expect_bool("f6 bit3 clear is not four screen", four_screen, 1'b0);
        expect12("f6 battery only keeps mapper low", mapper_id, 12'd0);

        load_ines(8'h4E, 8'h45, 8'h53, 8'h1A, 8'h01, 8'h00, 8'h01, 8'h00, 64'd0);
        run_parse(32'd16400);
        expect2("f6 bit0 set is vertical", mirroring, 2'd1);
        expect_bool("f6 vertical keeps battery low", battery, 1'b0);

        load_ines(8'h4E, 8'h45, 8'h53, 8'h1A, 8'h01, 8'h00, 8'h04, 8'h00, 64'd0);
        run_parse(32'd16912);
        expect_bool("f6 trainer bit", trainer, 1'b1);
        expect28("f6 trainer adds 512 to expected size", expected_size, 28'd16912);
        expect_bool("f6 trainer exact size valid", valid, 1'b1);

        load_ines(8'h4E, 8'h45, 8'h53, 8'h1A, 8'h01, 8'h00, 8'h08, 8'h00, 64'd0);
        run_parse(32'd16400);
        expect_bool("f6 four screen bit", four_screen, 1'b1);
        expect2("f6 four screen keeps raw mirroring", mirroring, 2'd0);
        expect_bool("f6 four screen still valid", valid, 1'b1);

        load_ines(8'h4E, 8'h45, 8'h53, 8'h1A, 8'h01, 8'h00, 8'hA7, 8'h00, 64'd0);
        run_parse(32'd16912);
        expect12("f6 mapper low nibble", mapper_id, 12'h0A);
        expect2("f6 combined vertical bit", mirroring, 2'd1);
        expect_bool("f6 combined battery bit", battery, 1'b1);
        expect_bool("f6 combined trainer bit", trainer, 1'b1);
        expect_bool("f6 combined four screen stays low", four_screen, 1'b0);
        expect28("f6 combined expected size", expected_size, 28'd16912);
        expect_bool("f6 combined valid", valid, 1'b1);
        $display("flags6 mirroring battery trainer four screen and mapper nibble PASS");
    end
endtask

task test_trainer_and_offsets;
    begin
        load_ines(8'h4E, 8'h45, 8'h53, 8'h1A, 8'h02, 8'h01, 8'h1F, 8'h00, 64'd0);
        run_parse(32'd41488);
        expect_bool("mmc1 trainer battery four screen valid", valid, 1'b1);
        expect12("mmc1 mapper id", mapper_id, 12'd1);
        expect2("mmc1 vertical mirroring", mirroring, 2'd1);
        expect_bool("mmc1 four screen", four_screen, 1'b1);
        expect_bool("mmc1 trainer", trainer, 1'b1);
        expect_bool("mmc1 battery", battery, 1'b1);
        expect26("mmc1 prg size", prg_size_bytes, 26'd32768);
        expect26("mmc1 chr size", chr_size_bytes, 26'd8192);
        expect28("mmc1 expected size with trainer", expected_size, 28'd41488);
        $display("trainer offset prg base and battery flag PASS");
    end
endtask

task test_dirty_ines_mask;
    begin
        load_ines(8'h4E, 8'h45, 8'h53, 8'h1A, 8'h01, 8'h00, 8'h00, 8'hF0,
                  {8'h01, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00});
        run_parse(32'd16400);
        expect_bool("dirty tail not nes2", nes2, 1'b0);
        expect_bool("dirty tail flagged", dirty_ines, 1'b1);
        expect_bool("dirty tail still valid", valid, 1'b1);
        expect12("dirty tail masks flags7 high nibble", mapper_id, 12'd0);
        expect4("dirty tail uses default prg shift", prg_ram_shift, 4'd7);
        expect2("dirty tail ignores byte 12 timing", cpu_ppu_timing, 2'd0);
        expect128("dirty tail header captured", dbg_header,
                  {8'h01, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00,
                   8'hF0, 8'h00, 8'h00, 8'h01, 8'h1A, 8'h53, 8'h45, 8'h4E});

        load_ines(8'h4E, 8'h45, 8'h53, 8'h1A, 8'h01, 8'h00, 8'h30, 8'hD4, 64'd0);
        run_parse(32'd16400);
        expect_bool("archaic format 0100 flagged dirty", dirty_ines, 1'b1);
        expect_bool("archaic format 0100 not nes2", nes2, 1'b0);
        expect12("archaic format 0100 mapper from flags6 only", mapper_id, 12'd3);
        expect_bool("archaic format 0100 valid", valid, 1'b1);

        load_ines(8'h4E, 8'h45, 8'h53, 8'h1A, 8'h01, 8'h00, 8'h10, 8'h8C, 64'd0);
        run_parse(32'd16400);
        expect_bool("format 1100 flagged dirty", dirty_ines, 1'b1);
        expect_bool("format 1100 not nes2", nes2, 1'b0);
        expect12("format 1100 mapper from flags6 only", mapper_id, 12'd1);
        expect_bool("format 1100 valid", valid, 1'b1);

        load_ines(8'h4E, 8'h45, 8'h53, 8'h1A, 8'h01, 8'h00, 8'h00, 8'h00, 64'd0);
        run_parse(32'd16400);
        expect_bool("zero format and zero tail is clean", dirty_ines, 1'b0);
        expect_bool("zero format and zero tail not nes2", nes2, 1'b0);
        $display("dirty ines header mask on format bits and flags7 high nibble PASS");
    end
endtask

task test_nes2_fields;
    begin
        load_ines(8'h4E, 8'h45, 8'h53, 8'h1A, 8'h00, 8'h03, 8'hB0, 8'h08,
                  {8'h00, 8'h00, 8'h00, 8'h02, 8'h08, 8'h07, 8'h03, 8'h34});
        run_parse(32'd12607504);
        expect_bool("nes2 valid", valid, 1'b1);
        expect4("nes2 error none", error, 4'd0);
        expect_bool("nes2 detected", nes2, 1'b1);
        expect_bool("nes2 not dirty", dirty_ines, 1'b0);
        expect12("nes2 nine bit mapper", mapper_id, 12'h40B);
        expect4("nes2 submapper", submapper_id, 4'd3);
        expect26("nes2 prg msb extended size", prg_size_bytes, 26'd12582912);
        expect26("nes2 chr size", chr_size_bytes, 26'd24576);
        expect4("nes2 prg ram shift", prg_ram_shift, 4'd7);
        expect4("nes2 chr ram shift", chr_ram_shift, 4'd8);
        expect2("nes2 timing multi region", cpu_ppu_timing, 2'd2);
        expect_bool("nes2 prg rom exponent clear", prg_rom_exponent, 1'b0);
        expect_bool("nes2 chr rom exponent clear", chr_rom_exponent, 1'b0);
        expect_bool("nes2 prg ram exponent clear", prg_ram_exponent, 1'b0);
        expect_bool("nes2 chr ram exponent clear", chr_ram_exponent, 1'b0);
        expect28("nes2 expected size", expected_size, 28'd12607504);
        expect4("nes2 alt prg ram shift", prg_ram_shift_alt, 4'd7);
        expect4("nes2 alt chr ram shift", chr_ram_shift_alt, 4'd8);
        expect12("nes2 alt mapper", mapper_id_alt, 12'h40B);
        $display("nes2 mapper submapper size msb ram shift and timing PASS");
    end
endtask

task test_nes2_exponent_flags;
    begin
        load_ines(8'h4E, 8'h45, 8'h53, 8'h1A, 8'h01, 8'h00, 8'h00, 8'h08,
                  {8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h10, 8'h00});
        run_parse(32'd2113552);
        expect4("prg exponent error", error, 4'd3);
        expect_bool("prg exponent error invalid", valid, 1'b0);
        expect_bool("prg rom exponent flag", prg_rom_exponent, 1'b1);
        expect_bool("prg rom exponent clears chr flag", chr_rom_exponent, 1'b0);
        expect_bool("nes2 confirmed for prg exponent", nes2, 1'b1);

        load_ines(8'h4E, 8'h45, 8'h53, 8'h1A, 8'h01, 8'h00, 8'h00, 8'h08,
                  {8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h04, 8'h00});
        run_parse(32'd16400);
        expect4("chr exponent error", error, 4'd3);
        expect_bool("chr rom exponent flag", chr_rom_exponent, 1'b1);
        expect_bool("chr exponent clears prg flag", prg_rom_exponent, 1'b0);

        load_ines(8'h4E, 8'h45, 8'h53, 8'h1A, 8'h01, 8'h00, 8'h00, 8'h08,
                  {8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h40, 8'h00, 8'h00});
        run_parse(32'd16400);
        expect4("prg ram exponent error", error, 4'd3);
        expect_bool("prg ram exponent flag", prg_ram_exponent, 1'b1);
        expect4("prg ram exponent shift still decoded", prg_ram_shift, 4'd0);
        expect_bool("prg ram exponent chr flag low", chr_ram_exponent, 1'b0);

        load_ines(8'h4E, 8'h45, 8'h53, 8'h1A, 8'h01, 8'h00, 8'h00, 8'h08,
                  {8'h00, 8'h00, 8'h00, 8'h00, 8'h80, 8'h00, 8'h00, 8'h00});
        run_parse(32'd16400);
        expect4("chr ram exponent error", error, 4'd3);
        expect_bool("chr ram exponent flag", chr_ram_exponent, 1'b1);
        expect4("chr ram exponent shift still decoded", chr_ram_shift, 4'd0);
        $display("nes2 exponent notation flags for rom and ram sizes PASS");
    end
endtask

task test_magic_errors;
    begin
        load_ines(8'h00, 8'h45, 8'h53, 8'h1A, 8'h02, 8'h01, 8'h1F, 8'h00, 64'd0);
        run_parse(32'd41488);
        expect_bool("bad magic0 invalid", valid, 1'b0);
        expect4("bad magic0 error", error, 4'd1);

        load_ines(8'h4E, 8'h46, 8'h53, 8'h1A, 8'h02, 8'h01, 8'h1F, 8'h00, 64'd0);
        run_parse(32'd41488);
        expect4("bad magic1 error", error, 4'd1);

        load_ines(8'h4E, 8'h45, 8'h54, 8'h1A, 8'h02, 8'h01, 8'h1F, 8'h00, 64'd0);
        run_parse(32'd41488);
        expect4("bad magic2 error", error, 4'd1);

        load_ines(8'h4E, 8'h45, 8'h53, 8'h1B, 8'h02, 8'h01, 8'h1F, 8'h00, 64'd0);
        run_parse(32'd41488);
        expect4("bad magic3 error", error, 4'd1);
        expect12("bad magic clears mapper", mapper_id, 12'd0);
        expect26("bad magic clears prg size", prg_size_bytes, 26'd0);
        expect26("bad magic clears chr size", chr_size_bytes, 26'd0);
        expect_bool("bad magic clears nes2", nes2, 1'b0);
        expect_bool("bad magic clears dirty", dirty_ines, 1'b0);
        expect2("bad magic clears mirroring", mirroring, 2'd0);
        expect_bool("bad magic clears four screen", four_screen, 1'b0);
        expect_bool("bad magic clears trainer", trainer, 1'b0);
        expect_bool("bad magic clears battery", battery, 1'b0);
        expect4("bad magic clears prg shift", prg_ram_shift, 4'd0);
        expect4("bad magic clears chr shift", chr_ram_shift, 4'd0);
        expect2("bad magic clears timing", cpu_ppu_timing, 2'd0);
        expect28("bad magic clears expected size", expected_size, 28'd0);
        expect_bool("bad magic clears trailing flag", size_trailing, 1'b0);
        expect8("bad magic keeps raw byte 0", dbg_header[7:0], 8'h4E);
        expect8("bad magic keeps raw byte 3", dbg_header[31:24], 8'h1B);
        expect_bool("bad magic alt also invalid", valid_alt, 1'b0);

        load_ines(8'h00, 8'h45, 8'h53, 8'h1A, 8'h00, 8'h00, 8'h00, 8'h00, 64'd0);
        run_parse(32'd0);
        expect4("magic beats prg zero and short file", error, 4'd1);
        expect26("magic priority prg size cleared", prg_size_bytes, 26'd0);

        load_ines(8'h4E, 8'h45, 8'h53, 8'h00, 8'h01, 8'h00, 8'h40, 8'hF0,
                  {8'h01, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00});
        run_parse(32'd16400);
        expect4("bad magic tail still error one", error, 4'd1);
        expect_bool("bad magic tail invalid", valid, 1'b0);
        expect_bool("bad magic tail clears dirty", dirty_ines, 1'b0);
        expect_bool("bad magic tail clears nes2", nes2, 1'b0);
        $display("magic check and field zeroing on bad magic PASS");
    end
endtask

task test_prg_zero_error;
    begin
        load_ines(8'h4E, 8'h45, 8'h53, 8'h1A, 8'h00, 8'h01, 8'h40, 8'h00, 64'd0);
        run_parse(32'd16);
        expect4("ines prg zero error", error, 4'd2);
        expect_bool("ines prg zero invalid", valid, 1'b0);
        expect26("ines prg zero prg size", prg_size_bytes, 26'd0);
        expect26("ines prg zero chr size", chr_size_bytes, 26'd8192);
        expect28("ines prg zero expected size", expected_size, 28'd8208);

        load_ines(8'h4E, 8'h45, 8'h53, 8'h1A, 8'h00, 8'h01, 8'h40, 8'h08, 64'd0);
        run_parse(32'd8208);
        expect4("nes2 prg zero error", error, 4'd2);
        expect_bool("nes2 prg zero invalid", valid, 1'b0);
        expect_bool("nes2 prg zero still nes2", nes2, 1'b1);
        expect12("nes2 prg zero mapper decoded", mapper_id, 12'd4);
        $display("zero prg rom size error beats length check PASS");
    end
endtask

task test_file_size_check;
    begin
        load_ines(8'h4E, 8'h45, 8'h53, 8'h1A, 8'h02, 8'h01, 8'h1F, 8'h00, 64'd0);
        run_parse(32'd41487);
        expect4("one byte short error", error, 4'd4);
        expect_bool("one byte short invalid", valid, 1'b0);
        expect28("expected size unchanged on mismatch", expected_size, 28'd41488);
        expect_bool("one byte short not trailing", size_trailing, 1'b0);

        run_parse(32'd0);
        expect4("empty file error", error, 4'd4);

        run_parse(32'd41489);
        expect4("one byte long is not an error", error, 4'd0);
        expect_bool("one byte long still valid", valid, 1'b1);
        expect_bool("one byte long trailing flag", size_trailing, 1'b1);

        run_parse(32'hFFFFFFFF);
        expect_bool("huge file valid", valid, 1'b1);
        expect_bool("huge file trailing flag", size_trailing, 1'b1);

        run_parse(32'd41488);
        expect_bool("exact size clears trailing", size_trailing, 1'b0);
        expect_bool("exact size valid", valid, 1'b1);

        run_parse(32'd16400);
        expect4("trainer file too short for its own size", error, 4'd4);

        load_ines(8'h4E, 8'h45, 8'h53, 8'h1A, 8'h01, 8'h00, 8'h40, 8'h00, 64'd0);
        run_parse(32'd16399);
        expect4("no trainer file one byte short", error, 4'd4);
        expect28("no trainer expected size", expected_size, 28'd16400);
        $display("actual_size versus expected_size short and trailing bytes PASS");
    end
endtask

task test_start_ignored_while_busy;
    begin
        load_ines(8'h4E, 8'h45, 8'h53, 8'h1A, 8'h01, 8'h00, 8'h40, 8'h00, 64'd0);
        actual_size   = 32'd16400;
        idx_log_count = 0;
        busy_cycles   = 0;
        done_count    = 0;
        start = 1'b1;
        @(posedge clk);
        #1;
        repeat (4) @(posedge clk);
        #1 start = 1'b0;
        wait (done_count == 1);
        #1;
        expect32("held start still one done pulse", done_count, 32'd1);
        expect32("held start still 17 busy cycles", busy_cycles, 32'd17);
        expect32("held start still 16 fetch samples", idx_log_count, 32'd16);
        expect12("held start result mapper", mapper_id, 12'd4);
        expect_bool("held start result valid", valid, 1'b1);
        expect32("held start no instance skew", done_mismatch, 32'd0);
        $display("start held high during a parse does not restart the fsm PASS");
    end
endtask

task test_output_hold_and_restart;
    begin
        load_ines(8'h4E, 8'h45, 8'h53, 8'h1A, 8'h02, 8'h01, 8'hB9, 8'h00, 64'd0);
        run_parse(32'd40976);
        expect12("hold mapper before restart", mapper_id, 12'h0B);
        expect26("hold prg size before restart", prg_size_bytes, 26'd32768);
        expect_bool("hold valid before restart", valid, 1'b1);
        expect28("hold expected size before restart", expected_size, 28'd40976);
        start = 1'b1;
        @(posedge clk);
        #1 start = 1'b0;
        #1;
        expect_bool("hold valid during next fetch", valid, 1'b1);
        expect12("hold mapper during next fetch", mapper_id, 12'h0B);
        expect_bool("hold busy during next fetch", busy, 1'b1);
        wait (done_count == 2);
        #1;
        expect_bool("restart busy low", busy, 1'b0);
        expect_bool("restart done low", done, 1'b0);

        load_ines(8'h4E, 8'h45, 8'h53, 8'h1A, 8'h01, 8'h00, 8'h40, 8'h00, 64'd0);
        run_parse(32'd16400);
        expect12("reparse mapper", mapper_id, 12'd4);
        expect26("reparse prg size", prg_size_bytes, 26'd16384);
        expect26("reparse chr size", chr_size_bytes, 26'd0);
        expect_bool("reparse nes2 cleared", nes2, 1'b0);
        expect_bool("reparse trainer cleared", trainer, 1'b0);
        expect_bool("reparse battery cleared", battery, 1'b0);
        expect_bool("reparse four screen cleared", four_screen, 1'b0);
        expect28("reparse expected size", expected_size, 28'd16400);
        $display("outputs hold between parses and a restart re-decodes PASS");
    end
endtask

task test_reset_behavior;
    begin
        load_ines(8'h4E, 8'h45, 8'h53, 8'h1A, 8'h02, 8'h01, 8'h1F, 8'h00, 64'd0);
        run_parse(32'd41488);
        expect12("pre reset mapper", mapper_id, 12'd1);
        reset = 1'b1;
        #1;
        expect_bool("reset busy low", busy, 1'b0);
        expect_bool("reset done low", done, 1'b0);
        expect_bool("reset valid low", valid, 1'b0);
        expect4("reset error none", error, 4'd0);
        expect_bool("reset nes2 low", nes2, 1'b0);
        expect_bool("reset dirty low", dirty_ines, 1'b0);
        expect12("reset mapper cleared", mapper_id, 12'd0);
        expect4("reset submapper cleared", submapper_id, 4'd0);
        expect26("reset prg size cleared", prg_size_bytes, 26'd0);
        expect26("reset chr size cleared", chr_size_bytes, 26'd0);
        expect2("reset mirroring cleared", mirroring, 2'd0);
        expect_bool("reset four screen cleared", four_screen, 1'b0);
        expect_bool("reset trainer cleared", trainer, 1'b0);
        expect_bool("reset battery cleared", battery, 1'b0);
        expect4("reset prg shift cleared", prg_ram_shift, 4'd0);
        expect4("reset chr shift cleared", chr_ram_shift, 4'd0);
        expect2("reset timing cleared", cpu_ppu_timing, 2'd0);
        expect_bool("reset prg exponent cleared", prg_rom_exponent, 1'b0);
        expect_bool("reset chr exponent cleared", chr_rom_exponent, 1'b0);
        expect28("reset expected size cleared", expected_size, 28'd0);
        expect_bool("reset trailing cleared", size_trailing, 1'b0);
        expect4("reset byte index cleared", dbg_byte_index, 4'd0);
        expect128("reset header shadow cleared", dbg_header, 64'd0);
        #40;
        expect_bool("reset held keeps valid low", valid, 1'b0);
        expect_bool("reset held keeps busy low", busy, 1'b0);
        reset = 1'b0;
        #1;
        run_parse(32'd41488);
        expect_bool("parse after reset valid", valid, 1'b1);
        expect12("parse after reset mapper", mapper_id, 12'd1);
        $display("asynchronous reset clears decode state and reparses PASS");
    end
endtask

initial begin
    clk            = 1'b0;
    reset          = 1'b1;
    start          = 1'b0;
    header         = 128'd0;
    actual_size    = 32'd0;
    fail_count     = 0;
    check_count    = 0;
    done_mismatch  = 0;
    log_overflow   = 0;
    idx_log_count  = 0;
    busy_cycles    = 0;
    done_count     = 0;
    exp_idx        = 4'd0;

    #4 reset = 1'b0;
    #2;

    test_byte_index_fsm;
    test_clean_ines_nrom128;
    test_flag6_bits;
    test_trainer_and_offsets;
    test_dirty_ines_mask;
    test_nes2_fields;
    test_nes2_exponent_flags;
    test_magic_errors;
    test_prg_zero_error;
    test_file_size_check;
    test_start_ignored_while_busy;
    test_output_hold_and_restart;
    test_reset_behavior;

    expect32("no fetch log overflow", log_overflow, 32'd0);
    expect32("instances agree on done", done_mismatch, 32'd0);

    $display("CHECKS %0d", check_count);
    if (fail_count != 0) begin
        $display("FAIL tb_ines_header_parser with %0d failing checks", fail_count);
        $finish;
    end
    $display("PASS tb_ines_header_parser magic/nes2/dirty-mask/sizes/error-priority");
    $finish;
end

initial begin
    #200000;
    $display("FAIL tb_ines_header_parser global timeout");
    $finish;
end

endmodule
