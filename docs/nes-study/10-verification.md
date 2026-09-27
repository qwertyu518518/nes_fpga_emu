# 10 验证：从“能运行”到“能解释每个周期”

## 1. 验证目标

本目录把验证分成两个问题：

1. **功能正确**：最终画面、声音、寄存器和游戏状态是否符合预期？
2. **时序正确**：产生这些结果的总线访问、dot、dummy、DMA、IRQ 和优先级是否正确？

功能通过不自动推出时序通过。一个 PPU 画面可能来自每像素直接扫描 nametable 的组合逻辑，而不是真实的八相位取数；一个 DMC sample buffer 可能直接读数组，而没有 CPU 总线停顿；一个 NROM 可能在地址范围上“看起来对”，但没有正确镜像。

## 2. 证据优先级和验证对象

| 证据 | 能证明什么 | 不能单独证明什么 |
|---|---|---|
| NESdev 行为表/说明 | 硬件应满足的规则 | 你的 RTL 实际产生了这些边沿 |
| 测试 ROM | 一组真实软件对时序和状态的约束 | 覆盖未测试的边界 |
| 独立参考模拟器 trace | 另一种实现的可观察序列 | 它自身一定没有近似 |
| 固定 C 源码 | 某个实现如何组织状态 | 硬件规格本身 |
| RTL assertion | 当前运行没有破坏不变量 | 需求本身是否写错 |
| 黄金输出 | 与选定模型一致 | 选定模型一定符合所有硬件变体 |

对每个测试结果记录三种结论：

```text
[源码观察] 参考 C 实际输出了什么
[NESdev 真值] 规范要求什么
[RTL 结果] 当前实现输出了什么
```

## 3. 验证分层

```text
L0 文件解析
  ↓
L1 CPU/内存事务
  ↓
L2 DMA/中断
  ↓
L3 PPU/APU 周期
  ↓
L4 mapper/板级行为
  ↓
L5 系统级游戏和 FPGA 平台
```

### 3.1 L0：文件解析

检查：

- magic、PRG/CHR 长度；
- trainer 偏移；
- mapper ID、submapper；
- mirroring、battery、four-screen；
- RAM/CHR RAM 容量；
- 短文件、溢出、非法 shift count。

这一层不应通过启动大型游戏间接验证。输入一个故意损坏的 header，解析器应在配置阶段报告明确错误。

### 3.2 L1：CPU/内存事务

检查：

- reset vector；
- opcode 和 operand 读取；
- RAM 镜像；
- PPU/APU 寄存器地址折叠；
- NROM PRG 读取；
- stack 和 JSR/RTS；
- 每个指令的 cycle count；
- dummy read/write。

### 3.3 L2：DMA/中断

检查：

- OAM DMA 513/514 周期；
- DMC 取样对 CPU 的影响；
- NMI 边沿、IRQ 电平和屏蔽；
- vector 读取顺序；
- BRK/RTI 栈；
- mapper IRQ acknowledge/reload。

### 3.4 L3：PPU/APU 周期

检查：

- PPU `(scanline,dot)`；
- v/t/x/w；
- NT/AT/pattern fetch 相位；
- sprite evaluation/fetch；
- status read、NMI suppression；
- APU frame step、length/envelope；
- DMC rate、DMA 和 IRQ。

### 3.5 L4：mapper/板级

检查：

- PRG/CHR bank 边界；
- bank wrap/clamp；
- mirroring；
- PRG RAM enable/protect；
- A12 filter；
- submapper/clone 的差异。

### 3.6 L5：系统/平台

检查：

- 多帧画面和滚动；
- 控制器输入；
- 音频 FIFO 和视频 frame ready；
- FPGA BRAM/SDRAM/SPI 配置；
- 长时间运行的稳定性、复位和资源使用。

## 4. 最小 trace 格式

### 4.1 CPU 总线 trace

```text
cycle, pc, instr_cycle, addr, rw, wdata, rdata, owner, ready, ppu_dot, dma_phase, nmi, irq
```

示例：

```text
c       pc    ic  addr   rw d  owner  ready dot phase nmi irq
12      8000  1   8000   R  A9 CPU    1     36  IDLE   1   1
13      8001  2   8001   R  01 CPU    1     39  IDLE   1   1
14      8002  3   0010   W  01 CPU    1     42  IDLE   1   1
```

### 4.2 PPU trace

```text
scanline,dot,addr_bus,fetch_phase,nt,at,pattern_lo,pattern_hi,x,y,palette_index,nmi
```

### 4.3 APU trace

```text
cycle,frame_step,quarter,half,pulse1_step,pulse2_step,tri_step,noise_lfsr,dmc_state,dmc_remaining,irq
```

### 4.4 Mapper trace

```text
cycle,source,addr,write_value,prg_bank,chr_bank,mirroring,ppu_addr,a12,irq_counter,irq_line
```

## 5. 黄金模型和差分比较

### 5.1 三种比较方式

| 方式 | 优点 | 局限 |
|---|---|---|
| RTL 对固定 C | 容易得到可重复 trace | C 可能有近似或 bug |
| RTL 对独立模拟器 | 更容易发现共同假设错误 | 两者可能共享错误 |
| RTL 对 NESdev 表/测试 ROM | 最接近权威行为 | 需要人工把规范转成断言 |

建议顺序：

1. 先用极小手工预期值，不依赖完整 C。
2. 再与固定 C trace 做差分。
3. 对关键边界使用测试 ROM 和 NESdev 规则。
4. 记录每次差异的分类，而不是简单以“不同”判失败。

### 5.2 差异分类

```text
D1  只差最终数据
D2  数据相同但周期不同
D3  CPU 事务相同但 PPU dot 不同
D4  同周期多个事件顺序不同
D5  C 模型简化，NESdev 真值可能支持 RTL
D6  NESdev 真值需要更细的 clone 资料
```

## 6. CPU 测试

### 6.1 指令类别覆盖表

| 类别 | 代表指令 | 必查项目 |
|---|---|---|
| load/store | `LDA`, `STA`, `LDX`, `STY` | Z/N、地址、总线方向 |
| transfer | `TAX`, `TXA`, `TYA` | 标志和顺序 |
| arithmetic | `ADC`, `SBC`, `CMP` | C/V/Z/N |
| logic | `AND`, `ORA`, `EOR`, `BIT` | 标志和总线读取 |
| increment | `INC`, `INX`, `DEX` | RMW dummy write |
| shift | `ASL`, `LSR`, `ROL`, `ROR` | carry、dummy、memory |
| branch | `BCC`, `BEQ`, `BNE` | taken/not taken/page cross |
| stack | `PHA`, `PHP`, `PLA`, `PLP` | S、dummy、B/5 |
| jump | `JMP`, `JSR`, `RTS` | PC、stack、indirect bug |
| interrupt | `BRK`, `RTI`, IRQ, NMI | vector、B、I、NMI hijack |
| unofficial | `LAX`, `SAX`, `SLO`, `RRA` | 版本差异和稳定性 |

### 6.2 周期断言

对每条测试程序建立基线：

```text
opcode: A9 01
cycles: 2
trace:
  read $8000
  read $8001
```

若 RTL 结果多一个或少一个周期，优先检查：

- 状态机是否在 cycle 0/1 重复取指；
- reset 后 `g_instr_cycle` 类状态是否清零；
- 同步 RAM ready 是否被重复计算；
- `g_instr_cycle = 0` 和 `1` 的边界。

## 7. 总线和地址译码测试

### 7.1 地址覆盖矩阵

| 测试地址 | 期望设备 | 必查副作用 |
|---|---|---|
| `$0000`, `$0800`, `$1000`, `$1800` | RAM | 同一物理 offset |
| `$2000`, `$2002`, `$2007` | PPU | 镜像、status/data 特殊行为 |
| `$4000`, `$4014`, `$4015`, `$4016`, `$4017` | APU/IO | 读副作用、控制器、frame counter |
| `$4020` | open bus | 读值模型 |
| `$6000` | PRG RAM 或禁用 | enable/protect |
| `$8000`, `$C000` | PRG | 固定/镜像 bank |
| `$FFFF` | PRG/vector | 读值和 bank 边界 |

### 7.2 Bus scoreboard

建立参考事务模型：

```text
expected_req = CPU FSM 产生的请求
actual_req    = RTL bus arbiter 实际接受
ready         = 目标设备完成
rdata         = 设备返回值
```

在每个周期断言：

```text
actual_req → actual_req 在下一 ready 周期完成
CPU 暂停时 owner 不能错误变成 CPU
PPU 内部取数不能被误记为 CPU 请求
```

## 8. DMA 验证

### 8.1 OAM DMA 状态机

| phase | 预期 | 失败信号 |
|---|---|---|
| `IDLE` | 无总线占用 | `$4014` 后仍 IDLE |
| `DUMMY` | 一次规定读 | 没有 dummy 或数据被错误使用 |
| `ALIGN` | 奇偶条件满足后进入 READ | 对齐条件永远不退出 |
| `READ` | 源地址递增/正确 | 读错 page 或 index |
| `WRITE` | `$2004` 写缓冲值 | 写入 OAM 顺序错误 |
| `FINISH` | 恢复 CPU owner | CPU 永久停机或提前恢复 |

### 8.2 长度和内容

- 数据内容：`OAM[i] == source[page*256 + ((offset+i) % 256)]`，具体起始 offset 需按硬件规则确认。
- 传输长度：256 字节。
- 周期：513 或 514，依起始相位。
- PPU：在 DMA 期间继续增加 dot。
- CPU：不执行自己的指令。

### 8.3 DMC DMA

DMC 需要同时观察：

```text
DMC ready
CPU owner
DMA phase
sample address
bytes_remaining
DMC output level
CPU PC
```

测试一个字节和完整样本两种长度，确认 CPU stall 不会破坏 APU rate counter。

## 9. 中断验证

### 9.1 NMI

1. 产生 vblank；
2. 确认 NMI line 的下降/上升边沿；
3. CPU 在指令边界进入 `$FFFA`；
4. handler 执行 `RTI`；
5. 回到被中断地址；
6. 重复一帧确认不会重复触发，除非出现新边沿。

### 9.2 IRQ

分别用 APU frame IRQ、DMC IRQ、mapper IRQ 作为来源。每个来源独立验证：

```text
source pending
line level
I flag mask
vector
handler acknowledge
source clear
```

### 9.3 BRK 和 NMI hijack

构造 BRK 正在压栈时出现 NMI 的场景，检查最终 vector 是 `$FFFA` 而不是 `$FFFE`，并验证 PC/P 压栈顺序。这个测试对 C 状态机尤其重要，因为 `g_nmi_hijack` 只在某些中断周期设置。

## 10. PPU 验证

### 10.1 背景图块黄金测试

建立一个最小 tile：

```text
CHR low  = 0b10101010
CHR high = 0b01010101
AT       = palette 1
```

预期每个像素的 2-bit pattern 按固定顺序变化。比较：

```text
expected_pixel = palette[attribute*4 + pattern]
actual_pixel   = PPU output
```

### 10.2 滚动边界

逐项覆盖：

- coarse X 0→31→0；
- coarse Y 28→29→0；
- fine Y 6→7→0；
- nametable horizontal/vertical bit 翻转；
- dot 257 水平复制；
- pre-render 垂直复制；
- `x` 的 0/7 边界。

### 10.3 精灵

构造：

- 0 个透明 sprite；
- 1 个 sprite；
- 9 个以上重叠 sprite；
- sprite 0 非透明/透明；
- priority 0/1；
- horizontal/vertical flip；
- 8×8/8×16；
- 左 8 像素裁剪。

检查 OAM 顺序、最多 8 个 secondary sprite、sprite overflow 和 sprite 0 hit。

### 10.4 奇数帧

在 NTSC 渲染打开和关闭两种状态比较 pre-render 行末端 dot。奇数帧跳过 dot 的条件应与 NESdev 真值一致；cNES 的具体 `CYCLES_PER_SCANLINE - 3` 注释表明它曾有实现疑问，不能直接当作硬件常量。

## 11. APU 验证

### 11.1 单通道单元

| 通道 | 最小测试 | 观察 |
|---|---|---|
| Pulse 1 | 固定 timer、duty、volume | step、length、sweep mute |
| Pulse 2 | 同上并切换 negate | 与 Pulse 1 的负 sweep 差异 |
| Triangle | linear reload、period | 32 步序列、linear counter |
| Noise | short/long mode | LFSR tap、周期表 |
| DMC | 一个 8-bit sample | DMA、level、地址、IRQ |

### 11.2 Frame sequencer

记录每个 step 的：

```text
frame_step
quarter_clock
half_clock
irq_flag
length counters
linear counter
```

测试 `$4017` mode 切换和 IRQ inhibit，验证 reset delay 是否有独立状态。

### 11.3 混音

先用固定通道输出计算预期非线性混音，再加入采样 FIFO。验证：

- 通道禁用时贡献为零；
- `pulse_LUT` 和 `TND_LUT` 的输入范围；
- sample index 和 FIFO 满/空；
- 帧结束时最后样本是否保留。

音频的主观“像不像”不能替代数值 trace。

## 12. Mapper 验证

### 12.1 通用断言

```text
prg_offset < prg_size 或命中明确的 wrap 规则
chr_offset < chr_size 或命中明确的 wrap 规则
PPU CHR read 只在 $0000-$1FFF 触发 mapper CHR path
A12 只由 PPU address bus 变化触发
IRQ line = pending && enabled
```

### 12.2 状态测试

| mapper | 测试重点 |
|---|---|
| NROM | 16 KiB mirror、CHR RAM |
| UxROM | bank 写入、最后 bank 固定 |
| CNROM | 8 KiB CHR、PRG 固定 |
| MMC1 | serial 五 bit、reset、四种 PRG/CHR mode |
| MMC3 | 8 KiB PRG、CHR inversion、A12 IRQ、ack/reload |

对每个 mapper 先测试“无渲染影响”的纯地址译码，再接入 PPU。这样能把 bank 错误与画面流水线错误分开。

## 13. 长时间和随机验证

### 13.1 定向随机

对 CPU 指令使用固定 seed 的随机 opcode，对以下字段做边界覆盖：

- 16 位地址；
- 页边界；
- X/Y=0、1、0x7F、0x80、0xFF；
- P 的每个标志；
- OAM DMA 奇偶起点；
- NMI 到达不同指令周期；
- mapper bank 0、1、最后 bank、越界值。

### 13.2 守恒检查

CPU 事务日志应满足：

```text
每个 CPU 请求最终有一个完成或明确 abort
每个 DMA read 有一个对应 write 或明确的 DMC consume
每个 PPU dot 只有一个编号
每个 frame_ready 恰好对应一帧
```

出现未完成事务时，先找仲裁和 ready，不要先修改预期数据。

## 14. 仿真平台和可观测性

### 14.1 轻量 trace

早期可把关键字段写到文本或 VCD：

```text
if (trace_enable && cpu_req)
    $display(...);
```

不要在每个内部组合信号都打开波形；先保留总线、状态和外设边界。

### 14.2 断言层次

```text
CPU 内部：
  PC/状态范围、cycle 单调、vector 顺序

Bus：
  owner/ready、地址范围、DMA phase

PPU：
  v/t/x/w 合法、dot 范围、pixel x/y 范围

APU：
  counter 范围、DMC remaining、IRQ 状态

Mapper：
  bank mask、A12 filter、IRQ line
```

### 14.3 失败信息

失败日志至少带：

```text
时间/周期
当前状态
最近一次总线事务
当前 PPU scanline/dot
当前 DMA phase
当前 mapper/APU 关键寄存器
```

只打印“expected X got Y”通常不足以定位跨模块错误。

## 15. FPGA 平台验证

RTL 仿真通过后还要检查：

- 目标 FPGA 的 BRAM/LUT/寄存器资源；
- ROM/CHR 是否能由配置接口加载；
- SDRAM 延迟和仲裁；
- 视频时序和双缓冲；
- 音频 FIFO 欠载/过载；
- 输入同步和按键去抖；
- CDC handshake；
- 长时间运行的热、功耗和帧稳定性。

平台层不应改变 NES 核心的寄存器语义。若平台需要改变帧率，应在 frame ready/sample FIFO 层适配。

## 16. 最小回归集合

建议第一批回归固定为：

1. NROM 16 KiB PRG + CHR RAM reset/vector。
2. `LDA/STA/JMP` CPU trace。
3. RAM 镜像和 PPU register mirror。
4. PPU vblank/NMI 一帧。
5. 单色背景 tile。
6. 水平/垂直滚动。
7. OAM DMA 256 字节。
8. IRQ/NMI/RESET。
9. UxROM PRG bank。
10. CNROM CHR bank。
11. MMC1 serial register。
12. MMC3 A12 IRQ。
13. APU 单通道和 frame sequencer。
14. DMC 一个样本。
15. 长时间 RAM/VRAM/OAM 稳定性。

## 17. 常见误区

- 只比较画面截图，不比较寄存器和总线 trace。
- 用一个固定 C trace 作为所有 NES 行为的真值。
- 把测试失败简单归咎于“时序差一个周期”，不查 dummy 和 ready。
- 断言太多但没有覆盖外部行为，导致仿真变慢却仍漏错。
- 随机测试没有固定 seed，失败无法复现。
- 只测试 NROM，不测试 mapper 初始向量。
- 只测试 PPU 可见像素，不测试 NMI、pre-render 和 odd-frame。
- 只听 APU 输出，不检查 DMC CPU stall。
- testbench 私自给 RAM/ROM 零延迟，掩盖 RTL 的等待问题。
- FPGA 仿真和 RTL 仿真使用不同的 reset 或 ROM 装载顺序。
- 看到状态最终恢复就认为中断 ack 正确，不检查 pending 标志和边沿。

## 18. 后续 RTL 验证接口

建议核心 RTL 保留一个不影响综合行为的 debug 端口：

```text
debug_cycle
debug_cpu_state
debug_cpu_addr/rw/data
debug_ppu_scanline/dot/v/t/x/w
debug_ppu_addr
debug_dma_phase
debug_mapper_irq
debug_apu_status
```

testbench 可以根据 `debug_enable` 选择文本 trace、VCD 或断言。调试端口不应改变总线 ready 或状态转移；否则测试平台本身会改变被测行为。

## 19. 完成定义

一个 NES 核心阶段完成，至少应能回答：

- 这个测试的预期来自 NESdev 真值、固定 C 还是两者？
- 哪个周期、地址和状态第一次不同？
- 差异是数据、dummy、优先级、DMA、边沿还是模型简化？
- RTL 是否在所有合法输入下保持状态不变量？
- FPGA 平台的存储器和时钟延迟是否改变了核心行为？

只有能够回答这些问题，才能把“画面能显示、声音能听见”提升为可维护的 NES RTL。
