`timescale 1ns/1ps

// WM8960 I2C master testbench: the codec is modelled as an I2C slave that
// resolves the open drain bus, decodes START / STOP / byte / ACK framing and
// samples SDA on every SCL rising edge. Each write transaction is decoded into
// the [DEV_ADDR+W, reg_addr, wdata] triple in txn_dev/txn_wr/txn_reg/txn_dat,
// and the physical layer is checked too: SDA may only move while SCL is low
// (START and STOP excepted), tSU;DAT, tHD;DAT, tSU;STA, tHD;STA, tSU;STO,
// tHD;STO, tBUF, the SCL bit period, the one bit long SDA release window the
// master must keep for each ACK slot, and that neither line is ever sourced
// high by the master.
//
// CONTROL WORD DECODE, AND WHY IT IS NOT THE OBVIOUS ONE
//   WM8960_v4.4.pdf, CONTROL INTERFACE (page 66):
//     "A control word consists of 16 bits. The first 7 bits (B15 to B9) are
//      address bits ... The remaining 9 bits (B8 to B0) are data bits".
//   Byte 0 is the 7-bit device address plus the R/W bit.  Byte 1 is therefore
//   B15..B8 = {reg_addr[6:0], data[8]} and byte 2 is B7..B0 = data[7:0].
//   The decoder below splits byte 1 that way.  A decoder that took byte 1 as a
//   whole 8-bit register address would agree with a master that is equally
//   wrong, so the register address and the data bit 8 are taken apart here and
//   the resulting table is then compared against a HARD-CODED copy of the
//   datasheet values, not against the DUT's own parameters.  Comparing only
//   against dut.CFG_REG()/dut.CFG_DATA() would be a tautology: it proves the
//   state machine walked its table, not that the table is right for a WM8960.

module tb_wm8960_i2c;

    localparam integer CLK_HZ = 50000000;
    localparam integer I2C_HZ = 100000;
    localparam [6:0]   DEV    = 7'h1a;

    localparam real BIT_NS     = 1000000000.0 / I2C_HZ;
    localparam real TOL        = 0.10;
    localparam real TSU_DAT_NS = 250.0;
    localparam real THD_DAT_NS = 100.0;
    localparam real TSU_STA_NS = 6000.0;
    localparam real THD_STA_NS = 600.0;
    localparam real TSU_STO_NS = 600.0;
    localparam real THD_STO_NS = 400.0;
    localparam real TBUF_NS    = 5000.0;

    localparam integer MAX_TXN = 32;

    reg        clk = 1'b0;
    reg        reset = 1'b0;
    reg        wr_req = 1'b0;
    reg  [6:0] reg_addr = 7'h00;
    reg  [8:0] wdata = 9'h000;

    wire       scl_o;
    wire       sda_o;
    wire       sda_oe;
    wire       busy;
    wire       wr_done;
    wire       nack_seen;
    wire       error;
    wire       cfg_done;

    reg        sda_ack_drive = 1'b0;
    reg        nack_mode = 1'b0;

    wire scl_bus;
    wire sda_bus;

    pullup (scl_bus);
    pullup (sda_bus);
    assign scl_bus = scl_o ? 1'bz : 1'b0;
    assign sda_bus = sda_oe ? sda_o : 1'bz;
    assign sda_bus = sda_ack_drive ? 1'b0 : 1'bz;

    wm8960_i2c #(
        .CLK_HZ(CLK_HZ),
        .I2C_HZ(I2C_HZ),
        .DEV_ADDR(DEV)
    ) dut (
        .clk(clk),
        .reset(reset),
        .wr_req(wr_req),
        .reg_addr(reg_addr),
        .wdata(wdata),
        .sda_i(sda_bus),
        .scl_o(scl_o),
        .sda_o(sda_o),
        .sda_oe(sda_oe),
        .busy(busy),
        .wr_done(wr_done),
        .nack_seen(nack_seen),
        .error(error),
        .cfg_done(cfg_done)
    );

    always #10 clk = ~clk;

    reg  [7:0] txn_dev [0:MAX_TXN-1];
    reg        txn_wr  [0:MAX_TXN-1];
    reg  [6:0] txn_reg [0:MAX_TXN-1];
    reg  [8:0] txn_dat [0:MAX_TXN-1];
    integer    txn_count = 0;
    integer    done_count = 0;
    integer    start_cnt = 0;
    integer    stop_cnt = 0;
    integer    abort_stop_cnt = 0;
    integer    i;

    reg  [7:0] byte_buf0 = 8'h00;
    reg  [7:0] byte_buf1 = 8'h00;
    reg  [7:0] byte_buf2 = 8'h00;
    integer    byte_n = 0;
    reg  [7:0] cur_byte = 8'h00;
    integer    cur_bits = 0;
    integer    bit_rise_cnt = 0;
    reg        in_txn = 1'b0;
    reg        ack_active = 1'b0;

    integer    mon_en = 0;
    reg        sda_prev = 1'b1;
    reg        scl_prev = 1'b1;
    reg        sda_at_rise = 1'b1;
    reg        sta_pending = 1'b0;
    reg        hd_sta_pending = 1'b0;
    reg        first_rise = 1'b0;
    reg        have_stop = 1'b0;
    real       last_sda_time = 0.0;
    real       last_scl_rise = 0.0;
    real       last_scl_fall = 0.0;
    real       start_time = 0.0;
    real       stop_time = 0.0;
    real       ack_open_time = 0.0;

    always @(sda_bus) begin
        if (mon_en) begin
            if (sda_prev === 1'b1 && sda_bus === 1'b0) begin
                if (scl_prev === 1'b1) begin
                    if (have_stop && ($realtime - stop_time) < (TBUF_NS * (1.0 - TOL)))
                        $fatal(1, "START only %0.1f ns after STOP, tBUF is %0.1f ns",
                               $realtime - stop_time, TBUF_NS);
                    if (in_txn)
                        $fatal(1, "START while a transaction is still open at %0.1f ns", $realtime);
                    in_txn      = 1'b1;
                    start_cnt   = start_cnt + 1;
                    start_time  = $realtime;
                    sta_pending = 1'b1;
                    have_stop   = 1'b0;
                    first_rise  = 1'b1;
                    bit_rise_cnt = 0;
                    cur_byte    = 8'h00;
                    cur_bits    = 0;
                    byte_n      = 0;
                end
            end
            if (sda_prev === 1'b0 && sda_bus === 1'b1) begin
                if (scl_prev === 1'b1) begin
                    if (!in_txn)
                        $fatal(1, "STOP at %0.1f ns without an open transaction", $realtime);
                    if (($realtime - last_scl_rise) < (TSU_STO_NS * (1.0 - TOL)))
                        $fatal(1, "SDA rose %0.1f ns after the SCL rising edge, tSU;STO is %0.1f ns",
                               $realtime - last_scl_rise, TSU_STO_NS);
                    if (($realtime - last_scl_fall) < (THD_STO_NS * (1.0 - TOL)))
                        $fatal(1, "SDA rose %0.1f ns after the SCL falling edge, tHD;STO is %0.1f ns",
                               $realtime - last_scl_fall, THD_STO_NS);
                    in_txn   = 1'b0;
                    have_stop = 1'b1;
                    stop_time = $realtime;
                    stop_cnt  = stop_cnt + 1;
                    if (byte_n == 3) begin
                        if (txn_count >= MAX_TXN)
                            $fatal(1, "slave transaction buffer overflow");
                        txn_dev[txn_count] = byte_buf0[7:1];
                        txn_wr[txn_count]  = byte_buf0[0];
                        // WM8960 control word: byte 1 = B15..B8, which is the
                        // 7-bit register address in [7:1] and register data bit
                        // 8 in [0].  Byte 2 is data bits 7:0.
                        txn_reg[txn_count] = byte_buf1[7:1];
                        txn_dat[txn_count] = {byte_buf1[0], byte_buf2};
                        txn_count          = txn_count + 1;
                        if (bit_rise_cnt != 27)
                            $fatal(1, "transaction had %0d bit clock rising edges, 27 expected", bit_rise_cnt);
                    end else begin
                        if (bit_rise_cnt != 9 * byte_n)
                            $fatal(1, "aborted transaction had %0d bit clocks for %0d bytes",
                                   bit_rise_cnt, byte_n);
                        if (byte_n > 0)
                            abort_stop_cnt = abort_stop_cnt + 1;
                    end
                end
            end
            last_sda_time = $realtime;
            sda_prev      = sda_bus;
        end
    end

    always @(posedge scl_bus) begin
        if (mon_en) begin
            scl_prev = 1'b1;
            if (sta_pending)
                $fatal(1, "SCL rose %0.1f ns into the START, tSU;STA is %0.1f ns",
                       $realtime - start_time, TSU_STA_NS);
            if (hd_sta_pending && ($realtime - last_scl_fall) < (THD_STA_NS * (1.0 - TOL)))
                $fatal(1, "SCL rose %0.1f ns after the START, tHD;STA is %0.1f ns",
                       $realtime - last_scl_fall, THD_STA_NS);
            hd_sta_pending = 1'b0;
            if (($realtime - last_sda_time) < (TSU_DAT_NS * (1.0 - TOL)))
                $fatal(1, "SDA setup before the SCL rising edge is %0.1f ns, tSU;DAT is %0.1f ns",
                       $realtime - last_sda_time, TSU_DAT_NS);
            if (first_rise) begin
                first_rise = 1'b0;
                if (in_txn)
                    bit_rise_cnt = bit_rise_cnt + 1;
            end else if (($realtime - last_scl_rise) < (BIT_NS * 1.25)) begin
                if (($realtime - last_scl_rise) < (BIT_NS * (1.0 - TOL)) ||
                    ($realtime - last_scl_rise) > (BIT_NS * (1.0 + TOL)))
                    $fatal(1, "SCL period %0.1f ns, %0.1f ns expected",
                           $realtime - last_scl_rise, BIT_NS);
                if (in_txn)
                    bit_rise_cnt = bit_rise_cnt + 1;
            end
            last_scl_rise = $realtime;
            sda_at_rise   = sda_bus;
            if (in_txn) begin
                if (cur_bits < 8) begin
                    cur_byte[7 - cur_bits] = sda_bus;
                    cur_bits = cur_bits + 1;
                end else begin
                    cur_bits = cur_bits + 1;
                    if (cur_bits > 9)
                        $fatal(1, "more than one ACK slot per byte at %0.1f ns", $realtime);
                    if (sda_oe !== 1'b0)
                        $fatal(1, "master still drives SDA during the ACK slot at %0.1f ns", $realtime);
                end
            end
        end
    end

    always @(negedge scl_bus) begin
        if (mon_en) begin
            scl_prev = 1'b0;
            if (sda_bus !== sda_at_rise && !sta_pending)
                $fatal(1, "SDA moved while SCL was high, it rose %0.1f ns after the SCL rising edge and fell at %0.1f ns",
                       $realtime - last_scl_rise, $realtime);
            if (sta_pending) begin
                if (($realtime - start_time) < (TSU_STA_NS * (1.0 - TOL)))
                    $fatal(1, "SDA was held low for %0.1f ns before the SCL falling edge, tSU;STA is %0.1f ns",
                           $realtime - start_time, TSU_STA_NS);
                sta_pending    = 1'b0;
                hd_sta_pending = 1'b1;
            end
            if (in_txn) begin
                if (cur_bits == 8 && !ack_active) begin
                    ack_active    = 1'b1;
                    sda_ack_drive = !nack_mode;
                    ack_open_time = $realtime;
                end else if (ack_active) begin
                    ack_active    = 1'b0;
                    sda_ack_drive = 1'b0;
                    if (($realtime - ack_open_time) < (BIT_NS * (1.0 - TOL)) ||
                        ($realtime - ack_open_time) > (BIT_NS * (1.0 + TOL)))
                        $fatal(1, "master held SDA released for %0.1f ns, one ACK slot is %0.1f ns",
                               $realtime - ack_open_time, BIT_NS);
                    if (cur_bits == 9) begin
                        if (byte_n == 0) begin
                            if (cur_byte[0] !== 1'b0)
                                $fatal(1, "address byte %02h is not a write request", cur_byte);
                            if (cur_byte[7:1] !== DEV)
                                $fatal(1, "address byte %02h does not address %02h", cur_byte, DEV);
                            byte_buf0 = cur_byte;
                        end else if (byte_n == 1) begin
                            byte_buf1 = cur_byte;
                        end else if (byte_n == 2) begin
                            byte_buf2 = cur_byte;
                        end else begin
                            $fatal(1, "master sent more than three bytes in one transaction");
                        end
                        byte_n  = byte_n + 1;
                        cur_bits = 0;
                    end
                end
            end
            last_scl_fall = $realtime;
        end
    end

    always @(posedge clk) begin
        if (mon_en) begin
            if (scl_o === 1'b1 && scl_bus !== 1'b1)
                $fatal(1, "SCL released while the bus is low, open drain violation at %0.1f ns", $realtime);
            if (sda_oe === 1'b1 && sda_o === 1'b1)
                $fatal(1, "master drives SDA high, open drain violation at %0.1f ns", $realtime);
        end
    end

    always @(sda_oe or sda_o) begin
        if (mon_en) begin
            if (($realtime - last_scl_fall) < (THD_DAT_NS * (1.0 - TOL)))
                $fatal(1, "master changed its SDA request %0.1f ns after the SCL falling edge, tHD;DAT is %0.1f ns",
                       $realtime - last_scl_fall, THD_DAT_NS);
        end
    end

    always @(posedge wr_done) begin
        done_count = done_count + 1;
    end

    task issue_write;
        input [6:0] ra;
        input [8:0] wd;
        begin
            @(negedge clk);
            reg_addr = ra;
            wdata    = wd;
            wr_req   = 1'b1;
            @(negedge clk);
            wr_req   = 1'b0;
        end
    endtask

    // ---------------------------------------------------------------------
    // The datasheet table, hard coded here so the assertion below is not a
    // comparison of the DUT's parameters against themselves.
    // Every line cites WM8960_v4.4.pdf.
    // ---------------------------------------------------------------------
    localparam integer EXP_N = 15;

    function [6:0] dref_reg;
        input integer i;
        begin
            case (i)
                0:  dref_reg = 7'h0F;  // R15 (0Fh) Reset
                1:  dref_reg = 7'h04;  // R4  (04h) Clocking (1)
                2:  dref_reg = 7'h34;  // R52 (34h) PLL (1)
                3:  dref_reg = 7'h35;  // R53 (35h) PLL K value (1)
                4:  dref_reg = 7'h36;  // R54 (36h) PLL K Value (2)
                5:  dref_reg = 7'h37;  // R55 (37h) PLL K Value (3)
                6:  dref_reg = 7'h07;  // R7  (07h) Digital Audio Interface Format
                7:  dref_reg = 7'h19;  // R25 (19h) Power Management (1)
                8:  dref_reg = 7'h1A;  // R26 (1Ah) Power Management (2)
                9:  dref_reg = 7'h05;  // R5  (05h) ADC and DAC Control (1)
                10: dref_reg = 7'h2F;  // R47 (2Fh) Power Management (3)
                11: dref_reg = 7'h22;  // R34 (22h) Left Out Mix (1)
                12: dref_reg = 7'h25;  // R37 (25h) Right Out Mix (2)
                13: dref_reg = 7'h02;  // R2  (02h) LOUT1 Volume
                14: dref_reg = 7'h03;  // R3  (03h) ROUT1 Volume
                default: dref_reg = 7'h00;
            endcase
        end
    endfunction

    function [8:0] dref_dat;
        input integer i;
        begin
            case (i)
                // "writing to this register resets all registers to their
                // default state"
                0:  dref_dat = 9'h000;
                // ADCDIV=000 DACDIV=000 SYSCLKDIV=10 CLKSEL=1
                1:  dref_dat = 9'h005;
                // SDM=0 PLLPRESCALE=1 PLLN=8 (5 < PLLN < 13, stability peaks 8)
                2:  dref_dat = 9'h018;
                // PLLK = 0x000000, so R = 8 exactly with no fractional jitter
                3:  dref_dat = 9'h000;
                4:  dref_dat = 9'h000;
                5:  dref_dat = 9'h000;
                // MS=0 slave, LRP=0, WL=00 16 bit, FORMAT=10 I2S
                6:  dref_dat = 9'h006;
                // VMIDSEL=01 (2x50k, playback), VREF=1, all else off
                7:  dref_dat = 9'h180;
                // DACL DACR LOUT1 ROUT1 PLL_EN, class D left off
                8:  dref_dat = 9'h1F9;
                // DACMU=0 lifts the power-on digital soft mute (default 0x008)
                9:  dref_dat = 9'h000;
                // LOMIX=1 ROMIX=1
                10: dref_dat = 9'h00C;
                // LD2LO=1, LI2LOVOL=101 (0dB) at its default
                11: dref_dat = 9'h100;
                // RD2RO=1, RI2ROVOL=101 (0dB) at its default
                12: dref_dat = 9'h100;
                // LO1ZC=1, LOUT1VOL=121 = +6dB - 6 = 0dB
                13: dref_dat = 9'h079;
                // RO1ZC=1, ROUT1VOL=121 = 0dB
                14: dref_dat = 9'h079;
                default: dref_dat = 9'h000;
            endcase
        end
    endfunction

    integer base;
    integer done_base;
    integer abort_base;

    initial begin
        #1 reset = 1'b1;
        #399;

        if (busy !== 1'b0)
            $fatal(1, "busy must be low while reset is asserted");
        if (cfg_done !== 1'b0)
            $fatal(1, "cfg_done must be low after reset");
        if (wr_done !== 1'b0)
            $fatal(1, "wr_done must be low after reset");
        if (nack_seen !== 1'b0)
            $fatal(1, "nack_seen must be low after reset");
        if (error !== 1'b0)
            $fatal(1, "error must be low after reset");
        if (sda_oe !== 1'b0)
            $fatal(1, "SDA must be released after reset");
        if (scl_o !== 1'b1)
            $fatal(1, "SCL must be released after reset");

        reset = 1'b0;
        mon_en = 1;

        @(posedge cfg_done);
        #1;

        if (busy !== 1'b0)
            $fatal(1, "busy must drop once the configuration table is done");
        if (start_cnt != dut.CFG_COUNT)
            $fatal(1, "saw %0d START conditions, the table has %0d entries",
                   start_cnt, dut.CFG_COUNT);
        if (txn_count != dut.CFG_COUNT)
            $fatal(1, "slave decoded %0d transactions, the table has %0d entries",
                   txn_count, dut.CFG_COUNT);
        if (txn_reg[0] !== 7'h0F || txn_dat[0] !== 9'h000)
            $fatal(1, "table item 0 is %02h=%03h, WM8960 R15 (0Fh) = 000 must be first",
                   txn_reg[0], txn_dat[0]);
        for (i = 0; i < dut.CFG_COUNT; i = i + 1) begin
            if (txn_dev[i] !== DEV)
                $fatal(1, "table item %0d addressed %02h, expected %02h", i, txn_dev[i], DEV);
            if (txn_wr[i] !== 1'b0)
                $fatal(1, "table item %0d is a read, expected a write", i);
            if (txn_reg[i] !== dut.CFG_REG(i))
                $fatal(1, "table item %0d wrote register %02h, expected %02h",
                       i, txn_reg[i], dut.CFG_REG(i));
            if (txn_dat[i] !== dut.CFG_DATA(i))
                $fatal(1, "table item %0d wrote %03h to %02h, expected %03h",
                       i, txn_dat[i], txn_reg[i], dut.CFG_DATA(i));
        end
        // The datasheet table, not the DUT's parameters.
        if (dut.CFG_COUNT != EXP_N)
            $fatal(1, "the table has %0d entries, the datasheet sequence has %0d",
                   dut.CFG_COUNT, EXP_N);
        for (i = 0; i < EXP_N; i = i + 1) begin
            if (txn_reg[i] !== dref_reg(i))
                $fatal(1, "table item %0d wrote register %02h, WM8960_v4.4 wants %02h",
                       i, txn_reg[i], dref_reg(i));
            if (txn_dat[i] !== dref_dat(i))
                $fatal(1, "table item %0d wrote %03h to R%0d (%02h), WM8960_v4.4 wants %03h",
                       i, txn_dat[i], dref_reg(i), dref_reg(i), dref_dat(i));
        end
        // The three writes that cannot be expressed in 8 data bits.  R26 DACL
        // is data bit 8, so an 8-bit-only master leaves the LEFT DAC powered
        // down; R34 LD2LO and R37 RD2RO are data bit 8 too, so the DACs never
        // reach the output mixer.  Both are asserted here so a future change
        // back to an 8-bit data field fails instead of producing a board with
        // a silent left channel.
        if (txn_dat[8][8] !== 1'b1)
            $fatal(1, "R26 DACL is data bit 8 and must be set, got %03h", txn_dat[8]);
        if (txn_dat[11][8] !== 1'b1)
            $fatal(1, "R34 LD2LO is data bit 8 and must be set, got %03h", txn_dat[11]);
        if (txn_dat[12][8] !== 1'b1)
            $fatal(1, "R37 RD2RO is data bit 8 and must be set, got %03h", txn_dat[12]);
        // The power-on default of R5 has DACMU=1; if that is left in place the
        // DAC is digitally muted no matter what every other register says.
        if (txn_dat[9][3] !== 1'b0)
            $fatal(1, "R5 DACMU must be cleared to unmute the DAC, got %03h", txn_dat[9]);
        if (stop_cnt != dut.CFG_COUNT)
            $fatal(1, "saw %0d STOP conditions, the table has %0d entries",
                   stop_cnt, dut.CFG_COUNT);
        if (abort_stop_cnt != 0)
            $fatal(1, "the configuration sequence produced %0d aborted writes", abort_stop_cnt);
        if (nack_seen !== 1'b0 || error !== 1'b0)
            $fatal(1, "the configuration sequence reported a NACK or an error");
        if (done_count != 0)
            $fatal(1, "wr_done pulsed during the configuration sequence");

        repeat (500) @(negedge clk);
        if (cfg_done !== 1'b1)
            $fatal(1, "cfg_done must stay high after the table is done");

        base = txn_count;
        done_base = done_count;
        issue_write(7'h26, 9'hab);
        @(posedge wr_done);
        #1;
        if (txn_count != base + 1)
            $fatal(1, "the single write produced %0d transactions", txn_count - base);
        if (txn_dev[base] !== DEV || txn_wr[base] !== 1'b0)
            $fatal(1, "write addressed %02h/%b, expected a write to %02h",
                   txn_dev[base], txn_wr[base], DEV);
        if (txn_reg[base] !== 7'h26 || txn_dat[base] !== 9'hab)
            $fatal(1, "write decoded as %02h=%03h, expected 26=0ab",
                   txn_reg[base], txn_dat[base]);
        if (error !== 1'b0 || nack_seen !== 1'b0)
            $fatal(1, "an acknowledged write raised nack_seen or error");
        repeat (10) @(negedge clk);
        if (done_count != done_base + 1)
            $fatal(1, "wr_done must be a single cycle pulse, saw %0d pulses", done_count - done_base);

        // Byte-level proof that the 7-bit register address really does sit in
        // byte 1 bits [7:1] and that register data bit 8 sits in byte 1 bit 0.
        // Register 0x25 is the discriminator, and it is deliberately NOT the
        // device address: DEV_ADDR is 0x1A, and byte 1 for a write to register
        // 0x1A with data bit 8 clear is {0x1A,0} = 0x34, which is the same
        // number as the device address byte and would prove nothing.
        base = txn_count;
        issue_write(7'h25, 9'h000);
        @(posedge wr_done);
        #1;
        if (byte_buf1 !== 8'h4A)
            $fatal(1, "byte 1 must be {7'h25, data[8]=0} = %02h, got %02h", 8'h4A, byte_buf1);
        if (byte_buf0 !== 8'h34)
            $fatal(1, "byte 0 must be {DEV_ADDR,1'b0} = %02h, got %02h", 8'h34, byte_buf0);
        base = txn_count;
        issue_write(7'h25, 9'h100);
        @(posedge wr_done);
        #1;
        if (byte_buf1 !== 8'h4B)
            $fatal(1, "byte 1 must be {7'h25, data[8]=1} = %02h, got %02h", 8'h4B, byte_buf1);
        if (byte_buf2 !== 8'h00)
            $fatal(1, "byte 2 must be data[7:0] = %02h, got %02h", 8'h00, byte_buf2);
        if (txn_reg[base] !== 7'h25 || txn_dat[base] !== 9'h100)
            $fatal(1, "nine bit write decoded as %02h=%03h, expected 25=100",
                   txn_reg[base], txn_dat[base]);

        base = txn_count;
        issue_write(7'h38, 9'h055);
        @(posedge wr_done);
        #1;
        if (txn_count != base + 1)
            $fatal(1, "the back to back write produced %0d transactions", txn_count - base);
        if (txn_reg[base] !== 7'h38 || txn_dat[base] !== 9'h055)
            $fatal(1, "back to back write decoded as %02h=%03h, expected 38=055",
                   txn_reg[base], txn_dat[base]);

        nack_mode = 1'b1;
        base = txn_count;
        done_base = done_count;
        abort_base = abort_stop_cnt;
        issue_write(7'h38, 9'h077);
        wait (nack_seen === 1'b1);
        #1;
        if (error !== 1'b1)
            $fatal(1, "error must be set once a NACK is seen");
        if (txn_count != base)
            $fatal(1, "a NACKed write was recorded as a transaction");
        if (done_count != done_base)
            $fatal(1, "wr_done pulsed for a NACKed write");
        @(negedge busy);
        #1;
        if (scl_bus !== 1'b1 || sda_bus !== 1'b1)
            $fatal(1, "the bus is not idle after a NACK abort");
        if (abort_stop_cnt != abort_base + 1)
            $fatal(1, "a NACKed write must be terminated by a STOP");
        nack_mode = 1'b0;

        base = txn_count;
        done_base = done_count;
        issue_write(7'h07, 9'h01B);
        repeat (40) @(negedge clk);
        if (busy !== 1'b1)
            $fatal(1, "busy must be high while a write is in flight");
        @(negedge clk);
        wr_req = 1'b1;
        @(negedge clk);
        wr_req = 1'b0;
        @(posedge wr_done);
        #1;
        if (txn_count != base + 1)
            $fatal(1, "a write request dropped while busy created a transaction");
        if (done_count != done_base + 1)
            $fatal(1, "a write request dropped while busy pulsed wr_done");
        if (txn_reg[base] !== 7'h07 || txn_dat[base] !== 9'h01B)
            $fatal(1, "in flight write decoded as %02h=%03h, expected 07=01B",
                   txn_reg[base], txn_dat[base]);
        repeat (10) @(negedge clk);
        if (scl_bus !== 1'b1 || sda_bus !== 1'b1)
            $fatal(1, "the bus is not idle after the last write");

        $display("tb_wm8960_i2c: %0d transactions, %0d START, %0d STOP, %0d aborted",
                 txn_count, start_cnt, stop_cnt, abort_stop_cnt);
        $display("CFG  15 writes, WM8960_v4.4 register table, 9 bit data field");
        $display("PASS wm8960_i2c");
        $finish;
    end

    initial begin
        #60000000;
        $fatal(1, "tb_wm8960_i2c global timeout");
    end

endmodule
