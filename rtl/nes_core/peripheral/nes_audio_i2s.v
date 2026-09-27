`timescale 1ns/1ps

// nes_audio_i2s: stereo sample FIFO, I2S bit serialiser and bit clock divider
// for the NES audio path (Verilog-2001, synthesisable).
//
// Composition
//   nes_cdc_fifo         sample ring buffer that carries the write side clock
//                        domain into the read side clock domain
//   read fetch throttle  one deep read ahead window that keeps the fifo read
//                        pointer from running ahead of the bit stream
//   intake gate          the shifter ready signal turned into the one cycle
//                        sample_valid pulse the serialiser expects
//   nes_i2s_shifter      32 bit serialiser clocked by rd_clk, enabled by rd_ce
//   bclk divider         mclk divided down by BCLK_DIV, fifty percent duty
//   output registers     dout and lrck captured on the bclk rising edge
//
// Parameters
//   DATA_WIDTH   nominal sample word width in bits. The datapath itself is
//                fixed at 32 bits because nes_i2s_shifter is a stereo 16+16
//                serialiser; DATA_WIDTH is only meaningful at its 32 bit
//                default.
//   ADDR_WIDTH   fifo depth exponent, 2**ADDR_WIDTH samples.
//   BCLK_DIV     bclk period in mclk cycles. BCLK_DIV = 1 passes mclk straight
//                through, BCLK_DIV = 2 and above divide by BCLK_DIV with a
//                fifty percent duty cycle.
//   BIT_REVERSED passed to nes_i2s_shifter, see that module for the order.
//
// Sample word
//   The fifo is loaded with {wr_right, wr_left}, so the shifter already sees
//   the layout it expects: bits 15:0 are the left channel, bits 31:16 the right
//   channel, and the left channel leaves first.
//
// Clock domains
//   wr_clk, wr_reset, wr_en, wr_left and wr_right drive the fifo write side,
//   and wr_full is the only write domain signal that leaves it.
//   rd_clk and rd_reset drive the read side: the fifo read pointer, the read
//   fetch throttle, the intake gate, the shifter, underflow and the shifter
//   side of dropped.
//   mclk drives the bclk divider and, through bclk, the dout and lrck output
//   registers.
//   The only signals that cross from the read side to the output side are the
//   single bit out_bit, out_lrck and out_valid of the shifter. No multi bit
//   value crosses directly: the 32 bit sample is handed over inside the rd_clk
//   domain only, and both pointer sets of the fifo are synchronised Gray words.
//   The shifter ready signal is consumed combinationally in this module, and
//   ready is a function of the shifter registers, of ce and of nothing else, so
//   gating the read and the intake with it adds no new crossing. ce here is
//   rd_ce, which already belongs to the rd_clk domain.
//
// Read fetch throttle and intake gate
//   The fifo read is destructive and rd_data is a single register, so a sample
//   that is read too early cannot be held anywhere except that one register,
//   and a sample that is read too late is not there when the serialiser frees.
//   The serialiser consumes one sample per 32 enabled clocks, so the two edges
//   that matter are the edge on which it takes a new sample and the bit 31 edge
//   on which it frees and refills in the same clock; the second is the only
//   edge on which a busy serialiser accepts anything, which is exactly what
//   nes_i2s_shifter ready reports.
//
//   fetch_hold is the read ahead window. It is set on the edge that reads a
//   sample, meaning rd_data now holds one fetched sample, and cleared on the
//   edge on which the serialiser takes it, so at most one fetched sample is ever
//   outstanding and rd_data is never overwritten while the sample in it is
//   still needed. That makes the read rate follow the consumption rate: a read
//   happens right after the previous sample has been consumed and never again
//   until the next one is. The read condition is !rd_empty && !fetch_hold.
//
//   The intake pulse into the serialiser is fetch_hold && ready, so the data is
//   presented on exactly the edges that accept it and never on any other, and
//   the serialiser can never drop a sample. The two conditions are mutually
//   exclusive, which is what lets fetch_hold load and clear in one register.
//
//   ready must not be used directly on the read. A read issued on an edge
//   through ready lands in rd_data one clock later, so the earliest edge on
//   which that sample can be taken is the following clock, by which time a
//   serialiser that was busy has already dropped busy and the stream has a dead
//   clock in it. Throttling on !fetch_hold instead issues the read early, while
//   the serialiser is still busy, and lets the fifo's own depth plus the one
//   rd_data register hold the sample until the bit 31 edge arrives.
//
// Backpressure
//   wr_full is the only backpressure signal of the write domain and the producer
//   must honour it: it is the one condition under which a written sample is
//   genuinely lost. dropped is the union of the two ways a sample can be lost,
//   the sticky drop of the serialiser and wr_full, so a high dropped either
//   means a sample reached a serialiser that had no room for it, which the
//   intake gate above is meant to make impossible, or means the write side was
//   offered a sample while the fifo was full. It is a status flag only: it is
//   not a handshake and is consumed by neither clock domain, so combining the
//   two terms across domains is deliberate. wr_en while wr_full is high is
//   ignored by the fifo and the sample is simply gone, which is what the
//   wr_full term reports.
//
// Reset
//   wr_reset and rd_reset are independent and belong to their own domain, as in
//   nes_cdc_fifo. underflow is sticky and is cleared by rd_reset. dout and
//   lrck are cleared by rd_reset as well, asynchronously in the mclk domain.
//   With the read ahead window in place the reader keeps one sample in
//   rd_data while the serialiser is busy, so rd_empty is asserted again between
//   samples whenever the producer cannot stay ahead; underflow reports exactly
//   that and is not a defect.

module nes_audio_i2s #(
    parameter integer DATA_WIDTH   = 32,
    parameter integer ADDR_WIDTH   = 10,
    parameter integer BCLK_DIV     = 1,
    parameter integer BIT_REVERSED = 0
) (
    input  wire        wr_clk,
    input  wire        wr_reset,
    input  wire        wr_en,
    input  wire [15:0] wr_left,
    input  wire [15:0] wr_right,
    output wire        wr_full,
    output wire        dropped,

    input  wire        rd_clk,
    input  wire        rd_reset,
    input  wire        mclk,
    input  wire        rd_ce,
    output wire        underflow,

    output wire        bclk,
    output wire        lrck,
    output wire        dout,
    output wire        sample_valid
);

    function integer log2i;
        input integer value;
        integer v;
        begin
            v = value - 1;
            for (log2i = 0; v > 0; log2i = log2i + 1)
                v = v >> 1;
        end
    endfunction

    localparam integer SAMPLE_WIDTH = 32;
    localparam integer DIV_HALF     = (BCLK_DIV / 2) < 1 ? 1 : (BCLK_DIV / 2);
    localparam integer DIV_W        = (DIV_HALF < 2) ? 1 : log2i(DIV_HALF);

    localparam [DIV_W-1:0] DIV_LAST = DIV_HALF - 1;

    wire [SAMPLE_WIDTH-1:0] wr_data;
    wire                    wr_full_i;
    wire                    rd_empty;
    wire [SAMPLE_WIDTH-1:0] rd_data;
    wire                    rd_en;

    reg                     fetch_hold;
    reg                     underflow_r;

    wire                    fifo_valid;
    wire [SAMPLE_WIDTH-1:0] sample_data;
    wire                    sh_out_valid;
    wire                    sh_out_bit;
    wire                    sh_out_lrck;
    wire                    sh_ready;
    wire                    sh_dropped;

    reg  [DIV_W-1:0]        div_cnt;
    reg                     bclk_int;
    reg                     dout_r;
    reg                     lrck_r;

    assign wr_data     = {wr_right, wr_left};
    assign wr_full     = wr_full_i;
    assign rd_en       = !rd_empty && !fetch_hold;
    assign fifo_valid  = fetch_hold && sh_ready;
    assign sample_data = rd_data;

    nes_cdc_fifo #(
        .DATA_WIDTH (SAMPLE_WIDTH),
        .ADDR_WIDTH (ADDR_WIDTH)
    ) u_fifo (
        .wr_clk   (wr_clk),
        .wr_reset (wr_reset),
        .wr_en    (wr_en),
        .wr_data  (wr_data),
        .wr_full  (wr_full_i),
        .rd_clk   (rd_clk),
        .rd_reset (rd_reset),
        .rd_en    (rd_en),
        .rd_data  (rd_data),
        .rd_empty (rd_empty)
    );

    always @(posedge rd_clk or posedge rd_reset) begin
        if (rd_reset) begin
            fetch_hold <= 1'b0;
        end else begin
            if (rd_en)
                fetch_hold <= 1'b1;
            else if (fifo_valid)
                fetch_hold <= 1'b0;
        end
    end

    always @(posedge rd_clk or posedge rd_reset) begin
        if (rd_reset) begin
            underflow_r <= 1'b0;
        end else begin
            if (rd_empty)
                underflow_r <= 1'b1;
        end
    end

    nes_i2s_shifter #(
        .BIT_REVERSED (BIT_REVERSED)
    ) u_shifter (
        .clk          (rd_clk),
        .reset        (rd_reset),
        .ce           (rd_ce),
        .sample_valid (fifo_valid),
        .sample_data  (sample_data),
        .out_valid    (sh_out_valid),
        .out_bit      (sh_out_bit),
        .out_lrck     (sh_out_lrck),
        .busy         (),
        .dropped      (sh_dropped),
        .ready        (sh_ready)
    );

    always @(posedge mclk or posedge rd_reset) begin
        if (rd_reset) begin
            div_cnt  <= {DIV_W{1'b0}};
            bclk_int <= 1'b0;
        end else begin
            if (div_cnt == DIV_LAST) begin
                div_cnt  <= {DIV_W{1'b0}};
                bclk_int <= ~bclk_int;
            end else begin
                div_cnt <= div_cnt + 1'b1;
            end
        end
    end

    assign bclk = (BCLK_DIV == 1) ? mclk : bclk_int;

    always @(posedge bclk or posedge rd_reset) begin
        if (rd_reset) begin
            dout_r <= 1'b0;
            lrck_r <= 1'b0;
        end else begin
            dout_r <= sh_out_bit;
            lrck_r <= sh_out_lrck;
        end
    end

    assign dout         = dout_r;
    assign lrck         = lrck_r;
    assign sample_valid = sh_out_valid;
    assign dropped      = sh_dropped | wr_full_i;
    assign underflow    = underflow_r;

endmodule
