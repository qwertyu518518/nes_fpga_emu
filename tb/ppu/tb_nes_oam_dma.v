`timescale 1ns/1ps

module tb_nes_oam_dma;

    reg clk;
    reg reset;
    reg start;
    reg [7:0] src_page;
    reg [7:0] oam_addr;
    reg [2:0] ack_delay;

    wire        a_hold;
    wire [15:0] a_read_addr;
    wire        a_read_req;
    wire        a_reg_cs;
    wire        a_reg_we;
    wire [2:0]  a_reg_addr;
    wire [7:0]  a_reg_dout;
    wire        a_busy;
    wire        a_done;
    wire [15:0] a_cycle;
    wire [7:0]  a_page;
    wire [7:0]  a_oam_addr;
    wire [7:0]  a_index;
    wire [1:0]  a_align_left;
    wire        a_addr_wr;

    wire        b_hold;
    wire [15:0] b_read_addr;
    wire        b_read_req;
    wire        b_reg_cs;
    wire        b_reg_we;
    wire [2:0]  b_reg_addr;
    wire [7:0]  b_reg_dout;
    wire        b_busy;
    wire        b_done;
    wire [15:0] b_cycle;
    wire [7:0]  b_page;
    wire [7:0]  b_oam_addr;
    wire [7:0]  b_index;
    wire [1:0]  b_align_left;
    wire        b_addr_wr;

    reg  [7:0]  src_mem [0:65535];
    reg  [7:0]  oam_a [0:255];
    reg  [7:0]  oam_b [0:255];
    reg  [7:0]  oam_hits [0:255];
    reg  [7:0]  oamaddr_a;
    reg  [7:0]  oamaddr_b;
    reg  [15:0] rd_seq [0:255];
    reg  [7:0]  wr_seq [0:255];
    reg  [7:0]  oam_seq [0:255];

    reg  [2:0]  wait_cnt;
    reg         parity_shadow;
    reg         prev_req;
    reg         prev_ack;
    reg  [15:0] prev_addr;
    reg         prev_cs;
    reg         prev_we;
    reg  [2:0]  prev_reg_addr;
    reg  [7:0]  prev_reg_dout;
    reg  [15:0] prev_cycle;

    integer hold_err;
    integer cyc_err;
    integer done_err;
    integer busy_prev_q;
    integer busy_slots;
    integer hold_cycles;
    integer done_pulses;
    integer rd_count;
    integer wr_count;
    integer idle_slots;
    integer req_slots;
    integer cs_slots;
    integer stab_err;
    integer streak_err;
    integer bad_addr_err;
    integer addr_wr_a_count;
    integer data_wr_a_count;
    integer addr_wr_b_count;
    integer data_wr_b_count;
    integer lock_err;
    integer i;
    integer k;
    reg  [7:0] idx8;
    reg  [7:0] exp8;
    reg  [1:0] align_len;

    wire       bus_req;
    wire       bus_ack;
    reg  [7:0] bus_data;

    assign bus_req  = a_read_req | b_read_req;
    assign bus_ack  = bus_req && (wait_cnt >= ack_delay);
    assign bus_data = bus_req ? src_mem[a_read_addr] : 8'h00;

    nes_oam_dma #(.OAMADDR_WRITE(1'b0)) dut (
        .clk(clk),
        .reset(reset),
        .start(start),
        .src_page(src_page),
        .oam_addr(oam_addr),
        .cpu_read_ack(bus_ack),
        .cpu_rdata(bus_data),
        .cpu_hold(a_hold),
        .cpu_read_addr(a_read_addr),
        .cpu_read_req(a_read_req),
        .ppu_reg_cs(a_reg_cs),
        .ppu_reg_we(a_reg_we),
        .ppu_reg_addr(a_reg_addr),
        .ppu_reg_dout(a_reg_dout),
        .busy(a_busy),
        .done(a_done),
        .cycle_count(a_cycle),
        .dbg_page(a_page),
        .dbg_oam_addr(a_oam_addr),
        .dbg_index(a_index),
        .dbg_align_left(a_align_left),
        .dbg_addr_wr(a_addr_wr)
    );

    nes_oam_dma #(.OAMADDR_WRITE(1'b1)) dut_addr (
        .clk(clk),
        .reset(reset),
        .start(start),
        .src_page(src_page),
        .oam_addr(oam_addr),
        .cpu_read_ack(bus_ack),
        .cpu_rdata(bus_data),
        .cpu_hold(b_hold),
        .cpu_read_addr(b_read_addr),
        .cpu_read_req(b_read_req),
        .ppu_reg_cs(b_reg_cs),
        .ppu_reg_we(b_reg_we),
        .ppu_reg_addr(b_reg_addr),
        .ppu_reg_dout(b_reg_dout),
        .busy(b_busy),
        .done(b_done),
        .cycle_count(b_cycle),
        .dbg_page(b_page),
        .dbg_oam_addr(b_oam_addr),
        .dbg_index(b_index),
        .dbg_align_left(b_align_left),
        .dbg_addr_wr(b_addr_wr)
    );

    always #5 clk = ~clk;

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            wait_cnt <= 3'd0;
        end else if (!bus_req) begin
            wait_cnt <= 3'd0;
        end else if (wait_cnt != 3'd7) begin
            wait_cnt <= wait_cnt + 3'd1;
        end
    end

    always @(posedge clk or posedge reset) begin
        if (reset)
            parity_shadow <= 1'b0;
        else
            parity_shadow <= ~parity_shadow;
    end

    always @(posedge clk) begin
        if (!reset) begin
            if (a_reg_cs && a_reg_we) begin
                if (a_reg_addr == 3'd3) begin
                    oamaddr_a <= a_reg_dout;
                    addr_wr_a_count = addr_wr_a_count + 1;
                end else if (a_reg_addr == 3'd4) begin
                    oam_a[oamaddr_a] <= a_reg_dout;
                    oam_hits[oamaddr_a] <= oam_hits[oamaddr_a] + 8'd1;
                    oamaddr_a <= oamaddr_a + 8'd1;
                    data_wr_a_count = data_wr_a_count + 1;
                end else begin
                    bad_addr_err = bad_addr_err + 1;
                end
            end
            if (b_reg_cs && b_reg_we) begin
                if (b_reg_addr == 3'd3) begin
                    oamaddr_b <= b_reg_dout;
                    addr_wr_b_count = addr_wr_b_count + 1;
                end else if (b_reg_addr == 3'd4) begin
                    oam_b[oamaddr_b] <= b_reg_dout;
                    oamaddr_b <= oamaddr_b + 8'd1;
                    data_wr_b_count = data_wr_b_count + 1;
                end else begin
                    bad_addr_err = bad_addr_err + 1;
                end
            end
        end
    end

    always @(posedge clk) begin
        if (reset) begin
            prev_req = 1'b0;
            prev_ack = 1'b0;
            prev_addr = 16'h0000;
            prev_cs = 1'b0;
            prev_we = 1'b0;
            prev_reg_addr = 3'd0;
            prev_reg_dout = 8'h00;
            prev_cycle = 16'd0;
            busy_prev_q = 0;
        end else begin
            if (bus_req && bus_ack) begin
                rd_seq[rd_count] = a_read_addr;
                rd_count = rd_count + 1;
            end
            if (a_reg_cs && a_reg_we && a_reg_addr == 3'd4) begin
                wr_seq[wr_count] = a_reg_dout;
                oam_seq[wr_count] = a_oam_addr;
                wr_count = wr_count + 1;
            end
            if (a_read_req !== b_read_req || a_read_addr !== b_read_addr)
                lock_err = lock_err + 1;
            if (a_busy !== b_busy || a_done !== b_done || a_cycle !== b_cycle)
                lock_err = lock_err + 1;
            if (b_reg_cs && (b_reg_addr != 3'd3)) begin
                if (!a_reg_cs || (a_reg_addr !== b_reg_addr) || (a_reg_dout !== b_reg_dout))
                    lock_err = lock_err + 1;
            end
            if (a_reg_cs && !b_reg_cs)
                lock_err = lock_err + 1;

            if (a_busy !== a_hold)
                hold_err = hold_err + 1;
            if (a_busy) begin
                busy_slots = busy_slots + 1;
                hold_cycles = hold_cycles + 1;
                if (a_cycle !== busy_slots)
                    cyc_err = cyc_err + 1;
                if (!a_read_req && !a_reg_cs)
                    idle_slots = idle_slots + 1;
                if (a_read_req)
                    req_slots = req_slots + 1;
                if (a_reg_cs)
                    cs_slots = cs_slots + 1;
            end else if ((busy_prev_q == 1) && (a_cycle !== busy_slots)) begin
                cyc_err = cyc_err + 1;
            end
            busy_prev_q = a_busy;

            if (a_done) begin
                done_pulses = done_pulses + 1;
                if (!a_busy || !a_reg_cs || (a_reg_addr != 3'd4) || (a_index != 8'hFF))
                    done_err = done_err + 1;
            end

            if (prev_req && !prev_ack) begin
                if (!a_read_req || (a_read_addr !== prev_addr))
                    stab_err = stab_err + 1;
                if (a_reg_cs !== 1'b0)
                    stab_err = stab_err + 1;
                if (a_done !== 1'b0)
                    stab_err = stab_err + 1;
                if (a_hold !== 1'b1)
                    stab_err = stab_err + 1;
                if (a_cycle !== (prev_cycle + 16'd1))
                    stab_err = stab_err + 1;
            end
            if (a_reg_cs && a_read_req)
                stab_err = stab_err + 1;
            if (prev_cs && a_reg_cs)
                streak_err = streak_err + 1;

            prev_req = a_read_req;
            prev_ack = bus_ack;
            prev_addr = a_read_addr;
            prev_cs = a_reg_cs;
            prev_we = a_reg_we;
            prev_cycle = a_cycle;
            prev_reg_addr = a_reg_addr;
            prev_reg_dout = a_reg_dout;
        end
    end

    task expect_idle;
        input [8*12-1:0] tag;
        begin
            if (a_busy !== 1'b0) $fatal(1, "%0s: busy got %b", tag, a_busy);
            if (a_hold !== 1'b0) $fatal(1, "%0s: cpu_hold got %b", tag, a_hold);
            if (a_done !== 1'b0) $fatal(1, "%0s: done got %b", tag, a_done);
            if (a_read_req !== 1'b0) $fatal(1, "%0s: cpu_read_req got %b", tag, a_read_req);
            if (a_reg_cs !== 1'b0) $fatal(1, "%0s: ppu_reg_cs got %b", tag, a_reg_cs);
            if (a_reg_we !== 1'b0) $fatal(1, "%0s: ppu_reg_we got %b", tag, a_reg_we);
            if (a_cycle !== 16'd0) $fatal(1, "%0s: cycle_count got %0d", tag, a_cycle);
            if (a_index !== 8'd0) $fatal(1, "%0s: dbg_index got %01h", tag, a_index);
            if (a_oam_addr !== 8'd0) $fatal(1, "%0s: dbg_oam_addr got %01h", tag, a_oam_addr);
            if (a_addr_wr !== 1'b0) $fatal(1, "%0s: dbg_addr_wr got %b", tag, a_addr_wr);
        end
    endtask

    task fill_src;
        input [7:0] page;
        input [7:0] seed;
        begin
            for (i = 0; i < 256; i = i + 1) begin
                idx8 = i;
                src_mem[{page, idx8}] = seed + i[7:0];
            end
        end
    endtask

    task clear_oam;
        input [7:0] fill;
        begin
            for (i = 0; i < 256; i = i + 1) begin
                idx8 = i;
                oam_a[idx8] = fill + i[7:0];
                oam_b[idx8] = fill + i[7:0];
                oam_hits[idx8] = 8'd0;
            end
        end
    endtask

    task wait_align;
        input [1:0] want;
        begin
            while ((parity_shadow ? 2'd2 : 2'd1) != want) @(negedge clk);
        end
    endtask

    task reset_counters;
        begin
            hold_err = 0;
            cyc_err = 0;
            done_err = 0;
            busy_prev_q = 0;
            busy_slots = 0;
            hold_cycles = 0;
            done_pulses = 0;
            rd_count = 0;
            wr_count = 0;
            idle_slots = 0;
            req_slots = 0;
            cs_slots = 0;
            stab_err = 0;
            streak_err = 0;
            bad_addr_err = 0;
            addr_wr_a_count = 0;
            data_wr_a_count = 0;
            addr_wr_b_count = 0;
            data_wr_b_count = 0;
            lock_err = 0;
        end
    endtask

    task check_first_align;
        input [1:0] want;
        input [7:0] page;
        input [7:0] base;
        begin
            align_len = a_align_left;
            if (align_len != want)
                $fatal(1, "ALIGN: first cycle dbg_align_left got %0d expected %0d",
                       align_len, want);
            if (a_busy !== 1'b1) $fatal(1, "ALIGN: busy not set in the first cycle");
            if (a_hold !== 1'b1) $fatal(1, "ALIGN: cpu_hold not set in the first cycle");
            if (a_done !== 1'b0) $fatal(1, "ALIGN: done set in the first cycle");
            if (a_read_req !== 1'b0) $fatal(1, "ALIGN: cpu_read_req set in the first cycle");
            if (a_reg_cs !== 1'b0) $fatal(1, "ALIGN: dut emitted a PPU write");
            if (a_addr_wr !== 1'b0) $fatal(1, "ALIGN: dut dbg_addr_wr set");
            if (a_cycle !== 16'd1) $fatal(1, "ALIGN: cycle_count got %0d expected 1", a_cycle);
            if (a_index !== 8'd0) $fatal(1, "ALIGN: dbg_index got %01h expected 00", a_index);
            if (a_page !== page)
                $fatal(1, "ALIGN: dbg_page got %01h expected %01h", a_page, page);
            if (a_oam_addr !== base)
                $fatal(1, "ALIGN: dbg_oam_addr got %01h expected %01h", a_oam_addr, base);
            if (a_read_addr !== {page, 8'h00})
                $fatal(1, "ALIGN: cpu_read_addr got %04h expected %04h",
                       a_read_addr, {page, 8'h00});
            if (want == 2'd1) begin
                if (b_reg_cs !== 1'b1 || (b_reg_addr != 3'd3) || (b_reg_dout !== base))
                    $fatal(1, "ALIGN: single align cycle misses the $2003 write cs=%b addr=%0d dout=%01h",
                           b_reg_cs, b_reg_addr, b_reg_dout);
                if (b_addr_wr !== 1'b1) $fatal(1, "ALIGN: dut_addr dbg_addr_wr not set");
            end else begin
                if (b_reg_cs !== 1'b0) $fatal(1, "ALIGN: $2003 write came one cycle early");
                if (b_addr_wr !== 1'b0) $fatal(1, "ALIGN: dbg_addr_wr set too early");
                @(negedge clk);
                if (b_reg_cs !== 1'b1 || (b_reg_addr != 3'd3) || (b_reg_dout !== base))
                    $fatal(1, "ALIGN: second align cycle misses the $2003 write cs=%b addr=%0d dout=%01h",
                           b_reg_cs, b_reg_addr, b_reg_dout);
                if (a_reg_cs !== 1'b0) $fatal(1, "ALIGN: dut emitted a PPU write");
                if (a_read_req !== 1'b0)
                    $fatal(1, "ALIGN: cpu_read_req set during the second align cycle");
                if (a_busy !== 1'b1) $fatal(1, "ALIGN: busy dropped during the second align cycle");
                if (a_cycle !== 16'd2)
                    $fatal(1, "ALIGN: cycle_count got %0d expected 2", a_cycle);
            end
        end
    endtask

    task wait_transfer_done;
        input [7:0] base;
        begin
            while (a_done !== 1'b1) @(negedge clk);
            if (a_reg_cs !== 1'b1 || (a_reg_addr != 3'd4))
                $fatal(1, "DONE: final cycle is not a $2004 write cs=%b addr=%0d",
                       a_reg_cs, a_reg_addr);
            if (a_index !== 8'hFF)
                $fatal(1, "DONE: dbg_index got %01h expected FF", a_index);
            if (a_read_req !== 1'b0)
                $fatal(1, "DONE: cpu_read_req set on the final cycle");
            if (a_oam_addr !== ((base + 8'd255) & 8'hFF))
                $fatal(1, "DONE: dbg_oam_addr got %01h expected %01h",
                       a_oam_addr, (base + 8'd255) & 8'hFF);
            @(negedge clk);
            if (a_done !== 1'b0) $fatal(1, "DONE: done wider than one cycle");
        end
    endtask

    task run_dma;
        input [7:0] page;
        input [7:0] base;
        input [2:0] delay;
        input [1:0] want;
        begin
            src_page = page;
            oam_addr = base;
            ack_delay = delay;
            oamaddr_a = base;
            oamaddr_b = base;
            reset_counters;
            clear_oam(8'h40);
            wait_align(want);
            start = 1'b1;
            @(negedge clk);
            start = 1'b0;
            check_first_align(want, page, base);
            wait_transfer_done(base);
        end
    endtask

    task check_common;
        input [15:0] expect_cycles;
        input [7:0] page;
        input [7:0] base;
        input [1:0] expect_align;
        begin
            if (a_cycle !== expect_cycles)
                $fatal(1, "CYCLE: cycle_count got %0d expected %0d", a_cycle, expect_cycles);
            if (b_cycle !== expect_cycles)
                $fatal(1, "CYCLE: dut_addr cycle_count got %0d expected %0d",
                       b_cycle, expect_cycles);
            if (hold_cycles !== expect_cycles)
                $fatal(1, "CYCLE: busy cycles got %0d expected %0d",
                       hold_cycles, expect_cycles);
            if (a_busy !== 1'b0) $fatal(1, "CYCLE: busy still high after done");
            if (a_hold !== 1'b0) $fatal(1, "CYCLE: cpu_hold still high after done");
            if (done_pulses !== 1)
                $fatal(1, "CYCLE: done pulses got %0d expected 1", done_pulses);
            if (rd_count !== 256)
                $fatal(1, "SEQ: acked reads got %0d expected 256", rd_count);
            if (wr_count !== 256)
                $fatal(1, "SEQ: $2004 writes got %0d expected 256", wr_count);
            if (data_wr_a_count !== 256)
                $fatal(1, "SEQ: dut $2004 writes got %0d expected 256", data_wr_a_count);
            if (data_wr_b_count !== 256)
                $fatal(1, "SEQ: dut_addr $2004 writes got %0d expected 256", data_wr_b_count);
            if (addr_wr_a_count !== 0)
                $fatal(1, "SEQ: dut emitted %0d $2003 writes expected 0", addr_wr_a_count);
            if (addr_wr_b_count !== 1)
                $fatal(1, "SEQ: dut_addr emitted %0d $2003 writes expected 1",
                       addr_wr_b_count);
            if (idle_slots !== expect_align)
                $fatal(1, "ALIGN: silent busy cycles got %0d expected %0d",
                       idle_slots, expect_align);
            if (req_slots !== (256 + 256 * ack_delay))
                $fatal(1, "ALIGN: read cycles got %0d expected %0d",
                       req_slots, 256 + 256 * ack_delay);
            if (cs_slots !== 256)
                $fatal(1, "ALIGN: dut PPU write cycles got %0d expected 256", cs_slots);
            if (hold_err !== 0) $fatal(1, "HOLD: cpu_hold != busy in %0d cycles", hold_err);
            if (cyc_err !== 0)
                $fatal(1, "CYCLE: cycle_count mismatch in %0d cycles", cyc_err);
            if (done_err !== 0)
                $fatal(1, "DONE: contract violation in %0d cycles", done_err);
            if (stab_err !== 0)
                $fatal(1, "STABLE: an output changed during a wait in %0d cases", stab_err);
            if (streak_err !== 0)
                $fatal(1, "STABLE: a PPU write lasted more than one cycle in %0d cases",
                       streak_err);
            if (bad_addr_err !== 0)
                $fatal(1, "ADDR: unexpected PPU register address %0d times", bad_addr_err);
            if (lock_err !== 0)
                $fatal(1, "LOCK: the two instances diverged in %0d cycles", lock_err);
            for (k = 0; k < 256; k = k + 1) begin
                idx8 = k;
                if (oam_hits[idx8] !== 8'd1)
                    $fatal(1, "SEQ: OAM[%02h] was written %0d times expected 1",
                           idx8, oam_hits[idx8]);
                exp8 = (base + idx8) & 8'hFF;
                if (rd_seq[k] !== {page, idx8})
                    $fatal(1, "SEQ: read %0d address got %04h expected %04h",
                           k, rd_seq[k], {page, idx8});
                if (wr_seq[k] !== src_mem[{page, idx8}])
                    $fatal(1, "SEQ: write %0d data got %01h expected %01h",
                           k, wr_seq[k], src_mem[{page, idx8}]);
                if (oam_seq[k] !== exp8)
                    $fatal(1, "SEQ: write %0d OAM address got %01h expected %01h",
                           k, oam_seq[k], exp8);
                if (oam_a[exp8] !== src_mem[{page, idx8}])
                    $fatal(1, "DATA: oam_a[%02h] got %01h expected %01h",
                           exp8, oam_a[exp8], src_mem[{page, idx8}]);
                if (oam_b[exp8] !== src_mem[{page, idx8}])
                    $fatal(1, "DATA: oam_b[%02h] got %01h expected %01h",
                           exp8, oam_b[exp8], src_mem[{page, idx8}]);
            end
        end
    endtask

    task test_reset_and_idle;
        begin
            reset = 1'b1;
            start = 1'b0;
            src_page = 8'h00;
            oam_addr = 8'h00;
            ack_delay = 3'd0;
            reset_counters;
            clear_oam(8'h40);
            #1;
            expect_idle("RESET");
            repeat (4) @(negedge clk);
            expect_idle("RESET");
            @(negedge clk);
            reset = 1'b0;
            @(negedge clk);
            expect_idle("IDLE");
            repeat (8) @(negedge clk);
            expect_idle("IDLE");
            if (a_read_addr !== 16'h0000)
                $fatal(1, "IDLE: cpu_read_addr got %04h expected 0000", a_read_addr);
            if (a_reg_addr !== 3'd3)
                $fatal(1, "IDLE: ppu_reg_addr got %0d expected 3", a_reg_addr);
            if (a_reg_dout !== 8'h00)
                $fatal(1, "IDLE: ppu_reg_dout got %01h expected 00", a_reg_dout);
            $display("OAMDMA reset values and idle outputs PASS");
        end
    endtask

    task test_order_and_page;
        begin
            fill_src(8'h02, 8'h10);
            run_dma(8'h02, 8'h00, 3'd0, 2'd1);
            check_common(16'd513, 8'h02, 8'h00, 2'd1);

            fill_src(8'h02, 8'h10);
            run_dma(8'h02, 8'h00, 3'd0, 2'd2);
            check_common(16'd514, 8'h02, 8'h00, 2'd2);

            fill_src(8'h20, 8'hA5);
            run_dma(8'h20, 8'h00, 3'd0, 2'd1);
            check_common(16'd513, 8'h20, 8'h00, 2'd1);

            fill_src(8'h7F, 8'h01);
            run_dma(8'h7F, 8'h00, 3'd0, 2'd2);
            check_common(16'd514, 8'h7F, 8'h00, 2'd2);

            fill_src(8'h80, 8'h5C);
            run_dma(8'h80, 8'h00, 3'd0, 2'd1);
            check_common(16'd513, 8'h80, 8'h00, 2'd1);

            fill_src(8'hFF, 8'hF0);
            run_dma(8'hFF, 8'h00, 3'd0, 2'd2);
            check_common(16'd514, 8'hFF, 8'h00, 2'd2);
            $display("OAMDMA 256 byte order and source page addressing PASS");
        end
    endtask

    task test_oamaddr_wrap;
        begin
            fill_src(8'h05, 8'h11);
            run_dma(8'h05, 8'h30, 3'd0, 2'd1);
            check_common(16'd513, 8'h05, 8'h30, 2'd1);

            fill_src(8'h05, 8'h22);
            run_dma(8'h05, 8'hF8, 3'd0, 2'd2);
            check_common(16'd514, 8'h05, 8'hF8, 2'd2);

            fill_src(8'h05, 8'h33);
            run_dma(8'h05, 8'hFF, 3'd0, 2'd1);
            check_common(16'd513, 8'h05, 8'hFF, 2'd1);

            fill_src(8'h05, 8'h44);
            run_dma(8'h05, 8'h01, 3'd0, 2'd2);
            check_common(16'd514, 8'h05, 8'h01, 2'd2);
            $display("OAMDMA non-zero OAMADDR start and 255 to 0 wraparound PASS");
        end
    endtask

    task test_ack_delay;
        begin
            fill_src(8'h06, 8'h77);
            run_dma(8'h06, 8'h00, 3'd1, 2'd1);
            check_common(16'd513 + 16'd256, 8'h06, 8'h00, 2'd1);

            fill_src(8'h06, 8'h88);
            run_dma(8'h06, 8'h40, 3'd2, 2'd2);
            check_common(16'd514 + 16'd512, 8'h06, 8'h40, 2'd2);

            fill_src(8'h06, 8'h99);
            run_dma(8'h06, 8'hC0, 3'd3, 2'd1);
            check_common(16'd513 + 16'd768, 8'h06, 8'hC0, 2'd1);
            $display("OAMDMA delayed read ack keeps the transfer correct PASS");
        end
    endtask

    task test_wait_stability;
        integer waited;
        reg [15:0] addr_hold;
        begin
            clear_oam(8'h40);
            fill_src(8'h09, 8'h3C);
            src_page = 8'h09;
            oam_addr = 8'h00;
            ack_delay = 3'd4;
            oamaddr_a = 8'h00;
            oamaddr_b = 8'h00;
            reset_counters;
            wait_align(2'd1);
            start = 1'b1;
            @(negedge clk);
            start = 1'b0;
            while (a_read_req !== 1'b1) @(negedge clk);
            addr_hold = a_read_addr;
            for (waited = 0; waited < 5; waited = waited + 1) begin
                if (a_read_req !== 1'b1)
                    $fatal(1, "STABLE: cpu_read_req dropped after %0d wait cycles", waited);
                if (a_read_addr !== addr_hold)
                    $fatal(1, "STABLE: cpu_read_addr moved to %04h after %0d waits",
                           a_read_addr, waited);
                if (a_reg_cs !== 1'b0)
                    $fatal(1, "STABLE: PPU write during read wait %0d", waited);
                if (a_cycle !== (16'd2 + waited))
                    $fatal(1, "STABLE: cycle_count got %0d expected %0d",
                           a_cycle, 16'd2 + waited);
                if (waited < 4 && bus_ack)
                    $fatal(1, "STABLE: ack arrived early after %0d wait cycles", waited);
                if (waited == 4 && !bus_ack)
                    $fatal(1, "STABLE: ack did not arrive in the fourth wait cycle");
                if (waited < 4) @(negedge clk);
            end
            if (a_read_addr !== addr_hold)
                $fatal(1, "STABLE: cpu_read_addr moved on the ack cycle");
            if (a_reg_cs !== 1'b0)
                $fatal(1, "STABLE: PPU write on the ack boundary cycle");
            if (a_index !== 8'd0)
                $fatal(1, "STABLE: dbg_index moved to %01h on the ack cycle", a_index);
            @(negedge clk);
            if (a_reg_cs !== 1'b1 || (a_reg_addr != 3'd4))
                $fatal(1, "STABLE: the cycle after the ack is not a $2004 write");
            if (a_reg_dout !== src_mem[{8'h09, 8'h00}])
                $fatal(1, "STABLE: first $2004 payload got %01h expected %01h",
                       a_reg_dout, src_mem[{8'h09, 8'h00}]);
            if (a_read_addr !== {8'h09, 8'h01})
                $fatal(1, "STABLE: cpu_read_addr got %04h expected 0901 after one byte",
                       a_read_addr);
            while (a_done !== 1'b1) @(negedge clk);
            if (a_reg_cs !== 1'b1 || (a_reg_addr != 3'd4))
                $fatal(1, "STABLE: final cycle is not a $2004 write");
            @(negedge clk);
            check_common(16'd513 + 16'd1024, 8'h09, 8'h00, 2'd1);
            $display("OAMDMA four-cycle ack wait holds request, address and data stable PASS");
        end
    endtask

    task test_start_ignored;
        begin
            clear_oam(8'h40);
            fill_src(8'h07, 8'h2D);
            src_page = 8'h07;
            oam_addr = 8'h10;
            ack_delay = 3'd0;
            oamaddr_a = 8'h10;
            oamaddr_b = 8'h10;
            reset_counters;
            wait_align(2'd1);
            start = 1'b1;
            @(negedge clk);
            start = 1'b0;
            repeat (40) @(negedge clk);
            if (a_busy !== 1'b1) $fatal(1, "RESTART: busy dropped in mid transfer");
            if (a_hold !== 1'b1) $fatal(1, "RESTART: cpu_hold dropped in mid transfer");
            start = 1'b1;
            @(negedge clk);
            start = 1'b0;
            if (a_busy !== 1'b1) $fatal(1, "RESTART: busy dropped on the extra start");
            wait_transfer_done(8'h10);
            check_common(16'd513, 8'h07, 8'h10, 2'd1);
            $display("OAMDMA start pulse during busy is ignored PASS");
        end
    endtask

    task test_reset_abort;
        begin
            clear_oam(8'h40);
            fill_src(8'h08, 8'h6E);
            src_page = 8'h08;
            oam_addr = 8'h00;
            ack_delay = 3'd1;
            oamaddr_a = 8'h00;
            oamaddr_b = 8'h00;
            reset_counters;
            wait_align(2'd2);
            start = 1'b1;
            @(negedge clk);
            start = 1'b0;
            repeat (30) @(negedge clk);
            if (a_busy !== 1'b1) $fatal(1, "ABORT: busy dropped before the reset");
            reset = 1'b1;
            #1;
            expect_idle("ABORT");
            reset = 1'b0;
            @(negedge clk);
            clear_oam(8'h40);
            fill_src(8'h08, 8'h6E);
            run_dma(8'h08, 8'h00, 3'd1, 2'd1);
            check_common(16'd513 + 16'd256, 8'h08, 8'h00, 2'd1);
            $display("OAMDMA reset aborts a transfer and the next transfer still works PASS");
        end
    endtask

    task test_back_to_back;
        begin
            fill_src(8'h0A, 8'h13);
            run_dma(8'h0A, 8'h00, 3'd0, 2'd2);
            check_common(16'd514, 8'h0A, 8'h00, 2'd2);

            fill_src(8'h0B, 8'h24);
            run_dma(8'h0B, 8'h80, 3'd0, 2'd2);
            check_common(16'd514, 8'h0B, 8'h80, 2'd2);

            fill_src(8'h0C, 8'h35);
            run_dma(8'h0C, 8'hFE, 3'd0, 2'd1);
            check_common(16'd513, 8'h0C, 8'hFE, 2'd1);
            $display("OAMDMA consecutive transfers restart the cycle counter PASS");
        end
    endtask

    initial begin
        clk = 1'b0;
        test_reset_and_idle;
        test_order_and_page;
        test_oamaddr_wrap;
        test_ack_delay;
        test_wait_stability;
        test_start_ignored;
        test_reset_abort;
        test_back_to_back;
        $display("PASS nes_oam_dma");
        $finish;
    end

    initial begin
        #2000000;
        $fatal(1, "global timeout");
    end

endmodule
