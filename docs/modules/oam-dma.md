# OAM DMA（$4014）：从软件模拟器的 DMA 调度到硬件 DMA 状态机

本文说明 `rtl/nes_core/ppu/nes_oam_dma.v` 的接口合同、时序模型和设计取舍，并回答一个和 `ppu-sprites.md` 同源的教学问题：

> 一个用 C 写的软件模拟器（一次 `memcpy` 加一个"占用 513 周期"的计数器）和一个用 Verilog 写的硬件实现（一次请求/应答握手加一个 4 状态状态机），究竟是不是**同一套行为的两种写法**？

结论：**数据的搬运方向和次序是同一套行为；"谁在什么时候拿到总线"完全不是。** 软件模拟器不需要总线，它只需要在正确的 CPU 周期上把 256 个字节交给 PPU；硬件实现必须真的去抢 CPU 的地址总线，并且必须真的把 CPU 停住 513/514 个周期。`nes_oam_dma.v` 实现的是后者：它是**总线主设备**，不是内存搬运函数。

行为权威是 NESdev PPU 文档中关于 OAM DMA 的小节。参考的克隆仓库只作为"别人怎么实现"的观察：

```text
.slim/clonedeps/repos/caseif__cNES/src/system.c       _handle_dma / system_start_oam_dma / $4014 译码
.slim/clonedeps/repos/caseif__cNES/src/ppu.c           ppu_push_dma_byte（DMA 的写端回调）
.slim/clonedeps/repos/ObaraEmmanuel__NES/src/ppu.c     dma() -> schedule_dma(..., DMA_OAM, ...)
.slim/clonedeps/repos/ObaraEmmanuel__NES/src/cpu6502.c tick_dma() 的 DMA_ALIGNING / DMA_HALTING / DMA_READ / DMA_WRITE
.slim/clonedeps/repos/ObaraEmmanuel__NES/src/mmu.c     $4014 写 -> dma()，$2003/$2004 读写
```

`[源码观察]` 标记的内容只是这两个仓库的写法，不是规格；本文没有用任何"看起来像规格"的措辞描述它们。

---

## 1. 软件模拟器怎么调度 OAM DMA

### 1.1 cNES：一个整数计数器 + 一次内存读回调

`[源码观察]` cNES 把 DMA 做成三个全局量，写 `$4014` 只是置位：

```c
static bool g_dma_in_progress;
static uint8_t g_dma_page;
static unsigned int g_dma_step;

void system_start_oam_dma(uint8_t page) {
    g_dma_in_progress = true;
    g_dma_page = page;
    g_dma_step = 0;
}
```

主循环里，DMA 抢占 CPU：

```c
if (tick_cpu) {
    if (g_dma_in_progress) { _handle_dma(); } else { cycle_cpu(); }
    g_total_cpu_cycles++;
}
```

`[源码观察]` 注意这里**没有"停住 CPU"的代码**：`cycle_cpu()` 只是没被调用。软件模拟器里的"CPU halt"就是"不调用 CPU 那个函数"，成本为零。

`_handle_dma()` 本身很短，全部逻辑是"这一步是读还是写"：

```c
uint8_t index = ppu_get_internal_regs()->s;            /* s 就是 OAMADDR */
if (g_dma_step == 0) {
    system_memory_read((g_dma_page << 8) | index);     /* dummy read，结果丢弃 */
} else {
    if (g_dma_step == 1) {
        g_dma_step++;
        if (g_total_cpu_cycles % 2) return;             /* 奇数周期：多烧一个 dummy */
    }
    if (g_dma_step % 2) ppu_push_dma_byte(g_bus_val);  /* 写 */
    else g_bus_val = system_memory_read((g_dma_page << 8) | index);  /* 读 */
}
if (++g_dma_step > 514) g_dma_in_progress = false;
```

这段代码里有四个值得记住的事实，每一个在 RTL 里都有一个对应物：

| cNES 里的写法 | 硬件里的对应物 |
| --- | --- |
| `g_dma_in_progress` 决定主循环调 `_handle_dma()` 还是 `cycle_cpu()` | `busy` / `cpu_hold` 决定 CPU 状态机是否推进、`nes_cpu_bus` 的 `bus_hold` 是否把总线冻结 |
| `g_total_cpu_cycles % 2` 决定多烧一个 dummy 周期 | `parity_q` 决定 `align_left_q` 是 1 还是 2 |
| `g_dma_step % 2` 决定这一步是读还是写 | `state` 是 `ST_READ` 还是 `ST_WRITE` |
| `system_memory_read(addr)` 直接返回字节 | `cpu_read_req` + `cpu_read_addr` 发出去，字节从 `cpu_rdata` 回来 |

**`system_memory_read` 就是"内存读取回调"。** 软件模拟器的总线是函数调用：给地址、给返回值，没有握手、没有延迟、没有"总线忙"这种状态。硬件的总线是一组引脚 + 一个请求/应答握手，函数调用模型在这里必须被替换成协议。

### 1.2 Obara：把 DMA 做成 CPU 的一个协程

`[源码观察]` Obara 走的是另一条路：DMA 不在 `mmu.c` 里循环，而是被**登记**到 CPU 上，由 CPU 自己"让出"执行权。

```c
void dma(PPU* ppu, uint8_t address){
    schedule_dma(&ppu->emulator->cpu, DMA_OAM, address * 0x100, ppu->OAM, 256, ppu->oam_address);
}
```

`tick_dma()` 是一个显式状态机，状态名直接把硬件时序暴露出来了：

```c
switch (dma->phase) {
    case DMA_ALIGNING: dma->phase = DMA_READ; break;
    case DMA_HALTING:
        if (ctx->apu->cycles & 1) dma->phase = DMA_ALIGNING; else dma->phase = DMA_READ;
        break;
    case DMA_DUMMY:
        if (ctx->apu->cycles & 1) dma->phase = DMA_ALIGNING; else dma->phase = DMA_READ;
        break;
    case DMA_READ:  ... dma->buffer = read_mem(ctx->memory, effective_addr);
                     if (dma->type == DMA_OAM) dma->phase = DMA_WRITE; ... break;
    case DMA_WRITE: uint16_t i = dma->offset + dma->index;
                     if (i >= dma->length) i -= dma->length;      /* OAMADDR 回绕 */
                     dma->dst[i] = dma->buffer;
                     if (++dma->index >= dma->length) dma->phase = DMA_CLEAR;
                     else dma->phase = DMA_READ; break;
}
```

`DMA_WRITE` 里那两行 `if (i >= dma->length) i -= dma->length;` 是**软件模拟器必须手写的硬件行为**：真实硬件的 OAM 是一个 256 字节的环形寄存器，`$2004` 每写一次 OAMADDR 加一、加到 255 之后回 0。软件里 `OAM[]` 只是一个数组，数组不会自己回绕，所以要显式减。`nes_oam_dma.v` 里对应的是：

```verilog
oam_cur_q <= (oam_cur_q == 8'hFF) ? 8'h00 : (oam_cur_q + 8'd1);
```

`DMA_ALIGNING` 这个状态名直接来自 NESdev 对"对齐周期"的叫法。`nes_oam_dma.v` 把它叫 `ST_ALIGN`。

---

## 2. 硬件侧的合同：为什么需要握手

真实硬件上，DMA 读一个字节至少需要两件事同时发生：

1. CPU 的地址总线上出现 `{page, index}`，然后被某个从设备（工作 RAM / 卡带 PRG ROM / 卡带 RAM）驱动成有效数据。
2. CPU 状态机停止推进。

这两件事都不是"一次函数调用"能表达的。`nes_oam_dma.v` 因此采用和 `nes_apu_dmc.v` 完全一致的握手风格（见 `tb/apu/README.md` 的"CPU stall / DMA 边界"）：

| 信号 | 方向 | 语义 |
| --- | --- | --- |
| `cpu_hold` | out | **电平**。`busy` 的别名。整个事务期间为高，事务结束后一拍释放。系统层把它接到 `nes_cpu_bus` 的 `bus_hold`。 |
| `cpu_read_req` | out | **电平**，不是脉冲。拉高表示"我要读一个字节"，并保持到 `cpu_read_ack` 出现。 |
| `cpu_read_addr` | out | 请求对应的 16 位 CPU 地址，事务期间单调递增 `$xx00 -> $xxFF`。 |
| `cpu_read_ack` | in | 总线侧授权。**可以延迟任意多个周期**，也可以和 `cpu_read_req` 同拍（零等待）。 |
| `cpu_rdata` | in | 读回来的字节。约定在 `cpu_read_ack` 同拍有效。 |

因为 `cpu_read_req` 是电平、并且 `cpu_read_addr` 只在 ack 时才前进，所以"外部读 ack 可延迟"是免费的：延迟多少个周期，事务就长多少个周期，数据一个字节都不会错。这一点在 `tb_nes_oam_dma` 里被直接验证（见第 6 节）。

### 2.1 关于输入清单里的 `cpu_read_req`

任务描述里 `cpu_read_req` 同时出现在输入和输出清单里。Verilog 的一个模块不允许两个同名端口，而这套握手必须有且只有一个请求方向的信号，因此本模块的取舍是：

- **输出**保留 `cpu_read_req`（它和 `cpu_read_addr`、`cpu_read_ack`、`cpu_rdata` 构成完整握手，是必需信号）；
- **输入**侧只保留 `cpu_read_ack` 和 `cpu_rdata` 两个真正有语义的信号，输入清单里的那个 `cpu_read_req` 视为对同一个信号的重复列举。

如果系统层需要一个"允许 DMA 驱动总线"的仲裁使能，应该由系统在 `nes_cpu_bus` 那一层实现（和 DMC 取样的仲裁放在一起），而不是在本模块再加一个输入。

---

## 3. 状态机与周期账

`nes_oam_dma.v` 有四个状态：

| 状态 | 含义 | 拍数 |
| --- | --- | --- |
| `ST_IDLE` | 空闲，等 `start` | 任意 |
| `ST_ALIGN` | dummy / alignment：既不发读请求，也不写 PPU | 1 或 2 |
| `ST_READ` | 发 `cpu_read_req`，等 `cpu_read_ack` | 1 + 等待拍数 |
| `ST_WRITE` | 一次 `$2004` 写 | 1 |

### 3.1 513 / 514 从哪来

```
偶数对齐：  1 (dummy) + 256 x (read + write) = 513
奇数对齐：  2 (dummy + align) + 256 x (read + write) = 514
```

NESdev 的规则是：DMA 若在 CPU 处于偶数周期时启动则耗时 513 周期，奇数周期则 514（多一个对齐周期）。本模块用一个**自由运行的 CPU 周期奇偶位** `parity_q` 实现这条规则：每拍翻转，`start` 被采样时若 `parity_q` 为 1 则 `align_left_q` 装 2，否则装 1。

`parity_q` 是模块内部的。真实系统里这个奇偶应该来自 CPU 的周期计数器；本模块自带计数器的好处是 `nes_oam_dma` 不依赖任何 CPU 状态就能自洽工作，代价是集成时如果系统已经有权威的 CPU 周期计数器，需要把这条规则搬到系统层（见第 7 节）。

### 3.2 拍编号与 `cycle_count`

`cycle_count` 从 `start` 被采样的那一拍开始编号为 1，并在事务期间逐拍加一：

| 拍 | 偶数对齐（`align_left_q=1`） | 奇数对齐（`align_left_q=2`） |
| --- | --- | --- |
| 1 | `ST_ALIGN`（若 `OAMADDR_WRITE=1`，这一拍发 `$2003`） | `ST_ALIGN`（无 PPU 访问） |
| 2 | `ST_READ` #0 | `ST_ALIGN`（发 `$2003`） |
| 3 | `ST_WRITE` #0 | `ST_READ` #0 |
| 4 | `ST_READ` #1 | `ST_WRITE` #0 |
| … | … | … |
| 2+2k | `ST_READ` #k | 3+2k |
| 3+2k | `ST_WRITE` #k | 4+2k |
| 513 | `ST_WRITE` #255，**`done=1`** | — |
| 514 | 空闲，`cycle_count` 保持 513 | `ST_WRITE` #255，**`done=1`** |
| 515 | — | 空闲，`cycle_count` 保持 514 |

由此得到三条不变量，testbench 逐拍核对：

1. `cpu_hold` / `busy` 恰好为高 513 拍或 514 拍（零等待总线时）。
2. `done` 为高时 `cycle_count` 恰好是 513（偶数）或 514（奇数）。
3. `done` 之后一拍，`busy`、`cpu_hold`、`cpu_read_req`、`ppu_reg_cs` 全部为低，`cycle_count` 保持终值。

### 3.3 `cpu_hold` 什么时候释放

任务描述里"`cpu_hold` 在事务完成后保持"有两种读法，本模块实现的是**"保持到事务完成（含完成拍）"**：

- `cpu_hold` 从 `start` 被采样后的第一拍一直为高，**包括 `done` 为高的那一拍**（那一拍同时是第 256 次 `$2004` 写）；
- `done` 之后**一拍**释放。

这样做的理由是：`done` 与最后一次 PPU 写在同一拍，所以"完成"这一刻总线和 PPU 都还在动，必须让 `cpu_hold` 覆盖它；再往后一拍 CPU 就可以安全恢复。如果系统需要更长的停机（例如等 CPU 自己的 `/RDY` 同步），在系统层对 `done` 做一级锁存即可，模块不需要改。

### 3.4 延迟 ack 时的周期账

`cycle_count` 计的是**实际经过的拍数**，不是标称值。总线每延迟一拍 ack，整个事务就多一拍：

```
cycle_count = 512 + align_len + 256 x (1 + ack_delay)
```

其中 `align_len` 是 1 或 2，零等待时就是 513 / 514。`align_len` 那一拍不受 ack 延迟影响（它是纯空转拍），所以 `OAMADDR_WRITE=1` 时那个 `$2003` 写**不额外占用周期**：它就搭在 dummy 拍里。

---

## 4. `start` 的锁存语义

`start` 上升沿（被采样那一拍）锁存四个量：

| 锁存 | 去向 | 理由 |
| --- | --- | --- |
| `src_page` | `page_q`，`dbg_page` | 之后的 256 次读都用它；`cpu_read_addr` 的高 8 位从此刻起固定。 |
| `src_page` | `read_addr_q = {src_page, 8'h00}` | 第一拍的读地址。 |
| `oam_addr` | `oam_base_q` | 起始 OAM 偏移。 |
| `oam_addr` | `oam_cur_q` | `dbg_oam_addr` 的初值，之后按 255 -> 0 回绕。 |
| — | `index_q = 0` | 已写字节计数。 |

**"锁存"是必需的，不只是整洁。** 真实程序会在启动 DMA 之后继续改自己的变量；软件模拟器里 DMA 是同步函数，根本没有这个问题。硬件上 `cpu_hold` 期间 CPU 改不了任何东西，但 `$4014` 的页字节本身可能在 DMA 启动后被 CPU 覆写（如果 CPU 用自修改代码），所以 `page` 必须是拍下来的值而不是组合读输入。`tb_nes_oam_dma` 的 `test_start_ignored` 就是在 `busy` 期间重新拉 `start` 并检查事务没有被重启或污染。

`busy` 期间的 `start` 被**忽略**（`ST_READ` / `ST_WRITE` / `ST_ALIGN` 分支里没有 `start` 判断）。`reset` 是唯一的中止手段：异步复位会把 `busy`、`cpu_hold`、`cpu_read_req`、`ppu_reg_cs` 全部拉低，`cycle_count` 和 `index_q` 归零。

---

## 5. `OAMADDR` 的两种接法

任务描述给了"固定 `$2004`"和"含 OAMADDR 写入序列"两个选项，本模块用参数 `OAMADDR_WRITE` 把两者都实现出来：

| `OAMADDR_WRITE` | 行为 | 谁来写 `$2003` |
| --- | --- | --- |
| `1'b0`（默认） | `ppu_reg_addr` 恒为 `3'd4`，256 次 `$2004` 写 | CPU 在 `$4014` 之前自己写 `OAMADDR` |
| `1'b1` | 先在 dummy 拍的**最后一拍**发一次 `$2003`（`ppu_reg_addr=3'd3`，`ppu_reg_dout=oam_base_q`），然后 256 次 `$2004` | 本模块代劳 |

默认取 `1'b0`，因为真实硬件就是这样：DMA 引擎不会碰 `OAMADDR`，它只是不停地写 `$2004`，而 `OAMADDR` 的自增和 255 -> 0 回绕发生在 PPU 内部的 OAM 地址寄存器里。`OAMADDR_WRITE=1` 存在的意义是给集成层一个选择：如果系统决定由 DMA 统一管理起始地址（例如省掉 CPU 侧的一次 MMIO 写，或者需要让 DMA 起点可被 testbench 观测），就打开它。

两种接法**产生完全相同的 256 字节 OAM 内容**——因为 `$2003` 写的就是 CPU 本来就写过的那个值。`tb_nes_oam_dma` 用两个实例同时跑同一个激励并逐字节比对，正是钉住这一点：两个实例的 `cpu_read_req` / `cpu_read_addr` / `busy` / `done` / `cycle_count` 必须逐拍相同，唯一的差别是 `OAMADDR_WRITE=1` 的那个实例在 align 阶段多发一次 `$2003`，因此 `ppu_reg_cs` 高的拍数是 257 而不是 256。

---

## 6. 输出稳定性合同

`"所有输出在等待期间稳定"` 在本模块里是靠"所有输出都是寄存器的组合函数"自然成立的，不是靠额外逻辑。逐条：

| 输出 | 在什么窗口里必须稳定 | 靠什么保证 |
| --- | --- | --- |
| `cpu_read_req` | `ST_READ` 期间直到 `cpu_read_ack` | 只由 `state` 决定，`state` 只在 ack 时离开 `ST_READ` |
| `cpu_read_addr` | 同上 | `read_addr_q` 只在 ack 时 `+1` |
| `ppu_reg_cs` / `ppu_reg_we` | `ST_WRITE` 整拍（1 拍脉冲） | 只由 `state` 决定 |
| `ppu_reg_addr` / `ppu_reg_dout` | 同上；align 拍的 `$2003` 同理 | `dout` 来自 `data_q`（ack 时锁存）或 `oam_base_q`（start 时锁存），都是寄存器 |
| `cpu_hold` | 整个事务 | `= busy` |
| `done` | 1 拍 | `= (state==ST_WRITE) && (index_q==8'hFF)` |
| `cycle_count` | 事务期间单调递增，事务后保持终值 | 计数器有显式的"最后一拍不加"判断 |

`cpu_read_req` 与 `ppu_reg_cs` **永不同拍**（一个要求 `state==ST_READ`，另一个要求 `state==ST_WRITE` 或 `ST_ALIGN`）。这一点在 testbench 里被单独断言，因为它是系统层能安全地把 DMA 读和 DMA 写接到同一组 PPU lane 上的前提。

---

## 7. 与 `nes_ppu_sprite.v` / `nes_ppu2c02.v` 的边界

三个模块的职责切分如下。

| 模块 | 拥有 | 不拥有 |
| --- | --- | --- |
| `nes_oam_dma.v`（本文） | DMA 的**时序**、**总线请求/应答**、**CPU 停机**、**`$2003`/`$2004` 的写序列**、`OAMADDR` 的回绕模型 | OAM RAM 本体、`OAMADDR` 的真实自增、`$2004` 的读语义 |
| `nes_ppu2c02.v` | OAM RAM、真实 `OAMADDR` 寄存器、`$2003`/`$2004` 的读写行为、`w` 翻转、可见区 glitch 简化 | DMA 时序、CPU 停机 |
| `nes_ppu_sprite.v` | primary OAM 的**内容语义**（渲染侧只读） | 写入 OAM 的任何通路 |

具体的三条接线约定：

1. **`$2004` 写是外部驱动的。** `nes_oam_dma` 输出的 `ppu_reg_cs` / `ppu_reg_we` / `ppu_reg_addr` / `ppu_reg_dout` 就是 `nes_ppu2c02` 的 `reg_cs` / `reg_we` / `reg_addr` / `reg_din`。接上之后，**真实的 OAMADDR 自增和 255 -> 0 回绕由 PPU 完成**，`nes_oam_dma` 内部的 `oam_cur_q` 只是同构的影子模型，供 `dbg_oam_addr` 观测和 testbench 断言用。两边必须同构，否则"非零 `OAMADDR` + 回绕"这一类行为会分叉。
2. **`$2003` 写与 CPU 侧的 `$2003` 写共用同一个端口。** `OAMADDR_WRITE=1` 时 DMA 会在事务开始那一拍写一次 `$2003`；系统层要么用 `OAMADDR_WRITE=0` 让 CPU 自己写，要么确认这一拍和 CPU 的写入不冲突（`cpu_hold` 已经保证 CPU 不动，但**不要**让 CPU 的 `$2003` 写和 DMA 的 `$2003` 写挂在同一个 mux 上再靠 `cpu_hold` 去选，那会把 `reg_cs` 的时序和 PPU 的 `w` 翻转搅在一起）。
3. **精灵模块不参与。** `nes_ppu_sprite.v` 的 `oam` 是一个 2048 位的**输入总线**，它假设 OAM 内容已经是最终结果。`nes_oam_dma` 写完 256 字节之后，`nes_ppu_sprite` 在下一次可见扫描线上就能看到新的精灵——但如果 DMA 是在可见区中途跑的，那一帧的精灵就是撕裂的。**本模块不检测、也不阻止这件事**：真实硬件同样不阻止，这正是软件必须在 vblank 里做 DMA 的原因。

---

## 8. 明确未实现 / 未建模

- **`$2004` 读、读 `OAMADDR` 期间的缓冲、attr 的 bit2-4 读回 0**：这些属于 `nes_ppu2c02` 的寄存器语义，本模块只发写。
- **可见区 DMA 的渲染 glitch**（Blargg 那些 oam_scanline / oam_stress 测试测的东西）：真实硬件在渲染期间写 `$2004` 会同时破坏 secondary OAM 清除和 sprite 评估。本模块只保证写序列，不建模 PPU 内部被破坏的后果。
- **`$4014` 写入本身的那一拍**：本模块的 `start` 是一个抽象输入。`$4014` 的译码、APU IO lane 上的握手、写入值的来源都在 `nes_cpu_bus` / `nes_apu2a03` 那一层，本模块不碰。
- **多主设备仲裁**：DMC 取样（`nes_apu_dmc.v` 的 `dmc_bus_req`）和 OAM DMA 会争同一条 CPU 总线。真实硬件里 DMC 抢占 OAM DMA 的行为很微妙。本模块假定系统已经仲裁好，`cpu_hold` 和 DMC 的 `dmc_bus_req` 怎么合成一个 `bus_hold` 是系统层的事。
- **CPU 周期奇偶的来源**：见 3.1，`parity_q` 是模块内部的自由运行计数器。
- **奇数帧跳 dot、PAL 制式**：与本模块无关。
- **`OAMADDR_WRITE` 的第三种取值**：只支持 0 和 1；写 2 会被当成 1（Verilog 参数不做枚举检查）。
- **读 ack 到达后的数据有效性检查**：本模块信任 `cpu_rdata` 在 `cpu_read_ack` 同拍有效，不检查时序。
- **testbench 未覆盖**：`ack_delay` 只测到 4；`src_page` 只测了 `$02/$05/$06/$07/$08/$09/$0A/$0B/$0C/$20/$7F/$80/$FF`；没有测同一拍 `start` 与 `reset` 同时到达的竞争（RTL 里异步 `reset` 优先，`tb_nes_oam_dma` 未加断言）；没有用真实的 `nes_cpu_bus` 驱动，而是用 TB 里手写的读总线模型。
- ModelSim/Questa 的 `run_ppu_tb.do` **没有** OAM DMA 通道，`tools/sim_all.ps1` 也不包含 `tb_nes_oam_dma`。这两个脚本不在本任务的写入范围内，没有改。
