# 42 HDMI/DVI 发射通路精读：`nes_video_hdmi.v` + `nes_hdmi_tx.v`

上一篇 [`41-zynq-clk.md`](41-zynq-clk.md) 讲了一个 MMCM 从 50 MHz 造出 21.477 MHz 与 25 MHz。这一篇接着问：**如果目标不是面板，而是一根 HDMI 线呢？** 板子上没有 HDMI 控制器，只有四对 TMDS 差分引脚。要把 PPU 的 256×240 像素送出去，需要三样东西：**两条新时钟**（27 MHz 像素、135 MHz 串行）、**一个按 CEA-861 480p 工作的缩放器**、**一个把字节编成 10 位符号并串行化的发射核**。

- 源码：[`rtl/nes_core/video/nes_video_hdmi.v`](../../rtl/nes_core/video/nes_video_hdmi.v)、[`rtl/platform/zynq/nes_hdmi_tx.v`](../../rtl/platform/zynq/nes_hdmi_tx.v)、[`rtl/platform/zynq/nes_hdmi_tmds_encoder.v`](../../rtl/platform/zynq/nes_hdmi_tmds_encoder.v)、[`rtl/platform/zynq/nes_hdmi_tmds_serializer.v`](../../rtl/platform/zynq/nes_hdmi_tmds_serializer.v)
- 合同与证据：[`../modules/hdmi-tx.md`](../modules/hdmi-tx.md)
- 测试目标：`video-hdmi-tb`（scaler）、`hdmi-tmds-encoder-tb`（编码器规范一致性），外加 `zynq-clk-tb` / `zynq-top-tb` 覆盖第二条 MMCM 与整条通路的 elaborate

---

## 1. 定位 + 上下游

```text
PPU 像素流 ──►┌──────────────┐  wr_clk=21.477 MHz
(RGB565)      │ nes_video_    │   ┌──────────────┐  pclk=27 / pclk_x5=135
              │ hdmi 缩放器   │──►│  nes_hdmi_tx │──► 4 × TMDS 差分对 ──► HDMI 连接器
              │ (256×240→     │   │ 3 编码 + 4 串行│
              │  720×480)     │   └──────────────┘
              └──────────────┘       hdmi_pclk 域
              frame_mem 双口 BRAM
              core_clk 写 / hdmi_pclk 读
```

- **上游**：核域像素流（`vid_we_q` / `vid_in_x_q` / `vid_in_y_q` / `vid_in_rgb_q`，与 LCD scaler 同一份）。
- **时钟**：第二个 MMCM 给出 `hdmi_pclk` 27 MHz 与 `hdmi_pclk_x5` 135 MHz。
- **下游**：连接器上的 4 对 TMDS（3 数据 + 1 时钟）。
- 它是整机**第四条时钟域**，比 `nes_zynq_top.v` 文件头写作时的三个域多一个。

![图 1：HDMI 发射通路](../figures/hdmi-path.svg)

**图 1** · 两个 MMCM 与四条时钟、`core_clk` 写 / `hdmi_pclk` 读的跨域 `nes_video_hdmi`、TMDS 编码器到串行器到连接器，以及 DDC 不可用的原因。事实来源见 [`../figures/README.md`](../figures/README.md)。生成图，勿手改。

---

## 2. 全文代码（骨架）

四个文件加起来约 750 行，`nes_hdmi_tmds_encoder.v`（208 行）的算法部分最值得逐行看，其余是原语例化与接线。下面按数据流顺序贴骨架。

### 2.1 第二个 MMCM（`nes_zynq_clk.v` 追加的部分）

```verilog
`NES_ZYNQ_MMCM_CELL #(
    .CLKFBOUT_MULT_F    (HDMI_CLKFBOUT_MULT_F),   // 13.5
    .CLKOUT0_DIVIDE_F   (HDMI_CLKOUT0_DIVIDE_F),  // 25.0
    .CLKOUT1_DIVIDE     (HDMI_CLKOUT1_DIVIDE),    // 5
    .DIVCLK_DIVIDE      (HDMI_DIVCLK_DIVIDE),     // 1
    .CLKIN1_PERIOD      (CLK_IN_PERIOD)
) u_mmcm_hdmi (
    .CLKIN1 (clk_in), .RST (rst_in), .LOCKED (hdmi_locked),
    .CLKOUT0 (hdmi_pclk), .CLKOUT1 (hdmi_pclk_x5), ...
);
```

### 2.2 缩放器（`nes_video_hdmi.v` 的核心）

```verilog
reg [15:0] frame_mem [0:61439];        // 第二块整帧缓冲

// 写口：core_clk
if (in_valid) frame_mem[mem_write_addr] <= in_rgb565;   // 地址 {in_y, in_x}

// 读口：hdmi_pclk，CEA-861 480p 光栅
assign hcount_next = h_line_last ? 11'd0 : (hcount + 11'd1);
assign de_next  = (hcount_next >= 122) && (hcount_next < 842) &&
                  (vcount_next >=  36) && (vcount_next <  516);
assign src_row  = v_active ? (vcount_next - 36) >> 1 : 8'd0;   // 2:1

assign h_acc_plus   = h_acc + 11'd256;
assign h_acc_ge     = (h_acc_plus >= 11'd720);
assign h_acc_next   = de ? (h_acc_ge ? (h_acc_plus - 720) : h_acc_plus) : 11'd0;
assign src_col_next = de ? (h_acc_ge ? (src_col + 8'd1) : src_col) : 8'd0;
assign mem_read_addr = {src_row, src_col_next};

// 同沿捕获：光栅、像素、消隐一致
always @(posedge rd_clk) if (ce) begin
    hcount <= hcount_next; vcount <= vcount_next; de <= de_next;
    rgb565 <= de_next ? frame_mem[mem_read_addr] : BLANK_RGB565;
    src_col <= src_col_next; h_acc <= h_acc_next;
end
```

### 2.3 编码器（`nes_hdmi_tmds_encoder.v` 的核心）

```verilog
// 阶段 1：8b -> 9b，XNOR 或 XOR 链
wire minimise = (ones_1 > 4) || ((ones_1 == 4) && (din_1[0] == 0));
assign q_m[0] = din_1[0];
assign q_m[1] = minimise ? ~(q_m[0]^din_1[1]) : (q_m[0]^din_1[1]);
... assign q_m[8] = ~minimise;

// 阶段 3：符号选择 + 运行差异
wire balanced = (disparity == 0) || (n1_2 == n0_2);
wire oppose   = ((disparity > 0) && (n1_2 > n0_2)) ||
                ((disparity < 0) && (n0_2 > n1_2));
always @(posedge clk or negedge rst_n) begin
    if (!de_2) begin case ({c1_2,c0_2}) ... endcase disparity <= 0; end
    else if (balanced) begin ... end
    else if (oppose)   begin ... end
    else               begin ... end
end
```

### 2.4 串行器与顶层（`nes_hdmi_tmds_serializer.v` / `nes_hdmi_tx.v`）

```verilog
// 主从两片 OSERDESE2：MASTER 出 D1..D8，SLAVE 经 SHIFTOUT→SHIFTIN 供 symbol[8]/[9]
OSERDESE2 #(.DATA_RATE_OQ("DDR"), .DATA_WIDTH(10), .SERDES_MODE("MASTER")) u_master (...);
OSERDESE2 #(.DATA_RATE_OQ("DDR"), .DATA_WIDTH(10), .SERDES_MODE("SLAVE"))  u_slave  (...);
OBUFDS #(.IOSTANDARD("TMDS_33")) u_pair (.I(serial), .O(serial_p), .OB(serial_n));

// 顶层：三条数据道编码，第四条时钟道固定送前导码
nes_hdmi_tmds_encoder u_encoder_blue (...c0(hsync), .c1(vsync));
nes_hdmi_tmds_encoder u_encoder_green(...c0(1'b0), .c1(1'b0));
nes_hdmi_tmds_encoder u_encoder_red  (...c0(1'b0), .c1(1'b0));
wire [9:0] clock_symbol = 10'b1111100000;
```

---

## 3. 逐段精读

### 3.1 为什么核心 MMCM 造不出 27 / 135 MHz

上一章的 MMCM 把 VCO 钉在 **1181.25 MHz**，唯一目的就是让核时钟 `945/44 MHz` 落在整数 `CLKOUT1_DIVIDE = 55` 上。代价是它的分频自由度被锁死：

```
27 MHz :  1181.25 / 27  = 43.75   —— 是 0.125 步，但只有 CLKOUT0 能分数分频，它已给 25 MHz LCD
135 MHz:  1181.25 / 135 = 8.75    —— 不是整数，落不到 CLKOUT1..6
```

换一个 VCO 才能同时命中两个。第二个 MMCM 取 675 MHz：

```
f_vco = 50 × 13.5 / 1 = 675 MHz
CLKOUT0_DIVIDE_F = 675 / 27  = 25.0  → hdmi_pclk    = 27.000 MHz
CLKOUT1_DIVIDE   = 675 / 135 = 5     → hdmi_pclk_x5 = 135.000 MHz
```

三个分频**没有一个取整**。`nes_zynq_clk.v` 文件头还记下一段被交接来的、自相矛盾的推导（`MULT_F=13.5` 配 `DIVCLK_DIVIDE=2` 会得到 337.5 而非 675），以及为什么最终选 `DIVCLK_DIVIDE=1`——细节见 [`../modules/hdmi-tx.md`](../modules/hdmi-tx.md) 第 2 节。

**关键点**：核心 MMCM 一个参数都没动，所以 `core_clk` / `lcd_clk` 与 HDMI 存在之前**逐位相同**。

### 3.2 scaler 为什么是"第二个模块"而不是加参数

`nes_video_800x480` 的水平律是"3:1 + 每第 8 列多 1"（32 组 × 25 dot）。720/256 = **2.8125 = 45/16**，那个 25-dot 组发射器表达不了。更根本的是：**一块 BRAM 的读口只由一个时钟驱动**，25 MHz LCD 读口与 27 MHz HDMI 读口无法共享同一个 `frame_mem` 实例。所以 `nes_video_hdmi` 带**自己的第二块 `frame_mem`**，由同一条核域流写入；`nes_video_800x480` 逐字节未动。

### 3.3 水平 45/16 用 Bresenham 累加器

输出 dot `n` 读源列 `floor(n × 256 / 720)`。累加器每个输出 dot 加 256、溢出（≥720）时减 720 并让 `src_col` 前进一位。720 个输出 dot 恰好推进 `720 × 256 / 720 = 256` 个源列，每行末归零，**有效宽度精确 720，无累积误差**——与音频 lane 的 `2016/55` 抽取器同一套惯用法，全程无浮点。

一个注释钉死的坑：`h_acc_next` 用**当前** `de` 门控，不是 `de_next`。用 `de_next` 会在消隐→有效的过渡多走一步，每列提前一个 dot。垂直方向更简单，`src_row = v_row_index[8:1]`，与 800×480 的移位一字不差。

### 3.4 编码器：三阶段、四个控制符号、差异界 ±8

编码器是三个寄存器级：`din` 被采样后 `dout` 再沿两个时钟有效。算法分三阶段（DVI 1.0 §3.1.3 / 图 3-5）：

1. **8b→9b**：按 1 的个数选 XNOR 链（多 1 或半数且 LSB=0，`q_m[8]=0`）还是 XOR 链（否则，`q_m[8]=1`），两条链都从 `q_m[0]=din[0]` 起。
2. **9b→10b**：`balanced`（差异为 0 或 q_m 平衡，符号恒五个 1）/ `oppose`（差异与 q_m 同号，取反把它拉回零）/ `follow`（照抄）。
3. `disparity` 是五位数带符号寄存器，随所选符号的 DC 含量更新；**控制符号把它归零**。

四个控制符号（蓝道，`{c1,c0}`，本模块存 `q_out[9:0]`、`q_out[0]` 先发，所以是规范 token 的倒序）：

| `{c1,c0}` | `q_out[9:0]` |
|---|---|
| 00 | `1101010100` |
| 01 | `0010101011` |
| 10 | `0101010100` |
| 11 | `1010101011` |

> **运行差异界是 ±8，不是 ±1。** TMDS 不是 IBM 8b/10b 码；DC 平衡符号贡献 0，但最小跳变符号可带多达八个 1/0。`tb_nes_hdmi_tmds_encoder` 断言的正是 ±8，并额外断言差异确实超过 1，专门抓"错误地钳到 ±1"的实现。别按 8b/10b 的直觉去读它。

### 3.5 串行器：7 系列原语只有 8 个输入口

`OSERDESE2` 并行输入只有 `D1..D8`，10 位靠**主从级联**：MASTER 出 `D1..D8`，SLAVE 用 `SHIFTOUT1/2 → SHIFTIN1/2` 把最后两位送进 MASTER。SLAVE 取 `symbol[8]`（D3）与 `symbol[9]`（D4）——`DATA_WIDTH=10` 时正是两个 `SHIFTOUT` 落到 MASTER 两个扩展输入的位对。两片都 `DATA_RATE_OQ="DDR"`，在 5× 串行钟上每周期出两位，一个像素周期出十位。输出经 `OBUFDS`（`IOSTANDARD="TMDS_33"`）。

Icarus 没有 `OSERDESE2` / `OBUFDS` 原语，仿真用 `tb/platform/nes_hdmi_tmds_prim_sim.v` 的行为模型替代；Vivado 综合对着真原语。

### 3.6 顶层：四条道与两条复位同步器

`nes_hdmi_tx` 例化 3 个编码器（蓝道载 `hsync`/`vsync`，绿红道 c0=c1=0）与 4 个串行器。**时钟道不编码**，固定送 `10'b1111100000`（DVI 时钟前导码）。`reset_n`（低有效）被两条独立的双触发器同步器分别重定时进 `pclk` 与 `pclk_x5`；编码器和串行器各走各的，不让板级复位直接走进像素域。

### 3.7 顶层复位链：HDMI 域必须等 `hdmi_locked`

`nes_zynq_top` 给第四个域单独一条链（`rst_hdmi = rst_hdmi_q[1] | ~hdmi_locked_q1`），规和核/LCD 一样：**HDMI 域被压住直到第二个 MMCM 锁定**。`.reset_n(~rst_hdmi)` 同时覆盖编码器与串行器。HDMI 的 `frame_mem` 与 LCD 版是同一颗简单双口原语的第二个实例，跨域不花任何逻辑。

---

## 4. 端口 / 参数表

### 4.1 `nes_video_hdmi`（关键端口）

| 端口 | 方向 | 作用 |
|---|---|---|
| `wr_clk` / `in_valid` / `in_x[7:0]` / `in_y[7:0]` / `in_rgb565[15:0]` | in | core_clk 写口 |
| `in_line_ready` / `in_frame_ready` | out | 观测脉冲，顶层悬空 |
| `rd_clk` / `rd_reset` / `ce` | in | hdmi_pclk 读口；`ce` 只门控光栅 |
| `rgb565[15:0]` / `de` / `hsync` / `vsync` | out | 像素与 CEA-861 时序 |
| `hcount[10:0]` / `vcount[10:0]` / `pixel_x` / `pixel_y` / `frame_pulse` | out | 光栅坐标与帧脉冲 |

### 4.2 `nes_hdmi_tx`

| 端口 | 方向 | 作用 |
|---|---|---|
| `pclk` / `pclk_x5` | in | 27 MHz 像素 / 135 MHz 串行 |
| `reset_n` | in | 低有效异步复位 |
| `rgb888[23:0]` / `hsync` / `vsync` / `de` | in | `{red,green,blue}` 与同步 |
| `tmds_data_p[2:0]` / `tmds_data_n[2:0]` / `tmds_clk_p` / `tmds_clk_n` | out | 四对 TMDS |

`nes_hdmi_tmds_encoder`：`clk`、`rst_n`、`din[7:0]`、`de`、`c0`、`c1` → `dout[9:0]`。
`nes_hdmi_tmds_serializer`：`rst`、`pclk`、`pclk_x5`、`symbol[9:0]` → `serial_p`、`serial_n`。

---

## 5. 代入数值走一遍

取输出 dot `n = 0, 1, 2, ...`，看 `(h_acc, src_col)` 怎么走：

| `n` | `h_acc`（进入时） | `h_acc+256` | `≥720?` | `src_col`（本 dot 用） | 下一拍 `src_col` |
|---:|---:|---:|:--:|---:|---:|
| 0 | 0 | 256 | 否 | 0 | 0 |
| 1 | 256 | 512 | 否 | 0 | 0 |
| 2 | 512 | 768 | **是** | 0 | 1 |
| 3 | 48 | 304 | 否 | 1 | 1 |
| … | … | … | … | … | … |
| 719 | 464 | 720 | **是** | 255 | 256→(行末归 0) |

源列 0 被发了 3 次（`n=0,1,2`），下一个源列何时被发 2 或 3 次取决于余数。把整行加起来：`src_col` 恰好从 0 走到 255 共 256 列、`n` 恰好 720，`h_acc` 回到 0。这就是"每行有效宽度精确 720"的算术。

再取一个 TMDS 例子：`din=8'h00`、差异为 0。`N1{0}=0`，走 XOR 链，`q_m={1,00000000}`；`N0{q_m}=8`，`disparity==0` → `balanced`，符号五个 1。`din=8'hFF` 则 `N1=8>4`，走 XNOR 链，符号是它的最小跳变形式，运行差异可达 ±8。第 3.4 节那张表就是全部直觉来源。

---

## 6. 常见疑问

**Q：为什么不用 720p60？** A：它的 5× 串行时钟是 371.25 MHz，核心 MMCM 要 `1181.25/371.25 = 35/11`，既非整数也非 0.125 步，造不出来；而且垂直缩放要新增 3:1 律、串行率是 480p 的 2.75 倍。480p 让垂直移位原样保留、两条时钟精确可达。

**Q：720×480 不是 4:3，画面会变形吗？** A：CEA-861 480p 的 720×480 是**方形像素**（每行 720 个有效像素对应 704 个采样点、显示为 4:3）；本项目把 256 列直接铺满 720 dot，没有做像素宽高比修正，所以是"横向拉满"的近似。这点属于显示几何，不与本模块的行为合同冲突。

**Q：为什么 DDC/EDID 做不了？** A：HDMI 的 DDC 用 R19/P20，而这两根正是触摸控制器的 `touch_scl`/`touch_sda`——板级物理冲突。触摸持有它们期间，DDC 不可能；`tmds_scl`/`tmds_sda` 在顶层根本不是端口。结果就是固定模式、无热插拔（详见 [`../modules/hdmi-tx.md`](../modules/hdmi-tx.md) 第 7 节）。

**Q：仿真里没有真的 `OSERDESE2`，测的算什么？** A：`hdmi-serializer-core` / `hdmi-tx-core` 是 **elaboration-only**（`Run=$false`）目标，只证明模块能对着行为模型展开——串行化时序的真值以 Vivado 综合的原语实现为准。编码器则有真正的规范一致性 bench（`hdmi-tmds-encoder-tb`），它重建规范的阶段 1 链、图 3-6 解码器与四个 token，逐符号比对。

**Q：布线通过、WNS 为正，是不是就能插上显示器了？** A：不是。本设计有**零条 `set_output_delay`**，TMDS 在 135 MHz 上比未约束的 25 MHz LCD 总线敏感得多。**布线干净不等于连接器处眼图有效**（第 8 节 / [`../modules/hdmi-tx.md`](../modules/hdmi-tx.md) 第 8 节）。要闭合需要接收端的建立/保持数字，不猜。

---

## 7. 你应该带走的三件事

1. **第二条 MMCM 是算术逼出来的**：核心 VCO 1181.25 MHz 到不了 27（唯一分数口已给 LCD）和 135（非整数分频），所以另起 675 MHz VCO；`50×13.5/1` → `÷25` 得 27、`÷5` 得 135，全部精确。
2. **缩放器是第二个模块且带第二块 BRAM**：45/16 = 2.8125 用 Bresenham 累加器（加 256、溢出减 720），垂直保持 2:1 移位；一块 BRAM 读口只认一个时钟，所以 27 MHz 读域必须有自己的 `frame_mem`。
3. **TMDS 的界是 ±8**：三阶段最小跳变编码、四个控制符号、运行差异可达 ±8 而非 8b/10b 的 ±1；时钟道不编码、固定发 `10'b1111100000`；DDC 因触摸占用 R19/P20 而不可用。

上一篇 [`41-zynq-clk.md`](41-zynq-clk.md) 讲了时钟怎么来，这一篇是它的第一个"高带宽消费者"。下一篇 [`50-cpu6502.md`](50-cpu6502.md) 回到核内部：`nes_cpu6502.v` 的 6502 指令状态机——有了 `core_clk`，CPU 才有节拍可踩。
