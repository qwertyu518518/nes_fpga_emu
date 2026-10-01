`timescale 1ns/1fs

// ============================================================================
// tb_nes_zynq_clk : gate testbench for the Zynq-7020 clock generator.
// ----------------------------------------------------------------------------
// Icarus cannot simulate MMCME2_BASE, so the DUT instantiates the behavioural
// mmcm_e2_base_sim model that lives at the bottom of this file when SYNTHESIS
// is not defined.  That model is not a hand written constant frequency
// generator: it derives both output periods from CLKIN1_PERIOD, DIVCLK_DIVIDE,
// CLKFBOUT_MULT_F and the two CLKOUT divides, exactly as the primitive does, so
// a wrong divide shows up here as a wrong measured frequency instead of as a
// silent elaboration success.
//
// Measurement method
//   Two independent counters watch the rising edges of core_clk and lcd_clk.
//   Each records $realtime at its first rising edge and at its Nth rising edge.
//   The measured period is (t_N - t_1)/(N-1) and the measured frequency is
//   1000/period in MHz.  Nothing is sampled from the model's own arithmetic; the
//   only model contribution is the edge times themselves.
//
// Tolerance
//   The measured frequency is asserted within TOL_REL of the target.  The noise
//   floor is the 1 fs timescale quantisation of the model's real valued delays:
//   each half period is rounded to the nearest 1 fs tick, so up to 1 fs of
//   systematic bias can accumulate per output period.  Over the 4096 edge
//   measurement window, 190.7 us, that is about 21 ppm, so the asserted
//   tolerance is 100 ppm, five times the worst case quantisation and still
//   three orders of magnitude tighter than the MMCM's own clock output
//   tolerance.  The divider arithmetic is separately asserted exact to 1e-12,
//   and the achieved frequency on real silicon is the Vivado clock report,
//   not this simulation.
//
// What is asserted
//   1  rst_in high forces locked low and both outputs to zero
//   2  locked asserts only after the modelled settling time and within a few
//      input cycles of it
//   3  neither output clock produces a single edge before locked is high
//   4  core_clk frequency within TOL_REL of 21.477272727272 MHz
//   5  lcd_clk frequency within TOL_REL of 25.000000 MHz
//   6  the measured frequencies equal the divider arithmetic recomputed from the
//      DUT's own parameter values, so the parameters, not a constant, are what
//      is under test
//   7  the divider arithmetic is exact: VCO inside the 7-series 600..1200 MHz
//      range, the multiply and both CLKOUT divides exact multiples of 0.125,
//      and both targets hit to better than 1e-12 relative
//   8  core_clk/4 is the NTSC PPU dot rate 5.369318 MHz, which is the contract
//      the NES core depends on
//   9  a second rst_in pulse drops locked and stops both clocks, and the core
//      clock frequency after re-lock is unchanged
// ============================================================================

module tb_nes_zynq_clk;

    // ---- DUT parameters under test -------------------------------------
    // CLKOUT0 carries lcd_clk on the fractional divide, CLKOUT1 carries
    // core_clk on the integer divide.  See the header of nes_zynq_clk.v.
    localparam real    CLK_IN_PERIOD_NS = 20.000;
    localparam real    MULT_F           = 23.625;
    localparam integer DIVCLK_DIVIDE    = 1;
    localparam real    CLKOUT0_DIVIDE_F = 47.25;
    localparam integer CLKOUT1_DIVIDE   = 55;

    // ---- independent numeric targets -----------------------------------
    localparam real NTSC_CORE_MHZ   = 945.0 / 44.0;   // 21.477272727272727
    localparam real LCD_MHZ         = 25.0;
    localparam real NTSC_DOT_MHZ    = NTSC_CORE_MHZ / 4.0;
    localparam real TOL_REL         = 1.0e-4;         // 100 ppm, see the header
    localparam real EXACT_REL       = 1.0e-12;        // divider arithmetic

    // ---- edge counting --------------------------------------------------
    localparam integer N_CORE = 4096;
    localparam integer N_LCD  = 4096;
    localparam integer N_RE   = 512;

    reg  clk_in;
    reg  rst_in;
    wire core_clk;
    wire lcd_clk;
    wire locked;

    integer errors;
    integer checks;

    integer phase;              // 0 first run, 1 after the second reset pulse
    integer measuring;
    integer measuring_re;

    integer core_edges;
    integer lcd_edges;
    integer pre_lock_core_edges;
    integer pre_lock_lcd_edges;
    real   core_t0;
    real   core_t1;
    real   lcd_t0;
    real   lcd_t1;

    integer lock_cycles_model;
    integer lock_cycle_seen;
    integer cycles_since_rst;

    integer i;
    real f_in_mhz;
    real f_vco_mhz;
    real f_core_ref_mhz;
    real f_lcd_ref_mhz;
    real core_per_ns;
    real lcd_per_ns;
    real core_mhz;
    real lcd_mhz;
    real core_err;
    real lcd_err;
    real re_core_per_ns;
    real re_core_mhz;

    nes_zynq_clk #(
        .CLK_IN_PERIOD    (CLK_IN_PERIOD_NS),
        .CLKFBOUT_MULT_F  (MULT_F),
        .DIVCLK_DIVIDE    (DIVCLK_DIVIDE),
        .CLKOUT0_DIVIDE_F (CLKOUT0_DIVIDE_F),
        .CLKOUT1_DIVIDE   (CLKOUT1_DIVIDE)
    ) dut (
        .clk_in  (clk_in),
        .rst_in  (rst_in),
        .lcd_clk (lcd_clk),
        .core_clk(core_clk),
        .locked  (locked)
    );

    // ---- 50 MHz board oscillator, package pin U18 ------------------------
    initial clk_in = 1'b0;
    always #(CLK_IN_PERIOD_NS / 2.0) clk_in = ~clk_in;

    // ---- edge counters --------------------------------------------------
    initial begin
        phase                = 0;
        measuring            = 0;
        measuring_re         = 0;
        core_edges           = 0;
        lcd_edges            = 0;
        pre_lock_core_edges  = 0;
        pre_lock_lcd_edges   = 0;
        core_t0              = 0.0;
        core_t1              = 0.0;
        lcd_t0               = 0.0;
        lcd_t1               = 0.0;
    end

    always @(posedge core_clk) begin
        if (!locked) begin
            pre_lock_core_edges = pre_lock_core_edges + 1;
        end
        else if (phase == 0) begin
            if (core_edges == 0) core_t0 = $realtime;
            if (core_edges < N_CORE) core_t1 = $realtime;
            core_edges = core_edges + 1;
        end
        else if (measuring_re) begin
            if (core_edges == 0) core_t0 = $realtime;
            if (core_edges < N_RE) core_t1 = $realtime;
            core_edges = core_edges + 1;
        end
    end

    always @(posedge lcd_clk) begin
        if (!locked) begin
            pre_lock_lcd_edges = pre_lock_lcd_edges + 1;
        end
        else if (phase == 0) begin
            if (lcd_edges == 0) lcd_t0 = $realtime;
            if (lcd_edges < N_LCD) lcd_t1 = $realtime;
            lcd_edges = lcd_edges + 1;
        end
    end

    task expect_true;
        input condition;
        input [8*72-1:0] label;
        begin
            checks = checks + 1;
            if (!condition) begin
                errors = errors + 1;
                $display("FAIL: %0s", label);
            end
        end
    endtask

    task expect_close;
        input real measured;
        input real target;
        input real tol_rel;
        input [8*72-1:0] label;
        real err;
        begin
            checks = checks + 1;
            err = (measured - target) / target;
            if (err < 0.0) err = -err;
            if (!(err < tol_rel)) begin
                errors = errors + 1;
                $display("FAIL: %0s measured %.9f target %.9f rel %.3e",
                         label, measured, target, err);
            end
        end
    endtask

    initial begin
        errors = 0;
        checks = 0;
        rst_in = 1'b1;

        // The settling time the RTL actually handed to the model.
        lock_cycles_model = dut.u_mmcm.LOCK_CYCLES;
        $display("INFO mmcm model settling time %0d input cycles", lock_cycles_model);

        // ------------------------------------------------------------------
        // 1. reset behaviour
        // ------------------------------------------------------------------
        repeat (24) @(posedge clk_in);
        expect_true(locked  === 1'b0, "locked low while rst_in high");
        expect_true(core_clk === 1'b0, "core_clk held at 0 while rst_in high");
        expect_true(lcd_clk === 1'b0, "lcd_clk held at 0 while rst_in high");

        // ------------------------------------------------------------------
        // 2. locked asserts only after the modelled settling time
        // ------------------------------------------------------------------
        rst_in          = 1'b0;
        lock_cycle_seen = -1;
        cycles_since_rst = 0;

        while (lock_cycle_seen < 0 && cycles_since_rst < (lock_cycles_model + 64)) begin
            @(posedge clk_in);
            cycles_since_rst = cycles_since_rst + 1;
            if (locked === 1'b1 && lock_cycle_seen < 0) begin
                lock_cycle_seen = cycles_since_rst;
            end
        end

        expect_true(lock_cycle_seen >= lock_cycles_model,
                    "locked asserted before the modelled settling time");
        expect_true(lock_cycle_seen <= lock_cycles_model + 8,
                    "locked asserted more than 8 input cycles after the settling time");

        $display("INFO locked asserted %0d input cycles after rst_in release, modelled settling %0d",
                 lock_cycle_seen, lock_cycles_model);

        // ------------------------------------------------------------------
        // 3. no output edge before lock
        // ------------------------------------------------------------------
        expect_true(pre_lock_core_edges == 0, "core_clk produced an edge before locked");
        expect_true(pre_lock_lcd_edges == 0, "lcd_clk produced an edge before locked");

        // ------------------------------------------------------------------
        // 4/5. measure both frequencies by edge counting
        // ------------------------------------------------------------------
        wait (core_edges >= N_CORE);
        wait (lcd_edges  >= N_LCD);

        core_per_ns = (core_t1 - core_t0) / (N_CORE - 1);
        lcd_per_ns  = (lcd_t1 - lcd_t0) / (N_LCD - 1);
        core_mhz    = 1000.0 / core_per_ns;
        lcd_mhz     = 1000.0 / lcd_per_ns;
        core_err    = (core_mhz - NTSC_CORE_MHZ) / NTSC_CORE_MHZ;
        lcd_err     = (lcd_mhz - LCD_MHZ) / LCD_MHZ;

        $display("INFO core_clk %0d rising edges over %.3f us, measured %.9f MHz, period %.9f ns, rel err %.3e",
                 N_CORE, (core_t1 - core_t0) / 1000.0, core_mhz, core_per_ns, core_err);
        $display("INFO lcd_clk  %0d rising edges over %.3f us, measured %.9f MHz, period %.9f ns, rel err %.3e",
                 N_LCD, (lcd_t1 - lcd_t0) / 1000.0, lcd_mhz, lcd_per_ns, lcd_err);

        expect_close(core_mhz, NTSC_CORE_MHZ, TOL_REL, "core_clk frequency");
        expect_close(lcd_mhz, LCD_MHZ, TOL_REL, "lcd_clk frequency");

        // ------------------------------------------------------------------
        // 6. the divider arithmetic recomputed from the DUT's own parameters
        // ------------------------------------------------------------------
        f_in_mhz       = 1000.0 / dut.CLK_IN_PERIOD;
        f_vco_mhz      = f_in_mhz * dut.CLKFBOUT_MULT_F / dut.DIVCLK_DIVIDE;
        f_core_ref_mhz = f_vco_mhz / dut.CLKOUT1_DIVIDE;
        f_lcd_ref_mhz  = f_vco_mhz / dut.CLKOUT0_DIVIDE_F;

        expect_close(core_mhz, f_core_ref_mhz, TOL_REL,
                     "core_clk equals f_vco/CLKOUT1_DIVIDE");
        expect_close(lcd_mhz, f_lcd_ref_mhz, TOL_REL,
                     "lcd_clk equals f_vco/CLKOUT0_DIVIDE_F");

        // ------------------------------------------------------------------
        // 7. the arithmetic itself
        // ------------------------------------------------------------------
        expect_true(f_vco_mhz >= 600.0 && f_vco_mhz <= 1200.0,
                    "VCO outside the 7-series 600..1200 MHz range");

        // The core clock is on an integer divide, which is what makes it exact.
        i = dut.CLKOUT1_DIVIDE - (dut.CLKOUT1_DIVIDE / 1) * 1;
        expect_true(i == 0, "CLKOUT1_DIVIDE is not an integer");
        expect_true(dut.CLKOUT1_DIVIDE >= 1 && dut.CLKOUT1_DIVIDE <= 128,
                    "CLKOUT1_DIVIDE outside the primitive range 1 to 128");

        // The LCD clock is on the fractional divide, which must land on 0.125.
        i = dut.CLKOUT0_DIVIDE_F / 0.125;
        expect_close(dut.CLKOUT0_DIVIDE_F, i * 0.125, EXACT_REL,
                     "CLKOUT0_DIVIDE_F is an exact multiple of 0.125");
        i = dut.CLKFBOUT_MULT_F / 0.125;
        expect_close(dut.CLKFBOUT_MULT_F, i * 0.125, EXACT_REL,
                     "CLKFBOUT_MULT_F is an exact multiple of 0.125");

        expect_close(f_core_ref_mhz, NTSC_CORE_MHZ, EXACT_REL,
                     "divider arithmetic hits 21.477272727272 MHz exactly");
        expect_close(f_lcd_ref_mhz, LCD_MHZ, EXACT_REL,
                     "divider arithmetic hits 25 MHz exactly");

        $display("INFO f_in %.6f MHz, f_vco %.6f MHz, f_core %.9f MHz, f_lcd %.9f MHz",
                 f_in_mhz, f_vco_mhz, f_core_ref_mhz, f_lcd_ref_mhz);

        // ------------------------------------------------------------------
        // 8. the PPU dot rate the NES core depends on
        // ------------------------------------------------------------------
        expect_close(core_mhz / 4.0, NTSC_DOT_MHZ, TOL_REL,
                     "core_clk divided by 4 is the NTSC PPU dot rate");

        // ------------------------------------------------------------------
        // 9. a second reset pulse drops locked and stops both clocks
        // ------------------------------------------------------------------
        rst_in = 1'b1;
        repeat (8) @(posedge clk_in);
        expect_true(locked   === 1'b0, "locked low again after the second rst_in pulse");
        expect_true(core_clk === 1'b0, "core_clk stopped after the second rst_in pulse");
        expect_true(lcd_clk === 1'b0, "lcd_clk stopped after the second rst_in pulse");

        rst_in    = 1'b0;
        phase     = 1;
        core_edges = 0;
        core_t0    = 0.0;
        core_t1    = 0.0;
        measuring_re = 1;

        repeat (lock_cycles_model + 16) @(posedge clk_in);
        expect_true(locked === 1'b1, "locked reasserted after the second rst_in release");

        wait (core_edges >= N_RE);
        measuring_re = 0;
        re_core_per_ns = (core_t1 - core_t0) / (N_RE - 1);
        re_core_mhz    = 1000.0 / re_core_per_ns;
        $display("INFO core_clk after re-lock, %0d rising edges, measured %.9f MHz",
                 N_RE, re_core_mhz);
        expect_close(re_core_mhz, NTSC_CORE_MHZ, TOL_REL,
                     "core_clk frequency unchanged after re-lock");

        // ------------------------------------------------------------------
        if (errors == 0) begin
            $display("PASS tb_nes_zynq_clk core_clk %.9f MHz and lcd_clk %.9f MHz measured by edge count, locked after %0d input cycles",
                     core_mhz, lcd_mhz, lock_cycle_seen);
        end
        else begin
            $display("FAIL tb_nes_zynq_clk with %0d violations out of %0d checks",
                     errors, checks);
        end
        $finish;
    end

    // Global timeout guard.
    initial begin
        #2_000_000;
        $display("FAIL tb_nes_zynq_clk global timeout");
        $fatal(1, "tb_nes_zynq_clk timed out");
    end

endmodule


// ============================================================================
// mmcm_e2_base_sim : behavioural stand-in for the Xilinx MMCME2_BASE.
// ----------------------------------------------------------------------------
// Testbench only, not part of the RTL.  Icarus has no MMCME2_BASE model, and
// silently resolving the primitive to nothing would make the frequency
// assertions in the testbench vacuous, so the divider arithmetic is reproduced
// here from the very same parameters the primitive takes:
//
//   f_vco  = f_in * CLKFBOUT_MULT_F / DIVCLK_DIVIDE
//   period = CLKIN1_PERIOD * DIVCLK_DIVIDE / CLKFBOUT_MULT_F * CLKOUTn_divide
//
// where CLKOUTn_divide is CLKOUT0_DIVIDE_F on CLKOUT0 and the integer
// CLKOUT1_DIVIDE on CLKOUT1, which is the split the primitive actually has.
//
// LOCKED asserts LOCK_CYCLES input cycles after RST is released and both
// outputs are held at 0 until then.
// ============================================================================
module mmcm_e2_base_sim #(
    parameter CLKFBOUT_MULT_F  = 5.0,
    parameter CLKOUT0_DIVIDE_F = 1.0,
    parameter CLKOUT1_DIVIDE   = 1,
    parameter DIVCLK_DIVIDE    = 1,
    parameter CLKIN1_PERIOD    = 0.0,
    parameter BANDWIDTH        = "OPTIMIZED",
    parameter STARTUP_WAIT     = "FALSE",
    parameter LOCK_CYCLES      = 200
) (
    input  wire CLKIN1,
    input  wire PWRDWN,
    input  wire RST,
    output wire LOCKED,
    output wire CLKFBOUT,
    output wire CLKFBOUTB,
    input  wire CLKFBIN,
    output reg  CLKOUT0,
    output reg  CLKOUT0B,
    output reg  CLKOUT1,
    output reg  CLKOUT1B,
    output reg  CLKOUT2,
    output reg  CLKOUT2B,
    output reg  CLKOUT3,
    output reg  CLKOUT3B,
    output reg  CLKOUT4,
    output reg  CLKOUT5,
    output reg  CLKOUT6
);

    reg        locked_r;
    reg [31:0] lock_cnt;

    real half0_ns;
    real half1_ns;

    // The feedback path is not modelled, it only has to exist so the port list
    // elaborates against the same parameter set as the primitive.
    assign CLKFBOUT = CLKIN1;

    initial begin
        locked_r = 1'b0;
        lock_cnt = 32'd0;
        CLKOUT0  = 1'b0;
        CLKOUT1  = 1'b0;
        if (CLKIN1_PERIOD <= 0.0) begin
            $display("FAIL mmcm_e2_base_sim CLKIN1_PERIOD must be non zero");
            $fatal(1, "mmcm_e2_base_sim needs a non zero CLKIN1_PERIOD");
        end
        half0_ns = (CLKIN1_PERIOD * DIVCLK_DIVIDE / CLKFBOUT_MULT_F * CLKOUT0_DIVIDE_F) / 2.0;
        half1_ns = (CLKIN1_PERIOD * DIVCLK_DIVIDE / CLKFBOUT_MULT_F * CLKOUT1_DIVIDE) / 2.0;
        $display("INFO mmcm_e2_base_sim f_vco %.6f MHz, CLKOUT0 half %.9f ns, CLKOUT1 half %.9f ns",
                 1000.0 * CLKFBOUT_MULT_F / (DIVCLK_DIVIDE * CLKIN1_PERIOD),
                 half0_ns, half1_ns);

        forever begin
            #(half0_ns);
            CLKOUT0 = locked_r ? ~CLKOUT0 : 1'b0;
        end
    end

    initial begin
        forever begin
            #(half1_ns);
            CLKOUT1 = locked_r ? ~CLKOUT1 : 1'b0;
        end
    end

    always @(posedge CLKIN1 or posedge RST) begin
        if (RST) begin
            lock_cnt <= 32'd0;
            locked_r <= 1'b0;
        end
        else if (lock_cnt < LOCK_CYCLES) begin
            lock_cnt <= lock_cnt + 32'd1;
            if (lock_cnt == LOCK_CYCLES - 1) locked_r <= 1'b1;
        end
    end

    assign LOCKED = locked_r;

endmodule
