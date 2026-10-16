# 32 卡带 ROM 进 bitstream：`nes_cart_rom.v`

一张 NES 卡带里有两块只读内容：**PRG ROM**（CPU 跑的程序）和 **CHR ROM**（PPU 用的图案）。软件模拟器把 `.nes` 文件 `fread` 进 `uint8_t prg_rom[]` / `chr_rom[]`；本项目用 `$readmemh` 在**综合期**把同样的内容灌进 BRAM。这一篇拆的就是这个模块，它也是整个设计里**唯一承载卡带内容的地方**。

- 源码：[`rtl/nes_core/cart/nes_cart_rom.v`](../../rtl/nes_core/cart/nes_cart_rom.v)
- 合同与证据：[`../modules/cart-rom.md`](../modules/cart-rom.md)
- 测试目标：`cart-rom-tb`（[`tb/cart/tb_nes_cart_rom.v`](../../tb/cart/tb_nes_cart_rom.v)），跑它：`.\tools\sim_all.ps1 -Mode cart-rom-tb`
- 前置：[`01-verilog-basics.md`](01-verilog-basics.md)、[`02-project-conventions.md`](02-project-conventions.md)、结构范本 [`10-mapper-nrom.md`](10-mapper-nrom.md)
- 主机侧工具：[`../tools/nes2hex.md`](../tools/nes2hex.md)（把 `.nes` 转成两个 hex）

---

## 1. 定位：它在系统里的哪一环

```text
 nes_system_v6（核内）： mapper_prg_bank_offset ─► prg_addr ─► prg_rdata（1 clk 寄存读）─► cart_din
                       [PRG 半边：reg [7:0] prg_rom[0:131071]]
 nes_zynq_top（平台）：  chr_req/chr_addr ─► ce_ppu 门控读 ─► chr_rdata ─► 核的 chr_rdata 输入
                       [$2007 写 ─► chr_ram_enable 门控写]（CHR 半边：chr_rom[0:8191]）
```

**同一个模块被例化两次，位置不同**，因为 Verilog 的层次化引用**只能向下**：

| 半边 | 例化者 | 参数 | 位置 |
|---|---|---|---|
| PRG | `nes_system_v6`（`u_prg_rom`） | `PRG_ENABLE=1`, `CHR_ENABLE=0` | 核**内部** |
| CHR | `nes_zynq_top`（`u_cart_chr`） | `PRG_ENABLE=0`, `CHR_ENABLE=1` | 核**上方**的平台顶层 |

为什么 PRG 必须在核内：`prg_rom` 曾经在 `nes_system_v6` 里声明却没有任何驱动，Vivado 于是把它**溶解掉**（日志 `Synth 8-3848`），贡献 0 逻辑、0 存储；而"从父层去驱动子层的数组"在 Verilog 里不可行，因为层次化引用只能指向下方。CHR 相反：`chr_rdata` 本来就是核的一个**输入端口**，核只把它透出去，所以 CHR 一半可以坐在核上方，由平台顶层提供。`nes_system_v6` 一行都不用改。

软件对比（最值得记住的一句）：软件 ROM 是**运行期**从文件系统读的，重启就能换卡带；本模块的 ROM **就是 bitstream 的一部分**，换卡带要**重新综合**。

---

## 2. 全文代码

文件头（第 3–141 行）是一篇小文档，列了设计取舍；下面是要读的模块本体（第 143–222 行）：

```verilog
module nes_cart_rom #(
    parameter integer PRG_SIZE_BYTES = 131072,
    parameter integer PRG_ADDR_BITS  = 17,
    parameter integer PRG_ENABLE     = 1,
    parameter integer CHR_ENABLE     = 1,
    parameter integer CHR_SIZE_BYTES = 8192,
    parameter integer CHR_LOCAL_BITS = 13,
    parameter integer CHR_ADDR_BITS  = 17,
    parameter PRG_INIT_FILE = "rtl/nes_core/cart/prg_placeholder.hex",
    parameter CHR_INIT_FILE = "rtl/nes_core/cart/chr_placeholder.hex"
)(
    input  wire                     clk,
    input  wire                     reset,

    input  wire                     prg_en,
    input  wire [PRG_ADDR_BITS-1:0] prg_addr,
    output reg  [7:0]               prg_rdata,

    input  wire                     ce_ppu,
    input  wire                     chr_req,
    input  wire [CHR_ADDR_BITS-1:0] chr_addr,
    output reg  [7:0]               chr_rdata,
    input  wire [13:0]              chr_waddr,
    input  wire                     chr_we,
    input  wire [7:0]               chr_wdata,
    input  wire                     chr_ram_enable
);

    generate

    if (PRG_ENABLE != 0) begin : g_prg
        reg [7:0] prg_rom [0:PRG_SIZE_BYTES-1];

        initial
            $readmemh(PRG_INIT_FILE, prg_rom);

        always @(posedge clk) begin
            if (reset)
                prg_rdata <= 8'h00;
            else if (prg_en)
                prg_rdata <= prg_rom[prg_addr];
        end
    end else begin : g_prg_off
        always @(posedge clk) begin
            if (reset)
                prg_rdata <= 8'h00;
        end
    end

    if (CHR_ENABLE != 0) begin : g_chr
        reg [7:0] chr_rom [0:CHR_SIZE_BYTES-1];
        wire [CHR_LOCAL_BITS-1:0] chr_rindex;
        wire [CHR_LOCAL_BITS-1:0] chr_windex;

        assign chr_rindex = chr_addr[CHR_LOCAL_BITS-1:0];
        assign chr_windex = chr_waddr[CHR_LOCAL_BITS-1:0];

        initial
            $readmemh(CHR_INIT_FILE, chr_rom);

        always @(posedge clk) begin
            if (reset)
                chr_rdata <= 8'h00;
            else begin
                if (ce_ppu && chr_req)
                    chr_rdata <= chr_rom[chr_rindex];
                if (chr_ram_enable && chr_we)
                    chr_rom[chr_windex] <= chr_wdata;
            end
        end
    end else begin : g_chr_off
        always @(posedge clk) begin
            if (reset)
                chr_rdata <= 8'h00;
        end
    end

endgenerate

endmodule
```

读三遍会发现整份代码只有两类东西：**两个 generate 块**（每块里一个数组 + 一个 `always`），以及**两个复位清零的输出寄存器**。没有状态机，没有计数器。

---

## 3. 逐段精读

### 3.1 为什么 ROM 必须进 bitstream

文件头第 3–8 行的话要原样记住：

> 在这块 Zynq 板上，**TF 卡和 QSPI flash 挂在 PS 的 MIO 引脚上，PL 够不着**。所以一块**不在 bitstream 里的 ROM，就是 PL 看不见的 ROM**。

PL 没有卡带读取通路、没有 boot loader、也没有任何运行期"从外部把字节读进 ROM 数组"的机制。因此换 ROM = 换 elaboration 期参数 = 重新综合出 bitstream。仓库里长期只有合成的占位数据（`prg_placeholder.hex` / `chr_placeholder.hex`），它们是确定性的可复现内容，不是某个具体游戏。

### 3.2 参数列表

| 参数 | 默认 | 白话 |
|---|---|---|
| `PRG_SIZE_BYTES` | `131072` | PRG 数组深度 = 128 KiB |
| `PRG_ADDR_BITS` | `17` | PRG 下标位宽，`2^17 = 131072` |
| `PRG_ENABLE` | `1` | 要不要造 PRG 半边 |
| `CHR_ENABLE` | `1` | 要不要造 CHR 半边 |
| `CHR_SIZE_BYTES` | `8192` | CHR 数组深度 = 8 KiB |
| `CHR_LOCAL_BITS` | `13` | CHR 只用低 13 位索引 |
| `CHR_ADDR_BITS` | `17` | 输入 `chr_addr` 的位宽（mapper 翻译后的宽度） |
| `PRG_INIT_FILE` / `CHR_INIT_FILE` | 两个占位 hex | `$readmemh` 的源文件 |

`PRG_ADDR_BITS` 和 `PRG_SIZE_BYTES` **不是用 `$clog2` 派生的**，而是照抄 `nes_system_v6` 自己的参数。原因写在文件头：`$clog2` 是 Verilog-2005，而本文件要在 `-g2001` 和 `-g2012` 下都能编译。调用方的不变量是 **`1 << PRG_ADDR_BITS == PRG_SIZE_BYTES`**——这正是 `prg_rom[prg_addr]` 不会越界的原因。

### 3.3 `initial $readmemh`：把 hex 变成 BRAM 的初始值

```verilog
reg [7:0] prg_rom [0:PRG_SIZE_BYTES-1];
initial
    $readmemh(PRG_INIT_FILE, prg_rom);
```

这是**可综合 BRAM 初始化的标准惯用法**。仿真时，`initial` 在"时间 0"被执行一次，把 hex 文件里的每个 8 位值填进数组。综合时，工具把同一份内容转成 BRAM 的 **INIT 属性**，于是 ROM 内容**就是 bitstream**。`$readmemh` 的 "h" 表示 hex。

三条必读性质：

1. **复位清不掉数组。** 复位块只把 `prg_rdata` / `chr_rdata` 置 `8'h00`，数组内容在 bitstream 里，逻辑根本无法在运行期改变它。这不是"没做"，是**做不到**，也是**不需要**：真实卡带 ROM 同样是只读、上电即在。
2. **`$readmemh` 给的条目少于数组深度时，剩下部分是未定义的。** 所以主机侧必须把镜像补满到完整深度（用 `00`）。`nes2hex.ps1` 就是这么做的：一个 16 KiB 游戏在 128 KiB 数组里是 87.5% 填充，这是预期结果而非缺陷。
3. **找不到文件、或文件长度不对时，Vivado 会静默把数组优化掉。** Block RAM Tile 数会从 50 掉到 **0**，而设计仍然过时序、仍然落位全部引脚——一份"看起来完美但不携带卡带"的 bitstream。对应的检查是 `report_utilization` 报 50 个 Block RAM Tile 而不是 0。

### 3.4 `generate if (PRG_ENABLE!=0)`：按参数决定造不造

```verilog
generate
  if (PRG_ENABLE != 0) begin : g_prg      // 造数组：reg prg_rom[...] + initial + always
  end else begin : g_prg_off              // 不造数组，只让输出寄存器被复位驱动
endgenerate
```

`generate` 块里的 `if` 是 **elaboration 期**（综合前）的分支：`PRG_ENABLE` 是常量，工具只造其中一支。`begin : g_prg` 给生成的电路起名字。

**开关的作用是省资源、避免重复**：板子在核上方例化本模块一次、两个半边都开；核在内部再例化一次，只开 PRG。若没有这两个开关，核的实例会**再建一份 8 KiB CHR 数组并再 `$readmemh` 一遍**——CHR hex 被读两次、多推断出 8 KiB 内容。被关掉的那一半，**数组根本不声明**（它在 generate 里面），所以任何东西都无法推断它；但那一半的输出寄存器**仍然被驱动**（只在复位下驱动），因此没有任何输出会悬空。

### 3.5 PRG 通路：一 clk 寄存读为什么是正确的字节

```verilog
always @(posedge clk) begin
    if (reset)     prg_rdata <= 8'h00;
    else if (prg_en) prg_rdata <= prg_rom[prg_addr];
end
```

这是**在时钟沿寄存的读**，所以 `prg_rdata` 比 `prg_addr` **晚一拍**。而核里看起来是**组合读**：

```verilog
assign prg_readback = prg_rom[prg_index];   // nes_system_v6
assign cart_din = (cart_addr[15] == 1'b1) ? prg_rdata : 8'h00;
```

块 RAM 有一 clk 读延迟，回答不了组合读——但它**不需要**回答，因为地址极稳：

- `mapper_prg_bank_offset` 是 `nes_cpu6502` 的 `bus_addr` 的 `always @*` 函数，而 `bus_addr` 只在 `ce_cpu` 为高（每 12 clk 一次的 posedge）时才动。
- 所以 PRG 地址在 `div_phase 1..11` 加上接下来的 `div_phase 0`，共 **12 clk 内完全不动**。
- CPU 在"前沿 `div_phase == 0`"的那个 posedge 锁存 `bus_din`，于是它取到的是本模块**早一 clk**、在**同一个地址**上寄存下来的字节。

一句话：**BRAM 晚一拍没关系，因为地址稳定了 12 拍。** `prg_en` 只为功耗存在：为低时 `prg_rdata` **保持**上一个字节（不是返回 0），所以只能在地址也被保持的地方门控它。

### 3.6 CHR 读延迟合同：逐 clk 讲清 arm / consume

这是本模块**最不能破的合同**。`nes_ppu2c02.v` 的文件头声明这条链：

```text
v_addr -> chr_addr -> mapper -> chr_final_addr -> CHR memory -> chr_rdata
```

链**零余量**：`chr_rdata` 在每个 `ce_ppu` 沿被寄存，链中任何位置插一级寄存器都**不会报错，只会静默返回上一个图案字节**。算术如下（`clk` = 21.477272727 MHz，`div_phase` 跑 0..11，每 clk 自增一次）：

- `ce_ppu = (div_phase[1:0] == 2'b00)`，所以在 **`div_phase` 0、4、8** 时为高：一个 PPU dot 是 4 clk，12 clk 里 enable 高 3 次。`ce` 的**沿**是"结束 `div_phase` 0 / 4 / 8"的那三个 posedge。
- **arm**：`nes_system_v6` 在"前沿 `div_phase == 8`"的**那一 clk** 抬 `ppu_chr_rd_arm`，于是 `div_phase 8` 期间 `chr_req` 为高、`chr_addr` 携带 `v_addr[13:0]`（`div_phase 8` 本身就是 `ce_ppu` beat）；本模块在那个沿锁存 `chr_addr`，于是从 `div_phase 9` 开始 `chr_rdata` 就保持 `chr_rom[chr_addr[12:0]]`。
- **consume**：PPU 的读缓冲在 arm 之后的**下一个 `ce` 沿**被装载，也就是"结束**下一个 dot** 的 `div_phase 0`"的那个沿——因为 arm 沿与它之间隔着 `div_phase 9, 10, 11, 0`。
- **窗口**：地址在 `div_phase 8` 上总线，到 `div_phase 0` 沿的 consume，是 **5 个 clk**（8、9、10、11、0）；读本身只花 **1** 个 clk（arm 沿）；**余量 4 个 clk = 186 ns**，而且字节在这整段窗口里**一直保持**，因为 `div_phase 9` 到 consume 之间没有任何东西重新锁存它。

**为什么读必须门控在 `ce_ppu`、而不是 `clk`：** 一个每 `clk` 都读的版本会在 `div_phase 9` 末尾**再次**锁存 `chr_addr`——那时取数单元（它们在每个 `ce` 沿寄存自己的 `chr_addr`）已经把某个取数地址放上了总线——于是会在 CPU 消费前 **3 clk** 用取数字节覆盖掉已 arm 的字节。这就是**陈旧字节失败模式，而且没有任何东西会报告它**。实现只有一行：

```verilog
if (ce_ppu && chr_req)
    chr_rdata <= chr_rom[chr_rindex];
```

门控在 `ce_ppu && chr_req` 还尊重了总线的两条性质：`chr_addr` 在 beat 之外是陈旧的，所以 **`chr_req` 是地址的唯一限定**；当一个 `$2007` arm 紧挨着一个取数 beat 时，`chr_req` **可以连续两个 `ce` 为高**，两个 beat 都要被服务，各自返回各自地址的字节。

### 3.7 CHR 写：只在 `chr_ram_enable` 时到达数组

```verilog
if (chr_ram_enable && chr_we)
    chr_rom[chr_windex] <= chr_wdata;
```

`chr_ram_enable` 就是核的 `mapper_chr_ram_enable`。核侧 `mapper_chr_ram_we`（`nes_mapper.v:221`）= `chr_ram_enable && ppu_we && (ppu_addr[13] == 1'b0)`，本模块实现的 `chr_ram_enable && chr_we` 就是这个表达式（`ppu_we == chr_we`，`ppu_addr == chr_waddr`）。`ppu_addr[13] == 0` 这一项已被隐含：`chr_waddr` 只在 PPU 的 `v_addr < $2000` 保护下才有意义，它强制 `v_addr[14:13] == 0`。

两条后果：

- `chr_ram_enable` 为高（CHR-RAM 卡带）：`$2007` 写真正进入数组，写位置是 `chr_windex = chr_waddr[12:0]`。
- `chr_ram_enable` 为低（CHR-ROM 卡带）：写**不只是**在总线口被丢掉，它**根本到不了数组**。所以 CHR ROM 无法被 `$2007` 写改变，内容**永远是 `$readmemh` 放进去的东西**。

### 3.8 尺寸与别名：`[12:0]` 精确，`[16:13]` 是接受的别名

```verilog
assign chr_rindex = chr_addr[CHR_LOCAL_BITS-1:0];   // 只取低 13 位
```

mapper 翻译出的 17 位 `chr_final_addr` 只用 `[12:0]` 索引，**高于 bit 12 的 bank 位全部被丢弃**：

| 卡带 | CHR 大小 | `[12:0]` 索引的结果 |
|---|---|---|
| NROM / UxROM | 8 KiB | **精确** |
| CNROM | 32 KiB | 别名，bank 折到 0..7 |
| MMC1 | 至多 64 KiB | 别名 |
| MMC3 | 至多 64 KiB | 别名 |

这和 `nes_system_v6` 已记录的 MMC3 CHR bank bit 7 在 `CHR_ADDR_BITS = 17` 上被截断是**同一类已接受限制**。加宽的办法就是抬高 `CHR_LOCAL_BITS` 和 `CHR_SIZE_BYTES`——**纯粹是改参数**。testbench **显式断言**了这个别名，而不是把它留给意外。

---

## 4. 参数与端口表

参数见 3.2 节。端口如下：

| 端口 | 方向 | 位宽 | 合同 |
|---|---|---|---|
| `clk` | in | 1 | 核时钟 21.477272727 MHz。本模块不产生也不消费 `ce`，只对端口给的电平取样 |
| `reset` | in | 1 | 高有效**同步**复位。只清两个输出寄存器 |
| `prg_en` | in | 1 | PRG 读使能。为低时 `prg_rdata` **保持**上一个字节（不是返回 0） |
| `prg_addr` | in | `PRG_ADDR_BITS`=17 | 核内由 `mapper_prg_bank_offset` 驱动，正好同宽 |
| `prg_rdata` | out | 8 | **一 clk 寄存读** |
| `ce_ppu` | in | 1 | PPU dot 使能，核导出的那一个。CHR 读的唯一门控 |
| `chr_req` | in | 1 | CHR 读请求，是 `chr_addr` 有效的**唯一限定** |
| `chr_addr` | in | `CHR_ADDR_BITS`=17 | mapper 翻译后的 `chr_final_addr` |
| `chr_rdata` | out | 8 | 在 **`ce_ppu` 沿**寄存 |
| `chr_waddr` / `chr_we` / `chr_wdata` | in | 14 / 1 / 8 | `$2007` 写地址（自增前的 `v_addr[13:0]`）/ 一 clk 宽写 strobe / 写数据 |
| `chr_ram_enable` | in | 1 | 核的 `mapper_chr_ram_enable`；写只有在它为高时才真正到达数组 |

注意 **`chr_rdata` 是核的输入**，`chr_req` / `chr_addr` / `chr_waddr` / `chr_we` / `chr_wdata` 是核的**输出**。这条总线是**单主多路复用**的：谁赢了 `chr_req`，谁就是那一拍把地址放上 `chr_addr` 的人，本模块没有仲裁要做。

---

## 5. 代入一组地址走一遍

**PRG：CPU 读 `$8000`（NROM-256，`PRG_SIZE_BYTES = 32768`）**

| 步骤 | 值 |
|---|---|
| CPU 地址 | `$8000` |
| mapper 输出（`NROM_MIRROR_16K=0`，取低 15 位） | `prg_addr = 15'h0000` |
| 本模块 | `prg_rdata <= prg_rom[0]` |
| 语义 | `$8000` 处读到的正是 hex 文件**第一个字节**（iNES 头已被 `nes2hex.ps1` 剥掉），不是头字节 `0x4E` |

**CHR：PPU 读 `$1FFF`（一个 `$2007` arm @ `div_phase 8`）**

| 步骤 | 值 |
|---|---|
| PPU 地址 | `$1FFF` |
| mapper 输出（NROM 取低 13 位） | `chr_addr = 17'h01FFF` |
| 本模块索引 | `chr_rindex = chr_addr[12:0] = 13'h1FFF` |
| 数组 | `chr_rom[8191]`（8 KiB 数组最后一个字节） |

时序走一遍（`div_phase` 每 clk +1）：

| clk | `div_phase`（前沿） | `ce_ppu` | 发生什么 |
|---|---|---|---|
| N | 8 | 1 | arm：`chr_req=1`、`chr_addr=$1FFF` |
| N+1 | 9 | 0 | 本模块已锁存，`chr_rdata = chr_rom[13'h1FFF]` |
| N+2、N+3 | 10、11 | 0 | 保持不变（无重锁存） |
| N+4 | 0 | 1 | **consume**：PPU 读缓冲装载这个字节（= arm 沿 + 4 clk） |

`div_phase 9、10、11、0` 之间没有任何东西重新锁存 `chr_rdata`——这正是"字节被保持到 consume"的原因，也是读必须门控 `ce_ppu` 的原因。

---

## 6. 常见疑问

**Q：为什么 `reset` 清不掉 ROM 数组？**
A：数组内容在 bitstream 里（BRAM 的 INIT 属性），运行期逻辑无法改变它。这不是缺陷：真实卡带 ROM 同样是只读、上电即在。`reset` 只清 `prg_rdata` / `chr_rdata` 两个输出寄存器，让复位期间读到 `8'h00`（也是 PPU 记录的 `$2007` fail-safe 值），避免返回 X。

**Q：读晚一拍为什么还能返回正确字节？**
A：因为地址稳定。`mapper_prg_bank_offset` 只在 `ce_cpu` 为高（每 12 clk 一次）时才动，PRG 地址在 12 clk 内不变；CPU 在 `div_phase 0` 沿锁存 `bus_din`，取到的正是本模块早一拍、在同一个地址上寄存的字节。见 3.5。

**Q：CHR 读为什么门控 `ce_ppu` 而不是 `clk`？**
A：每个 `clk` 都读的版本会在 `div_phase 9` 末尾用取数单元放上总线的地址**覆盖**已 arm 的字节，让 CPU 消费到上一个图案字节，而且**不会报任何错**。见 3.6。

**Q：为什么只认 `chr_addr[12:0]`？**
A：CHR 数组只有 8 KiB（`2^13`）。对 NROM / UxROM 精确；对 CNROM / MMC1 / MMC3 是"bank 折叠"的别名，是已接受的限制，加宽只需改 `CHR_LOCAL_BITS` / `CHR_SIZE_BYTES`。见 3.8。

**Q：为什么核里例化时 `CHR_ENABLE=0`？**
A：核够不到 CHR 内容（`chr_rdata` 是它的输入端口），CHR 由平台顶层提供；若核里也开 CHR，就会**再建一份 8 KiB 数组、再 `$readmemh` 一遍**，多推断出 8 KiB 内容。见 3.4。

---

## 7. 你应该带走的三件事

1. **`$readmemh` + `initial` = 可综合的 ROM 初始化**：hex 在综合期变成 BRAM 的 INIT，ROM 内容就是 bitstream；`reset` 清不掉数组，换内容要重新综合。
2. **CHR 读延迟合同是零余量的**：arm 在 `div_phase 8`、consume 在下一个 `ce_ppu` 沿（+4 clk），读必须门控在 `ce_ppu` 而非 `clk`，否则会**静默返回上一个字节**。
3. **一个模块、两次例化、两个开关**：PRG 在核内（`CHR_ENABLE=0`）、CHR 在平台顶层（`PRG_ENABLE=0`），用 `generate` 决定造不造哪一半；`[12:0]` 索引对 8 KiB 精确，对其余是接受的别名。

下一篇 [`33-mapper-dispatch.md`](33-mapper-dispatch.md)：看 `nes_mapper.v` 怎么把这些地址翻译成 `prg_bank_offset` / `chr_final_addr`，并组合分发到 NROM / CNROM / MMC1 / MMC3 各子模块。
