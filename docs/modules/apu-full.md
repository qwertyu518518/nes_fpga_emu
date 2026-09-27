# APU 完整实现：软件模拟器模型与硬件 RTL 的对应关系

本文是 `rtl/nes_core/apu/` 的教学文档。目标不是复述寄存器表（`docs/nes-study/07-apu.md` 已经做过），而是回答一个具体问题：

> 一个用 C 写的软件模拟器（channel struct + frame scheduler + host sampling）和一个用 Verilog 写的硬件实现（timer + LFSR + DMA FSM）之间，究竟是**同一套行为的两种写法**，还是在解决**两个不同的问题**？

结论先行：**同一套行为**。软件模拟器和硬件 APU 都在回答“第 N 个 CPU 周期上，五个通道各自的输出是多少”。差别不在语义，而在**谁来提供时间基准、谁来提供数据、谁承担了本该由模拟电路承担的近似**。软件模拟器把三件本该由硬件完成的事揽了下来：

1. **采样率转换**（CPU cycle rate → 44.1/48 kHz），
2. **混音的模拟精度**（浮点公式 + biquad 滤波器），
3. **总线仲裁**（DMC 抢占 CPU 变成一次“调度 + 回调”）。

RTL 必须把 1 交给下游音频引擎、把 3 交给总线仲裁层，只保留 2 的整数化形式。除此之外，两边的结构是可以逐字段对上的。本文按这个思路组织：先讲软件模型的三根时间轴，再讲硬件的四个状态机，然后给逐字段对照表，最后列出**故意不一致**的地方并说明原因。

参考实现：

```text
.slim/clonedeps/repos/ObaraEmmanuel__NES/src/apu.h     结构体定义（本文主要对照对象）
.slim/clonedeps/repos/ObaraEmmanuel__NES/src/apu.c     时序、寄存器、混音、采样
.slim/clonedeps/repos/caseif__cNES/src/system.c        OAM DMA 状态机放在总线层
.slim/clonedeps/repos/caseif__cNES/src/ppu.c           PPU 暴露 ppu_push_dma_byte()
```

`[真值]` 标记的内容以 NESdev APU 为准；`[源码观察]` 标记的内容只是这两个仓库的写法，不是规格。

---

## 1. 软件模型的三根时间轴

`Obara` 的 `execute_apu()` 每个 CPU 周期调用一次，函数体里同时推进三件互不相干的事：

```c
void execute_apu(APU* apu) {
    ... frame sequencer（按 apu->cycles 计数）...
    if (apu->cycles & 1) {                 // 轴 B：通道 timer
        clock_divider(&apu->pulse1.t);
        clock_divider(&apu->pulse2.t);
        if (clock_divider(&apu->noise.timer)) { ... LFSR shift ... }
    }
    clock_dmc(apu);                          // 轴 C：DMC 状态机 + DMA 调度
    clock_triangle(&apu->triangle);          // 轴 B（全速率）
    update_length_counter(...);              // 轴 A：frame 事件落地
    sample(apu);                             // 轴 D：host 采样
    apu->cycles++;
}
```

四个轴：

| 轴 | 谁提供 | 软件里的形态 | 硬件里的形态 |
| --- | --- | --- | --- |
| **A. frame sequencer** | APU 内部 | 一张 `uint32_t sequence[6]` 表 + 一张 `uint8_t directive[6]` 位掩码表 | 自由运行计数器 + 组合译码出的 `quarter` / `half` / `irq_set` 三个 action bit |
| **B. 通道 timer / LFSR** | APU 内部 | 通用 `Divider` 结构体 | 每个通道自己的下计数器 + 重装寄存器（+ pulse 的 4 位预分频） |
| **C. DMC 取数** | **CPU 总线** | `dma_scheduled` 标志 + `schedule_dma()` + `dmc_complete()` 回调 | 4 根信号的电平/脉冲握手，由总线侧实现停机与授权 |
| **D. host 采样** | **宿主音频设备** | `Sampler` 分频器 + 两个 biquad + SDL 队列 | `ce_sample` 采样沿 + 外部 WM8978/I2S/FIFO |

轴 C 和轴 D 是**软件模拟器替硬件做的决定**，轴 A 和轴 B 是真正的 APU 电路。搞清这个划分，就不会把“C 代码里的采样循环”误当成 APU 的一部分。

### 1.1 轴 A：frame scheduler 是“表驱动”的，RTL 是“译码驱动”的

软件版把时序写成数据：

```c
static uint32_t NTSC_frame_sequence[2][6] = {
    {7457, 14913, 22371, 29828, 29829, 29830},  // Mode 0
    {7457, 14913, 22371, 29829, 37281, 37282}   // Mode 1
};
static uint8_t frame_sequence_directives[2][6] = {
    { FRAME_QUARTER,
      FRAME_QUARTER|FRAME_HALF,
      FRAME_QUARTER,
      FRAME_IRQ,
      FRAME_QUARTER|FRAME_HALF|FRAME_IRQ,
      FRAME_IRQ_INHIBIT },
    { ... }
};
```

每帧的逻辑是：`sequencer` 加一，`sequencer == sequence[step]` 时按 `directive[step]` 执行动作，`step` 加一。这样写的好处是加 PAL 制式只要换一张表（`PAL_frame_sequence`）。

RTL 版不能真的用 ROM/常量数组当表（EP4CE10 上是分布式 ROM，Verilog-2001 里也不能 `initial` 初始化），所以变成：

```verilog
always @* begin
    frame_quarter = 1'b0;
    frame_half    = 1'b0;
    frame_irq_set = 1'b0;
    if (frame_count == FC_QUARTER_1) begin
        frame_quarter = 1'b1;
    end else if (frame_count == FC_QUARTER_2) begin
        frame_quarter = 1'b1;
        frame_half    = 1'b1;
    end else if (frame_count == FC_QUARTER_3) begin
        frame_quarter = 1'b1;
    end else if (frame_count == FC_STEP_4) begin
        if (!frame_mode5) begin
            frame_quarter = 1'b1;
            frame_half    = 1'b1;
            frame_irq_set = 1'b1;
        end
    end else if (frame_count == FC_STEP_5) begin
        if (frame_mode5) begin
            frame_quarter = 1'b1;
            frame_half    = 1'b1;
        end
    end
end
```

这就是同一张表的**组合译码版**：比较目标从“表项”变成了“常量”。软件版每帧跑 6 次循环、查 2 张表；RTL 版每个 `ce` 跑一次 5 路比较。前者适合加制式，后者适合综合。

两种写法都必须保住的不变量有三个，缺一个声音就会错：

1. **quarter 和 half 是两个独立 action**，不是“每帧一次”。把 4-step 压成一次更新，length 和 envelope 的时序都会偏。
2. **事件沿和归零沿分开**。4-step 的第 4 个事件在第 29829 个 CPU cycle 结算，计数器停在 29829 一个周期，第 29830 个周期才回 0。所以 IRQ 周期是 29830 而不是 29829。软件版用 `sequence[4] = 29828` 后面再补一个 `29829/0` 的方式表达同一件事（见 `apu.c` 表里的注释 `29830/0`），RTL 版用 `FC_STEP_4` + `FC_END_4` 两个常量表达。
3. **5-step 永远不置 frame IRQ**。

### 1.2 轴 B：`Divider` 抽象 vs 专用硬件

软件版用一个通用结构体覆盖所有定时需求：

```c
typedef struct { long long period, counter; uint32_t step, limit, from; uint8_t loop; } Divider;
static uint8_t clock_divider(Divider *d) {
    if (d->counter) { d->counter--; return 0; }        // 倒计数
    d->counter = d->period;                            // 重装
    d->step++;
    if (d->limit && d->step > d->limit) d->step = d->from;   // 环形步进
    return 1;                                          // 本周期"到点"
}
```

`clock_divider_inverse()` 是它的“反向”版本，用于 envelope（`step` 递减，到 0 回绕）。`step/limit/from/loop` 四个字段把“环形序列发生器”抽象了出来。

RTL 里没有这个抽象，因为**四个通道的定时语义互不相同**，`Divider` 的 `period` 字段其实掩盖了四套不同的换算规则。逐条对照：

| 通道 | `[真值]` 硬件行为 | 换算 | RTL 实现 | 软件的 `Divider` 写法 |
| --- | --- | --- | --- | --- |
| Pulse 1/2 | 4 位预分频器 + 11 位计数器 | 一次 step = `16 × (period+1)` CPU cycle | `timer_prescale[3:0]` 走满 16 → `timer_cnt <= period`，`period==0` 时 step+1 | `period = 寄存器值`，靠把 timer 放在 `cycles & 1`（半速）里凑；等价于 `2×(period+1)`，**不等于**硬件的 `16×(period+1)`，`[源码观察]` Obara 这里靠常数缩放而非预分频 |
| Triangle | 无预分频，11 位计数器直接是周期 | 一次 step = `period` CPU cycle | `timer_cnt <= (period==0) ? 0 : period-1` | `clock_triangle()`，`period` 直接用；`step` 只在 `l.counter && linear_counter` 时前进 |
| Noise | 无预分频，周期来自 16 项表 | 一次 shift = `table[index]` CPU cycle | `timer_reload = table[index] - 1`（`dbg_noise_period` 显示表值本身） | `noise_period_lookup_NTSC[index]` 直接当 `period` |
| DMC | 无预分频，周期来自 16 项 rate 表 | 一次输出 bit = `rate_table[index]` CPU cycle | `rate_reload = rate_table[index] - 1` | `dmc.rate = dmc_rate_index_NTSC[i] - 1` |

**这张表是全文最重要的一张。** 它的含义是：从软件 `Divider` 迁移到 RTL 时，`Divider` 的 `period` 字段**不能照抄**。Pulse 的 `period` 是 `(真值周期/16) - 1`，Triangle 的 `period` 是 `真值周期`，Noise/DMC 的 `period` 是 `真值周期 - 1`。照抄 `Divider` 会得到四种不同的错误，其中 Pulse 差 8 倍、Triangle 差 1 个周期。

`Divider` 的 `step/limit/from/loop` 在 RTL 里则分裂成两种东西：

- **环形序列**（duty 8 步、triangle 32 步）变成一个窄计数器加一张小表。Triangle 的 32 步表甚至不需要存储，因为 `15,14,...,0,0,...,15` 关于中点对称：

  ```verilog
  function [3:0] tri_sequence;
      input [4:0] step;
      begin
          case (step[4])
              1'b0: tri_sequence = 4'd15 - {1'b0, step[3:0]};
              default: tri_sequence = {1'b0, step[3:0]};
          endcase
      end
  endfunction
  ```

  `step[4]` 选半周，`step[3:0]` 是半周内的位置，序列就退化成一次减法。软件版必须老老实实写 32 项数组（`tri_sequence[32]`）。

- **包络**（`clock_divider_inverse`）变成“重装值 + 递减到 0 再重装”的下降沿计数器。

### 1.3 轴 C：软件版把 DMA 变成“调度 + 回调”

硬件的 DMC 取样是一次**总线事务**：APU 拉一个请求，CPU 让出总线，内存返回一个字节。软件里没有总线，只能用调用栈模拟：

```c
// apu.c: clock_dmc()
if (dmc->bits_remaining == 0) {
    if (dmc->bytes_remaining > 0) dmc->dma_scheduled = 1;   // “我想取一个字节”
    ...
}
if (dmc->dma_scheduled && dmc->ready) {
    schedule_dma(&apu->emulator->cpu, DMA_DMC, dmc->current_addr, &dmc->sample, 1, 0);
    dmc->dma_scheduled = 0;
}

// cpu6502.c: DMA_READ 分支
case DMA_READ: ... dmc_complete(&emu->apu); break;

// apu.c: dmc_complete()
dmc->empty = 0;
if (dmc->current_addr == 0xffff) dmc->current_addr = 0x8000; else dmc->current_addr++;
if (dmc->bytes_remaining == 1) { if (loop) {...} else { irq; enabled = 0; } }
else if (dmc->bytes_remaining) dmc->bytes_remaining--;
```

`dma_scheduled` + `schedule_dma()` + `dmc_complete()` 这三个东西，在 RTL 里变成**一个跨模块握手**，因为数据必须真的从别的模块搬过来：

```verilog
assign dmc_bus_req = state;                 // APU：我需要一个字节（电平，直到被授权）
assign dmc_addr    = current_addr;          // APU：从这个地址取
// 总线侧：见下
// APU: if (state && dmc_ack) begin sample_buf <= dmc_rdata; ... end
```

两个容易被忽略的差别：

1. **软件版的 `dmc_complete()` 是同步的**——`schedule_dma()` 立刻把字节填进 `dmc->sample`，下一行代码就能看到新数据。RTL 的 `dmc_ack` 可能隔若干个 `clk` 才回来，甚至可能被总线侧拒绝。所以 APU 的取数分支**不能受 `ce` 门控**：如果 `ce` 跟着 CPU 一起被停住，就会出现“APU 请求 → CPU 让出总线 → 等 `ce` 才能收数据 → `ce` 不来”的死锁。
2. **软件版的 `ready` 是一个软件发明的状态**（`toggle_delay = 2 + (cycles & 1)`，用来模拟 DMC 抢占后 APU 暂停几拍）。硬件里这个概念对应 `/RDY` 线和真实的 stall 周期。本仓库把它压缩成“`dmc_bus_req && !dmc_ack` 期间 CPU 停住”，不规定停几拍——总线侧停多久，`rate_cnt` 就多等多久，行为自洽。

### 1.4 轴 D：host sampling 完全不属于 APU

软件版每个 CPU cycle 都算一次混音值，然后用一个带抖动的分频器抽到宿主采样率：

```c
void sample(APU* apu) {
    float sample = biquad(get_sample(apu), &apu->aa_filter);   // 每个 CPU cycle 一次
    apu->buff[sampler->index++] = 32000 * biquad(sample, &apu->filter) * apu->volume;
    // counter >= period 时才落一个样本；period 在 max_period / min_period 之间抖动
}
```

这里有**两个** biquad（一个 20 kHz 低通做抗混叠，一个高通去 DC），加一个 `float` 音量乘法。`[真值]` 真实 NES 并没有这一级滤波，它只是 DAC 之后的一点点模拟低通。

RTL 版把这一整层砍掉，只留一个采样沿：

```verilog
if (ce && ce_sample) begin
    sample_valid <= 1'b1;
    sample_left  <= mixed_sample;
    sample_right <= mixed_sample;
end
```

这是**正确**的简化，不是偷懒：`ce_sample` 的频率由系统层决定（本板是 I2S 串行输出需要的节拍），采样点相对于 CPU 周期的相位也是系统层的责任。APU 只承诺“在这个沿上，我给出一个组合稳定、无毛刺的 16 位幅度”。

对应的责任划分：

```text
APU（rtl/nes_core/apu）        →  五通道求值、非线性混音（整数 LUT）、采样寄存器
系统 / 音频引擎（未实现）      →  采样率转换、DC 偏置、高通/低通、重采样 FIFO、FIFO 满/空策略
WM8978（未实现）               →  I2S 串行化、8/16 位格式、音量
```

`sample_left` 是**无符号**幅度。软件版之所以能直接输出，是因为它最后乘了 `32000 * volume` 并交给 SDL 去当有符号样本；RTL 版不做符号化，外部音频链需要自己做偏置。

---

## 2. 逐字段对照：软件 struct ↔ RTL 信号

### 2.1 公共部件

| 软件字段 | RTL 信号 | 差别 |
| --- | --- | --- |
| `LengthCounter { counter, halt, new_halt, new_counter }` | `length_cnt` / `halt`（pulse 用 `halt`，triangle 用 `control`，noise 用 `halt`） / `len_pending` + `len_pending_valid` | 软件把“待装载值”放在 `new_counter`，靠 `update_length_counter()` 在每周期末尾搬进 `counter`；RTL 用 `len_pending_valid` 标志，**在下一个 `ce` 沿**装载。语义相同：写入 length 寄存器的那个沿不立刻改 `counter` |
| `length_counter_lookup[32]` | `nes_apu_length_lut.v` 的组合函数 | 软件是数组，RTL 提取成一个独立的小模块，四个通道共用一份，避免复制 4 遍 |
| `Divider`（envelope） | `env_div` + `env_decay` + `env_restart` + `env_period` | 软件的 `clock_divider_inverse` 隐含方向；RTL 显式分开“重装值”和“当前值”，因为 `$4000` 写要能在下一个 quarter 沿生效 |
| `APU.frame_interrupt` / `APU.IRQ_inhibit` | `frame_irq_flag` / `frame_inhibit` | 一致 |
| `APU.status`（8 位） | 组合读出的 `$4015` | 软件是一个字段；RTL 每次访问重新组合，因为 status 位是“比较结果”而不是“存储值” |
| `APU.frame_interrupt` + `apu->dmc.interrupt` → CPU | `frame_irq_flag \| dmc_irq_flag` → `irq` | 软件经 `interrupt()` / `interrupt_clear()` 走 CPU 的中断状态机；RTL 只输出一个电平 OR。屏蔽/filter/上升沿检测属于 CPU 侧 |

### 2.2 Pulse

| 软件 | RTL | 差别 |
| --- | --- | --- |
| `Pulse.t`（`Divider`） | `timer_cnt` + `timer_prescale[3:0]` + `period` | 见 §1.2，硬件有真的 4 位预分频器 |
| `Pulse.t.step`（0..7） | `duty_step[2:0]` | 一致；写 `$4003/$4007` 把它清 0 |
| `duty[4][8]` | `duty_bit()` 的 4 分支 | 8 项表退化成 4 个比较 |
| `Pulse.sweep`（`Divider`）+ `shift/neg/enable_sweep/sweep_reload` | `sweep_div` + `sweep_div_reload` + `sweep_shift` + `sweep_neg` + `sweep_reload` | 一致。`sweep_div_reload = $4001[6:4] + 1`，所以 sweep period 0 表示每 2 个 half frame 改一次 |
| `Pulse.id` + `update_target_period()` | `ONE_COMP` 参数 | 软件用运行时 `id` 分支；RTL 用参数在 elaboration 时定死，Pulse 1 减 1、Pulse 2 不减 |
| `Pulse.mute` | `mute` | 一致：`period < 8 \|\| target > 0x7FF`。注意软件版**不看 `enable_sweep`** 就 mute，本实现跟随 |
| `Pulse.envelope.period/step/loop` | `const_volume` / `volume` / `env_decay` / `env_period` / `halt` | 一致 |

### 2.3 Triangle

| 软件 | RTL | 差别 |
| --- | --- | --- |
| `Triangle.sequencer`（`Divider`，`limit=31`） | `period` + `timer_cnt` + `seq_step[4:0]` | 环形 `limit` 变成 5 位计数器自然回绕 |
| `tri_sequence[32]` | `tri_sequence()` 函数 | 对称性让它退化成减法 |
| `Triangle.linear_reload` / `linear_counter` / `linear_reload_flag` | `linear_reload` / `linear_cnt` / `linear_reload_flag` | 一致，包括“先 reload 再看 flag 是否保留”的顺序 |
| `Triangle.l.new_halt`（复用 `$4008[7]`） | `control` | 一致：`$4008[7]` 同时是 control 和 length halt |
| `set_tri_length()` 同时服务 `$400A` 和 `$400B` | `$400A` 只置 reload flag，`$400B` 才装 length | **故意不一致**，见 §4.1 |
| `get_sample()` 的 `triangle.sequencer.period > 1` 门控 | 无 | **故意省略**，见 §4.2 |

### 2.4 Noise

| 软件 | RTL | 差别 |
| --- | --- | --- |
| `Noise.shift`（`uint16_t`，只用低 15 位） | `lfsr[14:0]` | 软件用 16 位容器浪费 1 位；RLT 用精确 15 位 |
| `(shift & 1) ^ ((mode ? BIT_6 : BIT_1) & shift)` | `lfsr[0] ^ lfsr[mode ? 6 : 1]` | 一致 |
| `noise->shift >>= 1; shift \|= feedback << 14` | `lfsr <= {lfsr_feedback, lfsr[14:1]}` | 一致 |
| `noise_period_lookup_NTSC[16]`（`uint16_t`） | `noise_period_ntsc[4:0]`（12 位，最大 4068） | 软件的 16 位类型放得下但没必要 |
| `Noise.mode`（`$400E[7]`） | `mode` | 一致，**只影响抽头** |
| `Noise.envelope`（`Divider`） | `env_decay/env_div/env_period/env_restart/const_volume/volume` | 同 pulse |
| `get_sample()` 的 `!(noise->shift & BIT_0)` | `!lfsr[0]` | 一致 |
| `init_noise()` 的 `shift = 1` | `lfsr <= 15'd1`（复位值） | 一致 |
| 无 mute 字段 | `mute = (period == 0)` | RTL 加了一条“period 为 0 就静音”的显式门控，见 §4.3 |

### 2.5 DMC

| 软件 | RTL | 差别 |
| --- | --- | --- |
| `DMC.rate_index`（倒计数） | `rate_cnt` | 一致；软件初值 0，RTL 也从 0 开始 |
| `DMC.rate` | `rate_reload` | 软件存 `表值-1`，RLT 也存 `表值-1` |
| `DMC.bits` / `bits_remaining` | `bits` / `bits_remaining[3:0]` | 一致 |
| `DMC.sample` / `DMC.empty` | `sample_buf` / `buf_empty` | 一致 |
| `DMC.silence` | `silence` | 一致 |
| `DMC.counter`（输出，7 位） | `output_level` | 一致，含 `>127` / `<1` 的钳位 |
| `DMC.bits_remaining` 内部 0→8 的重装 | `bits_remaining <= 4'd8` | 一致 |
| `DMC.bytes_remaining` / `current_addr` / `sample_addr` / `sample_length` | 同名字段 | 一致，含 `$FFFF → $8000` 回绕 |
| `DMC.IRQ_enable` / `loop` / `interrupt` | `irq_enable` / `loop` / `irq_flag` | 一致；`$4010[7]=0` 和 `$4015` 访问都清 `irq_flag` |
| `DMC.enabled` | `active` | 一致（自然结束清 0，必须重开） |
| `DMC.dma_scheduled` + `schedule_dma()` + `dmc_complete()` + `DMC.ready` + `toggle_delay` | `state` + `dmc_bus_req/dmc_addr/dmc_ack/dmc_rdata` | **最大的结构差异**，见 §1.3 和 §3 |
| `DMC.counter` 无条件参与混音 | `output_level` 无条件参与 | 一致 |
| 自然结束时 `bytes_remaining` 留 1，靠 `abort` 再清 0 | 直接清 0，用 `bytes_next` 避免多取一个字节 | 简化，行为等价，见 §4.4 |

---

## 3. DMC 的 DMA FSM：软件“函数调用” vs 硬件“跨模块握手”

这是唯一一个软件和硬件**结构上**不同的地方，所以单开一节。

### 3.1 硬件侧真正发生的事

```text
APU 内部                                     CPU 总线 / 内存
--------                                     -------------
输出移位寄存器空了
  ↓ 需要一个字节
dmc_bus_req = 1  ────────────────────────→   停住 CPU（不推进 ce_cpu）
dmc_addr    = current_addr  ─────────────→   （准备读这个地址）
                                             若干 clk 后：
                                             dmc_ack   = 1
                                             dmc_rdata = mem[dmc_addr]
  ← ───────────────────────────────────────
锁存 sample_buf，buf_empty = 0
推进 current_addr / bytes_remaining
输出单元继续消耗 sample_buf
```

关键性质：

- `dmc_bus_req` 是**电平**。它必须保持到被授权，否则总线侧可能永远等不到一个干净的窗口。
- 授权**不需要 `ce`**。这是死锁的唯一解药：`ce` 是 CPU cycle enable，CPU 被停住时 `ce` 也停，所以取数必须挂在 `clk` 上。
- 同一时刻**只允许一个请求在飞**。`slot_free = !state || dmc_ack` 保证不会重复发起。
- 缓冲区在字节被装进移位寄存器的那一刻就空了，于是**同一拍**发出下一个请求。8 bit × 最长 428 cycle = 3424 cycle 的播放窗口远大于一次取样延迟，所以正常情况下取数总是提前完成。

### 3.2 与软件版的逐句对应

| 软件 | 硬件 | 说明 |
| --- | --- | --- |
| `if (dmc->bits_remaining == 0) dmc->dma_scheduled = 1;` | `if ((bytes_next != 0) && slot_free) state <= 1'b1;` | 触发点相同：移位寄存器空的那一拍 |
| `if (dmc->dma_scheduled && dmc->ready) schedule_dma(...)` | 总线侧看到 `dmc_bus_req` 后停机 | 软件的 `ready` 检查在 APU 内，硬件的授权在总线内 |
| `schedule_dma(DMA_DMC, addr, &dmc->sample, 1, 0)` | `dmc_rdata` 在 `dmc_ack` 那一拍有效 | 数据搬运 |
| `dmc_complete()` | `if (state && dmc_ack)` 分支 | 收尾：地址推进、`bytes_remaining` 递减、loop 回卷 |
| `if (!dmc->ready) { cpu.dmc.abort = 1; bytes_remaining = 0; }` | 写 `$4015[4]=0` 时 `state <= 0; bytes_remaining <= 0` | 中止未完成的请求 |
| `if (apu->dmc.enabled && dmc->bytes_remaining == 0) { restart; }` | `status_wr[4] && bytes_remaining == 0` 分支 | 重开 |

### 3.3 同一 tick 内的优先级

一个 `clk` 上可能同时发生：字节送达、`$4010` 写、`$4015` 写、rate tick。RTL 用单个 always 块里的**书写顺序**当优先级：

```text
byte_in（总线送达）
  <  $4010-$4013 寄存器写
  <  $4015 写（enable / 重开 / 中止）
  <  status_clear（$4015 读或写 → 清 DMC IRQ）
  <  ce-gated rate tick（含自然结束时置 IRQ）
```

也就是**通道 tick 的优先级最高**。所以“样本结束的那一拍同时读了 `$4015`”这种极端情况下 IRQ 会留下来。这是有意的选择：`$4015` 读的语义是“报告当前状态”，如果同一拍刚好产生新 IRQ，报告完就把它清掉会丢事件。软件版没有这个问题，因为 `read_apu_status()` 是纯读函数，置位发生在别的时刻。

---

## 4. 故意不一致的地方，以及原因

软件实现是观察材料，不是规格。下面每一条都是本仓库**明确选择不跟随**的地方。

### 4.1 `$400A` 不装 triangle length

`[源码观察]` Obara 的 `set_tri_length()` 同时挂在 `$400A` 和 `$400B` 上（两个地址共用 period 高 3 位），所以写 `$400A = 0x07` 也会把 length index 0 装进去。`[真值]` NESdev 只把 “length counter” 归给 `$400B`，对 `$400A` 只说 “also sets the linear counter reload flag”。

本实现按 NESdev：`$400A` 只写 `period[10:8]` 和 reload flag。这条差异是可观测的——游戏如果写 `$400A` 顺便改了 length，行为会不同。

### 4.2 Triangle 不做 `period > 1` 的静音门控

`[源码观察]` `get_sample()` 里有 `triangle.sequencer.period > 1`。这是软件端为了让“超声频”听起来像静音而加的近似。`[真值]` 硬件里 period 很小时输出的是一个超声频三角波，不是 0。

本实现不加。副作用是：软件模拟器听不到的超声成分，RTL 会算进混音。整数量级下 `tri_sequence[step] * 3` 的贡献依然进 LUT，不会溢出。

### 4.3 Noise 的 `mute` 是显式的

软件版没有 mute 概念，靠 `lfsr[0]` 自然产生静音。本实现加了一条 `mute = (period == 0)`（复位后没写过 `$400E` 的情况），把“周期为 0 → 移位寄存器每个 `ce` 都跳一次”的极端情况显式静音。这不是 NESdev 规则，是为了让 `dbg_noise_mute` 有可断言的语义；NESdev 提到的“period index 0 且 `lfsr[0]=1` 时额外静音”那类边角规则没有实现。

### 4.4 DMC 自然结束时的 `bytes_remaining`

`[源码观察]` Obara 在最后一个字节取完时把 `bytes_remaining` 留成 1，靠后续的 `abort` 再清 0，这样“还能发起一次注定被中止的 DMA”，用来模拟真实硬件的一个边角行为。

本实现直接清 0。代价是需要小心同一拍上的“取数完成”和“样本结束”判定：RTL 里同一拍看到的是**旧**的 `bytes_remaining`，所以判定必须用推算出来的 `bytes_next`：

```verilog
assign bytes_next = !byte_in ? bytes_remaining
                  : (bytes_remaining == 12'd1) ? (loop ? sample_length : 12'd0)
                  : (bytes_remaining == 12'd0) ? 12'd0
                  : (bytes_remaining - 12'd1);
```

没有这一行，单字节样本会多取一个字节，第 9 个 bit tick 才会发现样本已结束。`tb_nes_apu2a03.v` 的 `DMC delta modulation, output unit refill and end-of-sample IRQ PASS` 那一组就是钉住这个行为的：8 个 delta bit 之后的那一拍就必须置 IRQ，不允许再多播一轮。

### 4.5 微周期级别的副作用全部不实现

`[源码观察]` Obara 用 `reset_sequencer_delay = 3 + (cycles & 1)`、`irq_clear_delay = 1 + (cycles & 1)`、`dmc.toggle_delay` 把“写在 PUT 周期还是 GET 周期”这种相位抖动都模拟了。

`[真值]` 这些确实是真实硬件的行为。**本仓库不实现**，因为：寄存器接口是 `reg_cs/reg_we/reg_addr/reg_din` 同步总线，没有 PUT/GET 之分，也没有“第几个 CPU 周期”这种信息可用。要实现得先把 CPU 的读写周期相位暴露到 APU 接口上，属于另一个任务。

同理，frame IRQ flag 更精细的置位点（NESdev 说 flag 在第 29828 个 cycle 就已置位，且 `$4015` 在 29829 读回 0 也会抑制本帧 IRQ）也没有实现——v1 保持 v0 的“第 29829 个 `ce` 置位、任何读都清标志”。

### 4.6 混音从 `float` 降到整数 LUT

| 软件 | RTL |
| --- | --- |
| `pulse_LUT[i] = 95.52f / (8128.0f/i + 100.0f)` | `pulse_mix_lut[N] = round(95.88 × 32767 × N / (8128 + 100N))` |
| `tnd_LUT[i] = 163.67f / (24329.0f/i + 100.0f)` | `tnd_mix_lut[M] = round(163.67 × 32767 × M / (24329 + 100M))` |
| `amp = pulse_LUT[p] + tnd_LUT[t]; return amp > 1 ? 1 : amp;` | `mixed = min(pulse_lut + tnd_lut, 32767)` |
| `32000 * biquad(sample, filter) * volume` | 只有 `sample_left/right` 两个寄存器 |

两点差异要讲清楚：

1. **系数不同**：软件版 pulse 用 95.52（一个常见的经验值），NESdev 的公式是 95.88。本实现取 NESdev 的 95.88。TB 里的 `ref_pulse_lut()` 用的也是 95.88，所以 TB 是对着公式验的，不是对着软件版验的。
2. **饱和点不同**：`lut(30) + lut(202) = 8470 + 24328 = 32798`，超过 32767。软件版先归一化到 `[0,1]` 再 `>1 ? 1`；RTL 版在 16 位域上比较，所以要显式限幅。`dbg_mix_sum` 故意暴露 17 位未限幅和，就是为了让这条限幅分支可观测、可断言。

没有 DC 偏置、没有高通/低通、没有 biquad、没有 `real`/`float`、没有除法器。这些全部属于 §1.4 的轴 D。

---

## 5. 给 RTL 作者的检查清单

从软件模拟器搬到 RTL 时，按这个顺序过一遍：

1. **先画时间轴。** 软件里一个函数干几件事，RTL 里就要拆成几个独立的状态机。本仓库：`nes_apu2a03.v`（寄存器 + frame sequencer + IRQ 汇总 + 混音 + 采样）、`nes_apu_pulse.v` / `nes_apu_triangle.v` / `nes_apu_noise.v` / `nes_apu_dmc.v`（通道）、`nes_apu_length_lut.v`（共享查表）。
2. **逐字段抄 `Divider` 的换算。** 特别确认预分频器和 `period+1` 还是 `period`，见 §1.2 的表。这是移植中最容易静默出错的一项。
3. **区分“环形序列发生器”和“倒计时器”。** 前者用窄计数器 + 小表（Triangle 甚至不用表），后者用“当前值 + 重装值”两个寄存器。不要试图用同一个通用模块覆盖。
4. **把“待装载值”建模成显式的 pending 标志**，不要像软件那样用 `new_counter != 0` 当隐式标志——`length_table(0) = 10` 是合法值，0 不能当地图。
5. **凡是需要外部数据的通道，一定要画成握手而不是函数调用。** DMC 是唯一的例子，但同样的原则适用于将来任何要跨模块取数的通道：请求是电平、授权不依赖 `ce`、同一时刻只允许一个请求在飞。
6. **明确写出“同一拍内谁赢”。** 本仓库用单个 always 块的书写顺序，见 §3.3。
7. **把不该属于 APU 的东西列出来。** 采样率转换、滤波、FIFO、总线仲裁、OAM DMA、IRQ 屏蔽——它们在软件模拟器里都长在 `apu.c` 里，在 RTL 里必须搬到别的模块。搬到哪儿、写不写，属于架构决策，但“不写”必须写在文档里。
8. **用可计算的参考公式验 LUT，不要用另一份 LUT 验 LUT。** `tb_nes_apu2a03.v` 的 `ref_pulse_lut()` / `ref_tnd_lut()` 用 64 位整数直接算 `round(a × 32767 × N / (b + 100N))`，然后和 RTL 的 `case` 表逐项比。本次运行一共验了 35538 个工作点，其中 `$4011` 的 0..127 是穷举的。

---

## 6. 本仓库的实现清单

| 文件 | Verilog | 内容 |
| --- | --- | --- |
| `rtl/nes_core/apu/nes_apu_length_lut.v` | 2001 | 32 项 length 查表，纯组合，四个通道共用 |
| `rtl/nes_core/apu/nes_apu_pulse.v` | 2001 | 16 预分频 + 11 位 timer、8 步 duty、envelope、length、sweep；`ONE_COMP` 参数 |
| `rtl/nes_core/apu/nes_apu_triangle.v` | 2001 | 32 步序列（对称减法实现）、无预分频 timer、7 位线性计数器 + reload flag、length |
| `rtl/nes_core/apu/nes_apu_noise.v` | 2001 | 15 位 LFSR（双抽头）、NTSC 周期表、envelope、length、显式 mute |
| `rtl/nes_core/apu/nes_apu_dmc.v` | 2001 | rate 表、sample buffer + 输出移位寄存器、7 位 delta DAC、loop/IRQ、`dmc_bus_req/dmc_addr/dmc_ack/dmc_rdata` |
| `rtl/nes_core/apu/nes_apu2a03.v` | 2001 | 寄存器译码、`$4015` status + 读副作用、`$4017`、frame sequencer（29830/37282）、IRQ 汇总、31 项 pulse LUT + 203 项 TND LUT、采样寄存器、48 个 debug 输出端口 |

接口合同、寄存器表、复位值、断言覆盖和“明确未实现”清单在 `tb/apu/README.md`，那里是契约的规范位置；本文只解释**为什么**是这样。

验证状态：**只有 Icarus Verilog 纯 RTL 仿真的证据**。`-g2001 -Wall` 单独 elaborate 六个 RTL 文件零 warning，`tb/apu/tb_nes_apu2a03.v` 的 27 个 test task（共 31 条 PASS 行）全部 `$fatal`-clean 通过。**没有** Quartus 综合报告、**没有** ModelSim/Questa 仿真、**没有** EP4CE10 上板证据。
