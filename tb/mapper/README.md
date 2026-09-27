# Mapper testbenches

本目录的四个 testbench 全部自包含：自己填 PRG/CHR 签名镜像，不加载 ROM，不需要 test ROM。它们验证 `rtl/nes_core/mapper/` 的 mapper RTL 与 TB 之间的内部一致性，不构成任何真实 ROM 行为或综合/板级证据。

接口合同、每个 mapper 的寄存器与地址译码模型、以及软件 C mapper dispatch/指针/寄存器模型到 RTL 的映射关系，见 [`docs/modules/mappers.md`](../../docs/modules/mappers.md)。

## 文件

| 文件 | 顶层 | 覆盖 |
|---|---|---|
| `tb_nes_mapper.v` | `tb_nes_mapper` | NROM-256（32 KiB）、UxROM、CNROM、mirroring、bus conflict、`mapper_select` 隔离 |
| `tb_nes_mapper_nrom128.v` | `tb_nes_mapper_nrom128` | NROM-128（16 KiB 镜像）、vertical header mirroring、WRAM 窗口 |
| `tb_nes_mapper_mmc1.v` | `tb_nes_mapper_mmc1` | MMC1 串行移位寄存器、PRG mode、CHR mode、mirroring、reset bit |
| `tb_nes_mapper_mmc3.v` | `tb_nes_mapper_mmc3` | MMC3 PRG/CHR bank、CHR inversion、mirroring、A12 观测、IRQ latch/reload/enable/ack |

## 运行

RTL 和 testbench 都用 `-g2001`，输出放在临时目录：

```powershell
$tmp = Join-Path $env:TEMP 'op_fpga_emu'
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
$rtl = @(
  'rtl\nes_core\mapper\nes_mapper.v',
  'rtl\nes_core\mapper\nes_mapper_nrom.v',
  'rtl\nes_core\mapper\nes_mapper_uxrom.v',
  'rtl\nes_core\mapper\nes_mapper_cnrom.v',
  'rtl\nes_core\mapper\nes_mapper_mmc1.v',
  'rtl\nes_core\mapper\nes_mapper_mmc3.v'
)
& 'C:\iverilog\bin\iverilog.exe' -g2001 -s tb_nes_mapper_mmc3 -o (Join-Path $tmp 'tb_nes_mapper_mmc3.vvp') @rtl 'tb\mapper\tb_nes_mapper_mmc3.v'
& 'C:\iverilog\bin\vvp.exe' (Join-Path $tmp 'tb_nes_mapper_mmc3.vvp')
```

把 `-s` 和文件换成其他顶层即可。RTL 也可以不带 testbench 单独 elaborate，例如：

```powershell
& 'C:\iverilog\bin\iverilog.exe' -g2001 -s nes_mapper -o (Join-Path $tmp 'nes_mapper_core.vvp') @rtl
```

可单独 elaborate 的顶层：`nes_mapper`、`nes_mapper_nrom`、`nes_mapper_uxrom`、`nes_mapper_cnrom`、`nes_mapper_mmc1`、`nes_mapper_mmc3`。

## 固定期望输出

每个 testbench 打印一串分组 `PASS` 行、一行 `CHECKS n`，最后一行 `PASS <top> <摘要>`。当前仓库状态下的完整输出：

```text
NROM 32K prg windows, chr ram writes, header mirroring PASS
UXROM 16K bank register, fixed last bank, chr ram PASS
UXROM bus conflict AND latch driven by external rom readback PASS
UXROM bus conflict reject-on-mismatch mode PASS
CNROM 8K chr bank, fixed 16K prg, chr rom write ignore PASS
CNROM bus conflict AND latch uses per-address rom readback PASS
MAPPER select gating prevents cross-mapper register writes PASS
CHECKS 96
PASS tb_nes_mapper nrom/uxrom/cnrom/mirroring/bus-conflict
```

```text
NROM 16K prg mirror across 8000-C000 PASS
NROM 16K wram window at 6000-7FFF PASS
CHECKS 20
PASS tb_nes_mapper_nrom128 16k-mirror/vertical-mirroring
```

```text
MMC1 reset state control=0x0C prg mode 3 single lower PASS
MMC1 serial register commits only on the fifth write PASS
MMC1 serial bit order lsb first and prg ram bit4 PASS
MMC1 8000/A000/C000/E000 serial register decode PASS
MMC1 prg bank modes 0/1/2/3 window mapping PASS
MMC1 chr bank modes 0/1 window mapping PASS
MMC1 mirroring control bits 0-1 PASS
MMC1 reset bit clears serial register and control PASS
MMC1 reset bit aborts a partial serial sequence PASS
CHECKS 98
PASS tb_nes_mapper_mmc1 serial/prg-mode/chr-mode/mirroring/reset
```

```text
MMC3 reset bank map bank6=0 bank7=1 last two banks fixed PASS
MMC3 prg 8K bank mode swap and 6-bit bank mask PASS
MMC3 chr 2K/1K window mapping with R0/R1 bit0 ignored PASS
MMC3 chr inversion swaps 0000-0FFF with 1000-1FFF PASS
MMC3 A000 mirroring, 8000 bit5 ram enable, A001 protect PASS
MMC3 irq latch load, reload and a12 decrement PASS
MMC3 irq latch countdown assert, disable/ack, enable PASS
MMC3 irq latch 0 asserts on every filtered edge PASS
MMC3 a12 rising edge filter with cooldown PASS
MMC3 configurable a12 edge polarity PASS
MMC3 even/odd address aliasing and 8000 range gating PASS
CHECKS 145
PASS tb_nes_mapper_mmc3 banks/mirroring/a12-irq-latch-reload-ack
```

失败时 `expect*` 任务会打印 `FAIL <标签>: got <实际> expected <期望>`，并以 `FAIL <top> with n failing checks` 收尾。工具缺失、编译错误、testbench 全局超时同样是失败。

## 断言覆盖要点

- PRG/CHR ROM 用签名填充：PRG 每字节是 `8'h40 + 8 KiB bank 号`，CHR 每字节是 `8'h80 + 1 KiB bank 号`。期望值由 TB 依据 mapper 语义独立算出，不读 DUT 的偏移输出，所以断言不构成自证。
- 每个 testbench 都直接断言 `prg_bank_offset` / `chr_bank_offset` 的具体值，用来区分“bank 选择错了”和“ROM 内容错了”。
- bus conflict 用 `readback_force_enable` / `readback_force_data` 构造冲突字节，避免改动 ROM 内容污染其他测试；每个冲突测试最后都关掉强制，断言 `prg_readback` 等于 `prg_rom[prg_bank_offset]`，证明读回值来自外部 ROM 并跟随当前 bank。
- MMC3 的 A12 上升沿和下降沿用两个独立实例分别驱动（`dut` 与 `u_mmc3_fall`），`u_mmc3_fall` 接独立的 `ppu_a12_fall`，因此可以断言“下降沿实例拉线时上升沿实例不受影响”。
- MMC3 测试用 `cpu_read` / `cpu_write` 任务和 `a12_rise_accepted` / `a12_fall_accepted` / `idle_clk` 任务精确控制时钟边沿数量。A12 相关的任务必须留够 cooldown（接受沿后至少隔 3 拍），`idle_clk` 的参数声明为 `input [7:0] cycles`，不能写成无类型的 `input cycles`——Verilog-2001 下无类型输入只有 1 bit。

## 明确未覆盖

- SA-1、SuperFX、FDS。
- MMC1 连续 CPU cycle 过滤导致的软件可见 glitch。
- MMC3 的 MC-ACC 计数窗口、NEC alternate clocking、T9552 去混淆、MMC6（submapper 1）。
- MMC3 与 OAM DMA（$4014）的交互。
- four-screen 的 4 KiB nametable RAM 数据通路。
- 任何真实 ROM、test ROM、综合、时序或板级行为。
