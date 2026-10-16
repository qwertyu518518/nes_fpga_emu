# 26 位串行器精读：`nes_i2s_shifter.v`

前面几篇讲的都是"存储/搬运/协议状态机"。这一篇讲一种更"贴身"的硬件：**位串行器**。它要做的事，用一句话说就是：

> **把一个 32 位的立体声样点，拆成 [15]、[14] … [0] 一位一位地往外挤，每次时钟使能挤一位，挤完 32 位正好送完一个样点。**

它没有 FIFO、没有分频器、不跨时钟域——**只拥有位流本身**（速率转换、缓冲、跨域是外面 `nes_audio_i2s` 的活）。读完你会弄清三件事：I2S 的 LRCLK/BCLK 相位、`bit_cnt ^ 5'h0f` 这类"索引算术"、以及一个忙碌移位器如何在**同一次钟**里既送走旧样点又收下新样点。

- 源码：[`rtl/nes_core/peripheral/nes_i2s_shifter.v`](../../rtl/nes_core/peripheral/nes_i2s_shifter.v)
- 合同与证据：[`../modules/i2s-audio.md`](../modules/i2s-audio.md)（上半部分讲本模块，**2.1–2.7 节**是逐条合同）
- 上游组装层：[`rtl/nes_core/peripheral/nes_audio_i2s.v`](../../rtl/nes_core/peripheral/nes_audio_i2s.v)（CDC FIFO + 读提前窗口 + intake 门 + BCLK 分频）
- 测试目标：`i2s-shifter-core`（elaboration）、`i2s-shifter-tb`（跑 [`tb/peripheral/tb_nes_i2s_shifter.v`](../../tb/peripheral/tb_nes_i2s_shifter.v)），见 [`../../tools/sim_all.ps1`](../../tools/sim_all.ps1)

---

## 1. 先认识"上游和下游"，以及 I2S 的三根线

```text
上游：nes_audio_i2s 读侧                          本模块                       下游：输出寄存器 / 采集
  rd_clk  ───────────────────────────────────► [nes_i2s_shifter]
  rd_ce   ───────────────────────────────────►   (32 位位串行器)
  ready   ◄───────────────────────────────────    out_valid ─► 每位一个单周期 strobe
  intake 门 ─► sample_valid ──────────────────►   out_bit   ─► dout @ bclk 上升沿
  rd_data  ─────────────────► sample_data ────►   out_lrck  ─► lrck @ bclk 上升沿
  busy / dropped ◄────────────────────────────┘
```

- **上游**：`nes_audio_i2s` 的读侧把 FIFO 里的样点取到 `rd_data`，再经一个 **intake 门**变成单周期的 `sample_valid`，用 `rd_clk` / `rd_ce` 喂进来；`ready` 是它判断"能不能出示"的依据（§3.3）。
- **下游**：`out_bit` / `out_lrck` 被 `bclk` 上升沿的输出寄存器（在组装层里）接走，成为 `dout` / `lrck`；`out_valid` 是**每一位**一个的 strobe，供采集/调试。
- **`busy`** 告诉上游"样点在飞"；**`dropped`** 是粘滞状态标志。

I2S 是"一根时钟、一根声道标记、一根数据"的三线同步串行总线：

| 线 | 本设计（从机、只发） | 作用 |
|---|---|---|
| `BCLK` | out | 位时钟。**一位占一个 BCLK 周期。** 本模块用 `ce` 抽象它：一个 `ce` 有效沿 = 一位。 |
| `LRCLK` / `WS` | out | 声道标记。**低 = 左、高 = 右**。 |
| `SD` / `DIN` | out | 串行数据，**MSB first**。 |

规格要点（就是本模块要兑现的三条）：

1. **一帧 = 32 位。** 一个样点是 16 位左 + 16 位右。
2. **左声道先出**：`out_lrck` 在流的**第 17 位**（0 基下标 16）从低翻到高，即"从左声道进入右声道"的那一位翻转。
3. **MSB first**（默认）：每声道从最高位开始送。

---

## 2. 全文（模块部分，含 `timescale`）

文件头有一整段注释契约（范围 / 样点格式 / 位序 / 吞吐 / 装载 / 输出 / `ready`），下面 §3.1 会逐条讲；这里先看**可综合的代码**：

```verilog
`timescale 1ns/1ps

module nes_i2s_shifter #(
    parameter BIT_REVERSED = 0
) (
    input  wire        clk,
    input  wire        reset,
    input  wire        ce,
    input  wire        sample_valid,
    input  wire [31:0] sample_data,
    output reg         out_valid,
    output reg         out_bit,
    output reg         out_lrck,
    output reg         busy,
    output reg         dropped,
    output wire        ready
);

    localparam [4:0] LAST_BIT = 5'd31;

    reg  [31:0] shift_reg;
    reg  [4:0]  bit_cnt;

    wire [4:0]  sel;
    wire        lrck_next;
    wire        freeing;

    assign sel       = (BIT_REVERSED != 0) ? bit_cnt : (bit_cnt ^ 5'h0f);
    assign lrck_next = bit_cnt[4];
    assign freeing   = ce && busy && (bit_cnt == LAST_BIT);
    assign ready     = !busy || freeing;

    always @(posedge clk) begin
        if (reset) begin
            shift_reg <= 32'h0;
            bit_cnt   <= 5'h0;
            out_valid <= 1'b0;
            out_bit   <= 1'b0;
            out_lrck  <= 1'b0;
            busy      <= 1'b0;
            dropped   <= 1'b0;
        end else begin
            if (sample_valid) begin
                if (busy && !freeing) begin
                    dropped <= 1'b1;
                end else begin
                    shift_reg <= sample_data;
                    bit_cnt   <= 5'h0;
                    busy      <= 1'b1;
                end
            end

            if (ce) begin
                out_valid <= 1'b0;
                if (busy) begin
                    out_valid <= 1'b1;
                    out_bit   <= shift_reg[sel];
                    out_lrck  <= lrck_next;
                    if (bit_cnt == LAST_BIT) begin
                        bit_cnt <= 5'd0;
                        busy    <= sample_valid;
                    end else begin
                        bit_cnt <= bit_cnt + 5'd1;
                    end
                end
            end
        end
    end

endmodule
```

先分清三类东西（[`01-verilog-basics.md`](01-verilog-basics.md) 第 1 节）：四条 **`assign` 是组合逻辑**；`shift_reg`、`bit_cnt`、五个输出 `reg` 是**寄存器**，只在 `posedge clk` 更新；真正的指挥中心是那一个 `always` 块。

---

## 3. 逐段精读

### 3.1 文件头就是合同

文件头把设计事实写成了七条（对应 `../modules/i2s-audio.md` 的表）：

| 头部小节 | 一句话 |
|---|---|
| Scope | 只有位流，**没有 FIFO / 分频 / CDC**。 |
| Sample format | `sample_data[15:0]`=左、`[31:16]`=右，**左先出**，`out_lrck` 第 17 位翻转。 |
| Bit order | `BIT_REVERSED=0`（默认）MSB first；`=1` 每声道内部反序，**声道顺序不变**。 |
| Throughput | 一个样点恰占 **32 个 `ce` 有效沿**；没有死钟、没有第 33 个 done 脉冲。 |
| Intake | 任意 `sample_valid` 高且 `busy` 低的沿接收，**与 `ce` 无关**；第一位在下一个 `ce` 沿出。 |
| Outputs | `out_valid` 每位一个 strobe；`ce=0` 冻结（`dropped` 不受 `ce` 门控）。 |
| ready | `!busy || freeing`，是**许可**不是 look-ahead（§3.3）。 |

### 3.2 参数与位宽常量

模块头部只有一个参数 `BIT_REVERSED = 0`（默认 MSB first）；另有一个内部常量 `localparam [4:0] LAST_BIT = 5'd31`，给 `bit_cnt` 的终止值起名字（避免魔法数字）。`bit_cnt` 是 5 位，正好数 0..31。

### 3.3 四条组合 `wire`：整套时序的"算式"

```verilog
assign sel       = (BIT_REVERSED != 0) ? bit_cnt : (bit_cnt ^ 5'h0f);
assign lrck_next = bit_cnt[4];
assign freeing   = ce && busy && (bit_cnt == LAST_BIT);
assign ready     = !busy || freeing;
```

**`sel`（选哪一位出去）。** 默认支是 `bit_cnt ^ 5'h0f`。为什么**异或**？看 `bit_cnt` 的取值：低位 0..15 送左声道、16..31 送右声道（由 bit4 决定声道）。我们希望"声道内从 MSB 开始"，也就是 `bit_cnt=0` 取 `bit15`、`=15` 取 `bit0`、`=16` 取 `bit31`、`=31` 取 `bit16`。

`bit_cnt ^ 5'h0f` 的妙处：`5'h0f = 5'b01111`，**只翻转低 4 位，bit4 不动**。对 0..15 而言 `v ^ 15 = 15 - v`（因为 15=0b1111 且 v 不借位），于是 0→15、1→14 …… 15→0；对 16..31 而言低 4 位同样反转，bit4 保持 1，于是 16→31 …… 31→16。**一句话：一次异或同时完成了"两个声道各自的反序"，还顺手保住了声道边界**——这正是"MSB first"。

`BIT_REVERSED=1` 时 `sel = bit_cnt`，就是顺着取（0→0 … 16→16），于是每声道变成 LSB first；**声道顺序没动**，左声道仍占前 16 位。

**`lrck_next`（下一拍 `out_lrck` 该是多少）。** 它就是 `bit_cnt[4]`：前 16 位（`bit_cnt` 0..15）为 0，后 16 位（16..31）为 1。因为它是**寄存器 `out_lrck` 的下一拍值**，所以名字带 `_next`（[`02-project-conventions.md`](02-project-conventions.md) 第 2 节）。

**`freeing`（这一沿会"腾空"寄存器吗）。** 当且仅当 **`ce` 有效 + 忙 + 正数到最后一位（`bit_cnt==31`）**：这一沿移出 bit31、寄存器随即空出来。

**`ready`（能收新样点吗）。** `= !busy || freeing`。语义：**即将到来的这一沿上，`sample_valid` 上提出的样点被保证接收**——要么寄存器空闲，要么恰好是这个"移走 bit31 并在同一次钟里重填"的沿。

> `ready` **不是 look-ahead**：它只许愿**当前这一沿**，不说任何关于再下一个沿的事。它是 `busy` / `bit_cnt` / `ce` 的纯组合函数，全在本模块时钟域里，所以同钟的驱动方可以直接用，**不需要同步器**。反过来，驱动方必须"手里已经拿着数据"，因为数据没法在评估这一沿的同一次钟里被生产出来。`nes_audio_i2s` 正是用 `fetch_hold && ready` 把它变成单周期脉冲的（合同 §3.5）。

### 3.4 复位块

`if (reset)` 是最高优先级分支（代码见 §2）：把 `shift_reg`、`bit_cnt` 和五个输出 `reg` 全部清 0。它是**同步复位**（敏感列表是 `always @(posedge clk)`，没有 `or posedge reset`），高有效。TB 的 `do_reset` 在复位后断言 `busy`/`out_valid`/`dropped`/`out_bit`/`out_lrck` **全 0**，还断言释放复位后它们保持低；`dropped` 的两次 `do_reset` 专门验证"粘滞标志确实被复位清掉"。

### 3.5 装载块：忙时丢弃 + 粘滞 `dropped` + 装载沿不出位

```verilog
if (sample_valid) begin
    if (busy && !freeing) begin
        dropped <= 1'b1;         // 忙、且不是 freeing 沿 -> 丢弃
    end else begin
        shift_reg <= sample_data; // 否则装载
        bit_cnt   <= 5'h0;
        busy      <= 1'b1;
    end
end
```

这一段**不在 `if (ce)` 里**——所以装载**与 `ce` 无关**：只要 `sample_valid` 高、`busy` 低，这一沿就收下（合同：任意沿接收）。

- **忙时丢弃**：`busy && !freeing` 时提的样点被丢弃，**在飞的样点完全不受影响**，只把 `dropped` 置 1。`dropped` 是**粘滞**的（没有任何语句把它清 0，只有复位能清），它高就表示"确实有一个样点无处可去"。TB 在飞行中途注入一个样点，断言 `dropped` 升起、位流一位不差、被丢的样点之后也不会补发。
- **`freeing` 是唯一例外**：忙碌移位器**唯一**还能接受样点的沿（见 §3.7）。
- **装载沿不输出**：装载只写寄存器。如果这一沿 `ce` 也高，下面 `ce` 块里的 `if (busy)` 看到的是**旧 `busy`（还是 0）**，所以不会出位。第一位要到**下一个 `ce` 有效沿**才出现。TB 断言"装载钟不得出位、`nbit` 仍为 0"。

> 为什么"旧 `busy`"？因为时序块里全部用**非阻塞 `<=`**：同一沿里所有右边按"沿开始时的值"同时算，`busy <= 1'b1` 要到沿结束才生效（[`01-verilog-basics.md`](01-verilog-basics.md) 第 7 节）。这是整个模块能"同一次钟既装载又判断"的基础。

### 3.6 `ce` 块：冻结与 `out_valid` strobe

```verilog
if (ce) begin
    out_valid <= 1'b0;
    if (busy) begin
        out_valid <= 1'b1;
        out_bit   <= shift_reg[sel];
        out_lrck  <= lrck_next;
        if (bit_cnt == LAST_BIT) begin
            bit_cnt <= 5'd0;
            busy    <= sample_valid;      // 见 §3.7
        end else begin
            bit_cnt <= bit_cnt + 5'd1;
        end
    end
end
```

**移位逻辑整段夹在 `if (ce)` 里**，这就是"冻结"的实现（[`02-project-conventions.md`](02-project-conventions.md) 第 1 节、[`01-verilog-basics.md`](01-verilog-basics.md) 第 9 节）：`ce=0` 时整个块不执行，于是 `out_valid` 保持电平、`out_bit` / `out_lrck` 保持当前位、`busy` 保持电平、`bit_cnt` 不前进。一个 `ce` 缺口是**把流拉长**而不是丢位。TB 在流中途插 5 个 `ce=0` 的钟，断言四个流引脚 + `busy` + `dropped` 都不动、位计数也不前进。

`ce=1` 时：`out_valid` 先被清 0，再在"忙"时置 1——所以它是**每位一个单周期脉冲**，一个样点恰好 32 个高周期。`out_bit <= shift_reg[sel]` 用 §3.3 的索引算术选位；`out_lrck <= lrck_next` 用 `bit_cnt[4]` 打声道标记。

> 注意停止时的行为：不被重填时 `busy` 归零，后续 `ce` 沿走不进 `if (busy)`，`out_bit` / `out_lrck` **保持最后一个值**（合同原文）——它们不会被清 0，直到复位。

### 3.7 `busy <= sample_valid`：为什么它能做到"背靠背无空隙"

这是全模块最精妙的一句。看第 32 个 `ce` 沿（`bit_cnt==LAST_BIT`）会发生什么：

- 此时 `freeing` 为真（`ce && busy && bit_cnt==31`）。
- 若同一沿 `sample_valid=1`：§3.5 的装载块因 `!freeing` 不成立而**走 `else` 装载**——`shift_reg <= sample_data`、`bit_cnt <= 0`、`busy <= 1`；同时 §3.6 又写 `busy <= sample_valid = 1`。两条写的值一致，**新样点在同一次钟里被装进移位寄存器，`busy` 保持高**。于是**下一个 `ce` 沿已经在移出新样点的 bit0**——这就是 `nes_audio_i2s` 里说的"serialiser 每 32 个使能钟消费一个样点，只有两个沿重要"。
- 若同一沿 `sample_valid=0`：装载块不执行，只有 §3.6 的 `busy <= sample_valid = 0` 生效，`busy` 落下，流停止。

**为什么不是 `busy <= 1'b0` 再靠别处重填？** 因为 `busy <= sample_valid` 用**一个表达式覆盖了两种命运**：有新品就继续忙、没有就收工。又因为它和装载是**同一次非阻塞钟**，新数据的 `shift_reg` 与 `busy` 同时落地，中间**没有多出的那一拍**。TB 的背靠背用例连续送 5 个样点、每个之间只留 1 个 `ce` 缺口，断言恰好 160 位、`dropped` 从不升起、两实例都跑完——只要少一拍或丢一相位就会失败。

---

## 4. 参数与端口表

| 参数 | 默认 | 含义 |
|---|---|---|
| `BIT_REVERSED` | `0` | `0`=MSB first（默认）；`1`=每声道内部 LSB first，**声道顺序不变**。 |

| 端口 | 方向 | 位宽 | 作用 |
|---|---|---|---|
| `clk` | in | 1 | 唯一时钟，所有状态只在 `posedge clk` 更新。 |
| `reset` | in | 1 | **同步、高有效**；清 `shift_reg`/`bit_cnt`/五个输出寄存器。 |
| `ce` | in | 1 | 时钟使能。高 = 推进一位；低 = 状态机冻结。 |
| `sample_valid` | in | 1 | 装载请求，**电平、任意沿**；`busy` 低时被接收，`freeing` 沿是忙时唯一例外。 |
| `sample_data` | in | 32 | `{right[15:0], left[15:0]}`，bit15:0=左、bit31:16=右。 |
| `out_valid` | out (reg) | 1 | **每位一个单周期 strobe**；一个样点恰好 32 个高周期。 |
| `out_bit` | out (reg) | 1 | 串行数据位；`ce` 低时保持当前位。 |
| `out_lrck` | out (reg) | 1 | 声道标记；前 16 位低、后 16 位高，**第 17 位翻转**。 |
| `busy` | out (reg) | 1 | 高 = 有样点在飞；装载沿拉高，移完第 32 位后（未重填则）拉低。 |
| `dropped` | out (reg) | 1 | **粘滞**丢样标志；忙时被丢弃的 `sample_valid` 置一，直到复位。 |
| `ready` | out (wire) | 1 | 接收许可 = `!busy || freeing`，**组合**，不是 look-ahead。 |

五个输出写成 `output reg`（而非 `wire`），是因为它们都在 `always` 块里被 `<=` 赋值；`ready` 是 `assign` 驱动的，所以是 `wire`（[`01-verilog-basics.md`](01-verilog-basics.md) 第 3 节）。

---

## 5. 一个样点走完 32 个 `ce` 沿（逐拍）

约定：**一拍 = 一个 `ce=1` 的 `posedge`**（`clk` 上升沿）。取样点 `sample_data = 32'hABCD_1234`，即 **左 `left = 16'h1234`、右 `right = 16'hABCD`**，默认 `BIT_REVERSED=0`。左 `0x1234` 的 bit[15..0] = `0,0,0,1,0,0,1,0,0,0,1,1,0,1,0,0`；右 `0xABCD` 的 bit[15..0] = `1,0,1,0,1,0,1,1,1,1,0,0,1,1,0,1`。

| 沿 | 沿前 `bit_cnt` | `sel` | 沿后 `out_bit` | 沿后 `out_lrck` | 说明 |
|---|---|---|---|---|---|
| 装载沿 | —（`busy`=0） | — | 保持 | 保持 | `shift_reg<=ABCD_1234`、`bit_cnt<=0`、`busy<=1`；**不出位** |
| `ce` #1 | 0 | 15 | `left[15]`=0 | 0 | 左声道 MSB（第 1 位） |
| `ce` #2..#15 | 1..14 | 14..1 | `left[14]`..`left[1]` | 0 | 左声道其余位，MSB 依次 |
| `ce` #16 | 15 | 0 | `left[0]`=0 | 0 | 左声道 LSB（第 16 位） |
| `ce` #17 | 16 | 31 | `right[15]`=1 | **1** | **`lrck` 翻转**（`bit_cnt[4]=1`）；右声道 MSB |
| `ce` #18 | 17 | 30 | `right[14]`=0 | 1 | |
| `ce` #31 | 30 | 17 | `right[1]`=0 | 1 | 右声道第 15 位 |
| `ce` #32 | 31 | 16 | `right[0]`=1 | 1 | 右声道 LSB；`bit_cnt<=0`、`busy<=sample_valid` |

拼起来看比特流（这就是 TB 逐位比对的东西）：

```text
位次序 : 1  2 ... 16 | 17 18 ... 32
out_bit: left[15] ... left[0] | right[15] ... right[0]
         = 0 0 0 1 0 0 1 0 0 0 1 1 0 1 0 0 | 1 0 1 0 1 0 1 1 1 1 0 0 1 1 0 1
out_lrck: 0 ... 0 （16 位）  |  1 ... 1 （16 位）      <- 恰在第 17 位翻转
```

`bit_cnt[4]` 在 0..15 恒 0、在 16..31 恒 1，所以 `lrck` 低/高各 16 位、翻转点严格落在第 17 位。`sel` 把"前半取 15..0、后半取 31..16"一次算完，就是 MSB first 的来源。TB 用同一激励同时驱动 `BIT_REVERSED=0/1` 两个实例：参考模型按**声道语义**写成、逐位比对，并特意断言两条位流**不相同**（`diffs != 0`），否则测试样点分不出两种次序；`check_lrck_split` 还逐位核对 16/16 分裂与"第 17 位必须翻转"。

---

## 6. 常见疑问

**Q：`bit_cnt ^ 5'h0f` 为什么不用 `15 - bit_cnt`？**
A：因为 `bit_cnt` 要跨两个声道（0..31）。`15 - bit_cnt` 在 `bit_cnt>15` 时会下溢、把右声道算错。异或 `0x0f` 只翻低 4 位、`bit4` 不动，于是**两个声道各自反序**一次完成，还天然保住了声道边界。

**Q：`ready` 不就是"下次是 `bit_cnt==31` 的沿"吗？为什么不提前看下一位？**
A：不是。`ready` 只回答**当前这一沿**能不能收，它不预测任何更晚的沿。它是一个纯组合函数，正因为只看当前，才不需要同步器，也才能在"数据已经在手"的前提下被安全使用。

**Q：装载沿为什么明明 `ce=1` 也不出位？**
A：因为 `busy` 是这一沿**才**被置 1 的（非阻塞 `<=`）。`ce` 块里的 `if (busy)` 读到的是沿开始时的旧值 0，所以这一沿不推进。第一位总是"下一个 `ce` 沿"。

**Q：忙时来的 `sample_valid` 会怎样？**
A：被**丢弃**——在飞的样点一位不动、`dropped` 置 1 且粘滞到复位。唯一例外是 `freeing` 沿（正好移出 bit31），那时它能被接收并实现背靠背（§3.7）。

**Q：`ce=0` 会丢位吗？会不会让 `dropped` 也冻结？**
A：不会丢位。`ce=0` 只冻结 `if (ce)` 里的移位/输出；`out_bit`/`out_lrck`/`out_valid`/`busy`/`bit_cnt` 全部保持，流被"拉长"。而 `dropped` 在**装载块**里更新，**不受 `ce` 门控**，所以 `ce=0` 期间若来一个忙时的 `sample_valid`，`dropped` 照常置 1。

**Q：两个声道之间为什么没有"死钟"？**
A：因为第 32 个 `ce` 沿既清 `bit_cnt`、又（在 `freeing` 下）借同一沿的新数据重填 `shift_reg`，`busy<=sample_valid` 还保持在线。于是**下一次 `ce` 沿直接是新样点的 bit0**，中间不多一拍，也没有第 33 个 done 脉冲。

---

## 7. 你应该带走的三件事

1. **`ce` 抽象 BCLK，`bit_cnt` 抽象位相位**：一个 `ce` 有效沿 = 一位；`bit_cnt` 0..31 决定当前是左还是右、是第几位。`sel = bit_cnt ^ 5'h0f` 一次异或同时完成"两声道各自 MSB first"，`bit_cnt[4]` 一次取位给出 `lrck` 并在第 17 位翻转。
2. **装载与移位用同一次非阻塞钟"合流"**：装载块不在 `if (ce)` 里（任意沿可收），移位块在 `if (ce)` 里（`ce=0` 冻结）；`busy <= sample_valid` 让忙碌移位器在移走最后一位的同一沿决定"续命还是收工"，配合同一沿的 `shift_reg` 重填，实现背靠背无空隙。
3. **`ready` 是许可不是预测**：`= !busy || freeing`，是接收逻辑本来就用的两个条件的纯组合观察，同钟可用、无需同步器；忙时提出的 `sample_valid` 仍被丢弃、`dropped` 仍粘滞。

下一篇 [`30-cpu-bus.md`](30-cpu-bus.md) 回到 NES 主线的中等规模模块：`nes_cpu_bus.v` 如何做地址译码与等待态。
