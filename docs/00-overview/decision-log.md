# 决策记录

本文件记录已经采用的项目决策。决策描述约束和理由，不等价于相应 RTL、测试或板级工作已经完成；当前实现状态以仓库文件和验证记录为准。

**阅读提示：** D001–D010 是 v0 期的决策记录，各条“边界”段落里出现的实现状态是**当时**的快照（例如“PLL/enable 发生器尚未实现”“bus arbiter 尚待实现”）。项目此后已经演进：系统顶层到 `nes_system_v6`，并新增了 Zynq-7020 平台层，`nes_cpu_bus` 等也已实现。后续决策从 D011 起；最新状态以仓库根 `README.md`、[`architecture.md`](architecture.md) 第 2 节和 [`../modules/`](../modules/) 为准。

## D001：cNES 作为主参考源码

**状态：** 已采用。

**决策：** 将 `.slim/clonedeps/repos/caseif__cNES/` 固定在提交 `7c8c252d74008e9a73a79ae18475d316d4f63290`，作为 CPU 总线、主机循环、PPU、renderer 和 mapper 组织的首要源码观察对象。

**理由：** 它的 `system`、CPU、PPU 和 mapper 回调关系能提供清晰的主机架构地图，便于把软件状态映射为 RTL 边界。

**边界：** cNES 的 APU MMIO 存在明确 TODO；它不能作为 APU 完整行为来源，也不能直接作为 RTL 代码模板。

## D002：c6502 作为 CPU 状态和周期结构参考

**状态：** 已采用。

**决策：** 将 `.slim/clonedeps/repos/caseif__c6502/` 固定在提交 `4f4bf74504611ed85ea9262094bb1a9c5c638563`，作为寄存器、指令表、寻址、周期状态和中断结构的 CPU 参考。

**理由：** 它把指令 decode、addressing、周期和外部 memory callback 分开，适合映射成 RTL 状态机和接口。

**边界：** C 中的 unofficial opcode、初始化调用次数和微周期近似不能自动升级为 2A03 规格；当前 CPU 合同优先记录实际可观察行为。

## D003：Obara 作为 APU 和 DMA 辅助参考

**状态：** 已采用。

**决策：** 将 `.slim/clonedeps/repos/ObaraEmmanuel__NES/` 固定在提交 `aa880b955e7762e4d4b18ccf96f5555c7f1fba2e`，主要用于 APU 五通道、frame sequencer、DMC DMA、内存对象和 mapper 组织的交叉观察。

**理由：** cNES 的 APU 路径不完整，Obara 提供了另一套显式上下文和 DMA/APU 组织，可帮助提出待验证问题。

**边界：** Obara 的滤波器、重采样、周期表和 clone 逻辑仍是软件模型；采用它们之前必须与 NESdev 说明和测试结果比较。

## D004：EP4CE10F17C8 作为首板

**状态：** 已采用为首板目标。

**决策：** 以 `EP4CE10F17C8` 开拓者板作为第一块平台适配目标，板级基线为 50 MHz `sys_clk`、低有效 `sys_rst_n`、约 423,936 memory bits、2 个 PLL，并按实际顶层连接核对引脚和 IO。

**理由：** 板的资源和外设已经足以覆盖 CPU、PPU、SDRAM、VGA、TF 和音频的学习目标；固定首板便于建立可复现的资源和时序记录。

**边界：** 板级例程的注释、IP 生成参数和编译成功不能代替 Fitter、TimeQuest、电气和上板测量。当前没有可宣称的 NES 顶层 Quartus 通过结果。

## D005：CPU/DRAM 分层

**状态：** 已采用为架构约束。

**决策：** CPU 只面对稳定的 16 位地址、8 位数据和 ready/hold 事务；工作 RAM、PRG/CHR 存储、SDRAM 控制器、FIFO 和物理地址映射放在 core 之外，通过平台/存储适配层连接。

**理由：** 这样 CPU 行为不依赖 SDRAM 命令、刷新、突发和同步 RAM 延迟，也可以在仿真、ModelSim 和不同存储实现之间复用。

**边界：** 目前 CPU 与外部存储的集成 RTL 尚未存在；该决策是接口和目录约束，不是已经完成的 SDRAM 控制器实现。

## D006：单时钟加 clock enable

**状态：** 已采用为目标 core 约束。

**决策：** NES core 使用一个共享 `clk`，用 `ce` 表达 CPU、PPU、APU 和 mapper 的更新时机；不在 core 中用逻辑与门随意门控时钟。异步板级输入在目标域同步。

**理由：** 连续时钟网络配合 CE 更容易做 STA、复位和 trace；也能让 CPU 等待时 PPU/APU 按自己的事件继续运行。

**边界：** EP4CE10 50 MHz 到 NES/VGA/SDRAM/音频的 PLL、相位和 enable 发生器尚未实现；CPU 模块当前只在 `bus_fire` 边界推进自己的状态。

## D007：CPU bus 使用 request/fire/hold

**状态：** 已采用并由当前 CPU 接口实现。

**决策：** 使用 `bus_req` 表示请求，`bus_fire = bus_req && bus_ready` 表示完成，使用 `bus_hold` 表示外部冻结；等待期间地址、方向和写数据保持稳定。

**理由：** 该接口能表达同步 RAM、DMA、仲裁和 PPU/APU 等待，不把一次 C 函数调用误认为一个硬件周期。

**边界：** 上层 bus arbiter、RAM 和 DMA 尚待实现；当前 testbench 只验证 CPU 端口和自包含 RAM 的行为。

## D008：v0 先固定 CPU 和事务级证据

**状态：** 已采用。

**决策：** v0 以官方 6502 指令、reset/vector、栈/中断、bus request/fire/hold 和自包含 testbench 为完成范围；PPU、APU、mapper、SDRAM 和板级输出属于后续阶段。

**理由：** 先建立可定位的 CPU 基线，能把指令、dummy、等待和中断错误与后续视频/音频错误分开。

**边界：** v0 不是完整 NES 模拟器，也不宣称已经实现真实 2A03 的所有微周期；已知差异在 CPU 合同和 bus TB README 中登记。

## D009：官方 opcode 与非法 opcode 分离

**状态：** 已采用为当前 CPU decode 约束。

**决策：** 官方 6502 合法 opcode 进入执行路径；未官方/不稳定 opcode 取到后置 `dbg_illegal` 并停止发出事务。

**理由：** 官方集合有稳定、可验证的基线；不同芯片的 unofficial 行为需要单独定义，不能混入 v0 的成功判据。

**边界：** 该决策不排除未来为特定测试 ROM 增加 unofficial 策略；新增策略必须有独立合同和测试。

## D010：行为权威优先于参考实现

**状态：** 已采用。

**决策：** NESdev 行为说明和测试 ROM 优先于固定 C 的内部状态；每个差异都标记来源、范围和取舍。

**理由：** 参考模拟器可能省略 PPU/APU 行为、使用固定 open bus 近似，或把软件调度顺序误当成硬件边沿。

**边界：** 参考仓库仍必须固定提交并可复查；它们是只读证据，不是本项目 RTL 的复制源。

## D011：Zynq-7020 作为第二个平台目标

**状态：** 已采用。

**决策：** 在 EP4CE10 之外新增 Zynq-7020（Navigator V2）平台层 `rtl/platform/zynq/`，由 `nes_zynq_clk` 用 MMCM 从 50 MHz 生成精确的 21.477272727 MHz 核时钟与 25 MHz LCD 时钟，`nes_zynq_top` 负责三时钟域与复位网接线。

**理由：** EP4CE10 的 PPU 综合面积装不下（见 [`risk-register.md`](risk-register.md) 第 10 节），需要更大器件先把整机跑通；Zynq 板自带 800×480 RGB LCD、GT9147 电容触摸与 WM8960 codec。

**边界：** EP4CE10 仍是首板目标且尚未综合；两套平台并存、互不替代。Zynq 侧的综合/时序数字来自仓库外的 Vivado 工程，复现过程见 [`vivado-runbook.md`](vivado-runbook.md)。

## D012：视频交付分两条路线

**状态：** 已采用。

**决策：** EP4CE10 走行缓冲（`nes_line_buffer_vga` + `nes_vga_timing`）；Zynq 的 800×480 面板走整帧缓冲（`nes_video_800x480`，真双口 BRAM 即唯一的跨时钟域）。整帧缩放的 `nes_video_scaler` 只作参考模型，不作为任一平台的可综合交付。

**理由：** 25 MHz 不是 21.477272727 MHz 的整数倍，面板像素必须走真实 25 MHz 沿而不能用核内 clock enable；真双口 BRAM 天然跨界，省掉同步器/握手/背压。

**边界：** 800×480 路径是单缓冲、无撕裂保护，刷新率由参数决定（默认约 45.1 Hz，不是 60 Hz）。

## D013：卡带内容进 bitstream

**状态：** 已采用。

**决策：** 卡带 PRG/CHR 由 `nes_cart_rom`（BRAM + `$readmemh`）承载；主机侧用 `tools/nes2hex.ps1` 把 iNES 转成提交在仓库里的 hex 文件。

**理由：** Zynq 上 TF 卡与 QSPI flash 在 PS 的 MIO 引脚、PL 够不到，**不在 bitstream 里的 ROM 就是 PL 看不见的 ROM**。

**边界：** 没有运行时加载、没有 TF 读通路、没有热插拔；CHR 高 bank 对 CNROM/MMC1/MMC3 是接受的别名（见 [`../modules/cart-rom.md`](../modules/cart-rom.md)）。

## D014：音频交付为有理抽取 + I2S 组装层 + WM8960

**状态：** 已采用。

**决策：** APU 的采样 strobe（≈1.789 MHz）经精确有理抽取 2016/55 与 4/4/2 三级滑动平均降速率，再进 `nes_audio_i2s`（CDC FIFO + `nes_i2s_shifter`）串行输出；codec 由其 I2C 主控 `wm8960_i2c` 配置。Zynq 板上的器件是 **WM8960**（EP4CE10 开拓者板上的才是 WM8978，两者寄存器图不同）。

**理由：** 单个 FIFO 的单生产/单消费结构里任何采样率失配都会让水位走满或走空；只有有理、无累积误差的抽取才能让生产者与消费者精确匹配。

**边界：** 不是完整抗混叠 FIR；没有上板音频验收。

## D015：触摸作为手柄输入的来源

**状态：** 已采用。

**决策：** Zynq 板上用 GT9147 电容触摸（`nes_touch_input`）配合两个 PL 键与板载 TPAD 生成 `buttons[7:0]`；坐标帧与面板尺寸从控制器自己的寄存器（输出最大值、`X2Y`）一次性校准读出，而不是硬编码假设。

**理由：** 板厂驱动的 GT 分支是直通、从未配置过坐标帧，现场“d-pad 四个方向全反”就是坐标帧与代码假设不一致的特征；控制器自己能报出它实际使用的帧。

**边界：** EP4CE10 没有触摸通路；多点/手势/滑动未建模；见 [`../modules/touch-input.md`](../modules/touch-input.md)。

## 未决事项

以下事项是 v0 期登记的尚未决定或尚未实现项，不应在状态报告中写成完成。其中 bus arbiter 命名、NROM 来源与部分存储分配已经在后续实现中确定（见 D011–D015 与 [`../modules/`](../modules/)）；**仍未关闭的风险以 [`risk-register.md`](risk-register.md) 的最新内容为准**：

- 目标 v1 的具体 NES 制式和 PPU 功能深度。
- 首个 NROM test ROM 的来源、许可和 golden trace 格式。
- CPU/PPU 同沿事件优先级、DMA 对齐和最终 bus arbiter 信号命名。
- EP4CE10 上 PRG/CHR、帧缓存、音频 FIFO 的实际存储分配。
- Quartus 版本、PLL 参数、SDC 版本和首板上电/复位时序。
