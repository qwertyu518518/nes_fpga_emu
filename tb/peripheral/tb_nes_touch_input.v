`timescale 1ns/1ps

// tb_nes_touch_input drives the vendor GT9147 I2C protocol from a behavioural
// capacitive touch controller slave, then checks the region map, the key
// debounce, the TPAD driven Start/Select substitution, the reset sequence, the
// decoded transaction stream, the NACK recovery path, and the one-time
// self-calibration.
//
// THE SUBSTITUTION IS NOT THE TOUCH PATH, and is checked apart on purpose: a
// held panel report must leave the two keys on A and B, because keying the
// substitution off touch_valid made steering with the screen and firing with a key
// mutually exclusive, which is the defect that was found on the board.
//
// THE CALIBRATION IS THE POINT OF THIS BENCH.  The driver now asks the controller
// what frame it is reporting in instead of assuming 800x480, so the I2C model here
// answers those reads out of per-scenario register values and every scenario is a
// different controller:
//   1  799 x 479,  Module_Switch1 bit 3 clear   the honest 800x480 module
//   2  1023 x 639, Module_Switch1 bit 3 SET     transposed axes, proved by the
//                                                  coordinates coming back exchanged
//   3  479 x 271,  Module_Switch1 bit 3 clear   the ATK-4342 of the same family
//   4  every calibration byte NACKed             fall back to the constants
//   5  every calibration byte all ones           fall back to the constants
// Scenario 2 uses 8'h68, which has bit 3 set AND bits 6 and 5 set, so a decoder
// that guessed the field layout, or read the wrong bit, would get a different
// answer and fail here.
//
// "it reads five more registers" is exactly the kind of change that silently
// mis-addresses, so every scenario asserts the ADDRESSES, the DIRECTION and the
// BYTE COUNT of all three calibration reads, and asserts afterwards that each one
// happened exactly once.  The region sweep is driven from the cuts the controller
// reported, and NON-VACUITY is asserted: if every scenario produced 200/600/240 the
// test could not tell a working calibration from the hardcoded constants, so the
// run fails unless at least one scenario lands on different numbers.
//
// The slave resolves the open drain bus, decodes START / repeated START / STOP,
// samples bytes on the SCL rising edge, drives ACK or NACK per byte, and drives
// the read data bits itself. The physical layer is checked as well: neither line
// is ever sourced high, SDA may only move while SCL is low except at START and
// STOP, tBUF is respected, ct_rst_n stays low for the 10 ms the vendor asks for
// and no I2C traffic starts before the 50 ms post reset wait has elapsed.

module tb_nes_touch_input;

    localparam integer CLK_HZ    = 50_000_000;
    localparam integer I2C_HZ    = 250_000;
    localparam [6:0]   DEV       = 7'h14;
    localparam [15:0]  ST_REG    = 16'h814E;
    localparam [15:0]  CO_REG    = 16'h8150;

    // The three read-only registers the driver calibrates from, hard-coded HERE on
    // purpose.  They are not read out of the RTL, because a testbench that reads
    // its expectation out of the thing under test checks nothing; spelling them
    // out is what turns a mis-addressed read into a failing bench.
    localparam [15:0]  CAL_XMAX   = 16'h8048;   // X Output Max, low then high byte
    localparam [15:0]  CAL_YMAX   = 16'h804A;   // Y Output Max, low then high byte
    localparam [15:0]  CAL_SWITCH = 16'h804D;   // Module_Switch1, bit 3 = X2Y

    localparam integer PANEL_W   = 800;
    localparam integer PANEL_H   = 480;
    localparam integer EDGE_L_N  = 1;
    localparam integer EDGE_L_D  = 4;
    localparam integer EDGE_R_N  = 3;
    localparam integer EDGE_R_D  = 4;
    localparam integer MID_N     = 1;
    localparam integer MID_D     = 2;

    // The compile-time cuts, i.e. what the driver fell back to before the
    // calibration existed and what scenarios 4 and 5 must land on.
    localparam [15:0]  XL = (PANEL_W * EDGE_L_N) / EDGE_L_D;
    localparam [15:0]  XR = (PANEL_W * EDGE_R_N) / EDGE_R_D;
    localparam [15:0]  YM = (PANEL_H * MID_N)   / MID_D;

    localparam integer DEBOUNCE  = 800;
    localparam integer RST_LOW   = 500_000;
    localparam integer RST_WAIT  = 2_500_000;
    localparam integer POLL      = 10_000;

    localparam real CLK_NS  = 1000000000.0 / CLK_HZ;
    localparam real TBUF_NS = 4000.0;

    localparam integer MAX_TXN = 2048;

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

    // What the driver published from its own reads.
    wire [15:0] touch_x_max;
    wire [15:0] touch_y_max;
    wire        touch_x2y;
    wire [15:0] touch_x_left_edge;
    wire [15:0] touch_x_right_edge;
    wire [15:0] touch_y_mid_edge;
    wire        touch_calib_ok;

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
        .poll_done   (poll_done),
        .touch_x_max       (touch_x_max),
        .touch_y_max       (touch_y_max),
        .touch_x2y         (touch_x2y),
        .touch_x_left_edge (touch_x_left_edge),
        .touch_x_right_edge(touch_x_right_edge),
        .touch_y_mid_edge  (touch_y_mid_edge),
        .touch_calib_ok    (touch_calib_ok)
    );

    always #10 clk = ~clk;

    localparam [2:0] SL_RX_BIT = 3'd0;
    localparam [2:0] SL_MACK   = 3'd1;
    localparam [2:0] SL_TX_BIT = 3'd2;
    localparam [2:0] SL_TX_ACK = 3'd3;

    localparam POST_IDLE = 1'b0;
    localparam POST_TX   = 1'b1;

    // ---- what this controller reports about itself.
    reg  [15:0] cal_x_max_val = 16'd799;
    reg  [15:0] cal_y_max_val = 16'd479;
    reg  [7:0]  cal_switch_val = 8'h00;
    // A bus that is stuck high: the slave still ACKs, it just never pulls SDA low,
    // so the master samples 8'hFF on every data bit.  That is the signature of a
    // controller that is present and acknowledging but not driving, and it must
    // not be mistaken for a 65535-wide panel.
    reg         cal_stuck_high = 1'b0;
    // NACK the HIGH byte of any 0x80xx register pointer.  0x80xx is used by the
    // three calibration reads and by nothing else in this design: 16'h814E is
    // 0x81xx and 16'h8150 is 0x81xx, so this cannot touch a poll transaction.
    reg         nack_cal = 1'b0;

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

    // ---- the scenario the run is currently in.
    integer    scen = 0;
    reg [15:0] rep_x_max = 16'd799;
    reg [15:0] rep_y_max = 16'd479;
    reg [7:0]  rep_switch = 8'h00;
    reg        scen_stuck = 1'b0;
    reg        scen_nack  = 1'b0;
    reg        scen_expect_swap = 1'b0;
    reg        scen_expect_ok   = 1'b1;
    reg [15:0] exp_xl = XL;
    reg [15:0] exp_xr = XR;
    reg [15:0] exp_ym = YM;
    reg        swap_active = 1'b0;

    integer    nonvacuous_cases = 0;
    integer    n_cal_total = 0;
    integer    exp_cal_reads = 1;

    function is_cal_reg;
        input [15:0] r;
        begin
            is_cal_reg = (r == CAL_XMAX) || (r == CAL_YMAX) || (r == CAL_SWITCH);
        end
    endfunction

    // Count how many completed transactions read the given register.  The return
    // width has to be stated: a function declared with no range returns ONE bit
    // in Verilog-2001, so a count of two would come back as zero and a count of
    // three as one.  That is not a hypothetical, it is what this returned before
    // the width was written down.
    function integer count_reg;
        input [15:0] r;
        integer i;
        integer n;
        begin
            n = 0;
            for (i = 0; i < MAX_TXN; i = i + 1) begin
                if ((i < txn_count) && (t_reg[i] === r))
                    n = n + 1;
            end
            count_reg = n;
        end
    endfunction

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
            end else if (is_cal_reg(rd_base)) begin
                // The model really holds these values and really answers the
                // reads, rather than the bench stubbing the driver's result: the
                // same byte-level path drives status and coordinates, so the
                // calibration reads are checked for real framing, ACK pattern and
                // address along with everything else.
                if (cal_stuck_high) begin
                    next_rd_byte = 8'hFF;
                end else if (rd_base == CAL_XMAX) begin
                    next_rd_byte = (rd_idx == 0) ? cal_x_max_val[7:0]
                                                  : cal_x_max_val[15:8];
                end else if (rd_base == CAL_YMAX) begin
                    next_rd_byte = (rd_idx == 0) ? cal_y_max_val[7:0]
                                                  : cal_y_max_val[15:8];
                end else begin
                    next_rd_byte = cal_switch_val;
                end
            end else begin
                next_rd_byte = 8'h00;
            end
        end
    endfunction

    function do_ack;
        input [7:0] b;
        input integer n;
        begin
            do_ack = 1'b0;
            if (txn_dead) begin
                do_ack = 1'b0;
            end else if (n == 0) begin
                do_ack = present && (b[7:1] == DEV);
            end else if (n == 1) begin
                // cur_byte is the HIGH byte of the register pointer here, so this
                // is the only place a 0x80xx read can be refused.
                do_ack = nack_cal ? ((b !== 8'h80) && !nack_reg)
                                  : (!nack_reg);
            end else begin
                do_ack = !nack_reg;
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
                reset_seen_rise = 1'b0;
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

    // The region map, restated over the CUTS IN FORCE for the current scenario.
    // It is the same total function the RTL implements: left below the left cut,
    // right at or above the right cut, and the band between them split at the
    // middle cut.  Reading exp_* rather than the localparams is what makes the
    // sweep follow the calibration; the independent literal expectations in
    // check_region are what stop this from checking the map against itself.
    function [3:0] derive_dpad;
        input [15:0] x;
        input [15:0] y;
        begin
            derive_dpad = 4'b0000;
            if (x < exp_xl) begin
                derive_dpad[1] = 1'b1;
            end else if (x >= exp_xr) begin
                derive_dpad[0] = 1'b1;
            end else if (y < exp_ym) begin
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

    // Present a report whose PANEL coordinates are (px, py), in whatever byte order
// the controller in force reports, and check that the driver hands back the panel
// coordinates.  It leaves the report latched, so the caller can look at the
// d-pad and the whole button byte before anything consumes it.
//
// The coordinates handed to the slave are the panel ones or their exchange,
// depending on what the scenario says the controller's X2Y bit is.  That is the
// swap assertion: a scenario with X2Y set is FAILED if the driver passes the bytes
// through, and a scenario with X2Y clear is failed if it exchanges them.
    task present_panel;
        input [15:0] px;
        input [15:0] py;
        reg   [15:0] rx;
        reg   [15:0] ry;
        begin
            rx = swap_active ? py : px;
            ry = swap_active ? px : py;
            wait_quiet();
            settle(4);
            x_val      = rx;
            y_val      = ry;
            status_val = 8'h81;
            int_drive  = 1'b0;
            ct_int     = 1'b0;
            guard = 0;
            // touch_valid rises one poll state BEFORE the coordinates are latched,
            // so waiting on touch_valid alone would read the PREVIOUS report's
            // coordinates and silently check the wrong point.
            while (!(touch_valid === 1'b1 && touch_x === px && touch_y === py) && guard < 600000) begin
                @(negedge clk);
                guard = guard + 1;
            end
            if (!(touch_valid === 1'b1 && touch_x === px && touch_y === py))
                $fatal(1, "s%d: the panel report (%0d, %0d) never arrived as (%0d, %0d); raw (%0d, %0d) X2Y=%b, last tv=%b txy=%0d,%0d st=%02h",
                       scen, px, py, px, py, rx, ry, touch_x2y, touch_valid, touch_x, touch_y, dut.status_q);
        end
    endtask

    task check_region;
        input [15:0] px;
        input [15:0] py;
        input [3:0]  want;
        begin
            present_panel(px, py);
            if (dpad !== want)
                $fatal(1, "s%d: panel (%0d, %0d) gave dpad %b, %b expected, cuts %0d/%0d/%0d",
                       scen, px, py, dpad, want, exp_xl, exp_xr, exp_ym);
            if (dpad !== derive_dpad(px, py))
                $fatal(1, "s%d: panel (%0d, %0d) gave dpad %b, the cut formula over %0d/%0d/%0d gives %b",
                       scen, px, py, dpad, exp_xl, exp_xr, exp_ym, derive_dpad(px, py));
            if (buttons[7:4] !== want)
                $fatal(1, "s%d: panel (%0d, %0d) put %b in buttons[7:4], %b expected",
                       scen, px, py, buttons[7:4], want);
            wait_quiet();
            if (dpad !== 4'b0000)
                $fatal(1, "releasing the touch must clear the dpad, it is %b", dpad);
        end
    endtask

    // The whole region map, at and around each of the three cuts IN FORCE.  The
    // literals L/U/D/R are the semantics, which are unchanged by the calibration;
    // only which panel coordinate lands on them moves.
    task region_sweep;
        begin
            // left third: x below the left cut, whatever y
            check_region(16'd0,        16'd0,        4'b0010);
            check_region(exp_xl - 1'b1, 16'd0,        4'b0010);
            check_region(exp_xl - 1'b1, exp_ym - 1'b1, 4'b0010);
            // the left cut is the FIRST pixel of the middle band, so it is already up
            check_region(exp_xl,        16'd0,        4'b1000);
            check_region(exp_xl + 1'b1, exp_ym - 1'b1, 4'b1000);
            check_region(exp_xl + 1'b1, exp_ym,       4'b0100);
            check_region(exp_xr - 1'b1, exp_ym - 1'b1, 4'b1000);
            check_region(exp_xr - 1'b1, exp_ym,       4'b0100);
            // the right cut is the first pixel of Right
            check_region(exp_xr,        16'd0,        4'b0001);
            check_region(exp_xr,        exp_ym - 1'b1, 4'b0001);
            check_region(exp_xr + 1'b1, exp_ym,       4'b0001);
            // out of range is still one of the five regions, never none
            check_region(exp_xr + 50,   16'd0,        4'b0001);
            check_region(16'd0,         exp_ym + 50,  4'b0010);
            check_region(exp_xl + 10,   exp_ym + 50,  4'b0100);
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

    // ---- the calibration assertions for one scenario.
    task check_calibration;
        begin
            // The maxima are only expected to have been latched if the reads were allowed to
    // complete, and a stuck-high bus legitimately produces 16'hFFFF rather than
    // what the controller would otherwise have said.  What must NOT happen is the
    // 16'hFFFF reaching the cuts, which is what the constants below check.
            if (scen_nack) begin
                if (touch_x_max !== 16'h0000 || touch_y_max !== 16'h0000)
                    $fatal(1, "s%d: a refused calibration read latched x_max=%0d y_max=%0d",
                           scen, touch_x_max, touch_y_max);
            end else if (scen_stuck) begin
                if (touch_x_max !== 16'hFFFF || touch_y_max !== 16'hFFFF)
                    $fatal(1, "s%d: a stuck-high bus read %0d/%0d, 65535/65535 expected",
                           scen, touch_x_max, touch_y_max);
            end else begin
                if (touch_x_max !== rep_x_max)
                    $fatal(1, "s%d: touch_x_max is %0d, the controller reported %0d",
                           scen, touch_x_max, rep_x_max);
                if (touch_y_max !== rep_y_max)
                    $fatal(1, "s%d: touch_y_max is %0d, the controller reported %0d",
                           scen, touch_y_max, rep_y_max);
            end
            if (touch_x2y !== scen_expect_swap)
                $fatal(1, "s%d: touch_x2y is %b from Module_Switch1 %02h, bit 3 says %b",
                       scen, touch_x2y, cal_switch_val, scen_expect_swap);
            if (touch_calib_ok !== scen_expect_ok)
                $fatal(1, "s%d: touch_calib_ok is %b, %b expected",
                       scen, touch_calib_ok, scen_expect_ok);
            if (touch_x_left_edge  !== exp_xl)
                $fatal(1, "s%d: x left cut is %0d, %0d expected", scen, touch_x_left_edge, exp_xl);
            if (touch_x_right_edge !== exp_xr)
                $fatal(1, "s%d: x right cut is %0d, %0d expected", scen, touch_x_right_edge, exp_xr);
            if (touch_y_mid_edge   !== exp_ym)
                $fatal(1, "s%d: y mid cut is %0d, %0d expected", scen, touch_y_mid_edge, exp_ym);

            // NON-VACUITY.  If the cuts the driver published were the hardcoded
            // constants in every scenario, this bench could not tell a working
            // calibration from the constants, and the whole change would be
            // untested.  Count the scenarios that landed somewhere else.
            if ((touch_x_left_edge  !== XL) || (touch_x_right_edge !== XR) ||
                (touch_y_mid_edge   !== YM)) begin
                nonvacuous_cases = nonvacuous_cases + 1;
                $display("  s%d NON-VACUOUS: cuts %0d/%0d/%0d differ from the constants %0d/%0d/%0d",
                         scen, touch_x_left_edge, touch_x_right_edge, touch_y_mid_edge, XL, XR, YM);
            end else begin
                $display("  s%d cuts %0d/%0d/%0d equal the constants %0d/%0d/%0d (this scenario is the fallback)",
                         scen, touch_x_left_edge, touch_x_right_edge, touch_y_mid_edge, XL, XR, YM);
            end
            $display("  s%d calibrated: x_max=%0d y_max=%0d x2y=%b ok=%b cuts=%0d/%0d/%0d",
                     scen, touch_x_max, touch_y_max, touch_x2y, touch_calib_ok,
                     touch_x_left_edge, touch_x_right_edge, touch_y_mid_edge);
        end
    endtask

    // Reset, let the driver reset the controller, wait for the calibration, then
    // check it.  poll_done is the observable that the calibration is finished: the
    // driver cannot complete a poll before it has been through SQ_CAL_DONE, so one
    // poll_done means the cuts are already latched.
    task run_scenario;
        input integer id;
        integer tb0;
        integer i0;
        integer i1;
        integer i2;
        integer i3;
        integer n0x;
        integer n0y;
        integer n0s;
        integer ab0;
        integer pol0;
        begin
            scen = id;
            case (id)
                1: begin
                    rep_x_max = 16'd799;  rep_y_max = 16'd479;  rep_switch = 8'h30;
                    scen_stuck = 1'b0;    scen_nack = 1'b0;
                    scen_expect_swap = 1'b0; scen_expect_ok = 1'b1;
                end
                2: begin
                    // bit 3 (X2Y) AND bit 7 AND bit 5 set, so a decoder that read
                    // the wrong bit of Module_Switch1 answers differently.
                    rep_x_max = 16'd1023; rep_y_max = 16'd639;  rep_switch = 8'h68;
                    scen_stuck = 1'b0;    scen_nack = 1'b0;
                    scen_expect_swap = 1'b1; scen_expect_ok = 1'b1;
                end
                3: begin
                    // The ATK-4342 of the same module family: 480x272.
                    rep_x_max = 16'd479;  rep_y_max = 16'd271;  rep_switch = 8'h00;
                    scen_stuck = 1'b0;    scen_nack = 1'b0;
                    scen_expect_swap = 1'b0; scen_expect_ok = 1'b1;
                end
                4: begin
                    rep_x_max = 16'd799;  rep_y_max = 16'd479;  rep_switch = 8'h30;
                    scen_stuck = 1'b0;    scen_nack = 1'b1;
                    scen_expect_swap = 1'b0; scen_expect_ok = 1'b0;
                end
                default: begin
                    rep_x_max = 16'd799;  rep_y_max = 16'd479;  rep_switch = 8'h30;
                    scen_stuck = 1'b1;    scen_nack = 1'b0;
                    scen_expect_swap = 1'b0; scen_expect_ok = 1'b0;
                end
            endcase

            // The cuts this scenario must produce, derived here from the reported
            // maxima by the same rule the driver uses, independently written.
            if (scen_nack) begin
                // A refused read has to land on the compile-time constants.
                exp_xl = XL;
                exp_xr = XR;
                exp_ym = YM;
            end else if (scen_stuck) begin
                exp_xl = XL;
                exp_xr = XR;
                exp_ym = YM;
            end else begin
                exp_xl = rep_x_max >> 2;
                exp_xr = rep_x_max - (rep_x_max >> 2);
                exp_ym = rep_y_max >> 1;
            end
            swap_active = scen_expect_swap & scen_expect_ok;

            // Hand the model the new controller.
            cal_x_max_val   = rep_x_max;
            cal_y_max_val   = rep_y_max;
            cal_switch_val  = rep_switch;
            cal_stuck_high  = scen_stuck;
            nack_cal        = scen_nack;
            present         = 1'b1;
            nack_reg        = 1'b0;
            x_val           = 16'h0000;
            y_val           = 16'h0000;
            status_val      = 8'h00;
            int_drive       = 1'b1;
            ct_int          = 1'b1;

            tb0  = txn_count;
            ab0  = abort_stop_cnt;
            pol0 = poll_cnt;
            n0x  = count_reg(CAL_XMAX);
            n0y  = count_reg(CAL_YMAX);
            n0s  = count_reg(CAL_SWITCH);

            // ---- reset
            reset = 1'b1;
            settle(64);
            repeat (RST_LOW) @(negedge clk);
            reset = 1'b0;

            guard = 0;
            while (init_done !== 1'b1 && guard < 8000000) begin
                @(negedge clk);
                guard = guard + 1;
            end
            if (init_done !== 1'b1)
                $fatal(1, "s%d: init_done never rose", id);
            if (!reset_seen_low || !reset_seen_rise)
                $fatal(1, "s%d: ct_rst_n never went low and then high", id);
            if ((reset_rise_time - reset_fall_time) < (RST_LOW * CLK_NS))
                $fatal(1, "s%d: ct_rst_n was low for %0.1f ns, at least %0.1f ns required",
                       id, reset_rise_time - reset_fall_time, RST_LOW * CLK_NS);

            // The calibration runs after init_done and before the first poll.
            poll_wait();
            poll_wait();

            if (scen_nack) begin
                // The one calibration transaction that was refused must still have
                // been terminated by a STOP, so the bus is handed back clean.
                if (abort_stop_cnt < ab0 + 1)
                    $fatal(1, "s%d: a NACKed calibration read did not abort with a STOP, aborts %0d -> %0d",
                           id, ab0, abort_stop_cnt);
                if (touch_x_max !== 16'h0000 || touch_y_max !== 16'h0000)
                    $fatal(1, "s%d: a refused calibration read latched x_max=%0d y_max=%0d",
                           id, touch_x_max, touch_y_max);
                if (touch_calib_ok !== 1'b0)
                    $fatal(1, "s%d: a refused calibration read claimed to be calibrated", id);
                if (touch_error !== 1'b0)
                    $fatal(1, "s%d: a refused calibration read raised touch_error; it is absorbed, not fatal", id);
            end else begin
                i0 = tb0;
                i1 = tb0 + 1;
                i2 = tb0 + 2;
                i3 = tb0 + 3;
                if (i0 >= txn_count || t_kind[i0] !== 1'b1 || t_reg[i0] !== CAL_XMAX || t_bytes[i0] !== 2)
                    $fatal(1, "s%d: transaction %0d is a %0d byte %b of %04h, a 2 byte read of %04h expected",
                           id, i0, (i0 < txn_count) ? t_bytes[i0] : -1,
                           (i0 < txn_count) ? t_kind[i0] : 1'bx,
                           (i0 < txn_count) ? t_reg[i0] : 16'hxxxx,
                           CAL_XMAX);
                if (i1 >= txn_count || t_kind[i1] !== 1'b1 || t_reg[i1] !== CAL_YMAX || t_bytes[i1] !== 2)
                    $fatal(1, "s%d: transaction %0d is a %0d byte %b of %04h, a 2 byte read of %04h expected",
                           id, i1, (i1 < txn_count) ? t_bytes[i1] : -1,
                           (i1 < txn_count) ? t_kind[i1] : 1'bx,
                           (i1 < txn_count) ? t_reg[i1] : 16'hxxxx,
                           CAL_YMAX);
                if (i2 >= txn_count || t_kind[i2] !== 1'b1 || t_reg[i2] !== CAL_SWITCH || t_bytes[i2] !== 1)
                    $fatal(1, "s%d: transaction %0d is a %0d byte %b of %04h, a 1 byte read of %04h expected",
                           id, i2, (i2 < txn_count) ? t_bytes[i2] : -1,
                           (i2 < txn_count) ? t_kind[i2] : 1'bx,
                           (i2 < txn_count) ? t_reg[i2] : 16'hxxxx,
                           CAL_SWITCH);
                // The first poll still reads the status register and clears the flag.
                if (i3 >= txn_count || t_kind[i3] !== 1'b1 || t_reg[i3] !== ST_REG || t_bytes[i3] !== 1)
                    $fatal(1, "s%d: transaction %0d after the calibration is not a 1 byte read of %04h",
                           id, i3, ST_REG);
                if (touch_error !== 1'b0)
                    $fatal(1, "s%d: an acknowledged controller reported a NACK during power up", id);
            end

            check_calibration();

            // ---- ONE-TIME, not every poll.  Exactly one COMPLETED read of each of the
            // three registers per scenario, no matter how many polls follow.  The
            // refused scenario is the one exception, and it is zero rather than
            // one because a refused transaction never completes: it is counted in
            // abort_stop_cnt above instead.
            exp_cal_reads = scen_nack ? 0 : 1;
            if ((count_reg(CAL_XMAX) - n0x) !== exp_cal_reads)
                $fatal(1, "s%d: %0d completed reads of %04h in this scenario (%0d total, %0d before), %0d expected",
                       id, count_reg(CAL_XMAX) - n0x, CAL_XMAX, count_reg(CAL_XMAX), n0x, exp_cal_reads);
            if ((count_reg(CAL_YMAX) - n0y) !== exp_cal_reads)
                $fatal(1, "s%d: %0d completed reads of %04h in this scenario (%0d total, %0d before), %0d expected",
                       id, count_reg(CAL_YMAX) - n0y, CAL_YMAX, count_reg(CAL_YMAX), n0y, exp_cal_reads);
            if ((count_reg(CAL_SWITCH) - n0s) !== exp_cal_reads)
                $fatal(1, "s%d: %0d completed reads of %04h in this scenario (%0d total, %0d before), %0d expected",
                       id, count_reg(CAL_SWITCH) - n0s, CAL_SWITCH, count_reg(CAL_SWITCH), n0s, exp_cal_reads);
            n_cal_total = n_cal_total + ((count_reg(CAL_XMAX) - n0x) +
                                         (count_reg(CAL_YMAX) - n0y) +
                                         (count_reg(CAL_SWITCH) - n0s));

            if (pol0 >= poll_cnt)
                $fatal(1, "s%d: the controller did not poll after init_done", id);
            if (touch_valid !== 1'b0)
                $fatal(1, "s%d: a controller reporting no touch must not set touch_valid", id);
            if (dpad !== 4'b0000)
                $fatal(1, "s%d: no touch must leave the dpad at 0000, it is %b", id, dpad);
            if (buttons !== 8'h00)
                $fatal(1, "s%d: no touch and no key must leave buttons at 00, they are %02h", id, buttons);
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
        // Before the calibration has run there is nothing to show, and the cuts in
        // the region map are the compile-time ones so the map is already usable.
        if (touch_x_left_edge !== XL || touch_x_right_edge !== XR || touch_y_mid_edge !== YM)
            $fatal(1, "the region cuts before any calibration are %0d/%0d/%0d, %0d/%0d/%0d expected",
                   touch_x_left_edge, touch_x_right_edge, touch_y_mid_edge, XL, XR, YM);
        if (touch_calib_ok !== 1'b0)
            $fatal(1, "touch_calib_ok must be low out of reset");

        mon_en = 1;
        reset_seen_low = 1'b1;
        reset_fall_time = 0.0;

        // =====================================================================
        // Scenario 1: the honest module, 799 x 479, X2Y clear.  The cuts move to
        // 199 / 600 / 239, which is already not the hardcoded 200 / 600 / 240.
        // =====================================================================
        $display("--- scenario 1: controller reports 799x479, Module_Switch1=%02h",
                 8'h30);
        run_scenario(1);

        base = txn_count;
        check_region(16'd400, 16'd100, 4'b1000);
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

        // The 4 byte fetch from CT_COORD_REG is untouched by the calibration, so
        // the same byte-level walk of the region map still holds; only the numbers
        // the sweep uses are the calibrated ones.
        region_sweep();

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
        if (swap_active !== 1'b0)
            $fatal(1, "scenario 1 must not swap the axes");
        present_panel(16'd0, 16'd0);
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

        // Release the report; exp_btn is the low nibble expected once it is gone.
        x_val = 16'h0000; y_val = 16'h0000; status_val = 8'h00;
        int_drive = 1'b1; ct_int = 1'b1;
        guard = 0;
        while (touch_valid !== 1'b0 && guard < 400000) begin
            @(negedge clk);
            guard = guard + 1;
        end
        if (touch_valid !== 1'b0)
            $fatal(1, "the touch never released");
        guard = 0;
        while (buttons[3:0] !== 8'h03 && guard < 400000) begin
            @(negedge clk);
            guard = guard + 1;
        end
        if (buttons[3:0] !== 8'h03)
            $fatal(1, "releasing the touch gave buttons %02h, 03 expected", buttons);
        if (dpad !== 4'b0000)
            $fatal(1, "releasing the touch must clear the dpad, it is %b", dpad);
        wait_quiet();

        // The TPAD is what promotes the keys.  It is a discrete button on F16 and it
        // is ACTIVE HIGH, the opposite of the two keys, so it is driven high here.
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
        present_panel(16'd0, 16'd0);
        if (buttons !== 8'h2C)
            $fatal(1, "the TPAD held with a reported touch gave buttons %02h, 2c expected", buttons);
        if (dpad !== 4'b0010)
            $fatal(1, "the touch dpad must survive the TPAD substitution, dpad is %b", dpad);

        wait_quiet();
        guard = 0;
        while (buttons[3:0] !== 8'h0C && guard < 400000) begin
            @(negedge clk);
            guard = guard + 1;
        end
        if (buttons[3:0] !== 8'h0C)
            $fatal(1, "releasing the touch with the TPAD held gave buttons %02h, 0c expected", buttons);

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

        // ---- the NACK recovery path, which is about the POLL and not the
        // calibration, so it is exercised once and not per scenario.
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

        nack_reg = 1'b0;
        present  = 1'b1;
        settle(4);

        check_region(exp_xr, exp_ym + 240, 4'b0001);
        if (touch_error !== 1'b1)
            $fatal(1, "touch_error must stay set once a NACK has been seen");

        // =====================================================================
        // Scenario 2: a transposed frame.  X2Y is set, so the driver has to
        // exchange the two 16 bit words.  A pass-through fails here.
        // =====================================================================
        $display("--- scenario 2: controller reports 1023x639, Module_Switch1=%02h, X2Y set",
                 8'h68);
        run_scenario(2);
        region_sweep();

        // =====================================================================
        // Scenario 3: the same module family at 480x272, ATK-4342.  The cuts have
        // to be 119 / 360 / 135, which is nowhere near 800x480 at all.
        // =====================================================================
        $display("--- scenario 3: controller reports 479x271 (ATK-4342), Module_Switch1=%02h",
                 8'h00);
        run_scenario(3);
        if (touch_x_left_edge !== 16'd119 || touch_x_right_edge !== 16'd360 ||
            touch_y_mid_edge !== 16'd135)
            $fatal(1, "s3: the 480x272 cuts are %0d/%0d/%0d, 119/360/135 expected",
                   touch_x_left_edge, touch_x_right_edge, touch_y_mid_edge);
        region_sweep();

        // =====================================================================
        // Scenario 4: every calibration read NACKed.  No garbage in the cuts, the
        // compile-time constants instead, and the flag says so.
        // =====================================================================
        $display("--- scenario 4: calibration NACKed, must fall back to %0d/%0d/%0d",
                 XL, XR, YM);
        run_scenario(4);
        if (touch_x_left_edge !== XL || touch_x_right_edge !== XR || touch_y_mid_edge !== YM)
            $fatal(1, "s4: the cuts are %0d/%0d/%0d, the constants %0d/%0d/%0d expected",
                   touch_x_left_edge, touch_x_right_edge, touch_y_mid_edge, XL, XR, YM);
        if (touch_x2y !== 1'b0)
            $fatal(1, "s4: a refused calibration read still asserted X2Y");
        if (touch_calib_ok !== 1'b0)
            $fatal(1, "s4: a refused calibration read claimed to be calibrated");
        region_sweep();

        // =====================================================================
        // Scenario 5: every calibration read all ones, a bus stuck high.  Same
        // fallback, and the cuts must not become 16383 / 49149 / 32767.
        // =====================================================================
        $display("--- scenario 5: calibration reads all ones, must fall back to %0d/%0d/%0d",
                 XL, XR, YM);
        run_scenario(5);
        if (touch_x_max !== 16'hFFFF || touch_y_max !== 16'hFFFF)
            $fatal(1, "s5: the model reported all ones, the driver published x_max=%0d y_max=%0d",
                   touch_x_max, touch_y_max);
        if (touch_x_left_edge !== XL || touch_x_right_edge !== XR || touch_y_mid_edge !== YM)
            $fatal(1, "s5: the cuts are %0d/%0d/%0d, the constants %0d/%0d/%0d expected",
                   touch_x_left_edge, touch_x_right_edge, touch_y_mid_edge, XL, XR, YM);
        if (touch_x2y !== 1'b0)
            $fatal(1, "s5: an all ones Module_Switch1 asserted X2Y");
        if (touch_calib_ok !== 1'b0)
            $fatal(1, "s5: an all ones calibration claimed to be calibrated");
        region_sweep();

        // =====================================================================
        // NON-VACUITY, at the end, over the whole run.  Without this the sweep
        // above would pass identically whether the driver calibrated or not.
        // =====================================================================
        if (nonvacuous_cases < 1) begin
            $fatal(1, "NON-VACUITY: every scenario produced the hardcoded cuts %0d/%0d/%0d, so this bench cannot tell the calibration from the constants",
                   XL, XR, YM);
        end
        // Four scenarios read the calibration registers; scenario 4's single read
        // was refused and a refused transaction is never logged as a completed one.
        if (n_cal_total !== 12)
            $fatal(1, "%0d completed calibration reads over five scenarios, 12 expected (3 per scenario, none for the refused one)",
                   n_cal_total);

        $display("tb_nes_touch_input: %0d transactions, %0d START, %0d repeated START, %0d STOP",
                 txn_count, start_cnt, rep_start_cnt, stop_cnt);
        $display("tb_nes_touch_input: %0d address matches, %0d flag clears, %0d aborted, %0d polls",
                 addr_ok_cnt, clr_cnt, abort_stop_cnt, poll_cnt);
        $display("tb_nes_touch_input: %0d calibration reads completed, %0d scenarios landed off the constants %0d/%0d/%0d",
                 n_cal_total, nonvacuous_cases, XL, XR, YM);
        $display("tb_nes_touch_input: debounce %0d clk, A after %0d clk", DEBOUNCE, a_press_g);
        $display("tb_nes_touch_input: keys alone give A/B, a screen touch leaves them at A/B, only the TPAD promotes them to Start/Select");
        $display("PASS nes_touch_input");
        $finish;
    end

    initial begin
        #1500000000;
        $fatal(1, "tb_nes_touch_input global timeout");
    end

endmodule
