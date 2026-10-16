# 系统集成 v0 / v1：最小 CPU+PPU 集成，以及 APU 第一次接入

本文是 `rtl/nes_core/system/nes_system_v0.v` 与 `rtl/nes_core/system/nes_system_v1.v` 的接口与接线合同。它们是本仓库 System 顶层演进链的**起点**，回答两个最基础的问题：

> 一个用 C 写的软件模拟器，把 `switch (address)` 译码、一段 RAM、一段 ROM 和一个"按分频器 tick 的 host loop"放在一个函数里就成了一套机器；Verilog 里最小的可仿真 NES 顶层，长什么样？

结论先行：**v0 只做"让 CPU 和 PPU 能互相跑通"这一件事。** 它没有独立总线模块、没有等待状态、没有 APU / mapper / DMA，所有地址译码都是顶层里一个组合 `case`，所有存储都在核内，`bus_ready` 是一根常电。v0 因此**零等待、时序确定**，代价是"什么都没接"。v1 在 v0 上只加一件事：把 APU 接进来，让 `$4000` 有意义、让 frame IRQ 能注入 CPU、让混音结果有输出口。v1 的 APU 接线本身在 `docs/modules/apu-system.md` 有完整讲解，本文只做概述并指向它。

行为权威是 NESdev 的 CPU 地址图与 2A03 文档；cNES（`caseif__cNES`，commit `7c8c252`）、C6502（`caseif__c6502`，commit `4f4bf74`）与 Obara（`ObaraEmmanuel__NES`，commit `aa880b9`）只作为"别人怎么写"的观察，不是规格。

---

## 1. 文件与层次

```text
rtl/nes_core/system/
├── nes_system_v0.v   CPU + PPU(背景) + 核内 RAM/PRG，bus_ready 常电
├── nes_system_v1.v   v0 + nes_apu2a03、$4000-$4017 路由、IRQ 注入、sample 输出
├── nes_system_v2.v   改用 nes_cpu_bus（真等待态）、精灵、owner/ready 观测口
└── ...                v3 DMA 仲裁、v4 controller、v5 mapper、v6 外部 CHR
```

两个顶层**并列存在**，v1 没有修改 v0 的任何一行；v0 的两个 testbench 与 v1 的 testbench 各测各的。

v0 的内部只有三个子模块：`nes_cpu6502`、`nes_ppu2c02`，以及顶层自己管理的两块存储数组（`cpu_ram`、`prg_rom`）。v1 再加一个 `nes_apu2a03`。

## 2. 端口合同（v0 / v1 合并表）

| 信号 | 方向 | v0 | v1 |
| --- | --- | --- | --- |
| `clk` | in | 单一系统时钟 | 同 v0 |
| `reset` | in | 高有效**异步**复位 | 同 v0 |
| `pixel_valid` / `pixel_x` / `pixel_y` | out | 背景像素；渲染关闭时 `pixel_valid` 仍为高 | 同 v0 |
| `pixel_index` | out | 4 位 NES palette 索引（不是 RGB） | 同 v0 |
| `frame_done` | out | 帧边界脉冲，结算后落在 `(0,0)` | 同 v0 |
| `vblank` | out | 0-based 时序，窗口 `(241,1)..(261,0)` | 同 v0 |
| `nmi_o` | out | `ppu_nmi`，等于 `vblank && PPUCTRL[7]` | 同 v0 |
| `cpu_cycle` | out | 32 位 CPU 总线周期计数 | 同 v0 |
| `ppu_dot` / `ppu_scanline` | out | PPU 0-based dot / scanline 计数 | 同 v0 |
| `apu_irq_o` | out | — | APU 的 `irq`，**同时**是 CPU `irq_i` 的驱动源 |
| `audio_sample_valid` | out | — | APU `sample_valid` 直出；`ce_sample=1` 时等价于一次 `ce_cpu` 的 1 拍脉冲 |
| `audio_sample_left` / `audio_sample_right` | out | — | APU 混音输出，左右相同；只由 `ce_sample` 脉冲有效 |
| `oam_dma_req` | out | — | 1 拍脉冲，"CPU 访问了 `$4014`"；**DMA 本体未实现** |
| `oam_dma_count` | out | — | 8 位粘滞计数，每次 `oam_dma_req` 加一，复位清零 |

模块参数（两版相同）：

| 参数 | 默认 | 合同 |
| --- | --- | --- |
| `PRG_SIZE_BYTES` | `16384` | PRG 存储深度（2 的幂）。16 KiB 时 `$8000-$BFFF` 与 `$C000-$FFFF` 两个窗口完全镜像（NROM-128）。 |

v0 / v1 都把 CPU 与 PPU 的全部 `dbg_*` 端口悬空；testbench 一律通过 `dut.u_cpu.dbg_*`、`dut.u_ppu.*`、`dut.prg_index`、`dut.ram_index` 等层次引用观察内部状态。这与后来的 v2 不同：v2 才把总线与寄存器桥的观测信号提到正式端口上。

## 3. 时钟分配：12 拍 `div_phase` 与 3:1 关系

两版共用同一个自由运行的 `clk`，用一个 4 位相位计数器 `div_phase` 产生使能：

```verilog
always @(posedge clk or posedge reset)
    if (reset)                 div_phase <= 4'd0;
    else if (div_phase == 4'd11) div_phase <= 4'd0;
    else                       div_phase <= div_phase + 4'd1;

assign ce_cpu = !reset && (div_phase == 4'd0);          // 12 拍中 1 拍
assign ce_ppu = !reset && (div_phase[1:0] == 2'b00);    // 12 拍中 3 拍：0,4,8
```

- `div_phase` 走 `0..11`，回卷到 0。
- **1 个 PPU dot = 4 个 `clk`**（`ce_ppu` 每 4 拍一次），**1 个 CPU 周期 = 12 个 `clk`**（`ce_cpu` 每 12 拍一次），CPU : dot 恰好是 **1 : 3**。
- `ce_cpu` 的唯一有效拍 `div_phase==0` 必然是 `ce_ppu` 有效拍，所以 **CPU 与 PPU 永远同相**。后果是每一次 CPU 总线事务都落在一个 PPU dot 上，凡是落在 PPU 地址空间的访问都会顺带吃掉该 dot 的滚动更新——这是 v0 的明确取舍，收益是结构简单、时序确定。

这套 12/4 分频是从 cNES 的 host loop（`g_cycle_index % g_cpu_clock_divider` / `% g_ppu_clock_divider`）抄来的**仿真相位**，`clk` 的标称是 21.477 MHz。它只保证相位与比例，不保证 50 MHz 上板的绝对频率（见第 10 节）。

## 4. v0 的地址译码与存储

### 4.1 译码：顶层一个组合 `case`

v0 没有独立总线模块。地址译码就写在顶层，读数据是一个纯组合 mux：

```verilog
assign sel_ram = (cpu_addr[15:13] == 3'b000);   // $0000-$1FFF
assign sel_ppu = (cpu_addr[15:13] == 3'b001);   // $2000-$3FFF
assign ram_index = cpu_addr[10:0];
assign prg_addr_window = cpu_addr[14:0];
assign prg_index = prg_addr_window[PRG_INDEX_BITS-1:0];

always @* begin
    case (cpu_addr[15:13])
        3'b000: cpu_din = cpu_ram[ram_index];
        3'b001: cpu_din = ppu_reg_dout;
        3'b010: cpu_din = 8'h00;   // $4000-$5FFF：常量 0
        3'b011: cpu_din = 8'h00;   // $6000-$7FFF：常量 0
        default: cpu_din = prg_rom[prg_index];   // $8000-$FFFF
    endcase
end
```

要点：

- `cpu_din` 是**组合**的。这是 v0 的关键简化：读数据不需要时钟沿、不需要握手，只要 `cpu_addr` 稳定，数据就在。
- `$4000-$5FFF`（v0 的 APU 窗口）、`$6000-$7FFF`（iNES 的 PRG RAM 窗口）都读回常量 `$00`，写侧没有任何分支（被忽略）。把"没接的东西"写成**确定的 0** 而不是 `X`，让 testbench 能直接断言。
- `$2000-$3FFF` 整体归 PPU，`reg_addr = cpu_addr[2:0]`，即 8 KiB 窗口每 8 字节折叠一次（`$2000/$2008/.../$3FF8` 都指向 `$2000`）。

### 4.2 2 KiB 工作 RAM 与四路镜像

`cpu_ram` 只有 `0:2047`（2 KiB），而 `$0000-$1FFF` 是 8 KiB。`ram_index = cpu_addr[10:0]` 意味着 **11 位索引**，于是 `$0000-$07FF` 是本体，`$0800-$0FFF`、`$1000-$17FF`、`$1800-$1FFF` 三块都是它的**别名**（4 路镜像）。集成 testbench 对这条镜像写死了断言：`STA $0010` 与 `STA $1810` 写的是同一个 `cpu_ram[16'h010]`，`LDA $1010` 读出 `$5A`。

### 4.3 16 KiB PRG：NROM-128 双窗口

`prg_index` 取 `prg_addr_window[PRG_INDEX_BITS-1:0]`，16 KiB 时是**低 14 位**。`$8000-$BFFF` 与 `$C000-$FFFF` 两个窗口因此都索引到 `prg_rom[0..16383]`，**完全镜像**——这正是 NROM-128 的行为。向量 `$FFFC/$FFFD` 落在上窗口，读出的也是 `prg_rom[13:0]`。`PRG_SIZE_BYTES` 改成 32768 就变成 NROM-256 的两段各 16 KiB，但**仍然没有 bank 切换**，所以不构成任何 mapper 支持。

16 KiB 是 **EP4CE10 的资源收敛结果，不是 mapper 实现**：器件只有 46 个 M9K，16 KiB PRG + 8 KiB CHR RAM + nametable/OAM/palette 已经占掉大半，32 KiB 装不下音频 FIFO 与 VGA 行缓存。

## 5. v0 的简化点（逐条）

1. **`cpu_din` 组合**：读无时序、无握手，见 4.1。
2. **`cpu_ram` / `prg_rom` 在核内**：存储器不是独立模块，写端口是一段 `always @(posedge clk)` 内联逻辑（`if (cpu_bus_fire && cpu_we && sel_ram)`）。没有 `nes_cpu_bus` 的 owner / req / ready 抽象。
3. **`bus_ready(!reset)` 零等待**：CPU 的 `bus_ready` 直接接 `!reset`。因为 `bus_req` 只在 `ce_cpu` 有效拍拉高，`cpu_bus_fire = bus_req && !reset` 天然与 `ce_cpu` 同相、宽度恒为 1 拍。对 CPU 而言，**每一次访存都恰好占 1 个 CPU 周期，等待逻辑从未被执行过**。
4. **无 APU / 无 mapper / 无 DMA**：`$4000` 读 0、写忽略；`$8000-$FFFF` 只是 ROM；`$4014` 未被译码。
5. **副作用绑定完成脉冲**：PPU 的 `ppu_reg_cs = cpu_bus_fire && sel_ppu`，只在事务真正完成的那一拍为高，避免等待期重复执行带副作用的寄存器访问。这一点在 v0 里是"性质"（因为恒 1 拍完成），但它被刻意写成脉冲，为后面的等待总线留接口。

## 6. v0 的向量与 `nmi_o`

- **复位向量**：`$FFFC/$FFFD` 落在 `default` 分支，CPU 从 `prg_rom[13:0]` 取到高地址。testbench 预填 `$FFFC=$00`、`$FFFD=$80`，于是首次取指 PC 是 `$8000`。
- **NMI 向量**：`$FFFA/$FFFB` 同样走 `default`。`nmi_o = ppu_nmi`，而 `ppu_nmi = vblank && PPUCTRL[7]`。PPU 在 `(241,0)` 拉高 `nmi_o`，CPU 内部对 `nmi_i` 做上升沿检测 + 锁存（`dbg_nmi_pending`），走 7 周期入栈序列后从 `$FFFA/$FFFB` 取向量。
- **IRQ 向量**：v0 的 `irq_i` 恒为 `1'b0`，`$FFFE/$FFFF` 链路在 v0 上没有任何系统级覆盖。

集成 testbench `tb_nes_system_v0.v` 与 `tb_nes_system_v0_nmi.v` 分别钉住背景通路（含 `$0000-$1FFF` 镜像、NROM-128 双窗口、一次完整帧的像素）和 NMI 通路（轮询到 vblank → 使能 `PPUCTRL[7]` → `$FFFA` 向量 → 入栈/`RTI` → 帧周期不变）。

## 7. v1 相对 v0 的 delta

v1 与 v0 的差异只有 6 处，其余（`div_phase`、RAM、PRG 镜像、读 mux 的另外四个分支、CPU 与 PPU 的例化、PPU 参数）逐字相同：

1. **新增 `nes_apu2a03` 例化**（`u_apu`），`ce = ce_cpu`、`ce_sample = 1'b1`。
2. **新增 `$4000-$4017` 路由**：

   ```verilog
   assign sel_apu = (cpu_addr[15:5] == 11'h200) && (cpu_addr[4:0] <= 5'h17);
   assign apu_reg_cs = cpu_bus_fire && sel_apu;
   // 读 mux 的 3'b010 分支：
   3'b010: cpu_din = sel_apu ? apu_reg_dout : 8'h00;
   ```

   上界必须写 `cpu_addr[4:0] <= 5'h17`，不能用 `!cpu_addr[4]`：`$4010-$401F` 的 bit4 全是 1，后者会把 `$4015/$4017` 挡在桥外（这个错误真实出现过）。
3. **`irq_i` 从 `1'b0` 变成 `apu_irq`**：APU 的 `frame_irq_flag | dmc_irq_flag` 直接驱动 CPU 的 `irq_i`，**电平、不锁存**。CPU 在 `ST_FETCH` 用 `irq_i && !p_reg[2]` 判定，软件必须自己读/写 `$4015` 去 ack。
4. **新增 `oam_dma_count_reg`**（8 位）：`$4014` 落在 `sel_apu` 内，读回 `$00`、写无副作用，但每次访问让 `oam_dma_count` 加一（"被记录但被忽略"的空操作，而不是未定义行为）。
5. **新增 5 个输出端口**：`apu_irq_o`、`audio_sample_valid`、`audio_sample_left/right`、`oam_dma_req`、`oam_dma_count`。
6. **读通路多一级 2:1 mux**：`3'b010` 分支从常量 `$00` 变成 `sel_apu ? apu_reg_dout : 8'h00`。

`$4018-$5FFF` 在 v1 里仍读回 `$00`、写忽略，与 v0 的 open bus 行为一致。

## 8. v1 的 APU 接入（概述，详见 `docs/modules/apu-system.md`）

v1 是 APU 第一次进系统。它做的三件事，完整推导在 `docs/modules/apu-system.md`：

- **地址路由**：`$4000-$4017` 是连续的 24 个地址，低 5 位直接透传成 `apu.reg_addr`，无需折叠。`apu_reg_cs` 是**完成脉冲**（不是请求级、不是纯译码），因为 APU 寄存器带副作用（读 `$4015` 清 IRQ、写 `$4017` 重启帧计数器等）。
- **IRQ 注入**：一根线 `.irq_i(apu_irq)`。这里没有锁存、没有 pending、没有和 mapper IRQ 的线或——因为 mapper IRQ 还不存在。
- **sample 输出**：`ce_sample` 恒为 1，于是 `sample_valid` 是每个 `ce_cpu` 沿后高 1 拍的 **strobe**（落在 `div_phase == 1`），速率与 `ce_cpu` 相同；它**不是音频速率**，下游必须自己抽取。左右声道当前完全相同。

`tb/system/tb_nes_system_audio.v` 是这条接线的端到端 testbench：配置 `$4000-$4003` 与 `$4017/$4015`，跑到 frame IRQ 抬两次，断言入口恰好 7 个 CPU 周期、`$4015` 读写 ack、逐 strobe 的 sample 与参考混音表一致、且 CPU/PPU 帧周期未被破坏。

## 9. 与后续版本的关系

**v2 起改用 `nes_cpu_bus` 的真等待态。** v0 / v1 的 `bus_ready` 是常电，等待路径从未被执行；v2 把 `nes_cpu_bus` 以 `ce = ce_cpu` 接入，集成层第一次把 `req / ready / 完成脉冲 / owner` 这套协议跑起来（设计说明见 `docs/modules/system-v2.md`）。此后每个顶层只在前一版上加一件事：

| 版本 | 一句话 | 文档 |
| --- | --- | --- |
| v2 | 接 `nes_cpu_bus`（真等待态，`ce=ce_cpu`），顶层内接 `nes_ppu_sprite`（背景 + 精灵混合），把总线与寄存器桥观测信号提到正式端口 | `docs/modules/system-v2.md` |
| v3 | 接 `nes_oam_dma`，通过 `bus_hold` 抢占总线；处理 `$2003`/`$2004` 端口的同沿竞争 | `docs/modules/system-v3.md` |
| v4 | 接 `nes_controller`：把 `$4016/$4017` 并联按钮变成 strobe + 串行移位 + 读数据替换 | `docs/modules/system-v4.md` |
| v5 | 接 `nes_mapper`：软件的函数指针表 / 指针数组变成硬件的 bank 寄存器 + 地址 mux，mapper IRQ 与 APU IRQ 线或 | `docs/modules/system-v5.md` |
| v6 | 把 PPU 的外部 CHR 读通路接到 mapper 的 bank 偏移输出（`EXTERNAL_CHR`），多出顶层 CHR 端口 | `docs/modules/system-v6.md` |

因此本文只管演进链的**起点**：v0 是"能跑通"，v1 是"多了声音"。要看 DMA、controller、mapper、外部 CHR，读对应文档，本文不重复。

## 10. 明确未实现 / 未建模

- **mapper**：v0 / v1 都没有 mapper 寄存器、没有 PRG/CHR banking、没有 mapper IRQ。固定 16 KiB PRG（NROM-128）+ 8 KiB CHR RAM，8 KiB nametable，horizontal mirroring（`MIRROR_VERTICAL=0`），没有四屏/单屏。`PRG_SIZE_BYTES` 只是容量参数，不构成任何 mapper 支持。
- **外部 CHR**：CHR 是 PPU 核内的 8 KiB RAM，没有外部 CHR bus、没有 CHR ROM、没有 pattern table banking。
- **controller**：v0 / v1 都没有 `$4016/$4017` 的串行移位语义。v1 里 `$4016` 落在 `sel_apu` 内，读 `$00`、写忽略。
- **DMA**：v0 完全没有 OAM DMA 与 DMC DMA。v1 让 `$4014` 可译码、可读回 `$00`、可计数，但**没有 DMA 状态机、没有 `RDY` 拉低、没有 513/514 stolen cycle、没有 OAM 写入**；`oam_dma_count` 不会导致任何 CPU 停顿。APU 的 `dmc_bus_req`/`dmc_addr` 悬空、`dmc_rdata = 8'h00`、`dmc_ack = 1'b0`——**没有任何保护阻止未来程序启动 DMC 后把它挂在 `dmc_ack=0` 上死等**。
- **IRQ 路径**：v0 的 `irq_i` 恒 0；v1 的 `irq_i` 唯一由 APU frame IRQ 驱动，没有 mapper IRQ 的线或。
- **open bus**：没有非确定值模型，未映射地址一律读常量 `$00`。
- **音频输出通路**：v1 只有 strobe 与 16 位混音值，没有抽取/重采样、没有 FIFO、没有 WM8978 接口、没有左右声道差异。
- **NMI 的多次服务与精确周期对齐**：v0 的 NMI testbench 只跑到第 2 个 `frame_done`，只服务 1 次 NMI；"每帧一次、长期稳定"没有覆盖。
- **精灵、奇数帧跳 dot、PAL/Dendy 制式**：与 PPU v0 一致，未实现。
- **综合 / 时序 / 上板**：本仓库**没有** ModelSim、Quartus 或 EP4CE10 上板证据。v0 / v1 的 `div_phase` 12/4 只是仿真相位，50 MHz 下的绝对速率问题尚未解决（见 `docs/modules/system-v2.md` 第 5 节）。不要拿它们的 `frame_period`、APU frame counter 计数或音频 strobe 速率当作上板时序依据。

## 11. 验证入口

集成 testbench 与 `tools/sim_all.ps1` 的目标 id 一一对应：

| `sim_all.ps1` 目标 id | testbench | 被测顶层 | 覆盖 |
| --- | --- | --- | --- |
| `system-v0` | `tb/system/tb_nes_system_v0.v` | `nes_system_v0` | CPU 经 6502 总线驱动 PPU 寄存器、背景像素、`$0000-$1FFF` RAM 镜像、NROM-128 双窗口、帧周期与 vblank 窗口 |
| `system-v0-nmi` | `tb/system/tb_nes_system_v0_nmi.v` | `nes_system_v0` | 端到端 NMI：轮询 vblank → 使能 `PPUCTRL[7]` → `$FFFA` 向量 → 入栈/`RTI` → 帧周期不变 |
| `system-v1-audio` | `tb/system/tb_nes_system_audio.v` | `nes_system_v1` | 端到端 APU：`$4000-$4017` 寄存器桥、frame IRQ 注入 `irq_i`、`$FFFE/$FFFF` IRQ 向量、服务例程 ack、sample 非零、CPU/PPU 帧不被破坏 |

其中 `system-core`（id）是纯顶层 elaboration：`iverilog -g2001 -s nes_system_v0`，只编译 RTL，确认顶层本身不依赖 testbench 特性。程序、断言清单与实测输出见 `tb/system/README.md` 的前三个 testbench 小节。

`.\tools\sim_all.ps1 -Mode all` 是权威门禁；本文只覆盖 RTL 与仿真相位，不覆盖综合、引脚分配或上板。
