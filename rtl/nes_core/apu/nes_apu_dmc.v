`timescale 1ns/1ps

module nes_apu_dmc (
    input wire clk,
    input wire reset,
    input wire ce,
    input wire status_wr,
    input wire [7:0] status_wr_data,
    input wire status_clear,
    input wire reg_we,
    input wire [1:0] reg_index,
    input wire [7:0] reg_din,
    output reg [7:0] reg_dout,
    output wire dmc_bus_req,
    output wire [15:0] dmc_addr,
    input wire [7:0] dmc_rdata,
    input wire dmc_ack,
    output reg irq_flag,
    output wire [15:0] sample_addr,
    output reg [15:0] current_addr,
    output reg [11:0] bytes_remaining,
    output reg [8:0] rate_cnt,
    output reg [3:0] bits_remaining,
    output reg [7:0] bits,
    output reg [6:0] output_level,
    output reg silence,
    output reg buf_empty,
    output reg active,
    output reg [7:0] sample_buf
);

reg irq_enable;
reg loop;
reg [3:0] rate_sel;
reg [7:0] sample_page;
reg [7:0] length_reg;
reg [8:0] rate_reload;
reg state;

wire [11:0] sample_length;
wire [11:0] bytes_next;
wire [3:0] bits_after;
wire rate_tick;
wire byte_in;
wire have_byte;
wire [7:0] byte_val;
wire consume;
wire refill;
wire refill_last;
wire slot_free;
wire dmc_en_next;
wire [7:0] bits_next;
wire [6:0] level_next;

function [8:0] dmc_rate_ntsc;
    input [3:0] index;
    begin
        case (index)
            4'd0: dmc_rate_ntsc = 9'd427;
            4'd1: dmc_rate_ntsc = 9'd379;
            4'd2: dmc_rate_ntsc = 9'd339;
            4'd3: dmc_rate_ntsc = 9'd319;
            4'd4: dmc_rate_ntsc = 9'd285;
            4'd5: dmc_rate_ntsc = 9'd253;
            4'd6: dmc_rate_ntsc = 9'd225;
            4'd7: dmc_rate_ntsc = 9'd213;
            4'd8: dmc_rate_ntsc = 9'd189;
            4'd9: dmc_rate_ntsc = 9'd159;
            4'd10: dmc_rate_ntsc = 9'd141;
            4'd11: dmc_rate_ntsc = 9'd127;
            4'd12: dmc_rate_ntsc = 9'd105;
            4'd13: dmc_rate_ntsc = 9'd83;
            4'd14: dmc_rate_ntsc = 9'd71;
            default: dmc_rate_ntsc = 9'd53;
        endcase
    end
endfunction

assign sample_addr = 16'hC000 | {sample_page, 6'b000000};
assign sample_length = {4'b0000, length_reg, 4'b0000} + 12'd1;
assign dmc_bus_req = state;
assign dmc_addr = current_addr;
assign rate_tick = (rate_cnt == 9'd0);
assign byte_in = state && dmc_ack;
assign have_byte = !buf_empty || byte_in;
assign byte_val = byte_in ? dmc_rdata : sample_buf;
assign bytes_next = !byte_in ? bytes_remaining
                  : (bytes_remaining == 12'd1) ? (loop ? sample_length : 12'd0)
                  : (bytes_remaining == 12'd0) ? 12'd0
                  : (bytes_remaining - 12'd1);
assign dmc_en_next = status_wr ? status_wr_data[4] : active;
assign consume = ce && dmc_en_next && rate_tick && (bits_remaining != 4'd0);
assign bits_after = consume ? (bits_remaining - 4'd1) : bits_remaining;
assign refill = ce && dmc_en_next && rate_tick && (bits_after == 4'd0);
assign refill_last = refill && !have_byte && (bytes_next == 12'd0) && !loop;
assign slot_free = !state || dmc_ack;
assign bits_next = refill ? (have_byte ? byte_val : bits) : (consume ? {1'b0, bits[7:1]} : bits);
assign level_next = !consume ? output_level
                 : (silence ? output_level
                 : (bits[0] ? ((output_level > 7'd125) ? 7'd127 : (output_level + 7'd2))
                            : ((output_level < 7'd2) ? 7'd0 : (output_level - 7'd2))));

always @* begin
    reg_dout = 8'h00;
    case (reg_index)
        2'd0: reg_dout = {irq_enable, loop, 2'b00, rate_sel};
        2'd1: reg_dout = {1'b0, output_level};
        2'd2: reg_dout = sample_page;
        default: reg_dout = length_reg;
    endcase
    if (reset)
        reg_dout = 8'h00;
end

always @(posedge clk or posedge reset) begin
    if (reset) begin
        irq_enable <= 1'b0;
        loop <= 1'b0;
        rate_sel <= 4'd0;
        rate_reload <= 9'd427;
        rate_cnt <= 9'd0;
        sample_page <= 8'd0;
        length_reg <= 8'd0;
        current_addr <= 16'hC000;
        bytes_remaining <= 12'd0;
        sample_buf <= 8'h00;
        buf_empty <= 1'b1;
        bits <= 8'h00;
        bits_remaining <= 4'd0;
        output_level <= 7'd0;
        silence <= 1'b1;
        active <= 1'b0;
        irq_flag <= 1'b0;
        state <= 1'b0;
    end else begin
        if (byte_in) begin
            sample_buf <= dmc_rdata;
            buf_empty <= 1'b0;
            state <= 1'b0;
            if (current_addr == 16'hFFFF)
                current_addr <= 16'h8000;
            else
                current_addr <= current_addr + 16'd1;
            if (bytes_remaining != 12'd0) begin
                if (bytes_remaining == 12'd1) begin
                    if (loop) begin
                        current_addr <= sample_addr;
                        bytes_remaining <= sample_length;
                    end else begin
                        bytes_remaining <= 12'd0;
                    end
                end else begin
                    bytes_remaining <= bytes_remaining - 12'd1;
                end
            end
        end

        if (reg_we) begin
            case (reg_index)
                2'd0: begin
                    irq_enable <= reg_din[7];
                    loop <= reg_din[6];
                    rate_sel <= reg_din[3:0];
                    rate_reload <= dmc_rate_ntsc(reg_din[3:0]);
                    if (!reg_din[7])
                        irq_flag <= 1'b0;
                end
                2'd1: output_level <= reg_din[6:0];
                2'd2: sample_page <= reg_din;
                default: length_reg <= reg_din;
            endcase
        end

        if (status_wr) begin
            if (status_wr_data[4]) begin
                active <= 1'b1;
                if (bytes_remaining == 12'd0) begin
                    bytes_remaining <= sample_length;
                    current_addr <= sample_addr;
                    if (buf_empty && !state)
                        state <= 1'b1;
                end
            end else begin
                active <= 1'b0;
                state <= 1'b0;
                bytes_remaining <= 12'd0;
            end
        end

        if (status_clear)
            irq_flag <= 1'b0;

        if (ce && dmc_en_next) begin
            if (!rate_tick)
                rate_cnt <= rate_cnt - 9'd1;
            else
                rate_cnt <= rate_reload;

            output_level <= level_next;
            bits <= bits_next;

            if (refill_last) begin
                bits_remaining <= 4'd0;
                silence <= 1'b1;
                active <= status_wr ? status_wr_data[4] : 1'b0;
                if (irq_enable)
                    irq_flag <= status_wr ? 1'b0 : 1'b1;
            end else if (refill) begin
                bits_remaining <= 4'd8;
                if (have_byte) begin
                    silence <= 1'b0;
                    buf_empty <= 1'b1;
                end else begin
                    silence <= 1'b1;
                end
                if ((bytes_next != 12'd0) && slot_free)
                    state <= 1'b1;
            end else if (consume) begin
                bits_remaining <= bits_after;
            end
        end
    end
end

endmodule
