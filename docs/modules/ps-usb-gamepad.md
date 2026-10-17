# USB gamepad on the Zynq PS (`tools/ps/app/usb_gamepad.*`, `usb_hid.*`)

This is the USB HID gamepad path for the Zynq PS bare-metal application. It
brings USB0 up in **host** mode, enumerates one attached HID gamepad, and polls
its interrupt IN endpoint, mapping each report to the NES controller byte and
writing it into the existing AXI register bank.

It is built on the BSP's **`xusbps`** driver (a driver library, like `xsdps`),
not on any copied vendor RTL. There is **no vendor USB example anywhere** for
this board, so unlike the SD path this is original work with no reference.

> **This half has never touched hardware.** No device has been attached, no
> enumeration has run, no button press has reached the NES. The structure is
> built so that as much as possible is testable on the host and so that every
> failure names its stage; what remains unverified is stated at the end.

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
interrogate): `report[0]` bit0 = A, bit1 = B (other bits ignored);
`report[1]` bit0 = Select, bit1 = Start, bit4 = Up, bit5 = Down, bit6 = Left,
bit7 = Right. A device whose report differs will mis-map until its layout is
added; see `usb_hid.h`.

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
* the loader's `SCRATCH` link check and the gamepad's `SCRATCH` button writes
  never overlap;
* the loader path is byte-for-byte the code that was already gated.

If the loader fails it still stops before the gamepad, exactly as before.

## 8. The register the buttons go through, and the finding

The register bank does not have a dedicated button register, and all eight word
offsets are allocated (CTRL, SCRATCH, STATUS, ID, PRG_ADDR, PRG_DATA, CHR_ADDR,
CHR_DATA). No **new** register is needed to carry the buttons: `SCRATCH` (0x04)
is a general-purpose RW register that is free after the boot-time link check, so
the gamepad writes the NES byte into `SCRATCH[7:0]`. That write is real and
read-back-verifiable over the existing AXI path.

**Finding:** the register bank is sufficient to *carry* the byte, but it does
**not** currently *deliver* it to the console. `nes_zynq_top.v` feeds
`nes_system_v6.buttons1` from the touch panel only (`btn_sync_q`), and no AXI
register reaches it; `build_ps.tcl` even notes *"the repo axi_lite_regs has no
GPIO key output"*. Delivering the buttons needs a PL change -- sample
`reg_scratch[7:0]` into `buttons1` (muxed with the touch panel) -- which means
editing `rtl/`. That is forbidden by this task's constraints, so it was **not**
done. Until it is, a gamepad write reaches `SCRATCH` but no button press reaches
the NES. This is a one-wire change and is the whole remaining gap on the PL
side.

## 9. What is verified, and what is not

**Verified:**

* the pure logic (descriptor walk, report size, gamepad detection, button
  mapping) passes the host test: 60 checks, 0 failures, and the non-vacuity
  counters above;
* the three application sources compile cleanly with the ARM toolchain
  (`-Wall -Wextra`);
* the PS flow still builds end to end (block design, bitstream, FSBL,
  application, `BOOT.bin`); see section 10.

**Not verified -- and cannot be, here:**

* **Nothing has run on hardware.** No USB device has ever been attached, no
  enumeration has ever run, and no button press has ever reached the NES.
* Host-mode entry, root-port power, connect detection and port reset.
* Every control transfer and the driver's host-side device-address bookkeeping
  (`xusbps` has no host-mode address API; see section 3).
* The HID interrupt IN endpoint: priming, polling and report arrival.
* The real descriptor and report layout of any device.
* That `SET_IDLE`, `SET_ADDRESS`, `SET_CONFIGURATION` are accepted by any
  device.
* Whether `SCRATCH` is ever wired to `buttons1` (section 8 -- not done).

## 10. Build result

Rebuilt with this change through the existing scripts (`run_build.ps1 -Mode
full`, then `run_sdk.ps1`):

| Artefact | Value |
| --- | --- |
| Block design | validates; synthesis/implementation 0 errors |
| Bitstream `ps_nes.bit` | 4,045,674 bytes (unchanged -- no `rtl/` change) |
| Routed utilisation | 42,055 LUT / 40,378 FF / 82 BRAM (unchanged) |
| FSBL `fsbl.elf` | 537,276 bytes |
| Application `loader_app.elf` | 492,112 bytes (grew: now carries `usb_hid.c`, `usb_gamepad.c`, xusbps) |
| `BOOT.bin` | **4,215,424 bytes**, SHA256 `CD4F682A1180EC80C23D67B279B84977D85EB35026EEC83635EDEEEE41A5B39D` |

`BOOT.bin` is the same three-partition image (FSBL + application + PL bitstream)
the SD boot flow consumes. The PL is byte-for-byte the previous build because
`rtl/` was not touched, so the bitstream and utilisation figures are unchanged;
only the application grew.
