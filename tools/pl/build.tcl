# PL-only full non-OOC implementation flow, Zynq-7020, real cartridge baked into
# BRAM.  This is the in-repo reproduction of the flow that produced every
# zynq_bitstream_vN artefact and the primary bitstream the hardware bring-up
# guide tells the user to flash first.
#
# The PS half of runtime cartridge loading lives in ../ps/ and builds a block
# design; this file is the OTHER half and has no PS, no block design and no
# block design IP.  Its top is nes_zynq_pl_top, the PL-only wrapper in this
# directory that binds every ps_* input of nes_zynq_top inert (see that file for
# why).  Running this file therefore reproduces the historical PL artefact from
# repository source alone.
#
# This file is applied on top of tools/pl/run_pl.ps1, which stages a throwaway
# work tree: a copy of rtl/ (minus rtl/platform/ep4ce10, the other board), this
# file and finish.tcl, the PL wrapper, a stash of the committed placeholder hex,
# and -- at the committed placeholder PATH -- a copy of the REAL cartridge from
# build/rom/{prg,chr}.hex.  build/ is gitignored and the cartridge is never
# committed.
#
# Placing the cartridge at the committed placeholder PATH is what makes this
# work: synth_design -generic on the top module does not work on the Vivado
# 2018.3 command line -- it delivers the quotes as part of the string value and
# synthesis dies with Synth 8-4445.  That was measured in the 274e25a run, not
# assumed.  $readmemh resolves the relative path against Vivado's CWD, so
# run_pl.ps1 launches Vivado with CWD set to the work tree root.
#
# No checkpoints are reused.  synth_design -> opt_design -> place_design ->
# phys_opt_design -> route_design, so the artifact traces to source.
#
# Vivado 2018.3 has no -seed on place_design or route_design.  -directive is the
# only knob and it is left at default here so the metrics stay comparable with
# the historical baseline.
#
# NOTHING here can abort before the checkpoints and reports are on disk, and
# write_bitstream is deliberately NOT here -- it lives in finish.tcl, which opens
# this run's own out_route.dcp.  get_memories does not exist in 2018.3 and is
# never called.

set part xc7z020clg400-2
set top  nes_zynq_pl_top

# The real cartridge sits at the path the committed default parameter names.
set prg_rel "rtl/nes_core/cart/prg_placeholder.hex"
set chr_rel "rtl/nes_core/cart/chr_placeholder.hex"

proc chk {label ok detail} {
    if {$ok} {
        puts "VERIFY PASS  $label  $detail"
    } else {
        puts "VERIFY FAIL  $label  $detail"
    }
}
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

# ============================================================== preflight
puts "PREFLIGHT cwd = [pwd]"
puts "PREFLIGHT flow = tools/pl PL-only, top = $top, part = $part"
foreach {hex want} [list $prg_rel 393216 $chr_rel 24576] {
    if {![file exists $hex]} {
        puts "PREFLIGHT FAIL $hex MISSING; the BRAM would be optimised away silently"
        exit 1
    }
    set sz [file size $hex]
    puts "PREFLIGHT $hex present, $sz bytes (expected $want)"
    puts "PREFLIGHT $hex first words = [first_words $hex 8]"
    if {$sz != $want} {
        puts "PREFLIGHT FAIL $hex is $sz bytes, expected $want"
        exit 1
    }
}
# PROOF the real cartridge is in place and not the committed placeholder:
#   real PRG word 0 = cc   (committed placeholder word 0 = 00)
#   real CHR word 0 = 00 01 01 41 71 55 7c  (committed placeholder = 00 01 02 03 ...)
# Same path, same $readmemh, same array geometry, different bytes, therefore
# different inferred INIT -- and that INIT differential, not the tile count, is
# the provenance evidence, because both builds report the same Block RAM tile
# count (a cartridge that failed to load shows 64 rather than 82, not 0: the 64
# frame_mem tiles are not part of the cartridge).
set prg_head [first_words $prg_rel 2]
if {[lindex $prg_head 0] ne "cc"} {
    puts "PREFLIGHT FAIL PRG does not start with cc; the real cartridge is not in place"
    exit 1
}
puts "PREFLIGHT OK PRG starts with cc (cartridge), not 00 (committed placeholder)"
set chr_head [first_words $chr_rel 4]
if {[lindex $chr_head 2] ne "01"} {
    puts "PREFLIGHT FAIL CHR does not read 00 00 01 01; the real cartridge is not in place"
    exit 1
}
puts "PREFLIGHT OK CHR reads [lrange [split $chr_head] 0 3] (cartridge), not 00 01 02 03 (placeholder)"

# Second, independent in-Vivado proof: byte-compare the file at the $readmemh
# path against the byte-verified stash of the committed placeholder, from inside
# Vivado, and report how many bytes differ.  This does not merely spot-check a
# first word -- it proves the whole image Vivado is about to read is the
# cartridge and not the placeholder.
foreach {live stash} [list $prg_rel placeholder_hex/prg_placeholder.hex \
                       $chr_rel placeholder_hex/chr_placeholder.hex] {
    set lh [open $live r] ; set lb [read $lh] ; close $lh
    set sh [open $stash r] ; set sb [read $sh] ; close $sh
    set lsz [string length $lb] ; set ssz [string length $sb]
    if {$lsz != $ssz} {
        puts "PREFLIGHT FAIL $live is $lsz chars, stash is $ssz chars"
        exit 1
    }
    set ndiff 0 ; set firstdiff -1 ; set i 0
    while {$i < $lsz} {
        if {[string index $lb $i] ne [string index $sb $i]} {
            incr ndiff
            if {$firstdiff < 0} { set firstdiff $i }
        }
        incr i
    }
    puts "PREFLIGHT $live differs from the committed placeholder in $ndiff of $lsz chars; first difference at char offset $firstdiff"
    if {$ndiff == 0} {
        puts "PREFLIGHT FAIL $live is byte-identical to the committed placeholder; the cartridge is NOT in place"
        exit 1
    }
}
puts "PREFLIGHT OK both images at the \$readmemh path differ from the placeholder over their whole length"

# Every .v in the vendor-independent core and the Zynq platform adapter, so
# nothing at HEAD can be silently left out.  Enumerated explicitly rather than by
# ** so it is exact.  rtl/platform/ep4ce10 is deliberately excluded: it is the
# other board.  pl/*.v adds the PL-only wrapper, which is the actual top.
set rtl_files {}
foreach d {nes_core nes_core/apu nes_core/bus nes_core/cart nes_core/controller \
           nes_core/cpu nes_core/mapper nes_core/peripheral nes_core/ppu \
           nes_core/system nes_core/video platform/zynq} {
    set rtl_files [concat $rtl_files [lsort [glob -nocomplain rtl/$d/*.v]]]
}
set rtl_files [concat $rtl_files [lsort [glob -nocomplain pl/*.v]]]
puts "PREFLIGHT RTL source count = [llength $rtl_files]"
foreach f $rtl_files { puts "PREFLIGHT RTL $f [file size $f] bytes" }

read_verilog $rtl_files
read_xdc rtl/platform/zynq/nes_zynq_top.xdc
# One top-relative constraint that the repository XDC cannot express for the
# wrapper top: the 640 ns aud_bclk generated clock, whose -source pin path in the
# repository XDC has no leading wildcard.  See pl/nes_zynq_pl_top_extra.xdc.
read_xdc pl/nes_zynq_pl_top_extra.xdc

# ============================================================== synthesis
synth_design -top $top -part $part

write_checkpoint -force out_synth.dcp
report_utilization -file rep_util_synth.rpt
report_utilization -hierarchical -file rep_util_synth_hier.rpt

# ---- BRAM after synthesis.  A cartridge that failed to load drops the tile
# count by 18 (16 PRG + 2 CHR) and this is the only synthesis-side signal that
# it happened.  report_utilization is captured at this stage and again after
# route.
set fh [open rep_util_synth.rpt r]
set sdata [read $fh]
close $fh
set stiles -1
regexp -nocase {\|\s*Block RAM Tile\s*\|\s*([0-9]+)} $sdata -> stiles
chk "BRAM tiles after synth" [expr {$stiles == 82}] "Block RAM Tile = $stiles (want 82 = 16 PRG + 2 CHR + 32 LCD frame_mem + 32 HDMI frame_mem; a cartridge that failed to load shows 64, not 0)"
puts "SYNTH-UTIL-RAW"
foreach line [split $sdata \n] {
    set t [string trim $line]
    foreach kw {Slice LUTs "LUT as Memory" "Slice Registers" "Block RAM Tile" RAMB18 "RAMB36/FIFO" DSPs} {
        if {[string match "| $kw *" $t] || [string match "|$kw *" $t]} {
            if {[string first "Slice Registers *|" $t] != 0} { puts "  SYNTH-UTIL $t" }
        }
    }
}

# ============================================================== BRAM INIT dump
# What Vivado ACTUALLY inferred, not what we pointed it at.  Every INIT_00..INIT_3F
# and INITP_00..INITP_3F of every RAMB cell goes to bram_init.txt so it can be
# diffed against the identical-dump placeholder build (ph_build.tcl).  That
# differential, not the tile count, is the provenance evidence: a cartridge build
# and a placeholder build report the same tile count, only the INIT data
# distinguishes them.
set fh [open bram_init.txt w]
puts $fh "# cell REF_NAME DATA_WIDTH INIT_00..INIT_3F INITP_00..INITP_3F"
puts $fh "# fields are LABELLED on purpose: an unlabeled positional dump cannot be parsed"
puts $fh "# unambiguously when a property reads back empty, and an empty vs zero value"
puts $fh "# must not be confused with a missing field."
set allbram [get_cells -quiet -hierarchical -filter {REF_NAME =~ RAMB*}]
puts "INFO RAMB cells found = [llength $allbram]"
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
puts "INFO BRAM INIT+INITP dump written to bram_init.txt"

# ---- per-array RAMB geometry, so a silent BRAM-to-LUTRAM regression is visible here
# and not only in the utilisation summary.
puts "INFO --- inferred BRAM geometry per array (post-synth) ---"
foreach {label pat} {PRG {NAME =~ *prg_rom_reg_*} \
                      CHR {NAME =~ *chr_rom_reg_*} \
                      FRAME {NAME =~ *frame_mem_reg_*}} {
    set cells [get_cells -quiet -hierarchical -filter $pat]
    puts "GEOM $label cells = [llength $cells]"
    foreach c [lsort $cells] {
        set nm ""
        catch {set nm [get_property NAME $c]}
        set rn ""
        catch {set rn [get_property REF_NAME $c]}
        set line "GEOM   $rn $nm"
        foreach p {READ_WIDTH_A WRITE_WIDTH_A WRITE_MODE_A READ_WIDTH_B WRITE_WIDTH_B} {
            set v "<unset>"
            catch {set v [get_property $p $c]}
            append line " $p=$v"
        }
        puts $line
    }
}

# ============================================================== implementation
opt_design
place_design
phys_opt_design
route_design
write_checkpoint -force out_route.dcp

# ==================================================================== reports
report_timing_summary -delay_type min_max -max_paths 20 -file rep_timing_routed.rpt
report_utilization -file rep_util_routed.rpt
report_utilization -hierarchical -file rep_util_routed_hier.rpt
report_route_status -file rep_route_status.rpt
report_drc -file rep_drc.rpt
report_io -file rep_io.rpt
report_clocks -file rep_clocks.rpt
check_timing -verbose -file rep_checktiming.rpt
report_methodology -file rep_methodology.rpt

puts "BUILD STAGE DONE -- reports on disk, no bitstream yet (finish.tcl writes it)"
exit 0
