# =============================================================================
# nes_zynq_top.xdc : pin and clock constraints for the Zynq-7020 NES platform
# -----------------------------------------------------------------------------
# Target device : xc7z020-clg400-2
# IOSTANDARD    : LVCMOS33 on every pin below.  That is the vendor value for
#                 every signal this design uses on this board; the only
#                 non-LVCMOS33 entries in the vendor file are the HDMI TMDS
#                 pairs, which this design does not instantiate.
#
# Primary source, every pin below is traceable to one line of it
#   D:\BaiduNetdiskDownload\【正点原子】领航者(V2)ZYNQ开发板资料 资料盘(A盘)\
#     领航者ZYNQ资料盘(A盘)\3_正点原子领航者ZYNQ开发板原理图\NAVIGATOR_ZYNQ_IO.xdc
#   146 lines, the official board-wide PL pin list.  Cited below as
#   "board XDC:<line>".  That file is GBK encoded and its comments are in
#   Chinese; only its set_property lines are load bearing here.
#
# Cross-check source
#   ...\领航者ZYNQ资料盘(A盘)\4_SourceCode\1_FPGA_Design\ZYNQ_7020_FPGA.zip
#   per-example XDCs under <example>\<example>.srcs\constrs_1\new\.  These are
#   working, implemented designs rather than a reference table, so a value that
#   appears in one of them has been through place and route.  Cited below as
#   "lcd_rgb_char.xdc:<line>" and so on.
#
# Known conflicts and source discrepancies, all resolved here and none of them
# silently picked.  See the block comment above each affected group.
#
# Port directions are NOT set by this file.  Vivado takes port direction from
# the top-level Verilog declaration, and a direction written here would be
# redundant at best and contradictory at worst.  Where a port has a required
# direction that is easy to get wrong, the requirement is stated in a comment
# next to the pin.
#
# What has actually been checked, Vivado 2018.3, xc7z020-clg400-2, against a
# throwaway stub top that declares exactly the ports named below.  The probe is
# under D:\vivadoProject\xdc_probe\ and is not part of this repository.
#
#   * 40 [get_ports ...] targets in this file, 40 resolved to exactly one port,
#     0 empty, 0 ambiguous.  38 of those 40 are the PACKAGE_PIN lines, the other
#     2 are the create_clock lines.
#   * 38 PACKAGE_PIN assignments, 38 distinct pins, 0 duplicates.
#   * place_design accepted all 38 on xc7z020-clg400-2 with DRC 0 errors, and
#     report_io returns Total User IO = 38, every one placed.  So every pin here
#     is a real pin of the real package, not just a plausible looking name.
#   * lcd_rgb[23:0], touch_scl and touch_sda elaborate and place as BIDIR, which
#     is the inout requirement below actually holding.
#   * The clock measurements are recorded next to the create_clock lines.
#
# COUNTS ABOVE ARE THE STUB PROBE'S, AND THE TPAD LINE MAKES THEM STALE.  They were
# measured before this file constrained touch_key, so "38 PACKAGE_PIN lines" is now
# 39 and "Total User IO = 38" is now 45.  The authoritative count for the file as it
# stands is no longer the stub probe but the real routed build, measured on the full
# platform top in D:\vivadoProject\zynq_bitstream_v6\ (Vivado 2018.3,
# xc7z020-clg400-2, full non-OOC flow, real cartridge):
#
#   * 48 active [get_ports] lines, resolving to 45 DISTINCT port targets, and
#     report_utilization-independent get_ports on the routed design returns exactly
#     45 ports.  The 48-vs-45 gap is the create_clock targets on sys_clk, lcd_clk
#     and aud_bclk, each of which carries a pin line as well.
#   * report_io on that build: Total User IO = 45, placed 45 of 45, unplaced 0,
#     DRC 0 errors, 0 routing errors.  So every line in this file, touch_key
#     included, is a real pin of the real package.
#   * touch_key read back by name AND by pin from that routed checkpoint:
#     PACKAGE_PIN F16, IOSTANDARD LVCMOS33, DIRECTION IN; F16 carries exactly one
#     port.  report_io agrees:
#       | F16 | touch_key | High Range | IO_L6P_T0_35 | INPUT | LVCMOS33 |
#   * check_timing on that build reports 0 lines of Vivado 12-584 "No ports
#     matched", and report_io reports none either, so no line in this file names a
#     port the real top does not declare.  That is the risk the next paragraph
#     called open, and it is now closed by measurement.
#
# What has NOT been checked: nothing below is a guess, but the stub-probe block
# above is a stub measurement, and the v6 numbers are the ones that describe this
# file as it actually reads today.  A future edit that changes a port name in the
# top must re-run the v6 probe or an equivalent, or the names can drift apart again
# and Vivado 12-584 will report it silently rather than as a build failure.
# =============================================================================


# -----------------------------------------------------------------------------
# System clock and reset
# board XDC:4   sys_clk   U18
# board XDC:7   sys_rst_n N16
# -----------------------------------------------------------------------------
set_property -dict {PACKAGE_PIN U18 IOSTANDARD LVCMOS33} [get_ports sys_clk]
set_property -dict {PACKAGE_PIN N16 IOSTANDARD LVCMOS33} [get_ports sys_rst_n]


# -----------------------------------------------------------------------------
# PL keys, active low with the board pull-ups
# board XDC:10  key[0] L14
# board XDC:11  key[1] K16
# Two keys are not a NES controller.  They are the reset/menu pair the platform
# top is expected to use for on-board control; the NES controller ports come
# from the capacitive touch panel below.
# -----------------------------------------------------------------------------
set_property -dict {PACKAGE_PIN L14 IOSTANDARD LVCMOS33} [get_ports {key[0]}]
set_property -dict {PACKAGE_PIN K16 IOSTANDARD LVCMOS33} [get_ports {key[1]}]


# -----------------------------------------------------------------------------
# TPAD: the board's third discrete button, on its own pin.
# board XDC:21  touch_key F16, in the board file's own "#---- 触摸按键 ----"
# section rather than under PL_KEY, and cross-checked against four per-example
# XDCs that all carry the identical line, e.g.
#     4_touch_led\...\touch_led.xdc:4      PACKAGE_PIN F16
#     25_mdio_rw_test\...\mdio_rw_test.xdc:8
#     26_eth_arp_test\...\eth_arp_test.xdc:7
#     3_pl_key\...\ (none; no PL_KEY example constrains F16)
#
# It sits here with the keys because it IS a key, not because the board file
# groups it there: it is a momentary push button, not a point on the GT9147.
# The distinction matters, because key[0] and key[1] are active low and this one
# is not.  Nothing in any XDC states the polarity, so it is taken from the
# vendor's own RTL for this pin, in 4_touch_led:
#     touch_led.v:51   assign touch_en = (~touch_key_d1) & touch_key_d0;
#     touch_led.v:65   根据触摸按键上升沿的脉冲信号切换led状态
#     tb_touch_led.v:22 #40 touch_key = 1'b1;   // 触摸按键按下
# A RISING edge is the press, and the stimulus drives 1 to press, so touch_key is
# ACTIVE HIGH: idle low, high while held.  nes_touch_input.v therefore reads
# key_stable_q[2] with no inversion while inverting key_stable_q[0] and [1].
# 26_eth_arp_test/srcs/sources_1/new/arp_ctrl.v:45 does the same edge detect.
#
# F16 was free before this line: no other PACKAGE_PIN in this file names it.
# -----------------------------------------------------------------------------
set_property -dict {PACKAGE_PIN F16 IOSTANDARD LVCMOS33} [get_ports touch_key]


# -----------------------------------------------------------------------------
# LCD pixel data, 24 bit RGB888, red in bits [23:16]
# board XDC:45..68, cross-checked against lcd_rgb_char.xdc:4..27 (identical).
#
# DIRECTION: lcd_rgb must be declared inout in the top-level Verilog.  This is
# not a stylistic choice.  The vendor drives the same 24 pins three-state:
#
#     lcd_rgb_char.v:53   assign lcd_rgb = lcd_de ? lcd_rgb_o : {24{1'bz}};
#
# and it reads the panel ID back over those same pins (lcd_rgb_char.v:54
# assign lcd_rgb_i = lcd_rgb), so the bus is genuinely bidirectional in the
# vendor design.  Declaring it output would either drop the ID readback or, if
# the top still tri-stated it, produce a direction conflict at synthesis.
#
# The 24-bit width at the top level is final regardless of where the
# RGB565-to-RGB888 expansion happens: nes_video_800x480.v emits rgb565[15:0]
# and the expansion to 24 bits is internal to the platform top either way.
# -----------------------------------------------------------------------------
set_property -dict {PACKAGE_PIN W18 IOSTANDARD LVCMOS33} [get_ports {lcd_rgb[0]}]
set_property -dict {PACKAGE_PIN W19 IOSTANDARD LVCMOS33} [get_ports {lcd_rgb[1]}]
set_property -dict {PACKAGE_PIN R16 IOSTANDARD LVCMOS33} [get_ports {lcd_rgb[2]}]
set_property -dict {PACKAGE_PIN R17 IOSTANDARD LVCMOS33} [get_ports {lcd_rgb[3]}]
set_property -dict {PACKAGE_PIN W20 IOSTANDARD LVCMOS33} [get_ports {lcd_rgb[4]}]
set_property -dict {PACKAGE_PIN V20 IOSTANDARD LVCMOS33} [get_ports {lcd_rgb[5]}]
set_property -dict {PACKAGE_PIN P18 IOSTANDARD LVCMOS33} [get_ports {lcd_rgb[6]}]
set_property -dict {PACKAGE_PIN N17 IOSTANDARD LVCMOS33} [get_ports {lcd_rgb[7]}]
set_property -dict {PACKAGE_PIN V17 IOSTANDARD LVCMOS33} [get_ports {lcd_rgb[8]}]
set_property -dict {PACKAGE_PIN V18 IOSTANDARD LVCMOS33} [get_ports {lcd_rgb[9]}]
set_property -dict {PACKAGE_PIN T17 IOSTANDARD LVCMOS33} [get_ports {lcd_rgb[10]}]
set_property -dict {PACKAGE_PIN R18 IOSTANDARD LVCMOS33} [get_ports {lcd_rgb[11]}]
set_property -dict {PACKAGE_PIN Y18 IOSTANDARD LVCMOS33} [get_ports {lcd_rgb[12]}]
set_property -dict {PACKAGE_PIN Y19 IOSTANDARD LVCMOS33} [get_ports {lcd_rgb[13]}]
set_property -dict {PACKAGE_PIN P15 IOSTANDARD LVCMOS33} [get_ports {lcd_rgb[14]}]
set_property -dict {PACKAGE_PIN P16 IOSTANDARD LVCMOS33} [get_ports {lcd_rgb[15]}]
set_property -dict {PACKAGE_PIN V16 IOSTANDARD LVCMOS33} [get_ports {lcd_rgb[16]}]
set_property -dict {PACKAGE_PIN W16 IOSTANDARD LVCMOS33} [get_ports {lcd_rgb[17]}]
set_property -dict {PACKAGE_PIN T14 IOSTANDARD LVCMOS33} [get_ports {lcd_rgb[18]}]
set_property -dict {PACKAGE_PIN T15 IOSTANDARD LVCMOS33} [get_ports {lcd_rgb[19]}]
set_property -dict {PACKAGE_PIN Y17 IOSTANDARD LVCMOS33} [get_ports {lcd_rgb[20]}]
set_property -dict {PACKAGE_PIN Y16 IOSTANDARD LVCMOS33} [get_ports {lcd_rgb[21]}]
set_property -dict {PACKAGE_PIN T16 IOSTANDARD LVCMOS33} [get_ports {lcd_rgb[22]}]
set_property -dict {PACKAGE_PIN U17 IOSTANDARD LVCMOS33} [get_ports {lcd_rgb[23]}]


# -----------------------------------------------------------------------------
# LCD control
# board XDC:70  lcd_hs  N18
# board XDC:71  lcd_vs  T20
# board XDC:72  lcd_de  U20
# board XDC:73  lcd_bl  M20
# board XDC:74  lcd_clk P19
# cross-checked against lcd_rgb_char.xdc:29..33 (identical).
#
# The panel is in DE mode.  lcd_hs and lcd_vs are held high by the vendor
# because DE mode ignores them (lcd_driver.v:127,128), but they are still
# driven here so the connector is never left floating.
#
# lcd_bl is constrained as a real output on purpose.  The vendor ties it to a
# constant 1 and never dims the backlight:
#
#     lcd_driver.v:130    assign lcd_bl = 1'b1;
#
# Do not copy that.  Constrain the pin and let the platform top drive it, so
# brightness control is possible without a constraint change.
# -----------------------------------------------------------------------------
set_property -dict {PACKAGE_PIN N18 IOSTANDARD LVCMOS33} [get_ports lcd_hs]
set_property -dict {PACKAGE_PIN T20 IOSTANDARD LVCMOS33} [get_ports lcd_vs]
set_property -dict {PACKAGE_PIN U20 IOSTANDARD LVCMOS33} [get_ports lcd_de]
set_property -dict {PACKAGE_PIN M20 IOSTANDARD LVCMOS33} [get_ports lcd_bl]
set_property -dict {PACKAGE_PIN P19 IOSTANDARD LVCMOS33} [get_ports lcd_clk]


# -----------------------------------------------------------------------------
# LCD reset
#
# SOURCE DISCREPANCY: lcd_rst has no line in the board-wide XDC.  The board file
# jumps from lcd_sda at line 79 straight to the touch reset at line 81.  The
# pin is present in four per-example XDCs instead, all agreeing on L17:
#
#     11_lcd_rgb_colorbar\...\lcd_rgb_colorbar.xdc:34   PACKAGE_PIN L17
#     12_lcd_rgb_char\...\lcd_rgb_char.xdc:34           PACKAGE_PIN L17
#     16_rtc_lcd\...\rtc_lcd.xdc:37                     PACKAGE_PIN L17
#     18_top_cymometer\...\top_cymometer.xdc:38         PACKAGE_PIN L17
#
# and L17 is confirmed placed on a real device pin by the vendor's own
# implementation report, 11_lcd_rgb_colorbar.runs\impl_1\lcd_rgb_colorbar_io_placed.rpt:254
#
#     | L17 | lcd_rst | High Range | IO_L11N_T1_SRCC_35 | OUTPUT | LVCMOS33 |
#
# L17 is used here on that evidence.  Note that 17_top_lcd_touch names the same
# pin lcd_rst_n and also ties it high (top_lcd_touch.v:66); this design keeps
# the vendor's lcd_rst spelling and drives it from the platform top, because
#
#     lcd_driver.v:132    assign lcd_rst = 1'b1;
#
# means the vendor never resets the panel at all.
# -----------------------------------------------------------------------------
set_property -dict {PACKAGE_PIN L17 IOSTANDARD LVCMOS33} [get_ports lcd_rst]


# -----------------------------------------------------------------------------
# Capacitive touch panel: I2C, reset and interrupt
# board XDC:77  lcd_scl   R19     (vendor port name for the touch I2C clock)
# board XDC:79  lcd_sda   P20     (vendor port name for the touch I2C data)
# board XDC:81  ct_rst    M19
# board XDC:83  ct_int    U19
#
# CONFLICT, RESOLVED HERE: R19 and P20 are each assigned twice in the board
# XDC, to two different signals on the same two package pins:
#
#     board XDC:77   set_property -dict {PACKAGE_PIN R19 ...} [get_ports lcd_scl]
#     board XDC:79   set_property -dict {PACKAGE_PIN P20 ...} [get_ports lcd_sda]
#     board XDC:91   set_property -dict {PACKAGE_PIN R19 ...} [get_ports tmds_scl]
#     board XDC:92   set_property -dict {PACKAGE_PIN P20 ...} [get_ports tmds_sda]
#
# That is a physical fact about the board, not a vendor typo: the ATK-4342
# panel connector and the HDMI DDC lines share R19 and P20.  Only one of the two
# pairs can be driven by this design.
#
# RESOLUTION: bound to the touch I2C.  This design has no HDMI output and no
# HDMI DDC, so tmds_scl and tmds_sda are not ports here at all and the conflict
# cannot arise.  Consequence, stated plainly so nobody re-adds them:
#
#   * The vendor's lcd_scl / lcd_sda names are NOT separately constrained below.
#     They are aliases for the same two physical pins, and constraining both
#     name pairs would put R19 and P20 in this file twice.  One physical pin,
#     one owner: the touch controller.
#   * If an HDMI port is ever added to the platform top, R19 and P20 must move
#     to it and the touch controller has to move to the panel's own connector
#     or to the PS I2C.  That is a board-level decision, not a constraint edit.
#
# NAME MAPPING: vendor port -> this file's port.
#     lcd_scl -> touch_scl      ct_rst -> touch_rst_n      ct_int -> touch_int
# The vendor ct_rst is active high and ct_int is active low; rtl/nes_core/
# peripheral/nes_touch_input.v already presents ct_rst_n, so the polarity fix
# lives in RTL and this file only carries the pin.
#
# DIRECTION: touch_scl and touch_sda must be inout in the top-level Verilog.
# I2C is open drain: the controller pulls low and releases, and the panel
# pulls low in an ACK.  A push-pull output would break the bus.  nes_touch_input.v
# splits this into scl_o / sda_o / sda_oe / sda_i internally, so the top level
# needs the joined inout form.  The board carries the external pull-ups.
# -----------------------------------------------------------------------------
set_property -dict {PACKAGE_PIN R19 IOSTANDARD LVCMOS33} [get_ports touch_scl]
set_property -dict {PACKAGE_PIN P20 IOSTANDARD LVCMOS33} [get_ports touch_sda]
set_property -dict {PACKAGE_PIN M19 IOSTANDARD LVCMOS33} [get_ports touch_rst_n]
set_property -dict {PACKAGE_PIN U19 IOSTANDARD LVCMOS33} [get_ports touch_int]


# -----------------------------------------------------------------------------
# Clocks
# -----------------------------------------------------------------------------

# 50 MHz board oscillator, package pin U18 (board XDC:4).
create_clock -name sys_clk -period 20.000 -waveform {0.000 10.000} [get_ports sys_clk]

# LCD dot clock, package pin P19.
#
# ============================ PENDING DECISION ==============================
# The period below is 40.000 ns = 25.000 MHz, which is the vendor choice and
# gives 45.1 Hz refresh on the 1056x525 panel timing in nes_video_800x480.v.
# The alternative is 33.264 MHz = 30.060 ns, which gives 60 Hz:
#
#     1056 * 525 * 60 = 33,264,000 Hz exactly
#
# Both are legitimate; they are a design decision that has not been made yet,
# and it is the ONLY thing this line is waiting on.  Nothing else in this file
# depends on it, and the 24-bit LCD bus above is the same either way.
#
# The choice is not free inside the current clock module.  rtl/platform/zynq/
# nes_zynq_clk.v derives both clocks from one MMCM at a 1181.25 MHz VCO, and
# CLKOUT0's divide must be an exact multiple of 0.125:
#
#     f_lcd = 1181.25 / 47.25 = 25.000000000 MHz   (CLKOUT0_DIVIDE_F = 47.25)
#
# Reaching 33.264 MHz from that VCO needs 1181.25 / 33.264 = 35.521..., which is
# not a multiple of 0.125, so 33.264 MHz requires re-running the m/k derivation
# in that module's header comment, not just editing this period.  Both the
# divider parameter and this line move together.
#
# MEASURED, Vivado 2018.3 on xc7z020-clg400-2: this create_clock and the clock
# Vivado derives from the MMCM both land on the lcd_clk net, so there are two
# clock objects on it, "lcd_clk" from this line and "lcd_clk_OBUF" generated from
# u_clk/u_mmcm/CLKOUT0.  Measured state with the period below:
#
#     CLOCKOBJ sys_clk      period=20.000   (this file, primary)
#     CLOCKOBJ lcd_clk      period=40.000   (this file)
#     CLOCKOBJ lcd_clk_OBUF period=40.000   (derived by Vivado from CLKOUT0)
#
# check_timing reports 0 register/latch pins with multiple clocks and 0
# unconnected generated clocks, so the duplication is harmless while the two
# periods agree.  That is the whole safety margin: they agree only because this
# period is correct.  Change this line alone and the user clock and the derived
# clock will disagree, and the timing report will be silently wrong rather than
# loudly wrong.  So this line and CLKOUT0_DIVIDE_F must be changed together.
# ===========================================================================
create_clock -name lcd_clk -period 40.000 -waveform {0.000 20.000} [get_ports lcd_clk]


# -----------------------------------------------------------------------------
# NES core clock: 21.477272727272 MHz, period 46.561 ns  -- NO create_clock HERE
#
# Deliberately absent, and this is a decision rather than an omission:
#
#   * The core clock is not a top-level port.  It is the internal net driven by
#     CLKOUT1 of the MMCME2_BASE in rtl/platform/zynq/nes_zynq_clk.v
#     (nes_zynq_clk.v:153, .CLKOUT1(core_clk)), so there is no [get_ports] to
#     attach a create_clock to.
#   * Vivado derives the generated clock on every MMCME2_BASE output itself
#     during synthesis, from CLKIN1_PERIOD and the divider parameters.  Writing
#     a create_clock or a create_generated_clock here as well would put a second,
#     competing definition of the same clock into the design and the timing
#     engine would be arbitrating between two sources of truth.
#
# So the exact frequency is already fully determined by the MMCM parameters
# that are already in the RTL, and 46.561 ns is recorded here only so the number
# is greppable next to the LCD clock it is derived with:
#
#     f_core = (50 * 23.625) / 55 = 1181.25 / 55 = 21.477272727272 MHz
#
# No separate generated-clock constraint is needed for correct timing analysis.
# If the core clock ever stops being an MMCM output, or if a generated clock has
# to be re-specified for a mode the primitive does not describe, that is the
# moment to add one here, and it must be a create_generated_clock with
# -source [get_pins <mmcm>/CLKOUT1], not a second create_clock.
#
# MEASURED, Vivado 2018.3 report_clocks on xc7z020-clg400-2 with this file read
# and nes_zynq_clk.v instantiated.  Vivado derives all three MMCM output clocks
# from sys_clk with no help from this file, and the core period comes out at
# exactly the number above:
#
#     Generated Clock     : core_clk       Master: sys_clk  Period: 46.561
#     Generated Sources   : {u_clk/u_mmcm/CLKOUT1}
#     Generated Clock     : lcd_clk_OBUF   Master: sys_clk  Period: 40.000
#     Generated Sources   : {u_clk/u_mmcm/CLKOUT0}
#     Generated Clock     : clkfb_out      Master: sys_clk  Period: 20.000
#     Generated Sources   : {u_clk/u_mmcm/CLKFBOUT}
#
# check_timing on that build: 0 register/latch pins with no clock, 0 with
# multiple clocks, 0 unconnected generated clocks, 0 unconstrained internal
# endpoints, 0 combinational loops.  That is the evidence for leaving this clock
# out of the file rather than a guess.
# -----------------------------------------------------------------------------


# -----------------------------------------------------------------------------
# I/O timing: NOT CONSTRAINED, AND DELIBERATELY NOT GUESSED
#
# check_timing on the measured build above reports, at HIGH severity:
#
#   * 1 input port with no input delay  : sys_rst_n
#   * 27 ports with no output delay     : lcd_rgb[23:0], lcd_de, touch_scl,
#                                         touch_sda
#
# So the clocking is constrained and the core closes timing, but the port paths
# are timed against nothing.  This is left open rather than filled in because
# set_input_delay and set_output_delay need real numbers that no vendor file
# supplies: the LCD panel's setup and hold across the ribbon, and the ATK touch
# controller's I2C timing over R19/P20.  Inventing those would produce a report
# that looks authoritative and is not, which is worse than an honest gap.
#
# The LCD side is the one that will actually bite, because lcd_de and lcd_rgb
# leave on the 40.000 ns dot clock with no output delay to judge them against.
# Whoever closes this should read the panel's datasheet for the DE-mode timing
# and add the delays against [get_clocks lcd_clk].
# -----------------------------------------------------------------------------


# -----------------------------------------------------------------------------
# TOUCH BUTTON CDC: sys_clk -> mmcm_core_clk, BOUNDED, NOT EXCUTED
#
# The eight failing endpoints on the routed design were all
#     u_touch/touch_*_q_reg[*]/C  ->  btn_meta_q_reg[7..0]/D
# at WNS -2.665, and each was only 3 logic levels and 3.232 ns deep.  The
# depth is not the problem.  The REQUIREMENT is: btn_meta_q is clocked by
# mmcm_core_clk, and mmcm_core_clk is an MMCM output derived from sys_clk, so
# Vivado treats the two as a synchronous, phase-related pair and computes a
# setup window of 0.106 ns for a path that physically needs 3.232 ns.  A 3 ns
# path against a 0.1 ns requirement fails by construction, and no amount of
# placement will fix it.
#
# WHY NOT set_clock_groups -asynchronous
#   The two clocks are NOT asynchronous.  mmcm_core_clk is produced from
#   sys_clk by the MMCME2_BASE in nes_zynq_clk.v, so there is a defined, fixed
#   frequency and phase relationship between them that Vivado derives and that
#   the rest of the design relies on.  Declaring them asynchronous would be a
#   false statement about the hardware, and it would additionally remove the
#   timing relationship between the two domains everywhere, not just on the
#   eight button bits.  It is the wrong tool because the real property here is
#   not "these clocks are unrelated", it is "this one path crosses domains and
#   its only obligation is to be short".
#
# WHY set_max_delay -datapath_only AND NOT set_false_path
#   A blanket false path on the same eight endpoints would silence the
#   violation with no constraint left standing, and an unbounded false path is
#   exactly how a metastability synchroniser ends up with its two stages
#   placed on opposite sides of the die.  set_max_delay -datapath_only keeps a
#   real bound on the physical delay while removing the meaningless setup
#   check, which is the standard treatment for a synchroniser input stage:
#
#     * the delay is still bounded, so btn_meta_q stays adjacent to its source
#       and the ASYNC_REG attribute can do its job;
#     * the bound is 20.000 ns, the SOURCE clock period, so the path is
#       checked against a number the design can actually meet (it needs
#       3.232 ns) rather than against a 0.106 ns coincidence of two edges;
#     * it applies ONLY to the source-to-first-stage arcs.  The second stage
#       btn_meta_q -> btn_sync_q is intra-core_clk and stays fully timed, so
#       the synchroniser's own settling window is still analysed.
#
# 20.000 ns is used rather than the 46.561 ns destination period because the
# bound should be the tighter of the two: the point of the constraint is to
# keep this path short, and the source period is the shorter period.
#
# The expression is scoped to the first-stage flops and to the touch module's
# own flops, so nothing else in the design is affected by it.
# -----------------------------------------------------------------------------
set_max_delay -datapath_only 20.000 \
    -from [get_cells -quiet -hierarchical -filter {NAME =~ *u_touch/*}] \
    -to   [get_cells -quiet -hierarchical -filter {NAME =~ *btn_meta_q_reg[*]}]


# =============================================================================
# AUDIO LANE: WM8960, I2S out plus a control I2C
#
# I2S interface, WM8960 on the Navigator V2 board
# board XDC:120  aud_bclk     M18
# board XDC:121  aud_dac_lrc  G18
# board XDC:122  aud_adc_lrc  L20
# board XDC:123  aud_adcdat   M17
# board XDC:124  aud_dacdat   G17
# board XDC:125  aud_mclk     E19
#
# DISCREPANCY, RESOLVED HERE: the vendor pin table spreadsheet says aud_dacdat
# is G18.  That is wrong, G18 is aud_dac_lrc per board XDC:121 above.  The
# board XDC and the per-example audio pin.xdc both put aud_dacdat on G17, so G17
# is used.  Consequence stated so it is not mistaken for a typo here: G18 and
# G17 are two different signals, and a build that follows the spreadsheet puts
# the DAC data and the DAC LRC on the same pin.
#
# Codec control I2C, shared with the board EEPROM and RTC
# board XDC:37   iic_scl E18   (board XDC calls it iic_scl, this lane aud_iic_scl)
# board XDC:38   iic_sda F17   (board XDC calls it iic_sda, this lane aud_iic_sda)
#
# This is one physical I2C bus, not a private one to the codec.  Anything else
# on the board that wants EEPROM or RTC access has to share it, so only one
# master may be driving.  Note that this bus is NOT the same pins as the touch
# I2C above: touch is R19/P20, the codec is E18/F17.  They are separate.
#
# Port widths: all six of these are single-bit signals, which is what the
# vendor pins require and all that can be claimed.  rtl/nes_core/peripheral/
# nes_audio_i2s.v agrees, it presents single-bit bclk / lrck / dout.
#
# aud_mclk IS AN OUTPUT, NOT AN INPUT
#   The old comment here said nes_audio_i2s.v "takes mclk as an INPUT, so
#   aud_mclk is a clock into that module" and concluded aud_mclk "will need its
#   own create_clock here".  That conclusion was wrong in a way that matters.
#   mclk is an input to nes_audio_i2s, yes, but in the platform top it is
#   DRIVEN: nes_zynq_top.v ties the module's mclk port and the aud_mclk pin to
#   the same net, mmcm_lcd_clk.  The direction of the codec's pin is therefore
#   output-from-the-FPGA, exactly like lcd_clk.  This is deliberate: it makes
#   mclk and rd_clk the same net, so bclk is a divided version of rd_clk and
#   the unsynchronised two-bit sampling at nes_audio_i2s.v:241-249 becomes a
#   phase-related same-clock hand-off instead of a CDC.  See the AUDIO LANE
#   block in the platform top's header, item 4.
#
# NO create_clock ON aud_mclk, AND WHY THAT IS THE RIGHT ANSWER
#   aud_mclk is not an independent clock source: it is the mmcm_lcd_clk net,
#   driven by CLKOUT0 of the MMCME2_BASE.  Vivado already derives
#   lcd_clk_OBUF on that net at 40.000 ns from CLKOUT0, and report_clocks on
#   the measured build below confirms it:
#       Generated Clock : lcd_clk_OBUF  Master Clock: sys_clk  Period: 40.000
#       Generated Sources: {u_clk/u_mmcm/CLKOUT0}
#   Adding a user create_clock on the aud_mclk PORT would put a second,
#   competing definition of that clock into the design, which is precisely the
#   hazard documented at the lcd_clk create_clock above ("a user clock and the
#   derived clock will disagree, and the timing report will be silently wrong
#   rather than loudly wrong").  The lcd_clk port already shows how that looks:
#   two clock objects on one net, harmless only while the periods agree.
#   There is nothing to time FROM aud_mclk either: no register in this design
#   is clocked by it, it only feeds the bclk divider inside nes_audio_i2s,
#   whose registers are on lcd_clk_OBUF.  So the correct treatment is no
#   constraint at all here.
#
# bclk IS A REAL CLOCK, AND AN EARLIER DRAFT OF THIS FILE WAS WRONG ABOUT IT
#   bclk is the mclk net divided by BCLK_DIV = 16 inside nes_audio_i2s, and it
#   does clock real registers: the one-bit I2S delay flop aud_dout_d_q in this
#   platform top, plus dout_r and lrck_r inside nes_audio_i2s.  An earlier draft
#   of this comment block claimed that "clock propagation derives a generated
#   clock on the divider output net from the mmcm_core_clk / lcd_clk_OBUF master
#   automatically, exactly as it does for the MMCM itself, so no
#   create_generated_clock is needed".  That is false, and check_timing on the
#   measured build is what says so:
#       1. checking no_clock
#        There are 3 register/latch pins with no clock driven by root clock
#        pin: u_audio_i2s/bclk_int_reg/Q (HIGH)
#        aud_dout_d_q_reg/C
#        u_audio_i2s/dout_r_reg/C
#        u_audio_i2s/lrck_r_reg/C
#   The MMCM is a primitive and Vivado knows CLKOUT0 is a clock source, so it
#   derives a clock for that.  bclk_int is just a flip-flop toggling on a clock
#   enable, which Vivado treats as ordinary logic, not as a clock source, and
#   report_clocks on the same build lists only sys_clk, lcd_clk, clkfb_out,
#   aud_mclk_OBUF and mmcm_core_clk -- no bclk among them.  The previous
#   no-audio build had "There are 0 register/latch pins with no clock", so these
#   three are new with this lane and are fixed here rather than explained away.
#
#   So it does need create_generated_clock, and the target has to be the aud_bclk
#   PORT.  Targeting the internal net u_audio_i2s/bclk instead was tried and is
#   worse: report_clocks on that build does not list aud_bclk at all, so
#   create_generated_clock on that net creates no clock object and the build
#   silently loses the 640 ns period.  The port works, aud_bclk appears in
#   report_clocks at 640.000 ns, and the 640 ns BCLK period that
#   tb_nes_audio_lane measures on the real pin is reproduced in the timing
#   report rather than only in simulation.
#
#   -source is the clock pin of the divider flip-flop, which is the mclk net
#   (lcd_clk_OBUF / aud_mclk_OBUF, 40.000 ns), and -divide_by 16 gives
#   640.000 ns = 1.5625 MHz.
#
#   This is deliberately not written as a second create_clock on the port, for
#   the same reason as the aud_mclk block above: this has to be a generated clock
#   of a clock Vivado already knows, or the design ends up with a bclk whose
#   relationship to lcd_clk_OBUF is unknown and the timing report is wrong
#   without saying so.
#
# TWO check_timing ITEMS ARE LEFT STANDING, ON PURPOSE
#   With the port target, check_timing still reports
#       There are 3 register/latch pins with no clock driven by root clock pin:
#       u_audio_i2s/bclk_int_reg/Q (HIGH)
#       There are 6 pins that are not constrained for maximum delay. (HIGH)
#           aud_dout_d_q_reg/CLR          aud_dout_d_q_reg/D
#           u_audio_i2s/dout_r_reg/CLR    u_audio_i2s/dout_r_reg/D
#           u_audio_i2s/lrck_r_reg/CLR    u_audio_i2s/lrck_r_reg/D
#   Both come from the same root cause and neither is closable from this file.
#   The bclk root is a fabric flip-flop output, because nes_audio_i2s divides
#   mclk with a clock enable (nes_audio_i2s.v:225-232) instead of instantiating
#   a BUFGCE or a clocking-wizard output.  Vivado will name the resulting domain
#   but will not build a launch/capture requirement inside it, so the D and CLR
#   pins of the three registers in that domain are listed as unconstrained.
#   nes_audio_i2s.v owns that divider and owns dout_r and lrck_r, and it is not
#   in this change's writable set, so the real fix belongs there: drive bclk from
#   a BUFGCE clocking a counter in the lcd_clk domain, or add a clocking-wizard
#   BCLK output.  Suppressing the two notes with set_false_path would hide a
#   real unanalysed region on the I2S data path, so they are left in the report.
#   The audio lane as it stands is still timed and still meets setup and hold
#   everywhere, and the 640 ns domain itself is the slowest clock in the design,
#   so the unanalysed arcs have a full 640 ns of slack by construction.
#
# I/O TIMING ON THESE PINS IS STILL NOT CONSTRAINED
#   The audio pins are all LVCMOS33 outputs with no set_output_delay, for the
#   same reason the LCD and touch pins have none: inventing a number that no
#   vendor file supplies produces a report that looks authoritative and is not.
#   check_timing on the measured build lists them among the ports with no
#   output delay.  That is an honest gap, not an oversight, and it is the same
#   gap that already exists on lcd_de / lcd_rgb.
# -----------------------------------------------------------------------------
set_property -dict {PACKAGE_PIN M18 IOSTANDARD LVCMOS33} [get_ports aud_bclk]
set_property -dict {PACKAGE_PIN G18 IOSTANDARD LVCMOS33} [get_ports aud_dac_lrc]
set_property -dict {PACKAGE_PIN G17 IOSTANDARD LVCMOS33} [get_ports aud_dacdat]
set_property -dict {PACKAGE_PIN E19 IOSTANDARD LVCMOS33} [get_ports aud_mclk]
set_property -dict {PACKAGE_PIN E18 IOSTANDARD LVCMOS33} [get_ports aud_iic_scl]
set_property -dict {PACKAGE_PIN F17 IOSTANDARD LVCMOS33} [get_ports aud_iic_sda]

create_generated_clock -name aud_bclk \
    -source [get_pins u_audio_i2s/bclk_int_reg/C] \
    -divide_by 16 \
    [get_ports aud_bclk]


# -----------------------------------------------------------------------------
# aud_adc_lrc (L20) AND aud_adcdat (M17): DELIBERATELY NOT CONSTRAINED
#
# board XDC:122 and :123 put these on real pins of the real package, so the pin
# names are valid.  They are not constrained here because the top level does
# not declare them, and the reason is that nothing in this design can drive or
# consume them:
#
#   * rtl/nes_core/peripheral/nes_audio_i2s.v is TRANSMIT ONLY.  It has a bclk
#     input, an lrck input and a dout input from the shifter, and outputs
#     bclk, lrck and dout.  There is no adcdat input and no adclrc input, so
#     there is nothing for the codec's ADCDAT pin to connect to.
#   * The WM8960 ADCLRC/GPIO1 pin is ADCLRC whenever R9 bit 6 ALRCGPIO is 0,
#     which is its power-on default and which the power-on table in
#     wm8960_i2c.v leaves alone.  With ADCLRC unused, and with the ADCs
#     powered down (R25 ADCL = ADCR = 0), ADCLRC and ADCDAT are held inactive
#     by the codec.
#   * Inventing an ADC path would mean an I2S receiver, a second CDC in the
#     other direction and a register to unmute the ADCs, none of which exist.
#     So the pins are left exactly as the board leaves them: unconnected.
#
# Uncommenting either line without adding the matching port would produce
# Vivado 12-584 "No ports matched", which is why they stay commented.
# set_property -dict {PACKAGE_PIN L20 IOSTANDARD LVCMOS33} [get_ports aud_adc_lrc]
# set_property -dict {PACKAGE_PIN M17 IOSTANDARD LVCMOS33} [get_ports aud_adcdat]


# =============================================================================
# AUDIO FIFO CDC: mmcm_core_clk <-> lcd_clk, BOUNDED, NOT EXCUTED
#
# This is the THIRD cross-domain boundary and it is new.  The other two are the
# touch buttons (sys_clk -> core_clk, bounded at the create_clock block above)
# and frame_mem (core_clk write port, lcd_clk read port).  frame_mem is a true
# simple-dual-port RAM so it costs no flip-flop arcs at all; the audio FIFO is a
# real dual-clock FIFO with Gray coded pointers, so it DOES contain
# core_clk -> lcd_clk and lcd_clk -> core_clk flip-flop arcs, both of which
# terminate on the first stage of a two-flop synchroniser marked ASYNC_REG.
#
# WHY THE VIOLATION IS BY CONSTRUCTION AND NOT BY PLACEMENT
#   Same reason as the touch buttons: mmcm_core_clk and lcd_clk are both MMCM
#   outputs derived from sys_clk through the same primitive, so Vivado treats
#   them as a synchronous, phase-related pair and computes a setup window of
#   about 0.1 ns for a path that physically needs nanoseconds.  The eight button
#   bits failed at -2.665 ns that way before they were bounded.
#
# WHY NOT set_clock_groups -asynchronous AND WHY NOT set_false_path
#   Exactly the arguments written out at the touch button block above, and they
#   apply verbatim: the two clocks are not asynchronous, they share a VCO; and
#   an unbounded false path is how a synchroniser's two stages end up on
#   opposite sides of the die.  set_max_delay -datapath_only keeps a real bound
#   on the physical delay, removes the meaningless setup check, and leaves the
#   second stage intra-domain and fully timed.
#
# 40.000 ns is the bound on both, because lcd_clk is the shorter of the two
# periods (46.561 ns for mmcm_core_clk) and the rule already used above is that
# the bound is the tighter of the two.  -from and -to are the source pointer
# and the FIRST synchroniser stage only, so the second stage
# rd_gray_sync1 -> rd_gray_sync2 and wr_gray_sync1 -> wr_gray_sync2 keep their
# normal intra-domain checks.
#
# DIRECTION, AND WHY THE OBVIOUS NAMING IS THE WRONG ONE TO TRUST HERE
#   In nes_cdc_fifo the registers are named after WHICH POINTER they carry, not
#   after the clock they sit in.  wr_gray_sync1/sync2 are clocked by rd_clk
#   (nes_cdc_fifo.v:152) and rd_gray_sync1/sync2 are clocked by wr_clk
#   (nes_cdc_fifo.v:142).  So the write pointer travels core_clk -> lcd_clk as
#   wr_gray_reg -> wr_gray_sync1_reg, and the read pointer travels lcd_clk ->
#   core_clk as rd_gray_reg -> rd_gray_sync1_reg.  Reading the names as "wr_*
#   goes to the wr side" swaps the two bounds and leaves 14 endpoints timing
#   against a full destination period.  Measured on the first routed build of
#   this lane with the bounds swapped: wr_gray_reg[0..6]/C ->
#   wr_gray_sync1_reg[0..6]/D at -1.633 to -1.775 ns and rd_gray_reg[0..6]/C ->
#   rd_gray_sync1_reg[0..6]/D at -1.727 to -1.879 ns, both of which are the
#   first-hop delay and nothing to do with the synchroniser actually failing.
#
# THE THIRD BOUND, THE FIFO READ MUX, WHICH THE OTHER TWO DO NOT COVER
#   mem_reg[*][*] is written on wr_clk and rd_data_reg[*] is loaded on rd_clk,
#   so the 32-bit read multiplexer is a fourth core_clk -> lcd_clk arc that the
#   two pointer bounds do not touch.  It is safe to bound for the same reason the
#   pointers are: wr_full only clears after rd_gray_sync2 has travelled the other
#   way, so by the time rd_bin can select a given word that word has been stable
#   for a full pointer round trip.  Unbounded it is the worst arc in the design,
#   32 endpoints at -2.749 to -3.134 ns.
#
# The cell name patterns are matched with a leading and trailing wildcard on
# purpose: the filter NAME =~ *wr_gray_reg* also matches wr_gray_reg[0..6], and
# it does NOT match wr_gray_sync1_reg or wr_gray_sync2_reg.
# -----------------------------------------------------------------------------
set_max_delay -datapath_only 40.000 \
    -from [get_cells -quiet -hierarchical -filter {NAME =~ *u_audio_i2s/u_fifo/wr_gray_reg*}] \
    -to   [get_cells -quiet -hierarchical -filter {NAME =~ *u_audio_i2s/u_fifo/wr_gray_sync1_reg*}]
set_max_delay -datapath_only 40.000 \
    -from [get_cells -quiet -hierarchical -filter {NAME =~ *u_audio_i2s/u_fifo/rd_gray_reg*}] \
    -to   [get_cells -quiet -hierarchical -filter {NAME =~ *u_audio_i2s/u_fifo/rd_gray_sync1_reg*}]
set_max_delay -datapath_only 40.000 \
    -from [get_cells -quiet -hierarchical -filter {NAME =~ *u_audio_i2s/u_fifo/mem_reg*}] \
    -to   [get_cells -quiet -hierarchical -filter {NAME =~ *u_audio_i2s/u_fifo/rd_data_reg*}]
# -----------------------------------------------------------------------------


# =============================================================================
# CODEC cfg_done: sys_clk -> core_clk AND sys_clk -> lcd_clk, BOUNDED
#
# wm8960_i2c runs on sys_clk because the control I2C is deliberately slow and has
# no reason to be in either fast domain.  Its cfg_done is the release for the two
# audio resets (rst_audio_wr = rst_core | ~codec_cfg_core_q1 and rst_audio_rd =
# rst_lcd | ~codec_cfg_lcd_q1), so it is a two-flop synchroniser into BOTH fast
# domains and therefore two more crossing arcs.  Measured unbounded on the first
# routed build: u_codec_i2c/cfg_done_q_reg/C -> codec_cfg_core_q0_reg/D at
# -1.524 ns, the only sys_clk -> mmcm_core_clk failure in the design.
#
# 20.000 ns on both, by the same tighter-of-the-two rule as the touch buttons
# block above: sys_clk is 20 ns and it is the shorter period here.  The endpoint
# is scoped to the q0 first stage only, so q0 -> q1 keeps its normal intra-domain
# check.
# -----------------------------------------------------------------------------
set_max_delay -datapath_only 20.000 \
    -from [get_cells -quiet -hierarchical -filter {NAME =~ *u_codec_i2c/cfg_done_q_reg*}] \
    -to   [get_cells -quiet -hierarchical -filter {NAME =~ *codec_cfg_core_q0_reg*}]
set_max_delay -datapath_only 20.000 \
    -from [get_cells -quiet -hierarchical -filter {NAME =~ *u_codec_i2c/cfg_done_q_reg*}] \
    -to   [get_cells -quiet -hierarchical -filter {NAME =~ *codec_cfg_lcd_q0_reg*}]
# =============================================================================

# =============================================================================
# MEASURED STATE, AUDIO LANE, xc7z020-clg400-2, Vivado 2018.3
#
# Full non-OOC flow (synth -> opt -> place -> phys_opt -> route) in the
# throwaway tree D:\vivadoProject\audio_probe, on a copy of rtl/ with
# rtl/nes_core/cart/*.hex copied alongside so the PRG ROM stays in BRAM.
#
# Design Timing Summary, routed:
#     WNS  +1.606   TNS 0.000   0 failing / 81553 setup endpoints
#     WHS  +0.083   THS 0.000   0 failing / 81529 hold  endpoints
#     WPWS +7.000   TPWS 0.000   0 failing / 39350 pulse width endpoints
#
# Intra clock:
#     mmcm_core_clk   WNS +1.606   0 failing / 78684
#     sys_clk         WNS +13.315  0 failing /   325
#     aud_mclk_OBUF   WNS +27.541  0 failing /   899
#
# Inter clock, every pair that has a path, all 0 failing:
#     sys_clk -> aud_mclk_OBUF         +15.254    1 endpoint
#     mmcm_core_clk -> aud_mclk_OBUF    +35.858   39 endpoints
#     sys_clk -> mmcm_core_clk          +16.671    9 endpoints
#     aud_mclk_OBUF -> mmcm_core_clk    +38.560    7 endpoints
#     sys_clk -> lcd_clk, lcd_clk -> sys_clk,
#     sys_clk -> clkfb_out, clkfb_out -> sys_clk,
#     aud_bclk -> mmcm_core_clk        all 0 failing
#
# report_clocks, routed:
#     sys_clk            20.000 ns  50.000 MHz   primary, [get_ports sys_clk]
#     lcd_clk            40.000 ns  25.000 MHz   primary, [get_ports lcd_clk]
#     clkfb_out          20.000 ns  50.000 MHz   from u_clk/u_mmcm/CLKFBOUT
#     aud_mclk_OBUF      40.000 ns  25.000 MHz   from u_clk/u_mmcm/CLKOUT0
#     mmcm_core_clk      46.561 ns  21.477 MHz   from u_clk/u_mmcm/CLKOUT1
#     aud_bclk          640.000 ns   1.562 MHz   aud_bclk, the create_generated_clock
#
# Utilisation, routed:
#     Slice LUTs        40424 /  53200   75.98 %
#     Slice Registers   39258 / 106400   36.90 %
#     Block RAM Tile        50 /    140   35.71 %    <- 50, so the PRG ROM is in BRAM
#     DSPs                  0 /    220    0.00 %
#
# Route: 43504 nets not needing routing, 60745 fully routed, 0 routing errors.
# report_drc: 0 errors.  The remaining warnings are pre-existing and not audio:
# PDCN-137 and REQP-1839 on the CHR RAMB36, RPBF-3 IO buffering, CHECK-3.
#
# THE CORE CLOCK MARGIN WENT UP, NOT DOWN
#   The no-audio build had mmcm_core_clk at +0.855 ns.  Adding the audio lane
#   put it at +0.814 ns on the first routed build, with the CDC arcs below
#   unbounded.  Once the crossing arcs are bounded, the placer stops dragging
#   the core domain around to satisfy meaningless requirements and the same
#   clock lands at +1.606 ns, which is 0.751 ns more margin than the design had
#   before any of this existed.
# =============================================================================
