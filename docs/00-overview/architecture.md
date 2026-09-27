# 架构总览

## 1. 分层图

```text
┌──────────────────────────────────────────────────────────────┐
│ 软件模型与证据                                                │
│ NESdev / 测试 ROM / 板级观察                                   │
│ cNES@7c8c252 · c6502@4f4bf74 · Obara@aa880b9                 │
└──────────────────────────────┬───────────────────────────────┘
                               │ 行为、trace、周期和差异
                               ▼
┌──────────────────────────────────────────────────────────────┐
│ 厂商无关 NES core                                              │
│ nes_system_top（规划）                                         │
│ ┌────────────┐ ┌────────────┐ ┌────────────┐ ┌────────────┐ │
│ │ CPU        │ │ CPU bus    │ │ PPU/APU    │ │ mapper/DMA │ │
│ │ 6502/2A03 │ │ owner/ready│ │ dot/tick   │ │ bank/IRQ   │ │
│ └─────┬──────┘ └─────┬──────┘ └─────┬──────┘ └─────┬──────┘ │
│       └──────────────┴──────────────┴──────────────┘         │
│       工作 RAM、nametable、OAM、palette、PRG/CHR 窗口           │
└──────────────────────────────┬───────────────────────────────┘
                               │ 稳定的地址/数据/ready/事件端口
                               ▼
┌──────────────────────────────────────────────────────────────┐
│ EP4CE10 platform                                               │
│ 50 MHz/PLL/reset · BRAM/FIFO · SDRAM · VGA · TF · WM8978     │
│ GPIO、CDC、SDC、IO standard 和板卡引脚                          │
└──────────────────────────────────────────────────────────────┘
```

软件模型提供观察线索，NES 行为资料和测试 ROM 提供规格约束；软件模型不直接决定 RTL 文件结构。平台层只适配资源和协议，不重新解释 CPU、PPU 或 APU 的寄存器语义。

## 2. 当前仓库状态

当前已经存在的 RTL 只有：

```text
rtl/nes_core/cpu/nes_cpu6502.v
```

与它配套的自包含 testbench 位于 `tb/cpu/`。CPU 模块不实例化工作 RAM、bus decoder、PPU、APU、mapper、DMA 或 EP4CE10 IP；这些边界目前以接口和规划记录下来，尚未被描述为已实现。

## 3. 厂商无关 core 的责任

厂商无关层负责可综合的行为和稳定的内部事务端口：

- CPU 指令、状态、中断和总线请求。
- NES CPU 地址空间的区域译码、RAM 镜像、open bus 策略和 owner 仲裁。
- PPU 的 scanline/dot、vblank、NMI、nametable、OAM、palette 和像素/帧事件。
- APU 寄存器、通道、frame sequencer、IRQ 和音频采样事件。
- OAM/DMC DMA 的总线占用和完成条件。
- mapper 的 PRG/CHR bank、mirroring、RAM enable/protect 和 IRQ 状态。
- 工作 RAM、PRG/CHR 窗口及其与外部存储接口的边界。

这一层不能依赖 `PIN_E1`、Quartus primitive、特定 PLL 参数、SDRAM 命令或 VGA 时序。未知或尚未决定的物理参数应通过端口或参数显式传入。

## 4. EP4CE10 platform 的责任

平台层负责：

- 50 MHz `sys_clk` 到 NES、VGA、SDRAM 和音频所需时钟/clock enable 的生成。
- `sys_rst_n` 到核心高有效 `reset` 的转换、PLL `locked` 处理和复位同步。
- Cyclone IV BRAM、RAM/FIFO IP、SDRAM 控制器和物理地址映射。
- 把核心的 ready/valid 或 owner/hold 事务转换为 BRAM 延迟、FIFO 背压和 SDRAM 突发。
- VGA 像素输出、TF 启动与卡读取、WM8978 I2C/音频输出、GPIO 和板级引脚。
- CDC、TimeQuest SDC、IO electrical 约束和上板测量。

平台层的存储控制器可以隐藏 SDRAM 延迟，但不能向 CPU 暴露一个没有 ready/hold 语义的“瞬间数组读”。核心也不应知道某个地址最终来自 BRAM 还是 SDRAM。

## 5. CPU 当前接口

CPU 端口的完整语义在 [`cpu-contract.md`](cpu-contract.md) 中定义。当前接口摘要如下：

| 信号 | 方向 | 语义 |
|---|---|---|
| `clk` | in | 共享系统时钟 |
| `reset` | in | 高有效异步 reset |
| `ce` | in | 高有效 clock enable；低时冻结 CPU |
| `bus_hold` | in | 高有效外部保持；低时释放 |
| `bus_din[7:0]` | in | 读事务数据 |
| `bus_ready` | in | 高有效完成条件 |
| `nmi_i` | in | 高有效 NMI 边沿输入 |
| `irq_i` | in | 高有效、可屏蔽 IRQ 电平 |
| `bus_req` | out | CPU 请求总线所有权 |
| `bus_fire` | out | `bus_req && bus_ready`，表示完成一次事务 |
| `bus_addr[15:0]` | out | 当前 CPU 地址 |
| `bus_we` | out | 写方向；低为读 |
| `bus_dout[7:0]` | out | 写数据 |
| `cpu_cycle`、`cpu_cycle_phase` | out | 已完成事务计数和 0–7 相位 |
| `dbg_*` | out | PC、寄存器、opcode、状态和异常观测 |

CPU 只提出请求和方向。工作 RAM、PPU/APU 寄存器、mapper 和 DMA 的选择由上层 bus/arbiter 负责。

## 6. 单时钟加 clock enable

目标 core 采用一个共享 `clk`，用模块级 `ce` 表达更新时机：

```text
共享 clk
  ├── cpu_ce
  ├── ppu_ce
  ├── apu_ce
  ├── mapper_ce
  └── platform/storage ce
```

约束如下：

1. 不使用逻辑与门随意门控时钟；时钟网络保持连续。
2. `ce` 只允许属于当前 `clk` 域，并在明确的边沿更新状态。
3. CPU 的 `ce=0` 会冻结 CPU 并压低 `bus_req`；CPU 状态真正推进的边界是 `bus_fire`，不是单纯的 `clk` 上升沿。
4. PPU/APU 在 CPU 等待时仍可按自己的 `ce` 运行；DMA 只改变总线 owner，不停止无关模块。
5. 板级异步输入先在目标域同步，再转换成 core 的高有效事件/电平语义。

50 MHz 是 EP4CE10 的输入基线，不是已经实现的 NES 时钟。NTSC CPU/PPU 频率、3:1 关系和帧边界必须在后续时钟/仿真设计中验证，不能用未经检查的整数分频代替。

## 7. 总线请求、完成和保持

CPU 与上层事务协议如下：

```text
CPU state
   │ 组合产生
   ▼
bus_req, bus_addr, bus_we, bus_dout
   │
   ├── bus_ready=0：保持当前输出，不推进 CPU
   │
   └── bus_ready=1：bus_fire=1
                         │
                         ├─ 读：在完成边沿采样 bus_din
                         └─ 写：在完成边沿接收 bus_dout
```

- `bus_req` 表示 CPU 当前需要完成一个总线事务。
- `bus_fire` 是完成脉冲/电平信号，等于 `bus_req && bus_ready`；每次 fire 对应一个 architectural bus cycle。
- `bus_ready=0` 时，地址、方向和写数据必须保持稳定。
- `bus_hold=1` 是更高优先级的外部冻结条件；CPU 状态不推进，`bus_req` 被压低。地址、方向和写数据的稳定性由 CPU 合同和上层 hold 协议共同保证。
- 上层可以在 CPU 请求之间插入 DMA owner；CPU 不应把 DMA 事务当成自己的 `bus_fire`。

## 8. RAM、PPU、APU 和 mapper 边界

CPU 侧的地址区域计划按 NES 规则拆开：

| CPU 地址 | 目标边界 | 关键合同 |
|---|---|---|
| `$0000-$1FFF` | 2 KiB 工作 RAM | `addr[10:0]` 物理索引，镜像访问同一字节 |
| `$2000-$3FFF` | PPU 寄存器 | `addr[2:0]` 选寄存器，特殊读副作用由 PPU 负责 |
| `$4000-$4013` | APU 通道寄存器 | 写入、状态和 timer 行为由 APU 负责 |
| `$4014` | OAM DMA 控制 | 写触发 DMA；总线占用由 arbiter 负责 |
| `$4015` | APU status | 读副作用和 IRQ 清除由 APU 负责 |
| `$4016-$4017` | 控制器/帧计数器 | 输入和 APU 共享边界的译码需显式仲裁 |
| `$4020-$5FFF` | 未映射/扩展区 | open bus 不能简单固定为零 |
| `$6000-$7FFF` | PRG RAM/工作窗口 | mapper 决定存在性、enable 和 protect |
| `$8000-$FFFF` | PRG ROM 窗口 | mapper 决定固定或可切换 bank |

PPU 还有一条内部取数路径访问 nametable、attribute、CHR 和 palette。它不等同于 CPU 的 `$2007` 访问；如果共享单口 RAM，bus arbiter 必须定义 owner、延迟和优先级。

APU 产生 IRQ 和 DMC DMA 请求。APU IRQ、mapper IRQ 等来源可以在 CPU 输入处合并，但各来源的清除、pending 和 ack 必须由来源模块保留。

mapper 接收 CPU PRG 写、PPU CHR/nametable 访问和 PPU 地址观察，输出 bank number、mirroring、RAM 状态和 IRQ。mapper 不直接改变 CPU 指令语义。

## 9. 存储和资源策略

EP4CE10 板级资料显示约 423,936 memory bits（约 51.75 KiB），但有效容量取决于端口宽度、深度、同步读延迟、双缓冲和 FIFO。资源不能只按理论总量相加。

计划中的存储层次是：

| 层次 | 适合的内容 | 约束 |
|---|---|---|
| 寄存器/小表 | 状态、bank、palette 特殊值、仲裁状态 | 明确读写优先级 |
| 片上 BRAM | 2 KiB 工作 RAM、OAM、palette、PPU 小表、行缓存、必要的 FIFO | 记录 M9K/BRAM、宽度、端口和延迟 |
| SDRAM | PRG/CHR、较大的 ROM、帧缓存或音频资源 | 通过 FIFO/ready 隐藏突发和刷新延迟 |

一个 640×480 RGB565 帧缓存需要 614,400 byte，不能默认放入 EP4CE10 BRAM；即使采用行缓存，也要以目标 Fitter 报告和实际吞吐率验证。ROM/CHR 的来源、大小和 mapper bank 选择不应写进 CPU 核心理由。

每次加入 RAM、FIFO、PLL 或 SDRAM 后，都要重新记录逻辑单元、寄存器、memory bits、PLL、IO、时钟、slack、未约束路径和外部吞吐率。工具编译成功本身不是行为通过证据。

## 10. 跨层接口原则

- 地址单位固定为 CPU byte；窗口的 bank 粒度由 mapper 明确定义。
- 每个总线接口都写出 request、ready、hold、数据有效和错误/超时语义。
- 调试信号可以暴露 PC、地址、owner、PPU dot、APU frame step 和 mapper 状态，但不能改变 ready 或状态转移。
- 平台层的视频帧事件、音频 sample 事件和 FIFO 水位不反向改变 core 的寄存器语义。
- 更换存储器、时钟或板卡时，重新生成 IP、重新约束并重新执行 CDC/STA/板级验收；不把可移植性理解为同一份 IP 文件直接复制。
