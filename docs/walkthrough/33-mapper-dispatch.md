# 33 mapper 顶层：`nes_mapper.v` 组合分发 + 子模块例化

前面 [`10-mapper-nrom.md`](10-mapper-nrom.md) 和 [`13-mapper-cnrom-uxrom.md`](13-mapper-cnrom-uxrom.md) 精读的是**单个** mapper。这一篇看它们的**总机**：`rtl/nes_core/mapper/nes_mapper.v`。

> **卡带有 5 种 mapper，用一根 `mapper_select` 号线挑一个，把它的输出接到整机；其余 4 个虽然也在跑，但不许说话。**

这就是"分发（dispatch）"：软件里靠函数指针表，硬件里靠**组合译码 + 多路选择（mux）**。这一层本篇彻底拆开。

- 源码：[`rtl/nes_core/mapper/nes_mapper.v`](../../rtl/nes_core/mapper/nes_mapper.v)
- 合同与证据：[`../modules/mappers.md`](../modules/mappers.md) 第 1、2、3.1 节
- 子模块精读：NROM → [`10-mapper-nrom.md`](10-mapper-nrom.md)，CNROM/UxROM → [`13-mapper-cnrom-uxrom.md`](13-mapper-cnrom-uxrom.md)
- 测试目标：`mapper-combined`（源码 [`tb/mapper/tb_nes_mapper.v`](../../tb/mapper/tb_nes_mapper.v)）

---

## 1. 先认识"上游和下游"

单个 mapper 只有三个观察面（CPU、PPU、卡带回读）。顶层把这些面**原样转给五个子模块**，再在出口处按型号选一个：

```text
mapper_select ─(0..4)┐
CPU  bus  cpu_addr / cpu_we / cpu_dout ─┐
PPU  bus  ppu_addr / ppu_we / ppu_dout / ppu_a12 ─┼─► [ nes_mapper 顶层 ]
卡带回读  prg_readback ─────────────────┘        │
                                       ┌─────────┴─────────┐
                                 组合分发 select_*/we_*   5 个子 mapper 同时例化
                                       └────► mux(if/else) ◄┘
                                                  │
   prg_bank_offset / chr_bank_offset / mirroring / nametable_map
   prg_ram_enable / prg_ram_we / chr_ram_enable / chr_ram_we
   irq / bus_conflict / dbg_* / mmc1_* / mmc3_*  ──► 整机
```

两个关键设计（后面逐段讲）：**五个子模块同时例化**（换 ROM 只改 `mapper_select`，不用重新综合，`mappers.md` 第 3.1 节）；**每个子模块的写使能都和 `select_*` 与过**，所以同一个 `$8000` 上的写不会串到别人的寄存器（TB 的 `test_select_isolation` 覆盖）。

---

## 2. 全文（分段，长例化省略）

### 2.1 文件头注释：`CHR_ADDR_BITS = 17` 的取舍

文件最上面那段注释就是本模块最需要解释的一个"决定"：

```verilog
// 17 bits = 128 KiB, which is exactly what MMC1 needs: its 5-bit 4 KiB bank
// reaches 0x1F000 and the 4 KiB intra-window offset adds at most 0xFFF, giving
// 0x1FFFF. Do not lower it below 17 or MMC1 bank >= 16 aliases back into low 64 KiB.
// 17 is NOT enough for MMC3. ... a window above 0x7F needs address bit 17 ...
// At 17 bits that bit is shifted out and MMC3 CHR banks 0x80-0xFF alias onto 0x00-0x7F.
// This is a known, accepted limitation at the current width.
```

翻成人话：**17 位"刚好够 MMC1、但对 MMC3 差一位"**。够不够、差哪一位，见第 3.7 节。

### 2.2 参数与端口（`nes_mapper.v:14-78`）

```verilog
module nes_mapper #(
    parameter integer PRG_ADDR_BITS = 17,
    parameter integer CHR_ADDR_BITS = 17,
    parameter integer PRG_SIZE_BYTES = 131072,   // 整卡 PRG 字节数
    parameter [2:0] HEADER_MIRRORING = 3'd0,
    parameter integer UxROM_BANK_BITS = 4,
    parameter integer CNROM_BANK_BITS = 2,
    parameter [1:0] UxROM_BUS_CONFLICT = 2'd1,
    parameter [1:0] CNROM_BUS_CONFLICT = 2'd1,
    parameter [1:0] MMC3_A12_EDGE = 2'd0,
    parameter integer MMC3_A12_COOLDOWN = 2,
    parameter integer NROM_PRG_SIZE_BYTES = 32768,
    parameter NROM_PRG_RAM = 1'b0,
    parameter NROM_CHR_RAM = 1'b0,
    parameter MMC1_CHR_RAM = 1'b0,
    parameter MMC3_CHR_RAM = 1'b0
)(
    input  wire        clk, reset,
    input  wire [7:0]  mapper_select,
    input  wire [15:0] cpu_addr,
    input  wire        cpu_we,
    input  wire [7:0]  cpu_dout,
    input  wire [13:0] ppu_addr,
    input  wire        ppu_we,
    input  wire [7:0]  ppu_dout,
    input  wire        ppu_a12,
    input  wire [7:0]  prg_readback,
    output wire [PRG_ADDR_BITS-1:0] prg_bank_offset,
    output wire [CHR_ADDR_BITS-1:0] chr_bank_offset,
    output wire [2:0]  mirroring,
    output wire [7:0]  nametable_map,
    output wire        prg_ram_enable, prg_ram_we, chr_ram_enable, chr_ram_we,
    output wire        irq, bus_conflict,
    output wire [7:0]  dbg_prg_bank_number, dbg_chr_bank_number,
    output wire [2:0]  dbg_mapper_id,
    // mmc1_* / mmc3_* 观测端口略，见第 4 节端口表
);
```

这些 `parameter` 不参与这里的逻辑，只是"往下传给五个子模块"的配置（如 `UxROM_BANK_BITS` 给 UxROM、`MMC3_A12_EDGE` 给 MMC3），在 2.7 的例化处转发。

### 2.3 组合分发：`select_*`、`mapper_write`、`we_*`

```verilog
assign select_nrom  = (mapper_select == 8'd0);
assign select_mmc1  = (mapper_select == 8'd1);
assign select_uxrom = (mapper_select == 8'd2);
assign select_cnrom = (mapper_select == 8'd3);
assign select_mmc3  = (mapper_select == 8'd4);

assign mapper_write = cpu_we && cpu_addr[15];

assign we_mmc1  = mapper_write && select_mmc1;
assign we_uxrom = mapper_write && select_uxrom;
assign we_cnrom = mapper_write && select_cnrom;
assign we_mmc3  = mapper_write && select_mmc3;
```

（内部还声明了每个子模块输出的中间 `wire`，如 `prg_offset_nrom`、`chr_offset_mmc1`、`mirroring_cnrom`、`irq_mmc3`、`bus_conflict_uxrom` 等，2.5 的选择电路把它们接到出口。）

### 2.4 `nametable_map_decode`：组合查表函数

```verilog
function [7:0] nametable_map_decode;
    input [2:0] mode;
    begin
        case (mode)
            3'd0: nametable_map_decode = 8'b01010000;
            3'd1: nametable_map_decode = 8'b01000100;
            3'd2: nametable_map_decode = 8'b00000000;
            3'd3: nametable_map_decode = 8'b01010101;
            default: nametable_map_decode = 8'b11100100;
        endcase
    end
endfunction
```

### 2.5 选择 mux：`always @*` 的 if/else 链（`nes_mapper.v:165-212`）

```verilog
always @* begin
    if (select_nrom) begin
        prg_bank_offset_r = prg_offset_nrom;   chr_bank_offset_r = chr_offset_nrom;
        mirroring_r       = mirroring_nrom;    prg_ram_enable_r  = prg_ram_nrom;
        chr_ram_enable_r  = chr_ram_nrom;      irq_r             = irq_nrom;
        bus_conflict_r    = 1'b0;              dbg_mapper_id_r   = 3'd0;
    end else if (select_mmc1) begin
        // ... 同样 8 行改成 mmc1 一套；dbg_mapper_id_r = 3'd1 ...
    end else if (select_uxrom) begin
        // ... uxrom 一套；bus_conflict_r = bus_conflict_uxrom；dbg_mapper_id_r = 3'd2 ...
    end else if (select_cnrom) begin
        // ... cnrom 一套；bus_conflict_r = bus_conflict_cnrom；dbg_mapper_id_r = 3'd3 ...
    end else begin   // 最后一个 else 兜底就是 MMC3
        prg_bank_offset_r = prg_offset_mmc3;   chr_bank_offset_r = chr_offset_mmc3;
        mirroring_r       = mirroring_mmc3;    prg_ram_enable_r  = prg_ram_mmc3;
        chr_ram_enable_r  = chr_ram_mmc3;      irq_r             = irq_mmc3;
        bus_conflict_r    = 1'b0;              dbg_mapper_id_r   = 3'd4;
    end
end
```

### 2.6 输出拼接、RAM 写使能与调试端口（`nes_mapper.v:214-226`）

```verilog
assign prg_bank_offset = prg_bank_offset_r;
assign chr_bank_offset = chr_bank_offset_r;
assign mirroring       = mirroring_r;
assign nametable_map   = nametable_map_decode(mirroring_r);
assign prg_ram_enable  = prg_ram_enable_r;
assign prg_ram_we      = prg_ram_enable_r && cpu_we && (cpu_addr[15:13] == 3'b011);
assign chr_ram_enable  = chr_ram_enable_r;
assign chr_ram_we      = chr_ram_enable_r && ppu_we && (ppu_addr[13] == 1'b0);
assign irq             = irq_r;
assign bus_conflict    = bus_conflict_r;
assign dbg_prg_bank_number = prg_bank_offset_r[PRG_ADDR_BITS-1:13];
assign dbg_chr_bank_number = chr_bank_offset_r[CHR_ADDR_BITS-1:10];
assign dbg_mapper_id       = dbg_mapper_id_r;
```

### 2.7 五个子模块例化（`nes_mapper.v:228-354`，长例化省略）

五个 mapper **全部**例化（`u_nrom` / `u_mmc1` / `u_uxrom` / `u_cnrom` / `u_mmc3`），命名连接方式一致，以最短的 `u_nrom` 为例：

```verilog
nes_mapper_nrom #(
    .PRG_ADDR_BITS(PRG_ADDR_BITS),   .CHR_ADDR_BITS(CHR_ADDR_BITS),
    .PRG_SIZE_BYTES(NROM_PRG_SIZE_BYTES), .HEADER_MIRRORING(HEADER_MIRRORING),
    .NROM_PRG_RAM(NROM_PRG_RAM),     .NROM_CHR_RAM(NROM_CHR_RAM)
) u_nrom (
    .cpu_addr(cpu_addr), .ppu_addr(ppu_addr),
    .prg_bank_offset(prg_offset_nrom), .chr_bank_offset(chr_offset_nrom),
    .mirroring(mirroring_nrom), .prg_ram_enable(prg_ram_nrom),
    .chr_ram_enable(chr_ram_nrom), .irq(irq_nrom)
);
```

四个有状态的子模块连接**和 NROM 不同的两点**：写使能接的是**门控后**的信号 `.cpu_we(we_mmc1/uxrom/cnrom/mmc3)`（NROM 没有 `cpu_we` 端口）；各自多接专属端口（UxROM/CNROM 接 `.prg_readback/.bus_conflict`，MMC1 接 `.clk/.reset` 并直通 `mmc1_*`，MMC3 接 `.ppu_a12` 并直通 `mmc3_*`）。

---

## 3. 逐段精读

### 3.1 `select_*`：一行一个"型号开关"

`mapper_select` 是 8 位型号号，5 行 `assign` 把它和 0..4 逐一比较，产生 5 根 **one-hot**（最多一根为高）的开关线。它们是**纯组合**：`mapper_select` 一变，开关立刻变。型号对应 iNES 头的 mapper 编号（`mappers.md` 第 2.1 节）：

| `mapper_select` | 0 | 1 | 2 | 3 | 4 |
|---|---|---|---|---|---|
| 型号 | NROM | MMC1 | UxROM | CNROM | MMC3 |
| 开关线 | `select_nrom` | `select_mmc1` | `select_uxrom` | `select_cnrom` | `select_mmc3` |

### 3.2 `mapper_write = cpu_we && cpu_addr[15]`：只在 CPU 写 PRG 窗口时有效

读法：**这一拍是 CPU 写周期（`cpu_we=1`），且地址最高位 `cpu_addr[15]=1`**（即落在 `$8000-$FFFF`，mapper 寄存器窗口）。两个条件同时成立才叫"一次 mapper 写"。再和 `select_*` 与一下得到写脉冲：

```verilog
assign we_mmc1 = mapper_write && select_mmc1;
```

这就是"写隔离"：后台有别的 mapper 寄存器，也**只有被选中的那个**收到写脉冲（`test_select_isolation` 测的就是它）。NROM 没有寄存器，所以没有 `we_nrom`。

### 3.3 `nametable_map_decode`：为什么用 function 查表

`mirroring_r` 只有 3 位（0=横、1=竖、2=单低、3=单高）。PPU 想要的是 4 个物理 nametable 的**索引表**，编码成 8 位 `{NT3,NT2,NT1,NT0}`（每项 2 bit）：

| `mode` | 0 | 1 | 2 | 3 | 其它 |
|---|---|---|---|---|---|
| 模式 | horizontal | vertical | single lower | single upper | four screen |
| `nametable_map` | `8'b01010000` | `8'b01000100` | `8'b00000000` | `8'b01010101` | `8'b11100100` |

**为什么用 `function` 而不是在顶层写 `case`？** 因为这是"输入模式、输出常量表"的**纯组合查表**；写成 function 后，2.6 节只需一行 `nametable_map_decode(mirroring_r)` 调用即可。function 在综合时被**内联展开**成组合逻辑（与 `case` 等价），不产生硬件层次。好处是"5 种模式的编码"只出现一次，PPU 侧只读 4 个 2 bit 常量，不必为每种镜像重建 nametable RAM（`mappers.md` 第 2.2 节）。

### 3.4 `always @*` 的 if/else 链：五个只有一个能到出口

这是本模块的核心。`prg_bank_offset_r`、`chr_bank_offset_r` 等**不是**真寄存器——名字带 `_r`、写在 `always` 块里，但这里是 `always @*`（组合块），所以它们只是"被 `=` 赋值的中间线"（`02` 篇第 5 节）。

读法：一条 `if / else if / else` 链，**从上往下第一个成立的分支赢**；每个分支把 8 个出口变量一次性赋成**该型号的一套值**；5 个型号一一对应 5 个分支，最后一个 `else` 没写 `select_mmc3`，它**兜底就是 MMC3**。

因为 `select_*` 是 one-hot，正常情况下每拍恰有一个分支成立，于是"五个子模块的输出里只有一个(被选中的)能传到出口"。**五个子模块都在运行**（寄存器随时钟更新、输出随时变化），但只有一根被放行——这就是组合 mux。

> 提醒：`always @*` 里每个出口变量在**所有分支**都被赋值，所以不会推断出 latch（`01` 篇第 16 节第 1 条）。若漏赋某支，就会出现"要记住旧值"的隐藏锁存器。

### 3.5 `chr_ram_we` / `prg_ram_we`：出口处的组合门控

顶层不只转发 `enable`，还顺手把**写使能**算好：

```verilog
assign prg_ram_we = prg_ram_enable_r && cpu_we && (cpu_addr[15:13] == 3'b011);
assign chr_ram_we = chr_ram_enable_r && ppu_we && (ppu_addr[13] == 1'b0);
```

- `prg_ram_we`：这张卡**确实有 PRG RAM**、**是 CPU 写周期**、**地址在 `$6000-$7FFF`**（`cpu_addr[15:13]==3'b011`）。三者同时成立才可写。
- `chr_ram_we`：这张卡**确实可写 CHR**（CHR RAM 板子）、**是 PPU 写 `$2007`**、**地址在图案表区 `$0000-$1FFF`**（`ppu_addr[13]==0`）。

关键点：**"有没有 RAM"（`*_ram_enable`）和"这一拍写不写"（`*_ram_we`）是分开的两件事**。前者由型号/参数决定，后者再叠加总线方向与地址译码；上层 memory owner 只看 `*_ram_we` 决定这一拍要不要落一个字节。

### 3.6 `dbg_*`：把偏移"换算成 bank 号"

```verilog
assign dbg_prg_bank_number = prg_bank_offset_r[PRG_ADDR_BITS-1:13];  // 除以 8192 -> 8 KiB bank
assign dbg_chr_bank_number = chr_bank_offset_r[CHR_ADDR_BITS-1:10];  // 除以 1024 -> 1 KiB bank
```

`prg_bank_offset_r` 是**字节偏移**，取 `[16:13]`（去掉低 13 位）就是 8 KiB bank 号（4 位 → 0..15）；`chr_bank_offset_r[16:10]` 是 1 KiB bank 号。它们只是**只读观测**（`02` 篇第 7 节），给 TB 一个"人话视图"，出错时能分清"bank 选错了"还是"ROM 内容错了"。`dbg_mapper_id` 同理，由 3.4 的 mux 直接写上型号号 0..4。

### 3.7 `CHR_ADDR_BITS = 17`：刚好够 MMC1，对 MMC3 差一位

- **为什么至少 17**：MMC1 的 CHR 是 5 位、4 KiB 粒度的 bank（`nes_mapper_mmc1.v`：`chr_bank_ext << 12`）。最大 bank 号 `0x1F`，`0x1F << 12 = 0x1F000`，加窗口内最多 `0xFFF` → `0x1FFFF`，正好需要 17 位（2^17 = 128 KiB）。**低到 16 位，bank ≥ 16 就会绕回低 64 KiB**，所以不能降。
- **为什么 17 又不够 MMC3**：`nes_mapper_mmc3.v` 用 8 位 CHR bank 寄存器、1 KiB 粒度（`chr_bank_offset = (chr_window_ext << 10) | ppu_addr[9:0]`）。当 R 寄存器 **bit7=1**（bank ≥ `0x80`）时 `0x80 << 10 = 0x20000`，这位正好落在**地址 bit17**；而输出只有 17 位，写不下 bit17，于是被**移出**，MMC3 的 CHR bank `0x80-0xFF` **别名**到 `0x00-0x7F`。

这个别名是**有意接受**的限制：消除它得把宽度加到 18 位，但多数游戏用不到那么大的 CHR bank。注释与文档都把它记成"已知、接受的截断"而非 bug。**这正是 `02` 篇第 6 节"看到位宽不匹配先怀疑是否有意截断"的真实例子。**

---

## 4. 端口表（输入 / 输出合并）

| 端口 | 方向 | 位宽 | 含义 |
|---|---|---|---|
| `clk` / `reset` | in | 1 | 只被有寄存器的子模块（MMC1/UxROM/CNROM/MMC3）使用 |
| `mapper_select` | in | 8 | 型号号：0=NROM、1=MMC1、2=UxROM、3=CNROM、4=MMC3 |
| `cpu_addr` | in | 16 | CPU 总线地址（**完整**地址） |
| `cpu_we` | in | 1 | CPU 写周期 |
| `cpu_dout` | in | 8 | CPU 写数据 |
| `ppu_addr` | in | 14 | PPU 地址（mapper 能观察到的部分） |
| `ppu_we` | in | 1 | PPU 写 `$2007` 周期 |
| `ppu_dout` | in | 8 | PPU 写数据 |
| `ppu_a12` | in | 1 | PPU 地址 A12（单独一路，供 MMC3 IRQ 判沿） |
| `prg_readback` | in | 8 | 外部 PRG ROM 在当前地址呈现的字节（bus conflict 用） |
| `prg_bank_offset` | out | `PRG_ADDR_BITS`(17) | PRG ROM 字节偏移，选中的子模块给 |
| `chr_bank_offset` | out | `CHR_ADDR_BITS`(17) | CHR ROM **最终**字节地址 |
| `mirroring` | out | 3 | 名字表镜像模式 |
| `nametable_map` | out | 8 | `nametable_map_decode(mirroring)` 得到的 4×2 bit 表 |
| `prg_ram_enable` | out | 1 | `$6000-$7FFF` 有没有 PRG RAM |
| `prg_ram_we` | out | 1 | PRG RAM 写使能（已含 enable + `$6000-$7FFF`） |
| `chr_ram_enable` | out | 1 | CHR 是否可写（CHR RAM 板子） |
| `chr_ram_we` | out | 1 | CHR RAM 写使能（已含 enable + `$0000-$1FFF`） |
| `irq` | out | 1 | mapper 给 CPU 的中断（高=有效） |
| `bus_conflict` | out | 1 | 组合观测：本次写是否被 ROM 总线值改过 |
| `dbg_prg_bank_number` | out | 8 | 偏移按 8 KiB 粒度的 bank 号 |
| `dbg_chr_bank_number` | out | 8 | 偏移按 1 KiB 粒度的 bank 号 |
| `dbg_mapper_id` | out | 3 | 当前生效型号号 |
| `mmc1_*` / `mmc3_*` | out | — | MMC1/MMC3 内部状态观测，只读，直通子模块 |

---

## 5. 代入 `mapper_select = 0..4` 看输出怎么切换

以 TB（`tb_nes_mapper.v`）配置为例：`PRG_ADDR_BITS=CHR_ADDR_BITS=17`、`PRG_SIZE_BYTES=131072`、`UxROM_BANK_BITS=3`、`NROM_CHR_RAM=1`；所有状态已复位。

| `mapper_select` | 走哪个分支 | `dbg_mapper_id` | `mirroring`（header=0） | 关键出口表现 |
|---:|---|---:|---|---|
| 0 | `select_nrom` → if | 0 | 0 | 偏移透传（NROM-256：`$8000→$00000`、`$FFFF→$07FFF`）；`chr_ram_enable=1`；`irq=0` |
| 1 | `select_mmc1` → else if | 1 | MMC1 控制位 | `prg/chr_bank_offset` 由 MMC1 串行寄存器决定；`prg_ram_enable=~prg_bank[4]` |
| 2 | `select_uxrom` → else if | 2 | 0 | `$C000` 固定末 bank `$1C000`；`$8000` 随 `bank_select`；`bus_conflict` 可拉高 |
| 3 | `select_cnrom` → else if | 3 | 0 | PRG 固定 16 KiB 镜像；`chr_ram_enable=0`（CHR ROM）；写 `$8000` 切 CHR bank |
| 4 | `select_mmc3` → 兜底 else | 4 | MMC3 `$A000` 控制位 | PRG 8 KiB 窗口可换（R6/R7）；MMC3 IRQ 参与 `irq`；CHR bank ≥ `0x80` 别名 |

**切换的关键是"同一根线、不同分支写不同值"**：把 `mapper_select` 从 2 改成 4，唯一变化是 3.4 的 if/else 链改走 MMC3 分支，于是所有出口从"UxROM 一套"整体切成"MMC3 一套"。子模块内部寄存器**不受影响**——所以 TB 里 `mapper_select` 来回改，UxROM 的 bank 和 CNROM 的 CHR bank 各自都还在（`test_select_isolation`）。另一个可观察点是 `nametable_map`：它是 `nametable_map_decode(mirroring_r)`，选中型号的 `mirroring` 一变它就跟着变（NROM header=0 时 `nametable_map = 8'b01010000`）。

---

## 6. 常见疑问

**Q：为什么要把 5 个子模块全例化？不是浪费资源吗？**
A：这是刻意的（`mappers.md` 第 3.1 节）。好处是换 ROM 只改 `mapper_select`，**不用重新综合**；代价是 5 套寄存器的触发器同时存在（合计约 60 个），EP4CE10 上可忽略。软件里是"换函数指针"，硬件里就是"换一根选择线"。

**Q：最后一个 `else` 没写 `select_mmc3`，会不会有 bug？**
A：不会，但它确实是"兜底"：`select_nrom..select_cnrom` 都不成立时走 MMC3。正常 `mapper_select` 只会是 0..4，所以 `else` 精确对应 4。副作用是**给一个不认识的型号号（如 5）会被当成 MMC3**，`dbg_mapper_id` 也显示 4；这一默认行为 TB 未覆盖。

**Q：`prg_bank_offset_r` 名字带 `_r`，为什么不是寄存器？**
A：`_r` 只是命名习惯，真正的判据是**被哪种块赋值**。赋值它的是 `always @*`（组合），所以是组合中间线，不是寄存器（对照 `01` 篇第 3 节）。真正的寄存器在五个子模块里。

**Q：`nametable_map` 为什么不直接等于 `mirroring`？**
A：`mirroring` 是"模式名"，`nametable_map` 是"4 个物理 nametable 的索引表"。PPU 需要的是后者（读逻辑 nametable 时查表访问物理 RAM）。把编码集中在一个 function 里，就不用为每种模式重建 RAM（`mappers.md` 第 2.2 节）。

**Q：`dbg_prg_bank_number` 为什么是 `[16:13]` 而不是整个偏移？**
A：因为它要的是"**第几个 bank**"而非"字节偏移"。去掉低 13 位 = 除以 8192 = 8 KiB bank 号，CHR 去掉低 10 位 = 1 KiB bank 号，TB 一眼就能看出"选中的是几号 bank"。

---

## 7. 你应该带走的三件事

1. **分发 = one-hot 译码 + 组合 mux**：`select_*` 把 `mapper_select` 变成 5 根开关线，`always @*` 的 if/else 链按开关线把"被选中型号的一套输出"接到出口。五个子模块都在跑，只有一个被放行。
2. **写隔离靠门控**：`mapper_write = cpu_we && cpu_addr[15]` 先划出"CPU 写 `$8000-$FFFF`"，再和 `select_*` 与出 `we_mmc1/uxrom/cnrom/mmc3`；`prg_ram_we`/`chr_ram_we` 在出口处再叠加"有无 RAM + 地址段"两道门。
3. **宽度的取舍要能说出后果**：`CHR_ADDR_BITS=17` 刚好够 MMC1（最大 `0x1FFFF`），但对 MMC3 会把 CHR bank 寄存器 bit7 落到地址 bit17 后移出，导致 bank `0x80-0xFF` 别名到 `0x00-0x7F`——这是**有意接受的截断**，不是 bug。

下一篇 [`34-mapper-mmc1.md`](34-mapper-mmc1.md) 精读第一个有"串行移位写协议"的 mapper：MMC1 用 5 次写拼出一个寄存器。
