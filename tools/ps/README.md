# tools/ps -- the PS half of runtime cartridge loading

This directory builds the software half of "load the cartridge from the TF card
at runtime instead of baking it into the bitstream". The PL half -- the
AXI4-Lite register bank, the clock-crossing bridge and the cartridge load port
-- is already in `rtl/` and gated; this directory connects the Zynq PS to it and
produces a bootable SD image.

## What is here

| File | Role |
| --- | --- |
| `build_ps.tcl` | Vivado 2018.3 block design + synthesis + implementation + bitstream + `.hdf` |
| `run_build.ps1` | launcher for `build_ps.tcl` (sets CWD, retries the XGUI flake, modes) |
| `ps7_vendor_cfg.tcl` | the PS7 IP configuration, derived from the vendor's own board example |
| `app/main.c` | the bare-metal cartridge loader, then the USB gamepad |
| `app/usb_hid.c` / `.h` | pure USB descriptor / HID parsing and the report-to-NES mapping (no Xilinx, host-tested) |
| `app/usb_gamepad.c` / `.h` | USB0 host-mode glue over the BSP `xusbps` driver |
| `host_test/` | the host test for `usb_hid.c` (builds and runs on this machine) |
| `sdk_flow.tcl` | xsct flow: hardware platform, FSBL, loader application (xilffs on its BSP) |
| `run_sdk.ps1` | launcher for `sdk_flow.tcl` + `bootgen` |
| `boot.bif` | boot image description: FSBL + application + PL bitstream |
| `init_diff.tcl` / `init_diff.ps1` | BRAM INIT differential that proves the cartridge content |

## How the two flows coexist

There are now **two independent Vivado flows**, and neither depends on the
other:

* **PL-only (primary, unchanged).** The non-project `build.tcl` / `finish.tcl`
  recipe over a frozen `nes_zynq_top` that shipped the emulator before this
  feature. It is still the primary build. It is *not* modified by anything in
  this directory, and it is run out of its own frozen tree, so nothing here
  touches it.
* **PS flow (additional).** `build_ps.tcl` is a **project-mode** flow because a
  block design is a project object. It reads the repository RTL, builds a block
  design (PS7 + `axi_protocol_converter` + `axi_lite_regs` + the real
  `nes_zynq_top`), derives its constraint file from the repository XDC, and
  produces `out/ps_nes.bit` and `out/ps_nes.hdf`.

The one RTL touch: `nes_zynq_top.v` gained seven `ps_*` ports and an internal
`nes_cart_load_bridge` instance (plus a two-flop synchroniser for the console
hold). Every board-independent instance -- including the platform bench -- ties
those ports inert, so behaviour with no PS is byte-for-byte the previous
behaviour. The PL-only flow's frozen copy of the tree is unaffected.

## How to build

```powershell
# 1. block design only (fast integration test)
.\tools\ps\run_build.ps1 -Mode bdonly

# 2. synthesis + reports, no implementation
.\tools\ps\run_build.ps1 -Mode synthonly

# 3. full: synth + place + route + bitstream + .hdf
.\tools\ps\run_build.ps1 -Mode full

# 4. FSBL + application + BOOT.bin (after step 3)
.\tools\ps\run_sdk.ps1

# 5. INIT differential (optional; proves the BRAM content)
& D:\Vivado\Vivado\2018.3\bin\vivado.bat -mode batch -source tools\ps\init_diff.tcl
.\tools\ps\init_diff.ps1

# 6. host test for the USB gamepad parsing logic (no Vivado, no hardware)
.\tools\ps\host_test\run_host_test.ps1
```

Toolchain paths used by the launchers: Vivado
`D:\Vivado\Vivado\2018.3\bin\vivado.bat`, SDK `D:\Vivado\SDK\2018.3\bin\xsct.bat`
and `bootgen.bat`.

### Why the project-mode flow has two traps handled explicitly

1. **`$readmemh` and the run directory.** Project-mode synthesis runs with its
   CWD set to the run directory, so a committed relative `$readmemh` path does
   not resolve and the ROM silently disappears (Block RAM falls to 0, everything
   else still looks green). `build_ps.tcl` installs a
   `STEPS.SYNTH_DESIGN.TCL.PRE` hook on `synth_1` that stages the committed hex
   into the run directory, and also points the module parameters at absolute
   paths.
2. **`puts` and `if` are not allowed in an XDC.** The derived constraint file
   contains only plain `set` / `set_false_path` / `set_max_delay` commands. A
   guarded or logged constraint is silently dropped.

## What the application does

`app/main.c`:

1. brings up UART0 (115200 8N1, MIO 14/15);
2. proves the PS<->PL link **before** trusting anything: `SCRATCH` round-trips
   four patterns and `ID` reads `0x4E455301`;
3. mounts the SD card through FatFs (xilffs over the `xsdps` driver, SD0 on
   MIO 40..45);
4. opens `0:/game.nes`, parses the 16-byte iNES header (magic, PRG/CHR sizes,
   trainer);
5. asserts `LOAD_EN` (which implies `HOLD`, so the console is held), streams PRG
   then CHR into `PRG_DATA` / `CHR_DATA` with the auto-incrementing address
   registers and little-endian lane order, then clears `LOAD_EN` to release the
   console.

Failure reporting is distinct and the console is **not** released on any of
them: link check failed, no card / unreadable filesystem, file not found, bad
iNES header, short read on PRG, short read on CHR.

## USB gamepad

After the console is released the application brings USB0 up in **host** mode,
enumerates one HID gamepad over the BSP `xusbps` driver, and polls its interrupt
IN endpoint, mapping each report to the NES button byte and writing it into
`SCRATCH[7:0]`. The loader runs first and is unchanged; the gamepad only starts
once the console is running. Full detail is in
[`docs/modules/ps-usb-gamepad.md`](../../docs/modules/ps-usb-gamepad.md).

* The pure logic (configuration-descriptor walk, HID report descriptor,
  report-to-NES mapping) is in `app/usb_hid.c` and is **host-tested**:
  `.\tools\ps\host_test\run_host_test.ps1` (60 checks, non-vacuity counters in
  `host_test/README.md`). The glue (`app/usb_gamepad.c`) cannot be tested here.
* **P4 "OTG SW" jumper.** The four Type-A host ports are only live in host mode,
  which the P4 jumper selects. A user who has not set P4 for host routing will
  see no device and no enumeration -- there is no software workaround.
* **Finding -- the buttons do not yet reach the NES.** The register bank is
  sufficient to *carry* the byte in `SCRATCH`, and the write is real and
  read-back-verifiable, but `nes_zynq_top.v` feeds `buttons1` from the touch
  panel only; no AXI register reaches it. Delivering the buttons needs a
  one-wire PL change (`reg_scratch[7:0]` -> `buttons1`, muxed with the touch
  pad), which means editing `rtl/`. This task must not edit `rtl/`, so it was
  not made. Until it is, a gamepad write reaches `SCRATCH` but no button press
  reaches the NES.

## Boot mode

The design assumes the board boots from the **SD card** (`BOOT.bin` on the
FAT-formatted card, boot mode jumper on SD). The BootROM loads the FSBL, the
FSBL programs the PL from the bitstream partition and starts the application,
and the application reads the cartridge from the same card.

## What has not been verified

**None of this has run on hardware.** No card has been read, no image has been
loaded into a real board, no UART output has been seen. Everything here is
verified only as far as: it synthesises, routes with all timing met, produces a
bitstream and an `.hdf` (Vivado 2018.3, `xc7z020clg400-2`), the application and
FSBL compile and link, and `bootgen` produces a three-partition `BOOT.bin`. The
register protocol itself is covered by the simulation gate on the RTL side.
