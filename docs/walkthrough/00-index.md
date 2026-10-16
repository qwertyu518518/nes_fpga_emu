# 源码精读（小白教程）总目录

本目录是**面向零 Verilog 基础读者**的逐行代码精读教程。它和 [`../modules/`](../modules/) 的分工是：

| 目录 | 讲什么 | 前提 |
|---|---|---|
| [`../modules/`](../modules/) | 模块的**接口合同、时序账、证据、未实现清单** | 已经会读 Verilog |
| **`walkthrough/`（本目录）** | **Verilog 语法 + 本项目代码逐行怎么读** | 会写一点 C 即可 |

读法建议：**先按本目录的顺序读**，建立语言和代码直觉；再回 `../modules/` 看合同与证据。两边会互相链接。

## 1. 阅读顺序（由浅入深）

### ① 语言打底

| 文档 | 讲什么 |
|---|---|
| [`01-verilog-basics.md`](01-verilog-basics.md) | Verilog 基础：从 C 思维切到硬件思维（组合/时序、`wire`/`reg`、`<=`/`=`、复位、`ce`、位运算、testbench、8 个坑） |
| [`02-project-conventions.md`](02-project-conventions.md) | 本项目的固定句式与读码方法（`_q`/`_next`、状态机骨架、命名连接、怎么跑 `sim_all.ps1`） |

### ② 组合逻辑入门（没有时钟、没有状态）

| 文档 | 精读模块 |
|---|---|
| [`10-mapper-nrom.md`](10-mapper-nrom.md) | `nes_mapper_nrom.v`：一行代码讲清"地址映射"（**本系列的样式范本**） |
| [`11-alu-lut.md`](11-alu-lut.md) | `nes_apu_length_lut.v`：`case` 查表 |
| [`12-vga-timing.md`](12-vga-timing.md) | `nes_vga_timing.v`：计数器画出一帧画面 |
| [`13-mapper-cnrom-uxrom.md`](13-mapper-cnrom-uxrom.md) | `nes_mapper_cnrom.v` / `nes_mapper_uxrom.v`：第一个寄存器状态与 bus conflict |

### ③ 时序逻辑与状态机入门（有时钟、有状态）

| 文档 | 精读模块 |
|---|---|
| [`20-controller.md`](20-controller.md) | `nes_controller.v`：移位寄存器 + 电平/脉冲 |
| [`21-cdc-fifo.md`](21-cdc-fifo.md) | `nes_cdc_fifo.v`：跨时钟域的经典结构（格雷码指针） |
| [`22-chr-fetch-unit.md`](22-chr-fetch-unit.md) | `nes_chr_fetch_unit.v`：一个 6 态 FSM |
| [`23-sprite-chr-fetch.md`](23-sprite-chr-fetch.md) | `nes_sprite_chr_fetch.v`：把 16 个字节排好队 |
| [`24-oam-dma.md`](24-oam-dma.md) | `nes_oam_dma.v`：256 字节搬运状态机 |
| [`25-sd-spi-cmd.md`](25-sd-spi-cmd.md) | `sd_spi_cmd.v`：串行协议发送器（含 CRC7） |
| [`26-i2s-shifter.md`](26-i2s-shifter.md) | `nes_i2s_shifter.v`：位串行器 |

### ④ 中等规模

| 文档 | 精读模块 |
|---|---|
| [`30-cpu-bus.md`](30-cpu-bus.md) | `nes_cpu_bus.v`：地址译码与等待态 |
| [`31-ines-parser.md`](31-ines-parser.md) | `ines_header_parser.v`：按字节吃文件头 |
| [`32-cart-rom.md`](32-cart-rom.md) | `nes_cart_rom.v`：BRAM 初始化与读延迟 |
| [`33-mapper-dispatch.md`](33-mapper-dispatch.md) | `nes_mapper.v`：组合分发 + 子模块例化 |
| [`34-mapper-mmc1.md`](34-mapper-mmc1.md) | `nes_mapper_mmc1.v`：串行移位寄存器写协议 |
| [`35-mapper-mmc3.md`](35-mapper-mmc3.md) | `nes_mapper_mmc3.v`：bank 切换与 A12 IRQ |
| [`36-line-buffer.md`](36-line-buffer.md) | `nes_line_buffer_vga.v`：双 bank 乒乓 |
| [`37-video-scaler.md`](37-video-scaler.md) | `nes_video_scaler.v`：整帧缓冲参考模型 |
| [`38-video-800x480.md`](38-video-800x480.md) | `nes_video_800x480.v`：真双口 RAM 跨时钟域 |
| [`39-audio-i2s.md`](39-audio-i2s.md) | `nes_audio_i2s.v`：FIFO + 位串行器的组装 |
| [`40-wm8960-i2c.md`](40-wm8960-i2c.md) | `wm8960_i2c.v`：I2C 主控状态机 |
| [`41-zynq-clk.md`](41-zynq-clk.md) | `nes_zynq_clk.v`：MMCM 时钟生成 |

### ⑤ 复杂核心

| 文档 | 精读模块 |
|---|---|
| [`50-cpu6502.md`](50-cpu6502.md) | `nes_cpu6502.v`：6502 指令状态机（骨架精读） |
| [`51-ppu2c02.md`](51-ppu2c02.md) | `nes_ppu2c02.v`：PPU 像素流水线（骨架精读） |
| [`52-ppu-sprite.md`](52-ppu-sprite.md) | `nes_ppu_sprite.v`：64 个精灵的优先级 |
| [`53-apu-channels.md`](53-apu-channels.md) | `nes_apu_pulse/triangle/noise.v` |
| [`54-apu-dmc.md`](54-apu-dmc.md) | `nes_apu_dmc.v`：DMC 与 DMA 请求 |
| [`55-apu2a03.md`](55-apu2a03.md) | `nes_apu2a03.v`：五通道顶层与 frame sequencer |
| [`56-touch-input.md`](56-touch-input.md) | `nes_touch_input.v`：触摸屏到 NES 手柄 |

### ⑥ 顶层集成

| 文档 | 精读模块 |
|---|---|
| [`60-system-early.md`](60-system-early.md) | `nes_system_v0.v` / `nes_system_v1.v` |
| [`61-system-mid.md`](61-system-mid.md) | `nes_system_v2.v` / `v3.v` / `v4.v` |
| [`62-system-mapper.md`](62-system-mapper.md) | `nes_system_v5.v` / `v6.v` |
| [`63-ep4ce10-top.md`](63-ep4ce10-top.md) | `nes_ep4ce10_top.v` + PLL stub + 引脚层 |
| [`64-zynq-top.md`](64-zynq-top.md) | `nes_zynq_top.v`：多时钟域整机 |

## 2. 每篇的统一结构

每篇模块精读都按同一骨架写，方便对照：

1. **一句话定位 + 上下游图**：这个模块在系统里干什么、谁给它输入、它给谁输出。
2. **全文代码**（大模块只贴骨架）：先把代码摆出来。
3. **逐段精读**：把代码翻译成人话。
4. **端口表**：每个端口的位宽与含义。
5. **代入数值走一遍**：用具体数字把逻辑跑一遍（最能验证"你真的懂了"）。
6. **常见疑问**。
7. **带走的三件事** + 下一篇链接。

## 3. 学完应该能做到

- 看到一个 `.v` 文件，能立刻分清：哪些是**端口**、哪些是**组合逻辑**（`always @*` / `assign`）、哪些是**寄存器**（`always @(posedge clk)`）。
- 能读懂本项目最常出现的三种句式：`wire x_next = ...; always (...) x_q <= x_next;`、`case (state)`、`{a, b, c[3:0]}`。
- 能回答：为什么时序块里用 `<=` 而不是 `=`？`ce` 是什么、为什么不用门控时钟？复位为什么分同步/异步？
- 能用 `iverilog` + `vvp` 跑一个模块的 testbench，并看懂 `$fatal` 报错。

## 4. 统一记号（全书通用）

- `$` 前缀表示十六进制，例如 `$4016` 是一个 NES 地址。
- 代码里的 `8'h81` 表示 8 位十六进制 `0x81`；`4'b1010` 表示 4 位二进制；`6'd33` 表示 6 位十进制 `33`。**宽的写在前面，`'` 后面跟着进制字母**。
- `[7:0]` 是位宽 8 的向量（bit7 是最高位）。
- 一拍 = 一个时钟上升沿（`posedge clk`）。
- `ce` = clock enable（时钟使能），高有效；`ce=0` 时相关寄存器"冻结"。
- 提到某个模块时给的不是"大概意思"，而是**这份代码实际做的事**；每个结论都能在文件里找到对应行。

## 5. 环境：怎么把代码跑起来

教程里不要求你先装 FPGA 工具，只要 Icarus Verilog：

```text
# 编译 + 运行一个 testbench（以 vga 时序为例）
iverilog -g2012 -s tb_nes_vga_timing -o tb.vvp ^
  rtl/nes_core/video/nes_vga_timing.v tb/video/tb_nes_vga_timing.v
vvp tb.vvp
```

本仓库还提供了统一入口：

```text
.\tools\sim_all.ps1 -Mode vga-timing-tb   # 只跑一个目标
.\tools\sim_all.ps1 -Mode all             # 跑全部回归（慢）
```

每个模块的说明都会给出它对应的目标 id。

## 6. 注意：本目录只讲解，不替代合同

本目录为了讲清楚，会把代码"翻译成人话"，可能出现比 `../modules/` 更口语的简化说法。**凡是要写进设计、要下判断的地方，一律以 `../modules/`、[`../00-overview/`](../00-overview/) 和 RTL 源码为准。**
