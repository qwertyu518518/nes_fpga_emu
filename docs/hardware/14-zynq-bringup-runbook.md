# 14 Zynq 上板 bring-up 手册：四个产物的分阶段点亮顺序与症状归因

## 0. 本文要解决的问题

`feature/ps-peripherals-hdmi-usb-sd` 上有 **11 个提交**（`master..HEAD`），它们给 `nes_zynq_top` 加了 HDMI、触摸 dpad 自校准、TPAD 的 A/B↔Start/Select 替换、PS 侧运行时卡带加载和 USB HID 手柄。**这些改动没有一个字节在真实板子上运行过。** 手上只有四个产物和五件要验的事，而且它们的**置信度并不相同**。

没有顺序的话，人的本能是先把最"完整"的产物——`BOOT.bin`——烧进去，因为它是 FSBL + 应用 + 比特流三合一。这恰好是最坏的选择：它失败时，失败点在**五个子系统和一条从未执行的启动链**之间不可分辨。

本文的价值只有一个：**把测试排成一条链，让每一阶段的失败都能收敛到一个受限的原因，并把观察到的症状映射到它指向的子系统。** 本文是操作手册，不是实现说明；每个模块的接口合同与证据见第 13 节的交叉引用，本文不重述。

> **本文不含**：任何 RTL 改动、任何构建、任何硬件访问。所有"做什么"都是给人执行的现场指令。

---

## 1. 证据标记（先读这一节）

本分支最危险的一件事，是把**仿真门禁的绿灯**读成**板子能跑**。`.\tools\sim_all.ps1 -Mode all` 现在是 73/73 全过，但仿真里没有一个真实 GT9147、没有一个 USB 设备、没有一张 SD 卡、没有一个显示器。为了让这两种状态无法被混读，本文每条关于行为的断言都只带以下三个标记之一，**不留空**：

| 标记 | 含义 | 现在属于它的东西 |
|---|---|---|
| **【仿真已验】** | 有可复现的仿真门禁或 host test 证据，附目标 id / 命令；**不等于上板可用** | AXI 寄存器协议、卡带加载通路、OR 仲裁、触摸校准状态机、TMDS 编码、第二个 MMCM 频率 |
| **【从未运行】** | 从未在任何硬件上执行过，没有任何证据 | HDMI 输出、触摸读真实控制器、PS boot chain、SD 读、USB 枚举、真实 TPAD 极性 |
| **【上板已验】** | 已在真实板上观察到。**本分支目前为空**——保留此标记只为表明刻度 | （无） |

三个标记是 `docs/hardware/` 既有证据等级（`【已确认事实】`/`【待上板验证】`/`【风险提示】`）在"这条行为到底跑过没有"上的细化。看到 **【仿真已验】** 时，正确读法是"**逻辑对**"，不是"**板子对**"。

---

## 2. 四个产物与它们的置信度

| 产物 | 是什么 | 怎么进板 | 置信度 |
|---|---|---|---|
| `D:\vivadoProject\zynq_bitstream_v10\nes_zynq_top_a_default.bit`（4,045,672 B） | **PL-only**，JTAG 可编程。含 HDMI、自校准触摸驱动、TPAD | JTAG | **最高**——这是相对"已经能跑的东西"改动最小的一档 |
| `D:\vivadoProject\zynq_bitstream_v9\nes_zynq_top_a_default.bit`（4,045,672 B） | **PL-only**，触摸自校准**但不含 HDMI** | JTAG | **高**——LCD 通路与之前跑过的版本逐字节相同；HDMI 破坏现有画面时的回退 |
| `tools\ps\out\ps_nes.bit`（4,045,674 B） | PS 设计的 PL 比特流。**没有 `BOOT.bin` 就不能直接用**，因为按 PS 启动流程 PL 必须由 FSBL 编程 | 否 | —（必须配 `BOOT.bin`） |
| `tools\ps\BOOT.bin`（4,215,424 B） | FSBL + loader app + 比特流三合一 | **SD 卡启动**，不是 JTAG | **最低**——一整条从未执行过的 PS 启动链 |

`ps_nes.bit` 单独用 JTAG 烧**不能**把 PS 侧跑起来：`ps_nes.bit` 是给 FSBL 当 bitstream partition 用的，它要的是 `BOOT.bin` 那条路。所以本手册不把 `ps_nes.bit` 列为独立阶段——它被 Stage 3 的 `BOOT.bin` 覆盖。

---

## 3. 为什么必须是这个顺序：单变量隔离

排序原则：**从独立变量最少、改动最小的产物，到独立变量最多的产物。** 每上一个阶段，只允许新引入的子系统成为"新变量"。

```text
Stage 1  JTAG 烧 v10   ── 变量：HDMI + 触摸校准 + TPAD 替换（都在这一个 PL 内）
Stage 2  画面/输入二分  ── 用 v9 拿掉 HDMI 这个变量
Stage 3  SD 启动        ── 新增变量：FSBL + PL 编程 + loader + SD 读（整条 PS 链）
Stage 4  USB 手柄       ── 新增变量：P4 跳线 + USB0 host 模式 + 枚举
```

关键结论，必须说清楚：

> **Stage 1 失败，和 PS 一点关系都没有。** v10 里没有 PS、没有 SD、没有 USB。所以 Stage 1 出问题时**不要**去查启动跳线、卡格式、`xusbps` 配置——那全部还没上电。这正是从 Stage 1 开始、而不是从 `BOOT.bin` 开始的原因。

Stage 3 只有在 **Stage 1 出了画面**之后才做：画面是"PL 被正确编程、视频通路活着"的最廉价的判据；如果 PL 本身都没点亮，SD 启动失败就又多了一层歧义。

---

## 4. 上板前置清单（物理前提）

开工之前逐项打勾。这几项中有**任何一项没做，后面的排查都会指向错误的方向**：

- [ ] **JTAG ribbon 插到底、卡扣扣好。** 它反复是"能不能 enumerate"与"根本连不上"的差别；**主板 USB 侧 enumerate 失败就是这个签名**——先怀疑排线，不要先怀疑 bitstream。
- [ ] **SD 卡是 FAT32**（不是 exFAT、不是 NTFS），`tools\ps\BOOT.bin` 放在**根目录**。
- [ ] **卡带镜像命名为 `0:/game.nes`**（根目录、小写 `game.nes`）。loader 打开的就是这个路径。
- [ ] **boot-mode 选择器置 SD**（不是 JTAG、不是 QSPI）。
- [ ] **P4 "OTG SW" 跳线置 host**（USB 用）。四个 Type-A 口只在 host routing 下带电；**没有软件绕过**。
- [ ] HDMI 线接到**已知支持 720×480p60 的显示器**；显示器输入源切到对应口。
- [ ] 串口接好，**115200 8N1**（UART0，MIO 14/15）。
- [ ] 已知并接受一条板级事实：DDC/EDID **故意不做**——`tmds_scl`/`tmds_sda` 在板上是 R19/P20，归触摸控制器，顶层没有声明这两个端口。不要指望设计去读 EDID。

---

## 5. Stage 1 — JTAG 烧 v10（PL-only）

### 做什么

用 JTAG 把 `D:\vivadoProject\zynq_bitstream_v10\nes_zynq_top_a_default.bit` 编程进 PL。**不插 SD、不动启动模式、不依赖 PS、不接 USB。**

### 成功标志

- **LCD 出画面**（不是白屏、不是花屏）；NES 画面几何稳定。
- **触摸 dpad 四方向正确**：在屏幕上按左/右/上/下，NES 里方向正确。这是自校准是否读对了坐标帧的直接判据。
- **HDMI 出画面**：同一帧内容出现在 HDMI 显示器上。
- **TPAD 替换正确**：按住板载 TPAD 时，`key0`→**Start**、`key1`→**Select**；不按 TPAD 时，`key0`→**A**、`key1`→**B**。

### 失败怎么办

按第 9 节症状表分流。三条独立判据（画面、触摸、TPAD）可以两两组合，这正是 Stage 1 能"一句话定位"的根据：

- 画面坏 → 视频通路（LCD 侧），见症状表第 2 行。
- 画面好、触摸方向坏 → 触摸校准或坐标帧，见第 3、4 行。
- 触摸好、TPAD 坏 → TPAD 极性，见第 5 行。
- 只有 HDMI 坏 → 见第 1 行，并用 Stage 2 的 v9 把它拿掉。

---

## 6. Stage 2 — 画面与输入的二分；v9 回退

Stage 1 不需要额外操作，本阶段是当 Stage 1 出现"画面与输入其中之一坏"时用的**隔离步骤**。

### 做什么

把 v9（`D:\vivadoProject\zynq_bitstream_v9\nes_zynq_top_a_default.bit`）JTAG 烧进去。v9 是**自校准触摸但不含 HDMI**的版本，LCD 通路与之前跑过的版本逐字节相同。

### 成功标志 / 失败怎么办

| 用 v9 后 | 结论 | 下一步 |
|---|---|---|
| LCD 画面**正常** | 画面回归是 **HDMI 引入的**；v9 把 HDMI 这个变量拿掉了 | 保留 v9 作为可用工作版本，转去查第 9 节第 1 行（HDMI） |
| LCD 画面**也坏** | 问题**不在 HDMI**；是共享视频通路/触摸/时钟的回归 | 查第 9 节第 2 行；HDMI 不是嫌疑对象 |

这条二分的价值：它用**一次烧写**把"HDMI 坏了"和"视频链本来就坏了"分开，而不用去改任何代码。

---

## 7. Stage 3 — SD 启动（`BOOT.bin`）

**前置：Stage 1 已经出过画面。** 否则 PL 编程本身是否成功未知，SD 启动失败会与 PL 失败混在一起。

### 做什么

1. 按第 4 节准备 SD 卡：FAT32、`tools\ps\BOOT.bin` 在根、`0:/game.nes` 在根。
2. boot-mode 选择器置 SD。
3. 上电，打开串口（115200 8N1）。

### 成功标志

UART 依次出现：**PS↔PL 链路自检通过**（`SCRATCH` 往返四种图案，且 `ID` 读回 `0x4E455301`）→ SD 挂载成功 → `0:/game.nes` 打开、iNES 头解析成功 → PRG、CHR 流送完成 → `LOAD_EN` 清除、console 释放 → 画面出现卡带内容。

失败报告是**分阶段且互不相同**的，console 在任一失败下都**不会被释放**：link check failed、无卡/文件系统不可读、文件不存在、iNES 头非法、PRG 短读、CHR 短读。每一个都指向不同的修法。

### 失败怎么办

| 现象 | 先查 |
|---|---|
| **完全没有 UART 输出** | boot-mode 选择器、卡格式/FAT32、FSBL——整条链从未执行过，先确认 BootROM 有没有跑起来 |
| **UART 有输出，但 link check 失败** | AXI 寄存器通路。这是**唯一有仿真覆盖**的部分，见第 9 节第 7 行 |
| **link 过了，但卡挂载/文件失败** | FatFs、卡格式、文件名是否恰好 `0:/game.nes` |
| **文件成了，但流送进去画面不对** | RTL 加载通路的字节序/地址自增（仿真是非空的，见第 11 节） |

---

## 8. Stage 4 — USB 手柄

**前置：Stage 3 已经把 console 跑起来。** loader 先跑、手柄后起步；loader 失败时根本到不了手柄。

### 做什么

1. 确认 **P4 "OTG SW" 跳线在 host**。
2. 把一个 HID gamepad 插进 Type-A 口。
3. 上电，观察 UART 的枚举/失败行，再试按键。

### 成功标志

UART 不在任何 `USBGP_ERR_*` 阶段停下；插拔手柄时能枚举；按手柄的 A/B/Select/Start/方向，NES 里对应的动作发生。

### 失败怎么办

| 现象 | 先查 |
|---|---|
| **`no device attached (port reset failed)`，完全没枚举** | **P4 跳线**必须 host；其次 PS USB0 配置。跳线没设时四个口全死，**无软件绕过** |
| **停在某个 `USBGP_ERR_*` 阶段** | 那个阶段名就是修法：`controller lookup/init`、`endpoint/DMA config`、`device descriptor malformed`、`SET_ADDRESS`、`configuration descriptor malformed`、`no HID interface`、`no interrupt IN endpoint`、`SET_CONFIGURATION`、`SET_IDLE`、`report descriptor`、`not a gamepad` |
| **枚举成功但按键无效** | OR 仲裁进 `buttons1` 在仿真里已断言（非空），所以怀疑 **report 解析或 `GAMEPAD`(0x20) 寄存器写**；确认设备 HID report layout 与 `usb_hid.h` 的约定一致 |

---

## 9. 症状 → 原因 对照表

**本表是本文最有价值的部分。** 每行的"证据等级"用第 1 节的三个标记之一，末列给出不靠猜的下一步。

| # | 现象 | 先查（按顺序） | 指向 | 证据等级 | 下一步 |
|---|---|---|---|---|---|
| 1 | LCD 有画面，**HDMI 全黑 / 无信号** | HDMI 线缆与显示器输入源 → 换一台已知支持 480p 的显示器 → TMDS 引脚与第二个 MMCM | TMDS 差分对、第二个 MMCM（`u_mmcm_hdmi`）未 LOCK、或接收端不接受无 EDID 的固定模式 | **【从未运行】** HDMI 从未点亮任何显示器 | DDC/EDID **故意不做**（`tmds_scl`/`tmds_sda` = R19/P20 归触摸，顶层未声明端口）。720×480p60 是标准 CEA 应被接受，但输出**零条 `set_output_delay`**，连接器眼图未约束——**WNS 为正 ≠ 眼图有效** |
| 2 | **HDMI 有画面，LCD 全黑** | 用 v9 回退（拿掉 HDMI 变量） | 共享视频通路回归；这条通路本应逐字节未动 | **【仿真已验】** `nes_video_800x480` 被刻意保持逐字节未动 | v9 下 LCD 正常 → 是 HDMI 引入的回归；v9 下也坏 → 与 HDMI 无关 |
| 3 | **触摸 dpad 四方向仍全错** | 先问：画面对不对？ | 画面对、只有方向错 = **坐标帧问题**（校准没生效或退回编译期常量）；画面也错 = 视频链问题 | **【仿真已验】** 校准五场景 + 切口逐点归属（`touch-input-tb`）；**【从未运行】** 校准从未读过真实控制器 | 读只读诊断线 `touch_calib_ok`/`touch_x_max`/`touch_y_max`/`touch_x2y`；`touch_calib_ok=0` 说明回退。另注意点 1 地址假设 `16'h8150` vs `16'h8158` |
| 4 | **触摸 dpad 错，但 TPAD 正常** | 隔离到校准通路而非触摸总线 | 触摸校准路径（TPAD 走独立按键链，不受 dpad 影响） | 同第 3 行 | 同第 3 行；TPAD 正常说明 I2C 总线/按键链没坏 |
| 5 | **TPAD 什么都不做** | 先怀疑**极性** | TPAD 极性。按 vendor RTL（`touch_led.v` 上升沿=按下）实现为**高有效**，从未在硬件上确认 | **【仿真已验】** 替换与独立性回归；**【从未运行】** 真实 TPAD 极性 | **一行取反**（`touch_key` 极性）就是修法；一次只改这一行 |
| 6 | **SD 启动完全无 UART 输出** | boot-mode 选择器 → 卡格式 → FSBL | BootROM/FSBL 根本没启动，或 PL 未被编程 | **【从未运行】** 整条 PS 启动链从未执行 | 按第 4 节逐项确认；确认串口 115200 8N1 |
| 7 | **UART 显示 link check 失败**（`SCRATCH` 图案或 `ID ≠ 0x4E455301`） | 确认地址映射 `0x4120_0000` → 协议转换器 → PS 时钟/复位 | AXI 寄存器通路——**唯一有仿真覆盖**的部分 | **【仿真已验】** `axi-lite-regs-tb`（五通道握手/WSTRB/OKAY/GAMEPAD）、`cart-rom-load-tb`（AXI→bridge→数组） | 仿真过而板上不过 → 优先怀疑 PS 侧地址/协议/时钟，而不是寄存器逻辑本身 |
| 8 | **手柄识别不到**（`no device attached`） | **P4 "OTG SW" 跳线** → PS USB0 配置 | 跳线未置 host（四个 Type-A 口全死，**无软件绕过**），或 USB0 配置 | **【从未运行】** 无 USB 设备被连接、无枚举 | 先动跳线再动软件；这是唯一"没有软件绕过"的硬件前提 |
| 9 | **手柄枚举成功，但按键无效** | HID report layout 是否与 `usb_hid.h` 约定一致 → `GAMEPAD`(0x20) 寄存器写 | report 解析或寄存器写 | **【仿真已验】** `GP_BTN_AT_CORE`/`GP_OR_ARBITRATION`（`zynq-top-tb`）、host test 60 checks | 约定：`report[0]` bit0=A、bit1=B；`report[1]` bit0=Select、bit1=Start、bit4=Up、bit5=Down、bit6=Left、bit7=Right。设备不同则需补 layout |
| 10 | **JTAG 连不上 / PC 认不到板** | JTAG ribbon 插好没 → 换口/换线 | 物理连接 | —（这是上板前通用项） | 主板 USB 侧 enumerate 失败就是排线没插好的签名 |

---

## 10. 已知不确定的部分（不要当成"大概能行"）

以下几条是**最可能先失败**的地方，全部标为 **【从未运行】**；不要因为它们编译过了、时序 met 了就假定它们能跑：

- **`xusbps` 在本次 SDK 里似乎只有 device-mode。** 没有 `ConfigureHost`；host-mode 进入和 host 侧 device-address 处理是用**直接寄存器写**做的。这是**整条分支里最不确定的部分**。`XUsbPs_SetDeviceAddress()` 写的是 `0x154`，在 host 模式下那是 periodic-frame-list base，**不能调用**。
- **从未连接过任何 USB 设备**，从未枚举，从未见过任何设备的真实描述符或 HID report。
- **从未读取过任何 SD 卡**，loader 从未执行。
- **HDMI 从未点亮过显示器**，且 TMDS 输出**没有任何 `set_output_delay` 约束**——一个时序报告全绿的比特流，不是"连接器眼图有效"的证据。
- **触摸校准从未读过真实控制器。** 它是**照着寄存器文档写的，只对仿真控制器测过**；真实 GT9147 的点 1 寄存器地址（`16'h8150` vs `16'h8158`）是自校准**不覆盖**的假设。
- **TPAD 的高有效极性从未在硬件上确认**——它来自 vendor RTL 的上升沿语义。

---

## 11. 证据在哪里（让失败可以被诊断，而不是被猜）

| 证据 | 命令 / 位置 | 覆盖什么 |
|---|---|---|
| 仿真回归门禁 | `.\tools\sim_all.ps1 -Mode all`（**73 个目标**） | AXI 寄存器协议、卡带加载通路、OR 仲裁、触摸校准状态机、TMDS 编码/串行器 elaborate、第二个 MMCM 频率 |
| USB 解析 host test | `.\tools\ps\host_test\run_host_test.ps1` | 配置描述符走查、HID report 走查、report→NES 映射（60 checks，带非空计数器） |
| 构建脚本 | `tools\ps\`（`run_build.ps1`、`run_sdk.ps1`） | 块设计、比特流、FSBL、应用、`BOOT.bin` 的产生过程 |
| XDC 控制流陷阱表 | `docs/00-overview/vivado-runbook.md` 第 4 节 | `if`/`puts` 不能写进 XDC，否则约束被静默丢弃——这正是 gamepad 的 `set_max_delay` 一度放进 `if` 而 8 条端点失败的原因 |

**重要**：门禁全绿只证明**逻辑对**，不证明**板子对**（第 1 节）。本手册不把门禁绿灯当作上板前置条件的替代。

---

## 12. 现场记录表

每次上板至少记录（沿用 `10-board-validation.md` 第 2 节的字段）：

| 字段 | 内容 |
|---|---|
| 日期 / 执行人 | 实际执行者 |
| 板卡 / 器件 | 板卡版本、`xc7z020clg400-2` |
| 烧录产物 | 哪个 `.bit` / `BOOT.bin`，及其字节数与 SHA256 |
| 物理前提 | JTAG、SD 卡格式、`game.nes`、boot mode、P4 跳线是否逐项完成 |
| Stage | 1 / 2 / 3 / 4，以及是否通过 |
| 实际 | 画面照片、UART 日志、错误码（`USBGP_ERR_*` / loader 阶段行） |
| 结论 | 通过 / 失败 / 有条件通过 / 待复测 |

---

## 13. 与其他章节的关系

- HDMI 通路、第二个 MMCM、DDC/EDID 限制、零 `set_output_delay`：`docs/modules/hdmi-tx.md`。
- 触摸 dpad 自校准、切口映射、TPAD 替换与极性：`docs/modules/touch-input.md`。
- PS 运行时卡带加载的 PL 半（寄存器图、加载通路、CDC）：`docs/modules/ps-rom-load.md`。
- PS 半（块设计、FSBL、应用、`BOOT.bin`、链接自检）：`docs/modules/ps-rom-load-software.md`、`tools/ps/README.md`。
- USB HID 手柄（host 模式、失败阶段、OR 仲裁）：`docs/modules/ps-usb-gamepad.md`。
- Zynq 平台层（四时钟域）：`docs/modules/zynq-platform.md`。
- Vivado 操作与陷阱表、证据引用规范：`docs/00-overview/vivado-runbook.md`。
- 板级验收的通用做法与记录格式：`docs/hardware/10-board-validation.md`。

---

## 14. 本章结论

一句话记法：**先烧改动最小的 v10，让它在 JTAG 上单独证明 HDMI、触摸和 TPAD；只有画面真的亮了，才允许把 PS 启动链、SD 卡和 USB 引入进来。** 每一阶段失败时的排查范围，由上一阶段已经证明的东西界定——Stage 1 失败永远不查 PS。所有"西门子绿"都只是**【仿真已验】**，只有在板上看到的行为才配得上**【上板已验】**；本分支目前一个都还没有。
