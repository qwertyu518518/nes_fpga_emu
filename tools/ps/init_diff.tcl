# =============================================================================
# init_diff.tcl -- INIT differential to prove the cartridge BRAM content.
#
# Tile count cannot distinguish "the committed placeholder is in the BRAM" from
# a different image, so this dumps every RAMB cell's INIT_00..INIT_3F and
# INITP_00..INITP_3F from two syntheses of the identical tree that differ ONLY
# in the bytes of the two $readmemh files, exactly as the PL-only flow's
# build.tcl / ph_build.tcl pair does.  The differential is then computed by
# tools/ps/init_diff.ps1.
#
#   A  out/ps_bram_init.txt     the committed build, from out/ps_synth.dcp
#   B  out/ps_bram_init_ph.txt  a control re-synthesis with the hex bytes flipped
#
# Run through tools/ps/run_init_diff.ps1 after a full build_ps.tcl run.
# =============================================================================

set root [file normalize [pwd]]
set repo [file normalize [file join $root .. ..]]
set outd [file join $root out]

proc dump_ramb {path} {
    set fh [open $path w]
    puts $fh "# cell REF_NAME DATA_WIDTH INIT_00..INIT_3F INITP_00..INITP_3F"
    puts $fh "# fields are LABELLED on purpose so an empty readback is not confused"
    puts $fh "# with a missing field or a zero."
    set allbram [get_cells -quiet -hierarchical -filter {REF_NAME =~ RAMB*}]
    puts "INIT_DIFF dump [llength $allbram] RAMB cells -> $path"
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
}

# ---- A. the committed build's inferred BRAM content -------------------------
open_checkpoint [file join $outd ps_synth.dcp]
dump_ramb [file join $outd ps_bram_init.txt]
close_design

# ---- B. control: identical tree, flipped hex at the same $readmemh path ------
set cart [file join $repo rtl nes_core cart]
set mod  [file join $outd modhex]
file mkdir $mod

foreach {src dst} [list [file join $cart prg_placeholder.hex] [file join $mod prg_mod.hex] \
                        [file join $cart chr_placeholder.hex] [file join $mod chr_mod.hex]] {
    set fh [open $src r]; set d [read $fh]; close $fh
    scan [string range $d 0 1] %x b0
    set nb [format "%02x" [expr {$b0 ^ 0xFF}]]
    set d2 [string replace $d 0 1 $nb]
    set fh [open $dst w]; puts -nonewline $fh $d2; close $fh
    puts "INIT_DIFF control $dst first byte $nb (was [format %02x $b0])"
}

set pre2 [file join $outd pre_synth_ctl.tcl]
set mprg [string map [list \\ /] [file join $mod prg_mod.hex]]
set mchr [string map [list \\ /] [file join $mod chr_mod.hex]]
set fh [open $pre2 w]
puts $fh "file mkdir rtl/nes_core/cart"
puts $fh "file copy -force \"$mprg\" rtl/nes_core/cart/prg_placeholder.hex"
puts $fh "file copy -force \"$mchr\" rtl/nes_core/cart/chr_placeholder.hex"
puts $fh "puts \"PRE_SYNTH_CTL cwd=\[pwd\]\""
close $fh

open_project [file join $root proj ps_nes.xpr]
# Point the module-reference parameters at the modified hex too, so the control
# differs regardless of which of the two mechanisms carried the image.
if {[catch {
    open_bd_design [get_files system.bd]
    set_property -dict [list CONFIG.PRG_INIT_FILE $mprg CONFIG.CHR_INIT_FILE $mchr] [get_bd_cells nes_zynq_top_0]
    save_bd_design
    close_bd_design
    puts "INIT_DIFF bd module params set to modified hex"
} e]} {
    puts "INIT_DIFF bd param set skipped: $e"
}
set r [get_runs synth_1]
set_property STEPS.SYNTH_DESIGN.TCL.PRE $pre2 $r
reset_run synth_1
launch_runs synth_1 -jobs 8
wait_on_run synth_1
set st [get_property STATUS $r]
puts "INIT_DIFF control synth status $st"
open_run synth_1
dump_ramb [file join $outd ps_bram_init_ph.txt]
puts "INIT_DIFF_DONE"
exit 0
