# 60 顶层集成第一课：`nes_system_v0.v` 与 `nes_system_v1.v`

前面几篇你只读**一个**模块（CPU、PPU、APU）。从这一篇开始读**顶层**（System）：它把几个大模块用线连起来——译地址、发时钟使能、往外送画面和声音。

本仓库的 System 顶层是一条演进链 v0 → v6。本文只读**最早两代**：

- [`rtl/nes_core/system/nes_system_v0.v`](../../rtl/nes_core/system/nes_system_v0.v)：最小集成，只让 CPU 和 PPU 互相跑通。
- [`rtl/nes_core/system/nes_system_v1.v`](../../rtl/nes_core/system/nes_system_v1.v)：在 v0 上加一件事——把 APU 接进来。

合同与证据见 [`../modules/system-v0-v1.md`](../modules/system-v0-v1.md) 与 [`../modules/apu-system.md`](../modules/apu-system.md)。上游：CPU [`50-cpu6502.md`](50-cpu6502.md)、PPU [`51-ppu2c02.md`](51-ppu2c02.md)、APU [`55-apu2a03.md`](55-apu2a03.md)。测试目标：`system-core` / `system-v0` / `system-v0-nmi` / `system-v1-audio`（见 [`tb/system/README.md`](../../tb/system/README.md)）。下一篇 [`61-system-mid.md`](61-system-mid.md)。

---

## 1. System 顶层站在哪里

```text
                 $0000-$1FFF ├─ cpu_ram (2 KiB，核内)
                 $2000-$3FFF ├─ PPU 寄存器 (reg_addr = cpu_addr[2:0])
 CPU ◄── cpu_addr/dout/din ─┤ $4000-$4017 ├─ APU 寄存器（仅 v1）
 (nes_cpu6502)              ┤ $8000-$FFFF ├─ prg_rom (16 KiB，核内)
        ▲ irq_i             └─ nmi_o ◄── ppu_nmi
        └──── v1: apu_irq ──── APU (nes_apu2a03) ─► sample_valid/left/right（仅 v1）

 PPU (nes_ppu2c02) ─► pixel_valid / pixel_x / pixel_y / pixel_index / frame_done / vblank
```

顶层自己**不实现任何 NES 算法**，只做四件事：① 产生 `ce`；② 用 `sel_*` 译码决定地址归谁；③ 例化子模块并接线；④ 把内部状态引到端口给仿真看。CPU/PPU/APU 的内部语义在前面的篇章已讲，这里只看总线。

v0 和 v1 **并列存在**：v1 没改 v0 一行，各有自己的 testbench。

---

## 2. 全文代码

### 2.1 `nes_system_v0.v` 全文

```verilog
`timescale 1ns/1ps

module nes_system_v0 #(
    parameter PRG_SIZE_BYTES = 16384
)(
    input wire clk,
    input wire reset,
    output wire pixel_valid,
    output wire [7:0] pixel_x,
    output wire [7:0] pixel_y,
    output wire [3:0] pixel_index,
    output wire frame_done,
    output wire vblank,
    output wire nmi_o,
    output wire [31:0] cpu_cycle,
    output wire [8:0] ppu_dot,
    output wire [8:0] ppu_scanline
);

localparam PRG_INDEX_BITS = $clog2(PRG_SIZE_BYTES);

reg [3:0] div_phase;
wire ce_ppu;
wire ce_cpu;

assign ce_ppu = !reset && (div_phase[1:0] == 2'b00);
assign ce_cpu = !reset && (div_phase == 4'd0);

always @(posedge clk or posedge reset) begin
    if (reset)
        div_phase <= 4'd0;
    else if (div_phase == 4'd11)
        div_phase <= 4'd0;
    else
        div_phase <= div_phase + 4'd1;
end

reg [7:0] cpu_ram [0:2047];
reg [7:0] prg_rom [0:PRG_SIZE_BYTES-1];

wire [15:0] cpu_addr;
wire cpu_we;
wire [7:0] cpu_dout;
reg [7:0] cpu_din;
wire cpu_bus_req;
wire cpu_bus_fire;
wire [3:0] cpu_cycle_phase;
wire [7:0] ppu_reg_dout;
wire ppu_nmi;
wire sel_ram;
wire sel_ppu;
wire [10:0] ram_index;
wire [14:0] prg_addr_window;
wire [PRG_INDEX_BITS-1:0] prg_index;
wire ppu_reg_cs;

assign sel_ram = (cpu_addr[15:13] == 3'b000);
assign sel_ppu = (cpu_addr[15:13] == 3'b001);
assign ram_index = cpu_addr[10:0];
assign prg_addr_window = cpu_addr[14:0];
assign prg_index = prg_addr_window[PRG_INDEX_BITS-1:0];
assign ppu_reg_cs = cpu_bus_fire && sel_ppu;
assign nmi_o = ppu_nmi;

always @* begin
    case (cpu_addr[15:13])
        3'b000: cpu_din = cpu_ram[ram_index];
        3'b001: cpu_din = ppu_reg_dout;
        3'b010: cpu_din = 8'h00;
        3'b011: cpu_din = 8'h00;
        default: cpu_din = prg_rom[prg_index];
    endcase
end

always @(posedge clk) begin
    if (cpu_bus_fire && cpu_we && sel_ram)
        cpu_ram[ram_index] <= cpu_dout;
end

nes_cpu6502 u_cpu (
    .clk(clk),
    .reset(reset),
    .ce(ce_cpu),
    .bus_hold(1'b0),
    .bus_din(cpu_din),
    .bus_ready(!reset),
    .nmi_i(ppu_nmi),
    .irq_i(1'b0),
    .bus_req(cpu_bus_req),
    .bus_fire(cpu_bus_fire),
    .cpu_cycle(cpu_cycle),
    .cpu_cycle_phase(cpu_cycle_phase),
    .bus_addr(cpu_addr),
    .bus_we(cpu_we),
    .bus_dout(cpu_dout),
    .dbg_pc(), .dbg_a(), .dbg_x(), .dbg_y(), .dbg_sp(), .dbg_p(),
    .dbg_opcode(), .dbg_state(), .dbg_nmi_pending(), .dbg_irq_pending(), .dbg_illegal()
);

nes_ppu2c02 #(
    .MIRROR_VERTICAL(1'b0)
) u_ppu (
    .clk(clk),
    .reset(reset),
    .ce(ce_ppu),
    .reg_cs(ppu_reg_cs),
    .reg_we(cpu_we),
    .reg_addr(cpu_addr[2:0]),
    .reg_din(cpu_dout),
    .reg_dout(ppu_reg_dout),
    .pixel_valid(pixel_valid),
    .pixel_x(pixel_x),
    .pixel_y(pixel_y),
    .pixel_index(pixel_index),
    .frame_done(frame_done),
    .vblank(vblank),
    .nmi_o(ppu_nmi),
    .dot(ppu_dot),
    .scanline(ppu_scanline),
    .dbg_v(), .dbg_t(), .dbg_x(), .dbg_w(), .chr_rd_arm(1'b0)
);

endmodule
```

> 为了省版面，上面把两个例化里的 `dbg_*` 观测口（CPU 11 个、PPU 4 个）与 PPU 的 `chr_rd_arm` 折成了几行；它们是只读观测口，不影响逻辑（见 [`02-project-conventions.md`](02-project-conventions.md) 第 7 节）。

### 2.2 `nes_system_v1.v`：新增 / 改动的全部代码

v1 与 v0 的差异只有 6 处，`div_phase`、RAM、PRG 镜像、CPU 例化、PPU 例化**逐字相同**，此处不重复，只列新增与改动：

```verilog
module nes_system_v1 #(
    parameter PRG_SIZE_BYTES = 16384
)(
    // ... clk/reset/pixel_*/frame_done/vblank/nmi_o 与 v0 相同 ...
    output wire apu_irq_o,                  // 新增
    output wire audio_sample_valid,         // 新增
    output wire [15:0] audio_sample_left,   // 新增
    output wire [15:0] audio_sample_right,  // 新增
    output wire oam_dma_req,                // 新增
    output wire [7:0] oam_dma_count,        // 新增
    output wire [31:0] cpu_cycle,
    output wire [8:0] ppu_dot,
    output wire [8:0] ppu_scanline
);

localparam PRG_INDEX_BITS = $clog2(PRG_SIZE_BYTES);
localparam [10:0] APU_PAGE_HIGH = 11'h200;   // $4000 的高 11 位
localparam [4:0]  APU_REG_LAST  = 5'h17;     // $4017
localparam [4:0]  APU_REG_DMA   = 5'h14;     // $4014

// div_phase / ce_ppu / ce_cpu / cpu_ram / prg_rom：与 v0 逐字相同，省略
wire ce_sample;                              // 新增
assign ce_sample = 1'b1;                     // 采样使能恒开
reg [7:0] oam_dma_count_reg;                 // 新增：$4014 粘滞计数

wire [7:0] apu_reg_dout;                     // 新增（以下 7 根均新增）
wire apu_irq;
wire apu_sample_valid;
wire [15:0] apu_sample_left;
wire [15:0] apu_sample_right;
wire sel_apu;
wire apu_reg_cs;

assign sel_apu = (cpu_addr[15:5] == APU_PAGE_HIGH) && (cpu_addr[4:0] <= APU_REG_LAST);
assign apu_reg_cs = cpu_bus_fire && sel_apu;
assign apu_irq_o = apu_irq;
assign audio_sample_valid = apu_sample_valid;
assign audio_sample_left = apu_sample_left;
assign audio_sample_right = apu_sample_right;
assign oam_dma_req = cpu_bus_fire && sel_apu && (cpu_addr[4:0] == APU_REG_DMA);
assign oam_dma_count = oam_dma_count_reg;

// 读 mux 唯一改动：3'b010 分支
//   3'b000/001/011/default 与 v0 逐字相同
3'b010: cpu_din = sel_apu ? apu_reg_dout : 8'h00;

always @(posedge clk or posedge reset) begin   // 新增
    if (reset)
        oam_dma_count_reg <= 8'd0;
    else if (oam_dma_req)
        oam_dma_count_reg <= oam_dma_count_reg + 8'd1;
end

// CPU 例化：与 v0 逐字相同，唯一差异是 .irq_i(apu_irq)（v0 是 1'b0）
// PPU 例化：与 v0 逐字相同，省略

nes_apu2a03 u_apu (                          // 新增：APU 第一次进系统
    .clk(clk), .reset(reset),
    .ce(ce_cpu),                             // 按 CPU 周期推进（不是 ce_ppu）
    .ce_sample(ce_sample),
    .reg_cs(apu_reg_cs), .reg_we(cpu_we),
    .reg_addr(cpu_addr[4:0]), .reg_din(cpu_dout), .reg_dout(apu_reg_dout),
    .irq(apu_irq),
    .dmc_bus_req(), .dmc_addr(),             // 悬空：DMC DMA 未接
    .dmc_rdata(8'h00), .dmc_ack(1'b0),
    .sample_valid(apu_sample_valid),
    .sample_left(apu_sample_left),
    .sample_right(apu_sample_right)
    // ... dbg_frame_phase 等约 48 个 dbg_* 端口全部悬空，省略 ...
);

endmodule
```

---

## 3. 逐段精读

### 3.1 `div_phase` 0..11：12 拍分频，CPU : PPU = 1 : 3

整个核心**只有一个时钟 `clk`**，两个部件靠 `ce` 决定"这一拍动不动"（见 §2.1）。`div_phase` 是 0..11 的四位相位计数器，数到 11 回卷 0：

- `ce_ppu = (div_phase[1:0] == 2'b00)`：低两位为 0，只在 0、4、8 为真——**每 4 拍一次**，所以 **1 个 PPU dot = 4 个 `clk`**。
- `ce_cpu = (div_phase == 4'd0)`：四位全 0，**每 12 拍一次**，所以 **1 个 CPU 周期 = 12 个 `clk`**。
- 12 : 4 = **3 : 1**，正是真机 CPU 1.789 MHz 对 PPU 5.369 MHz。`div_phase==0` 同时满足两者，所以 **CPU 与 PPU 永远同相**。

这是本项目最重要的固定写法：**切的是 `ce`，不是时钟**。你永远不会看到 `always @(posedge clk_ppu)`（见 [`02-project-conventions.md`](02-project-conventions.md) 第 1 节）。

### 3.2 2 KiB 工作 RAM 与四路镜像

`cpu_ram [0:2047]` 只有 2 KiB，而 `$0000-$1FFF` 是 8 KiB。索引 `ram_index = cpu_addr[10:0]` 只取**低 11 位**，丢掉高两位：

| CPU 地址 | 物理字节 |
|---|---|
| `$0000-$07FF` | 本体 |
| `$0800-$0FFF` / `$1000-$17FF` / `$1800-$1FFF` | 三次别名（镜像） |

`STA $0010` 与 `STA $1810` 写的是同一个 `cpu_ram[16'h010]`。写侧就一句：`if (cpu_bus_fire && cpu_we && sel_ram) cpu_ram[ram_index] <= cpu_dout;`。

### 3.3 16 KiB PRG：NROM-128 双窗口镜像

`PRG_INDEX_BITS = $clog2(16384) = 14`。`prg_addr_window = cpu_addr[14:0]` 丢掉 `addr[15]`，`prg_index = prg_addr_window[13:0]` 再丢掉 `addr[14]`——16 KiB 时实际索引就是 `cpu_addr[13:0]`，于是 `$8000-$BFFF` 与 `$C000-$FFFF` 两个窗口都索引到 `prg_rom[0..16383]`——**同一份 ROM 出现两遍**，这就是 NROM-128。复位向量 `$FFFC/$FFFD` 落在上窗口，也读低 14 位。**没有 bank 切换**：`PRG_SIZE_BYTES` 只是容量参数，16 KiB 是 EP4CE10 的资源收敛结果，不构成任何 mapper 支持。

### 3.4 地址译码：一个组合 `case` 决定 CPU 读什么

v0 没有独立总线模块，译码写在顶层，读数据是**纯组合** mux（§2.1 的 `always @*`，只看 `cpu_addr[15:13]`）：`$0000` 读 RAM、`$2000` 读 PPU 寄存器、`$4000`/`$6000` 读常量 `$00`、`$8000` 起读 PRG。

- `cpu_din` 声明是 `reg`，但写在 `always @*` 里、用阻塞 `=`，所以综合成**组合 mux**，不是触发器。
- 没接的地址写成**确定的 `$00`** 而不是 `X`，testbench 才能直接断言。
- `case` 必须带 `default`，否则推断出锁存器（见 [`01-verilog-basics.md`](01-verilog-basics.md) 第 5 节）。

### 3.5 `$2000` 空间：8 KiB 窗口折叠到 3 位

`$2000-$3FFF` 是 8 KiB，PPU 只有 8 个寄存器，所以 `reg_addr = cpu_addr[2:0]`：`$2000/$2008/.../$3FF8` 全指向 `$2000`（和 §3.2 的 RAM 镜像同一种"窗口 + 截断"手法）。注意 `ppu_reg_cs = cpu_bus_fire && sel_ppu`，不是 `sel_ppu`——PPU 寄存器带副作用，必须用"事务完成的那一拍"脉冲，避免等待期重复执行。

### 3.6 向量与 `nmi_o`

- **复位向量** `$FFFC/$FFFD` 走 `default` 分支；testbench 预填 `$FFFC=$00`、`$FFFD=$80`，首次取指 PC = `$8000`。
- **NMI 向量** `$FFFA/$FFFB` 同样走 `default`。`nmi_o = ppu_nmi`，而 `ppu_nmi = vblank && PPUCTRL[7]`；CPU 对 NMI 做**上升沿检测 + 锁存**，走 7 周期入栈取向量。
- **IRQ 向量** `$FFFE/$FFFF`：v0 的 `irq_i` 恒 `1'b0`，没有触发源。

### 3.7 v0 的简化点（逐条）

1. **`cpu_din` 组合**：读无时序、无握手，地址稳定数据就在。
2. **`cpu_ram`/`prg_rom` 在核内**：不是独立模块，写端口是内联 `always`。
3. **`bus_ready(!reset)` 零等待**：`bus_req` 只在 `ce_cpu` 有效拍拉高，于是 `bus_fire = bus_req && !reset` 天然宽 1 拍——**每次访存恰好 1 个 CPU 周期，等待逻辑从未被执行**。
4. **无 APU / mapper / DMA / controller / 外部 CHR**：`$4000` 读 0 写忽略，`$4014` 未译码，CHR 是 PPU 核内 RAM。

收益是**结构简单、时序确定**，代价是"什么都没接"。

### 3.8 v1 相对 v0 的 delta

1. **例化 `nes_apu2a03`**：`ce = ce_cpu`（frame counter 必须按 CPU 周期走），`ce_sample = 1'b1`。
2. **`$4000-$4017` 路由**：`sel_apu` + `apu_reg_cs` + 读 mux 的 `3'b010` 分支。上界必须写 `cpu_addr[4:0] <= 5'h17`，**不能用 `!cpu_addr[4]`**：`$4010-$401F` 的 bit4 全是 1，后者会漏掉 `$4015/$4017`（此错真实出现过）。
3. **IRQ 注入**：`irq_i` 从 `1'b0` 变成 `apu_irq`（`frame_irq_flag | dmc_irq_flag`），**电平、不锁存**，软件须自己读/写 `$4015` ack。
4. **`oam_dma_count_reg`**：`$4014` 落在 `sel_apu` 内，读回 `$00`、写无副作用，但每次访问计数加一。
5. **新增 5 个输出端口**（见 §4）。

APU 接线的完整推导见 [`../modules/apu-system.md`](../modules/apu-system.md)。

---

## 4. 端口表（v0 / v1 合并，标版本）

| 端口 | 方向 | 位宽 | v0 | v1 | 作用 |
|---|---|---|---|---|---|
| `clk` / `reset` | in | 1 / 1 | ✓ | ✓ | 单一系统时钟 / 高有效异步复位 |
| `pixel_valid` / `pixel_x` / `pixel_y` | out | 1/8/8 | ✓ | ✓ | 背景像素；渲染关时 `pixel_valid` 仍高 |
| `pixel_index` | out | 4 | ✓ | ✓ | NES palette 索引（不是 RGB） |
| `frame_done` | out | 1 | ✓ | ✓ | 帧边界脉冲，结算后落在 `(0,0)` |
| `vblank` | out | 1 | ✓ | ✓ | 0-based，窗口 `(241,1)..(261,0)` |
| `nmi_o` | out | 1 | ✓ | ✓ | `= vblank && PPUCTRL[7]` |
| `cpu_cycle` | out | 32 | ✓ | ✓ | CPU 总线周期计数 |
| `ppu_dot` / `ppu_scanline` | out | 9 / 9 | ✓ | ✓ | PPU 0-based dot / scanline |
| `apu_irq_o` | out | 1 | — | ✓ | APU `irq`，**同时**驱动 CPU `irq_i`，电平不锁存 |
| `audio_sample_valid` | out | 1 | — | ✓ | 采样 strobe，宽 1 拍、落在 `div_phase==1` |
| `audio_sample_left` / `right` | out | 16/16 | — | ✓ | 混音输出，左右当前相同 |
| `oam_dma_req` | out | 1 | — | ✓ | 宽 1 拍脉冲，"CPU 访问了 `$4014`" |
| `oam_dma_count` | out | 8 | — | ✓ | 粘滞计数，每次 `oam_dma_req` 加一 |

参数 `PRG_SIZE_BYTES`（默认 `16384`）：PRG 存储深度；16 KiB 时两窗口完全镜像。

---

## 5. 一帧里 `ce_cpu` / `ce_ppu` 的节拍走一遍

`clk` 自由跑，`div_phase` 从 0 数到 11 再回卷。把两个 `ce` 画在同一时间轴上（下标是 `clk` 拍）：

```text
clk          0   1   2   3   4   5   6   7   8   9  10  11 | 12 ...
div_phase    0   1   2   3   4   5   6   7   8   9  10  11 |  0 ...
ce_cpu       1   .   .   .   .   .   .   .   .   .   .   . |  1 ...
ce_ppu       1   .   .   .   1   .   .   .   1   .   .   . |  1 ...
             ^               ^               ^             ^
           CPU 周期 0         dot 1           dot 2      CPU 周期 1
```

- 一个 **CPU 周期** = 12 个 `clk`；一个 **PPU dot** = 4 个 `clk`；一个 CPU 周期里 PPU 走 **3 个 dot**。
- `ce_cpu==1` 的那一拍**必然** `ce_ppu==1`，所以**每次 CPU 总线事务都落在一个 PPU dot 上**：落在 PPU 地址空间就会顺带吃掉该 dot 的滚动更新。这是 v0 的明确取舍——换来 CPU/PPU 永不错拍。

一帧长度（NTSC）钉在 `262 × 341 × 4 = 357368` 个 `clk`。`div_phase` 是 12 拍而不是 4 拍，意味着 `clk` 的标称是 **21.477 MHz**（12 × 1.789 MHz）；testbench 里 `always #5 clk`（100 MHz）只决定仿真快慢，不改变任何周期比例。

---

## 6. 常见疑问

**Q：为什么不直接把 `clk` 分频出 `clk_cpu`/`clk_ppu`？**
A：本项目铁律是**一个时钟 + `ce`**。门控/分频时钟会让时序分析和跨域处理变复杂；`ce` 方案里"冻结点"一目了然（见 [`01-verilog-basics.md`](01-verilog-basics.md) 第 9 节）。

**Q：`cpu_din` 是 `reg`，为什么说它是组合逻辑？**
A：`reg`/`wire` 的区别是"谁驱动它"，不是"是不是寄存器"。它写在 `always @*` 里、用 `=`，所以综合成组合 mux。

**Q：为什么 `ppu_reg_cs` 要写成 `cpu_bus_fire && sel_ppu`，不直接用 `sel_ppu`？**
A：`sel_ppu` 是"地址落在窗口里"，只要地址停着就一直有效；`cpu_bus_fire` 是"事务恰好这一拍完成"。寄存器带副作用，必须用完成脉冲保证一次访问只执行一次。

**Q：v1 的 `ce_sample = 1'b1`，`audio_sample_valid` 是音频速率吗？**
A：不是。它等价于每个 `ce_cpu` 沿后宽 1 拍的 strobe（落在 `div_phase==1`），速率 1.789 MHz。下游必须自己抽取/重采样；没有 FIFO、没有 WM8978 接口。

**Q：v0/v1 里有 DMA 吗？**
A：没有。`$4014` 只被"记一笔"（`oam_dma_count`），没有 DMA 状态机、没有 `RDY` 拉低、没有 stolen cycle。APU 的 `dmc_bus_req`/`dmc_addr` 悬空、`dmc_ack=1'b0`——**没有保护阻止程序启动 DMC 后挂在 `dmc_ack=0` 上死等**。

---

## 7. 你应该带走的三件事

1. **顶层只做四件事**：发 `ce`、译地址（`sel_*`）、连子模块、引观测口；算法都在子模块里。
2. **`div_phase` 0..11 是全部时序的根**：`ce_cpu = (div_phase==0)`（12 拍），`ce_ppu = (div_phase[1:0]==0)`（每 4 拍），CPU:dot = 1:3 且永远同相。
3. **v0 是"能跑通"，v1 是"多了声音"**：v0 用组合 `cpu_din`、核内 RAM/PRG、`bus_ready(!reset)` 零等待换确定性；v1 只加 APU 例化、`$4000` 路由、`irq_i` 注入和一排 sample 输出口。v0/v1 是 v2..v6 的**起点**（见 [`../modules/system-v0-v1.md`](../modules/system-v0-v1.md) 第 9 节）。

下一篇 [`61-system-mid.md`](61-system-mid.md) 读 v2/v3/v4：接独立的 `nes_cpu_bus`（真等待态）、加 OAM DMA 仲裁、再加手柄。
