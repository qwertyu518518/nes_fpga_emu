# APU 与系统总线的接线：IRQ 注入、`$4000` 路由、采样输出

本文讲 `rtl/nes_core/system/nes_system_v1.v` 这个顶层，也就是 APU v1（`rtl/nes_core/apu/`）第一次被接进 CPU/PPU 的地方。APU 五个通道的**内部语义**已经在 `docs/modules/apu-full.md` 讲过，本文不重复；本文只回答三个“接线层”的问题：

1. **软件模拟器是怎么把 APU 的 IRQ 注入 CPU 的？硬件又是怎么做的？**
2. **系统总线是怎么把 `$4000` 这个地址路由到 APU 的？**
3. **硬件的 frame counter、IRQ 线、sample 输出分别接到哪里，彼此的相位关系是什么？**

行为权威是 NESdev 的 APU / 2A03 / CPU 文档。cNES（`caseif__cNES`，commit `7c8c252`）、C6502（`caseif__c6502`，commit `4f4bf74`）与 Obara（`ObaraEmmanuel__NES`，commit `aa880b9`）只作为“别人怎么写”的观察，用来点出 RTL 容易漏掉的边界，不代表规格。标记约定：`[真值]` 指 NESdev，`[源码观察]` 指这三个仓库。

参考实现：

```text
.slim/clonedeps/repos/caseif__cNES/src/system.c        读/写译码 + IRQ 线回调
.slim/clonedeps/repos/caseif__cNES/src/mappers/mmc3.c  一个真实 mapper 的 IRQ 源
.slim/clonedeps/repos/ObaraEmmanuel__NES/src/apu.c       APU 侧置位/清除 IRQ
.slim/clonedeps/repos/ObaraEmmanuel__NES/src/cpu6502.c   CPU 侧的判定
rtl/nes_core/apu/nes_apu2a03.v                          本仓库 APU 顶层
rtl/nes_core/system/nes_system_v1.v                    本仓库系统顶层
rtl/nes_core/cpu/nes_cpu6502.v                          本仓库 CPU 的中断入口
rtl/nes_core/bus/nes_cpu_bus.v                          独立总线模块（v1 尚未使用）
```

---

## 1. 问题一：软件模拟器怎么把 APU IRQ 注入 CPU

### 1.1 两种模型，差别在“谁持有中断状态”

真硬件上 APU 与 CPU 之间只有**一根电平线**（2A03 的 `IRQ` 输出）。这条线：

- 由 APU 内部的一个 flag 驱动（frame IRQ）或由 DMC 驱动（`$4010[7]` 使能的 DMC IRQ）；
- **锁存在 APU 里**，不是边沿脉冲；
- 保持有效直到软件去 ack —— 唯一的 ack 手段是读或写 `$4015`（`$4015` 读清 frame IRQ 与 DMC IRQ；写 `$4015` 也清 frame IRQ；写 `$4017[6]=1` 额外清 frame IRQ）；
- CPU 侧只看**电平**，`I` 标志为 0 时取指边界采样到就响应。

软件模拟器一般不做一根真实导线，而是用**软件 pending 位**代替它。于是分成两派：

| | 状态放在哪 | CPU 怎么感知 | 代表实现 |
| --- | --- | --- | --- |
| **A. 粘滞位 + 指令边界轮询** | CPU 的 `interrupt` 位掩码 | CPU 每条指令前读这个掩码 | `[源码观察]` Obara `ctx->interrupt` |
| **B. 回调函数（惰性求值）** | mapper / 子系统的私有状态 | CPU 需要 IRQ 时**调用**一个函数去问 | `[源码观察]` cNES `g_irq_line_callback` |

### 1.2 A 派：粘滞位

`Obara` 的 `apu.c` 在 frame sequencer 走到带 `FRAME_IRQ` 指令的那一步时**不立即**改 CPU，而是先置一个自己的标志：

```c
if (directive & FRAME_IRQ) {
    apu->frame_interrupt = 1;
    apu->irq_should_set = 1;      // "We need to delay IRQ line assertion by one clock"
}
...
if (apu->irq_should_set) {       // 下一拍
    if (!apu->IRQ_inhibit)
        interrupt(&apu->emulator->cpu, APU_FRAME_IRQ);
    apu->irq_should_set = 0;
}
```

`interrupt(&cpu, APU_FRAME_IRQ)` 只是往 `ctx->interrupt` 这个位掩码里 OR 一个 bit。CPU 侧：

```c
static void poll_interrupt(c6502* ctx) {
    if (ctx->interrupt & ~IRQ || (ctx->interrupt & IRQ && !(ctx->sr & INTERRUPT))) {
        ctx->polled_interrupt = ctx->interrupt;
    } else {
        ctx->polled_interrupt = 0;
    }
}
```

也就是说“`irq && !I`”这个判定被放在 CPU 的 `poll_interrupt()` 里，APU 只需要负责把自己的 bit 置上 / 清掉。ack 也是 APU 主动做的：`$4015` 读时 `interrupt_clear(&cpu, APU_FRAME_IRQ)`（`[源码观察]` `apu.c:540` 附近与 `write_status()`）。

**这与真硬件是同一个行为**，只是把“导线”换成了“共享内存里的一个 bit”。它有一个必然的代价：**软件必须保证 APU 每周期都被调用**。`interrupt()` 发生在那条唯一的 `execute_apu()` 调用链上；一旦某个循环忘了调，IRQ 永远不会来。这也是所有软件模拟器里最容易出现的一类 bug。

### 1.3 B 派：回调

cNES 走的是另一条路。总线层只提供一个函数指针：

```c
static unsigned int (*g_irq_line_callback)(void);
...
unsigned int system_read_irq_line(void) {
    return g_irq_line_callback != NULL ? g_irq_line_callback() : 1;
}
```

mapper 在自己的初始化里注册：

```c
static unsigned int _mmc3_irq_connection(void) {
    return g_asserting_irq && g_irq_enabled ? 0 : 1;
}
...
system_connect_irq_line(_mmc3_irq_connection);
```

注意这个回调的**极性是反的**：返回 `0` 表示 IRQ 有效。这不是笔误，而是把 CPU 的 `IRQ` 输入极性（`[真值]` 6502 的 `IRQ` 是低有效）直接搬到了函数返回值上。`system_read_irq_line()` 在没注册回调时返回 `1`（未中断），这个默认值很重要：新接的 mapper 如果忘了注册，整机会静默地没有 IRQ，而不是每次都中断。

B 派的好处是**多源天然支持**：MMC3、Namco-104、NROM 的 `$4014`（若实现）等等都可以各自注册一条，谁想抬 IRQ 就把自己的状态置起来，不需要 CPU 侧有任何改动。

### 1.4 本仓库的 CPU 接口：不是边沿，也不是 pending 寄存器

`rtl/nes_core/cpu/nes_cpu6502.v` 的接口只有两根线：

```verilog
input  wire nmi_i,          // 电平，CPU 内部做上升沿检测 + 锁存
input  wire irq_i,          // 电平，无锁存
output wire dbg_irq_pending // = irq_i，只是观测
```

- **NMI** 有内部锁存：`nmi_rise = nmi_i && !nmi_sync_reg;`，上升沿把 `nmi_pending_reg` 置 1，在 `ST_FETCH` 被采样并进入 7 周期入口。因为 NMI 脉冲只有几十 ns，硬件上必须靠这个锁存。
- **IRQ 没有锁存**。判定就写在取指状态里：

```verilog
end else if (irq_i && !p_reg[2]) begin
    illegal_reg    <= 1'b0;
    int_kind_reg   <= INT_IRQ;
    int_pc_push_reg<= pc_reg;
    int_push_b_reg <= 1'b0;
    state_reg      <= ST_INT_DUMMY2;
end
```

这与 `[真值]` 一致：6502 的 IRQ 是**电平**，`I` 置 1 就屏蔽，屏蔽期间线上的电平变化不记忆（不像 NMI 会 pending）。软件必须在自己的服务例程里 ack 源，否则 `RTI` 之后立刻又进一次。

因此 `nes_system_v1` 做的接线只有一根线：`.irq_i(apu_irq)`。没有锁存、没有 pending、没有与 mapper IRQ 的或 —— 因为 mapper IRQ 还不存在（见第 5 节）。

### 1.5 IRQ 入口的三个容易被忽略的细节

`nes_cpu6502.v` 的中断入口序列是 7 个总线周期：

| 状态 | `bus_addr` | 副作用 |
| --- | --- | --- |
| `ST_FETCH` | `pc_reg` | 判定并锁存 `int_kind_reg` / `int_pc_push_reg`，`pc_reg` **不前进** |
| `ST_INT_DUMMY2` | `pc_reg` | 假读（真 6502 在这里多一个总线周期） |
| `ST_INT_PUSH_HI` | `$01xx` | 压入 `pc` 高字节，`sp--` |
| `ST_INT_PUSH_LO` | `$01xx` | 压入 `pc` 低字节，`sp--` |
| `ST_INT_PUSH_P` | `$01xx` | 压入 `P`，`sp--`，**并置 `I`** |
| `ST_INT_VEC_LO` | `$FFFE`（IRQ/BRK）或 `$FFFA`（NMI） | 取向量低字节 |
| `ST_INT_VEC_HI` | 向量+1 | 取向量高字节，装入 `pc` |

三个细节：

1. **`pc_reg` 在 `ST_FETCH` 不前进**，所以被压栈的是“下一条指令的地址”，`RTI` 之后正好回到被打断的那条指令上。
2. **入栈的 `P` 是 `(p_reg | 0x20)`，IRQ 时 bit4 恒为 0**：

   ```verilog
   assign interrupt_push_data = (p_reg | 8'h20) | (int_push_b_reg ? 8'h10 : 8'h00);
   ```

   `int_push_b_reg` 只有 `BRK` 会置 1。这给了 testbench 一条很好用的判据：“bit4 == 0” 就说明 CPU 走的是 IRQ 入口而不是撞上了 `BRK` 指令（撞 `BRK` 时向量地址同样是 `$FFFE`，只靠向量地址分不出来）。
3. **`I` 是在 `ST_INT_PUSH_P` 置的**，不是在判定的那一刻。所以从判定到例程第一条指令之间，CPU 已经被屏蔽了；例程里必然 `I == 1`，`RTI` 之后恢复成被压进去的那个值。

`tb/system/tb_nes_system_audio.v` 把这三条都写成了断言：入口恰好 7 个 CPU 周期（`cpu_cycle` 差值）、`$01FC/$01FB/$01FA` 的数据与 `bit4 == 0`、例程内 `P[2] == 1` 且 `sp == $FA` 而回到主循环后 `P[2] == 0` 且 `sp == $FD`。

---

## 2. 问题二：`$4000` 怎么被路由到 APU

### 2.1 软件里这就是一个 `if` 链

`[源码观察]` cNES 的 `system.c`：

```c
uint8_t system_lower_memory_read(uint16_t addr) {
    if (addr >= 0x0000 && addr <= 0x1FFF)      return system_ram_read(addr % SYSTEM_MEMORY_SIZE);
    else if (addr >= 0x2000 && addr <= 0x3FFF) return ppu_read_mmio((uint8_t)(addr % 8));
    else if (addr == 0x4014)                 { /*TODO: DMA register*/ return 0; }
    else if ((addr >= 0x4000 && addr <= 0x4013) || addr == 0x4015) { /*TODO: APU MMIO*/ return 0; }
    else if (addr >= 0x4016 && addr <= 0x4017) return 0x40 | controller_poll(addr - 0x4016);
    else                                      return system_bus_read();  // open bus
}
```

三点值得注意：

- **APU 的窗口是被拆开的**：`$4000-$4013` 与 `$4015` 归 APU，`$4014` 单独归 OAM DMA，`$4016-$4017` 归控制器（读出 bit0/bit1 串行移位），`$4017` 在真机上**同时**是 APU 的帧计数器寄存器（写）与控制器端口（读）。这正是为什么软件用 5 个分支而不是一个区间。
- **读和写的分支是两份**，`addr % 8` / `addr % 2` 这种折叠也各自写一遍。折叠在这里是安全的，因为 `$2000` 与 `$4000` 都是 8 或 5 位的寄存器堆。
- **open bus 显式存在**：`system_bus_read()` 在没有 cartridge 的地址上返回什么是有定义的。

### 2.2 `nes_system_v0`：整段是常量 `$00`

v0 的读 mux 是：

```verilog
case (cpu_addr[15:13])
    3'b000: cpu_din = cpu_ram[ram_index];
    3'b001: cpu_din = ppu_reg_dout;
    3'b010: cpu_din = 8'h00;      // $4000-$5FFF 整段常量 0
    3'b011: cpu_din = 8'h00;
    default: cpu_din = prg_rom[prg_index];
endcase
```

写侧没有 APU 分支，`$4000-$5FFF` 的写被**完全忽略**。也就是说 v0 里 `$4017` 写进去什么都不发生，`$4015` 读回来永远是 `$00` —— CPU 的 IRQ 脚被接成 `1'b0`。这个形状的好处是它把“没接的东西”写成了**确定的**行为（读 0、写忽略）而不是 `X`，因此 testbench 可以直接对 `$4000` 写忽略做断言。

### 2.3 `nes_system_v1`：加一层 `sel_apu` 与一个完成脉冲

v1 增加的东西很少：

```verilog
assign sel_apu = (cpu_addr[15:5] == APU_PAGE_HIGH) && (cpu_addr[4:0] <= APU_REG_LAST);
assign apu_reg_cs = cpu_bus_fire && sel_apu;
...
3'b010: cpu_din = sel_apu ? apu_reg_dout : 8'h00;
```

`$4000-$4017` 是**连续**的 24 个地址，APU 的 `reg_addr` 恰好是 5 位，所以**不需要任何折叠或偏移**，低 5 位直接透传。这与 PPU 的 `$2000-$3FFF → reg_addr[2:0]` 是同一种“镜像窗口 + 截断”的手法。

`apu_reg_cs` 的定义是这一节的重点：**它不是地址译码，是“这一次 CPU 总线事务恰好在这一拍完成”**。三根线各司其职：

| 信号 | 语义 | 宽度 |
| --- | --- | --- |
| `sel_apu` | 地址译码，纯组合，与有没有发生访问无关 | 跟随 `cpu_addr` |
| `apu_reg_we` / `apu_reg_din` | 方向与写数据，来自 CPU | 跟随 `cpu_addr` |
| `apu_reg_cs` | **副作用的唯一合法时刻** | 1 个 `clk` |

为什么必须是脉冲而不是“级”信号？因为 APU 寄存器带副作用：

| 访问 | 副作用 |
| --- | --- |
| 读 `$4015` | 清 frame IRQ + 清 DMC IRQ |
| 写 `$4015` | 清 frame IRQ；改写四个通道的使能；被禁用的通道长度清零 |
| 写 `$4017` | 重启 frame counter；`bit6` 置 1 时清 frame IRQ |
| 写 `$4003` / `$4007` / `$400B` / `$400F` | 装长度计数器（需通道已使能）、重置 duty/tri 序列、清 envelope |
| 写 `$4000` / `$400C` | 重置 envelope 计时 |

`nes_apu2a03.v` 里这些副作用的判定全部是 `reg_cs && reg_we && (reg_addr == ...)`。如果 `reg_cs` 是“请求级”信号（在整个等待期保持有效），一次 `$4015` 读会在等待的每一拍都清一次 IRQ；如果 `reg_cs` 干脆就是 `sel_apu`，那么只要 CPU 的 `bus_addr` 停在某个地址上（等待态、或者 `ST_INT_VEC_LO` 之类的固定地址），寄存器就会被反复写入。

本仓库的 `bus_ready` 恒等于 `!reset`（`nes_system_v1` 直接写死，没有等待状态机），所以 `cpu_bus_fire = bus_req && !reset` 而 `bus_req` 只在 `ce_cpu` 有效拍拉高 → `apu_reg_cs` 天然与 `ce_cpu` 同相、宽度恒为 1 拍。这是**当前实现的性质，不是合同**：一旦将来把 `nes_cpu_bus.v`（带等待计数器）接进来，`apu_xfer` 仍然是 1 拍，但 `apu_reg_cs` 的对齐关系就要重新验证。`nes_cpu_bus.v` 里对应的是：

```verilog
assign apu_req  = cpu_req && !bus_hold && (owner_r == OWNER_APU_IO);
assign apu_xfer = cpu_fire && (owner_r == OWNER_APU_IO);
assign apu_wr   = apu_xfer && cpu_we;
```

即**级信号给流水线用、脉冲信号给副作用用**，与 `docs/modules/cpu-bus.md` 的一致结论。

### 2.4 `$4014`：既不是 APU 寄存器也不是 open bus

`$4014`（OAM DMA）在 v1 里落在 `sel_apu` 内，会被送到 APU 的 `reg_addr = 5'h14`。APU 内部只有 `reg_addr[4:2] == 3'd5` 才进状态/帧计数器分支，而 `$4014`、`$4016` 既不等于 `5'h15` 也不等于 `5'h17`，于是：

- 读 → `reg_dout` 的 `default: 8'h00` → 返回 `$00`；
- 写 → `reg_wr_status` 与 `reg_wr_frame` 都不匹配 → 没有任何副作用。

v1 额外加了两个观测口，把这个“被记录但被忽略”的语义显式化：

```verilog
assign oam_dma_req = cpu_bus_fire && sel_apu && (cpu_addr[4:0] == APU_REG_DMA);
assign oam_dma_count = oam_dma_count_reg;   // 8 bit，复位清零，每次 req 加一
```

这样“DMA 没实现”这件事在接口上就是一个**可观测的空操作**，而不是一个未定义行为。`tb_nes_system_audio.v` 的程序读一次 `$4014` 并断言返回 `$00`、`oam_dma_count` 变成 1，两条都成立才算过。

**明确不做的事**：没有 DMA 状态机、没有 `RDY` 拉低、没有 513/514 个 stolen cycle、没有 OAM 写入、`oam_dma_count` 不会导致任何 CPU 停顿。`$4014` 的完整语义属于 `docs/modules/cpu-bus.md` 描述的总线仲裁层，不在 v1 的范围里。

### 2.5 一个真实的坑：`$4000-$4017` 的上界不能用 `!cpu_addr[4]`

`$4000-$401F` 是 32 个地址。直觉上会写成 `cpu_addr[15:5] == 11'h200 && !cpu_addr[4]`，意思是“低 5 位最高位为 0”。但 `$4010-$401F` 的 **bit4 全是 1**，所以这个条件实际只覆盖 `$4000-$400F`，会把整个 `$4010-$4017`（含 `$4015` 与 `$4017`）挡在桥外。

正确写法必须对 5 位下标整体比较：

```verilog
assign sel_apu = (cpu_addr[15:5] == APU_PAGE_HIGH) && (cpu_addr[4:0] <= APU_REG_LAST);
```

这个错误在本次开发中真实出现过：testbench 第一次运行就报 `cpu write to an unmapped region at 4017`（因为 testbench 独立地断言“所有写都必须落在 RAM / PPU / APU 之一”，这条地址区间账立刻不平）。

### 2.6 与 `nes_cpu_bus.v` 的已知分歧

`rtl/nes_core/bus/nes_cpu_bus.v` 的译码是：

```verilog
3'b010: owner_r = (cpu_addr[15:5] == 11'b01000000000) ? OWNER_APU_IO : OWNER_OPEN;
```

它把 `$4000-$401F` 整段归 APU_IO（并且 `apu_addr = cpu_addr[4:0]`，所以 `$4018-$401F` 会折回 `$4000-$4007`），而 `nes_system_v1` 用的是更紧的 `$4000-$4017`。

这两个范围**在功能上等价**，因为 `$4018-$401F` 折回后的 `reg_addr[4:2] ∈ {6, 7}`，在 `nes_apu2a03.v` 里既不是任何通道（`3'd0..3'd4`）也不是状态/帧计数器（`3'd5`）—— 读回 0、写忽略。差别只在**卫生层面**：一旦将来 APU 增加了落在 `reg_addr[4:2] == 6/7` 的寄存器（例如 `$4016` 的控制器读，或者一个未来的扩展），宽窗口就会静默产生错误路由。

`nes_system_v1` 目前**没有**例化 `nes_cpu_bus.v`（它用的是 v0 那套内联的组合 mux + 同步 RAM），所以这个分歧现在不会出错，但它是 `nes_system_v1` 下一步接 `$4016` 控制器之前必须先统一的东西。合并时应当以 `nes_cpu_bus.v` 为准把上界改成 `cpu_addr[4:0] <= 5'h17`，或者在两边共用一个 `sel_apu_io` 表达式。

---

## 3. 问题三：frame counter、IRQ、sample 输出怎么连

### 3.1 三条独立的使能

`nes_system_v1` 沿用 v0 的 12 拍 `div_phase`：

```verilog
assign ce_ppu = !reset && (div_phase[1:0] == 2'b00);   // 12 拍中 3 拍：1 dot = 4 clk
assign ce_cpu = !reset && (div_phase == 4'd0);         // 12 拍中 1 拍：1 CPU 周期
assign ce_sample = 1'b1;                                // APU 采样使能
```

`div_phase` 是 12 拍而不是 4 拍，意味着 `clk` 的标称是 **21.477 MHz**（12 × 1.789 MHz），也就是 NTSC CPU 时钟的 12 倍过采样。testbench 里的 `always #5 clk`（10 ns 周期 = 100 MHz）只决定仿真快慢，不改变任何周期比例：帧长恒为 `262 × 341 × 4 = 357368` 个 `clk`，即 `29780.67` 个 CPU 周期。

APU 的例化是：

```verilog
nes_apu2a03 u_apu (
    .clk(clk), .reset(reset),
    .ce(ce_cpu),          // frame counter 与全部通道 timer 都按 CPU 周期推进
    .ce_sample(ce_sample),
    .reg_cs(apu_reg_cs), .reg_we(cpu_we),
    .reg_addr(cpu_addr[4:0]), .reg_din(cpu_dout), .reg_dout(apu_reg_dout),
    .irq(apu_irq),
    .dmc_rdata(8'h00), .dmc_ack(1'b0),
    .sample_valid(...), .sample_left(...), .sample_right(...),
    ...
);
```

**`ce = ce_cpu` 而不是 `ce_ppu`**，这是必须的：NES 的 frame sequencer 是按 CPU 周期（1.789 MHz）计数的，4 步序列 29830 拍 ≈ 1.0017 个视频帧，对应约 60.0 Hz 的中断率。若误接到 `ce_ppu`（3 倍速率），IRQ 周期会变成 9943 个 CPU 周期，帧率变成 180 Hz —— `tb_nes_system_audio.v` 的逐 strobe `div_phase` 断言会在第一次 sample 脉冲上就失败。

### 3.2 sample 输出：这是一根 strobe 线，不是一根音频线

`nes_apu2a03.v` 的采样逻辑只有三行：

```verilog
if (ce && ce_sample) begin
    sample_valid <= 1'b1;
    sample_left  <= mixed_sample;
    sample_right <= mixed_sample;
end else begin
    sample_valid <= 1'b0;
end
```

`ce_sample` 恒为 1 时，`sample_valid` 就是**每个 `ce` 沿之后高 1 个 `clk` 的脉冲**，即 1.789 MHz 速率、占空比 1:12 的 strobe，波形上只落在 `div_phase == 1` 那一拍。这与 `docs/modules/apu-full.md` 第 1 节的“轴 D”对应：真硬件里这一拍会进一个模拟低通滤波器并被宿主音频设备抽取，RTL 里既没有滤波器也没有抽取器。

因此 `audio_sample_valid` 的正确读法是“**这里有一个新的混音输出**”，而不是“这里有一个该播的音频样本”。下游必须自己做抽取（例如每 37 或 38 个 `ce` 取一个，落到 48.3 kHz）以及低通。`docs/hardware/08-wm8978-audio.md` 记录了后续 FIFO 的方向，本次没有实现。

`sample_left` / `sample_right` 当前**完全相同**（都是 `mixed_sample`）。NES 真机左右声道差异来自模拟负载矩阵（$4015 bit7 控制），本仓库的混音器是纯整数 LUT，所以没有这个差异。

### 3.3 IRQ：两个 flag 的或，且不锁存

```verilog
assign irq = frame_irq_flag | dmc_irq_flag;
```

- **frame IRQ flag** 由 frame sequencer 在 4 步模式的第 4 步置位（5 步模式不置位），由 `$4015` 读/写或 `$4017[6]=1` 写清除。
- **DMC IRQ flag** 由 `$4010[7]` 使能、DMC 采样缓冲区空时置位；由 `$4015` 读或写**无条件**清除（`dmc_status_clear = reg_wr_status || reg_rd_status`），另外写 `$4010[7] = 0` 也清。
- 两者都受 `frame_inhibit`（`$4017[6]`）约束 —— 注意 `$4017[6]` 是**禁止** frame IRQ，写 `$40` 会让 frame IRQ 永远不来。`tb_nes_system_audio.v` 的程序写的是 `$00`，第一次写成 `$40` 时 testbench 报 `only 0 frame irq periods were measured`。

`$4015` 的读回值在 `nes_apu2a03.v` 里是 `{dmc_irq_flag, frame_irq_flag, 1'b0, dmc_active, noise_len!=0, tri_len!=0, pulse2_len!=0, pulse1_len!=0}` —— 即 bit7 = DMC IRQ、bit6 = frame IRQ、bit5 未用（恒 0）、bit4 = DMC 仍在取数、bit3:0 = 四个通道的长度计数器非零。这也是软件 ack frame IRQ 的标准手法（`LDA $4015 / STA $4015`）：读回来的 bit6 就是“刚才被清掉的那个标志”，写回去既 ack 了 IRQ 又把长度状态原样还原。

frame sequencer 的关键计数点是（`nes_apu2a03.v` 的 localparam）：

| 常量 | 值 | 含义 |
| --- | --- | --- |
| `FC_QUARTER_1` | 7456 | quarter frame 1（envelope） |
| `FC_QUARTER_2` | 14912 | quarter + half（长度计数器、sweep） |
| `FC_QUARTER_3` | 22370 | quarter |
| `FC_STEP_4` | 29828 | 4 步：**置 frame IRQ flag**；5 步：idle |
| `FC_STEP_5` | 37280 | 5 步：quarter + half，不置 IRQ |
| `FC_END_4` | 29829 | 4 步驻留计数（下一拍归零） |
| `FC_END_5` | 37281 | 5 步驻留计数 |

所以 4 步模式的 frame IRQ 在**第 29829 个 `ce` 沿**抬起来，随后 `frame_count` 驻留在 29829 一个 `ce` 拍再归零，整个序列 29830 `ce` 一轮。`irq` 是**电平**（不是脉冲），`frame_irq_flag` 归零它就落。

### 3.4 完整接线表

| APU 侧 | 系统侧 | 目的地 | 性质 |
| --- | --- | --- | --- |
| `ce` | `ce_cpu` | frame sequencer、四个通道 timer、LFSR、长度计数器 | 每 12 拍 1 拍 |
| `ce_sample` | `1'b1` | sample 输出寄存器 | 每拍都有效 |
| `reg_cs` | `cpu_bus_fire && sel_apu` | 全部寄存器副作用 | 1 拍，与 `ce_cpu` 同相 |
| `reg_we` | `cpu_we` | — | 跟随 `bus_we` |
| `reg_addr` | `cpu_addr[4:0]` | 5 位寄存器下标 | 直接透传 |
| `reg_dout` | `cpu_din`（`3'b010` 分支） | CPU 读数据 | 组合，仅 `reg_cs` 时有效 |
| `irq` | `apu_irq_o` → `u_cpu.irq_i` | CPU 中断入口 | 电平，`!P[2]` 时在 `ST_FETCH` 采样 |
| `sample_valid` | `audio_sample_valid` | 下游抽取器 | 1 拍脉冲，1.789 MHz |
| `sample_left/right` | `audio_sample_left/right` | 下游抽取器 | 16 bit，1.79 MHz 速率 |
| `dmc_bus_req` / `dmc_addr` | **悬空** | — | DMC DMA 未接 |
| `dmc_rdata` | `8'h00` | DMC | 常 0 |
| `dmc_ack` | `1'b0` | DMC | 恒不 ack |

最后三行是本版本最脆的地方：`dmc_ack` 恒 0 之所以没有出问题，**只是因为没有任何程序写过 `$4010-$4013`**。一旦有程序启动 DMC 采样，`nes_apu_dmc` 会一直等 `dmc_ack`，`dmc_bus_req` 永远高，APU 的 `ce` 通道表面上还在跑但 DMC 状态机会永久卡住。`tb/system/tb_nes_system_audio.v` 断言 `dbg_dmc_irq` 永不抬升，那只能证明**本程序**没碰 DMC，不能证明这条线路是安全的。

### 3.5 三条时间轴的相位关系

把 CPU、frame sequencer、sample strobe 画在同一个时间轴上（`ce_cpu` 拍序号）：

```text
ce 序号   0    1    2    3  ...  7456  7457  ... 14912 14913 ... 29828 29829 29830 29831 ...
          |    |    |    |         |     |        |     |       |     |     |     |
CPU 总线  X    .    .    .         .     .        .     .       .     .     .     .
frame seq 0    1    2    3        7456  7457    14912 14913   22370 29828 29829 29830
Q/H action -    -    -    -         Q     -        Q+H   -        Q   -    -    -
sample     S    S    S    S         S     S        S     S       S     S     S     S
                     ^
                     $4017 写在这一拍把 frame_count 清 0（写的那一拍不计数）
```

要点：

1. **`$4017` 的写不占用一个 `ce` 拍**。APU 里是 `if (reg_wr_frame) frame_count <= 0; else if (ce) frame_count <= frame_count + 1;`，所以写 `$4017` 之后的第一个 `ce` 沿才让 `frame_count` 从 0 变成 1。
2. **frame IRQ 在 `ce` 沿上抬起来之后，下一拍 CPU 才可能在 `ST_FETCH` 看到它**。`irq` 是组合输出，`cpu_bus_fire` 与 `ce_cpu` 同相，所以 CPU 看到 `irq_i == 1` 的第一个 `ST_FETCH` 就是紧随其后的那一个。
3. **例程里 `LDA $4015` 的清零发生在 ST_DATA 那个总线周期上**，而 IRQ 判定发生在它之前 7 个周期。也就是说从 IRQ 抬起到 flag 被清，中间有 7 + 4 = 11 个 CPU 周期的时间窗；只要这个窗短于 29830 个 `ce`（真实硬件的 16.7 ms），就不会出现“例程还在跑、第二个 IRQ 已经来了”的情况。这也是 v1 的 IRQ 天然可重入的原因。

---

## 4. 与 `nes_system_v0` 的差异清单

`nes_system_v1` 与 `nes_system_v0` 的差异只有 6 处，其余（`div_phase`、RAM、PRG 镜像、读 mux 的另外 4 个分支、CPU 与 PPU 的例化、PPU 参数）逐字相同：

| # | 差异 | 影响 |
| --- | --- | --- |
| 1 | 新增 `sel_apu` 与 `apu_reg_cs` | `$4000-$4017` 从常量 0 变成真实 APU |
| 2 | 读 mux 的 `3'b010` 分支从 `8'h00` 变成 `sel_apu ? apu_reg_dout : 8'h00` | CPU 读通路多一级 2:1 mux |
| 3 | CPU `irq_i` 从 `1'b0` 变成 `apu_irq` | 打开 IRQ 入口 |
| 4 | 新增 `u_apu` 例化 | M9K 占用增加；`nes_apu2a03` 间接例化 5 个子模块 |
| 5 | 新增 `oam_dma_count_reg`（8 bit 寄存器） | 1 个 FF 组 |
| 6 | 新增 5 个输出端口 | 只是观测，不消耗内部资源 |

`nes_system_v0` 本身**没有被修改**，两个顶层并列存在，v0 的两个 testbench 完全不受影响。

---

## 5. 明确未实现与已知风险

- **OAM DMA（`$4014`）**：只有“被记录”（`oam_dma_req` / `oam_dma_count`），没有状态机、`RDY` 拉低、stolen cycle、OAM 写入。
- **DMC DMA**：`dmc_bus_req` / `dmc_addr` 悬空，`dmc_ack` 恒 0。**没有保护阻止程序启动 DMC 后死等**。
- **mapper IRQ**：`$8000-$FFFF` 没有 mapper 寄存器，`apu_irq_o` 是 `irq_i` 的唯一驱动源。接 mapper 时正确的做法是 `irq_i = apu_irq | mapper_irq`（或回到 `nes_cpu_bus.v` 的 `system_read_irq_line()` 那种多源模型），**不要**改成让 APU 内部去感知 mapper。
- **`$4016` 控制器**：没有串行移位寄存器、 strobe 时序、`$4016[0]` 写触发。当前 `$4016` 落在 `sel_apu` 内，读 `$00`、写忽略。
- **`$4015[7]` DMC IRQ 使能位**：APU 已经实现（`reg_dout` 的 bit7 报 DMC IRQ，写 `$4015` 无条件清 DMC IRQ flag），但因为 DMC DMA 未接，这一位没有可观察的后果。
- **音频抽取 / FIFO / WM8978 接口**：不存在。`audio_sample_valid` 是 1.789 MHz 的 strobe。
- **左右声道差异 / `$4015[7]` 负载矩阵**：不存在。
- **`nes_cpu_bus.v` 与 `nes_system_v1` 的 `$4018-$401F` 译码分歧**：见 2.6，功能等价但需要统一。
- **时序未经 Fitter 验证**：读通路多一级 mux 这件事在 EP4CE10 上的实际影响没有综合数据。
- **APU IRQ 屏蔽语义**：CPU 侧 `irq_i && !p_reg[2]` 意味着 `SEI` 期间 APU 的 frame IRQ 会被丢掉（不 pending）。这是 `[真值]` 行为，但本仓库的 APU **不会**因此“补发”一次，与真机一致。

---

## 6. 验证

`tb/system/tb_nes_system_audio.v` 是这套接线的端到端 testbench，程序是：关掉渲染 → `$4017 = $00`（4 步、允许 frame IRQ、重启计数）→ 读一次 `$4015` 确认是 `$00` → 使能 pulse1 → 配置 `$4000-$4003`（duty 2、恒定音量 15、周期 32、长度表索引 8 = 160）→ 关掉 PPU → 读 `$4014` / `$4018` / `$401F` 确认都是 `$00` → 自跳等 IRQ。`$FFFE/$FFFF` 指向 `$8200` 的服务例程：`LDA $4015`（读即 ack）→ `STA $4015`（写回确认）→ RAM 计数 +1 → `RTI`。

跑满 3 个 PPU 帧后它断言的要点（完整清单见 `tb/system/README.md` 的“APU testbench”一节）：

- frame IRQ 恰好 2 次、相隔 29830 个 `ce`、每次都在 `frame_count == 29829` 时抬；
- `apu_irq_o === (dbg_frame_irq | dbg_dmc_irq)` 与 `dbg_irq_pending === apu_irq_o` 逐 `clk` 成立；
- handler 进入 2 次、入口恰好 7 个 CPU 周期、入栈 PC 与 `P` 正确且 `P[4] == 0`；
- `apu_irq_o` 上升沿数 == 下降沿数（每一次都被 ack 清掉），结束时为低；
- `apu_reg_cs` 恒为单拍、恒与 `ce_cpu` 同相、恒落在 `$4000-$4017`；`$4018/$401F` 的读不得到达 APU 且读回 `$00`；
- 全部 89343 个 sample strobe 逐个与参考 mixer 表比对，非零 44415 个，峰值 4895，IRQ 服务期间 strobe 不中断；
- PPU 帧周期恒为 357368 `clk`、`frame_done` 落在 `(0,0)`、`PPUCTRL == $00` 使 `nmi_o` 全程为低、`pixel_index` 全程为 0；
- 每一次 `cpu_bus_fire` 都被分类到 `ram / ppu / apu / openbus / prg` 之一且总和自洽。

对 RTL 副本做了 16 个单点变异验证断言非空跑：14 个被抓（断 `irq_i`、断 `apu_irq_o`、IRQ 漏进 `nmi_o`、放宽 `sel_apu`、`reg_cs` 变电平、`reg_addr` 折叠、`reg_we` 恒 1、`ce` 换 `ce_ppu`、`ce_sample` 接 0、`ce_cpu` 挪相位、去掉 APU 读通路、`oam_dma_req` 接 0、`oam_dma_count` 不累加、`apu_irq_o` 取反），2 个是等价变异（`ce_sample` 接 `ce_ppu`，因为 `ce_cpu ∩ ce_ppu == {div_phase == 0}`）。
