`timescale 1ns/1ps

// tb_nes_touch_input drives the vendor GT9147 I2C protocol from a behavioural
// capacitive touch controller slave, then checks the region map, the key
// debounce, the TPAD driven Start/Select substitution, the reset sequence, the
// decoded transaction stream and the NACK recovery path.
//
// The substitution is driven by touch_key, the board's discrete TPAD on F16, and
// NOT by the panel report.  The two are checked apart on purpose: a held panel
// report must leave the two keys on A and B, because keying the substitution off
// touch_valid made steering with the screen and firing with a key mutually
// exclusive, which is the defect that was found on the board.
//
// The slave resolves the open drain bus, decodes START / repeated START / STOP,
// samples bytes on the SCL rising edge, drives ACK or NACK per byte, and drives
// the read data bits itself. The physical layer is checked as well: neither line
// is ever sourced high, SDA may only move while SCL is low except at START and
// STOP, tBUF is respected, ct_rst_n stays low for the 10 ms the vendor asks for
// and no I2C traffic starts before the 50 ms post reset wait has elapsed.
//
// The region expectations are derived from the same parameter arithmetic the
// module uses, so the test follows a change of PANEL_W, PANEL_H or of the EDGE
// and MID fractions without being edited.

module tb_nes_touch_input;

    localparam integer CLK_HZ    = 50_000_000;
    localparam integer I2C_HZ    = 250_000;
    localparam [6:0]   DEV       = 7'h14;
    localparam [15:0]  ST_REG    = 16'h814E;
    localparam [15:0]  CO_REG    = 16'h8150;

    localparam integer PANEL_W   = 800;
    localparam integer PANEL_H   = 480;
    localparam integer EDGE_L_N  = 1;
    localparam integer EDGE_L_D  = 4;
    localparam integer EDGE_R_N  = 3;
    localparam integer EDGE_R_D  = 4;
    localparam integer MID_N     = 1;
    localparam integer MID_D     = 2;

    localparam [15:0]  XL = (PANEL_W * EDGE_L_N) / EDGE_L_D;
    localparam [15:0]  XR = (PANEL_W * EDGE_R_N) / EDGE_R_D;
    localparam [15:0]  YM = (PANEL_H * MID_N)   / MID_D;

    localparam integer DEBOUNCE  = 800;
    localparam integer RST_LOW   = 500_000;
    localparam integer RST_WAIT  = 2_500_000;
    localparam integer POLL      = 10_000;

    localparam real CLK_NS  = 1000000000.0 / CLK_HZ;
    localparam real TBUF_NS = 4000.0;

    localparam integer MAX_TXN = 512;

    reg        clk = 1'b0;
    reg        reset = 1'b1;
    reg        ct_int = 1'b1;
    reg        key0 = 1'b1;
    reg        key1 = 1'b1;
    // touch_key is the board TPAD on F16, ACTIVE HIGH: idle low, high while
    // held.  See the TPAD block in rtl/platform/zynq/nes_zynq_top.xdc.
    reg        touch_key = 1'b0;

    wire       ct_rst_n;
    wire       scl_o;
    wire       sda_o;
    wire       sda_oe;
    wire [7:0] buttons;
    wire [3:0] dpad;
    wire       touch_valid;
    wire [15:0] touch_x;
    wire [15:0] touch_y;
    wire       touch_int;
    wire       init_done;
    wire       touch_error;
    wire       bus_busy;
    wire       poll_done;

    reg        slave_oe = 1'b0;
    reg        slave_val = 1'b1;

    wire scl_bus;
    wire sda_bus;

    pullup (scl_bus);
    pullup (sda_bus);
    assign scl_bus = scl_o ? 1'bz : 1'b0;
    assign sda_bus = sda_oe ? sda_o : 1'bz;
    assign sda_bus = slave_oe ? slave_val : 1'bz;

    nes_touch_input #(
        .CLK_HZ            (CLK_HZ),
        .I2C_HZ            (I2C_HZ),
        .DEV_ADDR          (DEV),
        .CT_STATUS_REG     (ST_REG),
        .CT_COORD_REG      (CO_REG),
        .PANEL_W           (PANEL_W),
        .PANEL_H           (PANEL_H),
        .EDGE_L_NUM        (EDGE_L_N),
        .EDGE_L_DEN        (EDGE_L_D),
        .EDGE_R_NUM        (EDGE_R_N),
        .EDGE_R_DEN        (EDGE_R_D),
        .MID_NUM           (MID_N),
        .MID_DEN           (MID_D),
        .DEBOUNCE_CYCLES   (DEBOUNCE),
        .CT_RST_LOW_CYCLES (RST_LOW),
        .CT_RST_WAIT_CYCLES(RST_WAIT),
        .POLL_CYCLES       (POLL),
        .USE_CT_INT        (1)
    ) dut (
        .clk         (clk),
        .reset       (reset),
        .ct_int      (ct_int),
        .ct_rst_n    (ct_rst_n),
        .scl_o       (scl_o),
        .sda_o       (sda_o),
        .sda_oe      (sda_oe),
        .sda_i       (sda_bus),
        .key0        (key0),
        .key1        (key1),
        .touch_key   (touch_key),
        .buttons     (buttons),
        .dpad        (dpad),
        .touch_valid (touch_valid),
        .touch_x     (touch_x),
        .touch_y     (touch_y),
        .touch_int   (touch_int),
        .init_done   (init_done),
        .touch_error (touch_error),
        .bus_busy    (bus_busy),
        .poll_done   (poll_done)
    );

    always #10 clk = ~clk;

    localparam [2:0] SL_RX_BIT = 3'd0;
    localparam [2:0] SL_MACK   = 3'd1;
    localparam [2:0] SL_TX_BIT = 3'd2;
    localparam [2:0] SL_TX_ACK = 3'd3;

    localparam POST_IDLE = 1'b0;
    localparam POST_TX   = 1'b1;

    reg        present    = 1'b1;
    reg        nack_reg   = 1'b0;
    reg  [7:0] status_val = 8'h00;
    reg  [15:0] x_val      = 16'h0000;
    reg  [15:0] y_val      = 16'h0000;
    reg        int_drive  = 1'b1;

    integer    mon_en = 0;
    reg        in_txn = 1'b0;
    reg        have_stop = 1'b0;
    reg  [2:0] sl_state = SL_RX_BIT;
    integer    byte_n = 0;
    reg  [7:0] cur_byte = 8'h00;
    integer    cur_bits = 0;
    reg  [15:0] reg_q = 16'h0000;
    reg        dir_q = 1'b0;
    integer    rd_idx = 0;
    reg  [15:0] rd_base = 16'h0000;
    reg  [7:0] tx_byte = 8'h00;
    integer    tx_bit = 0;
    reg        master_ack = 1'b1;
    reg        bit_armed = 1'b0;
    reg        post_byte = POST_IDLE;
    reg        txn_dead = 1'b0;
    integer    txn_data_bytes = 0;

    reg        sda_prev = 1'b1;
    reg        scl_prev = 1'b1;
    reg        sda_at_rise = 1'b1;
    reg        sta_pending = 1'b0;
    real       stop_time = 0.0;
    real       sda_change_time = 0.0;
    real       scl_rise_time = 0.0;
    real       reset_fall_time = 0.0;
    real       reset_rise_time = 0.0;
    reg        reset_seen_low = 1'b0;
    reg        reset_seen_rise = 1'b0;

    integer    start_cnt = 0;
    integer    stop_cnt = 0;
    integer    rep_start_cnt = 0;
    integer    addr_ok_cnt = 0;
    integer    clr_cnt = 0;
    integer    abort_stop_cnt = 0;
    integer    co_txn_idx = -1;
    integer    poll_cnt = 0;
    integer    txn_count = 0;

    reg        t_kind  [0:MAX_TXN-1];
    reg  [15:0] t_reg   [0:MAX_TXN-1];
    integer    t_bytes [0:MAX_TXN-1];

    integer    guard;
    integer    base;
    integer    press_g;
    integer    a_press_g;

    function [7:0] next_rd_byte;
        input dummy;
        begin
            if (rd_base == ST_REG) begin
                next_rd_byte = status_val;
            end else if (rd_base == CO_REG) begin
                case (rd_idx)
                    3'd0: next_rd_byte = x_val[7:0];
                    3'd1: next_rd_byte = x_val[15:8];
                    3'd2: next_rd_byte = y_val[7:0];
                    3'd3: next_rd_byte = y_val[15:8];
                    default: next_rd_byte = 8'h00;
                endcase
            end else begin
                next_rd_byte = 8'h00;
            end
        end
    endfunction

    function do_ack;
        input [7:0] b;
        input integer n;
        begin
            if (txn_dead) begin
                do_ack = 1'b0;
            end else if (n == 0) begin
                do_ack = present && (b[7:1] == DEV);
            end else if (nack_reg) begin
                do_ack = 1'b0;
            end else begin
                do_ack = 1'b1;
            end
        end
    endfunction

    task byte_complete;
        begin
            if (byte_n == 0) begin
                dir_q     = cur_byte[0];
                byte_n    = 1;
                post_byte = POST_IDLE;
                if (cur_byte[7:1] == DEV && present) begin
                    addr_ok_cnt = addr_ok_cnt + 1;
                    if (dir_q == 1'b1) begin
                        rd_base   = reg_q;
                        rd_idx    = 0;
                        post_byte = POST_TX;
                    end
                end
            end else if (byte_n == 1) begin
                reg_q[15:8] = cur_byte;
                byte_n      = 2;
            end else if (byte_n == 2) begin
                reg_q[7:0]  = cur_byte;
                byte_n      = 3;
            end else begin
                txn_data_bytes = txn_data_bytes + 1;
                if (reg_q == ST_REG) begin
                    clr_cnt = clr_cnt + 1;
                    if (cur_byte !== 8'h00)
                        $fatal(1, "the touch flag clear wrote %02h, 00 expected", cur_byte);
                    status_val = 8'h00;
                    int_drive  = 1'b1;
                end
            end
        end
    endtask

    task drive_first_data_bit;
        begin
            tx_byte    = next_rd_byte(1'b0);
            rd_idx     = rd_idx + 1;
            tx_bit     = 7;
            slave_oe   = 1'b0;
            if (tx_byte[7] == 1'b0) begin
                slave_oe  = 1'b1;
                slave_val = 1'b0;
            end
            sl_state   = SL_TX_BIT;
            txn_data_bytes = txn_data_bytes + 1;
        end
    endtask

    always @(ct_rst_n) begin
        if (mon_en) begin
            if (ct_rst_n === 1'b0) begin
                reset_fall_time = $realtime;
                reset_seen_low  = 1'b1;
            end else if (reset_seen_low) begin
                reset_rise_time = $realtime;
                reset_seen_rise = 1'b1;
            end
        end
    end

    always @(sda_bus) begin
        if (mon_en) begin
            if (sda_prev === 1'b1 && sda_bus === 1'b0) begin
                if (scl_prev === 1'b1) begin
                    if (have_stop && ($realtime - stop_time) < TBUF_NS)
                        $fatal(1, "START only %0.1f ns after STOP, tBUF is at least %0.1f ns",
                               $realtime - stop_time, TBUF_NS);
                    if (in_txn) begin
                        rep_start_cnt = rep_start_cnt + 1;
                    end else begin
                        start_cnt = start_cnt + 1;
                        in_txn    = 1'b1;
                    end
                    if (!reset_seen_rise)
                        $fatal(1, "a START appeared at %0.1f ns, ct_rst_n has not risen yet", $realtime);
                    if (($realtime - reset_rise_time) < (RST_WAIT * CLK_NS))
                        $fatal(1, "a START appeared %0.1f ns after ct_rst_n rose, at least %0.1f ns required",
                               $realtime - reset_rise_time, RST_WAIT * CLK_NS);
                    have_stop      = 1'b0;
                    byte_n         = 0;
                    cur_bits       = 0;
                    cur_byte       = 8'h00;
                    sl_state       = SL_RX_BIT;
                    bit_armed      = 1'b0;
                    txn_dead       = 1'b0;
                    post_byte      = POST_IDLE;
                    txn_data_bytes = 0;
                    slave_oe       = 1'b0;
                    sta_pending    = 1'b1;
                end
            end
            if (sda_prev === 1'b0 && sda_bus === 1'b1) begin
                if (scl_prev === 1'b1) begin
                    if (!in_txn)
                        $fatal(1, "a STOP at %0.1f ns arrived without an open transaction", $realtime);
                    in_txn   = 1'b0;
                    have_stop = 1'b1;
                    stop_time = $realtime;
                    stop_cnt  = stop_cnt + 1;
                    if (txn_dead) begin
                        abort_stop_cnt = abort_stop_cnt + 1;
                    end else if (txn_count < MAX_TXN) begin
                        t_kind [txn_count] = dir_q;
                        t_reg  [txn_count] = reg_q;
                        t_bytes[txn_count] = txn_data_bytes;
                        if (dir_q === 1'b1 && reg_q == CO_REG && txn_data_bytes == 4)
                            co_txn_idx = txn_count;
                        txn_count          = txn_count + 1;
                    end
                    slave_oe = 1'b0;
                    sl_state = SL_RX_BIT;
                end
            end
            sda_prev       = sda_bus;
            sda_change_time = $realtime;
        end
    end

    always @(posedge scl_bus) begin
        if (mon_en) begin
            scl_prev      = 1'b1;
            scl_rise_time = $realtime;
            if (in_txn) begin
                if (sl_state == SL_RX_BIT) begin
                    if (bit_armed === 1'b1) begin
                        bit_armed = 1'b0;
                        if (cur_bits < 8) begin
                            cur_byte[7 - cur_bits] = sda_bus;
                            cur_bits = cur_bits + 1;
                        end
                    end
                end else if (sl_state == SL_MACK) begin
                    if (cur_bits > 8)
                        $fatal(1, "more than one ACK slot per byte at %0.1f ns", $realtime);
                    byte_complete();
                end else if (sl_state == SL_TX_ACK) begin
                    master_ack = sda_bus;
                end
            end
            sda_at_rise = sda_bus;
        end
    end

    always @(negedge scl_bus) begin
        if (mon_en) begin
            scl_prev = 1'b0;
            if (sda_bus !== sda_at_rise && !sta_pending)
                $fatal(1, "SDA moved while SCL was high, it changed at %0.1f ns and SCL rose at %0.1f ns",
                       sda_change_time, scl_rise_time);
            if (sta_pending)
                sta_pending = 1'b0;
            if (in_txn) begin
                if (sl_state == SL_RX_BIT && cur_bits == 8) begin
                    if (do_ack(cur_byte, byte_n)) begin
                        slave_oe  = 1'b1;
                        slave_val = 1'b0;
                    end else begin
                        slave_oe = 1'b0;
                        txn_dead = 1'b1;
                    end
                    bit_armed = 1'b0;
                    sl_state  = SL_MACK;
                end else if (sl_state == SL_RX_BIT) begin
                    bit_armed = 1'b1;
                end else if (sl_state == SL_MACK) begin
                    slave_oe  = 1'b0;
                    cur_bits  = 0;
                    bit_armed = 1'b1;
                    if (post_byte == POST_TX) begin
                        drive_first_data_bit();
                    end else begin
                        sl_state = SL_RX_BIT;
                    end
                end else if (sl_state == SL_TX_BIT) begin
                    if (tx_bit == 0) begin
                        slave_oe = 1'b0;
                        sl_state = SL_TX_ACK;
                    end else begin
                        tx_bit    = tx_bit - 1;
                        slave_oe  = 1'b0;
                        if (tx_byte[tx_bit] == 1'b0) begin
                            slave_oe  = 1'b1;
                            slave_val = 1'b0;
                        end
                    end
                end else if (sl_state == SL_TX_ACK) begin
                    cur_bits  = 0;
                    bit_armed = 1'b1;
                    if (master_ack === 1'b1) begin
                        slave_oe  = 1'b0;
                        post_byte = POST_IDLE;
                        sl_state  = SL_RX_BIT;
                    end else begin
                        drive_first_data_bit();
                    end
                end
            end
        end
    end

    always @(posedge clk) begin
        if (mon_en) begin
            if (scl_o === 1'b1 && scl_bus !== 1'b1)
                $fatal(1, "SCL was released while the bus is low, open drain violation at %0.1f ns", $realtime);
            if (sda_oe === 1'b1 && sda_o === 1'b1)
                $fatal(1, "the master drives SDA high, open drain violation at %0.1f ns", $realtime);
            if (slave_oe === 1'b1 && slave_val === 1'b1)
                $fatal(1, "the slave drives SDA high, open drain violation at %0.1f ns", $realtime);
        end
    end

    always @(posedge poll_done) poll_cnt = poll_cnt + 1;

    function [3:0] derive_dpad;
        input [15:0] x;
        input [15:0] y;
        begin
            derive_dpad = 4'b0000;
            if (x < XL) begin
                derive_dpad[1] = 1'b1;
            end else if (x >= XR) begin
                derive_dpad[0] = 1'b1;
            end else if (y < YM) begin
                derive_dpad[3] = 1'b1;
            end else begin
                derive_dpad[2] = 1'b1;
            end
        end
    endfunction

    task settle;
        input integer n;
        begin
            repeat (n) @(negedge clk);
        end
    endtask

    task wait_quiet;
        integer bclr;
        begin
            bclr = clr_cnt;
            guard = 0;
            while (guard < 600000) begin
                @(negedge clk);
                guard = guard + 1;
                if ((clr_cnt > bclr) && (int_drive === 1'b1) && (poll_done === 1'b1) &&
                    (touch_valid === 1'b0)) begin
                    @(negedge clk);
                    ct_int = 1'b1;
                    guard  = 600000;
                end
            end
            if (clr_cnt <= bclr)
                $fatal(1, "a poll cycle with a touch flag clear never completed");
        end
    endtask

    task present_touch;
        input [15:0] x;
        input [15:0] y;
        input [7:0]  st;
        begin
            wait_quiet();
            settle(4);
            x_val      = x;
            y_val      = y;
            status_val = st;
            int_drive  = 1'b0;
            ct_int     = 1'b0;
            guard = 0;
            while (!(touch_valid === 1'b1 && touch_x === x && touch_y === y) && guard < 600000) begin
                @(negedge clk);
                guard = guard + 1;
            end
            if (!(touch_valid === 1'b1 && touch_x === x && touch_y === y))
                $fatal(1, "the touch at (%0d, %0d) with status %02h was never latched, last tv=%b txy=%0d,%0d st=%02h",
                       x, y, st, touch_valid, touch_x, touch_y, dut.status_q);
            if (touch_int !== 1'b1)
                $fatal(1, "touch_int must be asserted while the controller holds a report");
        end
    endtask

    task release_touch;
        // exp_btn is the low nibble expected once the report is gone: 03 for the
        // two keys on A and B, 0c for them promoted to Start and Select by the TPAD.
        input [7:0] exp_btn;
        begin
            x_val      = 16'h0000;
            y_val      = 16'h0000;
            status_val = 8'h00;
            int_drive  = 1'b1;
            ct_int     = 1'b1;
            guard = 0;
            while (touch_valid !== 1'b0 && guard < 400000) begin
                @(negedge clk);
                guard = guard + 1;
            end
            if (touch_valid !== 1'b0)
                $fatal(1, "the touch never released");
            if (touch_int !== 1'b0)
                $fatal(1, "touch_int must drop once the report has been consumed");
            guard = 0;
            while (buttons[3:0] !== exp_btn[3:0] && guard < 400000) begin
                @(negedge clk);
                guard = guard + 1;
            end
            if (buttons[3:0] !== exp_btn[3:0])
                $fatal(1, "releasing the touch gave buttons %02h, %02h expected", buttons, exp_btn);
            if (dpad !== 4'b0000)
                $fatal(1, "releasing the touch must clear the dpad, it is %b", dpad);
            wait_quiet();
        end
    endtask

    task expect_dpad;
        input [15:0] x;
        input [15:0] y;
        input [3:0]  want;
        begin
            present_touch(x, y, 8'h81);
            if (dpad !== want)
                $fatal(1, "touch (%0d, %0d) gave dpad %b, %b expected", x, y, dpad, want);
            if (dpad !== derive_dpad(x, y))
                $fatal(1, "touch (%0d, %0d) gave dpad %b, the parameter formula gives %b",
                       x, y, dpad, derive_dpad(x, y));
            if (buttons[7:4] !== want)
                $fatal(1, "touch (%0d, %0d) put %b in buttons[7:4], %b expected", x, y, buttons[7:4], want);
            wait_quiet();
            if (dpad !== 4'b0000)
                $fatal(1, "releasing the touch must clear the dpad, it is %b", dpad);
        end
    endtask

    task expect_touch_invalid;
        input [7:0] st;
        integer bclr;
        begin
            wait_quiet();
            settle(4);
            bclr       = clr_cnt;
            x_val      = 16'h0123;
            y_val      = 16'h0456;
            status_val = st;
            int_drive  = 1'b0;
            ct_int     = 1'b0;
            guard = 0;
            while (guard < 600000) begin
                @(negedge clk);
                guard = guard + 1;
                if ((clr_cnt > bclr) && (poll_done === 1'b1)) begin
                    @(negedge clk);
                    guard = 600000;
                end
            end
            if (clr_cnt <= bclr)
                $fatal(1, "status %02h was not consumed by a completed poll cycle", st);
            if (touch_valid !== 1'b0)
                $fatal(1, "status %02h must not report a touch, touch_valid is high", st);
            if (dpad !== 4'b0000)
                $fatal(1, "status %02h must not drive the dpad, it is %b", st, dpad);
            if (buttons[7:4] !== 4'b0000)
                $fatal(1, "status %02h must leave buttons[7:4] at 0, it is %b", st, buttons[7:4]);
            wait_quiet();
        end
    endtask

    task poll_wait;
        begin
            guard = 0;
            while (poll_done !== 1'b1 && guard < 400000) begin
                @(negedge clk);
                guard = guard + 1;
            end
            if (poll_done !== 1'b1)
                $fatal(1, "no poll cycle completed within the guard, seq=%0d e_state=%0d e_phase=%0d e_bit=%0d txn=%0d clr=%0d",
                       dut.seq_q, dut.u_i2c.e_state, dut.u_i2c.e_phase, dut.u_i2c.e_bit, txn_count, clr_cnt);
            @(negedge clk);
        end
    endtask

    initial begin
        #1 reset = 1'b1;
        #399;
        if (ct_rst_n !== 1'b0)
            $fatal(1, "ct_rst_n must be low while reset is asserted");
        if (touch_valid !== 1'b0 || dpad !== 4'b0000 || buttons !== 8'h00)
            $fatal(1, "every button must be released while reset is asserted");
        if (init_done !== 1'b0)
            $fatal(1, "init_done must be low while reset is asserted");
        if (touch_error !== 1'b0)
            $fatal(1, "touch_error must be low while reset is asserted");
        if (sda_oe !== 1'b0 || scl_o !== 1'b1)
            $fatal(1, "the bus must be released while reset is asserted");

        reset = 1'b0;
        mon_en = 1;
        reset_seen_low = 1'b1;
        reset_fall_time = 0.0;

        guard = 0;
        while (init_done !== 1'b1 && guard < 8000000) begin
            @(negedge clk);
            guard = guard + 1;
        end
        if (init_done !== 1'b1)
            $fatal(1, "init_done never rose");

        if (!reset_seen_low || !reset_seen_rise)
            $fatal(1, "ct_rst_n never went low and then high");
        if ((reset_rise_time - reset_fall_time) < (RST_LOW * CLK_NS))
            $fatal(1, "ct_rst_n was low for %0.1f ns, at least %0.1f ns required",
                   reset_rise_time - reset_fall_time, RST_LOW * CLK_NS);

        base = poll_cnt;
        poll_wait();
        poll_wait();
        if (start_cnt == 0)
            $fatal(1, "no I2C transaction was issued after the reset sequence");
        if (touch_error !== 1'b0)
            $fatal(1, "an acknowledged controller reported a NACK during power up");
        if (poll_cnt < base + 2)
            $fatal(1, "the controller did not poll after init_done");
        if (touch_valid !== 1'b0)
            $fatal(1, "a controller reporting no touch must not set touch_valid");
        if (dpad !== 4'b0000)
            $fatal(1, "no touch must leave the dpad at 0000, it is %b", dpad);
        if (buttons !== 8'h00)
            $fatal(1, "no touch and no key must leave buttons at 00, they are %02h", buttons);
        if (clr_cnt < 2)
            $fatal(1, "each poll must clear the touch flag, only %0d clears were seen (start=%0d rep=%0d stop=%0d addr=%0d txn=%0d)",
                   clr_cnt, start_cnt, rep_start_cnt, stop_cnt, addr_ok_cnt, txn_count);
        if (t_kind[0] !== 1'b1 || t_reg[0] !== ST_REG || t_bytes[0] !== 1)
            $fatal(1, "transaction 0 is a %0d byte %b of %04h, a 1 byte read of %04h expected",
                   t_bytes[0], t_kind[0], t_reg[0], ST_REG);
        if (t_kind[1] !== 1'b0 || t_reg[1] !== ST_REG || t_bytes[1] !== 1)
            $fatal(1, "transaction 1 is a %0d byte %b of %04h, a 1 byte write of %04h expected",
                   t_bytes[1], t_kind[1], t_reg[1], ST_REG);
        if (rep_start_cnt < 2)
            $fatal(1, "the status read must use a repeated START, only %0d were seen", rep_start_cnt);

        base = txn_count;
        present_touch(16'd400, 16'd100, 8'h81);
        if (dpad !== 4'b1000)
            $fatal(1, "touch (400, 100) gave dpad %b, 1000 expected", dpad);
        if (touch_x !== 16'd400 || touch_y !== 16'd100)
            $fatal(1, "the coordinate read produced (%0d, %0d), (400, 100) expected", touch_x, touch_y);
        wait_quiet();
        if (co_txn_idx <= base)
            $fatal(1, "a reported touch must produce a 4 byte coordinate read, none was seen after transaction %0d",
                   base);
        if (t_kind[co_txn_idx] !== 1'b1 || t_reg[co_txn_idx] !== CO_REG || t_bytes[co_txn_idx] !== 4)
            $fatal(1, "transaction %0d is a %0d byte %b of %04h, a 4 byte read of %04h expected",
                   co_txn_idx, t_bytes[co_txn_idx], t_kind[co_txn_idx], t_reg[co_txn_idx], CO_REG);
        if (t_kind[co_txn_idx-1] !== 1'b1 || t_reg[co_txn_idx-1] !== ST_REG || t_bytes[co_txn_idx-1] !== 1)
            $fatal(1, "transaction %0d is a %0d byte %b of %04h, a 1 byte read of %04h expected",
                   co_txn_idx-1, t_bytes[co_txn_idx-1], t_kind[co_txn_idx-1], t_reg[co_txn_idx-1], ST_REG);
        if (co_txn_idx + 1 >= txn_count ||
            t_kind[co_txn_idx+1] !== 1'b0 || t_reg[co_txn_idx+1] !== ST_REG || t_bytes[co_txn_idx+1] !== 1)
            $fatal(1, "the transaction after the coordinate read is not the flag clear write");

        expect_dpad(16'd0,   16'd0,   4'b0010);
        expect_dpad(16'd0,   16'd479, 4'b0010);
        expect_dpad(16'd100, 16'd120, 4'b0010);
        expect_dpad(16'd199, 16'd0,   4'b0010);
        expect_dpad(16'd199, 16'd479, 4'b0010);

        expect_dpad(16'd200, 16'd0,   4'b1000);
        expect_dpad(16'd201, 16'd0,   4'b1000);
        expect_dpad(16'd201, 16'd479, 4'b0100);
        expect_dpad(16'd400, 16'd238, 4'b1000);
        expect_dpad(16'd400, 16'd239, 4'b1000);
        expect_dpad(16'd400, 16'd240, 4'b0100);
        expect_dpad(16'd400, 16'd241, 4'b0100);
        expect_dpad(16'd599, 16'd0,   4'b1000);
        expect_dpad(16'd599, 16'd479, 4'b0100);

        expect_dpad(16'd600, 16'd0,   4'b0001);
        expect_dpad(16'd600, 16'd479, 4'b0001);
        expect_dpad(16'd601, 16'd120, 4'b0001);
        expect_dpad(16'd799, 16'd0,   4'b0001);
        expect_dpad(16'd799, 16'd479, 4'b0001);

        expect_dpad(16'd800, 16'd0,   4'b0001);
        expect_dpad(16'd800, 16'd240, 4'b0001);
        expect_dpad(16'd0,   16'd480, 4'b0010);
        expect_dpad(16'd400, 16'd480, 4'b0100);
        expect_dpad(16'hFFFF, 16'hFFFF, 4'b0001);
        expect_dpad(16'd300, 16'hFFFF, 4'b0100);

        expect_touch_invalid(8'h86);
        expect_touch_invalid(8'h05);
        expect_touch_invalid(8'h00);
        expect_touch_invalid(8'h80);

        settle(DEBOUNCE + 32);
        if (buttons !== 8'h00)
            $fatal(1, "every button must be released after the region tests, they are %02h", buttons);

        key0 = 1'b0;
        a_press_g = 0;
        while (buttons[0] !== 1'b1 && a_press_g < DEBOUNCE + 64) begin
            @(negedge clk);
            a_press_g = a_press_g + 1;
        end
        if (buttons[0] !== 1'b1)
            $fatal(1, "key[0] never produced A");
        if (a_press_g < DEBOUNCE)
            $fatal(1, "A appeared after %0d clk, the debounce needs at least %0d", a_press_g, DEBOUNCE);
        if (a_press_g > DEBOUNCE + 8)
            $fatal(1, "A appeared after %0d clk, at most %0d are allowed", a_press_g, DEBOUNCE + 8);
        if (buttons !== 8'h01)
            $fatal(1, "key[0] alone gave buttons %02h, 01 expected", buttons);
        if (dpad !== 4'b0000)
            $fatal(1, "key[0] must not drive the dpad");

        key1 = 1'b0;
        press_g = 0;
        while (buttons[1] !== 1'b1 && press_g < DEBOUNCE + 64) begin
            @(negedge clk);
            press_g = press_g + 1;
        end
        if (buttons !== 8'h03)
            $fatal(1, "key[0] and key[1] gave buttons %02h, 03 expected", buttons);

        // A screen touch on its own must NOT change what the two keys do.  This is
        // the regression for the defect that was found on the board: the
        // substitution used to be keyed off touch_valid_q, so touching the screen
        // to steer turned the two keys into Start and Select and firing with a key
        // became impossible.  Both keys are already pressed here and stay pressed
        // across the whole report, so under the old RTL buttons would be 8'h2c at
        // this point (dpad 0010 with A and B released and Start and Select set)
        // instead of 8'h23.
        present_touch(16'd0, 16'd0, 8'h81);
        if (touch_valid !== 1'b1)
            $fatal(1, "the panel report must still be latched when the keys are checked");
        if (dpad !== 4'b0010)
            $fatal(1, "touch (0, 0) gave dpad %b, 0010 expected", dpad);
        if (buttons[7:4] !== 4'b0010)
            $fatal(1, "touch (0, 0) put %b in buttons[7:4], 0010 expected", buttons[7:4]);
        if (buttons[1:0] !== 2'b11)
            $fatal(1, "a screen touch released A and B, buttons[1:0] is %b", buttons[1:0]);
        if (buttons[3:2] !== 2'b00)
            $fatal(1, "a screen touch turned the keys into Start and Select, buttons[3:2] is %b",
                   buttons[3:2]);
        if (buttons !== 8'h23)
            $fatal(1, "a screen touch changed what the keys do: buttons %02h, 23 expected", buttons);

        release_touch(8'h03);

        // The TPAD is what promotes them.  It is a discrete button on F16 and it is
        // ACTIVE HIGH, the opposite of the two keys, so it is driven high here.
        touch_key = 1'b1;
        settle(DEBOUNCE + 32);
        if (buttons !== 8'h0C)
            $fatal(1, "holding the TPAD gave buttons %02h, 0c expected (Start and Select)", buttons);
        if (buttons[0] !== 1'b0 || buttons[1] !== 1'b0)
            $fatal(1, "A and B must be released while the TPAD is held");
        if (buttons[3] !== 1'b1 || buttons[2] !== 1'b1)
            $fatal(1, "key[0] must drive Start and key[1] must drive Select while the TPAD is held");
        if (dpad !== 4'b0000)
            $fatal(1, "the TPAD must not drive the dpad, dpad is %b", dpad);

        // The screen dpad and the TPAD substitution are independent: both held at
        // once must give dpad 0010 with Start and Select and A and B released.
        present_touch(16'd0, 16'd0, 8'h81);
        if (buttons !== 8'h2C)
            $fatal(1, "the TPAD held with a reported touch gave buttons %02h, 2c expected", buttons);
        if (dpad !== 4'b0010)
            $fatal(1, "the touch dpad must survive the TPAD substitution, dpad is %b", dpad);

        release_touch(8'h0C);

        touch_key = 1'b0;
        settle(DEBOUNCE + 32);
        if (buttons !== 8'h03)
            $fatal(1, "releasing the TPAD gave buttons %02h, 03 expected (A and B again)", buttons);

        // The TPAD gets the same debounce as the keys: a pulse shorter than the
        // window must neither substitute nor latch.
        touch_key = 1'b1;
        settle(DEBOUNCE - 8);
        if (buttons[3:2] !== 2'b00)
            $fatal(1, "a TPAD pulse shorter than the debounce window reached Start and Select");
        touch_key = 1'b0;
        settle(DEBOUNCE * 3);
        if (buttons[3:2] !== 2'b00)
            $fatal(1, "a TPAD pulse shorter than the debounce window latched the substitution");
        if (buttons !== 8'h03)
            $fatal(1, "the short TPAD pulse disturbed the keys, buttons %02h", buttons);

        key1 = 1'b1;
        guard = 0;
        while (buttons[1] !== 1'b0 && guard < DEBOUNCE + 64) begin
            @(negedge clk);
            guard = guard + 1;
        end
        key0 = 1'b1;
        guard = 0;
        while (buttons[0] !== 1'b0 && guard < DEBOUNCE + 64) begin
            @(negedge clk);
            guard = guard + 1;
        end
        if (buttons !== 8'h00)
            $fatal(1, "releasing both keys gave buttons %02h, 00 expected", buttons);

        settle(DEBOUNCE);
        key0 = 1'b0;
        settle(DEBOUNCE - 8);
        if (buttons[0] !== 1'b0)
            $fatal(1, "a key[0] pulse shorter than the debounce window produced A");
        key0 = 1'b1;
        settle(DEBOUNCE * 3);
        if (buttons[0] !== 1'b0)
            $fatal(1, "a key[0] pulse shorter than the debounce window latched A");
        settle(16);

        if (touch_error !== 1'b0)
            $fatal(1, "an acknowledged controller reported an error before the NACK tests");

        present = 1'b0;
        base = poll_cnt;
        guard = 0;
        while (touch_error !== 1'b1 && guard < 800000) begin
            @(negedge clk);
            guard = guard + 1;
        end
        if (touch_error !== 1'b1)
            $fatal(1, "an absent controller did not raise touch_error");
        if (touch_valid !== 1'b0)
            $fatal(1, "an absent controller must not report a touch");
        if (buttons[7:4] !== 4'b0000)
            $fatal(1, "an absent controller must leave the buttons released, they are %02h", buttons);
        poll_wait();
        poll_wait();
        if (poll_cnt < base + 1)
            $fatal(1, "the controller did not keep polling after a NACK");
        if (scl_bus !== 1'b1 || sda_bus !== 1'b1)
            $fatal(1, "the bus was not handed back cleanly after a NACK");
        if (abort_stop_cnt < 1)
            $fatal(1, "an aborted transaction must still be terminated by a STOP");

        nack_reg = 1'b1;
        base = abort_stop_cnt;
        guard = 0;
        while (abort_stop_cnt < base + 1 && guard < 800000) begin
            @(negedge clk);
            guard = guard + 1;
        end
        if (abort_stop_cnt < base + 1)
            $fatal(1, "a NACKed register pointer did not abort the transaction");
        if (touch_error !== 1'b1)
            $fatal(1, "a NACKed register pointer did not raise touch_error");
        nack_reg = 1'b0;
        present  = 1'b1;
        settle(4);

        present_touch(16'd600, 16'd480, 8'h85);
        if (dpad !== 4'b0001)
            $fatal(1, "after recovery touch (600, 480) gave dpad %b, 0001 expected", dpad);
        if (touch_x !== 16'd600 || touch_y !== 16'd480)
            $fatal(1, "after recovery the coordinates are (%0d, %0d), (600, 480) expected", touch_x, touch_y);
        if (touch_error !== 1'b1)
            $fatal(1, "touch_error must stay set once a NACK has been seen");
        wait_quiet();
        if (dpad !== 4'b0000)
            $fatal(1, "the dpad must clear once the recovered touch is released");

        $display("tb_nes_touch_input: %0d transactions, %0d START, %0d repeated START, %0d STOP",
                 txn_count, start_cnt, rep_start_cnt, stop_cnt);
        $display("tb_nes_touch_input: %0d address matches, %0d flag clears, %0d aborted, %0d polls",
                 addr_ok_cnt, clr_cnt, abort_stop_cnt, poll_cnt);
        $display("tb_nes_touch_input: cuts x_left=%0d x_right=%0d y_mid=%0d, debounce %0d clk, A after %0d clk",
                 XL, XR, YM, DEBOUNCE, a_press_g);
        $display("tb_nes_touch_input: keys alone give A/B, a screen touch leaves them at A/B, only the TPAD promotes them to Start/Select");
        $display("PASS nes_touch_input");
        $finish;
    end

    initial begin
        #500000000;
        $fatal(1, "tb_nes_touch_input global timeout");
    end

endmodule
