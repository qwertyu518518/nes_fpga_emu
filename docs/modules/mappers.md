# Mapper 模块：软件 C 模型到 RTL 的映射

本文说明 `rtl/nes_core/mapper/` 下 `nes_mapper` 及其子模块的接口合同、每个 mapper 的寄存器与地址译码模型，以及软件 C 模拟器的 dispatch/指针/寄存器模型如何一一对应到 RTL 的 bank register、address mux 和 IRQ FSM。

行为权威是 NESdev 的 mapper/NROM/MMC1/MMC3 说明。cNES（`caseif__cNES`，commit `7c8c252`）和 Obara（`ObaraEmmanuel__NES`，commit `aa880b9`）只作为“别人怎么实现”的观察，用来发现 RTL 容易漏掉的边界，不代表规格。

当前未实现、也不在本文件范围内：SA-1、SuperFX、FDS，以及 mapper 7/11/19/46/66/75/94/180/185 等。

---

## 1. 文件与层次

```text
rtl/nes_core/mapper/
├── nes_mapper.v            顶层 shell：mapper dispatch、观察端口、nametable map
├── nes_mapper_nrom.v       mapper 0  NROM   纯组合，无状态
├── nes_mapper_uxrom.v      mapper 2  UxROM  一个 16 KiB bank register
├── nes_mapper_cnrom.v      mapper 3  CNROM  一个 8 KiB CHR bank register
├── nes_mapper_mmc1.v       mapper 1  MMC1   串行移位寄存器 + 4 个寄存器
└── nes_mapper_mmc3.v       mapper 4  MMC3   8 个 bank register + IRQ FSM
```

顶层是纯组合 dispatch：五个子模块同时存在，按 `mapper_select` 选择输出。每个子模块的写使能都已经和 `mapper_select` 与过，所以在同一个 `$8000` 地址上写不会串到别的 mapper 寄存器（`tb_nes_mapper.v` 的 `test_select_isolation` 覆盖这一点）。

`nes_mapper_nrom.v` 没有 `clk`/`reset` 端口，因为 NROM 没有寄存器；这是有意的，不是遗漏。

---

## 2. 接口合同

### 2.1 输入

| 端口 | 宽度 | 含义 |
|---|---|---|
| `clk` / `reset` | 1 | 只有 MMC1/MMC3/UxROM/CNROM 的寄存器使用 |
| `mapper_select` | 8 | mapper 编号。0=NROM、1=MMC1、2=UxROM、3=CNROM、4=MMC3 |
| `cpu_addr` | 16 | CPU 总线地址，**完整地址**而不只是 `addr[15:13]` |
| `cpu_we` | 1 | CPU 写周期 |
| `cpu_dout` | 8 | CPU 写数据 |
| `ppu_addr` | 14 | PPU 看到的地址（mapper 能观察到的部分，不含更高位） |
| `ppu_we` | 1 | PPU 写 `$2007` 周期 |
| `ppu_dout` | 8 | PPU 写数据 |
| `ppu_a12` | 1 | **PPU 地址的 A12**，独立于 `ppu_addr[12]`，供 MMC3 IRQ 时序使用 |
| `prg_readback` | 8 | 外部 PRG ROM 在 `cpu_addr` 上呈现的字节，见第 4 节 |

三条观察通道是分开的：CPU 通道、`ppu_addr`/`ppu_we`/`ppu_dout` 通道、`ppu_a12` 通道。这样安排的原因见 [nes-study/08-mappers.md](../nes-study/08-mappers.md) 第 4.1 节和第 10.6 节：真实 mapper 同时观察 CPU 地址线、PPU 地址线和写数据，软件里的函数指针表并不是硬件总线。

`ppu_dout` 在 mapper 0/1/2/3/4 中都没有被消费。这四个 mapper 不根据 PPU 写数据切 bank；CHR RAM 的写入由 memory owner 用 `chr_ram_we` 完成。端口保留是为了让后续需要“PPU 写触发切 bank”的板子不需要改接口。

`ppu_a12` 与 `ppu_addr[12]` 分成两个端口，是为了避免把 “MMC3 观察到的 PPU 地址 A12” 误接成 CPU 地址位或者 PPU 的 13 位地址低 12 位。NESdev 明确 A12 是 PPU 地址总线上的第 12 位；系统集成时应由 PPU 侧显式驱动。

### 2.2 输出

| 端口 | 宽度 | 含义 |
|---|---|---|
| `prg_bank_offset` | `PRG_ADDR_BITS`（默认 17） | PRG ROM 内部字节偏移，memory owner 用它索引 PRG ROM |
| `chr_bank_offset` | `CHR_ADDR_BITS`（默认 16） | CHR ROM 内部字节偏移 |
| `mirroring` | 3 | 0=horizontal、1=vertical、2=single lower、3=single upper、4=four screen |
| `nametable_map` | 8 | `{NT3,NT2,NT1,NT0}`，每项 2 bit 物理 nametable 索引 |
| `prg_ram_enable` | 1 | `$6000-$7FFF` 是否有 PRG RAM |
| `prg_ram_we` | 1 | PRG RAM 写使能（已含 `prg_ram_enable` 与 `$6000-$7FFF` 译码） |
| `chr_ram_enable` | 1 | CHR 是否可写（CHR RAM 板子） |
| `chr_ram_we` | 1 | CHR RAM 写使能（已含 `chr_ram_enable` 与 `$0000-$1FFF` 译码） |
| `irq` | 1 | mapper 拉低给 CPU 的 IRQ 线，**高有效位语义：1 = 有效** |
| `bus_conflict` | 1 | 组合观测信号，本次 bank 选择写是否被 ROM 总线值影响 |
| `dbg_prg_bank_number` | 8 | `prg_bank_offset` 按 8 KiB 粒度的调试视图 |
| `dbg_chr_bank_number` | 8 | `chr_bank_offset` 按 1 KiB 粒度的调试视图 |
| `dbg_mapper_id` | 3 | 当前生效的 mapper |
| `mmc1_*` | — | MMC1 状态观测：串行计数/值、control、CHR bank0/1、PRG bank |
| `mmc3_*` | — | MMC3 状态观测：IRQ counter/latch/pending/reload/enable、a12_filtered、bank_select、R6/R7、prg_mode、chr_inversion、ram_protect |

`nametable_map` 的编码（对应 [nes-study/08-mappers.md](../nes-study/08-mappers.md) 第 3.2 节）：

| `mirroring` | 模式 | `nametable_map` | 展开 |
|---:|---|---|---|
| 0 | horizontal | `8'b01010000` | NT0=0, NT1=0, NT2=1, NT3=1 |
| 1 | vertical | `8'b01000100` | NT0=0, NT1=1, NT2=0, NT3=1 |
| 2 | single lower | `8'b00000000` | 全部 0 |
| 3 | single upper | `8'b01010101` | 全部 1 |
| 4 | four screen | `8'b11100100` | NT0=0, NT1=1, NT2=2, NT3=3 |

解码集中在顶层的 `nametable_map_decode` 函数里，而不是复制四份 nametable 数组。这样 PPU 侧只需要读 4 个 2 bit 常量，改 mirroring 模式不需要重建任何 RAM。

### 2.3 地址宽度参数的取值范围

- `PRG_ADDR_BITS` 默认 17，可寻址 128 KiB PRG。要覆盖 iNES 常规上限用 17；`> 17` 只会让 `prg_bank_offset` 变宽，不改变译码逻辑。
- `CHR_ADDR_BITS` 默认 16，可寻址 64 KiB CHR。MMC1 的 5 bit CHR bank 在 4 KiB 粒度下需要 17 bit；本项目按 NES2 的 CHR 上限 64 KiB 取 16 bit，TB 也只用 4 KiB 粒度下编号 ≤ 15 的值。若要覆盖 MMC1 的全部 32 个 4 KiB bank，把 `CHR_ADDR_BITS` 提到 17。
- 移位在 Verilog 中按左操作数自定宽度，所以 RTL 一律先做零扩展再左移（`bank_ext << 13`），不依赖隐式截断。

---

## 3. 软件 C 模型到 RTL 的对应关系

### 3.1 dispatch：函数指针表 → `mapper_select` + 组合 mux

cNES 的 `Mapper` 结构用 `ram_read_func` / `ram_write_func` / `vram_read_func` / `vram_write_func` / `tick_func` 五个函数指针把行为分派到具体 mapper；Obara 的 `Mapper` 结构则用 `read_ROM` / `write_ROM` / `read_PRG` / `write_PRG` / `read_CHR` / `write_CHR` / `set_bus` 一组函数指针，并额外用 `mapper_num` 选 `load_*()`。

两者的共同点是：**分派发生在每次总线访问时，而不是在 CPU 里做 `if (mapper == 4)`**。

RTL 的对应物是：

```text
mapper_select ──┬─ select_nrom  ──> u_nrom  输出
                ├─ select_mmc1  ──> u_mmc1 输出
                ├─ select_uxrom ──> u_uxrom 输出
                ├─ select_cnrom ──> u_cnrom 输出
                └─ select_mmc3  ──> u_mmc3 输出 ──> mux ──> prg_bank_offset / chr_bank_offset / ...
```

差别有两个，都是刻意的：

1. **五个子模块同时存在，而不是只例化一个。** 换 ROM 不需要重新综合，C 侧换 mapper 只是换一个函数指针，RTL 侧换 mapper 只是换 `mapper_select`。代价是五个子模块的寄存器同时存在（总共约 60 个触发器），在 EP4CE10 上可忽略。
2. **每个子模块的 `cpu_we` 都与过 `select_*`。** 这解决了 C 函数指针天然解决的问题：软件一次只会调用当前 mapper 的 `write_PRG`，RTL 里必须显式禁止非选中 mapper 吃写脉冲。

C 侧的 `mapper_num` 还带着 submapper/clone 差异（cNES 的 `mapper_init_mmc3` 处理 submapper 1/3/4，Obara 的 `load_MMC3` 处理 1/3/4/5）。本项目把其中两个真正影响地址/时序的差异提成参数，其余差异明确不做：

| clone/submapper 差异 | 参考实现 | 本项目 |
|---|---|---|
| MMC3 A12 上升沿/下降沿 | cNES submapper 3 用下降沿，Obara submapper 3 用 MC-ACC 下降沿 | `MMC3_A12_EDGE` 参数，0=上升沿、1=下降沿 |
| MMC3 A12 间隔过滤 | cNES `A12_COOLDOWN_PERIOD 3`，Obara `t_cycles - cycles >= 3` | `MMC3_A12_COOLDOWN` 参数（默认 2 个空周期，接受沿后至少隔 3 拍） |
| UxROM bus conflict | cNES 无；Obara 无（写 `value & 0x7`） | `UxROM_BUS_CONFLICT` 参数，见第 4 节 |
| CNROM bus conflict | cNES submapper 2 标 “unimplemented AND bus conflicts” | `CNROM_BUS_CONFLICT` 参数，见第 4 节 |
| MMC3 T9552 去混淆、MC-ACC 计数窗口 | Obara submapper 5/3 | 未实现 |
| MMC1 连续 CPU cycle 过滤 | Obara `t_cycles - cpu_cycle == 1` | 未实现（`cpu_we` 由系统保证每 CPU 周期最多一次） |
| MMC1 连续写过滤导致软件 glitch | cNES/Obara 都有 | 未实现 |
| MMC3 `$A001` PRG RAM protect | Obara 有，MMC6 用；cNES 未实现 | 已实现（`ram_protect`） |

### 3.2 指针数组：`*PRG_ptrs[]` / `*CHR_ptrs[]` → bank register + address mux

Obara 的 mapper 把窗口存成指针：

```c
mmc3->PRG_bank_ptrs[0..3];                 // 8 KiB PRG 窗口
mmc3->CHR_bank_ptrs[0..7];                 // 1 KiB CHR 窗口
mmc3->PRG_bank_ptrs[3] = PRG_ROM + banks*0x4000 - 0x2000;
```

cNES 不存指针，而是每次读调用 `_mmc3_get_prg_offset(cart, addr)` 现算偏移。

RTL 采用 cNES 的方向：**只存 bank 编号，不存指针**，输出偏移。原因是：

- 指针是运行期地址，在综合里就是一堆需要和 ROM 基址相加的加法器；存编号后相加的是一个常量移位，ROM 基址由 memory owner 自己加。
- 存编号后，bank 编号本身可以直接作为调试端口暴露（`mmc3_prg_bank6`、`mmc1_chr_bank0` 等），测试能区分“bank 选择错了”和“ROM 内容错了”。
- 存编号后，窗口末尾的固定 bank（UxROM 的最后一个 16 KiB、MMC3 的最后两个 8 KiB）可以用 `PRG_SIZE_BYTES` 在 elaboration 时算成常量，不需要运行期比较。

三种 C 表示的对应关系：

| C 表示 | 出现位置 | RTL 对应 |
|---|---|---|
| `uint8_t *PRG_ptrs[8]` / `CHR_ptrs[8]` | Obara `mapper.h` | `prg_bank6/7`、`chr_bank0..5` 寄存器 + `prg_bank_offset`/`chr_bank_offset` 输出 |
| `g_prg_bank`、`g_chr_bank` | cNES `unrom.c`、`cnrom.c` | `bank_select`（UxROM）、`chr_bank_select`（CNROM） |
| `(bank * GRANULARITY) \| (addr % GRANULARITY) % size` | cNES `_mmc1_get_prg_offset` 等 | `(bank << SHIFT) \| addr[LOW]` |
| `CHR_ptrs[i][addr]` 指针解引用 | Obara `read_CHR` | memory owner 用 `chr_bank_offset` 索引 CHR ROM |
| `PRG_ROM[(addr - 0x8000) & clamp]` | Obara 通用 `read_PRG` | NROM 组合译码 |

### 3.3 寄存器模型：`g_write_count` / `g_write_val` → 串行移位寄存器

cNES 的 MMC1：

```c
g_write_val |= (val & 0x01) << g_write_count;
g_write_count++;
if (g_write_count == 5) { /* 提交到 addr & 0xE000 选中的寄存器 */ }
```

RTL 的 `nes_mapper_mmc1.v` 是同一状态机的时序化：

```text
serial_count_r  3 bit   0..4，第 5 次写后清 0
serial_value_r  5 bit   已收到的位，b0 在 [0]
control_r       5 bit   [4]=chr_mode [3:2]=prg_mode [1:0]=mirroring
chr_bank0_r     5 bit
chr_bank1_r     5 bit
prg_bank_r      5 bit   [4]=prg_ram_disable [3:0]=bank
```

第 5 次写提交时用 `{cpu_dout[0], serial_value_r[3:0]}`，即新位作为 bit4、旧的 4 位作为 bit3:0。这与 C 的 `g_write_val` 累积语义完全一致：软件只需要“按 LSB 优先连续写 5 次 bit7=0 的字节”。

`cpu_dout[7]` 为 1 时进入 reset 分支，把 `control_r` 恢复为 `5'b01100`（chr_mode=0、prg_mode=3、single lower），`chr_bank0_r`、`chr_bank1_r`、`prg_bank_r` 清零，`serial_count_r` 清零。

**这是一个需要记录的决定。** cNES 的 reset 分支只清 `g_write_count`/`g_write_val` 并把 `prg_bank_mode` 设成 3，**不动** `g_mmc1_control` 的 mirroring/chr_mode，也不清 CHR/PRG bank 寄存器；Obara 的 reset 分支同样只设 `mmc1->reg = REG_INIT` 和 `mmc1->PRG_mode = 3`。两个参考实现一致地只做部分复位。本项目选择做完整复位（control 回 `0x0C`、bank 全清），理由是：

- 这是多数 NESdev 描述和多数 FPGA 实现的 MMC1 reset 行为。
- 完整复位让 TB 能在一次 reset 之后确定全部初始状态，`tb_nes_mapper_mmc1.v` 的 `test_reset_state` 逐条断言了 control=0x0C、bank 全 0、mirroring=single lower。

如果后续要精确复现某个软件的 glitch 依赖，必须把这个选择改成参数。

### 3.4 `tick_func` / `set_bus`：PPU 地址观察器 → A12 边沿检测器 + IRQ FSM

cNES 的 `_mmc3_tick()` 每个 CPU 周期比较 `ppu_get_internal_regs()->addr_bus` 的旧 A12 和新 A12：相等就返回，不同才看方向，然后过 `g_a12_cooldown` 过滤；接着在“reload 或 counter 为 0”时把 counter 装成 latch，否则减 1；最后如果 counter 归零且 IRQ enable，置 staged，下一拍再 assert。

Obara 的 `set_bus(mapper, addr)` 形式几乎一样，只是用 `emulator->cpu.t_cycles` 和 `mmc3->cycles` 的差 `>= 3` 做过滤，并且**不**做 staged，直接 `interrupt(&cpu, MAPPER_IRQ)`。

RTL 的对应拆分（`nes_mapper_mmc3.v`）：

```text
ppu_a12 ──> ppu_a12_d ──> a12_edge ──┐
                                      ├──> a12_filtered ──> irq_counter_r
a12_cooldown_r ───────────────────────┘                    irq_pending_r
                                                                    │
$8000 C001 ──> irq_reload_r ──────────────────────────────────────┤
$E000 ──> irq_enabled_r=0, irq_pending_r=0                       │
$E001 ──> irq_enabled_r=1                                       v
                                                          irq = irq_enabled_r && irq_pending_r
```

对应关系：

| C 状态 | RTL |
|---|---|
| `g_last_addr` / `mmc3->a12` | `ppu_a12_d` |
| `g_a12_cooldown` / `cycles` 时间差 | `a12_cooldown`（接受沿后置 `MMC3_A12_COOLDOWN`，每拍递减） |
| `g_irq_latch` / `mmc3->IRQ_latch` | `irq_latch_r` |
| `g_irq_counter` / `mmc3->IRQ_counter` | `irq_counter_r` |
| `g_irq_reload` / `mmc3->IRQ_cleared` | `irq_reload_r` |
| `g_irq_enabled` / `mmc3->IRQ_enabled` | `irq_enabled_r` |
| `g_staged_irq` + `g_asserting_irq` | 合并为 `irq_pending_r`，见下 |
| `g_asserting_irq && g_irq_enabled ? 0 : 1` | `irq = irq_enabled_r && irq_pending_r` |
| `system_connect_irq_line()` 回调 | 顶层 `irq` 输出，由系统接到 CPU 的 `irq_i` |

**第二个需要记录的决定：assert 不做 staged。** cNES 用 `staged → asserting` 两拍，Obara 一次到位。本项目选择一次到位（与 Obara 一致），因为：

- 差别只有 1 个 CPU 周期，而 IRQ 服务程序的标准写法是 `disable; reload; enable`，多这一拍不影响任何正确软件。
- 一次到位让 `irq_pending_r` 是唯一状态，TB 只需要分别断言“counter 归零”和“IRQ 拉线”，就能把“计数器到零”和“中断真正上线”区分开——这正是 [nes-study/08-mappers.md](../nes-study/08-mappers.md) 第 10.6 节要求的分离。

`irq_pending_r` 是 sticky 的：`irq_counter_r` 归零后保持 0，每个被接受的 A12 沿都会再次把 counter 装回 latch（`counter == 0` 分支）并重新检查是否要置 pending，所以 latch=0 时 IRQ 在每个沿上重新拉线。只有 `$E000`（disable + ack）会清 pending。这与 Obara 的 `interrupt()` 幂等语义一致。

`irq_counter_next` 是组合线而不是寄存器：

```text
irq_counter_next = (irq_reload_r || irq_counter_r == 0) ? irq_latch_r : irq_counter_r - 1
```

这样 pending 判定用的就是“这一拍即将写入的值”，不需要在 always 块里引入第二个临时寄存器。

---

## 4. bus conflict：外部 ROM 读回值，不是 mapper 内部比较

**结论：bus conflict 的判定字节来自外部 ROM 读回值 `prg_readback`；mapper 内部只做组合比较和选择，不持有任何 PRG ROM。**

原因是 RTL 的所有权划分：PRG/CHR ROM 在 `nes_system_v0` 那样的 memory owner 里（`reg [7:0] prg_rom [...]`），不在 mapper 里。如果让 mapper 自己保存一份 ROM 影子数组做比较，就要在板级设计上决定两份 ROM 拷贝谁是真源，而且 SRAM/BRAM 数量翻倍。

所以接口是：

```text
系统 memory owner:  prg_readback = prg_rom[prg_bank_offset]     // 同一个 clk 域的组合读
mapper:             latched_data  = f(cpu_dout, prg_readback, UxROM_BUS_CONFLICT)
                    bus_conflict  = cpu_we && (prg_readback != cpu_dout)
```

mapper 内部的比较和选择由 `UxROM_BUS_CONFLICT` / `CNROM_BUS_CONFLICT` 参数决定：

| 参数值 | 语义 | 适用板子 |
|---:|---|---|
| `2'd0` | 关闭冲突处理，直接用 `cpu_dout` | 74HC161/74HC573 的 UNROM、标准 CNROM |
| `2'd1` | 组合比较 `prg_readback != cpu_dout` 拉高 `bus_conflict`，并把 `cpu_dout & prg_readback` 送进寄存器 | 带 bus conflict 的 UxROM 变体、CNROM submapper 2 |
| `2'd2` | 组合比较；不等时**丢弃整次写**（`write_accept = 0`），相等时用 `cpu_dout` | 严格模型，用于验证软件是否真的避开了冲突 |

`bus_conflict` 是纯组合输出，只在写周期有效。它的用途是观测，不是内部控制：它让 TB 能证明“这次写确实被 ROM 总线值改过”，从而区分 AND 模式（`cpu_dout & rom`）和直接锁存（`cpu_dout`）两种实现。

`tb_nes_mapper.v` 的 `test_uxrom_bus_conflict_and` / `test_uxrom_bus_conflict_reject` / `test_cnrom_bus_conflict` 用一个 `readback_force_enable` 开关把 `prg_readback` 换成显式值，从而在不改动 ROM 内容的前提下构造冲突；每个测试最后都把强制关掉一次，断言 `prg_readback == prg_rom[prg_bank_offset]`，证明“读回值确实来自外部 ROM 且跟随当前 bank”。reject 模式用第二个 `nes_mapper_uxrom` 实例（`UxROM_BUS_CONFLICT(2'd2)`）单独例化，因为 bus conflict 模式是 elaboration 期参数。

NROM、MMC1、MMC3 没有 bus conflict，MMC1 的串行移位寄存器按位接收，不存在数据总线污染问题。这三个 mapper 的 `bus_conflict` 恒为 0。

---

## 5. 各 mapper 的地址译码

### 5.1 Mapper 0 / NROM

```text
NROM_MIRROR_16K = (PRG_SIZE_BYTES <= 16384)

prg_bank_offset = NROM_MIRROR_16K ? {13'b0, cpu_addr[13:0]}
                                 : {12'b0, cpu_addr[14:0]}
chr_bank_offset = {3'b0, ppu_addr[12:0]}
mirroring       = HEADER_MIRRORING
prg_ram_enable  = NROM_PRG_RAM
chr_ram_enable  = NROM_CHR_RAM
```

16 KiB 时 `$C000-$FFFF` 是 `$8000-$BFFF` 的镜像（`% 0x4000`，与 cNES `nrom.c` 的 `adj_addr %= 0x4000` 一致）；32 KiB 时四个 8 KiB 窗口是连续的。

CHR RAM 时 `chr_ram_we` 有效，写入由 memory owner 用 `ppu_addr[12:0]` 索引 8 KiB CHR RAM；CHR ROM 时 `chr_bank_offset` 就是 `ppu_addr[12:0]`，`chr_ram_we` 恒 0。

`mirroring` 只从 `HEADER_MIRRORING` 读，因为 NROM 没有运行时寄存器。`NROM_PRG_RAM` 默认 0（NROM-128 没有 WRAM），NROM-256 才置 1。

TB：`tb_nes_mapper.v` 覆盖 32 KiB；`tb_nes_mapper_nrom128.v` 覆盖 16 KiB 镜像、vertical header mirroring、`nametable_map` 和 WRAM 窗口。

### 5.2 Mapper 2 / UxROM

```text
UXROM_LAST_BANK_16K = (PRG_SIZE_BYTES >> 14) - 1

prg_bank_offset = (cpu_addr[14] ? UXROM_LAST_BANK_16K : bank_select) << 14
                  | cpu_addr[13:0]
chr_bank_offset = ppu_addr[12:0]
chr_ram_enable  = 1'b1
prg_ram_enable  = 1'b0
```

`$8000-$BFFF` 是可切换的 16 KiB bank，`$C000-$FFFF` 固定最后一个 bank。`bank_select` 是 `UxROM_BANK_BITS` 位（默认 4 bit，对应 256 KiB 板；TB 用 3 bit 配 128 KiB ROM）。写 `$8000-$FFFF` 任意地址都切 bank，地址只用来产生 bus conflict 的读回字节。`$7FFF` 及以下的写被 `mapper_write = cpu_we && cpu_addr[15]` 挡掉。

UxROM 板子的 WRAM 在本版本不建模（`prg_ram_enable` 恒 0），这是明确的范围限制，不是遗漏。

### 5.3 Mapper 3 / CNROM

```text
prg_bank_offset = {3'b0, cpu_addr[13:0]}          // 固定 16 KiB，$C000 起镜像
chr_bank_offset = (chr_bank_select << 13) | ppu_addr[12:0]
chr_ram_enable  = 1'b0
prg_ram_enable  = 1'b0
```

`chr_bank_select` 是 `CNROM_BANK_BITS` 位（默认 2 bit，32 KiB CHR）。写 `$8000-$FFFF` 切 CHR bank，CPU PRG 不变。CHR ROM 的写被 `chr_ram_enable = 0` 丢掉。

### 5.4 Mapper 1 / MMC1

```text
MMC1_LAST_BANK_16K = (PRG_SIZE_BYTES >> 14) - 1

prg_bank16_select:
  control[3:2] == 2'b00 或 2'b01 : {prg_bank_r[4:1], cpu_addr[14]}
  control[3:2] == 2'b10         : cpu_addr[14] ? prg_bank_r : 5'd0
  control[3:2] == 2'b11         : cpu_addr[14] ? MMC1_LAST_BANK_16K : prg_bank_r

chr_bank4k_select:
  control[4] : ppu_addr[12] ? chr_bank1_r : chr_bank0_r
  else       : {chr_bank0_r[4:1], ppu_addr[12]}

prg_ram_enable = ~prg_bank_r[4]
mirroring      = 2'd0 ? single lower : 2'd1 ? single upper
                : 2'd2 ? vertical     : horizontal
```

模式 0/1 都用 `{prg_bank_r[4:1], cpu_addr[14]}`，即 bit4（PRG RAM disable）和 bit0 被丢掉，16 KiB bank 号是 `{bit4..bit1, addr[14]}`。这与 cNES 的 `(g_prg_bank & 0x1E) + (addr & 0x4000 ? 1 : 0)` 和 Obara 的 `PRG_bank1 = PRG_ROM + 0x4000 * (PRG_reg & ~1)` 逐位等价。

CHR 模式 0（8 KiB）用 `chr_bank0` 的 bit0 当作 4 KiB 半区选择：$0000-$0FFF 是 `{chr_bank0[4:1], 0}`，$1000-$1FFF 是 `{chr_bank0[4:1], 1}`。写 $C000 在 chr_mode=0 时仍然更新 `chr_bank1_r`，但它此刻不参与译码。

### 5.5 Mapper 4 / MMC3

寄存器译码用 `cpu_addr[15:13]` 加 `cpu_addr[0]`，对应 cNES 的 `addr & 0xE001`：

| 写 | `cpu_addr[15:13]` | `cpu_addr[0]` | 作用 |
|---|---|---|---|
| `$8000` | `3'b100` | 0 | `bank_select_r = d[2:0]`、`chr_inversion_r = d[7]`、`ram_enable_r = d[5]`、`prg_mode_r = d[6]`；`d[5]==0` 时清 `ram_protect_r` |
| `$8001` | `3'b100` | 1 | 按 `bank_select_r` 写 R0–R5 或 R6/R7 |
| `$A000` | `3'b101` | 0 | `mirroring_r = d[0] ? horizontal : vertical` |
| `$A001` | `3'b101` | 1 | `ram_enable_r` 为 1 时写 `ram_protect_r` |
| `$C000` | `3'b110` | 0 | `irq_latch_r = d` |
| `$C001` | `3'b110` | 1 | `irq_reload_r = 1` |
| `$E000` | `3'b111` | 0 | `irq_enabled_r = 0`、`irq_pending_r = 0`（disable + ack） |
| `$E001` | `3'b111` | 1 | `irq_enabled_r = 1` |

`$8001` 的目标寄存器和掩码：

| `bank_select_r` | 目标 | 掩码 |
|---:|---|---|
| 0 | `chr_bank0_r`（覆盖 $0000-$0FFF 两个 1 KiB 窗） | `d & 0xFE` |
| 1 | `chr_bank1_r`（覆盖 $0800-$0FFF） | `d & 0xFE` |
| 2–5 | `chr_bank2_r` … `chr_bank5_r` | `d & 0xFF` |
| 6 | `prg_bank6_r` | `d & 0x3F` |
| 7 | `prg_bank7_r` | `d & 0x3F` |

CHR 窗口索引：

```text
chr_window_base = ppu_addr[12] ? {1'b1, ppu_addr[11:10]}   // $1000-$1FFF: 4 个 1 KiB 窗
                                : {2'b00, ppu_addr[11]}      // $0000-$0FFF: 2 个 2 KiB 窗
chr_window_index = chr_inversion_r ? (chr_window_base ^ 3'b100) : chr_window_base
```

inversion 就是把 8 个窗口整体异或 bit2，即 0↔4、1↔5、2↔6、3↔7，等价于 Obara 的 `(ptr_index + 4) % 8`。R0/R1 的 bit0 被忽略，所以窗口 0 用 `chr_bank0_r`、窗口 1 用 `{chr_bank0_r[7:1], 1'b1}`。

PRG 窗口用 `cpu_addr[14:13]` 选 4 个 8 KiB 窗：

| `cpu_addr[14:13]` | 地址窗 | `prg_mode_r == 0` | `prg_mode_r == 1` |
|---:|---|---|---|
| `2'b00` | `$8000-$9FFF` | R6 | 固定倒数第二个 8 KiB bank |
| `2'b01` | `$A000-$BFFF` | R7 | R7 |
| `2'b10` | `$C000-$DFFF` | 固定倒数第二个 8 KiB bank | R6 |
| `2'b11` | `$E000-$FFFF` | 固定最后一个 8 KiB bank | 固定最后一个 8 KiB bank |

`MMC3_LAST_BANK_8K = (PRG_SIZE_BYTES >> 13) - 1`、`MMC3_SECOND_LAST_BANK_8K = (PRG_SIZE_BYTES >> 13) - 2` 是 elaboration 期常量，PRG ROM 至少要 16 KiB（2 个 8 KiB bank）才有意义。

复位值：`prg_bank6_r = 0`、`prg_bank7_r = 1`、CHR bank 全 0、`prg_mode_r = 0`、`chr_inversion_r = 0`、`ram_enable_r = 0`、`mirroring_r = HEADER_MIRRORING`、`irq_enabled_r = 0`、`irq_pending_r = 0`、`irq_latch_r = 0`、`irq_counter_r = 0`。复位后 IRQ 是关的，这与 cNES 的 `g_irq_enabled = false` 一致。

---

## 6. 验证

四个 testbench，全部自包含（自己填 PRG/CHR 镜像，不加载 ROM），全部用 Icarus Verilog `-g2001` 编译并运行：

| 顶层 | 源文件 | 覆盖 |
|---|---|---|
| `nes_mapper` | 6 个 RTL 文件 | `-g2001` 单独 elaborate |
| `nes_mapper_nrom` | 同上 | 同上 |
| `nes_mapper_uxrom` | 同上 | 同上 |
| `nes_mapper_cnrom` | 同上 | 同上 |
| `nes_mapper_mmc1` | 同上 | 同上 |
| `nes_mapper_mmc3` | 同上 | 同上 |
| `tb_nes_mapper` | RTL + `tb/mapper/tb_nes_mapper.v` | NROM-256 32 KiB 的四个 PRG 窗口和偏移、CHR ROM/RAM 写入、header horizontal mirroring 与 `nametable_map`、UxROM 16 KiB bank register 与固定末 bank、bank 位宽掩码、`$7FFF` 以下的写被忽略、CNROM 8 KiB CHR bank 与固定 16 KiB PRG、CHR ROM 写忽略、UxROM AND/reject 两种 bus conflict 模式、CNROM bus conflict 的逐地址读回、`mapper_select` 隔离 |
| `tb_nes_mapper_nrom128` | RTL + `tb/mapper/tb_nes_mapper_nrom128.v` | 16 KiB PRG 在 $8000–$FFFF 的镜像关系、vertical header mirroring 与 `nametable_map`、WRAM 在 $6000-$7FFF 的读回和写使能 |
| `tb_nes_mapper_mmc1` | RTL + `tb/mapper/tb_nes_mapper_mmc1.v` | 复位态（control=0x0C、PRG mode 3、single lower）、第 5 次写才提交、LSB 优先的位序、bit4 的 PRG RAM disable、四个串行地址译码、PRG mode 0/1/2/3 的窗口映射、CHR mode 0/1 的窗口映射、mirroring 控制位、reset bit 清空串行寄存器和全部 bank、reset bit 中断半次序列 |
| `tb_nes_mapper_mmc3` | RTL + `tb/mapper/tb_nes_mapper_mmc3.v` | 复位 bank 映射、PRG mode 交换 $8000/$C000、6 bit bank 掩码、CHR 2 KiB/1 KiB 窗口与 R0/R1 bit0 忽略、CHR inversion、$A000 mirroring、$8000 bit5 RAM enable 与 $A001 protect、IRQ latch 装载/reload/递减、disable+ack、latch=0 的重复 assert、counter 到 0 与 IRQ 上线的分离、A12 上升沿 cooldown、下降沿实例、偶奇地址别名与 $8000 范围门控 |

断言方式：每个 `expect*` 任务比较期望与实际，不一致时打印 `FAIL <标签>: got ... expected ...` 并累加 `fail_count`；testbench 结束打印 `CHECKS n`，`fail_count != 0` 时打印 `FAIL <top> with n failing checks` 并以 `FAIL` 开头，正常则打印 `PASS <top> <覆盖摘要>`。另外有全局超时块。

ROM 内容用签名填充：PRG ROM 的每个字节是 `8'h40 + offset[16:13]`（8 KiB bank 号），CHR ROM 是 `8'h80 + offset[15:10]`（1 KiB bank 号），CHR RAM 用同样的 CHR 签名，PRG RAM 全 `8'hE0`。这样“读到什么字节”直接对应“选中了哪个 bank”，期望值由 TB 从 mapper 语义独立算出，不读 DUT 的偏移输出，所以断言不是自证。

**这些证据的范围上限**：只证明 mapper RTL 与 testbench 的内部一致性，以及这些 RTL 在 `-g2001` 下可 elaborate。它**不**证明任何真实 ROM 的行为、任何 mapper clone 的 glitch、任何综合/时序/板级结论、任何 NESdev test ROM 结果。相关上限也记录在 [`docs/00-overview/verification-plan.md`](../00-overview/verification-plan.md)。

---

## 7. 明确的未实现项

- UxROM 的 PRG RAM / WRAM 板子变体。
- MMC1 的连续 CPU cycle 过滤和“忽略连续写”导致的软件可见 glitch。
- MMC1 的 CHR-RAM 板子变体（写 $A000/$C000 改 PRG bank 的行为，Obara `mmc1.c` 里有），`MMC1_CHR_RAM` 目前只影响 `chr_ram_enable`。
- MMC3 的 MC-ACC 计数窗口、NEC alternate clocking、T9552 去混淆、MMC6（submapper 1）的 8 bit bank 与完整写保护。
- CNROM/CNROM copy（mapper 185）的特殊行为。
- four-screen 的实际 4 KiB nametable RAM：RTL 只输出 `mirroring = 4` 和 `nametable_map = 8'b11100100`，PPU 侧还没有对应的 4 屏 RAM。
- PPU 侧的 `MIRROR_VERTICAL` 仍是 `nes_ppu2c02.v` 的编译期参数，尚未改成读 `nes_mapper` 的运行时 `mirroring`/`nametable_map`。
- DMA（$4014）、OAM DMA 与 mapper 交互的时序。
