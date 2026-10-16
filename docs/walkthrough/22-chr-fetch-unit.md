# 22 状态机精读：`nes_chr_fetch_unit.v`

这是本教程第一篇真正的**时序逻辑 + 状态机**模块（[`20-controller.md`](20-controller.md)、[`21-cdc-fifo.md`](21-cdc-fifo.md) 各讲了一种时序结构）。它只做一件事：

> **把"PPU 要一张背景 tile 的两个图案字节"翻译成"对外部 CHR 存储器的两次单字节读请求，并把读回的两个字节摆好交代出去"。**

为什么需要单独一个模块？因为**外部 CHR 是单口存储器**：一个 `ce` 只能做**一次读**、只回**一个字节**。而渲染一张 8×8 背景 tile 要**两个字节**——低平面在 `tile_base + i*16`、高平面在 `+8`（[`../modules/ppu-external-chr.md`](../modules/ppu-external-chr.md) 1.2 节那张四条地址约定表）。所以要有人把"两个字节"拆成"两次请求、收两个字节、配对放好"。本模块就是干这个的。

- 源码：[`rtl/nes_core/ppu/nes_chr_fetch_unit.v`](../../rtl/nes_core/ppu/nes_chr_fetch_unit.v)
- 合同与证据：[`../modules/ppu-external-chr.md`](../modules/ppu-external-chr.md)（**2.1 节节拍合同**、**11.2 节三条接口限制**）
- 可行性测量：[`../modules/chr-fetch-feasibility.md`](../modules/chr-fetch-feasibility.md)（dot 预算为什么够）
- 测试目标：`chr-fetch-core`（elaboration）、`chr-fetch-tb`（跑 [`tb/ppu/tb_nes_chr_fetch_unit.v`](../../tb/ppu/tb_nes_chr_fetch_unit.v)），见 [`../../tools/sim_all.ps1`](../../tools/sim_all.ps1)

---

## 1. 先认识"上游和下游"

```text
上游 PPU(g_chr_external)             下游总线                          下游消费(PPU 侧锁存)
  bg_fetch_due ─┐                    ┌ chr_req/chr_addr ─► 优先 mux ─► mapper ─► 外部 CHR 存储
  bg_tile_base ─┼─►[nes_chr_fetch_unit]┤                                            │
  6'd1 ─────────┘    (5 态 FSM)       └ chr_rdata ◄────────────────────────────────┘
                    bg_lo/bg_hi/bg_valid/busy ─► bg_lo_q/bg_hi_q/bg_ready ─► 像素合成
```

- **上游是 PPU 的取数触发逻辑**：它算出"这一拍该取哪个 tile"，给本模块一个 `req_start` 脉冲 + `tile_base` + `tile_count`。PPU 侧**每个 tile 窗口单独打一次 `req_start`**，所以把 `tile_count` 接成 `6'd1`（原因见 §6）。
- **下游是共享的 CHR 地址总线**：`chr_req`/`chr_addr` 是 PPU 的输出端口，经"背景 / 精灵 / `$2007` 读臂"的**组合优先 mux**（无握手、无背压），再经 mapper 译码落到外部 CHR 存储。`chr_rdata` 从存储回来，合同规定**同步读、下一个 `ce` 有效**（2.1 节）。
- **`bg_lo`/`bg_hi`/`bg_valid` 回给 PPU**：PPU 用 `bg_lo_q`/`bg_hi_q`/`bg_ready` 把数据接住（合同 §11.2 第三条：`bg_valid` 只是**脉冲**）。

一句话：**给它一个 tile 地址，它按"低平面→高平面"发两次单字节请求，读回来摆到 `bg_lo`/`bg_hi`，再用一个 `bg_valid` 脉冲报"好了"。**

---

![图 1：nes_chr_fetch_unit 状态机](../figures/chr-fetch-fsm.svg)

**图 1** · `nes_chr_fetch_unit` 的五态序列与 7 个 `ce` 的占用：两次 `chr_req` 拍分别在 `trigger+3` 与 `trigger+5`，`bg_valid` 在 `trigger+7` 拉起并保持到下一次接受。事实来源 `rtl/nes_core/ppu/nes_chr_fetch_unit.v`。生成图，勿手改，见 [`../figures/`](../figures/)。

## 2. 全文（106 行）

```verilog
`timescale 1ns/1ps

module nes_chr_fetch_unit (
  input  wire       clk,
  input  wire       ce,
  input  wire       reset,
  input  wire       req_start,
  input  wire [12:0] tile_base,
  input  wire [5:0]  tile_count,
  output reg        chr_req,
  output reg [13:0] chr_addr,
  input  wire [7:0] chr_rdata,
  output reg [7:0]  bg_lo,
  output reg [7:0]  bg_hi,
  output reg        bg_valid,
  output reg        busy
);

  localparam [2:0] S_IDLE = 3'd0;
  localparam [2:0] S_PRE  = 3'd1;
  localparam [2:0] S_ARM  = 3'd2;
  localparam [2:0] S_BEAT = 3'd3;
  localparam [2:0] S_GRAB = 3'd4;

  reg  [2:0]  state;
  reg  [12:0] base_q;
  reg  [5:0]  cnt_q;
  reg  [5:0]  idx_q;
  reg         pl_q;
  reg         cap_pl;
  reg         fin_q;

  wire        last_byte = pl_q && (idx_q == cnt_q - 6'd1);
  wire [13:0] nxt_addr  = base_q + {3'b0, idx_q, 4'd0} + (pl_q ? 14'd8 : 14'd0);
  wire [13:0] fwd_addr  = nxt_addr + 14'd8;

  always @(posedge clk) begin
    if (reset) begin
      state    <= S_IDLE;
      base_q   <= 13'd0;
      cnt_q    <= 6'd0;
      idx_q    <= 6'd0;
      pl_q     <= 1'b0;
      cap_pl   <= 1'b0;
      fin_q    <= 1'b0;
      chr_req  <= 1'b0;
      chr_addr <= 14'd0;
      bg_lo    <= 8'd0;
      bg_hi    <= 8'd0;
      bg_valid <= 1'b0;
      busy     <= 1'b0;
    end else if (ce) begin
      case (state)
        S_IDLE: begin
          if (req_start && !busy) begin
            base_q   <= tile_base;
            cnt_q    <= tile_count;
            idx_q    <= 6'd0;
            pl_q     <= 1'b0;
            state    <= S_PRE;
            busy     <= 1'b1;
            bg_valid <= 1'b0;
          end
        end

        S_PRE: begin
          chr_addr <= nxt_addr;
          state    <= S_ARM;
        end

        S_ARM: begin
          chr_req <= 1'b1;
          state   <= S_BEAT;
        end

        S_BEAT: begin
          chr_req <= 1'b0;
          cap_pl  <= pl_q;
          fin_q   <= last_byte;
          if (pl_q) idx_q <= idx_q + 6'd1;
          pl_q    <= ~pl_q;
          if (!last_byte) begin
            chr_addr <= fwd_addr;
          end
          state <= S_GRAB;
        end

        S_GRAB: begin
          if (cap_pl) bg_hi <= chr_rdata;
          else        bg_lo <= chr_rdata;
          if (fin_q) begin
            busy     <= 1'b0;
            bg_valid <= 1'b1;
            state    <= S_IDLE;
          end else begin
            chr_req <= 1'b1;
            state   <= S_BEAT;
          end
        end

        default: state <= S_IDLE;
      endcase
    end
  end

endmodule
```

读之前先分清三类东西（[`01-verilog-basics.md`](01-verilog-basics.md) 第 1 节）：**组合逻辑**是那三条 `wire`；**寄存器**是 `state` + 10 个 `reg`，只在 `posedge clk` 且 `ce=1` 时更新；真正的指挥中心是 `case (state)`。

---

## 3. 逐段精读

### 3.1 五个状态：`localparam`

```verilog
localparam [2:0] S_IDLE = 3'd0;
localparam [2:0] S_PRE  = 3'd1;
localparam [2:0] S_ARM  = 3'd2;
localparam [2:0] S_BEAT = 3'd3;
localparam [2:0] S_GRAB = 3'd4;
```

`localparam` 是模块内常量（[`01-verilog-basics.md`](01-verilog-basics.md) 第 11 节）。名字就是它们的活儿：

| 状态 | 白话 | 一句话 |
|---|---|---|
| `S_IDLE` | 空闲 | 等 `req_start`；接受后装载参数 |
| `S_PRE` | 预备 | 先把**第一个**目标地址放进 `chr_addr` |
| `S_ARM` | 举枪 | 把 `chr_req` 抬起来（下一拍发请求） |
| `S_BEAT` | 拍发 | 落下 `chr_req`（一个 ce 宽的脉冲），算好**下一个**地址、记下"这一字节是什么" |
| `S_GRAB` | 收数 | 把 `chr_rdata` 收进 `bg_lo`/`bg_hi`；收完就完事，没收完再发一次 |

`case` 末尾还有 `default: state <= S_IDLE;`，实际永远走不到（`state` 只有 5 个合法值），但**必须有**——否则工具会以为"有些取值没照顾到、要记旧值"，于是推断出锁存器（[`01-verilog-basics.md`](01-verilog-basics.md) 第 16 节第 1 条）。

> 合同 [`../modules/ppu-external-chr.md`](../modules/ppu-external-chr.md) 11.2 节把延迟写成"`... → S_DONE` 共 8 拍"。代码里**没有 `S_DONE`**——只有这 5 个状态，收数那步就是 `S_GRAB`。"8 拍"是把"受理 `req_start` 那拍"和"`bg_valid` 在总线上可见那拍"都算进去的计数（§5 会逐拍走一遍）。

### 3.2 寄存器清单

```verilog
reg  [2:0]  state;
reg  [12:0] base_q;    // 起始地址（tile_base）
reg  [5:0]  cnt_q;     // 要取多少个 tile
reg  [5:0]  idx_q;     // 当前取到第几个 tile
reg         pl_q;      // 当前这一字节是低平面(0)还是高平面(1)
reg         cap_pl;    // "接力棒"：记住刚发出去那一字节是哪个平面
reg         fin_q;     // "接力棒"：记住刚发出去那一字节是不是最后一个
```

`base_q`/`cnt_q`/`idx_q`/`pl_q` 是**取数上下文**（现在取到哪个 tile、哪个平面）；`cap_pl`/`fin_q` 是**两个"接力棒"**（§3.6、§3.7 详讲）——因为读回来的数据晚一拍，发请求时知道的信息必须"打结"带到下一拍。

### 3.3 三条组合 `wire`：地址算术的核心

```verilog
wire        last_byte = pl_q && (idx_q == cnt_q - 6'd1);
wire [13:0] nxt_addr  = base_q + {3'b0, idx_q, 4'd0} + (pl_q ? 14'd8 : 14'd0);
wire [13:0] fwd_addr  = nxt_addr + 14'd8;
```

**`last_byte`**：只有"正在处理**高平面**（`pl_q=1`）**且**这是**最后一个 tile**（`idx_q == cnt_q-1`）"时才为真。它标记整段取数的**最后一个字节**——收完它就能收工。

**`nxt_addr`**：`{3'b0, idx_q, 4'd0}` = 把 6 位 `idx_q` 左移 4 位 = `idx_q * 16`（[`01-verilog-basics.md`](01-verilog-basics.md) 第 10 节拼接：左拼 3 个 0、右拼 4 个 0，净效果 ×16），这就是**第 `idx_q` 张 tile 的低平面地址** `base + idx*16`；`+ (pl_q ? 14'd8 : 0)` 若是高平面再加 8。所以 **`nxt_addr` = "当前 tile、当前平面"的字节地址**。

**`fwd_addr` = `nxt_addr + 8` = 下一个字节**。巧思在于：**平面之间差 8，tile 之间差 16 = 2×8**，所以"下一个字节"永远是 `+8`：

| 当前 | `nxt_addr` | `fwd_addr` | 含义 |
|---|---|---|---|
| tile i，低平面（`pl_q=0`） | `base+i*16` | `base+i*16+8` | 同一个 tile 的高平面 |
| tile i，高平面（`pl_q=1`） | `base+i*16+8` | `base+i*16+16` | **下一个** tile 的低平面 |

这就是"**地址提前一拍算好**"：状态机在 `S_BEAT`（发当前请求那拍）就把 `fwd_addr` 塞进 `chr_addr`，下一拍真正发请求时地址已就位。TB 的 **A4** 逐拍断言"每个请求拍之前一个 `ce`，`chr_addr` 已等于请求地址"。

### 3.4 复位块

```verilog
if (reset) begin
    state    <= S_IDLE;
    base_q   <= 13'd0;
    ...
    busy     <= 1'b0;
end
```

**同步复位**（敏感列表是 `always @(posedge clk)`，没有 `or posedge reset`），高有效。它把**每一个**寄存器清成 0：状态机回 `S_IDLE`；取数上下文清零；两个接力棒清零；输出全部落 0（`chr_req`/`chr_addr`/`bg_lo`/`bg_hi`/`bg_valid`/`busy`）。TB 的 **A1** 在复位后断言 `chr_req`/`bg_valid`/`busy` 全 0；**A8** 更进一步——取数**中途**拉复位，断言状态被就地清干净、之后还能正常开始新一次取数。（本仓库核内 `reset` 高有效，板级低有效按键的反转在平台层做，[`01-verilog-basics.md`](01-verilog-basics.md) 第 8 节。）

### 3.5 `ce` 把整个状态机包住

```verilog
end else if (ce) begin
    case (state)
        ...
    endcase
end
```

外层骨架是 `if (reset) ... else if (ce) ...`，**整个 `case` 都夹在 `else if (ce)` 里**，所以 `ce=1` 才走一步、`ce=0` 则**什么都不动**——状态、地址、`chr_req`、`bg_valid`、`busy` 逐拍保持。这正是本项目铁律（[`02-project-conventions.md`](02-project-conventions.md) 第 1 节）：**不用门控时钟，用连续 `clk` + 使能 `ce`**。TB 的 **A5** 在一行取到一半时把 `ce` 拉低 4 个 `clk`，断言这期间所有输出一个字节都不变，放开后整行仍能跑完。

> 副作用（合同 §11.3.5）：`ce=0` 冻结会把 `chr_req` 的高电平**拉长到多个 `clk`**，于是它不再是 2.1 节说的"1 个 `ce` 宽脉冲"。这不是 bug，是 `ce` 门控的直接后果；系统里 `ce_ppu` 是连续 1-in-4，所以实际不出现。

### 3.6 每个分支做什么、下一步去哪

（代码见 §2，这里只讲行为。）

- **`S_IDLE`**（接受任务）：条件 `req_start && !busy` 里的 `!busy` 保证**取数途中来的 `req_start` 被忽略**（A6）。受理时装载 `base_q`/`cnt_q`/`idx_q=0`/`pl_q=0`、抬起 `busy`（告诉别人"我在飞"）、**主动清 `bg_valid`**（防上一行的完成脉冲串到这一行，A7）→ `S_PRE`。
- **`S_PRE`**：`chr_addr <= nxt_addr`。此刻 `idx_q=0`、`pl_q=0`，故 `nxt_addr = base_q`——**第一个字节就是 `tile_base`** → `S_ARM`。
- **`S_ARM`**：`chr_req <= 1'b1`。因为 `chr_req` 是寄存器，本拍置 1、**下一拍**才在总线上高 → `S_BEAT`。
- **`S_BEAT`**（发请求 + 算下一站）：`chr_req <= 1'b0` 落回，使 `chr_req` **恰好高一个 `ce`**；`cap_pl <= pl_q`、`fin_q <= last_byte`（存两根接力棒）；`if (pl_q) idx_q <= idx_q+1`；`pl_q <= ~pl_q`（平面翻转）；`if (!last_byte) chr_addr <= fwd_addr`（**提前一拍**装好下一个地址，最后一个字节就不再更新）→ `S_GRAB`。
- **`S_GRAB`**（收数）：用 `cap_pl` 决定 `chr_rdata` 进 `bg_hi` 还是 `bg_lo`（这就是"这一拍请求、下一拍收数"的收数点）；用 `fin_q` 决定收工（`busy<=0`、`bg_valid<=1`、回 `S_IDLE`）还是再发（`chr_req<=1`、回 `S_BEAT`）。
- **`default`**：回 `S_IDLE` 兜底。

### 3.7 `cap_pl` / `fin_q`：为什么两个信息要"打一拍"

关键是**读的延迟**：合同 2.1 节规定 `chr_rdata` 在**下一个 `ce`** 才有效。流程必然是：

```text
S_BEAT（本拍发请求、地址就位）——还知道：这字节是低/高平面？是不是最后一个？
   │
   ▼
S_GRAB（下一拍才拿到 chr_rdata）——可 pl_q 已被翻转、idx_q 已经 +1
```

在 `S_BEAT` 里，`pl_q` 和 `last_byte` 都会在同一拍被改掉（`pl_q <= ~pl_q`、`idx_q <= idx_q+1`）。到下一拍 `S_GRAB`，`pl_q` 已是新值，无法再回答"刚回来那个字节是哪个平面"。所以 `S_BEAT` **提前把判断结果存进 `cap_pl`/`fin_q`**，`S_GRAB` 读它们即可。这就是两根"接力棒"存在的唯一理由——**把发请求时才知道的信息传递到收数据那一拍**。

---

## 4. 端口表

| 端口 | 方向 | 位宽 | 作用 |
|---|---|---|---|
| `clk` | in | 1 | 唯一时钟 |
| `ce` | in | 1 | 时钟使能；`ce=0` 冻结整个状态机 |
| `reset` | in | 1 | 同步、高有效；把所有寄存器清零 |
| `req_start` | in | 1 | "开始取数"脉冲；只在 `S_IDLE && !busy` 时被受理 |
| `tile_base` | in | 13 | 起始 tile 的**局部** CHR 地址（低平面地址） |
| `tile_count` | in | 6 | 要取多少张 tile（每张 2 字节）；PPU 侧接 `6'd1` |
| `chr_req` | out | 1 | 对存储器的读请求，**1 个 `ce` 宽脉冲** |
| `chr_addr` | out | 14 | 请求地址；**请求拍之前一个 ce 就已就位**（bit12 是 pattern table 选择位，bit13 恒 0） |
| `chr_rdata` | in | 8 | 存储返回的字节，**下一个 `ce` 有效** |
| `bg_lo` | out | 8 | 低平面字节（寄存器；`tile_count>1` 时只剩**最后一个 tile** 的，见 §6） |
| `bg_hi` | out | 8 | 高平面字节（同上） |
| `bg_valid` | out | 1 | "取完了"**脉冲**，只高一个 `ce`，随后回 `S_IDLE` |
| `busy` | out | 1 | 取数进行中；`req_start` 只在它低时被受理 |

这几个输出写成 `output reg`（而非 `wire`），是因为它们都在 `always` 块里被 `<=` 赋值；这里它们确实都是寄存器（[`01-verilog-basics.md`](01-verilog-basics.md) 第 3 节）。

---

## 5. 代入 `tile_count=1` 和 `tile_count=33` 各走一遍

约定：**一拍 = 一个 `ce=1` 的 `posedge`**；下表写"该拍**开始**时各值"，以及该拍结束时寄存器变成的值。设 `tile_base = B`。

### 5.1 `tile_count=1`（取 1 张 tile = 2 个字节）

| 拍 | `state` | 这一拍发生 | `chr_req`(拍内) | 请求地址 |
|---|---|---|---|---|
| #1 | `S_IDLE` | 受理 `req_start`，装载 `B`,`cnt=1`,`idx=0`,`pl=0`，`busy<=1` | 0 | — |
| #2 | `S_PRE` | `chr_addr <= nxt_addr = B` | 0 | — |
| #3 | `S_ARM` | `chr_req <= 1` | 0 | （`chr_addr=B` 已就位） |
| #4 | `S_BEAT` | `chr_req <= 0`；`cap_pl<=0`,`fin_q<=0`；`pl<=1`；`chr_addr<=fwd=B+8` | **1** | **B**（低平面） |
| #5 | `S_GRAB` | `cap_pl=0` → `bg_lo <= chr_rdata`；`fin_q=0` → `chr_req<=1` | 0 | （`chr_addr=B+8` 已就位） |
| #6 | `S_BEAT` | `chr_req <= 0`；`cap_pl<=1`,`fin_q<=1`（`last_byte=1`）；`idx<=1`,`pl<=0`；不更新地址 | **1** | **B+8**（高平面） |
| #7 | `S_GRAB` | `cap_pl=1` → `bg_hi <= chr_rdata`；`fin_q=1` → `busy<=0`,`bg_valid<=1`,回 `S_IDLE` | 0 | — |
| #8 | `S_IDLE` | `bg_valid` 在总线上可见（下游在这个 ce 接住） | 0 | — |

**数一数**：`chr_req` 只高了 **2 次**（#4 请求 `B`、#6 请求 `B+8`），正好 = `2 × tile_count`；地址序列 **B → B+8** 严格 +8 递增。这正是 `chr-fetch-tb` 的 **A2**（请求数 = `2*c`、首址 = `tile_base`）与 **A4**（地址提前一拍就位）在测的东西。从受理 `req_start`（#1）到 `bg_valid` 可见（#8）是 **8 个 `ce`**——PPU 侧的 9 拍流水正是为了吸收这 8 拍延迟（合同 §11.2）。

### 5.2 `tile_count=33`（最坏行，66 次请求）

TB 用的最坏行是 `WORST_BASE = 1024`、`WORST = 33`，断言 **恰好 66 次请求**、**最后一个地址 = base + 520**。用上面公式亲手验一遍：

- 请求总数 = `2 × tile_count` = `2 × 33` = **66**。
- 第 `k` 次请求地址 = `base + 8*k`，`k = 0,1,...,65`（每字节步长 8）。
- 最后一次（`k=65`）= `base + 8*65` = `base + 520` = `1024 + 520` = **1544**。

地址序列：

```text
B+0   B+8   B+16   B+24   B+32   ...   B+504   B+512   B+520
低0   高0    低1    高1    低2    ...   低32    高32    ——
        ↑tile0↑      ↑tile1↑              ↑tile32↑（最后一个字节）
```

每一对 `(B+16i, B+16i+8)` 就是第 `i` 张 tile 的低/高平面。地址**严格 +8 递增、绝不重复、绝不回退**——正是 **A3** 逐请求断言的三条（首址、`prev+8`、严格递增）；TB 还用 `chr_mem[b+kk*16]` / `chr_mem[b+kk*16+8]` 逐个核对 `bg_lo`/`bg_hi` 的值，确保取回的不是"顺序对但内容错"。66 这个数同合同 §11.1.2 的表一致（`fine_x≠0`、`mask_reg[1]=1` 那格是 66/line）；取数单元不关心 `fine_x`/`mask`，它只负责把"33 张 tile"变成 66 次请求，何时发由 PPU 的触发逻辑决定。

---

## 6. 常见疑问

**Q：`tile_count` 能数到 33，为什么 PPU 侧偏偏接 `6'd1`？**
A：因为合同 §11.2 第一条限制——**本模块只暴露最后一个 tile**。`bg_lo`/`bg_hi` 是"最后一个 tile"的寄存器：`tile_count>1` 时前面 `tile_count-1` 个 tile 的字节**确实取回来了、也确实写进了 `bg_lo`/`bg_hi`**，但会被后面的 tile **覆盖**，而且没有任何端口把它们交出来。所以 PPU 侧干脆**每个 tile 窗口打一次 `req_start`、`tile_count` 接 1**，用逐 tile 流水摊到整行；那个 6 位口在 PPU 侧其实**没被用上**（TB 用它来测多 tile 连续取数这条路径）。

**Q：`S_ARM` 抬起 `chr_req`、`S_BEAT` 又落下——为什么要跨两个状态？**
A：因为 `chr_req` 是寄存器。要让存储器在某一拍看到"高电平 + 地址"，就得**上一拍**把它设成 1。`S_ARM` 设 1（下一拍高）、`S_BEAT` 设 0（下一拍低），高电平**恰好占一个 `ce`**。地址早在 `S_PRE` 就放好，所以 `S_BEAT` 那拍"请求 + 地址"同时有效。

**Q：为什么地址要在前一拍（`S_BEAT` 里装 `fwd_addr`）就算好？**
A：因为存储器是**同步读**：它在"请求有效"那拍采样地址并锁存，必须保证请求拍到来时地址**已经稳定**。提前一拍装好就是留出这一拍建立时间，对应合同 2.1 节"`chr_addr` 在请求期间寄存保持"；TB 的 A4 把这条钉死。

**Q：`bg_valid` 为什么只是脉冲，不是电平？**
A：`S_GRAB` 里置 1 后下一拍就回 `S_IDLE`，而 `S_IDLE` 没有把它按住的语句，所以它高一个 `ce` 就落下（`bg_lo`/`bg_hi` 本身保持不变）。合同 §11.2 第三条讲的就是这个——**没有"数据仍然有效"的握手**，所以下游（PPU）必须自己配 `bg_lo_q`/`bg_hi_q`/`bg_ready` 锁存，本模块只负责"报一声"。

**Q：`busy` 和 `state != S_IDLE` 是一回事吗？**
A：基本绑定，但 `busy` 是**给下游看**的：受理时置 1、`fin_q` 收工时置 0。它既用来挡住行中途的 `req_start`（A6），也被 PPU 侧用来判断"取数是否在飞"。

---

## 7. 你应该带走的三件事

1. **单口存储要靠状态机"排队"**：外部 CHR 一个 `ce` 只回一个字节，取数单元就把"一个 tile 两字节"展开成"低平面请求 → 高平面请求"，每字节恰好 2 个 `ce`（1 拍发、1 拍收）。
2. **地址提前一拍、信息打一拍**：地址在 `S_BEAT` 里用 `fwd_addr` 提前装好；"这是哪个平面/是不是最后"两个判断用 `cap_pl`/`fin_q` 接力到收数那一拍——都是为了迁就存储器"下一拍才回数据"的延迟。
3. **`ce` 包住整个 `case`**：`else if (ce)` 一包，`ce=0` 就冻结状态、地址、请求、完成脉冲全部不动；复位块把每个寄存器清零。这是本项目所有状态机的统一骨架（[`02-project-conventions.md`](02-project-conventions.md) 第 4 节）。

下一篇 [`23-sprite-chr-fetch.md`](23-sprite-chr-fetch.md) 看同一类问题的"精灵版"：如何在 hblank 的固定窗口里，把 **8 个 slot × 2 个平面 = 16 个字节**排好队取回来。
