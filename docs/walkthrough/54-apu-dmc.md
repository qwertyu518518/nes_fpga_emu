# 54 DMC 通道精读：`nes_apu_dmc.v`

`nes_apu_dmc.v` 是 APU 的第五个通道：它不产生方波或噪声，而是**把 CPU 内存里的一段字节当成 1-bit 采样播放**——这种方式叫 **delta modulation**，鼓声、人声常用。

- 源码：[`rtl/nes_core/apu/nes_apu_dmc.v`](../../rtl/nes_core/apu/nes_apu_dmc.v)
- 合同与证据：[`../modules/apu-full.md`](../modules/apu-full.md)（§2.5、§3、§4.4）
- 测试目标：`apu-core`（elaboration）+ `apu-tb`（见 [`tb/apu/README.md`](../../tb/apu/README.md)）

---

## 1. 它是什么、站在哪

DMC 干三件事：**播放**（`bits` 一次存 8 个 1-bit 采样 = 1 字节，每个 bit 让 `output_level` 加 2 或减 2，有上下限，形成台阶波形）、**取数**（采样数据在 CPU 地址空间，DMC 自己读不到，必须**申请 CPU 总线**搬回，即 DMC DMA）、**结束通知**（播完置 `irq_flag`）。

```text
   CPU 写 $4010-$4013 / $4015（经 nes_apu2a03 译码）
                          ▼
   ┌───────────────────────────────────────────────┐
   │ nes_apu_dmc: bits → output_level ─► 混音       │
   └───────────────────────────────────────────────┘
        │ dmc_bus_req / dmc_addr ──► CPU 总线仲裁（要一个字节）
        │ ◄── dmc_rdata / dmc_ack  ──（返回字节 + 授权脉冲）
        │ irq_flag ──────────────► nes_apu2a03 → CPU /IRQ
```

`dmc_bus_req` / `dmc_addr` 送到 [`nes_cpu_bus.v`](../../rtl/nes_core/bus/nes_cpu_bus.v) 的 `dma_req_dmc`（与 OAM DMA 共用同一个 DMA 端口），仲裁只有一行：`dma_pick_oam = dma_req_oam; dma_pick_dmc = !dma_req_oam && dma_req_dmc;`，即 **OAM 优先于 DMC**。授权与字节经 `dma_ack`/`dma_din` 回来，由 [`nes_system_v6.v`](../../rtl/nes_core/system/nes_system_v6.v) 分成 `apu_dmc_ack`/`apu_dmc_rdata`；请求期间 `bus_hold` 冻住 CPU。这与 [`24-oam-dma.md`](24-oam-dma.md) 是同一套握手，区别只是 OAM 一次搬 256 字节、DMC 只要一个字节。

---

## 2. 全文（225 行）

```verilog
`timescale 1ns/1ps

module nes_apu_dmc (
    input wire clk,
    input wire reset,
    input wire ce,
    input wire status_wr,
    input wire [7:0] status_wr_data,
    input wire status_clear,
    input wire reg_we,
    input wire [1:0] reg_index,
    input wire [7:0] reg_din,
    output reg [7:0] reg_dout,
    output wire dmc_bus_req,
    output wire [15:0] dmc_addr,
    input wire [7:0] dmc_rdata,
    input wire dmc_ack,
    output reg irq_flag,
    output wire [15:0] sample_addr,
    output reg [15:0] current_addr,
    output reg [11:0] bytes_remaining,
    output reg [8:0] rate_cnt,
    output reg [3:0] bits_remaining,
    output reg [7:0] bits,
    output reg [6:0] output_level,
    output reg silence,
    output reg buf_empty,
    output reg active,
    output reg [7:0] sample_buf
);

reg irq_enable;
reg loop;
reg [3:0] rate_sel;
reg [7:0] sample_page;
reg [7:0] length_reg;
reg [8:0] rate_reload;
reg state;

wire [11:0] sample_length;
wire [11:0] bytes_next;
wire [3:0] bits_after;
wire rate_tick;
wire byte_in;
wire have_byte;
wire [7:0] byte_val;
wire consume;
wire refill;
wire refill_last;
wire slot_free;
wire dmc_en_next;
wire [7:0] bits_next;
wire [6:0] level_next;

function [8:0] dmc_rate_ntsc;
    input [3:0] index;
    begin
        case (index)
            4'd0: dmc_rate_ntsc = 9'd427;
            4'd1: dmc_rate_ntsc = 9'd379;
            4'd2: dmc_rate_ntsc = 9'd339;
            4'd3: dmc_rate_ntsc = 9'd319;
            4'd4: dmc_rate_ntsc = 9'd285;
            4'd5: dmc_rate_ntsc = 9'd253;
            4'd6: dmc_rate_ntsc = 9'd225;
            4'd7: dmc_rate_ntsc = 9'd213;
            4'd8: dmc_rate_ntsc = 9'd189;
            4'd9: dmc_rate_ntsc = 9'd159;
            4'd10: dmc_rate_ntsc = 9'd141;
            4'd11: dmc_rate_ntsc = 9'd127;
            4'd12: dmc_rate_ntsc = 9'd105;
            4'd13: dmc_rate_ntsc = 9'd83;
            4'd14: dmc_rate_ntsc = 9'd71;
            default: dmc_rate_ntsc = 9'd53;
        endcase
    end
endfunction

assign sample_addr = 16'hC000 | {sample_page, 6'b000000};
assign sample_length = {4'b0000, length_reg, 4'b0000} + 12'd1;
assign dmc_bus_req = state;
assign dmc_addr = current_addr;
assign rate_tick = (rate_cnt == 9'd0);
assign byte_in = state && dmc_ack;
assign have_byte = !buf_empty || byte_in;
assign byte_val = byte_in ? dmc_rdata : sample_buf;
assign bytes_next = !byte_in ? bytes_remaining
                  : (bytes_remaining == 12'd1) ? (loop ? sample_length : 12'd0)
                  : (bytes_remaining == 12'd0) ? 12'd0
                  : (bytes_remaining - 12'd1);
assign dmc_en_next = status_wr ? status_wr_data[4] : active;
assign consume = ce && dmc_en_next && rate_tick && (bits_remaining != 4'd0);
assign bits_after = consume ? (bits_remaining - 4'd1) : bits_remaining;
assign refill = ce && dmc_en_next && rate_tick && (bits_after == 4'd0);
assign refill_last = refill && !have_byte && (bytes_next == 12'd0) && !loop;
assign slot_free = !state || dmc_ack;
assign bits_next = refill ? (have_byte ? byte_val : bits) : (consume ? {1'b0, bits[7:1]} : bits);
assign level_next = !consume ? output_level
                 : (silence ? output_level
                 : (bits[0] ? ((output_level > 7'd125) ? 7'd127 : (output_level + 7'd2))
                            : ((output_level < 7'd2) ? 7'd0 : (output_level - 7'd2))));

always @* begin
    reg_dout = 8'h00;
    case (reg_index)
        2'd0: reg_dout = {irq_enable, loop, 2'b00, rate_sel};
        2'd1: reg_dout = {1'b0, output_level};
        2'd2: reg_dout = sample_page;
        default: reg_dout = length_reg;
    endcase
    if (reset)
        reg_dout = 8'h00;
end

always @(posedge clk or posedge reset) begin
    if (reset) begin
        irq_enable <= 1'b0;
        loop <= 1'b0;
        rate_sel <= 4'd0;
        rate_reload <= 9'd427;
        rate_cnt <= 9'd0;
        sample_page <= 8'd0;
        length_reg <= 8'd0;
        current_addr <= 16'hC000;
        bytes_remaining <= 12'd0;
        sample_buf <= 8'h00;
        buf_empty <= 1'b1;
        bits <= 8'h00;
        bits_remaining <= 4'd0;
        output_level <= 7'd0;
        silence <= 1'b1;
        active <= 1'b0;
        irq_flag <= 1'b0;
        state <= 1'b0;
    end else begin
        if (byte_in) begin
            sample_buf <= dmc_rdata;
            buf_empty <= 1'b0;
            state <= 1'b0;
            if (current_addr == 16'hFFFF)
                current_addr <= 16'h8000;
            else
                current_addr <= current_addr + 16'd1;
            if (bytes_remaining != 12'd0) begin
                if (bytes_remaining == 12'd1) begin
                    if (loop) begin
                        current_addr <= sample_addr;
                        bytes_remaining <= sample_length;
                    end else begin
                        bytes_remaining <= 12'd0;
                    end
                end else begin
                    bytes_remaining <= bytes_remaining - 12'd1;
                end
            end
        end

        if (reg_we) begin
            case (reg_index)
                2'd0: begin
                    irq_enable <= reg_din[7];
                    loop <= reg_din[6];
                    rate_sel <= reg_din[3:0];
                    rate_reload <= dmc_rate_ntsc(reg_din[3:0]);
                    if (!reg_din[7])
                        irq_flag <= 1'b0;
                end
                2'd1: output_level <= reg_din[6:0];
                2'd2: sample_page <= reg_din;
                default: length_reg <= reg_din;
            endcase
        end

        if (status_wr) begin
            if (status_wr_data[4]) begin
                active <= 1'b1;
                if (bytes_remaining == 12'd0) begin
                    bytes_remaining <= sample_length;
                    current_addr <= sample_addr;
                    if (buf_empty && !state)
                        state <= 1'b1;
                end
            end else begin
                active <= 1'b0;
                state <= 1'b0;
                bytes_remaining <= 12'd0;
            end
        end

        if (status_clear)
            irq_flag <= 1'b0;

        if (ce && dmc_en_next) begin
            if (!rate_tick)
                rate_cnt <= rate_cnt - 9'd1;
            else
                rate_cnt <= rate_reload;

            output_level <= level_next;
            bits <= bits_next;

            if (refill_last) begin
                bits_remaining <= 4'd0;
                silence <= 1'b1;
                active <= status_wr ? status_wr_data[4] : 1'b0;
                if (irq_enable)
                    irq_flag <= status_wr ? 1'b0 : 1'b1;
            end else if (refill) begin
                bits_remaining <= 4'd8;
                if (have_byte) begin
                    silence <= 1'b0;
                    buf_empty <= 1'b1;
                end else begin
                    silence <= 1'b1;
                end
                if ((bytes_next != 12'd0) && slot_free)
                    state <= 1'b1;
            end else if (consume) begin
                bits_remaining <= bits_after;
            end
        end
    end
end

endmodule
```

---

## 3. 逐段精读

**3.1 三条接口。** 寄存器写：`reg_we` + `reg_index`（0→`$4010`，1→`$4011`，2→`$4012`，3→`$4013`）+ `reg_din`。状态：`status_wr`/`status_wr_data`/`status_clear`（都来自 `$4015`）。取样总线：`dmc_bus_req`/`dmc_addr` 出，`dmc_rdata`/`dmc_ack` 入。

**3.2 地址与长度怎么算（第 79-80 行）。**

```verilog
assign sample_addr   = 16'hC000 | {sample_page, 6'b000000};    // $4012×64 + $C000
assign sample_length = {4'b0000, length_reg, 4'b0000} + 12'd1;  // $4013×16 + 1
```

`{sample_page, 6'b0}` 把页值左移 6 位（×64）再或上基址 `$C000`：`$4012=$01` → `$C040`。`sample_length` 把 `$4013` 左移 4 位（×16）再 +1：`$4013=$00` → 1 字节，`$4013=$01` → 17 字节。

**3.3 rate 表与节拍（第 55-77、193-197 行）。** `dmc_rate_ntsc()` 是 16 项函数查表；写 `$4010` 时 `rate_reload <= dmc_rate_ntsc(reg_din[3:0])`。`rate_tick = (rate_cnt == 9'd0)` 是"这一拍到点"，时序块里 `rate_cnt` 走 0 → 重装 `rate_reload` → 递减 → 到 0 再 tick。所以**每 `rate_reload` 个 `ce` 播一位**（index 15 是 53 → 54 个 `ce` 一位）。

**3.4 输出单元：8 个 bit 怎么变成电平（第 92-101 行）。** `consume` 消费一位（`bits_remaining`−1、`bits` 右移，`bits[0]` 是当前位）；`refill` 在 8 位播完（`bits_after==0`）时从 `sample_buf` 装新字节、`bits_remaining` 回 8；`level_next` 按 `bits[0]`：=1 加 2（上限 127）、=0 减 2（下限 0）、`silence` 时不改。这就是"clamped counter"整数化的 delta 调制。

**3.5 取样请求：`state` 是一位握手标志。** `assign dmc_bus_req = state;`，`state=1` 即"有一个字节的请求在飞"。相关派生：

```verilog
assign byte_in   = state && dmc_ack;        // 总线授权，字节到了
assign have_byte = !buf_empty || byte_in;   // 缓冲里有字节（或这一拍到）
assign slot_free = !state || dmc_ack;       // 同一时刻只允许一个请求在飞
```

`byte_in` 分支（第 136-156 行）做四件事：锁存 `sample_buf`、`buf_empty<=0`、`state<=0`（撤销请求）、推进 `current_addr`（`$FFFF` 之后回 `$8000`）、更新 `bytes_remaining`（`==1` 且 `loop` 回卷到 `sample_length`，否则清 0，其余 −1）。`refill` 装字节**同一拍**把 `buf_empty<=1`，于是 `if ((bytes_next != 12'd0) && slot_free) state <= 1'b1;` 发出下一个请求；播放窗口（8 × 最长 428 `ce`）远大于一次取样延迟，所以取数通常提前完成。`bytes_next`（第 87-90 行）是"取数之后剩几个"的组合推算，**判样本结束必须用它、不能用当前 `bytes_remaining`**，否则单字节样本会多取一个字节才报 IRQ（§4.4）。

**3.6 寄存器写、active 与 IRQ。** `$4010`=`{irq_enable, loop, rate_sel}`（`d[7]=0` 时顺手清 `irq_flag`）；`$4011` 直接写 `output_level`；`$4012`/`$4013` → `sample_page`/`length_reg`。`status_wr`（`$4015[4]`）置 1 且 `bytes_remaining==0` 就**重启**（装长度/基址，缓冲空则发请求），置 0 就**中止**（清 `active`/`state`/`bytes_remaining`）。**自然结束**（`refill_last`，第 202-207 行）：`!have_byte && bytes_next==0 && !loop` → `silence<=1`、`active<=0`，`irq_enable` 为 1 时置 `irq_flag`。`status_clear`（`$4015` 读或写）：清 `irq_flag`——这就是"读 `$4015` 清 DMC IRQ"。`$4015[4]` 是**外部开关**、`active` 是**内部状态**：自然结束清 `active` 后，必须再写一次 `$4015[4]=1` 才重开。

**3.7 同一拍谁赢。** 一个 `clk` 沿上可能同时有字节送达/`$4010-$4013` 写/`$4015` 写/清/rate tick，RTL 用**单个 always 块的书写顺序**表达优先级（低 → 高）：`byte_in` < 寄存器写 < `status_wr` < `status_clear` < `ce` 门控的 tick。所以"样本结束那拍刚好读 `$4015`"时新置的 IRQ 会留下（有意为之，见 `../modules/apu-full.md` §3.3）。

---

## 4. 端口与寄存器

| 端口 | 方向/宽 | 作用 |
|---|---|---|
| `clk`, `reset`, `ce` | in 1 | 时钟 / 异步高有效复位 / CPU cycle 使能（`ce=0` 冻结） |
| `status_wr`, `status_wr_data` | in 1/8 | `$4015` 写，`data[4]` = DMC enable |
| `status_clear` | in 1 | `$4015` 读或写，清 `irq_flag` |
| `reg_we`, `reg_index`, `reg_din` | in 1/2/8 | `$4010-$4013` 写 |
| `reg_dout` | out 8 | 寄存器读回（组合） |
| `dmc_bus_req`, `dmc_addr` | out 1/16 | **电平**请求 + 请求地址（`$8000-$FFFF`） |
| `dmc_rdata`, `dmc_ack` | in 8/1 | 返回字节 + 授权脉冲（同拍有效） |
| `irq_flag` | out 1 | 样本结束 IRQ 标志（电平） |
| `sample_addr`, `current_addr`, `bytes_remaining` | out 16/16/12 | 采样基址 / 当前地址 / 剩余字节 |
| `rate_cnt`, `bits_remaining`, `bits`, `output_level` | out 9/4/8/7 | rate 计数 / 移位剩余位 / 移位寄存器 / DAC 电平 |
| `silence`, `buf_empty`, `active`, `sample_buf` | out 1/1/1/8 | 静音 / 缓冲空 / 播放中 / 缓冲字节 |

| 寄存器 | 写 | 读 |
|---|---|---|
| `$4010` | IRQ enable=`d[7]`、loop=`d[6]`、rate index=`d[3:0]` | `{irq_enable, loop, 2'b00, rate index}` |
| `$4011` | 直接输出电平=`d[6:0]` | `{1'b0, output_level}` |
| `$4012` | sample page：`sample_addr=$C000+value×64` | `sample_page` |
| `$4013` | 长度-1：`sample_length=value×16+1` | `length_reg` |
| `$4015` 写 `d[4]` | 1=enable/重启，0=中止并清 `bytes_remaining` | —— |
| `$4015` 读 | —— | bit4 = `bytes_remaining != 0`；**读清** `irq_flag` |

---

## 5. 一次采样走一遍

设定：`$4010=$8F`（irq_enable=1、loop=0、rate index 15 → `rate_reload=53`）、`$4011=$00`、`$4012=$00`（`sample_addr=$C000`）、`$4013=$00`（`sample_length=1`），内存 `$C000=$5A`。

| 步骤 | 事件 | 关键信号变化 |
|---|---|---|
| 1 | 写 `$4015`，`d[4]=1` | `active=1`；`bytes_remaining==0` → 装 `sample_length=1`、`current_addr=$C000`；缓冲空 → `state=1` |
| 2 | 请求在飞 | `dmc_bus_req=1`、`dmc_addr=$C000`；系统拉 `bus_hold` 停住 CPU |
| 3 | 总线授权 | `dmc_ack=1`、`dmc_rdata=$5A` → `byte_in`：`sample_buf<=$5A`、`buf_empty<=0`、`state<=0`、`current_addr<=$C001`、`bytes_remaining<=0`（`==1` 且 `!loop`） |
| 4 | 第一个 rate tick | `refill`：`bits<=$5A`、`bits_remaining<=8`、`have_byte=1` → `silence<=0`、`buf_empty<=1`；`bytes_next==0` 故不再发请求 |
| 5 | 之后每 54 个 `ce` | `consume` 一位：`bits` 右移、`bits_remaining` 8→…→1，`output_level` 按 `bits[0]` ±2 |
| 6 | 第 8 位播完那一 tick | `refill` 但 `have_byte=0` → `silence=1`；`refill_last` 成立 → `irq_flag<=1`、`active<=0`、`bits_remaining<=0` |
| 7 | CPU 读 `$4015` | `status_clear` → `irq_flag<=0` |

`$5A = 0101_1010`：`bits[0]` 依次是 0,1,0,1,1,0,1,0，电平从 0 出发先触底再台阶上升。要点：**第 8 个 bit 播完的那一拍就置 IRQ**，`active` 随即清 0，要重放必须再写一次 `$4015[4]=1`。

---

## 6. 常见疑问

**Q：`dmc_bus_req` 为什么是电平不是脉冲？** A：它要保持到 `dmc_ack` 出现，否则总线侧可能永远等不到一个干净的授权窗口；停几拍是自由的。
**Q：为什么取样分支挂在 `clk` 上、不受 `ce` 门控？** A：`ce` 是 CPU cycle 使能，CPU 被 DMA 停住时 `ce` 也停；取数若等 `ce` 会"请求 → 停 CPU → `ce` 不来 → 收不到数据"死锁，故 `byte_in` 用裸 `clk`（见 [`tb/apu/README.md`](../../tb/apu/README.md) CPU stall 一节）。
**Q：为什么判结束用 `bytes_next` 而不是当前 `bytes_remaining`？** A：同一拍"取数字节"与"取完后剩几个"必须一致，用当前值会多取一个字节（[`../modules/apu-full.md`](../modules/apu-full.md) §4.4）。
**Q：IRQ 由谁清，`$FFFF` 之后为什么回 `$8000`？** A：写 `$4010[7]=0`、或任何 `$4015` 读/写都清 `irq_flag`；地址回 `$8000` 是真实硬件行为（地址高字节进一后落回 RAM 页），不是 64 KiB 模运算。

---

## 7. 你应该带走的三件事

1. **DMC = 播放 + 取数 + 结束 IRQ**：`bits` 移位寄存器把 8 个 1-bit 采样变成 ±2 的台阶电平，字节通过 DMA 从 CPU 内存搬进来。
2. **请求是电平、授权不依赖 `ce`、同时只一个在飞**：`state` 一位就是全部握手状态，`slot_free` 防止重复发起。
3. **输出单元是两级缓冲**：`sample_buf`（1 字节）+ `bits`（8 位），装字节的瞬间就发下一个请求，播放窗口远大于取数延迟。

下一篇 [`55-apu2a03.md`](55-apu2a03.md) 把五个通道装进顶层：寄存器译码、frame sequencer、IRQ 汇总与整数混音。
