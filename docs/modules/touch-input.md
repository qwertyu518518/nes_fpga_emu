# 电容触摸屏当 NES 手柄（GT9147 -> $4016）：从板厂寄存器图到触摸 dpad

本文说明 `rtl/nes_core/peripheral/nes_touch_input.v`（及同文件后半的 `nes_touch_i2c`）的接口合同、时序模型与设计取舍，回答一个和 `controller.md` 同源的教学问题：

> 一块只有电容屏、没有手柄接口的 Zynq 板子，怎么把一根手指变成 `$4016` 的 8 个位？

结论：**触摸屏在 RTL 里最终就是"一只 8 位并联手柄"。** `nes_controller.v` 只认 `buttons[7:0]`，不关心这 8 根线来自 4021 的物理触点还是电容控制器的 I2C 报点，所以不需要新的 CPU 侧协议。

三条分层的事实来源：

- 芯片行为（寄存器图、复位、报点格式、自检寄存器）来自 GT9147 手册/《GT9147 编程指南》与板厂驱动用法。
- 坐标帧与轴线方向来自控制器自己发布的只读寄存器（`16'h8048 / 16'h804A / 16'h804D`），**不是**板厂 pass-through。
- `$4016` 位序是 NESdev 的，本项目由 `docs/modules/controller.md` 复述。

板厂驱动只作观察、只读引用：

```text
...\17_top_lcd_touch\...\touch\touch_dri.v   GT 家族选择、寄存器图、有效解码、复位
...\17_top_lcd_touch\...\touch\i2c_dri_m.v   START / addr+W / addr16 / Sr / addr+R / data / STOP
...\17_top_lcd_touch\...\lcd\rd_id.v         4.3" 800x480 RGB 面板报 lcd_id 16'h4384
```

`[源码观察]` 只标记"板厂或克隆仓库这么写"，不是规格。证据入口：`tools/sim_all.ps1` 目标 `touch-input-tb`，顶层 `tb/peripheral/tb_nes_touch_input.v`。

---

## 1. 为什么"用触摸屏当手柄"成立

`controller.md` 3.1 把 `nes_controller.v` 的 `buttons` 定义成"1P 按钮位图，bit0..bit7 = A, B, Select, Start, Up, Down, Left, Right"，bit0 就是 `$4016` 第一次读出的那一位；它是一根**并联输入总线**，`nes_controller` 只负责串行化。`nes_touch_input.v` 的产物正是这根线：

```verilog
assign buttons = {touch_dpad, key_start, key_select, btn_b, btn_a};
assign dpad    = touch_dpad;              // touch_dpad[3:0] = {Up, Down, Left, Right}
```

所以"触摸屏 -> 手柄"只需把一次触摸归到某方向、把两个物理键归到某两个按钮，其余交给已有的 `nes_controller`；对 `$4016` 而言，屏幕上的手和插着的手柄不可区分。

位序合同（RTL 字面连线）：

| `buttons` 位 | 来源 | `$4016` 对应位 |
| --- | --- | --- |
| bit0 / bit1 | `btn_a` / `btn_b`（TPAD 未按时 = `key0` / `key1`） | A / B |
| bit2 / bit3 | `key_select` / `key_start`（TPAD 未按时恒 0） | Select / Start |
| bit4 | `touch_dpad[0]` = Right | Up |
| bit5 | `touch_dpad[1]` = Left | Down |
| bit6 | `touch_dpad[2]` = Down | Left |
| bit7 | `touch_dpad[3]` = Up | Right |

A/B/Select/Start 的次序与 `$4016` 一致。`[RTL 建议]` 四个方向位则不然：按上面的拼接式，`buttons[7:4]` 从高到低是 `{Up, Down, Left, Right}`，而 `$4016` 合同是 bit4=Up … bit7=Right，即高半字节相对 `$4016` 是**反的**。现有两个 tb 都用 dpad 自己的字面量比对（Left 判 `buttons[7:4]==4'b0010`），没有测试把这根线穿过 `nes_controller` 再按串行位反查，所以这条次序差异不会被门禁照出来；接真实游戏前必须先确认这一点。

---

## 2. 两个模块的分工

- **`nes_touch_input`（顶层）**知道 GT9147 在这块板上"是什么"：器件地址、状态/坐标寄存器、复位时序、自校准、区域映射、按键与 TPAD 语义；对总线只提"读/写一个字节、起停"这一层请求。
- **`nes_touch_i2c`（通用 I2C 主机）**只知道"什么"是 I2C：START / 重复 START / 数据位 / ACK / STOP / tBUF，一次一字节，**对 GT9147 一无所知**。

接口是电平请求 + 脉冲应答：`start/rep_start/cont/stop/tx_dir/tx_data/ack_out/sda_i` 进，`scl_o/sda_o/sda_oe` 与 `byte_done/byte_nack/stop_done/rx_data/busy` 出。`req_*` 由顶层按 `seq_q` 组合译码，**是电平**，保持到对应脉冲出现，请求不会和位引擎赛跑。`tx_dir=1` 写、`tx_dir=0` 读（采 `sda_i`）。`byte_nack` 在"写期待 ACK 却没拿到"或"读末字节应 NACK 却拿到 ACK"时拉高，顶层视其为本笔事务作废。

---

## 3. I2C 与 GT9147

### 3.1 总线三态约定

与 `wm8960_i2c.v` 完全相同的开漏约定：

```verilog
assign touch_scl   = touch_scl_o  ? 1'bz : 1'b0;   // scl_o: 0 拉低，1 释放
assign touch_sda   = touch_sda_oe ? touch_sda_o : 1'bz;
assign touch_sda_i = touch_sda;
```

`sda_oe` **只在发逻辑 0 时有效**，主机从不在任何线上灌高；逻辑 1 靠释放 SDA 来发，这样从机在 ACK 槽拉低时能压过外部上拉。

### 3.2 寄存器图

| 项 | 值 |
| --- | --- |
| I2C 从地址 | `7'h14`（`DEV_ADDR`），16 位寄存器指针（先高后低） |
| `16'h814E` 状态 / 触摸标志 | 1 字节。bit7 = 数据就绪，`status[3:0]` = 点数；有效 `status[7] && 1<=status[3:0]<=5`；写 `0x00` 清标志 |
| `16'h8150` 触摸点 1 坐标 | 4 字节，顺序 X 低、X 高、Y 低、Y 高 |
| 自检只读寄存器 | `16'h8048/49` X Max、`16'h804A/4B` Y Max（低字节在前）、`16'h804D` Module_Switch1（bit3 = X2Y） |
| 复位 | `ct_rst_n` 拉低 10 ms，释放，再过 50 ms 才第一次访问 |

`[源码观察]` GT 家族**不接受配置写入**，所以板厂那份 FT 专用寄存器表没有被搬进来。

### 3.3 一次正常 poll 与复位

顶层按固定顺序走一笔主事务加两笔子事务：**读状态**（START，`addr+W`，指针高/低，重复 START，`addr+R`，读 1 字节，STOP）→ **判定**（有效则 `touch_valid<=1` 并转坐标，否则 `touch_valid<=0` 直接清标志）→ **读坐标**（同样起停，连读 4 字节，前 3 ACK、末 NACK）→ **清标志**（START，`addr+W`，写 `16'h814E` 指针，写 `0x00`，STOP），然后 `poll_done<=1` 回等待态。I2C 位级时序在 `nes_touch_i2c` 内，每字节拆 4 个 quarter（`QTR = CLK_HZ/(4*I2C_HZ) = 50` 拍），SCL 高相位采 `sda_i`。

复位：`SQ_RST_LO` 把 `ct_rst_n` 保持 0 共 `CT_RST_LOW_CYCLES`（默认 500_000 拍 = 10 ms）；`SQ_RST_HI` 释放后再等 `CT_RST_WAIT_CYCLES`（2_500_000 = 50 ms），到点置 `init_done<=1`。之后**不**立刻 poll，而是先进自校准（第 4 节）；所以 `init_done` 的含义是"复位与 50 ms 等待结束、总线马上要被使用"，而不是"已读过面板数据"。

---

## 4. "坐标帧是问出来的"

### 4.1 为什么不能假设

文件头原写"GT 坐标按原样使用，不做轴交换"，这是从板厂的 GT 分支（本身是 pass-through）抄来的假设。但"板厂原样透传"**不能证明**总线上的帧就是代码假定的帧：板厂唯一的 FPGA 例子把两个数当数字打印，对一串数字来说转置的帧看起来完全正常。现场症状是：一块其他都正确的板子上，**屏幕触摸产生的 d-pad 四个方向全反**，而区域图几何上是对的——正是"坐标所在的帧和硬编码的帧不同"的签名。

### 4.2 怎么问、怎么回退

GT9147 上电自检模组参数并把结果发布在只读寄存器里。复位等待后，`nes_touch_input` 做**一次性校准**读回五字节：

- 三个自检寄存器地址是 **localparam 而非 parameter**（`CT_XMAX_REG/CT_YMAX_REG/CT_SWITCH_REG`）——帧是读出来的而不是选出来的，没有留给构建去改的地方；`tb_nes_touch_input` 硬编码同样三个值并断言驱动读的正是它们，写错地址会是失败的 bench 而不是静默错址。
- 校准复用**同一段**"读字节块"序列，由 `cal_step_q`（0=X max，1=Y max，2=Switch1）选指针/字节数/ACK 图样；多字节读里"末字节 NACK"最容易写错，故 `cal_rx_ack = cal_two_bytes & (cal_idx_q==0)` 同时充当"还有下一字节"的标志。
- 读完后在 `SQ_CAL_DONE` 做**唯一的一次算术**：`x_max>>2`、`x_max-(x_max>>2)`、`y_max>>1`，写进三个寄存器；此后区域映射只读它们当常量，**每帧无算术**。X2Y 的轴交换在末字节到达时用两个 16 位 2:1 mux 对调两个字（`touch_x <= x2y ? y_raw : x_raw`），取数序列因此保持"只有一种字节顺序"。

`touch_calib_ok` **只在**校准读全部完成 **且** 结果可用时为 1。三类失败都退回编译期常量：任一读被 NACK；总线卡高（`x/y_max==16'hFFFF` 或高字节 `8'hFF`，或 `mod_switch==8'hFF`，即"从机在 ACK 却从不驱动 SDA"）；退化值（`x/y_max==0`，按面值会把两条水平切口都放到 0，把每次触摸都送成 Right）。回退时三切口保持 `PANEL_W/PANEL_H` 的分数（默认 200/600/240），`x2y` 强置 0。**失败校准的行为 == 校准存在之前**，不会更差；失败**不**拉 `touch_error`（有意吸收，只由 `touch_calib_ok` 报告）。`touch_x_max / touch_y_max / touch_x2y` 是只读诊断线，"存在是为了被看"。

---

## 5. 区域映射

`region` 是 `(x, y)` 的**全函数**，五区域互斥且覆盖整个平面：

```verilog
wire region_left   = (touch_x_q <  x_left_edge_q);
wire region_right  = (touch_x_q >= x_right_edge_q);
wire region_middle = ~region_left & ~region_right;
wire region_upper  = (touch_y_q <  y_mid_edge_q);
wire [3:0] touch_dpad = {touch_valid_q & region_middle &  region_upper,  // Up
                         touch_valid_q & region_middle & ~region_upper,  // Down
                         touch_valid_q & region_left,                    // Left
                         touch_valid_q & region_right};                  // Right
```

边界归属被钉死，tb 逐点断言：

| 位置 | 归属 | 依据 |
| --- | --- | --- |
| `x == X_LEFT_EDGE` | 中带（不是 Left） | 左切口是中带的第一个像素 |
| `x == X_RIGHT_EDGE` | Right | 右切口是 Right 的第一个像素 |
| `y == Y_MID_EDGE` | Down（不是 Up） | 中切口是 Down 的第一个像素 |

没有 `(x, y)` 落在五区域之外，越界坐标也归到三者之一。比较只读三个寄存器、无逐帧算术——这就是把乘法和移位只做一次的全部意义。`touch_valid_q` 与门把关：无有效触摸时 `touch_dpad` 恒 0。

---

## 6. 按键与 TPAD 的 Start/Select 替换

两个低有效 PL 键 `key0/key1` 与高有效的板载 TPAD `touch_key` 走同一条 2 级同步 + 消抖链，空闲向量 `3'b011`（两键空闲高、TPAD 空闲低）：

```verilog
wire ab_substituted = key_stable_q[2];        // 板载 TPAD，高有效
wire key_start  = ab_substituted & ~key_stable_q[0];
wire key_select = ab_substituted & ~key_stable_q[1];
wire btn_a      = ~ab_substituted & ~key_stable_q[0];
wire btn_b      = ~ab_substituted & ~key_stable_q[1];
```

规律：**按住 TPAD 时 `key0 -> Start`、`key1 -> Select`；否则 `key0 -> A`、`key1 -> B`**（这两对按钮不会同时需要）。`[RTL 建议]` 替换使能**必须**取自 TPAD 而不是 `touch_valid`：旧写法用 `touch_valid_q` 门控，导致"用屏幕转向"会让两个键变成 Start/Select，转向与开火互斥，这是板上实测到的缺陷。`tb_nes_touch_input` 把它独立成回归：报告一次触摸期间两键已按下，必须**仍是** A/B（`buttons==8'h23` 而非旧 RTL 的 `8'h2c`），只有 TPAD 才提升为 Start/Select；TPAD 与屏幕 dpad 互相独立。

---

## 7. 端口 / 参数合同表

| 信号 | 方向 | 合同 |
| --- | --- | --- |
| `clk` / `reset` | in | 系统时钟（Zynq 接 `sys_clk` = 50 MHz）；高有效**异步**复位。单时钟域、无 `ce`。 |
| `ct_int` / `ct_rst_n` | in / out | GT9147 中断，**低有效**，`USE_CT_INT` 非零时可在一次成功 poll 后提前唤醒；面板复位，低有效（时序见 3.3）。 |
| `scl_o` / `sda_o` / `sda_oe` / `sda_i` | out / in | 开漏 I2C 四件套（约定见 3.1）。 |
| `key0` / `key1` / `touch_key` | in | 两个 PL 键（低有效）与板载 TPAD（高有效）。 |
| `buttons[7:0]` / `dpad[3:0]` | out | 喂 `nes_controller` 的位图（位序见第 1 节）与触摸方向 `{Up,Down,Left,Right}`。 |
| `touch_valid` / `touch_x` / `touch_y` / `init_done` / `touch_error` / `bus_busy` / `poll_done` | out | 最近有效报点与坐标 / 复位等待结束 / 出错后保持 / I2C 忙 / 一拍 poll 完成脉冲。 |
| `touch_x_max` / `touch_y_max` / `touch_x2y` / `touch_x_left_edge` / `touch_x_right_edge` / `touch_y_mid_edge` / `touch_calib_ok` | out | 自校准只读诊断结果（见 4.2）。 |

关键参数（默认）：`CLK_HZ=50_000_000`、`I2C_HZ=250_000`、`DEV_ADDR=7'h14`、`CT_STATUS_REG=16'h814E`、`CT_COORD_REG=16'h8150`、`PANEL_W=800`、`PANEL_H=480`、`EDGE_L=1/4`、`EDGE_R=3/4`、`MID=1/2`、`DEBOUNCE_CYCLES=800`、`CT_RST_LOW_CYCLES=500_000`、`CT_RST_WAIT_CYCLES=2_500_000`、`POLL_CYCLES=1_000_000`、`USE_CT_INT=1`。`CT_COORD_REG` 是"点 1 坐标在哪个寄存器"的诊断旋钮，默认 `16'h8150`，未来可重指向 `16'h8158`（见第 10 节）。

---

## 8. 时序账

| 量 | 默认 | @50 MHz | 说明 |
| --- | --- | --- | --- |
| I2C quarter `QTR` | `50_000_000/(4*250_000)=50` clk | 1 µs | 满周期 4 µs = 250 kHz |
| 复位保持 `CT_RST_LOW_CYCLES` | 500_000 clk | 10 ms | `ct_rst_n` 拉低 |
| 复位后等待 `CT_RST_WAIT_CYCLES` | 2_500_000 clk | 50 ms | 释放到首次访问之间 |
| 消抖 `DEBOUNCE_CYCLES` | 800 clk | 16 µs | 三级共用一个窗口 |
| 轮询周期 `POLL_CYCLES` | 1_000_000 clk | 20 ms | 约 50 次/秒；`ct_int` 可提前唤醒 |

一次 poll 的长度 = 状态读（+ 可能的坐标读）+ 清标志三笔事务的字节数与起停开销之和。tb 把 `POLL_CYCLES` 覆盖成 `10_000`（200 µs）加快仿真，不改变协议形状。**消抖**：`key_sync_q` 与候选不等就累加 `key_cnt_q`，达到阈值才提升为新的稳定值；窗口短于 `DEBOUNCE` 的脉冲**既不**产生 A/B/Start/Select，也**不**被锁存，tb 对 `key0` 和 TPAD 都断言了这一点。

---

## 9. 平台接线（Zynq）

`nes_touch_input` 目前**只在 Zynq 平台被例化**（`nes_zynq_top.v` 里的 `u_touch`）：挂 `sys_clk` = 50 MHz / `rst_sys` 域，`touch_scl/touch_sda/touch_rst_n/touch_int` 直接是板级引脚，`key0/key1` 接 PL 键，`touch_key` 接 F16 的板载 TPAD。它的 `buttons` 输出在 `sys_clk` 域，而 `nes_system_v6` 跑 `core_clk`（21.477 MHz），两者之间是**唯一的手柄跨域路径**——`sys_clk -> core_clk` 的 2 级同步器：

```verilog
(* ASYNC_REG = "TRUE" *) reg [7:0] btn_meta_q, btn_sync_q;
always @(posedge mmcm_core_clk or negedge sys_rst_n)
    if (!sys_rst_n) begin btn_meta_q <= 8'h00; btn_sync_q <= 8'h00; end
    else            begin btn_meta_q <= touch_buttons; btn_sync_q <= btn_meta_q; end
```

`btn_sync_q` 直接接 `nes_system_v6.buttons1`；`ASYNC_REG` 让两级相邻，XDC 用 `set_max_delay -datapath_only` 给这条路径设界。校准结果 `touch_x_max/...` 在平台里是**没有消费者**的 wire，且刻意不引出为端口——不新增引脚、不改 45 脚的数，Vivado 会在综合时把未连接网折掉，这正是期望结果。

---

## 10. 明确未实现 / 未建模

- **只在 Zynq 平台存在**：EP4CE10 开拓者板没有 GT9147，本模块在该平台**没有被例化**，也没有综合/时序证据；它只有仿真门禁（`tools/sim_all.ps1` 目标 `touch-input-tb`，顶层 `tb_nes_touch_input`，标准 2001）。
- **点 1 地址假设**：`16'h8150` 是固件 1030 以前的点 1，1030+ 上点 1 可能在 `16'h8158`。本模块**没有**处理这个假设，取数固定在 `CT_COORD_REG`，只能靠把该 parameter 重指向来适配（平台顶层已把它透传成诊断旋钮）。这是自校准**不覆盖**的那条关于坏 d-pad 的假设。
- **多点 / 手势 / 滑动未建模**：状态允许点数到 5，但只读点 1 的四字节；多点、手势、滑动、长按，以及"整帧转置"以外的帧畸变（镜翻转、斜置）一律不处理。
- **`ct_int` 唤醒语义**：早唤醒要求此前至少完成过一次成功 poll（`poll_ok_q`）且 `ct_int` 低有效；中断极性、去毛刺不深究，只做 2 级同步。
- **开漏电气只靠约定**：模块只保证 `sda_oe` 只在发 0 时为 1、从不灌高；上拉、总线电容、速率裕量属于板级。
- **高半字节位序未被门禁照到**：见第 1 节的观察——四个方向位相对 `$4016` 的次序差异没有任何测试端到端验证过；**也没有用真实 `nes_cpu_bus` 驱动、没有和 PPU 的 sprite 0 hit 联通、平台里没有任何消费者**。

---

## 证据

- `tb/peripheral/tb_nes_touch_input.v`：行为级 GT9147 I2C 从机模型，逐字节跑同一取数路径；断言含器件地址 `7'h14`、`16'h814E` 清标志写 `0x00`、`16'h8150` 的 4 字节坐标读、五场景自校准（799×479 X2Y 清 / 1023×639 X2Y 置证坐标对调 / 479×271 = ATK-4342 / 校准读全 NACK / 全 1 卡高）、三个自检寄存器的地址/方向/字节数（各恰好一次）、区域映射三条切口的逐点归属、按键与 TPAD 消抖及 Start/Select 替换回归、复位 `ct_rst_n` 低 10 ms 且 50 ms 内不起事务、开漏物理层（无人灌高、SDA 只在 SCL 低时变、tBUF 满足）。结尾的**非空断言**要求至少一个场景的切口不同于编译期常量（否则分不清"校准生效"和"回退"），并要求五场景共 12 次成功校准读。
- `tools/sim_all.ps1`：目标 id `touch-input-tb`，`peripheral` 组，`Standard = 2001`，`Run = $true`。模块没有该目标就等于没有回归保护。
