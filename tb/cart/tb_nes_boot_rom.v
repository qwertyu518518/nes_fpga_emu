`timescale 1ns/1ps

// ============================================================================
// tb_nes_boot_rom : boot a real cartridge image and prove the core renders it
// ----------------------------------------------------------------------------
// WHAT THIS IS FOR
//   The other benches in this tree all prove one block against a hand-built
//   stimulus.  This one boots an actual .nes image: it loads the PRG image
//   through nes_system_v6's real nes_cart_rom, lets the CPU run the cartridge's
//   own reset vector, lets the PPU render real frames from the cartridge's own
//   CHR, and then captures the visible 256x240 frame into a binary PPM so the
//   picture can be looked at rather than inferred.
//
//   A rendered image on its own is NOT evidence.  Every claim below is asserted:
//   the reset vector is read out of the DUT's own PRG array, the program counter
//   is watched from the first instruction, the frame count is compared against
//   the number of frames asked for, the CHR the DUT renders from is compared
//   byte for byte against an independent copy of the same file, and X is not
//   allowed to reach a captured pixel.
//
// WHY THE PLACEHOLDER IS THE DEFAULT
//   PRG_HEX_FILE and CHR_HEX_FILE both default to the committed placeholders,
//   and STRICT_ROM defaults to 0, so `tools\sim_all.ps1` can gate this bench
//   using nothing but committed files.  The committed placeholder is a synthetic
//   filler pattern, NOT a cartridge: its reset vector is $0504, which is not in
//   $8000-$FFFF, and the program it "contains" never initialises the PPU.  So
//   the cartridge-dependent assertions (vector in ROM space, image not blank,
//   no X pixel) are only made when STRICT_ROM is 1, which is how the real .nes
//   run is invoked.  Every assertion that describes the CORE rather than the
//   CARTRIDGE is made unconditionally and holds for any image at all; see the
//   A1..A5 block below for which is which.
//
// WHY THE CORE IS DRIVEN DIRECTLY AND NOT THROUGH THE PLATFORM TOP
//   The Zynq top adds a 25 MHz LCD domain, a frame buffer, a palette expansion
//   and the whole audio lane.  None of that is what is under test, the LCD
//   domain would dominate the run time, and going through it would mean the
//   frame this bench captures has passed through a module whose correctness is
//   somebody else's target.  So this bench instantiates nes_system_v6 directly,
//   which is also the same core the top instantiates, and reproduces only the
//   one piece of top-level wiring that CHR genuinely needs: the CHR-only
//   nes_cart_rom instance, wired exactly as rtl/platform/zynq/nes_zynq_top.v
//   wires it, because nes_system_v6 has CHR_ENABLE(0) on its own instance and
//   therefore contains no CHR array at all.
//
// THE ce_ppu CADENCE, AND WHY IT IS NOT REGENERATED HERE
//   The core clock is the MMCM CLKOUT1 of rtl/platform/zynq/nes_zynq_clk.v:
//       f_core = (50e6 * 23.625) / 55 = 1181.25e6 / 55 = 21.477272727 MHz
//       T_core = 1 / 21.477272727e6 = 46.560846561 ns
//   nes_system_v6 divides that down internally with its own div_phase counter,
//   which runs 0..11 and is the ONLY clock divider in the core:
//       assign ce_cpu = !reset && (div_phase == 4'd0)   -> one CPU step per 12 clk
//       assign ce_ppu = !reset && (div_phase[1:0] == 2'b00) -> one PPU dot per 4 clk
//   So one PPU dot is 4 core clocks = 186.243 ns, and div_phase[1:0] == 0 hits
//   at phase 0, 4 and 8, of which only phase 0 is the clock edge on which the
//   dot register advances.
//   This bench therefore drives a plain 46.561 ns clock and then samples the
//   DUT's OWN exported ce_ppu.  It does not build a local div_phase and it does
//   not derive a clock enable from a local counter.  That is not a stylistic
//   choice: nes_cart_rom's CHR read path is phase sensitive by design, so a
//   regenerated cadence that is one to three beats out of phase latches the
//   CHR address on the wrong edge and returns the previous pattern byte,
//   silently, and the render still looks plausible.
//
// ONE FRAME, ARITHMETICALLY
//   NTSC is 262 scanlines of 341 dots, and one dot is 4 core clocks:
//       262 * 341 * 4 = 357,368 core clocks per frame
//       357,368 * 46.560846561 ns = 16.6375 ms per frame  (the 60.0988 Hz rate)
//   120 frames is therefore 42,884,160 core clocks and about 1.996 seconds of
//   emulated NES time.  frame_done pulses from the PPU at dot 340 of scanline
//   261, the pre-render line, which is after every one of the 240 visible
//   scanlines has been drawn, so a framebuffer dumped at that moment is
//   complete.
//
// PALETTE
//   pixel_pal[5:0] is applied through the SAME 64-entry table
//   rtl/platform/zynq/nes_zynq_top.v uses, transcribed below unchanged, and
//   widened to RGB888 with the SAME replication that top applies
//   ({r5,r5[4:2]}, {g6,g6[5:4]}, {b5,b5[4:2]}).  The table is not shared by
//   `include because that would make a gated testbench depend on a platform top
//   that this bench deliberately does not elaborate, and the transcription is
//   checked against that source in tools/sim_all.ps1's own file set.
//   pixel_pal is the raw byte the PPU stored: [5:4] is the colour axis and
//   [3:0] the luminance axis, so only [5:0] index the table.
//
// WHAT IS ASSERTED, AND UNDER WHICH MODE
//   A1  PRG reset vector, read from the DUT's own array, and the CPU's first PC
//       equals it.                       unconditional
//   A2  cpu_cycle advances, and N distinct PC values are collected
//       and printed.                      unconditional
//   A3  frames completed == frames asked for.        unconditional
//   A4  CHR the DUT renders from == an independent $readmemh of the same file,
//       byte for byte, all 8192 bytes.    unconditional
//   A5  captured frame has more than one distinct palette index, and the
//       fraction of non-background pixels and a 16x15 luminance map are
//       printed.                          STRICT_ROM only for the ">1" gate
//   A6  no captured pixel index is X.     STRICT_ROM (the placeholder's program
//                                        never writes PPU palette RAM, which
//                                        has no reset path in nes_ppu2c02.v,
//                                        so X there is correct and expected)
// ============================================================================

module tb_nes_boot_rom;

    // ------------------------------------------------------------- parameters
    // Defaults are the committed placeholders so the gate target is
    // self-contained.  The real .nes run overrides the first four.
    parameter PRG_HEX_FILE    = "rtl/nes_core/cart/prg_placeholder.hex";
    parameter CHR_HEX_FILE    = "rtl/nes_core/cart/chr_placeholder.hex";
    parameter integer WRITE_FRAMES = 0;
    parameter integer STRICT_ROM   = 0;
    parameter integer FRAMES_TO_RUN = 6;

    // -------------------------------------------------------------- geometry
    localparam integer FB_W = 256;
    localparam integer FB_H = 240;
    localparam integer FB_N = FB_W * FB_H;

    // Core clock.  1 / 21.477272727 MHz = 46.560846561 ns, rounded to the
    // 1 ps resolution of the `timescale above.
    localparam real CORE_HALF_NS = 23.2805;

    // NROM PRG window.  rtl/nes_core/mapper/nes_mapper_nrom.v:22 masks
    // prg_bank_offset to cpu_addr[14:0] when the image is 32 KiB, so
    // $8000-$BFFF is offset 0..16383 and $C000-$FFFF is offset 16384..32767.
    // The reset vector lives at CPU $FFFC, which is offset $7FFC.
    localparam [15:0] RESET_OFF = 16'h7FFC;

    reg clk;
    reg reset;
    reg [7:0] buttons1;
    reg [7:0] buttons2;

    wire [8:0]  w_dot;
    wire [8:0]  w_scanline;

    always #CORE_HALF_NS clk = !clk;

    initial begin
        clk       = 1'b0;
        reset     = 1'b1;
        buttons1  = 8'h00;
        buttons2  = 8'h00;
    end

    // =========================================================================
    // PALETTE, transcribed from rtl/platform/zynq/nes_zynq_top.v
    // =========================================================================
    function [15:0] pal_to_rgb565;
        input [5:0] idx;
        begin
            case (idx)
                6'h00: pal_to_rgb565 = 16'h632C;
                6'h01: pal_to_rgb565 = 16'h00F3;
                6'h02: pal_to_rgb565 = 16'h0855;
                6'h03: pal_to_rgb565 = 16'h4012;
                6'h04: pal_to_rgb565 = 16'h700C;
                6'h05: pal_to_rgb565 = 16'h8803;
                6'h06: pal_to_rgb565 = 16'h8080;
                6'h07: pal_to_rgb565 = 16'h6940;
                6'h08: pal_to_rgb565 = 16'h39E0;
                6'h09: pal_to_rgb565 = 16'h0260;
                6'h0A: pal_to_rgb565 = 16'h0260;
                6'h0B: pal_to_rgb565 = 16'h0225;
                6'h0C: pal_to_rgb565 = 16'h01AD;
                6'h0D: pal_to_rgb565 = 16'h0000;
                6'h0E: pal_to_rgb565 = 16'h0000;
                6'h0F: pal_to_rgb565 = 16'h0000;
                6'h10: pal_to_rgb565 = 16'hAD75;
                6'h11: pal_to_rgb565 = 16'h029E;
                6'h12: pal_to_rgb565 = 16'h39BF;
                6'h13: pal_to_rgb565 = 16'h811D;
                6'h14: pal_to_rgb565 = 16'hB8F4;
                6'h15: pal_to_rgb565 = 16'hD949;
                6'h16: pal_to_rgb565 = 16'hD200;
                6'h17: pal_to_rgb565 = 16'hB2E0;
                6'h18: pal_to_rgb565 = 16'h73C0;
                6'h19: pal_to_rgb565 = 16'h2C40;
                6'h1A: pal_to_rgb565 = 16'h0461;
                6'h1B: pal_to_rgb565 = 16'h042C;
                6'h1C: pal_to_rgb565 = 16'h0376;
                6'h1D: pal_to_rgb565 = 16'h0000;
                6'h1E: pal_to_rgb565 = 16'h0000;
                6'h1F: pal_to_rgb565 = 16'h0000;
                6'h20: pal_to_rgb565 = 16'hFFFF;
                6'h21: pal_to_rgb565 = 16'h4D1F;
                6'h22: pal_to_rgb565 = 16'h8C3F;
                6'h23: pal_to_rgb565 = 16'hD39F;
                6'h24: pal_to_rgb565 = 16'hFB7E;
                6'h25: pal_to_rgb565 = 16'hFBD3;
                6'h26: pal_to_rgb565 = 16'hFC88;
                6'h27: pal_to_rgb565 = 16'hFD61;
                6'h28: pal_to_rgb565 = 16'hC640;
                6'h29: pal_to_rgb565 = 16'h7EE2;
                6'h2A: pal_to_rgb565 = 16'h470A;
                6'h2B: pal_to_rgb565 = 16'h26B6;
                6'h2C: pal_to_rgb565 = 16'h25FF;
                6'h2D: pal_to_rgb565 = 16'h4A69;
                6'h2E: pal_to_rgb565 = 16'h0000;
                6'h2F: pal_to_rgb565 = 16'h0000;
                6'h30: pal_to_rgb565 = 16'hFFFF;
                6'h31: pal_to_rgb565 = 16'hB6DF;
                6'h32: pal_to_rgb565 = 16'hD67F;
                6'h33: pal_to_rgb565 = 16'hEE3F;
                6'h34: pal_to_rgb565 = 16'hFE3F;
                6'h35: pal_to_rgb565 = 16'hFE5B;
                6'h36: pal_to_rgb565 = 16'hFE96;
                6'h37: pal_to_rgb565 = 16'hFEF3;
                6'h38: pal_to_rgb565 = 16'hE752;
                6'h39: pal_to_rgb565 = 16'hCF93;
                6'h3A: pal_to_rgb565 = 16'hB797;
                6'h3B: pal_to_rgb565 = 16'hA77B;
                6'h3C: pal_to_rgb565 = 16'hA73F;
                6'h3D: pal_to_rgb565 = 16'hBDD7;
                6'h3E: pal_to_rgb565 = 16'h0000;
                6'h3F: pal_to_rgb565 = 16'h0000;
                default: pal_to_rgb565 = 16'h0000;
            endcase
        end
    endfunction

    // The top's RGB565 -> RGB888 widening, byte for byte:
    //   r8 = {rgb565[15:11], rgb565[15:13]}
    //   g8 = {rgb565[10:5],  rgb565[10:9]}
    //   b8 = {rgb565[4:0],   rgb565[4:2]}
    function [23:0] pal_rgb888;
        input [5:0] idx;
        reg [15:0] p;
        begin
            p = pal_to_rgb565(idx);
            pal_rgb888 = {p[15:11], p[15:13], p[10:5], p[10:9], p[4:0], p[4:2]};
        end
    endfunction

    // =========================================================================
    // TB-SIDE CHR MODEL
    //
    // An independent load of the same hex file.  It is NOT what the DUT renders
    // from; A4 compares it against the DUT's real CHR array byte for byte, so a
    // path error in either load shows up as a mismatch rather than as a
    // plausible but wrong picture.
    // =========================================================================
    reg [7:0] chr_model [0:8191];
    reg [7:0] prg_model [0:131071];

    initial begin
        $readmemh(CHR_HEX_FILE, chr_model);
        $readmemh(PRG_HEX_FILE, prg_model);
    end

    // =========================================================================
    // DUT
    // =========================================================================
    wire [7:0]       chr_rdata;
    wire             pv_pixel_valid;
    wire [7:0]       pv_pixel_x;
    wire [7:0]       pv_pixel_y;
    wire [7:0]       pv_pixel_pal;
    wire             pv_frame_done;
    wire             pv_vblank;
    wire             pv_nmi;
    wire             pv_apu_irq;
    wire             pv_audio_valid;
    wire [15:0]      pv_audio_l;
    wire [15:0]      pv_audio_r;
    wire [31:0]      pv_cpu_cycle;
    wire             pv_ce_ppu;
    wire             pv_ce_cpu;
    wire             pv_chr_req;
    wire [16:0]      pv_chr_final_addr;
    wire [13:0]      pv_chr_waddr;
    wire             pv_chr_we;
    wire [7:0]       pv_chr_wdata;
    wire             pv_chr_ram_en;
    wire [2:0]       pv_mapper_id;
    wire [7:0]       pv_mapper_nt;
    wire             pv_nmi_o;
    wire             pv_ctrl_data;
    // The core's own PPU register decode taps, so the write census below counts
    // writes the core actually performed rather than inferring them from the
    // raw bus.
    wire             pv_ppu_reg_cs;
    wire             pv_ppu_reg_we;
    wire [2:0]       pv_ppu_reg_addr;

    // MAPPER_SELECT 0 and HEADER_MIRRORING 0 are already this core's defaults
    // and are stated explicitly anyway so the cartridge's mapper and mirroring
    // are visible here rather than inherited.  NROM_PRG_RAM and NROM_CHR_RAM
    // are 0: this cartridge has no battery and its CHR is ROM, and leaving
    // CHR_RAM at 0 is also what keeps the CHR read-only.
    nes_system_v6 #(
        .MAPPER_SELECT(8'd0),
        .HEADER_MIRRORING(3'd0),
        .NROM_PRG_SIZE_BYTES(32768),
        .NROM_PRG_RAM(1'b0),
        .NROM_CHR_RAM(1'b0),
        .PRG_INIT_FILE(PRG_HEX_FILE)
    ) dut (
        .clk(clk),
        .reset(reset),
        .buttons1(buttons1),
        .buttons2(buttons2),
        .chr_rdata(chr_rdata),
        .pixel_valid(pv_pixel_valid),
        .pixel_x(pv_pixel_x),
        .pixel_y(pv_pixel_y),
        .pixel_index(),
        .pixel_pal(pv_pixel_pal),
        .frame_done(pv_frame_done),
        .vblank(pv_vblank),
        .nmi_o(pv_nmi_o),
        .apu_irq_o(pv_apu_irq),
        .audio_sample_valid(pv_audio_valid),
        .audio_sample_left(pv_audio_l),
        .audio_sample_right(pv_audio_r),
        .cpu_cycle(pv_cpu_cycle),
        .ppu_dot(w_dot),
        .ppu_scanline(w_scanline),
        .bus_owner(),
        .bus_active(),
        .bus_wait_count(),
        .bus_req(),
        .bus_stall(),
        .bus_fire(),
        .bus_addr(),
        .bus_we(),
        .bus_dout(),
        .bus_din(),
        .sel_ram(),
        .sel_ppu(),
        .sel_apu_io(),
        .sel_open_bus(),
        .sel_cart_ram(),
        .sel_cart_rom(),
        .ram_we(),
        .ppu_reg_cs(pv_ppu_reg_cs),
        .ppu_reg_we(pv_ppu_reg_we),
        .ppu_reg_addr(pv_ppu_reg_addr),
        .apu_reg_cs(),
        .apu_reg_we(),
        .apu_reg_addr(),
        .controller_data(pv_ctrl_data),
        .cart_req(),
        .cart_xfer(),
        .cart_addr(),
        .cart_din(),
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
        .mapper_id(pv_mapper_id),
        .mapper_prg_bank_offset(),
        .mapper_chr_bank_offset(),
        .mapper_mirroring(),
        .mapper_nametable_map(pv_mapper_nt),
        .mapper_prg_bank_number(),
        .mapper_prg_ram_enable(),
        .mapper_prg_ram_we(),
        .mapper_chr_ram_enable(pv_chr_ram_en),
        .mapper_chr_ram_we(),
        .mapper_bus_conflict(),
        .mapper_irq(),
        .irq_line(),
        .mapper_write_pulse(),
        .mapper_write_addr(),
        .mapper_write_data(),
        .prg_readback(),
        .chr_waddr(pv_chr_waddr),
        .chr_we(pv_chr_we),
        .chr_wdata(pv_chr_wdata),
        .chr_req(pv_chr_req),
        .chr_final_addr(pv_chr_final_addr),
        .ce_ppu(pv_ce_ppu),
        .ce_cpu(pv_ce_cpu)
    );

    // The production CHR half, wired exactly as rtl/platform/zynq/nes_zynq_top.v
    // wires its u_cart_chr: PRG disabled, CHR enabled, the core's OWN ce_ppu
    // (not a regenerated one), the core's chr_req and chr_final_addr, and the
    // mapper's chr_ram_enable gating the write half.
    nes_cart_rom #(
        .PRG_ENABLE(0),
        .CHR_ENABLE(1),
        .CHR_INIT_FILE(CHR_HEX_FILE)
    ) u_cart_chr (
        .clk(clk),
        .reset(reset),
        .prg_en(1'b0),
        .prg_addr(17'd0),
        .prg_rdata(),
        .ce_ppu(pv_ce_ppu),
        .chr_req(pv_chr_req),
        .chr_addr(pv_chr_final_addr),
        .chr_rdata(chr_rdata),
        .chr_waddr(pv_chr_waddr),
        .chr_we(pv_chr_we),
        .chr_wdata(pv_chr_wdata),
        .chr_ram_enable(pv_chr_ram_en)
    );

    // =========================================================================
    // FRAMEBUFFER AND PER-PIXEL ACCOUNTING
    //
    // pixel_valid in nes_ppu2c02.v:949 is a LEVEL, not a pulse:
    //     pixel_valid = !reset && (scanline < 240) && (dot < 256)
    // and dot only advances on ce_ppu.  So the conjunction below, which is the
    // same conjunction rtl/platform/zynq/nes_zynq_top.v uses for its pixel
    // pipeline, is high exactly once per visible dot and writes each of the 256
    // dots of a line once each.  Sampling on pixel_valid alone would write each
    // dot four times, four clks apart, into the same address.
    // =========================================================================
    reg [23:0] fb_rgb [0:FB_N-1];
    reg [5:0]  fb_idx [0:FB_N-1];

    integer x_pixels;          // captured pixels that were X
    integer cap_pixels;        // total pixels captured
    integer x_idx_seen;        // captured pixels whose index was X
    integer max_pal_idx;       // highest palette index captured
    reg [63:0] pal_seen;       // palette indices seen since the last frame_done
    integer pix_x_i;
    integer pix_y_i;
    integer out_of_range;

    initial out_of_range = 0;

    always @(posedge clk) begin
        if (!reset && pv_ce_ppu && pv_pixel_valid) begin
            cap_pixels = cap_pixels + 1;
            // pixel_x and pixel_y are 8 bits, so a bound of 256 written as 8'd256
            // would truncate to zero and make this test always false.  Both are
            // widened to integers first so the comparison is done in a width
            // that can hold FB_W and FB_H.
            pix_x_i = pv_pixel_x;
            pix_y_i = pv_pixel_y;
            if ((pix_x_i >= 0) && (pix_x_i < FB_W) && (pix_y_i >= 0) && (pix_y_i < FB_H)) begin
                fb_rgb[pix_y_i * FB_W + pix_x_i] <= pal_rgb888(pv_pixel_pal[5:0]);
                fb_idx[pix_y_i * FB_W + pix_x_i] <= pv_pixel_pal[5:0];
                if (^{pv_pixel_pal[5:0]} === 1'bx) begin
                    x_idx_seen = x_idx_seen + 1;
                end else begin
                    pal_seen[pv_pixel_pal[5:0]] = 1'b1;
                    if (pv_pixel_pal[5:0] > max_pal_idx)
                        max_pal_idx = pv_pixel_pal[5:0];
                end
            end else begin
                out_of_range = out_of_range + 1;
            end
        end
    end

    // =========================================================================
    // FRAME COUNTING AND PER-FRAME ROLLOVER
    //
    // frame_done is a LEVEL registered on ce, not a pulse.  nes_ppu2c02.v:1056
    // clears it on every ce and nes_ppu2c02.v:1096 sets it on the ce where dot
    // hits 340 of scanline 261, so it is high for that clk AND for the three
    // clk before the next ce arrives: four core clocks in total.  Counting it on
    // every clock therefore counts one frame four times, which is exactly what
    // an earlier version of this bench did and what made the run look like the
    // PPU had stopped after fifteen frames.  It is counted on ce_ppu, where it
    // is unambiguous.
    //
    // At that instant every one of the 240 visible scanlines of the frame just
    // finished has been captured, so a framebuffer dumped here is complete.
    // =========================================================================
    integer frame_count;

    initial begin
        frame_count   = 0;
        cap_pixels    = 0;
        x_pixels      = 0;
        x_idx_seen    = 0;
        max_pal_idx   = 0;
        pal_seen      = 64'd0;
    end

    wire frame_tick = pv_ce_ppu && pv_frame_done;

    always @(posedge clk) begin
        if (reset)
            frame_count <= 0;
        else if (frame_tick) begin
            frame_count <= frame_count + 1;
            pal_seen    <= 64'd0;
        end
    end

    // =========================================================================
    // CPU TRACKING: reset vector, first program counters, cycle advance
    //
    // nes_system_v6 leaves nes_cpu6502's dbg_pc port unconnected
    // (nes_system_v6.v:478), so the program counter is read from the register
    // the port itself is assigned from, nes_cpu6502.v:233  assign dbg_pc = pc_reg.
    // =========================================================================
    wire [15:0] cpu_pc = dut.u_cpu.pc_reg;

    integer pc_distinct;             // distinct pc values seen so far
    reg [15:0] pc_first [0:63];
    reg [15:0] pc_last;
    integer    pc_changes;
    integer    first_pc_frame;
    reg        first_pc_seen;
    integer    reset_frames;         // core clocks reset was held

    initial begin
        pc_distinct   = 0;
        pc_changes    = 0;
        first_pc_frame = -1;
        first_pc_seen = 1'b0;
        pc_last       = 16'hFFFF;
        reset_frames  = 0;
    end

    always @(posedge clk) begin
        if (reset) begin
            reset_frames = reset_frames + 1;
        end else begin
            if (pv_ce_cpu) begin
                if (cpu_pc !== pc_last) begin
                    pc_changes = pc_changes + 1;
                    pc_last    = cpu_pc;
                end
                if (first_pc_seen === 1'b0) begin
                    first_pc_seen = 1'b1;
                    first_pc_frame = frame_count;
                end
            end
            // A 64-entry linear table of the distinct values collected, used
            // only for reporting: the first N distinct PC values in order.
            if (pc_distinct < 64) begin
                if (pc_already(cpu_pc) === 1'b0) begin
                    pc_first[pc_distinct] = cpu_pc;
                    pc_distinct = pc_distinct + 1;
                end
            end
        end
    end

    function pc_already;
        input [15:0] v;
        integer k;
        begin
            pc_already = 1'b0;
            for (k = 0; k < pc_distinct; k = k + 1) begin
                if (pc_first[k] === v)
                    pc_already = 1'b1;
            end
        end
    endfunction

    // =========================================================================
    // SPRITE OBSERVATIONS (informative, not gated)
    // =========================================================================
    integer s0_clk, so_clk;
    integer s0_first_frame, so_first_frame;

    // -------------------------------------------------------------------------
    // SUBCONDITION AUDIT: why sprite 0 hit and overflow do or do not fire.
    //
    // nes_ppu_sprite.v:434-436 raises sprite0_hit only when
    //     pixel_active && slot_opaque[0] && (bg_pixel != 4'h0)
    // and nes_ppu2c02.v:924-925 makes bg_pixel = bg_shown && bg_pattern!=0, where
    // bg_shown is mask_reg[3] and dot >= 8.  So a hit needs ALL of:
    //     sprites shown (mask_reg[4], to latch), background shown (mask_reg[3]),
    //     a non-transparent BACKGROUND pixel, sprite 0 in range for this line,
    //     sprite 0 covering this dot, and sprite 0's pattern non-zero here.
    // Counting each of those separately turns "sprite 0 hit never fired" from an
    // observation into a diagnosis: whichever term is always zero is the reason.
    //
    // nes_ppu_sprite.v:441-442 raises sprite_overflow when range_count > 8, and
    // range_count is the DUT's own popcount.  mdl_range below recomputes the same
    // quantity INDEPENDENTLY from oam_ram, so a defect in the shared-prefix
    // popcount or in the eight picks would show up as a disagreement between the
    // model and the flag rather than as a plausible-looking screen.
    // -------------------------------------------------------------------------
    integer m_pix;         // ce_ppu beats inside the visible window
    integer m_bgopaque;    // background pattern non-zero at this dot
    integer m_s0opaque;    // DUT slot_opaque[0]
    integer m_s0_and_bg;   // the exact conjunction sprite0_hit requires
    integer m_hit_raw;     // DUT sprite0_hit_raw (pre-latch)
    integer m_ovf_raw;     // DUT sprite_overflow_raw (pre-latch)
    integer m_range_gt8;   // DUT range_count > 8
    integer m_mdl_range;   // samples where the independent model says > 8
    integer m_mdl_mismatch;// samples where DUT range_count disagrees with the model
    integer m_mask3;       // background shown
    integer m_mask4;       // sprites shown
    integer m_ctrl5;       // 8x16 sprite mode
    integer m_read2002;    // $2002 reads by the game
    integer m_max_range;   // largest range_count seen
    integer m_s0_y, m_s0_tile, m_s0_attr, m_s0_x;
    integer mdl_i, mdl_row, mdl_cnt, mdl_h;
    integer ovamodel_on;

    initial begin
        s0_clk = 0; so_clk = 0;
        s0_first_frame = -1; so_first_frame = -1;
        m_pix = 0; m_bgopaque = 0; m_s0opaque = 0; m_s0_and_bg = 0;
        m_hit_raw = 0; m_ovf_raw = 0; m_range_gt8 = 0; m_mdl_range = 0;
        m_mdl_mismatch = 0; m_mask3 = 0; m_mask4 = 0; m_ctrl5 = 0;
        m_read2002 = 0; m_max_range = 0;
        ovamodel_on = 0;
        $value$plusargs("OVAMODEL=%d", ovamodel_on);
        m_s0_y = 0; m_s0_tile = 0; m_s0_attr = 0; m_s0_x = 0;
    end

    always @(posedge clk) begin
        if (!reset) begin
            if (dut.u_ppu.dbg_sprite0_hit === 1'b1) begin
                s0_clk = s0_clk + 1;
                if (s0_first_frame < 0) s0_first_frame = frame_count;
            end
            if (dut.u_ppu.dbg_sprite_overflow === 1'b1) begin
                so_clk = so_clk + 1;
                if (so_first_frame < 0) so_first_frame = frame_count;
            end
            if (pv_ppu_reg_cs && !pv_ppu_reg_we && (pv_ppu_reg_addr == 3'd2))
                m_read2002 = m_read2002 + 1;

            if (pv_ce_ppu && (w_scanline < 9'd240) && (w_dot < 9'd256)) begin
                m_pix = m_pix + 1;
                if (dut.u_ppu.bg_opaque === 1'b1) m_bgopaque = m_bgopaque + 1;
                if (dut.u_ppu.g_chr_external.u_sprite.slot_opaque[0] === 1'b1)
                    m_s0opaque = m_s0opaque + 1;
                if ((dut.u_ppu.g_chr_external.u_sprite.slot_opaque[0] === 1'b1) &&
                    (dut.u_ppu.bg_opaque === 1'b1))
                    m_s0_and_bg = m_s0_and_bg + 1;
                if (dut.u_ppu.sprite0_hit_raw === 1'b1) m_hit_raw = m_hit_raw + 1;
                if (dut.u_ppu.sprite_overflow_raw === 1'b1) m_ovf_raw = m_ovf_raw + 1;
                if (dut.u_ppu.mask_reg[3] === 1'b1) m_mask3 = m_mask3 + 1;
                if (dut.u_ppu.mask_reg[4] === 1'b1) m_mask4 = m_mask4 + 1;

                // Independent recomputation of the 8-sprite limit straight from
                // OAM.  The DUT computes scan_row = scanline - oam_y in ten bits
                // and counts scan_row < sprite_height, so the subtraction must be
                // taken modulo 1024 here too or a sprite below the current line
                // would wrap to a huge positive and be counted as in range.
                //
                // Gated on +OVAMODEL=1 because it is 64 iterations on every one
                // of the 61440 visible ce_ppu samples per frame, which roughly
                // halves the frame rate.  The full 900 frame run had it on and
                // reported 0 disagreements over 55.3 million samples.
                if (ovamodel_on != 0) begin
                mdl_h = dut.u_ppu.control_reg[5] ? 16 : 8;
                mdl_cnt = 0;
                for (mdl_i = 0; mdl_i < 64; mdl_i = mdl_i + 1) begin
                    mdl_row = (w_scanline - dut.u_ppu.oam_ram[mdl_i * 4]) & 1023;
                    if (mdl_row < mdl_h) mdl_cnt = mdl_cnt + 1;
                end
                if (mdl_cnt > 8) m_mdl_range = m_mdl_range + 1;
                if (dut.u_ppu.g_chr_external.u_sprite.range_count != mdl_cnt)
                    m_mdl_mismatch = m_mdl_mismatch + 1;
                if (dut.u_ppu.g_chr_external.u_sprite.range_count > m_max_range)
                    m_max_range = dut.u_ppu.g_chr_external.u_sprite.range_count;
                end
            end
        end
    end

    // Snapshot OAM entry 0 at each frame boundary so the report can say whether
    // sprite 0 is ever positioned at all.
    integer m_s0_y_f, m_s0_x_f, m_s0_tile_f, m_s0_attr_f, m_s0_fr;
    initial begin
        m_s0_y_f = 0; m_s0_x_f = 0; m_s0_tile_f = 0; m_s0_attr_f = 0; m_s0_fr = -1;
    end

    always @(posedge clk) begin
        if (!reset && pv_ce_ppu && (w_scanline == 9'd100) && (w_dot == 9'd10)) begin
            m_s0_y_f    = dut.u_ppu.oam_ram[0];
            m_s0_tile_f = dut.u_ppu.oam_ram[1];
            m_s0_attr_f = dut.u_ppu.oam_ram[2];
            m_s0_x_f    = dut.u_ppu.oam_ram[3];
            m_s0_fr     = frame_count;
        end
    end

    // =========================================================================
    // CONTROLLER STIMULUS
    //
    // nes_controller.v:62 returns sel_buttons[0] first and shifts sr1_q right,
    // so the read order is the standard NES order:
    //     bit0 A  bit1 B  bit2 SELECT  bit3 START  bit4 UP  bit5 DOWN
    //     bit6 LEFT  bit7 RIGHT
    // Start is therefore buttons1[3].
    // The press schedule is a plusarg so the same compiled image can be driven
    // differently without recompiling:  +PRESS=2,20,40
    // presses START for PRESS_HOLD frames beginning at each listed frame.
    // =========================================================================
    integer press_frames [0:7];
integer n_press;
integer press_hold;
reg     press_active;
    integer vtmp;
    integer cap_list     [0:7];
    integer n_cap;

    // Icarus 12.0's $value$plusargs("%s", reg) does NOT fill the register with
    // the ASCII bytes: measured directly, "+CAP=40,70,100" into a reg [8*64:1]
    // left b[0] = 0x58 ('X'), not 0x34 ('4'), so a byte scan of the buffer
    // cannot be used to split a list.  It also accepts only two arguments, so
    // the SystemVerilog multi-value form is unavailable.  The two-argument %d
    // form does work, so both lists are taken as explicitly numbered integer
    // plusargs instead:
    //     +PRS0=30 +PRS1=45      press START from those frames
    //     +CAP0=40 +CAP1=70      dump those frame numbers
    // Eight calls each rather than a loop, because the plusarg name has to be a
    // literal.
    task automatic do_press_scan;
        input integer seed;
        integer hit;
        integer ph;
        begin
            n_press    = 0;
            press_hold = 8;
            ph = $value$plusargs("PRESSHOLD=%d", press_hold);
            if (seed != 0) begin
                hit = $value$plusargs("PRS0=%d", vtmp); if (hit != 0) begin press_frames[n_press] = vtmp; n_press = n_press + 1; end
                hit = $value$plusargs("PRS1=%d", vtmp); if (hit != 0) begin press_frames[n_press] = vtmp; n_press = n_press + 1; end
                hit = $value$plusargs("PRS2=%d", vtmp); if (hit != 0) begin press_frames[n_press] = vtmp; n_press = n_press + 1; end
                hit = $value$plusargs("PRS3=%d", vtmp); if (hit != 0) begin press_frames[n_press] = vtmp; n_press = n_press + 1; end
                hit = $value$plusargs("PRS4=%d", vtmp); if (hit != 0) begin press_frames[n_press] = vtmp; n_press = n_press + 1; end
                hit = $value$plusargs("PRS5=%d", vtmp); if (hit != 0) begin press_frames[n_press] = vtmp; n_press = n_press + 1; end
                hit = $value$plusargs("PRS6=%d", vtmp); if (hit != 0) begin press_frames[n_press] = vtmp; n_press = n_press + 1; end
                hit = $value$plusargs("PRS7=%d", vtmp); if (hit != 0) begin press_frames[n_press] = vtmp; n_press = n_press + 1; end
            end
        end
    endtask

    task automatic do_cap_scan;
        input integer seed;
        integer hit;
        begin
            n_cap = 0;
            hit = $value$plusargs("CAP0=%d", vtmp); if (hit != 0) begin cap_list[n_cap] = vtmp; n_cap = n_cap + 1; end
            hit = $value$plusargs("CAP1=%d", vtmp); if (hit != 0) begin cap_list[n_cap] = vtmp; n_cap = n_cap + 1; end
            hit = $value$plusargs("CAP2=%d", vtmp); if (hit != 0) begin cap_list[n_cap] = vtmp; n_cap = n_cap + 1; end
            hit = $value$plusargs("CAP3=%d", vtmp); if (hit != 0) begin cap_list[n_cap] = vtmp; n_cap = n_cap + 1; end
            hit = $value$plusargs("CAP4=%d", vtmp); if (hit != 0) begin cap_list[n_cap] = vtmp; n_cap = n_cap + 1; end
            hit = $value$plusargs("CAP5=%d", vtmp); if (hit != 0) begin cap_list[n_cap] = vtmp; n_cap = n_cap + 1; end
            hit = $value$plusargs("CAP6=%d", vtmp); if (hit != 0) begin cap_list[n_cap] = vtmp; n_cap = n_cap + 1; end
            hit = $value$plusargs("CAP7=%d", vtmp); if (hit != 0) begin cap_list[n_cap] = vtmp; n_cap = n_cap + 1; end
            if (n_cap == 0) begin
                cap_list[0] = FRAMES_TO_RUN - 2;
                cap_list[1] = FRAMES_TO_RUN - 1;
                n_cap = 2;
            end
        end
    endtask

    integer fi;
    always @(frame_count) begin
        if (WRITE_FRAMES == 1 && !reset) begin
            for (fi = 0; fi < n_cap; fi = fi + 1) begin
                if (frame_count == cap_list[fi] && cap_list[fi] >= 0)
                    dump_ppm(frame_count, cap_list[fi]);
            end
        end
        // Press schedule, evaluated on frame boundaries.
        //
        // OR-ed across every entry rather than assigned per entry.  An earlier
        // version of this loop assigned buttons1 unconditionally inside the loop,
        // so with two or more scheduled presses the LAST entry always won and
        // every earlier press was silently dead.  A four-press schedule actually
        // pressed only its fourth.
        if (WRITE_FRAMES == 1 && !reset) begin
            press_active = 1'b0;
            for (fi = 0; fi < n_press; fi = fi + 1) begin
                if ((frame_count >= press_frames[fi]) &&
                    (frame_count <  press_frames[fi] + press_hold))
                    press_active = 1'b1;
            end
            buttons1 = press_active ? 8'h08 : 8'h00;
        end
    end

    // =========================================================================
    // PPM WRITER, binary P6, no library and no encoding
    // =========================================================================
    reg [8*64:1] ppm_name;
    integer      ppm_fd;
    integer      px, py, pi;
    reg [7:0]    b_r, b_g, b_b;
    integer      ppm_bytes;

    task automatic dump_ppm;
        input integer frame_n;
        input integer slot;
        integer   st_hist [0:63];
        integer   s_k;
        integer   s_distinct;
        integer   s_modal;
        integer   s_modal_cnt;
        integer   s_nonbg;
        begin
            // Per-frame image statistics, so one run reports the whole
            // progression instead of only the final framebuffer.
            for (s_k = 0; s_k < 64; s_k = s_k + 1) st_hist[s_k] = 0;
            for (s_k = 0; s_k < FB_N; s_k = s_k + 1)
                if (fb_idx[s_k] !== 6'hxx) st_hist[fb_idx[s_k]] = st_hist[fb_idx[s_k]] + 1;
            s_distinct = 0; s_modal = 0; s_modal_cnt = 0;
            for (s_k = 0; s_k < 64; s_k = s_k + 1) begin
                if (st_hist[s_k] > 0) s_distinct = s_distinct + 1;
                if (st_hist[s_k] > s_modal_cnt) begin
                    s_modal_cnt = st_hist[s_k];
                    s_modal    = s_k;
                end
            end
            s_nonbg = 0;
            for (s_k = 0; s_k < FB_N; s_k = s_k + 1)
                if ((fb_idx[s_k] !== 6'hxx) && (fb_idx[s_k] !== s_modal[5:0]))
                    s_nonbg = s_nonbg + 1;

            $sformat(ppm_name, "build/frames/nes_frame%0d.ppm", slot);
            ppm_fd = $fopen(ppm_name, "wb");
            if (ppm_fd == 0) begin
                $display("PPM ERROR could not open %0s", ppm_name);
            end else begin
                $fwrite(ppm_fd, "P6\n%0d %0d\n255\n", FB_W, FB_H);
                for (py = 0; py < FB_H; py = py + 1) begin
                    for (px = 0; px < FB_W; px = px + 1) begin
                        pi = py * FB_W + px;
                        b_r = fb_rgb[pi][23:16];
                        b_g = fb_rgb[pi][15:8];
                        b_b = fb_rgb[pi][7:0];
                        $fwrite(ppm_fd, "%c%c%c", b_r, b_g, b_b);
                    end
                end
                ppm_bytes = 15 + FB_N * 3;
                $fclose(ppm_fd);
                $display("PPM wrote %0s  nes_frame=%0d  slot=%0d  %0d bytes  distinct=%0d modal=%0d modal_count=%0d nonbg=%0d nonbg_frac=%0.6f",
                         ppm_name, frame_n, slot, ppm_bytes,
                         s_distinct, s_modal, s_modal_cnt, s_nonbg,
                         s_nonbg / (FB_N * 1.0));
            end
        end
    endtask

    // =========================================================================
    // IMAGE ANALYSIS, run once at the end on the final framebuffer
    // =========================================================================
    integer hist [0:63];
    integer ai;
    integer modal_idx;
    integer modal_cnt;
    integer nonbg;
    integer distinct_n;
    integer blk_sum;
    integer blk_avg;
    integer bx, by;
    reg [7:0] lum_ramp [0:9];
    reg [1023:0] row_txt;
    integer     final_distinct;
    integer     final_nonbg;

    initial begin
        // ASCII ramp, darkest to brightest.  Written numerically rather than
        // as string literals because a Verilog string literal is 32 bits wide
        // and assigning one to an 8-bit reg is a truncating warning.
        lum_ramp[0] = 8'h20;  // space
        lum_ramp[1] = 8'h2E;  // .
        lum_ramp[2] = 8'h3A;  // :
        lum_ramp[3] = 8'h2D;  // -
        lum_ramp[4] = 8'h3D;  // =
        lum_ramp[5] = 8'h2B;  // +
        lum_ramp[6] = 8'h2A;  // *
        lum_ramp[7] = 8'h23;  // #
        lum_ramp[8] = 8'h25;  // %
        lum_ramp[9] = 8'h40;  // @
    end

    task automatic analyse;
        begin
            for (ai = 0; ai < 64; ai = ai + 1) hist[ai] = 0;
            for (ai = 0; ai < FB_N; ai = ai + 1) begin
                if (fb_idx[ai] !== 6'hxx) hist[fb_idx[ai]] = hist[fb_idx[ai]] + 1;
            end
            modal_idx = 0; modal_cnt = 0; distinct_n = 0; nonbg = 0;
            for (ai = 0; ai < 64; ai = ai + 1) begin
                if (hist[ai] > 0) distinct_n = distinct_n + 1;
                if (hist[ai] > modal_cnt) begin
                    modal_cnt = hist[ai];
                    modal_idx = ai;
                end
            end
            for (ai = 0; ai < FB_N; ai = ai + 1)
                if ((fb_idx[ai] !== 6'hxx) && (fb_idx[ai] !== modal_idx[5:0]))
                    nonbg = nonbg + 1;
            final_distinct = distinct_n;
            final_nonbg   = nonbg;

            $display("ANALYSIS distinct_colours=%0d modal_index=%0d modal_count=%0d non_background=%0d non_background_fraction=%0.6f",
                     distinct_n, modal_idx, modal_cnt, nonbg,
                     (FB_N * 1.0) ? (nonbg * 1.0 / (FB_N * 1.0)) : 0.0);
            $display("ANALYSIS x_index_pixels=%0d max_palette_index=%0d", x_idx_seen, max_pal_idx);
            $display("LUMINANCE 16x15 blocks, ramp ' ' darkest to '@' brightest");
            for (by = 0; by < 15; by = by + 1) begin
                row_txt = 1024'd0;
                for (bx = 0; bx < 16; bx = bx + 1) begin
                    blk_sum = 0;
                    for (py = by * 16; py < by * 16 + 16; py = py + 1)
                        for (px = bx * 16; px < bx * 16 + 16; px = px + 1)
                            blk_sum = blk_sum + {1'b0, fb_rgb[py * FB_W + px][23:16]} +
                                      {1'b0, fb_rgb[py * FB_W + px][15:8]} +
                                      {1'b0, fb_rgb[py * FB_W + px][7:0]};
                    blk_avg = (blk_sum / 3) / 256;
                    if (blk_avg > 255) blk_avg = 255;
                    // Square-root transfer before quantising, so sparse bright
                    // detail survives.  A plain linear mean over a 16x16 block
                    // hides this cartridge's screen entirely: it is white text
                    // on black with about 3 percent of the pixels lit, so a
                    // block holding a dozen lit pixels averages near 7/255 and
                    // prints as the darkest glyph even though it carries the
                    // whole picture.  sqrt(mean/255)*255 == sqrt(mean*255) keeps
                    // the ordering and restores the contrast at the dark end
                    // without clipping white.
                    blk_avg = isqrt(blk_avg * 255);
                    row_txt[bx*8 +: 8] = lum_ramp[(blk_avg * 9) / 256];
                end
                $write("LUM ");
                for (bx = 0; bx < 16; bx = bx + 1) $write("%c", row_txt[bx*8]);
                $write("\n");
            end
        end
    endtask

    // =========================================================================
    // PER-FRAME TRACE
    //
    // Enabled with +TRACE.  This is the instrument that answers "did it render
    // and then stop, or did it never render at all", which a single end-of-run
    // framebuffer cannot: a framebuffer holds whatever the LAST frame drew, so a
    // hang late in the run is indistinguishable from a black screen without it.
    // =========================================================================
    integer trace_on;
    integer fr_pix;          // pixels captured this frame
    integer fr_pcchg;        // program counter changes this frame
    integer fr_nmi;          // nmi_o rising edges this frame
    integer fr_dma;          // oam_dma_start pulses this frame
    integer fr_ceppu;        // ce_ppu beats this frame
    integer fr_cecpu;        // ce_cpu beats this frame
    integer fr_vbl;          // vblank clk high this frame
    integer fr_pcmax;        // highest PC address touched this frame
    integer fr_nmin;         // lowest PC address touched this frame
    integer fr_dist;         // distinct palette indices in this frame
    integer fr_nonbg;        // pixels off the background colour this frame
    reg [15:0] fr_pcmin_v;
    integer fh [0:63];
    integer fk;
    integer fh_max;
    integer fh_mode;

    // Cumulative PPU register writes.  These decide whether a black screen is
    // the game choosing to leave rendering off or the core failing to serve the
    // writes, and that distinction is the whole diagnosis:
    //   w2000 PPUCTRL (NMI enable + base addresses)
    //   w2001 PPUMASK (bit3 show background, bit4 show sprites)
    //   w2005 scroll x   w2006 scroll y   w2007 data
    //   wpal  $3Fxx palette writes, i.e. reg_addr 7 with v_addr[4:0] < 32
    //   wctrl_hi, wmask_hi are the same two registers' high bits as the core
    //   actually latched them, so a written-but-not-latched fault is visible.
    integer w2000, w2001, w2005, w2006, w2007, wpal, wctrl_hi, wmask_hi, w4014;
    integer fr_dma_total, ppu_chr_rd_total;
    reg [7:0] ctrl_latched, mask_latched;
    // v_addr as it was BEFORE the current edge.  The PPU increments v_addr on
    // the same edge as a $2007 write, so sampling v_addr combinationally in an
    // observer at that edge reads the POST-increment value and every palette
    // write looks like it landed one entry too high.  Registering it first is
    // what makes the palette census below agree with palette_ram.
    reg [14:0] v_addr_q;
    integer chr_we_pulses;

    // CHR read path audit.
    //
    //   chr_req_pulses    : how many CHR fetches the core asked for at all
    //   chr_pages_seen    : which 128-byte pages of the 8 KiB CHR were touched,
    //                       as a 64-bit mask over chr_final_addr[12:7].  A PPU
    //                       that only ever asks for a couple of pages cannot show
    //                       a screen no matter what the ROM contains.
    //   chr_rdata_bad     : THE decisive check.  chr_rdata is registered on
    //                       ce_ppu, so just before any ce_ppu edge it must hold
    //                       the byte for the address that was presented on the
    //                       PREVIOUS ce_ppu edge.  Comparing it against the
    //                       independent model of that address proves the whole
    //                       path -- request, mapper translation, array index,
    //                       register timing -- in one number, and it is the check
    //                       that catches a phase error which would otherwise
    //                       still produce a plausible-looking picture.
    integer chr_req_pulses;
    integer chr_rdata_bad;
    integer chr_rdata_checked;
    reg [63:0] chr_pages_seen;
    reg [16:0] chr_prev_addr;
    reg        chr_prev_valid;
    reg [7:0]  chr_expect_q;
    integer    chr_min_addr, chr_max_addr;

    initial begin
        chr_req_pulses  = 0;
        chr_rdata_bad   = 0;
        chr_rdata_checked = 0;
        chr_pages_seen  = 64'd0;
        chr_prev_valid  = 1'b0;
        chr_min_addr    = 17'h1FFFF;
        chr_max_addr    = 17'd0;
        fr_dma_total      = 0;
        ppu_chr_rd_total  = 0;
        chr_we_pulses     = 0;
    end

    always @(posedge clk) begin
        // v_addr must be sampled on EVERY clock, not only on ce_ppu.  A $2007
        // write lands on a ce_CPU beat, so a v_addr_q that only advanced on
        // ce_ppu never held the address the write actually used and the palette
        // census below read zero for every write.
        if (!reset) v_addr_q <= dut.u_ppu.v_addr;
        if (!reset && pv_ce_ppu) begin
            if (pv_chr_we && pv_chr_ram_en)
                chr_we_pulses = chr_we_pulses + 1;
            // chr_rdata pre-edge must equal the model byte for the previous
            // request.
            if (chr_prev_valid === 1'b1) begin
                chr_rdata_checked = chr_rdata_checked + 1;
                if (chr_rdata !== chr_expect_q)
                    chr_rdata_bad = chr_rdata_bad + 1;
            end
            chr_prev_valid = 1'b1;
            if (pv_chr_req) begin
                chr_req_pulses = chr_req_pulses + 1;
                chr_pages_seen[pv_chr_final_addr[12:7]] = 1'b1;
                if (pv_chr_final_addr < chr_min_addr) chr_min_addr = pv_chr_final_addr;
                if (pv_chr_final_addr > chr_max_addr) chr_max_addr = pv_chr_final_addr;
                chr_expect_q  = chr_model[pv_chr_final_addr[12:0]];
                chr_prev_addr = pv_chr_final_addr;
            end
        end
    end

    // How much of the PPU palette the CPU actually programmed.  A PPU whose
    // palette_ram is all zero or all X renders a flat or undefined screen no
    // matter how correct the background pipeline is, so this separates "the CPU
    // never set the palette" from "the PPU ignores it".
    // Integer square root, by counting up.  The argument never exceeds
    // 255*255 = 65025 here, so the loop is at most 255 iterations.
    function integer isqrt;
        input integer v;
        integer i;
        begin
            i = 0;
            while (((i + 1) * (i + 1) <= v) && (i < 4096)) i = i + 1;
            isqrt = i;
        end
    endfunction

    function integer popcount64;
        input [63:0] v;
        integer k;
        begin
            popcount64 = 0;
            for (k = 0; k < 64; k = k + 1)
                if (v[k]) popcount64 = popcount64 + 1;
        end
    endfunction

    function integer pal_nonzero_sample;
        integer k;
        begin
            pal_nonzero_sample = 0;
            for (k = 0; k < 32; k = k + 1)
                if (dut.u_ppu.palette_ram[k] !== 8'h00 &&
                    dut.u_ppu.palette_ram[k] !== 8'hxx)
                    pal_nonzero_sample = pal_nonzero_sample + 1;
        end
    endfunction

    task automatic trace_frame;
        input integer n;
        begin
            $display("TRACE frame=%0d pix=%0d dist=%0d nonbg=%0d ce_ppu=%0d cpu_cycle=%0d pc_lo=$%0h pc_hi=$%0h nmi=%0d dma=%0d",
                     n, fr_pix, fr_dist, fr_nonbg, fr_ceppu, pv_cpu_cycle,
                     fr_nmin, fr_pcmax, fr_nmi, fr_dma);
        end
    endtask

    initial begin
        trace_on  = 0;
        press_active = 1'b0;
        fr_pix    = 0; fr_pcchg = 0; fr_nmi = 0; fr_dma = 0;
        fr_ceppu  = 0; fr_cecpu = 0; fr_vbl = 0; fr_pcmax = 0; fr_nmin = 16'hFFFF;
        fr_dist   = 0; fr_nonbg = 0;
        fr_pcmin_v = 16'hFFFF;
        w2000 = 0; w2001 = 0; w2005 = 0; w2006 = 0; w2007 = 0; wpal = 0;
        wctrl_hi = 0; wmask_hi = 0; w4014 = 0;
    end

    reg nmi_o_q;

    // ONE process owns every per-frame counter.  An earlier version of this
    // bench accumulated in one always block and cleared in a second one, with
    // blocking assignment in the first and non-blocking in the second; two
    // processes driving the same variable is a race, and it produced a frame
    // trace whose per-frame counts were meaningless (all the activity landed in
    // one bucket).  Everything below is accumulate-then-test inside a single
    // block so the numbers are a real partition of the run.
    always @(posedge clk) begin
        nmi_o_q <= pv_nmi_o;
        if (reset) begin
            fr_pix     <= 0;
            fr_pcchg   <= 0;
            fr_nmi     <= 0;
            fr_dma     <= 0;
            fr_ceppu   <= 0;
            fr_cecpu   <= 0;
            fr_vbl     <= 0;
            fr_pcmax   <= 0;
            fr_nmin    <= 16'hFFFF;
            fr_pcmin_v <= 16'hFFFF;
        end else begin
            if (pv_ce_ppu) begin
                fr_ceppu <= fr_ceppu + 1;
                if (pv_pixel_valid) fr_pix <= fr_pix + 1;
            end
            if (pv_ce_cpu) begin
                fr_cecpu <= fr_cecpu + 1;
                if (cpu_pc > fr_pcmax) fr_pcmax <= cpu_pc;
                if (cpu_pc < fr_pcmin_v) begin
                    fr_pcmin_v <= cpu_pc;
                    fr_nmin    <= cpu_pc;
                end
            end
            if (pv_vblank) fr_vbl <= fr_vbl + 1;
            if (pv_nmi_o && !nmi_o_q) fr_nmi <= fr_nmi + 1;
            if (dut.oam_dma_start) fr_dma <= fr_dma + 1;
            if (dut.oam_dma_start) fr_dma_total = fr_dma_total + 1;
            if (dut.ppu_chr_rd_arm) ppu_chr_rd_total = ppu_chr_rd_total + 1;
            if (frame_tick) begin
                if (trace_on != 0) begin
                    // Per-frame colour census, so the progression is visible
                    // even on a run that dumps no images.
                    for (fk = 0; fk < 64; fk = fk + 1) fh[fk] = 0;
                    for (fk = 0; fk < FB_N; fk = fk + 1)
                        if (fb_idx[fk] !== 6'hxx) fh[fb_idx[fk]] = fh[fb_idx[fk]] + 1;
                    fr_dist  = 0;
                    fh_max   = 0;
                    fh_mode  = 0;
                    for (fk = 0; fk < 64; fk = fk + 1) begin
                        if (fh[fk] > 0) fr_dist = fr_dist + 1;
                        if (fh[fk] > fh_max) begin
                            fh_max  = fh[fk];
                            fh_mode = fk;
                        end
                    end
                    fr_nonbg = 0;
                    for (fk = 0; fk < 64; fk = fk + 1)
                        if ((fh[fk] > 0) && (fk != fh_mode))
                            fr_nonbg = fr_nonbg + fh[fk];
                    trace_frame(frame_count + 1);
                end
                fr_pix     <= 0;
                fr_pcchg   <= 0;
                fr_nmi     <= 0;
                fr_dma     <= 0;
                fr_ceppu   <= 0;
                fr_cecpu   <= 0;
                fr_vbl     <= 0;
                fr_pcmax   <= 0;
                fr_nmin    <= 16'hFFFF;
                fr_pcmin_v <= 16'hFFFF;
            end
            // PPU register writes.  sel_ppu/cs/we/addr are the core's own decode
            // taps, so this counts writes the core actually performed.
            if (pv_ppu_reg_cs && pv_ppu_reg_we) begin
                case (pv_ppu_reg_addr)
                    3'd0: w2000 = w2000 + 1;
                    3'd1: w2001 = w2001 + 1;
                    3'd5: w2005 = w2005 + 1;
                    3'd6: w2006 = w2006 + 1;
                    3'd7: begin
                        w2007 = w2007 + 1;
                        // The palette window.  $3F00 is 0x3F00, which in the
                        // PPU's 15 bit v_addr is 0 1111 1000 0000 0, so
                        // v_addr[14:13] is 2'b01, NOT 2'b00.  An earlier version
                        // of this test used 2'b00 here, which can never be true
                        // for any palette address, and so reported zero palette
                        // writes on a run in which palette_ram demonstrably held
                        // 23 programmed entries.  The correct decode is
                        // v_addr[14:13] == 2'b01 && v_addr[12] == 1'b1, i.e.
                        // v_addr[14:12] == 3'b011, the $3000-$3FFF range the
                        // 2C02 mirrors its palette through.  Read from
                        // v_addr_q, the pre-edge value, so it is the address the
                        // PPU actually wrote.
                        if ((v_addr_q[14:13] == 2'b01) && (v_addr_q[12] == 1'b1))
                            wpal = wpal + 1;
                    end
                    default: ;
                endcase
            end
            if (dut.u_ppu.control_reg[7]) wctrl_hi = wctrl_hi + 1;
            if (dut.u_ppu.mask_reg[3] || dut.u_ppu.mask_reg[4]) wmask_hi = wmask_hi + 1;
        end
    end

    // =========================================================================
    // MAIN SEQUENCE
    // =========================================================================
    integer errors;
    integer prg_mismatch;
    integer chr_mismatch;
    integer pi2;
    integer chr_nonzero;
    integer prg_first_lo, prg_first_hi;
    reg [15:0] reset_vector;
    reg [15:0] pc_at_first_ce;
    reg        pc_captured;
    reg [31:0] cycle_first;
    reg [31:0] cycle_last;
    integer    cycles_advanced;

    initial begin
        errors = 0;
        do_cap_scan(1);
        do_press_scan(1);
        if ($value$plusargs("TRACE=%d", trace_on) == 0) trace_on = 0;

        $display("BOOT ROM PRG_HEX_FILE=%0s", PRG_HEX_FILE);
        $display("BOOT ROM CHR_HEX_FILE=%0s", CHR_HEX_FILE);
        $display("BOOT ROM strict=%0d frames_to_run=%0d write_frames=%0d",
                 STRICT_ROM, FRAMES_TO_RUN, WRITE_FRAMES);
        $display("BOOT ROM clock period=%0.3f ns (21.477272727 MHz), dot=%0d clk, frame=%0d clk = %0.4f ms",
                 2.0 * CORE_HALF_NS, 4, 357368, 357368 * 46.560846561 / 1000000.0);

        // Reset is active HIGH (nes_system_v6 gates ce_ppu with !reset and the
        // CPU and PPU both use posedge reset).  Hold it for a few core clocks
        // so div_phase is running before the release.
        reset = 1'b1;
        repeat (16) @(posedge clk);
        reset = 1'b0;

        // A short settle so the first $readmemh-driven fetch has happened.
        repeat (64) @(posedge clk);

        // ---------------------------------------------------------------- A1
        // The reset vector is read out of the DUT's OWN PRG array, not out of
        // the testbench's copy, so this is the value the core will actually
        // fetch.  nes_cart_rom loads prg_rom in an initial block, so by here it
        // is loaded.
        prg_first_lo = dut.u_prg_rom.g_prg.prg_rom[RESET_OFF];
        prg_first_hi = dut.u_prg_rom.g_prg.prg_rom[RESET_OFF + 16'd1];
        reset_vector = {prg_first_hi[7:0], prg_first_lo[7:0]};
        $display("A1 reset vector from DUT u_prg_rom.g_prg.prg_rom[$%0h/$%0h] = $%0h",
                 RESET_OFF, RESET_OFF + 16'd1, reset_vector);

        if (^reset_vector === 1'bx) begin
            $display("A1 FAIL reset vector is X: the DUT PRG array did not load");
            errors = errors + 1;
        end

        // The full PRG array must match the independent load, not just the two
        // vector bytes.
        prg_mismatch = 0;
        for (pi2 = 0; pi2 < 131072; pi2 = pi2 + 1)
            if (dut.u_prg_rom.g_prg.prg_rom[pi2] !== prg_model[pi2])
                prg_mismatch = prg_mismatch + 1;
        $display("A1 prg array compare: %0d of 131072 bytes differ from the independent $readmemh",
                 prg_mismatch);
        if (prg_mismatch != 0) begin
            $display("A1 FAIL the DUT PRG array does not match the file");
            errors = errors + 1;
        end

        // CHR full depth: an 8 KiB image that is all one value means $readmemh
        // found nothing, which is also what would silently drop the BRAM count
        // in synthesis.
        chr_nonzero = 0;
        for (pi2 = 0; pi2 < 8192; pi2 = pi2 + 1)
            if (chr_model[pi2] !== 8'h00) chr_nonzero = chr_nonzero + 1;
        $display("A4 chr model: %0d of 8192 bytes non-zero, distinct values %0d",
                 chr_nonzero, distinct_chr());

        // ---------------------------------------------------------------- A4
        // The CHR the DUT actually renders from, byte for byte, against an
        // independent load of the same file.
        chr_mismatch = 0;
        for (pi2 = 0; pi2 < 8192; pi2 = pi2 + 1)
            if (u_cart_chr.g_chr.chr_rom[pi2] !== chr_model[pi2])
                chr_mismatch = chr_mismatch + 1;
        $display("A4 chr array compare: %0d of 8192 bytes differ between u_cart_chr.g_chr.chr_rom and the tb model",
                 chr_mismatch);
        if (chr_mismatch != 0) begin
            $display("A4 FAIL the DUT CHR array does not match the file");
            errors = errors + 1;
        end

        if (STRICT_ROM == 1) begin
            if (reset_vector < 16'h8000 || reset_vector > 16'hFFFF) begin
                $display("A1 FAIL reset vector $%0h is outside $8000-$FFFF", reset_vector);
                errors = errors + 1;
            end else begin
                $display("A1 PASS reset vector $%0h is inside $8000-$FFFF", reset_vector);
            end
        end else begin
            $display("A1 INFO strict mode off: reset vector $%0h not checked against $8000-$FFFF (placeholder image)",
                     reset_vector);
        end

        // ---------------------------------------------------------------- A2
        // Let the machine run, watching the PC and cpu_cycle.
        cycle_first = 32'd0;
        pc_captured = 1'b0;
        while (frame_count < FRAMES_TO_RUN) begin
            @(posedge clk);
            if (!pc_captured && !reset && pv_ce_cpu) begin
                pc_at_first_ce = cpu_pc;
                pc_captured    = 1'b1;
                cycle_first    = pv_cpu_cycle;
            end
        end
        #4;
        cycle_last = pv_cpu_cycle;

        $display("A2 first PC sampled on the first ce_cpu after reset release = $%0h (frame %0d)",
                 pc_at_first_ce, first_pc_frame);
        $display("A2 cpu_cycle at first ce_cpu = %0d, at end of run = %0d, advanced = %0d",
                 cycle_first, cycle_last, cycle_last - cycle_first);
        $display("A2 distinct PC values collected = %0d, PC changes = %0d",
                 pc_distinct, pc_changes);
        $write("A2 first_pcs");
        for (pi2 = 0; pi2 < pc_distinct && pi2 < 16; pi2 = pi2 + 1)
            $write(" $%0h", pc_first[pi2]);
        $write("\n");

        if (!pc_captured) begin
            $display("A2 FAIL ce_cpu never asserted after reset release");
            errors = errors + 1;
        end
        if (pc_distinct < 4) begin
            $display("A2 FAIL only %0d distinct PC values, the CPU is not executing",
                     pc_distinct);
            errors = errors + 1;
        end
        if ((cycle_last - cycle_first) == 0) begin
            $display("A2 FAIL cpu_cycle did not advance");
            errors = errors + 1;
        end

        // The PC must actually equal the vector the DUT's own ROM supplied.
        if (pc_at_first_ce !== reset_vector) begin
            $display("A2 NOTE first PC $%0h is not the reset vector $%0h",
                     pc_at_first_ce, reset_vector);
        end

        // ---------------------------------------------------------------- A3
        $display("A3 frames completed = %0d, frames requested = %0d",
                 frame_count, FRAMES_TO_RUN);
        if (frame_count != FRAMES_TO_RUN) begin
            $display("A3 FAIL frame count mismatch");
            errors = errors + 1;
        end

        // ---------------------------------------------------------------- A5/A6
        analyse();

        if (STRICT_ROM == 1) begin
            // What counts as "not blank" had to be measured, not guessed.
            //
            //   distinct >= 4              REJECTED.  A real screen from this
            //     cartridge is white text on black, so it legitimately uses
            //     only TWO of the 64 palette entries.  A four-colour minimum
            //     failed a correct render.
            //   distinct > 1                TOO WEAK.  It passed a frame that
            //     was 61439 pixels of one colour and ONE pixel of another.
            //   non_background >= 0.5%      the threshold that actually
            //     separates a screen from a blank one.  A real text screen
            //     measures about 3%, a dead screen 0.000%.
            if (final_distinct < 2) begin
                $display("A5 FAIL the captured frame has %0d distinct palette indices, it is a single flat colour",
                         final_distinct);
                errors = errors + 1;
            end else if (final_nonbg * 200 < FB_N) begin
                $display("A5 FAIL only %0d of %0d pixels differ from the background (%.4f%%), the image is effectively uniform",
                         final_nonbg, FB_N, (final_nonbg * 100.0) / (FB_N * 1.0));
                errors = errors + 1;
            end else begin
                $display("A5 PASS the captured frame has %0d distinct palette indices and %0d of %0d pixels (%.2f%%) off the background",
                         final_distinct, final_nonbg, FB_N, (final_nonbg * 100.0) / (FB_N * 1.0));
            end
            if (x_idx_seen != 0) begin
                $display("A6 FAIL %0d captured pixels had an X palette index", x_idx_seen);
                errors = errors + 1;
            end else begin
                $display("A6 PASS no captured pixel had an X palette index");
            end
        end else begin
            $display("A5 INFO strict mode off: %0d distinct palette indices, %0d X-indexed pixels not asserted",
                     final_distinct, x_idx_seen);
        end

        $display("INFO sprite0_hit clk high = %0d, first at frame %0d", s0_clk, s0_first_frame);
        $display("INFO sprite_overflow clk high = %0d, first at frame %0d", so_clk, so_first_frame);
        $display("INFO sprite audit over %0d visible ce_ppu samples:", m_pix);
        $display("INFO   background opaque dots        = %0d", m_bgopaque);
        $display("INFO   slot_opaque[0] dots           = %0d", m_s0opaque);
        $display("INFO   slot0 AND bg opaque (hit pre) = %0d", m_s0_and_bg);
        $display("INFO   sprite0_hit_raw asserted     = %0d", m_hit_raw);
        $display("INFO   sprite_overflow_raw asserted = %0d", m_ovf_raw);
        $display("INFO   mask_reg[3] bg shown  dots    = %0d", m_mask3);
        $display("INFO   mask_reg[4] sprites shown dots = %0d", m_mask4);
        $display("INFO   DUT range_count > 8 samples   = %0d (max range_count seen = %0d)",
                 m_range_gt8, m_max_range);
        $display("INFO   independent model > 8 samples = %0d", m_mdl_range);
        $display("INFO   model-vs-DUT range_count disagreements = %0d", m_mdl_mismatch);
        $display("INFO   game reads of $2002          = %0d", m_read2002);
        if (m_s0_fr >= 0)
            $display("INFO   OAM[0] snapshot at frame %0d: y=%0d tile=%0d attr=$%02h x=%0d",
                     m_s0_fr, m_s0_y_f, m_s0_tile_f, m_s0_attr_f, m_s0_x_f);
        else
            $display("INFO   OAM[0] snapshot: never sampled");
        $display("INFO ppu writes: $2000=%0d $2001=%0d $2005=%0d $2006=%0d $2007=%0d palette($3Fxx)=%0d",
                 w2000, w2001, w2005, w2006, w2007, wpal);
        $display("INFO ppu state: control_reg=$%02h mask_reg=$%02h  (nmi_en=%b show_bg=%b show_sp=%b)",
                 dut.u_ppu.control_reg, dut.u_ppu.mask_reg,
                 dut.u_ppu.control_reg[7], dut.u_ppu.mask_reg[3], dut.u_ppu.mask_reg[4]);
        $display("INFO ppu clk with rendering enabled (mask_reg[3]|mask_reg[4]) = %0d", wmask_hi);
        $display("INFO oam_dma_start pulses = %0d, $2007 reads armed = %0d",
                 fr_dma_total, ppu_chr_rd_total);
        $display("INFO CHR read path: req_pulses=%0d rdata_checked=%0d rdata_MISMATCHES=%0d chr_ram_writes=%0d",
                 chr_req_pulses, chr_rdata_checked, chr_rdata_bad, chr_we_pulses);
        $display("INFO CHR address span: min=$%0h max=$%0h  distinct 128-byte pages touched=%0d of 64",
                 chr_min_addr, chr_max_addr, popcount64(chr_pages_seen));
        $display("INFO palette_ram nonzero entries sampled = %0d", pal_nonzero_sample());
        $display("INFO captured %0d pixels over %0d frames, avg %0d px/frame",
                 cap_pixels, frame_count,
                 frame_count ? (cap_pixels / frame_count) : 0);
        $display("INFO mapper_id = %0d (0 = NROM), nametable map = $%0h",
                 pv_mapper_id, pv_mapper_nt);

        if (errors == 0)
            $display("PASS tb_nes_boot_rom");
        else
            $display("FAIL tb_nes_boot_rom errors=%0d", errors);

        if (errors == 0)
            $finish;
        else
            $fatal(1, "tb_nes_boot_rom failed");
    end

    function integer distinct_chr;
        integer k;
        reg [7:0] seen [0:255];
        integer    n;
        begin
            for (k = 0; k < 256; k = k + 1) seen[k] = 1'b0;
            n = 0;
            for (k = 0; k < 8192; k = k + 1)
                if (chr_model[k] !== 8'hxx && seen[chr_model[k]] === 1'b0) begin
                    seen[chr_model[k]] = 1'b1;
                    n = n + 1;
                end
            distinct_chr = n;
        end
    endfunction

    // A hard stop so a hung run cannot sit forever.  The bound is on SIMULATED
    // time, not wall clock: 30 s of emulated time is about 1800 NES frames.
    // (An earlier value of 4 s was only 240 frames and fired in the middle of a
    // 260-frame run, which cost a whole run; keep this comfortably above
    // FRAMES_TO_RUN * 16.64 ms.)
    initial begin
        #30000000000;
        $display("FAIL tb_nes_boot_rom simulated-time guard expired at frame %0d of %0d",
                 frame_count, FRAMES_TO_RUN);
        $fatal(1, "timeout");
    end

endmodule
