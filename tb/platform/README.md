# NES platform testbenches

本目录有 3 个自检 testbench，覆盖两个平台顶层/时钟：

| testbench | 被测模块 | sim_all 目标 id |
| --- | --- | --- |
| `tb_nes_ep4ce10_top.v` | `rtl/platform/ep4ce10/nes_ep4ce10_top.v`（整个 EP4CE10 顶层） | `platform-tb` |
| `tb_nes_zynq_clk.v` | `rtl/platform/zynq/nes_zynq_clk.v`（Zynq-7020 MMCM 时钟发生器） | `zynq-clk-tb` |
| `tb_nes_zynq_top.v` | `rtl/platform/zynq/nes_zynq_top.v`（Zynq-7020 平台顶层） | `zynq-top-tb` |

此外本组还有两个**纯 elaboration 目标**（`Run = $false`，只编译 RTL 不跑仿真，用来确认顶层可 elaborate）：

- `platform-core`：顶层 `nes_ep4ce10_top`（`-g2001`）。
- `qsf-if-core`：顶层 `nes_ep4ce10_qsf_if`（`-g2001`，QSF 引脚包装层）。

这一组的目标可以用 `.\tools\sim_all.ps1 -Mode platform` 一次跑完（3 个仿真目标 + 2 个 elaboration 目标）。

---

# 1. `tb_nes_ep4ce10_top.v`：EP4CE10 平台顶层

被测是 `rtl/platform/ep4ce10/nes_ep4ce10_top.v`，目标 `platform-tb`。TB 用两个理想时钟驱动它：

- `clk_ntsc` 21.477272 MHz（半周期 23.275 ns），文档 12 定义的 NES 主时钟。核内 `div_phase` 再分出 `ce_cpu = /12`（1.789773 MHz）与 `ce_ppu = /4`（5.369318 MHz）；1.789773 MHz 是 CPU 速率，不是本顶层的时钟输入。
- `clk_vga` 25 MHz（半周期 20 ns）。
- `clk_sys` 50 MHz（半周期 10 ns），只用于按键消抖。消抖窗口用参数缩短（`DEBOUNCE_US = 16`，即 800 个 `clk_sys`），出厂默认仍是 16000 us = 16 ms @ 50 MHz。

断言清单（与 testbench 头一致）：

1. **VGA**：`hsync` / `vsync` / `de` 逐像素与 800x525 模型一致；每行 96 个 hsync 周期；可见行 512 个 de 周期、消隐行 0 个；`vsync` 恰好 3 行；帧周期 420000 拍。
2. **PPU 像素进入行缓冲**：`wr_ce` 每个 dot 采一次，`pixel_x` 严格逐个递增 0..255，每行 341 个 dot（一帧内 239 次，帧边界处 23*341，因为 240..261 消隐行不产生可见像素）；`line_done` 在 x=255 之后一拍拉高；`line_ready_toggle` 每写一行翻一次。
3. **按键**：`clk_sys` 域两级同步 + 消抖后才允许电平变化（`>= DEBOUNCE_CYCLES` 拍），变化后在 `<= 4` 个 `clk_ntsc` 内出现在 `buttons1[3:0]`，高 4 位恒为 1，`buttons2` 为 0xff。
4. **音频**：`audio_valid` 是 1 拍宽 strobe，复位期间为 0，出现非零样点。
5. **非零像素**：`vga_r` / `vga_g` / `vga_b` 出现非零，说明 PPU → 行缓冲 → VGA 时序整条打通。

TB 内置一段程序（`lda_imm` / `sta_abs` / `jmp_abs` / NMI 向量等 task 写 `MAIN_PROG`）、一个 800x525 VGA 模型、以及 `press` / `wait_frames` 等 task；`$fatal` 命中即以非零退出码结束。

# 2. `tb_nes_zynq_clk.v`：Zynq-7020 MMCM 时钟发生器

被测是 `rtl/platform/zynq/nes_zynq_clk.v`，目标 `zynq-clk-tb`。Icarus 不能仿真 `MMCME2_BASE`，所以 DUT 在非 `SYNTHESIS` 时例化**本文件底部的行为级模型** `mmcm_e2_base_sim`。该模型不是手写的定频发生器：它从 `CLKIN1_PERIOD`、`DIVCLK_DIVIDE`、`CLKFBOUT_MULT_F` 与两个 CLKOUT 分频**按 primitive 的方式推导**输出周期，所以一个错误的分频会表现为**测得的频率错**，而不是静默 elaborate 成功。

测量方法：两个独立计数器分别监视 `core_clk` 与 `lcd_clk` 的上升沿，各自记录首个与第 N 个上升沿的 `$realtime`，测得周期 `(t_N - t_1)/(N-1)`、频率 `1000/period` MHz。不从模型的算术里取样，模型的唯一贡献是沿时刻本身。测量窗口 4096 个沿（约 190.7 us）。

断言清单：

1. `rst_in` 高时强制 `locked` 低、两路输出为 0。
2. `locked` 只在模型建立时间之后、且在几拍输入周期内断言。
3. `locked` 为高之前两路输出不产生任何沿。
4. `core_clk` 频率在 `TOL_REL = 100 ppm` 内等于 21.477272727272 MHz。
5. `lcd_clk` 频率在 100 ppm 内等于 25.000000 MHz。
6. 测得频率等于**从 DUT 自身参数值重算**的分频算术，所以被检验的是参数而非常量。
7. 分频算术精确（相对 1e-12）：VCO 落在 7 系列 600..1200 MHz 内，乘数与两个 CLKOUT 分频都是 0.125 的整数倍，两个目标命中优于 1e-12。
8. `core_clk / 4` 是 NTSC PPU dot 速率 5.369318 MHz——NES 核依赖的这条合同。
9. 第二次 `rst_in` 脉冲再次拉低 `locked`、停两路时钟，重锁后 `core_clk` 频率不变。

容差说明：噪声底是模型实值延时的 1 fs 量化（每个半周期四舍五入到最近的 1 fs 刻度），在 190.7 us 窗口上约 21 ppm，故断言容差取 100 ppm（最坏量化的五倍）；真实硅片上的频率以 Vivado 时钟报告为准，不是本仿真。

`mmcm_e2_base_sim` 定义在本文件里，`tb_nes_zynq_top.v` 会把它一并编译进来复用。

# 3. `tb_nes_zynq_top.v`：Zynq-7020 平台顶层

被测是 `rtl/platform/zynq/nes_zynq_top.v`，目标 `zynq-top-tb`。顶层是布线层，其子模块各自已 gate，所以本 bench **不重测** PPU / mapper / scaler 的算术，只证明只在此层存在、别处没有的几件事：

1. **三个时钟域真是三个域、比例正确**：一个行为级 `MMCME2_BASE` 模型（`mmcm_e2_base_sim`，复用自 `tb_nes_zynq_clk.v`）产生真实的 `core_clk` 与 `lcd_clk`，因此测得的帧周期是真实值。
2. **复位网络**：三条按域独立的链，高有效，对 `!sys_rst_n` 异步断言、同步释放，各自与 `locked` 的两级同步器相与。`locked` 低时核必须在 core 与 lcd 两个域都被复位，只有 `locked` 高后才释放。
3. **顶层拥有的两个面板引脚**：`lcd_rst` 上电保持低后释放；`lcd_bl` 不得在该释放之前起来。
4. **顶层拥有的两张转换表**：64 项调色板 LUT 与 RGB565 → RGB888 扩展，另加 `lcd_rgb` 的三态行为与按键的 2-FF 跨域。
5. **触控 lane**：顶层拥有两条面板 I2C 引脚，是本设计中**唯一**能观察 `touch_scl` / `touch_sda` 开漏合同的地方。一个行为级 GT9147 slave 对控制器 ACK 并应答状态与坐标寄存器读；总线在整轮运行中被持续监视，以免推挽驱动藏在安静窗口里。

两个额外的独立检查：

- **调色板防循环**：期望值来自对 `.slim/clonedeps/repos/caseif__cNES/src/ppu.c:94-111` 的**第二份独立转写**（转成 RGB888，用同一套文档化法则 `R5=R8>>3, G6=G8>>2, B5=B8>>3`），但两份转写一致还不能说明对，所以再叠一层**与硬件相符的调色板字面量**——其中 `$0F` 是消隐项因此是**黑**、白是 `$20` 和 `$30`。
- **帧率比**：core 帧周期 = `262*341*4` core clocks = 357368 core clocks = 16.6379 ms；面板帧周期 = `1056*525` lcd clocks = 554400 lcd clocks = 22.1760 ms；于是 `panel_frames / core_frames` 必须是 `16.6379/22.1760 = 0.7503`（即 0.75）。这条廉价端到端 sanity check 若时钟或帧缓冲有错就不会是 0.75。

输出多次打印 `INFO` / `VIOLATION` 行，最后以 `PASS nes_zynq_top ...` 或 `FAIL nes_zynq_top with N violations` 结束，另有 `global timeout` 兜底。

---

# 运行

统一入口（含两个纯 elaboration 目标）：

```powershell
.\tools\sim_all.ps1 -Mode platform
```

单个目标，例如：

```powershell
.\tools\sim_all.ps1 -Mode zynq-clk-tb
```

`zynq-clk-tb` 的直接等价 Icarus 命令（源文件少，可直接调用）：

```powershell
$tmp = $env:TEMP
& 'C:\iverilog\bin\iverilog.exe' -g2012 -s tb_nes_zynq_clk -o (Join-Path $tmp 'tb_nes_zynq_clk.vvp') 'rtl\platform\zynq\nes_zynq_clk.v' 'tb\platform\tb_nes_zynq_clk.v'
& 'C:\iverilog\bin\vvp.exe' (Join-Path $tmp 'tb_nes_zynq_clk.vvp')
```

`platform-tb` 与 `zynq-top-tb` 的源文件很多（顶层 RTL + 相应系统的全部 RTL + 视频/音频依赖 + testbench），逐条手写容易漏依赖，建议直接用 `.\tools\sim_all.ps1 -Mode platform`（或 `-Mode platform-tb` / `-Mode zynq-top-tb`）由脚本拼出规范化源列表：

```powershell
$tmp = $env:TEMP
$src = @(
    'rtl\platform\ep4ce10\nes_ep4ce10_top.v',
    'rtl\platform\ep4ce10\nes_ep4ce10_pll_stub.v',
    'rtl\platform\ep4ce10\nes_ep4ce10_qsf_if.v'
    # 再加 nes_system_v4 的全部 RTL、行缓冲（nes_line_buffer_vga.v）与 VGA 时序（nes_vga_timing.v）
)
& 'C:\iverilog\bin\iverilog.exe' -g2012 -s tb_nes_ep4ce10_top -o (Join-Path $tmp 'tb_nes_ep4ce10_top.vvp') ($src + 'tb\platform\tb_nes_ep4ce10_top.v')
& 'C:\iverilog\bin\vvp.exe' (Join-Path $tmp 'tb_nes_ep4ce10_top.vvp')
```

任何 `$fatal` 命中都会让 vvp 以非零退出码结束。

# 未覆盖 / 边界

- **只有 Icarus 纯 RTL 仿真证据**：本目录没有 ModelSim `.do` 脚本，仓库也没有 Quartus / Vivado 上板证据；所有 PASS 只来自 Icarus Verilog。
- **EP4CE10 顶层 tb 用理想时钟**：不覆盖 PLL 锁定、抖动或引脚约束；`clk_ntsc` / `clk_vga` / `clk_sys` 是理想的。
- **MMCM 是行为模型，不是真实 primitive**：`mmcm_e2_base_sim` 从参数推导周期，只证明参数算术与频率合同，真实频率以上板 Vivado 时钟报告为准。
- **zynq-top 的触摸 slave 是行为模型**：它能 ACK 并应答状态/坐标寄存器，但不是真实 GT9147；模拟前端行为不在覆盖内。
- **子模块算术不在此重测**：PPU / mapper / scaler / 音频 lane 的正确性由各自的 bench 负责，本组只验证平台层面的时钟、复位、引脚与转换表。
