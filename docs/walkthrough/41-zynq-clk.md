# 41 时钟生成精读：`nes_zynq_clk.v`

前面 40 篇都在讲"拿到一个现成的 `clk` 以后怎么用"。这一篇反过来问：**时钟从哪来？** Zynq-7020 板上只有一颗 **50 MHz** 晶振，可 NES 核要 **21.477272727 MHz**、LCD 面板要 **25 MHz**——都不是 50 的整数分频。这个模块用**一颗 MMCM**（Xilinx 的时钟合成器）从 50 MHz 造出这两条时钟，再给一个 `locked`。

- 源码：[`rtl/platform/zynq/nes_zynq_clk.v`](../../rtl/platform/zynq/nes_zynq_clk.v)
- 合同与证据：[`../modules/zynq-platform.md`](../modules/zynq-platform.md)
- 测试目标：`zynq-clk-tb`（[`tb/platform/tb_nes_zynq_clk.v`](../../tb/platform/tb_nes_zynq_clk.v)）

---

## 1. 定位 + 上下游

```text
50 MHz 晶振 (U18) ─clk_in─►┌────────────────────┐─core_clk (21.477272727 MHz)─► NES 核
rst_in (高有效)  ─────────►│   nes_zynq_clk     │─lcd_clk  (25 MHz)──────────► 面板 / 音频 lane
                          │  1 × MMCME2_BASE   │─locked─────────────────────► 复位网
                          └────────────────────┘
```

- **上游**：50 MHz 板载晶振（引脚 `U18`，网名 `sys_clk`）+ 高有效复位 `rst_in`。
- **下游**：`core_clk` 喂 NES 核，`lcd_clk` 喂视频读口/音频 lane，`locked` 进复位网。
- 它是整机**时钟树的根**。`locked` 怎么用是**顶层**的事（不在本模块），文件头给了范例：

```verilog
assign core_rst_n = rst_in_n & nes_locked;
nes_sync_rst_n  <= core_rst_n & nes_locked;   // 在 core_clk 域释放
```

---

## 2. 全文代码（197 行）

```verilog
`timescale 1ns/1ps

// ============================================================================
// nes_zynq_clk : Zynq-7020 clock generator for the NES core
// ----------------------------------------------------------------------------
// The board oscillator is 50 MHz (package pin U18, net sys_clk, vendor XDC
// NAVIGATOR_ZYNQ_IO.xdc line 4).  The vendor material carries no
// 21.477272727 MHz clock of any kind, so the NES core clock is synthesised
// from the 50 MHz input with one MMCME2_BASE.
//
// Which output carries which clock, and why
//   MMCME2_BASE gives CLKOUT0 a fractional divide, CLKOUT0_DIVIDE_F, and only
//   integer divides to CLKOUT1..CLKOUT6.  The NES core clock therefore goes on
//   CLKOUT1, whose divide is an exact integer, and the LCD clock goes on
//   CLKOUT0, where the fractional divide is allowed to be a non-integer
//   multiple of 0.125.  Putting the core clock on CLKOUT0 instead would force
//   the LCD divide to be an integer, which is impossible from a 50 MHz input:
//   see the arithmetic below.
//
// Frequency derivation
//   The core clock is exactly 945/44 MHz = 21.477272727272... MHz.  The core
//   divides it by 4 with the 12 phase div_phase counter and ce_ppu is one core
//   clock in four, so the PPU dot rate is 945/176 MHz = 5.369318 MHz, which is
//   the NTSC dot rate.  The clock is therefore not "about 21.5 MHz": any other
//   frequency moves every PPU timing window.
//
//   Write CLKFBOUT_MULT_F = m/8 with m an integer, so f_vco = 50*m/8.  The core
//   divide is the integer k, so
//
//       f_core = (50*m/8)/k = 945/44    ->    2200*m = 7560*k
//                                        ->    55*m   = 189*k
//
//   55 and 189 are coprime, so m must be a multiple of 189 and k a multiple of
//   55.  The smallest pair is m = 189, k = 55:
//
//       CLKFBOUT_MULT_F  = 189/8 = 23.625          (primitive range 2.0 to 64.0)
//       DIVCLK_DIVIDE    = 1
//       f_vco            = 50 * 23.625 / 1 = 1181.25 MHz
//                                      (7-series MMCM VCO range 600 to 1200)
//       CLKOUT1_DIVIDE   = 55        (integer, 1 to 128)
//       f_core           = 1181.25 / 55       = 21.477272727272 MHz
//
//   Then the LCD divide must be f_vco/25 = 47.25, and 47.25 = 378/8, so it is an
//   exact multiple of the 0.125 step CLKOUT0_DIVIDE_F allows:
//
//       CLKOUT0_DIVIDE_F = 378/8 = 47.25
//       f_lcd            = 1181.25 / 47.25 = 25.000000000 MHz
//
//   Nothing in that chain is rounded, so the achieved frequencies are the
//   targets to the last bit the dividers can encode.
//
//   Why not a 1000 MHz VCO, the usual first guess.  A 1000 MHz VCO would need
//   CLKOUT1_DIVIDE = 1000/(945/44) = 46.560846560846..., which is not an
//   integer, and CLKOUT0_DIVIDE_F = 46.5625, the nearest multiple of 0.125,
//   gives 1000/46.5625 = 21.476510067114 MHz, 763 Hz low.  The CPU and PPU would
//   then run 0.0036 percent slow and the frame period would be visibly long.
//   The 1181.25 MHz VCO hits the frequency exactly instead.
//
// LCD clock
//   The vendor panel is 1056x525 with an 800x480 active area in DE mode.  The
//   vendor demo drives it with a divide by two of the 50 MHz input, which is
//   25 MHz and 45.1 Hz refresh.  A true 60 Hz would want 1056*525*60 =
//   33.264 MHz, which is awkward to reach from 50 MHz and is a separate design
//   decision, so 25 MHz is produced here to match the vendor and the divider is
//   a parameter so the platform top can change it later without touching this
//   module.  A different LCD target needs the derivation above re-run, because
//   the pair m/k that makes the core clock exact can move.
//
// locked, and why the platform top must use it
//   MMCME2_BASE LOCKED deasserts while the VCO is settling and its outputs are
//   not usable before that point.  locked is passed straight out of the
//   primitive with no masking and no resynchronisation here.  The platform top
//   must hold the NES core in reset until locked is high, for example
//
//       assign core_rst_n = rst_in_n & nes_locked;
//       nes_sync_rst_n  <= core_rst_n & nes_locked;   // released in core_clk
//
//   Releasing the core before locked means the core starts counting on a clock
//   that is still slewing, and the reset release lands at an arbitrary point in
//   the settling window.
//
// Simulation
//   MMCME2_BASE is a device primitive and cannot be simulated by Icarus, so the
//   instantiation is selected by macro.  Vivado defines SYNTHESIS during
//   synthesis and gets the real primitive and the real feedback BUFG; anything
//   else gets a plain wire for the feedback and the behavioural
//   mmcm_e2_base_sim model, which lives in tb/platform/tb_nes_zynq_clk.v.  The
//   model derives its output periods from the same parameters the primitive
//   takes, so a parameter error shows up as a frequency error in the testbench
//   edge count rather than as a silent elaboration success.
// ============================================================================

`ifdef SYNTHESIS
  `define NES_ZYNQ_MMCM_CELL MMCME2_BASE
  `define NES_ZYNQ_MMCM_FB   nes_zynq_clk_fb_bufg
`else
  `define NES_ZYNQ_MMCM_CELL mmcm_e2_base_sim
  `define NES_ZYNQ_MMCM_FB   nes_zynq_clk_fb_wire
`endif

module nes_zynq_clk #(
    // f_in in Hz.  Documentation only, the primitive is told the period.
    parameter CLK_IN_HZ         = 50_000_000,
    // CLKIN1_PERIOD in ns, 20.000 ns for the 50 MHz board oscillator.  Vivado
    // times the MMCM from this value, so it must match the real input.
    parameter CLK_IN_PERIOD     = 20.000,
    // MMCM parameters, see the derivation in the header.
    parameter CLKFBOUT_MULT_F   = 23.625,
    parameter DIVCLK_DIVIDE     = 1,
    // CLKOUT0 carries the LCD clock and is the only fractional divide.
    parameter CLKOUT0_DIVIDE_F  = 47.25,
    // CLKOUT1 carries the NES core clock on an integer divide.
    parameter CLKOUT1_DIVIDE    = 55
) (
    // 50 MHz board oscillator, package pin U18.
    input  wire clk_in,
    // Active high, drives the primitive RST input.  Hold high until the board
    // power rails and the oscillator are stable.
    input  wire rst_in,
    // 25 MHz LCD dot clock.  Parameter driven, see the header.
    output wire lcd_clk,
    // 21.477272727272 MHz NES core clock.
    output wire core_clk,
    // MMCM LOCKED, straight from the primitive.  The platform top must keep
    // the NES core in reset while this is low.
    output wire locked
);

    wire clkfb_out;
    wire clkfb_in;

// Every port of MMCME2_BASE is connected.  The primitive declares 18 ports and
// Vivado treats an omitted one as an error, even when it is an unused output,
// so the unused CLKOUT2..6 and the inverted outputs are tied off explicitly.
`NES_ZYNQ_MMCM_CELL #(
    .CLKFBOUT_MULT_F    (CLKFBOUT_MULT_F),
    .CLKOUT0_DIVIDE_F   (CLKOUT0_DIVIDE_F),
    .CLKOUT1_DIVIDE     (CLKOUT1_DIVIDE),
    .DIVCLK_DIVIDE      (DIVCLK_DIVIDE),
    .CLKIN1_PERIOD      (CLK_IN_PERIOD),
    .BANDWIDTH          ("OPTIMIZED"),
    .STARTUP_WAIT       ("FALSE")
) u_mmcm (
    .CLKIN1   (clk_in),
    .PWRDWN   (1'b0),
    .RST      (rst_in),
    .LOCKED   (locked),
    .CLKFBOUT (clkfb_out),
    .CLKFBOUTB(),
    .CLKFBIN  (clkfb_in),
    .CLKOUT0  (lcd_clk),
    .CLKOUT0B (),
    .CLKOUT1  (core_clk),
    .CLKOUT1B (),
    .CLKOUT2  (),
    .CLKOUT2B (),
    .CLKOUT3  (),
    .CLKOUT3B (),
    .CLKOUT4  (),
    .CLKOUT5  (),
    .CLKOUT6  ()
);

`NES_ZYNQ_MMCM_FB u_fb (
    .I(clkfb_out),
    .O(clkfb_in)
);

endmodule


// Synthesis only feedback buffer.  The MMCM feedback path needs a BUFG and
// Vivado does not insert one for a hand written primitive instance.
module nes_zynq_clk_fb_bufg (
    input  wire I,
    output wire O
);

    BUFG u_bufg (
        .I(I),
        .O(O)
    );

endmodule


// Simulation only feedback passthrough, so the same RTL source elaborates
// under Icarus without a BUFG primitive.
module nes_zynq_clk_fb_wire (
    input  wire I,
    output wire O
);

    assign O = I;

endmodule
```

注意：一个文件里有**三个** `module`——主体 `nes_zynq_clk`，加最后两个只做"反馈缓冲"的小模块（综合走真 `BUFG`，仿真走直连线）。

---

## 3. 逐段精读

### 3.1 文件头与 `` `timescale 1ns/1ps ``

文件头那一大段 `//` 是这个小模块的设计文档，把"哪个输出挂哪条时钟、频率怎么推、`locked` 怎么用、仿真怎么替代"写死，第 5 节再走一遍推导。`` `timescale `` 只给仿真器定时间单位，本项目每个文件都有。

### 3.2 `` `ifdef SYNTHESIS ``：同一份源码，两种后端

```verilog
`ifdef SYNTHESIS
  `define NES_ZYNQ_MMCM_CELL MMCME2_BASE
  `define NES_ZYNQ_MMCM_FB   nes_zynq_clk_fb_bufg
`else
  `define NES_ZYNQ_MMCM_CELL mmcm_e2_base_sim
  `define NES_ZYNQ_MMCM_FB   nes_zynq_clk_fb_wire
`endif
```

`` `ifdef `` 是**编译期**选择（同 C 的 `#ifdef`）。Vivado 综合定义 `SYNTHESIS`，两个宏展开成**真实 `MMCME2_BASE` 原语**与**真 `BUFG` 反馈**；Icarus 没有这个宏，展开成**行为模型 `mmcm_e2_base_sim`**（在 testbench 里）与**直连线反馈**。理由：`MMCME2_BASE` 是器件物理原语，Icarus 里不存在，硬例化会解析失败、把频率断言变空谈；仿真用的行为模型**从同一组参数**算周期，所以参数写错就表现为"频率测不对"，而不是"静默 elaborate 成功"。

### 3.3 参数逐条

- `CLK_IN_HZ = 50_000_000`：**仅供人读**，原语不用它（原语要的是周期）。
- `CLK_IN_PERIOD = 20.000`：输入周期（ns），50 MHz → 20 ns，是 **Vivado 的真实定时依据**，必须与板子一致。
- `CLKFBOUT_MULT_F = 23.625`：反馈倍频 `m/8`，`m=189`，原语范围 2.0..64.0。
- `DIVCLK_DIVIDE = 1`：输入预分频，取 1，不预分频。
- `CLKOUT0_DIVIDE_F = 47.25`：LCD 分频（**唯一可分数**），`378/8`，是 0.125 的整倍数。
- `CLKOUT1_DIVIDE = 55`：核时钟分频（**整数**），`k=55`。

（`50_000_000` 的下划线只是千分位，综合时即 `50000000`。）

### 3.4 端口

`clk_in`、`rst_in`（in）与 `lcd_clk`、`core_clk`、`locked`（out）全声明成 `wire`：模块内**没有 `always` 块**，输出都由原语输出端或 `assign` 连续驱动。

### 3.5 原语例化：端口必须全部连接

```verilog
`NES_ZYNQ_MMCM_CELL #(
    .CLKFBOUT_MULT_F (CLKFBOUT_MULT_F), .CLKOUT0_DIVIDE_F (CLKOUT0_DIVIDE_F),
    .CLKOUT1_DIVIDE (CLKOUT1_DIVIDE), .DIVCLK_DIVIDE (DIVCLK_DIVIDE),
    .CLKIN1_PERIOD (CLK_IN_PERIOD), .BANDWIDTH ("OPTIMIZED"), .STARTUP_WAIT ("FALSE")
) u_mmcm (
    .CLKIN1 (clk_in), .PWRDWN (1'b0), .RST (rst_in), .LOCKED (locked),
    .CLKFBOUT (clkfb_out), .CLKFBOUTB(), .CLKFBIN (clkfb_in),
    .CLKOUT0 (lcd_clk), .CLKOUT0B(), .CLKOUT1 (core_clk), .CLKOUT1B(),
    .CLKOUT2(), .CLKOUT2B(), .CLKOUT3(), .CLKOUT3B(),
    .CLKOUT4(), .CLKOUT5(), .CLKOUT6()
);
```

`MMCME2_BASE` 声明了 18 个端口，Vivado **把"漏接"当作错误**，所以连用不到的输出也要显式悬空：`.CLKOUT2()` 括号空着 = "这个端口我知道，但不用它"。`PWRDWN` 接常量 `1'b0`（常开不省电），`RST` 接 `rst_in`，`LOCKED` **原样**引出成 `locked`（不做掩码、不再同步）。参数 `BANDWIDTH("OPTIMIZED")` 让工具自动选环路带宽，`STARTUP_WAIT("FALSE")` 表示不等配置完成。

反馈环用两根 `wire` 分开接：`clkfb_out` 接原语 `CLKFBOUT`，`clkfb_in` 接原语 `CLKFBIN`，中间那块由 `u_fb` 填。

### 3.6 反馈缓冲两个模块：`BUFG` vs 直连线

`u_fb` 在两种后端下是不同实现：综合用 `nes_zynq_clk_fb_bufg`（内含 `BUFG`），仿真用 `nes_zynq_clk_fb_wire`（`assign O = I`，一根直连线）。

**`BUFG` 是什么？** FPGA 的**全局时钟缓冲器**：时钟信号必须走专用时钟网络（不是普通布线），才能低偏斜地扇出到全片触发器。手写原语时 Vivado **不会自动插**这个缓冲（文件头原话），所以必须自己接一个；仿真里没有 `BUFG` 原语，就用直连线代替（仿真不关心偏斜）。反馈回来的意义：MMCM 靠"把自己的输出与参考输入比相"来锁频锁相，反馈路径就是它判断"锁没锁上"的依据。

### 3.7 为什么 `locked` 必须参与复位

MMCM 上电后要花一段时间让内部 VCO（压控振荡器）稳定，期间 `LOCKED` 为**低**、输出时钟**不可用**（还在爬升、频率没锁死）。本模块把 `LOCKED` 原样引出，**门控责任在平台顶层**：必须用 `locked` 压住 NES 核的复位（第 1 节范例）。否则核会在一根还在变化的时钟上开始计数，复位释放的那一拍恰好落在稳定窗口里一个**任意**位置。复位网细节见 [`../modules/zynq-platform.md`](../modules/zynq-platform.md) 第 5 节。

---

## 4. 端口 / 参数表

| 端口 | 方向 | 作用 |
|---|---|---|
| `clk_in` | in | 50 MHz 板载晶振输入（`U18`） |
| `rst_in` | in | 高有效复位，直接驱动 MMCM 的 `RST` |
| `lcd_clk` | out | 25 MHz LCD 点时钟（来自 CLKOUT0 分数分频） |
| `core_clk` | out | 21.477272727 MHz NES 核时钟（来自 CLKOUT1 整数分频） |
| `locked` | out | MMCM 锁定指示，原样引出；顶层低有效用它压复位 |

| 参数 | 默认 | 作用 |
|---|---|---|
| `CLK_IN_HZ` | 50000000 | 文档用，不参与定时 |
| `CLK_IN_PERIOD` | 20.000 | 输入周期（ns），真实定时依据 |
| `CLKFBOUT_MULT_F` | 23.625 | 反馈倍频 `m/8` |
| `DIVCLK_DIVIDE` | 1 | 输入预分频 |
| `CLKOUT0_DIVIDE_F` | 47.25 | LCD 分频（可分数） |
| `CLKOUT1_DIVIDE` | 55 | 核时钟分频（整数） |

---

## 5. 把推导等式走一遍

**目标**：核时钟精确等于 `945/44 MHz = 21.477272727272... MHz`——不是"大约 21.5"，任何别的值都会移动每个 PPU 时序窗口（核再 4 分频即 NTSC dot 率 `945/176 = 5.369318 MHz`）。

**为什么不能整数分频**：50 除以整数只给 `50/N`，序列里没有 `21.477...`，所以要**分数倍频**。MMCM 的公式（`m`、`k` 为整数）是

```
f_vco = f_in * (m/8) / DIVCLK_DIVIDE          f_out = f_vco / k
```

取 `DIVCLK_DIVIDE = 1`、核时钟走整数分频 `k`，令 `(50 * m/8) / k = 945/44`：

```
50m / (8k) = 945/44   →(×44×8k)  2200m = 7560k   →(÷40)  55m = 189k
```

`55 = 5×11` 与 `189 = 3³×7` **互质**，所以 `m` 必是 189 的倍数、`k` 必是 55 的倍数，最小解 `m = 189, k = 55`：

```
CLKFBOUT_MULT_F = 189/8  = 23.625            （原语范围 2.0..64.0 ✓）
DIVCLK_DIVIDE   = 1
f_vco           = 50 * 23.625 = 1181.25 MHz  （7 系列 VCO 600..1200 ✓）
CLKOUT1_DIVIDE  = 55    → f_core = 1181.25/55 = 21.477272727272... MHz ✓
```

**LCD（25 MHz）**：`f_vco/25 = 47.25 = 378/8`，正好是 0.125 的整倍数，于是 `CLKOUT0_DIVIDE_F = 47.25`，`f_lcd = 1181.25/47.25 = 25.000000000 MHz` ✓。

**为什么核放 CLKOUT1、LCD 放 CLKOUT0**：`MMCME2_BASE` **只有 CLKOUT0 能分数分频**（`CLKOUT0_DIVIDE_F`），CLKOUT1..6 只接受整数。核时钟要求绝对精确 → 必须落在整数分频上 → CLKOUT1（`55`）；LCD 的 `47.25` 本就不是整数 → 只能在 CLKOUT0 的分数口表达。反过来把核放 CLKOUT0，就等于逼 LCD 用整数分频，而从 50 MHz 做不到。

**为什么不用 1000 MHz VCO（第一直觉）**：`CLKOUT1_DIVIDE = 1000/(945/44) = 46.5608...` 不是整数；取最接近的 0.125 倍数 `CLKOUT0_DIVIDE_F = 46.5625`，得 `f_core = 1000/46.5625 = 21.476510... MHz`，**低 763 Hz**。CPU/PPU 会慢 `0.0036%`，帧周期肉眼可见地变长。1181.25 MHz 的 VCO 才精确命中。

---

## 6. 常见疑问

**Q：为什么不能像别处那样用"50 MHz 分频 + `ce`"？** A：`ce` 只能把时钟按整数倍变慢（得到 `50/N`），而 `21.477272727` 不是 50 的整数分频，`ce` 造不出来，必须用能**分数倍频**的 MMCM。

**Q：仿真里没有真的 MMCM，这测试还算数吗？** A：算。仿真分支用 TB 里的行为模型 `mmcm_e2_base_sim`，它**从同一组参数**算输出周期，参数写错 → 测出频率错 → TB 报错。它验的是**分频算术与参数**，不是硅上的时钟抖动；真硅频率以 Vivado 时钟报告为准。

**Q：`locked` 只是一根输出线，为什么说它必须参与复位？** A：VCO 稳定前 `LOCKED` 无效、输出不可用；本模块故意"原样引出"，把门控责任交给顶层，顶层不接就等于让核在一根还在爬升的时钟上启动（3.7 节）。

**Q：想换 60 Hz 面板（33.264 MHz）要动哪？** A：要**重跑上面的 m/k 推导**（让核时钟精确的那对 `m/k` 可能会变），并同时改 `CLKOUT0_DIVIDE_F` 与 XDC 的 `create_clock` 周期，两处必须一起动。

---

## 7. 你应该带走的三件事

1. **精确时钟要"分数倍频"**：`f_core = 945/44`，靠 `CLKFBOUT_MULT_F = m/8` 与整数 `k` 命中，`2200m = 7560k → 55m = 189k → m=189, k=55`，VCO 1181.25 MHz。
2. **MMCM 的分工由硬件决定**：只有 CLKOUT0 能分数分频，所以精确的核时钟放 CLKOUT1（整数 55），本就非整数的 LCD 分频 47.25 放 CLKOUT0。
3. **原语 + `ifdef` + `locked`**：`MMCME2_BASE` 端口必须全接（没用的也要悬空），反馈要自己的 `BUFG`；仿真用行为模型替代真原语；`locked` 是复位网的必需品，必须在平台顶层用它压住 NES 核。

下一篇 [`50-cpu6502.md`](50-cpu6502.md) 进入核心：`nes_cpu6502.v` 的 6502 指令状态机——有了这篇的 `core_clk`，CPU 才有节拍可踩。
