`timescale 1ns/1ps

// tb_nes_system_v6_uxrom_prg : the one thing neither tb_nes_system_v6 nor
// tb_nes_system_v5 can say about the BRAM PRG.
//
// WHY THIS BENCH EXISTS
//   nes_system_v6 now answers its PRG reads out of nes_cart_rom, whose read is
//   REGISTERED, so prg_readback carries the byte for mapper_prg_bank_offset as
//   it was on the PREVIOUS clk rather than the present one.  prg_readback has
//   exactly two consumers in the whole design -- nes_mapper_uxrom and
//   nes_mapper_cnrom, which AND cpu_dout against it and report bus_conflict
//   from it -- and mapper_we is the registered cart_wr_pending_q, so the
//   compare is evaluated exactly on the clk where a one-clk skew could bite.
//
//   tb_nes_system_v5 DOES exercise UxROM conflict mode 1 ("the two 00 writes AND
//   against a live prg_readback and hold bank 0, the 43 and 45 writes latch bank
//   5"), but it instantiates nes_system_v5, whose prg_rom is a flat
//   combinational array inside the core and which this change did not touch.
//   tb_nes_system_v6 instantiates four nes_system_v6 cores with MAPPER_SELECT 0,
//   0, 0 and 4 -- NROM and MMC3, neither of which even has a prg_readback port
//   on its mapper submodule.  So after this change the UxROM/CNROM compare
//   against a REGISTERED prg_readback was covered by nothing.  This bench
//   closes exactly that hole and nothing else.
//
// WHAT IS MEASURED, NOT ASSUMED
//   1. On the clk of every mapper write pulse, prg_readback is compared with the
//      byte the testbench's OWN bank model says sits at the write address in the
//      bank current BEFORE the write lands.  That is the assertion a one-clk
//      stale byte would have broken.  The model is built from the mapper's
//      exported write_addr and write_data plus its own model_bank register; it
//      never consults the dut's bank register to decide what the byte is.
//   2. mapper_prg_bank_offset is compared with the same model's offset on those
//      clks, so a wrong byte cannot be excused by a wrong address.
//   3. mapper_bus_conflict is compared with (model byte != write data), i.e.
//      against the testbench's own arithmetic and not against the same
//      prg_readback the DUT itself compared.
//   4. mapper_prg_bank_offset[16:14] is compared with model_bank on EVERY clk,
//      not only on writes, and model_bank advances only from the testbench's
//      own latched_data arithmetic.  A bank that moved without a write, or a
//      write whose effect was wrong, both fail.
//   5. Every PRG read is compared: cart_din and bus_din against tb_prg at the
//      offset the testbench model computes, and against the testbench's own
//      UxROM window decode.  Nothing here reads the dut's memory.
//   6. The program's own read-back markers are checked against HARD-CODED
//      expectations, so the model is not the only thing being confirmed.
//
// NON-VACUITY
//   The seven bank writes are built so that two are conflict free and five
//   genuinely conflict, and they drive banks 0 3 4 2 5 0 1 6, so a byte from the
//   previous bank is a different value rather than a plausible one.  Both
//   conflict counts are asserted.  The last write goes to $FF00 inside the fixed
//   last window, so the cpu_addr[14] branch of nes_mapper_uxrom.v:42 is measured
//   and not only the banked branch.
//
// The program lives in the FIXED LAST WINDOW ($C000-$FFFF -> tb_prg[0x1C000..])
// because a UxROM program in a banked window vanishes the moment it changes
// bank, which is exactly why real UxROM titles put their code at $C000.

module tb_nes_system_v6_uxrom_prg;

localparam integer PRG_BYTES   = 131072;
localparam integer PRG_BITS    = 17;
localparam integer CHR_BITS    = 17;
localparam integer BANK_BYTES  = 16384;
localparam integer LAST_BANK   = (PRG_BYTES / BANK_BYTES) - 1;
localparam integer FIXED_BASE  = LAST_BANK * BANK_BYTES;

// Byte the cartridge answers with at CPU $8000 in bank b, and the marker at
// CPU $8100 in bank b.  Both are bank dependent, which is what makes a stale
// byte from the wrong bank visible instead of plausible.
localparam [7:0] CONFLICT_BASE = 8'h83;
localparam [7:0] MARKER_BASE   = 8'h40;

localparam [15:0] SELF_ADDR = 16'hC05B;
localparam [15:0] DONE_CELL = 16'h022F;

reg clk;
reg reset;
reg done;

wire        ce_ppu;
wire [7:0]  chr_rdata;

wire [15:0] ux_bus_addr;
wire        ux_bus_we;
wire [7:0]  ux_bus_din;
wire [7:0]  ux_bus_dout;
wire        ux_bus_req;
wire        ux_bus_fire;
wire [7:0]  ux_cart_din;
wire        ux_sel_cart_rom;
wire        ux_sel_ram;
wire [7:0]  ux_prg_readback;
wire        ux_mapper_write_pulse;
wire [15:0] ux_mapper_write_addr;
wire [7:0]  ux_mapper_write_data;
wire [PRG_BITS-1:0] ux_mapper_prg_bank_offset;
wire [2:0]  ux_mapper_id;
wire        ux_mapper_bus_conflict;
wire        ux_chr_req;
wire [CHR_BITS-1:0] ux_chr_final_addr;

reg [7:0] tb_prg    [0:PRG_BYTES-1];
reg [7:0] chr_mem   [0:8191];
reg [7:0] chr_rdata_q;
reg [7:0] ram_shadow[0:2047];

reg [3:0] model_bank;
wire [PRG_BITS-1:0] model_offset;
wire [7:0]          model_byte;
wire [7:0]          model_latched;
wire                model_conflict;

integer prg_read_count;
integer pulse_count;
integer conflict_count;
integer no_conflict_count;
integer pulse_byte_err;
integer pulse_off_err;
integer conflict_flag_err;
integer bank_err;
integer read_err;
integer pulse_clk_count;

assign chr_rdata = chr_rdata_q;

// ce_ppu is the core's own 3-of-4 enable: high at div_phase 0, 4 and 8.
assign ce_ppu = !reset && (ux.div_phase[1:0] == 2'b00);

// UxROM decode, rebuilt here from nes_mapper_uxrom.v:42-46 so the expectation
// does not come out of the rtl it is checking.
assign model_offset = ux_mapper_write_addr[14]
                    ? (FIXED_BASE + ux_mapper_write_addr[13:0])
                    : ((model_bank * BANK_BYTES) + ux_mapper_write_addr[13:0]);

assign model_byte     = tb_prg[model_offset];
assign model_latched  = ux_mapper_write_data & model_byte;
assign model_conflict = (model_byte != ux_mapper_write_data);

always #23 clk = ~clk;

nes_system_v6 #(
    .PRG_SIZE_BYTES(PRG_BYTES),
    .PRG_ADDR_BITS(PRG_BITS),
    .MAPPER_SELECT(8'd2),
    .UxROM_BANK_BITS(4),
    .UxROM_BUS_CONFLICT(2'd1),
    .HEADER_MIRRORING(3'd0),
    .NROM_CHR_RAM(1'b1)
) ux (
    .clk(clk),
    .reset(reset),
    .buttons1(8'h00),
    .buttons2(8'h00),
    .chr_rdata(chr_rdata),
    .pixel_valid(),
    .pixel_x(),
    .pixel_y(),
    .pixel_index(),
    .frame_done(),
    .vblank(),
    .nmi_o(),
    .apu_irq_o(),
    .audio_sample_valid(),
    .audio_sample_left(),
    .audio_sample_right(),
    .cpu_cycle(),
    .ppu_dot(),
    .ppu_scanline(),
    .bus_owner(),
    .bus_active(),
    .bus_wait_count(),
    .bus_req(ux_bus_req),
    .bus_stall(),
    .bus_fire(ux_bus_fire),
    .bus_addr(ux_bus_addr),
    .bus_we(ux_bus_we),
    .bus_dout(ux_bus_dout),
    .bus_din(ux_bus_din),
    .sel_ram(ux_sel_ram),
    .sel_ppu(),
    .sel_apu_io(),
    .sel_open_bus(),
    .sel_cart_ram(),
    .sel_cart_rom(ux_sel_cart_rom),
    .ram_we(),
    .ppu_reg_cs(),
    .ppu_reg_we(),
    .ppu_reg_addr(),
    .apu_reg_cs(),
    .apu_reg_we(),
    .apu_reg_addr(),
    .controller_data(),
    .cart_req(),
    .cart_xfer(),
    .cart_addr(),
    .cart_din(ux_cart_din),
    .cart_ack(),
    .bus_hold(),
    .oam_dma_start(),
    .oam_dma_cpu_hold(),
    .oam_dma_cpu_read_req(),
    .oam_dma_cpu_read_addr(),
    .oam_dma_cpu_read_ack(),
    .oam_dma_cpu_rdata(),
    .oam_dma_ppu_reg_cs(),
    .oam_dma_ppu_reg_we(),
    .oam_dma_ppu_reg_addr(),
    .oam_dma_ppu_reg_dout(),
    .oam_dma_busy(),
    .oam_dma_done(),
    .oam_dma_page(),
    .oam_dma_page_latch(),
    .oam_dma_base_addr(),
    .oam_dma_cur_addr(),
    .oam_dma_index(),
    .oam_dma_align_left(),
    .oam_dma_addr_wr(),
    .oam_dma_cycle_count(),
    .apu_dmc_bus_req(),
    .apu_dmc_addr(),
    .apu_dmc_ack(),
    .apu_dmc_rdata(),
    .dma_sel(),
    .dma_ack(),
    .dma_din(),
    .dma_wait(),
    .dma_active(),
    .dma_unimpl(),
    .dma_owner(),
    .ppu_port_cs(),
    .ppu_port_we(),
    .ppu_port_addr(),
    .ppu_port_din(),
    .mapper_id(ux_mapper_id),
    .mapper_prg_bank_offset(ux_mapper_prg_bank_offset),
    .mapper_chr_bank_offset(),
    .mapper_mirroring(),
    .mapper_nametable_map(),
    .mapper_prg_bank_number(),
    .mapper_prg_ram_enable(),
    .mapper_prg_ram_we(),
    .mapper_chr_ram_enable(),
    .mapper_chr_ram_we(),
    .mapper_bus_conflict(ux_mapper_bus_conflict),
    .mapper_irq(),
    .irq_line(),
    .mapper_write_pulse(ux_mapper_write_pulse),
    .mapper_write_addr(ux_mapper_write_addr),
    .mapper_write_data(ux_mapper_write_data),
    .prg_readback(ux_prg_readback),
    .chr_waddr(),
    .chr_we(),
    .chr_wdata(),
    .chr_req(ux_chr_req),
    .chr_final_addr(ux_chr_final_addr)
);

// The external CHR responder.  Registered on the ce_ppu edge, which is the
// contract nes_cart_rom.v documents: the address is on the bus at div_phase 8,
// the byte is latched on that same edge, and the PPU consumes it five clk later.
always @(posedge clk) begin
    if (reset)
        chr_rdata_q <= 8'h00;
    else if (ce_ppu && ux_chr_req)
        chr_rdata_q <= chr_mem[ux_chr_final_addr[12:0]];
end

integer exp_read_off;
integer exp_offset;
integer i;
integer eff_addr;

initial begin
    clk = 1'b0;
    reset = 1'b1;
    done = 1'b0;
    prg_read_count = 0;
    pulse_count = 0;
    conflict_count = 0;
    no_conflict_count = 0;
    pulse_byte_err = 0;
    pulse_off_err = 0;
    conflict_flag_err = 0;
    bank_err = 0;
    read_err = 0;
    pulse_clk_count = 0;
    model_bank = 4'd0;
    exp_read_off = 0;
end

// THE MEASUREMENT.  An always @(posedge clk) reads pre-edge values, and
// cart_wr_pending_q is exactly one clk wide (cart_xfer is ce gated), so the
// pre-edge value on the clk where mapper_write_pulse is high IS the clk on which
// nes_mapper_uxrom evaluates latched_data and bus_conflict.
always @(posedge clk) begin
    if (reset) begin
        model_bank <= 4'd0;
    end else begin
        // The model bank register advances on the same clk the rtl's bank_select
        // does, from the same arithmetic, both using the pre-edge bank.  Neither
        // one peeks at the other.
        if (ux_mapper_write_pulse) begin
            pulse_count = pulse_count + 1;
            pulse_clk_count = pulse_clk_count + 1;
            if (pulse_clk_count !== 1)
                $fatal(1, "mapper write pulse %0d was %0d clk wide, expected exactly 1",
                       pulse_count, pulse_clk_count);
            if (pulse_count > 7)
                $fatal(1, "mapper write pulse %0d, the program issues only 7 bank writes",
                       pulse_count);
            if (model_conflict) conflict_count = conflict_count + 1;
            else                no_conflict_count = no_conflict_count + 1;

            // (1) the byte the AND and the conflict flag were evaluated against
            if (ux_prg_readback !== model_byte) begin
                pulse_byte_err = pulse_byte_err + 1;
                if (pulse_byte_err < 6)
                    $display("PULSE-BYTE write %0d addr=%04h data=%02h: prg_readback=%02h, the tb model byte for pre-write bank %0d at offset %05h is %02h",
                             pulse_count, ux_mapper_write_addr, ux_mapper_write_data,
                             ux_prg_readback, model_bank, model_offset, model_byte);
            end
            // (2) the address that byte was fetched with
            if (ux_mapper_prg_bank_offset !== model_offset) begin
                pulse_off_err = pulse_off_err + 1;
                if (pulse_off_err < 6)
                    $display("PULSE-ADDR write %0d addr=%04h: mapper_prg_bank_offset=%05h, tb model %05h",
                             pulse_count, ux_mapper_write_addr,
                             ux_mapper_prg_bank_offset, model_offset);
            end
            // (3) the flag, against the tb's own arithmetic and NOT against the
            // dut's own prg_readback
            if (ux_mapper_bus_conflict !== model_conflict) begin
                conflict_flag_err = conflict_flag_err + 1;
                if (conflict_flag_err < 6)
                    $display("PULSE-FLAG write %0d addr=%04h data=%02h: mapper_bus_conflict=%b, tb model %b (model byte %02h)",
                             pulse_count, ux_mapper_write_addr, ux_mapper_write_data,
                             ux_mapper_bus_conflict, model_conflict, model_byte);
            end

            model_bank <= model_latched[3:0];
        end else begin
            pulse_clk_count = 0;
        end

        // (4) the whole offset, on every clk, not only on writes.  The effective
        // address is the mapper's own source: its latched write address while the
        // pulse is up, the cpu address otherwise.  The banked branch is then held
        // to the tb's model_bank and the fixed branch to LAST_BANK, so a bank
        // that moved without a write, or a write whose effect differed, both
        // fail -- and the fixed window is not mistaken for a bank change.
        eff_addr = ux_mapper_write_pulse ? ux_mapper_write_addr : ux_bus_addr;
        exp_offset = eff_addr[14]
                   ? (FIXED_BASE + eff_addr[13:0])
                   : ((model_bank * BANK_BYTES) + eff_addr[13:0]);
        if (ux_mapper_prg_bank_offset !== exp_offset) begin
            bank_err = bank_err + 1;
            if (bank_err < 6)
                $display("BANK dut offset=%05h, tb model %05h (addr=%04h, tb model bank=%0d, fixed branch=%b)",
                         ux_mapper_prg_bank_offset, exp_offset, eff_addr, model_bank,
                         eff_addr[14]);
        end

        // (5) every PRG read, against the tb's own image and window decode
        if (ux_bus_req && ux_bus_fire && ux_sel_cart_rom && !ux_bus_we) begin
            prg_read_count = prg_read_count + 1;
            exp_read_off = ux_bus_addr[14]
                         ? (FIXED_BASE + ux_bus_addr[13:0])
                         : ((model_bank * BANK_BYTES) + ux_bus_addr[13:0]);
            if (exp_read_off !== ux_mapper_prg_bank_offset)
                read_err = read_err + 1;
            else if (ux_cart_din !== tb_prg[exp_read_off])
                read_err = read_err + 1;
            else if (ux_bus_din !== tb_prg[exp_read_off])
                read_err = read_err + 1;
        end
    end
end

// RAM write capture, so the program's own read-back can be checked without a
// second model of the work ram.
always @(posedge clk) begin
    if (!reset && ux_bus_req && ux_bus_fire && ux_sel_ram && ux_bus_we) begin
        ram_shadow[ux.bus_addr[10:0]] = ux_bus_dout;
        if (ux_bus_addr === DONE_CELL)
            done = 1'b1;
    end
end

// ------------------------------------------------------- program image
task put;
    input [15:0] at;
    input [7:0]  v;
    begin
        tb_prg[FIXED_BASE + (at - 16'hC000)] = v;
    end
endtask

integer b;
integer pc;
reg [7:0] bank_byte;
reg [7:0] marker_byte;

// Seven bank writes, and the bank each must produce.  CONFLICT_BASE+b at $8000,
// mode 1 latches data & that byte, bank_select takes bits [3:0]:
//   b=0 byte 83 : 0F & 83 = 03 -> bank 3   conflicting
//   b=3 byte 86 : 05 & 86 = 04 -> bank 4   conflicting
//   b=4 byte 87 : 0A & 87 = 02 -> bank 2   conflicting
//   b=2 byte 85 : 85 & 85 = 85 -> bank 5   NOT conflicting, and 85 & 0F = 05
//   b=5 byte 88 : 07 & 88 = 00 -> bank 0   conflicting
//   b=0 byte 83 : 01 & 83 = 01 -> bank 1   conflicting
//   last write   : it goes to $FF00, which is in the FIXED last window, so the
//                  byte is the one at FIXED_BASE+$3F00 = 06 and NOT b's 84:
//                  06 & 06 = 06 -> bank 6.  This is the cpu_addr[14] branch of
//                  nes_mapper_uxrom.v:42-44.
reg [7:0] wdata [0:6];
integer wexp  [0:6];

initial begin
    for (i = 0; i < PRG_BYTES; i = i + 1)
        tb_prg[i] = 8'h00;
    for (i = 0; i < 8192; i = i + 1)
        chr_mem[i] = 8'h00;
    for (i = 0; i < 2048; i = i + 1)
        ram_shadow[i] = 8'h00;

    for (b = 0; b <= LAST_BANK; b = b + 1) begin
        bank_byte = CONFLICT_BASE + b;
        marker_byte = MARKER_BASE + b;
        tb_prg[b * BANK_BYTES + 0]     = bank_byte;
        tb_prg[b * BANK_BYTES + 16'h0100] = marker_byte;
        tb_prg[b * BANK_BYTES + 16'h0101] = marker_byte + 8'h10;
    end

    // The fixed last window holds the program.  Its $FF00 byte is given a value
    // so the one fixed-window bank write below still has a meaningful AND.
    tb_prg[FIXED_BASE + 16'h3F00] = 8'h06;

    put(16'hC000, 8'h78);   // SEI
    put(16'hC001, 8'hD8);   // CLD
    put(16'hC002, 8'hA2);   // LDX #$FF
    put(16'hC003, 8'hFF);
    put(16'hC004, 8'h9A);   // TXS

    wdata[0] = 8'h0F; wexp[0] = 3;
    wdata[1] = 8'h05; wexp[1] = 4;
    wdata[2] = 8'h0A; wexp[2] = 2;
    wdata[3] = 8'h85; wexp[3] = 5;
    wdata[4] = 8'h07; wexp[4] = 0;
    wdata[5] = 8'h01; wexp[5] = 1;
    wdata[6] = 8'h06; wexp[6] = 6;

    // Seven steps of 11 bytes: LDA #d ; STA $8000|$FF00 ; LDA $8100 ; STA $0200+n
    pc = 16'hC005;
    for (i = 0; i < 7; i = i + 1) begin
        put(pc, 8'hA9);
        put(pc + 1, wdata[i]);
        put(pc + 2, 8'h8D);
        put(pc + 3, 8'h00);
        put(pc + 4, (i == 6) ? 8'hFF : 8'h80);
        put(pc + 5, 8'hAD);
        put(pc + 6, 8'h00);
        put(pc + 7, 8'h81);
        put(pc + 8, 8'h8D);
        put(pc + 9, i);
        put(pc + 10, 8'h02);
        pc = pc + 11;
    end

    put(pc, 8'hA9);            // LDA #$5A
    put(pc + 1, 8'h5A);
    put(pc + 2, 8'h8D);        // STA $022F
    put(pc + 3, DONE_CELL[7:0]);
    put(pc + 4, DONE_CELL[15:8]);
    put(pc + 5, 8'h4C);        // JMP self
    put(pc + 6, SELF_ADDR[7:0]);
    put(pc + 7, SELF_ADDR[15:8]);

    put(16'hFFFC, 8'h00);      // reset vector, in the fixed last window
    put(16'hFFFD, 8'hC0);

    // Mirror the image into the dut's BRAM through the same hierarchical write
    // every other system bench uses.  The array moved one level down when it
    // moved into nes_cart_rom; it is still the core's only way to be handed a
    // program, and nothing about the injection changed.
    for (i = 0; i < PRG_BYTES; i = i + 1)
        ux.u_prg_rom.g_prg.prg_rom[i] = tb_prg[i];
end

// --------------------------------------------------------------- run
integer guard;

initial begin
    #1;
    repeat (4) @(posedge clk);
    #1;
    @(negedge clk);
    reset = 1'b0;
    #1;

    guard = 0;
    while (done !== 1'b1) begin
        @(posedge clk);
        guard = guard + 1;
        if (guard > 4000000) begin
            $display("RESULT FAIL the program never reached its done store at $022F");
            $finish;
        end
    end
    repeat (24) @(posedge clk);

    if (ux_mapper_id !== 3'd2)
        $fatal(1, "mapper_id is %0d, the bench elaborated MAPPER_SELECT=2 (UxROM)",
               ux_mapper_id);
    if (pulse_count !== 7)
        $fatal(1, "the mapper write pulse fired %0d times, the program issues 7",
               pulse_count);
    if (conflict_count < 1)
        $fatal(1, "no write produced a bus conflict, so mapper_bus_conflict was never exercised high");
    if (no_conflict_count < 1)
        $fatal(1, "no write was conflict free, so mapper_bus_conflict was never exercised low");
    if (pulse_byte_err !== 0)
        $fatal(1, "prg_readback was wrong on %0d of %0d mapper write clks",
               pulse_byte_err, pulse_count);
    if (pulse_off_err !== 0)
        $fatal(1, "mapper_prg_bank_offset was wrong on %0d of %0d mapper write clks",
               pulse_off_err, pulse_count);
    if (conflict_flag_err !== 0)
        $fatal(1, "mapper_bus_conflict disagreed with the tb model on %0d of %0d writes",
               conflict_flag_err, pulse_count);
    if (bank_err !== 0)
        $fatal(1, "mapper_prg_bank_offset left the tb model offset on %0d clk",
               bank_err);
    if (read_err !== 0)
        $fatal(1, "%0d of %0d prg reads did not match the tb image",
               read_err, prg_read_count);
    if (prg_read_count < 100)
        $fatal(1, "only %0d prg reads happened, the read path is barely exercised",
               prg_read_count);

    // The program's own read-back markers, against HARD-CODED expectations and
    // not against the model, so the model is not the only thing confirmed.
    for (i = 0; i < 7; i = i + 1) begin
        if (ram_shadow[16'h0200 + i] !== (MARKER_BASE + wexp[i]))
            $fatal(1, "ram[$%04h] = %02h, expected %02h for step %0d (bank %0d)",
                   16'h0200 + i, ram_shadow[16'h0200 + i],
                   MARKER_BASE + wexp[i], i, wexp[i]);
    end
    if (ram_shadow[DONE_CELL[10:0]] !== 8'h5A)
        $fatal(1, "ram[$022F] = %02h, the program never reached its done store",
               ram_shadow[DONE_CELL[10:0]]);

    $display("PULSE-WINDOW every one of the %0d mapper write pulses was exactly 1 clk wide, and on that clk prg_readback matched the tb model's byte for the PRE-write bank (err=%0d), mapper_prg_bank_offset matched the model's offset (err=%0d), and mapper_bus_conflict matched the tb's own (model byte != write data) (err=%0d).  That clk is the one nes_mapper_uxrom evaluates latched_data and bus_conflict on, so it is exactly where a one-clk-stale prg_readback would have appeared.  %0d of the %0d writes conflicted and %0d did not, so both levels of the flag were exercised PASS",
             pulse_count, pulse_byte_err, pulse_off_err, conflict_flag_err,
             conflict_count, pulse_count, no_conflict_count);
    $display("BANK-OFFSET mapper_prg_bank_offset was rebuilt from the tb's own UxROM decode on EVERY clk of the run -- banked branch to model_bank, fixed branch to the last 16 KiB bank, address taken from the mapper's latched write address while its pulse is up and from the cpu address otherwise -- and never left it (err=%0d).  model_bank advances only from the tb's own latched_data arithmetic on the write pulse, so a bank that moved without a write, or a write whose effect differed, would have failed PASS",
             bank_err);
    $display("PRG-READS %0d cart reads, each compared on the tb's own UxROM window decode, on mapper_prg_bank_offset, and on both cart_din and bus_din against the tb's own tb_prg image (err=%0d).  Nothing in this check reads the dut's memory PASS",
             prg_read_count, read_err);
    $display("PROGRAM-READBACK the seven markers the program itself read back out of the banked window were ram[$0200..$0206] = %02h %02h %02h %02h %02h %02h %02h against the hard coded banks 3 4 2 5 0 1 6, and ram[$022F] = %02h is the done store.  The last write went to $FF00 inside the FIXED last window, so the cpu_addr[14] branch of the conflict decode was measured and not only the banked branch PASS",
             ram_shadow[16'h0200], ram_shadow[16'h0201], ram_shadow[16'h0202],
             ram_shadow[16'h0203], ram_shadow[16'h0204], ram_shadow[16'h0205],
             ram_shadow[16'h0206], ram_shadow[DONE_CELL[10:0]]);
    $display("PASS tb_nes_system_v6_uxrom_prg");
    $finish;
end

endmodule
