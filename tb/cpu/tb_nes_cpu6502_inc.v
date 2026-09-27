`timescale 1ns/1ps

module tb_nes_cpu6502_inc;

localparam MAXTR = 256;
localparam MARK_ADDR = 16'h7FF0;
localparam START_ADDR = 16'h0400;

reg clk;
reg reset;
reg ce;
reg bus_ready;
reg [7:0] bus_din;
wire bus_hold;
wire nmi_i;
wire irq_i;
wire bus_req;
wire bus_fire;
wire [31:0] cpu_cycle;
wire [3:0] cpu_cycle_phase;
wire [15:0] bus_addr;
wire bus_we;
wire [7:0] bus_dout;
wire [15:0] dbg_pc;
wire [7:0] dbg_a;
wire [7:0] dbg_x;
wire [7:0] dbg_y;
wire [7:0] dbg_sp;
wire [7:0] dbg_p;
wire [7:0] dbg_opcode;
wire [6:0] dbg_state;
wire dbg_nmi_pending;
wire dbg_irq_pending;
wire dbg_illegal;

reg [7:0] memory [0:65535];
reg [15:0] tr_addr [0:MAXTR-1];
reg [7:0] tr_dout [0:MAXTR-1];
reg [7:0] tr_din [0:MAXTR-1];
reg tr_we [0:MAXTR-1];
integer tr_count;
integer tr_end;
integer base_idx;
integer assert_count;
integer k;
reg done_flag;
reg probe_fired;
reg [15:0] probe_pc;
reg [7:0] probe_p;
reg [15:0] mark_pc;
reg [7:0] mark_p;
reg [8*24-1:0] scn;

nes_cpu6502 dut(
    .clk(clk),
    .reset(reset),
    .ce(ce),
    .bus_hold(bus_hold),
    .bus_din(bus_din),
    .bus_ready(bus_ready),
    .nmi_i(nmi_i),
    .irq_i(irq_i),
    .bus_req(bus_req),
    .bus_fire(bus_fire),
    .cpu_cycle(cpu_cycle),
    .cpu_cycle_phase(cpu_cycle_phase),
    .bus_addr(bus_addr),
    .bus_we(bus_we),
    .bus_dout(bus_dout),
    .dbg_pc(dbg_pc),
    .dbg_a(dbg_a),
    .dbg_x(dbg_x),
    .dbg_y(dbg_y),
    .dbg_sp(dbg_sp),
    .dbg_p(dbg_p),
    .dbg_opcode(dbg_opcode),
    .dbg_state(dbg_state),
    .dbg_nmi_pending(dbg_nmi_pending),
    .dbg_irq_pending(dbg_irq_pending),
    .dbg_illegal(dbg_illegal)
);

always #5 clk = ~clk;

assign bus_hold = 1'b0;
assign nmi_i = 1'b0;
assign irq_i = 1'b0;

always @* begin
    bus_din = 8'h00;
    if (bus_fire && !bus_we)
        bus_din = memory[bus_addr];
end

always @(posedge clk) begin
    if (bus_fire && bus_we)
        memory[bus_addr] <= bus_dout;
end

always @(posedge clk) begin
    if (reset) begin
        tr_count = 0;
        tr_end = -1;
        done_flag = 1'b0;
        probe_fired = 1'b0;
    end else begin
        if (bus_fire) begin
            if (tr_count >= MAXTR)
                $fatal(1, "[%0s] transaction log overflow at %0d entries", scn, tr_count);
            if (done_flag && !probe_fired) begin
                probe_pc = dbg_pc;
                probe_p = dbg_p;
                probe_fired = 1'b1;
            end
            tr_addr[tr_count] = bus_addr;
            tr_we[tr_count] = bus_we;
            tr_dout[tr_count] = bus_dout;
            tr_din[tr_count] = bus_we ? 8'h00 : bus_din;
            if (bus_we && (bus_addr == MARK_ADDR) && !done_flag) begin
                tr_end = tr_count;
                done_flag = 1'b1;
                mark_pc = dbg_pc;
                mark_p = dbg_p;
            end
            tr_count = tr_count + 1;
        end
    end
end

task poke;
    input [15:0] addr;
    input [7:0] data;
    begin
        memory[addr] = data;
    end
endtask

task clear_ram;
    integer n;
    begin
        for (n = 0; n < 65536; n = n + 1)
            memory[n] = 8'h00;
        memory[16'hFFFA] = 8'h00;
        memory[16'hFFFB] = 8'h04;
        memory[16'hFFFC] = 8'h00;
        memory[16'hFFFD] = 8'h04;
        memory[16'hFFFE] = 8'h00;
        memory[16'hFFFF] = 8'h04;
    end
endtask

task start_scenario;
    begin
        ce = 1'b1;
        reset = 1'b1;
        bus_ready = 1'b1;
        repeat (4) @(posedge clk);
        reset = 1'b0;
        repeat (1) @(posedge clk);
    end
endtask

task dump_trace;
    integer n;
    begin
        for (n = 0; n < tr_count; n = n + 1)
            $display("DUMP %0d %s %04h %02h", n, tr_we[n] ? "W" : "R",
                     tr_addr[n], tr_we[n] ? tr_dout[n] : tr_din[n]);
    end
endtask

task chk_r;
    input integer idx;
    input [15:0] addr;
    begin
        if (idx < 0)
            $fatal(1, "[%0s] negative trace index", scn);
        if (idx >= tr_count)
            $fatal(1, "[%0s] trace index %0d is outside [0,%0d]", scn, idx, tr_count - 1);
        if (tr_we[idx] !== 1'b0)
            $fatal(1, "[%0s] trace %0d expected a read at %04h but it was a write to %04h",
                   scn, idx, addr, tr_addr[idx]);
        if (tr_addr[idx] !== addr) begin
            dump_trace();
            $fatal(1, "[%0s] trace %0d expected a read at %04h but the address was %04h",
                   scn, idx, addr, tr_addr[idx]);
        end
        assert_count = assert_count + 1;
    end
endtask

task chk_rd;
    input integer idx;
    input [7:0] data;
    begin
        if (tr_din[idx] !== data)
            $fatal(1, "[%0s] trace %0d expected read data %02h but got %02h",
                   scn, idx, data, tr_din[idx]);
        assert_count = assert_count + 1;
    end
endtask

task chk_w;
    input integer idx;
    input [15:0] addr;
    input [7:0] data;
    begin
        if (idx < 0)
            $fatal(1, "[%0s] negative trace index", scn);
        if (idx >= tr_count)
            $fatal(1, "[%0s] trace index %0d is outside [0,%0d]", scn, idx, tr_count - 1);
        if (tr_we[idx] !== 1'b1)
            $fatal(1, "[%0s] trace %0d expected a write at %04h but it was a read from %04h",
                   scn, idx, addr, tr_addr[idx]);
        if (tr_addr[idx] !== addr)
            $fatal(1, "[%0s] trace %0d expected a write at %04h but the address was %04h",
                   scn, idx, addr, tr_addr[idx]);
        if (tr_dout[idx] !== data)
            $fatal(1, "[%0s] trace %0d expected write data %02h but got %02h",
                   scn, idx, data, tr_dout[idx]);
        assert_count = assert_count + 1;
    end
endtask

task chk_range_is_read;
    input integer from_idx;
    input integer to_idx;
    begin
        for (k = from_idx; k <= to_idx; k = k + 1) begin
            if (tr_we[k] !== 1'b0)
                $fatal(1, "[%0s] trace %0d in [%0d,%0d] is a write, reads were expected",
                       scn, k, from_idx, to_idx);
        end
        assert_count = assert_count + 1;
    end
endtask

task chk_count_to;
    input [15:0] addr;
    input want_we;
    input integer want;
    integer n;
    integer c;
    begin
        c = 0;
        for (n = 0; n <= tr_end; n = n + 1) begin
            if ((tr_addr[n] === addr) && (tr_we[n] === want_we))
                c = c + 1;
        end
        if (c !== want)
            $fatal(1, "[%0s] address %04h had %0d transfers with we=%0b, expected %0d",
                   scn, addr, c, want_we, want);
        assert_count = assert_count + 1;
    end
endtask

task chk_mem;
    input [15:0] addr;
    input [7:0] data;
    begin
        if (memory[addr] !== data)
            $fatal(1, "[%0s] memory %04h holds %02h, expected %02h",
                   scn, addr, memory[addr], data);
        assert_count = assert_count + 1;
    end
endtask

task chk_reg;
    input [8*24-1:0] nm;
    input [15:0] got;
    input [15:0] want;
    begin
        if (got !== want)
            $fatal(1, "[%0s] %0s is %04h, expected %04h", scn, nm, got, want);
        assert_count = assert_count + 1;
    end
endtask

task find_first_fetch;
    input [7:0] op;
    begin
        base_idx = -1;
        for (k = 0; k < tr_end; k = k + 1) begin
            if ((tr_we[k] === 1'b0) && (tr_addr[k] === START_ADDR) && (tr_din[k] === op)) begin
                base_idx = k;
                k = tr_end;
            end
        end
        if (base_idx < 0)
            $fatal(1, "[%0s] no opcode fetch of %02h at %04h was logged", scn, op, START_ADDR);
        assert_count = assert_count + 1;
    end
endtask

task chk_reset_prefix;
    begin
        if (base_idx < 3)
            $fatal(1, "[%0s] only %0d transfers precede the first fetch", scn, base_idx);
        for (k = 0; k < base_idx - 2; k = k + 1) begin
            if (tr_we[k] !== 1'b0)
                $fatal(1, "[%0s] reset transfer %0d is a write, all were reads", scn, k);
            if (tr_addr[k] !== 16'h0000)
                $fatal(1, "[%0s] reset transfer %0d is at %04h, expected $0000",
                       scn, k, tr_addr[k]);
        end
        chk_r(base_idx - 2, 16'hFFFC);
        chk_r(base_idx - 1, 16'hFFFD);
    end
endtask

task chk_marker;
    begin
        chk_w(tr_end, MARK_ADDR, 8'h00);
    end
endtask

task chk_probe;
    begin
        if (probe_fired !== 1'b1)
            $fatal(1, "[%0s] the deferred sample after the marker never fired", scn);
    end
endtask

task scn_inc_abs_1234;
    begin
        scn = "INC $1234 abs";
        clear_ram();
        poke(16'h0400, 8'hEE); poke(16'h0401, 8'h34); poke(16'h0402, 8'h12);
        poke(16'h0403, 8'h8D); poke(16'h0404, 8'hF0); poke(16'h0405, 8'h7F);
        poke(16'h0406, 8'h4C); poke(16'h0407, 8'h06); poke(16'h0408, 8'h04);
        poke(16'h1234, 8'h7F);
        poke(16'h0034, 8'hC3);
        start_scenario();
        wait (done_flag == 1'b1);
        wait (probe_fired == 1'b1);
        ce = 1'b0;
        repeat (2) @(posedge clk);
        find_first_fetch(8'hEE);
        chk_reset_prefix();
        chk_r(base_idx + 0, 16'h0400); chk_rd(base_idx + 0, 8'hEE);
        chk_r(base_idx + 1, 16'h0401); chk_rd(base_idx + 1, 8'h34);
        chk_r(base_idx + 2, 16'h0402); chk_rd(base_idx + 2, 8'h12);
        chk_r(base_idx + 3, 16'h1234); chk_rd(base_idx + 3, 8'h7F);
        chk_w(base_idx + 4, 16'h1234, 8'h7F);
        chk_w(base_idx + 5, 16'h1234, 8'h80);
        chk_r(base_idx + 6, 16'h0403); chk_rd(base_idx + 6, 8'h8D);
        chk_range_is_read(base_idx + 0, base_idx + 3);
        chk_count_to(16'h1234, 1'b0, 1);
        chk_count_to(16'h1234, 1'b1, 2);
        chk_count_to(16'h0034, 1'b0, 0);
        chk_count_to(16'h0034, 1'b1, 0);
        chk_mem(16'h1234, 8'h80);
        chk_mem(16'h0034, 8'hC3);
        chk_marker();
        chk_probe();
        chk_reg("PC at the marker", mark_pc, 16'h0406);
        chk_reg("PC one transfer later", probe_pc, 16'h0406);
        if (mark_p !== 8'hA4)
            $fatal(1, "[%0s] P at the marker is %02h, expected a4 (N set by the new value $80)", scn, mark_p);
        if (probe_p !== 8'hA4)
            $fatal(1, "[%0s] P one transfer later is %02h, expected a4", scn, probe_p);
        if (dbg_illegal !== 1'b0)
            $fatal(1, "[%0s] dbg_illegal asserted", scn);
        $display("PASS %0s: read %04h=%02h, wrote old %02h then new %02h, final PC=%04h, P=%02h",
                 scn, 16'h1234, 8'h7F, 8'h7F, 8'h80, probe_pc, probe_p);
    end
endtask

task scn_inc_zp_34;
    begin
        scn = "INC $34 zp";
        clear_ram();
        poke(16'h0400, 8'hE6); poke(16'h0401, 8'h34);
        poke(16'h0402, 8'h8D); poke(16'h0403, 8'hF0); poke(16'h0404, 8'h7F);
        poke(16'h0405, 8'h4C); poke(16'h0406, 8'h05); poke(16'h0407, 8'h04);
        poke(16'h0034, 8'h56);
        poke(16'h1234, 8'hC3);
        start_scenario();
        wait (done_flag == 1'b1);
        wait (probe_fired == 1'b1);
        ce = 1'b0;
        repeat (2) @(posedge clk);
        find_first_fetch(8'hE6);
        chk_reset_prefix();
        chk_r(base_idx + 0, 16'h0400); chk_rd(base_idx + 0, 8'hE6);
        chk_r(base_idx + 1, 16'h0401); chk_rd(base_idx + 1, 8'h34);
        chk_r(base_idx + 2, 16'h0034); chk_rd(base_idx + 2, 8'h56);
        chk_w(base_idx + 3, 16'h0034, 8'h56);
        chk_w(base_idx + 4, 16'h0034, 8'h57);
        chk_r(base_idx + 5, 16'h0402); chk_rd(base_idx + 5, 8'h8D);
        chk_range_is_read(base_idx + 0, base_idx + 2);
        chk_count_to(16'h0034, 1'b0, 1);
        chk_count_to(16'h0034, 1'b1, 2);
        chk_count_to(16'h1234, 1'b0, 0);
        chk_count_to(16'h1234, 1'b1, 0);
        chk_mem(16'h0034, 8'h57);
        chk_mem(16'h1234, 8'hC3);
        chk_marker();
        chk_probe();
        chk_reg("PC at the marker", mark_pc, 16'h0405);
        chk_reg("PC one transfer later", probe_pc, 16'h0405);
        if (mark_p !== 8'h24)
            $fatal(1, "[%0s] P at the marker is %02h, expected 24 (N and Z both clear)", scn, mark_p);
        if (probe_p !== 8'h24)
            $fatal(1, "[%0s] P one transfer later is %02h, expected 24", scn, probe_p);
        if (dbg_illegal !== 1'b0)
            $fatal(1, "[%0s] dbg_illegal asserted", scn);
        $display("PASS %0s: read %04h=%02h, wrote old %02h then new %02h, final PC=%04h, P=%02h",
                 scn, 16'h0034, 8'h56, 8'h56, 8'h57, probe_pc, probe_p);
    end
endtask

task scn_ldx_absy_be;
    begin
        scn = "LDX $1234,Y abY";
        clear_ram();
        poke(16'h0400, 8'hA0); poke(16'h0401, 8'h02);
        poke(16'h0402, 8'hBE); poke(16'h0403, 8'h34); poke(16'h0404, 8'h12);
        poke(16'h0405, 8'h8D); poke(16'h0406, 8'hF0); poke(16'h0407, 8'h7F);
        poke(16'h0408, 8'h4C); poke(16'h0409, 8'h08); poke(16'h040A, 8'h04);
        poke(16'h1236, 8'h77);
        poke(16'h1234, 8'h11);
        start_scenario();
        wait (done_flag == 1'b1);
        wait (probe_fired == 1'b1);
        ce = 1'b0;
        repeat (2) @(posedge clk);
        find_first_fetch(8'hA0);
        chk_reset_prefix();
        chk_r(base_idx + 0, 16'h0400); chk_rd(base_idx + 0, 8'hA0);
        chk_r(base_idx + 1, 16'h0401); chk_rd(base_idx + 1, 8'h02);
        chk_r(base_idx + 2, 16'h0402); chk_rd(base_idx + 2, 8'hBE);
        chk_r(base_idx + 3, 16'h0403); chk_rd(base_idx + 3, 8'h34);
        chk_r(base_idx + 4, 16'h0404); chk_rd(base_idx + 4, 8'h12);
        chk_r(base_idx + 5, 16'h1236); chk_rd(base_idx + 5, 8'h77);
        chk_r(base_idx + 6, 16'h0405); chk_rd(base_idx + 6, 8'h8D);
        chk_range_is_read(base_idx + 2, base_idx + 5);
        chk_count_to(16'h1236, 1'b0, 1);
        chk_count_to(16'h1236, 1'b1, 0);
        chk_count_to(16'h1234, 1'b0, 0);
        chk_count_to(16'h1234, 1'b1, 0);
        chk_mem(16'h1234, 8'h11);
        chk_marker();
        chk_probe();
        chk_reg("PC at the marker", mark_pc, 16'h0408);
        chk_reg("PC one transfer later", probe_pc, 16'h0408);
        if (dbg_x !== 8'h77)
            $fatal(1, "[%0s] X is %02h, expected 77 loaded from %04h", scn, dbg_x, 16'h1236);
        if (dbg_illegal !== 1'b0)
            $fatal(1, "[%0s] dbg_illegal asserted", scn);
        $display("PASS %0s: read %04h=%02h into X, final PC=%04h", scn, 16'h1236, 8'h77, probe_pc);
    end
endtask

initial begin
    clk = 1'b0;
    reset = 1'b1;
    ce = 1'b1;
    bus_ready = 1'b1;
    bus_din = 8'h00;
    tr_count = 0;
    tr_end = -1;
    done_flag = 1'b0;
    probe_fired = 1'b0;
    assert_count = 0;
    base_idx = -1;
    for (k = 0; k < 65536; k = k + 1)
        memory[k] = 8'h00;

    repeat (4) @(posedge clk);
    scn_inc_abs_1234();
    scn_inc_zp_34();
    scn_ldx_absy_be();

    $display("PASS INC self-check: assertions=%0d, first fetch after %0d reset transfers",
             assert_count, base_idx);
    $finish;
end

initial begin
    #2000000;
    for (k = 0; k < tr_count; k = k + 1)
        $display("TIMEOUT TRACE %0d %s %04h %02h state=%0d pc=%04h",
                 k, tr_we[k] ? "W" : "R", tr_addr[k],
                 tr_we[k] ? tr_dout[k] : tr_din[k], dbg_state, dbg_pc);
    $fatal(1, "global timeout, scenario [%0s] transfers=%0d", scn, tr_count);
end

endmodule
