# NES PPU 2C02 v0 testbench

`tb_nes_ppu2c02.v` 是 `rtl/nes_core/ppu/nes_ppu2c02.v` 的自检 testbench。它直接实例化 PPU，自行通过层次引用初始化 2 KiB nametable、8 KiB CHR、256 B OAM 和 32 B palette，不下载 ROM，也不需要外部 test ROM。

`nes_ppu2c02.v` 现在内部实例化 `rtl/nes_core/ppu/nes_ppu_sprite.v`（实例名 `u_sprite`），把 8x8/8x16、翻转、palette 组、8-sprite 上限交给那个模块，PPU 顶层只做 mask / 状态位集成和背景-精灵混色。**因此编译 `nes_ppu2c02.v` 时必须同时给出 `nes_ppu_sprite.v`**，见下面“运行”一节的完整命令。

## 本目录的 testbench 一览

本目录现在有 **7** 个 testbench，都不下载 ROM、不读外部文件：

| testbench | 被测对象 | 性质 | 小节 |
| --- | --- | --- | --- |
| `tb_nes_ppu2c02.v` | `rtl/nes_core/ppu/nes_ppu2c02.v` | 自检 testbench | “PPU 2C02 v0 testbench”正文 |
| `tb_nes_ppu_sprite.v` | `rtl/nes_core/ppu/nes_ppu_sprite.v` | 自检 testbench | 精灵 testbench |
| `tb_nes_oam_dma.v` | `rtl/nes_core/ppu/nes_oam_dma.v` | 自检 testbench | OAM DMA testbench |
| `tb_nes_chr_fetch_unit.v` | `rtl/nes_core/ppu/nes_chr_fetch_unit.v` | 自检 testbench | CHR 取数单元 testbench |
| `tb_chr_fetch_feasibility.v` | 不是被测模块，是 `nes_ppu2c02`（`EXTERNAL_CHR=1'b0`） | **测量实验**，一行 RTL 都没改 | CHR 取数可行性实验 testbench |
| `tb_nes_ppu2c02_ext_chr.v` | 同时例化 `nes_ppu2c02` 的 `EXTERNAL_CHR=0` 与 `1` 两个实例 | A/B 等价性 testbench（回归目标 `ppu-ext-chr-tb`） | “明确未实现”节记录的精灵 A/B 证据 |
| `tb_nes_sprite_chr_fetch.v` | `rtl/nes_core/ppu/nes_sprite_chr_fetch.v` | 自检 testbench | 与取数单元 testbench 同属精灵 CHR 预取这条线 |

后四个都属"外部 CHR 取数"这条线，但**它们彼此独立**：`tb_nes_chr_fetch_unit.v` 测背景取数单元自己的时序合同，`tb_nes_sprite_chr_fetch.v` 测精灵预取单元自己的时序合同，`tb_chr_fetch_feasibility.v` 测 dot 预算，而 `tb_nes_ppu2c02_ext_chr.v` 是把两个单元放进真实 PPU 里做 `EXTERNAL_CHR=0` vs `1` 的逐 `ce` A/B——**只有它提供像素级证据**，另外三个各自只证明单元自身的约定（见各节"未覆盖项"）。**`nes_chr_fetch_unit` 现在已经被 `nes_ppu2c02` 的 `g_chr_external` 例化**（背景取数；精灵侧由 `nes_sprite_chr_fetch` 承担），CHR 取数通路在 PPU 侧已接通，见下面两节各自的“未覆盖项”。

## 接口极性

| 信号 | 方向 | v0 合同 |
| --- | --- | --- |
| `reset` | in | 高有效异步复位。只复位控制寄存器和时序寄存器，不清 10 KiB 内部 RAM。 |
| `ce` | in | 高有效。每一次 `ce=1` 的时钟沿推进一个 PPU dot。 |
| `reg_cs` / `reg_we` | in | 寄存器访问在 `clk` 上升沿完成，不受 `ce` 门控。`reg_addr=0..7` 对应 `$2000..$2007`。 |
| `pixel_valid` | out | `scanline=0..239` 且 `dot=0..255` 时为高，包括背景显示关闭时。 |
| `pixel_x` / `pixel_y` | out | 可见像素坐标；不可见时固定为 0。 |
| `pixel_index` | out | 4 位 NES palette 索引，不是 RGB。背景关闭或左 8 像素裁剪且该 dot 没有不透明精灵时输出 palette 0。 |
| `frame_done` | out | `(261,340)` 之后的一个 `ce` 周期脉冲。 |
| `vblank` | out | 0-based 时序，在 `(241,1)` 整个 dot 为高，在 `(261,1)` 整个 dot 起为低，高电平窗口恰好 6820 dot。 |
| `nmi_o` | out | 高有效电平，与 `vblank` 共用同一时序点：`PPUCTRL[7]=1` 时在 `(241,1)` 置位，在 `(261,1)` 自动撤销，不需要读 `PPUSTATUS`；读 `PPUSTATUS` 仍会提前清除。CPU 侧可做上升沿检测。 |
| `dbg_v` / `dbg_t` / `dbg_x` / `dbg_w` | out | 滚动地址、fine X 和双写选择位。 |
| `dbg_sprite0_hit` / `dbg_sprite_overflow` | out | 与 `PPUSTATUS[5]` / `PPUSTATUS[6]` 同源的**已锁存**状态，组合直出，方便在不消费 `$2002` 的情况下观察。 |

## 时序模型

- 固定 NTSC 341 dot × 262 scanline，dot 计数 0..340。
- 可见区是 scanline 0–239、dot 0–255。
- dot/scanline 计数器是 0-based，`always @(posedge clk)` 在**当前 dot 结束时**结算，所以寄存器输出在结算后立即随计数器呈现新值。
- vblank 和 NMI 与渲染开关无关。置位条件是 `scanline==241 && dot==0`，因此 `vblank` 在 `(241,1)` 期间为高；清除条件是 `scanline==261 && dot==0`，因此 `vblank` 从 `(261,1)` 起为低。窗口是 `(241,1)..(241,340)`、scanline 242–260 全部 dot、`(261,0)`，共 `340 + 19*341 + 1 = 6820` dot。
- `nmi_o` 与 `vblank` 共用同一对时序点：在 `(241,0)` 判定时若 `PPUCTRL[7]=1` 则置位（电平自 `(241,1)` 起为高），在 `(261,0)` 判定时自动清零（电平自 `(261,1)` 起为低）。自动撤销是 v0 的明确简化：CPU 不读 `PPUSTATUS` 时 NMI 也会在下一个可见帧前释放，避免电平一直挂在高。
- v0 的 `PPUSTATUS` suppression 简化：读 `$2002` 只在时钟沿上清标志（`vblank`、`nmi_o`、`w`、以及精灵的 `sprite0_hit_reg`/`sprite_overflow_reg`），不实现 NESdev 的读取抑制窗口。`(241,0)` 上带 `ce` 的读会与同沿的置位更新冲突，此时沿上后段的读清除胜出，整帧 `vblank` 保持低；`(241,0)` 上不带 `ce` 的读看不到已置位的 `vblank`，返回值是 `$00` 且不抑制置位。
- 不实现奇数帧跳 dot。
- `v` 在背景显示打开时按 tile 边界执行 `inc_x`，在 dot 256 执行 `inc_x + inc_y`，dot 257 复制 `t` 的水平部分，pre-render 的 dot 280–304 复制 `t` 的垂直部分。

## 同一时钟沿的冲突合同

CPU 寄存器访问不受 `ce` 门控，所以同一个 `clk` 上升沿上可能既有寄存器访问又有 `ce` 渲染滚动更新，两者都要写 `v_addr`。v0 合同是寄存器访问优先：

- 渲染滚动更新（`inc_x`、`inc_x+inc_y`、dot 257 水平复制、pre-render dot 280–304 垂直复制）只在 `reg_cs=0` 的 `ce` 沿执行。
- 同一沿上 `reg_cs=1` 时，`PPUADDR` 第二写和 `PPUDATA` 读写得到的 `v` 不会被同沿的渲染更新覆盖；该 dot 的滚动更新被跳过而不是延后补做。
- 代价：一个在渲染滚动 dot 上完成的寄存器访问会推迟一个 tile 的取数边界。这是 v0 的明确简化，不是 PPU 真实行为。
- 真实 PPU 在该冲突点还会产生写入 glitch、可见区/不可见区副作用差异和 `inc_x`/`inc_y` 的部分生效，v0 一律不建模。

## 背景模型

v0 是功能级逐像素背景取数，不是逐 dot 预取流水线：

- `PPUCTRL[4]` 选择 CHR pattern table。
- `PPUMASK[3]` 控制背景，`PPUMASK[1]` 控制左 8 像素，`PPUMASK[0]` 灰度。
- 使用 `t` 的 coarse/fine scroll、nametable 位和独立 `x` fine scroll。
- 使用 nametable、attribute quadrant、两平面 CHR pattern 和 4 色 palette。
- vblank 后的 vblank/NMI 状态仍然工作。

nametable mirroring 由参数 `MIRROR_VERTICAL` 决定：

| 参数 | `$2000` / `$2400` / `$2800` / `$2C00` 物理映射 |
| --- | --- |
| `MIRROR_VERTICAL=0` | 常见 horizontal mirroring：`$2000=$2400`，`$2800=$2C00` |
| `MIRROR_VERTICAL=1` | 常见 vertical mirroring：`$2000=$2800`，`$2400=$2C00` |

palette 的 `$3F10/$3F14/$3F18/$3F1C` 镜像始终存在。

`$2007` 读 palette 地址时，返回值是当前 palette 项（经镜像映射），而 `read_buffer_reg` 填的是 palette 下面的 nametable 数据，即同一页 `$2F00-$2FFF`：`$3F00→$2F00`、`$3F10→$2F10`、`$3F18→$2F18`。因此 palette 读之后的第一次非 palette 读会回读到该下层 nametable 值。

## 精灵集成（顶层接线）

`nes_ppu2c02.v` 只做三件事，具体寻址、翻转、8-sprite 上限和溢出计数全部由 `nes_ppu_sprite.v` 承担。

### 1. 内部 RAM 摊平成模块总线

`u_sprite` 的 OAM 与 CHR 都是**输入端口**，PPU 侧用 generate 连续赋值把内部 RAM 摊平后送进去：

| 目标 | 布局 |
| --- | --- |
| `sprite_oam_bus[2047:0]` | 项 `si` 的 Y/tile/attr/X 在 `[si*32 +: 8]`、`+8`、`+16`、`+24`，即 `oam_ram[si*4 .. si*4+3]`。64 次迭代（`g_oam_flatten`）。 |
| `sprite_chr_slots[127:0]` | **不是**整片 CHR 的扁平总线。**8 次迭代、16 次读**（`g_sprite_chr_slots`）：slot `g` 的低平面在 `[g*16 + 0 +: 8]` = `chr_ram[s_pat_addr[g]]`，高平面在 `[g*16 + 8 +: 8]` = `chr_ram[s_pat_addr[g] + 13'd8]`，`s_pat_addr[g]` 取自 `nes_ppu_sprite` 新导出的 `pat_addr_cur_o[g*13 +: 13]`。 |

**（已按事实更新，`575e191`）**这一格原先是 `sprite_chr_bus[65535:0]`（字节 n 在 `[n*8 +: 8]`，即 `chr_ram[n]`），由一个 **8,192 次迭代**的 `g_chr_flatten` 组合拼成。那条路被删掉了：8,192 个常量索引的读口让 Quartus 直接拒收（`Error (10106): loop must terminate within 5000 iterations`），Verific 的 elaboration 器也在同一构造上崩（`read to RAM wasn't mapped to a specific read port`）。现在 `u_sprite` 收 `.chr_slots(sprite_chr_slots)`，并用 `.PER_SLOT_CHR(1'b1)` 选中单元内部 `g_chr_per_slot` 分支；`.chr(65536'd0)` 仍然传着，但那条 `g_chr_flat` 默认路径在 PPU 里**不再被读**。**交付的仍是同两个字节、同两个字节地址**（`s_pat_addr` 与 `s_pat_addr + 8`），所以渲染结果不变。逐条推导与实测数字见 [`docs/00-overview/risk-register.md`](../../docs/00-overview/risk-register.md) 第 10.4 节与 [`docs/modules/ppu-external-chr.md`](../../docs/modules/ppu-external-chr.md) 1.2 / 1.3 节。

`ctrl` 接 `control_reg`，`mask` 接 `mask_reg`，`scanline`/`dot` 直接接 PPU 计数器。`nes_ppu_sprite.v` 是纯组合模块（`clk`/`ce` 未被引用），所以这些连线不引入任何 dot 级流水或预取状态，背景取数通路和 vblank/NMI 时序完全不受影响。

### 2. `pixel_index` 混色规则

顶层把精灵模块的 `sprite_pixel`（`{attr[1:0], pat[1:0]}`）查成最终 palette 值，再用背景透明度和优先级位选一个：

1. 精灵不透明 = `PPUMASK[4]` 且 `pat != 0`；精灵 palette 项是 `$3F10 + sprite_pixel`（`pat != 0` 保证不会命中 `$3F10/$3F14/$3F18/$3F1C` 镜像）。
2. 背景**被显示** = `PPUMASK[3]` 且（`dot >= 8` 或 `PPUMASK[1]`）；背景**不透明** = 被显示且 `pat != 0`。
3. 背景不透明时，精灵不透明且优先级位为 0（`attr[5]=0`，精灵在前）就输出精灵色，否则输出背景色。
4. 背景透明时，精灵不透明就输出精灵色，否则输出 `bg_palette_value`（`pat==0` 时它就是 palette 0 的背板色）。
5. 背景没被显示时，精灵不透明就输出精灵色，否则输出 0——这是 v0 一直沿用的“未显示即 palette 0”策略。
6. 最后统一套 `PPUMASK[0]` 灰度（`& 4'h3`），`reset` 时仍然强制 0。

没有精灵覆盖时这条链逐位复现 v0 行为：背景被显示就输出 `bg_palette_value[3:0]`（含 `pat==0` 时的背板色），没被显示就输出 0。背景时序、vblank/NMI、`PPUDATA` 和 `$2000-$2007` 语义都没有改动；`test_solid_and_checker`、`test_attribute_quadrants`、`test_fine_scroll`、`test_rendering_off_vblank` 等既有断言的期望值一个字没改。

### 3. mask 集成与状态位

- 左 8 像素：精灵像素的左 8 裁剪由 `nes_ppu_sprite.v` 内部用 `PPUMASK[2]` 完成；背景左 8 裁剪是顶层的 `bg_shown`。两者独立，所以 `PPUMASK=0x1C`（显示精灵左 8、隐藏背景左 8）和 `PPUMASK=0x1A`（显示背景左 8、隐藏精灵左 8）都能得到正确画面。
- `sprite0_hit`：顶层只补一个全局门控 `PPUMASK[4]`，并把喂给模块的 `bg_pixel` 定义成**背景不透明标记**——`bg_opaque ? 4'hF : 4'h0`，其中 `bg_opaque` 已经含 `PPUMASK[3]` 和左 8 裁剪。这样命中条件在 x>=8 时是 `PPUMASK[3] && PPUMASK[4]`，在 x<8 时是 `PPUMASK[1] && PPUMASK[2] && PPUMASK[3] && PPUMASK[4]`，与硬件一致。用背景**颜色**而不是不透明度做判定是不行的：pattern 不为 0 但颜色恰好是 `$0F` 的背景像素在硬件上照样产生 hit。
- `sprite_overflow`：顶层用 `PPUMASK[4]` 门控（真实硬件的溢出评估也只在渲染打开时发生）。
- 两个标志都是**寄存器**：在 `ce` 沿上用当拍组合值置位（只置不清），`reset` 清零，读 `$2002` 清零，**不会**每帧自动清零。同一沿上既是渲染 dot 又读 `$2002` 时，读清除胜出，与 vblank 的“寄存器优先”合同一致。
- `PPUSTATUS` 读回值是 `{vblank, overflow, hit, 1'b0, 4'b0000}`：bit4 和 bit3:0 保持 v0 的未定义位策略（恒 0），v0 未定义位没有被 sprite 接线改变。

## 断言覆盖

`tb_nes_ppu2c02.v` 使用 `$fatal` 断言并打印关键状态，覆盖：

1. 复位值、`ce=0` 冻结、完整 341×262 计数、frame wrap。逐 dot 采样 `(241,1)..(261,0)` 窗口：断言 `vblank == ((scanline==241 && dot>=1) || (scanline>=242 && scanline<=260) || (scanline==261 && dot==0))`，一帧累计高电平 dot 数等于 6820，上升沿落在 `(241,1)`、下降沿落在 `(261,1)`，且 `PPUCTRL[7]=0` 时 `nmi_o` 全帧保持低。采样点取 posedge 结算后的稳定状态。
2. `PPUCTRL`、`PPUMASK`、`PPUSTATUS`、`OAMADDR`、`OAMDATA`、共享 `w` 的 `PPUSCROLL`/`PPUADDR`、`v/t/x/w` 可观察结果。
3. `PPUDATA` 写 CHR/nametable/palette、1 字节与 32 字节递增、缓冲读取、palette 镜像读、palette 读把 `$2F00/$2F10/$2F18` 下层 nametable 值填入缓冲并在随后的非 palette 读中回读、horizontal mirroring。
4. 同一沿冲突：渲染滚动 dot 上的 `PPUADDR` 第二写与 `PPUDATA` 读以寄存器结果为准，同沿的 `inc_x` 被跳过，下一个滚动 dot 恢复正常更新。
5. 纯色 tile 和 2×2 棋盘格 tile 的固定关键像素。
6. attribute 四象限 `TL/TR/BL/BR = $11/$12/$13/$00`，以及 fine X=3、fine Y=4 的 tile/row 边界像素。
7. 关闭背景和 sprite 时仍产生 vblank：`(241,1)` 为高、`(261,0)` 仍为高、`(261,1)` 起为低。
8. `PPUCTRL[7]` 打开后，vblank 事件在 `(241,1)` 产生高有效 `nmi_o`，读 `$2002` 返回 `$80` 并清除 `vblank`、`nmi_o` 和 `w`。
9. vblank 窗口边界的状态读：`(241,0)` 读 `$2002` 返回 `$00` 并抑制整帧 `vblank`，下一帧 `(241,1)` 恢复；`(241,1)` 读 `$2002` 返回 `$80` 并清除 `vblank`/`nmi_o`/`w`。
10. NMI 自动撤销：不读 `$2002` 时 `nmi_o` 在 `(241,1)` 置位、在 `(260,340)` 仍保持高、在 `(261,1)` 自动变低，且 `(261,340)` 与下一帧 `(0,0)` 都不会重新拉高。
11. 精灵像素与优先级：全部 OAM 都用 `$2003`/`$2004` 写入（`write_oam_entry` / `park_oam`，不靠层次赋值），一个 X=40 的精灵在 X=56 的“背景后”精灵之前、另一个 X=72 用 tile 3 + palette 1；逐点断言精灵 8 像素宽度、左右边界、上下边界、palette 索引和 `attr[5]` 优先级。再把 nametable 的 `(0,4)` 块换成透明 tile，复位后确认同一个“背景后”精灵在透明背景上**显示**、在不透明背景上**被盖住**。
12. `PPUMASK` 集成：同一个跨左 8 边界（X=4）的精灵在 `0x18/0x1E/0x14/0x10/0x1C/0x1A/0x08/0x00` 八种 mask 下逐点断言，并单独断言 `0x1F` 的灰度把混合结果 `& 4'h3`。
13. `PPUCTRL` 透传：`PPUCTRL[5]` 打开时 OAM tile `$02` 的精灵按 tile 对取数（tile 1 上半、tile 2 下半，16 行），`[5]=0` 时退化成 8x8；`PPUCTRL[3]` 切换到 pattern table 1 后同一个 tile 换成 table 1 的数据。
14. sprite 0 hit：先断言命中 dot 之前 `dbg_sprite0_hit=0` 且 `$2002=$00`，走完命中 dot 后 `dbg_sprite0_hit=1` 且 `$2002=$20`，连续两次读 `$2002` 都返回 `$00` 且 debug 同步归零；再分别用“背景 pattern 透明”、“`PPUMASK[3]=0`”、“`PPUMASK[1]=0`”三种情况确认 hit 被抑制，同时确认精灵像素在这些情况下照常输出。
15. 8-sprite 上限与 overflow：9 个精灵在同一行（8 个全透明 tile + 第 9 个不透明）时 `dbg_sprite_overflow=1`、`$2002=$40`、第 9 个的像素**不出现**；把第 8 个挪出范围后 8 个在范围内，overflow 清零且第 8 个精灵正常显示；`PPUMASK[4]=0` 时精灵和 overflow 一起消失。

## 运行

在仓库根目录执行，输出放在临时目录，不向仓库写文件：

```powershell
$tmp = Join-Path $env:TEMP 'op_fpga_emu'
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
& 'C:\iverilog\bin\iverilog.exe' -g2001 -s nes_ppu2c02 -o (Join-Path $tmp 'nes_ppu2c02_core.vvp') 'rtl\nes_core\ppu\nes_ppu2c02.v' 'rtl\nes_core\ppu\nes_ppu_sprite.v'
& 'C:\iverilog\bin\iverilog.exe' -g2012 -s tb_nes_ppu2c02 -o (Join-Path $tmp 'tb_nes_ppu2c02.vvp') 'rtl\nes_core\ppu\nes_ppu2c02.v' 'rtl\nes_core\ppu\nes_ppu_sprite.v' 'tb\ppu\tb_nes_ppu2c02.v'
& 'C:\iverilog\bin\vvp.exe' (Join-Path $tmp 'tb_nes_ppu2c02.vvp')
```

核心是 Verilog-2001 源码，可单独用 `-g2001` elaborate；`nes_ppu2c02.v` 依赖 `nes_ppu_sprite.v`，两条命令都必须带上它。testbench 使用 `$fatal`，因此 Icarus 入口使用 `-g2012`，与仓库现有 CPU testbench 相同。

`tools/sim_all.ps1` **这一侧不需要改**：`$ppuSources`（`:127`）已经是 `@($ppuSpriteRtl, $ppuRtl, $chrFetchUnitRtl, $spriteChrFetchRtl)`，**第一条就是 `rtl\nes_core\ppu\nes_ppu_sprite.v`**（`:81` 定义 `$ppuSpriteRtl`）。`ppu-core`（`:197`）、`ppu-integration`（`:224`）、`chr-feasibility-tb`（`:233`）、`ppu-ext-chr-tb`（`:260`）以及 `nes_system_v0`..`v6` 的源列表（`:140-146`）全部由它拼出，因此**这四个 PPU 目标与全部 `system-*` 目标都带着精灵源文件**；精灵单元自己另有 `ppu-sprite` 目标（`:201-209`，顶层 `tb_nes_ppu_sprite`）。**真正还没同步的是 ModelSim/Questa 侧的三个 `.do`**：`tb/ppu/run_ppu_tb.do:2` 与 `tb/system/run_system_tb.do:2` / `tb/system/run_system_nmi_tb.do:2` 的 `vlog` 行只列 `nes_ppu2c02.v`，直接跑它们会得到 `Unknown module type: nes_ppu_sprite`（外加 `nes_chr_fetch_unit` / `nes_sprite_chr_fetch`）。补上 `rtl/nes_core/ppu/nes_ppu_sprite.v` 之后 `tb_nes_system_v0` 和 `tb_nes_system_v0_nmi` 都能通过（已手工验证），所以这是纯 source-list 问题，不是行为回归。

逐 dot 全帧扫描（`test_reset_and_frame`）会跑满 89342 个 dot，而 `nes_ppu_sprite.v` 是纯组合模块、每个 dot 都要重算 64 项范围和 8 个 slot，因此仿真时间约 11.1 ms、vvp 实测约 50 s（接入精灵前是 6.2 ms / 2.4 s）。下面是本版本的完整期望输出，逐行对应一个 test task：

```text
TIMING frame=341x262 vblank=241:1..261:0 high_dots=6820 nmi_disabled
REGISTER ctrl/status/oam/scroll/address PASS
PPUDATA chr/name/palette buffer and mirroring PASS
REGISTER over render scroll priority PASS
BACKGROUND solid tile x=0/7/8/255 PASS
BACKGROUND checker tile PASS
BACKGROUND attribute quadrants TL/TR/BL/BR=11/12/13/00 PASS
BACKGROUND fine x=3 y=4 boundaries PASS
VBLANK rendering-off PASS
NMI enable/event/status-clear PASS
VBLANK 241:0 PPUSTATUS read returns 0 and suppresses PASS
VBLANK 241:1 PPUSTATUS read returns 0x80 and clears PASS
NMI auto-release at 261:1 without a status read PASS
SPRITE integration OAM writes, palette and priority over opaque bg PASS
SPRITE integration behind-bg sprite covered by opaque bg PASS
SPRITE integration PPUMASK=0x18 hides both left-8 halves PASS
SPRITE integration PPUMASK=0x1E shows both left-8 halves PASS
SPRITE integration PPUMASK=0x14 sprites only with left-8 PASS
SPRITE integration PPUMASK=0x10 sprites only, left-8 hidden PASS
SPRITE integration PPUMASK=0x1C sprite left-8 over hidden bg left-8 PASS
SPRITE integration PPUMASK=0x1A bg left-8 without sprite left-8 PASS
SPRITE integration PPUMASK=0x08 background only hides sprites PASS
SPRITE integration PPUMASK=0x00 output stays palette 0 PASS
SPRITE integration PPUMASK grayscale ands mixed pixel to 2 bits PASS
SPRITE integration PPUCTRL[5] 8x16 tile pair PASS
SPRITE integration PPUCTRL[5]=0 collapses to 8x8 PASS
SPRITE integration PPUCTRL[3] selects sprite pattern table PASS
SPRITE integration sprite0 hit sets and clears PPUSTATUS[5] PASS
SPRITE integration sprite0 hit blocked by transparent bg PASS
SPRITE integration sprite0 hit blocked by PPUMASK[3]=0 PASS
SPRITE integration sprite0 hit blocked by PPUMASK[1]=0 PASS
SPRITE integration 9th sprite dropped and PPUSTATUS[6] set PASS
SPRITE integration 8th sprite renders without overflow PASS
SPRITE integration PPUMASK[4]=0 hides sprites and overflow PASS
PASS nes_ppu2c02 v0
```

任何 `$fatal` 命中会让 vvp 以非零退出码结束，并把失败 dot 或寄存器值打印到 stdout；`tb_nes_ppu2c02.v` 顶部还有 `global timeout` 兜底断言。

作为置信度检查，对 RTL 的临时副本做了 15 处定向变异（忽略优先级位、去掉 `PPUMASK[4]` 精灵门控、去掉 hit/overflow 锁存、交换 `PPUSTATUS[5]/[6]`、`bg_pixel` 标记忽略 mask、overflow 去掉 `PPUMASK[4]` 门控、去掉读 `$2002` 清标志、去掉 reset 清标志、debug 口改直连组合值、精灵 palette 基数写成 0、背景透明判定写成“被显示”、把精灵从混色里摘掉），**15 处全部被 testbench 立即抓到**。RTL 本身在检查后已还原。

`run_ppu_tb.do` 提供 ModelSim/Questa 的同一条编译和运行命令，**当前还没有加上 `nes_ppu_sprite.v`**，也需要同步。当前仓库没有 ModelSim、Quartus 或 EP4CE10 上板证据；该脚本未被本版本验证。

## 精灵 testbench

`tb_nes_ppu_sprite.v` 是 `rtl/nes_core/ppu/nes_ppu_sprite.v` 的自检 testbench。和上面的 `tb_nes_ppu2c02.v` 一样，它不下载 ROM、不读外部文件：模块的 OAM 和 CHR 是**输入端口**而不是内部 RAM，所以 TB 用两块显式声明的总线寄存器（`oam_bus` / `chr_bus`）加 `assign` 连续赋值驱动，`set_sprite` / `fill_tile` / `fill_tile_row` 三个 task 按字节偏移写这两块总线，**没有使用任何未声明的隐式内存**。

被测模块是**纯组合**的（`clk` 和 `ce` 在 RTL 里没有被任何逻辑引用，只有 `reset` 参与 `frame_active`），所以 TB 的 `probe(line, dot)` task 只是改 `scanline`/`dot` 然后 `#1` 等待组合逻辑稳定，不推进时钟。`test_reset_and_clock_independence` 显式翻转 `ce` 和 `clk` 若干拍来证明输出不随它们变化。

## 精灵模块接口极性

| 信号 | 方向 | 合同 |
| --- | --- | --- |
| `clk` | in | **未使用。** 模块无寄存器。 |
| `ce` | in | **未使用。** 时序由 `scanline`/`dot` 外部给定。 |
| `reset` | in | 高有效。`frame_active = !reset && (scanline < 240)`，因此置位时四个输出全 0。 |
| `oam` | in | 2048 位扁平 primary OAM。**项 `si` 的 Y/tile/attr/X 分别在 `oam[si*32 +: 8]`、`+8`、`+16`、`+24`**。 |
| `chr` | in | 65536 位扁平 CHR，字节 n 在 `chr[n*8 +: 8]`。table0 = `$0000-$0FFF`，table1 = `$1000-$1FFF`。 |
| `ctrl` | in | PPUCTRL。**只用 bit5**（1 = 8×16）和 **bit3**（8×8 的 pattern table）。 |
| `mask` | in | PPUMASK。**只用 bit2**（1 = 显示左 8 像素的精灵）。bit4 不参与门控。 |
| `scanline` | in | `>= 240` 视为不可见。 |
| `dot` | in | `>= 256` 视为不可见；取数只用 `dot[7:0]`。 |
| `bg_pixel` | in | 4 位背景 palette 索引（0 = 透明）。**只影响 `sprite0_hit`。** |
| `sprite_pixel` | out | `{attr[1:0], pat[1:0]}`：高 2 位是精灵 palette 组号，低 2 位是 pattern 值。**不是** `$3Fxx` 索引，不是 RGB。 |
| `sprite_priority` | out | 4 位**全等于**胜出 slot 的 `attr[5]`（在背景后面 = `$F`，否则 `$0`）。 |
| `sprite0_hit` | out | `pixel_active && slot_opaque[0] && bg_pixel != 0`。 |
| `sprite_overflow` | out | `frame_active && range_count > 8`。**不受 `dot` 和 `PPUMASK` 影响。** |

行为与结构的完整教学说明在 `docs/modules/ppu-sprites.md`。

两个模块现在是接线的：`nes_ppu2c02.v` 里的 `u_sprite` 实例负责把 OAM/CHR 摊平、喂 `PPUCTRL`/`PPUMASK`/计数器、查 palette、混色并锁存状态位（见上文“精灵集成”）。**本节下面的 table 描述的是 `nes_ppu_sprite.v` 自己的端口合同**，那些顶层接线的细节不重复在这里。

## 精灵断言覆盖

`tb_nes_ppu_sprite.v` 使用 `$fatal` 断言并逐行打印 PASS，覆盖：

1. **RESET / CLOCK 门控**：9 个精灵在范围内（overflow=1）时 `reset=1` 让四个输出全为 0；`reset=0` 恢复；`ce` 高低各跑 4 个 `clk` 输出不变；`bg_pixel` 只改 `sprite0_hit` 不改 `sprite_pixel`/`sprite_priority`。
2. **8×8 行/列寻址与两个 plane**：0x80 平面 → pattern 1、0x00 高平面 → pattern 2、双平面 → pattern 3；逐行核对 8 个行号的 CHR 行地址；`dot = X-1` / `X+8` 透明；`scanline = Y-1` / `Y+8` 不在范围。
3. **8×8 pattern table**：table0 放 tile 2、table1 放 tile 5，两个精灵同一行；`PPUCTRL[3]` 切换时只有对应的精灵亮。
4. **8×16 tile 对与表选择**：tile 号 bit0 选表（`PPUCTRL[3]` 被忽略）、`row[3]` 选上/下半 tile、`ctrl[5]=0` 时同一 OAM 项退化成从 table0 取数的 8×8、16 行之外不显示。
5. **h/v/both flip**：单 bit 位置随翻转在 `xoffset 0 ↔ 7` 之间移动；`0x81`（bit7+bit0）这种双端图案在不翻转/翻转下分别落在精灵首列/末列；vflip 让亮行从 row0 移到 row7。
6. **palette 与优先级输出**：`attr[1:0]` 0..3 得到 `{palette, pattern}` = 1/5/9/13；`attr[5]` 使 `sprite_priority = $F`；优先级位**不**阻止 sprite 0 hit。
7. **left-8 clip（`PPUMASK[2]`）**：`mask[2]=1` 时 dot 0..7 正常；`mask[2]=0` 时 dot 0..7 的 `sprite_pixel`/`sprite_priority`/`sprite0_hit` 全为 0，dot 8 恢复；被裁剪的 `X=4` 跨边界精灵在 dot 4..7 隐藏、dot 8..11 可见。
8. **8-sprite 上限与 OAM 次序**：6 个精灵在 `X=32` 重叠且 palette 不同 → 最小的在范围 OAM 下标赢；8 个在范围时第 8 个（slot 7）仍渲染；9 个在范围时第 9 个被丢弃（不透明像素也不出现）且 overflow 置位；7 个在范围时 overflow 清零；`PPUMASK[4]=0` 时精灵仍输出且 overflow 仍置位。
9. **sprite 0 hit**：背景透明不置位、背景非透明置位、透明像素不置位、优先级位不阻止置位、`dot = X-1` 与 `scanline = Y-1` 不置位、`dot >= 256` 不置位；以及**`OAM 项 0 不在范围时 slot 0 被下一个在范围精灵顶替并可以置 hit`**这一行为级差异。
10. **dot≥256 / vblank / reset 屏蔽**：dot 256/257/340/511 清像素但**保留 overflow**；scanline 239 正常、240/241/255/261/511 全清；`reset` 屏蔽一个本该有效的像素并在释放后恢复。
11. **OAM 项 63 与 Y 边界**：只有 OAM 项 63 在范围时能渲染、且被项 0 压过；`Y=0` 覆盖 scanline 0..7；`Y=255` 不回绕到 scanline 0 且在可见区永不显示；`Y=232` 填满最后一条可见行；8×16 `Y=224` 覆盖 224..239 而 `Y=240` 完全落在可见区之外。
12. **输入隔离**：10 组无关 `PPUCTRL` 位、10 组无关 `PPUMASK` 值（**包括 `PPUMASK[4]=0`**）、4 组 `bg_pixel`，逐一确认只影响合同规定的那一个输出。

## 精灵 testbench 运行

在仓库根目录执行，输出放在临时目录，不向仓库写文件：

```powershell
$tmp = Join-Path $env:TEMP 'op_fpga_emu'
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
& 'C:\iverilog\bin\iverilog.exe' -g2001 -Wall -s nes_ppu_sprite -o (Join-Path $tmp 'nes_ppu_sprite_core.vvp') 'rtl\nes_core\ppu\nes_ppu_sprite.v'
& 'C:\iverilog\bin\iverilog.exe' -g2012 -s tb_nes_ppu_sprite -o (Join-Path $tmp 'tb_nes_ppu_sprite.vvp') 'rtl\nes_core\ppu\nes_ppu_sprite.v' 'tb\ppu\tb_nes_ppu_sprite.v'
& 'C:\iverilog\bin\vvp.exe' (Join-Path $tmp 'tb_nes_ppu_sprite.vvp')
```

核心是纯 Verilog-2001，可以单独用 `-g2001 -Wall` elaborate。Icarus 会报 5 条 `@* is sensitive to all 8 words in array 'slot_opaque'/'slot_attr'/'slot_pat'` 的提示性 warning（来自 RTL 里 `always @*` 读数组），不影响仿真结果，本任务不修改 RTL。testbench 语法本身是 Verilog-2001（`task`/`input`/`integer`/`assign`），与仓库其他 testbench 一致用 `-g2012` 入口以便使用 `$fatal`（Icarus 在 `-g2001` 下也能接受 `$fatal`，但入口统一更好）。

下面是本版本的完整期望输出，逐行对应一个 test task；vvp 退出码 0，仿真时间 340 ns，实测运行约 0.1 s：

```text
SPRITE reset gating and no clock/ce dependence PASS
SPRITE 8x8 row/column addressing and both pattern planes PASS
SPRITE 8x8 pattern table selection via PPUCTRL[3] PASS
SPRITE 8x16 tile pair, table from tile bit0, PPUCTRL[3] ignored PASS
SPRITE horizontal, vertical and combined flip PASS
SPRITE palette index and priority output PASS
SPRITE left-8 clipping via PPUMASK[2] PASS
SPRITE 8-sprite-per-line limit, OAM order and overflow PASS
SPRITE sprite 0 hit conditions and slot substitution PASS
SPRITE dot>=256, vblank and reset masking PASS
SPRITE OAM entry 63, Y wrap boundaries and 8x16 bottom edge PASS
SPRITE PPUCTRL/PPUMASK/bg_pixel isolation PASS
PASS nes_ppu_sprite
```

任何 `$fatal` 命中会让 vvp 以非零退出码结束，并把失败的检查名、实际值、期望值和当前 `scanline:dot` 打印到 stdout；`tb_nes_ppu_sprite.v` 顶部还有 `global timeout`（200 µs 仿真时间）兜底断言。

作为置信度检查，对 RTL 的临时副本做了 20 处定向变异（8×16 表选择、8×16 tile 对、hflip、vflip、优先级、palette 输出、left-8 clip、overflow 阈值、8-slot 上限、hit 的背景条件、slot 优先次序、dot 门控、可见区门控、reset 门控、行高选择、CHR 高平面、X 窗口宽度、OAM 范围比较、`PPUMASK[4]` 门控、输出清零），**19 处被 testbench 立即抓到**；剩下 1 处只是脚本里的匹配串因换行符没替换成功，不是覆盖空洞。RTL 本身没有被修改。

## 精灵 testbench 未覆盖项

这些是**当前模块的功能级组合模型**没有实现、因此 testbench 也不该去测的东西。列出它们是为了避免把"没测"误读成"测过且通过"。

- **secondary OAM 的时序**：32 B 次 OAM、dot 1..64 的清空、dot 65..256 的评估窗口、dot 257..320 的 fetch 窗口、8 组 X 倒计数器和 pattern 移位寄存器。本模块每个 dot 重新组合算一遍整条通路，所以这些都不存在。
- **评估状态机**：奇数 dot 读主 OAM / 偶数 dot 写次 OAM 的锁存-写回时序；`m`/`n`/`o`/`p` 四个影子寄存器的推进。
- **溢出 glitch**：真实硬件次 OAM 写满后"写变成从 `OAM_cache[0]` 读"造成的鬼影精灵（Blargg 溢出测试测的就是这个），以及 `m` 递增 bug 导致的"第 9 个之后连续误置 overflow"。本模块的 overflow 是纯计数语义。
- **`OAMADDR` 相关行为**：`$2003` 非零时精灵 0 判定退化、评估起点偏移、$2002 读精灵 0 hit 时的 8 像素抑制窗口。
- **OAM DMA（`$4014`）** 和 CPU 停机，不在这个模块里；由 `rtl/nes_core/ppu/nes_oam_dma.v` 单独实现，见下文 OAM DMA 章节。
- **dot 255 的 sprite 0 hit 抑制**：真实硬件在 x=255 不产生 hit，本模块照常置位（已被 testbench 显式钉住）。
- **扫描线 240..255 的精灵**：真实硬件上 `Y=232..255` 的精灵在第 240..255 行仍可显示（8×16 模式下 `Y=240` 会跨进可见区），本模块的 `frame_active = scanline < 240` 直接把它们屏蔽。
- **`PPUMASK[4]`（显示精灵）门控**：本模块不实现，精灵在 `mask=0` 时照样输出（已被 testbench 显式钉住）。`PPUMASK[0]`（灰度）同理，模块输出的是 palette 组号而不是最终颜色。
- **背景/精灵混色**：`sprite_pixel` 和 `sprite_priority` 是交给上层的原始量，本模块不输出最终 palette RAM 索引。"背景透明时精灵一定显示"这一支不在这里。**顶层 `nes_ppu2c02.v` 已经完成混色并由 `tb_nes_ppu2c02.v` 的 `test_sprite_pixels_and_priority` 断言，见上文"精灵集成"。**
- **每一帧的逐 dot 扫描**：因为模块是纯组合，testbench 只在关键 (scanline, dot) 点上探测，没有跑满 341×262 的全帧逐点比对。**与 `nes_ppu2c02.v` 的联合断言已经补上**（`test_sprite_pixels_and_priority` / `test_sprite_mask_gating` / `test_sprite_ctrl_passthrough` / `test_sprite0_status` / `test_sprite_overflow_status`），但仍然只钉关键像素，没有整屏逐点比对。
- **多精灵相互遮挡的全组合**：只验证了"6 个精灵在同一 X 重叠取最小 OAM 下标"这一种遮挡形态，没有穷举 8 个 slot 的所有不透明组合。
- **CHR 越界与 `chr` 总线宽度**：CHR 按 8 KiB 全量给满，8×8 的 `s_pat_addr` 必然落在 0..0x7F7、8×16 落在 0..0x1077，没有测非法 `tile`/`ctrl` 组合下的越界读。**这条限制仍然有效**（本 TB 走 `PER_SLOT_CHR = 0` 的 `g_chr_flat`，真的在读 `chr`）；TB 侧摊平也只给了低 8 KiB（8192 字节）。**注意别把它读成 PPU 里那个 `g_chr_flatten`**——那个已经在 `575e191` 删掉了（见上面第 1 节），现在只存在于本 TB 这条默认路径上。
- **`OAM` 总线宽度**：`oam` 固定 2048 位、64 项全部可寻址，已测项 0 和项 63，但没有测项 32..62 的逐项扫描。
- **PAL / NTSC 差异、奇数帧跳 dot**：与精灵无关，未实现也不测。
- ModelSim/Questa 的 `run_ppu_tb.do:2` **没有**精灵源文件（`tb/system/run_system_tb.do:2` / `tb/system/run_system_nmi_tb.do:2` 同样没有），跑它们会 `Unknown module type: nes_ppu_sprite`。**`tools/sim_all.ps1` 这一侧已经没有这个问题**：`$ppuSources`（`:127`）第一条就是 `rtl\nes_core\ppu\nes_ppu_sprite.v`，`ppu-core` / `ppu-integration` / `chr-feasibility-tb` / `ppu-ext-chr-tb` / `system-*` 的源列表都由它拼出，精灵单元自己另有 `ppu-sprite` 目标（`:201-209`，顶层 `tb_nes_ppu_sprite`）。**所以要补的只有那三个 `.do`，门禁脚本本身不用动。**

## OAM DMA testbench

`tb_nes_oam_dma.v` 是 `rtl/nes_core/ppu/nes_oam_dma.v` 的自检 testbench。和上面两个 testbench 一样，它不下载 ROM、不读外部文件：TB 自己提供 64 KiB 的源内存、两个 256 B 的 OAM 影子模型和一个可配置 ack 延迟的读总线模型。

和精灵 testbench 最大的不同是它**实例化两份 `nes_oam_dma`**：`dut` 用 `OAMADDR_WRITE=1'b0`（`ppu_reg_addr` 恒为 `$2004`），`dut_addr` 用 `OAMADDR_WRITE=1'b1`（align 阶段先发一次 `$2003`）。两份实例共享同一组输入、同一个读总线模型和同一份源内存，但各自有一份 OAM 影子模型。每一笔事务都逐拍断言两份实例的 `cpu_read_req` / `cpu_read_addr` / `busy` / `done` / `cycle_count` 完全相同，只有 `$2004` 写一致、且 `dut_addr` 恰好多一次 `$2003` 写；最后逐字节比对两份 OAM 影子必须一致。**`$2003` 写序列是纯冗余的**这一点因此被钉死，同时两个接法都被覆盖。

TB 还维护一个 `parity_shadow`，行为和 RTL 里的 `parity_q` 完全一致（异步复位清零、每拍翻转）。这不是层次引用，是一个独立的 1 位模型；它让 `wait_align(1)` / `wait_align(2)` 能确定性地把 `start` 放到想要的 CPU 周期奇偶上，因此 **513 和 514 两条路径都被确定性地测到**，而不是靠碰运气。

读总线模型的形状和 `nes_apu_dmc.v` 的 DMC 取样模型一致：内存是组合读的（`cpu_rdata` 跟随 `cpu_read_addr`），**只有 ack 可以延迟**。这有一个有用的副作用——如果 DUT 在等待期间动了 `cpu_read_addr`，数据就会错，所以"等待期间输出稳定"是被数据完整性检查**功能性**验证的，不只是波形比对。

### OAM DMA 模块接口极性

| 信号 | 方向 | 合同 |
| --- | --- | --- |
| `clk` | in | **CPU 时钟**。一拍 = 一个 CPU cycle。模块假定外部已经完成 CPU : PPU = 1 : 3 的分频。 |
| `reset` | in | 高有效**异步**复位。清除 `busy` / `cpu_hold` / `done` / `cycle_count` / 全部影子寄存器。 |
| `start` | in | 1 拍脉冲。采样沿锁存 `src_page` 和 `oam_addr` 并开始事务。**`busy` 期间被忽略**（唯一的中止手段是 `reset`）。保持多拍会在上一次 `done` 之后立刻开始新事务。 |
| `src_page` | in | `$4014` 的写入值，只在 `start` 采样沿被锁存成 `page_q`。 |
| `oam_addr` | in | PPU 的 `OAMADDR` 当前值（系统层从 PPU 侧取回），同样只在 `start` 采样沿被锁存成 `oam_base_q`。 |
| `cpu_read_ack` | in | 读授权。**可以延迟任意拍**，可以和 `cpu_read_req` 同拍（零等待）。只在 `cpu_read_req` 为高时被采样。 |
| `cpu_rdata` | in | 读回来的字节，约定与 `cpu_read_ack` 同拍有效。 |
| `cpu_hold` | out | **电平**，`busy` 的别名。从 `start` 后第一拍到第 256 次 `$2004` 写（**含 `done` 拍**）一直为高，`done` 之后**一拍**释放。 |
| `cpu_read_addr` | out | 16 位 CPU 读地址，事务期间从 `{src_page, 8'h00}` 单调递增到 `{src_page, 8'hFF}`。**只在 ack 时才 `+1`**，因此等待期间绝对稳定。 |
| `cpu_read_req` | out | **电平**请求，一直保持到 `cpu_read_ack` 出现（宽度 = 1 + ack 延迟拍数）。`ST_ALIGN` / `ST_WRITE` 期间为 0。 |
| `ppu_reg_cs` | out | PPU 寄存器访问选通。`ST_WRITE` 期间为高（1 拍脉冲）；`OAMADDR_WRITE=1` 时 align 阶段的**最后一拍**也高一次（`$2003`）。与 `cpu_read_req` **永不同拍**。 |
| `ppu_reg_we` | out | 恒等于 `ppu_reg_cs`（本模块只发写）。 |
| `ppu_reg_addr` | out | `3'd4`（`$2004`）或 `3'd3`（`$2003`）。`OAMADDR_WRITE=0` 时恒为 `3'd4`。 |
| `ppu_reg_dout` | out | 写数据。`$2004` 时是 ack 拍锁存的字节，`$2003` 时是 `oam_base_q`，其他状态为 `8'h00`。 |
| `busy` | out | `state != IDLE`。 |
| `done` | out | **1 拍脉冲**，与第 256 次 `$2004` 写同拍。 |
| `cycle_count` | out | 从 `start` 起数的**已完成的停机拍数**，`busy` 期间逐拍加一；`done` 之后保持终值。零等待下终值是 **513（偶数对齐）或 514（奇数对齐）**；ack 每延迟一拍就多一拍。 |
| `dbg_page` / `dbg_oam_addr` / `dbg_index` | out | 锁存后的页、当前 OAM 写地址（255 -> 0 回绕）、字节序号 0..255。 |
| `dbg_align_left` | out | align 倒计时 1 或 2。**事务第一拍的读数就是 align 拍数**，testbench 用它确认 513/514 走对了分支。 |
| `dbg_addr_wr` | out | 当前拍是否在发 `$2003` 写。 |

### 513 / 514 状态机

四拍循环的账：`1 (dummy) + 256 x (read + write) = 513`；`start` 采样沿若 `parity_q` 为 1（奇数 CPU 周期）则 align 阶段多一拍，得到 `514`。逐拍合同：

| 拍 | 偶数对齐 | 奇数对齐 |
| --- | --- | --- |
| 1 | `ST_ALIGN`（`dut_addr` 在此发 `$2003`） | `ST_ALIGN`（无 PPU 访问） |
| 2 | `ST_READ` #0 | `ST_ALIGN`（`dut_addr` 发 `$2003`） |
| 3 | `ST_WRITE` #0 | `ST_READ` #0 |
| 2+2k / 3+2k | `ST_READ` #k / `ST_WRITE` #k | 3+2k / 4+2k |
| 513 | `ST_WRITE` #255，**`done=1`**，`cycle_count=513` | — |
| 514 | 空闲，`cycle_count` 保持 513 | `ST_WRITE` #255，**`done=1`**，`cycle_count=514` |

教学说明（软件模拟器的 DMA 调度 / 内存读取回调 vs 硬件 DMA 状态机 / 总线仲裁、与精灵模块的边界）在 `docs/modules/oam-dma.md`。

### OAM DMA 断言覆盖

`tb_nes_oam_dma.v` 使用 `$fatal` 断言并逐行打印 PASS，覆盖：

1. **RESET / IDLE**：复位后 `busy`/`cpu_hold`/`done`/`cpu_read_req`/`ppu_reg_cs`/`ppu_reg_we` 全 0，`cycle_count`/`dbg_index`/`dbg_oam_addr`/`dbg_addr_wr` 全 0；复位保持期间和释放后 8 拍空闲期内这些值不变，`cpu_read_addr` 停在 `0000`、`ppu_reg_dout` 停在 `00`。
2. **256 字节顺序 + page 地址**：`$02/$20/$7F/$80/$FF` 五个源页 × 偶数/奇数对齐共 8 次事务；逐拍记录 256 次 ack 时的 `cpu_read_addr`（必须严格等于 `{page,0}..{page,255}`）、256 次 `$2004` 的 `ppu_reg_dout`（必须等于源页同偏移字节）、以及每次写对应的 OAM 地址；**OAM 位置直方图要求 256 个位置各被写恰好 1 次**。
3. **OAMADDR 非零 + 255 -> 0 回绕**：`$30`（跨 `FF -> 00`）、`$F8`（8 字节后回绕）、`$FF`（1 字节后回绕）、`$01` 四种起点；`done` 那一拍的 `dbg_oam_addr` 必须是 `(base+255) & 255`；最终 256 字节 OAM 内容与源页逐字节相同。
4. **dummy / alignment**：`start` 后第一拍的 `dbg_align_left` 必须等于期望的 1 或 2；该拍 `busy=1`/`cpu_hold=1`/`done=0`/`cpu_read_req=0`/`cycle_count=1`/`dbg_index=0`/`dbg_page=src_page`/`dbg_oam_addr=oam_addr`/`cpu_read_addr={page,0}`；`OAMADDR_WRITE=0` 的实例该拍**不得**有任何 PPU 写；`OAMADDR_WRITE=1` 的实例在 align=1 时该拍发 `$2003`、align=2 时**第二拍**才发（第一拍发就是早了一拍，直接判死）。整笔事务统计"既不读也不写"的拍数必须恰好等于 align 拍数、读拍数必须等于 `256 + 256 x ack_delay`、写拍数必须恰好 256。
5. **ack 延迟**：`ack_delay` = 1 / 2 / 3 时数据仍完全正确，`cycle_count` 分别为 `513+256` / `514+512` / `513+768`，dummy 拍数**不受**延迟影响。
6. **等待期间的输出稳定**：单独一个 testbench 段用 `ack_delay=4` 逐拍检查 4 个等待拍内 `cpu_read_req` 恒 1、`cpu_read_addr` 恒定、`ppu_reg_cs` 恒 0、`done` 恒 0、`cpu_hold` 恒 1、`cycle_count` 逐拍 +1、ack **不早到也不晚到**；ack 那一拍 `cpu_read_addr` 仍不得前移、`dbg_index` 仍是 0；下一拍是 `$2004` 写且 `ppu_reg_dout` 等于第一个源字节、`cpu_read_addr` 已前移到 `{page,1}`。此外全局监视器对每一笔事务统计"等待拍内输出发生变化"和"PPU 写超过 1 拍"的次数，必须为 0；还断言 `cpu_read_req` 与 `ppu_reg_cs` 永不同拍。
7. **busy / done**：`done` 恰好 1 拍且与第 256 次 `$2004` 写（`dbg_index=FF`、`ppu_reg_addr=4`、`ppu_reg_cs=1`）同拍，该拍 `cpu_read_req=0`；`done` 之后一拍全部输出归零；`busy` 期间 `cycle_count` 逐拍等于已过去的 busy 拍数，事务结束后等于总 busy 拍数。
8. **hold**：`cpu_hold` 与 `busy` 在**每一拍**都相等（逐拍比较，跨全部事务），停机拍数与 `cycle_count` 终值一致（513 / 514 / 513+延迟）；`done` 那一拍 `cpu_hold` 仍为高。
9. **busy 期间 `start` 被忽略**：传输进行到第 40 拍时再拉一次 `start`，`busy` 不掉、`cycle_count` 不变、数据不受影响。
10. **reset 中止**：传输第 30 拍拉 `reset`，所有输出立即归零；之后新事务照常完成并通过全部数据检查。
11. **连续事务**：`$0A` / `$0B` / `$0C` 背靠背三笔，`cycle_count` 每次重新从 1 开始计数。
12. **两种 `$2003` 接法等价**：`OAMADDR_WRITE=0` 的实例**一次 `$2003` 都不发**（`ppu_reg_addr` 恒 `3'd4`），`=1` 的实例**恰好发一次**且值等于 `oam_addr`；两者的读请求/地址/时序逐拍相同，256 字节 OAM 内容逐字节相同。

### OAM DMA testbench 运行

在仓库根目录执行，输出放在临时目录，不向仓库写文件：

```powershell
$tmp = Join-Path $env:TEMP 'op_fpga_emu'
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
& 'C:\iverilog\bin\iverilog.exe' -g2001 -Wall -s nes_oam_dma -o (Join-Path $tmp 'nes_oam_dma_core.vvp') 'rtl\nes_core\ppu\nes_oam_dma.v'
& 'C:\iverilog\bin\iverilog.exe' -g2012 -s tb_nes_oam_dma -o (Join-Path $tmp 'tb_nes_oam_dma.vvp') 'rtl\nes_core\ppu\nes_oam_dma.v' 'tb\ppu\tb_nes_oam_dma.v'
& 'C:\iverilog\bin\vvp.exe' (Join-Path $tmp 'tb_nes_oam_dma.vvp')
```

核心是 Verilog-2001 源码，可以单独用 `-g2001 -Wall` elaborate（本版本**零 warning**）。testbench 使用 `$fatal`，因此 Icarus 入口使用 `-g2012`，与仓库现有 PPU/APU testbench 相同。

下面是本版本的完整期望输出，逐行对应一个 test task；vvp 退出码 0，仿真时间 126.47 us，实测运行约 0.17 s：

```text
OAMDMA reset values and idle outputs PASS
OAMDMA 256 byte order and source page addressing PASS
OAMDMA non-zero OAMADDR start and 255 to 0 wraparound PASS
OAMDMA delayed read ack keeps the transfer correct PASS
OAMDMA four-cycle ack wait holds request, address and data stable PASS
OAMDMA start pulse during busy is ignored PASS
OAMDMA reset aborts a transfer and the next transfer still works PASS
OAMDMA consecutive transfers restart the cycle counter PASS
PASS nes_oam_dma
```

任何 `$fatal` 命中会让 vvp 以非零退出码结束，并把检查名、实际值和期望值打印到 stdout（行号可用）；`tb_nes_oam_dma.v` 顶部还有 `global timeout`（2000 us 仿真时间）兜底断言。

作为置信度检查，对 RTL 的**临时副本**（仓库里的 RTL 未被修改）做了 22 处定向变异：OAMADDR 回绕（3 种）、`cycle_count` 末拍加一（回退到有 bug 的版本）、读地址不前进、`$2003` 写提前一个拍 / 整个消失、`align_left` 恒 1、`done` 每拍都高、`cpu_hold` 提前释放、只写 255 字节、读数据被移位、写数据被移位、每字节后多插一个 align 拍、`ppu_reg_we` 在 `$2003` 写上为低、`cpu_read_req` 周期性丢失、起始 `oam_addr` 未锁存、起始 `page` 未锁存、`busy` 期间接受 `start`、ack 被忽略、`busy` 事务中变低、`cycle_count` 起点为 0，**21 处被 testbench 立即抓到**；剩下 1 处是把 `(oam_cur_q == 8'hFF) ? 8'h00 : (oam_cur_q + 8'd1)` 简化成 `oam_cur_q + 8'd1`——因为 `oam_cur_q` 是 8 位寄存器，加法本身就会截断回绕，所以这是**等价变异**而不是覆盖空洞。

### OAM DMA testbench 未覆盖项

- **`ack_delay` 只测到 3，单独一段测到 4**：TB 的 `ack_delay` 是 3 位、`wait_cnt` 饱和于 7，所以最大可表达 `ack_delay=7`；7 及以上没有测。
- **没有用真实的 `nes_cpu_bus` 驱动**：读总线是 TB 里手写的组合内存 + 计数器，`nes_cpu_bus` 的 `wait_need` / `bus_hold` / `owner_ack` 交互没有端到端验证。
- **没有和 `nes_ppu2c02.v` 端到端联通**：OAM 影子是 TB 里的数组，不是 `nes_ppu2c02` 内部的 256 B OAM RAM；`$2003` 写之后 PPU 侧真实的 `OAMADDR` 自增、以及 `w` 翻转在可见区的副作用都没有被测。
- **没有和 `nes_ppu_sprite.v` 联通**：不测"新写进去的精灵在下一条扫描线出现"，也不测可见区 DMA 造成的撕裂。
- **没有覆盖 `start` 与 `reset` 同拍**的竞争：RTL 里异步 `reset` 优先，TB 未加断言。
- **没有覆盖 `start` 保持多拍**在 `done` 之后立刻开始第二笔事务的行为（文档里说明了，TB 没测）。
- **没有覆盖读 ack 同拍 `reset`**、或者 ack 在 `cpu_read_req` 撤销之后才到（TB 的 ack 生成器保证 `req=0` 时 `ack=0`）。
- **没有覆盖 `OAMADDR_WRITE` 被写成 2** 这种非法参数值。
- **没有覆盖两个实例在 `OAMADDR_WRITE` 上的非法组合**（本 TB 固定一份 0 一份 1）。
- **`parity_shadow` 是 TB 里对 `parity_q` 的独立复制**：如果 RTL 改了奇偶规则（例如改成偶数时多一拍），TB 的 `wait_align` 会和 RTL 一起错，测试可能仍然通过。只有 `dbg_align_left` 和 `cycle_count` 的交叉核对是真正独立的。
- **没有做 8x/16x 规模的随机回归**：全部是定向事务。
- ModelSim/Questa 的 `run_ppu_tb.do` **没有** OAM DMA 通道；`tools/sim_all.ps1` 也不包含 `tb_nes_oam_dma`，本任务没有改这两个脚本（不在写入范围内）。

## CHR 取数单元 testbench

`tb_nes_chr_fetch_unit.v` 是 `rtl/nes_core/ppu/nes_chr_fetch_unit.v` 的自检 testbench，和上面三个一样不下载 ROM、不读外部文件：CHR 在 TB 里是 8 KiB 数组 `chr_mem[0:8191]`，初始化成 `i[7:0] ^ 8'h5A`（**任意字节都既不等于 0 也不等于 `8'hxx`**，所以"取回的是不是这一拍请求的那个字节"可以逐字节判死）。

`nes_chr_fetch_unit.v` 是**外部 CHR 单口取数单元**：收到一行的取数请求（`req_start` + `tile_base` + `tile_count`）后，按"每 tile 两拍、先低平面再高平面"的节拍把整行的 CHR 顺序读一遍，最后**只把最后一个 tile 的两个平面**锁存进 `bg_lo` / `bg_hi` 并拉起 `bg_valid`。它用 6 状态 FSM（`S_IDLE` / `S_PRE` / `S_ARM` / `S_BEAT` / `S_GRAB` / `S_DONE`）实现，`chr_addr` 在 `S_PRE` 就被更新、`chr_req` 在下一拍的 `S_ARM` 才拉高——这就是"地址比请求早一拍就位"这条合同的来源。

TB 里的 CHR 读模型是**固定 1 拍延迟**的寄存器读：`ce` 上升沿锁存 `chr_addr` 并同时读数组，`chr_rdata` 取的是上一拍锁下来的 `mem_q`。这正好是"请求拍发地址、下一拍收数据"的合同，也让"请求期间 `chr_addr` 是否被改动"可以被**数据完整性检查**功能性地验证，而不只是看波形。

### CHR 取数单元模块接口极性

| 信号 | 方向 | 合同 |
| --- | --- | --- |
| `clk` | in | 唯一时钟。模块只有一个 `always @(posedge clk)`。 |
| `ce` | in | 高有效。**所有状态推进都以 `ce=1` 为条件**：`ce=0` 时 `chr_req` / `chr_addr` / `bg_lo` / `bg_hi` / `bg_valid` / `busy` 全部逐位冻结。 |
| `reset` | in | 高有效**同步**复位（采样沿是 `posedge clk`）。RTL 里 `if (reset)` 分支排在 `else if (ce)` **前面**，所以复位**不受 `ce` 门控**——`ce=0` 期间来一个时钟沿照样清干净。 |
| `req_start` | in | 1 拍脉冲，只在 `S_IDLE` 被采样。**`busy=1` 期间被忽略**（唯一的重入手段是 `reset`）。接受的那一拍把 `tile_base` / `tile_count` 锁存进 `base_q` / `cnt_q`，同时**清 `bg_valid`**。 |
| `tile_base` | in | 13 位。本行第一个 tile 的 CHR 基址；只有 `base_q` 的 13 位参与地址加法。 |
| `tile_count` | in | 6 位。本行要取的 tile 数；一行共发 `2 * tile_count` 个 `chr_req` 拍。 |
| `chr_req` | out | 1 拍脉冲，每平面一个。 |
| `chr_addr` | out | 14 位。**在 `chr_req` 拉高之前一个 `ce` 就已经是正确值**（`S_PRE` 先写地址、`S_ARM` 再拉请求）。一行内单调递增，每拍 +8。 |
| `chr_rdata` | in | 8 位。约定在 `chr_req` 拍**之后的那一拍**有效。 |
| `bg_lo` / `bg_hi` | out | 8 位各一。**只锁存本行最后一个 tile 的两个平面**：行内第 `k` 个字节（`k` 从 0 到 `2*cnt-1`）的地址是 `base + k*8`，偶数 `k`（低平面）收进 `bg_lo`、奇数 `k`（高平面）收进 `bg_hi`。RTL 里 `idx_q` 只在 `pl_q=1` 的拍递增，所以它自己只从 0 走到 `cnt-1`。 |
| `bg_valid` | out | **电平**，不是脉冲。一行取完在 `S_DONE` 拉高，**一直保持到下一行 `req_start` 被接受**（接受那一拍清零）。 |
| `busy` | out | **电平**，`state != S_IDLE`。在接受 `req_start` 的**下一拍**起为高，经过 `S_DONE` 那一拍仍是高，`S_DONE` 之后回到 `S_IDLE` 的那一拍才回 0。 |

### CHR 取数单元断言覆盖

`tb_nes_chr_fetch_unit.v` 使用 `$fatal` 断言，共 **8 组**（A1..A8），每组一行 `$display`：

1. **A1 复位干净**：复位后 `chr_req` / `bg_valid` / `busy` 三者全 0。
2. **A2 单 tile 的请求节拍**：`tile_count=1` 恰好发 2 个 `chr_req`，地址依次是 `tile_base` 与 `tile_base+8`（低平面在前、高平面在后）；本行结束后 `bg_valid=1`，且 `bg_lo` / `bg_hi` 逐字节等于 CHR 模型里对应的两个字节，**并且都不是 `8'hxx`**（证明两平面真的被锁存了，不是悬空）。
3. **A3 最坏行的字节数与地址递增**：`tile_count=33`（即 `tb_chr_fetch_feasibility.v` 实测的最坏行在渲染窗口里的 tile 数）恰好发 66 个 `chr_req`，地址覆盖 `tile_base+0 .. tile_base+520`，每拍 **+8 严格递增**（不许跳、不许重复、不许回退），33 组低/高平面对逐字节与 CHR 模型比对，最后一组锁进 `bg_lo` / `bg_hi`。
4. **A4 地址提前一拍就位**：一个全局监视器在**每一个请求拍**比较 `chr_addr` 与上一拍的 `chr_addr`，全 66 个请求拍都必须"上一拍就已经是这一拍该给的值"——即地址不是和 `chr_req` 同一拍才变的。
5. **A5 `ce=0` 冻结**：行中途把 `ce` 拉低 4 个 `clk`，`chr_req` / `chr_addr` / `bg_lo` / `bg_hi` / `bg_valid` / `busy` 六个输出逐位不变；`ce` 恢复后本行照常跑完（`tile_count=4` → 8 个请求）。
6. **A6 行中 `req_start` 被忽略**：行中途再拉一次 `req_start`（带不同的 `tile_base=6000` / `tile_count=2`），当前行不受影响——仍然是 66 个请求、末地址仍是 `tile_base+520`、`bg_valid` 仍为 1。
7. **A7 行间不串数据**：第二次 `req_start` 接受那一拍清掉 `bg_valid`；行 1（4 tile @4096）末 tile 是 `6a/62`、行 2（2 tile @5120）末 tile 是 `4a/42`，两者**必须不同**（相同就判死），证明没有 bleed。
8. **A8 取数中途复位**：行中途拉 `reset`，`chr_req` / `bg_valid` / `busy` 立刻全 0（事务被中止）；复位释放后**下一行照常工作**（`tile_count=3` → 6 个请求，`bg_lo=7a` / `bg_hi=72`）。

TB 顶部还有 `global timeout`（200 µs 仿真时间）兜底断言。

### CHR 取数单元 testbench 运行

在仓库根目录执行，输出放在临时目录，不向仓库写文件：

```powershell
$tmp = Join-Path $env:TEMP 'op_fpga_emu'
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
& 'C:\iverilog\bin\iverilog.exe' -g2001 -Wall -s nes_chr_fetch_unit -o (Join-Path $tmp 'nes_chr_fetch_unit_core.vvp') 'rtl\nes_core\ppu\nes_chr_fetch_unit.v'
& 'C:\iverilog\bin\iverilog.exe' -g2012 -s tb_nes_chr_fetch_unit -o (Join-Path $tmp 'tb_nes_chr_fetch_unit.vvp') 'rtl\nes_core\ppu\nes_chr_fetch_unit.v' 'tb\ppu\tb_nes_chr_fetch_unit.v'
& 'C:\iverilog\bin\vvp.exe' (Join-Path $tmp 'tb_nes_chr_fetch_unit.vvp')
```

`-g2001` / `-g2012` 的选择理由：核心是纯 Verilog-2001（一个 `always` + 6 个寄存器 + 3 根组合线，没有任何 SystemVerilog 构造），所以 `chr-fetch-core` 目标能用 `-g2001 -Wall` 单独 elaborate；testbench 用 `$fatal`，因此 TB 入口统一用 `-g2012`，与本目录上面几个 testbench 以及 `tools/sim_all.ps1` 里 `Standard = '2012'` 的写法一致（Icarus 在 `-g2001` 下其实也接受 `$fatal`，但入口统一更好）。

下面是本版本的完整期望输出；vvp 退出码 0，仿真时间 3.796 µs，实测运行约 0.1 s，**最后一行是 `PASS nes_chr_fetch_unit`**：

```text
A1 reset clean: chr_req=0 bg_valid=0 busy=0 chr_addr=0
A2 tile_count=1: chr_req x2 addrs 0,8 bg_lo=5a bg_hi=52 bg_valid=1
A3 worst row tile_count=33: chr_req x66 addrs 1024..1544 (base+0..base+520), all 33 low/high pairs match CHR model
A4 chr_addr already correct one ce before all 66 request beats
A5 ce=0 for 4 clk mid-row: all outputs frozen, row still completed with 8 reqs
A6 mid-row req_start ignored: still 66 reqs, last addr 520, bg_valid=1
A7 bg_valid cleared on 2nd start; row1(4@4096) last=6a/62 row2(2@5120) last=4a/42, no bleed
A8 reset mid-fetch cleared state: chr_req=0 bg_valid=0 busy=0
A8 next row after reset works: chr_req x6 bg_lo=7a bg_hi=72
PASS nes_chr_fetch_unit
```

任何 `$fatal` 命中会让 vvp 以非零退出码结束，并把检查编号（如 `A3`）、实际值与期望值打印到 stdout。

### CHR 取数单元 testbench 未覆盖项

- **本 TB 只证明"这个单元自己按约定走"，不证明它在 PPU 里的接法。** `nes_chr_fetch_unit` 现在**已经被** `nes_ppu2c02` 的 `g_chr_external` 例化：PPU 侧按 `b_k = 8k - fine_x` 的窗口起点在 `b_k - 9` 逐 tile 流水打 `req_start`，收到 `bg_valid` 那一拍把 `bg_lo` / `bg_hi` 锁进 `bg_lo_q` / `bg_hi_q` 并置 `bg_ready`；`chr_rdata` 也真的被读了（进 PPU 的平面锁存，并喂 `nes_sprite_chr_fetch` 的 128 位 `shadow`）。**像素级证据来自另一条 TB** `tb_nes_ppu2c02_ext_chr.v`（回归目标 `ppu-ext-chr-tb`，`EXTERNAL_CHR=0` 与 `EXTERNAL_CHR=1` 的逐 dot A/B），不是这一条。
- **没有和 `nes_system_v5` 的 `ce` 端到端联通**：这里的 `ce` 是 TB 自己一拍一拍的脉冲，不是系统层 PPU 的 4 分频。`chr_rdata` "下一 `ce` 有效"这条合同只对着 TB 自己的 1 拍延迟读模型成立。
- **读模型固定 1 拍、不可背压**：ack 延迟没有参数化；外部 CHR 来不及、要多拍等待、要仲裁、要按突发读，全都没有测。SDRAM 的真实延迟与突发效率更不在范围内。
- **只回最后一个 tile**：`bg_lo` / `bg_hi` 不是整行缓存。真实一行要出 32 组像素就得有 32 组寄存器或一个逐 dot 移位寄存器，这个模块没有、这个 TB 也没有测需要多少寄存器。
- **没有 `dot` / `scanline` 输入**：模块根本不知道现在在第几拍，所以"在一行的哪个 dot 拉 `req_start`"、"在 dot 257 拉会不会和精灵预取撞车"都不在这里测——那些是 `tb_chr_fetch_feasibility.v` 的测量加 `docs/modules/ppu-external-chr.md` 的设计决定。
- **只取 pattern 两平面**：attribute 四象限、nametable 复制、以及 `chr-fetch-feasibility.md` 第 6 节那个"不能整体 mux 成 `dot+1`"的 attribute 陷阱，本 TB 一条都没覆盖。
- **激励是"发一次、等 `busy` 落"**：因此 `tile_count=0`、6 位 `tile_count` 的上限、`tile_base` 顶到 8191、以及"上一行完成的同一拍就发下一行 `req_start`"这些边界都没测。本 TB 出现的最大地址是 6184（`tile_base=6144` / `tile_count=3`），**13 位 `base_q` 加法的回绕与 `chr_addr[13]` 这位从未被用到的情况没有测**。
- **第 4.2 节那个 68 B/行 的最坏行没有被本 TB 完整覆盖**：`tile_count=33` 覆盖的是渲染窗口的 33 个 tile（66 字节），**预取 tile 那额外的 2 字节不在这里**。
- ModelSim/Questa 的 `run_ppu_tb.do` 没有 CHR 取数单元通道，本任务没有改那个脚本（不在写入范围内）；`tools/sim_all.ps1` 已经包含 `chr-fetch-core` 与 `chr-fetch-tb`。

## CHR 取数可行性实验 testbench

`tb_chr_fetch_feasibility.v` **不是某个模块的自检 testbench，而是一次测量实验**。它实例化 `nes_ppu2c02`（`MIRROR_VERTICAL = 1'b0`、`EXTERNAL_CHR = 1'b0`）但**只把它当信号来源**，通过层次引用读出真实的 `dot` / `scanline` / `bg_x_total` / `bg_coarse_*` / `bg_attribute_byte` / `u_sprite.range_count` 等线网，在 13 组寄存器配置、共 **16 个完整帧**（1,429,472 拍）上数出三件事：Q1 背景取数的 dot 预算、Q2 精灵 `dot 257..272` 那 16 拍预取窗口够不够、Q3 "把 `dot` 整体 mux 成 `dot+1`" 会坏多少。

**它一行 RTL 都没有改**，完整结论与全部测量数字在 [`docs/modules/chr-fetch-feasibility.md`](../../docs/modules/chr-fetch-feasibility.md)；本节只说明 testbench 本身。

Q3 的反事实**不是靠改 RTL 造 bug 得到的**：TB 内部的 `bg_model` task 把整条背景通路重算一遍，唯一参数是 `sh ∈ {0,1}`，`sh=1` 只把 `xts` 换成 `dut.bg_x_total + 1`（背景通路唯一的 `dot` 入口），其余连 `mirror_nametable` / `palette_index_map` 都是照抄 RTL。

### CHR 可行性实验断言覆盖

`tb_chr_fetch_feasibility.v` 使用 `$fatal` 断言，共 **15 组**（不是 15 个 `$fatal` 字面量，是 15 条互相独立的判死条件）：

1. **寄存器配置自检（`set_config`）**：`fine_x` / `temp_addr[4:0]` / `temp_addr[9:5]` / `temp_addr[14:10]`（nametable 基址）/ `mask_reg` / `control_reg` / `u_sprite.sprite_height` 全部要与配置相符（6 个独立 `$fatal`）。不符就意味着"这一帧的数据属于另一组配置"，后面所有数字全部作废。
2. **`dot` / `scanline` 逐拍核对**：262 × 341 每一拍都必须与 TB 自己的 `li` / `di` 循环计数一致。
3. **一行内 `u_sprite.range_count` 不变**。
4. **一行内 `bg_coarse_y` 不变**。
5. **一行内 `bg_y_total` 不变**。（3/4/5 合起来从仿真里验证了 `ppu-external-chr.md` 3.6 那句"Y 侧三根线与 `dot` 完全无关"。）
6. **模型自检**：dot 0..255 每一拍，TB 的 `sh=0` 重算结果必须与 `dut.bg_palette_value` **逐位相同**，且 `dut.bg_palette_index` / `dut.bg_attribute` 也逐位相同。这条不是形式主义——实现期它抓到了一个真 bug（重算模型最初把 `bg_nt_offset` 拼成 `{ntx, nty, ...}`，而 RTL 是 `bg_nametable[1]` 放 bit 11、`[0]` 放 bit 10），在 scanline 240 dot 0 被抓住。
7. **每帧结束必须回到 `0:0`**。
8. **可见区（dot 0..255）tile 边界数每行恰好 32**。（这条就是文档第 3 节"预期 33、实测 32"那条被推翻的预期。）
9. **整行（dot 0..340）tile 边界数必须是 42 或 43**。
10. **发射机会（`bg_x_total[2:0] == 3'd6`）与边界数之差不超过 1**。
11. **hblank（dot ≥ 256）拍数每行 85**。
12. **`dot 257..272` 拍数每行 16**（这就是 Q2 的预取窗口）。
13. **`bg_shown` 拍数必须是 333（`mask[1]=0`）/ 341（`mask[1]=1`）**。
14. **`u_sprite.pixel_active` 拍数：行 0..239 必须是 256，行 240..261 必须是 0**。
15. **实际出背景像素的列数：行 0..239 必须是 248 / 256，行 240..261 必须是 0**。

TB 顶部还有 `global timeout`（400 ms 仿真时间）兜底断言。

### CHR 可行性实验 testbench 运行

在仓库根目录执行，输出放在临时目录，不向仓库写文件：

```powershell
C:\iverilog\bin\iverilog.exe -g2012 -Wall -o "$env:TEMP\chrfeas.vvp" -s tb_chr_fetch_feasibility `
    rtl\nes_core\ppu\nes_ppu2c02.v rtl\nes_core\ppu\nes_ppu_sprite.v tb\ppu\tb_chr_fetch_feasibility.v
C:\iverilog\bin\vvp.exe "$env:TEMP\chrfeas.vvp"
```

`-g2012` 的理由：PPU 核心本身是 Verilog-2001（`ppu-core` 能用 `-g2001` 单独 elaborate），但这个 testbench 用 `$fatal` 判死，所以入口统一 `-g2012`，与上面几个 testbench 一致；这里额外加了 `-Wall`，`-Wall` 下本 testbench **零 warning**（RTL 侧那 9 条 `@*` 数组敏感性 warning 与本实验无关，也没有被它消除：`nes_ppu_sprite.v:333,334,334,335,340,360` 6 条 + `nes_ppu2c02.v:445,769,774` 3 条；`tools/sim_all.ps1` 自己不加 `-Wall`，所以跑回归看不到它们）。

期望输出的**最后一行是 `PASS chr_fetch_feasibility`**；vvp 退出码 0，仿真时间 14.295 ms。13 组配置各打印一段 `PASS-FRAME <组名>`，每段后面是 Q1 / Q2 / Q3 三组实测数字加 Q2 的 `range_count` 直方图；随后是 pass M 的逐行明细（行 0..40、95..115、240..261，每行给 `range_count` / `sprite_pixel_dots` / `overflow_dots` / `rendered_bg_columns` / `bad_attr_columns`）；最后一行是 `Q1 dot340 bg_x_total, pass M: ...`。完整的逐行输出示例见 `docs/modules/chr-fetch-feasibility.md` 第 9 节。

### CHR 可行性实验 testbench 未覆盖项

这一节必须和文档第 8 节一起读。

- **不构成任何等价性证据**：文档第 4/5/6 节的数字全是"预算"与"反事实差异"，不是"`EXTERNAL_CHR=1` 的输出等于 `EXTERNAL_CHR=0` 的输出"。第 6 节的 16 列 / 196 列是"**如果用错实现方式**会坏多少"，不是"实现正确之后的差异"。
- **`EXTERNAL_CHR = 1'b1` 一次都没被实例化**，本实验连外部取数分支长什么样都没跑。它和 `tb_nes_chr_fetch_unit.v` 是**两条独立的线**：一个测预算，一个测单元自己的时序合同，**两者之间那一段现在也已经写好**：`nes_chr_fetch_unit` 由 `nes_ppu2c02` 的 `g_chr_external` 例化，`chr_req` / `chr_addr` / `chr_rdata` 都接上了（精灵侧由 `nes_sprite_chr_fetch` 承担，`chr_req` / `chr_addr` 由二者无握手地仲裁 mux 送出）。像素级证据由 `ppu-ext-chr-tb` 给出；`chr-fetch-tb` 通过**仍然不构成**"CHR 取数通路已接通"的证据，它只覆盖单元自身。
- **没有验证时序合同**：这里的 `ce` 是 TB 自己一拍一拍的 `tick_dot`，不是 `nes_system_v5` 的 `div_phase`，所以"每 dot 1 字节"这个前提本身没有被端到端验证过。
- **没有覆盖运行期改变 scroll**：13 组配置都是"整帧固定寄存器"，`temp_addr` 在一行中途变化的场景没测。
- **没有覆盖 CPU 在渲染期访问 `$2007`**（文档第 7 节 8.1 / 8.3 涉及的路径），也没有覆盖 `$2007` 写 CHR 与取数请求撞在同一拍的情形。
- **没有做综合 / 时序收敛验证**："19.94% 占用率"是**拍数**的占用率，不是门级时序。
- **Q3 的 16 列依赖激励**：本实验刻意让每个 attribute 字节的 4 个象限互不相同、tile 号逐 tile 不同、CHR 两平面按位取反。换成"整张 attribute 表同值 + 全屏同一个 tile"，attribute 差异的**可观测**列数会变，但"象限选错"的事实与每行 16 次翻转的节拍不变。
- ModelSim/Questa 的 `run_ppu_tb.do` 没有这条实验通道，本任务没有改那个脚本（不在写入范围内）；`tools/sim_all.ps1` 已经包含 `chr-feasibility-tb`（`Group = 'ppu'`）。

## 外部 CHR A/B testbench

`tb_nes_ppu2c02_ext_chr.v`（回归目标 `ppu-ext-chr-tb`，**1,248** 行）例化**两个** `nes_ppu2c02`——`dut_a` 是 `EXTERNAL_CHR(1'b0)`、`dut_b` 是 `EXTERNAL_CHR(1'b1)`（**6 个**外部 CHR 数据端口全部接出，第 7 个 `chr_rd_arm` 在两个实例上都**绑 `1'b0`**）——共用同一份 `clk` / `ce` / 寄存器激励，逐 `ce` 逐 dot 比对。这是本目录**唯一**提供像素级等价性证据的 TB；另外三个（`chr-fetch-tb` / `sprite-fetch-tb` / `chr-feasibility-tb`）各自只证明单元自身或只测预算。断言清单、固定输出与边界见 [`../../docs/modules/ppu-external-chr.md`](../../docs/modules/ppu-external-chr.md) 第 11.1.3 与 11.3.1 节。

### `A6 $2007-WRITE-STROBE`：目标已改，以及**为什么这条 TB 故意没有写场景**

`$2007` 对外部 CHR 的写通路已经实现（`5cc36e7` / `576cc74`），所以这条断言原来的"`chr_we` / `chr_wdata` 恒为 `1'b0` / `8'h00`"**陈旧了**。它现在断言的是 strobe 与真实寄存器周期的等价关系：

- `chr_we` 为高 ⟺ 该拍是真实的 `reg_cs && reg_we && reg_addr == 7` 写周期，且 `chr_wdata == reg_din`；
- `chr_we` **不会**在这种写周期之外为高（同一条件）；
- 一次落在 CHR 半区地址空间的 `$2007` 写周期**必须**在该拍抬起 `chr_we`。

**实测到 0 个 strobe 拍，这是诚实的 0 而不是空洞**：本 TB 的 `write_register` 只用地址 6 / 6 / 5 / 5 / 0 / 1，`read_status` 只用地址 2，**`reg_addr` 从来不是 7**，所以 strobe 合法地一次都没有被激励。

**这是刻意的，不是缺口，而且有两条互相独立的原因。**

**原因一：两侧的架构不同，渲染中期的访问会让它们结构上不再等价。** 这条 A/B 把 `EXTERNAL_CHR = 0`（内部那一侧**逐 dot 组合**读 `chr_ram`）与 `EXTERNAL_CHR = 1`（外部那一侧是**一次取数提前**的流水）放在一起比较像素。写 CHR 时内部侧立刻看到新字节、外部侧要等 1 dot 甚至更久；读 CHR 时 `$2007` 的读臂要占掉一个 `ce` 的地址时间、还可能顶掉一个在飞的取数字节。如果在这里加一个 `$2007` 场景，上面 921,600 次背景比对与 552,960 个精灵比较点就**不再测量"外部通路等价"，而是在测量"两侧架构不同"**，它们的数字将失去意义。**所以不要"顺手"往这条 TB 里加一个 `$2007` 写或读场景。**

**原因二（这一条与 A/B 无关，纯粹是这条 bench 做不到）：这条 TB 里没有 CPU，也没有总线。** `$2007` 读臂的成立条件是"这次 `$2007` 访问会不会在下一个 `ce_cpu` 拍上真正发出"——`nes_system_v6` 用的是 `sel_ppu && !cpu_we && (ppu_addr == 3'd7) && cpu_bus_ready && (div_phase == 4'd8)`，每一个项都来自 **CPU 侧**（owner 译码、`bus_we`、`bus_addr`、`div_phase`）。这条 bench 直接用 task 写寄存器，**没有 owner 译码、没有等待态、没有 `div_phase`**，所以它**提供不了**设计需要的那种判据；硬要造一个只能造一个假的。**端到端证明因此必须放在有 CPU 与总线的那一层。**

**为什么只保留一条诚实的 0 而不是一条断言**：`$2007` 读写两条通路的端到端证明都放在 `tb/system/tb_nes_system_v6.v`（回归目标 `system-v6`），它用五块板（W1 哨兵 / 自验证对 / CHR-RAM-vs-CHR-ROM 忽略对 / MMC3 bank 限定写 / **W3 回读组**）把整条通路钉死。合同与逐条推导见 [`../../docs/ppu_chr_external_write.md`](../../docs/ppu_chr_external_write.md)。

**`ppu-ext-chr-tb` 的 A/B 数字逐字节未变**（**写通路那一轮与读臂那一轮都是**）：`S3` 七个精灵可观测量全部 `= 0`、`A3 verified request addresses=337450 verified latched plane pairs=126546`、`S2 request_beats=159296 … shadow_byte_mismatches=0`——读写两条通路的加入**都没有**让 PPU 的渲染行为发生任何漂移。读臂那一轮该目标本机 **402.7 s**。

## 明确未实现

- OAM DMA（`$4014`）和 CPU 停机；精确 sprite evaluation 与次 OAM 时序（次 OAM 的清空/评估/取数窗口、`m`/`n`/`o`/`p` 影子寄存器、溢出 glitch）。精灵侧的这些是 `rtl/nes_core/ppu/nes_ppu_sprite.v` 的已知边界，顶层只做功能级接线，不额外修正（读 `$2002` 抑制 hit 的 8 像素窗口、dot 255 不产生 hit、pre-render 行的 hit 行为、`$2003` 非零时精灵 0 判定退化都按那个模块的合同走）。
- sprite 0 hit / overflow 标志**不会每帧自动清零**，只由 `reset` 和读 `$2002` 清；溢出标志在可见行上第一个满足 `PPUMASK[4] && overflow` 的 `ce` 沿就置位，比真实硬件 dot 64..256 的评估窗口更早。
- 8×16 sprite、sprite pattern table、优先级和翻转**已由** `rtl/nes_core/ppu/nes_ppu_sprite.v` 实现并接入 `nes_ppu2c02.v`（见上文"精灵集成"），但精确的取数/评估时序仍然没有。
- 精确 open bus、`$2000/$2001/$2003/$2005/$2006` 读回低两位、寄存器写入 glitch 和读取抑制 NMI 的精确窗口（见时序模型里的 suppression 简化）。`PPUSTATUS[4]` 和 bit3:0 保持恒 0。
- vblank 中途把 `PPUCTRL[7]` 写成 1 不会立即产生 NMI：v0 只在 `(241,0)` 这一个判定点采样 `PPUCTRL[7]`。
- 奇数帧跳 dot、精确背景预取时序、NTSC 之外的制式。
- 逐 dot 可见/不可见区域对 CPU 寄存器访问的真实冲突行为：v0 统一取寄存器优先，不产生 glitch，见“同一时钟沿的冲突合同”。
- APU、mapper 和四屏/单屏 mirroring。**CHR 外部 PPU bus 已经在 PPU 侧接通**：`nes_ppu2c02` 的 `g_chr_external` 分支同时例化 `nes_chr_fetch_unit`（背景）和 `nes_sprite_chr_fetch`（精灵），`chr_req`/`chr_addr` 由二者**无握手**地仲裁 mux 送出、`chr_rdata` 被闩进 `bg_lo_q`/`bg_hi_q` 与 128 位 `shadow`，证据是 `tb/ppu/tb_nes_ppu2c02_ext_chr.v`（回归目标 `ppu-ext-chr-tb`）里 `EXTERNAL_CHR=0` 与 `EXTERNAL_CHR=1` 两个实例之间的 A/B：精灵的七个可观测量在 **552,960** 个比较点上**全部 0 分歧**，1,708 个精灵决定像素跨透明背景 908 / 不透明背景前 564 / 不透明背景后 236 三类优先级，**6,144** 个 dot 恰好 8 个精灵在范围内、**2,048** 个 overflow dot。**精灵特征是逐项证明的**——那条 A/B 跑 **9 个精灵场景**，每组有自己的非空洞 `$fatal`（`case_sp_*` 计数器逐组清零，每组 `mismatched_pixels=0`）：8×16 高度（`sp1-8x16-oddtile` 40、`sp8-8x16-mixprio` 560 个精灵决定像素）、每行 8 个 sprite 上限（`sp8-8x8-limit` 2,048、`sp8-8x16-mixprio` 4,096 个"恰好 8 个在范围内"的 dot）、overflow 标志位（`sp10-overflow` 2,048 个 overflow dot）、水平翻转（`sp1-hflip` 48）、垂直翻转（`sp1-vflip` 56）、双翻转（`sp1-hvflip` 56）。**仍未覆盖**的只有 §8.2"用下一行 OAM 计数"那个 overflow **行为**差异（未实现、所以不可观测；标志位一致本身已证）与这 9 个场景之外没构造出来的优先级组合；**CHR 仲裁仍然无握手、无背压**。**边界**：这是 TB 驱动场景下的 A/B，**不是实机卡带、不是 NESdev test ROM、不是硬件**；`system-v6` 自己那条整帧 A/B 只是**背景**对比，精灵像素等价性**只有** `ppu-ext-chr-tb` 这一条。mapper 侧的 `chr_bank_offset` 接进这条**读**通路是在 System 层完成的，由 `system-v6` 目标证明（见 [`../../docs/modules/system-v6.md`](../../docs/modules/system-v6.md)）。**外部 CHR 的 `$2007` 写通路已经实现**（`5cc36e7` / `576cc74`）：`g_chr_external` 驱动 `chr_waddr`（**自增前**的 `v_addr`）与 `chr_we`（**恰好 1 `clk` 宽**的组合 strobe）/`chr_wdata`，`nes_mapper.v` 一行未改，端到端证据在 `system-v6`（**96** 个写拍、**0** 翻译错、总线侧独立计数同样 96，加哨兵 / 自验证对 / 忽略对 / MMC3 bank 限定写四组非空洞检查），本目录这条 A/B TB 则是**故意没有 `$2007` 场景**（理由见上面那一节的两条独立原因）、只保留一条诚实的 0。**外部 CHR 的 `$2007` **读**通路也已实现**（读臂那一轮）：`nes_ppu2c02` 新增 `input wire chr_rd_arm`（本 TB 两个实例都绑 `1'b0`），`g_chr_external` 里 CHR 读是 CHR 总线的**第三个 master**（`chr_rd_win` 抬 `chr_req`、把 `v_addr[13:0]` 送上 `chr_addr`），配一个 set/hold 寄存器 `chr_rd_armed_q` 与一层**失效保护** `read_buffer_reg <= chr_rd_armed_q ? chr_rdata : 8'h00;`；`nes_system_v6` 在 `div_phase == 8` 的那一拍抬读臂（`sel_ppu && !cpu_we && (ppu_addr == 3'd7) && cpu_bus_ready && (div_phase == 4'd8)`，因为 CPU 在 `div_phase == 0` 锁存 `bus_din`、而外部 CHR 在**每个** `ce_ppu` 沿寄存 `chr_rdata`——**提前量恰好零余量**）。端到端证据在 `system-v6` 的 W3 组：396 个读拍对 396 个读臂一对一、395 个回读字节核对 **0 错**、ab_v5 的内部 `chr_ram` 与 ab_v6 的顶层 128 KiB 阵列对同一批读给出**逐字节相同**的 32 个单元。**但它会占掉一个 `ce` 的地址时间并可能顶掉一个在飞的取数字节**（396 个臂里 **107** 个真的撞上），所以**渲染开着时帧中读不宣称安全**、扫描线 261 明确不安全。**仍未接/仍未做完的是**：**写与取数、以及读臂与取数各自的碰撞抑制**（写实测 **22/96**、读实测 **107/396**，**两条都未修**）、片上 CHR 存储（真实系统要靠尚不存在的 SDRAM，**BRAM 推断也没有任何综合证据**；读臂还带来一条新义务——`chr_addr` 上的地址建立时间必须按真实存储器 `tACC` 预算重新核对）、以及 `ppu_a12`（仍绑 0，所以 MMC3 扫描线 IRQ 无法自计时）。
- 合成验证：`nes_chr_fetch_unit.v` 走的是"整行顺序读、只回最后一个 tile"的形态，不是逐 dot 取数流水线；面积、时序、以及和真实外部 CHR 存储的握手都没有评估过。**它已经接进 `nes_system_v6`**，但 v6 尚未接进任何平台顶层，所以依然没有任何综合、Fitter 或时序证据。
- 精确背景逐 dot 预取和 shift register 装载；当前背景路径按固定 dot 计数功能级取数。
- 合成验证：`nes_ppu_sprite.v` 每个 dot 都要组合重算 64 项 OAM 范围和 8 个 slot，接进 PPU 之后面积和时序完全没有评估过（`docs/00-overview/risk-register.md` 的 R-01 仍然有效）。

内部 CHR 是 8 KiB RAM，便于仿真和综合前端推断；后续 mapper 版本应把它替换为外部 PPU bus 或 banked CHR 存储。
