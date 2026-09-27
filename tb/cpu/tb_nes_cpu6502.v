`timescale 1ns/1ps

module tb_nes_cpu6502;

reg clk;
reg reset;
reg ce;
reg bus_hold;
reg [7:0] bus_din;
reg bus_ready;
reg nmi_i;
reg irq_i;
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
integer memory_index;
integer cycle_count;
integer stall_count;
integer reset_count;
integer trace_count;
integer wait_count;
reg reset_sequence_done;
reg stall_seen;
reg nmi_seen;
reg irq_seen;
reg hold_sample_valid;
reg [15:0] hold_addr_sample;
reg hold_we_sample;
reg [7:0] hold_dout_sample;
reg stall_sample_valid;
reg [15:0] stall_addr_sample;
reg stall_we_sample;
reg [7:0] stall_dout_sample;
reg [15:0] sw_addr_q0;
reg [15:0] sw_addr_q1;
reg [15:0] sw_addr_q2;
reg [7:0] sw_data_q0;
reg sp_check_pend;
reg [7:0] sp_check_expected;
reg reset_vec_check_pend;
integer stack_write_count;
integer stack_read_count;
integer int_push_count;
integer nmi_vector_count;
integer ffe_vector_count;

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
        cycle_count <= 0;
        stall_count <= 0;
        bus_hold <= 1'b0;
        reset_count <= 0;
        reset_sequence_done <= 1'b0;
        stall_seen <= 1'b0;
        nmi_seen <= 1'b0;
        irq_seen <= 1'b0;
        hold_sample_valid <= 1'b0;
        stall_sample_valid <= 1'b0;
        sw_addr_q0 <= 16'h0000;
        sw_addr_q1 <= 16'h0000;
        sw_addr_q2 <= 16'h0000;
        sw_data_q0 <= 8'h00;
        sp_check_pend = 1'b0;
        sp_check_expected = 8'h00;
        reset_vec_check_pend = 1'b0;
        stack_write_count = 0;
        stack_read_count = 0;
        int_push_count = 0;
        nmi_vector_count = 0;
        ffe_vector_count = 0;
    end else begin
        cycle_count <= cycle_count + 1;
        if (stall_count != 0)
            stall_count <= stall_count - 1;
        if (cycle_count == 24)
            stall_count <= 2;
        if ((cycle_count >= 38) && (cycle_count <= 40))
            bus_hold <= 1'b1;
        else
            bus_hold <= 1'b0;
        if (bus_req && !bus_ready) begin
            stall_seen <= 1'b1;
            if (stall_sample_valid &&
                ((bus_addr !== stall_addr_sample) || (bus_we !== stall_we_sample) || (bus_dout !== stall_dout_sample)))
                $fatal(1, "CPU bus outputs changed while stalled");
            stall_addr_sample <= bus_addr;
            stall_we_sample <= bus_we;
            stall_dout_sample <= bus_dout;
            stall_sample_valid <= 1'b1;
        end else begin
            stall_sample_valid <= 1'b0;
        end
        if (bus_hold) begin
            if (hold_sample_valid &&
                ((bus_addr !== hold_addr_sample) || (bus_we !== hold_we_sample) || (bus_dout !== hold_dout_sample)))
                $fatal(1, "CPU bus outputs changed while held");
            hold_addr_sample <= bus_addr;
            hold_we_sample <= bus_we;
            hold_dout_sample <= bus_dout;
            hold_sample_valid <= 1'b1;
        end else begin
            hold_sample_valid <= 1'b0;
        end
        if (nmi_i)
            nmi_seen <= 1'b1;
        if (irq_i)
            irq_seen <= 1'b1;
        if (reset_vec_check_pend) begin
            reset_vec_check_pend = 1'b0;
            if (dbg_pc !== 16'h8000)
                $fatal(1, "PC after the reset vector is %04h, expected 8000", dbg_pc);
            if (dbg_sp !== 8'hFD)
                $fatal(1, "SP after the reset vector is %02h, expected fd", dbg_sp);
            if (dbg_p !== 8'h24)
                $fatal(1, "P after the reset vector is %02h, expected 24", dbg_p);
        end
        if (!reset_sequence_done) begin
            if (bus_fire) begin
                reset_count <= reset_count + 1;
                if ((reset_count < 5) && (bus_addr != 16'h0000))
                    $fatal(1, "reset dummy address mismatch at count %0d", reset_count);
                if ((reset_count == 5) && (bus_addr != 16'hFFFC))
                    $fatal(1, "reset vector low address mismatch");
                if ((reset_count == 6) && (bus_addr != 16'hFFFD))
                    $fatal(1, "reset vector high address mismatch");
                if (reset_count == 6) begin
                    reset_sequence_done <= 1'b1;
                    reset_vec_check_pend = 1'b1;
                end
            end
        end
        if (sp_check_pend) begin
            sp_check_pend = 1'b0;
            if (dbg_sp !== sp_check_expected)
                $fatal(1, "SP is %02h after a stack push, expected $0100+SP-1 = %02h",
                       dbg_sp, sp_check_expected);
        end
        if (bus_fire && (bus_addr[15:8] == 8'h01)) begin
            if (bus_we) begin
                stack_write_count = stack_write_count + 1;
                if (bus_addr !== {8'h01, (dbg_sp - 8'd1)})
                    $fatal(1, "stack push to %04h with SP=%02h, expected $0100+(SP-1)=%04h",
                           bus_addr, dbg_sp, {8'h01, (dbg_sp - 8'd1)});
                sw_addr_q2 <= sw_addr_q1;
                sw_addr_q1 <= sw_addr_q0;
                sw_addr_q0 <= bus_addr;
                sw_data_q0 <= bus_dout;
                sp_check_pend = 1'b1;
                sp_check_expected = dbg_sp - 8'd1;
            end else begin
                stack_read_count = stack_read_count + 1;
                if (bus_addr !== {8'h01, dbg_sp})
                    $fatal(1, "stack pop from %04h with SP=%02h, expected $0100+SP=%04h",
                           bus_addr, dbg_sp, {8'h01, dbg_sp});
            end
        end
        if (bus_fire && !bus_we && ((bus_addr == 16'hFFFA) || (bus_addr == 16'hFFFE))) begin
            int_push_count = int_push_count + 1;
            if ((sw_addr_q0 !== 16'h01FA) || (sw_addr_q1 !== 16'h01FB) || (sw_addr_q2 !== 16'h01FC))
                $fatal(1, "interrupt pushes were $01%02h/$01%02h/$01%02h, expected $01fc/$01fb/$01fa",
                       sw_addr_q2[7:0], sw_addr_q1[7:0], sw_addr_q0[7:0]);
            if (sw_data_q0[5] !== 1'b1)
                $fatal(1, "pushed P %02h has the unused bit clear", sw_data_q0);
            if (bus_addr == 16'hFFFA) begin
                nmi_vector_count = nmi_vector_count + 1;
                if (sw_data_q0[4] !== 1'b0)
                    $fatal(1, "NMI pushed P %02h has the break flag set", sw_data_q0);
            end else begin
                ffe_vector_count = ffe_vector_count + 1;
                if (ffe_vector_count == 1) begin
                    if (sw_data_q0[4] !== 1'b1)
                        $fatal(1, "BRK pushed P %02h with the break flag clear", sw_data_q0);
                end else begin
                    if (sw_data_q0[4] !== 1'b0)
                        $fatal(1, "IRQ pushed P %02h with the break flag set", sw_data_q0);
                end
            end
        end
        if (bus_fire) begin
            trace_count = trace_count + 1;
            if (bus_we)
                $display("TRACE %0d PC=%04h ST=%0d OP=%02h A=%02h P=%02h %s %04h <- %02h", trace_count, dbg_pc, dbg_state, dbg_opcode, dbg_a, dbg_p, "W", bus_addr, bus_dout);
            else
                $display("TRACE %0d PC=%04h ST=%0d OP=%02h A=%02h P=%02h %s %04h -> %02h", trace_count, dbg_pc, dbg_state, dbg_opcode, dbg_a, dbg_p, "R", bus_addr, bus_din);
        end
    end
end

initial begin
    clk = 1'b0;
    reset = 1'b1;
    ce = 1'b1;
    bus_hold = 1'b0;
    nmi_i = 1'b0;
    irq_i = 1'b0;
    cycle_count = 0;
    stall_count = 0;
    reset_count = 0;
    trace_count = 0;
    wait_count = 0;
    reset_sequence_done = 1'b0;
    stall_seen = 1'b0;
    nmi_seen = 1'b0;
    irq_seen = 1'b0;
    hold_sample_valid = 1'b0;
    stall_sample_valid = 1'b0;
    reset_vec_check_pend = 1'b0;
    for (memory_index = 0; memory_index < 65536; memory_index = memory_index + 1)
        memory[memory_index] = 8'h00;

    memory[16'h8000] = 8'hA9;
    memory[16'h8001] = 8'h11;
    memory[16'h8002] = 8'h85;
    memory[16'h8003] = 8'h10;
    memory[16'h8004] = 8'hA2;
    memory[16'h8005] = 8'h03;
    memory[16'h8006] = 8'hA0;
    memory[16'h8007] = 8'h04;
    memory[16'h8008] = 8'h8A;
    memory[16'h8009] = 8'hAA;
    memory[16'h800A] = 8'h98;
    memory[16'h800B] = 8'hA8;
    memory[16'h800C] = 8'h18;
    memory[16'h800D] = 8'h69;
    memory[16'h800E] = 8'h02;
    memory[16'h800F] = 8'h38;
    memory[16'h8010] = 8'hE9;
    memory[16'h8011] = 8'h01;
    memory[16'h8012] = 8'h85;
    memory[16'h8013] = 8'h11;
    memory[16'h8014] = 8'hA5;
    memory[16'h8015] = 8'h10;
    memory[16'h8016] = 8'hC5;
    memory[16'h8017] = 8'h10;
    memory[16'h8018] = 8'hF0;
    memory[16'h8019] = 8'h02;
    memory[16'h801A] = 8'hEA;
    memory[16'h801B] = 8'hEA;
    memory[16'h801C] = 8'hA9;
    memory[16'h801D] = 8'h80;
    memory[16'h801E] = 8'h85;
    memory[16'h801F] = 8'h20;
    memory[16'h8020] = 8'h06;
    memory[16'h8021] = 8'h20;
    memory[16'h8022] = 8'hA5;
    memory[16'h8023] = 8'h20;
    memory[16'h8024] = 8'h69;
    memory[16'h8025] = 8'h01;
    memory[16'h8026] = 8'h38;
    memory[16'h8027] = 8'hE9;
    memory[16'h8028] = 8'h01;
    memory[16'h8029] = 8'h85;
    memory[16'h802A] = 8'h21;
    memory[16'h802B] = 8'h20;
    memory[16'h802C] = 8'h00;
    memory[16'h802D] = 8'h81;
    memory[16'h802E] = 8'h48;
    memory[16'h802F] = 8'h28;
    memory[16'h8030] = 8'hA2;
    memory[16'h8031] = 8'h02;
    memory[16'h8032] = 8'hB5;
    memory[16'h8033] = 8'h30;
    memory[16'h8034] = 8'h95;
    memory[16'h8035] = 8'h40;
    memory[16'h8036] = 8'hA0;
    memory[16'h8037] = 8'h01;
    memory[16'h8038] = 8'hB1;
    memory[16'h8039] = 8'h50;
    memory[16'h803A] = 8'h85;
    memory[16'h803B] = 8'h41;
    memory[16'h803C] = 8'h6C;
    memory[16'h803D] = 8'h70;
    memory[16'h803E] = 8'h00;
    memory[16'h8040] = 8'hA5;
    memory[16'h8041] = 8'h22;
    memory[16'h8042] = 8'hC9;
    memory[16'h8043] = 8'h01;
    memory[16'h8044] = 8'hD0;
    memory[16'h8045] = 8'hFA;
    memory[16'h8046] = 8'hA9;
    memory[16'h8047] = 8'h33;
    memory[16'h8048] = 8'h85;
    memory[16'h8049] = 8'h24;
    memory[16'h804A] = 8'h00;
    memory[16'h804B] = 8'h00;
    memory[16'h804C] = 8'hA5;
    memory[16'h804D] = 8'h23;
    memory[16'h804E] = 8'hC9;
    memory[16'h804F] = 8'h01;
    memory[16'h8050] = 8'hD0;
    memory[16'h8051] = 8'hFA;
    memory[16'h8052] = 8'h58;
    memory[16'h8053] = 8'h4C;
    memory[16'h8054] = 8'h58;
    memory[16'h8055] = 8'h80;
    memory[16'h8058] = 8'hA5;
    memory[16'h8059] = 8'h23;
    memory[16'h805A] = 8'hC9;
    memory[16'h805B] = 8'h02;
    memory[16'h805C] = 8'hD0;
    memory[16'h805D] = 8'hFA;
    memory[16'h805E] = 8'hA9;
    memory[16'h805F] = 8'h77;
    memory[16'h8060] = 8'h85;
    memory[16'h8061] = 8'h2F;
    memory[16'h8062] = 8'h4C;
    memory[16'h8063] = 8'h62;
    memory[16'h8064] = 8'h80;

    memory[16'h8100] = 8'h78;
    memory[16'h8101] = 8'hA9;
    memory[16'h8102] = 8'h81;
    memory[16'h8103] = 8'h4A;
    memory[16'h8104] = 8'h6A;
    memory[16'h8105] = 8'h2A;
    memory[16'h8106] = 8'hC6;
    memory[16'h8107] = 8'h72;
    memory[16'h8108] = 8'h48;
    memory[16'h8109] = 8'h68;
    memory[16'h810A] = 8'h38;
    memory[16'h810B] = 8'hA9;
    memory[16'h810C] = 8'h42;
    memory[16'h810D] = 8'h60;

    memory[16'h8300] = 8'hE6;
    memory[16'h8301] = 8'h22;
    memory[16'h8302] = 8'h40;
    memory[16'h8310] = 8'hE6;
    memory[16'h8311] = 8'h23;
    memory[16'h8312] = 8'h40;

    memory[16'h0030] = 8'h00;
    memory[16'h0032] = 8'h5A;
    memory[16'h0040] = 8'h00;
    memory[16'h0041] = 8'h00;
    memory[16'h0042] = 8'h00;
    memory[16'h0050] = 8'h60;
    memory[16'h0051] = 8'h00;
    memory[16'h0060] = 8'h5A;
    memory[16'h0061] = 8'h5B;
    memory[16'h0070] = 8'h40;
    memory[16'h0071] = 8'h80;

    memory[16'hFFFA] = 8'h00;
    memory[16'hFFFB] = 8'h83;
    memory[16'hFFFC] = 8'h00;
    memory[16'hFFFD] = 8'h80;
    memory[16'hFFFE] = 8'h10;
    memory[16'hFFFF] = 8'h83;

    #23;
    reset = 1'b0;
end

initial begin
    wait (reset_sequence_done == 1'b1);
    wait (dbg_pc >= 16'h8040 && dbg_pc <= 16'h8044);
    nmi_i = 1'b1;
    nmi_seen = 1'b1;
    repeat (3) @(posedge clk);
    nmi_i = 1'b0;
    wait (memory[16'h0022] == 8'h01);
    wait (dbg_pc == 16'h8052);
    irq_i = 1'b1;
    irq_seen = 1'b1;
    wait (dbg_pc >= 16'h8310 && dbg_pc <= 16'h8312);
    irq_i = 1'b0;
end

initial begin
    wait (reset_sequence_done == 1'b1);
    while ((memory[16'h002F] != 8'h77) && (wait_count < 30000)) begin
        @(posedge clk);
        wait_count = wait_count + 1;
    end
    if (memory[16'h002F] != 8'h77)
        $fatal(1, "timeout waiting for final marker, marker=%02h", memory[16'h002F]);
    repeat (3) @(posedge clk);
    if (reset_count != 7)
        $fatal(1, "reset transaction count was %0d", reset_count);
    if (!stall_seen)
        $fatal(1, "no injected stall was observed");
    if (!nmi_seen)
        $fatal(1, "NMI stimulus was not observed");
    if (!irq_seen)
        $fatal(1, "IRQ stimulus was not observed");
    if (dbg_pc !== 16'h8062)
        $fatal(1, "final PC mismatch: %04h", dbg_pc);
    if (dbg_a !== 8'h77)
        $fatal(1, "A mismatch: %02h", dbg_a);
    if (dbg_x !== 8'h02)
        $fatal(1, "X mismatch: %02h", dbg_x);
    if (dbg_y !== 8'h01)
        $fatal(1, "Y mismatch: %02h", dbg_y);
    if (dbg_sp !== 8'hFD)
        $fatal(1, "SP mismatch: %02h", dbg_sp);
    if (!dbg_p[5])
        $fatal(1, "P bit 5 is clear");
    if (dbg_p[0] !== 1'b1)
        $fatal(1, "carry flag mismatch: %02h", dbg_p);
    if (dbg_p[1] !== 1'b0)
        $fatal(1, "zero flag mismatch: %02h", dbg_p);
    if (dbg_p[2] !== 1'b0)
        $fatal(1, "interrupt flag mismatch: %02h", dbg_p);
    if (dbg_illegal)
        $fatal(1, "illegal opcode flag is set");
    if (dbg_nmi_pending)
        $fatal(1, "NMI pending flag is set at completion");
    if (dbg_irq_pending)
        $fatal(1, "IRQ pending flag is set at completion");
    if (memory[16'h0010] !== 8'h11)
        $fatal(1, "zero-page LDA/STA result mismatch: %02h", memory[16'h0010]);
    if (memory[16'h0011] !== 8'h05)
        $fatal(1, "ADC/SBC result mismatch: %02h", memory[16'h0011]);
    if (memory[16'h0020] !== 8'h00)
        $fatal(1, "ASL result mismatch: %02h", memory[16'h0020]);
    if (memory[16'h0021] !== 8'h01)
        $fatal(1, "SBC result mismatch: %02h", memory[16'h0021]);
    if (memory[16'h0022] !== 8'h01)
        $fatal(1, "NMI handler result mismatch: %02h", memory[16'h0022]);
    if (memory[16'h0023] !== 8'h02)
        $fatal(1, "BRK/IRQ handler result mismatch: %02h", memory[16'h0023]);
    if (memory[16'h0024] !== 8'h33)
        $fatal(1, "subroutine marker mismatch: %02h", memory[16'h0024]);
    if (memory[16'h0072] !== 8'hFF)
        $fatal(1, "DEC result mismatch: %02h", memory[16'h0072]);
    if (memory[16'h0032] !== 8'h5A)
        $fatal(1, "zero-page indexed read mismatch: %02h", memory[16'h0032]);
    if (memory[16'h0042] !== 8'h5A)
        $fatal(1, "zero-page indexed write mismatch: %02h", memory[16'h0042]);
    if (memory[16'h0041] !== 8'h5B)
        $fatal(1, "indirect indexed read mismatch: %02h", memory[16'h0041]);
    if (stack_write_count < 12)
        $fatal(1, "only %0d stack pushes were observed", stack_write_count);
    if (stack_read_count < 6)
        $fatal(1, "only %0d stack pops were observed", stack_read_count);
    if (int_push_count != 3)
        $fatal(1, "expected 3 interrupt vector fetches (brk, nmi, irq), saw %0d", int_push_count);
    if (nmi_vector_count != 1)
        $fatal(1, "expected 1 nmi vector fetch, saw %0d", nmi_vector_count);
    if (ffe_vector_count != 2)
        $fatal(1, "expected 2 brk/irq vector fetches, saw %0d", ffe_vector_count);
    $display("PASS PC=%04h A=%02h X=%02h Y=%02h SP=%02h P=%02h cycles=%0d pushes=%0d pops=%0d",
             dbg_pc, dbg_a, dbg_x, dbg_y, dbg_sp, dbg_p, cpu_cycle,
             stack_write_count, stack_read_count);
    $finish;
end

initial begin
    #1000000;
    $fatal(1, "global timeout");
end

endmodule
