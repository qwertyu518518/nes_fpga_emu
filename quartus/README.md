# Quartus 工程骨架（未验证）

本目录是 `op_fpga_emu` 的 **Quartus 工程骨架**：`op_fpga_emu.qpf`（工程身份）、`op_fpga_emu.qsf`（器件 `EP4CE10F17C8` + 顶层 `nes_ep4ce10_top` + 38 条 Verilog 源）、`op_fpga_emu.sdc`（3 条 `create_clock` + 2 条 `set_false_path`）三个文件都已存在，让 Quartus Prime 能打开一个完整的工程。

**先说最重要的一句：本仓库没有安装 Quartus，这三个文件从未在 Quartus 中打开或编译过，这里没有跑过一次综合、一次 Fit、一次 TimeQuest、一次上板测量。** 下面所有 `.qsf` / `.sdc` / `.qpf` 里的内容都是按仓库文档与厂商例程观察写出来的骨架，**没有一条被 Quartus 解析过或校验过**。打开工程后请以 Quartus 自己的报告为准，不要把这里的数字当作结果引用。

标记沿用 `docs/hardware/00-index.md` 的约定：**【厂商例程观察】** = 来自厂商例程的观察，不是本工程的验证结果；**【未验证】** = 必须由工具报告或上板测量回答。

PLL 相关的交叉引用：SDC 第 6 节的 `TODO(PLL)`（状态 A → B 的改写清单）在 [`docs/hardware/12-ntsc-clock-and-pll.md`](../docs/hardware/12-ntsc-clock-and-pll.md) **第 6 节**有对应的验证步骤与通过判据，改 SDC 前后请对照那 6.2 / 6.3 节。

---

## 0. 目录内容

| 文件 | 作用 | 状态 |
|---|---|---|
| `op_fpga_emu.qpf` | 工程身份文件（工程名 + 工程文件格式版本），Quartus 打开工程的入口 | 骨架，版本号是占位 |
| `op_fpga_emu.qsf` | 全部工程设置：器件、顶层实体、38 条 `VERILOG_FILE`、工程级 IO 电压、TimeQuest 的 SDC 指向 | 骨架，**0 条 `set_location_assignment` / 0 条 `set_io_assignment`（完全没有任何引脚分配）** |
| `op_fpga_emu.sdc` | TimeQuest 时序约束：**3 条生效的 `create_clock`**（50 / 21.477272 / 25 MHz）、**0 条 `create_generated_clock`**、IO 标准、**2 条生效的 `set_false_path`**、PLL 生成后的 `TODO(PLL)` 改写清单 | 骨架，**从未被 TimeQuest 解析或校验** |
| `../rtl/platform/ep4ce10/nes_ep4ce10_qsf_if.v` | 板级引脚封装层：把 `nes_ep4ce10_top` 的端口名映射成板级信号名（`sys_clk` / `sys_rst_n` / `key[3:0]` / `vga_hs` / `vga_vs` / `vga_rgb[15:0]` / `led[3:0]` / `beep`） | 唯一新增的 RTL，已用 Icarus 编译通过（见第 6 节） |
| `README.md` | 本文：怎么打开、先做哪三步、哪些是未验证的 | — |

`.qpf` 与 `.qsf` 必须成对存在，缺一个 Quartus 打不开。工程目录就是 `quartus/`，所以 `.qsf` 里的 RTL 路径都写成 `../rtl/...`。

### 0.1 实际计数（本机用文本搜索逐条核对，不是估算）

本节所有数字都是从这三个文件里直接搜出来的，**不代表任何工具校验结果**——三个文件从未在 Quartus 里打开或编译过。

| 核对项 | 实测 | 怎么数的 |
|---|---|---|
| `quartus/op_fpga_emu.qpf` | **存在** | `Test-Path` = True |
| `quartus/op_fpga_emu.qsf` | **存在**（143 行） | `Test-Path` = True |
| `quartus/op_fpga_emu.sdc` | **存在**（193 行） | `Test-Path` = True |
| 仓库里任何 `.qip` | **不存在** | 全仓 `*.qip` 递归搜索，0 结果 |
| 仓库里任何 `.sdf` | **不存在** | 全仓 `*.sdf` 递归搜索，0 结果 |
| `.qsf` 里 `set_location_assignment` | **0 条** | 全文搜索，0 命中 → **没有任何引脚分配** |
| `.qsf` 里 `set_io_assignment` | **0 条** | 全文搜索，0 命中 |
| `.qsf` 里 `PIN_LOCATION` | **0 条** assignment；1 次出现在注释里（说明"故意留空"） | 唯一命中的第 126 行是注释文本 |
| `.qsf` 生效的 `set_global_assignment` | **48 条**（10 条非文件 + 38 条 `VERILOG_FILE`） | 逐行匹配行首 `set_global_assignment`；全文另有 1 次命中在第 13 行的格式说明注释里 |
| `.qsf` 生效的 `VERILOG_FILE` | **38 条** | 逐行匹配行首 `set_global_assignment -name VERILOG_FILE` |
| `.qsf` 声明的器件 | `FAMILY "Cyclone IV E"` / `DEVICE EP4CE10F17C8` / `DEVICE_FAMILY "Cyclone IV E"` | 第 17–19 行 |
| `.qsf` 声明的顶层 | `TOP_LEVEL_ENTITY nes_ep4ce10_top` | 第 27 行 |
| `.sdc` 生效的 `create_clock` | **3 条** | 逐行匹配行首 `create_clock` |
| ├ `sys_clk` | 20.000 ns = 50 MHz 板载晶振 | 第 55 行 |
| ├ `clk_ntsc` | 46.5608 ns = 21.477272 MHz | 第 65 行 |
| └ `clk_vga` | 40.000 ns = 25 MHz | 第 69 行 |
| `.sdc` 生效的 `create_generated_clock` | **0 条** | 全文只有 1 次命中，位于第 11 行**注释**里（说明"因此写成 create_clock"）→ **altpll 尚未生成** |
| `.sdc` 生效的 `set_false_path` | **2 条** | 逐行匹配行首 `set_false_path` |
| ├ (a) 复位同步器 | `-from [get_ports $P_SYS_RSTN]` | 第 132 行 |
| └ (b) NTSC→VGA toggle CDC | `-from [get_registers {*line_ready_toggle}] -to [get_registers {*toggle_meta}]` | 第 145–146 行 |
| `.sdc` 生效的 `derive_pll_clocks` | **0 条** | 2 次命中都在第 62、186 行的 `TODO(PLL)` 注释段里 |
| `.sdc` 生效的 `set_clock_groups` | **1 条**（`-asynchronous`，3 个 group） | 第 117–120 行，仅在"altpll 未生成"的过渡状态成立 |
| `.sdc` 生效的 `set_input_delay` / `set_output_delay` / `set_max_delay` / `set_clock_uncertainty` | 生效的**各 0 条** | 四个关键字合计 4 次命中，全部是注释：第 151 行（`set_max_delay` 同步器第一级预算的注释示例）、第 160 行（`set_input_delay` TODO）、第 164 行（`set_output_delay` TODO）、第 53 行（`set_clock_uncertainty` TODO）。实际生效的是第 72 行的 `derive_clock_uncertainty`（自动推导，不含晶振 ppm 偏差） |

**从上表能得出的唯一结论：工程骨架在位，但证据为零。** 三个文件从未在 Quartus 中打开或编译过（本机没有安装 Quartus），所以**综合、Fitter、STA、引脚分配、时序收敛依然没有任何证据**。已就位的是"能被工具读的文件"，不是"被工具读过的结果"。

### 0.2 清单完整性与自检方法

`rtl/nes_core/` 下实际有 **35** 个 `.v` 文件，`rtl/platform/ep4ce10/` 下有 **3** 个，合计 **38** 个（一文件一模块，38 个模块）；`.qsf` 的 `VERILOG_FILE` 清单**现已与磁盘逐条一致**，38 条对 38 个 `.v`，missing = 0、ghost = 0。

清单历史上漏过三次，三次都已经补齐：

- 第一次漏了 `peripheral/` 下的 **4** 个模块——`wm8978_i2c.v`、`nes_cdc_fifo.v`、`nes_i2s_shifter.v`、`nes_audio_i2s.v`；
- 第二次是在那之后**新增**的两个模块没有同步进清单——`ppu/nes_chr_fetch_unit.v` 与 `peripheral/sd_spi_cmd.v`；
- 第三次是本轮**新增**的 `ppu/nes_sprite_chr_fetch.v`（精灵 CHR 预取单元）同样没有同步进清单。

也就是说"上一轮说 37 条"是**当时**的实测值：当时清单与磁盘都是 37 个 `.v`、逐条一致；其后仓库新增了这 1 个模块，清单与磁盘因此短暂分叉（37 对 38，missing = 1），**现已把这条 `VERILOG_FILE` 补进去**，恢复与磁盘逐条一致。**补清单只是让文件清单自洽，不等于这个模块被综合过**——见第 6 节，它仍在层次闭包之外（见第 4.3 节），且本工程从未被 Quartus 编译过。

请用下面的命令自行核对清单与磁盘是否一致：

```powershell
$qsf = (Select-String -Path quartus\op_fpga_emu.qsf -Pattern "^set_global_assignment -name VERILOG_FILE" |
        ForEach-Object { ($_.Line -split '\s+')[-1].Replace('../','').Replace('/','\') })
$actual = Get-ChildItem -Recurse rtl -Filter *.v | ForEach-Object { $_.FullName.Replace("$PWD\",'') }
"qsf=$($qsf.Count) disk=$($actual.Count) missing=$(($actual|Where-Object{$qsf -notcontains $_}).Count) ghost=$(($qsf|Where-Object{-not(Test-Path $_)}).Count)"
$actual | Where-Object { $qsf -notcontains $_ }   # 应无输出
$qsf    | Where-Object { -not (Test-Path $_) }   # 应无输出
```

本机实测输出是 `qsf=38 disk=38 missing=0 ghost=0`，后两条命令都无输出。

`rtl/nes_core/peripheral/` 下的 **5** 个模块（`wm8978_i2c` / `nes_cdc_fifo` / `nes_i2s_shifter` / `nes_audio_i2s` / `sd_spi_cmd`）与 `ppu/nes_chr_fetch_unit.v` 都没有被 `nes_ep4ce10_top` 或任何 System 顶层实例化（`README.md` 与 `docs/00-overview/verification-plan.md` 都记着 `wm8978_i2c` 这一点），所以它们不在层次闭包里、也不需要被当前顶层综合——但它们属于仓库实际内容，列进 `VERILOG_FILE` 只是为了清单完整。它们与 `nes_ep4ce10_qsf_if` 一起按第 4.3 节的多顶层处理。**特别地：`nes_chr_fetch_unit` 尚未被 `nes_ppu2c02` 例化，CHR 外部取数通路在硬件上仍未接通**，列进 `.qsf` 不改变这一点。

---

## 1. 怎么在 Quartus 里打开

1. 启动 Quartus Prime（任何支持 Cyclone IV E 的版本，Standard / Pro 都可以）。
2. `File → Open Project…`，选 `quartus/op_fpga_emu.qpf`。
   - **不要**用 `File → New Project Wizard` 重建：`.qpf` 已经带了工程身份，Wizard 只会让你重新填一遍器件和顶层。
3. 打开后先不要点 `Start Compilation`，按顺序做第 2 节的三步。
4. 打开后请立刻在 `Assignments → Settings` 里核对三处，不要假设文件里的字面值被工具接受了：
   - `Devices`：Family = `Cyclone IV E`，Device = `EP4CE10F17C8`
   - `Design Files`：应该看到 **38** 个 `.v` 文件和 1 个 `.sdc`。清单已与磁盘核对一致（见第 0.2 节的自检脚本），如果你在 Design Files 面板里数到别的数字，说明 `.qsf` 又有新增文件没被列进去
   - `TimeQuest`：SDC 那一行指向 `op_fpga_emu.sdc`
     （**【未验证】** 不同 Quartus 版本这条 assignment 可能显示为 `SDC_FILE` 或 `SOURCE_TSDC_FILE_NAME`，以你版本里实际显示的为准）

打开时**预期**会看到的提示（不是 bug）：

- `get_ports` 对不存在的端口名会打印警告。`op_fpga_emu.sdc` 第 0 节的 `pick_port` 会依次尝试 `sys_clk → clk_sys` 这类候选名，只为让同一份 SDC 对两种顶层都能用，被跳过的候选会留下警告。
- 可能有多个顶层实体的提示，见第 4.3 节。

编译一次之后 Quartus 会在 `quartus/` 下生成一堆东西：`output_files/`、`db/`、`incremental_db/`、`.qsf` 备份、TimeQuest 报告、`.sld`、`.rpt` 等。**这些是产物，不是本目录的交付物**，建议加进 `.gitignore`（本仓库当前的 `.gitignore` 只忽略了 `.slim/clonedeps/repos/`，本次没有改动它）。该提交的是 `.qpf` / `.qsf` / `.sdc` / `README.md` 四个文件，以及 `rtl/platform/ep4ce10/nes_ep4ce10_qsf_if.v`。

---

## 2. 打开后必须先做的三步

### 第一步：确认器件与顶层

`Assignments → Settings`：

| 项 | 值 | 说明 |
|---|---|---|
| Family | `Cyclone IV E` | 器件系列 |
| Device | `EP4CE10F17C8` | FBGA / 256 pin / C8 |
| Top-level entity | `nes_ep4ce10_top`（默认） | 备选 `nes_ep4ce10_qsf_if`，见第 4 节 |
| 工程级 IO 电压 | `2.5 V` | **【厂商例程观察】**厂商例程用这个值作为起点；**【未验证】**每个 bank 的 VCCIO 是否匹配、按键/LED/VGA 是否需要 3.3-V LVTTL，必须查原理图 |

### 第二步：添加引脚（Pin Planner）

`Assignments → Pin Planner`。**本工程故意没有写任何 `PIN_LOCATION`**：引脚号是电气与板级复用的事实，只能由原理图 + 器件手册确认；把一份转录的数字写进 `.qsf`，会变成一个看起来已经验证过的引脚承诺。下面的数字全部是**【厂商例程观察】**，请**逐条对着原理图确认**后再填。

| 板级信号 | 引脚 | 方向 | 备注 |
|---|---|---|---|
| `sys_clk` | `E1` | input | 50 MHz 板载晶振。**打开 Clock Assignment 后不要勾 "Enable Global Clock"**，这个引脚应该驱动 fabric 里的普通时钟网络 |
| `sys_rst_n` | `M1` | input | 低有效。**【未验证】**板上有无独立复位按键、是否与 `beep`/数码管共用 |
| `key[0]` | `E16` | input | 低有效（按下为 0）【厂商例程观察】 |
| `key[1]` | `E15` | input | 同上 |
| `key[2]` | `M2` | input | 同上 |
| `key[3]` | `M16` | input | 同上 |
| `led[0]` | `D11` | output | **【未验证】**共阴/共阳与点亮电平；封装层按高电平点亮写 |
| `led[1]` | `C11` | output | 同上 |
| `led[2]` | `E10` | output | 同上 |
| `led[3]` | `F9` | output | 同上 |
| `beep` | `D12` | output | **【未验证】**极性与驱动电路；封装层当前恒 0 |
| `vga_hs` | `B11` | output | **【未验证】**同步极性（本工程按例程的低有效输出） |
| `vga_vs` | `B10` | output | 同上 |
| `vga_rgb[15:0]` | 见下表 | output | RGB565，位序必须按下表逐位填 |

`vga_rgb[15:0]` 的逻辑位 → 物理 pin（**bit15 = MSB 放在厂商例程列表的第一个 pin**，**【厂商例程观察】**）：

| 逻辑位 | pin | RGB565 含义 |
|---|---|---|
| `vga_rgb[15]` | `A8` | R 高位（bit 15..11 = 5 bit 红） |
| `vga_rgb[14]` | `B8` | R |
| `vga_rgb[13]` | `A9` | R |
| `vga_rgb[12]` | `B9` | R |
| `vga_rgb[11]` | `A10` | R |
| `vga_rgb[10]` | `B5` | G 高位（bit 10..5 = 6 bit 绿） |
| `vga_rgb[9]` | `A6` | G |
| `vga_rgb[8]` | `B6` | G |
| `vga_rgb[7]` | `A7` | G |
| `vga_rgb[6]` | `B7` | G |
| `vga_rgb[5]` | `A2` | B 高位（bit 4..0 = 5 bit 蓝） |
| `vga_rgb[4]` | `B2` | B |
| `vga_rgb[3]` | `A3` | B |
| `vga_rgb[2]` | `B3` | B |
| `vga_rgb[1]` | `A4` | B |
| `vga_rgb[0]` | `B4` | B |

**这 16 个 pin 为什么不按颜色连续排列、又为什么必须照抄厂商例程的位序，见第 5 节。**

填完之后建议把确认过的引脚回写成本文件第 2 节这一节的内容（或者直接写进 `.qsf`），并把"确认人 / 确认依据（原理图版本、日期）"一起记下来。

顺带需要确认的两件板级事实（本工程没有内置保护）：

- 按键的**上拉**在哪里。封装层没有加 FPGA 内部弱上拉，依赖板载上拉（例程假设"释放为 1"）。若上板读到恒 0，先查原理图，再考虑加内部弱上拉。
- `beep` 与 `led` 的驱动电路极性。

### 第三步：生成 altpll

`Tools → IP Catalog → Library → Altera IP → PLL ALTPLL`，或 `Tools → MegaWizard`，`Create a new custom IP variation`。

| 参数 | 填什么 | 依据 |
|---|---|---|
| Device | `EP4CE10F17C8` | 必须与工程器件一致，IP 会按器件查表 |
| 输入频率 | `50` MHz | 必须是**实际**晶振频率，不是"看起来接近 50"的数字 |
| 输出通道 | 至少 2 路（`clk0` → `clk_ntsc`，`clk1` → `clk_vga`）；建议再加 50 MHz 透传 | `docs/hardware/12-ntsc-clock-and-pll.md` 第 3.3 节 |
| `clk0` | 目标 21.477272 MHz | **本仓库不提供参数值**：VCO 有上下限、M/D/N 有上限，21.477272 MHz 从 50 MHz 出发**无法精确得到**，只能取最接近的可达值。枚举与误差分析见该文档第 3、7 节 |
| `clk1` | 目标 25 MHz | 50 ÷ 2 是整数比，这条比较容易满足 |

生成后**必须**做的 6 件事（与 `op_fpga_emu.sdc` 第 6 节的 `TODO(PLL)` 清单一一对应，**同一条清单的文档出处是 [`docs/hardware/12-ntsc-clock-and-pll.md`](../docs/hardware/12-ntsc-clock-and-pll.md) 第 6 节（6.1 Icarus 三层、6.2 生成并加入 altpll IP、6.3 跑 STA 与改 SDC、6.4 上板 bring-up）**）：

1. 打开生成的 IP 文件，抄下真实的 VCO 频率、每路 `multiply_by` / `divide_by` / `counter` / `duty_cycle` / `phase_shift`，写回 `docs/hardware/12-ntsc-clock-and-pll.md` 第 3.3 节，替换那里的【计算示例（未验证）】。**读生成文件和 PLL 报告的数字，不读文档里的候选值。**
2. 确认 `locked` 的极性与复位要求，按 `docs/hardware/12-ntsc-clock-and-pll.md` 第 3.5 节把它接进复位组合（`sys_rst_n & locked` 之后**各域各自**同步释放，不要共用一个域的复位去驱动另一个域）。
3. 把 `clk_ntsc` / `clk_vga` 从顶层**输入端口**改成 PLL 的内部连线。选默认顶层 `nes_ep4ce10_top` 时改 `rtl/platform/ep4ce10/nes_ep4ce10_top.v`；选封装顶层 `nes_ep4ce10_qsf_if` 时改 `rtl/platform/ep4ce10/nes_ep4ce10_qsf_if.v`（把 PLL 放在封装层，`clk_ntsc`/`clk_vga` 两个输入端口就删掉）。
4. 改 `op_fpga_emu.sdc`：删掉 `clk_ntsc` / `clk_vga` 两条 `create_clock`、删掉 `set_clock_groups`，加 `derive_pll_clocks`；然后 `report_clock_info` 确认每一条时钟的周期与 IP 实际分频一致。
5. 补两条现在**故意没写**的约束：`ce_cpu` / `ce_ppu` 的多周期路径，以及按键 50 MHz → NTSC 两级同步器的 `false_path`（`op_fpga_emu.sdc` 第 5 节有清单和理由）。漏掉多周期约束会让 STA 按 46.5608 ns 要求一条实际有 558.7 ns 余量的路径，产生假失败，也可能掩盖真实问题。
6. 确认 PLL 资源数与器件可用数匹配（EP4CE10 有 2 个 PLL【厂商例程观察】）。

---

## 3. 每个文件的作用与要点

- **`op_fpga_emu.qpf`**：只放工程身份（`PROJECT_REVISION`）和 QPF 格式版本。Quartus 打开后会用它自己的版本重写这一行。**不要**在这里放器件或文件列表，那些属于 `.qsf`。
- **`op_fpga_emu.qsf`**：
  - 器件三件套（`FAMILY` / `DEVICE` / `DEVICE_FAMILY`）；
  - `TOP_LEVEL_ENTITY`；
  - `STRATIX_DEVICE_IO_STANDARD "2.5 V"`（工程级 IO 电压起点，见第 2 节第一步）；
  - `SDC_FILE op_fpga_emu.sdc`（TimeQuest 约束文件）；
    - `rtl/nes_core/**` 的 35 个 + `rtl/platform/ep4ce10/**` 的 3 个 `VERILOG_FILE`，共 38 条，已与磁盘核对一致，见第 0.2 节；
   - **0 条** `set_location_assignment`、**0 条** `set_io_assignment`、**0 条** `PIN_LOCATION`（第 126 行只有一句"故意留空"的注释）、没有 PLL 的 `.qip`。理由见第 2 节第二步与第 6 节。
- **`op_fpga_emu.sdc`**：
  - 第 0 节 `pick_port`：一份 SDC 同时支持两种顶层；
  - 第 1 节三个 `create_clock`（50 / 21.477272 / 25 MHz）——**当前 altpll 未生成，所以后两个是"独立输入端口"而不是 generated clock**，因此本文件**没有也不能**写 `create_generated_clock`（生效条数实测为 0，唯一一次文本命中在第 11 行的注释里）；
  - 第 2 节 IO 标准；
  - 第 3 节 `set_clock_groups -asynchronous`（生效 1 条，3 个 group）：**只在这个过渡期有效**，PLL 生成后必须删；
  - 第 4 节两条 `set_false_path`（生效 2 条）：**只给复位同步器**（第 4.a 条）和 **NTSC→VGA 的 toggle CDC**（第 4.b 条），没有别的路径例外；
  - 第 5、6 节：故意没写的约束清单，以及 PLL 生成后的改写清单。
- **`../rtl/platform/ep4ce10/nes_ep4ce10_qsf_if.v`**：唯一的新增 RTL。它只做端口改名与三件小事——把 `vga_r/vga_g/vga_b` 拼回 `vga_rgb[15:0]`、用一个 25 位自由运行计数器产生 `led[0]` 心跳（约 1.49 Hz 翻转）、`beep` 恒 0（WM8978 通路还没接，见 `docs/hardware/08-wm8978-audio.md`）。`vga_de` 不接板级引脚（本板 VGA 只有 HS/VS/RGB），改驱动 `led[1]`；`audio_valid` / `audio_left` 暂不接板级引脚。**它不含任何 vendor primitive、不含任何引脚约束。**

---

## 4. 顶层二选一

### 4.1 两种顶层与端口名

`.qsf` 的 `TOP_LEVEL_ENTITY` 只能填一个。两个候选的端口名不同，这是它们最大的区别：

| 作用 | `nes_ep4ce10_top`（默认） | `nes_ep4ce10_qsf_if`（封装层） |
|---|---|---|
| 50 MHz 时钟 | `clk_sys` | `sys_clk` |
| 复位 | `reset_n` | `sys_rst_n` |
| 按键 | `key0` `key1` `key2` `key3`（4 个独立端口） | `key[3:0]` |
| VGA 同步 | `vga_hsync` `vga_vsync` | `vga_hs` `vga_vs` |
| VGA 颜色 | `vga_r[4:0]` `vga_g[5:0]` `vga_b[4:0]`（分三组） | `vga_rgb[15:0]` |
| LED / 蜂鸣器 | 无 | `led[3:0]` / `beep` |
| 音频 | `audio_valid` `audio_left[15:0]` | 无 |
| PLL 接在哪 | 改平台顶层 | 改封装层（`clk_ntsc` / `clk_vga` 变成内部信号） |
| Pin Planner 里看到什么 | 内部信号名，要自己对着板级表翻译 | 直接就是板级信号名 |

`op_fpga_emu.sdc` 用 `pick_port` 逐个试候选名，所以**两种顶层都能直接用同一份 SDC**，不用改约束。

**建议的推进顺序**：先保持默认顶层 `nes_ep4ce10_top` 跑通综合（层次最干净、报告最容易读），生成 PLL 之前再切到 `nes_ep4ce10_qsf_if`，这样 PLL 只出现在封装层，`nes_ep4ce10_top` 保持"两个时钟从端口进来"的可综合状态（`tb/platform/` 的 testbench 也依赖这个接口，改了顶层端口就要改 testbench）。

### 4.2 切换方法

改 `.qsf` 里那一行：

```tcl
set_global_assignment -name TOP_LEVEL_ENTITY nes_ep4ce10_qsf_if
```

只改这一行。`SDC_FILE`、器件、IO 电压都不用动。

### 4.3 多个顶层实体

`VERILOG_FILE` 列出的是**几乎全仓库**的模块（nes_core 35 个 + platform 3 个 = 38 条，已与磁盘核对一致），而从 `nes_ep4ce10_top` 出发的实际层次闭包只有 **16** 个模块（用 Icarus Verilog 以 `-s nes_ep4ce10_top` 展开后读生成的 vvp 里的 `.scope` 得到；只喂这 16 个文件重新展开也能通过，退出码 0）。38 − 16 = **22** 个模块不在闭包里。Quartus 会把"没有被任何模块实例化"的模块当成候选顶层实体，下面这 22 个都可能各自变成一个额外的顶层实体：

`nes_system_v0`、`nes_system_v1`、`nes_system_v2`、`nes_system_v3`、`nes_system_v5`、`nes_mapper` 与 `nes_mapper_nrom` / `nes_mapper_uxrom` / `nes_mapper_cnrom` / `nes_mapper_mmc1` / `nes_mapper_mmc3`、`ines_header_parser`、`nes_video_scaler`、`nes_chr_fetch_unit`、`nes_sprite_chr_fetch`、`wm8978_i2c`、`nes_cdc_fifo`、`nes_i2s_shifter`、`nes_audio_i2s`、`sd_spi_cmd`、`nes_ep4ce10_pll_stub`、`nes_ep4ce10_qsf_if`（选默认顶层时）。

其中 `wm8978_i2c` / `nes_cdc_fifo` / `nes_i2s_shifter` / `nes_audio_i2s` / `sd_spi_cmd` 是补进清单的 `peripheral/` 5 个模块，`nes_chr_fetch_unit` 与 `nes_sprite_chr_fetch` 是补进清单的 `ppu/` 2 个模块（见第 0.2 节）：它们进清单是为了让 `VERILOG_FILE` 与磁盘一致，**并不代表进了层次闭包**。`nes_chr_fetch_unit` 至今**没有被 `nes_ppu2c02` 例化**，CHR 外部取数通路在硬件上仍未接通；`nes_sprite_chr_fetch` 同样**没有被任何模块例化**（既不在 `nes_ppu2c02` 的 `g_chr_external` 分支里，也不在 `nes_ppu_sprite` 里），精灵 CHR 预取单元在硬件上完全没有接线，外部 CHR 模式下精灵仍然不渲染；`sd_spi_cmd` 同理没有被任何顶层例化，SD 卡通路还是独立模块。另外顶层 `nes_ep4ce10_top` 只把 `audio_sample_valid` / `audio_sample_left` 送到输出端口，WM8978 的 I2C/FIFO/I2S 通路也没接（见 `docs/hardware/08-wm8978-audio.md`）。

**【未验证】** 这份清单在 Quartus 里到底会产生几个顶层实体、各自占多少资源，必须看 `Analysis & Synthesis` 报告。三种处理办法（任选其一）：

1. `Project Navigator` 里对它们右键 → `Ignore Top-Level Entity`；
2. 把对应的 `VERILOG_FILE` 行注释掉（只影响编译，不动源文件）；
3. 先不管，先看报告里出现了几个顶层实体，再决定。

注意 `nes_video_scaler` 尤其值得处理：它是 120 KiB 的整帧参考模型，超出 EP4CE10 全部片上存储约 2.3 倍（`README.md` 与 `docs/modules/video-scaler.md` 有论证）。如果它真的被当成顶层实体综合，Fitter 会因为 M9K 不够而失败。

---

## 5. 为什么 `vga_rgb[15:0]` 的位序要与厂商例程一致

**逻辑位序和物理引脚顺序是两个不同的东西。** RGB565 的逻辑位分配是固定的：

```text
bit 15..11 = 5 bit 红   bit 10..5 = 6 bit 绿   bit 4..0 = 5 bit 蓝
```

而这 16 个 pin 在板上是 `A8, B8, A9, B9, A10, B5, A6, B6, A7, B7, A2, B2, A3, B3, A4, B4` —— 既不按颜色连续排列，也不是任何看起来整齐的顺序，**只能来自 `PIONEER_FPGA_IO.tcl` / IO XLSX 的原始声明顺序**。厂商例程把这条总线命名为 `vga_rgb[15:0]`，它的 `vga_rgb[15]` 就是列表里的第一个 pin。本工程沿用**同一条总线名和同一位序**，理由有三条：

1. **可对照。** 例程的彩条工程（`12_vga_colorbar`）用同一份位序并且是能跑的。本工程复用同一位序，Pin Planner 里的一行和例程的一行可以直接比对；换成自定义顺序，就失去了这个对照。
2. **不能"顺手排整齐"。** 如果按 R5→G6→B5 重新挑一组连续 pin 填进去，例程能跑的白/红/绿/蓝彩条在本工程就会红蓝互换——而这种错误在综合报告、TimeQuest 报告里**完全看不出来**，只在上板看颜色时才发现（`docs/hardware/05-vga-lcd.md` 第 6 节把"RGB bit 到模拟颜色的顺序"列为必须上板验证的项）。
3. **本工程的位序是构造出来的，不是搬过来的。** `nes_ep4ce10_top` 里 `vga_r = rgb565[15:11]`、`vga_g = rgb565[10:5]`、`vga_b = rgb565[4:0]`，封装层再拼回 `vga_rgb = {vga_r, vga_g, vga_b}`。这 16 位从行缓冲到引脚是**原样搬运**，中间没有任何重排，所以"哪一位对应哪个 pin"完全由这一张表决定，填错就是错。

真正能验证位序正确的方式只有两个，都必须上板：

- 跑一组已知颜色的彩条：白 = `16'hFFFF`、红 = `16'hF800`、绿 = `16'h07E0`、蓝 = `16'h001F`；
- 或者示波器分别量 VGA 连接器的 R / G / B 三个模拟通道，看哪一位的错误对应到哪个通道。

---

## 6. 未验证清单

**这一节是本目录存在的主要理由。以下每一条都没有被工具或硬件回答过。**

### 6.1 文件级

| 未验证项 | 说明 |
|---|---|
| 能不能被 Quartus 打开 | `.qpf` / `.qsf` 是按格式手写的，**从没被 Quartus 解析过、更没编译过**（本机没有安装 Quartus）。`QUARTUS_VERSION = "20.1.0"` 与 `ORIGINAL_QUARTUS_VERSION 20.1.0` 都是占位 |
| QSF 的 assignment 名字 | `SDC_FILE` 在不同版本可能显示为 `SOURCE_TSDC_FILE_NAME`；`STRATIX_DEVICE_IO_STANDARD` 的合法取值与器件是否匹配也没验证 |
| `VERILOG_FILE` 清单与磁盘是否一致 | 清单曾漏 4 个 `peripheral/` 下的模块（`wm8978_i2c.v`、`nes_cdc_fifo.v`、`nes_i2s_shifter.v`、`nes_audio_i2s.v`），其后又漏了新增的 2 个模块（`ppu/nes_chr_fetch_unit.v`、`peripheral/sd_spi_cmd.v`），本轮再漏了新增的 `ppu/nes_sprite_chr_fetch.v`；**三次都已补入**，38 条与磁盘 38 个 `.v` 逐条一致（missing = 0、ghost = 0，见第 0.2 节的自检脚本）。**仍未验证的是 Quartus 是否接受这份清单**——本机没有安装 Quartus，从没被工具解析过，更没有因为补了这些条就综合过 |
| 工程级 IO 电压 `2.5 V` | 只是【厂商例程观察】的起点。每个 bank 的 VCCIO、是否需要 3.3-V LVTTL、是否经电平转换，全部未确认 |
| 层次闭包与多顶层实体 | 第 4.3 节的 22 个模块会不会变成额外顶层、Fitter 会不会因此资源不够，未验证 |
| 新增封装层 `nes_ep4ce10_qsf_if.v` | **已用 Icarus Verilog `-g2001` 单独 elaborate 通过**（`iverilog -g2001 -Wall -s nes_ep4ce10_qsf_if`，18 个源文件，退出码 0，只有 `nes_core` 里原有的 `@*` 数组敏感性警告）。**这只是语法与层次自洽，不是综合结果**：它在 Quartus 里的资源、引脚、时序都没有测过 |
| `led[0]` 心跳约 1.49 Hz | 由 `hb_cnt_q[24]` 在 25 MHz 下翻转得出，是纸面计算；上板频率是否可接受、LED 是不是这个亮度偏好，都没测 |
| `beep` 恒 0 | WM8978 通路未接（`docs/hardware/08-wm8978-audio.md`），封装层故意不驱动它 |

### 6.2 约束级

| 未验证项 | 说明 |
|---|---|
| SDC 能否被 TimeQuest 读完 | 整份文件**从未被 TimeQuest 解析过**。任何一条命令的名字、参数、节点语法都可能在你的版本上报错（生效的 3 条 `create_clock`、1 条 `set_clock_groups`、2 条 `set_false_path`、若干 `set_instance_assignment` 全部未经校验） |
| `pick_port` 里的 `get_ports` 行为 | 端口不存在时是返回空集合还是报错，不同版本可能不同；文件里用 `catch` 兜住了，但**实际行为未验证** |
| `false_path` 的寄存器名 | `*line_ready_toggle` → `*toggle_meta` 用通配符避免写死层级，寄存器名本身来自 `rtl/nes_core/video/nes_line_buffer_vga.v`。**若工具对通配符或层级分隔符 `|` 的处理与预期不同，这两条可能匹配不到对象** |
| `set_clock_groups -asynchronous` | 只在"altpll 未生成"这个过渡状态成立。PLL 生成后必须删掉，否则会掩盖 PLL 内部的相位关系 |
| 三条 `create_clock` 的周期 | 20.000 ns / 46.5608 ns / 40.000 ns 是纸面换算，**不代表器件上真有这三颗时钟**。`clk_ntsc` / `clk_vga` 现在是自由驱动的输入端口，综合能过不等于能工作 |
| 晶振偏差 | ±20~±50 ppm 的晶振偏差没有被写进 `set_clock_uncertainty`（现在用的是 `derive_clock_uncertainty` 的自动值） |
| IO / 输出时序 | `key` / `sys_rst_n` 的板级走线延迟、VGA/LED/beep 的输出延迟全部没有约束，也没有"明确决定不约束"的书面记录 |
| `ce_cpu` / `ce_ppu` 多周期路径 | **故意没写**，见 SDC 第 5 节。写了假的多周期约束比不写更糟 |
| 亚稳态 MTBF | `set_false_path` 只让 STA 不再报告，**不解决亚稳态**。同步器第一级的 `set_max_delay` 是注释状态，取值方法待定（`docs/hardware/12-ntsc-clock-and-pll.md` 第 6.3 节） |
| 一切数字 | **没有综合报告、没有 Fitter 数字（LE / M9K / PLL 数）、没有 TimeQuest 的 fmax 与 slack、没有板级观测。** `docs/00-overview/risk-register.md` 里的 R-03 / R-05 / R-07 **仍然未关闭** |

### 6.3 引脚级

| 未验证项 | 说明 |
|---|---|
| **全部 `PIN_LOCATION`** | `.qsf` 里 `set_location_assignment` / `set_io_assignment` / `PIN_LOCATION` 的生效条数**实测各为 0**（`PIN_LOCATION` 唯一一次文本命中在第 126 行的注释里），也就是**一个引脚都没分配**。第 2 节第二步的表必须由你在 Pin Planner 里对着原理图确认后填入。**不要**把未确认的引脚号当成本工程的结论引用 |
| `docs/hardware/01-ep4ce10-board.md` 第 3.2 节与本次清单不一致 | 该节只列了 **15 个** VGA 引脚，且第 6 位是 `A5` 而不是本次给定的 `B5`，并缺 `B2`、`A3`。本次照抄给定的 16 位清单，但**两者都必须以 `PIONEER_FPGA_IO.tcl` / IO XLSX / 原理图为准**。这个不一致本次没有改动文档（约定只写新文件），请在确认引脚时一并核对 |
| 按键上拉 | 例程假设"释放为 1"，封装层没加内部弱上拉 |
| `led` 共阴/共阳 | 封装层按高电平点亮写 |
| `beep` 极性与驱动电路 | 未知，当前恒 0 |
| `vga_hs` / `vga_vs` 极性与连接器方向 | 例程是低有效同步；显示器兼容性要实测 |
| 复用冲突 | `docs/hardware/01-ep4ce10-board.md` 第 4 节列了一堆复用关系（D8/C8 的 I2C 共用、LCD 与 SDRAM 重叠等）。本工程只用 P0 信号，但"约束文件只能约束已实例化的顶层端口"，真正的复用检查要靠 Fitter 报告和原理图 |
| 配置脚复用 | 部分配置 pin 在配置完成后能否当普通 IO 由工程选项决定，不要只看信号名 |

### 6.4 PLL 相关

`altpll` **尚未生成**，因此：PLL 参数（VCO、M/D/N、占空比、相移）不存在；`clk_ntsc` 的频率误差、帧率、抖动、锁定时间全部未知；`locked` 参与复位的接法未做；`.sdc` 里**生效的 `create_generated_clock` 是 0 条**（唯一一次文本命中在第 11 行的注释里），`derive_pll_clocks` 的 2 次命中也都在 TODO 段里、**生效 0 条**。也就是说 SDC 目前把 `clk_ntsc`/`clk_vga` 当成两块自由驱动的输入引脚处理，这个前提在 PLL 生成后必须推翻。

`op_fpga_emu.sdc` 第 6 节列出了状态 A → 状态 B 的 6 步改写清单（删两条 `create_clock`、删 `set_clock_groups`、把两个时钟从顶层端口改成 PLL 内部连线并让 `locked` 参与复位、加 `derive_pll_clocks` + `report_clock_info`、补按键 CDC `false_path` 与 `ce_cpu`/`ce_ppu` 多周期约束、把 IP 的真实 VCO/分频参数抄回文档）。**同一条清单的验证步骤与通过判据在 [`docs/hardware/12-ntsc-clock-and-pll.md`](../docs/hardware/12-ntsc-clock-and-pll.md) 第 6 节**——改 SDC 前后请对照那 6.2 / 6.3 节，不要只照抄本文第 2 节第三步。

---

## 7. 与其他文档的关系

- `docs/hardware/12-ntsc-clock-and-pll.md`：第 2 节目标时钟表、第 3 节 altpll 参数清单（本文第 2 节第三步的依据）、**第 6 节验证步骤**（SDC 第 6 节 TODO 的出处）、第 5.1 节 toggle CDC、第 5.4 节读端速率 4 倍约束。
- `docs/hardware/13-platform-top.md`：第 1 节三个时钟的来源、第 2 节复位分发、第 4 节视频链三个接口。**第 6 节列的"`.qsf` / `.sdc` 待补"补的是骨架，不是证据。**
- `docs/hardware/03-clock-reset-cdc.md`：第 5.2 节异步断言同步释放（`false_path` 第 4.a 条的理由）、第 6 节 CDC 四种模式、第 9 节 SDC 检查顺序。
- `docs/hardware/01-ep4ce10-board.md`：第 2 节 IO 标准与电气前提、第 3 节板级信号总览、第 4 节引脚复用。**注意第 3.2 节的 VGA 引脚表与本目录不一致，见第 6.3 节。**
- `docs/hardware/05-vga-lcd.md`：第 2 节 RGB565 位分配与 5/6/5 输出、第 6 节"RGB bit 到模拟颜色的顺序必须上板验证"。
- `docs/hardware/09-input-and-pins.md`：第 1 节 4 键的引脚与极性、第 6 节引脚复用和资源矩阵。
- `docs/hardware/08-wm8978-audio.md`：`audio_valid` / `audio_left` 为什么现在不接引脚。
- `docs/hardware/00-overview/risk-register.md`：R-05（无 Quartus 证据）、R-07（50 MHz 到 NTSC 时钟未验证）—— 本目录**不关闭**这两条风险，只提供了关闭它们所需的输入。**注意**：该文件第 262 行写的【事实】"仓库内没有 `.qsf`、`.sdc`、`.qip`、`.ip`、`.tcl`、`.srf`、`.stp` 文件（全仓搜索 0 结果）"**已经过期**——`.qpf`/`.qsf`/`.sdc` 三个文件现在都存在（`.qip`/`.sdf` 仍然不存在）。该文件本轮不在允许修改的范围内，请下次同步时更正；本目录的实测计数见第 0.1 节。

---

## 8. 本次刻意没有做的事

- 没有安装或运行 Quartus，没有综合 / Fit / TimeQuest / 上板——`.qpf`/`.qsf`/`.sdc` 三个文件**从未在 Quartus 中打开或编译过**。
- 没有写任何 `PIN_LOCATION`：`set_location_assignment` / `set_io_assignment` 生效条数实测为 0。
- 没有生成 altpll，没有 PLL 参数：`.sdc` 生效的 `create_generated_clock` 实测为 0。
- 没有写 `ce_cpu` / `ce_ppu` 多周期约束、输入输出延迟、同步器 `set_max_delay`（SDC 里都有 TODO 与理由，这四项的生效条数实测也都是 0）。
- 没有改动 `rtl/nes_core/`、`tb/`、`tools/` 和任何既有文档（`docs/hardware/01-ep4ce10-board.md` 第 3.2 节的引脚不一致只在本文件里记录，未改原文）。
- `wm8978_i2c.v` 等 4 个 `peripheral/` 模块曾被漏在 `.qsf` 的 `VERILOG_FILE` 清单之外；其后新增的 `ppu/nes_chr_fetch_unit.v` 与 `peripheral/sd_spi_cmd.v` 也没同步进清单；本轮新增的 `ppu/nes_sprite_chr_fetch.v` 同样漏了一次。**三次都已补齐**：38 条与磁盘 38 个 `.v` 逐条一致（见第 0.2 节）。补清单只保证文件清单自洽，**不表示这些模块被综合过**。
- 除新增这 1 条 `VERILOG_FILE` 之外，没有改动 `.qsf` 里的任何 `set_global_assignment`（器件、顶层、既有 `VERILOG_FILE` 顺序、SDC 指向全部保持原样），其余改动只在注释文字。
- 没有综合过，因此"38 条清单被 Quartus 接受"这件事仍然未验证；`nes_chr_fetch_unit` 与 `nes_sprite_chr_fetch` 都**没有被 `nes_ppu2c02` 例化**——前者是 CHR 外部**背景**取数通路，后者是精灵 CHR 预取单元，两者都仍未接通。
- 没有给新增的 Verilog 加行内注释：说明性文字全部放在本文与 SDC/QSF 的注释块里。
