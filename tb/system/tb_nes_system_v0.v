`timescale 1ns/1ps

module tb_nes_system_v0;

localparam PRG_SIZE_BYTES = 16384;
localparam PRG_INDEX_BITS = $clog2(PRG_SIZE_BYTES);
localparam [14:0] PRG_WINDOW_MASK = 15'h7FFF >> (15 - PRG_INDEX_BITS);
localparam [14:0] PRG_RESET_VECTOR_IDX = 16'hFFFC & PRG_WINDOW_MASK;
localparam [14:0] PRG_RESET_VECTOR_HI_IDX = 16'hFFFD & PRG_WINDOW_MASK;
localparam [15:0] RAM_MIRROR_CELL = 16'h0010;
localparam [15:0] RAM_MIRROR_ALIAS = 16'h1810;
localparam [15:0] RAM_MIRROR_READ = 16'h1010;
localparam [15:0] PRG_MIRROR_LOW = 16'h8200;
localparam [15:0] PRG_MIRROR_HIGH = 16'hC200;
localparam [15:0] TAIL_TESTS = 16'h8066;
localparam [15:0] SELF_LOOP = 16'h8086;
localparam [15:0] FAILURE_LOOP = 16'h8062;

reg clk;
reg reset;

wire pixel_valid;
wire [7:0] pixel_x;
wire [7:0] pixel_y;
wire [3:0] pixel_index;
wire frame_done;
wire vblank;
wire nmi_o;
wire [31:0] cpu_cycle;
wire [8:0] ppu_dot;
wire [8:0] ppu_scanline;

reg prev_frame_done;
reg prev_vblank;
reg check_enable;
reg [3:0] expected_index;
reg saw_reset_lo;
reg saw_reset_hi;
reg saw_first_fetch;
reg saw_fetch_bus;
reg saw_first_opcode;
reg saw_self_loop;
reg tail_tests_entered;
reg expected_vblank;

integer frame_count;
integer checked_index1;
integer checked_index2;
integer visible_count;
integer ppu_wr_total;
integer ppu_wr_ctrl;
integer ppu_wr_mask;
integer ppu_wr_addr;
integer ppu_wr_data;
integer ppu_wr_other;
integer ppu_rd_total;
integer skipped_scroll_dots;
integer cpu_bus_count;
integer vblank_rise_count;
integer vblank_fall_count;
integer clear_index;
integer ram_rd_total;
integer ram_wr_total;
integer ram_rd_1010;
integer ram_wr_0010;
integer ram_wr_1810;
reg [7:0] ram_rd_1010_data;
integer ram_mirror_wr;
integer prg_rd_lower;
integer prg_rd_upper;
integer prg_rd_fffc;
integer prg_rd_fffd;
integer prg_rd_c200;

reg [8:0] rise_line;
reg [8:0] rise_dot;
reg [8:0] fall_line;
reg [8:0] fall_dot;
reg [8:0] prev_dot;
integer clk_count;
integer frame_mark;
integer frame_clk_delta;
reg have_frame_mark;

nes_system_v0 dut (
    .clk(clk),
    .reset(reset),
    .pixel_valid(pixel_valid),
    .pixel_x(pixel_x),
    .pixel_y(pixel_y),
    .pixel_index(pixel_index),
    .frame_done(frame_done),
    .vblank(vblank),
    .nmi_o(nmi_o),
    .cpu_cycle(cpu_cycle),
    .ppu_dot(ppu_dot),
    .ppu_scanline(ppu_scanline)
);

always #5 clk = !clk;

function [3:0] expected_pixel_index;
    input [8:0] line;
    input [9:0] column;
    begin
        if ((line < 9'd8) && (column >= 9'd8) && (column <= 9'd15))
            expected_pixel_index = 4'd2;
        else
            expected_pixel_index = 4'd1;
    end
endfunction

function [7:0] prg_mirror_read;
    input [15:0] address;
    begin
        prg_mirror_read = dut.prg_rom[address[PRG_INDEX_BITS-1:0]];
    end
endfunction

function [7:0] ram_mirror_read;
    input [15:0] address;
    begin
        ram_mirror_read = dut.cpu_ram[address[10:0]];
    end
endfunction

task put_prg_byte;
    input [15:0] address;
    input [7:0] value;
    begin
        dut.prg_rom[address[PRG_INDEX_BITS-1:0]] = value;
    end
endtask

task load_prg_rom;
    begin
        for (clear_index = 0; clear_index < PRG_SIZE_BYTES; clear_index = clear_index + 1)
            dut.prg_rom[clear_index] = 8'h00;
        for (clear_index = 0; clear_index < 2048; clear_index = clear_index + 1)
            dut.cpu_ram[clear_index] = 8'h00;
        dut.prg_rom[PRG_RESET_VECTOR_IDX] = 8'h00;
        dut.prg_rom[PRG_RESET_VECTOR_HI_IDX] = 8'h80;

        put_prg_byte(16'h8000, 8'hA9);
        put_prg_byte(16'h8001, 8'h00);
        put_prg_byte(16'h8002, 8'h8D);
        put_prg_byte(16'h8003, 8'h00);
        put_prg_byte(16'h8004, 8'h20);
        put_prg_byte(16'h8005, 8'h8D);
        put_prg_byte(16'h8006, 8'h01);
        put_prg_byte(16'h8007, 8'h20);
        put_prg_byte(16'h8008, 8'hA9);
        put_prg_byte(16'h8009, 8'h00);
        put_prg_byte(16'h800A, 8'h8D);
        put_prg_byte(16'h800B, 8'h06);
        put_prg_byte(16'h800C, 8'h20);
        put_prg_byte(16'h800D, 8'h8D);
        put_prg_byte(16'h800E, 8'h06);
        put_prg_byte(16'h800F, 8'h20);
        put_prg_byte(16'h8010, 8'hA2);
        put_prg_byte(16'h8011, 8'h08);
        put_prg_byte(16'h8012, 8'hA9);
        put_prg_byte(16'h8013, 8'hFF);
        put_prg_byte(16'h8014, 8'h8D);
        put_prg_byte(16'h8015, 8'h07);
        put_prg_byte(16'h8016, 8'h20);
        put_prg_byte(16'h8017, 8'hCA);
        put_prg_byte(16'h8018, 8'hD0);
        put_prg_byte(16'h8019, 8'hFA);
        put_prg_byte(16'h801A, 8'hA9);
        put_prg_byte(16'h801B, 8'h20);
        put_prg_byte(16'h801C, 8'h8D);
        put_prg_byte(16'h801D, 8'h06);
        put_prg_byte(16'h801E, 8'h20);
        put_prg_byte(16'h801F, 8'hA9);
        put_prg_byte(16'h8020, 8'h01);
        put_prg_byte(16'h8021, 8'h8D);
        put_prg_byte(16'h8022, 8'h06);
        put_prg_byte(16'h8023, 8'h20);
        put_prg_byte(16'h8024, 8'hA9);
        put_prg_byte(16'h8025, 8'h02);
        put_prg_byte(16'h8026, 8'h8D);
        put_prg_byte(16'h8027, 8'h07);
        put_prg_byte(16'h8028, 8'h20);
        put_prg_byte(16'h8029, 8'hA9);
        put_prg_byte(16'h802A, 8'h3F);
        put_prg_byte(16'h802B, 8'h8D);
        put_prg_byte(16'h802C, 8'h06);
        put_prg_byte(16'h802D, 8'h20);
        put_prg_byte(16'h802E, 8'hA9);
        put_prg_byte(16'h802F, 8'h01);
        put_prg_byte(16'h8030, 8'h8D);
        put_prg_byte(16'h8031, 8'h06);
        put_prg_byte(16'h8032, 8'h20);
        put_prg_byte(16'h8033, 8'hA9);
        put_prg_byte(16'h8034, 8'h21);
        put_prg_byte(16'h8035, 8'h8D);
        put_prg_byte(16'h8036, 8'h07);
        put_prg_byte(16'h8037, 8'h20);
        put_prg_byte(16'h8038, 8'hA9);
        put_prg_byte(16'h8039, 8'h3F);
        put_prg_byte(16'h803A, 8'h8D);
        put_prg_byte(16'h803B, 8'h06);
        put_prg_byte(16'h803C, 8'h20);
        put_prg_byte(16'h803D, 8'hA9);
        put_prg_byte(16'h803E, 8'h02);
        put_prg_byte(16'h803F, 8'h8D);
        put_prg_byte(16'h8040, 8'h06);
        put_prg_byte(16'h8041, 8'h20);
        put_prg_byte(16'h8042, 8'hA9);
        put_prg_byte(16'h8043, 8'h32);
        put_prg_byte(16'h8044, 8'h8D);
        put_prg_byte(16'h8045, 8'h07);
        put_prg_byte(16'h8046, 8'h20);
        put_prg_byte(16'h8047, 8'hA9);
        put_prg_byte(16'h8048, 8'h00);
        put_prg_byte(16'h8049, 8'h8D);
        put_prg_byte(16'h804A, 8'h06);
        put_prg_byte(16'h804B, 8'h20);
        put_prg_byte(16'h804C, 8'h8D);
        put_prg_byte(16'h804D, 8'h06);
        put_prg_byte(16'h804E, 8'h20);
        put_prg_byte(16'h804F, 8'h8D);
        put_prg_byte(16'h8050, 8'h00);
        put_prg_byte(16'h8051, 8'h20);
        put_prg_byte(16'h8052, 8'hA9);
        put_prg_byte(16'h8053, 8'h0A);
        put_prg_byte(16'h8054, 8'h8D);
        put_prg_byte(16'h8055, 8'h01);
        put_prg_byte(16'h8056, 8'h20);
        put_prg_byte(16'h8057, 8'hAD);
        put_prg_byte(16'h8058, 8'h02);
        put_prg_byte(16'h8059, 8'h20);
        put_prg_byte(16'h805A, 8'hD0);
        put_prg_byte(16'h805B, 8'h06);
        put_prg_byte(16'h805C, 8'h4C);
        put_prg_byte(16'h805D, 8'h66);
        put_prg_byte(16'h805E, 8'h80);
        put_prg_byte(16'h8062, 8'h4C);
        put_prg_byte(16'h8063, 8'h62);
        put_prg_byte(16'h8064, 8'h80);
        put_prg_byte(16'h8066, 8'hA9);
        put_prg_byte(16'h8067, 8'h5A);
        put_prg_byte(16'h8068, 8'h8D);
        put_prg_byte(16'h8069, 8'h10);
        put_prg_byte(16'h806A, 8'h00);
        put_prg_byte(16'h806B, 8'h8D);
        put_prg_byte(16'h806C, 8'h10);
        put_prg_byte(16'h806D, 8'h18);
        put_prg_byte(16'h806E, 8'hAD);
        put_prg_byte(16'h806F, 8'h10);
        put_prg_byte(16'h8070, 8'h10);
        put_prg_byte(16'h8071, 8'hC9);
        put_prg_byte(16'h8072, 8'h5A);
        put_prg_byte(16'h8073, 8'hD0);
        put_prg_byte(16'h8074, 8'hED);
        put_prg_byte(16'h8075, 8'hAD);
        put_prg_byte(16'h8076, 8'h00);
        put_prg_byte(16'h8077, 8'hC2);
        put_prg_byte(16'h8078, 8'hC9);
        put_prg_byte(16'h8079, 8'hA5);
        put_prg_byte(16'h807A, 8'hD0);
        put_prg_byte(16'h807B, 8'hE6);
        put_prg_byte(16'h807C, 8'hAD);
        put_prg_byte(16'h807D, 8'h00);
        put_prg_byte(16'h807E, 8'h82);
        put_prg_byte(16'h807F, 8'hC9);
        put_prg_byte(16'h8080, 8'hA5);
        put_prg_byte(16'h8081, 8'hD0);
        put_prg_byte(16'h8082, 8'hDF);
        put_prg_byte(16'h8083, 8'h4C);
        put_prg_byte(16'h8084, 8'h86);
        put_prg_byte(16'h8085, 8'h80);
        put_prg_byte(16'h8086, 8'h4C);
        put_prg_byte(16'h8087, 8'h86);
        put_prg_byte(16'h8088, 8'h80);
        put_prg_byte(PRG_MIRROR_LOW, 8'hA5);
    end
endtask

task load_video_ram;
    begin
        for (clear_index = 0; clear_index < 8192; clear_index = clear_index + 1)
            dut.u_ppu.chr_ram[clear_index] = 8'h00;
        for (clear_index = 0; clear_index < 2048; clear_index = clear_index + 1)
            dut.u_ppu.nametable_ram[clear_index] = 8'h00;
        for (clear_index = 0; clear_index < 256; clear_index = clear_index + 1)
            dut.u_ppu.oam_ram[clear_index] = 8'h00;
        for (clear_index = 0; clear_index < 32; clear_index = clear_index + 1)
            dut.u_ppu.palette_ram[clear_index] = 8'h00;
        for (clear_index = 1; clear_index < 8; clear_index = clear_index + 1)
            dut.u_ppu.chr_ram[clear_index] = 8'hFF;
        for (clear_index = 8; clear_index < 16; clear_index = clear_index + 1)
            dut.u_ppu.chr_ram[clear_index] = 8'h00;
        for (clear_index = 32; clear_index < 40; clear_index = clear_index + 1)
            dut.u_ppu.chr_ram[clear_index] = 8'h00;
        for (clear_index = 40; clear_index < 48; clear_index = clear_index + 1)
            dut.u_ppu.chr_ram[clear_index] = 8'hFF;
        dut.u_ppu.palette_ram[0] = 8'h0F;
    end
endtask

always @(posedge clk) begin
    if (reset)
        clk_count = 0;
    else
        clk_count = clk_count + 1;
end

always @(posedge clk) begin
    if (!reset) begin
        if (dut.ppu_reg_cs) begin
            if (dut.u_ppu.reg_we) begin
                ppu_wr_total = ppu_wr_total + 1;
                case (dut.u_ppu.reg_addr)
                    3'd0: ppu_wr_ctrl = ppu_wr_ctrl + 1;
                    3'd1: ppu_wr_mask = ppu_wr_mask + 1;
                    3'd6: ppu_wr_addr = ppu_wr_addr + 1;
                    3'd7: ppu_wr_data = ppu_wr_data + 1;
                    default: ppu_wr_other = ppu_wr_other + 1;
                endcase
            end else begin
                ppu_rd_total = ppu_rd_total + 1;
            end
        end
        if (dut.ce_ppu && dut.ppu_reg_cs)
            skipped_scroll_dots = skipped_scroll_dots + 1;
        if (dut.cpu_bus_fire) begin
            cpu_bus_count = cpu_bus_count + 1;
            if (!dut.ce_cpu)
                $fatal(1, "cpu bus fire without ce_cpu at div_phase=%0d", dut.div_phase);
            if (!dut.ce_ppu)
                $fatal(1, "cpu bus fire is not aligned with a ppu ce at div_phase=%0d", dut.div_phase);
        end
        if (dut.u_cpu.dbg_pc === TAIL_TESTS)
            tail_tests_entered = 1'b1;
        if ((tail_tests_entered === 1'b1) && (dut.u_cpu.dbg_pc === SELF_LOOP)) begin
            saw_self_loop = 1'b1;
        end else if (saw_self_loop === 1'b1) begin
            if ((dut.u_cpu.dbg_pc !== SELF_LOOP + 16'd1) &&
                (dut.u_cpu.dbg_pc !== SELF_LOOP + 16'd2))
                $fatal(1, "cpu left the jmp self loop, pc=%04h", dut.u_cpu.dbg_pc);
        end
        if ((dut.u_cpu.dbg_pc === FAILURE_LOOP + 16'd1) ||
            (dut.u_cpu.dbg_pc === FAILURE_LOOP + 16'd2))
            $fatal(1, "cpu entered the failure loop at %04h, pc=%04h",
                   FAILURE_LOOP, dut.u_cpu.dbg_pc);
        if (saw_first_fetch === 1'b1) begin
            if (dut.u_cpu.dbg_pc[15:8] !== 8'h80)
                $fatal(1, "cpu pc left the prg program area, pc=%04h", dut.u_cpu.dbg_pc);
        end
        if (dut.u_cpu.dbg_illegal !== 1'b0)
            $fatal(1, "dbg_illegal asserted, pc=%04h state=%0d opcode=%02h",
                   dut.u_cpu.dbg_pc, dut.u_cpu.dbg_state, dut.u_cpu.dbg_opcode);
        case (dut.u_cpu.dbg_state)
            7'd5: if (!saw_reset_lo) begin
                saw_reset_lo = 1'b1;
                if (dut.u_cpu.bus_addr !== 16'hFFFC)
                    $fatal(1, "reset vector low fetch address got %04h expected FFFC",
                           dut.u_cpu.bus_addr);
            end
            7'd6: if (!saw_reset_hi) begin
                saw_reset_hi = 1'b1;
                if (dut.u_cpu.bus_addr !== 16'hFFFD)
                    $fatal(1, "reset vector high fetch address got %04h expected FFFD",
                           dut.u_cpu.bus_addr);
            end
            7'd7: begin
                if (!saw_first_fetch) begin
                    saw_first_fetch = 1'b1;
                    if (dut.u_cpu.dbg_pc !== 16'h8000)
                        $fatal(1, "first fetch pc got %04h expected 8000", dut.u_cpu.dbg_pc);
                end
                if (dut.cpu_bus_fire)
                    saw_fetch_bus = 1'b1;
                else if (saw_fetch_bus && !saw_first_opcode) begin
                    saw_first_opcode = 1'b1;
                    if (dut.u_cpu.dbg_opcode !== 8'hA9)
                        $fatal(1, "first fetched opcode got %02h expected A9", dut.u_cpu.dbg_opcode);
                end
            end
            default: begin
            end
        endcase
    end
end

always @(posedge clk) begin
    if ((!reset) && (dut.u_cpu.dbg_state >= 7'd5)) begin
        if (dut.cpu_bus_fire) begin
            if ((dut.cpu_addr[15:12] === 4'h0) && (dut.sel_ram !== 1'b1))
                $fatal(1, "%04h did not decode to cpu_ram", dut.cpu_addr);
            if ((dut.cpu_addr[15:12] === 4'h0) && (dut.ram_index !== dut.cpu_addr[10:0]))
                $fatal(1, "ram_index got %03h expected %03h for %04h",
                       dut.ram_index, dut.cpu_addr[10:0], dut.cpu_addr);
            if ((dut.cpu_addr[15:12] === 4'h2) && (dut.sel_ppu !== 1'b1))
                $fatal(1, "%04h did not decode to ppu registers", dut.cpu_addr);
            if (dut.sel_ram) begin
                if (dut.cpu_we) begin
                    ram_wr_total = ram_wr_total + 1;
                    if (dut.cpu_addr[12] === 1'b1) begin
                        ram_mirror_wr = ram_mirror_wr + 1;
                        if (dut.ram_index !== 11'h010)
                            $fatal(1, "mirrored ram write %04h used index %03h expected 010",
                                   dut.cpu_addr, dut.ram_index);
                    end
                    case (dut.cpu_addr)
                        RAM_MIRROR_CELL: begin
                            ram_wr_0010 = ram_wr_0010 + 1;
                            if (dut.cpu_dout !== 8'h5A)
                                $fatal(1, "STA $0010 wrote %02h expected 5A", dut.cpu_dout);
                        end
                        RAM_MIRROR_ALIAS: begin
                            ram_wr_1810 = ram_wr_1810 + 1;
                            if (dut.cpu_dout !== 8'h5A)
                                $fatal(1, "STA $1810 wrote %02h expected 5A", dut.cpu_dout);
                        end
                        default: begin
                            $fatal(1, "unexpected ram write to %04h data %02h",
                                   dut.cpu_addr, dut.cpu_dout);
                        end
                    endcase
                end else begin
                    ram_rd_total = ram_rd_total + 1;
                    if (dut.cpu_addr === RAM_MIRROR_READ) begin
                        ram_rd_1010 = ram_rd_1010 + 1;
                        ram_rd_1010_data = dut.cpu_din;
                    end else begin
                        $fatal(1, "unexpected ram read from %04h", dut.cpu_addr);
                    end
                end
            end
            if ((dut.cpu_addr[14] === 1'b1) && (dut.sel_ram !== 1'b1) && (dut.sel_ppu !== 1'b1)) begin
                if (dut.prg_index >= PRG_SIZE_BYTES)
                    $fatal(1, "prg index %03h out of range for %04h",
                           dut.prg_index, dut.cpu_addr);
                if (dut.prg_index !== dut.cpu_addr[13:0])
                    $fatal(1, "prg index got %03h expected %03h for %04h (nrom-128 mirror)",
                           dut.prg_index, dut.cpu_addr[13:0], dut.cpu_addr);
                if (dut.cpu_we)
                    $fatal(1, "unexpected write to prg at %04h", dut.cpu_addr);
                prg_rd_upper = prg_rd_upper + 1;
                case (dut.cpu_addr)
                    16'hFFFC: begin
                        prg_rd_fffc = prg_rd_fffc + 1;
                        if (dut.cpu_din !== 8'h00)
                            $fatal(1, "read at FFFC got %02h expected 00", dut.cpu_din);
                    end
                    16'hFFFD: begin
                        prg_rd_fffd = prg_rd_fffd + 1;
                        if (dut.cpu_din !== 8'h80)
                            $fatal(1, "read at FFFD got %02h expected 80", dut.cpu_din);
                    end
                    PRG_MIRROR_HIGH: begin
                        prg_rd_c200 = prg_rd_c200 + 1;
                        if (dut.cpu_din !== 8'hA5)
                            $fatal(1, "read at C200 got %02h expected A5", dut.cpu_din);
                    end
                    default: begin
                        $fatal(1, "unexpected prg read from %04h", dut.cpu_addr);
                    end
                endcase
            end
            if ((dut.cpu_addr[14] === 1'b0) && (dut.sel_ram !== 1'b1) && (dut.sel_ppu !== 1'b1)) begin
                if (dut.prg_index !== dut.cpu_addr[13:0])
                    $fatal(1, "prg index got %03h expected %03h for %04h",
                           dut.prg_index, dut.cpu_addr[13:0], dut.cpu_addr);
                prg_rd_lower = prg_rd_lower + 1;
            end
        end
    end
end

always @(posedge clk) begin
    #1;
    if (!reset) begin
        if (frame_done !== 1'b0) begin
            if ((ppu_scanline !== 9'd0) || (ppu_dot !== 9'd0))
                $fatal(1, "frame_done asserted at %0d:%0d, expected 0:0",
                       ppu_scanline, ppu_dot);
        end
        if ((frame_done === 1'b1) && (prev_frame_done !== 1'b1)) begin
            frame_count = frame_count + 1;
            if (have_frame_mark === 1'b1)
                frame_clk_delta = clk_count - frame_mark;
            else
                have_frame_mark = 1'b1;
            frame_mark = clk_count;
            if (frame_count == 1) begin
                check_enable = 1'b1;
                checked_index1 = 0;
                checked_index2 = 0;
                prev_dot = 9'd340;
            end else begin
                check_enable = 1'b0;
            end
        end
        prev_frame_done = frame_done;

        expected_vblank = ((ppu_scanline == 9'd241) && (ppu_dot >= 9'd1)) ||
                          ((ppu_scanline >= 9'd242) && (ppu_scanline <= 9'd260)) ||
                          ((ppu_scanline == 9'd261) && (ppu_dot == 9'd0));
        if (vblank !== expected_vblank)
            $fatal(1, "vblank window mismatch at %0d:%0d got %b expected %b",
                   ppu_scanline, ppu_dot, vblank, expected_vblank);
        if ((vblank === 1'b1) && (prev_vblank !== 1'b1)) begin
            vblank_rise_count = vblank_rise_count + 1;
            rise_line = ppu_scanline;
            rise_dot = ppu_dot;
        end
        if ((vblank !== 1'b1) && (prev_vblank === 1'b1)) begin
            vblank_fall_count = vblank_fall_count + 1;
            fall_line = ppu_scanline;
            fall_dot = ppu_dot;
        end
        prev_vblank = vblank;

        if (nmi_o !== 1'b0)
            $fatal(1, "nmi_o is high with PPUCTRL[7]=0 at %0d:%0d", ppu_scanline, ppu_dot);

        if (pixel_valid === 1'b1) begin
            if ((pixel_x !== ppu_dot[7:0]) || (pixel_y !== ppu_scanline[7:0]))
                $fatal(1, "pixel coordinates got (%0d,%0d) expected (%0d,%0d)",
                       pixel_x, pixel_y, ppu_dot[7:0], ppu_scanline[7:0]);
            if (check_enable === 1'b1) begin
                expected_index = expected_pixel_index(ppu_scanline, ppu_dot);
                if (pixel_index !== expected_index)
                    $fatal(1, "pixel (%0d,%0d) got index %0d expected %0d",
                           pixel_x, pixel_y, pixel_index, expected_index);
                if (ppu_dot !== prev_dot) begin
                    if (expected_index == 4'd1)
                        checked_index1 = checked_index1 + 1;
                    else
                        checked_index2 = checked_index2 + 1;
                end
            end
        end
        prev_dot = ppu_dot;
    end
end

initial begin
    clk = 1'b0;
    reset = 1'b1;
    prev_frame_done = 1'b0;
    prev_vblank = 1'b0;
    check_enable = 1'b0;
    expected_index = 4'd0;
    expected_vblank = 1'b0;
    saw_reset_lo = 1'b0;
    saw_reset_hi = 1'b0;
    saw_first_fetch = 1'b0;
    saw_fetch_bus = 1'b0;
    saw_first_opcode = 1'b0;
    saw_self_loop = 1'b0;
    tail_tests_entered = 1'b0;
    frame_count = 0;
    checked_index1 = 0;
    checked_index2 = 0;
    visible_count = 0;
    ppu_wr_total = 0;
    ppu_wr_ctrl = 0;
    ppu_wr_mask = 0;
    ppu_wr_addr = 0;
    ppu_wr_data = 0;
    ppu_wr_other = 0;
    ppu_rd_total = 0;
    skipped_scroll_dots = 0;
    cpu_bus_count = 0;
    vblank_rise_count = 0;
    vblank_fall_count = 0;
    ram_rd_total = 0;
    ram_wr_total = 0;
    ram_rd_1010 = 0;
    ram_wr_0010 = 0;
    ram_wr_1810 = 0;
    ram_rd_1010_data = 8'h00;
    ram_mirror_wr = 0;
    prg_rd_lower = 0;
    prg_rd_upper = 0;
    prg_rd_fffc = 0;
    prg_rd_fffd = 0;
    prg_rd_c200 = 0;
    rise_line = 9'd0;
    rise_dot = 9'd0;
    fall_line = 9'd0;
    fall_dot = 9'd0;
    prev_dot = 9'd0;
    clk_count = 0;
    frame_mark = 0;
    frame_clk_delta = 0;
    have_frame_mark = 1'b0;
    load_prg_rom;
    load_video_ram;

    repeat (4) @(posedge clk);
    #1;
    if ((ppu_scanline !== 9'd0) || (ppu_dot !== 9'd0))
        $fatal(1, "ppu counter did not start at 0:0, got %0d:%0d", ppu_scanline, ppu_dot);
    if (frame_done !== 1'b0)
        $fatal(1, "frame_done is high during reset");
    if (vblank !== 1'b0)
        $fatal(1, "vblank is high during reset");
    if (nmi_o !== 1'b0)
        $fatal(1, "nmi_o is high during reset");
    if (dut.u_cpu.dbg_state !== 7'd0)
        $fatal(1, "cpu state is %0d during reset, expected 0", dut.u_cpu.dbg_state);
    if (dut.u_ppu.mask_reg !== 8'h00)
        $fatal(1, "ppumask is %02h during reset, expected 00", dut.u_ppu.mask_reg);

    @(negedge clk);
    reset = 1'b0;
    #1;

    wait (frame_count == 2);
    #100;

    if (!saw_reset_lo || !saw_reset_hi || !saw_first_fetch || !saw_first_opcode)
        $fatal(1, "cpu reset sequence incomplete lo=%b hi=%b fetch=%b opcode=%b",
               saw_reset_lo, saw_reset_hi, saw_first_fetch, saw_first_opcode);
    if (prg_mirror_read(16'h8000) !== 8'hA9)
        $fatal(1, "prg image load failed at 8000, got %02h", prg_mirror_read(16'h8000));
    if (prg_mirror_read(16'h805E) !== 8'h80)
        $fatal(1, "prg image load failed at 805E, got %02h", prg_mirror_read(16'h805E));
    if (prg_mirror_read(16'h8064) !== 8'h80)
        $fatal(1, "prg image load failed at 8064, got %02h", prg_mirror_read(16'h8064));
    if (prg_mirror_read(16'h805C) !== 8'h4C)
        $fatal(1, "prg image load failed at 805C, got %02h", prg_mirror_read(16'h805C));
    if (prg_mirror_read(16'h805D) !== 8'h66)
        $fatal(1, "prg image load failed at 805D, got %02h", prg_mirror_read(16'h805D));
    if (prg_mirror_read(16'h8083) !== 8'h4C)
        $fatal(1, "prg image load failed at 8083, got %02h", prg_mirror_read(16'h8083));
    if (prg_mirror_read(16'h8085) !== 8'h80)
        $fatal(1, "prg image load failed at 8085, got %02h", prg_mirror_read(16'h8085));
    if (prg_mirror_read(SELF_LOOP) !== 8'h4C)
        $fatal(1, "prg image load failed at 8086, got %02h", prg_mirror_read(SELF_LOOP));
    if (prg_mirror_read(SELF_LOOP + 16'd2) !== 8'h80)
        $fatal(1, "prg image load failed at 8088, got %02h",
               prg_mirror_read(SELF_LOOP + 16'd2));
    if (prg_mirror_read(PRG_MIRROR_LOW) !== 8'hA5)
        $fatal(1, "prg mirror marker missing at 8200, got %02h",
               prg_mirror_read(PRG_MIRROR_LOW));
    if ((prg_mirror_read(16'hFFFC) !== 8'h00) || (prg_mirror_read(16'hFFFD) !== 8'h80))
        $fatal(1, "prg reset vector got %02h%02h expected 8000",
               prg_mirror_read(16'hFFFD), prg_mirror_read(16'hFFFC));
    if (tail_tests_entered !== 1'b1)
        $fatal(1, "cpu never entered the mirror tests at 8066");
    if ((dut.u_cpu.dbg_pc !== SELF_LOOP) && (dut.u_cpu.dbg_pc !== SELF_LOOP + 16'd1) &&
        (dut.u_cpu.dbg_pc !== SELF_LOOP + 16'd2))
        $fatal(1, "cpu did not settle in the jmp self loop, pc=%04h", dut.u_cpu.dbg_pc);
    if (saw_self_loop !== 1'b1)
        $fatal(1, "cpu never reached the jmp self loop at 8086");
    $display("CPU reset vector FFFC/FFFD -> PC=8000 first opcode=A9 ppustatus=00 self loop=8086 PASS");

    if (cpu_cycle !== cpu_bus_count[31:0])
        $fatal(1, "cpu_cycle %0d does not match bus fire count %0d", cpu_cycle, cpu_bus_count);
    if (ppu_wr_total != 25)
        $fatal(1, "ppu register write count got %0d expected 25", ppu_wr_total);
    if (ppu_wr_ctrl != 2)
        $fatal(1, "ppuctrl write count got %0d expected 2", ppu_wr_ctrl);
    if (ppu_wr_mask != 2)
        $fatal(1, "ppumask write count got %0d expected 2", ppu_wr_mask);
    if (ppu_wr_addr != 10)
        $fatal(1, "ppuaddr write count got %0d expected 10", ppu_wr_addr);
    if (ppu_wr_data != 11)
        $fatal(1, "ppudata write count got %0d expected 11", ppu_wr_data);
    if (ppu_wr_other != 0)
        $fatal(1, "unexpected writes to other ppu registers: %0d", ppu_wr_other);
    if (ppu_rd_total != 1)
        $fatal(1, "ppu register read count got %0d expected 1", ppu_rd_total);
    $display("BUS cpu_cycles=%0d ppu_writes=%0d (ctrl=%0d mask=%0d addr=%0d data=%0d) ppu_reads=%0d PASS",
             cpu_cycle, ppu_wr_total, ppu_wr_ctrl, ppu_wr_mask, ppu_wr_addr, ppu_wr_data, ppu_rd_total);

    if (skipped_scroll_dots != (ppu_wr_total + ppu_rd_total))
        $fatal(1, "skipped scroll dots got %0d expected %0d",
               skipped_scroll_dots, ppu_wr_total + ppu_rd_total);
    $display("SYNC cpu ce and ppu ce in-phase, register-access dots skipped=%0d PASS",
             skipped_scroll_dots);

    if (ram_wr_total != 2)
        $fatal(1, "ram write count got %0d expected 2", ram_wr_total);
    if (ram_rd_total != 1)
        $fatal(1, "ram read count got %0d expected 1", ram_rd_total);
    if (ram_wr_0010 != 1)
        $fatal(1, "STA $0010 executed %0d times expected 1", ram_wr_0010);
    if (ram_wr_1810 != 1)
        $fatal(1, "STA $1810 executed %0d times expected 1", ram_wr_1810);
    if (ram_rd_1010 != 1)
        $fatal(1, "LDA $1010 executed %0d times expected 1", ram_rd_1010);
    if (ram_rd_1010_data !== 8'h5A)
        $fatal(1, "LDA $1010 read %02h expected 5A", ram_rd_1010_data);
    if (dut.cpu_ram[16'h010] !== 8'h5A)
        $fatal(1, "cpu_ram[0010] is %02h expected 5A", dut.cpu_ram[16'h010]);
    if (ram_mirror_read(RAM_MIRROR_ALIAS) !== 8'h5A)
        $fatal(1, "ram mirror cell for %04h is %02h expected 5A",
               RAM_MIRROR_ALIAS, ram_mirror_read(RAM_MIRROR_ALIAS));
    $display("RAM $0000-$1FFF mirror: STA $0010/$1810 -> cell 010=%02h, LDA $1010=%02h (wr=%0d rd=%0d aliased=%0d) PASS",
             dut.cpu_ram[16'h010], ram_rd_1010_data, ram_wr_total, ram_rd_total, ram_mirror_wr);

    if (prg_rd_lower < 90)
        $fatal(1, "prg reads from $8000-$BFFF got %0d, expected at least 90", prg_rd_lower);
    if (prg_rd_upper != 3)
        $fatal(1, "prg reads from $C000-$FFFF got %0d expected 3", prg_rd_upper);
    if (prg_rd_fffc != 1)
        $fatal(1, "read at $FFFC got %0d times expected 1", prg_rd_fffc);
    if (prg_rd_fffd != 1)
        $fatal(1, "read at $FFFD got %0d times expected 1", prg_rd_fffd);
    if (prg_rd_c200 != 1)
        $fatal(1, "read at $C200 got %0d times expected 1", prg_rd_c200);
    if (prg_mirror_read(PRG_MIRROR_HIGH) !== 8'hA5)
        $fatal(1, "prg mirror cell for %04x is %02h expected A5",
               PRG_MIRROR_HIGH, prg_mirror_read(PRG_MIRROR_HIGH));
    if (prg_rd_lower + prg_rd_upper + ram_rd_total + ram_wr_total +
        ppu_wr_total + ppu_rd_total + 5 != cpu_bus_count)
        $fatal(1, "bus cycle accounting does not close: lower=%0d upper=%0d ram_rd=%0d ram_wr=%0d ppu_wr=%0d ppu_rd=%0d reset_dummy=5 total=%0d of %0d",
               prg_rd_lower, prg_rd_upper, ram_rd_total, ram_wr_total,
               ppu_wr_total, ppu_rd_total, cpu_bus_count);
    $display("PRG NROM-128 %0d bytes: $8000-$BFFF and $C000-$FFFF both index 0000-%04x, lower reads=%0d upper reads=%0d (FFFC=%02h FFFD=%02h C200=%02h) PASS",
             PRG_SIZE_BYTES, PRG_SIZE_BYTES - 1, prg_rd_lower, prg_rd_upper,
             prg_mirror_read(16'hFFFC), prg_mirror_read(16'hFFFD),
             prg_mirror_read(PRG_MIRROR_HIGH));

    if (dut.u_ppu.control_reg !== 8'h00)
        $fatal(1, "ppuctrl is %02h after the cpu program, expected 00", dut.u_ppu.control_reg);
    if (dut.u_ppu.mask_reg !== 8'h0A)
        $fatal(1, "ppumask is %02h after the cpu program, expected 0A", dut.u_ppu.mask_reg);
    if (dut.u_ppu.v_addr !== 15'h0000)
        $fatal(1, "ppu v is %04h after the cpu program, expected 0000", dut.u_ppu.v_addr);
    if (dut.u_ppu.temp_addr !== 15'h0000)
        $fatal(1, "ppu t is %04h after the cpu program, expected 0000", dut.u_ppu.temp_addr);
    if (dut.u_ppu.fine_x !== 3'd0)
        $fatal(1, "ppu fine x is %0d after the cpu program, expected 0", dut.u_ppu.fine_x);
    if (dut.u_ppu.write_toggle !== 1'b0)
        $fatal(1, "ppu write toggle is %b after the cpu program, expected 0",
               dut.u_ppu.write_toggle);
    if (dut.u_ppu.chr_ram[0] !== 8'hFF)
        $fatal(1, "chr[0] is %02h, the cpu ppudata write did not land", dut.u_ppu.chr_ram[0]);
    if (dut.u_ppu.chr_ram[7] !== 8'hFF)
        $fatal(1, "chr[7] is %02h, the cpu ppudata loop did not run 8 times", dut.u_ppu.chr_ram[7]);
    if (dut.u_ppu.chr_ram[32] !== 8'h00)
        $fatal(1, "chr[32] is %02h, the tile 2 low plane prefill is wrong", dut.u_ppu.chr_ram[32]);
    if (dut.u_ppu.chr_ram[40] !== 8'hFF)
        $fatal(1, "chr[40] is %02h, the tile 2 high plane prefill is wrong", dut.u_ppu.chr_ram[40]);
    if (dut.u_ppu.nametable_ram[0] !== 8'h00)
        $fatal(1, "nametable[0] is %02h, expected 00", dut.u_ppu.nametable_ram[0]);
    if (dut.u_ppu.nametable_ram[1] !== 8'h02)
        $fatal(1, "nametable[1] is %02h, the cpu nametable write did not land",
               dut.u_ppu.nametable_ram[1]);
    if (dut.u_ppu.nametable_ram[2] !== 8'h00)
        $fatal(1, "nametable[2] is %02h, expected 00", dut.u_ppu.nametable_ram[2]);
    if (dut.u_ppu.palette_ram[0] !== 8'h0F)
        $fatal(1, "palette[0] is %02h, expected 0F", dut.u_ppu.palette_ram[0]);
    if (dut.u_ppu.palette_ram[1] !== 8'h21)
        $fatal(1, "palette[1] is %02h, the cpu palette write did not land", dut.u_ppu.palette_ram[1]);
    if (dut.u_ppu.palette_ram[2] !== 8'h32)
        $fatal(1, "palette[2] is %02h, the cpu palette write did not land", dut.u_ppu.palette_ram[2]);
    if (dut.u_ppu.palette_ram[3] !== 8'h00)
        $fatal(1, "palette[3] is %02h, expected 00", dut.u_ppu.palette_ram[3]);
    $display("PPUSTATE cpu-driven ctrl=00 mask=0A v=0000 t=0000 chr[0:7]=FF nt[0..2]=00,02,00 pal[0..3]=0F,21,32,00 PASS");

    if (frame_count != 2)
        $fatal(1, "frame_done count got %0d expected 2", frame_count);
    if (vblank_rise_count < 2)
        $fatal(1, "vblank rise count got %0d, expected at least 2", vblank_rise_count);
    if (vblank_rise_count != vblank_fall_count)
        $fatal(1, "vblank rise %0d does not match fall %0d",
               vblank_rise_count, vblank_fall_count);
    if ((rise_line !== 9'd241) || (rise_dot !== 9'd1))
        $fatal(1, "vblank rise at %0d:%0d, expected 241:1", rise_line, rise_dot);
    if ((fall_line !== 9'd261) || (fall_dot !== 9'd1))
        $fatal(1, "vblank fall at %0d:%0d, expected 261:1", fall_line, fall_dot);
    if (frame_clk_delta != 357368)
        $fatal(1, "frame period got %0d clk expected 357368 (262x341x4)", frame_clk_delta);
    $display("TIMING frame_done=%0d frame_period=%0dclk vblank_window=241:1..261:0 rise=%0d:%0d fall=%0d:%0d PASS",
             frame_count, frame_clk_delta, rise_line, rise_dot, fall_line, fall_dot);

    visible_count = checked_index1 + checked_index2;
    if (visible_count != 61440)
        $fatal(1, "checked visible pixel count got %0d expected 61440 (one full frame)",
               visible_count);
    if (checked_index1 != 61376)
        $fatal(1, "palette index 1 pixel count got %0d expected 61376", checked_index1);
    if (checked_index2 != 64)
        $fatal(1, "palette index 2 pixel count got %0d expected 64", checked_index2);
    $display("BACKGROUND full frame pixels=%0d index1=%0d index2=%0d PASS",
             visible_count, checked_index1, checked_index2);

    $display("PASS nes_system_v0");
    $finish;
end

initial begin
    #20000000;
    $fatal(1, "global timeout");
end

endmodule
