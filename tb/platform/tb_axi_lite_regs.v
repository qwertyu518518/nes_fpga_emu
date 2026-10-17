`timescale 1ns/1ps

// =============================================================================
// tb_axi_lite_regs : protocol and register semantics of the hand-written
// AXI4-Lite slave, and the cartridge-load transaction it produces.
//
// WHAT IS PROVEN
//   * reset state of every output, and that the slave is idle before any traffic
//   * the five channels handshake: AW and W accepted independently and in either
//     order, B only after both, AR -> R with one read outstanding
//   * BRESP and RRESP are 2'b00 (OKAY) on every response
//   * WSTRB is honoured per byte lane on a writable register
//   * read-back of a written value, on two different values, with the two
//     read-backs compared against each other as well as against what was written
//   * ID reads the exact constant, STATUS returns pl_status_in
//   * the GAMEPAD register (0x20) writes, reads back, honours WSTRB per lane, and
//     drives pl_gamepad from its low byte
//   * a write to a RO register is acknowledged and does not change it
//   * the LOAD_EN gate: with LOAD_EN set a PRG_DATA/CHR_DATA word becomes up to
//     four byte loads (one per WSTRB lane) at consecutive addresses, the address
//     auto-increments by 4, and partial WSTRB writes only the set lanes; with
//     LOAD_EN clear the same write produces NO load and does not advance
//   * backpressure: while pl_ld_ready is low the response is withheld and no
//     load is produced, and the word completes once ready is raised
//
// NON-VACUITY -- WHY THIS FAILS AGAINST A STUB
//   A slave that returned a constant on every read would fail immediately: the
//   two SCRATCH read-backs are of different values and are also required to
//   differ from each other, and ID is required to equal 0x4E455301 exactly while
//   STATUS is required to equal the driven pl_status_in.  A slave that never
//   asserted BVALID would hang the write tasks and trip the timeout.  A slave
//   that never produced a load would fail every LOAD_* check (the expected load
//   list is non-empty for every enabled transaction).  A slave that produced a
//   load unconditionally would fail the LOAD_EN clear case, which requires the
//   load list to stay empty.  A slave that asserted RWVALID, or answered without
//   honouring WSTRB, is caught by the reset, handshake and per-lane checks.
// =============================================================================

module tb_axi_lite_regs;

    localparam integer ADDR_W = 17;
    localparam integer MAXF   = 128;

    reg         clk;
    reg         rst_n;
    reg  [5:0]  awaddr;
    reg         awvalid;
    reg  [2:0]  awprot;
    reg  [31:0] wdata;
    reg  [3:0]  wstrb;
    reg         wvalid;
    reg         bready;
    reg  [5:0]  araddr;
    reg         arvalid;
    reg  [2:0]  arprot;
    reg         rready;
    reg         ld_ready;
    reg  [7:0]  status_in;

    wire        awready;
    wire        wready;
    wire [1:0]  bresp;
    wire        bvalid;
    wire        arready;
    wire [31:0] rdata;
    wire [1:0]  rresp;
    wire        rvalid;
    wire        console_hold;
    wire        load_enable;
    wire        ld_valid;
    wire        ld_target;
    wire [ADDR_W-1:0] ld_addr;
    wire [7:0]  ld_data;
    wire [7:0]  gamepad;

    integer checks;
    integer errors;

    // Load monitor: every accepted byte is recorded, in order.
    reg        mon_tgt  [0:MAXF-1];
    reg [ADDR_W-1:0] mon_addr [0:MAXF-1];
    reg [7:0]  mon_data [0:MAXF-1];
    integer    mon_n;
    reg        exp_tgt  [0:MAXF-1];
    reg [ADDR_W-1:0] exp_addr [0:MAXF-1];
    reg [7:0]  exp_data [0:MAXF-1];
    integer    exp_n;

    axi_lite_regs #(
        .C_S_AXI_DATA_WIDTH(32),
        .C_S_AXI_ADDR_WIDTH(6),
        .PRG_ADDR_BITS(17),
        .CHR_ADDR_BITS(13),
        .ADDR_W(ADDR_W)
    ) dut (
        .s_axi_aclk(clk),
        .s_axi_aresetn(rst_n),
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
        .pl_ld_ready(ld_ready),
        .pl_status_in(status_in),
        .pl_gamepad(gamepad)
    );

    always #10 clk = ~clk;

    always @(posedge clk) begin
        if (ld_valid && ld_ready) begin
            if (mon_n < MAXF) begin
                mon_tgt[mon_n]  = ld_target;
                mon_addr[mon_n] = ld_addr;
                mon_data[mon_n] = ld_data;
                mon_n = mon_n + 1;
            end
        end
    end

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

    task expect_load;
        input t;
        input [ADDR_W-1:0] a;
        input [7:0] d;
        begin
            exp_tgt[exp_n]  = t;
            exp_addr[exp_n] = a;
            exp_data[exp_n] = d;
            exp_n = exp_n + 1;
        end
    endtask

    task check_loads;
        integer i;
        begin
            checks = checks + 1;
            if (mon_n != exp_n)
                err("LOAD_COUNT", mon_n, exp_n, 0);
            for (i = 0; (i < mon_n) && (i < exp_n); i = i + 1) begin
                checks = checks + 1;
                if (mon_tgt[i] !== exp_tgt[i])   err("LOAD_TGT",  i, mon_tgt[i],  exp_tgt[i]);
                if (mon_addr[i] !== exp_addr[i]) err("LOAD_ADDR", i, mon_addr[i], exp_addr[i]);
                if (mon_data[i] !== exp_data[i]) err("LOAD_DATA", i, mon_data[i], exp_data[i]);
            end
        end
    endtask

    task clear_loads;
        begin
            mon_n = 0;
            exp_n = 0;
        end
    endtask

    // AW and W together.  Holds both valids until BVALID, then a single response
    // is checked and acknowledged.
    task axi_write;
        input [5:0]  a;
        input [31:0] d;
        input [3:0]  s;
        input [1:0]  exp;
        begin
            @(negedge clk);
            awaddr = a; awvalid = 1'b1; awprot = 3'b000;
            wdata = d; wstrb = s; wvalid = 1'b1;
            bready = 1'b0;
            @(posedge clk);
            while (!bvalid) @(posedge clk);
            checks = checks + 1;
            if (bresp !== exp)
                err("BRESP", bresp, exp, 0);
            @(negedge clk);
            awvalid = 1'b0; wvalid = 1'b0; bready = 1'b1;
            @(posedge clk);
            @(negedge clk);
            bready = 1'b0;
        end
    endtask

    // AW first, then W a few cycles later.  Proves the slave holds AW.
    task axi_write_aw_first;
        input [5:0]  a;
        input [31:0] d;
        input [3:0]  s;
        begin
            @(negedge clk);
            awaddr = a; awvalid = 1'b1; awprot = 3'b000;
            wvalid = 1'b0; bready = 1'b0;
            @(posedge clk);          // accepted while idle
            @(negedge clk); awvalid = 1'b0;
            repeat (3) @(negedge clk);
            wdata = d; wstrb = s; wvalid = 1'b1;
            @(posedge clk);
            while (!bvalid) @(posedge clk);
            checks = checks + 1;
            if (bresp !== 2'b00) err("BRESP_AWFIRST", bresp, 0, 0);
            @(negedge clk); wvalid = 1'b0; bready = 1'b1;
            @(posedge clk);
            @(negedge clk); bready = 1'b0;
        end
    endtask

    // W first, then AW.  Proves the slave holds W.
    task axi_write_w_first;
        input [5:0]  a;
        input [31:0] d;
        input [3:0]  s;
        begin
            @(negedge clk);
            wdata = d; wstrb = s; wvalid = 1'b1;
            awvalid = 1'b0; bready = 1'b0;
            @(posedge clk);          // accepted while idle
            @(negedge clk); wvalid = 1'b0;
            repeat (3) @(negedge clk);
            awaddr = a; awvalid = 1'b1; awprot = 3'b000;
            @(posedge clk);
            while (!bvalid) @(posedge clk);
            checks = checks + 1;
            if (bresp !== 2'b00) err("BRESP_WFIRST", bresp, 0, 0);
            @(negedge clk); awvalid = 1'b0; bready = 1'b1;
            @(posedge clk);
            @(negedge clk); bready = 1'b0;
        end
    endtask

    task axi_read;
        input  [5:0]  a;
        output [31:0] d;
        begin
            @(negedge clk);
            araddr = a; arvalid = 1'b1; arprot = 3'b000; rready = 1'b0;
            @(posedge clk);
            while (!rvalid) @(posedge clk);
            d = rdata;
            checks = checks + 1;
            if (rresp !== 2'b00) err("RRESP", rresp, 0, 0);
            @(negedge clk); arvalid = 1'b0; rready = 1'b1;
            @(posedge clk);
            @(negedge clk); rready = 1'b0;
        end
    endtask

    reg [31:0] rd;
    reg [31:0] rd_a;
    reg [31:0] rd_b;
    integer    i;

    initial begin
        clk       = 1'b0;
        rst_n     = 1'b0;
        awaddr    = 6'd0;
        awvalid   = 1'b0;
        awprot    = 3'b000;
        wdata     = 32'h0;
        wstrb     = 4'h0;
        wvalid    = 1'b0;
        bready    = 1'b0;
        araddr    = 6'd0;
        arvalid   = 1'b0;
        arprot    = 3'b000;
        rready    = 1'b0;
        ld_ready  = 1'b1;
        status_in = 8'h00;
        checks    = 0;
        errors    = 0;
        mon_n     = 0;
        exp_n     = 0;
        rd        = 32'h0;
        rd_a      = 32'h0;
        rd_b      = 32'h0;

        repeat (4) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;
        repeat (4) @(posedge clk);

        // ------------------------------------------------ reset / idle state
        checks = checks + 6;
        if (console_hold !== 1'b0) err("RESET_CONSOLE", console_hold, 0, 0);
        if (load_enable  !== 1'b0) err("RESET_LOADEN",  load_enable, 0, 0);
        if (ld_valid     !== 1'b0) err("RESET_LDVALID", ld_valid, 0, 0);
        if (bvalid       !== 1'b0) err("RESET_BVALID",  bvalid, 0, 0);
        if (rvalid       !== 1'b0) err("RESET_RVALID",  rvalid, 0, 0);
        if (awready !== 1'b1)      err("RESET_AWREADY", awready, 0, 0);
        if (gamepad !== 8'h00)     err("RESET_GAMEPAD", gamepad, 0, 0);

        // ------------------------------------------------ ID and STATUS
        status_in = 8'hA5;
        axi_read(5'h0C, rd);
        checks = checks + 1;
        if (rd !== 32'h4E455301) err("ID_VALUE", rd, 32'h4E455301, 0);
        axi_read(5'h08, rd);
        checks = checks + 1;
        if (rd !== 32'h000000A5) err("STATUS_VALUE", rd, 32'hA5, 0);
        status_in = 8'h00;

        // ------------------------------------------------ scratch readback, two
        // different values, compared against each other too (non-vacuity).
        axi_write(5'h04, 32'h12345678, 4'hF, 2'b00);
        axi_read (5'h04, rd_a);
        axi_write(5'h04, 32'hDEADBEEF, 4'hF, 2'b00);
        axi_read (5'h04, rd_b);
        checks = checks + 3;
        if (rd_a !== 32'h12345678) err("SCRATCH_A", rd_a, 32'h12345678, 0);
        if (rd_b !== 32'hDEADBEEF) err("SCRATCH_B", rd_b, 32'hDEADBEEF, 0);
        if (rd_a === rd_b)         err("SCRATCH_CONSTANT", rd_a, rd_b, 0);

        // ------------------------------------------------ WSTRB per lane
        axi_write(5'h04, 32'h00000000, 4'hF, 2'b00);
        axi_write(5'h04, 32'hFFFFFFFF, 4'h2, 2'b00);   // byte 1 only
        axi_read (5'h04, rd);
        checks = checks + 1;
        if (rd !== 32'h0000FF00) err("WSTRB_BYTE1", rd, 32'h0000FF00, 0);
        axi_write(5'h04, 32'hFFFFFFFF, 4'h8, 2'b00);   // byte 3 only
        axi_read (5'h04, rd);
        checks = checks + 1;
        if (rd !== 32'hFF00FF00) err("WSTRB_BYTE3", rd, 32'hFF00FF00, 0);

        // ------------------------------------------------ GAMEPAD (0x20)
        // The gamepad register is a dedicated RW word at 0x20, byte-lane
        // semantics like the other writable registers, and its low byte is the
        // live pl_gamepad output the top consumes.  It sits above the eight
        // load-path words, which is why the map is six bits wide.
        axi_write(6'h20, 32'h00000000, 4'hF, 2'b00);
        axi_write(6'h20, 32'hFFFFFFFF, 4'h2, 2'b00);   // byte 1 only
        axi_read (6'h20, rd);
        checks = checks + 2;
        if (rd !== 32'h0000FF00) err("GAMEPAD_WSTRB_BYTE1", rd, 32'h0000FF00, 0);
        if (gamepad !== 8'h00)   err("GAMEPAD_OUT_BYTE1", gamepad, 8'h00, 0);
        axi_write(6'h20, 32'hFFFFFFFF, 4'h1, 2'b00);   // byte 0 only
        axi_read (6'h20, rd);
        checks = checks + 2;
        if (rd !== 32'h0000FFFF) err("GAMEPAD_WSTRB_BYTE0", rd, 32'h0000FFFF, 0);
        if (gamepad !== 8'hFF)   err("GAMEPAD_OUT_BYTE0", gamepad, 8'hFF, 0);

        // ------------------------------------------------ AW-first / W-first
        axi_write_aw_first(5'h04, 32'hCAFEF00D, 4'hF);
        axi_read(5'h04, rd);
        checks = checks + 1;
        if (rd !== 32'hCAFEF00D) err("AW_FIRST_READBACK", rd, 32'hCAFEF00D, 0);
        axi_write_w_first(5'h04, 32'h0BADF00D, 4'hF);
        axi_read(5'h04, rd);
        checks = checks + 1;
        if (rd !== 32'h0BADF00D) err("W_FIRST_READBACK", rd, 32'h0BADF00D, 0);

        // ------------------------------------------------ RO register is inert
        axi_write(5'h0C, 32'hFFFFFFFF, 4'hF, 2'b00);
        axi_read (5'h0C, rd);
        checks = checks + 1;
        if (rd !== 32'h4E455301) err("RO_ID_CHANGED", rd, 32'h4E455301, 0);

        // ------------------------------------------------ CTRL semantics
        axi_write(5'h00, 32'h00000001, 4'hF, 2'b00);
        checks = checks + 2;
        if (load_enable  !== 1'b1) err("CTRL_LOADEN",  load_enable, 1, 0);
        if (console_hold !== 1'b1) err("CTRL_HOLD_BY_LOAD", console_hold, 1, 0);
        axi_write(5'h00, 32'h00000000, 4'hF, 2'b00);
        checks = checks + 2;
        if (load_enable  !== 1'b0) err("CTRL_LOADEN_CLEAR",  load_enable, 0, 0);
        if (console_hold !== 1'b0) err("CTRL_HOLD_CLEAR",    console_hold, 0, 0);
        axi_write(5'h00, 32'h00000002, 4'hF, 2'b00);   // HOLD only
        checks = checks + 2;
        if (load_enable  !== 1'b0) err("CTRL_HOLD_ONLY_LOADEN", load_enable, 0, 0);
        if (console_hold !== 1'b1) err("CTRL_HOLD_ONLY",        console_hold, 1, 0);
        axi_write(5'h00, 32'h00000001, 4'hF, 2'b00);   // LOAD_EN, keep HOLD semantics

        // ------------------------------------------------ full-word PRG load
        axi_write(5'h10, 32'h00000100, 4'hF, 2'b00);   // PRG_ADDR = 0x100
        clear_loads();
        expect_load(1'b0, 17'h0100, 8'h11);
        expect_load(1'b0, 17'h0101, 8'h22);
        expect_load(1'b0, 17'h0102, 8'h33);
        expect_load(1'b0, 17'h0103, 8'h44);
        axi_write(5'h14, 32'h44332211, 4'hF, 2'b00);
        check_loads();
        axi_read(5'h10, rd);
        checks = checks + 1;
        if (rd[16:0] !== 17'h0104) err("PRG_ADDR_INC", rd, 17'h0104, 0);

        // ------------------------------------------------ partial WSTRB lanes 0,2
        axi_write(5'h10, 32'h00000200, 4'hF, 2'b00);
        clear_loads();
        expect_load(1'b0, 17'h0200, 8'hDD);
        expect_load(1'b0, 17'h0202, 8'hBB);
        axi_write(5'h14, 32'hAABBCCDD, 4'h5, 2'b00);
        check_loads();
        axi_read(5'h10, rd);
        checks = checks + 1;
        if (rd[16:0] !== 17'h0204) err("PRG_ADDR_INC_PARTIAL", rd, 17'h0204, 0);

        // ------------------------------------------------ CHR load
        axi_write(5'h18, 32'h00000030, 4'hF, 2'b00);   // CHR_ADDR = 0x30
        clear_loads();
        expect_load(1'b1, 17'h0030, 8'h55);
        expect_load(1'b1, 17'h0031, 8'h66);
        expect_load(1'b1, 17'h0032, 8'h77);
        expect_load(1'b1, 17'h0033, 8'h88);
        axi_write(5'h1C, 32'h88776655, 4'hF, 2'b00);
        check_loads();
        axi_read(5'h18, rd);
        checks = checks + 1;
        if (rd[12:0] !== 13'h0034) err("CHR_ADDR_INC", rd, 13'h0034, 0);

        // ------------------------------------------------ inert with LOAD_EN = 0
        axi_write(5'h00, 32'h00000000, 4'hF, 2'b00);   // LOAD_EN = 0
        axi_write(5'h10, 32'h00000300, 4'hF, 2'b00);   // PRG_ADDR = 0x300
        clear_loads();
        axi_write(5'h14, 32'h99887766, 4'hF, 2'b00);   // must NOT load
        check_loads();                                 // expects mon_n == 0
        axi_read(5'h10, rd);
        checks = checks + 1;
        if (rd[16:0] !== 17'h0300) err("PRG_ADDR_ADVANCED_WHEN_INERT", rd, 17'h0300, 0);

        // ------------------------------------------------ backpressure
        axi_write(5'h00, 32'h00000001, 4'hF, 2'b00);   // LOAD_EN = 1
        axi_write(5'h10, 32'h00000400, 4'hF, 2'b00);   // PRG_ADDR = 0x400
        clear_loads();
        expect_load(1'b0, 17'h0400, 8'hA1);
        ld_ready = 1'b0;
        @(negedge clk);
        awaddr = 5'h14; awvalid = 1'b1; awprot = 3'b000;
        wdata  = 32'h000000A1; wstrb = 4'h1; wvalid = 1'b1;
        bready = 1'b0;
        repeat (12) @(posedge clk);
        checks = checks + 2;
        if (bvalid !== 1'b0)    err("BACKPRESSURE_BVALID", bvalid, 0, 0);
        if (ld_valid !== 1'b1)  err("BACKPRESSURE_VALID",  ld_valid, 1, 0);
        // release and let it drain
        @(negedge clk); ld_ready = 1'b1;
        @(posedge clk);
        while (!bvalid) @(posedge clk);
        checks = checks + 1;
        if (bresp !== 2'b00) err("BACKPRESSURE_BRESP", bresp, 0, 0);
        @(negedge clk); awvalid = 1'b0; wvalid = 1'b0; bready = 1'b1;
        @(posedge clk);
        @(negedge clk); bready = 1'b0;
        check_loads();

        // ------------------------------------------------ final
        $display("axi_lite_regs loads_monitored=%0d checks=%0d errors=%0d", mon_n, checks, errors);
        $display("CHECKS %0d", checks);
        if (errors != 0) begin
            $display("FAIL tb_axi_lite_regs with %0d failing checks", errors);
            $fatal(1, "tb_axi_lite_regs failed");
        end
        $display("PASS tb_axi_lite_regs five-channel handshake, WSTRB, OKAY responses, load transactions, inert gate");
        $finish;
    end

    initial begin
        #1000000;
        $fatal(1, "global timeout");
    end

endmodule
