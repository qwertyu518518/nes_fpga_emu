# NES peripheral testbenches

本目录有 7 个自检 testbench，覆盖片外外设适配：WM8960 codec 的 I2C 配置、SD/eMMC 的 SPI 命令帧、跨时钟域 FIFO、I2S 位序列化与装配层、电容触摸输入，以及 Zynq-7020 的音频 lane（decimator + FIFO + I2S + codec 配置）。除 `tb_nes_audio_lane.v` 要 elaborate 整条 zynq 顶层之外，其余都不下载 ROM、不读外部文件。

这一组的目标可以用 `.\tools\sim_all.ps1 -Mode peripheral` 一次跑完，其中 `peripheral-core`、`sd-spi-cmd-core`、`cdc-fifo-core`、`i2s-shifter-core`、`audio-i2s-core` 是**纯 elaboration 目标**（`Run = $false`，只编译 RTL 不跑仿真，用来确认模块可 elaborate）。

| testbench | 被测模块 | sim_all 目标 id |
| --- | --- | --- |
| `tb_wm8960_i2c.v` | `rtl/nes_core/peripheral/wm8960_i2c.v` | `peripheral-i2c` |
| `tb_sd_spi_cmd.v` | `rtl/nes_core/peripheral/sd_spi_cmd.v` | `sd-spi-cmd-tb` |
| `tb_nes_cdc_fifo.v` | `rtl/nes_core/peripheral/nes_cdc_fifo.v` | `cdc-fifo-tb` |
| `tb_nes_i2s_shifter.v` | `rtl/nes_core/peripheral/nes_i2s_shifter.v` | `i2s-shifter-tb` |
| `tb_nes_audio_i2s.v` | `rtl/nes_core/peripheral/nes_audio_i2s.v`（+ `nes_cdc_fifo` + `nes_i2s_shifter`） | `audio-i2s-tb` |
| `tb_nes_touch_input.v` | `rtl/nes_core/peripheral/nes_touch_input.v` | `touch-input-tb` |
| `tb_nes_audio_lane.v` | `rtl/platform/zynq/nes_zynq_top.v` 内的音频 lane | `audio-lane-tb` |

对应的设计文档在 `docs/modules/wm8960-i2c.md`、`docs/modules/sd-spi-cmd.md`、`docs/modules/cdc-fifo.md`、`docs/modules/i2s-audio.md`、`docs/modules/touch-input.md`、`docs/modules/zynq-platform.md`。

---

# 1. `tb_wm8960_i2c.v`：WM8960 codec 配置 I2C 主机

被测 `wm8960_i2c`，目标 `peripheral-i2c`（纯 elaboration 为 `peripheral-core`，`-g2001`）。TB 把 codec 建模成一个 I2C slave：解析开漏总线上的 START / STOP / 字节 / ACK，在每个 SCL 上升沿采样 SDA，并把每一笔写事务解码成 `[DEV_ADDR+W, reg_addr, wdata]` 三元组。

**控制字解码**是这套断言的要点，而且**故意不用直觉拆法**：WM8960 一帧是 16 bit 控制字，byte0 = 7 位设备地址 + R/W，byte1 = B15..B8（其中 [7:1] 是 7 位寄存器地址，[0] 是数据 bit8），byte2 = data[7:0]。TB 按这个拆法解码，并把结果与**硬编码的 WM8960_v4.4 寄存器表**逐项比对，而不是与 DUT 自己的 `CFG_REG()` / `CFG_DATA()` 比——后者只会证明状态机走完自己的表，证明不了表对 WM8960 正确。

断言覆盖：

- **物理层**：tSU;DAT、tHD;DAT、tSU;STA、tHD;STA、tSU;STO、tHD;STO、tBUF、SCL 位周期、ACK 槽必须留出的 1 bit SDA 释放窗口；并断言主机从不把 SCL/SDA 源出高电平（开漏合同）。
- **上电配置表**：START 数、STOP 数、解码出的事务数都与表条数一致；表第 0 项必须是 R15（0Fh）= 000；每条地址都是 `DEV`、方向都是写、寄存器与数据与数据手册序列一致；R26（DACL）/ R34（LD2LO）/ R37（RD2RO）的 data bit8 必须置位、R5（DACMU）必须清零；序列期间不得出现 NACK/error，`wr_done` 不得脉冲；`cfg_done` 在表跑完后保持高。
- **单笔写**：`wr_done` 必须是单拍脉冲；设备地址、写方向、寄存器、数据解码正确。
- **9 bit 写**：R25 写数据 `data[8]=1` 时 byte1/byte2 的拆法正确（`byte1 = {7'h25, 1'b1}`、`byte2 = data[7:0]`），解码回 25=100。
- **背靠背写**：连续两笔写产生两笔事务，第二笔解码正确。
- **NACK 路径**：NACK 会置 `error`、不记事务、不脉冲 `wr_done`、用 STOP 收尾、总线回 idle。
- **busy 期间丢请求**：忙时来的 `wr_req` 不产生事务、不脉冲 `wr_done`，在途写不受扰动。
- 顶部有 `global timeout` 兜底。

# 2. `tb_sd_spi_cmd.v`：SD/eMMC SPI 命令帧发送器

被测 `sd_spi_cmd`，目标 `sd-spi-cmd-tb`（纯 elaboration 为 `sd-spi-cmd-core`）。TB 的卡模型在 CS 低时对每个 `spi_clk` 上升沿采样 MOSI、逐位重建六个命令字节，并且只在下降沿改 MISO。

断言覆盖：

- **帧内容**：byte0 = `{2'b01, cmd[5:0]}`；32 位参数正确；byte5 = `{CRC7, 1'b1}`。参考 CRC7 用长除法（乘 x^7 再对 0x89 约减）独立算出，不是复用 DUT 的移位寄存器。
- **逐位流**：前 48 位与期望逐位比对，其后 48 位 dummy 必须全为 1；一帧共 120 个时钟。
- **响应**：byte6 / byte7 承载预置的 resp0 / resp1。
- **CMD00 特例**：`CMD00` 的 CRC 字节必须等于 SD 规范值 `8'h95`。
- **分频与占空比**：`spi_clk` 半周期 = `CLK_HZ/(2*SPI_HZ)` ±1 拍，占空比 50%，一帧 121 上升沿 / 121 下降沿。
- **握手时序**：`busy` 跟随 `start`，`start` 当拍 CS 拉低；帧中再来 `start` 不重开帧；`done` 必须单拍、`done` 时 CS 已高、`busy` 已落。
- **计数**：`done` 脉冲数 = 帧数，CS 拉低次数 = 帧数 + 1。
- **帧中复位**：复位后 cs / busy 都回空闲。
- **`crc_check_en`**：应答全 0 时 `crc7_err=0`；应答全 1 时 `crc7_err=0`；坏 CRC7 的应答必须把 `crc7_err` 置 1。
- 有看门狗（`cyc > 2000000` 判无进展）。

# 3. `tb_nes_cdc_fifo.v`：异步跨时钟域 FIFO

被测 `nes_cdc_fifo`，目标 `cdc-fifo-tb`（**标准是 `-g2001`**，纯 elaboration 为 `cdc-fifo-core`）。用 10 ns 写时钟对 14 ns 读时钟，两者相位与比例持续漂移，让每个交叉都被两种相位扫过。参考模型由 DUT **实际接受**的读写驱动（在每个时钟的负沿采样，正是下一个正沿要用的 flag 值），所以模型与 DUT 的占用必须完全一致，一次匹配就证明没有条目丢失、重复或乱序。

分五个阶段：

- **阶段 0**：联合复位后的 flag 极性（`wr_full=0`、`rd_empty=1`、`rd_data=0`，且 flag 是被驱动的）。
- **阶段 1**：写满到深度，检查 `wr_full` 的时点（不早不晚）、溢出字被拒绝（既不被写入也不粘住 `wr_full`），再 drain 并逐值比对。
- **阶段 2**：空 FIFO 上读不得移动 `rd_ptr`、不得扰动 `rd_data`，flag 不变。
- **阶段 3**：10000 次交错的随机读写决策，逐值比对，最后 drain 并检查无残留。
- **阶段 4**：写侧、读侧各自单独复位后都不挂死、flag 可恢复，再联合复位做一次干净的 32 项往返。

关键断言名：`WR_ACCEPT` / `RD_ACCEPT` / `RD_DATA`、`FULL_EARLY` / `FULL_LATE` / `FULL_STICKY`、`OVERFLOW_STORED`、`EMPTY_FLAG` / `EMPTY_POINTER`、`RD_HOLD`（空时 `rd_data` 不得变）、`RD_RESET` / `WR_RESET` 的恢复与 `*_HANG` 超时、以及全局 `TB_TIMEOUT` 兜底。

# 4. `tb_nes_i2s_shifter.v`：I2S 位序列化器

被测 `nes_i2s_shifter`，目标 `i2s-shifter-tb`（纯 elaboration 为 `i2s-shifter-core`）。两个实例同激励，一个 `BIT_REVERSED=0`、一个 `=1`。参考模型按**通道语义**写，不是照 RTL 的索引算术抄。

断言覆盖：

- **位流**：每个 ce 使能的时钟都与模型比对——MSB 实例发 `left[15]..left[0]` 再接 `right[15]..right[0]`，reversed 实例每通道 LSB 先发；两种情况左通道都占前 16 位。通道交换、卡位、位序错误、丢 ce gap、坏样点都会失败。
- **`out_lrck`**：逐位检查，并在一轮结束时要求翻转正好发生在第 17 位。
- **`busy` / `out_valid` / `dropped`**：在每个状态转换处检查。ce gap 期间四个流引脚必须冻结，位计数不得前进。
- **背靠背**：5 个样点按 160 bit 的平面流整体比对，防止"新样点覆盖在途样点"被掩盖。
- **复位**：清 `busy` / `out_valid` / `out_bit` / `out_lrck` / `dropped`；释放后保持空闲。
- **`dropped`**：busy 期间来的 `sample_valid` 置 `dropped`（reversed 实例同样），且不扰动在途流；`dropped` 是 sticky，直到复位才清。

# 5. `tb_nes_audio_i2s.v`：I2S 装配层

被测 `nes_audio_i2s`，目标 `audio-i2s-tb`（纯 elaboration 为 `audio-i2s-core`）。时钟：`wr_clk` 10 ns，`rd_clk` 与 `mclk` 20 ns，`BCLK_DIV=1` 使 bclk 与 `rd_clk` 同周期同相位；一个样点是 32 个序列化时钟 = 640 ns，`rd_ce` 恒高。四个样点在连续的 `wr_clk` 上一次性写入 FIFO，让"无空隙"成为**唯一合法**结果，从而可以**断言**而不是容忍这个空隙。

断言覆盖：

- **无空隙**：每个 `sample_valid` 为高的 bclk 上升沿收一位；在第一个与最后一个这样的 strobe 之间，任何 `sample_valid` 为低的 bclk 上升沿都是致命 gap，收集器不能靠跳过隐藏空闲。
- **数据**：收集到的 128 位逐个与按通道语义建的参考模型比对。
- **`lrck`**：每个 32 位样点内 16 位低 + 16 位高，翻转落在每个样点的第 17 位（也就是流的 bit 索引 16/48/80/112），四个样点的四组 16/16 切分与四次翻转全部检查。
- **`dropped`** 必须始终为 0（背压在可观测层面的形式：样点不丢、FIFO 不满）。
- `underflow` **不检查**，且**预期**会置位（读者一次只持有一样点，样点之间 FIFO 会空）。
- 有全局超时。

# 6. `tb_nes_touch_input.v`：电容触摸 NES 输入

被测 `nes_touch_input`，目标 `touch-input-tb`（**标准是 `-g2001`**）。TB 用一个行为级 GT9147 I2C slave 驱动厂商协议，检查区域映射、按键消抖、由 TPAD 驱动的 Start/Select 替换、复位序列、解码出的事务流、NACK 恢复路径，以及一次性自标定。

- **自标定是本 bench 的重点**：驱动不再假定 800x480，而是问控制器报告的是哪一帧。I2C 模型用每个场景各自的寄存器值应答这些读。五个场景：1) 799x479、`Module_Switch1` bit3 清（诚实的 800x480 模组）；2) 1023x639、`Module_Switch1` bit3 置（轴交换，由坐标回来时被交换证明）；3) 479x271、bit3 清（同族 ATK-4342）；4) 每个标定字节都 NACK（回退常量）；5) 每个标定字节全 1（回退常量）。场景 2 用 `8'h68`（bit3 置且 bit6/bit5 也置），猜错字段布局或读错位都会得到不同答案而失败。
- **读取地址/方向/字节数**：每个场景都断言三次标定读的地址、方向与字节数，并在之后断言各发生且仅发生一次（"多读五个寄存器"最典型的失效就是静默错址）。
- **非空洞**：区域扫描由控制器报告的切点驱动，并断言至少有一个场景落在不同的数字上——否则测不出"工作正常的标定"与"硬编码常量"的差别。
- **替换与触摸路径分开**：面板报告保持时两个键必须仍在 A/B（把替换门在 `touch_valid` 上会让"用屏转向"和"用键开火"互斥，那是板上发现的缺陷）。
- **物理层**：两根线从不被源出高，SDA 只在 SCL 低时变化（START/STOP 除外），tBUF；`ct_rst_n` 保持低 10 ms，复位后 50 ms 等待期内不得有 I2C 流量。

# 7. `tb_nes_audio_lane.v`：Zynq 音频 lane

被测是 `nes_zynq_top` 内的音频 lane（**不是**独立模块，是顶层布线），目标 `audio-lane-tb`。因此本 bench 会 elaborate **整条 zynq 顶层**——真实 MMCM 模型、真实 NES 核，以及顶层首次例化的两个子模块 `nes_audio_i2s` 与 `wm8960_i2c`。PPU / mapper / scaler 不在此重测（那些由 zynq-top 的 bench 负责），只检查别处不存在的东西：

- **A. codec 控制 I2C（真实引脚）**：slave 模型解析开漏总线，每笔写与**硬编码的 WM8960_v4.4 寄存器表**比对（与 DUT 参数比只会证明状态机走了自己的表）。
- **B. decimator（`mmcm_core_clk` 域）**：B1 单位增益、bit-exact（常量输入经 4/4/2 平均与 /32 后完全不变，闭式检查、无参考模型）；B2 用独立参考模型（历史缓冲 + 显式求和，而非 DUT 的运行延时寄存器）逐值比对；B3 精确输出数——有理步进是 2016 输入样点 → 55 输出样点，Bresenham 累加器有界，所以恰好 2016k 输入 strobe 后必须恰好 55k 输出（无漂移证明）。
- **C. 二者之间的 FIFO**：从释放读侧到运行结束，`wr_full` / `dropped` / `underflow` 都必须保持低。
- **D. I2S 引脚（对照 WM8960 的 I2S 格式章节）**：D1 bclk 周期 640 ns = 1.5625 MHz；D2 某位所属的通道是**早一个 bclk** 采样的 `lrck`（Philips I2S：LRCLK 在最后一个位被锁存前一个位时钟变化，MSB 在 LRCLK 变化后第二个上升 BCLK 沿可用）；D3 MSB 先与字对齐——每个解码帧与 decimator 实际写入 FIFO 的值在**固定索引偏移 K** 处比对（FIFO 无丢样，K 是常量；K 一旦移动就说明在漂移）。强制激励是 16 位输出各不相同的 ramp，所以位反的样点会得到 ramp 里从不出现的值。
- **采样输入被强制**：占位 PRG ROM 不是游戏，真 APU 输出恒 0，会让上面所有检查变成空洞；所以 `audio_sample_left/right` 被强制，`audio_sample_valid` 保持真实（strobe 速率与 12 核时钟间隔仍是真值）。两阶段：先常量（单位增益），再 ramp（其余）。

---

# 运行

统一入口（含 elaboration 目标）：

```powershell
.\tools\sim_all.ps1 -Mode peripheral
```

单个目标，例如：

```powershell
.\tools\sim_all.ps1 -Mode peripheral-i2c
.\tools\sim_all.ps1 -Mode audio-lane-tb
```

直接调用 Icarus（逐条等价命令；`$tmp` 指向 `$env:TEMP`）：

```powershell
$tmp = $env:TEMP
# peripheral-i2c
& 'C:\iverilog\bin\iverilog.exe' -g2012 -s tb_wm8960_i2c -o (Join-Path $tmp 'tb_wm8960_i2c.vvp') 'rtl\nes_core\peripheral\wm8960_i2c.v' 'tb\peripheral\tb_wm8960_i2c.v'
& 'C:\iverilog\bin\vvp.exe' (Join-Path $tmp 'tb_wm8960_i2c.vvp')
# sd-spi-cmd-tb
& 'C:\iverilog\bin\iverilog.exe' -g2012 -s tb_sd_spi_cmd -o (Join-Path $tmp 'tb_sd_spi_cmd.vvp') 'rtl\nes_core\peripheral\sd_spi_cmd.v' 'tb\peripheral\tb_sd_spi_cmd.v'
# cdc-fifo-tb（-g2001）
& 'C:\iverilog\bin\iverilog.exe' -g2001 -s tb_nes_cdc_fifo -o (Join-Path $tmp 'tb_nes_cdc_fifo.vvp') 'rtl\nes_core\peripheral\nes_cdc_fifo.v' 'tb\peripheral\tb_nes_cdc_fifo.v'
# i2s-shifter-tb
& 'C:\iverilog\bin\iverilog.exe' -g2012 -s tb_nes_i2s_shifter -o (Join-Path $tmp 'tb_nes_i2s_shifter.vvp') 'rtl\nes_core\peripheral\nes_i2s_shifter.v' 'tb\peripheral\tb_nes_i2s_shifter.v'
# audio-i2s-tb（装配层带 cdc_fifo + i2s_shifter 两个依赖）
& 'C:\iverilog\bin\iverilog.exe' -g2012 -s tb_nes_audio_i2s -o (Join-Path $tmp 'tb_nes_audio_i2s.vvp') 'rtl\nes_core\peripheral\nes_cdc_fifo.v' 'rtl\nes_core\peripheral\nes_i2s_shifter.v' 'rtl\nes_core\peripheral\nes_audio_i2s.v' 'tb\peripheral\tb_nes_audio_i2s.v'
# touch-input-tb（-g2001）
& 'C:\iverilog\bin\iverilog.exe' -g2001 -s tb_nes_touch_input -o (Join-Path $tmp 'tb_nes_touch_input.vvp') 'rtl\nes_core\peripheral\nes_touch_input.v' 'tb\peripheral\tb_nes_touch_input.v'
```

`audio-lane-tb` 需要整条 zynq 顶层（顶层 + v6 system 的全部 RTL + 音频三件套 + `wm8960_i2c` + `nes_touch_input` + `nes_video_800x480` + `nes_zynq_clk` + 两个 tb），源文件很多，建议直接用 `.\tools\sim_all.ps1 -Mode peripheral` 或 `-Mode audio-lane-tb`，由脚本拼出规范化源列表。

任何 `$fatal` 命中都会让 vvp 以非零退出码结束并把检查名与实际值打印到 stdout；多数 bench 另有 `global timeout` / 看门狗兜底。

# 未覆盖 / 边界

- **只有 Icarus 纯 RTL 仿真证据**：本目录没有任何 ModelSim `.do` 脚本，仓库也没有 Quartus 或上板证据；所有 PASS 只来自 Icarus Verilog。
- **I2C 时序检查是仿真内的数值检查**：`$realtime` 与 1 ns/1 ps 精度下的建立/保持窗口断言，不是真实器件的容差模型。
- **codec 与触摸控制器是行为模型**：`wm8960_i2c`、`touch_input`、`audio_lane` 里的 slave 都是 TB 里的行为级模型，不是真实 WM8960 / GT9147。
- **音频 lane 不覆盖模拟行为**：没有编解码器 PLL 锁定、耳机输出；4/4/2 级联的镜像抑制**未测量**（需要频谱），这里对滤波器只证明其算术精确，而非阻带。
- **`underflow` 在 audio-i2s 与 audio-lane 中是预期现象**：前者明确不检查，后者只断言它在稳定后不再升起；不要把 `underflow` 置位本身当成缺陷。
- **触摸标定的边界**：标定寄存器值以硬编码字面量给出，只覆盖列出的五个场景；非法/未列出的 `Module_Switch1` 位组合不在覆盖内。
