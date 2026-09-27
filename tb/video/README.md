# NES video testbenches

本目录有三个自检 testbench，都不下载 ROM、不读外部文件：

| testbench | 被测模块 | 规模 | 参数覆盖 |
| --- | --- | --- | --- |
| `tb_nes_video_scaler.v` | `rtl/nes_core/video/nes_video_scaler.v` | 整帧 frame buffer，256×240×RGB565 ≈ 120 KiB | 无参数 |
| `tb_nes_line_buffer_vga.v` | `rtl/nes_core/video/nes_line_buffer_vga.v` | 双 bank 行缓冲，2×256×RGB565 = 1 KiB | 同一次运行里同时验证 `REPEAT_LINE=1` 和 `REPEAT_LINE=0` |
| `tb_nes_vga_timing.v` | `rtl/nes_core/video/nes_vga_timing.v` | 无存储，800×525 时序，840200 拍逐拍比对 | 无参数（只跑默认 640×480@60Hz） |

前两个是同一件事的两种规模：都是"把 256×240 放大成 512×480 的像素流"，但一个存整帧、一个只存两行。EP4CE10 装不下前者、装得下后者，所以后者才是能进比特流的那条路。第三个不产生像素，只产生 800×525 的时序和 DE 窗口，是显示通路里唯一不碰像素数据的模块。设计文档分别在 `docs/modules/video-scaler.md`、`docs/modules/line-buffer-vga.md` 和 `docs/modules/vga-timing.md`。

---

# 1. `tb_nes_video_scaler.v`：整帧 scaler

`tb_nes_video_scaler.v` 是 `rtl/nes_core/video/nes_video_scaler.v` 的自检 testbench。它不下载 ROM、不读外部文件：写口就是 PPU 每 dot 送出的 `(in_pixel_x, in_pixel_y, in_pixel_index)`，读口就是 VGA 侧的像素流。

## 被测模块的实际行为

TB 是照着下面这几条**已实现**的合同写的，不是照着想象中的合同：

| 合同 | 实现位置 |
| --- | --- |
| 256×240 源像素，每像素一个 4 位调色板索引 | `frame_mem[{in_pixel_y, in_pixel_x}]`，共 61440 项 |
| 调色板在**写**的时候查成 RGB565 | `palette_rgb565(in_pixel_index)`，64 项 |
| 256 个 `pixel_valid` 脉冲 = 一行 | `line_count == LINE_LAST(255)` |
| 240 行 = 一帧 | `frame_line_count == FRAME_LAST(239)` |
| 读指针自由运行，512×480 环绕 | `scan_x` / `scan_y`，与 `line_ready`/`frame_ready` **完全无关** |
| 2×2 复制 | `mem_read_addr = {scan_y[8:1], scan_x[8:1]}` |
| 复位是**同步**复位，且不清 `frame_mem` | 两个 `always @(posedge clk) if (reset)` |

三个必须记住的时序细节：

1. **写和计数在同一个 `always` 沿**。`line_ready` 是寄存器输出，在第 256 个 `pixel_valid` 沿之后的**下一个**周期才为高。TB 在每次写的 `posedge + 1` 相位检查它。
2. **`out_pixel_x` / `out_pixel_y` 与 `rgb565` 是对齐的**。三个输出都从**同一个** `scan_x` / `scan_y` 当前值取，所以 `posedge + 1` 处采到的 `(out_pixel_x, out_pixel_y, rgb565)` 一定是同一个源像素 `(x>>1, y>>1)`。TB 全程依赖这一点。
3. **复位不清 `frame_mem`**。`test_reset_mid_frame` 明确把这一点钉成合同：复位前写 100 行，复位后第 110 行仍然是上一帧的内容。

## 时序纪律

TB 的信号变化都发生在 `posedge clk` 之后 `#1`：`in_pixel_*` 在被采样沿之前有完整建立时间，输出在沿之后 `#1` 采样。四个基础 task：

| task | 作用 |
| --- | --- |
| `apply_reset` | 拉高 `reset` 3 拍，释放，再空一拍，回到 `posedge+1` 相位 |
| `scan_start` | 只拉高 `reset` 1 拍后释放，把读指针对齐到 `(0,0)` 并让第一个输出像素就绪 |
| `write_pixel(sx, sy, ci)` | 置 `pixel_valid=1` 和输入，等一个 `posedge`，然后 `#1` |
| `write_frame(pat, idle_every, →line, →frame)` | 写满 240×256 个像素，逐像素检查两个 ready 脉冲的位置 |
| `scan_check(count, pat, mode, block, x0, y0)` | 从当前读指针位置线性走 `count` 个输出像素，检查坐标、颜色和 2×2 复制 |
| `check_source_pixel(sx, sy, pat)` | 把读指针开到指定源像素并检查它（用来看缓冲区留存） |

`scan_check` 走的是**连续像素流**，不是"跳到某个坐标"。所以 `test_palette_64` 里要先走 128 个像素（源 x=0..63 的上半行），再空走 384 个（源 x=64..127..255），再走 128 个到输出行 1 —— 同一批 64 个调色板值在输出行 0 和行 1 各出现一次，因为 `1 >> 1 == 0`。

## 参考模型

调色板表在 TB 里独立抄了一份 `pal_ref`（64 项，Verilog-2001 只能用无位宽的 `'h10:`..`'h3F:` 做 case 标签，4 位装不下）。图样函数：

```
pattern_index(x, y, 0) = (x + 3*y + 3) mod 16
pattern_index(x, y, 1) = (x + 5*y + 7) mod 16
```

两个图样对 x 和 y **不交换对称**，所以 x/y 读写地址搞反会立刻被抓到。期望色 `pal_ref(pattern_index(out_x >> 1, out_y >> 1, pat))`。

## 断言覆盖

`tb_nes_video_scaler.v` 使用 `$fatal` 断言并逐行打印 PASS，覆盖：

1. **复位**（`test_reset_initial`）：冷复位后 `out_pixel_x/y == 0`、`line_ready`/`frame_ready` 为低；随后把 `reset` 连续拉高 5 拍，四个输出一个都不许动（这个模块是同步复位，输出只在时钟沿更新）。释放后第一拍读指针必须落在原点。
   注意 `apply_reset` 结束时已经放过一个无复位沿，此时 `rgb565` 是**未初始化**的 `frame_mem[0]`（仿真里是 `xxxx`），所以复位后不能检查 `rgb565`——只有复位**保持**期间才能检查它被清成 0。
2. **64 项调色板**（`test_palette_64`）：往源行 0 写 64 个像素，索引 0..63。写完必须**没有**任何 ready 脉冲（64 < 256）。然后读输出行 0 的前 128 个像素和输出行 1 的前 128 个像素，每个都必须等于 `pal_ref(x>>1)`，且 2×2 块内 4 个像素颜色完全一致。这一条把 64 项 RGB565 常量和"索引就是源 x"两件事一起钉死。
3. **写满 256×240**（`test_frame_a`）：61440 次 `pixel_valid`，其中每 7 次插入一个 `pixel_valid=0` 的空闲周期（证明计数的是**有效像素**而不是时钟）。逐像素断言 `line_ready` 只在 `x=255` 出现、不会连续两拍为高、`frame_ready` 必定与 `line_ready` 同时且只在 `x=255, y=239`。结束计数必须是 **line_ready = 240**、**frame_ready = 1**。空闲周期上还断言两个 ready 都为 0。
   空闲周期恰好会在第 1792 个像素（第 7 行末尾）之后插一次，也就是紧跟在一次 `line_ready` 脉冲后面——这一拍正好额外验证了 `line_ready` 是单周期脉冲。
4. **整帧读出**（`test_frame_a` 尾部）：`scan_start` 后连续走 **245760** 个输出像素（512×480），每个都检查坐标严格等于期望的 `x+1 / y+1` 环绕序列、颜色等于 `pal_ref(pattern_index(x>>1, y>>1, 0))`、2×2 块 4 个像素同色。走完必须正好回到 `(0,0)`。
5. **连续帧**（`test_frame_b` / `test_frame_c`）：再写两整帧，图样换成 `pat=1`，每帧都必须重新得到 240 / 1。frame B 之后完整重扫 245760 个像素并按 `pat=1` 校验（证明缓冲区是**原地覆盖**，读指针重新绕一圈看到的是新帧）。frame C 之后用 `check_source_pixel` 单点校验 `(0,0)`、`(255,239)`、`(128,64)`，把四角和帧中央钉死。
6. **帧中复位**（`test_reset_mid_frame`）：写 100 行（共 25600 个像素）后拉复位。复位必须清掉 `line_ready`/`frame_ready` 并把读指针归零；**缓冲区不清**——源像素 `(200, 110)` 仍然是 frame C 的 `pat=1` 值。复位释放后**再写一整帧**，仍然必须是 240 / 1（那 100 行残帧被整帧丢弃，不能和下一帧凑成一个 `frame_ready`）。
7. **读指针与写口解耦**（`test_read_pointer_free_running`）：读指针在 (0,0) 起步的同时，每拍写一个像素（300 拍，中途会撞上一次 `line_ready`）。每一拍读指针都必须精确 `+1`（x=511 时换行、y=479 时回到 (0,0)），且永不越出 512×480。写口和 ready 脉冲**不能**让读指针停一拍。
8. **只有 pixel stream，没有黑边**（`test_stream_geometry`）：逐行遍历 480 行 × 512 列，每一行必须从 `x=0` 开始、`y` 严格等于行号、x 严格等于列号，走完正好 245760 个像素并回到 `(0,0)`。这一条把"输出**只有** 512×480 的像素流，没有左右黑边、没有上下黑边、没有 blanking、没有 padding"写成显式断言。`test_read_pointer_free_running` 里还额外断言 `out_pixel_x > 511 || out_pixel_y > 479` 不成立。

顶部还有 `global timeout`（20 ms 仿真时间）兜底断言。

## 覆盖不到的地方

- **只有 16 种颜色参与全帧颜色校验**。写口 `in_pixel_index` 只有 4 位，模块本身最多只能存 16 种颜色；64 项调色板只在第 2 条里逐项查过。全帧校验靠的是坐标序列 + 2×2 复制 + 非交换图样，颜色只是叠在上面的一层。
- **图样的周期是 16**。`pattern_index` 取模 16，所以源 x 或 y 偏移 16 的错误靠颜色查不出来（会被坐标序列抓住）。这是 `in_pixel_index` 只有 4 位的直接后果。
- **同址同拍的写读冲突**：写沿和读沿撞上同一地址时，RTL 读到的是**旧值**（阻塞读在 NBA 之前求值）。第 7 条故意在扫描期间写像素，因此那条只查坐标不查颜色。

## 运行

在仓库根目录执行，输出放在临时目录，不向仓库写文件：

```powershell
$tmp = Join-Path $env:TEMP 'op_fpga_emu'
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
& 'C:\iverilog\bin\iverilog.exe' -g2001 -Wall -s nes_video_scaler -o (Join-Path $tmp 'nes_video_scaler_core.vvp') 'rtl\nes_core\video\nes_video_scaler.v'
& 'C:\iverilog\bin\iverilog.exe' -g2012 -Wall -s tb_nes_video_scaler -o (Join-Path $tmp 'tb_nes_video_scaler.vvp') 'rtl\nes_core\video\nes_video_scaler.v' 'tb\video\tb_nes_video_scaler.v'
& 'C:\iverilog\bin\vvp.exe' (Join-Path $tmp 'tb_nes_video_scaler.vvp')
```

核心是 Verilog-2001 源码，可以单独用 `-g2001 -Wall` elaborate（**零 warning**）。testbench 使用 `$fatal`，因此 Icarus 入口使用 `-g2012`，与仓库现有 controller/PPU/APU testbench 相同；TB 自身也是 `-Wall` 零 warning（64 项调色板表用无位宽 `'h10:`..`'h3F:` 标签，避免 `4'h10` 这种"给 4 位常量多写了 1 位"的告警）。

下面是本版本的完整期望输出，逐行对应一个 test task；vvp 退出码 0，仿真时间 14.922936 ms，实测运行约 3.9 s（一次要跑三整帧 + 三次 245760 像素的全流扫描）：

```text
VIDEO reset clears the read pointer, the pixel stream and the ready pulses PASS
VIDEO all 64 palette entries reach the 2x2 replicated read stream PASS
VIDEO full 256x240 frame A: 240 line_ready, 1 frame_ready, 512x480 stream PASS
VIDEO consecutive frame B overwrites the buffer and restarts the read pointer PASS
VIDEO third consecutive frame keeps 240 lines and one frame pulse PASS
VIDEO mid frame reset restarts the line counter, keeps the buffer and drops the partial frame PASS
VIDEO the read pointer never stalls on writes, line_ready or frame_ready PASS
VIDEO raster is exactly 512x480 with no border, no blanking and no padding PASS
PASS nes_video_scaler
```

任何 `$fatal` 命中会让 vvp 以非零退出码结束，并把检查名、实际值、期望值打印到 stdout。

作为置信度检查，对 RTL 的**临时副本**（仓库里的 RTL 未被修改）做了 5 处定向变异，**5 处全部被 testbench 立刻抓到**：

| 变异 | 第一次失败 |
| --- | --- |
| `mem_read_addr` 的 x/y 写反 | `rgb565 at output (2,0) source (1,0) got xxxx expected 00f1` |
| `LINE_LAST` 改成 254 | `line_ready asserted at source x=254 y=0, expected x=255` |
| `FRAME_LAST` 改成 238 | `frame_ready asserted at source x=255 y=238, expected x=255 y=239` |
| 调色板第 1 项 `00F1` 改成 `00F2` | `rgb565 at output (2,0) source (1,0) got 00f2 expected 00f1` |
| 读地址去掉垂直复制（`scan_y[7:1]`） | `rgb565 at output (0,2) source (0,1) got 310c expected 6080` |

`tools/sim_all.ps1` 没有 video 目标，ModelSim 也没有对应的 `run_video_tb.do`；这两个脚本不在本任务的写入范围内，没有改。

---

# 2. `tb_nes_line_buffer_vga.v`：双 bank 行缓冲

`tb_nes_line_buffer_vga.v` 是 `rtl/nes_core/video/nes_line_buffer_vga.v` 的自检 testbench。它同样不下载 ROM、不读外部文件，写口就是 PPU 送出的 `(wr_x, wr_index)`，读口就是 VGA 侧的 `(read_x, read_rgb565)` 像素流。

## 2.1 被测模块的实际行为

TB 是照着下面这几条**已实现**的合同写的，不是照着想象中的合同：

| 合同 | 实现位置 |
| --- | --- |
| 256 个 `wr_pixel_valid` 脉冲 = 一行 | `wr_line_end = wr_pixel_valid & (wr_x == 255)` |
| 一行收齐 → `line_done` 脉冲 + `line_ready_toggle` 翻转 + `wr_bank` 翻转 | 写端 `always` 的 `if (wr_line_end)` 分支 |
| 存储是 2 bank × 256 × RGB565 = 1 KiB | `line_mem[{wr_bank, wr_x}]`，512 项 |
| 调色板在**写**的时候查成 RGB565 | `palette_rgb565(wr_index)`，64 项（4 位口只到得了 16 项） |
| 2-bank 乒乓：写端翻 bank 的同时读端读**刚写完**的那一行 | `rd_bank` 只在**整源行**（含所有重复遍）读完后翻转 |
| 跨时钟域用 **1 bit toggle + 两级同步器** | `toggle_meta` / `toggle_sync` / `toggle_seen` |
| 一个源行输出 2×512 = 1024 个像素 | `REPEAT_LINE=1`（默认）时 `rd_second` 让同一 bank 读两遍 |
| 一个源行输出 1×512 = 512 个像素 | `REPEAT_LINE=0` 时 `rd_second` 恒 0，行为与参数化前逐位相同 |
| 2× 水平复制 = 地址右移，且**和坐标对齐** | `line_mem[{rd_bank, rd_next_x[8:1]}]`，`rd_next_x = rd_x_cnt + 1` |
| `line_read_start` 在**每一遍**的 `read_x=0` 各脉冲一次 | `rd_active & (rd_x_cnt == 9'd0)` |
| `wr_ce` / `rd_ce` 关掉就完全不动（复位优先于使能） | `if (reset) ... else if (ce) ...` |
| 复位**不清** `line_mem` | `line_mem` 不在任何一个复位列表里 |

四个必须记住的时序细节：

1. **`read_x = c` 时 `read_rgb565` 必须是 `line_mem[rd_bank][c>>1]`。** BRAM 同步读，数据比地址晚一拍，所以地址必须用**下一个**计数器（`rd_next_x`）取。这条是本次改动修掉的既有缺陷：原来地址用 `rd_x_cnt`，导致整幅图横向错开一个源像素，`read_x=2` 处拿到的是源像素 0 而不是 1，2×2 复制块被切成错位的 1+1。
2. **行末沿必须为下一遍预装 `mem[0]`。** 重复遍的第 0 个像素靠这个预装才能拿到源像素 0，否则会拿到上一遍的残留（`mem[255]`）。
3. **复位把读端 bank 拉回 0。** 所以在**奇数行**中途复位读端，下一行（偶数行，bank 0）会自动重新对齐；下一行是奇数行就会错位。TB 故意在读奇数行时复位来验证前者。
4. **toggle 是电平不是脉冲。** 读端欠一次翻转就一定看得见；欠两次或更多则中间的整行被**静默跳过**，且没有任何信号表明这件事发生了。TB 的时钟比（5 倍）保证永不 overrun，但那是测试环境的性质，**不是模块的保护**。

## 2.2 时钟与调度纪律（改 TB 之前必读）

TB 用**两个不同频率、且边沿永不重合**的时钟，这是所有断言能确定性成立的前提：

| 角色 | 周期 | 边沿时刻（mod 10 ns） | 谁在用 |
| --- | --- | --- | --- |
| `rd_clk` | 10 ns（`#5`） | 5 | 被测读端 + monitor |
| `wr_clk` | 50 ns（`#2` 后 `#25`） | 2、7 | 被测写端 + 主控 task |
| monitor 采样点 | `posedge rd_clk` 之后 `#1` | 6 | 唯一改模型状态的地方 |
| 主控观测点 | `posedge` 之后 `#2` | 3、8 | 唯一改 `rd_ce` / `rd_reset` / 模型重置的地方 |

因此 monitor（偶数时刻）和主控（奇数时刻）**永远不会在同一时刻读写同一个变量**，`rd_ce` / `rd_reset` 的赋值也永远不会和 monitor 的采样撞在一起。两个 task 封装了这个纪律，改 TB 时**必须**用它们：

| task | 作用 |
| --- | --- |
| `wait_wr(n)` | 等 n 个 `wr_clk` 沿（停在偶数时刻） |
| `wait_rd(n)` | 等 n 个 `rd_clk` 沿**再 `#2`**（停在奇数时刻，DUT 输出已稳定） |
| `rd_ce_set(v)` | `@(posedge rd_clk); #2; rd_ce = v;` —— 保证赋值不与 monitor 撞车 |
| `rd_reset_set(v)` | 同上 |
| `wr_pixel(x, ci, pv)` | 置写口输入，等一个 `wr_clk` 沿，然后 `#1`；顺带断言两个实例的 `line_done` / `line_ready_toggle` 一致 |
| `wr_line(l)` | 写满一行，逐像素断言 `line_done` / `line_ready_toggle` 只在 `x=255` 出现；断言 `wr_bank` 翻转；**结束时把 `wr_pixel_valid` 清 0** |
| `drain(rep, nre)` | 等两个实例分别读完 rep / nre 行，再断言行数精确相等且读端已停 |
| `model_rearm(inst)` | 重置某个实例的读流模型（`md_x` / `md_line` / `md_pass` / `md_done`） |
| `all_reset` | 同时拉高两个复位（各保持 3 个沿），清模型和影子值，归零全局计数，释放复位，并断言 `wr_bank` 已归 0 |

**`wr_line` 结束时必须清 `wr_pixel_valid`。** 写口的 `wr_x=255` + `wr_pixel_valid=1` 如果被留着，主控在后面等 `rd_clk` 的循环里会让被测模块**每个 `wr_clk` 沿都判定"一行结束"**，于是 toggle 每 50 ns 翻一次、读端读到一堆还没写的陈旧 bank。这个坑真实存在过（TB 第一版就踩了），现在由 `wr_line` 收尾保证。

## 2.3 参考模型

调色板表在 TB 里独立抄了一份 `pal_ref`（64 项，Verilog-2001 只能用无位宽的 `'h10:`..`'h3F:` 做 case 标签，4 位装不下）。图样函数只用 4 位索引，且**每一行的图样互不相同**：

```
pat_idx(x, l) = (x + 7*l + 3) mod 16
```

`7*l mod 16` 在 l = 0..7 上是 0, 7, 14, 5, 12, 3, 10, 1，**两两不同**。所以"读到了错误的那一行"（ping-pong 错位、bank 错位、toggle 少一次）会立刻在颜色上暴露，不需要层次化看内部寄存器。图样对 x 也不对称（`pat(255-x, l) != pat(x, l)`），所以横向镜像错误同样会被抓到。

期望色 `pal_ref(pat_idx(read_x >> 1, line))`。

读流模型每个实例一份（`md_x` / `md_prev` / `md_line` / `md_pass` / `md_done`），由 monitor 在每个 `rd_ce` 沿更新，检查：

- `read_x` 严格等于期望的递增序列（0..511），空闲时必须是 0；
- `line_read_start` 恰好在 `read_x=0` 为高，其他位置一律为低；
- 颜色等于期望值；
- `read_x` 为奇数时颜色必须等于上一个像素（2× 水平复制的直接表达）；
- 每遍结束（`read_x=511`）推进 `md_pass`，`md_pass` 超过该实例的遍数上限就完成一行；
- `frame_line_valid=0` 时 `line_read_start` 必须为 0、`read_x` 必须停在 0。

## 2.4 断言覆盖

`tb_nes_line_buffer_vga.v` 使用 `$fatal` 断言并逐行打印 PASS，覆盖 4 组：

1. **复位与 `wr_ce` 门控**（`test_reset_contract`）：复位释放后 40 个 `rd_clk` 周期里，写口没有脉冲、读口 `frame_line_valid` / `line_read_start` / `read_x` / `read_rgb565` 全为 0，`line_read_start` 计数为 0。然后 12 个 `wr_ce=1` 但 `wr_pixel_valid=0` 的空闲周期不许出脉冲；6 个 `wr_ce=0` 且 `wr_x=255` 的周期**不许**完成一行（证明写使能真的把整个写端关掉了）；最后 100 个 `wr_ce=1` 的写像素期间读端必须**一次都不许**出有效像素。
2. **`rd_ce` 门控与重复遍**（`test_rd_ce_gate`）：先写 100 个像素（不满一行），确认无脉冲；`wr_reset` 保持 2 个 `wr_clk` 沿，必须仍然无脉冲（残行被丢弃且**不产生** toggle）；释放后写满第 0 行；`rd_ce` 仍为 0 的 60 个周期里读端不许有任何输出、`line_read_start` 计数必须为 0。放行 `rd_ce` 后等 `read_x` 走到 200，**此时冻结**：在 `rd_ce=0` 下再等 12 个周期，四个输出必须逐拍不变（`test_reset_contract` 里读端一直是空闲的，这里是唯一一处"冻结在非零状态"的检查）。
恢复后必须正好读完 1 行，`line_read_start` 计数 = 2（`REPEAT_LINE=1`）/ 1（`REPEAT_LINE=0`）。
3. **并发 ping-pong**（`test_ping_pong`）：连续写 8 行，第 3 行中间插 7 个 `wr_ce=0` 的空洞、第 5 行之后插 5 个空洞（证明计数的是**有效像素**而不是时钟，且行与行之间断开也不丢行）。逐像素校验行序 0,0,1,1,…,7,7、颜色、2× 复制、坐标序列；`line_read_start` 计数必须正好 16 / 8；写口有效**且**读口有效的重叠周期数必须 ≥ 3000（实测 7114），否则这条测试等于空过。
4. **读端中途复位**（`test_rd_reset_mid_line`）：写第 0 行，等两个实例都读完；写第 1 行，等 `line_read_start` 出现后再走 150 个周期（此时必须正好在**第一遍中间**，`md_done` 仍为 1/1）；拉高 `rd_reset` 3 个沿，四个输出必须全部清零、两个实例的 `frame_line_valid` / `line_read_start` 也必须清零；把模型重置到"下一行是第 2 行"（复位丢掉了第 1 行，且 `rd_bank` 归 0 与第 2 行的 bank 0 自动对齐）；再等 200 个周期，读端**不许**自恢复，`line_read_start` 计数必须停在 3 / 2（第 0 行两遍 + 第 1 行一遍，不重复读）；最后再写 4 行，逐像素校验第 2..5 行，计数必须正好 11 / 6。

**toggle 同步**由 monitor 顺带检查：每写完一行记下时间戳，两次 `line_read_start` 都必须满足"距写端翻转 ≥ 30 ns"（3 个 `rd_clk`，即两级同步器 + 一次接受）；在读端保证空闲的阶段（`lat_strict`）还额外要求 ≤ 60 ns。`rd_ce` 被门控的那一段不设上界，因为那时候读端本来就可能等很久。

**"写读同时不冲突"**由两件事共同钉死：(a) 每一行的图样互不相同，所以读到正在被写的那一行必然颜色错；(b) `wr_line` 断言每行之后 `wr_bank` 一定翻转、monitor 断言每个**源行**起始处 `rd_bank` 一定翻转且复位后第一行必须是 bank 0。**没有**直接断言"读写 bank 不相等"——那一瞬间（写端刚翻 `wr_bank` 的沿）读端还在读**上一行**，两个 bank 合法地短暂相等，直接断言会误报。

顶部还有 `global timeout`（20 ms 仿真时间）兜底断言，`drain` 和两个等待循环各有 4000 拍的局部超时。

## 2.5 覆盖不到的地方

- **`line_mem` 的复位行为没有直接测**。要测它需要层次化引用 `line_mem` 或一个读回端口，TB 选择不断言"复位后内容保留"。间接证据是：中途复位后必须重写整行才能读到正确数据，而重写之前的任何断言都不依赖旧内容。
- **overrun（写端领先 2 行以上）没测，因为模块不支持**。toggle 只有 1 bit，跳行行为既没有接口暴露，也没法在"永不 overrun"的 5 倍时钟比下测出来。这条限制写在 `docs/modules/line-buffer-vga.md` 第 5.5 节。
- **同址同拍的写读冲突没测**。ping-pong 在结构上排除了它，但如上所述，"两个 bank 不相等"不是一条可以在任意时刻断言的合同。
- **只有 16 种颜色**参与颜色校验，因为 `wr_index` 只有 4 位，模块最多只能存 16 种颜色；64 项调色板表在 RTL 里是全的，但 4 位口到不了 16 以上。
- **图样周期是 16**，源 x 偏移 16 的错误靠颜色查不出来（会被坐标序列抓住）。这是 `wr_index` 只有 4 位的直接后果。
- **`rd_ce=0` 期间积压 2 次以上 toggle 的行为**没测（第 4 条只测了积压 0 次的情形）。

## 2.6 运行

在仓库根目录执行，输出放在临时目录，不向仓库写文件：

```powershell
$tmp = Join-Path $env:TEMP 'op_fpga_emu'
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
& 'C:\iverilog\bin\iverilog.exe' -g2001 -Wall -s nes_line_buffer_vga -o (Join-Path $tmp 'nes_line_buffer_vga_core.vvp') 'rtl\nes_core\video\nes_line_buffer_vga.v'
& 'C:\iverilog\bin\iverilog.exe' -g2012 -Wall -s tb_nes_line_buffer_vga -o (Join-Path $tmp 'tb_nes_line_buffer_vga.vvp') 'rtl\nes_core\video\nes_line_buffer_vga.v' 'tb\video\tb_nes_line_buffer_vga.v'
& 'C:\iverilog\bin\vvp.exe' (Join-Path $tmp 'tb_nes_line_buffer_vga.vvp')
```

核心是 Verilog-2001 源码，可以单独用 `-g2001 -Wall` elaborate（**零 warning**），也可以用 `-Pnes_line_buffer_vga.REPEAT_LINE=0` 覆盖参数重新 elaborate 验证参数化路径。testbench 使用 `$fatal`，因此 Icarus 入口使用 `-g2012`，与仓库现有 controller/PPU/APU testbench 相同；TB 自身也是 `-Wall` 零 warning。

下面是本版本的完整期望输出，逐行对应一个 test task；vvp 退出码 0，仿真时间 251.047 µs，实测运行约 0.18 s：

```text
LINBUF reset and wr_ce gating raise no line_done, no toggle and no read line PASS
LINBUF rd_ce gates the whole read side and REPEAT_LINE replays one line as two passes PASS
LINBUF 8 concurrent lines ping pong in order, 7114 write/read overlap cycles, no torn read PASS
LINBUF rd_reset mid pass drops the partial line, homes the bank and resumes on the next toggle PASS
PASS nes_line_buffer_vga
tb\video\tb_nes_line_buffer_vga.v:702: $finish called at 251047000 (1ps)
```

任何 `$fatal` 命中会让 vvp 以非零退出码结束，并把检查名、实际值、期望值打印到 stdout。

作为置信度检查，对 RTL 的**临时副本**（仓库里的 RTL 未被修改）做了 7 处定向变异，**7 处全部被 testbench 立刻抓到**：

| 变异 | 第一次失败 |
| --- | --- |
| 去掉重复遍（`if (REPEAT_LINE != 0 && !rd_second)` → `if (1'b0)`） | `the read side did not reach 1/1 lines, it stalled at 0/1` |
| 读地址退回 `rd_x_cnt[8:1]`（取消读延迟对齐） | `inst 0 rgb565 at line 0 read_x 2 got 310c expected 4008` |
| 同步器退化成 1 级（`toggle_sync <= line_ready_toggle`） | `inst 0 read a line 28 ns after the write toggle, the 2 flip flop synchronizer is bypassed` |
| 同步器冻死（`toggle_meta <= toggle_meta`） | `the read side never reached read_x=200` |
| `line_read_start` 改成 `rd_x_cnt == 9'd1` | `inst 0 line_read_start got 0 at read_x 0, expected 1` |
| 重复遍不预装 `line_mem[{rd_bank,0}]` | `inst 0 rgb565 at line 0 read_x 0 got 0000 expected 310c` |
| `rd_bank` 读完不翻转 | `inst 0 rgb565 at line 1 read_x 0 got 310c expected 5b20` |

`tools/sim_all.ps1` 只有 scaler 的 `video-core` / `video-tb` 两个目标，没有行缓冲的目标；ModelSim 也没有对应的 `.do` 文件。这两个脚本不在本任务的写入范围内，没有改。

---

# 3. `tb_nes_vga_timing.v`：VGA 时序发生器

`tb_nes_vga_timing.v` 是 `rtl/nes_core/video/nes_vga_timing.v` 的自检 testbench。它同样不下载 ROM、不读外部文件：像素源就是 TB 自己的一条 512×480 自由运行行流，靠 `line_read_start` 归位。设计文档在 `docs/modules/vga-timing.md`。

前两个 testbench 检查的是"像素对不对"，这一个检查的是"时序对不对"：它没有一行像素缓冲，只有计数器，所以可以把**连续 840200 拍**逐拍比对。代价是运行时间比前两个长（实测约 8 s，仿真时间 35.99 ms）。

## 3.1 被测模块的实际行为

TB 是照着下面这几条**已实现**的合同写的：

| 合同 | 实现位置 |
|---|---|
| `hcount` 0..799、`vcount` 0..524，都自由运行 | `h_next` / `v_next` |
| 所有输出和输入在**同一个沿**上更新，输入描述"沿之后计数器到达的坐标" | 唯一的 `always @(posedge clk)` |
| `hsync` 高有效于 `x ∈ [656,752)` | `hsync_next` |
| `vsync` 高有效于 `y ∈ [490,493)` | `vsync_next` |
| `de` = 纯时序窗口 `x ∈ [64,576) && y ∈ [0,480)`，与有没有数据无关 | `de_next` |
| `rgb565` = `de` 且本行已对齐且 `px_valid` 时才取源像素，否则 0 | `act_next` |
| `active_pixels` = 那一拍 `rgb565` 上真的有图像数据 | `act_next` |
| `frame_pulse` 落在**一帧的最后一个像素** `(799,524)`，单周期 | `frame_end = (h_next==H_LAST) && (v_next==V_LAST)` |
| `line_read_sync` 是 `line_read_start` 的 `ce` 门控寄存回声 | `line_read_sync <= line_read_start` |
| `line_started` 行末清零，strobe 优先于行末清零 | `line_next = line_read_start ? 1'b1 : (h_last ? 1'b0 : line_started)` |
| `line_read_start` **不能**动 `hcount`/`vcount` | `line_started` 是唯一被它改变的状态位 |
| 复位优先于 `ce`；`ce=0` 冻结包括输入在内的一切 | `if (reset) ... else if (ce) ...` |

## 3.2 时钟与调度纪律（改 TB 之前必读）

时钟是 40 ns（`#20`，对应 25 MHz 像素时钟）。TB 的不变量是：

> **在一个 `ce` 沿刚过去、`#1` 之后：`mx`/`my` 等于 DUT 的 `hcount`/`vcount`，`e_*` 是这一拍的期望值，输入引脚上摆的是**下一个**坐标要用的值。**

所有激励都发生在 `posedge clk` 之后 `#1`，所以输入在被采样沿之前有 39 ns 的建立时间，输出在沿之后 `#1` 采样。围绕这个不变量有 6 个 task：

| task | 作用 |
| --- | --- |
| `drive(tx,ty)` | 算出坐标 `(tx,ty)` 的全部期望（`e_hs/e_vs/e_de/e_fp/e_lrs/e_act/e_rgb/e_kind`），按规则摆好 strobe 与源像素，并推进源流；末尾把三个输入存进 `p_hold_*` |
| `drive_rearm` | 只把三个输入恢复成 `p_hold_*`，不重算、不推进源流（`ce=0` 冻结后恢复用） |
| `step` | 等一个 `posedge`，`#1`，`n_cycle` 加一，跑 `check_now`，再算下一个坐标并 `drive` |
| `run_steps(n)` | 连续 `n` 拍 |
| `goto_xy(tx,ty)` | `step` 到 `(mx,my)==(tx,ty)` **再补一拍**，于是离开时 DUT 引脚上正是 `(tx,ty)` 且已被 `check_now` 校验过；带 2000000 拍局部超时 |
| `snap` / `snap_check` | 存下九个输出 / 逐位比对（`ce=0` 冻结用） |

`goto_xy` 结尾那"多出来的一拍"是这个 TB 里最容易写错的地方：只 `step` 到 `mx==tx` 的话，DUT 的输出还停在**前一个**坐标，任何针对 `(tx,ty)` 的断言都会读到上一拍。`goto_xy(63,20); n0 = n_lrs; goto_xy(64,20);` 这种写法是为了让"这一行只出现 1 次 strobe"的计数断言恰好成立。

`apply_reset` 把 DUT 复位 3 拍并检查，然后清空模型；`raster_arm` 把模型摆到"下一个 `ce` 沿会到达 `(1,0)`"的状态并重置行/像素计数器。**每次 `apply_reset` 之后必须重新 `raster_arm`**，因为复位把 `mx`/`my` 归 0 了。

## 3.3 参考模型

几何常数在模型里是**字面量**（`64/576/480/656/752/490/493/799/524`），不引用 DUT 的参数——这样"参数和模型同时错"才会被抓住。源流模型是一条自由运行的 512×480 像素流：

```
src_pat(y, x) = {y[7:0], x[7:0]} + 1
```

`+1` 保证它**永远不是 0**，于是"黑"和"一个恰好是 0 的像素"不会混淆；`(y,x)` 唯一，于是读到错误的行/列一定颜色不同。流每拍前进一列，`line_read_start` 把它重新归位到 `(行号, 0)`。

`e_kind` 记录这一拍属于哪一类，驱动更精确的断言：

| `e_kind` | 含义 | 额外断言 |
| --- | --- | --- |
| 0 | 正常数据 | 无 |
| 1 | 在 DE 窗口内、`px_valid=0`（像素空洞） | `de` 仍为高、`active_pixels` 为 0、`rgb565` 为 0 |
| 2 | 在 DE 窗口内但本行没有 strobe | `de` 仍为高、`active_pixels` 为 0、`rgb565` 为 0 |

`landmarks` 是 23 个**硬编码**地标断言（`x=655/656/751/752` 的 hsync 跳变、`x=63/64/575/576` 的 de 跳变、`y=479/480` 的行边界、`y=489/490/492/493` 的 vsync 跳变、`frame_pulse` 只在 `(799,524)`、hsync 不与有效区重叠），逐拍执行。它们和参考模型是**两套独立写法**，模型对但地标错的情况会被抓住。

## 3.4 断言覆盖

8 组，逐行打印 PASS：

1. **复位**（`test_reset_contract`）：`reset` 期间 3 拍、释放后 12 拍，每拍 `zero_check` 断言 `hcount/vcount = 0`、`hsync/vsync/de/frame_pulse/line_read_sync = 0`、`rgb565 = 0`、`active_pixels = 0`，而且这 12 拍里持续把 `line_read_start`、`px_valid` 打成 1、`px_rgb565` 打成 `FFFF`（`ce=0` 必须把输入一起吞掉）。
2. **帧中复位**（`test_reset_mid_frame`）：先跑到 `(100,3)`（断言那里 `de=1`、`active_pixels=1`、像素非 0），然后在 `ce=0` 下拉复位，2 拍 `zero_check`；释放后再 1 拍仍全 0；`raster_arm` 之后跑到 `(64,0)`，断言第一个有效像素就是源列 0、这一行恰好 1 次 strobe。这条钉住"复位优先于 `ce`"和"复位把光栅归位到 `(0,0)`"。
3. **`ce` 冻结**（`test_ce_freeze`）：在 `(200,7)`（`de=1`、像素非 0）`snap`，然后 `ce=0` 并把 `px_rgb565` 打成 `FFFF`、`line_read_start` 打成 1，保持 16 拍，每拍 `snap_check` 断言九个输出**逐位**不变（所以像素不得变成 `FFFF`、strobe 不得被采纳）；`ce=1` + `drive_rearm` 后一拍，断言光栅精确从 201 继续、流是源列 137（冻结既不重发也不跳列）。第二段把 strobe 打在**被冻结期间**，并抑制第 8 行自己的 strobe，跑到 `(575,8)` 断言 512 个像素全黑——证明冻结期间的 strobe 被**丢弃**而不是延后执行；随后第 9 行必须恢复成源列 0。
4. **缺像素**（`test_missing_pixels`）：在第 10 行同时挖掉源列 5、6、511 三个洞。逐点检查 `(68,10)=列4`、`(69,10)=黑`、`(70,10)=黑`、`(71,10)=列7`、`(575,10)=黑`、`(576,10)` 出窗口且为黑。其中 `(71,10)=列7` 是关键：**空洞不移动后面的像素**（不是"停一拍重发"）。然后抑制第 11 行的 strobe，跑到 `(0,12)` 断言黑像素计数正好 512、掉点计数仍是 3，第 12 行 `(64,12)` 恢复为源列 0。
5. **`line_read_start` 对齐**（`test_line_read_align`）：`(64,20)=列0`、`(575,20)=列511`，这一行恰好 1 次 strobe。然后在第 21 行的 `x=300` 补一个 strobe：断言 `line_read_sync` 在 300 处为高、`(300,21)=列0`、`(301,21)=列1`、`(575,21)=列275`（源从 300 重新数起，275 < 512 没有回绕），并且**逐拍**的 `hcount/vcount` 序列没被扰动（模型逐拍比对，这一条就是"不能用它复位帧计数器"的断言）。最后第 22 行回到正常，每行恰好 1 次 strobe。
6. **行末 strobe**（`test_last_pixel_strobe`）：在 `x=799` 呈现 strobe。断言 `line_read_sync` 被回声，但**下一行 512 个像素仍然全黑**——行末清零优先，这次 strobe 对下一行毫无作用。
7. **行首 strobe**（`test_zero_strobe`）：在 `x=0` 呈现 strobe（并抑制该行自己的 strobe）。断言 strobe 赢过行末清零：`(64,13)=列64`（源在 x=0 归位，所以可见窗口看到的是流的第 64..列）、`(575,13)=列63`（源自己的 512 列回绕）、黑像素计数为 0；第 14 行恢复正常。
8. **整帧**（`test_full_frame`）：复位后连续 `step` 840199 拍，**每一拍**都跑 `check_now`（9 个输出 + 坐标序列 + 23 个地标）。另外累计：每帧有效像素 245760、每帧 vsync 行数 3、每行 hsync 恰好 96 拍、840200 拍内 2 次 `frame_pulse`、第一次在第 419999 拍（`(0,0)` 是复位状态，不会被重新寄存）、两次脉冲间隔恰好 420000 拍（= 525 行）、strobe 共 1051 次（两整帧 1050 + 第三帧的第一次）、结束时位置精确为 `(200,0)`、第三帧已累计 137 个有效像素。

顶部还有 `global timeout`（120 ms 仿真时间）兜底断言，`goto_xy` 有 2000000 拍局部超时。

## 3.5 覆盖不到的地方

- **`H_ACTIVE` / `V_ACTIVE` 两个参数没被任何逻辑使用**，所以 TB 也没有覆盖它们（改成 1 或 999 都不影响行为）。它们是文档性质的参数，见 `docs/modules/vga-timing.md` 第 2 节。
- **参数化路径没有覆盖**。TB 只跑默认的 640×480@60Hz。`DE_X0/DE_X1/HSYNC_*/VSYNC_*/V_TOTAL/H_TOTAL` 改成别的值时，`landmarks` 和 `goto_xy` 里的字面量会全部失效——本 TB 不是参数无关的。换参数必须同时改 TB。
- **非默认时钟比没测**。时钟固定 40 ns（25 MHz）。`ce` 的其他占空比（例如只在部分拍使能）没有专门覆盖，但 `test_ce_freeze` 证明了单次拉低会冻结全部状态。
- **多实例 / 不同参数的两份拷贝没做**。行缓冲的 TB 用两个实例对比，本模块没有这个手法。
- **和上游行缓冲的联合行为没测**。TB 的源流是自己造的模型，不是 `nes_line_buffer_vga`。真正的拼接（谁在 `hcount==63` 时发 strobe、toggle 与光栅的相位关系）目前**没有代码**，见 `docs/modules/vga-timing.md` 第 8 节。
- **极性没有测**。本模块固定正有效，负极性由顶层反相，TB 不涉及反相后的波形。
- **`ce` 长期为 0 再恢复没有测**（只测了 16 拍）。恢复后 `frame_pulse` 是否会补发被跳过的那一拍，取决于上游在 `ce=0` 期间是否也停摆，本 TB 不回答这个跨模块问题。

## 3.6 运行

在仓库根目录执行，输出放在临时目录，不向仓库写文件：

```powershell
$tmp = Join-Path $env:TEMP 'op_fpga_emu'
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
& 'C:\iverilog\bin\iverilog.exe' -g2001 -Wall -s nes_vga_timing -o (Join-Path $tmp 'nes_vga_timing_core.vvp') 'rtl\nes_core\video\nes_vga_timing.v'
& 'C:\iverilog\bin\iverilog.exe' -g2012 -Wall -s tb_nes_vga_timing -o (Join-Path $tmp 'tb_nes_vga_timing.vvp') 'rtl\nes_core\video\nes_vga_timing.v' 'tb\video\tb_nes_vga_timing.v'
& 'C:\iverilog\bin\vvp.exe' (Join-Path $tmp 'tb_nes_vga_timing.vvp')
```

核心是 Verilog-2001 源码，可以单独用 `-g2001 -Wall` elaborate（**零 warning**）。testbench 使用 `$fatal`，因此 Icarus 入口使用 `-g2012`，与仓库现有 controller/PPU/APU testbench 相同；TB 自身也是 `-Wall` 零 warning。

下面是本版本的完整期望输出，逐行对应一个 test task；vvp 退出码 0，仿真时间 35.986621 ms，实测运行约 8 s：

```text
VGAT reset clears hsync, vsync, de, the pixel bus and both strobes PASS
VGAT reset wins over ce=0, homes the raster and restarts the line stream PASS
VGAT ce=0 freezes the whole raster, the pixel bus and the strobes PASS
VGAT missing pixels and a missing line start both come out black while de stays high PASS
VGAT line_read_start re-homes the stream at x=0 of a line without touching the frame counter PASS
VGAT a line_read_start on the last pixel of a line is echoed but the wrap still clears it PASS
VGAT a line_read_start presented at x=0 wins over the wrap clear and keeps the line aligned PASS
VGAT 800x525 free running raster, 96 hsync, 3 vsync, 245760 active pixels, 420000 cycle frame PASS
PASS nes_vga_timing
tb\video\tb_nes_vga_timing.v:761: $finish called at 35986621000 (1ps)
```

任何 `$fatal` 命中会让 vvp 以非零退出码结束，并把检查名、实际值、期望值打印到 stdout。

作为置信度检查，对 RTL 的**临时副本**（仓库里的 RTL 未被修改）做了 17 处定向变异，**17 处全部被 testbench 立刻抓到**：

| 变异 | 第一次失败 |
| --- | --- |
| `HSYNC_START` 656 → 648 | `hsync is 1 at (648,0), expected 0` |
| hsync 窗口 `< P_HSE` → `<= P_HSE` | `hsync is 1 at (752,0), expected 0` |
| `HSYNC_END` 752 → 751 | `hsync is 0 at (751,0), expected 1` |
| `DE_X1` 576 → 584 | `de is 1 at (576,0), expected 0` |
| `DE_X0` 64 → 65 | `de is 0 at (64,0), expected 1` |
| `VSYNC_END` 493 → 494 | `vsync is 1 at (0,493), expected 0` |
| `VSYNC_START` 490 → 489 | `vsync is 1 at (0,489), expected 0` |
| `DE_Y1` 480 → 481 | `de is 1 at (64,480), expected 0` |
| 行末清零优先于 strobe（`h_last ? 1'b0 : ...` 在前） | `active_pixels is 0 at (64,13), expected 1` |
| `line_next` 去掉行末清零 | `active_pixels is 1 at (64,8), expected 0` |
| `act_next` 忽略 `px_valid` | `active_pixels is 1 at (69,10), expected 0` |
| `rgb565 <= px_rgb565`（消隐不再置黑） | `rgb565 is 0001 at (1,0), expected 0000` |
| `else if (ce)` → `else` | `reset left hcount at 1` |
| `frame_end` 改用旧计数器（脉冲落到 `(0,0)`） | `frame_pulse is 0 at (799,524), expected 1` |
| `line_read_sync` 被 `de_next` 门控 | `line_read_sync is 0 at (799,12), expected 1` |
| `vcount` 不回卷 | `vcount is 525, expected 0 at hcount 0` |
| `hcount` 不前进 | `hcount is 0, expected 1 at vcount 0` |

其中"行末清零优先于 strobe"和"`line_next` 去掉行末清零"这两条，是**先由变异发现测试有洞、再补测试**的：最初第 6、7 条只检查了"`line_read_sync` 有没有回声"，而下一行自己也会发 strobe，所以两种优先级都能通过。现在第 6 条抑制了下一行自己的 strobe 并断言 512 个像素全黑，第 7 条同样抑制并断言整行有数据，两种优先级才被区分开。

`tools/sim_all.ps1` 没有 VGA 时序的目标，ModelSim 也没有对应的 `run_video_tb.do`；这两个脚本不在本任务的写入范围内，没有改。
