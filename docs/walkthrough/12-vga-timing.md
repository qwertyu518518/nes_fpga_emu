# 12 模块精读：`nes_vga_timing.v` —— 用计数器画出一整帧画面

前两篇（[`10-mapper-nrom.md`](10-mapper-nrom.md)、[`11-alu-lut.md`](11-alu-lut.md)）都是**纯组合**模块：没有时钟、没有记忆。这一篇第一次碰到**时序**：模块里有两个一直在跑的计数器，每个时钟沿加一，绕着屏幕一圈一圈地扫。它要回答的问题是：

> **显示器这一刻应该收到什么（行同步、场同步、像素有效、什么颜色）？**

`nes_vga_timing.v` 就是一个 **640×480@60Hz 的 VGA 纯时序发生器**：两个计数器、一级输出寄存器、几个常数比较。它不产生像素、不保存像素、不实例化任何东西——像素从上游的行流里来，它只负责"报坐标 + 报时序窗口"。

- 源码：[`rtl/nes_core/video/nes_vga_timing.v`](../../rtl/nes_core/video/nes_vga_timing.v)
- 合同与证据：[`../modules/vga-timing.md`](../modules/vga-timing.md)
- 测试目标：`vga-timing-core`（只编译）、`vga-timing-tb`（跑仿真），见 [`tools/sim_all.ps1`](../../tools/sim_all.ps1) 与 [`tb/video/tb_nes_vga_timing.v`](../../tb/video/tb_nes_vga_timing.v)

---

## 1. 先认识"上游和下游"

```text
上游行流：line_read_start / px_valid / px_rgb565
        │
        ▼
   [nes_vga_timing]  ──► hsync / vsync / de / rgb565  ──► VGA 引脚（DAC/LCD）
        │
        └──► hcount / vcount / active_pixels / frame_pulse / line_read_sync ──► 顶层观测与握手
```

- **上游**：行缓冲（`nes_line_buffer_vga`）一边读像素，一边用 `line_read_start` 告诉本模块"新的一行开始了"，用 `px_valid` 说明"这一拍的 `px_rgb565` 是真像素"。
- **本模块**：像"电视机的电子枪"一样自由扫描，把 `hcount`/`vcount` 走到哪、`hsync`/`vsync` 什么时候拉高、`de` 什么时候有效，**实时**送到引脚。
- **下游**：显示器靠 `hsync`/`vsync` 对齐水平/垂直方向，靠 `de` 知道"哪些像素要画"，靠 `rgb565` 拿到颜色。顶层再用 `frame_pulse` 做换帧、用 `line_read_sync` 确认握手落在预期坐标。

**最关键的一句话**：本模块**不存任何像素**（一个字节的存储器都没有），它只输出"这一拍是第几行第几列、是不是有效区"。像素缺了就输出黑。

---

## 2. 全文（100 行）

```verilog
`timescale 1ns/1ps

// 640x480@60Hz VGA 时序发生器：纯计数器加一级输出寄存器，不含 IP、不含引脚、不含存储器。
// 顶层约束：本模块不得实例化 nes_video_scaler，也不得拥有 frame buffer；
// 像素来源是上游行流，缺像素或未对齐时输出黑。详见 docs/modules/vga-timing.md。
module nes_vga_timing #(
    parameter integer H_TOTAL     = 800,
    parameter integer H_ACTIVE    = 640,
    parameter integer HSYNC_START = 656,
    parameter integer HSYNC_END   = 752,
    parameter integer V_TOTAL     = 525,
    parameter integer V_ACTIVE    = 480,
    parameter integer VSYNC_START = 490,
    parameter integer VSYNC_END   = 493,
    parameter integer DE_X0       = 64,
    parameter integer DE_X1       = 576,
    parameter integer DE_Y0       = 0,
    parameter integer DE_Y1       = 480
) (
    input  wire        clk,
    input  wire        reset,
    input  wire        ce,
    input  wire        line_read_start,
    input  wire        px_valid,
    input  wire [15:0] px_rgb565,
    output reg         hsync,
    output reg         vsync,
    output reg         de,
    output reg  [15:0] rgb565,
    output reg  [9:0]  hcount,
    output reg  [9:0]  vcount,
    output reg         active_pixels,
    output reg         frame_pulse,
    output reg         line_read_sync
);

    localparam [9:0] H_LAST = H_TOTAL - 1;
    localparam [9:0] V_LAST = V_TOTAL - 1;

    localparam [9:0] P_HS0 = HSYNC_START[9:0];
    localparam [9:0] P_HSE = HSYNC_END[9:0];
    localparam [9:0] P_VS0 = VSYNC_START[9:0];
    localparam [9:0] P_VSE = VSYNC_END[9:0];
    localparam [9:0] P_DX0 = DE_X0[9:0];
    localparam [9:0] P_DX1 = DE_X1[9:0];
    localparam [9:0] P_DY0 = DE_Y0[9:0];
    localparam [9:0] P_DY1 = DE_Y1[9:0];

    reg line_started;

    wire       h_last;
    wire [9:0] h_next;
    wire [9:0] v_next;
    wire       hsync_next;
    wire       vsync_next;
    wire       de_next;
    wire       line_next;
    wire       act_next;
    wire       frame_end;

    assign h_last     = (hcount == H_LAST);
    assign h_next     = h_last ? 10'd0 : (hcount + 10'd1);
    assign v_next     = h_last ? ((vcount == V_LAST) ? 10'd0 : (vcount + 10'd1)) : vcount;

    assign hsync_next = (h_next >= P_HS0) && (h_next < P_HSE);
    assign vsync_next = (v_next >= P_VS0) && (v_next < P_VSE);
    assign de_next    = (h_next >= P_DX0) && (h_next < P_DX1) &&
                        (v_next >= P_DY0) && (v_next < P_DY1);

    assign line_next  = line_read_start ? 1'b1 : (h_last ? 1'b0 : line_started);
    assign act_next   = de_next & line_next & px_valid;
    assign frame_end  = (h_next == H_LAST) && (v_next == V_LAST);

    always @(posedge clk) begin
        if (reset) begin
            hcount         <= 10'd0;
            vcount         <= 10'd0;
            hsync          <= 1'b0;
            vsync          <= 1'b0;
            de             <= 1'b0;
            rgb565         <= 16'd0;
            active_pixels  <= 1'b0;
            frame_pulse    <= 1'b0;
            line_read_sync <= 1'b0;
            line_started   <= 1'b0;
        end else if (ce) begin
            hcount         <= h_next;
            vcount         <= v_next;
            hsync          <= hsync_next;
            vsync          <= vsync_next;
            de             <= de_next;
            rgb565         <= act_next ? px_rgb565 : 16'd0;
            active_pixels  <= act_next;
            frame_pulse    <= frame_end;
            line_read_sync <= line_read_start;
            line_started   <= line_next;
        end
    end

endmodule
```

和纯组合模块最大的区别：**这里有一个 `always @(posedge clk)`**。所有输出都是 `reg`，都在时钟沿更新，所以输出相对计算**晚一拍**。这是本篇最重要的一个事实，后面反复用到。

---

## 3. 逐段精读

### 3.1 开头：`` `timescale `` 与文件头约束

`` `timescale 1ns/1ps `` 给仿真器定时间单位（第 10 篇讲过）。下面三行注释就是**合同**：本模块**不得**实例化 `nes_video_scaler`、**不得**拥有 frame buffer。也就是说它绝不"存一帧再看"，像素现来现用——这就是它和一个"整帧缓冲方案"的分界线。

### 3.2 参数列表：光栅几何

VGA 的"光栅"就是把屏幕按固定的拍数切成行和帧，参数表（值全部来自源码）：

| 参数 | 值 | 含义 | 白话 |
|---|---:|---|---|
| `H_TOTAL` | 800 | 一行的像素时钟数 | 走完 800 拍就算一行 |
| `H_ACTIVE` | 640 | 显示器可见宽度 | **只写文档，不参与比较** |
| `HSYNC_START` | 656 | 行同步起点 | `hcount` 到 656 时 `hsync` 拉高 |
| `HSYNC_END` | 752 | 行同步终点（不含） | 到 752 时 `hsync` 拉低，共 96 拍 |
| `V_TOTAL` | 525 | 一帧的行数 | 走完 525 行算一帧 |
| `V_ACTIVE` | 480 | 显示器可见高度 | **只写文档，不参与比较** |
| `VSYNC_START` | 490 | 场同步起点 | `vcount` 到 490 时 `vsync` 拉高 |
| `VSYNC_END` | 493 | 场同步终点（不含） | 到 493 时拉低，共 3 行 |
| `DE_X0/X1` | 64/576 | 图像窗口横向区间（左闭右开） | 宽 512 = 576−64 |
| `DE_Y0/Y1` | 0/480 | 图像窗口纵向区间（左闭右开） | 高 480 |

用"左闭右开"（`[` 含、`)` 不含）读这张表：`hsync` 覆盖 `[656,752)`，`vsync` 覆盖 `[490,493)`，`de` 覆盖 `x∈[64,576) 且 y∈[0,480)`。

几个直接能读出来、TB 也逐拍断言的数：

- 一行 = 800 拍，一帧 = 525 行，整帧 = 800×525 = **420000 拍**。
- 25 MHz 像素时钟下，刷新率 = 25000000 / 420000 ≈ **59.52 Hz**。
- 每行 `hsync` 高 96 拍；每帧 `vsync` 高 3 行（490、491、492）。
- 有效像素 = 512×480 = **245760 个/帧**（TB 的 `test_full_frame` 就钉这个数）。

`H_ACTIVE`/`V_ACTIVE` 特意留着却不参与比较：它们代表"**显示器**认为的边界（640×480）"，而 `DE_*` 才是"**我们放图像**的边界（512×480）"。两者差 128，正好左右各 64 黑边。

### 3.3 `localparam`：把 `parameter` 截成 10 位

```verilog
localparam [9:0] H_LAST = H_TOTAL - 1;      // 799
localparam [9:0] P_HS0  = HSYNC_START[9:0]; // 656
```

两个细节：

1. **`localparam` 是"模块内部常量"**：和 `parameter` 一样是常数，但外面例化时改不了。这里全是从 `parameter` 派生出来的值，不需要外人再传，所以用 `localparam`。注意 `H_LAST = 799` 是**回卷点**：`hcount` 走到 799 的下一拍就回 0。
2. **为什么要 `[9:0]` 和 `[9:0]` 切片？** 这些 `parameter` 声明成 `integer`（32 位），而计数器 `hcount`/`vcount` 是 `[9:0]`（10 位）。如果直接拿 32 位常数去和 10 位计数器比较，Verilog 会把两边"补齐到更宽的一边"再比，容易藏坑。这里**主动把常数截成 10 位**，让 `h_next >= P_HS0` 是 10 位比 10 位，干净利落。

### 3.4 端口列表

| 端口 | 方向 | 位宽 | 作用 |
|---|---|---|---|
| `clk` | in | 1 | 像素时钟，640×480@60Hz 对应 25 MHz（周期 40 ns） |
| `reset` | in | 1 | **同步**复位，优先级高于 `ce` |
| `ce` | in | 1 | 计数使能，`0` 时整个模块冻结 |
| `line_read_start` | in | 1 | 上游说"新的一行开始了"，用来把像素流对齐到本行 |
| `px_valid` | in | 1 | 这一拍的 `px_rgb565` 是真像素 |
| `px_rgb565` | in | 16 | 源像素（RGB565） |
| `hsync` | out | 1 | 行同步，**正极性**（有效高） |
| `vsync` | out | 1 | 场同步，**正极性**（有效高） |
| `de` | out | 1 | 图像窗口有效，**纯时序**（和有没有数据无关） |
| `rgb565` | out | 16 | 像素输出，窗口外/无数据时为 0 |
| `hcount` | out | 10 | `0..799`，当前这一拍的横坐标 |
| `vcount` | out | 10 | `0..524`，当前这一拍的纵坐标 |
| `active_pixels` | out | 1 | 这一拍 `rgb565` 上是真实图像数据 |
| `frame_pulse` | out | 1 | 单拍脉冲，落在**一帧最后一个像素** `(799,524)` |
| `line_read_sync` | out | 1 | `line_read_start` 经 `ce` 门控后的回声，单拍 |

**为什么输出都是 `reg`？** 因为它们都在 `always @(posedge clk)` 里被赋值。对比第 10 篇的 NROM：那边全 `assign`，所以端口是 `wire`。**看端口是 `wire` 还是 `reg`，就能猜到模块里是纯组合还是有时钟。**

### 3.5 王牌句式：组合算下一拍，寄存器打一拍

这是本项目处处出现的模式（见 [`02-project-conventions.md`](02-project-conventions.md) 第 2 节），本篇的核心就靠它：

```verilog
assign h_last = (hcount == H_LAST);                          // 组合：这一拍是不是行末
assign h_next = h_last ? 10'd0 : (hcount + 10'd1);           // 组合：下一拍 hcount 会变成多少
...
always @(posedge clk)
    ... hcount <= h_next; ...                                // 寄存器：时钟沿把它存住
```

逐行拆：

- `h_last`：`hcount == 799` 时为真，是**组合比较器**，没有时钟。
- `h_next`：三目。不是行末就 `hcount + 1`，是行末就**回卷成 0**。它是"下一拍的 `hcount`"。
- `hcount <= h_next`：时钟沿（且 `ce=1`）到了，才把 `h_next` 存进 `hcount`。

**为什么要拆成"组合的 next + 寄存的 q"？** 因为 `hsync_next`、`de_next` 等都要用"下一拍的坐标"来判断极性，直接在组合里算出来、再同一拍打进寄存器，输出就永远和计数器**同拍对齐**，不会错位。命名规则：`_next` 是组合、是下一拍值；`hcount`/`vcount` 本身是寄存器、是当前值。

再看垂直方向的 `v_next`（嵌套三目）：

```verilog
assign v_next = h_last ? ((vcount == V_LAST) ? 10'd0 : (vcount + 10'd1)) : vcount;
```

读法：**只有当前是行末（`h_last`）时，行号才变**。行末时看是不是帧末——是就回卷成 0，否则 `vcount + 1`。不是行末时 `v_next = vcount`，行号保持不变。这就是"一行一行往下走"。

三个窗口比较器全是"左闭右开"：

```verilog
assign hsync_next = (h_next >= P_HS0) && (h_next < P_HSE);   // 656 <= x < 752
assign vsync_next = (v_next >= P_VS0) && (v_next < P_VSE);   // 490 <= y < 493
assign de_next    = (h_next >= P_DX0) && (h_next < P_DX1) &&
                    (v_next >= P_DY0) && (v_next < P_DY1);   // 64<=x<576 且 0<=y<480
```

注意它们用的都是 `_next`（下一拍坐标）。原因见 3.6。

最后两行是"对齐"和"帧末"：

```verilog
assign line_next = line_read_start ? 1'b1 : (h_last ? 1'b0 : line_started);
assign act_next  = de_next & line_next & px_valid;
assign frame_end = (h_next == H_LAST) && (v_next == V_LAST);
```

- `line_next`：**strobe（`line_read_start`）优先**。strobe 来了就置 1；没来的话，行末清 0，否则保持 `line_started`。它只表达"本行是否已对齐"，**完全不影响 `hcount`/`vcount`**。
- `act_next`：三件事同时成立才算有效像素——`de`（在窗口内）且本行已对齐 且 `px_valid`。缺任何一条，输出的都是黑。
- `frame_end`：下一拍就是 `(799,524)` 时为真，用它生成 `frame_pulse`。

### 3.6 时序块：输出寄存器（所以是一拍延迟）

```verilog
always @(posedge clk) begin
    if (reset)   begin ... 全部清零 ... end
    else if (ce) begin
        hcount <= h_next;  hsync <= hsync_next;  vsync <= vsync_next;
        de <= de_next;  rgb565 <= act_next ? px_rgb565 : 16'd0;
        line_read_sync <= line_read_start;  line_started <= line_next;
    end
end
```

三个必须记住的点：

1. **复位优先于 `ce`**。`if (reset)` 在最前面，所以扫描到一半（正显示像素）拉高 `reset`，**即使 `ce=0` 下一拍也全部归零**，光栅回到 `(0,0)`。TB 的 `test_reset_mid_frame` 就钉这一条。
2. **`ce=0` 冻结一整条光栅**。`else if (ce)` 不成立时，所有寄存器保持原值：计数器不动、`hsync`/`vsync`/`de`/`rgb565` 不变、**连输入都被丢掉**——`ce=0` 期间呈现的 `line_read_start` 和 `px_rgb565` 会直接作废，恢复后**不会补上**。TB 的 `test_ce_freeze` 冻结 16 拍、逐位比对九个输出。
3. **一切都在时钟沿用 `<=` 更新**，所以输出描述的是"这一拍 `hcount`/`vcount` 读到的那个坐标"。`rgb565 <= act_next ? px_rgb565 : 0` 里，`px_rgb565` 是**第 N 个 `ce` 沿上**呈现的源像素，它对应的是**沿之后**计数器到达的坐标。

`line_read_sync <= line_read_start` 是**回声**：把上游的 strobe 原样寄存一下，让下游能确认"我这一拍的握手落到了预期坐标"。

---

## 4. 代入具体数字走一遍

设复位后 `ce=1`，光栅从 `(0,0)` 自由运行。看**行**上的三个关键时刻（`ce` 沿之前 `hcount` 读到什么，沿之后输出变成什么）：

| 时刻（沿前 `hcount`） | `h_next` | `hsync_next` | 沿后 `hcount` | 沿后 `hsync` | 说明 |
|---:|---:|---:|---:|---:|---|
| 654 | 655 | 0 | 655 | 0 | `hsync` 还是低 |
| 655 | 656 | **1** | 656 | **1** | **656 这拍 `hsync` 翻高** |
| 750 | 751 | 1 | 751 | 1 | 高电平持续到 751 |
| 751 | 752 | **0** | 752 | **0** | **到 752 翻低**，共 96 拍 |

行 `de`：在 `hcount=63` 那一拍，`h_next=64`，`de_next=1` → 沿后 `hcount=64` 且 `de=1`。走到 `hcount=575` 时 `h_next=576`，`de_next=0` → 沿后 `de=0`。于是 `de` 恰好覆盖 `64..575`。

行 `vcount`：`hcount` 走到 `799` 时 `h_last=1`，`v_next = vcount + 1`，所以下一拍行号 +1；`hcount` 回卷到 0。走到 `(799,524)` 时 `v_next=0`，整帧回到 `(0,0)`。

帧 `vsync`：`vcount` 走过 `490` 时 `vsync_next=1`，到 `493` 时 `0`，所以 vsync 覆盖第 490、491、492 三行。

帧末 `frame_pulse`：在 `hcount=798, vcount=524` 那一拍，`h_next=799`、`v_next=524`，`frame_end=1` → 沿后落在 `(799,524)`，`frame_pulse=1`。TB 断言"脉冲落在**最后一个像素**而不是 `(0,0)`"，因为 `(0,0)` 的像素已经被锁存，以它为触发点的换帧会晚生效。

再走一遍**对齐**（默认 `DE_X0=64`）：在 `hcount=63` 那一拍给出 `line_read_start` 和该行第 0 个源像素。沿后 `hcount=64`、`line_next=1`、`act_next=1`，于是坐标 64 上输出的就是源像素 0；`line_read_sync` 会在 `hcount=64`（第一个有效像素同拍）为高，正好用来核对握手。TB 用 `test_line_read_align` 断言 `(64,y)` 是源列 0、`(575,y)` 是源列 511。

---

## 5. 常见疑问

**Q：`de` 和 `active_pixels` 看起来差不多，为什么要两个？**
A：二者含义不同。`de` 只管**时序窗口**（"显示器该收像素的位置"），`active_pixels` 才说"这一拍真的有像素"。缺 `line_read_start`（未对齐）或 `px_valid=0`（坏点）时，两个信号在 `rgb565` 上都是 0，但 `de` 仍为高。下游能借此区分"这行还没准备好"和"这行在消隐"。

**Q：`line_read_start` 会把计数器复位吗？**
A：**不会**。它只改 `line_started` 这一个状态位，`hcount`/`vcount` 自由运行、完全不受影响。TB 特意在一行中间打 strobe，然后逐拍验证坐标序列没被扰动。

**Q：现在这个模块被顶层用上了吗？**
A：还没有。仓库里没有任何顶层同时实例化它和行缓冲；把行缓冲的 `line_read_start` 直接接进来还需要一层相位适配（判断 `hcount == DE_X0-1` 才转送）。这些属于上层集成，见 [`../modules/vga-timing.md`](../modules/vga-timing.md) 第 8 节。

---

## 6. 你应该带走的三件事

1. **VGA 就是两个计数器**：行 = `H_TOTAL` 拍、帧 = `V_TOTAL` 行，`hsync`/`vsync`/`de` 只是若干个"计数落在哪个区间"的比较器。
2. **王牌句式随时钟升级**：`wire x_next = ...; always @(posedge clk) x <= x_next;`——组合算下一拍、寄存器打一拍，输出与计数器同拍对齐（也因此输出**相对计算晚一拍**）。
3. **`reset` 优先于 `ce`、`ce` 冻结一切**：复位把光栅归位到 `(0,0)`；`ce=0` 时计数器、输出、连输入都被丢掉。`localparam [9:0]` 把 32 位 `parameter` 截成 10 位，是为了和 10 位计数器干净比较。

下一篇 [`13-mapper-cnrom-uxrom.md`](13-mapper-cnrom-uxrom.md) 回到 mapper 家族，看**第一个带寄存器的 mapper**：逻辑上还是组合选 bank，但需要 `clk` 记住"上次写了什么"。
