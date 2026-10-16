# 21 逐行精读：`nes_cdc_fifo.v`

前面每个模块都只有一个时钟 `clk`，用 `ce` 分频。这一篇不同：`nes_cdc_fifo.v` 有**两个时钟** `wr_clk` 和 `rd_clk`，数据要从一个时钟域安全地搬到另一个。它就是一个 FIFO（先进先出队列）：写侧往里塞，读侧往外取。

- 源码：[`rtl/nes_core/peripheral/nes_cdc_fifo.v`](../../rtl/nes_core/peripheral/nes_cdc_fifo.v)
- 原理与合同：[`../modules/cdc-fifo.md`](../modules/cdc-fifo.md)
- 测试目标：`cdc-fifo-core`（只编译）、`cdc-fifo-tb`（跑 [`tb/peripheral/tb_nes_cdc_fifo.v`](../../tb/peripheral/tb_nes_cdc_fifo.v)）

---

## 1. 先认识"上游和下游"

```text
core_clk 域（写侧）                              lcd_clk 域（读侧）
音频采样 ──► wr_en/wr_data ──► [ nes_cdc_fifo ] ──► rd_en/rd_data ──► I2S 位串行器
                                wr_clk ▲     ▲ rd_clk
                                       └─────┘
                                  两个时钟互不相关
```

- **谁写**：`nes_audio_i2s` 里的音频采样流，踩 `wr_clk`（即 `core_clk`）。
- **谁读**：从 `rd_data` 取走 32 位立体声样本，踩 `rd_clk`（即 `lcd_clk` / `mclk`），送去 I2S 位串行器。
- **谁例化它**：本仓库唯一使用点是 [`nes_zynq_top.v`](../../rtl/platform/zynq/nes_zynq_top.v) → `nes_audio_i2s` 里的 `u_fifo`，那里把 `ADDR_WIDTH` 从默认 10 改成 6 以省触发器。EP4CE10 平台顶层没有例化它。
- 宽度和深度都是 `parameter`，所以它是通用零件，不含任何 NES 语义。

---

## 2. 全文（162 行）

```verilog
`timescale 1ns/1ps

// nes_cdc_fifo: single-read / single-write asynchronous FIFO for clock domain
// crossing (Verilog-2001, synthesisable).
//
// Structure
//   Two independently clocked pointer pairs, each ADDR_WIDTH+1 bits wide: a
//   binary pointer that addresses the storage array and a Gray pointer that is
//   published to the other domain. The remote Gray pointer passes through a
//   two stage flip-flop synchronizer before it feeds the local flag. Every bit
//   of the array is a pair of flip-flops: wr_clk writes mem[wr_ptr], rd_clk
//   registers mem[rd_ptr] into rd_data, so rd_data is never a combinational
//   read of the array and stays stable between read clock edges. The array
//   itself carries no reset: an entry only becomes meaningful once it has been
//   written, which is exactly what the two pointer flags guarantee.
//
// Full / empty
//   wr_full_next  = (wr_gray_next == {~rd_gray_sync2[PTR_WIDTH-1:PTR_WIDTH-2],
//                                     rd_gray_sync2[PTR_WIDTH-3:0]})
//   rd_empty_next = (rd_gray_next == wr_gray_sync2)
//   Inverting the top two Gray bits of the synchronized remote pointer is the
//   standard "one full turn behind" signature for full, and equality of the
//   whole Gray word is the signature for empty. Gray coding is what makes the
//   comparison safe: only one pointer bit changes per increment, so a
//   synchronized sample can never mix an old and a new bit.
//   ADDR_WIDTH must be >= 2, so the depth is 2**ADDR_WIDTH entries (4 minimum,
//   1024 at the default of 10) and DATA_WIDTH defaults to 32.
//
// Handshake
//   A write commits only while wr_en && !wr_full, a read only while
//   rd_en && !rd_empty. Asserting wr_en while full, or rd_en while empty, is
//   ignored: the pointer does not advance and nothing is stored or fetched.
//   The write side sees a delayed copy of the read pointer, so wr_full may
//   stay asserted for a couple of read clocks after the last entry leaves,
//   and the read side likewise may see rd_empty for a couple of write clocks
//   after the first entry arrives.
//
// Reset
//   wr_reset clears wr_ptr, wr_full and the read pointer synchronizer inside
//   the write domain. rd_reset clears rd_ptr, rd_empty, rd_data and the write
//   pointer synchronizer inside the read domain. The two resets are
//   independent and are never synchronized into the opposite domain. During a
//   reset the cross domain pointers may therefore be inconsistent, and after
//   the reset is released a few entries may be discarded or replayed before
//   the two pointers line up again. Both ends should be reset together.

module nes_cdc_fifo #(
    parameter DATA_WIDTH = 32,
    parameter ADDR_WIDTH = 10
) (
    input  wire                  wr_clk,
    input  wire                  wr_reset,
    input  wire                  wr_en,
    input  wire [DATA_WIDTH-1:0] wr_data,
    output reg                   wr_full,

    input  wire                  rd_clk,
    input  wire                  rd_reset,
    input  wire                  rd_en,
    output reg  [DATA_WIDTH-1:0] rd_data,
    output reg                   rd_empty
);

    localparam integer DEPTH     = (1 << ADDR_WIDTH);
    localparam integer PTR_WIDTH = ADDR_WIDTH + 1;

    localparam [PTR_WIDTH-1:0] PTR_ONE = {{(PTR_WIDTH - 1){1'b0}}, 1'b1};

    reg [DATA_WIDTH-1:0] mem [0:DEPTH-1];

    reg [PTR_WIDTH-1:0] wr_bin;
    reg [PTR_WIDTH-1:0] wr_bin_next;
    reg [PTR_WIDTH-1:0] wr_gray;
    reg [PTR_WIDTH-1:0] wr_gray_next;

    reg [PTR_WIDTH-1:0] rd_bin;
    reg [PTR_WIDTH-1:0] rd_bin_next;
    reg [PTR_WIDTH-1:0] rd_gray;
    reg [PTR_WIDTH-1:0] rd_gray_next;

    (* ASYNC_REG = "TRUE" *) reg [PTR_WIDTH-1:0] rd_gray_sync1;
    (* ASYNC_REG = "TRUE" *) reg [PTR_WIDTH-1:0] rd_gray_sync2;
    (* ASYNC_REG = "TRUE" *) reg [PTR_WIDTH-1:0] wr_gray_sync1;
    (* ASYNC_REG = "TRUE" *) reg [PTR_WIDTH-1:0] wr_gray_sync2;

    wire [PTR_WIDTH-1:0] wr_gray_at_full;
    wire                  wr_full_next;
    wire                  rd_empty_next;

    assign wr_gray_at_full = {~rd_gray_sync2[PTR_WIDTH-1:PTR_WIDTH-2],
                              rd_gray_sync2[PTR_WIDTH-3:0]};
    assign wr_full_next  = (wr_gray_next == wr_gray_at_full);
    assign rd_empty_next = (rd_gray_next == wr_gray_sync2);

    always @* begin
        wr_bin_next  = wr_bin;
        wr_gray_next = wr_gray;
        if (wr_en && !wr_full) begin
            wr_bin_next  = wr_bin + PTR_ONE;
            wr_gray_next = (wr_bin + PTR_ONE) ^ ((wr_bin + PTR_ONE) >> 1);
        end
    end

    always @* begin
        rd_bin_next  = rd_bin;
        rd_gray_next = rd_gray;
        if (rd_en && !rd_empty) begin
            rd_bin_next  = rd_bin + PTR_ONE;
            rd_gray_next = (rd_bin + PTR_ONE) ^ ((rd_bin + PTR_ONE) >> 1);
        end
    end

    always @(posedge wr_clk or posedge wr_reset) begin
        if (wr_reset) begin
            wr_bin  <= {PTR_WIDTH{1'b0}};
            wr_gray <= {PTR_WIDTH{1'b0}};
            wr_full <= 1'b0;
        end else begin
            if (wr_en && !wr_full)
                mem[wr_bin[ADDR_WIDTH-1:0]] <= wr_data;
            wr_bin  <= wr_bin_next;
            wr_gray <= wr_gray_next;
            wr_full <= wr_full_next;
        end
    end

    always @(posedge rd_clk or posedge rd_reset) begin
        if (rd_reset) begin
            rd_bin   <= {PTR_WIDTH{1'b0}};
            rd_gray  <= {PTR_WIDTH{1'b0}};
            rd_data  <= {DATA_WIDTH{1'b0}};
            rd_empty <= 1'b1;
        end else begin
            if (rd_en && !rd_empty)
                rd_data <= mem[rd_bin[ADDR_WIDTH-1:0]];
            rd_bin   <= rd_bin_next;
            rd_gray  <= rd_gray_next;
            rd_empty <= rd_empty_next;
        end
    end

    always @(posedge wr_clk or posedge wr_reset) begin
        if (wr_reset) begin
            rd_gray_sync1 <= {PTR_WIDTH{1'b0}};
            rd_gray_sync2 <= {PTR_WIDTH{1'b0}};
        end else begin
            rd_gray_sync1 <= rd_gray;
            rd_gray_sync2 <= rd_gray_sync1;
        end
    end

    always @(posedge rd_clk or posedge rd_reset) begin
        if (rd_reset) begin
            wr_gray_sync1 <= {PTR_WIDTH{1'b0}};
            wr_gray_sync2 <= {PTR_WIDTH{1'b0}};
        end else begin
            wr_gray_sync1 <= wr_gray;
            wr_gray_sync2 <= wr_gray_sync1;
        end
    end

endmodule
```

下面每一节都对应上面的一块代码，引用行号请对照第 2 节。

---

## 3. 逐段精读

### 3.1 为什么非要有异步 FIFO

把 `wr_data` 直接从写侧递到读侧有两层问题：

1. **单比特亚稳态**：读侧触发器直接采写侧一根线，跳变点可能正好落在采样窗口里，输出一时既不像 0 也不像 1。办法是**同一根线连打两拍**。
2. **多比特撕裂**：二进制指针递增时可能同时翻好几位（如 `011→100`）。读侧在中间采样会得到**从未存在过**的"幽灵值"，满/空判断就会算错。

本模块的答案：跨域只传**格雷码指针**（每拍最多翻一位，从根上消灭撕裂）+ 过**两级触发器**（把亚稳态压到"最多错一拍"）。

### 3.2 `localparam`：三个派生常量

```verilog
localparam integer DEPTH     = (1 << ADDR_WIDTH);        // 默认 1024
localparam integer PTR_WIDTH = ADDR_WIDTH + 1;           // 默认 11
localparam [PTR_WIDTH-1:0] PTR_ONE = {{(PTR_WIDTH - 1){1'b0}}, 1'b1};
```

- `DEPTH` 是深度，永远 2 的幂，指针才能自然回绕。
- `PTR_WIDTH = ADDR_WIDTH + 1`：指针比地址**多一位**，这位是**回绕标志位**。`mem` 只用低 `ADDR_WIDTH` 位寻址，最高位用来区分"同一地址是第几圈"，满和空才分得清。
- `PTR_ONE` 是补零到 `PTR_WIDTH` 位的常数 1，即指针的步长。

### 3.3 存储阵列与四组指针

`reg [DATA_WIDTH-1:0] mem [0:DEPTH-1];` 是深度 `DEPTH`、字宽 `DATA_WIDTH` 的存储体（默认 1024 × 32 位），在 `wr_clk` 沿被写、`rd_clk` 沿被读，本质是一块**一写口一读口的双时钟 RAM**。它**不带复位**——槽在被写之前没有意义，而"有没有被写过"由满/空标志保证。

每一侧都维护**两份指针**（`wr_bin/wr_gray`、`rd_bin/rd_gray`），分工不同：

| 指针 | 用途 | 是否跨域 |
|---|---|---|
| `wr_bin` / `rd_bin` | 取低 `ADDR_WIDTH` 位索引 `mem` | 否，只在本地域 |
| `wr_gray` / `rd_gray` | 发布给对侧，参与满/空比较 | 是 |

格雷码不是顺序码，`mem[gray]` 会落在错的地址；二进制码又会撕裂。**所以二进制管本地寻址、格雷码管跨域比较，两个都要。** `_next` 后缀照旧是"组合算出的下一拍值"（见 [02 篇](02-project-conventions.md)）。

### 3.4 两级同步器与 `ASYNC_REG`

`rd_gray_sync1/2` 住在**写域**，把读指针搬进写域；`wr_gray_sync1/2` 反过来住在**读域**。每个对侧指针都连打两拍，四行声明都带 `(* ASYNC_REG = "TRUE" *)`。`(* ... *)` 是**综合属性**，不是逻辑：它告诉工具"这两个触发器是一级同步器，请摆在一起、别拆散优化或重定时"。它不影响仿真，也不会出现在波形里。

### 3.5 三条 `assign`：组合判据

```verilog
assign wr_gray_at_full = {~rd_gray_sync2[PTR_WIDTH-1:PTR_WIDTH-2],
                          rd_gray_sync2[PTR_WIDTH-3:0]};
assign wr_full_next  = (wr_gray_next == wr_gray_at_full);
assign rd_empty_next = (rd_gray_next == wr_gray_sync2);
```

- **满**：`wr_gray_at_full` 把同步过来的读指针**最高两位取反、其余位照抄**（`{~高2位, 低9位}`）；`wr_full_next` 再问"写者下一拍的格雷码是否等于它"。因为指针多一位，"比读指针超前整整 `DEPTH` 项"在格雷码里恰好对应**最高两位一起翻转**，这是业界（Cummings）的标准签名。
- **空**：`rd_empty_next` 判断"读者下一拍的位置是否与写者最新落地位置**完全相等**"，相等即没数据。
- 用 `_next` 而不是当前值，使"这一拍读完后是否立刻变空"在一个时钟沿上就定好。

### 3.6 两个 `always @*`：算"下一拍指针"

```verilog
always @* begin
    wr_bin_next  = wr_bin;
    wr_gray_next = wr_gray;
    if (wr_en && !wr_full) begin
        wr_bin_next  = wr_bin + PTR_ONE;
        wr_gray_next = (wr_bin + PTR_ONE) ^ ((wr_bin + PTR_ONE) >> 1);
    end
end
```

这是组合块，用阻塞赋值 `=`。读法：先**默认不动**（这样不写时也不会推断出 latch），只有 `wr_en && !wr_full` 时才前进——二进制 `+1`，格雷码用公式 `g = b ^ (b>>1)`（对**递增值**做二进制转格雷）。读侧那个 `always @*` 完全对称。

**为什么 `b ^ (b>>1)` 只翻一位？** 相邻递增值只差 1，做这个变换后结果的汉明距离恰好是 1。于是跨域采样时每一位要么还是旧值、要么已是新值，**不存在中间第三种组合**。这就是格雷码能安全跨域的全部理由。

### 3.7 两个指针寄存器块

写域块 `always @(posedge wr_clk or posedge wr_reset)`（异步入、高有效、只踩 `wr_clk`）复位优先清 `wr_bin/wr_gray/wr_full`（满标志复位为 0）；正常路径同拍做三件事：**写存储** `mem[wr_bin[ADDR_WIDTH-1:0]] <= wr_data`（用当前指针当地址）、**指针前进到 `_next`**、**更新满标志**。

读域块 `always @(posedge rd_clk or posedge rd_reset)` 完全对称，复位后 `rd_empty = 1`（空）。关键的一行是 `rd_data <= mem[rd_bin[ADDR_WIDTH-1:0]]`：读出是**寄存输出**，不是 `assign` 的组合读，所以 `rd_data` 在 `rd_bin` 抖动时不会跟着抖，且在 `rd_empty` 为 1 时保持上一拍值。testbench 的 `RD_HOLD` 检查正是在钉这一点。

### 3.8 两个同步器块

写域同步器块每个 `wr_clk` 沿做 `rd_gray_sync1 <= rd_gray; rd_gray_sync2 <= rd_gray_sync1;`——读指针先进 `sync1`、`sync1` 再进 `sync2`，所以 `rd_gray_sync2` 是**晚两个写时钟**的读指针副本，满判据用的就是它。读域那个块对称地搬 `wr_gray`（`wr_gray_sync2` 给空判据用）。两块都**没有清 `mem`**：复位期间跨域指针可能暂时不一致，但读者绝不会读没写过的槽（空判据拦住），写者也绝不会覆盖没读走的槽（满判据拦住）。

---

## 4. 端口 / 参数表

| 参数 | 默认 | 含义 |
|---|---|---|
| `DATA_WIDTH` | 32 | 每项位宽，也是 `mem` 列宽和 `rd_data` 宽度 |
| `ADDR_WIDTH` | 10 | 深度指数，深度 `= 2**ADDR_WIDTH`；约束 `>= 2`（最小深度 4） |

| 端口 | 方向 | 域 | 作用 |
|---|---|---|---|
| `wr_clk` | in | 写 | 写指针、满标志、读指针同步器都踩这个沿 |
| `wr_reset` | in | 写 | 高有效**异步**复位，只影响写域 |
| `wr_en` | in | 写 | 写请求，仅 `!wr_full` 时提交 |
| `wr_data` | in | 写 | 写入数据，仅提交那拍进 `mem` |
| `wr_full` | out | 写 | 满标志（寄存器），用同步过的读指针判定，滞后几拍 |
| `rd_clk` | in | 读 | 读指针、空标志、写指针同步器都踩这个沿 |
| `rd_reset` | in | 读 | 高有效**异步**复位，只影响读域 |
| `rd_en` | in | 读 | 读请求，仅 `!rd_empty` 时提交 |
| `rd_data` | out | 读 | 读出数据，**寄存输出**，空时保持 |
| `rd_empty` | out | 读 | 空标志（寄存器），复位初值 1 |

---

## 5. 一次写入 → 跨域 → 读出，逐拍走一遍

两边刚联合复位完：指针全 0，`wr_full=0`、`rd_empty=1`。写侧写进一个值 `X`：

| 时刻 | 发生了什么 |
|---|---|
| 写沿 #1 | `wr_en=1` 且 `!wr_full` → `mem[0] <= X`；`wr_bin`、`wr_gray` 前进到 1 |
| 读沿 #1 | `wr_gray_sync1 <= 1`，`wr_gray_sync2` 还是旧值 0 |
| 读沿 #2 | `wr_gray_sync2 <= 1`，于是 `rd_gray_next(=0) != wr_gray_sync2(=1)` |
| 读沿 #2 沿 | `rd_empty <= 0`，**空标志落下** |
| 读沿 #3 | `rd_en=1` 且 `!rd_empty` → `rd_data <= mem[0]`（就是 `X`），指针前进 |
| 读沿 #4 | `rd_data` 稳定为 `X`，`rd_bin=1` 已生效 |

两个要点：数据要穿过**两级同步器（两个读沿）**读侧才知道"有货"；读出本身又各占一拍。反过来，读走一项后读指针也要穿两级 `wr_clk` 同步器，`wr_full` 才松开。**永远宁可多等一拍，也不让指针越过对侧还没看到的位置**，这就是正确性来源。

---

## 6. 常见疑问

**Q：两个复位为什么独立？** 这是两个真正独立的时钟域，把 A 域复位同步到 B 域又要多一组同步器。`wr_reset` 只清写域的 `wr_bin/wr_gray/wr_full` 和住在本域的 `rd_gray_sync1/2`；`rd_reset` 对称地只清读域那一组。

**Q：那为什么又说"要一起复位"？** 正因复位可能只落一边，跨域指针会暂时不一致——复位释放后会有若干项被丢弃或重放，直到两侧指针重新对齐（文件头原话）。所以正常做法是两端同时复位。testbench 的 phase 4 特意各自单独复位证明"不挂死、标志能恢复"，phase 4i 再用联合复位跑一次干净的 32 项往返。

**Q：`wr_full` 用滞后的 `rd_gray_sync2` 会不会覆盖数据？** 不会，只会**更保守**：写侧看到稍旧的读进度，满/空标志可能多举几拍。最坏情况只是少走一拍，绝不会越过对侧还没看到的位置。

**Q：`ADDR_WIDTH >= 2` 为什么是硬约束？** 满判据要取"最高两位"的格雷回绕签名，指针只有两位时签名就退化了，所以最小深度是 4。

---

## 7. 你应该带走的三件事

1. **跨域只传格雷码，每拍只翻一位**——`g = b ^ (b>>1)` 保证相邻码字汉明距离为 1，从根上消灭多比特撕裂；两级同步器把亚稳态压成"最多错一拍"。
2. **二进制和格雷码各司其职**——二进制指针负责本地寻址（`mem[bin[ADDR_WIDTH-1:0]]`），格雷码负责跨域比较。
3. **异步 FIFO 的延迟不是缺陷**——满/空标志用的是穿过两级同步器、滞后于对侧的指针，保守等一拍才是它的正确性来源。

下一篇 [`22-chr-fetch-unit.md`](22-chr-fetch-unit.md) 回到单时钟世界，看一个 6 态有限状态机怎么按节拍取 CHR 字节。
