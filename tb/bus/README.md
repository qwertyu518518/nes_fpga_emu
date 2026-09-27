# CPU 总线 testbench

`tb_nes_cpu_bus.v` 是 `rtl/nes_core/bus/nes_cpu_bus.v` 的自检 testbench。它自己扮演 CPU 主设备（持有 `req/we/addr/dout` 直到传输完成），自己扮演 OAM/DMC 两个 DMA 引擎（各自持有 `dma_req_*` 和 `dma_addr` 直到 `dma_ack`），自己实例化 PPU、APU、卡带窗口三个**外部设备模型**（寄存器堆 + 可编程 ack 延迟），不下载 ROM，不读外部文件，不需要 test ROM。

接口合同、地址译码表、ready/valid 时序规则、`bus_hold` 语义、DMA 读端口与仲裁合同，以及软件模拟器 `switch(address)` + DMA callback 模型到本模块的逐项对应，见 [`docs/modules/cpu-bus.md`](../../docs/modules/cpu-bus.md)。`ce` 使能的合同由本文档的“`ce` 是被测对象”一节与集成层 [`docs/modules/system-v2.md`](../../docs/modules/system-v2.md) 第 3.1 节共同固定：状态与副作用只在 `ce=1` 的 CPU 周期推进，`clk` 只是时序基准。

## 文件

| 文件 | 顶层 | 覆盖 |
|---|---|---|
| `tb_nes_cpu_bus.v` | `tb_nes_cpu_bus` | 2 KiB RAM 读写、四路镜像、六个 owner 译码、PPU/APU/ROM owner 选择、0/1/多周期等待、stall 稳定性、hold 优先级、请求撤回、open bus、卡带 RAM 窗口、`ce` 门控（状态只在 CPU 使能沿推进）、通用 DMA 读端口（RAM/PRG/open bus/PPU-APU 缺口、ack 延迟、地址稳定性、hold 期间 CPU 冻结、OAM > DMC 固定优先级、请求撤回与复位） |

## 三个配置同时被测

testbench 同时实例化三个 DUT，共享同一组 CPU 侧激励、同一组 DMA 激励、同一根 `ce`、`bus_hold` 和同一组外部设备模型：

| 实例 | `READ_WAIT_CYCLES` | `RAM_READ_SYNC` | `DMA_PRESENT` | 用途 |
|---|---|---|---|---|
| `dut` | 0（默认） | 0（组合读） | 1 | 当前 `nes_system_v0` 的零等待接法；是唯一把 `cart_addr` 接进卡带模型、也唯一引出 `dma_din/dma_ack/dma_wait/dma_active/dma_unimpl` 的实例 |
| `dut_w` | 3 | 1（同步读） | 1 | 迁移到 BRAM 之后的等待行为；引出 `dbg_dma_owner_w`/`dbg_dma_wait_count_w` 用来断言 DMA 强制等待计数器确实被装上 |
| `dut_v` | 1 | 1（同步读） | 1 | `nes_system_v2` 的集成配置，外部 owner 与 RAM 都是 `wait_need=1` |

三个实例的 `cpu_req` 是**三条独立请求线**（`req0`/`req1`/`req2`）。testbench 主控在每个实例各自完成的那一拍之后才拉低它自己的请求，所以一个 CPU 写绝不会在第二个实例里再发生一次——否则“一个 CPU 事务恰好产生一次写副作用”这条断言会被 TB 自己伪造的重复事务破坏。

DMA 侧**只有一组请求线**（`dma_req_oam`/`dma_req_dmc`/`dma_addr`），三个实例共享。这是刻意的：DMA 端口是单主仲裁点，TB 的 DMA 引擎模型在任一时刻只有一个 owner 持有总线（就是被授予的那一个），所以让三个配置同时服务同一个 DMA 事务，才能逐配置精确断言 DMA 读完成拍数。三个实例的 `dma_din` 因此都从同一条 `dma_addr` 译码，卡带数据又都经过 `dut` 的 `cart_addr`（唯一接进模型的那个），所以 DMA 的 PRG 读数据在三个实例上一致，可以逐个断言。

## `ce` 是被测对象，不是接线细节

`nes_cpu_bus` 有一个显式 `ce` 输入。`clk` 只提供时序基准，`active` / `wait_cnt` / `ram_q` / `dma_active_r` / `dma_wait_cnt` / `dma_ram_q` / open bus 锁存值**只在 `ce=1` 的那个时钟沿推进**，所有副作用脉冲（`ram_we`、`*_xfer`、`*_wr`）也都被 `ce` 限定。testbench 因此可以自由地在两个 `ce` 之间插入任意数量的“非 `ce` 时钟”，用来证明：

- 事务的拍数按 **CPU `ce`** 计，与两个 `ce` 之间隔了多少个 `clk` 无关；
- 非 `ce` 时钟上 `active` / `wait_cnt` / open bus 全部冻结，也不产生任何完成脉冲；
- `bus_hold` 与 `ce` 是两个正交的门：hold 冻结状态，`ce` 决定状态何时推进。

`ce_transfer` 任务按“提出请求 → 等 `ce` → 插 `gap` 个非 `ce` 时钟 → 再等 `ce`”的节拍跑一笔事务，并分别统计三个实例各用了多少个 `ce`。`test_ce_gated_progress` 用 1/3/4/5/7/11 个非 `ce` 时钟的间隔跑 RAM/PPU/ROM/open bus 读写，期望值恒为 `1/2/2`、`1/4/2`、`1/1/1`；`test_ce_hold` 在前 3 个 `ce` 上拉 `bus_hold`，期望值变成 `4/7/5`。请求方义务（`cpu_req` 只在 CPU `ce` 有效、地址与控制在 stall 期间保持不变）与 `nes_cpu6502` 一致：`nes_cpu6502` 内部有 `if (!cpu_active) bus_req = 1'b0;`，所以 TB 的 `ce_transfer` 也只在 `ce` 窗口里拉高 `req0/req1/req2`，并在每个实例完成的那一拍之后立刻拉低它自己的请求。

对照实验（对 RTL 副本删除 `ce &&`，不改动仓库文件）会被第一条断言抓住：`clk without ce keeps the forced wait active flag: got 0 expected 1`——没有 `ce` 门时状态机会在非 `ce` 时钟上走“请求撤回”分支，把等待中的事务作废。

## DMA 引擎模型

TB 不实现 DMA 状态机（`nes_oam_dma` 在 `rtl/nes_core/ppu/` 有自己的 TB），只实现 DMA 引擎对总线的**请求方义务**：

| 模型 | 内容 |
|---|---|
| OAM 引擎 | 拉高 `dma_req_oam`，把 `dma_addr` 保持在 `{page, index}`，直到看到 `dma_ack` 才推进到下一个字节 |
| DMC 引擎 | 拉高 `dma_req_dmc`，行为同上；`dma_addr` 固定落在 PRG 区域 |
| 仲裁观察 | 三个实例的 `dma_ack` 各自独立计时，TB 因此能逐配置给出精确的完成拍数 |

`dma_read` 任务跑一笔 DMA 读：拉 `bus_hold`、拉请求线、逐拍采样三个实例的 `dma_din`/`dma_ack`/`dma_wait`/`dma_active`/`dbg_dma_wait_count` 与 `cart_addr`，在 `dma_ack` 那一拍取数据、按实例累加拍数，**等三个实例都 ack 之后**才拉低请求线并释放 `bus_hold`。任务结束后 `bus_hold=0`，所以任务里对 `cart_addr` 的断言必须用完成拍抓下来的 `dma_seen_cart_addr`（任务返回时 `cart_addr` 已经交还给 CPU 地址）。

## 设备模型

| 模型 | 内容 | ack 延迟 | 数据/副作用 |
|---|---|---|---|
| PPU | 8 个寄存器（`addr[2:0]` 折叠） | `ppu_ack_delay` 拍 | 读 `$2002` 返回并清除 vblank 锁存位；读/写各一个事件计数器 |
| APU | 32 个寄存器（`addr[4:0]` 折叠） | `apu_ack_delay` 拍 | 读 `$4015` 返回并清除 frame IRQ 位（bit 6） |
| 卡带 | 16 KiB PRG ROM 签名镜像 + 8 KiB PRG RAM | `cart_ack_delay` 拍 | `$6000-$7FFF` 落 PRG RAM，`$8000+` 写只计 mapper 写事件 |

三个模型在 `ack` 为低时都返回**毒值**（`8'hE1`/`8'hD3`/`8'hC7`），`ack` 拉高后才给出真实数据。因此“先完成、后取数”这条规则不是靠约定，而是靠毒值被断言直接测出来的：任何提前完成都会让期望数据和毒值不符。`ce` 与 DMA 相关的用例把三个 `ack_delay` 都设成 0，让等待拍数只由 `READ_WAIT_CYCLES` / `RAM_READ_SYNC` 决定（否则设备模型的 ack 倒计时也是按 `clk` 计的，会把“等待几个 `ce`”这个问题搅浑）。

卡带模型的 `ack` 条件是 `cart_busy && (ack_cnt == 0)`，而 `cart_busy = cart_req | cart_req_w | cart_req_v`。DMA 读 PRG 时 `dma_cart_sel` 会把 `cart_req` 拉高，因此同一条 ack 通路同时服务 CPU 读和 DMA 读——这正是“硬件 DMA 端口复用同一组 owner 端口”的可测形态。

ROM 签名是 `rom_sig(addr) = 8'h80 ^ addr[7:0] ^ {addr[13:12], 6'h00}`，TB 用同一个函数独立算期望值，不读 DUT 的任何内部译码输出。

## 运行

RTL 和 testbench 都用 `-g2001`（Icarus 12 在 `-g2001` 下已支持 `$fatal`），输出放在临时目录：

```powershell
$tmp = Join-Path $env:TEMP 'op_fpga_emu'
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
& 'C:\iverilog\bin\iverilog.exe' -g2001 -s tb_nes_cpu_bus -o (Join-Path $tmp 'tb_nes_cpu_bus.vvp') 'rtl\nes_core\bus\nes_cpu_bus.v' 'tb\bus\tb_nes_cpu_bus.v'
& 'C:\iverilog\bin\vvp.exe' (Join-Path $tmp 'tb_nes_cpu_bus.vvp')
```

RTL 也可以不带 testbench 单独 elaborate：

```powershell
& 'C:\iverilog\bin\iverilog.exe' -g2001 -s nes_cpu_bus -o (Join-Path $tmp 'nes_cpu_bus.vvp') 'rtl\nes_core\bus\nes_cpu_bus.v'
```

加 `-Wall` 编译无告警（三个实例都接全了 DMA 端口，没有悬空输入）。`nes_system_v0/v1/v2` 没有接这三个新输入，`iverilog` 会对它们报 3 条 “dangling input port ... floating” 警告；这是有意的——`DMA_PRESENT` 默认 0，端口在 RTL 里被完全旁路，行为与加端口之前逐位相同（v0/v1/v2 的回归输出没有变化）。

## 固定期望输出

```text
reset state and default zero wait ready PASS
decode table ram/ppu/apu-io/open/cart-ram/cart-rom PASS
on chip 2K ram synchronous write and read back PASS
0000-1FFF four way ram mirroring PASS
owner selection and per owner request forwarding PASS
read side effects and write strobes only on completed transfers PASS
one cycle wait on the ppu, apu and rom owners PASS
multi cycle wait on the ppu, apu and rom owners PASS
address and control stability through a long stall PASS
4020-5FFF open bus value tracking PASS
6000-7FFF cart ram window and 8000-FFFF rom window PASS
bus_hold before the request freezes and yields the bus PASS
bus_hold in the middle of a stall freezes and resumes PASS
bus_hold during a stalled write produces one write event PASS
withdrawn request aborts cleanly and can be re-presented PASS
ce gated transactions take the same cpu cycles with 1, 3, 4, 5, 7 and 11 clk gaps between the enables PASS
bus_hold freezes the wait state across cpu enables and the transfer still completes once PASS
dma port idle contract and reset values PASS
dma reads of on chip 2K ram across four way mirroring PASS
dma reads of the cart ram and prg rom windows PASS
dma open bus tracking and the unimplemented ppu/apu mmio source PASS
dma ack delay keeps address, owner and cpu outputs stable PASS
dma service during a cpu stall freezes the cpu and never overlaps busy state PASS
fixed oam over dmc priority on the shared dma read port PASS
withdrawn dma request aborts cleanly and can be re-presented PASS
reset clears the dma state and the next transfer still works PASS
CHECKS 2114
PASS tb_nes_cpu_bus ram-mirror/owner/wait/stall/hold/ce/dma
```

任何断言失败都走 `$fatal`，打印 `FAIL <标签>: got <实际> expected <期望>` 形式的消息并以退出码 1 结束；传输不完成、全局超时同样是失败。`CHECKS` 计数包含两个常驻监视器（CPU stall 稳定性监视器与 DMA 稳定性监视器）在每个等待沿上各贡献的一次检查。

## 断言覆盖要点

| 分组 | 断言内容 |
|---|---|
| reset | 复位后 `dbg_wait_count`/`dbg_active`/`dbg_open_bus` 归零；RAM 地址在任何请求之前就是 ready（`dut`），而 `dut_w` 在请求开始之前 **不是** ready（同步读必须先启动） |
| 译码 | 15 个代表地址的 `owner` 与六个 `sel_*`（打包成 `sel_word`），含 `$07FF/$0800/$1000/$1FFF`、`$3FFF`、`$401F/$4020`、`$5FFF/$6000/$7FFF/$8000/$FFFF` 边界；两个配置译码一致 |
| RAM | 未写过的字节读回 `RAM_INIT`；写脉冲计数为 1；读回值、`dbg_open_bus`、延迟配置的 `dbg_open_bus_w` 都被检查 |
| 镜像 | 写 `$0000` 后 `$0000/$0800/$1000/$1800` 读到同一字节且 `ram_addr` 折叠为 0；写 `$1810` 后 `$0810/$1010/$0010` 同值；再写 `$1000` 后 `$0000` 变成新值 |
| owner 选择 | 请求期间只有被选中的 owner 有 `*_req`，`ppu_addr`/`apu_addr` 折叠、`cart_addr` 不折叠；完成那一拍用捕获信号断言 `ppu_xfer`/`ppu_wr` 为 1、其它 owner 的 `*_xfer` 与 `ram_we` 为 0、等待计数已排空；`$4015` 是 APU IO 而 `$4035` 已经是 open bus |
| 副作用时机 | `$2002` 读：第一个完成拍读到 `$80`，晚一个拍的第二个配置读到 `$00`，且 stall 期间 vblank 锁存位和读事件计数都不动；`$4015` 读对 frame IRQ 位做同样断言；一个 2 拍的 RAM 写只产生 1 个 `ram_we` 脉冲；一个 stall 了 4 拍的 mapper 写只产生 1 个写事件 |
| 1 拍等待 | PPU/APU/ROM 各一次 `ack_delay=1` 的读写，两个配置的完成拍数分别按 `1+ack` 和 `1+max(3,ack)` 精确断言 |
| 多拍等待 | `ack_delay` 5/7/4：逐拍断言 `cpu_stall` 为高、`cpu_fire` 为低、`cpu_din` 仍是毒值、请求与地址稳定；断言等待计数先归零后继续等 ack |
| stall 稳定性 | 常驻监视器在**每个** stall 沿比较 `cpu_addr/we/dout`、`owner`、`sel_word`、`ram_addr` 以及三个 owner 的 `req/we/addr/dout`，任何一位变化立即 `$fatal` |
| open bus | ROM 读把 `dbg_open_bus` 变成读回值；`$4020` 读回该值且 1 拍完成、不请求任何 owner；在 PPU/APU 都设 6 拍延迟时 open bus 仍然 1 拍完成；写 `$5000` 后 `dbg_open_bus` 变成写数据 |
| 卡带窗口 | `$6000/$7000/$7FFF` 是三个独立字节（不假装 8 KiB 窗口内还有镜像），`$8000+` 写不污染 PRG RAM 但产生 mapper 写事件，`$FFFF` 读到签名值 |
| hold 优先级 | 请求之前拉 hold：零等待地址也 `ready=0`、不产生 `ram_we`、事务根本没启动、等待计数保持 0；释放后恰好 1 个写脉冲并能读回 |
| hold 优先级 | stall 中拉 hold 三个拍：`ready/fire/*_req/*_xfer/*_wr/ram_we` 全低，等待计数与 `dbg_active` 冻结，无读副作用；释放后事务以原地址正常完成，只多一次读事件 |
| hold 优先级 | stall 中拉 hold 且事务是写：hold 期间无 mapper 写事件，释放后恰好一个 |
| 请求撤回 | stall 中拉低请求：`dbg_active` 归零、等待计数清零、无副作用；再重新提出同一请求可以正常完成 |
| `ce` 门控 | `ce_transfer` 在每个 `ce` 之间插入 1/3/4/5/7/11 个非 `ce` 时钟，逐个非 `ce` 时钟断言 `dbg_active`/`dbg_wait_count`/`dbg_open_bus` 冻结、`cpu_fire`/`ram_we`/`ppu_xfer` 不脉冲；三个实例的完成拍数分别精确断言为 `1/2/2`（RAM 读写）、`1/4/2`（PPU/ROM 读）、`1/1/1`（open bus 读），与 `ce` 之间的 `clk` 数量无关 |
| `ce` 门控 | 同一个 `ce_transfer` 前 3 个 `ce` 拉 `bus_hold`：三个实例的 `cpu_ready` 全程为 0、`dbg_active`/`dbg_wait_count`/`dbg_open_bus` 与 `*_req` 全部冻结/释放、无 `ram_we`；释放后拍数精确变成 `4/7/5`，数据仍正确 |
| `ce` 门控 | 同步读配置（`dut_v`）在 `ce` 窗口内读回写入的字节，open bus 锁存值逐实例检查，`ram_we` 事件计数逐实例为 1 且 `ram_we`/`ppu_wr`/`cart_wr` 只在完成那一拍为高（读事务上全为 0） |
| DMA 空闲合同 | 无请求（`dma_addr` 摆在 RAM / open bus / PRG 三个区域）时 `dma_ack/dma_wait/dma_active/dma_unimpl` 全低，`dbg_dma_owner=2`（IDLE），`dbg_dma_wait_count=0` |
| DMA RAM/PRG 读 | DMA 读 `$07F0`（用 `ce_transfer` 给三个实例同时写下 `$3C`）与镜像 `$17F0` 都读回 `$3C`；未写过的 `$00F0` 读回 `RAM_INIT`；拍数精确断言为 `1/2/2`。DMA 读 `$6100`（CPU 先写入 `$5D`）与 `$C123/$FFFF` 都读回卡带数据，拍数 `1/4/2`；完成那一拍 `cart_addr` 必须等于 `dma_addr` |
| DMA open bus 与 MMIO 缺口 | DMA 读 `$2002`/`$4015` 返回 `DMA_MMIO_VALUE`（`$00`）、0 等待、`dma_unimpl=1`，且 `$2002` 的 vblank 锁存位**没有**被清（0 次 PPU 读副作用）；DMA 读 `$4020/$5FFF` 返回 open bus 锁存值且不置 `dma_unimpl`；DMA PRG 读把 open bus 锁存值更新成读回字节，三个实例一致 |
| DMA ack 延迟与稳定性 | `cart_ack_delay=3` 的 PRG 读：第一拍 `dma_wait=1/dma_ack=0/dma_din=8'hC7`（毒值）、`dbg_dma_wait_count` 仍为 0；请求沿把它装成 2（`dut_w`，`READ_WAIT_CYCLES=3`）而 `dut` 恒为 0，`dma_active=1`；等待期逐拍断言 `dma_wait` 仍为高、`cart_addr` 仍是 `$E123`、`cpu_ready/cpu_fire/ppu_req/ram_we` 全冻结、`owner` 仍是被冻结的 CPU owner；完成拍 `dma_wait=0`、`dma_active` 仍为高（沿后才清）、等待计数已排空；拍数精确断言为 `4/4/4` |
| DMA 期间 CPU 稳定 | 常驻 DMA 监视器在每个 DMA 请求沿比较 `cpu_addr/we/dout`、`owner`、`sel_word`、`ram_addr`（CPU 侧必须冻结），并在上一个 DMA 拍没有 ack 时比较 `dma_addr`（请求方必须稳定） |
| DMA hold + CPU 忙等隔离 | CPU 有一笔 stall 中的 PPU 读（`dbg_active=1`）时拉 hold + DMC 请求：`dbg_active`/`dbg_wait_count`/`dbg_open_bus` 全部冻结（不是清零），`cpu_stall` 仍为高；DMA PRG 读正常完成且期间 `cpu_fire`/`ram_we`/`ppu_xfer` 从不脉冲、PPU 读副作用计数增量为 0；DMA 结束后 `dbg_active` 仍是 1、等待计数与 DMA 前逐位相同；释放 hold 后 CPU 事务以原地址读回 `$8A`，只产生一次读副作用，随后 `dbg_active`/`dbg_wait_count` 才清零 |
| DMA 优先级 | `dbg_dma_owner`/`dma_sel` 在 OAM 单独请求、DMC 单独请求、两者同拍请求、全撤四种组合下分别为 `0/0`、`1/1`、`0/0`、`2/-`；两者同拍时读回的是 **OAM** 的地址（PRG 与卡带 RAM 两个地址各验一次，完成那一拍的 `dbg_dma_owner` 也必须是 0），OAM 撤请求后同一拍立刻变成 DMC 的地址（完成那一拍必须是 1） |
| DMA 请求撤回 | stall 中拉低请求：`dma_active` 归零、等待计数清零、`dma_ack/dma_wait` 都为低；再重新提出同一请求可以正常完成，之后 DMC 请求也能正常完成 |
| DMA 复位 | 请求在等待中被 `reset` 打断：`dma_active`/`dbg_dma_wait_count` 清零、端口变成惰性（`dma_ack=0`、`dma_wait=0`、`dbg_dma_owner=2`）、open bus 与 CPU `dbg_active` 一并归零；复位保持 20 ns 期间状态不回来；复位后 RAM 内容**没有**被清（`$07F0` 仍是 `$3C`），新的 DMA RAM/PRG 读照常工作 |

## 明确未覆盖

- DMA 状态机本身（256/512/1024 字节计数、odd/even 对齐、`OAMADDR` 回绕、`$2003/$2004` 写序列、513/514 周期边界）。`rtl/nes_core/ppu/nes_oam_dma.v` 有自己的 testbench（`tb/ppu/tb_nes_oam_dma.v`）；本 TB 只覆盖它与总线之间的**握手**。
- DMC DMA 的时序来源（APU 的 DMC 周期、sample 偷取、`$4015` bit 4/7、`$4010-$4013`）。本端口只提供“一次一字节的读事务”，DMC 何时发起由 APU 层决定。
- DMA **写**。端口是只读的；`cart_wr`/`cart_xfer`/`ram_we` 仍然只由 CPU 事务驱动，TB 断言 DMA 期间这三个脉冲从不出现。
- PPU/APU MMIO 作为 DMA 数据源。端口返回稳定占位值 `DMA_MMIO_VALUE` 并置 `dma_unimpl`，见 `docs/modules/cpu-bus.md` 第 7 节。
- 真实 ROM、test ROM、综合、时序收敛、板上行为。
- open bus 的精确硬件规则（浮空数据线、上次驱动值与地址线残留）。这里用“上一次完成传输的数据字节”，与 cNES 的 `g_bus_val` 同构，是软件近似而不是 NESdev 规格。DMA 读同样会更新这个锁存值（与 cNES 里每次总线访问都写 `g_bus_val` 同构）。
- 与 6502 的端到端联调（CPU 核心目前由 `nes_cpu6502` 自己的 TB 覆盖），以及 `nes_system_v2` 里的 DMA 接线（`bus_hold` 在 v2 里恒为 0）。
- PPU nametable/CHR 路径、PPU A12、mapper bank 译码：本模块只把地址和方向桥接出去，不解释 bank。
- 读改写（RMW）期间同一地址的读后写：组合读模式下同拍写同址读回的是旧值，这和 `nes_system_v0` 现在的行为一致，本 TB 不做断言。
