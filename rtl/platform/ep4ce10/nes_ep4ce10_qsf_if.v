`timescale 1ns/1ps

module nes_ep4ce10_qsf_if (
    input  wire        sys_clk,
    input  wire        sys_rst_n,
    input  wire        clk_ntsc,
    input  wire        clk_vga,
    input  wire [3:0]  key,
    output wire        vga_hs,
    output wire        vga_vs,
    output wire [15:0] vga_rgb,
    output wire [3:0]  led,
    output wire        beep
);

    wire        vga_de_i;
    wire [4:0]  vga_r;
    wire [5:0]  vga_g;
    wire [4:0]  vga_b;
    wire        audio_valid_i;
    wire [15:0] audio_left_i;

    reg [24:0] hb_cnt_q;

    always @(posedge clk_vga or negedge sys_rst_n) begin
        if (!sys_rst_n)
            hb_cnt_q <= 25'd0;
        else
            hb_cnt_q <= hb_cnt_q + 25'd1;
    end

    assign led[0] = ~hb_cnt_q[24];
    assign led[1] = vga_de_i;
    assign led[2] = vga_hs;
    assign led[3] = vga_vs;
    assign beep   = 1'b0;

    nes_ep4ce10_top u_dut (
        .clk_sys    (sys_clk),
        .clk_ntsc   (clk_ntsc),
        .clk_vga    (clk_vga),
        .reset_n    (sys_rst_n),
        .key0       (key[0]),
        .key1       (key[1]),
        .key2       (key[2]),
        .key3       (key[3]),
        .vga_hsync  (vga_hs),
        .vga_vsync  (vga_vs),
        .vga_de     (vga_de_i),
        .vga_r      (vga_r),
        .vga_g      (vga_g),
        .vga_b      (vga_b),
        .audio_valid(audio_valid_i),
        .audio_left (audio_left_i)
    );

    assign vga_rgb = {vga_r, vga_g, vga_b};

endmodule
