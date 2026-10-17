`timescale 1ns/1ps

// =============================================================================
// nes_cart_load_bridge.v -- move one load byte from the PS clock domain into the
// core clock domain and hand it to nes_cart_rom's load port.
//
// WHY A BRIDGE IS NEEDED AT ALL
//   The PS reaches the PL through M_AXI_GP0 clocked by FCLK_CLK0.  On this board
//   that is 50 MHz, and it is the clock axi_lite_regs runs on.  The cartridge
//   arrays are block RAMs clocked by mmcm_core_clk, 21.477272727 MHz, which the
//   top generates from that same 50 MHz with an MMCM.  The two clocks are
//   related but not equal, so a load strobe cannot simply be run from the AXI
//   domain into a core-domain RAM write port.  A raw crossing of a multi-bit
//   address and data into a RAM write is exactly the kind of unsynchronised
//   crossing the XDC discipline in this project forbids; this module is the
//   crossing, and it is a bundled-data handshake, not a synchroniser on each
//   bit.
//
// THE HANDSHAKE (toggle request, toggle echo)
//   Host side: while idle it asserts host_ready.  On host_valid & host_ready it
//   latches target/address/data, flips req_toggle, and drops host_ready.  It
//   raises host_ready again only after ack_toggle has been synchronised back and
//   equals req_toggle.  AXI is single-outstanding, and axi_lite_regs holds the
//   next byte until ready, so no request is ever missed.
//
//   Core side: req_toggle is synchronised through three flops; the block fires
//   on the edge (req_sync2 != req_sync3), presents one byte to the cartridge for
//   exactly one core clock, and echoes ack_toggle = req_sync2.
//
//   WHY THE BUS IS SAFE.  target/address/data are driven from registers that are
//   loaded on the same edge req_toggle flips and are held until the echo comes
//   back.  The core samples them on an edge at least two core clocks after
//   req_toggle changed, and the echo cannot return before that sampling edge
//   plus the synchroniser latency, so the bundle is stable across the whole
//   window in which the core can observe it.  This is the standard
//   bundled-data-with-toggle-transfer pattern; the toggle carries the timing and
//   the bundle only has to hold still.
//
// ENABLE, AND WHY IT IS CARRIED AND NOT SAMPLED PER BYTE
//   host_load_enable is synchronised to the core domain (two flops) and drives
//   prg_ld_en / chr_ld_en, the cartridge's load enables.  host_load_enable comes
//   from axi_lite_regs' LOAD_EN, which the PS sets before its first data write
//   and clears only after its last, so by the time any request crosses it is
//   stable.  The enable is a slow control level, not a per-byte signal, so a
//   two-flop synchroniser is the right crossing for it.
//
// core_reset IS NOT THE CONSOLE HOLD
//   The console is held in reset for the whole load, and the cartridge's load
//   write is deliberately not gated by its own reset so that it can be written
//   while the console is held.  This bridge's core side must likewise keep
//   running during the hold: core_reset is the CLOCK DOMAIN's reset (MMCM not
//   locked, board reset), not the console hold.  A caller that wires the console
//   hold into core_reset here would deadlock the load.
// =============================================================================

module nes_cart_load_bridge #(
    parameter integer PRG_ADDR_BITS = 17,
    parameter integer CHR_ADDR_BITS = 13,
    // Must be >= max(PRG_ADDR_BITS, CHR_ADDR_BITS); see axi_lite_regs.
    parameter integer ADDR_W = 17
) (
    // ---------------------------------------------------- host (AXI/PS) domain
    input  wire                      host_clk,
    input  wire                      host_reset,
    input  wire                      host_valid,
    input  wire                      host_target,
    input  wire [ADDR_W-1:0]         host_addr,
    input  wire [7:0]                host_data,
    input  wire                      host_load_enable,
    output wire                      host_ready,

    // ----------------------------------------------------------- core domain
    input  wire                      core_clk,
    input  wire                      core_reset,
    output wire                      prg_ld_en,
    output wire [PRG_ADDR_BITS-1:0]  prg_ld_addr,
    output wire [7:0]                prg_ld_data,
    output wire                      prg_ld_we,
    output wire                      chr_ld_en,
    output wire [CHR_ADDR_BITS-1:0]  chr_ld_addr,
    output wire [7:0]                chr_ld_data,
    output wire                      chr_ld_we
);

    // -------------------------------------------------------------- host side
    reg                  host_busy;
    reg                  req_toggle;
    reg                  req_target_q;
    reg [ADDR_W-1:0]     req_addr_q;
    reg [7:0]            req_data_q;
    // ack_toggle is written in the core domain and read here as an asynchronous
    // one-bit level, which is what this two-flop chain is for.
    (* ASYNC_REG = "TRUE" *) reg ack_sync1;
    (* ASYNC_REG = "TRUE" *) reg ack_sync2;

    wire ack_toggle;

    assign host_ready = ~host_busy;

    always @(posedge host_clk) begin
        if (host_reset) begin
            host_busy    <= 1'b0;
            req_toggle   <= 1'b0;
            req_target_q <= 1'b0;
            req_addr_q   <= {ADDR_W{1'b0}};
            req_data_q   <= 8'h00;
            ack_sync1    <= 1'b0;
            ack_sync2    <= 1'b0;
        end else begin
            ack_sync1 <= ack_toggle;
            ack_sync2 <= ack_sync1;
            if (host_valid && ~host_busy) begin
                host_busy    <= 1'b1;
                req_toggle   <= ~req_toggle;
                req_target_q <= host_target;
                req_addr_q   <= host_addr;
                req_data_q   <= host_data;
            end else if (host_busy && (ack_sync2 == req_toggle)) begin
                host_busy    <= 1'b0;
            end
        end
    end

    // -------------------------------------------------------------- core side
    (* ASYNC_REG = "TRUE" *) reg req_sync1;
    (* ASYNC_REG = "TRUE" *) reg req_sync2;
    reg                          req_sync3;
    reg                          ack_toggle_r;

    (* ASYNC_REG = "TRUE" *) reg load_en_s1;
    (* ASYNC_REG = "TRUE" *) reg load_en_s2;

    reg                    prg_ld_en_r;
    reg [PRG_ADDR_BITS-1:0] prg_ld_addr_r;
    reg [7:0]              prg_ld_data_r;
    reg                    prg_ld_we_r;
    reg                    chr_ld_en_r;
    reg [CHR_ADDR_BITS-1:0] chr_ld_addr_r;
    reg [7:0]              chr_ld_data_r;
    reg                    chr_ld_we_r;

    assign ack_toggle = ack_toggle_r;

    always @(posedge core_clk) begin
        if (core_reset) begin
            req_sync1     <= 1'b0;
            req_sync2     <= 1'b0;
            req_sync3     <= 1'b0;
            ack_toggle_r  <= 1'b0;
            load_en_s1    <= 1'b0;
            load_en_s2    <= 1'b0;
            prg_ld_en_r   <= 1'b0;
            prg_ld_addr_r <= {PRG_ADDR_BITS{1'b0}};
            prg_ld_data_r <= 8'h00;
            prg_ld_we_r   <= 1'b0;
            chr_ld_en_r   <= 1'b0;
            chr_ld_addr_r <= {CHR_ADDR_BITS{1'b0}};
            chr_ld_data_r <= 8'h00;
            chr_ld_we_r   <= 1'b0;
        end else begin
            req_sync1 <= req_toggle;
            req_sync2 <= req_sync1;
            req_sync3 <= req_sync2;
            load_en_s1 <= host_load_enable;
            load_en_s2 <= load_en_s1;

            // One-cycle strobes; re-asserted below on a request edge only.
            prg_ld_we_r <= 1'b0;
            chr_ld_we_r <= 1'b0;
            prg_ld_en_r <= load_en_s2;
            chr_ld_en_r <= load_en_s2;

            if (req_sync2 != req_sync3) begin
                // A request edge.  The bundle is stable; take it if the enable is
                // up, then echo the toggle.  If the enable is down the byte is
                // dropped AND still acknowledged, so the host never hangs.
                if (load_en_s2) begin
                    if (req_target_q == 1'b0) begin
                        prg_ld_addr_r <= req_addr_q[PRG_ADDR_BITS-1:0];
                        prg_ld_data_r <= req_data_q;
                        prg_ld_we_r   <= 1'b1;
                    end else begin
                        chr_ld_addr_r <= req_addr_q[CHR_ADDR_BITS-1:0];
                        chr_ld_data_r <= req_data_q;
                        chr_ld_we_r   <= 1'b1;
                    end
                end
                ack_toggle_r <= req_sync2;
            end
        end
    end

    assign prg_ld_en   = prg_ld_en_r;
    assign prg_ld_addr = prg_ld_addr_r;
    assign prg_ld_data = prg_ld_data_r;
    assign prg_ld_we   = prg_ld_we_r;
    assign chr_ld_en   = chr_ld_en_r;
    assign chr_ld_addr = chr_ld_addr_r;
    assign chr_ld_data = chr_ld_data_r;
    assign chr_ld_we   = chr_ld_we_r;

endmodule
