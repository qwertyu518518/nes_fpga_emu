# 11 第二种纯组合模块：`nes_apu_length_lut.v`

上一篇 [`10-mapper-nrom.md`](10-mapper-nrom.md) 的纯组合模块用 `assign` 做"地址翻译"。这一篇看第二类纯组合模块：**查表（LUT，look-up table）**。它只回答一个问题：

> **给我一个 0~31 的小编号（`index`），NES 声音的"时长（length）"应该是多少个半帧？**

一句代码就能说清：**把输入的编号当成下标，去一张写死的表里取出对应的常数。** 这就是硬件里的"查表"。

- 源码：[`rtl/nes_core/apu/nes_apu_length_lut.v`](../../rtl/nes_core/apu/nes_apu_length_lut.v)
- 合同与证据：[`../modules/apu-full.md`](../modules/apu-full.md)（§2.1 公共部件、§6 实现清单）
- 测试目标：`apu-core`（只 elaborate，确认能编译）、`apu-tb`（跑 `tb_nes_apu2a03.v`）；见 [`tools/sim_all.ps1`](../../tools/sim_all.ps1)

---

## 1. 先认识"上游和下游"

```text
CPU 写 $4003/$4007/$400B/$400F 最高 5 位
        │
        ▼
   index[4:0] ──► [nes_apu_length_lut] ──► value[7:0]
                                              │
                                              ▼
                          通道模块把 value 装进 length 计数器，
                          之后由 frame sequencer 每半帧减 1
```

- **上游**：游戏写 `$4003`（pulse 1）、`$4007`（pulse 2）、`$400B`（triangle）、`$400F`（noise）时，寄存器的高 5 位就是这张表的**下标**。
- **下游**：四个通道（`nes_apu_pulse/triangle/noise`）都拿同一个 `value` 去装载自己的 length 计数器。四路共用一份表，所以本仓库把它单独抽成一个模块，避免把 32 项常数抄 4 遍。

length 计数器每次"半帧"信号到来就减 1，减到 0 通道静音。这张表只是**起点值**，递减的事由别的模块做——本模块**没有时钟、没有状态**。

---

## 2. 全文（45 行）

```verilog
`timescale 1ns/1ps

module nes_apu_length_lut (
    input wire [4:0] index,
    output reg [7:0] value
);

always @* begin
    case (index)
        5'd0: value = 8'd10;
        5'd1: value = 8'd254;
        5'd2: value = 8'd20;
        5'd3: value = 8'd2;
        5'd4: value = 8'd40;
        5'd5: value = 8'd4;
        5'd6: value = 8'd80;
        5'd7: value = 8'd6;
        5'd8: value = 8'd160;
        5'd9: value = 8'd8;
        5'd10: value = 8'd60;
        5'd11: value = 8'd10;
        5'd12: value = 8'd14;
        5'd13: value = 8'd12;
        5'd14: value = 8'd26;
        5'd15: value = 8'd14;
        5'd16: value = 8'd12;
        5'd17: value = 8'd16;
        5'd18: value = 8'd24;
        5'd19: value = 8'd18;
        5'd20: value = 8'd48;
        5'd21: value = 8'd20;
        5'd22: value = 8'd96;
        5'd23: value = 8'd22;
        5'd24: value = 8'd192;
        5'd25: value = 8'd24;
        5'd26: value = 8'd72;
        5'd27: value = 8'd26;
        5'd28: value = 8'd16;
        5'd29: value = 8'd28;
        5'd30: value = 8'd32;
        default: value = 8'd30;
    endcase
end

endmodule
```

整份代码没有 `clk`、没有 `reset`、没有一行 `posedge`。它是一个**纯组合电路**：`index` 一变，`value` 立刻跟着变（有一定逻辑延迟）。综合工具会把它变成一小片组合逻辑（查表 LUT + 选择网络）。

---

## 3. 逐段精读

### 3.1 模块声明与端口

```verilog
module nes_apu_length_lut (
    input wire [4:0] index,
    output reg [7:0] value
);
```

- `input wire [4:0] index`：5 位输入，取值范围 `0~31`（2^5 = 32 个可能值），正好够当 32 项表的下标。
- `output reg [7:0] value`：8 位输出，最大的表值 `254` 需要 8 位才放得下。
- **为什么输出是 `reg` 而不是上一篇的 `wire`？** 因为 `value` 是在 `always` 过程块里被赋值的。规则很简单：

  | 输出写法 | 由谁驱动 | 出现在什么时候 |
  |---|---|---|
  | `output wire` | `assign` 或子模块输出 | 纯 `assign` 模块（如 NROM） |
  | `output reg` | `always` 块里的 `=` 或 `<=` | 有过程块的模块（如本模块） |

  这里的 `reg` **不是"寄存器"**（没有存储、没有时钟），只是"这根线由 `always` 块驱动"这个语法要求。这是新手最容易误会的一点，见第 6 节。

### 3.2 `always @*`：组合块的另一种写法

```verilog
always @* begin
    case (index)
        ...
    endcase
end
```

- `always @*` 里的 `*` 表示"敏感列表交给工具自动推断"：工具发现块里读了 `index`，就自动对 `index` 敏感，`index` 一变就重算。
- `always @*` 是**组合逻辑**，不是寄存器（对比 [`01-verilog-basics.md`](01-verilog-basics.md) §5、§6）。
- 组合块里必须用**阻塞赋值 `=`**，不能用 `<=`。原因：组合块描述的是"一条线上电流立刻流过"，`=` 就是"立刻算出新值"；而 `<=` 的含义是"等到时钟沿再更新"，用在组合块里会让仿真和综合对不上。

### 3.3 `case (index)`：一个分支一个表项

```verilog
        5'd0: value = 8'd10;
        5'd1: value = 8'd254;
        ...
        5'd30: value = 8'd32;
```

- `case (index) ... endcase` 和 C 的 `switch` 很像：拿 `index` 的值去和每个分支的常数比，相等就执行那一行。
- 每个分支只做一件事：把一个十进制常数写进 `value`。所以整块逻辑等价于"**用 `index` 当下标去数组取数**"。
- 本项目选择"用 `case` 写表"而不是声明一个 `reg [7:0] rom [0:31]`，是因为 EP4CE10 上这种小常量表用组合逻辑（分布式 LUT）实现最省，不需要真的 BRAM；而且 Verilog-2001 里数组的写法在综合时反而更容易出意外（这一点在 [`../modules/apu-full.md`](../modules/apu-full.md) §1.1 有解释）。

### 3.4 常数怎么读：`5'd0`、`8'd10`

Verilog 的常数格式是 **位宽 `'` 进制 数值**，宽写在前面、`'` 后面跟一个进制字母：

| 进制字母 | 含义 | 例子 |
|---|---|---|
| `'d` | 十进制 | `8'd10` = 8 位十进制 10 |
| `'b` | 二进制 | `4'b1010` = 4 位二进制 1010（也就是十进制 10） |
| `'h` | 十六进制 | `8'hFF` = 8 位十六进制 FF |

所以：

- `5'd0`：宽 5 位、十进制、值 0。写成二进制是 `00000`，正好是 `index` 的宽度。
- `8'd10`：宽 8 位、十进制、值 10。写成二进制是 `00001010`，正好是 `value` 的宽度。

**位宽写在前面、和端口宽度对齐**，是为了让工具准确分配位数，也让人一眼看出"这个常数是给 `index` 用的还是给 `value` 用的"。

### 3.5 `default`：为什么绝不能省

```verilog
        default: value = 8'd30;
    endcase
```

- `default` 覆盖了 `case` 里没写到的所有取值。这里 `index` 是 5 位、共 32 种取值，上面写了 `0~30` 共 31 项，剩下的 `5'd31` 就落到 `default`（值 30）。
- **组合块如果某些分支忘了赋值，工具会推断出"要记住上一次的值"→ 生成一个锁存器（latch）**。锁存器在 FPGA 上通常是不想要的（时序难分析、容易出毛刺，见 [`01-verilog-basics.md`](01-verilog-basics.md) §5、§16）。
- 所以本模块的两个"防漏"手段：① 每个分支都赋值；② 结尾必须有 `default`。这样无论 `index` 是多少，`value` 都一定被赋到，绝不会综合出 latch。

---

## 4. 端口表

| 端口 | 方向 | 位宽 | 作用 |
|---|---|---|---|
| `index` | in | 5 | 表的下标，来自 `$4003/$4007/$400B/$400F` 的高 5 位 |
| `value` | out | 8 | 查表得到的 length 起点值（单位：半帧，最多减 `value` 次静音） |

没有 `clk`、没有 `reset`、没有 `ce`、没有 `dbg_*`。**"没有时钟"本身就是它的合同**：它不做任何记忆，纯组合。

---

## 5. 代入具体 `index` 走一遍

拿三个有代表性的下标手算一遍（都在 tb 里被断言覆盖）：

| `index` | 命中的分支 | `value` | 说明 |
|---|---|---|---|
| `5'd1` | `5'd1: value = 8'd254;` | **254** | 特殊值：整张表里唯一一个超大的数，是长度最长的 index |
| `5'd9` | `5'd9: value = 8'd8;` | 8 | 普通值：8 个半帧 |
| `5'd31` | 没有专门分支 → `default` | **30** | 走 `default`，得 30 |

再比如 `index = 5'd0`（用户常说的"默认时长"）得 `8'd10`，`index = 5'd24` 得 `8'd192`。**注意 `index` 和 `value` 完全不是同一个东西**：`index` 是游戏写进寄存器的编号，`value` 才是真正参与计数的时长。

这张表不是本项目拍的，而是 **NES APU 硬件规格里的官方 length 表**。真实 NES 的 APU 内部就有一块一模一样的 32 项常量表，`$4003` 等高 5 位选中哪一项，硬件就装载哪个值。所以这份 RTL 的 32 个数字是**照抄 NES 规格**得来的：数值本身是"事实"，不是设计选择。其中 `index = 1 → 254` 是这条规格里最著名的一个"特殊值"，其余多数值在 `2~192` 之间。

---

## 6. 常见疑问

**Q：输出是 `reg`，那它是不是有记忆、有延迟？**
A：没有。名字里的 `reg` 只是语法分类（"由 `always` 块赋值"），并不等于硬件里的触发器。判断有没有记忆看的是**块的类型**：`always @*` 是组合，立刻出结果；只有 `always @(posedge clk)` 才是能"记住"上一拍的寄存器。本模块里 `value` 只取决于当前 `index`，无状态。

**Q：为什么不写 `wire [7:0] value` 再用 `assign`？**
A：`case` 不是表达式，写不成一行 `assign`。要在组合逻辑里表达"多选一"，就得用 `always @*` + `case`，而 `always` 块左边必须是 `reg`。所以"用 `case` 查表"和"输出是 `reg`"是绑在一起出现的。等价的另一种写法是 `assign value = index==0 ? 8'd10 : index==1 ? 8'd254 : ...`，但那要嵌套 31 层三目，可读性远不如 `case`。

**Q：为什么 `default` 给的是 30，而不是 0 或 x？**
A：因为硬件对 `index[4:0] = 31` 的官方答复就是 30。`default` 不是"出错兜底"，而是"最后一项表值"。这样做的副作用是：即使仿真时 `index` 出现未知值（`x`），`value` 也会被赋成确定的 30，不会把 `x` 传播出去。

---

## 7. 你应该带走的三件事

1. **LUT 就是"下标进、常数出"的组合逻辑**：输入当数组下标，输出直接取值，硬件上综合成一小片查找/选择网络，没有时钟、没有状态。
2. **组合块的两条铁律**：用阻塞 `=`，且 `case` 必须有 `default`、每个分支都要赋值，否则会综合出 latch。
3. **`reg`/`wire` 看"谁驱动"**：`always` 块赋值就写 `reg`（哪怕它其实是组合逻辑），`assign` 驱动就写 `wire`。别把 `reg` 当成"一定会存值"。

下一篇 [`12-vga-timing.md`](12-vga-timing.md) 进入**时序逻辑**：用一个计数器（`hcount`/`vcount`）+ `ce` 画出 VGA 的一帧画面，第一次看到"有时钟、有记忆"的模块怎么写。
