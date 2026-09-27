# 系统集成 v5：把 `nes_mapper` 接进系统，以及软件 mapper 的指针数组怎么变成硬件 bank 寄存器

本文是 `rtl/nes_core/system/nes_system_v5.v` 的接口与接线合同。它在 v4 的基础上只加一件事：**`rtl/nes_core/mapper/` 进系统**。核心问题只有四个：

1. 软件模拟器的 mapper 是**函数指针表**（cNES）和**指针数组**（Obara）两套写法，RTL 用什么结构替代它们？
2. mapper 的 bank 切换在硬件上是"**bank 寄存器 + 地址 mux**"，它和"指针数组换指针"到底差在哪？
3. mapper 的 IRQ 怎么和 APU 的 IRQ 一起进 CPU 的 `irq_i`？线或的位置在哪一级？
4. v5 做到了哪一步、哪一步明确留给下一阶段（外部 CHR bank 接 PPU）？

`docs/modules/mappers.md` 已经写清 `nes_mapper` 自身的接口合同、每个 mapper 的寄存器与地址译码模型、以及软件 C 模型到 RTL 的逐项对应关系；`docs/modules/system-v4.md` 写清 v4 的 controller override 边界。本文不重复这两份，只写 v5 顶层**具体怎么接线**、**为什么这么接**，以及**软件模型与硬件结构的逐项对应**。

行为权威是 NESdev 的 mapper/NROM/MMC1/MMC3 说明。`[源码观察]` 标记的内容只是克隆仓库的写法，不是规格。

---

## 1. v5 相对 v4 的增量

| 项 | v4 | v5 |
| --- | --- | --- |
| PRG 存储 | `reg [7:0] prg_rom [0:PRG_SIZE_BYTES-1]`，默认 16 KiB | 同一份数组，**默认 128 KiB**（`PRG_SIZE_BYTES = 131072`） |
| PRG 读地址 | `prg_index = cart_addr[PRG_INDEX_BITS-1:0]`，纯镜像窗口 | `prg_index = mapper_prg_bank_offset`，由 mapper 决定 |
| mapper | 无 | `nes_mapper`，`MAPPER_SELECT ∈ {0,1,2,3,4}` |
| bus conflict 用的读回字节 | 无 | `prg_readback`，等于**当前 PRG 读值** |
| CPU `irq_i` | `apu_irq` | `mapper_irq \| apu_irq` |
| mirroring | `u_ppu` 的编译期参数 `MIRROR_VERTICAL(1'b0)` | 同左（不变），mapper 的 `mirroring` / `nametable_map` 作为观测端口输出 |
| CHR | PPU 内部 8 KiB CHR RAM | 同左；`chr_bank_offset` 输出但**不接 PPU** |
| controller / DMA / APU / PPU sprite / 可等待 bus | 全部在 | 原样保留，见第 7 节 |

**一句话**：v5 把"CPU 看到的 PRG 字节从哪来"这件事的所有权从顶层移交给 mapper，顶层只保留 ROM 数组本身。

## 2. 接线：四条线 + 一个完成沿

v4 已经在顶层做了 controller override 与 OAM DMA 的 `$2003/$2004` 影子。v5 **一个字都没改 `nes_cpu_bus`、`nes_cpu6502`、`nes_ppu2c02`、`nes_apu2a03`**，全部增量都在 `nes_system_v5.v` 里。

### 2.1 PRG 读

```verilog
reg [7:0] prg_rom [0:PRG_SIZE_BYTES-1];            // 外部 PRG ROM，>= 128 KiB

wire [PRG_ADDR_BITS-1:0] prg_index;

assign prg_index    = mapper_prg_bank_offset;
assign prg_readback = prg_rom[prg_index];
assign cart_din     = (cart_addr[15] == 1'b1) ? prg_rom[prg_index] : 8'h00;
```

三点必须说清：

1. **`prg_bank_offset` 已经是绝对偏移，不是 bank 号。** `docs/modules/mappers.md` 第 2.2 节写的是"PRG ROM 内部字节偏移"，五个子模块的实现都是"bank base 或上窗口内地址"：

   ```text
   nrom : prg_bank_offset = {2'b0, cpu_addr[14:0]}                              // 32 KiB 直接映射
   uxrom: prg_bank_offset = (bank_select << 14) | cpu_addr[13:0]                 // 可切换下窗口
   cnrom: prg_bank_offset = {3'b0, cpu_addr[13:0]}                              // 固定 16 KiB 镜像
   mmc1 : prg_bank_offset = (prg_bank16 << 14) | cpu_addr[13:0]
   mmc3 : prg_bank_offset = (prg_window  << 13) | cpu_addr[12:0]
   ```

   所以"**bank base + cart_addr**"这一次加法发生在 **mapper 内部**（`cpu_addr` 就是顶层喂进去的 `cart_addr`），顶层拿到的是**已经加完的结果**。顶层如果再自己加一次 `cart_addr`，NROM 的 `$8000` 会读成 `prg_rom[0]`、`$FFFF` 会读成 `prg_rom[0xFFFF]`（地址被折了两遍），这是 v5 明确**没有**采用的接法。TB 用一个独立模型逐次比对 `prg_bank_offset`，就是为了把这条语义钉死（第 6 节）。

2. **`prg_readback` 与 `cart_din` 读的是同一个字。** 这是有意的：UxROM/CNROM 的 bus conflict 判定字节必须就是"这次写落在 ROM 里的那个字节"。写成两条独立读路径反而会出现"比较用的字节和 CPU 看到的字节不是同一个 bank"这种断言看不见的缺陷。

3. **`cart_addr[15]` 门控保留自 v4**：cart RAM 窗口（`$6000-$7FFF`）读回 `$00`。v5 没有加 PRG RAM 数组（见第 8 节）。

### 2.2 mapper 的 CPU 写：只在完成沿触发

```verilog
reg cart_wr_pending_q;
reg [15:0] cart_wr_addr_q;
reg [7:0]  cart_wr_data_q;

always @(posedge clk or posedge reset) begin
    if (reset) begin
        cart_wr_pending_q <= 1'b0;
        cart_wr_addr_q    <= 16'h0000;
        cart_wr_data_q    <= 8'h00;
    end else begin
        cart_wr_pending_q <= cart_xfer && cart_we;
        cart_wr_addr_q    <= cart_addr;
        cart_wr_data_q    <= cart_dout;
    end
end

wire mapper_we       = cart_wr_pending_q;
wire [15:0] mapper_cpu_addr = cart_wr_pending_q ? cart_wr_addr_q : cart_addr;
wire [7:0]  mapper_cpu_dout = cart_wr_pending_q ? cart_wr_data_q : cart_dout;
```

三个设计点：

1. **只认完成沿，不认请求沿。** `cart_we` 是**请求级**的（`cart_req && cpu_we`），一次 cart 写会在"等待拍"和"完成拍"各出现一次；`READ_WAIT_CYCLES=1` 意味着每次传输都占两个 `ce`。直接把它接给 mapper，一次写会在同一个 CPU 周期里被锁存两次。这与 v4 对 `$4016` `/PL` 的处理是同一条纪律（见 `docs/modules/system-v4.md` 第 2 节）。

2. **地址与数据一起寄存。** 完成沿之后 `cart_addr` 可能已经指向下一次请求的目标，所以脉冲那一拍必须用寄存下来的地址/数据。`mapper_cpu_addr` 用一个 2 选 1 mux：脉冲拍用寄存值，其余拍用实时 `cart_addr`——这样 mapper 的**读**译码（NROM/UxROM/CNROM 的 `prg_bank_offset` 里那部分窗口内地址）在任何一拍都拿得到正确的 `cpu_addr`。

3. **脉冲宽度恰好 1 个 `clk`。** `cart_xfer` 只在 `ce` 有效的那个 `clk` 为高，所以 `mapper_we` 也是 1 拍。TB 逐 clk 断言这一点（相邻两拍都高即失败）。

**为什么脉冲落在完成沿之后的下一拍而不是同一拍**：`nes_cpu_bus` 的 `bus_data_r` 是**组合**的（`always @*` 从 `cart_din`/`ram_data`/`ppu_din`/`apu_din` 里选），CPU 在**完成沿**上用沿前的 `bus_din` 更新寄存器。把 mapper 写使能放在完成沿当拍，就等于让"这一次写"和"这一次读"在同一拍里既竞争又互相可见。推迟一拍把两件事彻底分开。

代价是：脉冲那一拍 `cart_din` 用的是"上一次写的地址"算出来的偏移。这个值**没有任何采样者**——`bus_fire` 最早只能发生在下一个 `ce`，而 `cart_wr_pending_q` 那时已经落回 0。TB 用"脉冲数 == 完成的 cart 写数"和"脉冲拍的地址/数据 == 上一次完成的写"两条断言覆盖这一点。

### 2.3 `ppu_addr` / `ppu_a12` 暂接 0

```verilog
wire [13:0] mapper_ppu_addr = 14'h0000;
wire        mapper_ppu_we   = 1'b0;
wire [7:0]  mapper_ppu_dout = 8'h00;
wire        mapper_ppu_a12  = 1'b0;
```

`nes_mapper` 的三条 PPU 观察通道（`ppu_addr`/`ppu_we`/`ppu_dout` 与独立的 `ppu_a12`）在 v5 全部绑 0。后果是**可观测的**：

- `chr_bank_offset` 恒等于 `{3'b0, ppu_addr[12:0]}` 或以它为输入的常量，**没有任何 CHR bank 切换**；
- MMC3 的 IRQ 计数器**永远不会被时钟**：`nes_mapper_mmc3.v` 只在 `a12_filtered` 时才更新 `irq_counter_r`，而 `ppu_a12` 恒 0 时 `a12_edge` 恒 0。程序写 `$C001`（reload）之后 `mmc3_irq_reload` 会**一直保持 1**，`irq_counter` 停在 0，`mapper_irq` 停在 0。TB 把"`$C001` 之后 reload 仍为 1、counter 仍为 0"写成断言——这正是"a12 被绑 0"的可观测证据，而不是一句注释。

`chr_bank_offset` 与 `prg_ram_enable`/`chr_ram_enable` 等输出仍然引到顶层端口，供下一阶段接线和观测使用。

### 2.4 mirroring 的边界

`mapper_mirroring` 与 `mapper_nametable_map` 被引到顶层端口，TB 对它们逐项断言（header mirroring、`$A000` 运行时切换、`nametable_map` 随模式变化）。

但**它们没有进 PPU**：`nes_ppu2c02` 的 mirroring 只有一个**编译期参数** `MIRROR_VERTICAL`，函数 `mirror_nametable` 内部直接读它，模块**没有运行期 mirroring 端口**。把一个随运行期变化的 wire 接到参数上只会在 elaboration 期求值一次（Icarus 在 t=0 求值并冻结），比"明确不接"更危险：行为看起来接上了，实际上 MMC1/MMC3 换模式时 PPU 不会跟着变，而断言也不会报警。

因此 v5 的做法是：

```verilog
nes_ppu2c02 #(
    .MIRROR_VERTICAL(1'b0)      // 与 v4 相同，不假装接上了
) u_ppu ( ... );
```

`docs/modules/mappers.md` 第 9 节已经把这条列为"PPU 侧 `MIRROR_VERTICAL` 仍固定"的范围限制。v5 把"mapper 输出 mirroring"和"PPU 应用 mirroring"分成两件事，前者已接线并被断言，后者与外部 CHR bank 一起列入下一阶段。

### 2.5 IRQ：线或的位置

```verilog
assign irq_line = mapper_irq | apu_irq;
...
nes_cpu6502 u_cpu ( ..., .irq_i(irq_line), ... );
assign apu_irq_o = apu_irq;      // 观测端口仍然只给 APU 的 irq
```

- `nes_cpu6502` 的中断判定是**电平**判定 `irq_i && !p_reg[2]`，没有 pending 寄存器（`dbg_irq_pending` 就是 `irq_i` 的直连）。所以 APU 和 mapper 必须自己在**同一根线**上或起来：CPU 只看得到一根线，先或后或都一样，但**必须或**。
- `apu_irq_o` 保持 v4 的语义（APU 自己的 `irq`），新增的 `irq_line` 才是真正进 CPU 的那根。TB 逐 clk 断言 `irq_line == (mapper_irq | apu_irq)` 且 `dbg_irq_pending == irq_line`。
- NMI 路径完全没动：PPU `nmi_o` → `u_cpu.nmi_i`。
- **mapper IRQ 的电平语义是"高 = 有效"**（`docs/modules/mappers.md` 第 2.2 节），与 CPU 的 `irq_i` 极性一致，中间没有取反。

## 3. 软件 mapper 的 dispatch：函数指针表 → `mapper_select` mux

`[源码观察]` cNES 的 `Mapper` 结构用 `ram_read_func`/`ram_write_func`/`vram_read_func`/`vram_write_func`/`tick_func` 五个函数指针分派到具体 mapper；Obara 用 `read_ROM`/`write_ROM`/`read_PRG`/`write_PRG`/`read_CHR`/`write_CHR`/`set_bus` 一组函数指针加 `mapper_num`。

两者的共同点是：**分派发生在每次总线访问时，而不是 CPU 里写 `if (mapper == 4)`**。

RTL 的对应物是 `nes_mapper` 顶层的组合 mux：

```text
mapper_select ──┬─ select_nrom  ──> u_nrom  ┐
                ├─ select_mmc1  ──> u_mmc1  │
                ├─ select_uxrom ──> u_uxrom  ├──> prg_bank_offset / chr_bank_offset /
                ├─ select_cnrom ──> u_cnrom  │    mirroring / irq / ...
                └─ select_mmc3  ──> u_mmc3  ┘
```

与软件的两点差别（`docs/modules/mappers.md` 第 3.1 节已展开）：

1. **五个子模块同时存在，而不是只例化一个。** 换 ROM 不重新综合，C 侧换 mapper 只是换一个函数指针，RTL 侧换 mapper 只是换 `MAPPER_SELECT`（v5 把它提成顶层参数 `MAPPER_SELECT`，默认 `8'd0`）。代价是五个子模块的寄存器同时存在（约 60 个触发器）。
2. **每个子模块的 `cpu_we` 都与过 `select_*`。** 软件一次只会调用当前 mapper 的 `write_PRG`；RTL 里必须显式禁止非选中 mapper 吃写脉冲，否则在同一个 `$8000` 上写会串到别的 mapper 的寄存器。TB 用三个实例（`MAPPER_SELECT` = 0/2/4）同时从三条 CPU 总线写 mapper 寄存器，串扰会立刻表现为某个实例的 bank 寄存器被别的实例的写改掉。

`MAPPER_SELECT` 支持 0（NROM）、1（MMC1）、2（UxROM）、3（CNROM）、4（MMC3）。CNROM 在 v5 的 RTL 里可综合可仿真（`prg_bank_offset` 是固定 16 KiB 镜像），只是 testbench 没有为它单开一个实例。

## 4. 指针数组 vs bank 寄存器 + 地址 mux

`[源码观察]` Obara 的 mapper 把窗口存成**指针**：

```c
mmc3->PRG_bank_ptrs[0..3];                 // 4 个 8 KiB PRG 窗口
mmc3->CHR_bank_ptrs[0..7];                 // 8 个 1 KiB CHR 窗口
mmc3->PRG_bank_ptrs[3] = PRG_ROM + banks*0x4000 - 0x2000;
```

读的时候是 `PRG_bank_ptrs[win][addr & 0x1FFF]` 这种**指针解引用**。cNES 不存指针，每次读调 `_mmc3_get_prg_offset(cart, addr)` 现算偏移。

**硬件上"指针数组"是不存在的东西。** 片上 ROM/BRAM 只有一个基址，FPGA 里没有"运行期地址"这种东西可以存进寄存器——`PRG_bank_ptrs[i]` 在综合后要么变成一根网表，要么被优化成一个常量加法。真正能存进触发器的是 **bank 编号**，所以 v5 走的是 cNES 的方向：

| C 表示 | 出现位置 | RTL 对应 | v5 顶层的对应 |
| --- | --- | --- | --- |
| `uint8_t *PRG_bank_ptrs[8]` / `CHR_bank_ptrs[8]` | Obara `mapper.h` | `prg_bank6/7`、`chr_bank0..5` 寄存器 + `prg_bank_offset`/`chr_bank_offset` | `prg_rom[prg_bank_offset]` |
| `g_prg_bank`、`g_chr_bank` | cNES `unrom.c`、`cnrom.c` | `bank_select`（UxROM）、`chr_bank_select`（CNROM） | 同上 |
| `(bank * GRANULARITY) \| (addr % GRANULARITY) % size` | cNES `_mmc1_get_prg_offset` | `(bank << SHIFT) \| addr[LOW]` | 由 `nes_mapper` 内部完成，顶层只收结果 |
| `CHR_ptrs[i][addr]` 解引用 | Obara `read_CHR` | `chr_bank_offset` | **v5 未接 PPU** |
| `PRG_ROM[(addr - 0x8000) & clamp]` | Obara 通用 `read_PRG` | NROM 组合译码 | `prg_rom[prg_bank_offset]` |

"硬件 bank register + 地址 mux 替代指针数组"这句话在 v5 的具体含义就是这三条：

1. **寄存器里存的是编号，不是地址。** `nes_mapper_mmc3` 的 `prg_bank6_r` 是 6 bit，`nes_mapper_uxrom` 的 `bank_select` 是 `UxROM_BANK_BITS` bit。存编号带来两个直接好处：相加的是一个常量移位而不是运行期地址；编号本身可以直接当调试端口暴露（`dbg_prg_bank_number`、`mmc3_prg_bank6`），测试能区分"bank 选错了"和"ROM 内容错了"。
2. **地址 mux 在 mapper 内部，用 `cpu_addr` 组合译码。** 五个子模块的 `prg_bank_offset` 都是纯组合式，`SHIFT` 与 `addr[LOW]` 的位宽在 elaboration 期就固定。窗口末尾的固定 bank（UxROM 的最后一个 16 KiB、MMC3 的最后/倒数第二个 8 KiB、NROM 的 16 KiB 镜像）用 `PRG_SIZE_BYTES` 在 elaboration 期算成常量，不需要运行期比较。
3. **v5 顶层只保留"ROM 数组 + 索引"这一件事。** 顶层不再有 `prg_index = cart_addr[...]` 这种自己算窗口的代码，也不再有任何"bank"概念——它对 mapper 是完全无感的，只知道 `prg_bank_offset` 是一个可以拿去索引的字节偏移。

这与 `docs/modules/mappers.md` 第 3.2 节的结论一致；v5 的增量是**把这条结论真正接到了系统的读总线上**。

## 5. bus conflict：读回值来自当前 PRG 读值

v5 把 `prg_readback` 接到 mapper，语义就是"外部 PRG ROM 在 `cpu_addr` 上呈现的字节"（`docs/modules/mappers.md` 第 4 节）。三条约束在 v5 里都成立：

1. `prg_readback` 与 `cart_din` 读同一个地址、同一个 bank（见 2.1 第 2 点）。
2. mapper 不持有任何 PRG ROM 影子数组——它在系统里只有 `prg_readback` 这 8 根线。
3. 写脉冲那一拍 `mapper_cpu_addr` 是**刚写完的那个地址**，所以比较用的字节正是这次写应该比较的字节。

TB 用两条独立判据覆盖：每个 `clk` 断言 `prg_readback == prg_rom[prg_bank_offset]`（证明它跟随当前 bank 而不是某个固定值），以及 UxROM 程序在 conflict 模式 1（AND）下真的靠读回字节切换 bank（第 6 节）。

## 6. v5 testbench 怎么测

`tb/system/tb_nes_system_v5.v` 在**同一个 testbench 里例化三个 `nes_system_v5`**，共用一个 `clk`：

| 实例 | `MAPPER_SELECT` | PRG 签名 | 程序 | 覆盖 |
| --- | --- | --- | --- | --- |
| `nrom_dut` | 0（NROM-256，`NROM_PRG_SIZE_BYTES=32768`） | `0x40 + (off>>14)`，即下窗口 `40`、上窗口 `41` | `$8000` 起，4 次签名读回 | NROM bank 映射：`$8040`/`$BFFF` → `40`，`$C000`/`$FFF0` → `41` |
| `uxrom_dut` | 2（UxROM，`UxROM_BANK_BITS=3`，`UxROM_BUS_CONFLICT=1`） | bank0 = `FF`，bank1..7 = `0x40+bank` | `$C000` 起（固定最后一个 bank） | bank 寄存器 + bus conflict + mirroring(header) + controller + OAM DMA + APU |
| `mmc3_dut` | 4（MMC3） | `0x50 + (off>>13)`，即 16 个 8 KiB bank | `$E000` 起（固定最后一个 bank） | R6/R7 bank 切换 + prg mode + `$A000` mirroring + IRQ 寄存器 + IRQ 进 CPU |

三个程序都是"读签名 → `CMP` → 不符就跳失败块 → 全过就写一个 RAM 完成标志 → 自跳"。TB 等三个完成标志都置位再结算。

TB 侧有**独立于 DUT 的 bank 模型**（`nrom_exp_off`/`uxrom_exp_off`/`mmc3_exp_off`），在**每一次** cart 传输上比对：

- NROM：`{2'b0, addr[14:0]}`；
- UxROM：`addr[14] ? 0x1C000\|addr[13:0] : bank<<14\|addr[13:0]`，其中 `bank` 是 TB 自己按 conflict 模式 1 的 `cpu_dout & prg_rom[本次写地址]` 算出来的；
- MMC3：按 `addr[14:13]` 选窗口（`00`=R6/倒数第二、`01`=R7、`10`=倒数第二/R6、`11`=最后），再 `| addr[12:0]`，其中 R6/R7/select/mode 是 TB 自己按 `$8000`/`$8001` 写的值跟踪的。

每读一个字节断言三件事：`mapper_prg_bank_offset` 等于模型、`cart_din` 等于 `prg_rom[模型]`、CPU 读到的 `bus_din` 等于 `prg_rom[模型]`。**每一次**完成的 cart 写断言：恰好一个 1 `clk` 的 `mapper_write_pulse`，且脉冲拍的 `mapper_write_addr`/`mapper_write_data` 等于那次写自己的地址/数据。

**mapper IRQ 的测法**（含一处必须记录的 testbench 手段）：

- `$C000` 写 7 → `mmc3_irq_latch == 7`；`$C001` → `mmc3_irq_reload` 置 1 且**一直保持 1**；`$E001`/`$E000` → `mmc3_irq_enabled` 1→0。这三条证明写脉冲真的进了 MMC3 寄存器，也证明 `ppu_a12` 绑 0 让计数器无法被时钟。
- 因为 a12 被绑 0，**没有任何 mapper 能自己把 IRQ 拉起来**（NROM/UxROM/CNROM 的 `irq` 恒 0，MMC1 的 `irq` 恒 0，MMC3 只在 `a12_filtered` 时置 pending）。要验证"mapper IRQ 真的能进 CPU"，TB 用 `force` 压住 `u_mapper.u_mmc3.irq_enabled_r` 与 `irq_pending_r` 为 1，于是 `irq = irq_enabled && irq_pending` 组合出 1，再逐项断言 `mapper_irq` → `irq_line` → `u_cpu.dbg_irq_pending` 三级都是 1，并确认 CPU 走完 7 周期入口、从 `$FFFE` 取到向量、跳到 `$E200` 的服务例程、例程把 `ram[0013]` 加 1 后 `RTI`。`release` 之后 TB **先 `force` 成 0 再 `release`**：`release` 只是解除强制，不会把寄存器恢复成驱动值——解除之后寄存器保持强制期间的值，要靠下一次驱动才变。直接 `release` 会让 `irq` 永远停在 1（本次开发真实遇到的现象）。

**保留路径的回归**（v4/v3/v2 的能力在 v5 里没有被 mapper 改坏）：

- 每一次非 open-bus 传输都恰好 1 个 `ce` 的 stall，`bus_stall == bus_req && !bus_fire` 逐 `ce` 断言，`dbg_wait_count` 在完成沿恒 0；
- 三个 CPU 都没有非法指令、都没有进失败块；
- UxROM 实例顺带把 controller（`$4016`/`$4017` 各 8 次读回 + 第 9 次读恒 1 + `apu_reg_cs` 不泄漏）、OAM DMA（`$4014` 一次、`dma_ack` 256、`$2004` 写 256、`oam[0..3] == 11 22 33 44`）、APU（pulse1 开着、sample 非零、`$4017=40` 禁止 frame IRQ、DMC 全程不请求总线）都跑了一遍。

**程序写法上的一条硬约束**（本次开发踩到并已写进 TB 的 `check_disp` 任务）：6502 的相对分支位移是**带符号 8 bit**，可达范围只有 `-128..+127`。TB 的 `bne_to`/`bne_flush` 在算出位移后立刻检查是否越界，越界直接 `$fatal`。失败块因此不能直接放在程序末尾，每个程序被切成若干"块"，每块结尾是 `JMP 下一块` + `JMP 远端失败块` 的 6 字节 trampoline，块内的 `BNE` 只跳到本块自己的 trampoline（绝对 `JMP` 不受 ±127 限制）。

## 7. v5 保留的 v4 接线

以下部分与 v4 逐行相同，TB 有回归断言：

- `nes_controller` 与 `$4016`/`$4017` 的 override 边界（`apu_addr_ctrl_owned = ctrl1 || (ctrl2 && !apu_we)`）；
- `nes_oam_dma` 的 `bus_hold` 仲裁、`$2003` 影子与 `$2004` 端口 mux；
- `nes_apu2a03` 的寄存器桥、frame counter、`$4014` 触发、`ce_sample` 与 sample 输出；
- `nes_ppu2c02` + `nes_ppu_sprite`（背景 + sprite 渲染、`MIRROR_VERTICAL(1'b0)`）；
- `nes_cpu_bus` 的 `READ_WAIT_CYCLES=1` / `RAM_READ_SYNC=1` 可等待总线与 DMA owner 译码；
- 12 拍 `div_phase` 的 `ce_cpu`/`ce_ppu` 分配。

## 8. v5 明确未实现

以下是**被测顶层 `nes_system_v5`** 的范围限制，不是 testbench 的缺陷：

- **外部 CHR bank 没接 PPU。** `chr_bank_offset` 已经在端口上，`chr_ram_enable`/`chr_ram_we` 也在，但 PPU 仍然用内部 8 KiB CHR RAM，**没有任何 CHR ROM 或 CHR banking**。因此 **CNROM 与 MMC1 的 CHR bank 切换在系统级不可观测**，任何依赖 CHR banking 的游戏跑不了。`ppu_addr`/`ppu_a12` 绑 0 意味着 mapper 连 PPU 地址都看不到。
- **MMC3 的 scanline IRQ 计数器在系统级无法被时钟**（`ppu_a12` 绑 0），所以"MMC3 IRQ 由 A12 沿触发"这条只在 `tb/mapper/tb_nes_mapper_mmc3.v` 里被覆盖，系统级只覆盖到寄存器与 IRQ 线的接线。
- **PPU 侧的 mirroring 没接。** 见 2.4：`nes_ppu2c02` 没有运行期 mirroring 端口，v5 不假装接上。四屏（`mirroring = 4`）的 4 KiB nametable RAM 同样没有。
- **PRG RAM / `$6000-$7FFF` 没有存储阵列。** `prg_ram_enable`/`prg_ram_we` 只是输出端口，顶层没有 `prg_ram` 数组，UxROM 板的 WRAM、MMC1 的 PRG RAM disable 位（`prg_bank[4]`）、MMC3 的 `$8000` bit5 RAM enable 与 `$A001` protect 都只到"寄存器"这一层。
- **MMC1 的串行移位寄存器在系统级没有被程序驱动过。** RTL 与接线都在（`MAPPER_SELECT=1` 可例化），但 v5 的 testbench 只例化了 mapper 0/2/4；MMC1 的串行提交、PRG mode 0/1/2/3、CHR mode、mirroring 控制位由 `tb/mapper/tb_nes_mapper_mmc1.v` 覆盖。
- **`MAPPER_SELECT` 是 elaboration 期参数。** 一个 `nes_system_v5` 实例整场仿真只有一个 mapper；换 mapper 要重新综合。软件侧的 `mapper_num` 也是每个 ROM 一次，所以这与软件行为一致，但与"运行时可切换"无关。
- **`PRG_ADDR_BITS` 必须等于 `$clog2(PRG_SIZE_BYTES)`。** 五个子模块的偏移位宽都跟着它走；bank 寄存器位数（`UxROM_BANK_BITS`/`CNROM_BANK_BITS`/MMC3 的 6 bit）如果能产生的偏移超出数组深度，`prg_rom[prg_bank_offset]` 会越界。v5 的 TB 用 `UxROM_BANK_BITS=3` 配 128 KiB、`CNROM_BANK_BITS` 保持默认 2，与 `tb/mapper` 的用法一致。综合可行性（128 KiB PRG 在 EP4CE10 上的 M9K 占用）**没有**评估，见 `docs/hardware/04-memory-and-fifo.md`。
- 其余与 v4 相同的缺口：`$4017` 读只回手柄位、open bus 上没有手柄位、`$4016` bit6/bit7 扩展口、第 9 次以后读恒 1、手柄物理层、DMC DMA 通路存在但未激励、`OAMADDR_WRITE=0`、音频输出通路（无 FIFO/无抽取）、上板频率与跨时钟域——见 `docs/modules/system-v4.md` 第 5 节。

## 9. 运行

```powershell
$tmp = Join-Path $env:TEMP 'op_fpga_emu'
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
$v5 = @(
  'rtl\nes_core\system\nes_system_v5.v',
  'rtl\nes_core\controller\nes_controller.v',
  'rtl\nes_core\bus\nes_cpu_bus.v',
  'rtl\nes_core\ppu\nes_ppu2c02.v',
  'rtl\nes_core\ppu\nes_ppu_sprite.v',
  'rtl\nes_core\ppu\nes_oam_dma.v',
  'rtl\nes_core\cpu\nes_cpu6502.v',
  'rtl\nes_core\apu\nes_apu_pulse.v',
  'rtl\nes_core\apu\nes_apu_triangle.v',
  'rtl\nes_core\apu\nes_apu_noise.v',
  'rtl\nes_core\apu\nes_apu_dmc.v',
  'rtl\nes_core\apu\nes_apu_length_lut.v',
  'rtl\nes_core\apu\nes_apu2a03.v',
  'rtl\nes_core\mapper\nes_mapper.v',
  'rtl\nes_core\mapper\nes_mapper_nrom.v',
  'rtl\nes_core\mapper\nes_mapper_uxrom.v',
  'rtl\nes_core\mapper\nes_mapper_cnrom.v',
  'rtl\nes_core\mapper\nes_mapper_mmc1.v',
  'rtl\nes_core\mapper\nes_mapper_mmc3.v'
)
& 'C:\iverilog\bin\iverilog.exe' -g2001 -s nes_system_v5 -o (Join-Path $tmp 'nes_system_v5_core.vvp') $v5
& 'C:\iverilog\bin\iverilog.exe' -g2012 -s tb_nes_system_v5 -o (Join-Path $tmp 'tb_nes_system_v5.vvp') ($v5 + 'tb\system\tb_nes_system_v5.v')
& 'C:\iverilog\bin\vvp.exe' (Join-Path $tmp 'tb_nes_system_v5.vvp')
```

第一条是纯顶层 elaboration（`-g2001`，只编译 RTL），确认 `nes_system_v5` 本身不依赖 testbench 特性。源文件列表必须显式包含 `nes_controller.v`、`nes_cpu_bus.v`、`nes_ppu_sprite.v`、`nes_oam_dma.v`、全部六个 APU 通道/查找表文件与全部六个 mapper 文件，`iverilog` 不会自动去找。`tools/sim_all.ps1` 没有登记 v5 目标（本次没有改动它），上面三条命令是直接调用。没有对应的 ModelSim `.do` 脚本。

实测输出（Icarus Verilog 12.0，Windows，10 ns 时钟）见 `tb/system/README.md` 的“v5 testbench”一节。v4 回归（`tb_nes_system_v4`，同一份 RTL 之外的文件）同时跑通，`PASS nes_system_v4`。

### 变异验证

为确认断言不是空跑，对 `nes_system_v5.v` 的**副本**（仓库里的 RTL 未被修改）做三处定向变异：

| 变异 | 结果 |
| --- | --- |
| `prg_index = mapper_prg_bank_offset` 换成 `prg_index = {1'b0, cart_addr[15:0]}`（忽略 bank） | 全局超时：三个 CPU 连 reset vector 都读错（向量落在数组的高半区），程序永远到不了完成标志 |
| `mapper_we = cart_wr_pending_q` 换成 `mapper_we = cart_we`（请求级而不是完成沿） | `uxrom prg offset disagreed with the tb bank model 3 times`——请求级的 `cpu_we` 在等待拍就改了一次 bank |
| `irq_line = mapper_irq \| apu_irq` 换成 `irq_line = apu_irq`（去掉线或） | `the mapper irq did not reach the combined irq line`（`force` 压出来的 mapper IRQ 到不了 CPU） |

三处全部被抓。其中第一处是靠全局超时抓到的（诊断信息不如后两处具体），因为破坏 bank 映射会让 CPU 在复位向量阶段就跑飞。
