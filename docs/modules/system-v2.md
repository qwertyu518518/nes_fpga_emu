# 系统集成 v2：软件模拟器的 `switch` / host loop 在硬件上对应什么

本文是 `rtl/nes_core/system/nes_system_v2.v` 的接口与接线合同，并回答一个具体问题：

> 一个用 C 写的软件模拟器（`switch (address)` + `uint8_t *ptr` + 一个按分频器 tick 的 host loop）和一个用 Verilog 写的硬件系统（`owner` + `ready` + 完成脉冲 + `bus_hold` 仲裁点），是在实现同一件事的两种写法，还是在解决两个不同的问题？

结论先行：**地址译码与 host loop 的节拍是同一件事，时序协议不是。** 软件模拟器把“访问一次内存”当成一次函数调用，函数返回时数据已经在手上，因此它天然是零延迟模型；host loop 用一个整数分频器（`g_cycle_index % 12`）决定“这一拍 CPU 走一步”，但**那一步永远不花时间**。硬件总线必须把“访问”拆成一次跨越若干拍的事务，而且这一次的拍数会反过来改变 CPU 与 PPU 的相对时序。v2 的全部接线工作，就是把“软件里的一次函数调用”落到“硬件上的一笔跨越 2 个 CPU 周期的事务”，并把由此产生的、**与真机不一致**的代价一条条写下来。

`docs/modules/cpu-bus.md` 已经逐条覆盖 `nes_cpu_bus` 自身的接口与 ready/valid 合同。本文不重复那份合同的字段定义，只写三件事：v2 怎么接线、软件模型逐条对应到硬件的哪根线、以及 v0/v1/v2 的差异与未解决问题。行为权威是 NESdev 的 CPU 地址图与 2A03 的 RDY 语义；cNES（`caseif__cNES`，commit `7c8c252`）与 Obara（`ObaraEmmanuel__NES`，commit `aa880b9`）只作为“别人怎么写”的观察。

---

## 1. 文件与层次

```text
rtl/nes_core/system/
├── nes_system_v0.v   自带 RAM / 地址 mux / 常电 bus_ready，只有 CPU + PPU(背景)
├── nes_system_v1.v   加 APU v1、$4014 访问记录，仍是常电 bus_ready
└── nes_system_v2.v   加 nes_cpu_bus（真等待）、精灵、owner/ready 观测端口
```

v2 的内部层次：

```text
                     div_phase (0..11)
                          |
        +-----------------+------------------+
        |                 |                  |
     ce_cpu=1          ce_ppu=1/3         ce_sample=1
        |                 |                  |
        |            nes_ppu2c02  <-- reg_cs = ppu_xfer
        |                 |
        |            nes_ppu_sprite (顶层内接)
        |                 |
        |              ppu_nmi --------> u_cpu.nmi_i
        |
        +--> u_cpu.ce
        +--> u_bus.ce      (与 u_cpu 同一个 clk、同一拍)
        |
   nes_cpu_bus  (READ_WAIT_CYCLES=1, RAM_READ_SYNC=1, RAM_INIT=0)
     |     |      |       |
     |     |      |       +--> cart_* --> prg_rom[cart_addr[PRG_INDEX_BITS-1:0]]
     |     |      +--> apu_* ----> nes_apu2a03 --irq--> u_cpu.irq_i
     |     +--> ppu_*
     +--> ram_array ($0000-$1FFF 四路镜像到 2 KiB)

   nes_cpu6502 的 bus_req/bus_ready 接 nes_cpu_bus 的 cpu_req/cpu_ready
   nes_cpu6502 的 bus_fire 与 nes_cpu_bus 的 cpu_fire 是同一个信号
   两者共用 clk，差别只在 ce：nes_cpu_bus 的等待状态只在 ce=1 的沿推进
```

## 2. 软件模型的三层，逐层对应到硬件

cNES 的 `system_lower_memory_read` / `system_lower_memory_write` 是一个纯 `if` 链，`do_system_loop` 是一个按分频器 tick 的死循环，OAM DMA 是 `if (g_dma_in_progress) _handle_dma(); else cycle_cpu();`。这三样东西在 v2 里的对应关系是：

| 软件（cNES） | 硬件（v2） | 是否同构 |
| --- | --- | --- |
| `if (addr >= 0x2000 && addr <= 0x3FFF)` | `case (cpu_addr[15:13]) == 3'b001` -> `owner = OWNER_PPU`、`sel_ppu` | 语义相同，形状不同 |
| `ppu_read_mmio((uint8_t)(addr % 8))` | `ppu_addr = cpu_addr[2:0]` 作为跨模块端口 | 语义相同（取模在软件里是位与） |
| `system_ram_read(addr % SYSTEM_MEMORY_SIZE)` | `ram_addr = cpu_addr[10:0]` | 语义相同 |
| `g_bus_val`（sticky 的数据总线值） | `dbg_open_bus` | 同构：都是“上一次放到总线上的字节” |
| `g_cycle_index % g_cpu_clock_divider`（NTSC = 12） | `div_phase == 0` -> `ce_cpu` | 节拍相同，**一拍做的事不同** |
| `g_cycle_index % g_ppu_clock_divider`（NTSC = 4） | `div_phase[1:0] == 0` -> `ce_ppu` | 同构 |
| `cycle_cpu()` 一次函数调用 = 一次总线访问 | `bus_fire` 一次完成脉冲 = 一次事务 | **不同构**（见下） |
| `if (g_dma_in_progress) _handle_dma()` | `bus_hold` + DMA 驱动同一组 owner 端口 | 结构同构，v2 未实现 |
| `cycle_ppu()` 每 4 拍一次 | `ce_ppu` 每 4 拍一次 | 同构 |

### 2.1 `switch` 的翻译：把“这次访问归谁”编码成一个值

cNES 的条件是 `addr >= 0x2000 && addr <= 0x3FFF` 两条比较；`nes_cpu_bus` 是 `case (cpu_addr[15:13])` 一条。两者选的是同一段地址，差别在于硬件必须把“这次访问归谁”**编成一个 3 bit 的数据**（`owner`），而不是留在控制流里：

- `owner` 同时驱动六个 `sel_*`、驱动 `ram_addr` 折叠、决定等待拍数策略、决定 `bus_data_r` 的读 mux；
- `sel_*` 是**纯地址译码输出**，与 `cpu_req` 无关。这样“译码错了”和“请求逻辑错了”可以分开定位：`owner` 对但 `ppu_req` 不对是请求逻辑的问题。

软件里这些是同一个 `if` 的多个副作用；硬件里如果不显式编码，就得给每个输出重写一遍译码。

### 2.2 host loop 的翻译：分频器是同构的，`cycle_cpu()` 的时长不是

cNES 的 host loop：

```c
bool tick_cpu = (g_cycle_index % g_cpu_clock_divider) == 0;   /* NTSC: 12 */
bool tick_ppu = (g_cycle_index % g_ppu_clock_divider) == 0;   /* NTSC: 4  */
if (tick_ppu) cycle_ppu();
if (tick_cpu) { if (g_dma_in_progress) _handle_dma(); else cycle_cpu(); g_total_cpu_cycles++; }
```

v2 的 `div_phase` 就是这段代码的 RTL 抄本，包括 PPU/CPU 的 4:12 比例。**但软件里 `cycle_cpu()` 是零成本的**：一次指令执行里的每一次访存都是一次 `system_memory_read` 调用，返回即完成。软件因此可以把“CPU 周期”与“访存次数”当成同一件事。

硬件里这两件事必须分开，因为：

1. 6502 的 RTL（`nes_cpu6502`）不是一个“每拍前进一格”的微码机，而是一个**只在 `bus_ready` 为高时才前进一格**的状态机：`cpu_active = ce && !bus_hold && !reset`，`bus_fire = bus_req && bus_ready`。这正是“可等待 CPU 总线”的合同。
2. 因此 `bus_ready` 必须在 `ce_cpu` 的那一拍恰好为高，否则 CPU 永远停住。

这两条合起来产生了 v2 最关键的一个接线决定，见 3.1。

### 2.3 DMA 的翻译：`if/else` 就是 `bus_hold`

cNES 的 `_handle_dma()` 占用 514 个 host tick，期间 `cycle_cpu()` **完全不被调用**——CPU 不是“慢下来”，是被换掉了。硬件里这正好是 `bus_hold`：

- cNES：DMA 期间 `g_bus_val` 继续被更新，`ppu_push_dma_byte(g_bus_val)` 把读到的字节推给 PPU；`g_total_cpu_cycles % 2` 为奇数时跳过一次写，复现 513/514 的差别。
- 硬件：DMA 引擎拉高 `bus_hold`，此时 `nes_cpu_bus` 强制 `cpu_ready`/`cpu_fire` 为 0、强制 `ppu_req`/`apu_req`/`cart_req` 为 0、**冻结**（不是清零）`active`/`wait_cnt`，然后由 DMA 自己驱动同一组 owner 端口；结束时拉低 `bus_hold`，CPU 从原来那一拍的剩余等待继续。

v2 把 `bus_hold` 接成 `1'b0`，所以这条路径**没有被验证**。但仲裁点已经在 `nes_cpu_bus` 里就位，v2 只是没有去拉它。

## 3. v2 的接线决定与它们的后果

### 3.1 `nes_cpu_bus` 的 `ce` 必须接 `ce_cpu`（否则死锁）

这是 v2 与 v0/v1 最大的结构差异，也是唯一一处**不接就完全跑不起来**的地方。

`nes_cpu6502` 不是“每拍前进一格”的微码机，而是**只在 `bus_ready` 为高时才前进一格**的状态机：`cpu_active = ce && !bus_hold && !reset`，`bus_fire = bus_req && bus_ready`。同时它还有一条容易被忽略的约定：

```verilog
if (!cpu_active)
    bus_req = 1'b0;      /* nes_cpu6502.v：请求只在 cpu_active 期间有效 */
```

也就是说 `cpu_req` 只在 `ce_cpu` 那一拍为高。`nes_cpu_bus` 的等待状态机按 `posedge clk` 走，但**只在 `ce` 为高的沿推进**。两者必须共用同一个 `clk` 和同一个“时间单位”（CPU 周期），否则会发生一个**确定性的**死锁，而且有两条独立理由：

| 失败接法 | 现象 |
| --- | --- |
| `ce` 接常电 1（等待拍数按 `clk` 数） | `wait_cnt` 在非 `ce` 的拍上照样递减，`ready` 于是只出现在 `div_phase ∈ {1,3,5,7,9,11}` 这些 CPU 不采样的相位上；CPU 只在 `div_phase == 0` 采样 `bus_ready`，两者永不相遇。 |
| `ce` 接常电 1（请求在非 `ce` 拍上是撤回的） | 第一个 `ce` 沿把 `active` 置 1；下一个 `clk`（`div_phase == 1`）上 `cpu_req` 已经是 0，状态机走“请求撤回”分支把事务作废；下一个 `ce` 重新启动，再下一个 `clk` 再次作废。 |

两种情况都让 CPU 永远停在 `ST_RESET_0`。（这一点在 Icarus 12 上实测确认：把 `.ce(ce_cpu)` 换成 `.ce(1'b1)`，testbench 在 56 ns 处报 `bus state moved on a clk without a cpu enable: div_phase=2 active 1->0 wait 0->0 addr=0000 req=1 stall=1`。）

v2 的接法是把 `ce` 显式接成 CPU 使能，总线与 CPU 共用同一个自由运行的 `clk`：

```verilog
) u_bus (
    .clk(clk),
    .reset(reset),
    .ce(ce_cpu),
    .bus_hold(bus_hold),
    ...
```

于是每一拍 CPU 周期总线的状态机恰好走一步，"请求沿 → 完成沿"正好是 2 个 CPU 周期（`READ_WAIT_CYCLES=1`），CPU 与总线的相位关系变成"CPU 在第 1 拍等、第 2 拍同时前进"。

这个形态的三个好处，都是构造上的而不是约定上的：

1. **可综合。** 由逻辑与门产生的时钟、派生时钟、跨时序域的读沿都不是可直接综合的构造，而 `if (ce)` 只是一个普通使能。整条等待路径上没有任何一个由逻辑生成的时钟，这与 `docs/00-overview/architecture.md` 第 1 条和 `docs/00-overview/decision-log.md` 的共享 `clk` + `ce` 决策一致。
2. **没有沿上的先后次序歧义。** CPU 与总线在同一个 `posedge clk` 上读同一份**沿前**的 `bus_req`/`bus_ready`，谁都不依赖“谁的时钟沿先到”。如果让总线的状态机跑在另一个由 `ce_cpu` 派生的时钟上，它看到的是沿后的 CPU 输出（还是沿前的，取决于仿真器的 NBA 提交顺序），这种依赖不可移植。
3. **复位是干净的。** `nes_cpu_bus` 的 `always @(posedge clk or posedge reset)` 直接挂在系统时钟上，异步复位沿一定会送达；换成派生时钟的写法则必须额外保证那个时钟的初值，否则 `active`/`wait_cnt` 会停在 x。

`ce` 的语义（状态、open bus、同步读寄存器、副作用脉冲都只在 `ce=1` 的沿推进）由 `tb/bus/tb_nes_cpu_bus.v` 在单元层证明：它在两个 `ce` 之间插入 0/1/3/5/7/11 个非 `ce` 时钟，逐个非 `ce` 时钟断言状态与 open bus 冻结、无完成脉冲，并断言完成拍数（`1/2/2`、`1/4/2`、`1/1/1`）与插入多少个 `clk` 无关。集成层的对应断言见 `tb/system/README.md` 的 v2 章节。

**剩下的代价只有时间**：`READ_WAIT_CYCLES=1` 让每一次访问都花 **2 个 CPU 周期**，所以 v2 里的 CPU 相对 PPU 只有真机一半的速率（每帧 14890 次总线访问，而真机是 29780 次）。见第 4 节。

### 3.2 `reg_cs` 只用完成脉冲，请求级信号单独给方向

| 软件 | v2 接线 | 为什么 |
| --- | --- | --- |
| `ppu_read_mmio()` 返回时 vblank 已被清一次 | `.reg_cs(ppu_xfer)`、`.reg_we(ppu_we)` | `ppu_xfer` 只在完成那一拍为高。`$2002` 读清 vblank、`$2007` 读推进 `v`、`$2004` 读写推进 `oam_addr`——如果用请求级 `reg_cs`，一次 stall 会做 6 次 |
| `apu_write_mmio()` 的副作用（清 frame IRQ、重启 frame counter） | `.reg_cs(apu_xfer)`、`.reg_we(apu_we)` | 同上 |
| `mapper->cpu_we` 组合出 `prg_ram_we` | `cart_wr` | v2 无 mapper；接口已留好 |

`ppu_we` / `apu_we` 是**请求级**的（`cpu_req && owner==X && cpu_we`），整个等待期保持有效，正是 BRAM wrapper 在请求沿打地址进流水线需要的；`reg_cs` 换成 `ppu_xfer` 之后，副作用只绑定“完成”，不再绑定“请求”。这两个信号的区分在 v2 的 testbench 里是被断言的（`reg_cs` 不得连续两拍为高；`reg_we` 只能出现在对应 owner 的请求期间）。

### 3.3 owner 的应答全部先接 1

v2 把 `ppu_ack` / `apu_ack` / `cart_ack` 都接成常 1，等待拍数完全由 `READ_WAIT_CYCLES` / `RAM_READ_SYNC` 决定。这样做是为了让集成层的时序**完全可预测**，从而能把“每一次访问恰好 2 个 CPU 周期”写成断言。真实接上 BRAM/SDRAM 之后，ack 才是 owner 自己说“我好了”，`dbg_wait_count` 会先归零而 `dbg_active` 仍为高——那不是 bug，是 `cpu-bus.md` 第 5 节描述的正常形态。

### 3.4 卡带侧：NROM-128 数组，不接 mapper

```verilog
assign prg_index = cart_addr[PRG_INDEX_BITS-1:0];                        /* 14 bit，16 KiB */
assign cart_din  = (cart_addr[15] == 1'b1) ? prg_rom[prg_index] : 8'h00;
```

- `$8000-$BFFF` 与 `$C000-$FFFF` 都取 `cart_addr[13:0]`，因此两个 16 KiB 窗口完全镜像（NROM-128）。`PRG_SIZE_BYTES` 改成 32768 就变成两段各 16 KiB（仍然是 NROM-256 行为，**仍然没有 bank 切换**）。
- `$6000-$7FFF` 的 owner 是 `CART_RAM`，但 v2 没有 PRG RAM：读回 `$00`，写被丢弃。
- `cart_addr` **不折叠**（16 位原样交给 owner），这与 `nes_cpu_bus` 的接口合同一致，因为窗口大小和 bank 由 mapper 决定；v2 是 NROM-128，不需要折叠但也不应该在这里折叠。

## 4. 等待路径的真实代价

这一节是 v2 最重要的输出：**v2 的 CPU 时序与真机不一致，而且不一致的幅度是确定的 2 倍。**

| 量 | 真 NTSC | v2 | 差异 |
| --- | --- | --- | --- |
| CPU : PPU dot 比 | 1 : 3 | 1 : 3（`ce_cpu` 每 12 拍、`ce_ppu` 每 4 拍） | 一致 |
| 一次总线访问占几个 CPU 周期 | 1（正常访存） | 2（`wait_need = 1`） | **2 倍** |
| 一条 6502 指令占几个 CPU 周期 | 2 - 7 | 4 - 14 | **2 倍** |
| 一条指令占几个 PPU dot | 6 - 21 | 12 - 42 | **2 倍** |
| 每帧（29780.5 CPU 周期）可完成的总线访问数 | 29780 | 14890 | 一半 |
| 一帧的画面周期数 | 262 × 341 = 89342 | 89342（不变） | 一致 |

后果：

1. **依赖精确周期的软件会跑错。** 任何按“这条指令占几个 dot”做光栅分裂、滚动、精灵分桶（sprite 0 hit 附近的敏感代码）的程序，在 v2 上会偏移一倍。这是功能级集成 testbench 覆盖不到、也不试图覆盖的区域。
2. **APU 的 frame counter 数的是 `ce_cpu`**，所以 frame IRQ 的间隔仍然是 29830 / 37282 个 `ce_cpu`，与真机一致——但换算成时间同样被拉长 2 倍。
3. **`audio_sample_valid` 是 `ce_cpu` 速率**，不是音频速率；v2 没有抽取器、没有 FIFO、没有 WM8978 接口。
4. 这不是“配置错了”。`READ_WAIT_CYCLES=1` + `RAM_READ_SYNC=1` 是**本次刻意选的集成配置**，目的就是让集成层第一次真正走等待路径（v0/v1 的 `bus_ready` 是常电，一次访存永远 1 拍，等待逻辑从未被执行过）。testbench 把“每一次 RAM/PPU/APU/cart 访问恰好 1 拍停顿、`dbg_wait_count` 全程为 0、只有 open bus 窗口立即完成”写成了逐事务断言，所以这个代价是被钉住的、可复现的。

## 5. 真实 50 MHz 频率问题仍未解决

v2 **保留** 12 拍 `div_phase` 作为仿真相位（4 拍 1 dot、12 拍 1 CPU 周期），这份相位本身是从 cNES 的 host loop 抄来的：cNES 把 `MASTER_CLOCK_SPEED_NTSC` 定义成 **21 477 272 Hz**，`CPU_CLOCK_DIVIDER_NTSC = 12`、`PPU_CLOCK_DIVIDER_NTSC = 4`，于是 `21477272 / 12 = 1 789 772.7 Hz`（真机 CPU）、`21477272 / 4 = 5 369 318 Hz`（真机 dot）。**cNES 的“主时钟”是为了配合整数分频器而反推出来的频率，不是任何一个现成晶振。**

v2 直接沿用 12/4，但目标器件的系统时钟是 50 MHz：

| 量 | 目标（NTSC） | 50 MHz + 12/4 分频 | 偏差 |
| --- | --- | --- | --- |
| PPU dot | 5 369 318 Hz | 50 MHz / 4 = 12 500 000 Hz | **2.328 倍太快** |
| CPU | 1 789 773 Hz | 50 MHz / 12 = 4 166 667 Hz | **2.328 倍太快** |
| 每帧时间 | 16.743 ms | 3.574 ms | 4.68 倍短 |

而 50 MHz 下**不存在**能同时命中两者的整数分频器：CPU:dot 必须是精确的 1:3，所以两个分频数必须是 `(B, 3B)`；命中 CPU 1 789 773 Hz 要求 `3B = 50e6 / 1.789773e6 = 27.932`，不是整数。取最近的整数对：

| 分频对 | dot 频率 | CPU 频率 | 误差 |
| --- | --- | --- | --- |
| 9 / 27 | 5 555 556 Hz | 1 851 852 Hz | +3.5% |
| 10 / 30 | 5 000 000 Hz | 1 666 667 Hz | −6.9% |
| 12 / 36 | 4 166 667 Hz | 1 388 889 Hz | −22.4% |

所以“真实 50 MHz 频率问题”不是分频参数没调好，而是**整数分频原理上做不到**。可行方向有三条，v2 一条都没做：

1. **换主时钟**（cNES 的做法）：选一个 21.477 272 MHz 的可用时钟，或者用 PLL 从 50 MHz 产生它，再用 12/4。代价是引入 PLL 抖动与额外的时钟域。
2. **分数分频 / NCO**：用一个相位累加器产生 27/28 拍交替的 CPU 使能、9/10 拍交替的 dot 使能。平均频率精确，代价是单次间隔有 ±1 拍抖动——对绝大多数软件不可见，但需要重新审视所有“同一沿冲突”的断言。
3. **分时钟域 + 握手**：CPU core 用自己的时钟，总线用 50 MHz，边界上一次事务跨越两个域。这与 3.1 的 `ce` 形态正交：`ce` 解决的是“同一时钟域内谁推进状态机”，跨域要另外加握手与 CDC 同步，v2 两者都没有做。

在上板之前，v2 的频率相关结论只能是“仿真相位正确，绝对速率错误 2.328 倍”。**不要**把 v2 的 `frame_period == 357368 clk`、APU frame counter 计数、音频 strobe 速率当作上板时序依据。

## 6. v0 / v1 / v2 的差异

| 维度 | `nes_system_v0` | `nes_system_v1` | `nes_system_v2` |
| --- | --- | --- | --- |
| CPU | `nes_cpu6502` | 同 | 同 |
| 总线 | 顶层自带 2 KiB RAM + `case (cpu_addr[15:13])` mux，`bus_ready = !reset` | 同 v0 | **`nes_cpu_bus`**（`READ_WAIT_CYCLES=1`、`RAM_READ_SYNC=1`、`RAM_INIT=0`、`ce = ce_cpu`） |
| 一次访存的拍数 | 1 拍（`bus_ready` 常电） | 1 拍 | **2 个 CPU 周期**（open bus 窗口 1 个） |
| 等待逻辑 | 不存在 | 不存在 | 存在，且被 testbench 逐事务断言 |
| PPU | `nes_ppu2c02`，**背景通路** | 同 v0 | 同 v0，但**顶层内接 `nes_ppu_sprite`**（背景 + 精灵混合） |
| APU | 无，`$4000-$5FFF` 读 `$00` | `nes_apu2a03`（5 通道 + 帧计数器 IRQ + sample 输出） | 同 v1 |
| `$4014` | 未译码 | 被记录（`oam_dma_req`/`oam_dma_count`），无 DMA | 被记录（`apu_reg_cs` 可观测），无 DMA |
| IRQ 源 | 无（`irq_i` 恒 0） | 仅 APU frame IRQ | 仅 APU frame IRQ |
| NMI 源 | PPU | PPU | PPU |
| DMA 仲裁 | 无 | `bus_hold` 端口预留但未用 | `bus_hold = 1'b0`，仲裁点在 `nes_cpu_bus` 里 |
| 观测 | 全部 `dbg_*` 悬空，靠层次引用 | 同 v0 | **总线与寄存器桥信号提到正式端口**（`bus_owner`/`bus_active`/`bus_wait_count`/`bus_*`/`sel_*`/`ppu_reg_*`/`apu_reg_*`/`cart_*`），只有 PRG 数组与最终状态仍用层次引用 |
| 集成 testbench | `tb_nes_system_v0.v`（背景）、`tb_nes_system_v0_nmi.v`（NMI） | `tb_nes_system_audio.v`（APU + IRQ） | `tb_nes_system_v2.v`（等待路径 + 背景 + 精灵 + APU + NMI + IRQ） |
| 频率 | 4/12 相位（仿真） | 4/12 相位（仿真） | 4/12 相位（仿真），**50 MHz 上板问题未解决** |
| 精灵 | 无 | 无（OAM 全 0 时不影响输出） | 有，且集成 testbench 写了一个在屏精灵并逐像素断言 |

三点需要强调：

1. **v2 没有删除 v0/v1 的任何功能。** v0 与 v1 的文件和 testbench 未被修改，v2 是并列的第三个顶层。
2. **v2 曾经在 2 倍指令周期上跑 CPU，这个决定已被 2026-10-03 的 2x 速率修正取代。** 原文写的是"v2 的 2 倍指令周期是 v2 自己引入的，不是 RTL 缺陷"——当时的判断是"参数与时序形状都没改，所以这是配置选择"。事实是：`nes_cpu6502` 确实没改，但 `nes_cpu_bus` 的 `wait_need` 为 1 时**根本无法表达**"1 拍等待不是额外一拍"，于是 `READ_WAIT_CYCLES = 1` 让每一次访问都多占一个 `ce_cpu`。因为 `ce_cpu` 同时是 APU 的时基，而 APU 的 frame IRQ 在 29,829 个 `ce_cpu` 上被独立验证过，所以这不是"配置选择"，而是 **CPU 与 APU 相差 2 倍**。现在 `wait_need <= 1` 是零等待，`tb_nes_system_v2.v` 的 `WAIT` 期望值也从"每个 owner 1 拍 stall"改成"每个 owner 0 拍"。详见 `docs/modules/cpu-bus.md` 4.1。
3. **v2 没有让 CPU 变"快"。** `ce_cpu` 仍然是 12 拍一次；变的是**一个 `ce_cpu` 里 CPU 能走多远**——从"一次访存"变成"一次访存"（修正前是 2 个 `ce_cpu` 才完成一次访存）。对 PPU 来说，帧长和 dot 数完全没变（`frame_period` 断言仍是 357368 clk），变的是 CPU 相对于帧的吞吐，而那正是它本来就应该有的吞吐。

## 7. 明确未实现

- **OAM DMA / DMC DMA 状态机与总线仲裁**。`bus_hold` 恒 0。`$4014` 只是被记录成一次无副作用的访问（读回 `$00`）。APU 的 `dmc_rdata` 接 `8'h00`、`dmc_ack` 接 `1'b0`；**没有**任何保护阻止未来程序启动 DMC 后把它挂在 `dmc_ack = 0` 上死等。
- **mapper**。没有 mapper 寄存器、没有 PRG/CHR banking、没有外部 CHR bus、没有 mapper IRQ。`apu_irq_o` 是 CPU `irq_i` 的唯一驱动源。
- **`$6000-$7FFF` 的 PRG RAM**。owner 译码到了 `CART_RAM`，但背后是空的。
- **音频输出通路**。没有 FIFO、没有抽取/重采样、没有 WM8978 接口、没有 `ce_sample` 抽取器。左右声道取同一个 `mixed_sample`。
- **跨时钟域**。全部模块共用一个 `clk`，`ce` 是同域使能。接 BRAM/SDRAM 或独立时钟域时 owner 侧的 ack 同步、CDC 握手都没有实现。
- **50 MHz 的真实频率**。见第 5 节。
- **逐 dot 的 PPU 取数时序、奇数帧跳 dot、PAL/Dendy 制式**。与 PPU v0 一致，未实现。
- **controller（`$4016/$4017`）**。这两个地址落在 `APU_IO` owner 里，但 APU 内部没有 controller 寄存器语义，读写都是无副作用的。

## 8. 验证入口

- 集成 testbench：`tb/system/tb_nes_system_v2.v`，说明见 `tb/system/README.md` 的“v2 testbench”章节（程序、断言清单、运行命令、实测输出）。
- 纯顶层 elaboration：`iverilog -g2001 -s nes_system_v2`（只编译 RTL），确认顶层本身不依赖 testbench 特性。
- 本仓库**没有** ModelSim、Quartus 或 EP4CE10 上板证据；本文的时序与频率结论只覆盖仿真相位，不覆盖综合、引脚分配或上板。
