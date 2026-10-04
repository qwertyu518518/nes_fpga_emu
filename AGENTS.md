# NES FPGA 项目代理说明

## 项目目标

本项目使用 Verilog 逐步实现 NES/FC 模拟器，先完成可仿真的 CPU、Bus、PPU 核心，再接入 EP4CE10 开拓者板的 VGA、TF、SDRAM 和 WM8978。软件参考代码只用于分析和实验，不直接复制为本项目 RTL。

## Cloned Dependency Source

Read-only dependency source repositories are available under `.slim/clonedeps/repos/` for inspection. Do not edit these clones.

- `.slim/clonedeps/repos/caseif__cNES/` - C11 NES emulator at commit `7c8c252`; primary reference for bus, PPU, DMA, and mapper architecture.
- `.slim/clonedeps/repos/caseif__c6502/` - C6502 at commit `4f4bf74`; primary reference for CPU state and bus-cycle analysis.
- `.slim/clonedeps/repos/ObaraEmmanuel__NES/` - C NES emulator at commit `aa880b9`; auxiliary reference for APU, DMC DMA, and recent mapper behavior.

## Implementation rules

- Keep vendor-independent NES RTL under `rtl/nes_core/`.
- Keep EP4CE10-specific adapters and constraints under `rtl/platform/ep4ce10/`.
- Keep simulation testbenches under `tb/` and verification scripts under `tools/`.
- Treat NESdev and test ROMs as the behavior authority; cloned emulators are observations, not specifications.
- Do not add inline code comments unless explicitly requested; put teaching material in `docs/`.

## Text file encoding rules

All files in this repository are **UTF-8 without BOM and LF line endings**.

- Do **not** round-trip this repository's text files through PowerShell `Get-Content` / `Set-Content` / `Out-File`. Under Windows PowerShell 5.1 those cmdlets use the system ANSI code page, so UTF-8 Chinese is decoded as mojibake and the GBK decoder silently swallows LF bytes, collapsing line breaks. A real incident destroyed about 90 newlines in `README.md` (283 lines became 193) and the file had to be rebuilt by hand.
- Use the editor tools for document edits. When a shell measurement of a text file is unavoidable, read it with `[IO.File]::ReadAllText($path, [Text.UTF8Encoding]::new($false, $true))` and never write it back that way.
- After any bulk edit, verify: LF-only, no BOM, no U+FFFD, and a plausible line count. Run `.\tools\check_text_encoding.ps1`; it reads raw bytes, checks all four conditions, and exits non-zero on any violation. Add `-MinLines <n>` when an edit should not have reduced a file's length.

## Verification gate

`.\tools\sim_all.ps1 -Mode all` is the authoritative gate. Run it and confirm every target is PASS before reporting work as done, and again after any change to the target list. A module that has no target in that script has no regression protection.
