# 08 Mapper 概念、地址窗口与常见实现

## 1. mapper 是什么

mapper 是卡带板上的地址译码和状态逻辑。它不改变 CPU 指令语义，但可以改变：

- CPU `$6000-$7FFF` 是否有 PRG RAM；
- CPU `$8000-$FFFF` 当前看到哪个 PRG bank；
- PPU `$0000-$1FFF` 当前看到哪个 CHR bank；
- 四个逻辑 nametable 如何映射到物理 nametable；
- 某些 PPU 地址变化是否触发 IRQ；
- 卡带是否包含特殊控制、bank 或扩展 ROM。

```text
CPU address ──┐
PPU address ──┼──> mapper state + decode ──> PRG/CHR/RAM/mirroring/IRQ
write data ───┘
```

mapper 编号是文件格式和板级行为的索引，不等于 ASIC 名称，也不保证所有同名 mapper 的每个 clone 完全相同。

## 2. mapper 与地址窗口

### 2.1 CPU PRG 窗口

```text
$8000-$9FFF   ┐
$A000-$BFFF   ├── 通常是 8 KiB 或 16 KiB bank 窗口
$C000-$DFFF   ┤
$E000-$FFFF   ┘
```

NROM 常按 16 KiB 窗口组织；MMC3 常按 8 KiB 窗口组织。mapper 的 bank mode 决定哪些窗口固定、哪些可切换。

### 2.2 PPU CHR 窗口

```text
$0000-$07FF   ┐
$0800-$0FFF   ├── 可能是 1 KiB、2 KiB 或 4 KiB bank
$1000-$17FF   ┤
$1800-$1FFF   ┘
```

PPUCTRL 的 background/sprite table 位只选择 `$0000` 或 `$1000` 基址；mapper 的 bank 选择决定这两个窗口背后实际是哪块 CHR。

## 3. mirroring 与 nametable map

### 3.1 四种逻辑 nametable

```text
逻辑 NT0       逻辑 NT1
$2000-$23FF    $2400-$27FF
      ┌──────────┐
逻辑 NT2       逻辑 NT3
$2800-$2BFF    $2C00-$2FFF
```

### 3.2 常见映射

设物理 nametable offset 为 0、1、2、3：

| 模式 | NT0 | NT1 | NT2 | NT3 |
|---|---:|---:|---:|---:|
| horizontal | 0 | 0 | 1 | 1 |
| vertical | 0 | 1 | 0 | 1 |
| single lower | 0 | 0 | 0 | 0 |
| single upper | 1 | 1 | 1 | 1 |
| four-screen | 0 | 1 | 2 | 3 |

`[NESdev 真值]` mirroring 是 PPU 逻辑地址到物理 nametable 的映射，不应通过复制四份数组实现，除非明确验证了写入和读取的所有边界。

### 3.3 cNES 和 Obara 的表示

- cNES `ppu.c` 用 `_translate_name_table_address()` 直接把逻辑地址转换为 0–0xFFF 数组偏移。
- Obara `mapper.c` 用 `name_table_map[4]` 保存每个逻辑 NT 的物理偏移。

两种表示都可以在 RTL 中实现为 2-bit/4-entry 映射表或组合逻辑。

## 4. cNES 的 mapper 接口

`include/mappers/mappers.h` 定义：

```text
Mapper
├── id
├── name
├── init_func(cart)
├── ram_read_func(cart, addr)
├── ram_write_func(cart, addr, value)
├── vram_read_func(cart, addr)
├── vram_write_func(cart, addr, value)
└── tick_func()
```

### 4.1 函数表不是硬件总线

`[源码观察]` cNES 通过函数指针把 CPU RAM 窗口和 PPU VRAM 窗口分开。`[NESdev 真值]` 真实 mapper 可能同时观察 CPU/PPU 地址、写数据、电源和中断线；函数表是软件组织方式。`[RTL 建议]` 显式定义 `cpu_prg_*`、`ppu_chr_*`、`nametable_map`、`mapper_irq` 等端口。

### 4.2 cNES 支持的 mapper ID

| ID | 名称 | 主要能力 |
|---:|---|---|
| 0 | NROM | 固定 PRG、可选 CHR RAM |
| 1 | MMC1 | PRG/CHR bank、serial register、mirroring |
| 2 | UNROM | PRG bank、CHR RAM |
| 3 | CNROM | 8 KiB CHR bank |
| 4 | MMC3 | PRG/CHR bank、mirroring、scanline IRQ |
| 7 | AXROM | 单屏 mirroring、PRG bank |
| 11 | Color Dreams | PRG/CHR bank、mirroring |
| 19 | Namco 1XX |Namco 风格 bank、mirroring |
| 185 | CNROM copy | 特殊 CNROM 变体 |

“支持”只表示该提交有对应文件和函数，不表示所有 submapper、clone 和未实现 glitch 都已覆盖。

## 5. Obara 的 mapper 接口

Obara `src/mappers/mapper.h` 的 `Mapper` 结构包含：

```text
PRG_ROM / CHR_ROM / PRG_RAM
PRG_ptrs[8] / CHR_ptrs[8]
PRG_banks / CHR_banks
mirroring / name_table_map[4]
mapper_num / submapper
read_ROM / write_ROM
read_PRG / write_PRG
read_CHR / write_CHR
set_bus(address)
reset
extension
```

`set_bus()` 值得特别注意：MMC3 等 mapper 通过观察 PPU 地址变化计时，而不是只看 CPU 写入。Obara 的接口比 cNES 更接近“PPU 地址观察器”。

## 6. NROM

### 6.1 行为

NROM 没有动态 bank：

```text
$8000-$BFFF → PRG bank 0
$C000-$FFFF → PRG bank 1，或 bank 0 镜像
```

CHR ROM 固定映射到 PPU `$0000-$1FFF`；CHR RAM 时写入 `$2007` 可修改 8 KiB。

### 6.2 cNES 源码观察

`src/mappers/nrom.c`：

- `$0000-$7FFF` 转给 `system_lower_memory_read/write`；
- `$8000-$FFFF` 转给 `cart->prg_rom`；
- 如果 PRG 小于等于 16 KiB，用 `adj_addr %= 0x4000` 镜像；
- CHR ROM 缺失时使用静态 `g_chr_ram`；
- PPU nametable/palette 通过 `ppu_name_table_*`、`ppu_palette_table_*`；
- 写入 ROM 被静默忽略。

### 6.3 RTL 最小实现

```text
if addr < $8000:
    system_lower_decode
else:
    prg_offset = (addr - $8000) % prg_size
    read prg_rom[prg_offset]
```

先完成 NROM 的 reset、PRG 读取和 RAM 镜像，再添加 CHR RAM。它是最适合验证 CPU 总线的 mapper。

## 7. UxROM / UNROM

### 7.1 窗口

```text
$8000-$BFFF → 可选 PRG bank
$C000-$FFFF → 固定最后 PRG bank
```

写 `$8000-$FFFF` 的值通常选择 16 KiB bank；bank 位数和镜像规则依具体 UxROM 变体。

### 7.2 cNES 观察

`src/mappers/unrom.c` 使用一个 8-bit `g_prg_bank`，读地址按 16 KiB 对齐，`$C000` 以上固定为最后一个 bank。它把 `cart->chr_rom` 初始复制到静态 CHR RAM，运行时 PPU 写入修改这份 RAM。

### 7.3 NESdev 真值

UxROM 家族的 board variant、bank bit 宽度、bus conflict 和 CHR RAM 行为可能不同。`[RTL 建议]` 第一版可实现明确指定的一个 UxROM 变体，并把 variant 参数化；不要仅用“mapper 2”一个数字覆盖所有 clone。

## 8. CNROM

### 8.1 行为

CNROM 主要切换 8 KiB CHR bank，PRG 通常固定：

```text
CPU $8000-$FFFF → 固定 PRG
CPU write       → 选择 CHR bank
PPU $0000-$1FFF → 当前 8 KiB CHR window
```

### 8.2 cNES/Obara 观察

- cNES `cnrom.c` 通过写 `$8000-$FFFF` 选择 CHR bank。
- Obara `cnrom.c` 用 `CHR_ptrs[0] = CHR_ROM + 0x2000 * (value & CHR_mask)`，写 CHR ROM 被记录为无效。
- Obara 对 submapper 2 标记需要未实现的 AND bus conflict，说明“同一个 CNROM 编号”可能有额外行为。

### 8.3 RTL 映射

只需要一个 8 KiB CHR bank register 和 13 KiB CHR ROM 偏移乘法/截断。验证重点是 bank 值超出实际 bank 数量时的 wrap、mask 和写入忽略。

## 9. MMC1

### 9.1 serial register

MMC1 的写入不是普通单字节寄存器，而是连续串行位：

```text
$8000-$9FFF  控制：mirroring、PRG mode、CHR mode
$A000-$BFFF  CHR bank 0
$C000-$DFFF  CHR bank 1
$E000-$FFFF  PRG bank/PRG RAM enable
```

典型写入序列：

```text
$80 → reset
$xx → bit0
$yy → bit1
$zz → bit2
$ww → bit3
$vv → bit4，完成
```

bit 7 为 1 时 reset。某些 clone 还使用连续 CPU cycle 过滤。

### 9.2 PRG mode

| mode | `$8000-$BFFF` | `$C000-$FFFF` |
|---:|---|---|
| 0/1 | 16 KiB bank A | 16 KiB bank B |
| 2 | 固定 bank 0 | 可选 bank |
| 3 | 可选 bank | 固定最后 bank |

### 9.3 CHR mode

| mode | `$0000-$0FFF` | `$1000-$1FFF` |
|---:|---|---|
| 0 | 8 KiB 连续 bank | 同一 8 KiB 的高 4 KiB |
| 1 | 4 KiB bank 0 | 4 KiB bank 1 |

### 9.4 cNES 观察

`src/mappers/mmc1.c`：

- `g_write_count` 和 `g_write_val` 累积 5 个 bit；
- `g_mmc1_control` 保存 mirroring、PRG mode、CHR mode；
- reset 把 PRG mode 设为 3；
- `_mmc1_get_prg_offset()` 和 `_mmc1_get_chr_offset()` 计算窗口偏移；
- `$6000-$7FFF` 通过 `g_enable_prg_ram` 控制；
- PRG RAM 使用 `% 0x2000`，忽略更大的 ROM 情况。

### 9.5 Obara 观察

Obara MMC1 还使用 `mapper->emulator->cpu.t_cycles` 检测连续写，并在 submapper/clone 条件下改变 bank 逻辑。它把 `MMC1_t` 作为 `extension` 挂到通用 Mapper。

### 9.6 RTL 建议

MMC1 最小接口：

```text
write_addr[15:13]
write_data[7:0]
write_count[2:0]
write_value[4:0]
control_reg
prg_bank[4:0]
chr_bank0[4:0]
chr_bank1[4:0]
```

每个 CPU 写周期只推进一次 serial register。复位、bank 范围 wrap 和 PRG RAM enable 要有独立断言。

## 10. MMC3

### 10.1 PRG 8 KiB 窗口

```text
$8000-$9FFF  R6 或固定倒数第二
$A000-$BFFF  R7
$C000-$DFFF  固定/可切换 R6
$E000-$FFFF  固定最后
```

MMC3 的 bank mode 位交换 `$8000` 与 `$C000` 两个 8 KiB 窗口。

### 10.2 CHR 2 KiB/1 KiB 窗口

CHR inversion 决定 1 KiB bank 的窗口排列。R0/R1 通常是 2 KiB 连续 bank，R2–R5 是 1 KiB bank，R6/R7 选择 PRG。

### 10.3 IRQ latch

典型寄存器：

| 地址 | 作用 |
|---:|---|
| `$8000` | bank mode、CHR inversion、RAM enable、bank select |
| `$8001` | 写当前选中的 bank |
| `$A000` | mirroring |
| `$C000` | IRQ latch |
| `$C001` | IRQ reload |
| `$E000` | disable/ack IRQ |
| `$E001` | enable IRQ |

IRQ 计数器由 PPU A12 过滤后的上升沿或某些 clone 的下降沿时钟化。A12 不是 CPU 地址 `$2000` 的 bit 12；它是 mapper 看到的 PPU 地址（例如 nametable/CHR fetch 地址）上的 A12。

### 10.4 cNES 观察

cNES `mmc3.c`：

- `_mmc3_get_prg_offset()` 用 8 KiB 粒度；
- `_mmc3_get_chr_offset()` 支持 2 KiB 大 bank和 1 KiB 小 bank；
- `_mmc3_tick()` 比较 `ppu_get_internal_regs()->addr_bus` 的 A12；
- 有 cooldown、staged IRQ、asserting IRQ 三步；
- submapper 3/4 选择边沿/计数触发变体。

这是很好的软件状态机观察，但 A12 过滤周期、reload 和 IRQ 边沿要按具体 MMC3 clone/NESdev 真值验证。

### 10.5 Obara 观察

Obara MMC3 的 `set_bus()` 直接接收 PPU address，按 CPU cycle 差值过滤；MC-ACC/NEC submapper 改变 clocking。它还把 `MAPPER_IRQ` 注入 CPU interrupt 结构。

### 10.6 RTL 建议

MMC3 不应只在 CPU 写 `$8001` 时改 bank；必须有一条 PPU 地址观察路径：

```text
PPU fetch address → A12 filter → IRQ clock
                                  ↓
                         irq_counter/latch/enable
                                  ↓
                              mapper IRQ
```

把 A12 filter、reload、enable、pending/ack 分成独立寄存器，便于测试时区分“计数器到零”和“IRQ 真正拉线”。

## 11. mapper IRQ 与 CPU 中断

```text
A12 filtered edge
       ↓
IRQ counter--
       ↓
counter == 0 && enabled
       ↓
mapper IRQ line low
       ↓
CPU poll IRQ + I flag
       ↓
$FFFE vector
```

NMI 不经过 mapper IRQ enable。写 disable/ack 和读/写某些寄存器可能清除或延迟 IRQ；软件常在 ISR 中先 disable，再 reload，最后 enable。

### 11.1 常见误区

- 把 PPU A12 当成 CPU 地址线。
- 计数器到零就立即清线，忽略 pending/ack 状态。
- 只在 PPU 可见像素阶段观察 A12，忽略 321–336 和其他取数。
- 使用 CPU 周期而非 PPU dot 给 A12 过滤。
- 把 IRQ 当成 NMI，导致 CPU 进入错误向量。

## 12. mapper 通用状态表

| 状态 | 触发 | 保存内容 | 输出 |
|---|---|---|---|
| `INIT` | reset/ROM load | 初始 bank、mirroring、RAM enable | 固定窗口 |
| `CPU_WRITE` | `$8000-$FFFF` 写入 | serial/普通 bank 寄存器 | 下一状态 |
| `PPU_FETCH` | PPU CHR/NT/AT 取数 | A12/地址历史 | CHR bank、IRQ clock |
| `IRQ_COUNT` | 过滤边沿 | counter | decrement/reload |
| `IRQ_ASSERT` | counter 命中 | pending/line | mapper IRQ |
| `IRQ_ACK` | disable/ack 写入 | 清 pending/enable | IRQ line high |

## 13. 实验

### 实验 A：NROM 镜像

准备 16 KiB PRG，在 `$8000` 和 `$C000` 读同一 offset；再用 32 KiB PRG 验证两窗口不同。记录 CPU 地址和物理 offset。

### 实验 B：UxROM bank

写不同 bank 值，读取 `$8000-$BFFF` 的首地址和 `$C000-$FFFF` 的向量。确认最后 bank 不变、低位 bank 编号和 CHR RAM 行为。

### 实验 C：CNROM

写入多个 CHR bank，读取同一个 PPU pattern 地址。确认 CPU PRG 不变、PPU 地址不变而 CHR 数据改变。

### 实验 D：MMC1 serial write

用五个 bit 逐次写 `$E000`，在第 1–4 次后读 PRG，第五次后再读。测试 reset bit、地址范围和 PRG mode。

### 实验 E：MMC3 IRQ

让 PPU 反复取数改变 A12，设置 latch=2，enable IRQ。数出 A12 过滤后的时钟数量，直到 IRQ line 拉低；再执行 disable/ack/reload/enable 序列。

## 14. 常见误区

- 把 mapper ID 当作 bank 编号或芯片型号。
- 只实现 PRG bank，不实现 CHR bank。
- 把 nametable mirroring 当成四个独立 1 KiB RAM。
- 忘记 `$6000-$7FFF` PRG RAM 的 enable/protect。
- 用 CPU 地址 `$2000` 的 bit 12 代替 PPU A12。
- 只在 PPU 可见像素阶段驱动 A12。
- MMC1 serial register 每次 CPU 写都直接完成五位。
- 忽略 bank 值 wrap、ROM 不足和 clone/submapper 差异。
- mapper 逻辑放在 PPU 像素循环里，导致 CPU 和 PPU 争用同一状态。

## 15. 后续 RTL 映射

### 15.1 通用 mapper shell

```text
nes_mapper
├── rom_metadata
├── prg_bank_mode
├── chr_bank_mode
├── prg_ram_enable/protect
├── nametable_map[4]
├── irq_state
├── cpu_prg_read
├── cpu_prg_write
├── ppu_chr_read
├── ppu_chr_write
├── ppu_addr_observe
└── irq_line
```

### 15.2 参数化实现顺序

1. NROM：固定 PRG、可选 CHR RAM。
2. UxROM：单个 16 KiB bank register。
3. CNROM：8 KiB CHR register。
4. MMC1：serial register 和 bank mode。
5. MMC3：8 个 bank、mirroring、IRQ。
6. 其他 mapper：把 clone/submapper 差异显式参数化。

### 15.3 验证接口

mapper 至少应暴露：

```text
selected_prg_bank
selected_chr_bank
nametable_map
last_ppu_addr
a12_filtered
irq_counter
irq_latched
cpu_write_count
```

这些信号既是调试端口，也是验证 PPU 取数和 CPU 写入顺序的证据。不要只暴露最终读数据；否则很难区分 bank 选择错误和 CHR ROM 内容错误。
