# 09 从 C 模拟器到 RTL 的映射方法

## 1. 映射目标

本章不把 C 代码逐行翻译成 Verilog，而是把可观察行为拆成适合硬件实现的对象：

```text
C 全局/结构体状态  → 寄存器、数组、配置 RAM
C 函数            → 组合逻辑或时序状态机
C 回调            → 端口、接口或事件总线
C while/for        → 计数器、状态转移或有限循环展开
C malloc/指针      → 固定地址存储体、bank pointer、配置阶段资源
C 函数调用顺序    → 明确的同周期优先级和握手
```

C 模拟器通常把一个硬件周期的多个副作用放在一个函数中；RTL 需要把它们分成可观察的微状态。目标不是“代码看起来像 C”，而是“波形、寄存器值和总线时序能解释”。

## 2. 四种实现级别

| 级别 | 目标 | 适合的模块 | 代价 |
|---|---|---|---|
| F：功能 | 最终寄存器/像素/声音正确 | 早期 CPU、简单 PPU 显示 | 不解释 dummy、边沿和竞争 |
| T：事务 | 每次读写、ready、寄存器副作用可追踪 | CPU bus、DMA、mapper | 仍可能不精确到每个内部 dot |
| C：周期 | 指令周期、PPU dot、APU clock 顺序可比较 | 6502、PPU、APU | 状态和验证复杂 |
| E：电气/模拟 | 模拟 open bus、上升沿、模拟滤波 | 特殊兼容层 | 不适合作为第一阶段目标 |

建议先达到 T，再逐步达到 C。不要一开始就追求所有 analog 行为，否则很难知道错误来自算法、时序还是物理模型。

## 3. C 状态到 RTL 对象的映射

| C 写法 | 典型对象 | RTL 形式 | 例子 |
|---|---|---|---|
| `static uint8_t x` | 单个状态位/字节 | `reg [7:0]` | `g_dma_in_progress` |
| `struct { ... }` | 相关寄存器组 | 一个模块端口组 | `PpuInternalRegisters` |
| `uint8_t ram[2048]` | 同步 RAM | `reg [7:0] ram [0:2047]` | 工作 RAM |
| `uint8_t *rom` | ROM/配置存储 | ROM 接口或 bank offset | PRG/CHR |
| `bool` | 状态位 | 1-bit reg | rendering enabled |
| `enum state` | 状态机 | `state` reg + `case` | PPU dot phase |
| `switch` | 译码/ALU | combinational mux | MMIO write |
| `if` | condition | comparator/mux | `$4014` DMA trigger |
| `for`/`while` | 多周期过程 | counter/FSM | DMA 256 bytes |
| callback | 外部接口 | module port | CPU bus read/write |
| pointer arithmetic | 地址计算 | adder/concat | bank offset |
| `memcpy` | 批量状态搬运 | DMA FSM | OAM DMA |
| `assert` | 设计约束 | assertion/状态编码 | address range |
| floating mixer | 数字近似或外部处理 | LUT/fixed point | APU output |

## 4. 建议的顶层分层

```text
nes_system_top
├── nes_clock_reset
├── nes_cpu
├── nes_cpu_bus
├── nes_work_ram
├── nes_ppu
├── nes_ppu_bus
├── nes_apu
├── nes_dma_arbiter
├── nes_mapper
├── nes_input
├── video_adapter
└── audio_adapter
```

### 4.1 顶层只做编排

顶层负责：

- reset 和时钟门控；
- 实例化各模块；
- 连接总线和中断线；
- 选择 ROM/CHR/RAM；
- 把 frame/sample ready 交给平台适配器。

顶层不要包含完整 PPU 取数公式、6502 ALU 或 MMC1 serial 状态，否则仿真波形会难以定位。

### 4.2 端口示例

CPU：

```text
cpu_addr[15:0]
cpu_rw
cpu_wdata[7:0]
cpu_rdata[7:0]
cpu_req
cpu_ready
nmi
irq
reset
```

PPU：

```text
ppu_dot
ppu_cpu_addr[2:0]
ppu_cpu_rw
ppu_cpu_wdata[7:0]
ppu_cpu_rdata[7:0]
ppu_vram_addr[13:0]
ppu_vram_rdata[7:0]
nmi
frame_ready
pixel_x[7:0]
pixel_y[7:0]
pixel_rgb
```

这些是概念端口，实际项目可根据平台总线和时序约束调整。

## 5. 状态机的映射

### 5.1 C 状态机和 RTL 状态机

一个 C 结构：

```text
state = {
  current,
  counter,
  operand,
  latch,
  flags
}
```

通常映射为：

```text
state       当前 FSM 状态
counter     当前周期/索引计数
operand     操作数寄存器
latch       外部设备或 PPU 返回值
flags       条件和控制位
```

### 5.2 转移表达

C 中的嵌套逻辑：

```text
if state == A:
    if counter == 0:
        state = B
    else:
        counter--
else if state == B:
    ...
```

可以映射成：

```text
always_ff:
  case (state)
    A: begin
        if (counter == 0) state <= B;
        else counter <= counter - 1;
      end
    B: ...
  endcase
```

### 5.3 同周期优先级

C 函数按源码顺序更新全局变量时，隐含了优先级。例如同一周期同时发生 PPU vblank、NMI enable 和 status read，RTL 必须写出明确规则：

```text
status_read_clear > vblank_set > nmi_line_update
```

还是：

```text
vblank_set > status_read_clear > nmi_line_update
```

不同选择会改变测试结果。不要让工具自动推断“非阻塞赋值的覆盖顺序”。

### 5.4 阻塞式 C 不是硬件阻塞

C 中：

```text
while (ready == 0) {
    tick_other_module();
}
```

在 RTL 中不能写一个会锁死时钟的 `while`。应改为：

```text
WAIT:
  if (ready) state <= NEXT;
  else begin
      tick_other_module();
      state <= WAIT;
  end
```

或者用独立的 `ready` enable，让其他模块继续运行。

## 6. 存储器和数组

### 6.1 工作 RAM

cNES `g_system_ram[0x800]`、Obara `Memory.RAM[0x800]` 都可直接推断为 2 KiB RAM。RTL 建议：

```text
read_addr  = cpu_addr[10:0]
write_en   = ram_write
read_data  = ram[read_addr]
```

同步 RAM 的读延迟必须进入 CPU bus ready 或 pipeline 状态。不要用阻塞式读表达式把一拍延迟隐藏掉。

### 6.2 PRG ROM

FPGA 上 ROM 有几种来源：

1. 仿真文件 `$readmemh`/文件数组；
2. 配置阶段从 SPI Flash 读入；
3. 外部 SDRAM；
4. 板级固定 mask ROM。

mapper 不应依赖 C 指针的地址相等，而应输出：

```text
prg_bank_number
prg_offset
prg_read_enable
```

ROM 接口根据 offset 返回数据。这样可以替换存储来源而不改 mapper。

### 6.3 CHR ROM/RAM

CHR 可能需要 PPU 内部高频读取和 CPU `$2007` 写入：

```text
CHR ROM：只读，多 bank
CHR RAM：可写，可能单端口或双端口
```

如果 CHR RAM 使用单端口，仲裁必须定义：

- PPU background fetch 优先级；
- sprite fetch 优先级；
- CPU `$2007` 写入何时完成；
- mapper bank 改变时正在进行的 fetch 是否继续。

### 6.4 OAM

OAM 256×8 可用 RAM，但 PPU 读取、CPU `$2004` 访问和 OAM DMA 写入可能冲突。最小实现可以：

- OAM DMA 直接在 CPU 侧写入 OAM RAM；
- PPU 读取采用同步 RAM；
- 用 owner/ready 表示冲突。

更高精度实现要模拟渲染期间 OAM 访问的特殊行为，而不是只加一个 mutex。

### 6.5 固定数组与动态指针

Obara 的 `PRG_ptrs[8]`、`CHR_ptrs[8]` 是 C 指针数组。RTL 不需要存真实地址，可以存 bank number：

```text
prg_bank_ptr[0..7] : integer bank index
chr_bank_ptr[0..7] : integer bank index
```

需要 mirror、wrap 或非法 bank 时，在译码器中处理。

## 7. 算术和位域

### 7.1 C bit-field 的风险

`PpuControl`、`VramAddr`、`StatusRegister` 依赖编译器 bit-field 布局。RTL 不应依赖 C union 的内存布局；应显式写位提取：

```text
ppu_ctrl_nt       = value[1:0]
ppu_ctrl_increment = value[2]
ppu_status_vblank  = value[7]
cpu_status_n       = value[7]
```

### 7.2 PPU `v` 位操作

C 中的：

```text
v.addr += 1
v.addr ^= 0x0400
```

在 RTL 中应是带条件的 15 位运算：

```text
if (coarse_x == 5'd31)
    coarse_x <= 0;
    nt_horizontal <= ~nt_horizontal;
else
    coarse_x <= coarse_x + 1;
```

不要用一个 16 位加法后靠仿真偶然得到正确 nametable 翻转。

### 7.3 ADC/SBC

6502 ALU 建议使用足够宽的中间值：

```text
sum9 = {1'b0, a} + {1'b0, m} + carry
result = sum9[7:0]
carry_out = sum9[8]
overflow = (~(a ^ m) & (a ^ result))[7]
```

SBC 可用 `a + ~m + carry` 或等价减法实现，但 overflow、carry 和 zero 的定义要与 6502 行为一致。

### 7.4 乘法

C 里的 `tile_index * 16`、bank number 乘以粒度在 RTL 中可以由移位拼接实现：

```text
tile_offset = tile_index << 4
bank_offset = bank_number << 14
```

如果 mapper 支持非 2 的幂 bank，使用 clamp mask 或明确的 modulo 组合逻辑，不要依赖 C 整数溢出。

## 8. 回调和接口

### 8.1 C 回调的优点

cNES 的 `CpuSystemInterface` 使 CPU 不知道 RAM、ROM 和 PPU 的具体实现；mapper 函数表使 NROM/MMC1/MMC3 可以替换。RTL 中对应的是模块端口和参数化接口。

### 8.2 不要用函数指针仿真

Verilog/ SystemVerilog 中不应为每个 mapper 生成动态函数指针。可以使用：

```text
mapper_id
case (mapper_id)
  NROM: ...
  UxROM: ...
  MMC1: ...
endcase
```

或者将 mapper 做成统一 shell 加参数寄存器：

```text
bank_mode
bank_select
serial_shift
irq_enable
```

### 8.3 事件替代阻塞调用

C 中：

```text
mapper->tick_func()
```

在 RTL 中更自然地表示为：

```text
on ppu_dot_edge:
    observe_ppu_address()
    maybe_clock_mapper_irq()
```

这使 PPU 取数、mapper A12 和 CPU 执行之间的顺序显式化。

## 9. 时钟、复位和多时钟域

### 9.1 首选单主时钟 + clock enable

如果 FPGA 资源允许，推荐：

```text
一个 clk
  ├── cpu_ce
  ├── ppu_ce
  ├── apu_ce
  └── mapper_ce
```

这样 reset、总线和 trace 更容易对齐。分频只控制哪些模块在某个边沿更新。

### 9.2 独立时钟域

如果 SDRAM、音频或视频使用独立时钟，需要处理：

- 复位同步；
- CDC handshake；
- FIFO 满/空；
- 读写指针格雷码或握手；
- 丢样和过采样策略；
- 仿真中的跨域可见性。

不要直接把两个时钟域的寄存器用组合逻辑相连。

### 9.3 reset 层次

建议区分：

```text
global_reset       复位所有核心
system_reset       重新启动模拟，但不覆盖配置 ROM
ppu_frame_reset    可选的帧级状态清理
dma_abort          中止当前传输
```

把每帧都当作 global reset 会丢失 RAM/OAM/游戏状态；把所有状态只在上电初始化又可能无法恢复 mapper 或 NMI 抑制。

## 10. 文件加载和仿真启动

### 10.1 仿真平台

```text
initial/config phase:
  read ROM header
  validate sizes
  load PRG/CHR
  set mapper parameters

reset phase:
  initialize CPU/PPU/APU/mapper
  wait for CPU reset vector

run phase:
  one master tick
  CPU/PPU/APU/DMA events
  optional trace
```

文件解析不应在每个 CPU 周期执行。把它放在配置阶段可以减少综合路径和仿真不确定性。

### 10.2 参数文件

可以由测试平台生成一个只读配置结构：

```text
mapper_id
submapper
prg_size
chr_size
prg_ram_size
chr_ram_size
mirroring
timing
```

RTL 核心只接收参数和 ROM 接口，不依赖主机文件系统。

## 11. 从 cNES 函数到 RTL 单元的示例映射

| cNES 源码 | 软件作用 | RTL 单元 |
|---|---|---|
| `initialize_system` | 分配和连接所有部件 | reset/parameter init FSM |
| `system_memory_read` | CPU 地址到 mapper | address decoder |
| `system_memory_write` | CPU 写和 DMA 总线 | bus write arbiter |
| `cycle_cpu` | 6502 一个 CPU cycle | CPU FSM |
| `cycle_ppu` | PPU 一个 dot | PPU dot FSM |
| `g_dma_step` | OAM DMA 相位 | DMA phase register/counter |
| `ppu_read_mmio` | PPU 寄存器读副作用 | PPU register read logic |
| `ppu_write_mmio` | PPU 寄存器写 | PPU register write decoder |
| `_do_tile_fetching` | 背景八相位 | background fetch FSM |
| `_do_sprite_evaluation` | OAM 评估 | sprite evaluator FSM |
| `mapper->tick_func` | PPU 地址观察 | A12 filter/IRQ counter |
| `set_pixel` | 软件帧缓冲 | pixel valid/ready port |
| `controller_poll` | 串行输入 | controller shift register |

## 12. 逐周期与逐事务的取舍

### 12.1 CPU

第一版可以每个 CPU cycle 完成一个总线事务；若有同步 RAM，则在 `MEM_WAIT` 状态插入等待。这样仍能追踪 PC、地址和 dummy access。

### 12.2 PPU

PPU 不能简单每个 CPU cycle 只做一件事。NTSC 下每个 CPU 周期约有三个 PPU dot，因此 PPU 内部 FSM 要能在一个 CPU 周期内推进多个 dot，或直接以 PPU dot clock 运行并由 CPU bus 通过 ready 交互。

### 12.3 APU

APU 可以每 CPU cycle 更新通道计数器，再按固定采样间隔抽取混音值。若目标是功能音频，简化 mixer 可接受；若目标是兼容测试，保留 frame/DMC 事件顺序。

### 12.4 Mapper

mapper 写入通常在 CPU 周期更新；MMC3 IRQ 需要每个 PPU dot 观察地址。把两者放在不同模块时，要定义同周期写入和地址变化的优先级。

## 13. 断言和调试端口

建议从第一版就保留：

```text
cpu_pc, cpu_a, cpu_x, cpu_y, cpu_sp, cpu_status
cpu_addr, cpu_rw, cpu_wdata, cpu_rdata, cpu_owner
ppu_scanline, ppu_dot, ppu_v, ppu_t, ppu_x, ppu_w
ppu_addr_bus, oam_dma_phase, oam_dma_index
mapper_bank, mapper_irq_counter, mapper_irq_line
apu_status, dmc_state, dmc_bytes_remaining
```

可以用 SystemVerilog assertion 检查：

- reset 后 N 个周期内 PC 不越界；
- RAM 物理地址小于 2048；
- OAM DMA index 不超过 255；
- vector read 先低字节后高字节；
- PPU visible pixel 的 x/y 在范围内；
- mapper IRQ line 与 enable/counter 状态一致。

断言不是替代 trace；它负责在长时间仿真中快速发现不变量被破坏。

## 14. 常见误区

- 把 C 的 `uint8_t` 当成天然的无符号物理信号，不检查位宽和截断。
- 把 `while` 直接翻译成 RTL `while`。
- 把全局变量分组当成模块边界，却没有定义谁在何时更新。
- 把同步 RAM 的读延迟隐藏在 testbench 或仿真模型里。
- 用一个大组合 case 同时实现 CPU、PPU 和 APU，造成不可综合路径。
- 让 CPU、PPU、APU 各自使用独立 reset，却没有统一 reset 顺序。
- 把 mapper bank pointer 存成真实指针，导致综合和跨域复杂化。
- 为了画面正确而让 PPU 读取永远返回零。
- 为了声音正确而让 DMC 不产生 CPU 总线延迟。
- 把 callback 当作“以后再接”的接口，延迟到总线契约已经改变。

## 15. 分阶段实施路线

### 阶段 1：最小 CPU 系统

```text
reset → vector → RAM/ROM → LDA/STA/JMP → trace
```

验收重点：地址、数据、PC、周期和 reset。

### 阶段 2：NROM + PPU 状态

```text
$2000-$2007 寄存器 → vblank/NMI → nametable/CHR 读取
```

先不追求完整画面，确认 PPU dot 和 CPU 访问可以同时运行。

### 阶段 3：背景渲染和滚动

```text
八相位 fetch → palette → pixel → v/t/x/w
```

加入水平复制、垂直复制、left clipping。

### 阶段 4：精灵和 DMA

```text
OAM DMA → secondary OAM → sprite fetch → priority/sprite0
```

将 DMA 总线和 PPU 取数冲突加入 trace。

### 阶段 5：IRQ 和 mapper

```text
MMC1/MMC3 bank → A12 → IRQ → CPU vector
```

验证 CPU 读取向量、ack 和 reload 的顺序。

### 阶段 6：APU

```text
寄存器 → 五通道 → frame sequencer → mixer → FIFO
```

最后加入 DMC DMA 和精确中断边界。

## 16. 第一个 RTL 单元实验

实现一个只读的 CPU bus trace 单元，不接 PPU 图像：

```text
reset
  ↓
读 $FFFC/$FFFD
  ↓
读 $8000 opcode
  ↓
读操作数
  ↓
更新 PC/状态
```

同时导出一帧文本：

```text
cycle, pc, addr, rw, data, state
```

用 `LDA #$01`、`STA $10`、`JMP $8000` 组成最小程序。只要这段 trace 与 6502 预期一致，后续 PPU/APU 才有稳定的 CPU 基础。
