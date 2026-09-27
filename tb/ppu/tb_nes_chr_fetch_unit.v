`timescale 1ns/1ps

module tb_nes_chr_fetch_unit;

    localparam STEP = 10;
    localparam [5:0] WORST = 6'd33;
    localparam       WORST_REQ = 66;
    localparam [13:0] WORST_BASE = 14'd1024;
    localparam [13:0] WORST_LAST = WORST_BASE + 14'd520;

    reg         clk = 1'b0;
    reg         ce = 1'b0;
    reg         reset = 1'b0;
    reg         req_start = 1'b0;
    reg  [12:0] tile_base = 13'd0;
    reg  [5:0]  tile_count = 6'd0;
    wire [7:0]  chr_rdata;

    wire        chr_req;
    wire [13:0] chr_addr;
    wire [7:0]  bg_lo;
    wire [7:0]  bg_hi;
    wire        bg_valid;
    wire        busy;

    reg [7:0]  chr_mem [0:8191];
    reg [7:0]  mem_q = 8'd0;
    reg [13:0] mem_a_q = 14'd0;

    integer i;
    integer kk;
    integer cnt_req;
    integer prev_addr;
    integer beats = 0;
    reg [13:0] addr_d = 14'd0;
    reg [7:0]  s_bg_lo;
    reg [7:0]  s_bg_hi;
    reg [13:0] s_chr_addr;
    reg        s_chr_req;
    reg        s_bg_valid;
    reg        s_busy;
    reg [7:0]  r1_lo;
    reg [7:0]  r1_hi;

    nes_chr_fetch_unit dut (
        .clk(clk), .ce(ce), .reset(reset),
        .req_start(req_start), .tile_base(tile_base), .tile_count(tile_count),
        .chr_req(chr_req), .chr_addr(chr_addr), .chr_rdata(chr_rdata),
        .bg_lo(bg_lo), .bg_hi(bg_hi), .bg_valid(bg_valid), .busy(busy)
    );

    always #(STEP/2) clk = ~clk;

    always @(posedge clk) begin
        if (ce) begin
            mem_a_q <= chr_addr;
            mem_q   <= chr_mem[chr_addr[12:0]];
        end
    end

    assign chr_rdata = mem_q;

    always @(posedge clk) begin
        if (ce) begin
            addr_d <= chr_addr;
            if (!reset && chr_req) begin
                beats = beats + 1;
                if (chr_addr !== addr_d)
                    $fatal(1, "A4: chr_addr changed AT request beat %0d: now %0d, was %0d one ce earlier",
                           beats, chr_addr, addr_d);
            end
        end
    end

    task ce_pulse;
        begin
            ce = 1'b1;
            @(posedge clk);
            #1;
            ce = 1'b0;
        end
    endtask

    task run_row;
        input [12:0] b;
        input [5:0]  c;
        input        mid;
        input        frozen;
        begin
            ce = 1'b0;
            @(posedge clk);
            @(posedge clk);
            req_start  = 1'b1;
            tile_base  = b;
            tile_count = c;
            ce = 1'b1;
            #1;
            @(posedge clk);
            #1;
            if (busy !== 1'b1)     $fatal(1, "row tile_count=%0d did not start", c);
            if (bg_valid !== 1'b0) $fatal(1, "A7: bg_valid not cleared by req_start");
            if (mid) begin
                req_start  = 1'b1;
                tile_base  = 13'd6000;
                tile_count = 6'd2;
                @(posedge clk);
                #1;
                req_start  = 1'b0;
                tile_base  = b;
                tile_count = c;
            end else begin
                req_start = 1'b0;
            end
            if (frozen) begin
                s_chr_req = chr_req; s_chr_addr = chr_addr; s_bg_lo = bg_lo;
                s_bg_hi = bg_hi; s_bg_valid = bg_valid; s_busy = busy;
                ce = 1'b0;
                repeat (4) begin
                    @(posedge clk);
                    #1;
                    if (chr_req !== s_chr_req || chr_addr !== s_chr_addr || bg_lo !== s_bg_lo
                        || bg_hi !== s_bg_hi || bg_valid !== s_bg_valid || busy !== s_busy)
                        $fatal(1, "A5: state changed while ce=0");
                end
                ce = 1'b1;
                #1;
            end
            cnt_req = 0;
            prev_addr = -1;
            beats = 0;
            while (busy === 1'b1) begin
                @(posedge clk);
                #1;
                if (chr_req) begin
                    if (cnt_req == 0 && chr_addr !== b)
                        $fatal(1, "A2: first chr_addr %0d != tile_base %0d", chr_addr, b);
                    if (cnt_req > 0 && chr_addr !== prev_addr + 8)
                        $fatal(1, "A3: req %0d chr_addr %0d != prev+8 %0d", cnt_req, chr_addr, prev_addr+8);
                    if (cnt_req > 0 && chr_addr <= prev_addr)
                        $fatal(1, "A3: chr_addr not strictly increasing at req %0d", cnt_req);
                    if (cnt_req > 0) begin
                        kk = (cnt_req - 1) >> 1;
                        if (((cnt_req - 1) & 1) == 0) begin
                            if (bg_lo !== chr_mem[b + kk*16])
                                $fatal(1, "A3: tile %0d lo %02h != %02h", kk, bg_lo, chr_mem[b+kk*16]);
                        end else begin
                            if (bg_hi !== chr_mem[b + kk*16 + 8])
                                $fatal(1, "A3: tile %0d hi %02h != %02h", kk, bg_hi, chr_mem[b+kk*16+8]);
                        end
                    end
                    prev_addr = chr_addr;
                    cnt_req = cnt_req + 1;
                end
            end
            if (cnt_req != 2*c)
                $fatal(1, "A2: chr_req count %0d != %0d for tile_count=%0d", cnt_req, 2*c, c);
            if (bg_valid !== 1'b1) $fatal(1, "A2: bg_valid not held after row done");
            if (bg_lo !== chr_mem[b + (c-1)*16])
                $fatal(1, "A3: last tile lo %02h != %02h", bg_lo, chr_mem[b+(c-1)*16]);
            if (bg_hi !== chr_mem[b + (c-1)*16 + 8])
                $fatal(1, "A3: last tile hi %02h != %02h", bg_hi, chr_mem[b+(c-1)*16+8]);
        end
    endtask

    initial begin
        for (i = 0; i < 8192; i = i + 1) chr_mem[i] = i[7:0] ^ 8'h5A;

        ce = 1'b0;
        reset = 1'b1;
        ce_pulse;
        reset = 1'b0;
        ce_pulse;

        if (chr_req !== 1'b0)  $fatal(1, "A1: chr_req not 0 after reset");
        if (bg_valid !== 1'b0) $fatal(1, "A1: bg_valid not 0 after reset");
        if (busy !== 1'b0)     $fatal(1, "A1: busy not 0 after reset");
        $display("A1 reset clean: chr_req=%b bg_valid=%b busy=%b chr_addr=%0d",
                 chr_req, bg_valid, busy, chr_addr);

        run_row(13'd0, 6'd1, 1'b0, 1'b0);
        if (bg_lo === 8'hxx || bg_hi === 8'hxx) $fatal(1, "A2: plane never latched");
        $display("A2 tile_count=1: chr_req x%0d addrs 0,%0d bg_lo=%02h bg_hi=%02h bg_valid=%b",
                 cnt_req, prev_addr, bg_lo, bg_hi, bg_valid);

        run_row(WORST_BASE[12:0], WORST, 1'b0, 1'b0);
        if (cnt_req != WORST_REQ)
            $fatal(1, "A3: worst row chr_req count %0d != %0d for tile_count=%0d",
                   cnt_req, WORST_REQ, WORST);
        if (prev_addr !== WORST_LAST)
            $fatal(1, "A3: worst row last chr_addr %0d != base+520 %0d", prev_addr, WORST_LAST);
        $display("A3 worst row tile_count=%0d: chr_req x%0d addrs %0d..%0d (base+0..base+520), all %0d low/high pairs match CHR model",
                 WORST, cnt_req, tile_base, prev_addr, WORST);
        $display("A4 chr_addr already correct one ce before all %0d request beats", beats);

        run_row(13'd3072, 6'd4, 1'b0, 1'b1);
        $display("A5 ce=0 for 4 clk mid-row: all outputs frozen, row still completed with %0d reqs", cnt_req);

        run_row(13'd0, WORST, 1'b1, 1'b0);
        $display("A6 mid-row req_start ignored: still %0d reqs, last addr %0d, bg_valid=%b",
                 cnt_req, prev_addr, bg_valid);

        run_row(13'd4096, 6'd4, 1'b0, 1'b0);
        r1_lo = bg_lo;
        r1_hi = bg_hi;
        if (bg_valid !== 1'b1) $fatal(1, "A7: bg_valid not held after row1");
        run_row(13'd5120, 6'd2, 1'b0, 1'b0);
        if (r1_lo === bg_lo && r1_hi === bg_hi) $fatal(1, "A7: row2 data identical to row1");
        $display("A7 bg_valid cleared on 2nd start; row1(4@4096) last=%02h/%02h row2(2@5120) last=%02h/%02h, no bleed",
                 r1_lo, r1_hi, bg_lo, bg_hi);

        ce = 1'b0;
        @(posedge clk);
        @(posedge clk);
        req_start  = 1'b1;
        tile_base  = 13'd6000;
        tile_count = 6'd6;
        ce = 1'b1;
        #1;
        repeat (9) begin
            @(posedge clk);
            #1;
        end
        req_start = 1'b0;
        if (busy !== 1'b1) $fatal(1, "A8: row did not start");
        reset = 1'b1;
        ce_pulse;
        reset = 1'b0;
        if (chr_req !== 1'b0 || bg_valid !== 1'b0 || busy !== 1'b0)
            $fatal(1, "A8: reset mid-fetch left req=%b valid=%b busy=%b", chr_req, bg_valid, busy);
        $display("A8 reset mid-fetch cleared state: chr_req=%b bg_valid=%b busy=%b", chr_req, bg_valid, busy);
        run_row(13'd6144, 6'd3, 1'b0, 1'b0);
        $display("A8 next row after reset works: chr_req x%0d bg_lo=%02h bg_hi=%02h", cnt_req, bg_lo, bg_hi);

        $display("PASS nes_chr_fetch_unit");
        $finish;
    end

    initial begin
        #200000;
        $fatal(1, "TB timeout");
    end

endmodule
