# 64 平台顶层精读：`nes_zynq_top.v`（多时钟域整机接线层）

这是本教程的最后一篇，也是**最大的一份 RTL**（约 55 KB）：Zynq-7020 平台的整机顶层。前面每一篇都在讲"一个模块内部怎么算"，这一篇反过来讲**"模块之间怎么接"**——它自己几乎不做运算，却要负责两件没有任何子模块能负责的事：**时钟树**和**复位网**，外加把核、卡带、视频、音频、触摸五条通路接起来。

- 源码：[`rtl/platform/zynq/nes_zynq_top.v`](../../rtl/platform/zynq/nes_zynq_top.v)
- 合同与证据：[`../modules/zynq-platform.md`](../modules/zynq-platform.md)
- 测试目标：`zynq-top-tb`（[`tb/platform/tb_nes_zynq_top.v`](../../tb/platform/tb_nes_zynq_top.v)）、`audio-lane-tb`（[`tb/peripheral/tb_nes_audio_lane.v`](../../tb/peripheral/tb_nes_audio_lane.v)）
- 前置：[`41-zynq-clk.md`](41-zynq-clk.md)（时钟从哪来）、[`38-video-800x480.md`](38-video-800x480.md)、[`39-audio-i2s.md`](39-audio-i2s.md)、[`40-wm8960-i2c.md`](40-wm8960-i2c.md)、[`56-touch-input.md`](56-touch-input.md)、[`62-system-mapper.md`](62-system-mapper.md)（核内子系统）

> 这一篇**不逐行讲完**一个 55 KB 的文件。目标是讲透四件事：**时钟树、复位网、三条跨域边界、五个子系统的接线**。调色板那 64 行 `case`、抽取器里每一级的位宽，只需要知道"它为什么在那里"。

---

## 1. 先认识"上游和下游"

```text
 50 MHz (U18) ─┐
 sys_rst_n ────┤ nes_zynq_clk (MMCM) ── core_clk 21.477272727 MHz ─► nes_system_v6 (CPU/PPU/APU + PRG cart)
               │                        lcd_clk  25 MHz ────────────► nes_video_800x480 读口 / nes_audio_i2s 读侧
               └─────────────────────── locked ─────────────────────► 复位网

 nes_system_v6 ──(像素, core_clk)──► 流水线寄存器 + palette LUT ──► nes_video_800x480 写口 ──frame_mem──► 面板引脚
 nes_system_v6 ──(audio_valid/left/right, core_clk)──► 抽取器 4/4/2+2016/55 ──► nes_audio_i2s ──► WM8960
 u_cart_chr (CHR only) ◄──ce_ppu/chr_addr── nes_system_v6
```

- **上游**：50 MHz 板载晶振（`U18`）+ 低有效复位 `sys_rst_n` + 板上按键，以及一块电容触摸屏。
- **本顶层**：**时钟树 + 复位网 + 接线**。它不实现 CPU、不实现 PPU，只把各子系统按正确的时钟域和复位连起来，并在少数"只在此层存在"的地方补逻辑（调色板表、面板复位/背光计数器、跨域同步器）。
- **下游**：LCD 面板引脚（`lcd_*`）、触摸面板 I2C（`touch_*`）、codec 音频引脚（`aud_*`）。

它和前面 63 篇最本质的区别是：**一个模块一个时钟**的铁律在这里被打破。这里有**三个时钟域**，所以必须显式处理"数据怎么从 A 域进 B 域"。

---

## 2. 骨架代码（不是全文）

顶层代码可分成"骨架"和"例化"两类。骨架是它真正拥有的逻辑，下面按主题给关键片段。

### 2.1 时钟树（唯一的时钟来源）

```verilog
wire mmcm_lcd_clk, mmcm_core_clk, mmcm_locked;

nes_zynq_clk u_clk (
    .clk_in (sys_clk), .rst_in (!sys_rst_n),
    .lcd_clk(mmcm_lcd_clk), .core_clk(mmcm_core_clk), .locked(mmcm_locked)
);

assign lcd_clk = mmcm_lcd_clk;   // 面板点时钟 = 25 MHz MMCM 输出
```

`nes_zynq_clk` 的推导见 [`41-zynq-clk.md`](41-zynq-clk.md)：一颗 MMCM 从 50 MHz 造出精确的 `core_clk`（`945/44 MHz`）和 `lcd_clk`（25 MHz）。

### 2.2 复位网（三域各一条链）

```verilog
(* MAX_FANOUT = 32 *) reg [1:0] rst_sys_q, rst_core_q, rst_lcd_q;

always @(posedge sys_clk or negedge sys_rst_n)
    if (!sys_rst_n) rst_sys_q <= 2'b11;
    else            rst_sys_q <= {rst_sys_q[0], 1'b0};
// rst_core_q / rst_lcd_q 同理，只是时钟换成 mmcm_core_clk / mmcm_lcd_clk

// locked 各域两级同步
always @(posedge sys_clk or negedge sys_rst_n)
    if (!sys_rst_n) begin locked_sys_q0 <= 1'b0; locked_sys_q1 <= 1'b0; end
    else begin locked_sys_q0 <= mmcm_locked; locked_sys_q1 <= locked_sys_q0; end
// core / lcd 同理

wire rst_sys  = rst_sys_q[1]  | ~locked_sys_q1;
wire rst_core = rst_core_q[1] | ~locked_core_q1;
wire rst_lcd  = rst_lcd_q[1]  | ~locked_lcd_q1;
```

三个复位**高有效**（`1` = 处于复位）。

### 2.3 三条跨域边界

```verilog
// ① 触摸按键：sys_clk -> core_clk，两级同步器
(* ASYNC_REG = "TRUE" *) reg [7:0] btn_meta_q, btn_sync_q;
always @(posedge mmcm_core_clk or negedge sys_rst_n)
    if (!sys_rst_n) begin btn_meta_q <= 8'h00; btn_sync_q <= 8'h00; end
    else            begin btn_meta_q <= touch_buttons; btn_sync_q <= btn_meta_q; end
```

② `frame_mem`（在 `nes_video_800x480` 内）：写口 `core_clk`、读口 `lcd_clk`，是一块**真双口 RAM**，跨界**不花任何逻辑**。
③ 音频样点 FIFO（在 `nes_audio_i2s` 内）：同样是双时钟 RAM，但它是**真双时钟 FIFO**（格雷码指针 + 两级同步器），确实含 `core_clk -> lcd_clk` 的触发器弧，由 XDC 用 `set_max_delay -datapath_only` 绑住。

### 2.4 音频 lane

```verilog
// cfg_done 各自两级同步进两域，或进复位
wire rst_audio_wr = rst_core | ~codec_cfg_core_q1;
wire rst_audio_rd = rst_lcd  | ~codec_cfg_lcd_q1;

// 精确有理抽取：2016 进、55 出
wire rat_hit = ma3_vld && ((rat_acc + 7'd55) >= 7'd63);
// ma1(4tap,/4) -> ma2(4tap,/16) -> ma3(2tap+2选1,/32) -> rat_hit

nes_audio_i2s #(.BCLK_DIV(16), .ADDR_WIDTH(6), .BIT_REVERSED(0)) u_audio_i2s (
    .wr_clk(mmcm_core_clk), .wr_reset(rst_audio_wr), .wr_en(dec_valid),
    .wr_left(dec_left), .wr_right(dec_right),
    .rd_clk(mmcm_lcd_clk), .rd_reset(rst_audio_rd),
    .mclk(mmcm_lcd_clk), .rd_ce(i2s_rd_ce),
    .bclk(aud_bclk_i), .lrck(aud_lrck_i), .dout(aud_dout_i)
);
```

### 2.5 各子系统例化（片段）

```verilog
nes_cart_rom #(.PRG_ENABLE(0), .CHR_ENABLE(1), .CHR_INIT_FILE(CHR_INIT_FILE)) u_cart_chr (
    .clk(mmcm_core_clk), .reset(rst_core), .prg_en(1'b0), .prg_rdata(),
    .ce_ppu(core_ce_ppu), .chr_addr(core_chr_final_addr), .chr_rdata(chr_rdata));

nes_system_v6 #(.PRG_INIT_FILE(PRG_INIT_FILE)) u_core (
    .clk(mmcm_core_clk), .reset(rst_core), .buttons1(btn_sync_q), .buttons2(8'h00), ...);

nes_video_800x480 u_video (.wr_clk(mmcm_core_clk), .rd_clk(mmcm_lcd_clk), .ce(1'b1), ...);

nes_touch_input #(.CT_COORD_REG(CT_COORD_REG)) u_touch (
    .clk(sys_clk), .reset(rst_sys), .key0(key[0]), .key1(key[1]), .buttons(touch_buttons), ...);
```

---

## 3. 逐段精读

### 3.1 三个时钟域各挂什么

| 域 | 频率 | 来源 | 挂什么 |
| --- | ---: | --- | --- |
| `sys_clk` | 50 MHz | 板载晶振 **U18**（顶层直接输入） | `nes_touch_input`；`wm8960_i2c` codec 配置；`lcd_rst`/`lcd_bl` 上电计数器；`locked`/`cfg_done` 同步器 |
| `core_clk` | 21.477272727 MHz | MMCM **CLKOUT1** | `nes_system_v6`（CPU/PPU/APU/bus/mapper）；`nes_cart_rom` CHR 半边；音频抽取滤波器；调色板 LUT（组合）；`nes_video_800x480` 写口；像素流水线寄存器 |
| `lcd_clk` | 25 MHz | MMCM **CLKOUT0** | `nes_video_800x480` 读口；`nes_audio_i2s` 读侧与 bclk（`rd_clk = mclk = lcd_clk`）；RGB565→RGB888（组合）；`lcd_*` 面板引脚；`aud_mclk` |

1. **`lcd_clk` 是一个数据输出，不是第四个域。** `assign lcd_clk = mmcm_lcd_clk;`，面板的 `lcd_de`/`lcd_rgb` 就寄存在同一个网上。
2. **25 MHz 不是 21.477 MHz 的整数倍**，所以面板输出级**不能**用 `core_clk` 加 `ce` 生成（`ce` 只能整数分频）。像素必须踩真实的 25 MHz 边沿离开，这也是"像素流必须跨域"的根本原因。

### 3.2 复位网：异步断言、同步释放、`locked` 参与

每个域一条链，形状完全一样。以 `sys_clk` 域为例：

```verilog
always @(posedge sys_clk or negedge sys_rst_n)
    if (!sys_rst_n) rst_sys_q <= 2'b11;
    else            rst_sys_q <= {rst_sys_q[0], 1'b0};
```

拆开读：

- 敏感列表里有 `negedge sys_rst_n` → **异步断言**：板级 `sys_rst_n` 一拉低，复位**瞬间**生效，不等时钟。这很关键，因为复位时时钟可能还没起振。
- 释放走两级移位：`2'b11 -> 2'b10 -> 2'b00`（`{rst_sys_q[0], 1'b0}` 是左移、低位补 0）。所以 `sys_rst_n` 释放后还要**两个时钟沿**才真正解除，这叫**同步释放**——保证解除时刻对齐时钟沿，避免"半边复位"。
- 三域各有自己的 `rst_*_q` 寄存器，**互不共享**，各自输出高有效。

`locked` 怎么参与：

```verilog
wire rst_sys = rst_sys_q[1] | ~locked_sys_q1;
```

`locked` 是 MMCM 的"锁好了"指示。VCO 稳定前 `LOCKED` 无效、输出时钟不可用，所以**核必须在 `locked` 为高之前一直按在复位里**。这里把 `~locked_q1` 或进复位：`locked` 低 → 复位为 1。

- `core_clk`/`lcd_clk` 本来就要 `locked` 之后才有时钟沿，所以这两域那些"异步断言"的触发器**只是保持复位直到自己的时钟起振**——这正是要求的行为：核不会在一根还在爬升的时钟上开始计数。
- `MAX_FANOUT = 32` 是**综合指令**：不加它，`opt_design` 会用**一个**触发器驱动整域的异步清零，路由极长；加它才会复制驱动器、搭一棵复位树。它不改变行为，也不是时序例外。

音频域在复位链上**再加一层限定**，见 3.6。

### 3.3 跨域一：触摸按键（两级同步器）

```verilog
(* ASYNC_REG = "TRUE" *) reg [7:0] btn_meta_q, btn_sync_q;
always @(posedge mmcm_core_clk or negedge sys_rst_n) begin
    if (!sys_rst_n) begin btn_meta_q <= 8'h00; btn_sync_q <= 8'h00; end
    else            begin btn_meta_q <= touch_buttons; btn_sync_q <= btn_meta_q; end
end
```

- `touch_buttons` 在 50 MHz（`sys_clk`）域产生，核心却在 21.477 MHz（`core_clk`）域读它。如果核直接采，可能正好采在它跳变的瞬间，得到**亚稳态**（既不是 0 也不是 1 的中间电平）——核里的 `$4016` 移位序列**不能容忍**这种情况。
- 两级触发器（`btn_meta_q` 是第一级、`btn_sync_q` 是第二级）让第一级先"不确定"，第二级再采一个稳定的值，把亚稳态概率压到极低。`ASYNC_REG = "TRUE"` 告诉工具把这两级摆在一起。
- 这是本设计**唯一**非像素的 `sys_clk -> core_clk` 跨域路径。XDC 对这条弧下 `set_max_delay -datapath_only 20.000`（两个最紧周期里较紧的那个）。

### 3.4 跨域二：`frame_mem`（真双口 BRAM，零逻辑跨界）

视频帧缓冲 `frame_mem` 在 `nes_video_800x480` 里面（见 [`38-video-800x480.md`](38-video-800x480.md)）：写口 `core_clk`、读口 `lcd_clk`，是一块**真双口 RAM**。

跨域**不花任何逻辑**：没有同步器、没有 toggle、没有握手、没有背压（文件头原文）。原因是 RAM 的写侧和读侧各自用**自己的时钟和地址**，二者从不"比较"，所以没有需要同步的信号。代价是缓冲是**单缓冲**的：同周期同地址读写返回旧值（BRAM read-first）。

### 3.5 跨域三：音频样点 FIFO（格雷指针 + 两级同步 + XDC 约束）

`nes_audio_i2s` 里的 `nes_cdc_fifo` **也是**双时钟 RAM，但它比 `frame_mem` 多了一件必须做的事——**判断空/满**：

- 写侧要知道 FIFO 满没满、读侧要知道空没空，这就要**跨域读对方的指针**。
- 指针直接跨域会采到"半新半旧"，所以用**格雷码**（相邻值只差 1 位，跨域最多错一位）**+ 两级同步器**。因此它**确实含** `core_clk -> lcd_clk` 的触发器弧。
- 这些弧用 XDC 的 `set_max_delay -datapath_only 40.000` 绑住（写指针弧、读指针弧，以及容易被漏掉的第 3 组：FIFO 存储读出 mux → 读数据寄存器）。

所以三条跨域边界的手段各不相同：**单比特/慢变信号用两级同步器，纯搬运用真双口 RAM 零逻辑，需要握手的水位用格雷 FIFO**。

### 3.6 音频 lane：每一处"差不多"都被精确匹配逼成"必须精确"

音频通路是 `core_clk -> 抽取器 -> nes_audio_i2s FIFO -> I2S 移位器 -> wm8960_i2c -> WM8960 引脚`。文件头逐条推导了四个不显然的点：

**① `audio_sample_valid` 不是音频采样率。** 核里 `ce_sample = 1'b1`，APU 在 `ce && ce_sample` 上发 `sample_valid`，而 `ce = ce_cpu` 是 12 个核时钟里 1 个。所以这个 strobe 速率是

```
21477272.727 / 12 = 1789772.727 Hz   （约 1.789 MHz）
```

这是 APU 的**自然速率**，比可用的音频采样率高约 37 倍。直接喂进 I2S 移位器就是"用 1.79 MHz 串噪声"。

**② 为什么 /37 不可用。** `1789772.727 / 37 = 48372.235 Hz`，比 48000 高 `101/13024 = 0.7755%`。误差不是音质问题，而是**可用性**问题：抽取器与 I2S 移位器之间是单生产者单消费者 FIFO，**任何**速率失配都会让水位一路走到满（丢样）或走到空（underflow）。0.78% 的失配约 **26 秒**就能填满一个 1024 项 FIFO。

与 25 MHz 侧帧率**精确匹配**的唯一整数抽取是 `/126`（14204 Hz，奈奎斯特只有 7.1 kHz，差得没法用）。算术：移位器每立体声样点出 `16 + 16` 位、一位一个 BCLK，一帧 32 BCLK，帧率 `25e6/(32*D)`（`BCLK_DIV = D`），与 strobe 速率之比是

```
(19687500/11) * (32*D/25000000) = 126*D/55
```

要取整必须 `55 | D`，只有 `D = 55`（得 14204.5 Hz）；合理选择 `D = 16` 得 `126*16/55 = 2016/55 = 36.6545...`，**不是整数**。于是抽取是**有理的 2016/55**，用**精确 Bresenham 累加器**实现：2016 个输入进、55 个输出出，永不累积误差——累加器是有界整数，状态只取决于已见样点计数。

```verilog
wire rat_hit = ma3_vld && ((rat_acc + 7'd55) >= 7'd63);
...
rat_acc <= rat_hit ? ((rat_acc + 7'd55) - 7'd63) : (rat_acc + 7'd55);
```

**③ 为什么不是 /37 箱式平均，而是 4/4/2 三级滑动平均。** 固定长度的箱式平均只有除以整数长度才有 unity 增益，而有理比值下平均长度在 1 与 2 之间交替，**不存在固定增益**；而且 37 抽头滑动平均的第一个零点在 `1789772/37 = 48.4 kHz`，对真正会折叠进输出的 24 kHz 带几乎无衰减。实际用三级短滑动平均 **4、4、2** 抽头串联，零点落在 **447 kHz、447 kHz、894 kHz**，都在输入带内、远高于音频带：帧率处约 0.35 dB，700 kHz 处约 −33 dB，而 DC 增益精确为 1（末级除以 `4*4*2 = 32`）。实现有个坑：第三级 `ma3_tog` 必须是 **1 bit**，写成 2 bit 会变成再除以 2，总比立刻配不上 63/55。

**④ 为什么 `rd_clk` 与 `mclk` 是同一个网。** `nes_audio_i2s` 在 `posedge bclk` 上采 `sh_out_bit`/`sh_out_lrck`，**不加同步器**，是从 `rd_clk` 域跨进 `mclk` 派生域。若两者是无关网络，这就是**未同步的两比特跨越**。把两者都接到 `mmcm_lcd_clk`，`bclk` 就成了同一时钟的分频版本，采样沿与驱动沿**相位相关**，每一位在整整一个 BCLK 周期（8 个 `lcd_clk`）内保持稳定。副作用：读侧仍在 `lcd_clk` 域，`mclk` 也不是新时钟。

**⑤ 帧率、BCLK 与 codec 自己的 PLL。**

```
BCLK_DIV = 16 -> BCLK = 25e6/16 = 1.5625 MHz，fs = 1.5625e6/32 = 48828.125 Hz
             = 1789772.727 * 55/2016   （逐位相等，FIFO 水位不会走动）
```

WM8960 被自己的 PLL 告知按 `48828.125 Hz` 采样，源是 25 MHz 的 MCLK：`f1 = 25/2 = 12.5 MHz`、`R = PLLN = 8`、`f2 = 100 MHz`（PLL VCO）、`SYSCLK = 12.5 MHz`、`fs = SYSCLK/256 = 48828.125 Hz`。`PLLK = 0` 所以没有小数分频抖动。替代方案（加第三路 MMCM 输出 12.288 MHz 得精确 48 kHz）会重新打开核时钟推导，为 0.78% 的采样率得不偿失。

**音频域复位限定 `cfg_done`：**

```verilog
wire rst_audio_wr = rst_core | ~codec_cfg_core_q1;
wire rst_audio_rd = rst_lcd  | ~codec_cfg_lcd_q1;
```

`wm8960_i2c` 在 `sys_clk` 上走 15 项上电表，约 4.6 ms 后拉高 `cfg_done`。FIFO 两端都不能在它之前跑：`nes_audio_i2s` 在复位时锁存 `rd_empty` 并把 `underflow` **粘滞**点亮，读侧提前放行会让它整个运行期都报 underflow，还会向仍处于上电默认态的 codec 送 BCLK。所以 `cfg_done` 各自两级同步进两域，再或进复位。

### 3.7 触摸例化

`nes_touch_input` 跑在 `sys_clk`，把 GT9147 电容屏变成 NES 手柄（详见 [`56-touch-input.md`](56-touch-input.md)）：

```verilog
nes_touch_input #(.CT_COORD_REG(CT_COORD_REG)) u_touch (
    .clk(sys_clk), .reset(rst_sys),
    .key0(key[0]), .key1(key[1]), .touch_key(touch_key),
    .buttons(touch_buttons), .dpad(touch_dpad), ...
);

assign touch_scl   = touch_scl_o ? 1'bz : 1'b0;   // 开漏：拉低或高阻
assign touch_sda   = touch_sda_oe ? touch_sda_o : 1'bz;
assign touch_sda_i = touch_sda;
assign touch_rst_n = ct_rst_n;
```

I2C 是**开漏**：控制器只会"拉低"或"释放"，绝不主动驱动高（推挽会烧总线）。`touch_scl`/`touch_sda` 是**真 inout**。板载两个 PL 键 `key[1:0]`（低有效）和第三个离散按钮 `touch_key`（高有效）都进这个模块，由它统一处理极性与消抖。自校准读出的 `touch_x_max`/`touch_x2y` 等是**顶层内部 wire，没有引出为端口**（只在仿真里读，Vivado 会把无用网折掉）。

### 3.8 卡带：CHR-only 在顶层，PRG 在核内

```verilog
nes_cart_rom #(.PRG_ENABLE(0), .CHR_ENABLE(1), .CHR_INIT_FILE(CHR_INIT_FILE)) u_cart_chr (
    .clk(mmcm_core_clk), .reset(rst_core),
    .prg_en(1'b0), .prg_addr(17'd0), .prg_rdata(),   // PRG 半边不造
    .ce_ppu(core_ce_ppu), .chr_addr(core_chr_final_addr), .chr_rdata(chr_rdata), ...
);
```

- 顶层只造 **CHR 半边**（8 KiB 图形 ROM）。**PRG 半边在 `nes_system_v6` 内部**再实例化一次（`PRG_ENABLE=1`、`CHR_ENABLE=0`），所以 8 KiB CHR 阵列不会造两遍。
- `ce_ppu` **逐字使用核导出的信号、绝不重新生成 `div_phase`**：`nes_cart_rom` 的 CHR 读路径对相位敏感，重生成的 `div_phase` 若差 1..3 拍，会在错误的 `ce_ppu` 沿锁存 `chr_addr`，静默返回上一个图案字节。
- ROM 内容来自 `$readmemh` 读的 hex 文件（`PRG_INIT_FILE`/`CHR_INIT_FILE`，默认是占位文件）。`$readmemh` 的相对路径是相对**仿真器/Vivado 的工作目录**，不是源文件目录，所以 `tools/sim_all.ps1` 会先切到仓库根目录。

### 3.9 视频：`nes_video_800x480` + RGB565→RGB888

```verilog
nes_video_800x480 u_video (
    .wr_clk(mmcm_core_clk), .rd_clk(mmcm_lcd_clk), .ce(1'b1),
    .in_valid(vid_we_q), .in_x(vid_in_x_q), .in_y(vid_in_y_q), .in_rgb565(vid_in_rgb_q),
    .rgb565(vid_rgb565), .de(vid_de), .hsync(vid_hsync), .vsync(vid_vsync), ...
);

wire [7:0] lcd_r8 = {vid_rgb565[15:11], vid_rgb565[15:13]};
wire [7:0] lcd_g8 = {vid_rgb565[10:5],  vid_rgb565[10:9]};
wire [7:0] lcd_b8 = {vid_rgb565[4:0],   vid_rgb565[4:2]};
assign lcd_rgb = vid_de ? {lcd_r8, lcd_g8, lcd_b8} : 24'hz;
```

- 写口 `core_clk`、读口 `lcd_clk`，`ce` 恒 1（光栅每个 `lcd_clk` 一个 dot，就是 25 MHz）。
- PPU 与写口之间有**两级流水寄存器**，64 项调色板 LUT 夹在两级之间（这样 LUT 落在两个寄存器之间，不在 PPU 组合输出上）。写选通是 `core_ce_ppu && core_pixel_valid`：`core_pixel_valid` 是**电平**（一个 dot 持续 4 个核时钟），而写口在每个 `wr_clk` 沿只要 `in_valid` 高就写，所以要靠 `ce_ppu` 收敛成**每 dot 一拍**。
- RGB565→RGB888 用**全长位复制**：`{r5, r5[4:2]}`、`{g6, g6[5:4]}`、`{b5, b5[4:2]}`，所以 0→0、满→满、每通道单调，白不会变灰。`lcd_rgb` 双向，仅在 `vid_de` 高时驱动（面板复位期间厂商要在这几根线上读面板 ID）。

### 3.10 调色板 LUT

```verilog
function [15:0] pal_to_rgb565;
    input [5:0] idx;
    begin case (idx)
        6'h00: pal_to_rgb565 = 16'h632C;  // 66 66 66
        6'h0F: pal_to_rgb565 = 16'h0000;  // blanking entry, black
        6'h20: pal_to_rgb565 = 16'hFFFF;  // FF FF FF
        ...
        default: pal_to_rgb565 = 16'h0000;
    endcase end
endfunction

wire [15:0] pal_rgb565 = pal_to_rgb565(core_pixel_pal[5:0]);
```

- `pixel_pal[7:0]` 是 PPU 存的原始字节，只有 `[5:0]` 索引进调色板（`[5:4]` 是色轴、`[3:0]` 是亮度轴）。64 项取自 cNES 参考表 `.slim/clonedeps/repos/caseif__cNES/src/ppu.c:94-111`，每项 `(r,g,b)` 用 `R5 = R8>>3`、`G6 = G8>>2`、`B5 = B8>>3` 转成 RGB565：红进 `rgb565[15:11]`、绿进 `[10:5]`、蓝进 `[4:0]`。
- 写成 **function** 而不是 `always` 块，是为了同一张表既能被调试口组合读，又能晚一级从流水寄存器里读。`$0F` 是消隐项所以是**黑**（不是白）；白是 `$20` 和 `$30`。
- 注意 `nes_line_buffer_vga.v` 里的色相扫描**不复用**——那是 hue sweep 不是 NES 调色板，会把 Mario 渲染成彩虹色。

### 3.11 明确未实现 / 未建模

- **片上没有 TF / SDRAM 之外的大容量存储。** 唯一承载卡带内容的是 `nes_cart_rom` 的 BRAM（PRG 128 KiB + CHR 8 KiB），内容随位流一同出厂。板级 TF 卡与 QSPI flash 在 PS 的 MIO 引脚上，**从 PL 不可达**；不能进位流的 ROM 就是 PL 看不到的 ROM。
- **音频不是完整的抗混叠 FIR。** 是 4/4/2 三级短滑动平均 + 有理抽取，**不是 16 抽头 FIR**；要在 20 kHz 内做到 −40 dB 需要另做（第 3.6 节）。
- **没有上板功能验收证据。** 仓库自身的可复现门禁只有 Icarus testbench（`zynq-top-tb`、`audio-lane-tb` 等）。仓库内**没有**随提交的 Vivado 工程、位流或上板照片；XDC 里的资源/时序数字来自仓库外的临时工程，只作旁证。
- **没有第二个 NES controller。** `buttons2` 恒 `8'h00`；核内部自带完整的 `$4016/$4017` 位移序列，顶层**不再**实例化第二个 `nes_controller`（会双驱 `controller_data`）。
- **XDC 里的 CDC 约束是 `set_max_delay -datapath_only`，不是 `set_false_path`。** `core_clk` 由 `sys_clk` 经同一个 MMCM 派生，两时钟**并非异步**，声明异步是关于硬件的假陈述。

---

## 4. 端口表

| 端口 | 方向 | 位宽 | 作用 |
| --- | --- | --- | --- |
| `sys_clk` | in | 1 | 50 MHz 板载晶振（`U18`） |
| `sys_rst_n` | in | 1 | 板级复位，**低有效** |
| `key` | in | 2 | 两个 PL 键，**低有效** |
| `touch_key` | in | 1 | 板载第三个离散按钮（TPAD），**高有效** |
| `lcd_rgb` | inout | 24 | 面板数据总线，双向（厂商在复位期读面板 ID），仅 `vid_de` 高时驱动 |
| `lcd_hs` / `lcd_vs` / `lcd_de` | out | 1 | 面板行/场同步与数据使能 |
| `lcd_bl` | out | 1 | 背光（上电计数到位才拉高） |
| `lcd_clk` | out | 1 | 面板点时钟（= `mmcm_lcd_clk`，25 MHz） |
| `lcd_rst` | out | 1 | 面板复位，**高 = 出复位**（上电先拉低再释放） |
| `touch_scl` / `touch_sda` | inout | 1 | 触摸面板 I2C，**开漏** |
| `touch_rst_n` | out | 1 | 触摸控制器复位（低有效） |
| `touch_int` | in | 1 | 触摸中断输入 |
| `aud_bclk` | out | 1 | I2S 位时钟（`25e6/16 = 1.5625 MHz`） |
| `aud_dac_lrc` | out | 1 | I2S 字时钟（LRCLK），低为左声道 |
| `aud_dacdat` | out | 1 | I2S DAC 数据，在 `bclk` 上升沿被 codec 采 |
| `aud_mclk` | out | 1 | codec 主时钟（就是 `mmcm_lcd_clk` 出片，25 MHz） |
| `aud_iic_scl` / `aud_iic_sda` | inout | 1 | codec 控制 I2C，**开漏**，与板载 EEPROM/RTC 共享 |

主要参数：`LCD_RST_HOLD_CYCLES = 5000`（100 µs 后释放面板复位）、`LCD_BL_ON_CYCLES = 20000`（400 µs 后才点背光，保证背光不在未复位面板上亮）、`PRG_INIT_FILE`/`CHR_INIT_FILE`（`$readmemh` 默认占位文件）、`CT_COORD_REG = 16'h8150`（触摸坐标寄存器，诊断用）。

---

## 5. 把两样东西各走一遍

### 5.1 一个音频采样：从 `core_clk` 到 codec 引脚

1. **APU 发声。** `nes_system_v6` 里的 APU（跑 `core_clk`）每 12 个核时钟发一次 `audio_sample_valid`（约 1.789 MHz），并给出 16 位 `audio_sample_left/right`。
2. **一级平均 `/4`。** 每个 `audio_sample_valid`，`ma1` 把左右各 4 个连续样点求和（18 位，不除），每 4 个输入产生一个 `ma1_vld`。
3. **二级平均 `/16`。** `ma2` 对 `ma1_sum` 再 4 抽头，每 4 个 `ma1_vld` 出 `ma2_vld`。
4. **三级平均 `/32`。** `ma3` 对 `ma2_sum` 做 2 抽头平均，并用 1 bit `ma3_tog` 每两个取一个 → `ma3_vld`。到此总速率 `/32`，DC 增益仍为 1（末级除 `4*4*2=32`，四舍五入加 16）。
5. **有理抽取 `2016/55`。** `rat_hit` 在累加器到达 63 时命中；每来一个 `ma3_vld` 累加 55，命中时减 63。63 次命中正好吃掉 2016 个输入 → `/32 × 55/63 = 55/2016`。命中时把 `(ma3_sum+16)>>5` 锁进 `dec_left/dec_right`。
6. **写进 FIFO。** `dec_valid` 拉高，`nes_audio_i2s` 在 `wr_clk = core_clk` 把样点写进 `nes_cdc_fifo`（格雷指针 + 两级同步）。
7. **读侧 = `lcd_clk` 域。** 读口 `rd_clk = mmcm_lcd_clk`，`mclk = mmcm_lcd_clk`（同一根线，见 3.6④）。`bclk` 由 `lcd_clk / 16` 得到，所以 `bclk = 1.5625 MHz`。
8. **串行化。** `nes_i2s_shifter` 在 `i2s_rd_ce`（`bclk` 上升沿）上每拍 shift 一位，一个立体声样点 32 位（16 左 + 16 右）。`aud_dout_i` 再加**一级 `bclk` 寄存器**（I2S 要求 MSB 在 LRCLK 跳变后的第二个上升 BCLK 沿可用）。
9. **出片。** `aud_bclk = aud_bclk_i`、`aud_dac_lrc = aud_lrck_i`、`aud_dacdat = aud_dout_d_q`、`aud_mclk = mmcm_lcd_clk`。
10. **codec 侧。** `wm8960_i2c`（`sys_clk` 域）早先用 I2C（`aud_iic_scl/sda`）把 15 项上电表写完并拉高 `cfg_done`；WM8960 用自己的 PLL 从 25 MHz MCLK 得到 `48828.125 Hz`，正好等于 `1789772.727 * 55/2016`，所以 FIFO 生产与消费**逐位相等**，水位不会随时间走动。

### 5.2 一个触摸事件：从 `sys_clk` 到 `core_clk`

1. **手指 → 面板。** 手指电容变化被 GT9147 捕获，它通过触摸 I2C（`touch_scl`/`touch_sda`，开漏）向 `nes_touch_input` 报告坐标与状态。
2. **模块解码。** `nes_touch_input` 跑 `sys_clk`，轮询坐标、一次性自校准、把坐标映射成 d-pad 方向，把 `key[1:0]` 与 `touch_key` 归到 A/B/Start/Select，最后输出 8 位 `touch_buttons[7:0]`。
3. **跨域采样。** `touch_buttons` 在 `sys_clk` 域。核心在 `core_clk` 域，用 `btn_meta_q`（第一级）先采它，再用 `btn_sync_q`（第二级）采第一级——把亚稳态概率压到极低。
4. **进核。** `btn_sync_q` 接到 `nes_system_v6.buttons1`（`buttons2` 恒 `8'h00`）。
5. **读手柄。** 核内部自带的 `$4016/$4017` 移位序列在每个 `ce_cpu` 上把 8 位串行移出，`controller_data` 汇入 `cpu_din`，6502 就能读到"哪个键被按了"。

按键电平是**人手速度**变化的（远慢于任一时钟），所以 8 位在 `$4016` 被读之前早已稳定；两级同步器处理的只是那一位跳变瞬间的亚稳态，不是多比特相干性问题。

---

## 6. 常见疑问

**Q：25 MHz 面板时钟为什么不能像别处那样用 `core_clk` 加 `ce`？**
A：`ce` 只能整数分频（`f/N`），而 `25 / 21.477272727` 不是整数。像素必须踩真实的 25 MHz 边沿离开，所以只能由 MMCM 另出一路，并让像素跨域。

**Q：为什么 `frame_mem` 跨域不用同步器，音频 FIFO 却要？**
A：`frame_mem` 是真双口 RAM，写侧和读侧**从不比较**任何信号（各自用自己的时钟和地址），所以没有需要同步的东西。音频 FIFO 要判满/空，必须**跨域比较对方的指针**，所以有触发器弧，要用格雷码 + 两级同步 + XDC 约束。

**Q：`rd_clk` 和 `mclk` 接同一根线不是"省事"吗？**
A：不是省事，是**必须**：`nes_audio_i2s` 在 `bclk` 上升沿采 `sh_out_bit`/`sh_out_lrck` 而没有同步器，只有让 `mclk` 与 `rd_clk` 同源，采样沿才与驱动沿相位相关、每一位才在一个 BCLK 周期内稳定。

**Q：`audio_sample_valid` 是 1.79 MHz，直接送 I2S 不行吗？**
A：不行。1.79 MHz 串出来是噪声；而且 1.79 MHz 与任何实用采样率都不精确匹配，FIFO 水位会一路走到满或空。

**Q：为什么不能用 `/37` 简单抽取？**
A：`1789772.727/37 = 48372.235 Hz`，比 48000 高 0.7755%。这个失配约 26 秒就能填满/抽干一个 1024 项 FIFO。授课里所有"精确相等"的要求都从这里来。

**Q：`cfg_done` 为什么也要进复位？**
A：FIFO 读侧提前放行会把 `underflow` **粘滞**点亮（整个运行期都报），还会向仍处于上电默认态的 codec 送 BCLK。所以两域各自同步 `cfg_done` 并或进复位。

**Q：`buttons2` 为什么恒 0？**
A：没有 player 2；而且核内自带完整 `$4016/$4017` 位移序列，顶层再实例化第二个 `nes_controller` 会双驱 `controller_data`、破坏每一次手柄读取。

---

## 7. 你应该带走的三件事

1. **顶层只拥有两样东西——时钟树和复位网——外加接线。** 凡是有运算能力的子模块都被单独 gate 过；顶层要保证的只是"谁跑哪个时钟、谁在什么时候出复位"。`zynq-top-tb` 也只测这些"只在此层存在"的东西。
2. **跨时钟域没有"免费"，只有三种明确手段。** 纯搬运用**真双口 RAM**（零逻辑，如 `frame_mem`）、慢变单比特用**两级同步器**（如触摸按键）、需要握手的多比特用**格雷码 FIFO + 两级同步 + XDC 约束**（如音频样点）。选错手段，症状不是立刻崩，而是偶尔采错一位或水位慢慢漂。
3. **"差不多"的时钟在硬件里会变成"慢慢坏"。** 音频链上每一处精确匹配（`2016/55`、`BCLK_DIV = 16`、25 MHz 与 codec PLL 逐位相等）都是被"FIFO 水位不能走动"逼出来的；`/37` 的 0.78% 误差 26 秒就出事。复位也同理：必须**异步断言、同步释放**，且被 `locked`/`cfg_done` 限定，否则核会在一根还在爬升的时钟上启动。

---

**这是本课程的最后一篇。** 想回到全局，请看 [`../README.md`](../README.md)（文档总索引）与 [`../modules/`](../modules/)（每个模块的接口合同、时序账、证据与未实现清单）——本目录负责"把代码翻译成人话"，那两个目录负责"写进设计时要拿什么当准绳"。
