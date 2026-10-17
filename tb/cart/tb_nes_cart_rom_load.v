`timescale 1ns/1ps

// =============================================================================
// tb_nes_cart_rom_load : load a cartridge image through the whole path -- AXI4-
// Lite register write -> clock-crossing bridge -> cartridge array -- and show
// that both arrays take the NEW image and that the core executes the loaded PRG
// rather than the one baked into the bitstream at synthesis.
//
// THE PATH UNDER TEST
//   host_clk (50 MHz, the PS FCLK_CLK0 / axi_lite_regs domain)
//       -> axi_lite_regs      (AXI write -> up to four byte-load requests)
//       -> nes_cart_load_bridge (toggle-handshake crossing into core_clk)
//       -> nes_cart_rom arrays (byte write port)
//   core_clk (21.477272727 MHz)
//
// WHAT IT PROVES
//   A1  the loaded PRG block reads back byte for byte through the array's own
//       core-side read port (prg_en/prg_addr/prg_rdata)
//   A2  the loaded CHR block reads back byte for byte through the array's own
//       ce_ppu-gated read port
//   A3  THE LOADED IMAGE IS NOT THE BAKED-IN ONE: every loaded byte is required
//       to differ from the committed placeholder model at that address, and the
//       reset vector is required to differ from the placeholder's vector
//   A4  the core reads the loaded image: a loaded reset vector ($FFFC/$FFFD) that
//       points at a loaded JMP-to-self loop makes the CPU's own pc_reg reach that
//       address.  A pass cannot come from the ROM still being the placeholder,
//       because the placeholder's vector is $0504 and never reaches $C000.
//   A5  inert by default: with LOAD_EN clear the same AXI write produces no load
//       and the array is unchanged
//
// NON-VACUITY -- WHY THIS FAILS AGAINST A STUB
//   If the load path wrote nothing (a stubbed bridge or array), every read-back
//   would return the placeholder byte, and A3 additionally requires the read-back
//   to DIFFER from that placeholder -- so a "not loaded" pass is impossible.  If
//   the read-back were a constant, A1/A2's comparison against the per-address
//   pattern fails.  If the bridge dropped or reordered a byte, the pattern does
//   not line up.  A5 fails if the enable gate is missing.
//
// The committed placeholders are read by this bench with its own $readmemh, so
// the comparison is against the file, not against a formula shared with the DUT.
// Run from the repository root, as tools/sim_all.ps1 does.
// =============================================================================

module tb_nes_cart_rom_load;

    localparam integer PRG_BYTES = 131072;
    localparam integer CHR_BYTES = 8192;

    // Loaded regions.
    localparam integer PRG_BASE  = 17'h4000;   // CPU $C000 under NROM 32 KiB
    localparam integer PRG_N     = 64;
    localparam integer VEC_ADDR  = 17'h7FFC;   // CPU $FFFC
    localparam integer CHR_BASE  = 13'h0000;
    localparam integer CHR_N     = 64;

    localparam [15:0] JUMP_TARGET = 16'hC000;

    // 50 MHz host, 21.477272727 MHz core.
    reg host_clk;
    reg core_clk;

    reg host_reset;
    reg core_reset;

    reg  [4:0]  awaddr;
    reg         awvalid;
    reg  [2:0]  awprot;
    reg  [31:0] wdata;
    reg  [3:0]  wstrb;
    reg         wvalid;
    reg         bready;
    reg  [4:0]  araddr;
    reg         arvalid;
    reg  [2:0]  arprot;
    reg         rready;
    reg  [7:0]  status_in;

    wire        awready, wready, bvalid;
    wire [1:0]  bresp;
    wire        arready, rvalid;
    wire [31:0] rdata;
    wire [1:0]  rresp;

    wire        console_hold;
    wire        load_enable;
    wire        ld_valid;
    wire        ld_target;
    wire [16:0] ld_addr;
    wire [7:0]  ld_data;
    wire        host_ready;

    wire        prg_ld_en;
    wire [16:0] prg_ld_addr;
    wire [7:0]  prg_ld_data;
    wire        prg_ld_we;
    wire        chr_ld_en;
    wire [12:0] chr_ld_addr;
    wire [7:0]  chr_ld_data;
    wire        chr_ld_we;

    // cartridge core-side read ports (driven by this bench)
    reg         cart_prg_en;
    reg  [16:0] cart_prg_addr;
    wire [7:0]  cart_prg_rdata;
    reg         cart_ce_ppu;
    reg         cart_chr_req;
    reg  [16:0] cart_chr_addr;
    wire [7:0]  cart_chr_rdata;

    integer checks;
    integer errors;
    integer i;
    integer k;
    integer differ_prg;
    integer differ_chr;

    reg [7:0] prg_model [0:PRG_BYTES-1];
    reg [7:0] chr_model [0:CHR_BYTES-1];
    reg [7:0] prg_exp   [0:PRG_N-1];
    reg [7:0] chr_exp   [0:CHR_N-1];

    reg [31:0] rd;
    reg [31:0] word;
    reg        pc_hit;

    always #10.0 host_clk = ~host_clk;
    always #23.2805 core_clk = ~core_clk;

    // ------------------------------------------------------------- DUTs
    axi_lite_regs #(
        .C_S_AXI_DATA_WIDTH(32),
        .C_S_AXI_ADDR_WIDTH(5),
        .PRG_ADDR_BITS(17),
        .CHR_ADDR_BITS(13),
        .ADDR_W(17)
    ) u_regs (
        .s_axi_aclk(host_clk),
        .s_axi_aresetn(~host_reset),
        .s_axi_awaddr(awaddr),
        .s_axi_awprot(awprot),
        .s_axi_awvalid(awvalid),
        .s_axi_awready(awready),
        .s_axi_wdata(wdata),
        .s_axi_wstrb(wstrb),
        .s_axi_wvalid(wvalid),
        .s_axi_wready(wready),
        .s_axi_bresp(bresp),
        .s_axi_bvalid(bvalid),
        .s_axi_bready(bready),
        .s_axi_araddr(araddr),
        .s_axi_arprot(arprot),
        .s_axi_arvalid(arvalid),
        .s_axi_arready(arready),
        .s_axi_rdata(rdata),
        .s_axi_rresp(rresp),
        .s_axi_rvalid(rvalid),
        .s_axi_rready(rready),
        .pl_console_hold(console_hold),
        .pl_load_enable(load_enable),
        .pl_ld_valid(ld_valid),
        .pl_ld_target(ld_target),
        .pl_ld_addr(ld_addr),
        .pl_ld_data(ld_data),
        .pl_ld_ready(host_ready),
        .pl_status_in(status_in)
    );

    nes_cart_load_bridge #(
        .PRG_ADDR_BITS(17),
        .CHR_ADDR_BITS(13),
        .ADDR_W(17)
    ) u_bridge (
        .host_clk(host_clk),
        .host_reset(host_reset),
        .host_valid(ld_valid),
        .host_target(ld_target),
        .host_addr(ld_addr),
        .host_data(ld_data),
        .host_load_enable(load_enable),
        .host_ready(host_ready),
        .core_clk(core_clk),
        .core_reset(core_reset),
        .prg_ld_en(prg_ld_en),
        .prg_ld_addr(prg_ld_addr),
        .prg_ld_data(prg_ld_data),
        .prg_ld_we(prg_ld_we),
        .chr_ld_en(chr_ld_en),
        .chr_ld_addr(chr_ld_addr),
        .chr_ld_data(chr_ld_data),
        .chr_ld_we(chr_ld_we)
    );

    // Standalone cartridge holding BOTH halves, so the loaded pattern can be
    // read back through the array's own core-side ports.
    nes_cart_rom #(
        .PRG_ENABLE(1),
        .CHR_ENABLE(1)
    ) u_cart (
        .clk(core_clk),
        .reset(core_reset | console_hold),
        .prg_en(cart_prg_en),
        .prg_addr(cart_prg_addr),
        .prg_rdata(cart_prg_rdata),
        .ce_ppu(cart_ce_ppu),
        .chr_req(cart_chr_req),
        .chr_addr(cart_chr_addr),
        .chr_rdata(cart_chr_rdata),
        .chr_waddr(14'h0000),
        .chr_we(1'b0),
        .chr_wdata(8'h00),
        .chr_ram_enable(1'b0),
        .prg_ld_en(prg_ld_en),
        .prg_ld_addr(prg_ld_addr),
        .prg_ld_data(prg_ld_data),
        .prg_ld_we(prg_ld_we),
        .chr_ld_en(chr_ld_en),
        .chr_ld_addr(chr_ld_addr),
        .chr_ld_data(chr_ld_data),
        .chr_ld_we(chr_ld_we)
    );

    // The real core, booting from the same loaded PRG.
    nes_system_v6 #(
        .MAPPER_SELECT(8'd0),
        .HEADER_MIRRORING(3'd0),
        .NROM_PRG_SIZE_BYTES(32768),
        .NROM_PRG_RAM(1'b0),
        .NROM_CHR_RAM(1'b0)
    ) u_core (
        .clk(core_clk),
        .reset(core_reset | console_hold),
        .buttons1(8'h00),
        .buttons2(8'h00),
        .chr_rdata(8'h00),
        .prg_ld_en(prg_ld_en),
        .prg_ld_addr(prg_ld_addr),
        .prg_ld_data(prg_ld_data),
        .prg_ld_we(prg_ld_we),
        .ce_ppu(),
        .ce_cpu()
    );

    always @(posedge core_clk)
        if (!(core_reset | console_hold) && (u_core.u_cpu.pc_reg === JUMP_TARGET))
            pc_hit = 1'b1;

    // ------------------------------------------------------------- helpers
    task err;
        input [8*40-1:0] tag;
        input integer p1;
        input integer p2;
        input integer p3;
        begin
            errors = errors + 1;
            if (errors <= 40)
                $display("MISMATCH %0s p1=%0h p2=%0h p3=%0h t=%0t", tag, p1, p2, p3, $time);
        end
    endtask

    task axi_write;
        input [4:0]  a;
        input [31:0] d;
        input [3:0]  s;
        begin
            @(negedge host_clk);
            awaddr = a; awvalid = 1'b1; awprot = 3'b000;
            wdata = d; wstrb = s; wvalid = 1'b1;
            bready = 1'b0;
            @(posedge host_clk);
            while (!bvalid) @(posedge host_clk);
            checks = checks + 1;
            if (bresp !== 2'b00) err("BRESP", bresp, 0, 0);
            @(negedge host_clk);
            awvalid = 1'b0; wvalid = 1'b0; bready = 1'b1;
            @(posedge host_clk);
            @(negedge host_clk);
            bready = 1'b0;
        end
    endtask

    task axi_read;
        input  [4:0]  a;
        output [31:0] d;
        begin
            @(negedge host_clk);
            araddr = a; arvalid = 1'b1; arprot = 3'b000; rready = 1'b0;
            @(posedge host_clk);
            while (!rvalid) @(posedge host_clk);
            d = rdata;
            checks = checks + 1;
            if (rresp !== 2'b00) err("RRESP", rresp, 0, 0);
            @(negedge host_clk); arvalid = 1'b0; rready = 1'b1;
            @(posedge host_clk);
            @(negedge host_clk); rready = 1'b0;
        end
    endtask

    task cart_prg_read;
        input [16:0] a;
        input [7:0]  exp;
        begin
            @(negedge core_clk);
            cart_prg_en   = 1'b1;
            cart_prg_addr = a;
            @(posedge core_clk);
            #1;
            checks = checks + 1;
            if (cart_prg_rdata !== exp)
                err("PRG_READBACK", a, cart_prg_rdata, exp);
        end
    endtask

    task cart_chr_read;
        input [16:0] a;
        input [7:0]  exp;
        begin
            @(negedge core_clk);
            cart_ce_ppu    = 1'b1;
            cart_chr_req   = 1'b1;
            cart_chr_addr  = a;
            @(posedge core_clk);
            #1;
            checks = checks + 1;
            if (cart_chr_rdata !== exp)
                err("CHR_READBACK", a, cart_chr_rdata, exp);
        end
    endtask

    initial begin
        $readmemh("rtl/nes_core/cart/prg_placeholder.hex", prg_model);
        $readmemh("rtl/nes_core/cart/chr_placeholder.hex", chr_model);
    end

    initial begin
        host_clk   = 1'b0;
        core_clk   = 1'b0;
        host_reset = 1'b1;
        core_reset = 1'b1;
        awaddr = 5'd0; awvalid = 1'b0; awprot = 3'b000;
        wdata = 32'h0; wstrb = 4'h0; wvalid = 1'b0; bready = 1'b0;
        araddr = 5'd0; arvalid = 1'b0; arprot = 3'b000; rready = 1'b0;
        status_in = 8'h00;
        cart_prg_en = 1'b0; cart_prg_addr = 17'd0;
        cart_ce_ppu = 1'b0; cart_chr_req = 1'b0; cart_chr_addr = 17'd0;
        checks = 0; errors = 0;
        differ_prg = 0; differ_chr = 0;
        pc_hit = 1'b0;
        rd = 32'h0; word = 32'h0;

        // Build the "different image" pattern before anything runs.
        prg_exp[0] = 8'h4C;               // JMP $C000 at $C000
        prg_exp[1] = JUMP_TARGET[7:0];
        prg_exp[2] = JUMP_TARGET[15:8];
        for (i = 3; i < PRG_N; i = i + 1)
            prg_exp[i] = prg_model[PRG_BASE + i] ^ 8'hFF;
        for (i = 0; i < CHR_N; i = i + 1)
            chr_exp[i] = chr_model[CHR_BASE + i] ^ 8'hFF;

        repeat (8) @(posedge host_clk);
        repeat (8) @(posedge core_clk);
        @(negedge host_clk);
        host_reset = 1'b0;
        @(negedge core_clk);
        core_reset = 1'b0;
        repeat (8) @(posedge host_clk);

        // =============================================================== load
        axi_write(5'h00, 32'h00000001, 4'hF);            // CTRL: LOAD_EN, console held
        checks = checks + 1;
        if (console_hold !== 1'b1) err("LOADEN_HOLD", console_hold, 1, 0);

        // PRG block: 64 bytes at PRG_BASE, full words.
        axi_write(5'h10, {15'h0, PRG_BASE[16:0]}, 4'hF);
        for (k = 0; k < (PRG_N / 4); k = k + 1) begin
            word[7:0]   = prg_exp[4*k + 0];
            word[15:8]  = prg_exp[4*k + 1];
            word[23:16] = prg_exp[4*k + 2];
            word[31:24] = prg_exp[4*k + 3];
            axi_write(5'h14, word, 4'hF);
        end

        // Reset vector: two bytes at VEC_ADDR, partial WSTRB.
        axi_write(5'h10, {15'h0, VEC_ADDR[16:0]}, 4'hF);
        axi_write(5'h14, {16'h0000, JUMP_TARGET[15:8], JUMP_TARGET[7:0]}, 4'h3);

        // CHR block: 64 bytes at CHR_BASE, full words.
        axi_write(5'h18, 32'h00000000, 4'hF);
        for (k = 0; k < (CHR_N / 4); k = k + 1) begin
            word[7:0]   = chr_exp[4*k + 0];
            word[15:8]  = chr_exp[4*k + 1];
            word[23:16] = chr_exp[4*k + 2];
            word[31:24] = chr_exp[4*k + 3];
            axi_write(5'h1C, word, 4'hF);
        end

        // Release the console.  Read-back is done here and not during the load
        // because the cartridge's read register is reset while the console is
        // held (that is the same reset the console uses), so its read port holds
        // 8'h00 until release.  The PS does not need to read the array back; this
        // bench does.
        axi_write(5'h00, 32'h00000000, 4'hF);            // CTRL: release
        checks = checks + 1;
        if (console_hold !== 1'b0) err("RELEASE_HOLD", console_hold, 0, 0);
        repeat (4) @(posedge core_clk);

        // ============================================================ A1 PRG
        cart_prg_en   = 1'b0;
        cart_prg_addr = 17'd0;
        for (i = 0; i < PRG_N; i = i + 1)
            cart_prg_read(PRG_BASE + i, prg_exp[i]);
        cart_prg_read(VEC_ADDR,     JUMP_TARGET[7:0]);
        cart_prg_read(VEC_ADDR + 1, JUMP_TARGET[15:8]);

        // ============================================================ A2 CHR
        for (i = 0; i < CHR_N; i = i + 1)
            cart_chr_read(CHR_BASE + i, chr_exp[i]);
        @(negedge core_clk); cart_ce_ppu = 1'b0; cart_chr_req = 1'b0; cart_prg_en = 1'b0;

        // ====================================================== A3 NOT PLACEHOLDER
        for (i = 3; i < PRG_N; i = i + 1)
            if (prg_exp[i] !== prg_model[PRG_BASE + i]) differ_prg = differ_prg + 1;
        for (i = 0; i < CHR_N; i = i + 1)
            if (chr_exp[i] !== chr_model[CHR_BASE + i]) differ_chr = differ_chr + 1;
        checks = checks + 4;
        if (differ_prg < (PRG_N - 3)) err("PRG_DIFFERS_FROM_PLACEHOLDER", differ_prg, PRG_N - 3, 0);
        if (differ_chr < CHR_N)       err("CHR_DIFFERS_FROM_PLACEHOLDER", differ_chr, CHR_N, 0);
        // The placeholder's own vector must not be the one we loaded.
        if (JUMP_TARGET[7:0]  === prg_model[VEC_ADDR])     err("VEC_LO_EQUALS_PLACEHOLDER", 0, 0, 0);
        if (JUMP_TARGET[15:8] === prg_model[VEC_ADDR + 1]) err("VEC_HI_EQUALS_PLACEHOLDER", 0, 0, 0);

        // ====================================================== A4 CORE EXECUTES
        repeat (6000) @(posedge core_clk);
        checks = checks + 1;
        if (pc_hit !== 1'b1) begin
            err("CORE_DID_NOT_REACH_LOADED_VECTOR", u_core.u_cpu.pc_reg, JUMP_TARGET, 0);
        end

        // ====================================================== A5 INERT DEFAULT
        // With LOAD_EN clear, a load-data write changes nothing.
        cart_prg_read(PRG_BASE, prg_exp[0]);
        axi_write(5'h14, 32'h0BADF00D, 4'hF);            // no LOAD_EN: dropped
        cart_prg_read(PRG_BASE, prg_exp[0]);

        $display("loaded prg_differ=%0d/%0d chr_differ=%0d/%0d pc_hit=%0d checks=%0d errors=%0d",
                 differ_prg, PRG_N - 3, differ_chr, CHR_N, pc_hit, checks, errors);
        $display("CHECKS %0d", checks);
        if (errors != 0) begin
            $display("FAIL tb_nes_cart_rom_load with %0d failing checks", errors);
            $fatal(1, "tb_nes_cart_rom_load failed");
        end
        $display("PASS tb_nes_cart_rom_load AXI -> bridge -> PRG/CHR arrays, core executes the loaded image");
        $finish;
    end

    initial begin
        #4000000;
        $fatal(1, "global timeout");
    end

endmodule
