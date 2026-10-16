`timescale 1ns/1ps

// 720x480p60 (CEA-861 480p) active image for the Zynq HDMI/DVI output.
//
// Dual clock, and the SAME clock-domain-crossing contract as
// nes_video_800x480.v: frame_mem is a Xilinx simple-dual-port block RAM whose
// write port is on wr_clk (the NES core domain, 21.477272727 MHz) and whose
// read port is on rd_clk (the HDMI pixel clock, 27.000 MHz).  27 MHz is not an
// integer multiple of 21.477 MHz, so the raster cannot be clocked from the core
// with an enable; pixel data must leave on real 27 MHz edges.  The true SDP RAM
// IS the crossing, so there is no synchroniser, toggle or handshake anywhere in
// this module.  A read colliding with a same-cycle write to the same address
// returns the previously stored value (BRAM read-first), and the buffer is
// single-buffered, so the image the sink shows is whatever the most recent write
// to that address left behind.  ce gates ONLY the raster; the write port has no
// enable beyond in_valid and this module adds no backpressure.
//
// WHY THIS IS A SEPARATE MODULE AND NOT nes_video_800x480 WITH PARAMETERS
//   The two scalers share the vertical law but not the horizontal one, and they
//   read on two different clocks, so a single frame_mem instance cannot serve
//   both.  A block RAM read port is clocked by exactly one domain: 25 MHz for
//   the LCD and 27 MHz for HDMI.  Time-sharing one read port would require both
//   readers to be on the same clock, and a true-dual-port block still exposes
//   only one read port per clock, so it does not solve a two-reader,
//   two-clock problem either; true-dual-port addressing only helps when one
//   port writes and the other reads on ONE read clock, which is not this case.
//   The honest answer is that the second read domain costs a second frame_mem
//   array, which is what this module carries.  The LCD module is therefore left
//   byte-for-byte untouched, and the platform top writes every visible pixel
//   into both arrays from the one core-domain stream.  The rejected alternative
//   (one array, the second reader moved onto the first reader's clock and a
//   small FIFO across to the other pixel rate) reintroduces a CDC and a buffer
//   for no saving on this device, which has 140 RAMB36 tiles against the 82
//   this build uses.
//
// Geometry, CEA-861 480p (720x480 at 59.94 Hz):
//   pixel clock  27.000 MHz
//   H: sync 62 / back porch 60 / active 720 / front porch 16 / total 858
//   V: sync  6 / back porch 30 / active 480 / front porch  9 / total 525
//   refresh 27e6 / (858*525) = 59.94 Hz
//   sync polarity negative on both axes (sync active LOW).
//
//   With hcount 0 at the leading edge of the sync pulse the active window is
//   [122,842) and the horizontal sync window is [0,62); with vcount 0 at the
//   leading edge of the vertical sync the active window is [36,516) and the
//   vertical sync window is [0,6).  All of these are parameters; the defaults
//   are the CEA-861 values above.
//
// Scaling.  256x240 source -> 720x480 output.
//   Vertical is exactly 2:1: src_row = v_row_index[8:1], 240 -> 480, so the
//   same shift nes_video_800x480.v uses survives unchanged.  Do not touch it.
//   Horizontal is 720/256 = 2.8125 = 45/16, which the 800x480 module's 25-dot
//   group emitter cannot express.  It is a rational Bresenham accumulator:
//   output dot n reads source column floor(n*256/720), maintained as an integer
//   accumulator that adds 256 per output dot and subtracts 720 on overflow,
//   advancing src_col by one on that overflow.  720 output dots therefore
//   advance src_col by exactly 720*256/720 = 256 source columns and the
//   accumulator returns to zero at the end of every scanline, so the active
//   width is exactly 720 on every line of every frame with no accumulating
//   error.  This is the same idiom the audio lane's 2016/55 decimator uses.
//   No floating point appears anywhere.
//
// Read-latency contract on rd_clk, identical to nes_video_800x480.v: the data
// for the dot being emitted is captured by the same clock edge that advances the
// raster into that dot, because mem_read_addr is built from the same *_next
// signals the raster counters are loaded from, so there is no output stage and
// no skew.
//
// in_line_ready and in_frame_ready stay in the wr_clk domain with the counters
// that produce them.  They are observation pulses only; nothing in the pixel
// path depends on them and no consumer exists in the real integration.
module nes_video_hdmi #(
    parameter integer H_TOTAL          = 858,
    parameter integer V_TOTAL          = 525,
    parameter integer H_ACTIVE_START   = 122,
    parameter integer H_ACTIVE_END     = 842,
    parameter integer V_ACTIVE_START   = 36,
    parameter integer V_ACTIVE_END     = 516,
    parameter integer H_SYNC_START     = 0,
    parameter integer H_SYNC_END       = 62,
    parameter integer V_SYNC_START     = 0,
    parameter integer V_SYNC_END       = 6,
    // 1 = sync active low (CEA-861 480p), 0 = sync active high.
    parameter integer SYNC_ACTIVE_LOW  = 1,
    parameter [15:0]  BLANK_RGB565     = 16'h0000
) (
    input  wire        wr_clk,
    input  wire        wr_reset,
    input  wire        in_valid,
    input  wire [7:0]  in_x,
    input  wire [7:0]  in_y,
    input  wire [15:0] in_rgb565,
    output reg         in_line_ready,
    output reg         in_frame_ready,
    input  wire        rd_clk,
    input  wire        rd_reset,
    input  wire        ce,
    output reg  [15:0] rgb565,
    output reg         de,
    output reg         hsync,
    output reg         vsync,
    output reg  [10:0] hcount,
    output reg  [10:0] vcount,
    output reg  [10:0] pixel_x,
    output reg  [10:0] pixel_y,
    output reg         frame_pulse
);

    localparam SRC_LAST  = 8'd255;
    localparam SRC_RLAST = 9'd239;

    localparam [10:0] H_LAST = H_TOTAL[10:0] - 11'd1;
    localparam [10:0] V_LAST = V_TOTAL[10:0] - 11'd1;
    localparam [10:0] H_A0   = H_ACTIVE_START[10:0];
    localparam [10:0] H_A1   = H_ACTIVE_END[10:0];
    localparam [10:0] V_A0   = V_ACTIVE_START[10:0];
    localparam [10:0] V_A1   = V_ACTIVE_END[10:0];
    localparam [10:0] H_S0   = H_SYNC_START[10:0];
    localparam [10:0] H_S1   = H_SYNC_END[10:0];
    localparam [10:0] V_S0   = V_SYNC_START[10:0];
    localparam [10:0] V_S1   = V_SYNC_END[10:0];

    localparam SYNC_IDLE = SYNC_ACTIVE_LOW ? 1'b1 : 1'b0;
    localparam SYNC_ACT  = SYNC_ACTIVE_LOW ? 1'b0 : 1'b1;

    // The horizontal step: 256 source columns over 720 output dots.  The
    // accumulator adds 256 per output dot and subtracts 720 on overflow.
    localparam [10:0] H_STEP_ADD = 11'd256;
    localparam [10:0] H_STEP_MOD = H_A1 - H_A0;   // 720 for the default mode

    reg [15:0] frame_mem [0:61439];

    reg  [7:0] in_col_count;
    reg  [8:0] in_row_count;

    reg  [7:0]  src_col;
    reg  [10:0] h_acc;

    wire        h_line_last;
    wire [10:0] hcount_next;
    wire [10:0] vcount_next;
    wire        h_active;
    wire        v_active;
    wire        de_next;
    wire        h_in_sync;
    wire        v_in_sync;
    wire [10:0] v_row_index;
    wire [7:0]  src_row;
    wire [10:0] h_acc_plus;
    wire        h_acc_ge;
    wire [10:0] h_acc_next;
    wire [7:0]  src_col_next;
    wire [15:0] mem_read_addr;
    wire [15:0] mem_write_addr;

    assign h_line_last = (hcount == H_LAST);
    assign hcount_next = h_line_last ? 11'd0 : (hcount + 11'd1);
    assign vcount_next = h_line_last ? ((vcount == V_LAST) ? 11'd0 : (vcount + 11'd1)) : vcount;

    assign h_active = (hcount_next >= H_A0) && (hcount_next < H_A1);
    assign v_active = (vcount_next >= V_A0) && (vcount_next < V_A1);
    assign de_next  = h_active & v_active;

    assign h_in_sync = (hcount_next >= H_S0) && (hcount_next < H_S1);
    assign v_in_sync = (vcount_next >= V_S0) && (vcount_next < V_S1);

    // The vertical law, unchanged from the 800x480 scaler: an exact 2:1 shift.
    assign v_row_index = v_active ? (vcount_next - V_A0) : 11'd0;
    assign src_row     = v_row_index[8:1];

    assign h_acc_plus   = h_acc + H_STEP_ADD;
    assign h_acc_ge     = (h_acc_plus >= H_STEP_MOD);
    // The step advances the accumulator only after a dot has actually been
    // emitted (gate on the CURRENT-active `de`, not `de_next`), so the state at
    // output dot n is exactly (src_col[n], acc[n]) with src_col[0] = 0 and
    // acc[0] = 0.  Gating on de_next would advance once on the blanking-to-active
    // transition and shift every column one dot early, which is the defect this
    // comment records.
    assign h_acc_next   = de ? (h_acc_ge ? (h_acc_plus - H_STEP_MOD) : h_acc_plus) : 11'd0;
    assign src_col_next = de ? (h_acc_ge ? (src_col + 8'd1) : src_col) : 8'd0;

    assign mem_read_addr  = {src_row, src_col_next};
    assign mem_write_addr = {in_y, in_x};

    always @(posedge rd_clk) begin
        if (rd_reset) begin
            hcount      <= 11'd0;
            vcount      <= 11'd0;
            de          <= 1'b0;
            // hcount/vcount are 0 at reset, which IS inside the sync window on
            // both axes, so the reset sync level is the ACTIVE level and the
            // registered sync outputs are consistent with the registered
            // counters from the very first clock after reset release.
            hsync       <= SYNC_ACT;
            vsync       <= SYNC_ACT;
            rgb565      <= BLANK_RGB565;
            pixel_x     <= 11'd0;
            pixel_y     <= 11'd0;
            frame_pulse <= 1'b0;
            src_col     <= 8'd0;
            h_acc       <= 11'd0;
        end else if (ce) begin
            hcount      <= hcount_next;
            vcount      <= vcount_next;
            de          <= de_next;
            hsync       <= h_in_sync ? SYNC_ACT : SYNC_IDLE;
            vsync       <= v_in_sync ? SYNC_ACT : SYNC_IDLE;
            rgb565      <= de_next ? frame_mem[mem_read_addr] : BLANK_RGB565;
            pixel_x     <= de_next ? (hcount_next - H_A0) : 11'd0;
            pixel_y     <= de_next ? (vcount_next - V_A0) : 11'd0;
            frame_pulse <= (hcount_next == H_LAST) && (vcount_next == V_LAST);
            src_col     <= src_col_next;
            h_acc       <= h_acc_next;
        end
    end

    always @(posedge wr_clk) begin
        if (wr_reset) begin
            in_col_count   <= 8'd0;
            in_row_count   <= 9'd0;
            in_line_ready  <= 1'b0;
            in_frame_ready <= 1'b0;
        end else begin
            in_line_ready  <= 1'b0;
            in_frame_ready <= 1'b0;
            if (in_valid) begin
                frame_mem[mem_write_addr] <= in_rgb565;
                if (in_col_count == SRC_LAST) begin
                    in_col_count  <= 8'd0;
                    in_line_ready <= 1'b1;
                    if (in_row_count == SRC_RLAST) begin
                        in_row_count   <= 9'd0;
                        in_frame_ready <= 1'b1;
                    end else begin
                        in_row_count <= in_row_count + 9'd1;
                    end
                end else begin
                    in_col_count <= in_col_count + 8'd1;
                end
            end
        end
    end

endmodule
