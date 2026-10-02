`timescale 1ns/1ps

module nes_cpu_bus #(
    parameter [7:0] READ_WAIT_CYCLES = 8'd0,
    parameter integer RAM_ADDR_BITS = 11,
    parameter RAM_READ_SYNC = 1'b0,
    parameter [7:0] RAM_INIT = 8'h00,
    parameter DMA_PRESENT = 1'b0,
    parameter [7:0] DMA_MMIO_VALUE = 8'h00,
    parameter [7:0] DMC_READ_WAIT_CYCLES = 8'd3
)(
    input wire clk,
    input wire reset,
    input wire ce,
    input wire bus_hold,

    input wire cpu_req,
    input wire cpu_we,
    input wire [15:0] cpu_addr,
    input wire [7:0] cpu_dout,
    output wire [7:0] cpu_din,
    output wire cpu_ready,
    output wire cpu_fire,
    output wire cpu_stall,

    input wire dma_req_oam,
    input wire dma_req_dmc,
    input wire [15:0] dma_addr,
    output wire dma_sel,
    output wire [7:0] dma_din,
    output wire dma_ack,
    output wire dma_wait,
    output wire dma_active,
    output wire dma_unimpl,

    output wire sel_ram,
    output wire sel_ppu,
    output wire sel_apu_io,
    output wire sel_open_bus,
    output wire sel_cart_ram,
    output wire sel_cart_rom,
    output wire [2:0] owner,
    output wire [RAM_ADDR_BITS-1:0] ram_addr,
    output wire ram_we,

    output wire ppu_req,
    output wire ppu_we,
    output wire ppu_wr,
    output wire ppu_xfer,
    output wire [2:0] ppu_addr,
    output wire [7:0] ppu_dout,
    input wire [7:0] ppu_din,
    input wire ppu_ack,

    output wire apu_req,
    output wire apu_we,
    output wire apu_wr,
    output wire apu_xfer,
    output wire [4:0] apu_addr,
    output wire [7:0] apu_dout,
    input wire [7:0] apu_din,
    input wire apu_ack,

    output wire cart_req,
    output wire cart_we,
    output wire cart_wr,
    output wire cart_xfer,
    output wire cart_ram_cs,
    output wire [15:0] cart_addr,
    output wire [7:0] cart_dout,
    input wire [7:0] cart_din,
    input wire cart_ack,

    output wire dbg_active,
    output wire [7:0] dbg_wait_count,
    output wire [7:0] dbg_open_bus,
    output wire [1:0] dbg_dma_owner,
    output wire [7:0] dbg_dma_wait_count
);

localparam [2:0] OWNER_OPEN = 3'd0;
localparam [2:0] OWNER_RAM = 3'd1;
localparam [2:0] OWNER_PPU = 3'd2;
localparam [2:0] OWNER_APU_IO = 3'd3;
localparam [2:0] OWNER_CART_RAM = 3'd4;
localparam [2:0] OWNER_CART_ROM = 3'd5;

localparam [1:0] DMA_OWNER_OAM = 2'd0;
localparam [1:0] DMA_OWNER_DMC = 2'd1;
localparam [1:0] DMA_OWNER_IDLE = 2'd2;

function [2:0] decode_owner;
    input [15:0] addr;
    begin
        case (addr[15:13])
            3'b000: decode_owner = OWNER_RAM;
            3'b001: decode_owner = OWNER_PPU;
            3'b010: decode_owner = (addr[15:5] == 11'b01000000000) ? OWNER_APU_IO : OWNER_OPEN;
            3'b011: decode_owner = OWNER_CART_RAM;
            default: decode_owner = OWNER_CART_ROM;
        endcase
    end
endfunction

reg [7:0] ram_array [0:(1<<RAM_ADDR_BITS)-1];
reg [7:0] ram_q;
reg [7:0] dma_ram_q;
reg [7:0] open_bus_q;
reg active;
reg dma_active_r;
reg [7:0] wait_cnt;
reg [7:0] dma_wait_cnt;

integer init_index;

initial begin
    for (init_index = 0; init_index < (1<<RAM_ADDR_BITS); init_index = init_index + 1)
        ram_array[init_index] = RAM_INIT;
end

reg [2:0] owner_r;
reg [7:0] bus_data_r;

always @* begin
    owner_r = decode_owner(cpu_addr);
end

assign owner = owner_r;
assign sel_ram = (owner_r == OWNER_RAM);
assign sel_ppu = (owner_r == OWNER_PPU);
assign sel_apu_io = (owner_r == OWNER_APU_IO);
assign sel_open_bus = (owner_r == OWNER_OPEN);
assign sel_cart_ram = (owner_r == OWNER_CART_RAM);
assign sel_cart_rom = (owner_r == OWNER_CART_ROM);
assign ram_addr = cpu_addr[RAM_ADDR_BITS-1:0];
assign cart_ram_cs = sel_cart_ram;

wire [2:0] dma_owner;
wire [RAM_ADDR_BITS-1:0] dma_ram_addr;
wire dma_req_present;
wire dma_pick_oam;
wire dma_pick_dmc;
wire dma_grant;
wire dma_ext;
wire dma_ack_src;
wire dma_ready;
wire dma_cart_sel;
wire [7:0] dma_wait_need;
wire [7:0] dma_ram_data;
reg  [7:0] dma_din_r;

assign dma_owner = decode_owner(dma_addr);
assign dma_ram_addr = dma_addr[RAM_ADDR_BITS-1:0];
assign dma_ram_data = RAM_READ_SYNC ? dma_ram_q : ram_array[dma_ram_addr];

assign dma_req_present = DMA_PRESENT && !reset && (dma_req_oam || dma_req_dmc);
assign dma_pick_oam = dma_req_oam;
assign dma_pick_dmc = !dma_req_oam && dma_req_dmc;
assign dma_grant = DMA_PRESENT && !reset && ce && bus_hold &&
                   (dma_pick_oam || dma_pick_dmc);
assign dma_sel = dma_pick_dmc;
assign dma_ext = (dma_owner == OWNER_CART_RAM) || (dma_owner == OWNER_CART_ROM);
assign dma_cart_sel = dma_grant && dma_ext;
assign dma_ack_src = dma_ext ? cart_ack : 1'b1;

// The dma read port's wait is PER REQUEST SOURCE, not per address decode.  An
// oam dma read is a plain read of whatever the page points at, so it keeps the
// decode's wait.  A dmc sample fetch is not a plain read: real hardware holds
// the cpu off the bus for 4 cpu cycles per DMC byte, 1 for the grant plus 3 for
// the fetch, and NESdev's DMC rate table counts those 4 in APU cycles.  Left on
// the shared READ_WAIT_CYCLES it inherits whatever the cpu path happens to be
// configured for, which is a coupling between two different contracts.  The
// number is a parameter so a core can change it without editing this file.
assign dma_wait_need = dma_pick_dmc ? DMC_READ_WAIT_CYCLES :
                       (dma_owner == OWNER_OPEN) ? 8'd0 :
                       (dma_owner == OWNER_RAM) ? (RAM_READ_SYNC ? 8'd1 : 8'd0) :
                       dma_ext ? READ_WAIT_CYCLES : 8'd0;

// NOTE, and this is the reason the cpu port's zero-stall rule is NOT repeated
// here.  That rule (ready_c, below) rests on the cpu presenting its address for
// eleven clk before the edge that completes the access, which is what buys a
// registered read its one clk of lead.  The dma port has no such window: dma_addr
// is muxed against dma_req_oam/dma_req_dmc, so the address and the request
// become valid on the SAME clk, and dma_grant can therefore be true on the very
// first clk the address is up.  A wait of one ce here is therefore the read's
// lead, not a wasted cpu cycle, and dropping it hands the requester the previous
// cell's byte: tb_nes_cpu_bus's "dma ram data on the forced wait config" is what
// catches that.  So this stays at a hard zero.
assign dma_ready = dma_grant &&
                   (dma_active_r ? (dma_wait_cnt == 8'd0) : (dma_wait_need == 8'd0)) &&
                   (!dma_ext || dma_ack_src);
assign dma_ack = dma_grant && dma_ready;
assign dma_wait = dma_req_present && !dma_ack;
assign dma_active = dma_grant && dma_active_r;
assign dma_unimpl = dma_grant &&
                    ((dma_owner == OWNER_PPU) || (dma_owner == OWNER_APU_IO));

always @* begin
    case (dma_owner)
        OWNER_RAM: dma_din_r = dma_ram_data;
        OWNER_CART_RAM, OWNER_CART_ROM: dma_din_r = cart_din;
        OWNER_PPU, OWNER_APU_IO: dma_din_r = DMA_MMIO_VALUE;
        default: dma_din_r = open_bus_q;
    endcase
end

assign dma_din = dma_din_r;

assign ppu_addr = cpu_addr[2:0];
assign ppu_dout = cpu_dout;
assign apu_addr = cpu_addr[4:0];
assign apu_dout = cpu_dout;
assign cart_addr = dma_cart_sel ? dma_addr : cpu_addr;
assign cart_dout = cpu_dout;

wire owner_ext;
wire owner_ack;
wire [7:0] wait_need;

assign owner_ext = (owner_r == OWNER_PPU) || (owner_r == OWNER_APU_IO) ||
                   (owner_r == OWNER_CART_RAM) || (owner_r == OWNER_CART_ROM);

assign owner_ack = (owner_r == OWNER_PPU) ? ppu_ack :
                   (owner_r == OWNER_APU_IO) ? apu_ack :
                   (owner_ext ? cart_ack : 1'b1);

assign wait_need = (owner_r == OWNER_OPEN) ? 8'd0 :
                   (owner_r == OWNER_RAM) ? (RAM_READ_SYNC ? 8'd1 : 8'd0) :
                   READ_WAIT_CYCLES;

wire [7:0] ram_data;

assign ram_data = RAM_READ_SYNC ? ram_q : ram_array[ram_addr];

// The work RAM's read port is FREE RUNNING.  ram_addr is cpu_addr[RAM_ADDR_BITS-1:0]
// and cpu_addr is combinational off the cpu's state register, which only moves on
// bus_fire, so the address is stable for the whole eleven-clk window between the
// edge that created the state and the edge that completes the access.  Issuing
// the read on every clk therefore latches the right byte one clk before it is
// needed, which is exactly the lead a registered read wants, and it costs no cpu
// cycle: the alternative -- arming the read once per request -- is what made
// every access take two ce_cpu beats.  One write port plus one free-running read
// port is the canonical simple-dual-port template, so this is not a new
// inference pattern.  dma_ram_q is deliberately NOT free running: the dma port
// is a separate contract, it has no such eleven-clk guarantee on dma_addr, and
// nothing above depends on it.
always @(posedge clk or posedge reset) begin
    if (reset)
        ram_q <= RAM_INIT;
    else if (RAM_READ_SYNC)
        ram_q <= ram_array[ram_addr];
end

always @* begin
    case (owner_r)
        OWNER_RAM: bus_data_r = ram_data;
        OWNER_PPU: bus_data_r = ppu_din;
        OWNER_APU_IO: bus_data_r = apu_din;
        OWNER_CART_RAM, OWNER_CART_ROM: bus_data_r = cart_din;
        default: bus_data_r = open_bus_q;
    endcase
end

assign cpu_din = bus_data_r;

wire ready_c;
// ce IS the cpu cycle on this port: the v2..v6 cores drive it from a twelve-clk
// div_phase window, three PPU dots wide, so a wait is expressed in ce_cpu units
// and a wait of one beat is NOT a second cpu cycle -- it is this one, already in
// progress.  ready_c therefore treats wait_need <= 1 as free, and the one clk of
// lead a registered read needs comes from the read port below being free
// running rather than from an extra slot.  active/wait_cnt still carry
// wait_need >= 2, so a configuration that really asks for three beats still gets
// three, and one that asks for none still gets none.
assign ready_c = !bus_hold &&
                 ((active ? (wait_cnt == 8'd0) : (wait_need <= 8'd1)) &&
                  (!owner_ext || owner_ack));

assign cpu_ready = ready_c;
assign cpu_fire = cpu_req && ready_c;
assign cpu_stall = cpu_req && !cpu_fire;

assign ram_we = ce && cpu_fire && cpu_we && (owner_r == OWNER_RAM);

assign ppu_req = cpu_req && !bus_hold && (owner_r == OWNER_PPU);
assign ppu_we = ppu_req && cpu_we;
assign ppu_xfer = ce && cpu_fire && (owner_r == OWNER_PPU);
assign ppu_wr = ppu_xfer && cpu_we;

assign apu_req = cpu_req && !bus_hold && (owner_r == OWNER_APU_IO);
assign apu_we = apu_req && cpu_we;
assign apu_xfer = ce && cpu_fire && (owner_r == OWNER_APU_IO);
assign apu_wr = apu_xfer && cpu_we;

assign cart_req = dma_cart_sel ? 1'b1 :
                  (cpu_req && !bus_hold &&
                   ((owner_r == OWNER_CART_RAM) || (owner_r == OWNER_CART_ROM)));
assign cart_we = cart_req && cpu_we;
assign cart_xfer = ce && cpu_fire &&
                   ((owner_r == OWNER_CART_RAM) || (owner_r == OWNER_CART_ROM));
assign cart_wr = cart_xfer && cpu_we;

always @(posedge clk or posedge reset) begin
    if (reset) begin
        active <= 1'b0;
        wait_cnt <= 8'd0;
        open_bus_q <= 8'h00;
        dma_active_r <= 1'b0;
        dma_wait_cnt <= 8'd0;
        dma_ram_q <= RAM_INIT;
    end else if (ce && !bus_hold) begin
        if (cpu_fire) begin
            active <= 1'b0;
            wait_cnt <= 8'd0;
            if (cpu_we) begin
                if (owner_r == OWNER_RAM)
                    ram_array[ram_addr] <= cpu_dout;
                open_bus_q <= cpu_dout;
            end else begin
                open_bus_q <= bus_data_r;
            end
        end else if (cpu_req && !active) begin
            active <= 1'b1;
            wait_cnt <= (wait_need <= 8'd1) ? 8'd0 : (wait_need - 8'd1);
        end else if (!cpu_req && active) begin
            active <= 1'b0;
            wait_cnt <= 8'd0;
        end else if (wait_cnt != 8'd0) begin
            wait_cnt <= wait_cnt - 8'd1;
        end
    end else if (ce) begin
        if (dma_grant && dma_ack) begin
            dma_active_r <= 1'b0;
            dma_wait_cnt <= 8'd0;
            open_bus_q <= dma_din_r;
        end else if (!dma_grant) begin
            dma_active_r <= 1'b0;
            dma_wait_cnt <= 8'd0;
        end else if (!dma_active_r) begin
            dma_active_r <= 1'b1;
            dma_wait_cnt <= (dma_wait_need == 8'd0) ? 8'd0 : (dma_wait_need - 8'd1);
            if (RAM_READ_SYNC && (dma_owner == OWNER_RAM))
                dma_ram_q <= ram_array[dma_ram_addr];
        end else if (dma_wait_cnt != 8'd0) begin
            dma_wait_cnt <= dma_wait_cnt - 8'd1;
        end
    end
end

assign dbg_active = active;
assign dbg_wait_count = wait_cnt;
assign dbg_open_bus = open_bus_q;
assign dbg_dma_owner = !dma_req_present ? DMA_OWNER_IDLE :
                       (dma_req_oam ? DMA_OWNER_OAM : DMA_OWNER_DMC);
assign dbg_dma_wait_count = dma_wait_cnt;

endmodule
