`timescale 1ns/1ps

// 800x480 active image for the Zynq 4.3" RGB LCD, vendor LCD ID 16'h4384.
// Parameter defaults are the vendor lcd_driver values for that panel, copied
// verbatim from ZYNQ_7020_FPGA/12_lcd_rgb_char/lcd_rgb_char.srcs/sources_1/new/
// lcd_driver.v: H_SYNC=128 H_BACK=88 H_DISP=800 H_FRONT=40 H_TOTAL=1056 (96-100),
// V_SYNC=2 V_BACK=33 V_DISP=480 V_FRONT=10 V_TOTAL=525 (102-106), DE window
// [h_sync+h_back,+h_disp) x [v_sync+v_back,+v_disp) (136-138), lcd_hs/lcd_vs tied
// 1'b1 in DE mode (127-128), blanked bus 24'd0 (150). Dot clock 25 MHz is the
// vendor clk_div.v selection for 16'h4384 (line 60), so ce is 1 per 40 ns.
// The bus stays RGB565; the RGB888 expansion for lcd_rgb[23:0] is a top-level
// wiring decision and is not done here.
//
// Scaling is exact: 800 = 256*3 + 32 and 32 = 256/8, so each input pixel emits
// 3 output pixels and each 8th input pixel emits a 4th. 800 = 32 groups of 25
// output dots, so mod8_count/group_count/emit_slot all return to zero at the end
// of every scanline and the active width is exactly 800 on every line of every
// frame. Vertically 240 -> 480 is exactly 2:1.
//
// Frame buffer is written on the input side and read on the output side, the
// same single-boundary CDC as nes_video_scaler. Read-latency contract: the data
// for the dot being emitted is captured by the same clock edge that advances the
// raster into that dot, because mem_read_addr is built from the same *_next
// signals the raster counters are loaded from, so no output stage and no skew.
// A read colliding with a same-cycle write to the same address returns the
// previously stored value (BRAM read-first).
module nes_video_800x480 #(
    parameter integer H_TOTAL          = 1056,
    parameter integer V_TOTAL          = 525,
    parameter integer H_ACTIVE_START   = 216,
    parameter integer H_ACTIVE_END     = 1016,
    parameter integer V_ACTIVE_START   = 35,
    parameter integer V_ACTIVE_END     = 515,
    parameter integer SYNC_ACTIVE_HIGH = 1,
    parameter [15:0]  BLANK_RGB565     = 16'h0000
) (
    input  wire        clk,
    input  wire        reset,
    input  wire        ce,
    input  wire        in_valid,
    input  wire [7:0]  in_x,
    input  wire [7:0]  in_y,
    input  wire [15:0] in_rgb565,
    output reg  [15:0] rgb565,
    output reg         de,
    output reg         hsync,
    output reg         vsync,
    output reg  [10:0] hcount,
    output reg  [10:0] vcount,
    output reg  [10:0] pixel_x,
    output reg  [10:0] pixel_y,
    output reg         frame_pulse,
    output reg         in_line_ready,
    output reg         in_frame_ready
);

    localparam SRC_LAST  = 8'd255;
    localparam SRC_RLAST = 9'd239;

    localparam [10:0] H_LAST = H_TOTAL[10:0] - 11'd1;
    localparam [10:0] V_LAST = V_TOTAL[10:0] - 11'd1;
    localparam [10:0] H_A0   = H_ACTIVE_START[10:0];
    localparam [10:0] H_A1   = H_ACTIVE_END[10:0];
    localparam [10:0] V_A0   = V_ACTIVE_START[10:0];
    localparam [10:0] V_A1   = V_ACTIVE_END[10:0];

    localparam SYNC_LEVEL = SYNC_ACTIVE_HIGH ? 1'b1 : 1'b0;

    reg [15:0] frame_mem [0:61439];

    reg  [7:0] in_col_count;
    reg  [8:0] in_row_count;

    reg  [2:0] mod8_count;
    reg  [4:0] group_count;
    reg  [1:0] emit_slot;

    wire        h_line_last;
    wire [10:0] hcount_next;
    wire [10:0] vcount_next;
    wire        de_now;
    wire        emit_step;
    wire        h_active;
    wire        v_active;
    wire        de_next;
    wire        col_done;
    wire        group_rolls;
    wire [2:0]  mod8_count_next;
    wire [4:0]  group_count_next;
    wire [1:0]  emit_slot_next;
    wire [7:0]  src_col;
    wire [7:0]  src_col_next;
    wire [7:0]  src_row;
    wire [11:0] v_active_index;
    wire [15:0] mem_read_addr;
    wire [15:0] mem_write_addr;

    assign h_line_last = (hcount == H_LAST);
    assign hcount_next = h_line_last ? 11'd0 : (hcount + 11'd1);
    assign vcount_next = h_line_last ? ((vcount == V_LAST) ? 11'd0 : (vcount + 11'd1)) : vcount;

    assign h_active = (hcount_next >= H_A0) && (hcount_next < H_A1);
    assign v_active = (vcount_next >= V_A0) && (vcount_next < V_A1);
    assign de_next  = h_active & v_active;
    assign de_now   = de;

    assign v_active_index = {1'b0, vcount_next} - {1'b0, V_A0};
    assign src_row = v_active ? v_active_index[8:1] : 8'd0;

    assign src_col = {group_count, mod8_count};

    assign group_rolls     = (mod8_count == 3'd7);
    assign emit_step       = de_next && de_now;
    assign col_done        = emit_step && (group_rolls ? (emit_slot == 2'd3) : (emit_slot == 2'd2));
    assign mod8_count_next = de_next ? (col_done ? (mod8_count + 3'd1) : mod8_count) : 3'd0;
    assign group_count_next = de_next
                            ? (col_done && group_rolls ? (group_count + 5'd1) : group_count)
                            : 5'd0;
    assign emit_slot_next = de_next ? (col_done ? 2'd0 : (emit_step ? (emit_slot + 2'd1) : emit_slot)) : 2'd0;
    assign src_col_next = {group_count_next, mod8_count_next};

    assign mem_read_addr  = {src_row, src_col_next};
    assign mem_write_addr = {in_y, in_x};

    always @(posedge clk) begin
        if (reset) begin
            hcount      <= 11'd0;
            vcount      <= 11'd0;
            de          <= 1'b0;
            hsync       <= SYNC_LEVEL;
            vsync       <= SYNC_LEVEL;
            rgb565      <= BLANK_RGB565;
            pixel_x     <= 11'd0;
            pixel_y     <= 11'd0;
            frame_pulse <= 1'b0;
            mod8_count  <= 3'd0;
            group_count <= 5'd0;
            emit_slot   <= 2'd0;
        end else if (ce) begin
            hcount      <= hcount_next;
            vcount      <= vcount_next;
            de          <= de_next;
            hsync       <= SYNC_LEVEL;
            vsync       <= SYNC_LEVEL;
            rgb565      <= de_next ? frame_mem[mem_read_addr] : BLANK_RGB565;
            pixel_x     <= de_next ? (hcount_next - H_A0) : 11'd0;
            pixel_y     <= de_next ? (vcount_next - V_A0) : 11'd0;
            frame_pulse <= (hcount_next == H_LAST) && (vcount_next == V_LAST);
            mod8_count  <= mod8_count_next;
            group_count <= group_count_next;
            emit_slot   <= emit_slot_next;
        end
    end

    always @(posedge clk) begin
        if (reset) begin
            in_col_count   <= 8'd0;
            in_row_count   <= 9'd0;
            in_line_ready  <= 1'b0;
            in_frame_ready <= 1'b0;
        end else if (ce) begin
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
