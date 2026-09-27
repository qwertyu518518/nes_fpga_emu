# 02 cNES 的模块关系与启动流程

## 1. 目的和边界

本章不是把 cNES 逐行翻译，而是从实际接口出发回答三个问题：

1. 一个 ROM 文件如何进入 `Cartridge` 对象？
2. `initialize_system()` 初始化了哪些硬件，谁向谁提供回调？
3. `do_system_loop()` 如何让 CPU、PPU 和 mapper 在同一个时间轴上运行？

源码观察固定在：

```text
.slim/clonedeps/repos/caseif__cNES
commit 7c8c252d74008e9a73a79ae18475d316d4f63290
```

本章提到的“cNES 没有 APU”是对该提交 `src/system.c` 中 MMIO TODO 分支的观察，不代表 NES 硬件没有 APU。

## 2. 顶层文件和接口地图

| 文件/头文件 | 对外接口 | 责任 |
|---|---|---|
| `src/main.c` | `main()`、系统线程入口 | 参数、ROM 文件、窗口、线程、退出 |
| `include/loader.h` / `src/loader.c` | `load_rom(FILE*, char*)` | 解析头、分配 PRG/CHR、创建 mapper |
| `include/cartridge.h` | `Cartridge` | ROM、CHR、RAM、mirroring、timing、mapper 元数据 |
| `include/system.h` / `src/system.c` | `initialize_system`、`system_memory_*`、`do_system_loop` | 主机、时钟、CPU/PPU 接口、DMA |
| `include/c6502/cpu.h` | `initialize_cpu`、`cycle_cpu`、`CpuSystemInterface` | 6502 核心和外部回调 |
| `include/ppu.h` / `src/ppu.c` | `initialize_ppu`、`cycle_ppu`、PPU MMIO | PPU 状态、nametable、渲染和 NMI |
| `include/renderer.h` / `src/renderer.c` | `set_pixel`、`submit_frame` | SDL frame buffer |
| `include/mappers/mappers.h` / `src/mappers/*.c` | `Mapper` 函数表 | CPU RAM 窗口和 PPU VRAM 窗口 |
| `include/input/*.h` | `controller_poll`、`controller_push` | 标准控制器抽象 |

### 2.1 `Cartridge` 不是硬件本身

`Cartridge` 结构把文件内容和板级配置集中在一起：

```text
Cartridge
├── title
├── prg_rom / prg_size
├── chr_rom / chr_size
├── mirror_mode
├── has_nv_ram / four_screen_mode
├── prg_ram / prg_nvram / chr_ram / chr_nvram
├── timing_mode
└── mapper
```

`[源码观察]` 这些字段由 `loader.c` 填入，之后 mapper 的 CPU 和 PPU 读写函数通过 `Cartridge *cart` 访问它们。`[NESdev 真值]` 卡带上的 PRG/CHR、mapper 状态和 nametable 布线由板级硬件决定，文件头只是描述它们的格式，不等于真实卡带电气实现。`[RTL 建议]` 顶层可以把 ROM 元数据和 mapper 状态拆开，避免把文件解析状态误当成运行时硬件状态。

## 3. 启动流程：从命令行到第一条指令

### 3.1 实际调用图

```text
main(argc, argv)
  ├─ 校验参数并打开 ROM
  ├─ load_rom(rom_file, base_name)
  │    ├─ 读取 16 字节 header
  │    ├─ 解析 mapper_id、timing、RAM 大小
  │    ├─ _create_mapper()
  │    ├─ 分配并读取 PRG/CHR
  │    └─ mapper->init_func(cart)
  ├─ initialize_window()
  ├─ initialize_renderer()
  ├─ initialize_system(cart)
  │    ├─ 选择 NTSC/PAL/Dendy 时钟
  │    ├─ 分配 PRG RAM/CHR RAM
  │    ├─ initialize_cpu(CpuSystemInterface)
  │    ├─ initialize_ppu()
  │    ├─ ppu_set_mirroring_mode()
  │    └─ _init_controllers()
  ├─ 创建系统线程
  └─ do_window_loop()
       └─ 后台线程 do_system_loop()
```

### 3.2 时序图

```text
main 线程                         system 线程
  │                                   │
  ├─ load_rom                         │
  │    └─ mapper 初始化                │
  ├─ initialize_system                 │
  │    ├─ CPU 接口注册                 │
  │    ├─ PPU/NMI 回调注册              │
  │    └─ reset 初始周期                │
  ├─ create thread ───────────────────►│
  │                                    ├─ do_system_loop
  │                                    │    ├─ PPU tick
  │                                    │    ├─ CPU/DMA tick
  │                                    │    └─ mapper tick
  ├─ SDL event/render loop             │
```

`[源码观察]` `initialize_system()` 在 `initialize_cpu()` 之后调用 `initialize_ppu()`；PPU 初始化时通过 `system_connect_nmi_line(_ppu_nmi_connection)` 注册 NMI 线回调。CPU 的 reset 不是一个单独的启动文件，而是 `initialize_cpu()` 将 `INT_RST` 放入队列后连续调用 7 次 `cycle_cpu()`。

### 3.3 启动顺序的硬件含义

`[NESdev 真值]` NES 商用卡带通常没有独立 boot ROM。复位后 CPU 从 `$FFFC/$FFFD` 取向量，因此向量所在的 PRG bank 必须由 mapper 初始状态正确映射。PPU、APU 的上电初值和 CPU 复位初值要按具体器件行为验证，不能简单认为所有寄存器都是零。

`[RTL 建议]` reset 应分成“全局复位”和“卡带可见性建立”。在向量读取有效前，mapper 的 PRG bank、mirroring 和 RAM 状态必须已经稳定；不要让未初始化的 mapper 指针参与向量读取。

## 4. `initialize_system()` 的状态建立

### 4.1 时钟状态

`system.c` 的全局变量把以下量作为主机状态：

| 状态 | 作用 |
|---|---|
| `g_tv_system` | NTSC、PAL 或 Dendy |
| `g_master_clock_speed` | 节流和统计使用的主时钟频率 |
| `g_cpu_clock_divider` | 何时调用 `cycle_cpu` |
| `g_ppu_clock_divider` | 何时调用 `cycle_ppu` |
| `g_cycle_index` | 在一个 CPU×PPU 分频周期中的位置 |
| `g_total_cpu_cycles` | DMA 对齐和日志使用的累计周期 |
| `g_bus_val` | 软件层的 open-bus/数据总线保持值 |

`[源码观察]` `g_cycle_index` 达到 `g_cpu_clock_divider * g_ppu_clock_divider` 时归零。PPU 先于 CPU 执行，CPU 之后执行，若有 mapper `tick_func` 再调用它。这个顺序是 cNES 的实现选择。

`[NESdev 真值]` 同一主时钟边沿上的边沿先后、复位相位和不同制式的分频关系必须由目标行为定义。对 PPU 地址 A12 敏感的 mapper 来说，PPU tick 和 mapper tick 的先后可能改变 IRQ 计数。

### 4.2 CPU 接口绑定

cNES 构造如下接口：

```text
mem_read       = system_memory_read
mem_write      = system_memory_write
bus_read       = system_bus_read
bus_write      = system_bus_write
poll_nmi_line  = system_read_nmi_line
poll_irq_line  = system_read_irq_line
poll_rst_line  = system_read_rst_line
```

这组接口揭示了 c6502 的内部假设：指令的数据值可以在 `bus_read`/`bus_write` 抽象中暂存，而带地址的内存访问通过 `mem_read`/`mem_write` 完成。详见 `05-6502.md`。

### 4.3 PPU 状态

`initialize_ppu()` 根据 `system_get_tv_system()` 选择 scanline 数量和 vblank 起点，初始化 `g_ppu_control`、`g_ppu_mask`、nametable、palette、OAM，并清零扫描线位置。`ppu_set_mirroring_mode()` 只设置镜像枚举；真正的地址翻译在 PPU 访问 nametable 时完成。

### 4.4 DMA 初始状态

`g_dma_in_progress` 初始为假，`g_dma_page` 被设为 `$FF`，但真正 DMA 只有写 `$4014` 后才置位。`_handle_dma()` 使用 `g_dma_step` 从 0 到 514，按奇偶步骤执行 dummy/read/write。

## 5. `do_system_loop()` 的一轮

### 5.1 源码观察顺序

```text
如果未 halt：
  tick_ppu = cycle_index % ppu_divider == 0
  tick_cpu = cycle_index % cpu_divider == 0

  若 tick_ppu：
    cycle_ppu()
    若 rst_cycles > 0：rst_cycles--

  若 tick_cpu：
    若 DMA：_handle_dma()
    否则：cycle_cpu()
    total_cpu_cycles++

  若 tick_ppu 且 mapper 有 tick_func：mapper_tick()

  cycle_index++
  若达到乘积：归零
```

### 5.2 状态表

| 条件 | CPU 行为 | PPU 行为 | mapper 行为 |
|---|---|---|---|
| 非 CPU tick、非 PPU tick | 等待 | 等待 | 等待 |
| CPU tick、非 DMA | `cycle_cpu` | 若同 tick 则先 `cycle_ppu` | PPU tick 时执行 |
| CPU tick、DMA 活跃 | `_handle_dma` | 独立继续 | 继续观察 PPU 地址 |
| PPU tick、非 CPU tick | 等待 | `cycle_ppu` | 可能执行 tick |
| halted | 全部等待 | 全部等待 | 全部等待 |
| stepping | 允许一轮后再次 halt | 已发生的 tick 不回滚 | 已发生的 tick 不回滚 |

### 5.3 时序图

```text
主循环 tick       t0    t1    t2    t3    t4    t5
PPU tick          P     .     .     P     .     .
CPU tick          C     .     .     C     .     .
mapper tick       M     .     .     M     .     .
实际执行          P→C→M .     .     P→C→M .     .
```

`[源码观察]` cNES 先执行 PPU，再执行 CPU，再执行 mapper tick。`[NESdev 真值]` 这不是“源代码调用顺序就是硬件事件顺序”的证明；尤其 mapper 依赖 PPU 地址变化时，应把边沿放到明确的 PPU dot 定义中。`[RTL 建议]` 为每个子模块定义同沿还是下一沿更新，并在 trace 中显式标出 `ppu_before_cpu` 或 `ppu_after_cpu` 的约定。

## 6. CPU 总线和 PPU 访问的两条路径

### 6.1 CPU 访问路径

```text
cycle_cpu
  → c6502 mem_read/mem_write(addr)
  → system_memory_read/write(addr)
  → mapper.ram_read_func/ram_write_func
  → system_lower_memory_* 或 PRG/PRG RAM
```

cNES 的 NROM `nrom_ram_read()` 将 `$0000`–`$7FFF` 转给 `system_lower_memory_read()`，将 `$8000`–`$FFFF` 映射到 `prg_rom`。MMC1、MMC3 等 mapper 在同一个入口里加入 `$6000`–`$7FFF` RAM 和寄存器逻辑。

### 6.2 PPU 访问路径

```text
cycle_ppu
  → ppu_name_table_read/write
      或 ppu 的内部取数函数
  → system_vram_read/write
  → mapper.vram_read_func/vram_write_func
  → CHR ROM/RAM 或 PPU 内部 nametable/palette
```

`[源码观察]` cNES 将 nametable 和 palette 的物理访问再回调给 `ppu_name_table_*` 和 `ppu_palette_table_*`，而 CHR 由 mapper 负责。`[NESdev 真值]` PPU 内部取数和 CPU 对 `$2007` 的访问可以共享某些 nametable 资源，但具体总线冲突、读缓冲和 palette 特殊行为不能用一个 C 数组读就完全表达。

### 6.3 两条路径的共享资源

```text
CPU $2007 ─────┐
               ├── nametable / palette / PPU internal bus
PPU fetches ───┘

CPU $8000 ─────┐
mapper IRQ ────┼── PRG window / A12 observation
PPU address ───┘
```

在 RTL 中要明确 `cpu_ppu_owner` 和 `ppu_fetch_owner` 是否能同时访问同一 RAM。如果 RAM 为单端口，需要仲裁；如果为双端口，要验证读写冲突和延迟是否改变硬件可观察行为。

## 7. cNES 的 renderer 路径

### 7.1 像素路径

`ppu.c` 在可见 dot 生成 `RGBValue`，调用 `system_emit_pixel(x,y,rgb)`；`system_emit_pixel()` 转到 renderer 的 `set_pixel()`。`cycle_ppu()` 在帧结束时调用 `system_submit_frame()`，renderer 将内部 256×240 buffer 转换到 SDL 纹理。

### 7.2 观察与真值

`[源码观察]` cNES 的 `g_pixel_buffer` 声明为 `[RESOLUTION_H][RESOLUTION_V]`，但 `set_pixel` 以 `x,y` 访问，显示路径通过裁剪顶部和底部若干行形成窗口。`[NESdev 真值]` 视频信号包含 256×240 可见区域、空白区和特定边缘像素时序；SDL 窗口的裁剪是显示适配，不是 PPU 行为。`[RTL 建议]` 平台视频适配器应位于 PPU 核心之外，核心只输出坐标、颜色和有效标志。

## 8. cNES 与 Obara 的组织差异

| 维度 | cNES | Obara Emmanuel NES |
|---|---|---|
| 顶层状态 | 多个 `static` 全局变量 | 一个 `Emulator` 结构体聚合 CPU/PPU/APU/Memory/Mapper |
| CPU 外部接口 | `CpuSystemInterface` 函数指针 | `Memory` 指针和 emulator 指针 |
| 总线 | `system_memory_*` 转发到 mapper | `read_mem`/`write_mem` 集中译码 |
| PPU | `ppu.c` 全局状态 + renderer 回调 | `PPU` 结构体 + `execute_ppu` |
| APU | MMIO TODO | `apu.c` 实现五个通道和采样器 |
| mapper | 函数表 `ram_read_func`、`vram_read_func` | `Mapper` 结构体函数指针、bank 指针和 extension |
| 主循环 | 主机线程按主时钟 tick | `tick_master_clock` + `execute` 循环 |
| 中断 | CPU 通过回调 poll NMI/IRQ/RESET | CPU 内部保存 NMI/IRQ 位并调用 `interrupt` |
| 视频输出 | SDL 双缓冲和事件循环 | `GraphicsContext` 和 frame render |

### 8.1 这张表的用途

它不是“哪一个更好”的排名，而是帮助学习者理解同一个硬件概念可以怎样组织：

- cNES 更接近“全局硬件寄存器 + 回调”的 C 风格。
- Obara 更接近“显式上下文对象 + 统一内存对象”的嵌入式 C 风格。
- 两者都把 PPU、CPU、APU 的硬件状态从局部变量中抽离出来。
- cNES 缺少 APU，Obara 的实现更完整，但其若干周期、滤波和重采样代码仍需与 NESdev 真值逐项比对。

## 9. 启动和循环中的异步边界

### 9.1 SDL 事件与模拟线程

cNES 的 `main()` 创建系统线程后，SDL 线程在 `do_window_loop()` 中处理窗口事件和显示。`system_emit_pixel()` 和 `system_submit_frame()` 会跨越线程边界，cNES 没有在接口中显示完整的锁或原子同步。

`[源码观察]` 这是桌面模拟器的实现取舍。`[NESdev 真值]` 真实硬件没有 SDL 事件线程，显示端是连续视频信号。`[RTL 建议]` 平台输入和视频输出使用双缓冲或握手机制，模拟核心不直接调用不可综合的图形 API。

### 9.2 控制器回调

`controller_poll()` 和 `controller_push()` 在 CPU 访问 `$4016/$4017` 时调用，输入设备状态由 SDL 驱动更新。`[源码观察]` cNES 将 `controller_push` 广播到两个端口。`[NESdev 真值]` 两个标准控制器端口的串行读回相互独立，strobe 和读时序由 $4016/$4017 规定。

## 10. cNES 启动实验

### 实验 1：只跟踪 reset

在 `initialize_system()` 前后输出：

```text
reset前：PC、SP、P、RAM[0x0000..0x0010]
reset后：PC、SP、P、CPU cycle
向量：FFFC、FFFD
```

预期可以看到 CPU 通过 `INT_RST` 进入 `$FFFC` 向量；具体 reset 周期数和寄存器初值要与 c6502 状态以及目标 NES 行为区分开。

### 实验 2：画调用图而不是只看结果

为一个 synthetic NROM 只实现：

```text
$FFFC = $80
$FFFD = $00
$8000 = A9 01
$8001 = 85 10
$8002 = 4C 00 80
```

记录 CPU 取指和 `system_memory_read` 的参数。观察 mapper 回调是否把 `$8000` 正确转成 PRG offset 0，并把写入 `$0010` 路由到 RAM。

### 实验 3：PPU 独立运行

暂时屏蔽 CPU 指令执行，只调用 `cycle_ppu()`。记录一帧内 scanline、dot、vblank 和 NMI callback 的调用次数。这个实验可以证明 PPU 不依赖 CPU 每条指令才推进。

### 实验 4：mapper tick

选择 MMC3，启用 IRQ latch，并让 PPU 取数改变 `addr_bus`。记录 `mapper_tick_func` 的调用时刻和 A12 变化。重点是区分 cNES 自己的 cooldown 过滤、Obara 的 mapper clock 变体和 NESdev 的 MMC3 行为。

## 11. 常见误区

- 把 `initialize_cpu()` 的 7 次 C 调用当成 NES 一定可见的 7 个精确硬件周期。
- 把全局 `g_cycle_index` 看成硬件寄存器；它只是 cNES 的调度器。
- 因为 `system_lower_memory_read` 对 APU 返回 0，就认为 APU 真值是读零。
- 只看 PPU 写入函数，不看 `cycle_ppu()` 中的取数和状态更新。
- 把 renderer 的 256×240 裁剪窗口当成 NES 的有效视频区域。
- 看到 mapper 函数表就认为所有 mapper 只需要两个读函数和一个写函数。
- 忽略 `mapper->init_func` 在 cartridge 加载后的额外副作用。

## 12. 后续 RTL 映射

建议把 cNES 的关系转换为以下接口，而不是照搬全局变量：

```text
nes_system_top
├── rom_loader_metadata
├── cpu_core
├── cpu_bus
├── ppu_core
├── ppu_bus
├── apu_core
├── dma_arbiter
├── mapper_core
├── work_ram
├── controller_port
└── video/audio_platform_adapter
```

`[RTL 建议]` 的 `nes_system_top` 负责 reset、制式和时钟；各核心只暴露状态和事务端口。`rom_loader_metadata` 在仿真开始时完成，运行时 mapper 只接收已解析的 bank/mirroring 参数。对应本章源码中的关系：

| cNES 源码 | RTL 对应 |
|---|---|
| `initialize_system` | reset/parameter initialization |
| `CpuSystemInterface` | CPU bus + interrupt line ports |
| `system_memory_read/write` | combinational/synchronous address decoder |
| `cycle_cpu` | CPU FSM one-cycle step |
| `cycle_ppu` | PPU dot FSM one-dot step |
| `mapper->tick_func` | PPU bus edge observer and mapper tick |
| `system_submit_frame` | video frame ready handshake |
| SDL callbacks | platform adapter ports |
