# 风险登记册

本文件登记当前实现中**尚未关闭**的结构性风险、证据缺口，以及已命名但仍在生效的限制。风险条目在满足各自门槛之前，不得被转述为“已解决”“已支持”“已验证”或“已完成”。

本文件描述的是**当前状态**，不是计划。缓解路线和门槛是未来动作，不得读成已有结果。

证据标记约定：

| 标记 | 含义 |
|---|---|
| 【事实】 | 可直接在仓库文件中读到的实现或文档内容，条目内给出文件与行号 |
| 【实测】 | 本机 Quartus Prime 报告文件里的数字。**报告不在仓库内**，条目内给出报告的绝对路径与章节名；引用前必须自己打开该报告核对 |
| 【审查】 | 独立审查已经写入仓库文档的结论，条目内引用该文档位置 |
| 【推断】 | 基于现有实现与器件资料的分析，**尚未经过综合、仿真或测量验证** |

当前状态的取值只有五种：`未开始`、`进行中`、`未解决`、`已关闭`、`已登记限制`。没有“基本完成”“风险较低可忽略”这类中间状态。`已关闭` 只允许在第 7 节要求的门槛有可复现证据时出现，并且必须写明**仍然残留的限定词**；只满足门槛的一部分时写成 `已关闭（部分）` 并写清哪一半已满足、哪一半已改挂别处。

## 1. 等级定义

| 等级 | 定义 | 关闭时机 |
|---|---|---|
| **S0** | 当前 RTL 已经写下的结构性选择。不修改就会让后续阶段返工，或让平台/综合结论建立在错误前提上 | 必须在启动被其阻断的阶段之前关闭 |
| **S1** | 证据与覆盖缺口。不要求返工当前 RTL，但在关闭之前不得声称对应能力“已验证”“已完成” | 必须在做出对应声明之前关闭 |
| **S2** | 已命名、范围受限的近似与已知差异。当前阶段接受并登记在案 | 不阻断当前阶段；进入相关阶段前必须重新评估 |

等级升级规则：

- S1 条目在相关阶段启动时自动升为 S0。
- S0 条目不能降级为 S1 来规避门槛；如确实要接受该风险，必须先在 `docs/00-overview/decision-log.md` 追加决策，写明被放弃的替代方案和承担的后果。
- S2 条目在相关阶段启动时不再视为“无影响”，必须重新评估并决定是关闭、升级还是继续接受。

## 2. 总览

| ID | 风险 | 等级 | 当前状态 | 阻断对象 | 关闭门槛（摘要） |
|---|---|---|---|---|---|
| R-01 | 零延迟组合 RAM/ROM 与 BRAM/SDRAM 分层冲突 | S0 | 未解决 | 平台/综合阶段 | 存储层具备显式读延迟合同，`bus_ready` 不再是常量，延迟变体 TB 通过 |
| R-02 | CPU/PPU 同相导致 PPU 滚动 dot 被跳过 | S0 | 未解决（当前被 TB 断言为预期行为） | v1 功能完成、平台阶段 | 滚动更新不再被 CPU 访问删除，系统级 TB 断言跳过数为 0 |
| R-03 | CHR/nametable 多端口与常量除法/取模的时序风险 | S0 | 未解决（**面积已实测、BRAM 0/46 已实测；时序仍未测量**，见第 10 节） | 平台/综合阶段 | 存在 PPU 单独综合的 M9K/LE 报告；**最差 slack 与未约束路径仍未测量**；重构后逐像素等价性 TB 通过 |
| R-04 | PRG / 8 KiB CHR 留在片上对 EP4CE10 BRAM 的压力（`PRG_SIZE_BYTES` 正在参数化） | S0 | 未解决（与 R-01、R-03 耦合；**第 10 节的实测表明 BRAM 不是绑定约束**，M9K 估算表的算术已更正） | 平台/综合阶段、ROM 容量范围 | `PRG_SIZE_BYTES` 取值被正式决定，存储预算表 + NES-only Fitter 报告含 VGA/音频/SDRAM FIFO 预留行 |
| R-05 | 当前无 Quartus / ModelSim / 上板证据 | S1 | 未开始（**Quartus Prime Lite 23.1 已安装，第 10 节有一份 PPU-only 的 map+fit 报告；但属于本仓库顶层的编译/布局布线报告与板级 bring-up 仍然没有**） | 任何“已上板/已通过综合”声明 | 属于本项目的 Fitter/TimeQuest 报告 + 一次可观测的板级 bring-up |
| R-06 | 当前 NMI 端到端覆盖缺口 | S1 | 未解决 | v1 功能完成声明 | 系统级 NMI TB 通过，NMI 形式在 CPU 合同中有明确约定 |
| R-07 | 50 MHz 到 NTSC/VGA/音频时钟未实现、未验证 | S0 | 未开始 | 所有视频/音频时序、平台/综合阶段 | PLL IP 已生成并由 TimeQuest 确认；绝对频率与 3:1 比例都有断言和实测证据 |
| R-08 | 精灵 slot 选择的组合开销（每 `ce` 一次 64 项 OAM 范围扫描） | S0 | **已关闭（部分）**：重复逻辑与回归时长已解决；面积/时序仍无 Fitter 证据，已改挂 R-03 / R-05 | — | 门槛已按 9.3 / 9.4 满足：27 万余 tick 逐 dot 等价、A/B 四行逐字节不变、`ppu-ext-chr-tb` 821.6 s → 162.5 s。**不覆盖面积与 fmax**，那一半仍未测量 |
| L-17 | **外部 CHR 共享地址总线上的读/写碰撞**：`$2007` 写 CHR 已实现，但写**不压制** `chr_req`，两者可在同一 `ce` 上同时为高 | S0 | **未解决**（已测量、未修复） | 任何"外部 CHR 通路整体可用"的声明、渲染期写 CHR 的软件 | 碰撞在 RTL 层被消除（压制 `chr_req` / 总线握手 / 上传窗口限制三者之一），并有覆盖"渲染开启时写 CHR"的 TB 场景 |

与 `docs/00-overview/verification-plan.md` 的对应关系：R-01/R-03/R-04 是 L5 的前置条件；R-06 是 L1/L4 的覆盖缺口；R-05 决定 L5 能否从“未开始”进入进行中；R-07 同样是 L5 的前置条件，因为它决定平台顶层的时钟结构。R-08 的**重复逻辑与回归时长这一半已关闭**（见第 9 节）：`nes_ppu2c02` 不再重复实现 `nes_ppu_sprite` 已有的精灵范围扫描，`ppu-ext-chr-tb` 占全量从 45.26% 降到 16.83%、全量从 1815.3 s 降到 965.6 s。**它关闭的只是回归时长与重复逻辑，面积与 fmax 仍然没有 Fitter 证据**，那部分仍由 R-03 与 R-05 承担。

## 3. S0 风险

### R-01 零延迟组合 RAM/ROM 与 BRAM/SDRAM 分层冲突

**等级/状态：** S0 / 未解决

**触发条件**

- 把 `nes_system_v0` 或 `nes_ppu2c02` 直接作为 Quartus 综合源。
- 让平台层沿用当前顶层的接法，即把 `bus_ready` 恒定接高。
- 任何把 PRG/CHR 从数组搬到 BRAM 或 SDRAM 的改动，若不同时修改 CPU 侧的等待语义。

**影响**

- 当前设计假设一次 CPU 总线事务在同一个时钟沿完成。同步 BRAM 的 1–2 clk 读延迟和 SDRAM 的 CAS/刷新/突发延迟都无法用这种接口表达。
- 直接综合的结果不是“慢一点”，而是 BRAM 无法按预期推断、组合逻辑被塞进 LE，或时序失败。此时产出的资源数字与 fmax 报告全部不可用，R-03 与 R-04 也因此无法被测量。
- 与已采用的架构约束正面冲突：`architecture.md` 第 4 节明确禁止向 CPU 暴露没有 ready/hold 语义的“瞬间数组读”，第 9 节把 PRG/CHR 规划到 SDRAM 层。当前 RTL 是这条约束的反例。这属于已知缺口，不是对决策的修改。
- 迁移前若已开始写平台层，平台层的时序假设、owner 划分和 FIFO 深度都会建立在错误的延迟模型上，需要整体返工。

**证据**

- 【事实】`rtl/nes_core/system/nes_system_v0.v:65-73`：`always @*` 组合读 `cpu_ram[ram_index]`（`:67`）与 `prg_rom[prg_index]`（`:71`），同一拍直接产出 `cpu_din`。
- 【事实】`rtl/nes_core/system/nes_system_v0.v:86`：`.bus_ready(!reset)` —— 顶层把 ready 恒定接高，CPU 从不进入等待态。
- 【事实】`rtl/nes_core/ppu/nes_ppu2c02.v:643-649`：`g_chr_internal` 的 `$2007` 读回 mux（`chr_rb_eff` / `chr_rb_cs` / `chr_rb_data`）组合读 CHR（`:647`）、nametable（`:648`）、palette（`:649`）——`575e191` 之前这个位置是内部 `ppu_space_read` 函数，**该函数已被删除**；`g_chr_external` 里的同名函数**仍然存在**（`:651-661`），它组合读 nametable（`:657`）与 palette（`:659`），而 `address < 14'h2000` 的 CHR 半边**直接返回 `8'h00`、不读任何 CHR 阵列**（`:654-655`），由 `:839-842` 的外部 `chr_rb_data` 用 `chr_rd_armed_q ? chr_rdata : 8'h00` 回答。背景像素通路同样是组合读：nametable `:548-549`、CHR `:596-597`（**仅内部 CHR 分支**；外部 CHR 分支的 `bg_pattern_low` / `bg_pattern_high` 读的是 `bg_lo_q` / `bg_hi_q` 锁存器，`:723-724`）、palette `:566`。
- 【事实】`rtl/nes_core/cpu/nes_cpu6502.v` 的状态推进只发生在 `bus_fire` 边界，等待语义在 CPU 侧已经具备，缺口在顶层接线。
- 【审查】`docs/00-overview/decision-log.md` D005 的“边界”已写明：CPU 与外部存储的集成 RTL 尚未存在，该决策目前只是接口和目录约束。
- 【事实】`docs/hardware/04-memory-and-fifo.md` 第 2 节给出同步 RAM 延迟模型和 6 项必须回答的问题；第 2.3 节明确提示“用组合地址加法器直接读 BRAM，工具可能无法按预期推断存储器”。

**缓解路线**

1. 在 `rtl/nes_core/system/` 之下引入显式的存储/总线层，为每类存储写死一份“请求级 → 数据返回级”的延迟合同（建议先定 1 clk 与 2 clk 两档），由该层产生 `bus_ready`，不再由顶层常量驱动。
2. 把所有数组读改为可推断形式（地址寄存 + 同步读 + 可选旁路），保证 `bus_din` 与发起请求对齐；需要跨多级时用 tag 而不是假设固定延迟。
3. CPU 状态机不需要为此改动：现有 `bus_req` / `bus_ready` / `bus_fire` 合同已经能表达等待。
4. PPU 的 `$2007` 读缓冲与背景取数各自定义延迟合同，不与 CPU 事务共用隐含的零延迟假设。
5. 迁移完成后，用“注入 N 拍延迟的存储模型”重跑现有三个 TB，行为结论必须与零延迟版本逐条相同。

**进入下一阶段前的门槛**

- 存在一份文档化的存储延迟合同，逐类写明：请求沿、数据返回沿、`bus_ready` 行为、复位策略、访问者与仲裁规则。
- `nes_system_v0` 的 `bus_ready` 不再是常量表达式。
- 现有 CPU bus testbench 存在一个开启延迟注入的变体，断言延迟期间 `bus_addr` / `bus_we` / `bus_dout` 保持稳定，且延迟结束后事务序列与零延迟版本逐条相同。
- 未满足以上三条之前，`verification-plan.md` 的 L5 不得从“未开始”进入进行中。

### R-02 CPU/PPU 同相导致 PPU 滚动 dot 被跳过

**等级/状态：** S0 / 未解决（当前被 testbench 断言为预期行为）

**触发条件**

- 保持 `nes_system_v0.v` 的 12 拍使能分配：`ce_cpu` 只在 `div_phase==0` 有效，而该拍必然也是 `ce_ppu` 的有效拍。
- 任何在渲染开启期间访问 `$2000-$3FFF` 的 CPU 程序：滚动写入、`$2007` 取像素、nametable 更新、NMI 处理器。
- `$2006` 写恰好命中 pre-render 扫描线的 dot 280–304。

**影响**

- PPU 的内部滚动更新只在 `reg_cs=0` 的 `ce` 沿执行，因此每一次落在 PPU 地址空间的 CPU 事务都会**删除**该 dot 的滚动更新，而不是延后补做。后果按命中点分级：
  - 命中 dot 8–248 的 `inc_x`：该点之后的 coarse X 少进一格，表现为该扫描线自命中点起约一个 tile（8 px）的横向错切，且不恢复。
  - 命中 dot 256：整条扫描线的垂直进位丢失，`v` 的 coarse Y 与 nametable 选择在下一条扫描线整体偏移。
  - 命中 dot 257：水平分量（`t` 的 coarse X 与 nametable X）不重载，该扫描线起横向滚动错位。
  - 命中 pre-render 的 dot 280–304：**整帧**的垂直分量不重载，该帧及之后所有扫描线的纵向滚动都基于错误的 `v`。
- 真实 2C02 的行为不是“停止内部取数”：内部取数继续，寄存器写只造成 `v` 的写入 glitch、`inc_x`/`inc_y` 部分生效，以及可见区/不可见区的差异。当前模型在这一点上比真实硬件更差，不是更宽松。
- 现有系统 testbench 把该行为断言为**通过条件**而非缺陷：断言每个寄存器访问恰好浪费一个 dot（本测试 26 个），并断言帧长恰好 `262×341×4 = 357368` 个 clk。修复同相问题必然使这两条断言失效，必须同步修改并说明理由，不能为了让 TB 通过而删除断言。
- 同一 TB 的背景像素断言只覆盖 nametable 全零 + 单一 tile 的退化场景，且渲染在第一帧内才打开、第二帧才检查。因此现有 PASS 不构成对真实滚动游戏的证据。

**证据**

- 【事实】`rtl/nes_core/system/nes_system_v0.v:26-27`：`ce_ppu = (div_phase[1:0]==2'b00)`，`ce_cpu = (div_phase==4'd0)` —— 后者恒为前者的一个子集，因此 CPU 与 PPU 永远同相。
- 【事实】`rtl/nes_core/system/nes_system_v0.v:62`：`ppu_reg_cs = cpu_bus_fire && sel_ppu`，PPU 寄存器片选直接来自 CPU 事务完成。
- 【事实】`rtl/nes_core/ppu/nes_ppu2c02.v:1000`：滚动更新条件为 `mask_reg[3] && !reg_cs && ((scanline < 9'd240) || (scanline == 9'd261))`；`:1003-1004`（dot 8–248 每 8 dot 一次 `inc_x`）、`:1001-1002`（dot 256 的 `inc_x+inc_y`）、`:1006-1009`（dot 257 水平重载）、`:1011-1015`（pre-render dot 280–304 垂直重载）全部落在这个条件内。
- 【事实】`rtl/nes_core/ppu/nes_ppu2c02.v:873-887`：`pixel_valid` / `pixel_index` 是纯组合输出。**背景取数通路在内部 CHR 分支不含任何 dot 级流水或预取状态**；`g_chr_external` 分支则有一条逐 tile 的 dot 级取数流水（`nes_chr_fetch_unit` 例化在 `:789-803`，`bg_lo_q` / `bg_hi_q` / `bg_ready` 锁存在 `:816-828`，`bg_pattern_low` / `bg_pattern_high` 读的是锁存器 `:723-724`）——像素输出本身在两个分支里都仍是纯组合。
- 【审查】`tb/ppu/README.md`“同一时钟沿的冲突合同”已明确记录：同沿 `reg_cs=1` 时该 dot 的滚动更新**被跳过而不是延后补做**，并把它列为 v0 的明确简化。
- 【审查】`tb/system/README.md`“时钟分配与 CPU/PPU 同相取舍”已把同相断言与“被跳过的 dot 计数”写成通过条件；同文件“集成限制”已记录 TB 只覆盖背景功能级取数，且锁死了 12 拍使能分配。
- 【事实】`tb/ppu/README.md`“明确未实现”已列出奇数帧跳 dot 未实现。该项与本条同源但独立，不合并计数（见 L-06）。

**缓解路线**

1. 把 PPU 内部取数与 CPU 寄存器访问解耦：滚动更新按 PPU 自己的 `ce` 无条件执行，不再以 `reg_cs=0` 为前提。
2. 为 `$2000` / `$2005` / `$2006` 写与同拍滚动更新定义明确的优先级（写入胜出且增量照常发生，或反之），并把该合同写进 `tb/ppu/README.md` 的冲突合同。不建模的部分必须显式列为未实现。
3. 相位解耦作为独立改动单独评估：把 `ce_cpu` 移出 `ce_ppu` 的有效拍可消除“每次事务都吃掉一个 dot”的系统性耦合，但不能替代第 1、2 步，因为真实硬件在同拍仍有 glitch。
4. 若最终决定不追求硬件等价的冲突行为，则必须在系统级给出“允许的滚动更新丢失预算”的明确上界，且该上界必须小于任何真实游戏的每扫描线 PPU 访问数。

**进入下一阶段前的门槛**

- 系统级 TB 断言：渲染开启的一帧内被删除的滚动更新数为 0，或存在已记录并被断言覆盖的例外表。
- 新增一个使用 `PPUCTRL[7]=1`、在 vblank 写 `$2005`/`$2006`、并在可见区用 `$2007` 取像素的 NROM 程序，断言整帧 `pixel_index` 与固定参考 trace 逐像素一致。
- `tb/system/README.md` 中“每访问浪费一个 dot”和“帧长 357368 clk”两条断言按新的使能分配与合同更新，更新理由写入文档。
- PPU 单模块层面：pre-render dot 280–304 被 CPU 写命中时，垂直重载仍然发生；或该行为被显式登记为已知限制并给出影响范围。

### R-03 CHR/nametable 多端口与常量除法/取模的时序风险

**等级/状态：** S0 / 未解决（**面积与 BRAM 推断已实测，见第 10 节；时序（fmax / 最差 slack / 未约束路径）仍未测量，因此本条不标"已关闭（部分）"**）

**触发条件**

- 对 `nes_ppu2c02` 做任何 Quartus 综合或布局布线（当前从未做过）。
- 保持背景像素通路的现有写法：逐像素组合读 nametable 两次、CHR 两次、palette 一次。
- 改为 BRAM 可推断的寄存读后，地址生成逻辑必须在一个周期内稳定。

**影响**

- 端口需求：**内部 CHR 路径**（`EXTERNAL_CHR = 1'b0`，即 `nes_system_v0`..`v5` 与平台顶层跑的那条）按当前 RTL，`nametable_ram` 需要 **3 个组合读口**（`:548` 名称、`:549` 属性、`:648` 经 `chr_rb_data` mux 的 `$2007` 路径）加 1 个写口（`:961`）；**外部 CHR 路径**（`EXTERNAL_CHR = 1'b1`）下是 **4 个组合读口**（`:548`、`:549`、`:657` 经 `g_chr_external` 里**仍然存在**的 `ppu_space_read`、`:719` `bg_name_target` 给取数支路）加同一个写口（`:961`）。**两个分支合计 5 个读点，但它们分属互斥的 `generate` 分支，任何一次 elaboration 只存在其中一个集合**；`chr_ram` 需要 **19 个组合读口**（`:596`、`:597` 是背景低/高两个平面，`:604` 与 `:606` 是 `g_sprite_chr_slots` 里 8 次迭代 × 2 个平面展开出的 **16** 个生成读口，`:647` 是 `chr_rb_data` 的 `$2007` 读回）加 1 个写口（`:637`）。**这 19 个读口本身就已经远超 M9K 的 1R1W，与第 10 节实测的 `0 / 46` M9K 一致**（10.1）。本条原来记的"3 个组合读口（`:486`、`:487`、`:478`）加 1 个写口（`:518`）"是 `575e191` 之前的行号，**那四个行号现在不对应当前的任何 `chr_ram` 引用**：内部 `g_chr_internal` 的 `ppu_space_read` 函数已在 `575e191` 删除，替换它的是 `:643-649` 的 `chr_rb_eff` / `chr_rb_cs` / `chr_rb_data` mux（10.4 记的就是这批删除与合并）。**历史对照**：`575e191` 之前内部路径用 8,192 次常量索引的 `g_chr_flatten` 展开 `sprite_chr_bus`，那才是本条最早的读口压力来源；它已被删除，替代物是现在的 8 次迭代 / 16 次读，逐条见 10.4，**本条不把 8,192 当作现状**。Cyclone IV E 的 M9K 是 1R1W，因此这些数组**按现状无法映射为 BRAM**，只能复制成多份（加深 R-04 的压力）或退化为分布式 LUT RAM（吃 LE、增延迟）。**外部 CHR 路径**（`nes_system_v6` 的 `EXTERNAL_CHR = 1'b1`）把 `chr_ram` 的多个读口换成**单口**外部总线（`chr_req` + `chr_addr` → `chr_rdata`），所以它**降低**了 BRAM 端口压力，但把压力转移成一个新的外部接口义务（见第 6 节与 R-01/R-04）。**注意两个路径不能同时按现在的写法映射 BRAM**——`nes_system_v6` 的顶层端口是纯 RTL，没有引脚、没有存储实现。
- 关键路径：背景像素输出 `pixel_index` 的组合链为 `dot`/`fine_x`/`t` → 加法器（`:537-540`）→ `/30` 与 `%30`（`:541`、`:543`）→ nametable 地址（`:546-547`）→ nametable 读（`:548-549`）→ CHR 地址（`:551`）→ CHR 读（`:596-597`）→ 位选择（`:550`、`:552`）→ palette 索引（`:562-565`）→ palette 读（`:566`）→ `pixel_index`（`:881`）。其中 `/30` 与 `%30` 在 7 位输入上综合为比较器/LUT 链，位置正处于两级 RAM 地址之间。**这条链是内部 CHR 分支的**；`g_chr_external` 分支的 nametable 读、CHR 地址计算同源，但末端那两级组合读换成了 `bg_lo_q` / `bg_hi_q` 锁存器输出（`:723-724`），所以它的末端少两级组合读、多一级寄存器。
- 仿真的数组索引没有端口概念，因此**当前三个 TB 全绿不能排除本条风险**。它只能在综合报告中暴露。
- 若综合后被迫复制数组，BRAM 占用会超出 R-04 的估算，平台阶段的容量结论需要重做。

**证据**

- 【事实】`rtl/nes_core/ppu/nes_ppu2c02.v:416-419`：`nametable_ram[0:2047]`、`chr_ram[0:8191]`、`oam_ram[0:255]`、`palette_ram[0:31]` 均为 Verilog-2001 数组，没有端口模式、读延迟或旁路参数。
- 【事实】同文件 `:548-549`（同拍两次 `nametable_ram[...]`）、`:596-597`（同拍两次 `chr_ram[...]`，**仅内部 CHR 分支**）、`:566`（`palette_ram[...]` 组合读进像素输出）、`:637` / `:961` / `:963`（同拍分别写 `chr_ram` / `nametable_ram` / `palette_ram`）、`:643-649`（内部 CHR 分支的 `$2007` 读经 `chr_rb_data` mux **再走一次** CHR / nametable / palette 组合读）、`:651-661`（外部 CHR 分支的 `ppu_space_read` **仍在**，由 `:841-842` 调用，CHR 半边返回 `8'h00`）。
- 【事实】同文件 `:541` `bg_vertical_sections = bg_coarse_y_sum / 7'd30;` 与 `:543` `bg_coarse_y = bg_coarse_y_sum % 7'd30;`。
- 【事实】`rtl/nes_core/system/nes_system_v0.v:26-27`（`nes_system_v1`..`v6` 全部相同，`nes_system_v6.v:176-177`）：`ce_ppu = !reset && (div_phase[1:0] == 2'b00)`，`ce_cpu = !reset && (div_phase == 4'd0)`。`div_phase` 是 4 bit 计数器、循环 0..11，因此 **12 个系统 clk = 1 个 CPU 总线周期 = 3 个 PPU dot**，即**每个 dot 是 4 个系统 clk，其中 3 个 `ce` 为高、1 个为低**。`tb/system/README.md:58-59` 把同一件事写成"12 拍中 1 拍（`ce_cpu`）/ 12 拍中 3 拍（`ce_ppu`），1 dot = 4 clk"，`tb/system/tb_nes_system_v6.v:4840` 的断言文本也写"4 clk per ppu ce"。**任何"每个 dot 有 9 个空闲 clk"的说法与这三处 RTL/文档矛盾，本仓库不采用。**
- 【事实】`docs/hardware/01-ep4ce10-board.md` 与 `docs/hardware/04-memory-and-fifo.md` 记录 423,936 memory bits，等于 46 × 9,216 bit（46 个 M9K）；`04-memory-and-fifo.md` 第 1.2 节要求容量表必须列出端口模式，并警告不要按理论总量相加。
- 【实测】**PPU 单独综合已做，面积这一半有报告**：`D:\quartusProject\ppu_synth2\final_ext.map.rpt`（Analysis & Synthesis）与 `final_ext.fit.rpt`（Fitter），器件 `EP4CE10F17C8`，Quartus Prime 23.1std.0 Build 991 SC Lite Edition。全部数字、来源、anti-folding 对照组、四个合法性缺陷、以及**未测量的部分**见第 10 节。本条下面不再重复这些数字。
- 【实测】上述报告确认 R-03 担心的那件事真的发生了：`final_ext.fit.rpt` 的 `Error (170011): Design contains 44323 blocks of type combinational node.  However, the device contains only 10320 blocks.` 与 `Error (171000): Can't fit design in device`；同时 `Total memory bits ; 0 / 423,936 ( 0 % )`——**BRAM 一个 bit 都没用上**，四个 `lpm_divide` 之外没有任何存储原语进网表。
- 【推断】**仍然未测量**：fmax、最差 slack、未约束端点。每次跑都出 `Critical Warning (332012): Synopsys Design Constraints File file not found`（没有 SDC、没有引脚分配），所以第 1、2 条缓解路线的取舍**至今没有被时序数据回答过**。

**缓解路线**

1. 把背景通路改造成标准的 2-tile 预取流水（nametable → attribute → CHR 低/高面，跨多个 dot 取数），端口需求降到 1R1W，同时解决“功能级逐像素取数不表达真实取数时序”的问题（见 L-10）。
2. 移除每像素的 `/30` 与 `%30`：coarse Y 的段选择在垂直重载 dot 一次性确定，或用比较/减法替代除法。
3. 决定 CHR/nametable 的端口归属与仲裁（CPU `$2007` 访问与 PPU 内部取数同时发生时谁优先），并把结论写入 `docs/00-overview/architecture.md` 第 8 节。
4. 保留当前功能级取数作为等价性基准，重构后的 RTL 与它逐像素比对。
5. 先做一次“只综合 PPU”的最小工程，尽早拿到真实 M9K/fmax，再决定是否投入完整流水重构。

**进入下一阶段前的门槛**

- 存在一次 PPU 单独综合的 Quartus 报告（Fitter + TimeQuest），记录 M9K 数量、LE 数量、最差 slack 和未约束路径。**门槛核对（截至第 10 节写入时）：M9K 与 LE 两项已满足**（`D:\quartusProject\ppu_synth2\final_ext.fit.rpt`，63,127 LE、0/46 M9K），**最差 slack 与未约束路径两项未满足**——那次跑没有 SDC、也没有引脚分配，TimeQuest 因此没有给出任何时序数字。所以本条**不能**标"已关闭（部分）"，只标"未解决（面积与 BRAM 已实测，时序未测量）"。
- 报告结论要么证明当前结构可接受（则在本条下记录 fmax 与端口代价），要么触发缓解路线的第 1、2 步。**这一条未满足**：报告没有 fmax，第 1、2 步因此**没有被触发也没有被否决**。第 10 节只登记面积事实，不代替这个判断。
- 重构后：`pixel_valid` / `pixel_index` 在随机 tile/attribute/palette/fine X/fine Y 图案下与重构前的功能级模型逐像素相同，并有可复现的 TB。**未满足**（重构没有做）。
- 第 10 节登记的 PPU 资源数字**只覆盖 `nes_ppu2c02` 加它的三个子单元加一个计数器驱动的激励包装**，不是整芯片、也不是 `nes_ep4ce10_top`。引用时必须带这个范围限定词。
- **额外一项（`nes_system_v6` 引入）**：外部 CHR 路径把 CHR 从"片上多读口数组"换成"单口外部总线"，这条路径的资源结论**不在**上面任何一条门槛覆盖范围内——它需要一条新的门槛：**外部 CHR 存储器方案确定并落地**（容量、时序、接口），且有对应的综合数字。**这一条门槛至今一条都没有满足**：128 KiB CHR 只存在于 testbench。
- **额外一项（`$2007` 外部 CHR 写通路落地后，`5cc36e7` / `576cc74`）**：外部路径现在**不只读，还写**。这给资源与时序两条各加了一条新义务，两者都**没有**被上面任何门槛覆盖：**(a) BRAM 推断没有任何证据**——外部 CHR 存储器上的**同址同拍写读冲突**在本仓库的模型里是 undefined、testbench 建模成 read-first，真双口（true dual port）够不够、还是必须 simple dual port，**只能由综合回答**，而本仓库没有综合。**(b) 写截止期没有任何合同**——`chr_req` 每 2 个 `ce` 就要一个字节、`chr_we` 不参与任何握手，这两条读侧义务现在同样适用于写侧。这两条与 R-01 / R-04 耦合，且**只能**在外部存储方案落地后一起评估。

### R-04 PRG / 8 KiB CHR 留在片上对 EP4CE10 BRAM 的压力

**等级/状态：** S0 / 未解决（与 R-01、R-03 耦合）

> **注意一（2026 年的 v6 增量）**：128 KiB CHR 的需求**不再是"片上阵列"问题，而是"外部接口"问题**。`nes_system_v6` 把 PPU 的 CHR 通路改成单口外部总线（`chr_req` / `chr_addr` → `chr_rdata`），`CHR_ADDR_BITS = 17` 就是这条接口的地址宽度承诺。因此下面那张 M9K 估算表里的 `chr_ram` 一行**只对内部 CHR 路径有效**；走 v6 路径时，CHR 的 128 KiB 落在片外，容量问题的**关闭路径从"选一个更小的 `PRG_SIZE_BYTES`"变成"把外部存储接上"**——而这正是 R-01（零延迟组合 RAM/ROM 与 BRAM/SDRAM 分层冲突）与 R-04 的 SDRAM 一侧。**本轮没有做出任何容量决定**：片上仍无 CHR 存储，SDRAM 控制器尚不存在。

> **注意三（`$2007` 外部 CHR 写通路落地后，`5cc36e7` / `576cc74`）**：外部 CHR 现在**不只读、还写**，`$2007` 写到 `< $2000` 会变成一次 `chr_we` strobe 并经 `nes_mapper` 的 `chr_ram_we` 到达外部端口（`nes_mapper.v` **一行未改**）。**这不改变上面任何一条容量估算**——128 KiB 仍然落在片外，片上 M9K 计数不变；**但它给存储方案新增了三条与容量无关的义务**，都还没有答案：**(a)** 外部 CHR 存储器必须能承受**写**，且**同址同拍的写读冲突**语义（true dual port vs simple dual port）**只能由综合回答**，本仓库的模型把它建模成 read-first；**(b)** 写侧同样**没有背压**、**没有握手**，`chr_we` 是无条件 strobe，接受与否只由 `chr_ram_enable_r` 决定；**(c)** 共享 CHR 地址总线上**写与取数读会撞**（见 L-17）。因此"接上 SDRAM"这件事比只读时**多了一层约束**，R-01 / R-03 / L-17 都要在方案落地时一起重评。

> **注意二：PRG 容量正在被参数化。** `nes_system_v0` 已把 PRG 从固定 `prg_rom [0:32767]` 改为参数 `PRG_SIZE_BYTES`（当前默认 `16384`），并用 `prg_addr_window = cpu_addr[14:0]` 加位掩码做镜像窗口。因此“PRG 占多少 BRAM”现在是一个**尚未决定的选择**，不是一个固定事实。本条同时覆盖 16 KiB 与 32 KiB 两种取值，因为两者都会阻断平台阶段。`rtl/nes_core/system/nes_system_v0.v` 处于活跃修改状态，下面的行号与数值以本文件写入时的内容为准，决策时必须重新核对。

**触发条件**

- 把 PRG 与 CHR 数组保留在片上，无论 `PRG_SIZE_BYTES` 取 16 KiB 还是 32 KiB。
- 在此基础上再加入 VGA 行缓存或双缓冲、音频 FIFO，以及 `docs/hardware/04-memory-and-fifo.md` 记录的 2 个 16 bit × 1024 SDRAM FIFO。

**影响**

- 器件片上存储总量 423,936 bit = 46 × 9,216 bit，即 46 个 M9K。
- **（2026-09-30 更正）8 位宽模式下 M9K 的可用深度是 1,024 byte，不是 1,152 byte。** `9,216 / 8 = 1,152` 要求 M9K 被配置成 1,152×8，而这**不是器件支持的位宽模式**：`docs/hardware/04-memory-and-fifo.md` 第 1.2 节列出的位宽是 1 / 2 / 4 / 9 / 18 / 36 bit，8 bit 不在其中；8 bit 负载要落在 9 bit 模式上，即 1,024×9 = 9,216 bit，因此**每块 M9K 只能提供 1,024 byte**。下面整张表按 1,024 byte 向上取整，**PRG 两行与两个合计因此都被改写**（原表按 9,216 bit 直接取整，低估了 PRG）。
  - 同一原因下，`01-ep4ce10-board.md:11` 与 `00-index.md:104` 写的"423,936 bit ≈ 52,992 byte ≈ 51.75 KiB"是**按 bit 数除以 8 的换算值，不是可实现的字节容量**。按 1,024 byte/M9K，46 块的实际可用负载是 47,104 byte（46.0 KiB）。**本条不改那两处**，只在此登记这个区别：任何"BRAM 够不够"的判断必须用 47,104 byte 这个数，不能用 52,992。
- 按 8 位宽模式（**每 M9K 1,024 byte**，理由见上一条）逐数组向上取整的**估算**：

  | 数组 | 深度×位宽 | bit | 字节 | 估计 M9K（原值 → 现值） | 当前端口需求 |
  |---|---|---|---|---|---|
  | `prg_rom`（`PRG_SIZE_BYTES = 16384`，当前默认） | 16384×8 | 131,072 | 16,384 | 15 → **16** | 1 组合读 |
  | `prg_rom`（`PRG_SIZE_BYTES = 32768`） | 32768×8 | 262,144 | 32,768 | 29 → **32** | 1 组合读 |
  | `chr_ram` | 8192×8 | 65,536 | 8,192 | 8 → **8**（未变） | **19 组合读 + 1 写**（**仅内部 CHR 路径**；`nes_system_v6` 的外部路径没有片上 `chr_ram`，见上面注意一。逐条行号见 R-03） |
  | `nametable_ram` | 2048×8 | 16,384 | 2,048 | 2 → **2**（未变） | **内部 CHR 路径 3 组合读 + 1 写；外部 CHR 路径 4 组合读 + 1 写**（两分支合计 5 个读点、分属互斥的 `generate` 分支，逐条行号见 R-03） |
  | `cpu_ram` | 2048×8 | 16,384 | 2,048 | 2 → **2**（未变） | 1 组合读 + 1 写 |
  | `oam_ram` | 256×8 | 2,048 | 256 | 1 → **1**（未变） | 1 组合读 + 1 写 |
  | `palette_ram` | 32×8 | 256 | 32 | 1 → **1**（未变） | 约 3 组合读 + 1 写 |
  | **合计（PRG = 16 KiB）** | — | **231,680** | 28,960 | 29 → **30** | 46 中剩约 16 |
  | **合计（PRG = 32 KiB）** | — | **362,752** | 45,344 | 43 → **46** | **46 中剩 0** |

- 更正后的两种取值都不足以容纳完整平台（**下面每个数字都已按上表的现值重算**）：
  - **PRG = 32 KiB**：NES 存储吃掉 **46/46** 个 M9K，**一个都不剩**（原写"约 43/46，剩约 3"）。SDRAM 例程的两个 FIFO（16 bit × 1024，各 16,384 bit）因此**完全无处可放**。
  - **PRG = 16 KiB**：剩约 16 个 M9K，扣掉 SDRAM FIFO 对（8 bit 宽 4 个 / 16 bit 宽 8 个）后剩约 12 / 8 个。一个 4096 帧的 32 bit 立体声音频 FIFO 需要 16,384 byte（16 bit 宽下需 8 个 M9K），再加 VGA 行缓存，16 个 M9K 仍然不够。位宽选择会改变计数，这正是 `04-memory-and-fifo.md` 反复强调的不能按理论总量相加。
- 逐数组向上取整造成的浪费是真实的：M9K 不能跨数组按位拼接。PRG = 16 KiB 时位总数余量约 192,256 bit，但按 1,024 byte/块取整后只剩约 16 块。
- **【实测】但 BRAM 并不是本项目的绑定约束**（第 10 节）：PPU 自身实测用掉 **0 / 46** 个 M9K。下面是把它自己那几个数组的容量需求放回器件之后的算术（**按每数组 1,024 byte/M9K 向上取整，因为 M9K 不能跨数组拼接**）：

  | 配置 | 数组 | 字节 | M9K |
  |---|---|---|---|
  | 外部 CHR | `nametable_ram` 2,048 + `oam_ram` 256 + `palette_ram` 32 | **2,336** | 2 + 1 + 1 = **4** |
  | 外部 CHR | 以上小计 vs 器件 46 块 | — | **剩 42 块** |
  | 内部 CHR | 以上 + `chr_ram` 8,192 | **10,528** | 4 + 8 = **12** |
  | 内部 CHR | 以上小计 vs 器件 46 块 | — | **剩 34 块** |
  | （参考）片上放 128 KiB CHR ROM | 131,072 | **需 128 块** | **超出 46，装不下** |

  **这解释了第 10 节的实测**：PPU 现在一个 M9K 都没用（10.1 / 10.2），而它**如果**能推断成 BRAM 也只需要 4 到 12 块。**BRAM 有 34 到 42 块空闲，绑定约束是逻辑单元（63,127 / 10,320）。** 这只是容量算术，**不构成"应该改成 BRAM"或"不应该改"的任何结论**——能不能推断成 BRAM 一次都没被测过（10.5 节）。
- **【事实】片上放不下 128 KiB CHR ROM，这是算术结论不是偏好**：128 KiB = 131,072 byte，按 1,024 byte/M9K 需 **128 块**，超过器件全部 46 块。**因此 CHR 必须落在片外存储**（`CHR_ADDR_BITS = 17` 这条外部接口义务由此获得算术上的必要性），落到哪块片外器件是未决事项。与 `docs/hardware/01-ep4ce10-board.md` 第 3.4 / 3.5 节已记录的板级资源对照：TF 卡是 4 线 SPI（`sd_clk` J2 / `sd_cs` C2 / `sd_mosi` D1 / `sd_miso` K1），SDRAM 是 16 bit 双向数据总线加 13 位地址、2 位 Bank、2 位 DQM；`01-ep4ce10-board.md:140` 另把板上的一路 flash 记为 "EPCS"——**该文件没有记录任何 flash 型号或容量**，因此"板上这颗 flash 能不能当 CHR ROM 用"在仓库里**没有答案**，本条不猜。
- 功能后果（与容量无关，独立成立）：片上 PRG + 8 KiB CHR RAM 等价于 NROM + CHR-RAM 且无 bank 切换，因此只能运行这一类游戏；任何需要 PRG banking 或 CHR ROM 的 mapper 都被容量挡在外面。把 `PRG_SIZE_BYTES` 调小只会进一步收窄 ROM 容量，不会缓解结构性冲突。
- 640×480 RGB565 整帧缓存（614,400 byte）无论如何进不了片上 BRAM；即使只做行缓存，也必须在上面剩余的 M9K 之上再挤出一份。
- 与 R-03 耦合：若多端口需求迫使复制数组，M9K 计数会进一步上升。

**证据**

- 【事实】`rtl/nes_core/system/nes_system_v0.v:3-4`：模块参数 `PRG_SIZE_BYTES`，当前默认 `16384`；`:20` `PRG_INDEX_BITS = $clog2(PRG_SIZE_BYTES)`；`:39` `prg_rom [0:PRG_SIZE_BYTES-1]`；`:53-54`、`:60-61` 用 `cpu_addr[14:0]` 加位掩码形成镜像窗口。
- 【事实】`rtl/nes_core/system/nes_system_v0.v:38`：`cpu_ram[0:2047]`。
- 【事实】`rtl/nes_core/ppu/nes_ppu2c02.v:416-419`：`nametable_ram[0:2047]`、`chr_ram[0:8191]`、`oam_ram[0:255]`、`palette_ram[0:31]`。
- 【事实】`docs/hardware/01-ep4ce10-board.md` 记录厂商例程 Fitter 报告：10,320 LE、423,936 memory bits、2 PLL、46 个 9-bit 乘法器；同文件第 11 行说明“约 52 KiB”只是数量级，不表示所有存储模式都能得到同样有效容量。
- 【事实】`docs/hardware/04-memory-and-fifo.md` 第 1.1 节记录 423,936 bit ≈ 52,992 byte ≈ 51.75 KiB、`8_ip_ram` 是单端口 32×8 的 `altsyncram`，以及 SDRAM 例程的两个 FIFO 为 16 bit × 1024。
- 【事实】`docs/hardware/05-vga-lcd.md` 第 85 行记录 640×480×2 byte = 614,400 byte/帧、约 36.6 MB/s，以及 NES 读与 VGA 读会竞争资源。
- 【事实】`docs/00-overview/architecture.md` 第 9 节已把 PRG/CHR 规划到 SDRAM 层，并写明帧缓存不能默认放片上。
- 【审查】`docs/00-overview/decision-log.md`“未决事项”已列出“EP4CE10 上 PRG/CHR、帧缓存、音频 FIFO 的实际存储分配”尚未决定。
- 【审查】`tb/system/README.md` 描述的仍是“固定 32 KiB PRG + 8 KiB CHR RAM”。在 `PRG_SIZE_BYTES` 参数化之后，该描述已与 RTL 现状不一致，必须随参数决定一并更新，不能让两处说法并存。
- 【推断】上表 M9K 数量是按 8 位宽模式（1,024 byte/M9K）向上取整的**算术估算**，**仍未经 Fitter 验证**。实际值取决于综合器推断结果、是否使用 IP，以及位宽/深度组织。**PPU 自身那一份现在有实测了**（第 10 节：外部 CHR 0/46、内部 CHR 0/46），但上表把 CPU 侧的 `prg_rom` / `cpu_ram` 也算进来了，那部分**没有任何综合证据**。
- 【事实】第 10 节的 `final_ext.fit.rpt` 把"46"这一项报为 `Embedded Multiplier 9-bit elements ; 0 / 46 ( 0 % )`，与 `Total memory bits ; 0 / 423,936 ( 0 % )` 并列；因此**"46 个 M9K"在 Quartus 报告里就是 46**，46 × 9,216 = 423,936 与 `01-ep4ce10-board.md:10` 的两个数字自洽。

**缓解路线**

1. 执行已决定的分层：工作 RAM、nametable、OAM、palette 留在片上；PRG 与 CHR 通过 R-01 的存储层放 SDRAM。
2. 输出一份版本化的存储预算表，每行至少包含：逻辑深度、数据位宽、端口模式、估计与实测 M9K、旁路/输出寄存器、复位策略、所属层次、访问者与仲裁规则。
3. 预算表必须把 VGA 行缓存、音频 FIFO、2 个 SDRAM FIFO 和任何 CDC 缓冲作为**已预留行**写进去，而不是最后再补。
4. ROM 容量与 mapper 范围随分层结果确定，并写进 `project-charter.md` 的 v1 范围。`PRG_SIZE_BYTES` 的取值必须由该结论反推，而不是先定参数再找容量依据。
5. 若选择 PRG 留在片上，必须先证明剩余 M9K 足以容纳所有已预留行，并接受由此产生的 ROM 容量上限。
6. 参数化之后，`tb/system/README.md` 与 `project-charter.md` 中关于 PRG 容量的描述、`decision-log.md` 的未决事项、以及 mapper 范围必须一次性对齐，不能让两处说法并存。

**进入下一阶段前的门槛**

- 存在一份 NES-only 的 Quartus 布局布线报告，含 M9K/BRAM、LE、寄存器、PLL、IO 的实测数字。**门槛核对：PPU-only 那一半已满足**（第 10 节，`final_ext.fit.rpt` 给出 63,127 LE / 19,260 寄存器 / 0-46 M9K / 0-2 PLL / 159-180 引脚），**NES-only 整机那一半未满足**——`nes_ep4ce10_top` 仍然没有被综合过，VGA / 音频 / SDRAM FIFO 三行预留至今没有任何实测数字。
- 存在缓解路线第 2 条要求的预算表，所有已预留行均已计入，且“实测”列不得留空或用估算冒充。
- `PRG_SIZE_BYTES` 的取值已由预算表结论反推确定，并在 `project-charter.md` 的 v1 范围中写成具体容量，而不是留作可调参数。
- 预算表结论与 `architecture.md` 第 9 节的层次规划一致，或已通过 `decision-log.md` 正式修订该规划。
- `tb/system/README.md` 中关于 PRG 容量的描述与最终取值一致。
- 在此之前，任何“可以跑某类游戏”的表述都不得进入对外说明。

## 4. S1 风险

### R-05 当前无 Quartus / ModelSim / 上板证据

**等级/状态：** S1 / 未开始

**触发条件**

- 需要回答“能不能上板”“综合能不能过”“时序够不够”这类问题。
- 需要第二个独立工具做交叉验证（当前只有 Icarus）。

**影响**

- 现在唯一可重复的**行为**证据是 Icarus Verilog 下的 **35 个**自包含 testbench（`tools/sim_all.ps1` 的 `$allTargets` 实际求值实测 51 个目标 = 16 个 compile-only + 35 个仿真，最近一次 `-Mode all` 实测 `Result: PASS (51 of 51)`、0 FAIL、墙钟 1402 s）。**（2026-09-30 登记）本机现已安装 Quartus Prime Lite 23.1，第 10 节有一份 PPU-only 的 map + fit 报告；但仍然没有任何时序分析、板级电气或上板行为证据，`nes_ep4ce10_top` 也从未被综合过。** 本条**不因此关闭**：第 4 节门槛要求的是"属于本项目的报告 + TimeQuest slack + 一次板级 bring-up"，三样都还没有。
- 因此以下判断目前**全部无证据**：fmax 够不够、SDC 是否完整、引脚与 IO standard 是否正确、复位与 PLL 是否稳定、画面与声音是否正确。**"资源够不够"与"BRAM 能否推断"现在有了一半答案**——见第 10 节：PPU 单独占 63,127 / 10,320 LE（装不下），但占 0 / 46 M9K（四个数组全部没有推断成 BRAM）。这只回答了 PPU，回答不了整机。
- **仿真门禁有一个已确认的盲区**（2026-09-30 登记）：`575e191` 之前 PPU 里有两组网（`read_buffer_reg[7:0]` 与 `v_addr[14:0]`）各有两个 `always` 块驱动，Quartus 报 `Error (10028)`，而 **Icarus 按 last-write-wins 容忍了它**，因此 51 个目标的 `sim_all.ps1` 门禁当时仍然全绿。**多驱动网是仿真抓不到、综合一抓就抓得到的一类缺陷**；引用 `PASS (51 of 51)` 时必须带上这个限定词。
- 这直接限制 R-01/R-03/R-04 的关闭方式：它们无法靠仿真关闭。
- 证据工具本身还有一个缺口：只有 Icarus 一个行为仿真器，`run_*.do` 只覆盖 `tb/cpu/`、`tb/ppu/`、`tb/system/`、`tb/apu/`，其余目录没有 ModelSim 入口脚本；`tools/sim_cpu.ps1` 的 `rtl` 与 `pure` 两个模式实际执行同一条命令。
- `docs/hardware/` 中出现的 BRAM、PLL、乘法器数字来自**厂商例程**的 Fitter 报告，不能当作本项目工程的资源结论。第 10 节的数字**是**本项目的报告，但范围只到 PPU。

**证据**

- 【事实】`rtl/` 下已有 `nes_core/{cpu,ppu,system,video,bus,apu,mapper,controller,cart,peripheral}` 与 `platform/ep4ce10/`（3 个 `.v`），平台顶层 `nes_ep4ce10_top` 存在。
- 【事实】仓库内已有 `quartus/op_fpga_emu.{qpf,qsf,sdc}` 工程骨架：`.qsf` 声明 `DEVICE EP4CE10F17C8` 与 `TOP_LEVEL_ENTITY nes_ep4ce10_top`，`.sdc` 含 3 条 `create_clock`（50 MHz `sys_clk`、21.477272 MHz `clk_ntsc`、25 MHz `clk_vga`）与 2 条 `set_false_path`。但 `set_location_assignment` 0 条、`create_generated_clock` 0 条（altpll 未生成）、`set_input_delay`/`set_output_delay` 各 0 条，且三个文件**从未在 Quartus 中打开或编译**；仓库内仍无 `.qip`、`.sdf`、`.stp`、`.srf`。实测数字见 `quartus/README.md` 第 0.1 节。
- 【审查】`tb/ppu/README.md` 与 `tb/system/README.md` 均写明“当前仓库没有 ModelSim、Quartus 或 EP4CE10 上板证据；该脚本未被本版本验证”。
- 【审查】`docs/00-overview/verification-plan.md` 第 4 节 L5 的结论是"此层状态是未开始，而不是失败或通过"，并已明确记录"**骨架不是结果**"：`quartus/` 下三个文件存在、平台顶层 `nes_ep4ce10_top.v` 存在但**未综合**、`.qpf`/`.qsf`/`.sdc` **从未在 Quartus 中打开或编译过**；同文档第 3.3 节说明 ModelSim 通过也只增加独立工具证据，不代表 EP4CE10 适配完成。
- 【事实】`tools/sim_cpu.ps1:3` 的 `ValidateSet` 为 `rtl|pure|integration|bus|all`，其中 `rtl` 与 `pure` 都调用 `-Top nes_cpu6502` 加同一份源文件；`:14-15` 把工具路径硬编码为 `C:\iverilog\bin`。
- 【实测】Quartus Prime **Lite Edition 23.1std.0 Build 991 11/28/2023 SC Lite Edition** 已安装，可执行文件在 `D:\intelfpga_lite\23.1std\quartus\bin64\`；`quartus` 13.1 另在 `D:\altera\13.1\quartus\bin64\`。工具链细节（不需要 license、Lite 只支持 Cyclone IV E、`quartus_sh --flow syn` 失败、报告文件是 cp1252）见第 10.6 节。
- 【实测】仓库的 `quartus/op_fpga_emu.{qpf,qsf,sdc}` **仍然没有被编译过**：第 10 节所有报告的顶层是 `ppu_synth_ext_top` / `ppu_synth_int_top` / `ppu_fold_top` / `cfu_stim` / `cfu_fold`，**没有一个是 `nes_ep4ce10_top`**，而这些激励包装与源文件副本都放在 `D:\quartusProject\` 下、不在仓库内。
- 【事实】`tb/ppu/README.md` 与 `tb/system/README.md` 的期望运行时间分别约为几十秒和约 9 秒，说明仿真规模已经不小，进一步的证据补齐需要规划时间预算。

**缓解路线**

1. 先补齐证据工具的可重复性：给 PPU 与系统 testbench 增加脚本入口（或新增统一脚本），并把三个 TB 的工具版本、完整命令行和期望输出固定下来。
2. 选一个不涉及外部存储的最小工程（CPU 顶层或 PPU 顶层）先跑通 Quartus 分析与布局布线，拿到第一份属于本项目的 Fitter/TimeQuest 报告。该步骤同时为 R-01、R-03 提供输入。
3. 为 NES core 写第一版 SDC（时钟、复位、generated clock，以及 false path / 多周期路径的显式理由），并把每次报告的资源与 slack 数字追加到 `docs/00-overview/`。
4. 板级 bring-up 从最小可观测序列开始：例如把 `cpu_cycle` / `frame_done` 计数，或一个已知 PRG 字节、固定 palette 值映射到 GPIO/LED，而不是直接接 VGA + 音频 + TF。
5. ModelSim/Questa 作为第二工具逐步接入（先 CPU，再 PPU，再系统），每次记录版本与差异。

**进入下一阶段前的门槛**

- 存在至少一份属于本项目的 Quartus 编译与布局布线报告，含器件、封装、速度等级、资源与 TimeQuest slack。**门槛核对：资源那部分已有（PPU-only，第 10 节）；"属于本项目"的上位定义（`nes_ep4ce10_top`）、TimeQuest slack 这两项未满足**——第 10 节那次跑没有 SDC，因此没有任何 slack。
- 存在一次可复现的板级 bring-up 观测，哪怕只是把一个固定常量或计数器输出到引脚。**未满足**。
- 在此之前，任何文档、README 或状态报告都不得出现“已综合”“已布局布线”“时序通过”“已上板”“画面正常”等表述；`verification-plan.md` 的 L5 保持“未开始”。

### R-06 当前 NMI 端到端覆盖缺口

**等级/状态：** S1 / 未解决

**触发条件**

- 需要声称“NMI 路径可用”或“v1 核心可运行 NROM 程序”。
- 任何依赖 NMI 驱动刷新的程序：几乎所有真实游戏都用 NMI 更新滚动与 OAM。

**影响**

- 现有覆盖是三段割裂的，没有一段覆盖完整链路：
  - PPU 层只验证 `nmi_o` 的置位、清除与自动撤销，不涉及 CPU。
  - CPU 层的 NMI 与 hijack 覆盖较完整，但 `nmi_i` 由 testbench 自行驱动，不是 PPU 产生的。
  - 系统层把 `PPUCTRL[7]` 全程保持为 0，`$FFFA`/`$FFFB` 向量从未被取，NMI 服务例程从未执行。
- 因此**从未被验证**的环节包括：vblank 产生的 NMI 是否真被 CPU 锁存、每帧是否恰好服务一次、handler 的写入是否落地、handler 内读 `$2002` 的抑制效果、`nmi_o` 自动撤销是否会造成第二次进入，以及 CPU 正忙时 NMI 被推迟到下一个取指边界的行为。
- 当前 `nmi_o` 是与 `vblank` 同窗口的电平（`(241,1)` 到 `(261,1)`，共 6820 dot），CPU 用上升沿检测。在单时钟域下这不是 CDC 缺陷；但 PPU 事件与 CPU 事务落在同一拍（R-02）意味着边沿位置与 CPU 取指边沿的相对关系从未被测量。
- “vblank 中途把 `PPUCTRL[7]` 写成 1 立即产生 NMI”这类真实场景在 v0 里不会产生 NMI，因为只在 `(241,0)` 单点采样。这是未实现项（见 L-08），不是已支持行为。
- 系统层 `irq_i` 恒接 0，因此 APU IRQ 与 mapper IRQ 路径完全没有覆盖，会与 v1 的 APU 工作绑定在一起。

**证据**

- 【事实】`rtl/nes_core/system/nes_system_v0.v:87-88`：`.nmi_i(ppu_nmi)`、`.irq_i(1'b0)`。
- 【事实】`rtl/nes_core/ppu/nes_ppu2c02.v:989-993`：`nmi_o` 只在 `scanline==241 && dot==0` 这一个判定点采样 `control_reg[7]`；`:995-998` 在 `(261,0)` 自动清零。
- 【事实】`rtl/nes_core/cpu/nes_cpu6502.v:216`：`nmi_rise = nmi_i && !nmi_sync_reg`（上升沿识别）；`:788-790` 锁存到 `nmi_pending_reg`；`:820-827` 在取指边界服务。
- 【审查】`tb/system/README.md`“明确未实现”写明：`irq_i` 恒为 0、测试程序全程 `PPUCTRL[7]=0`，因此 NMI 服务例程和 `$FFFA` 向量没有被覆盖；同文件的“NMI 关闭”断言正依赖这一点。
- 【审查】`tb/cpu/README.md` 记录 NMI、BRK hijack、IRQ hijack 场景与单点 hijack 采样点近似，但 `nmi_i` 在 `tb/cpu/tb_nes_cpu6502.v` 与 `tb/cpu/tb_nes_cpu6502_bus.v` 中由 testbench 自行产生（`nmi_armed` / `nmi_addr_t` 机制）。
- 【审查】`tb/ppu/README.md` 断言 8–10 覆盖 vblank/NMI 使能、事件、`$2002` 清除与自动撤销，范围止于 PPU 端口。
- 【事实】`docs/00-overview/cpu-contract.md` 第 6 节已把 hijack 窗口的单点采样登记为已知微周期差异。

**缓解路线**

1. 在系统级新增 NMI testbench：一个 PRG 程序置 `PPUCTRL[7]=1`，`$FFFA` 指向的 handler 往工作 RAM 写计数 marker 并写一个 PPU 寄存器。
2. 断言至少覆盖：每帧服务次数、进入时压入的 PC 与 P、`$FFFA`/`$FFFB` 取指地址、handler 写入确实落到 RAM、handler 内 `$2002` 读对 `vblank`/`nmi_o`/`w` 的抑制、`(261,1)` 自动撤销不引发第二次进入、CPU 正忙时 NMI 被推迟到下一个取指边界。
3. 决定 NMI 的最终形式：保持“电平 + 上升沿检测”还是改为脉冲，并在 `cpu-contract.md` 与 `tb/cpu/README.md` 中同步。`nmi_o` 是否需要在 `(261,1)` 自动撤销应作为显式决策记录，而不是隐含在 PPU 实现里。
4. 决定 vblank 中途置 `PPUCTRL[7]=1` 是否需要立即产生 NMI；若不做，登记为已知限制并给出影响范围。
5. 把 APU/mapper IRQ 与 NMI 一起规划 `irq_i` 的多来源合成与清除规则，而不是等 APU 开工再补。

**进入下一阶段前的门槛**

- 上述系统级 NMI testbench 存在、可复现通过，并输出固定的每帧服务次数与关键地址。
- NMI 的形式（电平或脉冲、自动撤销、hijack 采样点）在 `cpu-contract.md` 中有明确合同，`tb/cpu/README.md` 与之一致。
- `irq_i` 的多来源合成与清除规则在 `decision-log.md` 未决事项中被处理（决定或明确推迟并写明理由）。
- 未满足之前，v1 不得被描述为“可运行 NROM 核心”，NMI 不得被描述为“已验证”。

## 5. S2：已登记的限制与近似

以下条目**不是未关闭的风险**，而是已命名、范围受限、当前阶段接受的近似或未实现项。登记在这里是为了防止它们在转述时丢失限定词。共同规则：任何对外表述都必须带上“范围 + 限定词”，不得简写成“已支持”。

| ID | 条目 | 范围 | 记录位置 | 重新评估时机 |
|---|---|---|---|---|
| L-01 | NMI/IRQ hijack 只在压入 PC 低字节完成时单点采样 | 全部 IRQ/BRK/NMI 序列 | `cpu-contract.md` §6、`tb/cpu/README.md` | R-06 关闭时 |
| L-02 | 外部中断序列 dummy 读当前 PC，`BRK` padding 读 PC+1 | 全部中断与 `BRK` | `cpu-contract.md` §6、`tb/cpu/README.md` | 引入 2A03 微周期等价位时 |
| L-03 | `PLA`/`PLP` 第 4 周期用 `$0100+SP` dummy read，`JSR` 第 3 周期读 `$0100+SP` | 对应指令 | `cpu-contract.md` §6 | 同上 |
| L-04 | RMW 为连续写旧值加新值，未建模 RDY 条件下的额外 write cycle | 全部 RMW | `cpu-contract.md` §6 | 引入 DMA 抢占时 |
| L-05 | 非法 opcode 进入 `ST_TRAP` 并置 `dbg_illegal` | 非官方 opcode | `cpu-contract.md` §6、`decision-log.md` D009 | 决定支持 unofficial opcode 时 |
| L-06 | 奇数帧跳 dot 未实现 | 全部帧时序 | `tb/ppu/README.md` | 引入 PAL 或追求逐帧精确时 |
| L-07 | 读 `$2002` 只在时钟沿清标志，不实现读取抑制窗口 | PPUSTATUS | `tb/ppu/README.md` | 引入真实取数流水线时 |
| L-08 | vblank 中途把 `PPUCTRL[7]` 写 1 不产生 NMI | PPUCTRL[7] | `tb/ppu/README.md` | R-06 关闭时 |
| L-09 | `nmi_o` 在 `(261,1)` 自动撤销，不读 `$2002` 也会释放 | NMI 电平 | `tb/ppu/README.md` | R-06 决策时 |
| L-10 | 背景为功能级逐像素取数，不是逐 dot 预取流水线 | 全部背景渲染 | `tb/ppu/README.md`、`tb/system/README.md` | R-03 关闭时 |
| L-11 | **精灵 8×16 高度、每行 8 个 sprite 上限、优先级、水平/垂直/双翻转与 sprite 0 hit / overflow 标志位在外部 CHR 模式下已由 9 个精灵场景逐项 A/B 证明**（`ppu-ext-chr-tb`，每组有自己的非空洞 `$fatal`）。仍未实现的是：**精确的 sprite evaluation 与次 OAM 时序**（评估窗口、次 OAM 装载、`m`/`n`/`o`/`p` 影子寄存器、溢出 glitch）、外部 CHR 模式下 §8.2 那个 overflow"用下一行 OAM 计数"的**行为**差异（标志位一致本身已证）、hit/overflow 标志不每帧自动清零且置位点早于真实硬件 dot 64..256 窗口、scanline 240..255 的精灵被 `frame_active` 屏蔽 | 全部精灵 | `tb/ppu/README.md`、`tb/system/README.md`、[`docs/modules/ppu-external-chr.md`](../modules/ppu-external-chr.md) §11.3.1 | v1 范围决策时 |
| L-12 | APU、`$4000-$5FFF` 恒返回 0、OAM DMA、DMC DMA、mapper IRQ 均不存在 | 音频与 DMA | `tb/system/README.md` | v1 范围决策时 |
| L-13 | testbench 用层次引用访问内部数组与 `dbg_*`，不是可移植验证接口 | 全部三个 TB | `tb/system/README.md` | TB 重构或 RTL 重命名时 |
| L-14 | 系统 TB 锁死 12 拍使能分配（帧长 357368 clk、CPU/PPU 同相、每访问浪费一个 dot） | 系统 TB 断言 | `tb/system/README.md` | R-02 关闭时 |
| L-15 | 系统 TB 中工作 RAM 写通路与 `$0000-$1FFF` 译码为空覆盖 | 系统 TB 覆盖 | `tb/system/README.md` | R-01 存储层就位后 |
| L-16 | **`CHR_ADDR_BITS = 17` 截断 MMC3 的 CHR bank bit 7**：MMC3 的 1 KiB CHR 窗口选择寄存器是 8 bit，bit 7 落在 17 bit 地址之外，因此 bank `0x80`-`0xFF` **别名**到 `0x00`-`0x7F` | MMC3 的 CHR banking（`nes_system_v6`，`CHR_ADDR_BITS` 是 elaboration 期参数） | [`docs/modules/system-v6.md`](../modules/system-v6.md) §3.4、§6 | 外部 CHR 存储方案确定时（地址宽度必须与它一致） |
| L-18 | **`mapper_ppu_a12` 在 RTL 里仍硬绑 0**（`nes_system_v5.v:215`、`nes_system_v6.v:302`——读臂那一轮之前是 `:259`），所以 MMC3 的扫描线 IRQ 计数器在系统级**仍然无法自时钟**。**根因不是"忘了接线"**：本 PPU **没有 VRAM 地址总线**，`bg_pattern_addr` 只有 13 bit、bit 12 是 `PPUCTRL[4]`，地址进位到不了 bit 12——所以根本不存在一个可以接出来的真实 A12 | MMC3 扫描 IRQ 的**自时钟**（生产 RTL 未改；状态机已在 `system-v6` 的 P1-11 里于**建模刺激**下被真实 RTL 激励过，但那是 TB 侧的模型，不是硬件预测） | [`docs/modules/system-v6.md`](../modules/system-v6.md) §5.3、§6；`tb/system/README.md` 的"### P1-11" | 给 `nes_ppu2c02` 引入真实 VRAM 地址总线时；或接入真实卡带时 |
| L-19 | **建模的 MMC3 A12 刺激不覆盖依赖精灵的 A12 变化**：真实硬件上 A12 的出现次数依赖精灵 pattern 地址，**每条扫描线可达 4 次**；P1-11 的模型只实现 NESdev 的标准情形（每个渲染扫描线、PPU dot 260 处一个上升沿）。**这不是一个可以被补上的缺口**——精灵 pattern 地址是 OAM 相关的，在**没有**真实 VRAM 地址总线的前提下无法建模 | `system-v6` 的 P1-11 结论范围 | `tb/system/README.md` 的"### P1-11"；[`docs/modules/system-v6.md`](../modules/system-v6.md) §5.4 | 与 L-18 同步（真实 VRAM 地址总线 / 真实卡带） |
| **L-20** | **`$2007` 外部 CHR 的读臂会占掉 CHR 总线上的一个取数拍**：`chr_rd_win` 现在直接喂 `chr_req` / `chr_addr`（`nes_ppu2c02.v:807`、`:808-809`），与 L-17 的写臂是**同一条隐患的第二个实例**。把地址放上总线要花掉一个 `ce` 的地址时间（外部 CHR 在**每个** `ce_ppu` 沿寄存 `chr_rdata`、CPU 在 `div_phase == 0` 锁存 `bus_din`，所以必须提前一个 `ce`，**提前量零余量**），并**可能顶掉一个**在飞的取数字节——一个背景 tile（8 像素、1 个 pattern 字节）或一个精灵 slot 平面（某一行上的 8 像素），**范围限定在被读的那条扫描线**。**实测 396 个读臂里 107 个真的撞上**（背景 71 / 精灵 36）。**渲染开着时帧中 `$2007` CHR 读不宣称安全**；扫描线 240–260 或关渲染时可证像素不可见，**扫描线 261 明确不安全** | `nes_system_v6` 的 `$2007` CHR 读通路（`EXTERNAL_CHR = 1`）；`g_chr_internal` 一行未改 | [`docs/ppu_chr_external_write.md`](../ppu_chr_external_write.md) §8.1；[`docs/modules/ppu-external-chr.md`](../modules/ppu-external-chr.md) 11.3.9；[`docs/modules/system-v6.md`](../modules/system-v6.md) §5.1.3、§6 | 与 L-17 同步——三条候选修法（压制 `chr_req` / 加握手背压 / 限制访问窗口）一条都还没做 |
| **L-20b** | **读臂带来的两条新义务，都是"合同变宽"而不是"缺陷"**：(a) **地址建立时间**——多出来的仲裁级落在 **`chr_addr`** 上，而 `chr_addr` 是通往 CHR 地址的**唯一**通路，所以 `v_addr → chr_addr → mapper → chr_final_addr → chr_rdata` 的建立时间必须按真实存储器（BRAM / SDRAM）的 `tACC` 预算**重新核对**；(b) **同址同拍的读写竞争第一次对程序可见**——TB 把它建模成 **read-first**，这个**建模选择**现在对"写完一个 CHR 字节立刻读回来"的程序是可观测的，必须由真实存储器回答 | 外部 CHR 存储器的实现方案（今天还没有，只在 testbench 里） | 同上；R-01、R-03 | 外部 CHR 存储方案落地时 |

**关于 L-16**：17 bit **正好覆盖 MMC1**（其 CHR 窗口最大 32 KiB），所以这个宽度不是随手取的。但**加宽它今天没有意义**——`nes_system_v6` 的 `chr_final_addr` 是纯 RTL 输出端口，片上没有 CHR 存储，外部方案（SDRAM）还不存在；加宽只会多产生一批没人读的常量位。**别名是已知的、可预测的、被接受的限制，不是缺陷**；真要修它，正确顺序是"先定外部存储地址宽度，再让 `CHR_ADDR_BITS` 跟着走"，而不是反过来。

**关于 L-18**：这条登记于 P1-11 那一轮。**两件事必须一起说，缺一件就会说错**：

- **生产状态一点没变**：`mapper_ppu_a12` 在 `nes_system_v5.v:215` 与 `nes_system_v6.v:302`（读臂那一轮之前是 `:259`）里**仍然硬绑 0**，MMC3 的扫描线 IRQ 计数器在系统级**仍然无法自时钟**。P1-11 **没有改动任何 RTL**。
- **但状态机不再是无证据的**：`system-v6` 的 `check_p1_11` 把一条**建模的** PPU dot A12 流 force 到那根生产网上，并断言它到达 RTL 采样的端口；**`irq_pending_r` 从头到尾没有被 force**，它必须由 `nes_mapper_mmc3.v:193-194` 的 `irq_counter_next == 0` 产生。实测见 [`docs/modules/system-v6.md`](../modules/system-v6.md) §5.3。

**根因（P1-11 之后才写清楚的）**：绑 0 **不是漏接**，而是**本 PPU 没有 VRAM 地址总线**。`bg_pattern_addr` 只有 13 bit，bit 12 是 `PPUCTRL[4]`，任何地址进位都到不了 bit 12；`bg_fetch_*` 那些网只存在于 `g_chr_external` 分支里。所以在这个 RTL 上**没有**一个"正确的"真实 A12 可以接出来——任何由 dot 推导出来的 A12 都是**硬件形状的虚构**：`chr_mmc3` 跑 `PPUCTRL = $00`，**真实硬件每帧把计数器时钟 0 次**（那个众所周知的 MMC3 陷阱，也是商业游戏必须用 `$2006` 手动打计数器来数扫描线的原因），而一个 dot 推导的 A12 会报 241——**绿灯会去认证一个错的答案**。

**"每帧 241"是引用的文献值，不是实测**：它来自 NESdev 的 MMC3 页，对应背景 `$0000` / 精灵 `$1000` 的标准情形。**没有任何东西验证它**，而一般情形（见 L-19）永远无法在这里被验证。

**因此 P1-11 的结论类型必须原样转述**：MMC3 计数器 / reload / pending 状态机与 `mapper_irq → irq_line → CPU` 入口链在**被喂进一条形状标准的 A12 流**时内部一致，且 pending 由真实 RTL 产生——**内部一致性与已发表时序吻合**，不是硬件行为。`force` 是刺激手段上的 hack，只因为被限制在**一个** testbench 里、且生产绑 0 在 force 窗口**两侧**都被断言过才诚实。**没有任何 MMC3 卡带被跑过**，`nes-test-roms/mmc3_irq_tests` 的**任何**二进制都没有被跑过，harness 还没有真实 ROM 装载。

**关掉 L-18 的正确路径**：若将来某次改动给 `nes_ppu2c02` 加上**真实的 VRAM 地址总线**，TB 里那个 A12 模型就成为它**逐拍 A/B 的参照对象**——模型对不对就从假设变成可测量的量。**那**才是"真实 A12"这个说法开始站得住的时刻。在那之前，它是虚构。

**关于 L-19**：L-18 的诚实版本。它的关键点是"**不能**建模"而不是"忘了建模"：真实硬件上 A12 的出现次数依赖精灵 pattern 地址，而精灵 pattern 地址是 OAM 相关的；在没有真实 VRAM 地址总线的条件下，这个依赖在 RTL 里**不存在可表示的形式**。因此"每条扫描线一次上升沿"是**一种**合法形状，不是**唯一**正确的形状。L-19 与 L-18 同步重估。

**关于 L-17**（登记于 `$2007` 对外部 CHR 的写通路落地那一轮，`5cc36e7` / `576cc74`）：`chr_we` 与 `chr_req` 是同一个 CHR 地址总线上的两个独立驱动源。`nes_system_v6` 给了**写优先**（`mapper_ppu_addr = ppu_chr_we ? ppu_chr_waddr : ppu_chr_addr`），但**写不压制 `chr_req`**——`chr_req` 由两个自由运行的取数单元经组合 mux 产生（`nes_ppu2c02.v:709`；读臂那一轮之后同一个 mux 变成"取数单元 + 读臂"三项、位置 `:807`，而这一行是**读臂落地之前**的位置），`bg_fetch_due`（`:604`，读臂那一轮之后是 `:698`）也没有扫描线或 mask 门控。`system-v6` 把这件事**测量**出来而不是假定：96 个 `$2007` 写拍里 **22** 拍与在飞的背景取数相撞；那一拍 `chr_final_addr` 上是写地址（因此改用**写模型**核对），代价是取数单元锁到了一个错字节。**本轮那 22 次碰撞 0 次落在 `bg_pa_enable` 为高或精灵打开的 scanline 上**（上传程序跑在 `PPUMASK = $00` 下），所以渲染结果未受影响——**但这不等于已修复**：一个在渲染中期写 CHR 的程序会有**一个 tile 拍**显示错 pattern。

**为什么它是硬件形状而不是接线错误**：2C02 只有一根 CHR 地址总线，写优先是它的固有行为。真正要选的是**仲裁策略**，三条各有代价：压制 `chr_req` 会破坏背景取数流水节拍（请求被吞 = tile 窗口错位）；给总线加握手/背压要改 `nes_chr_fetch_unit` / `nes_sprite_chr_fetch` 两个单元的接口（它们现在是"无条件请求、无背压"）；把上传窗口限制在关渲染时则要求软件配合（vblank / `$2001 = 0`），无法在 RTL 内部保证。**本轮一条都没做。** 详见 [`docs/ppu_chr_external_write.md`](../ppu_chr_external_write.md) §4 与 §8.2。

**关于 L-20**（登记于 `$2007` 对外部 CHR 的**读**通路落地那一轮，与 L-17 同批发现、**并列而不是替代**）：读臂把同一个问题搬到了读侧。`chr_rd_win` 现在**直接**喂 `chr_req` 与 `chr_addr`（`nes_ppu2c02.v:807`、`:808-809`），所以 **`P0-8` 那条"`chr_req` 从不在连续两个 `ce` 上为高"按构造就会被违反**——那一轮把 `P0-8` **重新界定**（不是削弱）：每组连续对按**第二拍是哪个 master 赢**归属，并断言**两拍都没有读臂**的连续对为 **0**（那正是旧不变式覆盖的取数对取数性质）。实测 `ab_v6` 上有 **171** 组连续对：89 组第二拍由读臂赢（80 背景 / 9 精灵）、82 组由取数赢（82 背景 / 0 精灵）、**0** 组两拍都没有读臂；`chr_mmc3` 的程序不发 `$2007` 读，所以那里 `m_req_consec == 0` **逐字保留**。

**撞车是真的，不是一句"未修"的定性话**：396 个读臂里 **107** 个与在飞的取数请求撞在同一个 `ce` 上。**它也是硬件形状**——2C02 只有一根内部 CHR 地址总线，真实硬件上 `$2007` 读的 CHR 访问同样要占地址时间，所以"把地址放上总线要花掉一个 `ce`"是**忠实**而不是走捷径；被顶掉的取数字节是本仓库这条流水线的**代价**。三条候选修法与 L-17 完全相同、同样**一条都没做**。**代价的边界必须一起说**：一个背景 tile（8 像素里 1 个 pattern 字节）或一个精灵 slot 平面（某一行上的 8 像素），**范围限定在被读的那条扫描线**；在扫描线 240–260 或关渲染时可以证明**像素不可见**（W3-10 逐臂核对、396 个臂违例 **0**、任何违例当场 `$fatal`），**扫描线 261 明确不安全**（它的 dot 340 背景取数与 dot 259–290 的精灵预取喂的是第 0 行）。落点分布：378 个臂在 vblank 扫描线 240–260、18 个在外部（`PPUMASK=$00`），跨扫描线 93..255。

**L-20 与 L-17 的差别必须说清**：L-17 的碰撞由 **PPU 侧**的 `mapper_ppu_addr` 写优先仲裁解决，代价是取数单元锁到写地址的字节；L-20 的碰撞由 **PPU 内部** `chr_req` / `chr_addr` 的组合 mux 解决，代价是取数单元锁到读地址的字节。**修 L-17 不会修 L-20，反之亦然**——所以它们必须一起重估。

**关于 L-20b**：这一条不是缺陷而是**合同变宽**，登记它是为了别在接真实存储器时忘掉。**地址建立时间**：`chr_addr` 是通往 CHR 地址的**唯一**通路，而读臂的提前量**恰好零余量**（外部 CHR 在每个 `ce_ppu` 沿寄存 `chr_rdata`、CPU 在 `div_phase == 0` 锁存 `bus_din`），所以链上任何一处插寄存器都会打断它；`tACC` 预算必须按真实 BRAM / SDRAM **重新核对**。**读写竞争**：读臂让同址同拍的写/读冲突**第一次对程序可见**，TB 建模成 read-first——**那是一个建模选择，不是被证明的硬件行为**，必须由真实存储器回答。

## 6. 已知耦合关系

处理任一条风险时，必须同时检查其耦合项，避免用一个条目的修复掩盖另一个条目的未关闭状态。

| 关系 | 说明 |
|---|---|
| R-01 → R-04 | 存储层没有延迟合同，就无法判断哪些数组应留在片上，容量估算因此不成立 |
| R-03 → R-04 | 多端口需求可能迫使复制数组，直接抬高 M9K 计数 |
| R-02 → R-06 | 滚动更新被删除会改变 NMI handler 写 `$2005`/`$2006` 的效果，因此 R-06 的系统级 TB 必须在 R-02 关闭后才可能给出稳定参考 trace |
| R-05 → R-01 / R-03 / R-04 | 这三条只能靠综合报告关闭，仿真无法替代；R-05 不关闭，三条的门槛都无法验证 |
| R-05 → R-07 | PLL 参数、VCO 范围、派生时钟与 slack 只能由 TimeQuest 关闭；R-05 不关闭，R-07 的门槛无法验证 |
| R-07 → R-03 | 时钟方案直接决定关键路径的周期预算（20 ns 与 46.55 ns 相差 2.33 倍），因此 PPU 的 fmax 结论不能在时钟方案确定前给出 |
| R-02 → L-14 | 修复 R-02 必然使 L-14 的两条断言失效；断言更新与风险关闭必须同一次提交完成 |
| R-03 → L-10 | 重构取数流水会改变 L-10 的范围限定，需要同步更新等价性基准 |
| R-08 → R-03 / R-05 | R-08 的"重复逻辑 + 回归时长"那一半已关闭；**剩下的面积与 fmax 只能由 R-03（存在 PPU 单独综合报告）与 R-05（存在属于本项目的综合/布局布线报告）关闭**。仿真耗时只是量级信号，**不得**用它替代综合数字，也**不得**因为 R-08 已关闭就把这两条一并读成已验证 |
| R-01 → L-16 | 外部 CHR 存储器还没有延迟合同，`CHR_ADDR_BITS` 也就没有依据。L-16（MMC3 bank bit 7 被 17 bit 截断）现在被接受，是因为**地址宽度在今天不需要正确**；一旦真的接上外部存储，地址宽度必须同时决定容量与时序，那时 L-16 必须重新评估（升级、关闭，或改外部存储的组织方式） |
| R-01 / R-04 → L-17 | `$2007` 外部 CHR 写通路落地后，外部存储器**新增了写侧义务**（写截止期、同址同拍读写冲突语义、写与取数读的总线仲裁）。这三条都不是容量问题，因此**不在** R-04 的存储预算表里；它们与 L-17 的仲裁决策必须一起在外部存储方案落地时评估 |
| R-03 → R-04 → L-16 | 外部 CHR 路径降低了 PPU 内部 `chr_ram` 的多读口压力（单口总线），但把压力转移到外部存储。**外部路径的资源与时序数字一条都没有**——它既不在 R-03 的"PPU 单独综合"门槛里，也不在 R-04 的"存储预算表"里，只能由外部存储方案落地后重新评估 |
| L-18 → L-19 | L-18 的诚实版本是 L-19：即使真的接上一条 A12，"每条扫描线一次上升沿"也只是**一种**合法形状。依赖精灵的 A12 变化在**没有**真实 VRAM 地址总线时**无法**建模，所以这两条必须一起重估，**不能**只关掉 L-18 就宣称 A12 已被验证 |

### 6.1 一条证据质量备注（不是新风险条目）

- **`nes_system_v5` 没有任何像素级断言。** `tb/system/tb_nes_system_v5.v` 验的是 mapper 接线（PRG 窗口、bus conflict、mirroring 观测、IRQ 线或、`force` 造的 IRQ 链路）与保留路径的握手，**它的三个程序都在第一帧之前跑完，一个 `pixel_index` 都没有比过**（`tb/system/README.md` 的 v5 一节把这一条写成"v5 testbench 绕过的问题"）。也就是说 v5 之后有**一段已合并的代码没有像素级回归保护**：v5 与 v6 之间任何影响 PPU 渲染的改动，都不会被 `system-v5` 抓到。
- **`nes_system_v6` 的 A/B 补上了这一层**（v6↔v5 整帧逐 `ce` 像素，184,320 次可见像素 + 268,026 个不加门的 `ce`，均 0 分歧），但**它的方向是反的**：它比较的是 v6 与 v5 两个**已经存在**的顶层，不是 v6 与一份独立参考。所以它证明的是"v6 没有改变 v5 的画面"，**不是**"画面是对的"。绝对正确性仍然只有 `ppu-ext-chr-tb` 拿内部 CHR 路径做参照的那条证据。
- **共同缺口**：v6 的 A/B **只覆盖背景**；精灵像素的回归保护**只有 `ppu-ext-chr-tb` 这一条**（`ad3c17a`：同一条 A/B 已包含精灵，OAM 的 tile 号 / attribute 与 CHR 字节换成非透明图案并加了精灵可见性自检，七个精灵可观测量在 **552,960** 个比较点上**全部 0 分歧**，精灵自检 1,708 个精灵决定像素跨透明背景 908 / 不透明背景前 564 / 不透明背景后 236 三类优先级——**但它仍然是 `EXTERNAL_CHR=0` 与 `EXTERNAL_CHR=1` 之间、TB 驱动场景下的 A/B，不是实机卡带、不是 test ROM、不是硬件**；精灵特征已由那 9 个精灵场景**逐项** A/B 证明——8×16 高度（`sp1-8x16-oddtile` 40 / `sp8-8x16-mixprio` 560 个精灵决定像素）、每行 8 个 sprite 上限（`sp8-8x8-limit` 2,048 / `sp8-8x16-mixprio` 4,096 个"恰好 8 个在范围内"的 dot）、overflow 标志位（`sp10-overflow` 2,048 个 overflow dot）、水平/垂直/双翻转（`sp1-hflip` 48 / `sp1-vflip` 56 / `sp1-hvflip` 56），每组都有自己的非空洞 `$fatal`；仍未覆盖的只有 §8.2 那个 overflow **行为**差异与这 9 个场景之外没构造出来的优先级组合）；而 v5 连背景都没有像素断言。
- **MMC3 扫描 IRQ 的证据类型（登记于 P1-11 那一轮）**：`system-v6` 的 P1-11 让 MMC3 计数器 / reload / pending 状态机与 `mapper_irq → irq_line → CPU` 入口链在**建模的** PPU dot A12 刺激下跑通，`irq_pending_r` 由真实 RTL 产生。**它的证据类型是内部一致性与已发表时序吻合，不是硬件行为**——L-18 与 L-19 仍然开放，`mapper_ppu_a12` 在 RTL 里仍然绑 0，**每帧 241 是 NESdev 的文献值而不是实测**，依赖精灵的 A12 变化**没有**被建模。详见 `tb/system/README.md` 的"### P1-11"一节与本文件第 5 节的 L-18 / L-19。

## 7. 状态更新规则

- 关闭一个风险条目必须同时给出：新证据的来源（文件路径加可复现命令或报告名称）、覆盖了 `verification-plan.md` 中哪条判据、以及仍然残留的限定词。
- “已缓解”“已规避”“已接受”都不是关闭。只有门槛全部满足并留下可复现证据，条目才能标为已关闭。
- 条目降级（例如 S0 降为 S1）必须在 `docs/00-overview/decision-log.md` 追加决策，写明理由与被放弃的替代方案。
- S2 条目升级为 S0/S1 时，从第 5 节移出并按风险条目格式重写，保留原编号以便追溯。
- 本文件描述当前状态。缓解路线与门槛是未来动作，不得写成已有结果。
- 状态取值只有 `未开始`、`进行中`、`未解决`、`已登记限制`、`已关闭`；不使用“基本完成”“可忽略”“风险较低”这类不可判定的表述。

## 8. S0 风险（续）

### R-07 50 MHz 到 NTSC/VGA/音频时钟未实现、未验证

**等级/状态：** S0 / 未开始

**负责人：** 平台层

**验证证据：** 尚无。本条目前没有任何 Quartus 编译报告、TimeQuest 报告、PLL IP 参数文件、上板测量或时钟域相关断言的证据。唯一存在的证据是三个 testbench 里硬编码的 10 ns 时钟周期，而它折算出的 PPU 速率是 25 MHz，不是 5.369318 MHz。

**风险**

板载只有一颗 50 MHz 晶振（`PIN_E1`），而 NTSC NES 需要 21.477272 MHz 主时钟（`ce_ppu` = /4 = 5.369318 MHz，`ce_cpu` = /12 = 1.789773 MHz），VGA 需要 25 MHz，WM8978 需要主时钟。这三组频率**没有任何一条能从 50 MHz 用整数分频得到**（50 ÷ 1.789773 = 27.93，50 ÷ 5.369318 = 9.31，50 ÷ 21.477272 = 2.33），因此必须引入 PLL，或者接受一个 3% 量级的频率错误。当前仓库既没有生成任何 PLL IP，也没有 SDC，更没有综合或上板证据，因此**哪个方案可行、以什么误差可行，全部未知**。

**触发条件**

- 任何声称视频时序、帧率、音频音高或音画同步“正确”“可用”“已支持”的表述。
- 开始编写 `rtl/platform/ep4ce10/` 下的任何文件：顶层时钟结构一旦按某个方案写死，改方案意味着平台层返工。
- 让 NES 顶层接 50 MHz 直接跑，或反过来把 VGA 的 25 MHz 当作 NES 域时钟。
- 把 testbench 的 10 ns 时钟周期当成 NES 的真实时间基。

**影响**

- **所有视频时序和音频时序**都建立在这条之上。帧长、dot 速率、CPU:PPU 比例、APU frame counter 速率、音频音高、重采样比，全部由主时钟频率和 CPU/PPU 分频比决定。
- 频率错误会直接进入用户可见的行为：CPU 偏 +3.47% 或 -6.88% 时，游戏运行速度明显不对、帧率偏离 2 Hz、APU frame IRQ 周期随之偏移、音频音高按同样比例偏移。这类错误在功能仿真里**完全测不出来**，因为仿真只检查周期数与相对比例，不检查绝对频率。
- 时钟方案决定关键路径的时间预算：NES 域用约 21.48 MHz 时周期是 46.55 ns，比 50 MHz 的 20 ns 宽松 2.33 倍。这会改变 R-03 那条 PPU 关键路径的结论，因此**时钟方案不定，R-03 的 fmax 结论就不能给**。
- 现有 RTL 已经把 12 拍 `div_phase` 使能分配写死（`ce_cpu` 每 12 拍 1 次、`ce_ppu` 每 4 拍 1 次），这个**比例**与真机一致，因此是可直接复用的资产；但三个 testbench 的时钟是 100 MHz，折算出的 PPU 是 25 MHz。也就是说当前只有比例被钉住，**绝对频率从未被任何断言钉住**。
- 视频侧的真实跨域面只有一个 bit（行缓冲的 `line_ready_toggle`），但 `pixel_valid`、`line_done`、`frame_done`、按键、`sys_rst_n` 的处理方式必须与时钟方案一起决定；方案改动会连带改动 CDC 清单。
- 若最终只能接受一个近似频率，必须把实际频率与由此得到的帧率写成显式记录，而不是让文档继续写 21.477272 MHz 这个理想值。

**证据**

- 【事实】板级输入为 50 MHz，位于 `PIN_E1`；板级复位 `sys_rst_n` 低有效，位于 `PIN_M1`（`docs/hardware/01-ep4ce10-board.md`）。器件报告列出 2 个 PLL（`docs/hardware/00-index.md` 第 7 节）。
- 【事实】`rtl/nes_core/system/nes_system_v0.v:22-27`：`reg [3:0] div_phase`，`ce_ppu = !reset && (div_phase[1:0] == 2'b00)`，`ce_cpu = !reset && (div_phase == 4'd0)`；`:32-35` 使 `div_phase` 在 0..11 之间循环，即 12 拍。比例 12:4 = 3:1 与真机一致。
- 【事实】`tb/system/tb_nes_system_v0.v:100` 的时钟是 `always #5 clk = !clk`，即 10 ns 周期 = 100 MHz。`tb/system/README.md` 明确记录“CPU 总线周期 120 ns”“1 dot = 4 clk = 40 ns”，折算出的 CPU 是 8.333 MHz、PPU 是 25 MHz，与真机的 1.789773 / 5.369318 MHz 相差约 4.66 倍。
- 【事实】`tb/system/tb_nes_system_v0.v:772-773` 断言帧周期恰好 357368 个 `clk`，即 262 × 341 × 4。这钉住的是主时钟**周期数**，不是绝对时间。
- 【事实】`rtl/nes_core/ppu/nes_ppu2c02.v:873-887`：`pixel_valid` / `pixel_x` / `pixel_index` 是纯组合输出，`pixel_x` 每个 dot 变一次。
- 【事实】`rtl/nes_core/video/nes_line_buffer_vga.v` 用 `wr_clk` / `rd_clk` 两个独立时钟，只让 1 bit 的 `line_ready_toggle` 过两级同步器；像素数据不出双口 RAM。
- 【事实】`docs/modules/line-buffer-vga.md` 第 3.5 节记录读端速率必须 ≥ 写端速率的 4 倍：NTSC 写端 5.369318 MHz 的 4 倍是 21.48 MHz，低于 VGA 的 25 MHz，余量约 16%。第 5.5 节记录该模块没有背压，写端领先 2 行以上会静默丢行。
- 【事实】`docs/hardware/08-wm8978-audio.md` 第 3 节记录例程 MCLK 为 12 MHz，并记录 12 MHz 在 256× 配置下只能得到 46.875 kHz，不是标准采样率。
- 【审查】`docs/00-overview/decision-log.md` 与 `docs/00-overview/architecture.md` 均未记录时钟方案决策。**`rtl/platform/ep4ce10/` 目录存在**（`nes_ep4ce10_top.v`、`nes_ep4ce10_pll_stub.v`、`nes_ep4ce10_qsf_if.v` 三个文件），其中 PLL 仍是占位 stub、`nes_ep4ce10_qsf_if` 只是可编译的引脚封装层，都**未综合**（见 R-05）。
- 【推断】PLL 可达频率是离散的，21.477272 MHz 从 50 MHz 出发**无法精确得到**；器件的 VCO 范围与乘数/分频上限必须从 Cyclone IV E 手册查，本条不给出具体数值。频率误差能做到多小取决于可达组合，属于未测量。
- 【推断】帧长 341 × 262 = 89,342 个 dot 不能被 3 整除（mod 3 = 2），因此 CPU 与 PPU 的相对对齐每帧漂移 2/3 个 CPU 周期、以 3 帧循环。这是硬件性质，当前没有任何断言记录它。

**缓解路线**

1. **先用理想外部时钟做 RTL 仿真**：把 testbench 的时钟周期参数化（默认保持 10 ns 使现有断言继续成立），新增一组用 21.477272 MHz 实际周期跑同一套断言的变体，证明 RTL 行为只依赖 CE 比例、不依赖绝对频率。仿真阶段**不实例化 PLL**。
2. **补上比例与帧长的断言**：任意连续 12 拍内恰好 1 个 `ce_cpu`、3 个 `ce_ppu`；一帧恰好 89,342 个 `ce_ppu`；连续帧的 `ce_cpu` 计数按 29,780 / 29,781 / 29,781 的 3 帧循环变化。
3. **在 Quartus 中生成 altpll IP**，按每路输出的用途分配通道（NTSC 主时钟、VGA 25 MHz、MCLK、50 MHz 透传、SDRAM 100 MHz + 相移），把生成文件里的 VCO 频率、每路乘除、占空比、相移抄进文档。候选值与实际值必须分开记录。
4. **跑 STA**：声明 50 MHz 输入与全部派生时钟，显式声明异步时钟分组，为 `ce_cpu` / `ce_ppu` 的多周期路径加约束，并逐条给 `false_path` 写明理由。
5. **上板测量**实际频率并记录误差，同时更新 `docs/hardware/12-ntsc-clock-and-pll.md` 中的候选值。
6. 时钟方案确定后再解 R-03：先只综合 PPU 拿到真实 fmax，再决定背景通路是否需要改成预取流水。

**进入下一阶段前的门槛**

- 存在一个参数化的时钟周期与一组在两个不同时间基下逐拍相同的断言，覆盖 3:1 比例与 89,342 dot 帧长。
- 存在 CPU:PPU 比例的多窗口断言，以及跨 3 帧的对齐漂移断言。
- 存在生成的 PLL IP 文件，其 VCO 频率、每路乘除、占空比、相移已被抄进文档；实际频率与由此得到的帧率已作为显式记录写入，而不是继续引用理想值。
- 存在 SDC，其中 50 MHz 输入、全部派生时钟、异步时钟分组与 `ce_cpu` / `ce_ppu` 多周期路径约束齐备，每条 `false_path` 有书面理由。
- TimeQuest 报告中未约束端点为 0 或每条有解释；最差 slack 有数值记录。
- 在以上条件满足之前，任何文档、README 或状态报告都不得出现“帧率正确”“音画同步”“时钟方案可行”“已通过 STA”等表述；本文第 3 节的候选值不得被引用为设计值。

---

## 9. S0 风险（续）

### R-08 精灵 slot 选择的组合开销：每 `ce` 一次 64 项 OAM 范围扫描（**已关闭（部分）**）

**等级/状态：** S0 / **已关闭（部分）**。"重复逻辑"与"回归时长"这一半的门槛已满足并有可复现证据；原门槛里"Fitter 报告给出面积/时序数字"这一半**没有**满足，已改挂 R-03 / R-05。**本条不得被转述为面积或时序已验证。**

**负责人：** PPU 集成层（`rtl/nes_core/ppu/nes_ppu2c02.v`）+ `rtl/nes_core/ppu/nes_ppu_sprite.v`

#### 9.1 根因与修法

`nes_ppu2c02.v` 的 `g_chr_external` 分支里**重复实现**了一份 `nes_ppu_sprite` 内部本来就有的精灵范围扫描：一个本地 `sp_nth_set` 函数加一个 `always` 块，遍历 64 项 `oam_ram` 的 Y 字节算出 `range_count`，再选出当前 `dot` 落在其 8 像素 X 窗口内的最低 slot。

**修法**：`nes_ppu_sprite` 新导出纯观测输出 `cur_slot_o[3:0]`，`nes_ppu2c02` 改为**消费**它而不是重算一遍。删除了 `sp_nth_set`、那个 64 项扫描 `always` 块，以及 **11 个只服务于该扫描的 reg**。`nes_ppu2c02.v` **806 → 752 行（净删 54 行）**。

#### 9.2 `cur_slot_o` 契约

| 项 | 内容 |
|---|---|
| 位宽 | **4 bit** |
| `0..7` | 当前 `dot` **位置上**所处的 slot：既在范围内（`g < range_count`）**且**其 8 像素 X 窗口覆盖该 `dot` 的**最低** slot |
| `4'h8` | 该 dot 无精灵覆盖。并且在 `dot >= 256`、`scanline >= 240`、`reset` 拉高时**无条件**输出 `4'h8`（这些位置 `pixel_active` 恒为 0） |
| 依赖关系 | **必须是位置性的，不能依赖 pattern**——否则会形成组合环 `chr_sh -> s_pat -> slot_opaque -> cur_slot_o -> chr_sh` |
| 与 `mask` 的关系 | **无关**：它报告位置，不报告左 8 裁剪是否抑制 |
| overflow | **不携带** overflow 信息 |
| 因此可断言的不变量 | 因为它与 `mask` 无关、不携带 overflow、也不依赖 pattern，所以精灵 TB 断言的是**较弱但正确**的不变量 **`cur_slot_o <= 不透明源 slot`**，**不是**相等 |

#### 9.3 验证

| 证据 | 内容 |
|---|---|
| **A/B 零行为漂移** | `tb/ppu/tb_nes_ppu2c02_ext_chr.v` **完全未改动**。修复前后 A/B 证据**逐字节相同**：`A1 total compared pixels=921600`、`A2 lines_checked=3930 total_requests=337450 total_plane_latches=32487`、`A3 verified request addresses=337450 verified latched plane pairs=126546`；每行 16 次精灵请求仍然成立 |
| **逐 dot 等价（27 万余 tick）** | 另用**仓库外**的 scratch harness 把被删掉的那份扫描**逐字抄出来**挂在新 PPU 上逐 dot 比对，覆盖 8×8 / 8×16 / 左 8 裁剪三段共 **27 万余 tick**：覆盖 slot 的 tick 分别 **512 / 1056 / 512** 个，`sp_slot` **全等**、`sp_chr_sh` **逐字节全等**、**0 mismatch** |
| **`cur_slot_o` 契约断言** | `tb/ppu/tb_nes_ppu_sprite.v` **纯追加 3 组断言**（门控情形、`0..7` 编码含间隙与第 9 个精灵被丢弃、与 `slot_opaque` 自洽）；现有 **12 组一字未改** |
| **回归** | `-Mode ppu` **10/10 全绿**；`-Mode all` **50/50 PASS** |

#### 9.4 收益

| 项 | 前 | 后 |
|---|---|---|
| `ppu-ext-chr-tb` | 821.6 s | **162.5 s** |
| 占全量 | **45.26%** | **16.83%** |
| 全量（`-Mode all`） | 1815.3 s（约 30.3 min） | **965.6 s**（墙钟 **966.09 s**，约 **16.1 min**），降幅 **46.8%** |
| 最慢前三 | — | `ppu-ext-chr-tb` 162.5 s（**16.83%**）、`chr-feasibility-tb` 81.3 s（8.42%）、`system-v3` 61.7 s（6.39%），合计 **31.6%** |

**归因必须与机器变快分开。** 本轮机器整体比上一轮**快**约 **1.23 倍**：用 **18 个不含 PPU 的目标**测得机器系数 **0.812**，各项目标比值落在 **0.724~0.928** 带内、**无一变慢**。849.7 s 的节省里 **659.1 s（77.6%）是 R-08 的结构收益**，其余 **190.6 s（22.4%）** 是机器变快。**反事实验证**：把其余 49 个目标按 0.812 缩放预测得 **969.3 s**，实测 **965.6 s**，误差 **3.7 s** → **`ppu-ext-chr-tb` 是唯一有结构变化的目标**。

#### 9.5 对原诊断的更正（必须读，否则会重复传播）

**`oam_ram` 那条数组敏感度警告从来就不是被删掉的那份扫描发出的。** 它来自 `reg_dout = oam_ram[oam_addr_reg]`，**改动前就存在**（先跑了 baseline 才说的）。改动后警告总数 **7 → 8**，新增的 1 条来自 `nes_ppu_sprite.v` 新加的 `slot_x` `always` 块——代价远小于删掉的那份重复扫描。**原来把这条警告归因到"每 `ce` 一次 64 项扫描"是误判。**

#### 9.6 仍然残留的限定词

- **面积与 fmax 仍然只有面积这一半有数字。** （2026-09-30 登记）第 10 节已有一份 PPU-only 的 map + fit 报告，但 fmax、最差 slack、未约束端点**仍然没有任何数字**（那次跑没有 SDC）。R-03 的"存在 PPU 单独综合报告"这一条门槛**只满足了 M9K 与 LE 两项**，时序那一项仍开着；R-05 的门槛（属于本项目的顶层报告 + 板级 bring-up）**仍然一条都没满足**。本条的关闭**只覆盖"重复逻辑 + 回归时长"**，面积那一半现在有数字了，但**面积数字不能被转述为"装得下"**——同一份报告的结论是装不下（63,127 / 10,320）。
- `nes_ppu_sprite` 内部那份 64 项 OAM 范围扫描与 nth-set 优先编码**仍然每 dot 组合重算**，只是不再被 PPU 层重复实现一遍。
- 外部 CHR 精灵通路的其余限制**没有因为本条关闭而改变**：CHR 仲裁仍然**无握手无背压**、两个取数单元靠两个窗口实测不重叠才成立；先前记在这里的"shadow 差一行"与"8 位 `chr_sh` 只能交付一个字节"两条**已修掉**（`3e218bf`、`c6ea299`——`chr_sh` 已加宽到 16 bit 并用 `{sp_plane_hi, sp_plane_lo}` 拼接真正交付低/高两个平面，`pat_addr_o` 已改用下一行 scanline，所以 `scanline_sel` 直连 `scanline` 是正确的接法）。精灵像素等价性也已由 `ppu-ext-chr-tb` 的 A/B 证明（`ad3c17a`，七个精灵可观测量在 552,960 个比较点上 0 分歧，**不是实机卡带、不是 test ROM、不是硬件**），精灵特征也已由那 9 个精灵场景**逐项** A/B 证明（8×16 高度、每行 8 个 sprite 上限、overflow 标志位、水平/垂直/双翻转，每组有自己的非空洞 `$fatal`），**但仍未覆盖**的只有 §8.2 那个 overflow **行为**差异（未实现、所以不可观测；标志位一致已由 2,048 个 dot 证明）与这 9 个场景之外没构造出来的优先级组合。见 `docs/modules/ppu-external-chr.md` 第 11.3 节。
- `verification-plan.md` 7.1 的"精灵 CHR 取数已实现 / 外部模式能渲染精灵"与"PPU 的资源与时序已知"两行**继续有效**。

**门槛核对**

| 门槛 | 状态 |
|---|---|
| 把重复扫描删掉（导出 `cur_slot_o` 消费它） | **已满足** —— 9.1 |
| 回归耗时回落 | **已满足** —— 9.4，821.6 s → 162.5 s、45.26% → 16.83% |
| 行为不回归 | **已满足** —— 9.3，27 万余 tick 逐 dot 等价 + A/B 四行逐字节不变 |
| Fitter 报告给出面积/时序数字 | **面积一半已满足**（第 10 节，63,127 LE / 0-46 M9K，结论是装不下），**时序一半仍未满足**，已改挂 R-03 / R-05；不在本条范围内，也**不得**因本条关闭而被宣称 |

---

## 10. PPU 单独综合的实测结果（2026-09-30 登记）

本节只登记**读到过报告的数字**和**读到过源码的结论**。本节不做取舍判断、不推荐范围、不给重构计划——器件容量决策与是否换器件都属于未决事项。

### 10.0 这份证据是什么、不是什么

| 项 | 内容 |
|---|---|
| 器件 | Cyclone IV E `EP4CE10F17C8`（三层：`FAMILY` / `DEVICE` / `DEVICE_FAMILY`，见 `final_ext.map.rpt` 的 Settings 表） |
| 工具 | Quartus Prime **23.1std.0 Build 991 11/28/2023 SC Lite Edition**（每一份报告的 Summary 表都印这一行） |
| 流程 | `quartus_map` + `quartus_fit`。**没有跑 TimeQuest / STA** |
| 顶层 | `ppu_synth_ext_top`、`ppu_synth_int_top`、`ppu_fold_top`、`cfu_stim`、`cfu_fold` —— 全部是放在 `D:\quartusProject\` 下的激励包装，**没有一个是仓库里的 `nes_ep4ce10_top`** |
| 源文件 | `D:\quartusProject\ppu_synth2\rtlf\` 下的 `nes_ppu2c02.v` / `nes_ppu_sprite.v` / `nes_sprite_chr_fetch.v` / `nes_chr_fetch_unit.v` 副本（`final_ext.map.rpt` 的 "Source Files Read" 表逐条列出），加 `ppu_stim.v` 与 `ppu_synth_ext_top.v` |
| **不是** | 不是整芯片数字、不是 TimeQuest 数字、不是板级观测、不是 test ROM、不是真实卡带 |

报告清单（全部在仓库外，引用前请自己打开核对）：

| 报告 | 内容 |
|---|---|
| `D:\quartusProject\ppu_synth2\final_ext.map.rpt` / `final_ext.fit.rpt` | PPU，`EXTERNAL_CHR = 1`，`575e191` |
| `D:\quartusProject\ppu_synth2\final_int.map.rpt` / `final_int.fit.rpt` | PPU，`EXTERNAL_CHR = 0` |
| `D:\quartusProject\ppu_synth2\final_fold.map.rpt` / `final_fold.fit.rpt` | PPU，所有 DUT 输入接常量的对照组 |
| `D:\quartusProject\step0\real\real.map.rpt` / `real.fit.rpt` | `nes_chr_fetch_unit` 单独综合，计数器驱动激励 |
| `D:\quartusProject\step0\fold\fold.map.rpt` / `fold.fit.rpt` | `nes_chr_fetch_unit` 单独综合，输入接常量的对照组 |
| `D:\quartusProject\ppu_synth2\raw_ext.map.rpt` / `raw_int.map.rpt` | **修复前**的 RTL，用来取 10.4 节的四条原文错误 |
| `D:\quartusProject\ppu_synth2\t1.log` 等 | Verific VRFX 内部错误的原文（10.4 节） |
| `D:\quartusProject\ppu_synth2\quartus_syn_pro_only.log` | `quartus_sh --flow syn` 的失败原文（10.6 节） |

### 10.1 面积：PPU 单独综合（外部 CHR，`EXTERNAL_CHR = 1`，`575e191`）

【实测】来源：`final_ext.map.rpt`（Analysis & Synthesis Summary / Resource Usage Summary / Post-Synthesis Netlist Statistics）与 `final_ext.fit.rpt`（Fitter Summary）。

| 项 | Analysis & Synthesis | Fitter |
|---|---|---|
| 状态 | `Successful` | **`Failed`** |
| Total logic elements | **63,126** | **63,127 / 10,320（612 %）** |
| Total combinational functions | 44,322 | 44,323 / 10,320（429 %） |
| Dedicated logic registers | **19,260** | 19,260 / 10,320（187 %） |
| Total registers | 19,260 | 19,260 |
| Total pins | 159 | 159 / 180（88 %） |
| Total memory bits | **0** | **0 / 423,936（0 %）** |
| Embedded Multiplier 9-bit elements | 0 | **0 / 46（0 %）** |
| Total PLLs | 0 | 0 / 2（0 %） |

- 【实测】A&S 的 LUT 分布：4 输入 37,896、3 输入 5,336、≤2 输入 1,090；normal 模式 42,729、arithmetic 模式 1,593。**Max LUT depth 150.20、Average LUT depth 39.76**（`final_ext.map.rpt` 的 Netlist Statistics 表）——**这两行是组合深度的一个下界指标，不是时序数字**，本节不给它附任何 fmax 含义。
- 【实测】Fitter 失败原因（原文，`final_ext.fit.rpt` 消息区）：
  - `Error (170011): Design contains 44323 blocks of type combinational node.  However, the device contains only 10320 blocks.`
  - `Error (171000): Can't fit design in device`
  - `Error: Quartus Prime Fitter was unsuccessful. 2 errors, 5 warnings`
- 【实测】**BRAM 完全没有被使用**。`final_ext.map.rpt` 的 "Post-Synthesis Netlist Statistics for Top Partition" 表里只有三类原语：`boundary_port` 159、`cycloneiii_ff` 19,260、`cycloneiii_lcell_comb` 44,324。**没有 `altsyncram`、没有 MLAB、没有任何存储器原语**；`Analysis & Synthesis Messages` 段里 `Info (278001): Inferred 6 megafunctions from design logic` 的六条全部是算术，不含任何存储器推断消息。
- 【实测】那 6 个 megafunction 的**来源行号**（`final_ext.map.rpt` 的 `Info (278004)` / `Info (278003)`），因此**它们不是"来源不明"的**：

  | 实例 | 源文件:行号 | 对应 RTL 表达式 | 该实例的组合 ALUT（per-entity 表，**仅参考**） |
  |---|---|---|---|
  | `lpm_divide:Div0` | `nes_ppu2c02.v:541` | `bg_vertical_sections = bg_coarse_y_sum / 7'd30;`（当前扫描线的背景 coarse Y 段选择） | 37 |
  | `lpm_divide:Mod0` | `nes_ppu2c02.v:543` | `bg_coarse_y = bg_coarse_y_sum % 7'd30;` | 41 |
  | `lpm_divide:Div1` | `nes_ppu2c02.v:709` | `bg_vertical_sections_nl = bg_coarse_y_sum_nl / 7'd30;`（**下一条**扫描线的同一段选择，dot ≥ 341 时用它） | 37 |
  | `lpm_divide:Mod1` | `nes_ppu2c02.v:710` | `bg_coarse_y_nl = bg_coarse_y_sum_nl % 7'd30;` | 37 |
  | `lpm_mult:Mult0` | **`nes_sprite_chr_fetch.v:99`** | `pat = pa[g * 13 +: 13];` 里的常量乘 13 | 5 |
  | `lpm_mult:Mult1` | **`nes_sprite_chr_fetch.v:99`** | 同一行（函数被两处调用） | 5 |

  - **这一条纠正了一个流传的说法**：审查意见曾记"2 个 `lpm_mult` 无法归属，PPU RTL 里没有 `*` 运算符"。**两处都不对**——`rtl/nes_core/ppu/nes_sprite_chr_fetch.v:99` 就有 `*`（变量 part-select 偏移里的常量乘 13），报告的 `Info (278003)` 也把它指向这一行。四个 `lpm_divide` 的组合代价同样**不是未知**：37 / 41 / 37 / 37。
  - 上表的 ALUT 列来自 `final_ext.map.rpt` 的 "Resource Utilization by Entity" 表，而**这张表的组合列已被证明不可信**（10.3 节）。**推断来源行号是可信的**（它带源文件名与行号），**ALUT 数字只作参考，不作依据**。

### 10.2 面积：PPU 单独综合（内部 CHR，`EXTERNAL_CHR = 0`）

【实测】来源：`final_int.fit.rpt` 的 Fitter Summary。

| 项 | 数值 |
|---|---|
| 状态 | **`Failed`** |
| Total logic elements | **568,724 / 10,320（5,511 %）** |
| Total combinational functions | 484,519 / 10,320（4,695 %） |
| Dedicated logic registers | **84,415 / 10,320（818 %）** |
| Total memory bits | **0 / 423,936（0 %）** |
| Embedded Multiplier 9-bit elements | 0 / 46（0 %） |
| Fitter 失败原文 | `Error (170011): Design contains 484519 blocks of type combinational node.  However, the device contains only 10320 blocks.` + `Error (171000): Can't fit design in device` |

- 【实测】568,724 / 63,127 = **9.01 倍**（外部 CHR 构建的 9.0 倍以上，登记为 9.0x）。
- 【实测】**内部 CHR 构建同样用掉 0 个 M9K**。也就是说 `chr_ram` 那 8,192 byte 也没有进 BRAM——与 10.1 的结论一致。

### 10.3 方法说明：anti-folding 对照组，以及一处必须记录的错误归属

**这一节是方法记录，写下来是为了让下一个人不要再犯同一个错。**

- 【实测】`final_fold.fit.rpt`：**同一个 PPU，把所有 DUT 输入接成常量** → Fitter **Successful**，**187 LE** / 167 组合 / 122 寄存器 / 0 memory bits / 126 pins（`final_fold.map.rpt` 的 A&S 也是 187 / 167 / 122）。
- 【实测】`real.fit.rpt`：**`nes_chr_fetch_unit` 单独综合、计数器驱动激励** → Fitter **Successful**，顶层 `cfu_stim` 共 **185 LE** / 141 组合 / **144 寄存器** / 0 memory bits / **0 M9K** / 99 pins（`real.map.rpt` 的 A&S 是 **186** LE / 141 / 144）。**同一份报告的 per-entity 表给出了更好的数字**：`nes_chr_fetch_unit:u_dut` 自己占 **106 Logic Cells / 67 寄存器 / 0 memory bits / 0 M9K**，剩下的 79 LC / 77 寄存器属于激励包装 `cfu_stim`。
- 【实测】`fold.fit.rpt`：**`nes_chr_fetch_unit` 单独综合、输入接常量** → Fitter **Successful**，**0 LE** / 0 组合 / 0 寄存器。
- 【推断】**因此该模块的成本区间是 106（模块自身，Fitter per-entity）到 185（模块 + 激励包装，Fitter 顶层）；185 是上界。** 两个数都不是 10,989。
- 【推断】**方法要点**：把 DUT 输入全部接常量会让综合器把几乎所有逻辑常量折叠掉，于是**同一个模块报出 187 LE 与 0 LE**。**只做常量接法的探针会报出 187 LE，并据此错误地认为 PPU 装得下。** 两个数字要一起看才有意义：187 / 63,127 ≈ 1/338。**任何"面积看起来很轻松"的探针结果都要先用计数器驱动的激励复现一遍再采信。**

#### 另一条方法陷阱：Fitter 跑失败时，per-entity 表的 Logic Cells 全是 0

- 【实测】`final_ext.fit.rpt` 与 `final_int.fit.rpt` 的 "Compilation Hierarchy Node" 表里，**每一行的 `Logic Cells` 都是 0**（只有 `Dedicated Logic Registers` 与 `Pins` 有值）。原因是 Fitter 在布局准备阶段就因为 `Error (170011)` 中止，**没有任何逻辑被放置**。
- 【推断】**因此凡是从这两份失败跑里取 per-entity 数字都是无效的**，无论它看起来多具体。**只有 Fitter 状态为 `Successful` 的报告，其 per-entity 表才有意义。**

#### 10,989 这个数字是错误归属，不得继续引用

- 【实测】`final_ext.map.rpt` 的 "Resource Utilization by Entity" 表把 **10,989 个组合 ALUT** 记在 `nes_chr_fetch_unit:g_chr_external.u_chr_fetch` 名下（同一行的寄存器列写 61）。
- 【实测】同一个模块单独综合：Fitter per-entity 表给 **106 Logic Cells / 67 寄存器**（`real.fit.rpt`），顶层 185 LE / 144 寄存器。**10,989 / 106 ≈ 104 倍，10,989 / 185 ≈ 59.4 倍。**
- 【事实】模块本身有多小，可以在源码里逐条数出来（`rtl/nes_core/ppu/nes_chr_fetch_unit.v`，共 112 行）：**6 个状态**（`S_IDLE` / `S_PRE` / `S_ARM` / `S_BEAT` / `S_GRAB` / `S_DONE`，`:19-24`），**64 个寄存器位**（`state` 3 + `base_q` 13 + `cnt_q` 6 + `idx_q` 6 + `pl_q` 1 + `cap_pl` 1 + `fin_q` 1 + `chr_req` 1 + `chr_addr` 14 + `bg_lo` 8 + `bg_hi` 8 + `bg_valid` 1 + `busy` 1），**一个 6 bit 比较器**（`:34` 的 `idx_q == cnt_q - 6'd1`），**两个 14 bit 地址加法器**（`:35` 的 `nxt_addr` 与 `:36` 的 `fwd_addr`），**没有 RAM、没有乘法、没有除法**。A&S per-entity 给的 61 位与 Fitter per-entity 给的 67 位都接近源码的 64 位，**寄存器列与源码相符**。
- 【推断】**因此那张 per-entity 表的组合（ALUT）列至少对 `nes_chr_fetch_unit` 是错的**，寄存器列则与源码相符。**这张表的任何组合数字都不得用作依据。**
- 【推断】**后果**：按最保守的口径（106）也有 **10,883 LE 是虚的**，按 185 口径是 10,804 LE，占 63,127 的约 17%。**把 63,127 直接当作"真实成本"去规划会高估约一万个 LE**。**但本节不给出"修正后的 PPU 面积"这个数字**：修正值没有被测量过（没有人把虚高那部分去掉之后重新综合过一次），而上面两个口径本身也依赖一张已被证明不可信的表。**本节只登记这个差额的存在。**

### 10.4 `575e191` 修掉的四个综合合法性缺陷

在 `575e191` 之前，Quartus 23.1 **根本不能综合这个 PPU**。以下四条错误是从修复前的报告里逐字取出来的（`D:\quartusProject\ppu_synth2\raw_ext.map.rpt` 与 `raw_int.map.rpt`，两份的 `Analysis & Synthesis Status` 都是 `Failed`）：

| # | 原文错误 | 报告位置 |
|---|---|---|
| 1 | `Error (10028): Can't resolve multiple constant drivers for net "read_buffer_reg[7]"`（以及 `[6]`..`[0]`），同一根网在 `nes_ppu2c02.v(922)` 与另一处各有一个 `always` 块驱动；另有 `Error (10029): Constant driver at nes_ppu2c02.v(845)` | `raw_ext.map.rpt:245-253` |
| 1b | `Error (10028): Can't resolve multiple constant drivers for net "v_addr[14]"`（以及 `[13]`..`[0]`），`nes_ppu2c02.v(940)` | `raw_ext.map.rpt:254-263` |
| 2 | `Error (10200): Verilog HDL Conditional Statement error at nes_ppu2c02.v(846): cannot match operand(s) in the condition to the corresponding edges in the enclosing event control of the always construct` | `raw_ext.map.rpt:209` |
| 3 | `Error (10106): Verilog HDL Loop error at nes_ppu2c02.v(610): loop must terminate within 5000 iterations`（`raw_int.map.rpt:200` 在 `:613` 上是同一条） | `raw_int.map.rpt:200` |
| 4 | `Internal Error: Sub-system: VRFX, File: /quartus/synth/vrfx/verific/verilog/veriname_elab.cpp, Line: 836` / `read to RAM wasn't mapped to a specific read port`（Verific elaboration 器在同一构造上崩溃） | `D:\quartusProject\ppu_synth2\t1.log`（`t2` / `t5` / `g1` / `g2` / `h1` / `h3` / `map_int` / `raw_int_hi` 等日志有同一条） |

- 【事实】**缺陷 1 是仿真抓不到的**：`read_buffer_reg[7:0]` 与 `v_addr[14:0]` 各自被两个 `always` 块驱动，而 Icarus 按 last-write-wins 处理，多出来的驱动无害。**因此 51 个目标的 `tools/sim_all.ps1` 门禁当时仍然全绿**——这正是"仿真门禁对多驱动网有盲区"的实证（已在 R-05 登记）。`575e191` 的 commit message 记录的处理是"把每根网合并成单一驱动"，并说明两条路径按构造互斥，所以合并是忠实的并集而不是优先级选择。
- 【事实】缺陷 3 的修法是**删掉** `g_chr_flatten`，不是把它改形。`575e191` 的 commit message 记录的理由：它存在的唯一目的是给 `nes_ppu_sprite` 每 slot 两个字节，而它用 **8,192 个常量索引的读口**做到这一点——**这是 `chr_ram` 一直无法推断 BRAM 的第二个独立原因**（第一个是 R-03 记录的多读口）。改法是让精灵单元改取"每 slot 当前行 pattern 地址 + 128 bit slot 向量"，由 **8 次迭代、16 次读**构成；`nes_ppu_sprite` 因此新增 `PER_SLOT_CHR` 参数、默认 0，它自己的 testbench 与内部 CHR 路径不受影响。
- 【事实】`rtl/` 下**已经没有 `g_chr_flatten` / `sprite_chr_bus` 这两个名字**，剩下的提及全在文档里，且都只出现在 3 个文件：`docs/00-overview/risk-register.md`（本节）、`docs/modules/ppu-external-chr.md`（1.1 的分支对照表、1.3 的等价性那条、11.3.1 的接线表，全部以"已删除 / 已被替换"的口径写）、`tb/ppu/README.md`（顶层接线表那条与精灵 TB 的越界限制那条）。另有 `docs/00-overview/verification-plan.md:506` 与 `:545` 两处只提到 `sprite_chr_bus`——那两处**有意保留**，它们是"那一轮"的历史结论，原文自带"以下是那一轮的历史结论"与"**当时**仍是接口骨架"的框定，描述的是修复前的状态，改掉等于篡改历史记录。
- 【事实】`575e191` 的 commit message 自己写明："Resource numbers are unchanged by this commit, still 63127 LEs and 0 of 46 M9K for the external CHR build, so this is a legality fix only and not progress toward fitting the device."——**这一句与 10.1 的报告数字一致，也说明"修好合法性"不等于"装得下"**。

### 10.5 明确**没有**测量的东西

| 未测量项 | 依据 |
|---|---|
| **fmax、最差 slack、未约束端点** | 每次跑都出 `Critical Warning (332012): Synopsys Design Constraints File file not found: '<rev>.sdc'. A Synopsys Design Constraints File is required by the Timing Analyzer to get proper timing constraints.` 随后是 `Info (332144): No user constrained base clocks found in the design` 与 `Info (332130): Timing requirements not specified -- quality metrics such as performance may be sacrificed to reduce compilation time.`（`final_ext.fit.rpt:3976` 及其后）。另有 `Critical Warning (169085): No exact pin location assignment(s) for 159 pins of 159 total pins.` |
| **报告里根本不存在时序数据** | 对 `final_ext.fit.rpt` 全文做逐词计数：`Fitter Timing Summary` = 0 次、`fmax` = 0 次、`slack` / `Slack` = 0 次、`Setup Summary` = 0 次、`Hold Summary` = 0 次。**这不是"没找到"，是报告里没有。** |
| **因此 R-03 / R-04 门槛的时序那一半仍然开着** | 上一行就是原因 |
| 修正错误归属之后的 PPU 面积 | 没有人重新综合过（10.3 节） |
| `nes_ppu_sprite`（per-entity 表给 13,927 ALUT）与 `nes_sprite_chr_fetch`（2,891）的可信成本 | 同一张 per-entity 表的组合列已被证明对 `nes_chr_fetch_unit` 是错的（10.3 节）；这两个模块**没有**单独综合过 |
| 2 个 `lpm_mult` 的 LE 成本 | 归属已知（`nes_sprite_chr_fetch.v:99`），但**成本**只来自不可信的 per-entity 表（表里写各 5 ALUT） |
| `lpm_divide` 在整芯片上下文里的真实成本 | 同上，表里写 37 / 41 / 37 / 37 |
| 四个数组能否被重构成 BRAM 可推断形式 | 10.1 只证明了**现状**推不出 BRAM，没有测过任何改法 |
| 时钟方案相关的任何结论 | 第 10 节没有 SDC，所以连 21.48 MHz 与 50 MHz 之间的差别都没被测量 |
| 上板行为 | 没有 |

### 10.6 工具链事实（写在会被人找到的地方）

- 【事实】**Quartus Prime Lite Edition 23.1（`23.1std.0 Build 991 11/28/2023 SC Lite Edition`）不需要 license 文件。** 安装目录 `D:\intelfpga_lite\23.1std\`，可执行文件在 `D:\intelfpga_lite\23.1std\quartus\bin64\`。Lite Edition **只支持 Cyclone IV E 器件族**，本项目目标 `EP4CE10F17C8` 属于该族，因此 Lite 够用。
- 【事实】**`quartus_sh --flow syn` 在 Lite Edition 上失败**，原文（`D:\quartusProject\ppu_synth2\quartus_syn_pro_only.log`）：
  - `Error (18169): The Quartus Prime Pro Edition Design Software must be installed to use quartus_syn.  Either install the Quartus Prime Pro Edition Design Software or use quartus_map.`
  - **可用替代**：`quartus_map`、`quartus_fit`，或 `quartus_sh --flow compile`。
- 【事实】**Quartus 报告文件是 cp1252 编码，不是 UTF-8。** 用严格 UTF-8 解码器读会抛异常（报告里有一个 `0xB0` 字节）。正确读法：`[Text.Encoding]::GetEncoding(1252)`。
- 【事实】`quartus` 13.1 也在本机：`D:\altera\13.1\quartus\bin64\`（`D:\altera\` 下另有 `license.dat`），**仅作为需要时的一次回退**，本节所有数字都来自 23.1。
- 【事实】每个 System 顶层的使能分配完全一样（`nes_system_v0.v:26-27` 到 `nes_system_v6.v:176-177` 逐个相同）：`div_phase` 4 bit、循环 0..11、`ce_ppu = (div_phase[1:0] == 2'b00)`、`ce_cpu = (div_phase == 4'd0)`。**12 个系统 clk = 1 个 CPU 周期 = 3 个 PPU dot，即每个 dot 是 4 个系统 clk、其中 3 个 `ce` 为高。** `tb/system/README.md:58-59` 把它写成"12 拍中 1 拍 / 12 拍中 3 拍，1 dot = 4 clk"。
  - **据此，一份审查意见里的"每个 PPU dot 有 12 个时钟周期、`ce` 只在 12 里的 3 个为高、因此每 dot 有 9 个空闲时钟，足够藏 3 级 BRAM 读流水且像素零位移"这条，在本仓库不成立**：12 拍是**一个 CPU 周期**的长度，不是 dot 的长度；按 RTL 每个 dot 只有 **1 个 `ce` 为低的 clk**。**因此"3 级流水可零位移隐藏"这个结论在本仓库没有被建立**，任何依赖它的重构计划必须重新核算。

