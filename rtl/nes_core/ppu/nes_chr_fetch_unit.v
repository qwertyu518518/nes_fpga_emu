`timescale 1ns/1ps

module nes_chr_fetch_unit (
  input  wire       clk,
  input  wire       ce,
  input  wire       reset,
  input  wire       req_start,
  input  wire [12:0] tile_base,
  input  wire [5:0]  tile_count,
  output reg        chr_req,
  output reg [13:0] chr_addr,
  input  wire [7:0] chr_rdata,
  output reg [7:0]  bg_lo,
  output reg [7:0]  bg_hi,
  output reg        bg_valid,
  output reg        busy
);

  localparam [2:0] S_IDLE = 3'd0;
  localparam [2:0] S_PRE  = 3'd1;
  localparam [2:0] S_ARM  = 3'd2;
  localparam [2:0] S_BEAT = 3'd3;
  localparam [2:0] S_GRAB = 3'd4;
  localparam [2:0] S_DONE = 3'd5;

  reg  [2:0]  state;
  reg  [12:0] base_q;
  reg  [5:0]  cnt_q;
  reg  [5:0]  idx_q;
  reg         pl_q;
  reg         cap_pl;
  reg         fin_q;

  wire        last_byte = pl_q && (idx_q == cnt_q - 6'd1);
  wire [13:0] nxt_addr  = base_q + {3'b0, idx_q, 4'd0} + (pl_q ? 14'd8 : 14'd0);
  wire [13:0] fwd_addr  = nxt_addr + 14'd8;

  always @(posedge clk) begin
    if (reset) begin
      state    <= S_IDLE;
      base_q   <= 13'd0;
      cnt_q    <= 6'd0;
      idx_q    <= 6'd0;
      pl_q     <= 1'b0;
      cap_pl   <= 1'b0;
      fin_q    <= 1'b0;
      chr_req  <= 1'b0;
      chr_addr <= 14'd0;
      bg_lo    <= 8'd0;
      bg_hi    <= 8'd0;
      bg_valid <= 1'b0;
      busy     <= 1'b0;
    end else if (ce) begin
      case (state)
        S_IDLE: begin
          if (req_start && !busy) begin
            base_q   <= tile_base;
            cnt_q    <= tile_count;
            idx_q    <= 6'd0;
            pl_q     <= 1'b0;
            state    <= S_PRE;
            busy     <= 1'b1;
            bg_valid <= 1'b0;
          end
        end

        S_PRE: begin
          chr_addr <= nxt_addr;
          state    <= S_ARM;
        end

        S_ARM: begin
          chr_req <= 1'b1;
          state   <= S_BEAT;
        end

        S_BEAT: begin
          chr_req <= 1'b0;
          cap_pl  <= pl_q;
          fin_q   <= last_byte;
          if (pl_q) idx_q <= idx_q + 6'd1;
          pl_q    <= ~pl_q;
          if (!last_byte) begin
            chr_addr <= fwd_addr;
          end
          state <= S_GRAB;
        end

        S_GRAB: begin
          if (cap_pl) bg_hi <= chr_rdata;
          else        bg_lo <= chr_rdata;
          if (fin_q) begin
            state <= S_DONE;
          end else begin
            chr_req <= 1'b1;
            state   <= S_BEAT;
          end
        end

        S_DONE: begin
          busy     <= 1'b0;
          bg_valid <= 1'b1;
          state    <= S_IDLE;
        end

        default: state <= S_IDLE;
      endcase
    end
  end

endmodule
