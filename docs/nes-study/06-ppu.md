# 06 PPU：v/t/x/w、图形取数、精灵、滚动与 NMI

## 1. PPU 的职责边界

PPU 2C02 同时做三件事：

1. 维护视频地址和滚动状态；
2. 从 CHR、nametable、attribute、OAM、palette 取数据；
3. 按 dot 输出像素并产生 vblank/NMI 状态。

CPU 只通过 `$2000-$2007` 访问 PPU 的寄存器视图。PPU 在可见区域还会自己发起内部取数，这些取数与 CPU 访问共享部分 PPU 资源，但不一定经过 CPU 的 `mem_read` 接口。

本章源码观察：

```text
.slim/clonedeps/repos/caseif__cNES/include/ppu.h
.slim/clonedeps/repos/caseif__cNES/src/ppu.c
.slim/clonedeps/repos/ObaraEmmanuel__NES/src/ppu.h
.slim/clonedeps/repos/ObaraEmmanuel__NES/src/ppu.c
```

## 2. PPU 地址空间

| PPU 地址 | 内容 | 访问性质 |
|---|---|---|
| `$0000-$1FFF` | CHR pattern tables | 读/写由 mapper 的 CHR ROM/RAM 决定 |
| `$2000-$2FFF` | 四个逻辑 nametable 区域 | 经过 mirroring 映射到物理 nametable |
| `$3000-$3EFF` | `$2000-$2EFF` 的镜像 | 译码上按 nametable 处理 |
| `$3F00-$3FFF` | 32 字节 palette RAM | 有特殊镜像和 open-bus 行为 |
| `$4000-$401F` | 未定义/开放总线区域 | 读值不能用固定零替代所有情况 |

### 2.1 nametable 的结构

一个 2 KiB nametable 区域由 960 字节名称表和 64 字节属性表组成：

```text
0x000..0x3BF  tile index，32×30
0x3C0..0x3FF  attribute，32×30，每字节覆盖四个 16×16 象限
```

`$2000`、`$2400`、`$2800`、`$2C00` 是四个逻辑 nametable 的起点。实际物理位置取决于 horizontal、vertical、single-screen 或 four-screen 方式。

### 2.2 palette 镜像

palette 逻辑地址低 5 位选择 32 个字节，但有特殊镜像：

```text
$3F10 → $3F00
$3F14 → $3F04
$3F18 → $3F08
$3F1C → $3F0C
```

背景颜色索引 0、精灵颜色索引 0 是透明/共享颜色的特殊位置。色 emphasis 和灰度由 mask 影响最终颜色，不应简单改写 palette RAM。

## 3. 寄存器表

| CPU 地址 | 名称 | 写入作用 | 读取作用/副作用 |
|---:|---|---|---|
| `$2000` | PPUCTRL | base nametable、增量、sprite 表、8×16、NMI enable | 多数位为未定义/open bus 风格 |
| `$2001` | PPUMASK | 灰度、显示 BG/SPR、左侧 8 像素裁剪 | 多数位无普通数据意义 |
| `$2002` | PPUSTATUS | 通常无普通写入意义 | 返回 vblank/sprite0/overflow，并清 vblank、复位 w |
| `$2003` | OAMADDR | 设置 OAM 地址 | 通常返回未定义/open bus |
| `$2004` | OAMDATA | 写 OAM，地址后增 | 读 OAM，属性字节部分位有特殊行为 |
| `$2005` | PPUSCROLL | 第一次写 X，第二次写 Y | 共享 w |
| `$2006` | PPUADDR | 第一次高 6 位，第二次低 8 位 | 共享 w，第二次写复制 t 到 v |
| `$2007` | PPUDATA | 写 v 指向的 PPU 空间并递增 v | 读缓冲、v 递增、palette 特殊路径 |

`[源码观察]` cNES 的 `ppu_read_mmio()` 对 `$2002` 清 vblank latch、清 NMI buffer 并把 `w` 置零；对 `$2007` 区分 `<$3F00` 的缓冲读取和 palette 直接读取。Obara `mmu.c`/`ppu.c` 进一步用 latch、4-dot read/write 延迟和 open-bus decay 表达某些副作用。

`[NESdev 真值]` 读 `$2002`、写 `$2000/$2005/$2006` 的时序和 NMI 抑制必须结合具体 PPU 行为。不能用“读取一个 struct 字段”概括。

## 4. v、t、x、w：PPU 的四个滚动状态

### 4.1 位布局

`v` 和 `t` 都是 15 位地址，布局相同：

```text
bit 14 13 12 | 11 10 | 9  8  7  6  5 | 4  3  2  1  0
   fine Y   |  NT   | coarse Y     | coarse X
```

| 名称 | 宽度 | 作用 |
|---|---:|---|
| fine Y | 3 | 当前 tile 内 8 个像素行的位置 |
| nametable | 2 | 垂直/水平 nametable 选择 |
| coarse Y | 5 | tile 行，范围 0–29，另有边界状态 |
| coarse X | 5 | tile 列，范围 0–31 |
| `x` | 3 | fine X，窗口内像素偏移 |
| `w` | 1 | 双写寄存器的第一/第二次写选择 |

`v` 是当前渲染取数地址，`t` 是下一次水平/垂直复制或 CPU 双写暂存地址。`x` 独立于 `v` 的 coarse X，因为它控制 tile 内像素移位。

### 4.2 `w` 的共享范围

`w` 会被以下寄存器共享：

```text
读 $2002       → w = 0
写 $2005       → 第一次/第二次 X、Y
写 $2006       → 第一次/第二次 address
```

因此软件若在两次滚动写之间读取 status，第二次写会被解释成第一次。RTL 中 `w` 应是一个有明确读写者仲裁的寄存器。

### 4.3 `$2005` 写入

第一次写入 `value`：

```text
t.coarse_x = value >> 3
x           = value & 7
```

第二次写入：

```text
t.fine_y   = value & 7
t.coarse_y = (value >> 3) & 31
```

然后 `w` 翻转。`$2000` 的 nametable bits 也会写入 `t` 的 bits 11–10。

### 4.4 `$2006` 写入

第一次写入：

```text
t[14:8] = value[6:0]
t[15]    = 0
```

第二次写入：

```text
t[7:0] = value
v = t
```

第二次写后 `w` 回到 0。`$2007` 访问使用 `v`，并按 PPUCTRL bit 2 每次增加 1 或 32。

### 4.5 水平递增 `inc_x`

```text
if coarse_x == 31:
    coarse_x = 0
    nametable_horizontal ^= 1
else:
    coarse_x += 1
```

### 4.6 垂直递增 `inc_y`

```text
if fine_y != 7:
    fine_y += 1
else:
    fine_y = 0
    if coarse_y == 29:
        coarse_y = 0
        nametable_vertical ^= 1
    elif coarse_y == 31:
        coarse_y = 0
    else:
        coarse_y += 1
```

`coarse_y == 31` 的特殊行为是 PPU 滚动真值中的边界细节。不要把它简化为“所有 30 行都循环”。

## 5. scanline 和 dot 时间线

### 5.1 每行 341 个 dot

```text
dot:  0       1                         256 257       320 321       336 337 340
      idle    可见像素开始                 可见结束      水平复制结束   sprite fetch 结束  dummy
      └────────────── 256 像素 ─────────────┘
```

常见背景取数窗口是 dot 1–256 和 321–336。每 8 个 dot 形成一个 tile 的八个取数相位。

### 5.2 制式表

| 制式 | 总 scanline | 可见行 | vblank 起点 | pre-render 行 | 备注 |
|---|---:|---:|---:|---:|---|
| NTSC | 262 | 0–239 | 241 | 261 | 奇数帧在渲染打开时跳过一个 dot |
| PAL | 312 | 0–239 | 241 | 311 | vblank 区域更长 |
| Dendy | 常见 312，源码实现可能不同 | 依区域定义 | 依区域定义 | 依区域定义 | 不要直接套 cNES 常量 |

`[源码观察]` cNES 为 NTSC、PAL、Dendy 分别使用 262、312、313 行；Obara 的 `ppu.h` 使用 NTSC 261、PAL 311 作为 pre-render 行编号，说明不同实现对“总行数/预渲染编号”的记法不同。`[NESdev 真值]` 目标区域应以对应时序表为准；行号、vblank 起点和帧长度要一起定义。

### 5.3 一帧的阶段

```text
scanline 0..239       可见图像
scanline 240          post-render
scanline 241          vblank 起始，NMI 资格开始
scanline vblank_end   vblank
pre-render             清理状态、复制垂直滚动、准备下一帧
```

CPU 读取 `$2002` 会抑制当前 vblank NMI 的特定情况。PPU 仍会清除 vblank 状态，但 CPU 可能不会收到 NMI。

## 6. 背景图块取数流水线

### 6.1 八相位表

| 相位 | 周期 | 动作 | 产生的 latch/效果 |
|---:|---:|---|---|
| 0 | 第一个 dot | 计算 NT 地址 | `addr_bus` |
| 1 | 第二个 dot | 读 NT | `name_table_entry_latch` |
| 2 | 第三个 dot | 计算 AT 地址 | `attr_bus` |
| 3 | 第四个 dot | 读 AT | 选择 2-bit palette |
| 4 | 第五个 dot | 计算 pattern low 地址 | `addr_bus` |
| 5 | 第六个 dot | 读 pattern low | 低位 pattern latch |
| 6 | 第七个 dot | 计算 pattern high 地址 | `addr_bus + 8` |
| 7 | 第八个 dot | 读 pattern high、递增 v | 装入移位寄存器 |

ASCII 表示：

```text
dot group:       0       1       2       3       4       5       6       7
address calc:   NT  →   NT read  AT  →  AT read  PTlo →  PTlo read PT hi → PT hi read
v update:                                                               inc_x
```

最后还要在适当的可见 dot 做垂直递增，并在 pre-render 的指定 dot 把 `t` 的垂直部分复制到 `v`。

### 6.2 NT 地址

常见形式：

```text
nt_addr = 0x2000 | (v & 0x0FFF)
```

### 6.3 AT 地址

```text
at_addr = 0x23C0
        | (v & 0x0C00)
        | ((v >> 4) & 0x38)
        | ((v >> 2) & 0x07)
```

属性字节覆盖 32×32 象限；根据 coarse X/Y 的 bit 1 选择四个 2-bit quadrant 之一。

### 6.4 pattern 地址

8×8 背景 tile：

```text
pattern_addr = background_table_base
             + tile_index * 16
             + fine_y
low_plane  = read(pattern_addr)
high_plane = read(pattern_addr + 8)
```

背景表基址由 PPUCTRL bit 4 选择，通常为 `$0000` 或 `$1000`。

### 6.5 移位和 fine X

两个 pattern byte 形成 16 位移位寄存器，输出时用 `x` 选择 tile 内 bit。概念上：

```text
pixel_pattern = ((pattern_high >> (7 - x)) & 1) << 1
              | ((pattern_low  >> (7 - x)) & 1)
```

实际 RTL 可以使用 16 位 shift register、8 位窗口或预取 tile RAM，但必须保持 bit 顺序和 `x` 边界。

### 6.6 背景 palette

若 pattern index 为 0，背景像素透明并使用 backdrop；否则：

```text
palette_index = (attribute << 2) | pattern_index
color = palette[0x3F00 + palette_index]
```

背景和精灵共享某些 backdrop 镜像规则；不要把所有 `palette[0]` 当作完全独立的颜色。

## 7. 精灵评估和取数

### 7.1 OAM 结构

OAM 是 256 字节：

```text
sprite 0: Y, tile, attributes, X
sprite 1: Y, tile, attributes, X
...
sprite 63
```

64 个 sprite 的 Y 是“可见行之前一行”的坐标。8×8 sprite 的覆盖条件通常写为：

```text
scanline - sprite_y in [0,7]
```

8×16 sprite 为 `[0,15]`。显示时实际 tile 行还要考虑属性中的垂直翻转。

### 7.2 每行评估阶段

| dot 范围 | 工作 | 结果 |
|---|---|---|
| 1–64 | 清 secondary OAM | 准备最多 8 个 sprite 的 32 字节 |
| 65–256 | 按 OAM 顺序评估 | 找当前行覆盖的 sprite |
| 257–320 | 取 sprite pattern | 8 个 sprite，各 8 个相位 |
| 321–340 | 下一 tile/背景预取和 dummy | 准备下一行 |

`[源码观察]` cNES 用 `m/n/o/p`、`sprite_attr_latch`、八个 shift register 和 death counter 实现评估与输出；Obara 用 `SpriteEvalMachine`、八个 `SpriteUnit` 和 `OAM_cache` 实现。两者都显式处理最多 8 个 sprite，而不是遍历 64 个直接输出。

### 7.3 secondary OAM 和优先级

评估先按 OAM 索引从小到大选择 sprite。输出时同一像素可能由多个 sprite 覆盖：

- pattern index 为 0 的 sprite 透明；
- 第一个非透明 sprite 决定 sprite 侧候选；
- priority bit 决定 sprite 与非透明背景谁优先；
- sprite 0 命中需要满足特定显示和坐标条件。

不要只按 tile 编号或 OAM 地址排序；顺序是硬件可观察行为。

### 7.4 8×16 sprite

PPUCTRL bit 5 设置 8×16：

```text
tile 偶数：上半部分
tile 奇数：下半部分
pattern table base 由 tile bit 0 选择
```

垂直翻转会改变当前行在 tile 中的位置和上下半 tile 选择。cNES 的 `_do_sprite_fetching()` 对此有单独地址计算；Obara 的 `fetch_frame()` 也在 sprite prefetch 分支处理 `offset ^= 15`。

### 7.5 sprite 0 hit

sprite 0 hit 的必要条件通常包括：

- sprite 0 覆盖当前 dot；
- 背景和 sprite pattern 都非零；
- 背景和 sprite 显示已打开；
- 坐标不处于禁止命中的边界；
- 左 8 像素裁剪设置不会阻止该处输出。

命中后设置 PPUSTATUS bit 6。它不是“sprite 0 的矩形碰到背景就一定命中”，必须看具体像素。

## 8. OAM DMA

写 `$4014` 后，PPU 从 `page × 256` 读取 256 字节写入 OAM。DMA 期间 CPU 让出总线，PPU 自身 dot 仍继续。详细总线时序见 `04-cpu-bus.md`。

### 8.1 OAM 地址和回绕

OAMADDR 是 8 位地址寄存器；写 `$2004` 后通常递增并按 8 位回绕。DMA 的起始位置与 OAMADDR 交互会产生不同布局和 wrap 行为，不能总写成 `OAM[i] = read(page*256+i)`。

### 8.2 DMA 和渲染

OAM DMA 会影响 PPU 访问 OAM 的时序，某些游戏在敏感点更新 OAM。功能模拟可以先实现数据复制，周期精确 RTL 再加入总线占用、dummy 和写入相位。

## 9. 滚动和 NMI

### 9.1 垂直/水平复制

在渲染打开时：

- 每个 tile 水平取数后执行 `inc_x`；
- 可见行结束附近执行 `inc_y`；
- dot 257 把 `t` 的水平位复制到 `v`；
- pre-render 的约 280–304 dot 把 `t` 的垂直位复制到 `v`。

### 9.2 NMI split

典型软件流程：

```text
等待 vblank/NMI
在 ISR 中：
  写 $2005 = 0
  写 $2005 = scroll_y
  写 $2006 = nametable_high
  写 $2006 = 0
在第一行前：
  写 $2005 = scroll_x
  写 $2005 = 0
```

这是一种把一帧中不同区域使用不同 nametable/scroll 的技术。它要求 CPU 对 `$2005/$2006` 写入的 dot 位置非常敏感。

### 9.3 NMI 抑制

PPU 在 vblank 产生 NMI 资格；CPU 若在特定时间读取 `$2002`，可能清除 vblank 标志并抑制 NMI。还要考虑 NMI enable 在 `$2000` bit 7 何时打开。

`[源码观察]` cNES 用 `g_nmi_occurred`、`g_nmi_occurred_buffer` 和 `_ppu_nmi_connection()` 实现延迟/锁存；Obara 用 `status`, `nmi_delay`, `supress_vblank` 和 `update_NMI()`。这些是两种不同的内部建模。

`[NESdev 真值]` NMI 是边沿事件，状态位、enable 和抑制窗口的关系要按 PPU 时序验证；不能只把 NMI 当作 `if (vblank) irq=1`。

## 10. cNES 与 Obara 的 PPU 源码观察

| 主题 | cNES | Obara | 需要注意 |
|---|---|---|---|
| 状态存储 | 全局 `PpuInternalRegisters` | `PPU` 结构体 | 都能映射为寄存器组 |
| 背景取数 | `_do_tile_fetching()` | `fetch_frame()` | 都体现 8 相位流水线 |
| 精灵评估 | `m/n/o/p` 手工索引 | `SpriteEvalMachine` 状态 | 细节不等价于硬件完整规范 |
| 输出 | shift register、death counter | shift register、`SpriteUnit` | 需验证优先级和左裁剪 |
| 滚动 | `_update_v_*` | `inc_hori_v`, `inc_vert_v` | 公式接近但边界/时序需核对 |
| 读缓冲 | 直接更新 `read_buf` | 4-dot `read_to_buffer` | Obara 试图模拟延迟，cNES 是较简化路径 |
| open bus | `ppu_bus` 位掩码 | `latch` + decay | 两者都是软件模型 |
| frame | 262/312/313 | NTSC/PAL 预渲染编号 | 不能直接互换常量 |
| NMI | buffer + callback | interrupt bit + delay | 外部接口不同，外部行为要比较 |

### 10.1 cNES 的具体观察

- `PpuControl`、`PpuMask`、`PpuStatus` 用 bit-field 与 `serial` 共享字节。
- `PpuInternalRegisters` 直接保存 `v/t/x/w`、sprite latches、pattern shift registers 和 `addr_bus`。
- `_do_tile_fetching()` 用 `(scanline_tick - 1) % 8` 分配 NT/AT/pattern 相位。
- `cycle_ppu()` 先取背景/状态，再可视情况评估和取 sprite，最后在可见 dot 输出像素。
- `render_pixel()` 还有 `RM_NORMAL`、`RM_NT*`、`RM_PT` 等调试/nametable 显示模式；它们不是 PPU 硬件模式。

### 10.2 Obara 的具体观察

- `PPU` 结构体同时保存 v/t/x/w、nametable VRAM、OAM、secondary cache、palette、picture unit 和八个 sprite unit。
- `fetch_frame()` 用 `PPUPhase` 明确枚举 NT_ADDR、NT_READ、AT_ADDR、AT_READ、pattern low/high 的地址和读阶段。
- `read_ppu()`/`write_ppu()` 安排 4 个 PPU dot 的 buffer 行为，意图表现 PPU 数据访问延迟。
- `read_oam()`/`write_oam()` 在渲染期间有特殊 OAM 行为，源码注释也标出部分未实现位。
- `execute_ppu()` 在 pre-render 清除状态、复制滚动位、设置 vblank，并处理奇数帧跳 dot。

## 11. PPU 状态表

### 11.1 渲染开关

| 状态 | 条件 | 背景取数 | v 增量 | 精灵取数 | 说明 |
|---|---|---|---|---|---|
| `RENDER_OFF` | BG/SPR 都关 | 可有总线活动但不按渲染更新 | 不按渲染规则 | 不评估 | CPU 仍可访问 PPU |
| `BG_ONLY` | 只开 BG | 有 | 有 | 不输出 | 可用于测试滚动 |
| `SPR_ONLY` | 只开 sprite | 受实现影响 | 受实现影响 | 有 | 背景透明/禁用规则需验证 |
| `RENDER_ON` | 两者至少一个开 | 有 | 有 | 有 | 完整渲染路径 |

### 11.2 一行状态

```text
IDLE
  │ dot 1
  ▼
BG_FETCH ──每 8 dot──> BG_FETCH
  │ dot 257
  ▼
SPRITE_FETCH ──每 8 dot──> SPRITE_FETCH
  │ dot 321
  ▼
NEXT_LINE_PREFETCH
  │ dot 337..340
  ▼
NEXT_SCANLINE
```

## 12. 实验：逐 dot 验证

### 实验 A：单色 tile

1. CHR tile 0 的低/高 plane 设置为一个固定 pattern。
2. nametable 填满 tile 0。
3. attribute 设置为 palette 0。
4. 关闭 sprite 和左裁剪。
5. 记录每个 `(scanline,dot,x)` 的 pattern、attribute、palette index。

先验证 x=0、x=7、x=8 的 fine X 边界，再验证 nametable 边界。

### 实验 B：水平滚动

把 coarse X 从 0 改到 31，观察 dot 257 复制和 `inc_x` 是否翻转水平 nametable 位。把 fine X 改为 7，确认移位寄存器输出边界。

### 实验 C：sprite 0 hit

放置一个非透明 sprite 0 和非透明背景 tile，在不同 x 位置扫描状态 bit 6。检查：

- 左 8 像素关闭时是否不命中；
- 背景 pattern 为 0 时是否不命中；
- sprite pattern 为 0 时是否不命中；
- 关闭 BG 或 SPR 时是否不命中。

### 实验 D：NMI split

在 vblank ISR 中改变 `t` 的 nametable/vertical bits，在下一帧记录 pre-render 复制后的 `v`。对比“CPU 写寄存器立即改变 v”和“只在指定 dot 复制”的实现。

## 13. 常见误区

- 把 `v`、`t` 当成普通的 16 位滚动变量。
- 忘记 `x` 不在 `v` 的 coarse X 中。
- 把 `w` 看成每个寄存器独立的位。
- 以为 `$2007` 读总是立即得到当前地址的数据。
- 忽略 palette 的 `$3F10/$14/$18/$1C` 镜像。
- 把 341 dot 简化成 256 dot。
- 把 sprite 评估放在每个像素循环里，破坏 OAM 顺序和 8 个 sprite 限制。
- 只实现背景图块，不实现 257 和 pre-render 的复制。
- 把 cNES 的 262/312/313 行常量直接当成所有区域的真值。
- 把 Obara 的延迟和 glitch 代码视为已经完整实现的硬件规范。
- 看到 `render_pixel()` 输出就认为 PPU 已产生正确 NMI/vblank。

## 14. 后续 RTL 映射

### 14.1 PPU 模块接口

```text
ppu_dot_input:
  cpu_ppu_read
  cpu_ppu_write
  cpu_addr
  cpu_data
  oam_dma_byte
  oam_dma_active
  reset

ppu_dot_output:
  ppu_addr_bus
  ppu_data_in
  ppu_pixel
  pixel_x
  pixel_y
  frame_ready
  nmi_line
  v
  t
  x
  w
```

### 14.2 内部模块

```text
nes_ppu
├── ppu_register_file
├── vram_and_palette
├── oam_primary
├── oam_secondary
├── background_fetch
├── sprite_evaluator
├── sprite_fetch
├── pixel_mux_and_palette
├── scroll_increment
├── nmi_status
└── frame_counter
```

### 14.3 存储建议

- nametable 可用 4 个 1 KiB bank 或 2 KiB 物理 RAM 加 mirroring 译码。
- palette 用 32×6 bit RAM，open-bus 高两位由读端合成。
- OAM 256×8，secondary OAM 32×8。
- pattern fetch 可以用同步双口 RAM，也可以用 PPU bus 多周期读取；两种方案都要固定 pipeline latency。
- shift register 用 16 bit pattern 和 attribute shift，配合 `x` 选择输出。

### 14.4 最小实现顺序

1. 计数器和 vblank/NMI。
2. `v/t/x/w` 写入。
3. nametable/CHR/palette 读取。
4. 背景取数和像素输出。
5. 水平/垂直滚动。
6. OAM DMA。
7. sprite 评估和输出。
8. sprite 0、overflow、奇数帧和寄存器 glitch。

每一步都输出内部状态和总线地址；当画面不对时，先定位是取数地址、流水线相位、滚动还是优先级。
