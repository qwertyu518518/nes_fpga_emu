# 56 触摸屏精读：`nes_touch_input.v`（电容屏 → NES 手柄）

前面 [`20-controller.md`](20-controller.md) 讲了 `nes_controller.v` 怎么把一根 **8 位并联手柄** 串行化成 `$4016` 的位流。这一篇讲那 8 根线**从哪来**：一块只有电容触摸屏、没有手柄口的板子，怎么把一根手指变成 `buttons[7:0]`。

- 源码：[`rtl/nes_core/peripheral/nes_touch_input.v`](../../rtl/nes_core/peripheral/nes_touch_input.v)（约 1054 行，本目录最长的一篇；文件里含两个模块）
- 合同与证据：[`../modules/touch-input.md`](../modules/touch-input.md)
- 测试目标：`touch-input-tb`（见 [`tb/peripheral/tb_nes_touch_input.v`](../../tb/peripheral/tb_nes_touch_input.v)）
- 前置：先读 [`20-controller.md`](20-controller.md)（`buttons[7:0]` 位序合同）和 [`21-cdc-fifo.md`](21-cdc-fifo.md)（两级同步器）。

> 这一篇**不逐行讲完**。目标是讲透"输入 → 坐标 → 方向/按键 → `buttons`"这条链；I2C 位级时序、校准的逐字节细节只需要知道**去哪查**。

---

## 1. 先认识"上游和下游"

```text
手指               GT9147 电容控制器              本模块（单时钟域 sys_clk）
 │ 触摸电容变化   ──►  │  I2C 从机 7'h14          ──►  │  nes_touch_input
 │                     │  状态 16'h814E                │    ├─ 复位 / 轮询状态机
 │                     │  坐标 16'h8150                │    ├─ 一次性自校准
 │                     │  自检 16'h8048/4A/4D          │    ├─ 区域映射
 │                     │                               │    └─ 按键同步+消抖
 └─ PL 键 / TPAD ───────────────────────────────────►  │
                                                       ▼
                              buttons[7:0] ──►（平台层两级同步）──► nes_controller ──► $4016
```

- **上游**：GT9147 是 I2C 从机（从地址 `7'h14`），本模块是主机；另外三个离散输入是 `key0`/`key1`（低有效的 PL 键）和 `touch_key`（板载 TPAD，高有效）。
- **本模块**：轮询触摸控制器，把最近一次报点归到某个方向，把按键归到 A/B/Start/Select，最后拼成一根 8 位并联手柄线。
- **下游**：`buttons` 在 `sys_clk`（50 MHz）域；真正的手柄消费者 `nes_system_v6` 跑 `core_clk`（21.477 MHz）。这两者之间的两级同步器**不在本模块里**，而在平台顶层 [`rtl/platform/zynq/nes_zynq_top.v`](../../rtl/platform/zynq/nes_zynq_top.v)（第 9 节）。

它由文件里的**两个模块**组成，分工很干净：

| 模块 | 它知道什么 | 它不知道什么 |
|---|---|---|
| `nes_touch_input`（顶层） | GT9147 在这块板上**是什么**：器件地址、寄存器图、复位时序、校准、区域映射、按键语义 | I2C 位怎么打 |
| `nes_touch_i2c`（通用主机） | 什么是 I2C：START / 重复 START / 位 / ACK / STOP / tBUF | GT9147 完全不知道 |

文件头也承认参考了板厂驱动的 I2C 拆法（`i2c_dri_m.v`），但 RTL 是重写的。

---

## 2. 骨架代码（不是全文）

全文 1054 行，这里只挑出"读这条数据链"必须认得的几块。要完整位时序请回源码。

**参数与三个区域切口**（编译期常量，`PANEL_W/PANEL_H` 的分数）：

```verilog
localparam [15:0] X_LEFT_EDGE  = (PANEL_W * EDGE_L_NUM) / EDGE_L_DEN;   // 默认 200
localparam [15:0] X_RIGHT_EDGE = (PANEL_W * EDGE_R_NUM) / EDGE_R_DEN;   // 默认 600
localparam [15:0] Y_MID_EDGE   = (PANEL_H * MID_NUM)   / MID_DEN;       // 默认 240
```

**校准要问的三个只读寄存器**（故意写成 `localparam`，不给构建改的机会）：

```verilog
localparam [15:0] CT_XMAX_REG   = 16'h8048;   // X Output Max 低位
localparam [15:0] CT_YMAX_REG   = 16'h804A;   // Y Output Max 低位
localparam [15:0] CT_SWITCH_REG = 16'h804D;   // Module_Switch1，bit3 = X2Y
```

**主状态机**用 `case (seq_q)`，状态名自解释（节选）：

```verilog
SQ_RST_LO / SQ_RST_HI            // 复位：10 ms 拉低 + 50 ms 等待
SQ_WAIT                          // 等轮询周期到点，或中断早唤醒
SQ_ST_WR / REH / REGL / RD / RX  // 读状态 16'h814E
SQ_EVAL                          // 有触摸？→ 坐标，否则 → 清标志
SQ_CO_WR / ... / RX0..RX3        // 读坐标 16'h8150（4 字节）
SQ_CLR_WR / ... / CLR_STOP       // 写 0x00 清触摸标志
SQ_CAL_*                         // 一次性自校准（见 3.7）
SQ_ABORT                         // 任一字节被 NACK：STOP 收场
```

**区域映射与拼 `buttons`**（整条链的落点）：

```verilog
wire region_left   = (touch_x_q <  x_left_edge_q);
wire region_right  = (touch_x_q >= x_right_edge_q);
wire region_middle = ~region_left & ~region_right;
wire region_upper  = (touch_y_q <  y_mid_edge_q);

wire [3:0] touch_dpad = {touch_valid_q & region_middle &  region_upper,  // Up
                         touch_valid_q & region_middle & ~region_upper,  // Down
                         touch_valid_q & region_left,                    // Left
                         touch_valid_q & region_right};                  // Right

assign buttons = {touch_dpad, key_start, key_select, btn_b, btn_a};
```

---

## 3. 逐段精读

### 3.1 文件头：三条事实来源

文件头（1–98 行）不是装饰，它是设计取舍的**出处**。三个层次分得很清楚：

1. **芯片行为**（寄存器图、复位、报点格式）来自 GT9147 手册/《GT9147 编程指南》与板厂驱动的用法。
2. **坐标帧与轴线方向**来自控制器自己发布的**只读寄存器**（`16'h8048/804A/804D`）——不是板厂 pass-through（见 3.7）。
3. **`$4016` 位序**是 NESdev 的，本项目由 [`../modules/controller.md`](../modules/controller.md) 复述。

一句话：**"板厂原样透传"不能证明帧就是代码假定的帧**，所以本模块选择"问"而不是"假设"。

### 3.2 参数与本地常量：切口是寄存器、不是常量

```verilog
localparam [15:0] X_LEFT_EDGE  = (PANEL_W * EDGE_L_NUM) / EDGE_L_DEN;
localparam [15:0] X_RIGHT_EDGE = (PANEL_W * EDGE_R_NUM) / EDGE_R_DEN;
localparam [15:0] Y_MID_EDGE   = (PANEL_H * MID_NUM)   / MID_DEN;
```

这三行是**编译期常量**，默认 `800×1/4=200`、`800×3/4=600`、`480×1/2=240`。它们现在是**回退值**：正常路径下会被自校准的结果覆盖（3.7）。区域映射的**语义**（左 1/4、右 1/4、中间带上下分）没变，变的只是三个**数字**从哪来。

`clog2` 是本文件里写了两遍的小函数（顶层一次、I2C 模块一次）：给"数到 N 需要几位"这种计数器算位宽。`WAIT_MAXV/WAIT_ALLV` 取三个等待值里最大的，`WAIT_CW = clog2(WAIT_ALLV+1)` 就是 `wait_cnt_q` 的宽度——一个计数器同时服务复位等待和轮询周期，宽度按最长的那段取。`DB_CW` 同理给消抖计数器。

**位宽和补零**：`{WAIT_CW{1'b0}}` 是"复制 `WAIT_CW` 个 0"，即清零；`RST_LO_M1 = CT_RST_LOW_CYCLES - 1` 是"数到最后一个数的比较值"（从 0 数到 N-1 需要 N 拍）。这些句式见 [`02-project-conventions.md`](02-project-conventions.md)。

### 3.3 I2C 请求译码：`always @*` 把状态翻译成总线动作

顶层对 I2C 只提**电平请求**：`req_start/req_rep/req_cont/req_stop/req_dir/req_tx/req_ack_out`。它们的值由 `seq_q` 组合译码：

```verilog
always @(*) begin
    req_start = 1'b0; req_rep = 1'b0; req_cont = 1'b0; req_stop = 1'b0;
    req_dir = 1'b1;   req_ack_out = 1'b1; req_tx = 8'h00;
    case (seq_q)
        SQ_ST_WR   : begin req_start = 1'b1; req_tx = {DEV_ADDR, 1'b0}; end
        SQ_ST_REGH : begin req_cont  = 1'b1; req_tx = CT_STATUS_REG[15:8]; end
        SQ_ST_REGL : begin req_cont  = 1'b1; req_tx = CT_STATUS_REG[7:0];  end
        SQ_ST_RD   : begin req_rep   = 1'b1; req_tx = {DEV_ADDR, 1'b1}; end
        SQ_ST_RX   : begin req_cont  = 1'b1; req_dir = 1'b0; req_ack_out = 1'b0; end
        // ...
```

读法要点：

- **默认先全清零**（`always @*` 里所有分支都赋值的纪律，见 [`01-verilog-basics.md`](01-verilog-basics.md) 第 5 节），再按键分支覆盖需要的位。
- `{DEV_ADDR, 1'b0}` 是**拼接**：`7'h14` 左移一位补 0 就是写地址，补 1 就是读地址——I2C 的地址字节第 0 位是方向位。
- **16 位寄存器指针**分两拍发：`REGH` 发高字节、`REGL` 发低字节，都是 `req_cont`（继续）。
- 这些请求是**电平**，会一直保持到 I2C 模块回一个 `byte_done`（或 `byte_nack`/`stop_done`）脉冲，所以不会和位引擎赛跑。

### 3.4 复位时序：10 ms 低 + 50 ms 等待

GT9147 上电后要先被复位，再给足它自检的时间。状态机一上电就进 `SQ_RST_LO`：

```verilog
SQ_RST_LO: begin
    ct_rst_n_q <= 1'b0;
    if (wait_cnt_q == RST_LO_M1) begin           // 数满 500_000 拍 = 10 ms @50MHz
        wait_cnt_q <= {WAIT_CW{1'b0}};
        ct_rst_n_q <= 1'b1;                       // 释放
        seq_q      <= SQ_RST_HI;
    end else wait_cnt_q <= wait_cnt_q + 1'b1;
end
SQ_RST_HI: begin
    if (wait_cnt_q == RST_HI_M1) begin           // 再等 2_500_000 拍 = 50 ms
        wait_cnt_q  <= {WAIT_CW{1'b0}};
        init_done_q <= 1'b1;
        seq_q       <= SQ_CAL_SEL;                // 不立刻 poll，先进自校准
    end else wait_cnt_q <= wait_cnt_q + 1'b1;
end
```

两个关键点：

- **`init_done` 的含义**是"复位序列和 50 ms 等待结束、总线马上要被使用"，**不是**"已读过面板数据"。校准跑在它之后、第一次 poll 之前。
- `ct_rst_n` 是**低有效**：拉低 10 ms 复位面板，释放后再等 50 ms 才第一次访问。测试 `tb_nes_touch_input` 用 `always @(ct_rst_n)` 监视下降/上升沿，并断言两段时间都够。

### 3.5 一次 poll：读状态 → 判定 → 读坐标 → 清标志

`SQ_WAIT` 数满 `POLL_CYCLES`（默认 1_000_000 拍 = 20 ms ≈ 50 次/秒）或被 `ct_int` 提前唤醒，就进 `SQ_ST_WR`。之后是一条固定流水：

1. **读状态** `SQ_ST_WR..SQ_ST_RX`：一笔事务读 `16'h814E` 的 1 字节 → `status_q`。
2. **判定** `SQ_EVAL`：`status_q[7]` 是"数据就绪"，`status_q[3:0]` 是点数。

   ```verilog
   SQ_EVAL: begin
       if (status_q[7] && (status_q[3:0] >= 4'd1) && (status_q[3:0] <= 4'd5)) begin
           touch_valid_q <= 1'b1;
           seq_q         <= SQ_CO_WR;      // 有触摸 → 读坐标
       end else begin
           touch_valid_q <= 1'b0;
           seq_q         <= SQ_CLR_WR;     // 没触摸 → 直接清标志
       end
   end
   ```

3. **读坐标** `SQ_CO_RX0..RX3`：连读 4 字节 = X 低、X 高、Y 低、Y 高。前 3 个 `req_ack_out=1`（ACK，还要下一字节），末字节 `req_ack_out=0`（NACK，收尾）——这是 I2C 多字节读的规矩，写错末字节最容易把控制器读挂。
4. **清标志** `SQ_CLR_WR..CLR_STOP`：向 `16'h814E` 写 `0x00`，然后 `poll_done_q <= 1'b1`、`poll_ok_q <= 1'b1`。

两条支路最后都会走到清标志：有坐标时经 `SQ_CO_STOP → SQ_CLR_WR`，没坐标时直接从 `SQ_EVAL` 进 `SQ_CLR_WR`。**每拍 poll 结束都拉一拍 `poll_done`**——它是测试观察"校准已经过去了"的锚点。

任一字节被 NACK（`byte_nack`）就跳 `SQ_ABORT`：发 STOP 把总线干净交还，置 `error_q <= 1'b1` 并保持（`touch_error` 是**锁存**的），`touch_valid_q <= 0`，`poll_ok_q <= 0`，然后回 `SQ_WAIT`。`bus_busy` 直接来自 I2C 模块的 `i2c_busy`。

> **坐标的映射为什么在最后字节做**：`SQ_CO_RX3` 同时用 `coord_x_raw = {x_hi_q, x_lo_q}`、`coord_y_raw = {rx_data, y_lo_q}` 拼出两个字，再用 `x2y_q ? ... : ...` 两个 16 位二选一对调（见 3.7）。这样"取数序列只有一种字节顺序"，不需要按配置位改层的字节序。

### 3.6 坐标帧是"问出来的"：一次性自校准

这是本模块最有意思的部分。为什么不能假设？文件头写得很直白：现场症状是**屏幕触摸产生的 d-pad 四个方向全反，但区域图几何上是对的**——这正是"坐标所在的帧和硬编码的帧不同"的签名。

GT9147 上电自检模组参数，把结果发布在只读寄存器里。顶层在 50 ms 等待结束后做**一次性校准**，依次读三笔：

| `cal_step_q` | 寄存器 | 字节数 | 含义 |
|---|---|---|---|
| `2'd0` | `16'h8048` | 2 | X Output Max（低字节在前） |
| `2'd1` | `16'h804A` | 2 | Y Output Max |
| `2'd2` | `16'h804D` | 1 | Module_Switch1，bit3 = X2Y |

校准复用**同一段**"读一块字节"序列，由 `cal_step_q` 选区指针和 ACK 图样：

```verilog
wire [15:0] cal_ptr       = (cal_step_q == 2'd0) ? CT_XMAX_REG :
                             (cal_step_q == 2'd1) ? CT_YMAX_REG : CT_SWITCH_REG;
wire        cal_two_bytes = (cal_step_q != 2'd2);
wire        cal_rx_ack    = cal_two_bytes & (cal_idx_q == 2'd0);   // 末字节 NACK
```

`cal_rx_ack` 一身两职：它既是"发 ACK"的信号，也是"还有下一字节"的标志——有它就在 `SQ_CAL_RX` 里再读一次，没有就 STOP。

读完在 `SQ_CAL_DONE` 做**全模块唯一的一次算术**：

```verilog
if (calib_valid) begin
    x_left_edge_q  <= x_out_max_q >> 2;                    // X max 的 1/4
    x_right_edge_q <= x_out_max_q - (x_out_max_q >> 2);    // X max 的 3/4
    y_mid_edge_q   <= y_out_max_q >> 1;                    // Y max 的 1/2
    x2y_q          <= mod_switch_q[3];
    calib_ok_q     <= 1'b1;
end else begin
    x_left_edge_q  <= X_LEFT_EDGE;      // 退回编译期常量
    x_right_edge_q <= X_RIGHT_EDGE;
    y_mid_edge_q   <= Y_MID_EDGE;
    x2y_q          <= 1'b0;
    calib_ok_q     <= 1'b0;
end
```

三个切口从此被**当常量读**，每帧**零算术**——这就是"乘法和移位只做一次"的全部意义。

**失败怎么回退**（`calib_valid` 为假）：

- **NACK**：任一校准字节被 NACK（`calib_fail_q`）。
- **总线卡高**：`x/y_max == 16'hFFFF`，或高字节是 `8'hFF`，或 `mod_switch == 8'hFF`——这是"从机在 ACK 却从不驱动 SDA"。
- **退化值**：`x/y_max == 0`，按面值会把两条水平切口放到 0，把每次触摸都送成 Right。

三类失败都退回编译期常量，且 `x2y` 强置 0。**失败校准的行为 == 校准存在之前**，不会更差；失败**不**拉 `touch_error`（有意吸收，只由 `touch_calib_ok` 报告）。`touch_x_max/touch_y_max/touch_x2y/touch_calib_ok` 是只读诊断线，"存在是为了被看"。

### 3.7 区域映射：五区域互斥且覆盖整个平面

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

- `region` 是 `(x, y)` 的**全函数**：左带 / 中上 / 中下 / 右，五区域互斥且覆盖整个平面，越界坐标也归到三者之一。
- **边界归属被钉死**：`x == X_LEFT_EDGE` 属**中带**（左切口是中带第一个像素）；`x == X_RIGHT_EDGE` 属 **Right**（右切口是 Right 第一个像素）；`y == Y_MID_EDGE` 属 **Down**（中切口是 Down 第一个像素）。测试逐点断言了这三条。
- `touch_valid_q` 与门把关：无有效触摸时 `touch_dpad` 恒 0。比较只读三个寄存器、**无逐帧算术**。

### 3.8 按键：两级同步 + 消抖 + TPAD 的 Start/Select 替换

三个离散输入走同一条链：

```verilog
wire [2:0] key_async = {touch_key, key1, key0};   // 空闲向量 = 3'b011

always @(posedge clk or posedge reset) begin        // 两级同步
    if (reset) begin key_meta_q <= 3'b011; key_sync_q <= 3'b011; end
    else begin key_meta_q <= key_async; key_sync_q <= key_meta_q; end
end

always @(posedge clk or posedge reset) begin        // 消抖
    if (reset) begin
        key_candidate_q <= 3'b011; key_stable_q <= 3'b011; key_cnt_q <= {DB_CW{1'b0}};
    end else if (key_sync_q == key_candidate_q) begin
        key_cnt_q <= {DB_CW{1'b0}};                  // 输入和候选一致 → 计数清零
    end else if (key_cnt_q == DB_M1) begin           // 不一致持续到阈值 → 提升为新的稳定值
        key_candidate_q <= key_sync_q;
        key_stable_q    <= key_sync_q;
        key_cnt_q       <= {DB_CW{1'b0}};
    end else key_cnt_q <= key_cnt_q + 1'b1;
end
```

- **为什么要两级同步**：这三个输入是板级异步信号，直接采可能亚稳态。打两拍把亚稳态压成"最多错一拍"（概念见 [`21-cdc-fifo.md`](21-cdc-fifo.md) 第 3 节）。
- **为什么要消抖**：窗口短于 `DEBOUNCE_CYCLES`（默认 800 拍 = 16 µs）的脉冲**既不**产生 A/B/Start/Select，也**不**被锁存。测试对 `key0` 和 TPAD 都断言了这一点。
- **空闲向量 `3'b011`**：`key0/key1` 低有效、空闲高（bits[1:0]=11），`touch_key` **高有效**、空闲低（bit[2]=0）。

按键语义（`key_stable_q` 之后）：

```verilog
wire ab_substituted = touch_key_debounced;   // 板载 TPAD，高有效；曾经错用 touch_valid_q
wire key_start  = ab_substituted & key0_pressed;
wire key_select = ab_substituted & key1_pressed;
wire btn_a      = ~ab_substituted & key0_pressed;
wire btn_b      = ~ab_substituted & key1_pressed;
```

规律：**按住 TPAD 时 `key0 → Start`、`key1 → Select`；否则 `key0 → A`、`key1 → B`**（这两对按钮不会同时需要）。

> **这是一个板上修过的缺陷**：旧写法用 `touch_valid_q` 门控替换，导致"用屏幕转向"会让两个键变成 Start/Select，转向与开火互斥。替换的使能**必须**取自 TPAD 这根独立的针脚，而不是触摸有效。测试把它独立成回归：报告一次触摸期间两键已按下，必须**仍是** A/B（`buttons==8'h23`，而不是旧 RTL 的 `8'h2c`）。

### 3.9 拼 `buttons` 与位序合同

```verilog
assign buttons = {touch_dpad, key_start, key_select, btn_b, btn_a};
assign dpad    = touch_dpad;
```

对照 [`20-controller.md`](20-controller.md) 的合同（`buttons[7:0]` = A,B,Select,Start,Up,Down,Left,Right，bit0 是 `$4016` 第一次读出的那一位）：

| `buttons` 位 | 来源 | `$4016` 对应位 |
|---|---|---|
| bit0 | `btn_a` | A |
| bit1 | `btn_b` | B |
| bit2 | `key_select` | Select |
| bit3 | `key_start` | Start |
| bit4 | `touch_dpad[0]` = Right | Up |
| bit5 | `touch_dpad[1]` = Left | Down |
| bit6 | `touch_dpad[2]` = Down | Left |
| bit7 | `touch_dpad[3]` = Up | Right |

**A/B/Select/Start 的次序与 `$4016` 一致**。但看 `touch_dpad = {Up, Down, Left, Right}` 的拼接：`buttons[7:4]` 从高到低是 `{Up, Down, Left, Right}`，而 `$4016` 合同要求 `bit4=Up … bit7=Right`，即高半字节相对合同是**反的**。

### 3.10 I2C 位时序去哪查

`nes_touch_i2c`（722 行起）是通用 I2C 主机：一个 `div_cnt_q` 分频出 quarter（`QTR = CLK_HZ/(4*I2C_HZ)`，默认 50 拍 ≈ 1 µs，满周期 250 kHz），一个 `e_state` 状态机走 `START / 位 / ACK / 重复 START / STOP / tBUF`。`E_BIT` 里把每个字节拆成 4 个 quarter（设 SDA、拉高 SCL、高相位采 `sda_i`、拉低 SCL）。它和 `wm8960_i2c.v` 用**完全相同的开漏约定**：

```verilog
assign touch_scl   = touch_scl_o  ? 1'bz : 1'b0;
assign touch_sda   = touch_sda_oe ? touch_sda_o : 1'bz;
assign touch_sda_i = touch_sda;
```

`sda_oe` **只在发逻辑 0 时有效**，主机从不在线上灌高；逻辑 1 靠释放 SDA，让从机在 ACK 槽能压过外部上拉。**位级细节不必逐行抠**，认准"电平请求 + 脉冲应答"（`byte_done/byte_nack/stop_done`）这一层就够了。想深入可对照 [`40-wm8960-i2c.md`](40-wm8960-i2c.md)（同一套约定）。

---

## 4. 端口 / 参数表

**参数**（默认）：

| 参数 | 默认 | 含义 |
|---|---|---|
| `CLK_HZ` / `I2C_HZ` | 50 MHz / 250 kHz | 时钟频率 / I2C 速率（算 `QTR` 用） |
| `DEV_ADDR` | `7'h14` | GT9147 I2C 从地址 |
| `CT_STATUS_REG` / `CT_COORD_REG` | `16'h814E` / `16'h8150` | 状态寄存器 / 点 1 坐标寄存器 |
| `PANEL_W` / `PANEL_H` | 800 / 480 | 面板尺寸（算回退切口用） |
| `EDGE_L_NUM/DEN` 等 | 1/4、3/4、1/2 | 三个切口分数 |
| `DEBOUNCE_CYCLES` | 800（16 µs） | 三级按键共用的消抖窗口 |
| `CT_RST_LOW_CYCLES` | 500_000（10 ms） | `ct_rst_n` 拉低时长 |
| `CT_RST_WAIT_CYCLES` | 2_500_000（50 ms） | 释放到首次访问的等待 |
| `POLL_CYCLES` | 1_000_000（20 ms） | 轮询周期（`ct_int` 可提前唤醒） |
| `USE_CT_INT` | 1 | 是否允许中断早唤醒 |

**端口**（节选，完整见合同表）：

| 信号 | 方向 | 合同 |
|---|---|---|
| `clk` / `reset` | in | 系统时钟（Zynq 接 `sys_clk` = 50 MHz）；**高有效异步**复位，单时钟域、无 `ce` |
| `ct_int` / `ct_rst_n` | in / out | GT9147 中断（低有效，2 级同步）；面板复位（低有效） |
| `scl_o` / `sda_o` / `sda_oe` / `sda_i` | out / in | 开漏 I2C 四件套 |
| `key0` / `key1` / `touch_key` | in | 两个 PL 键（低有效）、板载 TPAD（高有效） |
| `buttons[7:0]` / `dpad[3:0]` | out | 喂 `nes_controller` 的位图 / 触摸方向 `{Up,Down,Left,Right}` |
| `touch_valid` / `touch_x` / `touch_y` | out | 最近有效报点与坐标 |
| `init_done` / `touch_error` / `bus_busy` / `poll_done` | out | 复位等待结束 / 出错后锁存 / I2C 忙 / 一拍完成脉冲 |
| `touch_x_max` / `touch_y_max` / `touch_x2y` / 三个切口 / `touch_calib_ok` | out | 自校准只读诊断结果 |

---

## 5. 一次触摸走一遍

设板子已复位完成、校准成功（切口 199/600/239），手指按在屏幕左上角，`key0` 被按下（低有效），`touch_key` 未按：

| 步骤 | 发生什么 |
|---|---|
| 等待 | `SQ_WAIT` 数到 20 ms（或 `ct_int` 早唤醒）→ `SQ_ST_WR` |
| 读状态 | 起停一笔读 `16'h814E`，得到 `status_q = 8'h81`（bit7 就绪、点数 1） |
| 判定 | `SQ_EVAL`：`status_q[7] && 1<=点数<=5` → `touch_valid_q <= 1`，进 `SQ_CO_WR` |
| 读坐标 | 连读 4 字节 → `x_lo/x_hi/y_lo/y_hi`；末字节用 `x2y_q` 对调两个字；设 `touch_x_q/touch_y_q` |
| 清标志 | 向 `16'h814E` 写 `0x00` → `poll_done` 一拍脉冲，回 `SQ_WAIT` |
| 区域映射 | `touch_x_q < 199` → `region_left=1`；`touch_dpad = 4'b0010`（Left） |
| 按键 | TPAD 未按 → `ab_substituted=0`；`key0` 按下 → `btn_a=1`、`btn_b=0` |
| 拼线 | `buttons = {4'b0010, key_start=0, key_select=0, btn_b=0, btn_a=1} = 8'h21` |
| 串行化 | 平台层把 `buttons` 同步进 `core_clk`，`nes_controller` 每次读 `$4016` 移出一位，第 1 次读出 `buttons[0]=A=1` |

注意：触摸 `(0,0)` 这样的点落 `region_left`；如果同时按 `key0`，A 与方向并存——这正是 3.8 修的缺陷所要保住的行为（屏幕转向不影响键的 A/B 语义）。

---

## 6. 常见疑问

**Q：为什么坐标读的字节顺序不改，而是在最后对调两个字？**
A：如果按 `x2y` 改字节序，取数序列就会随一个"上电读一次的配置位"变两种形态，验证过的那一份字节级模型就不成立了。改成"先按固定顺序拼两个字，再 2:1 mux 交换"，取数序列永远是同一种。

**Q：校准失败会不会让手柄更差？**
A：不会。失败回退到编译期常量（=`PANEL_W/PANEL_H` 的分数），行为**等于**校准存在之前。失败也不拉 `touch_error`，只由 `touch_calib_ok=0` 报告。

**Q：`buttons` 接 `nes_controller` 就完事了吗？**
A：还差一步跨时钟域。`buttons` 在 `sys_clk`，`nes_controller` 在 `core_clk`，中间在平台层打了**两级同步器**（见 3.10 的下游与第 9 节）。核心侧对多位信号直接采会有撕裂风险。

---

## 7. 你应该带走的三件事

1. **触摸屏在 RTL 里就是一只 8 位并联手柄**：`buttons[7:0]` 直接喂 `nes_controller`，屏幕上的手和插着的手柄对 `$4016` 不可区分——不需要新协议。
2. **"问"胜过"假设"**：坐标帧和轴线方向不是抄板厂 pass-through，而是上电后从 `16'h8048/804A/804D` 读回来、一次性推出三个切口（唯一的一次算术），失败回退编译期常量；`touch_calib_ok` 说清是哪一种。
3. **复杂部分有"分层出口"**：I2C 位时序在 `nes_touch_i2c`（"电平请求 + 脉冲应答"），跨时钟域在平台层（两级同步），本模块只负责"是什么"——认准这一层，就不必被 1054 行淹掉。

### 未写进合同的一条观察（未被门禁覆盖）

第 3.9 节已从代码确认：`buttons = {touch_dpad, ...}` 里 `touch_dpad = {Up, Down, Left, Right}`，于是 `buttons[7:4]` 从高到低是 `{Up, Down, Left, Right}`，而 `$4016` 合同要求 `bit4=Up … bit7=Right`——**高半字节相对 `$4016` 的次序是反的**。现有测试（`check_region`）用 `dpad` 自己的字面量比对（Left 判 `buttons[7:4]==4'b0010`），**没有**把这根线穿过 `nes_controller` 再按串行位反查，所以这条次序差异**不会**被 `touch-input-tb` 照出来。这里把它作为"未被门禁覆盖的观察"写明，**不断言已修**——接真实游戏前必须先确认这一点。合同文档 [`../modules/touch-input.md`](../modules/touch-input.md) 第 10 节也列了同一条。

---

下一篇 [`60-system-early.md`](60-system-early.md) 走出单个模块，看早期整机系统怎么把 CPU、PPU、总线拼起来。
