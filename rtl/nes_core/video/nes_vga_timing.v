`timescale 1ns/1ps

// 640x480@60Hz VGA 时序发生器：纯计数器加一级输出寄存器，不含 IP、不含引脚、不含存储器。
// 顶层约束：本模块不得实例化 nes_video_scaler，也不得拥有 frame buffer；
// 像素来源是上游行流，缺像素或未对齐时输出黑。详见 docs/modules/vga-timing.md。
module nes_vga_timing #(
    parameter integer H_TOTAL     = 800,
    parameter integer H_ACTIVE    = 640,
    parameter integer HSYNC_START = 656,
    parameter integer HSYNC_END   = 752,
    parameter integer V_TOTAL     = 525,
    parameter integer V_ACTIVE    = 480,
    parameter integer VSYNC_START = 490,
    parameter integer VSYNC_END   = 493,
    parameter integer DE_X0       = 64,
    parameter integer DE_X1       = 576,
    parameter integer DE_Y0       = 0,
    parameter integer DE_Y1       = 480
) (
    input  wire        clk,
    input  wire        reset,
    input  wire        ce,
    input  wire        line_read_start,
    input  wire        px_valid,
    input  wire [15:0] px_rgb565,
    output reg         hsync,
    output reg         vsync,
    output reg         de,
    output reg  [15:0] rgb565,
    output reg  [9:0]  hcount,
    output reg  [9:0]  vcount,
    output reg         active_pixels,
    output reg         frame_pulse,
    output reg         line_read_sync
);

    localparam [9:0] H_LAST = H_TOTAL - 1;
    localparam [9:0] V_LAST = V_TOTAL - 1;

    localparam [9:0] P_HS0 = HSYNC_START[9:0];
    localparam [9:0] P_HSE = HSYNC_END[9:0];
    localparam [9:0] P_VS0 = VSYNC_START[9:0];
    localparam [9:0] P_VSE = VSYNC_END[9:0];
    localparam [9:0] P_DX0 = DE_X0[9:0];
    localparam [9:0] P_DX1 = DE_X1[9:0];
    localparam [9:0] P_DY0 = DE_Y0[9:0];
    localparam [9:0] P_DY1 = DE_Y1[9:0];

    reg line_started;

    wire       h_last;
    wire [9:0] h_next;
    wire [9:0] v_next;
    wire       hsync_next;
    wire       vsync_next;
    wire       de_next;
    wire       line_next;
    wire       act_next;
    wire       frame_end;

    assign h_last     = (hcount == H_LAST);
    assign h_next     = h_last ? 10'd0 : (hcount + 10'd1);
    assign v_next     = h_last ? ((vcount == V_LAST) ? 10'd0 : (vcount + 10'd1)) : vcount;

    assign hsync_next = (h_next >= P_HS0) && (h_next < P_HSE);
    assign vsync_next = (v_next >= P_VS0) && (v_next < P_VSE);
    assign de_next    = (h_next >= P_DX0) && (h_next < P_DX1) &&
                        (v_next >= P_DY0) && (v_next < P_DY1);

    assign line_next  = line_read_start ? 1'b1 : (h_last ? 1'b0 : line_started);
    assign act_next   = de_next & line_next & px_valid;
    assign frame_end  = (h_next == H_LAST) && (v_next == V_LAST);

    always @(posedge clk) begin
        if (reset) begin
            hcount         <= 10'd0;
            vcount         <= 10'd0;
            hsync          <= 1'b0;
            vsync          <= 1'b0;
            de             <= 1'b0;
            rgb565         <= 16'd0;
            active_pixels  <= 1'b0;
            frame_pulse    <= 1'b0;
            line_read_sync <= 1'b0;
            line_started   <= 1'b0;
        end else if (ce) begin
            hcount         <= h_next;
            vcount         <= v_next;
            hsync          <= hsync_next;
            vsync          <= vsync_next;
            de             <= de_next;
            rgb565         <= act_next ? px_rgb565 : 16'd0;
            active_pixels  <= act_next;
            frame_pulse    <= frame_end;
            line_read_sync <= line_read_start;
            line_started   <= line_next;
        end
    end

endmodule
