`timescale 1ns/1ps

module tb_nes_system_v0_nmi;

localparam PRG_SIZE_BYTES = 16384;
localparam PRG_INDEX_BITS = $clog2(PRG_SIZE_BYTES);
localparam [14:0] PRG_WINDOW_MASK = 15'h7FFF >> (15 - PRG_INDEX_BITS);
localparam [14:0] PRG_RESET_VECTOR_IDX = 16'hFFFC & PRG_WINDOW_MASK;
localparam [14:0] PRG_RESET_VECTOR_HI_IDX = 16'hFFFD & PRG_WINDOW_MASK;
localparam [14:0] PRG_NMI_VECTOR_IDX = 16'hFFFA & PRG_WINDOW_MASK;
localparam [14:0] PRG_NMI_VECTOR_HI_IDX = 16'hFFFB & PRG_WINDOW_MASK;
localparam [15:0] POLL_LOOP = 16'h800C;
localparam [15:0] MAIN_LOOP = 16'h8016;
localparam [15:0] NMI_HANDLER = 16'h8100;
localparam [15:0] NMI_COUNTER = 16'h0010;
localparam [15:0] STACK_PC_HI = 16'h01FC;
localparam [15:0] STACK_PC_LO = 16'h01FB;
localparam [15:0] STACK_P = 16'h01FA;
localparam NMI_TO_FRAME_DONE_CLK = 28640;
localparam FRAME_PERIOD_CLK = 357368;
localparam NMI_PENDING_MAX_CLK = 96;

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
reg prev_nmi_o;
reg saw_reset_lo;
reg saw_reset_hi;
reg saw_first_fetch;
reg saw_fetch_bus;
reg saw_first_opcode;
reg saw_ctrl7;
reg handler_active;
reg nmi_pending_seen;
reg have_frame_mark;
reg have_nmi_mark;
reg nmi_vblank_fall_seen;
reg expected_vblank;
reg expected_nmi;
reg [7:0] ctrl7_at_poll_hit;

integer frame_count;
integer clk_count;
integer frame_mark;
integer frame_clk_delta;
integer nmi_mark;
integer nmi_to_frame_done;
integer cpu_bus_count;
integer ppu_wr_total;
integer ppu_wr_ctrl;
integer ppu_wr_mask;
integer ppu_wr_other;
integer ppu_rd_total;
integer ppu_rd_vblank_set;
integer poll_iterations;
integer prg_rd_upper;
integer prg_rd_fffc;
integer prg_rd_fffd;
integer prg_rd_fffa;
integer prg_rd_fffb;
integer nmi_entry_count;
integer nmi_handler_count;
integer nmi_push_pc_hi;
integer nmi_push_pc_lo;
integer nmi_push_p;
integer nmi_counter_wr_total;
integer nmi_counter_wr_nonzero;
integer nmi_pending_clk;
integer nmi_rise_count;
integer nmi_rise_line;
integer nmi_rise_dot;
integer vblank_rise_count;
integer vblank_fall_count;
integer nmi_fall_line;
integer nmi_fall_dot;
integer clear_index;

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
        dut.prg_rom[PRG_NMI_VECTOR_IDX] = 8'h00;
        dut.prg_rom[PRG_NMI_VECTOR_HI_IDX] = 8'h81;
        put_prg_byte(16'h8000, 8'hA9);
        put_prg_byte(16'h8001, 8'h00);
        put_prg_byte(16'h8002, 8'h58);
        put_prg_byte(16'h8003, 8'h8D);
        put_prg_byte(16'h8004, 8'h00);
        put_prg_byte(16'h8005, 8'h20);
        put_prg_byte(16'h8006, 8'h8D);
        put_prg_byte(16'h8007, 8'h01);
        put_prg_byte(16'h8008, 8'h20);
        put_prg_byte(16'h8009, 8'h8D);
        put_prg_byte(16'h800A, 8'h10);
        put_prg_byte(16'h800B, 8'h00);
        put_prg_byte(16'h800C, 8'hAD);
        put_prg_byte(16'h800D, 8'h02);
        put_prg_byte(16'h800E, 8'h20);
        put_prg_byte(16'h800F, 8'h10);
        put_prg_byte(16'h8010, 8'hFB);
        put_prg_byte(16'h8011, 8'hA9);
        put_prg_byte(16'h8012, 8'h80);
        put_prg_byte(16'h8013, 8'h8D);
        put_prg_byte(16'h8014, 8'h00);
        put_prg_byte(16'h8015, 8'h20);
        put_prg_byte(16'h8016, 8'h4C);
        put_prg_byte(16'h8017, 8'h16);
        put_prg_byte(16'h8018, 8'h80);
        put_prg_byte(NMI_HANDLER, 8'hAD);
        put_prg_byte(NMI_HANDLER + 16'd1, 8'h10);
        put_prg_byte(NMI_HANDLER + 16'd2, 8'h00);
        put_prg_byte(NMI_HANDLER + 16'd3, 8'h18);
        put_prg_byte(NMI_HANDLER + 16'd4, 8'h69);
        put_prg_byte(NMI_HANDLER + 16'd5, 8'h01);
        put_prg_byte(NMI_HANDLER + 16'd6, 8'h8D);
        put_prg_byte(NMI_HANDLER + 16'd7, 8'h10);
        put_prg_byte(NMI_HANDLER + 16'd8, 8'h00);
        put_prg_byte(NMI_HANDLER + 16'd9, 8'h40);
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
                    default: ppu_wr_other = ppu_wr_other + 1;
                endcase
                if ((dut.u_ppu.reg_addr === 3'd0) && (dut.u_ppu.reg_din[7] === 1'b1))
                    saw_ctrl7 = 1'b1;
            end else begin
                ppu_rd_total = ppu_rd_total + 1;
                if (dut.u_ppu.reg_dout[7] === 1'b1) begin
                    ppu_rd_vblank_set = ppu_rd_vblank_set + 1;
                    ctrl7_at_poll_hit = dut.u_ppu.control_reg;
                end
            end
        end
        if (dut.cpu_bus_fire) begin
            cpu_bus_count = cpu_bus_count + 1;
            if (!dut.ce_cpu)
                $fatal(1, "cpu bus fire without ce_cpu at div_phase=%0d", dut.div_phase);
            if (!dut.ce_ppu)
                $fatal(1, "cpu bus fire is not aligned with a ppu ce at div_phase=%0d", dut.div_phase);
            if (dut.u_cpu.dbg_state >= 7'd5) begin
                if ((dut.sel_ram !== 1'b1) && (dut.sel_ppu !== 1'b1)) begin
                    if (dut.prg_index >= PRG_SIZE_BYTES)
                        $fatal(1, "prg index %03h out of range for %04h",
                               dut.prg_index, dut.u_cpu.bus_addr);
                    if (dut.prg_index !== dut.u_cpu.bus_addr[13:0])
                        $fatal(1, "prg index got %03h expected %03h for %04h (nrom-128 mirror)",
                               dut.prg_index, dut.u_cpu.bus_addr[13:0], dut.u_cpu.bus_addr);
                    if (dut.u_cpu.bus_addr[14] === 1'b1) begin
                        prg_rd_upper = prg_rd_upper + 1;
                        case (dut.u_cpu.bus_addr)
                            16'hFFFA: begin
                                prg_rd_fffa = prg_rd_fffa + 1;
                                if (dut.cpu_din !== 8'h00)
                                    $fatal(1, "nmi vector low got %02h expected 00", dut.cpu_din);
                            end
                            16'hFFFB: begin
                                prg_rd_fffb = prg_rd_fffb + 1;
                                if (dut.cpu_din !== 8'h81)
                                    $fatal(1, "nmi vector high got %02h expected 81", dut.cpu_din);
                            end
                            16'hFFFC: begin
                                prg_rd_fffc = prg_rd_fffc + 1;
                                if (dut.cpu_din !== 8'h00)
                                    $fatal(1, "reset vector low got %02h expected 00", dut.cpu_din);
                            end
                            16'hFFFD: begin
                                prg_rd_fffd = prg_rd_fffd + 1;
                                if (dut.cpu_din !== 8'h80)
                                    $fatal(1, "reset vector high got %02h expected 80", dut.cpu_din);
                            end
                            default: begin
                                $fatal(1, "unexpected prg read from %04h", dut.u_cpu.bus_addr);
                            end
                        endcase
                    end
                end
                if ((dut.sel_ram === 1'b1) && (dut.u_cpu.bus_we === 1'b1)) begin
                    if (dut.ram_index !== dut.u_cpu.bus_addr[10:0])
                        $fatal(1, "ram_index got %03h expected %03h for %04h",
                               dut.ram_index, dut.u_cpu.bus_addr[10:0], dut.u_cpu.bus_addr);
                    case (dut.u_cpu.bus_addr)
                        NMI_COUNTER: begin
                            nmi_counter_wr_total = nmi_counter_wr_total + 1;
                            if (dut.u_cpu.bus_dout !== 8'h00)
                                nmi_counter_wr_nonzero = nmi_counter_wr_nonzero + 1;
                        end
                        STACK_PC_HI: begin
                            nmi_push_pc_hi = nmi_push_pc_hi + 1;
                            if (dut.u_cpu.bus_dout !== MAIN_LOOP[15:8])
                                $fatal(1, "nmi push pc high got %02h expected %02h",
                                       dut.u_cpu.bus_dout, MAIN_LOOP[15:8]);
                        end
                        STACK_PC_LO: begin
                            nmi_push_pc_lo = nmi_push_pc_lo + 1;
                            if (dut.u_cpu.bus_dout !== MAIN_LOOP[7:0])
                                $fatal(1, "nmi push pc low got %02h expected %02h",
                                       dut.u_cpu.bus_dout, MAIN_LOOP[7:0]);
                        end
                        STACK_P: begin
                            nmi_push_p = nmi_push_p + 1;
                            if (dut.u_cpu.bus_dout !== (dut.u_cpu.dbg_p | 8'h20))
                                $fatal(1, "nmi push p got %02h, expected p with b5 forced (%02h)",
                                       dut.u_cpu.bus_dout, (dut.u_cpu.dbg_p | 8'h20));
                        end
                        default: begin
                            $fatal(1, "unexpected ram write to %04h data %02h",
                                   dut.u_cpu.bus_addr, dut.u_cpu.bus_dout);
                        end
                    endcase
                end
            end
        end
        if (dut.u_cpu.dbg_illegal !== 1'b0)
            $fatal(1, "dbg_illegal asserted, pc=%04h state=%0d opcode=%02h",
                   dut.u_cpu.dbg_pc, dut.u_cpu.dbg_state, dut.u_cpu.dbg_opcode);
        if (dut.u_cpu.dbg_nmi_pending === 1'b1) begin
            nmi_pending_clk = nmi_pending_clk + 1;
            nmi_pending_seen = 1'b1;
        end
        if (dut.cpu_bus_fire && (dut.u_cpu.dbg_state === 7'd7)) begin
            if (dut.u_cpu.dbg_pc === NMI_HANDLER) begin
                if (handler_active !== 1'b1) begin
                    handler_active = 1'b1;
                    nmi_handler_count = nmi_handler_count + 1;
                end
            end
            if (dut.u_cpu.dbg_pc === MAIN_LOOP) begin
                handler_active = 1'b0;
                if (dut.u_cpu.dbg_p[2] !== 1'b0)
                    $fatal(1, "i flag is %b in the main loop, the program runs with cli",
                           dut.u_cpu.dbg_p[2]);
            end
            if (dut.u_cpu.dbg_pc === POLL_LOOP)
                poll_iterations = poll_iterations + 1;
        end
        if (dut.cpu_bus_fire && (dut.u_cpu.dbg_state === 7'd42))
            handler_active = 1'b0;
        if (dut.cpu_bus_fire && (handler_active === 1'b1)) begin
            if (dut.u_cpu.dbg_sp !== 8'hFA)
                $fatal(1, "sp is %02h inside the nmi handler, expected FA", dut.u_cpu.dbg_sp);
            if (dut.u_cpu.dbg_nmi_pending !== 1'b0)
                $fatal(1, "dbg_nmi_pending is still set inside the nmi handler");
            if (dut.u_cpu.dbg_p[2] !== 1'b1)
                $fatal(1, "i flag is clear inside the nmi handler, p=%02h", dut.u_cpu.dbg_p);
        end
        if (saw_first_fetch === 1'b1) begin
            if ((dut.u_cpu.dbg_pc[15:8] !== 8'h80) && (dut.u_cpu.dbg_pc[15:8] !== 8'h81))
                $fatal(1, "cpu pc left the prg program area, pc=%04h", dut.u_cpu.dbg_pc);
        end
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
            if ((have_nmi_mark === 1'b1) && (frame_count == 2))
                nmi_to_frame_done = clk_count - nmi_mark;
        end
        prev_frame_done = frame_done;

        expected_vblank = ((ppu_scanline == 9'd241) && (ppu_dot >= 9'd1)) ||
                          ((ppu_scanline >= 9'd242) && (ppu_scanline <= 9'd260)) ||
                          ((ppu_scanline == 9'd261) && (ppu_dot == 9'd0));
        if ((vblank === 1'b1) && (expected_vblank !== 1'b1))
            $fatal(1, "vblank is high outside the window at %0d:%0d", ppu_scanline, ppu_dot);
        if ((vblank === 1'b1) && (prev_vblank !== 1'b1)) begin
            vblank_rise_count = vblank_rise_count + 1;
            if ((ppu_scanline !== 9'd241) || (ppu_dot !== 9'd1))
                $fatal(1, "vblank rose at %0d:%0d, expected 241:1", ppu_scanline, ppu_dot);
        end
        if ((vblank !== 1'b1) && (prev_vblank === 1'b1)) begin
            vblank_fall_count = vblank_fall_count + 1;
            if ((have_nmi_mark === 1'b1) && (nmi_vblank_fall_seen !== 1'b1)) begin
                nmi_vblank_fall_seen = 1'b1;
                nmi_fall_line = ppu_scanline;
                nmi_fall_dot = ppu_dot;
            end
        end
        prev_vblank = vblank;

        expected_nmi = vblank & dut.u_ppu.control_reg[7];
        if (nmi_o !== expected_nmi)
            $fatal(1, "nmi_o got %b expected %b at %0d:%0d with ppuctrl=%02h",
                   nmi_o, expected_nmi, ppu_scanline, ppu_dot, dut.u_ppu.control_reg);
        if ((nmi_o === 1'b1) && (prev_nmi_o !== 1'b1)) begin
            nmi_rise_count = nmi_rise_count + 1;
            nmi_rise_line = ppu_scanline;
            nmi_rise_dot = ppu_dot;
            nmi_mark = clk_count;
            have_nmi_mark = 1'b1;
        end
        prev_nmi_o = nmi_o;

        if (pixel_index !== 4'h0)
            $fatal(1, "pixel_index is %0d at %0d:%0d with ppumask=%02h, expected 0",
                   pixel_index, ppu_scanline, ppu_dot, dut.u_ppu.mask_reg);
        if (pixel_valid === 1'b1) begin
            if ((pixel_x !== ppu_dot[7:0]) || (pixel_y !== ppu_scanline[7:0]))
                $fatal(1, "pixel coordinates got (%0d,%0d) expected (%0d,%0d)",
                       pixel_x, pixel_y, ppu_dot[7:0], ppu_scanline[7:0]);
        end
    end
end

initial begin
    clk = 1'b0;
    reset = 1'b1;
    prev_frame_done = 1'b0;
    prev_vblank = 1'b0;
    prev_nmi_o = 1'b0;
    saw_reset_lo = 1'b0;
    saw_reset_hi = 1'b0;
    saw_first_fetch = 1'b0;
    saw_fetch_bus = 1'b0;
    saw_first_opcode = 1'b0;
    saw_ctrl7 = 1'b0;
    handler_active = 1'b0;
    nmi_pending_seen = 1'b0;
    have_frame_mark = 1'b0;
    have_nmi_mark = 1'b0;
    nmi_vblank_fall_seen = 1'b0;
    expected_vblank = 1'b0;
    expected_nmi = 1'b0;
    ctrl7_at_poll_hit = 8'h00;
    frame_count = 0;
    clk_count = 0;
    frame_mark = 0;
    frame_clk_delta = 0;
    nmi_mark = 0;
    nmi_to_frame_done = 0;
    cpu_bus_count = 0;
    ppu_wr_total = 0;
    ppu_wr_ctrl = 0;
    ppu_wr_mask = 0;
    ppu_wr_other = 0;
    ppu_rd_total = 0;
    ppu_rd_vblank_set = 0;
    poll_iterations = 0;
    prg_rd_upper = 0;
    prg_rd_fffc = 0;
    prg_rd_fffd = 0;
    prg_rd_fffa = 0;
    prg_rd_fffb = 0;
    nmi_entry_count = 0;
    nmi_handler_count = 0;
    nmi_push_pc_hi = 0;
    nmi_push_pc_lo = 0;
    nmi_push_p = 0;
    nmi_counter_wr_total = 0;
    nmi_counter_wr_nonzero = 0;
    nmi_pending_clk = 0;
    nmi_rise_count = 0;
    nmi_rise_line = 0;
    nmi_rise_dot = 0;
    vblank_rise_count = 0;
    vblank_fall_count = 0;
    nmi_fall_line = 0;
    nmi_fall_dot = 0;
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
    if (prg_mirror_read(16'h8002) !== 8'h58)
        $fatal(1, "prg image load failed at 8002, got %02h", prg_mirror_read(16'h8002));
    if (prg_mirror_read(16'h800F) !== 8'h10)
        $fatal(1, "prg image load failed at 800F, got %02h", prg_mirror_read(16'h800F));
    if (prg_mirror_read(16'h8010) !== 8'hFB)
        $fatal(1, "prg image load failed at 8010, got %02h", prg_mirror_read(16'h8010));
    if (prg_mirror_read(MAIN_LOOP) !== 8'h4C)
        $fatal(1, "prg image load failed at 8016, got %02h", prg_mirror_read(MAIN_LOOP));
    if (prg_mirror_read(NMI_HANDLER) !== 8'hAD)
        $fatal(1, "prg image load failed at 8100, got %02h", prg_mirror_read(NMI_HANDLER));
    if (prg_mirror_read(NMI_HANDLER + 16'd9) !== 8'h40)
        $fatal(1, "prg image load failed at 8109, got %02h",
               prg_mirror_read(NMI_HANDLER + 16'd9));
    if ((prg_mirror_read(16'hFFFA) !== 8'h00) || (prg_mirror_read(16'hFFFB) !== 8'h81))
        $fatal(1, "nmi vector got %02h%02h expected 8100",
               prg_mirror_read(16'hFFFB), prg_mirror_read(16'hFFFA));
    if ((prg_rd_fffc != 1) || (prg_rd_fffd != 1))
        $fatal(1, "reset vector fetch counts got %0d/%0d expected 1/1", prg_rd_fffc, prg_rd_fffd);
    if ((prg_rd_fffa < 1) || (prg_rd_fffb != prg_rd_fffa))
        $fatal(1, "nmi vector fetch counts got %0d/%0d, expected one pair per entry",
               prg_rd_fffa, prg_rd_fffb);
    nmi_entry_count = prg_rd_fffa;
    if (prg_rd_upper != (2 + (2 * nmi_entry_count)))
        $fatal(1, "prg reads from the mirrored window got %0d expected %0d",
               prg_rd_upper, 2 + (2 * nmi_entry_count));
    $display("PRG nrom-128 %0d bytes, reset vector FFFC/FFFD=%02h%02h, nmi vector FFFA/FFFB=%02h%02h, handler=%04h PASS",
             PRG_SIZE_BYTES, prg_mirror_read(16'hFFFD), prg_mirror_read(16'hFFFC),
             prg_mirror_read(16'hFFFB), prg_mirror_read(16'hFFFA), NMI_HANDLER);
    $display("MIRROR every vector is fetched through $C000-$FFFF, upper window reads=%0d, all indexed as addr[13:0] PASS",
             prg_rd_upper);

    if (ppu_wr_total != 3)
        $fatal(1, "ppu register write count got %0d expected 3", ppu_wr_total);
    if (ppu_wr_ctrl != 2)
        $fatal(1, "ppuctrl write count got %0d expected 2", ppu_wr_ctrl);
    if (ppu_wr_mask != 1)
        $fatal(1, "ppumask write count got %0d expected 1", ppu_wr_mask);
    if (ppu_wr_other != 0)
        $fatal(1, "unexpected writes to other ppu registers: %0d", ppu_wr_other);
    if (ppu_rd_total != poll_iterations)
        $fatal(1, "ppu register read count %0d does not match %0d poll iterations",
               ppu_rd_total, poll_iterations);
    if (ppu_rd_total < 1)
        $fatal(1, "the program never polled ppustatus");
    if (ppu_rd_vblank_set != 1)
        $fatal(1, "ppustatus read with vblank set got %0d times expected 1", ppu_rd_vblank_set);
    if (ctrl7_at_poll_hit !== 8'h00)
        $fatal(1, "the poll loop saw vblank with ppuctrl=%02h, nmi had to be off",
               ctrl7_at_poll_hit);
    if (saw_ctrl7 !== 1'b1)
        $fatal(1, "the program never enabled ppuctrl bit 7");
    if (dut.u_ppu.control_reg !== 8'h80)
        $fatal(1, "ppuctrl is %02h at the end, expected 80", dut.u_ppu.control_reg);
    $display("POLL ppustatus reads=%0d, exactly %0d with vblank set while ppuctrl[7]=0, then ppuctrl=80 PASS",
             ppu_rd_total, ppu_rd_vblank_set);

    if (nmi_rise_count != 1)
        $fatal(1, "nmi_o rising edge count got %0d expected 1", nmi_rise_count);
    if ((nmi_rise_line !== 9'd241) || (nmi_rise_dot !== 9'd1))
        $fatal(1, "nmi_o rose at %0d:%0d, expected 241:1", nmi_rise_line, nmi_rise_dot);
    if (nmi_handler_count < 1)
        $fatal(1, "the nmi handler never executed");
    if (nmi_handler_count != nmi_entry_count)
        $fatal(1, "nmi handler executions %0d do not match %0d entries",
               nmi_handler_count, nmi_entry_count);
    if (nmi_push_pc_hi != nmi_entry_count)
        $fatal(1, "nmi pc-high pushes %0d do not match %0d entries",
               nmi_push_pc_hi, nmi_entry_count);
    if (nmi_push_pc_lo != nmi_entry_count)
        $fatal(1, "nmi pc-low pushes %0d do not match %0d entries",
               nmi_push_pc_lo, nmi_entry_count);
    if (nmi_push_p != nmi_entry_count)
        $fatal(1, "nmi p pushes %0d do not match %0d entries", nmi_push_p, nmi_entry_count);
    if (nmi_counter_wr_nonzero != nmi_entry_count)
        $fatal(1, "nmi counter increments %0d do not match %0d entries",
               nmi_counter_wr_nonzero, nmi_entry_count);
    if (nmi_counter_wr_total != (1 + nmi_entry_count))
        $fatal(1, "ram %04h write count got %0d expected %0d (one program store plus one per handler run)",
               NMI_COUNTER, nmi_counter_wr_total, 1 + nmi_entry_count);
    if (dut.cpu_ram[16'h010] !== nmi_entry_count[7:0])
        $fatal(1, "cpu_ram[0010] is %02h expected %02h", dut.cpu_ram[16'h010], nmi_entry_count[7:0]);
    if (ram_mirror_read(16'h1810) !== nmi_entry_count[7:0])
        $fatal(1, "ram mirror cell for 1810 is %02h expected %02h",
               ram_mirror_read(16'h1810), nmi_entry_count[7:0]);
    $display("NMI entries=%0d, handler=%04h ran %0d times, pushed pc=%02h%02h to 01FC/01FB and p with b5 set to 01FA, ram[0010]=%02h PASS",
             nmi_entry_count, NMI_HANDLER, nmi_handler_count,
             MAIN_LOOP[15:8], MAIN_LOOP[7:0], dut.cpu_ram[16'h010]);

    if (nmi_pending_seen !== 1'b1)
        $fatal(1, "dbg_nmi_pending never went high, the nmi was never latched");
    if (nmi_pending_clk > NMI_PENDING_MAX_CLK)
        $fatal(1, "dbg_nmi_pending stayed high for %0d clk, it must clear inside the 7 cycle entry sequence",
               nmi_pending_clk);
    if (dut.u_cpu.dbg_nmi_pending !== 1'b0)
        $fatal(1, "dbg_nmi_pending is still set at the end of the run");
    if (dut.u_cpu.dbg_sp !== 8'hFD)
        $fatal(1, "sp is %02h after the nmi handler returned, expected FD", dut.u_cpu.dbg_sp);
    if (dut.u_cpu.dbg_p[2] !== 1'b0)
        $fatal(1, "i flag is %b after the nmi handler returned, expected 0 (rti restores the pushed p)",
               dut.u_cpu.dbg_p[2]);
    $display("NMI dbg_nmi_pending latched then cleared in %0d clk, 0 inside the handler and at the end, sp back to FD, i flag set on entry and restored by rti PASS",
             nmi_pending_clk);

    if (frame_count != 2)
        $fatal(1, "frame_done count got %0d expected 2", frame_count);
    if (frame_clk_delta != FRAME_PERIOD_CLK)
        $fatal(1, "frame period got %0d clk expected %0d", frame_clk_delta, FRAME_PERIOD_CLK);
    if (nmi_to_frame_done != NMI_TO_FRAME_DONE_CLK)
        $fatal(1, "clk from the nmi edge to the next frame_done got %0d expected %0d",
               nmi_to_frame_done, NMI_TO_FRAME_DONE_CLK);
    if (vblank_rise_count < 1)
        $fatal(1, "vblank never rose");
    if (vblank_rise_count != vblank_fall_count)
        $fatal(1, "vblank rise %0d does not match fall %0d", vblank_rise_count, vblank_fall_count);
    if (nmi_vblank_fall_seen !== 1'b1)
        $fatal(1, "the vblank window that raised the nmi never fell");
    if ((nmi_fall_line !== 9'd261) || (nmi_fall_dot !== 9'd1))
        $fatal(1, "the nmi vblank window fell at %0d:%0d, expected 261:1", nmi_fall_line, nmi_fall_dot);
    $display("TIMING frame period=%0dclk, nmi edge at %0d:%0d, nmi edge to frame_done=%0dclk (21x341x4-4) PASS",
             frame_clk_delta, nmi_rise_line, nmi_rise_dot, nmi_to_frame_done);

    if (cpu_cycle !== cpu_bus_count[31:0])
        $fatal(1, "cpu_cycle %0d does not match bus fire count %0d", cpu_cycle, cpu_bus_count);
    $display("BUS cpu_cycles=%0d ppu_writes=%0d (ctrl=%0d mask=%0d) ppu_reads=%0d PASS",
             cpu_cycle, ppu_wr_total, ppu_wr_ctrl, ppu_wr_mask, ppu_rd_total);

    $display("PASS nes_system_v0_nmi");
    $finish;
end

initial begin
    #20000000;
    $fatal(1, "global timeout");
end

endmodule
