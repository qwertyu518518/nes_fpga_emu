# Vivado 操作手册（怎么跑，怎么信那些数）

> **本文件是过程，不是结果。**
>
> - **跑过什么、跑出什么数**：[`toolchains.md`](toolchains.md)（两条链并排对照）、[`risk-register.md`](risk-register.md)（第 10 / 11 / 12 / 13 节）。那两份文件**不写怎么跑**。
> - **怎么在这台机器上把它跑起来、怎么读它的输出、怎么不被它骗**：**本文件**。
> - 在本仓库的历史上，**过程一直是缺的**：每一次 Vivado 运行都留下了报告与日志，但没有任何一份文档说明"要敲哪条命令才能得到它"。本文件补的就是这一段。
>
> **边界声明**（与 `risk-register.md` 11.0 / 12.0 / 13.0 一致）：**本仓库没有做出任何 PL-vs-PS 迁移决定。** 全在 PL、PPU 在 PL 而其余在 ARM、全在 ARM 而 PL 只做视频，三条路线都仍然开着，**本文件不推荐其中任何一条**。流程 D 里出现 `nes_zynq_top` 只是因为"跑到比特流"这一步需要一个非 OOC 顶层才能成立，**不构成对它的架构路线的任何判断**。

---

## 0. 怎么读这份文件

### 0.1 证据标记

沿用 `hardware/00-index.md` 第 2 节与 `toolchains.md` 的同一套标记：

| 标记 | 含义 |
|---|---|
| 【已确认事实】 | 来自本机文件系统核对、工具自身文档、或脚本注释里已记录的决定；不需要再跑一次就能确认 |
| 【实测】 | 本机跑出来的，源文件在下文点名 |
| 【厂商例程观察】 | 从 Xilinx 随安装附带的例程 / 文档读到的形态 |
| 【待上板验证】 | 必须上真实 FPGA 板才能确认；**本文件里没有任何一条是已上板确认过的** |
| 【仓库外探针】 | 在 `D:\vivadoProject\` 之外的临时工程里跑过、**未提交、未登记成可复现源文件**的一次运行；只作为报告结果记录，引用时必须连同第 9 节的边界声明一起读 |
| 【风险提示】 | 在当前器件、约束或流程边界下会导致"跑通了但结论错"的事项 |

### 0.2 数字纪律（本文件最容易被违反的一条）

**任何综合 / 实现 / 时序数字都不许单独出现。** 引用任何一个，必须同时带上：

1. **工具 + 版本**
2. **器件（part）**
3. **top 模块名**
4. **负对照塌缩了多少倍**（没有负对照的数字不许引用，见第 5 节）
5. **约束范围**（有几条 `create_clock`、有没有引脚 / IOSTANDARD / I/O delay）
6. **源文件路径**

这条规矩在 `toolchains.md` 第 10 节与 `risk-register.md` 里是硬约束，本文件不放松它。**本文件里出现的每个数字都点了 `D:\vivadoProject\` 下的源文件名；没有源文件的数字不应该出现在这里。**

**本文件不复述面积与时序结果本身。** 那些数归 `toolchains.md` 与 `risk-register.md`；本文件只写"要敲什么才能得到它"和"拿到它之后先看哪几行"。

---

## 1. 环境事实

| 项 | 事实 | 证据 |
|---|---|---|
| 工具版本 | **Vivado v2018.3 (64-bit) Build 2405991 Thu Dec 6 23:38:27 MST 2018**（IP Build 2404404 Fri Dec 7 01:43:56 MST 2018） | 【已确认事实】`D:\vivadoProject\timing_enum\vivado4_stdout.log:2-3`；同 `toolchains.md` 第 1 节表 |
| 安装位置 / 入口 | `D:\Xilinx\Vivado\2018.3\`，入口 `bin\vivado.bat` | 【已确认事实】`D:\vivadoProject\core_zynq\run_probe.bat:2`、`core_pal_probe\run_real.bat:2` |
| 是否在 `PATH` | **否**。**没有 `XILINX_VIVADO` 环境变量**（两者都已核对） | 【已确认事实】`toolchains.md` 第 1 节表。**所以每一个启动器都必须写绝对路径**，不能写 `vivado` |
| 器件 | **`xc7z020clg400-2`**（Zynq-7020，125 个 user I/O），**每一次运行都是它** | 【已确认事实】工具自己打印 `INFO: [Device 21-403] Loading part xc7z020clg400-2`（`timing_enum\vivado4_stdout.log`）；`ppu_zynq\out\impl_ext_stock.impl.log:171` 给出 `has only 125 sites available on device` |
| license | **不需要用户提供 `.lic` 文件**；免费 WebPACK 版覆盖 `XC7Z020-CLG400-2`。**`D:\Xilinx\` 下那 3 个 `.lic` 文件是安装目录 `data\` 树里随 IP 附带的 license 文本，不是工具 license** | 【已确认事实】`toolchains.md` 第 1 节表与表下那段说明。正确说法是"本文件登记的每一次运行都成功取到 license"，不是"目录里有 license 文件" |
| Tcl 版本 | **Tcl 8.5 —— 没有 `continue`** | 【实测】`D:\vivadoProject\zynq_bitstream_v5\finish.tcl:31` 原文：`# Vivado 2018.3 ships Tcl 8.5, which has no "continue", hence the nesting.` |
| `$readmemh` 路径 | **相对路径按 Vivado 的 CWD 解析，不是按 tcl 脚本所在目录解析** | 【已确认事实】`D:\vivadoProject\zynq_bitstream_v5\build.tcl:14-15` 原文：`$readmemh resolves the relative path against Vivado's CWD, so this script MUST be launched with CWD set to this directory.` |

**【风险提示】`$readmemh` 这一条是最容易把一次跑变成静默失败的一条。** 相对路径写错时 Vivado **不报错退出**，它给一条 `CRITICAL WARNING` 然后把数组当常量折叠掉，于是块 RAM 变成 0、面积看起来"变小"、其它所有检查都还是绿的。见第 8 节第 4 行与 `D:\vivadoProject\core_pal_probe\real_stdout.log:272`。

---

## 2. 启动器：为什么所有步骤必须塞进一次 batch

### 2.1 慢启动是真的，而且有账可查

【已确认事实】`vivado.bat` 每次调用会 `call setupEnv.bat` **两次**（一次不带参数、一次带 `XILINX_VIVADO`）。所以**每一次 `vivado` 启动都要付两份环境初始化**。

【实测】**把一次运行拆成多次调用，代价是每次几分钟。** 这不是估算 —— 本仓库每一次多构建的运行都是**一次 batch 跑完多个变体**，这是唯一可行的写法：

| 一次 batch 里跑了什么 | 单变体耗时 | 源文件 |
|---|---|---|
| PPU 面积探针 3 个顶层（`ext` / `fold` / `int`） | `ext` 360.8 s + `fold` 322.0 s + `int` 1,679.5 s，合计 `tcl_start 11:40:30` → `tcl_end 12:21:28`（约 41 分钟） | 【实测】`D:\vivadoProject\ppu_zynq\out\summary.txt`（经 `toolchains.md` 第 1 节登记） |
| 整核探针 3 个变体（`m4` / `fold` / `m0`） | `m4` 4,282.6 s + `fold` 4,315.8 s + `m0` 4,320.7 s，每个变体约 71–72 分钟 | 【实测】`D:\vivadoProject\core_zynq\out\summary.txt` |
| PPU 时序探针（20 ns 一次） | 综合 867.2 s + 实现 1,047.5 s = `total_s` 1,063.5 s | 【实测】`D:\vivadoProject\constraint_probe\out\p80_summary.txt:8,14,32` |

**所以规则是：所有步骤放进同一次 `vivado -mode batch -source <script>.tcl`。** 需要"分段"的时候，分的是 **tcl 文件**，不是 `vivado` 进程（见流程 D）。

### 2.2 启动器 .bat 的最小形状

【已确认事实】仓库外现存的两个启动器就是这个形状（`core_zynq\run_probe.bat`、`core_pal_probe\run_real.bat`）：

```bat
@echo off
call "D:\Xilinx\Vivado\2018.3\bin\vivado.bat" -mode batch -source D:\vivadoProject\<probe>\<probe>.tcl
echo VIVADO_EXITCODE=%ERRORLEVEL%
```

`core_pal_probe\run_real.bat` 额外做了两件本文件推荐做的事：

```bat
set PROBE_WHICH=real
call "D:\Xilinx\Vivado\2018.3\bin\vivado.bat" -mode batch -nolog -nojournal -source ... > real_stdout.log 2> real_stderr.log
echo EXITCODE=%ERRORLEVEL% >> real_stdout.log
```

- **`-nolog -nojournal`**：不要让 Vivado 往工程目录里写 `vivado.log` / `vivado.jou`。【风险提示】`D:\vivadoProject\core_zynq\vivado.log` 就是这么攒出来的，而且它和被显式重定向的 `vivado_stdout.log` **内容重叠**，两份一起当证据会重复计数。
- **重定向 stdout / stderr 到固定文件名 + 把 `EXITCODE` 追加进去**：`finish.tcl:419-420` 里有一条由此推出的纪律 —— **正在被追加写的日志不能当证据**（`finish_stdout.log` 在脚本运行期间还在增长，所以它的完整 sweep 被刻意排除，只用了 `vivado.log` 与 `build_stdout.log`）。
- **`cd /d` 进脚本目录**：`$readmemh` 那一条（1 节）要求 CWD 就是脚本目录。`@echo off` + `cd /d "%~dp0"` 是最小写法。

---

## 3. 四条流程

四条流程的关系：**A 只回答"多大"，B 回答"多大 + 快不快"，C 在不重跑的前提下回答"快不快"，D 才产出比特流。** 选哪一条由"这次要回答什么问题"决定，不由"哪一条跑得快"决定。

### 3.0 要产出比特流，先分清两条可复现的构建流程

A–D 是**探针**流程，用来回答面积 / 时序问题。**真正产出比特流、并且已经进仓库、由启动器驱动的构建流程只有两条**：

| 构建流程 | 位置 | 顶层 | 干什么 | 什么时候用 |
|---|---|---|---|---|
| **仅 PL（主构建）** | [`tools/pl/`](../../tools/pl/README.md) | `nes_zynq_pl_top`（对 `nes_zynq_top` 的 PL-only 绑定） | 整个控制台都在 PL 上，卡带在**综合时**烧进 BRAM，产出独立 `.bit` | **默认。** 除非你要下面的 PS 功能 |
| **PS 流程（附加）** | [`tools/ps/`](../../tools/ps/README.md) | 块设计（PS7 + `axi_lite_regs` + `nes_zynq_top`） | PS 上的裸机加载程序从 TF 卡**运行时**读 `.nes`，经 AXI4-Lite 灌进同一块 BRAM，外加 USB 手柄；产出 `BOOT.bin`（不是独立 `.bit`） | 想不重新综合就换卡带时 |

两条流程互相独立，都建 `nes_zynq_top`；仅 PL 那条通过 `nes_zynq_pl_top` 把它绑成 53 个端口。**下面第 3.4 节的流程 D 就是"仅 PL"那一条**：它原先只存在于仓库外的 `D:\vivadoProject\zynq_bitstream_vN\`，现在已进仓库。

### 3.1 流程 A —— 综合探针（只有面积）

**干什么**：拿到一个 top 在 `xc7z020clg400-2` 上的 **post-synthesis 面积上界**，不带任何时序。
**代价**：本机实测单变体 **322.0 s – 4,320.7 s**（见 2.1 表，源文件同上）。**规模一变，代价就变一个量级**：同一次 batch 里 PPU 的三个顶层 `ext`（外部 CHR）360.8 s、`fold`（负对照）322.0 s、`int`（内部 CHR）1,679.5 s——**`int` 是 `ext` 的 4.65 倍**（1,679.5 ÷ 360.8）。
**不要用它回答**：时序。`toolchains.md` 第 1 节已经写明链 B 的前三次跑**没有** `opt_design` / `place_design` / `route_design` / `report_timing_summary`。

【实测】参考实现：`D:\vivadoProject\ppu_zynq\probe.tcl`（PPU）与 `D:\vivadoProject\core_zynq\probe.tcl`（整核，`probe.tcl:67-72` 是同一段）。

```tcl
# ---- 工程流：走 launch_runs，所以综合设置是 Vivado 的 stock defaults ----
set part xc7z020clg400-2
create_project <name> $proj -part $part -force
add_files -norecurse -fileset sources_1 $rtlf
add_files -norecurse -fileset sources_1 $harness
# 逐个文件确认 file_type，避免 Vivado 把 .v 当 Verilog SystemVerilog
foreach f [get_files -quiet -of_objects [get_filesets sources_1]] {
  if {[get_property file_type $f] ne "Verilog"} { set_property file_type Verilog $f }
}
# 不设 strategy、不加 pragma、不覆盖 flow option —— 这是故意的，见下面那段说明

set_property top $top [get_filesets sources_1]
catch { set_property top $top [get_runs synth_1] }
launch_runs synth_1 -jobs 8
wait_on_run synth_1
open_run synth_1

report_utilization            -file "$outd/$name.util.rpt"
report_utilization -hierarchical -file "$outd/$name.util_hier.rpt"
report_methodology            -file "$outd/$name.meth.rpt"
write_checkpoint -force        "$outd/$name.dcp"
exit
```

**为什么这条流程里没有 `synth_design`，而且是故意的。** 【已确认事实】`D:\vivadoProject\core_zynq\probe.tcl:73-74` 的注释原文：`# No strategy override, no synthesis pragma, no flow option: stock Vivado Synthesis defaults, the same condition as the validated PPU probe.` 同 `probe.tcl:6-7`：`# same device, same stock Vivado Synthesis defaults`。

**这一点是跨工具对照的前提，不是省事。** 链 A（Cyclone IV E / Quartus 23.1）的 PPU 那一次跑的是**默认设置**（`toolchains.md` 第 10 节）。要让"同一份 RTL 在两个器件上的面积差"读起来是器件差而不是设置差，**两边必须都是默认设置**。所以流程 A 走 `launch_runs synth_1` 而不是手写 `synth_design`，**不是为了少写几行，是为了保住"stock defaults"这个条件**。

【风险提示】**代价是：这条流程对"综合设置"没有任何控制力。** 想改一个选项，就必须离开这条流程，而**一旦离开，"与 Quartus 那次同条件对照"这个前提就没了**。

**【风险提示】`launch_runs` 有一个静默失败面**：它把综合放进子进程，tcl 侧的 `catch` 捕不到子进程的错误。`core_zynq\probe.tcl:260-263` 因此把 `runme.log` 与 `*_synth.log` 显式 `file copy` 到 `out\` 目录再扫 —— **不复制就等于没有错误证据**，因为 `probe.tcl:281` 的 warning / error 普查是从那份原始日志读的。

### 3.2 流程 B —— OOC 实现 + STA（面积 + 真时序）

**干什么**：在同一个 `xc7z020clg400-2` 上跑到 `route_design`，给出 post-route 面积与 `report_timing_summary`。
**代价**：本机实测 `elapsed_s` **1,031.7 s**（`D:\vivadoProject\divide_probe\out\divide_summary.txt`）、**1,063.5 s**（`D:\vivadoProject\constraint_probe\out\p80_summary.txt:32`）、**1,467.6 s**（`D:\vivadoProject\ppu_zynq\out\impl2_summary.txt:21`）。同一批探针的**负对照**同流程只要 **384.5 s**（同 `divide_summary.txt` 的 `div_fold_ooc_np` 段）—— **这就是为什么每个探针都必须带一个负对照顶层的直接理由：它同时是最便宜的不确定性检查。**

【实测】参考实现：`D:\vivadoProject\ppu_zynq\impl2.tcl:256-271`（同文件 `:60-100` 是共用的报告/事实/路径表 proc）。

```tcl
# ---- 非工程流（no project）----
catch { close_project }
read_verilog -library xil_defaultlib $rtlf
read_verilog -library xil_defaultlib $harness
read_xdc $xdc
synth_design -top $top -part xc7z020clg400-2 -mode out_of_context   # <== 不可省
write_checkpoint -force "$outd/${tag}_synth.dcp"
report_utilization -file "$outd/${tag}.util_synth.rpt"

opt_design
place_design
phys_opt_design
route_design
write_checkpoint -force "$outd/${tag}_routed.dcp"

report_timing_summary -delay_type min_max -max_paths 10 -nworst 10 \
    -report_unconstrained -significant_digits 4 -check_timing_verbose \
    -file "$outd/${tag}.tsum_max.rpt"
report_utilization -file "$outd/${tag}.util_impl.rpt"
check_timing -verbose -file "$outd/${tag}.check_timing.rpt"
exit
```

#### `-mode out_of_context` 是强制的，理由是一条实测报错

【实测】不带它，`opt_design` 会过，`place_design` 在 Phase 1.2 挂掉。`D:\vivadoProject\ppu_zynq\out\impl_ext_stock.impl.log` 原文：

```
:169  ERROR: [Place 30-58] IO placement is infeasible. Number of unplaced terminals (157) is greater than number of available sites (125).
:171    IO Group: 1 ... has only 125 sites available on device, but needs 157 sites.
:331  ERROR: [Place 30-58] IO placement is infeasible. Number of unplaced terminals (158) is greater than number of available sites (125).
:494  ERROR: [Place 30-374] IO placer failed to find a solution
:521  ERROR: [Place 30-99] Placer failed with error: 'IO Clock Placer failed'
```

（157 与 158 是两次不同的顶层 / 位宽；125 是 `xc7z020clg400-2` 的 user I/O 上限，见 1 节。）

【已确认事实】**这堵墙是 harness 造出来的，不是设计造出来的。** `D:\vivadoProject\ppu_zynq\impl2.tcl:12-15` 的注释原文：

```
# Cause is the anti-constant-folding harness, not the PPU: obs_o[123:0] +
# stim_count_o[31:0] + rst_in need 159 bonded IOBs and XC7Z020-CLG400-2
# has 125 user I/O. Those 159 bits exist so the observation cone cannot be
# pruned; on a board they would be internal wires.
```

**读法**：那 159 位观测总线存在的唯一目的是**让观测锥不被优化掉**（第 5 节）。在真实板级设计上它们是内部导线，不占 bonded IOB。**所以 `-mode out_of_context` 关掉的是端口边界的 I/O buffer 插入，不是被测设计的内部逻辑。** 【实测】`impl2.tcl:24-28` 明确记下了这一点：DUT、harness、`EXTERNAL_CHR` 都没动，只抑制端口边界的 I/O buffer 插入，并额外把 post-synth 的 `report_utilization` 也抓下来，用来证明这一点。

【厂商例程观察】`-mode out_of_context` 的合法性来自 Vivado 2018.3 自己的 `synth_design` 帮助（`impl2.tcl:17-21` 抄录）：`-mode [ default | out_of_context ] ... This mode turns off I/O buffer insertion for the module ... The block can also be implemented for analysis purposes.` 同一处（`:22`）记下 **`-noiopad` 在 2018.3 不存在**。

### 3.3 流程 C —— 只读 checkpoint 分析

**干什么**：**不重跑综合与实现**，直接打开一份已经 route 完的 `.dcp`，把时序问题问完。
**代价**：本机实测 `open_checkpoint: elapsed = 00:00:17` + `get_timing_paths: elapsed = 00:00:13`（合计 30 s 工具自报耗时），来源 `D:\vivadoProject\timing_enum\vivado4_stdout.log`。**对照：全量流程 B 是 1,031.7 s – 1,467.6 s**（源文件见 3.2 节那三行）。**也就是说同一个设计，问时序问题这一件事，重跑比读 checkpoint 贵 34.4 – 48.9 倍**（1,031.7 ÷ 30 = 34.4；1,467.6 ÷ 30 = 48.9）。【已确认事实】读 checkpoint 不修改网表，只往输出目录写文件（`timing_enum\enum.tcl:1-2` 的注释：`Read-only timing enumeration on the existing routed checkpoint. Does not modify the repository. Writes only into D:/vivadoProject/timing_enum.`）。

【实测】参考实现：`D:\vivadoProject\timing_enum\sweep.tcl`（`{D:/vivadoProject/zynq_top_probe/out_route.dcp}`）、`enum.tcl`、`enum2.tcl`、`margins.tcl`，以及 `D:\vivadoProject\core_pal_probe\dcp_facts.tcl`（最短的一个，只读 `.dcp` 写一份 facts 文件）。

```tcl
open_checkpoint <绝对路径>.dcp

# 先确认这份 checkpoint 属于谁、约束是什么 —— 不确认就读数，读的就是错的数
foreach c [get_clocks] {
  puts "[get_property NAME $c] PERIOD=[get_property PERIOD $c]"
}
report_timing -delay_type max -max_paths 20 -sort_by slack -file rep_timing.rpt

# 关键一步：用 -nworst 1 让"每个端点只留最差一条"，
# 于是 端点数 == 路径数，枚举结果本身就是一个端点清单
set ps [get_timing_paths -delay_type max -slack_lesser_than 0.0 \
             -max_paths 5000 -nworst 1]
puts "failing_endpoints = [llength $ps]"
foreach p $ps {
  puts [format "%9.3f  %s  <-  %s" \
      [get_property SLACK $p] [get_property ENDPOINT_PIN $p] [get_property STARTPOINT_PIN $p]]
}

report_timing_summary -check_timing_verbose -max_paths 10 -nworst 10 \
    -report_unconstrained -file rep_tsum.rpt
exit
```

#### 为什么"枚举 + 求和"比"报告里翻一翻"强

【已确认事实】`-nworst 1` 的语义是**每个端点只保留最差的一条路径**，所以 `[llength $ps]` 直接就是**失败端点数**，逐条 slack 求和就是 TNS 的一个自洽复算。`timing_enum\sweep.tcl:4-6` 把这条理由写在注释里：

```
# One path per endpoint (nworst 1) for every endpoint that is not comfortably
# clean. This gives the failure set AND the near-miss set in one shot, so a
# negative result ("sprite_overflow is fine") comes with a number attached.
```

**这句话是本节存在的全部理由**：把 `-slack_lesser_than` 从 `0.0` 放宽到 `30.0`（`sweep.tcl:9` 用的就是 30.0，`-max_paths 60000`），就能让**"这里没有路径"变成一句带数字的话**——`端点数 = 0` 是一个可以写进文档、可以被别人复核的陈述；"我翻了一遍没看见"不是。

【风险提示】`-nworst` 的值是**每端点**而不是全局，所以 **`-max_paths` 必须开得比端点数大**，否则尾部端点被静默截断。`enum.tcl:63-64` 与 `sweep.tcl:9-10` 分别用了 5000 / 500 与 60000；**如果你要引用失败端点数，就把 `-max_paths` 的值一起写出来**，否则那个数无法复核。

【风险提示】**`-nworst 1` 只在"端点"粒度上完备，在"起点"粒度上不完备。** 一个端点可以有很多个起点。`enum2.tcl:36-38` 因此专门跑了一遍 `-nworst 40 -max_paths 3000` 来统计"到达同一端点的不同起点个数"。**所以：`-nworst 1` 的条数 = 端点数，不等于路径总数。**

### 3.4 流程 D —— 全量非 OOC → 比特流（仓库内：[`tools/pl/`](../../tools/pl/README.md)）

**干什么**：整个设计（核 + 平台适配层 + 真卡带）跑到 `route_design`，然后出 `.bit`。**这是本项目的主比特流流程** —— 历史上每一个 `zynq_bitstream_vN` 都由它产出，包括上板手册让人先烧的那一个。

**它现在在仓库里。** 脚本是 [`tools/pl/build.tcl`](../../tools/pl/build.tcl) / [`tools/pl/finish.tcl`](../../tools/pl/finish.tcl)，外加出处对照用的 [`tools/pl/ph_build.tcl`](../../tools/pl/ph_build.tcl)、PL-only 绑定 [`tools/pl/nes_zynq_pl_top.v`](../../tools/pl/nes_zynq_pl_top.v) 和启动器 [`tools/pl/run_pl.ps1`](../../tools/pl/run_pl.ps1)。**它原先只存在于仓库外的 `D:\vivadoProject\zynq_bitstream_vN\`**，所以一个克隆既能建 PS 那一版、又建不了 PL 这一版，而旧文档给出的命令指向仓库里不存在的路径。

顶层是 `nes_zynq_pl_top`，不是 `nes_zynq_top` 本身：`nes_zynq_top` 现在带八个 `ps_*` 输入，PL-only 构建没有 PS 去驱动它们，所以用 `nes_zynq_pl_top` 把这八个口绑死（与两个板级无关 testbench 的做法一致：`ps_ld_valid`/`ps_ld_target`/`ps_ld_addr`/`ps_ld_data`/`ps_load_enable`/`ps_console_hold`/`ps_gamepad` 接 0、`ps_ld_ready` 悬空），端口数仍是 53，控制台不会被悬空的 `ps_console_hold` 拉进复位。**RTL 未被改动。**

**代价**：本机实测（**历史版本** `D:\vivadoProject\zynq_bitstream_v5\build_stdout.log`，早于 HDMI，仅作耗时参考）`synth_design` `elapsed = 00:03:26`、`opt_design` `00:00:30`、`place_design` `00:01:46`、`phys_opt_design` `00:00:06`、`route_design` `00:02:53`、`report_timing_summary` `00:00:08`，工具自报合计约 **529 s**。加 HDMI 后会更长。
【风险提示】面积 / 时序数字要引用时，按第 7 节的模板带上五个槽位，并点明它来自哪一份 `rep_*.rpt`；不要只引一个 WNS。

#### 为什么拆成两段（这是本节唯一的要点）

【已确认事实】`D:\vivadoProject\zynq_bitstream_v5\build.tcl:24-26` 的注释原文：

```
# NOTHING here can abort before the checkpoints and reports are on disk, and
# write_bitstream is deliberately NOT here -- it lives in finish.tcl, which opens this
# run's own out_route.dcp.
```

拆分的收益是**可恢复性**，不是速度：

1. **`build.tcl` 里不可能在 checkpoint 与报告落盘之前中止。** 所有 `report_*` 都包在 `catch` 里（`build.tcl` 的报告段），每个 `report_*` 后面紧跟一行自己的 `*_err` 记录，最后一行是 `exit 0`（`build.tcl:211-212`：`puts "BUILD STAGE DONE -- reports on disk, no bitstream yet (finish.tcl writes it)"` + `exit 0`）。**所以 build 阶段永远以"磁盘上有东西"结束，而不是以"成功"结束。**
2. **`write_bitstream` 只在 `finish.tcl` 里**（`finish.tcl:443`），而 `finish.tcl` 只做 `open_checkpoint out_route.dcp`（`finish.tcl:16`）。**后果：一个 `.bit` 的存在，就等于"这一次的 route 结果通过了 finish 阶段的全部断言"这个陈述。** 没有这一步，`.bit` 的存在只说明有人敲过一次 `write_bitstream`。

**`build.tcl`（`synth_design` 不带 `-mode`）：**

```tcl
# ---- preflight：先把会让后面静默失败的东西查掉 ----
puts "PREFLIGHT cwd = [pwd]"                 # $readmemh 按 CWD 解析
foreach {hex want} [list $prg_rel 393216 $chr_rel 24576] {
    if {![file exists $hex]} { puts "PREFLIGHT FAIL $hex MISSING"; exit 1 }
    if {[file size $hex] != $want} { puts "PREFLIGHT FAIL $hex wrong size"; exit 1 }
    puts "PREFLIGHT $hex first words = [first_words $hex 8]"
}
# 光"文件在"不够：还要证明它是真卡带而不是占位符（build.tcl:74-91 比较头几个 word）

read_verilog $rtl_files
read_xdc rtl/platform/zynq/nes_zynq_top.xdc

synth_design -top nes_zynq_pl_top -part xc7z020clg400-2   # <== PL-only 绑定，且没有 -mode
write_checkpoint -force out_synth.dcp
report_utilization            -file rep_util_synth.rpt
report_utilization -hierarchical -file rep_util_synth_hier.rpt
# ... BRAM INIT 全量 dump + 每张阵列的 RAMB 几何 ...

opt_design
place_design
phys_opt_design
route_design
write_checkpoint -force out_route.dcp

report_timing_summary -delay_type min_max -max_paths 20 -file rep_timing_routed.rpt
report_utilization            -file rep_util_routed.rpt
report_utilization -hierarchical -file rep_util_routed_hier.rpt
report_route_status -file rep_route_status.rpt
report_drc        -file rep_drc.rpt
report_io         -file rep_io.rpt
report_clocks     -file rep_clocks.rpt
check_timing -verbose -file rep_checktiming.rpt
report_methodology -file rep_methodology.rpt

puts "BUILD STAGE DONE -- reports on disk, no bitstream yet (finish.tcl writes it)"
exit 0
```

**`finish.tcl`（`open_checkpoint` → 断言 → `write_bitstream`）：**

```tcl
open_checkpoint out_route.dcp
# 从 routed 设计里读回真实推断出来的 RAMB 几何（不是从算式推，不是从 synth 阶段的 dump 推）
set rambs [get_cells -quiet -hierarchical -filter {REF_NAME == RAMB36E1 || REF_NAME == RAMB18E1}]
# ... 断言：BRAM tile 数、LUT as Memory 数、setup WNS / hold WHS、
#            setup/hold 失败端点数、TNS/THS、路由错误数、DRC error 数、
#            53 个端口全部有 PACKAGE_PIN、四个 create_clock 的周期、
#            每个 [get_ports] 都真的匹配到一个端口、组合环为 0 ...
# TNS 不从 get_timing_paths 读：-nworst 0 被拒，改读 report_timing_summary 的 Design Timing Summary 行
write_bitstream -force <top>.bit
exit 0
```

【已确认事实】`finish.tcl:166-167` 把 TNS 那条坑写在注释里：`# ---- TNS.  get_timing_paths rejects -nworst 0, so read the authoritative Design Timing Summary row out of report_timing_summary instead.`（第 4 节表里同一行）。

【已确认事实】`build.tcl:26` 同时记下另一条：`get_memories does not exist in 2018.3 and is never called.`（第 4 节表里同一行。）

---

## 4. 2018.3 陷阱（全部是本机实测报错，不是文档警告）

**下面每一行的"原文"列都是本机日志 / summary 里逐字抄出来的错误串**，不是从 Xilinx 文档里推的。凡是本仓库没撞到过的猜测，一律不写进这张表。

| 症状 / 想用的东西 | 本机实测原文 | 源文件 | 正确写法 |
|---|---|---|---|
| `report_timing -output_pins` | `ERROR: [Common 17-170] Unknown option '-output_pins', please type 'report_timing -help' for usage info.` | 【实测】`D:\vivadoProject\ppu_zynq\out\impl2_summary.txt:41`（`paths_err`）与 `:43`（`critpath_err`）；同样两行在 `constraint_probe\out\probe35_summary.txt:418`、`core_pal_probe\out\real.summary.txt:95` 重复出现 | **去掉这个选项**。默认的节点表带的是同一份数据，少一个选项不影响级数本身，**只影响 summary 那一列**，所以那些 `*_summary.txt` 里的 `LEVEL` 字段全是 `n/a`（`impl2_summary.txt:52-70` 逐行可见） |
| `report_timing_summary -delay_type max_min` | `ERROR: [Vivado 12-1248] '-delay_type' max_min not recognized.` | 【实测】`D:\vivadoProject\ppu_zynq\out\impl2_summary.txt:39`（`tsum_err`）。产生它的那次调用在 `impl2.tcl:70` | **`-delay_type min_max`**（顺序不能反） |
| `synth_design -noiopad` | **该选项在 2018.3 不存在。** 曾经按它试过，失败记录在 `ppu_zynq\out\impl_summary.txt:15` | 【已确认事实】`D:\vivadoProject\ppu_zynq\impl2.tcl:22` 原文：`-noiopad does NOT exist in 2018.3.` | **`synth_design -mode out_of_context`**（3.2 节） |
| `get_memories` | **该命令在 2018.3 不存在，永远不要调。** | 【已确认事实】`D:\vivadoProject\zynq_bitstream_v5\build.tcl:26`、`finish.tcl:12` 都逐字记了这条 | 用 `get_cells -quiet -hierarchical -filter {REF_NAME == RAMB36E1 \|\| REF_NAME == RAMB18E1}`（`finish.tcl:64`） |
| `set_property generic {MAPPER=$param}` —— **花括号吃掉了替换** | **每一个变体**的综合日志都打印 `Parameter MAPPER_SELECT bound to: m - type: string` | 【实测】`D:\vivadoProject\core_zynq\out\m4.synth.log:28` 与 `m0.synth.log:28`（同一行 `:28`）；错写的调用在 `core_zynq\probe.tcl:238` | **用双引号**：`set_property generic "MAPPER=$mapper" [current_fileset]`。**花括号把 `$param` 整个抑制掉了，Vivado 收到的是字面量字符串 `$param`** |
| `place_design -seed` / `route_design -seed` | **2018.3 没有 `-seed`。** | 【已确认事实】`D:\vivadoProject\zynq_bitstream_v5\build.tcl:20-22` 原文：`# Vivado 2018.3 has no -seed on place_design or route_design.  -directive is the only knob and it is left at default here so the metrics stay comparable with the 274e25a (v4) baseline.` | **唯一的旋钮是 `-directive`，并且默认不要动它** —— 动了就跟基线不可比 |
| 对 timing path 取 `get_property LEVEL` | 不是合法属性，打印 `n/a` | 【实测】`D:\vivadoProject\ppu_zynq\out\impl2_summary.txt:52-70` 每一行的 `LEVEL=n/a`；同 4 节第 1 行的后果 | **`get_property LOGIC_LEVELS`**（合法用例：`core_pal_probe\dcp_facts.tcl:25`、`constraint_probe\out\probe4_summary.txt:26`） |
| `get_timing_paths -nworst 0` | **被拒绝。** | 【已确认事实】`D:\vivadoProject\zynq_bitstream_v5\finish.tcl:166-167` 原文：`# ---- TNS.  get_timing_paths rejects -nworst 0, so read the authoritative Design Timing Summary row out of report_timing_summary instead.`；实测撞到点在 `core_pal_probe\real_stdout.log:151`、`core_rom_probe\out\run_real.log:151` | **从 `report_timing_summary` 的 Design Timing Summary 那一行读 TNS**，不要从 `get_timing_paths` 读（`finish.tcl:168-198` 是完整实现） |
| 用 `string match` 测含 `[` 的字面文本 | **错。** glob 里 `[` 打开一个字符类，所以带方括号的模式**根本不是在测字面文本** | 【已确认事实】`D:\vivadoProject\zynq_bitstream_v5\finish.tcl:342-344` 原文：`# Test with string first, NOT string match: in a glob an open bracket starts a character class, so a bracketed glob pattern does not test for literal text.` | **`string first`** |
| Tcl 的 `continue` | **Tcl 8.5 没有 `continue`。** | 【实测】`D:\vivadoProject\zynq_bitstream_v5\finish.tcl:31` 与 `:344`；写法见 `finish.tcl:345-350`（置一个 flag 变量）与 `finish.tcl:32-44`（把循环嵌套一层） | **用一个 flag 变量**（`D:\vivadoProject\divide_probe\divide.tcl:147-162` 是另一个合法写法：`for` + `break`） |
| `synth_design -generic "..."` 在命令行上 | **引号被当成字符串值的一部分传进去，综合死在 `Synth 8-4445`** | 【已确认事实】`D:\vivadoProject\zynq_bitstream_v5\build.tcl:10-15` 原文：`# synth_design -generic on the top module does not work on the Vivado 2018.3 command line -- it delivers the quotes as part of the string value and synthesis dies with Synth 8-4445.  That was measured in the 274e25a run, not assumed.` | **把卡带放在 committed default parameter 指向的那个路径上**，用工程流的 `set_property generic`（双引号）传参 |
| `couldn't read file ".../unimacro/unimacro_vhdl.tcl": No error` | **Vivado 内部的瞬时故障。** 第一次 `synth_design` 死在这里，**RTL 是可证明干净的**（`xvlog` exit 0），事后那个文件也能正常读 | 【实测】`D:\vivadoProject\divide_probe\div_stdout.log:129`（`divide.tcl:143-146` 的注释被 echo 出来）；失败那一次的记录在 `D:\vivadoProject\divide_probe\out\divide_summary_attempt1_FAILED.txt`（`synth ERROR: ERROR: [Common 17-69] Command failed: Synthesis failed ...`） | **重试一次。** `divide.tcl:147-162` 就是"最多两次"的实现（`for` + `break`，因为 8.5 没有 `continue`）。【风险提示】**重试必须是"整个 `synth_design` 重来"，不是"接着上次继续"** —— `close_design` 必须在重试循环里 |
| 在 XDC 里写 Tcl 的 `if` / `puts`（典型场景：用脚本**生成**约束文件，把条件逻辑和约束混在一起输出） | `CRITICAL WARNING: [Designutils 20-1307] Command 'puts' is not supported in the xdc constraint file. [D:/VivadoProject/ps_probe/ps_probe2.xdc:890]` —— **只是一条 CRITICAL WARNING，里面的约束被静默丢弃**。综合和实现**照常跑完**，唯一的信号是失败端点数的变化 | 【实测】`D:\vivadoProject\ps_probe\proj2\ps_probe2.runs\synth_1\runme.log:80` 与 `ps_probe\full2_stdout.log:2006`、`:2948`。同一个坑在本仓库撞过**两次**：`tools/ps/build_ps.tcl` 派生的 XDC 把 PS 桥的约束包进 `if` → **234 个失败端点**；后来 gamepad 的 `set_max_delay` 又被包进 `if` → **8 个失败端点、WNS −2.429 ns**（见 `tools/ps/build_ps.tcl:195` 与派生文件 `tools/ps/out/ps_zynq_top.xdc:948` 的注释） | **XDC 只允许约束命令，不允许 Tcl 控制流。** 条件逻辑写在产生它的 `.tcl` 里，**输出来的 XDC 必须逐行都是约束**。这条之所以危险，是因为它**不报错、不中止**：路径就此不受约束，而在有冗余的时序预算下很可能仍然全绿，直到某一天余量被吃掉才暴露 |

### 4.1 一条不是陷阱、但同样致命的：`-generic` 与 `-mode` 在工程流里都不存在

【实测】`D:\vivadoProject\ppu_zynq\out\impl2_summary.txt:9`：

```
set STEPS.SYNTH_DESIGN.ARGS FAILED: ERROR: [Common 17-170] Unknown option '-mode out_of_context', please type 'set_property -help' for usage info.
```

【已确认事实】同文件 `:11` 记下了决策过程：`#    (attempt 1 showed this property does not exist; -> engine B)`，而那次尝试的调用在 `impl2.tcl:207`：

```tcl
if {$ooc} { set_property [get_runs synth_1] STEPS.SYNTH_DESIGN.ARGS [list -mode out_of_context] }
```

**结论：`-mode out_of_context` 只能走非工程流（流程 B）。** 工程流（流程 A）那条路在 2018.3 上根本接不住它，见第 8 节第 2 行。

---

## 5. 防常量折叠：本项目不用属性

### 5.1 零属性

【已确认事实】**本项目自己的 RTL 与探针 tcl 里，`keep` / `dont_touch` / `syn_keep` / `-flatten_hierarchy` 的使用次数是 0。** 控制手段**完全是结构化 RTL 加上每个探针一个负对照**。

**这不是省事，是可比性。** 加 `keep` 会让"这个数是设计的成本"这句话失效 —— 那个数里会混进工具为了满足你而留下的东西。`toolchains.md` 第 7 节与 `risk-register.md` 12.7 已经把 per-module 归因表列为不可信；同一逻辑也适用于 `keep`。

### 5.2 方法

两条，缺一不可：

1. **每个 DUT 输入都由一个寄存器驱动，而那个寄存器的 D 端是一个真实函数** —— 自由运行的计数器。输入因此在一个时钟周期内至少变化一次，工具无法证明它是常量。
2. **每个 DUT 输出都被观测进寄存器。** 观测寄存器自己也是自由运行的（`constraint_probe\out\probe4_summary.txt:27-28` 的最差路径起点 `u_stim/u_dut/scanline_reg[0]_rep__0/C` 落在 DUT 内、终点 `u_stim/obs_q_reg[25]/D` 落在 harness 的观测寄存器上，就是这套结构的直接证据）。
3. **第二次运行：所有输入接常量。** 面积差就是"这个设计里有多少逻辑真的在动"。

### 5.3 塌缩倍数是置信度指标，不是参考信息

【实测】本仓库量到的三个塌缩倍数（**口径与各自来源见 `toolchains.md` 第 3 / 3.1 节与 `risk-register.md` 第 10 / 11 / 12 节；此处不重复结果本身**）：

| 探针 | 塌缩 | 是否通过判据 |
|---|---|---|
| Quartus / `EP4CE10F17C8` PPU | **338×** | 通过 |
| Vivado / `xc7z020clg400-2` PPU | **21.5×** | 通过 |
| Vivado / `xc7z020clg400-2` 整核 `nes_system_v6` | **1.14×** | **没有通过** |

【风险提示】**1.14× 没有通过判据，所以那一轮的数字必须按"上界"读。** `toolchains.md` 第 6 节第 2 条给了根因：整核自己产生活动（`div_phase` 自由运行、CPU 不停取指并一直写 PPU 寄存器），**接常量只让 CHR 的"数据"变成常量，没有让它的"寻址"变成常量**。**所以塌缩倍数不是走过场，它是"这个 harness 有没有被它自己的对照实验验证过"的判定值。**

### 5.4 `rom_probe` 为什么跑三个顶层

【实测】`D:\vivadoProject\rom_probe\impl.tcl:193-195` 逐字：

```tcl
flow_np real rom_probe_top     $real_h
flow_np neg  rom_probe_neg_top $neg_h
flow_np null rom_probe_const_rst_top $neg_h
```

- **`real`** —— 每个 DUT 输入由自由运行计数器驱动；
- **`neg`** —— 每个 DUT 输入接常量；
- **`null`** —— **在 `neg` 的基础上把复位也接 0**（复用同一份 harness 文件 `$neg_h`，只换顶层模块名）。

【实测】为什么需要第三个（`D:\vivadoProject\rom_probe\out\impl_summary.txt`，`neg` 段 `WNS_path_ENDPOINT_PIN` 与紧随其后的四条路径）：

```
WNS_path_ENDPOINT_PIN  u_dut/chr_rom_reg_1/ENBWREN
SLACK=75.873 ... ENDPOINT_PIN=u_dut/chr_rom_reg_1/RSTRAMB
SLACK=75.933 ... ENDPOINT_PIN=u_dut/chr_rom_reg_0/WEA[0]
```

**在 `neg` 里，CHR 存储器的 `RSTRAMB` / `ENBWREN` / `WEA` 引脚仍然被真实信号驱动，所以那 2 个块 RAM 原语活了下来。** 也就是说 **`neg` 单独一个对照给出的塌缩倍数是偏乐观的** —— 它没有把存储器的控制面也压掉。第三个顶层就是为了压这一层而存在的。

【实测】三个顶层的原语普查（`D:\vivadoProject\rom_probe\out\{real,neg,null}.facts.txt`，`REF_NAME =~ RAMB36*` 与按名字收窄的 `chr_rom_ramb36` / `chr_rom_cells`）：

| 顶层 | `ramb36` | `chr_rom_ramb36` | `chr_rom_cells` | `lut` | `ff` |
|---|---|---|---|---|---|
| `real` | **34** | 2 | 9 | 84 | 74 |
| `neg` | **2** | 2 | 3 | 32 | 56 |
| `null` | **2** | 2 | **2** | 26 | 56 |

【风险提示】**注意 `null` 也是 2 个 `RAMB36E1`，不是 0。** 也就是说：**在本仓库的这一次实测里，`null` 并没有把块 RAM 压到 0**，它压掉的是 `chr_rom_cells` 从 9 → 3 → 2 与 `lut` 从 84 → 32 → 26。**所以引用 ROM 折叠率时，必须写清楚"负对照的底线是 2 个 `RAMB36E1`，不是 0"，并且写清楚是哪一个顶层给出的那个底线。** 把"第三个顶层"当成"已经压到 0 块 BRAM"来引用，是一次会传播的误读。

### 5.5 写完负对照之后必须做的一步：对输出文件做哈希

【实测】**这条不是理论建议，本仓库踩过。** `core_zynq` 的五个 mapper 变体**测的是同一个设计**：

| 文件 | SHA-256 |
|---|---|
| `D:\vivadoProject\core_zynq\out\m0.census.txt` | `E6987E034024B82DF024D0621A67B4744E9682BFD9B1DC7D3A8DB738D8EF8B28` |
| `D:\vivadoProject\core_zynq\out\m4.census.txt` | `E6987E034024B82DF024D0621A67B4744E9682BFD9B1DC7D3A8DB738D8EF8B28` |
| `D:\vivadoProject\core_zynq\out\fold.census.txt` | `E36B36EB18CE0259EC244FDACEAD77BE334EE35C92B2951A07E666375CCCD8F3` |

（`m0` 与 `m4` **逐字节相同**；`fold` 不同，因为它是另一个顶层 —— `nes_fold_top`。）

【实测】根因是 4 节表里那一行：错写的花括号让每个变体都收到同一个字面量，所以日志里每个变体都打印 `Parameter MAPPER_SELECT bound to: m - type: string`（`m4.synth.log:28`、`m0.synth.log:28`）。

【风险提示】**负对照没有抓住这个 bug。** 负对照能抓住"面积塌缩得不够"，抓不住"变体之间根本没变"。**这两件事必须分别查**：塌缩倍数由负对照管，变体是否真的不同由哈希管。`toolchains.md` 第 3.1 节与 `risk-register.md` 12.6 已经把那次扫描登记为作废。

**所以流程纪律是：写完负对照，把每个变体的输出文件哈希一遍，确认它们确实不同，再读数。**

---

## 6. 约束政策

### 6.1 本仓库逻辑时序探针的 XDC 只有一条有效行

【已确认事实】**逻辑时序探针的 XDC 里只有一条有效行，此外什么都没有。** 例如：

```tcl
create_clock -name sys_clk -period 20.000 [get_ports clk]
```

（`D:\vivadoProject\constraint_probe\constr\ppu_sys_clk_20.xdc`；80 ns 那一份是同目录的 `ppu_sys_clk_80.xdc`。）

**没有引脚分配、没有 IOSTANDARD、没有 `set_input_delay` / `set_output_delay`、没有板级文件。**

【实测】这个声明有工具自己的输出作证 —— `D:\vivadoProject\constraint_probe\out\p80.check_timing.rpt`：

```
:47  There are 0 pins that are not constrained for maximum delay.
:63  There are 156 ports with no output delay specified. (HIGH)
:32  There are 0 register/latch pins with no clock.
:239 There are 0 combinational loops in the design.
```

【风险提示】**所以这样量出来的 WNS 只描述器件内部逻辑，不含任何 pad。** 它不是板级约束集的结果，**不能当作"这块板能跑多快"来引用**。`toolchains.md` 第 3.2 节与第 5 节已经逐条写明这一点。

**对照：全量非 OOC 那一跑（流程 D）确实是有引脚约束的** —— `tools/pl/finish.tcl` 断言 53 个端口全部拿到 `PACKAGE_PIN`，并断言 XDC 里每个 `[get_ports]` 目标都真的匹配到一个真实端口。**两者的 WNS 口径因此完全不同，不可互相引用。**

### 6.2 两个例外，都在实测文件里

【已确认事实】**`rom_clk.xdc` 是唯一带显式 `-waveform` 的那一份**（`D:\vivadoProject\rom_probe\constr\rom_clk.xdc`，全文一行）：

```tcl
create_clock -name sys_clk -period 80.000 -waveform {0.000 40.000} [get_ports clk]
```

【已确认事实】**`video_dc_clk.xdc` 是唯一真正的双时钟那一份**（`D:\vivadoProject\video_dc_probe\constr\video_dc_clk.xdc:23-24`）：

```tcl
create_clock -name wr_clk -period 46.561 [get_ports wr_clk]
create_clock -name rd_clk -period 40.000 [get_ports rd_clk]
```

**两个时钟刻意不声明相互关系。** 【已确认事实】同文件 `:14-18` 的理由原文：`# The two clocks are left with NO declared relationship. They come from independent MMCM outputs, so Vivado is free to assume the worst case rather than being told they are safe. There is no combinational path between the domains: the only crossing is the frame_mem read/write pair, which is a simple-dual-port RAM and is not a timed path.` 同文件 `:7-8` 给出两个真实周期：`wr_clk` 21.477272727 MHz → 46.561 ns（NES 核域）、`rd_clk` 25.000000000 MHz → 40.000 ns（LCD 点时钟域）。

【风险提示】**单时钟约束去量一个双时钟设计，量不到跨域。** 同文件 `:5-6` 原文：`# BOTH clocks are declared at their REAL periods. Measuring a dual-clock design under a single 80 ns clock measures nothing about the crossing.` ——**这句话就是为什么这一份不能省掉第二条 `create_clock`。**

---

## 7. 报告纪律

### 7.1 引用任何一个结果的最小完整形式

【已确认事实】下面这个模板是本仓库引用纪律的最小完整形态，**照抄它，不要精简**：

```
【实测】Vivado 2018.3，`xc7z020clg400-2`，top = `<top>`，负对照塌缩 `<N>×`，
约束仅 `create_clock -period <P>`（无引脚/IOSTANDARD/I/O delay），
已跑完 `route_design`。Slice LUT `<used>` / 53,200 = `<pct>%`，
WNS `<wns>` ns，失败端点 `<n>` / `<total>`。来源 `<报告文件>`。
```

**五个必填槽位，缺一个这条引用就不成立：**

| 槽位 | 缺了会怎样被误读 |
|---|---|
| 工具 + 版本 | 换一个版本，同一个设计给出另一个数，无从判断 |
| part | 28,380 与 63,127 差的是器件容量，不是工具好坏（`toolchains.md` 第 3 节） |
| top 模块名 | 同一个 `nes_ppu2c02` 在整核里比孤立探针里**合法地更小**（`toolchains.md` 第 3.1 节限定词第 2 条） |
| 负对照塌缩倍数 | 1.14× 那一次根本没验证过 harness（5.3 节） |
| 约束范围 | 只有 `create_clock` 的 WNS 不含 pad（6.1 节） |
| 已跑到哪个阶段 | post-synthesis 用量是**上界**，工具自己在报告第 1 节脚注里这么说（`toolchains.md` 第 5 节引过） |

### 7.2 `fmax` 的负号：不要算，或者诚实标注

【实测】`1000/(period + wns)` 在 WNS 为负时给出**负数**，而 `1000/(period - wns)` 给出**虚高的正数**。两者都不是频率。

【实测】`D:\vivadoProject\divide_probe\divide.tcl:130` 写的是后者：

```tcl
puts $hf [format "fmax_MHz  1000/(period-wns) = %.4f" [expr {1000.0/($period-$wns)}]]
```

**它在 WNS 为负时把负的 slack 当成加项，于是报出一个物理上不可能的频率。** 【实测】那一次运行的输出（`D:\vivadoProject\divide_probe\out\div_ext_ooc_np.headline.txt`）：

```
max SLACK            -39.221
fmax_MHz  1000/(period-wns) = 16.8859
```

**`16.8859` 是把一个 −39.221 ns 的违例当成余量加出来的虚构频率，不是任何东西能跑到的频率。**

【已确认事实】同一份 `toolchains.md` 第 6 节第 11 条已经记下三种互不一致的写法：20 ns 那次 `1000/(period+wns) = -49.4022`（负数）、80 ns 那次 `11.5556`（即 `1000/(80+6.538)`）、除法替换那次 `1000/(period-wns) = 16.8859`。**三个字段连正负号约定都不一样，其中两个在物理上不可能是频率。**

**所以本文件的规则是：**

1. **默认不算 fmax。**
2. 要引用频率，就**用 `Data Path Delay` 与 `WNS` 原始值自己算，并写清算式**。
3. **WNS 为负时，`1000/(period+wns)` 会是负数。** 要么原样打印并标注"这是负余量下的公式产物，不是频率"，**要么干脆不给 fmax**。**不许把负数取绝对值、不许换分母、不许只报正的那一个。**

---

## 8. 验证清单 / 排障表

**症状 → 成因 → 修法。** 每一行的"证据"列都给源文件。

| # | 症状 | 成因 | 修法 | 证据 |
|---|---|---|---|---|
| 1 | `ERROR: [Place 30-58] IO placement is infeasible. Number of unplaced terminals (157) is greater than number of available sites (125).` 随后 `[Place 30-374] IO placer failed to find a solution`、`[Place 30-99] Placer failed with error: 'IO Clock Placer failed'`；`opt_design` 过了，`place_design` 死在 Phase 1.2 | **反常量折叠的观测总线要 159 个 bonded IOB，而 `xc7z020clg400-2` 只有 125 个 user I/O。** 这堵墙是 harness 造的，不是设计造的 —— 那 159 位在板级设计上就是内部导线 | **`synth_design -mode out_of_context`**（流程 B）。**`-noiopad` 在 2018.3 不存在** | 【实测】`D:\vivadoProject\ppu_zynq\out\impl_ext_stock.impl.log:169,331,494,521`；成因说明 `impl2.tcl:12-15`；`-noiopad` 不存在 `impl2.tcl:22` |
| 2 | `set_property ... ARGS FAILED: ERROR: [Common 17-170] Unknown option '-mode out_of_context', please type 'set_property -help' for usage info.` | **工程流接不住这个选项。** `STEPS.SYNTH_DESIGN.ARGS` 上没有 `-mode` 这个 property | **改用非工程流**（流程 B）：`read_verilog` / `read_xdc` / `synth_design ... -mode out_of_context`。流程 A 的工程流（`launch_runs`）只能做面积 | 【实测】`D:\vivadoProject\ppu_zynq\out\impl2_summary.txt:9`（同文件 `:11` 记着 `# -> engine B`）；失败的调用在 `impl2.tcl:207` |
| 3 | `constrs_1 :` 后面是空的 | **本来就没有约束。** 流程 A 全程无 XDC、无引脚、无 SDC、无时钟约束，所以实现集是空的 | **要看时序就必须换流程 B**（带一条 `create_clock` 的 XDC）。**面积跑没有时序不是工具的问题，是流程 A 的定义** | 【已确认事实】`toolchains.md` 第 1 节表（约束文件一行）与第 5 节第一行；实测侧 `D:\vivadoProject\core_zynq\vivado.log` 打印 `Design is defaulting to impl run constrset: constrs_1` 而该集为空 |
| 4 | **面积小得可疑**，或者 **BRAM 数是 0 而设计里明明有 RAM** | **`$readmemh` 没找到 hex 文件。** 相对路径按 **Vivado 的 CWD** 解析，不是按脚本目录。数组被当常量折叠掉，于是块 RAM 静默变成 0，**其它所有检查都还是绿的** | **先 preflight 文件，再跑综合**：存在性、字节数、前几个 word 三样都查，缺一样就 `exit 1`。并且 `cd /d` 进脚本目录再启动 Vivado | 【实测】`D:\vivadoProject\core_pal_probe\real_stdout.log:272`：`CRITICAL WARNING: [Synth 8-4445] could not open $readmem data file 'rtl/nes_core/cart/prg_placeholder.hex'; please make sure the file is added to project and has read permission, ignoring [.../nes_cart_rom.v:176]`，紧跟 `Warning: Trying to implement RAM in registers.`；结果 `D:\vivadoProject\core_pal_probe\out\real.summary.txt:12-13` 给 `POSTSYNTH_RAMB36E1 : 0` / `POSTSYNTH_RAMB18E1 : 0`；preflight 实现见 `D:\vivadoProject\zynq_bitstream_v5\build.tcl:57-91`；CWD 规则见 `build.tcl:14-15`。**对照：同一个设计在 hex 就位时给 50 块 tile** —— `D:\vivadoProject\zynq_bitstream_v5\rep_util_synth.rpt:72`（`Block RAM Tile 50 / 140`），断言写在 `build.tcl:122`。**这两个 0 与 50 都是流程内断言值，不是本文件登记的面积结果** |
| 5 | `synth_design` 死在 `couldn't read file ".../unimacro/unimacro_vhdl.tcl": No error` | **Vivado 内部的瞬时故障。** RTL 可证明干净（`xvlog` exit 0），事后那个文件也能正常读 —— 所以不是设计错误 | **重试一次。** 重试必须"整个 `synth_design` 重来"（循环里先 `close_design`），不是接着上次继续。Tcl 8.5 没有 `continue`，用 `for` + `break` 或 flag 变量 | 【实测】`D:\vivadoProject\divide_probe\div_stdout.log:129`（`divide.tcl:143-146` 的注释被 echo 出来）；失败那一次 `D:\vivadoProject\divide_probe\out\divide_summary_attempt1_FAILED.txt` 记 `synth ERROR: ERROR: [Common 17-69] Command failed: Synthesis failed ...`；重试实现 `divide.tcl:147-162` |

---

## 9. PS7 块设计流程（流程 E）：两次未上机验证的可行性探针

> **本节的所有数字都来自两次【仓库外探针】。** 两次都在仓库外的临时工程里跑过，**没有提交、没有留下可复现的源文件**：第一次（probe 1）没有产出比特流，第二次（probe 2）产出了比特流。它们记录在这里，是因为"PS 这条路能不能走、踩了哪些坑"是本文件该答的问题；**但它们不是本文件第 7 节意义上可复核的测量**——引用时要把这条边界声明一起读，并优先把它登记进 `risk-register.md`。**本节没有任何一条经过硬件验证**：probe 2 的比特流从未被启动，USB / SD 枚举从未测过。

### 9.1 结论：PS + PL 能装下，也能收敛（headline）

**结论是可行的。** 第一次探针量出"面积放得下但时序不收敛"，第二次探针证明那次失败的两个原因**都是可避免的，而且都已移除**：路由器无拥塞地收敛，每个时钟域的 WNS 都为正，比特流产出。下面 9.1.1 保留第一次探针的完整记录（它的失败是有信息量的历史），9.1.2 是第二次探针的结果与两条可复用的教训。

#### 9.1.1 第一次探针（probe 1）：按现状不收敛

在一个最小的 **PS7 + AXI4-Lite 块设计**里，把真实的 `nes_zynq_top` 一并实例化进去。结果：

- **能 build、能 validate**（块设计语法与连接合法）；
- **面积放得下，但很紧**；
- **按现状不收敛时序**。

面积与实现数字（`xc7z020-clg400-2`，Vivado 2018.3，全量非 OOC 流程）：

| 量 | 值 |
|---|---|
| Slice LUTs | **43,775 / 53,200 = 82.28 %** |
| 基线（无 PS/互连） | 41,533 |
| 增量 | **+2,242**，其中 **AXI 互连占 2,013** |
| post-place WNS | **−2.799 ns** |
| post-place TNS | **−338.124** |
| 失败 setup 端点数 | **134** |
| `route_design` | **未收敛**：报 `[Route 35-447] Congestion is preventing the router from routing all nets`，约 2.5 小时后仍停在 iteration 3 |

**后果：没有比特流产出。**

**这不是最终结论。** probe 1 的失败来自两处可改的选择，见 9.1.2；只读完这张表就停下的读者会得到比实际更悲观的答案。

#### 9.1.2 第二次探针（probe 2）：收敛并产出比特流

**Verdict：装得很宽松。** 路由器无拥塞，每个时钟域都闭合时序。原因不是换了运气或种子，而是**换掉了两个错误选择**。

**原因 1：互连选错了工具。** probe 1 为了一个一对一的、很小的寄存器组，用了 `axi_smc`（SmartConnect）加 `axi_gpio`，其中 `axi_smc` 单独就占 **2,013 LUT / 2,539 FF**（连同 `axi_gpio` 是 2,058 / 2,589）。probe 2 把两者换成一个**手写的 AXI4-Lite slave**，外加 PS 的 `M_AXI_GP0` 强制要求的 AXI3→AXI4-Lite 协议转换器：

| block | LUT | FF |
|---|---|---|
| 手写 `axi_lite_regs`（218 行） | **99** | **267** |
| `axi_protocol_converter`（PS 的 `M_AXI_GP0` 需要） | 418 | 564 |
| **合计** | **517** | **831** |
| probe 1 的 `axi_smc` + `axi_gpio` | 2,058 | 2,589 |
| **节省** | **−1,541（−75%）** | **−1,758（−68%）** |

手写 slave 单独只占 `axi_smc` LUT 的 **4.9%**、FF 的 **10.5%**。**教训 1：SmartConnect 不是一对一的 AXI-Lite 寄存器组的正确块。** 只有一个小寄存器组、一条点对点连接时伸手去拿 SmartConnect，代价比整个 PS 开销本应占的还大。

**原因 2：复位那一类是接口处理问题，不是容量限制。** 两处改动：

- 平台顶层里核域的视频流水线（frame BRAM 周围会大量复制的 `px_*` / `vid_*` 寄存器）原来吃的是原始 `negedge sys_rst_n`，现在改吃**核域同步器的输出** `posedge rst_core`。
- 残留的是**异步断言进入每个域各自复位同步器**的那一段。先试过**有界处理，并且实测失败了**：`set_max_delay -datapath_only 20.000`（正是本仓库给自己的时钟域边界用的同一个写法）**约束的是 setup/hold 数据通路，不管 recovery/removal**，于是对 0.106 ns 的要求仍然留下 **27 个失败**。所以这些弧改成**按引脚范围的 `set_false_path -to`**，明确点名 **37 个一级复位同步器的异步引脚**：`rst_{sys,core,lcd,hdmi}_q_reg`、`locked_*_q?_reg`、`hdmi_locked_q?_reg`、`codec_cfg_*_q?_reg`、`btn_meta_q_reg`、`btn_sync_q_reg`。

**必须写明：这不是对复位的一刀切 false path。** 第二级、每个域的复位树、所有数据路径和其余全部约束都原样保留。

**结果：失败 `async_default` 端点从 134 变成 0**，综合与布线后签核两处都是 0。

两次探针对照基线（`xc7z020-clg400-2`，Vivado 2018.3，全量非 OOC 流程）：

| | baseline（仅 PL） | probe 1 综合 | probe 1 placed | **probe 2 综合** | **probe 2 routed** |
|---|---:|---:|---:|---:|---:|
| Slice LUTs | 41,533 | 43,775 | 43,048 | **42,234** | **41,988（78.9%）** |
| Slice Registers | 39,626 | 42,233 | 41,278 | **40,475** | **40,331（37.9%）** |
| RAMB36 / RAMB18 | 82 / 0 | 82 / 0 | 82 / 0 | **82 / 0** | **82 / 0** |
| WNS / TNS | — | — | −2.799 / −338.124 | — | **+2.356 / 0.000** |
| WHS / THS | — | — | −0.277 / −1.926 | — | **+0.067 / 0.000** |
| 失败 setup / hold | — | — | 134 / 15 | — | **0 / 0** |

- PS 相对基线的开销现在是 **+701 LUT / +849 FF**（综合口径：42,234 − 41,533 / 40,475 − 39,626），第一次探针是 **+2,242**（43,775 − 41,533）。
- **每个时钟的 WNS 全为正**：`clk_fpga_0` 8.693 · `mmcm_core_clk` **5.051** · `mmcm_hdmi_pclk` 26.012 · `mmcm_hdmi_pclk_x5` 6.380 · `aud_mclk_OBUF` 28.102。NES 核自己的域仍然通过。
- 余量：**LUT 21.1%**、**FF 62.1%**、**BRAM 41%** 空闲。
- **Router 收敛**：`Router Completed Successfully`，0 条未布线 net，0 个布线错误，**零条 `[Route 35-447]` 拥塞警告**，在全局迭代第一轮就收敛，耗时 **4 分 29 秒**（place 2:16、opt 0:30；implementation 总计 9:13）——对照第一次探针的 2.5 小时仍未跑完。
- **比特流产出**：4,045,674 bytes，SHA256 `7C0278B55443B5C3F72AE57D3122304F02112BCA1A382B547D38DE66F01E9B6F`；`ps_probe2.hdf` 325,395 bytes。

**必须直说的一个保留意见：** hold 余量很薄，只有 **+0.067 ns**，而且它落在 Xilinx 的 `axi_protocol_converter` 里，**不在 NES 核**。slice 级 packing 已经到 100%，所以后续再加逻辑要带着 hold 意识去加。这两条都不改变 verdict。

### 9.2 134 个失败全是一类：PS 复位驱动 fabric 异步复位

**本节记录的是 probe 1 的失败集合；probe 2 对这一类的处理与结果见 9.1.2 原因 2。**

**这是本节最重要的一句，它区分"放弃这条路"和"修一个接口"。**

134 个失败**全部**是 **`async_default` 的 recovery/removal** 违例，落在 **PS 复位驱动 fabric 异步复位**这条路径上：`clk_fpga_0 → mmcm_core_clk`，**130 个端点**。

**每一个时钟域内部都通过**（包括 NES 核本身）；**每一个同步的跨时钟对也都通过**。所以这不是容量问题，是**一个可修的单点接口处理问题**：

> 正确读法不是"PS + PL 装不下"，而是"PS 复位进入 fabric 异步复位的接口需要按 recovery/removal 的特殊处理（同步、或改变复位下发方式）"。

（这与 XDC 里已经处理过的 `sys_clk → mmcm_core_clk` 复位/CDC 边界同源：从另一个时钟域来的异步复位必须被当作同步器输入来对待，而不是直接扇到全片的异步清零端。）

### 9.3 流程陷阱列表（每一条都花过真实时间）

下面每一条都是**静默或误导性失败**——它们不会以"构建失败"的形式出现，这正是要逐条记下来的原因。

| # | 陷阱 | 症状 / 后果 | 正确做法 |
|---|---|---|---|
| 1 | 块设计 IP 参数需要 **`CONFIG.` 前缀** | 裸写 `PCW_*` 会被**静默忽略**，PS 起来是默认值，**没有任何东西会说它被忽略了** | 一律写成 `CONFIG.PCW_*` |
| 2 | **`PCW_EN_RST0_PORT=1` 是必需的** | 不开这个，`FCLK_RESET0_N` **根本不存在** | 需要 `FCLK_RESET0_N` 就必须先开 `CONFIG.PCW_EN_RST0_PORT=1` |
| 3 | **`M_AXI_GP0_ACLK` 必须手动连** | 自动化连接**不会**替你接它 | 手动把 `M_AXI_GP0_ACLK` 接到时钟 |
| 4 | **`assign_bd_address` 在 2018.3 没有 `-force`** | 按别的版本写 `-force` 会失败 | 去掉 `-force` |
| 5 | FIXED_IO 的 vlnv | 名字写错就连不上 | `xilinx.com:display_processing_system7:fixedio_rtl:1.0` |
| 6 | **工程模式综合的 CWD 是 run 目录** | 提交的**相对 `$readmemh` 路径失效**，ROM **静默消失**，BRAM 报 0，设计看起来像"根本没有 ROM" | 用**绝对模块参数** + 每次综合运行的 **`STEPS.SYNTH_DESIGN.TCL.PRE`** 钩子。**这与第 1 节、第 8 节第 4 行记录的那一类坑完全相同（同样的 `$readmemh` 静默折叠），只是触发路径从 CWD 换成了工程模式的 run 目录** |
| 7 | Vivado 的 **XGUI helper-process 竞态** | 间歇性报 `couldn't read file ".../xgui/*.tcl"` 或 `unimacro_verilog.tcl` | **重试即可解决**，不要当作设计错误去追（与第 4 节表里 `unimacro_vhdl.tcl` 那条同源，见第 8 节第 5 行） |

第 6 条与既有条目的关系值得单独点出：第 1 节和第 8 节第 4 行已经把 `$readmemh` 的 CWD 静默失败列为"最容易把一次跑变成静默失败的一条"。流程 E 只是把同一根因在**工程模式**下再撞了一次——**工程模式合成把 CWD 设到 run 目录**，于是 commit 里的相对路径全部落空。**两类症状、同一个根因、同一个修法**（先证明文件在、再让路径绝对化）。所以第 1 节那条纪律在 PS 流程里不但仍然成立，还更隐蔽（因为工程流的 preflight 更难插到 run 目录里）。

### 9.4 若采用 PS，构建流程会变成什么样

记录这些，是为了避免"只是多接一个 IP"的错觉：

- **顶层从纯 batch TCL 变成块设计（工程模式）**。流程 B 那个非工程的 `read_verilog` / `synth_design` 配方**在顶层无法存活**——一旦顶层是 `.bd`，综合就必须走工程流（对照第 3.1 节流程 A 的"stock defaults"条件也随之改变）。
- **`.hdf`（2018.3；2019.2 起是 `.xsa`）进入视野**：它是把 PL 硬件定义交给 SDK 的产物。
- **FSBL、BSP、裸机 App、`BOOT.bin` 成为新交付物**。
- **比特流本身不再是交付物**。`.bit` 只是 `BOOT.bin` 的一个组成，单独烧进 PL 只跑一半系统。
- **板子的启动模式（QSPI vs SD）变成一个用户设置**：`BOOT.bin` 放哪里、从哪启动，是使用者要选的东西，不再是"烧完 bit 就跑"。

### 9.5 已被证实可用的 SDK 命令序列

下面这条序列在探针里被实际跑通（**仍是【仓库外探针】，未上机**）：

```text
write_hwdef                       # 导出 .hdf / .xsa，交给 SDK
xsct                              # Xilinx 软件命令行
    hsi::add_library xilffs       # FSBL 需要的库
    sdk createapp -app {Zynq FSBL}# 生成 FSBL 应用
bootgen -image boot.bif -arch zynq -o BOOT.bin -w on
```

命令名与顺序是探针验证过的形态；参数（`.bif` 内容、库版本）由工程决定。

### 9.6 边界声明（必须与数字一起读）

- **没有上机验证。** probe 2 产出了比特流（4,045,674 bytes，SHA256 见 9.1.2），但**它从未被启动过**；probe 1 甚至没有产出比特流。USB / SD 枚举**从未测过**，PS 侧的外设一个都没有在硬件上跑起来过。
- **本节数字不携带可复现源文件。** 与第 1–8 节不同，流程 E 两次探针的产物都没有登记在 `D:\vivadoProject\` 里，因此其他节"每个数字都点源文件"的纪律在这里**不成立**——这是一个诚实的缺口，不是省事。probe 2 的比特流与 `.hdf` 同样没有进入仓库。
- **本文件仍然不做 PL-vs-PS 迁移决定**（见文件头边界声明）。流程 E 只是回答"如果走 PS，会撞到什么"，不是推荐。

### 9.7 流程 E 已经进了仓库（软件半边）

第 9 节那两次探针之后，PS 这条路已经有一份**可复现**的流程进了仓库：`tools/ps/`（块设计、FSBL、裸机加载程序、`BOOT.bin`）与模块文档
[`../modules/ps-rom-load-software.md`](../modules/ps-rom-load-software.md)。流程 E 的构建配方（`build_ps.tcl` / `run_build.ps1` / `sdk_flow.tcl` / `run_sdk.ps1`）与它这次跑出来的数（LUT / FF / BRAM、0 失败端点、比特流与 `BOOT.bin` 的 SHA256、INIT 差分）都在那份文档里，并且**这一次是有源文件的**（报告在 `tools/ps/out/`，由流程自己生成）。仍然成立的是第 9.6 节的边界：**没有上机验证。**

---

## 附：本文件引用的全部源文件

**除流程 D 的仓库内实现（`tools/pl/`）外，下表全部在 `D:\vivadoProject\` 下，仓库外。** 本文件不修改其中任何一个。

| 用途 | 路径 |
|---|---|
| Vivado 版本 / part 自报 | `timing_enum\vivado4_stdout.log` |
| 启动器（绝对路径 / `-nolog -nojournal` / 重定向） | `core_zynq\run_probe.bat`、`core_pal_probe\run_real.bat` |
| 流程 A 参考实现 | `ppu_zynq\probe.tcl`、`core_zynq\probe.tcl` |
| 流程 B 参考实现 | `ppu_zynq\impl2.tcl`、`divide_probe\divide.tcl` |
| 流程 B 实测耗时 | `divide_probe\out\divide_summary.txt`、`constraint_probe\out\p80_summary.txt`、`ppu_zynq\out\impl2_summary.txt` |
| 流程 C 参考实现 | `timing_enum\sweep.tcl`、`timing_enum\enum.tcl`、`timing_enum\enum2.tcl`、`timing_enum\margins.tcl`、`core_pal_probe\dcp_facts.tcl` |
| 流程 D（仅 PL）参考实现，**仓库内** | [`tools/pl/build.tcl`](../../tools/pl/build.tcl)、[`tools/pl/finish.tcl`](../../tools/pl/finish.tcl)、[`tools/pl/ph_build.tcl`](../../tools/pl/ph_build.tcl)、[`tools/pl/nes_zynq_pl_top.v`](../../tools/pl/nes_zynq_pl_top.v)、[`tools/pl/run_pl.ps1`](../../tools/pl/run_pl.ps1) |
| 流程 D 历史版本（3.4 节耗时数字的来源） | `zynq_bitstream_v5\build.tcl`、`zynq_bitstream_v5\finish.tcl`、`zynq_bitstream_v5\build_stdout.log`、`zynq_bitstream_v5\finish_stdout.log`、`zynq_bitstream_v5\rep_util_synth.rpt` |
| IO 放置不可行 | `ppu_zynq\out\impl_ext_stock.impl.log` |
| 2018.3 陷阱 | `ppu_zynq\out\impl2_summary.txt`、`ppu_zynq\out\impl_summary.txt`、`ppu_zynq\out\impl_ext_ooc_np.check_timing.rpt`、`core_pal_probe\real_stdout.log`、`core_zynq\out\m4.synth.log`、`core_zynq\out\m0.synth.log` |
| 负对照三顶层 | `rom_probe\impl.tcl`、`rom_probe\out\impl_summary.txt`、`rom_probe\out\{real,neg,null}.facts.txt`、`rom_probe\constr\rom_clk.xdc` |
| 变体哈希 | `core_zynq\out\{m0,m4,fold}.census.txt` |
| 约束政策 | `constraint_probe\constr\ppu_sys_clk_20.xdc`、`constraint_probe\constr\ppu_sys_clk_80.xdc`、`constraint_probe\out\p80.check_timing.rpt`、`video_dc_probe\constr\video_dc_clk.xdc` |
| fmax 符号错误 | `divide_probe\divide.tcl:130`、`divide_probe\out\div_ext_ooc_np.headline.txt` |

**结果本身在别处**：面积 / 时序 / 失败端点数 / 存储推断理由 → [`toolchains.md`](toolchains.md) 与 [`risk-register.md`](risk-register.md) 第 10 – 13 节。

**第 9 节（流程 E，PS7 块设计探针）没有可登记的源文件。** 两次探针都在仓库外的临时工程里跑过，未提交、未留下可复现产物，所以它不在上表内；probe 2 的比特流与 `.hdf` 也没有登记。引用第 9 节的任何数字都要连同第 9.6 节的边界声明一起读。
