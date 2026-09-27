`timescale 1ns/1ps

module nes_line_buffer_vga #(
    parameter integer REPEAT_LINE = 1
) (
    input  wire        wr_clk,
    input  wire        wr_reset,
    input  wire        wr_ce,
    input  wire        wr_pixel_valid,
    input  wire [7:0]  wr_x,
    input  wire [3:0]  wr_index,
    output reg         line_ready_toggle,
    output reg         line_done,
    input  wire        rd_clk,
    input  wire        rd_reset,
    input  wire        rd_ce,
    output reg         frame_line_valid,
    output reg         line_read_start,
    output reg  [8:0]  read_x,
    output reg  [15:0] read_rgb565
);

    localparam [7:0] LINE_LAST_X  = 8'd255;
    localparam [8:0] VLINE_LAST_X = 9'd511;

    reg [15:0] line_mem [0:511];

    reg wr_bank;

    reg toggle_meta;
    reg toggle_sync;
    reg toggle_seen;

    reg       rd_bank;
    reg       rd_active;
    reg       rd_second;
    reg [8:0] rd_x_cnt;
    reg [15:0] rd_mem_q;

    wire wr_line_end;
    wire toggle_new;
    wire rd_line_end;
    wire [8:0] rd_next_x;

    assign wr_line_end = wr_pixel_valid & (wr_x == LINE_LAST_X);
    assign toggle_new  = toggle_sync ^ toggle_seen;
    assign rd_line_end = (rd_x_cnt == VLINE_LAST_X);
    assign rd_next_x   = rd_x_cnt + 9'd1;

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

    always @(posedge wr_clk) begin
        if (wr_reset) begin
            wr_bank            <= 1'b0;
            line_ready_toggle  <= 1'b0;
            line_done          <= 1'b0;
        end else if (wr_ce) begin
            line_done <= 1'b0;
            if (wr_pixel_valid) begin
                line_mem[{wr_bank, wr_x}] <= palette_rgb565(wr_index);
                if (wr_line_end) begin
                    line_done         <= 1'b1;
                    line_ready_toggle <= ~line_ready_toggle;
                    wr_bank           <= ~wr_bank;
                end
            end
        end
    end

    always @(posedge rd_clk) begin
        if (rd_reset) begin
            toggle_meta       <= line_ready_toggle;
            toggle_sync       <= line_ready_toggle;
            toggle_seen       <= line_ready_toggle;
            rd_bank           <= 1'b0;
            rd_active         <= 1'b0;
            rd_second         <= 1'b0;
            rd_x_cnt          <= 9'd0;
            rd_mem_q          <= 16'd0;
            frame_line_valid  <= 1'b0;
            line_read_start   <= 1'b0;
            read_x            <= 9'd0;
            read_rgb565       <= 16'd0;
        end else if (rd_ce) begin
            toggle_meta      <= line_ready_toggle;
            toggle_sync      <= toggle_meta;
            frame_line_valid <= rd_active;
            line_read_start  <= rd_active & (rd_x_cnt == 9'd0);
            read_x           <= rd_x_cnt;
            read_rgb565      <= rd_mem_q;
            if (rd_active) begin
                if (rd_line_end) begin
                    rd_x_cnt <= 9'd0;
                    if (REPEAT_LINE != 0 && !rd_second) begin
                        rd_second <= 1'b1;
                        rd_mem_q  <= line_mem[{rd_bank, 8'd0}];
                    end else begin
                        rd_second <= 1'b0;
                        rd_bank   <= ~rd_bank;
                        rd_active <= 1'b0;
                    end
                end else begin
                    rd_mem_q <= line_mem[{rd_bank, rd_next_x[8:1]}];
                    rd_x_cnt <= rd_x_cnt + 9'd1;
                end
            end else if (toggle_new) begin
                toggle_seen <= toggle_sync;
                rd_active   <= 1'b1;
                rd_second   <= 1'b0;
                rd_x_cnt    <= 9'd0;
                rd_mem_q    <= line_mem[{rd_bank, 8'd0}];
            end
        end
    end

endmodule
