# CPU 合同

本文描述 `rtl/nes_core/cpu/nes_cpu6502.v` 当前可观察的接口和时序合同。它是实现和 testbench 的接口基线；未列出的时序特性不能从当前模块推定为已经实现。

## 1. 当前端口

### 1.1 输入

| 端口 | 位宽 | 有效电平/边沿 | 当前语义 |
|---|---:|---|---|
| `clk` | 1 | 上升沿 | 共享系统时钟；状态只在 `bus_fire` 时推进 |
| `reset` | 1 | 高有效、异步 | 立即把状态机带回 reset 初值；不复位外部 RAM |
| `ce` | 1 | 高有效 | CPU clock enable；低时冻结 CPU 并压低 `bus_req` |
| `bus_hold` | 1 | 高有效 | 外部保持；优先级高于普通 ready 等待 |
| `bus_din` | 8 | 在读 `bus_fire` 完成边沿采样 | 当前读事务返回的数据 |
| `bus_ready` | 1 | 高有效 | 高时允许当前 CPU 请求完成 |
| `nmi_i` | 1 | 高有效边沿 | NMI 输入；上升事件被锁存为 pending |
| `irq_i` | 1 | 高有效电平 | 可屏蔽 IRQ 输入；`P[2]` 置位时不接受 |

### 1.2 输出

| 端口 | 位宽 | 语义 |
|---|---:|---|
| `bus_req` | 1 | CPU 请求当前总线事务；`ce=0`、`bus_hold=1` 或 reset 时为 0 |
| `bus_fire` | 1 | `bus_req && bus_ready`，一个 architectural bus cycle 的完成条件 |
| `cpu_cycle` | 32 | 已完成的 `bus_fire` 计数，包含 reset 事务 |
| `cpu_cycle_phase` | 4 | 已完成事务的 0–7 相位计数 |
| `bus_addr` | 16 | 当前 CPU 地址 |
| `bus_we` | 1 | 高为写，低为读 |
| `bus_dout` | 8 | 写事务数据 |
| `dbg_pc` | 16 | 当前 PC |
| `dbg_a`、`dbg_x`、`dbg_y`、`dbg_sp`、`dbg_p` | 8 each | 架构寄存器和状态 |
| `dbg_opcode` | 8 | 最近取到的 opcode |
| `dbg_state` | 7 | 内部 FSM 编码，供 trace 使用 |
| `dbg_nmi_pending` | 1 | 已锁存的 NMI 事件 |
| `dbg_irq_pending` | 1 | `irq_i` 的观测镜像 |
| `dbg_illegal` | 1 | 取到未支持 opcode 后置位 |

`dbg_*` 和 cycle 输出是观测接口；它们不改变 bus ownership、ready 或状态转移。

## 2. 状态推进和事务规则

1. CPU 只在 `bus_fire` 为高的上升沿改变 FSM、PC、寄存器和 cycle 计数。单独的 `clk` 上升沿、`ce=1` 或 `bus_req=1` 不足以推进状态。
2. `bus_req=1` 且 `bus_ready=0` 时，CPU 保持当前状态；`bus_addr`、`bus_we` 和 `bus_dout` 必须保持稳定，不能在等待期间换事务。
3. `bus_req=1` 且 `bus_ready=1` 时，`bus_fire=1`。读数据在完成上升沿采样，写数据在该上升沿交付给上层。
4. `ce=0` 时 CPU 状态冻结，`bus_req` 为 0；恢复 `ce` 后从原状态继续。
5. `bus_hold=1` 时 CPU 状态冻结，`bus_req` 被压低。除 `bus_req` 的 hold 语义外，地址、方向和写数据不能因 hold 自身而改变；释放 hold 后从原状态继续。
6. `reset=1` 时状态立即回到 reset 初值，且 `bus_req` 不启动新的事务。reset 解除后，当前实现先完成 5 次 `$0000` dummy read，再读取 `$FFFC` 和 `$FFFD`。
7. reset 向量完成后，当前实现把 `SP` 设为 `$FD`、`P` 设为 `$24`，然后从向量地址取 opcode。
8. `cpu_cycle_phase` 每个完成的 `bus_fire` 加一，到 7 后回到 0；它不是 PPU dot，也不是 instruction counter。

上层必须把 `bus_fire` 视为 CPU 可见的事务边界。等待、同步 RAM 延迟、DMA 插入和其他设备副作用都应在这个边界上表达，不能通过改变 `bus_addr` 来“加速”CPU。

## 3. 官方指令范围

RTL 的 decode 表覆盖官方 6502 的 151 个合法 opcode。当前可以按下面的类别理解支持面：

| 类别 | 当前指令族 | 当前寻址/形态 |
|---|---|---|
| load/store | `LDA`、`LDX`、`LDY`、`STA`、`STX`、`STY` | immediate、zero page、zero-page indexed、absolute、absolute indexed、`(zp,X)`、`(zp),Y` 的官方组合 |
| ALU/compare | `ADC`、`SBC`、`AND`、`ORA`、`EOR`、`CMP`、`CPX`、`CPY`、`BIT` | 各自的 official immediate、zero-page、absolute、indexed 和 indirect 组合 |
| read-modify-write | `ASL`、`LSR`、`ROL`、`ROR`、`INC`、`DEC` | accumulator 或 memory，含官方 indexed 组合 |
| transfer/increment | `TAX`、`TAY`、`TXA`、`TYA`、`TSX`、`TXS`、`INX`、`INY`、`DEX`、`DEY` | implied/accumulator |
| flag | `CLC`、`SEC`、`CLI`、`SEI`、`CLD`、`SED`、`CLV` | implied |
| branch | `BPL`、`BMI`、`BVC`、`BVS`、`BCC`、`BCS`、`BNE`、`BEQ` | relative，含 taken/page-cross 事务 |
| control | `JMP`、`JSR`、`RTS`、`RTI`、`BRK` | absolute、`JMP` indirect、stack/vector 序列 |
| stack | `PHA`、`PHP`、`PLA`、`PLP` | implied，遵守下方绝对栈地址合同 |
| no-op | `NOP` | implied |

`JMP ($xxFF)` 的间接页边界 bug 已按当前测试合同保留：低字节从 `$xxFF` 读取，高字节从同一高页的 `$xx00` 读取。未官方或不稳定 opcode 不在此范围内；取到后置 `dbg_illegal`，进入 `ST_TRAP`，不再发出后续总线事务，且不推进 PC 或修改架构寄存器。

当前 decode 表中的官方 opcode 集合（十六进制）为：

```text
ORA: 01 05 09 0D 11 15 19 1D
AND: 21 25 29 2D 31 35 39 3D
EOR: 41 45 49 4D 51 55 59 5D
ADC: 61 65 69 6D 71 75 79 7D
STA: 81 85 8D 91 95 99 9D
LDA: A1 A5 A9 AD B1 B5 B9 BD
CMP: C1 C5 C9 CD D1 D5 D9 DD
CPX: E0 E4 EC
CPY: C0 C4 CC
SBC: E1 E5 E9 ED F1 F5 F9 FD
LDX: A2 A6 AE B6 BE
LDY: A0 A4 AC B4 BC
STX: 86 96 8E
STY: 84 94 8C
BIT: 24 2C
ASL: 0A 06 16 0E 1E
ROL: 2A 26 36 2E 3E
LSR: 4A 46 56 4E 5E
ROR: 6A 66 76 6E 7E
INC: E6 F6 EE FE
DEC: C6 D6 CE DE
TAX/TAY/TXA/TYA/TSX/TXS/INX/INY/DEX/DEY: AA A8 8A 98 BA 9A E8 C8 CA 88
CLC/SEC/CLI/SEI/CLD/SED/CLV: 18 38 58 78 D8 F8 B8
BPL/BMI/BVC/BVS/BCC/BCS/BNE/BEQ: 10 30 50 70 90 B0 D0 F0
JMP/JSR/RTS/RTI/BRK: 4C 6C 20 60 40 00
PHA/PHP/PLA/PLP/NOP: 48 08 68 28 EA
```

`D` 位可以由 `SED/CLD` 改变；NES 2A03 的 ADC/SBC 不以十进制模式作为正常算术路径。当前 RTL 的 ADC/SBC 使用二进制 ALU，不能把这一点扩展成通用 NMOS 6502 BCD 兼容声明。

## 4. 栈地址合同

`SP` 是 8 位寄存器，但所有栈访问都使用绝对的 `$01xx` 地址：

| 事务 | 地址规则 | SP 更新规则 |
|---|---|---|
| push 写（`PHA`、`PHP`、JSR/中断 PC/P） | `$0100 + (SP - 1)`，地址先按旧 SP 计算 | 完成该写事务时 `SP` 变为同一个 `SP-1` |
| pull 读（`PLA`、`PLP`、RTS、RTI） | `$0100 + SP`；前置 dummy read 重复此地址 | 只有数据读完成后 `SP` 加一 |

因此 reset 的 `SP=$FD` 时，第一次 push 必须写 `$01FC`，而不是 `$01FD`；第一次 pull 必须读 `$01FD`。中断三字节 push 的绝对地址顺序是 `$01FC`、`$01FB`、`$01FA`。任何只按“相邻栈槽”推断而没有检查绝对地址的 testbench 都不足以验证本合同。

当前状态和栈字节值的合同还包括：

- `PHP` 推入 `P | $30`；BRK 和硬件中断的 B 位按来源区分。
- `NMI`、IRQ 和被 NMI 劫持的序列推入 B=0 的 P；BRK 正常推入 B=1。
- 栈上的 P bit 5 为 1；`PLP/RTI` 恢复时强制 bit 4/bit 5 的硬件可见规则。
- push/pull 的 dummy 访问仍会出现在总线上，即使其数据被丢弃。

## 5. IRQ 和 NMI 适配约定

CPU 面向 core 的 `nmi_i`、`irq_i` 都是**高有效**输入，模块内部不做反相：

- `nmi_i` 按上升沿识别。边沿可以在 CPU 忙时锁存到 `dbg_nmi_pending`，在取指边界服务；NMI 序列期间可按当前单点采样合同劫持 IRQ/BRK。
- `irq_i` 是高电平请求。CPU 只在 `P[2]==0` 的取指边界接受它；来源模块负责在自己的 ack/read/clear 规则中撤销请求。
- reset 向量来自 `$FFFC/$FFFD`，NMI 向量来自 `$FFFA/$FFFB`，IRQ/BRK 向量来自 `$FFFE/$FFFF`。
- core 不负责把 APU IRQ、mapper IRQ 或多个来源合成一条线；平台/bus 层负责 OR 和来源清除。
- 板级 `sys_rst_n` 是低有效，连接到 CPU 前必须由平台层转换成高有效 `reset`。异步板级线不能直接当作 core 域内的同步事件。

## 6. 暂不支持或已知的微周期差异

当前 testbench 已把下列差异记录为显式边界；它们不是“已修复”的行为：

| 项目 | 当前实现 | 目标/影响 |
|---|---|---|
| `PLA/PLP` 第 4 个周期 | 用 `$0100+SP` 的 dummy read | 2A03 常见描述使用 PC+1 dummy；当前数据读地址和事务数仍是合同的一部分 |
| `JSR` 第 3 个周期 | 读 `$0100+SP` | 地址形状与当前合同一致，但未建模 RDY 对内部周期的采样 |
| NMI/IRQ hijack 窗口 | 在压入 PC 低字节完成时单点采样 | 不实现真实芯片逐微周期 NMI 输入判定 |
| 中断 dummy | 外部中断序列的 dummy 使用当前 PC；BRK padding 读 PC+1 | 当前 bus TB 明确锁定该选择，不能泛化为所有芯片微周期 |
| RMW | 连续写旧值和新值 | 未加入 2A03 在 RDY 条件下的额外 write-cycle 行为 |
| 非法 opcode | 进入 `ST_TRAP` 并置 `dbg_illegal` | 不模拟 unofficial/JAM opcode 的不稳定行为 |

因此当前 CPU 可以作为事务级和行为级基线，但不能在文档中宣称已经逐微周期等价于真实 2A03。`tb/cpu/README.md` 和 `tb/cpu/tb_nes_cpu6502_bus.v` 是这些差异的当前证据。

## 7. 集成方必须遵守的最小规则

- 不把 `bus_req` 当作已经完成的读；只有 `bus_fire` 才能推进 CPU。
- 在 `bus_ready=0`、`bus_hold=1` 期间保持 CPU 事务输出稳定。
- 把 `bus_din` 作为完成沿的读数据，把 `bus_dout` 作为写事务数据。
- 不在 CPU 核心里实现 RAM、MMIO 副作用、open bus、DMA 或 mapper bank；这些属于上层边界。
- 用高有效信号连接 core；低有效板级线和 CDC 在平台适配层处理。
- 新增指令或中断路径时，先扩展 bus TB 的 trace/断言，再更新本文件。
