# 07 APU：五个通道、帧序列器、混音与 DMC 边界

## 1. APU 的观察范围

NES APU 通常由以下部分组成：

```text
Pulse 1 ─┐
Pulse 2 ─┤
Triangle ├── 非线性混音器 ── 高通/低通等输出处理 ── 音频采样
Noise   ─┤
DMC     ─┘

CPU $4000-$4017 ── 寄存器写入/读取
APU frame sequencer ── IRQ 和长度/包络/扫描时钟
DMC sample buffer ── DMC DMA 向 CPU 总线取字节
```

本章的源码观察主要来自：

```text
.slim/clonedeps/repos/ObaraEmmanuel__NES/src/apu.h
.slim/clonedeps/repos/ObaraEmmanuel__NES/src/apu.c
.slim/clonedeps/repos/ObaraEmmanuel__NES/src/cpu6502.h
.slim/clonedeps/repos/ObaraEmmanuel__NES/src/cpu6502.c
```

cNES 的 `system.c` 在 `$4000-$4013`、`$4015` 处明确留有 APU TODO，因此不能从 cNES 得到完整 APU 行为。`[NESdev 真值]` 是寄存器、通道时序、帧序列器、IRQ 和 DMC 总线行为的权威来源；Obara 代码是很好的观察材料，但其中采样滤波、周期计数和近似值需要独立核对。

## 2. APU 寄存器总表

| 地址 | 名称 | 主要字段 |
|---:|---|---|
| `$4000` | Pulse 1 duty/control | duty、length halt、constant volume、volume |
| `$4001` | Pulse 1 sweep | enabled、shift、negate、reload、period |
| `$4002` | Pulse 1 timer low | timer period[7:0] |
| `$4003` | Pulse 1 length/high | length index、timer period[10:8]、length load |
| `$4004-$4007` | Pulse 2 | 同上 |
| `$4008` | Triangle linear/control | control bit、linear reload、halt |
| `$4009` | Triangle timer low | period[7:0] |
| `$400A` | Triangle timer high/length | period[10:8]、length load |
| `$400B` | Triangle length | length index |
| `$400C` | Noise control | mode、halt、constant volume、volume |
| `$400E` | Noise period | period index、mode |
| `$400F` | Noise length | length index |
| `$4010` | DMC control | IRQ enable、loop、rate index |
| `$4011` | DMC output | 7-bit delta level |
| `$4012` | DMC sample address | `$C000 + value×64` |
| `$4013` | DMC sample length | `value×16 + 1` bytes |
| `$4015` | APU status | 各通道 length、frame IRQ、DMC IRQ |
| `$4017` | Frame counter | mode、IRQ inhibit、sequencer reset |

地址写入和读取并不对称。例如 `$4015` 写是通道 enable，读是状态；`$4017` 同时与 frame counter 和控制器 2 读回有关。

## 3. 公共部件：长度计数器、包络和线性计数器

### 3.1 length counter

Pulse 1、Pulse 2、Triangle、Noise 都有长度计数器。写入 length 寄存器时，使用 32 项查表把 5-bit 索引变成实际长度；是否立即装载通常受通道 enable 状态影响。

```text
enable = 0 → 写 length 不一定装载
enable = 1 → 写入待装载值
frame half clock → counter--
halt = 1 时停止递减
counter = 0 → 通道静音
```

`[源码观察]` Obara 的 `set_*_length()` 多数只在 `enabled` 时设置 `new_counter`；`update_length_counter()` 再把待装载值转入当前计数器。`[NESdev 真值]` 写入和 frame clock 的边界时序决定游戏听到的结果，不能只做最终 counter 数值。

### 3.2 envelope

Pulse 和 Noise 的包络由 4-bit volume、period 和 clock 组成：

```text
volume = constant ? constant_volume : envelope_step
```

包络通常每 quarter-frame clock 一次。`[源码观察]` Obara 用 `Divider` 的 `period/counter/step` 表示包络和通道计时器；`clock_divider_inverse()` 在到达周期时递减或回绕。`[RTL 建议]` 把 counter、reload 和 direction 分开，避免一个通用 divider 隐藏 envelope 与 timer 的不同装载规则。

### 3.3 Triangle linear counter

Triangle 还有 7-bit linear counter 和 reload flag：

```text
linear_reload = $4008[6:0]
control bit   = $4008[7]

quarter clock:
  if reload_flag:
      linear_counter = linear_reload
  else if linear_counter:
      linear_counter--
  if control bit == 0:
      reload_flag = 0
```

Triangle 的 timer 即使没有 length counter，也不能在 linear counter 为 0 时正常推进；高频 period 可能进入超声频而听不到，但内部状态仍会变化。

## 4. Pulse 1 和 Pulse 2

### 4.1 通道组成

```text
11-bit timer → duty sequence(8 steps) → volume/envelope
          ↘ sweep → period mute/change
length counter → enable gate
```

### 4.2 duty

四种 duty 波形可用 8 步序列表示：

| duty 值 | 常见高电平比例 | 序列示意 |
|---:|---:|---|
| 0 | 12.5% | `0 1 0 0 0 0 0 0` |
| 1 | 25% | `0 1 1 0 0 0 0 0` |
| 2 | 50% | `0 1 1 1 1 0 0 0` |
| 3 | 25% 反相 | `1 0 0 1 1 1 1 1` |

`[源码观察]` Obara 的 `duty[4][8]` 使用上表一类序列。`[NESdev 真值]` duty 的相位重置、timer reload 和 length load 时机要按通道规则实现；波形表本身正确并不代表时序正确。

### 4.3 timer period

11-bit period 分布为：

```text
$4002/$4006 → period[7:0]
$4003/$4007 → period[10:8]
```

timer 每个 APU 时钟或规定的子周期递减；到零后 step 加一并 reload。频率近似为：

```text
f = apu_clock / (16 × (period + 1))
```

具体输出还受到 sweep mute、length counter 和 enable 的影响。

### 4.4 sweep

Sweep 由 shift、period、negate、enabled 和 reload flag 组成：

```text
target = period
if negate:
    target = period - (period >> shift)
    Pulse 1 还要额外减 1
else:
    target = period + (period >> shift)
```

target 超界或过小时通道静音。Pulse 1 的负 sweep 比 Pulse 2 多一个补偿，这是常见且容易写错的硬件细节。

### 4.5 Pulse 状态表

| 条件 | timer | 输出 |
|---|---|---|
| enable=0 | 依实现可能继续/停止 | 静音 |
| length=0 | 可继续计数 | 静音 |
| sweep mute | 可继续计数 | 静音 |
| period 太低或 target 越界 | 可继续计数 | 静音 |
| 以上均满足 | 随 duty step 变化 | duty × volume |

## 5. Triangle

Triangle 使用 32 步序列：

```text
15 14 13 ... 1 0 0 1 ... 14 15
```

它没有 duty 选择，使用固定序列；音量由 0–15 的序列值提供。Triangle 的线性计数器、length counter 和 11-bit timer 必须同时有效。

### 5.1 Triangle 时序

```text
timer 到期
  ↓
if length_counter != 0 and linear_counter != 0:
    sequence_step = (sequence_step + 1) mod 32
  ↓
输出 triangle_sequence[step]
```

### 5.2 高周期静音的误区

把 period 写得很小并不会自动得到“更强”的声音；它可能变成超声频，游戏听不到但 CPU/NMI 和渲染时序仍可能受影响。某些软件用 triangle 的线性计数器状态做时序，因此不能因为音频输出近似为零就省略 timer。

## 6. Noise

### 6.1 15 位 LFSR

Noise 的核心是一个 15 位线性反馈移位寄存器：

```text
bit 0 → 输出
反馈 = bit0 XOR (mode ? bit6 : bit1)
shift right
feedback 插入 bit14
```

- mode 0：短模式，反馈 bit 1。
- mode 1：长模式，反馈 bit 6。
- 两种模式的输出静音条件、周期表和 LFSR reload 要按 NESdev 规则实现。

### 6.2 周期表

周期索引由 `$400E[3:0]` 选择，NTSC/PAL 的表不同。Obara 在 `apu.c` 中定义 `noise_period_lookup_NTSC` 和 `noise_period_lookup_PAL`，这说明制式不仅影响 PPU，也影响 APU 的周期表。

### 6.3 Noise 输出

```text
if shift_register_bit0 == 0 and length_counter != 0 and enable:
    output = volume
else:
    output = 0
```

Noise 的 envelope 与 Pulse 类似，但周期表和 LFSR 反馈使声音明显不同。

## 7. DMC：采样、delta 调制和 DMA 边界

### 7.1 寄存器编码

```text
sample_address = $C000 + ($4012 × 64)
sample_length  = ($4013 × 16) + 1
rate_index     = $4010[3:0]
loop           = $4010[6]
irq_enable     = $4010[7]
output_level   = $4011[6:0]
```

DMC 读取样本字节后，每次输出一个 bit：

```text
bit = 1 → output += 2，限制在 0..127
bit = 0 → output -= 2，最小为 1
```

一个字节的 8 bit 消耗完后，若 buffer 为空且 bytes remaining 非零，就请求新的 DMA 字节。

### 7.2 DMC 状态表

| 状态 | 条件 | 动作 |
|---|---|---|
| `DISABLED` | `$4015` 未 enable | 不产生正常样本，ready 延迟变化 |
| `EMPTY` | sample buffer 无数据 | 安排 DMC DMA，必要时输出 silence |
| `FILLING` | DMA 正在取字节 | CPU 总线让出；APU 继续计时 |
| `PLAYING` | buffer 有 bit | 按 rate 消耗 bit，更新 level |
| `IRQ` | 最后一个字节完成且 IRQ enable | 置 DMC IRQ |
| `LOOP` | 最后一个字节完成且 loop=1 | 地址和长度回到起点 |

### 7.3 地址回绕

DMC 当前地址到达 `$FFFF` 后回到 `$8000`，不是简单地对整个 64 KiB 做 `(addr+1) % 65536`。样本区理论上在 `$8000-$FFFF` 循环。

### 7.4 DMC DMA 的 CPU 边界

当 DMC 需要一个字节时：

1. APU 置 DMA scheduled。
2. DMC ready 时向 CPU 发出取样请求。
3. CPU 总线执行一次（或规定的若干）DMA 事务。
4. 字节写入 DMC sample buffer。
5. `dmc_complete()` 更新地址、剩余长度和 IRQ 状态。

`[源码观察]` Obara 的 `clock_dmc()` 调用 `schedule_dma(..., DMA_DMC, current_addr, &sample, 1, 0)`；`cpu6502.c` 的 `DMA_READ` 分支把一个字节交给 `dmc_complete()`，没有把它写入 CPU 可见的普通地址。

`[NESdev 真值]` DMC 取样导致的 CPU 延迟、总线地址冲突、ready 变化和中断清除时序是兼容性问题。功能 RTL 可以把 DMC buffer 抽象为数组，但若要运行依赖精确时序的游戏，必须实现总线边界。

### 7.5 DMC IRQ

DMC IRQ 不是“每次取样都触发”。只有满足以下条件才产生：

```text
bytes_remaining 到达结束
loop == 0
IRQ_enable == 1
```

读 `$4015` 会返回 DMC IRQ 状态并清除相应标志；写 `$4015` 可以禁用 DMC 并清除其 IRQ。不同实现对延迟和边沿的表达可能不同。

## 8. Frame sequencer

### 8.1 四步和五步模式

`$4017` bit 7 选择 mode，bit 6 是 IRQ inhibit。

四步模式大致动作：

```text
step 1: quarter
step 2: quarter + half
step 3: quarter
step 4: quarter + half + IRQ
step 5: inhibit/复位相关
```

五步模式：

```text
step 1: quarter
step 2: quarter + half
step 3: quarter
step 4: 无
step 5: quarter + half
```

### 8.2 周期表

| 制式 | 首个 quarter | 第二个 | 第三个 | 第四个 | 第五个 | 4-step 归零/重复周期 | 5-step 归零/重复周期 |
|---|---:|---:|---:|---:|---:|---:|---:|
| NTSC | 7457 | 14913 | 22371 | 29828/29829 | 37281（5-step） | 29830 | 37282 |
| PAL | 8313 | 16627 | 24939 | 33252/33253 | 41565（5-step） | 33254 | 41566 |

这里的数字要区分两种时间：一是 step 动作发生的结算沿，二是序列结束后计数器归零的沿。当前 RTL v0 在 step-4 事件沿（29829）置 frame IRQ，随后保持一个周期，再在第 29830 个 CPU cycle 归零；5-step 的第五个事件在 37281，归零在 37282。NESdev 还描述了更精细的 29828/29829 IRQ flag 与读取窗口，当前 v0 明确不实现。

`[源码观察]` Obara 以 `NTSC_frame_sequence`、`PAL_frame_sequence` 和 `frame_sequence_directives` 表驱动 frame sequencer。`[NESdev 真值]` 真实时序表、写入 `$4017` 的 reset delay 和 IRQ inhibit 需要按 APU 文档核对。

### 8.3 quarter 与 half

| 时钟 | 影响 |
|---|---|
| quarter | envelope、triangle linear counter |
| half | pulse sweep、length counter、triangle length、noise length |
| frame IRQ | frame counter IRQ flag 和 CPU IRQ line |

把 quarter 和 half 合并成一个“每帧更新”会改变声音长度和 IRQ；RTL 中至少需要两个独立 action bit。

## 9. 混音和非线性输出

### 9.1 通道输出域

Pulse 1/2 通常输出 0–15；Triangle、Noise、DMC 也有各自的 0–15/7-bit 近似域。五个通道不是直接线性相加，而是通过 NES 的非线性混音表。

常见 pulse 公式：

```text
pulse_out = 95.52 / (8128 / (pulse1 + pulse2) + 100)
```

常见 TND 公式：

```text
tnd_out = 163.67 / (24329 / (3×triangle + 2×noise + dmc) + 100)
```

`[源码观察]` Obara 在 `get_sample()` 中把 pulse 和 TND 分开，用 `pulse_LUT` 和 `tnd_LUT` 相加，再限制幅度。`[NESdev 真值]` 精确混音还涉及通道输出范围、禁用状态和输出滤波；软件参考实现通常会选择一个可听且可验证的近似。

### 9.2 输出滤波和重采样

桌面模拟器常以 48 kHz 输出，而 APU 内部状态每个 CPU/APU 周期变化。需要：

```text
APU state at cycle N
       ↓
混音
       ↓
低通/高通滤波
       ↓
sample-and-hold 或平均
       ↓
固定采样率 FIFO
```

FPGA 不必复制 SDL 滤波器，但必须定义输出采样点、FIFO 满/空策略和帧边界。不要把视频 frame boundary 当成音频采样边界。

## 10. `$4015` 和 IRQ

### 10.1 status 位

| 位 | 含义 |
|---:|---|
| 0 | Pulse 1 length counter 非零 |
| 1 | Pulse 2 length counter 非零 |
| 2 | Triangle length counter 非零 |
| 3 | Noise length counter 非零 |
| 4 | DMC 正在播放/有剩余样本 |
| 5 | 特殊 open-bus/内部总线行为 |
| 6 | frame IRQ |
| 7 | DMC IRQ |

写 `$4015` 的低 5 位 enable 对应通道，并可能清 DMC IRQ；读 `$4015` 返回状态并清 frame/DMC IRQ 的边沿/标志。

### 10.2 IRQ 汇总

```text
frame IRQ ─┐
DMC IRQ  ──┼── OR ── APU IRQ line ── CPU IRQ input
mapper IRQ ┘
```

APU IRQ 和 mapper IRQ 在 CPU 侧可以 OR 到同一条可屏蔽线，但来源清除方式不同。不要用一个“清全局 IRQ”寄存器代替各来源的清除。

## 11. cNES 与 Obara 的差异

| 主题 | cNES | Obara |
|---|---|---|
| APU MMIO | TODO，读返回 0，写忽略 | 完整寄存器分发 |
| 状态 | 无独立 APU 模块 | `APU` 结构体含五个通道 |
| 采样 | 无 | `Sampler`、Biquad filter、SDL audio |
| CPU/DMC | OAM DMA 有 | OAM/DMC 统一 DMA 状态机 |
| frame IRQ | 无 | `APU_FRAME_IRQ` 注入 CPU interrupt |
| 周期表 | 无 | NTSC/PAL 表和 frame sequence |

`[源码观察]` Obara 的实现覆盖面明显更完整，但 `apu.c` 中 `clock_divider()`、`execute_apu()`、sampler 和滤波的边界仍是 C 模拟器设计，不应逐行当作 APU 电路图。

## 12. 手工实验

### 实验 A：Pulse duty

对 Pulse 1 写固定 period、length 和不同 duty，导出每个 timer step 的 0/1 输出。确认：

- timer 写入是否重置相位；
- `$4003` length load 是否静音/解除静音；
- volume constant 和 envelope 的差异。

### 实验 B：Pulse sweep mute

设置 shift 过大，使 target 超过 0x7FF；确认通道 mute。再写回合法 period，比较 sweep reload 时钟。不要只检查 `target` 算式。

### 实验 C：Triangle linear counter

先禁用 triangle，再写 linear reload；启用后观察 quarter clock。关闭 control bit 后，reload flag 应按规则清除。比较 length counter 为零和 linear counter 为零的差异。

### 实验 D：Noise 短/长模式

同一 LFSR 初值下切换 mode bit，比较反馈 tap 和 audible 输出。记录 period index 在 NTSC/PAL 下的 timer reload。

### 实验 E：DMC 一个字节

构造一个样本字节 `0xB4`，设置非循环、IRQ disabled，运行到 buffer empty。记录：

```text
8 次 bit 输出
output level 0..127
DMA 请求时刻
CPU 被延迟的时刻
地址递增和 bytes_remaining
```

然后打开 loop 和 IRQ enable，分别观察地址回绕和 IRQ 清除。

## 13. 常见误区

- 认为 APU 只在 CPU 写寄存器时运行。
- 把 Pulse 1 和 Pulse 2 的负 sweep 当成完全相同。
- 把 Triangle 的序列当成 8 步而不是 32 步。
- 只实现 Noise 输出，不实现 15 位 LFSR。
- 把 DMC 当成“每个音频采样读一个 ROM byte”，忽略 APU rate 和 CPU DMA 边界。
- DMC 结束永远不复位地址或永远循环；实际由 loop 位决定。
- 用线性相加替代非线性混音，却仍声称与 NES 音频等价。
- 把 frame sequencer 的 IRQ 和 DMC IRQ 混成一个状态。
- 忽略 `$4015` 读副作用和 `$4017` 写 reset delay。
- 直接输出每个 CPU 周期的混音值，却没有固定采样率和 FIFO。

## 14. 后续 RTL 映射

### 14.1 模块划分

```text
nes_apu
├── apu_register_file
├── pulse[0:1]
├── triangle
├── noise
├── dmc_channel
├── frame_sequencer
├── apu_irq_arbiter
├── nonlinear_mixer
├── sample_fifo
└── audio_output
```

### 14.2 通道通用结构

```text
period_register
counter
reload/step
length_counter
envelope_or_linear
enable_gate
output_level
```

Pulse 额外有 duty 和 sweep；Triangle 有 32 步序列；Noise 有 LFSR；DMC 有 sample buffer、bit counter 和 DMA request。

### 14.3 时钟和 ready

APU 可以用 CPU clock enable，也可以用独立的 APU tick。关键是每个事件有固定顺序：

```text
register write
frame sequencer action
channel timer
DMC DMA/IRQ
mix/sample
```

如果使用多个 always block，所有跨模块事件都要定义同一周期内谁先更新；最好用显式 `event_bus` 或统一的 tick FSM。

### 14.4 音频输出层级

建议分两级实现：

1. **功能级**：正确寄存器、通道输出和非线性混音，输出固定采样率。
2. **周期级**：精确 frame sequencer、DMC CPU stall、open bus 和滤波边界。

[10-verification.md](10-verification.md) 会把每个级别对应到可观察断言；不要在没有 trace 的情况下判断“音质差不多”就完成了 APU。
