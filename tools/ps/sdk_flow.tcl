# =============================================================================
# sdk_flow.tcl -- Xilinx SDK 2018.3 command-line flow (run under xsct.bat).
#
# Consumes tools/ps/out/ps_nes.hdf (written by build_ps.tcl after the routed
# design) and produces:
#   * a hardware platform project,
#   * the FSBL, built from the {Zynq FSBL} template,
#   * the bare-metal loader application, from tools/ps/app/main.c, with the
#     xilffs library on its BSP so FatFs and the SD driver are available.
#
# The BOOT.bin is assembled afterwards by bootgen from boot.bif (see
# tools/ps/run_sdk.ps1), with the FSBL, the application AND the PL bitstream.
#
# SDK's Eclipse GUI is incomplete in this install; this is the command line.
# =============================================================================

set root [file normalize [pwd]]
set hdf  [file join $root out ps_nes.hdf]
set ws   [file join $root sdk_ws]

puts "SDK_START root=$root"
puts "SDK_HDF $hdf exists=[file exists $hdf]"
if {![file exists $hdf]} { puts "SDK_FAIL missing hdf"; exit 1 }

file delete -force $ws
file mkdir $ws

sdk setws $ws
sdk createhw -name ps_nes_hw -hwspec $hdf
puts "SDK_HW done"

# ---- FSBL: createapp with the {Zynq FSBL} template auto-creates its BSP and
# ---- carries the libraries the FSBL needs (xilffs among them).
sdk createapp -name fsbl -hwproject ps_nes_hw -proc ps7_cortexa9_0 \
              -os standalone -lang C -app {Zynq FSBL}
puts "SDK_FSBL done"

# ---- bare-metal loader application.
# Create the BSP explicitly first, add xilffs (FatFs + SD/xsdps glue), then
# attach the application to it with -bsp so its link line carries -lxilffs.
sdk createbsp -name loader_app_bsp -hwproject ps_nes_hw -proc ps7_cortexa9_0 -os standalone
puts "SDK_BSP done"

# setlib is a top-level xsct command (not under "sdk") and requires an open BSP.
if {[catch {openbsp loader_app_bsp} e]} {
    puts "SDK_OPENBSP_ERR $e"
}
if {[catch {setlib -bsp loader_app_bsp -lib xilffs} e2]} {
    puts "SDK_SETLIB_ERR $e2"
} else {
    puts "SDK_SETLIB xilffs added to loader_app_bsp"
}
if {[catch {regenbsp -bsp loader_app_bsp} rerr]} {
    puts "SDK_REGENBSP_ERR $rerr"
} else {
    puts "SDK_REGENBSP ok"
}

sdk createapp -name loader_app -hwproject ps_nes_hw -proc ps7_cortexa9_0 \
              -os standalone -lang C -app {Empty Application} -bsp loader_app_bsp
puts "SDK_APP done"

puts "SDK_TREE_APP: [lsort [glob -nocomplain -tails -directory $ws/loader_app *]]"
foreach f [glob -nocomplain $ws/loader_app/src/*] { puts "SDK_APP_SRC_FILE $f" }

# Drop our own main.c in before the build so the template's main is replaced.
if {[file exists [file join $ws loader_app src]]} {
    file copy -force [file join $root app main.c] [file join $ws loader_app src main.c]
    puts "SDK_MAIN copied"
}

sdk projects -build
puts "SDK_BUILD_DONE"

foreach p [list [file join $ws fsbl Debug fsbl.elf] \
                [file join $ws loader_app Debug loader_app.elf]] {
    set sz 0
    if {[file exists $p]} { set sz [file size $p] }
    puts "SDK_ELF $p exists=[file exists $p] size=$sz"
}
exit
