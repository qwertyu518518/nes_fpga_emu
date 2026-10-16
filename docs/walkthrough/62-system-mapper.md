# 62 端到端系统精读：`nes_system_v5.v` 与 `nes_system_v6.v`

前面 [`60-system-early.md`](60-system-early.md) 和 [`61-system-mid.md`](61-system-mid.md) 看的是"最早能把 CPU 跑起来"的整机。这一篇看**最后两代 System 顶层**，它们各自只加了一件事：

- `nes_system_v5.v`：第一次把 **mapper（映射器）** 接进系统，让卡带 ROM 的 bank 切换真正生效。
- `nes_system_v6.v`：让 **PPU 用外部 CHR**，把 mapper 算出的 CHR 偏移补上最后一段读通路。

> **v5 把"CPU 读 PRG 的地址"这件事的所有权从顶层交给 mapper；v6 把"PPU 读 CHR 的地址"接上 mapper。**
> 两代顶层都**没有改 CPU、没有改 bus、没有改 mapper 本身**，全部增量都在顶层这几根线上。

本篇的主线是 **delta（增量）**：先讲 v5 的接线和它为什么这么接，再讲 v6 相对 v5 多了哪几条线、为什么不会形成组合环。读懂这两代，你就把"整机 + mapper"拼图拼完整了。

- 源码：[`rtl/nes_core/system/nes_system_v5.v`](../../rtl/nes_core/system/nes_system_v5.v)、[`rtl/nes_core/system/nes_system_v6.v`](../../rtl/nes_core/system/nes_system_v6.v)
- 合同与证据：[`../modules/system-v5.md`](../modules/system-v5.md)、[`../modules/system-v6.md`](../modules/system-v6.md)、[`../modules/ppu-external-chr.md`](../modules/ppu-external-chr.md) 第 11 节
- 测试目标：`system-v5`、`system-v6`、`system-v6-uxrom-prg`（见 [`../../tools/sim_all.ps1`](../../tools/sim_all.ps1)）

**前置**：读完 [`33-mapper-dispatch.md`](33-mapper-dispatch.md)（`nes_mapper` 的五个子模块怎么分发）和 [`51-ppu2c02.md`](51-ppu2c02.md)（PPU 的取数与 CHR 端口）再读本篇会更顺。

---

## 1. 先认识"上游和下游"

整机里有两条地址总线，mapper 正好夹在中间：

```text
CPU 侧（PRG）   6502 ── cpu_addr ──► nes_cpu_bus ── cart_addr ──► [系统顶层] ──► nes_mapper
                                                                     │              │
                                                                     │        prg_bank_offset（绝对字节偏移）
                                                                     │              │
                                                                     └──◄─ prg_rom[prg_bank_offset] ──► cart_din ──► CPU

PPU 侧（CHR）   PPU ── chr_addr（本地 8 KiB 窗口地址）──► [系统顶层] ──► nes_mapper
                  ▲                                              │         │
                  │                                        chr_final_addr ◄─ chr_bank_offset（绝对字节偏移）
                  └── chr_rdata ◄── 外部 CHR 存储器（在顶层之外）
```

- **CPU 侧**：6502 读 `$8000-$FFFF` 就是读卡带程序 ROM（PRG）。谁决定读哪个字节？**mapper**。
- **PPU 侧**：PPU 读图案表就是读图形 ROM（CHR）。v5 里 PPU 还在用**自己内部的 8 KiB CHR RAM**；v6 改成向**外部**要 CHR 字节，向谁要由 mapper 决定。
- mapper 的活儿始终是同一句：**把"CPU/PPU 看到的地址"翻译成"ROM 数组里的绝对字节偏移"**（回顾 [`10-mapper-nrom.md`](10-mapper-nrom.md)）。

v5 干的是左半边（PRG），v6 补的是右半边（CHR）。

---

## 2. 骨架代码（关键接线片段，长端口列表省略）

### 2.1 v5：PRG 读所有权交给 mapper

```verilog
reg [7:0] prg_rom [0:PRG_SIZE_BYTES-1];          // PRG ROM 就在顶层（v5）
wire [PRG_ADDR_BITS-1:0] prg_index;

assign prg_index    = mapper_prg_bank_offset;     // 索引直接来自 mapper
assign prg_readback = prg_rom[prg_index];         // bus conflict 用的读回字节
assign cart_din     = (cart_addr[15] == 1'b1) ? prg_rom[prg_index] : 8'h00;
```

```verilog
// mapper 的 CPU 写：只在"完成沿"发一拍脉冲（地址/数据是先寄存下来的）
always @(posedge clk or posedge reset) begin
    if (reset) begin
        cart_wr_pending_q <= 1'b0;
        cart_wr_addr_q    <= 16'h0000;
        cart_wr_data_q    <= 8'h00;
    end else begin
        cart_wr_pending_q <= cart_xfer && cart_we;
        cart_wr_addr_q    <= cart_addr;
        cart_wr_data_q    <= cart_dout;
    end
end

wire mapper_we      = cart_wr_pending_q;
wire [15:0] mapper_cpu_addr = cart_wr_pending_q ? cart_wr_addr_q : cart_addr;
wire [7:0]  mapper_cpu_dout = cart_wr_pending_q ? cart_wr_data_q : cart_dout;
```

### 2.2 v5：PPU 侧的 mapper 通道全部绑 0

```verilog
wire [13:0] mapper_ppu_addr = 14'h0000;   // PPU 地址不给 mapper 看
wire        mapper_ppu_we   = 1'b0;
wire [7:0]  mapper_ppu_dout = 8'h00;
wire        mapper_ppu_a12  = 1'b0;        // MMC3 的 A12 也绑 0
```

### 2.3 v6：PPU 改外部 CHR，mapper 的 PPU 通道接上真实 PPU 地址

```verilog
nes_ppu2c02 #(
    .MIRROR_VERTICAL(1'b0),
    .EXTERNAL_CHR(1'b1)          // 唯一的 delta：不再用内部 CHR RAM
) u_ppu (
    ...,
    .chr_waddr(ppu_chr_waddr),   // $2007 写的本地地址（递增前的 v_addr）
    .chr_req  (chr_req),         // 读请求（顶层输出）
    .chr_addr (ppu_chr_addr),    // 读的本地 CHR 地址
    .chr_we   (ppu_chr_we),      // $2007 写选通（单 clk 脉冲）
    .chr_wdata(ppu_chr_wdata),   // $2007 写数据
    .chr_rd_arm(ppu_chr_rd_arm), // $2007 CHR 读的请求臂
    .chr_rdata(chr_rdata)        // 顶层输入，直接进 PPU
);
```

```verilog
// mapper 的 CHR 地址来自 PPU 的本地 CHR 地址；写拍上只把 bit13 摆回写地址那位
wire [13:0] mapper_ppu_addr = {ppu_chr_we ? 1'b0 : ppu_chr_addr[13],
                               ppu_chr_addr[12:0]};
wire        mapper_ppu_we   = ppu_chr_we;
wire [7:0]  mapper_ppu_dout = ppu_chr_wdata;
wire        mapper_ppu_a12  = 1'b0;              // 仍然绑 0

assign chr_waddr      = ppu_chr_waddr;           // 写端口原样导出
assign chr_we         = ppu_chr_we;
assign chr_wdata      = ppu_chr_wdata;
assign chr_final_addr = mapper_chr_bank_offset;  // 最终 17 bit 地址 = mapper 的输出
```

---

## 3. 逐段精读

### 3.1 v5 的 delta：PRG 读地址的所有权交给 `nes_mapper`

v4 里顶层的写法是自己算窗口：`prg_index = cart_addr[PRG_INDEX_BITS-1:0]`。v5 把这一句换成：

```verilog
assign prg_index = mapper_prg_bank_offset;
```

请盯住 `prg_bank_offset` 这个名字：它是 **offset（偏移）**，不是 **bank（编号）**。mapper 内部已经把"bank base + 窗口内地址"这次加法做完了，顶层拿到的就是**可以直接拿去索引 ROM 数组的绝对字节偏移**。

以 NROM 为例（[`10-mapper-nrom.md`](10-mapper-nrom.md) 第 3.5 节）：`$8000 → $00000`、`$FFFF → $07FFF`。顶层若再自己加一次 `cart_addr`，地址就被折了两遍——v5 **明确没有**这么接。这就是"所有权移交"的含义：**顶层对 bank 完全无感，只知道偏移能拿去索引。**

### 3.2 v5 的 delta：mapper 写只在"完成沿"发一拍脉冲

CPU 往 `$8000-$FFFF` 写，就是给 mapper 寄存器写值（换 bank）。但总线上的 `cart_we` 是**请求级**的，一次写可能在等待拍和完成拍各出现一次。如果直接把它接给 mapper，一次写会被锁存两次。

所以 v5 先寄存：

```verilog
cart_wr_pending_q <= cart_xfer && cart_we;   // 只有"传输完成"那一拍才为 1
```

然后：

- `mapper_we = cart_wr_pending_q` —— 一个**恰好 1 个 `clk` 宽**的写脉冲；
- `mapper_cpu_addr` / `mapper_cpu_dout` 用两选一 mux —— 脉冲那一拍用**寄存下来的地址/数据**（因为 `cart_addr` 可能已经指向下一个请求），其余拍用实时 `cart_addr`，这样 mapper 的读译码任何一拍都拿得到正确地址。

> **为什么推迟一拍而不是同一拍？** `nes_cpu_bus` 的读数据是组合的，CPU 在完成沿上更新寄存器。把 mapper 写使能放在完成沿当拍，就等于让"这次写"和"这次读"在同一拍里既竞争又互相可见。推迟一拍把两件事彻底分开。

### 3.3 v5 的 delta：`bus conflict` 用 `prg_readback`

有些卡带（UxROM/CNROM）的写入会与 ROM 输出**竞争同一根数据线（bus conflict）**：实际写进寄存器的值等于"CPU 想写的值"按位与"ROM 在该地址呈现的字节"。所以 mapper 需要知道"这一刻 ROM 上是什么字节"：

```verilog
assign prg_readback = prg_rom[prg_index];
```

这个 `prg_readback` 送进 `nes_mapper`，供 UxROM/CNROM 做冲突判定。注意 `prg_readback` 和 `cart_din` **读的是同一个字**（同一个地址、同一个 bank）——这是有意的：比较用的字节必须就是 CPU 真正会看到的字节，否则会出现断言看不见的缺陷。

### 3.4 v5 的 delta：`CPU irq_i = mapper_irq | apu_irq`

`nes_cpu6502` 的中断线只有一根，且是**电平判定**。APU 和 mapper 都可能拉中断，所以必须在进 CPU 之前**或**起来：

```verilog
assign irq_line = mapper_irq | apu_irq;
...
nes_cpu6502 u_cpu ( ..., .irq_i(irq_line), ... );
assign apu_irq_o = apu_irq;      // 观测端口仍然只给 APU 自己的 irq
```

- mapper IRQ 极性是"高 = 有效"，与 CPU 的 `irq_i` 一致，中间不取反。
- `apu_irq_o` 保持旧语义（只看 APU），新增的 `irq_line` 才是真正进 CPU 的那根。TB 逐拍断言 `irq_line == (mapper_irq | apu_irq)`。

### 3.5 v5 的 delta：`MAPPER_SELECT` 是 elaboration 期参数

顶层参数 `MAPPER_SELECT`（默认 `8'd0`）原样传给 `nes_mapper` 的 `.mapper_select(...)`：

```verilog
nes_mapper #( ..., ) u_mapper ( ..., .mapper_select(MAPPER_SELECT), ... );
```

`nes_mapper` 用它在顶层做**组合分发**（[`33-mapper-dispatch.md`](33-mapper-dispatch.md) 第 3 节）：五个子 mapper 同时例化，只有被选中的那个把输出接到出口。

**关键点**：`MAPPER_SELECT` 是 `parameter`，在**综合/elaborate 时**就固定了。一个 `nes_system_v5` 实例整场仿真/上板只有一个 mapper，**要换 mapper 得重新综合**。这和软件模拟器"每个 ROM 选一次 `mapper_num`"行为一致，与"运行时可切换"无关。

### 3.6 v5 里 PPU 还是内部 8 KiB CHR RAM

v5 **一个字都没动 PPU**：`nes_ppu2c02 #(.MIRROR_VERTICAL(1'b0))`，没有 `EXTERNAL_CHR`，所以 PPU 仍用自己的内部 `chr_ram`。同时顶层把 mapper 的三条 PPU 观察通道全绑 0（见 2.2）：

- `chr_bank_offset` 恒等于以 `ppu_addr` 为输入的常量，**没有任何 CHR bank 切换**；
- `ppu_a12 = 0` 让 MMC3 的扫描线 IRQ 计数器**永远不被时钟**（MMC3 只在 A12 沿时更新计数器）；
- mirroring 的 `mapper_mirroring` / `mapper_nametable_map` 虽然引到了顶层端口，但**没有进 PPU**——因为 `nes_ppu2c02` 的镜像只有一个**编译期参数** `MIRROR_VERTICAL`，没有运行期端口。v5 不去"假装接上"。

### 3.7 v6 的 delta：PPU 改 `.EXTERNAL_CHR(1'b1)`

v6 相对 v5 的核心改动只有一处参数：

```verilog
nes_ppu2c02 #( .MIRROR_VERTICAL(1'b0), .EXTERNAL_CHR(1'b1) ) u_ppu ( ... );
```

`EXTERNAL_CHR=1` 让 PPU **不再取自己内部的 CHR**，而是走外部 CHR 端口。于是 PPU 上原本就有的三根线有了真实信号：`chr_req`（要字节）、`chr_addr`（要哪个本地地址）、`chr_rdata`（拿回来的字节）。顶层新增端口把这条通路接出去：

| 方向 | 端口 | 含义 |
|---|---|---|
| in | `chr_rdata[7:0]` | 外部 CHR 存储器上一拍给出的字节（直接进 PPU） |
| out | `chr_req` | PPU 请求一个外部 CHR 字节（**无背压、无应答**） |
| out | `chr_final_addr` | mapper 映射后的**最终** CHR 字节地址（默认 17 bit） |

### 3.8 v6 的 delta：`mapper_ppu_addr` 由 PPU 本地 CHR 地址驱动

v5 那根恒 0 的 `mapper_ppu_addr` 现在接上 PPU 的本地 CHR 地址：

```verilog
wire [13:0] mapper_ppu_addr = {ppu_chr_we ? 1'b0 : ppu_chr_addr[13],
                               ppu_chr_addr[12:0]};
```

两句人话：

1. **读地址 `ppu_chr_addr[12:0]` 完全无遮挡地送进 mapper**，mapper 据此算出带 bank 的最终偏移。
2. **写拍（`ppu_chr_we=1`）上只把 `bit13` 换成写地址那一位**，而写地址的 `bit13` **结构上恒 0**。为什么单留这一位？因为 `nes_mapper` 的 `chr_ram_we` 门控要看 `ppu_addr[13] == 0`；把写地址那一位放回去，`chr_ram_we` 才与改动前逐位相同。这不是仲裁，只是让写门控保持一致。

### 3.9 v6 的 delta：`chr_final_addr = mapper_chr_bank_offset`（前馈、无组合环）

```verilog
assign chr_final_addr = mapper_chr_bank_offset;
```

**PPU 发的是"本地 8 KiB 窗口里的地址"，mapper 发的是"CHR 空间里的绝对字节偏移"，最终地址就是后者本身。** PPU 在 mapper 之后**不再加任何东西**。

这是本设计最容易踩的坑，值得单独记：

```text
路径 A（会成环）：chr_addr ──► mapper ──► chr_bank_offset ──► 又接回 chr_addr
路径 B（安全）：  chr_addr ──► mapper ──► chr_bank_offset ──► chr_final_addr（输出端口，无人读回）
```

- mapper 的输入是 PPU 的 `chr_addr` 与 `chr_rdata` 是**输入端口**、只到寄存器、**不参与地址计算**；`chr_final_addr` 是**输出端口**，没有任何模块读它。
- 两条都没有把 mapper 的输出接回 PPU 的输入 → **不存在组合环**。这是一条**前馈（feed-forward）**通路。
- 反例（**错误写法**）：`assign chr_final_addr = ppu_chr_addr + mapper_chr_bank_offset;` 看起来自然，其实地址被**折了两遍**，而且立刻成环。

### 3.10 v6 的地址合同：本地 8 KiB / 13 bit，pattern-table 选择是 bit 12

pattern 字节地址在 PPU 内部是：

```text
{table, tile[7:0], plane, fine_y[2:0]}   =  $0000 .. $1FFF   （13 bit）
```

- 本地 CHR 窗口是 **8 KiB = 13 bit**；**pattern-table 选择落在 bit 12**（背景是 `PPUCTRL[4]`，精灵是 `PPUCTRL[5]`），**不是**第二个 8 KiB bank。
- `chr_addr` 端口虽然声明成 14 bit，但 **`bit13` 结构上恒 0**（地址本身只有 13 bit），所以每个 mapper 丢掉 `ppu_addr[13]` **完全无害**，而它们各自把 **bit12** 当窗口选择。
- 8 KiB 的 CHR 存储器用 `chr_final_addr[12:0]` 索引，因为地址**永远不超过 `0x1FFF`**，这次截断**不产生镜像、不产生回绕**。
- `chr_final_addr` 默认 17 bit（128 KiB）：刚好够 MMC1，但会**截断 MMC3 CHR bank 的 bit7**，导致 bank `0x80-0xFF` 别名到 `0x00-0x7F`。这是**已知、已接受**的限制（同 [`33-mapper-dispatch.md`](33-mapper-dispatch.md) 第 3.7 节）。

### 3.11 v6 仍未做（边界）

与 v5 一样，v6 也有明确边界，别把它当成"完整卡带"：

- **片上没有 CHR 存储**。`nes_system_v6` 只导出地址/选通/请求，**不含任何 CHR 阵列**；CHR 存储器在顶层之外（板级），且**必须自己观察** `chr_waddr` / `chr_we` / `chr_wdata`（写）并在每个 `ce` 寄存 `chr_rdata`（读）。
- **写/读与取数的碰撞抑制仍未修**。PPU 取数流水是"每 8 个 `ce` 一个 tile、零余量"的，渲染期间 `$2007` 写 CHR 会抢占同一根 CHR 读地址链——这条碰撞的抑制仍未做（`ppu-external-chr.md` 第 11.3.2 节）。
- **mirroring 仍只有编译期参数**。`nes_ppu2c02` 依旧只有 `MIRROR_VERTICAL`，mapper 运行期输出的 mirroring 仍**没有进 PPU**。
- **`ppu_a12` 仍绑 0**。MMC3 的扫描线 IRQ 在系统级仍无法自时钟。
- `chr_req` 上没有 `ready/ack` 握手，所以这套端口**不能直接接 SDRAM**（真实 SDRAM 有 CAS/刷新延迟）。

### 3.12 v6 的一个附带 delta：PRG 从内部数组搬到 `nes_cart_rom`

v5 的 `prg_rom` 是顶层里的一块 `reg` 数组。v6 把它移进 `nes_cart_rom` 实例（`CHR_ENABLE=0`，只建 PRG 半边）：

```verilog
nes_cart_rom #( .PRG_SIZE_BYTES(...), .PRG_ADDR_BITS(...),
                .PRG_ENABLE(1), .CHR_ENABLE(0), .PRG_INIT_FILE(...) ) u_prg_rom (
    .prg_addr(mapper_prg_bank_offset), .prg_rdata(prg_rdata), ... );

assign prg_readback = prg_rdata;
assign cart_din     = (cart_addr[15] == 1'b1) ? prg_rdata : 8'h00;
```

`nes_cart_rom` 的读是**寄存的一拍延迟**（[`32-cart-rom.md`](32-cart-rom.md)），但因为 `mapper_prg_bank_offset` 在 CPU 整个 12 拍窗口里是稳定的，这一拍延迟拿到的仍是**正确的字节**。`nes_mapper` 依旧一个字节没改。

---

## 4. 端口表（标注版本）

只列与 mapper / CHR 相关的部分；`clk`/`reset`/`pixel_*`/`audio_*`/`bus_*` 等与 v4 相同。

| 端口 | 方向 | 位宽 | v5 | v6 | 含义 |
|---|---|---|---|---|---|
| `mapper_select`(参数) | — | 8 | 有 | 有 | 型号号：0=NROM、1=MMC1、2=UxROM、3=CNROM、4=MMC3。**elaboration 期固定** |
| `mapper_prg_bank_offset` | out | `PRG_ADDR_BITS` | 有 | 有 | PRG 绝对字节偏移（来自 mapper） |
| `prg_readback` | out | 8 | 有 | 有 | 当前 PRG 读值，供 bus conflict |
| `mapper_chr_bank_offset` | out | `CHR_ADDR_BITS`(17) | 有（**未接 PPU**） | 有（= `chr_final_addr`） | CHR 绝对字节偏移（来自 mapper） |
| `mapper_mirroring`/`mapper_nametable_map` | out | 3 / 8 | 有 | 有 | 镜像模式与索引表（**仍没进 PPU**） |
| `mapper_irq` / `irq_line` | out | 1 | 有 | 有 | mapper IRQ；`irq_line = mapper_irq \| apu_irq` |
| `mapper_write_pulse`/`_addr`/`_data` | out | 1/16/8 | 有 | 有 | mapper 写脉冲（完成沿，1 拍）与它那拍寄存的地址/数据 |
| `chr_rdata` | in | 8 | **无** | 有 | 上拍的最终 CHR 地址对应的字节 |
| `chr_req` | out | 1 | **无** | 有 | PPU 请求 CHR 字节（无背压） |
| `chr_final_addr` | out | `CHR_ADDR_BITS`(17) | **无** | 有 | `= mapper_chr_bank_offset`（映射后的最终地址） |
| `chr_waddr` | out | 14 | **无** | 有 | `$2007` 写的本地地址（递增前 `v_addr[13:0]`，仅 `chr_we` 高时有效） |
| `chr_we` | out | 1 | **无** | 有 | `$2007` 写外部 CHR 的**单 clk 选通** |
| `chr_wdata` | out | 8 | **无** | 有 | `$2007` 写进去的那个字节 |

---

## 5. 走一遍

### 5.1 一次 `$2007` 写 CHR（v6 的通路）

假设 CPU 执行 `STA $2007`，写数据为 `D`，且 PPU 内部 `v_addr < $2000`：

1. **CPU 写周期**：数据经 `nes_cpu_bus` 译码成 PPU 寄存器访问，`ppu_port_cs/we/addr=3'd7/din=D` 送到 PPU。
2. **PPU 内部**（外部 CHR 分支）拉出写端口：`chr_we = 1`（恰好一拍）、`chr_waddr = 递增前的 v_addr[13:0]`、`chr_wdata = D`。
3. **顶层导出**：`chr_waddr/chr_we/chr_wdata` 原样出现在顶层输出上（**顶层不含存储**）。
4. **mapper 侧**：`mapper_ppu_we = chr_we`、`mapper_ppu_dout = chr_wdata`；`mapper_ppu_addr` 在写拍上把 `bit13` 摆成写地址那一位（恒 0），低 13 位是**读**地址。mapper 据此组合出 `mapper_chr_ram_we = chr_ram_enable && ppu_we && (ppu_addr[13]==0)`。
5. **是否真的写**：由 `mapper_chr_ram_we` 决定——**CHR-RAM 板**才可能为高，**CHR-ROM 板**恒低（写被挡住）。下游的 CHR 存储器用 `chr_waddr/chr_we/chr_wdata` 落一个字节。
6. **读侧同步**：`chr_final_addr = mapper_chr_bank_offset` 一直有效；PPU 取数时 `chr_req` 拉高，外部存储器在**下一个 `ce`** 把该地址（低 13 位）的字节放上 `chr_rdata`，PPU 锁存。

### 5.2 一次 PRG bank 切换（UxROM）

假设 CPU 执行 `STA $8000`，写数据为 `B` 想换 PRG bank：

1. **总线**：这是落在 `$8000-$FFFF` 的卡带**写**，产生 `cart_xfer && cart_we`。
2. **完成沿寄存**：`cart_wr_pending_q` 在完成拍变 1，同时把 `cart_addr`/`cart_dout` 存进 `cart_wr_addr_q`/`cart_wr_data_q`。
3. **下一拍发脉冲**：`mapper_we = 1`（1 拍），`mapper_cpu_addr = cart_wr_addr_q`、`mapper_cpu_dout = cart_wr_data_q`。
4. **mapper 内部**：`mapper_write = cpu_we && cpu_addr[15]` → `we_uxrom = mapper_write && select_uxrom` → UxROM 锁存 `bank_select`（并按 `prg_readback` 做 bus conflict）。
5. **偏移改变**：`prg_bank_offset` 随 `bank_select` 改变 → `prg_index` 改变 → `prg_rom[prg_index]`（v6 里是 `prg_rdata`）改变 → 之后读 `$8000` 就落在新 bank 上。

> TB（`tb_nes_system_v5.v`）用一个**独立于 DUT 的 bank 模型**逐次比对 `prg_bank_offset`，就是为了把 3.1 那条"偏移已算好、顶层不再加"的语义钉死。

---

## 6. 常见疑问

**Q：`prg_bank_offset` 到底是 bank 号还是偏移？**
A：**绝对字节偏移**。名字里的 "offset" 就是提醒你：换 bank 的乘法/加法已经在 mapper 内部做完了，顶层直接 `prg_rom[prg_bank_offset]` 即可。顶层若再自己加 `cart_addr`，地址会折两遍。

**Q：为什么 mapper 写要推迟一拍？**
A：因为 `cart_we` 是请求级的，且总线读数据是组合的。推迟到完成沿之后，让"写"与"读"彻底分开，避免同拍竞争。代价是脉冲那拍 `cart_din` 是拿"上次写地址"算的，但那个值没有任何采样者（下一次 `bus_fire` 最早在下一个 `ce`）。

**Q：`chr_addr` 是 14 bit，为什么说本地窗口只有 13 bit？**
A：地址本身只有 13 bit（`$0000-$1FFF`），端口多出来的 `bit13` **结构上恒 0**。所以 mapper 丢 `ppu_addr[13]` 无损，pattern-table 选择在 **bit12**。

**Q：`chr_final_addr` 为什么不是 `ppu_addr + chr_bank_offset`？**
A：那样地址被折两遍，而且 mapper 的输出会接回 PPU 输入，**形成组合环**。正确写法是 `chr_final_addr = mapper_chr_bank_offset`（前馈，PPU 不再加任何东西）。

**Q：v6 把 `chr_waddr`/`chr_we`/`chr_wdata` 也导出，可以不用吗？**
A：必须用。`nes_system_v6` **不含 CHR 存储**，下游存储器只能靠这三个信号自己落字节。`chr_we` 不登记，必须按**单拍脉冲**用。

**Q：`MAPPER_SELECT` 能运行期切换吗？**
A：不能。它是 `parameter`，elaboration 期固定；换 mapper 要重新综合。这与软件"每个 ROM 选一次"一致。

**Q：v6 能用 MMC3 的 CHR banking 吗？**
A：能切换到 128 KiB 以内，但 **CHR bank `0x80-0xFF` 会别名**到 `0x00-0x7F`（17 bit 截断 bit7）。这是已知、已接受的限制。

---

## 7. 你应该带走的三件事

1. **所有权移交 = 只接结果，不再自己算**。v5 的 `prg_index = mapper_prg_bank_offset`、v6 的 `chr_final_addr = mapper_chr_bank_offset`，都是"顶层不做 bank 运算、只拿 mapper 算好的**绝对偏移**索引存储"。
2. **接口的时序纪律必须显式写出来**：mapper 写只在完成沿发 **1 拍脉冲**（`cart_wr_pending_q`）；`chr_we` 是**单 clk 选通**、`chr_req` **无背压**。这些不是注释，是下游必须满足的合同。
3. **前馈不是环**：`chr_addr → mapper → chr_bank_offset → chr_final_addr` 单向到输出端口，没有任何东西读回，所以**不成环**；写成"PPU 再加一次偏移"就同时错地址又成环。

下一篇 [`63-ep4ce10-top.md`](63-ep4ce10-top.md) 把整机搬到真实板子上：看顶层怎么接 VGA、TF、SDRAM 与 WM8978，以及跨时钟域与引脚约束怎么做。
