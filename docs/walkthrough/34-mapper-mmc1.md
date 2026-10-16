# 34 MMC1：一个地址写 5 次的串行移位 mapper

上一篇 [`33-mapper-dispatch.md`](33-mapper-dispatch.md) 讲了 [`nes_mapper.v`](../../rtl/nes_core/mapper/nes_mapper.v) 如何按 `mapper_select` 分发到 5 个子模块。这一篇精读其中的 **MMC1**（mapper 1），它是本项目第一个**带时钟、带寄存器、带写协议**的 mapper。

- 源码：[`rtl/nes_core/mapper/nes_mapper_mmc1.v`](../../rtl/nes_core/mapper/nes_mapper_mmc1.v)
- 合同与证据：[`../modules/mappers.md`](../modules/mappers.md) 的 5.4 节
- 测试目标：`mapper-mmc1`（见 [`tb/mapper/tb_nes_mapper_mmc1.v`](../../tb/mapper/tb_nes_mapper_mmc1.v)）

MMC1 最反直觉的一点：**切 bank 不是"往一个地址写一次值"，而是"往同一个地址连写 5 次，每次只带 1 个 bit"**。这一篇就围绕这个协议展开。

---

## 1. 先认识"上游和下游"

```text
cpu_addr[14:13] ─► 选寄存器(control/CHR0/CHR1/PRG)   cpu_dout[0] ─► 每次的 1 bit
cpu_dout[7]=1   ─► 复位/清移位                       cpu_we      ─┐
ppu_addr[12]    ─► 4 KiB 半区选择                    ppu_addr    ─┴► [nes_mapper_mmc1]
   ──► prg_bank_offset ─► PRG ROM ；  chr_bank_offset ─► CHR ROM ；  mirroring ─► PPU
```

- **CPU 侧写窗口** `$8000-$FFFF`：软件通过连续 5 次写送进"想要的 bank / 镜像模式"。
- **PPU 侧读图案表**：MMC1 把 `ppu_addr` 和内部 CHR bank 寄存器拼成 **CHR ROM 字节偏移**。
- 与 NROM 最大的不同：**NROM 是纯 `assign`，MMC1 有一条 `always @(posedge clk or posedge reset)`**，因为"记住当前 bank"离不开寄存器。上游 `nes_mapper.v` 的写使能 `we_mmc1 = cpu_we && cpu_addr[15]` 已保证地址落在 `$8000-$FFFF`。

---

## 2. 全文（127 行）

```verilog
`timescale 1ns/1ps

module nes_mapper_mmc1 #(
    parameter integer PRG_ADDR_BITS = 17,
    parameter integer CHR_ADDR_BITS = 17,
    parameter integer PRG_SIZE_BYTES = 131072,
    parameter MMC1_CHR_RAM = 1'b0
)(
    input wire clk,
    input wire reset,
    input wire [15:0] cpu_addr,
    input wire cpu_we,
    input wire [7:0] cpu_dout,
    input wire [13:0] ppu_addr,
    output wire [PRG_ADDR_BITS-1:0] prg_bank_offset,
    output wire [CHR_ADDR_BITS-1:0] chr_bank_offset,
    output wire [2:0] mirroring,
    output wire prg_ram_enable,
    output wire chr_ram_enable,
    output wire irq,
    output wire [2:0] serial_count,
    output wire [4:0] serial_value,
    output wire [4:0] control,
    output wire [4:0] chr_bank0,
    output wire [4:0] chr_bank1,
    output wire [4:0] prg_bank
);

localparam [7:0] MMC1_LAST_BANK_16K = (PRG_SIZE_BYTES >> 14) - 1;
localparam [4:0] MMC1_CONTROL_RESET = 5'b01100;
localparam [4:0] MMC1_SERIAL_LAST_BIT = 3'd4;

reg [2:0] serial_count_r;
reg [4:0] serial_value_r;
reg [4:0] control_r;
reg [4:0] chr_bank0_r;
reg [4:0] chr_bank1_r;
reg [4:0] prg_bank_r;

reg [4:0] prg_bank16_select;
reg [4:0] chr_bank4k_select;
reg [2:0] mirroring_select;
wire [PRG_ADDR_BITS-1:0] prg_bank_ext;
wire [CHR_ADDR_BITS-1:0] chr_bank_ext;

always @* begin
    case (control_r[3:2])
        2'b00, 2'b01: prg_bank16_select = {prg_bank_r[4:1], cpu_addr[14]};
        2'b10: prg_bank16_select = cpu_addr[14] ? prg_bank_r : 5'd0;
        2'b11: prg_bank16_select = cpu_addr[14] ? MMC1_LAST_BANK_16K : prg_bank_r;
    endcase
end

always @* begin
    if (control_r[4])
        chr_bank4k_select = ppu_addr[12] ? chr_bank1_r : chr_bank0_r;
    else
        chr_bank4k_select = {chr_bank0_r[4:1], ppu_addr[12]};
end

assign prg_bank_ext = {{(PRG_ADDR_BITS-5){1'b0}}, prg_bank16_select};
assign chr_bank_ext = {{(CHR_ADDR_BITS-5){1'b0}}, chr_bank4k_select};

assign prg_bank_offset = (prg_bank_ext << 14) | {{(PRG_ADDR_BITS-14){1'b0}}, cpu_addr[13:0]};
assign chr_bank_offset = (chr_bank_ext << 12) | {{(CHR_ADDR_BITS-12){1'b0}}, ppu_addr[11:0]};
// chr_bank_offset is the FINAL CHR byte address, not a displacement to be added
// to somewhere else. ppu_addr must be the LOCAL CHR byte address the PPU presents
// on its chr_addr port; the 4 KiB window select and its placement are applied
// here, and the memory owner indexes CHR with the result directly. ppu_addr[13]
// (PPUCTRL[4]/[5], the pattern-table select) is deliberately dropped: it is a
// PPU-internal decode, not a cartridge address bit.
assign prg_ram_enable = ~prg_bank_r[4];
assign chr_ram_enable = MMC1_CHR_RAM;
assign irq = 1'b0;
assign serial_count = serial_count_r;
assign serial_value = serial_value_r;
assign control = control_r;
assign chr_bank0 = chr_bank0_r;
assign chr_bank1 = chr_bank1_r;
assign prg_bank = prg_bank_r;

assign mirroring = mirroring_select;

always @* begin
    case (control_r[1:0])
        2'd0: mirroring_select = 3'd2;
        2'd1: mirroring_select = 3'd3;
        2'd2: mirroring_select = 3'd1;
        default: mirroring_select = 3'd0;
    endcase
end

always @(posedge clk or posedge reset) begin
    if (reset) begin
        serial_count_r <= 3'd0;
        serial_value_r <= 5'd0;
        control_r <= MMC1_CONTROL_RESET;
        chr_bank0_r <= 5'd0;
        chr_bank1_r <= 5'd0;
        prg_bank_r <= 5'd0;
    end else if (cpu_we) begin
        if (cpu_dout[7]) begin
            serial_count_r <= 3'd0;
            serial_value_r <= 5'd0;
            control_r <= MMC1_CONTROL_RESET;
            chr_bank0_r <= 5'd0;
            chr_bank1_r <= 5'd0;
            prg_bank_r <= 5'd0;
        end else begin
            serial_value_r[serial_count_r] <= cpu_dout[0];
            if (serial_count_r == MMC1_SERIAL_LAST_BIT) begin
                serial_count_r <= 3'd0;
                serial_value_r <= 5'd0;
                case (cpu_addr[14:13])
                    2'b00: control_r <= {cpu_dout[0], serial_value_r[3:0]};
                    2'b01: chr_bank0_r <= {cpu_dout[0], serial_value_r[3:0]};
                    2'b10: chr_bank1_r <= {cpu_dout[0], serial_value_r[3:0]};
                    default: prg_bank_r <= {cpu_dout[0], serial_value_r[3:0]};
                endcase
            end else begin
                serial_count_r <= serial_count_r + 3'd1;
            end
        end
    end
end

endmodule
```

---

## 3. 逐段精读

### 3.1 常量与寄存器声明

```verilog
localparam [7:0] MMC1_LAST_BANK_16K = (PRG_SIZE_BYTES >> 14) - 1;   // 128K>>14=8, -1=7
localparam [4:0] MMC1_CONTROL_RESET = 5'b01100;                     // 复位后的 control
localparam [4:0] MMC1_SERIAL_LAST_BIT = 3'd4;                       // 第 5 次的计数

reg [2:0] serial_count_r;   // 已收几位（0..4）
reg [4:0] serial_value_r;   // 已收到的位，bit0 在 [0]
reg [4:0] control_r;        // [4]chr_mode [3:2]prg_mode [1:0]mirroring
reg [4:0] chr_bank0_r;      // $A000 寄存器
reg [4:0] chr_bank1_r;      // $C000 寄存器
reg [4:0] prg_bank_r;       // $E000 寄存器，[4]=PRG-RAM disable
```

`131072 >> 14 = 8`，`-1` 得 **7**——128 KiB PRG 的末 bank（偏移 `7*0x4000 = $1C000`）。`MMC1_CONTROL_RESET = 5'b01100` 是 `chr_mode=0`、`prg_mode=3`、single lower，即**上电默认 $8000 可切、$C000 固定末 bank**。`serial_count_r`/`serial_value_r` 是"工作台"，真正被软件使用的 4 个目标寄存器是 `control_r`/`chr_bank0_r`/`chr_bank1_r`/`prg_bank_r`；另有 6 个同名输出端口只把内部寄存器引出来给 testbench 断言（规则同 `dbg_*`：只看，不影响逻辑）。

### 3.2 移位寄存器写块与"为什么写 5 次"

```verilog
always @(posedge clk or posedge reset) begin
    if (reset)                        ...全清，control 回 0x0C...
    else if (cpu_we) begin
        if (cpu_dout[7])              ...分支 A：复位/清移位...
        else begin
            serial_value_r[serial_count_r] <= cpu_dout[0];       // 收一位
            if (serial_count_r == MMC1_SERIAL_LAST_BIT)  ...第 5 次：提交...
            else serial_count_r <= serial_count_r + 3'd1;        // 否则计数+1
        end
    end
end
```

优先级从上到下：**`reset`（异步）> 分支 A（bit7=1）> 分支 B（bit7=0）**，就是基础篇里的寄存器骨架。

**为什么写一次只收一位？** MMC1 芯片只有一个串行输入脚，软件必须把 5 位拆开、**LSB 优先**、一拍一位地送。关键一句是 `serial_value_r[serial_count_r] <= cpu_dout[0];`（新位放进第 `count` 个位置）：`serial_count_r` 是"当前要填的位号"，第 1 次写填 bit0，第 2 次填 bit1……第 5 次（`count==4`）填 bit4。这就是"**每写一次移一位**"。**分支 A（`cpu_dout[7]=1`）是软件复位**：把 `serial_count`、`serial_value`、`control` 和 3 个 bank 全清，能在序列写到一半时**中止并清零**（`test_partial_write_reset` 验证）；它和异步 `reset` 清的是同一批寄存器。

### 3.3 第 5 次提交：`case (cpu_addr[14:13])`

```verilog
if (serial_count_r == MMC1_SERIAL_LAST_BIT) begin    // 这是第 5 次
    serial_count_r <= 3'd0;                          // 清工作台
    serial_value_r <= 5'd0;
    case (cpu_addr[14:13])                           // 用地址高位选目标
        2'b00: control_r   <= {cpu_dout[0], serial_value_r[3:0]};   // $8000-$9FFF
        2'b01: chr_bank0_r <= {cpu_dout[0], serial_value_r[3:0]};   // $A000-$BFFF
        2'b10: chr_bank1_r <= {cpu_dout[0], serial_value_r[3:0]};   // $C000-$DFFF
        default: prg_bank_r <= {cpu_dout[0], serial_value_r[3:0]};  // $E000-$FFFF
    endcase
end
```

1. **目标寄存器由第 5 次写的地址决定**，看 `cpu_addr[14:13]`（`$8000-$FFFF` 被切成 4 个 8 KiB 段）。`test_register_decode` 用 4 个地址各写一次序列，验证只有对应寄存器变化。
2. **新值 = `{cpu_dout[0], serial_value_r[3:0]}`**：第 5 次的 bit 当 **bit4**，前 4 次攒下的位当 **bit3:0**。为什么不用 `serial_value_r[4:0]`？因为本行是**非阻塞赋值**，`serial_value_r[4] <= cpu_dout[0]` 这一拍还没生效，所以直接把 `cpu_dout[0]` 写进高位拼接里，结果一致又明确。

### 3.4 PRG mode：`case (control_r[3:2])`

写 `$8000` 的 `control_r[3:2]` 决定 **PRG 交换方式**，`cpu_addr[14]` 把 `$8000-$BFFF`（A14=0）和 `$C000-$FFFF`（A14=1）分开：

```verilog
case (control_r[3:2])
    2'b00, 2'b01: prg_bank16_select = {prg_bank_r[4:1], cpu_addr[14]};
    2'b10: prg_bank16_select = cpu_addr[14] ? prg_bank_r : 5'd0;
    2'b11: prg_bank16_select = cpu_addr[14] ? MMC1_LAST_BANK_16K : prg_bank_r;
endcase
```

| prg_mode | $8000-$BFFF | $C000-$FFFF | 白话 |
|---|---|---|---|
| `0`/`1` | `prg_bank_r[4:1]*2` | `+1` | 两段当成一个 32 KiB 块切（`prg_bank_r` 的 bit0 被丢弃） |
| `2` | bank 0（固定） | `prg_bank_r` | 首 bank 固定，末尾可切 |
| `3` | `prg_bank_r` | 末 bank（固定） | 首段可切，末 bank 固定（复位默认） |

模式 0/1 的 `{prg_bank_r[4:1], cpu_addr[14]}` 即 `bank = (prg_bank_r & 0x1E) | A14`——同一个 32 KiB 块的两半；bit4（PRG-RAM disable）和 bit0 都不参与（`test_prg_modes` 的 `mode1 ignores prg bank bit0`）。

### 3.5 CHR mode：4 KiB bank 怎么拼成偏移

```verilog
if (control_r[4])                                    // chr_mode=1：4 KiB 模式
    chr_bank4k_select = ppu_addr[12] ? chr_bank1_r : chr_bank0_r;
else                                                 // chr_mode=0：8 KiB 模式
    chr_bank4k_select = {chr_bank0_r[4:1], ppu_addr[12]};
```

`ppu_addr[12]` 是图案表窗口里的 **4 KiB 半区选择**（`$0000-$0FFF` 还是 `$1000-$1FFF`）：

- **chr_mode=0（8 KiB）**：两个半区来自**同一个** `chr_bank0_r`。`{chr_bank0_r[4:1], ppu_addr[12]}` = 丢掉 `chr_bank0` 最低位、换成 A12，低半区是 `bank & 0x1E`、高半区是 `bank | 1`。写 `$C000` 仍更新 `chr_bank1_r`，但此时它不参与译码。
- **chr_mode=1（4 KiB）**：`ppu_addr[12]=0` 用 `chr_bank0_r`，`=1` 用 `chr_bank1_r`，两个 4 KiB 窗口**各自独立**换 bank。

例（`test_chr_modes`）：`chr_bank0=5`，chr_mode=0。`$0000`（A12=0）→ `{0010,0}=4` → bank 4；`$1000`（A12=1）→ `{0010,1}=5` → bank 5。所谓"8 KiB 窗口"其实是 bank 4 的 4 KiB + bank 5 的 4 KiB 拼起来的——**bit0 被 A12 替代**。

### 3.6 bank 拼装与其余输出

```verilog
assign prg_bank_offset = (prg_bank_ext << 14) | {{(PRG_ADDR_BITS-14){1'b0}}, cpu_addr[13:0]};
assign chr_bank_offset = (chr_bank_ext << 12) | {{(CHR_ADDR_BITS-12){1'b0}}, ppu_addr[11:0]};
```

这一步把所有东西拼成"**ROM 数组的绝对字节偏移**"，读法固定为 **`(bank << 粒度) | 窗口内偏移`**：PRG 粒度 16 KiB = `<< 14`（偏移 `cpu_addr[13:0]`），CHR 粒度 4 KiB = `<< 12`（偏移 `ppu_addr[11:0]`）。

**为什么 CHR 是 4 KiB 粒度？** `chr_bank0/1` 的 5 位中 1 就代表一个 4 KiB 块；8 KiB 模式只是把两个块拼起来（见 3.5）。5 位 bank 最大 `$1F`，`$1F << 12 = $1F000`，再加 12 位偏移最大 `$1FFFF`——**必须 17 位才装得下**，这就是 `CHR_ADDR_BITS` 默认 17 的原因。另有一处**有意截断**：`ppu_addr[13]`（PPUCTRL 的图案表选择）是 PPU 内部译码、不是卡带地址位，所以丢掉（`test_chr_bank_addr_bits17` 验证 `chr_bank0=0x10` 需要 17 位偏移）。

```verilog
assign prg_ram_enable = ~prg_bank_r[4];   // prg_bank 的 bit4 是 PRG-RAM disable，取反
assign chr_ram_enable = MMC1_CHR_RAM;     // 参数决定 CHR 可写否
assign irq = 1'b0;                        // MMC1 没有 IRQ 源
case (control_r[1:0])
    2'd0: mirroring_select = 3'd2;   // single lower
    2'd1: mirroring_select = 3'd3;   // single upper
    2'd2: mirroring_select = 3'd1;   // vertical
    default: mirroring_select = 3'd0; // horizontal
endcase
```

镜像的**编号是打乱的**：MMC1 的 `control[1:0]` 与项目内部 `mirroring` 编码不一一对应；送出的 `mirroring` 采用统一编码（0=horizontal、1=vertical、2=single lower、3=single upper），再由 `nes_mapper.v` 的 `nametable_map_decode` 转成 8 位名字表映射（`test_mirroring_control` 断言 4 种取值）。

---

## 4. 端口表

| 端口 | 方向 | 位宽 | 作用 |
|---|---|---|---|
| `clk` | in | 1 | 唯一时钟 |
| `reset` | in | 1 | 异步复位，高有效 |
| `cpu_addr` | in | 16 | CPU 地址，写时用 `[14:13]` 选寄存器 |
| `cpu_we` | in | 1 | 写使能（上游已保证 `cpu_addr[15]=1`） |
| `cpu_dout` | in | 8 | 写数据，`[0]` 是数据位、`[7]` 是复位位 |
| `ppu_addr` | in | 14 | PPU 图案表地址，`[12]` 选 4 KiB 半区 |
| `prg_bank_offset` | out | 17 | PRG ROM 绝对字节偏移 |
| `chr_bank_offset` | out | 17 | CHR ROM 绝对字节偏移 |
| `mirroring` | out | 3 | 名字表镜像模式 |
| `prg_ram_enable` | out | 1 | `~prg_bank_r[4]` |
| `chr_ram_enable` | out | 1 | `MMC1_CHR_RAM` 参数 |
| `irq` | out | 1 | 恒 0 |
| `serial_count`/`serial_value`/`control`/`chr_bank0`/`chr_bank1`/`prg_bank` | out | 3/5/5/5/5/5 | 观测内部寄存器（见 3.1） |

状态观察端口在 `nes_mapper.v` 里接到 `mmc1_serial_count`、`mmc1_control` 等顶层端口，testbench 靠它们区分"是 bank 选择错了还是 ROM 内容错了"。

---

## 5. 连续 5 次写走一遍（从移位到装载）

以 `test_serial_needs_five_writes` 为例：对 `$E000`（选 PRG bank）连写 5 次，前 4 次 `8'h00`，第 5 次 `8'h01`。

| 第几次 | `cpu_dout` | 写前 count | 动作 | 写后 count | `serial_value_r` | `prg_bank_r` |
|---|---|---|---|---|---|---|
| 1 | `0x00` | 0 | `serial_value[0]<=0` | 1 | `00000` | `00000` |
| 2 | `0x00` | 1 | `serial_value[1]<=0` | 2 | `00000` | `00000` |
| 3 | `0x00` | 2 | `serial_value[2]<=0` | 3 | `00000` | `00000` |
| 4 | `0x00` | 3 | `serial_value[3]<=0` | 4 | `00000` | `00000` |
| 5 | `0x01` | 4 | 提交 `{1,0000}` | 0 | `00000` | `10000` |

第 4 次写完后 `prg_bank_r` **仍是 0**（未提交）——`prg unchanged after 4 writes` 就在断言"不满 5 次不生效"。第 5 次一写，`prg_bank_r = 5'b10000`（bit4=1，禁用 PRG-RAM），两个工作台清回 0，准备下一轮。位序上（`test_serial_bit_order`）连写 `0,1,0,1` 得 `serial_value = 0x0A`，**LSB 最先写进最低位**；testbench 的 `mmc1_serial_write(addr, value)` 按 bit0..bit4 先写低位，真实游戏则是把 5 位拆成 5 次 `STA $E000`。

---

## 6. 常见疑问

**Q：为什么不一次写 8 位，非要写 5 次？**
A：这是 **MMC1 芯片的硬件设计**：只有一个串行数据脚，软件必须分 5 拍 LSB 优先送入，RTL 只是忠实复刻这个协议。

**Q：写地址不同、数据不同，会不会算成两次序列？**
A：不会。每次 `cpu_we` 且 `bit7=0` 就收一位，与地址无关；只有第 5 次才用**当时的地址** `cpu_addr[14:13]` 选目标，所以标准用法是 5 次写同一地址。

**Q：bit7=1 的复位和 `reset` 端口是一回事吗？**
A：效果相同（都清 control 和全部 bank），触发方式不同：`reset` 是外部异步复位；`bit7=1` 是**软件复位**，在时钟块里同步生效，用来中止写了一半的序列。

**Q：为什么复位后 `$C000` 是固定末 bank？**
A：`MMC1_CONTROL_RESET` 的 `prg_mode=3` 就是"$8000 可切、$C000 固定末 bank"；末 bank 存着复位向量，CPU 一上电才能从 `$FFFC` 读到正确启动地址（测试断言偏移 `$1C000`）。

---

## 7. 你应该带走的三件事

1. **MMC1 用串行写协议**：一个地址写 5 次，`bit0` 进移位寄存器、每写一次移一位，第 5 次才用 `{新位, 前 4 位}` 落到 `cpu_addr[14:13]` 选中的寄存器；写 `bit7=1` 随时复位并清移位。
2. **control 5 位管两套 mode**：`[3:2]` 选 PRG 交换方式（0/1=32 KiB 切、2=首固定、3=末固定），`[4]` 选 CHR 是 8 KiB 还是 4 KiB，`[1:0]` 选镜像（编号打乱）。
3. **bank 拼偏移 = `(bank << 粒度) | 窗口内偏移`**：PRG 粒度 14 位、CHR 粒度 12 位；CHR 的 5 位 bank 配 4 KiB 粒度必须 17 位地址，`ppu_addr[13]` 是有意丢弃的 PPU 内部位。

上一篇 [`33-mapper-dispatch.md`](33-mapper-dispatch.md) 讲了它怎么被顶层选中；下一篇 [`35-mapper-mmc3.md`](35-mapper-mmc3.md) 看更复杂的 MMC3——它把"按地址选寄存器"和"按 bit0 区分奇偶"结合起来，还带一个 A12 边沿触发的扫描线 IRQ。
