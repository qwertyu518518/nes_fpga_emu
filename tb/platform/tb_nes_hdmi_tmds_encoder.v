`timescale 1ns/1ps

// ============================================================================
// tb_nes_hdmi_tmds_encoder : gate testbench for the T.M.D.S. colour-lane
// encoder.
// ----------------------------------------------------------------------------
// What is under test is the DVI 1.0 transition-minimised, DC-balanced encoding
// (section 3.1.3, Figure 3-5), so every assertion here is written against that
// specification rather than against a re-implementation of the RTL.  The bench
// rebuilds the specification's own quantities -- the stage-1 chain q_m, the
// decoder of Figure 3-6, the four control tokens -- from the specification text
// and checks the DUT's output against them.
//
// The bench drives a stream, one symbol per clock, and reads dout two edges
// behind the input (the encoder is three register stages, so dout at the edge
// that samples input k is the encoding of input k-2; CHECK_LAG = 2).
//
// Assertions
//
//   1. Reset.  Asynchronous active-low reset drives dout to zero.
//   2. The four control symbols come out exactly.  The specification writes
//      them in transmitted order q_out[0..9]; read into q_out[9:0] they are
//      1101010100 / 0010101011 / 0101010100 / 1010101011 for {c1,c0} =
//      00 / 01 / 10 / 11.  All four are asserted by exact match.
//   3. Control resets the state machine.  After a run of control symbols the
//      same data byte encodes exactly as it did with disparity zero in the
//      directed sweep, which only holds if Cnt was forced back to zero.
//   4. Structural conformance to Figure 3-5.  For every data symbol:
//        - dout[8] equals q_m[8] of the specification's stage-1 chain;
//        - undoing the bit-9 inversion (dout[9] == 1 means the low eight bits
//          were complemented) recovers q_m[7:0] exactly.
//      These two pin the symbol to q_m and its inversion flag on every one of
//      the three selection branches.
//   5. DC balance.  For an input whose q_m has four ones the symbol is the
//      DC-balanced choice and must carry exactly five ones.
//   6. Round trip.  The specification's decoder (Figure 3-6) recovers the
//      original byte from the encoder's output on every data symbol.
//   7. Bounded running disparity.  The running disparity -- derived from the
//      outputs themselves, reset to zero by each control symbol -- never leaves
//      [-8, +8].  See the note below on why the bound is 8 and not 1.
//   8. Non-vacuity.  The number of distinct output symbols over the directed
//      sweep and the random stream is asserted large; the four control tokens
//      are each seen; the data path is exercised; and 0x00 and 0x01 are
//      asserted to differ, so a stub that returns a constant cannot pass.
//
// Why the disparity bound is +/-8, not +/-1
//   T.M.D.S. is not the IBM 8b/10b code and its running disparity is not the
//   +/-1 of that code.  Figure 3-5's `balanced` branch emits a symbol with exactly
//   five ones (zero disparity), but the `oppose`/`follow` branches emit the
//   transition-minimised symbol, which can carry up to eight ones or eight
//   zeros.  The running disparity therefore reaches +/-8 over ordinary video
//   (the all-zero and all-ones bytes are the extremes).  The invariant the
//   specification actually guarantees is that the disparity never drifts: the
//   `oppose` branch always pushes it back towards zero, so it stays bounded.
//   Asserting +/-1 would fail a correct encoder; the bench asserts the true
//   bound and additionally asserts the disparity exceeds 1, so an encoder that
//   wrongly clamped its state would be caught rather than accommodated.
// ============================================================================

module tb_nes_hdmi_tmds_encoder;

    localparam integer CHECK_LAG = 2;      // dout lags the sampling edge by two
    localparam integer MAXN      = 5120;   // largest stream the arrays hold

    reg        clk;
    reg        rst_n;
    reg  [7:0] din;
    reg        de;
    reg        c0;
    reg        c1;
    wire [9:0] dout;

    integer    errors;
    integer    checks;

    // Stream storage.
    reg [7:0]  s_din [0:MAXN-1];
    reg        s_de  [0:MAXN-1];
    reg        s_c0  [0:MAXN-1];
    reg        s_c1  [0:MAXN-1];
    integer    n_sym;

    // Observation.
    integer    disp;                 // running disparity derived from outputs
    integer    max_abs_disp;
    integer    n_data_checks;
    integer    n_ctrl_checks;
    integer    n_distinct;
    reg        seen [0:1023];
    reg        ctrl_ok [0:3];        // {c1,c0} tokens observed exactly
    reg [9:0]  zero_out [0:255];     // encoding of each byte at disparity zero
    reg        record_zero;
    reg        check_zero;
    integer    max_token;

    nes_hdmi_tmds_encoder dut (
        .clk   (clk),
        .rst_n (rst_n),
        .din   (din),
        .de    (de),
        .c0    (c0),
        .c1    (c1),
        .dout  (dout)
    );

    always #5 clk = ~clk;

    // ---- specification helpers -----------------------------------------

    function integer popcount8;
        input [7:0] v;
        integer i;
        begin
            popcount8 = 0;
            for (i = 0; i < 8; i = i + 1)
                popcount8 = popcount8 + v[i];
        end
    endfunction

    function integer popcount10;
        input [9:0] v;
        integer i;
        begin
            popcount10 = 0;
            for (i = 0; i < 10; i = i + 1)
                popcount10 = popcount10 + v[i];
        end
    endfunction

    // Specification stage 1: build the nine-bit q_m from the byte.
    function [8:0] stage1_qm;
        input [7:0] d;
        reg         minimise;
        reg [7:0]   qm;
        integer     i;
        begin
            minimise = (popcount8(d) > 4) ||
                       ((popcount8(d) == 4) && (d[0] == 1'b0));
            qm[0] = d[0];
            for (i = 1; i < 8; i = i + 1)
                qm[i] = minimise ? ~(qm[i-1] ^ d[i]) : (qm[i-1] ^ d[i]);
            stage1_qm = { ~minimise, qm };
        end
    endfunction

    // Specification stage 2 decoder (Figure 3-6): recover the byte.
    function [7:0] decode_data;
        input [9:0] sym;
        reg         d8;
        reg [7:0]   low;
        reg         prev;
        integer     i;
        begin
            low = sym[9] ? ~sym[7:0] : sym[7:0];
            d8  = sym[8];
            decode_data[0] = low[0];
            prev = low[0];
            for (i = 1; i < 8; i = i + 1) begin
                decode_data[i] = d8 ? (low[i] ^ prev) : (low[i] ^~ prev);
                prev = low[i];
            end
        end
    endfunction

    // The four control tokens, {c1,c0} indexed 2*c1 + c0.
    function [9:0] ctrl_token;
        input       c0b;
        input       c1b;
        begin
            case ({c1b, c0b})
                2'b00:   ctrl_token = 10'b1101010100;
                2'b01:   ctrl_token = 10'b0010101011;
                2'b10:   ctrl_token = 10'b0101010100;
                default: ctrl_token = 10'b1010101011;
            endcase
        end
    endfunction

    task fail;
        input [8*96-1:0] label;
        begin
            errors = errors + 1;
            $display("FAIL: %0s", label);
        end
    endtask

    task expect_true;
        input condition;
        input [8*96-1:0] label;
        begin
            checks = checks + 1;
            if (!condition)
                fail(label);
        end
    endtask

    // ---- driving -------------------------------------------------------

    task apply_reset;
        begin
            rst_n = 1'b0;
            de    = 1'b0;
            din   = 8'h00;
            c0    = 1'b0;
            c1    = 1'b0;
            repeat (4) @(posedge clk);
            #1;
            checks = checks + 1;
            if (dout !== 10'h000) begin
                errors = errors + 1;
                $display("FAIL: reset left dout at %010b", dout);
            end
            rst_n = 1'b1;
        end
    endtask

    // Check the output symbol against the input symbol it encodes.
    task check_out;
        input integer idx;
        reg [8:0]   qm9;
        integer     ones;
        begin
            ones = popcount10(dout);

            if (seen[dout] === 1'b0) begin
                seen[dout] = 1'b1;
                n_distinct = n_distinct + 1;
            end

            if (s_de[idx] == 1'b0) begin
                // Control symbol: exact token.
                n_ctrl_checks = n_ctrl_checks + 1;
                checks = checks + 1;
                if (dout !== ctrl_token(s_c0[idx], s_c1[idx])) begin
                    errors = errors + 1;
                    $display("FAIL: control {c1,c0}=%b%b gave %010b, spec says %010b",
                             s_c1[idx], s_c0[idx], dout, ctrl_token(s_c0[idx], s_c1[idx]));
                end
                ctrl_ok[2 * s_c1[idx] + s_c0[idx]] = 1'b1;
                disp = 0;
            end
            else begin
                // Data symbol: structural conformance, balance, round trip.
                n_data_checks = n_data_checks + 1;
                qm9 = stage1_qm(s_din[idx]);

                checks = checks + 1;
                if (dout[8] !== qm9[8]) begin
                    errors = errors + 1;
                    $display("FAIL: din %02h q_out[8]=%b, spec q_m[8]=%b",
                             s_din[idx], dout[8], qm9[8]);
                end

                checks = checks + 1;
                if ((dout[9] ? ~dout[7:0] : dout[7:0]) !== qm9[7:0]) begin
                    errors = errors + 1;
                    $display("FAIL: din %02h low bits %08b after undoing q_out[9]=%b, spec q_m=%08b",
                             s_din[idx], dout[7:0], dout[9], qm9[7:0]);
                end

                // An input whose q_m is balanced must take the DC-balanced
                // branch and therefore carry exactly five ones.
                if (popcount8(qm9[7:0]) == 4) begin
                    checks = checks + 1;
                    if (ones !== 5) begin
                        errors = errors + 1;
                        $display("FAIL: din %02h has balanced q_m but symbol %010b carries %0d ones",
                                 s_din[idx], dout, ones);
                    end
                end

                // Round trip through the specification decoder.
                checks = checks + 1;
                if (decode_data(dout) !== s_din[idx]) begin
                    errors = errors + 1;
                    $display("FAIL: din %02h encoded to %010b, decoder recovered %02h",
                             s_din[idx], dout, decode_data(dout));
                end

                // Bounded running disparity.
                disp = disp + (2 * ones - 10);
                if (disp > max_abs_disp) max_abs_disp = disp;
                if (-disp > max_abs_disp) max_abs_disp = -disp;
                checks = checks + 1;
                if (disp > 8 || disp < -8) begin
                    errors = errors + 1;
                    $display("FAIL: running disparity %0d out of [-8,8] at din %02h",
                             disp, s_din[idx]);
                end

                if (record_zero)
                    zero_out[s_din[idx]] = dout;

                // Extra evidence that a run of control symbols zeroed Cnt.
                if (check_zero) begin
                    checks = checks + 1;
                    if (dout !== zero_out[s_din[idx]]) begin
                        errors = errors + 1;
                        $display("FAIL: after a control run din %02h gave %010b, disparity-zero encoding is %010b",
                                 s_din[idx], dout, zero_out[s_din[idx]]);
                    end
                end
            end
        end
    endtask

    // Drive a whole stream; assumes s_*[0..n_sym-1] are filled.
    task run_stream;
        integer k;
        begin
            for (k = 0; k < n_sym + CHECK_LAG; k = k + 1) begin
                if (k < n_sym) begin
                    din = s_din[k];
                    de  = s_de[k];
                    c0  = s_c0[k];
                    c1  = s_c1[k];
                end
                @(posedge clk);
                #1;
                if (k >= CHECK_LAG)
                    check_out(k - CHECK_LAG);
            end
        end
    endtask

    task put_control;
        input integer i;
        input         cc0;
        input         cc1;
        begin
            s_din[i] = 8'h00; s_de[i] = 1'b0; s_c0[i] = cc0; s_c1[i] = cc1;
        end
    endtask

    task put_data;
        input integer i;
        input [7:0]   v;
        begin
            s_din[i] = v; s_de[i] = 1'b1; s_c0[i] = 1'b0; s_c1[i] = 1'b0;
        end
    endtask

    integer i;
    integer v;

    initial begin
        clk          = 1'b0;
        rst_n        = 1'b1;
        din          = 8'h00;
        de           = 1'b0;
        c0           = 1'b0;
        c1           = 1'b0;
        errors       = 0;
        checks       = 0;
        disp         = 0;
        max_abs_disp = 0;
        n_data_checks = 0;
        n_ctrl_checks = 0;
        n_distinct   = 0;
        n_sym        = 0;
        record_zero  = 1'b0;
        check_zero   = 1'b0;
        max_token    = 0;
        for (i = 0; i < 1024; i = i + 1) seen[i] = 1'b0;
        for (i = 0; i < 4; i = i + 1) ctrl_ok[i] = 1'b0;
        for (i = 0; i < 256; i = i + 1) zero_out[i] = 10'h000;

        apply_reset;

        // ------------------------------------------------------------------
        // 1. the four control symbols, exactly
        // ------------------------------------------------------------------
        n_sym = 8;
        put_control(0, 1'b0, 1'b0);
        put_control(1, 1'b1, 1'b0);
        put_control(2, 1'b0, 1'b1);
        put_control(3, 1'b1, 1'b1);
        put_control(4, 1'b0, 1'b0);
        put_control(5, 1'b1, 1'b0);
        put_control(6, 1'b0, 1'b1);
        put_control(7, 1'b1, 1'b1);
        run_stream;

        expect_true(ctrl_ok[0] === 1'b1, "control {c1,c0}=00 must emit 1101010100");
        expect_true(ctrl_ok[1] === 1'b1, "control {c1,c0}=01 must emit 0010101011");
        expect_true(ctrl_ok[2] === 1'b1, "control {c1,c0}=10 must emit 0101010100");
        expect_true(ctrl_ok[3] === 1'b1, "control {c1,c0}=11 must emit 1010101011");
        $display("INFO control symbols: 1101010100 0010101011 0101010100 1010101011 all matched");

        // ------------------------------------------------------------------
        // 2. directed sweep: every byte, each preceded by a control symbol so
        //    it is encoded with disparity zero.  Covers the all-zero and
        //    all-one extremes and every q_m class.
        // ------------------------------------------------------------------
        record_zero = 1'b1;
        n_sym = 0;
        for (v = 0; v < 256; v = v + 1) begin
            put_control(n_sym, 1'b0, 1'b0);
            n_sym = n_sym + 1;
            put_data(n_sym, v[7:0]);
            n_sym = n_sym + 1;
        end
        run_stream;
        record_zero = 1'b0;

        // 3. control resets the state machine: after a run of controls the same
        //    bytes must encode exactly as they did at disparity zero.  The
        //    structural checks in check_out already ran on these symbols; the
        //    equality against the recorded disparity-zero encodings is the
        //    extra evidence that Cnt was forced back to zero.
        n_sym = 0;
        for (i = 0; i < 6; i = i + 1) begin
            put_control(n_sym, i[0], i[1]);
            n_sym = n_sym + 1;
        end
        // 0x00 directly after the run: the run must have zeroed Cnt.
        put_data(n_sym, 8'h00); n_sym = n_sym + 1;
        // The rest are each preceded by a control so they too are at Cnt = 0.
        put_control(n_sym, 1'b0, 1'b0); n_sym = n_sym + 1;
        put_data(n_sym, 8'hFF); n_sym = n_sym + 1;
        put_control(n_sym, 1'b0, 1'b0); n_sym = n_sym + 1;
        put_data(n_sym, 8'h1E); n_sym = n_sym + 1;
        put_control(n_sym, 1'b0, 1'b0); n_sym = n_sym + 1;
        put_data(n_sym, 8'h10); n_sym = n_sym + 1;
        put_control(n_sym, 1'b0, 1'b0); n_sym = n_sym + 1;
        put_data(n_sym, 8'hA5); n_sym = n_sym + 1;
        check_zero = 1'b1;
        run_stream;
        check_zero = 1'b0;

        // ------------------------------------------------------------------
        // 4. long pseudo-random stream (no controls): DC balance, round trip
        //    and non-vacuity on a large sample.
        // ------------------------------------------------------------------
        n_sym = 0;
        put_control(n_sym, 1'b0, 1'b0); n_sym = n_sym + 1;
        put_control(n_sym, 1'b0, 1'b0); n_sym = n_sym + 1;
        put_control(n_sym, 1'b0, 1'b0); n_sym = n_sym + 1;
        begin : lfsr_seed
            reg [15:0] lfsr;
            integer    k;
            lfsr = 16'hACE1;
            for (k = 0; k < 4096; k = k + 1) begin
                lfsr = { lfsr[14:0], lfsr[15] ^ lfsr[13] ^ lfsr[12] ^ lfsr[10] };
                put_data(n_sym, lfsr[7:0]);
                n_sym = n_sym + 1;
            end
        end
        run_stream;

        // ------------------------------------------------------------------
        // summary assertions
        // ------------------------------------------------------------------
        $display("INFO data symbols checked %0d, control symbols checked %0d",
                 n_data_checks, n_ctrl_checks);
        $display("INFO distinct output symbols observed %0d", n_distinct);
        $display("INFO maximum |running disparity| observed %0d", max_abs_disp);

        expect_true(n_distinct >= 256,
                    "the sweep must produce many distinct symbols (non-vacuous)");
        expect_true(n_data_checks >= 4000,
                    "the data path must be exercised over a long stream");
        expect_true(n_ctrl_checks >= 8,
                    "the control path must be exercised");
        expect_true(max_abs_disp >= 1,
                    "the running disparity must actually move");
        expect_true(max_abs_disp <= 8,
                    "the running disparity must stay within the TMDS bound");
        expect_true(max_abs_disp > 1,
                    "the disparity is multi-valued; an encoder clamped to +/-1 would be wrong");
        expect_true(zero_out[8'h00] !== zero_out[8'h01],
                    "0x00 and 0x01 must encode differently");
        expect_true(seen[zero_out[8'h00]] === 1'b1,
                    "the disparity-zero encoding of 0x00 must have been observed");

        if (errors == 0) begin
            $display("PASS tb_nes_hdmi_tmds_encoder %0d checks, %0d distinct symbols, max |disparity| %0d",
                     checks, n_distinct, max_abs_disp);
        end
        else begin
            $display("FAIL tb_nes_hdmi_tmds_encoder with %0d violations out of %0d checks",
                     errors, checks);
            $fatal(1, "tb_nes_hdmi_tmds_encoder failed");
        end
        $finish;
    end

    initial begin
        #2_000_000;
        $fatal(1, "tb_nes_hdmi_tmds_encoder global timeout");
    end

endmodule
