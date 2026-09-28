# CHR 取数可行性测量：单口外部 CHR 的 dot 预算与 attribute 陷阱

## 1. 这份文档是什么，不是什么

**这是决策依据，不是实现。**

对应的 testbench 是 `tb/ppu/tb_chr_fetch_feasibility.v`，它**一行 RTL 都没有改**。它做的事只有一件：把 `nes_ppu2c02`（`EXTERNAL_CHR = 1'b0`，也就是当前唯一可综合的内部 CHR 路径）当作**信号来源**，通过层次化引用读出它内部真实的 `dot` / `scanline` / `bg_x_total` / `bg_coarse_*` / `bg_attribute_byte` / `range_count` 等线网，在仿真里数出三个量：

| 编号 | 问题 | 本文对应小节 |
|---|---|---|
| Q1 | 背景取数的 dot 预算到底有多紧？"单口外部 CHR、每 dot 最多 1 字节、341 dot/行"装得下吗？ | 4 |
| Q2 | 精灵 shadow 预取的 `dot 257..272` 这 16 拍窗口够不够？固定 16 拍预取全部 slot 可行吗？ | 5 |
| Q3 | "不能把 `dot` 整体 mux 成 `dot+1`" 这个陷阱到底会坏多少？每行多少列会取错 attribute？ | 6 |

这三项对应 [`ppu-external-chr.md`](ppu-external-chr.md) 第 3-6 节的时序提案、第 4 节的 attribute 陷阱、以及第 6 节的预算表。第 7 节把这些实测结论映射回该文档第 8 节登记的三条行为差异。

**本文档不构成任何等价性证据。** 见第 8 节。

---

## 2. 方法

### 2.1 被测对象

| 项 | 值 |
|---|---|
| DUT | `nes_ppu2c02`，`MIRROR_VERTICAL = 1'b0`，`EXTERNAL_CHR = 1'b0`（走 `g_chr_internal` 分支） |
| 被测文件 | `rtl/nes_core/ppu/nes_ppu2c02.v`、`rtl/nes_core/ppu/nes_ppu_sprite.v` |
| 编译命令 | `iverilog -g2012 -Wall -s tb_chr_fetch_feasibility rtl/nes_core/ppu/nes_ppu2c02.v rtl/nes_core/ppu/nes_ppu_sprite.v tb/ppu/tb_chr_fetch_feasibility.v` |
| 通过判据 | 打印 `PASS chr_fetch_feasibility` |

选 `EXTERNAL_CHR = 1'b0` 是刻意的：这条分支是**当前唯一被回归覆盖的**渲染路径，它的组合取数结果就是"要等价到的目标"，所以它可以当作外部取数 FSM 的黄金参考。

### 2.2 层次化驱动的存储内容

testbench 直接写 `dut.nametable_ram` / `dut.chr_ram` / `dut.palette_ram` / `dut.oam_ram`（写法参考 `tb/ppu/tb_nes_ppu2c02.v` 的 `clear_memory` / `load_solid_scene`）：

| 存储 | 内容 | 目的 |
|---|---|---|
| `nametable_ram[0..959]` | `(row*7 + col*3) & 0xFF`，逐 tile 都不同 | 让 Q3 的"+1 dot 换 tile 号"必然产生可观测差异 |
| `nametable_ram[0x3C0..0x3FF]` 与 `[0x7C0..0x7FF]` | 偶数槽 `8'h1B`、奇数槽 `8'hE4` | 每个 attribute 字节的 4 个 quadrant 互不相同（`0x1B` 给出 3/2/1/0，`0xE4` 给出 0/1/2/3），因此"quadrant 选错"必然等于"attribute 值取错"；两块都写是为了 `MIRROR_VERTICAL=0` 下 `bg_nametable[1]=1` 的行也有可读的属性表 |
| `chr_ram[0..8191]` | `~i[7:0]` | 低/高平面对任意 bit 都至少有一个 1，保证 `bg_pattern_index != 0`，于是 palette 一定被 attribute 决定，颜色差异可观测 |
| `palette_ram[0..31]` | `0x10 + i` | 32 项互不相同，palette 索引不同必然颜色不同 |
| `oam_ram` | 23 个精灵有 Y（Y=0 的 9 个、Y=20 的 7 个、Y=60 的 4 个、Y=100 的 3 个），其余 41 个停在 Y=`0xF8` | 让每行 `range_count` 在 0 / 3 / 4 / 7 / 9 之间变化，并触发 8-sprite 溢出 |

### 2.3 观测的内部信号

全部通过层次化引用读取，**没有一行 RTL 改动**：

| 信号 | 用途 |
|---|---|
| `dut.dot` / `dut.scanline` | 时序基准，逐拍核对 |
| `dut.bg_x_total` | Q1 的 tile 边界、发射机会、dot 340 的取值 |
| `dut.temp_addr` / `dut.fine_x` | 解释相位来源 |
| `dut.bg_shown` / `dut.g_chr_internal.u_sprite.pixel_active` | 渲染窗口与发射窗口 |
| `dut.g_chr_internal.u_sprite.range_count` / `.sprite_pixel` / `.sprite_overflow` / `.sprite_height` | Q2 的活跃 slot 数 |
| `dut.bg_coarse_x` / `dut.bg_coarse_y` / `dut.bg_vertical_sections` / `dut.bg_y_total` | Q3 的坐标推导，以及"Y 侧与 dot 无关"的验证 |
| `dut.bg_attribute_byte` / `dut.bg_attribute` / `dut.bg_palette_index` / `dut.bg_palette_value` | Q3 的对照基准 |

### 2.4 Q3 的对照实验怎么做的

**没有改 RTL 去制造 bug。** testbench 内部完整重算了一遍背景通路（`bg_model` 任务），参数只有一个 `sh ∈ {0, 1}`：

- `sh = 0`：用 `bg_x_total` 本身。算式与 `nes_ppu2c02` 第 416-445 行逐条对应，包括 `mirror_nametable` 与 `palette_index_map` 两个函数的复制。
- `sh = 1`：唯一的差别是 `xts = dut.bg_x_total + 1`，其余全部照抄。这**正是** `assign eff_dot = EXTERNAL_CHR ? (dot + 1) : dot;` 的效果，因为 `bg_x_total` 是整条背景通路唯一的 `dot` 入口。

为了让这组测量本身可信，加了一条**逐拍自检**：在 dot 0..255 的每一拍上，`sh = 0` 的重算结果必须与 `dut.bg_palette_value`、`dut.bg_palette_index`、`dut.bg_attribute` **逐位相同**，否则立刻 `$fatal`。本实验跑完 16 帧、约 143 万拍，这条自检一次都没触发——也就是说"把 `dot` 整体 +1"这个反事实模型的**唯一**差异确实就是那 1 拍，测出来的差异数字可以直接归因给第 4 节那个陷阱。

（记录一个实现期的真实坑：RTL 的 `bg_nt_offset = {bg_nametable, bg_coarse_y, bg_coarse_x}` 把 `bg_nametable[1]` 放在 bit 11、`[0]` 放在 bit 10。重算模型最初写成 `{ntx, nty, ...}`，被上面那条自检在 scanline 240 dot 0 抓住。这条自检不是形式主义。）

### 2.5 跑了多少帧

13 组寄存器配置，合计 **16 个完整帧**（每帧 262 行 × 341 拍 = 89,342 拍，合计 1,429,472 拍）。A / L / M 三组各跑 2 帧，其余每组 1 帧；**所有帧的全部计入统计**。逐帧之间只改寄存器，不改存储。

| 组 | fine_x | coarse_x | coarse_y | PPUCTRL | PPUMASK | 精灵高度 | 帧数 | 用途 |
|---|---|---|---|---|---|---|---|---|
| A | 0 | 0 | 0 | `0x00` | `0x1C` | 8×8 | 2 | 基准 + Q3 主数据 |
| B..H | 1..7 | 0 | 0 | `0x00` | `0x1C` | 8×8 | 各 1 | Q1 的 fine_x 扫描 |
| I | 0 | 21 | 29 | `0x00` | `0x1C` | 8×8 | 1 | Q1 大 coarse_x |
| J | 7 | 31 | 29 | `0x00` | `0x1C` | 8×8 | 1 | Q1 `bg_x_total` 9 bit 溢出 |
| K | 6 | 20 | 15 | `0x01` | `0x1E` | 8×8 | 1 | Q1 最坏行（`mask[1]=1`）+ Q3 另一渲染窗口 |
| L | 5 | 12 | 7 | `0x20` | `0x1C` | 8×16 | 2 | Q2 的 8×16 |
| M | 5 | 12 | 7 | `0x00` | `0x1C` | 8×8 | 2 | Q2 的 8×8 + 逐行明细 |

`PPUMASK = 0x1C` 是"左 8 像素不显示"（`mask[1]=0`），`0x1E` 是"左 8 像素显示"（`mask[1]=1`）。`set_config` 每次都断言 `fine_x` / `temp_addr[4:0]` / `temp_addr[9:5]` / `temp_addr[11:10]` / `mask_reg` / `control_reg` / `u_sprite.sprite_height` 全部与配置相符，不符即 `$fatal`。

### 2.6 测量点自身的有效性检查

以下每一条都是 `$fatal`，任何一条不成立就不会打印 PASS：

| 检查 | 期望 | 覆盖范围 |
|---|---|---|
| `dot` / `scanline` 逐拍核对 | 262 × 341 全对 | 每拍 |
| 每帧结束必须回到 0:0 | 是 | 每帧 |
| 可见区（dot 0..255）`bg_x_total[2:0] == 3'd7` 次数 | **恰好 32** | 全部 262 行 × 16 帧 |
| 整行（dot 0..340）tile 边界次数 | 42 或 43 | 全部 262 行 × 16 帧 |
| 发射机会（`bg_x_total[2:0] == 3'd6`）与边界次数之差 | ≤ 1 | 全部 262 行 × 16 帧 |
| hblank 拍数（dot ≥ 256） | 85 | 全部 262 行 × 16 帧 |
| `dot 257..272` 拍数 | 16 | 全部 262 行 × 16 帧 |
| `bg_shown` 拍数 | 333（`mask[1]=0`）/ 341（`mask[1]=1`） | 全部 262 行 × 16 帧 |
| `u_sprite.pixel_active` 拍数 | 256（行 0..239）/ 0（行 240..261） | 全部 262 行 × 16 帧 |
| 实际出背景像素的列数（`scanline<240 && dot<256 && bg_shown`） | 248（`mask[1]=0`）/ 256（`mask[1]=1`） | 全部 262 行 × 16 帧 |
| `u_sprite.range_count` 在一行内不变 | 不变 | 全部 262 行 × 16 帧 |
| `dut.bg_coarse_y` 在一行内不变 | 不变 | 全部 262 行 × 16 帧 |
| `dut.bg_y_total` 在一行内不变 | 不变 | 全部 262 行 × 16 帧 |
| 背景通路重算模型（`sh=0`）与 DUT 逐位一致 | 一致 | dot 0..255 每一拍 |

最后两条顺带把 [`ppu-external-chr.md`](ppu-external-chr.md) 3.5 和 3.6 的两个说法**从仿真里验证了**：

- `bg_y_total` 在一整行内恒定 → 3.5 说的"`bg_y_total` 不依赖 `dot`，所以提前一整行取数不引入 Y 方向偏差"成立。
- `bg_coarse_y` / `bg_vertical_sections` 派生自 `bg_y_total`，因此同样与 `dot` 无关 → 3.6 说的"Y 侧三根线与 `dot` 完全无关，取数支路直接复用"成立，取数支路不需要任何 `dot` 项。

---

## 3. 先说一个被实测推翻的预期

任务描述里预期"每行 tile 边界数应为 33/行左右"。**实测不是 33，是 32**，而且在 13 组配置、262 行、16 帧里**一次都不例外**（这条就是上面那条 `== 32` 的 `$fatal`）。

原因是算得清、也测得着的：`bg_x_total = dot + fine_x + (temp_addr[4:0] << 3)`，最后一项是 8 的倍数，所以 tile 相位只由 `(dot + fine_x) mod 8` 决定；而 dot 0..255 正好是 256 拍 = 32 个完整的 8 拍周期，所以**任何 `fine_x` 下都恰好 32 个 tile 边界**。

"33"这个数字来自 [`ppu-external-chr.md`](ppu-external-chr.md) 6.1 的写法"32 个可见 tile + 1 个预取 tile"。**tile 数**确实是 33（32 个边界切出来的 tile，加上渲染窗口两端各可能压掉半个 tile 的补齐），但**边界数**是 32。本文下面把"边界数"和"tile 数"分开写，不再混用。

---

## 4. Q1 — 背景取数的 dot 预算

### 4.1 实测数据

| 组 | fine_x | coarse_x | coarse_y | PPUMASK | 可见区边界数(dot 0..255) | 整行边界数(dot 0..340) | 边界最小间隔 | 渲染窗口 tile 数 | 背景字节/行 | 占 341 拍 | 占渲染列 |
|---|---|---|---|---|---|---|---|---|---|---|---|
| A | 0 | 0 | 0 | `0x1C` | 32 | 42 | 8 | 31 | 64 | 18.76% | 25.80% |
| B | 1 | 0 | 0 | `0x1C` | 32 | 42 | 8 | 32 | 66 | 19.35% | 26.61% |
| C | 2 | 0 | 0 | `0x1C` | 32 | 42 | 8 | 32 | 66 | 19.35% | 26.61% |
| D | 3 | 0 | 0 | `0x1C` | 32 | 43 | 8 | 32 | 66 | 19.35% | 26.61% |
| E | 4 | 0 | 0 | `0x1C` | 32 | 43 | 8 | 32 | 66 | 19.35% | 26.61% |
| F | 5 | 0 | 0 | `0x1C` | 32 | 43 | 8 | 32 | 66 | 19.35% | 26.61% |
| G | 6 | 0 | 0 | `0x1C` | 32 | 43 | 8 | 32 | 66 | 19.35% | 26.61% |
| H | 7 | 0 | 0 | `0x1C` | 32 | 43 | 8 | 32 | 66 | 19.35% | 26.61% |
| I | 0 | 21 | 29 | `0x1C` | 32 | 42 | 8 | 31 | 64 | 18.76% | 25.80% |
| J | 7 | 31 | 29 | `0x1C` | 32 | 43 | 8 | 32 | 66 | 19.35% | 26.61% |
| K | 6 | 20 | 15 | `0x1E` | 32 | 43 | 8 | **33** | **68** | **19.94%** | 26.56% |

字节数 = 渲染窗口 tile 数 × 2 + 1 个预取 tile × 2。渲染列数 = 248（`mask[1]=0`）或 256（`mask[1]=1`）。

同一份数据里另外几条被断言过的量：

| 量 | 实测 |
|---|---|
| 发射机会（`bg_x_total[2:0] == 3'd6`，即 3.2 的 `bg_x_total_f[2:0] == 3'd7`）次数/行 | 42 或 43，与边界次数相同或差 1（差 1 发生在整行最后一次发射的落点越过 dot 340） |
| 相邻 tile 边界的最小间隔 | **8 拍**（13 组配置全部） |
| 可见区（行 0..239）的 `pixel_active` 拍数 | 256 |
| 行 240..261 的 `pixel_active` 拍数 | **0** |
| `bg_shown` 拍数 | 333 / 341，**在全部 262 行上都成立**——`bg_shown` 没有被 `scanline` 门控，vblank 行同样是 333 拍。真正决定"出不出像素"的是 `pixel_valid = (scanline < 240) && (dot < 256)` |

### 4.2 最坏行

可见区 tile 数在 `mask[1]=0` 时恒为 31（`fine_x=0`）或 32（`fine_x≠0`），**没有更坏的行**。真正的最坏组合是 K 组：`mask[1]=1` 把渲染窗口从 dot 8..255 扩到 dot 0..255，同时 `fine_x=6` 让 dot 0 落在 tile 中间，于是窗口里有 33 个 tile：

- 最坏行背景字节数 = 33 × 2 + 2 = **68 B/行**
- 占 341 拍 = **19.94%**
- 占 256 个渲染列 = **26.56%**

`fine_x` 确实让 tile 边界整体平移（B..H 组的整行边界数从 42 变 43 就是这个平移造成的），但**平移不改变每行的 tile 数上界**，因为 256 拍窗口里 tile 起点要么 31 个要么 32 个，加上窗口头部最多再压进半个 tile，最坏封顶 33。

### 4.3 一个实测出来的地址算式问题（不是带宽问题）

3.5 提议"在**本行 dot 340** 把下一行的第一个 tile 打进 `bg_lo_q` / `bg_hi_q`"。实测 `bg_x_total` 在 dot 340 的取值：

| 组 | coarse_x | fine_x | dot 340 的 `bg_x_total` | dot 340 的 tile 索引 `bg_x_total[8:3]` | dot 0 的 tile 索引（= coarse_x） |
|---|---|---|---|---|---|
| A | 0 | 0 | 340 | 42 | 0 |
| H | 0 | 7 | 347 | 43 | 0 |
| I | 21 | 0 | 508 | 63 | 21 |
| K | 20 | 6 | 506 | 63 | 20 |
| L / M | 12 | 5 | 441 | 55 | 12 |
| J | 31 | 7 | **83** | **10** | 31 |

- `lines_where_dot340_tile_index_equals_coarse_x = 0`，13 组配置、共 4192 行，**一次都不成立**。`bg_x_total` 是行内单调计数器，它在 dot 340 的 tile 索引是"本行第 42~63 个 tile"，不是"下一行的第 0 个 tile"。取数状态机在 dot 340 必须**显式把 tile 索引强制回 `coarse_x`**，不能靠 `bg_x_total` 自然走到 0。
- `bg_x_total` 只有 **9 bit**（`nes_ppu2c02.v:300`、`:416`）。J 组 `340 + 7 + 8*31 = 595`，9 bit 回绕成 83，tile 索引从本该有的 73 跳到 10。溢出的门槛是 `8*coarse_x + fine_x + dot ≥ 512`：在 dot 340 处 `coarse_x ≥ 22`（`fine_x=0`）或 `coarse_x ≥ 21`（`fine_x=7`）就会溢出。**可见区 dot 0..255 永远不溢出**（最坏 `255 + 7 + 248 = 510`），所以溢出只影响 hblank。
- 但**溢出不影响节拍**：`bg_x_total` 每拍仍然 +1，`bg_x_total[2:0] == 3'd7` 的节拍没有被破坏，J 组的"边界最小间隔 = 8"就是证据。溢出的后果只是 hblank 里的相位/偏移量发生跳变，也就是上一条那个"dot 340 地址算错"的问题被放大，不是新增一个带宽约束。

### 4.4 Q1 结论

**装得下，而且余量很大。**

- 需求侧最坏 68 B/行（`mask[1]=1` + `fine_x≠0` + 预取 tile），常规 64~66 B/行。
- 供给侧：一行 341 拍、每拍最多 1 字节，共 341 B。
- **实测占用率 18.76% ~ 19.94%**（分母 341 拍）。即使把分母缩到真正出像素的 248 / 256 列，占用率也只有 25.80% ~ 26.56%。
- tile 边界最小间隔实测 8 拍，因此 3.2 的"每个 tile 2 个 `ce` 拍连发 lo/hi"永远有地方放，不需要额外的时序技巧。

**唯一的"装不下"不是带宽，而是地址算式**：dot 340 的预取不能用 `bg_x_total` 直接算（第 4.3 节）。这是改写状态机的问题，不是换资源的问题。

---

## 5. Q2 — 精灵 shadow 预取的 16 拍窗口

### 5.1 实测数据

| 量 | 8×8（M 组，2 帧） | 8×16（L 组，2 帧） |
|---|---|---|
| `dot 257..272` 的拍数 / 行 | **16，全部 262 行** | **16，全部 262 行** |
| hblank（dot 256..340）拍数 / 行 | **85，全部 262 行** | 85，全部 262 行 |
| 可见区（行 0..239）`range_count` min / max | 0 / 9 | 0 / 9 |
| `range_count` 直方图（262 行） | 0:222、3:8、4:8、7:8、9:8、41:8 | 0:184、3:16、4:16、7:16、9:16、41:16 |
| 8-sprite 限制后实际渲染 slot 数 / 行 min / max / 平均 | 0 / 8 / **0.73** | 0 / 8 / **1.46** |
| 固定成本 `8 slot × 2 plane` | 16 B/可见行 | 16 B/可见行 |
| 有用成本 `2 × min(range_count, 8)` / 可见行平均 | **1.47 B** | **2.93 B** |
| 固定 16 B 占 16 拍窗口 | 100% | 100% |
| 固定 16 B 占 85 拍 hblank | **18.82%** | 18.82% |
| 有用成本占 16 拍窗口 | 9.16% | 18.33% |
| `sprite_overflow` 为真的行数 / 帧 | 8 | 8 |
| 出精灵像素的拍数 / 行 min / max | 0 / 56 | 0 / 64 |
| 行 240..261 的 `range_count` min / max | 0 / **41** | 0 / 41 |

几点必须读清楚：

- **8×16 不会改变每字节成本。** 5.2 关心的"整 tile 缓存要 160 B"来自"每 slot 缓存两平面全部 8 行"，而 5.3 的 shadow latch 只存"本行要用的那 1 个字节"，所以 `8 slot × 2 plane × 1 B = 16 B` 与精灵高度无关。实测两模式的固定成本都是 16 B/可见行。8×16 改变的只是**每行有多少 slot 处于范围内**：直方图从 8 行一组变成 16 行一组（行 0..15 上 `range_count=9`，8×8 时只有行 0..7）。
- **`dot 257..272` 恒定可用。** 这 16 拍在 262 行每一行都存在（被 `$fatal` 断言过），包括 vblank 行 241..260 和 pre-render 行 261。需要它的只有"下一行要渲染精灵"的那些行，共 241 个（行 0..239 各由前一行的 hblank 服务，帧首行 0 由行 261 的 hblank 服务）。行 240 的 hblank 是浪费的，因为 `frame_active = (scanline < 240)`，行 240 不渲染。
- **2 拍同步读的延迟吃得下。** 在 dot 257..272 发 16 次请求，数据在 dot 258..273 回来，最晚一次落在 dot 273，仍在 hblank（256..340）内，且远早于下一行 dot 0 开始渲染。
- **行 240..261 的 `range_count` 是 41，不是 0。** OAM 里停在 Y=`0xF8`（248）的 41 个"停放"精灵在行 248..255 落入范围。`nes_ppu_sprite` 的 `frame_active` 在这些行是 0，所以一个精灵都不渲染，但 `range_count` 仍然是 41。这直接说明 8.2 描述的"overflow 变成用下一行 OAM 算"不是纯理论：现在 `sprite_overflow` 的定义是 `frame_active && (range_count > 8)`，落在**本行**；一旦改成用下一行的预取结果，它读到的 OAM 集合和现在这一行渲染用的**不是同一批**。

### 5.2 Q2 结论

**"固定 16 拍预取全部 slot"可行，不需要按活跃 slot 数动态缩短窗口。**

- 窗口恒定：16 拍，在全部 262 行都存在，实测无例外。
- 容量足够：需求恒为 16 B/可见行，窗口 16 拍 = 16 B，正好 1:1；放到整个 hblank 上是 16/85 = **18.82%**。
- 延迟足够：最后一次返回落在 dot 273，仍在 hblank 内。
- 动态缩短窗口能省的很有限：当前激励下有用成本平均只有 1.47 B（8×8）/ 2.93 B（8×16），占窗口 9.16% / 18.33%。也就是说固定 16 拍方案在**最坏行是 100% 占满窗口、在平均行浪费约 91%**，但这个"浪费"换来的是状态机里没有"本行到底有几个 slot"这条额外依赖。
- 唯一真实的代价不是时序而是**正确性**：固定 16 拍意味着必须为全部 8 个 slot 发请求，包括 `range_count < 8` 时的空 slot。`nes_ppu_sprite` 的 slot 选择是 `nth_set(in_range, SLOT_PICK)`，`in_range` 位不足时 `nth_set` 返回 0，即空 slot 会重复取 sprite 0 的地址。这不产生像素（`slot_opaque` 有 `SLOT_U8 < range_count` 门控），但会浪费 2 次外部读。**如果外部 CHR 的读有副作用或需要 bank 递增，这个浪费要单独确认。**

---

## 6. Q3 — "不能把 `dot` 整体 mux 成 `dot+1`" 这个陷阱

### 6.1 原理

整条背景通路只有一个 `dot` 入口，就是 `nes_ppu2c02.v:416` 的

```verilog
assign bg_x_total = {1'b0, dot} + {6'b0, fine_x} + ({4'b0, temp_addr[4:0]} << 3);
```

`bg_coarse_x_sum`、`bg_coarse_x`、`bg_nametable[0]`、`bg_nt_offset`、`bg_attr_offset`、`bg_name`、`bg_attribute_byte`、`bg_attribute`、`bg_pattern_bit`、`bg_pattern_addr` 全部由它派生。所以 `eff_dot = dot + 1` 等价于"整条通路提前 1 拍"，其中：

- `bg_name` 提前 1 拍**是想要的**（3.1 只抽 `bg_x_total_f` 支路就是为了这个）；
- `bg_attribute_byte` 提前 1 拍、`bg_attribute` 的 quadrant 选择 `{bg_coarse_y[1], bg_coarse_x[1]}` 里的 `bg_coarse_x[1]` 提前 1 拍**是纯粹的错误**。

第 4 节说的"每一行的 32 列都会取到错误的 attribute quadrant"这句话是**错的**：因为 `bg_coarse_x[1]` 每 16 拍才翻一次，不是每 8 拍。下面是实测。

### 6.2 实测数据

反事实模型（`sh=1`）与正确路径（`sh=0`）逐列比较。`mask[1]=0` 时渲染窗口是 dot 8..255（248 列），`mask[1]=1` 时是 dot 0..255（256 列）。

| 组 | 渲染列/行 | 错 `bg_name` 的列/行 | 错 `bg_attribute_byte` 的列/行 | **错 attribute 值的列/行** | 错 palette 索引的列/行 | 最终背景色不同的列/行 | 行内访问到的 coarse X 个数 | 其中含错列的 coarse X |
|---|---|---|---|---|---|---|---|---|
| A（2 帧，fine_x=0, coarse_y=0） | 248 | 31 | 8 | **16** | 196 | 196 | 31 | 16 |
| B..H（各 1 帧，fine_x=1..7） | 248 | 31 | 8 | **16** | 195~196 | 195~196 | 32 | 16 |
| I（fine_x=0, coarse_x=21, coarse_y=29） | 248 | 31 | 8 | **16** | 196 | 196 | 31 | 16 |
| J（fine_x=7, coarse_x=31, coarse_y=29） | 248 | 31 | 8 | **16** | 196 | 196 | 32 | 16 |
| K（fine_x=6, coarse_x=20, coarse_y=15, `mask=0x1E`） | 256 | **0** | 8 | **16** | 160 | 160 | 32 | 16 |

逐行明细（pass M，行 0..40 每一行）显示 `bad_attr_columns` 恒为 **16**，不是平均 16。

整帧合计（pass A，2 帧，119,040 个渲染列）：

| 量 | 计数 | 占渲染列 |
|---|---|---|
| `bg_name` 不同 | 14,880 | 12.50% |
| `bg_attribute_byte` 不同 | 3,840 | 3.23% |
| **attribute 值不同** | **7,680** | **6.45%** |
| palette 索引不同 | 76,336 | 64.12% |
| 最终背景色不同 | 76,336 | 64.12% |

### 6.3 Q3 结论

**每行 32 个 tile 列（248 / 256 个像素列）里，恰好 16 列会取到不同的 attribute 值。**

- 精确数字：**16 列 / 行**，占渲染列的 **6.45%**（`mask[1]=0`，16/248）或 **6.25%**（`mask[1]=1`，16/256）。
- 16 = 一行里 `bg_coarse_x[1]` 翻转的次数（每 16 拍一次，256 拍窗口 16 次）。在 13 组配置、16 帧、262 行的全部可见行上，这个数字一次都没变过。
- 有 16 个不同的 `coarse_x` 取值各自含 1 个错列，即**每 32 个 tile 里有 16 个 tile 会被污染 1 列**，而不是"每个 tile 都错"。
- `bg_attribute_byte` 本身只在 `bg_coarse_x[4:2]` 变化时（每 32 拍）才不同，所以每行只有 8 列连字节都读错，另外 8 列是"字节读对了、quadrant 选错了"。两者加起来正好 16。
- 8×16 与精灵设置无关（Q3 完全在背景通路里），L / M 两组的 Q3 数字逐项相同，这也顺带交叉验证了测量本身。
- **最终颜色差异远大于 attribute 差异**：196/248 = 79% 的列背景色不同（整帧 64.12%）。因为 `dot+1` 同时把 `bg_name` 提前了 1 拍，于是每 8 拍换一次 tile 号，加上 `bg_pattern_bit` 也提前，pattern 数据本身在 12.5% 的列上就是错的。**这一项不是 attribute 陷阱造成的，是"整条通路 mux"的必然后果**——也正是 3.1 只抽一根 `bg_x_total_f` 支路、把 `bg_coarse_x` / `bg_coarse_y` / `bg_attribute_byte` 留在 `dot` 上的理由。
- K 组的 `bg_name` 差异是 **0**，原因与 attribute 无关：`MIRROR_VERTICAL = 0` 时 `mirror_nametable` 丢掉了 `address[10]`（水平 nametable 位），取字节的物理地址与 `bg_nametable[0]` 无关，所以 `coarse_x` 跨 nametable 边界时 tile 号不跳。K 组的 `bg_attribute_byte` 差异是 8（不是 0），因为 attribute 偏移的高位仍然经过 `address[10]` 参与拼接、只是最终被 mirror 丢掉，物理地址随 `cxc[4:2]` 变化。

---

## 7. 映射回 `ppu-external-chr.md` 第 8 节的三条行为差异

| 第 8 节的差异 | 时序上装得下吗（实测） | 性质 |
|---|---|---|
| **8.1** `$2007` 写 CHR RAM 后渲染晚 1 dot 可见 | **装得下。** 写 CHR 不产生任何额外取数：每行的取数总量恒为 64~68 B，与 `$2007` 写无关。晚 1 dot 只是"读回延迟"，不改变节拍。 | **纯行为差异，是决策问题。** 不是时序问题。 |
| **8.2** `sprite_overflow` 变成"下一行计数" | **装得下。** overflow 由预取结果算出，而预取本来就发生在 hblank 的 dot 257..272（第 5 节实测该窗口恒为 16 拍），不需要任何额外 dot。代价是**语义**变化：实测行 240..261 的 `range_count` 与渲染行完全不同（行 248..255 是 41，而 8 个范围内时只有 9），所以"用下一行 OAM 算"读到的确实不是当前这一行渲染用的那批精灵。 | **纯行为差异，是决策问题。** 但注意它比 8.1/8.3 更难自证：现在 `sprite_overflow` 的定义是 `frame_active && (range_count > 8)`，外部模式要改口径，而 `$2002` 的粘滞寄存器行为不变，所以"读值不变、置位点后移"这个说法需要新的 TB 证据才能成立。 |
| **8.3** `$2007` 读 nametable 区间别名到 CHR 前 8 KiB | **装得下，且与取数预算完全无关。** 这条只影响 CPU 通过 `$2007` 回读 nametable 的路径，一个渲染周期里都不发生。 | **纯行为差异，是决策问题。** 与 Q1/Q2 的时序结论无关。 |

**三条全部是"时序上装得下、纯粹是行为差异"。** 换句话说：[`ppu-external-chr.md`](ppu-external-chr.md) 第 10 节"整帧逐像素与内部模式相同"的验收判据与这三条的冲突，**不是被 dot 预算否掉的**——预算是够的（Q1 最坏 19.94%，Q2 最坏 18.82%）。冲突只在于"要不要接受行为差异"这个纯决策问题。

反过来，本次实测找出**两处真正需要改设计的地方**，都不属于第 8 节：

| 位置 | 问题 | 性质 |
|---|---|---|
| [`ppu-external-chr.md`](ppu-external-chr.md) 3.5 "dot 340 预取下一行的第一个 tile" | `bg_x_total` 在 dot 340 的 tile 索引实测是本行第 42~63 个 tile（`coarse_x=31` 时因 9 bit 溢出变成第 10 个），**在任何一组配置下都不等于 dot 0 的 tile 索引**（0/4192 行）。取数状态机必须在 dot 340 显式把 tile 索引强制回 `coarse_x`。 | **地址算式不成立**，必须改写。不是带宽不够。 |
| [`ppu-external-chr.md`](ppu-external-chr.md) 4 "整体 mux 成 `dot+1`" | 实测每行 16 列（6.45%）取错 attribute、196/248 列（79%）最终背景色不同。 | **实现方式不成立**，必须按 3.1 只抽 `bg_x_total_f` 一根支路。不是预算不够。 |

另外 3.2（发射条件跟着 `fine_x` 漂移）在实测里得到确认：tile 边界最小间隔 8 拍，但整行边界数在 `fine_x=0..2` 是 42、在 `fine_x=3..7` 是 43，**边界相位确实随 `fine_x` 整体平移**，所以 3.2 说的"不能把发射点固定在 dot 8/16/24/..."是对的。3.3（复制 nametable）与 3.6（共用 `bg_coarse_y_sum`）不涉及 dot 预算；其中 3.6 的"Y 侧与 `dot` 无关"已由本实验的逐拍断言验证（`bg_coarse_y` 与 `bg_y_total` 在一整行内恒定，262 行 × 16 帧无一例外）。

---

## 8. 本实验**没有**验证的东西

这一节必须和结论一起读。

1. **没有验证外部 CHR 取数逻辑能跑。** `g_chr_external` 里仍然是 `chr_req = 1'b0`、`chr_addr = 14'd0`、`chr_we = 1'b0`、`chr_wdata = 8'h00`，`chr_rdata` 在整个 `nes_ppu2c02` 里一次都没有被读过。本实验连 `EXTERNAL_CHR = 1'b1` 都没有实例化过。
2. **不构成任何等价性证据。** 第 4/5/6 节的全部数字都是"预算"与"反事实差异"，不是"`EXTERNAL_CHR=1` 的输出等于 `EXTERNAL_CHR=0` 的输出"。第 6 节的 16 列 / 196 列是"如果**用错实现方式**会坏多少"，不是"实现之后的差异"。
3. **没有验证时序合同。** 2.1 节的 `ce_ppu` 4 分频、`chr_req` 1 拍脉冲、`chr_addr` 请求期间保持、`chr_rdata` 下一个 `ce` 有效，这些是 [`ppu-external-chr.md`](ppu-external-chr.md) 2.1 的设计决定。本实验的 `ce` 是 testbench 自己一拍一拍的 `tick_dot` 驱动的，**不是** `nes_system_v5` 的 `div_phase`，所以"每 dot 1 字节"这个前提本身没有被端到端验证过。
4. **没有覆盖运行期改变 scroll 的情形。** 13 组配置都是"整帧固定寄存器"。游戏会在帧中途写 `$2005` / `$2000`，那时 `temp_addr` 会在一行中途变化，`bg_coarse_x_sum` / `bg_vertical_sections` 在一行内就不再恒定（本实验的断言只证明"寄存器不变时它们恒定"）。3.6 说的"一旦复制出第二份 `/30`、`%30` 就可能不一致"这个风险，本实验**没有**测。
5. **没有覆盖 CPU 在渲染期访问 `$2007`**（8.1/8.3 涉及的路径），也没有覆盖 `$2007` 写 CHR 与取数请求撞在同一拍的情形。
6. **没有做综合 / 时序收敛验证。** "19.94% 占用率"是**拍数**的占用率，不是门级时序。单口外部 CHR 走 SDRAM 的真实延迟、仲裁、突发效率都在本实验范围之外（[`ppu-external-chr.md`](ppu-external-chr.md) 6.3 那些带宽数字是估算，不是本实验的产物）。
7. **Q3 的 16 列这个数字依赖激励。** 本实验刻意让每个 attribute 字节的 4 个 quadrant 互不相同，让 tile 号逐 tile 不同，让 CHR 两平面按位取反。如果换成"整张 attribute 表同值 + 全屏同一个 tile"的画面，attribute 差异的**可观测**数会变，但**象限被选错的事实**和每行 16 次翻转的节拍不变。换句话说：16 列是"选错的象限数"，它在任何激励下都成立；"有多少列因此在画面上看得出差别"则依赖数据。

---

## 9. 复现

```powershell
C:\iverilog\bin\iverilog.exe -g2012 -Wall -o "$env:TEMP\chrfeas.vvp" -s tb_chr_fetch_feasibility `
    rtl\nes_core\ppu\nes_ppu2c02.v rtl\nes_core\ppu\nes_ppu_sprite.v tb\ppu\tb_chr_fetch_feasibility.v
C:\iverilog\bin\vvp.exe "$env:TEMP\chrfeas.vvp"
```

这个 testbench **已纳入回归入口**。`tools/sim_all.ps1` 里有对应目标 `chr-feasibility-tb`（`Group = 'ppu'`，是 `$allTargets` 的第 9 个目标，紧跟 `ppu-integration`），源文件列表就是 PPU 集 `nes_ppu_sprite.v` + `nes_ppu2c02.v` 再加本 testbench，`-g2012` 编译 + `vvp`，成功时同样打印 `PASS chr_fetch_feasibility`。单独跑：

```powershell
.\tools\sim_all.ps1 -Mode chr-feasibility-tb
```

**最近一次全量回归已经改成 47/47 全绿**，但这不是写这份文档那一轮的结果，而是**后续轮次**的结果：写这份文档时 `tools/sim_all.ps1` 只有 43 个目标，当时的记录是 43/43；其后 `nes_chr_fetch_unit.v` 与 `sd_spi_cmd.v` 两个新模块进入仓库，回归目标数随之变成 47，本文档第 3 节与第 2 节的数字没有因此改动。47 个目标全部 PASS、退出码 0，逐目标耗时合计 **803.4 s**、墙钟 **803.8 s ≈ 13.4 min**。本目标仍然是其中最慢的一个（该轮记录 75.2 s；本机单独复跑 `-Mode ppu` 两次分别实测 74 s 与 70.8 s）。目标表、证据表与 7.1/7.2/7.3 的对应条目请以 `docs/00-overview/verification-plan.md` 的当前版本为准。

**本轮新增的 4 个目标是 `chr-fetch-core`、`chr-fetch-tb`、`sd-spi-cmd-core`、`sd-spi-cmd-tb`**，其中 `chr-fetch-core`（`-g2001` elaborate `nes_chr_fetch_unit`）与 `chr-fetch-tb`（`tb_nes_chr_fetch_unit`）与本实验的 `chr-feasibility-tb` 同属**外部 CHR 取数**这一条线：一个测本文第 4/5/6 节的 dot 预算与反事实差异，另一个测取数单元本身的单口节拍合同（每 tile 2 拍 lo/hi、地址在请求拍提前一拍就位、`ce=0` 冻结、行中 `req_start` 被忽略、行间 `bg_valid` 不串数据、复位中止）。**但把这两条线接起来的那一步还没有做：`nes_chr_fetch_unit` 至今没有被 `nes_ppu2c02` 例化，`g_chr_external` 分支在 RTL 里仍然是死的（`chr_req` 恒 0、`chr_rdata` 一次都没被读过），CHR 取数通路仍未接通。** 因此本文第 1–8 节的全部数字仍然是"预算与反事实差异"，`chr-fetch-tb` 通过**不构成**任何等价性证据——第 8 节那 7 条"没有验证的东西"一条都没有被它关闭。

成功时最后一行是 `PASS chr_fetch_feasibility`。13 组配置各打印一段 `PASS-FRAME <组名>`，每段含 Q1 / Q2 / Q3 三组实测数字、Q2 的 `range_count` 直方图；M 组之后另有一段逐行明细（行 0..40、95..115、240..261），每行给出 `range_count` / `sprite_pixel_dots` / `overflow_dots` / `rendered_bg_columns` / `bad_attr_columns`。明细里的 `rendered_bg_columns` 在行 240..261 恒为 0，因为 `pixel_valid` 把 `scanline >= 240` 排除掉了；而原始的 `bg_shown` 信号在全部 262 行上都是 333 拍（`mask[1]=0`），这一点由断言保证、不在明细里打印。

`-Wall` 下本 testbench 零 warning。RTL 侧有 **9 条既有 warning**，全部是 `@*` 对数组敏感：`nes_ppu_sprite.v:333,334,334,335,340,360` 共 6 条（第 334 行自己就发两条，分别是 `slot_attr` 和 `slot_pat`）加 `nes_ppu2c02.v:445,769,774` 共 3 条。这些与本实验无关，也**没有**被本实验消除——回归目标 `chr-feasibility-tb` 与 `ppu-core` 用的是同一份 PPU 源文件列表，这 9 条 warning 在两条目标上都会出现（注意 `tools/sim_all.ps1` 自己不加 `-Wall`，所以跑回归时看不到它们，本节这段数字是按上面第 9 节那条带 `-Wall` 的复现命令数的）。
