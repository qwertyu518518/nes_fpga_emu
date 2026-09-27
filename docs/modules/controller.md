# 标准 NES 手柄（$4016 / $4017）：从 SDL 键盘事件到并联输入 + 串行移位器

本文说明 `rtl/nes_core/controller/nes_controller.v` 的接口合同、时序模型和设计取舍，并回答一个和 `oam-dma.md` 同源的教学问题：

> 一个用 C 写的软件模拟器（一段 `memcpy` 加一个 `bit++` 计数器）和一个用 Verilog 写的硬件实现（8 根并联输入线 + 一个 8 位移位寄存器 + 一个读选通），究竟是不是**同一套行为的两种写法**？

结论：**位的次序、快照的时机、8 次读取的边界完全相同；"谁来提供这 8 个物理状态"完全不是。** 软件模拟器不需要并联输入线，因为 SDL 已经给了它一个 8 元素的布尔数组；硬件实现必须有 8 根同步+消抖后的物理输入，因为 NES 手柄的电气接口本来就是 8 根并联触点。`nes_controller.v` 实现的是后者：**CPU 可见的串行端口**，而不是手柄的物理层。

行为权威是 NESdev "Controllers" 章节。参考的克隆仓库只作为"别人怎么实现"的观察：

```text
.slim/clonedeps/repos/caseif__cNES/include/input/standard/standard_controller.h   STD_BTN_A..STD_BTN_RIGHT = 0..7
.slim/clonedeps/repos/caseif__cNES/src/input/standard/sc_driver.c                 SDL 键盘/手柄/摇杆 -> bool button_states[8]
.slim/clonedeps/repos/caseif__cNES/src/input/standard/standard_controller.c       _sc_push / _sc_poll：strobe + bit 计数器
.slim/clonedeps/repos/caseif__cNES/src/input/input_device.c                      controller_push 向两个端口广播 strobe
.slim/clonedeps/repos/caseif__cNES/src/system.c                                   $4016/$4017 读写译码 + 0x40 open bus
.slim/clonedeps/repos/ObaraEmmanuel__NES/src/controller.h                         KeyPad 位图枚举
.slim/clonedeps/repos/ObaraEmmanuel__NES/src/controller.c                         keyboard_mapper / read_joypad
.slim/clonedeps/repos/ObaraEmmanuel__NES/src/mmu.c                                $4016/$4017 -> read_joypad
```

`[源码观察]` 标记的内容只是这两个仓库的写法，不是规格。

---

## 1. 硬件侧：4021 移位寄存器到底是什么

NES 标准手柄里那颗 4021 是一个 **8 位并联输入 / 串行输出** 的移位寄存器。它只有三根有效信号：

| 信号 | 方向（对手柄而言） | 作用 |
| --- | --- | --- |
| `/PL`（strobe） | in | 低有效。**拉低时把 8 根并联输入线装进移位寄存器**；保持低就一直重新装。 |
| `CLK` | in | 每个上升沿把移位寄存器左移一位，并行输入线被新数据补进高端。 |
| `OUT`（data） | out | 移位寄存器第 0 位。**每读一次 `$4016`，CPU 拿到当前第 0 位，寄存器同时前进一位。** |

关键点，也是整个模块的设计中心：

1. **并联输入是"活的"，移位寄存器是"冻结的"。** 8 根输入线任何时候都在变，但 CPU 在 8 次读取期间看到的是**某一个瞬间的快照**。`/PL` 就是"拍照"的那一下。
2. **`/PL` 是电平，不是边沿。** 真实 4021 在 `/PL` 为低的整个期间持续并联装载；`/PL` 拉高之后，寄存器停在最后一次装入的快照上继续移位。软件模拟器必须显式模仿这一点。
3. **8 次之后没有数据了。** 真实硬件的 `OUT` 在内部计数器越过 8 之后由外部上拉电阻决定，实践中读到的是 1（`OUT` 空闲时被上拉）。各家模拟器写法不同，见第 4 节。
4. **两个端口共用一根 strobe。** `$4016` 的写同时给两个手柄的 `/PL` 喂信号，这是 cNES 里 `controller_push` 显式 `for` 循环两个端口的原因，也是真实硬件的连线。

一次典型的软件轮询（NES 游戏的 `ReadInput` 例程）：

```
LDA #$01
STA $4016      ; /PL 拉低：装入 A,B,Sel,St,Up,Dn,Lt,Rt
LDA #$00
STA $4016      ; /PL 拉高：快照冻结，开始移位
LDA $4016      ; -> A
LDA $4016      ; -> B
LDA $4016      ; -> Select
LDA $4016      ; -> Start
LDA $4016      ; -> Up
LDA $4016      ; -> Down
LDA $4016      ; -> Left
LDA $4016      ; -> Right
```

所以 $4016 的访问序列是 **1 次写 + 1 次写 + 8 次读**，共 10 个 CPU 周期量级的 IO 操作。这也是本模块为什么把"写 strobe"和"读一位"做成两个独立信号，而不是一个"访问"信号。

---

## 2. 软件模拟器怎么把键盘事件变成 strobe + 移位寄存器

### 2.1 cNES：SDL 状态 -> `bool[8]` -> `memcpy` -> 计数器

`[源码观察]` cNES 的手柄状态只有三样东西，和 RTL 的三个寄存器一一对应：

```c
typedef struct {
    bool button_states[8];   /* = 8 根并联输入线 */
    bool strobe;             /* = /PL 的电平      */
    unsigned int bit;        /* = 移位位置        */
} ScState;
```

SDL 那一侧把键盘、手柄按键、摇杆轴统一成 8 个布尔值（`sc_driver.c`）：

```c
static SDL_Scancode g_poll_keys[BUTTON_COUNT] = {
        SDL_SCANCODE_Z, SDL_SCANCODE_X, SDL_SCANCODE_COMMA, SDL_SCANCODE_PERIOD,
        SDL_SCANCODE_UP, SDL_SCANCODE_DOWN, SDL_SCANCODE_LEFT, SDL_SCANCODE_RIGHT
};

static SDL_GameControllerButton g_poll_buttons[BUTTON_COUNT] = {
        SDL_CONTROLLER_BUTTON_A, SDL_CONTROLLER_BUTTON_X,
        SDL_CONTROLLER_BUTTON_BACK, SDL_CONTROLLER_BUTTON_START,
        SDL_CONTROLLER_BUTTON_DPAD_UP, SDL_CONTROLLER_BUTTON_DPAD_DOWN,
        SDL_CONTROLLER_BUTTON_DPAD_LEFT, SDL_CONTROLLER_BUTTON_DPAD_RIGHT,
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

**数组下标就是位号**，而且下标顺序正是 NESdev 的 `$4016` 串行输出顺序：

```c
#define STD_BTN_A      0
#define STD_BTN_B      1
#define STD_BTN_SELECT 2
#define STD_BTN_START  3
#define STD_BTN_UP     4
#define STD_BTN_DOWN   5
#define STD_BTN_LEFT   6
#define STD_BTN_RIGHT  7
```

这就是本模块 `buttons[7:0]` 的位序合同，**不是本项目自己定的**。

然后是一次 `memcpy`（`standard_controller.c`）：

```c
void sc_set_state(Controller *controller, bool button_states[]) {
    memcpy(((ScState*) controller->state)->button_states, button_states, sizeof(bool) * 8);
}
```

注意这里**没有任何握手**。`button_states[]` 是宿主进程的内存，CPU 的 MMIO 读和 SDL 事件循环跑在同一个线程里，"数据到了没有"这个问题在软件里不存在。

写 `$4016` 就是设 `strobe` 电平，并且**向两个端口广播**（`input_device.c`）：

```c
void controller_push(unsigned int port, uint8_t data) {
    // there's only one output port, which is directed to both controllers
    for (int port = MIN_PORT; port <= MAX_PORT; port++)
        controllers[port]->pusher(controllers[port], data);
}
```

读 `$4016` 就是移位（`standard_controller.c`）：

```c
uint8_t _sc_poll(Controller *controller) {
    ScState *state_cast = (ScState*) controller->state;

    if (state_cast->strobe) {
        state_cast->bit = 0;
        g_poll_callback(controller->id);      /* 重新采样 SDL：这就是"电平敏感的并联装载" */
    }

    if (state_cast->bit > 7) {
        state_cast->bit++;
        return 1; // input is tied to vcc, so extra reads reutrn 1
    }

    if (state_cast->button_states[state_cast->bit++]) return 1;
    else return 0;
}
```

### 2.2 Obara：一个字面意义上的 8 位移位寄存器

`[源码观察]` Obara 走的是另一条路。SDL 事件直接写进一个 16 位位图（`controller.c`）：

```c
void keyboard_mapper(struct JoyPad* joyPad, SDL_Event* event){
    uint16_t key = 0;
    switch (event->key.key) {
        case SDLK_RIGHT: key = RIGHT; break;
        case SDLK_LEFT:  key = LEFT;  break;
        ...
        case SDLK_J: key = BUTTON_A; break;
        case SDLK_K: key = BUTTON_B; break;
    }
    if (event->type == SDL_EVENT_KEY_UP)        joyPad->status &= ~key;
    else if (event->type == SDL_EVENT_KEY_DOWN) joyPad->status |= key;
}
```

位号定义在 `controller.h`，**和 cNES 完全一致**（`A=0, B=1, SELECT=2, START=3, UP=4, DOWN=5, LEFT=6, RIGHT=7`）。事件驱动的 `|=` / `&= ~` 就是 8 根并联输入线在翻转。

移位则是字面意义上的移位寄存器：

```c
uint8_t read_joypad(struct JoyPad* joyPad){
    uint8_t val = joyPad->reg & 1;
    joyPad->reg >>= 1;
    // refill BIT 7 with 1
    joyPad->reg |= 0x80;
    return val;
}
```

这三行就是本模块里这一行的直译：

```verilog
wire [7:0] sr1_next  = {fill_one, sr1_q[7:1]};
```

`val = reg & 1` 是 `sel_sr[0]`，`reg >>= 1` 是 `sr[7:1]`，`reg |= 0x80` 是 `fill_one`。而且"补进 1"这个选择**自带了第 4 节讨论的 past-8 行为**：8 次之后 `reg` 自然变成 `0xFF`，之后永远返回 1。这不是特殊分支，是移位方向的副产物。

`mmu.c` 里的端口选择：

```c
mem->bus |= read_joypad(&mem->joy1) & 0x1f;   /* $4016 */
mem->bus |= read_joypad(&mem->joy2) & 0x1f;   /* $4017 */
```

### 2.3 open bus：为什么软件模拟器要 `| 0x40`

`[源码观察]` cNES 的读译码：

```c
} else if (addr >= 0x4016 && addr <= 0x4017) {
    return 0x40 | controller_poll(addr - 0x4016);
}
```

bit0 是手柄数据，bit6 恒为 1（open bus 上一次访问留下的值）。**这是总线的性质，不是手柄的性质。** 本模块的 `data_out` 因此只填 bit0，`data_out[7:1]` 恒为 0；open bus 的建模留给 `nes_cpu_bus` 那一层。

### 2.4 两种写法的差异表

| cNES / Obara 里的写法 | `nes_controller.v` 里的对应物 |
| --- | --- |
| `bool button_states[8]` / `joyPad->status` | `buttons` / `buttons2` 输入总线（8 根并联输入线） |
| `SDL_GetKeyboardState` / `SDL_Event` 派发 | 平台层的输入同步 + 消抖 + 位图（见 `docs/hardware/09-input-and-pins.md`），**不在本模块内** |
| `state->strobe`（`bool` 电平） | `latch_strobe` 输入（**电平**，不是边沿） |
| `state->bit`（`unsigned int`） | `cnt1_q` / `cnt2_q`（4 位，饱和于 9） |
| `button_states[bit++]` | `sel_sr[0]` + `sr <= {fill_one, sr[7:1]}` |
| `if (bit > 7) return 1;` | `EXTRA_READ` 三种策略（见第 4 节） |
| `controller_push` 向两个端口循环 | `latch_strobe` 同时驱动 `sr1_q` 和 `sr2_q` |
| `addr - 0x4016` | `read_select` |

---

## 3. 接口合同

```verilog
module nes_controller #(
    parameter [1:0] EXTRA_READ = 2'd0
)(...);
```

### 3.1 端口

| 信号 | 方向 | 合同 |
| --- | --- | --- |
| `clk` | in | **CPU 时钟。** 一拍 = 一个 CPU 周期。模块假定外部已完成 CPU 分频，本模块不产生也不消费 `ce`。 |
| `reset` | in | 高有效**异步**复位。异步清零两个移位寄存器、两个并装载寄存器、两个读计数器和两个 `last` 寄存器。 |
| `latch_strobe` | in | **`$4016` 写入值的 bit0，即 `/PL` 的电平。** 为 1 时**每一个时钟沿**都把 `buttons` / `buttons2` 装进两个并装载寄存器和两个移位寄存器，并把两个读计数器清零。为 0 时移位寄存器保持最后装入的快照并继续移位。**是电平不是边沿。** |
| `read_strobe` | in | 读脉冲。**每个为高的时钟沿 = 一次读取 = 移出一位。** 典型用法是 1 拍脉冲；保持 3 拍高就是连续读 3 位。`latch_strobe` 为 1 时被忽略。 |
| `read_select` | in | 端口选择。`0` = `$4016`（1P），`1` = `$4017`（2P）。**只影响读，不影响 strobe。** |
| `buttons` | in | 1P 按钮位图，**bit0..bit7 = A, B, Select, Start, Up, Down, Left, Right**。这是"并联输入线"，一直活着。 |
| `buttons2` | in | 2P 按钮位图，位序同上。 |
| `data_bit` | out | 串行数据线，1 bit。**高 = 按下。** |
| `data_out` | out | `{7'b0, data_bit}`。**bit7:1 恒为 0**，open bus 由总线层建模。 |
| `dbg_sr1` / `dbg_sr2` | out | 两个移位寄存器当前值，8 位。 |
| `dbg_latch1` / `dbg_latch2` | out | 两个并装载寄存器当前值，8 位（最后一次 strobe 时的快照）。 |
| `dbg_cnt1` / `dbg_cnt2` | out | 自上次 strobe 以来的读取次数，**饱和于 9**。 |
| `dbg_selected_sr` / `dbg_selected_latch` / `dbg_selected_cnt` | out | 按 `read_select` 选出来的那一路，方便 testbench 只看一路。 |
| `dbg_past8` | out | `1` = 选中端口已经读过 8 次或更多。 |

### 3.2 位序合同

`buttons[0]` 是**第一次读**拿到的那一位。一次 strobe 之后连续 8 次读，按"第一次读 = word bit0"拼成的字节**正好等于 `buttons` 本身**：

```
buttons = 8'b1010_0101   (A=1 B=0 Select=1 Start=0 Up=0 Down=1 Left=0 Right=1)
读 #1  -> 1  (A)
读 #2  -> 0  (B)
读 #3  -> 1  (Select)
读 #4  -> 0  (Start)
读 #5  -> 0  (Up)
读 #6  -> 1  (Down)
读 #7  -> 0  (Left)
读 #8  -> 1  (Right)
拼成 word = 8'b1010_0101 = buttons
```

`tb_nes_controller` 对全部 256 种组合断言了这条等式（两个端口、三个 `EXTRA_READ` 实例各一遍）。

### 3.3 strobe 是电平敏感这件事必须被钉死

这是本模块最容易实现错的一条。三种情况都必须成立，testbench 逐条断言：

| 情况 | 期望 | RTL 里的机制 |
| --- | --- | --- |
| `latch_strobe` 保持为 1，按钮中途变化 | 每个时钟沿都重新装载；`data_bit` **组合地**跟随当前 `buttons[0]` | `else if (latch_now)` 分支每拍执行；`data_bit` 的第一级 mux 就是 `latch_strobe ? sel_buttons[0] : ...` |
| `latch_strobe` 为 1 时读 | 返回当前 `buttons[0]`，**移位寄存器和计数器都不动** | 读分支在 `else` 里，`latch_now` 优先 |
| `latch_strobe` 从 1 变 0 | 移位寄存器停在**最后一个装载过的**快照上 | 装载是每拍覆盖，所以"最后一个"就是最后一个时钟沿看到的那组按钮 |

注意 `data_bit` 的 live 路径是**组合**的，而并装载寄存器只在时钟沿更新。这是一个有意的分工：真实 4021 在 `/PL` 为低时 `OUT` 直接反映并联输入的 A 端（本模块用组合逻辑表达），而"拍照"这个动作本身是时钟沿上的事。

### 3.4 两个端口

- `latch_strobe` 是**一根**线，同时装载两个端口。这和 cNES 的 `controller_push` 广播循环、也和真实硬件一致。
- 读 `$4016` 只移位 `sr1_q`，读 `$4017` 只移位 `sr2_q`。两个计数器互相独立。
- `read_select` 本身没有任何副作用：不改变状态，只选 mux。testbench 专门用 20 拍只翻 `read_select` 而不发读选通来钉住这一点。

---

## 4. 第 9 次及以后的读取：三种策略

`EXTRA_READ` 是一个 2 位参数，**默认 `2'd0`**。它只影响第 9 次及以后的读，前 8 次在所有模式下逐位相同。

| `EXTRA_READ` | 名字 | 8 次之后返回 | 移位寄存器终值 | 依据 |
| --- | --- | --- | --- | --- |
| `2'd0`（默认） | 恒 1 | 永远 1 | `8'hFF` | cNES 的 `if (bit > 7) return 1;` 注释写的是 "input is tied to vcc"；Obara 的 `reg |= 0x80` 是同一件事的移位版本。真实硬件 `OUT` 空闲时被上拉。 |
| `2'd1` | 保持最后一位 | 永远 = 快照的 bit7（Right 的状态） | `8'h00` | "稳定值"策略：把第 8 次读出来的那一位锁住不动。 |
| `2'd2` | 移进 0 | 永远 0 | `8'h00` | 字面意义的 8 位移位寄存器耗尽后读 0，等价于"所有按钮都松开"。 |
| `2'd3` | 保留 | 同 `2'd0` | `8'hFF` | 未定义值，行为与 `2'd0` 相同。 |

实现上的分工：`EXTRA_READ` 决定移位寄存器**补进什么**（`fill_one`），`EXTRA_READ=1` 再额外用 `last*_q` 在输出 mux 上覆盖。`last*_q` 只在前 8 次读里更新（第 8 次读之后冻结），所以"保持的最后一位"确实是快照的第 8 位而不是继续漂移的移位寄存器内容。

**为什么默认是恒 1：** 真实 NES 手柄的数据线在 4021 内部计数器越过 8 之后由外部上拉电阻决定，实践中的观测值是 1。任何**正确**的游戏都只读 8 次，所以这个选择对兼容性没有影响；它是一个显式的、可被 testbench 穷举的建模旋钮，不是需要"猜对"的东西。`tb_nes_controller` 同时实例化三个实例（`EXTRA_READ` = 0/1/2），用 `0x02`（bit7=0，把恒 1 和另外两种分开）和 `0x80`（bit7=1，把保持位和移进 0 分开）两组组合把三种模式两两区分开。

---

## 5. 周期账

| 拍 | `latch_strobe` | `read_strobe` | 效果 |
| --- | --- | --- | --- |
| 1 | 0 -> 1 | 0 | 采样沿装载 `sr = buttons`，`cnt = 0` |
| 2 | 1 -> 0 | 0 | 快照冻结（`sr` 不变，因为这一拍 `latch_strobe=0`） |
| 3 | 0 | 1 | 采样沿 `sr <= {fill, sr[7:1]}`，`cnt` 加一 |
| 4..10 | 0 | 1 | 同上，共 8 次读 |
| 11.. | 0 | 1 | `cnt` 饱和于 9；输出按 `EXTRA_READ` |

一次完整轮询是 **10 个 CPU 周期**（2 写 + 8 读）。游戏每帧做一次，所以本模块的动态功耗约等于"每帧翻转 80 次"。

---

## 6. 从手柄物理层到本模块的边界

`docs/hardware/09-input-and-pins.md` 第 3.1 节把方案分成"直接并联输入"和"串行控制器接口"。**本模块对应的是前者。** 完整链路是：

```
物理按键 -> 输入同步（亚稳态） -> 消抖 -> 按下/释放沿 -> 8 bit 稳定位图 -> [本模块] -> $4016/$4017
                                                        ^
                                              平台层负责，不在本模块内
```

也就是说：**用户插的是一只物理 NES 手柄，但 FPGA 不实现 4021 协议**，而是把 8 根触点直接接进 FPGA 引脚。理由和 `09-input-and-pins.md` 里写的一样：省掉一个外部同步协议（`latch`/`clock`/`data` 的建立保持时间、data 浮空、时钟停止），而 CPU 侧看到的 $4016/$4017 行为**完全一样**。

代价是必须做对输入同步和消抖（`09-input-and-pins.md` 第 2 节），以及组合键的语义定义（第 5 节）。本模块**不检测鬼键、不做消抖、不做 CDC**：`buttons` 被假定已经是 8 位稳定电平。

---

## 7. 明确未实现 / 未建模

- **open bus**：`data_out[7:1]` 恒 0。真实硬件 bit1-4 是浮空/上拉，bit6 通常保留上一次访问的值。留给 `nes_cpu_bus`。
- **4021 的第 9 级**：真实 4021 有 9 个移位级（8 位 + 一个 tie-high 级），所以第 9 次读天然返回 1。本模块用 `EXTRA_READ` 参数显式建模这个行为，而不是真的造第 9 级——对 CPU 可见的结果一样，但 `dbg_sr` 停在 8 位，可观测性更好。
- **无手柄 / 故障手柄**：真实硬件可以检测"没接手柄"（数据线浮空被上拉成全 1），本模块的 `buttons` 输入被假定总是有效。全 1 输入恰好就是"什么都没按"，但没有独立的故障通道。
- **Zapper / 四个玩家**：$4016 上的模拟子系统和 NES 侧 4 个手柄位（`$4016` 的 bit0-3 复用）都没做。
- **`read_strobe` 的边沿约束**：模块接受任意宽度的高电平，每拍算一次读。系统层应该给 1 拍脉冲。
- **和 `nes_cpu_bus` / `nes_system` 的接线**：本模块不接总线。$4016/$4017 的地址译码、写 bit0 到 `latch_strobe`、读数据到 `data_out` 全部在系统层完成。
- **testbench 未覆盖**：`EXTRA_READ=3`（保留值）没有专门的 test task，虽然它和 `2'd0` 走完全相同的组合路径；两个端口的 `last2_q` / `dbg_cnt2` 饱和值没有单独逐拍核对（`dbg_cnt2` 只在 256 组合扫描里查过 `8`）；没有用真实的 `nes_cpu_bus` 驱动；没有和 PPU 的 sprite 0 hit 逻辑端到端联通（$4016 的 bit6-7 是扩展口，本模块不产生）。
- **`tools/sim_all.ps1` 和 ModelSim 的 `run_*_tb.do` 都没有 controller 通道**：这两个脚本不在本任务的写入范围内，没有改。
