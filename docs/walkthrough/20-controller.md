# 20 第一个时序模块精读：`nes_controller.v`

前面 [`10-mapper-nrom.md`](10-mapper-nrom.md) 的 NROM 全是 `assign`，没有时钟。这一篇是**第一个带时钟的模块**：它实现 NES 手柄在 CPU 眼里的 `$4016` / `$4017` 端口——一个「串行移位器」。读完你会明白三件事：并联输入怎么变成串行位、`_q` 寄存器怎么读、以及「电平敏感」和「脉冲敏感」的区别。

- 源码：[`rtl/nes_core/controller/nes_controller.v`](../../rtl/nes_core/controller/nes_controller.v)
- 合同与证据：[`../modules/controller.md`](../modules/controller.md)
- 测试目标：`controller-tb`（见 [`tb/controller/tb_nes_controller.v`](../../tb/controller/tb_nes_controller.v)）

---

## 1. 先认识「上游和下游」

```text
buttons / buttons2                ───────►
latch_strobe（/PL 电平）          ───────►  [nes_controller] ──► data_bit ──► CPU 读 $4016/$4017
read_strobe / read_select         ───────►                    └─► data_out（bit7:1 恒 0）
```

- **上游**：`buttons` / `buttons2` 是 1P / 2P 的 8 根「并联输入线」，即平台层同步+消抖后的一组布尔值。
- **本模块**：把「8 位位图」变成「一次给出 1 位」的串行口，并模仿 4021 的 `/PL` 电平敏感行为。
- **下游**：CPU 每读一次 `$4016`（`read_select=0`）或 `$4017`（`read_select=1`），`data_bit` 给出下一位。地址译码与写值的 bit0 变成 `latch_strobe` 都在系统层。

---

## 2. 全文（109 行）

```verilog
`timescale 1ns/1ps

module nes_controller #(
    parameter [1:0] EXTRA_READ = 2'd0
)(
    input  wire       clk,
    input  wire       reset,
    input  wire       latch_strobe,
    input  wire       read_strobe,
    input  wire       read_select,
    input  wire [7:0] buttons,
    input  wire [7:0] buttons2,
    output wire       data_bit,
    output wire [7:0] data_out,
    output wire [7:0] dbg_sr1,
    output wire [7:0] dbg_sr2,
    output wire [7:0] dbg_latch1,
    output wire [7:0] dbg_latch2,
    output wire [3:0] dbg_cnt1,
    output wire [3:0] dbg_cnt2,
    output wire [7:0] dbg_selected_sr,
    output wire [7:0] dbg_selected_latch,
    output wire [3:0] dbg_selected_cnt,
    output wire       dbg_past8
);

    localparam EXTRA_ONE  = 2'd0;
    localparam EXTRA_HOLD = 2'd1;
    localparam EXTRA_ZERO = 2'd2;

    localparam [3:0] CNT_SAT = 4'd9;

    wire fill_one  = ((EXTRA_READ == EXTRA_ONE) || (EXTRA_READ == 2'd3)) ? 1'b1 : 1'b0;
    wire hold_last = (EXTRA_READ == EXTRA_HOLD);

    reg  [7:0] sr1_q;
    reg  [7:0] sr2_q;
    reg  [7:0] latch1_q;
    reg  [7:0] latch2_q;
    reg  [3:0] cnt1_q;
    reg  [3:0] cnt2_q;
    reg        last1_q;
    reg        last2_q;

    wire latch_now = latch_strobe;
    wire read1 = read_strobe && !read_select && !latch_strobe;
    wire read2 = read_strobe &&  read_select && !latch_strobe;

    wire [7:0] sel_buttons = read_select ? buttons2  : buttons;
    wire [7:0] sel_sr     = read_select ? sr2_q     : sr1_q;
    wire [7:0] sel_latch  = read_select ? latch2_q  : latch1_q;
    wire [3:0] sel_cnt    = read_select ? cnt2_q    : cnt1_q;
    wire       sel_last   = read_select ? last2_q   : last1_q;

    wire past8 = (sel_cnt >= 4'd8);

    wire [7:0] sr1_next  = {fill_one, sr1_q[7:1]};
    wire [7:0] sr2_next  = {fill_one, sr2_q[7:1]};
    wire [3:0] cnt1_next = (cnt1_q >= CNT_SAT) ? CNT_SAT : (cnt1_q + 4'd1);
    wire [3:0] cnt2_next = (cnt2_q >= CNT_SAT) ? CNT_SAT : (cnt2_q + 4'd1);

    assign data_bit  = latch_strobe  ? sel_buttons[0] :
                       (hold_last && past8) ? sel_last : sel_sr[0];
    assign data_out  = {7'b0, data_bit};

    assign dbg_sr1            = sr1_q;
    assign dbg_sr2            = sr2_q;
    assign dbg_latch1         = latch1_q;
    assign dbg_latch2         = latch2_q;
    assign dbg_cnt1           = cnt1_q;
    assign dbg_cnt2           = cnt2_q;
    assign dbg_selected_sr    = sel_sr;
    assign dbg_selected_latch = sel_latch;
    assign dbg_selected_cnt   = sel_cnt;
    assign dbg_past8          = past8;

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            sr1_q    <= 8'h00;
            sr2_q    <= 8'h00;
            latch1_q <= 8'h00;
            latch2_q <= 8'h00;
            cnt1_q   <= 4'd0;
            cnt2_q   <= 4'd0;
            last1_q  <= 1'b0;
            last2_q  <= 1'b0;
        end else if (latch_now) begin
            latch1_q <= buttons;
            latch2_q <= buttons2;
            sr1_q    <= buttons;
            sr2_q    <= buttons2;
            cnt1_q   <= 4'd0;
            cnt2_q   <= 4'd0;
        end else begin
            if (read1) begin
                sr1_q   <= sr1_next;
                cnt1_q  <= cnt1_next;
                if (cnt1_q < 4'd8)
                    last1_q <= sr1_q[0];
            end
            if (read2) begin
                sr2_q   <= sr2_next;
                cnt2_q  <= cnt2_next;
                if (cnt2_q < 4'd8)
                    last2_q <= sr2_q[0];
            end
        end
    end

endmodule
```

---

## 3. 逐段精读

### 3.1 4021 到底是个什么零件

真实手柄里那颗「4021」是一颗 **8 位并联输入 / 串行输出** 移位寄存器，只有三根有用信号：

| 引脚 | 方向（对手柄而言） | 作用 |
|---|---|---|
| `/PL`（strobe） | in | **低有效电平**。拉低时把 8 根并联线装进寄存器；保持低就一直重装。 |
| `CLK` | in | 每个上升沿把寄存器左移一位，空出的位补入。 |
| `OUT`（data） | out | 寄存器第 0 位。**每读一次 `$4016` 拿到第 0 位，寄存器同时前进一位。** |

一句话总模型：**8 根并联输入 + 一个 8 位移位寄存器 + 一个 `/PL` 电平 + 每读一次移一位。**

### 3.2 参数、本地常量与两个「策略」信号

模块头部有一个可配置参数 `parameter [1:0] EXTRA_READ = 2'd0`，它只决定「第 9 次及以后的读返回什么」；`localparam EXTRA_ONE=0 / EXTRA_HOLD=1 / EXTRA_ZERO=2` 给三种取值起了名字，`CNT_SAT = 4'd9` 是读计数器的**饱和值**（3.5 讲为什么是 9 不是 8）。用常量而不是魔法数字，可读性完全不同。

```verilog
wire fill_one  = ((EXTRA_READ == EXTRA_ONE) || (EXTRA_READ == 2'd3)) ? 1'b1 : 1'b0;
wire hold_last = (EXTRA_READ == EXTRA_HOLD);
```

这两根 `wire` 是**组合逻辑**：`fill_one` 决定移位寄存器空出的高位**补 1 还是补 0**（`EXTRA_READ` 为 0/3 时补 1，为 1/2 时补 0）；`hold_last` 在 `EXTRA_READ==1`（保持最后一位）时为真。`2'd3` 是「保留值」，与 `2'd0` 走完全相同的路径。

### 3.3 寄存器声明：为什么每个都带 `_q`，为什么有「两组」

按 [`02-project-conventions.md`](02-project-conventions.md) 的命名约定，**`_q` 表示「已经被时钟存住的当前值」**（`reg`），对应它组合地算出的下一拍值会叫 `_next`。所以你看到 `_q` 就知道「这是记忆，不是导线」。

这里天然有**两组**，因为 NES 有两个手柄口：1P（`$4016`）和 2P（`$4017`）。每组里三个寄存器各司其职：

| 寄存器 | 名字含义 | 干什么 |
|---|---|---|
| `sr1_q` / `sr2_q` 与 `latch1_q` / `latch2_q` | 移位寄存器 + 快照副本 | 装载时都 = 快照；`sr` 每读一次右移一位（被消耗），`latch` 读时不动、停在最后一次 strobe 的快照上。 |
| `cnt1_q` / `cnt2_q` | 读计数器 | 自上次 strobe 以来读了几次，饱和于 9。 |
| `last1_q` / `last2_q` | 第 8 位的备份 | 只在「保持最后一位」策略里用（3.7 讲）。 |

**为什么 `latch*_q` 和 `sr*_q` 装载同一个值却要分开存？** 因为 `sr` 会被 8 次读「排空」，而 `latch` 不退位，留作证据。testbench 正是靠 `lat1_tie` 断言「快照确实抓到了按钮」而不被移位干扰。

### 3.4 组合：使能与端口选择

```verilog
wire latch_now = latch_strobe;
wire read1 = read_strobe && !read_select && !latch_strobe;
wire read2 = read_strobe &&  read_select && !latch_strobe;
```

- `latch_now` 就是 `latch_strobe` 本身——**代表 `/PL` 的电平，不加边沿检测**，为 1 的每一拍都装载。
- `read1` / `read2` 是「这一拍要读 1P / 2P」。它们都带了 `&& !latch_strobe`：**只要 strobe 还在高，读就被屏蔽**（装载优先，见 3.8 的优先级）。`read_select` 决定读哪个口。

```verilog
wire [7:0] sel_buttons = read_select ? buttons2  : buttons;
wire [7:0] sel_sr     = read_select ? sr2_q     : sr1_q;
wire [7:0] sel_latch  = read_select ? latch2_q  : latch1_q;
wire [3:0] sel_cnt    = read_select ? cnt2_q    : cnt1_q;
wire       sel_last   = read_select ? last2_q   : last1_q;
```

五行 `? :` 结构完全一样：**`read_select=0` 走 1P 那一路，`=1` 走 2P 那一路**。这就是「同一套逻辑服务两个端口」的写法——不复制电路，只在读的瞬间用一根选择线分流，也说明 `read_select` **只影响读，不影响 strobe**（strobe 共用）。

### 3.5 组合：下一拍的移位与计数

```verilog
wire past8 = (sel_cnt >= 4'd8);

wire [7:0] sr1_next  = {fill_one, sr1_q[7:1]};
wire [7:0] sr2_next  = {fill_one, sr2_q[7:1]};
wire [3:0] cnt1_next = (cnt1_q >= CNT_SAT) ? CNT_SAT : (cnt1_q + 4'd1);
wire [3:0] cnt2_next = (cnt2_q >= CNT_SAT) ? CNT_SAT : (cnt2_q + 4'd1);
```

- `past8 = (sel_cnt >= 8)`：选中端口已经读过 8 次及以上，供 `data_bit` 判断「该切到额外读策略了」。
- `sr1_next = {fill_one, sr1_q[7:1]}`：这是**右移一位**。拼接的左边是高位，所以新 `bit7 = fill_one`，新 `bit[6:0] = 旧 bit[7:1]`。被「挤出去」的是 `sr1_q[0]`——正是刚才那一位数据。空出的最高位补 `fill_one`。对照 [`../modules/controller.md`](../modules/controller.md) 里 Obara 的 `reg >>= 1; reg |= 0x80;`，两者是同一件事。
- `cnt1_next = (cnt1_q >= CNT_SAT) ? CNT_SAT : (cnt1_q + 1)`：计数器**饱和加法**。加到 9 之后就钉在 9 不再动。

**为什么饱和在 9 而不是 8？** 因为要区分两种状态：「正好读了 8 次」（`cnt=8`）和「读了 8 次以上」（`cnt=9`）。若饱和在 8，就没法知道是第 8 次还是第 20 次了。

### 3.6 组合输出：`data_bit` 是电平敏感的

```verilog
assign data_bit  = latch_strobe  ? sel_buttons[0] :
                   (hold_last && past8) ? sel_last : sel_sr[0];
assign data_out  = {7'b0, data_bit};
```

`data_bit` 是**纯组合**的（`assign`，没有时钟），按优先级三选一：

1. 只要 `latch_strobe` 为高 → 直接输出 `sel_buttons[0]`，也就是**当前**按钮的 A 位。所以 `buttons` 一变，`data_bit` 立刻跟着变，不等时钟沿。
2. 否则，若是「保持最后一位」模式且已过 8 次 → 输出 `sel_last`（锁住的第 8 位）。
3. 否则 → 输出移位寄存器第 0 位 `sel_sr[0]`。

这一条「strobe 高时直接反映 `buttons[0]`」就是**电平敏感**的核心：真实 4021 在 `/PL` 为低时 `OUT` 直连并联输入，本项目用组合逻辑表达它。testbench 里 `latch_strobe` 保持高、中途翻转 `buttons`，断言 `data_bit` 立刻跟随（见 `test_strobe_reload`）。`data_out = {7'b0, data_bit}` 只填 bit0，**高 7 位恒 0**；真实总线的 open bus（例如 bit6 常为 1）由 `nes_cpu_bus` 建模，不在这里。

### 3.7 `last*_q`：三种 `EXTRA_READ` 策略落在哪

策略的分工是「**填什么**」由 `fill_one` 管，「**输出选谁**」由 `hold_last` 管：

| `EXTRA_READ` | 名字 | 第 9 次及以后 | 移位寄存器终值 |
|---|---|---|---|
| `2'd0`（默认） | 恒 1 | 永远 1 | `8'hFF` |
| `2'd1` | 保持最后一位 | 永远 = 快照的 bit7 | `8'h00` |
| `2'd2` | 移进 0 | 永远 0 | `8'h00` |
| `2'd3` | 保留 | 同 `2'd0` | `8'hFF` |

- `2'd0` / `2'd3`：`fill_one=1`，8 次后 `sr` 全填成 `8'hFF`，`sel_sr[0]` 自然恒 1。**不需要专门的输出分支**，移位方向本身就带来了这个效果。
- `2'd2`：`fill_one=0`，`sr` 清成 `8'h00`，输出恒 0。
- `2'd1`：`hold_last=1`。它在输出 mux 里用 `sel_last` 覆盖掉 `sel_sr[0]`，把第 8 次读到的那位锁住。

`last*_q` 只在 `cnt < 8` 的读里更新（`if (cnt1_q < 4'd8) last1_q <= sr1_q[0];`），即第 1~8 次读。第 8 次读时 `cnt=7`，抓到的正是 `buttons[7]`（Right）；之后 `cnt>=8`，`last1_q` **冻结**，所以「保持的最后一位」是快照的 bit7，而不是继续漂移的移位内容。

### 3.8 时序块：复位 > 装载 > 移位

```verilog
always @(posedge clk or posedge reset) begin
    if (reset) begin                  // 优先级 1：异步复位，全部清零
        sr1_q <= 8'h00;  // ... 8 个寄存器统统 <- 0 ...
    end else if (latch_now) begin     // 优先级 2：strobe 高，每拍装载
        sr1_q    <= buttons;
        latch1_q <= buttons;          // sr1/sr2/latch1/latch2 都装
        cnt1_q   <= 4'd0;             // 两个计数器清零
    end else begin                    // 优先级 3：读 -> 移位
        if (read1) begin
            sr1_q   <= sr1_next;
            cnt1_q  <= cnt1_next;
            if (cnt1_q < 4'd8) last1_q <= sr1_q[0];
        end
        // if (read2) ... 对 sr2_q/cnt2_q/last2_q 做同样的事
    end
end
```

读法（**优先级从上到下**，就是 [`02-project-conventions.md`](02-project-conventions.md) 第 3 节的骨架）：

1. 敏感列表带 `or posedge reset` → **异步复位**（高有效）：`reset` 一拉高，不等时钟沿就清空全部 8 个寄存器。`test_reset` / `test_reset_midstream` 断言「拉高后 `#1` 就清干净」。
2. `else if (latch_now)`：strobe 为高时**每拍**重新装载并清计数。因为它是 `else if`，**装载期间读分支根本不会执行**——这就是「读被屏蔽、快照不被扰动」的机制。
3. `else` 里的 `if (read1)` / `if (read2)`：真正移位。二者互斥（由 `read_select` 决定），每拍最多执行一个；`cnt1_q` 与 `cnt2_q` **各自独立**（`test_dual_port` 交错读两口来钉这一点）。

时序块里全部用**非阻塞 `<=`**：所有寄存器在同一个时钟沿「同时」更新，这正对应硬件真相。

---

## 4. 端口表

| 端口 | 方向 | 位宽 | 合同 |
|---|---|---|---|
| `clk` | in | 1 | CPU 时钟，一拍 = 一个 CPU 周期。 |
| `reset` | in | 1 | 高有效**异步**复位，清空全部状态。 |
| `latch_strobe` | in | 1 | `$4016` 写值的 bit0，即 `/PL` 的**电平**。为 1 时每拍装载并清计数；为 0 时保持快照并允许移位。 |
| `read_strobe` | in | 1 | 读脉冲。**每个为高的时钟沿 = 一次读取 = 移出一位**；strobe 为 1 时被忽略。 |
| `read_select` | in | 1 | `0`=`$4016`（1P），`1`=`$4017`（2P）。只影响读。 |
| `buttons` | in | 8 | 1P 位图，**bit0..7 = A,B,Select,Start,Up,Down,Left,Right**（位序是 NESdev 规格，不是本项目自定）。 |
| `buttons2` | in | 8 | 2P 位图，位序同上。 |
| `data_bit` | out | 1 | 串行数据线，高 = 按下。**组合**输出。 |
| `data_out` | out | 8 | `{7'b0, data_bit}`，高 7 位恒 0。 |
| `dbg_sr1` / `dbg_sr2` / `dbg_latch1` / `dbg_latch2` / `dbg_cnt1` / `dbg_cnt2` | out | — | 两个移位寄存器、两个快照寄存器、两个读计数器（饱和于 9）的当前值。 |
| `dbg_selected_sr` / `dbg_selected_latch` / `dbg_selected_cnt` / `dbg_past8` | out | — | 按 `read_select` 选出的那一路，以及「已读过 8 次及以上」。 |

`dbg_*` 全是只读观测，**不影响任何功能逻辑**（[`02-project-conventions.md`](02-project-conventions.md) 第 7 节）。

---

## 5. 一次完整轮询：1 写 + 1 写 + 8 读

游戏拿 `buttons = 8'b1010_0101`（A=1,B=0,Select=1,Start=0,Up=0,Down=1,Left=0,Right=1）轮询一次，CPU 侧是 2 次写 + 8 次读。逐拍看：

| 拍 | `latch_strobe` | `read_strobe` | 时钟沿之后发生什么 |
|---|---|---|---|
| 1 | 1 | 0 | 装载：`sr1_q = 8'hA5`、`latch1_q = 8'hA5`、`cnt1_q = 0`。同时 `data_bit = buttons[0] = 1`（组合）。 |
| 2 | 0 | 0 | 快照冻结，什么都不动。 |
| 3 | 0 | 1 | 读前 `data_bit = sr1_q[0] = 1`（A）；沿后 `sr1_q <= {1, sr1_q[7:1]}`，`cnt1_q = 1`。 |
| 4 | 0 | 1 | 读到 `0`（B）；沿后 `sr1_q` 再右移，`cnt1_q = 2`。 |
| 5 | 0 | 1 | 读到 `1`（Select）；`cnt1_q = 3`。 |
| 6 | 0 | 1 | 读到 `0`（Start）。 |
| 7 | 0 | 1 | 读到 `0`（Up）。 |
| 8 | 0 | 1 | 读到 `1`（Down）。 |
| 9 | 0 | 1 | 读到 `0`（Left）。 |
| 10 | 0 | 1 | 读到 `1`（Right）；沿后 `cnt1_q = 8`，`past8 = 1`。 |

**把读到的 8 位按「第一次读 = bit0」拼起来**：`1 0 1 0 0 1 0 1 = 8'hA5`，**正好等于 `buttons` 本身**；`read_select` 换成 1 就轮到 `sr2_q` / `cnt2_q`，strobe 仍共用。第 11 拍起 `cnt1_q` 饱和到 9，`data_bit` 按 `EXTRA_READ` 给额外读策略（默认恒 1），`tb_nes_controller` 对全部 256 种组合、两个端口、三个 `EXTRA_READ` 实例各断言了一遍这条位序合同。

---

## 6. 常见疑问

**Q：为什么 `data_bit` 是 `wire`（组合），而不是寄存器？**
A：因为真实 4021 在 `/PL` 为低时 `OUT` 直连并联输入。若把 `data_bit` 做成寄存器，strobe 保持高时按钮中途变化就反映不出来，`test_strobe_reload` 会失败。

**Q：读脉冲保持 3 拍高会怎样？**
A：`read_strobe` 是电平，每个为高的时钟沿算一次读，所以 3 拍就连续移 3 位、`cnt` 加 3。`test_pulse_width` 就断言了这一点。系统层应给 1 拍脉冲。

**Q：`read_select` 翻转会不会有副作用？**
A：不会。它只驱动 mux，不改变任何寄存器。`test_select_and_idle_isolation` 用 20 拍反复翻它、不发给读选通，断言计数器纹丝不动。

**Q：`latch_now` 和 `read1`/`read2` 会不会同时为真？**
A：不会。`read1`/`read2` 都带了 `&& !latch_strobe`，且时序块里装载分支的 `else` 才轮到读。这就是「装载优先」。

---

## 7. 你应该带走的三件事

1. **并联输入 → 串行输出**：strobe 把 8 根线拍成快照（`sr`/`latch` 装载），每次读右移一位（`sr <= {fill_one, sr[7:1]}`），`sr[0]` 就是当前位。
2. **电平敏感 vs 脉冲敏感**：`latch_strobe` 是电平（为高时每拍重装、`data_bit` 组合跟随），`read_strobe` 每个高拍算一次读；时序块用 `if/else if` 的**从上到下优先级**表达「复位 > 装载 > 移位」。
3. **命名即语义**：看到 `_q` 就是寄存器、`_next` 是下一拍值、`sel_*` 是按 `read_select` 分流的组合 mux、`dbg_*` 只读不影响逻辑。

下一篇 [`21-cdc-fifo.md`](21-cdc-fifo.md) 走进跨时钟域的经典结构：FIFO 与格雷码指针。
