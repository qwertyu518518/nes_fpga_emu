`timescale 1ns/1ps

module nes_apu_length_lut (
    input wire [4:0] index,
    output reg [7:0] value
);

always @* begin
    case (index)
        5'd0: value = 8'd10;
        5'd1: value = 8'd254;
        5'd2: value = 8'd20;
        5'd3: value = 8'd2;
        5'd4: value = 8'd40;
        5'd5: value = 8'd4;
        5'd6: value = 8'd80;
        5'd7: value = 8'd6;
        5'd8: value = 8'd160;
        5'd9: value = 8'd8;
        5'd10: value = 8'd60;
        5'd11: value = 8'd10;
        5'd12: value = 8'd14;
        5'd13: value = 8'd12;
        5'd14: value = 8'd26;
        5'd15: value = 8'd14;
        5'd16: value = 8'd12;
        5'd17: value = 8'd16;
        5'd18: value = 8'd24;
        5'd19: value = 8'd18;
        5'd20: value = 8'd48;
        5'd21: value = 8'd20;
        5'd22: value = 8'd96;
        5'd23: value = 8'd22;
        5'd24: value = 8'd192;
        5'd25: value = 8'd24;
        5'd26: value = 8'd72;
        5'd27: value = 8'd26;
        5'd28: value = 8'd16;
        5'd29: value = 8'd28;
        5'd30: value = 8'd32;
        default: value = 8'd30;
    endcase
end

endmodule
