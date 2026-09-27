`timescale 1ns/1ps

module nes_controller #(
    parameter [1:0] EXTRA_READ = 2'd0
)(
    input  wire       clk,
    input  wire       reset,
    input  wire       latch_strobe,
    input  wire       read_strobe,
    input  wire       read_select,
    input  wire [7:0] buttons,
    input  wire [7:0] buttons2,
    output wire       data_bit,
    output wire [7:0] data_out,
    output wire [7:0] dbg_sr1,
    output wire [7:0] dbg_sr2,
    output wire [7:0] dbg_latch1,
    output wire [7:0] dbg_latch2,
    output wire [3:0] dbg_cnt1,
    output wire [3:0] dbg_cnt2,
    output wire [7:0] dbg_selected_sr,
    output wire [7:0] dbg_selected_latch,
    output wire [3:0] dbg_selected_cnt,
    output wire       dbg_past8
);

    localparam EXTRA_ONE  = 2'd0;
    localparam EXTRA_HOLD = 2'd1;
    localparam EXTRA_ZERO = 2'd2;

    localparam [3:0] CNT_SAT = 4'd9;

    wire fill_one  = ((EXTRA_READ == EXTRA_ONE) || (EXTRA_READ == 2'd3)) ? 1'b1 : 1'b0;
    wire hold_last = (EXTRA_READ == EXTRA_HOLD);

    reg  [7:0] sr1_q;
    reg  [7:0] sr2_q;
    reg  [7:0] latch1_q;
    reg  [7:0] latch2_q;
    reg  [3:0] cnt1_q;
    reg  [3:0] cnt2_q;
    reg        last1_q;
    reg        last2_q;

    wire latch_now = latch_strobe;
    wire read1 = read_strobe && !read_select && !latch_strobe;
    wire read2 = read_strobe &&  read_select && !latch_strobe;

    wire [7:0] sel_buttons = read_select ? buttons2  : buttons;
    wire [7:0] sel_sr     = read_select ? sr2_q     : sr1_q;
    wire [7:0] sel_latch  = read_select ? latch2_q  : latch1_q;
    wire [3:0] sel_cnt    = read_select ? cnt2_q    : cnt1_q;
    wire       sel_last   = read_select ? last2_q   : last1_q;

    wire past8 = (sel_cnt >= 4'd8);

    wire [7:0] sr1_next  = {fill_one, sr1_q[7:1]};
    wire [7:0] sr2_next  = {fill_one, sr2_q[7:1]};
    wire [3:0] cnt1_next = (cnt1_q >= CNT_SAT) ? CNT_SAT : (cnt1_q + 4'd1);
    wire [3:0] cnt2_next = (cnt2_q >= CNT_SAT) ? CNT_SAT : (cnt2_q + 4'd1);

    assign data_bit  = latch_strobe  ? sel_buttons[0] :
                       (hold_last && past8) ? sel_last : sel_sr[0];
    assign data_out  = {7'b0, data_bit};

    assign dbg_sr1            = sr1_q;
    assign dbg_sr2            = sr2_q;
    assign dbg_latch1         = latch1_q;
    assign dbg_latch2         = latch2_q;
    assign dbg_cnt1           = cnt1_q;
    assign dbg_cnt2           = cnt2_q;
    assign dbg_selected_sr    = sel_sr;
    assign dbg_selected_latch = sel_latch;
    assign dbg_selected_cnt   = sel_cnt;
    assign dbg_past8          = past8;

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            sr1_q    <= 8'h00;
            sr2_q    <= 8'h00;
            latch1_q <= 8'h00;
            latch2_q <= 8'h00;
            cnt1_q   <= 4'd0;
            cnt2_q   <= 4'd0;
            last1_q  <= 1'b0;
            last2_q  <= 1'b0;
        end else if (latch_now) begin
            latch1_q <= buttons;
            latch2_q <= buttons2;
            sr1_q    <= buttons;
            sr2_q    <= buttons2;
            cnt1_q   <= 4'd0;
            cnt2_q   <= 4'd0;
        end else begin
            if (read1) begin
                sr1_q   <= sr1_next;
                cnt1_q  <= cnt1_next;
                if (cnt1_q < 4'd8)
                    last1_q <= sr1_q[0];
            end
            if (read2) begin
                sr2_q   <= sr2_next;
                cnt2_q  <= cnt2_next;
                if (cnt2_q < 4'd8)
                    last2_q <= sr2_q[0];
            end
        end
    end

endmodule
