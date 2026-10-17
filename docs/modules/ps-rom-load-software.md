# PS runtime cartridge loading -- the software half (`tools/ps/`)

This is the software half of "load the cartridge from the TF card at runtime
instead of baking it into the bitstream". Its PL half -- `axi_lite_regs`,
`nes_cart_load_bridge` and the cartridge load port -- is documented in
[`ps-rom-load.md`](ps-rom-load.md). This document is how to build the PS flow,
what the block design connects, and what was measured.

> **This document does not restate the process for its own sake.** The measured
> numbers below come from one run of the flow in this repository and are
> reported with their source (`tools/ps/out/*.rpt`, generated, not committed).
> To reproduce them, run `tools/ps/run_build.ps1 -Mode full` then
> `tools/ps/run_sdk.ps1`; see `tools/ps/README.md`.

---

## 1. How the two flows coexist

There are two independent Vivado flows.

* **PL-only (primary, unchanged).** The non-project `build.tcl` / `finish.tcl`
  recipe over a frozen `nes_zynq_top`. It is still the primary build, it is not
  modified by this feature, and it runs out of its own frozen tree. Its
  `finish.tcl` asserts exactly 44 top-level ports with package pins; that is
  the frozen tree's contract, not this tree's.
* **PS flow (additional).** `tools/ps/build_ps.tcl` is **project-mode** because
  a block design is a project object. It builds PS7 + `axi_protocol_converter` +
  `axi_lite_regs` + the real `nes_zynq_top`, and produces a bitstream and a
  `.hdf`. It never edits anything the PL-only flow reads.

The single RTL touch is additive: `nes_zynq_top.v` gained seven `ps_*` ports,
an internal `nes_cart_load_bridge` instance, and a two-flop synchroniser for the
console hold. A board-independent instance ties the ports inert, so behaviour
with no PS is unchanged and the simulation gate still passes.

## 2. What the block design connects

| Block design cell | What it is |
| --- | --- |
| `processing_system7_0` | PS7 from the vendor board example: FCLK0 = 50 MHz, `M_AXI_GP0` on, SD0 on MIO 40..45 (no card detect), USB0 on MIO 28..39, UART0 on MIO 14/15 |
| `axi_pc` | `axi_protocol_converter` AXI3 -> AXI4-Lite, required because `M_AXI_GP0` is AXI3 |
| `axi_lite_regs_0` | the repository's hand-written AXI4-Lite slave, at `0x4120_0000` |
| `rst_ps7_50M` | `proc_sys_reset` for the 50 MHz domain |
| `nes_zynq_top_0` | the real platform top, as a module reference |
| `status_zero` | an 8-bit `xlconstant` for `pl_status_in` (this design publishes no PL status bit) |

FCLK_CLK0 clocks `axi_pc`, `axi_lite_regs_0` and `nes_zynq_top_0/sys_clk` (so
the top's `sys_clk` domain *is* the PS domain). The peripheral reset drives the
matching `aresetn`/`sys_rst_n`. The slave's `pl_load_enable`, `pl_console_hold`
and `pl_ld_*` handshake connect directly to the top's `ps_load_enable`,
`ps_console_hold` and `ps_ld_*` ports; inside the top the bridge crosses into
the core clock domain and drives the PRG and CHR arrays.

`SmartConnect` is deliberately **not** used: for a one-to-one register bank it
measured 2,013 LUT / 2,539 FF against the hand-written slave's 145 / 226.

## 3. Constraint treatment (and why it is scoped, not blanket)

The constraint file is **derived** from `rtl/platform/zynq/nes_zynq_top.xdc`:
the `sys_clk` / `sys_rst_n` pin lines and the `sys_clk` `create_clock` are
dropped (the PS owns those), the `aud_bclk` generated clock's `-source` is
retargeted hierarchically, and everything else is carried through. Then:

* **Reset distribution.** The PS reset reaches each clock domain's inline reset
  synchroniser. The synchronous release is intra-domain and timed; the
  asynchronous assertion has no real requirement, so it gets a **scoped
  `set_false_path -to`** on the named first-stage synchroniser async pins only
  (`rst_{sys,core,lcd,hdmi}_q`, `locked_*`, `hdmi_locked_*`, `codec_cfg_*`,
  `btn_*`, and the console-hold synchroniser). A bounded treatment was measured
  first and does **not** work: `set_max_delay -datapath_only` governs the
  setup/hold data path and does not bound recovery/removal.
* **The platform-top pixel pipeline** (`px_*_q`, `vid_*_q`) still takes the raw
  board reset, so its recovery/removal arcs are also PS-reset -> core. The
  earlier probe removed those arcs in RTL (pointing the pipeline at `rst_core`);
  this task is constrained not to change `rtl/` behaviour, so the same scoped
  false path is extended to exactly those named registers instead. It is still
  not a blanket reset false path.
* **CDC bounds.** The PS clock and the core clock are MMCM-related, so the
  bridge's crossing paths fail by construction. They get the repository's
  synchroniser idiom, `set_max_delay -datapath_only 20.000`, scoped to the
  launch registers (including `axi_lite_regs`' CTRL register, which drives
  `host_load_enable`) and the first-stage destination registers.
* **The console hold** is synchronised into the core domain inside the top
  before it is ORed into the core reset. Without that synchroniser, ORing a
  PS-domain register into the core reset put **37,412 endpoints** on the
  `clk_fpga_0 -> mmcm_core_clk` setup check at **-12.798 ns** (measured, first
  routed attempt).

Note: `puts` and `if` are **not supported in an XDC constraint file**; the
derived file contains only plain constraint commands. A guarded or logged
constraint is silently dropped.

## 4. Measured result (Vivado 2018.3, `xc7z020clg400-2`, project mode)

Source: `tools/ps/out/ps_util_routed.rpt`, `ps_timing_routed.rpt`,
`ps_route_status.rpt`; generated by `run_build.ps1 -Mode full`.

| Quantity | Value |
| --- | --- |
| Slice LUTs | 42,055 / 53,200 = 79.05 % |
| &nbsp;&nbsp;LUT as Logic | 41,993 |
| &nbsp;&nbsp;LUT as Memory | 62 |
| Slice Registers | 40,378 / 106,400 = 37.95 % |
| Block RAM Tile | 82 (RAMB36E1 only) |
| RAMB18 | 0 |
| DSPs | 0 |
| WNS / TNS (setup) | **+1.767 ns / 0.000** |
| WHS / THS (hold) | +0.043 ns / 0.000 |
| Failing setup / hold endpoints | **0 / 0** |
| Router | Completed successfully; 0 unrouted nets, 0 routing errors; **1** `[Route 35-447]` congestion warning |
| Route time | opt 0:26, place 1:40, route 5:18, impl total ~9:08 |
| Bitstream | `tools/ps/out/ps_nes.bit`, 4,045,674 bytes, SHA256 `F2F889BF4F70670765F4EC6BCA26578EB898C8A139FCB79CBE4FCA5E3CF16C30` |
| Hardware handoff | `tools/ps/out/ps_nes.hdf`, 326,174 bytes |

Reference points: the earlier probe (which had no cartridge-load bridge)
reported 41,988 LUT / 40,331 FF / 82 BRAM / WNS +2.356 / 0 failing; the PL-only
baseline is 41,533 LUT / 39,626 FF / 82 BRAM. This build is **+522 LUT / +752 FF
over the PL-only baseline** (it carries the AXI protocol converter, the register
bank, the bridge and the hold synchroniser), and **+67 LUT / +47 FF over the
probe**.

**On `LUT as Memory = 62`.** The PL-only design reports 2; the PS design reports
62 because the AXI interconnect adds ~60 LUTRAM, and the probe's PS build also
reported exactly 62. The number that matters for the silent-BRAM regression is
that `Block RAM Tile = 82` and `RAMB18 = 0`: the CHR/PRG arrays are still in
block RAM. A wrong write-port shape was measured elsewhere in this project at
3,074 LUT-as-Memory and 1,024 distributed RAM; that is not what happened here.

## 5. Cartridge provenance -- INIT differential

Tile count cannot distinguish one image from another: 82 BRAM tiles appear
whether the array holds the committed placeholder or any other bytes. So the
cartridge content is proved by an **INIT differential**:
`init_diff.tcl` dumps every RAMB cell's `INIT_00..INIT_3F` and
`INITP_00..INITP_3F` from the committed synthesis and from a control synthesis
of the identical tree whose two hex files have their first byte flipped, and
`init_diff.ps1` diffs the two dumps by label.

Measured: **10 of 82 RAMB cells differ (8 PRG + 2 CHR), 10 INIT words differ, 0
INITP words differ, and all 64 frame-memory cells are identical.** That is
non-vacuous (the control really changed the cartridge) and specific (only the
cartridge moved). The PS build's baked image is the committed placeholder; the
runtime image is what the application streams in.

## 6. Boot mode and user procedure

The design assumes the board boots from the **SD card**:

1. format a micro SD card FAT32;
2. copy `tools/ps/BOOT.bin` (4,215,424 bytes,
   SHA256 `CD4F682A1180EC80C23D67B279B84977D85EB35026EEC83635EDEEEE41A5B39D`)
   to the root;
3. copy the cartridge image to the root as `0:/game.nes`;
4. set the board's boot-mode selector to SD and power on.

(That `BOOT.bin` carries the cartridge loader *and* the USB gamepad path; the
loader still runs first and is unchanged. See
[`ps-usb-gamepad.md`](ps-usb-gamepad.md).)

`BOOT.bin` carries three partitions: the FSBL, the loader application, and the
PL bitstream (verified by measuring `bootgen` output with and without the
bitstream partition: the delta is 4,045,624 bytes, the bitstream's payload).

## 7. What is verified, and what is not

Verified:

* RTL half still passes `tools/sim_all.ps1 -Mode all` (the load path benches).
* The block design builds and validates; the full design synthesises, routes
  with **0 failing endpoints** and all timing met, and writes a bitstream.
* The FSBL and the application compile and link (arm-none-eabi).
* `bootgen` produces a three-partition `BOOT.bin`, and the bitstream partition
  is present.

**Not verified:**

* **Nothing has run on hardware.** No SD card has been read, no image has been
  loaded into a real board, no UART output has been observed.
* The PS-side boot chain (FSBL -> PL configuration -> application -> SD read)
  is entirely untested end to end.
* The application's runtime behaviour (timing of `LOAD_EN`, the byte stream
  into the arrays) is covered only by the RTL simulation gate, not on silicon.
