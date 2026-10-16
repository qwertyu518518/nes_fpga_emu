# 35 精读 `nes_mapper_mmc3.v`：MMC3 的 bank 切换与扫描线 IRQ

MMC3（mapper 4）是 NES 上最常用的 mapper。和 [`10-mapper-nrom.md`](10-mapper-nrom.md) 那几行 `assign` 相比，这一篇是本教程里**第一个既有寄存器、又有写协议、还有边沿计数**的模块：它要记住 CPU 写进来的 bank 号，还要从 PPU 的 A12 线上"数扫描线"并在数完时拉 IRQ。语法基础见 [`01-verilog-basics.md`](01-verilog-basics.md)、[`02-project-conventions.md`](02-project-conventions.md)。

- 源码：[`rtl/nes_core/mapper/nes_mapper_mmc3.v`](../../rtl/nes_core/mapper/nes_mapper_mmc3.v)
- 合同与证据：[`../modules/mappers.md`](../modules/mappers.md) 第 5.5 节
- 测试目标：`mapper-mmc3`（见 [`tb/mapper/tb_nes_mapper_mmc3.v`](../../tb/mapper/tb_nes_mapper_mmc3.v)）

---

## 1. 先认识"上游和下游"

```text
CPU 写 $8000-$FFFF ──► [nes_mapper_mmc3] ──► prg_bank_offset ──► PRG ROM 取字节
PPU 给 ppu_addr    ──►                  ──► chr_bank_offset ──► CHR ROM 取字节
PPU 给 ppu_a12     ──► A12 扫描计数器   ──► irq ─────────────► CPU 中断引脚
```

- **CPU 侧**：CPU 往 `$8000-$FFFF` 写值是在给 MMC3 下命令（"把 5 号 8 KiB bank 放到 `$8000`"），所以有 `cpu_we`/`cpu_dout` 写端口。
- **PPU 侧**：`ppu_addr` 翻译 CHR 地址；`ppu_a12` 是**独立的一根线**，专门给 IRQ 用（关心第 12 位何时跳变，不是地址本身）。
- **状态**：MMC3 要"记住"bank 号和计数器，所以它**有时钟 `clk` 和异步复位 `reset`**——这是它和 NROM 最本质的区别。

上层是 [`33-mapper-dispatch.md`](33-mapper-dispatch.md) 的 `nes_mapper.v`：五个 mapper 子模块都例化出来（MMC3 实例名 `u_mmc3`），按 `mapper_select` 选输出。系统层在 `nes_system_v5/v6` 里接进整机，并**把 `mapper_ppu_a12` 绑成常量 0**，见第 6 节。

---

## 2. 全文（243 行）

```verilog
`timescale 1ns/1ps

module nes_mapper_mmc3 #(
    parameter integer PRG_ADDR_BITS = 17,
    parameter integer CHR_ADDR_BITS = 17,
    parameter integer PRG_SIZE_BYTES = 131072,
    parameter [1:0] MMC3_A12_EDGE = 2'd0,
    parameter integer MMC3_A12_COOLDOWN = 2,
    parameter [2:0] HEADER_MIRRORING = 3'd0,
    parameter MMC3_CHR_RAM = 1'b0
)(
    input wire clk,
    input wire reset,
    input wire [15:0] cpu_addr,
    input wire cpu_we,
    input wire [7:0] cpu_dout,
    input wire [13:0] ppu_addr,
    input wire ppu_a12,
    output wire [PRG_ADDR_BITS-1:0] prg_bank_offset,
    output wire [CHR_ADDR_BITS-1:0] chr_bank_offset,
    output wire [2:0] mirroring,
    output wire prg_ram_enable,
    output wire chr_ram_enable,
    output wire irq,
    output wire [7:0] irq_counter,
    output wire [7:0] irq_latch,
    output wire irq_pending,
    output wire irq_reload,
    output wire irq_enabled,
    output wire a12_filtered,
    output wire [2:0] bank_select,
    output wire [5:0] prg_bank6,
    output wire [5:0] prg_bank7,
    output wire prg_mode,
    output wire chr_inversion,
    output wire [7:0] ram_protect
);

localparam [7:0] MMC3_LAST_BANK_8K = (PRG_SIZE_BYTES >> 13) - 1;
localparam [7:0] MMC3_SECOND_LAST_BANK_8K = (PRG_SIZE_BYTES >> 13) - 2;
localparam [7:0] MMC3_A12_COOLDOWN_VALUE = MMC3_A12_COOLDOWN;

reg [2:0] bank_select_r;
reg prg_mode_r;
reg chr_inversion_r;
reg ram_enable_r;
reg [7:0] ram_protect_r;
reg [7:0] chr_bank0_r;
reg [7:0] chr_bank1_r;
reg [7:0] chr_bank2_r;
reg [7:0] chr_bank3_r;
reg [7:0] chr_bank4_r;
reg [7:0] chr_bank5_r;
reg [5:0] prg_bank6_r;
reg [5:0] prg_bank7_r;
reg [7:0] irq_latch_r;
reg [7:0] irq_counter_r;
reg irq_reload_r;
reg irq_enabled_r;
reg irq_pending_r;
reg [2:0] mirroring_r;

reg ppu_a12_d;
reg [7:0] a12_cooldown;

wire write_8000;
wire write_8001;
wire write_A000;
wire write_A001;
wire write_C000;
wire write_C001;
wire write_E000;
wire write_E001;

wire a12_edge;
wire [7:0] irq_counter_next;
reg [7:0] prg_window_bank;
wire [2:0] chr_window_base;
wire [2:0] chr_window_index;
reg [7:0] chr_window_bank;
wire [PRG_ADDR_BITS-1:0] prg_window_ext;
wire [CHR_ADDR_BITS-1:0] chr_window_ext;

assign write_8000 = cpu_we && (cpu_addr[15:13] == 3'b100) && !cpu_addr[0];
assign write_8001 = cpu_we && (cpu_addr[15:13] == 3'b100) && cpu_addr[0];
assign write_A000 = cpu_we && (cpu_addr[15:13] == 3'b101) && !cpu_addr[0];
assign write_A001 = cpu_we && (cpu_addr[15:13] == 3'b101) && cpu_addr[0];
assign write_C000 = cpu_we && (cpu_addr[15:13] == 3'b110) && !cpu_addr[0];
assign write_C001 = cpu_we && (cpu_addr[15:13] == 3'b110) && cpu_addr[0];
assign write_E000 = cpu_we && (cpu_addr[15:13] == 3'b111) && !cpu_addr[0];
assign write_E001 = cpu_we && (cpu_addr[15:13] == 3'b111) && cpu_addr[0];

assign a12_edge = (MMC3_A12_EDGE == 2'd0)
    ? (ppu_a12 & ~ppu_a12_d)
    : (~ppu_a12 & ppu_a12_d);
assign a12_filtered = (a12_cooldown == 8'd0) && a12_edge;
assign irq_counter_next = (irq_reload_r || (irq_counter_r == 8'd0))
    ? irq_latch_r
    : (irq_counter_r - 8'd1);

always @* begin
    case (cpu_addr[14:13])
        2'b00: prg_window_bank = prg_mode_r ? MMC3_SECOND_LAST_BANK_8K : {2'b00, prg_bank6_r};
        2'b01: prg_window_bank = {2'b00, prg_bank7_r};
        2'b10: prg_window_bank = prg_mode_r ? {2'b00, prg_bank6_r} : MMC3_SECOND_LAST_BANK_8K;
        default: prg_window_bank = MMC3_LAST_BANK_8K;
    endcase
end

assign chr_window_base = ppu_addr[12]
    ? {1'b1, ppu_addr[11:10]}
    : {2'b00, ppu_addr[11]};

assign chr_window_index = chr_inversion_r
    ? (chr_window_base ^ 3'b100)
    : chr_window_base;

always @* begin
    case (chr_window_index)
        3'd0: chr_window_bank = chr_bank0_r;
        3'd1: chr_window_bank = {chr_bank0_r[7:1], 1'b1};
        3'd2: chr_window_bank = chr_bank1_r;
        3'd3: chr_window_bank = {chr_bank1_r[7:1], 1'b1};
        3'd4: chr_window_bank = chr_bank2_r;
        3'd5: chr_window_bank = chr_bank3_r;
        3'd6: chr_window_bank = chr_bank4_r;
        default: chr_window_bank = chr_bank5_r;
    endcase
end

assign prg_window_ext = {{(PRG_ADDR_BITS-8){1'b0}}, prg_window_bank};
assign chr_window_ext = {{(CHR_ADDR_BITS-8){1'b0}}, chr_window_bank};

assign prg_bank_offset = (prg_window_ext << 13) | {{(PRG_ADDR_BITS-13){1'b0}}, cpu_addr[12:0]};
assign chr_bank_offset = (chr_window_ext << 10) | {{(CHR_ADDR_BITS-10){1'b0}}, ppu_addr[9:0]};
// chr_bank_offset is the FINAL CHR byte address, not a displacement to be added
// to somewhere else. ppu_addr must be the LOCAL CHR byte address the PPU presents
// on its chr_addr port; the 1 KiB window placement is applied here and the memory
// owner indexes CHR with the result directly. ppu_addr[13] (PPUCTRL[4]/[5], the
// pattern-table select) is deliberately dropped: it is a PPU-internal decode, not
// a cartridge address bit. The same dropping is what makes ppu_addr[12] -- the
// A12 line the scanline IRQ counter clocks from -- a distinct, lower address bit.
assign mirroring = mirroring_r;
assign prg_ram_enable = ram_enable_r;
assign chr_ram_enable = MMC3_CHR_RAM;
assign irq = irq_enabled_r && irq_pending_r;
assign irq_counter = irq_counter_r;
assign irq_latch = irq_latch_r;
assign irq_pending = irq_pending_r;
assign irq_reload = irq_reload_r;
assign irq_enabled = irq_enabled_r;
assign bank_select = bank_select_r;
assign prg_bank6 = prg_bank6_r;
assign prg_bank7 = prg_bank7_r;
assign prg_mode = prg_mode_r;
assign chr_inversion = chr_inversion_r;
assign ram_protect = ram_protect_r;

always @(posedge clk or posedge reset) begin
    if (reset) begin
        bank_select_r <= 3'd0;
        prg_mode_r <= 1'b0;
        chr_inversion_r <= 1'b0;
        ram_enable_r <= 1'b0;
        ram_protect_r <= 8'h00;
        chr_bank0_r <= 8'd0;
        chr_bank1_r <= 8'd0;
        chr_bank2_r <= 8'd0;
        chr_bank3_r <= 8'd0;
        chr_bank4_r <= 8'd0;
        chr_bank5_r <= 8'd0;
        prg_bank6_r <= 6'd0;
        prg_bank7_r <= 6'd1;
        irq_latch_r <= 8'd0;
        irq_counter_r <= 8'd0;
        irq_reload_r <= 1'b0;
        irq_enabled_r <= 1'b0;
        irq_pending_r <= 1'b0;
        mirroring_r <= HEADER_MIRRORING;
        ppu_a12_d <= 1'b0;
        a12_cooldown <= 8'd0;
    end else begin
        ppu_a12_d <= ppu_a12;

        if (a12_cooldown != 8'd0)
            a12_cooldown <= a12_cooldown - 8'd1;
        else if (a12_filtered)
            a12_cooldown <= MMC3_A12_COOLDOWN_VALUE;

        if (a12_filtered) begin
            irq_counter_r <= irq_counter_next;
            irq_reload_r <= 1'b0;
            if ((irq_counter_next == 8'd0) && irq_enabled_r)
                irq_pending_r <= 1'b1;
        end

        if (write_8000) begin
            bank_select_r <= cpu_dout[2:0];
            prg_mode_r <= cpu_dout[6];
            chr_inversion_r <= cpu_dout[7];
            ram_enable_r <= cpu_dout[5];
            if (!cpu_dout[5])
                ram_protect_r <= 8'h00;
        end

        if (write_8001) begin
            case (bank_select_r)
                3'd0: chr_bank0_r <= {cpu_dout[7:1], 1'b0};
                3'd1: chr_bank1_r <= {cpu_dout[7:1], 1'b0};
                3'd2: chr_bank2_r <= cpu_dout;
                3'd3: chr_bank3_r <= cpu_dout;
                3'd4: chr_bank4_r <= cpu_dout;
                3'd5: chr_bank5_r <= cpu_dout;
                3'd6: prg_bank6_r <= cpu_dout[5:0];
                default: prg_bank7_r <= cpu_dout[5:0];
            endcase
        end

        if (write_A000)
            mirroring_r <= cpu_dout[0] ? 3'd0 : 3'd1;

        if (write_A001) begin
            if (ram_enable_r)
                ram_protect_r <= cpu_dout;
        end

        if (write_C000)
            irq_latch_r <= cpu_dout;

        if (write_C001)
            irq_reload_r <= 1'b1;

        if (write_E000) begin
            irq_enabled_r <= 1'b0;
            irq_pending_r <= 1'b0;
        end

        if (write_E001)
            irq_enabled_r <= 1'b1;
    end
end

endmodule
```

---

## 3. 逐段精读

### 3.1 参数与 `localparam`
| 参数 | 含义 | 白话 |
|---|---|---|
| `PRG_ADDR_BITS` / `CHR_ADDR_BITS` | 输出偏移位宽 | 默认 17 位，够 128 KiB |
| `PRG_SIZE_BYTES` | 这张卡 PRG 多大 | 默认 128 KiB，决定末档 bank 号 |
| `MMC3_A12_EDGE` | 认 A12 的哪种沿 | 0=上升沿（标准），1=下降沿（submapper 3 clone） |
| `MMC3_A12_COOLDOWN` | 接受一个沿后静默几拍 | 默认 2，滤掉同一扫描线内的抖动 |
| `HEADER_MIRRORING` | 复位时的镜像模式 | 从 iNES 头带进来 |
| `MMC3_CHR_RAM` | CHR 是不是 RAM | 本模块只透传到 `chr_ram_enable` |

`MMC3_LAST_BANK_8K = (PRG_SIZE_BYTES >> 13) - 1`：`>> 13` 是"除以 8 KiB"（8192 = 2^13），得到 PRG 有多少个 8 KiB bank；减 1 是**最后一个** bank，`MMC3_SECOND_LAST_BANK_8K` 减 2 是**倒数第二个**。这两个是 **elaboration 期常量**（综合前算好），所以 `$C000`/`$E000` 的固定窗不需要运行期比较；128 KiB 时它们是 15（`$1E000`）和 14（`$1C000`）。

### 3.2 寄存器声明
`reg` 那一大串就是 MMC3 要记住的全部东西，分四组：控制位（`bank_select_r`/`prg_mode_r`/`chr_inversion_r`/`ram_enable_r`/`ram_protect_r`）、8 个 bank 号（`chr_bank0..5_r` + `prg_bank6/7_r`）、IRQ 状态（`irq_latch_r`/`irq_counter_r`/`irq_reload_r`/`irq_enabled_r`/`irq_pending_r`）、A12 用（`ppu_a12_d` 上一拍 A12 + `a12_cooldown` 静默倒计时）。带 `_r` 后缀是本项目对"寄存器"的命名。

### 3.3 写译码：8 个 `write_*`
```verilog
assign write_8001 = cpu_we && (cpu_addr[15:13] == 3'b100) && cpu_addr[0];
```
所有写都落在 `$8000-$FFFF`，用**高 3 位 `[15:13]`** 分四区、再用**最低位 `[0]`** 分奇偶：

| 写脉冲 | `[15:13]` | `[0]` | 地址（含别名） | 作用 |
|---|---|---|---|---|
| `write_8000` | `100` | 0 | `$8000`、`$8002`… | bank 选择 + 4 个控制位 |
| `write_8001` | `100` | 1 | `$8001`、`$8003`… | 往选中的 bank 寄存器写数据 |
| `write_A000` | `101` | 0 | `$A000`… | 改镜像模式 |
| `write_A001` | `101` | 1 | `$A001`… | 写 PRG RAM 保护位 |
| `write_C000` | `110` | 0 | `$C000`… | 写 IRQ latch |
| `write_C001` | `110` | 1 | `$C001`… | 置 IRQ reload 请求 |
| `write_E000` | `111` | 0 | `$E000`… | 关 IRQ + 清 pending（ack） |
| `write_E001` | `111` | 1 | `$E001`… | 开 IRQ |

真实卡带译码是 `addr & $E001`，其余地址位不管，所以 `$8002` 和 `$8000` 是**同一个寄存器**（别名）；`$7FFF`（`[15:13]=011`）谁都对不上，写被忽略（`test_unmapped_writes` 覆盖）。

### 3.4 A12 边沿检测、cooldown 与计数器"下一拍值"
```verilog
assign a12_edge = (MMC3_A12_EDGE == 2'd0) ? (ppu_a12 & ~ppu_a12_d) : (~ppu_a12 & ppu_a12_d);
assign a12_filtered = (a12_cooldown == 8'd0) && a12_edge;
assign irq_counter_next = (irq_reload_r || (irq_counter_r == 8'd0)) ? irq_latch_r : (irq_counter_r - 8'd1);
```
- `ppu_a12_d` 是 `ppu_a12` 的**上一拍值**（时序块里每拍刷新）。拿"这拍"与"上一拍"比较，跳变的那一瞬 `a12_edge` 就是 1——这就是**边沿检测**。
- `a12_filtered` 再与上 `a12_cooldown == 0`：刚接受过一个沿、还在静默期的边沿被丢掉，这是**去抖**，防止一条扫描线内 A12 多次跳变被数成好几条线。
- `irq_counter_next` 是计数器**下一拍值**：有 reload 请求或当前已是 0，就**重载 latch**，否则**减 1**。注意"当前是 0 也重载"：若 latch=0，计数器永远停 0，于是每个被接受的沿都立刻触发一次 IRQ（`test_irq_zero_latch` 覆盖）。

### 3.5 PRG 窗口（组合，4 个 8 KiB 窗）
用 `cpu_addr[14:13]` 选窗，`prg_mode_r` 决定"可换的 R6"放 `$8000` 还是 `$C000`：

| `[14:13]` | 地址窗 | `prg_mode_r==0` | `prg_mode_r==1` |
|---:|---|---|---|
| `00` | `$8000-$9FFF` | R6 | 固定倒数第二 bank |
| `01` | `$A000-$BFFF` | R7 | R7 |
| `10` | `$C000-$DFFF` | 固定倒数第二 bank | R6 |
| `11` | `$E000-$FFFF` | 固定最后 bank | 固定最后 bank |

精髓是：**`$E000-$FFFF` 永远钉在最后一个 8 KiB bank**（复位向量在这，CPU 从这启动），所以随便切 bank，中断入口都在。模式 0 把 R6 放 `$8000`（适合 32 KiB PRG 的玩法），模式 1 把它挪到 `$C000`。

### 3.6 CHR 窗口（组合，2 KiB/1 KiB 混排 + 反转）
CHR 窗口是 8 KiB（`$0000-$1FFF`）。`chr_window_base` 先算"落在第几号窗"：`ppu_addr[12]=0`（低 4 KiB）当**两个 2 KiB 窗**，看 `[11]` 得索引 0/1；`ppu_addr[12]=1`（高 4 KiB）当**四个 1 KiB 窗**，看 `[11:10]` 得索引 4/5/6/7。窗口到 bank 的映射（`case`）：

| 索引 | 窗口 | 用哪个寄存器 |
|---:|---|---|
| 0 / 1 | `$0000-$07FF` / `$0800-$0FFF` | R0 / `{R0[7:1],1}`（同一 2 KiB 块） |
| 2 / 3 | `$1000-$13FF` / `$1400-$17FF` | R1 / `{R1[7:1],1}` |
| 4 / 5 / 6 / 7 | `$1800`-`$1FFF` 各 1 KiB | R2 / R3 / R4 / R5 |

R0/R1 管 2 KiB 窗，必须 2 KiB 对齐，所以 bit0 被强制 0（写 R0/R1 时 `{cpu_dout[7:1], 1'b0}`）；窗口 1 用 `{R0[7:1],1}`，即 `R0` 与 `R0+1` 拼成一个 2 KiB 块。`chr_inversion_r` 为 1 时 `^ 3'b100` 把 bit2 取反，即 **0↔4、1↔5、2↔6、3↔7**：把"低 4 KiB 用 2 KiB 的 R0/R1、高 4 KiB 用 1 KiB 的 R2-R5"**整个对调**成"低 4 KiB 用 1 KiB、高 4 KiB 用 2 KiB"。游戏靠它把状态栏/背景的图案表布局换顺序。

### 3.7 拼接成字节偏移与输出
`prg_bank_offset = (prg_window_ext << 13) | cpu_addr[12:0]`：bank 号 `<< 13`（乘 8 KiB）得窗口起点，再或上窗口内偏移。`chr_bank_offset = (chr_window_ext << 10) | ppu_addr[9:0]`：bank 号 `<< 10`（乘 1 KiB）得起点。结果 `chr_bank_offset` 是**最终字节地址**（不是位移），memory owner 直接索引 CHR；注释强调 `ppu_addr[13]`（图案表选择）被**有意丢掉**，正因为丢了它 `ppu_addr[12]` 才是那根独立 A12。

功能输出只有 `mirroring`/`prg_ram_enable`/`chr_ram_enable`/`irq` 与两个 offset；`irq = irq_enabled_r && irq_pending_r`（使能且挂起才拉高）。从 `irq_counter` 到 `ram_protect` 的十几根全是**只读观测口**（`nes_mapper.v` 转成 `mmc3_*` 给 testbench），性质同 `dbg_*`，不影响逻辑。

### 3.8 时序块：复位与寄存器写入
异步复位把所有寄存器清成已知值（`prg_bank6_r=0`、`prg_bank7_r=1`、CHR bank 全 0、IRQ 全关、`mirroring_r=HEADER_MIRRORING`）；`prg_bank7_r=1` 是 MMC3 的经典初值。非复位路径顺序：存上一拍 A12 → 走 cooldown → 若 `a12_filtered` 就更新计数器并清 `irq_reload_r`（"到 0 且已使能"时置 pending）→ 处理 8 个写分支。

**两寄存器协议**：`$8000` 只写"选哪个号"（存 `bank_select_r`），`$8001` 才写数据，且按**上一次 `$8000` 存的 `bank_select_r`** 决定写哪个寄存器（`case (bank_select_r)`）。顺序不能反：先 `$8000` 再 `$8001`。bit2-0 选号、bit5 使能 PRG RAM（为 0 时顺带清 `ram_protect`）、bit6 PRG 模式、bit7 CHR 反转；`$8001` 写 R0/R1 丢 bit0、写 R6/R7 只取低 6 位。`$A000` 用 bit0 定镜像（1=水平、0=垂直）；`$A001` 只在 `ram_enable_r` 为 1 时写保护位。`$C000` 写 latch、`$C001` 置 reload；`$E000` 关使能 + 清 pending（ack），`$E001` 只开使能。

---

## 4. 端口表
| 端口 | 方向 | 位宽 | 作用 |
|---|---|---|---|
| `clk` / `reset` | in | 1 | 寄存器时钟 / 高有效异步复位 |
| `cpu_addr` | in | 16 | 写译码用 `[15:13]`+`[0]`，PRG 窗口用 `[14:13]` |
| `cpu_we` / `cpu_dout` | in | 1 / 8 | CPU 写周期 / 写数据 |
| `ppu_addr` | in | 14 | PPU 图案表地址（CHR 翻译用） |
| `ppu_a12` | in | 1 | **独立**的 PPU A12，供扫描线 IRQ 计数 |
| `prg_bank_offset` | out | 17 | PRG ROM 字节偏移 |
| `chr_bank_offset` | out | 17 | **最终** CHR 字节地址 |
| `mirroring` | out | 3 | 0=水平、1=垂直（`$A000` 决定） |
| `prg_ram_enable` | out | 1 | `$6000-$7FFF` 是否有 PRG RAM（`$8000` bit5） |
| `chr_ram_enable` | out | 1 | 透传 `MMC3_CHR_RAM` |
| `irq` | out | 1 | `irq_enabled_r && irq_pending_r` |
| `irq_counter`…`ram_protect` | out | — | 只读观测（转成 `mmc3_*`，不参与逻辑） |

功能输出其实只有六个，其余都是给 testbench 的观测口。

---

## 5. 代入数字走一遍
设 `PRG_SIZE_BYTES = 131072`（128 KiB，16 个 8 KiB bank）。

**A. 复位态**（`prg_mode_r=0`、R6=0、R7=1）：`$8000`→bank 0（`$00000`）、`$A000`→bank 1（`$02000`）、`$C000`→倒数第二 bank 14（`$1C000`）、`$E000`→bank 15（`$1E000`）——即 `test_reset_state` 的期望。

**B. 切 bank**：写 `$8000=$06`（选 R6）、写 `$8001=$05`。此后 `$8000` 读到 bank 5（`$0A000`）、`$9FFF` 是 `$0BFFF`；`$E000` 仍 bank 15 不动。

**C. 切 PRG 模式**：写 `$8000=$C6`（bit7=1 反转 CHR、bit6=1 模式 1、bit2-0=6 选 R6）。此时 `$8000` 变**倒数第二 bank**（`$1C000`），`$C000` 变 **R6**（`$0A000`）——固定档只在 `$8000`/`$C000` 之间对调。

**D. CHR 反转**：写 R0=$07、R1=$09、R2=$0A、R3=$0B、R4=$0C、R5=$0D（R0/R1 的 bit0 被吃，实际存 `$06`/`$08`）。不反转时 `$0000`→窗 0 用 R0 → bank 6 → `chr_bank_offset=$1800`，`$0800`→窗 1 用 R0 高半 → bank 7 → `$1C00`，`$1000`→窗 4 用 R2 → bank 10 → `$2800`。写 `$8000=$80` 反转后整体对调：`$0000` 改用 R2（`$2800`），`$1000` 改用 R0（`$1800`）。`test_chr_inversion` 逐点验证这个交换。

**E. IRQ 一个周期**：写 `$C000=$02`（latch=2）、`$C001`（请求 reload）、`$E001`（开 IRQ）。之后每个**被接受的** A12 上升沿：第 1 沿装载 latch→counter=2（不上线），第 2 沿 counter=1，第 3 沿 counter=0 且置 `irq_pending`→`irq` 拉高。写 `$E000` 关 IRQ + 清 pending，`irq` 才落下。

---

## 6. 常见疑问
**Q：`$8000` 和 `$8001` 能乱序写吗？**
A：不能。`$8001` 写哪个 bank 取决于 `bank_select_r`（上一次 `$8000` 的值），必须"先选号、再写数据"。

**Q：为什么 R6/R7 只取低 6 位、R0/R1 要丢 bit0？**
A：R6/R7 是 8 KiB bank 号，6 位够表示 64 个 bank（512 KiB）；R0/R1 管 2 KiB 窗，必须 2 KiB 对齐，所以 bit0 恒 0。

**Q：A12 沿为什么要 cooldown 过滤？**
A：一条扫描线里 PPU 会多次取图案，A12 可能抖动。`a12_filtered = (cooldown==0) && edge` 保证接受一个沿后至少静默 `MMC3_A12_COOLDOWN` 拍（默认 2，即下一次接受至少隔 3 拍），避免把一条扫描线数成好几条。

**Q：为什么复位后 `irq` 一定是 0？**
A：复位清了 `irq_enabled_r` 和 `irq_pending_r`，`irq = enabled && pending = 0`。且 pending **只在 `irq_enabled_r` 为 1 时**才可能被置起（时序块里 `&& irq_enabled_r` 的门），所以"先数到 0、后开使能"不会回溯触发（`test_irq_assert_and_ack` 的 "enable does not retrofire"）。

**Q：为什么说"`mapper_ppu_a12` 仍绑 0，所以本模块的 IRQ 在 system 里不能自时钟"？**
A：本模块的 A12 来自端口 `ppu_a12`，对应上层 `nes_mapper` 的 `ppu_a12`。但 `nes_system_v5.v`/`nes_system_v6.v` 里写着 `wire mapper_ppu_a12 = 1'b0;` 再接到 `.ppu_a12(mapper_ppu_a12)`。于是整机送到本模块的 `ppu_a12` **恒为 0**，永远没有边沿 → `a12_filtered` 永远为 0 → 计数器永不拍 → IRQ 计数这条路在整机里**不发生**（写 `$8000`/`$C000`/`$E000` 的寄存器本身仍生效）。`tb_nes_system_v6.v` 是靠 `force` 强行拉起这条线才验证计数逻辑的。**这是已知的整机缺口，不是本模块的 bug**：本模块在 `tb_nes_mapper_mmc3.v` 里由 testbench 直接驱动 `ppu_a12`，A12/IRQ 逻辑已被单独证明。

**Q：`ppu_addr[13]` 被丢了会不会出事？**
A：这是有意的。`ppu_addr[13]` 是 PPU 内部按 `PPUCTRL` 选的图案表，不是卡带地址位；CHR 只认低 13 位。正因为丢了它，`ppu_addr[12]` 才是那根独立 A12。

---

## 7. 你应该带走的三件事
1. **两寄存器协议**：`$8000` 选号、`$8001` 写数据；8 个 `write_*` 只靠 `cpu_addr[15:13]`+`[0]` 译码，其余地址位是别名。
2. **窗口 = 组合 `case` + 移位拼接**：PRG 2 种模式 × 4 个 8 KiB 窗，CHR 2 KiB/1 KiB 混排 + `^ 3'b100` 反转；固定档由 `PRG_SIZE_BYTES` 在 elaboration 期算成常量。
3. **A12 扫描 IRQ = 边沿检测 + cooldown + 装载/递减/到 0 挂起**，`irq = enabled && pending`；而整机里 `ppu_a12` 仍绑 0，这条路还没接上。

下一篇 [`36-line-buffer.md`](36-line-buffer.md) 看视频侧的"双 bank 乒乓行缓冲"。
