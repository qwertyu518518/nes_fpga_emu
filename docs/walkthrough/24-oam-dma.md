# 24 一个真正的总线主设备：`nes_oam_dma.v`

前面 [`22-chr-fetch-unit.md`](22-chr-fetch-unit.md)、[`23-sprite-chr-fetch.md`](23-sprite-chr-fetch.md) 的状态机都在"自己家里"搬数据。这一篇不一样：它要**抢走 CPU 的总线**，把 CPU 停住一段时间，把 256 个字节从 CPU 内存搬到 PPU 的精灵内存里。

- 源码：[`rtl/nes_core/ppu/nes_oam_dma.v`](../../rtl/nes_core/ppu/nes_oam_dma.v)
- 合同与证据：[`../modules/oam-dma.md`](../modules/oam-dma.md)
- 测试目标：`ppu-oam-dma`（见 [`tb/ppu/tb_nes_oam_dma.v`](../../tb/ppu/tb_nes_oam_dma.v)）

---

## 1. 先认识"这是什么"和"它站在哪"

**什么是 OAM DMA。** PPU 里有 256 字节的 **OAM**（Object Attribute Memory），存 64 个精灵的坐标、图案号、属性。游戏通常在**垂直消隐（vblank）**里整屏更新它：把这 256 字节放在 CPU 内存的**同一页**（地址高 8 位相同，如 `$0200-$02FF`），然后让 CPU 写一次寄存器 `$4014`——写入的**值就是页号**（`$02` 表示从 `$0200-$02FF` 搬）。写完后硬件自动逐个搬运这 256 字节，这段自动搬运就叫 **OAM DMA**。

**为什么写一次 `$4014` 会占掉 CPU 时间。** `$4014` 不是"发个命令就返回"。DMA 引擎要**真的去读 CPU 内存的 256 个字节**，而这些字节必须一次次出现在 CPU 地址总线上。于是它干脆**把 CPU 整个停住**，自己接管地址总线直到搬完。

- 软件模拟器里这很简单：主循环里"不调用 `cycle_cpu()`"就等于停住（见 [`../modules/oam-dma.md`](../modules/oam-dma.md) 第 1 节）。
- 硬件里必须有**握手**：DMA 说"我要读这个地址"（`cpu_read_req` + `cpu_read_addr`），总线回答"给你数据了"（`cpu_read_ack` + `cpu_rdata`），一次才算读完。

这个"读/答"来回走完 256 次，就是被占用的 CPU 时间：**偶数周期启动 513 拍，奇数周期启动 514 拍**（多一个"对齐"拍）。

**它站在哪（上下游）：**

```text
   CPU 执行 "STA $4014"（值 = 页号）
            ▼
   nes_cpu_bus 译码 $4014 ──► start, src_page=页号, oam_addr=当前 OAMADDR
            ▼
    ┌───────────────────────┐
    │      nes_oam_dma      │
    └───────────────────────┘
       └ cpu_hold ───────────► nes_cpu_bus 的 bus_hold（冻住 CPU）
       └ cpu_read_req/addr ──► 工作 RAM / PRG ROM ──┐ cpu_rdata
       ◄──────── cpu_read_ack ◄──────────────────────┘
       └ ppu_reg_cs/we/addr/dout ─► nes_ppu2c02 的 $2003 / $2004 写
```

三条边界（详见 [`../modules/oam-dma.md`](../modules/oam-dma.md) 第 7 节）：

1. **CPU 侧**：`cpu_hold` 交给 [`nes_cpu_bus.v`](../../rtl/nes_core/bus/nes_cpu_bus.v) 的 `bus_hold`，冻结 CPU 状态机。握手风格与 `nes_apu_dmc.v` 的 DMC 取样一致。
2. **PPU 侧**：`ppu_reg_*` 接到 [`nes_ppu2c02.v`](../../rtl/nes_core/ppu/nes_ppu2c02.v) 的寄存器写端口，由 PPU 真正执行 `$2003`（OAMADDR）/`$2004`（OAMDATA）写。
3. **精灵侧**：本模块**不碰** [`nes_ppu_sprite.v`](../../rtl/nes_core/ppu/nes_ppu_sprite.v)。它只保证"写完 256 字节"，渲染有没有撕裂不是它的事。

---

## 2. 全文（135 行）

```verilog
`timescale 1ns/1ps

module nes_oam_dma #(
    parameter OAMADDR_WRITE = 1'b0
)(
    input  wire        clk,
    input  wire        reset,
    input  wire        start,
    input  wire [7:0]  src_page,
    input  wire [7:0]  oam_addr,
    input  wire        cpu_read_ack,
    input  wire [7:0]  cpu_rdata,
    output wire        cpu_hold,
    output wire [15:0] cpu_read_addr,
    output wire        cpu_read_req,
    output wire        ppu_reg_cs,
    output wire        ppu_reg_we,
    output wire [2:0]  ppu_reg_addr,
    output wire [7:0]  ppu_reg_dout,
    output wire        busy,
    output wire        done,
    output wire [15:0] cycle_count,
    output wire [7:0]  dbg_page,
    output wire [7:0]  dbg_oam_addr,
    output wire [7:0]  dbg_index,
    output wire [1:0]  dbg_align_left,
    output wire        dbg_addr_wr
);

    localparam [2:0] REG_OAMADDR = 3'd3;
    localparam [2:0] REG_OAMDATA = 3'd4;

    localparam [2:0] ST_IDLE  = 3'd0;
    localparam [2:0] ST_ALIGN = 3'd1;
    localparam [2:0] ST_READ  = 3'd2;
    localparam [2:0] ST_WRITE = 3'd3;

    reg [2:0]  state;
    reg [1:0]  align_left_q;
    reg        parity_q;
    reg [7:0]  page_q;
    reg [7:0]  oam_base_q;
    reg [7:0]  oam_cur_q;
    reg [7:0]  index_q;
    reg [15:0] read_addr_q;
    reg [7:0]  data_q;
    reg [15:0] cycle_cnt_q;

    wire addr_phase = (state == ST_ALIGN) && (align_left_q == 2'd1);
    wire addr_wr    = OAMADDR_WRITE && addr_phase;
    wire last_write = (state == ST_WRITE) && (index_q == 8'hFF);
    wire read_ack   = (state == ST_READ) && cpu_read_ack;

    assign busy          = (state != ST_IDLE);
    assign cpu_hold      = busy;
    assign done          = last_write;
    assign cycle_count   = cycle_cnt_q;
    assign cpu_read_req  = (state == ST_READ);
    assign cpu_read_addr = read_addr_q;
    assign ppu_reg_cs    = (state == ST_WRITE) || addr_wr;
    assign ppu_reg_we    = ppu_reg_cs;
    assign ppu_reg_addr  = (state == ST_WRITE) ? REG_OAMDATA : REG_OAMADDR;
    assign ppu_reg_dout  = (state == ST_WRITE) ? data_q :
                           (state == ST_ALIGN) ? oam_base_q : 8'h00;
    assign dbg_page      = page_q;
    assign dbg_oam_addr  = oam_cur_q;
    assign dbg_index     = index_q;
    assign dbg_align_left = align_left_q;
    assign dbg_addr_wr   = addr_wr;

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            state       <= ST_IDLE;
            align_left_q <= 2'd0;
            parity_q    <= 1'b0;
            page_q      <= 8'h00;
            oam_base_q  <= 8'h00;
            oam_cur_q   <= 8'h00;
            index_q     <= 8'd0;
            read_addr_q <= 16'h0000;
            data_q      <= 8'h00;
            cycle_cnt_q <= 16'd0;
        end else begin
            parity_q <= ~parity_q;

            if ((state != ST_IDLE) && !last_write)
                cycle_cnt_q <= cycle_cnt_q + 16'd1;

            case (state)
                ST_IDLE: begin
                    if (start) begin
                        page_q      <= src_page;
                        oam_base_q  <= oam_addr;
                        oam_cur_q   <= oam_addr;
                        index_q     <= 8'd0;
                        read_addr_q <= {src_page, 8'h00};
                        data_q      <= 8'h00;
                        align_left_q <= parity_q ? 2'd2 : 2'd1;
                        cycle_cnt_q <= 16'd1;
                        state       <= ST_ALIGN;
                    end
                end

                ST_ALIGN: begin
                    if (align_left_q > 2'd1)
                        align_left_q <= align_left_q - 2'd1;
                    else
                        state <= ST_READ;
                end

                ST_READ: begin
                    if (read_ack) begin
                        data_q      <= cpu_rdata;
                        read_addr_q <= read_addr_q + 16'd1;
                        state       <= ST_WRITE;
                    end
                end

                ST_WRITE: begin
                    oam_cur_q <= (oam_cur_q == 8'hFF) ? 8'h00 : (oam_cur_q + 8'd1);
                    if (index_q == 8'hFF) begin
                        index_q <= 8'd0;
                        state   <= ST_IDLE;
                    end else begin
                        index_q <= index_q + 8'd1;
                        state   <= ST_READ;
                    end
                end

                default: state <= ST_IDLE;
            endcase
        end
    end

endmodule
```

---

## 3. 逐段精读

### 3.1 参数 `OAMADDR_WRITE`

一个开关，决定**要不要替 CPU 写一次 `$2003`（OAMADDR）**。`0`（默认）只做 256 次 `$2004` 写，起始地址由 CPU 自己在 `$4014` 之前写——**这是真实硬件的行为**；`1` 则在对齐阶段多发一次 `$2003` 代劳。两种接法搬出的 256 字节**完全相同**，区别只是 `$2003` 由谁发。

### 3.2 寄存器清单（11 个 `reg`）

`state`（4 态）、`align_left_q`（对齐剩余 1/2 拍）、`parity_q`（自由运行的奇偶位）、`page_q`（锁存源页）、`oam_base_q`（锁存起始 OAM 地址）、`oam_cur_q`（影子 OAM 地址，会回绕）、`index_q`（已写字节 0..255）、`read_addr_q`（CPU 读地址，逐字节 +1）、`data_q`（等写进 PPU 的字节）、`cycle_cnt_q`（已过拍数）。这 11 个就是全部记忆；几乎所有输出都是它们的组合函数（`busy`、`done`、`cpu_hold`……），所以输出天然稳定。

### 3.3 派生信号与输出

```verilog
wire addr_phase = (state == ST_ALIGN) && (align_left_q == 2'd1);  // 对齐最后一拍
wire addr_wr    = OAMADDR_WRITE && addr_phase;                    // 这一拍写 $2003
wire last_write = (state == ST_WRITE) && (index_q == 8'hFF);      // 第 256 次写
wire read_ack   = (state == ST_READ) && cpu_read_ack;             // 读被授权

assign busy          = (state != ST_IDLE);        // 只要不空闲就是忙
assign cpu_hold      = busy;                      // 停机 = 忙（别名）
assign done          = last_write;                // 完成 = 最后一次写
assign cpu_read_req  = (state == ST_READ);        // 电平，不是脉冲
assign cpu_read_addr = read_addr_q;
assign ppu_reg_cs    = (state == ST_WRITE) || addr_wr;
assign ppu_reg_we    = ppu_reg_cs;
assign ppu_reg_addr  = (state == ST_WRITE) ? REG_OAMDATA : REG_OAMADDR;
assign ppu_reg_dout  = (state == ST_WRITE) ? data_q :
                       (state == ST_ALIGN) ? oam_base_q : 8'h00;
```

- **`cpu_hold = busy`**：一行讲完"整个事务期间 CPU 停住"。
- **`cpu_read_req` 是电平**：拉高后保持到 `cpu_read_ack` 出现，所以"总线慢几拍"是免费的。
- **`ppu_reg_addr` 只在非 WRITE 时才可能是 `OAMADDR(3)`**：`$2003` 只出现在对齐拍的 `addr_wr`，`$2004` 只出现在 WRITE。两者**永不同拍**（测试专门断言）。

### 3.4 时序块：复位、奇偶、周期计数

```verilog
parity_q <= ~parity_q;                       // 无条件、每拍翻转（自由运行）
if ((state != ST_IDLE) && !last_write)
    cycle_cnt_q <= cycle_cnt_q + 16'd1;      // 忙且不是最后一拍才 +1
```

- `or posedge reset` 是**异步复位**，`reset=1` 立刻清空。
- `parity_q` 每拍翻转，它的当前值在 `start` 被采样时决定对齐长度。
- 周期计数**在最后一拍不加**（`!last_write`），所以会**停在终值** 513/514。

### 3.5 四个状态

| 状态 | 做什么 | 下一步 |
|---|---|---|
| `ST_IDLE` | 等 `start`；锁存 `src_page`/`oam_addr`，`read_addr_q={src_page,8'h00}`，`align_left_q` 由 `parity_q` 定为 1 或 2，`cycle_cnt_q=1` | `ST_ALIGN` |
| `ST_ALIGN`（对齐） | 空转 1 或 2 拍；`align_left_q>1` 时减 1，否则转走 | `ST_READ` |
| `ST_READ`（请求/读） | 发 `cpu_read_req` 并保持；`read_ack` 时锁存 `data_q<=cpu_rdata`、`read_addr_q+1` | `ST_WRITE` |
| `ST_WRITE`（写/收尾） | 写一次 `$2004`；`oam_cur_q` 回绕递增；`index_q==FF` 则收尾 | `ST_READ` 或（第 256 次）`ST_IDLE` |

要记住三点：

- **源页只锁存一次**：`page_q <= src_page` 在 `start` 那拍拍下，之后 256 次读都用它，CPU 事后改那页变量也不影响。
- **`read_addr_q` 只在 ack 时 +1**：等待期间 `cpu_read_addr` 稳定不变，这是"延迟 ack 不丢数据"的关键。
- **两个回绕**：`oam_cur_q` 每到 WRITE 就 +1、`FF` 后回 `00`（OAM 地址回绕，真实回绕由 PPU 完成，这里只是同构影子）；`index_q` 用第 256 次（`==FF`）作为收工条件然后清零（**256 字节计数的回绕检测**）。

---

## 4. 端口表

| 端口 | 方向 | 位宽 | 作用 |
|---|---|---|---|
| `clk` | in | 1 | 唯一时钟 |
| `reset` | in | 1 | 异步复位，高有效 |
| `start` | in | 1 | 一拍脉冲，启动一次搬运（`$4014` 写） |
| `src_page` | in | 8 | 源页号（`$4014` 写入值），`start` 时锁存 |
| `oam_addr` | in | 8 | 起始 OAM 地址（= OAMADDR），`start` 时锁存 |
| `cpu_read_ack` | in | 1 | 总线授权，可延迟任意拍 |
| `cpu_rdata` | in | 8 | 读回字节，约定在 ack 同拍有效 |
| `cpu_hold` | out | 1 | = `busy`，接到 `nes_cpu_bus` 的 `bus_hold`，冻住 CPU |
| `cpu_read_addr` | out | 16 | 读地址，事务期间 `$xx00 -> $xxFF` |
| `cpu_read_req` | out | 1 | 电平请求，保持到 ack |
| `ppu_reg_cs` | out | 1 | PPU 寄存器片选，写 `$2003`/`$2004` 时为高 |
| `ppu_reg_we` | out | 1 | 写使能，= `ppu_reg_cs` |
| `ppu_reg_addr` | out | 3 | `3=$2003`(OAMADDR)，`4=$2004`(OAMDATA) |
| `ppu_reg_dout` | out | 8 | 写数据：WRITE 拍为 `data_q`，align 拍为 `oam_base_q` |
| `busy` | out | 1 | 事务期间为高 |
| `done` | out | 1 | 单拍脉冲，与第 256 次写同拍 |
| `cycle_count` | out | 16 | 已过拍数，事务后保持 513 或 514 |
| `dbg_page` / `dbg_oam_addr` / `dbg_index` | out | 8/8/8 | 观测：锁存页号 / 影子 OAM 地址（回绕）/ 已写字节计数 |
| `dbg_align_left` / `dbg_addr_wr` | out | 2/1 | 观测：对齐剩余拍（1 或 2）/ 本拍是否发 `$2003` 写 |

`dbg_*` 只能看，不能反过来影响逻辑。

---

## 5. 逐拍走一遍一次 `$4014` 搬运

设定：`src_page=$02`，`oam_addr=$00`，`OAMADDR_WRITE=0`，总线零等待（`ack` 与 `req` 同拍）。

### 5.1 偶数对齐（`parity_q=0` → `align_left_q=1`，共 513 拍）

| `cycle_count` | 状态 | `req` | `read_addr` | `reg_cs` | `reg_addr` | 说明 |
|---|---|---|---|---|---|---|
| 1 | ALIGN | 0 | `$0200` | 0 | — | 对齐拍（1 拍） |
| 2 | READ #0 | 1 | `$0200` | 0 | — | 读 `$0200` |
| 3 | WRITE #0 | 0 | `$0201` | 1 | `4` | 写 `$2004` = `$0200` 的值 |
| … | … | … | … | … | … | 读/写交替（每字节：READ 一拍 + WRITE 一拍） |
| 512 | READ #255 | 1 | `$02FF` | 0 | — | 最后一个读 |
| 513 | WRITE #255 | 0 | `$0300` | 1 | `4` | **`done=1`**，`busy` 仍高 |
| 514 | IDLE | 0 | `$0300` | 0 | `3` | `busy` 落下，`cycle_count` 停在 513 |

读地址 `$0200 -> $02FF`；`read_addr_q` 是 16 位，第 256 次读后进到 `$0300`（寄存器溢出，不再使用）。`done` 与最后一次写**同拍**，那一拍 `cpu_hold` 还高——"完成"这一刻总线和 PPU 都还在动。

### 5.2 奇数对齐（`parity_q=1` → `align_left_q=2`，共 514 拍）

只差最前面多一个对齐拍：第 1 拍 ALIGN（剩 2，减到 1），第 2 拍 ALIGN（剩 1，转 READ），第 3 拍起和偶数情形完全一致、整体后移一拍，第 514 拍 `WRITE #255` 置 **`done=1`**。

**513 vs 514 的由来**：写 `$4014` 时 CPU 处于偶数周期 → 1 个对齐拍 → 513；处于奇数周期 → 多等 1 拍凑齐偶相位 → 514。本模块用一个自由运行的 `parity_q` 在 `start` 那拍决定 `align_left_q`，把这条规则写死在硬件里。

### 5.3 打开 `OAMADDR_WRITE=1` 多出来的 `$2003` 写

`addr_wr` 发生在对齐阶段**最后一拍**（偶数是第 1 拍，奇数是第 2 拍），此时 `ppu_reg_cs=1`、`ppu_reg_addr=3`、`ppu_reg_dout=oam_base_q`。它**搭在本来就要空转的对齐拍里**，所以**不额外占周期**：513/514 不变，只是 `ppu_reg_cs` 高的总拍数从 256 变成 257。

### 5.4 总线慢一拍会怎样

若 ack 每字节延迟 `d` 拍，则每次 READ 变成 `1+d` 拍，总周期 `cycle_count = 512 + align_len + 256×(1+d)`（`align_len` 为 1 或 2）。零等待就是 513/514；`d=4` 时等于 `513 + 1024`（测试就是这么算的）。数据一个字节都不会错，因为等待期间请求和地址都保持不变。

---

## 6. 常见疑问

**Q：`cpu_hold` 和 `busy` 为什么是同一个值？**
A：因为"停机"和"忙"在本模块里是同一件事。拆两个名字只为可读：CPU 侧叫 `cpu_hold`，观测侧叫 `busy`。测试用 `hold_err` 断言 `a_busy === a_hold`。

**Q：`done` 是高电平还是脉冲？**
A：只有**一拍**。`last_write` 只在 `state==ST_WRITE && index_q==FF` 成立；最后一拍 `cycle_cnt` 不加、下一拍即回 IDLE，所以 `done` 不会超过一拍（测试专门断言）。

**Q：`busy` 期间再拉 `start` 会怎样？**
A：没反应。`ST_ALIGN`/`ST_READ`/`ST_WRITE` 三个分支里**根本没有 `start` 判断**，只有 `ST_IDLE` 才看 `start`，所以忙时 `start` 被忽略，事务不会被重启或污染（`test_start_ignored` 验证）。

**Q：事务中途想取消怎么办？**
A：只能 `reset`。异步复位立刻把 `state`、`busy`、`cpu_hold`、`cpu_read_req`、`ppu_reg_cs` 全拉低，`cycle_count`、`index_q` 归零（`test_reset_abort` 验证）。

**Q：`oam_cur_q` 会不会和 PPU 里的真实 OAMADDR 不一致？**
A：不会，**前提是两边同构**。真实的 `$2003` 写、`$2004` 自增、`FF->00` 回绕发生在 `nes_ppu2c02.v`；`oam_cur_q` 只是等价影子，供 `dbg_oam_addr` 观测（合同见 [`../modules/oam-dma.md`](../modules/oam-dma.md) 第 7 节）。

---

## 7. 你应该带走的三件事

1. **DMA 是总线主设备，不是 `memcpy`**：靠 `cpu_hold` 停住 CPU，靠 `cpu_read_req`/`cpu_read_ack` 一次一个字节抢总线，靠 `ppu_reg_*` 把字节写进 PPU。
2. **513/514 来自对齐相位，不是魔法**：`parity_q` 在 `start` 时决定 `align_left_q` 是 1 还是 2，那 1-2 个空转拍就是全部区别；`cycle_count` 用"最后一拍不加"停在 513/514。
3. **锁存是必需的**：`page_q`/`oam_base_q` 在 `start` 那拍拍下，之后 256 次读/写都用它们，源页和起始 OAM 地址都不会被后续变化污染。

下一篇 [`25-sd-spi-cmd.md`](25-sd-spi-cmd.md) 换一个完全不同的协议：把命令按位串行地发到 SD 卡上。
