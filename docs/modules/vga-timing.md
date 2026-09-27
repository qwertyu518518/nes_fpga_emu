# VGA 时序发生器：软件 blit/窗口 offset 与硬件 DE 窗口的逐条对应

`rtl/nes_core/video/nes_vga_timing.v` 是 640×480@60Hz VGA 的**纯时序发生器**：两个自由运行的计数器、一级输出寄存器、几个常数比较。它不产生像素、不保存像素、不实例化任何东西。

本文回答和 `docs/modules/line-buffer-vga.md` 同一类问题，但对象不同：

> 一个用 C 写的软件模拟器（PPU 每 dot 往 `framebuffer[x][y]` 写颜色，帧末 `submit_frame()` 一次性 `SDL_UpdateTexture`，窗口按 `WINDOW_SCALE` 放大）和一个用 Verilog 写的硬件实现（800×525 计数器 + DE 窗口 + 消隐期输出黑），是不是**同一套行为的两种写法**？

结论：**时序这一层是同一套，"窗口"那一层不是。** 软件把"裁掉多少、放大几倍"编码成 blit 循环里的 `continue` 和 `SDL_CreateWindow` 的尺寸；硬件把它编码成 DE 窗口的两个常数（`DE_X0/DE_X1`、`DE_Y0/DE_Y1`）。像素从哪来、什么时候有一行可读，仍然是上游行缓冲的事，本模块只提供"这一拍是不是有效像素、这一行的 x 是多少"这两个答案。

---

## 1. 是什么、不是什么

| 是 | 不是 |
|---|---|
| 800×525 的行/场计数器 | 不是像素生成器 |
| HS / VS / DE 三个窗口比较器 | 不是 frame buffer（一个字节存储都没有） |
| 一级输出寄存器（数据与坐标同拍） | 不是顶层（不含引脚、不含 PLL、不含约束） |
| `line_read_start` 的对齐状态位 | 不是 `nes_video_scaler`（不实例化它） |
| 消隐期把 RGB 强制为 0 | 不是 CDC（单时钟域，`ce` 是唯一的门控） |

模块头部的顶层约束就是这句话：**本模块不得实例化 `nes_video_scaler`，也不得拥有 frame buffer**。像素来源是上游行流，缺失时输出黑。这条约束的意义见第 9 节。

---

## 2. 参数与光栅几何

```verilog
parameter integer H_TOTAL     = 800;   // 一行的像素时钟数
parameter integer H_ACTIVE    = 640;   // 显示器可见区宽度（文档用，不参与窗口逻辑）
parameter integer HSYNC_START = 656;
parameter integer HSYNC_END   = 752;
parameter integer V_TOTAL     = 525;   // 一帧的行数
parameter integer V_ACTIVE    = 480;   // 显示器可见区高度（文档用，不参与窗口逻辑）
parameter integer VSYNC_START = 490;
parameter integer VSYNC_END   = 493;
parameter integer DE_X0       = 64;    // 图像窗口左边界（含）
parameter integer DE_X1       = 576;   // 图像窗口右边界（不含）
parameter integer DE_Y0       = 0;     // 图像窗口上边界（含）
parameter integer DE_Y1       = 480;   // 图像窗口下边界（不含）
```

派生出的常数：`H_LAST = 799`、`V_LAST = 524`。窗口是**左闭右开**的区间，这一点决定了 `DE_X1 = 576` 意味着 512 个像素而不是 511 个。

| 区段 | 本模块 | 与 `docs/hardware/05-vga-lcd.md` 厂商例程对照 |
|---|---:|---|
| 行前肩（图像窗口左黑边） | 64 | 例程的有效区是 640 宽，起始位置 0 |
| 图像窗口 | 512 | 例程 640（640 = 64 + 512 + 64，左右各 64 黑边） |
| 行后肩 | 224 | 64（黑边）+ 16（前沿） |
| 行同步 | 96 | 96（656..751，与例程一致） |
| 一行合计 | 800 | 800（一致） |
| 场同步 | 3 行（490..492） | **2 行**（例程的场同步是帧首的 2 行，有效区在行 35..514） |
| 图像行数 | 480 | 480（一致，0..479） |
| 一帧合计 | 525 | 525（一致） |
| 帧长 | 800 × 525 = 420000 拍 | 一致 |
| 刷新率 | 25 MHz / 420000 = **59.52 Hz** | 一致（`docs/hardware/05-vga-lcd.md` 第 1.1 节） |

两点必须写清楚：

1. **`H_ACTIVE` / `V_ACTIVE` 不参与任何比较。** 640×480 是**显示器**的可见区，本模块送出的图像窗口是 512×480。少了 `H_ACTIVE` 也能工作，但那样就分不清"显示器认为的边界"和"我们放图像的边界"，而 05-vga-lcd.md 的 64+512+64 分解正是黑边方案的来源。
2. **场同步取 3 行（490..492）而不是例程的 2 行。** 例程把场同步放在帧首（`docs/hardware/05-vga-lcd.md` 第 1.2 节的有效区是行 35..514），本模块放在帧尾的垂直消隐里，和 64×480 的图像窗口在时间上错开，交换/回填类动作可以在脉冲处做而不会撞上有效区。490+3 = 493 < 525，垂直回卷前的余量仍有 32 行。这是参数化选择，不是从例程抄来的事实；换成 2 行只需把 `VSYNC_END` 改成 492。

---

## 3. 接口与一拍流水线合同

| 信号 | 方向 | 含义 |
|---|---|---|
| `clk` | in | 像素时钟，640×480@60Hz 对应 25 MHz（周期 40 ns） |
| `reset` | in | **同步**复位，优先级高于 `ce` |
| `ce` | in | 计数使能，`0` 时整个模块冻结 |
| `line_read_start` | in | 读端像素流"新的一行开始了"，用于把流对齐到一条新扫描线 |
| `px_valid` | in | 当前 `px_rgb565` 是一个有效源像素 |
| `px_rgb565[15:0]` | in | 源像素（RGB565，位分配见 05-vga-lcd.md 第 2.1 节） |
| `hsync` | out | 行同步，**正极性**（有效高） |
| `vsync` | out | 场同步，**正极性**（有效高） |
| `de` | out | 图像窗口有效，**纯时序**，与有没有数据无关 |
| `rgb565[15:0]` | out | 像素输出，窗口外/无数据时为 0 |
| `hcount[9:0]` | out | 0..799，当前这一拍在引脚上的横坐标 |
| `vcount[9:0]` | out | 0..524，当前这一拍在引脚上的纵坐标 |
| `active_pixels` | out | 这一拍 `rgb565` 上是真实图像数据（= `de` 且本行已对齐且 `px_valid`） |
| `frame_pulse` | out | 单周期脉冲，落在**一帧的最后一个像素** `(799,524)` |
| `line_read_sync` | out | `line_read_start` 的 `ce` 门控寄存回声，单周期 |

### 3.1 一拍流水线（本模块最重要的合同）

所有输入和所有输出都在**同一个 `posedge clk`** 上更新，因此：

> **在第 N 个 `ce` 沿上呈现的 `px_valid` / `px_rgb565` / `line_read_start`，描述的是那个沿之后计数器将要到达的坐标。**

等价说法：`px_*` 相对 `hcount` **领先一拍**；`hcount` / `vcount` 读到的就是引脚上那一拍的坐标（`hcount`、`vcount` 和 `hsync/vsync/de/rgb565` 描述的是同一个像素，不会错位）。

| 时刻 | `hcount` 读数 | 引脚上的输出描述的坐标 | 这一拍应当呈现的源像素 |
|---|---:|---:|---|
| 第 N 个 `ce` 沿之前 | `x` | 已经是 `x` | 坐标 `x+1` 的源像素（或者沿上的下一个坐标） |
| 第 N 个 `ce` 沿之后 | `x+1` | `x+1` | 坐标 `x+2` 的源像素 |

所以**默认 DE 窗口下，对齐的写法是：在 `hcount` 读 63 的那一拍给出 `line_read_start` 和该行的第 0 个源像素**，于是坐标 64 上的输出就是源像素 0。`line_read_sync` 会在 `hcount` 读 64（与第一个有效像素同拍）时为高。

这个约定和 `nes_line_buffer_vga` 的 `read_x` / `read_rgb565` 完全一致（那两个信号同拍描述同一个源像素，见 `docs/modules/line-buffer-vga.md` 第 3.4 节），所以两个模块可以直接串在同一个 `ce` 上，中间不需要额外的相位调整。

### 3.2 `de` / `active_pixels` / `rgb565` 为什么是三个信号

| 情况 | `de` | `active_pixels` | `rgb565` |
|---|---:|---:|---:|
| 窗口内，本行已对齐，`px_valid=1` | 1 | 1 | 源像素 |
| 窗口内，本行已对齐，`px_valid=0` | 1 | 0 | 0 |
| 窗口内，本行**未**收到 `line_read_start` | 1 | 0 | 0 |
| 窗口外（消隐、黑边） | 0 | 0 | 0 |

`de` 只表达时序窗口（显示器/控制器该收像素的位置），`active_pixels` 才表达"这一拍真的有像素"。把两者分开，下游就能区分**"这一行还没准备好"**（未对齐）和**"这一行在消隐"**（窗口外）——两者在 `rgb565` 上都是 0，但在系统层是不同的事件。

---

## 4. `line_read_start`：对齐的是读端流，不是帧计数器

```verilog
assign line_next = line_read_start ? 1'b1 : (h_last ? 1'b0 : line_started);
```

`line_started` 是**唯一**一个由 `line_read_start` 改变的状态位，它只回答"本行是否已对齐"。行为：

| 事件 | `line_started` | 效果 |
|---|---:|---|
| 某拍 `line_read_start=1` | 置 1 | 从该坐标起，本行有效区输出源像素 |
| 行末（`hcount=799`，即将回到 0）且本拍无 strobe | 清 0 | 下一行重新等待 strobe |
| 帧计数器 `vcount` | **完全不受影响** | 自由运行，第 5 条断言就是钉这一条 |

三条必须记住的性质：

1. **不能用它复位帧计数器。** 帧计数器只有复位和 `ce` 能停它。TB 在一行的中间打一个 strobe，然后逐拍校验 `hcount` / `vcount` 的递增序列没有被扰动（`test_line_read_align`）。
2. **行末清零、strobe 优先。** 当 strobe 和"行末"落在同一拍时（也就是 strobe 呈现给坐标 `(0, y+1)` 的那一刻），置位赢。所以"行首 x=0 处的 strobe"既被回声也被采纳，能让整行保持对齐。反过来，**呈现给坐标 `(799, y)` 的 strobe 会被行末清零立刻抹掉**——它只对齐坐标 799 那个消隐像素，对下一行毫无作用。这两条各自被 `test_zero_strobe` 和 `test_last_pixel_strobe` 钉死。
3. **strobe 在有效区中间也能用，但会截断本行。** 在 `x=300` 打 strobe，坐标 300 变成源像素 0，坐标 301..575 是它的后继，坐标 64..299 是**上一段流**的尾巴。所以 strobe 的正确位置是"源像素 0 应该落在的那个坐标"，默认就是 `DE_X0`。

**推荐用法**：把 `line_read_start` 和该行的第 0 个源像素一起呈现，落在 `DE_X0`（默认 64）上。

---

## 5. `ce` 与复位

```verilog
if (reset) begin ...全部清零... end else if (ce) begin ...计数... end
```

| 信号 | 复位时 | `ce=0` 时 |
|---|---|---|
| `hcount` / `vcount` | 0 | 保持 |
| `hsync` / `vsync` / `de` | 0 | 保持 |
| `rgb565` | 0 | 保持 |
| `active_pixels` / `frame_pulse` / `line_read_sync` | 0 | 保持 |
| `line_started` | 0 | 保持 |

- **复位优先于 `ce`。** 在扫描中间（`de=1`、像素非 0）拉高 `reset`，即使 `ce=0`，下一拍也一定全部归零。复位把光栅**归位到 `(0,0)`**，所以第一帧的第一个 `frame_pulse` 出现在第 419999 个 `ce` 沿（`(0,0)` 是复位状态本身，不会被重新寄存一次），之后的帧长严格是 420000 拍。
- **`ce` 冻结一切，包括输入。** `ce=0` 期间呈现的 `px_rgb565` / `line_read_start` 会被**整个丢掉**，不会被延后到恢复后执行。TB 在 `ce=0` 的 16 拍里持续把 `px_rgb565` 打成 `16'hFFFF`、把 `line_read_start` 打成 1，断言九个输出逐位不变，并且恢复之后那一行的 strobe **没有被补上**。
- 复位后计数从 `(0,0)` 自由运行，不需要外部"启动"信号。

---

## 6. 同步极性

`hsync` / `vsync` 都是**正极性**（有效高）：

| 信号 | 有效区间 | 极性 |
|---|---|---|
| `hsync` | `x ∈ [656, 752)`，每行 96 拍 | 高有效 |
| `vsync` | `y ∈ [490, 493)`，每帧 3 行 | 高有效 |
| `de` | `x ∈ [64, 576)` 且 `y ∈ [0, 480)` | 高有效 |

复位时三者都是 0。

`docs/hardware/05-vga-lcd.md` 第 1.1、1.3 节记录了厂商例程用**低有效** HS/VS，并明确写着"具体显示器的输入极性……不能只由代码决定"。因此：**如果接的显示器或转接器要求负极性，由顶层反相后再出引脚**（`assign vga_hs_n = ~hsync;`），不要改本模块——本模块的窗口语义（"有效高"）在两种极性下都更好读。

---

## 7. 软件 SDL blit / 窗口 offset 与硬件 DE 窗口的逐条对应

`[源码观察]` `.slim/clonedeps/repos/caseif__cNES/` 是这种结构的典型：`src/renderer.c` 的常量是 `VIEWPORT_TOP 8`、`VIEWPORT_BOTTOM 231`、`VIEWPORT_H = RESOLUTION_H(256)`、`VIEWPORT_V = 224`，`src/renderer.h` 里 `WINDOW_SCALE 3`。

### 7.1 裁剪：blit 循环里的 `continue`

```c
/* src/renderer.c:154 —— 240 行里只有 224 行被 blit */
if (y < VIEWPORT_TOP || y > VIEWPORT_BOTTOM) continue;
(*g_pixel_buffer_back)[y - VIEWPORT_TOP][x][0] = rgb.r;
```

| 软件 | 硬件 | 说明 |
|---|---|---|
| `if (y < 8 \|\| y > 231) continue;` | `DE_Y0` / `DE_Y1` | 同一个"只显示中间一段"的动作，一个在 blit 循环里跳过，一个在时序比较器里给出窗口 |
| 裁掉 8 + 8 = 16 行 | 0 行被裁 | **行为不同**：软件按 NTSC overscan 惯例裁成 224 行，硬件把 240 行全部用上（每行 2 遍 = 480 行，`docs/modules/line-buffer-vga.md` 第 3.5 节） |
| `[y - VIEWPORT_TOP][x]` | `vcount` / `hcount` | 同一个坐标系的两种下标 |

**为什么硬件不裁那 16 行**：VGA 的 480 可见行需要正好 480 个源行才能填满，240 源行 × 2 遍正好。裁掉 16 行就只能显示 448 行，要么上下加黑边（浪费 32 行），要么非等比拉伸。`docs/hardware/05-vga-lcd.md` 第 3.3 节把"帧边界和撕裂"列为显示通路的难点，`docs/modules/line-buffer-vga.md` 第 6 节说明了为什么这里不需要整帧缓冲。

### 7.2 缩放：窗口尺寸

```c
/* src/renderer.c:81 —— 窗口 = 256*3 × 224*3 = 768 × 672 */
g_window = SDL_CreateWindow("cNES", ..., VIEWPORT_H * WINDOW_SCALE, VIEWPORT_V * WINDOW_SCALE, ...);
/* src/renderer.c:175 —— 一次 blit 铺满整个窗口 */
SDL_RenderCopy(g_renderer, g_texture, NULL, NULL);
```

| 软件 | 硬件 | 说明 |
|---|---|---|
| `WINDOW_SCALE 3`（256×224 → 768×672） | 512×480 的 DE 窗口 | 都是"把 256×240 放大到比它大的显示面" |
| `SDL_RenderCopy(..., NULL, NULL)` 整数倍放大 | 2× 复制（地址右移一位） | 软件放大要写两遍，硬件放大不写任何东西（`docs/modules/line-buffer-vga.md` 第 3.4 节） |
| 窗口 768 宽 vs 显示器 640 宽 → 由操作系统居中，两侧是桌面 | DE 窗口 512 宽 vs 显示器 640 宽 → 每侧 64 像素黑边 | 同一个"显示面比图像大"的事实，软件交给窗口管理器，硬件自己算常数 |
| 窗口 672 高 vs 显示器 480 高 → 上下也是桌面 | DE 窗口 480 高 = 显示器 480 高 | 纵向不浪费，两侧浪费 |

**这就是 `DE_X0=64` / `DE_X1=576` 的来历**：640 − 512 = 128 = 64 + 64，正好对称。`docs/modules/line-buffer-vga.md` 第 5.2 节当时写的是"横向还差 128 像素，黑边不需要 RAM，用 DE 窗口的常数表达即可"——本模块就是这个"常数"。

### 7.3 帧呈现与消隐

| 软件 | 硬件 | 说明 |
|---|---|---|
| `swap(front, back)` + `SDL_UpdateTexture` + `RenderPresent` | `frame_pulse` | 同一个"一帧结束"的事件 |
| blit 顺序遍历整帧，行边界在同一个循环里 | `vcount` 自由运行 + `line_read_start` 逐行握手 | 软件不需要握手，硬件需要（`docs/modules/line-buffer-vga.md` 第 2.2 节） |
| 帧末一次性交换前后台，撕裂不可见 | 行边界 ping-pong，行内不可能撕裂 | `docs/modules/line-buffer-vga.md` 第 5.4 节 |
| 窗口外的桌面像素由系统画 | 消隐期 `rgb565` 强制 0 | `docs/hardware/05-vga-lcd.md` 第 1.2 节："显示区域外的 RGB 输出为 0 可以减少无意义切换" |

`frame_pulse` 落在 `(799,524)`——**一帧的最后一个像素**，位于垂直消隐（490..524 行全黑）里，是下游做交换/回填/计数最安全的时刻；下一个 `ce` 沿就是 `(0,0)`。若把脉冲放在 `(0,0)`，那一拍的像素已经被锁存，任何以它为触发点的交换都会晚一个像素生效。

### 7.4 一句话总结这张表

软件侧的 `continue`、`WINDOW_SCALE`、`SDL_RenderPresent` 在硬件侧分别对应 DE 的纵向窗口、DE 的横向窗口加 2× 复制、`frame_pulse`。**没有任何一个对应"存一帧"**——这是本模块和 `nes_video_scaler` 的分界线。

---

## 8. 复位之后画面从哪来（与行缓冲拼接时的责任划分）

本模块对上只要求一件事：**`px_valid` / `px_rgb565` 在正确的拍上给出正确的那一行**。它不检查上游有没有准备好，只在没准备好时输出黑。据此划分责任：

| 情况 | 现象 | 谁负责 |
|---|---|---|
| strobe 准时到达（`hcount=63` 时给出） | 整行 512 像素正常 | — |
| strobe 迟到 | 该行前半截黑、后半截正常 | 顶层：必须等到行数据就绪才能发 strobe |
| strobe 没来 | 整行 512 像素全黑，`de` 仍为高 | 同上 |
| `px_valid` 出现空洞 | 对应像素黑，**流不暂停**（后面的像素不前移） | 上游：`px_valid` 是"打洞"，不是"停一拍重发" |

`nes_line_buffer_vga` 的 `line_read_start` 出现在它自己 `read_x=0` 的那一拍，而它什么时候开始读一行由 toggle 握手决定，**与 VGA 光栅的相位无关**。因此顶层不能把它的 `line_read_start` 直接接到本模块：必须加一层相位适配——判断 `hcount == DE_X0-1` 时才把 strobe 送给本模块，并用 `line_read_sync`（它与第一个有效像素同拍为高）确认这一次 strobe 落在了预期的坐标上。仓库里目前没有任何顶层实例化这两个模块，所以这层适配还没有代码。

---

## 9. 验证状态

`tb/video/tb_nes_vga_timing.v` 用 `$fatal` 逐拍断言覆盖 8 组检查（清单与运行方式见 `tb/video/README.md` 第 3 节）：

1. **复位**（`test_reset_contract`）：`reset` 期间九个输出全为 0；释放后 `ce=0` 且输入持续给 `FFFF`/strobe 时仍然全为 0。
2. **帧中复位**（`test_reset_mid_frame`）：扫描中间（`de=1`、像素非 0）在 `ce=0` 下拉复位，下一拍全部归零，光栅归位到 `(0,0)`，第 0 行重新从源像素 0 开始。
3. **`ce` 冻结**（`test_ce_freeze`）：非零状态下冻结 16 拍，九个输出逐位不变（像素不得变成 `FFFF`、strobe 不得被采纳）；恢复后流不重复也不跳列；**冻结期间呈现的 strobe 被丢弃**而不是延后执行（该行 512 个像素保持全黑）。
4. **缺像素与缺行首**（`test_missing_pixels`）：三个 `px_valid` 空洞（第 5、6、511 列）各自输出黑、`de` 保持高、`active_pixels` 为 0，且空洞**不移动**后面的像素；整行不发 strobe 时 512 个像素全黑而 `de` 仍为高，下一行恢复正常。
5. **`line_read_start` 对齐**（`test_line_read_align`）：`(64,y)` 是源列 0、`(575,y)` 是源列 511；行中间打 strobe 会把流重新归位到该坐标且**不动** `hcount`/`vcount`。
6. **行末 strobe**（`test_last_pixel_strobe`）：呈现给 `x=799` 的 strobe 会被回声，但行末清零立刻抹掉它，下一行仍然全黑。
7. **行首 strobe**（`test_zero_strobe`）：呈现给 `x=0` 的 strobe 赢过行末清零，整行保持对齐（源在 x=0 归位，所以可见窗口看到的是第 64 列起）。
8. **整帧**（`test_full_frame`）：840200 拍连续逐拍比对，每拍校验 9 个输出与坐标序列；每帧 96 拍 hsync、3 行 vsync、245760 个有效像素，`frame_pulse` 间隔恰好 420000 拍（= 525 行），并逐拍检查 23 个硬编码地标（656/751/752、63/64/575/576、489/490/492/493、479/480、524 等）。

作为置信度检查，对 RTL 的**临时副本**（仓库里的 RTL 未被修改）做了 17 处定向变异，**17 处全部被立刻抓到**，明细见 `tb/video/README.md` 第 3 节。

---

## 10. 参考

- 行为权威：VGA 640×480@60Hz 的时序规范（800×525、HS 96、VS 3 行、25 MHz → 59.52 Hz），与 `docs/hardware/05-vga-lcd.md` 第 1 节的厂商例程一致，除场同步取 3 行。
- 板级与极性：`docs/hardware/05-vga-lcd.md`（时序、同步极性待上板验证、RGB565 位分配、DE 模式的 LCD 对比、撕裂与架构选项）。
- 像素来源：`docs/modules/line-buffer-vga.md`（行缓冲合同、`read_x` 与 `read_rgb565` 同拍、2× 复制、ping-pong、overrun 限制）、`docs/modules/video-scaler.md`（整帧版本，本模块**不使用**）。
- CDC 与门控口径：`docs/hardware/03-clock-reset-cdc.md`。
- 软件结构观察：`[源码观察]` `.slim/clonedeps/repos/caseif__cNES/src/renderer.c`（`VIEWPORT_TOP/BOTTOM`、`SDL_CreateWindow` 的 `WINDOW_SCALE`、`submit_frame` 的 `continue`、`SDL_RenderPresent`）、`src/renderer.h`（`WINDOW_SCALE 3`）。这只是"别人怎么写"的观察，不是规格。
