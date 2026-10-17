# tools/pl -- the PL-only Zynq-7020 bitstream flow

This directory reproduces the **primary bitstream** this project ships: the
PL-only build that put the NES core and its platform adapter on the fabric with
no Zynq PS.  Every `zynq_bitstream_vN` artefact came from this flow, including
the `v10` bitstream the hardware bring-up guide tells you to flash first.

It exists because that flow used to live only in throwaway trees outside the
repository (`D:\vivadoProject\zynq_bitstream_vN\`), so a clone could not build
its own primary artefact and the runbook's commands pointed at paths that do not
exist in the repository.

## Which flow to use when

There are two independent Vivado flows.  Neither depends on the other.

* **PL-only (this directory) -- the default / primary build.**  The console runs
  entirely on the PL, and the cartridge image is baked into the bitstream's BRAM
  at synthesis.  Flash the `.bit` and you have a running console.  Use this
  unless you specifically need the PS feature below.
* **PS flow (`../ps/`).**  A Zynq PS runs a bare-metal loader that reads a `.nes`
  file from the SD card at runtime and streams it into the same BRAM over
  AXI4-Lite, plus a USB gamepad.  It is a **project-mode** flow because a block
  design is a project object, and it produces `BOOT.bin`, not a standalone
  `.bit`.  Use it when you want to change cartridge without re-synthesising.

Both flows build `nes_zynq_top`.  The PL-only flow binds it through
`nes_zynq_pl_top` (see below); the PS flow instantiates it inside the block
design.

## What is here

| File | Role |
| --- | --- |
| `build.tcl` | full non-OOC flow: `synth_design` -> `opt_design` -> `place_design` -> `phys_opt_design` -> `route_design`, plus reports and the BRAM INIT dump |
| `finish.tcl` | opens this run's own `out_route.dcp`, runs every assertion, writes the bitstream |
| `ph_build.tcl` | placeholder-control synthesis: the provenance half of the BRAM INIT differential |
| `nes_zynq_pl_top.v` | the PL-only wrapper that ties `nes_zynq_top`'s eight `ps_*` inputs inert |
| `nes_zynq_pl_top_extra.xdc` | the one top-relative constraint the repository XDC cannot express under the wrapper (the 640 ns `aud_bclk` generated clock) |
| `run_pl.ps1` | launcher: stages the throwaway work tree, resolves the toolchain and cartridge, retries the XGUI flake, runs the stages |

## How to build

```powershell
# full: synth -> route -> assertions -> bitstream (needs the cartridge below)
.\tools\pl\run_pl.ps1

# stop after route, no bitstream
.\tools\pl\run_pl.ps1 -Mode build

# provenance control (synthesis only, committed placeholder)
.\tools\pl\run_pl.ps1 -Mode control
```

By default the work tree is `tools/pl/out/` (gitignored); pass `-WorkDir` to put
it elsewhere, e.g. a throwaway tree outside the repository:

```powershell
.\tools\pl\run_pl.ps1 -WorkDir "$env:TEMP\pl_verify"
```

## The cartridge

The scripts place the real cartridge at the paths the top's committed default
`PRG_INIT_FILE` / `CHR_INIT_FILE` parameters name
(`rtl/nes_core/cart/prg_placeholder.hex` and `chr_placeholder.hex`).  That is
the mechanism, not a shortcut: `synth_design -generic` on the 2018.3 command
line delivers the quotes as part of the string value and synthesis dies with
`Synth 8-4445`.

The cartridge is read from `build/rom/prg.hex` (393216 bytes) and
`build/rom/chr.hex` (24576 bytes).  **`build/` is gitignored and the cartridge is
never committed.**  `run_pl.ps1` copies it into a throwaway work tree, so the
tracked placeholder hex in the repository is never overwritten.  A missing or
wrong-sized cartridge is a hard, up-front error, never a silent BRAM collapse.

A `$readmemh` that cannot find its file leaves the array partly uninitialised and
Vivado then optimises it away **silently**: the Block RAM tile count drops by the
cartridge's own 18 tiles and the design still meets timing and still places every
pin.  `build.tcl` therefore checks the cartridge file's size and first words
before synthesis, and `finish.tcl` asserts the absolute tile count (82) and the
per-array RAMB geometry after route.

## How a PL-only build ties the eight `ps_*` ports

`nes_zynq_top` gained seven `ps_*` cartridge-load inputs, an output `ps_ld_ready`
and an eighth input `ps_gamepad` for the PS flow.  A PL-only build has no PS to
drive them, and an undriven `ps_console_hold` would reach the core-domain reset
through its two-flop synchroniser as an unknown, holding the console.
`nes_zynq_pl_top` ties `ps_ld_valid`, `ps_ld_target`, `ps_ld_addr`, `ps_ld_data`,
`ps_load_enable`, `ps_console_hold` and `ps_gamepad` to zero and leaves
`ps_ld_ready` open -- exactly what `tb/platform/tb_nes_zynq_top.v` and
`tb/peripheral/tb_nes_audio_lane.v` already do.  No RTL is modified.

## What the artefact is checked against

`finish.tcl` asserts, on the routed design: 82 Block RAM Tiles, `RAMB18` = 0,
`LUT as Memory` = 2, 64 frame_mem cells (32 LCD + 32 HDMI), no routing errors, no
DRC errors, 53 of 53 pins placed, and 0 failing setup/hold endpoints.  `RAMB18`
and `LUT as Memory` are checked explicitly because a silently mis-inferred array
passes every simulation target while being wrong in hardware.
