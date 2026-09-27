# 01 NES 系统总览与计算机体系结构基础

## 1. 先建立一个不混淆的整机模型

NES 不是一个“CPU 直接算像素”的单核芯片。对一个可运行的游戏，至少需要同时考虑 CPU、PPU、APU、工作 RAM、卡带、mapper 和输入设备。下面的图先画出逻辑数据流，再画出时间关系。

```text
                         +----------------------+
                         |      CPU 6502        |
                         | PC A X Y S P/flags  |
                         +----------+-----------+
                                    |
                         16 位地址 / 8 位数据
                                    |
             +----------------------+----------------------+
             |                      |                      |
      +------v------+       +-------v--------+      +------v------+
      | 2 KiB RAM   |       | 地址译码/总线   |      | 卡带 + mapper|
      | $0000-$1FFF | <---> | open bus/DMA    | <---> | PRG/CHR/RAM  |
      +-------------+       +-------+--------+      +------+-------+
                                   |                       |
                         CPU 周期  |                       | PRG/CHR 窗口
                                   v                       v
                         +---------+---------+       +-----+------+
                         |  PPU  2C02      |       | 视频/音频  |
                         | v t x w OAM     |       |            |
                         +-----------------+       +------------+
                                   ^
                                   |
                         APU 2A03 + DMC DMA
```

这里故意没有把每根线都画成 RTL 总线。真实硬件中 CPU、PPU 和 APU 有不同的时钟分频关系，mapper 还可能监视 PPU 地址变化；软件可以用函数调用隐藏这些并行关系，RTL 必须显式决定何时发生。

## 2. 硬件部件和它们的职责

| 部件 | 对软件可见的状态 | 对游戏的功能 | RTL 学习重点 |
|---|---|---|---|
| CPU 6502 | A、X、Y、S、PC、P、总线和中断线 | 读取 PRG、执行指令、读写 RAM 和寄存器 | 取指、寻址、微周期、dummy access、IRQ/NMI/RESET |
| 工作 RAM | 2 KiB，可按硬件规则镜像 | 栈、变量、游戏状态 | 同步 RAM 读延迟、地址镜像、复位值 |
| PPU | `PPUCTRL` 到 `PUDATA`、OAM、palette、nametable、v/t/x/w | 生成 256×240 画面、滚动、精灵、NMI | dot/scanline 状态机、流水线、优先级、奇偶帧 |
| APU | `$4000`–`$4017` 寄存器和 IRQ 状态 | 五个音频通道、混音、DMC 取样 | 帧序列器、计数器、非线性混音、DMA 边界 |
| 卡带 PRG | CPU `$8000`–`$FFFF` 窗口 | 程序和向量 | ROM 接口、bank 选择、镜像、mapper 状态 |
| 卡带 CHR | PPU `$0000`–`$1FFF` 窗口 | tile 图形数据 | ROM/RAM 区分、CHR bank 粒度、A12 监视 |
| Mapper | PRG/CHR bank、mirroring、IRQ 可选 | 扩展容量和游戏特定机制 | 地址译码、寄存器时序、IRQ 边沿 |
| 控制器 | `$4016`/`$4017` 串行读回 | 读取按键 | strobe、移位、open bus 上半位 |
| 视频/音频输出 | PPU 像素、APU 混合采样 | 显示和发声 | frame buffer、DMA、采样抽取、平台适配 |

### 2.1 CPU 不是“函数调用机器”

嵌入式 C 中调用 `mem_read(address)` 可能只执行一条数组访问；6502 硬件却要在下一个时钟边界让地址稳定、驱动 `R/W`、等待 RAM/ROM/总线完成，再把数据交给 CPU。一个 C 模拟器可以在一次高层函数调用中隐藏多个 CPU 周期，因而必须用 trace 或专门的 cycle state 才能研究时序。

### 2.2 PPU 是独立的状态机

PPU 自己按 dot 运行。CPU 写入 `PPUSCROLL` 或 `PPUADDR` 只是改变 PPU 寄存器状态；真正改变 `v` 的时机还取决于写入发生在哪一行、哪个 dot、渲染是否打开。PPU 的图像取数也有自己的地址总线，mapper 可以观察这条地址总线。

### 2.3 APU 既产生声音又请求 CPU

APU 的通道计时器和 frame sequencer 按自己的时基运行。DMC 还会在 CPU 总线上取一个样本字节，取样期间 CPU 不能正常执行自己的指令；因此音频不是“最后调用一次混音函数”那么简单。

## 3. 体系结构基础：冯诺依曼与哈佛式取舍

### 3.1 纯冯诺依曼的直觉

冯诺依曼结构把指令和数据放在同一地址空间，通过同一组地址和数据总线访问。优点是结构简单、地址空间统一；缺点是取指和数据访问会争用同一总线，指令和数据流量不容易独立优化。

### 3.2 哈佛式的直觉

哈佛结构把指令存储和数据存储分开，允许不同总线同时工作。优点是指令读取和数据访问可以并行；缺点是需要额外的地址空间、总线和一致性管理。

### 3.3 NES 的实际取舍

NES 不是“纯哈佛”或“纯冯诺依曼”二选一：

- CPU 侧使用统一的 16 位地址空间，程序、数据、RAM 和 I/O 通过地址译码访问，具有强烈的冯诺依曼特征。
- PPU 有独立的 nametable/OAM/palette 空间和图形取数路径，不能简单视为 CPU RAM 的普通数组。
- CPU 访问 PPU 寄存器与 PPU 内部渲染取数是两个不同方向的访问；二者可能发生总线竞争或时序冲突。
- 6502 的指令和数据都来自同一 CPU 16 位空间，但 DMA 会暂时夺取总线。
- APU 的 DMC 还会从 CPU 空间取样，进一步说明“声音输出”和“CPU 数据通路”并不是隔离的。

### 3.4 `[源码观察]`

cNES 的 `src/system.c` 把 `system_memory_read`、`system_memory_write` 交给 `c6502`，再由 `cart->mapper->ram_read_func` 和 `ram_write_func` 分发；PPU 则通过 `system_vram_read`、`system_vram_write` 走另一组 mapper 回调。这个 C 结构清楚地区分了 CPU 侧和 PPU 侧接口，但它没有真实总线的仲裁电气细节。

Obara 的 `src/mmu.c` 把 RAM、PPU 寄存器、APU 寄存器和 mapper ROM 统一放在 `read_mem`/`write_mem` 中；`src/cpu6502.c` 的 `read` 和 `write` 在一次高层访问内调用 `tick_master_clock`，因此多个内存访问会推进 PPU、APU 和 mapper 时间。

### 3.5 `[NESdev 真值]`

真实硬件要同时满足 CPU 访问语义、PPU 内部渲染时序、DMA 抢占、mapper 监视以及 open bus 行为。仅证明最终 RAM 内容相同，不能证明总线访问次数和时序相同。

### 3.6 `[RTL 建议]`

先建立一个统一的 `nes_cpu_bus` 事务接口，再为 PPU 内部取数和 DMA 仲裁定义明确的 owner/ready 协议。不要一开始把所有读写都接到一个无延迟组合数组；那通常只能做功能近似，不能解释 PPU 时序和 mapper IRQ。

## 4. 时钟、周期和三个时间域

### 4.1 参考时钟关系

| 制式 | 主时钟 | CPU 分频 | PPU 分频 | 近似 CPU 频率 | 近似 PPU 频率 | CPU:PPU |
|---|---:|---:|---:|---:|---:|---:|
| NTSC | 21.477272 MHz | 12 | 4 | 1.789773 MHz | 5.369318 MHz | 1:3 |
| PAL | 26.601712 MHz | 16 | 5 | 1.662607 MHz | 5.320342 MHz | 1:3.2 |
| Dendy | 26.601712 MHz | 15 | 5 | 1.773447 MHz | 5.320342 MHz | 1:3 |

这些数字描述的是常见 NES 主时钟分频方案。PAL 和 Dendy 的 CPU 频率、PPU 帧长以及部分 APU 周期表不同，不能只把帧率从 60 改成 50。

### 4.2 CPU cycle 与 PPU dot

一个 CPU 周期不等于一个 PPU dot。NTSC 下常见关系是每个 CPU 周期对应 3 个 PPU dot；PAL 下约 3.2 个；Dendy 下约 3 个。PPU 的 341 dot/scanline 是独立常量，不能用“256 个像素加一点余量”简化。

### 4.3 源码观察

- cNES `system.c` 定义了 NTSC、PAL、Dendy 的主时钟、CPU divider 和 PPU divider，并用 `g_cycle_index` 在一个主时钟循环中决定 `cycle_ppu()` 和 `cycle_cpu()`。
- Obara `emulator.c` 的 `tick_master_clock()` 每次先增加 CPU 周期计数，PPU 启用时通常执行三次 `execute_ppu()`；PAL 每五轮额外执行一次。这是对不同分频比的应用层实现。
- cNES 的 APU MMIO 分支在 `system_lower_memory_read` 中直接标为 TODO，写入也直接返回；因此其主循环虽然有统一时钟，APU 行为并未完整实现。

### 4.4 NESdev 真值与实验

要验证频率关系，记录同一个事件在三个计数器中的时间：

```text
主时钟 tick:  |----|----|----|----|----|----|
CPU tick:      |C       C       C       C       C|
PPU dot:       |p p p p p p p p p p p p p p p p|
事件:                         ^ 观察 PPU dot 与 CPU cycle 的对应
```

实验可以只使用 NROM，不接 mapper IRQ；改变制式后先比较每帧 CPU 周期数、PPU dot 数和 NMI 次数，再比较画面。

## 5. 总线周期的基本阶段

一个简化的 CPU 读周期可以写成：

```text
时间 →
地址   A ─────稳定──────────────┐
R/W    R ──────────────────────┐
φ2     ─────低──────高─────────┐
数据   D ───────────有效───────┘
```

更细的时序会包含地址建立、数据保持和总线释放阶段。对于系统学习，先掌握四个事件即可：

1. CPU 给出 16 位地址。
2. CPU 给出读/写方向。
3. 被选中的设备在有效窗口提供或接收 8 位数据。
4. 周期结束后 CPU 进入下一条指令的微周期或完成当前指令。

### 5.1 等待状态

真实外部存储器、FPGA BRAM 和平台总线都可能比 CPU 逻辑慢。等待状态不是“CPU 停了但什么也不发生”，而是要保持当前地址、方向和必要的状态，插入额外周期。错误实现常见两种：

- 直接把 BRAM 当成零延迟组合 RAM，造成 PPU/APU 同周期读写语义错误。
- 每个访问都插入固定等待，虽然画面能跑，却改变了 DMA 对齐和 mapper 时钟。

### 5.2 缓存取舍

NES CPU 没有现代 CPU 那种大缓存，PPU 的图案移位寄存器本身就是一种专用流水线。FPGA 实现也不应照搬软件缓存来掩盖地址错误。可以用小寄存器阵列、预取寄存器和明确的 ready 信号，但每个额外缓存都必须回答：什么时候填入、什么时候失效、DMA 期间是否仍能访问。

### 5.3 RTL 建议

为每条访问保留 `valid`、`addr`、`rw`、`wdata`、`rdata`、`ready`。如果 CPU 是单周期状态机，至少规定访问在哪个状态采样；如果存储器是同步 RAM，规定 request/response 的延迟；如果 DMA 抢占，规定 CPU 的 `ready` 是拉低还是由总线仲裁器替换 owner。

## 6. CPU、PPU、APU 的并行关系

```text
一个主时钟区间内可以发生：
┌──────────── CPU 指令微周期 ────────────┐
│ 取指 → 读操作数 → 写回/跳转 → 下一周期 │
└─────────────────────────────────────────┘
             │                 │
             │ IRQ/NMI          │ DMA 仲裁
             ▼                 ▼
┌──── PPU 连续 dot 状态机 ────┐  ┌── APU 帧/通道计时 ──┐
│ 取 NT/AT/CHR → 移位 → 像素 │  │ quarter/half/IRQ   │
└────────────────────────────┘  └─────────────────────┘
```

### 6.1 状态机的共同结构

CPU、PPU、APU 都可以用“当前状态 + 下一状态 + 条件”描述：

```text
state = 状态寄存器
condition = 地址、PC、dot、计数器、IRQ 线
next_state = 状态转移函数
side_effect = 寄存器、RAM、像素、音频或总线副作用
```

不要用 C 的 `if` 嵌套层级直接推断 RTL 层级。一个 C 函数中可能包含多个硬件状态；一个硬件状态也可能需要多个 C 局部变量来表达。

### 6.2 中断和 DMA 的时间关系

- NMI 由 PPU vblank 事件产生，CPU 在指令边界确认并进入向量。
- IRQ 是电平概念，CPU 的 `I` 标志决定是否屏蔽；APU frame IRQ 和 DMC IRQ 是来源，mapper IRQ 另算。
- OAM DMA 由 CPU 写 `$4014` 触发，CPU 在 DMA 期间让出总线，APU/PPU 仍按自己的时间运行。
- DMC DMA 是 APU 向 CPU 索取样本字节的短事务，通常也会影响 CPU 可见的总线行为。

### 6.3 常见误区

1. 把 NMI 当成“每帧立即打断当前指令”。它要等 CPU 识别并进入中断序列。
2. 把 IRQ 当成一次性脉冲。某些来源是保持电平，清除来源和 CPU 服务是不同动作。
3. 只实现 DMA 的数据复制，不实现 dummy access 和对齐。
4. PPU 只在 CPU 读写寄存器时运行，忽略后台自己的取数流水线。
5. 把 PPU 输出像素当作 CPU 函数返回值；真实像素是按 dot 连续产生的。

## 7. CPU 总线地址空间总表

| CPU 地址 | 通常映射 | 备注 |
|---|---|---|
| `$0000`–`$1FFF` | 2 KiB 工作 RAM | 以 `$0800` 为周期镜像 |
| `$2000`–`$3FFF` | PPU 寄存器 | 以 8 个寄存器为周期镜像 |
| `$4000`–`$4013` | APU 通道寄存器 | 写入和读回行为不完全对称 |
| `$4014` | OAMDMA | 写入页码，启动 OAM DMA |
| `$4015` | APU status | 读会清某些状态，bit 5 有特殊 open-bus 语义 |
| `$4016`–`$4017` | 控制器 1/2 | 同时涉及 APU frame counter 和输入 |
| `$4018`–`$401F` | 禁用/未映像 | 具体设备行为需按 NESdev 说明核对 |
| `$4020`–`$5FFF` | 通常无设备 | 未映射读通常呈 open bus |
| `$6000`–`$7FFF` | PRG RAM/工作区窗口 | 是否存在、是否可写由 mapper 决定 |
| `$8000`–`$FFFF` | PRG ROM 窗口 | 固定 bank、切换 bank 和镜像由 mapper 决定 |

cNES 的 `system_lower_memory_*` 和 Obara 的 `mmu.c` 都把低地址空间拆成上述区域；差别主要在未实现寄存器、open bus 和 mapper 扩展的细节。详见 `04-cpu-bus.md`。

## 8. 视频、音频和输入的时间出口

### 8.1 视频

PPU 每一行输出 256 个可见像素，但内部还会进行 341 个 dot 的工作。像素可以在 dot 1 到 256 形成，剩余 dot 用于精灵、属性、nametable 和下一 tile 预取。frame buffer 只记录最终像素，不足以验证滚动和 sprite 0 hit。

### 8.2 音频

APU 产生数字通道状态，混音器把 pulse 与 triangle/noise/DMC 合成非线性输出。软件可以把混音放在每个 CPU 周期后，但 FPGA 需要定义采样率、重采样和音频 FIFO 的边界。

### 8.3 输入

标准控制器通过串行移位读回。主机输入事件可以异步发生，但控制器寄存器在 NES 总线上按 CPU 访问读取；RTL 适配器应把物理按键同步到系统时钟，再实现 strobe 和移位协议。

## 9. 从 C 代码到硬件行为的阅读方法

对每个 C 函数问四个问题：

| C 现象 | 可能对应的硬件含义 | 需要核对的证据 |
|---|---|---|
| 一次 `read(addr)` | 一个或多个 CPU 总线周期 | 6502 微周期、PPU dot、ready |
| `while` 或递归调用 | 状态机等待条件 | 下一状态、边沿、计数器 |
| `static` 全局数组 | RAM、ROM、OAM、palette 或 mapper 状态 | 复位值、读写端口、初始化来源 |
| 回调函数 | 可配置总线设备或中断源 | 函数指针替换的硬件接口 |
| `memcpy`/循环 | DMA 或批量搬运 | 是否占 CPU 周期、dummy、奇偶对齐 |
| `assert` | 设计假设 | 硬件是否有同样的非法状态约束 |

## 10. 整机最小实验

### 实验 A：三个时钟计数器

只构造一个无游戏逻辑的系统，输出：

```text
master_tick
cpu_cycle
ppu_dot
frame_dot
```

分别用 NTSC、PAL、Dendy 参数运行一帧，记录 CPU 周期数、PPU dot 数和 NMI 位置。预期是先得到约 1:3、1:3.2、1:3 的比例，再检查制式特有的帧长。

### 实验 B：空 PPU 仍会跑

关闭显示和精灵，只让 PPU 状态机运行。观察：

- vblank 状态是否在规定 scanline/dot 发生；
- NMI 产生和读取 status 的关系；
- CPU 是否仍能执行；
- 帧提交是否按制式发生。

### 实验 C：一次 RAM 访问

让 CPU 执行 `LDA $10`，记录：

```text
cycle | PC | addr | R/W | data | A | P
```

然后把 RAM 读延迟从 0 改为 1 个系统周期，确认 CPU 等待而 PPU dot 继续推进。这个实验能把“C 函数返回了值”和“硬件完成了总线周期”区分开。

## 11. 常见误区清单

- 把 NES 称作纯哈佛机或纯冯诺依曼机，忽略其混合结构。
- 用现代 CPU 的“取指/执行/访存”阶段替代 6502 的实际周期。
- 认为 PPU 只有可见像素阶段。
- 把 APU 当成 CPU 读寄存器时才推进的设备。
- 把 mapper IRQ 当成 NMI。
- 看到 C 中 `g_bus_val = 0` 就断言硬件读零。
- 用帧率作为唯一时间证据，不记录 dot、CPU cycle 和 DMA phase。
- 在 RTL 中把阻塞式 C 循环直接翻译成一个超长组合路径。

## 12. 后续 RTL 映射

建议在 `rtl/nes_core/` 规划以下层次：

```text
nes_clock_gen
  ├── nes_cpu
  ├── nes_ppu
  ├── nes_apu
  ├── nes_dma_arbiter
  ├── nes_cpu_bus_decode
  └── nes_system_top
```

第一阶段只需让地址译码、RAM、reset vector 和 PPU 状态计数可 trace；第二阶段再加入 PPU 图形流水线；APU 和复杂 mapper 放在总线/中断契约稳定之后。每个模块都应把 `source observation` 对应为一个可测试的状态变量，而不是把 C 文件名直接变成 RTL 文件名。
