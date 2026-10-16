# Zynq-7020 平台层（`nes_zynq_clk` + `nes_zynq_top`）：从 50 MHz 板载晶振到三条跨域边界

本文说明 `rtl/platform/zynq/nes_zynq_clk.v` 与 `rtl/platform/zynq/nes_zynq_top.v` 的接口合同、时钟树、复位网和跨域边界，回答一个和 `controller.md`、`i2s-audio.md`、`cdc-fifo.md` 同源的教学问题：

> 一个用 C 写的软件模拟器里，"时钟"是免费的（全进程一根时间轴）、"复位"是免费的（`main()` 从头跑一遍）、"跨模块传数据"是免费的（同一块内存）。为什么 FPGA 平台顶层要把一半的注意力放在时钟怎么来、复位怎么放、数据怎么跨这三件事上？

结论：**软件的"免费"来自单线程单地址空间这台机器根本不存在的并行前提；硬件把这些前提全部取消。** `nes_zynq_clk.v` 负责一件事——用一颗 MMCM 从 50 MHz 造出精确的 21.477272727 MHz 和 25 MHz；`nes_zynq_top.v` 负责两件没有子模块能负责的事——**时钟树和复位网**，外加把核、卡带、视频、音频、触摸五条通路接起来。凡是软件里"不存在"的东西（异步时钟域、亚稳态、背压、上电顺序），这里都必须显式补上。

平台顶层的两个**文件头**是设计事实的准绳：`nes_zynq_clk` 的派生推导、`nes_zynq_top` 的 CLOCK DOMAINS / AUDIO LANE / 三条跨域段。本文以它们为准，`[源码观察]` 标记的内容只是观察。行为权威是 Xilinx 7 系列 `MMCME2_BASE` 文档和板级资料，不是任何模拟器的写法。

对照阅读：EP4CE10 平台的同类文档是 `docs/hardware/13-platform-top.md`（altpll、行缓冲、单音频 lane），两者组织方式一致，但**时钟发生器、跨域结构和音频实现完全不同**，见第 9 节。

---

## 1. 板子、器件与为什么需要 MMCM

- **器件**：Xilinx Zynq-7020，封装 `xc7z020-clg400-2`（`.xdc` 头）。
- **板载晶振**：50 MHz，封装引脚 **U18**，网名 `sys_clk`（`nes_zynq_top.xdc`：`create_clock -name sys_clk -period 20.000 [get_ports sys_clk]`）。
- **vendor 资料里没有任何 21.477272727 MHz 的时钟源**，所以 NES 核时钟必须自己从 50 MHz 造。

为什么不能用整数分频：NES 核时钟的精确值是 `945/44 MHz`，相对 50 MHz 的比值是

```
f_core / f_in = (945/44) / 50 = 945 / 2200 = 189 / 440
```

也就是"乘 189、除 440"。整数分频只能给 `f_in / N` 或 `f_in * M / N`（M、N 都是小整数），要落到这个比值上，需要**分数倍频**。7 系列 MMCM 恰好允许 `CLKFBOUT_MULT_F` 以 0.125 为步进，而 CLKOUTn 是整数分频，所以能写成

```
f_out = f_in * (m/8) / k        （m 为整数，k 为整数）
```

要它等于 `(189/440) * f_in`，就需要 `m = 189`、`8k = 440` 即 `k = 55`。**这两步就是全部理由**：不是"21.5 兆差不多就行"，而是任何别的频率都会移动每一个 PPU 时序窗口。

---

## 2. 时钟推导逐步

以文件头为准，推导链条无一处取整：

```
f_core = (50 * m/8) / k = 945/44
        -> 2200*m = 7560*k
        -> 55*m   = 189*k

55 与 189 互质，所以 m 必须是 189 的倍数、k 必须是 55 的倍数，最小解 m=189、k=55。

CLKFBOUT_MULT_F  = 189/8 = 23.625          (原语范围 2.0 .. 64.0)
DIVCLK_DIVIDE    = 1
f_vco            = 50 * 23.625 / 1 = 1181.25 MHz   (7 系列 MMCM VCO 范围 600 .. 1200)
CLKOUT1_DIVIDE   = 55                       (整数，1 .. 128)
f_core           = 1181.25 / 55 = 21.477272727272 MHz

CLKOUT0_DIVIDE_F = 378/8 = 47.25            (0.125 的精确倍数)
f_lcd            = 1181.25 / 47.25 = 25.000000000 MHz
```

**为什么核时钟放 CLKOUT1、LCD 放 CLKOUT0**（文件头"What output carries which clock"段）：`MMCME2_BASE` 只给 CLKOUT0 一个分数分频口 `CLKOUT0_DIVIDE_F`，CLKOUT1..6 只接受整数分频。核时钟要求绝对精确，必须落在**整数分频**上，所以放 CLKOUT1；LCD 的 `f_vco/25 = 47.25` 本身不是整数，只有 CLKOUT0 的分数口能表达。如果把核时钟放 CLKOUT0，就等于逼 LCD 用整数分频，而这是从 50 MHz 做不到的。

**为什么不用 1000 MHz VCO**（文件头加粗的一段）——这是"第一直觉"。1000 MHz 会要求

```
CLKOUT1_DIVIDE = 1000/(945/44) = 46.560846560846...   不是整数
CLKOUT0_DIVIDE_F = 46.5625（最接近的 0.125 倍数）
f_core = 1000/46.5625 = 21.476510067114 MHz，低了 763 Hz
```

CPU 与 PPU 会慢 0.0036%，帧周期肉眼可见地变长。1181.25 MHz VCO 才是精确命中。

**LCD 目标本身是个未决设计选择**（`nes_zynq_top.xdc` 的 PENDING DECISION 块）：vendor 面板是 1056×525、800×480 有效区，vendor 用 50 MHz 二分频即 25 MHz、45.1 Hz 刷新。真 60 Hz 需要 `1056*525*60 = 33.264 MHz`，而 `1181.25/33.264 = 35.521...` 不是 0.125 的倍数，所以想换 60 Hz 必须**重跑上面的 m/k 推导**、同时改 `CLKOUT0_DIVIDE_F` 和 XDC 的 `create_clock` 周期，两处必须一起动。

---

## 3. 三个时钟域

三个域，**core_clk 与 lcd_clk 之间除像素流和音频样点流外没有别的东西跨越**（顶层文件头）。25 MHz 不是 21.477 MHz 的整数倍，所以面板输出级不能用核心时钟加使能来跑。

| 域 | 频率 | 来源 | 挂什么 |
| --- | ---: | --- | --- |
| `sys_clk` | 50 MHz | 板载晶振 **U18**（顶层直接输入） | `nes_touch_input`；`wm8960_i2c` codec 配置；`lcd_rst`/`lcd_bl` 上电计数器；`locked` 同步器第 1 级 |
| `core_clk` | 21.477272727 MHz | MMCM **CLKOUT1** | `nes_system_v6`（CPU/PPU/APU/bus/controller/mapper）；`nes_cart_rom` CHR 半边；音频抽取滤波器；调色板 LUT（组合）；`nes_video_800x480` 写口 |
| `lcd_clk` | 25 MHz | MMCM **CLKOUT0** | `nes_video_800x480` 读口；`nes_audio_i2s` 读侧与 bclk（`rd_clk = mclk = lcd_clk`）；RGB565→RGB888（组合）；`lcd_de`/`lcd_hs`/`lcd_vs`/`lcd_rgb` 面板引脚；`aud_mclk`（就是 `mmcm_lcd_clk` 出片） |

注意 `lcd_clk` 是**一个数据输出，不是一个新时钟域**：`assign lcd_clk = mmcm_lcd_clk;`，`lcd_de`/`lcd_rgb` 就寄存在同一个网上。

---

## 4. 三条跨域边界

顶层文件头把跨域边界数成**三条**，手段各不相同：

### 4.1 touch buttons：`sys_clk -> core_clk`，两级同步器

`nes_touch_input` 在 50 MHz 域产出的 8 位按钮电平要喂给核里的 `$4016` 移位序列。核**不能容忍一个亚稳态的位**，所以过一个两级触发器同步器：

```verilog
(* ASYNC_REG = "TRUE" *) reg [7:0] btn_meta_q, btn_sync_q;
always @(posedge mmcm_core_clk or negedge sys_rst_n) begin
    if (!sys_rst_n) begin btn_meta_q <= 8'h00; btn_sync_q <= 8'h00; end
    else            begin btn_meta_q <= touch_buttons; btn_sync_q <= btn_meta_q; end
end
```

`ASYNC_REG` 把两级摆在一起。XDC 对 `u_touch/* -> btn_meta_q_reg[*]` 下 `set_max_delay -datapath_only 20.000`（见第 9 节"为什么不是 set_false_path"）。

### 4.2 `frame_mem`：真双口 BRAM，零逻辑跨界

`nes_video_800x480` 里的 `frame_mem`（`reg [15:0] frame_mem [0:61439]`，256×240 个 16 位字）是一块**真正的简单双口 RAM**：写口 `core_clk`、读口 `lcd_clk`。因为是 RAM，跨域**不花任何逻辑**——没有同步器、没有 toggle、没有握手、没有背压（文件头原文）。同周期同地址读写返回旧值（BRAM read-first），缓冲是单缓冲的。

### 4.3 音频样点 FIFO：格雷指针 + 两级同步 + XDC 约束

`nes_audio_i2s` 里的 `nes_cdc_fifo`（实例 `u_fifo`）同样是双时钟 RAM，但它是**真双时钟 FIFO**：格雷码指针 + 两级同步器，所以它**确实含** `core_clk -> lcd_clk` 和反向的触发器跨域路径。与 4.2 不同，这些路径要用 XDC 绑住。XDC 对三组路径下 `set_max_delay -datapath_only 40.000`：

```
wr_gray_reg        -> wr_gray_sync1_reg     （写指针 core_clk -> lcd_clk）
rd_gray_reg        -> rd_gray_sync1_reg     （读指针 lcd_clk -> core_clk）
mem_reg            -> rd_data_reg           （32 位读 mux，两条指针约束覆盖不到）
```

第 3 条容易被漏掉：`mem_reg` 在 `wr_clk` 写、`rd_data_reg` 在 `rd_clk` 载入，是第四条 `core_clk -> lcd_clk` 弧。它可绑的理由是满标志只在 `rd_gray_sync2` 走完一个来回后才清，所以 `rd_bin` 选中某个字时该字已稳定整整一个指针来回。

FIFO 深度用 `ADDR_WIDTH = 6`（64 项）。默认的 10（1024 项）会让 `1024*32*2 = 65536` 个触发器把 xc7z020 的放置器撑爆（`[源码观察]` 满足 93.7% LUT / 66.3% FF 时报 `[Place 30-4]`）；这条通路速率精确相等，64 项即约 1.31 ms 缓冲，实测固定延迟只有 1 个采样。细节见 `docs/modules/cdc-fifo.md`、`docs/modules/i2s-audio.md`。

### 4.4 第四条：`cfg_done` 本身也跨域

严格说 codec 的 `cfg_done` 是 `sys_clk -> core_clk` 和 `sys_clk -> lcd_clk` 两组同步器（XDC 各下 `set_max_delay -datapath_only 20.000`），但由于它在复位网里被消费，放到第 5 节。

---

## 5. 复位网

板级 `sys_rst_n` **低有效**。每个域各自一条链：**异步断言、同步释放**，再与该域自己的 `locked` 两级同步器相与。

```verilog
(* MAX_FANOUT = 32 *) reg [1:0] rst_sys_q, rst_core_q, rst_lcd_q;
always @(posedge sys_clk or negedge sys_rst_n)
    if (!sys_rst_n) rst_sys_q <= 2'b11; else rst_sys_q <= {rst_sys_q[0], 1'b0};

wire rst_sys  = rst_sys_q[1]  | ~locked_sys_q1;   // 高有效：1 = 处于复位
wire rst_core = rst_core_q[1] | ~locked_core_q1;
wire rst_lcd  = rst_lcd_q[1]  | ~locked_lcd_q1;
```

要点：

1. **`locked` 参与复位。** MMCM 在 VCO 稳定前 `LOCKED` 无效，其输出不可用。核**必须在 `locked` 为高之前被按在复位里**，否则会在一根还在爬升的时钟上开始计数、复位释放点落在稳定窗口的任意位置。`core_clk`/`lcd_clk` 本来就要 `locked` 之后才有时钟沿，所以这两域里那些异步断言的触发器**只是保持复位直到自己的时钟起振**——这正是要求的行为。
2. **三个域的复位寄存器互不驱动**，各域独立，输出高有效。`MAX_FANOUT = 32` 是综合指令：不加它 `opt_design` 会用一个触发器驱动整域的异步清零（`[源码观察]` 实测 `rst_core_q[1]/C -> */CLR` 路由 9.4..10.3 ns，约 94% 是布线），加它才会复制驱动器搭复位树。它不改变行为，也不是时序例外。
3. **音频 lane 在复位链上再加一层限定 `cfg_done`。** `wm8960_i2c` 在 `sys_clk` 上走 15 项上电表，约 4.6 ms 后拉高 `cfg_done`。FIFO 两端都不能在它之前跑：`nes_audio_i2s` 在复位时锁存 `rd_empty` 并把 `underflow` **粘滞**点亮，读侧提前放行会让它整个运行期都报 underflow，还会向仍处于上电默认态的 codec 送 BCLK。所以 `cfg_done` 各自两级同步进两域，再或进复位：

```
rst_audio_wr = rst_core | ~codec_cfg_core_q1
rst_audio_rd = rst_lcd  | ~codec_cfg_lcd_q1
```

两条都高有效，都因为或上了继承项而在 `!sys_rst_n` 上异步断言。

4. **面板复位与背光**由 `sys_clk` 上的一个 16 位上电计数器管：`lcd_rst` 在 `sys_rst_n` 释放后 `LCD_RST_HOLD_CYCLES = 5000`（100 µs）拉高（高 = 出复位），`lcd_bl` 在 `LCD_BL_ON_CYCLES = 20000`（400 µs）才拉高，**保证背光不在未复位的面板上点亮**。切勿反转 `lcd_rst`：反相会在 t=0 就把面板拔出复位、计数到位后又按回去。

---

## 6. 音频 lane

通路是 `core_clk -> 抽取器 -> nes_audio_i2s FIFO -> I2S 移位器 -> wm8960_i2c -> WM8960 引脚`。文件头把其中不显然的地方逐条推导，这里给出结论：

### 6.1 `audio_sample_valid` 不是音频采样率

`nes_system_v6.v` 置 `ce_sample = 1'b1`，`nes_apu2a03.v` 在 `ce && ce_sample` 上发 `sample_valid`，而 `ce = ce_cpu` 是 12 个核心钟里 1 个。所以该 strobe 速率是

```
21477272.727 / 12 = 1789772.727 Hz   （约 1.789 MHz）
```

这是 APU 的自然速率，比任何可用采样率高约 37 倍。**直接喂进 I2S 移位器就是"用 1.79 MHz 串噪声"。**

### 6.2 为什么 /37 不可用

```
1789772.727 / 37 = 48372.235 Hz，比 48000 高 101/13024 = 0.7755%
```

误差本身是**可用性**问题而非音质问题：抽取器与 I2S 移位器之间是单生产者单消费者 FIFO，**任何**速率失配都会让水位一路走到满（丢样）或走到空（underflow）。0.78% 的失配约 **26 秒**填满/抽干一个 1024 项 FIFO。

与 25 MHz 侧帧率精确匹配的唯一整数抽取是 `/126`（14204 Hz，奈奎斯特只有 7.1 kHz，差得没法用）。算术：移位器每立体声样点出 `16 + 16` 位、一位一个 BCLK，一帧 32 BCLK，帧率 `25e6/(32*D)`（`BCLK_DIV = D`），与 strobe 速率之比是

```
(19687500/11) * (32*D/25000000) = 126*D/55
```

要取整必须 `55 | D`，只有 `D = 55`（得 14204.5 Hz）；`D = 16`（合理选择）得 `126*16/55 = 2016/55 = 36.654545...`，不是整数。于是抽取是**有理的 2016/55**，用**精确 Bresenham 累加器**实现：2016 个输入进、55 个输出出，永不累积误差——累加器是有界整数，状态只取决于已见样点计数。

### 6.3 滤波：4/4/2 三级滑动平均，不是 16 抽头 FIR

固定长度箱式平均只有除以整数长度才有 unity 增益，有理比值下平均长度在 1 与 2 之间交替，**不存在固定增益**；而且 37 抽头滑动平均的第一个零点在 `1789772/37 = 48.4 kHz`，对真正会折叠进输出的 24 kHz 带几乎无衰减。实际用三级短滑动平均 **4、4、2** 抽头串联，零点落在 **447 kHz、447 kHz、894 kHz**，都在输入带内、远高于音频带：帧率处约 0.35 dB，700 kHz 处约 −33 dB，而 DC 增益精确为 1（末级除以 `4*4*2 = 32`）。**这不是完整抗混叠滤波器**——要在 20 kHz 内做到 −40 dB 需要 1.79 MHz 下 16 抽头 FIR，那是另一件工作，这里没有做。实现上一个坑：第三级 `ma3_tog` 必须是 1 bit，2 bit 会变成再除以 2，总比立刻配不上 63/55。

### 6.4 为什么 `rd_clk` 与 `mclk` 是同一个网

`nes_audio_i2s.v:241-249` 在 `posedge bclk` 上采 `sh_out_bit`/`sh_out_lrck`，**不加同步器**，是从 `rd_clk` 域跨进 `mclk` 派生域。若两者是无关网络，这就是**未同步的两比特跨越**。把两者都接到 `mmcm_lcd_clk`，`bclk` 就成了同一时钟的分频版本，采样沿与驱动沿**相位相关**，每一位在整整一个 BCLK 周期（8 个 `lcd_clk`）内保持稳定。副作用：读侧就在 `lcd_clk` 域、`mclk` 也不是新时钟。实例化时 `.rd_clk (mmcm_lcd_clk)`、`.mclk (mmcm_lcd_clk)`，而 `aud_mclk` 直接就是 `mmcm_lcd_clk` 出片。

### 6.5 帧率、BCLK 与 codec 自己的 PLL

```
BCLK_DIV = 16 -> BCLK = 25e6/16 = 1.5625 MHz，fs = 1.5625e6/32 = 48828.125 Hz
             = 1789772.727 * 55/2016  （逐位相等，FIFO 水位不会走动）
```

WM8960 被自己的 PLL 告知按 48828.125 Hz 采样，源是 25 MHz 的 MCLK：

```
f1 = 25 / 2^PLLPRESCALE = 25/2 = 12.5 MHz
R  = PLLN + PLLK/2^24 = 8 + 0 = 8
f2 = R*f1 = 100 MHz          (PLL VCO)
SYSCLK = f2/(4*2) = 12.5 MHz
fs = SYSCLK/256 = 48828.125 Hz
```

`f2` 落在数据手册"90–100 MHz 表现最佳"的上沿，`PLLN = 8` 正是"稳定性在 N=8 峰值"那一档，`PLLK = 0` 则完全没有小数分频抖动。**替代方案**是加第三路 MMCM 输出到 12.288 MHz 得到精确 48 kHz、不借 codec PLL，但那会重新打开核时钟推导（它唯一职责就是精确命中 21.477272727），为 0.78% 的采样率得不偿失。

codec 寄存器表与时钟方案的逐项数据手册引用见 `rtl/nes_core/peripheral/wm8960_i2c.v` 文件头和 `docs/modules/wm8960-i2c.md`。

---

## 7. 触摸 lane、卡带、视频与调色板

### 7.1 触摸 lane（`sys_clk`）

`nes_touch_input` 在 `sys_clk` 上，把 GT9147 电容屏变成 NES 手柄。引脚：`touch_scl`/`touch_sda`（**真 inout，开漏**，R19/P20）、`touch_rst_n`（M19）、`touch_int`（U19）。板载两个 PL 键 `key[1:0]`（L14/K16，**低有效**）与第三个离散按钮 `touch_key`（F16，**高有效**，不是触摸屏上的点）。输出 `touch_buttons[7:0]`，位序与 `nes_controller` 一致：`[7:4]` 是触摸 d-pad `{Up,Down,Left,Right}`，`[1:0]` 是 A/B，`[3:2]` 在 `touch_key` 按住时改当 Start/Select。

驱动会**一次性自校准**：读 `16'h8048/8049` X Output Max、`16'h804A/804B` Y Output Max、`16'h804D` Module_Switch1 的 bit3（X2Y），据此推出 d-pad 的三个分区切点（`touch_x_max`/`touch_y_max`/`touch_x2y`/`touch_x_left_edge` 等是顶层内部 wire，**没有引出为端口**，只在仿真里读）。但它不在本仓库的模块文档里（`docs/modules/touch-input.md` 尚不存在），以 `rtl/nes_core/peripheral/nes_touch_input.v` 文件头为准。

### 7.2 卡带（CHR-only 在顶层，PRG 在核内）

`nes_cart_rom` 在本顶层实例化**一次**，只用 CHR 半边（`PRG_ENABLE(0)`、`CHR_ENABLE(1)`）：它的 `ce_ppu` 用核导出的 `core_ce_ppu`，它的 `chr_rdata` 驱动核的 `chr_rdata` 输入。PRG 半边在 `nes_system_v6` **内部**再实例化一次（`PRG_ENABLE=1`、`CHR_ENABLE=0`）。`ce_ppu` **逐字使用、绝不重新生成 `div_phase`**：除非模块疏忽，重生成会差 1..3 拍、在错误的 `ce_ppu` 沿锁存 `chr_addr`，静默返回上一个 pattern 字节（见 `nes_cart_rom.v` 文件头 CHR READ LATENCY）。ROM 内容来自 `$readmemh` 读的 hex 文件（`PRG_INIT_FILE`/`CHR_INIT_FILE`，默认是占位文件），**没有卡读取器、没有引导加载器**。细节见 `rtl/nes_core/cart/nes_cart_rom.v`（本仓库暂无 `docs/modules/cart-rom.md`）。

### 7.3 视频（`nes_video_800x480` + RGB565→RGB888）

写口 `core_clk`、读口 `lcd_clk`，`ce` 恒 1。800×480 有效区套在 1056×525 里，缩放精确（`800 = 256*3 + 32`，`32 = 256/8`；纵向 240→480 恰为 2:1）。PPU 与写口之间有**两级流水寄存器**，64 项调色板 LUT 夹在两级之间。写选通是 `core_ce_ppu && core_pixel_valid`：`core_pixel_valid` 是**电平**（一个 dot 持续 4 个核心钟），而 `nes_video_800x480` 在每个 `wr_clk` 沿只要 `in_valid` 高就写，所以要靠 `ce_ppu` 收敛成每 dot 一拍（详见 `rtl/nes_core/video/nes_video_800x480.v` 文件头；本仓库暂无 `docs/modules/video-800x480.md`）。

RGB565→RGB888 用**全长位复制**：`{r5, r5[4:2]}`、`{g6, g6[5:4]}`、`{b5, b5[4:2]}`，所以 0→0、满→满、每通道单调。总线 `lcd_rgb` 双向，仅在 `vid_de` 高时驱动（`assign lcd_rgb = vid_de ? {lcd_r8,lcd_g8,lcd_b8} : 24'hz;`），红色落在 `[23:16]`。

### 7.4 调色板 LUT

`pixel_pal[7:0]` 是 PPU 存的原始字节，只有 `[5:0]` 索引进调色板（`[5:4]` 是色轴、`[3:0]` 是亮度轴）。64 项取自 cNES 参考表 `.slim/clonedeps/repos/caseif__cNES/src/ppu.c:94-111`，每项 `(r,g,b)` 转 RGB565 用 `R5 = R8>>3`、`G6 = G8>>2`、`B5 = B8>>3`。`nes_line_buffer_vga.v` 里的色相扫描**不复用**——那是 hue sweep 不是 NES 调色板，会把 Mario 渲染成彩虹色。$0F 是 blacking 项（黑），白是 $20/$30。

---

## 8. 端口与引脚

`nes_zynq_top` 的端口：`sys_clk`/`sys_rst_n`、`key[1:0]`、`touch_key`、`lcd_rgb[23:0]`(inout)/`lcd_hs`/`lcd_vs`/`lcd_de`/`lcd_bl`/`lcd_clk`/`lcd_rst`、`touch_scl`/`touch_sda`(inout)/`touch_rst_n`/`touch_int`，以及音频六根 `aud_bclk`/`aud_dac_lrc`/`aud_dacdat`/`aud_mclk`/`aud_iic_scl`/`aud_iic_sda`。

`.xdc` 要点：全部 `LVCMOS33`；`lcd_rgb`、`touch_scl`/`touch_sda`、`aud_iic_scl`/`aud_iic_sda` 必须声明为 **inout**（开漏/双向）；`aud_mclk` 是**输出**（是 `mmcm_lcd_clk` 出片）；`aud_adc_lrc`(L20) 与 `aud_adcdat`(M17) **不声明也不约束**——`nes_audio_i2s` 是发送专用，ADC 通路没有逻辑，不发明；touch 的 I2C（R19/P20）与 codec 的 I2C（E18/F17）是**两条不同的物理总线**，codec 那条还与板载 EEPROM/RTC 共享。时钟约束：`sys_clk` 20 ns、`lcd_clk` 40 ns 各有 `create_clock`；**`core_clk` 故意没有** `create_clock`（它是 MMCM 内部输出，Vivado 从参数自动派生，再加一个会引入相互竞争的两个真值源）；`aud_bclk` 用 `create_generated_clock -source u_audio_i2s/bclk_int_reg/C -divide_by 16`（640 ns = 1.5625 MHz）。

---

## 9. 明确未实现 / 未建模

- **没有块 RAM 之外的大容量存储。** 本项目里唯一承载卡带内容的是 `nes_cart_rom` 的 BRAM（PRG 128 KiB + CHR 8 KiB），内容随位流一同出厂。
- **没有 TF / SDRAM。** 板级 TF 卡与 QSPI flash 在 PS 的 MIO 引脚上，**从 PL 不可达**；不能进位流的 ROM 就是 PL 看不到的 ROM（`nes_cart_rom.v` 文件头）。
- **音频没有完整抗混叠。** 是 4/4/2 三级短滑动平均 + 有理抽取，**不是 16 抽头 FIR**；要 20 kHz 内 −40 dB 需要另做（第 6.3 节）。
- **EP4CE10 与 Zynq 的实现不同，不是同一份顶层的移植。** `docs/hardware/13-platform-top.md` 描述的 EP4CE10 平台用 `altpll`（不是 MMCM）、用行缓冲双 bank 乒乓解耦 NTSC/VGA（不是双口 `frame_mem`）、音频只把 `audio_valid`/`audio_left` 原样送出而**没有抽取器/I2S/WM8960 通路**、也没有触摸 lane。Zynq 顶层的 `nes_zynq_clk.v` 与本顶层是新写的，不是 `nes_ep4ce10_top.v` 的改名。
- **没有上板综合 / 时序 / 功能验收证据，仓库自身的可复现门禁只有 Icarus TB。** `tools/sim_all.ps1` 里与本平台相关的只有三个仿真目标（见第 10 节）；本仓库内**没有**随提交的 Vivado 工程、位流或上板照片。XDC 里出现的资源与时钟测量数字（例如 40424/53200 LUT、`mmcm_core_clk` WNS +1.606、50 Block RAM Tile）来自**仓库外的临时 Vivado 工程**（`D:\vivadoProject\...`），不能从提交内容复现，只作旁证。
- **XDC 里成组的 CDC 约束是 `set_max_delay -datapath_only`，不是 `set_false_path`，也不是 `set_clock_groups -asynchronous`。** 理由（XDC 头）：`mmcm_core_clk` 由 `sys_clk` 经同一个 MMCM 派生，两时钟**并非异步**，声明异步是关于硬件的假陈述；而无界的 false path 正是"同步器两级被摆到芯片两侧"的成因。`-datapath_only` 保住物理延迟上限、去掉无意义的建立检查，且只作用于"源 → 第一级"，第二级仍是同域正常时序。每条边界绑到两周期里更紧的那个（按钮 20 ns、FIFO 40 ns）。
- **I/O 时序有意未约束。** `check_timing` 报 `sys_rst_n` 无输入延迟、27 个端口无输出延迟（`lcd_rgb`/`lcd_de`/`touch_scl`/`touch_sda` 等）；面板 DE 模式与触摸 I2C 的建立保持需要真实数据手册数字，**不猜**——编造会得到看起来权威、实际不成立的报告。同一缺口也存在于音频引脚。
- **音频 `bclk` 域仍是未完全分析的区域。** `bclk` 由 `nes_audio_i2s` 用时钟使能对 `mclk` 分频得到（不是 BUFGCE/ClockWizard 输出），Vivado 会命名该域但不为其建发射/捕获要求，故 `check_timing` 还留 3 个无时钟寄存器和 6 个未约束引脚。**不用 false path 压制**，因为那会隐藏真实的未分析区；该域是全设计最慢时钟（640 ns），这些弧先天有整周期裕量。真正修复属于 `nes_audio_i2s`（换 BUFGCE）。
- **LCD 刷新率是未决设计选择。** 当前 25 MHz / 45.1 Hz；换 60 Hz（33.264 MHz）必须重跑 m/k 推导并同改 `CLKOUT0_DIVIDE_F` 与 XDC 周期（第 2 节）。
- **第二个 NES controller 不存在。** `buttons2` 恒 `8'h00`；核内部自带完整的 `$4016/$4017` 位移序列，本顶层**不再**实例化第二个 `nes_controller`（会双驱 `controller_data`）。

---

## 10. 证据入口

`tools/sim_all.ps1` 里与本平台相关的目标：

| 目标 id | 内容 | 组 | `Run` |
| --- | --- | --- | --- |
| `zynq-clk-tb` | `tb/platform/tb_nes_zynq_clk.v`（Verilog-2012） | platform | `$true` |
| `zynq-top-tb` | `tb/platform/tb_nes_zynq_top.v`（Verilog-2012） | platform | `$true` |
| `audio-lane-tb` | `tb/peripheral/tb_nes_audio_lane.v`（decimator + I2S + WM8960 I2C） | peripheral | `$true` |

`.\tools\sim_all.ps1 -Mode all` 是权威门禁，本平台以这三个目标为回归保护（`-Mode platform` 只覆盖前两个）。

三个 testbench 各自钉住的东西：

- **`tb_nes_zynq_clk`**：`MMCME2_BASE` 不能被 Icarus 仿真，所以 DUT 在非 `SYNTHESIS` 分支例化本文件底部的行为模型 `mmcm_e2_base_sim`，它**从 DUT 自己的参数算输出周期**（参数错就表现为测出的频率错，而不是静默 elaborate 成功）。断言：`rst_in` 高时 `locked` 低且两输出恒 0；`locked` 只在建模稳定时间后、并在其后 8 个输入周期内拉高；`locked` 前两时钟**一个沿都不产生**；`core_clk` 在 21.477272727 MHz、`lcd_clk` 在 25 MHz 的 100 ppm 内；分频算术精确到 1e-12；VCO 在 600..1200；乘数与两个 CLKOUT 分频都是 0.125 的整倍数；`core_clk/4` 是 NTSC dot 率 5.369318 MHz；第二次复位脉冲再次拉低 `locked` 并停钟，重锁后频率不变。
- **`tb_nes_zynq_top`**：只证明"只在顶层存在"的四件事——三域确是三个域且比例正确（复用上文的 MMCM 模型算真实帧周期）、复位网（三链独立、异步断言、同步释放、`locked` 门控）、面板两根引脚（`lcd_rst` 上电拉低再释放，`lcd_bl` 不早于它）、两张转换表（64 项调色板 LUT 与 RGB565→RGB888 **穷举全部 65536 个 16 位字**）与 `lcd_rgb` 三态、按钮 2-FF 跨域、触摸 lane（行为 GT9147 从机 ACK + 整段运行监控开漏契约）。另有帧率比 `core_period/lcd_period = 0.7503`（= 16.6379/22.1760 ms）作端到端 sanity。调色板还叠一层**独立锚点**（$0F 是黑、$20/$30 是白、$16 橙、$26 鲑红 …），避免只是"两份转写互相印证"。
- **`tb_nes_audio_lane`**：整条音频 lane（decimator + `nes_audio_i2s` + `wm8960_i2c`），并在真实引脚上测到 640 ns 的 BCLK 周期。

以上全部是**仿真**证据；上板综合、时序收敛与功能验收不在本仓库内（第 9 节）。

---

## 11. 与其他章节的关系

- 时钟来源与误差（EP4CE10 的 altpll 方案）：`docs/hardware/13-platform-top.md`、`docs/hardware/12-ntsc-clock-and-pll.md`。
- 音频 FIFO（格雷码指针、满/空判据、独立复位）：`docs/modules/cdc-fifo.md`。
- I2S 位流与组装层（32 `ce` 沿、`rd_clk`/`mclk` 同网、一位延迟）：`docs/modules/i2s-audio.md`。
- WM8960 控制字（7 位地址 + 9 位数据、上电表）：`docs/modules/wm8960-i2c.md`。
- NES 核与控制器位序：`docs/modules/system-v6.md`、`docs/modules/controller.md`。
- 尚未存在的模块文档：`docs/modules/touch-input.md`、`docs/modules/cart-rom.md`、`docs/modules/video-800x480.md`，本文对应内容以 `rtl/nes_core/peripheral/nes_touch_input.v`、`rtl/nes_core/cart/nes_cart_rom.v`、`rtl/nes_core/video/nes_video_800x480.v` 的文件头为准。
