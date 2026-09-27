`timescale 1ns/1ps

module nes_video_scaler (
    input  wire        clk,
    input  wire        reset,
    input  wire        pixel_valid,
    input  wire [7:0]  in_pixel_x,
    input  wire [7:0]  in_pixel_y,
    input  wire [3:0]  in_pixel_index,
    output reg  [9:0]  out_pixel_x,
    output reg  [9:0]  out_pixel_y,
    output reg  [15:0] rgb565,
    output reg         line_ready,
    output reg         frame_ready
);

    localparam [7:0] LINE_LAST = 8'd255;
    localparam [7:0] FRAME_LAST = 8'd239;
    localparam [9:0] SCALE_W_LAST = 10'd511;
    localparam [9:0] SCALE_H_LAST = 10'd479;

    reg [15:0] frame_mem [0:61439];

    reg [7:0] line_count;
    reg [7:0] frame_line_count;

    reg [9:0] scan_x;
    reg [9:0] scan_y;

    wire [9:0] scan_x_next;
    wire [9:0] scan_y_next;
    wire [9:0] scan_line_last;
    wire [15:0] mem_read_addr;

    function [15:0] palette_rgb565;
        input [3:0] color_index;
        begin
            case (color_index)
                6'h00: palette_rgb565 = 16'h630C;
                6'h01: palette_rgb565 = 16'h00F1;
                6'h02: palette_rgb565 = 16'h0884;
                6'h03: palette_rgb565 = 16'h310C;
                6'h04: palette_rgb565 = 16'h4008;
                6'h05: palette_rgb565 = 16'h5807;
                6'h06: palette_rgb565 = 16'h6080;
                6'h07: palette_rgb565 = 16'h7140;
                6'h08: palette_rgb565 = 16'h79E0;
                6'h09: palette_rgb565 = 16'h6A80;
                6'h0A: palette_rgb565 = 16'h5B20;
                6'h0B: palette_rgb565 = 16'h4360;
                6'h0C: palette_rgb565 = 16'h2B21;
                6'h0D: palette_rgb565 = 16'h0AA2;
                6'h0E: palette_rgb565 = 16'h0204;
                6'h0F: palette_rgb565 = 16'h0184;
                6'h10: palette_rgb565 = 16'h0000;
                6'h11: palette_rgb565 = 16'hBDF7;
                6'h12: palette_rgb565 = 16'h039C;
                6'h13: palette_rgb565 = 16'h1C5E;
                6'h14: palette_rgb565 = 16'h6D1E;
                6'h15: palette_rgb565 = 16'h9D1E;
                6'h16: palette_rgb565 = 16'hC55E;
                6'h17: palette_rgb565 = 16'hE59E;
                6'h18: palette_rgb565 = 16'hED38;
                6'h19: palette_rgb565 = 16'hD454;
                6'h1A: palette_rgb565 = 16'hCB8F;
                6'h1B: palette_rgb565 = 16'hA32E;
                6'h1C: palette_rgb565 = 16'h82CC;
                6'h1D: palette_rgb565 = 16'h628C;
                6'h1E: palette_rgb565 = 16'h4A2A;
                6'h1F: palette_rgb565 = 16'h0000;
                6'h20: palette_rgb565 = 16'hFFFF;
                6'h21: palette_rgb565 = 16'h053F;
                6'h22: palette_rgb565 = 16'h3DDF;
                6'h23: palette_rgb565 = 16'h6E3F;
                6'h24: palette_rgb565 = 16'h9E9F;
                6'h25: palette_rgb565 = 16'hC6DF;
                6'h26: palette_rgb565 = 16'hD71F;
                6'h27: palette_rgb565 = 16'hEF3F;
                6'h28: palette_rgb565 = 16'hFF3F;
                6'h29: palette_rgb565 = 16'hFE3B;
                6'h2A: palette_rgb565 = 16'hFD37;
                6'h2B: palette_rgb565 = 16'hF494;
                6'h2C: palette_rgb565 = 16'hEC12;
                6'h2D: palette_rgb565 = 16'hDBAF;
                6'h2E: palette_rgb565 = 16'hC34E;
                6'h2F: palette_rgb565 = 16'h9AEE;
                6'h30: palette_rgb565 = 16'hFEDB;
                6'h31: palette_rgb565 = 16'h05DF;
                6'h32: palette_rgb565 = 16'h6E7F;
                6'h33: palette_rgb565 = 16'h9EDE;
                6'h34: palette_rgb565 = 16'hC71E;
                6'h35: palette_rgb565 = 16'hE77E;
                6'h36: palette_rgb565 = 16'hF7BE;
                6'h37: palette_rgb565 = 16'hFFDF;
                6'h38: palette_rgb565 = 16'hFE3D;
                6'h39: palette_rgb565 = 16'hFD5A;
                6'h3A: palette_rgb565 = 16'hF518;
                6'h3B: palette_rgb565 = 16'hF516;
                6'h3C: palette_rgb565 = 16'hF514;
                6'h3D: palette_rgb565 = 16'hF532;
                6'h3E: palette_rgb565 = 16'hF594;
                6'h3F: palette_rgb565 = 16'hF594;
                default: palette_rgb565 = 16'h0000;
            endcase
        end
    endfunction

    assign scan_line_last = (scan_x == SCALE_W_LAST);
    assign scan_x_next = scan_line_last ? 10'd0 : (scan_x + 10'd1);
    assign scan_y_next = scan_line_last
                       ? ((scan_y == SCALE_H_LAST) ? 10'd0 : (scan_y + 10'd1))
                       : scan_y;
    assign mem_read_addr = {scan_y[8:1], scan_x[8:1]};

    always @(posedge clk) begin
        if (reset) begin
            scan_x <= 10'd0;
            scan_y <= 10'd0;
            out_pixel_x <= 10'd0;
            out_pixel_y <= 10'd0;
            rgb565 <= 16'd0;
        end else begin
            scan_x <= scan_x_next;
            scan_y <= scan_y_next;
            out_pixel_x <= scan_x;
            out_pixel_y <= scan_y;
            rgb565 <= frame_mem[mem_read_addr];
        end
    end

    always @(posedge clk) begin
        if (reset) begin
            line_count <= 8'd0;
            frame_line_count <= 8'd0;
            line_ready <= 1'b0;
            frame_ready <= 1'b0;
        end else begin
            line_ready <= 1'b0;
            frame_ready <= 1'b0;
            if (pixel_valid) begin
                frame_mem[{in_pixel_y, in_pixel_x}] <= palette_rgb565(in_pixel_index);
                if (line_count == LINE_LAST) begin
                    line_count <= 8'd0;
                    line_ready <= 1'b1;
                    if (frame_line_count == FRAME_LAST) begin
                        frame_line_count <= 8'd0;
                        frame_ready <= 1'b1;
                    end else begin
                        frame_line_count <= frame_line_count + 8'd1;
                    end
                end else begin
                    line_count <= line_count + 8'd1;
                end
            end
        end
    end

endmodule
