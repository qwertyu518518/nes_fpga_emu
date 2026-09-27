# 风险登记册

本文件登记当前实现中**尚未关闭**的结构性风险、证据缺口，以及已命名但仍在生效的限制。风险条目在满足各自门槛之前，不得被转述为“已解决”“已支持”“已验证”或“已完成”。

本文件描述的是**当前状态**，不是计划。缓解路线和门槛是未来动作，不得读成已有结果。

证据标记约定：

| 标记 | 含义 |
|---|---|
| 【事实】 | 可直接在仓库文件中读到的实现或文档内容，条目内给出文件与行号 |
| 【审查】 | 独立审查已经写入仓库文档的结论，条目内引用该文档位置 |
| 【推断】 | 基于现有实现与器件资料的分析，**尚未经过综合、仿真或测量验证** |

当前状态的取值只有四种：`未开始`、`进行中`、`未解决`、`已登记限制`。没有“基本完成”“风险较低可忽略”这类中间状态。

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
| R-03 | CHR/nametable 多端口与常量除法/取模的时序风险 | S0 | 未解决（未做任何综合测量） | 平台/综合阶段 | 存在 PPU 单独综合的 M9K/fmax 报告；重构后逐像素等价性 TB 通过 |
| R-04 | PRG / 8 KiB CHR 留在片上对 EP4CE10 BRAM 的压力（`PRG_SIZE_BYTES` 正在参数化） | S0 | 未解决（与 R-01、R-03 耦合） | 平台/综合阶段、ROM 容量范围 | `PRG_SIZE_BYTES` 取值被正式决定，存储预算表 + NES-only Fitter 报告含 VGA/音频/SDRAM FIFO 预留行 |
| R-05 | 当前无 Quartus / ModelSim / 上板证据 | S1 | 未开始 | 任何“已上板/已通过综合”声明 | 属于本项目的 Fitter/TimeQuest 报告 + 一次可观测的板级 bring-up |
| R-06 | 当前 NMI 端到端覆盖缺口 | S1 | 未解决 | v1 功能完成声明 | 系统级 NMI TB 通过，NMI 形式在 CPU 合同中有明确约定 |
| R-07 | 50 MHz 到 NTSC/VGA/音频时钟未实现、未验证 | S0 | 未开始 | 所有视频/音频时序、平台/综合阶段 | PLL IP 已生成并由 TimeQuest 确认；绝对频率与 3:1 比例都有断言和实测证据 |
| R-08 | 精灵 slot 选择的组合开销（每 `ce` 一次 64 项 OAM 范围扫描） | S0 | 未解决 | 外部 CHR 精灵通路的时序收敛、`ppu-ext-chr-tb` 回归时长 | 把扫描移到稀疏拍或改为按行预算一次；Fitter 报告给出面积/时序数字且回归耗时回落 |

与 `docs/00-overview/verification-plan.md` 的对应关系：R-01/R-03/R-04 是 L5 的前置条件；R-06 是 L1/L4 的覆盖缺口；R-05 决定 L5 能否从“未开始”进入进行中；R-07 同样是 L5 的前置条件，因为它决定平台顶层的时钟结构；R-08 阻断的是外部 CHR 精灵通路在接近时序收敛前的可用性，同时也是 `ppu-ext-chr-tb` 回归时长已经占到全量 45.26% 的直接原因。

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
- 【事实】`rtl/nes_core/ppu/nes_ppu2c02.v:104-114`：`ppu_space_read` 组合读 CHR/nametable/palette；背景像素通路 `:179-180`、`:183-184`、`:199` 同样是组合读。
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
- 【事实】`rtl/nes_core/ppu/nes_ppu2c02.v:327`：滚动更新条件为 `mask_reg[3] && !reg_cs && ((scanline < 9'd240) || (scanline == 9'd261))`；`:330`（dot 8–248 每 8 dot 一次 `inc_x`）、`:329`（dot 256 的 `inc_x+inc_y`）、`:333-336`（dot 257 水平重载）、`:338-342`（pre-render dot 280–304 垂直重载）全部落在这个条件内。
- 【事实】`rtl/nes_core/ppu/nes_ppu2c02.v:202-219`：`pixel_valid` / `pixel_index` 是纯组合输出，背景取数通路不含任何 dot 级流水或预取状态。
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

**等级/状态：** S0 / 未解决（未做任何综合测量）

**触发条件**

- 对 `nes_ppu2c02` 做任何 Quartus 综合或布局布线（当前从未做过）。
- 保持背景像素通路的现有写法：逐像素组合读 nametable 两次、CHR 两次、palette 一次。
- 改为 BRAM 可推断的寄存读后，地址生成逻辑必须在一个周期内稳定。

**影响**

- 端口需求：按当前 RTL，`nametable_ram` 需要 3 个组合读口（`:179` 名称、`:180` 属性、`:307` 经 `ppu_space_read` 的 `$2007` 路径）加 1 个写口（`:292`）；`chr_ram` 需要 3 个组合读口（`:183`、`:184`、`:108`）加 1 个写口（`:290`）。Cyclone IV E 的 M9K 是 1R1W，因此这些数组**按现状无法映射为 BRAM**，只能复制成多份（加深 R-04 的压力）或退化为分布式 LUT RAM（吃 LE、增延迟）。
- 关键路径：背景像素输出 `pixel_index` 的组合链为 `dot`/`fine_x`/`t` → 加法器（`:168-171`）→ `/30` 与 `%30`（`:172`、`:174`）→ nametable 地址（`:177-178`）→ nametable 读（`:179-180`）→ CHR 地址（`:182`）→ CHR 读（`:183-184`）→ 位选择（`:185`）→ palette 索引（`:198`）→ palette 读（`:199`）→ `pixel_index`（`:213`）。其中 `/30` 与 `%30` 在 7 位输入上综合为比较器/LUT 链，位置正处于两级 RAM 地址之间。
- 仿真的数组索引没有端口概念，因此**当前三个 TB 全绿不能排除本条风险**。它只能在综合报告中暴露。
- 若综合后被迫复制数组，BRAM 占用会超出 R-04 的估算，平台阶段的容量结论需要重做。

**证据**

- 【事实】`rtl/nes_core/ppu/nes_ppu2c02.v:38-41`：`nametable_ram[0:2047]`、`chr_ram[0:8191]`、`oam_ram[0:255]`、`palette_ram[0:31]` 均为 Verilog-2001 数组，没有端口模式、读延迟或旁路参数。
- 【事实】同文件 `:179-180`（同拍两次 `nametable_ram[...]`）、`:183-184`（同拍两次 `chr_ram[...]`）、`:199`（`palette_ram[...]` 组合读进像素输出）、`:290-294`（同拍写 CHR/nametable/palette）、`:307`（`$2007` 读再走一次 `ppu_space_read`）。
- 【事实】同文件 `:172` `bg_vertical_sections = bg_coarse_y_sum / 7'd30;` 与 `:174` `bg_coarse_y = bg_coarse_y_sum % 7'd30;`。
- 【事实】`docs/hardware/01-ep4ce10-board.md` 与 `docs/hardware/04-memory-and-fifo.md` 记录 423,936 memory bits，等于 46 × 9,216 bit（46 个 M9K）；`04-memory-and-fifo.md` 第 1.2 节要求容量表必须列出端口模式，并警告不要按理论总量相加。
- 【推断】从未做过 PPU 单独综合，因此 M9K 计数、fmax、以及各数组是否被推断为 BRAM **全部未测量**。

**缓解路线**

1. 把背景通路改造成标准的 2-tile 预取流水（nametable → attribute → CHR 低/高面，跨多个 dot 取数），端口需求降到 1R1W，同时解决“功能级逐像素取数不表达真实取数时序”的问题（见 L-10）。
2. 移除每像素的 `/30` 与 `%30`：coarse Y 的段选择在垂直重载 dot 一次性确定，或用比较/减法替代除法。
3. 决定 CHR/nametable 的端口归属与仲裁（CPU `$2007` 访问与 PPU 内部取数同时发生时谁优先），并把结论写入 `docs/00-overview/architecture.md` 第 8 节。
4. 保留当前功能级取数作为等价性基准，重构后的 RTL 与它逐像素比对。
5. 先做一次“只综合 PPU”的最小工程，尽早拿到真实 M9K/fmax，再决定是否投入完整流水重构。

**进入下一阶段前的门槛**

- 存在一次 PPU 单独综合的 Quartus 报告（Fitter + TimeQuest），记录 M9K 数量、LE 数量、最差 slack 和未约束路径。
- 报告结论要么证明当前结构可接受（则在本条下记录 fmax 与端口代价），要么触发缓解路线的第 1、2 步。
- 重构后：`pixel_valid` / `pixel_index` 在随机 tile/attribute/palette/fine X/fine Y 图案下与重构前的功能级模型逐像素相同，并有可复现的 TB。
- 未满足以上条件前，任何文档都不得给出 PPU 的资源或时序数字。

### R-04 PRG / 8 KiB CHR 留在片上对 EP4CE10 BRAM 的压力

**等级/状态：** S0 / 未解决（与 R-01、R-03 耦合）

> **注意：PRG 容量正在被参数化。** `nes_system_v0` 已把 PRG 从固定 `prg_rom [0:32767]` 改为参数 `PRG_SIZE_BYTES`（当前默认 `16384`），并用 `prg_addr_window = cpu_addr[14:0]` 加位掩码做镜像窗口。因此“PRG 占多少 BRAM”现在是一个**尚未决定的选择**，不是一个固定事实。本条同时覆盖 16 KiB 与 32 KiB 两种取值，因为两者都会阻断平台阶段。`rtl/nes_core/system/nes_system_v0.v` 处于活跃修改状态，下面的行号与数值以本文件写入时的内容为准，决策时必须重新核对。

**触发条件**

- 把 PRG 与 CHR 数组保留在片上，无论 `PRG_SIZE_BYTES` 取 16 KiB 还是 32 KiB。
- 在此基础上再加入 VGA 行缓存或双缓冲、音频 FIFO，以及 `docs/hardware/04-memory-and-fifo.md` 记录的 2 个 16 bit × 1024 SDRAM FIFO。

**影响**

- 器件片上存储总量 423,936 bit = 46 × 9,216 bit，即 46 个 M9K。
- 按 8 位宽模式（M9K 提供 1,152 byte 深度）逐数组向上取整的**估算**：

  | 数组 | 深度×位宽 | bit | 估计 M9K | 当前端口需求 |
  |---|---|---|---|---|
  | `prg_rom`（`PRG_SIZE_BYTES = 16384`，当前默认） | 16384×8 | 131,072 | 15 | 1 组合读 |
  | `prg_rom`（`PRG_SIZE_BYTES = 32768`） | 32768×8 | 262,144 | 29 | 1 组合读 |
  | `chr_ram` | 8192×8 | 65,536 | 8 | 3 组合读 + 1 写 |
  | `nametable_ram` | 2048×8 | 16,384 | 2 | 3 组合读 + 1 写 |
  | `cpu_ram` | 2048×8 | 16,384 | 2 | 1 组合读 + 1 写 |
  | `oam_ram` | 256×8 | 2,048 | 1 | 1 组合读 + 1 写 |
  | `palette_ram` | 32×8 | 256 | 1 | 约 3 组合读 + 1 写 |
  | **合计（PRG = 16 KiB）** | — | **231,680** | **29** | 46 中剩约 17 |
  | **合计（PRG = 32 KiB）** | — | **362,752** | **43** | 46 中剩约 3 |

- 两种取值都不足以容纳完整平台：
  - **PRG = 32 KiB**：NES 存储吃掉约 43/46 个 M9K，只剩约 3 个。SDRAM 例程的两个 FIFO（16 bit × 1024，各 16,384 bit）在 8 位宽下各需 2 个 M9K、在 16 位宽下各需 4 个，**仅这一对 FIFO 就超出剩余量**。
  - **PRG = 16 KiB**：剩约 17 个 M9K，扣掉 SDRAM FIFO 对（8 位宽 4 个 / 16 位宽 8 个）后剩约 13 / 9 个。一个 4096 帧的 32 bit 立体声音频 FIFO 需要 16,384 byte（16 bit 宽下约 15 个 M9K），再加 VGA 行缓存，17 个 M9K 仍然不够。位宽选择会改变计数，这正是 `04-memory-and-fifo.md` 反复强调的不能按理论总量相加。
- 逐数组向上取整造成的浪费是真实的：M9K 不能跨数组按位拼接。PRG = 16 KiB 时位总数余量约 192,256 bit（相当于 20.9 个 M9K），但按数组取整后只剩约 17 个。
- 功能后果（与容量无关，独立成立）：片上 PRG + 8 KiB CHR RAM 等价于 NROM + CHR-RAM 且无 bank 切换，因此只能运行这一类游戏；任何需要 PRG banking 或 CHR ROM 的 mapper 都被容量挡在外面。把 `PRG_SIZE_BYTES` 调小只会进一步收窄 ROM 容量，不会缓解结构性冲突。
- 640×480 RGB565 整帧缓存（614,400 byte）无论如何进不了片上 BRAM；即使只做行缓存，也必须在上面剩余的 M9K 之上再挤出一份。
- 与 R-03 耦合：若多端口需求迫使复制数组，M9K 计数会进一步上升。

**证据**

- 【事实】`rtl/nes_core/system/nes_system_v0.v:3-4`：模块参数 `PRG_SIZE_BYTES`，当前默认 `16384`；`:20` `PRG_INDEX_BITS = $clog2(PRG_SIZE_BYTES)`；`:39` `prg_rom [0:PRG_SIZE_BYTES-1]`；`:53-54`、`:60-61` 用 `cpu_addr[14:0]` 加位掩码形成镜像窗口。
- 【事实】`rtl/nes_core/system/nes_system_v0.v:38`：`cpu_ram[0:2047]`。
- 【事实】`rtl/nes_core/ppu/nes_ppu2c02.v:38-41`：`nametable_ram[0:2047]`、`chr_ram[0:8191]`、`oam_ram[0:255]`、`palette_ram[0:31]`。
- 【事实】`docs/hardware/01-ep4ce10-board.md` 记录厂商例程 Fitter 报告：10,320 LE、423,936 memory bits、2 PLL、46 个 9-bit 乘法器；同文件第 11 行说明“约 52 KiB”只是数量级，不表示所有存储模式都能得到同样有效容量。
- 【事实】`docs/hardware/04-memory-and-fifo.md` 第 1.1 节记录 423,936 bit ≈ 52,992 byte ≈ 51.75 KiB、`8_ip_ram` 是单端口 32×8 的 `altsyncram`，以及 SDRAM 例程的两个 FIFO 为 16 bit × 1024。
- 【事实】`docs/hardware/05-vga-lcd.md` 第 85 行记录 640×480×2 byte = 614,400 byte/帧、约 36.6 MB/s，以及 NES 读与 VGA 读会竞争资源。
- 【事实】`docs/00-overview/architecture.md` 第 9 节已把 PRG/CHR 规划到 SDRAM 层，并写明帧缓存不能默认放片上。
- 【审查】`docs/00-overview/decision-log.md`“未决事项”已列出“EP4CE10 上 PRG/CHR、帧缓存、音频 FIFO 的实际存储分配”尚未决定。
- 【审查】`tb/system/README.md` 描述的仍是“固定 32 KiB PRG + 8 KiB CHR RAM”。在 `PRG_SIZE_BYTES` 参数化之后，该描述已与 RTL 现状不一致，必须随参数决定一并更新，不能让两处说法并存。
- 【推断】上表 M9K 数量是按 8 位宽模式的向上取整估算，**未经 Fitter 验证**。实际值取决于综合器推断结果、是否使用 IP，以及位宽/深度组织。

**缓解路线**

1. 执行已决定的分层：工作 RAM、nametable、OAM、palette 留在片上；PRG 与 CHR 通过 R-01 的存储层放 SDRAM。
2. 输出一份版本化的存储预算表，每行至少包含：逻辑深度、数据位宽、端口模式、估计与实测 M9K、旁路/输出寄存器、复位策略、所属层次、访问者与仲裁规则。
3. 预算表必须把 VGA 行缓存、音频 FIFO、2 个 SDRAM FIFO 和任何 CDC 缓冲作为**已预留行**写进去，而不是最后再补。
4. ROM 容量与 mapper 范围随分层结果确定，并写进 `project-charter.md` 的 v1 范围。`PRG_SIZE_BYTES` 的取值必须由该结论反推，而不是先定参数再找容量依据。
5. 若选择 PRG 留在片上，必须先证明剩余 M9K 足以容纳所有已预留行，并接受由此产生的 ROM 容量上限。
6. 参数化之后，`tb/system/README.md` 与 `project-charter.md` 中关于 PRG 容量的描述、`decision-log.md` 的未决事项、以及 mapper 范围必须一次性对齐，不能让两处说法并存。

**进入下一阶段前的门槛**

- 存在一份 NES-only 的 Quartus 布局布线报告，含 M9K/BRAM、LE、寄存器、PLL、IO 的实测数字。
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

- 现在唯一可重复的证据是 Icarus Verilog 下的 **34 个**自包含 testbench（`tools/sim_all.ps1` 的 `$allTargets` 实际求值实测 50 个目标 = 16 个 compile-only + 34 个仿真）。**没有任何综合、布局布线、时序分析、板级电气或上板行为证据。**
- 因此以下判断目前**全部无证据**：资源够不够、fmax 够不够、BRAM 能否推断、SDC 是否完整、引脚与 IO standard 是否正确、复位与 PLL 是否稳定、画面与声音是否正确。
- 这直接限制 R-01/R-03/R-04 的关闭方式：它们无法靠仿真关闭。
- 证据工具本身还有一个缺口：只有 Icarus 一个行为仿真器，`run_*.do` 只覆盖 `tb/cpu/`、`tb/ppu/`、`tb/system/`、`tb/apu/`，其余目录没有 ModelSim 入口脚本；`tools/sim_cpu.ps1` 的 `rtl` 与 `pure` 两个模式实际执行同一条命令。
- `docs/hardware/` 中出现的 BRAM、PLL、乘法器数字来自**厂商例程**的 Fitter 报告，不能当作本项目工程的资源结论。

**证据**

- 【事实】`rtl/` 下已有 `nes_core/{cpu,ppu,system,video,bus,apu,mapper,controller,cart,peripheral}` 与 `platform/ep4ce10/`（3 个 `.v`），平台顶层 `nes_ep4ce10_top` 存在。
- 【事实】仓库内已有 `quartus/op_fpga_emu.{qpf,qsf,sdc}` 工程骨架：`.qsf` 声明 `DEVICE EP4CE10F17C8` 与 `TOP_LEVEL_ENTITY nes_ep4ce10_top`，`.sdc` 含 3 条 `create_clock`（50 MHz `sys_clk`、21.477272 MHz `clk_ntsc`、25 MHz `clk_vga`）与 2 条 `set_false_path`。但 `set_location_assignment` 0 条、`create_generated_clock` 0 条（altpll 未生成）、`set_input_delay`/`set_output_delay` 各 0 条，且三个文件**从未在 Quartus 中打开或编译**；仓库内仍无 `.qip`、`.sdf`、`.stp`、`.srf`。实测数字见 `quartus/README.md` 第 0.1 节。
- 【审查】`tb/ppu/README.md` 与 `tb/system/README.md` 均写明“当前仓库没有 ModelSim、Quartus 或 EP4CE10 上板证据；该脚本未被本版本验证”。
- 【审查】`docs/00-overview/verification-plan.md` 第 4 节 L5 的结论是"此层状态是未开始，而不是失败或通过"，并已明确记录"**骨架不是结果**"：`quartus/` 下三个文件存在、平台顶层 `nes_ep4ce10_top.v` 存在但**未综合**、`.qpf`/`.qsf`/`.sdc` **从未在 Quartus 中打开或编译过**；同文档第 3.3 节说明 ModelSim 通过也只增加独立工具证据，不代表 EP4CE10 适配完成。
- 【事实】`tools/sim_cpu.ps1:3` 的 `ValidateSet` 为 `rtl|pure|integration|bus|all`，其中 `rtl` 与 `pure` 都调用 `-Top nes_cpu6502` 加同一份源文件；`:14-15` 把工具路径硬编码为 `C:\iverilog\bin`。
- 【事实】`tb/ppu/README.md` 与 `tb/system/README.md` 的期望运行时间分别约为几十秒和约 9 秒，说明仿真规模已经不小，进一步的证据补齐需要规划时间预算。

**缓解路线**

1. 先补齐证据工具的可重复性：给 PPU 与系统 testbench 增加脚本入口（或新增统一脚本），并把三个 TB 的工具版本、完整命令行和期望输出固定下来。
2. 选一个不涉及外部存储的最小工程（CPU 顶层或 PPU 顶层）先跑通 Quartus 分析与布局布线，拿到第一份属于本项目的 Fitter/TimeQuest 报告。该步骤同时为 R-01、R-03 提供输入。
3. 为 NES core 写第一版 SDC（时钟、复位、generated clock，以及 false path / 多周期路径的显式理由），并把每次报告的资源与 slack 数字追加到 `docs/00-overview/`。
4. 板级 bring-up 从最小可观测序列开始：例如把 `cpu_cycle` / `frame_done` 计数，或一个已知 PRG 字节、固定 palette 值映射到 GPIO/LED，而不是直接接 VGA + 音频 + TF。
5. ModelSim/Questa 作为第二工具逐步接入（先 CPU，再 PPU，再系统），每次记录版本与差异。

**进入下一阶段前的门槛**

- 存在至少一份属于本项目的 Quartus 编译与布局布线报告，含器件、封装、速度等级、资源与 TimeQuest slack。
- 存在一次可复现的板级 bring-up 观测，哪怕只是把一个固定常量或计数器输出到引脚。
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
- 【事实】`rtl/nes_core/ppu/nes_ppu2c02.v:316-320`：`nmi_o` 只在 `scanline==241 && dot==0` 这一个判定点采样 `control_reg[7]`；`:322-325` 在 `(261,0)` 自动清零。
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
| L-11 | 精灵、sprite 0 hit、sprite overflow、8×16、优先级与翻转均未实现 | 全部精灵 | `tb/ppu/README.md`、`tb/system/README.md` | v1 范围决策时 |
| L-12 | APU、`$4000-$5FFF` 恒返回 0、OAM DMA、DMC DMA、mapper IRQ 均不存在 | 音频与 DMA | `tb/system/README.md` | v1 范围决策时 |
| L-13 | testbench 用层次引用访问内部数组与 `dbg_*`，不是可移植验证接口 | 全部三个 TB | `tb/system/README.md` | TB 重构或 RTL 重命名时 |
| L-14 | 系统 TB 锁死 12 拍使能分配（帧长 357368 clk、CPU/PPU 同相、每访问浪费一个 dot） | 系统 TB 断言 | `tb/system/README.md` | R-02 关闭时 |
| L-15 | 系统 TB 中工作 RAM 写通路与 `$0000-$1FFF` 译码为空覆盖 | 系统 TB 覆盖 | `tb/system/README.md` | R-01 存储层就位后 |

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
- 【事实】`rtl/nes_core/ppu/nes_ppu2c02.v:277-289`：`pixel_valid` / `pixel_x` / `pixel_index` 是纯组合输出，`pixel_x` 每个 dot 变一次。
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

### R-08 精灵 slot 选择的组合开销：每 `ce` 一次 64 项 OAM 范围扫描

**等级/状态：** S0 / 未解决

**负责人：** PPU 集成层（`rtl/nes_core/ppu/nes_ppu2c02.v`）

**验证证据：** 没有任何综合报告。唯一的量化证据是 `tools/sim_all.ps1 -Mode all` 的逐目标耗时：同一条 RTL 在接与不接精灵 slot 选择这两版之间，`ppu-ext-chr-tb` 从 143.7 s 涨到 821.6 s。**这不是综合数字，只是量级信号。**

**风险**

`nes_ppu2c02.v` 的 `g_chr_external` 分支（`EXTERNAL_CHR = 1`）里，为了在每个 `ce` 上给出"当前该用哪个 sprite slot"，有一段组合逻辑（`:494-520`）必须**每 `ce` 求值一次 64 项 OAM 范围扫描**：`sp_in_range` 遍历 64 个 OAM 项做 Y 范围比较并累加 `range_count`，随后对 8 个候选 slot 各调一次 `sp_nth_set`（它自己又扫一遍 64 bit 向量）。与之相邻的还有一段同形状的 slot 选择逻辑在 `nes_ppu_sprite.v` 内部（`EXTERNAL_CHR = 0` 路径），所以这条成本在两条路径上都存在，只是 `EXTERNAL_CHR = 0` 的目标没有精灵 `chr_sh`/shadow 那条敏感的组合链，代价没有被放大到同量级。

**影响**

- **面积**：64 项范围比较 + 8 次 64 bit 优先编码展开，在 Cyclone IV E 上是数百个 LE 量级的组合逻辑。EP4CE10 全部只有 10,320 LE（`docs/hardware/01-ep4ce10-board.md` 引用的厂商例程数字），**本项目从未综合过，所以真实占用未知**。
- **时序**：这段逻辑挂在 `chr_sh` → `nes_ppu_sprite` 的 `s_plane_lo`/`s_plane_hi` → `slot_opaque` → `sprite_pixel` 路径上，也就是**每个 PPU dot 的精灵像素输出**都在等它。它和背景像素通路（`/30`、`%30`、两级 RAM 读，见 R-03）叠在同一个 `pixel_index` 收敛点上。
- **回归时长**：`ppu-ext-chr-tb` 占全量从 15.0 % 升到 **45.26 %**，与 `chr-feasibility-tb` 合计 **51.0 %**；全量从 958.0 s 涨到 1815.3 s（**+89 %**）。**一半以上的回归墙钟压在两个目标上**，继续加逐帧断言的边际成本已经很高。
- **真实开销与假象必须分开**：本机这一轮整体慢约 **×1.17~×1.35**（用**不含 `nes_ppu2c02`** 的目标测得：`mapper-combined` ×1.35、`cpu-integration` ×1.31、`cpu-inc` ×1.26）。扣除抖动带后，`ppu-ext-chr-tb` 仍有约 **×4.7 的纯结构倍数**；`chr-feasibility-tb` 残差约 ×1.14、`ppu-integration` 约 ×1.11、`system-v3` 约 ×1.10、`system-v2` 约 ×1.08；`system-v0`/`v0-nmi`/`v1-audio`/`v4`/`v5`/`platform-tb` 落在抖动带内（残差 ≈ ×0.93~×0.97），**测不出结构性成本**。Icarus 报出的 `@* is sensitive to all 256 words in array 'oam_ram'` 警告与这个判断一致。

**证据**

- 【事实】`rtl/nes_core/ppu/nes_ppu2c02.v:494-520`：`always @*` 块里 `for (sp_si = 0; sp_si < 64; ...)` 按 `scanline` 与 `oam_ram[{sp_si[5:0], 2'b00}]` 做 9 bit 减法并比较 `< sp_height`，得到 64 bit `sp_in_range` 与 `sp_range_count`；随后 `for (sp_gi = 0; sp_gi < 8; ...)` 对每个 slot 调 `sp_nth_set`（`:471-492`，内部 `for (b = 0; b < 64; b = b + 1)`），再用 `oam_ram[{sp_idx[5:0], 2'b11}]` 算 `sp_xoff` 判水平覆盖。整个 `always @*` 的输出 `sp_slot` 直接决定 `sp_base_lo`/`sp_base_hi`（`:524-525`）→ `sp_plane_lo`/`sp_plane_hi`（`:526-527`）→ `sp_chr_sh`（`:528`）→ `u_sprite` 的 `chr_sh`（`:552`）。
- 【事实】同文件 `:16-48` 的模块头注释记录了这套组合 mux 成立的**前提**：背景最后一个请求拍在 dot 250、从 dot 253 起占有总线；精灵占 dot 257..291；下一个背景预取在 dot 324。注释同时写明一旦前提被破坏，**背景请求拍会被静默丢弃且没有背压**。
- 【事实】`rtl/nes_core/ppu/nes_ppu2c02.v:582-583`：`assign chr_req = sp_bus_sel ? sp_chr_req : bg_chr_req;` / `assign chr_addr = sp_bus_sel ? sp_chr_addr : bg_chr_addr;`，`sp_bus_sel = sp_busy`（`:523`）——纯组合优先级，**没有 ready/valid**。
- 【事实】`rtl/nes_core/ppu/nes_ppu_sprite.v` 内部有同形状的 64 项 OAM 范围扫描与 nth-set 优先编码（每 dot 组合重算），`docs/modules/ppu-sprites.md` 与 `README.md` 的模块表都把这一点写进"每 dot 组合重算的并行 sprite 通路"。
- 【推断】LE 数与 fmax **完全未知**：本仓库没有任何 PPU 单独综合报告，R-03 的门槛（"存在一次 PPU 单独综合的 Quartus 报告"）尚未满足，因此本条无法用综合数据关闭。
- 【事实】实测耗时：`ppu-ext-chr-tb` 143.7 s → **821.6 s**（占全量 15.0 % → **45.26 %**）、`chr-feasibility-tb` 74.9 s → **104.1 s**（5.73 %）、全量 958.0 s → **1815.3 s**（约 16.0 min → 30.3 min，**+89 %**）。同一次全量的四行输出与上一轮**逐字节相同**（`A1 total compared pixels=921600`、`A2 lines_checked=3930 total_requests=337450 total_plane_latches=32487`、`A3 verified request addresses=337450 verified latched plane pairs=126546`），即**帧数、断言条数一条都没变**。

**缓解路线**（尚未实施，也尚未决定采用哪一条）

1. **把 slot 选择从"每 `ce` 求值"改成"每行预算一次"**：在 dot 257 之前那几个没有 CHR 请求的 `ce` 上把 8 个 slot 的选择算好并锁存，整行只查表。代价是 sprite 的水平位置判定从组合变成一次预计算，需要在行首重算，并处理 pre-render 行与 vblank 行。
2. **把 64 项扫描挪到稀疏拍上**：只在需要的那一拍（或少数几拍）驱动扫描，其余 `ce` 保持寄存器值。等价于 1 的一种实现。
3. **让 `nes_ppu_sprite` 直接导出它内部已经算好的 slot 索引**，PPU 层不再重算一遍同一件事。这条最干净，但会改 `nes_ppu_sprite` 的端口形状，而该模块的端口**已被 `tb/ppu/tb_nes_ppu_sprite.v` 锁定**。
4. 任何改动都必须**先重推 `nes_ppu2c02.v:16-48` 的三个仲裁窗口**（背景 253 / 精灵 257..291 / 背景 324），否则会引入"背景请求拍被静默丢弃"这条无背压的失效模式。

**验证方式**

- **Fitter 报告**：存在一份 PPU（或至少含 `g_chr_external` 的层次）的 Quartus 报告，给出该段的 LE 数与最差 slack，并与本条记录的上界估算对照。
- **回归耗时回落**：改动后重跑 `.\tools\sim_all.ps1 -Mode all`，`ppu-ext-chr-tb` 的耗时从 821.6 s 明显回落（目标是回到与 `chr-feasibility-tb` 同量级，即 100 s 上下），且 `ppu-ext-chr-tb` 打印的三个 A 行**保持逐字节不变**。
- **行为不回归**：背景的 921,600 次逐 `ce` 逐 dot 像素比对仍然全部一致，精灵的每行 16 次请求断言仍然成立（这两条已经是 `ppu-ext-chr-tb` 里的断言，不需要新写）。

**进入下一阶段前的门槛**

- 上述"Fitter 报告"与"回归耗时回落"两条同时满足，且 `docs/modules/ppu-external-chr.md` 第 11.3.8 节与本条同步更新。
- 在此之前，**不得**宣称外部 CHR 精灵通路"接近时序收敛"或"代价可接受"，`verification-plan.md` 7.1 的"精灵 CHR 取数已实现 / 外部模式能渲染精灵"一行继续有效。
