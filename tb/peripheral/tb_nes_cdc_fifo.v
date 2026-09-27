`timescale 1ns/1ps

// nes_cdc_fifo testbench: 10 ns write clock against a deliberately unrelated
// 14 ns read clock, so every crossing is exercised with both phases and both
// ratios drifting against each other.
//
// Reference model
//   The model is driven by what the DUT actually accepts, sampled on the
//   negative edge of each clock, which is the exact value of the flag the
//   coming positive edge will use. Accepted writes push into mb_mem, accepted
//   reads pop the head, and every accepted read compares the registered
//   rd_data against the popped entry. Because the write side is the sole
//   authority on its own pointer, and the read side only ever reads an address
//   whose data was committed at least two read clocks earlier, model and DUT
//   occupancy stay identical, so a match proves no entry was lost, duplicated
//   or reordered.
//
// Phases
//   0  joint reset, flag polarity
//   1  fill to depth, wr_full timing, rejection of the overflow word, drain
//   2  empty read attempt must not move the pointer nor disturb rd_data
//   3  10000 interleaved random enable decisions, full data comparison, drain
//   4  each reset asserted on its own, no hang, flags recoverable, then a
//      joint reset and a clean round trip

module tb_nes_cdc_fifo;

    localparam integer DATA_WIDTH = 32;
    localparam integer ADDR_WIDTH = 10;
    localparam integer DEPTH     = (1 << ADDR_WIDTH);
    localparam integer RAND_CYCLES = 10000;

    localparam [DATA_WIDTH-1:0] BAD_VALUE = 32'hdeadc0de;
    localparam [DATA_WIDTH-1:0] BAD_SEQ   = 32'hbad0bad0;

    reg wr_clk = 1'b0;
    reg rd_clk = 1'b0;
    reg wr_reset = 1'b1;
    reg rd_reset = 1'b1;
    reg wr_en = 1'b0;
    reg rd_en = 1'b0;
    reg [DATA_WIDTH-1:0] wr_data = {DATA_WIDTH{1'b0}};

    wire wr_full;
    wire rd_empty;
    wire [DATA_WIDTH-1:0] rd_data;

    reg [DATA_WIDTH-1:0] mb_mem [0:DEPTH-1];
    integer mb_head = 0;
    integer mb_tail = 0;
    integer mb_count = 0;
    integer mb_pushes = 0;
    integer mb_pops = 0;

    reg                 wr_run = 1'b0;
    reg [DATA_WIDTH-1:0] wr_word = {DATA_WIDTH{1'b0}};
    reg [DATA_WIDTH-1:0] wr_next = {DATA_WIDTH{1'b0}};
    reg                 wr_adv = 1'b0;

    reg                 rd_run = 1'b0;
    reg [DATA_WIDTH-1:0] rd_exp = {DATA_WIDTH{1'b0}};
    reg                 rd_adv = 1'b0;

    reg                 phase_rand = 1'b0;
    reg                 model_en = 1'b1;
    reg                 tb_live = 1'b0;
    reg                 prev_empty = 1'b1;
    reg [DATA_WIDTH-1:0] prev_data = {DATA_WIDTH{1'b0}};

    integer n_wr_cycles = 0;
    integer n_rd_cycles = 0;
    integer n_rand_cycles = 0;
    integer i;
    integer guard;
    integer drain_guard;
    integer pending;
    integer wr_before;
    integer rd_before;

    reg wen_next;
    reg ren_next;
    integer urand;

    nes_cdc_fifo #(
        .DATA_WIDTH(DATA_WIDTH),
        .ADDR_WIDTH(ADDR_WIDTH)
    ) dut (
        .wr_clk   (wr_clk),
        .wr_reset (wr_reset),
        .wr_en    (wr_en),
        .wr_data  (wr_data),
        .wr_full  (wr_full),
        .rd_clk   (rd_clk),
        .rd_reset (rd_reset),
        .rd_en    (rd_en),
        .rd_data  (rd_data),
        .rd_empty (rd_empty)
    );

    always #5 wr_clk = ~wr_clk;
    always #7 rd_clk = ~rd_clk;

    task mb_push;
        input [DATA_WIDTH-1:0] d;
        begin
            if (mb_count >= DEPTH)
                $fatal(1, "MB_OVERFLOW: model holds %0d entries", mb_count);
            mb_mem[mb_tail] = d;
            mb_tail = (mb_tail == DEPTH-1) ? 0 : mb_tail + 1;
            mb_count = mb_count + 1;
            mb_pushes = mb_pushes + 1;
        end
    endtask

    task mb_pop;
        input [DATA_WIDTH-1:0] d;
        begin
            if (mb_count == 0)
                $fatal(1, "MB_UNDERFLOW: DUT read %h with an empty model", d);
            if (d !== mb_mem[mb_head])
                $fatal(1, "MB_MISMATCH: read %h expected %h", d, mb_mem[mb_head]);
            mb_head = (mb_head == DEPTH-1) ? 0 : mb_head + 1;
            mb_count = mb_count - 1;
            mb_pops = mb_pops + 1;
        end
    endtask

    task model_clear;
        begin
            mb_head   = 0;
            mb_tail   = 0;
            mb_count  = 0;
            mb_pushes = 0;
            mb_pops   = 0;
        end
    endtask

    task wr_one;
        input [DATA_WIDTH-1:0] d;
        input integer          expect_accept;
        begin
            @(posedge wr_clk); #1;
            wr_word = d;
            wr_run  = 1'b1;
            @(negedge wr_clk); #1;
            if ((expect_accept != 2) && (wr_adv != expect_accept))
                $fatal(1, "WR_ACCEPT: word %h accepted=%0d expected %0d (wr_full=%b)",
                       d, wr_adv, expect_accept, wr_full);
            @(negedge wr_clk);
        end
    endtask

    task rd_one;
        input [DATA_WIDTH-1:0] expected;
        input integer          expect_accept;
        begin
            @(posedge rd_clk); #1;
            rd_exp = expected;
            rd_run = 1'b1;
            @(negedge rd_clk); #1;
            if (rd_adv != expect_accept)
                $fatal(1, "RD_ACCEPT: expected=%h accepted=%0d expected %0d (rd_empty=%b)",
                       expected, rd_adv, expect_accept, rd_empty);
            @(posedge rd_clk); #1;
            if (rd_adv && rd_data !== expected)
                $fatal(1, "RD_DATA: read %h expected %h", rd_data, expected);
            @(negedge rd_clk);
        end
    endtask

    task rd_drop;
        begin
            @(posedge rd_clk); #1;
            rd_run = 1'b1;
            @(negedge rd_clk); #1;
            @(posedge rd_clk); #1;
        end
    endtask

    task do_reset;
        input integer hold_cycles;
        begin
            tb_live = 1'b0;
            wr_reset = 1'b1;
            rd_reset = 1'b1;
            @(posedge wr_clk);
            @(posedge rd_clk);
            repeat (hold_cycles) @(posedge wr_clk);
            #1;
            wr_reset = 1'b0;
            rd_reset = 1'b0;
            repeat (4) @(posedge wr_clk);
            repeat (4) @(posedge rd_clk);
            tb_live = 1'b1;
        end
    endtask

    task drain_and_check;
        begin
            if (mb_count > 0) begin
                guard = 0;
                while (rd_empty !== 1'b0) begin
                    if (guard > 64)
                        $fatal(1, "DRAIN_WAIT: rd_empty stayed high with %0d entries queued",
                               mb_count);
                    @(posedge rd_clk); #1;
                    guard = guard + 1;
                end
            end
            drain_guard = 0;
            while (mb_count > 0) begin
                if (drain_guard > 20000)
                    $fatal(1, "DRAIN_HANG: %0d entries left in the model", mb_count);
                rd_one(mb_mem[mb_head], 1'b1);
                drain_guard = drain_guard + 1;
            end
            guard = 0;
            while (rd_empty !== 1'b1) begin
                if (guard > 2000)
                    $fatal(1, "EMPTY_HANG: rd_empty never asserted after the drain");
                @(posedge rd_clk);
                guard = guard + 1;
            end
        end
    endtask

    always @(negedge wr_clk) begin
        n_wr_cycles = n_wr_cycles + 1;
        if (phase_rand) begin
            urand = $random & 32'h7fffffff;
            wen_next = ((urand % 100) < 60);
            wr_data <= wr_next;
            wr_en   <= wen_next;
            wr_adv  <= wen_next && !wr_full;
            if (model_en && wen_next && !wr_full) begin
                mb_push(wr_next);
                wr_next = wr_next + 1;
            end
        end else begin
            wr_data <= wr_word;
            wr_en   <= wr_run;
            wr_adv  <= wr_run && !wr_full;
            if (model_en && wr_run && !wr_full)
                mb_push(wr_word);
            wr_run <= 1'b0;
        end
    end

    always @(negedge rd_clk) begin
        n_rd_cycles = n_rd_cycles + 1;
        if (phase_rand) begin
            urand = $random & 32'h7fffffff;
            ren_next = ((urand % 100) < 60);
            rd_en  <= ren_next;
            rd_adv <= ren_next && !rd_empty;
            if (model_en && ren_next && !rd_empty) begin
                rd_exp = mb_mem[mb_head];
                mb_pop(rd_exp);
            end
            n_rand_cycles = n_rand_cycles + 1;
        end else begin
            rd_en  <= rd_run;
            rd_adv <= rd_run && !rd_empty;
            if (model_en && rd_run && !rd_empty)
                mb_pop(rd_exp);
            rd_run <= 1'b0;
        end
    end

    always @(posedge rd_clk) begin
        #1;
        if (tb_live && model_en && rd_adv && rd_data !== rd_exp)
            $fatal(1, "RD_DATA: read %h expected %h", rd_data, rd_exp);
    end

    always @(negedge rd_clk) begin
        prev_empty = rd_empty;
        prev_data  = rd_data;
    end

    always @(posedge rd_clk) begin
        #1;
        if (tb_live && prev_empty && (rd_data !== prev_data))
            $fatal(1, "RD_HOLD: rd_data changed to %h while rd_empty was 1", rd_data);
    end

    initial begin
        for (i = 0; i < DEPTH; i = i + 1)
            mb_mem[i] = {DATA_WIDTH{1'b0}};

        do_reset(6);

        if (wr_full !== 1'b0)
            $fatal(1, "RESET: wr_full=%b after reset, expected 0", wr_full);
        if (rd_empty !== 1'b1)
            $fatal(1, "RESET: rd_empty=%b after reset, expected 1", rd_empty);
        if (wr_full === 1'bx || rd_empty === 1'bx)
            $fatal(1, "RESET: flags are not driven (wr_full=%b rd_empty=%b)",
                   wr_full, rd_empty);
        if (rd_data !== {DATA_WIDTH{1'b0}})
            $fatal(1, "RESET: rd_data=%h after reset, expected 0", rd_data);

        $display("phase 0: joint reset, wr_full=0 rd_empty=1");

        for (i = 0; i < DEPTH; i = i + 1) begin
            wr_one(i[DATA_WIDTH-1:0] + 32'h1000_0000, 1'b1);
            if (i < DEPTH-1 && wr_full !== 1'b0)
                $fatal(1, "FULL_EARLY: wr_full=%b after %0d of %0d writes",
                       wr_full, i + 1, DEPTH);
        end
        if (wr_full !== 1'b1)
            $fatal(1, "FULL_LATE: wr_full=%b after %0d writes, expected 1",
                   wr_full, DEPTH);
        $display("phase 1a: %0d entries accepted, wr_full asserted", DEPTH);

        wr_one(BAD_VALUE, 1'b0);
        if (wr_full !== 1'b1)
            $fatal(1, "FULL_STICKY: wr_full=%b, the overflow word was taken",
                   wr_full);
        @(negedge wr_clk); #1;
        wr_data = BAD_VALUE;
        wr_en   = 1'b1;
        repeat (6) @(negedge wr_clk);
        wr_en   = 1'b0;
        if (wr_full !== 1'b1)
            $fatal(1, "FULL_STICKY: wr_full=%b while the overflow word was held",
                   wr_full);
        $display("phase 1b: overflow word rejected, wr_full stays asserted");

        drain_and_check();
        if (mb_pushes !== DEPTH)
            $fatal(1, "OVERFLOW_STORED: %0d writes accepted, expected %0d",
                   mb_pushes, DEPTH);
        $display("phase 1c: %0d entries drained in order, no overflow entry", DEPTH);

        wr_one(BAD_SEQ, 1'b1);
        drain_and_check();
        if (mb_pushes !== DEPTH + 1)
            $fatal(1, "OVERFLOW_STORED: write %0d accepted behind a full FIFO",
                   mb_pushes);
        $display("phase 1d: the next word takes the slot right after the %0d kept entries", DEPTH);

        do_reset(4);
        if (wr_full !== 1'b0 || rd_empty !== 1'b1)
            $fatal(1, "RESET2: wr_full=%b rd_empty=%b", wr_full, rd_empty);

        rd_one({DATA_WIDTH{1'b0}}, 1'b0);
        rd_one({DATA_WIDTH{1'b0}}, 1'b0);
        if (rd_empty !== 1'b1)
            $fatal(1, "EMPTY_FLAG: rd_empty=%b after rejected reads", rd_empty);
        if (wr_full !== 1'b0)
            $fatal(1, "EMPTY_FLAG: wr_full=%b after rejected reads", wr_full);
        $display("phase 2: reads on an empty FIFO are ignored, flags unchanged");

        for (i = 0; i < 64; i = i + 1)
            wr_one(i[DATA_WIDTH-1:0] + 32'h2000_0000, 1'b1);
        drain_and_check();
        if (mb_count !== 0)
            $fatal(1, "EMPTY_POINTER: %0d entries left, the empty read moved rd_ptr",
                   mb_count);
        $display("phase 2b: pointer did not move on the empty read attempts");

        wr_before = mb_pushes;
        rd_before = mb_pops;
        phase_rand = 1'b1;
        wr_next    = 32'h0100_0000;
        while (n_rand_cycles < RAND_CYCLES) begin
            @(posedge rd_clk);
        end
        phase_rand = 1'b0;
        @(negedge wr_clk); #1;
        wr_en   = 1'b0;
        @(negedge rd_clk); #1;
        rd_en   = 1'b0;
        $display("phase 3: %0d random interleaved enable cycles, %0d writes accepted, %0d reads accepted",
                 RAND_CYCLES, mb_pushes - wr_before, mb_pops - rd_before);

        drain_and_check();
        if (mb_count !== 0)
            $fatal(1, "RANDOM_LEFTOVER: %0d entries left in the model", mb_count);
        $display("phase 3b: all accepted words compared and matched, no loss, no repeat, no reorder");

        while (mb_count < 300) begin
            if (n_wr_cycles > 40000)
                $fatal(1, "FILL_HANG: only %0d of 300 entries written", mb_count);
            wr_one(32'h7700_0000 + mb_count, 1'b1);
        end
        $display("phase 4a: %0d entries queued for the independent reset test", mb_count);

        model_en = 1'b0;
        tb_live  = 1'b0;
        rd_reset = 1'b1;
        repeat (3) @(posedge rd_clk);
        #1;
        rd_reset = 1'b0;
        @(negedge rd_clk); #1;
        if (rd_empty !== 1'b1)
            $fatal(1, "RD_RESET: rd_empty=%b right after the read side reset alone",
                   rd_empty);
        if (wr_full !== 1'b0)
            $fatal(1, "RD_RESET: wr_full=%b right after the read side reset alone",
                   wr_full);
        $display("phase 4b: read side reset alone, rd_empty forced back to 1");

        tb_live  = 1'b1;
        guard    = 0;
        while (rd_empty !== 1'b0) begin
            if (guard > 64)
                $fatal(1, "RD_RESET_HANG: the read side never saw the queued entries");
            @(posedge rd_clk);
            guard = guard + 1;
        end
        pending = 0;
        guard   = 0;
        while (rd_empty !== 1'b1) begin
            if (guard > 4000)
                $fatal(1, "RD_RESET_HANG: rd_empty never recovered, only %0d reads taken",
                       pending);
            rd_drop();
            if (rd_adv)
                pending = pending + 1;
            guard = guard + 1;
        end
        $display("phase 4c: read side drained %0d entries after its own reset, rd_empty recovered", pending);

        tb_live  = 1'b0;
        wr_reset = 1'b1;
        repeat (3) @(posedge wr_clk);
        #1;
        wr_reset = 1'b0;
        repeat (6) @(posedge wr_clk);
        if (wr_full !== 1'b0)
            $fatal(1, "WR_RESET: wr_full=%b after the write side reset alone",
                   wr_full);
        $display("phase 4d: write side reset alone, wr_full forced back to 0");

        tb_live  = 1'b1;
        guard    = 0;
        while (guard < 600) begin
            wr_one(32'h6600_0000 + guard, 2);
            guard = guard + 1;
        end
        $display("phase 4e: write side still accepts words after its own reset, wr_full=%0d", wr_full);
        pending = 0;
        guard   = 0;
        while (rd_empty !== 1'b1) begin
            if (guard > 2 * DEPTH + 64)
                $fatal(1, "WR_RESET_HANG: rd_empty never recovered, only %0d reads taken",
                       pending);
            rd_drop();
            if (rd_adv)
                pending = pending + 1;
            guard = guard + 1;
        end
        $display("phase 4f: rd_empty recovered, %0d reads drained", pending);

        guard = 0;
        while (wr_full !== 1'b1) begin
            if (guard > 2 * DEPTH + 64)
                $fatal(1, "WR_FULL_HANG: wr_full never reasserted after the resets");
            wr_one(32'h4400_0000 + guard, 2);
            guard = guard + 1;
        end
        $display("phase 4g: wr_full reasserts at depth after the independent resets");

        pending = 0;
        guard   = 0;
        while (rd_empty !== 1'b1) begin
            if (guard > 2 * DEPTH + 64)
                $fatal(1, "WR_FULL_HANG: rd_empty never recovered after the refill");
            rd_drop();
            if (rd_adv)
                pending = pending + 1;
            guard = guard + 1;
        end
        $display("phase 4h: rd_empty recovered after the refill, %0d reads drained", pending);

        tb_live = 1'b0;
        do_reset(6);
        model_clear();
        model_en = 1'b1;
        tb_live = 1'b1;
        if (wr_full !== 1'b0 || rd_empty !== 1'b1)
            $fatal(1, "RESET3: wr_full=%b rd_empty=%b", wr_full, rd_empty);
        for (i = 0; i < 32; i = i + 1)
            wr_one(32'h5500_0000 + i[DATA_WIDTH-1:0], 1'b1);
        drain_and_check();
        if (mb_pops !== 32)
            $fatal(1, "RESET3: %0d entries read back, expected exactly 32", mb_pops);
        $display("phase 4i: joint reset then a clean 32 entry round trip");

        $display("PASS nes_cdc_fifo");
        $finish;
    end

    initial begin
        #2000000;
        $fatal(1, "TB_TIMEOUT: the testbench stopped making progress");
    end

endmodule
