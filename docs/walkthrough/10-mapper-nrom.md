# 10 第一款模块精读：`nes_mapper_nrom.v`

这是本教程的第一篇模块精读，也是**最简单的一个模块**：没有时钟、没有状态机、没有存储器，只有几条 `assign`。它的任务是回答一个问题：

> **CPU 给出一个地址（比如 `$C123`），卡带 ROM 里到底哪个字节该被读到总线上？**

这个"看地址决定去 ROM 哪个偏移"的东西，就叫 **mapper（映射器）**。NROM 是最简单的一种 mapper（早期卡带用它）。

- 源码：[`rtl/nes_core/mapper/nes_mapper_nrom.v`](../../rtl/nes_core/mapper/nes_mapper_nrom.v)
- 合同与证据：[`../modules/mappers.md`](../modules/mappers.md)
- 测试目标：`mapper-nrom`（见 [`tb/mapper/tb_nes_mapper_nrom128.v`](../../tb/mapper/tb_nes_mapper_nrom128.v)）

---

## 1. 先认识"上游和下游"

```text
CPU 给出 cpu_addr ──► [nes_mapper_nrom] ──► prg_bank_offset ──► 卡带 ROM 用这个偏移取字节
PPU 给出 ppu_addr ──►                  ──► chr_bank_offset ──► 图形 ROM 用这个偏移取字节
```

- **CPU 侧**：6502 读 `$8000-$FFFF` 就是读卡带程序 ROM（PRG）。
- **PPU 侧**：PPU 读图案表就是读卡带图形 ROM（CHR）。
- mapper 夹在中间，把"CPU/PPU 看到的地址"翻译成"ROM 数组里的下标"。

NROM 的翻译极其简单：**几乎就是原样透传**。复杂 mapper（MMC1/MMC3）才会换 bank。

---

## 2. 全文（32 行）

```verilog
`timescale 1ns/1ps

module nes_mapper_nrom #(
    parameter integer PRG_ADDR_BITS = 17,
    parameter integer CHR_ADDR_BITS = 17,
    parameter integer PRG_SIZE_BYTES = 32768,
    parameter NROM_MIRROR_16K = (PRG_SIZE_BYTES <= 16384),
    parameter [2:0] HEADER_MIRRORING = 3'd0,
    parameter NROM_PRG_RAM = 1'b0,
    parameter NROM_CHR_RAM = 1'b0
)(
    input wire [15:0] cpu_addr,
    input wire [13:0] ppu_addr,
    output wire [PRG_ADDR_BITS-1:0] prg_bank_offset,
    output wire [CHR_ADDR_BITS-1:0] chr_bank_offset,
    output wire [2:0] mirroring,
    output wire prg_ram_enable,
    output wire chr_ram_enable,
    output wire irq
);

assign prg_bank_offset = NROM_MIRROR_16K
    ? {{(PRG_ADDR_BITS-14){1'b0}}, cpu_addr[13:0]}
    : {{(PRG_ADDR_BITS-15){1'b0}}, cpu_addr[14:0]};

assign chr_bank_offset = {{(CHR_ADDR_BITS-13){1'b0}}, ppu_addr[12:0]};
assign mirroring = HEADER_MIRRORING;
assign prg_ram_enable = NROM_PRG_RAM;
assign chr_ram_enable = NROM_CHR_RAM;
assign irq = 1'b0;

endmodule
```

看到 `assign` 了吗？**整份代码没有一行时钟**。它是一个纯组合电路：地址一变，输出立刻变（有一定逻辑延迟）。

---

## 3. 逐段精读

### 3.1 开头：`` `timescale 1ns/1ps ``

给仿真器用的时间单位（1 纳秒分辨率）。对综合没有影响，本项目每个文件都写这一行。

### 3.2 参数列表 `#(...)`

```verilog
module nes_mapper_nrom #(
    parameter integer PRG_ADDR_BITS = 17,     // PRG 偏移的位宽
    parameter integer CHR_ADDR_BITS = 17,     // CHR 偏移的位宽
    parameter integer PRG_SIZE_BYTES = 32768, // PRG 大小（默认 32 KiB）
    parameter NROM_MIRROR_16K = (PRG_SIZE_BYTES <= 16384),
    parameter [2:0] HEADER_MIRRORING = 3'd0,
    parameter NROM_PRG_RAM = 1'b0,
    parameter NROM_CHR_RAM = 1'b0
)(
```

逐个说人话：

| 参数 | 含义 | 白话 |
|---|---|---|
| `PRG_ADDR_BITS` | 输出偏移多少位 | ROM 最大 128 KiB 时需要 17 位 |
| `CHR_ADDR_BITS` | 同上，给 CHR | |
| `PRG_SIZE_BYTES` | 这张卡 PRG 有多大 | NROM 有 16 KiB 和 32 KiB 两版 |
| `NROM_MIRROR_16K` | **是否 16 KiB 镜像** | 见 3.4 节，这是 NROM 的关键 |
| `HEADER_MIRRORING` | 名字表镜像模式 | 由 iNES 文件头带进来，原样传给 PPU |
| `NROM_PRG_RAM` / `NROM_CHR_RAM` | 这张卡有没有 PRG-RAM / CHR-RAM | NROM 通常是 ROM，所以默认 0 |

注意 `NROM_MIRROR_16K = (PRG_SIZE_BYTES <= 16384)`：**参数可以有默认表达式**。它自动判断"PRG 只有 16 KiB 或更小"。16 KiB 的卡就是 NROM-128，32 KiB 的是 NROM-256。

### 3.3 端口列表

```verilog
    input wire [15:0] cpu_addr,
    input wire [13:0] ppu_addr,
    output wire [PRG_ADDR_BITS-1:0] prg_bank_offset,
    output wire [CHR_ADDR_BITS-1:0] chr_bank_offset,
    output wire [2:0] mirroring,
    output wire prg_ram_enable,
    output wire chr_ram_enable,
    output wire irq
```

| 端口 | 方向 | 位宽 | 作用 |
|---|---|---|---|
| `cpu_addr` | in | 16 | CPU 想访问的地址 |
| `ppu_addr` | in | 14 | PPU 想访问的图案表地址 |
| `prg_bank_offset` | out | 17 | 译好后送 ROM 数组的下标 |
| `chr_bank_offset` | out | 17 | 同上，给 CHR |
| `mirroring` | out | 3 | 名字表镜像模式（原样转发） |
| `prg_ram_enable` | out | 1 | 是否启用 PRG-RAM |
| `chr_ram_enable` | out | 1 | 是否可写 CHR（ROM 卡为 0） |
| `irq` | out | 1 | NROM 没有 IRQ 源，恒 0 |

**为什么输出是 `wire` 而不是 `reg`？** 因为整份代码全用 `assign`，没有过程块（`always`）。`assign` 驱动的东西就是 `wire`。

### 3.4 核心一：`prg_bank_offset`（PRG 地址翻译）

```verilog
assign prg_bank_offset = NROM_MIRROR_16K
    ? {{(PRG_ADDR_BITS-14){1'b0}}, cpu_addr[13:0]}
    : {{(PRG_ADDR_BITS-15){1'b0}}, cpu_addr[14:0]};
```

拆开读：

- 这是一个三目（`? :`）：如果 `NROM_MIRROR_16K` 为真走上面一行，否则走下面一行。
- `{{(PRG_ADDR_BITS-14){1'b0}}, cpu_addr[13:0]}`：先复制 `PRG_ADDR_BITS-14 = 3` 个 0，再拼上 `cpu_addr` 的**低 14 位**。结果正好 17 位（3+14）。
- 另一支补 2 个 0 再拼**低 15 位**（2+15=17）。

**为什么 16 KiB 卡只取低 14 位？** 这就是 NROM-128 的"镜像"：

- 16 KiB 的 ROM 需要 14 位地址（2^14 = 16384）。
- CPU 的 `$8000-$BFFF` 和 `$C000-$FFFF` 是两段 16 KiB，但 ROM 只有一段。
- 丢掉最高位 → `$C000` 也指向 ROM 偏移 0，`$FFFF` 也指向偏移 `$3FFF`。**同一份 ROM 在内存里出现了两遍**，这就是"镜像"。

而 32 KiB 卡不镜像，两段拼起来正好覆盖 32 KiB，所以取低 15 位。

### 3.5 核心二：`chr_bank_offset`（CHR 地址翻译）

```verilog
assign chr_bank_offset = {{(CHR_ADDR_BITS-13){1'b0}}, ppu_addr[12:0]};
```

PPU 的图案表窗口是 8 KiB（13 位），所以补 `CHR_ADDR_BITS-13 = 4` 个 0，再拼 `ppu_addr` 的低 13 位。**CHR 在 NROM 里永远是同一份 8 KiB，不换 bank。**

> 这里"丢掉 `ppu_addr[13]`"是本项目**有意接受**的截断（pattern-table 选择落在 bit 12），详见 [`../modules/system-v6.md`](../modules/system-v6.md)。现在只需要知道：NROM 只关心低 13 位。

### 3.6 其余输出：原样转发与常量

```verilog
assign mirroring       = HEADER_MIRRORING;   // 文件头说什么就是什么
assign prg_ram_enable  = NROM_PRG_RAM;       // 参数决定
assign chr_ram_enable  = NROM_CHR_RAM;       // 参数决定
assign irq             = 1'b0;               // NROM 没有中断源
```

- `mirroring` 是**透传**：mapper 自己不产生镜像模式，只是把 iNES 头里的值送到 PPU。
- `irq = 1'b0` 是一个**常量输出**。虽然 NROM 用不到，但接口统一，上层可以不管 mapper 型号直接连（没有中断的 mapper 恒 0）。

---

## 4. 代入具体数字走两遍

**例 A：NROM-256（`PRG_SIZE_BYTES = 32768`）**

此时 `NROM_MIRROR_16K = (32768 <= 16384) = 0`，走下面一支（低 15 位）：

| `cpu_addr` | `prg_bank_offset` | 说明 |
|---|---|---|
| `$8000` | `$0000` | 窗口起点 → ROM 开头 |
| `$C000` | `$4000` | 第二段 → ROM 中间 |
| `$FFFF` | `$7FFF` | 最后一行 → ROM 末尾 |
| `$FFFC` | `$7FFC` | **复位向量**就在这（CPU 从这读启动地址） |

**例 B：NROM-128（`PRG_SIZE_BYTES = 16384`）**

此时 `NROM_MIRROR_16K = 1`，走上面一支（低 14 位）：

| `cpu_addr` | `prg_bank_offset` | 说明 |
|---|---|---|
| `$8000` | `$0000` | 第一段起点 |
| `$C000` | `$0000` | **镜像**：又回到 ROM 开头 |
| `$FFFF` | `$3FFF` | 镜像后的末尾 |

这就是测试 `tb_nes_mapper_nrom128.v` 要覆盖的行为：**同一份数据被两段地址访问到。**

---

## 5. 常见疑问

**Q：为什么这个模块没有 `clk`？**
A：NROM 的映射是固定的，不需要"记住"任何东西，所以是纯组合。MMC1/MMC3 要记住 bank 号，那些模块才有 `clk`。

**Q：`irq` 恒 0 不是浪费端口吗？**
A：不。上层顶层（`nes_system_v5/v6`）对任何 mapper 都写 `cpu.irq_i = mapper_irq | apu_irq`。让没中断的 mapper 输出 0，顶层就不用为 mapper 型号写分支。

**Q：为什么参数叫"offset"而不是"bank"？**
A：因为它是**绝对字节偏移**，不是 bank 编号。上层直接拿它去索引 ROM 数组；换 bank 的运算已经在这个模块里做完了。

---

## 6. 你应该带走的三件事

1. **mapper = 地址翻译器**：输入 CPU/PPU 地址，输出 ROM 下标。NROM 只是"透传 + 截断"。
2. **位宽截断要能说出后果**：16 KiB 卡丢第 14 位 → 镜像；8 KiB CHR 丢第 13 位 → 只认低 13 位。
3. **纯组合模块长什么样**：全 `assign`、无 `always`、输出是 `wire`。

下一篇 [`11-alu-lut.md`](11-alu-lut.md) 看另一类纯组合模块：用 `case` 查表。
