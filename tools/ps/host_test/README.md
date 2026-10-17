# tools/ps/host_test -- the host-testable half of the USB gamepad

This directory exists because the USB gamepad path cannot be verified on
hardware here: the board is unreachable, no USB device can be attached, and the
project's gate is Icarus/Verilog so it cannot execute ARM software. So the parts
that are pure functions of bytes were factored into
[`../app/usb_hid.c`](../app/usb_hid.c) and are asserted here, on this machine,
with an ordinary host C compiler.

## How to run

```powershell
.\tools\ps\host_test\run_host_test.ps1
```

It prefers MSVC `cl.exe` (found through `vcvars64.bat` / `vswhere`; present in
this environment as VS 2019/2022 Build Tools) and falls back to a host `gcc` on
`PATH`. It compiles `test_usb_hid.c` together with `../app/usb_hid.c` and runs
the result. Exit code is the test's: `0` = PASS, non-zero = FAIL. Nothing here
touches Vivado, the SDK, or the ARM toolchain.

## What it asserts

| Area | Cases |
| --- | --- |
| configuration-descriptor walk | a well-formed gamepad (HID interface first) with an 8-byte interrupt IN endpoint; the HID interface **not** first (a vendor interface precedes it); a HID interface whose interrupt IN endpoint has a **non-default `wMaxPacketSize`** (16 and 64) |
| distinct failure codes | HID interface but no interrupt IN endpoint (`NO_INT_IN`); an interrupt IN endpoint but no HID interface (`NO_HID`); `wTotalLength` past the buffer, and ending mid-descriptor (`TRUNCATED`); a zero-length descriptor (`BAD_LENGTH`); too short (`TOO_SHORT`); not a configuration (`NOT_CONFIG`) |
| HID report descriptor | a 16-button gamepad (2-byte report); a gamepad with two axes (3-byte report); a mouse that must **not** be reported as a gamepad; a truncated item; an empty descriptor |
| report -> NES buttons | every button pressed, none pressed, each single button, A+Right, unused bits only, and a report whose declared size is 1 byte against a 2-byte buffer (proves the size is honoured, not the buffer) |

The exact expected endpoint, packet size, interval, interface number, report
size and button byte of every case are asserted, so a stub returning a constant
cannot satisfy them.

## Non-vacuity: the observed counts

The test additionally counts that the code it claims to exercise actually ran,
and fails if any counter is zero. The numbers observed on this machine:

```
checks                = 60
endpoints_seen_total  = 6      (endpoint descriptors actually walked)
input_items_total     = 5      (HID report-descriptor Input items actually walked)
nonzero_btn_cases     = 12     (mapping cases whose result != 0)
```

`endpoints_seen_total > 0` is the guard against a parser that reports success
without ever reaching the endpoint-finding code; `nonzero_btn_cases > 0` is the
guard against a mapping that only ever returns zero.

## What the host test CANNOT cover

Everything that needs silicon or a device:

* controller init, host-mode entry, root-port power and connect detection;
* port reset and any timing around it;
* **enumeration**: `GET_DESCRIPTOR`, `SET_ADDRESS`, `SET_CONFIGURATION`,
  `SET_IDLE`, and the correctness of the controller's host-side device-address
  bookkeeping (see the finding in `../README.md`);
* the HID interrupt IN endpoint: priming, polling and report arrival;
* a real device's descriptor and report layout. The button layout
  `nes_buttons_from_report()` accepts is a documented convention, not a
  discovery -- see `../app/usb_hid.h`.

None of that has ever run. See `../README.md`, "What has not been verified".
