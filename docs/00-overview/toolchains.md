# 两条综合工具链并排对照

本文件把本机**两条互相独立的综合链**放在一起。**为什么要并排写**：只写 Quartus 那一侧，读者会以为 Quartus 是本项目唯一的选项；只写 Vivado 那一侧，读者会以为第 10 节的 `EP4CE10F17C8` 结论被推翻了。**两条都在，两条都有效。**

**入口**：[`risk-register.md`](risk-register.md) 第 10 节（Quartus / `EP4CE10F17C8`）与**第 11 节**（Vivado / `xc7z020clg400-2`，以及"没有做出任何迁移决定"的边界声明在 11.0）。Quartus 那一侧更详细的工具链注意事项同时写在 [`quartus/README.md`](../../quartus/README.md) 第 0.3 节。

> **最重要的一句，写在前面**：
>
> **没有做出任何迁移决定。** 本文件登记的是**两次测量**，不是一条计划。三条路线——**全在 PL**、**PPU 在 PL 而其余在 ARM**、**全在 ARM 而 PL 只做视频**——**都仍然开着**，本文件**不推荐其中任何一条**。
>
> **两次测量都只覆盖一个模块（`nes_ppu2c02` 加它的子单元加一个激励包装），都没有时序，两个器件都没有上过板，整芯片顶层在两个器件上都从未被综合过。**

---

## 1. 两条链的基本事实

| 项 | 链 A | 链 B |
|---|---|---|
| 工具 | Quartus Prime **Lite Edition 23.1std.0 Build 991 11/28/2023 SC Lite Edition** | Vivado **v2018.3 (64-bit) Build 2405991 Thu Dec 6 23:38:27 MST 2018** |
| 器件 | Cyclone IV E **`EP4CE10F17C8`**（三层 `FAMILY` / `DEVICE` / `DEVICE_FAMILY`） | Zynq-7020 **`xc7z020clg400-2`**（日志原文 `Loading part: xc7z020clg400-2`） |
| 安装位置 | `D:\intelfpga_lite\23.1std\`，可执行文件在 `quartus\bin64\` | `D:\Xilinx\Vivado\2018.3\`，入口 `bin\vivado.bat` |
| 是否在 `PATH` | 是 | **否**，且没有 `XILINX_VIVADO` 环境变量（两者都已核对） |
| license | **不需要** license 文件；Lite **只支持 Cyclone IV E**，本项目目标属于该族 | **不需要用户提供的 `.lic` 文件**；三份日志都有 `Got license for feature 'Synthesis' and/or device 'xc7z020'`；免费 WebPACK 版覆盖 `XC7Z020-CLG400-2` |
| 跑到的阶段 | `quartus_map` + `quartus_fit`（**没有 TimeQuest / STA**） | `synth_design` + `report_utilization` + `write_checkpoint`（**没有 `opt_design` / `place_design` / `route_design` / `report_timing_summary`**） |
| 约束文件 | **无 SDC、无引脚分配** | **无 XDC、无引脚分配、无 SDC、无时钟约束** |
| 报告编码 | **cp1252**（严格 UTF-8 解码会抛异常，正确读法 `[Text.Encoding]::GetEncoding(1252)`） | **ASCII / UTF-8**（严格 UTF-8 解码不抛异常） |
| 顶层（全部在仓库外） | `ppu_synth_ext_top` / `ppu_synth_int_top` / `ppu_fold_top` / `cfu_stim` / `cfu_fold` | `ppu_synth_ext_top` / `ppu_synth_int_top` / `ppu_fold_top` |
| 仓库内工程 | `quartus/op_fpga_emu.{qpf,qsf,sdc}` —— **从未被打开或编译过** | **不存在**（仓库内没有任何 `.xpr` / `.xdc`） |
| 登记位置 | `risk-register.md` 第 10 节 | `risk-register.md` 第 11 节 |

**`D:\Xilinx\` 下有 3 个 `.lic` 文件**（`data\ip\core_licenses\Xilinx.lic`、`XilinxFree.lic`、`data\sysgen\hwcosim_compiler\pp_ethernet\Xilinx_IP.lic`）。**它们是安装目录 `data\` 树里随 IP 附带的 license 文本，不是用户要提供的工具 license。** 正确说法是"**不需要用户提供 `.lic` 文件，三次综合都成功取到 license**"。

**慢启动**：`vivado.bat` 每次调用会 `call setupEnv.bat` **两次**（一次不带参数、一次带 `XILINX_VIVADO`），所以很慢。**必须把所有步骤放进同一次 `vivado -mode batch -source <script>.tcl`**——本次三个构建就是这么跑的（`ext` 360.8 s + `fold` 322.0 s + `int` 1,679.5 s，`tcl_start 11:40:30` → `tcl_end 12:21:28`，约 41 分钟）。

**Quartus 侧另一条已知限制**：`quartus_sh --flow syn` 在 Lite Edition 上失败（`Error (18169): The Quartus Prime Pro Edition Design Software must be installed to use quartus_syn.`），改用 `quartus_map` / `quartus_fit` / `quartus_sh --flow compile`。旧版 `quartus` 13.1 在 `D:\altera\13.1\quartus\bin64\`，仅作回退；**第 10 节的全部数字都来自 23.1。**

---

## 2. 两次探针用的是同一份东西

这一条是第 2 节全部对照的前提。**逐文件 SHA-256 比对：**

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

---

## 3. 面积对照（`EXTERNAL_CHR = 1`，同一份 RTL、同一套 harness、同一个负对照组）

| | Cyclone IV E / Quartus 23.1 | XC7Z020 / Vivado 2018.3 | 倍数 |
|---|---|---|---|
| 逻辑单元总量 | 63,127 LE / 10,320 = **612 %** | 28,380 Slice LUT / 53,200 = **53.35 %** | 占用率之比 **11.5×** |
| 其中组合 | 44,323 组合函数 / 10,320 = **429 %** | 28,380 Slice LUT（Vivado 的 `Slice LUTs` 不含寄存器） | 打包因子 **1.56×** |
| 寄存器 | 19,260 | 19,586 | 差 326（1.7 %） |
| 片上存储 | **0 / 423,936 bit**（0 个 M9K） | **0 / 140 块 RAM tile**（0 个 RAMB36E1 / RAMB18E1） | 都是 0 |
| 实现阶段 | `quartus_fit` **Failed**（`Error (171000): Can't fit design in device`） | **没跑** | — |
| 时序 | **没有**（无 SDC） | **没有**（无 XDC） | 都是没有 |
| 负对照组 | 187 LE（塌缩 **338×**） | 1,319 LUT（塌缩 **21.5×**） | 口径不同，见下 |

- **填充率 11.5×** 的口径：6.116 ÷ 0.5335 = 11.47。**这不是"Vivado 更省"，是同一份设计在两个容量不同的器件上占的比例不同。**
- **打包因子 1.56×** 是**第一次真正测到**这个量（此前只是"约 1.5×"的假设）。内部 CHR 构建的同一比法是 484,519 ÷ 216,642 = **2.24×**。
- **两个负对照组的绝对值不可跨工具比**：Quartus 的 LE 同时装组合与寄存器，Vivado 的 `Slice LUTs` 不含寄存器。**可比的是同一个工具内部的比值。**
- **寄存器数几乎相同**（19,260 vs 19,586）是"两个工具确实展开了同一份状态"的最强证据：寄存器不随器件逻辑结构变化。**所以面积差不是"两边综合了不同的东西"。**
- **能推到什么程度**：**612 % 在 `EP4CE10F17C8` 上是几何上不可能的**（需要的组合节点数是器件能力的 6.1 倍），而器件容量从 10,320 变到 53,200 个逻辑单元是 **5.16×**。**不能推的是**"Vivado 比 Quartus 好/省"——那需要同器件对照，本仓库没有。

---

## 4. 两条链在"推不出块 RAM"上独立同意

**这是两条链唯一在结论层面互相印证的一条，也是本文件最值得记的一条。**

- **Quartus**：网表里只有 `boundary_port` / `cycloneiii_ff` / `cycloneiii_lcell_comb`，没有 `altsyncram`、没有 MLAB；`Total memory bits ; 0 / 423,936 ( 0 % )`。
- **Vivado**：`RAMB36E1 0`、`RAMB18E1 0`、`LUT as Memory 0`、`SRL16E 0`；并且**工具自己给了理由**：
  - `g_chr_internal.chr_ram_reg` → `1: RAM has too many ports (16). Maximum supported = 16.` **与** `2: No valid read/write found for RAM.`（**两行都要引**），随后 `RAM "g_chr_internal.chr_ram_reg" dissolved into registers`；
  - `nametable_ram_reg` / `palette_ram_reg` → `1: RAM is sensitive to asynchronous reset signal. this RTL style is not supported.`；
  - 256 字节 OAM → `INFO: [Synth 8-5546] ROM "oam_ram_reg[N]" won't be mapped to RAM because it is too sparse`，日志里**印出 `N = 0..99` 共 100 条**，随后 `Common 17-14` 说"further instances will be disabled"——**所以总条数在这份日志里读不出来，不要写成大于 100 的数字。**

**根因是同一个，所以这是架构事实而不是工具怪癖**：这些数组是"多个异步组合读 + 一个写"，而**块 RAM 在两个器件族上都不接受异步多读**。`chr_ram` 是 **19** 个读口、`oam_ram` 是 **257** 个、`nametable_ram` 是 3 或 4 个、`palette_ram` 是 5 个（逐行核对的数见 `risk-register.md` 11.4）。

**因此"0 / 46 M9K"必须带上"整个 PPU 存储集合"这个范围限定词**，不能缩成"`chr_ram` 没进 BRAM"——四条阵列的理由各不相同（端口数、异步复位、稀疏、无有效读写对），结论相同。

---

## 5. 两条链共同缺失的东西

| 缺失项 | 链 A | 链 B |
|---|---|---|
| **fmax / 最差 slack / 未约束端点** | 无 SDC：`Critical Warning (332012): Synopsys Design Constraints File file not found` | 无 XDC：`No constraint files found.` + `WARNING: [Constraints 18-5210] No constraints selected for write.` |
| **引脚分配** | 0 条 | 0 条 |
| **整芯片顶层（`nes_ep4ce10_top` 或等价物）** | 从未被综合过 | 不存在这样的工程 |
| **上板观测** | 没有 | **没有** |
| **仓库内工程被工具解析** | `quartus/` 下三个文件**从未被打开或编译过** | 仓库内无 Vivado 工程 |

**Vivado 自己写明的上界**：报告第 1 节脚注 `The Final LUT count, after physical optimizations and full implementation, is typically lower.` —— 所以 **28,380 是实现后用量的上界**。

---

## 6. 两条链共同踩过的报告陷阱

1. **per-module 归因表不可信。** Quartus 的 `final_ext.map.rpt` 把 10,989 个组合 ALUT 记在 `nes_chr_fetch_unit` 名下（该模块单独综合只有 106 LC / 185 LE）；Vivado 的 `ext.util_hier.rpt` 把 18,503 LUT 记在 `nes_ppu2c02` 名下并**完全漏掉 `nes_ppu_sprite`**（而 `nes_ppu2c02.v:766` 确实例化了它）。**两个工具、两个报告、同一类错误。任何按模块归因的资源数字，在拿到第二份独立核对之前都不得使用。**
2. **不要用"把 DUT 输入全接常量"的方式估面积。** 链 A 那样同一个 PPU 只报 187 LE，链 B 报 1,319 LUT——会让人错误地认为装得下。**必须与计数器驱动的激励一起读。**
3. **Fitter / 实现失败时它的 per-entity 表不可用。** 链 A 的 `final_ext.fit.rpt` / `final_int.fit.rpt` 的 "Compilation Hierarchy Node" 表里每一行 `Logic Cells` 都是 0，因为 Fitter 在布局阶段就中止了。**只有实现成功的报告，那张表才有意义。**
4. **报告里"没有时序数据"和"没找到时序数据"是两件事。** 链 A 对 `final_ext.fit.rpt` 全文逐词计数：`fmax` = 0 次、`slack` = 0 次、`Fitter Timing Summary` = 0 次——**是报告里没有，不是没找到。**
5. **"所有存储原语都 0"是有效结论，"RAMB 那一行不存在"也是。** 链 A 的报告里没有任何存储器原语行；链 B 的报告里 RAMB 行的 **Used 列是 0**。两种呈现方式都要能读。

---

## 7. 逐模块资源数字的禁用范围（本节是方法约束，不是新风险）

**在下面两条都成立之前，不要写任何 per-module 资源数字**：

1. 拿到**第二份**独立来源（网表原语普查 / 单独综合该模块 / 器件手册的单元结构）；
2. 明确写出**口径**（"Slice LUTs 含不含寄存器"、"是不是实现前的数"）。

链 A 与链 B 都在自己的文档里留下了**已证伪的具体数字**，引用它们的历史教训比引用结论更重要：`quartus/README.md` 第 0.3 节末尾三条注意事项，以及 `risk-register.md` 的 10.3 与 11.7。
