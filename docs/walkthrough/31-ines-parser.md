# 31 按字节吃文件头：`ines_header_parser.v`

一个 NES 卡带文件（`.nes`）开头有 **16 个字节**，叫 **iNES 文件头**。它是一张"身份证"：告诉程序这张卡用哪个 mapper、PRG/CHR 各多大、名字表怎么镜像。这一篇拆的是**硬件版解析器**：它不读文件，只把这 16 个字节搬进寄存器、按位解释成一组配置，并检查文件长度对不对。

- 源码：[`rtl/nes_core/cart/ines_header_parser.v`](../../rtl/nes_core/cart/ines_header_parser.v)
- 合同与证据：[`../modules/ines-loader.md`](../modules/ines-loader.md)
- 测试目标：`cart-ines-tb`（[`tb/cart/tb_ines_header_parser.v`](../../tb/cart/tb_ines_header_parser.v)），跑它：`.\tools\sim_all.ps1 -Mode cart-ines-tb`
- 前置：[`01-verilog-basics.md`](01-verilog-basics.md)、[`02-project-conventions.md`](02-project-conventions.md)、结构范本 [`10-mapper-nrom.md`](10-mapper-nrom.md)（那篇纯组合，这篇是"16 拍 FSM + 一组寄存器"）。

---

## 1. 定位：它在系统里的哪一环

```text
外部（SD/TF/Flash/比特流）        ┌──────────────────────┐
  header[127:0]  ───────────────►│  ines_header_parser  │──► valid / error
  actual_size[31:0] ────────────►│  (本模块：配置阶段)   │──► mapper_id / mirroring
  start / clk / reset ──────────►│  16 字节日 → 配置     │──► prg_size / chr_size / expected_size
                                  └──────────────────────┘──► done（1 拍脉冲）
                                             ▼
                                   nes_mapper / ROM 搬运引擎（下一篇 32-cart-rom.md）
```

它**只做一件事**：16 字节头 → 一组配置寄存器。它**不**读文件、不搬 PRG/CHR 数据、不持有 ROM。文件真实长度 `actual_size` 由外部（`ftell`、SD 目录项、Flash 长度表）算好传进来。

和软件对比（最值得记住的一句）：软件里 `fread(buffer,16,1,file)` 一次拿到 16 字节、位运算立刻出结果、不需要时钟；硬件里**必须真的一个字节一个字节地搬**，还要有"搬完了没有"的握手。字段含义两边一样，"什么时候搬第几个字节"完全不一样。

---

## 2. 全文代码

### 2.1 段一：参数与状态码（第 1–47 行）

端口定义见第 4 节端口表，此处只贴参数与常量：

```verilog
`timescale 1ns/1ps
module ines_header_parser #(
    parameter [3:0] INES_DEFAULT_RAM_SHIFT = 4'd7
)( /* 5 个输入 + 25 个输出，见第 4 节 */ );

    localparam [3:0] ERR_NONE=4'd0, ERR_MAGIC=4'd1, ERR_PRG_ZERO=4'd2,
                     ERR_EXPONENT=4'd3, ERR_SIZE_SHORT=4'd4;
    localparam [1:0] ST_IDLE=2'd0, ST_FETCH=2'd1, ST_DECODE=2'd2;
```

### 2.2 段二：寄存器与组合译码（第 49–135 行）

```verilog
    reg [1:0] state;  reg [3:0] byte_index;
    reg [127:0] hdr_q; reg [31:0] size_q;

    reg valid_r; reg [3:0] error_r; reg nes2_r, dirty_r;
    reg [11:0] mapper_r; reg [3:0] submapper_r; reg [25:0] prg_size_r, chr_size_r;
    reg [1:0] mirroring_r, timing_r; reg four_screen_r, trainer_r, battery_r;
    reg [3:0] prg_shift_r, chr_shift_r; reg prg_exp_r, chr_exp_r;
    reg prg_ram_exp_r, chr_ram_exp_r; reg [27:0] expected_r; reg trailing_r;

    wire [6:0] byte_offset = {byte_index, 3'b000};

    wire [7:0] f4=hdr_q[39:32],  f5=hdr_q[47:40],  f6=hdr_q[55:48],
               f7=hdr_q[63:56],  f8=hdr_q[71:64],  f9=hdr_q[79:72],
               f10=hdr_q[87:80], f11=hdr_q[95:88], f12=hdr_q[103:96];

    wire magic_ok = (hdr_q[7:0]==8'h4E) && (hdr_q[15:8]==8'h45) &&
                   (hdr_q[23:16]==8'h53) && (hdr_q[31:24]==8'h1A);
    wire tail_zero = (hdr_q[127:96] == 32'd0);

    wire nes2_d       = (f7[3:2] == 2'b10);
    wire clean_ines_d = (f7[3:2] == 2'b00) && tail_zero;
    wire dirty_d      = !nes2_d && !clean_ines_d;

    wire [11:0] mapper_ines   = {4'd0, f7[7:4], f6[7:4]};
    wire [11:0] mapper_nes2   = {f8[3:0], f7[7:4], f6[7:4]};
    wire [11:0] mapper_masked = {8'd0, f6[7:4]};
    wire [11:0] mapper_d = nes2_d ? mapper_nes2 :
                          dirty_d ? mapper_masked : mapper_ines;
    wire [3:0] submapper_d = nes2_d ? f8[7:4] : 4'd0;

    wire [11:0] prg_blocks = nes2_d ? {f9[3:0], f4} : {4'd0, f4};
    wire [11:0] chr_blocks = nes2_d ? {f9[7:4], f5} : {4'd0, f5};
    wire [25:0] prg_size_d = {prg_blocks, 14'd0};
    wire [25:0] chr_size_d = {1'b0, chr_blocks, 13'd0};

    wire trainer_d = f6[2];
    wire [27:0] expected_d = 28'd16 + (trainer_d ? 28'd512 : 28'd0)
                              + {2'b00, prg_size_d} + {2'b00, chr_size_d};
    wire size_short = ({4'd0, size_q} < expected_d);
    wire size_long  = ({4'd0, size_q} > expected_d);

    wire [3:0] prg_shift_d = nes2_d ? f10[3:0] : INES_DEFAULT_RAM_SHIFT;
    wire [3:0] chr_shift_d = nes2_d ? f11[3:0] : INES_DEFAULT_RAM_SHIFT;
    wire prg_exp_d = nes2_d && (f9[7:4] != 4'h0);
    wire chr_exp_d = nes2_d && (f9[3:2] != 2'b00);
    wire prg_ram_exp_d = nes2_d && (f10[7:6] != 2'b00);
    wire chr_ram_exp_d = nes2_d && (f11[7:6] != 2'b00);
    wire exponent_d = prg_exp_d | chr_exp_d | prg_ram_exp_d | chr_ram_exp_d;

    wire [1:0] timing_d = nes2_d ? f12[1:0] : 2'b00;
    wire [1:0] mirroring_d = f6[0] ? 2'b01 : 2'b00;
    wire four_screen_d = f6[3];
    wire battery_d = f6[1];

    wire [3:0] error_d = !magic_ok            ? ERR_MAGIC :
                        (prg_blocks == 12'd0) ? ERR_PRG_ZERO :
                        exponent_d            ? ERR_EXPONENT :
                        size_short            ? ERR_SIZE_SHORT : ERR_NONE;
    wire keep_d = magic_ok;
```

### 2.3 段三：输出赋值与状态机（第 137–241 行）

第 137–161 行是 **28 行同构的 `assign 输出 = 对应 _r 寄存器;`**（如 `assign mapper_id = mapper_r;`、`busy = (state != ST_IDLE)`、`done = (state == ST_DECODE)`、`dbg_header = hdr_q`），逐一列在第 4 节端口表，此处不重复贴。

```verilog
    always @(posedge clk or posedge reset) begin
        if (reset) begin
            state <= ST_IDLE;   byte_index <= 4'd0;
            hdr_q <= 128'd0;    size_q <= 32'd0;
            valid_r <= 1'b0;    error_r <= ERR_NONE;
            /* 其余全部 _r 寄存器——mapper/submapper、prg/chr 容量、mirroring、
               four_screen/trainer/battery、RAM shift、timing、四个 exponent、
               expected_r、trailing_r——同样在此清 0；逐项见第 4 节端口表 */
        end else begin
            case (state)
                ST_IDLE: begin
                    if (start) begin
                        hdr_q <= 128'd0;  size_q <= actual_size;
                        byte_index <= 4'd0; state <= ST_FETCH;
                    end
                end

                ST_FETCH: begin
                    hdr_q[byte_offset +: 8] <= header[byte_offset +: 8];
                    if (byte_index == 4'd15) begin
                        byte_index <= 4'd0;  state <= ST_DECODE;
                    end else begin
                        byte_index <= byte_index + 4'd1;
                    end
                end

                ST_DECODE: begin
                    valid_r       <= (error_d == ERR_NONE);
                    error_r       <= error_d;
                    nes2_r        <= keep_d && nes2_d;
                    dirty_r       <= keep_d && dirty_d;
                    mapper_r      <= keep_d ? mapper_d : 12'd0;
                    submapper_r   <= keep_d ? submapper_d : 4'd0;
                    prg_size_r    <= keep_d ? prg_size_d : 26'd0;
                    chr_size_r    <= keep_d ? chr_size_d : 26'd0;
                    mirroring_r   <= keep_d ? mirroring_d : 2'd0;
                    four_screen_r <= keep_d && four_screen_d;
                    trainer_r     <= keep_d && trainer_d;
                    battery_r     <= keep_d && battery_d;
                    prg_shift_r   <= keep_d ? prg_shift_d : 4'd0;
                    chr_shift_r   <= keep_d ? chr_shift_d : 4'd0;
                    timing_r      <= keep_d ? timing_d : 2'd0;
                    prg_exp_r     <= keep_d && prg_exp_d;
                    chr_exp_r     <= keep_d && chr_exp_d;
                    prg_ram_exp_r <= keep_d && prg_ram_exp_d;
                    chr_ram_exp_r <= keep_d && chr_ram_exp_d;
                    expected_r    <= keep_d ? expected_d : 28'd0;
                    trailing_r    <= keep_d && size_long;
                    state         <= ST_IDLE;
                end

                default: state <= ST_IDLE;
            endcase
        end
    end
```

> 原文里 `reg` 声明、复位块都是一行一个（第 54–74、164–189 行），这里并列/注释写以省行；`ST_FETCH`/`ST_DECODE` 分支与原文逐字一致。整份代码只有**一个** `always`，它同时是状态机和输出寄存器——本项目最典型的一种复合结构。

---

## 3. 逐段精读

### 3.1 头的 16 个字节各管什么（全篇地图）

| 字节 | 含义 |
|---|---|
| 0–3 | magic `4E 45 53 1A`（ASCII 为 `N` `E` `S` + MS-DOS EOF `0x1A`） |
| 4 | PRG ROM 大小，单位 **16 KiB 块**；5 是 CHR，单位 **8 KiB 块**（0 = 用 CHR RAM） |
| 6 | flags6：bit0 镜像、bit1 battery、bit2 trainer、bit3 four-screen、bit7–4 mapper 低 4 位 |
| 7 | flags7：bit3–2 格式标识、bit7–4 mapper 高 4 位 |
| 8–15 | iNES 未用；**NES 2.0** 里承载扩展字段（mapper 高位、submapper、容量高位、RAM shift、timing） |

命名上：`f4`…`f12` 是切出的字节、`xxx_d` 是组合算出的译码结果（都是 `wire`），`xxx_r` 是真正存住的寄存器（`reg`，在 `ST_DECODE` 那一拍写入）——即第 02 篇 `_next`/`_q` 套路，后缀换成了 `_d`/`_r`。

### 3.2 字节切片与 magic

约定"**字节 0 在最低位**"，所以 byte `i` = `hdr_q[8*i +: 8]`，如 `f4 = hdr_q[39:32]` 就是 byte4。这跟"把 16 字节写成一个大十六进制数"的直觉正相反。

```verilog
wire magic_ok = (hdr_q[7:0]==8'h4E) && (hdr_q[15:8]==8'h45) &&
                (hdr_q[23:16]==8'h53) && (hdr_q[31:24]==8'h1A);
```

为什么不写 `hdr_q[31:0] == 32'h4E45531A`？因为"字节 0 在低位"时那个 32 位常数其实应是 `32'h1A53454E`，写一次比较极容易把首字节写反。拆成四个字节比，想错都难。

### 3.3 格式三分法与 mapper/submapper

```verilog
wire nes2_d       = (f7[3:2] == 2'b10);              // NES 2.0
wire clean_ines_d = (f7[3:2] == 2'b00) && tail_zero;  // 干净 iNES（格式位00 且 byte12–15 全0）
wire dirty_d      = !nes2_d && !clean_ines_d;         // 其余 = dirty iNES
```

判 NES2 的值是 `2'b10`（bit3=1,bit2=0），不是 `01`。既非 `10` 也非 `00` 的文件归为 dirty（早期 dump / 头写坏），**只信 mapper 低 4 位**——兼容策略不是规格：保留位非 0 时接受文件但降级解析。

```verilog
wire [11:0] mapper_ines = {4'd0, f7[7:4], f6[7:4]};      // iNES：8 位
wire [11:0] mapper_nes2 = {f8[3:0], f7[7:4], f6[7:4]};   // NES2：byte8 低4位 → 12 位
```

mapper 低 4 位在 byte6 高位、高 4 位在 byte7 高位，NES2.0 再用 byte8 低 4 位扩成 12 位。dirty 文件只取 `{8'd0, f6[7:4]}`：把坏掉的 `byte7[7:4]` 当高 4 位会读出完全错误的 mapper（如坏头 `byte7=0xF4` 被误读成 0xF4）。submapper（子映射器号）仅 NES2 有，取 `byte8[7:4]`，否则恒 0。

### 3.4 容量与 `expected_size`：位宽账

```verilog
wire [25:0] prg_size_d = {prg_blocks, 14'd0};        // 块数 × 16 KiB = 左移 14
wire [25:0] chr_size_d = {1'b0, chr_blocks, 13'd0};  // 块数 × 8 KiB  = 左移 13
wire [27:0] expected_d = 28'd16 + (trainer_d ? 28'd512 : 28'd0)
                          + {2'b00, prg_size_d} + {2'b00, chr_size_d};
```

块数是 12 位（NES2 有高位扩展）。三处必须记住：① **PRG 16 KiB 一块、CHR 8 KiB 一块**，移位量 14 与 13 不同，用错 CHR 容量翻倍；② 块数 12 位 → 容量要 26 位；③ **`expected_size` 要 28 位**——两个 26 位相加再加 512 会越过 `2^26`，用 26 位存会静默溢出，恰把"文件太短"变成"看起来正好"。`expected_size` 就是"合法文件至少应有多大"。

### 3.5 exponent notation（倍率标记）

NES2.0 的 byte9 同时表达两件事：`byte9[3:0]` 是 PRG 块数高位、`byte9[7:4]` 是 CHR 块数高位，而 ×2/×3 倍率标记也挤在这几个 bit 里。本模块按常见实现判"**非零即倍率**"（`prg_exp_d = nes2_d && f9[7:4]!=0`，`chr_exp_d = nes2_d && f9[3:2]!=0`）。容量算术隐含"倍率 = 1"，故任一倍率成立就报 `ERR_EXPONENT`、`valid = 0`：**宁可不认，也不给乘错的容量**。代价是"CHR size 高位非零"的 NES2 文件也被拒——这是格式自身歧义，不是 bug。

### 3.6 错误优先级与 `keep_d`

```verilog
wire [3:0] error_d = !magic_ok            ? ERR_MAGIC :
                    (prg_blocks == 12'd0) ? ERR_PRG_ZERO :
                    exponent_d            ? ERR_EXPONENT :
                    size_short            ? ERR_SIZE_SHORT : ERR_NONE;
```

`? :` 从上到下挑：**magic 错 > PRG 数为 0 > 倍率标记 > 文件太短**。magic 错时其余字段全是垃圾，报更具体的错是误导；PRG 为 0 说明头本身非法（真实卡至少 16 KiB PRG）；倍率说明容量前提不成立；最后才轮到长度。`size_short = actual_size < expected_size`；`size_long`（文件更长）**不是错误**，只置 `size_trailing`。另外 `wire keep_d = magic_ok;`：magic 一失败 `keep_d=0`，`ST_DECODE` 里所有字段清零（`keep_d ? xxx_d : 0`），但 `error`（=ERR_MAGIC）与 `dbg_header`（原始头）保留供诊断。

### 3.7 段三：16 拍字节索引 FSM

| 状态 | 拍数 | 做什么 |
|---|---|---|
| `ST_IDLE` | 1 | 采样 `start`，清 `hdr_q`、`byte_index=0`，把 `actual_size` 锁进 `size_q` |
| `ST_FETCH` | 16 | 一拍搬一个字节，`byte_index` 从 0 数到 15 |
| `ST_DECODE` | 1 | 用 `hdr_q`/`size_q` 一次算全字段与错误码，写进输出寄存器 |

```verilog
wire [6:0] byte_offset = {byte_index, 3'b000};          // byte_index * 8
ST_FETCH: begin
    hdr_q[byte_offset +: 8] <= header[byte_offset +: 8]; // 搬第 byte_index 个字节
    if (byte_index == 4'd15) begin byte_index <= 4'd0; state <= ST_DECODE; end
    else                       byte_index <= byte_index + 4'd1;
end
```

`byte_offset = {byte_index, 3'b000}` 把 4 位索引左移 3 位（乘 8），得到字节在 128 位里的**起始 bit**；`hdr_q[基址 +: 8]` 是**可变 part-select**，4 位索引正好选 16 个位置。`byte_index` 数到 15 后**清 0** 再进 `ST_DECODE`（所以 testbench 断言"译码后 `dbg_byte_index` 回到 0"）。从 `start` 被采样到 `done` 结束共 **17 个时钟沿**（16 搬 + 1 译码），`busy` 高 17 拍（`done` 那拍仍为 1）。`start` 在 `ST_FETCH`/`ST_DECODE` 里**没有判断**，故解析期间 `start` 保持高不会重启；唯一中止手段是 `reset`。

---

## 4. 端口表

| 端口 | 方向 | 位宽 | 对应寄存器 | 作用 |
|---|---|---|---|---|
| `clk` / `reset` | in | 1 | — | `reset` 异步高有效，清状态机与全部输出寄存器 |
| `start` | in | 1 | — | 1 拍脉冲启动解析；`busy` 期间被忽略 |
| `header` | in | 128 | — | 16 字节头，字节 0 在最低位，`start` 后 16 拍内须稳定 |
| `actual_size` | in | 32 | `size_q` | 文件真实字节数，外部传入 |
| `busy` / `done` | out | 1 | — | `state != ST_IDLE` / 译码那拍为 1（1 拍脉冲） |
| `valid` / `error` | out | 1 / 4 | `valid_r` / `error_r` | `error==0` 为 1；错误码见 3.6 |
| `nes2` / `dirty_ines` | out | 1 | `nes2_r` / `dirty_r` | 格式判定，见 3.3 |
| `mapper_id` / `submapper_id` | out | 12 / 4 | `mapper_r` / `submapper_r` | 见 3.3；submapper 仅 NES2 |
| `prg_size_bytes` | out | 26 | `prg_size_r` | `prg_blocks × 16384` |
| `chr_size_bytes` | out | 26 | `chr_size_r` | `chr_blocks × 8192`（0 = CHR RAM） |
| `mirroring` | out | 2 | `mirroring_r` | `00` = horizontal，`01` = vertical |
| `four_screen` / `trainer` / `battery` | out | 1 | `_r` | byte6[3]/[2]/[1]；trainer 另给 `expected_size` 加 512 |
| `prg_ram_shift` / `chr_ram_shift` | out | 4 | `_r` | 容量 = `64 << shift` |
| `cpu_ppu_timing` | out | 2 | `timing_r` | 仅 NES2（byte12[1:0]），否则 0 |
| `*_exponent`（四个） | out | 1 | `_r` | prg/chr/ram 倍率标记，见 3.5 |
| `expected_size` | out | 28 | `expected_r` | 见 3.4 |
| `size_trailing` | out | 1 | `trailing_r` | 文件比 `expected_size` 长（不是错误） |
| `dbg_byte_index` / `dbg_header` | out | 4 / 128 | `byte_index` / `hdr_q` | 当前索引 / 锁存的原始头（不受 magic 失败清零） |

所有输出寄存器只在 `done` 那一拍更新，之后保持到下一次 `done`；复位是唯一清零手段。

---

## 5. 代入一个 16 字节头走一遍

取 **mapper=0、PRG=2 块（32 KiB）、CHR=1 块（8 KiB）、horizontal 镜像**，即一张 NROM-256（与 [`10-mapper-nrom.md`](10-mapper-nrom.md) 例 A 同一张卡）。16 个字节是：

| 偏移 | 值 | 字段 |
|---|---|---|
| 0–3 | `4E 45 53 1A` | magic，拼 128 位字时落在最低 4 字节 |
| 4 / 5 | `02` / `01` | PRG 块数 2 → 32 KiB；CHR 块数 1 → 8 KiB |
| 6 | `00` | 镜像 horizontal、battery/trainer/four-screen=0、mapper 低 4 位=0 |
| 7 | `00` | 格式位 `00`（clean iNES）、mapper 高 4 位=0 |
| 8–15 | `00` | 尾部全零（`tail_zero=1`） |

按"字节 0 在低位"拼成 128 位字：`header = {64'h0, 8'h00, 8'h00, 8'h01, 8'h02, 8'h1A, 8'h53, 8'h45, 8'h4E}`。

**FSM 16 拍**：第 `i` 拍执行 `hdr_q[i*8 +: 8] <= header[i*8 +: 8]`，`byte_index` 依次 0…15，搬完后 `hdr_q` 就等于 `header`；切出 `f4=02, f5=01, f6=00, f7=00, f8…f12=00`。

| 输出 | 计算 | 结果 |
|---|---|---|
| `magic_ok` / `tail_zero` | magic 全对；byte12–15 全 0 | 1 / 1 |
| `nes2` / `dirty_ines` | `f7[3:2]=00 ≠ 10`；clean iNES | 0 / 0 |
| `mapper_id` / `submapper_id` | `{4'd0,0,0}`；非 NES2 | **0** / 0 |
| `prg_size_bytes` / `chr_size_bytes` | `2<<14` / `1<<13` | **32768** / **8192** |
| `trainer` / `expected_size` | `f6[2]=0`；`16+0+32768+8192` | 0 / **40976** |
| `prg_ram_shift` / `chr_ram_shift` | 非 NES2 → 默认 | 7 / 7 |
| `mirroring` / `four_screen` / `battery` | `f6[0]=0→00`；`f6[3]`；`f6[1]` | **00 horiz** / 0 / 0 |
| `cpu_ppu_timing` / 四个 exponent | 非 NES2 | 0 / 全 0 |
| `error` / `valid` | magic 对、块数非 0、无倍率、长度够 | **0** / **1** |

**再代入三种 `actual_size`**（`test_file_size_check` 覆盖的正是这三情形）：`40976`（正好）→ `error=0, valid=1, size_trailing=0`；`40000`（短了）→ `size_short=1`，`error=4`、`valid=0`；`50000`（多了）→ `size_long=1`，`error=0`、`valid=1`、`size_trailing=1`。**短了报错、正好干净、长了只挂标志**——这就是本模块的边界行为合同。

---

## 6. 常见疑问

**Q：128 位头是并行口，为什么还要走 16 拍？** A：真实硬件里头不是并行出现的（ROM 在 SD/TF/Flash 里，字节一拍一个出来）。写成"宽口 + 一拍一字节"的 FSM，以后接 SD 控制器只需把 `header` 换成"读数据寄存器"、FSM 一行不改；且不依赖"16 字节同时到齐"的假设，`dbg_byte_index` 还让顺序可逐拍断言。代价是 `header` 必须在 16 拍内保持稳定。

**Q：`done` 为什么是一拍脉冲？** A：`done = (state == ST_DECODE)`，该状态只有一拍。上层把它当"配置寄存器已更新"的唯一事件，做一次搬运启动即可。

**Q：magic 失败为什么还保留 `dbg_header`？** A：`error` 只说"头坏了"，`dbg_header` 让你看到**坏在哪**（哪个字节不对），纯诊断，不影响逻辑。

**Q：dirty 文件还能 `valid = 1` 合理吗？** A：合理。dirty 是"格式位非 00 也非 NES2"的降级策略：这类文件现实大量存在，直接拒绝会误伤。本模块选择**接受但只信一半字段**（mapper 只取低 4 位），并置 `dirty_ines=1` 让上层决定是否提示用户。

**Q：`INES_DEFAULT_RAM_SHIFT = 7` 是规格吗？** A：不是，是大多数模拟器对非 NES2 文件的默认策略（8 KiB），不是 iNES 规范。改它不改变任何位图解释。

---

## 7. 你应该带走的三件事

1. **文件头 = 一组按位摆放的配置**：magic 判格式、byte4/5 是块数、byte6/7 藏 mirroring/battery/trainer/four-screen 与 mapper 号，NES2.0 再用 byte8–12 扩展 mapper、submapper、容量高位、RAM shift、timing。
2. **"组合译码 + 时序存住"的复合块**：一个 `always` 同时当 FSM 和输出寄存器——`ST_FETCH` 搬字节，`ST_DECODE` 把 `_d` 组合值一次写进 `_r`；错误优先级用嵌套 `? :` 一行表清：magic > PRG=0 > exponent > size。
3. **边界检查必须有位宽账**：PRG 左移 14、CHR 左移 13、`expected_size` 必须 28 位；`actual_size` 三者代入（短报错 / 正好 / 长挂 `size_trailing`）就是行为合同。

下一篇 [`32-cart-rom.md`](32-cart-rom.md) 看这组寄存器怎么变成 BRAM 的初始内容与读延迟。
