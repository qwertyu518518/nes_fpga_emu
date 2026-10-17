# =============================================================================
# nes_zynq_pl_top_extra.xdc : top-relative constraint for the PL-only wrapper
# -----------------------------------------------------------------------------
# tools/pl/build.tcl reads rtl/platform/zynq/nes_zynq_top.xdc -- the platform
# adapter's own constraints, written for the hierarchy where nes_zynq_top IS the
# top.  The PL-only build puts nes_zynq_pl_top above it (to bind the eight ps_*
# inputs inert), which adds one hierarchy level.  Every constraint in the
# repository XDC that identifies a cell with a LEADING WILDCARD still resolves
# one level down, but exactly ONE does not:
#
#   create_generated_clock -name aud_bclk \
#       -source [get_pins u_audio_i2s/bclk_int_reg/C] ...
#
# has no leading wildcard, so under the wrapper it matches nothing and Vivado
# reports
#   WARNING: [Vivado 12-508] No pins matched 'u_audio_i2s/bclk_int_reg/C'
#   CRITICAL WARNING: [Vivado 12-4739] create_generated_clock:No valid object(s)
# and the 640 ns BCLK domain is silently lost.  That is exactly the silent-drop
# failure class the repository XDC warns about, so it is closed here rather than
# left standing.  This file re-creates that ONE clock, with the same divide-by-16
# and the same destination port, but with a hierarchy-robust source pattern.
#
# WHY THIS IS A BUILD FILE AND NOT AN RTL CHANGE: the constraint still belongs to
# nes_zynq_top and is unchanged in rtl/platform/zynq/nes_zynq_top.xdc.  Only its
# top-relative path is supplied by the build that chooses the top.  Nothing else
# in the repository XDC needs this: the touch-button, audio-FIFO, codec-config
# and HDMI set_max_delay blocks all use a leading wildcard and survive the extra
# hierarchy level.
#
# XDC files may contain constraints only, never Tcl control flow: a guarded or
# logged constraint is silently dropped (see docs/00-overview/vivado-runbook.md,
# section 4).
# =============================================================================
create_generated_clock -name aud_bclk \
    -source [get_pins -quiet -hierarchical -filter {NAME =~ *u_audio_i2s/bclk_int_reg/C}] \
    -divide_by 16 \
    [get_ports aud_bclk]
