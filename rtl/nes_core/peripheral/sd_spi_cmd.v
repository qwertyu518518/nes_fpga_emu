`timescale 1ns/1ps

// SD/eMMC SPI command frame transmitter (Verilog-2001, synthesisable).
//
// One transaction shifts {8'h40|cmd, arg[31:24], arg[23:16], arg[15:8],
// arg[7:0], {crc7, 1'b1}} out MSB first, then nine 0xFF dummy bytes: the
// first eight clock the reply in, resp0/resp1 keep the first two and the ninth
// adds the clocks before CS may go high, so a frame is 15 bytes / 120 spi_clk
// periods. start is a one clock pulse honoured only while idle, done pulses for
// the clock that ends the frame, busy is high from the clock that accepts start
// through that clock, and nothing here is hard coded.
//
// CRC7 is x^7+x^3+1 (0x89), init 0, MSB first, one shift register step per
// input bit, so the transmit byte is {crc7, 1'b1}. The reply check recomputes
// CRC7 over resp0[7:1] and compares it with resp0[7:1], the ((crc7<<1)|1) byte
// form restricted to the seven CRC bits; an all ones (0xFF / 0x7F, card busy) or
// all zeros (0x00, no reply) field means "no CRC received" and is skipped, and
// crc7_err is sticky until reset.
//
// SPI_HZ comes from a CLK_HZ/(4*SPI_HZ) divider tick, four ticks per bit, so the
// clock half period is two ticks, CLK_HZ/(2*SPI_HZ), at 50% duty. Tick 0 presents
// the next MOSI bit while the clock is low, 1 raises the clock and the card
// samples MOSI, 2 samples MISO while the card still holds it, 3 lowers the clock
// and the card may change MISO: both edges get a half period of setup and of
// hold. Accepting start clears the divider and pulls clock and CS low together,
// so the first edge is a fixed two ticks after CS falls and the first bit
// really leaves the master.

module sd_spi_cmd #(parameter integer CLK_HZ = 21477272, SPI_HZ = 400000) (
    input  wire        clk,
    input  wire        reset,
    input  wire        start,
    input  wire [5:0]  cmd,
    input  wire [31:0] arg,
    output wire        spi_clk,
    output wire        spi_cs_n,
    output wire        spi_mosi,
    input  wire        spi_miso,
    output reg  [7:0]  resp0,
    output reg  [7:0]  resp1,
    output reg         busy,
    output reg         done,
    output reg         crc7_err,
    input  wire        crc_check_en
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

    function [6:0] crc7_upd;
        input [6:0] seed;
        input [7:0] data;
        integer k;
        reg [6:0] c;
        begin
            c = seed;
            for (k = 7; k >= 0; k = k - 1)
                c = {c[5:0], 1'b0} ^ ((c[6] ^ data[k]) ? 7'h09 : 7'h00);
            crc7_upd = c;
        end
    endfunction

    function [6:0] crc7_msg;
        input [39:0] msg;
        integer k;
        reg [6:0] c;
        begin
            c = 7'h00;
            for (k = 4; k >= 0; k = k - 1) c = crc7_upd(c, msg[8 * k +: 8]);
            crc7_msg = c;
        end
    endfunction

    localparam [1:0] ST_IDLE = 2'd0, ST_BIT = 2'd1, ST_TAIL = 2'd2;
    localparam [3:0] LAST_RX = 4'd13;
    localparam integer QTR_RAW = CLK_HZ / (4 * SPI_HZ);
    localparam integer QTR     = (QTR_RAW < 1) ? 1 : QTR_RAW;
    localparam integer QW_RAW  = clog2(QTR + 1);
    localparam integer QW      = (QW_RAW < 1) ? 1 : QW_RAW;
    localparam [QW-1:0] QTR_M1 = QTR - 1;
    reg [QW-1:0] div_cnt_q;
    reg [1:0]    state_q;
    reg [1:0]    phase_q;
    reg [3:0]    byte_idx_q;
    reg [2:0]    bit_idx_q;
    reg [5:0]    cmd_q;
    reg [31:0]   arg_q;
    reg [6:0]    crc_q;
    reg [7:0]    rx_byte_q;
    reg          clk_q, mosi_q, cs_n_q;
    wire tick = (div_cnt_q == QTR_M1);
    wire [7:0] tx_byte = (byte_idx_q == 4'd0) ? {2'b01, cmd_q[5:0]} :
                         (byte_idx_q == 4'd1) ? arg_q[31:24] :
                         (byte_idx_q == 4'd2) ? arg_q[23:16] :
                         (byte_idx_q == 4'd3) ? arg_q[15:8] :
                         (byte_idx_q == 4'd4) ? arg_q[7:0] :
                         (byte_idx_q == 4'd5) ? {crc_q, 1'b1} : 8'hff;
    wire [6:0] resp_crc  = crc7_upd(7'h00, {1'b0, resp0[7:1]});
    wire       resp_skip = (resp0[7:1] == 7'h7f) | (resp0[7:1] == 7'h00);
    always @(posedge clk) begin
        if (reset) begin
            div_cnt_q  <= {QW{1'b0}};
            state_q    <= ST_IDLE;
            phase_q    <= 2'd0;
            bit_idx_q  <= 3'd0;
            byte_idx_q <= 4'd0;
            cmd_q      <= 6'd0;
            arg_q      <= 32'd0;
            crc_q      <= 7'h00;
            rx_byte_q  <= 8'h00;
            clk_q      <= 1'b1;
            mosi_q     <= 1'b1;
            cs_n_q     <= 1'b1;
            resp0      <= 8'h00;
            resp1      <= 8'h00;
            busy       <= 1'b0;
            done       <= 1'b0;
            crc7_err   <= 1'b0;
        end else begin
            done <= 1'b0;
            busy <= (state_q != ST_IDLE) | (start & (state_q == ST_IDLE));
            if (tick) div_cnt_q <= {QW{1'b0}}; else div_cnt_q <= div_cnt_q + 1'b1;
            if (state_q == ST_IDLE) begin
                clk_q  <= 1'b1;
                mosi_q <= 1'b1;
                cs_n_q <= 1'b1;
                if (start) begin
                    cmd_q      <= cmd;
                    arg_q      <= arg;
                    crc_q      <= crc7_msg({2'b01, cmd[5:0], arg});
                    div_cnt_q  <= {QW{1'b0}};
                    byte_idx_q <= 4'd0;
                    bit_idx_q  <= 3'd0;
                    phase_q    <= 2'd0;
                    clk_q      <= 1'b0;
                    cs_n_q     <= 1'b0;
                    state_q    <= ST_BIT;
                end
            end else if (tick) begin
                if (phase_q == 2'd0) mosi_q <= tx_byte[7 - bit_idx_q];
                else if (phase_q == 2'd1) clk_q <= 1'b1;
                else if (phase_q == 2'd2) rx_byte_q <= {rx_byte_q[6:0], spi_miso};
                else begin
                    clk_q <= 1'b0;
                    if (bit_idx_q != 3'd7) begin
                        bit_idx_q <= bit_idx_q + 3'd1;
                    end else if (state_q == ST_TAIL) begin
                        bit_idx_q <= 3'd0;
                        cs_n_q    <= 1'b1;
                        state_q   <= ST_IDLE;
                        done      <= 1'b1;
                        if (crc_check_en && !resp_skip && (resp_crc != resp0[7:1]))
                            crc7_err <= 1'b1;
                    end else begin
                        bit_idx_q <= 3'd0;
                        if (byte_idx_q == 4'd6) resp0 <= rx_byte_q; else if (byte_idx_q == 4'd7) resp1 <= rx_byte_q;
                        if (byte_idx_q == LAST_RX) state_q <= ST_TAIL;
                        else byte_idx_q <= byte_idx_q + 4'd1;
                    end
                end
                phase_q <= phase_q + 2'd1;
            end
        end
    end

    assign spi_clk = clk_q;
    assign spi_cs_n = cs_n_q;
    assign spi_mosi = mosi_q;

endmodule
