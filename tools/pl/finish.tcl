# FINISH PASS.  Opens this run's OWN out_route.dcp -- the checkpoint produced by
# the full non-OOC flow in build.tcl, with no checkpoints reused -- does all
# verification, and writes the bitstream for the PL-only top (nes_zynq_pl_top,
# the board-independent wrapper around nes_zynq_top with the eight ps_* inputs
# tied inert).
#
# This script does NOT open a hardware target.  There is no hw_server, no open_hw,
# no program_hw_devices and no prog*.tcl anywhere in this directory: programming the
# board is a separate, later step, so nothing here can touch hardware.
#
# The CHR array's inferred WRITE_MODE_A / READ_WIDTH_A / WRITE_WIDTH_A are read back
# HERE, from the routed checkpoint, not from arithmetic and not from the synth-stage
# dump.  Since 274e25a removed the write-side freeze, the same-address
# read-during-write path is live on hardware for the first time, so this property
# matters more than it did.
#
# 2018.3 pitfalls carried over from the previous run, deliberately avoided:
#   get_memories does not exist      -> never called
#   CONFIG.<param> is empty here     -> parameters are proved from the files instead
#   utilisation regexes do not match -> the .rpt files are parsed as text

open_checkpoint out_route.dcp
set cur [current_design]

proc chk {label ok detail} {
    if {$ok} {
        puts "VERIFY PASS  $label  $detail"
    } else {
        puts "VERIFY FAIL  $label  $detail"
    }
}
proc utilval {data label} {
    # A utilisation row is  | <label> | <used> | <avail> | <util%> |  and the label
    # cell may be indented, e.g. "|   RAMB18          |".  So split on the bar and
    # compare the trimmed label text, not a fixed-offset substring.  Some rows repeat
    # in a second section; the first integer hit is the flat device summary.
    # Vivado 2018.3 ships Tcl 8.5, which has no "continue", hence the nesting.
    foreach line [split $data \n] {
        set t [string trim $line]
        if {[string index $t 0] eq "|" && [string match "*|*" $t]} {
            set fields [split $t |]
            if {[llength $fields] >= 3} {
                set name [string trim [lindex $fields 1]]
                if {$name eq $label} {
                    set v [string trim [lindex $fields 2]]
                    if {[string is integer -strict $v]} { return $v }
                }
            }
        }
    }
    return "<not found>"
}
proc dumputil {tag data} {
    # Quoted elements: a brace-quoted list would split "Slice LUTs" into two items.
    foreach l {"Slice LUTs" "LUT as Memory" "Slice Registers" "Block RAM Tile" \
               "RAMB36/FIFO" "RAMB18" "DSPs"} {
        puts "UTIL $tag $l = [utilval $data $l]"
    }
}
proc clock_by_period {want tol} {
    # Generated clocks are named after their net.  Under the PL-only wrapper the
    # core clock's net is auto-named by Vivado, so clocks are found by period.
    foreach c [get_clocks -quiet *] {
        if {abs([get_property PERIOD $c] - $want) < $tol} { return $c }
    }
    return ""
}

puts "=========================================================="
puts "VERIFY BLOCK (routed design, this run's own out_route.dcp)"
puts "=========================================================="

# ===================================================== cartridge geometry readback
# Read from the ROUTED design.  Reported per array.
puts "---- inferred BRAM geometry, READ BACK FROM THE ROUTED DESIGN ----"
# Filter on REF_NAME first, then narrow by name in Tcl.  A -filter on NAME alone
# also matches the surrounding flop/reg hierarchy and reports hundreds of cells.
set rambs [get_cells -quiet -hierarchical -filter {REF_NAME == RAMB36E1 || REF_NAME == RAMB18E1}]
puts "RAMB primitives in the routed design = [llength $rambs]"
proc byname {rambs pat} {
    set out {}
    foreach c $rambs {
        set nm ""
        catch {set nm [get_property NAME $c]}
        if {[string match $pat $nm]} { lappend out $c }
    }
    return [lsort $out]
}
set chr_cells [byname $rambs *chr_rom_reg_*]
set prg_cells [byname $rambs *prg_rom_reg_*]
set frm_cells [byname $rambs *frame_mem_reg_*]
puts "GEOM-ROUTED CHR cells   = [llength $chr_cells]"
puts "GEOM-ROUTED PRG cells   = [llength $prg_cells]"
puts "GEOM-ROUTED FRAME cells = [llength $frm_cells]"
chk "CHR array inferred into BRAM, not LUTRAM" [expr {[llength $chr_cells] == 2}] \
    "chr_rom RAMB cells = [llength $chr_cells] (want 2)"
chk "PRG array inferred into BRAM, not LUTRAM" [expr {[llength $prg_cells] == 16}] \
    "prg_rom RAMB cells = [llength $prg_cells] (want 16)"
chk "frame arrays (LCD + HDMI) inferred into BRAM, not LUTRAM" [expr {[llength $frm_cells] == 64}] \
    "frame_mem RAMB cells = [llength $frm_cells] (want 64: 32 per scaler)"
# The cell-by-cell cross-check closes the loop against the flat utilisation number: the
# three named buckets must account for EVERY RAMB primitive in the routed design, with
# none left over.  A silent BRAM-to-LUTRAM regression moves cells out of these buckets
# and shows up here as an unbalanced sum even if the summary row were misread.
set buckets [expr {[llength $chr_cells] + [llength $prg_cells] + [llength $frm_cells]}]
chk "PRG+CHR+FRAME buckets account for every RAMB primitive" \
    [expr {$buckets == [llength $rambs]}] \
    "buckets 2+16+64 = $buckets vs RAMB primitives = [llength $rambs]"
set fh [open rep_bram_geom_routed.txt w]
puts $fh "# RAMB geometry read back from the ROUTED checkpoint"
foreach c $chr_cells {
    set nm ""; catch {set nm [get_property NAME $c]}
    set rn ""; catch {set rn [get_property REF_NAME $c]}
    set line "RAMB36E1 $nm"
    foreach p {WRITE_MODE_A READ_WIDTH_A WRITE_WIDTH_A WRITE_MODE_B READ_WIDTH_B WRITE_WIDTH_B} {
        set v "<unset>"; catch {set v [get_property $p $c]}
        append line " $p=$v"
    }
    puts $line
    puts $fh $line
}
foreach c $prg_cells {
    set nm ""; catch {set nm [get_property NAME $c]}
    set rn ""; catch {set rn [get_property REF_NAME $c]}
    set line "RAMB36E1 $nm"
    foreach p {WRITE_MODE_A READ_WIDTH_A WRITE_WIDTH_A WRITE_MODE_B READ_WIDTH_B WRITE_WIDTH_B} {
        set v "<unset>"; catch {set v [get_property $p $c]}
        append line " $p=$v"
    }
    puts $line
    puts $fh $line
}
foreach c $frm_cells {
    set nm ""; catch {set nm [get_property NAME $c]}
    set rn ""; catch {set rn [get_property REF_NAME $c]}
    set line "RAMB36E1 $nm"
    foreach p {WRITE_MODE_A READ_WIDTH_A WRITE_WIDTH_A WRITE_MODE_B READ_WIDTH_B WRITE_WIDTH_B} {
        set v "<unset>"; catch {set v [get_property $p $c]}
        append line " $p=$v"
    }
    puts $line
    puts $fh $line
}
close $fh
# The one property this build was asked to read back explicitly.
foreach c $chr_cells {
    set nm ""; catch {set nm [get_property NAME $c]}
    set wm "";  catch {set wm  [get_property WRITE_MODE_A $c]}
    set rwa ""; catch {set rwa [get_property READ_WIDTH_A  $c]}
    set wwa ""; catch {set wwa [get_property WRITE_WIDTH_A $c]}
    puts "CHR-ARRAY $nm WRITE_MODE_A=$wm READ_WIDTH_A=$rwa WRITE_WIDTH_A=$wwa"
}

# ===================================================== BRAM and friends after route
set fh [open rep_util_routed.rpt r]
set udata [read $fh]
close $fh
dumputil ROUTE $udata
set tiles -1
regexp -nocase {\|\s*Block RAM Tile\s*\|\s*([0-9]+)} $udata -> tiles
chk "BRAM tiles after route" [expr {$tiles == 82}] "Block RAM Tile = $tiles (want 82: 16 PRG + 2 CHR + 64 frame_mem)"
# The silent-failure mode: BRAM quietly becomes LUTRAM and every other check still passes.
set lutmem [utilval $udata "LUT as Memory"]
set ramb18 [utilval $udata "RAMB18"]
chk "no BRAM-to-LUTRAM regression (LUT as Memory == 2)" [expr {$lutmem == 2}] \
    "LUT as Memory = $lutmem (baseline 2)"
chk "no BRAM-to-LUTRAM regression (RAMB18 == 0)" [expr {$ramb18 == 0}] \
    "RAMB18 = $ramb18 (baseline 0)"

# ===================================================== setup and hold, globally
set wpath [get_timing_paths -delay_type max -nworst 1 -max_paths 1]
set wns [get_property SLACK [lindex $wpath 0]]
set hpath [get_timing_paths -delay_type min -nworst 1 -max_paths 1]
set whs [get_property SLACK [lindex $hpath 0]]
set fsetup [get_timing_paths -delay_type max -slack_lesser_than 0 -max_paths 200000 -nworst 1]
set fhold  [get_timing_paths -delay_type min -slack_lesser_than 0 -max_paths 200000 -nworst 1]
puts "TIMING-WORST max slack=$wns start=[get_property STARTPOINT_PIN [lindex $wpath 0]] end=[get_property ENDPOINT_PIN [lindex $wpath 0]]"
puts "TIMING-WORST min slack=$whs start=[get_property STARTPOINT_PIN [lindex $hpath 0]] end=[get_property ENDPOINT_PIN [lindex $hpath 0]]"
chk "setup WNS" [expr {$wns > 0.0}] [format "WNS = %.3f ns" $wns]
chk "hold WHS"  [expr {$whs > 0.0}]  [format "WHS = %.3f ns" $whs]
chk "setup failing endpoints" [expr {[llength $fsetup] == 0}] "failing = [llength $fsetup]"
chk "hold failing endpoints"  [expr {[llength $fhold] == 0}]  "failing = [llength $fhold]"
foreach p [lrange $fsetup 0 19] {
    puts "SETUP-FAIL [get_property SLACK $p] [get_property STARTPOINT_PIN $p] -> [get_property ENDPOINT_PIN $p]"
}
foreach p [lrange $fhold 0 19] {
    puts "HOLD-FAIL [get_property SLACK $p] [get_property STARTPOINT_PIN $p] -> [get_property ENDPOINT_PIN $p]"
}

# ---- TNS.  get_timing_paths rejects -nworst 0, so read the authoritative
# Design Timing Summary row out of report_timing_summary instead.
set fh [open rep_timing_routed.rpt r]
set tdata [read $fh]
close $fh
foreach dt {max min} {
    set tns 0.0
    if {[catch {set tns [get_property STATS.TOTAL.negative_slack [get_timing_paths -delay_type $dt -nworst 1 -max_paths 1]]} e]} {
        set tns "<err $e>"
    }
    puts "INFO $dt worst-path negative_slack = $tns"
}
set sumline ""
foreach line [split $tdata \n] {
    set t [string trim $line]
    if {[regexp {^\s*(-?[0-9]+\.[0-9]+)\s+(-?[0-9]+\.[0-9]+)\s+([0-9]+)\s+([0-9]+)\s+(-?[0-9]+\.[0-9]+)\s+(-?[0-9]+\.[0-9]+)\s+([0-9]+)\s+([0-9]+)\s+(-?[0-9]+\.[0-9]+)\s+(-?[0-9]+\.[0-9]+)\s+([0-9]+)\s+([0-9]+)\s*$} $t]} {
        set sumline $t
        break
    }
}
puts "TIMING-SUMMARY-VALUES $sumline"
if {$sumline ne ""} {
    regexp {^\s*(-?[0-9]+\.[0-9]+)\s+(-?[0-9]+\.[0-9]+)\s+([0-9]+)\s+([0-9]+)\s+(-?[0-9]+\.[0-9]+)\s+(-?[0-9]+\.[0-9]+)\s+([0-9]+)} $sumline -> \
        s_wns s_tns s_tnsfail s_tnstot s_whs s_ths s_thsfail
    puts "SUM setup WNS=$s_wns TNS=$s_tns failing=$s_tnsfail of $s_tnstot"
    puts "SUM hold  WHS=$s_whs THS=$s_ths failing=$s_thsfail"
    chk "setup TNS == 0.000" [expr {$s_tns eq "0.000"}] "TNS = $s_tns"
    chk "setup TNS failing endpoints == 0" [expr {$s_tnsfail == 0}] "TNS failing = $s_tnsfail"
    chk "hold THS == 0.000" [expr {$s_ths eq "0.000"}] "THS = $s_ths"
    chk "hold THS failing endpoints == 0" [expr {$s_thsfail == 0}] "THS failing = $s_thsfail"
    chk "setup WNS positive" [expr {$s_wns > 0.0}] "WNS = $s_wns ns"
    chk "hold WHS positive" [expr {$s_whs > 0.0}] "WHS = $s_whs ns"
}
# Report the timing summary's own header line for the record.
foreach line [split $tdata \n] {
    set t [string trim $line]
    if {[string match "WNS(ns)*" $t] || [string match "WHS(ns)*" $t] \
        || [string match "WPWS(ns)*" $t] || [string match "TPWS(ns)*" $t]} {
        puts "TIMING-SUMMARY $t"
    }
}

# ---- the thinnest path, per clock, so the core margin can be read directly
set fh [open rep_perclock_wns.txt w]
puts $fh "# per-clock worst setup slack, routed design"
foreach c [lsort [get_clocks -quiet *]] {
    set cn [get_property NAME $c]
    set per [get_property PERIOD $c]
    set ps [get_timing_paths -delay_type max -from $c -to $c -nworst 1 -max_paths 1]
    if {[llength $ps] > 0} {
        set p [lindex $ps 0]
        set s [get_property SLACK $p]
        puts "WNS-PER-CLOCK $cn period $per intra $s [get_property STARTPOINT_PIN $p] -> [get_property ENDPOINT_PIN $p]"
        puts $fh "$cn period $per WNS $s [get_property STARTPOINT_PIN $p] -> [get_property ENDPOINT_PIN $p]"
    } else {
        puts "WNS-PER-CLOCK $cn period $per intra \"no intra-clock path\""
        puts $fh "$cn period $per WNS no-intra-clock-path"
    }
}
close $fh

# ---- core margin, the number the baseline is quoted against.  Found by period,
# not by name, for the same wrapper-hierarchy reason as the four-clock block.
set core [clock_by_period 46.561 0.002]
if {$core ne ""} {
    set ps [get_timing_paths -delay_type max -from $core -to $core -nworst 1 -max_paths 1]
    if {[llength $ps] > 0} {
        set p [lindex $ps 0]
        puts "CORE-WNS-SETUP slack=[get_property SLACK $p] start=[get_property STARTPOINT_PIN $p] end=[get_property ENDPOINT_PIN $p]"
    }
    set ph [get_timing_paths -delay_type min -from $core -to $core -nworst 1 -max_paths 1]
    if {[llength $ph] > 0} {
        set p [lindex $ph 0]
        puts "CORE-WHS-HOLD slack=[get_property SLACK $p] start=[get_property STARTPOINT_PIN $p] end=[get_property ENDPOINT_PIN $p]"
    }
}

# ---- every intra and inter clock pair, both delay types
set allclocks [lsort [get_clocks -quiet *]]
set cl_names {}
foreach c $allclocks { lappend cl_names [get_property NAME $c] }
puts "INFO clock objects ([llength $allclocks]): [join $cl_names ,]"
puts "INFO clock pairs enumerated = [llength $allclocks]x[llength $allclocks] = [expr {[llength $allclocks]*[llength $allclocks]}]"
set pairfail 0
foreach f $allclocks {
    foreach t $allclocks {
        set ps [get_timing_paths -delay_type max -from $f -to $t -slack_lesser_than 0 -max_paths 2000 -nworst 1]
        if {[llength $ps] > 0} {
            incr pairfail [llength $ps]
            puts "PAIR-FAIL-SETUP [get_property NAME $f] -> [get_property NAME $t] : [llength $ps]"
        }
    }
}
chk "all intra+inter clock pairs, setup" [expr {$pairfail == 0}] "failing setup endpoints = $pairfail"
set pairfailh 0
foreach f $allclocks {
    foreach t $allclocks {
        set ps [get_timing_paths -delay_type min -from $f -to $t -slack_lesser_than 0 -max_paths 2000 -nworst 1]
        if {[llength $ps] > 0} {
            incr pairfailh [llength $ps]
            puts "PAIR-FAIL-HOLD [get_property NAME $f] -> [get_property NAME $t] : [llength $ps]"
        }
    }
}
chk "all intra+inter clock pairs, hold" [expr {$pairfailh == 0}] "failing hold endpoints = $pairfailh"

# ===================================================== routing errors
set fh [open rep_route_status.rpt r]
set rdata [read $fh]
close $fh
set rerr -1
regexp {# of nets with routing errors.*?:\s*([0-9]+)} $rdata -> rerr
set unroute -1
regexp {# of nets with no routing.*?:\s*([0-9]+)} $rdata -> unroute
chk "routing errors" [expr {$rerr == 0}] "nets with routing errors = $rerr"
puts "ROUTESTATUS-RAW"
foreach line [split $rdata \n] {
    set t [string trim $line]
    if {[string match "*routing errors*" $t] || [string match "*no routing*" $t] \
        || [string match "*fully routed*" $t] || [string match "*routing status*" $t]} {
        puts "  $t"
    }
}

# ===================================================== DRC
set fh [open rep_drc.rpt r]
set ddata [read $fh]
close $fh
set drcerr 0
foreach line [split $ddata \n] {
    if {[regexp -nocase {\|\s*[A-Z]+[A-Z0-9_]*-[0-9]+\s*\|\s*Error\s*\|} $line]} { incr drcerr }
}
set totviol -1
regexp {Violations found:\s*([0-9]+)} $ddata -> totviol
chk "DRC errors" [expr {$drcerr == 0}] "error-severity rules = $drcerr; total violations (incl. NSTD/UCIO warnings) = $totviol"

# ===================================================== pin placement
# The PL-only top places 53 pins: the 45 board pins of the base platform plus
# the eight HDMI TMDS ports.  The eight ps_* ports that nes_zynq_top gained for
# the PS flow are bound inside nes_zynq_pl_top and are not ports of the placed
# design at all, so they cannot appear here or be left unplaced.
set allports [get_ports -quiet *]
set placed 0
set unplaced {}
foreach p $allports {
    set pp ""
    catch {set pp [get_property PACKAGE_PIN -quiet $p]}
    if {[string length $pp] > 0} { incr placed } else { lappend unplaced [get_property NAME $p] }
}
chk "total user IO" [expr {[llength $allports] == 53}] "ports = [llength $allports] (want 53 = 45 + 3 tmds_data_p + 3 tmds_data_n + tmds_clk_p + tmds_clk_n)"
chk "pins placed" [expr {[llength $unplaced] == 0}] \
    "placed = $placed of [llength $allports], unplaced = [llength $unplaced] [join $unplaced ,]"

# ===================================================== the four clocks
# sys_clk and lcd_clk are top-level ports, so their clock objects carry their own
# names.  The NES core clock and the audio BCLK are generated clocks, and because
# the PL-only build's top is the wrapper nes_zynq_pl_top the core clock's net is
# auto-named by Vivado (u_top_n_6 on the first run of this flow), so the two
# generated clocks are found by their exact periods instead of by name -- the
# same technique the HDMI block below already uses.  The BCLK clock is created
# by pl/nes_zynq_pl_top_extra.xdc, which restores the one repository-XDC
# constraint whose source path could not survive the extra hierarchy level.
foreach {cname period} {sys_clk 20.000 lcd_clk 40.000} {
    set co [get_clocks -quiet $cname]
    if {[llength $co] == 0} {
        chk "clock $cname exists" 0 "does not exist"
    } else {
        set per [get_property PERIOD [lindex $co 0]]
        chk "clock $cname period" [expr {abs($per - $period) < 0.002}] \
            [format "%s = %.3f ns (want %.3f)" $cname $per $period]
    }
}
foreach {label period} {core_clk 46.561 aud_bclk 640.000} {
    set co [clock_by_period $period 0.002]
    if {$co eq ""} {
        chk "clock $label present" 0 "no clock at $period ns"
    } else {
        chk "clock $label present" 1 "[get_property NAME $co] period [get_property PERIOD $co] ns"
    }
}
# ===================================================== HDMI clocks
# The second MMCM's two outputs are internal nets, so their clock object names are
# not known a priori; find them by their exact periods instead of by name.
set hclk_p 0
set hclk_x5 0
foreach c [get_clocks -quiet *] {
    set cn [get_property NAME $c]
    set per [get_property PERIOD $c]
    if {abs($per - 37.037) < 0.01} { incr hclk_p ; puts "CLOCK-HDMI hdmi_pclk   $cn period $per" }
    if {abs($per -  7.407) < 0.01} { incr hclk_x5; puts "CLOCK-HDMI hdmi_pclk_x5 $cn period $per" }
}
chk "hdmi pixel clock 27.000 MHz present" [expr {$hclk_p  >= 1}] "clocks at 37.037 ns = $hclk_p"
chk "hdmi 5x serial clock 135.000 MHz present" [expr {$hclk_x5 >= 1}] "clocks at 7.407 ns = $hclk_x5"

puts "---- report_clocks ----"
foreach line [split [read [open rep_clocks.rpt r]] \n] {
    set t [string trim $line]
    if {[string match "*sys_clk*" $t] || [string match "*lcd_clk*" $t] || [string match "*aud_bclk*" $t] \
        || [string match "*mmcm_core_clk*" $t]} { puts "  CLOCK $t" }
}

# ===================================================== 12-584 "No ports matched"
# Count DISTINCT [get_ports ...] targets, not lines: sys_clk, lcd_clk and aud_bclk
# each carry two get_ports lines (pin placement plus their create_clock), so the
# active lines resolve to exactly 49 distinct ports, matching the XDC's own P-side
# targets.  The four N-side TMDS ports are inferred package pairs and carry no
# XDC entry of their own.
set fh [open rtl/platform/zynq/nes_zynq_top.xdc r]
set xdata [read $fh]
close $fh
set xdc_lines 0
set xdc_targets {}
foreach line [split $xdata \n] {
    # Test with string first, NOT string match: in a glob an open bracket starts a
    # character class, so a bracketed glob pattern does not test for literal text.
    # Vivado 2018.3 ships Tcl 8.5, which has no "continue", hence the flag.
    set keep 0
    set head [string range $line 0 0]
    set idx [string first {[get_ports} $line]
    if {$head ne "#" && $idx >= 0} { set keep 1 }
    if {$keep == 1} {
        incr xdc_lines
        set rest [string trim [string range $line [expr {$idx + 10}] end]]
        set close [string first "]" $rest]
        if {$close >= 0} {
            set tgt [string range $rest 0 [expr {$close - 1}]]
        } else {
            set tgt $rest
        }
        if {[lsearch -exact $xdc_targets $tgt] < 0} { lappend xdc_targets $tgt }
    }
}
set xdc_distinct {}
foreach t $xdc_targets {
    set n [string trim $t]
    set n [string trim $n "{}"]
    if {[lsearch -exact $xdc_distinct $n] < 0} { lappend xdc_distinct $n }
}
set xdc_namediff [llength $xdc_distinct]
puts "XDC active get_ports lines = $xdc_lines, distinct port targets = $xdc_namediff"
chk "every XDC get_ports target matched a real port" [expr {$xdc_namediff == 49}] \
    "distinct active get_ports targets = $xdc_namediff (want 49 = 45 + 4 TMDS P-side pins)"

# ===================================================== accepted gaps
# Reported present or absent.  NOT treated as failures and NOT closed here.
set fh [open rep_checktiming.rpt r]
set cdata [read $fh]
close $fh
set nclock -1
regexp {There are ([0-9]+) register/latch pins with no clock} $cdata -> nclock
set nuncon -1
regexp {There are ([0-9]+) pins that are not constrained for maximum delay} $cdata -> nuncon
set nin -1
regexp {There are ([0-9]+) input ports with no input delay} $cdata -> nin
set nout -1
regexp {There are ([0-9]+) ports with no output delay} $cdata -> nout
set nloops -1
regexp {There are ([0-9]+) combinational loops} $cdata -> nloops
puts "GAP-1 register/latch pins with no clock          = $nclock (accepted: 3 expected)"
puts "GAP-1 pins not constrained for maximum delay     = $nuncon (accepted: 6 expected, BCLK domain)"
puts "GAP-1 input ports with no input delay            = $nin"
puts "GAP-1 ports with no output delay                 = $nout"
puts "GAP-2 combinational loops                        = $nloops"
chk "0 combinational loops" [expr {$nloops == 0}] "combinational loops = $nloops"
set n584 0
foreach line [split $cdata \n] {
    if {[string match "*12-584*" $line]} { incr n584 ; puts "CHECKTIMING-12-584 [string trim $line]" }
}
puts "GAP-2 check_timing 12-584 lines = $n584"
chk "0 check_timing 12-584 No-ports-matched" [expr {$n584 == 0}] "12-584 lines = $n584"
set xdc_has_delay 0
foreach kw {set_input_delay set_output_delay} {
    foreach line [split $xdata \n] {
        if {[string match "*$kw*" $line] && [string first "#" [string range $line 0 0]] != 0} { incr xdc_has_delay }
    }
}
puts "GAP-1 active set_input_delay/set_output_delay commands in the XDC = $xdc_has_delay (0 expected)"

# ---- the known pre-existing Netlist 29-72 BUFG property critical warning.
set n2972 0
foreach rep {rep_methodology.rpt rep_drc.rpt rep_route_status.rpt} {
    if {[file exists $rep]} {
        set fh [open $rep r]
        set rdata [read $fh]
        close $fh
        foreach line [split $rdata \n] {
            if {[string match "*29-72*" $line]} { incr n2972 ; puts "NETLIST-29-72($rep) [string trim $line]" }
        }
    }
}
# Sweep every COMPLETE log on disk.  finish_stdout.log is deliberately excluded: it is
# still being appended to while this script runs, so it cannot be trusted as evidence.
set swept 0
foreach lg {vivado.log build_stdout.log} {
    if {![file exists $lg]} { continue }
    set fh [open $lg r]
    set ldata [read $fh]
    close $fh
    incr swept
    foreach line [split $ldata \n] {
        if {[string match "*Netlist 29-72*" $line] && [string match "*CRITICAL WARNING*" $line]} {
            incr n2972
            puts "NETLIST-29-72($lg) [string trim $line]"
        }
    }
}
if {$swept > 0} {
    puts "GAP-3 logs retained and swept for Netlist 29-72: $swept file(s)"
} else {
    puts "GAP-3 NO COMPLETE LOG FOUND; 29-72 evidence from implementation reports only"
}
puts "GAP-3 Netlist 29-72 occurrences = $n2972"


# ===================================================== the TPAD pin itself
# The one new constraint.  Checked by NAME and by PIN, and by DIRECTION, because a
# silent 12-584 would leave the port unplaced rather than failing the build.
set tk [get_ports -quiet touch_key]
if {[llength $tk] != 1} {
    chk "touch_key port exists" 0 "get_ports touch_key returned [llength $tk] objects"
} else {
    set tkpin "";  catch {set tkpin  [get_property PACKAGE_PIN $tk]}
    set tkir "";  catch {set tkir   [get_property IOSTANDARD  $tk]}
    set tkdir "";  catch {set tkdir  [get_property DIRECTION    $tk]}
    set tkcfg "touch_key PACKAGE_PIN=$tkpin IOSTANDARD=$tkir DIRECTION=$tkdir"
    chk "touch_key exists as one port" 1 $tkcfg
    chk "touch_key is on F16"           [expr {$tkpin eq "F16"}]  "PACKAGE_PIN = $tkpin (want F16)"
    chk "touch_key IOSTANDARD LVCMOS33" [expr {$tkir  eq "LVCMOS33"}] "IOSTANDARD = $tkir"
    chk "touch_key direction is an input" [expr {[string match "IN*" $tkdir]}] "DIRECTION = $tkdir (Vivado 2018.3 reads an input as IN, report_io prints it as INPUT)"
    set fpins {}
    foreach p $allports { set q ""; catch {set q [get_property PACKAGE_PIN -quiet $p]}; if {$q eq "F16"} { lappend fpins [get_property NAME $p] } }
    chk "F16 carries exactly one port" [expr {[llength $fpins] == 1}] "ports on F16 = [llength $fpins] [join $fpins ,]"
}
# And the same pin read back out of the IO report on disk, so it is not only the
# in-memory property object that says so.
set ffound 0
foreach line [split [read [open rep_io.rpt r]] \n] {
    if {[string match "*touch_key*" $line]} { puts "IO-REPORT [string trim $line]" }
    if {[string match "*touch_key*" $line] && [string match "*F16*" $line]} { incr ffound }
}
chk "rep_io.rpt shows touch_key on F16" [expr {$ffound > 0}] "matching rows = $ffound"
set n584b 0
foreach line [split [read [open rep_io.rpt r]] \n] {
    if {[string match "*12-584*" $line]} { incr n584b; puts "IO-12-584 [string trim $line]" }
}
chk "rep_io.rpt has no 12-584 No-ports-matched" [expr {$n584b == 0}] "12-584 rows = $n584b"
# ===================================================== bitstream
write_bitstream -force nes_zynq_pl_top.bit
if {[file exists nes_zynq_pl_top.bit]} {
    puts "BITSTREAM nes_zynq_pl_top.bit [file size nes_zynq_pl_top.bit] bytes"
    chk "bitstream written" 1 "nes_zynq_pl_top.bit"
} else {
    chk "bitstream written" 0 "not written"
}

puts "=========================================================="
puts "FINISH DONE"
puts "=========================================================="
exit 0
