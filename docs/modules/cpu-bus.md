# CPU 总线模块：软件 `switch(address)` 与硬件 ready/valid 的对应关系

本文是 `rtl/nes_core/bus/nes_cpu_bus.v` 的接口与时序合同，并回答一个具体问题：

> 一个用 C 写的软件模拟器（`switch (address)` + `uint8_t *ptr` + 数组）和一个用 Verilog 写的硬件总线（`req/ready` + 完成脉冲 + 同步 RAM），是在实现同一件事的两种写法，还是在解决两个不同的问题？

结论先行：**地址译码部分是同一件事，时序部分不是。** 软件模拟器把“访问一次内存”当成一次函数调用，函数返回时数据已经在手上，因此它天然是零延迟模型；硬件总线必须把“访问”拆成一次**跨越若干拍的事务**，因为 BRAM 要 1 拍、SDRAM 要 3-5 拍、复位后的 RAM 读和刚写过的字节行为还不一样。本模块的全部信号设计，都是为了让“软件的一次函数调用”在硬件上有一个可综合、且副作用只发生一次的表达。

行为权威是 NESdev 的 CPU 地址图与 2A03 的 RDY 语义。cNES（`caseif__cNES`，commit `7c8c252`）和 Obara（`ObaraEmmanuel__NES`，commit `aa880b9`）只作为“别人怎么写”的观察，用来提示 RTL 容易漏掉的边界，不代表规格。

本文件覆盖基础总线层和它的**通用 DMA 读端口**。DMA 状态机（256/512/1024 字节计数、odd/even 对齐、`OAMADDR` 回绕、513/514 周期边界）不在这里——它在 `rtl/nes_core/ppu/nes_oam_dma.v`；`nes_mapper` 的 bank 译码、PPU nametable/CHR 通路也不在这里。本模块只做端口桥接与仲裁，不含 PPU/APU/mapper 的任何寄存器语义。

---

## 1. 文件与层次

```text
rtl/nes_core/bus/
└── nes_cpu_bus.v   地址译码 + 等待状态 + 片上 2 KiB RAM + 外部 owner 桥接 + 通用 DMA 读端口
```

模块内部只有五类东西：

```text
cpu_addr ──> owner 译码 ──> 等待计数/ready ──> cpu_ready
     │                              │
     │                              ├──> ram_array（$0000-$1FFF，组合或同步读）
     │                              ├──> ppu_req/we/addr/dout  ──> ppu_din/ppu_ack
     │                              ├──> apu_req/we/addr/dout  ──> apu_din/apu_ack
     │                              └──> cart_req/we/addr/dout ──> cart_din/cart_ack
     └──> owner/sel_* 译码输出（与请求无关，纯地址译码）

dma_addr ──> 同一张 owner 译码表 ──> 独立的等待状态机 ──> dma_ack/dma_din
     │                                    │
     │                                    └──> ram_array / open_bus 锁存（模块内部）
     └──> cart_addr（DMA 与 CPU 互斥复用）、cart_din
```

没有状态机枚举、没有“当前 owner 是谁”的寄存器：owner 完全由地址组合译码得到，等待逻辑对 CPU 和 DMA 各有一组倒计数器和标志（`active/wait_cnt` 与 `dma_active_r/dma_wait_cnt`）。这是刻意的——基础层越接近纯组合，接上层的 BRAM/SDRAM/DMA 时越不需要拆改。

## 2. 接口合同

### 2.1 CPU 侧（ready/valid）

| 端口 | 宽度 | 含义 |
|---|---|---|
| `clk` / `reset` | 1 | `reset` 异步高有效；复位把等待状态、open bus 值和同步读寄存器清零，**不清 RAM 内容** |
| `bus_hold` | 1 | 外部冻结/让出。拉高时本模块整体冻结并释放总线（见第 6 节） |
| `cpu_req` | 1 | 请求有效（对齐 `nes_cpu6502` 的 `bus_req`） |
| `cpu_we` | 1 | 1=写，0=读 |
| `cpu_addr` | 16 | 完整 16 位地址，不折叠 |
| `cpu_dout` | 8 | 写数据 |
| `cpu_din` | 8 | 读数据。**只在 `cpu_ready` 为高的那一拍保证有效**，其它时候是 owner's 中途值或未定义值 |
| `cpu_ready` | 1 | 传输将在**下一个时钟沿**完成。它不依赖 `cpu_req`，是一个纯组合的 ready |
| `cpu_fire` | 1 | `cpu_req && cpu_ready`，完成脉冲。系统可以用它触发 `$4014` DMA |
| `cpu_stall` | 1 | `cpu_req && !cpu_fire`，纯观测用 |

这套命名直接对齐 `nes_cpu6502` 的现有合同：`bus_ready` 接 `cpu_ready`，CPU 内部的 `bus_fire = bus_req && bus_ready` 就是本模块的 `cpu_fire`。CPU 在 `bus_ready` 为低时保持 `bus_addr/bus_we/bus_dout` 不变，这条“请求方在整个等待期保持稳定”的义务正是本模块敢用组合译码的前提。

### 2.1.1 通用 DMA 读端口

这一组端口是**给 DMA 引擎用的第二个只读主设备**。它和 CPU 侧完全对称：请求方提出请求并保持地址，模块把完成条件组合成 `dma_ack`，数据放在 `dma_din`。

| 端口 | 方向 | 宽度 | 含义 |
|---|---|---|---|
| `dma_req_oam` | in | 1 | OAM DMA 引擎的请求级信号。保持有效直到 `dma_ack` |
| `dma_req_dmc` | in | 1 | DMC DMA 引擎的请求级信号。保持有效直到 `dma_ack` |
| `dma_addr` | in | 16 | 被授予总线的那个引擎呈现的地址，**不折叠**。等待期间必须保持不变 |
| `dma_sel` | out | 1 | 仲裁结果：0 = OAM 拿到端口，1 = DMC 拿到端口。两条请求线都为 0 时是无关值（读作 0），要判“无人请求”请用 `dbg_dma_owner` |
| `dma_din` | out | 8 | 读数据。**只在 `dma_ack` 为高的那一拍保证有效**，其它时候是 owner 的中途值或毒值 |
| `dma_ack` | out | 1 | 传输将在**下一个时钟沿**完成。引擎在这一拍取走 `dma_din` 并推进 `dma_addr` |
| `dma_wait` | out | 1 | 请求已被受理但还没完成（含“请求提出了但还没拿到总线”）。纯观测用，引擎的义务仍然是保持请求线 |
| `dma_active` | out | 1 | 端口正在服务一笔 DMA 事务（内部 `dma_active_r` 被授予时的门控输出） |
| `dma_unimpl` | out | 1 | 当前 `dma_addr` 落在 PPU/APU MMIO，模块返回了稳定占位值而不是真实数据（第 7 节） |

两条请求线而不是一条 `dma_req`，是为了把“哪个 owner 拿到端口”做成**模块内部可断言的固定优先级**，而不是上层看不见的约定。同一拍两条都是高时，**OAM 优先于 DMC**：

```verilog
assign dma_pick_oam = dma_req_oam;
assign dma_pick_dmc = !dma_req_oam && dma_req_dmc;   // OAM 优先
assign dma_sel      = dma_pick_dmc;
```

OAM 优先的理由不是“随便定的”，有两条：NESdev 把 OAM DMA 定义为 513/514 周期的**成块** stolen-cycle 转移，DMC 抢占则是 1/2 个周期的抽样，它必须等 OAM DMA 让出总线才能继续。软件可见的后果是：OAM DMA 进行中 DMC 请求不会打断它，最多推迟到 OAM DMA 结束；反过来 DMC 不会把 OAM 的 256 字节搬运行程拉长。因此 DMC 引擎必须能接受“DMA 读被推迟若干拍”，而 OAM 引擎可以假设自己的事务一提出就推进。

仲裁结果的三个出口：`dma_sel`（给系统层决定地址/数据路由）、`dbg_dma_owner`（给 testbench 与波形工具）、以及 `dma_grant` 隐含在 `dma_ack`/`dma_wait`/`dma_active` 三个输出里。

### 2.1.2 DMA 端口的授予条件

```text
dma_grant = DMA_PRESENT && !reset && ce && bus_hold && (dma_pick_oam || dma_pick_dmc)
```

四个门各有原因：

| 门 | 原因 |
|---|---|
| `DMA_PRESENT`（参数，默认 0） | 端口存在性开关。为 0 时所有 DMA 逻辑被常量旁路，模块与加端口之前**逐位相同**（见 2.4） |
| `!reset` | 复位期间端口完全惰性：`dma_ack=0`、`dma_wait=0`、`dbg_dma_owner=IDLE`，避免复位窗口里出现一次“看起来成功”的 DMA 传输 |
| `ce` | 和 CPU 侧同一条使能：状态只在 CPU 使能沿推进 |
| `bus_hold` | 互斥点。DMA 引擎是拉高 `bus_hold` 的那一方，所以“请求已提出且 hold 已拉高”就是“CPU 已经让出总线”。没有这个门，DMA 会在 CPU 正要完成一笔 `$C000` 读的那一拍把 `cart_addr` 抢走 |

未授予时的行为是确定的、不依赖内部状态的：`dma_ack=0`、`dma_active=0`、`dma_unimpl=0`，`dma_wait` 只反映“请求线为高但还没完成”。因此引擎的正确写法是**保持请求线直到看到 `dma_ack`**，而不是等一个 `dma_grant` 输出（模块没有提供 `dma_grant` 端口，因为它完全可由 `dma_sel && bus_hold && ce` 推出）。

### 2.2 外部 owner 侧（request/ack + 完成脉冲）

三个 owner 用同一套五信号结构，字段名不同：

| 字段 | 含义 |
|---|---|
| `X_req` | 请求级信号：`cpu_req && !bus_hold && (owner == X)`。在整个等待期保持有效，外部设备可以用它把地址/方向打进自己的流水线 |
| `X_we` | 方向级信号，与 `X_req` 同时有效。`X_req && cpu_we` |
| `X_addr` / `X_dout` | 桥接出去的地址（按设备折叠）和写数据。**不折叠的** `cart_addr` 是完整 16 位 |
| `X_xfer` | **完成脉冲**，只在传输完成的那一拍为高。这是外部设备产生副作用的唯一合法时刻 |
| `X_wr` | 写事件脉冲 `X_xfer && X_we`。每个 CPU 写事务恰好一个周期 |
| `X_din` / `X_ack` | owner 返回的数据与应答。`X_ack` 为高表示“我能在这一拍完成”，且 `X_din` 在这一拍有效 |

分出 `X_req/X_we`（级）和 `X_xfer/X_wr`（脉冲）两级是本模块最重要的一个决定。软件模拟器里这两者是同一件事：

```c
case 0x2002: return ppu_read_status();   // 读 + 副作用，一次函数调用
```

硬件里它们必须分开：请求可能持续 5 拍，而 `$2002` 的 vblank 清除只能发生一次。如果只给 owner 一个 `reg_cs` 级信号，stall 5 拍就会清 5 次 vblank；如果只给脉冲，BRAM 又来不及在请求沿把地址打进流水线。两级都给，各取所长。

`cart_wr` 的存在还有一个接线上的理由：`nes_mapper` 的 `cpu_we` 内部会组合出 `prg_ram_we` 和 bank 寄存器写脉冲。接级信号，mapper 在 stall 期间会连写 5 次 bank 寄存器（MMC1 的串行移位寄存器会被写坏 5 次）；接 `cart_wr`，mapper 恰好看到一次写事件。

### 2.3 译码与观测

| 端口 | 宽度 | 含义 |
|---|---|---|
| `owner` | 3 | 0=OPEN、1=RAM、2=PPU、3=APU_IO、4=CART_RAM、5=CART_ROM |
| `sel_ram` / `sel_ppu` / `sel_apu_io` / `sel_open_bus` / `sel_cart_ram` / `sel_cart_rom` | 1 各一 | 六个区域的独热译码，**只由 `cpu_addr` 决定，与 `cpu_req` 无关** |
| `ram_addr` | `RAM_ADDR_BITS` | 折叠后的片上 RAM 地址（`cpu_addr[RAM_ADDR_BITS-1:0]`） |
| `ram_we` | 1 | 片上 RAM 写脉冲，已对齐到完成沿。留出来给 BRAM wrapper 和观测 |
| `dbg_active` | 1 | 有一笔 **CPU** 事务正在等待 |
| `dbg_wait_count` | 8 | 剩余强制等待拍数（外部 owner 的 ack 等待不计入），**只数 CPU 事务** |
| `dbg_open_bus` | 8 | 上一次**完成**传输放到数据总线上的字节（CPU 写、CPU 读、DMA 读都会更新它） |
| `dbg_dma_owner` | 2 | DMA 仲裁的完整编码：0 = OAM，1 = DMC，2 = IDLE（无请求或复位中）。OAM > DMC 的固定优先级在这里可观测 |
| `dbg_dma_wait_count` | 8 | 剩余强制等待拍数，**只数 DMA 事务** |

`sel_*` 与 `owner` 做成纯译码输出（而不是 `req && decode`）有两个理由：一是和 `nes_system_v0` 现有的 `sel_ram`/`sel_ppu` 观测量一致；二是译码错误和请求错误可以分开定位——`owner` 对但 `*_req` 不对是请求逻辑的问题，`owner` 本身错才是译码的问题。

### 2.4 参数

| 参数 | 默认 | 含义 |
|---|---|---|
| `READ_WAIT_CYCLES` | 0 | 外部 owner（PPU/APU/卡带）的**最小**额外等待拍数。0 = 零等待，兼容 `nes_system_v0` 现在的接法。对 CPU 与 DMA 两条路径同时生效 |
| `RAM_ADDR_BITS` | 11 | 片上 RAM 地址位宽，11 = 2 KiB（NES 工作 RAM 的真实大小） |
| `RAM_READ_SYNC` | 0 | 0 = 组合读（分布式 RAM/LUTRAM，0 等待）；1 = 同步读（1 拍，映射到 BRAM）。CPU 读走 `ram_q`，DMA 读走独立的 `dma_ram_q` |
| `RAM_INIT` | 0 | 上电内容。放在参数里是因为 TB 需要确定性初值，而综合流程也用得上。复位**不清** RAM |
| `DMA_PRESENT` | 0 | 是否存在通用 DMA 读端口。为 0 时 `dma_grant` 是常量 0，全部 DMA 输出是常量，模块与加端口之前逐位相同 |
| `DMA_MMIO_VALUE` | `8'h00` | DMA 读命中 PPU/APU MMIO 时返回的稳定占位值（第 7 节） |

`DMA_PRESENT` 默认 0 而不是 1，是为了让现有三个顶层（`nes_system_v0`/`nes_system_v1`/`nes_system_v2`）**一行都不用改**就继续工作：它们不接这三个输入，端口在 RTL 里被常量旁路，编译时 `iverilog` 会对每个实例报 3 条 “dangling input port floating” 警告，行为与加端口之前完全一致（这三个顶层的回归输出没有变化，见 `tb/bus/README.md` 的“运行”一节）。接 DMA 的顶层必须显式写 `.DMA_PRESENT(1'b1)`。

## 3. 地址译码

| `addr[15:13]` | 地址范围 | `owner` | 折叠 | 说明 |
|---|---|---|---|---|
| `000` | `$0000-$1FFF` | RAM | `addr[10:0]` | 四路镜像到 2 KiB |
| `001` | `$2000-$3FFF` | PPU | `addr[2:0]` | 8 个寄存器周期镜像到 `$2000-$2007` |
| `010` 且 `addr[15:5] == 11'd512` | `$4000-$401F` | APU_IO | `addr[4:0]` | 32 个寄存器周期镜像到 `$4000-$401F`（`$4000>>5 = 512`） |
| `010` 其余 | `$4020-$5FFF` | OPEN | — | 未映射，返回 open bus 值，0 等待 |
| `011` | `$6000-$7FFF` | CART_RAM | 不折叠 | 完整地址交给 mapper/PRG RAM 决定窗口 |
| `100`/`101`/`110`/`111` | `$8000-$FFFF` | CART_ROM | 不折叠 | 完整地址交给 mapper 决定 bank |

两点值得单独说：

**RAM 折叠是硬件的，不是 mapper 的。** `$0000/$0800/$1000/$1800` 指向同一个物理字节，这是 2 KiB 芯片 + 地址线直连的结果。软件里对应 `addr % SYSTEM_MEMORY_SIZE`（cNES）或 `address % 0x800`（Obara `get_ptr`），硬件里就是一根线：`ram_addr = cpu_addr[10:0]`（DMA 侧是 `dma_ram_addr = dma_addr[10:0]`）。没有比较、没有加法、没有掩码和运算。

**PPU 折叠只做译码第一步。** `ppu_addr = cpu_addr[2:0]` 把 `$2002` 和 `$3FFA` 变成同一个索引，但读 `$2002` 的 vblank 清除、`$2007` 的读缓冲、`w` 标志对副作用的抑制都在 PPU 自己内部。本模块把“这一拍完成了一次 `$2002` 读”告诉它（`ppu_xfer`），剩下的它自己判断。

**`$6000-$7FFF` 和 `$8000-$FFFF` 不折叠。** 因为窗口大小和 bank 由 mapper 决定：MMC3 可以只开 8 KiB PRG RAM，UxROM 固定最高一档 bank，NROM-128 让 `$8000-$BFFF` 和 `$C000-$FFFF` 指向同一段 ROM。总线只负责“这是卡带窗口，地址原样给你”，`cart_ram_cs` 告诉 PRG RAM owner 现在在 `$6000-$7FFF`，剩下的解释权在 `nes_mapper`。

**DMA 用的是同一张表。** 译码被抽成一个 `decode_owner(addr)` 函数，`cpu_addr` 和 `dma_addr` 各调一次；因此“DMA 读 `$17F0` 与 CPU 读 `$17F0` 折叠到同一个 `ram_addr` 偏移”这类一致性不需要单独维护，也不可能漂移。注意 `sel_*` 与 `owner` 输出仍然**只由 `cpu_addr` 决定**——它们是 CPU 侧的译码观测口，不代表 DMA 的译码结果；DMA 的译码结果只通过 `dma_din`/`dma_unimpl`/`cart_addr` 体现。这是刻意的分离：一个 `sel_*` 信号同时代表两套地址会让“它在看谁的地址”变成一个需要额外说明的问题。

## 4. 时序合同

### 4.1 完成拍数

一次访问从“请求被提出”到“传输完成”经过的时钟沿数：

| 区域 | `RAM_READ_SYNC=0, READ_WAIT_CYCLES=0` | `RAM_READ_SYNC=1, READ_WAIT_CYCLES=3` |
|---|---|---|
| RAM | 1 | 2 |
| OPEN | 1 | 1 |
| 外部 owner（ack 立即来） | 1 | 4 |
| 外部 owner（ack 要 N 拍） | 1+N | 1+max(3, N) |

公式就是 `1 + max(强制等待, ack 等待)`。这个 `max` 是有意的：参数化的强制等待用来给慢速存储一个**下限**（比如所有卡带读至少 2 拍），ack 用来表达 owner 自己还要多久（SDRAM 控制器忙）。两者取较大值，不需要优先级仲裁。

`RAM_READ_SYNC=1` 时 RAM 固定多 1 拍，因为 BRAM 的输出只能在时钟沿后有效。同步读的地址在**请求沿**打进 `ram_q`（CPU 路径）或 `dma_ram_q`（DMA 路径），所以数据在下一拍稳定，配合 1 拍等待正好是“提前一拍发地址”的标准写法。两个路径各用各的读寄存器而不是共用一个：CPU 侧的状态机在 `bus_hold` 为高时整段不推进，DMA 侧的状态机在 `bus_hold` 为低时整段不推进，结构上互斥，但合成工具不会因为“两个 always 块在同一条件下互补”就替你证明这一点，所以最省事的做法就是两份寄存器。

**DMA 读端口用完全相同的公式**，因为它复用了同一张译码表和同一组参数：

| 区域 | `RAM_READ_SYNC=0, READ_WAIT_CYCLES=0` | `RAM_READ_SYNC=1, READ_WAIT_CYCLES=3` |
|---|---|---|
| RAM | 1 | 2 |
| OPEN | 1 | 1 |
| PPU/APU MMIO（占位值） | 1 | 1 |
| 卡带 RAM/PRG（ack 立即来） | 1 | 4 |
| 卡带 RAM/PRG（ack 要 N 拍） | 1+N | 1+max(3, N) |

唯一的差别是 PPU/APU MMIO：CPU 走它要等 owner 的 ack，DMA 走它不产生任何 owner 请求、0 等待直接返回占位值（第 7 节）。这条不对称是刻意的——DMA 读 PPU 寄存器在真机上会带来难以建模的副作用（渲染被打断、滚动寄存器被重写），与其实现一半不如显式地不做并让 `dma_unimpl` 说出来。

### 4.2 状态与三个分支

模块内部对 CPU 和 DMA 各有一对寄存器（`active`/`wait_cnt` 与 `dma_active_r`/`dma_wait_cnt`），时钟沿上按同样的顺序判：

```text
完成拍（cpu_fire / dma_ack） -> 清 active/wait_cnt，提交副作用（RAM 写、open bus 更新）
请求沿（req && !active）     -> 置 active，wait_cnt = wait_need - 1，同步读在此沿锁数据
撤回沿（!req && active）     -> 清 active/wait_cnt，事务作废（见 4.4）
其余拍                      -> wait_cnt 递减
```

`ready_c` 的组合表达式把“事务还没开始”和“事务已经在等”分开处理：

```text
ready = !bus_hold && (active ? (wait_cnt == 0) : (wait_need == 0)) && (!外部owner || ack)
```

没开始时看 `wait_need`（配置决定的最小等待），已经在等时看 `wait_cnt`（本次事务实际剩余）。这样 0 等待配置下 CPU 提出请求的那一拍就能完成，不需要额外一个“启动”状态。DMA 侧是同构的 `dma_ready`，唯一差别是把 `!bus_hold` 换成 `dma_grant`：

```text
dma_ready = dma_grant && (dma_active_r ? (dma_wait_cnt == 0) : (dma_wait_need == 0)) && (!卡带owner || cart_ack)
```

两条状态机写在**同一个时序块**里、靠 `bus_hold` 互斥（`ce && !bus_hold` / `ce && !bus_hold && ...` 之后才是 DMA 分支）。这不是风格选择：open bus 锁存值 `open_bus_q` 被两条路径共用，两块分别写它就是多驱动。把互斥条件写进同一个块，读者一眼就能看出“CPU 路径和 DMA 路径在结构上不可能同时推进”。

### 4.3 stall 期间的稳定性义务

分成两半，各由不同的人负责：

**请求方（CPU 侧）**：从提出请求到看到 `cpu_ready`，`cpu_req/cpu_we/cpu_addr/cpu_dout` 必须保持不变。这是 `nes_cpu6502` 已经写进合同的义务（“the core holds its outputs stable until then”）。本模块的 TB 用一个常驻监视器在每个 stall 沿检查这一点。

**请求方（DMA 侧）**：同一条义务，换成 `dma_addr` 与 `dma_req_*`。引擎在 `dma_ack` 之前推进 `dma_addr` 就等于让模块用旧等待状态去读新地址，行为没有意义。TB 的 DMA 监视器在“上一个 DMA 拍没有 ack”时比较 `dma_addr`，任何变化立即 `$fatal`。TB 里的 DMA 引擎模型一律保持 `dma_addr` 直到 `dma_ack`。

**请求方（模块的反向义务）**：模块必须**不**动 CPU 的输出。`owner`/`sel_*` 是 `cpu_addr` 的纯组合译码，CPU 地址一冻结它们就自动冻结；`dma_addr` 只影响 DMA 自己的译码和（被授予时的）`cart_addr`。因此“CPU 事务被 DMA 打断再恢复”这一整条路径上，CPU 看到的每一个信号都和它冻结前逐位相同。

**本模块**：因为译码是组合的，请求方稳定就等于所有对外信号稳定——`ppu_req/ppu_we/ppu_addr/ppu_dout`（以及 apu/cart 的同名字段）、`owner`、`sel_*`、`ram_addr` 全部自动稳定。这不是巧合，是选择组合译码换来的：外部设备可以在请求沿把这些值打进自己的地址流水线，整个等待期不需要再改。TB 同样逐拍检查这些输出没有动。

**读数据不在稳定义务之内。** `cpu_din` 在 stall 期间可能多次变化（外部设备的输出寄存器、open bus 锁存值）。只有完成拍的那一个值有意义。TB 用“未 ready 时返回毒值”的设备模型把这条规则变成可测的：任何提前完成都会读到毒值而不是期望数据。`dma_din` 遵守同一条规则，DMA 侧的毒值是 `8'hC7`（卡带模型未 ack 时返回值）。

### 4.4 副作用只发生一次

| 副作用 | 触发条件 | 位置 |
|---|---|---|
| 片上 RAM 写入 | `cpu_fire && cpu_we && owner==RAM` | 模块内部 + `ram_we` 输出 |
| open bus 值更新 | 每次 `cpu_fire` 或 `dma_ack` | 模块内部 |
| PPU 寄存器读副作用（vblank 清除、`$2007` 缓冲、`w` 翻转） | `ppu_xfer` | 由 PPU 用 `ppu_xfer` 而非 `ppu_req` 触发 |
| APU 状态读清标志 | `apu_xfer` | 同上 |
| mapper bank 寄存器写、`prg_ram_we` | `cart_wr` | mapper 用 `cart_wr` 接线 |
| PRG RAM / PRG ROM 写入 | owner 用 `cart_wr`/`cart_xfer` 驱动自己的 RAM | 存储 owner |
| 卡带读事件计数 | `cart_xfer` | 存储 owner |
| **PPU/APU 寄存器副作用** | **无**（DMA 读 MMIO 不拉 `ppu_req`/`apu_req`） | 见第 7 节 |

DMA 端口是**只读**的：它复用 `cart_req`/`cart_addr`/`cart_din`/`cart_ack` 四个信号来读 PRG，但 `cart_dout`、`cart_we`、`cart_xfer`、`cart_wr`、`ram_we` 全部只由 CPU 路径驱动。TB 对此有正面断言——DMA 服务期间 `ram_we` 与 `ppu_xfer` 逐拍为低，PPU 读副作用计数增量为 0。

`nes_system_v0` 现在的做法是 `ppu_reg_cs = cpu_bus_fire && sel_ppu`，即“完成沿 + 地址译码”。接进本模块时这一行变成 `.reg_cs(ppu_xfer)`，语义完全一样，但不再需要在系统层重复写一遍 `&& sel_ppu`，也不会因为 stall 而重复触发。

### 4.5 请求撤回

`cpu_req` 在等待期间被拉低（请求方放弃或被抢占）时，模块清 `active`/`wait_cnt` 并丢弃这次事务：不写 RAM、不产生任何 `*_xfer`、不动 open bus。之后重新提出同一个地址会当作一次全新的事务从 0 拍开始。这条路径 TB 单独验证（`withdrawn request aborts cleanly`），因为它是从“请求方保证稳定”这条义务派生出的边界：义务被违反时，模块的行为是**放弃**而不是**猜测**。

DMA 侧的对应路径是：请求线（或 `bus_hold`）在等待期间被拉低，模块清 `dma_active_r`/`dma_wait_cnt` 并作废这一拍，**不改** open bus，`dma_ack` 也不出现。重新提出同一个 `dma_addr` 是一次全新的事务。这里和 CPU 侧有一处刻意的**不对称**：CPU 侧的 `bus_hold` 是**冻结**（第 6 节），DMA 侧的 `bus_hold` 撤销是**作废**。原因是 DMA 引擎是 hold 的驱动方，它撤销 hold 就等于宣布“我不做了”，此时保留一个半途的等待计数没有意义；而 CPU 侧的 hold 是被别人拉起来的，CPU 自己并不知道，只能原地等。

反过来，如果请求方在上一次事务完成前就提出新事务（不撤回、直接换地址），模块会认为这是同一笔事务的延续，继续用旧 `wait_cnt` 等——此时 `owner` 已经按新地址变了，行为没有意义。TB 的主控因此在每个实例完成的那一拍之后立刻拉低该实例的请求。

## 5. 等待拍的观测

`dbg_wait_count` 与 `dbg_dma_wait_count` 只数**强制等待**，不数 ack 等待。原因是 ack 等待的进度由 owner 自己知道（它的控制器状态），总线这一侧只能看到“还没好”。所以调试时会看到 `dbg_wait_count` 先归零、`dbg_active` 仍为高、`cpu_stall` 仍为高——这正是“卡带在等 SDRAM”的正常形态。反过来 `dbg_wait_count` 递减到非 0 而 owner 早已 ack，则说明配置比需要的多算了拍。

两条路径的等待状态是**两套独立寄存器**，所以“CPU 在等卡带”与“DMA 在等卡带”可以同时为真而不互相覆盖。TB 的 `dma service during a cpu stall` 用例把这件事做成断言：CPU 有一笔 stall 中的 PPU 读时发起 DMA，断言 DMA 全程 `dbg_active`/`dbg_wait_count`/`dbg_open_bus` 逐位不变、DMA 结束后它们仍然是 DMA 之前那个值，并且 CPU 那笔事务在 hold 释放后以原地址读回正确数据。

## 6. `bus_hold`：冻结与让出

`bus_hold` 是给上层的让出点（OAM/DMC DMA 仲裁用），语义是**冻结本模块 + 释放对外请求**：

| `bus_hold` 为高时 | 行为 |
|---|---|
| `cpu_ready` / `cpu_fire` | 强制 0，即使地址是 0 等待的 RAM |
| `ppu_req/apu_req/cart_req` | 强制 0，外部设备看不到挂起的请求，可以安全接管共享总线 |
| `*_xfer` / `*_wr` / `ram_we` | 强制 0 |
| `active` / `wait_cnt` | 冻结（不是清零），释放后从原状态继续 |
| `ram_array` | 不写。停在半路的写不会发生也不会被部分执行 |
| `dbg_open_bus` | 冻结 |

关键设计点是**冻结而不是复位**。DMA 抢占 CPU 总线时，6502 的状态必须原地保留（`nes_cpu6502` 的 `bus_hold` 同样冻结自己并强制 `bus_req` 为低），DMA 结束后 CPU 要能继续完成它原来那一笔访问，而不是重新开始。如果 `bus_hold` 把等待状态清零，DMA 返回后 CPU 会重新经历一遍等待，DMA 的 513/514 周期边界就会污染软件可见时序。

释放后原地址的事务继续完成，只需要再等 owner 的 ack（owner 在 `*_req` 为低的那些拍里可以重新加载自己的流水线，这正是“请求级信号可以在等待期保持有效、也可以被撤销后重建”的好处）。

### 6.1 hold 期间 CPU 与 DMA 的关系

`bus_hold` 由外部的 OAM/DMC 控制器驱动时，它是**互斥点**而不是阻塞点：

```text
bus_hold = 1 期间
  CPU 侧：cpu_ready/cpu_fire/所有 *_req/*_xfer/ram_we 全部为 0，
          active/wait_cnt/ram_q/open_bus 全部冻结（不清零）
  DMA 侧：只要 DMA_PRESENT 且有请求，dma_ack 照常可以出现，
          dma_active_r/dma_wait_cnt 照常推进，ram_array 照常被读，
          cart_addr/cart_req 照常被 DMA 的地址接管
```

两条状态机因此在同一拍里一个冻结、一个推进，而**互不覆盖**：`active` 不会被 DMA 的完成沿清掉，`dma_active_r` 也不会被 CPU 的完成沿清掉。结构上的保证是时序块里的 `else if` 链——`ce && !bus_hold` 分支属于 CPU，`else if (ce)` 分支（此时 `bus_hold` 必为高）属于 DMA。两组寄存器从不被同一条分支写过。

`cart_addr` 是唯一在 hold 期间会改值的对外信号，而且只在 DMA 真的译码到卡带窗口时才改（`dma_cart_sel = dma_grant && dma_ext`）。这正是真机的样子：CPU 被 RDY 挡住之后，DMA 引擎接管地址线。CPU 侧的一切（`cpu_addr`/`owner`/`sel_*`/`ram_addr`/`ppu_*`/`apu_*`）在 hold 期间逐位不动，TB 的 DMA 监视器每个请求沿都检查这一点。

本模块**不含** DMA 状态机。`bus_hold` 与 DMA 读端口一起提供完整的仲裁点：DMA 引擎拉高 `bus_hold`、拉高自己的请求线、把地址放在 `dma_addr` 上，看到 `dma_ack` 才推进下一个字节，结束时拉低请求线和 `bus_hold` 把总线交还。DMA 引擎的字节计数、odd/even 对齐、`$2003/$2004` 写序列都在引擎里。

## 7. 软件模型对照

### 7.0 DMA：软件的 callback 调度 vs 硬件的 DMA 端口

这是整份文档里软件与硬件差别最大的一处，值得单独写一节。

#### 7.0.1 软件模拟器怎么做 DMA

cNES 和 Obara 都不实现“抢占”。`$4014` 的写只是**记一笔**（cNES 是 `// TODO: DMA`，Obara 是让 `$4014` 可译码、可读回 `$00`、可计数但无副作用），软件要自己写搬运循环：

```c
// 软件玩家/游戏作者写的 OAM DMA
for (i = 0; i < 256; i++)
    ppu_oam[i] = read(page * 256 + i);      // read() 走的是普通的 CPU 读路径
```

这里有三个软件与硬件的结构性差别：

| | 软件 callback 模型 | 硬件 DMA 端口 |
|---|---|---|
| **谁来搬** | CPU（软件循环） | DMA 引擎（状态机），CPU 完全不参与 |
| **何时发生** | 同步插在 `$4014` 写之后，代价由软件循环自己的指令数决定 | 抢占式：CPU 被 `bus_hold` 挡住 513/514 个周期，与软件无关 |
| **读源限制** | 无。`read()` 对任何地址都成立，包括 `$2000-$3FFF`（会真的调 `ppu_read_mmio`，副作用是真的） | 只有 RAM / PRG RAM / PRG ROM / open bus。PPU/APU MMIO 返回占位值并置 `dma_unimpl` |
| **仲裁** | 不存在。只有一个执行流 | OAM 与 DMC 都要抢同一个读端口，固定 OAM > DMC |
| **open bus** | `read()` 走公共出口，`g_bus_val` 每次都被更新 | 每次 `dma_ack` 都更新 `open_bus_q`，与 cNES 的 `g_bus_val` 同构 |
| **中途放弃** | 软件可以说停就停（跳出循环） | 拉低请求线/`bus_hold`，模块清 `dma_active_r`/`dma_wait_cnt` 并作废这一拍 |

**（a）软件 callback 丢掉的是“stolen cycle”，不是“搬运”。** 软件里的 `read(page*256+i)` 和 CPU 读一个字节在代码上是同一件事；差别只在于调用它的是游戏代码还是 DMA 引擎。硬件里这个差别是 513/514 个被占掉的 CPU 周期——它是 OAM DMA 在真机上可被观测到的**唯一**副作用（除了 `$2002` 之类），所以硬件端口必须提供“让 CPU 停住”的机制（`bus_hold`），而软件模型里根本没有这个概念需要表达。

**（b）硬件 DMA 的读源集合比软件小，而且必须是小的。** 软件的 `read()` 对 `$2000` 会调用 `ppu_read_mmio(0)`，真的清 vblank、真的翻转 `w`、真的推进 `$2007` 缓冲。NESdev 对真机 OAM DMA 从 `$2000-$3FFF` 取数的描述是“会影响 PPU 内部状态”（渲染被打断），对 `$4014-$4017` 的描述是“读会返回当时的 APU 状态”。这两种行为都依赖 PPU/APU 在 CPU 被挡住的那 513 拍里的**实时**内部状态，无法用“地址 + 等待拍数”表达在一个组合译码的总线模块里。因此本模块的选择是显式的：

```verilog
OWNER_RAM, OWNER_CART_RAM, OWNER_CART_ROM -> 真实数据
OWNER_OPEN                              -> open_bus_q（稳定、可预测）
OWNER_PPU, OWNER_APU_IO                 -> DMA_MMIO_VALUE（稳定常量），0 等待，
                                            不拉 ppu_req/apu_req，dma_unimpl = 1
```

**这是本文档明确声明的“未实现”，不是“恰好返回 0”。** 它的可测形式有三条，TB 全部断言：读 `$2002` 返回 `DMA_MMIO_VALUE`、0 等待完成、`dma_unimpl=1`，且 **`ppu_regs[2]`（vblank 锁存）没有被清**——即 DMA 读 PPU 寄存器**没有任何 PPU 副作用**。想支持它需要的是 PPU/APU 侧的“被 DMA 读”专用通路，不在本模块范围内。软件因此**不得**用 `$2000-$5FFF` 作 OAM DMA 的源页；这是真机上的一个真实陷阱（$2000-$3FFF 会打断渲染），本实现把它变成一个确定的、可被断言的行为而不是一个未定义行为。

**（c）软件不需要仲裁，硬件必须。** 软件里 OAM DMA 是游戏代码的循环、DMC 是 APU 的采样函数，两者不会真正同时执行（单线程）。硬件里它们是两个独立的时钟域逻辑（`nes_oam_dma` 与 `nes_apu_dmc`）同时想读同一个端口。所以 DMA 端口的 owner 选择做成了两条显式请求线加固定优先级（第 2.1.1 节），而不是让上层用一根仲裁树拼出来——拼出来的话，优先级就变成系统层的实现细节，`nes_cpu_bus` 自己测不到，OAM > DMC 这条合同也就无处落地。TB 从端口外面用 `dbg_dma_owner` 与 `dma_sel` 断言这条合同，OAM 单独请求 / DMC 单独请求 / 两者同拍 / 两者同拍但地址不同 / 两者同拍且 OAM 随后撤请求五种情形都有断言。

**（d）软件模型的 513/514 与硬件端口无关，但与 `ce` 有关。** 端口不数周期，它只保证“一次一字节”。`nes_oam_dma` 自己的 testbench（`tb/ppu/tb_nes_oam_dma.v`）已经把 513/514、odd/even 对齐、`OAMADDR` 回绕钉住了；本模块的 testbench 只钉握手与仲裁。两侧对接时唯一的约定是：引擎的每一次“读一个字节”对应一次 `dma_ack`，而每一次 `dma_ack` 在 `ce` 计数下消耗 `1 + max(强制等待, ack 等待)` 拍。引擎若要精确数 513/514，它必须知道 `ce` 的节奏，而不能假设“一次 `dma_ack` = 一个 CPU 周期”。

### 7.1 cNES：一个 if 链 + 一个 open bus 全局变量

`system.c` 的 `system_lower_memory_read`：

```c
if (addr >= 0x0000 && addr <= 0x1FFF)  return system_ram_read(addr % SYSTEM_MEMORY_SIZE);
else if (addr >= 0x2000 && addr <= 0x3FFF) return ppu_read_mmio((uint8_t)(addr % 8));
else if (addr == 0x4014)               return 0;                       // TODO: DMA
else if ((addr >= 0x4000 && addr <= 0x4013) || addr == 0x4015) return 0; // TODO: APU
else if (addr >= 0x4016 && addr <= 0x4017) return 0x40 | controller_poll(addr - 0x4016);
else                                     return system_bus_read();        // open bus
```

`system_bus_read()` 返回 `g_bus_val`，而每次 `system_memory_read` 结束都会 `g_bus_val = res`、每次写都是 `g_bus_val = val`。也就是说 cNES 的 open bus 模型就是“上一次放到总线上的字节”——和本模块的 `dbg_open_bus` 逐位同构。

三处差别值得写下来：

**（a）if 链 vs `owner` 编码。** cNES 的条件是 `addr >= 0x2000 && addr <= 0x3FFF` 两条比较；本模块是 `case (cpu_addr[15:13])`。语义相同，但 `owner` 是 3 bit 的**数据**而不是控制流：它可以同时驱动六个 `sel_*`、驱动 `ram_addr` 折叠、驱动等待拍数策略。软件里这些是同一个 if 的多个副作用；硬件里必须显式把“这次访问归谁”编码成一个值，否则每个输出都要重写一遍译码。

**（b）`addr % 8` vs `ppu_addr = cpu_addr[2:0]`。** 软件的取模由编译器变成位与（地址非负且是 2 的幂），所以这确实是“同一件事”。但软件里取模发生在**调用点**（`ppu_read_mmio((uint8_t)(addr % 8))` 的参数里），硬件里折叠必须在**跨模块的端口上**发生——PPU 模块不该看到 16 位地址，也不该自己算取模。

**（c）函数调用即事务 vs ready/valid。** `ppu_read_mmio()` 返回时，`ppu->status` 的 vblank 位已经被清掉了，而且只清了一次——因为函数只被调用了一次。硬件里 PPU 会看到 5 拍 `ppu_req`，如果它按 `ppu_req` 做副作用就会清 5 次。`ppu_xfer` 就是把“函数调用了一次”这件事显式化。

### 7.2 Obara：指针、`switch` 和 `mem->bus`

`mmu.c` 的 `get_ptr`：

```c
uint8_t* get_ptr(Memory* mem, uint16_t address){
    if(address < 0x2000) return mem->RAM + (address % 0x800);
    if(address > 0x6000 && address < 0x8000 && mem->PRG_RAM) return mem->PRG_RAM + (address - 0x6000);
    return NULL;
}
```

这是“指针/数组”模型：一次访问被翻译成一个**指针算术**，随后 `*ptr = value` 或 `return *ptr`。零延迟、零协议、零等待。软件之所以能这样写，是因为 RAM 就在进程地址空间里。

`write_mem` 则是纯 `switch (address)`，`case PPU_CTRL: set_latch(ppu, value, 0xff); set_ctrl(ppu, value); break;`。注意 `set_latch` ——Obara 有一个模拟“数据总线残留值”的 latch 机制，`mem->bus` 也是 sticky 的。这和 cNES 的 `g_bus_val` 是同一个想法：软件必须显式维护“总线上现在是什么”，因为软件里没有真实的数据总线。

对应到硬件：

| 软件概念 | RTL 对应 | 为什么不能直接照搬 |
|---|---|---|
| `get_ptr` 返回指针 | `ram_addr = cpu_addr[10:0]` + `ram_array` | 硬件没有指针，`ram_addr` 是要被 BRAM 采样的一根线 |
| `*ptr = v` 立即生效 | `cpu_fire && cpu_we` 时钟沿写入 | 硬件的写发生在时钟沿，不是组合赋值 |
| `return *ptr` 立即返回 | `ram_q` / `dma_ram_q`（同步读）或组合读（`RAM_READ_SYNC=0`） | BRAM 的输出必须先发地址再等一拍 |
| `switch(address)` 一次命中 | `owner` 组合译码 + `*_xfer` 脉冲 | 硬件要区分“这次访问还没结束”和“已经结束” |
| `mem->bus` sticky | `dbg_open_bus` 寄存器 | 同构，但 RTL 里的值只在完成沿更新（CPU 侧是 `cpu_fire`，DMA 侧是 `dma_ack`） |
| `mem->RAM[addr % 0x800]` | `ram_array[ram_addr]` / `ram_array[dma_ram_addr]` | 同构；两条路径的折叠都是无比较的位选 |
| 软件的 `for` 循环搬 OAM | `nes_oam_dma` 状态机 + 本模块的 DMA 读端口 | 见 7.0 |

### 7.3 零延迟模型在哪里会破

软件模型的隐含前提是“所有 owner 都是同一个速度”。四条会打破它的硬件事实：

**1）BRAM 是 1 拍。** 分布式 RAM 组合读可以 0 等待，块 RAM 不行。所以同一份 RTL 需要两种读法，`RAM_READ_SYNC` 就是这个开关，`test_ram_read_write` 同时验证两个配置。

**2）SDRAM 是 3-5 拍，而且不固定。** 刷新手柄、bank 冲突、行激活都影响延迟。这时 `READY_WAIT_CYCLES=0` 配上一个“忙就拉低 ack”的 owner 就是正确的组合：总等待由 owner 说，总线不猜。

**3）副作用必须和“完成”绑定，不能和“请求”绑定。** 见 4.4。这是软件完全没有的问题——函数调用没有中间态。

**4）open bus 是物理现象，不是变量。** 软件的 `g_bus_val`/`mem->bus` 是对“总线上残留什么”的近似。硬件里真正的 open bus 取决于数据线是否浮空、上一次驱动的是哪一位、地址线在那一刻是什么。`dbg_open_bus` 保持了和软件同构的近似，并且 `OWNER_OPEN` 是 0 等待（没有任何设备会拖慢一个不存在的设备），这在软件里是天然的（`return g_bus_val` 不花时间）。

**5）抢占是硬件才有的第五个维度。** 见 7.0。软件模型里 CPU 永远在跑，因此“DMA 读端口”和“CPU 读端口”可以是同一个函数；硬件里它们是两个必须被显式仲裁的主设备，`bus_hold` + `dma_req_oam`/`dma_req_dmc` 就是那个仲裁的全部实现。

**结论**：软件模拟器的地址译码可以逐条翻译成 RTL；软件模拟器的“访问耗时”必须整体丢弃并替换成 ready/valid 协议；软件模拟器的“DMA 就是个循环”必须整体丢弃并替换成一个显式的单主仲裁端口。丢掉的东西不多，但不能靠“在 RTL 里也写成 0 拍”蒙混过关——那只是把 BRAM 换成 LUTRAM、把 SDRAM 换成寄存器堆换来的假象。

## 8. 迁移到 BRAM / SDRAM

### 8.1 片上 RAM：LUTRAM → BRAM

1. 把 `RAM_READ_SYNC` 设为 1。RAM 访问自动变成 2 拍（1 拍强制等待），`ram_q` 变成真正的 BRAM 输出寄存器。
2. 不需要改任何外部接口。`ram_we` 和 `ram_addr` 已经在完成沿对齐，wrapper 可以直接用它们接一个片上 BRAM 宏。
3. `RAM_INIT` 决定上电内容。EP4CE10 的 M9K 块可以指定初始化值，仿真里由 `initial` 块给出。
4. 若片上 RAM 要扩到 8 KiB（部分 mapper 的 PRG RAM 工作区），`RAM_ADDR_BITS` 提到 12，译码表不变（`$0000-$1FFF` 仍折叠到 `addr[RAM_ADDR_BITS-1:0]`，只是不再四路镜像到同一格——这会改变行为，需要先确认目标卡带）。

### 8.2 卡带 ROM/RAM：寄存器堆 → BRAM → SDRAM

BRAM 阶段（8-16 KiB PRG）：

```text
owner 侧不变（cart_req/cart_we/cart_addr/cart_dout/cart_ack/cart_din）
READ_WAIT_CYCLES = 1        // 给 BRAM 一拍，和 RAM 同步读对齐
cart_ack = cart_req && bram_done
```

BRAM wrapper 的形状就是 ready/valid 的标准从设备：请求沿锁 `cart_addr`/`cart_we`，下一拍给 `cart_ack=1` 和 `cart_din`，写使能只认 `cart_wr`。

SDRAM 阶段（512 KiB - 8 MiB PRG）：

```text
READ_WAIT_CYCLES = 2        // 给控制器启动/行激活留下限
cart_ack = ctrl_req && !ctrl_busy && !open_row
cart_addr 由 mapper 决定，SDRAM 控制器自己管 bank/row/column
```

需要额外解决的三件事：

1. **地址要跨模块传更宽。** mapper 给的是 PRG 内部偏移（`prg_bank_offset`，17 bit 覆盖 128 KiB）。8 MiB PRG 需要 23 bit，`nes_mapper` 的 `PRG_ADDR_BITS` 提到 23，或者在卡带 wrapper 里做窗口映射（用 `prg_bank_offset` 的高位选 SDRAM 的哪个 bank 区，低位做行地址）。
2. **mapper 的读回 `prg_readback` 要等数据回来。** UxROM/CNROM 的 bus conflict 依赖“同一地址上 ROM 的值”。零等待时这个值是同拍组合的；SDRAM 时它要等 3-5 拍。`nes_mapper` 已经有 `prg_readback` 这个观察端口，接法是：让 bus conflict 检查只在 `cart_ack` 为高的那一拍采样，否则读到的可能是上一笔事务的数据。这是本模块接口已经留好的位置（`cart_din` 在 `cart_ack` 为高时有效），但 `nes_mapper` 侧的取样点需要在集成时确认。
3. **复位后的第一次读可能更慢。** SDRAM 控制器要初始化。把 `bus_hold` 在初始化期间拉高是最简单的做法：CPU 停住，总线让出，初始化完成后释放。

### 8.3 等待拍数怎么定

不要拍脑袋。定 `READ_WAIT_CYCLES` 的正确顺序是：

1. 先定**功能**上的下限：0（片上 RAM 组合读 + 立即应答的 owner）。这是当前 `nes_system_v0` 的行为，也是所有 CPU 侧周期计数 test 的基线。
2. 换存储时只改参数，不改逻辑。BRAM → 1，SDRAM → 2 或 3。
3. 用 trace 验证：记录每次 `cpu_fire` 的拍数分布，确认 PPU/APU 访问仍然是 1 拍（它们是片上寄存器，不该被卡带存储的延迟拖慢——本模块按 owner 分别计算等待就是这个原因）。
4. 不要用 `READ_WAIT_CYCLES` 去“修”某个 mapper 的行为。mapper 的时序 glitch（MMC1 的连续 CPU cycle 过滤等）属于 mapper/时序层，用总线等待参数去凑会把两个问题搅在一起。

### 8.4 接入现有顶层

`nes_system_v0` 现在自己做的事和本模块的对应关系：

| `nes_system_v0` 现有代码 | 接到本模块 |
|---|---|
| `reg [7:0] cpu_ram [0:2047]` + 组合读 + 时钟沿写 | 删除，由 `nes_cpu_bus` 承担 |
| `case (cpu_addr[15:13])` 三路 mux | 删除，由 `owner`/`sel_*` 承担 |
| `bus_ready(!reset)` | `cpu_ready`（`reset` 移到 CPU 自己的复位） |
| `ppu_reg_cs = cpu_bus_fire && sel_ppu` | `.reg_cs(ppu_xfer)` |
| `ppu_reg_we = cpu_we` | `.reg_we(ppu_we)` |
| `prg_rom[prg_index]` 组合读 | 卡带 owner，`cart_ack` 应答 |
| （无）| `nes_mapper` 的 `cpu_we` 接 `cart_wr` |
| （无）| `.DMA_PRESENT(1'b1)` + `dma_req_oam`/`dma_req_dmc`/`dma_addr`（接 DMA 时） |

注意 `nes_system_v0` 的 `cpu_addr` 是直接来自 CPU 的，没有 `cpu_req` 门控，接入时 `cpu_req` 接 CPU 的 `bus_req` 即可；`cpu_fire` 与 CPU 内部的 `bus_fire` 是同一个信号，接线时只接一处。

### 8.5 接入 DMA 引擎

`nes_oam_dma`（在 `rtl/nes_core/ppu/`）现在的接口是 `cpu_read_req`/`cpu_read_addr`/`cpu_read_ack`/`cpu_rdata`/`cpu_hold`，即它自己握有地址线、自己在 `cpu_read_ack` 为高时取数。接到本模块的 DMA 端口上是**直连**，不需要任何适配：

| `nes_oam_dma` 输出 | `nes_cpu_bus` 输入 | 说明 |
|---|---|---|
| `cpu_hold` | `bus_hold` | OAM DMA 的 hold 与 CPU 的 hold 是**同一根线**：拉高它既冻结 CPU 又打开 DMA 端口。`nes_cpu6502` 也接这根线 |
| `cpu_read_req` | `dma_req_oam` | 已经满足“保持到 ack”这条义务（`nes_oam_dma` 的 testbench 逐拍断言 `cpu_read_req` 在 ack 之前不掉、`cpu_read_addr` 不动） |
| `cpu_read_addr` | `dma_addr` | 引擎驱动地址，总线只读 |

| `nes_cpu_bus` 输出 | `nes_oam_dma` 输入 | 说明 |
|---|---|---|
| `dma_ack` | `cpu_read_ack` | 语义一致：这一拍的数据在下一沿可用 |
| `dma_din` | `cpu_rdata` | 语义一致：只在 `dma_ack` 为高时有效 |
| `dma_wait` | （不接） | 纯观测 |

DMC 侧（`nes_apu_dmc`）的接法相同，端口换成 `dma_req_dmc`。**两个引擎必须共享一根 `dma_addr` 线**，或者在系统层用 `dma_sel` 做一层 mux；如果两个引擎各自驱动一根地址线再 mux，mux 的选择信号必须与本模块的优先级一致，否则会出现“总线的仲裁认为 A 赢了、但地址线是 B 的”这种最难查的错误。这也是本模块把优先级做进端口而不是留给上层的原因。

`dma_ppu_reg_*` 那一组（`nes_oam_dma` 用它写 `$2003/$2004`）**不走本模块**。OAM 的写目标是 PPU 内部寄存器，不是 CPU 总线；真机上那 257/258 个写周期是 DMA 引擎直接占用 PPU 寄存器端口，和 CPU 读同一片 RAM 是两条独立的通路。把它接到 `nes_cpu_bus` 的 `ppu_req/ppu_dout` 上会与 CPU 的 PPU 访问产生第二次仲裁，而那次仲裁的优先级是 PPU 域的问题，不属于本模块。

## 9. 明确未实现

- **OAM DMA / DMC DMA 状态机**。字节计数、odd/even 对齐、`OAMADDR` 回绕、`$2003/$2004` 写序列、513/514 周期边界都不在本模块；它们在 `rtl/nes_core/ppu/nes_oam_dma.v`（有独立 testbench）。本模块只提供握手与仲裁。
- **DMA 写**。端口是只读的；`cart_dout`/`cart_we`/`cart_xfer`/`cart_wr`/`ram_we` 仍然只由 CPU 路径驱动。OAM DMA 的写目标是 PPU 寄存器而不是总线，见 8.5。
- **PPU/APU MMIO 作为 DMA 数据源**。返回 `DMA_MMIO_VALUE`（默认 `$00`）、0 等待、`dma_unimpl=1`，并且**不产生任何 PPU/APU 副作用**（不拉 `ppu_req`/`apu_req`）。真机上从 `$2000-$3FFF` 取数会打断渲染、从 `$4014-$4017` 取数会返回当时的 APU 状态，这两种行为都需要 PPU/APU 侧的被 DMA 读通路。见 7.0（b）。
- **DMC 抢占的 1/2 周期语义**。端口只表达“一次一字节的读”，DMC 的 sample 偷取节奏由 APU 侧决定。
- **PPU nametable、CHR、palette、A12 的任何逻辑。**
- **APU 寄存器、mapper bank、controller（`$4016/$4017`）的语义。** `$4016/$4017` 目前落在 `APU_IO` owner 里，controller 需要并到同一个 owner 或新开一个 owner。
- **open bus 的精确硬件规则。** 当前模型是“上一次完成传输的数据字节”，与 cNES `g_bus_val` / Obara `mem->bus` 同构。
- **未初始化 RAM 内容的真实 NES 模式。** 当前由 `RAM_INIT` 决定，仿真里是 0；复位不清 RAM。
- **`nes_system_v0/v1/v2` 里的 DMA 接线。** 三个顶层都还是 `bus_hold` 恒 0、`.DMA_PRESENT` 用默认 0。接 DMA 需要新写一个集成顶层（或者按 8.5 改 v2），本次改动没有触碰这三个文件。
