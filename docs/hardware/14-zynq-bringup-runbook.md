# 14 Zynq 上板 bring-up 手册：四个产物的分阶段点亮顺序与症状归因

## 0. 本文要解决的问题

`feature/ps-peripherals-hdmi-usb-sd` 上有 **11 个提交**（`master..HEAD`），它们给 `nes_zynq_top` 加了 HDMI、触摸 dpad 自校准、TPAD 的 A/B↔Start/Select 替换、PS 侧运行时卡带加载和 USB HID 手柄。**这些改动没有一个字节在真实板子上运行过。** 手上只有四个产物和五件要验的事，而且它们的**置信度并不相同**。

没有顺序的话，人的本能是先把最"完整"的产物——`BOOT.bin`——烧进去，因为它是 FSBL + 应用 + 比特流三合一。这恰好是最坏的选择：它失败时，失败点在**五个子系统和一条从未执行的启动链**之间不可分辨。

本文的价值只有一个：**把测试排成一条链，让每一阶段的失败都能收敛到一个受限的原因，并把观察到的症状映射到它指向的子系统。** 本文是操作手册，不是实现说明；每个模块的接口合同与证据见第 13 节的交叉引用，本文不重述。

> **本文不含**：任何 RTL 改动、任何构建、任何硬件访问。所有"做什么"都是给人执行的现场指令。

---

## 1. 证据标记（先读这一节）

本分支最危险的一件事，是把**仿真门禁的绿灯**读成**板子能跑**。`.\tools\sim_all.ps1 -Mode all` 现在是 74/74 全过，但仿真里没有一个真实 GT9147、没有一个 USB 设备、没有一张 SD 卡、没有一个显示器。为了让这两种状态无法被混读，本文每条关于行为的断言都只带以下三个标记之一，**不留空**：

| 标记 | 含义 | 现在属于它的东西 |
|---|---|---|
| **【仿真已验】** | 有可复现的仿真门禁或 host test 证据，附目标 id / 命令；**不等于上板可用** | AXI 寄存器协议、卡带加载通路、OR 仲裁、触摸校准状态机、TMDS 编码、第二个 MMCM 频率 |
| **【从未运行】** | 从未在任何硬件上执行过，没有任何证据 | HDMI 输出、PS boot chain、SD 读、USB 枚举、真实 TPAD 极性 |
| **【上板已验】** | 已在真实板上观察到 | **触摸 dpad 位序反了导致四方向全错**（按上却向右，等四向错位）与**空 poll 被判为抬手导致玩家移动断续**（敌人正常）——两条都是**故障**被观察到；对应修复只在仿真里验证过并已烧写，**修复后的上板结果尚未回报**（见第 9 节第 3 行、`docs/modules/touch-input.md` 第 11 节） |

三个标记是 `docs/hardware/` 既有证据等级（`【已确认事实】`/`【待上板验证】`/`【风险提示】`）在"这条行为到底跑过没有"上的细化。看到 **【仿真已验】** 时，正确读法是"**逻辑对**"，不是"**板子对**"。

这套刻度还有一类它单独防不住的失败，本分支真实发生过：**门禁的绿灯有时连"逻辑对"都要限定是相对于谁。** 若一个 tb 用**被测模块自己的输出**去对照**按同一种约定写下的期望**，它只能证明模块内部自洽，照不出这个约定在**消费者边界**上是错的。`nes_touch_input` 曾把 dpad 拼成 `{Up,Down,Left,Right}` 接到 `buttons[7:4]`，而 `$4016` 合同是 bit4=Up…bit7=Right，于是四个方向全部落错位；`touch-input-tb` 一直用 `dpad` 自己的字面量比对，**74/74 全绿也照不出它**，直到真板上"坦克朝右走"才暴露。可复用的规则与复盘见 `docs/modules/touch-input.md` 第 11 节、第 9 节第 3 行，以及 `docs/00-overview/verification-plan.md` 第 7.2 节的对应条目。

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

开工之前逐项打勾。这几项中有**任何一项没做，后面的排查都会指向错误的方向**。注意后面几项**按阶段**成立，不是一开始就全部就位：

- [ ] **JTAG ribbon 插到底、卡扣扣好。** 它反复是"能不能 enumerate"与"根本连不上"的差别；**主板 USB 侧 enumerate 失败就是这个签名**——先怀疑排线，不要先怀疑 bitstream。
- [ ] **串口接好，115200 8N1**（UART0，MIO 14/15）。
- [ ] **P4 "OTG SW" 跳线置 host**（仅 Stage 4 需要）。四个 Type-A 口只在 host routing 下带电；**没有软件绕过**。
- [ ] **选择器与卡槽按阶段分开，不能一上来就都置好：**
      - **Stage 1 = boot-mode 置 JTAG、卡槽为空、不接 HDMI 线。** 此时 PS 完全不参与，BootROM 干净地等 JTAG，上电状态没有歧义。
      - **Stage 3 = boot-mode 才置 SD、并把卡插入。** 只有到这一步两者才就位。
      在 SD 模式下空卡上电，BootROM 会重试/回退而不是干净地等 JTAG——这正是"照前置清单做、再做 Stage 1"会得到的含糊上电；反过来，JTAG 模式下插着卡上电会让人误以为 Stage 1 和 PS 有关。两者都会把 Stage 1 的失败引向错误方向。
- [ ] **（Stage 3 前置）SD 卡是 FAT32**（不是 exFAT、不是 NTFS），`tools\ps\BOOT.bin` 放在**根目录**。
- [ ] **（Stage 3 前置）卡带镜像命名为 `0:/game.nes`**（根目录、小写 `game.nes`）。loader 打开的就是这个路径。
- [ ] 已知并接受一条板级事实：DDC/EDID **故意不做**——`tmds_scl`/`tmds_sda` 在板上是 R19/P20，而**这一对引脚与触摸 I2C 共用**（见 XDC 的 CONFLICT 块），顶层没有声明这两个端口。不要指望设计去读 EDID。**也正因如此，HDMI 线在 Stage 1 的后半段才接**，见下一节。

---

## 5. Stage 1 — JTAG 烧 v10（PL-only）

### 做什么（1a：先不接 HDMI 线）

用 JTAG 把 `D:\vivadoProject\zynq_bitstream_v10\nes_zynq_top_a_default.bit` 编程进 PL。**boot-mode 选择器置 JTAG、不插 SD 卡、不接 HDMI 线、不接 USB。**

先**在不接 HDMI 线**的状态下验证 LCD 与触摸，让"触摸是否可用"有一个干净的基线：

- **LCD 出画面**（不是白屏、不是花屏）；NES 画面几何稳定。
- **触摸 dpad 四方向正确**：在屏幕上按左/右/上/下，NES 里方向正确。这条判据同时压在**位序**（`buttons[7:4]` 与 `$4016` 一致）和**坐标帧**（自校准是否读对）两处；方向全错时**先查位序**再怀疑坐标帧，两者都能造成同样的现象（见第 9 节第 3 行）。
- **TPAD 替换正确**：按住板载 TPAD 时，`key0`→**Start**、`key1`→**Select**；不按 TPAD 时，`key0`→**A**、`key1`→**B**。

### 做什么（1b：再接 HDMI 线，然后重新确认触摸）

1a 通过后，**才**把 HDMI 线接到**已知支持 720×480p60 的显示器**，显示器输入源切到对应口，然后：

- **HDMI 出画面**：同一帧内容出现在 HDMI 显示器上。
- **触摸仍然正确**：把 1a 里的四方向测试**再按一遍**，必须仍然全对。
- **TPAD 仍然正确**。

**为什么必须是这个顺序：** HDMI 的 DDC 脚（`tmds_scl`/`tmds_sda`）与触摸 I2C（`touch_scl`/`touch_sda`）在板上是 **R19/P20 同一对物理引脚**（XDC 的 CONFLICT 块）。显示器端的 DDC/EDID 是 **5 V 标准**、带自己的上拉，插上来就把显示器的 EDID EEPROM 与 5 V 上拉挂到了 3.3 V 的触摸总线上。所以"接上 HDMI 后触摸坏"完全可能是这根线造成的，**不是**校准或坐标帧的问题。先测无 HDMI 的基线、再接线上重复触摸，才能把这两者区分开。

### 失败怎么办

按第 9 节症状表分流。三条独立判据（画面、触摸、TPAD）可以两两组合，这正是 Stage 1 能"一句话定位"的根据：

- 画面坏（1a）→ 视频通路（LCD 侧），见症状表第 2 行。
- 画面好、触摸方向坏且**在 1a 就坏** → 先查位序，再查触摸校准/坐标帧，见第 3、4 行。
- 触摸好、TPAD 坏 → TPAD 极性，见第 5 行。
- 只有 HDMI 坏（1b）→ 见第 1 行，并用 Stage 2 的 v9 把它拿掉。
- **1a 触摸好、1b 接上 HDMI 线后触摸变坏 → 见第 3b 行：先怀疑共用引脚，不要先去查校准或坐标帧。**

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
2. boot-mode 选择器**从 Stage 1 的 JTAG 改置 SD**，并插入刚才准备好的卡。（Stage 1 是 **JTAG + 空卡**；到 Stage 3 这一步，选择器和卡才第一次就位。）
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
| **`no device attached (port reset failed)`，完全没枚举** | **P4 跳线**必须 host；其次 PS USB0 配置（reset 现按 vendor 参考设计配在 MIO 9，见第 10 节）。跳线没设时四个口全死，**无软件绕过** |
| **停在某个 `USBGP_ERR_*` 阶段** | 那个阶段名就是修法：`controller lookup/init`、`endpoint/DMA config`、`device descriptor malformed`、`SET_ADDRESS`、`configuration descriptor malformed`、`no HID interface`、`no interrupt IN endpoint`、`SET_CONFIGURATION`、`SET_IDLE`、`report descriptor`、`not a gamepad` |
| **枚举成功但按键无效** | OR 仲裁进 `buttons1` 在仿真里已断言（非空），所以怀疑 **report 解析或 `GAMEPAD`(0x20) 寄存器写**；确认设备 HID report layout 与 `usb_hid.h` 的约定一致 |

---

## 9. 症状 → 原因 对照表

**本表是本文最有价值的部分。** 每行的"证据等级"用第 1 节的三个标记之一，末列给出不靠猜的下一步。

| # | 现象 | 先查（按顺序） | 指向 | 证据等级 | 下一步 |
|---|---|---|---|---|---|
| 1 | LCD 有画面，**HDMI 全黑 / 无信号** | HDMI 线缆与显示器输入源 → 换一台已知支持 480p 的显示器 → TMDS 引脚与第二个 MMCM | TMDS 差分对、第二个 MMCM（`u_mmcm_hdmi`）未 LOCK、或接收端不接受无 EDID 的固定模式 | **【从未运行】** HDMI 从未点亮任何显示器 | DDC/EDID **故意不做**（`tmds_scl`/`tmds_sda` = R19/P20 归触摸，顶层未声明端口）。720×480p60 是标准 CEA 应被接受，但输出**零条 `set_output_delay`**，连接器眼图未约束——**WNS 为正 ≠ 眼图有效** |
| 2 | **HDMI 有画面，LCD 全黑** | 用 v9 回退（拿掉 HDMI 变量） | 共享视频通路回归；这条通路本应逐字节未动 | **【仿真已验】** `nes_video_800x480` 被刻意保持逐字节未动 | v9 下 LCD 正常 → 是 HDMI 引入的回归；v9 下也坏 → 与 HDMI 无关 |
| 3 | **触摸 dpad 四方向全错（或整体错位）** | Ⅰ. **位序**：`buttons[7:4]` 的拼接顺序是否就是 `$4016` 合同（`nes_controller.v` 的移出顺序；bit4=Up、[5]=Down、[6]=Left、[7]=Right）→ Ⅱ. 再问：画面对不对？ | Ⅰ. 位序反了 = `nes_touch_input.v` 把方向向量拼成了 `{Up,Down,Left,Right}` 之类，与 `$4016` 相反（**本分支就是这样**：up→Right、right→Up、left→Down、down→Left，四向全部错位）→ Ⅱ. 画面对、位序也对、只有方向错 = **坐标帧问题**（校准没生效或退回编译期常量）→ Ⅲ. 画面也错 = 视频链问题 | **【上板已验】** 位序反了会让四向全部错位，已在真板上逐方向观察到（映射见"指向"列）；**【仿真已验】** 校准五场景 + 切口逐点归属（`touch-input-tb`），但该 tb 当时拿 `dpad` 自己的字面量自证，**照不出位序**；**【从未运行】** 校准结果从未在硬件上单独核对 | 位序：把向量绑到**消费者**的定义上（`nes_controller.v` 的 `$4016` 移出顺序 A,B,Select,Start,Up,Down,Left,Right），不要用 `nes_touch_input` 自己的 `dpad` 输出自证；复盘见 `docs/modules/touch-input.md` 第 11 节。坐标帧：读只读诊断线 `touch_calib_ok`/`touch_x_max`/`touch_y_max`/`touch_x2y`；`touch_calib_ok=0` 说明回退。另注意点 1 地址假设 `16'h8150` vs `16'h8158` |
| 3b | **1a 触摸好、接上 HDMI 线后触摸变坏**（拔线后恢复） | 先拔掉 HDMI 线重测触摸 | **R19/P20 是触摸 I2C 与 HDMI DDC 的同一对物理引脚**；显示器端 DDC 的 5 V 上拉与 EDID EEPROM 挂到了 3.3 V 触摸总线 | **【从未运行】** 无显示器接入过 | **不是校准/坐标帧问题**，不要先去改 `touch_calib_ok`/坐标帧。保持 HDMI 与触摸不同时使用，或把触摸改到面板连接器/PS I2C（板级决定，见 XDC 的 CONFLICT 块） |
| 4 | **触摸 dpad 错，但 TPAD 正常** | 先查位序（第 3 行 Ⅰ）→ 再隔离到校准通路而非触摸总线 | 位序反了（最可能，见第 3 行 Ⅰ：TPAD 走独立按键链，位序反不影响它）；位序对则为触摸校准路径 | 同第 3 行 | 同第 3 行；TPAD 正常说明 I2C 总线/按键链没坏，不等于坐标帧就是坏的 |
| 5 | **TPAD 什么都不做** | 先怀疑**极性** | TPAD 极性。按 vendor RTL（`touch_led.v` 上升沿=按下）实现为**高有效**，从未在硬件上确认 | **【仿真已验】** 替换与独立性回归；**【从未运行】** 真实 TPAD 极性 | **一行取反**（`touch_key` 极性）就是修法；一次只改这一行 |
| 6 | **SD 启动完全无 UART 输出** | boot-mode 选择器 → 卡格式 → FSBL | BootROM/FSBL 根本没启动，或 PL 未被编程 | **【从未运行】** 整条 PS 启动链从未执行 | 按第 4 节逐项确认；确认串口 115200 8N1 |
| 7 | **UART 显示 link check 失败**（`SCRATCH` 图案或 `ID ≠ 0x4E455301`） | 确认地址映射 `0x4120_0000` → 协议转换器 → PS 时钟/复位 | AXI 寄存器通路——**唯一有仿真覆盖**的部分 | **【仿真已验】** `axi-lite-regs-tb`（五通道握手/WSTRB/OKAY/GAMEPAD）、`cart-rom-load-tb`（AXI→bridge→数组） | 仿真过而板上不过 → 优先怀疑 PS 侧地址/协议/时钟，而不是寄存器逻辑本身 |
| 8 | **手柄识别不到**（`no device attached`） | **P4 "OTG SW" 跳线** → PS USB0 配置 | 跳线未置 host（四个 Type-A 口全死，**无软件绕过**），或 USB0 配置 | **【从未运行】** 无 USB 设备被连接、无枚举 | 先动跳线再动软件；这是唯一"没有软件绕过"的硬件前提 |
| 9 | **手柄枚举成功，但按键无效** | HID report layout 是否与 `usb_hid.h` 约定一致 → `GAMEPAD`(0x20) 寄存器写（并确认 report 带 Report ID 时偏移已按 1 传入） | report 解析或寄存器写 | **【仿真已验】** `GP_BTN_AT_CORE`/`GP_OR_ARBITRATION`（`zynq-top-tb`）、host test 74 checks（含 report-ID 偏移用例） | 约定（在任一 Report ID **之后**）：byte0 bit0=A、bit1=B；byte1 bit0=Select、bit1=Start、bit4=Up、bit5=Down、bit6=Left、bit7=Right。此约定**不匹配多数真实 Xbox 风格手柄**（它们低位字节是摇杆轴、按键在后面的 16 位字段），所以"枚举成功但按键无效/全是错键"多半是 **layout 假设不符，不是接线故障**；需按该设备真实 report layout 补映射 |
| 10 | **JTAG 连不上 / PC 认不到板** | JTAG ribbon 插好没 → 换口/换线 | 物理连接 | —（这是上板前通用项） | 主板 USB 侧 enumerate 失败就是排线没插好的签名 |

---

## 10. 已知不确定的部分（不要当成"大概能行"）

以下几条是**最可能先失败**的地方，全部标为 **【从未运行】**；不要因为它们编译过了、时序 met 了就假定它们能跑：

- **`xusbps` 在本次 SDK 里似乎只有 device-mode。** 没有 `ConfigureHost`；host-mode 进入和 host 侧 device-address 处理是用**直接寄存器写**做的。这是**整条分支里最不确定的部分**。`XUsbPs_SetDeviceAddress()` 写的是 `0x154`，在 host 模式下那是 periodic-frame-list base，**不能调用**。
- **USB0 PHY reset 按 vendor 参考设计配置（MIO 9），但从未构建或运行验证过。** vendor 配置里 USB0 reset 原本停在 disabled 占位值（`USB0_RESET_ENABLE=0`、`RESET_IO=<Select>`）；本分支把它改成这块板的 vendor 参考设计值（`PCW_USB0_RESET_ENABLE=1`、`RESET_IO=MIO 9`、`PCW_USB_RESET_ENABLE=1`、`PCW_USB_RESET_POLARITY=Active Low`、`PCW_USB_RESET_SELECT=Share reset pin`），**provenance 写在 `tools\ps\build_ps.tcl` 的 override 注释里**（来自 `ZYNQ_7020_PYNQ.zip` 的 `base` 设计）。这些值**未在 Vivado 里重建验证过**（只改了配置 TCL），也从未在板上生效过。
- **从未连接过任何 USB 设备**，从未枚举，从未见过任何设备的真实描述符或 HID report。
- **从未读取过任何 SD 卡**，loader 从未执行。
- **HDMI 从未点亮过显示器**，且 TMDS 输出**没有任何 `set_output_delay` 约束**——一个时序报告全绿的比特流，不是"连接器眼图有效"的证据。
- **触摸校准结果从未在硬件上单独核对。** 它是**照着寄存器文档写的，只对仿真控制器测过**；真板上一个只读诊断构建证明了**原始坐标与手指位置一致**（取数寄存器与坐标帧在本板成立），但校准读回来的三个量（`touch_x_max`/`touch_y_max`/`touch_x2y`）与点 1 地址的 `16'h8158` 分支从未在硬件上读出核对。
- **TPAD 的高有效极性从未在硬件上确认**——它来自 vendor RTL 的上升沿语义。

---

## 11. 证据在哪里（让失败可以被诊断，而不是被猜）

| 证据 | 命令 / 位置 | 覆盖什么 |
|---|---|---|
| 仿真回归门禁 | `.\tools\sim_all.ps1 -Mode all`（**74 个目标**） | AXI 寄存器协议、卡带加载通路、OR 仲裁、触摸校准状态机、TMDS 编码/串行器 elaborate、第二个 MMCM 频率、HDMI scaler 的 core→27 MHz 双时钟写读交叉（`video-hdmi-dc-tb`） |
| USB 解析 host test | `.\tools\ps\host_test\run_host_test.ps1` | 配置描述符走查、HID report 走查、report→NES 映射（74 checks，带非空计数器） |
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

一句话记法：**先烧改动最小的 v10，让它在 JTAG 上单独证明 HDMI、触摸和 TPAD；只有画面真的亮了，才允许把 PS 启动链、SD 卡和 USB 引入进来。** 每一阶段失败时的排查范围，由上一阶段已经证明的东西界定——Stage 1 失败永远不查 PS。所有"西门子绿"都只是**【仿真已验】**，只有在板上看到的行为才配得上**【上板已验】**；本分支现有两个**【上板已验】**，但两条都是**故障本身**（触摸 dpad 位序反了、空 poll 被判为抬手），其修复只在仿真里验证过并已烧写，**修复后的上板结果尚未回报**。
