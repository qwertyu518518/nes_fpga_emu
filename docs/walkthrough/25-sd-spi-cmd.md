# 25 串行协议发送器精读：`sd_spi_cmd.v`（SD/TF 卡的 SPI 命令帧 + CRC7）

前面几篇讲的是"读一个值、搬一段数据"；这一篇让 FPGA 在四根线上按规律翻转电平，说出 SD 卡听得懂的串行协议——本项目第一个真正的**协议发送器**。

- 源码：[`rtl/nes_core/peripheral/sd_spi_cmd.v`](../../rtl/nes_core/peripheral/sd_spi_cmd.v)
- 合同与证据：[`../modules/sd-spi-cmd.md`](../modules/sd-spi-cmd.md)
- 测试台：[`tb/peripheral/tb_sd_spi_cmd.v`](../../tb/peripheral/tb_sd_spi_cmd.v)
- 测试目标：`sd-spi-cmd-core`（只 elaboration）、`sd-spi-cmd-tb`（真跑），见 [`tools/sim_all.ps1`](../../tools/sim_all.ps1)

---

## 1. 先认识"上游和下游"

SPI 模式下只有四根线：`CS`（片选）、`CLK`（时钟）、`MOSI`（主机→卡）、`MISO`（卡→主机）。主机在 `CS` 低电平期间把命令一位一位移出去，卡在时钟沿上采样。

```text
上层控制器（未实现）
   │  start / cmd[5:0] / arg[31:0] / crc_check_en
   ▼
 [sd_spi_cmd] ── spi_cs_n / spi_clk / spi_mosi ──►  SD/TF 卡
   │          ◄── spi_miso ──
   └── resp0 / resp1 / busy / done / crc7_err ──► 上层控制器
```

- **上游**是某个 SD 控制器逻辑（发 `start`、传命令号 `cmd` 和参数 `arg`、收结果）。目前**还不存在**——全仓库没有任何模块例化它。
- **下游**是 TF 卡本身。本模块**只管发一帧、收两个应答字节**；不解析命令、不轮询卡忙、不做块读（合同第 7 节列为"未实现"）。

记住这帧的长度：**6 个命令字节 + 9 个 0xFF 哑字节 = 15 字节 = 120 个 `spi_clk` 周期。**

---

## 2. 全文（180 行）

```verilog
`timescale 1ns/1ps

// SD/eMMC SPI command frame transmitter (Verilog-2001, synthesisable).
//
// One transaction shifts {8'h40|cmd, arg[31:24], arg[23:16], arg[15:8],
// arg[7:0], {crc7, 1'b1}} out MSB first, then nine 0xFF dummy bytes: the
// first eight clock the reply in, resp0/resp1 keep the first two and the ninth
// adds the clocks before CS may go high, so a frame is 15 bytes / 120 spi_clk
// periods. start is a one clock pulse honoured only while idle, done pulses for
// the clock that ends the frame, busy is high from the clock that accepts start
// through that clock, and nothing here is hard coded.
//
// CRC7 is x^7+x^3+1 (0x89), init 0, MSB first, one shift register step per
// input bit, so the transmit byte is {crc7, 1'b1}. The reply check recomputes
// CRC7 over resp0[7:1] and compares it with resp0[7:1], the ((crc7<<1)|1) byte
// form restricted to the seven CRC bits; an all ones (0xFF / 0x7F, card busy) or
// all zeros (0x00, no reply) field means "no CRC received" and is skipped, and
// crc7_err is sticky until reset.
//
// SPI_HZ comes from a CLK_HZ/(4*SPI_HZ) divider tick, four ticks per bit, so the
// clock half period is two ticks, CLK_HZ/(2*SPI_HZ), at 50% duty. Tick 0 presents
// the next MOSI bit while the clock is low, 1 raises the clock and the card
// samples MOSI, 2 samples MISO while the card still holds it, 3 lowers the clock
// and the card may change MISO: both edges get a half period of setup and of
// hold. Accepting start clears the divider and pulls clock and CS low together,
// so the first edge is a fixed two ticks after CS falls and the first bit
// really leaves the master.

module sd_spi_cmd #(parameter integer CLK_HZ = 21477272, SPI_HZ = 400000) (
    input  wire        clk,
    input  wire        reset,
    input  wire        start,
    input  wire [5:0]  cmd,
    input  wire [31:0] arg,
    output wire        spi_clk,
    output wire        spi_cs_n,
    output wire        spi_mosi,
    input  wire        spi_miso,
    output reg  [7:0]  resp0,
    output reg  [7:0]  resp1,
    output reg         busy,
    output reg         done,
    output reg         crc7_err,
    input  wire        crc_check_en
);

    function integer clog2;
        input integer value;
        integer rest;
        begin
            rest = value - 1;
            clog2 = 0;
            while (rest > 0) begin
                rest = rest >> 1;
                clog2 = clog2 + 1;
            end
        end
    endfunction

    function [6:0] crc7_upd;
        input [6:0] seed;
        input [7:0] data;
        integer k;
        reg [6:0] c;
        begin
            c = seed;
            for (k = 7; k >= 0; k = k - 1)
                c = {c[5:0], 1'b0} ^ ((c[6] ^ data[k]) ? 7'h09 : 7'h00);
            crc7_upd = c;
        end
    endfunction

    function [6:0] crc7_msg;
        input [39:0] msg;
        integer k;
        reg [6:0] c;
        begin
            c = 7'h00;
            for (k = 4; k >= 0; k = k - 1) c = crc7_upd(c, msg[8 * k +: 8]);
            crc7_msg = c;
        end
    endfunction

    localparam [1:0] ST_IDLE = 2'd0, ST_BIT = 2'd1, ST_TAIL = 2'd2;
    localparam [3:0] LAST_RX = 4'd13;
    localparam integer QTR_RAW = CLK_HZ / (4 * SPI_HZ);
    localparam integer QTR     = (QTR_RAW < 1) ? 1 : QTR_RAW;
    localparam integer QW_RAW  = clog2(QTR + 1);
    localparam integer QW      = (QW_RAW < 1) ? 1 : QW_RAW;
    localparam [QW-1:0] QTR_M1 = QTR - 1;
    reg [QW-1:0] div_cnt_q;
    reg [1:0]    state_q;
    reg [1:0]    phase_q;
    reg [3:0]    byte_idx_q;
    reg [2:0]    bit_idx_q;
    reg [5:0]    cmd_q;
    reg [31:0]   arg_q;
    reg [6:0]    crc_q;
    reg [7:0]    rx_byte_q;
    reg          clk_q, mosi_q, cs_n_q;
    wire tick = (div_cnt_q == QTR_M1);
    wire [7:0] tx_byte = (byte_idx_q == 4'd0) ? {2'b01, cmd_q[5:0]} :
                         (byte_idx_q == 4'd1) ? arg_q[31:24] :
                         (byte_idx_q == 4'd2) ? arg_q[23:16] :
                         (byte_idx_q == 4'd3) ? arg_q[15:8] :
                         (byte_idx_q == 4'd4) ? arg_q[7:0] :
                         (byte_idx_q == 4'd5) ? {crc_q, 1'b1} : 8'hff;
    wire [6:0] resp_crc  = crc7_upd(7'h00, {1'b0, resp0[7:1]});
    wire       resp_skip = (resp0[7:1] == 7'h7f) | (resp0[7:1] == 7'h00);
    always @(posedge clk) begin
        if (reset) begin
            div_cnt_q  <= {QW{1'b0}};
            state_q    <= ST_IDLE;
            phase_q    <= 2'd0;
            bit_idx_q  <= 3'd0;
            byte_idx_q <= 4'd0;
            cmd_q      <= 6'd0;
            arg_q      <= 32'd0;
            crc_q      <= 7'h00;
            rx_byte_q  <= 8'h00;
            clk_q      <= 1'b1;
            mosi_q     <= 1'b1;
            cs_n_q     <= 1'b1;
            resp0      <= 8'h00;
            resp1      <= 8'h00;
            busy       <= 1'b0;
            done       <= 1'b0;
            crc7_err   <= 1'b0;
        end else begin
            done <= 1'b0;
            busy <= (state_q != ST_IDLE) | (start & (state_q == ST_IDLE));
            if (tick) div_cnt_q <= {QW{1'b0}}; else div_cnt_q <= div_cnt_q + 1'b1;
            if (state_q == ST_IDLE) begin
                clk_q  <= 1'b1;
                mosi_q <= 1'b1;
                cs_n_q <= 1'b1;
                if (start) begin
                    cmd_q      <= cmd;
                    arg_q      <= arg;
                    crc_q      <= crc7_msg({2'b01, cmd[5:0], arg});
                    div_cnt_q  <= {QW{1'b0}};
                    byte_idx_q <= 4'd0;
                    bit_idx_q  <= 3'd0;
                    phase_q    <= 2'd0;
                    clk_q      <= 1'b0;
                    cs_n_q     <= 1'b0;
                    state_q    <= ST_BIT;
                end
            end else if (tick) begin
                if (phase_q == 2'd0) mosi_q <= tx_byte[7 - bit_idx_q];
                else if (phase_q == 2'd1) clk_q <= 1'b1;
                else if (phase_q == 2'd2) rx_byte_q <= {rx_byte_q[6:0], spi_miso};
                else begin
                    clk_q <= 1'b0;
                    if (bit_idx_q != 3'd7) begin
                        bit_idx_q <= bit_idx_q + 3'd1;
                    end else if (state_q == ST_TAIL) begin
                        bit_idx_q <= 3'd0;
                        cs_n_q    <= 1'b1;
                        state_q   <= ST_IDLE;
                        done      <= 1'b1;
                        if (crc_check_en && !resp_skip && (resp_crc != resp0[7:1]))
                            crc7_err <= 1'b1;
                    end else begin
                        bit_idx_q <= 3'd0;
                        if (byte_idx_q == 4'd6) resp0 <= rx_byte_q; else if (byte_idx_q == 4'd7) resp1 <= rx_byte_q;
                        if (byte_idx_q == LAST_RX) state_q <= ST_TAIL;
                        else byte_idx_q <= byte_idx_q + 4'd1;
                    end
                end
                phase_q <= phase_q + 2'd1;
            end
        end
    end

    assign spi_clk = clk_q;
    assign spi_cs_n = cs_n_q;
    assign spi_mosi = mosi_q;

endmodule
```

这个模块内部有三样东西：分频器（产生"该走一步了"的 `tick`）、状态机（`state_q`）、相位计数器（`phase_q`）。

---

## 3. 逐段精读

### 3.1 参数与端口

`CLK_HZ` 是系统时钟频率（默认 21.477272 MHz，NES 主频），`SPI_HZ` 是想要的 SPI 时钟（默认 400 kHz）。**这两个参数不参与逻辑，只用来算分频比**，所以没有硬编码的魔法数字。`spi_clk`/`spi_cs_n`/`spi_mosi` 是 `wire`（由内部寄存器经最后三条 `assign` 转出）；其余输出是 `reg`。

### 3.2 `clog2`：算"要多少根线装得下一个数"

function 对应 C 的函数，但只能组合计算、不能存状态：数 `value-1` 要右移几次才变 0。`clog2(14)` 是 `13→6→3→1→0`，移 4 次返回 4，用来给 `div_cnt_q` 算位宽。

### 3.3 `crc7_upd`：逐位推进的 CRC 移位寄存器（LFSR）

核心一步是 `c = {c[5:0], 1'b0} ^ ((c[6] ^ data[k]) ? 7'h09 : 7'h00);`。对 `data` 的每位（`k` 从 7 到 0，**MSB first**）：① `{c[5:0],1'b0}` 把 7 位寄存器左移一位（丢掉 `c[6]`）；② 看"刚移出的 `c[6]`"与"当前输入位"异或；③ 为 1 就 XOR 抽头 `7'h09`（`x^3+x^0`），为 0 不动。

**为什么等价于长除法**：CRC 的定义是"消息多项式乘 `x^7`，再对生成多项式 `x^7+x^3+1`（`0x89`）取余"。长除法是**批处理**（一次拿全消息），LFSR 是**流式**（来一位推一步）；两者算出同一个余数，而 LFSR 不需要一次拿出整条消息。

### 3.4 `crc7_msg`：按大端顺序喂 5 个字节

初值 `c=0`。`msg` 是 40 位 = 5 个字节，`msg[8*k +: 8]` 是"从第 `8*k` 位向上取 8 位"的切片；`k` 从 4 到 0，先取最高字节 `[39:32]`、最后取最低字节 `[7:0]`——**大端、MSB first**，正是 SPI 线上要发的顺序。调用时传 `{2'b01, cmd[5:0], arg}`：高 8 位是命令字节，后 32 位是 `arg`。CRC7 只覆盖这 5 个字节，**不含**第六个 `{crc7,1'b1}`。

### 3.5 局部常量：分频器与"减一"的 `tick`

`QTR = CLK_HZ / (4*SPI_HZ)` 是**一个 SPI 位的四分之一**需要的系统时钟数：默认 `21477272/(4*400000)=13.42`，整除得 `13`（`QTR_RAW<1` 时钳到 1）。`QW=clog2(QTR+1)=4` 是计数器位宽。计数器在 0..QTR-1 循环，到 `QTR-1` 出 `tick` 并下一拍清零，**所以 `tick` 每 `QTR` 个系统时钟出一次**。`LAST_RX=13` 是"已发完第 14 个字节"的边界（见 3.11）。

### 3.6 `tick` 与要发的那个字节

`wire tick = (div_cnt_q == QTR_M1);` 是纯组合。`tx_byte` 是一串 `? :` **组合 mux**，按 `byte_idx_q` 选当前字节：字节 0 = `{2'b01, cmd_q[5:0]}` = 起始位 `0` + 传输位 `1` + 命令号 = `8'h40|cmd`；字节 1..4 = `arg`（大端先发高位）；字节 5 = `{crc_q, 1'b1}`（高 7 位 CRC + 结束位恒 1）；字节 ≥6 = `8'hff`。它只在 `phase_q==0` 时被读走一位（`tx_byte[7-bit_idx_q]`），所以不必寄存。

### 3.7 应答校验的两根 `wire`

`resp_crc = crc7_upd(0, {1'b0, resp0[7:1]})`：对 `resp0` 高 7 位**重算**一次 CRC7，作比较参考。`resp_skip = (resp0[7:1]==7'h7f) | (resp0[7:1]==7'h00)`：这 7 位**全 1**（`0xFF`/`0xFE`，卡忙）或**全 0**（`0x00`/`0x01`，无应答）时判为"没收到带 CRC 的应答"，**跳过比较**——卡忙和无应答都不是 CRC 错误。

### 3.8 复位与每拍默认动作

`reset` **不在敏感列表里**（`always @(posedge clk)`），是**同步复位**：把状态回 `ST_IDLE`、分频器清零、`crc_q=0`，三根 SPI 线都置 1（空闲电平），并清 `resp0/1`、`busy`、`done`、`crc7_err`。TB 的 `do_reset` 断言复位后 `cs_n=1 busy=0 done=0 crc7_err=0`。

非复位分支开头两句是**每拍默认值**：`done <= 1'b0;` 与 `busy <= (state_q != ST_IDLE) | (start & (state_q == ST_IDLE));`。`done` 先清、特例再置，就是**单拍脉冲**写法；`busy` 在"当前非空闲"或"这一拍接受 start"时为高，于是从接受 start 那拍一直高到结束帧那拍。TB 的 `wait_done` 检查 `done` 那拍 `busy` 仍高、之后一拍落下。

### 3.9 空闲态：接受 start 就"清分频器 + 拉低 CS/clock"

`if (state_q == ST_IDLE)` 里每拍把三根线写回高电平；`if (start)` **只在空闲态被接受**（帧中再来的 `start` 走不到这里、被忽略，TB 的 `stray` 分支专门断言）。接受这拍做四件事：锁存 `cmd`/`arg`；**组合地**算好 `crc_q = crc7_msg({2'b01, cmd[5:0], arg})`；**清分频器** `div_cnt_q<=0`；把 `clk_q` 和 `cs_n_q` **同时拉低**。因为分频器从 0 起算、`tick` 要 `QTR` 拍后才来，而 `CS` 下降就在这一拍，所以"第一条边沿距 `CS` 下降是固定的 2 个 tick"。

### 3.10 发送态：一个四相位的小状态机

`else if (tick)` 里**每 `tick` 走一步**，`phase_q` 在 0..3 循环，**每个 SPI 位花 4 个 tick**：

| `phase_q` | 动作 | `spi_clk` |
|---|---|---|
| 0 | `mosi_q <= tx_byte[7-bit_idx_q]`（MOSI 变，时钟仍低） | 低 |
| 1 | `clk_q <= 1`——**卡在此上升沿采样 MOSI** | 低→高 |
| 2 | `rx_byte_q <= {rx_byte_q[6:0], spi_miso}`（卡仍握着 MISO） | 高 |
| 3 | `clk_q <= 0`——卡可在此下降沿之后改 MISO | 由高变低 |

`spi_clk` 在相位 1、2 为高、相位 3、0 为低，**每个半周期恰好 2 个 tick**，占空比严格 **50%**，半周期 = `CLK_HZ/(2*SPI_HZ)`（默认 `2×13=26`）。MOSI 在相位 0（clock 低）就位、到上升沿有半个周期**建立时间**；MISO 在相位 2（clock 仍高）采样、到下降沿有半个周期**保持时间**——这就是 SPI mode 0。TB 用真实边沿核对：`hi_len==lo_len`、半周期落在 `HALF±1`（`HALF=26`）。

### 3.11 相位 3：字节边界

相位 3 是"这一位的下降沿"，也是唯一做进位的地方：

- **未到第 8 位**（`bit_idx_q != 7`）：`bit_idx_q++`，继续同一字节。
- **第 8 位且已到收尾态**（`ST_TAIL`）：这一字节是第 15 个。做：`cs_n_q<=1`（拉高片选）、回 `ST_IDLE`、`done<=1`；并在 `crc_check_en && !resp_skip && 不匹配` 时把 `crc7_err` 置 1（**粘滞**，只有复位才清）。
- **第 8 位且在普通态**（`ST_BIT`）：一个字节发完。`byte_idx_q==6` 把收满的 `rx_byte_q` 存进 `resp0`，`==7` 存进 `resp1`（应答第 1、2 字节）。`byte_idx_q==LAST_RX(13)` 时**不递增**而切到 `ST_TAIL`；收尾态再用 0xFF 发一个字节即收工——0..13 共 14 个 + 收尾 1 个 = **15 个字节**。

落到总数上：字节 0..5 命令帧（48 个时钟），字节 6、7 两个哑字节（16 个时钟，正好捕捉 `resp0`/`resp1`），字节 8..13 继续摇应答（48 个时钟），第 15 个字节再补 8 个时钟——**合计 120 个 `spi_clk`**，保证 `CS` 拉高前满足"应答之后再给足 8 个时钟"。

### 3.12 输出

最后三条 `assign` 把 `clk_q`/`cs_n_q`/`mosi_q` 接到三根 SPI 引脚；用 `assign` 而非把端口声明成 `reg`，是为了让"内部状态"与"引脚"分开、便于观察。

---

## 4. 端口/参数表

| 参数 | 默认 | 含义 |
|---|---|---|
| `CLK_HZ` | 21477272 | 系统时钟频率，只用于算分频 |
| `SPI_HZ` | 400000 | 目标 SPI 时钟频率 |

| 端口 | 方向 | 位宽 | 作用 |
|---|---|---|---|
| `clk` / `reset` | in | 1 | 系统时钟 / 高有效**同步**复位 |
| `start` | in | 1 | 1 拍脉冲，**只在 `ST_IDLE` 被接受** |
| `cmd[5:0]` / `arg[31:0]` | in | 6/32 | 命令号；参数（大端移出） |
| `crc_check_en` | in | 1 | 使能应答 CRC 校验；0 则完全不比较 |
| `spi_miso` | in | 1 | 主入从出，在 `phase_q==2` 的 tick 采样 |
| `spi_clk` / `spi_cs_n` / `spi_mosi` | out | 1 | SPI 时钟（空闲高、50% 占空）/ 片选（低有效）/ 主出从入（MSB first，哑字节恒 1） |
| `resp0[7:0]` / `resp1[7:0]` | out | 8 | 应答第 1、2 字节（字节 6、7 收到） |
| `busy` | out | 1 | 接受 `start` 那拍起为高，到 `done` 那拍仍高 |
| `done` | out | 1 | 结束帧那一拍脉冲一次 |
| `crc7_err` | out | 1 | 粘滞的应答 CRC 错误标志，只有复位才清 |

---

## 5. 一帧 CMD17 逐相位走一遍

取 TB 那一帧：`run_frame(6'h11, 32'h00001234, 8'h51, 8'h00)`——发 **CMD17**，参数 `32'h00001234`，期望应答 `resp0=0x51`。先算 6 个命令字节：

| `byte_idx_q` | 值 | 由来 |
|---|---|---|
| 0 | `8'h51` | `8'h40 \| 6'h11` |
| 1..4 | `00 00 12 34` | `arg` 大端 |
| 5 | `8'h15` | `{CRC7, 1'b1}`，本帧 CRC7 = `7'h0A` |

CRC7 由 `crc7_msg({2'b01, 6'h11, 32'h00001234})` 算出。TB 用**独立的长除法** `ref_crc7`（整体乘 `x^7` 再用 `0x89` 按位长除，与 DUT 的逐位 LFSR 是两套结构）复核这一字节，并额外锚定**外部已知值**：CMD0（参数 0）的 CRC 字节在 SD 规范里是 `0x95`，单独断言 `in_byte[5]==8'h95`。**若 TB 照抄 DUT 的 LFSR，两边错在同一处也会"通过"（自证），所以必须用独立算法。**

第 0 个字节 `8'h51 = 0101_0001`，MSB first 依次发 `0 1 0 1 0 0 0 1`。第 0 位（bit7=`0`）：相位 0 把 `tx_byte[7]=0` 摆上 MOSI，相位 1 升钟（卡此刻采样 `0`），相位 2 采 MISO，相位 3 降钟并把 `bit_idx_q` 0→1；下一位（bit6=`1`）重复这四拍，只是摆 `tx_byte[6]=1`……整帧字节流是

```text
51 00 00 12 34 15 | FF FF FF FF FF FF FF FF FF
└─ 6 个命令字节 ─┘ └─ 9 个哑字节（72 个时钟）─┘   = 120 个 spi_clk
```

前 48 位对照 `exp_frame` 拼出的期望位串，后 72 位（`k=48..119`）必须全为 1，`in_total` 必须等于 **120**。TB 还数到 **121 上升沿 / 121 下降沿**：120 个周期本该 120/120，多出的一个下降沿来自"接受 start 那拍把空闲高的 `spi_clk` 拉低"，多出的一个上升沿来自"帧结束回空闲后 `spi_clk` 升回高"。应答在字节 6/7 收满时分别存入 `resp0`/`resp1`，最后断言 `resp0==0x51 && resp1==0x00`。

---

## 6. 常见疑问

**Q：为什么一帧要发 9 个 0xFF，收完应答不停？**
A：SPI 模式下应答最多延迟 `Ncr` 个字节，主机必须**继续给时钟**卡才吐得出来。前 8 个哑字节提供 64 个时钟把应答摇出来；第 9 个再补 8 个时钟，满足"应答之后再给足 8 个时钟才可拉高 CS"。所以 `CS` 从低到高是**固定 120 个周期**。

**Q：为什么 `crc7_err` 要"粘滞"？**
A：一帧 CRC 错误说明通信出了大问题，不该被后续帧的偶然正常覆盖；它保持到复位，让上层能可靠看到"曾经出过错"。

**Q：为什么 `resp0[7:1]` 全 1 或全 0 要跳过、不算错？**
A：全 1（`0xFF`/`0x7F`）是**卡忙**，全 0（`0x00`）是**无应答**，都**不是**"收到带 CRC 的应答"，没有 CRC 可校验。TB 对这两种情况都断言"不置 `crc7_err`"。

**Q：`start` 拉高两拍会重复启动吗？**
A：不会。`start` 只在 `ST_IDLE` 被接受，接受**同一拍** `state_q` 就变 `ST_BIT`，之后再也进不去 `if(start)`。TB 的 `stray` 分支在帧中途强拉 `start`，断言 `busy` 不掉、也不会开新帧。

**Q：这个模块现在被谁用？**
A：**没有任何模块例化它**，TF 卡一根线还没接。它目前的全部价值是把"SPI 命令帧 + CRC7"做成可仿真的确定行为，为上层的 SD 初始化/块读打好发送侧地基。

---

## 7. 你应该带走的三件事

1. **协议发送器 = 分频器 + 状态机 + 相位计数器**：`tick` 决定"多久走一步"，`phase_q` 决定"这一步摆数据、升时钟、采 MISO 还是降时钟"，`state_q`/`byte_idx_q`/`bit_idx_q` 决定"发到哪了"。
2. **位序和字节序是协议的一部分**：字节 MSB first、`arg` 大端、命令字节 `8'h40|cmd`、CRC 字节 `{crc7,1'b1}`——错一位整帧就废；CRC7 用逐位 LFSR 实现，与长除法等价。
3. **时序账要能对上**：一位 4 个 tick、半周期 2 个 tick（50% 占空）、一帧 15 字节 = 120 个 `spi_clk`；TB 的 121/121 边沿、26 clk 半周期都是这条账的直接推论。

下一篇 [`26-i2s-shifter.md`](26-i2s-shifter.md) 看另一类"位串行器"：把音频采样按 I2S 协议一位一位推出去。
