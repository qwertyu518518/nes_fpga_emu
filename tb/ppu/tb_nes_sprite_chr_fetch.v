`timescale 1ns/1ps

module tb_nes_sprite_chr_fetch;

    localparam STEP = 10;

    reg          clk = 1'b0;
    reg          ce = 1'b0;
    reg          reset = 1'b0;
    reg          start = 1'b0;
    reg  [103:0] pat_addr = 104'd0;
    wire         chr_req;
    wire [13:0]  chr_addr;
    wire [7:0]   chr_rdata;
    wire [127:0] shadow;
    wire         shadow_valid;
    wire         busy;

    reg  [7:0]   chr_mem [0:8191];
    reg  [7:0]   mem_q = 8'd0;
    reg  [12:0]  mem_a_q = 13'd0;

    reg  [12:0]  pats [0:39];
    reg  [103:0] cur_pat = 104'd0;
    reg  [13:0]  exp_addr [0:15], obs_addr [0:15];
    reg  [7:0]   exp_byte [0:15];
    reg  [127:0] exp_shadow = 128'd0, r_shadow = 128'd0, r1_shadow = 128'd0;
    reg  [127:0] sh_d = 128'd0, f_sh = 128'd0;
    reg  [13:0]  addr_d = 14'd0, f_addr = 14'd0;
    reg          req_d = 1'b0, f_req = 1'b0, f_sv = 1'b0, f_busy = 1'b0;
    reg          wrap_seen = 1'b0, mid_seen = 1'b0;
    integer t, m, n, cnt_req, req_rise, grab_cnt, since;

    nes_sprite_chr_fetch dut (
        .clk(clk), .ce(ce), .reset(reset), .start(start), .pat_addr(pat_addr),
        .chr_req(chr_req), .chr_addr(chr_addr), .chr_rdata(chr_rdata),
        .shadow(shadow), .shadow_valid(shadow_valid), .busy(busy)
    );

    always #(STEP/2) clk = ~clk;

    always @(posedge clk) begin
        if (ce) begin
            mem_a_q <= chr_addr[12:0];
            mem_q   <= chr_mem[mem_a_q];
        end
    end

    assign chr_rdata = mem_q;

    task set_expected;
        input [103:0] pa;
        reg   [12:0] f13;
        reg   [16:0] wide;
        reg   [13:0] lo, hi;
        integer m2, n2, off;
        begin
            exp_shadow = 128'd0;
            for (m2 = 0; m2 < 16; m2 = m2 + 1) begin
                f13  = pa[(m2 >> 1) * 13 +: 13];
                wide = {1'b0, f13, 3'b000};
                lo   = wide[13:0];
                hi   = (lo + 14'd64) & 14'h3FFF;
                off  = (m2 >> 1) * 16 + (m2[0] ? 8 : 0);
                exp_addr[m2] = m2[0] ? hi : lo;
                exp_byte[m2] = chr_mem[exp_addr[m2][12:0]];
                exp_shadow[off +: 8] = exp_byte[m2];
                if (hi < lo) wrap_seen = 1'b1;
            end
            for (m2 = 0; m2 < 16; m2 = m2 + 1)
                for (n2 = m2 + 1; n2 < 16; n2 = n2 + 1)
                    if (exp_byte[m2] === exp_byte[n2])
                        $fatal(1, "A4: fill aliases bytes %0d/%1d at %02h (addrs %04h/%04h)",
                               m2, n2, exp_byte[m2], exp_addr[m2], exp_addr[n2]);
            for (m2 = 0; m2 < 16; m2 = m2 + 1) begin
                off = (m2 >> 1) * 16 + (m2[0] ? 8 : 0);
                if (exp_shadow[off +: 8] === shadow[off +: 8])
                    $fatal(1, "A9: byte %0d new value %02h equals stale shadow slice, write invisible",
                           m2, exp_byte[m2]);
            end
        end
    endtask

    task run_fetch;
        input integer s;
        input integer frz;
        input integer inj_on;
        input integer act;
        input        midchk;
        reg froze, injected, inj;
        begin
            for (m = 0; m < 8; m = m + 1) cur_pat[m*13 +: 13] = pats[s*8+m];
            set_expected(cur_pat);
            ce = 1'b0;
            @(posedge clk);
            @(posedge clk);
            pat_addr = cur_pat;
            start = 1'b1;
            ce = 1'b1;
            #1;
            @(posedge clk);
            #1;
            start = 1'b0;
            if (busy !== 1'b1) $fatal(1, "A2: set%0d start not accepted, busy=%b", s, busy);
            if (shadow_valid !== 1'b0) $fatal(1, "A2/A7: set%0d start did not clear shadow_valid", s);
            cnt_req = 0; req_rise = 0; grab_cnt = 0; since = 0;
            req_d = chr_req; sh_d = shadow; addr_d = chr_addr;
            froze = 1'b0; injected = 1'b0;
            while (busy === 1'b1) begin
                inj = inj_on && !injected && (cnt_req == act);
                if (inj) begin
                    injected = 1'b1;
                    pat_addr = {8{13'h1FFF}};
                    start = 1'b1;
                end
                @(posedge clk);
                #1;
                start = 1'b0;
                if (ce) begin
                    if (chr_req) begin
                        cnt_req = cnt_req + 1;
                        if (cnt_req > 16) $fatal(1, "A2: set%0d chr_req #%0d exceeds 16", s, cnt_req);
                        if (chr_addr !== addr_d) $fatal(1, "A2: set%0d req %0d addr %04h not held from prev ce (%04h)", s, cnt_req, chr_addr, addr_d);
                        if (cnt_req > 1 && since != 1) $fatal(1, "A2: set%0d req %0d after %0d idle ce, want 1", s, cnt_req, since);
                        obs_addr[cnt_req-1] = chr_addr;
                        if (chr_addr !== exp_addr[cnt_req-1]) $fatal(1, "A3: set%0d req %0d addr %04h != expected %04h", s, cnt_req, chr_addr, exp_addr[cnt_req-1]);
                    end
                    if (chr_req && !req_d) req_rise = req_rise + 1;
                    if (shadow !== sh_d) grab_cnt = grab_cnt + 1;
                    if (chr_req) since = 0; else since = since + 1;
                    addr_d = chr_addr;
                    req_d = chr_req;
                    sh_d = shadow;
                    if (inj && busy !== 1'b1) $fatal(1, "A6: set%0d busy dropped on ignored start", s);
                    if (midchk && cnt_req == 8) begin
                        if (shadow === r1_shadow) $fatal(1, "A7: set%0d row1 shadow intact mid row2", s);
                        mid_seen = 1'b1;
                    end
                    if (frz != 0 && !froze && cnt_req == frz) begin
                        froze = 1'b1;
                        f_req = chr_req; f_addr = chr_addr; f_sh = shadow; f_sv = shadow_valid; f_busy = busy;
                        ce = 1'b0;
                        repeat (4) begin
                            @(posedge clk);
                            #1;
                            if (chr_req !== f_req || chr_addr !== f_addr || shadow !== f_sh
                                || shadow_valid !== f_sv || busy !== f_busy)
                                $fatal(1, "A5: set%0d output changed while ce=0", s);
                        end
                        ce = 1'b1;
                        #1;
                    end
                end
            end
            if (cnt_req != 16)  $fatal(1, "A2: set%0d chr_req count %0d != 16", s, cnt_req);
            if (req_rise != 16) $fatal(1, "A9: set%0d chr_req rising edges %0d != 16", s, req_rise);
            if (grab_cnt != 16) $fatal(1, "A9: set%0d chr_rdata samples %0d != 16", s, grab_cnt);
            if (shadow_valid !== 1'b1) $fatal(1, "A4: set%0d shadow_valid=%b", s, shadow_valid);
            if (busy !== 1'b0) $fatal(1, "A4: set%0d busy=%b", s, busy);
            if (shadow !== exp_shadow) $fatal(1, "A4: set%0d shadow %032h != expected %032h", s, shadow, exp_shadow);
            r_shadow = shadow;
            repeat (6) begin
                @(posedge clk);
                #1;
                if (chr_req !== 1'b0) $fatal(1, "A10: set%0d chr_req high after completion", s);
                if (shadow !== r_shadow) $fatal(1, "A10: set%0d shadow changed after completion", s);
                if (shadow_valid !== 1'b1) $fatal(1, "A10: set%0d shadow_valid dropped after completion", s);
            end
            $display("     set%0d done: chr_req x%0d, rise %0d, rdata samples %0d, addr0=%04h addr15=%04h",
                     s, cnt_req, req_rise, grab_cnt, obs_addr[0], obs_addr[15]);
        end
    endtask

    initial begin
        for (t = 0; t < 8192; t = t + 1)
            chr_mem[t] = ((t / 8) % 256) ^ 8'hA5 ^ (t % 8);
        for (t = 0; t < 1024; t = t + 1)
            for (m = 0; m < 8; m = m + 1)
                chr_mem[(t * 8 + 64) % 8192 + m] = (t % 256) ^ 8'h5A ^ m;

        pats[0*8+0]=13'd0;    pats[0*8+1]=13'd340;  pats[0*8+2]=13'd1408; pats[0*8+3]=13'd216;
        pats[0*8+4]=13'd1459; pats[0*8+5]=13'd114;  pats[0*8+6]=13'd2041; pats[0*8+7]=13'd511;
        pats[1*8+0]=13'd657;  pats[1*8+1]=13'd2042; pats[1*8+2]=13'd1068; pats[1*8+3]=13'd700;
        pats[1*8+4]=13'd1566; pats[1*8+5]=13'd865;  pats[1*8+6]=13'd706;  pats[1*8+7]=13'd1705;
        pats[2*8+0]=13'd344;  pats[2*8+1]=13'd1782; pats[2*8+2]=13'd2043; pats[2*8+3]=13'd262;
        pats[2*8+4]=13'd1507; pats[2*8+5]=13'd1500; pats[2*8+6]=13'd272;  pats[2*8+7]=13'd32;
        pats[3*8+0]=13'd291;  pats[3*8+1]=13'd1687; pats[3*8+2]=13'd1057; pats[3*8+3]=13'd2044;
        pats[3*8+4]=13'd737;  pats[3*8+5]=13'd1301; pats[3*8+6]=13'd549;  pats[3*8+7]=13'd676;
        pats[4*8+0]=13'd320;  pats[4*8+1]=13'd589;  pats[4*8+2]=13'd317;  pats[4*8+3]=13'd746;
        pats[4*8+4]=13'd2045; pats[4*8+5]=13'd973;  pats[4*8+6]=13'd47;   pats[4*8+7]=13'd579;

        ce = 1'b1;
        reset = 1'b1;
        @(posedge clk);
        #1;
        reset = 1'b0;
        ce = 1'b0;
        if (chr_req !== 1'b0)       $fatal(1, "A1: chr_req not 0 after reset");
        if (shadow_valid !== 1'b0)  $fatal(1, "A1: shadow_valid not 0 after reset");
        if (busy !== 1'b0)          $fatal(1, "A1: busy not 0 after reset");
        $display("A1  reset clean: chr_req=%b shadow_valid=%b busy=%b chr_addr=%04h",
                 chr_req, shadow_valid, busy, chr_addr);

        run_fetch(0, 0, 0, 0, 1'b0);
        $display("A2  set0: chr_req exactly 16 times, one pulse every 2 ce, 1 ce wide, no extra/lost pulse");
        $write("A3  set0 observed addrs:");
        for (m = 0; m < 16; m = m + 1) $write(" %04h", obs_addr[m]);
        $display("");
        $display("A3  all 16 equal the spec sequence: slot0 %04h/%04h, slot6 %04h/%04h (14-bit wrap), slot7 %04h/%04h, wrap_seen=%b",
                 exp_addr[0], exp_addr[1], exp_addr[12], exp_addr[13], exp_addr[14], exp_addr[15], wrap_seen);
        $write("A4  set0 observed shadow bytes lo/hi per slot:");
        for (n = 0; n < 8; n = n + 1) $write(" %02h/%02h", shadow[n*16 +: 8], shadow[n*16+8 +: 8]);
        $display("");
        $display("A4  all 16 bytes equal the CHR model, shadow_valid=%b busy=%b", shadow_valid, busy);

        run_fetch(1, 3, 0, 0, 1'b0);
        $display("A5  ce=0 for 4 clk at req %0d: all outputs frozen, row still finished with %0d reqs",
                 3, cnt_req);

        run_fetch(2, 0, 1, 4, 1'b0);
        $display("A6  start while busy=1 ignored: still %0d reqs, addr15=%04h, shadow intact (%b)",
                 cnt_req, obs_addr[15], (shadow === r_shadow));

        run_fetch(3, 0, 0, 0, 1'b0);
        r1_shadow = r_shadow;
        run_fetch(4, 0, 0, 0, 1'b1);
        if (!mid_seen) $fatal(1, "A7: row2 never observed mid-flight");
        if (shadow === r1_shadow) $fatal(1, "A7: row2 shadow identical to row1");
        if (shadow[7:0] === r1_shadow[7:0]) $fatal(1, "A7: row1 slot0 survived row2");
        $display("A7  row1 slot0 %02h -> row2 slot0 %02h, shadow_valid cleared on 2nd start, mid row2 already replaced (%b), no bleed",
                 r1_shadow[7:0], shadow[7:0], mid_seen);

        for (m = 0; m < 8; m = m + 1) cur_pat[m*13 +: 13] = pats[2*8+m];
        pat_addr = cur_pat;
        ce = 1'b0;
        @(posedge clk);
        @(posedge clk);
        start = 1'b1;
        ce = 1'b1;
        #1;
        @(posedge clk);
        #1;
        start = 1'b0;
        if (busy !== 1'b1) $fatal(1, "A8: abort row did not start");
        repeat (9) begin
            @(posedge clk);
            #1;
        end
        reset = 1'b1;
        @(posedge clk);
        #1;
        reset = 1'b0;
        if (chr_req !== 1'b0 || shadow_valid !== 1'b0 || busy !== 1'b0)
            $fatal(1, "A8: reset mid-fetch left req=%b valid=%b busy=%b", chr_req, shadow_valid, busy);
        $display("A8  reset after 9 ce of fetch: chr_req=%b shadow_valid=%b busy=%b",
                 chr_req, shadow_valid, busy);
        run_fetch(0, 0, 0, 0, 1'b0);

        $display("A9  chr_req rising edges %0d == chr_rdata samples %0d == 16 on every one of the 6 fetches",
                 req_rise, grab_cnt);
        $display("A10 6 ce after each completion: chr_req=0, shadow held, shadow_valid=1");

        $display("PASS nes_sprite_chr_fetch");
        $finish;
    end

    initial begin
        #200000;
        $fatal(1, "TB timeout");
    end

endmodule
