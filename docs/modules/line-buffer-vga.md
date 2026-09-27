# 视频行缓冲：软件 framebuffer `y++`/blit 与硬件双 bank 行乒乓的对应

本文说明 `rtl/nes_core/video/nes_line_buffer_vga.v` 的接口合同、数据流和**它现在到底是什么、又不是什么**，并回答一个教学问题：

> 一个用 C 写的软件模拟器（PPU 每 dot 往 `framebuffer[x][y]` 写一个颜色，帧末一次性 `submit_frame()` + `SDL_UpdateTexture`）和一个用 Verilog 写的硬件实现（2 bank 行缓冲 + toggle 握手 + 2× 水平复制 + 垂直重复），是不是**同一套行为的两种写法**？

结论：**方向是同一套，但硬件这一侧只保留了"一帧"里最不可省的一小块——一行。** 软件模拟器必须存下**整帧** 256×240，因为它在帧末才 blit；硬件不能等，因为显示端有自己不可暂停的时序，所以它只存**两行**，用一次握手把"生成侧"和"显示侧"在**行边界**上解耦。代价是：硬件这条路上**没有帧的概念**，一行写完就必须立刻被读走，否则下一行会覆盖它。

`docs/modules/video-scaler.md` 讲的是**整帧 frame buffer** 版本（120 KiB，在 EP4CE10 上装不下）。本文讲的是**行缓冲**版本（1 KiB，装得下），并且明确指出：**当前不使用完整 framebuffer**（第 6 节）。

---

## 1. 术语与数据规模

| 名称 | 规模 | 说明 |
|---|---|---|
| 源分辨率 | 256 × 240 = 61,440 像素 | NES 可见区，每像素 1 个 4 位调色板索引 |
| 本模块缓冲 | 2 bank × 256 × 16 bit = **8,192 bit = 1 KiB** | 只存 2 行，存的是查表后的 RGB565 |
| EP4CE10 片上存储 | 423,936 bit ≈ 51.75 KiB | Fitter 报告数字，见 `docs/hardware/01-ep4ce10-board.md` 第 1.1 节 |
| 对比：整帧 frame buffer | 61,440 × 16 bit ≈ 120 KiB | `nes_video_scaler.v` 的做法，**装不下** |
| 2 倍输出（水平） | 512 像素/行 | 靠**地址右移一位**，不占额外存储 |
| 2 倍输出（垂直） | 480 行/帧 | 靠**把同一 bank 读两遍**，不占额外存储 |

**1 KiB vs 120 KiB 是本文最重要的一条结论。** 行缓冲把"整帧"降级成"整行"，视频侧的片上存储需求从 120 个 M9K 块降到 **1 个 M9K 块**（512×16 = 8192 bit，正好一个 M9K）。代价从"存储不够"变成了"**时序不能 overrun**"（第 5.5 节）。

---

## 2. 软件模拟器怎么显示一帧

### 2.1 两阶段模型（`[源码观察]`）

`.slim/clonedeps/repos/caseif__cNES/` 是这种结构的典型：

```c
/* src/system.c:606 —— 生成侧，每 dot 一次 */
void system_emit_pixel(unsigned int x, unsigned int y, const RGBValue color) {
    set_pixel(x, y, color);
}

/* src/renderer.c:147 —— 写进整帧缓冲，注意下标是 [x][y] */
void set_pixel(unsigned int x, unsigned int y, const RGBValue rgb) {
    g_pixel_buffer[x][y] = rgb;
}

/* src/ppu.c:1163 —— 这就是硬件要模仿的 "y++" */
if (++g_scanline_tick >= CYCLES_PER_SCANLINE) {   /* 341 */
    g_scanline_tick = 0;
    if (++g_scanline >= g_scanline_count) {        /* 262 */
        g_scanline = 0;
        g_odd_frame = !g_odd_frame;
        system_submit_frame();                     /* 帧末 blit */
    }
}

/* src/renderer.c:151 —— 帧末一次性遍历整帧，顺手裁掉上下黑边 */
void submit_frame(void) {
    for (x...) for (y...) {
        if (y < VIEWPORT_TOP || y > VIEWPORT_BOTTOM) continue;   /* 8 / 231 */
        ... (*g_pixel_buffer_back)[y - VIEWPORT_TOP][x] = ...;
    }
    swap(front, back);  memcpy(...);
}

/* src/renderer.c:172 —— 显示侧，每帧一次 */
void draw_frame(void) { SDL_UpdateTexture(...); SDL_RenderCopy(...); SDL_RenderPresent(...); }
```

三个关键事实：

1. **写入侧已经查好了调色板**（`RGBValue` 而不是 4 位索引）。和硬件把 `palette_rgb565()` 放在写口是同一件事。
2. **`y++` 是控制流的一部分**，不是对外信号。行边界不需要通知任何人，因为 blit 是同一段代码在同一个线程里顺序跑的。
3. **`submit_frame()` 里的 `continue` 就是软件版的"黑边"**：`VIEWPORT_TOP=8`、`VIEWPORT_BOTTOM=231`，240 行里只有 224 行被 blit。硬件里这件事由 VGA 时序发生器的 DE 窗口做（`docs/hardware/05-vga-lcd.md`）。

### 2.2 关键性质：软件侧**不需要**握手

软件模拟器在帧末 blit 时，整个 framebuffer 已经是"最终画面"，遍历是**从左到右、从上到下的顺序内存遍历**。行边界、帧边界都在**同一个线程的同一个循环**里，不需要跨时钟域通知。

硬件有两个自由运行的时钟（PPU 侧、VGA 侧），所以行边界必须变成一个**显式信号**，这就是 `line_done` / `line_ready_toggle`。**`line_ready_toggle` 就是硬件版的 `y++`。**

---

## 3. 本模块的实际合同

### 3.1 写口：PPU 侧

```verilog
input  wire        wr_pixel_valid;
input  wire [7:0]  wr_x;
input  wire [3:0]  wr_index;
```

在 `wr_ce && wr_pixel_valid` 的那个 `posedge wr_clk`，模块执行：

```verilog
line_mem[{wr_bank, wr_x}] <= palette_rgb565(wr_index);
```

| 软件 | 硬件 | 差别 |
|---|---|---|
| `g_pixel_buffer[x][y] = rgb` | `line_mem[{wr_bank, wr_x}] <= pal(wr_index)` | 硬件**没有 y**：y 被 bank 选代替，一行满了就翻 bank |
| `++g_scanline_tick >= 341` | `wr_x == 255` | 硬件只数**有效像素**（`wr_pixel_valid`），软件数 dot |
| 帧末 blit | 无 | 行缓冲**没有帧**，见第 6 节 |

`{wr_bank, wr_x}` 是 9 位拼接地址，语义就是 `wr_bank * 256 + wr_x`，所以 `line_mem` 是 512 项 = 2 bank × 256。**"y" 只剩 1 位，而且这 1 位是 ping-pong 状态，不是坐标。**

### 3.2 `line_done` 与 `line_ready_toggle`：硬件版的 `y++`

```verilog
assign wr_line_end = wr_pixel_valid & (wr_x == LINE_LAST_X);   /* 255 */
...
if (wr_line_end) begin
    line_done         <= 1'b1;
    line_ready_toggle <= ~line_ready_toggle;
    wr_bank           <= ~wr_bank;
end
```

| 信号 | 含义 | 宽度与性质 |
|---|---|---|
| `line_done` | 一行 256 个像素收齐了 | 单周期脉冲，只在 `wr_ce` 为高时更新 |
| `line_ready_toggle` | **这一行可以读了** | 1 bit **电平**，不是脉冲 |
| `wr_bank` | 下一个像素写进哪个 bank | 1 bit，每行翻转一次 |

**为什么是 toggle 而不是脉冲？** 因为读端可能比写端慢。一个单周期脉冲在读端 `rd_ce` 恰好为低的沿上就会**整个丢掉**，而且丢了之后无法察觉。toggle 是**电平**：只要读端还欠着一次翻转，它下次采样就看得见。代价是 toggle **分不清"欠一次"和"欠两次或更多"**（第 5.5 节）。

`tb_nes_line_buffer_vga.v` 的 `wr_line` task 逐像素断言：`line_done` 只在 `x=255` 出现、`line_ready_toggle` 只在 `x=255` 翻转、两个实例的这两个信号永远一致；`all_reset` 断言复位后 `wr_bank` 归 0；`test_reset_contract` 断言 `wr_ce=0` 时 `x=255` 也不完成一行。

### 3.3 双 bank 乒乓：为什么 2 行就够

```text
写端：  ──写 bank0(256 px)──┬──写 bank1(256 px)──┬──写 bank0──
                            │                    │
                        toggle 翻转          toggle 翻转
                            │                    │
读端：                    ──读 bank0(1024 rd_ce)─┴──── idle ────
                            ↑                        ↑
                     读端落后写端不超过 1 行，读的就是"刚写完"的那一行
```

读端在 `toggle` 到来时读**当前 `rd_bank`**，读完 1 行（或 2 遍）后翻转 `rd_bank` 并回到 idle。写端在同一时刻已经翻到另一个 bank 去了。**两个 bank 永不重合**，这就是"写读同时不冲突"的全部内容。

TB 用两种方式钉它：

1. **功能检查**：`pat_idx(x, l) = (x + 7l + 3) mod 16`，每一行的图样**互不相同**，所以"读到了正在被写的那一行"会立刻在颜色上暴露。`test_ping_pong` 连续写 8 行（中途两次拉低 `wr_ce`），逐像素校验顺序为 0,0,1,1,…,7,7。
2. **结构检查**：`wr_line` 断言每写完一行 `dut.wr_bank` 一定翻转；monitor 在每次**源行**起始处断言 `dut.rd_bank` 一定翻转（复位后的第一行必须是 bank 0）。注意 bank 是**每源行**翻一次，不是每遍翻一次。

`test_ping_pong` 还统计"写口有效且读口有效"的重叠周期数并断言 ≥ 3000（实测 7114），**防止这条测试因为写读根本没同时发生而空过**。

### 3.4 2× 水平复制与读延迟对齐

```verilog
assign rd_next_x = rd_x_cnt + 9'd1;
...
rd_mem_q <= line_mem[{rd_bank, rd_next_x[8:1]}];   /* 512 个输出像素 → 256 个源像素 */
```

`rd_next_x[8:1]` 就是 `rd_x_cnt[8:1]` 右移一位，**这就是全部的 2 倍水平放大**：没有乘法器、没有插值、没有第二份缓冲。

**但这里的 `+1` 不是可选的，它是"读延迟对齐"。** BRAM 是同步读：地址在沿上给出，数据在**下一个**沿出来。而 `read_x` 直接取当前 `rd_x_cnt`。两者差一拍，所以地址必须用**下一个**计数器的值取：

| 输出 | 地址 | 得到的源像素 |
|---|---|---|
| `read_x = 0` | 行首预装 `line_mem[{rd_bank,0}]` | 0 |
| `read_x = 1` | `(0+1)>>1 = 0` | 0 |
| `read_x = 2` | `(1+1)>>1 = 1` | 1 |
| `read_x = 3` | `(2+1)>>1 = 1` | 1 |
| … | … | … |
| `read_x = 511` | `(510+1)>>1 = 255` | 255 |

**合同：`read_x = c` 时 `read_rgb565` 一定等于 `line_mem[rd_bank][c>>1]`，两者描述同一个源像素。** 这和 `nes_video_scaler` 的"`out_pixel_x` / `out_pixel_y` / `rgb565` 对齐"是同一条合同。

> 这一条是本次改动**修掉的既有缺陷**：`rd_mem_q <= line_mem[{rd_bank, rd_x_cnt[8:1]}]` 配 `read_x <= rd_x_cnt` 时，数据比坐标慢一个源像素，整幅图横向错开 1 像素，2×2 复制块被切成 1+1 的错位对。TB 的第一个颜色断言就是为它写的（`read_x 2 got 310c expected 4008`）。`docs/modules/video-scaler.md` 第 3.3 节记录的"三个输出对齐"是本合同的文档出处。

`tb_nes_line_buffer_vga.v` 对每个像素检查坐标序列、颜色 `pal_ref(pat_idx(read_x>>1, line))`，并且**单独**检查 `read_x` 为奇数时颜色必须等于前一个像素（2× 复制的直接表达）。

### 3.5 `REPEAT_LINE`：垂直 2× 是"免费"的，代价是读端时间

```verilog
parameter integer REPEAT_LINE = 1;
...
if (rd_line_end) begin                     /* read_x == 511 */
    rd_x_cnt <= 9'd0;
    if (REPEAT_LINE != 0 && !rd_second) begin
        rd_second <= 1'b1;
        rd_mem_q  <= line_mem[{rd_bank, 8'd0}];   /* 同一 bank 立刻再读一遍 */
    end else begin
        rd_second <= 1'b0;
        rd_bank   <= ~rd_bank;                    /* 这一源行读完了才换 bank */
        rd_active <= 1'b0;
    end
end
```

`rd_second` 是"当前这一遍是不是第二遍"的 1 bit 状态。行为：

| `REPEAT_LINE` | 一个源行的输出 | `line_read_start` 次数 |
|---|---|---|
| `1`（默认） | 2 × 512 = 1024 个输出像素 | **2 次**（每一遍的 `read_x=0` 各一次） |
| `0` | 1 × 512 = 512 个输出像素 | 1 次 |

`REPEAT_LINE=0` 时 `rd_second` 恒为 0，第一个条件恒假，走的分支和参数化之前**逐位相同**。

**软件对照**：软件模拟器做 240→480 的垂直放大，只能在 `submit_frame()` 里写两遍（`dst[2y]` 和 `dst[2y+1]`）或者交给 SDL 的 scale 参数——**都要把整帧缓冲写两遍**。硬件这里**一个字节都没多写**，只是把已经在手里的那一行**读了两遍**。240 源行 × 2 = 480，正好是 VGA 的有效行数（`docs/hardware/05-vga-lcd.md`）。

**代价必须写清楚**：写一行是 256 个 `wr_ce` 周期，读一行变成 1024 个 `rd_ce` 周期。**读端速率必须 ≥ 写端速率的 4 倍**，否则 toggle 会 overrun。NTSC 的 PPU 像素时钟是 341 × 262 × 59.94 ≈ **5.35 MHz**，4 倍是 **21.4 MHz**，低于 25 MHz 的 VGA 像素时钟——**数字上可行，但余量不大**。TB 用 5 倍（`wr_clk` 50 ns / `rd_clk` 10 ns）留出余量，并在 `drain` 里断言没有 stall。

重复遍的边界也需要**预装**：行末沿上必须把 `rd_mem_q` 重新装成 `line_mem[{rd_bank,0}]`，否则第二遍的第 0 个像素会拿到第一遍的残留（上一遍的 `mem[255]`）。TB 的颜色断言正好覆盖这一点（变异 `rd_mem_q <= 16'd0` 会在 `read_x 0` 处失败）。

### 3.6 跨时钟域：toggle + 两级同步器

```verilog
toggle_meta <= line_ready_toggle;   /* 第 1 级 */
toggle_sync <= toggle_meta;         /* 第 2 级 */
toggle_new  = toggle_sync ^ toggle_seen;
```

`line_ready_toggle` 在 `wr_clk` 域产生，在 `rd_clk` 域被采样，必须过两级同步器。`toggle_seen` 记住"我已经消费过哪一次翻转"，`toggle_new` 就是"有一行新数据"。

**时序合同**：一次 `wr_clk` 沿翻转 toggle 之后，读端**不可能**在同一个 `rd_clk` 沿就开始读；最早也要 3 个 `rd_ce` 沿之后（2 级同步 + 1 次接受），第 4 个沿才出现第一个有效像素。TB 把这条钉成时间断言：

| 条件 | 断言 |
|---|---|
| 任何情况下 | 首行像素 − 写端翻转 ≥ 30 ns（3 个 `rd_clk`） |
| 读端空闲且 `rd_ce=1` 时 | ≤ 60 ns（4 个 `rd_clk` + 相位抖动） |

去掉同步器（`toggle_sync <= line_ready_toggle`）会得到 28 ns，被第一条抓住；把同步器冻死（`toggle_meta <= toggle_meta`）会让读端永远不动，被 `drain` 的超时抓住。

`rd_reset` 时 `toggle_meta` / `toggle_sync` / `toggle_seen` **全部**同步到 `line_ready_toggle` 的当前值，所以复位本身**不会**产生一次伪行（`toggle_new = 0`）。这是"reset 不产生伪行"的实现依据。

### 3.7 `wr_ce` / `rd_ce`：两个独立的时钟使能

| 信号 | 关掉之后的效果 |
|---|---|
| `wr_ce=0` | 不写 `line_mem`、`line_done` 不更新、`line_ready_toggle` 不翻转、`wr_bank` 不动 |
| `rd_ce=0` | 整个读端冻结：同步器、`rd_bank`、`rd_x_cnt`、`rd_mem_q`、四个输出寄存器全部保持 |

两个 `always` 块都是 `if (reset) ... else if (ce) ...`，所以**复位优先于使能**。TB 的 monitor 在每个 `rd_clk` 沿保存四个读端输出的影子值，`rd_ce=0` 时逐拍比对——`test_rd_ce_gate` 在 `read_x=201`（正在扫描中，颜色非零）时冻结 12 个 `rd_clk` 周期，把"冻结"钉成显式断言而不是"恰好没动"。

`rd_ce=0` 期间写端可以继续翻 toggle；`rd_ce` 恢复后读端会消费**积压的那一次翻转**。但如果积压了 2 次以上（第 5.5 节），中间的行就被静默跳过。TB 因此在 `rd_ce=0` 期间**只写 1 行**，并在恢复后断言恰好消费了 1 次。

### 3.8 复位合同

两个**同步**复位，各自独立：

| 复位 | 清什么 | 不清什么 |
|---|---|---|
| `wr_reset` | `wr_bank`、`line_ready_toggle`、`line_done` | `line_mem` |
| `rd_reset` | `toggle_meta`、`toggle_sync`、`toggle_seen`、`rd_bank`、`rd_active`、`rd_second`、`rd_x_cnt`、`rd_mem_q`、`frame_line_valid`、`line_read_start`、`read_x`、`read_rgb565` | `line_mem` |

**`line_mem` 不在复位列表里**，和 `nes_video_scaler` 的 `frame_mem` 一样是 BRAM 的性质。这意味着：复位**不会**把画面清黑，`line_mem` 里留着上一次的内容。TB 明确测了这一点（虽然是通过"复位后必须先写满一整行才能读到正确数据"间接测的，见第 7 节覆盖不到的地方）。

`rd_reset` 中途拉高会**丢弃正在扫描的那一行**（`rd_active` 清 0），但 `toggle_seen` 已经消费掉了那一次的翻转，所以不会重复读；`rd_bank` 被拉回 0，因此**只有当下一行是偶数行时**读写 bank 才对齐。`test_rd_reset_mid_line` 故意在读**奇数行**（bank 1）的中途复位：复位把 `rd_bank` 拉回 0，而下一行是偶数行（bank 0），于是**自动重新对齐**，随后再写 4 行验证顺序和数据都正确。这是一个刻意设计的性质，也是一个必须写进合同的限制。

---

## 4. 输出接口的形状

| 信号 | 含义 | 性质 |
|---|---|---|
| `frame_line_valid` | 当前这一拍是有效输出像素 | 一整行连续为高，行间为低 |
| `line_read_start` | **这一遍**的第一个像素（`read_x=0`） | 单周期脉冲，每个重复遍各一次 |
| `read_x` | 行内输出列号 0..511 | 空闲时被停在 0 |
| `read_rgb565` | 16 bit 像素 | 空闲时是残留值，**不可用** |

输出**没有**帧级信号，也**没有**"这是第几遍"的信号。下游想区分两遍，只能数 `line_read_start`（或用 `frame_line_valid` 的低电平当行间隙）。

---

## 5. 与 VGA 时序的对应，以及缺什么

### 5.1 对应关系表

| 软件模拟器 | 本模块 | 真实 VGA（`docs/hardware/05-vga-lcd.md`） |
|---|---|---|
| `g_pixel_buffer[x][y]` 61,440 项 | `line_mem` 512 项 | — |
| `++g_scanline_tick >= 341` | `wr_x == 255` | 行计数 0..799 |
| `++g_scanline >= 262` → `submit_frame()` | **不存在** | 场计数 0..524 |
| `submit_frame()` 里 blit 整帧 | 一个源行被读 2 遍（1024 拍） | 有效区 640 宽 |
| `if (y < 8 \|\| y > 231) continue;` | **不存在** | 场前 10 + 场后 33 |
| `SDL_RenderPresent()` | `line_read_start` 脉冲 | 场同步 2 行 |
| 窗口缩放 `WINDOW_SCALE` | **不存在** | — |

### 5.2 横向还差 128 像素

本模块输出 **512** 列，VGA 有效区是 **640** 列。差 128 = 每边 64 像素黑边（640 = 64 + 512 + 64）。黑边**不需要 RAM**，用 DE 窗口的常数表达即可。

### 5.3 完全没有 VGA 时序发生器

没有 `hsync` / `vsync` / `de`，没有消隐期输出黑线的逻辑。`read_rgb565` 在行间会残留上一遍的最后一个像素，**必须**由下游在 `frame_line_valid=0` 时忽略或置黑。TB 显式断言 `frame_line_valid=0` 时 `read_x` 停在 0（`read_rgb565` 不检查，因为它是残留值）。

### 5.4 撕裂：行缓冲解决了大部分，但没解决全部

`nes_video_scaler` 是单缓冲原地覆盖，必然撕裂。行缓冲**在行边界上把两侧解耦**：写端在读端扫描 bank 0 的时候写 bank 1，两者不重叠，所以**行内不可能撕裂**。剩下的问题是**行与行之间的接缝**：如果读端跟不上，toggle 会 overrun，被跳过的行就是撕裂的等价物（表现为"某一行显示的是更早的一行"）。第 5.5 条就是这个问题的边界。

### 5.5 没有背压：overrun 是本模块的硬限制

toggle 是 1 bit，**没有队列、没有 ready/valid、没有错误标志**。因此：

- 写端比读端慢 → 正常，读者会 idle 等 toggle。
- 写端比读端快，但领先**不超过 1 行** → 正常，ping-pong 正好抵消。
- 写端领先 **2 行或更多** → 读端只看到 toggle 的**净变化**，**中间的整行被静默跳过**，而且**没有任何信号表明这件事发生了**。

这正是"不存整帧"要付的钱。彻底解决需要：更多 bank（深度 = 最坏领先行数）、一个请求/应答握手（读者读完一行必须应答，写端才允许翻 bank），或者退回整帧缓冲。当前接口**三者都没有**，`tb_nes_line_buffer_vga.v` 通过 5 倍时钟比保证测试里永不 overrun，但这是**测试环境的性质，不是模块提供的保护**。

### 5.6 后续还需要补的

| 需要什么 | 为什么本模块没有 |
|---|---|
| VGA 时序发生器（800×525 + 96/48/640/16 + 2/33/480/10） | 显示侧时序是独立模块的职责，见 `docs/hardware/05-vga-lcd.md` |
| 640 宽 DE 窗口 + 左右各 64 像素黑边 | 纯常数，不需要存储 |
| 与 `nes_system` 顶层的连接 | 目前没有任何顶层实例化本模块（`rtl/nes_core/system/nes_system_v5.v` 里没有） |
| overrun 指示 | 见 5.5 |
| 帧级同步（"这一遍是第几帧"） | 行缓冲没有帧的概念 |

---

## 6. 当前不使用完整 framebuffer

这一点单独写出来，因为它是最容易被误读的地方。

| 问题 | 答案 |
|---|---|
| 有整帧缓冲吗？ | **没有。** `line_mem` 只有 512 项 = 2 行 = 1 KiB |
| 画面存在哪里？ | **不存。** 每一行在写完后立刻被读走 2 遍，然后 `wr_bank` 翻回去覆盖它 |
| 一帧的像素去哪了？ | **从来没被同时持有过。** 帧是一个**时间过程**，不是一个存储对象 |
| 那 CPU 要读回画面怎么办？ | 读不到。行缓冲是**纯显示通路**，没有 CPU 可见的端口 |
| 想回退到整帧？ | `nes_video_scaler.v` 就是那个版本，但它 120 KiB，EP4CE10 装不下（`docs/modules/video-scaler.md` 第 5.1 节） |
| 什么时候必须回到整帧？ | 需要**缩帧截图**、**回退到 CPU 侧图像处理**、或者**显示端时序不可预测**（例如要跑在任意分辨率的 LCD 面板上）的时候 |

行缓冲能成立的全部前提是：**显示端的时序是可预测的，行边界可以握手**。VGA 恰好满足这两条（800×525 是固定的）。这也是 `docs/hardware/05-vga-lcd.md` 把"行缓冲"列为首选方案的原因。

---

## 7. 验证状态

`tb/video/tb_nes_line_buffer_vga.v` 用 `$fatal` 断言覆盖 4 组检查（详细清单和运行方式见 `tb/video/README.md`）：

1. **复位与 `wr_ce` 门控**（`test_reset_contract`）：无写入时读端 40 个周期不产生任何有效像素；12 个空闲写周期无脉冲；`wr_ce=0` 时 `x=255` 也不完成一行；100 个被门控的写像素不产生任何读行。
2. **`rd_ce` 门控与重复遍**（`test_rd_ce_gate`）：写 100 像素后 `wr_reset` 必须丢弃残行且不产生 toggle；一行在 `rd_ce=0` 期间写完也不许漏过去；在 `read_x=201` 冻结 12 个周期，四个输出逐拍不变；恢复后恰好 2 遍（`REPEAT_LINE=1`）/1 遍（`REPEAT_LINE=0`）。
3. **并发 ping-pong**（`test_ping_pong`）：8 行并发，两个 `wr_ce` 空洞，逐像素校验行序 0,0,1,1,…,7,7、颜色、2× 复制、坐标序列；`line_read_start` 计数 16/8；写读重叠 ≥ 3000 拍（实测 7114）。
4. **读端中途复位**（`test_rd_reset_mid_line`）：在读奇数行中途复位，四个输出清零、200 个周期内不自恢复、被丢弃的行不重复读、bank 重新对齐，随后 4 行数据正确。

同时实例化**两个**模块（`REPEAT_LINE=1` 和 `REPEAT_LINE=0`），共用同一套写口激励，两条读通路各有一个独立模型，所以"参数关掉重复"和"参数打开重复"是同一次运行里同时验证的。

已知覆盖不到的地方：

- **`line_mem` 的复位行为没有直接测**。它需要层次化引用或读回接口，TB 选择不断言"复位后内容保留"，只断言"复位后必须重写整行才能读对"。
- **同址同拍的写读冲突没测**。ping-pong 结构上排除了它（写 bank X 时读端在 bank ~X），但没有直接断言两个 bank 不相等（那个断言在行末沿附近会因为 bank 翻转的时序而误报，见 `tb/video/README.md`）。
- **overrun 没测，因为模块不支持**。toggle 丢行的行为既没有接口暴露，也没法在"永不 overrun"的时钟比下测出来。
- **只有 16 种颜色**参与颜色校验，因为 `wr_index` 只有 4 位（和 `nes_video_scaler` 同一个限制）。
- **图样周期是 16**，源 x 偏移 16 的错误靠颜色查不出来（靠坐标序列抓）。

作为置信度检查，对 RTL 的**临时副本**（仓库里的 RTL 未被临时修改）做了 7 处定向变异，**7 处全部被立刻抓到**：

| 变异 | 第一次失败 |
| --- | --- |
| 去掉重复（`if (1'b0)`） | `the read side did not reach 1/1 lines, it stalled at 0/1` |
| 地址退回 `rd_x_cnt[8:1]` | `inst 0 rgb565 at line 0 read_x 2 got 310c expected 4008` |
| 同步器退化成 1 级 | `inst 0 read a line 28 ns after the write toggle, the 2 flip flop synchronizer is bypassed` |
| 同步器冻死（`toggle_meta <= toggle_meta`） | `the read side never reached read_x=200` |
| `line_read_start` 改成 `rd_x_cnt == 1` | `inst 0 line_read_start got 0 at read_x 0, expected 1` |
| 重复遍不预装 `mem[0]` | `inst 0 rgb565 at line 0 read_x 0 got 0000 expected 310c` |
| `rd_bank` 不翻转 | `inst 0 rgb565 at line 1 read_x 0 got 310c expected 5b20` |

`tools/sim_all.ps1` 没有 line buffer 目标，ModelSim 也没有对应的 `run_video_tb.do`；这两个脚本不在本任务的写入范围内，没有改。

---

## 8. 参考

- 行为权威：NESdev PPU 文档（可见区 256×240、每像素 4 位调色板索引、341×262 dot）。
- 板级数字：`docs/hardware/01-ep4ce10-board.md`（423,936 bit 片上存储）、`docs/hardware/03-clock-reset-cdc.md`（两级同步器）、`docs/hardware/05-vga-lcd.md`（800×525 时序、640×480 有效区、撕裂与架构选项）。
- 对照模块：`docs/modules/video-scaler.md`（整帧版本，120 KiB）、`docs/hardware/04-memory-and-fifo.md`（带宽口径）。
- 软件结构观察：`[源码观察]` `.slim/clonedeps/repos/caseif__cNES/src/ppu.c`（`++g_scanline_tick >= 341` / `++g_scanline >= 262` / `system_submit_frame()`）、`src/renderer.c`（`set_pixel` 写整帧、`submit_frame` 裁剪并交换前后台、`draw_frame` 做 `SDL_UpdateTexture` + `RenderPresent`）。这只是"别人怎么写"的观察，不是规格。
