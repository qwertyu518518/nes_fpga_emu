`timescale 1ns/1ps

module nes_oam_dma #(
    parameter OAMADDR_WRITE = 1'b0
)(
    input  wire        clk,
    input  wire        reset,
    input  wire        start,
    input  wire [7:0]  src_page,
    input  wire [7:0]  oam_addr,
    input  wire        cpu_read_ack,
    input  wire [7:0]  cpu_rdata,
    output wire        cpu_hold,
    output wire [15:0] cpu_read_addr,
    output wire        cpu_read_req,
    output wire        ppu_reg_cs,
    output wire        ppu_reg_we,
    output wire [2:0]  ppu_reg_addr,
    output wire [7:0]  ppu_reg_dout,
    output wire        busy,
    output wire        done,
    output wire [15:0] cycle_count,
    output wire [7:0]  dbg_page,
    output wire [7:0]  dbg_oam_addr,
    output wire [7:0]  dbg_index,
    output wire [1:0]  dbg_align_left,
    output wire        dbg_addr_wr
);

    localparam [2:0] REG_OAMADDR = 3'd3;
    localparam [2:0] REG_OAMDATA = 3'd4;

    localparam [2:0] ST_IDLE  = 3'd0;
    localparam [2:0] ST_ALIGN = 3'd1;
    localparam [2:0] ST_READ  = 3'd2;
    localparam [2:0] ST_WRITE = 3'd3;

    reg [2:0]  state;
    reg [1:0]  align_left_q;
    reg        parity_q;
    reg [7:0]  page_q;
    reg [7:0]  oam_base_q;
    reg [7:0]  oam_cur_q;
    reg [7:0]  index_q;
    reg [15:0] read_addr_q;
    reg [7:0]  data_q;
    reg [15:0] cycle_cnt_q;

    wire addr_phase = (state == ST_ALIGN) && (align_left_q == 2'd1);
    wire addr_wr    = OAMADDR_WRITE && addr_phase;
    wire last_write = (state == ST_WRITE) && (index_q == 8'hFF);
    wire read_ack   = (state == ST_READ) && cpu_read_ack;

    assign busy          = (state != ST_IDLE);
    assign cpu_hold      = busy;
    assign done          = last_write;
    assign cycle_count   = cycle_cnt_q;
    assign cpu_read_req  = (state == ST_READ);
    assign cpu_read_addr = read_addr_q;
    assign ppu_reg_cs    = (state == ST_WRITE) || addr_wr;
    assign ppu_reg_we    = ppu_reg_cs;
    assign ppu_reg_addr  = (state == ST_WRITE) ? REG_OAMDATA : REG_OAMADDR;
    assign ppu_reg_dout  = (state == ST_WRITE) ? data_q :
                           (state == ST_ALIGN) ? oam_base_q : 8'h00;
    assign dbg_page      = page_q;
    assign dbg_oam_addr  = oam_cur_q;
    assign dbg_index     = index_q;
    assign dbg_align_left = align_left_q;
    assign dbg_addr_wr   = addr_wr;

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            state       <= ST_IDLE;
            align_left_q <= 2'd0;
            parity_q    <= 1'b0;
            page_q      <= 8'h00;
            oam_base_q  <= 8'h00;
            oam_cur_q   <= 8'h00;
            index_q     <= 8'd0;
            read_addr_q <= 16'h0000;
            data_q      <= 8'h00;
            cycle_cnt_q <= 16'd0;
        end else begin
            parity_q <= ~parity_q;

            if ((state != ST_IDLE) && !last_write)
                cycle_cnt_q <= cycle_cnt_q + 16'd1;

            case (state)
                ST_IDLE: begin
                    if (start) begin
                        page_q      <= src_page;
                        oam_base_q  <= oam_addr;
                        oam_cur_q   <= oam_addr;
                        index_q     <= 8'd0;
                        read_addr_q <= {src_page, 8'h00};
                        data_q      <= 8'h00;
                        align_left_q <= parity_q ? 2'd2 : 2'd1;
                        cycle_cnt_q <= 16'd1;
                        state       <= ST_ALIGN;
                    end
                end

                ST_ALIGN: begin
                    if (align_left_q > 2'd1)
                        align_left_q <= align_left_q - 2'd1;
                    else
                        state <= ST_READ;
                end

                ST_READ: begin
                    if (read_ack) begin
                        data_q      <= cpu_rdata;
                        read_addr_q <= read_addr_q + 16'd1;
                        state       <= ST_WRITE;
                    end
                end

                ST_WRITE: begin
                    oam_cur_q <= (oam_cur_q == 8'hFF) ? 8'h00 : (oam_cur_q + 8'd1);
                    if (index_q == 8'hFF) begin
                        index_q <= 8'd0;
                        state   <= ST_IDLE;
                    end else begin
                        index_q <= index_q + 8'd1;
                        state   <= ST_READ;
                    end
                end

                default: state <= ST_IDLE;
            endcase
        end
    end

endmodule
