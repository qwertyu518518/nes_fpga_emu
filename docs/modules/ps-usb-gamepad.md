# USB gamepad on the Zynq PS (`tools/ps/app/usb_gamepad.*`, `usb_hid.*`)

This is the USB HID gamepad path for the Zynq PS bare-metal application. It
brings USB0 up in **host** mode, enumerates one attached HID gamepad, and polls
its interrupt IN endpoint, mapping each report to the NES controller byte and
writing it into the AXI register bank's dedicated `GAMEPAD` register (0x20). The
PL combines that register with the touch panel and delivers it to the console,
so a written button byte now reaches `nes_system_v6.buttons1`.

It is built on the BSP's **`xusbps`** driver (a driver library, like `xsdps`),
not on any copied vendor RTL. There is **no vendor USB example anywhere** for
this board, so unlike the SD path this is original work with no reference.

> **This half has never touched hardware.** No device has been attached and no
> enumeration has run. The PL delivery path is now simulated -- a byte written to
> `GAMEPAD` reaches `nes_system_v6.buttons1` -- but no button press has ever come
> from a real device. The structure is built so that as much as possible is
> testable on the host and so that every failure names its stage; what remains
> unverified is stated at the end.

---

## 1. The factoring: what is pure, and what the host test covers

The problem was split at the boundary between "a function of bytes" and "talks
to silicon".

| File | Purity | Tested on the host? |
| --- | --- | --- |
| `tools/ps/app/usb_hid.c` + `.h` | pure: configuration-descriptor walk, HID report-descriptor walk, report -> NES button mapping. No Xilinx header, no allocation, no hardware. | **yes** -- `tools/ps/host_test` |
| `tools/ps/app/usb_gamepad.c` + `.h` | hardware glue: `xusbps` init, host mode, control transfers, enumeration, endpoint polling. | no |
| `tools/ps/app/main.c` | integration: runs the (unchanged) cartridge loader first, then the gamepad, and names every failure stage. | no |

The only device-shaped logic -- locating the HID interface and its interrupt IN
endpoint, sizing the report, deciding "is this a gamepad", and turning report
bytes into `{A, B, Select, Start, Up, Down, Left, Right}` -- lives in
`usb_hid.c` and is asserted on the host. `usb_gamepad.c` hands the exact
descriptor bytes it reads to those pure functions, so a device that parses
incorrectly would be a failure of host-tested code, not of untested glue.

**What the host test cannot cover:** enumeration, USB transfers, timing, a real
device's actual descriptors, and anything the interrupt endpoint does. See
`tools/ps/host_test/README.md`.

## 2. The host test

Run it with:

```powershell
.\tools\ps\host_test\run_host_test.ps1
```

It compiles `test_usb_hid.c` with `../app/usb_hid.c` using a host compiler (MSVC
`cl.exe` via `vcvars64.bat`, or a host `gcc`) and runs it. It asserts the
well-formed gamepad descriptor, a HID interface that is not the first interface,
a non-default interrupt `wMaxPacketSize`, every-button and no-button reports, and
malformed/truncated descriptors (which must be **rejected**, not walked off the
end).

**Non-vacuity.** The observed counts on this machine:

```
checks                = 60
endpoints_seen_total  = 6
input_items_total     = 5
nonzero_btn_cases     = 12
```

`endpoints_seen_total > 0` proves the parser reached the endpoint-finding code
(a stub returning "ok" without walking endpoints fails this); `nonzero_btn_cases
> 0` proves at least one case produced a button pattern distinct from all-zero.
Both, plus `input_items_total > 0`, are asserted, so the test cannot pass
vacuously.

## 3. The hardware glue

BSP driver: **`xusbps`** (`usbps_v2_4`), already present in the BSP `libxil.a`
because the vendor PS7 configuration enables USB0. Functions used:
`XUsbPs_LookupConfig`, `XUsbPs_CfgInitialize`, `XUsbPs_ConfigureDevice` (endpoint
DMA / queue-head memory), `XUsbPs_EpBufferSend` / `XUsbPs_EpBufferReceive` /
`XUsbPs_EpBufferRelease` (control and interrupt transfers), `XUsbPs_EpEnable`,
`XUsbPs_Start` / `XUsbPs_Stop`, and the `XUsbPs_ReadReg`/`WriteReg`/`SetBits`/
`ClrBits` register macros.

Enumeration sequence, in order:

1. look up and initialise the controller (`XUsbPs_CfgInitialize`);
2. set up EP0 (control) DMA/queue-head memory (`XUsbPs_ConfigureDevice`);
3. switch to **host** mode (write `XUSBPS_MODE_CM_HOST_MASK` to the USB mode
   register) and power the root port (`XUSBPS_PORTSCR_PP_MASK`), then start;
4. wait for connect (`XUSBPS_PORTSCR_CCS`);
5. bus reset (hold `XUSBPS_PORTSCR_PR`, release, wait for port enable);
6. `GET_DESCRIPTOR(DEVICE)`;
7. `SET_ADDRESS`;
8. `GET_DESCRIPTOR(CONFIGURATION)` (9 bytes for `wTotalLength`, then the whole
   descriptor), and hand it to `usb_parse_config_descriptor`;
9. `GET_DESCRIPTOR(HID REPORT)` for the HID interface, and hand it to
   `hid_parse_report_descriptor`;
10. `SET_CONFIGURATION`;
11. `SET_IDLE` for the HID interface;
12. enable the interrupt IN endpoint and poll it, mapping each report with
    `nes_buttons_from_report`.

### Why some of this pokes registers directly

This `xusbps` version is a **device-mode** driver: `XUsbPs_ConfigureDevice`
configures the device role, there is no `XUsbPs_ConfigureHost`, its queue heads
carry no device-address field, and `XUsbPs_SetDeviceAddress()` writes register
`0x154`, which in host mode is the periodic-frame-list base -- so it must not be
called in host mode. Host mode is therefore entered by writing the mode and
root-port registers directly (the hardware's own requirement), and the control
transfers ride on the driver's EP0 buffers. This is the least-certain part of
the glue and is called out again in section 9.

## 4. Distinct failure stages

Every stage returns a distinct code, printed by `main.c`; there is no silent
stall. From `usb_gamepad.h`:

| Stage | Code | UART line |
| --- | --- | --- |
| controller lookup | `USBGP_ERR_LOOKUP` | `controller lookup failed` |
| controller init | `USBGP_ERR_CFG_INIT` | `controller init failed` |
| endpoint/DMA config | `USBGP_ERR_DEV_CONFIG` | `controller endpoint/DMA config failed` |
| no device / port reset | `USBGP_ERR_NO_DEVICE` | `no device attached (port reset failed)` |
| device descriptor | `USBGP_ERR_DEV_DESCRIPTOR` | `device descriptor malformed` |
| `SET_ADDRESS` | `USBGP_ERR_SET_ADDRESS` | `SET_ADDRESS failed` |
| configuration descriptor | `USBGP_ERR_CONFIG_DESCRIPTOR` | `configuration descriptor malformed` |
| no HID interface | `USBGP_ERR_NO_HID` | `no HID interface in the configuration` |
| no interrupt IN endpoint | `USBGP_ERR_NO_INT_IN` | `HID interface has no interrupt IN endpoint` |
| `SET_CONFIGURATION` | `USBGP_ERR_SET_CONFIG` | `SET_CONFIGURATION failed` |
| `SET_IDLE` | `USBGP_ERR_SET_IDLE` | `SET_IDLE failed` |
| report descriptor | `USBGP_ERR_REPORT_DESCRIPTOR` | `HID report descriptor failed/malformed` |
| not a gamepad | `USBGP_ERR_NOT_GAMEPAD` | `report descriptor is not a gamepad` |
| endpoint poll | `USBGP_ERR_POLL` | `interrupt endpoint poll failed` |

"configuration descriptor malformed", "no HID interface" and "no interrupt IN
endpoint" are three different codes because they need three different fixes.

## 5. The button mapping, and the bit order

`nes_controller.v` latches `buttons` and shifts **bit 0 out first** on `$4016`
(`data_bit = latch_strobe ? sel_buttons[0] : ...`, `nes_controller.v:62`), and
`nes_touch_input.v:92-94` names the order explicitly: *"buttons[7:0] ... the
order is A, B, Select, Start, Up, Down, Left, Right"*, with
`buttons = {touch_dpad, key_start, key_select, btn_b, btn_a}`. So:

| bit | 0 | 1 | 2 | 3 | 4 | 5 | 6 | 7 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| NES | A | B | Select | Start | Up | Down | Left | Right |

`nes_buttons_from_report()` produces exactly this byte. The accepted HID report
layout it maps from is a **documented convention** (there is no device to
interrogate): after any Report ID, byte 0 bit0 = A, bit1 = B (other bits
ignored); byte 1 bit0 = Select, bit1 = Start, bit4 = Up, bit5 = Down, bit6 =
Left, bit7 = Right. A device whose report differs will mis-map until its layout
is added; see `usb_hid.h`.

**This convention is a contribution, not a general HID interpreter, and it does
not match most real pads.** A typical Xbox-style pad puts the analog axes in the
low bytes and packs the buttons into a 16-bit word later in the report, so this
layout reads axes as buttons and the buttons come out wrong or absent. That is a
layout mismatch in `nes_buttons_from_report()`, **not** a wiring or bus fault: if
the pad enumerates (stops at no `USBGP_ERR_*` stage) but the buttons are wrong,
the device simply does not follow this convention. The fix is to read that
device's real report layout, which is deliberately out of scope here.

When the report descriptor declares a Report ID, the report on the wire is
`[ID][buttons...]`, so the mapper is given an explicit offset (1 with a Report ID,
0 without) and reads the buttons from the byte after the ID. Reading the ID byte
as buttons was a real defect; the host test now pins it down with a report-ID
gamepad whose ID byte aliases the wrong button.

## 6. The P4 "OTG SW" jumper -- a user instruction

**The four USB Type-A host ports are only live in host mode, and on this board
host mode is selected by the P4 "OTG SW" jumper.** A user who has not set P4 for
host routing will see no enumeration and will conclude the code is broken. There
is no software workaround: the jumper selects the routing at the connector, not
a register.

## 7. Coexistence with the cartridge loader

The cartridge loader runs **first and unmodified**. Only after it has streamed
the image and released the console (`CTRL = 0`) does `main()` call
`run_gamepad()`. This is a deliberate, single-threaded decision:

* the console is held during the load, so no input is needed then;
* the loader's `SCRATCH` link check and the gamepad's `GAMEPAD` (0x20) button
  writes are different registers and can never race;
* the loader path is byte-for-byte the code that was already gated.

If the loader fails it still stops before the gamepad, exactly as before.

## 8. The register the buttons go through, and how they reach the console

The gamepad writes a dedicated **`GAMEPAD` register at offset 0x20**, not
`SCRATCH`. `SCRATCH` (0x04) belongs to the boot-time link check, which writes
four patterns through it to prove the PS<->PL link; the gamepad writes a byte per
report, so sharing one register would race the two. `GAMEPAD` is a plain RW word
with per-byte WSTRB semantics like every other writable register. It is the ninth
word, which is why the AXI address port widened from five bits to six; the
existing eight words are unchanged.

**The register now reaches the controller.** `axi_lite_regs` brings the low byte
out as `pl_gamepad[7:0]`; `build_ps.tcl` connects it to `nes_zynq_top.ps_gamepad`;
and `nes_zynq_top` ORs it with the touch panel's byte **in the `sys_clk` domain**
and crosses the sum into the core domain through the same two-flop synchroniser
the touch buttons already used (`btn_meta_q`/`btn_sync_q`). Combining in the
source domain and crossing once is deliberate: both sources are `sys_clk`, so
crossing them separately and ORing in the core could sample two different
reports.

**The rule is OR, not override.** The touch panel and the on-board TPAD are
proven inputs that work on hardware today; a gamepad must be able to play
alongside them, not silently disable them whenever a pad reports. Override would
mean that plugging in a gamepad (or a stray HID report) drops the panel. The OR
also matches what a user expects from two attached input devices. The gamepad
register's launch arc is a new `sys_clk -> mmcm_core_clk` crossing, so it gets
its own bounded `set_max_delay -datapath_only 20.000` in the derived XDC (the
source XDC already bounds the touch half).

![图 1：USB 手柄通路与证据](../figures/ps-usb-gamepad.svg)

**图 1** · 从板级 Type-A 口到 `nes_system_v6.buttons1` 的三段：板级接线（ULPI PHY / hub / Type-A，含 P4 "OTG SW" 跳线）、PS 软件（host 模式、枚举、host-tested 纯解析、中断轮询）、PL 送达路径（`GAMEPAD` 0x20 → `OR` → 2FF → `buttons1`）。绿标 = 有仿真或 host test 证据，红标 = **从未运行**，黄标 = 板级事实（非 RTL/源码事实）。事实来源 [`usb_gamepad.c`](../../tools/ps/app/usb_gamepad.c)、[`usb_hid.h`](../../tools/ps/app/usb_hid.h)、[`main.c`](../../tools/ps/app/main.c)、[`build_ps.tcl`](../../tools/ps/build_ps.tcl)、[`nes_zynq_top.v`](../../rtl/platform/zynq/nes_zynq_top.v)。生成图，勿手改。

**Coverage.** `tb/platform/tb_nes_zynq_top.v` instantiates the real
`axi_lite_regs` slave (exactly as the block design does), performs a real AXI
write into 0x20, and requires the value at `nes_system_v6.buttons1`; it then
holds the gamepad and the touch keys active together and requires the OR
(`touch 0x03 | gamepad 0x0C == 0x0F`). Removing the PL connection makes that
assertion fail (`GP_BTN_AT_CORE`, `GP_OR_ARBITRATION`), so it is not vacuous.
`tb/platform/tb_axi_lite_regs.v` additionally pins the register's WSTRB lanes and
its `pl_gamepad` output.

## 9. What is verified, and what is not

**Verified:**

* the pure logic (descriptor walk, report size, gamepad detection, button
  mapping) passes the host test: 60 checks, 0 failures, and the non-vacuity
  counters above;
* the three application sources compile cleanly with the ARM toolchain
  (`-Wall -Wextra`);
* the PL delivery path is simulated: a real AXI write into `GAMEPAD` (0x20)
  appears at `nes_system_v6.buttons1`, and the gamepad/touch combination is the
  OR (section 8). This assertion fails against RTL without the connection, so it
  is not vacuous;
* the full simulation gate passes (`sim_all.ps1 -Mode all`, 73/73);
* the PS flow still builds end to end (block design, bitstream, FSBL,
  application, `BOOT.bin`); see section 10.

**Not verified -- and cannot be, here:**

* **Nothing has run on hardware.** No USB device has ever been attached, no
  enumeration has ever run, and no button press has ever reached the NES. What
  is now proven is only that a byte written to `GAMEPAD` *can* reach the
  console's controller input; nothing proves that byte was ever produced by a
  real device.
* Host-mode entry, root-port power, connect detection and port reset.
* Every control transfer and the driver's host-side device-address bookkeeping
  (`xusbps` has no host-mode address API; see section 3).
* The HID interrupt IN endpoint: priming, polling and report arrival.
* The real descriptor and report layout of any device.
* That `SET_IDLE`, `SET_ADDRESS`, `SET_CONFIGURATION` are accepted by any
  device.
* The gamepad register's `sys_clk -> core_clk` crossing has not been routed and
  timing-closed yet in isolation; the derived-XDC bound is in place, and the
  routed build is checked against it (section 10).

## 10. Build result

Rebuilt with this change through the existing scripts (`run_build.ps1 -Mode
full`, then `run_sdk.ps1`), now including the PL delivery path. Rebuilt again on
`master` at `389e365` (2026-10-19) with the HDMI output and the two touch fixes
present; the figures below are that rebuild:

| Artefact | Value |
| --- | --- |
| Block design | validates; synthesis/implementation 0 errors |
| Routed timing | **WNS +2.364 ns, 0 failing setup endpoints** (of 85,966); WHS +0.051, 0 hold; all user constraints met |
| Routed utilisation | 42,120 LUT / 40,434 FF / **82 Block RAM Tile / RAMB18 = 0** |
| CHR/PRG arrays | still in block RAM: `u_prg_rom` RAMB36 = 16, `u_cart_chr` RAMB36 = 2, RAMB18 = 0 for both |
| Bitstream `ps_nes.bit` | 4,045,674 bytes, SHA256 `54EFE1DABE226DB227FCAAAC1E5540D333E6F2D7F1676C33FD8010E6E3AA20E7` |
| FSBL `fsbl.elf` | 537,276 bytes |
| Application `loader_app.elf` | 492,240 bytes |
| `BOOT.bin` | **4,215,424 bytes**, SHA256 `972596583FD21908CB41781CB95FDF457474B99A7087C52C341972C1E3156979` |

`BOOT.bin` is the same three-partition image (FSBL + application + PL bitstream)
the SD boot flow consumes. The gamepad register crossing adds one
`sys_clk -> mmcm_core_clk` path set, bounded in the derived XDC (see section 8);
with that bound the routed design has 0 failing endpoints. The first attempt
left the bound inside an `if`, which the XDC language silently rejects
(`Designutils 20-1307`), and those eight `reg_gamepad_reg -> btn_meta_q_reg`
endpoints failed at WNS -2.429 ns until the `if` was removed.
