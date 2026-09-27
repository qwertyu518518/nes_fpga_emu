`timescale 1ns/1ps

// nes_cdc_fifo: single-read / single-write asynchronous FIFO for clock domain
// crossing (Verilog-2001, synthesisable).
//
// Structure
//   Two independently clocked pointer pairs, each ADDR_WIDTH+1 bits wide: a
//   binary pointer that addresses the storage array and a Gray pointer that is
//   published to the other domain. The remote Gray pointer passes through a
//   two stage flip-flop synchronizer before it feeds the local flag. Every bit
//   of the array is a pair of flip-flops: wr_clk writes mem[wr_ptr], rd_clk
//   registers mem[rd_ptr] into rd_data, so rd_data is never a combinational
//   read of the array and stays stable between read clock edges. The array
//   itself carries no reset: an entry only becomes meaningful once it has been
//   written, which is exactly what the two pointer flags guarantee.
//
// Full / empty
//   wr_full_next  = (wr_gray_next == {~rd_gray_sync2[PTR_WIDTH-1:PTR_WIDTH-2],
//                                     rd_gray_sync2[PTR_WIDTH-3:0]})
//   rd_empty_next = (rd_gray_next == wr_gray_sync2)
//   Inverting the top two Gray bits of the synchronized remote pointer is the
//   standard "one full turn behind" signature for full, and equality of the
//   whole Gray word is the signature for empty. Gray coding is what makes the
//   comparison safe: only one pointer bit changes per increment, so a
//   synchronized sample can never mix an old and a new bit.
//   ADDR_WIDTH must be >= 2, so the depth is 2**ADDR_WIDTH entries (4 minimum,
//   1024 at the default of 10) and DATA_WIDTH defaults to 32.
//
// Handshake
//   A write commits only while wr_en && !wr_full, a read only while
//   rd_en && !rd_empty. Asserting wr_en while full, or rd_en while empty, is
//   ignored: the pointer does not advance and nothing is stored or fetched.
//   The write side sees a delayed copy of the read pointer, so wr_full may
//   stay asserted for a couple of read clocks after the last entry leaves,
//   and the read side likewise may see rd_empty for a couple of write clocks
//   after the first entry arrives.
//
// Reset
//   wr_reset clears wr_ptr, wr_full and the read pointer synchronizer inside
//   the write domain. rd_reset clears rd_ptr, rd_empty, rd_data and the write
//   pointer synchronizer inside the read domain. The two resets are
//   independent and are never synchronized into the opposite domain. During a
//   reset the cross domain pointers may therefore be inconsistent, and after
//   the reset is released a few entries may be discarded or replayed before
//   the two pointers line up again. Both ends should be reset together.

module nes_cdc_fifo #(
    parameter DATA_WIDTH = 32,
    parameter ADDR_WIDTH = 10
) (
    input  wire                  wr_clk,
    input  wire                  wr_reset,
    input  wire                  wr_en,
    input  wire [DATA_WIDTH-1:0] wr_data,
    output reg                   wr_full,

    input  wire                  rd_clk,
    input  wire                  rd_reset,
    input  wire                  rd_en,
    output reg  [DATA_WIDTH-1:0] rd_data,
    output reg                   rd_empty
);

    localparam integer DEPTH     = (1 << ADDR_WIDTH);
    localparam integer PTR_WIDTH = ADDR_WIDTH + 1;

    localparam [PTR_WIDTH-1:0] PTR_ONE = {{(PTR_WIDTH - 1){1'b0}}, 1'b1};

    reg [DATA_WIDTH-1:0] mem [0:DEPTH-1];

    reg [PTR_WIDTH-1:0] wr_bin;
    reg [PTR_WIDTH-1:0] wr_bin_next;
    reg [PTR_WIDTH-1:0] wr_gray;
    reg [PTR_WIDTH-1:0] wr_gray_next;

    reg [PTR_WIDTH-1:0] rd_bin;
    reg [PTR_WIDTH-1:0] rd_bin_next;
    reg [PTR_WIDTH-1:0] rd_gray;
    reg [PTR_WIDTH-1:0] rd_gray_next;

    (* ASYNC_REG = "TRUE" *) reg [PTR_WIDTH-1:0] rd_gray_sync1;
    (* ASYNC_REG = "TRUE" *) reg [PTR_WIDTH-1:0] rd_gray_sync2;
    (* ASYNC_REG = "TRUE" *) reg [PTR_WIDTH-1:0] wr_gray_sync1;
    (* ASYNC_REG = "TRUE" *) reg [PTR_WIDTH-1:0] wr_gray_sync2;

    wire [PTR_WIDTH-1:0] wr_gray_at_full;
    wire                  wr_full_next;
    wire                  rd_empty_next;

    assign wr_gray_at_full = {~rd_gray_sync2[PTR_WIDTH-1:PTR_WIDTH-2],
                              rd_gray_sync2[PTR_WIDTH-3:0]};
    assign wr_full_next  = (wr_gray_next == wr_gray_at_full);
    assign rd_empty_next = (rd_gray_next == wr_gray_sync2);

    always @* begin
        wr_bin_next  = wr_bin;
        wr_gray_next = wr_gray;
        if (wr_en && !wr_full) begin
            wr_bin_next  = wr_bin + PTR_ONE;
            wr_gray_next = (wr_bin + PTR_ONE) ^ ((wr_bin + PTR_ONE) >> 1);
        end
    end

    always @* begin
        rd_bin_next  = rd_bin;
        rd_gray_next = rd_gray;
        if (rd_en && !rd_empty) begin
            rd_bin_next  = rd_bin + PTR_ONE;
            rd_gray_next = (rd_bin + PTR_ONE) ^ ((rd_bin + PTR_ONE) >> 1);
        end
    end

    always @(posedge wr_clk or posedge wr_reset) begin
        if (wr_reset) begin
            wr_bin  <= {PTR_WIDTH{1'b0}};
            wr_gray <= {PTR_WIDTH{1'b0}};
            wr_full <= 1'b0;
        end else begin
            if (wr_en && !wr_full)
                mem[wr_bin[ADDR_WIDTH-1:0]] <= wr_data;
            wr_bin  <= wr_bin_next;
            wr_gray <= wr_gray_next;
            wr_full <= wr_full_next;
        end
    end

    always @(posedge rd_clk or posedge rd_reset) begin
        if (rd_reset) begin
            rd_bin   <= {PTR_WIDTH{1'b0}};
            rd_gray  <= {PTR_WIDTH{1'b0}};
            rd_data  <= {DATA_WIDTH{1'b0}};
            rd_empty <= 1'b1;
        end else begin
            if (rd_en && !rd_empty)
                rd_data <= mem[rd_bin[ADDR_WIDTH-1:0]];
            rd_bin   <= rd_bin_next;
            rd_gray  <= rd_gray_next;
            rd_empty <= rd_empty_next;
        end
    end

    always @(posedge wr_clk or posedge wr_reset) begin
        if (wr_reset) begin
            rd_gray_sync1 <= {PTR_WIDTH{1'b0}};
            rd_gray_sync2 <= {PTR_WIDTH{1'b0}};
        end else begin
            rd_gray_sync1 <= rd_gray;
            rd_gray_sync2 <= rd_gray_sync1;
        end
    end

    always @(posedge rd_clk or posedge rd_reset) begin
        if (rd_reset) begin
            wr_gray_sync1 <= {PTR_WIDTH{1'b0}};
            wr_gray_sync2 <= {PTR_WIDTH{1'b0}};
        end else begin
            wr_gray_sync1 <= wr_gray;
            wr_gray_sync2 <= wr_gray_sync1;
        end
    end

endmodule
