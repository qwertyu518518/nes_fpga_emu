# 03 iNES、NES2、PRG 与 CHR 文件格式

## 1. 文件格式解决的不是“所有硬件行为”

ROM 文件头描述卡带的容量、mapper 编号、mirroring、电池 RAM 和制式等元数据。它不描述：

- 6502 每条指令的微周期；
- PPU 每个 dot 的取数顺序；
- APU 五个通道的内部计数器；
- mapper 在某个 CPU 周期内如何过滤边沿；
- 电源上电时的模拟电平。

因此“文件能加载”与“游戏能正确运行”是两个不同的验证层次。

## 2. iNES 文件的整体布局

标准布局如下：

```text
偏移       长度       内容
0x00       4          魔数 "NES\x1A"
0x04       1          PRG ROM 大小，单位 16 KiB
0x05       1          CHR ROM 大小，单位 8 KiB
0x06       1          flags 6
0x07       1          flags 7
0x08       8          NES 2.0 扩展字段，或 iNES 未使用
0x10       N          PRG ROM
0x10+N     M          CHR ROM（如果有）
之后                  trainer、可选数据或格式特定内容
```

`[NESdev 真值]` iNES 的基本 PRG/CHR 区域以固定块大小组织；mapper 决定这些块怎样映射到 CPU/PPU 地址窗口。iNES 本身没有要求 ROM 内部带校验和，不能把现代文件格式的 checksum 规则自动套上去。

## 3. 16 字节头字段

| 偏移 | 字段 | 关键位/含义 | RTL 关注点 |
|---:|---|---|---|
| 0 | magic | `4E 45 53 1A` | 解析状态、大小检查 |
| 4 | PRG ROM size | 16 KiB 块数 | PRG 字节数、bank 数 |
| 5 | CHR ROM size | 8 KiB 块数 | CHR ROM/RAM 判定 |
| 6 | flags 6 | bit 0 mirroring，bit 1 battery，bit 2 trainer，bit 3 four-screen，bit 4–7 mapper low | mirroring、trainer 偏移、NVRAM、mapper ID |
| 7 | flags 7 | bit 0–3 mapper high，bit 6 VS Unisystem，bit 7 PlayChoice，bits 2–3 NES 2.0 标识 | mapper ID、特殊系统 |
| 8–15 | NES 2.0 | submapper、扩展 ROM/RAM 位数、CHR RAM/NVRAM、exponent、timing | 运行时参数而非普通数据 |

### 3.1 flags 6 位图

```text
bit:       7   6   5   4   3       2       1        0
flags6:   mapper_low  four-screen  trainer  battery  mirroring
```

- bit 0 为 1 时通常是 vertical mirroring，为 0 时通常是 horizontal mirroring；具体命名要以所选 NESdev/iNES 解释为准。
- bit 1 表示电池支持的 PRG RAM，模拟器应决定是否持久化。
- bit 2 表示 trainer。若存在，数据位于 PRG 之前，解析器必须先跳过 512 字节。
- bit 3 表示 four-screen；它可能要求额外 1 KiB nametable 空间，不能简单当作普通 mirroring。
- bit 4–7 是 mapper 编号低四位。

### 3.2 flags 7 位图

```text
bit:       7          6              5   4   3   2   1   0
flags7:   PlayChoice  VS Unisystem   0   0  mapper high / NES2 标识
```

mapper 编号通常由 `((flags7 & 0xF0) >> 4) | (flags6 >> 4)` 得到。NES 2.0 使用 bit 2–3 的格式标识，扩展字段从 byte 8 开始。

## 4. PRG ROM：CPU 看到什么

PRG 是 CPU 程序存储空间。常见的 16 KiB 块数如下：

| header[4] | PRG 字节数 | 典型映射含义 |
|---:|---:|---|
| 1 | 16 KiB | NROM 128 KiB 以下，窗口常镜像 |
| 2 | 32 KiB | NROM 256 KiB，固定映射 |
| 4 | 64 KiB | 多 bank mapper 的常见起点 |
| 8 | 128 KiB | 需要切换或固定窗口的 mapper |
| 16 | 256 KiB | 大型卡带，仍由 mapper 决定窗口 |

### 4.1 NROM 的基本映射

```text
CPU $8000 ────────┐
                  ├── PRG bank 0，$8000-$BFFF
CPU $C000 ────────┘

CPU $C000 ────────┐
                  ├── PRG bank 1，$C000-$FFFF
CPU $FFFF ────────┘
```

16 KiB PRG 时，同一 16 KiB 内容会同时出现在 `$8000-$BFFF` 和 `$C000-$FFFF`。32 KiB PRG 时通常各占一个窗口。mapper 可以改变这个关系。

### 4.2 PRG bank 算术

很多 mapper 使用以下基本形式：

```text
prg_offset = (selected_bank * bank_size + (cpu_addr - window_base)) % prg_size
```

其中 `bank_size` 可能是 8 KiB、16 KiB 或其他粒度。`[常见误区]` 不能把 mapper 编号当成 bank 编号，也不能默认所有 mapper 都按 16 KiB 切 bank。

## 5. CHR ROM、CHR RAM 与 8 KiB 块

CHR 是 PPU 图形模式数据。header[5] 为 0 通常表示没有 CHR ROM，硬件/模拟器应提供 8 KiB CHR RAM；非零表示相应数量的 8 KiB CHR ROM 块。

| header[5] | CHR 字节数 | 典型用途 |
|---:|---:|---|
| 0 | 8 KiB CHR RAM | 软件上传 tile 图形 |
| 1 | 8 KiB CHR ROM | 固定图形 |
| 2 | 16 KiB CHR ROM | 两个 8 KiB 区域 |
| 4 | 32 KiB CHR ROM | mapper 可切 bank |
| 8 | 64 KiB CHR ROM | 复杂 CHR mapper |

### 5.1 tile 的存储格式

一个 8×8 tile 通常占 16 字节：

```text
tile n + 0 .. +7   平面 0：低有效位到高有效位
tile n + 8 .. +15  平面 1：高有效位
```

PPU 取出两字节后，按位组合成 0–3 的颜色索引。CHR 的 bank 选择通常以 1 KiB、2 KiB 或 4 KiB 为粒度，取决于 mapper。

### 5.2 CHR RAM 的边界

如果 `header[5] == 0`，CPU 仍不能直接写 `$0000-$1FFF`；写入 PPU 的 `$2007` 才会经过 PPU 数据端口写 CHR RAM。若 ROM 声明了 CHR ROM，mapper 的 CHR 写函数通常应忽略写入。文件名和源码注释不能替代这个规则。

## 6. NES 2.0 扩展

当 flags 7 的格式字段表示 NES 2.0 时，byte 8–15 承载额外信息。常见字段包括：

| 字节 | 内容 | 处理建议 |
|---:|---|---|
| 8 | mapper 高位和 submapper | 解析为完整 mapper ID、submapper |
| 9 | PRG/CHR ROM 扩展大小 | 与 byte 4/5 合并，注意单位和溢出 |
| 10 | PRG RAM/NVRAM shift count | 计算容量并设置持久化属性 |
| 11 | CHR RAM/NVRAM shift count | 计算容量和 ROM/RAM 属性 |
| 12 | timing 和其他扩展 | 选择 NTSC/PAL/Dendy/多制式 |
| 13–15 | 扩展标志/保留 | 不要默认为全零，保留原始值供诊断 |

### 6.1 容量计算的安全边界

若以字节为单位，常见形式是：

```text
64 << shift_count
```

解析器必须检查 shift count 的上限、整数溢出、ROM 文件剩余长度和分配失败。iNES 的 header 字节本身也可能损坏；“文件短于声明容量”应在加载阶段报错，而不是让 CPU 读到越界内存。

### 6.2 trainer

`[源码观察]` cNES `loader.c` 在发现 `flag6.has_trainer` 时打印“不支持”并返回失败，没有读取或跳过 512 字节。`[NESdev 真值]` trainer 是 ROM 数据布局的一部分，解析器应在正确的偏移处处理它；是否支持其内容是模拟器能力问题。`[RTL 建议]` 文件加载器至少应有一个 `trainer_present` 状态，不能把 trainer 数据误当成 PRG。

## 7. cNES loader 的实际流程

### 7.1 `load_rom()`

cNES `src/loader.c` 的观察流程如下：

```text
读取 16 字节 buffer
  ↓
检查 magic 0x4E45531A
  ↓
取 PRG 块数、CHR 块数
  ↓
解析 flags6、flags7
  ↓
若 NES2：解析 flag8..flag12
否则：根据文件名猜测 PAL
  ↓
_create_mapper(mapper_id, submapper)
  ↓
拒绝 trainer
  ↓
分配并读取 PRG/CHR
  ↓
填充 Cartridge
  ↓
调用 mapper->init_func(cart)
```

### 7.2 关键源码观察

- `prg_size` 和 `chr_size` 初始是 header 的块数，分配时分别乘以 `0x4000` 和 `0x2000`。
- mapper ID 是 `flag7.mapper_high << 4 | flag6.mapper_low`，NES2 还会加最高四位。
- cNES 的 `prg_ram_size` 和 `chr_ram_size` 默认各为 `$2000`；非 NES2 时这更像模拟器的默认容量策略，不是所有真实卡带的统一电气规格。
- `has_nv_ram` 只记录文件头电池 RAM 标志；系统初始化时尝试从 `sram.bin` 读取。
- cNES 的 `flag10`/`flag11` 代码中 `prg_nvram_size` 的条件使用了 `prg_ram_shift_count`；这应被视为源码实现细节，不能直接复制成通用 NES2 解析规则。

## 8. Obara loader 的观察

Obara 的 `src/mappers/mapper.c` 采用另一种组织：

- `load_file()` 先把文件读入 `ROMData`。
- `load_data()` 识别 `"NES\x1A"`、`"NESM\x1A"`、NSF 和 NSFe。
- `header[4]`、`header[5]` 先读成 `PRG_banks` 和 `CHR_banks`，NES2 再用 byte 9 扩展。
- `select_mapper()` 先装载 generic mapper 函数，再按 mapper ID 替换特定函数。
- `set_mirroring()` 用 `name_table_map[4]` 指向实际 nametable 偏移。

`[源码观察]` Obara 明确区分了 `MapperFormat` 的 `INES`、`NES2` 和 `ARCHAIC_INES`，并在 `RAM_size == 0` 时对非 NES2 文件假设 8 KiB PRG RAM。`[NESdev 真值]` 这是格式兼容策略，不是所有卡带都必须有 8 KiB RAM 的证明。

## 9. 运行时地址和文件 bank 的关系

```text
文件偏移
┌───────────────┐
│ PRG bank 0    │──┐
├───────────────┤  │
│ PRG bank 1    │──┼── mapper 选择 ── CPU $8000-$FFFF
├───────────────┤  │
│ PRG bank n    │──┘
└───────────────┘

CHR bank 0     ── mapper 选择 ── PPU $0000-$1FFF
CHR bank 1     ── mapper 选择 ── PPU $0000-$1FFF
```

mapper 的 bank 指针是“运行时窗口选择”，不是修改 ROM 文件。改变 bank 后，原文件偏移不变，只是 CPU/PPU 的译码结果改变。

## 10. 解析器状态表

| 状态 | 输入 | 下一状态 | 失败条件 |
|---|---|---|---|
| READ_HEADER | 文件前 16 字节 | PARSE_FLAGS | 文件过短、magic 错 |
| PARSE_FLAGS | byte 4–7 | PARSE_EXTENSION | 容量非法、格式未知 |
| PARSE_EXTENSION | byte 8–15 | CHECK_TRAINER | NES2 字段越界或 shift 过大 |
| CHECK_TRAINER | trainer 位 | READ_PRG | 当前实现不支持时报告失败 |
| READ_PRG | `prg_size × 16 KiB` | READ_CHR | 文件短于声明 |
| READ_CHR | `chr_size × 8 KiB` | BUILD_CARTRIDGE | 文件短于声明 |
| BUILD_CARTRIDGE | 元数据和数据指针 | RUN | 容量/指针/空分配检查失败 |
| RUN | CPU reset | EXECUTE | mapper 初始窗口无法提供向量 |

## 11. 手工解析实验

准备一个最小 NROM 文件的十六进制头：

```text
4E 45 53 1A 02 01 F0 00 00 00 00 00 00 00 00 00
```

按本文表格推导：

- magic 正确；
- PRG 为 2 个 16 KiB 块，共 `$8000` 字节；
- CHR 为 1 个 8 KiB 块；
- flags6 的 mapper low 为 `$F`，flags7 高位为 0，因此 mapper ID 为 15；
- flags6 bit 4 为 1，表示 battery；bit 3 为 1，表示 four-screen；需要确认该 ROM 是否真的符合这些声明。

然后改变 mapper high 位、CHR size 和 NES2 字段，重新推导运行时窗口。不要只检查文件总长度；还要检查声明的 PRG/CHR 是否能从当前文件偏移读到。

## 12. 常见误区

1. 把 header[4] 当作 KiB 或字节数。它是 16 KiB 块数。
2. 把 header[5] 为 0 当作“没有 CHR”。通常表示使用 8 KiB CHR RAM。
3. 忘记 trainer 会让 PRG 起点后移。
4. 把 mapper ID 的低/高四位顺序写反。
5. 把 NES2 byte 9 的扩展位简单拼到 byte 4/5，却不检查单位和溢出。
6. 看到 four-screen 就只改 mirroring enum，忽略额外 nametable RAM。
7. 把 battery 标志当作 NVRAM 一定已经初始化。
8. 用文件名猜 PAL 作为最终真值；文件名启发式不能替代 header、制式和测试 ROM。
9. 让 CPU 直接索引文件指针，绕过 mapper 的 bank 译码。
10. 解析器只检查 magic，不检查 ROM、CHR 和 trainer 的边界。

## 13. 后续 RTL 映射

### 13.1 文件加载器

文件加载器属于仿真/平台侧，不属于每个 CPU cycle 的核心逻辑。建议接口为：

```text
rom_header_valid
mapper_id
submapper_id
prg_rom_ptr / prg_rom_size
chr_rom_ptr / chr_rom_size
prg_ram_size / chr_ram_size
battery_present
timing_mode
```

在 FPGA 板上，ROM 文件通常在配置阶段由 SPI Flash/SDRAM 控制器读入；运行时 `nes_mapper` 只接收 bank 参数。

### 13.2 bank 译码器

```text
mapper_state:
  prg_bank_mode
  chr_bank_mode
  prg_ram_enable
  mirroring_mode
  irq_enable / irq_counter

CPU address ──> window_decode ──> bank_offset ──> PRG interface
PPU address ──> chr_decode ─────> bank_offset ──> CHR interface
```

将 bank 选择保存为寄存器，而不是每次重新执行 C 函数的完整 bank 搜索。非法或超出实际容量的 bank 号要有确定的 clamp、镜像或错误状态，并在 trace 中可见。

### 13.3 最小验证顺序

1. 只验证 header 字段和长度。
2. 只验证 NROM 128/256 KiB 固定映射。
3. 加入 PRG RAM 读写和 battery 策略。
4. 加入 CHR ROM 与 CHR RAM 两种路径。
5. 最后加入 mapper bank、mirroring 和 IRQ。

`[RTL 建议]` 这一章的格式解析不应与 CPU 指令执行绑死在同一个 always 块中；配置阶段错误应在仿真开始时报告，运行阶段只处理已验证的元数据。
