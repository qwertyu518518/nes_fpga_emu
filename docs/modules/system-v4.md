# 系统集成 v4：把并联按钮接到 `$4016`/`$4017`，以及软件模拟器的键盘事件是怎么变成 8 个 bit 的

本文是 `rtl/nes_core/system/nes_system_v4.v` 的接口与接线合同。它在 v3 的 DMA 仲裁点之上只加一件事：**`nes_controller` 进系统**。核心问题只有两个：

1. C 写的软件模拟器怎么把 SDL 键盘事件变成一个 controller bit 数组，又怎么把它变成 `$4016`/`$4017` 的 strobe + 移位？
2. 硬件上"8 根并联输入线 + 一颗 4021 移位寄存器 + 总线上的读数据替换"和上面那段 C 是不是同一套行为？

`docs/modules/controller.md` 已经逐条写清 `nes_controller` 自身的接口合同、位序合同与三种 `EXTRA_READ` 策略，`docs/modules/system-v3.md` 写清 v3 的 DMA 仲裁点与 `$4014` 同沿竞争。本文不重复这两份，只写：

- 软件侧的**事件 → bit 数组 → strobe → 串行读**这条完整链路，以及它和硬件的逐项对应；
- v4 顶层**具体怎么接线**（4 条线 + 1 个 mux），以及每条线为什么是那个极性；
- controller override 的**准确边界**（`$4016` 全部访问 + `$4017` 读，`$4017` 写必须继续到达 APU 帧计数器），以及它带来的两个代价（open bus 上没有手柄那一位、只填 bit0）；
- 4 个板载按键为什么只是**后续平台映射问题**，不是 RTL 问题；
- v4 明确未实现的部分。

行为权威是 NESdev "Controllers" 与 CPU 地址图中 `$4016`/`$4017` 的说明。`[源码观察]` 标记的内容只是克隆仓库的写法，不是规格。

---

## 1. 软件模拟器那一侧：事件是怎么变成 8 个 bit 的

### 1.1 SDL 事件 -> `bool[8]`

`[源码观察]` cNES 的驱动把键盘、手柄按键、摇杆轴**统一成 8 个布尔值**，下标就是 NESdev 的 `$4016` 串行输出顺序：

```c
static SDL_Scancode g_poll_keys[BUTTON_COUNT] = {
        SDL_SCANCODE_Z, SDL_SCANCODE_X, SDL_SCANCODE_COMMA, SDL_SCANCODE_PERIOD,
        SDL_SCANCODE_UP, SDL_SCANCODE_DOWN, SDL_SCANCODE_LEFT, SDL_SCANCODE_RIGHT
};
void sc_poll_input(unsigned int controller_id) {
    const uint8_t *key_states = SDL_GetKeyboardState(&key_count);
    for (int i = 0; i < BUTTON_COUNT; i++)
        button_states[i] = key_states[g_poll_keys[i]]
                         | _get_controller_button(controller_id, g_poll_buttons[i]);
    button_states[4] |= _get_controller_axis(controller_id, SDL_CONTROLLER_AXIS_LEFTY,  0);
    button_states[5] |= _get_controller_axis(controller_id, SDL_CONTROLLER_AXIS_LEFTY,  1);
    button_states[6] |= _get_controller_axis(controller_id, SDL_CONTROLLER_AXIS_LEFTX,  0);
    button_states[7] |= _get_controller_axis(controller_id, SDL_CONTROLLER_AXIS_LEFTX,  1);
    sc_set_state(get_controller(controller_id), button_states);
}
```

```c
#define STD_BTN_A 0
#define STD_BTN_B 1
#define STD_BTN_SELECT 2
#define STD_BTN_START 3
#define STD_BTN_UP 4
#define STD_BTN_DOWN 5
#define STD_BTN_LEFT 6
#define STD_BTN_RIGHT 7
```

`[源码观察]` Obara 走的是事件驱动的位图，同一套下标：

```c
void keyboard_mapper(struct JoyPad* joyPad, SDL_Event* event){
    uint16_t key = 0;
    switch (event->key.key) { case SDLK_RIGHT: key = RIGHT; break; ... }
    if (event->type == SDL_EVENT_KEY_UP)        joyPad->status &= ~key;
    else if (event->type == SDL_EVENT_KEY_DOWN) joyPad->status |= key;
}
```

这两段是**两套模拟器里唯一真正和"硬件"对应的东西**：8 根并联触点的当前电平。它们在软件里是一个 `bool[8]` / `uint16_t` 位图，在硬件里是 FPGA 的 8 根引脚。

### 1.2 写 `$4016` -> strobe 电平；读 `$4016` -> 移一位

`[源码观察]` cNES：

```c
void controller_push(unsigned int port, uint8_t data) {
    // there's only one output port, which is directed to both controllers
    for (int port = MIN_PORT; port <= MAX_PORT; port++)
        controllers[port]->pusher(controllers[port], data);
}

uint8_t _sc_poll(Controller *controller) {
    ScState *state_cast = (ScState*) controller->state;
    if (state_cast->strobe) {
        state_cast->bit = 0;
        g_poll_callback(controller->id);      /* 重新采样 SDL：这就是"电平敏感的并联装载" */
    }
    if (state_cast->bit > 7) { state_cast->bit++; return 1; }
    if (state_cast->button_states[state_cast->bit++]) return 1; else return 0;
}
```

`[源码观察]` Obara 更接近字面意义上的移位寄存器：

```c
uint8_t read_joypad(struct JoyPad* joyPad){
    uint8_t val = joyPad->reg & 1;
    joyPad->reg >>= 1;
    joyPad->reg |= 0x80;      /* refill BIT 7 with 1 */
    return val;
}
```

于是软件一次轮询就是游戏里人人都会写的那 10 条指令：

```text
LDA #$01
STA $4016      ; /PL 拉低：并联装载
LDA #$00
STA $4016      ; /PL 拉高：快照冻结
LDA $4016      ; -> A  = A
LDA $4016      ; -> A  = B
LDA $4016      ; -> A  = Select
LDA $4016      ; -> A  = Start
LDA $4016      ; -> A  = Up
LDA $4016      ; -> A  = Down
LDA $4016      ; -> A  = Left
LDA $4016      ; -> A  = Right
```

`tb/system/tb_nes_system_v4.v` 跑的就是这一段，只是把 8 个结果分别存进 `$0020..$0027` 再逐位 `CMP`。

### 1.3 与硬件的逐项对应

| 软件侧（`[源码观察]`） | v4 硬件侧 | 一致吗 |
| --- | --- | --- |
| `bool button_states[8]` / `joyPad->status` | 顶层输入 `buttons1[7:0]` / `buttons2[7:0]` | 一致：**位序由 NESdev 定，不是本项目定的** |
| `state->strobe`（写 `$4016` 的 bit0） | 顶层寄存器 `latch_strobe_q`，直接接 `u_controller.latch_strobe` | 一致，**都是电平不是边沿** |
| `state->bit`（读位置） | `cnt1_q` / `cnt2_q` | 一致 |
| `button_states[bit++]` | `sel_sr[0]` + `sr <= {fill_one, sr[7:1]}` | 一致 |
| `controller_push` 向两个端口循环 | 一根 `latch_strobe_q` 同时装载 `sr1_q` 与 `sr2_q` | 一致（真实连线也是一根 `/PL`） |
| `addr - 0x4016` | `ctrl_read_select = apu_addr_ctrl2` | 一致 |
| `return 0x40 \| bit` | `{7'b0, controller_data}` | **不一致，且是有意的**：v4 只填 bit0，open bus 留给总线层（见 3.3） |
| 没有任何握手 | `latch_strobe_q` 写入沿 vs `u_controller` 装载沿差一拍 | 一致：真实 4021 也是 `/PL` 拉高后的下一个时钟才装载 |

结论与 `docs/modules/controller.md` 第 0 节相同：**位的次序、快照的时机、8 次读取的边界完全相同；"谁提供这 8 个物理状态"完全不是同一件事。** 软件不需要并联输入线（SDL 已经给了一个 8 元素布尔数组），硬件必须有 8 根同步 + 消抖后的物理输入。

## 2. v4 顶层的接线：4 条线 + 1 个 mux

v3 的 `nes_cpu_bus` 把 `$4000-$401F` 整体译码成 `OWNER_APU_IO`（`decode_owner` 的 `3'b010` 分支），并把完成脉冲给成 `apu_xfer`。v4 **一个字都没改 `nes_cpu_bus`**，全部 override 都在顶层：

```verilog
localparam [4:0] APU_REG_OAMDMA = 5'h14;
localparam [4:0] APU_REG_CTRL1  = 5'h16;
localparam [4:0] APU_REG_CTRL2  = 5'h17;

wire apu_addr_ctrl1      = (apu_addr == APU_REG_CTRL1);
wire apu_addr_ctrl2      = (apu_addr == APU_REG_CTRL2);
wire apu_addr_ctrl_owned = apu_addr_ctrl1 || (apu_addr_ctrl2 && !apu_we);
wire apu_ctrl_xfer       = apu_xfer && apu_addr_ctrl_owned;
wire apu_ctrl_read       = apu_ctrl_xfer && !apu_we;
wire apu_port_cs         = apu_xfer && !apu_addr_ctrl_owned;

assign apu_reg_cs = apu_port_cs;                 // 观测端口
assign apu_reg_we = apu_we;
assign apu_reg_addr = apu_addr;

assign cpu_din = apu_ctrl_xfer ? {7'b0, controller_data} : bus_cpu_din;

reg latch_strobe_q;
always @(posedge clk or posedge reset) begin
    if (reset)                                                  latch_strobe_q <= 1'b0;
    else if (apu_xfer && apu_we && apu_addr_ctrl1)             latch_strobe_q <= cpu_dout[0];
end

wire ctrl_read_strobe = apu_ctrl_read;
wire ctrl_read_select = apu_addr_ctrl2;
```

以及 `nes_controller` 例化时 `.reg_cs(apu_port_cs)`——**送进 APU 实例的也必须是 gate 过的信号**，否则端口说"没有访问"而 APU 内部副作用照旧发生，那是一种"断言看不见的缺陷"。这条不变量现在是被 testbench 抓着的：TB 统计层次信号 `dut.u_apu.reg_wr_frame` 被拉高的 clk 数，断言恰好 1（见 3.1）。

四条线：

| 线 | 表达式 | 为什么是这个极性 |
| --- | --- | --- |
| `/PL` 电平 | `apu_xfer && apu_we && apu_addr == $16` | 必须是**完成沿**，不是请求沿。`apu_we` 是请求级的（`apu_req && cpu_we`），如果用它而不是 `apu_xfer`，一个 stalled 的 `$4016` 写会在等待拍和完成拍各改一次电平 |
| 读选通 | `apu_ctrl_read` = `apu_xfer && !apu_we && addr ∈ {$16,$17}` | 同上：**只认完成沿**。APU_IO owner 用 `READ_WAIT_CYCLES=1`，而 `c7ebf00` 之后 `wait_need <= 1` 是**零等待**，所以一次读只占**一个** CPU 周期（原文写的"一次读占 2 个 CPU 周期"是 2x 速率缺陷的形态）；无论占几个周期，用请求级信号都会让一次读错位 |
| 端口选择 | `apu_addr_ctrl2` | `$4016` -> 0，`$4017` -> 1。与 cNES 的 `addr - 0x4016` 同义 |
| 数据回注 | `cpu_din = apu_ctrl_xfer ? {7'b0, controller_data} : bus_cpu_din` | `nes_cpu_bus` 的读数据 mux 在 `OWNER_APU_IO` 分支上取 `apu_din`；顶层在**同一拍**把它换成串行位 |

override 的边界是**按地址 + 方向**划的，不是整段地址：

| 访问 | controller 做什么 | APU `reg_cs` / `apu_reg_cs` |
| --- | --- | --- |
| `$4016` 读 | port 1 移位，串行位进 `cpu_din[0]` | 0 |
| `$4016` 写 | 加载共享 `/PL`（`latch_strobe_q`） | 0 |
| `$4017` 读 | port 2 移位，串行位进 `cpu_din[0]` | 0 |
| **`$4017` 写** | **不参与** | **1**（`nes_apu2a03` 的 `reg_wr_frame` 成立） |
| `$4000-$4015` 其余 | 不参与 | 1 |

`$4017` 的写之所以必须留在 APU 侧：真机上写 `$4017` 进的是帧计数器，读 `$4017` 出来的是帧计数器状态 + 手柄 bit0，本来就是两个完全不同的东西；而 v3 的程序正是靠 `STA $4017` 配置 4 步/5 步与 frame IRQ 禁止位，TB 里对应的判据是 `apu_wr_frame == 1`。详见 3.1。

### 2.1 `/PL` 与 4021 之间有一拍，这是对的

`latch_strobe_q` 在 `$4016` 写完成的沿更新；`nes_controller` 在**下一个**时钟沿才看到新的电平并装载。这是真实的 4021 时序：`/PL` 拉高之后，第一个有效时钟才把并行输入搬进移位寄存器。TB 把这件事写成断言而不是注释——在第二次 `/PL`（port 2 测试开始）的前后各取一次快照：

```text
CONTROLLERPL the shared /PL took effect on the clock after the completed $4016 write:
port 1 went cnt=9 sr=ff latch=a5 -> cnt=0 sr=a5 latch=a5
```

即"port 1 读满 9 次之后，第二次 `$4016` 写让它回到 `cnt=0, sr=buttons1`"。这也顺带证明了**一根 `/PL` 同时清两个计数器**（真实连线如此），以及 port 2 读满 8 次之后 port 1 仍然是 `cnt=0`（一路耗尽不污染另一路）。

### 2.2 读数据为什么能在同一拍取到正确的那一位

`nes_cpu6502` 的 `cpu_active = ce && !bus_hold && !reset`，状态机在 `ce` 窗口结束的**那个沿**用沿前的 `bus_din` 更新寄存器；`nes_controller` 在**同一个沿**做移位。因此 CPU 拿到的是移位**之前**的 `sel_sr[0]`，硬件上也正是这样：4021 的 `OUT` 是组合的，CPU 在时钟沿上采样，之后才发生移位。TB 因此把断言写成"每一次完成的控制器读，`bus_din[0]` 必须等于期望序列的下一位"：

```text
CONTROLLERBUS every completed $4016 transfer and every $4017 read bypassed apu_reg_cs,
the $4017 write still drove apu_reg_cs with reg_we high, every read put exactly one serial
bit on the cpu read data bus, ...
```

18 次读（两个口各 8 次 + 各自第 9 次）逐位核对，错一位就 `ctrl_data_err` 非零。

### 2.3 一个容易写错的细节：`LDA $4016` 只碰 `$4016` 一次

`nes_cpu6502` 的 `ST_ABS_LO` / `ST_ABS_HI` 状态是**用 `bus_addr = pc_reg` 从程序计数器取操作数字节**的，不走数据总线上的 `addr_reg`。所以 `LDA $4016` 对 `$40xx` 窗口只产生**一次**完成传输（`ST_DATA` 那一次），不是三次。这一点必须确认过：如果操作数字节是按 `$4016`/`$4017` 取的，那么 `LDA $4016` 的高字节取数会顺带把 port 2 也移一位，整个设计从第一拍就是错的。`tb_nes_system_v3` 的 `apu_rd` 计数（3 次 `LDA $4015` = 3 次 APU 读）是同一件事的旁证。

## 3. override 的边界与两个真实代价

### 3.1 `$4017` 的写必须继续到达 APU 帧计数器（曾经出过的真实回归）

这一节记的是**被修掉**的一处回归，不是现状。最初的 override 把 `$4016`/`$4017` **整段地址**在两种方向上一起 gate 掉了：

```verilog
wire apu_addr_ctrl   = apu_addr_ctrl1 || apu_addr_ctrl2;   // 错：不分方向
wire apu_port_cs     = apu_xfer && !apu_addr_ctrl;
```

后果是 `nes_apu2a03` 的 `reg_wr_frame = reg_cs && reg_we && (reg_addr == 5'h17)` 永远不成立：**任何写 `$4017` 来配置帧计数器模式（4 步/5 步、允许/禁止 frame IRQ）的程序，在 v4 上这条配置会静默丢失**，帧计数器永远停在复位默认的 4 步 + 允许 IRQ。当时的 TB 干脆**不写** `$4017`，并把这件事写成 `$4017=0` 的断言与输出——那是在把一处功能退化固定下来而不是修掉它。

现在的合同是**只 gate `$4016` 的全部访问与 `$4017` 的读**：

```verilog
wire apu_addr_ctrl_owned = apu_addr_ctrl1 || (apu_addr_ctrl2 && !apu_we);
wire apu_port_cs         = apu_xfer && !apu_addr_ctrl_owned;
```

`!apu_we` 那一项不只是为了让 APU 看见帧计数器写，它同时保护了**读数据 mux**：`cpu_din` 的覆盖条件是 `apu_ctrl_xfer`，如果 `$4017` 写也被算成 controller 自己的传输，`cpu_din` 会在写周期上被换成 `{7'b0, controller_data}`，CPU 紧接着的那次取指就会读到垃圾操作码。实测把 `!apu_we` 删掉（回到旧的整段 gate）时，程序立刻跑飞，最终报 `the port 2 read counter disagreed with the completed reads 702777 times`。

TB 侧现在有两条独立判据把这条边界钉住：

- `apu_wr_frame == 1`：`apu_reg_cs && bus_we && apu_reg_addr == 5'h17` 的完成脉冲恰好 1 次（程序的 `LDA #$00 / STA $4017`）；
- `apu_frame_pulse == 1`：层次观察 APU 实例内部的 `u_apu.reg_wr_frame`，证明这条写**真的进了帧计数器**，而不只是"端口说有访问"。这一条正是为了防止"观测端口与 APU 实例接的不是同一根线"这种断言看不见的缺陷重新长出来。

对应输出：

```text
APUREG writes $4000-$4003=1 each, $4015=2 (1 enable + 1 acks), $4014=1,
$4017=1 reached the frame counter inside the apu instance while only the $4017 read
belongs to controller2, reads $4015=1 PASS
```

同时 `apu_reg_cs` 的泄漏判据从"地址是 `$16` 或 `$17` 就失败"收窄成"地址是 `$16`，或者地址是 `$17` 且 `apu_reg_we` 为 0 就失败"，并加上反向的一条：任何 `apu_reg_cs` 为高的拍上 `apu_reg_addr` 不得是 `$16`、不得是 `$17` 的读。两条一起保证"读 `$4017` + 全部 `$4016`"这一个集合之外没有别的洞。

写 `$4017 = $00` 会把 `frame_count` 复位成 0 并选 4 步模式，TB 仍然断言 `dbg_frame_count` 全程不得超过 `FC_END_4 = 29829`（也就是程序确实把帧计数器留在 4 步模式），frame IRQ 照常每 29829 个 `ce_cpu` 抬一次，IRQ 链路覆盖不变（本 testbench 跑满 2 帧 = 59562 个 `ce`，`irq rises=1 falls=1 entries=1`）。


`nes_cpu_bus` 在一次完成的读之后把 `open_bus_q <= bus_data_r`，而 `bus_data_r` 在 `OWNER_APU_IO` 分支上取的是 `apu_din`（`apu_port_cs == 0` 时 APU 给 `$00`）。所以之后再读 `$4018-$5FFF` 拿到的是 `$00`，**不是**"上一次完成传输的字节"（也就是不是手柄那一位）。cNES 的 `0x40 | controller_poll(...)` 那种建模在 v4 里没有做，因为 open bus 的建模属于总线层，而总线层这次没改。`docs/modules/controller.md` 第 7 节已经把 open bus 列为 `nes_controller` 的未实现项，v4 只是把它继续往上传了一格。

### 3.3 只填 bit0

`{7'b0, controller_data}`：`bus_din[7:1]` 恒为 0。TB 逐次读断言 `bus_din[7:1] == 7'h00`（`ctrl_read_width_err`），因为位宽收窄是最容易被"顺手改成 `0x40`"的地方。

## 4. 4 个板载按键是平台映射问题，不是 RTL 问题

`nes_system_v4` 的契约是：**`buttons1[7:0]` / `buttons2[7:0]` 已经是 8 位稳定电平**。它不做消抖、不做鬼键检测、不做 CDC、不做键盘扫描矩阵解码——`docs/modules/controller.md` 第 6 节把这条边界画在输入同步之前。

因此"板子上只有 4 个按键，怎么填满 8 个 bit"完全落在 `rtl/platform/ep4ce10/` 与 `docs/hardware/09-input-and-pins.md` 的范围内，RTL 这一侧不需要任何改动：

| 平台要做的事 | 落在哪里 | 对 `nes_system_v4` 的影响 |
| --- | --- | --- |
| 4 个物理按键的按下/释放沿 → 8 bit 位图 | 平台层输入同步 + 消抖 + 边沿检测 | 无。位图直接驱动 `buttons1` |
| 只有 4 个物理键时的**组合键语义**（例如 A+B 映射到 Select） | 平台层的按键映射表 | 无 |
| 按键扫描矩阵（行列复用）解码 | 平台层 | 无 |
| 跨时钟域同步（按键在另一个时钟域） | 平台层 | 无，但**必须**在进 `buttons1` 之前做完：`nes_controller` 只在 `clk` 域采样 |
| 键盘/USB 而非物理按键 | 更高层的驱动 | 无 |

换句话说，v4 之后剩下的输入工作**没有一件需要改 `nes_controller` 或 `nes_system_v4`**：8 bit 的契约是稳定的，缺的是"谁来产生这 8 个稳定的 bit"。这也是 `tb/system/tb_nes_system_v4.v` 在顶层直接给固定 `buttons1`/`buttons2` 就够了的原因——它测的是 `$4016`/`$4017` 这一侧的合同，不是按键那一侧。

## 5. v4 明确未实现

以下是**被测顶层 `nes_system_v4`** 的范围限制，不是 testbench 的缺陷：

- **open bus 上没有手柄位**（见 3.2），`$4018-$5FFF` 读 `$00`、写忽略。
- **读 `$4017` 出来的只有手柄那一位**：`nes_apu2a03` 的 `reg_dout` 在 `reg_addr == 5'h17` 的读上给 `$00`，而 v4 把 `$4017` 的读整个交给 controller2，所以 CPU 从 `$4017` 读到的就是 `{7'b0, controller_data}`。真机上 `$4017` 读的 bit6/bit7 来自帧计数器状态位——**这两位没有被建模**。这和上一条是同一个缺口：帧计数器的**写**路径完整（`reg_wr_frame`），**读**路径被 controller 独占且只回手柄位。
- **`$4016` 的 bit6/bit7 扩展口**（Zapper / 四个玩家的模拟子系统和 NES 侧 4 个手柄位）没有建模，`{7'b0, data}` 恒为 0。
- **第 9 次及以后的读**按 `nes_controller` 的默认 `EXTRA_READ = 2'd0` 返回恒 1。v4 没有把 `EXTRA_READ` 提成 `nes_system_v4` 的参数，也没有做真机的 9 级 tie-high 移位器。
- **手柄的物理层**：`nes_controller` 不检测"没接手柄"（真实硬件靠数据线被上拉成全 1 检出）。`buttons1 = 8'hFF` 恰好就是"什么都没按"，但没有独立的故障通道。
- **DMC DMA 通路**与 v3 相同：接线存在但本 testbench 从不激励，`apu_dmc_bus_req` 与 `dma_sel` 全程为 0、`dbg_dmc_irq` 永不抬升。**没有**任何保护阻止未来程序启动 DMC 后撞上未验证的握手。
- **`OAMADDR_WRITE = 0`**、**mapper**（无寄存器 / 无 bank 切换 / 无 mapper IRQ，`PRG_SIZE_BYTES` 只是容量参数，默认 16 KiB NROM-128 行为）、**`$6000-$7FFF` 无 PRG RAM**、**sprite 0 hit / overflow 未覆盖**、**音频输出通路**（无 FIFO / 无抽取 / 无 WM8978 接口，`audio_sample_valid` 是 `ce_cpu` 速率的 strobe）、**上板频率与跨时钟域**——全部与 `docs/modules/system-v3.md` 第 7 节相同，v4 没有改动其中任何一条。
- **`/PL` 的电平敏感性在系统级没有被区分**：v4 TB 按任务要求在顶层给**固定** `buttons1`/`buttons2`，因此"电平装载 vs 边沿装载"在系统级是等价变异（两个快照时刻的 `buttons` 相同）。这条语义由 `tb/controller/tb_nes_controller.v` 的 `test_strobe_reload` 专门覆盖（它在 `latch_strobe` 保持为高时改 `buttons`，断言 `data_bit` 与 `dbg_sr1` 立刻变化），系统级不重复。
