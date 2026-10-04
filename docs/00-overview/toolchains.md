# 两条综合工具链并排对照

本文件把本机**两条互相独立的综合链**放在一起。**为什么要并排写**：只写 Quartus 那一侧，读者会以为 Quartus 是本项目唯一的选项；只写 Vivado 那一侧，读者会以为第 10 节的 `EP4CE10F17C8` 结论被推翻了。**两条都在，两条都有效。**

**入口**：[`risk-register.md`](risk-register.md) 第 10 节（Quartus / `EP4CE10F17C8`）、**第 11 节**（Vivado / `xc7z020clg400-2`，PPU 单独面积；"没有做出任何迁移决定"的边界声明在 11.0）、**第 12 节**（Vivado / 同一器件，**整核 NES core `nes_system_v6`** 面积；边界声明在 12.0）与**第 13 节**（Vivado / 同一器件，**PPU 时序：同一条 RTL、两个约束**；边界声明在 13.0）。Quartus 那一侧更详细的工具链注意事项同时写在 [`quartus/README.md`](../../quartus/README.md) 第 0.3 节。

> **最重要的一句，写在前面**：
>
> **没有做出任何迁移决定。** 本文件登记的是**四次跑**（三次面积 + 一次时序），不是一条计划。三条路线——**全在 PL**、**PPU 在 PL 而其余在 ARM**、**全在 ARM 而 PL 只做视频**——**都仍然开着**，本文件**不推荐其中任何一条**。
>
> **四次跑的规模与目的都不同，不能互相替代，也不能只读一行：**
>
> | 次数 | 测的是什么 | 器件 | Slice LUT / 53,200 | 登记位置 |
> |---|---|---|---|---|
> | 1 | **PPU 单独**（`nes_ppu2c02` + 3 个子单元 + 激励包装） | Cyclone IV E `EP4CE10F17C8` | 63,127 LE / 10,320 = **612 %**（装不下） | 第 10 节 |
> | 2 | **PPU 单独**（同一份 RTL、同一套 harness） | Zynq-7020 `xc7z020clg400-2` | 28,380 / 53,200 = **53.35 %** | 第 11 节 |
> | 3 | **整核 NES core**（`nes_system_v6` 的 21 文件闭包 + 激励包装，**仍然没有平台层**） | Zynq-7020 `xc7z020clg400-2` | **41,624 / 53,200 = 78.24 %** | **第 12 节** |
> | 4 | **PPU 单独，同一份未改动的 RTL，只改 `create_clock` 的周期，跑完实现与 STA** | Zynq-7020 `xc7z020clg400-2` | 实现后 **29,668 / 53,200 = 55.77 %**（80.000 ns 那一次） | **第 13 节** |
>
> **只读第二行会以为剩下 24,820 个 LUT 是白送的。第三行才是回答"装不装得下"的那一个**，而且它**仍然不是整机**——**没有视频、没有音频、没有 SDRAM、没有 TF、没有平台顶层**（第 12.10 节逐条列出）。
>
> **第四行的两个数必须一起读，谁都不许被单独引用**（第 13 节）：**约束在 80.000 ns 时收敛（WNS +6.538 ns、TNS 0.000、0 / 39,533 失败端点）；约束在 20.000 ns 时同一份 RTL 不收敛（WNS −40.242 ns、TNS −2851.741、410 / 39,599 失败端点）**。80 ns 是这个设计自己的 dot 速率合同（第 13.2 节），不是一个为了变绿而挑的数。**这组数字描述 `b10db66` 之前的源码，`b10db66` 之后没有跑过任何一次时序。**
>
> **三次面积跑都没有时序。第四次有，但范围只有一处**：**PPU 单独、只有 `xc7z020clg400-2`、没有引脚约束、没有 IOSTANDARD、没有 I/O delay**。**`EP4CE10F17C8` 上仍然没有任何时序数字，整核仍然没有，视频 / 音频 / SD-TF / SDRAM / 平台顶层仍然一次都没有被任何工具看过，两个器件都没有上过板。** 第三次比前两次多两个必须一起读的限制：**anti-constant-folding 交叉核对没有通过判据**（分离度只有 1.14×，第 12.5 节），**mapper 扫描作废**（只测到 MMC3 一条配置，第 12.6 节）。

---

## 1. 两条链的基本事实

| 项 | 链 A | 链 B |
|---|---|---|
| 工具 | Quartus Prime **Lite Edition 23.1std.0 Build 991 11/28/2023 SC Lite Edition** | Vivado **v2018.3 (64-bit) Build 2405991 Thu Dec 6 23:38:27 MST 2018** |
| 器件 | Cyclone IV E **`EP4CE10F17C8`**（三层 `FAMILY` / `DEVICE` / `DEVICE_FAMILY`） | Zynq-7020 **`xc7z020clg400-2`**（日志原文 `Loading part: xc7z020clg400-2`） |
| 安装位置 | `D:\intelfpga_lite\23.1std\`，可执行文件在 `quartus\bin64\` | `D:\Xilinx\Vivado\2018.3\`，入口 `bin\vivado.bat` |
| 是否在 `PATH` | 是 | **否**，且没有 `XILINX_VIVADO` 环境变量（两者都已核对） |
| license | **不需要** license 文件；Lite **只支持 Cyclone IV E**，本项目目标属于该族 | **不需要用户提供的 `.lic` 文件**；**PPU 探针与整核探针的每一份日志**都有 `Got license for feature 'Synthesis' and/or device 'xc7z020'`；**第四次时序跑另外拿到了 Implementation 特征**（`constraint_probe\logs\probe4.log:1201` 等 `INFO: [Common 17-349] Got license for feature 'Implementation' and/or device 'xc7z020'`）；免费 WebPACK 版覆盖 `XC7Z020-CLG400-2` |
| 跑到的阶段 | `quartus_map` + `quartus_fit`（**没有 TimeQuest / STA**） | **三次面积跑**：`synth_design` + `report_utilization` + `write_checkpoint`（**没有 `opt_design` / `place_design` / `route_design` / `report_timing_summary`**）；**第四次（PPU 时序，第 13 节）跑完了 `synth_design` + `opt_design` + `place_design` + `route_design` + `report_timing_summary`** |
| 约束文件 | **无 SDC、无引脚分配** | **三次面积跑：无 XDC、无引脚分配、无 SDC、无时钟约束**；**第四次（第 13 节）只有 `create_clock -name sys_clk -period <80.000 或 20.000> [get_ports clk]`**——**没有引脚分配、没有 IOSTANDARD、没有 `set_input_delay` / `set_output_delay`、没有板级文件** |
| 报告编码 | **cp1252**（严格 UTF-8 解码会抛异常，正确读法 `[Text.Encoding]::GetEncoding(1252)`） | **ASCII / UTF-8**（严格 UTF-8 解码不抛异常） |
| 顶层（全部在仓库外） | `ppu_synth_ext_top` / `ppu_synth_int_top` / `ppu_fold_top` / `cfu_stim` / `cfu_fold` | **PPU 探针**：`ppu_synth_ext_top` / `ppu_synth_int_top` / `ppu_fold_top`；**整核探针**：`nes_stim` / `nes_fold_top`。**第四次时序跑仍然是 `ppu_synth_ext_top`** |
| 仓库内工程 | `quartus/op_fpga_emu.{qpf,qsf,sdc}` —— **从未被打开或编译过** | **不存在**（仓库内没有任何 `.xpr` / `.xdc`）；探针的工程都在 `D:\vivadoProject\` 下（`ppu_zynq\proj\`、`core_zynq\proj\`，时序探针 `constraint_probe\` 与 `divide_probe\` 连 `.xpr` 都没有，只用批处理 tcl） |
| 登记位置 | `risk-register.md` 第 10 节 | `risk-register.md` 第 11 节（PPU 面积）、**第 12 节（整核面积）**、**第 13 节（PPU 时序）** |

**`D:\Xilinx\` 下有 3 个 `.lic` 文件**（`data\ip\core_licenses\Xilinx.lic`、`XilinxFree.lic`、`data\sysgen\hwcosim_compiler\pp_ethernet\Xilinx_IP.lic`）。**它们是安装目录 `data\` 树里随 IP 附带的 license 文本，不是用户要提供的工具 license。** 正确说法是"**不需要用户提供 `.lic` 文件，本文件登记的每一次综合都成功取到 license**"。

**慢启动**：`vivado.bat` 每次调用会 `call setupEnv.bat` **两次**（一次不带参数、一次带 `XILINX_VIVADO`），所以很慢。**必须把所有步骤放进同一次 `vivado -mode batch -source <script>.tcl`**——PPU 那次三个构建就是这么跑的（`ext` 360.8 s + `fold` 322.0 s + `int` 1,679.5 s，`tcl_start 11:40:30` → `tcl_end 12:21:28`，约 41 分钟）；**整核那次也一样**（`m4` 4,282.6 s + `fold` 4,315.8 s + `m0` 4,320.7 s，每个变体约 71–72 分钟，第四个变体 `m1` 起手后被中止，`summary.txt` 里没有 `tcl_end`）；**第四次时序跑同样是一次批处理**（综合 867.2 s、实现 1,047.5 s、合计 1,063.5 s，`p80_summary.txt`）。

**Quartus 侧另一条已知限制**：`quartus_sh --flow syn` 在 Lite Edition 上失败（`Error (18169): The Quartus Prime Pro Edition Design Software must be installed to use quartus_syn.`），改用 `quartus_map` / `quartus_fit` / `quartus_sh --flow compile`。旧版 `quartus` 13.1 在 `D:\altera\13.1\quartus\bin64\`，仅作回退；**第 10 节的全部数字都来自 23.1。**

### 1.1 如何复现这些运行

**本文件是"跑过什么"，不是"怎么跑"。** 本仓库每一次 Vivado 运行都留下了报告与日志，但**过程本身从未被写下来过**：要敲哪条命令才能得到这些数字、2018.3 上哪些选项不存在、负对照怎么写、结果该怎么引用，全部在 **[`vivado-runbook.md`](vivado-runbook.md)**。分工是固定的——**`toolchains.md` 继续是"跑了什么"的记录，`vivado-runbook.md` 是"怎么跑"的操作手册**，两者互相引用而不合并。**本节是那个文件的入口，不是它的摘要。**

---

## 2. 两次 PPU 探针用的是同一份东西

**这一节只管 PPU 那两次探针（第 10 节 Quartus ↔ 第 11 节 Vivado）。整核那次（第 12 节）不是同一份东西，闭包完全不同**，所以它不进这张表——它的 21 文件闭包与"其中 20 个与仓库 HEAD 逐字节相同、只有 `nes_system_v6.v` 差 `bcfe595` 那一行"这条核对记在 `risk-register.md` 12.2。**这一节是第 3 节全部对照的前提。** 逐文件 SHA-256 比对：

| 文件 | 两侧位置 | 结果 |
|---|---|---|
| `nes_ppu2c02.v` | `D:\vivadoProject\ppu_zynq\rtlf\` vs `D:\quartusProject\ppu_synth2\rtlf\` | **完全相同**，且**与本仓库 `rtl/nes_core/ppu/nes_ppu2c02.v` 逐字节相同**（1,041 行） |
| `nes_ppu_sprite.v` | 同上 | **完全相同**，与仓库 HEAD 逐字节相同 |
| `nes_sprite_chr_fetch.v` | 同上 | **完全相同**，与仓库 HEAD 逐字节相同 |
| `nes_chr_fetch_unit.v` | 同上 | **完全相同**，与仓库 HEAD 逐字节相同 |
| `ppu_stim.v` | `…\ppu_zynq\src\` vs `D:\quartusProject\ppu_synth2\` | **逐字节相同**（170 行） |
| `ppu_synth_ext_top.v` | 同上 | **逐字节相同**（21 行） |
| `ppu_synth_int_top.v` | 同上 | **逐字节相同**（21 行） |
| `ppu_fold_top.v` | 同上 | **逐字节相同**（126 行） |

**所以两次面积差不是"两次综合的输入不同"造成的。** 变的只有器件与工具链。

> **（2026-10-01 补记）这张表的"与本仓库逐字节相同"是当时成立的，现在对 `nes_ppu2c02.v` 已经不成立。** `b10db66` 之后 `rtl\nes_core\ppu\nes_ppu2c02.v` 变了（51,105 字节 / **1,073 行**），所以上表第一行那句"逐字节相同（1,041 行）"**描述的是那两轮探针当时的仓库状态**。四个不同修订的 SHA-256 对照表在 `risk-register.md` **13.1**，引用时必须带上修订名。其余三行（`nes_ppu_sprite.v` / `nes_sprite_chr_fetch.v` / `nes_chr_fetch_unit.v`）**没有**被那四次时序跑改动，`b10db66` 也只动了 `nes_ppu2c02.v` 一个文件。

---

## 3. PPU 单独综合的跨器件面积对照（`EXTERNAL_CHR = 1`，同一份 RTL、同一套 harness、同一个负对照组）

| | Cyclone IV E / Quartus 23.1 | XC7Z020 / Vivado 2018.3 | 倍数 |
|---|---|---|---|
| 逻辑单元总量 | 63,127 LE / 10,320 = **612 %** | 28,380 Slice LUT / 53,200 = **53.35 %** | 占用率之比 **11.5×** |
| 其中组合 | 44,323 组合函数 / 10,320 = **429 %** | 28,380 Slice LUT（Vivado 的 `Slice LUTs` 不含寄存器） | 打包因子 **1.56×** |
| 寄存器 | 19,260 | 19,586 | 差 326（1.7 %） |
| 片上存储 | **0 / 423,936 bit**（0 个 M9K） | **0 / 140 块 RAM tile**（0 个 RAMB36E1 / RAMB18E1） | 都是 0 |
| 实现阶段 | `quartus_fit` **Failed**（`Error (171000): Can't fit design in device`） | **面积那三次跑没跑** | — |
| 时序 | **没有**（无 SDC） | **面积那三次跑没有**（无 XDC）；**第四次跑有，见 3.2** | 链 A 仍然没有 |
| 负对照组 | 187 LE（塌缩 **338×**） | 1,319 LUT（塌缩 **21.5×**） | 口径不同，见下 |

- **填充率 11.5×** 的口径：6.116 ÷ 0.5335 = 11.47。**这不是"Vivado 更省"，是同一份设计在两个容量不同的器件上占的比例不同。**
- **打包因子 1.56×** 是**第一次真正测到**这个量（此前只是"约 1.5×"的假设）。内部 CHR 构建的同一比法是 484,519 ÷ 216,642 = **2.24×**。
- **两个负对照组的绝对值不可跨工具比**：Quartus 的 LE 同时装组合与寄存器，Vivado 的 `Slice LUTs` 不含寄存器。**可比的是同一个工具内部的比值。**
- **寄存器数几乎相同**（19,260 vs 19,586）是"两个工具确实展开了同一份状态"的最强证据：寄存器不随器件逻辑结构变化。**所以面积差不是"两边综合了不同的东西"。**
- **能推到什么程度**：**612 % 在 `EP4CE10F17C8` 上是几何上不可能的**（需要的组合节点数是器件能力的 6.1 倍），而器件容量从 10,320 变到 53,200 个逻辑单元是 **5.16×**。**不能推的是**"Vivado 比 Quartus 好/省"——那需要同器件对照，本仓库没有。

---

## 3.1 同一器件上的两个规模：PPU 单独 vs 整核 NES core（**必须和第 3 节一起读**）

**第 3 节那张表的两列都是 PPU 单独。同一块器件上还有一次整核测量，两者不是矛盾，是两个规模。**

【实测】来源：`D:\vivadoProject\core_zynq\out\m4.util.rpt`（与 `fold.util.rpt` / `m0.util.rpt`），Vivado v2018.3，`xc7z020clg400-2`，完整登记在 `risk-register.md` **第 12 节**。

| | **PPU 单独**（`ext`，第 11 节） | **整核 NES core**（`m4`，第 12 节） | 差 |
|---|---|---|---|
| Slice LUTs | 28,380 / 53,200 = **53.35 %** | **41,624 / 53,200 = 78.24 %** | **+13,244** |
| 剩余 LUT | 24,820（46.65 %） | **11,576（21.76 %）** | −13,244 |
| Slice Registers | 19,586 | 36,888 | +17,302 |
| 块 RAM tile | **0 / 140** | **0 / 140** | 0 |
| DSP48E1 | 0 / 220 | 0 / 220 | 0 |
| 负对照组 | 1,319 LUT（塌缩 **21.5×**） | 36,506 LUT（塌缩 **仅 1.14×**） | 口径见下 |
| 状态 | `synth_design Complete!` | `synth_design Complete!`，**0 error / 2 critical warning** | |

**四条必须一起读的限定词，缺一条这张表就会被读错：**

1. **78.24 % 不是"装得下"。** 它是 `nes_system_v6`（NES core）**加一个激励包装**的面积，**不是整机**：**没有卡带 ROM**（`prg_rom` 128 KiB 无驱动源，贡献 0）、**没有外部 CHR 存储器**、**没有外部 VRAM**、**没有视频、没有音频、没有 SDRAM、没有 TF、没有平台顶层**。逐条见 `risk-register.md` 12.10。
2. **+13,244 不是"除 PPU 以外所有东西"的干净求和。** `nes_system_v6.v:526-531` 把 PPU 的 6 个 `dbg_*` 输出全部接空，所以核里的 PPU 比孤立探针的 PPU **合法地更小**。
3. **负对照组的分离度这次只有 1.14×，没有通过判据。** PPU 那次是 21.5×、Quartus 那次是 338×。**所以这一次的 harness 没有被它自己的对照实验验证**，41,624 必须按"上界"读。详见 `risk-register.md` 12.5。
4. **IOB 那一行（532 / 125 = 425.60 %）是激励包装的产物，不是设计成本**——`OBUF 530` = `obs_o` 497 位 + `stim_count_o` 32 位 + `rtl_reset_o` 1 位，**DUT 本身只需要 26 个输入**。与第 3 节 PPU 那一行同一类产物，见 12.3。

**这一格对三条路线各意味着什么（只陈述，不推荐）：** 全在 PL → 整核已经用掉 78.24 %，剩 11,576；PPU 在 PL 其余在 ARM → **CPU + APU + bus + OAM DMA + controller + mapper 一起放进同一个 PL，实测 LUT 从 PPU 单独的 28,380 涨到 41,624**（**这不等于"其余部分正好 13,244"，见上面第 2 条限定词**；而这条路线的关键数字——CPU/APU 搬去 PS 之后 PL 侧还剩多少——**没有被测过**，本仓库也没有那个 PS↔PL 划分）；全在 ARM 而 PL 只做视频 → 本仓库**没有**一个可综合的视频顶层，什么都没测。

**只测到了 MMC3 一条 mapper 配置**：`MAPPER_SELECT` 是参数（`nes_mapper.v:139-143`），Vivado 2018.3 的 `set_property generic {MAPPER=4}` 把整数绑成了字符串 `m`，扫描作废（`risk-register.md` 12.6）。**但 `nes_mapper.v:228-354` 把五个 mapper 子模块无条件全部例化在模块作用域上，所以 41,624 里已经包含了五个 mapper 的逻辑**——`MAPPER_SELECT` 决定的是哪一组被写驱动、被观测，不是"换掉一份逻辑"。

---

## 3.2 第四次跑：PPU 时序，同一条 RTL、两个约束（**第 13 节，本文件唯一有时序数字的一节**）

【实测】**同一个 PPU 探针、同一套 harness、同一份未改动的 RTL**，只把 `create_clock` 的周期从 20.000 ns 改成 80.000 ns，跑完了 `opt_design` / `place_design` / `route_design` / `report_timing_summary`。器件 `xc7z020clg400-2`，Vivado v2018.3，非工程 out-of-context。完整登记在 `risk-register.md` **第 13 节**。

| | **20.000 ns** | **80.000 ns** |
|---|---|---|
| WNS | **−40.242 ns** | **+6.538 ns** |
| TNS | **−2851.741 ns** | **0.000 ns** |
| 失败端点 / 总端点 | **410 / 39,599** | **0 / 39,533** |
| 时序是否满足 | **否** | **是** |
| 最差路径 datapath / 级数 | 60.200 ns / 82 级 | 73.459 ns / 82 级 |
| Slice LUT（实现后） | 31,250 / 53,200 = 58.74 % | 29,668 / 53,200 = 55.77 % |
| 块 RAM tile / DSP | 0 / 140、0 / 220 | 0 / 140、0 / 220 |
| 报告 | `D:\vivadoProject\ppu_zynq\out\impl_ext_ooc_np.*` | `D:\vivadoProject\constraint_probe\out\p80_*` |

**这一节**：

- **只对 PPU 单独成立**，**只对 `xc7z020clg400-2` 成立**，**只对上面这两个约束成立**。**链 A（`EP4CE10F17C8`）仍然没有任何时序数字**，**整核 `nes_system_v6` 仍然没有任何时序数字**，**视频 / 音频 / SD-TF / SDRAM / 平台顶层仍然一次都没有被任何工具看过**，**两个器件都没有上过板**。
- **没有引脚、没有 IOSTANDARD、没有 I/O delay、没有板级文件**：`p80.check_timing.rpt` 给 `There are 0 pins that are not constrained for maximum delay.`，同时给 `rst_in` 1 个输入端口无 input delay、156 个输出端口无 output delay。**所以这是逻辑时序探针，不是板级约束集。**
- **out-of-context 是被迫的**：`ppu_zynq\out\impl_ext_stock.impl.log:169` 是 `ERROR: [Place 30-58] IO placement is infeasible. Number of unplaced terminals (157) is greater than number of available sites (125).`——157 根是激励包装的 157 位观测总线（`obs_o` 124 + `stim_count_o` 32 + `rtl_reset_o` 1）。**所以"157 位观测总线超出 125 个 bonded IOB"是必须用 out-of-context 的原因，不是它的代价。**
- **这两个数字描述 `b10db66` 之前的源码**（两侧 RTL 的 SHA-256 相同，见第 13.1 节）。**`b10db66` 之后没有跑过任何一次时序。**
- **本文件不给任何 fmax 数字**：三份 `*_summary.txt` 里的 `fmax_MHz` 字段是公式产物（20 ns 那次写 `1000/(period+wns) = -49.4022`，80 ns 那次写 `11.5556`，除法替换那次写 `1000/(period-wns) = 16.8859`——**三个字段连正负号约定都不一样，其中两个在物理上不可能是频率**）。**引用频率时用 `Data Path Delay` 与 `WNS` 原始值自己算，并写清算式。**

---

## 4. 两条链在"推不出块 RAM"上独立同意

**这是两条链唯一在结论层面互相印证的一条，也是本文件最值得记的一条**（4.1 是同一个工具链上的第三次确认，它**加深**这条结论但**不构成新的跨厂商印证**）。

- **Quartus**：网表里只有 `boundary_port` / `cycloneiii_ff` / `cycloneiii_lcell_comb`，没有 `altsyncram`、没有 MLAB；`Total memory bits ; 0 / 423,936 ( 0 % )`。
- **Vivado**：`RAMB36E1 0`、`RAMB18E1 0`、`LUT as Memory 0`、`SRL16E 0`；并且**工具自己给了理由**：
  - `g_chr_internal.chr_ram_reg` → `1: RAM has too many ports (16). Maximum supported = 16.` **与** `2: No valid read/write found for RAM.`（**两行都要引**），随后 `RAM "g_chr_internal.chr_ram_reg" dissolved into registers`；
  - `nametable_ram_reg` / `palette_ram_reg` → `1: RAM is sensitive to asynchronous reset signal. this RTL style is not supported.`；
  - 256 字节 OAM → `INFO: [Synth 8-5546] ROM "oam_ram_reg[N]" won't be mapped to RAM because it is too sparse`，日志里**印出 `N = 0..99` 共 100 条**，随后 `Common 17-14` 说"further instances will be disabled"——**所以总条数在这份日志里读不出来，不要写成大于 100 的数字。**

**根因是同一个，所以这是架构事实而不是工具怪癖**：这些数组是"多个异步组合读 + 一个写"，而**块 RAM 在两个器件族上都不接受异步多读**。`chr_ram` 是 **19** 个读口、`oam_ram` 是 **257** 个、`nametable_ram` 是 3 或 4 个、`palette_ram` 是 5 个（逐行核对的数见 `risk-register.md` 11.4）。

**因此"0 / 46 M9K"必须带上"整个 PPU 存储集合"这个范围限定词**，不能缩成"`chr_ram` 没进 BRAM"——四条阵列的理由各不相同（端口数、异步复位、稀疏、无有效读写对），结论相同。

### 4.1 整核尺度上理由清单变长了（Vivado / `xc7z020clg400-2` / `nes_system_v6`）

【实测】`D:\vivadoProject\core_zynq\out\m4.util.rpt` 与 `m4.synth.log`：**块 RAM tile 0 / 140、RAMB18 0 / 280、分布式 RAM 0、DSP48E1 0**，而 `m4.census.txt` 把 `RAMB*` 与 `RAM*X1S` 全部查成 0。**但 CPU 侧多出两条 PPU 那两次都没有的理由：**

| 数组 | 工具给的理由（原文） |
|---|---|
| `cpu_ram`（`nes_cpu_bus.v:104`，2048×8） | `1: RAM is sensitive to asynchronous reset signal. this RTL style is not supported.` → `RAM "ram_array_reg" dissolved into registers`。**它单独占 `u_bus` 的 16,426 个触发器，其中 16,384 位就是这张 2 KiB 的 RAM——整个设计最大的单个寄存器消费者。** |
| `prg_rom`（`nes_system_v6.v:189`，128 KiB） | `1: Unable to determine number of words or word size in RAM.` / `2: No valid read/write found for RAM.` **加 `WARNING: [Synth 8-3848] Net prg_rom ... does not have driver.`** |

**所以"0 块 BRAM"在整核尺度上是三条互不相同的理由，不是一条。** 最值得注意的是第二条：**`prg_rom` 根本没有写源，所以 128 KiB 在 41,624 这个数里贡献为 0**——**真实目标上 ROM 必须落在片外 flash / BRAM / 板载 ROM，而这块器件的 140 块 BRAM tile 在这里一块都没被碰过。**

**一条不要读错的数字**：整核日志里有一行汇总 `BRAMs: 280 (col length: RAMB18 60 RAMB36 30)`，**那是器件容量，不是推断数**。**推断数是 0。**

**根因清单变长了，但这仍然是"现状描述"**：第 10、11 节的 PPU 结论是"这些数组按现状无法映射为块 RAM"；第 12 节把它扩展成"整核的存储集合同样一块 BRAM 都没用上，其中 CPU 工作 RAM 全摊成触发器、卡带 ROM 根本不存在"。**任何"应该改成 BRAM"的改法一次都没有被测过。** 逐条见 `risk-register.md` 12.4。

---

## 5. 两条链共同缺失的东西

| 缺失项 | 链 A | 链 B |
|---|---|---|
| **最差 slack / TNS / 失败端点** | **仍然没有**：无 SDC，`Critical Warning (332012): Synopsys Design Constraints File file not found` | **第四次跑有了，但范围只有 PPU 单独**：80.000 ns 合同下 WNS **+6.538 ns**、TNS **0.000**、**0 / 39,533** 失败端点；同一份 RTL 在 20.000 ns 下 WNS **−40.242 ns**、TNS **−2851.741**、**410 / 39,599**（3.2 节）。**面积那三次跑仍然没有**（`No constraint files found.` + `WARNING: [Constraints 18-5210] No constraints selected for write.`），**整核仍然没有** |
| **引脚分配 / IOSTANDARD / I/O delay** | 0 条 | 面积那三次跑 0 条；**第四次跑仍然 0 条**（`p80.check_timing.rpt`：`rst_in` 无 input delay、156 个输出端口无 output delay）——**它的 80.000 ns 只约束了内部逻辑** |
| **整芯片顶层（`nes_ep4ce10_top` 或等价物）** | 从未被综合过 | 不存在这样的工程（只有 `nes_ppu2c02` 与 `nes_system_v6` 两个仓库外顶层） |
| **上板观测** | 没有 | **没有** |
| **仓库内工程被工具解析** | `quartus/` 下三个文件**从未被打开或编译过** | 仓库内无 Vivado 工程 |
| **整核（`nes_system_v6`）的面积** | **从未被综合过** | 41,624 / 53,200 = 78.24 %（第 12 节）——**但仍然没有视频、音频、SDRAM、TF、平台顶层** |
| **整核（`nes_system_v6`）的时序** | 没有 | **没有**：那三个构建只有 `synth_design` + `report_utilization` + `write_checkpoint`（`risk-register.md` 12.9） |
| **视频 / 音频 / SD-TF / SDRAM / 平台顶层的面积与时序** | 没有 | **没有**：那 9 个文件在两个器件上都没有被综合过一次（`risk-register.md` 12.10） |

**Vivado 自己写明的上界**：面积报告第 1 节脚注 `The Final LUT count, after physical optimizations and full implementation, is typically lower.` —— 所以 **28,380 与 41,624 都是实现后用量的上界**。**第四次跑给出了 PPU 单独的实现后用量**（80.000 ns 那一次是 **29,668 / 53,200 = 55.77 %**），**整核仍然只有上界，没有实现后用量**。

---

## 6. 两条链共同踩过的报告陷阱

1. **per-module 归因表不可信——现在有三个独立实例。** Quartus 的 `final_ext.map.rpt` 把 10,989 个组合 ALUT 记在 `nes_chr_fetch_unit` 名下（该模块单独综合只有 106 LC / 185 LE）；Vivado 的 `ext.util_hier.rpt` 把 18,503 LUT 记在 `nes_ppu2c02` 名下并**完全漏掉 `nes_ppu_sprite`**；**Vivado 的 `core_zynq\out\m4.util_hier.rpt` 在同一个工具上又漏掉一次 `nes_ppu_sprite`，还把 `u_mmc3` 报成 0 个触发器（而 `nes_mapper_mmc3.v:43-64` 有 21 个寄存器声明），并且 `u_apu` 的子项加起来 610 而表上写 609。** **两个工具、三份报告、同一类错误。任何按模块归因的资源数字，在拿到第二份独立核对之前都不得使用。**
2. **不要用"把 DUT 输入全接常量"的方式估面积——但要知道它什么时候会失效。** 链 A 那样同一个 PPU 只报 187 LE，链 B 的 PPU 探针报 1,319 LUT（塌缩 21.5×）——会让人错误地认为装得下。**必须与计数器驱动的激励一起读。** **第 12 节的整核探针是这条陷阱的第一个反例：塌缩只有 1.14×，所以那个对照组没有验证 harness。** 原因不是 harness 写得不好，而是**整核自己产生活动**：`div_phase`（`nes_system_v6.v:180-187`）自由运行、CPU 不停取指并一直写 PPU 寄存器，所以**接常量只让 CHR 的"数据"变成常量，没有让它的"寻址"变成常量**。**要验证这类 harness，对照组必须压掉内部时钟状态——那样的对照没有跑过。**
3. **Fitter / 实现失败时它的 per-entity 表不可用。** 链 A 的 `final_ext.fit.rpt` / `final_int.fit.rpt` 的 "Compilation Hierarchy Node" 表里每一行 `Logic Cells` 都是 0，因为 Fitter 在布局阶段就中止了。**只有实现成功的报告，那张表才有意义。**
4. **报告里"没有时序数据"和"没找到时序数据"是两件事。** 链 A 对 `final_ext.fit.rpt` 全文逐词计数：`fmax` = 0 次、`slack` = 0 次、`Fitter Timing Summary` = 0 次——**是报告里没有，不是没找到。**
5. **"所有存储原语都 0"是有效结论，"RAMB 那一行不存在"也是。** 链 A 的报告里没有任何存储器原语行；链 B 的报告里 RAMB 行的 **Used 列是 0**。两种呈现方式都要能读。
6. **日志的"行数"与工具的"内部计数器"量的是两件事，混用会得出错误的严重性判断。** 整核日志 `m4.synth.log` 共 1,980 行，其中 316 行以 `WARNING` 开头、2 行以 `CRITICAL WARNING` 开头，而工具内部计数器是 **197,067**——因为每个 code 在 100 条处封顶只关掉打印、不关掉计数。**PPU 那次的 `ext.synth.log` 同理：856 行、204 行 warning、内部计数器 65,945。** 说"某份日志有 65,900 条 warning"指的是计数器，不是行数。
7. **Vivado 报的源码行号不一定指向出问题的语句。** 整核那条 `Synth 8-6859` 多驱动网警告给的是 `nes_cpu6502.v:216` 与 `nes_cpu_bus.v:155`，但当前源码这两行分别是 `assign nmi_rise = …` 与 `assign dma_req_present = …`——**真正的驱动语句在 `:230` 与 `:233`**。**引用这类发现要引日志原文，再另引当前源码里真正的构造，不要把工具给的行号当引用。**
8. **按子串 grep 时序关键字会误报。** 整核 `m4.util_hier.rpt` 里两处会让人以为命中了时序的 `Met`，是模块名 `nes_apu_pulse__parameterized0` 里的两个字母。**必须按词边界。**
9. **generic 绑参数要确认类型。** 整核探针用 `set_property generic {MAPPER=4}`，Vivado 2018.3 把整数绑成了**字符串** `m`（日志原文 `Parameter MAPPER_SELECT bound to: m - type: string`），于是 5 个 mapper 变体跑出**逐字节相同**的结果。**"跑完了 5 个变体"不等于"跑到了 5 种配置"。**
10. **`report_timing` 在 2018.3 上没有 `-output_pins`，`-delay_type max_min` 也不被接受。** 原文是 `ERROR: [Common 17-170] Unknown option '-output_pins', please type 'report_timing -help' for usage info.`（`ppu_zynq\out\impl2_summary.txt` 的 `paths_err` 与 `critpath_err` 两个字段）与 `ERROR: [Vivado 12-1248] '-delay_type' max_min not recognized.`。**后果**：那几份 `*_summary.txt` 里的 `LEVEL` 字段全是 `n/a`，**逻辑级数只能从不带那个选项的 `report_timing` 里取**。**默认的节点表带的是同一份数据，所以少一个选项不影响级数本身，只影响 summary 那一列。**
11. **`*_summary.txt` 里那个 `fmax_MHz` 字段是公式产物，不是测量，不要引用。** 三份实测到的写法互不一致：20 ns 那次是 `1000/(period+wns) = -49.4022`（负数）、80 ns 那次是 `11.5556`（即 `1000/(80+6.538)`）、除法替换那次是 `1000/(period-wns) = 16.8859`。**三个字段连正负号约定都不一样，其中两个在物理上不可能是频率。引用频率时用 `Data Path Delay` 与 `WNS` 原始值自己算，并写清算式。**
12. **不要用"所有状态元件都被 `ce` 门控，所以每个 `ce` 之间其实有 4 倍预算"来解释一次时序失败。这条已经被测量否掉了，不要重新推导一遍。**（第 13.3 节）那次失败**不是**测量产物：
    - **harness 的 `obs_q` 根本没有被 `ce` 门控**：它是自由运行的 `FDRE`，`CE` 引脚接 `u_stim/<const1>`，驱动单元是 `u_stim/VCC/P`（`constraint_probe\out\final_corroboration.txt` 与 `probe1_ce_driver.txt`）。**它确实提出一个真正的单周期要求——而那个要求落在 harness 上，不落在 PPU 上。**
    - **`nes_ppu_sprite` 是纯组合的**：全文只有 4 个 `always @*`（`:211`、`:234`、`:335`、`:365`），**没有任何 `posedge` / `negedge`**。所以那条被报成 82 级的路径**一个寄存器都没有**，**没有 `ce` 门控可以利用**。
    - **失败端点的归属**：410 个里 **398 个是 `u_dut` 内部的寄存器到寄存器路径**，只有 **12 个是 harness 的 `obs_q`**（`probe3_endpoints.txt`；另一种切法给 `CE_DUT 284` / `D_DUT 114` / `D_OTHER 12`，284 + 114 = 398）。
    - **错的是前提，不是测量**：那条经验规则里唯一成立的部分是"约束是产品的承诺"，而错的是"20 ns 是这个设计欠的约束"（第 13.2 节）。**再看到这条理论被提出来，直接指到 13.3。**
13. **不要指望靠剪扇出拿回那条关键路径的路由时间。这条也已经被测量否掉了，登记为已关闭的问题。**（第 13.5 节）那条路径 **81.821 %** 的时间在路由上（`impl_ext_ooc_np.tsum_max.rpt:380`），曾被归因为 `s_idx` / `nl_idx` 各自驱动几百个 LUT 负载。三条实测证据：
    - **`*s_idx*` 与 `*nl_idx*` 匹配到 0 根网**（`constraint_probe\out\probe4_fanout_evidence.txt:4-5`）——**综合之后它们不是网**。
    - **`sprite_oam_bus` 的最大扇出是 14 个引脚**（同一份文件 `:6`：2,688 根网、`total_pins 19814`、`max_pins 14`）。
    - **工具自己说无事可做**：在那 2,688 根网上设 `MAX_FANOUT 32` 再跑 `phys_opt_design -directive AggressiveFanoutOpt`，日志给出 `INFO: [Physopt 32-65] No nets found for high-fanout optimization.` 与 `INFO: [Physopt 32-232] Optimized 0 net. Created 0 new instance.`（`constraint_probe\logs\probe4.log`）——**因为 14 远低于阈值 32，连候选都不存在。**
    - **做了之后**：WNS −40.242 → −39.257（**拿回 0.985 ns**），Slice LUT 31,250 → 31,266（**+16**）。**代价与收益都被记下来了，所以不必再试一次。**
    - **本条只否掉了"剪扇出"这一条出路**，**没有**给出那 81.8 % 的成因——那个问题仍然开着（`risk-register.md` 13.9）。
14. **关键路径的名字不要按源码变量名去找。** 路径中段的 LUT 在报告里的名字是**优化器生成**的（`u_stim/u_dut/obs_q[28]_i_*`，靠近终点时变成 `u_stim/u_dut/g_chr_external.u_sprite_chr_fetch/obs_q[28]_i_*` 与 `obs_q[25]_i_*`），**报告里既没有 `nth_set` 也没有 `sprite_oam_bus` 这两个词**（检索 0 命中）。**所以"某几级属于某个源码函数"只能是按级数的归因，不能写成逐单元名的实测。** 能够逐字核实的只有起终点单元、中间那几级 `sprite_overflow_reg_*` carry 链、以及那根 `u_stim/u_dut/g_chr_external.u_sprite/g_slot[0].vec[1]` 网（第 13.4 节）。

---

## 7. 逐模块资源数字的禁用范围（本节是方法约束，不是新风险）

**在下面两条都成立之前，不要写任何 per-module 资源数字**：

1. 拿到**第二份**独立来源（网表原语普查 / 单独综合该模块 / 器件手册的单元结构）；
2. 明确写出**口径**（"Slice LUTs 含不含寄存器"、"是不是实现前的数"）。

链 A 与链 B 都在自己的文档里留下了**已证伪的具体数字**，引用它们的历史教训比引用结论更重要：`quartus/README.md` 第 0.3 节末尾三条注意事项，以及 `risk-register.md` 的 10.3、11.7 与 **12.7**。

**当前唯一允许逐模块引用的两个数字是整核层级表里的 `u_bus`（8,761 LUT / 16,426 FF）与 `u_cpu`（3,763 LUT / 221 FF），且必须带"来自已被证明不可信的层级表"这个限定词**——它们只被用来给 `cpu_ram` 的 2 KiB 摊成触发器这件事一个量级参照。**第 12 节因此不发布任何 per-module LUT 表。**
