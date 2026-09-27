# 04 CPU 总线、地址译码与 DMA 仲裁

## 1. 总线是“事务”，不是一次函数调用

对 CPU 来说，一次总线访问至少包含：

```text
地址 addr[15:0]
方向 rw
写数据 wdata[7:0]
读数据 rdata[7:0]
有效 valid
完成 ready
```

不同资料会把 `valid`、`ready`、锁存、仲裁和 `R/W` 分成不同信号。名称可以不同，语义必须明确：CPU 什么时候认为事务开始，什么时候采样读数据，等待时哪些信号保持稳定。

### 1.1 CPU 侧和 PPU 侧的差别

CPU 总线主要服务 6502；PPU 还有一条内部图形取数路径。两者可能访问 nametable 或 palette 相关资源，也可能由 mapper 通过 A12 观察 PPU 地址。把两者合并成一条“读内存函数”会让以下问题消失：

- PPU 取数是否有固定 pipeline 延迟；
- CPU `$2007` 访问是否会与渲染取数冲突；
- mapper IRQ 到底观察 CPU 地址还是 PPU 地址；
- DMA 是否能暂时阻止 CPU，但允许 PPU 继续工作。

## 2. CPU 一个简化读周期

```text
周期边界       │<----------- 一个 CPU 访问 --------->│
地址 addr      A────────────保持稳定──────────────────A
R/W            R────────────保持稳定──────────────────R
φ2/valid       __有效__________________________________
rdata          ───────────从设备得到有效值──────────────
ready          ───────────设备在窗口内拉高──────────────
```

### 2.1 读事务的阶段

| 阶段 | 地址/方向 | 数据 | 设计问题 |
|---|---|---|---|
| 地址建立 | CPU 输出目标地址 | 无意义 | 地址译码何时稳定 |
| 访问窗口 | 保持 R 或 W | 读数据或写数据有效 | RAM/ROM/APU 的 ready |
| 完成/释放 | CPU 采样或结束 | 锁存到寄存器 | 是否还需要一个保持周期 |

### 2.2 写事务

```text
地址       A────────────目标地址────────────
R/W        W────────────写方向──────────────
wdata      D────────────写数据──────────────
ready      ─────────────目标设备接受────────
```

写 ROM、禁用寄存器、禁用 PRG RAM 都是合法外部行为：设备可以接收写周期但不改变存储内容。RTL 中应区分“总线完成”和“存储写入生效”。

## 3. NES CPU 地址空间

| 地址范围 | 设备/窗口 | 典型周期 | 读回和写入 |
|---|---|---|---|
| `$0000-$1FFF` | 工作 RAM | 可变 | 读/写；按 `$0800` 镜像 |
| `$2000-$3FFF` | PPU 寄存器 | 可变 | 8 个寄存器周期镜像；部分寄存器有特殊读副作用 |
| `$4000-$4013` | APU pulse/triangle/noise/DMC 寄存器 | 可变 | 通道寄存器 |
| `$4014` | OAMDMA | 写触发 | 写入 OAM page |
| `$4015` | APU status | 读有副作用 | 清 frame/DMC 状态并可能影响 IRQ |
| `$4016-$4017` | 控制器/APU frame counter | 读有副作用 | 串行读键、strobe、frame mode |
| `$4018-$401F` | 禁用区 | 通常无设备 | 不能假设有 RAM |
| `$4020-$5FFF` | 未映射 | 通常 open bus | 读值依设备/总线状态 |
| `$6000-$7FFF` | PRG RAM 或工作 RAM 窗口 | mapper 决定 | 可用、禁用、保护状态各异 |
| `$8000-$FFFF` | PRG ROM 窗口 | mapper 决定 | 读为主，写通常无效或被 mapper 解释 |

### 3.1 RAM 镜像

硬件工作 RAM 是 2 KiB，因此：

```text
physical_ram = cpu_addr[10:0]
```

`$0000`、`$0800`、`$1000`、`$1800` 访问同一个物理字节。cNES 的 `system_lower_memory_read` 和 Obara 的 `mmu.c` 都显式做 `addr % 0x800` 或等价处理。

### 3.2 PPU 寄存器镜像

`$2000-$3FFF` 以 8 个寄存器为周期：

```text
register_index = cpu_addr[2:0]
$2002 → index 2
$2007 → index 7
$3FFA → index 2
```

注意：把地址折叠成索引只是译码第一步，PPU 内部还可能根据渲染状态、读缓冲、`w` 和 vblank 抑制改变副作用。

### 3.3 未映射地址

`[NESdev 真值]` 未映射区域的读值取决于总线浮空、上一次驱动和具体硬件连接；某些地址线可能影响结果。`[源码观察]` cNES 对未映射低地址读返回 `system_bus_read()`，写入直接忽略；Obara 的 `read_mem` 对未映射 IO 返回 `mem->bus`，ROM 区则交给 mapper。两者都是软件近似，不能把“返回上次总线值”泛化为所有硬件的精确 open-bus 规则。

## 4. 地址译码的分层

推荐把地址译码拆成四层：

```text
cpu_addr[15:0]
      │
      ▼
区域选择：RAM / PPU_IO / APU_IO / EXPANSION / PRG_RAM / PRG_ROM
      │
      ▼
设备选择：PPU register index、APU register index、mapper window
      │
      ▼
mapper bank 选择、mirroring、保护位
      │
      ▼
物理 RAM/ROM/CHR 或 open-bus 值
```

### 4.1 区域选择状态表

| `addr[15:13]` 或等价条件 | 区域 | 备注 |
|---|---|---|
| `000`–`001` | RAM | `$0000-$1FFF` |
| `010`–`011` | PPU IO | `$2000-$3FFF` |
| `100` | APU/IO/EXPANSION | 还要判断 `$4014/$4015/$4016/$4017` |
| `101` | 未映射或扩展区 | 具体设备另定 |
| `110` | PRG RAM 窗口 | mapper 决定 |
| `111` | PRG ROM 窗口 | mapper 决定 |

`[源码观察]` cNES 先让 mapper 的 `ram_read_func` 接收完整 16 位地址，再由 NROM/MMC1 等 mapper 决定是否转给 `system_lower_memory_*`。Obara 则在 `mmu.c` 先处理 RAM/IO，再把高地址交给 mapper。这个差异是软件层次差异，不是硬件地址图差异。

## 5. 总线周期与 CPU 指令周期

6502 的一个指令由多个总线周期组成。粗略分类：

| 类别 | 例子 | 典型访问 |
|---|---|---|
| 取指 | 每条指令开始 | 读 PC，PC 递增 |
| 操作数读取 | `LDA`, `ADC`, `JMP` | 读立即数、零页或绝对地址 |
| 写回 | `STA`, `STX`, `ASL` | 写目标地址 |
| 读改写 | `INC`, `ASL`, `ROR` | 读、可能 dummy 写、写回 |
| 栈操作 | `PHA`, `JSR`, `RTS` | dummy 读、push/pop |
| 分支 | `BNE`, `BCC` | 读偏移，可能有 dummy 取指 |
| 中断 | IRQ/NMI/RESET | dummy 读、push、读向量 |

### 5.1 dummy read

dummy read 的数据可能被丢弃，但访问本身会：

- 让外部设备看到地址和 R/W；
- 改变 open-bus 或 mapper 监视到的总线；
- 占用 CPU 周期；
- 在某些 PPU/APU 寄存器上产生副作用。

因此“结果没用到”不代表“可以从波形删除”。

### 5.2 dummy write

读改写指令可能先把旧值写回，再写新值；某些 6502 兼容行为对 I/O 设备可见。这个 dummy write 对 NES 的 PPU/APU 很重要，不能只实现最终写。

## 6. OAM DMA 的总线仲裁

### 6.1 基本过程

CPU 写 `$4014` 后，PPU OAM DMA 读取一页 256 字节：

```text
CPU cycle       0       1       2       3       4       5 ...
DMA phase      dummy   align   read    write   read    write
CPU bus        idle    idle    source  $2004  source  $2004
```

实际相位根据 CPU/APU 周期奇偶可能多一个对齐周期。总数据是 256 次读和 256 次写，另加 dummy/对齐，因此常见总长度为 513 或 514 个 CPU 周期。

### 6.2 状态表

| 状态 | 地址来源 | 数据方向 | 目的 |
|---|---|---|---|
| `IDLE` | 无 | 无 | 等待 `$4014` |
| `DUMMY` | CPU 当前 PC 或实现规定的地址 | 读 | 对齐/填充总线 |
| `ALIGN` | 视实现而定 | 读或等待 | 等待合适奇偶相位 |
| `READ` | `page<<8 + index` | 读 | 取 OAM 源字节 |
| `WRITE` | `$2004` | 写 | 把字节写入 OAM |
| `FINISH` | 无 | 无 | 恢复 CPU 所有权 |

### 6.3 cNES 源码观察

cNES `system.c` 的 `_handle_dma()`：

- `g_dma_step == 0` 做一次 dummy read；
- step 1 进行奇偶判断，必要时直接推进；
- 奇数 step 写 `g_bus_val` 到 PPU，偶数 step 从 `page<<8 | index` 读；
- `g_dma_step > 514` 后结束。

这是一套清晰的软件状态机，但 dummy 地址取 `g_ppu_internal_regs->s`，且对齐与 `g_total_cpu_cycles` 奇偶相关；这些是 cNES 的具体选择，不能自动当作所有硬件/NESdev 测试的唯一时序。

### 6.4 Obara 源码观察

Obara 在 `cpu6502.h` 定义 `DMA_Phase`：`DMA_CLEAR`、`DMA_HALTING`、`DMA_DUMMY`、`DMA_ALIGNING`、`DMA_READ`、`DMA_WRITE`，并把 OAM/DMC 都放进 CPU 结构。`tick_dma()` 对 APU 区域和控制器区域做总线冲突处理，说明它把 DMA 看成 CPU 总线事务，而不是 PPU 内部数组复制。

### 6.5 NESdev 真值

OAM DMA 的关键可观察点是：

- CPU 在 DMA 期间不执行自己的指令；
- 总线上存在规定的读/写/对齐时序；
- `$2004` 写入的顺序与 OAM 地址回绕有关；
- PPU 和 APU 的内部计时继续运行；
- DMA 对某些 I/O 地址和 open bus 的访问可能产生副作用。

### 6.6 RTL 映射

```text
cpu_bus_master
├── cpu_request
├── dma_request
├── selected_device
├── data_return
└── owner_return
```

DMA FSM 产生 `dma_read` 和 `dma_write`，总线仲裁器暂时禁止 CPU 普通请求。PPU 仍由自己的 dot clock 运行；不要用“停止整个 `clk`”实现 DMA。

## 7. DMC DMA 与 CPU 总线

DMC 是 APU 向 CPU 空间取一个样本字节的机制。它和 OAM DMA 的不同点：

| 项目 | OAM DMA | DMC DMA |
|---|---|---|
| 触发 | CPU 写 `$4014` | APU 样本缓冲为空且 DMC ready |
| 传输长度 | 256 字节 | 一个样本字节 |
| 目标 | PPU OAM | APU DMC sample register |
| CPU | 停止正常执行并让出总线 | 取样期间占用/延迟 CPU 总线 |
| 结束 | 256 次写入完成 | 字节交给 APU，通常没有对应 CPU 写周期 |
| IRQ | OAM DMA 本身不产生 IRQ | DMC IRQ 可由控制位启用 |

`[NESdev 真值]` DMC DMA 造成的 CPU 延迟和总线访问细节是许多游戏时序测试关注的边界；不能用“一次性从数组读取”完全替代。

`[源码观察]` Obara `cpu6502.c` 中 `DMA_DMC` 的 `DMA_READ` 完成后直接把一个字节交给 `dmc_complete()`，并继续推进 master clock；这是很有价值的总线状态机观察，但 OAM/DMC 的具体 phase 延迟仍需与测试 ROM 对照。

## 8. IRQ、NMI、RESET 的总线/控制线

```text
PPU vblank ──> NMI line ──┐
APU frame  ──> IRQ line ──┼──> CPU interrupt poll
DMC IRQ    ──> IRQ line ──┤
mapper IRQ ──> IRQ line ──┘
reset      ────────────────> CPU reset sequence
```

| 信号 | 触发方式 | CPU 是否可屏蔽 | 典型向量 |
|---|---|---|---|
| NMI | 下降/上升沿事件，取决于线路实现 | 否 | `$FFFA` |
| IRQ | 电平请求 | 是，受 `I` 标志影响 | `$FFFE` |
| RESET | 复位线路 | 否，另走 reset 序列 | `$FFFC` |
| BRK | 软件指令 | 不是外部 IRQ | `$FFFE`，B 行为不同 |

cNES 的 CPU 通过 `poll_nmi_line`、`poll_irq_line` 和 `poll_rst_line` 读取回调；Obara 在 CPU 结构中保存 `NMI_line`、`interrupt` 和 `polled_interrupt`。两种实现都可作为接口学习材料，但 NMI 边沿、IRQ 保持和清除时序应由硬件真值验证。

## 9. 一次总线的 trace 格式

建议每个 CPU 访问记录：

```text
cycle, pc, addr, rw, wdata, rdata, owner, ready, ppu_dot, dma_phase
```

示例：

```text
cycle  ppu_dot  pc    addr    rw  data  owner  note
  12      36   8000  8000    R   A9    CPU    opcode
  13      39   8001  8001    R   01    CPU    immediate
  14      42   8002  0010    W   01    CPU    STA zero page
```

至少同时记录 `pc`、地址和 owner。只记录最终 PC 无法判断是取指、dummy read 还是数据读。

## 10. 实验：证明地址译码正确

### 实验 A：RAM 镜像

CPU 依次写：

```text
LDA #$5A
STA $0010
LDA $0810
```

预期第二次读到 `$5A`。trace 中应有两个不同 CPU 地址，但物理 RAM offset 都是 `$010`。

### 实验 B：PPU 寄存器镜像

向 `$2000` 和 `$3000` 写不同值，读取 `$2000/$3000` 或观察控制寄存器效果。验证 `addr[2:0]` 折叠；同时检查读副作用是否只在真实寄存器上发生。

### 实验 C：open bus

在没有设备驱动的地址读 `$4020`，先让总线保持一个已知值，再改变地址。分别用“固定零”“地址低字节”“保持上次值”三种模型运行，记录哪个游戏测试能够区分它们。

### 实验 D：DMA 对齐

在 CPU 奇偶周期不同的位置写 `$4014`，记录：

```text
start_cycle
dummy_read
first_read
first_write
finish_cycle
```

与 513/514 周期和 PPU/APU 继续运行的 trace 对照。

## 11. 常见误区

- 只实现地址范围，不实现 PPU/APU 的读副作用和 dummy access。
- 把 RAM 镜像误做成 8 KiB 或 32 KiB。
- 把 `$4014` 当普通寄存器写完就立即复制 256 字节。
- DMA 期间停止 PPU 时钟。
- 只实现 CPU 地址译码，忘记 PPU A12 和 mapper tick。
- 把 CPU 的 `mem_read` 和 6502 内部 `bus_read` 当成完全相同的接口。
- 用组合逻辑直接把总线值送到 RAM，忽略同步 RAM 延迟。
- 只记录读数据，不记录无效地址的 R/W 和周期。
- 把 IRQ 来源合并成一个电平，却不处理清除和重新置位。

## 12. 后续 RTL 映射

### 12.1 总线模块

```text
nes_cpu_bus_decode
  inputs:  cpu_addr, cpu_rw, cpu_wdata, dma_* , ppu_mirror_request
  outputs: ram_cs, ram_addr, ppu_io_cs, ppu_reg_index,
           apu_io_cs, prg_ram_cs, prg_rom_cs, open_bus_value
```

### 12.2 仲裁状态表

| owner | 触发 | 持有时间 | 结束条件 |
|---|---|---|---|
| CPU | CPU request 且无 DMA | 一个或多个 CPU cycle | ready |
| OAM DMA | `$4014` 写入 | dummy + align + 256 read/write pairs | transfer complete |
| DMC DMA | APU sample request | 取样规定周期 | byte delivered |
| PPU internal | PPU fetch | PPU pipeline latency | fetch complete |

仲裁器应给 PPU 内部路径和 DMA 明确优先级；不要用一个隐含的 C 回调顺序表达优先级。

### 12.3 最小 RTL 验证顺序

1. RAM 和 open bus。
2. PPU 寄存器地址折叠。
3. NROM PRG 读。
4. 6502 取指和数据访问。
5. OAM DMA。
6. IRQ/NMI/RESET。
7. mapper bank 和 PPU A12。

每一步都保留总线 trace；等画面出现后再调 PPU，通常比一开始同时调 CPU、PPU、APU 更容易定位问题。
