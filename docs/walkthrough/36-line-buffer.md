# 36 逐行精读：`nes_line_buffer_vga.v` —— 双 bank 乒乓的行缓冲

[12 篇](12-vga-timing.md) 的 VGA 时序发生器**不存像素**，[21 篇](21-cdc-fifo.md) 的 FIFO 只有**一个**数据流。这一篇同时碰到两件难事：**两个时钟域**（生成像素的 `wr_clk` 和显示读取的 `rd_clk`）与**两块存储 bank**（一块被写、一块被读）。

它回答：**PPU 侧一 pixel 一 pixel 生成的行，怎么安全交给一个自己走时钟的显示端？**

答案不是"存整帧"，而是"只存两行"：写端把一行填进一块 **bank**，填满就翻到另一块继续写；读端从**另一块** bank 取走那行。两块 bank 一写一读、交替使用，就是 **ping-pong（乒乓）**。

- 源码：[`rtl/nes_core/video/nes_line_buffer_vga.v`](../../rtl/nes_core/video/nes_line_buffer_vga.v)
- 合同与证据：[`../modules/line-buffer-vga.md`](../modules/line-buffer-vga.md)
- 测试目标：`line-buffer-core`（只编译）、`line-buffer-tb`（跑 [`tb/video/tb_nes_line_buffer_vga.v`](../../tb/video/tb_nes_line_buffer_vga.v)），见 [`tools/sim_all.ps1`](../../tools/sim_all.ps1)

---

## 1. 先认识"上游和下游"

```text
wr_clk 域（写侧，≈PPU 像素节拍）        rd_clk 域（读侧，≈VGA 像素时钟）
   一个像素：wr_x / wr_index
        │                                    line_read_start ──► 下游 VGA 时序
  [ nes_line_buffer_vga ] ─ 512×16 行存储 ─►  read_x / read_rgb565 ──► 显示端
        │                                    frame_line_valid ──► "这一拍是有效像素"
        └──► line_ready_toggle ─(跨域)────────┘
             line_done        （1 bit 电平，两级同步）
```

- **谁写**：PPU 侧每生成一个像素，送来 **4 位调色板索引** `wr_index` 和横坐标 `wr_x`（0..255）；写口顺手把索引查成 RGB565。
- **谁读**：显示侧按自己的节奏扫描，逐个取走 `read_rgb565`；`read_x`（0..511）是输出列号。
- **两个时钟互不相关**，"一行写好了"必须变成跨域信号——这就是 `line_ready_toggle`。
- **谁例化它**：目前没有顶层实例化它（`nes_system_v5.v` 里没有），只作为 `line-buffer-core`/`line-buffer-tb` 两个目标被编译/仿真。

**为什么是行缓冲而不是整帧？** 这是本篇最贵的一条账，第 3.1 节细算。

---

## 2. 全文

`palette_rgb565` 是一张 64 项的纯查表 LUT（同 [11 篇](11-alu-lut.md)），这里只列前 6 项，其余以注释省略；其余逻辑逐行照抄：

```verilog
`timescale 1ns/1ps

module nes_line_buffer_vga #(
    parameter integer REPEAT_LINE = 1
) (
    input  wire        wr_clk,
    input  wire        wr_reset,
    input  wire        wr_ce,
    input  wire        wr_pixel_valid,
    input  wire [7:0]  wr_x,
    input  wire [3:0]  wr_index,
    output reg         line_ready_toggle,
    output reg         line_done,
    input  wire        rd_clk,
    input  wire        rd_reset,
    input  wire        rd_ce,
    output reg         frame_line_valid,
    output reg         line_read_start,
    output reg  [8:0]  read_x,
    output reg  [15:0] read_rgb565
);

    localparam [7:0] LINE_LAST_X  = 8'd255;
    localparam [8:0] VLINE_LAST_X = 9'd511;

    reg [15:0] line_mem [0:511];

    reg wr_bank;
    reg toggle_meta;
    reg toggle_sync;
    reg toggle_seen;
    reg       rd_bank;
    reg       rd_active;
    reg       rd_second;
    reg [8:0] rd_x_cnt;
    reg [15:0] rd_mem_q;

    wire wr_line_end;
    wire toggle_new;
    wire rd_line_end;
    wire [8:0] rd_next_x;

    assign wr_line_end = wr_pixel_valid & (wr_x == LINE_LAST_X);
    assign toggle_new  = toggle_sync ^ toggle_seen;
    assign rd_line_end = (rd_x_cnt == VLINE_LAST_X);
    assign rd_next_x   = rd_x_cnt + 9'd1;

    function [15:0] palette_rgb565;   /* 4→16 位调色板 LUT，共 64 项（见 11-alu-lut.md） */
        input [3:0] color_index;
        begin
            case (color_index)
                6'h00: palette_rgb565 = 16'h630C;   /* ... 6'h01 .. 6'h3F ... */
                default: palette_rgb565 = 16'h0000;
            endcase
        end
    endfunction

    always @(posedge wr_clk) begin
        if (wr_reset) begin
            wr_bank            <= 1'b0;
            line_ready_toggle  <= 1'b0;
            line_done          <= 1'b0;
        end else if (wr_ce) begin
            line_done <= 1'b0;
            if (wr_pixel_valid) begin
                line_mem[{wr_bank, wr_x}] <= palette_rgb565(wr_index);
                if (wr_line_end) begin
                    line_done         <= 1'b1;
                    line_ready_toggle <= ~line_ready_toggle;
                    wr_bank           <= ~wr_bank;
                end
            end
        end
    end

    always @(posedge rd_clk) begin
        if (rd_reset) begin
            toggle_meta       <= line_ready_toggle;
            toggle_sync       <= line_ready_toggle;
            toggle_seen       <= line_ready_toggle;
            rd_bank           <= 1'b0;
            rd_active         <= 1'b0;
            rd_second         <= 1'b0;
            rd_x_cnt          <= 9'd0;
            rd_mem_q          <= 16'd0;
            frame_line_valid  <= 1'b0;
            line_read_start   <= 1'b0;
            read_x            <= 9'd0;
            read_rgb565       <= 16'd0;
        end else if (rd_ce) begin
            toggle_meta      <= line_ready_toggle;
            toggle_sync      <= toggle_meta;
            frame_line_valid <= rd_active;
            line_read_start  <= rd_active & (rd_x_cnt == 9'd0);
            read_x           <= rd_x_cnt;
            read_rgb565      <= rd_mem_q;
            if (rd_active) begin
                if (rd_line_end) begin
                    rd_x_cnt <= 9'd0;
                    if (REPEAT_LINE != 0 && !rd_second) begin
                        rd_second <= 1'b1;
                        rd_mem_q  <= line_mem[{rd_bank, 8'd0}];
                    end else begin
                        rd_second <= 1'b0;
                        rd_bank   <= ~rd_bank;
                        rd_active <= 1'b0;
                    end
                end else begin
                    rd_mem_q <= line_mem[{rd_bank, rd_next_x[8:1]}];
                    rd_x_cnt <= rd_x_cnt + 9'd1;
                end
            end else if (toggle_new) begin
                toggle_seen <= toggle_sync;
                rd_active   <= 1'b1;
                rd_second   <= 1'b0;
                rd_x_cnt    <= 9'd0;
                rd_mem_q    <= line_mem[{rd_bank, 8'd0}];
            end
        end
    end

endmodule
```

和 [21 篇](21-cdc-fifo.md) 一样，这里有**两个独立的 `always @(posedge ...)`**：一个只听 `wr_clk`，一个只听 `rd_clk`。全模块**没有一行 `clk`**。它也没有 `dbg_*` 端口，状态要靠层次化引用（`dut_rep.wr_bank`）在 testbench 里看。

---

## 3. 逐段精读

### 3.1 存储尺度：为什么两行就够

`line_mem` 是 `reg [15:0] line_mem [0:511]`：**512 × 16 位 = 8192 bit = 1 KiB**。512 项 = **2 bank × 256 像素**，因为 `{wr_bank, wr_x}` 是 9 位拼接地址，语义就是 `wr_bank*256 + wr_x`。

| 方案 | 存储量 | EP4CE10 片上 423,936 bit 装得下？ |
|---|---|---|
| 整帧 frame buffer（`nes_video_scaler.v`） | 256×240×16 ≈ 120 KiB | **装不下** |
| 行缓冲（本模块，2 行） | 2×256×16 = 1 KiB | 装得下，正好 1 个 M9K |

**"整帧降级成两行"是本模块存在的全部理由。** 代价是：帧不再是存储对象，而是**时间过程**——一行写完必须立刻被读走，写端再翻回来覆盖它（第 3.9 节）。

### 3.2 bank 与地址：写读各持一块"当前 bank"

`wr_bank` 与 `rd_bank` 都是 1 bit。写端每写完一行翻转 `wr_bank`，决定下一个像素写进哪一半；读端每读完**一个源行**翻转 `rd_bank`，决定这一轮从哪一半读。因为写端在读完之前已经翻到另一边，读的时候两者**永远相反**——这就是 ping-pong。

### 3.3 写口：写满一行就翻 bank、翻 toggle

```verilog
assign wr_line_end = wr_pixel_valid & (wr_x == LINE_LAST_X);   /* 255 */
...
line_done <= 1'b0;                       /* 默认清 0 → 保证是单拍脉冲 */
if (wr_pixel_valid) begin
    line_mem[{wr_bank, wr_x}] <= palette_rgb565(wr_index);
    if (wr_line_end) begin
        line_done         <= 1'b1;
        line_ready_toggle <= ~line_ready_toggle;
        wr_bank           <= ~wr_bank;
    end
end
```

1. **只有 `wr_pixel_valid` 才写**：`wr_x` 到 255 但 `wr_pixel_valid=0` 时什么都不发生，所以"行"按**有效像素**数。
2. 行末那一拍同时做三件事：写第 255 个像素、翻 `line_ready_toggle`、翻 `wr_bank`。**这一拍后整行写完，写端已指向对面 bank。**
3. `line_done` 每拍默认清 0，只有行末那拍置 1 → **单周期脉冲**；`line_ready_toggle` 相反，是**电平**，翻一次保持到下次翻转（第 3.5 节讲为什么）。

### 3.4 读口：idle / 扫描 / 行末

读口主体是 `if (rd_active) ... else if (toggle_new) ...`，对应"正在扫描"和"空闲等新行"：

```verilog
frame_line_valid <= rd_active;                        /* 扫描中 = 有效像素 */
line_read_start  <= rd_active & (rd_x_cnt == 9'd0);   /* 每一遍的第一个像素 */
read_x           <= rd_x_cnt;                         /* 输出列号 = 内部计数器 */
read_rgb565      <= rd_mem_q;                         /* 输出像素 = BRAM 数据寄存器 */
if (rd_active) begin                                  /* 扫描中：推进 / 行末处理 */
    ...   /* 行末见第 3.7 节；推进见第 3.6 节 */
end else if (toggle_new) begin                        /* 空闲且发现新行 */
    toggle_seen <= toggle_sync;                       /* 记账，避免重复读 */
    rd_active   <= 1'b1;
    rd_second   <= 1'b0;
    rd_x_cnt    <= 9'd0;
    rd_mem_q    <= line_mem[{rd_bank, 8'd0}];         /* 预装行首 */
end
```

- `rd_active` 是"这一行正在被扫描"的 1 bit 状态，直接驱动 `frame_line_valid`，所以**行内连续高、行间低**。
- `line_read_start` 只在 `rd_active && rd_x_cnt==0` 时为高，是**单拍脉冲**；`REPEAT_LINE=1` 时一个源行读两遍，所以**一个源行脉冲两次**（第 3.7 节）。
- **四个输出都是寄存器**，比内部 `rd_x_cnt`/`rd_mem_q` 晚一拍对齐（第 3.6 节处理）。
- **空闲时 `read_x` 停在 0**，`read_rgb565` 是残留值，下游必须靠 `frame_line_valid=0` 忽略。

### 3.5 toggle 同步器：1 bit 怎么跨 `wr_clk`→`rd_clk`

```verilog
reg toggle_meta;   /* 第 1 级同步 */
reg toggle_sync;   /* 第 2 级同步 */
reg toggle_seen;   /* 我已经消费到哪一次翻转 */
assign toggle_new = toggle_sync ^ toggle_seen;   /* 组合：还有一行没读 */

toggle_meta <= line_ready_toggle;   /* 写域信号进第 1 级 */
toggle_sync <= toggle_meta;         /* 第 1 级再进第 2 级 */
```

- `line_ready_toggle` 在写域产生、读域采样，**不能直接用**（可能采到亚稳值），所以过**两级同步器** `toggle_meta`→`toggle_sync`。
- **为什么传 toggle 而不是单拍脉冲？** 读端可能比写端慢；单拍脉冲落在 `rd_ce=0` 的沿上会**整丢**且无法察觉。toggle 是**电平**，只要还欠一次翻转，下次采样就看得见。
- `toggle_new = toggle_sync ^ toggle_seen` 是"净差额"：`toggle_seen` 记账我消费过的值，异或非零说明有一行新数据；检测到后 `toggle_seen <= toggle_sync` 避免重复读。
- 复位时三级都被赋成 `line_ready_toggle` 的**当前值**，所以复位本身**不产生伪行**（`toggle_new` 恒 0）。

**代价**：读端最早要 **2 个 `rd_ce` 沿**（两级同步）才看到 toggle，第 3 沿接受并预装，第 4 沿才出第一个有效像素。TB 把它钉成时间断言："首行像素 − 写端翻转 ≥ 30 ns（3 个 `rd_clk`）"，去掉同步器立刻被抓。

### 3.6 2× 水平复制：地址右移一位

```verilog
assign rd_next_x = rd_x_cnt + 9'd1;
rd_mem_q <= line_mem[{rd_bank, rd_next_x[8:1]}];   /* 读地址 = (rd_x_cnt+1) >> 1 */
```

输出 512 列、源只有 256 列，每个源像素输出两次。`(rd_x_cnt+1) >> 1` **右移一位就是全部的水平放大**：没有乘法器、没有第二份缓冲。

**那个 `+1` 不是可选的**，它是"读延迟对齐"：BRAM 是**同步读**（这拍给地址、下拍出数据），而 `read_x` 直接取当前 `rd_x_cnt`，两者差一拍，所以地址要用**下一个**计数器的值。合起来：`read_x = c` 时 `read_rgb565 = line_mem[rd_bank][c>>1]`——偶数 `c` 是新像素、奇数 `c` 重复前一个。testbench 单独断言奇数 `c` 的颜色等于前一个像素。

### 3.7 `REPEAT_LINE`：垂直 2× 是"免费"的吗

`REPEAT_LINE` 默认 1。行末（`rd_x_cnt==511`）时：

- `REPEAT_LINE!=0 && !rd_second`：**不换 bank**，`rd_second<=1`、`rd_x_cnt<=0`、把 `rd_mem_q` **重新预装成行首**，同一 bank 立刻再读一遍。
- 否则：`rd_bank <= ~rd_bank`、`rd_active <= 0`，这一源行结束。

所以 `REPEAT_LINE=1` 时一个源行输出 **2×512 = 1024** 个像素、`line_read_start` 脉冲 **2 次**；`REPEAT_LINE=0` 时输出 512 个、脉冲 1 次，且 `rd_second` 恒 0，走的分支与没有该参数时**逐位相同**。240 源行 × 2 = 480，正好是 VGA 有效行数。

**"免费"要加引号**：存储一个字节没多，但**读端时间翻倍**——写一行 256 拍、读一行 1024 拍，读端速率必须 ≥ 写端 **4 倍**，否则 toggle overrun（第 3.9 节）。行末那次重新预装也必须，否则第二遍第 0 个像素会拿到上一遍的残留（`mem[255]`）。

### 3.8 为什么行内不可能撕裂

撕裂 = 读端和写端同时碰到同一块存储。这里不会发生，因为时间上错开：

```text
写端： ──写 bank0(256 px)──┬──写 bank1(256 px)──┬──写 bank0──
                            │   toggle 翻转       │
读端：                    ──读 bank0(1024 拍)────┴── 读 bank1 ──
```

写端翻 `wr_bank` 和翻 `toggle` 是**同一拍**。读端收到 toggle 时，写端已经在写对面的 bank。**双方各自锁定互反的 bank，行内绝不交叠，所以行内不可能撕裂。** 剩下的风险在**行与行之间**：读端跟不上时被跳过的行就是撕裂的等价物。

### 3.9 没有背压：写领先 2 行就会**静默**丢行

`toggle` 只有 1 bit，**没有队列、没有 ready/valid、没有错误标志**：

- 写比读慢 → 正常，读端 idle 等 toggle。
- 写比读快、领先**不超过 1 行** → 正常，ping-pong 正好抵消。
- 写领先 **2 行或更多** → 读端只看到 toggle 的**净变化**（0 或 1），**中间的整行被静默跳过**，**没有任何信号表明发生了这件事**。

这是"不存整帧"必须付的钱。要彻底解决需要更多 bank（深度=最坏领先行数）、读后应答握手、或退回整帧缓冲——**当前接口三者都没有**。TB 用 5 倍时钟比（`wr_clk` 50 ns / `rd_clk` 10 ns）保证测试里永不 overrun，但那是**测试环境的性质，不是模块的保护**。

---

## 4. 端口 / 参数表

| 参数 | 默认 | 含义 |
|---|---|---|
| `REPEAT_LINE` | 1 | 非 0 时一个源行读两遍（垂直 2×）；0 时只读一遍 |

| 端口 | 方向 | 域 | 位宽 | 作用 |
|---|---|---|---|---|
| `wr_clk` / `wr_reset` / `wr_ce` | in | 写 | 1 | 写时钟 / **同步**复位 / 写使能（0 冻结写侧） |
| `wr_pixel_valid` | in | 写 | 1 | 这一拍的 `wr_x/wr_index` 是真像素 |
| `wr_x` / `wr_index` | in | 写 | 8 / 4 | 源列号 0..255 / 4 位调色板索引 |
| `line_ready_toggle` | out | 写 | 1 | **一行已可读**，1 bit **电平**，每行翻转 |
| `line_done` | out | 写 | 1 | 一行收齐，**单周期脉冲** |
| `rd_clk` / `rd_reset` / `rd_ce` | in | 读 | 1 | 读时钟 / **同步**复位 / 读使能（0 冻结整个读侧） |
| `frame_line_valid` | out | 读 | 1 | 这一拍是有效输出像素（行内连续高） |
| `line_read_start` | out | 读 | 1 | **这一遍**的第一个像素（`read_x=0`），单拍脉冲 |
| `read_x` | out | 读 | 9 | 输出列号 0..511，空闲停在 0 |
| `read_rgb565` | out | 读 | 16 | 16 位像素，空闲时是**残留值**，不可用 |

**为什么全是 `reg` 输出？** 它们都在 `always @(posedge ...)` 里被赋值（对比 [10 篇](10-mapper-nrom.md) 全 `assign` 的 `wire`）。**输出没有帧级信号，也没有"第几遍"的信号**：下游只能数 `line_read_start`，或把 `frame_line_valid` 的低电平当行间隙。

---

## 5. 一行写入 → 跨域 → 读出，逐拍走一遍

复位后 `wr_bank=0`、`rd_bank=0`、`rd_active=0`、`toggle=0`。写源行 L0（写进 bank 0），`REPEAT_LINE=1`：

| 时刻 | 发生了什么 |
|---|---|
| 写沿 x=0..254 | `line_mem[{0,x}] <= palette(wr_index)`；`line_done=0` |
| 写沿 x=255 | 写 `line_mem[{0,255}]`；`wr_line_end=1` → `line_done<=1`、**`toggle` 0→1**、**`wr_bank` 0→1** |
| 下一写沿 | `line_done` 自动回 0；写端开始往 **bank 1** 写 L1 |
| rd 沿 #1 / #2 | `toggle_meta<=1`、然后 `toggle_sync<=1`（两级同步；此刻 `toggle_new` 仍为 0） |
| rd 沿 #3 | `toggle_new=1` → 接受：`toggle_seen<=1`、`rd_active<=1`、`rd_x_cnt<=0`、`rd_mem_q<=line_mem[{0,0}]` |
| rd 沿 #4 | **第一个有效像素**：`frame_line_valid=1`、`line_read_start=1`、`read_x=0`、`read_rgb565=line_mem[{0,0}]` |
| rd 沿 #5 / #6 | `read_x=1` 颜色仍 `line_mem[{0,0}]`（2× 复制）；`read_x=2` 变 `line_mem[{0,1}]` |
| … 至 511 | 都是 `line_mem[{0, read_x>>1}]` |
| rd 沿（read_x=511） | `rd_line_end=1`；`REPEAT_LINE=1 && !rd_second` → **不换 bank**，`rd_second<=1`、`rd_x_cnt<=0`、预装 `rd_mem_q<=line_mem[{0,0}]` |
| 第二遍末（read_x=511） | `rd_second=1` → 走 else：`rd_bank<=1`、`rd_active<=0`；`line_read_start` 本轮共脉冲 **2 次**，回 idle |

结论：**数据在写口那拍进 `line_mem`，跨域要花 2 个 `rd` 沿（两级同步）+ 1 个沿接受，第 4 个 `rd` 沿才出第一个像素；一个源行输出 1024 拍。** 全程无需就绪回执——成本就是 3.9 节的 overrun 不可检测。

---

## 6. 常见疑问

**Q：`line_ready_toggle` 和 `line_done` 都是"一行好了"，为什么要两个？读端比写端慢会丢数据吗？**
A：`line_done` 是写域**单拍脉冲**，只给写侧/调试看；`line_ready_toggle` 是**跨域电平**，因为脉冲在慢的读域里会整个丢掉（3.5）。读端慢**不超过 1 行**没问题（写端照样填另一块 bank）；只有领先 **≥2 行**时才静默丢行（3.9），且没有信号能察觉。

**Q：`rd_ce=0` 或扫描中途 `rd_reset` 会怎样？**
A：`rd_ce=0` 时整个读端（含同步器、四个输出寄存器）冻结；恢复后消费积压的那一次翻转，但积压 ≥2 次仍丢行。`rd_reset` 会丢弃正在扫的那一行并把 `rd_bank` 拉回 0，且因 `toggle_seen` 已记账不会重复读——**只有下一行恰好是偶数行（bank 0）时读写 bank 才自动重新对齐**。

**Q：`wr_index` 只有 4 位，`palette_rgb565` 却是 64 项的表？**
A：`wr_index` 是 4 位，只有 0..15 可达，故 `case` 里 `6'h10..6'h3F` 那些项在这条通路上**取不到**（TB 也只校验 16 种颜色）。表比需要的大不是错误，只是写宽了。

---

## 7. 你应该带走的三件事

1. **行缓冲 = 用"两行 ping-pong"换掉"整帧 120 KiB"**：写 bank 与读 bank 永远互反，行内不撕裂；代价是帧不再被存储，行写完必须立刻读走。
2. **跨域只传 1 bit toggle 电平，过两级同步器**：单拍脉冲会丢、电平不会；`toggle_new = toggle_sync ^ toggle_seen` 是"还有一行没读"的判据，复位时三级同步到当前值可避免伪行。
3. **2× 放大不花存储**：水平靠地址右移 `rd_next_x[8:1]`（外加 `+1` 对齐同步读延迟和行首预装），垂直靠 `REPEAT_LINE` 把同一 bank 读两遍——省下存储，付出读端时间（≥4 倍速率），否则 1 bit toggle **静默丢行**。

下一篇 [`37-video-scaler.md`](37-video-scaler.md) 看**整帧参考模型**版本：`nes_video_scaler.v` 为什么直接存下 256×240 整帧、它在 EP4CE10 上为什么装不下、以及它作为行为参照给行缓冲留下了哪些合同。
