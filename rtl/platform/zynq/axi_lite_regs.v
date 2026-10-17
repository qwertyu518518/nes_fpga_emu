`timescale 1ns/1ps

// =============================================================================
// axi_lite_regs.v -- the PS-facing register bank and cartridge load source.
//
// PROVENANCE
//   Written from the ARM AMBA AXI4-Lite specification, not adapted from any
//   vendor source file.  The channel skeleton (five channels, single-outstanding
//   AW/W/AR/R, BRESP/RRESP = OKAY on every response, WSTRB honoured per byte
//   lane) is the shape a first PS probe needed to replace a
//   smartconnect + axi_gpio pair that cost 2,013 LUT / 2,539 FF for a one-to-one
//   register bank.  That hand-written slave measured 99 LUT / 267 FF.  This file
//   is the repository's copy of it, extended with the cartridge load registers.
//
// WHAT IT IS
//   A small AXI4-Lite register bank the Cortex-A9 reaches through M_AXI_GP0.
//   The PS M_AXI_GP0 is AXI3, so a Xilinx axi_protocol_converter (AXI3 -> AXI4-
//   Lite) is required in front of it; that converter is a primitive instantiated
//   in the block design, not vendor reference code copied into this repository.
//
// REGISTER MAP (32-bit, word addressed, offset = addr[4:2])
//   0x00  CTRL      RW  bit0 LOAD_EN, bit1 HOLD.  See CONSOLE HOLD below.
//   0x04  SCRATCH   RW  general scratch; write/read-back proves the link.
//   0x08  STATUS    RO  {24'b0, pl_status_in[7:0]}.
//   0x0C  ID        RO  0x4E455301 ("NES" + revision 1).  A constant the PS can
//                       read to prove it is talking to THIS slave.
//   0x10  PRG_ADDR  RW  byte address into the PRG array, low PRG_ADDR_BITS bits.
//   0x14  PRG_DATA  WO  one AXI word of PRG bytes; auto-increments PRG_ADDR.
//   0x18  CHR_ADDR  RW  byte address into the CHR array.
//   0x1C  CHR_DATA  WO  one AXI word of CHR bytes; auto-increments CHR_ADDR.
//   Writes to a RO register are decoded and acknowledged (OKAY) and dropped,
//   which is legal for a read-only register.
//
// THE LOAD PATH, AND WHY THE ARRAYS STAY BYTE-WIDE
//   The cartridge arrays are 8 bits wide.  A 32-bit load port into a byte-wide
//   block RAM is not a shape the primitive can take: it would mean four
//   simultaneous writes to four consecutive array words on one clock, which
//   either builds four byte-wide RAMs or fails to map to RAM at all.  So one
//   PRG_DATA / CHR_DATA write is expanded here into UP TO FOUR byte writes, one
//   per set WSTRB lane, one byte per core clock, each handed across the clock
//   domain by nes_cart_load_bridge.  Lane k writes array address (ADDR + k) with
//   data[8k +: 8], and ADDR advances by 4 when the last set lane has been handed
//   off.  A full word stream therefore loads a cartridge at four bytes per AXI
//   transaction; a byte-at-a-time writer sets WSTRB = 4'b0001 and steps in
//   multiples of four.
//
//   The hand-off is a valid/ready handshake on pl_ld_valid / pl_ld_ready.  A
//   PRG_DATA write is NOT acknowledged with BVALID until every strobed byte has
//   been accepted, and awready/wready are held low while a word is in flight, so
//   the single-outstanding write can never outrun the load.  pl_ld_ready comes
//   from the bridge; a caller with no bridge may tie it high.
//
// INERT UNLESS ENABLED
//   ctrl[0] (LOAD_EN) gates the load path THREE times over: a load-data write is
//   only turned into a request when LOAD_EN is set; the bridge only forwards a
//   request while the synchronized enable is high; and the cartridge itself only
//   writes while its load enable is high.  With LOAD_EN clear a PRG_DATA or
//   CHR_DATA write is acknowledged and dropped, exactly like a RO register, and
//   nothing reaches either array.
//
// CONSOLE HOLD (why a partial image cannot be executed)
//   pl_console_hold = ctrl[1] | ctrl[0].  LOAD_EN IMPLIES HOLD: the same bit that
//   lets bytes reach the arrays also asserts the console hold, so the CPU and
//   PPU are held in reset for the entire load and cannot fetch, execute, or
//   perform a $2007 store.  The only way to release the console is to clear
//   LOAD_EN (and HOLD), which can only be a deliberate "the image is complete"
//   write.  A partially-loaded image therefore cannot be executed by
//   construction: execution requires the very bit whose presence permits writes.
//   ctrl[1] lets the PS additionally stop a running console before it starts a
//   load, if it ever wants to load over a live one.
// =============================================================================

module axi_lite_regs #(
    parameter integer C_S_AXI_DATA_WIDTH = 32,
    parameter integer C_S_AXI_ADDR_WIDTH = 5,
    parameter integer PRG_ADDR_BITS = 17,
    parameter integer CHR_ADDR_BITS = 13,
    // Must be >= max(PRG_ADDR_BITS, CHR_ADDR_BITS).  A parameter rather than a
    // localparam because the ANSI port list below is elaborated before the body.
    parameter integer ADDR_W = 17
) (
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 ACLK CLK" *)
    (* X_INTERFACE_PARAMETER = "ASSOCIATED_BUSIF S_AXI, ASSOCIATED_RESET aresetn, FREQ_HZ 50000000" *)
    input  wire                          s_axi_aclk,
    (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 ARESETN RST" *)
    (* X_INTERFACE_PARAMETER = "POLARITY ACTIVE_LOW" *)
    input  wire                          s_axi_aresetn,

    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI AWADDR" *)
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME S_AXI, DATA_WIDTH 32, PROTOCOL AXI4LITE, FREQ_HZ 50000000, ID_WIDTH 0, ADDR_WIDTH 5, AWUSER_WIDTH 0, ARUSER_WIDTH 0, WUSER_WIDTH 0, RUSER_WIDTH 0, BUSER_WIDTH 0, READ_WRITE_MODE READ_WRITE, HAS_BURST 0, HAS_LOCK 0, HAS_PROT 0, HAS_CACHE 0, HAS_QOS 0, HAS_REGION 0, HAS_WSTRB 1, HAS_BRESP 1, HAS_RRESP 1, SUPPORTS_NARROW_BURST 0, NUM_READ_OUTSTANDING 1, NUM_WRITE_OUTSTANDING 1, MAX_BURST_LENGTH 1, PHASE 0.000, NUM_READ_THREADS 1, NUM_WRITE_THREADS 1, RUSER_BITS_PER_BYTE 0, WUSER_BITS_PER_BYTE 0" *)
    input  wire [C_S_AXI_ADDR_WIDTH-1:0] s_axi_awaddr,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI AWPROT" *)
    input  wire [2:0]                    s_axi_awprot,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI AWVALID" *)
    input  wire                          s_axi_awvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI AWREADY" *)
    output wire                          s_axi_awready,

    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI WDATA" *)
    input  wire [C_S_AXI_DATA_WIDTH-1:0] s_axi_wdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI WSTRB" *)
    input  wire [C_S_AXI_DATA_WIDTH/8-1:0] s_axi_wstrb,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI WVALID" *)
    input  wire                          s_axi_wvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI WREADY" *)
    output wire                          s_axi_wready,

    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI BRESP" *)
    output reg  [1:0]                    s_axi_bresp,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI BVALID" *)
    output reg                           s_axi_bvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI BREADY" *)
    input  wire                          s_axi_bready,

    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI ARADDR" *)
    input  wire [C_S_AXI_ADDR_WIDTH-1:0] s_axi_araddr,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI ARPROT" *)
    input  wire [2:0]                    s_axi_arprot,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI ARVALID" *)
    input  wire                          s_axi_arvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI ARREADY" *)
    output wire                          s_axi_arready,

    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI RDATA" *)
    output reg  [C_S_AXI_DATA_WIDTH-1:0] s_axi_rdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI RRESP" *)
    output reg  [1:0]                    s_axi_rresp,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI RVALID" *)
    output reg                           s_axi_rvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI RREADY" *)
    input  wire                          s_axi_rready,

    // Functional, PL-facing ports (plain signals, not an AXI interface).
    output wire                          pl_console_hold,
    output wire                          pl_load_enable,
    output wire                          pl_ld_valid,
    output wire                          pl_ld_target,
    output wire [ADDR_W-1:0]             pl_ld_addr,
    output wire [7:0]                    pl_ld_data,
    input  wire                          pl_ld_ready,
    input  wire [7:0]                    pl_status_in
);

    // ---------------------------------------------------------------- registers
    reg [31:0]               reg_ctrl;
    reg [31:0]               reg_scratch;
    reg [PRG_ADDR_BITS-1:0]  prg_addr_reg;
    reg [CHR_ADDR_BITS-1:0]  chr_addr_reg;

    assign pl_load_enable  = reg_ctrl[0];
    assign pl_console_hold = reg_ctrl[1] | reg_ctrl[0];

    // ------------------------------------------------------------ write channel
    reg                            aw_seen;
    reg                            w_seen;
    reg [C_S_AXI_ADDR_WIDTH-1:0]   awaddr_q;
    reg [C_S_AXI_DATA_WIDTH-1:0]   wdata_q;
    reg [C_S_AXI_DATA_WIDTH/8-1:0] wstrb_q;

    // One load word in flight: address, data, strobes, the lane cursor and the
    // target.  While this is set the write channel is closed, so there is still
    // never more than one write outstanding.
    reg                  ld_pending;
    reg                  ld_target;
    reg [ADDR_W-1:0]     ld_base;
    reg [31:0]           ld_wdata;
    reg [3:0]            ld_strb;
    reg [1:0]            ld_lane;

    // Accept AW and W independently, hold them, then commit one response.  Both
    // readys are low while a response is outstanding or a load word is in flight.
    assign s_axi_awready = ~aw_seen & ~s_axi_bvalid & ~ld_pending;
    assign s_axi_wready  = ~w_seen  & ~s_axi_bvalid & ~ld_pending;

    wire aw_fire = s_axi_awready & s_axi_awvalid;
    wire w_fire  = s_axi_wready  & s_axi_wvalid;
    // Commit only once BOTH channels have been captured in the registers, i.e.
    // the cycle after the last of the two fires.  Committing on the same cycle
    // both fire would apply the OLD wdata_q/awaddr_q, because a nonblocking
    // assignment inside the same always block does not take effect until the
    // following cycle.  The first probe's slave committed on `new_aw & new_w`;
    // that was invisible there because its master never presented AW and W in
    // the same cycle, and it is caught here because this bench does.
    wire commit  = aw_seen & w_seen & ~s_axi_bvalid & ~ld_pending;

    wire [2:0] waddr_sel  = awaddr_q[4:2];
    wire       is_ld_reg  = (waddr_sel == 3'd5) | (waddr_sel == 3'd7);
    wire       start_load = commit & is_ld_reg & reg_ctrl[0] & (|wstrb_q);

    function [31:0] apply_strb;
        input [31:0] old_v;
        input [31:0] new_v;
        input [3:0]  strb;
        begin
            apply_strb[7:0]   = strb[0] ? new_v[7:0]   : old_v[7:0];
            apply_strb[15:8]  = strb[1] ? new_v[15:8]  : old_v[15:8];
            apply_strb[23:16] = strb[2] ? new_v[23:16] : old_v[23:16];
            apply_strb[31:24] = strb[3] ? new_v[31:24] : old_v[31:24];
        end
    endfunction

    // Lowest set WSTRB lane at or above the cursor.  The loop runs 3 down to 0 and
    // the last assignment wins, so the selected lane is the lowest still to do.
    reg       ld_sel_valid;
    reg [1:0] ld_sel_lane;
    integer   li;

    always @(*) begin
        ld_sel_valid = 1'b0;
        ld_sel_lane  = 2'd0;
        for (li = 3; li >= 0; li = li - 1) begin
            if (ld_strb[li] && (li[1:0] >= ld_lane)) begin
                ld_sel_valid = 1'b1;
                ld_sel_lane  = li[1:0];
            end
        end
    end

    reg [7:0] ld_sel_data;
    always @(*) begin
        case (ld_sel_lane)
            2'd0:    ld_sel_data = ld_wdata[7:0];
            2'd1:    ld_sel_data = ld_wdata[15:8];
            2'd2:    ld_sel_data = ld_wdata[23:16];
            2'd3:    ld_sel_data = ld_wdata[31:24];
            default: ld_sel_data = 8'h00;
        endcase
    end

    assign pl_ld_valid  = ld_pending & ld_sel_valid;
    assign pl_ld_target = ld_target;
    assign pl_ld_addr   = ld_base + ld_sel_lane;
    assign pl_ld_data   = ld_sel_data;

    wire ld_fire = pl_ld_valid & pl_ld_ready;

    always @(posedge s_axi_aclk) begin
        if (!s_axi_aresetn) begin
            aw_seen      <= 1'b0;
            w_seen       <= 1'b0;
            awaddr_q     <= {C_S_AXI_ADDR_WIDTH{1'b0}};
            wdata_q      <= {C_S_AXI_DATA_WIDTH{1'b0}};
            wstrb_q      <= {C_S_AXI_DATA_WIDTH/8{1'b0}};
            s_axi_bvalid <= 1'b0;
            s_axi_bresp  <= 2'b00;
            reg_ctrl     <= 32'h00000000;
            reg_scratch  <= 32'h00000000;
            prg_addr_reg <= {PRG_ADDR_BITS{1'b0}};
            chr_addr_reg <= {CHR_ADDR_BITS{1'b0}};
            ld_pending   <= 1'b0;
            ld_target    <= 1'b0;
            ld_base      <= {ADDR_W{1'b0}};
            ld_wdata     <= 32'h00000000;
            ld_strb      <= 4'h0;
            ld_lane      <= 2'd0;
        end else begin
            if (aw_fire) begin
                aw_seen  <= 1'b1;
                awaddr_q <= s_axi_awaddr;
            end
            if (w_fire) begin
                w_seen  <= 1'b1;
                wdata_q <= s_axi_wdata;
                wstrb_q <= s_axi_wstrb;
            end

            if (commit) begin
                aw_seen <= 1'b0;
                w_seen  <= 1'b0;
                if (start_load) begin
                    // Open a load word; the response waits until it has drained.
                    ld_pending <= 1'b1;
                    ld_target  <= (waddr_sel == 3'd7);
                    ld_base    <= (waddr_sel == 3'd7) ? chr_addr_reg : prg_addr_reg;
                    ld_wdata   <= wdata_q;
                    ld_strb    <= wstrb_q;
                    ld_lane    <= 2'd0;
                end else begin
                    s_axi_bvalid <= 1'b1;
                    s_axi_bresp  <= 2'b00;
                    case (waddr_sel)
                        3'd0:    reg_ctrl     <= apply_strb(reg_ctrl,    wdata_q, wstrb_q);
                        3'd1:    reg_scratch  <= apply_strb(reg_scratch, wdata_q, wstrb_q);
                        3'd2:    ; // status, read only
                        3'd3:    ; // id, read only
                        3'd4:    prg_addr_reg <= wdata_q[PRG_ADDR_BITS-1:0];
                        3'd5:    ; // PRG_DATA with LOAD_EN low, or WSTRB 0: dropped
                        3'd6:    chr_addr_reg <= wdata_q[CHR_ADDR_BITS-1:0];
                        3'd7:    ; // CHR_DATA with LOAD_EN low, or WSTRB 0: dropped
                        default: ;
                    endcase
                end
            end else if (ld_pending) begin
                if (ld_fire) begin
                    ld_lane <= ld_sel_lane + 2'd1;
                    if (ld_sel_lane == 2'd3) begin
                        ld_pending   <= 1'b0;
                        s_axi_bvalid <= 1'b1;
                        s_axi_bresp  <= 2'b00;
                        if (ld_target)
                            chr_addr_reg <= chr_addr_reg + 4;
                        else
                            prg_addr_reg <= prg_addr_reg + 4;
                    end
                end else if (!ld_sel_valid) begin
                    ld_pending   <= 1'b0;
                    s_axi_bvalid <= 1'b1;
                    s_axi_bresp  <= 2'b00;
                    if (ld_target)
                        chr_addr_reg <= chr_addr_reg + 4;
                    else
                        prg_addr_reg <= prg_addr_reg + 4;
                end
            end

            if (s_axi_bvalid & s_axi_bready)
                s_axi_bvalid <= 1'b0;
        end
    end

    // ------------------------------------------------------------- read channel
    reg [C_S_AXI_DATA_WIDTH-1:0] rdata_n;

    always @(*) begin
        case (s_axi_araddr[4:2])
            3'd0:    rdata_n = reg_ctrl;
            3'd1:    rdata_n = reg_scratch;
            3'd2:    rdata_n = {24'b0, pl_status_in};
            3'd3:    rdata_n = 32'h4E455301;
            3'd4:    rdata_n = {{(32-PRG_ADDR_BITS){1'b0}}, prg_addr_reg};
            3'd5:    rdata_n = 32'h00000000;
            3'd6:    rdata_n = {{(32-CHR_ADDR_BITS){1'b0}}, chr_addr_reg};
            3'd7:    rdata_n = 32'h00000000;
            default: rdata_n = 32'hDEADBEEF;
        endcase
    end

    // One read outstanding: arready is low while RVALID is set.
    assign s_axi_arready = ~s_axi_rvalid;

    always @(posedge s_axi_aclk) begin
        if (!s_axi_aresetn) begin
            s_axi_rvalid <= 1'b0;
            s_axi_rdata  <= {C_S_AXI_DATA_WIDTH{1'b0}};
            s_axi_rresp  <= 2'b00;
        end else begin
            if (s_axi_arready & s_axi_arvalid) begin
                s_axi_rvalid <= 1'b1;
                s_axi_rdata  <= rdata_n;
                s_axi_rresp  <= 2'b00;
            end else if (s_axi_rvalid & s_axi_rready) begin
                s_axi_rvalid <= 1'b0;
            end
        end
    end

    // Prot is accepted but not decoded: this bank has no privileged regions.
    wire _unused_prot = &{1'b0, s_axi_awprot, s_axi_arprot};

endmodule
