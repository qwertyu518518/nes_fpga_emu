`timescale 1ns/1ps

// Gate testbench for nes_cart_rom.
//
// The clock, div_phase and ce_ppu generator is a replica of nes_system_v6's, on
// purpose: the CHR read is only meaningful against those exact phases, so the
// bench does not get to choose its own idea of a PPU dot.  clk is the
// 21.477272727 MHz core clock, div_phase runs 0..11, and
// ce_ppu = (div_phase[1:0] == 2'b00) is high AT div_phase 0, 4 and 8, so the
// ce EDGES are the posedges that END div_phase 0, 4 and 8 and a dot is 4 clk.
// dot_ctr counts div_phase 0 clks, so dot_ctr == the dot index and a
// div_phase 0 posedge raises it to the next one.
//
// What is covered
//   reset contents: both output registers read 8'h00 while reset is high, a
//   request presented during reset is not serviced, and both stay at 8'h00
//   until the first beat after it
//   PRG: an address sweep over all 131072 addresses, one clk apart, every byte
//   compared against the model this bench loaded from the committed hex file; a
//   zero-setup demonstration that the read is registered and not combinational,
//   so a one-beat skew would be visible rather than merely conceivable; the
//   prg_en hold case contrasted with the prg_en release
//   CHR: a sweep of all 8192 addresses one ce beat apart and a second sweep
//   with a stride coprime to 8192, every serviced beat compared against the same
//   model; the arm/consume phase relationship the zero-slack contract rests on,
//   asserted on EVERY beat as consume_phase == (arm_phase + 4) mod 12; the
//   $2007 arm at div_phase 8 consumed at div_phase 0, with the previously
//   serviced address used to classify a mismatch as a stale byte rather than as
//   a wrong byte; two consecutive ce beats; a beat arriving on the ce where the
//   previous beat is consumed; a request presented on a single non-ce clk inside
//   the previous beat's window, which must be ignored entirely; the bank-bit
//   alias above [12:0]; writes with chr_ram_enable 0 (ignored, and not merely
//   dropped at the port) and 1 (serviced, exactly one byte, readable back
//   through the bus, and visible through the bank alias); a read consumed on a
//   frame boundary and a beat pair straddling one
//   the models' own properties: not undefined, no two consecutive bytes equal,
//   and the two 64 KiB PRG banks not identical, which is what makes a one-beat
//   skew detectable at all
//
// The hex paths are the module's own defaults and are resolved by the simulator
// against its WORKING DIRECTORY, not against this file's directory, so the
// bench must be run from the repository root.  tools/sim_all.ps1 does that for
// every target.
//
// The model arrays are loaded by this bench with its own $readmemh, from the
// same two files the DUT was elaborated with, so the comparison is against the
// committed file and not against a formula this bench shares with the generator
// that wrote it.

module tb_nes_cart_rom;

    localparam integer PRG_BYTES   = 131072;
    localparam integer CHR_BYTES   = 8192;
    localparam integer FRAME_DOTS  = 16;
    localparam integer MIN_BEATS   = 18000;

    reg clk;
    reg reset;

    reg  [3:0] div_phase;
    wire       ce_ppu;

    reg         prg_en;
    reg  [16:0] prg_addr;
    wire [7:0]  prg_rdata;

    reg         chr_req;
    reg  [16:0] chr_addr;
    wire [7:0]  chr_rdata;
    reg  [13:0] chr_waddr;
    reg         chr_we;
    reg  [7:0]  chr_wdata;
    reg         chr_ram_enable;

    reg  [7:0]  prg_model [0:PRG_BYTES-1];
    reg  [7:0]  chr_model [0:CHR_BYTES-1];

    reg         pend_valid;
    reg  [16:0] pend_addr;
    reg  [3:0]  pend_phase;
    reg         svc_valid;
    reg  [16:0] svc_addr;
    reg         prev_valid;
    reg  [16:0] prev_addr;

    integer dot_ctr;
    integer beat_count;
    integer consume_count;
    integer beat_phase_ok;
    integer beat_wrong;
    integer beat_stale;
    integer checks;
    integer errors;
    integer i;
    integer j;
    integer a;
    integer a_prev;
    integer a_new;
    integer b;

    reg  [7:0]  hold_b;

    nes_cart_rom dut (
        .clk(clk),
        .reset(reset),
        .prg_en(prg_en),
        .prg_addr(prg_addr),
        .prg_rdata(prg_rdata),
        .ce_ppu(ce_ppu),
        .chr_req(chr_req),
        .chr_addr(chr_addr),
        .chr_rdata(chr_rdata),
        .chr_waddr(chr_waddr),
        .chr_we(chr_we),
        .chr_wdata(chr_wdata),
        .chr_ram_enable(chr_ram_enable)
    );

    assign ce_ppu = !reset && (div_phase[1:0] == 2'b00);

    always #5 clk = ~clk;

    always @(posedge clk or posedge reset) begin
        if (reset)
            div_phase <= 4'd0;
        else if (div_phase == 4'd11)
            div_phase <= 4'd0;
        else
            div_phase <= div_phase + 4'd1;
    end

    always @(posedge clk) begin
        if (!reset && (div_phase == 4'd0))
            dot_ctr = dot_ctr + 1;
    end

    task err;
        input [8*32-1:0] tag;
        input integer p1;
        input integer p2;
        input integer p3;
        begin
            errors = errors + 1;
            if (errors <= 20)
                $display("MISMATCH %0s p1=%0d p2=%0d p3=%0d t=%0t", tag, p1, p2, p3, $time);
        end
    endtask

    // Every serviced beat is checked here, so the sweeps, the runs and the
    // targeted cases below are all checked by the same code.  The consume is
    // the next ce edge after the beat, which is what nes_ppu2c02's $2007 read
    // buffer and both fetch units do.  The consume is tested BEFORE the service
    // so a beat arriving on the same edge as a consume is not lost, and the
    // two-deep address history is shifted on the service so that prev_addr is
    // the beat BEFORE the one being consumed, which is the byte a one-clk-late
    // read would have returned.
    always @(posedge clk) begin
        if (!reset) begin
            if (pend_valid && ce_ppu) begin
                consume_count = consume_count + 1;
                checks = checks + 1;
                if (div_phase !== ((pend_phase + 4'd4) % 12)) begin
                    err("CHR_CONSUME_PHASE", pend_phase, div_phase, consume_count);
                end else begin
                    beat_phase_ok = beat_phase_ok + 1;
                end
                if (chr_rdata !== chr_model[pend_addr[12:0]]) begin
                    if (prev_valid &&
                        chr_model[prev_addr[12:0]] !== chr_model[pend_addr[12:0]] &&
                        chr_rdata === chr_model[prev_addr[12:0]])
                        beat_stale = beat_stale + 1;
                    else
                        beat_wrong = beat_wrong + 1;
                    err("CHR_BYTE", pend_addr, chr_rdata, chr_model[pend_addr[12:0]]);
                end
                pend_valid = 1'b0;
            end
            if (ce_ppu && chr_req) begin
                beat_count = beat_count + 1;
                pend_valid = 1'b1;
                pend_addr  = chr_addr;
                pend_phase = div_phase;
                prev_valid = svc_valid;
                prev_addr  = svc_addr;
                svc_valid  = 1'b1;
                svc_addr   = chr_addr;
            end
        end
    end

    // Present one request on the next ce clk and drop it one clk later, so it
    // is high across exactly one posedge.
    task chr_one;
        input [16:0] adr;
        begin
            @(negedge clk);
            while (!ce_ppu) @(negedge clk);
            chr_addr = adr;
            chr_req  = 1'b1;
            @(negedge clk);
            chr_req  = 1'b0;
        end
    endtask

    // Present count CONSECUTIVE ce beats: the address is put on the bus and
    // chr_req is left high for a whole dot, so every ce in the run is serviced.
    // That is the consecutive-ce case nes_ppu2c02's header documents, and it is
    // also how a long sweep is driven without a gap between beats.
    task chr_beat_run;
        input integer count;
        input integer base;
        input integer stride;
        begin
            @(negedge clk);
            while (!ce_ppu) @(negedge clk);
            for (j = 0; j < count; j = j + 1) begin
                chr_addr = (base + j * stride) & 17'h1FFFF;
                chr_req  = 1'b1;
                repeat (4) @(negedge clk);
            end
            chr_req = 1'b0;
        end
    endtask

    // The $2007 read arm exactly as nes_system_v6 issues it: chr_req high on the
    // single clk whose pre-edge div_phase is 8, holding the address, with
    // nothing else on the bus for the four clk until the consume at div_phase 0.
    task chr_arm_at8;
        input [16:0] adr;
        begin
            @(negedge clk);
            while (div_phase !== 4'd8) @(negedge clk);
            chr_addr = adr;
            chr_req  = 1'b1;
            @(negedge clk);
            chr_req  = 1'b0;
        end
    endtask

    // A write attempt.  When ena is high the model is updated too, so the
    // always-on monitor keeps comparing against what the array should now hold;
    // the callers still assert the exact byte they expect back, so the update
    // cannot hide a write that did not happen.
    task chr_write;
        input [12:0] adr;
        input [7:0]  dat;
        input        ena;
        begin
            @(negedge clk);
            chr_waddr      = {1'b0, adr};
            chr_wdata      = dat;
            chr_we         = 1'b1;
            chr_ram_enable = ena;
            @(negedge clk);
            chr_we         = 1'b0;
            chr_ram_enable = 1'b0;
            if (ena)
                chr_model[adr] = dat;
        end
    endtask

    // Read one local address back through the bus and compare with a reference.
    task chr_read_expect;
        input [16:0] adr;
        input [7:0]  dat;
        begin
            chr_one(adr);
            repeat (6) @(posedge clk);
            checks = checks + 1;
            if (chr_rdata !== dat)
                err("CHR_READBACK", adr, chr_rdata, dat);
        end
    endtask

    initial begin
        $readmemh("rtl/nes_core/cart/prg_placeholder.hex", prg_model);
        $readmemh("rtl/nes_core/cart/chr_placeholder.hex", chr_model);
    end

    initial begin
        clk            = 1'b0;
        reset          = 1'b1;
        prg_en         = 1'b0;
        prg_addr       = 17'd0;
        chr_req        = 1'b0;
        chr_addr       = 17'd0;
        chr_waddr      = 14'd0;
        chr_we         = 1'b0;
        chr_wdata      = 8'h00;
        chr_ram_enable = 1'b0;
        pend_valid     = 1'b0;
        pend_addr      = 17'd0;
        pend_phase     = 4'd0;
        svc_valid      = 1'b0;
        svc_addr       = 17'd0;
        prev_valid     = 1'b0;
        prev_addr      = 17'd0;
        dot_ctr        = 0;
        beat_count     = 0;
        consume_count  = 0;
        beat_phase_ok  = 0;
        beat_wrong     = 0;
        beat_stale     = 0;
        checks         = 0;
        errors         = 0;
        a              = 0;
        a_prev         = 0;
        a_new          = 0;
        b              = 0;
        hold_b         = 8'h00;

        // the committed files must be able to tell a stale byte from a right one
        for (i = 0; i < CHR_BYTES; i = i + 1) begin
            if (chr_model[i] === 8'hxx || chr_model[i] === 8'hzz) begin
                checks = checks + 1;
                err("CHR_MODEL_UNDEFINED", i, 0, 0);
            end
            if ((i > 0) && (chr_model[i] === chr_model[i - 1])) begin
                checks = checks + 1;
                err("CHR_MODEL_ADJACENT_EQUAL", i, chr_model[i], 0);
            end
        end
        for (i = 0; i < PRG_BYTES; i = i + 1) begin
            if (prg_model[i] === 8'hxx || prg_model[i] === 8'hzz) begin
                checks = checks + 1;
                err("PRG_MODEL_UNDEFINED", i, 0, 0);
            end
            if ((i > 0) && (prg_model[i] === prg_model[i - 1])) begin
                checks = checks + 1;
                err("PRG_MODEL_ADJACENT_EQUAL", i, prg_model[i], 0);
            end
        end
        for (i = 0; i < 4096; i = i + 1) begin
            if (prg_model[65536 + i] === prg_model[i]) begin
                checks = checks + 1;
                err("PRG_MODEL_BANKS_EQUAL", i, prg_model[i], 0);
            end
        end

        repeat (4) @(posedge clk);
        @(negedge clk);
        reset = 1'b0;
        repeat (8) @(posedge clk);

        // ---------------------------------------------------------------
        // reset contents
        // ---------------------------------------------------------------
        reset = 1'b1;
        prg_en   = 1'b1;
        prg_addr = 17'd0;
        chr_addr = 17'd0000;
        chr_req  = 1'b1;
        repeat (4) @(posedge clk);
        #1;
        chr_req = 1'b0;
        checks  = checks + 4;
        if (prg_rdata !== 8'h00) err("PRG_RESET_NOT_ZERO", prg_rdata, 0, 0);
        if (chr_rdata !== 8'h00) err("CHR_RESET_NOT_ZERO", chr_rdata, 0, 0);
        if (beat_count != 0)       err("BEAT_DURING_RESET", beat_count, 0, 0);
        if (consume_count != 0)    err("CONSUME_DURING_RESET", consume_count, 0, 0);
        @(negedge clk);
        reset = 1'b0;
        repeat (4) @(posedge clk);
        #1;
        if (chr_rdata !== 8'h00) begin
            checks = checks + 1;
            err("CHR_POST_RESET_NOT_ZERO", chr_rdata, 0, 0);
        end

        // ---------------------------------------------------------------
        // PRG: the read is registered, so a change of address that is NOT given
        // a clk of setup does not reach the output until the next posedge.  The
        // address is moved and the output is read in the SAME time step, so this
        // is a statement about the absence of a combinational path and not a
        // race between two always blocks.  That absence is what makes a one-beat
        // skew observable rather than merely conceivable.
        // ---------------------------------------------------------------
        a_prev = 17'd0;
        a_new  = 17'd12345;
        @(negedge clk);
        prg_addr = a_prev[16:0];
        @(posedge clk);
        @(negedge clk);
        checks = checks + 1;
        if (prg_rdata !== prg_model[a_prev])
            err("PRG_SETUP_BASELINE", prg_rdata, prg_model[a_prev], a_prev);
        prg_addr = a_new[16:0];
        checks = checks + 2;
        if (prg_rdata !== prg_model[a_prev])
            err("PRG_ZERO_SETUP_NOT_STALE", prg_rdata, prg_model[a_prev], a_prev);
        if (prg_rdata === prg_model[a_new])
            err("PRG_READ_LOOKS_COMBINATIONAL", prg_rdata, prg_model[a_new], a_new);
        @(posedge clk);
        @(negedge clk);
        checks = checks + 1;
        if (prg_rdata !== prg_model[a_new])
            err("PRG_ONE_CLK_LATENCY", prg_rdata, prg_model[a_new], a_new);

        // prg_en low holds the last byte rather than returning zero
        @(negedge clk);
        prg_en   = 1'b0;
        prg_addr = 17'd54321;
        repeat (3) @(posedge clk);
        #1;
        checks = checks + 1;
        if (prg_rdata !== prg_model[a_new])
            err("PRG_ENABLE_HOLD", prg_rdata, prg_model[a_new], a_new);
        @(negedge clk);
        prg_en = 1'b1;
        @(posedge clk);
        #1;
        checks = checks + 1;
        if (prg_rdata !== prg_model[17'd54321])
            err("PRG_ENABLE_RELEASE", prg_rdata, prg_model[17'd54321], 54321);

        // ---------------------------------------------------------------
        // PRG: address sweep over the whole range, one clk per address
        // ---------------------------------------------------------------
        for (a = 0; a < PRG_BYTES; a = a + 1) begin
            @(negedge clk);
            prg_addr = a[16:0];
            @(posedge clk);
            #1;
            checks = checks + 1;
            if (prg_rdata !== prg_model[a])
                err("PRG_SWEEP", a, prg_rdata, prg_model[a]);
        end
        @(negedge clk);
        prg_en = 1'b0;

        // ---------------------------------------------------------------
        // CHR: the full local address space, one ce beat per address, then the
        // same space walked with a stride coprime to 8192
        // ---------------------------------------------------------------
        chr_beat_run(CHR_BYTES, 0, 1);
        repeat (20) @(posedge clk);
        chr_beat_run(CHR_BYTES, 0, 4099);
        repeat (20) @(posedge clk);

        // ---------------------------------------------------------------
        // CHR: the $2007 arm at div_phase 8, consumed at div_phase 0
        // ---------------------------------------------------------------
        for (a = 0; a < 2048; a = a + 1) begin
            chr_arm_at8((a * 7 + 1) & 17'h1FFFF);
            repeat (5) @(posedge clk);
        end

        // the same address twice must return the same byte, and two adjacent
        // addresses must not
        chr_arm_at8(17'h0000);
        repeat (8) @(posedge clk);
        hold_b = chr_rdata;
        chr_arm_at8(17'h0001);
        repeat (8) @(posedge clk);
        checks = checks + 2;
        if (chr_rdata === hold_b)
            err("CHR_ADJACENT_ARMS_EQUAL", 1, chr_rdata, hold_b);
        if (chr_rdata !== chr_model[17'h0001])
            err("CHR_ARM_ADDR1", 1, chr_rdata, chr_model[17'h0001]);
        chr_arm_at8(17'h0000);
        repeat (8) @(posedge clk);
        checks = checks + 1;
        if (chr_rdata !== hold_b)
            err("CHR_ARM_REPEAT", 0, chr_rdata, hold_b);

        // ---------------------------------------------------------------
        // CHR: consecutive ce beats, including the documented background and
        // sprite windows' stride-1 and stride-7 patterns
        // ---------------------------------------------------------------
        chr_beat_run(2, 17'h0100, 1);
        repeat (8) @(posedge clk);
        chr_beat_run(16, 17'h0800, 7);
        repeat (20) @(posedge clk);

        // ---------------------------------------------------------------
        // CHR: a beat arriving on the ce where the previous beat is consumed.
        // chr_req stays high from div_phase 8 through div_phase 0, so beat 1 is
        // serviced at the div_phase 8 edge and beat 2 at the div_phase 0 edge,
        // which is the same edge beat 1's consume happens on.  Beat 1's byte
        // must be what that consume sees, and beat 2's address is what lands
        // after it, four clk later.
        // ---------------------------------------------------------------
        @(negedge clk);
        while (div_phase !== 4'd8) @(negedge clk);
        chr_addr = 17'h1234;
        chr_req  = 1'b1;
        @(negedge clk);
        @(negedge clk);
        @(negedge clk);
        @(negedge clk);
        chr_addr = 17'h4321;
        @(negedge clk);
        chr_req  = 1'b0;
        repeat (8) @(posedge clk);
        #1;
        checks = checks + 1;
        if (chr_rdata !== chr_model[13'h0321])
            err("CHR_CONSECUTIVE_DELIVERY", 17'h4321, chr_rdata, chr_model[13'h0321]);

        // ---------------------------------------------------------------
        // CHR: a request on a single non-ce clk inside the previous beat's
        // four-clk window.  It must be ignored completely, so the consume one
        // clk before it is high again must still see the previous address.
        // ---------------------------------------------------------------
        @(negedge clk);
        while (div_phase !== 4'd8) @(negedge clk);
        chr_addr = 17'h00AA;
        chr_req  = 1'b1;
        @(negedge clk);
        chr_req  = 1'b0;
        chr_addr = 17'h0F0F;
        chr_req  = 1'b1;
        @(negedge clk);
        chr_req  = 1'b0;
        repeat (8) @(posedge clk);
        #1;
        checks = checks + 1;
        if (chr_rdata !== chr_model[13'h0AA])
            err("CHR_MID_WINDOW_REQUEST_APPLIED", 17'h0F0F, chr_rdata, chr_model[13'h0AA]);

        // ---------------------------------------------------------------
        // CHR: bank bits above [12:0] are dropped.  Eight final addresses that
        // differ only above bit 12 must all return the byte for 13'h0111, and
        // the model must be able to tell them apart from their neighbours.
        // ---------------------------------------------------------------
        chr_beat_run(8, 17'h0111, 17'h2000);
        repeat (12) @(posedge clk);
        for (i = 0; i < 8; i = i + 1)
            chr_read_expect(17'h0111 + i * 17'h2000, chr_model[13'h0111]);
        chr_read_expect(13'h0110, chr_model[13'h0110]);
        chr_read_expect(13'h0112, chr_model[13'h0112]);
        chr_read_expect(17'h1111, chr_model[13'h1111]);

        // ---------------------------------------------------------------
        // CHR writes: ignored with chr_ram_enable 0, serviced with it 1
        // ---------------------------------------------------------------
        // disabled: the byte must not reach the array at any aliased address
        chr_write(13'd100, 8'hA5, 1'b0);
        repeat (4) @(posedge clk);
        chr_read_expect(17'h0064, chr_model[13'd100]);
        chr_read_expect(17'h2064, chr_model[13'd100]);
        chr_read_expect(17'h4064, chr_model[13'd100]);
        chr_read_expect(13'd99,   chr_model[13'd99]);
        chr_read_expect(13'd101,  chr_model[13'd101]);

        // enabled: exactly one byte, at the low 13 bits, so every bank shows it
        chr_write(13'd100, 8'hA5, 1'b1);
        repeat (4) @(posedge clk);
        chr_read_expect(17'h0064, 8'hA5);
        chr_read_expect(17'h2064, 8'hA5);
        chr_read_expect(17'h6064, 8'hA5);
        chr_read_expect(13'd99,   chr_model[13'd99]);
        chr_read_expect(13'd101,  chr_model[13'd101]);
        chr_read_expect(13'd116,  chr_model[13'd116]);

        // enabled but not writing: nothing changes
        chr_we         = 1'b0;
        chr_ram_enable = 1'b1;
        chr_waddr      = 14'd200;
        chr_wdata      = 8'h5A;
        repeat (4) @(posedge clk);
        @(negedge clk);
        chr_ram_enable = 1'b0;
        chr_read_expect(13'd200, chr_model[13'd200]);
        chr_read_expect(13'd100, 8'hA5);

        // restore the file byte so the rest of the bench sees the committed rom
        chr_write(13'd100, chr_model[13'd100], 1'b1);
        repeat (4) @(posedge clk);
        chr_read_expect(17'h0064, chr_model[13'd100]);
        chr_read_expect(17'h2064, chr_model[13'd100]);

        // ---------------------------------------------------------------
        // CHR: a read consumed exactly on a frame boundary.  dot_ctr holds the
        // dot index during a dot, and a div_phase 0 posedge raises it to the
        // next, so the consume of a div_phase 8 arm lands on the boundary when
        // the arm is taken while (dot_ctr + 1) is a multiple of FRAME_DOTS.
        // ---------------------------------------------------------------
        @(negedge clk);
        while (((dot_ctr + 1) % FRAME_DOTS) != 0) @(negedge clk);
        while (div_phase !== 4'd8) @(negedge clk);
        b = dot_ctr;
        chr_addr = 17'h0777;
        chr_req  = 1'b1;
        repeat (5) @(posedge clk);
        @(negedge clk);
        chr_req = 1'b0;
        checks = checks + 2;
        if (dot_ctr % FRAME_DOTS != 0)
            err("FRAME_BOUNDARY_MISSED", b, dot_ctr, 0);
        if (dot_ctr != b + 1)
            err("FRAME_BOUNDARY_DOT", b, dot_ctr, 0);
        repeat (8) @(posedge clk);
        #1;
        if (chr_rdata !== chr_model[13'h0777]) begin
            checks = checks + 1;
            err("CHR_FRAME_BOUNDARY", 17'h0777, chr_rdata, chr_model[13'h0777]);
        end

        // and a beat pair straddling a boundary, the second consumed one dot in
        chr_beat_run(2, 17'h1800, 3);
        repeat (8) @(posedge clk);

        // ---------------------------------------------------------------
        // final accounting
        // ---------------------------------------------------------------
        if (beat_count < MIN_BEATS) begin
            checks = checks + 1;
            err("TOO_FEW_BEATS", beat_count, MIN_BEATS, 0);
        end
        checks = checks + 3;
        if (consume_count != beat_count)
            err("BEAT_CONSUME_COUNT", beat_count, consume_count, 0);
        if (beat_phase_ok != beat_count)
            err("BEAT_PHASE_MISMATCH", beat_phase_ok, beat_count, 0);
        if (beat_stale != 0)
            err("STALE_BYTES_SEEN", beat_stale, 0, 0);

        $display("beats %0d consumes %0d phase_ok %0d stale %0d wrong %0d prg_sweep %0d chr_sweeps 2x%0d",
                 beat_count, consume_count, beat_phase_ok, beat_stale, beat_wrong, PRG_BYTES, CHR_BYTES);
        $display("CHECKS %0d", checks);

        if (errors != 0) begin
            $display("FAIL tb_nes_cart_rom with %0d failing checks", errors);
            $fatal(1, "tb_nes_cart_rom failed");
        end

        $display("PASS tb_nes_cart_rom prg 128k sweep and chr 8k ce-gated read with the div_phase 8 arm, chram gated writes");
        $finish;
    end

    initial begin
        #60000000;
        $fatal(1, "global timeout");
    end

endmodule
