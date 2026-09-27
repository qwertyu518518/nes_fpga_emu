`timescale 1ns/1ps

module tb_nes_cpu6502_bus;

localparam MAXTR = 4096;
localparam MARK_ADDR = 16'h7FF0;
localparam NMI_HANDLER = 16'h0500;
localparam IRQ_HANDLER = 16'h0600;

reg clk;
reg reset;
reg ce;
wire bus_hold;
reg bus_ready;
reg [7:0] bus_din;
reg nmi_armed;
reg [15:0] nmi_addr_t;
reg nmi_on_write;
reg irq_armed;
reg [15:0] irq_addr_t;
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
reg [7:0] tr_sp [0:MAXTR-1];
reg tr_we [0:MAXTR-1];
integer tr_count;
integer tr_end;
reg done_flag;
reg s_pend;
reg [15:0] s_addr;
reg s_we;
reg [7:0] s_dout;
reg h_pend;
reg [15:0] h_addr;
reg h_we;
reg [7:0] h_dout;
integer stall_count;
reg stall_armed;
integer stall_at;
reg hold_armed;
reg [15:0] hold_addr_t;
reg hold_released;
reg [2:0] hold_cnt;
reg hold_was_active;
integer stall_fired;
integer hold_fired;
integer stall_total;
integer hold_total;
integer assert_count;
integer stack_slot_checks;
integer k;
reg [8*24-1:0] scn;
reg [7:0] mark_a;
reg [7:0] mark_x;
reg [7:0] mark_y;
reg [7:0] mark_sp;
reg [7:0] mark_p;
integer captured;
integer probe_index;
reg probe_armed;
reg [7:0] probe_sp;
reg [7:0] probe_p;
reg [15:0] probe_pc;

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

assign bus_ready = (stall_count == 0);
assign nmi_i = nmi_armed && bus_req && (bus_addr == nmi_addr_t) && (!bus_we || nmi_on_write);
assign irq_i = irq_armed && bus_req && !bus_we && (bus_addr == irq_addr_t);
assign bus_hold = hold_armed && !hold_released && (bus_addr == hold_addr_t);

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
        stall_count <= 0;
        stall_armed <= 1'b0;
        stall_at <= -1;
        hold_released <= 1'b0;
        hold_cnt <= 0;
        hold_was_active <= 1'b0;
        stall_fired <= 0;
        hold_fired <= 0;
        s_pend <= 1'b0;
        h_pend <= 1'b0;
        probe_armed <= 1'b0;
    end else begin
        if (stall_count != 0)
            stall_count <= stall_count - 1;
        if (stall_armed && (stall_at == tr_count)) begin
            stall_count <= 3;
            stall_armed <= 1'b0;
            stall_fired <= stall_fired + 1;
            stall_total = stall_total + 1;
        end
        if (bus_hold && !hold_was_active) begin
            hold_fired <= hold_fired + 1;
            hold_was_active <= 1'b1;
            hold_total = hold_total + 1;
        end else if (!bus_hold) begin
            hold_was_active <= 1'b0;
        end
        if (bus_hold) begin
            if (hold_cnt == 3'd4)
                hold_released <= 1'b1;
            else
                hold_cnt <= hold_cnt + 3'd1;
        end
        if (bus_fire) begin
            if (tr_count >= MAXTR)
                $fatal(1, "[%0s] transaction log overflow at %0d entries", scn, tr_count);
            if (bus_addr[15:8] == 8'h01) begin
                stack_slot_checks = stack_slot_checks + 1;
                if (bus_we) begin
                    if (bus_addr[15:0] !== {8'h01, (dbg_sp - 8'd1)})
                        $fatal(1, "[%0s] stack push to %04h with SP=%02h, expected $0100+(SP-1)=%04h",
                               scn, bus_addr, dbg_sp, {8'h01, (dbg_sp - 8'd1)});
                end else begin
                    if (bus_addr[15:0] !== {8'h01, dbg_sp})
                        $fatal(1, "[%0s] stack pop from %04h with SP=%02h, expected $0100+SP=%04h",
                               scn, bus_addr, dbg_sp, {8'h01, dbg_sp});
                end
            end
            tr_addr[tr_count] = bus_addr;
            tr_we[tr_count] = bus_we;
            tr_dout[tr_count] = bus_dout;
            tr_din[tr_count] = bus_we ? 8'h00 : bus_din;
            tr_sp[tr_count] = dbg_sp;
            if (bus_we && (bus_addr == MARK_ADDR) && !done_flag) begin
                tr_end = tr_count;
                done_flag = 1'b1;
                mark_a = dbg_a;
                mark_x = dbg_x;
                mark_y = dbg_y;
                mark_sp = dbg_sp;
                mark_p = dbg_p;
            end
            if (probe_armed && (tr_count == probe_index)) begin
                probe_sp = dbg_sp;
                probe_p = dbg_p;
                probe_pc = dbg_pc;
                probe_armed <= 1'b0;
            end
            tr_count = tr_count + 1;
        end
        if (bus_req && !bus_ready) begin
            if (s_pend &&
                ((bus_addr !== s_addr) || (bus_we !== s_we) || (bus_dout !== s_dout)))
                $fatal(1, "[%0s] bus outputs moved while stalled: %04h/%0b/%02h -> %04h/%0b/%02h",
                       scn, s_addr, s_we, s_dout, bus_addr, bus_we, bus_dout);
            s_addr = bus_addr;
            s_we = bus_we;
            s_dout = bus_dout;
            s_pend = 1'b1;
        end else begin
            s_pend = 1'b0;
        end
        if (bus_hold) begin
            if (h_pend &&
                ((bus_addr !== h_addr) || (bus_we !== h_we) || (bus_dout !== h_dout)))
                $fatal(1, "[%0s] bus outputs moved while bus_hold: %04h/%0b/%02h -> %04h/%0b/%02h",
                       scn, h_addr, h_we, h_dout, bus_addr, bus_we, bus_dout);
            h_addr = bus_addr;
            h_we = bus_we;
            h_dout = bus_dout;
            h_pend = 1'b1;
        end else begin
            h_pend = 1'b0;
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
        for (n = 0; n < 2048; n = n + 1)
            memory[n] = 8'h00;
        memory[16'hFFFA] = 8'h00;
        memory[16'hFFFB] = 8'h05;
        memory[16'hFFFC] = 8'h00;
        memory[16'hFFFD] = 8'h04;
        memory[16'hFFFE] = 8'h00;
        memory[16'hFFFF] = 8'h06;
    end
endtask

task start_scenario;
    begin
        nmi_armed = 1'b0;
        nmi_on_write = 1'b0;
        irq_armed = 1'b0;
        stall_armed = 1'b0;
        hold_armed = 1'b0;
        hold_released = 1'b1;
        hold_cnt = 0;
        hold_was_active = 1'b0;
        ce = 1'b1;
        reset = 1'b1;
        repeat (4) @(posedge clk);
        reset = 1'b0;
        repeat (1) @(posedge clk);
    end
endtask

task arm_hold;
    input [15:0] addr;
    begin
        hold_released = 1'b0;
        hold_cnt = 0;
        hold_armed = 1'b1;
        hold_addr_t = addr;
    end
endtask

task freeze_cpu;
    begin
        nmi_armed = 1'b0;
        irq_armed = 1'b0;
        stall_armed = 1'b0;
        hold_armed = 1'b0;
        ce = 1'b0;
        repeat (2) @(posedge clk);
        ce = 1'b1;
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
            $fatal(1, "[%0s] trace %0d expected read at %04h but it was a write to %04h",
                   scn, idx, addr, tr_addr[idx]);
        if (tr_addr[idx] !== addr) begin
            dump_trace();
            $fatal(1, "[%0s] trace %0d expected read at %04h but address was %04h",
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
            $fatal(1, "[%0s] trace %0d expected write at %04h but it was a read from %04h",
                   scn, idx, addr, tr_addr[idx]);
        if (tr_addr[idx] !== addr)
            $fatal(1, "[%0s] trace %0d expected write at %04h but address was %04h",
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
                $fatal(1, "[%0s] trace %0d in [%0d,%0d] is a write, expected reads only",
                       scn, k, from_idx, to_idx);
        end
        assert_count = assert_count + 1;
    end
endtask

task chk_count_to;
    input [15:0] addr;
    input [7:0] want_we;
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

task chk_reset_prefix;
    begin
        chk_r(0, 16'h0000);
        chk_r(1, 16'h0000);
        chk_r(2, 16'h0000);
        chk_r(3, 16'h0000);
        chk_r(4, 16'h0000);
        chk_r(5, 16'hFFFC);
        chk_r(6, 16'hFFFD);
        chk_r(7, 16'h0400);
    end
endtask

task chk_stall_seen;
    input integer want;
    begin
        if (stall_fired !== want)
            $fatal(1, "[%0s] stall fired %0d times, expected %0d", scn, stall_fired, want);
        assert_count = assert_count + 1;
    end
endtask

task scn_sta_absx;
    begin
        scn = "STA abs,X";
        clear_ram();
        poke(16'h0400, 8'hA9); poke(16'h0401, 8'h5A);
        poke(16'h0402, 8'hA2); poke(16'h0403, 8'h02);
        poke(16'h0404, 8'h9D); poke(16'h0405, 8'hFF); poke(16'h0406, 8'h05);
        poke(16'h0407, 8'h8D); poke(16'h0408, 8'hF0); poke(16'h0409, 8'h7F);
        poke(16'h040A, 8'h4C); poke(16'h040B, 8'h0A); poke(16'h040C, 8'h04);
        poke(16'h0501, 8'hEE);
        start_scenario();
        arm_hold(16'h0406);
        stall_armed = 1'b1; stall_at = 14;
        wait (done_flag == 1'b1);
        freeze_cpu();
        chk_reset_prefix();
        chk_r(11, 16'h0404); chk_rd(11, 8'h9D);
        chk_r(12, 16'h0405); chk_rd(12, 8'hFF);
        chk_r(13, 16'h0406); chk_rd(13, 8'h05);
        chk_r(14, 16'h0501); chk_rd(14, 8'hEE);
        chk_w(15, 16'h0601, 8'h5A);
        chk_r(16, 16'h0407);
        chk_w(tr_end, MARK_ADDR, 8'h5A);
        chk_count_to(16'h0501, 1'b1, 0);
        chk_count_to(16'h0601, 1'b1, 1);
        chk_count_to(16'h0501, 1'b0, 1);
        if (dbg_illegal !== 1'b0)
            $fatal(1, "[%0s] dbg_illegal asserted", scn);
        if (dbg_a !== 8'h5A)
            $fatal(1, "[%0s] A mismatch: %02h", scn, dbg_a);
        if (memory[16'h0501] !== 8'hEE)
            $fatal(1, "[%0s] dummy address was modified: %02h", scn, memory[16'h0501]);
        chk_stall_seen(1);
        if (hold_fired != 1)
            $fatal(1, "[%0s] bus_hold was exercised %0d times (addr %04h, released %0b, cnt %0d)",
                   scn, hold_fired, hold_addr_t, hold_released, hold_cnt);
        $display("PASS %0s: dummy read %04h, single write %04h", scn, 16'h0501, 16'h0601);
    end
endtask

task scn_sta_izy;
    begin
        scn = "STA (zp),Y";
        clear_ram();
        poke(16'h0030, 8'hFF);
        poke(16'h0031, 8'h05);
        poke(16'h0400, 8'hA9); poke(16'h0401, 8'hC3);
        poke(16'h0402, 8'hA0); poke(16'h0403, 8'h05);
        poke(16'h0404, 8'h91); poke(16'h0405, 8'h30);
        poke(16'h0406, 8'h8D); poke(16'h0407, 8'hF0); poke(16'h0408, 8'h7F);
        poke(16'h0409, 8'h4C); poke(16'h040A, 8'h09); poke(16'h040B, 8'h04);
        poke(16'h0504, 8'h5A);
        poke(16'h0604, 8'h00);
        start_scenario();
        wait (done_flag == 1'b1);
        freeze_cpu();
        chk_reset_prefix();
        chk_r(11, 16'h0404); chk_rd(11, 8'h91);
        chk_r(12, 16'h0405); chk_rd(12, 8'h30);
        chk_r(13, 16'h0030); chk_rd(13, 8'hFF);
        chk_r(14, 16'h0031); chk_rd(14, 8'h05);
        chk_r(15, 16'h0504); chk_rd(15, 8'h5A);
        chk_w(16, 16'h0604, 8'hC3);
        chk_r(17, 16'h0406);
        chk_w(tr_end, MARK_ADDR, 8'hC3);
        chk_count_to(16'h0504, 1'b1, 0);
        chk_count_to(16'h0604, 1'b1, 1);
        chk_count_to(16'h0504, 1'b0, 1);
        if (memory[16'h0504] !== 8'h5A)
            $fatal(1, "[%0s] dummy address was modified: %02h", scn, memory[16'h0504]);
        if (dbg_illegal !== 1'b0)
            $fatal(1, "[%0s] dbg_illegal asserted", scn);
        $display("PASS %0s: dummy read %04h, single write %04h", scn, 16'h0504, 16'h0604);
    end
endtask

task scn_lda_izy;
    begin
        scn = "LDA (zp),Y";
        clear_ram();
        poke(16'h0030, 8'hFF);
        poke(16'h0031, 8'h05);
        poke(16'h0400, 8'hA0); poke(16'h0401, 8'h05);
        poke(16'h0402, 8'hB1); poke(16'h0403, 8'h30);
        poke(16'h0404, 8'h8D); poke(16'h0405, 8'hF0); poke(16'h0406, 8'h7F);
        poke(16'h0407, 8'h4C); poke(16'h0408, 8'h07); poke(16'h0409, 8'h04);
        poke(16'h0504, 8'h5A);
        poke(16'h0604, 8'h9B);
        start_scenario();
        wait (done_flag == 1'b1);
        freeze_cpu();
        chk_reset_prefix();
        chk_r(9, 16'h0402); chk_rd(9, 8'hB1);
        chk_r(10, 16'h0403); chk_rd(10, 8'h30);
        chk_r(11, 16'h0030); chk_rd(11, 8'hFF);
        chk_r(12, 16'h0031); chk_rd(12, 8'h05);
        chk_r(13, 16'h0504); chk_rd(13, 8'h5A);
        chk_r(14, 16'h0604); chk_rd(14, 8'h9B);
        chk_r(15, 16'h0404);
        chk_w(tr_end, MARK_ADDR, 8'h9B);
        chk_count_to(16'h0504, 1'b0, 1);
        chk_count_to(16'h0604, 1'b0, 1);
        if (dbg_a !== 8'h9B)
            $fatal(1, "[%0s] A should be 9b from the fixed address, got %02h", scn, dbg_a);
        $display("PASS %0s: dummy read %04h discarded, data read %04h", scn, 16'h0504, 16'h0604);
    end
endtask

task chk_rmw_indexed;
    input integer base_idx;
    input [15:0] dummy_addr;
    input [8*8-1:0] dummy_text;
    input [15:0] target_addr;
    input [7:0] old_val;
    input [7:0] new_val;
    begin
        chk_r(base_idx + 0, dummy_addr);
        chk_rd(base_idx + 0, 8'hEE);
        chk_r(base_idx + 1, target_addr);
        chk_rd(base_idx + 1, old_val);
        chk_w(base_idx + 2, target_addr, old_val);
        chk_w(base_idx + 3, target_addr, new_val);
        chk_r(base_idx + 4, 16'h0407);
        chk_count_to(dummy_addr, 1'b1, 0);
        chk_count_to(target_addr, 1'b0, 1);
        chk_count_to(target_addr, 1'b1, 2);
        if (memory[dummy_addr] !== 8'hEE)
            $fatal(1, "[%0s] dummy address %04h was modified: %02h", scn, dummy_addr, memory[dummy_addr]);
        if (memory[target_addr] !== new_val)
            $fatal(1, "[%0s] target %04h holds %02h, expected %02h", scn, target_addr, memory[target_addr], new_val);
        assert_count = assert_count + 1;
    end
endtask

task scn_inc_absx_samepage;
    begin
        scn = "INC abs,X same";
        clear_ram();
        poke(16'h0400, 8'hA9); poke(16'h0401, 8'h55);
        poke(16'h0402, 8'hA2); poke(16'h0403, 8'h01);
        poke(16'h0404, 8'hFE); poke(16'h0405, 8'h00); poke(16'h0406, 8'h06);
        poke(16'h0407, 8'h8D); poke(16'h0408, 8'hF0); poke(16'h0409, 8'h7F);
        poke(16'h040A, 8'h4C); poke(16'h040B, 8'h0A); poke(16'h040C, 8'h04);
        poke(16'h0601, 8'h3C);
        start_scenario();
        wait (done_flag == 1'b1);
        freeze_cpu();
        chk_reset_prefix();
        chk_r(11, 16'h0404); chk_rd(11, 8'hFE);
        chk_r(12, 16'h0405); chk_rd(12, 8'h00);
        chk_r(13, 16'h0406); chk_rd(13, 8'h06);
        chk_r(14, 16'h0601); chk_rd(14, 8'h3C);
        chk_r(15, 16'h0601); chk_rd(15, 8'h3C);
        chk_w(16, 16'h0601, 8'h3C);
        chk_w(17, 16'h0601, 8'h3D);
        chk_r(18, 16'h0407);
        chk_range_is_read(11, 15);
        chk_count_to(16'h0601, 1'b0, 2);
        chk_count_to(16'h0601, 1'b1, 2);
        if (memory[16'h0601] !== 8'h3D)
            $fatal(1, "[%0s] memory %04h holds %02h", scn, 16'h0601, memory[16'h0601]);
        $display("PASS %0s: dummy+data read %04h, old write %02h, new write %02h",
                 scn, 16'h0601, 8'h3C, 8'h3D);
    end
endtask

task scn_inc_absx_cross;
    begin
        scn = "INC abs,X cross";
        clear_ram();
        poke(16'h0400, 8'hA9); poke(16'h0401, 8'h56);
        poke(16'h0402, 8'hA2); poke(16'h0403, 8'h01);
        poke(16'h0404, 8'hFE); poke(16'h0405, 8'hFF); poke(16'h0406, 8'h05);
        poke(16'h0407, 8'h8D); poke(16'h0408, 8'hF0); poke(16'h0409, 8'h7F);
        poke(16'h040A, 8'h4C); poke(16'h040B, 8'h0A); poke(16'h040C, 8'h04);
        poke(16'h0500, 8'hEE);
        poke(16'h0600, 8'h7F);
        start_scenario();
        stall_armed = 1'b1; stall_at = 15;
        wait (done_flag == 1'b1);
        freeze_cpu();
        chk_reset_prefix();
        chk_r(11, 16'h0404); chk_rd(11, 8'hFE);
        chk_r(12, 16'h0405); chk_rd(12, 8'hFF);
        chk_r(13, 16'h0406); chk_rd(13, 8'h05);
        chk_r(14, 16'h0500); chk_rd(14, 8'hEE);
        chk_r(15, 16'h0600); chk_rd(15, 8'h7F);
        chk_w(16, 16'h0600, 8'h7F);
        chk_w(17, 16'h0600, 8'h80);
        chk_r(18, 16'h0407);
        chk_range_is_read(11, 15);
        chk_count_to(16'h0500, 1'b1, 0);
        chk_count_to(16'h0600, 1'b0, 1);
        chk_count_to(16'h0600, 1'b1, 2);
        if (memory[16'h0500] !== 8'hEE)
            $fatal(1, "[%0s] dummy address was modified: %02h", scn, memory[16'h0500]);
        if (memory[16'h0600] !== 8'h80)
            $fatal(1, "[%0s] target %04h holds %02h", scn, 16'h0600, memory[16'h0600]);
        if (dbg_illegal !== 1'b0)
            $fatal(1, "[%0s] dbg_illegal asserted", scn);
        chk_stall_seen(1);
        $display("PASS %0s: dummy read %04h=ee discarded, data read %04h=7f, writes 7f then 80",
                 scn, 16'h0500, 16'h0600);
    end
endtask

task scn_sta_absy_cross;
    begin
        scn = "STA abs,Y";
        clear_ram();
        poke(16'h0400, 8'hA9); poke(16'h0401, 8'h6E);
        poke(16'h0402, 8'hA0); poke(16'h0403, 8'h01);
        poke(16'h0404, 8'h99); poke(16'h0405, 8'hFF); poke(16'h0406, 8'h05);
        poke(16'h0407, 8'h8D); poke(16'h0408, 8'hF0); poke(16'h0409, 8'h7F);
        poke(16'h040A, 8'h4C); poke(16'h040B, 8'h0A); poke(16'h040C, 8'h04);
        poke(16'h0500, 8'hEE);
        poke(16'h0600, 8'h00);
        start_scenario();
        wait (done_flag == 1'b1);
        freeze_cpu();
        chk_reset_prefix();
        chk_r(11, 16'h0404); chk_rd(11, 8'h99);
        chk_r(12, 16'h0405); chk_rd(12, 8'hFF);
        chk_r(13, 16'h0406); chk_rd(13, 8'h05);
        chk_r(14, 16'h0500); chk_rd(14, 8'hEE);
        chk_w(15, 16'h0600, 8'h6E);
        chk_r(16, 16'h0407);
        chk_w(tr_end, MARK_ADDR, 8'h6E);
        chk_count_to(16'h0500, 1'b1, 0);
        chk_count_to(16'h0600, 1'b1, 1);
        chk_count_to(16'h0500, 1'b0, 1);
        if (memory[16'h0500] !== 8'hEE)
            $fatal(1, "[%0s] dummy address was modified: %02h", scn, memory[16'h0500]);
        if (dbg_illegal !== 1'b0)
            $fatal(1, "[%0s] dbg_illegal asserted", scn);
        $display("PASS %0s: dummy read %04h, single write %04h", scn, 16'h0500, 16'h0600);
    end
endtask

task scn_sta_izx;
    begin
        scn = "STA (zp),X";
        clear_ram();
        poke(16'h0001, 8'h00);
        poke(16'h0002, 8'h06);
        poke(16'h00FE, 8'hE1);
        poke(16'h0400, 8'hA9); poke(16'h0401, 8'h6D);
        poke(16'h0402, 8'hA2); poke(16'h0403, 8'h03);
        poke(16'h0404, 8'h81); poke(16'h0405, 8'hFE);
        poke(16'h0406, 8'h8D); poke(16'h0407, 8'hF0); poke(16'h0408, 8'h7F);
        poke(16'h0409, 8'h4C); poke(16'h040A, 8'h09); poke(16'h040B, 8'h04);
        poke(16'h0600, 8'h00);
        start_scenario();
        wait (done_flag == 1'b1);
        freeze_cpu();
        chk_reset_prefix();
        chk_r(11, 16'h0404); chk_rd(11, 8'h81);
        chk_r(12, 16'h0405); chk_rd(12, 8'hFE);
        chk_r(13, 16'h00FE); chk_rd(13, 8'hE1);
        chk_r(14, 16'h0001); chk_rd(14, 8'h00);
        chk_r(15, 16'h0002); chk_rd(15, 8'h06);
        chk_w(16, 16'h0600, 8'h6D);
        chk_r(17, 16'h0406);
        chk_w(tr_end, MARK_ADDR, 8'h6D);
        chk_count_to(16'h0600, 1'b1, 1);
        chk_count_to(16'h00FE, 1'b1, 0);
        if (memory[16'h0600] !== 8'h6D)
            $fatal(1, "[%0s] target %04h holds %02h", scn, 16'h0600, memory[16'h0600]);
        if (dbg_illegal !== 1'b0)
            $fatal(1, "[%0s] dbg_illegal asserted", scn);
        $display("PASS %0s: unindexed dummy at %04h, wrapped pointer %04h/%04h, single write %04h",
                 scn, 16'h00FE, 16'h0001, 16'h0002, 16'h0600);
    end
endtask

task scn_rts;
    begin
        scn = "RTS dummy";
        clear_ram();
        poke(16'h0400, 8'h20); poke(16'h0401, 8'h08); poke(16'h0402, 8'h04);
        poke(16'h0403, 8'hA9); poke(16'h0404, 8'h5A);
        poke(16'h0405, 8'h8D); poke(16'h0406, 8'hF0); poke(16'h0407, 8'h7F);
        poke(16'h0408, 8'h60);
        poke(16'h0409, 8'h4C); poke(16'h040A, 8'h09); poke(16'h040B, 8'h04);
        start_scenario();
        stall_armed = 1'b1; stall_at = 18;
        wait (done_flag == 1'b1);
        freeze_cpu();
        chk_reset_prefix();
        chk_r(7, 16'h0400); chk_rd(7, 8'h20);
        chk_r(8, 16'h0401); chk_rd(8, 8'h08);
        chk_r(9, 16'h01FD);
        chk_w(10, 16'h01FC, 8'h04);
        chk_w(11, 16'h01FB, 8'h02);
        chk_r(12, 16'h0402); chk_rd(12, 8'h04);
        chk_r(13, 16'h0408); chk_rd(13, 8'h60);
        chk_r(14, 16'h0409);
        chk_range_is_read(13, 18);
        chk_r(15, 16'h01FB);
        chk_r(16, 16'h01FB);
        chk_rd(16, 8'h02);
        chk_r(17, 16'h01FC);
        chk_rd(17, 8'h04);
        chk_r(18, 16'h0402);
        chk_r(19, 16'h0403);
        chk_w(tr_end, MARK_ADDR, 8'h5A);
        chk_stall_seen(1);
        if (tr_addr[18] !== 16'h0402)
            $fatal(1, "[%0s] last RTS transaction at %04h is not the pulled pc", scn, tr_addr[18]);
        chk_count_to(16'h01FC, 1'b1, 1);
        chk_count_to(16'h01FB, 1'b1, 1);
        chk_count_to(16'h01FD, 1'b1, 0);
        chk_count_to(16'h01FE, 1'b0, 0);
        if (memory[16'h01FC] !== 8'h04)
            $fatal(1, "[%0s] pushed pc high at 01fc holds %02h", scn, memory[16'h01FC]);
        if (memory[16'h01FB] !== 8'h02)
            $fatal(1, "[%0s] pushed pc low at 01fb holds %02h", scn, memory[16'h01FB]);
        $display("PASS %0s: pushes $01fc/$01fb, pops re-read $01fb then $01fc, last dummy read at %04h, next fetch at %04h",
                 scn, tr_addr[18], tr_addr[19]);
    end
endtask

task scn_rti;
    begin
        scn = "RTI stack";
        clear_ram();
        poke(16'h01F9, 8'h1C);
        poke(16'h01FA, 8'h05);
        poke(16'h01FB, 8'h04);
        poke(16'h0400, 8'hA2); poke(16'h0401, 8'hF9);
        poke(16'h0402, 8'h9A);
        poke(16'h0403, 8'h40);
        poke(16'h0404, 8'hEE);
        poke(16'h0405, 8'hA9); poke(16'h0406, 8'h42);
        poke(16'h0407, 8'h8D); poke(16'h0408, 8'hF0); poke(16'h0409, 8'h7F);
        start_scenario();
        arm_hold(16'h01F9);
        stall_armed = 1'b1; stall_at = 14;
        probe_index = 17; probe_armed = 1'b1;
        wait (done_flag == 1'b1);
        freeze_cpu();
        chk_reset_prefix();
        chk_r(7, 16'h0400); chk_rd(7, 8'hA2);
        chk_r(8, 16'h0401); chk_rd(8, 8'hF9);
        chk_r(9, 16'h0402); chk_rd(9, 8'h9A);
        chk_r(10, 16'h0403); chk_rd(10, 8'h40);
        chk_r(11, 16'h0403); chk_rd(11, 8'h40);
        chk_r(12, 16'h0404); chk_rd(12, 8'hEE);
        chk_r(13, 16'h01F9);
        chk_r(14, 16'h01F9); chk_rd(14, 8'h1C);
        chk_r(15, 16'h01FA); chk_rd(15, 8'h05);
        chk_r(16, 16'h01FB); chk_rd(16, 8'h04);
        chk_r(17, 16'h0405); chk_rd(17, 8'hA9);
        chk_r(18, 16'h0406); chk_rd(18, 8'h42);
        chk_range_is_read(10, 17);
        chk_w(tr_end, MARK_ADDR, 8'h42);
        chk_count_to(16'h01F9, 1'b0, 2);
        chk_count_to(16'h01FA, 1'b0, 1);
        chk_count_to(16'h01FB, 1'b0, 1);
        chk_count_to(16'h01F9, 1'b1, 0);
        chk_count_to(16'h01FA, 1'b1, 0);
        chk_count_to(16'h01FB, 1'b1, 0);
        chk_count_to(16'h01F8, 1'b0, 0);
        chk_count_to(16'h01FC, 1'b0, 0);
        chk_count_to(16'h0404, 1'b0, 1);
        chk_count_to(16'h0404, 1'b1, 0);
        if ((tr_addr[12] !== 16'h0404) || (tr_addr[13] !== 16'h01F9) ||
            (tr_addr[14] !== 16'h01F9) || (tr_addr[15] !== 16'h01FA) ||
            (tr_addr[16] !== 16'h01FB) || (tr_addr[17] !== 16'h0405))
            $fatal(1, "[%0s] RTI transactions are %04h/%04h/%04h/%04h/%04h/%04h, expected $0404/$01f9/$01f9/$01fa/$01fb/$0405",
                   scn, tr_addr[12], tr_addr[13], tr_addr[14], tr_addr[15], tr_addr[16], tr_addr[17]);
        if ((tr_sp[13] !== 8'hF9) || (tr_sp[14] !== 8'hF9) || (tr_sp[15] !== 8'hFA) ||
            (tr_sp[16] !== 8'hFB) || (tr_sp[17] !== 8'hFC))
            $fatal(1, "[%0s] SP across the RTI pulls is %02h/%02h/%02h/%02h/%02h, expected f9/f9/fa/fb/fc",
                   scn, tr_sp[13], tr_sp[14], tr_sp[15], tr_sp[16], tr_sp[17]);
        if (probe_armed !== 1'b0)
            $fatal(1, "[%0s] the post-return probe at transaction %0d never fired", scn, probe_index);
        if (probe_pc !== 16'h0405)
            $fatal(1, "[%0s] PC on the first fetch after RTI is %04h, expected the pulled 0405", scn, probe_pc);
        if (probe_p !== 8'h2C)
            $fatal(1, "[%0s] P on the first fetch after RTI is %02h, expected 2c (stack $1c with b forced clear and bit 5 forced set)",
                   scn, probe_p);
        if (probe_sp !== 8'hFC)
            $fatal(1, "[%0s] SP on the first fetch after RTI is %02h, expected fc", scn, probe_sp);
        if (dbg_p !== 8'h2C)
            $fatal(1, "[%0s] final P is %02h, expected 2c", scn, dbg_p);
        if (dbg_sp !== 8'hFC)
            $fatal(1, "[%0s] final SP is %02h, expected fc", scn, dbg_sp);
        if (dbg_a !== 8'h42)
            $fatal(1, "[%0s] final A is %02h, expected 42", scn, dbg_a);
        if (mark_sp !== 8'hFC)
            $fatal(1, "[%0s] SP at the marker is %02h, expected fc", scn, mark_sp);
        if (mark_p !== 8'h2C)
            $fatal(1, "[%0s] P at the marker is %02h, expected 2c", scn, mark_p);
        if (dbg_illegal !== 1'b0)
            $fatal(1, "[%0s] dbg_illegal asserted", scn);
        chk_stall_seen(1);
        if (hold_fired != 1)
            $fatal(1, "[%0s] bus_hold was exercised %0d times at %04h (released %0b, cnt %0d)",
                   scn, hold_fired, hold_addr_t, hold_released, hold_cnt);
        $display("PASS %0s: dummy %04h, stack dummy %04h, p %02h from %04h, pcl %02h from %04h, pch %02h from %04h, final fetch %04h, pc %04h p %02h sp %02h",
                 scn, 16'h0404, 16'h01F9, 8'h1C, 16'h01F9, 8'h05, 16'h01FA, 8'h04, 16'h01FB, 16'h0405,
                 probe_pc, probe_p, probe_sp);
    end
endtask

task build_irq_program;
    begin
        poke(16'h0400, 8'h58);
        poke(16'h0401, 8'hA9); poke(16'h0402, 8'h11);
        poke(16'h0403, 8'h4C); poke(16'h0404, 8'h0C); poke(16'h0405, 8'h04);
        poke(16'h0406, 8'h5A); poke(16'h0407, 8'h5A);
        poke(16'h0408, 8'h5A); poke(16'h0409, 8'h5A);
        poke(16'h040A, 8'h5A); poke(16'h040B, 8'h5A);
        poke(16'h040C, 8'h4C); poke(16'h040D, 8'h0F); poke(16'h040E, 8'h04);
        poke(16'h040F, 8'h4C); poke(16'h0410, 8'h0F); poke(16'h0411, 8'h04);
    end
endtask

task scn_irq_dummy_pc;
    begin
        scn = "IRQ dummy2 pc";
        clear_ram();
        build_irq_program();
        poke(16'h0600, 8'h8D); poke(16'h0601, 8'hF0); poke(16'h0602, 8'h7F);
        poke(16'h0603, 8'h40);
        start_scenario();
        irq_armed = 1'b1; irq_addr_t = 16'h040F;
        wait (done_flag == 1'b1);
        freeze_cpu();
        chk_reset_prefix();
        chk_r(7, 16'h0400); chk_rd(7, 8'h58);
        chk_r(17, 16'h040F); chk_rd(17, 8'h4C);
        chk_r(18, 16'h040F);
        chk_range_is_read(17, 18);
        chk_w(19, 16'h01FC, 8'h04);
        chk_w(20, 16'h01FB, 8'h0F);
        chk_w(21, 16'h01FA, tr_dout[21]);
        if (tr_addr[19] !== 16'h01FC || tr_addr[20] !== 16'h01FB || tr_addr[21] !== 16'h01FA)
            $fatal(1, "[%0s] interrupt pushes are not the three $0100+SP-1 slots %04h/%04h/%04h",
                   scn, tr_addr[19], tr_addr[20], tr_addr[21]);
        if (tr_dout[21] !== 8'h20)
            $fatal(1, "[%0s] pushed P is %02h, expected 20", scn, tr_dout[21]);
        if (tr_dout[21][4] !== 1'b0)
            $fatal(1, "[%0s] pushed P %02h has the break flag set", scn, tr_dout[21]);
        if (tr_dout[21][5] !== 1'b1)
            $fatal(1, "[%0s] pushed P %02h has the unused bit clear", scn, tr_dout[21]);
        if (dbg_p[2] !== 1'b1)
            $fatal(1, "[%0s] interrupt flag was not set by the interrupt: P=%02h", scn, dbg_p);
        chk_r(22, 16'hFFFE);
        chk_r(23, 16'hFFFF);
        chk_r(24, 16'h0600);
        chk_w(tr_end, MARK_ADDR, 8'h11);
        chk_count_to(MARK_ADDR, 1'b1, 1);
        chk_count_to(16'h01FC, 1'b1, 1);
        chk_count_to(16'h01FB, 1'b1, 1);
        chk_count_to(16'h01FA, 1'b1, 1);
        chk_count_to(16'h01FD, 1'b0, 0);
        if (dbg_illegal !== 1'b0)
            $fatal(1, "[%0s] dbg_illegal asserted", scn);
        $display("PASS %0s: interrupt at pc %04h, dummy2 re-read %04h, pushed pc %04h at $01fc/$01fb, p %02h at $01fa",
                 scn, 16'h040F, tr_addr[18], 16'h040F, tr_dout[21]);
    end
endtask

task scn_nmi_dummy_pc;
    begin
        scn = "NMI dummy2 pc";
        clear_ram();
        build_irq_program();
        poke(16'h0500, 8'h8D); poke(16'h0501, 8'hF0); poke(16'h0502, 8'h7F);
        poke(16'h0503, 8'h40);
        start_scenario();
        nmi_armed = 1'b1; nmi_addr_t = 16'h040E;
        wait (done_flag == 1'b1);
        freeze_cpu();
        chk_reset_prefix();
        chk_r(17, 16'h040F); chk_rd(17, 8'h4C);
        chk_r(18, 16'h040F);
        chk_range_is_read(17, 18);
        chk_w(19, 16'h01FC, 8'h04);
        chk_w(20, 16'h01FB, 8'h0F);
        chk_w(21, 16'h01FA, tr_dout[21]);
        if (tr_addr[19] !== 16'h01FC || tr_addr[20] !== 16'h01FB || tr_addr[21] !== 16'h01FA)
            $fatal(1, "[%0s] interrupt pushes are not the three $0100+SP-1 slots %04h/%04h/%04h",
                   scn, tr_addr[19], tr_addr[20], tr_addr[21]);
        if (tr_dout[21] !== 8'h20)
            $fatal(1, "[%0s] pushed P is %02h, expected 20", scn, tr_dout[21]);
        if (tr_dout[21][4] !== 1'b0)
            $fatal(1, "[%0s] pushed P %02h has the break flag set", scn, tr_dout[21]);
        if (tr_dout[21][5] !== 1'b1)
            $fatal(1, "[%0s] pushed P %02h has the unused bit clear", scn, tr_dout[21]);
        if (dbg_p[2] !== 1'b1)
            $fatal(1, "[%0s] interrupt flag was not set by the interrupt: P=%02h", scn, dbg_p);
        chk_r(22, 16'hFFFA);
        chk_r(23, 16'hFFFB);
        chk_r(24, 16'h0500);
        chk_w(tr_end, MARK_ADDR, 8'h11);
        chk_count_to(16'h01FC, 1'b1, 1);
        chk_count_to(16'h01FB, 1'b1, 1);
        chk_count_to(16'h01FA, 1'b1, 1);
        if (memory[16'h01FA] !== 8'h20)
            $fatal(1, "[%0s] pushed P at 01fa holds %02h", scn, memory[16'h01FA]);
        if (dbg_nmi_pending !== 1'b0)
            $fatal(1, "[%0s] NMI pending stuck high", scn);
        $display("PASS %0s: interrupt at pc %04h, dummy2 re-read %04h, pushed pc %04h at $01fc/$01fb, vector %04h",
                 scn, 16'h040F, tr_addr[18], 16'h040F, 16'hFFFA);
    end
endtask

task scn_brk_nmi_hijack;
    begin
        scn = "BRK NMI hijack";
        clear_ram();
        poke(16'h0400, 8'hA9); poke(16'h0401, 8'h3B);
        poke(16'h0402, 8'h00);
        poke(16'h0403, 8'h4C); poke(16'h0404, 8'h03); poke(16'h0405, 8'h04);
        poke(16'h0500, 8'h8D); poke(16'h0501, 8'hF0); poke(16'h0502, 8'h7F);
        poke(16'h0503, 8'h4C); poke(16'h0504, 8'h03); poke(16'h0505, 8'h05);
        poke(16'h0600, 8'h8D); poke(16'h0601, 8'hF1); poke(16'h0602, 8'h7F);
        poke(16'h0603, 8'h4C); poke(16'h0604, 8'h03); poke(16'h0605, 8'h06);
        start_scenario();
        nmi_armed = 1'b1; nmi_addr_t = 16'h0403;
        wait (done_flag == 1'b1);
        freeze_cpu();
        chk_reset_prefix();
        chk_r(9, 16'h0402); chk_rd(9, 8'h00);
        chk_r(10, 16'h0403);
        chk_range_is_read(9, 10);
        chk_w(11, 16'h01FC, 8'h04);
        chk_w(12, 16'h01FB, 8'h04);
        chk_w(13, 16'h01FA, tr_dout[13]);
        if (tr_addr[11] !== 16'h01FC || tr_addr[12] !== 16'h01FB || tr_addr[13] !== 16'h01FA)
            $fatal(1, "[%0s] hijack pushes are not the three $0100+SP-1 slots %04h/%04h/%04h",
                   scn, tr_addr[11], tr_addr[12], tr_addr[13]);
        if (tr_dout[13] !== 8'h24)
            $fatal(1, "[%0s] hijacked pushed P is %02h, expected 24", scn, tr_dout[13]);
        if (tr_dout[13][4] !== 1'b0)
            $fatal(1, "[%0s] hijacked push still has the break flag set: %02h", scn, tr_dout[13]);
        if (tr_dout[13][2] !== 1'b1)
            $fatal(1, "[%0s] pushed P %02h has the interrupt flag clear", scn, tr_dout[13]);
        chk_r(14, 16'hFFFA);
        chk_r(15, 16'hFFFB);
        chk_r(16, 16'h0500);
        chk_w(tr_end, MARK_ADDR, 8'h3B);
        chk_count_to(16'h7FF1, 1'b1, 0);
        chk_count_to(16'hFFFE, 1'b0, 0);
        chk_count_to(16'hFFFF, 1'b0, 0);
        chk_count_to(16'h01FC, 1'b1, 1);
        chk_count_to(16'h01FB, 1'b1, 1);
        chk_count_to(16'h01FA, 1'b1, 1);
        if (memory[16'h7FF1] !== 8'h00)
            $fatal(1, "[%0s] IRQ vector handler ran during the hijack", scn);
        if (dbg_nmi_pending !== 1'b0)
            $fatal(1, "[%0s] NMI pending stuck high", scn);
        if (dbg_illegal !== 1'b0)
            $fatal(1, "[%0s] dbg_illegal asserted", scn);
        $display("PASS %0s: BRK padding read %04h, hijack pushes $01fc/$01fb/$01fa, vector %04h, break flag cleared",
                 scn, 16'h0403, 16'hFFFA);
    end
endtask

task scn_irq_nmi_hijack;
    begin
        scn = "IRQ NMI hijack";
        clear_ram();
        build_irq_program();
        poke(16'h0500, 8'h8D); poke(16'h0501, 8'hF0); poke(16'h0502, 8'h7F);
        poke(16'h0503, 8'h4C); poke(16'h0504, 8'h03); poke(16'h0505, 8'h05);
        poke(16'h0600, 8'h8D); poke(16'h0601, 8'hF1); poke(16'h0602, 8'h7F);
        poke(16'h0603, 8'h4C); poke(16'h0604, 8'h03); poke(16'h0605, 8'h06);
        start_scenario();
        irq_armed = 1'b1; irq_addr_t = 16'h040F;
        nmi_armed = 1'b1; nmi_on_write = 1'b1; nmi_addr_t = 16'h01FC;
        wait (done_flag == 1'b1);
        freeze_cpu();
        chk_reset_prefix();
        chk_r(7, 16'h0400); chk_rd(7, 8'h58);
        chk_r(17, 16'h040F); chk_rd(17, 8'h4C);
        chk_r(18, 16'h040F);
        chk_range_is_read(17, 18);
        chk_w(19, 16'h01FC, 8'h04);
        chk_w(20, 16'h01FB, 8'h0F);
        chk_w(21, 16'h01FA, tr_dout[21]);
        if (tr_addr[19] !== 16'h01FC || tr_addr[20] !== 16'h01FB || tr_addr[21] !== 16'h01FA)
            $fatal(1, "[%0s] hijack pushes are not the three $0100+SP-1 slots %04h/%04h/%04h",
                   scn, tr_addr[19], tr_addr[20], tr_addr[21]);
        if (tr_dout[21] !== 8'h20)
            $fatal(1, "[%0s] pushed P is %02h, expected 20 (irq push with i clear, b clear)", scn, tr_dout[21]);
        if (tr_dout[21][4] !== 1'b0)
            $fatal(1, "[%0s] pushed P %02h has the break flag set", scn, tr_dout[21]);
        if (tr_dout[21][2] !== 1'b0)
            $fatal(1, "[%0s] pushed P %02h did not come from an irq taken with cli", scn, tr_dout[21]);
        if (tr_dout[21][5] !== 1'b1)
            $fatal(1, "[%0s] pushed P %02h has the unused bit clear", scn, tr_dout[21]);
        if (dbg_p[2] !== 1'b1)
            $fatal(1, "[%0s] interrupt flag was not set by the hijacked interrupt: P=%02h", scn, dbg_p);
        chk_r(22, 16'hFFFA);
        chk_r(23, 16'hFFFB);
        chk_r(24, 16'h0500);
        chk_w(tr_end, MARK_ADDR, 8'h11);
        chk_count_to(16'h7FF1, 1'b1, 0);
        chk_count_to(16'hFFFE, 1'b0, 0);
        chk_count_to(16'hFFFF, 1'b0, 0);
        chk_count_to(16'h01FC, 1'b1, 1);
        chk_count_to(16'h01FB, 1'b1, 1);
        chk_count_to(16'h01FA, 1'b1, 1);
        if (memory[16'h7FF1] !== 8'h00)
            $fatal(1, "[%0s] IRQ vector handler ran during the hijack", scn);
        if (memory[16'h01FA] !== 8'h20)
            $fatal(1, "[%0s] pushed P at 01fa holds %02h", scn, memory[16'h01FA]);
        if (dbg_nmi_pending !== 1'b0)
            $fatal(1, "[%0s] NMI pending stuck high", scn);
        if (dbg_illegal !== 1'b0)
            $fatal(1, "[%0s] dbg_illegal asserted", scn);
        $display("PASS %0s: irq at pc %04h hijacked before the p push, vectors $01fc/$01fb/$01fa, p %02h, vector %04h/%04h, b clear",
                 scn, 16'h040F, tr_dout[21], 16'hFFFA, 16'hFFFB);
    end
endtask

task scn_push_pull_stack;
    begin
        scn = "PHA PHP PLA PLP";
        clear_ram();
        poke(16'h0400, 8'hA9); poke(16'h0401, 8'h5A);
        poke(16'h0402, 8'h48);
        poke(16'h0403, 8'h08);
        poke(16'h0404, 8'h68);
        poke(16'h0405, 8'h28);
        poke(16'h0406, 8'hA9); poke(16'h0407, 8'h7E);
        poke(16'h0408, 8'h48);
        poke(16'h0409, 8'h08);
        poke(16'h040A, 8'h68);
        poke(16'h040B, 8'h28);
        poke(16'h040C, 8'h8D); poke(16'h040D, 8'hF0); poke(16'h040E, 8'h7F);
        start_scenario();
        wait (done_flag == 1'b1);
        freeze_cpu();
        chk_reset_prefix();
        chk_r(9, 16'h0402); chk_rd(9, 8'h48);
        chk_r(10, 16'h0403);
        chk_w(11, 16'h01FC, 8'h5A);
        chk_r(12, 16'h0403); chk_rd(12, 8'h08);
        chk_r(13, 16'h0404);
        chk_w(14, 16'h01FB, 8'h34);
        chk_r(15, 16'h0404); chk_rd(15, 8'h68);
        chk_r(16, 16'h0405);
        chk_r(17, 16'h01FB);
        chk_r(18, 16'h01FB);
        chk_rd(18, 8'h34);
        chk_r(19, 16'h0405); chk_rd(19, 8'h28);
        chk_r(20, 16'h0406);
        chk_r(21, 16'h01FC);
        chk_r(22, 16'h01FC);
        chk_rd(22, 8'h5A);
        chk_r(25, 16'h0408); chk_rd(25, 8'h48);
        chk_r(26, 16'h0409);
        chk_w(27, 16'h01FC, 8'h7E);
        chk_r(28, 16'h0409); chk_rd(28, 8'h08);
        chk_r(29, 16'h040A);
        chk_w(30, 16'h01FB, 8'h78);
        chk_r(31, 16'h040A); chk_rd(31, 8'h68);
        chk_r(32, 16'h040B);
        chk_r(33, 16'h01FB);
        chk_r(34, 16'h01FB);
        chk_rd(34, 8'h78);
        chk_r(35, 16'h040B); chk_rd(35, 8'h28);
        chk_r(36, 16'h040C);
        chk_r(37, 16'h01FC);
        chk_r(38, 16'h01FC);
        chk_rd(38, 8'h7E);
        chk_r(39, 16'h040C); chk_rd(39, 8'h8D);
        chk_r(40, 16'h040D);
        chk_r(41, 16'h040E);
        chk_w(tr_end, MARK_ADDR, 8'h78);
        chk_range_is_read(9, 10);
        chk_range_is_read(12, 13);
        chk_range_is_read(15, 16);
        chk_range_is_read(19, 20);
        chk_range_is_read(25, 26);
        chk_range_is_read(28, 29);
        chk_range_is_read(31, 32);
        chk_range_is_read(35, 36);
        chk_count_to(16'h01FC, 1'b1, 2);
        chk_count_to(16'h01FB, 1'b1, 2);
        chk_count_to(16'h01FD, 1'b1, 0);
        chk_count_to(16'h01FA, 1'b1, 0);
        chk_count_to(16'h01FC, 1'b0, 4);
        chk_count_to(16'h01FB, 1'b0, 4);
        if (memory[16'h01FC] !== 8'h7E)
            $fatal(1, "[%0s] $01fc holds %02h, expected 7e", scn, memory[16'h01FC]);
        if (memory[16'h01FB] !== 8'h78)
            $fatal(1, "[%0s] $01fb holds %02h, expected 78", scn, memory[16'h01FB]);
        if (mark_sp !== 8'hFD)
            $fatal(1, "[%0s] SP at the marker is %02h, expected fd", scn, mark_sp);
        if (mark_p !== 8'h6E)
            $fatal(1, "[%0s] P at the marker is %02h, expected 6e", scn, mark_p);
        if (mark_a !== 8'h78)
            $fatal(1, "[%0s] A at the marker is %02h, expected 78 (the php value)", scn, mark_a);
        if (dbg_a !== 8'h78)
            $fatal(1, "[%0s] final A is %02h, expected 78", scn, dbg_a);
        if (dbg_p !== 8'h6E)
            $fatal(1, "[%0s] final P is %02h, expected 6e", scn, dbg_p);
        if (dbg_sp !== 8'hFD)
            $fatal(1, "[%0s] final SP is %02h, expected fd", scn, dbg_sp);
        if (dbg_illegal !== 1'b0)
            $fatal(1, "[%0s] dbg_illegal asserted", scn);
        $display("PASS %0s: pushes $01fc/$01fb, pulls re-read $01fb/$01fc, final a=%02h p=%02h sp=%02h",
                 scn, dbg_a, dbg_p, dbg_sp);
    end
endtask

task scn_illegal_opcode;
    input [7:0] op;
    input [8*16-1:0] name;
    begin
        scn = name;
        clear_ram();
        poke(16'h0400, 8'hA9); poke(16'h0401, 8'h80);
        poke(16'h0402, 8'h8D); poke(16'h0403, 8'hF0); poke(16'h0404, 8'h7F);
        poke(16'h0405, op); poke(16'h0406, 8'h30);
        poke(16'h0407, 8'h8D); poke(16'h0408, 8'hF1); poke(16'h0409, 8'h7F);
        poke(16'h040A, 8'h4C); poke(16'h040B, 8'h0A); poke(16'h040C, 8'h04);
        start_scenario();
        wait (done_flag == 1'b1);
        captured = 0;
        while ((dbg_illegal !== 1'b1) && (captured < 40)) begin
            @(posedge clk);
            captured = captured + 1;
        end
        if (dbg_illegal !== 1'b1)
            $fatal(1, "[%0s] dbg_illegal was not set within 40 cycles for opcode %02h", scn, op);
        captured = tr_count;
        repeat (20) @(posedge clk);
        if (tr_count !== captured)
            $fatal(1, "[%0s] cpu kept issuing bus transactions after the trap (%0d extra)",
                   scn, tr_count - captured);
        if (dbg_illegal !== 1'b1)
            $fatal(1, "[%0s] dbg_illegal was not set for opcode %02h", scn, op);
        chk_reset_prefix();
        chk_r(9, 16'h0402);
        chk_w(12, MARK_ADDR, 8'h80);
        chk_r(13, 16'h0405); chk_rd(13, op);
        chk_count_to(16'h7FF1, 1'b1, 0);
        if (memory[16'h7FF1] !== 8'h00)
            $fatal(1, "[%0s] instruction after the trap executed", scn);
        if (dbg_a !== mark_a)
            $fatal(1, "[%0s] opcode %02h modified A: %02h -> %02h", scn, op, mark_a, dbg_a);
        if (dbg_x !== mark_x || dbg_y !== mark_y || dbg_sp !== mark_sp)
            $fatal(1, "[%0s] opcode %02h modified X/Y/SP", scn, op);
        if (dbg_p !== mark_p)
            $fatal(1, "[%0s] opcode %02h modified P: %02h -> %02h", scn, op, mark_p, dbg_p);
        if (dbg_pc !== 16'h0405)
            $fatal(1, "[%0s] pc advanced to %04h on a trap", scn, dbg_pc);
        if (dbg_opcode !== op)
            $fatal(1, "[%0s] dbg_opcode is %02h, expected %02h", scn, dbg_opcode, op);
        $display("PASS %0s: opcode %02h trapped, dbg_illegal set, no state change", scn, op);
    end
endtask

initial begin
    clk = 1'b0;
    reset = 1'b1;
    ce = 1'b1;
    nmi_armed = 1'b0;
    nmi_addr_t = 16'h0000;
    nmi_on_write = 1'b0;
    irq_armed = 1'b0;
    irq_addr_t = 16'h0000;
    stall_armed = 1'b0;
    stall_at = -1;
    hold_armed = 1'b0;
    hold_addr_t = 16'h0000;
    hold_released = 1'b1;
    hold_cnt = 0;
    hold_was_active = 1'b0;
    stall_count = 0;
    tr_count = 0;
    tr_end = -1;
    done_flag = 1'b0;
    stall_fired = 0;
    hold_fired = 0;
    stall_total = 0;
    hold_total = 0;
    assert_count = 0;
    stack_slot_checks = 0;
    for (k = 0; k < 65536; k = k + 1)
        memory[k] = 8'h00;

    repeat (4) @(posedge clk);
    scn_sta_absx();
    scn_sta_izy();
    scn_lda_izy();
    scn_inc_absx_samepage();
    scn_inc_absx_cross();
    scn_sta_absy_cross();
    scn_sta_izx();
    scn_rts();
    scn_rti();
    scn_irq_dummy_pc();
    scn_nmi_dummy_pc();
    scn_brk_nmi_hijack();
    scn_irq_nmi_hijack();
    scn_push_pull_stack();

    scn_illegal_opcode(8'h1A, "illegal 1A");
    scn_illegal_opcode(8'h3A, "illegal 3A");
    scn_illegal_opcode(8'h5A, "illegal 5A");
    scn_illegal_opcode(8'h7A, "illegal 7A");
    scn_illegal_opcode(8'hB2, "illegal B2");

    if (stall_total < 2)
        $fatal(1, "only %0d stalls were injected across the run", stall_total);
    if (hold_total < 1)
        $fatal(1, "no bus_hold window was exercised across the run");
    if (stack_slot_checks < 20)
        $fatal(1, "only %0d stack slot checks ran across the run", stack_slot_checks);
    $display("PASS bus-cycle checks: assertions=%0d stalls=%0d holds=%0d stack_slots=%0d",
             assert_count, stall_total, hold_total, stack_slot_checks);
    $finish;
end

initial begin
    #5000000;
    for (k = 0; k < tr_count; k = k + 1)
        $display("TIMEOUT TRACE %0d %s %04h %02h state=%0d pc=%04h",
                 k, tr_we[k] ? "W" : "R", tr_addr[k], tr_we[k] ? tr_dout[k] : tr_din[k],
                 dbg_state, dbg_pc);
    $fatal(1, "global timeout, scenario [%0s] traces=%0d", scn, tr_count);
end

endmodule
