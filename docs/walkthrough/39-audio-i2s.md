# 39 组装层精读：`nes_audio_i2s.v`

[`26-i2s-shifter.md`](26-i2s-shifter.md) 里的位串行器只会"一位一位往外挤"，**自己不缓冲、不分频、不跨时钟域**。那么样点是谁喂的？两个时钟域怎么安全搬过去？BCLK 从哪来？`nes_audio_i2s` 就是回答这三问的**组装层**：把 FIFO、读提前窗口、intake 门、位串行器、BCLK 分频、输出寄存器拼起来，对外给出 BCLK / LRCK / DOUT 三根线。

- 源码：[`rtl/nes_core/peripheral/nes_audio_i2s.v`](../../rtl/nes_core/peripheral/nes_audio_i2s.v)
- 合同与证据：[`../modules/i2s-audio.md`](../modules/i2s-audio.md)（**下半部分 3.1–3.7 节**）
- 前置：FIFO [`21-cdc-fifo.md`](21-cdc-fifo.md)、串行器 [`26-i2s-shifter.md`](26-i2s-shifter.md)
- 测试目标：`audio-i2s-core`（elaboration）、`audio-i2s-tb`（[`tb/peripheral/tb_nes_audio_i2s.v`](../../tb/peripheral/tb_nes_audio_i2s.v)）

---

## 1. 先认识"上游和下游"

```text
写侧（wr_clk=core_clk）        读侧（rd_clk=lcd_clk）                          输出侧（mclk→bclk）
APU 采样 ─► wr_en/wr_left/wr_right ─►┌─ nes_audio_i2s ──────────────────────────────────┐
                                     │  u_fifo (nes_cdc_fifo) ─► rd_data                 │
                                     │  fetch_hold 读提前窗口 ─► rd_en                    │
                                     │  intake 门 fifo_valid = fetch_hold && ready        │
                                     │  u_shifter (nes_i2s_shifter) ─ out_bit/out_lrck ─► dout_r/lrck_r
                                     │  bclk 分频: mclk ─► bclk                          │
wr_full ◄── 唯一离开写侧 ─────────────┤                                                    │
dropped / underflow / sample_valid ───┘      下游：WM8960 (aud_bclk/aud_dac_lrc/aud_dacdat)
```

写侧 APU 每样点一个 strobe，带 `wr_left` / `wr_right` 两个 16 位声道写进 FIFO，唯一背压是 `wr_full`；读侧把样点搬过时钟域、卡住读指针、挤成位流；输出侧把 `mclk` 分频成 `bclk` 并寄存 `dout` / `lrck`。

本仓库唯一把它接起来的是 Zynq 顶层 [`nes_zynq_top.v`](../../rtl/platform/zynq/nes_zynq_top.v) 的 `u_audio_i2s`（`BCLK_DIV = 16`、`ADDR_WIDTH = 6`）：

| 端口 | 实际接到 | 说明 |
|---|---|---|
| `wr_clk` / `wr_en` | `mmcm_core_clk` / `dec_valid` | 写侧 = core 域，抽取器每输出一样点给一次 |
| `rd_clk` / `mclk` | `mmcm_lcd_clk` | **同一个网络**（见 3.7） |
| `rd_ce` | `i2s_rd_ce` | `bclk` 上升沿检测（`bclk & ~bclk_d_q`），一个 `ce` = 一位 |
| `bclk` | `aud_bclk_i` | 25 MHz / 16 = 1.5625 MHz → 帧率 48828.125 Hz |

平台还在 `dout` 上**再加一级 `bclk` 寄存器**（I2S"一位延迟"），**不在本模块里**。EP4CE10 顶层没有例化本模块。

---

## 2. 全文（模块部分；文件头约 100 行注释契约由 §3 归纳）

```verilog
`timescale 1ns/1ps

module nes_audio_i2s #(
    parameter integer DATA_WIDTH   = 32,
    parameter integer ADDR_WIDTH   = 10,
    parameter integer BCLK_DIV     = 1,
    parameter integer BIT_REVERSED = 0
) (
    input  wire        wr_clk,
    input  wire        wr_reset,
    input  wire        wr_en,
    input  wire [15:0] wr_left,
    input  wire [15:0] wr_right,
    output wire        wr_full,
    output wire        dropped,

    input  wire        rd_clk,
    input  wire        rd_reset,
    input  wire        mclk,
    input  wire        rd_ce,
    output wire        underflow,

    output wire        bclk,
    output wire        lrck,
    output wire        dout,
    output wire        sample_valid
);

    function integer log2i;
        input integer value;
        integer v;
        begin
            v = value - 1;
            for (log2i = 0; v > 0; log2i = log2i + 1)
                v = v >> 1;
        end
    endfunction

    localparam integer SAMPLE_WIDTH = 32;
    localparam integer DIV_HALF     = (BCLK_DIV / 2) < 1 ? 1 : (BCLK_DIV / 2);
    localparam integer DIV_W        = (DIV_HALF < 2) ? 1 : log2i(DIV_HALF);

    localparam [DIV_W-1:0] DIV_LAST = DIV_HALF - 1;

    wire [SAMPLE_WIDTH-1:0] wr_data;
    wire                    wr_full_i;
    wire                    rd_empty;
    wire [SAMPLE_WIDTH-1:0] rd_data;
    wire                    rd_en;

    reg                     fetch_hold;
    reg                     underflow_r;

    wire                    fifo_valid;
    wire [SAMPLE_WIDTH-1:0] sample_data;
    wire                    sh_out_valid;
    wire                    sh_out_bit;
    wire                    sh_out_lrck;
    wire                    sh_ready;
    wire                    sh_dropped;

    reg  [DIV_W-1:0]        div_cnt;
    reg                     bclk_int;
    reg                     dout_r;
    reg                     lrck_r;

    assign wr_data     = {wr_right, wr_left};
    assign wr_full     = wr_full_i;
    assign rd_en       = !rd_empty && !fetch_hold;
    assign fifo_valid  = fetch_hold && sh_ready;
    assign sample_data = rd_data;

    nes_cdc_fifo #(
        .DATA_WIDTH (SAMPLE_WIDTH),
        .ADDR_WIDTH (ADDR_WIDTH)
    ) u_fifo (
        .wr_clk   (wr_clk),
        .wr_reset (wr_reset),
        .wr_en    (wr_en),
        .wr_data  (wr_data),
        .wr_full  (wr_full_i),
        .rd_clk   (rd_clk),
        .rd_reset (rd_reset),
        .rd_en    (rd_en),
        .rd_data  (rd_data),
        .rd_empty (rd_empty)
    );

    always @(posedge rd_clk or posedge rd_reset) begin
        if (rd_reset) begin
            fetch_hold <= 1'b0;
        end else begin
            if (rd_en)
                fetch_hold <= 1'b1;
            else if (fifo_valid)
                fetch_hold <= 1'b0;
        end
    end

    always @(posedge rd_clk or posedge rd_reset) begin
        if (rd_reset) begin
            underflow_r <= 1'b0;
        end else begin
            if (rd_empty)
                underflow_r <= 1'b1;
        end
    end

    nes_i2s_shifter #(
        .BIT_REVERSED (BIT_REVERSED)
    ) u_shifter (
        .clk          (rd_clk),
        .reset        (rd_reset),
        .ce           (rd_ce),
        .sample_valid (fifo_valid),
        .sample_data  (sample_data),
        .out_valid    (sh_out_valid),
        .out_bit      (sh_out_bit),
        .out_lrck     (sh_out_lrck),
        .busy         (),
        .dropped      (sh_dropped),
        .ready        (sh_ready)
    );

    always @(posedge mclk or posedge rd_reset) begin
        if (rd_reset) begin
            div_cnt  <= {DIV_W{1'b0}};
            bclk_int <= 1'b0;
        end else begin
            if (div_cnt == DIV_LAST) begin
                div_cnt  <= {DIV_W{1'b0}};
                bclk_int <= ~bclk_int;
            end else begin
                div_cnt <= div_cnt + 1'b1;
            end
        end
    end

    assign bclk = (BCLK_DIV == 1) ? mclk : bclk_int;

    always @(posedge bclk or posedge rd_reset) begin
        if (rd_reset) begin
            dout_r <= 1'b0;
            lrck_r <= 1'b0;
        end else begin
            dout_r <= sh_out_bit;
            lrck_r <= sh_out_lrck;
        end
    end

    assign dout         = dout_r;
    assign lrck         = lrck_r;
    assign sample_valid = sh_out_valid;
    assign dropped      = sh_dropped | wr_full_i;
    assign underflow    = underflow_r;

endmodule
```

---

## 3. 逐段精读

### 3.1 头部：`log2i` 与分频常量

`function integer log2i` 是**综合期求值的常量函数**（不是硬件），算"向上取整的 log2"，只在 `localparam` 调用一次，最终变常数。`SAMPLE_WIDTH = 32` 说明数据通路**固定 32 位**（16 左 + 16 右），`DATA_WIDTH` 只在 32 默认值下有意义。`DIV_HALF` 是 BCLK **半周期**（以 `mclk` 计，至少 1）；`DIV_W` = 半周期计数器位宽；`DIV_LAST = DIV_HALF - 1`。`BCLK_DIV = 16` 时 `DIV_HALF = 8`、`DIV_W = 3`、`DIV_LAST = 7`。

### 3.2 `assign` 组合段

```verilog
assign wr_data     = {wr_right, wr_left};
assign rd_en       = !rd_empty && !fetch_hold;
assign fifo_valid  = fetch_hold && sh_ready;
assign sample_data = rd_data;
```

- **数据布局 `{wr_right, wr_left}`**：拼接"**左边是高位**"，结果是 `bit31:16 = 右`、`bit15:0 = 左`，**正好是 `nes_i2s_shifter` 期望的布局**（bit15:0 左、bit31:16 右，左声道先出）。写侧是两个 16 位窄口，拼接由本模块做——这就是"组装层"的一半含义。
- `rd_en`：**非空**且**没有已取出的样点在手**（`!fetch_hold`）时才读（§3.3）。
- `fifo_valid`：送给串行器的 `sample_valid`，等于 `fetch_hold && sh_ready`（§3.5）。
- `sample_data = rd_data`：真只是一根线。

### 3.3 核心一：`fetch_hold` 读提前窗口

```verilog
always @(posedge rd_clk or posedge rd_reset) begin
    if (rd_reset)             fetch_hold <= 1'b0;
    else if (rd_en)           fetch_hold <= 1'b1;   // 这一沿读了 -> 置位
    else if (fifo_valid)      fetch_hold <= 1'b0;   // 串行器取走 -> 清零
end
```

**为什么需要它？** 因为 **FIFO 读是破坏性的，`rd_data` 只是一个寄存器**：读太早的样点除了那个寄存器**无处可放**，读太晚的样点在串行器腾空时又不在手边。串行器每 32 个使能钟才消费一个样点，真正重要的沿只有两个：它**取新样点的沿**，和它**移出 bit31 并在同一次钟里重填的沿**（后者是忙碌串行器**唯一**还能收数据的沿，正是串行器的 `ready` 报告的）。

`fetch_hold` 就是"读提前窗口"：**读**的沿置 1（`rd_data` 里有一个已取出的样点），**串行器取走**的沿清 0。于是**至多一个已取出的样点在飞**，`rd_data` 里的样点仍被需要时**绝不会被覆盖**；读速率自动跟随消费速率。两个分支互斥（一读置位、一取清零），所以**同一个寄存器**能同时承担"装载"和"清除"。复位是 `rd_reset` 异步清零。

### 3.4 `underflow` 块：粘滞的"读到空"

`if (rd_empty) underflow_r <= 1'b1;` —— 一旦读到空就拉高，**只有 `rd_reset` 能清**（粘滞）。有了读提前窗口，读者会在串行器忙碌期间把一个样点留在 `rd_data` 里，**只要生产者跟不上，样点之间 `rd_empty` 就会再次断言**——`underflow` 报的正是这件事。**它是状态报告，不是缺陷**：`tb_nes_audio_i2s` 因此**不检查**它，并预期它会被断言。

### 3.5 intake 门 = `fetch_hold && ready`；为什么不能直接用 `ready` 去读 FIFO

`fifo_valid = fetch_hold && sh_ready` 保证**数据只在接受它的那些沿上出示**，所以串行器**永远不会丢样点**。

**为什么不用 `ready` 直接拉 `rd_en` 读 FIFO？** 通过 `ready` 在某沿发起的读要**下一个钟**才落到 `rd_data`，该样点最早只能在**再下一个沿**被取走，而那时忙碌的串行器**已经放开 `busy`**，流里就插进一个"死钟"。改用 `!fetch_hold` 节流是**提前**发读——趁串行器还忙——让 **FIFO 深度 + 那一个 `rd_data` 寄存器**把样点**一直握到 bit31 沿**。一句话：**`ready` 只能"决定要不要出示已拿在手里的数据"，不能"触发一次取数"**（同 [`26-i2s-shifter.md`](26-i2s-shifter.md) §2.4）。

### 3.6 两个子模块例化

- `u_fifo`（`nes_cdc_fifo`）把 `wr_clk` 域搬进 `rd_clk` 域；`.wr_data(wr_data)` 用的是拼接后的 32 位。跨域格雷码指针是 FIFO 内部的事（见 [`21-cdc-fifo.md`](21-cdc-fifo.md)）。
- `u_shifter`（`nes_i2s_shifter`）**完全在读侧**（`clk = rd_clk`、`reset = rd_reset`、`ce = rd_ce`）。所以 **32 位样点只在 `rd_clk` 域内交接**（FIFO → `rd_data` → 串行器），**没有任何多比特值直接跨域**。`.busy()` 括号空着 = 悬空输出，本模块不需要它。

### 3.7 BCLK 分频 + `assign bclk`

`always @(posedge mclk or posedge rd_reset)` 里数 `DIV_HALF` 个 `mclk` 周期就翻转 `bclk_int`，得到 **50% 占空比**、周期 `BCLK_DIV` 个 `mclk` 周期的方波。但 `assign bclk = (BCLK_DIV == 1) ? mclk : bclk_int;`：

- **`BCLK_DIV = 1` 直通 `mclk`**（无分频、无相位偏移），此时 `bclk_int` 不驱动任何东西。
- **`BCLK_DIV >= 2`** 才用分频器；`BCLK_DIV = 16` → 25 MHz / 16 = 1.5625 MHz。

分频器归 `mclk` 域，却用读侧 `rd_reset` 异步清零（平台里 `mclk` 与 `rd_clk` 是同一网络，见 `../modules/i2s-audio.md` §5）。

### 3.8 输出寄存器 + 尾部 `assign`

```verilog
always @(posedge bclk or posedge rd_reset) begin
    if (rd_reset) begin dout_r <= 1'b0; lrck_r <= 1'b0; end
    else          begin dout_r <= sh_out_bit; lrck_r <= sh_out_lrck; end
end

assign sample_valid = sh_out_valid;
assign dropped      = sh_dropped | wr_full_i;
```

- 串行器的 `out_bit` / `out_lrck` 是**单比特**，在 **`bclk` 上升沿**被寄存成 `dout` / `lrck`。这是读侧 → 输出侧**唯一**的跨越，只有单比特，无需同步器。
- 后果：**输出比分数据晚一个 BCLK 沿**——`sample_valid` 已报告当前位，`dout` 上还是上一位。`tb_nes_audio_i2s` 正是据此**在 `sample_valid` 上"待命"、在下一个 `bclk` 上升沿取数**。
- 之所以能安全用 `posedge bclk` 采 `rd_clk` 域的位，是因为平台把 `mclk` 与 `rd_clk` 接成**同一个网络**，`bclk` 是它同相的分频版本，采样沿与驱动沿相位相关。
- `sample_valid = sh_out_valid`：**每一位一个**单周期 strobe，**不是**采样率；APU 侧那个 1.79 MHz 的 `audio_sample_valid` 与它**同名不同物**。

---

## 4. 端口与参数表

| 参数 | 默认 | 含义 |
|---|---|---|
| `DATA_WIDTH` | 32 | 名义字宽；数据通路**固定 32 位**，只在 32 默认值下有意义 |
| `ADDR_WIDTH` | 10 | FIFO 深度指数 `2**ADDR_WIDTH`（Zynq 平台改成 6） |
| `BCLK_DIV` | 1 | BCLK 周期（以 `mclk` 计）；`1` 直通，`>=2` 分频 50% 占空比 |
| `BIT_REVERSED` | 0 | 透传给串行器的位序开关 |

| 信号 | 方向 | 域 | 合同 |
|---|---|---|---|
| `wr_clk` / `wr_reset` / `wr_en` | in | 写 | 写侧时钟 / 异步复位 / 写使能（`wr_full` 高时被忽略） |
| `wr_left` / `wr_right [15:0]` | in | 写 | 左 / 右声道样点 |
| `wr_full` | out | 写 | **唯一真正丢采样的背压信号**，写侧唯一离开域的信号 |
| `rd_clk` / `rd_reset` / `rd_ce` | in | 读 | 读侧时钟 / 异步复位 / 串行器 `ce`（一 `ce` = 一位） |
| `underflow` | out | 读 | 粘滞"读到空"标志，`rd_reset` 清零 |
| `mclk` | in | 输出 | BCLK 分频源时钟 |
| `bclk` / `lrck` / `dout` | out | 输出 | 位时钟 / 声道标记 / 串行数据（后两者在 `bclk` 上升沿寄存） |
| `sample_valid` | out | 输出 | 等于串行器 `out_valid`：**每位一个**单周期 strobe |
| `dropped` | out | 两域并集 | `sh_dropped \| wr_full_i` |

---

## 5. 一个采样从写 FIFO 到 `dout` 逐拍走一遍

以 `tb_nes_audio_i2s` 为例：`wr_clk` 周期 10 ns，`rd_clk = mclk` 周期 20 ns，`BCLK_DIV = 1`（故 `bclk = mclk = rd_clk` 同周期同相位），`rd_ce` 恒 1，四个样点**背靠背**写入；一样点 = 32 个 `rd_clk` 沿 = 640 ns。

| `rd_clk` 沿 | 读侧发生的事 | `fetch_hold` | 串行器 |
|---|---|---|---|
| 写侧连续 4 个 `wr_clk` | 4 样点全部入队，FIFO 非空 | 0 | 空转 |
| 第 1 沿 | `rd_en = !empty && !fetch_hold = 1` → 读出样点 0 到 `rd_data` | **0→1** | 空闲，但 `fifo_valid` 用的是**旧** `fetch_hold=0`，**这一沿不出示** |
| 第 2 沿 | `fifo_valid = 1 && ready(1) = 1`；同时 `rd_en` 又为 1，读出样点 1 到 `rd_data` | **1→0** | **接收样点 0**，`busy→1` |
| 第 3..33 沿 | 移位 32 位（左 16 + 右 16），窗口里握着样点 1 | 保持 1 | 每沿一位，`out_valid` 每位一个脉冲 |
| 第 34 沿（bit31） | `fifo_valid = fetch_hold && ready(=freeing)` | 1→0 | **同一次钟里移出 bit31 并重填样点 1**，无死钟 |
| … | 重复 | … | … |

**输出侧**：`out_bit` / `out_lrck` 每个 `bclk` 上升沿被采到 `dout` / `lrck`，所以 **`sample_valid` 比 `dout` 上对应的位早一个 `bclk` 沿**。因为四个样点**提前**都在 FIFO 里，读者总能在 bit31 沿前把下一个样点握在 `rd_data` 里，所以 **`sample_valid` 之间的 `bclk` 沿不得空闲**（testbench 把任何"strobe 之间 `sample_valid` 为低"的沿判为 `$fatal`），且正常路径下 **`dropped` 从不升起**。

---

## 6. 常见疑问

**Q：`dropped` 到底是什么？和 `underflow` 有何不同？**

A：`dropped = sh_dropped | wr_full_i` 是**两条丢样路径的并集**：`sh_dropped` 是串行器的**粘滞丢弃**（忙时被丢的 `sample_valid`，有了 §3.5 的 intake 门**正常不该出现**）；`wr_full_i` 是**写侧在 FIFO 满时还塞样点**——`wr_full` 高时的 `wr_en` 被 FIFO 忽略，那个样点**真的没了**。`wr_full` 是"**唯一真正丢采样**"的背压条件，生产者必须尊重它。`dropped` **只是状态标志**，不是握手、两域都不消费，所以跨域合并两项是**有意为之**。而 `underflow` 是"读到空"（生产者跟不上），**预期发生、不是缺陷**。

**Q：`fetch_hold` 会不会让第一个样点被读两次？** 不会。`rd_en = !rd_empty && !fetch_hold`，读后 `fetch_hold` 立刻置 1 挡住第二次读，直到串行器取走才清零。

**Q：为什么平台上 `rd_clk` 和 `mclk` 是同一个网？** 因为 §3.8 用 `posedge bclk` 采 `rd_clk` 域的位；若两者无关，就是**未同步的两比特跨越**。接成同一网络后 `bclk` 是它同相的分频版本，每一位在整整一个 BCLK 周期内稳定。

**Q：`sample_valid` 是采样率吗？** **不是**。它是串行器 `out_valid`，**每一位一个**。APU 侧 1.79 MHz 的 `audio_sample_valid` 才是"每样点一个"。

---

## 7. 你应该带走的三件事

1. **破坏性读 + 单寄存器 ⇒ 必须提前读**：`rd_data` 只是一个寄存器，读太早无处放、读太晚来不及。`fetch_hold` 读提前窗口让读速率跟随消费速率，`rd_en = !rd_empty && !fetch_hold`；它在**读**的沿置 1、在**串行器取走**的沿清 0。
2. **`ready` 是许可不是触发器**：`sample_valid = fetch_hold && ready`；`ready` 只能"决定要不要出示已拿在手里的数据"，**绝不能用它去发起一次 FIFO 读**（那会插进死钟）。
3. **背压只有一个真丢样条件**：`wr_full` 是"真正丢采样"的唯一条件；`dropped = sh_dropped | wr_full`，`underflow` 是粘滞"读到空"报告（预期出现）。`BCLK_DIV = 1` 直通 `mclk`、`>= 2` 50% 分频；`dout` / `lrck` 在 `bclk` **上升沿**寄存，所以 `sample_valid` 比 `dout` 早一个 `bclk` 沿。

下一篇 [`40-wm8960-i2c.md`](40-wm8960-i2c.md)：I2S 把样点送到 codec，codec 自己怎么被配置？看 `wm8960_i2c.v` 如何用一根 I2C 主控状态机在上电时把 WM8960 的寄存器配好。
