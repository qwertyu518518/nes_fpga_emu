# PLACEHOLDER-CONTROL SYNTHESIS.  Same tree, same read_verilog list, same XDC,
# same top (nes_zynq_pl_top), same part, same $readmemh PATH as build.tcl -- the
# ONLY difference is the CONTENT of the two hex files at
# rtl/nes_core/cart/*_placeholder.hex, which for this run is the committed
# placeholder (00 01 02 03 ... / cc cc ...) rather than the real cartridge.
#
# Why this exists: the cartridge build and the placeholder build report the SAME
# Block RAM tile count.  Tile count therefore cannot tell them apart.  The
# inferred RAMB INIT_00..INIT_3F and INITP_00..INITP_3F can, and this run produces
# the other half of that comparison (build.tcl writes bram_init.txt).
#
# Synthesis only.  No opt/place/phys_opt/route: the differential is entirely a
# synthesis artefact (BRAM inference + INIT), so implementation would add minutes
# and change nothing in the numbers being compared.  Output names are ph_* so
# nothing belonging to the real-cartridge run can be overwritten.

set part xc7z020clg400-2
set top  nes_zynq_pl_top

set prg_rel "rtl/nes_core/cart/prg_placeholder.hex"
set chr_rel "rtl/nes_core/cart/chr_placeholder.hex"

proc first_words {path n} {
    if {![file exists $path]} { return "<missing>" }
    set fh [open $path r]
    set data [read $fh]
    close $fh
    set out {}
    foreach t [split $data " \t\n\r"] {
        if {$t ne ""} {
            lappend out $t
            if {[llength $out] >= $n} { break }
        }
    }
    return [join $out " "]
}

puts "PH PREFLIGHT cwd = [pwd]"
puts "PH PREFLIGHT purpose = PLACEHOLDER CONTROL BUILD, PL-only top $top"
foreach {hex want} [list $prg_rel 393216 $chr_rel 24576] {
    if {![file exists $hex]} {
        puts "PH PREFLIGHT FAIL $hex MISSING"
        exit 1
    }
    set sz [file size $hex]
    puts "PH PREFLIGHT $hex present, $sz bytes (expected $want)"
    puts "PH PREFLIGHT $hex first words = [first_words $hex 8]"
    if {$sz != $want} {
        puts "PH PREFLIGHT FAIL $hex is $sz bytes, expected $want"
        exit 1
    }
}
# The committed placeholder's PRG word 0 is 00.  The real cartridge's is cc.  Assert
# the placeholder is genuinely in place, otherwise this control build proves nothing.
set prg_head [first_words $prg_rel 2]
if {[lindex $prg_head 0] ne "00"} {
    puts "PH PREFLIGHT FAIL PRG does not start with 00; the committed placeholder is not in place"
    exit 1
}
puts "PH PREFLIGHT OK PRG starts with 00 (committed placeholder), not cc (cartridge)"
# And the whole image must be the placeholder, not just its first word.
foreach {live stash} [list $prg_rel placeholder_hex/prg_placeholder.hex \
                       $chr_rel placeholder_hex/chr_placeholder.hex] {
    set lh [open $live r] ; set lb [read $lh] ; close $lh
    set sh [open $stash r] ; set sb [read $sh] ; close $sh
    if {$lb ne $sb} {
        puts "PH PREFLIGHT FAIL $live is NOT byte-identical to the committed placeholder stash"
        exit 1
    }
    puts "PH PREFLIGHT OK $live is byte-identical to the committed placeholder ([string length $lb] chars)"
}

set rtl_files {}
foreach d {nes_core nes_core/apu nes_core/bus nes_core/cart nes_core/controller \
           nes_core/cpu nes_core/mapper nes_core/peripheral nes_core/ppu \
           nes_core/system nes_core/video platform/zynq} {
    set rtl_files [concat $rtl_files [lsort [glob -nocomplain rtl/$d/*.v]]]
}
set rtl_files [concat $rtl_files [lsort [glob -nocomplain pl/*.v]]]
puts "PH PREFLIGHT RTL source count = [llength $rtl_files] (must equal the cartridge run)"

read_verilog $rtl_files
read_xdc rtl/platform/zynq/nes_zynq_top.xdc
read_xdc pl/nes_zynq_pl_top_extra.xdc

synth_design -top $top -part $part

write_checkpoint -force ph_synth.dcp
report_utilization -file ph_util_synth.rpt

set fh [open ph_util_synth.rpt r]
set sdata [read $fh]
close $fh
set stiles -1
regexp -nocase {\|\s*Block RAM Tile\s*\|\s*([0-9]+)} $sdata -> stiles
puts "PH RESULT Block RAM Tile = $stiles  (the real-cartridge PL run also reports 82)"
puts "PH RESULT this is the point: tile count is IDENTICAL for both builds, so it"
puts "PH RESULT cannot distinguish them.  Only the INIT differential can."

# Identical dump format to bram_init.txt, just a different output file.
set fh [open bram_init_ph.txt w]
puts $fh "# cell REF_NAME DATA_WIDTH INIT_00..INIT_3F INITP_00..INITP_3F"
puts $fh "# fields are LABELLED on purpose: an unlabeled positional dump cannot be parsed"
puts $fh "# unambiguously when a property reads back empty, and an empty vs zero value"
puts $fh "# must not be confused with a missing field."
set allbram [get_cells -quiet -hierarchical -filter {REF_NAME =~ RAMB*}]
puts "PH INFO RAMB cells found = [llength $allbram]"
foreach c $allbram {
    set rn [get_property REF_NAME $c]
    set dw [get_property DATA_WIDTH $c]
    set nm [get_property NAME $c]
    puts -nonewline $fh "$nm $rn DATA_WIDTH=$dw"
    for {set k 0} {$k < 64} {incr k} {
        set pn [format "INIT_%02X" $k]
        set v "<absent>"
        catch {set v [get_property $pn $c]}
        if {$v eq ""} { set v "<empty>" }
        puts -nonewline $fh " $pn=$v"
    }
    for {set k 0} {$k < 64} {incr k} {
        set pn [format "INITP_%02X" $k]
        set v "<absent>"
        catch {set v [get_property $pn $c]}
        if {$v eq ""} { set v "<empty>" }
        puts -nonewline $fh " $pn=$v"
    }
    puts $fh ""
}
close $fh
puts "PH INFO BRAM INIT+INITP dump written to bram_init_ph.txt"

puts "PH BUILD DONE"
exit 0
