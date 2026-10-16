# 23 状态机精读：`nes_sprite_chr_fetch.v`

上一篇 [`22-chr-fetch-unit.md`](22-chr-fetch-unit.md) 讲了"背景版"取数单元：把**一张** tile 的两个字节拆成两次单字节请求。这一篇讲**精灵版**：

> **它把"这一行要显示的 8 个精灵、每个精灵一行图案的两个字节"共 `8 × 2 = 16` 个字节，按固定顺序一个一个取回来，摆进一块 128 bit 的 `shadow` 里。**

为什么要单独一个模块，而不是复用背景那个？

1. **它要一次交付 16 个字节**。背景版只有 `bg_lo`/`bg_hi` 两个 8 位输出口，多出来的字节没有端口交出去（[`../modules/ppu-external-chr.md`](../modules/ppu-external-chr.md) 11.2 节第一条限制）。精灵一行最多 8 个 sprite，所以要**16 字节一块交**。
2. **它只在 hblank 的一个固定窗口里跑**：PPU 在每行 dot 257 打一次 `start`，取完在 dot 292 抬 `shadow_valid`，然后拿这块 `shadow` 出**下一行**的精灵像素。

- 源码：[`rtl/nes_core/ppu/nes_sprite_chr_fetch.v`](../../rtl/nes_core/ppu/nes_sprite_chr_fetch.v)
- 合同与证据：[`../modules/ppu-external-chr.md`](../modules/ppu-external-chr.md)（设计要点在**模块头注释**、接线与限制在 **11.1 / 11.3.1 节**）
- 测试目标：`sprite-fetch-core`（elaboration）、`sprite-fetch-tb`（跑 [`tb/ppu/tb_nes_sprite_chr_fetch.v`](../../tb/ppu/tb_nes_sprite_chr_fetch.v)），见 [`../../tools/sim_all.ps1`](../../tools/sim_all.ps1)

---

## 1. 先认识"上游和下游"

```text
上游 nes_ppu_sprite                   下游总线                        下游消费(精灵渲染)
  pat_addr (8×13bit) ─┐               ┌ chr_req/chr_addr ─► 优先 mux ─► mapper ─► 外部 CHR
  start(dot==257) ────┼─►[nes_sprite_chr_fetch]┤                                     │
                      │   (6 态 FSM)          └ chr_rdata ◄───────────────────────────┘
                      │   shadow(128bit)/shadow_valid/busy ─► 精灵逐 slot 读 shadow
                      └ pat_addr 已是"下一行"的地址
```

- **上游是 `nes_ppu_sprite`**：它把这一行 8 个精灵的 pattern 地址算好，打包成 104 bit 的 `pat_addr`（8 个 slot，每个 13 bit）；并且**特意给"下一行"的地址**（导出成 `pat_addr_o`，内部用 `nl_pat_addr` 算）——因为预取要提前一行。
- **下游是共享的 CHR 地址总线**：`chr_req`/`chr_addr` 是 PPU 的输出端口，经"背景 / 精灵 / `$2007` 读臂"的组合优先 mux（无握手、无背压），到外部 CHR。`chr_rdata` 同步返回，**下一个 `ce` 有效**。
- **`shadow`/`shadow_valid`/`busy` 回给 PPU**：PPU 用 `shadow` 里的字节渲染精灵像素；`shadow_valid` 是"这块数据好了"的电平（一直保持到下一次 `start`），`busy` 是"正在飞"。

一句话：**给它一行 8 个精灵的地址，它在固定窗口里按"slot0 低、slot0 高、slot1 低、……"取回 16 个字节，一块摆进 `shadow`。** 这就是"**预取到 shadow**"：不在渲染的当拍现取，而是提前把结果搬进一块寄存器备用。

---

## 2. 全文（模块体 119 行）

> 文件开头还有一段约 68 行的英文头注释（握手/字节顺序/节拍/集成限制），它讲的东西全部在 §3 里逐条展开，这里不再重复粘贴。

```verilog
`timescale 1ns/1ps

module nes_sprite_chr_fetch (
  input  wire         clk,
  input  wire         ce,
  input  wire         reset,
  input  wire         start,
  input  wire [103:0] pat_addr,
  output reg          chr_req,
  output reg  [13:0]  chr_addr,
  input  wire [7:0]   chr_rdata,
  output reg  [127:0] shadow,
  output reg          shadow_valid,
  output reg          busy
);

  localparam [2:0] S_IDLE = 3'd0;
  localparam [2:0] S_PRE  = 3'd1;
  localparam [2:0] S_ARM  = 3'd2;
  localparam [2:0] S_BEAT = 3'd3;
  localparam [2:0] S_GRAB = 3'd4;
  localparam [2:0] S_DONE = 3'd5;

  function [13:0] plane_byte;
    input [103:0] pa;
    input [2:0]   g;
    input         p;
    reg   [12:0]  pat;
    reg   [13:0]  sum;
    begin
      pat        = pa[g * 13 +: 13];
      sum        = {1'b0, pat} + (p ? 14'd8 : 14'd0);
      plane_byte = sum & 14'h3FFF;
    end
  endfunction

  reg  [2:0]   state;
  reg  [103:0] pat_q;
  reg  [2:0]   grp_q;
  reg          pl_q;
  reg          cap_pl;
  reg  [2:0]   cap_grp;
  reg          fin_q;

  wire         last_byte = pl_q && (grp_q == 3'd7);
  wire [13:0]  cur_addr  = plane_byte(pat_q, grp_q, pl_q);
  wire [13:0]  fwd_addr  = pl_q ? plane_byte(pat_q, grp_q + 3'd1, 1'b0)
                                 : plane_byte(pat_q, grp_q, 1'b1);

  always @(posedge clk) begin
    if (reset) begin
      state        <= S_IDLE;
      pat_q        <= 104'd0;
      grp_q        <= 3'd0;
      pl_q         <= 1'b0;
      cap_pl       <= 1'b0;
      cap_grp      <= 3'd0;
      fin_q        <= 1'b0;
      chr_req      <= 1'b0;
      chr_addr     <= 14'd0;
      shadow_valid <= 1'b0;
      busy         <= 1'b0;
    end else if (ce) begin
      case (state)
        S_IDLE: begin
          if (start && !busy) begin
            pat_q        <= pat_addr;
            grp_q        <= 3'd0;
            pl_q         <= 1'b0;
            state        <= S_PRE;
            busy         <= 1'b1;
            shadow_valid <= 1'b0;
          end
        end

        S_PRE: begin
          chr_addr <= cur_addr;
          state    <= S_ARM;
        end

        S_ARM: begin
          chr_req <= 1'b1;
          state   <= S_BEAT;
        end

        S_BEAT: begin
          chr_req <= 1'b0;
          cap_pl  <= pl_q;
          cap_grp <= grp_q;
          fin_q   <= last_byte;
          if (pl_q) grp_q <= grp_q + 3'd1;
          pl_q     <= ~pl_q;
          if (!last_byte) chr_addr <= fwd_addr;
          state    <= S_GRAB;
        end

        S_GRAB: begin
          if (cap_pl) shadow[cap_grp * 16 + 8 +: 8] <= chr_rdata;
          else        shadow[cap_grp * 16 +: 8]     <= chr_rdata;
          if (fin_q) begin
            state <= S_DONE;
          end else begin
            chr_req <= 1'b1;
            state   <= S_BEAT;
          end
        end

        S_DONE: begin
          busy         <= 1'b0;
          shadow_valid <= 1'b1;
          state        <= S_IDLE;
        end

        default: state <= S_IDLE;
      endcase
    end
  end

endmodule
```

先分清三类东西（[`01-verilog-basics.md`](01-verilog-basics.md) 第 1 节）：**组合逻辑**是那个 `function` 和三条 `wire`；**寄存器**是 `state` + 7 个 `reg`，只在 `posedge clk` 且 `ce=1` 时更新；指挥中心是 `case (state)`。

---

## 3. 逐段精读

### 3.1 文件头注释：它就是规格书

文件头讲三件事：**握手与顺序**（`ce` 是唯一使能；`start` 只在 `busy=0` 时受理、飞行途中直接丢弃；字节顺序固定；落点公式；地址 = `pat` / `pat+8`）、**节拍**（把受理 `start` 那拍记为 edge 1，逐拍列出 `start` 到 `shadow_valid` 的 **35 个 `ce`**）、**集成限制**（14 位口只有 13 位真地址；`pat` 的 bit3 是硬 0；`pat_addr` 必须是**下一行**的地址；`shadow` **不被复位清零**）。

其中"下一行"那句是重点：**取数单元只负责"把给它的地址取回来"，"提前一行"是上游 `nes_ppu_sprite` 用 `pat_addr_o` 做到的**。取数单元里没有"扫描线"这个概念，给它什么地址就取什么。

### 3.2 六个状态：`localparam`

```verilog
localparam [2:0] S_IDLE = 3'd0;
localparam [2:0] S_PRE  = 3'd1;
localparam [2:0] S_ARM  = 3'd2;
localparam [2:0] S_BEAT = 3'd3;
localparam [2:0] S_GRAB = 3'd4;
localparam [2:0] S_DONE = 3'd5;
```

| 状态 | 一句话 |
|---|---|
| `S_IDLE` | 等 `start`；受理后锁存 8 个 slot 地址、`busy<=1`、清 `shadow_valid` |
| `S_PRE` | 把**第一个**字节的地址放进 `chr_addr` |
| `S_ARM` | 抬起 `chr_req`（下一拍发请求） |
| `S_BEAT` | 落下 `chr_req`（一个 `ce` 宽的脉冲）；算好**下一个**地址；存接力棒；翻转平面/进位 slot |
| `S_GRAB` | 把 `chr_rdata` 收进 `shadow` 对应字节；收完去 `S_DONE`，没收完再发一次 |
| `S_DONE` | `busy<=0`、`shadow_valid<=1`，回 `S_IDLE` |

和背景版（5 态、收工点在 `S_GRAB`）相比，这里**多一个独立的 `S_DONE`**：在"最后一个字节写完"和"抬 `shadow_valid`"之间隔开一拍，让最后一个 `chr_req` 干净落下。

`case` 末尾的 `default: state <= S_IDLE;` 永远走不到（`state` 只有 6 个合法值），但**必须有**——否则工具会以为"有些取值没照顾到、要记旧值"，推断出锁存器（[`01-verilog-basics.md`](01-verilog-basics.md) 第 16 节第 1 条）。

### 3.3 `plane_byte` 函数：地址算术的核心

`function` 是**纯组合**小工具（像 C 的函数，但没有状态、没有时钟）。输入 `pa` = 整个 104 bit `pat_addr`，`g` = slot 号（0..7），`p` = 平面（0 低 / 1 高）。

```verilog
pat        = pa[g * 13 +: 13];
sum        = {1'b0, pat} + (p ? 14'd8 : 14'd0);
plane_byte = sum & 14'h3FFF;
```

- **取这个 slot 的 13 位地址**：`pa[g * 13 +: 13]` 是**变量基址切片**（[`01-verilog-basics.md`](01-verilog-basics.md) 第 10 节 `+:`）——从第 `g*13` 位起取 13 位。8 个 slot 首尾相接排在 104 位里：`slot7` 在 `bit 103..91`，……，`slot0` 在 `bit 12..0`。所以 `g*13 +: 13` 就是"跳过前 g 个 slot、取第 g 个"。
- **这 13 位怎么拼**（协议来自 `nes_ppu_sprite.v`：`s_pat_addr = {s_table, s_tile, 1'b0, s_fine[2:0]}`）：

  | bit 12 | bits 11..4 | bit 3 | bits 2..0 |
  |---|---|---|---|
  | `s_table` 图案表选择 | `s_tile[7:0]` tile 号 0..255 | `1'b0`（16 字节对齐） | `s_fine[2:0]` tile 内第几行 0..7 |

  **它就是"已经乘好 16"的字节地址**：`s_tile` 落在 `bit 11..4`（×16），`1'b0` 落在 `bit 3`，所以 `pat = tile*16 + fine`，单位是**字节**。
- **加平面偏移**：`sum = {1'b0, pat} + (p ? 14'd8 : 0)`。低平面 +0，高平面 **+8**——一张 tile 16 字节，两个平面正好隔 8 字节。`{1'b0, pat}` 把 13 位补成 14 位好做加法。
- **14 位掩码**：`sum & 14'h3FFF` 把结果收在 14 位里。这是"**14 位回卷**"的写法——形式上保证不越界。头注释说明：对**合法的** `pat`（`bit3=0`，`pat <= 0x1FF7`）最大就是 `0x1FF7 + 8 = 0x1FFF`，够不到 `0x2000`，所以这个掩码**从不真正触发**（"lossless rather than a wrap"）；`pat` 里的 `s_table` 只到 `sum` 的 `bit 12`，**永远到不了 `bit 13`**。

> **历史的坑："地址偏 8 倍"。** 头注释特意把两种写法并列：`nes_ppu_sprite` 内部那根展平的 65536 bit `chr` 总线读的是 `chr[{pat,3'b000} +: 8]`——那是**位索引**（`{pat,3'b000}` 位 = 第 `pat` 个字节）。早先的实现**把位索引当成了字节地址**，等于又**左移 3 位**（×8），于是每个请求地址都**偏大 8 倍**。正确做法：本单元的 `chr_addr` 是**字节**地址，直接输出 `pat`（或 `pat+8`），**不做任何 `<<3`**。TB 靠"独立重算一份 14 位字节地址"钉死这一点（§6 Q4）。

### 3.4 寄存器与三根"接力棒"

`pat_q`/`grp_q`/`pl_q` 是**取数上下文**（现在轮到哪个 slot、哪个平面）；`cap_pl`/`cap_grp`/`fin_q` 是**三根"接力棒"**——因为 `chr_rdata` **晚一拍**才回来，发请求时才知道的信息（"哪个 slot 的哪个平面""是不是最后一个"）必须在 `S_BEAT` 里存下来，带到 `S_GRAB`。背景版只需两根（`cap_pl`/`fin_q`），这里因为要写 `shadow` 的具体位置，**多存一根 `cap_grp`**。

### 3.5 三条组合 `wire`

```verilog
wire last_byte = pl_q && (grp_q == 3'd7);          // 高平面 且 最后一个 slot = 最后一个字节
wire [13:0] cur_addr = plane_byte(pat_q, grp_q, pl_q);   // 当前字节地址
wire [13:0] fwd_addr = pl_q ? plane_byte(pat_q, grp_q + 3'd1, 1'b0)   // 高→下一 slot 低
                            : plane_byte(pat_q, grp_q, 1'b1);          // 低→本 slot 高
```

`fwd_addr` 一行搞定"下一个字节"：低平面之后是**同 slot 的高平面**（+8）；高平面之后是**下一 slot 的低平面**（下一 slot、+0）。这就是"**地址提前一拍算好**"：状态机在 `S_BEAT`（发当前请求那拍）就把 `fwd_addr` 塞进 `chr_addr`，下一拍真正发请求时地址已就位（`if (!last_byte) chr_addr <= fwd_addr;`，最后一个字节不再更新）。

### 3.6 复位块 —— 注意 `shadow` 不在里面

**同步复位**（`always @(posedge clk)`，无 `or posedge reset`）、高有效。它把**每一个**状态寄存器清 0：状态回 `S_IDLE`、上下文与接力棒清零、`chr_req`/`chr_addr`/`shadow_valid`/`busy` 全部落 0。

**但 `shadow` 没有出现在复位块里！** 这是**刻意**的：`shadow` 只由"当前这次取数的 16 次写"改写。后果是——**第一行取完之前 `shadow` 是 `X`**，谁提前读它就染出 `X` 像素。所以消费侧必须用 `shadow_valid` 门控（合同 11.3.1 第 3 条强调的 `sp_shadow_valid`）。TB 的 **A1** 复位后断言 `chr_req`/`shadow_valid`/`busy` 全 0；**A8** 更进一步——取数**中途**拉复位，断言状态被就地清干净、之后还能正常开新一次取数。

### 3.7 `ce` 把整个状态机包住

外层是 `if (reset) ... else if (ce) ...`，**整个 `case` 都夹在 `else if (ce)` 里**：`ce=1` 走一步，`ce=0` 则什么都不动（状态、`chr_req`、`chr_addr`、`shadow`、`shadow_valid`、`busy` 逐拍保持）。这就是本项目铁律（[`02-project-conventions.md`](02-project-conventions.md) 第 1 节）：**不用门控时钟，用连续 `clk` + 使能 `ce`**。TB 的 **A5** 在取到第 3 个请求时把 `ce` 拉低 4 个 `clk`，断言这些输出一个字节都不变，放开后整行仍能跑完 16 个请求。

### 3.8 每个分支做什么、下一步去哪

- **`S_IDLE`**：`start && !busy` 里的 `!busy` 保证**飞行途中来的 `start` 被丢弃**（A6）。受理时锁存 `pat_q<=pat_addr`、`grp_q<=0`、`pl_q<=0`、`busy<=1`、**主动清 `shadow_valid`**（防上一次的"完成"电平串到这一次，A7）→ `S_PRE`。
- **`S_PRE`**：`chr_addr <= cur_addr`，此刻 `grp_q=0`、`pl_q=0`，故就是 `slot0` 低平面地址 → `S_ARM`。
- **`S_ARM`**：`chr_req <= 1'b1`。因为它是寄存器，本拍置 1、**下一拍**才在总线上高 → `S_BEAT`。
- **`S_BEAT`**：`chr_req <= 1'b0` 落回，使其**恰好高一个 `ce`**；三根接力棒存好；`if (pl_q) grp_q<=grp_q+1`（高平面发完→下一个 slot）；`pl_q<=~pl_q`（平面翻转）；`if (!last_byte) chr_addr<=fwd_addr`（提前一拍装下一个地址）→ `S_GRAB`。
- **`S_GRAB`**：用 `cap_grp`/`cap_pl` 决定 `chr_rdata` 写进 `shadow` 哪个字节（本拍拿到数据）；用 `fin_q` 决定收工（→`S_DONE`）还是再发（`chr_req<=1`→`S_BEAT`）。
- **`S_DONE`**：`busy<=0`、`shadow_valid<=1`，回 `S_IDLE`。`shadow_valid` 此后**一直保持**（`S_IDLE` 没有把它按住的语句）直到下一次 `start` 清它。
- **`default`**：回 `S_IDLE` 兜底。

### 3.9 变量位选：`shadow[cap_grp * 16 + 8 +: 8]`

```verilog
if (cap_pl) shadow[cap_grp * 16 + 8 +: 8] <= chr_rdata;
else        shadow[cap_grp * 16 +: 8]     <= chr_rdata;
```

`shadow` 是 128 位寄存器（16 字节）。切片下标是**运行期才确定的变量基址**：`cap_grp * 16` 是第 `cap_grp` 个 slot 的 16 位基址（`0,16,…,112`），`+ 8` 表示高平面落在这一 slot 的**上半个字节**，`+: 8` 从该位起取 8 位。于是 **slot g 低平面 → `shadow[g*16 +: 8]`，高平面 → `shadow[g*16+8 +: 8]`**。`cap_grp` 是 3 位，`7*16+8+8 = 128` 刚好不越界。

**换成 byte 视角**：第 `k` 个取回的字节（`k=0..15`）落在 `shadow[k*8 +: 8]`——`shadow` 的位布局就是"**16 个字节按取数顺序首尾相接，低位字节在前**"。这就是为什么顺序必须固定。

---

## 4. 端口表

| 端口 | 方向 | 位宽 | 作用 |
|---|---|---|---|
| `clk` | in | 1 | 唯一时钟 |
| `ce` | in | 1 | 时钟使能；`ce=0` 冻结整个状态机 |
| `reset` | in | 1 | 同步、高有效；清所有寄存器（**`shadow` 除外**） |
| `start` | in | 1 | "开始预取"脉冲；只在 `S_IDLE && !busy` 时被受理，飞行途中被丢弃 |
| `pat_addr` | in | 104 | 8 个 slot 的 13 位 pattern **字节**地址；**必须是下一行的**（上游 `pat_addr_o` 保证） |
| `chr_req` | out | 1 | 对存储器的读请求，**1 个 `ce` 宽脉冲**，共 16 个，每 2 `ce` 一个 |
| `chr_addr` | out | 14 | 请求地址；**请求拍之前一个 `ce` 就已就位**（bit12 是图案表选择，bit13 对合法输入恒 0） |
| `chr_rdata` | in | 8 | 存储返回的字节，**下一个 `ce` 有效** |
| `shadow` | out | 128 | 16 个字节的沉淀寄存器（见 §3.9 布局）；**不复位、只由本次的 16 次写改写** |
| `shadow_valid` | out | 1 | "这块数据好了"的**电平**，`S_DONE` 抬起后保持到下一次 `start` |
| `busy` | out | 1 | 取数进行中；`start` 只在它低时被受理 |

这些输出写成 `output reg`（而非 `wire`），因为都在 `always` 块里被 `<=` 赋值——这里它们确实都是寄存器（[`01-verilog-basics.md`](01-verilog-basics.md) 第 3 节）。

---

## 5. 代入一组 `pat_addr` 走一遍

约定：**一拍 = 一个 `ce=1` 的 `posedge`**；"受理 `start` 那拍"记为 **edge 1**。

### 5.1 先算 16 个地址

取一组现实例子：图案表 0、`fine`(行内)=0、8 个精灵的 tile 号依次是 `0x10,0x11,…,0x17`。按 §3.3 布局，每个 slot 的 13 位地址 = `tile*16`：

| slot | `pat` | 低平面 = `pat` | 高平面 = `pat+8` | slot | `pat` | 低平面 | 高平面 |
|---|---|---|---|---|---|---|---|
| 0 | `0x100` | `0x100` | `0x108` | 4 | `0x140` | `0x140` | `0x148` |
| 1 | `0x110` | `0x110` | `0x118` | 5 | `0x150` | `0x150` | `0x158` |
| 2 | `0x120` | `0x120` | `0x128` | 6 | `0x160` | `0x160` | `0x168` |
| 3 | `0x130` | `0x130` | `0x138` | 7 | `0x170` | `0x170` | `0x178` |

固定取数顺序（`slot.lo, slot.hi, …`）展开成 16 个请求地址：

```text
k :  0     1     2     3     4     5     6     7   |  8     9    10    11    12    13    14    15
a : 100   108   110   118   120   128   130   138  | 140   148   150   158   160   168   170   178
    └ slot0 ┘  └ slot1 ┘  └ slot2 ┘  └ slot3 ┘        └ slot4 ┘  └ slot5 ┘  └ slot6 ┘  └ slot7 ┘
```

每个 `(pat, pat+8)` 是一张 tile 的两个平面；每 8 字节跨一个平面，每 16 字节跨一个 tile。**地址严格递增、绝不重复、绝不回退。** 第 `k` 个字节落进 `shadow[k*8 +: 8]`，所以最终是 `shadow[7:0]=CHR[0x100]`、`shadow[15:8]=CHR[0x108]`、……、`shadow[127:120]=CHR[0x178]`。

### 5.2 逐拍走一遍（数着 35 个 `ce`）

| 拍 | `state` | 这一拍发生 | `chr_req`(拍内) | 请求地址 | 写入 `shadow` |
|---|---|---|---|---|---|
| #1 | `S_IDLE` | 受理 `start`，`pat_q<=pat_addr`,`grp=0`,`pl=0`,`busy<=1`,`shadow_valid<=0` | 0 | — | — |
| #2 | `S_PRE` | `chr_addr <= cur_addr = 0x100` | 0 | — | — |
| #3 | `S_ARM` | `chr_req <= 1` | 0 | （`0x100` 已就位） | — |
| #4 | `S_BEAT` | `chr_req<=0`；`cap_pl<=0`,`cap_grp<=0`,`fin_q<=0`；`pl<=1`；`chr_addr<=0x108` | **1** | **0x100** | — |
| #5 | `S_GRAB` | 写低平面；`fin_q=0` → `chr_req<=1` | 0 | （`0x108` 已就位） | **`shadow[7:0]`** |
| #6 | `S_BEAT` | `chr_req<=0`；`cap_pl<=1`,`cap_grp<=0`；`grp<=1`,`pl<=0`；`chr_addr<=0x110` | **1** | **0x108** | — |
| #7 | `S_GRAB` | 写高平面 | 0 | （`0x110` 已就位） | **`shadow[15:8]`** |
| … | … | 每个字节都是"1 拍发请求 + 1 拍收数写 shadow" | … | … | … |
| #33 | `S_ARM` | 第 16 个请求发出前 `chr_req<=1` | 0 | （`0x178` 已就位） | — |
| #34 | `S_BEAT` | `cap_grp<=7`,`cap_pl<=1`,`fin_q<=1`（`last_byte`）；**不再更新地址** | **1** | **0x178** | — |
| #35 | `S_GRAB` | 写高平面；`fin_q=1` → `state<=S_DONE` | 0 | — | **`shadow[127:120]`** |
| #36 | `S_DONE` | `busy<=0`、`shadow_valid<=1`，回 `S_IDLE` | 0 | — | — |

**数一数**：

- `chr_req` 高电平出现在 **#3,#5,#7,…,#33** 共 **16 次**，每次**恰好一个 `ce` 宽**、间隔 **1 个空闲 `ce`**——正是 **A2**（恰好 16 次、每 2 `ce` 一个、1 `ce` 宽、不多不少）在测的。
- 地址序列在请求拍之前一拍就已就位，严格是 §5.1 那 16 个字节地址——正是 **A3** 逐请求核对的"规范字节地址序列"（`hi = lo+8`）。
- `start`(#1) 到 `shadow_valid`(#36) = **35 个 `ce`**：首字节 4 个 `ce`（`#1→#5`），之后每字节 2 个，`4 + 2×15`，加最后一拍收工 `S_DONE` = 35。

> **35 这个数为什么关键**：PPU 在 dot 257 发 `start`，`shadow_valid` 在 dot `257 + 35 = 292` 抬起，**已经过了本行的 dot 0..255**——同行地址救不了同行像素，所以 `pat_addr` 必须是**下一行**的。

---

## 6. 常见疑问

**Q1：为什么字节顺序必须固定成 `slot0.lo, slot0.hi, …, slot7.hi`？**
A：因为 `shadow` 是**位布局固定**的寄存器——第 `k` 个字节永远落 `shadow[k*8 +: 8]`。消费侧根本不看取数过程，只认布局：slot g 低平面读 `shadow[g*16 +: 8]`、高平面读 `shadow[g*16+8 +: 8]`。顺序固定，取数就是一次**线性扫描**（地址一路递增），消费就是一个**固定公式**。顺序一变，`shadow` 的意义全乱。所以头注释把它写成合同，TB 也逐字节核对（A4）。

**Q2：为什么不把 8 个 slot 的地址一次发出去？**
A：因为外部 CHR 是**单口**——一个 `ce` 只回一个字节。取数单元的全部复杂度，就是把"16 个字节"排成一条不乱、不丢、位置能对上的流水线。

**Q3：`shadow_valid` 是电平、不会自己落，为什么每次 `start` 还要主动清它？**
A：不清的话，"上一次取完"的电平会在这一次刚开始、`shadow` 还没写完时就宣布"数据是新的"，消费侧就用**半新半旧**的 `shadow` 出像素。所以 `S_IDLE` 受理 `start` 立刻 `shadow_valid<=0`，到本次 `S_DONE` 才重新抬起。A7 就测这个：第二次 `start` 那拍断言电平被清、且中途 `shadow` 已不同于上一次。

**Q4：TB 怎么钉死"地址是字节地址、不是位索引"？**
A：TB 的 `set_expected` **完全独立地**重算期望地址——不碰被测模块，只从 13 位 `pat` 出发，在**字节**域做 `+8`，得到 14 位 `exp_addr[0..15]`；A3 再逐请求断言 `chr_addr === exp_addr[k]`。一旦被测模块重犯"把 `pat` 当位索引又 `<<3`"那个 ×8 老错，`chr_addr` 就会是期望值的 8 倍，A3 立刻 `$fatal`。**用独立重算的字节地址做锚**，是防止这种"两套记法混用"缺陷复发的关键。

**Q5：`chr_addr[13]` 到底会不会被置位？**
A：对**合法** `pat`（`bit3=0`，最大 `0x1FF7`）不会（最大 `0x1FFF`，`bit13` 恒 0，掩码从不真触发）。但这个 14 位口**不是摆设**：TB 的 **A3** 特意用一组越界 `pat`（`set1` 用 `0x1FF8`，`bit3=1`，真实精灵通路产生不出来）让 `pat+8` 溢出到 `0x2000`，**真的把 `chr_addr[13]` 驱动起来**并断言 `wrap_seen` 为真——否则一个偷偷把地址截成 13 位的实现就会漏掉。所以这是"14 位带宽承重"的覆盖率检查，不是说正常精灵会用到 `bit13`。

**Q6：`S_ARM` 抬 `chr_req`、`S_BEAT` 又落下——为什么要跨两个状态？**
A：同背景版（[`22-chr-fetch-unit.md`](22-chr-fetch-unit.md) §6）：寄存器要在某一拍被存储器看到"高电平 + 地址"，就必须**上一拍**设 1；`S_ARM` 设 1、`S_BEAT` 设 0，高电平**恰好占一个 `ce`**。地址早在 `S_PRE`（首字节）或上一个 `S_BEAT`（后续字节）放好，所以请求拍"请求 + 地址"同时有效。

---

## 7. 你应该带走的三件事

1. **预取 = 提前把结果搬进一块寄存器**：渲染当拍取不到数，就在 hblank 窗口里把 16 个字节**预取**进 128 bit `shadow`，用 `shadow_valid` 报"能用"。`shadow` 的位布局就是"16 个字节按固定顺序首尾相接"。
2. **字节地址 vs 位索引，一步错就 ×8**：`chr_addr` 是**字节**地址，等于 13 位的 `pat`（或 `pat+8`），**不做任何 `<<3`**；`nes_ppu_sprite` 内部展平 CHR 总线用的是**位**索引 `{pat,3'b000}`。混用就"地址偏 8 倍"，TB 用**独立重算的 14 位字节地址**锚死（A3）。
3. **地址提前一拍、信息打一拍、`ce` 包住整个 `case`**：地址在 `S_BEAT` 用 `fwd_addr` 提前装；"哪个 slot/哪个平面/是不是最后"用 `cap_grp`/`cap_pl`/`fin_q` 三根接力棒带到收数拍；`else if (ce)` 一包，`ce=0` 就全冻结。`start` 到 `shadow_valid` 是 **35 个 `ce`**，对应 dot 257→292。

下一篇 [`24-oam-dma.md`](24-oam-dma.md) 看另一种"按固定节奏搬很多字节"的状态机：`nes_oam_dma.v`——如何在约 513 个 `ce` 里把 CPU 侧的 256 字节搬进 PPU 的 OAM。
