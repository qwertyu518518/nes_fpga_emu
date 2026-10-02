`timescale 1ns/1ps

// WM8960 stereo audio codec I2C master (Verilog-2001, synthesisable).
//
// PART IDENTITY, AND WHY THIS FILE WAS RENAMED FROM wm8978_i2c.v
//   The part on the Navigator (ALIENTEK) V2 Zynq board is a WM8960, not a
//   WM8978.  Three independent sources agree:
//     * the only codec datasheet in the board material is WM8960_v4.4.pdf,
//     * the board-wide XDC audio section header reads 音频（WM8960）,
//     * the vendor 42_audio_loopback example programs slave address 0x1A and
//       names the part WM8960 in its own source.
//   The WM8978 and the WM8960 have DIFFERENT register maps, so a sequence that
//   was correct for one is meaningless to the other.  Every register and every
//   value in the table below was checked against WM8960_v4.4.pdf; the
//   differences found are listed under "WHAT CHANGED" further down.
//
// Bus interface uses explicit tri-state control instead of `inout`:
//   scl_o  open drain SCL drive request, 0 = pull SCL low, 1 = release SCL
//          (the master never sources current on SCL, an external pull-up sets
//          the high level)
//   sda_o  SDA level, only meaningful while sda_oe is high
//   sda_oe 1 = drive sda_o, 0 = release SDA
//   sda_i  SDA level resolved on the wire, sampled during the ACK slot
// Typical hookup:  assign scl = scl_o  ? 1'bz : 1'b0;
//                  assign sda = sda_oe ? sda_o : 1'bz;
// A logic one on SDA is sent by releasing the line, sda_oe is only asserted for
// a logic zero, so the master never sources current on SDA either. A slave
// that pulls SDA low during the ACK slot therefore wins over the pull-up, and
// the master samples it through sda_i.
//
// WRITE TRANSACTION FRAMING, AND WHY reg_addr IS 7 BITS AND wdata IS 9
// (wr_req is a one clock pulse, reg_addr and wdata must be valid in that same
// cycle):
//   ST_IDLE -> ST_START_H -> ST_START_L -> ST_BIT -> ST_STOP_L -> ST_STOP_H
//   -> ST_STOP_HOLD -> ST_IDLE
// ST_BIT clocks nine slots per byte over three bytes, the ninth slot being the
// ACK slot where the master releases SDA and samples sda_i. ST_GAP delays
// separate the power-on configuration items.
//
//   WM8960_v4.4.pdf, CONTROL INTERFACE / 2-WIRE SERIAL CONTROL INTERFACE
//   (page 66, Figure 37):
//     "A control word consists of 16 bits. The first 7 bits (B15 to B9) are
//      address bits that select which control register is accessed. The
//      remaining 9 bits (B8 to B0) are data bits, corresponding to the 9 bits
//      in each control register."
//     "The device address is 0011010 (0x34h)."  = 7'h1A, the DEV_ADDR below.
//     "the controller sends the first byte of control data (B15 to B8, i.e.
//      the WM8960 register address plus the first bit of register data)"
//
//   So the three bytes on the wire are
//     byte 0  = {DEV_ADDR[6:0], 1'b0}      device address plus the R/W bit
//     byte 1  = {reg_addr[6:0], wdata[8]}  7-bit register address, then
//                                        register data bit 8
//     byte 2  = wdata[7:0]                 register data bits 7 to 0
//
//   This module previously sent byte 1 = reg_addr[7:0] and byte 2 = wdata[7:0],
//   i.e. it treated the register address as the WHOLE of byte 1.  Per the
//   citation above that is wrong: it would have delivered the register address
//   shifted up by one bit and put the address LSB into register data bit 8.
//   Every write in the old table landed on register (addr >> 1) with a garbage
//   bit 8, so the sequence could not have configured a WM8960.  The nine-slot
//   per byte framing and the ACK handling were correct and are unchanged; only
//   the bit position of the address inside byte 1, and the width of the data
//   field, were wrong.  The vendor 42_audio_loopback main.c is independent
//   evidence for the corrected form: it builds
//     I2C_Data[0] = (reg_addr << 1) | data_bit_8;  I2C_Data[1] = data & 0xFF;
//   which is byte 1 = {addr[6:0], data[8]} after masking addr to 7 bits.
//
//   The 9-bit data field is not optional.  R26 (1Ah) DACL is data bit 8, and
//   without it the LEFT DAC stays powered down and the left channel is silent.
//   R34 (22h) LD2LO and R37 (25h) RD2RO are data bit 8 as well, and without
//   them the DACs never reach the output mixer at all.
//
// A NACK on any ACK slot raises nack_seen and error, aborts the byte train
// and still emits the STOP so the bus is handed back cleanly; wr_done does
// not pulse for an aborted write. A wr_req that arrives while busy is
// dropped and raises error. Both flags are sticky until reset.
//
// Timing: SCL comes from a CLK_HZ/(4*I2C_HZ) quarter-period divider, so one
// bit period is four divider ticks. SDA is only ever driven in the tick that
// follows an SCL falling edge, which leaves one quarter period of hold and
// two of setup. START and STOP each hold their SCL/SDA levels for a full bit
// period, well past the standard-mode minima (tSU;STA 6.0us, tHD;STA 0.6us,
// tSU;STO 0.6us, tHD;STO 0.4us, tBUF 5.0us).
//
// Power-on configuration: after reset the module walks the case-form constant
// table CFG_REG()/CFG_DATA() (CFG_COUNT items, in table order) and latches
// cfg_done high once the table is exhausted; CFG_GAP clocks of delay are
// inserted before the first item and between items. Every register address and
// value is a parameter, so a board can retune the sequence without edits.
//
// WHAT CHANGED, ITEM BY ITEM, AGAINST WM8960_v4.4.pdf
//   The old table was written for a WM8978.  On a WM8960 every one of those
//   nine writes landed somewhere else, and several of the addresses it used do
//   not exist:
//
//     old 0x00=0x1F  "software reset"
//            WM8960: software reset is R15 (0Fh) and it resets every register
//            to its power-on default when written.  R0 (00h) is the LEFT INPUT
//            volume register (LINVOL) on a WM8960.  ->  0x0F = 0x000
//     old 0x01=0x1F  "channel enable, LOUT/ROUT + mixer + line outputs"
//     old 0x02=0x1F  "the same for the right side"
//            WM8960: R1 (01h) is the RIGHT INPUT volume and R2 (02h) is the
//            LOUT1 volume.  The power management registers are R25 (19h) and
//            R26 (1Ah).  ->  0x19 = 0x180, 0x1A = 0x1F9
//     old 0x0C=0x10  "I2S master mode, 256*Fs MCLK/word-clock ratio"
//            WM8960: R12 (0Ch) is RESERVED.  The digital audio interface format
//            register is R7 (07h) and it has no master/clock-ratio field: MS
//            is bit 6, and the MCLK/word-clock ratio is set by ADCDIV/DACDIV in
//            R4 (04h).  ->  0x07 = 0x006
//     old 0x0D=0x02  "digital audio interface control, 16 bit words"
//            WM8960: R13 (0Dh) is RESERVED.  There is no second interface
//            control register; the word length is WL[1:0] inside R7.  ->  merged
//            into the single 0x07 write above
//     old 0x19=0x34  "sample rate: oversampling ratio + divider"
//     old 0x1A=0x00  "the same, second half"
//            WM8960: R25 (19h) is Power Management (1) and R26 (1Ah) is Power
//            Management (2).  The sample rate dividers are ADCDIV/DACDIV/
//            SYSCLKDIV in R4 (04h) and the PLL ratio is R52..R55 (34h..37h).
//            ->  see items 1..5 and 7, 8
//     old 0x32=0x32  "left digital volume, -57dB..+12dB in 0.5dB steps"
//     old 0x33=0x32  "right digital volume"
//            WM8960: R50 (32h) is RESERVED and R51 (33h) is Class D Control (2)
//            (the speaker DC/AC boost).  The headphone output volumes are
//            LOUT1VOL in R2 (02h) and ROUT1VOL in R3 (03h), both 7-bit with
//            1dB steps over +6dB..-73dB.  ->  0x02 = 0x079, 0x03 = 0x079
//
//   The new table, fifteen items, in the order they are written.  The order is
//   the datasheet's requirement that functions be enabled and disabled in the
//   right sequence: "To avoid any pop or click noise, it is important to enable
//   or disable functions in the correct order (see Applications Information)"
//   and "Whenever an analogue output is disabled, it remains connected to VREF
//   through a resistor. This helps to prevent pop noise when the output is
//   re-enabled" (page 43).  So: clocking and PLL first, then the digital
//   interface format, then VREF/VMID, then the output buffers and the PLL
//   enable, then the digital soft mute is lifted, then the mixer path, and the
//   output volume last.
//
//     0  R15 (0Fh) = 0x000  software reset, restores every power-on default
//     1  R4  (04h) = 0x005  Clocking (1).  ADCDIV=000, DACDIV=000,
//                          SYSCLKDIV=10 (divide SYSCLK by 2), CLKSEL=1
//                          (SYSCLK from the PLL, not from MCLK).  Bits [8:6]
//                          ADCDIV, [5:3] DACDIV, [2:1] SYSCLKDIV, [0] CLKSEL.
//                          0x005 = 0b0000_0101 -> SYSCLKDIV=10, CLKSEL=1.
//     2  R52 (34h) = 0x018  PLL (1).  OPCLKDIV=000, SDM=0 (integer mode),
//                          PLLPRESCALE=1 (divide MCLK by 2 first),
//                          PLLN=8.  Bits [8:6] OPCLKDIV, [5] SDM,
//                          [4] PLLPRESCALE, [3:0] PLLN.
//                          0x018 = 0b0000_1000 -> PLLPRESCALE=1, PLLN=8.
//                          Datasheet: "There is a fixed divide by 4 in the PLL
//                          and a selectable divide by N after the PLL" and
//                          "5 < PLLN < 13", "Its stability peaks at N=8".
//     3  R53 (35h) = 0x000  PLLK[23:16] = 0
//     4  R54 (36h) = 0x000  PLLK[15:8]  = 0
//     5  R55 (37h) = 0x000  PLLK[7:0]   = 0
//                          K = 0 makes the ratio the integer PLLN alone, so
//                          R = 8 with no fractional jitter.  The power-on
//                          defaults are 31h 26h E9h and MUST be cleared.
//     6  R7  (07h) = 0x006  Digital audio interface format.  ALRSWAP=0,
//                          BCLKINV=0, MS=0 (SLAVE mode, BCLK/LRCK are inputs
//                          driven by the host), DLRSWAP=0, LRP=0 (normal LRCLK
//                          polarity), WL=00 (16 bit words), FORMAT=10 (I2S).
//                          Bits [8] ALRSWAP, [7] BCLKINV, [6] MS, [5] DLRSWAP,
//                          [4] LRP, [3:2] WL, [1:0] FORMAT.
//                          0x006 = 0b0000_0110.  The power-on default is 0x00A,
//                          which is the same interface in 24 bit mode; 0x006
//                          clears WL to 00 for the 16 bit words this design
//                          shifts.
//     7  R25 (19h) = 0x180  Power Management (1).  VMIDSEL=01 (2 x 50k divider,
//                          the playback setting), VREF=1, everything else off.
//                          Bits [8:7] VMIDSEL, [6] VREF, [5] AINL, [4] AINR,
//                          [3] ADCL, [2] ADCR, [1] MICB, [0] DIGENB.
//                          0x180 = 0b0110000000 -> VMIDSEL=01, VREF=1.
//     8  R26 (1Ah) = 0x1F9  Power Management (2).  DACL=1, DACR=1, LOUT1=1,
//                          ROUT1=1, SPKL=0, SPKR=0, OUT3=0, PLL_EN=1.
//                          0x1F9 = 0b1_1111_1001.  DACL is data bit 8, so this
//                          write cannot be expressed in 8 bits.  The Class D
//                          speaker path is left OFF: the board's audio output is
//                          the headphone pair on LOUT1/ROUT1, and the datasheet
//                          warns SPK_OP_EN must not be enabled before there is a
//                          valid class D switching clock.  R49 (31h) therefore
//                          keeps its power-on SPK_OP_EN=00 and needs no write.
//     9  R5  (05h) = 0x000  ADC and DAC Control (1).  DACMU=0 lifts the digital
//                          soft mute (the power-on default 0x008 has DACMU=1,
//                          so without this write the DAC output stays muted
//                          regardless of every other setting), DEEMPH=00 (none),
//                          DACDIV2=0.
//    10  R47 (2Fh) = 0x00C  Power Management (3).  LMIC=0, RMIC=0, LOMIX=1,
//                          ROMIX=1.  Bits [5] LMIC, [4] RMIC, [3] LOMIX,
//                          [2] ROMIX.  0x00C = 0b0000_0011_00 -> LOMIX, ROMIX.
//    11  R34 (22h) = 0x100  Left output mixer.  LD2LO=1 (left DAC to left
//                          output mixer), LI2LO=0, LI2LOVOL=101 (0dB) kept at
//                          its default.  Bit [8] LD2LO, so 9-bit data again.
//    12  R37 (25h) = 0x100  Right output mixer.  RD2RO=1, RI2RO=0,
//                          RI2ROVOL=101 (0dB) default.
//    13  R2  (02h) = 0x079  LOUT1 volume.  OUT1VU=0, LO1ZC=1 (change gain on
//                          zero cross only, which is what keeps a volume change
//                          from clicking), LOUT1VOL=0x79=121.
//                          "1111111 = +6dB ... 1dB steps down to 0110000 =
//                          -73dB", so 121 = +6 - (127-121) = 0dB.
//                          OUT1VU is a write-1 trigger and is left at 0.
//    14  R3  (03h) = 0x079  ROUT1 volume.  RO1ZC=1, ROUT1VOL=121 = 0dB.
//
//   Clock arithmetic for items 1..8, with MCLK = 25 MHz (the lcd_clk net):
//     f1   = MCLK / 2^PLLPRESCALE = 25 / 2   = 12.500 MHz
//     R    = PLLN + PLLK / 2^24    = 8 + 0    = 8
//     f2   = R * f1                = 100.000 MHz     (PLL VCO)
//     SYSCLK = f2 / (4 * 2^SYSCLKDIV) = 100 / 8 = 12.500 MHz
//     fs   = SYSCLK / 256 (DACDIV=000)            = 48828.125 Hz
//   f2 lands on the upper edge of the datasheet's "performs best when f2 is
//   between 90MHz and 100MHz", and PLLN=8 is the "stability peaks at N=8"
//   case, with K=0 so there is no fractional divider jitter at all.  SYSCLKDIV
//   has to be 2 because 1 would need R = 4, outside the 5 < PLLN < 13 window.
//   DCLKDIV keeps its power-on default 111 (SYSCLK/16 = 781.25 kHz), which is
//   inside the 700-800 kHz the datasheet asks for; it is only used by the
//   Class D outputs, which are disabled here.
//
// CFG_COUNT must not exceed the number of table entries implemented below
// (CFG_REG indices 0x0F, 0x04, 0x34, 0x35, 0x36, 0x37, 0x07, 0x19, 0x1A,
// 0x05, 0x2F, 0x22, 0x25, 0x02, 0x03); indices past the table read back 0x00.

module wm8960_i2c #(
    parameter integer CLK_HZ       = 50000000,
    parameter integer I2C_HZ       = 100000,
    parameter [6:0]   DEV_ADDR     = 7'h1a,
    parameter integer CFG_COUNT    = 15,
    parameter integer CFG_GAP      = 2500,
    parameter [6:0] CFG_RST_REG   = 7'h0f,
    parameter [8:0] CFG_RST_DAT   = 9'h000,
    parameter [6:0] CFG_CLK1_REG  = 7'h04,
    parameter [8:0] CFG_CLK1_DAT  = 9'h005,
    parameter [6:0] CFG_PLLN_REG  = 7'h34,
    parameter [8:0] CFG_PLLN_DAT  = 9'h018,
    parameter [6:0] CFG_PLKK1_REG = 7'h35,
    parameter [8:0] CFG_PLKK1_DAT = 9'h000,
    parameter [6:0] CFG_PLKK2_REG = 7'h36,
    parameter [8:0] CFG_PLKK2_DAT = 9'h000,
    parameter [6:0] CFG_PLKK3_REG = 7'h37,
    parameter [8:0] CFG_PLKK3_DAT = 9'h000,
    parameter [6:0] CFG_FMT_REG   = 7'h07,
    parameter [8:0] CFG_FMT_DAT   = 9'h006,
    parameter [6:0] CFG_PM1_REG   = 7'h19,
    parameter [8:0] CFG_PM1_DAT   = 9'h180,
    parameter [6:0] CFG_PM2_REG   = 7'h1a,
    parameter [8:0] CFG_PM2_DAT   = 9'h1f9,
    parameter [6:0] CFG_DAC_REG   = 7'h05,
    parameter [8:0] CFG_DAC_DAT   = 9'h000,
    parameter [6:0] CFG_PM3_REG   = 7'h2f,
    parameter [8:0] CFG_PM3_DAT   = 9'h00c,
    parameter [6:0] CFG_LMIX_REG  = 7'h22,
    parameter [8:0] CFG_LMIX_DAT  = 9'h100,
    parameter [6:0] CFG_RMIX_REG  = 7'h25,
    parameter [8:0] CFG_RMIX_DAT  = 9'h100,
    parameter [6:0] CFG_VOL_L_REG = 7'h02,
    parameter [8:0] CFG_VOL_L_DAT = 9'h079,
    parameter [6:0] CFG_VOL_R_REG = 7'h03,
    parameter [8:0] CFG_VOL_R_DAT = 9'h079
)(
    input  wire       clk,
    input  wire       reset,
    input  wire       wr_req,
    input  wire [6:0] reg_addr,
    input  wire [8:0] wdata,
    input  wire       sda_i,
    output wire       scl_o,
    output wire       sda_o,
    output wire       sda_oe,
    output wire       busy,
    output wire       wr_done,
    output wire       nack_seen,
    output wire       error,
    output wire       cfg_done
);

    function integer clog2;
        input integer value;
        integer rest;
        begin
            rest = value - 1;
            clog2 = 0;
            while (rest > 0) begin
                rest = rest >> 1;
                clog2 = clog2 + 1;
            end
        end
    endfunction

    function [6:0] CFG_REG;
        input [7:0] idx;
        begin
            case (idx)
                8'd0    : CFG_REG = CFG_RST_REG;
                8'd1    : CFG_REG = CFG_CLK1_REG;
                8'd2    : CFG_REG = CFG_PLLN_REG;
                8'd3    : CFG_REG = CFG_PLKK1_REG;
                8'd4    : CFG_REG = CFG_PLKK2_REG;
                8'd5    : CFG_REG = CFG_PLKK3_REG;
                8'd6    : CFG_REG = CFG_FMT_REG;
                8'd7    : CFG_REG = CFG_PM1_REG;
                8'd8    : CFG_REG = CFG_PM2_REG;
                8'd9    : CFG_REG = CFG_DAC_REG;
                8'd10   : CFG_REG = CFG_PM3_REG;
                8'd11   : CFG_REG = CFG_LMIX_REG;
                8'd12   : CFG_REG = CFG_RMIX_REG;
                8'd13   : CFG_REG = CFG_VOL_L_REG;
                8'd14   : CFG_REG = CFG_VOL_R_REG;
                default : CFG_REG = 7'h00;
            endcase
        end
    endfunction

    function [8:0] CFG_DATA;
        input [7:0] idx;
        begin
            case (idx)
                8'd0    : CFG_DATA = CFG_RST_DAT;
                8'd1    : CFG_DATA = CFG_CLK1_DAT;
                8'd2    : CFG_DATA = CFG_PLLN_DAT;
                8'd3    : CFG_DATA = CFG_PLKK1_DAT;
                8'd4    : CFG_DATA = CFG_PLKK2_DAT;
                8'd5    : CFG_DATA = CFG_PLKK3_DAT;
                8'd6    : CFG_DATA = CFG_FMT_DAT;
                8'd7    : CFG_DATA = CFG_PM1_DAT;
                8'd8    : CFG_DATA = CFG_PM2_DAT;
                8'd9    : CFG_DATA = CFG_DAC_DAT;
                8'd10   : CFG_DATA = CFG_PM3_DAT;
                8'd11   : CFG_DATA = CFG_LMIX_DAT;
                8'd12   : CFG_DATA = CFG_RMIX_DAT;
                8'd13   : CFG_DATA = CFG_VOL_L_DAT;
                8'd14   : CFG_DATA = CFG_VOL_R_DAT;
                default : CFG_DATA = 9'h000;
            endcase
        end
    endfunction

    localparam [3:0] ST_IDLE      = 4'd0;
    localparam [3:0] ST_START_H   = 4'd1;
    localparam [3:0] ST_START_L   = 4'd2;
    localparam [3:0] ST_BIT       = 4'd3;
    localparam [3:0] ST_STOP_L    = 4'd4;
    localparam [3:0] ST_STOP_H    = 4'd5;
    localparam [3:0] ST_STOP_HOLD = 4'd6;
    localparam [3:0] ST_GAP       = 4'd7;

    localparam [1:0] TICK_LAST    = 2'd3;

    localparam integer QTR_RAW    = CLK_HZ / (4 * I2C_HZ);
    localparam integer QTR        = (QTR_RAW < 1) ? 1 : QTR_RAW;
    localparam integer QW_RAW     = clog2(QTR + 1);
    localparam integer QW         = (QW_RAW < 1) ? 1 : QW_RAW;
    localparam [QW-1:0] QTR_M1    = QTR - 1;

    localparam integer GW_RAW     = clog2(CFG_GAP + 1);
    localparam integer GW         = (GW_RAW < 1) ? 1 : GW_RAW;
    localparam [GW-1:0] GAP_MAX   = CFG_GAP - 1;

    reg [QW-1:0] div_cnt_q;
    reg [GW-1:0] gap_cnt_q;
    reg [3:0]    state_q;
    reg [1:0]    phase_q;
    reg [1:0]    hold_cnt_q;
    reg [3:0]    bit_idx_q;
    reg [1:0]    byte_sel_q;
    reg [7:0]    cfg_idx_q;
    reg [6:0]    reg_addr_q;
    reg [8:0]    wdata_q;
    reg          scl_q;
    reg          sda_val_q;
    reg          sda_oe_q;
    reg          ack_sample_q;
    reg          started_q;
    reg          txn_cfg_q;
    reg          wr_done_q;
    reg          nack_seen_q;
    reg          error_q;
    reg          cfg_done_q;

    wire tick = (div_cnt_q == QTR_M1);

    // Byte 1 of a WM8960 control transfer is {7-bit register address, data bit 8},
    // byte 2 is data bits 7:0.  See the header for the datasheet citation.
    wire [7:0] cur_byte = (byte_sel_q == 2'd0) ? {DEV_ADDR, 1'b0} :
                          (byte_sel_q == 2'd1) ? {reg_addr_q, wdata_q[8]} :
                                                wdata_q[7:0];

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            div_cnt_q    <= {QW{1'b0}};
        end else if (tick) begin
            div_cnt_q    <= {QW{1'b0}};
        end else begin
            div_cnt_q    <= div_cnt_q + 1'b1;
        end
    end

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            state_q      <= ST_IDLE;
            phase_q      <= 2'd0;
            hold_cnt_q   <= 2'd0;
            bit_idx_q    <= 4'd0;
            byte_sel_q   <= 2'd0;
            cfg_idx_q    <= 8'd0;
            reg_addr_q   <= 7'h00;
            wdata_q      <= 9'h000;
            scl_q        <= 1'b1;
            sda_val_q    <= 1'b1;
            sda_oe_q     <= 1'b0;
            ack_sample_q <= 1'b1;
            started_q    <= 1'b0;
            txn_cfg_q    <= 1'b0;
            wr_done_q    <= 1'b0;
            nack_seen_q  <= 1'b0;
            error_q      <= 1'b0;
            cfg_done_q   <= 1'b0;
            gap_cnt_q    <= {GW{1'b0}};
        end else begin
            wr_done_q <= 1'b0;

            if (!started_q) begin
                started_q <= 1'b1;
                state_q   <= ST_GAP;
                gap_cnt_q <= {GW{1'b0}};
            end else if (tick) begin
                case (state_q)
                    ST_START_H: begin
                        if (hold_cnt_q == TICK_LAST) begin
                            hold_cnt_q <= 2'd0;
                            scl_q      <= 1'b0;
                            state_q    <= ST_START_L;
                        end else begin
                            hold_cnt_q <= hold_cnt_q + 2'd1;
                        end
                    end
                    ST_START_L: begin
                        if (hold_cnt_q == TICK_LAST) begin
                            hold_cnt_q <= 2'd0;
                            phase_q    <= 2'd0;
                            bit_idx_q  <= 4'd0;
                            state_q    <= ST_BIT;
                        end else begin
                            hold_cnt_q <= hold_cnt_q + 2'd1;
                        end
                    end
                    ST_BIT: begin
                        if (phase_q == 2'd0) begin
                            if (bit_idx_q == 4'd8) begin
                                sda_oe_q  <= 1'b0;
                                sda_val_q <= 1'b1;
                            end else begin
                                sda_val_q <= cur_byte[7 - bit_idx_q];
                                sda_oe_q  <= ~cur_byte[7 - bit_idx_q];
                            end
                        end
                        if (phase_q == 2'd1) begin
                            scl_q <= 1'b1;
                        end else if (phase_q == 2'd2) begin
                            ack_sample_q <= sda_i;
                        end else if (phase_q == 2'd3) begin
                            scl_q <= 1'b0;
                            if (bit_idx_q == 4'd8) begin
                                if (ack_sample_q == 1'b0) begin
                                    if (byte_sel_q == 2'd2) begin
                                        state_q <= ST_STOP_L;
                                    end else begin
                                        byte_sel_q <= byte_sel_q + 2'd1;
                                        bit_idx_q  <= 4'd0;
                                    end
                                end else begin
                                    nack_seen_q <= 1'b1;
                                    error_q     <= 1'b1;
                                    state_q     <= ST_STOP_L;
                                end
                            end else begin
                                bit_idx_q <= bit_idx_q + 4'd1;
                            end
                        end
                        phase_q <= phase_q + 2'd1;
                    end
                    ST_STOP_L: begin
                        if (phase_q == 2'd0) begin
                            sda_oe_q  <= 1'b1;
                            sda_val_q <= 1'b0;
                        end
                        if (hold_cnt_q == TICK_LAST) begin
                            hold_cnt_q <= 2'd0;
                            scl_q      <= 1'b1;
                            state_q    <= ST_STOP_H;
                        end else begin
                            hold_cnt_q <= hold_cnt_q + 2'd1;
                        end
                    end
                    ST_STOP_H: begin
                        if (hold_cnt_q == TICK_LAST) begin
                            hold_cnt_q <= 2'd0;
                            sda_oe_q   <= 1'b0;
                            sda_val_q  <= 1'b1;
                            state_q    <= ST_STOP_HOLD;
                        end else begin
                            hold_cnt_q <= hold_cnt_q + 2'd1;
                        end
                    end
                    ST_STOP_HOLD: begin
                        if (hold_cnt_q == TICK_LAST) begin
                            hold_cnt_q <= 2'd0;
                            phase_q    <= 2'd0;
                            if (txn_cfg_q) begin
                                cfg_idx_q <= cfg_idx_q + 8'd1;
                                gap_cnt_q <= {GW{1'b0}};
                                state_q   <= ST_GAP;
                            end else begin
                                wr_done_q <= 1'b1;
                                state_q   <= ST_IDLE;
                            end
                        end else begin
                            hold_cnt_q <= hold_cnt_q + 2'd1;
                        end
                    end
                    ST_GAP: begin
                        if (gap_cnt_q >= GAP_MAX) begin
                            gap_cnt_q <= {GW{1'b0}};
                            if (cfg_idx_q >= CFG_COUNT) begin
                                cfg_done_q <= 1'b1;
                                state_q    <= ST_IDLE;
                            end else begin
                                reg_addr_q <= CFG_REG(cfg_idx_q);
                                wdata_q    <= CFG_DATA(cfg_idx_q);
                                byte_sel_q <= 2'd0;
                                bit_idx_q  <= 4'd0;
                                phase_q    <= 2'd0;
                                hold_cnt_q <= 2'd0;
                                txn_cfg_q  <= 1'b1;
                                scl_q      <= 1'b1;
                                sda_oe_q   <= 1'b1;
                                sda_val_q  <= 1'b0;
                                state_q    <= ST_START_H;
                            end
                        end
                    end
                    default: begin
                        state_q <= ST_IDLE;
                    end
                endcase
            end else if (state_q == ST_GAP) begin
                if (gap_cnt_q < GAP_MAX) begin
                    gap_cnt_q <= gap_cnt_q + 1'b1;
                end
            end

            if (started_q && wr_req && state_q == ST_IDLE) begin
                reg_addr_q <= reg_addr;
                wdata_q    <= wdata;
                byte_sel_q <= 2'd0;
                bit_idx_q  <= 4'd0;
                phase_q    <= 2'd0;
                hold_cnt_q <= 2'd0;
                txn_cfg_q  <= 1'b0;
                scl_q      <= 1'b1;
                sda_oe_q   <= 1'b1;
                sda_val_q  <= 1'b0;
                state_q    <= ST_START_H;
            end else if (started_q && wr_req) begin
                error_q <= 1'b1;
            end
        end
    end

    assign scl_o     = scl_q;
    assign sda_o     = sda_val_q;
    assign sda_oe    = sda_oe_q;
    assign busy      = (state_q != ST_IDLE);
    assign wr_done   = wr_done_q;
    assign nack_seen = nack_seen_q;
    assign error     = error_q;
    assign cfg_done  = cfg_done_q;

endmodule
