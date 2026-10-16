# I2S 音频位串行器（`nes_i2s_shifter`）与组装层（`nes_audio_i2s`）：从 32 位立体声样点到 BCLK/LRC/DIN 三根线

本文说明 `rtl/nes_core/peripheral/nes_i2s_shifter.v` 与 `rtl/nes_core/peripheral/nes_audio_i2s.v` 的接口合同、时序模型和设计取舍，回答一个和 `controller.md`、`oam-dma.md` 同源的教学问题：

> 软件音频栈里"播一个样点"是把样本拷进缓冲区、让操作系统按采样率把它送出去；FPGA 的 I2S 从机里没有缓冲区语义，只有"一位一个时钟沿地把 32 位串出去"。

结论：**协议位序、声道相位、BCLK 边沿是规格；谁提供 32 位样点、以什么节奏提供，是设计。** `nes_i2s_shifter` 只拥有位流本身，`nes_audio_i2s` 负责缓冲、跨时钟交接和输出寄存器；采样率转换、抗混叠滤波、codec 寄存器配置都不在这两个模块里。

行为权威是 I2S 总线规范和 WM8960 数据手册的 AUDIO DATA FORMATS 章节（它规定**接收方**的采样相位）；两个模块的**文件头注释**是设计事实的准绳，`[源码观察]` 标记的内容只是观察，不是规格。

---

## 1. I2S 协议基础与相位

I2S 是一根时钟、一根声道标记、一根数据的三线同步串行总线：

| 线 | 方向（本设计是从机、只发） | 作用 |
| --- | --- | --- |
| `BCLK` | out | 位时钟。**一位占用一个 BCLK 周期。** |
| `LRCLK` / `WS` | out | 声道标记。**低 = 左、高 = 右**，每个立体声样点对翻转一次。 |
| `SD` / `DIN` | out | 串行数据，**MSB first**。 |

规格要点：

1. **一帧 = 32 个 BCLK。** 一个样点是 16 位左 + 16 位右，前 16 个 BCLK 送左、后 16 个送右。
2. **左声道先出。** `out_lrck` 在流的**第 17 位**（0 基下标 16）从低翻到高，即从左声道进入右声道的那一位翻转。
3. **MSB first。** 默认（`BIT_REVERSED = 0`）每声道从最高位开始送。
4. **数据在 BCLK 边沿被接收方采样。** 本设计在 BCLK **上升沿**把 `dout` / `lrck` 打进输出寄存器（§3.9）。

`[数据手册真值]` WM8960_v4.4.pdf： "In I2S mode, the MSB is available on the second rising edge of BCLK following a LRCLK transition"。即收发双方在 LRCLK 翻转后再数第二个 BCLK 边沿才取 MSB。这就是 zynq 平台在 `dout` 上多加一级 BCLK 寄存器（§5）的原因——把 MSB 推进第二个时隙；`lrck` 不加延迟，因为它是给接收方的通道标记。

样点的位分布（两模块共同的合同）：

```
sample_data[31:16] = 右声道 right
sample_data[15:0]  = 左声道 left
流  :  左[15] 左[14] ... 左[0] | 右[15] 右[14] ... 右[0]
lrck:  0 ... 0  (16 位)          1 ... 1  (16 位)
```

---

## 2. `nes_i2s_shifter`：一次采样恰好 32 个 `ce` 有效沿

本模块只拥有位流：**没有样点 FIFO、没有位时钟分频、没有时钟域跨越。** 速率转换、缓冲和 CDC 是外面模块的活。

### 2.1 端口合同

```verilog
module nes_i2s_shifter #(parameter BIT_REVERSED = 0) (...);
```

| 信号 | 方向 | 合同 |
| --- | --- | --- |
| `clk` | in | 位流时钟。本模块**唯一**的时钟，所有状态只在 `posedge clk` 更新。 |
| `reset` | in | 高有效复位，在 `posedge clk` 上采样（同步清零 `shift_reg`、`bit_cnt`、`out_valid`、`out_bit`、`out_lrck`、`busy`、`dropped`）。组装层把 `rd_reset` 送给它。 |
| `ce` | in | **时钟使能。** 高 = 这一沿推进一位（`out_valid` 并移位）；低 = 状态机冻结（§2.6）。 |
| `sample_valid` | in | 装载请求，**电平，任意沿**。`busy` 为低时该沿接收（§2.2 / §2.5）。 |
| `sample_data [31:0]` | in | `{right[15:0], left[15:0]}`，即 bit15:0 = 左、bit31:16 = 右。 |
| `out_valid` | out (reg) | **每位一个单周期 strobe。** 出一个样点恰好 32 个高周期。 |
| `out_bit` | out (reg) | 串行数据位。`ce` 低时保持当前位。 |
| `out_lrck` | out (reg) | 声道标记。前 16 位低、后 16 位高，**第 17 位翻转**。 |
| `busy` | out (reg) | 高 = 有样点在飞。装载沿拉高，移完第 32 位后（未被重填时）拉低。 |
| `dropped` | out (reg) | **粘滞**丢样标志。忙时被丢弃的 `sample_valid` 置一，直到复位。 |
| `ready` | out (wire) | 接收许可 = `!busy || freeing`，组合（§2.4）。 |

内部索引与声道：`sel = BIT_REVERSED ? bit_cnt : (bit_cnt ^ 5'h0f)`；`lrck_next = bit_cnt[4]`；`freeing = ce && busy && (bit_cnt == 5'd31)`；`ready = !busy || freeing`。

### 2.2 装载沿不输出

一个样点在**任意** `sample_valid` 为高、`busy` 为低的时钟沿被接收，**与 `ce` 无关**：`busy` 在该沿拉高，而**第一位在下一个 `ce` 有效沿才出现，绝不在装载沿本身**。

吞吐（文件头原文）：一个样点恰好占 **32 个 `ce` 有效沿**。第 32 个 `ce` 沿移出 bit31 并清空寄存器，**同一次钟里**若又送来一个样点就顺手装载它，再下一个沿已在移出新样点的 bit0。**样点之间没有死钟，也没有第 33 个 done 脉冲**；不被重填时 `busy` 保持低、流停止、`out_bit` / `out_lrck` 保持最后一个值。

### 2.3 位序与 `BIT_REVERSED`

`BIT_REVERSED = 0`（默认）MSB first：左样点以 `left[15] ... left[0]` 出去，右样点同理。`BIT_REVERSED = 1` 在每个声道**内部**反序：`left[0] ... left[15]` 再 `right[0] ... right[15]`；**声道顺序不变**，左声道始终占前 16 位。`sel = bit_cnt ^ 5'h0f` 是 MSB first 的索引算术（`bit_cnt = 0` 取 bit15 … `bit_cnt = 31` 取 bit16），`BIT_REVERSED = 1` 时 `sel = bit_cnt` 顺取。`tb_nes_i2s_shifter` 用同一激励驱动两个实例，参考模型按**声道语义**写成并逐位比对，还专门断言两实例的位流**不相同**（`diffs != 0`），否则测试样点分不出两种次序。

### 2.4 `ready` 的精确定义，以及"不是 look-ahead"

`ready = !busy || freeing`，`freeing = ce && busy && (bit_cnt == 5'd31)`。语义是：**即将到来的这个时钟沿上，一个在 `sample_valid` 上提出的样点被保证接收**——要么寄存器空闲，要么恰好是这个移出 bit31 并在同一次钟里重填的沿。

- `ready` 只许可**当前这一沿**，**不是 look-ahead**：它不说任何关于再下一个沿的事。
- 它是 `busy`、`bit_cnt`、`ce` 的**纯组合函数**，三者都在本模块自己的时钟域里，所以同钟的驱动方可以直接用它，**不需要同步器**。
- **生产者必须"手里已经拿着数据"** 才能在该沿被接受：数据无法在评估该沿的同一次钟里被生产出来，所以驱动方不能用 `ready` 去**触发一次取数**，只能用它在取好数之后决定要不要出示（§3.5 正是这么用的）。

`ready` 是接收逻辑本来就用的两个条件的纯观察，**不改变任何既有行为**：不可接收时提出的 `sample_valid` 仍被丢弃，`dropped` 仍粘滞，一个样点仍占 32 个 `ce` 沿，背靠背样点仍无缝隙。

### 2.5 忙时丢弃 `sample_valid` + 粘滞 `dropped`

`busy` 为高、且这一沿**不是** `freeing` 沿时提出的 `sample_valid` 被**丢弃**：在飞的样点**完全不受影响**，`dropped` 置一；例外就是 `freeing` 沿——忙碌移位器唯一仍能接受样点的沿。`dropped` **粘滞**（直到复位），它高就表示**确实有一个样点无处可去**。`tb_nes_i2s_shifter` 在飞行样点中途注入一个不同样点，断言 `dropped` 升起、`busy` 与位流一位不差、被丢的样点之后也不会补发，且复位后 `dropped` 清零。

### 2.6 `ce = 0` 冻结，不丢位

`ce` 为低时状态机冻结：`out_valid` 保持电平、`out_bit` / `out_lrck` 保持当前位、`busy` 保持电平。所以一个 `ce` 缺口是**把流拉长**而不是丢位；`dropped` 是状态标志，**不受 `ce` 门控**。testbench 在流中途插入 5 个 `ce = 0` 的钟，断言四个流引脚和 `busy` / `dropped` 都不动、位计数也不前进。

### 2.7 周期账

| `ce` 沿 | 效果 |
| --- | --- |
| 0（`sample_valid` 沿，与 `ce` 无关） | 装载 `shift_reg`，`bit_cnt <= 0`，`busy <= 1`；**不**出位 |
| 1 | `out_valid <= 1`，移出 bit0（`sel = 15` → 左 MSB），`lrck = 0` |
| 2..16 | 同上，左声道 16 位出完 |
| 17 | 移出 bit16 → 右 MSB，`lrck_next = bit_cnt[4] = 1`，**第 17 位翻转** |
| 18..31 | 右声道其余位，`lrck = 1` |
| 32 | 移出 bit31；`busy <= sample_valid`（同一次钟里重填，或无重填则归零） |

一个样点 = **32 个 `ce` 有效沿**；`out_valid` 是单周期脉冲，所以恰好 32 个高周期。

---

## 3. `nes_audio_i2s`：CDC FIFO + 读提前窗口 + 组装层 + BCLK 分频 + 输出寄存器

### 3.1 组成（文件头原文）

| 子块 | 作用 |
| --- | --- |
| `nes_cdc_fifo` | 样点环形缓冲，把写侧时钟域送进读侧时钟域 |
| read fetch throttle | 一深度的**读提前窗口**，让 FIFO 读指针不跑到位流前面 |
| intake gate | 把移位器 `ready` 变成串行器期望的**单周期 `sample_valid` 脉冲** |
| `nes_i2s_shifter` | 由 `rd_clk` 驱动、`rd_ce` 使能的 32 位串行器 |
| bclk divider | `mclk` 按 `BCLK_DIV` 分频，50% 占空比 |
| output registers | `dout` / `lrck` 在 `bclk` 上升沿寄存 |

### 3.2 端口合同

| 信号 | 方向 | 域 | 合同 |
| --- | --- | --- | --- |
| `wr_clk` | in | 写 | FIFO 写侧时钟。 |
| `wr_reset` | in | 写 | 写侧异步高有效复位，独立于读侧（见 `nes_cdc_fifo`）。 |
| `wr_en` | in | 写 | 写使能。`wr_full` 为高时被 FIFO 忽略，样点直接丢失。 |
| `wr_left [15:0]` | in | 写 | 左声道样点。 |
| `wr_right [15:0]` | in | 写 | 右声道样点。 |
| `wr_full` | out | 写 | 写侧唯一离开该域的信号，**唯一真正的背压信号**（§3.6）。 |
| `rd_clk` | in | 读 | 读侧时钟。FIFO 读指针、`fetch_hold`、intake 门、移位器、`underflow` 都在此域。 |
| `rd_reset` | in | 读 | 读侧异步高有效复位。 |
| `rd_ce` | in | 读 | 移位器时钟使能（即 §2 的 `ce`），**已属于 `rd_clk` 域**。 |
| `mclk` | in | 输出 | BCLK 分频的源时钟。 |
| `underflow` | out | 读 | 粘滞下溢标志，`rd_reset` 清零。 |
| `bclk` | out | 输出 | `BCLK_DIV = 1` 时直通 `mclk`，否则是分频器输出。 |
| `lrck` | out | 输出 | 声道标记，在 `bclk` 上升沿寄存。 |
| `dout` | out | 输出 | 串行数据，在 `bclk` 上升沿寄存。 |
| `sample_valid` | out | 输出 | **等于移位器 `out_valid`**：每位一个单周期 strobe（**不是采样率**，见 §5）。 |
| `dropped` | out | 两域并集 | `sh_dropped | wr_full_i`（§3.6）。 |

### 3.3 数据布局 `{wr_right, wr_left}`

`assign wr_data = {wr_right, wr_left};` 所以 FIFO 里存的 32 位字**正好是移位器期望的布局**（bit15:0 左、bit31:16 右，左声道先出）；写侧因此是两个 16 位窄口，组装层负责拼接。

### 3.4 破坏性读与 `fetch_hold` 读提前窗口

FIFO 读是**破坏性**的，`rd_data` 是**单个寄存器**：读太早的样点除了那个寄存器**无处可放**，读太晚的样点在串行器放开时又不在手边。串行器每 32 个使能钟消费一个样点，因此只有两个沿重要——**它取新样点的沿**，和**它放开并在同一次钟里重填的 bit31 沿**（后者是忙碌串行器唯一接受的沿，正是 `nes_i2s_shifter` 的 `ready` 所报告的）。

```verilog
assign rd_en = !rd_empty && !fetch_hold;
```

`fetch_hold` 就是读提前窗口：在**读出**一个样点的沿置一（`rd_data` 里有一个已取出的样点），在**串行器取走它**的沿清零。因此**至多一个已取出的样点在飞**，`rd_data` 在其中的样点仍被需要时**绝不会被覆盖**；读速率跟随消费速率——上一个样点刚被消费才发生下一次读，在那之前不再读。

### 3.5 intake pulse = `fetch_hold && ready`；为什么不能直接用 `ready` 去读 FIFO

```verilog
assign fifo_valid = fetch_hold && sh_ready;   // 送入串行器的 sample_valid
```

intake 脉冲是 `fetch_hold && ready`，所以数据**只在接受它的那些沿上**出示、绝不在别的沿上出示，串行器**永远不会丢掉一个样点**；两个条件互斥（一读置位、一取清零），这正是单寄存器 `fetch_hold` 能同时承担"装载"和"清除"的原因。

**不能用 `ready` 直接去读 FIFO**：通过 `ready` 在某沿发起的读要到**下一个钟**才落到 `rd_data`，该样点最早只能在再下一沿被取走，此时一个原本忙碌的串行器已经放开 `busy`，流里就插进一个死钟。改成用 `!fetch_hold` 节流则是**提前**发读——趁串行器还忙——让 FIFO 自身深度加上那一个 `rd_data` 寄存器把样点**一直握到 bit31 沿**到来。`fetch_hold` 在 `rd_clk` 域用 `rd_reset` 异步清零。

### 3.6 背压：`wr_full` 是唯一真丢采样条件

`wr_full` 是写域唯一的背压信号，**生产者必须尊重它**：它是"写进去的样点真的丢了"的**唯一**条件——`wr_full` 为高时的 `wr_en` 被 FIFO 忽略，样点就没了。

```verilog
assign dropped = sh_dropped | wr_full_i;
```

`dropped` 是两条丢样路径的**并集**：移位器的粘滞丢弃，和 `wr_full`。它**只是状态标志**，不是握手，两域都不消费它，所以跨域合并这两项是**有意为之**。（正常情况下 §3.5 的 intake 门让 `sh_dropped` 那条根本不该出现，于是 `dropped` 高基本就等于"写侧在 FIFO 满时还塞了样点"。）

### 3.7 `underflow` 与 `BCLK_DIV` 及输出寄存器

`underflow` 粘滞，`rd_reset` 清零，由"读到 `rd_empty`"置一。有了读提前窗口，读者在串行器忙碌期间把一个样点留在 `rd_data` 里，所以**只要生产者跟不上，样点之间 `rd_empty` 会再次断言**——`underflow` 报的正是这件事，**它不是缺陷**；`tb_nes_audio_i2s` 因此**不检查** `underflow`，并预期它会被断言（文件头原文）。

`BCLK_DIV` 是 **BCLK 周期以 `mclk` 周期计**：`assign bclk = (BCLK_DIV == 1) ? mclk : bclk_int;`。`BCLK_DIV = 1` **直通 `mclk`**（无分频、无相位偏移）；`BCLK_DIV >= 2` 用 `DIV_HALF = BCLK_DIV / 2` 的半周期计数器翻转 `bclk_int`，得到 **50% 占空比**（`DIV_W` 由 `log2i` 算出半计数器位宽，`DIV_HALF` / `DIV_LAST` 都是综合期定死的 `localparam`）。

`dout` / `lrck` 在 **`bclk` 上升沿**（`mclk` 派生域）从 `sh_out_bit` / `sh_out_lrck` 寄存，`rd_reset` 异步清零。这也意味着**输出比移位器状态晚一个 BCLK 沿**——`tb_nes_audio_i2s` 据此断言：strobe（`sample_valid`）比分数据**恰好领先一个 bclk 沿**，所以收集器在 `sample_valid` 上"待命"、在**下一个** `bclk` 上升沿取数。

---

## 4. 时钟域

| 信号 | 所属域 | 去向 |
| --- | --- | --- |
| `wr_clk` / `wr_reset` / `wr_en` / `wr_left` / `wr_right` | 写 | 只进 FIFO 写侧；**只有 `wr_full` 离开写域** |
| `rd_clk` / `rd_reset` / `rd_ce` | 读 | FIFO 读指针、`fetch_hold`、intake 门、移位器、`underflow`、移位器侧 `dropped` |
| `mclk`（→ `bclk`） | 输出 | 分频器，以及经 `bclk` 的 `dout` / `lrck` 输出寄存器 |

跨域规则：

- **读侧 → 输出侧只有单比特。** 进入输出侧的只有移位器的 `out_bit`、`out_lrck`、`out_valid` 三个**单比特**信号。**没有任何多比特值直接跨域**：32 位样点**只在 `rd_clk` 域内交接**（FIFO → `rd_data` → 移位器都在读侧）。
- FIFO 的两组指针是**格雷码字**、经两级同步器互跨（这是 `nes_cdc_fifo` 的事，本文不展开）；32 位样点从"写"到"读"的交接完全发生在 FIFO 内部。
- `ready` 在本模块内被**组合**消费；它是移位器寄存器和 `ce`（即 `rd_ce`）的函数，别的什么都不是，所以用它门控读与 intake **不引入任何新的跨域**。

---

## 5. 和 Zynq 平台的边界

平台接线写在 zynq 平台文档里（`rtl/platform/zynq/nes_zynq_top.v` 文件头 AUDIO LANE 段），这里只讲它如何约束本模块，**不把 decimator 展开成第二个模块文档**。

1. **`audio_sample_valid` 不是采样率。** 那是 **APU 侧**每个样点一个的 strobe（`nes_system_v6.v` 置 `ce_sample = 1'b1`，`nes_apu2a03.v` 在 `ce && ce_sample` 上发，`ce = ce_cpu` 是 1/12 核心钟），速率 `21477272.727 / 12 = 1789772.727 Hz`，是 APU 的自然速率。**它与本模块输出的 `sample_valid` 同名不同物**——后者是**每一位**一个的单周期 strobe（§2.2 / §3.2）。把这 1.79 MHz 的样点流直接喂进 I2S 串行器就是"用 1.79 MHz 串噪声"。
2. **为什么没有 /37。** `1789772.727 / 37 = 48372.235 Hz`，比 48000 Hz 高 `101/13024 = 0.7755%`。误差本身是问题：decimator 与串行器之间是单生产者单消费者 FIFO，**任何**速率失配都会让液面走到底——要么永久 `wr_full`（丢样），要么永久 `rd_empty`（`underflow`）；0.78% 的失配约 **26 秒**抽干/灌满一个 1024 项 FIFO。所以"可接受的采样率误差"在这里不是选项。
3. **有理抽取 2016/55。** 精确匹配的唯一整数抽取是 `/126`（14204 Hz，奈奎斯特只有 7.1 kHz），差得没法用。`nes_i2s_shifter` 每个立体声样点出 16 + 16 位、一位一个 BCLK，所以一帧 32 BCLK、帧率 `25e6/(32*D)`（`BCLK_DIV = D`），与 strobe 速率之比是 `(19687500/11) * (32*D/25000000) = 126*D/55`。要它取整必须 55 整除 `D`，只有 `D = 55`（得 14204.5 Hz）；`D = 16`（合理选择）得 `126*16/55 = 2016/55`，不是整数。于是抽取是**有理的 2016/55**，用**精确的 Bresenham 累加器**实现：2016 个输入进、55 个输出出，永不累积误差。滤波用三级短滑动平均 4、4、2 抽头（零 DSP），不是长 FIR；详见 zynq 平台文档。
4. **为什么 `rd_clk` 和 `mclk` 是同一个网。** `nes_audio_i2s.v:241-249` 用 `posedge bclk` 采 `sh_out_bit` / `sh_out_lrck`，**不加同步器**，从 `rd_clk` 域跨进 `mclk` 派生域。若二者是无关网络，这就是一个**未同步的两比特跨越**。把两者都接到同一个 `mmcm_lcd_clk`，`bclk` 就成了同一时钟的分频版本，采样沿与驱动沿**相位相关**，每一位在整整一个 BCLK 周期（= 8 个 `lcd_clk`）内保持稳定；这也意味着读侧就在 `lcd_clk` 域、`mclk` 也不是新时钟。平台实例化时 `.mclk (mmcm_lcd_clk)`、`.rd_clk (mmcm_lcd_clk)`。
5. **一位延迟。** zynq 平台在 `dout` 上再加一级 `bclk` 寄存器（"I2S 的一位延迟"），把 MSB 推到 §1 引用的"LRCLK 翻转后第二个 BCLK 边沿"；`lrck` 不加延迟。这一级延迟是**平台接线**，不在本模块里。

---

## 6. 证据入口

`tools/sim_all.ps1` 里与本模块相关的目标（在 `-Targets` 白名单中）：

| 目标 id | 内容 | `Run` |
| --- | --- | --- |
| `i2s-shifter-core` | `nes_i2s_shifter` 单独 elaboration | `$false` |
| `i2s-shifter-tb` | `tb_nes_i2s_shifter`（Verilog-2012） | `$true` |
| `audio-i2s-core` | `nes_audio_i2s` elaboration | `$false` |
| `audio-i2s-tb` | `tb_nes_audio_i2s`（Verilog-2012） | `$true` |
| `audio-lane-tb` | Zynq 音频通路整体（decimator + I2S + WM8960 I2C） | `$true` |

源依赖：`i2s-shifter-*` 只编 `nes_i2s_shifter.v`；`audio-i2s-*` 编 `nes_cdc_fifo.v + nes_i2s_shifter.v + nes_audio_i2s.v`；`audio-lane-tb` 编整个 zynq 顶层及其子模块。`i2s-shifter-tb` 与 `audio-i2s-tb` 都是**自校验**的：逐位比对参考模型、检查 `lrck` 的 16/16 分裂与第 17 位翻转；`audio-i2s-tb` 采取背靠背写四样点，并断言"`sample_valid` 之间的 `bclk` 沿不得空闲"、`dropped` 从不升起。

---

## 7. 明确未实现 / 未建模

- **没有采样率转换。** `nes_i2s_shifter` 只按 32 `ce` 沿移一个样点，`nes_audio_i2s` 只按写使能入队；有理抽取器（2016/55）与滑动平均滤波器在 **zynq 平台层**，不在本模块。
- **没有 BCLK / LRC / MCLK 的电气与相位收敛建模。** 输出寄存器的建立/保持、`bclk` 到 `dout` 的偏移、跨芯片走线全部未建模；本文只描述 RTL 的相位关系。
- **没有 codec 就绪门控。** 模块内没有 "codec ready" 端口或逻辑；平台靠把 `rd_reset` 接成来自 `wm8960_i2c` 的 `cfg_done` 来推迟读侧启动，本模块不知道 codec 是否配好。
- **没有被 NES System 顶层实例化。** `nes_i2s_shifter` 只出现在 `nes_audio_i2s` 内部和它的 testbench 里；`nes_audio_i2s` **不在** `nes_system_v6`（NES System 顶层）内部，**也不在** EP4CE10 平台顶层里。本项目里唯一把它接起来的是 **Zynq 平台顶层** `nes_zynq_top.v`（`u_audio_i2s`，`BCLK_DIV = 16`、`ADDR_WIDTH = 6`、`mclk = rd_clk = lcd_clk`）；那份接线写在 zynq 平台文档里，本文不重复。
- **没有综合 / 时序证据。** `sim_all.ps1` 里与本模块相关的门都是**仿真**目标；本文不提供任何综合报告、资源占用数字或时序收敛结论（zynq 平台文档里的 93.7% LUT / 66.3% FF 是平台整体实测，不是本模块的）。
- **`bclk` 分频的验证是按 `BCLK_DIV = 1` 做的。** `tb_nes_audio_i2s` 用 `BCLK_DIV = 1`（`bclk = mclk = rd_clk`，同周期同相位）；`BCLK_DIV >= 2` 的 50% 占空比路径由 zynq 平台的实际 `BCLK_DIV = 16` 在 `audio-lane-tb` 里被间接覆盖，本模块自带 testbench **没有**单独穷举分频比。
- **发送专用。** 两个模块都是 transmit only；WM8960 的 ADC / `aud_adc_lrc` / `aud_adcdat` 方向没有对应逻辑，平台里那些引脚未连接（zynq 顶层文件头明确写了这一点）。
- **testbench 未覆盖：** 没有把 `nes_audio_i2s` 接上真实的 `nes_system_v6`；没有用 `wr_full` 主动灌满 FIFO 去复现"写侧丢样"那条 `dropped` 路径（`audio-i2s-tb` 断言的是 `dropped` **从不**升起的正常路径）；没有对 `underflow` 的粘滞行为做逐拍核对（它被预期断言、不作检查）。
