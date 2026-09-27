# 13 平台顶层：软件 main / framebuffer / SDL 事件循环与硬件接线的逐条对应

## 0. 本章要回答的问题

前面各章分别讲清了时钟（`12-ntsc-clock-and-pll.md`）、视频（`05-vga-lcd.md`）、输入（`09-input-and-pins.md`）、音频（`08-wm8978-audio.md`）。本章把第一根线接起来：`rtl/platform/ep4ce10/nes_ep4ce10_top.v` 把一个 vendor 无关的 NES 核、两个时钟域、一条视频链、一路音频 sample 和四路带消抖的按键合成一个可综合的顶层。

本章要逐条回答的问题只有一个：**软件模拟器里的哪一段，在硬件上对应哪几根线和哪个时钟域。** 凡是软件里"免费"的东西（事件循环同线程、framebuffer 顺序遍历、SDL 已经给你消好抖的布尔数组），硬件上都必须显式补上；凡是硬件上多出来的东西（异步时钟域、背压、电平极性），软件里都不存在，因此不能靠"软件跑通了"推断硬件也对。

**本章不含**：Quartus 工程、`.qsf`/`.sdc`、PLL IP 参数值、TF/SDRAM/WM8978 驱动。引脚约束待补，见第 6 节。

## 1. 三个时钟和它们的关系

| 顶层端口 | 频率 | 谁提供 | 驱动什么 |
|---|---:|---|---|
| `clk_sys` | 50 MHz | 板载晶振 `PIN_E1` | 只用于按键两级同步 + 16 ms 消抖计数 |
| `clk_ntsc` | 21.477272 MHz | EP4CE10 `altpll`（**本模块不含**） | NES 域全部逻辑 + 行缓冲写口 + PPU dot 使能 |
| `clk_vga` | 25 MHz | EP4CE10 `altpll`（**本模块不含**） | VGA 800×525 时序 + 行缓冲读口 + RGB 输出 |

三个必须记住的数字关系：

1. `clk_ntsc` 是 **NTSC 主时钟**（副载波 3.579545 MHz × 6），不是 CPU 时钟。核内 `div_phase` 再分出 `ce_cpu = /12`（**1.789773 MHz，周期 558.7 ns**）和 `ce_ppu = /4`（5.369318 MHz）。**1.789773 MHz 是 CPU 速率，不是本顶层的时钟输入**；`tb/platform/tb_nes_ep4ce10_top.v` 用 23.275 ns 半周期驱动 `clk_ntsc`，这才是 NES 域的时间基。
2. 25 MHz 与 5.369318 MHz 之间没有有理关系（25 ÷ 5.369318 ≈ 4.6557），所以两个域不能靠"同一个时钟加使能"耦合，只能靠行缓冲在数据层面解耦（`docs/modules/line-buffer-vga.md`）。
3. `clk_ntsc` 与 `clk_vga` 是**真正异步**的两个域。50 MHz 与 21.48 MHz 之间也没有整数关系，因此按键消抖不能放在 NES 域里做。

`clk_ntsc` / `clk_vga` 由 `altpll` IP 在 Quartus 中生成后从顶层引进来；频率误差、VCO 范围、每路分频必须由 MegaWizard 与 TimeQuest 确认，候选值与误差分析见 `12-ntsc-clock-and-pll.md` 第 3 节。`rtl/platform/ep4ce10/nes_ep4ce10_pll_stub.v` 只是端口占位，**不参与综合，也没有 `locked` 之外的任何功能**。

## 2. 时钟域与复位分发

```
clk_sys    50MHz ──┬── key_meta/key_sync (2 级)
                   └── 消抖计数器 (16 ms = 800000 拍)
                              │ key_stable_q (4 bit 同时翻转的电平)
                              ▼
clk_ntsc  21.48MHz ─┬── btn_meta/btn_sync (2 级) ── buttons1[3:0]
                    ├── nes_system_v4 (CPU/PPU/APU/bus/controller)
                    ├── ppu_ce_div (4 分频 = ce_ppu)
                    └── 行缓冲写口 + line_ready_toggle
clk_vga     25MHz  ─┬── 行缓冲读口 (toggle 2 级同步 + 差分消费)
                    └── nes_vga_timing (自由运行光栅)
```

复位规则（`docs/hardware/03-clock-reset-cdc.md` 第 2 节）：

- `reset_n` 是板级低有效输入，**异步断言**。
- 三个域各自一个 2 位同步器，**同步释放**：`reset_n` 低直接把 `rst_*_q` 置 `2'b11`（本地复位高有效），`reset_n` 释放后 `0` 从低位逐拍移入，第 2 拍后 `rst_*_q[1]` 变 0。
- 三个域的复位寄存器**互不驱动**。NTSC 域的复位不能接到 VGA 域的时序发生器上。
- 顶层内部的 `rst_sys` / `rst_ntsc` / `rst_vga` 是**高有效**（1 = 处于复位），分别喂给 `nes_system_v4.reset`、行缓冲 `wr_reset` / `rd_reset`、`nes_vga_timing.reset`。

## 3. 软件结构与硬件接线的逐条对应

下表是本章的核心。左列是软件模拟器（cNES 结构，`docs/nes-study/02-cnes-architecture.md`、`docs/modules/*.md`）里做的事，右列是本顶层里对应的 RTL。

| 软件侧 | 软件为什么"免费" | 硬件侧 | 本顶层里的实现 | 缺了会怎样 |
|---|---|---|---|---|
| `do_window_loop()` / SDL 事件循环与模拟线程**同进程**（cNES 甚至跨线程但接口里没有显式同步） | 单一地址空间、单一线程序 | NTSC 域与 VGA 域**真正异步** | 行缓冲双 bank 乒乓，`line_ready_toggle` 1 bit 过 2 级同步器后差分消费 | 读到写了一半的行 → 撕裂条纹 |
| `set_pixel(x, y, rgb)` 顺序写 `framebuffer[y][x]` | 访存顺序就是显示顺序 | PPU 像素**流式**产生，`pixel_valid`/`pixel_x`/`pixel_index` 每 dot 变一次 | 送行缓冲写口，`wr_ce` = PPU dot 使能 | 写口多写或漏写 → 行缓冲内容错位 |
| framebuffer 一次 blit / `SDL_UpdateTexture` 一次提交 | 整帧已就绪，blit 是纯内存遍历 | 只有**一行**的缓冲（2 × 256 × 16 bit = 1 KiB） | 行缓冲每行写完翻转一次 `wr_bank` | 显存不够（EP4CE10 片上存储约 51.75 KiB，整帧 256×240×16 bit 要 120 KiB） |
| `SDL_RenderCopy(..., NULL, NULL)` 的整数倍放大 / `WINDOW_SCALE` | blit 循环里写两遍 | 2× 水平 + 2× 垂直放大 | `REPEAT_LINE = 1`，一行读两遍（512 拍），240 源行 → 480 显示行 | 分辨率不对 |
| 软件 blit 的 `continue`（裁掉上下边缘） | 循环里的条件判断 | DE 窗口常数 `DE_X0/DE_X1/DE_Y0/DE_Y1` | `nes_vga_timing` 默认 64/576/0/480，即 512 有效像素居中 | 有效区偏移，图像不在屏幕中心 |
| `SDL_RenderPresent()`（帧末一次） | 一次性提交，无撕裂 | 自由运行的 800×525 计数器 + HS/VS/DE | `nes_vga_timing`，帧周期 420000 拍 @25 MHz | 显示器不同步 |
| 帧末 blit 的遍历顺序（左上到右下） | 代码写死的循环 | 读端在**收到 toggle 的那一刻**才开始读，`line_read_start` 重新对齐 x=0 | 行缓冲读端 `line_read_start` 脉冲喂给时序发生器 | 滚动/撕裂，行首对不齐 |
| `SDL_GetKeyboardState()` 给出 8 个已消抖的布尔值 | 宿主 OS 已经做过消抖 | 机械按键有 5~20 ms 抖动，且在 50 MHz 异步域 | 2 级同步 + 16 ms 候选电平计数 | 一次按下被读成多次 |
| `button_states[4]` 数组直接喂给 CPU | 数组和 MMIO 在同一地址空间 | 4 bit 电平要跨 50 MHz → 21.48 MHz 域 | 消抖后再过 2 级同步器，取反后填 `buttons1[3:0]` | 亚稳态 → 随机按键 |
| `controller_poll()` 在 `$4016` 读时重新采样 SDL | 读 MMIO 就是读数组 | NES 手柄是 `$4016` strobe + 8 次串行读 | `nes_system_v4` 内的 `nes_controller` + `buttons1`/`buttons2` | 位序或第 9 次读错 |
| APU 每个 CPU 周期算一个混音样点，`ce_sample` 恒 1 | 直接把数组 push 进 SDL 队列 | `audio_sample_valid` 是 1 拍宽、**1.789773 MHz** 的 strobe，**不是音频采样率** | 原样送到 `audio_valid` / `audio_left` 顶层端口 | 以为它能直接驱动 WM8978 |
| `SDL_QueueAudio` + 宿主声卡重采样到 44.1/48 kHz | 宿主音频栈负责 | 需要异步 FIFO 到 MCLK/BCLK 域 | **本顶层不做**，只留端口 | 音画随时间相对漂移 |
| `main()` 里顺序做 reset → 载入 ROM → 主循环 | 单线程顺序即时间顺序 | 三个域各自复位，NES 核自由运行 | 复位分发见第 2 节 | 一域先跑起来读到未初始化的另一域 |

## 4. 视频链的三个接口

```
PPU (clk_ntsc)                 行缓冲                        VGA 时序 (clk_vga)
pixel_valid ─┐
pixel_x     ─┼─> wr_ce/pixel_valid/wr_x/wr_index  ─>  read_rgb565  ─> px_rgb565
pixel_index ┘         │                                    ▲
                     └─> line_ready_toggle ──2 级同步──> line_read_start / frame_line_valid
                                                                          │
                                                          hsync/vsync/de/rgb565 ┘
```

三个容易写错、并且被 `tb/platform/tb_nes_ep4ce10_top.v` 断言钉住的点：

1. **`wr_ce` 必须是 PPU dot 使能（4 拍一次），不能常 1。** `pixel_valid` 和 `pixel_x` 是 PPU 的组合输出，`dot` 在 4 拍内保持不变。常 1 会让 `x = 255` 被写 4 次，`line_ready_toggle` 翻转 4 次后回到原值，读端**永远看不到"新的一行"**，画面全黑。
2. **写使能的相位必须与核内 `div_phase` 一致。** 两者由同一个 `rst_ntsc` 复位，从同一条时钟沿开始计数。若相差 1~3 拍，被漏掉的恰好是每行第一个 dot，行缓冲的 `x = 0` 单元永远不被写，读端第一列会输出 x。TB 用"`pixel_x` 严格按 0..255 递增、每行 341 个 dot"两条断言把相位钉住。
3. **跨域只有 1 bit。** `pixel_x` / `pixel_index` 留在双口 RAM 里不过同步器；`pixel_valid`、`line_done`、`frame_done` 是脉冲或与 toggle 相对有序的信号，**不用它们判断读起始**，读起始一律用 `line_ready_toggle` 的边沿（`12-ntsc-clock-and-pll.md` 第 5.1 节）。

写口速率约束：写端 5.369318 MHz，读端把一行读 2 遍需要 21.48 MHz，25 MHz 有 16% 余量。行缓冲没有背压，写端长期领先时整行被静默跳过（`docs/modules/line-buffer-vga.md` 第 5.5 节）。

## 5. 音频：端口在这里，接法不在这里

顶层只做一件事：把 `audio_sample_valid` 和 `audio_sample_left` 原样送出。

- `audio_valid` 是 `clk_ntsc` 域**宽度 1 拍**的 strobe，速率 = `ce_cpu` = **1.789773 MHz**。它**不是** 44.1 kHz 或 48 kHz。
- `audio_left` 是**无符号**幅度（`docs/modules/apu-full.md` 第 4 节），外部音频链自己做偏置。
- 接 WM8978 需要：NTSC 域 → MCLK 域的异步 FIFO（格雷码指针 + 水位背压）→ 12.288 MHz MCLK 域重采样到标准采样率 → BCLK/LRC 域串出。**重采样时钟必须来自 NES 域**，否则音画会随时间相对漂移（`12-ntsc-clock-and-pll.md` 第 2 节末）。这套接法属于后续工作，`docs/hardware/08-wm8978-audio.md` 有完整清单。

## 6. 还没做的事

| 项目 | 状态 | 备注 |
|---|---|---|
| `altpll` IP | **未生成** | 需在 Quartus 中按 `12-ntsc-clock-and-pll.md` 第 3.3 节生成；本仓库只有 `nes_ep4ce10_pll_stub.v` 占位 |
| `.qsf` 引脚分配 | **待补** | `clk_sys` → `PIN_E1`，`reset_n` → `PIN_M1`，4 个按键与 VGA HS/VS/DE/R/G/B 引脚需查 `01-ep4ce10-board.md` 与正点原子 IO 表后填入 |
| `.sdc` 时序约束 | **待补** | 50 MHz 输入 `create_clock`、`derive_pll_clocks`、`set_clock_groups -asynchronous` 分组 NTSC/VGA/BCLK、`ce_ppu` 控制的寄存器按 4 拍多周期约束（否则 STA 会按 46.55 ns 要求一条实际有 186 ns 余量的路径） |
| TimeQuest 报告 | **未测量** | R-03 / R-05 未关闭；PPU 关键路径 fmax 未测 |
| TF 卡 / SDRAM | 未实现 | 载带与存档需要，本顶层不含 |
| WM8978 驱动 | 未实现 | 见第 5 节 |
| 完整 8 位手柄 | 未实现 | 板载 4 键只够 P0；`09-input-and-pins.md` 第 5 节 |
| `tools/sim_all.ps1` 集成 | 未加入 | 本仓库的仿真脚本目前没有 `platform` 分组，需要时自行添加 |

## 7. 验证

`tb/platform/tb_nes_ep4ce10_top.v` 用两个理想时钟（`clk_ntsc` 23.275 ns 半周期 = 21.477272 MHz，`clk_vga` 20 ns = 25 MHz，`clk_sys` 10 ns = 50 MHz）跑 3 个 NES 帧，断言：

| 断言 | 内容 |
|---|---|
| VGA 时序 | `hsync`/`vsync`/`de` 逐像素与 800×525 模型一致；每行 96 个 hsync 周期；可见行 512 个 de 周期、消隐行 0 个；每帧 3 行 vsync；帧周期 420000 拍 |
| PPU → 行缓冲 | `ppu_ce` 每 dot 采一次；`pixel_x` 严格 0..255 递增；每行 341 个 dot，帧边界 23×341（240..261 消隐行不产生可见像素）；`line_done` 在 x=255 后一拍拉高；`line_ready_toggle` 每写一行翻一次 |
| 像素 | 调色板索引非 0 的样点存在（证明 PPU 颜色真的进了行缓冲）；`vga_r`/`vga_g`/`vga_b` 出现非零 |
| 按键 | 消抖电平不得早于 `DEBOUNCE_CYCLES` 个 `clk_sys` 变化；变化后 4 个 `clk_ntsc` 内出现在 `buttons1[3:0]`；`buttons1[7:4]` 恒 1；`buttons2` 恒 `0xFF` |
| 音频 | `audio_valid` 是 1 拍宽 strobe；复位期间为 0；出现非零样点 |

消抖窗口在 TB 里用 `DEBOUNCE_US = 16`（800 个 `clk_sys`）缩短以控制仿真时间；**出厂默认是 `DEBOUNCE_US = 16000`，即 16 ms @ 50 MHz**，由 `CLK_SYS_HZ` 推导，不是 TB 专用值。

运行方式（不依赖 `tools/sim_all.ps1`）：

```text
iverilog -g2012 -s tb_nes_ep4ce10_top -o tb.vvp \
  rtl/nes_core/cpu/nes_cpu6502.v \
  rtl/nes_core/ppu/nes_ppu_sprite.v rtl/nes_core/ppu/nes_ppu2c02.v rtl/nes_core/ppu/nes_oam_dma.v \
  rtl/nes_core/apu/nes_apu_length_lut.v rtl/nes_core/apu/nes_apu_pulse.v rtl/nes_core/apu/nes_apu_triangle.v \
  rtl/nes_core/apu/nes_apu_noise.v rtl/nes_core/apu/nes_apu_dmc.v rtl/nes_core/apu/nes_apu2a03.v \
  rtl/nes_core/bus/nes_cpu_bus.v rtl/nes_core/controller/nes_controller.v \
  rtl/nes_core/system/nes_system_v4.v \
  rtl/nes_core/video/nes_line_buffer_vga.v rtl/nes_core/video/nes_vga_timing.v \
  rtl/platform/ep4ce10/nes_ep4ce10_top.v rtl/platform/ep4ce10/nes_ep4ce10_pll_stub.v \
  tb/platform/tb_nes_ep4ce10_top.v
vvp tb.vvp
```

仿真里的 ROM 与 PPU RAM 是 TB 通过层次化写 `dut.u_nes.prg_rom` / `dut.u_nes.u_ppu.*` 装入的（与 `tb/system/*.v` 同一做法）。**上板时这些内容来自 TF 卡，本顶层不含任何加载逻辑。**

TB 抓到过的两个真实缺陷（说明这些断言不是装饰）：

1. `buttons1` 的拼接顺序写反，A/B/Select/Start 落在 `[7:4]` 而不是 NES 规定的 `[3:0]`。
2. 复位同步器的移位方向与输出极性不匹配（异步值 `2'b00` + 移入 1，对高有效输出等价于"复位释放后永久停在复位"），NES 核与 VGA 时序一直被按在复位里。

## 8. 与其他章节的关系

- 时钟来源与误差：`12-ntsc-clock-and-pll.md`。本顶层是那章"方案 B"的实现。
- 行缓冲结构与速率约束：`docs/modules/line-buffer-vga.md`。
- VGA 时序与 DE 窗口：`docs/modules/vga-timing.md`。
- 手柄位序与快照时机：`docs/modules/controller.md`。
- NES 核行为（NROM 期集成、APU 采样点）：`docs/modules/system-v4.md`、`docs/modules/apu-full.md`。
- 板级事实（晶振、复位键、器件资源）：`01-ep4ce10-board.md`。
- 未关闭风险：R-03（PPU 关键路径时序未测）、R-05（无 Quartus 证据）、R-07（50 MHz 到 NTSC 时钟未验证），见 `docs/00-overview/risk-register.md`。
