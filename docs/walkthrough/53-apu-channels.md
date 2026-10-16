# 53 三个方波类 APU 通道：`nes_apu_pulse.v` / `nes_apu_triangle.v` / `nes_apu_noise.v`

APU（音频处理单元）里有五个发声通道。**其中一个通道干的事，本质上就是一台"分频器 + 一个小表"**：把一个以 CPU 周期为单位的倒计数器跑起来，数到 0 就把波形推进一格，于是输出一个不断变化的小电平。三个方波类通道（脉冲、三角、噪声）都是这个套路，只是"推进什么"和"怎么换算"不同。

这一篇把三个模块放在一起读，目的是让你看清：**它们的骨架一模一样，差别只在中间那块"波形发生器"。**

- 源码：[`rtl/nes_core/apu/nes_apu_pulse.v`](../../rtl/nes_core/apu/nes_apu_pulse.v)、[`nes_apu_triangle.v`](../../rtl/nes_core/apu/nes_apu_triangle.v)、[`nes_apu_noise.v`](../../rtl/nes_core/apu/nes_apu_noise.v)
- 合同与逐字段对照：[`../modules/apu-full.md`](../modules/apu-full.md)（§1.2 那张"换算表"是全篇重点）
- 共用查表：[`11-alu-lut.md`](11-alu-lut.md)（`nes_apu_length_lut.v`）
- 测试目标：`apu-core`（只 elaborate）、`apu-tb`（跑 `tb_nes_apu2a03.v`），见 [`tools/sim_all.ps1`](../../tools/sim_all.ps1)
- 端口极性、复位值、时间轴合同以 [`tb/apu/README.md`](../../tb/apu/README.md) 为准

---

## 1. 先认识"上游和下游"

这三个模块都**只被顶层 `nes_apu2a03.v` 例化**，各出现一到两次（Pulse 出现两次，即 Pulse 1/2）：

```text
CPU 写 $4000/$4004 ─┬─► [u_pulse1 / u_pulse2  nes_apu_pulse]  (ONE_COMP=1/0)
CPU 写 $4001/$4005 ─┘
CPU 写 $4008-$400B ───► [u_triangle  nes_apu_triangle]
CPU 写 $400C-$400F ───► [u_noise     nes_apu_noise]
frame sequencer ─┐
                 ├─► ce / quarter / half（定时）
$4015 enable ────┘─► enable / enable_wr / enable_wr_data
   每个通道 ─────────► out_level(4) / length_cnt / period / reg_dout ─► 顶层 mixer
```

要点：

- **时间基准来自顶层**，不在通道里。`nes_apu2a03.v` 用 frame sequencer 产生 `quarter`、`half` 两个"事件沿"，再把系统的 `ce`（CPU cycle enable）一起发给每个通道。通道自己只有"倒计数"。
- **配置来自 CPU 寄存器**。顶层把 `reg_we`（本通道被写）、`reg_index[1:0]`、`reg_din[7:0]` 转发进来；通道写完改变自己的状态，并组合地给出 `reg_dout` 供 CPU 读回。
- **`$4015` 是总开关**。`enable` 是本通道的开关位，`enable_wr` 表示"这次写的是 `$4015`"，`enable_wr_data` 是那一位的值（bit0 给 Pulse 1……bit2 给 Triangle、bit3 给 Noise）。输出 `out_level` 是 4 位整数电平（0~15），顶层把它（Pulse 是两路之和、Triangle 乘 3）送进混音表。

---

## 2. 三个模块的骨架（只贴关键片段）

三个文件的"章节顺序"几乎一致：① 一组相同的端口；② `length_write_now` / `length_lut_index` / `length_lut_value`，并例化同一个 `nes_apu_length_lut`；③ 一个 `reg_dout` 组合读回块；④ 一个 `out_level` 组合输出块；⑤ 一个大的时钟块，里面依次是**复位 → 寄存器写 → `if (ce)` 下的各种计数**。

差异集中在"中间那块波形发生器"：

```verilog
// pulse：8 步 duty 相位 + 4 位预分频 + sweep
reg [2:0] duty_step;   reg [3:0] timer_prescale;
assign duty_out = duty_bit(duty, duty_step);
assign sweep_mute = (period < 11'd8) || (sweep_target > 14'sd2047);

// triangle：32 步对称相位 + 无预分频
reg [4:0] seq_step;
assign silent = !enable || (length_cnt == 8'd0) || (linear_cnt == 7'd0);

// noise：15 位 LFSR，无相位表
reg [14:0] lfsr;
assign lfsr_feedback = lfsr[0] ^ lfsr[mode ? 6 : 1];
assign mute = (period == 12'd0);
```

下面按通道分节精读。**通用部件（length/envelope/寄存器）先在 pulse 里讲透，triangle/noise 只讲不同的部分。**

---

## 3. 逐段精读

### 3.1 公共骨架一：length counter 与共用查表

三个通道有一模一样的三行：

```verilog
assign length_write_now = reg_we && (reg_index == 2'd3);
assign length_lut_index = length_write_now ? reg_din[7:3] : len_index;

nes_apu_length_lut u_length_lut (
    .index(length_lut_index),
    .value(length_lut_value)
);
```

读法：

- `reg_index` 是通道内 4 个寄存器的小编号（`2'd0..2'd3`）。**编号 3 就是本通道的"length 寄存器"**（Pulse 是 `$4003/$4007`，Triangle 是 `$400B`，Noise 是 `$400F`）。写的瞬间 `length_write_now=1`。
- 查表的**下标**就是写入字节的高 5 位 `reg_din[7:3]`；查表得到 `length_lut_value`（单位是"半帧"，32 项表见 [`11-alu-lut.md`](11-alu-lut.md)）。
- 直接查这个值而不先用 `len_index`，是为了让"同一拍写 length"能立刻拿到新值——`len_index` 是寄存器，这一拍还没更新。

装载不是马上发生的，而是**先挂起、下一个 `ce` 再装**（pulse 里）：

```verilog
default: begin                       // reg_index == 3
    len_index <= reg_din[7:3];
    period[10:8] <= reg_din[2:0];
    duty_step <= 3'd0;               // 写 length 同时复位 duty 相位
    env_decay <= 4'd15;              // 同时把 envelope 重置到最大
    if (enable) begin
        len_pending <= length_lut_value;
        len_pending_valid <= 1'b1;
    end
end

// 在同一个大时钟块里、下一个 ce 沿才真正装载：
if (ce && len_pending_valid) begin
    length_cnt <= len_pending;
    len_pending_valid <= 1'b0;
end
```

- `len_pending` + `len_pending_valid` 是"待装载值"和它的有效标志。用显式标志而不是拿 `0` 当地图，因为 `length_lut_value` 的合法值里没有 0 但语义上 0 不能当"没东西"（[`../modules/apu-full.md`](../modules/apu-full.md) §5 第 4 条）。
- **只有 `enable=1` 才装载**：`$4015` 对应位为 0 时写 length 寄存器不生效。这是合同（`tb/apu/README.md` 每个通道一节都写了）。
- 递减发生在 **half（半帧）**，且要满足三个条件：

```verilog
if ((length_cnt != 8'd0) && !halt && !length_write_now)
    length_cnt <= length_cnt - 8'd1;
```

  `halt` 是"暂停 length 递减"位（Pulse 是 `$4000[5]`，Noise 是 `$400C[5]`，Triangle 叫 `control` 即 `$4008[7]`）。`!length_write_now` 保证"写入的那一拍不递减"。减到 0 后通道就静音（见下面的 `out_level`）。

- `enable_wr && !enable_wr_data` → `length_cnt <= 0`：顶层写 `$4015` 且把本通道关掉时，**立刻清 0**。注意它不在 `ce` 分支里——`$4015` 的效果不受 `ce` 门控。

### 3.2 公共骨架二：envelope（音量衰减）

Pulse 和 Noise 各有一份完全相同的 envelope：

```verilog
assign env_level = const_volume ? vol : env_decay;
```

- `const_volume=1` 时音量用 `vol`（`$4000[4]` 选的固定值），否则用 `env_decay`（自动衰减值）。
- 写 `$4000/$400C` 时：`env_period <= reg_din[3:0]`、`env_restart <= 1'b1`；如果 period 写成 0，分频器直接设成 15。`env_restart` 是"下一次 quarter 立刻重装"的请求标志。
- 每个 **quarter（四分之一帧）**处理一次，逻辑是"分频器归零才动一个衰减步"：

```verilog
if (quarter) begin
    if (env_restart) begin                 // 寄存器刚被写：重装
        env_decay <= 4'd15;
        env_div <= (env_period == 4'd0) ? 4'd15 : env_period;
        env_restart <= 1'b0;
    end else if (env_div != 4'd0)          // 还没到点：分频器减一
        env_div <= env_div - 4'd1;
    else begin                             // 到点：重装并衰减一格
        env_div <= (env_period == 4'd0) ? 4'd15 : env_period;
        if (env_decay != 4'd0)  env_decay <= env_decay - 4'd1;
        else if (halt)          env_decay <= 4'd15;   // halt=1 时循环回绕
    end
end
```

把这段和 [`../modules/apu-full.md`](../modules/apu-full.md) §2.1 对照：软件模拟器的 `clock_divider_inverse` 在这里被拆成了"重装值 `env_period` + 当前值 `env_div` + 一个 `env_restart` 请求"，因为寄存器写必须能在**下一个 quarter 沿**生效。`halt` 同时是 length 的暂停位，所以 `halt=1` 时 length 冻结、音量还要循环回绕。

### 3.3 Pulse：duty 表 + 4 位预分频 + sweep

**(a) duty 表。** pulse 的波形是一个 8 步循环，每步是 0 或 1，由 `duty` 两 bit 选四种占空比，用函数实现（不存表）：

```verilog
function duty_bit;  input [1:0] duty_sel;  input [2:0] step;  begin
    case (duty_sel)
        2'd0: duty_bit = (step == 3'd1);                       // 12.5%
        2'd1: duty_bit = (step == 3'd1) || (step == 3'd2);     // 25%
        2'd2: duty_bit = (step >= 3'd1) && (step <= 3'd4);     // 50%
        default: duty_bit = (step == 3'd0) || (step >= 3'd3);  // 25%（反相）
    endcase
end endfunction
assign duty_out = duty_bit(duty, duty_step);
```

`duty_step` 是一个 3 位自然回绕计数器（`duty_step + 3'd1`，7 到 0 自动回卷），相位在这 8 步里循环。写 `$4003/$4007` 会把它清 0（上面 3.1 那段）。

**(b) 定时器：16 分频再数 period。** 这是三个通道里唯一带预分频的：

```verilog
if (timer_prescale == 4'd15) begin
    timer_prescale <= 4'd0;
    if (timer_cnt == 11'd0) begin timer_cnt <= period; duty_step <= duty_step + 3'd1; end
    else                          timer_cnt <= timer_cnt - 11'd1;
end else
    timer_prescale <= timer_prescale + 4'd1;
```

`timer_prescale` 走满 16 拍才给 `timer_cnt` 一次机会，所以**一个 duty step = `16 × (period + 1)` 个 `ce`**。这正是 [`../modules/apu-full.md`](../modules/apu-full.md) §1.2 表里 `period = (真值周期/16) - 1` 的来历；如果照抄软件 `Divider` 的 `period`（半速写法）会差 8 倍。整个自增逻辑包在 `if (ce)` 里，`ce=0` 时全部冻结。

**(c) 输出。** 静音条件有好几层：

```verilog
always @* begin
    if (enable && (length_cnt != 8'd0) && !sweep_mute && duty_out)
        out_level = env_level;
    else
        out_level = 4'd0;
end
```

四个条件全满足才发声：通道开关打开、length 没数完、sweep 没静音、当前 duty 相位是 1。`sweep_mute`：

```verilog
assign sweep_mute = (period < 11'd8) || (sweep_target > 14'sd2047);
```

即"周期太小"或"sweep 想把它推到合法范围之外"就静音。

**(d) sweep（周期扫描）。** 目标周期是纯组合算出来的，用**有符号**运算（`sweep_shift` = 右移几位，`sweep_neg` 决定加/减，`ONE_COMP` 参数让 Pulse 1 的负扫描多减 1）：

```verilog
sweep_period_signed = $signed({3'b000, period});
sweep_change = sweep_period_signed >>> sweep_shift;   // 右移 = 除以 2^shift
if (sweep_neg)
    sweep_target = sweep_period_signed - sweep_change - (ONE_COMP ? 14'sd1 : 14'sd0);
else
    sweep_target = sweep_period_signed + sweep_change;
```

真正改 `period` 发生在 **half**（`sweep_div_reload = $4001[6:4] + 1`，所以寄存器 0 表示每 2 个 half frame 才动一次；`sweep_shift=0` 直接门控不改周期）：

```verilog
if (half) begin
    if (sweep_reload)         begin sweep_reload <= 1'b0; sweep_div <= 4'd0; end
    else if (sweep_div != 4'd0)    sweep_div <= sweep_div - 4'd1;
    else begin
        sweep_div <= sweep_div_reload;
        if (sweep_enabled && (sweep_shift != 3'd0) && !sweep_mute)
            period <= sweep_target_period;                // 应用新周期
    end
end
```

### 3.4 Triangle：32 步阶梯波形 + 线性计数器

**(a) 32 步序列，退化成一次减法。** 三角波是 `15 14 … 1 0 0 1 … 14 15` 的 32 步对称序列，**不存表**：

```verilog
function [3:0] tri_sequence;  input [4:0] step;  begin
    case (step[4])
        1'b0:    tri_sequence = 4'd15 - {1'b0, step[3:0]};  // 前半：递减
        default: tri_sequence = {1'b0, step[3:0]};          // 后半：递增
    endcase
end endfunction
```

`step[4]`（第 5 位）选前半周/后半周，`step[3:0]` 是半周内的位置。前半周是 `15 - step[3:0]`，后半周就是 `step[3:0]`——这就是"对称性让 32 项表退化成一个减法"。

**(b) 定时器：无预分频。** Triangle **没有** `timer_prescale`，`period` 寄存器值就是真实周期：

```verilog
assign timer_reload = (period == 11'd0) ? 11'd0 : (period - 11'd1);
...
if (timer_cnt != 11'd0) timer_cnt <= timer_cnt - 11'd1;
else begin
    timer_cnt <= timer_reload;
    if (!silent) seq_step <= seq_step + 5'd1;   // 只有不静音才推进
end
```

和 pulse 的 `16×(period+1)` 是**两套约定**：triangle 一次 step ≈ `period` 个 `ce`。`seq_step` 是 5 位自然回绕（0~31）。注意 `if (!silent)`：线性计数器为 0 时 `timer_cnt` 照跑（内部状态继续变化），但 `seq_step` 冻结、输出静音——这是 NESdev 明确的行为。

**(c) 线性计数器。** 三角形用"线性计数器"控制起音和释放，由 **quarter** 驱动，7 位：

```verilog
if (quarter) begin
    if (linear_reload_flag)
        linear_cnt <= linear_reload;     // 先 reload
    else if (linear_cnt != 7'd0)
        linear_cnt <= linear_cnt - 7'd1;
    if (!control)
        linear_reload_flag <= 1'b0;      // 再看 control 决定是否清 flag
end
```

顺序很关键：**先 reload、再看 `control` 是否清 flag**。`linear_reload` 是 `$4008[6:0]`；`linear_reload_flag` 由写 `$400A` / `$400B` 置起（注意 **`$4008` 不置**，合同里专门写了）。`control`（`$4008[7]`）为 1 时 flag 保持，于是每个 quarter 都重装，`linear_cnt` 恒为 reload 值；`control` 为 0 时 flag 被清，之后每 quarter 减 1，减到 0 通道静音。

**(d) 静音与输出。**

```verilog
assign silent = !enable || (length_cnt == 8'd0) || (linear_cnt == 7'd0);

always @* begin
    if (silent) out_level = 4'd0;
    else        out_level = tri_sequence(seq_step);
end
```

和 pulse 不同：triangle 用的是**线性计数器**而不是 envelope，`control` 同时兼任 length halt（half 那段的 `!control` 就是 `!halt`）。写 `$400A/$400B` 会置 reload flag；写 `$400B` 才会装 length（本项目按 NESdev，`$400A` 不装，见 [`../modules/apu-full.md`](../modules/apu-full.md) §4.1）。

### 3.5 Noise：15 位 LFSR + mode 抽头

**(a) LFSR。** 噪声不是相位表，而是一个**线性反馈移位寄存器**，数满周期就移位并塞入一个反馈位：

```verilog
assign lfsr_feedback = lfsr[0] ^ lfsr[mode ? 6 : 1];
assign lfsr_output = lfsr[0];
...
if (timer_cnt != 12'd0)  timer_cnt <= timer_cnt - 12'd1;
else begin
    timer_cnt <= timer_reload;
    lfsr <= {lfsr_feedback, lfsr[14:1]};   // 反馈位进最高位，整体右移
end

if (enable && (length_cnt != 8'd0) && !mute && !lfsr_output)   // out_level 组合块
    out_level = env_level;
else
    out_level = 4'd0;
```

- 寄存器是 15 位（`lfsr[14:0]`），复位值是 `15'd1`，之后永不进 0。
- 反馈抽头由 `mode` 选：`mode=0` 抽 bit1，`mode=1` 抽 bit6。这对应 NES 的"短模式/长模式"（93/31 抽头），**只影响反馈，不影响周期表**。`mode` 来自 `$400E[7]`。
- 输出位取最低位 `lfsr[0]`，但门控是 `!lfsr_output`（bit0=0 才发声）。

**(b) 周期来自 16 项表。** Noise 的 `period` 不是寄存器直接给的，而是查一张 NTSC 表（无预分频）：

```verilog
2'd2: begin
    mode <= reg_din[7];
    period_index <= reg_din[3:0];
    period <= noise_period_ntsc(reg_din[3:0]);
    timer_reload <= noise_period_ntsc(reg_din[3:0]) - 12'd1;
end
```

`noise_period_ntsc` 是 `4,8,16,32,64,96,128,160,202,254,380,508,762,1016,2034,4068`。`period` 存的是**表值本身**（给 debug 看），`timer_reload` 存 `表值-1`（给倒计数器用）。`$400E[3:0]` 是 `period_index`。

**(c) 显式 mute / envelope / length。** 就一行：`assign mute = (period == 12'd0);`。

复位后没写过 `$400E`，`period=0`，此时每个 `ce` 都会移位一次——本实现用这条显式门控把它静音。这是**本仓库自己加的一条**，不是 NESdev 规则（[`../modules/apu-full.md`](../modules/apu-full.md) §4.3）。envelope 与 pulse 完全一致；`halt`（`$400C[5]`）同时冻结 length。写 `$400F` 会把 `env_decay` 置 15（重启包络）。

---

## 4. 端口表（合并，标模块）

**三个模块共有的端口：**

| 端口 | 方向 | 位宽 | 作用 |
|---|---|---|---|
| `clk` / `reset` | in | 1 | 唯一时钟；高有效**异步**复位 |
| `ce` | in | 1 | CPU cycle enable；所有计数只在此推进，`ce=0` 冻结 |
| `quarter` / `half` | in | 1 | frame sequencer 的四分之一帧 / 半帧事件沿 |
| `enable` / `enable_wr` / `enable_wr_data` | in | 1 | `$4015` 开关位 / 本拍是否写 `$4015` / 那一位的值（0 表示关） |
| `reg_we` / `reg_index[1:0]` / `reg_din[7:0]` | in | — | 通道寄存器写 |
| `reg_dout[7:0]` / `length_cnt[7:0]` / `out_level[3:0]` / `period` | out | — | 寄存器读回 / length 当前值 / 4 位输出电平 / 周期寄存器（Noise 的 `period` 是 12 位） |

**各模块独有端口（大多为 debug 引出，顶层再转成 `dbg_*`，不是功能必需的）：**

- **Pulse**：`mute`、`volume`、`duty_step[2:0]`、`env_decay[3:0]`、`env_div[3:0]`（out），参数 `ONE_COMP`。
- **Triangle**：`seq_step[4:0]`、`linear_cnt[6:0]`、`linear_reload_flag`（out）。**Noise**：`lfsr[14:0]`、`mode`、`const_volume`、`volume[3:0]`、`halt`、`env_decay[3:0]`、`env_div[3:0]`、`mute`（out）。

---

## 5. 以 pulse 为例：一个 timer 周期怎么产生一个输出 bit

把 §3.3(b)(c) 连起来，从 `period` 被写成一个值开始，走一遍"一个 duty step 的产生"：

1. **CPU 写 `$4002`**（`reg_index=2`）→ `period[7:0] <= reg_din`；再写 `$4003`（`reg_index=3`）→ `period[10:8] <= reg_din[2:0]`，同时 `duty_step <= 0`、`env_decay <= 15`、挂起 length。
2. **下一个 `ce` 沿**：`len_pending_valid=1` → `length_cnt <= length_lut_value`（假如此时 `enable=1`）。
3. **接着每 16 个 `ce`**：`timer_prescale` 从 0 数到 15；数满的那一拍预分频回 0，若 `timer_cnt==0` 则 `timer_cnt <= period` 且 `duty_step <= duty_step+1`，否则 `timer_cnt` 减 1。
4. **一个 step 的总长** = 16 次预分频 `×`（`period` 次减 1 再加一次重装）= **`16 × (period + 1)` 个 `ce`**。
5. **`duty_step` 一变**，`duty_out` 由 `duty_bit(duty, duty_step)` 组合重算，`out_level` 在 `enable && length_cnt!=0 && !sweep_mute && duty_out` 时等于 `env_level`，否则 0；`half` 到来时 `length_cnt` 减 1、sweep 也可能把 `period` 换成 `sweep_target_period`，于是循环回到第 3 步。

一句话：**`period` 决定"多久推一格"，`duty` 决定"这一格是 1 还是 0"，`enable/length/halt` 决定"整条链路通不通"，三者相乘才得到 `out_level`。**

---

## 6. 常见疑问

**Q：为什么 clock 块里套一层 `if (ce)`，`quarter`/`half` 还在里面再判断？**
A：铁律是**一个时钟 + `ce` 使能**，不做门控时钟（[`01-verilog-basics.md`](01-verilog-basics.md) §9）。`ce=0` 时所有计数器"冻结"（`tb_nes_apu2a03.v` 的 `CE=0 FREEZE` 组专门断言这点）；`quarter`/`half` 是"事件沿"，放进 `ce` 分支才能和计数器共用同一个时间基准，于是 length/envelope/sweep 的时序都对齐到 CPU 周期。

**Q：写 length 寄存器明明是"写"，为什么 `length_cnt` 要等到下一个 `ce` 才更新？**
A：因为合同要求"写入的那个 `ce` 沿不立刻改 `counter`"（和软件模拟器的 `new_counter` 语义一致）。用 `len_pending` + `len_pending_valid` 显式表达这个一拍延迟。

**Q：`halt`/`control` 到底是谁的位？**
A：Pulse 的 `$4000[5]`、Noise 的 `$400C[5]` 叫 `halt`；Triangle 的 `$4008[7]` 叫 `control`。它们语义相同：**既暂停 length 递减**（half 那段），**又影响 envelope/线性计数器**（quarter 那段）。

**Q：Triangle 的 `period` 和 Pulse 的 `period` 能互相照抄吗？**
A：不能。Pulse 是 `16×(period+1)`，Triangle 是 `period`（无预分频），Noise/DMC 是 `表值或表值-1`。这正是 [`../modules/apu-full.md`](../modules/apu-full.md) §1.2 那张表要强调的"四种不同换算"。

---

## 7. 你应该带走的三件事

1. **三个通道共享同一副骨架**：`length counter + 共用 LUT + reg 读回 + out_level 组合输出 + 一个 `ce` 门控的大时钟块`。差别只在中间的波形发生器（duty 表 / 32 步阶梯 / LFSR）。
2. **分频 timer 是"秒表"，波形相位是"指针"**：Pulse 用 4 位预分频 + 11 位 timer，Triangle 无预分频，Noise 用 16 项周期表；三者都是"数到 0 推一格"，但换算规则完全不同，不能互相照抄。
3. **控制位决定"通不通"而非"是什么波形"**：`enable`（`$4015`）、`halt`/`control`、`length_cnt`、`sweep_mute`/`silent`/`mute` 都是门控；真正的波形只由相位/表决定。

下一篇 [`54-apu-dmc.md`](54-apu-dmc.md) 看第四个通道 `nes_apu_dmc.v`：它第一次需要**从外部取数据**，因此引入了跨模块握手（`dmc_bus_req` / `dmc_ack`），是三个方波通道里完全没有的一个维度。
