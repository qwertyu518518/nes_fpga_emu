# 项目章程

## 1. 项目使命

`op_fpga_emu` 的使命是把 NES/FC 的可观察行为逐步落实为可综合、可追踪、可在 EP4CE10 上验证的 RTL。实现顺序遵循“先固定 CPU/总线合同，再加入并行外设和板级资源”的路径；不把桌面模拟器的线程、图形 API 或阻塞式内存访问直接搬进硬件。

项目同时承担学习任务：每个 RTL 行为都应能指出其 NES 行为依据、参考源码观察、当前取舍和验证证据。

## 2. 行为权威和证据等级

NES 行为的权威来源按以下顺序使用：

1. NESdev 的 2A03/2C02、APU、mapper、CPU 和 PPU 行为说明。
2. 官方或广泛采用的 NES 测试 ROM，以及可重复的板级/逻辑分析观察。
3. 多个独立模拟器对同一可观察序列的交叉印证。
4. 固定版本的参考 C 源码。
5. 教学用的简化模型。

参考源码版本固定为：

| 项目 | 提交 | 证据角色 |
|---|---|---|
| cNES | `7c8c252d74008e9a73a79ae18475d316d4f63290` | 主参考：CPU 总线、主机循环、PPU 和 mapper 组织 |
| c6502 | `4f4bf74504611ed85ea9262094bb1a9c5c638563` | CPU 状态、指令和周期级结构参考 |
| ObaraEmmanuel NES | `aa880b955e7762e4d4b18ccf96f5555c7f1fba2e` | APU、DMC DMA、内存和 mapper 的辅助观察 |

这些仓库位于 `.slim/clonedeps/repos/`，只读，不在本项目中编辑。C 代码的函数名、回调结构、默认值、TODO 或某个数组布局本身不是 NES 硬件规格。

## 3. v0 范围：CPU 行为基线

v0 是当前阶段，目标是让 CPU 的架构状态和总线可观察行为在没有完整 NES 系统的情况下可验证。

### 3.1 v0 包含

- 6502/2A03 风格的寄存器、PC、栈和状态标志。
- 官方 6502 指令集合的解码和执行路径，包括寻址、分支、栈、JSR/RTS、RTI/BRK、IRQ、NMI 和 RMW。
- reset 后的 `$FFFC/$FFFD` 向量读取，以及可追踪的 reset dummy 访问。
- `bus_req`、`bus_fire`、`bus_ready`、`bus_hold` 和 `ce` 的独立接口语义。
- 纯 RTL elaboration、自包含集成 testbench 和逐事务 bus testbench。
- 文本 trace、失败断言和已知微周期差异清单。

### 3.2 v0 不包含

- 完整的 NES 地址译码和 RAM/PRG/CHR 存储层次。
- PPU 像素流水线、APU 音频、OAM DMA、DMC DMA 或 mapper IRQ。
- 外部 ROM 文件加载、完整 iNES/NES2 解析或商业游戏兼容性。
- 6502 未官方指令的稳定实现。
- 2A03 每一个微周期、RDY 采样和模拟电气行为的完全复刻。
- VGA、TF、SDRAM、WM8978、PLL、引脚和 EP4CE10 上板验收。

### 3.3 v0 完成判据

v0 只有在以下条件同时满足时才算完成：

- CPU RTL 可由 Icarus elaboration，ModelSim/Questa 也能独立 elaboration。
- 集成 testbench 的 reset、寄存器、内存、栈和中断断言通过。
- bus testbench 的每场景事务序列、dummy access、RMW 写入、栈绝对地址和 hold/stall 不变量通过。
- 所有已知差异被记录为差异，而不是被测试输出掩盖。
- 失败时能用最近的 cycle、地址、方向、数据和状态定位问题。

## 4. v1 范围：最小可运行 NES 核心

v1 是计划中的下一阶段，不是当前完成状态。目标是让一个受控的 NROM 测试程序在完整厂商无关核心中运行，并为 EP4CE10 适配提供稳定接口。

### 4.1 v1 计划包含

- CPU bus owner/ready/hold 仲裁和 2 KiB 工作 RAM，含 `$0800` 镜像。
- NROM PRG 窗口、向量映射、基础 CHR ROM/CHR RAM 窗口和最小 mapper 状态。
- PPU 寄存器、vblank/NMI 计数和最小可观察帧时序；是否纳入完整背景渲染由验证资源决定。
- OAM DMA 的 owner、相位、dummy 和 256 字节传输合同。
- NROM 测试程序、固定 trace 格式和可重复的仿真入口。
- 平台无关的视频帧/音频采样输出端口，不直接调用桌面图形或音频 API。

### 4.2 v1 计划不自动包含

- 所有 mapper、所有 unofficial opcode、所有制式和所有 clone glitch。
- 完整模拟滤波、精确 NTSC/PAL 音频输出或 analog open bus。
- 多游戏兼容性、联网、存档 UI 或桌面模拟器功能集合。

## 5. 明确的非目标

本项目当前明确不追求：

- 复制某个 C 模拟器的源代码、目录结构或私有实现。
- 用固定零、最后一次总线值或无副作用数组访问冒充所有硬件的 open bus。
- 在 CPU 核心里放置 EP4CE10 引脚、PLL、SDRAM 物理时序或 VGA 协议。
- 用“画面能显示”或“声音能听见”代替逐总线、逐 dot 和中断证据。
- 把未官方的 6502 opcode 当作跨芯片稳定的 NES 行为。
- 在没有 Fitter、TimeQuest、引脚约束和板级测量的情况下宣称硬件可运行。
- 为了教学而隐藏已知近似；近似必须命名、限定范围并列入验证计划。

## 6. 首板和平台目标

首板是 `EP4CE10F17C8` 开拓者板。该目标只定义首轮平台适配和资源预算，不把板级信号泄漏到 NES 核心接口。

已采用的板级基线包括：

- 器件：`EP4CE10F17C8`，Cyclone IV E。
- 板载输入时钟：`sys_clk`，50 MHz，位于 `PIN_E1`。
- 板级复位：`sys_rst_n`，低有效，位于 `PIN_M1`。
- 目标资源量级：约 423,936 memory bits、2 个 PLL；具体使用量必须以目标工程 Fitter 报告为准。

核心使用高有效 `reset` 和高有效 `nmi_i`/`irq_i`，板级低有效信号、异步输入和 CDC 由 `rtl/platform/ep4ce10/` 的适配层转换。首板资源、引脚和电气验证不改变 `docs/nes-study/` 中的 NES 行为权威地位。

## 7. 交付物和目录责任

| 交付物 | 位置 | 责任 |
|---|---|---|
| 厂商无关 NES RTL | `rtl/nes_core/` | CPU、总线、PPU、APU、mapper 和系统核心 |
| EP4CE10 适配 RTL | `rtl/platform/ep4ce10/` | 时钟、复位、存储器 IP、CDC、VGA、TF、SDRAM、音频和引脚连接 |
| 仿真验证 | `tb/`、`tools/` | testbench、脚本、trace 和断言 |
| 行为与项目合同 | `docs/00-overview/` | 范围、接口、架构、验证和决策 |
| 学习材料 | `docs/nes-study/`、`docs/hardware/` | 背景阅读，不作为完成状态证明 |
| 参考源码 | `.slim/clonedeps/repos/` | 只读观察对象 |

## 8. 变更原则

行为变化必须先更新合同或决策记录，再修改 RTL；新增测试必须说明预期来自 NESdev、测试 ROM、固定 C 还是当前工程取舍。任何未来计划都要标为计划，不能用“已支持”“已验证”描述尚未存在的模块或板级结果。
