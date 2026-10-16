# 文档总索引与阅读路线

本仓库的文档分五套，各有不同用途。本文是入口，帮你在读之前先选对**你此刻需要哪一套**。

> 术语：`[源码观察]` 指固定提交的参考 C 代码里的写法；`[NESdev 真值]` 指 NES 硬件/测试 ROM 约束的可观察行为；`[RTL 建议]` 指本项目的实现取舍。三者不可互换。

## 1. 五套文档各管什么

| 目录 | 回答的问题 | 读者 |
|---|---|---|
| [`00-overview/`](00-overview/) | 项目为什么这样分层、接口合同、决策、验证计划与风险账本 | 想理解项目约束与状态 |
| [`nes-study/`](nes-study/) | NES/FC 本身怎么工作，参考 C 模拟器怎么组织 | 想打 NES 基础 |
| [`hardware/`](hardware/) | EP4CE10 开拓者板的板级事实与数字逻辑/时序基础 | 想把 RTL 落到板子上 |
| [`walkthrough/`](walkthrough/) | **从 Verilog 零基础开始，逐个模块对照源码逐行精读** | **完全新手 / 想逐行读懂代码** |
| [`modules/`](modules/) | **本项目每个 RTL 模块**的接口合同、时序账与证据 | 想读懂/修改具体模块 |

此外：`tools/nes2hex.md` 讲主机侧把 iNES 转成可进 bitstream 的 hex；`tb/` 下各子目录的 `README.md` 是逐 testbench 的验证教学文档。

## 2. 三条可选阅读路线

### 2.1 完全新手：先建立概念，再看本项目

0. **连 Verilog 都还没学过**：直接从 [`walkthrough/00-index.md`](walkthrough/00-index.md) 起步，先读 [`01-verilog-basics.md`](walkthrough/01-verilog-basics.md) 与 [`02-project-conventions.md`](walkthrough/02-project-conventions.md)，再按它给的顺序逐个模块精读源码。
1. [`nes-study/00-index.md`](nes-study/00-index.md) → [`01-nes-system.md`](nes-study/01-nes-system.md)：整机与时间尺度。
2. [`nes-study/03-ines-format.md`](nes-study/03-ines-format.md) → [`04-cpu-bus.md`](nes-study/04-cpu-bus.md) → [`05-6502.md`](nes-study/05-6502.md)：ROM → 地址 → 指令。
3. [`nes-study/06-ppu.md`](nes-study/06-ppu.md) → [`07-apu.md`](nes-study/07-apu.md)：视频与音频。
4. [`hardware/00-index.md`](hardware/00-index.md) → [`02-verilog-foundations.md`](hardware/02-verilog-foundations.md) → [`03-clock-reset-cdc.md`](hardware/03-clock-reset-cdc.md)：从 C 思维切到硬件思维。
5. 再按需读 `modules/`。

### 2.2 想读懂/改某个 RTL 模块：直接看 `modules/`

先读 [`00-overview/architecture.md`](00-overview/architecture.md) 第 2 节拿到当前模块清单，再进对应文件。模块文档的固定结构是：教学问题 → C 参考观察 → NESdev 真值 → RTL 接口合同 → 时序/周期账 → **明确未实现**。

### 2.3 想复现证据：`tools/sim_all.ps1` + `tb/`

`.\tools\sim_all.ps1 -Mode all` 是权威回归门禁；`-Mode <组名|目标 id>` 可跑子集。每个模块文档都会给出它对应的目标 id。

## 3. `modules/` 全清单

### 3.1 核心（CPU / 总线 / 存储）

| 文档 | 模块 |
|---|---|
| [`cpu-bus.md`](modules/cpu-bus.md) | `nes_cpu_bus`（地址译码、等待态、owner/hold、DMA 端口） |
| [`00-overview/cpu-contract.md`](00-overview/cpu-contract.md) | `nes_cpu6502` 的对外接口合同（CPU 的 6502 概念见 `nes-study/05-6502.md`） |
| [`cart-rom.md`](modules/cart-rom.md) | `nes_cart_rom`（BRAM 卡带 PRG/CHR + `$readmemh`） |
| [`ines-loader.md`](modules/ines-loader.md) | `ines_header_parser`（iNES/NES2.0 头解析） |
| [`mappers.md`](modules/mappers.md) | `nes_mapper` 与 NROM/UxROM/CNROM/MMC1/MMC3 |

### 3.2 PPU / APU

| 文档 | 模块 |
|---|---|
| [`ppu-external-chr.md`](modules/ppu-external-chr.md) | `nes_ppu2c02` 外部 CHR 通路（背景/精灵取数） |
| [`ppu-sprites.md`](modules/ppu-sprites.md) | `nes_ppu_sprite` |
| [`oam-dma.md`](modules/oam-dma.md) | `nes_oam_dma` |
| [`chr-fetch-feasibility.md`](modules/chr-fetch-feasibility.md) | `nes_chr_fetch_unit` 的可行性测量 |
| [`../ppu_chr_external_write.md`](ppu_chr_external_write.md) | `$2007` 对外部 CHR 的读写通路 |
| [`apu-full.md`](modules/apu-full.md) | `nes_apu2a03` 五通道全量 |
| [`apu-system.md`](modules/apu-system.md) | APU 与 System 的接线（v1 起） |

### 3.3 视频 / 输入

| 文档 | 模块 |
|---|---|
| [`video-scaler.md`](modules/video-scaler.md) | `nes_video_scaler`（整帧参考模型） |
| [`line-buffer-vga.md`](modules/line-buffer-vga.md) | `nes_line_buffer_vga`（EP4CE10 行缓冲） |
| [`vga-timing.md`](modules/vga-timing.md) | `nes_vga_timing`（640×480 时序） |
| [`video-800x480.md`](modules/video-800x480.md) | `nes_video_800x480`（Zynq 800×480 双时钟） |
| [`controller.md`](modules/controller.md) | `nes_controller`（$4016/$4017） |
| [`touch-input.md`](modules/touch-input.md) | `nes_touch_input`（GT9147 电容触摸） |

### 3.4 外设（音频 / 存储 / CDC）

| 文档 | 模块 |
|---|---|
| [`cdc-fifo.md`](modules/cdc-fifo.md) | `nes_cdc_fifo`（格雷码异步 FIFO） |
| [`i2s-audio.md`](modules/i2s-audio.md) | `nes_i2s_shifter` + `nes_audio_i2s` |
| [`wm8960-i2c.md`](modules/wm8960-i2c.md) | `wm8960_i2c`（Zynq 板 codec；注意与 EP4CE10 的 WM8978 不同） |
| [`sd-spi-cmd.md`](modules/sd-spi-cmd.md) | `sd_spi_cmd`（SPI 命令帧 + CRC7） |

### 3.5 System 顶层（演进链）

| 文档 | 版本 |
|---|---|
| [`system-v0-v1.md`](modules/system-v0-v1.md) | `nes_system_v0`（最小 CPU+PPU）、`nes_system_v1`（接入 APU） |
| [`system-v2.md`](modules/system-v2.md) | 改用 `nes_cpu_bus` 真等待态、内接 sprite |
| [`system-v3.md`](modules/system-v3.md) | OAM DMA 与 DMA 仲裁 |
| [`system-v4.md`](modules/system-v4.md) | controller 接入 |
| [`system-v5.md`](modules/system-v5.md) | mapper 接入（PRG bank / mapper IRQ） |
| [`system-v6.md`](modules/system-v6.md) | PPU 外部 CHR（读/写/取数仲裁） |

### 3.6 平台层

| 文档 | 平台 |
|---|---|
| [`hardware/13-platform-top.md`](hardware/13-platform-top.md) | `nes_ep4ce10_top`（EP4CE10，VGA 行缓冲链路） |
| [`zynq-platform.md`](modules/zynq-platform.md) | `nes_zynq_clk` + `nes_zynq_top`（Zynq-7020，三时钟域） |

## 4. 事实、范围与证据的边界

- `docs/nes-study/` 与 `docs/hardware/` 是**背景阅读**，不是完成状态证明。
- 每个模块文档结尾的“明确未实现 / 未建模”是**该模块可宣称范围的上限**，不要把它读成“已支持”。
- 综合/时序/上板证据**按器件区分**：EP4CE10 上没有任何时序数字；Zynq 侧的测量与复现见 [`00-overview/risk-register.md`](00-overview/risk-register.md) 与 [`00-overview/vivado-runbook.md`](00-overview/vivado-runbook.md)。
- **以实际文件树与 [`modules/`](modules/) 为准。** 仓库根 `README.md` 的“当前阶段”是一份更细的逐模块状态摘要，但它可能滞后于代码（例如仍写着某些外设“没有被任何顶层实例化”，而它们已在 Zynq 平台里接线）。本文与 README 冲突时，以 RTL 文件树和各模块文档为准。
