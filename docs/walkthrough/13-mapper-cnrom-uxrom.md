# 13 第一个带寄存器的 mapper：`nes_mapper_cnrom.v` / `nes_mapper_uxrom.v`

上一篇 [`10-mapper-nrom.md`](10-mapper-nrom.md) 里的 NROM 是**纯组合**的：地址一变，输出立刻变，没有任何记忆。这一篇要精读的两个 mapper 不一样——它们第一次有了**寄存器**，能在运行中被 CPU 改写：

> **CNROM 让程序切"图形（CHR）"的世界；UxROM 让程序切"程序（PRG）"的世界。**

"切"这个动作必须被**记住**，所以这两个模块第一次出现了 `always @(posedge clk)`。这也是它们相对 NROM 唯一的新东西，其余都是 10 篇讲过的地址拼接。

- 源码：[`rtl/nes_core/mapper/nes_mapper_cnrom.v`](../../rtl/nes_core/mapper/nes_mapper_cnrom.v)
- 源码：[`rtl/nes_core/mapper/nes_mapper_uxrom.v`](../../rtl/nes_core/mapper/nes_mapper_uxrom.v)
- 合同与证据：[`../modules/mappers.md`](../modules/mappers.md) 第 4、5.2、5.3 节
- 测试目标：`mapper-combined`（源码 [`tb/mapper/tb_nes_mapper.v`](../../tb/mapper/tb_nes_mapper.v)）；NROM 对照目标 `mapper-nrom`

---

## 1. 先认识"上游和下游"

和 NROM 一样，mapper 夹在 CPU/PPU 和卡带 ROM 之间做地址翻译，但多了两条通道：

```text
CPU：cpu_addr / cpu_we / cpu_dout ─┐
PPU：ppu_addr                     ─┼─► [ mapper ] ─┬─► prg_bank_offset ─► 程序 ROM 下标
卡带 ROM：prg_readback ────────────┘               ├─► chr_bank_offset ─► 图形 ROM 下标
                                                   └─► bus_conflict ────► 观测：这次写被 ROM 值改过吗
```

- **多了 CPU 写通道**（`cpu_we`、`cpu_dout`）：CPU 写 `$8000-$FFFF` 时，mapper 把写数据**存进一个寄存器**。
- **多了回读输入** `prg_readback`：卡带 PRG ROM 在 `cpu_addr` 上呈现的字节，只被 bus conflict 用到（第 5 节）。

这也是它们第一次需要 `clk`/`reset`（原因见 3.1）。

---

## 2. 全文

### 2.1 `nes_mapper_cnrom.v`（切 CHR bank）

```verilog
`timescale 1ns/1ps

module nes_mapper_cnrom #(
    parameter integer PRG_ADDR_BITS = 17,
    parameter integer CHR_ADDR_BITS = 17,
    parameter integer PRG_SIZE_BYTES = 32768,
    parameter integer CNROM_BANK_BITS = 2,
    parameter [1:0] CNROM_BUS_CONFLICT = 2'd1,
    parameter [2:0] HEADER_MIRRORING = 3'd0
)(
    input wire clk,
    input wire reset,
    input wire [15:0] cpu_addr,
    input wire cpu_we,
    input wire [7:0] cpu_dout,
    input wire [13:0] ppu_addr,
    input wire [7:0] prg_readback,
    output wire [PRG_ADDR_BITS-1:0] prg_bank_offset,
    output wire [CHR_ADDR_BITS-1:0] chr_bank_offset,
    output wire [2:0] mirroring,
    output wire prg_ram_enable,
    output wire chr_ram_enable,
    output wire irq,
    output wire bus_conflict
);

reg [CNROM_BANK_BITS-1:0] chr_bank_select;

wire write_accept;
wire [7:0] latched_data;
wire [CHR_ADDR_BITS-1:0] chr_bank_ext;

assign latched_data = (CNROM_BUS_CONFLICT == 2'd0) ? cpu_dout
    : ((CNROM_BUS_CONFLICT == 2'd2) ? cpu_dout : (cpu_dout & prg_readback));
assign write_accept = (CNROM_BUS_CONFLICT == 2'd2) ? (cpu_dout == prg_readback) : 1'b1;
assign bus_conflict = cpu_we && (CNROM_BUS_CONFLICT != 2'd0) && (prg_readback != cpu_dout);

assign chr_bank_ext = {{(CHR_ADDR_BITS-CNROM_BANK_BITS){1'b0}}, chr_bank_select};

assign prg_bank_offset = {{(PRG_ADDR_BITS-14){1'b0}}, cpu_addr[13:0]};
assign chr_bank_offset = (chr_bank_ext << 13) | {{(CHR_ADDR_BITS-13){1'b0}}, ppu_addr[12:0]};
assign mirroring = HEADER_MIRRORING;
assign prg_ram_enable = 1'b0;
assign chr_ram_enable = 1'b0;
assign irq = 1'b0;

always @(posedge clk or posedge reset) begin
    if (reset)
        chr_bank_select <= {CNROM_BANK_BITS{1'b0}};
    else if (cpu_we && write_accept)
        chr_bank_select <= latched_data[CNROM_BANK_BITS-1:0];
end

endmodule
```

### 2.2 `nes_mapper_uxrom.v`（切 PRG bank，末 bank 固定）

```verilog
`timescale 1ns/1ps

module nes_mapper_uxrom #(
    parameter integer PRG_ADDR_BITS = 17,
    parameter integer CHR_ADDR_BITS = 17,
    parameter integer PRG_SIZE_BYTES = 131072,
    parameter integer UxROM_BANK_BITS = 4,
    parameter [1:0] UxROM_BUS_CONFLICT = 2'd1,
    parameter [2:0] HEADER_MIRRORING = 3'd0
)(
    input wire clk,
    input wire reset,
    input wire [15:0] cpu_addr,
    input wire cpu_we,
    input wire [7:0] cpu_dout,
    input wire [13:0] ppu_addr,
    input wire [7:0] prg_readback,
    output wire [PRG_ADDR_BITS-1:0] prg_bank_offset,
    output wire [CHR_ADDR_BITS-1:0] chr_bank_offset,
    output wire [2:0] mirroring,
    output wire prg_ram_enable,
    output wire chr_ram_enable,
    output wire irq,
    output wire bus_conflict
);

localparam [7:0] UXROM_LAST_BANK_16K = (PRG_SIZE_BYTES >> 14) - 1;

reg [UxROM_BANK_BITS-1:0] bank_select;

wire write_accept;
wire [7:0] latched_data;
wire [PRG_ADDR_BITS-1:0] bank_select_ext;
wire [PRG_ADDR_BITS-1:0] bank_base;

assign latched_data = (UxROM_BUS_CONFLICT == 2'd0) ? cpu_dout
    : ((UxROM_BUS_CONFLICT == 2'd2) ? cpu_dout : (cpu_dout & prg_readback));
assign write_accept = (UxROM_BUS_CONFLICT == 2'd2) ? (cpu_dout == prg_readback) : 1'b1;
assign bus_conflict = cpu_we && (UxROM_BUS_CONFLICT != 2'd0) && (prg_readback != cpu_dout);

assign bank_select_ext = {{(PRG_ADDR_BITS-UxROM_BANK_BITS){1'b0}}, bank_select};
assign bank_base = cpu_addr[14]
    ? ({{(PRG_ADDR_BITS-8){1'b0}}, UXROM_LAST_BANK_16K} << 14)
    : (bank_select_ext << 14);

assign prg_bank_offset = bank_base | {{(PRG_ADDR_BITS-14){1'b0}}, cpu_addr[13:0]};
assign chr_bank_offset = {{(CHR_ADDR_BITS-13){1'b0}}, ppu_addr[12:0]};
assign mirroring = HEADER_MIRRORING;
assign prg_ram_enable = 1'b0;
assign chr_ram_enable = 1'b1;
assign irq = 1'b0;

always @(posedge clk or posedge reset) begin
    if (reset)
        bank_select <= {UxROM_BANK_BITS{1'b0}};
    else if (cpu_we && write_accept)
        bank_select <= latched_data[UxROM_BANK_BITS-1:0];
end

endmodule
```

两个文件几乎逐行对称：结构一样，只是"切的是哪个窗口"和"切出来的偏移怎么拼"不同。

---

## 3. 逐段精读

### 3.1 第一个寄存器：为什么 NROM 不需要 `clk`，这两个需要

看 CNROM 的最后一段：

```verilog
reg [CNROM_BANK_BITS-1:0] chr_bank_select;
...
always @(posedge clk or posedge reset) begin
    if (reset)
        chr_bank_select <= {CNROM_BANK_BITS{1'b0}};
    else if (cpu_we && write_accept)
        chr_bank_select <= latched_data[CNROM_BANK_BITS-1:0];
end
```

`chr_bank_select` 是一个**寄存器**（`reg` 被 `always @(posedge clk)` 赋值），记住"当前选中第几个 CHR bank"。为什么 NROM 不需要它、这两个需要？因为 NROM 的映射是**死的**（地址进、偏移出，中间不用记任何东西，所以能全用 `assign`）；而这两个模块要支持"运行时写一个字节换 bank"，下一次 CPU/PPU 读别的地址时 mapper 必须**还记得**上次选的 bank。**要记得，就必须有存储 → 必须有 `clk` 把值打进触发器。**

读法用 02 篇的骨架：`reset` 优先（清 0），`else if` 是使能条件（这里是一条写脉冲），`<=` 是"下一个时钟沿生效"。注意这里是**异步复位**（敏感列表有 `or posedge reset`），reset 一拉高立刻清 0。

### 3.2 CPU 写 PRG 窗口：`cpu_we && write_accept`

寄存器的更新条件是 `cpu_we && write_accept`。`cpu_we` 在顶层已被 `mapper_write = cpu_we && cpu_addr[15]` 和 `select_*` 与过（`nes_mapper.v:145`），所以只有"**CPU 写周期**、地址落在 `$8000-$FFFF`（`cpu_addr[15]=1`）、且当前 mapper 被选中"三者同时成立时（`mapper_select` 门控，`test_select_isolation` 断言过），寄存器才可能更新。

`write_accept` 是 bus conflict 用的门（默认模式下恒为 1），第 5 节讲。

**CNROM 与 UxROM 的差别就在这一条使能上：**

- CNROM：写 `$8000-$FFFF` 更新的是 `chr_bank_select`（**CHR** bank，图形）。
- UxROM：写 `$8000-$FFFF` 更新的是 `bank_select`（**PRG** bank，程序）。

### 3.3 CNROM：切 CHR（图形）bank

```verilog
assign chr_bank_ext = {{(CHR_ADDR_BITS-CNROM_BANK_BITS){1'b0}}, chr_bank_select};
assign chr_bank_offset = (chr_bank_ext << 13) | {{(CHR_ADDR_BITS-13){1'b0}}, ppu_addr[12:0]};
```

两行合起来读：`chr_bank_ext` 先把 2 位 bank 号**补零**到 `CHR_ADDR_BITS` 位（复用 10 篇的 `{{N{1'b0}}, x}` 讲法，N = `CHR_ADDR_BITS - CNROM_BANK_BITS`）；`<< 13` 把它变成该 bank 的字节起点（每个 CHR bank 是 8 KiB = 2^13 字节）；最后 `| {…, ppu_addr[12:0]}` 拼上 bank **内部**的 13 位偏移（PPU 图案表窗口 8 KiB）。一句话：**`chr_bank_offset = bank 起点 + 窗口内偏移`**，就是最终的 CHR 字节地址，PPU 侧直接拿它索引 CHR ROM。

CNROM 的 PRG 是**固定**的：`prg_bank_offset = {{(PRG_ADDR_BITS-14){1'b0}}, cpu_addr[13:0]}`，和 NROM-128 一样只取低 14 位 → `$C000-$FFFF` 是 `$8000-$BFFF` 的镜像；CNROM 板子 PRG 通常就 16 KiB/32 KiB 且不切。

### 3.4 UxROM：切 PRG（程序）bank，且末 bank 固定

UxROM 的写数据进 `bank_select`，但地址译码分两段：

```verilog
assign bank_select_ext = {{(PRG_ADDR_BITS-UxROM_BANK_BITS){1'b0}}, bank_select};
assign bank_base = cpu_addr[14]
    ? ({{(PRG_ADDR_BITS-8){1'b0}}, UXROM_LAST_BANK_16K} << 14)
    : (bank_select_ext << 14);
assign prg_bank_offset = bank_base | {{(PRG_ADDR_BITS-14){1'b0}}, cpu_addr[13:0]};
```

逐句：

- `bank_select_ext`：把 bank 号补零到 `PRG_ADDR_BITS` 位（同 3.3 的补零讲法）。
- `bank_base`：由 `cpu_addr[14]` 二选一——`$8000-$BFFF`（bit=0）用可切换 bank 起点 `bank_select_ext << 14`（每个 PRG bank 16 KiB = 2^14）；`$C000-$FFFF`（bit=1）用**最后一个** bank 起点。
- `UXROM_LAST_BANK_16K = (PRG_SIZE_BYTES >> 14) - 1`：PRG 总字节数除以 16 KiB 得 bank 总数，减 1 就是末 bank 号；它是 `localparam`，在综合时由 `PRG_SIZE_BYTES` 算成常量。
- 最后 `| {…, cpu_addr[13:0]}` 拼上 bank 内 14 位偏移。

**"最后一个 bank 固定"是 UxROM 的关键行为**：`$C000-$FFFF` 永远指向 ROM 末尾那 16 KiB。这样"复位处理、中断向量表"这类必须在固定地址的代码，无论切换到哪个 bank 都能访问到。`$8000-$BFFF` 才随 `bank_select` 变。

UxROM 的 CHR 不切（`chr_bank_offset = {{(CHR_ADDR_BITS-13){1'b0}}, ppu_addr[12:0]}`），且板上通常是 **CHR RAM**：`chr_ram_enable = 1'b1`。对比 CNROM 的 `chr_ram_enable = 1'b0`（CHR ROM，只读）；这一位由 memory owner 决定"PPU 写 CHR 时是否落到 RAM"。

### 3.5 bus conflict：ROM 和 CPU 同时驱动总线

真实卡带上，mapper 的 bank 寄存器常做成**锁存器**，它的输入直接接在数据总线上。CPU 写这个地址时，**PRG ROM 也正在把该地址的字节驱动到同一条数据总线**。两路驱动撞在一起 = **bus conflict（总线冲突）**。

这就是 `prg_readback` 的用途：它是"卡带 ROM 在 `cpu_addr` 上呈现的字节"（由外部 memory owner 提供，mapper 自己不存 ROM）。mapper 用它来还原真实板子的行为：

```verilog
assign latched_data = (BUS_CONFLICT == 2'd0) ? cpu_dout
    : ((BUS_CONFLICT == 2'd2) ? cpu_dout : (cpu_dout & prg_readback));
assign write_accept = (BUS_CONFLICT == 2'd2) ? (cpu_dout == prg_readback) : 1'b1;
assign bus_conflict = cpu_we && (BUS_CONFLICT != 2'd0) && (prg_readback != cpu_dout);
```

`BUS_CONFLICT` 是参数（CNROM/UxROM 各一个），三种取值代表**三种板子**：

| 值 | 语义 | 锁进寄存器的值 | `write_accept` |
|---:|---|---|---|
| `2'd0` | 不处理冲突（74HC161/74HC573 的标准板） | `cpu_dout` | 恒 1 |
| `2'd1` | **AND 模式**（带冲突的变体） | `cpu_dout & prg_readback` | 恒 1 |
| `2'd2` | **严格模式**：不等就整次丢弃写 | `cpu_dout` | `cpu_dout == prg_readback` |

- **AND 模式**：CPU 想写 `$07`、ROM 在该地址是 `$5A`，实际锁进寄存器的是 `$07 & $5A = $02`。软件必须特意让"想写的值"躲开冲突位，否则写进去的值会被 ROM 悄悄改掉。
- **严格模式**：不相等就 `write_accept=0`，**整个写周期被丢掉**，寄存器保持原值；只有明确相等才采纳。这是最严格的模型，用来验证软件真的避开了冲突。
- `bus_conflict` 是**纯组合**输出，只在写周期有效：它记录"这次写确实被 ROM 总线值影响过"。它只用于**观测**，不参与内部控制。

---

## 4. 端口表（两模块合并，标模块）

| 端口 | 方向 | CNROM | UxROM | 含义 |
|---|---|---|---|---|
| `clk` / `reset` | in | ✓ | ✓ | 寄存器时钟与异步复位 |
| `cpu_addr` | in | ✓ | ✓ | CPU 总线地址 |
| `cpu_we` | in | ✓ | ✓ | CPU 写周期（顶层已按 `$8000-$FFFF` 门控） |
| `cpu_dout` | in | ✓ | ✓ | CPU 写数据（bank 号） |
| `ppu_addr` | in | ✓ | ✓ | PPU 图案表地址（低 13 位有效） |
| `prg_readback` | in | ✓ | ✓ | 外部 PRG ROM 在当前地址的字节，供 bus conflict 使用 |
| `prg_bank_offset` | out | ✓ | ✓ | PRG ROM 字节偏移 |
| `chr_bank_offset` | out | ✓ | ✓ | CHR ROM 字节偏移（**最终地址**，不是位移） |
| `mirroring` | out | ✓ | ✓ | 名字表镜像，透传 `HEADER_MIRRORING` |
| `prg_ram_enable` | out | ✓ | ✓ | 两者都恒 0（本版本不建模 WRAM） |
| `chr_ram_enable` | out | ✓ | ✓ | CNROM=0（CHR ROM）、UxROM=1（CHR RAM） |
| `irq` | out | ✓ | ✓ | 两者都无中断源，恒 0 |
| `bus_conflict` | out | ✓ | ✓ | 组合观测：本次写是否被 ROM 值改过 |

参数里最要紧的三个：`CNROM_BANK_BITS`/`UxROM_BANK_BITS`（bank 号位宽，默认 2/4）、`PRG_SIZE_BYTES`（UxROM 用它算末 bank）、`*_BUS_CONFLICT`（bus conflict 模式 0/1/2，见 3.5）。

---

## 5. 代入数值走一遍

以 TB 的配置为例：UxROM `PRG_SIZE_BYTES=131072`（128 KiB）、`UxROM_BANK_BITS=3`、`BUS_CONFLICT=2'd1`；CNROM `CNROM_BANK_BITS=2`。

**UxROM：写 bank 寄存器 → 读窗口偏移改变**（`tb_nes_mapper.v` 的 `test_uxrom_banks`）

| 动作 | `bank_select` | `$8000` 读出的偏移 | `$C000` 读出的偏移 |
|---|---:|---|---|
| 复位后 | 0 | `$00000` | `$1C000`（末 bank 固定） |
| 写 `$8000=5` | 5 | `$14000`（bank5 × `$4000`） | `$1C000`（不变） |
| 写 `$FFFF=2` | 2 | `$08000` | 仍 `$1C000` |
| 写 `$8000=$1F` | `$1F & 7 = 7` | `$1C000` | `$1C000`（都撞到末 bank） |
| 写 `$7FFF=1` | 不变 | 不变 | 不变（`$7FFF` 下由 `cpu_addr[15]` 挡掉） |

`$C000` 的末 bank 偏移 `$1C000 = 7 × $4000 = bank7`，正好是 128 KiB / 16 KiB − 1。TB 用 `prg_signature` 把"读到哪个字节"映射回"选中了哪个 bank"，所以每个偏移都能独立核对。

**CNROM：写 bank 寄存器 → 读 CHR 偏移改变**（`test_cnrom`）

| 动作 | `chr_bank_select` | `ppu_addr=$0000` 时 `chr_bank_offset` | `ppu_addr=$1234` 时 |
|---|---:|---|---|
| 复位后 | 0 | `$0000` | `$1234` |
| 写 `$8000=2` | 2 | `$4000`（2 × `$2000`） | `$5234` |
| 写 `$C000=3` | 3 | `$6000` | `$7234`（`$6000 | $1234`） |

每个 CHR bank 是 8 KiB = `$2000`，所以 bank2 → 起点 `$4000`，bank3 → 起点 `$6000`。CNROM 的 PRG 不管怎么写都固定（TB 断言写 bank 后 `$8000` 读出的 PRG 字节不变）。

**bus conflict**：TB 用开关把 `prg_readback` 强制成 `$5A`。AND 模式（`test_cnrom_bus_conflict`）下写 `cpu_dout=$03`，与 `$5A` 不等 → `bus_conflict=1`，锁进寄存器的值 `$03 & $5A = $02` → 选 CHR bank2 → `chr_bank_offset=$4000`；随后关掉强制，断言 `prg_readback == prg_rom[prg_bank_offset]`，证明读回值来自外部 ROM 且跟随当前 bank。reject 模式（`test_uxrom_bus_conflict_reject`，`BUS_CONFLICT=2'd2` 的独立实例）下写 `$07` 与读回 `$5A` 不等 → 整次写被丢、bank 保持 0，只有相等（`$5A`）才采纳。

---

## 6. 常见疑问

**Q：为什么 CNROM 切 CHR，UxROM 切 PRG？**
A：这是两块真实板子的历史分工。CNROM 板子 PRG 小（常常写死），厂商靠**多塞图形**来区分关卡/场景；UxROM 板子把**程序**切成 16 KiB 一页，让大游戏能放更多代码，同时保留末尾一页放固定代码。

**Q：`chr_bank_offset` 为什么叫"最终地址"而不是"位移"？**
A：因为它已经把 bank 起点和窗口内偏移**加好了**。上层直接 `chr_rom[chr_bank_offset]`，不需要再补任何东西。这和 NROM 的"透传"语义不同，注释里特意写明了。

**Q：`chr_ram_enable` 的默认值两模块不同，会不会搞混？**
A：不会，这正是它们的区别：CNROM 用 CHR ROM（0），UxROM 用 CHR RAM（1）。上层 memory owner 就靠这一位决定 PPU 写 CHR 是落到 RAM 还是被丢弃。

---

## 7. 你应该带走的三件事

1. **第一个寄存器 = 第一个 `clk`**：NROM 无状态所以全 `assign`；CNROM/UxROM 要记住 bank 号，所以第一次出现 `always @(posedge clk or posedge reset)`，用 `if (reset)` 清 0、`else if` 使能写入。
2. **写窗口定 bank，读窗口拼偏移**：`cpu_we && cpu_addr[15]`（顶层已门控）触发寄存器更新；读窗口时 `bank << 粒度位 | 窗口内偏移` 拼出最终字节地址。
3. **UxROM 的"末 bank 固定"与 bus conflict**：`$C000-$FFFF` 永远指向 ROM 末尾 16 KiB（`cpu_addr[14]` 选择）；bus conflict 用外部 `prg_readback` 复现"ROM 与 CPU 抢总线"，参数 0/1/2 分别对应不处理、AND、严格丢弃。

下一篇 [`20-controller.md`](20-controller.md) 进入时序逻辑与状态机的正式入门：用移位寄存器读手柄。
