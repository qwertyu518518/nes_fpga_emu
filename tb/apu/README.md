# NES APU 2A03 v1 testbench

`tb_nes_apu2a03.v` 是 `rtl/nes_core/apu/nes_apu2a03.v` 的自检 testbench。它直接实例化 APU，自己驱动 `clk`/`ce`/`ce_sample`、寄存器总线和 DMC 取样总线模型，不下载 ROM，不读外部文件，不使用层次引用去**写**内部状态（唯一的层次读是 `dut.mixed_sample`，用来观察组合混音值）。

v1 在 v0 的 Pulse 基础上补齐 Triangle、Noise、DMC 和 CPU 总线取样请求接口。仍然**没有**实现：IRQ filter、完整 203 项 TND 逐位非线性 mixer、DC 偏置与高通/低通滤波、重采样 FIFO、WM8978/I2S、精确 open bus、精确到 micro-cycle 的寄存器副作用。详见“明确未实现”。

## 文件

| 文件 | 内容 |
| --- | --- |
| `rtl/nes_core/apu/nes_apu_length_lut.v` | 32 项 length counter 查表（纯组合），四个通道共用。 |
| `rtl/nes_core/apu/nes_apu_pulse.v` | 单个 pulse 通道（timer、duty、length、envelope、sweep）。`ONE_COMP` 参数区分 Pulse 1 的负 sweep 补偿。 |
| `rtl/nes_core/apu/nes_apu_triangle.v` | Triangle：32 步序列、无预分频 timer、7 位线性计数器、reload flag、length。 |
| `rtl/nes_core/apu/nes_apu_noise.v` | Noise：15 位 LFSR、short/long 模式、NTSC 周期表、envelope、length。 |
| `rtl/nes_core/apu/nes_apu_dmc.v` | DMC：rate 表、sample buffer、8 位输出单元、7 位 delta DAC、loop/IRQ，以及 `dmc_bus_req/dmc_addr/dmc_rdata/dmc_ack` 取样请求接口。 |
| `rtl/nes_core/apu/nes_apu2a03.v` | 顶层：寄存器译码、`$4015`、`$4017`、frame sequencer、IRQ 汇总、整数五通道 mixer、采样输出、debug。 |
| `tb/apu/tb_nes_apu2a03.v` | 自检 testbench，`$fatal` 断言，末尾打印 `PASS nes_apu2a03 v1`。 |
| `tb/apu/run_apu_tb.do` | ModelSim/Questa 的同一条编译和运行命令。 |

## 接口极性

| 信号 | 方向 | v1 合同 |
| --- | --- | --- |
| `reset` | in | 高有效**异步**复位，复位全部寄存器、通道状态、frame counter、frame/DMC IRQ 和采样寄存器。 |
| `ce` | in | 高有效 CPU cycle enable。**所有**计数器（frame counter、pulse timer/预分频、triangle timer、noise timer/LFSR、DMC rate counter、length、envelope、线性计数器、待装载 length）只在这里推进。`ce=0` 时 APU 内部状态完全冻结。 |
| `ce_sample` | in | 采样使能。只有 `ce=1 && ce_sample=1` 的那个 `clk` 上升沿锁存一个新的 sample。 |
| `reg_cs` / `reg_we` | in | 寄存器访问在 `clk` 上升沿完成，**不受 `ce` 门控**（和 `nes_ppu2c02` v0 一致）。`reg_addr[4:0]=0x00..0x17` 对应 `$4000..$4017`。 |
| `reg_dout` | out | 组合读出。`$4000-$4013` 返回按 live 字段重组的写入值；`$4015` 返回 status；其余地址返回 `$00`。 |
| `irq` | out | **电平**输出（不是脉冲）= `frame_irq_flag \| dmc_irq_flag`。 |
| `dmc_bus_req` | out | **电平** DMC 取样请求。拉高表示 APU 需要一个样本字节，并且会一直保持到 `dmc_ack` 出现。**CPU 必须在 `dmc_bus_req && !dmc_ack` 期间停住总线。** |
| `dmc_addr` | out | 请求对应的 CPU 地址（`$8000..$FFFF`，`$FFFF` 之后回 `$8000`）。在 `dmc_bus_req` 期间有效。 |
| `dmc_rdata` | in | 总线侧返回的字节。 |
| `dmc_ack` | in | 总线侧授权脉冲。与 `dmc_rdata` 同拍有效。**不需要** `ce=1`：APU 在任意 `clk` 上升沿采样 `dmc_bus_req && dmc_ack`，这样 CPU 被取样停住时 APU 不会自锁。 |
| `sample_valid` | out | 1 周期脉冲，只在 `ce && ce_sample` 的沿上为高。 |
| `sample_left` / `sample_right` | out | 16 位**无符号**幅度（0..32767），v1 是单声道，左右相同。 |
| `dbg_frame_phase` | out | frame 事件序号 0..4，见“frame sequencer”。 |
| `dbg_frame_irq` / `dbg_dmc_irq` | out | 两个 IRQ 源各自的标志寄存器。 |
| `dbg_frame_count` | out | frame counter 内部计数值 0..29829（4-step）/ 0..37281（5-step）。两个上界各比 step 结算沿大 1，是 NESdev “计数器在 29830 / 37282 个 CPU cycle 后归零” 里的那个保持周期。 |
| `dbg_pulse1_*` / `dbg_pulse2_*` | out | length、period、duty step、channel level、envelope decay、envelope divider、sweep mute。 |
| `dbg_pulse_sum` | out | 两个 pulse level 之和 0..30，pulse mixer 查表索引。 |
| `dbg_tri_*` | out | length、period(11)、seq_step(5)、linear_cnt(7)、linear_reload_flag、level。 |
| `dbg_noise_*` | out | length、period(12，查表值)、lfsr(15)、mode、mute、level、env_decay、env_div。 |
| `dbg_dmc_*` | out | sample_addr、current_addr、bytes_remaining、rate_cnt、bits_remaining、bits、sample_buf、output(7)、silence、buf_empty、active。 |
| `dbg_tnd_sum` / `dbg_mix_pulse` / `dbg_mix_tnd` / `dbg_mix_sum` | out | 混音器的四个中间量：TND 索引、两张 LUT 的输出、未限幅的 17 位总和。 |

## 寄存器

| 地址 | 写 | 读 |
| --- | --- | --- |
| `$4000` / `$4004` | duty=`d[7:6]`、length halt=`d[5]`、const volume=`d[4]`、volume/period=`d[3:0]` | 同一字段重组 |
| `$4001` / `$4005` | sweep enable=`d[7]`、sweep period=`d[6:4]`、negate=`d[3]`、shift=`d[2:0]` | 同一字段重组 |
| `$4002` / `$4006` | period[7:0] | `{3'b000, period[7:0]}` |
| `$4003` / `$4007` | length index=`d[7:3]`、period[10:8]=`d[2:0]` | `{length index, period[10:8]}` |
| `$4008` | control=`d[7]`、linear reload=`d[6:0]` | `{control, linear reload}` |
| `$4009` | period[7:0] | `{3'b000, period[7:0]}` |
| `$400A` | period[10:8]=`d[2:0]`，**并置 linear reload flag**；不装 length | `{5'b00000, period[10:8]}` |
| `$400B` | length index=`d[7:3]`、period[10:8]=`d[2:0]`，**并置 linear reload flag** | `{length index, period[10:8]}` |
| `$400C` | halt=`d[5]`、const volume=`d[4]`、envelope period=`d[3:0]` | `{1'b0, halt, const, env_period}` |
| `$400D` | 忽略 | `$00` |
| `$400E` | mode=`d[7]`、period index=`d[3:0]` | `{mode, 3'b000, period index}` |
| `$400F` | length index=`d[7:3]`，**并把 envelope decay 置 15** | `{length index, 3'b000}` |
| `$4010` | IRQ enable=`d[7]`、loop=`d[6]`、rate index=`d[3:0]` | `{irq_enable, loop, 2'b00, rate index}` |
| `$4011` | output level=`d[6:0]` | `{1'b0, output level}` |
| `$4012` | sample page，`sample_addr = $C000 + value×64` | `sample_page` |
| `$4013` | sample length 字节数-1，`sample_length = value×16 + 1` | `length` |
| `$4015` | `d[0..3]` = Pulse 1/2/Triangle/Noise enable；`d[4]` = DMC enable。**并清 frame IRQ 和 DMC IRQ** | bit0..3 = 四个 length 非零，bit4 = DMC 仍在取样，bit5 恒 0，bit6 = frame IRQ，bit7 = DMC IRQ。**读清 frame IRQ 和 DMC IRQ。** |
| `$4017` | `d[7]` = 5-step，`d[6]` = IRQ inhibit；写总是把 frame counter 和 phase 清零 | `$00` |

`$4014`（OAM DMA）和 `$4016`（控制器 1）写入被忽略、读出 `$00`。**OAM DMA 不在 APU 里**，见“CPU stall / DMA 边界”。

`$400A` 与 `$400B` 共享 `period[10:8]`，所以 `$400A` 的读回值是 3 位高周期（`{5'b0, period[10:8]}`），不是写入的原始字节。NESdev 只把“置 linear reload flag”归给 `$400A`，length 装载只归给 `$400B`；本实现按 NESdev，因此 `$400A` **不**装 length（Obara 的 `set_tri_length()` 两个地址共用，会顺带装 length，这里没有跟随）。

### `$4015` 的 v1 合同

- 读返回的是**读沿之前**的 flag 组合，清除发生在同一个 `clk` 上升沿；写 `$4015` 同样清 frame IRQ 和 DMC IRQ。
- 写 `$4015` 把某通道 enable 位为 0 时，该通道 length counter 立刻清 0（和 Obara `set_status()` 一致）。重新置 1 不会重装 length，必须再写一次 length 寄存器。
- bit5 是 open bus / 内部总线行为的占位，**恒读 0**，没有假装实现。
- 写 `$4015` 且 `d[4]=0` 会中止 DMC：清 `bytes_remaining`、清内部 `active`、撤掉未完成的总线请求。已经进入 sample buffer 的那个字节**不**被丢弃，重新置 1 后会先被播放完再取新字节。
- 写 `$4015` 且 `d[4]=1` 时，若 `bytes_remaining == 0` 就重启样本（`current_addr = sample_addr`、`bytes_remaining = sample_length`）；若 sample buffer 也是空的，立刻发起一次总线请求。

## frame sequencer

NTSC 固定时序，按 `ce` 计数。计数器在“事件沿”结算，`dbg_frame_count` 显示结算后的值。

| 模式 | step 1 | step 2 | step 3 | step 4 | step 5 | 归零 | 周期 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 4-step（`$4017[7]=0`） | 7457 Q | 14914 Q+H | 22371 Q | 29829 Q+H+IRQ | — | 29830 | **29830** |
| 5-step（`$4017[7]=1`） | 7457 Q | 14914 Q+H | 22371 Q | 29830 无 | 37281 Q+H | 37282 | **37282** |

- 事件沿之后 counter **不立即清零**：4-step 停在 29829、5-step 停在 37281 各一个 `ce`（hold 周期），下一个 `ce` 才回 0。所以 4-step 的 IRQ→IRQ 周期是 **29830** 个 `ce`，5-step 的 step1→step1 周期是 **37282** 个 `ce`。
- `dbg_frame_phase`：复位后为 0；过 7457 变 1、14914 变 2、22371 变 3；4-step 的 29829 沿立刻回 0 并保持到 29830 归零，5-step 的 29829 沿变 4 并保持到 37281，37281 沿回 0。
- 5-step 永远不置 frame IRQ。
- half frame（step 2、step 4）驱动 length counter（四个通道）和 pulse sweep；quarter frame（4-step 是 1..4，5-step 是 1、2、3、5）驱动 pulse/noise envelope 和 triangle 线性计数器。两个时钟是独立的 action bit。
- `inhibit`（`$4017[6]`）阻止 frame IRQ 置位，但不阻止 quarter/half 时钟，也不改变 29830 的周期。写 `$4017` 且 `d[6]=1` 会 ack（清）frame IRQ。
- 保留 v0 的微周期限制，见“明确未实现”。

## Triangle 通道

- 32 步序列 `15 14 ... 1 0 0 1 ... 14 15`（`tri_sequence()` 用 `step[4]` 选择升/降半周，不需要 32 项表）。
- timer **没有预分频**，每个 `ce` 递减一次，`period` 满时 step 加一并重装 `period-1`（`period=0` 时每个 `ce` 一步）。这和 pulse 的 `16×(period+1)` 是两套不同的约定：triangle 的寄存器值就是真实周期。
- step 只在 `enable && length != 0 && linear != 0` 时前进。linear counter 为 0 时 timer 仍然跑（内部状态继续变化），但 step 冻结、输出静音——这是 NESdev 明确的行为，也是某些软件用 triangle 线性计数器做时序的基础。
- 线性计数器（7 位）由 quarter frame 驱动，顺序和 Obara `quarter_frame()` 一致：**先** reload，**再** 看 `control` 是否清 reload flag。
- 写 `$400A` / `$400B` 都置 reload flag；写 `$4008` **不**置。
- `control`(`$4008[7]`) 同时是 length counter 的 halt。
- 输出 level = `enable && length != 0 && linear != 0 ? tri_sequence[step] : 0`。**没有** Obara `get_sample()` 里那个 `period > 1` 的门控：把 period 写得很小得到的是超声频，不是静音，所以硬件上不需要那个门。

## Noise 通道

- 15 位 LFSR，复位值 1，`feedback = bit0 ^ (mode ? bit6 : bit1)`，`lfsr <= {feedback, lfsr[14:1]}`。`mode` 来自 `$400E[7]`，**只影响反馈抽头，不影响周期表**。
- 输出 = `enable && length != 0 && !mute && !lfsr[0] ? (const ? volume : env_decay) : 0`。
- 周期表（NTSC，12 位）：`4 8 16 32 64 96 128 160 202 254 380 508 762 1016 2034 4068`。`dbg_noise_period` 显示查表值，内部重装值是 `表值-1`，所以表值就是真实周期。PAL 表没有实现。
- envelope 语义与 pulse 完全一致（见 v0 README 的 ENVELOPE 一节）；`$400C[5]` 同时是 length counter 的 halt。
- `mute` 只有一条：`period == 0`（即 period index 复位且没写过 `$400E`）。NESdev 的“period index 0 且 LFSR bit0 = 1 时额外静音”这类细节没有实现。

## DMC 通道

- rate 表（NTSC，重装值 = 周期-1）：`427 379 339 319 285 253 225 213 189 159 141 127 105 83 71 53`。
- `sample_addr = $C000 + $4012×64`，`sample_length = $4013×16 + 1`。
- 输出单元是两级结构，和 Obara 的 `sample_buf` / `bits` / `bits_remaining` / `silence` 一一对应：
  1. `sample_buf` 是 1 字节 DMA 缓冲；`buf_empty` 表示它空着。
  2. `bits` / `bits_remaining` 是输出移位寄存器；`silence` 表示移位寄存器里没有可播的位。
  3. rate tick 上先消费一位（`bits[0]` 决定 delta），`bits_remaining` 减到 0 时再从 `sample_buf` 装一个新字节；装进去的瞬间 `sample_buf` 就空了，于是**同时**发起下一个字节的总线请求。8×54 = 432 个 CPU cycle 的播放窗口远大于一次取样延迟，所以正常情况下取数总是提前完成。
  4. 装不进新字节时 `silence=1`，输出保持，移位计数器继续走到 0 再等下一次 refill。
- delta 调制：`bit=1 → level+2`（上限 127），`bit=0 → level-2`（下限 0），**silence 时不更新**。这是“clamped counter”的整数化写法。
- 样本结束：`bytes_remaining == 0 && !loop` 且移位寄存器刚好空的那一 tick，置 DMC IRQ（若 `irq_enable`）、清内部 `active`。`loop=1` 时地址和长度回到 `sample_addr` / `sample_length`，永远不置 IRQ。
- 地址回绕：`current_addr == $FFFF` 时下一个字节取自 `$8000`，不是 64 KiB 模运算。
- 同一 tick 上同时发生“字节送达”和“样本结束判定”时，用的是**送达之后**的 `bytes_next`，所以单字节样本不会多取一个字节。
- 内部 `active`（播放使能）和 `$4015` 的 enable 位分开：`$4015` 位是外部开关，`active` 是内部状态，自然结束时自己清 0，必须再写一次 `$4015[4]=1` 才会重开。`$4015` bit4 读出的是 `bytes_remaining != 0`，和 Obara 一致。

## 混音和采样（教学近似）

- 两张纯整数查表，**没有 `real`/`float`、没有除法器、没有滤波**：
  - `pulse_mix_lut[N] = round(95.88 × 32767 × N / (8128 + 100N))`，`N = pulse1_level + pulse2_level`（0..30），`lut(30) = 8470`。
  - `tnd_mix_lut[M] = round(163.67 × 32767 × M / (24329 + 100M))`，`M = 3×triangle + 2×noise + dmc`（0..202），`lut(202) = 24328`。
- `mixed_sample = min(pulse_lut + tnd_lut, 32767)`。`dbg_mix_sum` 暴露未限幅的 17 位和，最大 32798，所以限幅分支真的会走到。
- 没有 DC 偏置、没有高通/低通、没有 sample-and-hold、没有重采样 FIFO、没有左右分路。`sample_left/right` 是无符号幅度、左右相同；接真实音频链需要外部做直流偏置和符号化。
- `ce && ce_sample` 的沿上 `sample_left <= mixed_sample`、`sample_right <= mixed_sample`、`sample_valid <= 1`；其他沿 `sample_valid <= 0`，`sample_left/right` 保持。
- mixer 的取值点不只在一处：TB 的 `check_mixer_now` 在多个测试里逐 `ce` 调用，把 `dbg_tnd_sum` / `dbg_mix_pulse` / `dbg_mix_tnd` / `dbg_mix_sum` 全部和 TB 内部用整数公式重算的参考值对比（本次运行累计校验了 35538 个工作点）。`MIXER tnd lut indices 0-127` 那一组是逐项穷举 `$4011` 的 128 个取值。

## 复位值

| 寄存器 | 复位值 |
| --- | --- |
| `$4000-$4013` | `$00`（duty 0、sweep disable、period 0、length index 0、control 0、linear reload 0、rate index 0） |
| envelope decay / divider | `$0` / `$0`，restart 标志 0 |
| length counter | `$00`（因此复位后四个 length 通道都静音） |
| pulse timer / 预分频 / duty step | `0` / `0` / `0` |
| pulse sweep | disable，divider `0`，reload 值 1，reload 标志 0 |
| triangle timer / seq step / linear counter | `0` / `0` / `0`，reload flag 0 |
| noise timer / LFSR | `0` / `15'd1` |
| DMC rate counter / 输出位 / sample buffer | `0` / `0` / `0`，`buf_empty=1`、`silence=1`、`active=0`、`irq_flag=0` |
| DMC `sample_addr` / `current_addr` / `bytes_remaining` | `$C000` / `$C000` / `0` |
| `$4015` enable | 全部 0 |
| frame mode / inhibit / counter / phase / IRQ | 4-step / 0 / 0 / 0 / 0 |
| `dmc_bus_req` / `dmc_ack` | 0 |
| sample_left / right / valid | `0` / `0` / 0 |

复位后 `dbg_pulse1_mute`、`dbg_pulse2_mute` 和 `dbg_noise_mute` 是 **1**，因为 `period = 0`（pulse 走 `period < 8` 那条，noise 走 `period == 0`）。这是设计行为，不是 bug。

## CPU stall / DMA 边界

v1 只**定义并测试**接口合同，完整 DMA 状态机不在 APU 里：

- **DMC 取样**：`dmc_bus_req` 是电平，`dmc_addr` 是请求地址。系统侧（CPU 总线仲裁）必须实现：请求期间停住 CPU（不推进 `ce_cpu` 也不推进 CPU 状态机）、在若干个 `clk` 内给出 `dmc_ack` 和 `dmc_rdata`。APU 侧不读任何 RAM，也不缓存整段样本。TB 里的总线模型就是这个合同的可执行版本：一个 `dmc_pending` 寄存器在请求拉高后一个 `clk` 拉高授权，`dmc_rdata` 组合来自 `dmc_addr`。
- **为什么 `dmc_ack` 不需要 `ce`**：如果 `ce` 跟着 CPU 一起被停住，“APU 发出请求 → CPU 让出总线 → 数据回来”就会死锁。所以字节在任意 `clk` 上升沿采样，输出单元仍然只在 `ce` 上推进。
- **停顿时长**：本实现不规定停几个 cycle，也不实现 `/RDY` toggle、DMC 造成的额外 1/4 cycle、地址冲突时的 dummy read。总线侧给多少个 stall cycle，APU 就只是多等多少个 `clk`（`rate counter` 停住），行为是自洽的。
- **OAM DMA（`$4014`）完全不在 APU 里**。按任务划分它由 PPU lane / CPU 总线提供；APU 对 `$4014` 的写忽略、读回 `$00`，没有任何 OAM DMA 请求端口。
- **IRQ 屏蔽与 mapper IRQ 仲裁**也不在 APU 里。`irq` 只是 `frame_irq_flag | dmc_irq_flag` 的电平 OR，没有 filter、没有上升沿检测、没有 CPU 侧屏蔽寄存器。

## 断言覆盖

`tb_nes_apu2a03.v` 使用 `$fatal`，27 个 test task 共输出 31 条 PASS 行：

1. **RESET**：38 项 debug 输出复位值、24 个寄存器地址读回 `$00`、复位后三个 mute 为 1、`dmc_bus_req` 空闲。
2. **REGISTER**：`$4000-$4007` 逐个写入再读回；`$4014/$4016/$4017` 读回 `$00`。
3. **CE=0 FREEZE**：`ce` 拉低 4000 个 `clk`（两次），验证 frame phase/count、两个 pulse length、period、duty step、level、envelope decay/divider、irq、mute、`sample_left` 全部不动，`sample_valid` 保持低；`ce=1` 恢复后 frame counter 继续走、`sample_valid` 重新拉高，去掉 `ce_sample` 后 `sample_valid` 落下而 `sample_left/right` 保持。
4. **STATUS**：两个 pulse 的 `$4015` 长度位、length 表索引 1→254 / 0→10、half 递减而 quarter 不减、disable 清 length、re-enable 不重装、10 个 half frame 后 length 到 0 且通道静音。
5. **DUTY**：duty=2、常量音量 15、period=8，采集 8 个连续 duty step，验证 step `1..7,0`、level `15 15 15 15 0 0 0 0`、对应 mixer 输出 `lut(15)=4895` / `lut(0)=0`；再用两个同相通道验证 `lut(30)=8470` 和左右相同。
6. **ENVELOPE**：33 个 quarter 采样点 `15 15 14 14 13 13 ... 1 1 0 0 15`（含 halt 回绕）、halt 冻结 length、常量音量 8、清 const 后 level 跟 `env_decay`。
7. **SWEEP**：target 溢出立即静音、写回合法值解除、period 4 静音、负 sweep 的 Pulse 1 多减 1、shift=0 不改 period。
8. **FRAME 4-step**：四个 phase 边界逐个核对（含 29828 沿之前仍是 phase 3 且无 IRQ），step-4 事件落在第 29829 个 `ce`、counter 停在 29829 一个保持周期、第 29830 个 `ce` 归零，`$4015` 读清、写 `$4015` 也清，用 mark 差值断言 IRQ→IRQ 正好 **29830** 个 `ce`。
9. **FRAME 5-step**：连跑两个 37282 ce 帧，五个 phase 边界逐个核对，step1→step1 正好 **37282** 个 `ce`，整个 5-step 期间 IRQ 恒低，切回 4-step 后 IRQ 在第 29829 个 `ce` 恢复。
10. **FRAME inhibit/ack**：inhibit 时 quarter/half 照常但 IRQ 恒低（两帧都是 29830），写 `$4017=$00` 后恢复，写 `$4017=$40` ack。
11. **TRIANGLE REGISTERS**：`$4008-$400B` 读回（`$400A` 只回 3 位共享高周期）、period 由 `$4009`+`$400A/$400B` 拼装、length index 字段读回、disable 时不装 length。
12. **TRIANGLE 32 步序列**：period=0、control=1、linear=127，逐 `ce` 采 32 个 step，验证 `seq_step` 严格 `1..31,0` 且 level 严格等于 `tri_sequence(step)`，每个点都过一遍 mixer 校验。
13. **TRIANGLE 线性计数器**：Q1 reload 127、control=0 时 flag 被清、之后每 quarter 减 1、跨帧继续减、reload 值 0 时停在 0 并静音、`$4008` **不**重新武装 flag、`$400B` 重新武装、control=1 时 flag 保持且 linear 恒 127、linear=0 时 500 个 `ce` 内 step 不前进。
14. **TRIANGLE length**：disable 时不装、enable 后装、half 递减而 quarter 不减、control bit 冻结 length、清 control 后恢复、同沿 length 装载优先于 half 递减、disable 清零。
15. **NOISE REGISTERS**：`$400C/$400E/$400F` 读回（含 bit7 未使用读 0、mode 回读、length index 字段），**16 项 NTSC 周期表逐项核对**。
16. **NOISE LFSR**：复位值 1，第一次 tick 得 `0x4000`；short 模式（tap bit1）连跑 64 次 tick 与 TB 参考模型逐位比对，并逐次验证 `lfsr[0]==0 → level 15` / `lfsr[0]==1 → level 0`；long 模式（tap bit6）连跑 32 次；`$4015` disable 门控。
17. **NOISE envelope/length**：quarter 序列 `15 15 14 14 13`、half 递减而 quarter 不减、halt 冻结/恢复、disable 清零。
18. **DMC REGISTERS**：`$4010-$4013` 读回、`sample_addr` 解码（含 `$C000` 下界和 `$FFC0` 上界）。
19. **DMC 总线请求合同**：disable 时永不请求；enable 立刻请求、地址等于 `sample_addr`、`$4015[4]=1`；ack 后缓冲锁存、地址 +1、`bytes_remaining` 递减到 0、通道在字节播完前仍 active；disable 中止未完成请求并清 `bytes_remaining`，之后 6 个 `clk` 不再请求；re-enable 重启样本、地址复位、缓冲里已有一个字节所以不立刻请求，等它消费完才发出指向 `sample_addr` 的新请求。
20. **DMC rate/输出单元**：rate index 15 的重装值 53、第一个 tick 后 `rate_cnt=53` 且 `bits_remaining=8`、空缓冲时 `silence=1` 且请求保持；再验证 53 个 `ce` 后 `rate_cnt` 归零但 tick 未发、第 54 个 `ce` 才发；连续 23 个 rate tick 逐个用 TB 的 delta 参考模型核对 7 位电平（覆盖 8 个静音 tick + 两个字节共 16 个数据 bit），最后电平为 6、地址前进 2、预取了第 3 个字节。
21. **DMC delta/IRQ**：单字节样本 `$5A` 的 8 个 delta bit 逐个核对（终值 2），第 8 个 bit 播完的那一 tick 置 DMC IRQ 并停机、bit 计数器停在 0、输出单元转静音；`$4015` 读清、重放后再置、写 `$4010` 关 IRQ enable 清、写 `$4015` 清。
22. **DMC loop/回绕**：65 字节 loop 样本从 `$FFC0` 起，第 64 次取数验证 `$FFFF → $8000` 回绕，第 65 次后 `bytes_remaining` 回到 65、地址回到 `$FFC0`、通道保持 active、IRQ 恒低。
23. **STATUS 全通道**：`$4015` bit0..4 全部置位、bit5 恒 0，四个 length 都是 254、DMC 已在取样；再分两次 disable 验证 length 逐通道清零而未 disable 的通道保持。
24. **MIXER LUT 穷举**：写 `$4011` 遍历 0..127，逐项核对 `dbg_dmc_output`、`dbg_tnd_sum` 和 `dbg_mix_tnd`；同时自检 TB 的 pulse 参考公式在 15 和 30 两个点。
25. **SAMPLE 输出**：pulse 电平 15 时 `sample_left/right` 跟随 4895、`sample_valid` 拉高；去掉 `ce_sample` 后 `sample_valid` 落下而 `sample_left/right` 保持 4895。
26. **MIXER 五通道限幅**：五通道全部开到各自最大值并在 40000 个 `ce` 内搜到 `pulse_sum=30` + `tnd=202` 的工作点（本次运行 8223 个 `ce` 命中），核对 `pulse_lut(30)=8470`、`tnd_lut(202)=24328`、未限幅和 32798、限幅输出 32767。
27. **IRQ 汇总**：DMC IRQ 单独置位时 `$4015` 回 `bit7`、读清；重放后在 DMC IRQ 保持期间 frame IRQ 照常置位，`$4015` 同时回 `0xC0`、一次读把两个标志都清掉、IRQ 线落低；再单独测 frame IRQ→IRQ 仍是 **29830** 个 `ce`。

## 运行

在仓库根目录执行，输出放在临时目录，不向仓库写文件：

```powershell
$tmp = Join-Path $env:TEMP 'op_fpga_emu'
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
& 'C:\iverilog\bin\iverilog.exe' -g2001 -Wall -s nes_apu2a03 -o (Join-Path $tmp 'nes_apu2a03_core.vvp') 'rtl\nes_core\apu\nes_apu_length_lut.v' 'rtl\nes_core\apu\nes_apu_pulse.v' 'rtl\nes_core\apu\nes_apu_triangle.v' 'rtl\nes_core\apu\nes_apu_noise.v' 'rtl\nes_core\apu\nes_apu_dmc.v' 'rtl\nes_core\apu\nes_apu2a03.v'
& 'C:\iverilog\bin\iverilog.exe' -g2012 -Wall -s tb_nes_apu2a03 -o (Join-Path $tmp 'tb_nes_apu2a03.vvp') 'rtl\nes_core\apu\nes_apu_length_lut.v' 'rtl\nes_core\apu\nes_apu_pulse.v' 'rtl\nes_core\apu\nes_apu_triangle.v' 'rtl\nes_core\apu\nes_apu_noise.v' 'rtl\nes_core\apu\nes_apu_dmc.v' 'rtl\nes_core\apu\nes_apu2a03.v' 'tb\apu\tb_nes_apu2a03.v'
& 'C:\iverilog\bin\vvp.exe' (Join-Path $tmp 'tb_nes_apu2a03.vvp')
```

6 个 RTL 文件是纯 Verilog-2001（无 `initial`、无 memory 初始化、无 vendor primitive、无 latch、无 SystemVerilog 构造），可以用 `-g2001 -Wall` 单独 elaborate 且零 warning。testbench 使用 `$fatal` 和 64 位整数参考公式，编译用 `-g2012`，和仓库现有 CPU/PPU testbench 一致。

下面是本版本的完整期望输出，逐行对应一个 test task；vvp 退出码 0，仿真时间约 11.86 ms，实测运行约 6.9 s：

```text
RESET all-zero state and 24 register readbacks PASS
REGISTER $4000-$4007 readback and $4014/$4016/$4017 reads PASS
CE=0 freeze of frame/length/period/duty/envelope/irq PASS
STATUS $4015 length status, disable and exhaustion PASS
DUTY sequence 01234567 level/mixer samples PASS
ENVELOPE decay, halt wraparound and constant volume PASS
SWEEP target overflow, period floor, negate difference and shift gate PASS
FRAME 4-step quarter/half phase and 29830 ce IRQ period PASS
FRAME 5-step no IRQ and 37282 ce period PASS
FRAME inhibit and acknowledge contract PASS
TRIANGLE $4008-$400B readback and period assembly PASS
TRIANGLE 32-step sequence 15..0..0..15 and mixer inputs PASS
TRIANGLE linear counter reload, halt, step gate and re-arm PASS
TRIANGLE length load gate, half clock, control halt and disable PASS
NOISE $400C-$400F readback and full NTSC period table PASS
NOISE short-mode LFSR sequence and output gate PASS
NOISE long-mode LFSR feedback tap 6 PASS
NOISE $4015 disable gate PASS
NOISE envelope, length status, halt and disable PASS
DMC $4010-$4013 readback and sample address decode PASS
DMC bus request/ack/address contract PASS
DMC abort on $4015 disable and restart contract PASS
DMC rate table reload, 54 ce tick spacing and 8 bits per byte PASS
  delta test byte = 5a
DMC delta modulation, output unit refill and end-of-sample IRQ PASS
DMC $FFFF to $8000 address wrap, loop reload and no IRQ PASS
STATUS $4015 bits 0-4 and the bit5 open-bus stub PASS
MIXER tnd lut indices 0-127 and pulse lut match the reference formula PASS
SAMPLE register latch, hold and sample_valid strobe PASS
MIXER five-channel sum and the 32767 clamp PASS after 8223 ce
MIXER validated 35538 operating points against the reference formula
IRQ frame+dmc aggregation, independent clear and 29830 ce period PASS
PASS nes_apu2a03 v1
```

任何 `$fatal` 命中会让 vvp 以非零退出码结束并打印失败点和实际值；`tb_nes_apu2a03.v` 顶部还有 `global timeout`（400 ms 仿真时间）兜底断言。

`run_apu_tb.do` 提供 ModelSim/Questa 的同一条编译和运行命令。**当前仓库没有 ModelSim、Quartus 或 EP4CE10 上板证据，该脚本未被本版本验证；上面所有 PASS 只来自 Icarus Verilog 纯 RTL 仿真。**

`tools/sim_all.ps1` / `tools/sim_cpu.ps1` 不包含 APU，v1 没有改这两个脚本（不在本任务写入范围内）。

## 相对 v0 的 testbench 修正

`FRAME 4-step` 那一组里，“step-4 之前应该还是 phase 3 且没有 IRQ”这条中间探针原本放在 `tick(1)` **之后**，与 RTL（以及本文档的 29829 事件沿）差一个 tick。v1 把它移到 `tick_to_count(29828)` 之后、那一个 `tick(1)` 之前，并把 IRQ→IRQ 的 mark 点移到 IRQ 置位的那一个 `ce`（否则测出来的是 29829 而不是 29830）。RTL 的 frame 时序本身没有改动。

## 明确未实现

以下都没有实现，也**没有**用假数据、假 IRQ 或占位通道冒充：

- **微周期级别的寄存器副作用**（保留 v0 的限制）：`$4017` 写后 3/4 cycle 的 frame counter reset delay 没实现，`reg_we` 沿上 frame counter 和 phase 立即清零；5-step 写入时“立刻额外 clock 一次 quarter+half”没实现。
- frame IRQ flag 的更精细置位点：v1 仍在 step-4 事件沿（第 29829 个 `ce`）置 `frame_irq_flag`。NESdev 描述的“flag 在 29828 那个 cycle 就已置位、且 `$4015` 在 29829 读回 0 也照样抑制本帧 IRQ”的读窗口没实现，任何 `ce` 上的读都只是简单清标志。
- `$4002` 读对 length / sweep 的副作用没有；`$4015` 读只清两个 IRQ flag 和报告状态。
- 精确 open bus：`$4015` bit5 恒 0。
- DMC 的 CPU stall **时长**、ready toggle、DMC 造成的额外 1/4 cycle、地址冲突 dummy read：没有。`dmc_bus_req/dmc_addr/dmc_ack/dmc_rdata` 的合同如上，DMC 不在 APU 内读任何 RAM。
- OAM DMA（`$4014`）：没有，由 PPU lane / CPU 总线负责；APU 侧只有“写忽略、读 0”。
- IRQ filter、frame IRQ 与 mapper IRQ 的仲裁、CPU 侧屏蔽：没有。`irq` 只是两个标志的电平 OR。
- PAL 制式、NTSC 之外的 period 表：没有，frame 时序、noise 周期表、DMC rate 表都只有 NTSC。
- 完整非线性 mixer 的逐位精确值、DC 偏置、高通/低通/Biquad 滤波、sample-and-hold、重采样 FIFO、FIFO 满/空策略：没有。mixer 是两张整数 LUT 相加再限幅。
- 左右分路（triangle→左、noise→右之类）：没有，`sample_left == sample_right`。
- WM8978、I2S、音频 FIFO、时钟分频、8/16 位格式转换：没有。输出只是 `sample_left/right` 两个寄存器。
- 视频帧边界与音频采样边界的关系：没有。采样只由 `ce_sample` 决定。
- Triangle 的 `period > 1` 门控（Obara `get_sample()` 有）、Noise “period index 0 且 LFSR bit0=1 额外静音”这类边角规则：没有。
- 寄存器和 `ce` 在同一个 `clk` 沿上的精细竞争（真实硬件的写入 glitch、读取时机）：v1 合同是寄存器访问优先，`$4017` 写整帧重置优先于 frame sequencer 步进，`$4015` 读清优先于同沿的 IRQ 置位。
