# HDMI/DVI 发射子系统（`nes_video_hdmi` + `nes_hdmi_tx` + 编码器 + 串行器）：从 256×240 到 720×480p60 的 TMDS 对

本文说明 `rtl/nes_core/video/nes_video_hdmi.v`、`rtl/platform/zynq/nes_hdmi_tx.v`、`rtl/platform/zynq/nes_hdmi_tmds_encoder.v` 与 `rtl/platform/zynq/nes_hdmi_tmds_serializer.v` 四个模块的接口合同、双时钟结构、缩放算术与 TMDS 编码，外加 `nes_zynq_clk.v` 里的**第二个 MMCM** 和 `nes_zynq_top.xdc` 里的 `tmds_*` 引脚。它回答一个和 `video-800x480.md` 同源的教学问题：

> 板子上没有 HDMI 控制器、没有显存、没有视频引擎，只有一根 50 MHz 晶振。怎么把 PPU 的 256×240 像素变成连接器上的四对 TMDS 差分线？

结论：**分三件事，缺一不可**——(1) 用**第二个 MMCM** 从 50 MHz 造出 27.000 MHz 像素时钟与 135.000 MHz 5 倍串行时钟，因为核心 MMCM 的 1181.25 MHz VCO 到不了这两个频率；(2) 用 `nes_video_hdmi` 把 256×240 整帧缓冲按 CEA-861 480p 光栅读出来，跨域仍然只是"一块真双口 BRAM"；(3) 用 `nes_hdmi_tx` 把 RGB888 编成 DVI 1.0 的 8b/10b 符号并 10:1 串行化。行为权威是 **DVI 1.0 规范 3.1.3 节（图 3-5）** 与 **CEA-861 480p 时序**；HDMI 相对于 DVI 增加了音频、CEC、DDC/EDID 等，但 TMDS 编码与 DVI 同源。

> **本子系统的四个 RTL 文件在提交 `db4c3b5` 才接入 `nes_zynq_top`**，其中 `nes_hdmi_tx.v` 文件头"Integration. This module is deliberately not instantiated anywhere yet."这一段**写于接入之前，已被该提交推翻**；`nes_zynq_top.v` 现在有 `tmds_*` 端口并实例化 `u_hdmi_tx`。以下一切以当前 RTL 文件树为准。

![图 1：HDMI 发射通路](../figures/hdmi-path.svg)

**图 1** · HDMI 通路：两个 MMCM 与四条时钟、`core_clk` 写 / `hdmi_pclk` 读的跨域 `nes_video_hdmi`、TMDS 编码器到串行器到连接器，以及 DDC 不可用的原因。事实来源见 `docs/figures/README.md`。生成图，勿手改，见 [`../figures/`](../figures/) 图 1。

---

## 1. 四个模块的分工

| 模块 | 文件 | 时钟域 | 职责 |
|---|---|---|---|
| `nes_video_hdmi` | `rtl/nes_core/video/nes_video_hdmi.v` | 双时钟（`wr_clk`=core_clk，`rd_clk`=hdmi_pclk） | 256×240 → 720×480 缩放 + CEA-861 480p 光栅发生器 |
| `nes_hdmi_tx` | `rtl/platform/zynq/nes_hdmi_tx.v` | 双时钟（`pclk`，`pclk_x5`） | 顶层：3 个色道编码器 + 4 个串行器 + 复位同步 |
| `nes_hdmi_tmds_encoder` | `rtl/platform/zynq/nes_hdmi_tmds_encoder.v` | `pclk` | 一条色道的 DVI 1.0 8b/10b 编码（三寄存器级） |
| `nes_hdmi_tmds_serializer` | `rtl/platform/zynq/nes_hdmi_tmds_serializer.v` | `pclk` / `pclk_x5` | 一条 TMDS 差分对的 10:1 串行化（`OSERDESE2` 主从 + `OBUFDS`） |

数据流方向：`PPU 像素流 → 调色板 LUT（在顶层）→ u_video_hdmi 写口 → frame_mem → 读口 → RGB565→RGB888 → u_hdmi_tx → 4 × TMDS 对`。四个模块都没有"帧"这个概念被显式传递，只有 `nes_video_hdmi` 内的两块缓冲。

---

## 2. 时钟算术：为什么必须有第二个 MMCM

`nes_zynq_clk` 里现在有**两个** `MMCME2_BASE`（实例 `u_mmcm` 与 `u_mmcm_hdmi`）。第一个是既有的核/LCD 时钟源，第二个**只为 HDMI**存在，且它的参数**与第一个完全独立**，所以 `core_clk` 与 `lcd_clk` 与 HDMI 存在之前逐位相同。

### 2.1 核心 MMCM 到不了 27 MHz 和 135 MHz

既有推导（详见 `zynq-platform.md` 第 2 节与 `41-zynq-clk.md`）把 VCO 钉死在 **1181.25 MHz**（`CLKFBOUT_MULT_F = 23.625`、`DIVCLK_DIVIDE = 1`），因为只有这个 VCO 能让核时钟 `945/44 MHz` 落在整数分频 `CLKOUT1_DIVIDE = 55` 上。LOCK 之后：

- **唯一能分数分频的输出是 `CLKOUT0`**（`CLKOUT0_DIVIDE_F`），它**已经被 25 MHz LCD 时钟占用**（`1181.25/47.25`）。`CLKOUT1..6` 只接受**整数**分频。
- `1181.25 / 27 = 43.75`。43.75 本身是一个 0.125 的整倍数（350/8），**只有 CLKOUT0 的分数口能表达它**——但 CLKOUT0 已经给了 LCD。`CLKOUT1..6` 要 43.75 的整数分频，做不到。所以核心 MMCM **无法**输出 27 MHz。
- `1181.25 / 135 = 8.75`，也**不是整数**，同样落不到 `CLKOUT1..6`。

### 2.2 1280×720p60 也过不了这道算术

如果把 720p60 当作候选（判断见第 3 节），它的 5 倍串行时钟是 `74.25 MHz × 5 = 371.25 MHz`。核心 MMCM 要出 371.25 MHz 需要分频比

```
1181.25 / 371.25 = 3.1818... = 35/11
```

`35/11` **既不是整数**（`CLKOUT1..6` 不接受），**也不是 0.125 的整倍数**（`CLKOUT0_DIVIDE_F` 不接受；最接近的 0.125 步是 3.125 与 3.25）。这就是为什么"720p 更难"这一点不只是频率更高，而是**核心 MMCM 的 VCO 限制**。

### 2.3 第二个 MMCM：675 MHz VCO

换一个 VCO 重新解同一组方程。让**两个输出同时精确**——27 MHz 与 135 MHz——的 VCO 是 675 MHz：

```
f_vco = 50 × 13.5 / 1 = 675.000 MHz          (7 系列 MMCM VCO 范围 600..1200，合法)
CLKOUT0_DIVIDE_F = 675 / 27  = 25.0          → hdmi_pclk    = 27.000 MHz 精确
CLKOUT1_DIVIDE   = 675 / 135 = 5             → hdmi_pclk_x5 = 135.000 MHz 精确
```

`CLKFBOUT_MULT_F = 13.5`（= 108 × 0.125，在 2.0..64.0 内）、`CLKOUT0_DIVIDE_F = 25.0`（0.125 的整倍数）、`CLKOUT1_DIVIDE = 5`（整数 1..128）。**三个分频都没有取整**，所以两条时钟都是精确值。

`nes_zynq_clk.v` 文件头还记下了一条被交接给它的**内部矛盾推导**：原稿写 `VCO = 50 × 27 / 2 = 675 MHz`，又写 `CLKFBOUT_MULT_F = 27/2 = 13.5`、`DIVCLK_DIVIDE = 2`。这两组数不自洽：`MULT_F = 13.5` 且 `DIVIDE = 2` 时 VCO 是 `50 × 13.5 / 2 = 337.5 MHz`，不是 675；要到 675 需要 `MULT_F = 27.0`。`(MULT_F = 13.5, DIVIDE = 1)` 与 `(MULT_F = 27.0, DIVIDE = 2)` 都落在 675 MHz 且给出同样的 27/135，本模块取前者，因为 `DIVCLK_DIVIDE = 1` 与核心 MMCM 一致。

### 2.4 两个 MMCM 的复位与锁定

两个 MMCM 共用 `clk_in` 与 `rst_in`，但**各自有 `LOCKED`**：`locked`（核/LCD）与 `hdmi_locked`（HDMI）。`nes_zynq_top` 为 HDMI 域单独建了一条复位链，见第 6 节。

`nes_zynq_top.xdc` 对 `hdmi_pclk` / `hdmi_pclk_x5` **不写 `create_clock`**：它们不是顶层端口，而是 MMCM 内部输出，Vivado 从 `CLKIN1_PERIOD` 与分频参数**自动派生**生成时钟（与核时钟同）。XDC 记下了一条实测：在 MMCM 输出上硬写 `create_clock` 会把 `CLKOUT0` 转成 primary clock 并**切断 MMCM 自身的 `CLKOUT0→CLKOUT1` 派生**，于是 `create_generated_clock -source .../CLKOUT0` 报 `[Timing 38-249]`、135 MHz 与任何东西都失去关系——所以正确做法是**一条都别写**。

---

## 3. 为什么选 720×480p60

三个候选放在一起，答案就出来了：

| 候选 | 像素时钟 / 5× 串行 | 从 50 MHz 可达？ | 垂直缩放 | 接收端 |
|---|---|---|---|---|
| **720×480p60（CEA-861 480p）** | 27.000 / **135.000 MHz** | **可达且精确**（第二 MMCM 675 MHz VCO） | 240→480 恰 2:1，**`nes_video_800x480` 的移位原样保留** | 标准 CEA 模式，接收端保底支持 |
| 1280×720p60 | 74.25 / 371.25 MHz | 核心 MMCM 不可达（`35/11`，见 2.2），需另解 VCO | 240→720 = 3:1，需新增水平与垂直律 | 标准，但串行率 2.75× |
| 自定义 800×480 直出 | 非 CEA，无标准光栅 | 需自定 pixel 时钟，多数不可精确落 | 3.125×/2×，`nes_video_800x480` 的律 | **非标准模式，接收端可能拒收** |

选 720×480p60 的四个理由，按重要性：

1. **标准 CEA 模式**，接收端不需要 EDID 协商就能认（虽然本项目根本不做 EDID，见第 7 节）。
2. **两条时钟精确可达**：675 MHz VCO 整数/分数分频**无一处取整**。
3. **垂直缩放器原样保留**：480/240 = 恰好 2:1，与 `nes_video_800x480` 的 `src_row = v_row_index[8:1]` 位移一字不差（第 5 节）。
4. **串行率 135 MHz 而不是 371 MHz**：传输更快、更贵、更敏感，而本设计连 `set_output_delay` 都没有（第 8 节）。

CEA-861 480p 的几何（`nes_video_hdmi.v` 参数默认值）：

```
像素时钟  27.000 MHz
H: sync 62 / back porch 60 / active 720 / front porch 16 / total 858
V: sync  6 / back porch 30 / active 480 / front porch  9 / total 525
刷新率    27e6 / (858 × 525) = 59.94 Hz
两轴同步极性均为负（sync active LOW）
```

`hcount` 以水平同步前沿为 0，有效窗 `[122,842)`；`vcount` 以垂直同步前沿为 0，有效窗 `[36,516)`。这些都是 `parameter`，默认值即上表。

---

## 4. 四个模块的接口合同

### 4.1 `nes_video_hdmi`

双时钟。写口在 `wr_clk`（NES 核域 21.477 MHz），读口在 `rd_clk`（HDMI 像素域 27 MHz），与 `nes_video_800x480` **同一套跨域合同**：`frame_mem` 是 Xilinx 简单双口 BRAM，写口 `wr_clk`、读口 `rd_clk`，**RAM 边界本身就是跨域元件**，模块里没有同步器、toggle、握手或背压（第 5.3 节）。

| 端口 | 方向 | 宽度 | 合同 |
|---|---|---|---|
| `wr_clk` / `wr_reset` | in | 1 | 写时钟（core_clk）+ 写域同步复位；清写计数器与 ready 脉冲，**不清 `frame_mem`** |
| `in_valid` | in | 1 | 写口唯一使能；为 1 的沿把 `in_rgb565` 写进 `{in_y, in_x}` |
| `in_x` / `in_y` | in | 8 | 源列 0..255 / 源行 0..239 |
| `in_rgb565` | in | 16 | 源像素 RGB565 |
| `in_line_ready` | out | 1 | `wr_clk` 域单周期脉冲，一行写满；**观测用，无消费者** |
| `in_frame_ready` | out | 1 | `wr_clk` 域单周期脉冲，一帧写满；**观测用，无消费者** |
| `rd_clk` / `rd_reset` | in | 1 | 读时钟（hdmi_pclk）+ 读域同步复位；光栅归位，**不清 `frame_mem`** |
| `ce` | in | 1 | **只门控光栅**；真实实例恒 1，写口不受影响 |
| `rgb565` | out | 16 | RGB565 像素；消隐 / 窗口外为 `BLANK_RGB565` |
| `de` | out | 1 | DE 窗口，纯时序 |
| `hsync` / `vsync` | out | 1 | 负极性同步（`SYNC_ACTIVE_LOW=1`） |
| `hcount` / `vcount` | out | 11 | 0..857 / 0..524 |
| `pixel_x` / `pixel_y` | out | 11 | 窗口内 `hcount-H_A0` / `vcount-V_A0`，窗口外 0 |
| `frame_pulse` | out | 1 | 单周期脉冲，落在 `(H_LAST, V_LAST)` |

参数：`H_TOTAL=858`、`V_TOTAL=525`、`H_ACTIVE_START=122`、`H_ACTIVE_END=842`、`V_ACTIVE_START=36`、`V_ACTIVE_END=516`、`H_SYNC_START=0`、`H_SYNC_END=62`、`V_SYNC_START=0`、`V_SYNC_END=6`、`SYNC_ACTIVE_LOW=1`、`BLANK_RGB565=16'h0000`。

### 4.2 `nes_hdmi_tmds_encoder`

| 端口 | 方向 | 宽度 | 合同 |
|---|---|---|---|
| `clk` | in | 1 | 像素时钟（列在 `pclk`） |
| `rst_n` | in | 1 | 低有效；异步断言、由调用者同步释放 |
| `din` | in | 8 | 本道数据字节 |
| `de` | in | 1 | 1=有效视频（走数据编码），0=消隐（发控制符号） |
| `c0` / `c1` | in | 1 | 消隐期两个控制位（蓝道载 hsync/vsync，绿红道接 0） |
| `dout` | out | 10 | 编码符号 `q_out[9:0]`，**`q_out[0]` 先发** |

**三寄存器级**：`din` 被采样后 `dout` 再沿两个时钟有效（从驱动沿数第三个沿）。测试 bench 的 `CHECK_LAG = 2` 就是这个数。复位把 `dout` 清零、`disparity` 归零。

### 4.3 `nes_hdmi_tmds_serializer`

| 端口 | 方向 | 宽度 | 合同 |
|---|---|---|---|
| `rst` | in | 1 | **高有效**，直接接原语 `RST`（与编码器低有效相反） |
| `pclk` | in | 1 | 并行（像素）时钟，接 `OSERDESE2.CLKDIV` |
| `pclk_x5` | in | 1 | 串行时钟，5 × `pclk`，接 `OSERDESE2.CLK`；DDR 再翻倍到每像素 10 位 |
| `symbol` | in | 10 | 符号，`symbol[0]` 先发 |
| `serial_p` / `serial_n` | out | 1 | 一对 TMDS 差分输出（`OBUFDS`，`IOSTANDARD="TMDS_33"`） |

7 系列 `OSERDESE2` 只有 8 个并行输入，10 位靠**主从两片级联**：MASTER 出 `D1..D8`，SLAVE 把最后两位经 `SHIFTOUT1/2 → SHIFTIN1/2` 送进 MASTER。SLAVE 取 `symbol[8]`（D3）与 `symbol[9]`（D4）——那正是 `DATA_WIDTH=10` 时两个 `SHIFTOUT` 落到 MASTER 两个扩展输入的位对。两片都 `DATA_RATE_OQ="DDR"`，5× 串行钟每周期两位，于是 10 位占**一个像素时钟周期**。

### 4.4 `nes_hdmi_tx`

| 端口 | 方向 | 宽度 | 合同 |
|---|---|---|---|
| `pclk` | in | 1 | 像素时钟（= hdmi_pclk 27 MHz） |
| `pclk_x5` | in | 1 | 串行时钟（= hdmi_pclk_x5 135 MHz） |
| `reset_n` | in | 1 | 异步板级复位，**低有效** |
| `rgb888` | in | 24 | `{red[7:0], green[7:0], blue[7:0]}` |
| `hsync` / `vsync` | in | 1 | 编到蓝道的 c0/c1 |
| `de` | in | 1 | 1=有效视频；0=消隐（每道发控制符号） |
| `tmds_data_p` / `tmds_data_n` | out | 3 | 三条 TMDS 数据对（蓝/绿/红） |
| `tmds_clk_p` / `tmds_clk_n` | out | 1 | 时钟对 |

内部：`u_encoder_blue/green/red` + `u_serial_blue/green/red/u_serial_clock`。**时钟道不编码**，固定送 `10'b1111100000`（DVI 时钟前导码）。`reset_n` 被两条**独立的双触发器同步器**重定时——一条在 `pclk`（喂编码器，异步断言/同步释放，低有效），一条在 `pclk_x5`（喂串行器 `RST`，因原语高有效所以取反）。编码器链和串行器链各走各的，不让板级复位直接走进像素域触发器。

---

## 5. 缩放：垂直保持 2:1，水平是 45/16 的有理累加器

### 5.1 为什么不能复用 `nes_video_800x480`

`nes_video_800x480` 的水平律是"3:1 + 每第 8 列多 1"（32 组 × 25 dot）。720/256 = **2.8125 = 45/16**，那个"25 dot 组"发射器表达不了。更根本的是：**一块 BRAM 的读口只由一个时钟域驱动**，25 MHz LCD 读口与 27 MHz HDMI 读口不可能共享同一个 `frame_mem` 实例。所以 `nes_video_hdmi` 是一个**独立模块、带自己的第二块 `frame_mem`**，由同一条核域像素流写入。这不是"复制代码"，是"第二次读时钟就要第二块存储"；`nes_video_800x480` 因此**逐字节未动**。

### 5.2 水平 45/16 的 Bresenham 累加器

输出 dot `n` 读源列 `floor(n × 256 / 720)`：

```verilog
assign h_acc_plus   = h_acc + 11'd256;
assign h_acc_ge     = (h_acc_plus >= H_STEP_MOD);        // H_STEP_MOD = 720
assign h_acc_next   = de ? (h_acc_ge ? (h_acc_plus - 720) : h_acc_plus) : 11'd0;
assign src_col_next = de ? (h_acc_ge ? (src_col + 8'd1) : src_col) : 8'd0;
```

每个输出 dot 给累加器加 256，溢出（≥720）时减 720 并让 `src_col` 前进一位。720 个输出 dot 恰好把 `src_col` 推进 `720 × 256 / 720 = 256` 个源列，累加器在每行末回到 0，所以**每一行、每一帧的有效宽度都精确是 720，无累积误差**。这是音频 lane 的 `2016/55` 抽取器（见 `i2s-audio.md`）同一套惯用法，**全程没有浮点**。

一个被注释钉死的坑：`h_acc_next` 以**当前** `de` 为门，不是 `de_next`。若用 `de_next`，累加器会在消隐→有效的过渡上多走一步，使每一列提前一个 dot——这正是注释里记录的缺陷。

### 5.3 垂直 2:1 与读写延迟合同

```verilog
assign v_row_index = v_active ? (vcount_next - 11'd36) : 11'd0;
assign src_row     = v_row_index[8:1];              // 480 -> 240 的右移一位
```

与 `nes_video_800x480` 的移位**一字不差**。读延迟合同也相同：正在发射的 dot 的数据由**推进光栅的同一个 `rd_clk` 沿**捕获，`mem_read_addr` 用同一个 `*_next` 拼出，没有输出级、没有 skew。同址同拍读写返回旧值（BRAM read-first），缓冲是**单缓冲**，写端比读端快（NTSC 59.94 Hz 对 HDMI 59.94 Hz，理论上接近相等；本项目不做撕裂保护）。

`in_line_ready` / `in_frame_ready` 留在 `wr_clk` 域，是**观测脉冲**，真实集成里**悬空**（`nes_zynq_top` 里 `.in_line_ready()`、`.in_frame_ready()`）。

---

## 6. 顶层接线与 HDMI 复位域

`nes_zynq_top` 里（`rtl/platform/zynq/nes_zynq_top.v`）：

- `u_video_hdmi`：`.wr_clk(mmcm_core_clk)`、`.rd_clk(mmcm_hdmi_pclk)`、`.rd_reset(rst_hdmi)`、`.ce(1'b1)`，写口接核域像素流（`vid_we_q` / `vid_in_x_q` / `vid_in_y_q` / `vid_in_rgb_q`）。
- RGB565→RGB888 用与 LCD 侧相同的**全量位复制**：`{r5,r5[4:2]}`、`{g6,g6[5:4]}`、`{b5,b5[4:2]}`。
- `u_hdmi_tx`：`.pclk(mmcm_hdmi_pclk)`、`.pclk_x5(mmcm_hdmi_pclk_x5)`、`.reset_n(~rst_hdmi)`、`.rgb888(hdmi_rgb888)`、四对 TMDS 直接出端口。

HDMI 是**第四个时钟域**。它单独一条复位链：

```verilog
(* MAX_FANOUT = 32 *) reg [1:0] rst_hdmi_q;
reg hdmi_locked_q0, hdmi_locked_q1;
// 都在 posedge mmcm_hdmi_pclk 上用 negedge sys_rst_n 异步断言、两级同步释放
wire rst_hdmi = rst_hdmi_q[1] | ~hdmi_locked_q1;
```

同核/LCD 的规则：**HDMI 域必须被压住直到第二个 MMCM 的 `LOCKED` 为高**，否则会在一根还在爬升的 27 MHz 时钟上开始串行化。`.reset_n(~rst_hdmi)` 说明它同时覆盖了编码器与串行器。

跨域边界**没有新增带触发器的路径**：HDMI 的 `frame_mem` 是与 LCD 版**同一颗简单双口原语**的第二个实例，跨域不花任何逻辑（XDC 里没有为 HDMI 加新的 `set_max_delay`）。`hdmi_pclk` 与 `lcd_clk` **也互不相关**——它们是两个独立 MMCM 的输出。

---

## 7. DDC / EDID 限制（显眼提醒）

**`tmds_scl` 与 `tmds_sda` 在板子上是 R19 / P20，正是触摸控制器（`touch_scl` / `touch_sda`）占用的同一对物理引脚。** 这是板级事实，不是笔误：ATK-4342 面板连接器与 HDMI 的 DDC 线共享这两个 pin。`nes_zynq_top.xdc` 的 CONFLICT 块已把它绑定给触摸，HDMI 的 `tmds_scl` / `tmds_sda` **根本没有被声明为端口**。

后果，必须直说：

- **HDMI DDC 不可能实现**（在触摸控制器继续持有 R19/P20 期间）。没有 EDID 读取，没有热插拔检测（`tmds_hpd` 在 L19 是空的，本项目**也没有**加这个输入——顶层不需要它）。
- **只能固定模式输出**：接收端要么认 720×480p60，要么没有画面。没有分辨率协商、没有 sink 能力查询、没有 HDCP（HDMI 需要，DVI 不需要，本项目两者都没做）。
- 要把 DDC 加回来，是一个**板级决定**：R19/P20 必须从触摸移交给 HDMI，触摸控制器得改到面板自己的连接器或 PS 的 I2C 上，不是改约束文件能解决的。

---

## 8. 诚实的时序警示

**本设计全篇有零条 `set_output_delay`。** 加 HDMI 之前 `check_timing` 已经列出所有无输出延迟的端口（`lcd_rgb[23:0]`、`lcd_de`、触摸两根 `touch_scl/touch_sda`、以及六根音频 `aud_*`），**加上 TMDS 数据/时钟对之后没有任何一条 `set_output_delay` 被补上**——当前是 **38 个端口无输出延迟**。

TMDS 在 **135 MHz** 上工作，比那个同样未约束的 25 MHz LCD 总线**敏感得多**。所以：

> **一个布线通过、报告 WNS 为正的比特流，不是"连接器处的眼图有效"的证据。**

P&R 对 `OSERDESE2` 输出路径只有"寄存器到引脚"的内部规则，**没有任何 DVI/HDMI 接收端的建立保持窗口**来判定它。要把这条闭合，需要接收端在电缆上的 TMDS 建立/保持数字（实测或数据手册来源）加上 `OBUFDS`/`OSERDESE2` 的输出延迟——那是另一件工作，**不猜**。这一点与 `zynq-platform.md` 第 9 节"I/O 时序有意未约束"同源，只是代价更高。XDC 的 HDMI 块把这条写得很清楚。

---

## 9. TMDS 编码：读者需要的那一层

`nes_hdmi_tmds_encoder` 从 **DVI 1.0 规范 3.1.3 节（图 3-5）** 编写（HDMI 继承同一算法），不是从任何 vendor 源码转写。

### 9.1 四个控制符号

消隐期（`de=0`）发控制符号。规范按发送顺序 `q_out[0..9]` 书写；本模块按 `q_out[9:0]` 存储、**`q_out[0]` 先发**，所以下面的字面量是规范 token 的倒序：

| `{c1,c0}` | `q_out[9:0]` | 含义 |
|---|---|---|
| 00 | `10'b1101010100` | 蓝道：hsync=0, vsync=0 |
| 01 | `10'b0010101011` | 蓝道：hsync=1, vsync=0 |
| 10 | `10'b0101010100` | 蓝道：hsync=0, vsync=1 |
| 11 | `10'b1010101011` | 蓝道：hsync=1, vsync=1 |

绿道与红道两个控制位恒 0，所以它们消隐期固定发 `{00}` 的 token。一个控制符号会**把运行差异寄存 `disparity` 强制归零**（规范复位 `Cnt`）。

### 9.2 三阶段最小跳变算法

1. **阶段 1（8b → 9b）**：把字节 `D[7:0]` 变成九位 `q_m[8:0]`。令 `N1{D}` 为 `D` 中 1 的个数；当 `(N1{D} > 4)` 或 `(N1{D} == 4 且 D[0] == 0)` 时用**交替 XNOR 链**且 `q_m[8]=0`，否则用 **XOR 链**且 `q_m[8]=1`。两条链都从 `q_m[0]=D[0]` 起。选链就是"对这个输入类最小化跳变"。
2. **阶段 2（9b → 10b）**：令 `N1{q_m}`、`N0{q_m}` 为 `q_m` 八个数据位的 1/0 数。`disparity` 是**五位数带符号寄存器**（规范叫 `Cnt`）。输出取三分支之一：
   - **balanced**：`disparity==0` 或 `N1{q_m}==N0{q_m}`。`q_out[9]=~q_m[8]`、`q_out[8]=q_m[8]`、`q_out[7:0]=q_m[8]?q_m[7:0]:~q_m[7:0]`——**DC 平衡**选择，符号恒有五个 1，对差异贡献为 0。
   - **oppose**：差异与 `q_m` 同号。`q_out[9]=1`，低八位取反——把最小跳变符号反向，**把差异拉回零**。
   - **follow**：其余。`q_out[9]=0`，低八位照抄——最小跳变符号，反向。
   差异更新量恰好是所选符号的 DC 含量。
3. `disparity` 因此等于已发送流的运行差异；控制符号把它归零。

### 9.3 运行差异边界是 ±8，不是 ±1

> **TMDS 不是 IBM 8b/10b 码，其运行差异不限于 ±1。** DC 平衡符号贡献 0，但最小跳变符号可以带多达八个 1（或八个 0），所以运行差异能到 **±8**（全 0 与全 1 字节是极值）。算法真正保证的是**差异永不漂移**：`oppose` 分支总把它推回零。

`tb_nes_hdmi_tmds_encoder` 断言的正是 `[-8, +8]` 这个界，并**额外断言差异确实超过 1**，所以一个错误地把状态钳到 ±1 的编码器会被抓出来，而不是被迁就。**不要**把它误写成"就像 8b/10b 那样界 ±1"——bench 文件头专门解释了为什么这是错的。

---

## 10. 证据入口

`tools/sim_all.ps1` 里与本子系统相关的目标：

| 目标 id | 内容 | 组 | `Run` |
|---|---|---|---|
| `video-hdmi-tb` | `tb/video/tb_nes_video_hdmi.v`（720×480 scaler，标准 2012） | video | `$true` |
| `video-hdmi-core` | `nes_video_hdmi` elaboration（标准 2001） | video | `$false` |
| `hdmi-tmds-encoder-tb` | `tb/platform/tb_nes_hdmi_tmds_encoder.v`（DVI 规范一致性，标准 2012） | platform | `$true` |
| `hdmi-tmds-encoder-core` | `nes_hdmi_tmds_encoder` elaboration | platform | `$false` |
| `hdmi-serializer-core` | `nes_hdmi_tmds_serializer` elaboration | platform | `$false` |
| `hdmi-tx-core` | `nes_hdmi_tx` elaboration | platform | `$false` |

`zynq-clk-tb` 现在也测第二个 MMCM：`hdmi_pclk` 27.000 MHz 与 `hdmi_pclk_x5` 135.000 MHz 的精确断言；`zynq-top-tb` elaborate 整条 HDMI 通路并数 `tmds_clk_p` 边沿。`nes_hdmi_tmds_serializer` 与 `nes_hdmi_tx` 在 Icarus 下靠 `tb/platform/nes_hdmi_tmds_prim_sim.v` 的行为 `OSERDESE2` / `OBUFDS` 模型 elaborate（该文件只进仿真文件集，Vivado 综合对着真原语）。

**`hdmi-tx-core` 的 `Run` 仍是 `$false`，且 `tools/sim_all.ps1` 内那段注释仍写着"not instantiated by nes_zynq_top.v yet"**——这句在 `db4c3b5` 之后已经过时，见本文开头与第 6 节。

`tb_nes_video_hdmi` 钉住的东西：`de` 等于用 `hcount`/`vcount` 重算的 CEA-861 480p 窗口；`hsync` 每行恰低 `[0,62)`；`vsync` 每帧恰低 `[0,6)`；`de` 低时总线为 `BLANK`；每行 `de` 恰 720 dot；`ce` 低时光栅完全冻结；一帧恰 `858×525` 个 `ce` 拍、480 个有效行；`src_col` 等于独立参考列 `floor(n×256/720)`、`mem_read_addr` 等于下一 dot 的参考地址；累加器始终在 0..719、`src_col` 在 0..255；内容逐 dot 比对；相邻输出行对相同（2:1）；每个源列被发 2 或 3 次、256 列恰好覆盖 720 dot（45/16 有理律）。

---

## 11. 明确未实现 / 未建模

- **没有上板综合 / 时序 / 功能验收证据。** 本子系统只有 Icarus 仿真门禁；仓库内没有随提交的 Vivado 工程、比特流或上板照片。TMDS 输出**没有输出延迟约束**（第 8 节）。
- **无 DDC / EDID / HPD / HDCP。** R19/P20 归触摸，`tmds_hpd` 未接入（第 7 节）。固定 720×480p60。
- **无 HDMI 音频。** 只有视频 TMDS；音频走独立的 WM8960 I2S lane（`i2s-audio.md`）。虽然 HDMI 数据岛（Data Island）能携带音频和 AVI InfoFrame，本设计**一个都没发**——接收端看到的是一路纯视频 TMDS，等同 DVI。
- **TMDS 编码未与规范逐案例全覆盖比对。** bench 用定向全字节扫描 + 4096 长 LFSR 流 + 规范解码器往返，但没有把规范附录的每一组参考向量逐一列出。
- **`nes_video_hdmi` 单缓冲、无撕裂保护、无背压。** 与 `nes_video_800x480` 相同：`frame_mem` 原地覆盖，写端与读端帧率接近但不等，没有前后台、没有交换。
- **`in_line_ready` / `in_frame_ready` 无消费者**（顶层悬空）。
- **`nes_hdmi_tx.v` 文件头的 "Integration" 段过时**（说"未被任何地方实例化、顶层无 HDMI 端口、XDC 无 TMDS 引脚"），已被 `db4c3b5` 推翻；RTL 受"不得改动"约束，本文如实记录现状。
- **第二个 MMCM 只服务 HDMI，不改动核/LCD 时钟。** 核时钟与 25 MHz LCD/音频时钟与 HDMI 存在之前逐位相同；这是刻意的，代价是 HDMI 的时钟频率不能靠改核心 MMCM 来获得。
- **720p / 800×480 直出未实现。** 分频算术上核心 MMCM 到不了它们的时钟（第 2.2 节），自定义模式还缺接收端支持；本模块只做 720×480p60。

---

## 12. 与其他章节的关系

- 时钟树与第一个 MMCM：`docs/modules/zynq-platform.md` 第 2 节、`docs/walkthrough/41-zynq-clk.md`。
- 同源 scaler（800×480，25 MHz 读口）：`docs/modules/video-800x480.md`；本模块是它的第二读时钟兄弟。
- 音频 lane（同一条核域像素流之外的音频通路）：`docs/modules/i2s-audio.md`。
- 顶层整机接线与四时钟域：`docs/modules/zynq-platform.md`（写作时描述三个域，HDMI 之后是四个）、`docs/walkthrough/64-zynq-top.md`（同样写于 HDMI 之前）。
- 引脚与 CDC 约束政策：`rtl/platform/zynq/nes_zynq_top.xdc` 的 HDMI 块与 I/O 时序块。
