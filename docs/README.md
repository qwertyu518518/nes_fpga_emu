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
| [`hdmi-tx.md`](modules/hdmi-tx.md) | `nes_video_hdmi` + `nes_hdmi_tx` + TMDS 编码器/串行器（Zynq 720×480p60 HDMI） |
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
| [`zynq-platform.md`](modules/zynq-platform.md) | `nes_zynq_clk` + `nes_zynq_top`（Zynq-7020，四时钟域） |

## 4. 事实、范围与证据的边界

- `docs/nes-study/` 与 `docs/hardware/` 是**背景阅读**，不是完成状态证明。
- 每个模块文档结尾的“明确未实现 / 未建模”是**该模块可宣称范围的上限**，不要把它读成“已支持”。
- 综合/时序/上板证据**按器件区分**：EP4CE10 上没有任何时序数字；Zynq 侧的测量与复现见 [`00-overview/risk-register.md`](00-overview/risk-register.md) 与 [`00-overview/vivado-runbook.md`](00-overview/vivado-runbook.md)。
- **以实际文件树与 [`modules/`](modules/) 为准。** 仓库根 `README.md` 的“当前阶段”是一份更细的逐模块状态摘要，但它可能滞后于代码（例如仍写着某些外设“没有被任何顶层实例化”，而它们已在 Zynq 平台里接线）。本文与 README 冲突时，以 RTL 文件树和各模块文档为准。

---

## 5. 全书总目录（主索引）

本节把 `docs/` 当成一部完整作品来编目：每个目录一句定位，每个文档一行说明；
阅读顺序沿用各目录自己的 `00-index.md`，见第 2 节的三条路线。
这不是替代上面的模块清单，而是给它补一张“整本书的地图”。

### 5.1 图与编号约定

- `docs/figures/` 下的 SVG 是**由 `tools/gen_figures.py` 从 RTL 生成的**，不是手绘；
  `\tools\gen_figures.ps1` 是 PowerShell 入口。重新生成：

  ```text
  .\tools\gen_figures.ps1            # 重新生成全部图
  .\tools\gen_figures.ps1 -Check     # 校验已是最新
  ```

- **编号按文档独立**：每张图只在它被嵌入的那一篇文档里按出现顺序记作“图 N”，
  跨文档不共享编号。这样新增图**不会改动任何已有文档里的编号引用**；本仓库既有的
  ASCII 时序图与表格不带编号，只有 `docs/modules/wm8960-i2c.md` 引用了数据手册的
  “图 37”，那是资料原图号，与本地图号不冲突。
- 每张图的事实来源（对应 `.v` 文件）与所在文档见 [`figures/README.md`](figures/README.md)，
  那里还记录了统一的视觉约定（配色、线型、图例）。

### 5.2 逐目录清单

#### `00-overview/`

项目约束与状态：为什么这样分层、接口合同、决策、验证计划、风险账本、工具链与 Vivado 复现手册。

| 文档 | 一句话 |
|---|---|
| [`00-overview/architecture.md`](00-overview/architecture.md) | 架构总览 |
| [`00-overview/cpu-contract.md`](00-overview/cpu-contract.md) | CPU 合同 |
| [`00-overview/decision-log.md`](00-overview/decision-log.md) | 决策记录 |
| [`00-overview/project-charter.md`](00-overview/project-charter.md) | 项目章程 |
| [`00-overview/risk-register.md`](00-overview/risk-register.md) | 风险登记册 |
| [`00-overview/toolchains.md`](00-overview/toolchains.md) | 两条综合工具链并排对照 |
| [`00-overview/verification-plan.md`](00-overview/verification-plan.md) | 验证计划 |
| [`00-overview/vivado-runbook.md`](00-overview/vivado-runbook.md) | Vivado 操作手册（怎么跑，怎么信那些数） |

#### `nes-study/`

NES/FC 本身怎么工作：整机、iNES 格式、CPU 总线、6502、PPU、APU、mapper，以及参考 C 模拟器怎么组织。

| 文档 | 一句话 |
|---|---|
| [`nes-study/00-index.md`](nes-study/00-index.md) | NES 软件学习文档总索引 |
| [`nes-study/01-nes-system.md`](nes-study/01-nes-system.md) | 01 NES 系统总览与计算机体系结构基础 |
| [`nes-study/02-cnes-architecture.md`](nes-study/02-cnes-architecture.md) | 02 cNES 的模块关系与启动流程 |
| [`nes-study/03-ines-format.md`](nes-study/03-ines-format.md) | 03 iNES、NES2、PRG 与 CHR 文件格式 |
| [`nes-study/04-cpu-bus.md`](nes-study/04-cpu-bus.md) | 04 CPU 总线、地址译码与 DMA 仲裁 |
| [`nes-study/05-6502.md`](nes-study/05-6502.md) | 05 6502 CPU：寄存器、寻址、周期、dummy access 与中断 |
| [`nes-study/06-ppu.md`](nes-study/06-ppu.md) | 06 PPU：v/t/x/w、图形取数、精灵、滚动与 NMI |
| [`nes-study/07-apu.md`](nes-study/07-apu.md) | 07 APU：五个通道、帧序列器、混音与 DMC 边界 |
| [`nes-study/08-mappers.md`](nes-study/08-mappers.md) | 08 Mapper 概念、地址窗口与常见实现 |
| [`nes-study/09-c-to-rtl.md`](nes-study/09-c-to-rtl.md) | 09 从 C 模拟器到 RTL 的映射方法 |
| [`nes-study/10-verification.md`](nes-study/10-verification.md) | 10 验证：从“能运行”到“能解释每个周期” |

#### `hardware/`

EP4CE10 开拓者板的板级事实与数字逻辑/时序基础：板卡、时钟复位 CDC、存储、VGA/LCD、TF/SD、SDRAM、音频、引脚、平台顶层，以及 Zynq PS/PL 的上板 bring-up 手册。

| 文档 | 一句话 |
|---|---|
| [`hardware/00-index.md`](hardware/00-index.md) | EP4CE10 开拓者板硬件学习文档 |
| [`hardware/01-ep4ce10-board.md`](hardware/01-ep4ce10-board.md) | 01 EP4CE10F17C8 开拓者板认识 |
| [`hardware/02-verilog-foundations.md`](hardware/02-verilog-foundations.md) | 02 Verilog 与数字电路学习路线 |
| [`hardware/03-clock-reset-cdc.md`](hardware/03-clock-reset-cdc.md) | 03 时钟、复位与 CDC |
| [`hardware/04-memory-and-fifo.md`](hardware/04-memory-and-fifo.md) | 04 片上存储、同步 RAM、FIFO 与跨时钟缓冲 |
| [`hardware/05-vga-lcd.md`](hardware/05-vga-lcd.md) | 05 VGA、RGB565 与 RGB LCD |
| [`hardware/06-tf-sd.md`](hardware/06-tf-sd.md) | 06 TF 卡 SPI、扇区与 FAT 边界 |
| [`hardware/07-sdram.md`](hardware/07-sdram.md) | 07 SDRAM 初始化、时序、容量与冲突 |
| [`hardware/08-wm8978-audio.md`](hardware/08-wm8978-audio.md) | 08 WM8978 音频：I2C、I2S、BCLK、LRC 与 MCLK |
| [`hardware/09-input-and-pins.md`](hardware/09-input-and-pins.md) | 09 输入、按键与 NES 手柄扩展 |
| [`hardware/10-board-validation.md`](hardware/10-board-validation.md) | 10 P0 板级验收实验 |
| [`hardware/11-portability.md`](hardware/11-portability.md) | 11 可移植性：从板级例程到 NES 项目 |
| [`hardware/12-ntsc-clock-and-pll.md`](hardware/12-ntsc-clock-and-pll.md) | 12 NTSC 与 VGA 时钟：从 50 MHz 到 NES 主时钟 |
| [`hardware/13-platform-top.md`](hardware/13-platform-top.md) | 13 平台顶层：软件 main / framebuffer / SDL 事件循环与硬件接线的逐条对应 |
| [`hardware/14-zynq-bringup-runbook.md`](hardware/14-zynq-bringup-runbook.md) | 14 Zynq 上板 bring-up 手册：四个产物的分阶段点亮顺序与症状归因 |

#### `walkthrough/`

面向零 Verilog 基础读者的逐模块源码精读教程，从语言打底到顶层集成。

| 文档 | 一句话 |
|---|---|
| [`walkthrough/00-index.md`](walkthrough/00-index.md) | 源码精读（小白教程）总目录 |
| [`walkthrough/01-verilog-basics.md`](walkthrough/01-verilog-basics.md) | 01 Verilog 基础：从 C 思维切到硬件思维 |
| [`walkthrough/02-project-conventions.md`](walkthrough/02-project-conventions.md) | 02 本项目代码的固定写法：学会这几种句式就能读懂全部模块 |
| [`walkthrough/10-mapper-nrom.md`](walkthrough/10-mapper-nrom.md) | 10 第一款模块精读：`nes_mapper_nrom.v` |
| [`walkthrough/11-alu-lut.md`](walkthrough/11-alu-lut.md) | 11 第二种纯组合模块：`nes_apu_length_lut.v` |
| [`walkthrough/12-vga-timing.md`](walkthrough/12-vga-timing.md) | 12 模块精读：`nes_vga_timing.v` —— 用计数器画出一整帧画面 |
| [`walkthrough/13-mapper-cnrom-uxrom.md`](walkthrough/13-mapper-cnrom-uxrom.md) | 13 第一个带寄存器的 mapper：`nes_mapper_cnrom.v` / `nes_mapper_uxrom.v` |
| [`walkthrough/20-controller.md`](walkthrough/20-controller.md) | 20 第一个时序模块精读：`nes_controller.v` |
| [`walkthrough/21-cdc-fifo.md`](walkthrough/21-cdc-fifo.md) | 21 逐行精读：`nes_cdc_fifo.v` |
| [`walkthrough/22-chr-fetch-unit.md`](walkthrough/22-chr-fetch-unit.md) | 22 状态机精读：`nes_chr_fetch_unit.v` |
| [`walkthrough/23-sprite-chr-fetch.md`](walkthrough/23-sprite-chr-fetch.md) | 23 状态机精读：`nes_sprite_chr_fetch.v` |
| [`walkthrough/24-oam-dma.md`](walkthrough/24-oam-dma.md) | 24 一个真正的总线主设备：`nes_oam_dma.v` |
| [`walkthrough/25-sd-spi-cmd.md`](walkthrough/25-sd-spi-cmd.md) | 25 串行协议发送器精读：`sd_spi_cmd.v`（SD/TF 卡的 SPI 命令帧 + CRC7） |
| [`walkthrough/26-i2s-shifter.md`](walkthrough/26-i2s-shifter.md) | 26 位串行器精读：`nes_i2s_shifter.v` |
| [`walkthrough/30-cpu-bus.md`](walkthrough/30-cpu-bus.md) | 30 中等规模精读：`nes_cpu_bus.v` 地址译码与等待态 |
| [`walkthrough/31-ines-parser.md`](walkthrough/31-ines-parser.md) | 31 按字节吃文件头：`ines_header_parser.v` |
| [`walkthrough/32-cart-rom.md`](walkthrough/32-cart-rom.md) | 32 卡带 ROM 进 bitstream：`nes_cart_rom.v` |
| [`walkthrough/33-mapper-dispatch.md`](walkthrough/33-mapper-dispatch.md) | 33 mapper 顶层：`nes_mapper.v` 组合分发 + 子模块例化 |
| [`walkthrough/34-mapper-mmc1.md`](walkthrough/34-mapper-mmc1.md) | 34 MMC1：一个地址写 5 次的串行移位 mapper |
| [`walkthrough/35-mapper-mmc3.md`](walkthrough/35-mapper-mmc3.md) | 35 精读 `nes_mapper_mmc3.v`：MMC3 的 bank 切换与扫描线 IRQ |
| [`walkthrough/36-line-buffer.md`](walkthrough/36-line-buffer.md) | 36 逐行精读：`nes_line_buffer_vga.v` —— 双 bank 乒乓的行缓冲 |
| [`walkthrough/37-video-scaler.md`](walkthrough/37-video-scaler.md) | 37 整帧缓冲参考模型精读：`nes_video_scaler.v` |
| [`walkthrough/38-video-800x480.md`](walkthrough/38-video-800x480.md) | 38 800×480 面板输出精读：`nes_video_800x480.v`（真双口 RAM 跨时钟域） |
| [`walkthrough/39-audio-i2s.md`](walkthrough/39-audio-i2s.md) | 39 组装层精读：`nes_audio_i2s.v` |
| [`walkthrough/40-wm8960-i2c.md`](walkthrough/40-wm8960-i2c.md) | 40 WM8960 立体声 codec 的 I2C 主控：`wm8960_i2c.v` |
| [`walkthrough/41-zynq-clk.md`](walkthrough/41-zynq-clk.md) | 41 时钟生成精读：`nes_zynq_clk.v` |
| [`walkthrough/42-hdmi-tx.md`](walkthrough/42-hdmi-tx.md) | 42 HDMI 发射通路精读：`nes_video_hdmi.v` + `nes_hdmi_tx.v`（720×480p60 与 TMDS） |
| [`walkthrough/50-cpu6502.md`](walkthrough/50-cpu6502.md) | 50 复杂核心精读：`nes_cpu6502.v` |
| [`walkthrough/51-ppu2c02.md`](walkthrough/51-ppu2c02.md) | 51 复杂核心精读：`nes_ppu2c02.v` |
| [`walkthrough/52-ppu-sprite.md`](walkthrough/52-ppu-sprite.md) | 52 精灵精读：`nes_ppu_sprite.v` |
| [`walkthrough/53-apu-channels.md`](walkthrough/53-apu-channels.md) | 53 三个方波类 APU 通道：`nes_apu_pulse.v` / `nes_apu_triangle.v` / `nes_apu… |
| [`walkthrough/54-apu-dmc.md`](walkthrough/54-apu-dmc.md) | 54 DMC 通道精读：`nes_apu_dmc.v` |
| [`walkthrough/55-apu2a03.md`](walkthrough/55-apu2a03.md) | 55 五通道 APU 顶层精读：`nes_apu2a03.v` |
| [`walkthrough/56-touch-input.md`](walkthrough/56-touch-input.md) | 56 触摸屏精读：`nes_touch_input.v`（电容屏 → NES 手柄） |
| [`walkthrough/60-system-early.md`](walkthrough/60-system-early.md) | 60 顶层集成第一课：`nes_system_v0.v` 与 `nes_system_v1.v` |
| [`walkthrough/61-system-mid.md`](walkthrough/61-system-mid.md) | 61 中间三代 System 顶层精读：`nes_system_v2.v` / `nes_system_v3.v` / `nes_sy… |
| [`walkthrough/62-system-mapper.md`](walkthrough/62-system-mapper.md) | 62 端到端系统精读：`nes_system_v5.v` 与 `nes_system_v6.v` |
| [`walkthrough/63-ep4ce10-top.md`](walkthrough/63-ep4ce10-top.md) | 63 EP4CE10 平台顶层精读：`nes_ep4ce10_top.v` + PLL 存根 + 引脚层 |
| [`walkthrough/64-zynq-top.md`](walkthrough/64-zynq-top.md) | 64 平台顶层精读：`nes_zynq_top.v`（多时钟域整机接线层） |

#### `modules/`

本项目每个 RTL 模块的接口合同、时序账、证据与“明确未实现”清单。

| 文档 | 一句话 |
|---|---|
| [`modules/apu-full.md`](modules/apu-full.md) | APU 完整实现：软件模拟器模型与硬件 RTL 的对应关系 |
| [`modules/apu-system.md`](modules/apu-system.md) | APU 与系统总线的接线：IRQ 注入、`$4000` 路由、采样输出 |
| [`modules/cart-rom.md`](modules/cart-rom.md) | 卡带 ROM（PRG + CHR）：把两个 `$readmemh` 数组落进 bitstream |
| [`modules/cdc-fifo.md`](modules/cdc-fifo.md) | 单读单写异步 FIFO（CDC）：格雷码指针如何把两个时钟域解耦 |
| [`modules/chr-fetch-feasibility.md`](modules/chr-fetch-feasibility.md) | CHR 取数可行性测量：单口外部 CHR 的 dot 预算与 attribute 陷阱 |
| [`modules/controller.md`](modules/controller.md) | 标准 NES 手柄（$4016 / $4017）：从 SDL 键盘事件到并联输入 + 串行移位器 |
| [`modules/cpu-bus.md`](modules/cpu-bus.md) | CPU 总线模块：软件 `switch(address)` 与硬件 ready/valid 的对应关系 |
| [`modules/hdmi-tx.md`](modules/hdmi-tx.md) | HDMI/DVI 发射子系统（`nes_video_hdmi` + `nes_hdmi_tx` + TMDS 编码器/串行器）：720×480p60、第二个 MMCM、缩放与 DDC 限制 |
| [`modules/i2s-audio.md`](modules/i2s-audio.md) | I2S 音频位串行器（`nes_i2s_shifter`）与组装层（`nes_audio_i2s`）：从 32 位立体声样点到 BCL… |
| [`modules/ines-loader.md`](modules/ines-loader.md) | iNES/NES2.0 头解析（`ines_header_parser`）：从软件 loader 的 `fread` 到硬件配置寄存器 |
| [`modules/line-buffer-vga.md`](modules/line-buffer-vga.md) | 视频行缓冲：软件 framebuffer `y++`/blit 与硬件双 bank 行乒乓的对应 |
| [`modules/mappers.md`](modules/mappers.md) | Mapper 模块：软件 C 模型到 RTL 的映射 |
| [`modules/oam-dma.md`](modules/oam-dma.md) | OAM DMA（$4014）：从软件模拟器的 DMA 调度到硬件 DMA 状态机 |
| [`modules/ppu-external-chr.md`](modules/ppu-external-chr.md) | PPU 外部 CHR：背景通路已接通并有像素级证据，精灵通路已接线并有像素级证据（覆盖仍有缺口），`$2007` 写通路已实现并有端到… |
| [`modules/ppu-sprites.md`](modules/ppu-sprites.md) | PPU 精灵：从软件模拟器模型到 RTL |
| [`modules/sd-spi-cmd.md`](modules/sd-spi-cmd.md) | SD/TF 卡 SPI 命令帧发送器（sd_spi_cmd.v）：从一条 CMD 到 15 字节帧 + CRC7 |
| [`modules/system-v0-v1.md`](modules/system-v0-v1.md) | 系统集成 v0 / v1：最小 CPU+PPU 集成，以及 APU 第一次接入 |
| [`modules/system-v2.md`](modules/system-v2.md) | 系统集成 v2：软件模拟器的 `switch` / host loop 在硬件上对应什么 |
| [`modules/system-v3.md`](modules/system-v3.md) | 系统集成 v3：DMA 仲裁点、`$2003`/`$2004` 端口同沿竞争与 OAM DMA |
| [`modules/system-v4.md`](modules/system-v4.md) | 系统集成 v4：把并联按钮接到 `$4016`/`$4017`，以及软件模拟器的键盘事件是怎么变成 8 个 bit 的 |
| [`modules/system-v5.md`](modules/system-v5.md) | 系统集成 v5：把 `nes_mapper` 接进系统，以及软件 mapper 的指针数组怎么变成硬件 bank 寄存器 |
| [`modules/system-v6.md`](modules/system-v6.md) | 系统集成 v6：把 PPU 的外部 CHR 读通路接到 mapper 的 bank 偏移输出上 |
| [`modules/touch-input.md`](modules/touch-input.md) | 电容触摸屏当 NES 手柄（GT9147 -> $4016）：从板厂寄存器图到触摸 dpad |
| [`modules/vga-timing.md`](modules/vga-timing.md) | VGA 时序发生器：软件 blit/窗口 offset 与硬件 DE 窗口的逐条对应 |
| [`modules/video-800x480.md`](modules/video-800x480.md) | 800×480 RGB LCD 视频输出：真双口 BRAM 跨域与 3:1 + 每 8 个多 1 的精确缩放 |
| [`modules/video-scaler.md`](modules/video-scaler.md) | 视频 scaler：软件 framebuffer / SDL blit 与硬件 frame buffer 的对应 |
| [`modules/wm8960-i2c.md`](modules/wm8960-i2c.md) | WM8960 立体声 codec 的 I2C 主控：从开漏总线到 15 项上电寄存器表 |
| [`modules/zynq-platform.md`](modules/zynq-platform.md) | Zynq-7020 平台层（`nes_zynq_clk` + `nes_zynq_top`）：从 50 MHz 板载晶振到三条跨域边界 |

#### `tools/`

工具文档：主机侧把 iNES 转成可进 bitstream 的 hex。

| 文档 | 一句话 |
|---|---|
| [`tools/nes2hex.md`](tools/nes2hex.md) | nes2hex：把 iNES `.nes` 转成 bitstream 内嵌的两个 hex |

#### 根目录散篇

`docs/` 顶层不与上述目录同类的单篇文档。

| 文档 | 一句话 |
|---|---|
| [`README.md`](README.md) | 文档总索引与阅读路线 |
| [`ppu_chr_external_write.md`](ppu_chr_external_write.md) | 外部 CHR 的 `$2007` 写通路：已实现并有端到端证据 |

#### `figures/`

由 RTL 生成、嵌入各文档的工程示意图（SVG）。图目录与来源见
[`figures/README.md`](figures/README.md)。
