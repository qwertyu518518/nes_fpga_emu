# PPU 精灵：从软件模拟器模型到 RTL

本文说明 `rtl/nes_core/ppu/nes_ppu_sprite.v` 的接口合同和数据流，并且回答一个教学问题：

> 一个用 C 写的软件模拟器（OAM 字节数组 + 逐扫描线的评估状态机 + 移位寄存器）和一个用 Verilog 写的硬件实现（OAM RAM + 8 组比较器 + 优先级编码器 + 移位寄存器），究竟是不是**同一套行为的两种写法**？

结论：**是同一套行为，但本仓库当前的模块只实现了其中"空间上并行"的那一半。** 软件模拟器必须用状态机把 64 个精灵在 192 个 dot 里串行地筛成 8 个，因为 CPU 一次只能做一件事；真实硬件本来就有 64 路并行的比较器和一个优先级编码器，不需要状态机。`nes_ppu_sprite.v` 直接照抄了真实硬件的**并行**结构（64 路比较 + nth-set 优先级编码 + 8 个 pattern 取数器），所以它没有 secondary OAM、没有评估窗口、没有移位寄存器，代价是**一个 dot 之内必须把整条数据通路重新组合算一遍**。

行为权威是 NESdev APU/PPU 文档。参考的克隆仓库只作为"别人怎么实现"的观察：

```text
.slim/clonedeps/repos/caseif__cNES/include/ppu.h      OAM/secondary OAM 结构体与评估寄存器
.slim/clonedeps/repos/caseif__cNES/src/ppu.c           _do_sprite_evaluation / _do_sprite_fetching / 像素混合
.slim/clonedeps/repos/ObaraEmmanuel__NES/src/ppu.h    OAM[256] / OAM_cache[32] / sprite_units[8] / SpriteEvalMachine
.slim/clonedeps/repos/ObaraEmmanuel__NES/src/ppu.c    evaluate_sprites FSM / get_sprite_pixel / get_pixel
```

`[源码观察]` 标记的内容只是这两个仓库的写法，不是规格；本文没有用任何"看起来像规格"的措辞描述它们。

---

## 1. 术语与数据规模

| 名称 | 规模 | 说明 |
|---|---|---|
| primary OAM | 64 项 × 4 B = 256 B | `$0200-$02FF`。每项 4 字节：Y、tile、attr、X。**OAM 里的 Y 是"精灵顶端减一"**，精灵实际画在 `Y+1 .. Y+H`。 |
| secondary OAM | 8 项 × 4 B = 32 B | 真实硬件内部结构，软件模拟器必须自己造，硬件不需要外部可见 |
| pattern table | 2 张 × 4 KiB = 8 KiB | `$0000-$0FFF` 和 `$1000-$1FFF`。每张 256 个 tile，每 tile 16 B（plane 0 的 8 行 + plane 1 的 8 行） |
| 精灵 palette | `$3F11/$3F13/$3F15/$3F17` 起 4 组 × 4 项 | attr 的 bit1:0 选组，pattern 的 bit1:0 选组内项 |
| 可见区 | 240 行 × 256 dot | scanline 0..239，dot 0..255 |

本文的"精灵 N"一律指 OAM 里的第 N 项（0..63），"slot k"（k = 0..7）指本行最多能显示的 8 个位置。

---

## 2. 软件模拟器怎么存 OAM

### 2.1 cNES：把 OAM 当成 `struct Sprite` 数组

`[源码观察]` cNES 用 `#pragma pack(push,1)` 定义的 4 字节结构：

```c
typedef struct {
    uint8_t y;
    union { uint8_t tile_num; };
    union { SpriteAttributes attrs; uint8_t attrs_serial; };
    uint8_t x;
} Sprite;                                  /* 正好 4 B */

static Sprite g_oam_ram[OAM_PRIMARY_SIZE / sizeof(Sprite)];   /* 64 项 */
static Sprite g_secondary_oam_ram[OAM_SECONDARY_SIZE / sizeof(Sprite)];  /* 8 项 */
```

`attrs` 是一个 bitfield union：`palette_index:2, unused:3, low_priority:1, flip_hor:1, flip_ver:1`，即 attr 的 bit1:0 = palette、bit5 = 优先级、bit6 = hflip、bit7 = vflip。

评估过程用四个"影子寄存器"推进，全部放在 `PpuInternalRegisters` 里：

| 字段 | 宽度 | 含义 |
|---|---|---|
| `m` | 3 | 当前精灵的字节下标 0..3（0=Y，1=tile，2=attr，3=X） |
| `n` | 7 | 当前 primary OAM 项号 0..63 |
| `o` | 4 | 当前 secondary OAM 项号 0..7 |
| `p` | 8 | OAM 内的字节偏移（`oamaddr` 加上 `n*4`） |
| `sprite_attr_latch` / `has_latched_sprite` | 8 / 1 | 奇数 dot 读主 OAM、偶数 dot 写次 OAM 的中间锁存 |
| `loaded_sprites` | 8 | 本行实际显示几个精灵（在 dot 257 从 `o` 采样） |
| `sprite_0_next_scanline` / `sprite_0_scanline` | 1 / 1 | 精灵 0 标志的跨行延迟 |
| `sprite_x_counters[8]` | 8×8 | 每个 slot 的 X 倒计数 |
| `sprite_death_counters[8]` | 8×8 | 每个 slot 还能画几个 dot（硬件没有这个东西） |
| `sprite_tile_shift_l[8]` / `_h[8]` | 8×8 | 每个 slot 的两个 pattern 移位寄存器 |

`[源码观察]` `sprite_death_counters` 在 `ppu.h` 里有明确注释："there's no analog to this in hardware"。它是软件为了"画完 8 个像素就不要再画"而加的替身，硬件靠移位寄存器里补 0 自然结束。

### 2.2 Obara：扁平字节数组 + 显式 FSM

`[源码观察]` Obara 不做结构体，直接用字节数组：

```c
uint8_t OAM[256];        /* primary，扁平 */
uint8_t OAM_cache[32];   /* secondary */
SpriteUnit sprite_units[8];   /* { uint8_t x, attr, pattern_LSB, pattern_MSB, halted; } */

typedef enum SpriteEvalState { READ_OAM_Y, CMP_OAM_Y, READ_BYTE, WRITE_BYTE, OAM_EOF } SpriteEvalState;
typedef struct SpriteEvalMachine {
    SpriteEvalState state; uint8_t buffer, n, m, remaining,
                    has_sprite_zero, has_overflown; uint16_t oam_addr;
} SpriteEvalMachine;
```

两者的差别是"表达力"而不是"语义"：cNES 用 `m/n/o` 三个下标在同一段代码里分支，Obara 把同样的 `m/n` 搬进一个显式的 5 状态 FSM。FSM 版本的优点是能精确表达硬件的"次 OAM 满之后写入变成从 `OAM_cache[0]` 读"这种 glitch 行为。

`[源码观察]` Obara 读 OAM 时对 attr 字节做掩码：`ppu->OAM[addr] & ((addr & 3) == 2 ? 0xE3 : 0xFF)`，也就是**强制 attr 的 bit2/3/4 读回 0**。这是为了逼近真实硬件（那三位是未接线的）。

---

## 3. 软件模拟器怎么逐扫描线选精灵

### 3.1 硬件的时间表

NESdev 规定精灵处理分成三段，每段都在可见区扫描线上（以及 pre-render 行）：

| dot 区间 | 干什么 |
|---|---|
| 1..64 | 把 32 B 次 OAM 全部写成 `$FF`（"清空"是写 `$FF` 不是写 0） |
| 65..256 | 评估：读 primary OAM，把命中的精灵的 4 个字节搬进次 OAM，最多 8 个 |
| 257..320 | 取数：从次 OAM 读 8 组 {Y, tile, attr, X}，算 CHR 地址，取 pattern 的两个字节装进 8 组移位寄存器 |

评估在 dot 257 结束、fetch 在 dot 320 结束，但两者服务的是**下一行**——这也是精灵 0 标志在 cNES 里要用 `sprite_0_next_scanline` / `sprite_0_scanline` 两个寄存器倒一拍的原因。

### 3.2 cNES 的评估循环

`[源码观察]` `_do_sprite_evaluation()` 只在 `g_scanline` 落在可见区时跑，逻辑按 dot 号分三段：

- dot 0：`m = n = o = 0`，`sprite_0_scanline = sprite_0_next_scanline`，`sprite_0_next_scanline = false`。
- dot 1..64 且为偶数：把 `g_secondary_oam_ram[(char*)dot/2 - 1]` 写 `$FF`。
- dot 65..256：奇数 dot 读主 OAM，偶数 dot 写次 OAM。读的时候按 `m` 分四种状态：

```c
case 0: {  /* Y */
    uint8_t val = sprite.y;
    if (val <= g_scanline && g_scanline - val <= (g_ppu_control.tall_sprites ? 15 : 7)) {
        g_ppu_internal_regs.m++;                 /* 命中：不换精灵，只换字节 */
        g_ppu_internal_regs.sprite_attr_latch = val;
        g_ppu_internal_regs.has_latched_sprite = true;
        if (g_ppu_internal_regs.o >= 8)
            g_ppu_status.sprite_overflow = 1;    /* 第 9 个命中就置 overflow */
    } else {
        g_ppu_internal_regs.n++;                 /* 不命中：换精灵 */
    }
    break;
}
case 1: case 2: case 3:                          /* tile / attr / X */
    latch(...); m++; break;
```

偶数 dot：若 `has_latched_sprite` 且 `o < 8` 就把锁存字节写进次 OAM 的第 `m-1` 字节；若 `m == 4` 说明这个精灵的 4 字节都搬完了，于是 `n++`、`o++`、`m = 0`，并且**在 `n == 0` 刚完成时**置 `sprite_0_next_scanline`。

这个"命中就不换 `n`"的结构是全部复杂度所在：它让 64 项扫描可以在任意项上停 4 个 dot。硬件上不存在这个问题，因为 64 个比较器是并行的。

`_do_sprite_fetching()` 在 dot 257..320 用 `switch ((dot - 1) % 8)` 给 8 个 slot 分配 8 个 dot，取 `y / tile / attr / x / 算地址 / 读 plane0 / 读 plane1`。`index >= loaded_sprites` 的 slot 被塞 0（硬件是补 0，软件也是补 0）。

### 3.3 Obara 的评估 FSM

`[源码观察]` Obara 同样是 dot 奇偶分工，但用状态机表达：

- `clear_oam()`：每个奇数 dot 写一次 `OAM_cache[sec_oam_address & 0x1f] = 0xff`，偶数 dot 递增 `sec_oam_address`。
- `evaluate_sprites()`：dot 65 进入 `READ_OAM_Y`。
  - `READ_OAM_Y`：读 `OAM[(n<<2 | m) + oam_addr]`，进 `CMP_OAM_Y`。
  - `CMP_OAM_Y`：`if (sec_oam_address < 32)` 时先**无条件把 Y 写进次 OAM**，再 `is_y_in_range()` 决定是 `m++`（命中，继续读剩下 3 字节）还是 `n++`（不命中）。`sec_oam_address >= 32` 时进入溢出路径：仍然继续 `is_y_in_range()`，命中就置 `SPRITE_OVERFLOW`。
  - `READ_BYTE` / `WRITE_BYTE`：`remaining` 从 3 数到 0。
  - `OAM_EOF`：主 OAM 扫完后继续翻次 OAM。

范围判定只有一个函数：

```c
static uint8_t is_y_in_range(PPU* ppu, uint8_t y) {
    return (ppu->scanlines & 0xff) - y < 8 << (ppu->ctrl & LONG_SPRITE ? 1 : 0);
}
```

注意这里的减法在 C 里是无符号运算（`size_t` 减 `uint8_t`），所以 `y > scanline` 时会回绕成一个巨大的数，`巨大数 < 8` 为假——和 cNES 显式写 `val <= g_scanline &&` 得到同样的结果。**两个模拟器在"Y 大于当前行"这一点上是一致且正确的**，这值得记一笔，因为 OAM 里写 `Y=$FF` 是常见的"隐藏精灵"手法。

---

## 4. 软件模拟器怎么读 pattern

### 4.1 CHR 地址

8×8（`ctrl & LONG_SPRITE == 0`）：

```c
addr = (ctrl & SPRITE_TABLE ? 0x1000 : 0) | (tile * 16 + cur_y);
plane0 = vram[addr];
plane1 = vram[addr + 8];
```

8×16：

```c
bottom_tile = (cur_y > 7) ^ flip_ver;        /* 注意翻转要先改 bottom_tile */
if (cur_y > 7) cur_y -= 8;
adj = (tile & 0xFE) | (bottom_tile ? 1 : 0);
addr = ((tile & 1) * 0x1000) | (adj * 16 + cur_y);
```

要点有三个：

1. **8×16 的 pattern table 由 tile 号的 bit0 选，不由 `PPUCTRL[3]` 选。** `PPUCTRL[3]`（`BG_TABLE`/pattern table）在 8×16 模式下被忽略。
2. **8×16 的 tile 号先清 bit0 再或上"是否下半张"**，所以 tile 号的高 7 位是 7 个 tile 对（0/1、2/3、4/5 …），一共 128 个合法 tile。
3. **vflip 在 8×16 下要同时翻转"用哪张 tile"和"用哪一行"**。只翻行不翻 tile 会把上下半张画反；只翻 tile 不翻行同样错。cNES 用 `bottom_tile = (cur_y > 7) ^ flip_ver` 一次做对。

### 4.2 位序

精灵的 pattern 是 **MSB first**：不翻转时最左像素取 pattern 字节的 bit7。

`[源码观察]` cNES 的实现很直接：

```c
res = system_vram_read(g_ppu_internal_regs.addr_bus);
if (!attrs.flip_hor) res = _reverse_bits(res);   /* 不翻转：把字节位序反过来 */
g_ppu_internal_regs.sprite_tile_shift_l[index] = res;
...
g_ppu_internal_regs.sprite_tile_shift_l[i] >>= 1;  /* 每 dot 右移一位 */
palette_low = ((sprite_tile_shift_h[i] & 1) << 1) | (sprite_tile_shift_l[i] & 1);
```

存进移位寄存器的是 `位反转(byte)`，之后右移并取 bit0，于是左起第一个像素 = 原 byte 的 bit7。翻转时存原字节、左移取 MSB，于是左起第一个像素 = 原 byte 的 bit0。Obara 走的是另一条路（存原字节、不翻转时左移取 bit7、翻转时右移取 bit0），结果一致。

顺带一个常见的误解来源：背景的 pattern 是 **LSB first**（fine X 从 bit0 起移），精灵是 **MSB first**。同一张 CHR tile 当背景和当精灵看，左右是镜像的。

### 4.3 优先级：先到先得，不是"优先级位高的赢"

真实硬件的规则是两级的：

1. **先按 OAM 顺序**。同一像素上，OAM 下标小的精灵赢——**不管它的优先级位是 0 还是 1**。
2. **赢的那个精灵再用优先级位决定要不要盖住背景**。`attr[5] = 1` 表示"在背景后面"：此时如果背景像素非透明，就输出背景；否则输出精灵。

`[源码观察]` cNES 的 `break` 就在第 1 级的末尾：

```c
for (unsigned int i = 0; i < g_ppu_internal_regs.loaded_sprites; i++) {
    if (g_ppu_internal_regs.sprite_x_counters[i]) continue;      /* 还没到 X */
    if (!g_ppu_internal_regs.sprite_death_counters[i]) continue;  /* 8 个像素画完了 */
    unsigned int palette_low = ((sprite_tile_shift_h[i] & 1) << 1)
                             | (sprite_tile_shift_l[i] & 1);
    if (!palette_low) continue;                                   /* 透明 */
    if (g_ppu_internal_regs.sprite_0_scanline && i == 0
            && g_ppu_mask.show_background && !transparent_background
            && g_scanline_tick != 256)
        g_ppu_status.sprite_0_hit = 1;                            /* 精灵 0 hit */
    ...
    if (!attrs.low_priority || transparent_background)
        final_palette_offset = sprite_palette_offset;
    break;                       /* 第一个不透明的精灵独占这个像素 */
}
```

`[源码观察]` Obara 把它编码成一个 6 bit 的"精灵像素描述子"再在 `get_pixel()` 里解码：`0x10 | (palette<<2) | pattern | (attr & BIT_5) | (is_sprite0 ? BIT_6 : 0)`，然后

```c
switch ((bg_pixel > 0) << 1 | (sprite_pixel > 0)) {
case 0b00: return 0;                          /* 都没像素 */
case 0b01: return sprite_pixel & 0x1f;        /* 只有精灵 */
case 0b10: return bg_pixel;                   /* 只有背景 */
case 0b11:                                    /* 都有 */
    if (sprite_pixel & BIT_6 && ppu->dots < 256)
        ppu->status |= SPRITE_0_HIT;
    if (sprite_pixel & BIT_5) return bg_pixel; /* 优先级位 1：背景赢 */
    return sprite_pixel & 0x1f;               /* 优先级位 0：精灵赢 */
}
```

精灵 0 标志的注入点在 fetch 阶段：`unit->attr = sprite_buffer.attr | (dots == 259 && has_sprite_zero ? BIT_2 : 0)`——真实硬件在第 2 个 slot 的 attr 字节（dot 259）上把精灵 0 标记塞进 `attr[2]`，这正是 `attr` 的 bit2 一直读回 0 的原因。

---

## 5. 硬件怎么实现同一套行为

把上面三节翻译成电路，得到的正是 `nes_ppu_sprite.v` 的结构。

### 5.1 OAM RAM

真实硬件里 primary OAM 是一块 256×8 的 RAM，由 `$2003`（OAMADDR）和 `$2004`（OAMDATA）加上 `$4014` 的 DMA 写入。`nes_ppu_sprite.v` 不含这块 RAM，它把 OAM 作为 **2048 位扁平总线** 暴露在端口上：

```verilog
assign scan_addr = {1'b0, si[5:0], 2'b00};      /* si*4  = OAM 项的字节基址 */
assign scan_bit0 = {3'b000, scan_addr} << 3;     /* si*32 = 该项在 2048 位总线上的位偏移 */
```

即 **OAM 项 si 的 Y/tile/attr/X 分别在 `oam[si*32 +: 8]`、`+8`、`+16`、`+24`**。`+:` 变址部分选在这个模块里是核心的读端口：64 个扫描通道**并行**取各自的 Y，一次比较；被选中的 8 个 slot 再各取 3 个字节。

把 OAM 放在端口上而不是模块内部，是为了让 memory owner（PPU 寄存器层 + OAM DMA）决定它什么时候变。模块对 OAM 只读不写，因此不需要时钟——这正是它可以做成纯组合的前提。

### 5.2 CHR ROM

CHR 是外部总线，8 KiB 固定地址空间（CHRRAM 板子）或者 mapper 提供的 bank。模块同样把它当 8192 字节的只读窗口：

```verilog
assign s_pat_addr = {s_table, 5'b00000, s_tile, 1'b0, s_fine[2:0]};  /* 13 位 */
assign s_plane_lo = chr[{s_pat_addr, 3'b000} +: 8];                  /* 字节 = addr*8 */
assign s_plane_hi = chr[({s_pat_addr, 3'b000} + 13'd64) +: 8];       /* +64 字节 = plane1 */
```

`s_pat_addr` 的 13 位结构就是硬件 VRAM 地址总线的低 13 位：`{A12, 5'b0, A7..A3, A1..A0}`。`A1` 被钉 0 是因为 plane 0 的 8 行是连续的；plane 1 靠 `+64` 字节（= +8 行）偏移。tbl 上标的 `5'b00000` 在 8×8 模式下对应硬件上"精灵 pattern 地址天然落在 `$0000/$1000`"——因为 8×8 的 tile 号只有 3 位，`tile<<4` 最多到 0x7F，乘 16 到 0x7F0 已经在第一张表内；真正决定用哪张表的是 `s_table` 放在 A12。

### 5.3 8-slot selection：nth-set 优先级编码器

硬件的"选前 8 个命中的精灵"是一个**并行优先级编码器**：

```
64 个比较器 → 64 位 in_range 向量 → 取最低 8 个置位的位置
```

软件必须用 192 个 dot 串行做同一件事，硬件只需要一级组合逻辑。这个模块把优先级编码器写成了一个可综合的函数：

```verilog
function [5:0] nth_set;
    input [63:0] vec;
    input [2:0]  pick;
    // 数到第 pick 个置位就返回它的下标；置位不足时返回 0
```

然后 `generate` 出 8 份：

```verilog
for (g = 0; g < 8; g = g + 1) begin : g_slot
    assign s_idx = nth_set(in_range, SLOT_PICK);   /* SLOT_PICK = g */
```

`nth_set(in_range, 0)` 就是"最低置位"（`$clz` 家族里最常见的一个），`nth_set(in_range, 7)` 是"第 8 个置位"。8 个调用是完全独立的，天然并行。

一个必须有的守门条件是 `slot_opaque` 里的 `(SLOT_U8 < range_count)`：当命中的精灵不足 8 个时，`nth_set` 返回的是**垃圾下标**（没有第 g 个置位），所以 slot g 存在与否必须由计数单独判断。这个条件是"8-sprite 上限"的另一半——**超出 8 个的精灵不是被"画成透明"，而是从来没有对应的 slot**。

### 5.4 范围比较

```verilog
assign scan_row = {1'b0, scanline} - {2'b0, scan_y};      /* 10 位 */
assign scan_hit = (scan_row < {1'b0, sprite_height});     /* sprite_height = ctrl[5] ? 16 : 8 */
```

这就是 `is_y_in_range()` 的硬件形式。关键在**减法宽度**：10 位无符号减法让 `scanline < Y` 自然回绕成一个大于 16 的数，从而落进"不在范围内"，不需要额外的 `scanline >= Y` 比较器。软件里这一行是 `val <= g_scanline && g_scanline - val <= 15` 两个条件，硬件里是一个减法器加一个比较器。

`sprite_height` 同时决定 8×8/8×16，因此 `PPUCTRL[5]` 是这个模块里唯一影响行数比较的寄存器位。

### 5.5 pattern 取数与列地址

```verilog
assign s_table  = ctrl[5] ? s_tile_byte[0] : ctrl[3];
assign s_tile   = ctrl[5] ? (s_tile_byte[3:1] + {2'b00, s_row[3]}) : s_tile_byte[2:0];
assign s_fine   = slot_attr[g][7] ? ({1'b0, sprite_height} - 10'd1 - s_row) : s_row;
assign s_xoff   = {2'b00, dot[7:0]} - {2'b00, slot_x[g]};
assign s_xbit   = slot_attr[g][6] ? s_xoff[2:0] : (3'd7 - s_xoff[2:0]);
assign s_pat    = {s_plane_hi[s_xbit], s_plane_lo[s_xbit]};
```

逐条对应 4.1 节的软件写法：

- `s_table`：8×16 时来自 tile 号 bit0，8×8 时来自 `PPUCTRL[3]`。
- `s_tile`：8×16 时 `tile[3:1] + (row >= 8)`，等价于 `(tile & 0xFE) | bottom_tile`；8×8 时就是 `tile[2:0]`。
- `s_fine`：vflip 把行号镜像。`sprite_height - 1 - s_row` 在 8×8 下是 `7 - row`，8×16 下是 `15 - row`。注意软件里 vflip 需要**两次**处理（先选 tile 再选行），这里因为 `s_tile` 用的 `s_row[3]` 是**未翻转的**行号高位，而 `s_fine` 是翻转后的行号，一次减法就把两者都覆盖了——这是并行结构比串行状态机省事的典型例子。
- `s_xoff`：同样用 10 位减法让 `dot < X` 自然落到"不命中"，并且没有精灵的水平环绕（真实硬件的 X 是 8 位，精灵不会被画到下一行的左边）。
- `s_xbit`：不翻转时 `7 - xoff`，也就是**左起第一个像素取 bit7**（MSB first），和 4.2 节一致。

`slot_opaque` 把三件事合起来：

```verilog
assign slot_opaque[g] = (SLOT_U8 < range_count)      /* slot 真实存在 */
                     && (s_xoff[9:3] == 8'd0)         /* 0 <= dot - X <= 7 */
                     && (s_pat != 2'b00);            /* pattern 值非 0 */
```

### 5.6 优先级

```verilog
found = 1'b0;
for (j = 0; j < 8; j = j + 1)
    if (!found && slot_opaque[j]) begin
        sprite_pixel    = {slot_attr[j][1:0], slot_pat[j][1:0]};
        sprite_priority = {4{slot_attr[j][5]}};
        found = 1'b1;
    end
```

这就是 4.3 节那条"第一个不透明的精灵独占这个像素"的电路形式：一条 8 位优先选择链。`j` 从小到大扫，slot 编号就是 OAM 次序（因为 `nth_set` 返回的是递增下标），所以 `j` 小 = OAM 下标小 = 优先。软件里的 `break`、Obara 里的 `if (... && priority_unit == NULL)`，和这里的 `!found &&` 是同一行代码的三种写法。

注意 `sprite_priority` 输出是**胜出 slot** 的 `attr[5]`，不是"这一行有没有精灵在背景后面"。真正的背景/精灵合成不在这个模块里。

### 5.7 sprite 0 hit

```verilog
if (pixel_active)
    if (slot_opaque[0] && (bg_pixel != 4'h0))
        sprite0_hit = 1'b1;
```

软件里对应 4.3 节的两处条件：`i == 0`（本 slot 是精灵 0）和 `!transparent_background`（背景不透明）。差别有两处，都是有意的简化，见 6 节。

### 5.8 overflow

```verilog
if (frame_active && (range_count > 7'd8))
    sprite_overflow = 1'b1;
```

软件里对应"第 9 个命中的 Y 置位"。真实硬件的 overflow 行为要脏得多：评估状态机有一个著名的 bug（`m` 递增到 3 之后继续递到 4，绕回 0 之前会读错字节），导致 overflow 会在**第 9 个以及之后一大串**精灵上被误置位，而且和 `OAMADDR` 有关。软件模拟器为了可预测性通常只实现"第 9 个"，本模块直接实现成"计数 > 8"。

---

## 6. `nes_ppu_sprite.v` 的接口合同

### 6.1 端口

| 端口 | 方向 | 宽度 | 合同 |
|---|---|---|---|
| `clk` | in | 1 | **未使用。** 本模块是纯组合，没有寄存器。 |
| `ce` | in | 1 | **未使用。** 时序由 `scanline`/`dot` 外部给定。 |
| `reset` | in | 1 | 高有效。只参与 `frame_active = !reset && ...`，因此置位时四个输出全为 0。 |
| `oam` | in | 2048 | primary OAM 256 B，字节 n 在 `oam[n*8 +: 8]`。 |
| `chr` | in | 65536 | CHR 8 KiB，字节 n 在 `chr[n*8 +: 8]`。 |
| `ctrl` | in | 8 | PPUCTRL。**只用到 bit5**（1=8×16）和 **bit3**（8×8 的 pattern table）。 |
| `mask` | in | 8 | PPUMASK。**只用到 bit2**（1=显示左 8 像素的精灵）。 |
| `scanline` | in | 9 | `>= 240` 视为不可见。 |
| `dot` | in | 9 | `>= 256` 视为不可见；取数只用 `dot[7:0]`。 |
| `bg_pixel` | in | 4 | 背景 palette 索引（0 = 透明）。**只影响 `sprite0_hit`。** |
| `sprite_pixel` | out | 4 | `{attr[1:0], pat[1:0]}`：高 2 位是精灵 palette 组号，低 2 位是 pattern 值。**不是** `$3Fxx` 索引，也不是 RGB。 |
| `sprite_priority` | out | 4 | 4 位全等于胜出 slot 的 `attr[5]`。 |
| `sprite0_hit` | out | 1 | 见 6.3。 |
| `sprite_overflow` | out | 1 | 见 6.3。 |

### 6.2 可见区与门控

```verilog
wire sprite_height = ctrl[5] ? 9'd16 : 9'd8;
wire frame_active  = !reset && (scanline < 9'd240);
wire pixel_active  = frame_active && (dot < 9'd256) && ((dot >= 9'd8) || mask[2]);
```

- `frame_active` 用 `scanline < 240` 而不是"在可见区集合里"，所以 scanline 240..511 全部输出 0。
- `pixel_active` 为假时 `sprite_pixel` 和 `sprite_priority` 被强制清 0。
- `sprite0_hit` 也被 `pixel_active` 门控，所以左 8 像素被裁剪时 hit 也不会产生——这和软件模拟器一致（cNES 用 `!show_sprites_left && tick <= 8` 一起裁掉像素和 hit）。
- `sprite_overflow` **只**被 `frame_active` 门控，不受 `dot` 和 `mask[2]` 影响，也不受 `PPUMASK[4]` 影响。

### 6.3 两个标志

| 输出 | 精确条件 | 备注 |
|---|---|---|
| `sprite0_hit` | `pixel_active && slot_opaque[0] && bg_pixel != 0` | `slot_opaque[0]` 是"slot 0 不透明"，不是"OAM 第 0 项不透明" |
| `sprite_overflow` | `frame_active && range_count > 8` | 计数语义，不受 `PPUMASK` 和 dot 影响 |

---

## 7. 明确未实现 / 与真实 2C02 的差异

这些不是 bug，是这个模块定位（功能级组合模型）带来的已知边界。全部由 `tb/ppu/tb_nes_ppu_sprite.v` 显式钉住或明确列为未覆盖。

### 7.1 时序相关（最主要的一类）

- **没有 secondary OAM。** 真实硬件的 32 B 次 OAM 在本模块里不存在，"选中的 8 个精灵"每次都直接从 2048 位 OAM 总线上重新取。代价是每个 dot 都要重算 64 路比较 + 8 组取数，而不是硬件的"评估一次、fetch 一次、移位 8 次"。
- **没有评估窗口（dot 65..256）和 fetch 窗口（dot 257..320）。** 硬件在这 192+64 个 dot 里把下一行的数据准备好；本模块在 dot 0 就已经算好了整行的结果。
- **没有 X 倒计数器和移位寄存器。** `sprite_x_counters` / `sprite_death_counters` / `sprite_tile_shift_l/h`（软件里）以及硬件里对应的 8 组 8 位移位寄存器都不存在。X 比较是每个 dot 重新做一次减法。
- **没有 OAM DMA、没有 `OAMADDR`。** 真实硬件里 `OAMADDR != 0` 时精灵 0 的判定会退化（评估从 OAMADDR 开始，精灵 0 的位置被打乱），本模块永远从 OAM 项 0 开始扫。
- **没有次 OAM 溢出 glitch。** 真实硬件次 OAM 写满之后"写变成从 `OAM_cache[0]` 读"，导致屏幕上出现本来不该有的鬼影精灵（Blargg 的溢出测试就是测这个）。本模块的溢出只影响一个标志位。

### 7.2 行为简化

- **`sprite_overflow` 是计数语义。** 不复现硬件 `m` 递增 bug 造成的"第 9 个之后一堆精灵都误置位"，也不依赖 `OAMADDR`。
- **`PPUMASK[4]`（显示精灵）没有实现。** `mask = 8'h00` 时精灵照样出现在 `sprite_pixel` 上。TB 的 `test_eight_sprite_limit` 和 `test_mask_ctrl_and_bg_isolation` 显式断言了这个行为。
- **`PPUMASK[0]`（灰度）没有实现**，也不需要——`sprite_pixel` 只是 palette 组号，灰度要在 palette RAM 或输出级做。
- **左 8 像素裁剪只影响 `mask[2]`。** 硬件里 `PPUMASK[3]`（显示背景左 8 像素）独立，本模块不看 `bg_pixel` 是不是被裁剪出来的。
- **没有 dot 255 的 sprite 0 hit 抑制。** 真实硬件在 x=255 不产生 sprite 0 hit（cNES 写 `g_scanline_tick != 256`，Obara 写 `ppu->dots < 256`）。本模块在 dot 255 照常置位，TB 的 `test_sprite0_hit` 里 `hit at dot 255 is not suppressed` 一行把这个行为钉住。
- **`sprite0_hit` 用 slot 0 而不是 OAM 项 0。** OAM 项 0 不在范围内时，slot 0 由下一个在范围内的精灵占据，于是**非零 OAM 下标的精灵可以置 hit**。这是与硬件最容易被误解的一处差异，TB 里的 `slot 0 substitutes the first in range sprite` / `substituted slot 0 can raise the hit` 两行把它固定下来。
- **`sprite_priority` 不是混色结果。** 它只是胜出 slot 的 `attr[5]`，背景/精灵的最终合成留给上层。
- **没有 sprite priority 的"背景透明则精灵一定显示"这一支。** 硬件是 `priority==0 || bg_transparent` 才显示精灵；本模块把这一支整个交给上层，只给出 `attr[5]`。
- **扫描线 248..255 的精灵永远不可见。** 因为 `frame_active` 是 `scanline < 240`。真实硬件上 `Y=248` 的 8×8 精灵在第 248..255 行是可见的（会显示在 NMI 之后的第一批行里），本模块把它当作不存在。TB 的 `Y=248 is never visible` 一行覆盖。
- **`Y = $FF` 的"隐藏精灵"仍然有效。** 因为范围比较用 10 位无符号减法，`scanline - 255` 回绕成大数。这与 cNES/Obara 一致，是这个模块刻意保留的行为。

### 7.3 组合模型本身的资源代价

8 个 slot 各要 2 次 `chr` 变址读 + 1 次 `oam` 变址读，64 次 `oam` 变址读做范围扫描，`nth_set` 被求值 8 次（每次最多 64 轮迭代）。这在真实硬件上是一大片组合逻辑（≈ 64 路 10 位减法比较器 + 8 个 64 位优先级编码器 + 8 个 13 位 CHR 地址生成器 + 8 个 8:1 字节选择器），在 EP4CE10 上需要评估面积和关键路径。**功能上等价，时序上完全不是**，因此这一版没有把它当最终形态。

---

## 8. 验证

`tb/ppu/tb_nes_ppu_sprite.v` 是本模块的自检 testbench，详见 `tb/ppu/README.md` 的精灵章节。它用 `$fatal` 断言，12 个 test task 覆盖 8×8、8×16、pattern table、h/v/both flip、palette、优先级、sprite 0 hit、left-8 clip、8-sprite 上限、overflow、vblank/dot≥256/reset，以及 OAM 项 63 和 Y 回绕边界。
