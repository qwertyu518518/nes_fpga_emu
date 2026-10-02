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
# What has NOT been checked, because the platform top does not exist yet: that
# this file's port names match what the real top will declare.  Until then a
# rename in the top silently produces Vivado 12-584 "No ports matched" instead
# of a build failure, and a pin left unconstrained places wherever the placer
# likes.  That is the remaining risk on this file, and it is not closable from
# here.
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
# AUDIO LANE -- COMMENTED OUT, NOT YET BUILT
#
# The codec register configuration and the I2S data path do not exist yet, so
# these pins are not ports of the platform top.  They are recorded here
# commented so the board facts are captured once and the block can be
# uncommented verbatim if the audio lane is included.  Uncommenting before the
# ports exist produces Vivado 12-584 "No ports matched" warnings on every line.
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
# Port widths: all eight of these are single-bit signals, which is what the
# vendor pins require and all that can be claimed.  rtl/nes_core/peripheral/
# nes_audio_i2s.v agrees, it presents single-bit bclk / lrck / dout.  Note that
# nes_audio_i2s.v takes mclk as an INPUT, so aud_mclk is a clock into that
# module, not a signal it drives.  If the audio lane is included, aud_mclk will
# need its own create_clock here, generated from sys_clk or from the MMCM, and
# the aud_adc_lrc / aud_adcdat pair has no counterpart in nes_audio_i2s.v at
# all, so the ADC path would be a module that does not exist yet.
#
# set_property -dict {PACKAGE_PIN M18 IOSTANDARD LVCMOS33} [get_ports aud_bclk]
# set_property -dict {PACKAGE_PIN G18 IOSTANDARD LVCMOS33} [get_ports aud_dac_lrc]
# set_property -dict {PACKAGE_PIN L20 IOSTANDARD LVCMOS33} [get_ports aud_adc_lrc]
# set_property -dict {PACKAGE_PIN M17 IOSTANDARD LVCMOS33} [get_ports aud_adcdat]
# set_property -dict {PACKAGE_PIN G17 IOSTANDARD LVCMOS33} [get_ports aud_dacdat]
# set_property -dict {PACKAGE_PIN E19 IOSTANDARD LVCMOS33} [get_ports aud_mclk]
# set_property -dict {PACKAGE_PIN E18 IOSTANDARD LVCMOS33} [get_ports aud_iic_scl]
# set_property -dict {PACKAGE_PIN F17 IOSTANDARD LVCMOS33} [get_ports aud_iic_sda]
#
# DIRECTION if uncommented: aud_bclk / aud_dac_lrc / aud_mclk and aud_iic_scl are
# outputs.  aud_dacdat is an output.  aud_adcdat and aud_adc_lrc are inputs,
# driven by the codec.  aud_iic_sda is inout, open drain like any I2C.
# =============================================================================
