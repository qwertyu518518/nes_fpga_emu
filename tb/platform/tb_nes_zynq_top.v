`timescale 1ns/1ps

// ============================================================================
// tb_nes_zynq_top : gate testbench for the Zynq-7020 platform top
// ----------------------------------------------------------------------------
// The top is a wiring layer.  Its submodules are already gated on their own, so
// this bench does NOT re-test the PPU, the mapper or the scaler arithmetic.  It
// proves the four things that only exist at this level and nowhere else:
//
//   1. The three clock domains really are three domains, at the right ratios.
//      A behavioural MMCME2_BASE model (mmcm_e2_base_sim, reused from
//      tb_nes_zynq_clk.v, which this bench compiles in) produces the real
//      core_clk and lcd_clk, so the measured frame periods are the real ones.
//
//   2. The reset network.  Three independent per-domain chains, active high,
//      async assert on !sys_rst_n and sync release, each ANDed with its own
//      two-flop synchroniser of the MMCM locked.  The core must be held in
//      reset while locked is low, in BOTH the core and the lcd domain, and
//      must release only after it goes high.
//
//   3. The two panel pins the top owns.  lcd_rst is held low after power-on
//      and released; lcd_bl must not come up before that release.
//
//   4. The two conversion tables the top owns.  The 64-entry palette LUT and
//      the RGB565 -> RGB888 expansion, plus the lcd_rgb tri-state behaviour and
//      the buttons 2-FF crossing.
//
//   5. The touch lane.  This top owns the two panel I2C pins, so it is the only
//      place where the open drain contract on touch_scl and touch_sda can be
//      observed at all.  A behavioural GT9147 slave ACKs the controller and
//      answers the status and coordinate register reads; the bus is then watched
//      for the whole run so a push-pull driver cannot hide in a quiet window.
//
// ANTI-CIRCULARITY ON THE PALETTE
//   The expected values are built from a SECOND, independent transcription of
//   .slim/clonedeps/repos/caseif__cNES/src/ppu.c:94-111 as RGB888 triples,
//   converted in the bench by the same documented law R5=R8>>3, G6=G8>>2,
//   B5=B8>>3.  Asserting the rtl LUT against that would still only prove two
//   transcriptions agree, so a third, independent check is layered on top: a
//   list of NES palette entries whose correct RGB888 value is known from the
//   hardware rather than from either transcription, hardcoded here as literals.
//   Those anchors include $0F, which is the blanking entry and therefore BLACK,
//   not white; white is $20 and $30.
//
// FRAME-RATE RATIO
//   The cheap end-to-end sanity check.  The core frame period is
//   262*341*4 core clocks = 357368 core clocks = 16.6379 ms, and the panel frame
//   period is 1056*525 lcd clocks = 554400 lcd clocks = 22.1760 ms, so
//   panel_frames / core_frames must be 16.6379/22.1760 = 0.7503.  If the clocking
//   or the frame buffer were wrong this ratio would not be 0.75.
// ============================================================================

module tb_nes_zynq_top;

    localparam real CORE_PERIOD_NS   = 46.560846560846;
    localparam real LCD_PERIOD_NS    = 40.0;
    localparam integer CORE_FRAME_NS = 16637856;
    localparam integer LCD_FRAME_NS  = 22176000;
    // Tolerance in parts per thousand, applied as X*(1000+/-TOL)/1000.  The
    // earlier form X*(100+TOL)/100 silently rounded to zero tolerance, because
    // integer division of a sub-ns remainder truncates.
    localparam integer TOL_PERMILLE  = 5;

    // Frame counts to observe before the end of the run.
    localparam integer WANT_CORE_FRAMES = 3;
    localparam integer WANT_LCD_FRAMES  = 2;

    reg sys_clk;
    reg sys_rst_n;
    reg [1:0] key;
    wire [23:0] lcd_rgb;
    wire lcd_hs;
    wire lcd_vs;
    wire lcd_de;
    wire lcd_bl;
    wire lcd_clk;
    wire lcd_rst;
    tri  touch_scl;
    tri  touch_sda;
    wire touch_rst_n;
    reg  touch_int;

    integer errors;
    integer k;
    integer idx;
    integer exp_r8;
    integer exp_g8;
    integer exp_b8;
    integer got_rgb;
    integer ref565_i;
    integer core_frames;
    integer lcd_frames;
    integer t_core_first;
    integer t_core_last;
    integer t_lcd_first;
    integer t_lcd_last;
    integer core_period_ns;
    integer lcd_period_ns;
    integer core_window;
    integer lcd_window;
    integer ratio_milli;
    real    ratio_real;
    integer expect_ratio_milli;
    integer rst_seen;
    integer t_rst_rel_ns;
    integer locked_at_ns;
    integer core_rst_release_ns;
    integer lcd_rst_release_ns;
    integer lcd_rst_pin_high_ns;
    integer lcd_bl_pin_high_ns;
    integer btn_converged_ns;
    integer t_key_down_ns;
    integer btn_phase;
    integer touch_base;
    integer touch_guard;
    integer touch_err_base;
    integer z_seen;
    integer de_seen;

    reg locked_r;
    reg [7:0]  pal_drv;
    reg [15:0] exp_drv;
    reg [7:0]  btn_drv;
    reg        de_drv;
    reg core_frame_d_r;
    reg lcd_frame_p_r;

    // touch_scl and touch_sda are the open-drain side of the panel I2C bus.  The
    // bench models the panel side pull-up on BOTH lines so neither is ever Z:
    // nes_zynq_top.xdc constrains the two pins with no PULLUP anywhere, so the
    // board module carries them and the model has to as well.  touch_scl was a
    // passive wire here while touch_sda had a pull-up, which is precisely why a
    // push-pull touch_scl driver in the top was invisible here.
    pullup pu_scl (touch_scl);
    pullup pu_sda (touch_sda);

    nes_zynq_top dut (        .sys_clk     (sys_clk),
        .sys_rst_n   (sys_rst_n),
        .key         (key),
        .lcd_rgb     (lcd_rgb),
        .lcd_hs      (lcd_hs),
        .lcd_vs      (lcd_vs),
        .lcd_de      (lcd_de),
        .lcd_bl      (lcd_bl),
        .lcd_clk     (lcd_clk),
        .lcd_rst     (lcd_rst),
        .touch_scl   (touch_scl),
        .touch_sda   (touch_sda),
        .touch_rst_n (touch_rst_n),
        .touch_int   (touch_int)
    );

    task err;
        input [8*44:1] code;
        input integer a;
        input integer b;
        begin
            errors = errors + 1;
            if (errors <= 30)
                $display("VIOLATION %0s a=%0d b=%0d t=%0t", code, a, b, $time);
        end
    endtask

    // ---------------------------------------------------------------------
    // Behavioural GT9147 slave on the touch bus.
    //
    // The panel is the only other device on touch_scl / touch_sda and it is open
    // drain like the master: it pulls a line low and otherwise releases it.  It
    // ACKs every byte addressed to 7'h14 and answers the two register reads the
    // controller makes, 16'h814E for the status and 16'h8150 for the four
    // coordinate bytes.  The register pointer survives a repeated START, which is
    // how the controller issues write-two-bytes-then-repeated-START-read.
    //
    // The decode is deliberately the same shape as the module bench's: sample on
    // the SCL rising edge, decide and present ACK or data on the SCL falling
    // edge, release on the falling edge that ends the slot.  Presenting anything
    // while SCL is low is what keeps the panel's own edges from being mistaken
    // for START or STOP.
    // ---------------------------------------------------------------------
    localparam [6:0]  SL_ADDR  = 7'h14;
    localparam [15:0] SL_STREG = 16'h814E;
    localparam [15:0] SL_COREG = 16'h8150;

    localparam [1:0] SL_RX      = 2'd0;
    localparam [1:0] SL_ACK     = 2'd1;
    localparam [1:0] SL_TX      = 2'd2;
    localparam [1:0] SL_TX_ACK  = 2'd3;

    localparam       SL_POST_IDLE = 1'b0;
    localparam       SL_POST_TX   = 1'b1;

    reg         sl_scl_low = 1'b0;
    reg         sl_sda_low = 1'b0;    reg  [1:0]  sl_state   = SL_RX;
    reg  [7:0]  sl_rx      = 8'h00;
    integer     sl_bit     = 0;
    integer     sl_byte    = 0;
    reg  [15:0] sl_ptr     = 16'h0000;
    reg  [15:0] sl_rd_base = 16'h0000;
    integer     sl_rd_idx  = 0;
    reg         sl_is_read = 1'b0;
    reg         sl_post    = SL_POST_IDLE;
    reg  [7:0]  sl_tx      = 8'h00;
    integer     sl_tx_bit  = 7;
    reg         sl_master_ack = 1'b1;
    reg         sl_in_txn  = 1'b0;
    reg  [15:0] sl_hold_cnt = 16'hFFFF;

    reg  [7:0]  sl_status  = 8'h00;
    reg  [15:0] sl_x       = 16'd100;
    reg  [15:0] sl_y       = 16'd120;

    integer sl_start_cnt  = 0;
    integer sl_stop_cnt   = 0;
    integer sl_addr_hits  = 0;
    integer sl_flag_clr   = 0;
    integer sl_coord_rds  = 0;
    integer scl_probe_bad = 0;
    integer bus_xcl       = 0;
    integer bus_xsda      = 0;
    integer bus_pp_sda    = 0;

    assign touch_scl = sl_scl_low ? 1'b0 : 1'bz;
    assign touch_sda = sl_sda_low ? 1'b0 : 1'bz;

    // The panel holding SCL low for a bounded window is ordinary I2C: it is how
    // a slave keeps the master from starting a new transfer until it is ready.
    always @(posedge sys_clk) begin
        if (sl_scl_low !== 1'b0) begin
            if (sl_hold_cnt != 16'd0) begin
                sl_hold_cnt = sl_hold_cnt - 16'd1;
            end else begin
                sl_scl_low = 1'b0;
                sl_hold_cnt = 16'hFFFF;
            end
        end
    end

    function sl_want_ack;
        begin
            if (sl_byte == 0) sl_want_ack = (sl_rx[7:1] == SL_ADDR);
            else              sl_want_ack = 1'b1;
        end
    endfunction

    task sl_load_rd_byte;
        begin
            if (sl_rd_base == SL_STREG) begin
                sl_tx = sl_status;
            end else if (sl_rd_base == SL_COREG) begin
                case (sl_rd_idx)
                    0:       sl_tx = sl_x[7:0];
                    1:       sl_tx = sl_x[15:8];
                    2:       sl_tx = sl_y[7:0];
                    default: sl_tx = sl_y[15:8];
                endcase
                if (sl_rd_idx == 0) sl_coord_rds = sl_coord_rds + 1;
            end else begin
                sl_tx = 8'h00;
            end
            sl_rd_idx = sl_rd_idx + 1;
        end
    endtask

    task sl_byte_done;
        begin
            if (sl_byte == 0) begin
                sl_is_read = sl_rx[0];
                sl_byte    = 1;
                sl_post    = SL_POST_IDLE;
                if (sl_rx[7:1] == SL_ADDR) begin
                    sl_addr_hits = sl_addr_hits + 1;
                    if (sl_is_read) begin
                        sl_rd_base = sl_ptr;
                        sl_rd_idx  = 0;
                        sl_post    = SL_POST_TX;
                        sl_load_rd_byte();
                    end
                end
            end else if (sl_byte == 1) begin
                sl_ptr[15:8] = sl_rx;
                sl_byte      = 2;
            end else if (sl_byte == 2) begin
                sl_ptr[7:0]  = sl_rx;
                sl_byte      = 3;
            end else begin
                if (sl_ptr == SL_STREG) begin
                    sl_flag_clr = sl_flag_clr + 1;
                    sl_status   = 8'h00;
                end
            end
        end
    endtask

    always @(posedge touch_scl) begin
        if (sl_state == SL_RX && sl_bit < 8) begin
            sl_rx[7 - sl_bit] = touch_sda;
            sl_bit = sl_bit + 1;
        end else if (sl_state == SL_ACK) begin
            sl_byte_done();
        end else if (sl_state == SL_TX_ACK) begin
            sl_master_ack = touch_sda;
        end
    end

    always @(negedge touch_scl) begin
        if (sl_state == SL_RX && sl_bit == 8) begin
            sl_sda_low = sl_want_ack();
            sl_state   = SL_ACK;
        end else if (sl_state == SL_ACK) begin
            sl_bit     = 0;
            sl_sda_low = 1'b0;
            sl_state   = SL_RX;
            if (sl_post == SL_POST_TX) begin
                sl_tx_bit  = 7;
                sl_sda_low = ~sl_tx[7];
                sl_state   = SL_TX;
            end
        end else if (sl_state == SL_TX) begin
            if (sl_tx_bit == 0) begin
                sl_sda_low = 1'b0;
                sl_state   = SL_TX_ACK;
            end else begin
                sl_tx_bit  = sl_tx_bit - 1;
                sl_sda_low = ~sl_tx[sl_tx_bit];
            end
        end else if (sl_state == SL_TX_ACK) begin
            sl_bit = 0;
            if (sl_master_ack === 1'b0) begin
                sl_load_rd_byte();
                sl_tx_bit  = 7;
                sl_sda_low = ~sl_tx[7];
                sl_state   = SL_TX;
            end else begin
                sl_state   = SL_RX;
            end
        end
    end

    always @(negedge touch_sda) begin
        if (touch_scl === 1'b1) begin
            sl_start_cnt = sl_start_cnt + 1;
            sl_in_txn    = 1'b1;
            sl_byte      = 0;
            sl_bit       = 0;
            sl_rx        = 8'h00;
            sl_state     = SL_RX;
            sl_post      = SL_POST_IDLE;
            sl_sda_low   = 1'b0;
        end
    end

    always @(posedge touch_sda) begin
        if (touch_scl === 1'b1) begin
            if (sl_in_txn) sl_stop_cnt = sl_stop_cnt + 1;
            sl_in_txn  = 1'b0;
            sl_sda_low = 1'b0;
            sl_state   = SL_RX;
        end
    end

    // ---------------------------------------------------------------------
    // Open drain contract on the two panel pins, observed on the real nets.
    //
    // X on either line is the only way a push-pull driver shows up here: a
    // strong one against the panel's strong zero resolves to X, while a correct
    // open-drain driver simply loses and lets the zero win.  The second check is
    // the direct form of the same contract on the master's own drive request.
    // ---------------------------------------------------------------------
    always @(posedge sys_clk) begin
        if (touch_scl === 1'bx) bus_xcl = bus_xcl + 1;
        if (touch_sda === 1'bx) bus_xsda = bus_xsda + 1;
        if (dut.touch_sda_oe === 1'b1 && dut.touch_sda_o === 1'b1) bus_pp_sda = bus_pp_sda + 1;
        // While the panel holds SCL low the wire must read low, whether or not the
        // master happens to be releasing it at that instant.
        if (sl_scl_low !== 1'b0 && touch_scl !== 1'b0) scl_probe_bad = scl_probe_bad + 1;
    end

    // ---------------------------------------------------------------------
    // Reference palette: a second, independent transcription of
    // caseif__cNES/src/ppu.c:94-111 as RGB888, r, g, b in that order.
    // ---------------------------------------------------------------------
    function integer ref_r;
        input integer i;
        begin
            case (i)
                0:  ref_r = 8'h66;  1:  ref_r = 8'h00;  2:  ref_r = 8'h0E;  3:  ref_r = 8'h44;
                4:  ref_r = 8'h71;  5:  ref_r = 8'h89;  6:  ref_r = 8'h86;  7:  ref_r = 8'h69;
                8:  ref_r = 8'h39;  9:  ref_r = 8'h04;  10: ref_r = 8'h00;  11: ref_r = 8'h00;
                12: ref_r = 8'h00;  13: ref_r = 8'h00;  14: ref_r = 8'h00;  15: ref_r = 8'h00;
                16: ref_r = 8'hAD;  17: ref_r = 8'h00;  18: ref_r = 8'h3B;  19: ref_r = 8'h80;
                20: ref_r = 8'hBB;  21: ref_r = 8'hDB;  22: ref_r = 8'hD7;  23: ref_r = 8'hB1;
                24: ref_r = 8'h73;  25: ref_r = 8'h2D;  26: ref_r = 8'h00;  27: ref_r = 8'h00;
                28: ref_r = 8'h00;  29: ref_r = 8'h00;  30: ref_r = 8'h00;  31: ref_r = 8'h00;
                32: ref_r = 8'hFF;  33: ref_r = 8'h4B;  34: ref_r = 8'h8A;  35: ref_r = 8'hD1;
                36: ref_r = 8'hFF;  37: ref_r = 8'hFF;  38: ref_r = 8'hFF;  39: ref_r = 8'hFF;
                40: ref_r = 8'hC4;  41: ref_r = 8'h7D;  42: ref_r = 8'h41;  43: ref_r = 8'h21;
                44: ref_r = 8'h25;  45: ref_r = 8'h4F;  46: ref_r = 8'h00;  47: ref_r = 8'h00;
                48: ref_r = 8'hFF;  49: ref_r = 8'hB6;  50: ref_r = 8'hD0;  51: ref_r = 8'hED;
                52: ref_r = 8'hFF;  53: ref_r = 8'hFF;  54: ref_r = 8'hFF;  55: ref_r = 8'hFF;
                56: ref_r = 8'hE7;  57: ref_r = 8'hCA;  58: ref_r = 8'hB2;  59: ref_r = 8'hA5;
                60: ref_r = 8'hA6;  61: ref_r = 8'hB8;  62: ref_r = 8'h00;  63: ref_r = 8'h00;
                default: ref_r = 8'h00;
            endcase
        end
    endfunction

    function integer ref_g;
        input integer i;
        begin
            case (i)
                0:  ref_g = 8'h66;  1:  ref_g = 8'h1E;  2:  ref_g = 8'h09;  3:  ref_g = 8'h00;
                4:  ref_g = 8'h00;  5:  ref_g = 8'h01;  6:  ref_g = 8'h13;  7:  ref_g = 8'h29;
                8:  ref_g = 8'h3E;  9:  ref_g = 8'h4C;  10: ref_g = 8'h4F;  11: ref_g = 8'h47;
                12: ref_g = 8'h35;  13: ref_g = 8'h00;  14: ref_g = 8'h00;  15: ref_g = 8'h00;
                16: ref_g = 8'hAD;  17: ref_g = 8'h50;  18: ref_g = 8'h34;  19: ref_g = 8'h22;
                20: ref_g = 8'h1E;  21: ref_g = 8'h29;  22: ref_g = 8'h40;  23: ref_g = 8'h5E;
                24: ref_g = 8'h79;  25: ref_g = 8'h8B;  26: ref_g = 8'h8F;  27: ref_g = 8'h84;
                28: ref_g = 8'h6D;  29: ref_g = 8'h00;  30: ref_g = 8'h00;  31: ref_g = 8'h00;
                32: ref_g = 8'hFF;  33: ref_g = 8'hA0;  34: ref_g = 8'h84;  35: ref_g = 8'h72;
                36: ref_g = 8'h6D;  37: ref_g = 8'h79;  38: ref_g = 8'h90;  39: ref_g = 8'hAE;
                40: ref_g = 8'hCA;  41: ref_g = 8'hDC;  42: ref_g = 8'hE1;  43: ref_g = 8'hD5;
                44: ref_g = 8'hBE;  45: ref_g = 8'h4F;  46: ref_g = 8'h00;  47: ref_g = 8'h00;
                48: ref_g = 8'hFF;  49: ref_g = 8'hD8;  50: ref_g = 8'hCD;  51: ref_g = 8'hC6;
                52: ref_g = 8'hC4;  53: ref_g = 8'hC8;  54: ref_g = 8'hD2;  55: ref_g = 8'hDE;
                56: ref_g = 8'hE9;  57: ref_g = 8'hF1;  58: ref_g = 8'hF3;  59: ref_g = 8'hEE;
                60: ref_g = 8'hE5;  61: ref_g = 8'hB8;  62: ref_g = 8'h00;  63: ref_g = 8'h00;
                default: ref_g = 8'h00;
            endcase
        end
    endfunction

    function integer ref_b;
        input integer i;
        begin
            case (i)
                0:  ref_b = 8'h66;  1:  ref_b = 8'h9A;  2:  ref_b = 8'hA8;  3:  ref_b = 8'h93;
                4:  ref_b = 8'h60;  5:  ref_b = 8'h1D;  6:  ref_b = 8'h00;  7:  ref_b = 8'h00;
                8:  ref_b = 8'h00;  9:  ref_b = 8'h00;  10: ref_b = 8'h00;  11: ref_b = 8'h2B;
                12: ref_b = 8'h6C;  13: ref_b = 8'h00;  14: ref_b = 8'h00;  15: ref_b = 8'h00;
                16: ref_b = 8'hAD;  17: ref_b = 8'hF1;  18: ref_b = 8'hFF;  19: ref_b = 8'hE8;
                20: ref_b = 8'hA5;  21: ref_b = 8'h4E;  22: ref_b = 8'h00;  23: ref_b = 8'h00;
                24: ref_b = 8'h00;  25: ref_b = 8'h00;  26: ref_b = 8'h08;  27: ref_b = 8'h60;
                28: ref_b = 8'hB5;  29: ref_b = 8'h00;  30: ref_b = 8'h00;  31: ref_b = 8'h00;
                32: ref_b = 8'hFF;  33: ref_b = 8'hFF;  34: ref_b = 8'hFF;  35: ref_b = 8'hFF;
                36: ref_b = 8'hF7;  37: ref_b = 8'h9E;  38: ref_b = 8'h47;  39: ref_b = 8'h0A;
                40: ref_b = 8'h00;  41: ref_b = 8'h13;  42: ref_b = 8'h57;  43: ref_b = 8'hB0;
                44: ref_b = 8'hFF;  45: ref_b = 8'h4F;  46: ref_b = 8'h00;  47: ref_b = 8'h00;
                48: ref_b = 8'hFF;  49: ref_b = 8'hFF;  50: ref_b = 8'hFF;  51: ref_b = 8'hFF;
                52: ref_b = 8'hFC;  53: ref_b = 8'hD8;  54: ref_b = 8'hB4;  55: ref_b = 8'h9C;
                56: ref_b = 8'h94;  57: ref_b = 8'h9F;  58: ref_b = 8'hBB;  59: ref_b = 8'hDF;
                60: ref_b = 8'hFF;  61: ref_b = 8'hB8;  62: ref_b = 8'h00;  63: ref_b = 8'h00;
                default: ref_b = 8'h00;
            endcase
        end
    endfunction

    // RGB888 -> RGB565, the documented law, applied to the bench's own table.
    function integer ref_565;
        input integer i;
        begin
            ref_565 = (((ref_r(i) >> 3) & 32'h1F) << 11)
                    | (((ref_g(i) >> 2) & 32'h3F) << 5)
                    |  ((ref_b(i) >> 3) & 32'h1F);
        end
    endfunction

    // RGB565 -> RGB888 with full-scale bit replication, the bench's own model.
    function integer exp_888;
        input integer v;
        integer r5;
        integer g6;
        integer b5;
        begin
            r5 = (v >> 11) & 32'h1F;
            g6 = (v >> 5) & 32'h3F;
            b5 = v & 32'h1F;
            exp_888 = (((r5 << 3) | (r5 >> 2)) << 16)
                    | (((g6 << 2) | (g6 >> 4)) << 8)
                    |  ((b5 << 3) | (b5 >> 2));
        end
    endfunction

    // ---------------------------------------------------------------------
    // Frames.  Sampled per domain so no synchroniser is needed in the bench.
    // BOTH are counted on the RISING EDGE only.  nes_ppu2c02 clears frame_done
    // on every `ce`, and `ce` is ce_ppu, which is one core clock in four, so
    // frame_done is high for four consecutive core clocks.  Counting the level
    // would score a single frame four times and report a frame period of two
    // core clocks.  Edge detection makes the count frame-period agnostic.
    // ---------------------------------------------------------------------
    always @(posedge dut.mmcm_core_clk) begin
        core_frame_d_r <= dut.core_frame_done;
        if (dut.core_frame_done && !core_frame_d_r) begin
            core_frames = core_frames + 1;
            if (core_frames == 1) t_core_first = $time;
            if (core_frames == WANT_CORE_FRAMES) t_core_last = $time;
        end
    end

    always @(posedge dut.mmcm_lcd_clk) begin
        lcd_frame_p_r <= dut.vid_frame_pulse;
        if (dut.vid_frame_pulse && !lcd_frame_p_r) begin
            lcd_frames = lcd_frames + 1;
            if (lcd_frames == 1) t_lcd_first = $time;
            if (lcd_frames == WANT_LCD_FRAMES) t_lcd_last = $time;
        end
        // lcd_rgb tri-state contract, observed on the real pin.
        if (dut.vid_de) begin
            de_seen = de_seen + 1;
            if (lcd_rgb === 24'hzzzzzz) err("LCD_RGB_Z_DURING_DE", $time, 0);
        end else begin
            z_seen = z_seen + 1;
            if (lcd_rgb !== 24'hzzzzzz) err("LCD_RGB_DRIVEN_WHEN_BLANKED", $time, 0);
        end
    end

    always @(posedge sys_clk) begin
        locked_r <= dut.mmcm_locked;
        if (locked_r && (locked_at_ns == 0)) locked_at_ns = $time;
        if (dut.rst_core === 1'b1) rst_seen = rst_seen + 1;
        // Stored as a DELTA from the sys_rst_n release, because the counter
        // thresholds are specified in sys_clk cycles after that release and an
        // absolute $time would silently depend on how long the bench had been
        // running before the reset was released.
        if (dut.lcd_rst === 1'b1 && lcd_rst_pin_high_ns == 0 && dut.mmcm_locked)
            lcd_rst_pin_high_ns = $time - t_rst_rel_ns;
        if (dut.lcd_bl === 1'b1 && lcd_bl_pin_high_ns == 0) lcd_bl_pin_high_ns = $time - t_rst_rel_ns;
    end

    always @(posedge dut.mmcm_core_clk) begin
        if (dut.rst_core === 1'b0 && core_rst_release_ns == 0) core_rst_release_ns = $time;
    end

    always @(posedge dut.mmcm_lcd_clk) begin
        if (dut.rst_lcd === 1'b0 && lcd_rst_release_ns == 0) lcd_rst_release_ns = $time;
    end

    always #10 sys_clk = ~sys_clk;

    initial begin
        sys_clk  = 1'b0;
        sys_rst_n = 1'b0;
        key      = 2'b11;
        touch_int= 1'b1;
        errors = 0; idx = 0;
        core_frames = 0; lcd_frames = 0;
        t_core_first = 0; t_core_last = 0; t_lcd_first = 0; t_lcd_last = 0;
        core_period_ns = 0; lcd_period_ns = 0;
        core_window = 0; lcd_window = 0;
        ratio_milli = 0; ratio_real = 0.0; expect_ratio_milli = 750;
        rst_seen = 0; locked_at_ns = 0; t_rst_rel_ns = 0;
        core_rst_release_ns = 0; lcd_rst_release_ns = 0;
        lcd_rst_pin_high_ns = 0; lcd_bl_pin_high_ns = 0;
        btn_converged_ns = 0; btn_phase = 0; t_key_down_ns = 0;
        z_seen = 0; de_seen = 0;
        core_frame_d_r = 1'b0; lcd_frame_p_r = 1'b0; locked_r = 1'b0;
        pal_drv = 8'h00; exp_drv = 16'h0000; btn_drv = 8'h00; de_drv = 1'b0;

        // Icarus evaluates a force RHS once, at the time the force executes, so
        // every force here targets a net this bench drives afterwards.  Forcing
        // a changing expression in a loop would freeze at the first value.
        force dut.core_pixel_pal = pal_drv;
        force dut.vid_rgb565     = exp_drv;
        force dut.vid_de         = de_drv;
        force dut.touch_buttons  = btn_drv;

        // ---------------------------------------------- reset and power-up
        repeat (20) @(posedge sys_clk);
        if (dut.rst_core !== 1'b1) err("CORE_NOT_IN_RESET_WHILE_LOCKED_LOW", dut.rst_core, 0);
        if (dut.rst_lcd  !== 1'b1) err("LCD_NOT_IN_RESET_WHILE_LOCKED_LOW", dut.rst_lcd, 0);
        if (dut.rst_sys  !== 1'b1) err("SYS_NOT_IN_RESET_WHILE_LOCKED_LOW", dut.rst_sys, 0);
        if (lcd_rst !== 1'b0) err("LCD_RST_NOT_LOW_AT_POWERUP", lcd_rst, 0);
        if (lcd_bl  !== 1'b0) err("LCD_BL_ON_DURING_RESET", lcd_bl, 0);

        @(negedge sys_clk);
        sys_rst_n = 1'b1;
        t_rst_rel_ns = $time;

        // The MMCM model asserts locked 200 CLKIN1 cycles after RST releases.
        // Nothing may come out of reset before that.
        #1000000;
        if (dut.mmcm_locked !== 1'b1) err("MMCM_NEVER_LOCKED", dut.mmcm_locked, 0);
        // 200 CLKIN1 = 4000 ns, plus the bench's own one-cycle sampling flop.
        if (locked_at_ns - t_rst_rel_ns < 4000 || locked_at_ns - t_rst_rel_ns > 4500)
            err("LOCKED_TIME", locked_at_ns - t_rst_rel_ns, 4000);
        if (core_rst_release_ns === 0) err("CORE_RESET_NEVER_RELEASED", 0, 0);
        if (lcd_rst_release_ns === 0) err("LCD_RESET_NEVER_RELEASED", 0, 0);
        // Two core clocks of synchroniser plus the two-flop release chain.
        if (core_rst_release_ns < locked_at_ns) err("CORE_RELEASED_BEFORE_LOCK", core_rst_release_ns, locked_at_ns);
        if (lcd_rst_release_ns  < locked_at_ns) err("LCD_RELEASED_BEFORE_LOCK", lcd_rst_release_ns, locked_at_ns);
        if (rst_seen < 100) err("CORE_RESET_TOO_SHORT", rst_seen, 100);

        // lcd_rst released at 5000 sys_clk = 100 us after sys_rst_n release,
        // lcd_bl at 20000 sys_clk = 400 us.  Both must have happened by now.
        repeat (30000) @(posedge sys_clk);
        if (lcd_rst_pin_high_ns === 0) err("LCD_RST_NEVER_RELEASED", 0, 0);
        if (lcd_bl_pin_high_ns  === 0) err("LCD_BL_NEVER_ON", 0, 0);
        if (lcd_bl_pin_high_ns <= lcd_rst_pin_high_ns)
            err("LCD_BL_BEFORE_LCD_RST", lcd_bl_pin_high_ns, lcd_rst_pin_high_ns);
        // Expected: rst pin high at 100000 ns, bl pin high at 400000 ns.
        if (lcd_rst_pin_high_ns < 99000 || lcd_rst_pin_high_ns > 101000)
            err("LCD_RST_PIN_TIMING", lcd_rst_pin_high_ns, 100000);
        if (lcd_bl_pin_high_ns < 399000 || lcd_bl_pin_high_ns > 401000)
            err("LCD_BL_PIN_TIMING", lcd_bl_pin_high_ns, 400000);
        if (dut.u_core.buttons2 !== 8'h00) err("BUTTONS2_NOT_TIED_OFF", dut.u_core.buttons2, 0);

        // ----------------------------------------------- palette LUT, 64
        for (idx = 0; idx < 64; idx = idx + 1) begin
            pal_drv = idx[7:0];
            #1;
            ref565_i = ref_565(idx);
            if (dut.pal_rgb565 !== ref565_i[15:0])
                err("PALETTE_LUT", idx, dut.pal_rgb565);
        end
        pal_drv = 8'h00;
        #1;

        // ------------------------- palette anchors, known from the hardware
        // $0F is the blanking entry and is BLACK.  White is $20 and $30.
        if (ref_565(8'h0F) !== 16'h0000) err("ANCHOR_0F_NOT_BLACK", ref_565(8'h0F), 0);
        if (ref_565(8'h20) !== 16'hFFFF) err("ANCHOR_20_NOT_WHITE", ref_565(8'h20), 0);
        if (ref_565(8'h30) !== 16'hFFFF) err("ANCHOR_30_NOT_WHITE", ref_565(8'h30), 0);
        if (ref_565(8'h00) !== 16'h632C) err("ANCHOR_00_NOT_DARKGREY", ref_565(8'h00), 0);
        if (ref_565(8'h10) !== 16'hAD75) err("ANCHOR_10_NOT_LIGHTGREY", ref_565(8'h10), 0);
        if (ref_565(8'h21) !== 16'h4D1F) err("ANCHOR_21_NOT_LIGHTBLUE", ref_565(8'h21), 0);
        if (ref_565(8'h16) !== 16'hD200) err("ANCHOR_16_NOT_DARKORANGE", ref_565(8'h16), 0);
        if (ref_565(8'h26) !== 16'hFC88) err("ANCHOR_26_NOT_SALMON", ref_565(8'h26), 0);
        if (ref_565(8'h27) !== 16'hFD61) err("ANCHOR_27_NOT_GOLD", ref_565(8'h27), 0);
        if (ref_565(8'h2A) !== 16'h470A) err("ANCHOR_2A_NOT_GREEN", ref_565(8'h2A), 0);
        if (ref_565(8'h12) !== 16'h39BF) err("ANCHOR_12_NOT_BLUE", ref_565(8'h12), 0);
        if (ref_565(8'h18) !== 16'h73C0) err("ANCHOR_18_NOT_OLIVE", ref_565(8'h18), 0);
        // The hue sweep from nes_line_buffer_vga would put a red-dominant value
        // at $0F.  Black at $0F is what distinguishes the real NES table.
        if (ref_r(8'h0F) !== 8'h00 || ref_g(8'h0F) !== 8'h00 || ref_b(8'h0F) !== 8'h00)
            err("ANCHOR_0F_NOT_000000", ref_r(8'h0F), 0);

        // ----------------------------------------- RGB565 -> RGB888 expansion
        de_drv = 1'b1;
        exp_drv = 16'h0000;
        #1; if (lcd_rgb !== 24'h000000) err("EXPAND_0000", lcd_rgb, 24'h000000);
        exp_drv = 16'hFFFF;
        #1; if (lcd_rgb !== 24'hFFFFFF) err("EXPAND_FFFF", lcd_rgb, 24'hFFFFFF);
        exp_drv = 16'hF800;
        #1; if (lcd_rgb !== 24'hFF0000) err("EXPAND_RED", lcd_rgb, 24'hFF0000);
        exp_drv = 16'h07E0;
        #1; if (lcd_rgb !== 24'h00FF00) err("EXPAND_GREEN", lcd_rgb, 24'h00FF00);
        exp_drv = 16'h001F;
        #1; if (lcd_rgb !== 24'h0000FF) err("EXPAND_BLUE", lcd_rgb, 24'h0000FF);
        // Partially saturated channels are the discriminating cases: a
        // replication that takes the wrong source bits still gets 0x0000,
        // 0xFFFF and the three full-scale primaries right, and only shows up
        // here.  Each literal is the field's own top bits, worked out by hand.
        exp_drv = 16'h7C00;
        #1; if (lcd_rgb !== 24'h7B8200) err("EXPAND_MID_RED", lcd_rgb, 24'h7B8200);
        exp_drv = 16'h03E0;
        #1; if (lcd_rgb !== 24'h007D00) err("EXPAND_MID_GREEN", lcd_rgb, 24'h007D00);
        exp_drv = 16'h0010;
        #1; if (lcd_rgb !== 24'h000084) err("EXPAND_EIGHTH_BLUE", lcd_rgb, 24'h000084);
        exp_drv = 16'h0008;
        #1; if (lcd_rgb !== 24'h000042) err("EXPAND_SIXTEENTH_BLUE", lcd_rgb, 24'h000042);
        // Exhaustive over all 16 bits of the word.
        for (idx = 0; idx < 65536; idx = idx + 1) begin
            exp_drv = idx[15:0];
            #1;
            got_rgb = exp_888(idx);
            if (lcd_rgb !== got_rgb[23:0]) begin
                err("EXPAND_EXHAUSTIVE", idx, lcd_rgb);
                idx = 65536;
            end
        end
        // Release both forces so the lcd_rgb tri-state counters below only
        // ever see the real raster, never a forced de.
        release dut.vid_rgb565;
        release dut.vid_de;
        de_drv = 1'b0;
        exp_drv = 16'h0000;
        #1;
        de_seen = 0;
        z_seen = 0;
        if (dut.u_core.buttons2 !== 8'h00) err("BUTTONS2_NOT_TIED_OFF", dut.u_core.buttons2, 0);

        // ------------------------------- touch_scl is open drain, regression
        // The controller holds ct_rst_n low for another 9 ms and then waits the
        // vendor's 50 ms, so at this point in the run the bus is guaranteed idle
        // and the master's I2C engine is sitting with scl_o released.  The panel
        // now pulls SCL low for 100 us, exactly as a GT9147 does when it needs
        // the bus.  A push-pull touch_scl driver fights that pull-down and the
        // resolved level is X; an open-drain driver loses and the wire stays low.
        // The pull-up has to exist first: nes_zynq_top.xdc constrains touch_scl
        // with no PULLUP, so the board module supplies it and without this the
        // pin would simply read Z.
        if (dut.touch_scl_o !== 1'b1) err("TOUCH_SCL_NOT_RELEASED_WHILE_IDLE", dut.touch_scl_o, 1);
        sl_hold_cnt = 16'd4999;
        sl_scl_low  = 1'b1;
        repeat (6000) @(posedge sys_clk);
        if (sl_scl_low !== 1'b0) err("TOUCH_SCL_STILL_HELD", sl_scl_low, 0);
        if (touch_scl !== 1'b1) err("TOUCH_SCL_DID_NOT_RECOVER", touch_scl, 1);
        $display("BUS  touch SCL open drain: 5000 clk held low by the panel, %0d cycles the wire was not low",
                 scl_probe_bad);

        // ---------------------------------------------- buttons CDC, real path
        // The synthetic pattern force has to come off first: while it is on,
        // touch_buttons is pinned to btn_drv and the real key path is invisible.
        // key[0] is active low on the board; nes_touch_input debounces it
        // (800 sys_clk = 16000 ns) and raises buttons[0].  Two core clocks
        // later the core-domain copy must show it, and it must hold there.
        release dut.touch_buttons;
        @(negedge sys_clk);
        key[0] = 1'b0;
        t_key_down_ns = $time;
        btn_converged_ns = 0;
        btn_phase = 0;
        // Bounded wait: a real failure must be reported, not waited out to the
        // global timeout with no diagnosis.
        while (btn_phase == 0 && $time - t_rst_rel_ns < 2000000) begin
            @(posedge dut.mmcm_core_clk);
            #1;
            if (dut.btn_sync_q[0] === 1'b1) begin
                btn_phase = 1;
                btn_converged_ns = $time;
            end
        end
        if (btn_phase == 0) begin
            err("BTN_A_NEVER_REACHED_CORE", dut.touch_buttons[0], dut.btn_sync_q[0]);
        end else begin
            // Hold for a while: it must not wander.
            repeat (2000) begin
                @(posedge dut.mmcm_core_clk);
                #1;
                if (dut.btn_sync_q[0] !== 1'b1) err("BTN_A_DROPPED_WHILE_HELD", dut.btn_sync_q[0], 0);
            end
            btn_converged_ns = btn_converged_ns - t_key_down_ns;
            if (btn_converged_ns < 16000) err("BTN_A_CONVERGED_BEFORE_DEBOUNCE", btn_converged_ns, 16000);
            if (btn_converged_ns > 40000) err("BTN_A_CONVERGED_TOO_LATE", btn_converged_ns, 40000);
            $display("CDC key0: touch buttons[0]=%0b core copy[0]=%0b converged %0d ns after press",
                     dut.touch_buttons[0], dut.btn_sync_q[0], btn_converged_ns);
        end
        @(negedge sys_clk);
        key[0] = 1'b1;
        btn_phase = 0;
        while (btn_phase == 0 && $time - t_rst_rel_ns < 2200000) begin
            @(posedge dut.mmcm_core_clk);
            #1;
            if (dut.btn_sync_q[0] === 1'b0) btn_phase = 1;
        end
        if (btn_phase == 0) err("BTN_A_NEVER_RELEASED", dut.btn_sync_q[0], 0);
        else $display("CDC key0 released: core copy[0]=%0b", dut.btn_sync_q[0]);

        // ------------------------- buttons CDC, forced pattern, hold check
        force dut.touch_buttons = btn_drv;
        btn_drv = 8'hA5;
        repeat (4) @(posedge dut.mmcm_core_clk);
        #1;
        if (dut.btn_sync_q !== 8'hA5) err("BTN_CDC_PATTERN", dut.btn_sync_q, 8'hA5);
        btn_drv = 8'h00;
        repeat (4) @(posedge dut.mmcm_core_clk);
        #1;
        if (dut.btn_sync_q !== 8'h00) err("BTN_CDC_RELEASE", dut.btn_sync_q, 8'h00);
        release dut.touch_buttons;
        btn_drv = 8'h00;
        $display("CDC forced pattern 0xA5 crossed sys_clk->core_clk and returned to 0x00 on release");

        // ---------------------------------------------- frame rate ratio run
        while ((core_frames < WANT_CORE_FRAMES) || (lcd_frames < WANT_LCD_FRAMES)) begin
            @(posedge dut.mmcm_core_clk);
        end
        // Let a little more settle so the last events are clean.
        repeat (1000) @(posedge dut.mmcm_core_clk);

        core_period_ns = (t_core_last - t_core_first) / (WANT_CORE_FRAMES - 1);
        lcd_period_ns  = (t_lcd_last  - t_lcd_first)  / (WANT_LCD_FRAMES - 1);
        core_window = t_core_last - t_core_first;
        lcd_window  = t_lcd_last  - t_lcd_first;

        // Tolerances in parts per thousand of the nominal.  The bound is
        // X +/- (X*TOL)/1000 and NOT X*(1000+/-TOL)/1000: the latter multiplies
        // 22176000 by 1005 to get 2.2e10, which overflows a 32-bit integer and
        // silently turns the upper bound into 812043 ns.  Here the largest
        // intermediate is 22176000*5 = 1.1e8, comfortably inside 2^31.
        if (core_period_ns < (CORE_FRAME_NS - ((CORE_FRAME_NS * TOL_PERMILLE) / 1000)))
            err("CORE_FRAME_PERIOD_LOW", core_period_ns, CORE_FRAME_NS);
        if (core_period_ns > (CORE_FRAME_NS + ((CORE_FRAME_NS * TOL_PERMILLE) / 1000)))
            err("CORE_FRAME_PERIOD_HIGH", core_period_ns, CORE_FRAME_NS);
        if (lcd_period_ns < (LCD_FRAME_NS - ((LCD_FRAME_NS * TOL_PERMILLE) / 1000)))
            err("LCD_FRAME_PERIOD_LOW", lcd_period_ns, LCD_FRAME_NS);
        if (lcd_period_ns > (LCD_FRAME_NS + ((LCD_FRAME_NS * TOL_PERMILLE) / 1000)))
            err("LCD_FRAME_PERIOD_HIGH", lcd_period_ns, LCD_FRAME_NS);

        // Ratio of the two periods.  The quantity that must come out at 0.75 is
        // core_period / lcd_period, i.e. how many NES frames fit in one panel
        // frame.  The inverse is 1.333 and is NOT the number to compare against
        // 750.  The multiply is done in real: lcd_period_ns * 1000 is 2.2e10 and
        // overflows a 32-bit integer, which silently produced a ratio of 42.
        ratio_real = (1.0 * core_period_ns) / (1.0 * lcd_period_ns);
        ratio_milli = ratio_real * 1000.0;
        if (ratio_real < 0.735 || ratio_real > 0.765)
            err("FRAME_RATE_RATIO", ratio_milli, expect_ratio_milli);

        $display("FRAME core frames=%0d period=%0d ns over window %0d ns (nominal %0d ns)",
                 core_frames, core_period_ns, core_window, CORE_FRAME_NS);
        $display("FRAME lcd  frames=%0d period=%0d ns over window %0d ns (nominal %0d ns)",
                 lcd_frames, lcd_period_ns, lcd_window, LCD_FRAME_NS);
        $display("FRAME ratio core_period/lcd_period = %0d/1000, nominal 750/1000",
                 ratio_milli);
        $display("FRAME counts observed lcd/core = %0d/%0d = %0d/1000 (informational only; a short window makes this a poor estimator)",
                 lcd_frames, core_frames, (lcd_frames * 1000) / core_frames);
        $display("BUS  lcd_rgb driven on %0d lcd_clk, released to Z on %0d",
                 de_seen, z_seen);

        if (z_seen < 1000) err("LCD_RGB_NEVER_TRISTATE", z_seen, 1000);
        if (de_seen < 1000) err("LCD_DE_NEVER_ASSERTED", de_seen, 1000);

        // ------------------------------------------- the panel I2C lane, live
        // ct_rst_n is low for 10 ms and the controller then waits the vendor's
        // 50 ms, so the first poll starts about 60 ms after the reset release.
        // Until now this bench finished at about 50 ms and never saw a single
        // I2C edge, which is the other half of why a push-pull touch_scl and a
        // dead panel could both ship.
        touch_guard = 0;
        while (dut.u_touch.init_done !== 1'b1 && touch_guard < 8000000) begin
            @(posedge sys_clk);
            touch_guard = touch_guard + 1;
        end
        if (dut.u_touch.init_done !== 1'b1) err("TOUCH_INIT_DONE_NEVER", touch_guard, 0);
        if (dut.touch_rst_n !== 1'b1) err("TOUCH_RST_N_NOT_RELEASED", dut.touch_rst_n, 1);

        // One poll cycle is a status read, a coordinate read and a flag clear.
        touch_base   = sl_stop_cnt;
        touch_err_base = sl_addr_hits;
        touch_guard  = 0;
        while (sl_stop_cnt < touch_base + 3 && touch_guard < 8000000) begin
            @(posedge sys_clk);
            touch_guard = touch_guard + 1;
        end
        if (sl_stop_cnt < touch_base + 3) err("TOUCH_POLL_NEVER_COMPLETED", sl_stop_cnt, touch_base + 3);
        if (sl_addr_hits < touch_err_base + 4) err("TOUCH_PANEL_NOT_ADDRESSED", sl_addr_hits, touch_err_base + 4);
        if (sl_flag_clr < 1) err("TOUCH_FLAG_NEVER_CLEARED", sl_flag_clr, 1);
        // An ACKing panel that answers must never raise the error flag; that flag
        // clearing poll_ok_q is what pins touch_valid low forever on the board.
        if (dut.u_touch.touch_error !== 1'b0) err("TOUCH_ERROR_ON_AN_ACKING_PANEL", dut.u_touch.touch_error, 0);
        if (dut.u_touch.poll_ok_q !== 1'b1) err("TOUCH_POLL_OK_NEVER_SET", dut.u_touch.poll_ok_q, 1);
        if (dut.u_touch.poll_done !== 1'b0) err("TOUCH_POLL_DONE_STUCK", dut.u_touch.poll_done, 0);
        if (touch_scl !== 1'b1 || touch_sda !== 1'b1)
            err("TOUCH_BUS_NOT_RELEASED", touch_scl, touch_sda);
        $display("TOUCH %0d START, %0d STOP, %0d address matches, %0d flag clears, error=%0b",
                 sl_start_cnt, sl_stop_cnt, sl_addr_hits, sl_flag_clr, dut.u_touch.touch_error);

        // A reported touch has to come back as coordinates and as the dpad half
        // of the button byte.  (100, 120) is left of the x_left cut at 200, so
        // dpad is 4'b0010.
        //
        // The report has to be staged while the bus is idle.  A real GT9147
        // clears its own data-ready flag when the master writes 0x00 to 16'h814E,
        // and the model does the same, so staging a report in the middle of a
        // poll cycle would have it wiped by that cycle's own flag clear.
        touch_guard = 0;
        while (touch_guard < 4000000) begin
            touch_base  = sl_start_cnt;
            touch_guard = 0;
            while (sl_start_cnt == touch_base && touch_guard < 300000) begin
                @(posedge sys_clk);
                touch_guard = touch_guard + 1;
            end
            if (touch_guard >= 300000) begin
                touch_guard = 4000001;
            end else begin
                @(posedge sys_clk);
                touch_guard = touch_guard + 1;
            end
        end
        if (sl_in_txn !== 1'b0) err("TOUCH_BUS_NEVER_WENT_IDLE", sl_in_txn, 0);
        $display("TOUCH bus went idle after %0d START, %0d STOP", sl_start_cnt, sl_stop_cnt);

        sl_x      = 16'd100;
        sl_y      = 16'd120;
        sl_status = 8'h81;
        @(negedge sys_clk);
        touch_int = 1'b0;
        touch_guard = 0;
        while (!(dut.u_touch.touch_valid === 1'b1 &&
                 dut.u_touch.touch_x === 16'd100 &&
                 dut.u_touch.touch_y === 16'd120) && touch_guard < 8000000) begin
            @(posedge sys_clk);
            touch_guard = touch_guard + 1;
        end
        if (!(dut.u_touch.touch_valid === 1'b1 &&
              dut.u_touch.touch_x === 16'd100 &&
              dut.u_touch.touch_y === 16'd120))
            err("TOUCH_REPORT_NEVER_LATCHED", dut.u_touch.touch_valid, dut.u_touch.touch_x);
        if (dut.u_touch.touch_error !== 1'b0) err("TOUCH_ERROR_ON_A_REPORT", dut.u_touch.touch_error, 0);
        if (sl_coord_rds < 1) err("TOUCH_COORDINATES_NEVER_READ", sl_coord_rds, 1);
        if (dut.touch_buttons[7:4] !== 4'b0010)
            err("TOUCH_DPAD_LEFT", dut.touch_buttons[7:4], 4'b0010);
        $display("TOUCH panel reported (%0d, %0d) status %02h, dpad %b, buttons %02h",
                 dut.u_touch.touch_x, dut.u_touch.touch_y, sl_status,
                 dut.touch_buttons[7:4], dut.touch_buttons);

        // Release it and let the flag clear consume the report.
        @(negedge sys_clk);
        touch_int = 1'b1;
        touch_guard = 0;
        while (dut.u_touch.touch_valid !== 1'b0 && touch_guard < 8000000) begin
            @(posedge sys_clk);
            touch_guard = touch_guard + 1;
        end
        if (dut.u_touch.touch_valid !== 1'b0) err("TOUCH_REPORT_NEVER_RELEASED", touch_guard, 0);
        if (dut.touch_buttons[7:4] !== 4'b0000) err("TOUCH_DPAD_STUCK", dut.touch_buttons[7:4], 0);

        // The open drain contract over the whole run, not just the probe window.
        if (bus_xcl != 0) err("TOUCH_SCL_CONTENDED", bus_xcl, 0);
        if (bus_xsda != 0) err("TOUCH_SDA_CONTENDED", bus_xsda, 0);
        if (bus_pp_sda != 0) err("TOUCH_SDA_PUSH_PULL", bus_pp_sda, 0);
        $display("BUS  touch bus contention over the whole run: scl=%0d sda=%0d push_pull_sda=%0d",
                 bus_xcl, bus_xsda, bus_pp_sda);

        if (errors != 0) begin
            $display("FAIL nes_zynq_top with %0d violations", errors);
            $fatal(1, "nes_zynq_top tb failed");
        end

        $display("PASS nes_zynq_top three clock domains, reset gated on locked, 64-entry palette, RGB888 expansion, open drain touch bus");
        $finish;
    end

    initial begin
        #400000000;
        $fatal(1, "global timeout");
    end

endmodule
