# NES system v0/v1/v2/v3 testbench

本目录有五个自检集成 testbench，前两个只实例化 `nes_system_v0` 一个顶层，第三个实例化 `nes_system_v1`（单时钟 `clk`），第四个实例化 `nes_system_v2`，第五个实例化 `nes_system_v3`，都通过层次引用加载 PRG 镜像、CHR、nametable、palette，**不使用任何外部 ROM 文件、不需要外部 test ROM**：

| testbench | 被测顶层 | 覆盖目标 |
| --- | --- | --- |
| `tb_nes_system_v0.v` | `nes_system_v0` | CPU 通过 6502 总线驱动 PPU 寄存器、背景像素、`$0000-$1FFF` 工作 RAM 镜像、PRG 的 NROM-128 镜像窗口 |
| `tb_nes_system_v0_nmi.v` | `nes_system_v0` | 端到端 NMI：第一个 vblank 后使能 `PPUCTRL[7]`、`$FFFA` 向量、服务例程入栈/出栈、`dbg_nmi_pending` 恢复、帧周期不变 |
| `tb_nes_system_audio.v` | `nes_system_v1` | 端到端 APU：`$4000-$4017` 寄存器桥、frame counter IRQ 注入 CPU `irq_i`、`$FFFE/$FFFF` IRQ 向量、服务例程 ack、sample 输出非零、CPU/PPU 帧不被破坏 |
| `tb_nes_system_v2.v` | `nes_system_v2` | 端到端“等待路径”：`nes_cpu_bus` 以 `ce = ce_cpu` 使能、`READ_WAIT_CYCLES=1` / `RAM_READ_SYNC=1` 接入，owner/ready/完成脉冲逐拍断言，NMI 服务例程里通过等待总线写 PPU 使能背景与精灵，APU pulse1 与 IRQ 并行不互相破坏 |
| `tb_nes_system_v3.v` | `nes_system_v3` | 端到端“DMA 仲裁点”：`nes_oam_dma` 通过 `bus_hold` 抢占总线、OAM> DMC 优先的 grant/ack 译码、`$2003` 影子寄存器与 PPU 逐 clk 同步、`$2004` 端口 mux 的源选择、3 次 DMA 的页/基址/内容与 `$4014` 写数据同沿竞争 |

集成 testbench 的重点是验证 **CPU 真的通过 6502 总线驱动 PPU 寄存器**，而不是只验证 PPU 单独工作：测试图案数据由 CPU 程序通过 `STA $2000/$2001/$2006/$2007` 写入，testbench 只做最小限度的层次预填，并且**刻意让每一份预填数据都缺少一个关键字节**，使 CPU 写入缺失时必然被断言抓到。

NMI testbench 的重点是验证 **vblank 到 CPU 的完整 NMI 链路**：PPU 在 `(241,0)` 拉高 `nmi_o`，CPU 在下一个取指周期锁存 `dbg_nmi_pending`，走 7 周期入栈序列，从 `$FFFA/$FFFB`（镜像窗口）取向量，跳到 `$8100` 的服务例程，例程写 RAM 计数并 `RTI` 回到被中断的自跳。

APU testbench 的重点是验证 **APU frame IRQ 到 CPU 的完整 IRQ 链路**，以及 **`$4000-$4017` 真的被路由到 APU**：CPU 用 `STA $4017/$4015/$4000/$4001/$4002/$4003` 配置 pulse1 与帧计数器，APU 的 frame counter 按 CPU 周期推进并在第 29829 个 `ce` 抬 IRQ，CPU 在 `irq_i && !P[2]` 成立时走同一条 7 周期入栈序列，从 `$FFFE/$FFFF` 取向量跳到 `$8200`，例程用 `LDA $4015`（读即 ack）确认后 `STA $4015` 写回、写 RAM 计数并 `RTI`。详见本文末尾的“APU testbench”章节。

## 被测接口合同

| 信号 | 方向 | v0 合同 |
| --- | --- | --- |
| `clk` | in | 单一系统时钟，testbench 用 10 ns 周期（`always #5`）。 |
| `reset` | in | 高有效异步复位，复位 CPU、PPU 寄存器和时序计数器；不初始化 2 KiB 内部 RAM、8 KiB CHR、256 B OAM、32 B palette、2 KiB 工作 RAM 和 `PRG_SIZE_BYTES` 字节的 PRG。 |
| `pixel_valid` / `pixel_x` / `pixel_y` | out | 可见像素，背景关闭时 `pixel_valid` 仍为高。 |
| `pixel_index` | out | 4 位 NES palette 索引，不是 RGB。 |
| `frame_done` | out | 帧边界脉冲，结算后落在 `(0,0)`。 |
| `vblank` | out | 0-based 时序，窗口 `(241,1)..(261,0)`。 |
| `nmi_o` | out | 与 `vblank` 同时序，等于 `vblank && PPUCTRL[7]`（读 `$2002` 与进入/退出 vblank 都会同时清掉 `vblank` 与 `nmi_o`，所以这个等式无条件成立）。 |
| `cpu_cycle` | out | 32 位 CPU 总线周期计数。 |
| `ppu_dot` / `ppu_scanline` | out | PPU 0-based dot/scanline 计数器。 |

模块参数：

| 参数 | 默认 | 合同 |
| --- | --- | --- |
| `PRG_SIZE_BYTES` | `16384` | PRG 存储深度（必须是 2 的幂）。`$8000-$BFFF` 与 `$C000-$FFFF` 两个 16 KiB 窗口都索引到 `prg_rom[0 .. PRG_SIZE_BYTES-1]` 的低 `PRG_INDEX_BITS` 位，因此 16 KiB 时两个窗口完全镜像，32 KiB 时两个窗口各占一半。 |

`nes_system_v0` 把 `dbg_*` 全部悬空，testbench 通过 `dut.u_cpu.dbg_*`、`dut.u_ppu.*`、`dut.prg_index`、`dut.ram_index` 层次引用观察内部状态。

## PRG 容量为什么默认是 16 KiB

16 KiB 是 **EP4CE10 v0 的资源收敛结果，不是 mapper 实现**。它只决定片上 ROM 数组的深度和两个 16 KiB 窗口的镜像方式，不提供任何 bank 切换、CHR banking、mapper 寄存器或 IRQ。

- 器件只有 46 个 M9K（423,936 bit）。按 8 位宽逐数组向上取整的**估算**（未经 Fitter 验证，见 `docs/00-overview/risk-register.md` R-04）：`prg_rom` 16 KiB 约 15 个 M9K，32 KiB 约 29 个；加上 CHR 8、nametable 2、工作 RAM 2、OAM 1、palette 1，16 KiB 合计约 29 个、32 KiB 合计约 43 个。
- 32 KiB 只剩约 3 个 M9K，仅 `docs/hardware/04-memory-and-fifo.md` 记录的两个 16 bit × 1024 SDRAM FIFO 就超出；16 KiB 剩约 17 个，仍然容不下 4096 帧音频 FIFO 加 VGA 行缓存。
- 功能后果与容量无关：片上 PRG + 8 KiB CHR RAM 等价于 **NROM + CHR-RAM 且无 bank 切换**，因此只能运行这一类游戏；任何需要 PRG banking 或 CHR ROM 的 mapper 都被结构挡在外面。把 `PRG_SIZE_BYTES` 调小只会进一步收窄 ROM 容量。
- 因此本文档只说“固定 16 KiB PRG + 8 KiB CHR RAM 的 NROM-128 行为已被 testbench 断言”，**不说**“已支持某类 mapper / 某类游戏”，也不给任何综合、时序或上板结论。

testbench 侧对应地不再假设 32 KiB：`put_prg_byte` / `prg_mirror_read` 都按 `PRG_INDEX_BITS` 掩码，reset vector 用 `$FFFC & (PRG_SIZE_BYTES-1)` 计算下标，`$8000` 起的程序在两种取值下都落在同一段物理存储里。

## 时钟分配与 CPU/PPU 同相取舍

`nes_system_v0` 用 `div_phase`（0..11，12 拍）分配使能：

| 使能 | 条件 | 占比 |
| --- | --- | --- |
| `ce_cpu` | `div_phase == 0` | 12 拍中 1 拍，CPU 总线周期 120 ns |
| `ce_ppu` | `div_phase[1:0] == 2'b00`，即 `div_phase ∈ {0,4,8}` | 12 拍中 3 拍，1 dot = 4 clk = 40 ns |

**CPU 与 PPU 永远同相**：`ce_cpu` 的唯一有效拍 `div_phase==0` 必然也是 `ce_ppu` 有效拍。后果是每一次 CPU 总线事务都落在一个 PPU dot 上。由于 PPU 的 CPU 寄存器访问不受 `ce` 门控，而渲染滚动更新只在 `reg_cs=0` 的 `ce` 沿执行（见 `tb/ppu/README.md` 的“同一时钟沿的冲突合同”），**每一个落在 PPU 地址空间的 CPU 访问都会顺带吃掉该 dot 的滚动更新**。

这是 v0 的明确取舍，收益是结构简单、时序确定、CPU 与 PPU 不会互相错拍；代价是 CPU 访问越频繁，背景滚动更新的丢失越多。集成 testbench 把这个取舍写成断言而不是留给注释：

- 每次 `dut.cpu_bus_fire` 都断言 `ce_cpu` 与 `ce_ppu` 同时为高（两个 testbench 都有）。
- 集成 testbench 统计 `ce_ppu && ppu_reg_cs` 的 dot 数，断言它等于 PPU 寄存器访问总数（25 写 + 1 读 = 26），即“每个寄存器访问恰好浪费一个 dot，没有重叠也没有遗漏”。
- 集成 testbench 断言帧周期恰好是 `262 × 341 × 4 = 357368` 个 `clk`，把 dot 速率和帧长一起钉住。

NMI testbench 不重复这条 dot 级断言：它的程序要连续轮询 `$2002` 3911 次，寄存器访问总数本身不再是小常数，只保留 `cpu_cycles` 自洽与帧周期。

## 层次预填与 CPU 写入的分工

预填（`load_video_ram`）与 CPU 写入的分工是刻意设计的：**预填值总是比最终画面少一环**，所以 CPU 少写任何一个字节，帧检查就会失败。

| 数据 | 层次预填 | CPU 写入 | 少了 CPU 写入的后果 |
| --- | --- | --- | --- |
| CHR tile 0 低平面 | `chr_ram[0]=$00`，`chr_ram[1..7]=$FF` | `$0000` 起 8 次 `STA $2007` 写 `$FF` | `chr_ram[0]` 保持 0 → scanline 0 全部退化为 backdrop，索引 15 |
| CHR tile 0 高平面 | `chr_ram[8..15]=$00` | — | — |
| CHR tile 2 低/高平面 | `chr_ram[32..39]=$00`，`chr_ram[40..47]=$FF` | — | — |
| nametable 全域 | 全部 `$00`（tile 0），属性字节 0 | `$2001` 写 `$02`（row 0 / col 1） | `(0..7, 8..15)` 退化为索引 1 而不是 2 |
| palette 0 | `$0F`（backdrop） | — | — |
| palette 1 | `$00` | `$3F01` 写 `$21` | 全屏退化为索引 0 |
| palette 2 | `$00` | `$3F02` 写 `$32` | tile 2 退化为索引 0 |
| palette 3+ | `$00` | — | — |
| OAM | 全 `$00` | — | — |
| PRG `$8000..$8088` | 全 `$00` | 程序本体（$8086 起是自跳） | — |
| PRG 镜像标记 `prg_rom[$0200]` | 全 `$00` | testbench 预填 `$A5`，程序从 `$8200` 与 `$C200` 各读一次并比较 | `$C200` 读不到 `$A5` → 程序跳进失败死循环 |
| PRG reset vector | `prg_rom[$3FFC]=$00`，`prg_rom[$3FFD]=$80` | — | 首次取指 PC 变成 `$0000` |
| 内部工作 RAM `$0000-$1FFF` | 全 `$00` | `STA $0010`、`STA $1810` 写 `$5A` | `LDA $1010` 读不到 `$5A` → 程序跳进失败死循环 |

CHR 预填只覆盖 tile 0 和 tile 2：背景取数路径把 `bg_name` 放在 `bg_pattern_addr[11:4]`，所以 tile N 的低平面在 `chr[N*16..N*16+7]`、高平面在 `chr[N*16+8..N*16+15]`。

## PRG 程序（集成 testbench）

`$8000` 起的 137 字节，reset vector 指向 `$8000`：

```text
$8000  A9 00        LDA #$00
$8002  8D 00 20     STA $2000      ; PPUCTRL = 0：关闭 NMI，inc=1，背景 pattern 表 $0000，nametable 0
$8005  8D 01 20     STA $2001      ; PPUMASK = 0：关闭渲染
$8008  A9 00        LDA #$00
$800A  8D 06 20     STA $2006      ; PPUADDR 高
$800D  8D 06 20     STA $2006      ; PPUADDR 低 -> v = $0000
$8010  A2 08        LDX #$08
$8012  A9 FF        LDA #$FF
$8014  8D 07 20     STA $2007      ; chr[0] = $FF
$8017  CA           DEX
$8018  D0 FA        BNE $8014      ; 8 次循环，chr[0..7] = $FF
$801A  A9 20        LDA #$20
$801C  8D 06 20     STA $2006
$801F  A9 01        LDA #$01
$8021  8D 06 20     STA $2006      ; v = $2001
$8024  A9 02        LDA #$02
$8026  8D 07 20     STA $2007      ; nametable[1] = $02（tile 2）
$8029  A9 3F        LDA #$3F
$802B  8D 06 20     STA $2006
$802E  A9 01        LDA #$01
$8030  8D 06 20     STA $2006      ; v = $3F01
$8033  A9 21        LDA #$21
$8035  8D 07 20     STA $2007      ; palette[1] = $21
$8038  A9 3F        LDA #$3F
$803A  8D 06 20     STA $2006
$803D  A9 02        LDA #$02
$803F  8D 07 20     STA $2007      ; v = $3F02
$8042  A9 32        LDA #$32
$8044  8D 07 20     STA $2007      ; palette[2] = $32
$8047  A9 00        LDA #$00
$8049  8D 06 20     STA $2006
$804C  8D 00 20     STA $2000      ; PPUCTRL = 0：t[11:10] = 0，NMI 仍关闭
$804F  8D 01 20     STA $2001      ; PPUMASK = $0A：背景开 + 显示左侧 8 像素
$8052  A9 0A        LDA #$0A
$8054  8D 01 20     STA $2001
$8057  AD 02 20     LDA $2002      ; 读 PPUSTATUS，期望 $00
$805A  D0 06        BNE $8062      ; 读到非 0 就跳到 $8062 的自锁死循环
$805C  4C 66 80     JMP $8066      ; 画面就绪，进入尾部镜像测试
$8062  4C 62 80     JMP $8062      ; 失败死循环：$2002 异常、RAM 镜像、PRG 镜像共用
$8066  A9 5A        LDA #$5A       ; --- RAM 镜像测试 ---
$8068  8D 10 00     STA $0010      ; 基准单元
$806B  8D 10 18     STA $1810      ; 高半区必须别名到同一单元
$806E  AD 10 10     LDA $1010      ; 再从另一个别名读回
$8071  C9 5A        CMP #$5A
$8073  D0 ED        BNE $8062      ; 读回不是 $5A -> 失败
$8075  AD 00 C2     LDA $C200      ; --- PRG 镜像测试 ---
$8078  C9 A5        CMP #$A5
$807A  D0 E6        BNE $8062
$807C  AD 00 82     LDA $8200      ; 下窗口与上窗口必须读出同一字节
$807F  C9 A5        CMP #$A5
$8081  D0 DF        BNE $8062
$8083  4C 86 80     JMP $8086
$8086  4C 86 80     JMP $8086      ; 正常无限自跳
```

加上 `prg_rom[$0200] = $A5`（即 `$8200` 与 `$C200` 共同映射的那一格）。

几个容易踩的点，testbench 依赖它们：

- `PPUADDR` 的高字节写会覆盖 `t[14:12]` 和 `t[11:8]`，所以最后一次 `PPUADDR` 写的是 `$0000`，把 `t` 整体清零。背景取数只读 `t`（不读 `v`），所以 `t=0` 时 coarse X/Y 就是 `dot/8`、`scanline/8`。
- `STA $2001` 用的是 `$8005` 处的 `A`，`A` 在 `$8000` 已被置 0。
- **相对分支的基准是“操作数地址 + 1”，也就是操作码地址 + 2**（`branch_target_reg = add_signed_offset(pc_reg + 1, bus_din)`，此处 `pc_reg` 指向操作数字节）。所以 `$8018` 处的 `BNE` 跳回 `$8014` 需要 `disp = $8014 - $801A = $FA`，`$805A` 处的 `BNE` 跳到 `$8062` 需要 `disp = $8062 - $805C = $06`，尾部三条 `BNE` 分别用 `$ED` / `$E6` / `$DF`。
- 读 `$2002` 会清 `vblank` 和 `w`。程序在 vblank 之外读它，期望返回值 `$00`；`BNE` 把非 0 返回值导向 `$8062`。
- 尾部测试**不能**继续用 `$805C` 做自跳：入口跳转已经占用了 `$805C`，所以自跳搬到了 `$8086`，`$8083` 的 `JMP $8086` 是唯一的进入路径。testbench 的自跳监视器因此以 `dbg_pc == $8086` 为“进入终态”的判据。

程序（含尾部镜像测试）在第 216 个程序周期取到 `$8086` 的 `JMP`，此后一直在自跳里空转，10 ns 时钟下约 26 µs 就稳定下来，远在第一帧结束（约 3.574 ms）之前。尾部测试只碰工作 RAM 和 PRG，不写 PPU 寄存器。

## 期望画面

`PPUCTRL = $00`、`PPUMASK = $0A`、nametable 全 0（除 index 1 为 2）、CHR tile 0 低 `$FF`/高 `$00`、tile 2 低 `$00`/高 `$FF`、palette 1 = `$21`、palette 2 = `$32`：

| 区域 | tile | pattern index | palette index | `pixel_index` |
| --- | --- | --- | --- | --- |
| 整个可见区，除了下面一块 | 0 | `2'b01` | 1 | **1** |
| `y=0..7`、`x=8..15`（nametable row 0 / col 1，CPU 写入的 tile 2） | 2 | `2'b10` | 2 | **2** |

所以断言是：`y<8 && 8<=x<=15` 期望 2，其余全部可见像素期望 1，一帧共 `240 × 256 = 61440` 个像素，其中 64 个是 2、61376 个是 1。

**第一帧是预热帧，不检查像素。** CPU 在第一帧 scanline 1 附近才打开 `PPUMASK`，第一帧前半段的像素仍是关闭渲染的输出。testbench 从第 1 个 `frame_done` 起打开像素检查，到第 2 个 `frame_done` 关闭，因此被检查的正好是完整一帧（`$display` 里的 `full frame pixels=61440` 就是这个恒等式）。`pixel_valid`、坐标、vblank 窗口和 NMI 电平仍然在**每一个 clk 沿**上检查，覆盖两整帧。尾部镜像测试只访问工作 RAM 和 PRG，不写 PPU，因此画面与计数完全不受影响。

## NMI testbench

`tb_nes_system_v0_nmi.v` 复用同一个顶层，但换一套程序和一套断言。程序只做四件事：关掉渲染、轮询到第一个 vblank、之后使能 `PPUCTRL[7]`、然后自跳等 NMI。

```text
$8000  A9 00        LDA #$00
$8002  58           CLI             ; 整个程序以 I=0 运行，NMI 不受 I 影响
$8003  8D 00 20     STA $2000       ; PPUCTRL = 0：NMI 关
$8006  8D 01 20     STA $2001       ; PPUMASK = 0
$8009  8D 10 00     STA $0010       ; NMI 计数 = 0
$800C  AD 02 20     LDA $2002       ; 轮询 PPUSTATUS
$800F  10 FB        BPL $800C       ; 直到读到 bit 7
$8011  A9 80        LDA #$80
$8013  8D 00 20     STA $2000       ; PPUCTRL = $80：NMI 开
$8016  4C 16 80     JMP $8016       ; 自跳，被 NMI 打断
$8100  AD 10 00     LDA $0010       ; --- NMI 服务例程，$FFFA/$FFFB 指向这里 ---
$8103  18           CLC
$8104  69 01        ADC #$01
$8106  8D 10 00     STA $0010       ; RAM 计数 +1
$8109  40           RTI
```

镜像与向量的对应关系：`prg_rom[$3FFA] = $00`、`prg_rom[$3FFB] = $81`，即 CPU 地址 `$FFFA/$FFFB`（在**镜像**窗口里）读出向量 `$8100`。

关键时序（全部由断言固定，见下）：

1. 复位后 CPU 从 `$FFFC/$FFFD` 取到 `$8000`，跑 4 条准备指令后进入 `$800C` 的轮询循环。
2. 第一次 vblank 在 `(241,0)` 置位。轮询循环每 18 dot 读一次 `$2002`，其中**恰好一次**读到 bit 7 为 1（读到即被 PPU 清掉），此时 `PPUCTRL[7]` 仍为 0。
3. `LDA #$80 / STA $2000` 在 `(241,~60)` 附近使能 NMI。PPU 的 `nmi_o` 只在 `(241,0)` 置位，所以本帧不会再产生 NMI；`nmi_o` 全程保持低直到帧 1 的 `(241,0)`。
4. 帧 1 的 `(241,0)`：`nmi_o` 拉高并保持到 `(261,0)`。CPU 在下一个 ce 沿锁存 `dbg_nmi_pending`，在随后的 `ST_FETCH` 走 7 周期入栈序列（`$01FC`←PC 高、`$01FB`←PC 低、`$01FA`←P），从 `$FFFA/$FFFB` 取向量，进入 `$8100`。
5. 例程把 `cpu_ram[$010]` 加 1 并 `RTI`，`sp` 回到 `$FD`，`I` 标志恢复成 `CLI` 后的 0，`dbg_nmi_pending` 在例程内已经是 0。
6. 帧 1 的 `frame_done` 落在 `(0,0)`，`cpu_ram[$010] == $01`。仿真在第 2 个 `frame_done` 后 100 ns 结束。

NMI 场景的断言覆盖：

1. **复位**：`ppu_dot`/`ppu_scanline` 为 `0:0`，`frame_done`/`vblank`/`nmi_o` 为低，CPU 处于 `ST_RESET_0`，`mask_reg` 为 `$00`。
2. **PRG 镜像与向量**：上窗口（`$C000-$FFFF`）的读只能是 `$FFFA/$FFFB/$FFFC/$FFFD` 四个向量地址，且读出的数据分别是 `$00/$81/$00/$80`；每次 PRG 读都断言 `prg_index == cpu_addr[13:0]` 且 `prg_index < PRG_SIZE_BYTES`。
3. **PPU 寄存器**：写恰好 3 次（`$2000` 两次、`$2001` 一次、其它 0）；读全部是 `$2002`，读次数等于轮询循环的取指次数；**读到 bit 7 为 1 的读恰好 1 次**，且当时 `PPUCTRL[7] == $00`。
4. **`nmi_o` 波形**：每个 clk 沿断言 `nmi_o == vblank && PPUCTRL[7]`；上升沿恰好 1 次且必须落在 `(241,1)`；产生 NMI 的那个 vblank 窗口必须正好在 `(261,1)` 落下；`vblank` 只允许在窗口内为高，上升沿只允许在 `(241,1)`。
5. **入栈序列**：每次 NMI 恰好一次 `$01FC` 写（数据 `$80`）、一次 `$01FB` 写（数据 `$16`，即被中断的自跳地址 `MAIN_LOOP` 的低字节）、一次 `$01FA` 写（数据必须等于当时的 `P` 或上 `b5`）。三者次数都等于 NMI 次数。
6. **服务例程**：`$8100` 的取指次数（按进入去重）等于 NMI 次数且 ≥ 1；例程执行期间 `sp` 恒为 `$FA`、`dbg_nmi_pending` 恒为 0、`I` 标志恒为 1（入栈序列置位，程序本身是 `CLI`）。
7. **RAM 计数**：`$0010` 的写次数等于 `1 + NMI 次数`（1 次程序清零 + 每次例程 1 次），非 0 写次数等于 NMI 次数；`dut.cpu_ram[16'h010]` 与 `cpu_ram[$1810]` 的镜像视图都等于 NMI 次数。
8. **`dbg_nmi_pending` 恢复**：必须至少被置位过一次；在例程内必须为 0；全程为高的 clk 数不得超过 96（8 个 CPU 周期，进入序列内部必须清掉）；仿真结束时必须为 0。
9. **`RTI` 收尾**：`sp` 回到 `$FD`，`I` 标志回到 0（`RTI` 恢复被压入的 `P`）。
10. **CPU 状态**：无非法指令；首次取指 PC 为 `$8000`、首个操作码 `$A9`；复位向量取指地址必须是 `$FFFC/$FFFD`；自跳期间 `I` 标志恒为 0；PC 永远在 `$80xx/$81xx`（跑飞立即失败）。
11. **总线与时序**：`cpu_cycles` 等于 testbench 自统计的总线事务数；每次事务都断言 `ce_cpu` 与 `ce_ppu` 同相；帧周期恰好 357368 clk；**从 NMI 上升沿到下一个 `frame_done` 恰好 28640 clk**（`(241,1)` 到 `(0,0)` 是 `21 × 341 × 4 - 4` 个 clk），即 NMI 服务没有拉长或缩短帧。
12. **渲染关闭输出**：`PPUMASK = 0` 全程成立，所以每个 clk 沿断言 `pixel_index == 0`，`pixel_valid` 时坐标必须等于 `ppu_dot`/`ppu_scanline`。

## 断言覆盖（集成 testbench）

`tb_nes_system_v0.v` 使用 `$fatal` 断言，覆盖：

1. **复位**：`ppu_dot`/`ppu_scanline` 为 `0:0`，`frame_done`/`vblank`/`nmi_o` 为低，`mask_reg` 为 `$00`，CPU 处于 `ST_RESET_0`。
2. **CPU reset 序列**：层次观察 `dbg_state` 为 `5`（`ST_RESET_LO`）时 `bus_addr == $FFFC`、为 `6`（`ST_RESET_HI`）时 `bus_addr == $FFFD`；进入 `7`（`ST_FETCH`）时 `dbg_pc == $8000`；该窗口内第一次总线事务之后的 `dbg_opcode == $A9`。PRG 装载结果本身也被回读校验（`$8000`、`$805E`、`$8064`、`$805C/$805D`、`$8083/$8085`、`$8086/$8088`、`$8200`、reset vector）。
3. **CPU 自跳**：`dbg_pc` 一旦到达 `$8086`（即尾部测试已跑完）就必须永远在 `{$8086, $8087, $8088}` 内循环，任何越界都是失败。`$8063/$8064` 出现即失败，等价于“跳进了 `$8062` 失败死循环”，因此 `$2002` 异常、RAM 镜像失败、PRG 镜像失败三条 `BNE` 都被同一个判据抓住。PC 离开 `$80xx` 也是失败。
4. **无非法指令**：任何 `clk` 沿上 `dut.u_cpu.dbg_illegal` 为高即失败。
5. **PPU 写事务计数**：统计 `dut.ppu_reg_cs && dut.u_ppu.reg_we`，断言总数 25，并按 `reg_addr` 分解为 `PPUCTRL=2`、`PPUMASK=2`、`PPUADDR=10`、`PPUDATA=11`、其它 0；读事务（`ppu_reg_cs && !reg_we`）恰好 1 次，即程序的 `LDA $2002`。
6. **CPU/PPU 同相**：见上面“时钟分配与 CPU/PPU 同相取舍”。
7. **CPU 周期计数自洽**：`cpu_cycle` 必须等于 testbench 自己统计的总线事务数。
8. **总线周期全覆盖账**：复位 5 个 dummy 周期 + 上窗口读 + 下窗口读 + RAM 读 + RAM 写 + PPU 读写，必须精确等于 `cpu_bus_count`。任何“没被分类”的地址范围都会让这个恒等式不成立。
9. **工作 RAM 镜像**：任何 `$0000-$1FFF` 访问都必须译码到 `cpu_ram` 且 `ram_index == cpu_addr[10:0]`；RAM 写必须恰好是 `$0010` 与 `$1810` 各一次、两次数据都是 `$5A`；RAM 读必须恰好是 `$1010` 一次且读回 `$5A`；`dut.cpu_ram[16'h010] == $5A`，`$1810` 的镜像视图也读回 `$5A`。
10. **PRG 镜像窗口**：每次 PRG 读都断言 `prg_index == cpu_addr[13:0]`（两个窗口都取低 14 位）且不越界；上窗口（`$C000-$FFFF`）的读只允许 `$FFFC`、`$FFFD`、`$C200` 三个地址，数据分别必须是 `$00`、`$80`、`$A5`；下窗口读次数 ≥ 90（证明程序确实在跑）。
11. **CPU 真的改写了 PPU 状态**：最终 `control_reg=$00`、`mask_reg=$0A`、`v_addr=$0000`、`temp_addr=$0000`、`fine_x=0`、`write_toggle=0`，并且 `chr_ram[0]=$FF`、`chr_ram[7]=$FF`、`nametable_ram[0]=$00`、`nametable_ram[1]=$02`、`nametable_ram[2]=$00`、`palette_ram[0]=$0F`、`palette_ram[1]=$21`、`palette_ram[2]=$32`、`palette_ram[3]=$00`。
12. **vblank 窗口**：每一个 `clk` 沿（posedge 结算后 1 ns）断言 `vblank == ((scanline==241 && dot>=1) || (scanline>=242 && scanline<=260) || (scanline==261 && dot==0))`；上升沿必须落在 `(241,1)`、下降沿必须落在 `(261,1)`、上升次数等于下降次数。
13. **NMI 关闭**：全程 `nmi_o` 必须为低（`PPUCTRL[7]=0`）。
14. **帧边界**：`frame_done` 为高时 `ppu_dot`/`ppu_scanline` 必须是 `0:0`；`frame_done` 恰好发生 2 次；相邻两次的间隔恰好 357368 个 `clk`。
15. **背景像素**：被检查帧的每一个 `pixel_valid` 采样点上，坐标必须等于 `ppu_dot`/`ppu_scanline`，`pixel_index` 必须等于期望值，并且整帧计数恰好是 61440 / 61376 / 64。

`#20000000`（20 ms，约 5.6 帧）有全局超时兜底断言，两个 testbench 都有。

## 变异验证

为确认断言不是空跑，对 RTL 副本（不改动仓库文件）做了单点变异，全部被断言抓到：

集成 testbench：

| 变异 | 抓到它的断言（vvp 退出码 1） |
| --- | --- |
| `$2007` 写不进 CHR | 背景像素 `(0,0)` 索引 15 ≠ 1 |
| `$2007` 写不进 nametable | 背景像素 `(8,0)` 索引 1 ≠ 2 |
| `$2007` 写不进 palette | 背景像素 `(0,0)` 索引 0 ≠ 1 |
| `PPUMASK` 写入被丢弃 | 背景像素 `(0,0)` 索引 0 ≠ 1 |
| vblank 提前一条扫描线置位 | vblank 窗口在 `240:1` 不匹配 |
| 帧回卷提前一条扫描线 | vblank 窗口在 `0:0` 不匹配 |
| 帧回卷的 dot 从 340 提前到 100 | pre-render 垂直复制错位，`v_addr` 变成 `$0019` |
| `frame_done` 永不置位 | 全局超时（`wait (frame_count == 2)` 永不满足） |
| `nmi_o` 无视 `PPUCTRL[7]` 恒高 | `nmi_o` 在 `241:1` 为高 |
| `ppu_reg_cs` 丢掉 `sel_ppu` 译码 | 背景像素 `(0,0)` 索引 0 ≠ 1 |
| `reg_we` 恒为 1 | PPU 写事务计数变成 26（`$2002` 读被记成写） |
| CPU `JMP` 不再被译码 | `dbg_illegal` 置位 |
| `cpu_cycle` 不再累加 | `cpu_cycle=0` 与总线事务计数 59562 不符 |
| `PPUSTATUS` 读值固定为 `$80` | CPU 的 `BNE` 跳进 `$8062` 死循环 |
| `pixel_y` 加 1 | 像素坐标 `(1,1)` ≠ `(1,0)` |
| RAM 读通路恒读 cell 0（`$1000-$1FFF` 不再是 RAM 别名） | 程序 `LDA $1010` 得到 0 → 跳进 `$8062` 死循环 |
| `ram_index` 变成 `cpu_addr[12:0]`（且 wire 同步加宽到 13 位） | `mirrored ram write 1810 used index 1810 expected 010` |
| `prg_index` 不做低位截断（等价于 32 KiB 直通） | `prg index 7ffc out of range for fffc` |
| PRG 镜像窗口缩到 4 KiB（`prg_addr_window & 15'h1FFF`） | `prg index got 1ffc expected 3ffc for fffc` |
| 自跳 `$8086` 改成跳回 `$8066`（testbench 镜像变异） | `cpu left the jmp self loop, pc=8066` |

NMI testbench：

| 变异 | 抓到它的断言（vvp 退出码 1） |
| --- | --- |
| PPU 在 `(241,0)` 不置 `nmi_o` | `nmi_o got 0 expected 1 at 241:1 with ppuctrl=80` |
| CPU `interrupt_vector` 恒为 `$FFFE` | 上窗口出现程序未预期的读 `unexpected prg read from fffe` |
| CPU 三处 `nmi_pending_reg <= 1'b0` 全删（pending 永不清） | `dbg_nmi_pending is still set inside the nmi handler` |
| CPU 中断入口不再 `p_reg[2] <= 1'b1` | `i flag is clear inside the nmi handler, p=a0` |
| CPU `ST_INT_VEC_HI` 的 PC 高字节固定为 `$80`（handler 变成 `$8000`） | 程序被重跑，`$241:51` 处 `PPUCTRL` 变 0 而 `nmi_o` 仍高 → `nmi_o got 1 expected 0 ... with ppuctrl=00` |
| 系统的 PRG 镜像坏掉（同上表） | `prg index 7ffc out of range for fffc` |

已知的等价变异，testbench 无法也不需要区分：

- `pixel_index` 里去掉 `PPUMASK[3]` 判断：被检查帧里 `PPUMASK[3]` 恒为 1，行为完全相同。渲染关闭期间的输出由 `tb/ppu/tb_nes_ppu2c02.v` 的 `test_rendering_off_vblank` 覆盖。
- `ram_index = cpu_addr[12:0]` 但**不**加宽 wire：由于 `ram_index` 声明为 11 位，赋值时高位被截断，与原实现逐位相同。
- `prg_index = prg_addr_window` 但**不**加宽 wire：由于 `prg_index` 声明为 `PRG_INDEX_BITS` 位，赋值同样被截断。
- CPU 把入栈 `P` 的 `| 8'h20`（强制 B5）改成 `| 8'h00`：本 CPU 的 `P` 在整个 NMI 场景里 B5 恒为 1（复位值 `$24`、`PLP`/`RTI` 都会强制），因此两种写法结果相同。
- `INC abs`（`$E6`）被 CPU 译码成零页 `INC`：**这是 CPU RTL 的真实缺陷，见下节**，不是本 testbench 的等价变异。本 testbench 因此不使用 `$E6`。

## 已知 CPU RTL 缺陷（本 testbench 绕过，未修改 CPU）

`rtl/nes_core/cpu/nes_cpu6502.v` 的 `decode_mode` 把 `8'hE6`（`INC` 绝对寻址）列在 `AM_ZP` 分支里，而 `AM_ABS` 分支没有 `8'hE6`：

```text
decode_mode: ... 8'h86, 8'hA6, 8'hC6, 8'hE6, 8'h84, 8'hA4, 8'hE4, 8'hC4 -> AM_ZP
decode_mode: 8'h0D, 8'h2D, ... 8'hCE, 8'hEE, 8'h8E, ... -> AM_ABS   （缺 8'hE6）
```

后果：`E6 10 00` 被当成 2 字节的零页 `INC $10`，指令流错开一字节，后面的 `RTI` 字节被当成操作码，本仓库的 NMI 场景最初就是这么跑飞的（PC 落到 `$8104` 的 `$00` = `BRK`）。修复属于 `rtl/nes_core/cpu/`，不在本次改动范围内；NMI 服务例程因此改用 `LDA $0010 / CLC / ADC #$01 / STA $0010`（`AD/18/69/8D`，全部译码正确）来写 RAM 计数。`tb/cpu` 现有 testbench 没有覆盖 `$E6` 的绝对寻址形态，所以这个缺陷此前没有被抓到。

## 运行

在仓库根目录执行，输出放在临时目录，不向仓库写文件：

```powershell
$tmp = Join-Path $env:TEMP 'op_fpga_emu'
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
& 'C:\iverilog\bin\iverilog.exe' -g2001 -s nes_system_v0 -o (Join-Path $tmp 'nes_system_v0_core.vvp') 'rtl\nes_core\system\nes_system_v0.v' 'rtl\nes_core\ppu\nes_ppu2c02.v' 'rtl\nes_core\cpu\nes_cpu6502.v'
& 'C:\iverilog\bin\iverilog.exe' -g2012 -s tb_nes_system_v0 -o (Join-Path $tmp 'tb_nes_system_v0.vvp') 'rtl\nes_core\system\nes_system_v0.v' 'rtl\nes_core\ppu\nes_ppu2c02.v' 'rtl\nes_core\cpu\nes_cpu6502.v' 'tb\system\tb_nes_system_v0.v'
& 'C:\iverilog\bin\vvp.exe' (Join-Path $tmp 'tb_nes_system_v0.vvp')
& 'C:\iverilog\bin\iverilog.exe' -g2012 -s tb_nes_system_v0_nmi -o (Join-Path $tmp 'tb_nes_system_v0_nmi.vvp') 'rtl\nes_core\system\nes_system_v0.v' 'rtl\nes_core\ppu\nes_ppu2c02.v' 'rtl\nes_core\cpu\nes_cpu6502.v' 'tb\system\tb_nes_system_v0_nmi.v'
& 'C:\iverilog\bin\vvp.exe' (Join-Path $tmp 'tb_nes_system_v0_nmi.vvp')
```

第一条命令是纯顶层 elaboration：用 `-g2001` 只编译三个 RTL 文件，把 `nes_system_v0` 当顶层，确认 RTL 本身不依赖 testbench 特性（`$clog2` 在 Icarus 的 `-g2001` 下可用）。后两条加 testbench，入口用 `-g2012`，因为 testbench 用了 `$fatal`，与仓库现有 CPU/PPU testbench 一致。

集成 testbench 的完整期望输出：

```text
CPU reset vector FFFC/FFFD -> PC=8000 first opcode=A9 ppustatus=00 self loop=8086 PASS
BUS cpu_cycles=59562 ppu_writes=25 (ctrl=2 mask=2 addr=10 data=11) ppu_reads=1 PASS
SYNC cpu ce and ppu ce in-phase, register-access dots skipped=26 PASS
RAM $0000-$1FFF mirror: STA $0010/$1810 -> cell 010=5a, LDA $1010=5a (wr=2 rd=1 aliased=1) PASS
PRG NROM-128 16384 bytes: $8000-$BFFF and $C000-$FFFF both index 0000-00003fff, lower reads=59525 upper reads=3 (FFFC=00 FFFD=80 C200=a5) PASS
PPUSTATE cpu-driven ctrl=00 mask=0A v=0000 t=0000 chr[0:7]=FF nt[0..2]=00,02,00 pal[0..3]=0F,21,32,00 PASS
TIMING frame_done=2 frame_period=357368clk vblank_window=241:1..261:0 rise=241:1 fall=261:1 PASS
BACKGROUND full frame pixels=61440 index1=61376 index2=64 PASS
PASS nes_system_v0
```

NMI testbench 的完整期望输出：

```text
PRG nrom-128 16384 bytes, reset vector FFFC/FFFD=8000, nmi vector FFFA/FFFB=8100, handler=8100 PASS
MIRROR every vector is fetched through $C000-$FFFF, upper window reads=4, all indexed as addr[13:0] PASS
POLL ppustatus reads=3911, exactly 1 with vblank set while ppuctrl[7]=0, then ppuctrl=80 PASS
NMI entries=1, handler=8100 ran 1 times, pushed pc=8016 to 01FC/01FB and p with b5 set to 01FA, ram[0010]=01 PASS
NMI dbg_nmi_pending latched then cleared in 31 clk, 0 inside the handler and at the end, sp back to FD, i flag set on entry and restored by rti PASS
TIMING frame period=357368clk, nmi edge at 241:1, nmi edge to frame_done=28640clk (21x341x4-4) PASS
BUS cpu_cycles=59562 ppu_writes=3 (ctrl=2 mask=1) ppu_reads=3911 PASS
PASS nes_system_v0_nmi
```

两个 v0 testbench 的仿真时间都是约 7.147 ms（两帧），vvp 运行时间分别约 7.5 s 与 7.1 s。任何 `$fatal` 命中会让 vvp 以非零退出码结束并打印失败坐标、寄存器值或时间点。

`run_system_tb.do` 与 `run_system_nmi_tb.do` 提供 ModelSim/Questa 的同一条编译和运行命令。当前仓库没有 ModelSim、Quartus 或 EP4CE10 上板证据；这两个脚本未被本版本验证。APU testbench 没有对应的 `.do` 脚本。

## 明确未实现

以下不是这三个 testbench 的缺陷，而是被测顶层本身（`nes_system_v0`，或该条里注明的 `nes_system_v1`）的范围限制：

- **精灵**：没有 sprite 渲染、sprite 0 hit、sprite overflow、OAM DMA、8×16 sprite、sprite pattern table、优先级和左右翻转。`pixel_index` 只有背景通路。NMI 与 APU testbench 都把 OAM 预填为全 0，因此精灵即使实现也不会改变输出。v0 与 v1 相同。
- **mapper**：没有 mapper 寄存器、没有 PRG/CHR banking、没有外部 CHR bus、没有 IRQ。系统固定 16 KiB PRG（NROM-128，`$8000-$BFFF` 与 `$C000-$FFFF` 镜像）+ 8 KiB CHR RAM + 2 KiB nametable + horizontal mirroring（`MIRROR_VERTICAL=0`），没有四屏或单屏 mirroring。`PRG_SIZE_BYTES` 只是容量参数，改成 32768 就变成 NROM-256 的两段窗口，但**仍然没有 bank 切换**，因此不构成任何 mapper 支持。v0 与 v1 相同。
- **APU**：`nes_system_v0` 完全没有 APU、`$4000-$4017` 全部返回 `$00`、没有帧计数器 IRQ、没有 DMC DMA，`$4000-$5FFF` 在系统里译码为常量 `$00`。`nes_system_v1` 接入 APU v1 的寄存器桥、frame counter IRQ、sample 输出与 `$4014` 访问记录（见“APU testbench”一节），但仍然没有 OAM DMA 与 DMC DMA。
- **DMA**：v0 完全没有 OAM DMA（`$4014`）和 DMC DMA。两个 v0 程序都不写 `$4014`。v1 让 `$4014` 可被译码、可被读回 `$00`、可被计数，但仍然没有 DMA 状态机与 stolen cycle。
- **IRQ 路径**：`nes_system_v0` 的 `irq_i` 恒为 0，`irq_i`/`dbg_irq_pending` 无系统级覆盖，NMI testbench 覆盖的只是 `$FFFA` 链路。`nes_system_v1` 让 `irq_i` 唯一地由 APU frame IRQ 驱动，`$FFFE` 链路由 APU testbench 覆盖；**mapper IRQ 仍然不存在**（没有 mapper 寄存器，也没有任何与 APU 做或的输入）。
- **NMI 的多次服务、嵌套与精确周期对齐**：NMI testbench 只跑到第 2 个 `frame_done`，因此只服务 1 次 NMI。“每帧一次、长期稳定”没有覆盖；`$FFFA/$FFFB` 之外的向量（IRQ/BRK）在 v0 上没有系统级覆盖，在 v1 上由 APU testbench 覆盖了 IRQ 一侧。
- **奇数帧跳 dot、PAL 制式、精确逐 dot 预取时序**：与 PPU v0 一致，未实现。
- **同一沿冲突**：寄存器访问优先，代价是每个 PPU 寄存器访问吃掉一个 dot 的滚动更新，见“时钟分配与 CPU/PPU 同相取舍”。**APU 寄存器访问不受这条规则约束**：APU 的 `ce` 是 `ce_cpu` 而不是 `ce_ppu`，且 PPU 的滚动更新门是 `!reg_cs`（只看 PPU 自己的 `reg_cs`），因此访问 `$4000-$4017` **不会**吃掉任何 PPU dot。这一点 APU testbench 用“帧周期恰好 357368 clk”从整体上钉住，但没有做 dot 级计数。

## 集成限制

- **只用层次引用，不是可移植的验证接口**。两个 testbench 都直接写 `dut.prg_rom`、`dut.cpu_ram`、`dut.u_ppu.chr_ram`、`nametable_ram`、`palette_ram` 并读 `dut.u_ppu.control_reg`、`dut.prg_index`、`dut.ram_index`、`div_phase` 等内部信号。这些名字一旦在 RTL 里重命名，testbench 会编译失败。RTL 想变成可综合产品时应该把这些换成正式端口或 package 接口。
- **testbench 依赖具体的 12 拍使能分配**。`frame_period == 357368`、`nmi edge to frame_done == 28640` 和 `ce_cpu`/`ce_ppu` 同相断言锁死了 `div_phase` 的具体设计。调整 CPU/PPU 的时钟分配就必须同步调整这几处断言和本文档里的表。
- **PRG 镜像断言与镜像探针都写死了 16 KiB 的 NROM-128 关系**（`prg_index == cpu_addr[13:0]`，探针是 `$8200` 与 `$C200` 读同一字节）。要用同一个 testbench 验证 `PRG_SIZE_BYTES = 32768`，必须同时改三处：DUT 例化加 `#(.PRG_SIZE_BYTES(32768))`、两处索引断言改成 `cpu_addr[14:0]`、镜像探针换成一对此窗口不互为别名的地址。已实测：只改前两处时 testbench 报 `read at C200 got 00 expected A5`，即程序自己就检测出 32 KiB 下 `$C200` 不再是 `$8200` 的别名。本次没有为 32 KiB 单独跑一遍完整 testbench。
- **程序在第一帧内完成**，所以渲染关闭期间的真实输出没有被断言。`tb/ppu/tb_nes_ppu2c02.v` 覆盖了渲染关闭时的 PPU 行为。
- **没有真实 ROM**。PRG 镜像是 testbench 用 `put_prg_byte` 逐字节写的，nametable/CHR/palette 也有相当一部分是层次预填。它验证的是 RTL 合同的内部一致性，不是任何商业或测试 ROM 的行为。NESdev test ROM 的结论不能由本 testbench 代替。
- **只覆盖背景功能级取数**。背景通路是逐像素组合取数，不是逐 dot 预取流水线，所以“真实 PPU 的取数时序缺陷”在本 testbench 里不会表现为画面错误。
- **NMI testbench 的 vblank 断言比集成 testbench 松一档**：轮询循环会主动读 `$2002`，读操作本身会清掉 vblank 标志，所以那里只能断言“vblank 只在窗口内为高、上升沿只在 `(241,1)`”，不能断言逐 clk 的窗口等式。窗口等式由集成 testbench 覆盖（它的程序只在 vblank 之外读一次 `$2002`）。

## APU testbench（`nes_system_v1`）

`tb_nes_system_audio.v` 复用同一个 CPU、PPU 与 APU v1（`nes_apu2a03` + 五个通道/查找表文件），但换到 `nes_system_v1` 顶层，换一套程序和一套断言。`nes_system_v0` 的文件与行为**未被修改**，v1 是并列的第二个顶层。

### 顶层接口合同（相对 v0 的增量）

| 信号 | 方向 | v1 合同 |
| --- | --- | --- |
| `apu_irq_o` | out | APU 的 `irq`（`frame_irq_flag \| dmc_irq_flag`），**同时**是 CPU `irq_i` 的驱动源。电平有效，**不锁存**：CPU 的中断入口是 `irq_i && !p_reg[2]` 的电平判定，所以 `$4015` 读/写 ack 之后线就落，CPU 必须自己 ack。 |
| `audio_sample_valid` | out | APU `sample_valid` 直出。`ce_sample` 恒为 1，因此它等价于 `ce_cpu`：每 12 个 `clk` 一次、宽度恰好 1 个 `clk` 的脉冲（脉冲落在 `div_phase == 1` 的那一拍）。**不是** 48 kHz 之类的音频速率，下游必须自己抽取。 |
| `audio_sample_left` / `audio_sample_right` | out | APU 混音器输出。当前 APU 左右相同（`sample_left <= mixed_sample; sample_right <= mixed_sample`）。 |
| `oam_dma_req` | out | **只有一个 CPU 周期宽**的脉冲（组合式 `cpu_bus_fire && $4014`），表示“CPU 访问了 `$4014`”。**OAM DMA 本体没有实现**，没有 stall、没有 DMA 周期、没有 OAM 写入。 |
| `oam_dma_count` | out | 8 bit 粘滞计数器，每次 `oam_dma_req` 加一，复位清零。用途是让外部/测试能观测到“程序确实碰过 `$4014`”，而不是靠注释。 |

其余端口（`pixel_*`、`frame_done`、`vblank`、`nmi_o`、`cpu_cycle`、`ppu_dot`、`ppu_scanline`）与 `nes_system_v0` 完全同义，时钟分配也完全相同：12 拍 `div_phase`，`ce_cpu = (div_phase == 0)`，`ce_ppu = (div_phase[1:0] == 0)`。

### 地址译码与寄存器桥

```text
sel_ram = (cpu_addr[15:13] == 3'b000)                              $0000-$1FFF
sel_ppu = (cpu_addr[15:13] == 3'b001)                              $2000-$3FFF
sel_apu = (cpu_addr[15:5] == 11'h200) && (cpu_addr[4:0] <= 5'h17)  $4000-$4017
```

- `sel_apu` 的上界用 `cpu_addr[4:0] <= 5'h17` 而不是 `!cpu_addr[4]`。后者是错的：`$4010-$401F` 的 bit4 全是 1，会把整个 `$4010-$4017`（含 `$4015` 与 `$4017`）挡在桥外。这个错误在本次开发中真实出现过，第一次跑 testbench 就报了 `cpu write to an unmapped region at 4017`。
- `$4000-$4017` 是**连续**的 24 个地址，因此 `sel_apu` 的低 5 位比较等价于 5 位寄存器下标直接透传：`apu.reg_addr = cpu_addr[4:0]`。不需要任何折叠或偏移。
- `apu_reg_cs = cpu_bus_fire && sel_apu`，**只在 CPU 真正完成一次总线事务的那一个 `clk` 周期为高**。这一点是必须的：APU 里 `$4015` 的读、`$4015`/`$4017` 的写都带副作用（清 frame IRQ / 重启 frame counter / 改变通道使能），如果用“请求级”信号而不是完成脉冲，同一次访问会被执行多次或被 stall 拍数放大。`cpu_bus_fire = bus_req && bus_ready`，而 `bus_ready = !reset` 且 `bus_req` 只在 `ce_cpu` 有效拍拉高，所以 `apu_reg_cs` 天然与 `ce_cpu` 同相、宽度恒为 1 拍。
- 读数据：`3'b010: cpu_din = sel_apu ? apu_reg_dout : 8'h00;`。`$4000-$4017` 之外（`$4018-$5FFF`）仍然读回 `$00`，与 v0 的 open bus 一致。

### `$4014`（OAM DMA）为什么“读得到 0、写不进、还会被记一笔”

`$4014` 落在 `sel_apu` 里，会被送到 APU 的 `reg_addr = 5'h14`。APU 内部 `reg_addr[4:2] == 3'd5` 才是状态/帧计数器分支，而 `$4014`、`$4016` 既不等于 `5'h15` 也不等于 `5'h17`，因此：

- 读：落到 `reg_dout` 的 `default: 8'h00`，返回 `$00`。
- 写：`reg_wr_status` / `reg_wr_frame` 都不匹配，写进去没有任何副作用。

也就是说“未实现”在 RTL 上表现为**一个被记录但被忽略的访问**，而不是“地址没译码所以行为未定义”。testbench 侧对应地把这一点写成断言而不是注释：程序读一次 `$4014` 并断言返回 `$00`，同时 `oam_dma_count` 从 0 变 1。

### 时钟与采样输出

- APU `ce = ce_cpu`。frame counter 因此按 **CPU 周期**（1.789 MHz）推进，4 步序列长度 29830 ce，5 步序列 37282 ce，与真机一致。
- APU `ce_sample = 1'b1`（`nes_system_v1.v` 里一条显式的常电 wire）。APU 内部的规则是 `if (ce && ce_sample) sample_valid <= 1; ... else sample_valid <= 0;`，所以每个 `ce_cpu` 沿之后 `sample_valid` 高 1 个 `clk`，即 `div_phase == 1` 那一拍；下一拍就被拉低。`tb_nes_system_audio.v` 逐拍断言 `audio_sample_valid` 只在 `div_phase == 1` 为高，且脉冲总数等于 APU 的 `ce` 脉冲总数。
- 混音器是**组合**的，`sample_left/right` 是 `ce` 沿上对 `mixed_sample` 的寄存。因此“某个 strobe 携带的样本”对应的是 `ce` 沿**之前**那一拍的通道电平。testbench 逐个 strobe 断言 `sample_left == sample_right` 且 `sample_left == ref_pulse_lut(pulse_sum_prev)`（`pulse_sum_prev` 是在 `ce_cpu` 沿上抓的沿前快照），并在 `tnd_sum != 0` 时立刻 `$fatal`——本程序只开 pulse1，三角波/噪声/DMC 必须全程为 0。

### IRQ 注入 CPU 的完整链路

```text
APU frame counter (ce_cpu) --frame_irq_flag--> irq = frame_irq_flag | dmc_irq_flag
      |                                                    |
      |                                            apu_irq_o (电平，不锁存)
      v                                                    v
                                             u_cpu.irq_i --> ST_FETCH: irq_i && !P[2]
                                                                 |
                                                                 v
                                  7 周期入口: DUMMY2 -> PUSH_HI -> PUSH_LO -> PUSH_P
                                           -> VEC_LO($FFFE) -> VEC_HI($FFFF) -> ST_FETCH
```

关键点，逐条都被 testbench 断言：

1. **电平不是边沿**。CPU 的判定是 `irq_i && !p_reg[2]`，没有 pending 寄存器。因此 `apu_irq_o` 从拉高到 ack 之间一直有效，`dbg_irq_pending` 就是 `irq_i` 的直连（CPU 里 `assign dbg_irq_pending = irq_i`）。testbench 逐 clk 断言 `dbg_irq_pending === apu_irq_o`，并断言 `apu_irq_o === (dbg_frame_irq | dbg_dmc_irq)`。
2. **入口是 7 个 CPU 周期**。在 `ST_FETCH` 判定成立的那一记 `cpu_cycle` 与服务例程第一次 `ST_FETCH` 之间的差必须恰好是 7。这条断言比“服务例程跑过了”强得多：它把 `ST_INT_DUMMY2 / PUSH_HI / PUSH_LO / PUSH_P / VEC_LO / VEC_HI` 六个状态加上返回取指全部钉住。
3. **入栈内容**。`$01FC` ← PC 高（必须是 `MAIN_LOOP` 的 `$80`）、`$01FB` ← PC 低（`$46`）、`$01FA` ← `P | 0x20`。`b5` 强制置 1（`interrupt_push_data = (p_reg | 8'h20) | (int_push_b_reg ? 8'h10 : 0)`）并且 **`b4` 必须为 0**：IRQ 的 `int_push_b_reg` 是 0，BRK 是 1，所以“bit4 为 0”正好把“CPU 走的是 IRQ 入口而不是 `BRK` 指令”这条判据固定下来。
4. **`I` 标志**。程序全程 `CLI`，所以主循环里 `P[2] == 0`（IRQ 可被响应）；CPU 在 `ST_INT_PUSH_P` 置 `I`，因此例程内 `P[2] == 1`；`RTI` 从栈上恢复 `P`，例程返回后 `I` 回到 0、`sp` 回到 `$FD`。testbench 在主循环取指、handler 内每一次总线事务、以及仿真结束三处分别断言这三点。
5. **ack 是软件责任**。例程第一条指令就是 `LDA $4015`：读操作本身就把 `frame_irq_flag` 清掉（APU 里 `frame_clear_now` 对 `reg_addr == 5'h15` 的读/写都为真），返回值的 bit6 就是被清掉的旧标志。testbench 断言这次读**只在 handler 内发生**且 bit6 == 1、bit7 == 0（DMC IRQ 未接）、bit1:0 == `01`（pulse1 长度非零）；紧接着的 `STA $4015` 断言写回值与读回值逐位相同，并且必须发生在读之后。
6. **IRQ 会再次发生**。4 步序列下 frame IRQ 每 29830 ce 抬一次；本次跑满 3 个 PPU 帧（`frame_period == 357368` clk，89343 个 `ce_cpu`），因此 frame IRQ 恰好抬 2 次、落 2 次，handler 恰好进入 2 次，RAM 计数 `cpu_ram[$0010] == 2`。断言 `apu_irq_o` 的上升沿数 == frame IRQ 上升沿数、下降沿数 == 上升沿数（每一次都被 ack 清掉，没有残留），并且仿真结束时 `apu_irq_o == 0`。

### 程序

`$8000` 起 76 字节 + `$8200` 起 16 字节的 IRQ 服务例程，reset vector 指向 `$8000`，IRQ vector `$FFFE/$FFFF` 指向 `$8200`（NMI vector `$FFFA/$FFFB` 也预填成 `$8100`，一旦被取就是立即失败，因为 `PPUCTRL[7]` 全程为 0）：

```text
$8000  58           CLI                  ; 整个程序以 I=0 运行，IRQ 可响应
$8001  A9 00        LDA #$00
$8003  8D 17 40     STA $4017            ; bit7=0 -> 4 步；bit6=0 -> 不禁止 frame IRQ；顺带重启 frame counter
$8006  AD 15 40     LDA $4015            ; 期望 $00：frame IRQ 还没来、通道长度都还是 0
$8009  C9 00        CMP #$00
$800B  D0 3C        BNE $8049            ; -> 失败死循环
$800D  A9 01        LDA #$01
$800F  8D 15 40     STA $4015            ; 使能 pulse1（必须在 $4003 之前，否则长度装载会被 enable 门挡住）
$8012  A9 BF        LDA #$BF
$8014  8D 00 40     STA $4000            ; duty=2 (25%)，bit5=1 halt + 恒定音量 15
$8017  A9 00        LDA #$00
$8019  8D 01 40     STA $4001            ; sweep 关闭
$801C  A9 20        LDA #$20
$801E  8D 02 40     STA $4002            ; timer 周期低 8 位
$8021  A9 40        LDA #$40
$8023  8D 03 40     STA $4003            ; bit7:3=8 -> length 表索引 8 (=160)，bit2:0=0 -> 周期高位
$8026  A9 00        LDA #$00
$8028  8D 00 20     STA $2000            ; PPUCTRL = 0：NMI 关
$802B  8D 01 20     STA $2001            ; PPUMASK = 0：渲染关
$802E  8D 10 00     STA $0010            ; IRQ 计数清零
$8031  AD 14 40     LDA $4014            ; OAM DMA 寄存器，未实现，必须读回 $00
$8034  C9 00        CMP #$00
$8036  D0 11        BNE $8049
$8038  AD 18 40     LDA $4018            ; APU 窗口之外，必须读回 $00 且不得到达 APU
$803B  C9 00        CMP #$00
$803D  D0 0A        BNE $8049
$803F  AD 1F 40     LDA $401F            ; 同上
$8042  C9 00        CMP #$00
$8044  D0 03        BNE $8049
$8046  4C 46 80     JMP $8046            ; 自跳，被 IRQ 打断（被中断的 PC 就是 $8046）
$8049  4C 49 80     JMP $8049            ; 失败死循环

$8200  AD 15 40     LDA $4015            ; --- IRQ 服务例程，读即清 frame IRQ ---
$8203  8D 15 40     STA $4015            ; 写回确认
$8206  AD 10 00     LDA $0010
$8209  18           CLC
$820A  69 01        ADC #$01
$820C  8D 10 00     STA $0010            ; RAM 计数 +1
$820F  40           RTI
```

几个容易踩的点，testbench 依赖它们：

- **`$4017` 的 bit6 是“禁止 frame IRQ”，不是“允许”**。第一次写成 `LDA #$40 / STA $4017` 时，程序永远等不到 IRQ，testbench 报 `only 0 frame irq periods were measured`。允许 frame IRQ 必须写 `$00`。
- **`$4015` 的使能必须早于 `$4003`**。pulse 的长度装载门是 `if (reg_we) ... if (enable) len_pending <= length_lut_value;`，而 `enable` 是 `pulse1_enable` 寄存器。若先写 `$4003` 再写 `$4015`，长度永远是 0，pulse1 全程静音，sample 全 0。
- **相对分支基准是“操作数地址 + 1”，即操作码地址 + 2**。四条 `BNE` 分别用 `$3C` / `$11` / `$0A` / `$03`。
- **`$4000 = $BF` 的 bit5 是 halt**。恒定音量模式下长度计数器不递减，所以 `dbg_pulse1_length` 跑完 3 帧仍然是 160。这不是“没跑”，是 APU 的正确行为；testbench 因此把期望值钉成精确的 160 而不是范围。
- **周期不能取 2048**。pulse 的静音条件是 `(period < 8) || (sweep_target > 2047)`，sweep 关闭时 `sweep_target = period + (period >>> shift)`；`$4002=$08 / $4003=$08` 得到 period = 0x800 = 2048 → `sweep_target = 2048 > 2047` → 永久静音。程序用 `$4002=$20 / $4003=$40` 得到 period = 0x020 = 32，避开这个陷阱。
- 计数器用 `LDA / CLC / ADC / STA` 而不是 `INC $0010`：绝对寻址的 `INC` 是 `$EE`，译码正确，但**零页**的 `INC` 是 `$E6`，而本仓库 CPU 的 `decode_mode` 把 `8'hE6` 误列在 `AM_ZP`（见上面的“已知 CPU RTL 缺陷”）。这条约束与 NMI testbench 完全一致。

### 断言覆盖

1. **复位**：`ppu_dot`/`ppu_scanline` 为 `0:0`，`frame_done`/`vblank`/`nmi_o`/`apu_irq_o`/`audio_sample_valid` 全低，`oam_dma_count` 为 0，CPU 处于 `ST_RESET_0`，APU `dbg_frame_count` 为 0，`PPUMASK` 为 `$00`。
2. **CPU reset 序列**：层次观察 `dbg_state == 5` 时 `bus_addr == $FFFC`、为 `6` 时 `bus_addr == $FFFD`；进入 `7` 时 `dbg_pc == $8000`；该窗口之后第一次总线事务的 `dbg_opcode == $58`（`CLI`）。
3. **PRG 镜像与向量**：每次 PRG 读都断言 `prg_index == cpu_addr[13:0]` 且不越界；上窗口（`$C000-$FFFF`）的读只允许 `$FFFA/$FFFB/$FFFC/$FFFD/$FFFE/$FFFF` 六个向量地址，数据分别是 `$00/$81/$00/$80/$00/$82`；reset 向量各取 1 次，IRQ 向量对数 == handler 进入次数，NMI 向量 0 次。
4. **地址区间全覆盖账**：每一次 `cpu_bus_fire`（复位 5 个 dummy 周期除外）都被分类到 `ram / ppu / apu / openbus / prg` 之一，**写**落到 `ram / ppu / apu` 之一，落到未映射区立刻 `$fatal`。各类计数与独立的 `sel_*`/`reg_cs` 探针必须逐一相等，总和必须等于映射过的总线周期数。
5. **APU 寄存器桥**：`apu_reg_cs` 蕴含 `cpu_bus_fire` 与 `ce_cpu`；相邻两拍不得同时为高（单拍脉冲）；地址必须在 `$4000-$4017` 内；`$4018/$401F` 的读**不得**拉起 `apu_reg_cs` 且必须读回 `$00`。写/读分别按 `reg_addr` 分解：写 `$4000/$4001/$4002/$4003/$4017` 各 1 次、`$4015` 写 `1 + handler 次数`、`$4014` 写 0 次、其它 0；读 `$4015` `1 + handler 次数`、`$4014` 1 次、`$4018/$401F`/其它 0 次。总事务数恰好 `8 + 2 × handler 次数`。
6. **frame counter**：每个 `apu_irq_o` 上升沿（testbench 在沿后一拍采样）APU `dbg_frame_count` 必须正好是 29829；两次上升沿之间恰好 29830 个 `ce` 脉冲；全程 `dbg_frame_count` 不得超过 29829（4 步模式下的驻留值）；仿真结束时 `dbg_frame_irq == 0`。
7. **IRQ → CPU**：逐 clk 断言 `apu_irq_o === (dbg_frame_irq | dbg_dmc_irq)` 且 `dbg_irq_pending === apu_irq_o`；DMC IRQ 任何时候抬起来即失败。handler 进入次数 == frame IRQ 次数 == `$4015` ack 次数；入口恰好 7 个 CPU 周期；`$01FC/$01FB/$01FA` 各压入 `handler 次数` 次且数据正确，`$01FA` 的 bit4 恒为 0；`cpu_ram[$0010]` 与其镜像 `$1810` 都等于 `handler 次数`。
8. **中断期间的 CPU 状态**：handler 内每次总线事务都断言 `sp == $FA` 且 `P[2] == 1`；主循环取指处断言 `P[2] == 0`；`RTI` 之后 `sp == $FD`、`P[2] == 0`。PC 越出 `$80xx` 主程序块或 `$82xx` 例程、或落进 `$8049` 失败死循环、或 `dbg_illegal` 置位，都立刻失败。
9. **sample 输出**：`audio_sample_valid` 只在 `div_phase == 1` 为高；脉冲总数 == APU `ce` 脉冲总数；每个脉冲都断言 `left == right` 且等于沿前 `pulse_sum` 的参考 mixer 表值，`tnd_sum` 必须全程为 0；非零样本数 > 0；峰值恰好 4895（`pulse_sum == 15` 的表值）；CPU 服务 IRQ 期间的 sample 脉冲数与同期 `ce` 脉冲数相等（证明采样通路不被中断序列打断）。
10. **PPU 未被破坏**：PPU 写恰好 2 次（`PPUCTRL` 1 次、`PPUMASK` 1 次、其它 0）、读 0 次；最终 `PPUCTRL == $00`、`PPUMASK == $00`；逐 clk 的 vblank 窗口等式成立、上升沿 3 次且与下降沿配平；`nmi_o === vblank && PPUCTRL[7]` 全程成立（`PPUCTRL[7] == 0`，所以恒为 0）；渲染关闭期间 `pixel_index == 0`、`pixel_valid` 时坐标等于 `ppu_dot`/`ppu_scanline`。
11. **帧与总线**：`frame_done` 恰好 3 次且都落在 `(0,0)`；相邻间隔恰好 357368 `clk`；`cpu_cycle` 等于 testbench 自统计的 `cpu_bus_fire` 总数。
12. **全局超时**：`#40000000`（40 ms，约 37 帧）兜底。

### 运行

```powershell
$tmp = Join-Path $env:TEMP 'op_fpga_emu'
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
$apu = @('rtl\nes_core\apu\nes_apu_pulse.v','rtl\nes_core\apu\nes_apu_triangle.v','rtl\nes_core\apu\nes_apu_noise.v','rtl\nes_core\apu\nes_apu_dmc.v','rtl\nes_core\apu\nes_apu_length_lut.v','rtl\nes_core\apu\nes_apu2a03.v')
$v1 = @('rtl\nes_core\system\nes_system_v1.v','rtl\nes_core\ppu\nes_ppu2c02.v','rtl\nes_core\ppu\nes_ppu_sprite.v','rtl\nes_core\cpu\nes_cpu6502.v') + $apu
& 'C:\iverilog\bin\iverilog.exe' -g2001 -s nes_system_v1 -o (Join-Path $tmp 'nes_system_v1_core.vvp') $v1
& 'C:\iverilog\bin\iverilog.exe' -g2012 -s tb_nes_system_audio -o (Join-Path $tmp 'tb_nes_system_audio.vvp') ($v1 + 'tb\system\tb_nes_system_audio.v')
& 'C:\iverilog\bin\vvp.exe' (Join-Path $tmp 'tb_nes_system_audio.vvp')
```

第一条是纯顶层 elaboration（`-g2001`，只编译 RTL），确认 `nes_system_v1` 本身不依赖 testbench 特性。注意源文件列表必须包含 `nes_ppu_sprite.v` 与全部五个 APU 通道/查找表文件：`nes_system_v1` 间接例化了它们，`iverilog` 不会自动去 `rtl/` 下找。**上面“运行”一节里 v0 那两条命令目前漏了 `rtl\nes_core\ppu\nes_ppu_sprite.v`**，直接照抄会报 `Unknown module type: nes_ppu_sprite`；这是本文档既有的笔误，本次没有改动 v0 章节，追加 `nes_ppu_sprite.v` 即可。`tools/sim_all.ps1` 目前只登记 v0 的 system 目标，也没有这一项，本次没有改动它，所以上面三条命令是直接调用。

完整期望输出：

```text
PRG nrom-128 16384 bytes, reset vector FFFC/FFFD=8000, irq vector FFFE/FFFF=8200, handler=8200 PASS
MIRROR every vector is fetched through $C000-$FFFF, upper window reads=6, irq pairs=2, nmi pairs=0 PASS
REGISTER program wrote $4000/$4001/$4002/$4003/$4015/$4017 once each and read $4015/$4014 once each, handler read+wrote $4015 2 times, $4018/$401F never reached the apu PASS
OAMDMA $4014 read returned 00, oam_dma_req pulsed 1 time, oam_dma_count=1, no cpu stall and no oam write PASS
PULSE1 period=020, length 160 of 160 (halted by $4000[5]), not muted, pulse2/tri/noise lengths all 0 PASS
IRQ entries=2, handler=8200 took 7 cpu cycles, pushed pc=8046 to 01FC/01FB and p with b5 set b4 clear to 01FA, ram[0010]=02 PASS
FRAMEIRQ raised on the ce edge that leaves frame count at 29829, then again every 29830 ce, rises=2 falls=2, counter max=29829 PASS
SAMPLE valid strobes=89343 (one per apu ce, one clk wide at div_phase=1), nonzero=44415, peak=4895, every strobe matched ref_pulse_lut, left=right, 42 strobes kept flowing while the cpu served the irqs PASS
PPU writes=2 (ctrl=1 mask=1) reads=0, ppuctrl=00 ppumask=00, nmi_o stayed low, pixel_index stayed 0, vblank rises=3 PASS
TIMING frame period=357368clk over 3 frames, apu ce pulses=89343, cpu bus cycles=89343 PASS
BUS cpu_cycles=89343 rd(ram=10 ppu=0 apu=4 openbus=2 prg=89303) wr(ram=9 ppu=2 apu=8) all regions classified PASS
CPU rti restored sp=FD and the i flag, cpu_cycle=89343 equals the counted bus fires PASS
PASS nes_system_audio
```

仿真时间 10.721 ms（3 帧）。本机实测 vvp 运行时间约 56 s，而同一台机器上两个 v0 testbench（各 7.147 ms）约 51 s——差异来自 3 帧 vs 2 帧和逐 strobe 断言，不是数量级差异。“运行”一节里记录的 v0 数字（约 7 s）与本机不同，属于既有章节的历史测量值，本次没有改动。任何 `$fatal` 命中会让 vvp 以非零退出码结束并打印失败条件。

### 变异验证

为确认断言不是空跑，对 `nes_system_v1.v` 的副本（不改动仓库文件）做了 16 个单点变异，14 个被抓，2 个是等价变异：

| 变异 | 结果（vvp 退出码 1 的断言） |
| --- | --- |
| CPU `irq_i` 接成 `1'b0` | `cpu dbg_irq_pending got 0 expected 1` |
| `apu_irq_o` 接成 `1'b0` | `apu_irq_o got 0 expected 1 from frame=1 dmc=0` |
| `apu_irq_o` 取反 | `apu_irq_o is high during reset` |
| `apu_irq` 漏进 `nmi_o` | `nmi_o got 1 expected 0 at 0:188 with ppuctrl=00` |
| `sel_apu` 放宽成整个 `$4000-$5FFF` | `apu_reg_cs asserted outside $4000-$4017 at 4018` |
| `apu_reg_cs` 去掉 `cpu_bus_fire`（变成电平） | `apu_reg_cs asserted without cpu_bus_fire` |
| `apu.reg_addr` 折成 `cpu_addr[2:0]` | `$4017 write count got 0 expected 1` |
| `apu.reg_we` 恒为 1 | `handler wrote $4015 before reading it` |
| `apu` 的 `ce` 换成 `ce_ppu` | `audio_sample_valid asserted at div_phase=5, expected 1` |
| `ce_sample` 接成 `1'b0` | `sample strobes 0 do not match apu ce pulses 89343` |
| `ce_cpu` 的相位挪到 `div_phase == 2` | `audio_sample_valid asserted at div_phase=3, expected 1` |
| 读 mux 的 `3'b010` 分支丢掉 APU 读通路 | `cpu_din 00 does not match apu reg_dout 41` |
| `oam_dma_req` 接成 `1'b0` | `oam_dma_req count got 0 expected 1` |
| `oam_dma_count` 不再累加 | `oam_dma_count is 0 expected 1` |
| `ce_sample` 接成 `ce_ppu` | **等价变异**：`ce_cpu` 与 `ce_ppu` 的交集只有 `div_phase == 0`，因此 `ce && ce_sample` 与 `ce && 1` 逐拍相同 |
| 一个空变异（改写为同值） | **等价变异**：文件内容不变 |

### v1 明确未实现

- **OAM DMA（`$4014`）**：只有“被记录”，没有 DMA 状态机、没有 `RDY` 拉低、没有 513/514 个 stolen cycle、没有 OAM 写入。`oam_dma_req` / `oam_dma_count` 是给未来实现和外部观测留的接口。
- **DMC DMA**：`u_apu` 的 `dmc_bus_req` / `dmc_addr` 悬空，`dmc_rdata` 接 `8'h00`、`dmc_ack` 接 `1'b0`。本程序从不写 `$4010-$4013`，所以 DMC 一直 inactive；testbench 断言 `dbg_dmc_irq` 永不抬升。但**没有**任何保护阻止未来程序启动 DMC 后把它挂在 `dmc_ack = 0` 上死等。
- **mapper IRQ**：`$8000-$FFFF` 没有 mapper 寄存器，没有 MMC3/MMC1 的 IRQ latch，`apu_irq_o` 是 CPU `irq_i` 的**唯一**驱动源。CPU 的 `irq_i` 也没有与 mapper IRQ 做或。
- **APU 寄存器窗口以外的 `$4018-$5FFF`**：读 `$00`、写忽略，与 v0 一致，没有 open bus 的非确定值模型。
- **音频输出通路**：没有 FIFO、没有抽取/重采样、没有 WM8978 接口、没有 `ce_sample` 抽取器。`audio_sample_valid` 是 1.79 MHz 速率的 strobe，不是音频速率。
- **左右声道差异**：APU 内部 `sample_left` 与 `sample_right` 取同一个 `mixed_sample`，没有 NES 的非线性负载近似。
- **与 v0 的差异面**：`cpu_din` 的 `3'b010` 分支从常量 `$00` 变成一个 2:1 mux。合成上这在 CPU 读通路上多一级逻辑，对时序的影响**未经 Fitter 验证**。

---

## v2 testbench（`nes_system_v2`）

`tb_nes_system_v2.v` 是本目录第四个自检集成 testbench，也是**第一个真正走等待路径**的集成 testbench。v0/v1 顶层自己有一根 `bus_ready = !reset` 的常电，CPU 的每一次访问都是 1 拍；v2 顶层把 `nes_cpu_bus` 以 `READ_WAIT_CYCLES=1`、`RAM_READ_SYNC=1` 接入，集成层因此第一次把 `req / ready / 完成脉冲 / owner` 这套协议真跑起来。

配套的设计说明在 `docs/modules/system-v2.md`，本节只写 testbench 自身（程序、断言、运行方式、实测输出）。v0 与 v1 的文件、行为与本文档前面各节**未被修改**。

### 被测顶层接口增量（相对 v1）

v1 把 `dbg_*` 全部悬空、靠层次引用观测。v2 把总线与寄存器桥的观测信号提到正式端口上，因此这个 testbench 只在三类地方用层次引用：`dut.prg_rom`（装载程序镜像）、`dut.u_bus.ram_array`（读 RAM 计数单元）、`dut.u_ppu.*` 与 `dut.u_cpu.dbg_*` / `dut.u_apu.dbg_*`（读最终状态）。

| 端口 | 宽度 | 含义 |
| --- | --- | --- |
| `bus_owner` | 3 | `nes_cpu_bus` 的 `owner`，0=OPEN、1=RAM、2=PPU、3=APU_IO、4=CART_RAM、5=CART_ROM |
| `bus_active` / `bus_wait_count` | 1 / 8 | `dbg_active` / `dbg_wait_count`：事务是否在等、剩余强制等待拍数 |
| `bus_req` / `bus_stall` / `bus_fire` | 1 各一 | CPU 侧的请求 / 停顿 / 完成，以及总线的 `cpu_stall` / `cpu_fire` |
| `bus_addr` / `bus_we` / `bus_dout` / `bus_din` | 16/1/8/8 | 总线上的地址、方向、写数据、读数据（读数据只在 `bus_fire` 那一拍有效） |
| `sel_ram` / `sel_ppu` / `sel_apu_io` / `sel_open_bus` / `sel_cart_ram` / `sel_cart_rom` | 1 各六 | 六个 owner 的独热译码，只由 `bus_addr` 决定 |
| `ram_we` | 1 | 片上 2 KiB RAM 的写脉冲，已对齐到完成沿 |
| `ppu_reg_cs` / `ppu_reg_we` / `ppu_reg_addr` | 1/1/3 | PPU 的 `reg_cs` / `reg_we` / `reg_addr`。`reg_cs` 就是 `ppu_xfer`，**只在完成那一拍为高** |
| `apu_reg_cs` / `apu_reg_we` / `apu_reg_addr` | 1/1/5 | APU 的 `reg_cs` / `reg_we` / `reg_addr`，同样只认完成脉冲 |
| `cart_req` / `cart_xfer` / `cart_addr` / `cart_din` / `cart_ack` | 1/1/16/8/1 | 卡带 owner 的请求级 / 完成脉冲 / 不折叠的地址 / 读数据 / 恒 1 的应答 |

其余端口（`pixel_*`、`frame_done`、`vblank`、`nmi_o`、`apu_irq_o`、`audio_*`、`cpu_cycle`、`ppu_dot`、`ppu_scanline`）与 v1 同义，时钟分配也完全相同：12 拍 `div_phase`，`ce_cpu = (div_phase == 0)`，`ce_ppu = (div_phase[1:0] == 0)`。

### 等待路径怎么接线，为什么必须这样接

`nes_cpu_bus` 的等待状态机只有一个倒计数器和两个标志，它按 `posedge clk` 走，但**只在 `ce` 为高的那个沿推进**。CPU 侧的合同是“在看到 `bus_ready` 之前保持 `bus_addr/bus_we/bus_dout` 不变”，且**只在 `cpu_active = ce && ...` 的那一拍检查 `bus_ready`**。因此总线内部的时间单位必须也是“CPU 周期”，否则两侧的节拍会错开。

把 `nes_cpu_bus` 的 `ce` 接成常电（等价于让等待计数按 `clk` 走），会发生一个**确定性的**死锁，而且是两条独立的理由：

- **等待拍数按 `clk` 数**：`wait_cnt` 在非 `ce` 的拍上照样递减，`ready` 于是出现在 `div_phase ∈ {1,3,5,7,9,11}` 这些 CPU 不采样的相位上；而 CPU 只在 `div_phase == 0` 采样 `bus_ready`，两者永不相遇。
- **请求在非 `ce` 拍上是撤回的**：`nes_cpu6502` 内部有 `if (!cpu_active) bus_req = 1'b0;`，所以 `cpu_req` 只在 CPU `ce` 窗口里为高。状态机在下一个 `clk` 看到 `!cpu_req && active`，走的是“请求撤回”分支，把刚启动的事务作废；下一个 `ce` 重新启动，再下一个 `clk` 再次作废。

两种情况都让 CPU 永远停在 `ST_RESET_0`。

v2 的接法是把 `ce` 显式接成 CPU 使能，总线与 CPU 共用同一个自由运行的 `clk`：

```verilog
) u_bus (
    .clk(clk),
    .reset(reset),
    .ce(ce_cpu),
    ...
```

于是每一拍 CPU 周期总线的状态机恰好走一步，“请求沿 → 完成沿”正好是 2 个 CPU 周期（`READ_WAIT_CYCLES=1`），CPU 与总线的相位关系变成“CPU 在第 1 拍等、第 2 拍同时前进”。两个模块在同一个沿上读同一份**沿前**的 `bus_req/bus_ready`，整条等待路径上没有任何一个由逻辑生成的时钟，因此也不存在沿上先后次序的歧义。

这条接法带来的合同，testbench 全部写成断言：

| 合同 | 断言位置 |
| --- | --- |
| `cpu_req` 只在 CPU `ce` 有效 | `ce_cpu` 拍上统计停顿次数，非 `ce` 拍不参与统计 |
| `bus_req` / `owner` / `sel_*` / `bus_addr` / `bus_we` / `bus_dout` 在整个 stall 期间保持 | 等待路径统计里 `bus_wait_count`/`bus_active` 的逐拍检查；地址与控制的稳定性由 CPU 侧合同保证 |
| 状态只在 `ce=1` 的沿推进 | 每个 `div_phase == 1` 的沿（即 `ce_cpu` 沿之后的那一拍）采样一次 `bus_active`/`bus_wait_count`，其余任何 `clk` 沿上它们变化即 `$fatal` |
| 一次 CPU 事务 = 2 个 CPU `ce` | `RAM`/`PPU`/`APU_IO`/`CART_*` 恰好 1 拍停顿，`OWNER_OPEN` 0 拍 |

代价与后果，都在 `docs/modules/system-v2.md` 的“等待路径的真实代价”一节：`READ_WAIT_CYCLES=1` 让每一次访问都花 **2 个 CPU 周期**，所以 v2 里的 CPU 相对 PPU 只有真机一半的速率（每帧 14890 次总线访问，而真机是 29780 次）。这是 v2 刻意选的集成配置，不是缺陷；v0/v1 的 `bus_ready` 是常电，一次访存永远 1 拍，等待逻辑从未被执行过。

### PRG 程序

镜像由 testbench 用 `emit` / `lda_imm` / `lda_abs` / `sta_abs` / `ppu_set_addr` / `ppu_fill8` / `jsr_abs` 等任务逐字节装配，相对分支的位移由 `bne_to`（回跳）与 `bne_patch` + `patch_bne`（前跳，先占位后回填）自动算出，因此不需要手算任何地址。

| 区段 | 地址 | 字节 | 内容 |
| --- | --- | --- | --- |
| 主程序 | `$8000-$805A` | 91 | 关渲染、清计数、配 APU pulse1、三个 owner 探针、open bus 探针、开 NMI、自跳 |
| NMI 服务例程 | `$8400-$8418` | 25 | 首次进入 `JSR $8600` 做 PPU 初始化，之后只累加 `$0010` 并 `RTI` |
| IRQ 服务例程 | `$8500-$850F` | 16 | `LDA $4015` / `STA $4015` ack，累加 `$0011`，`RTI` |
| PPU 初始化子程序 | `$8600-$86C8` | 201 | 写 CHR / nametable / palette / OAM，末尾 `PPUMASK = $1E` 并 `RTS` |
| 失败死循环 | `$8800-$8802` | 3 | 任何一处探针不通过就跳进来 |
| 向量 | `$FFFA/$FFFB` | | `$8400`（NMI） |
| 向量 | `$FFFC/$FFFD` | | `$8000`（reset） |
| 向量 | `$FFFE/$FFFF` | | `$8500`（IRQ） |

主程序：

```text
$8000  58           CLI                  ; I=0，IRQ 可响应；NMI 不受 I 影响
$8001  A9 00
$8003  8D 10 00     STA $0010            ; NMI 计数 = 0
$8006  A9 00
$8008  8D 11 00     STA $0011            ; IRQ 计数 = 0
$800B  A9 00
$800D  8D 12 00     STA $0012            ; PPU 初始化守卫 = 0
$8010  A9 00
$8012  8D 00 20     STA $2000            ; PPUCTRL = 0：NMI 关、渲染关
$8015  A9 00
$8017  8D 01 20     STA $2001            ; PPUMASK = 0
$801A  A9 00
$801C  8D 17 40     STA $4017            ; bit7=0 -> 4 步；bit6=0 -> 允许 frame IRQ
$801F  A9 01
$8021  8D 15 40     STA $4015            ; 使能 pulse1（必须早于 $4003）
$8024  A9 BF
$8026  8D 00 40     STA $4000            ; duty=2，bit5=1 halt + 恒定音量 15
$8029  A9 00
$802B  8D 01 40     STA $4001            ; sweep 关
$802E  A9 20
$8030  8D 02 40     STA $4002            ; 周期低 8 位 = $20
$8033  A9 40
$8035  8D 03 40     STA $4003            ; 长度表索引 8 (=160)，周期高位 = 0
$8038  AD 10 60     LDA $6010            ; $6000-$7FFF 译码到 CART_RAM，无 PRG RAM -> 00
$803B  C9 00
$803D  D0 C1        BNE $8800
$803F  AD 00 84     LDA $8400            ; NROM-128 镜像探针：下窗口
$8042  C9 AD
$8044  D0 BA        BNE $8800
$8046  AD 00 C4     LDA $C400            ; NROM-128 镜像探针：上窗口，必须读出同一字节
$8049  C9 AD
$804B  D0 B3        BNE $8800
$804D  AD 20 40     LDA $4020            ; open bus：返回上一次完成传输的字节
$8050  8D 13 00     STA $0013
$8053  A9 80
$8055  8D 00 20     STA $2000            ; PPUCTRL = $80：NMI 开
$8058  4C 58 80     JMP $8058            ; 自跳，等 NMI 与 IRQ
```

NMI / IRQ 服务例程：

```text
$8400  AD 12 00     LDA $0012            ; 首次进入才做 PPU 初始化
$8403  C9 00
$8405  D0 08        BNE $840F
$8407  A9 01
$8409  8D 12 00     STA $0012
$840C  20 00 86     JSR $8600            ; PPU 初始化子程序（只在第一次 NMI 里跑）
$840F  AD 10 00     LDA $0010
$8412  18           CLC
$8413  69 01        ADC #$01
$8415  8D 10 00     STA $0010            ; NMI 计数 +1
$8418  40           RTI

$8500  AD 15 40     LDA $4015            ; --- IRQ 服务例程，读即清 frame IRQ ---
$8503  8D 15 40     STA $4015            ; 写回确认
$8506  AD 11 00     LDA $0011
$8509  18           CLC
$850A  69 01        ADC #$01
$850C  8D 11 00     STA $0011            ; IRQ 计数 +1
$850F  40           RTI
```

PPU 初始化子程序（`$8600` 起，201 字节）的结构是 9 次 `PPUADDR` + `STA $2007`，中间 5 个 8 字节的 `LDX #8 / STA $2007 / DEX / BNE` 循环：

| 目标 | 写的内容 | 结果 |
| --- | --- | --- |
| `v = $0000` | 8 × `$FF` | `chr[0..7]`，tile 0 低平面全 1 |
| `v = $0010` | 8 × `$00` | `chr[16..23]` |
| `v = $0018` | 8 × `$FF` | `chr[24..31]`，tile 1 高平面全 1 |
| `v = $0020` | 8 × `$FF` | `chr[32..39]`，精灵 tile 2 低平面 |
| `v = $0028` | 8 × `$00` | `chr[40..47]`，精灵 tile 2 高平面 |
| `v = $2001` | `$01` | `nametable[1] = 1`（第 0 行第 1 列用 tile 1） |
| `v = $3F00` | `$0F`、`$21`、`$32` | 背景色、tile 0 调色板、tile 1 调色板 |
| `v = $3F11` | `$16` | 精灵 tile 2（`attr=0`、`pat=01`）的调色板 |
| `v = $0000` | — | 把 `t` 与 `v` 一起清零，滚动归位 |

之后 `$2003 = $00` + 4 次 `STA $2004` 写 OAM[0..3] = `$20,$02,$00,$08`（Y=32、tile 2、attr 0、X=8 的一个精灵），最后 `PPUMASK = $1E`（bit1/bit2 打开左侧 8 像素、bit3 开背景、bit4 开精灵）并 `RTS`。

几个容易踩的点，testbench 依赖它们：

- **NROM-128 探针的期望值是 `$AD`**：`$8400` 是 `LDA abs` 的操作码，而 `$C400` 因为 `prg_index = cart_addr[13:0]` 折叠回同一格，两者必须读出同一个字节。程序自己比较，任何一侧的镜像关系坏掉都会跳进 `$8800`。
- **`$6010` 必须读回 `$00`**：`$6000-$7FFF` 的 owner 是 `CART_RAM`，v2 没有 PRG RAM，`cart_din` 在 `cart_addr[15] == 0` 时给 `$00`。这同时覆盖了 owner 译码的第 4 类。
- **`LDA $4020` 返回上一次完成传输的字节**：上一步刚取完 `$4020` 的高字节 `$40`，所以 open bus 单元 `$0013` 必须是 `$40`。testbench 不只比这个常量，还通用地断言“任何 open bus 读 == 上一次完成传输的 `bus_din`”。
- **PPU 初始化在 NMI 服务例程里做**：因此全程 `ppu_rd == 0`，程序从不读 `$2002`，`vblank` 窗口等式可以在**每一个** `clk` 沿上逐拍成立。这是 v0 的 NMI testbench 做不到的（它的轮询循环会不断读 `$2002` 把 vblank 提前清掉）。
- **守卫标志在 `$0012`**：它本身被 testbench 精确计数（写 2 次：主程序清零 + 首次 NMI 置 1），配合 PPU 写事务的精确计数（`$2006` 18 次、`$2007` 45 次）就证明了初始化子程序只跑过一次。
- **相对分支基准是“操作码地址 + 2”**：`$803D` 的 `BNE` 跳 `$8800` 用 `$C1`，`$8044` 用 `$BA`，`$804B` 用 `$B3`，`$8405` 跳 `$840F` 用 `$08`；5 个 `STA $2007` 循环里的 `BNE` 一律用 `$FA`（回跳 6 字节）。
- **绝对分支搬不进 NMI 例程**：初始化子程序有 201 字节，8 位有符号相对位移装不下，所以用 `JSR $8600` / `RTS` 把它挪到独立地址。testbench 因此额外统计栈的 `$01F8/$01F9`，断言这次 `JSR`/`RTS` 只发生一次。

### 期望画面

`PPUCTRL = $80`、`PPUMASK = $1E`、`nametable[0] = 0` / `nametable[1] = 1`、其余 nametable 全 0、`chr` 见上表、`palette[00..02] = $0F/$21/$32`、`palette[11] = $16`、一个精灵在 `(32..39, 8..15)`：

| 区域 | 通路 | palette index | `pixel_index` |
| --- | --- | --- | --- |
| `y=0..7`、`x=8..15` | 背景 tile 1，pattern `10`，palette 2 | `$02` | **2** |
| `y=32..39`、`x=8..15` | 精灵 tile 2，pattern `01`，palette `$11` | `$11` | **6** |
| 其余全部可见像素 | 背景 tile 0，pattern `01`，palette 1 | `$01` | **1** |

精灵在 `y=32..39` 上是唯一在屏的精灵：OAM[4..255] 被 testbench 预填成 `$FF`（Y=255，任何扫描线都算不出 `0 <= scanline-255 < 8`），所以既不会溢出也不会多画。精灵 `attr[5] = 0`，优先级在背景之前，因此它在背景不透明的地方也照样显示自己的颜色。

断言按 `frame_done` 计：第 2 次 `frame_done` 之后打开检查、到第 3 次 `frame_done` 关闭，被检查的正好是一整帧（`240 × 256 = 61440` 个像素，其中 64 个是 2、64 个是 6、61312 个是 1）。`pixel_valid`、坐标、vblank 窗口、`nmi_o` 电平和 `frame_done` 位置在**每一个** `clk` 沿上检查，覆盖三整帧。

### 断言覆盖

1. **复位**：`ppu_dot`/`ppu_scanline` 为 `0:0`，`frame_done`/`vblank`/`nmi_o`/`apu_irq_o`/`audio_sample_valid` 全低，`bus_active` 低、`bus_wait_count` 为 0、`bus_req`/`bus_fire` 低，CPU 处于 `ST_RESET_0`，`PPUMASK` 为 `$00`，APU `dbg_frame_count` 为 0。
2. **owner 译码**：每个 `clk` 沿都从 `bus_addr` 重新推导 `owner` 与六个 `sel_*`，与被测顶层比对；任何一个地址区间没被分类、被重复分类或译错立刻失败。
3. **完成脉冲语义**：`ppu_reg_cs`/`apu_reg_cs`/`cart_xfer`/`ram_we` 都必须蕴含 `bus_fire` 且落在正确的 owner 上；`ppu_reg_cs`、`apu_reg_cs` 不得连续两拍为高（单拍脉冲）；`apu_reg_addr` 不得超过 `$17`；`cart_req` 不得出现在卡带窗口之外；`ppu_reg_we`/`apu_reg_we` 只能出现在对应 owner 的请求期间；`cart_ack` 恒 1。
4. **等待路径**：在每个 `ce_cpu` 拍上统计本次事务的停顿次数，`RAM`/`PPU`/`APU_IO`/`CART_*` 必须恰好 1 拍、`OWNER_OPEN` 必须 0 拍；`bus_stall` 必须等于 `bus_req && !bus_fire`；完成拍上 `bus_wait_count` 必须为 0（这正是 `READ_WAIT_CYCLES=1` 的形状）、`bus_active` 必须为 1（open bus 窗口则必须为 0）；继续停顿超过一拍时 `bus_active` 必须保持 1。
5. **`ce` 门控**：每个 `div_phase == 1` 的沿（也就是 `ce_cpu` 沿之后的那一拍）采样一次 `bus_active` 与 `bus_wait_count`；其余任何 `clk` 沿上这两个寄存器发生变化就立刻 `$fatal`。这条断言把“等待状态只在 CPU 使能沿推进”钉死，也是把 `u_bus` 的 `ce` 接成常电时的第一个失败点（实测报 `bus state moved on a clk without a cpu enable: div_phase=2 active 1->0 wait 0->0 addr=0000 req=1 stall=1`）。
6. **总线周期全覆盖账**：`prg_rd + ram_rd + ram_wr + ppu_rd + ppu_wr + apu_rd + apu_wr + open_rd + cartram_rd + prg_wr` 必须精确等于总完成次数。复位的 5 个 dummy 读已经落在 `ram_rd` 里，不再单独加。落到 `CART_ROM` 的写、非白名单 RAM 地址的写，全部立刻失败。
7. **CPU reset 序列**：`dbg_state` 为 5 时 `bus_addr == $FFFC`、为 6 时 `$FFFD`；进入 7 时 `dbg_pc == $8000`；该窗口之后第一次总线事务取到的操作码必须是 `$58`；全程 `dbg_illegal` 为 0；PC 永远在已编程的四段之内，落进 `$8800` 或任何空隙都失败。
8. **中断期间的 CPU 状态**：在 NMI 例程、IRQ 例程与初始化子程序里（PC 落在对应区间）且状态还没进 `RTI` 序列时，`I` 标志必须为 1、`sp` 不得超过 `$FA`；在主程序里取指时 `I` 必须为 0（首个 `CLI` 之前除外）、`sp` 必须为 `$FD`。
9. **中断的隔离性**：IRQ 服务例程里出现任何 PPU 寄存器传输即失败；NMI 例程与初始化子程序里出现任何 APU 寄存器传输即失败。
10. **NMI 链路**：每个 `clk` 沿断言 `nmi_o == vblank && PPUCTRL[7]`；每个 `nmi_o` 上升沿必须落在 `(241,1)`；NMI 上升沿数、`$FFFA` 向量取指数、`$0010` 的写入次数（除主程序那一次清零）与 `ram_array[$010]` 的终值四者必须互相相等。
11. **IRQ 链路**：逐 clk 断言 `apu_irq_o === (dbg_frame_irq | dbg_dmc_irq)` 且 `dbg_irq_pending === apu_irq_o`；`dbg_dmc_irq` 抬起来即失败（DMC DMA 没接线）；上升沿数 == 下降沿数 == `$FFFE` 向量取指数 == `$4015` ack 次数；`$4015` 写次数 == 1（主程序使能）+ 上升沿数；`ram_array[$011]` 等于 IRQ 次数。
12. **栈**：每次中断入口向 `$01FA/$01FB/$01FC` 各写 1 字节，次数精确等于 `3 × (NMI + IRQ)`；每个 `RTI` 从 `$01FB`（P）和 `$01FC`（PC 低字节）各读 1 次，次数精确等于入口数；`$01F8/$01F9` 的写与读都恰好 1 次（唯一一次 `JSR $8600` / `RTS`）。
13. **PPU 寄存器桥**：写按 `reg_addr` 精确分解——`$2000` 3 次、`$2001` 2 次、`$2003` 1 次、`$2004` 4 次、`$2006` 18 次、`$2007` 45 次、`$2002` 与其它 0 次；读必须为 0（所以 vblank 窗口不被截断）。
14. **APU 寄存器桥**：写 `$4000-$4003` 各 1 次、`$4017` 1 次、`$4015` 3 次（1 次使能 + 2 次 ack）、其它 0 次；读只有 `$4015` 2 次；读不到任何其它寄存器。
15. **open bus 与空窗口**：任何 `OWNER_OPEN` 读必须等于上一次完成传输的 `bus_din`（含地址），`$0013` 终值必须为 `$40`；`$6010` 读 1 次且值为 `$00`（由程序自己 `CMP`/`BNE` 保证）。
16. **CPU 真的改写了 PPU 状态**：最终 `PPUCTRL = $80`、`PPUMASK = $1E`、`v = $0000`、`t = $0000`、`fine_x = 0`、`w = 0`，`chr[0..7] = $FF`、`chr[8..15] = $00`、`chr[16..23] = $00`、`chr[24..31] = $FF`、`chr[32..39] = $FF`、`chr[40..47] = $00`，`nametable[1] = $01`，`palette[00..02] = $0F/$21/$32`、`palette[11] = $16`，`OAM[0..3] = $20/$02/$00/$08`。
17. **帧与 NMI 不被中断破坏**：`frame_done` 恰好 3 次且都落在 `(0,0)`；相邻间隔恰好 `262 × 341 × 4 = 357368` 个 `clk`；vblank 窗口等式逐 clk 成立，上升/下降沿各 3 次；被检查帧的 `pixel_valid` 采样点上坐标必须等于 `ppu_dot`/`ppu_scanline`，`pixel_index` 必须等于期望值，整帧计数必须是 61440 / 61312 / 64 / 64。
18. **音频**：`audio_sample_valid` 只在 `div_phase == 1` 为高且不得缺失，脉冲总数等于 APU 的 `ce` 脉冲总数（89343）；每个脉冲 `left == right`；`dbg_tnd_sum` 必须全程为 0（只有 pulse1 被使能）；非零样本数 > 0，峰值 4895；**服务中断期间的 `ce` 脉冲数与同期 sample 脉冲数相等**（1410/1410），证明采样通路不被中断序列打断；`dbg_pulse1_length` 终值精确为 160（`$4000[5]` halt 使长度不递减），`dbg_pulse1_mute` 为 0。
19. **全局超时**：`#40000000`（40 ms，约 11 帧）兜底。

### 运行

```powershell
$tmp = Join-Path $env:TEMP 'op_fpga_emu'
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
$v2 = @(
  'rtl\nes_core\system\nes_system_v2.v',
  'rtl\nes_core\bus\nes_cpu_bus.v',
  'rtl\nes_core\ppu\nes_ppu2c02.v',
  'rtl\nes_core\ppu\nes_ppu_sprite.v',
  'rtl\nes_core\cpu\nes_cpu6502.v',
  'rtl\nes_core\apu\nes_apu_pulse.v',
  'rtl\nes_core\apu\nes_apu_triangle.v',
  'rtl\nes_core\apu\nes_apu_noise.v',
  'rtl\nes_core\apu\nes_apu_dmc.v',
  'rtl\nes_core\apu\nes_apu_length_lut.v',
  'rtl\nes_core\apu\nes_apu2a03.v'
)
& 'C:\iverilog\bin\iverilog.exe' -g2001 -s nes_system_v2 -o (Join-Path $tmp 'nes_system_v2_core.vvp') $v2
& 'C:\iverilog\bin\iverilog.exe' -g2012 -s tb_nes_system_v2 -o (Join-Path $tmp 'tb_nes_system_v2.vvp') ($v2 + 'tb\system\tb_nes_system_v2.v')
& 'C:\iverilog\bin\vvp.exe' (Join-Path $tmp 'tb_nes_system_v2.vvp')
```

第一条是纯顶层 elaboration（`-g2001`，只编译 RTL），确认 `nes_system_v2` 本身不依赖 testbench 特性。源文件列表必须显式包含 `nes_cpu_bus.v`、`nes_ppu_sprite.v` 与全部五个 APU 通道/查找表文件，`iverilog` 不会自动去找。`tools/sim_all.ps1` 目前没有登记 v2 的 system 目标，本次没有改动它，上面三条命令是直接调用。

实测输出（Icarus Verilog 12.0，Windows，10 ns 时钟）：

```text
RESET ppu=0:0 frame/vblank/nmi/irq/sample low, bus idle, cpu state 0 PASS
OWNER the owner and the six sel bits are re-derived from cpu_addr and compared on every clk PASS
CPU reset FFFC/FFFD -> PC=8000 first opcode=58, illegal opcodes=0 PASS
WAIT every ram/ppu/apu/cart transfer took exactly one ce of stall, dbg_wait_count stayed 0, only the open bus window completed immediately
WAIT completed transfers=44672 stalled=44671 immediate=1 (all open bus reads) PASS
BUS owner accounting prg_rd=44523 ram_rd=37 ram_wr=27 ppu_rd=0 ppu_wr=73 apu_rd=2 apu_wr=8 open_rd=1 cartram_rd=1, the five reset dummies are counted as ram reads PASS
PPUREG writes ctrl=3 mask=2 vaddr=18 vdata=45 oamaddr=1 oamdata=4 status=0 other=0, reads=0, no ppu access inside the irq handler PASS
APUREG writes $4000-$4003=1 each, $4017=1, $4015=3, reads $4015=2, no apu access inside the nmi handler PASS
OPENBUS $4020 returned the previous completed transfer (40) and $6010 in the cart ram window returned 00 PASS
PPUSTATE ctrl=80 mask=1E v=0000 t=0000 w=0, chr[0:7]=ff [8:15]=00 [16:23]=00 [24:31]=ff [32:39]=ff [40:47]=00, nt[1]=01, pal=0f,21,32 and 11=16, oam=20,02,00,08 PASS
PRG main $8000-$805a (91 bytes), nmi handler $8400, setup routine $8600-$86c8 (201 bytes), irq handler $8500, fail loop $8800, vectors fffa=$8400 fffc=$8000 fffe=$8500
IRQ nmi rises=3 handler entries=3 ram[0010]=03, apu irq rises=2 falls=2 entries=2 ram[0011]=02 PASS
STACK every entry pushed pch/pcl/p to 01fa-01fc (15 frames of 3) and the rti pulled p and the pc low byte back (5 and 5), the setup jsr/rts touched 01f8-01f9 once
AUDIO ce pulses=89343 sample strobes=89343 nonzero=44352 peak=4895, strobes inside handlers=1410/1410 PASS
FRAME frame_done=3 period=357368clk vblank rises=3 falls=3, checked frame pixels=61440 index1=61312 index2=64 sprite6=64 PASS
PASS nes_system_v2
```

仿真时间 10.721 ms（3 帧），本机 vvp 约 56 s。任何 `$fatal` 命中会让 vvp 以非零退出码结束并打印失败条件、时间点与相关寄存器值。

### v2 testbench 绕过的问题

- **`$2002` 轮询会截断 vblank 窗口**：本 testbench 用 NMI 进入 vblank 做初始化，因此 `ppu_rd == 0`，可以断言逐 clk 的窗口等式。轮询式程序做不到这一点（v0 的 NMI testbench 就因此把窗口断言放松了一档），如果将来要覆盖轮询路径，窗口等式必须退化成“只在窗口内为高 + 上升沿只在 `(241,1)`”。
- **CPU RTL 的零页 `INC` 缺陷**：`decode_mode` 把 `$E6` 误列在 `AM_ZP`（本文档前面已记录）。本程序与两个服务例程的计数器全部用 `LDA / CLC / ADC #$01 / STA` 实现，绕开这条指令。
- **相对分支的 8 位范围**：初始化子程序 201 字节，超出 8 位位移能覆盖的范围，因此搬成子程序用 `JSR`/`RTS` 调用。这是程序布局的约束，不是 RTL 的缺陷，但它解释了为什么 v2 的 testbench 里多了一段栈事务的断言。

### v2 明确未实现

以下是**被测顶层 `nes_system_v2`** 的范围限制，不是 testbench 的缺陷：

- **OAM DMA（`$4014`）与 DMC DMA**：`bus_hold` 恒 0，总线上没有 DMA 仲裁点；`$4014` 被译码到 `APU_IO` owner 但 APU 内部只把它记成一次无副作用的访问（读回 `$00`）；APU 的 `dmc_rdata` 接 `8'h00`、`dmc_ack` 接 `1'b0`，DMC 一直 inactive，testbench 断言 `dbg_dmc_irq` 永不抬升。**没有**任何保护阻止未来程序启动 DMC 后把它挂在 `dmc_ack = 0` 上死等。
- **mapper**：`$8000-$FFFF` 没有 mapper 寄存器、没有 bank 切换、没有 IRQ，`PRG_SIZE_BYTES` 只是容量参数（默认 16 KiB，NROM-128 行为）。
- **`$6000-$7FFF` 没有 PRG RAM**：owner 是 `CART_RAM`，读回 `$00`、写丢弃。
- **音频输出通路**：没有 FIFO、没有抽取/重采样、没有 WM8978 接口。`audio_sample_valid` 是 `ce_cpu` 速率的 strobe（50 MHz 系统时钟下 4.17 MHz），不是音频速率。
- **左右声道差异**：`sample_left` 与 `sample_right` 取同一个 `mixed_sample`。
- **时钟频率**：见 `docs/modules/system-v2.md` 的“真实 50 MHz 频率问题仍未解决”一节。v2 保留 12 拍 `div_phase`（1 dot = 4 clk、1 CPU 周期 = 12 clk）作为仿真相位，没有解决上板频率。
- **跨时钟域**：v2 的全部模块都在同一个 `clk` 域，`ce` 是这个域里的使能信号，不涉及任何跨域握手。真正接 BRAM/SDRAM 或把 CPU core 放进自己的时钟域时，owner 侧的 ack 必须先同步回 `clk` 域，这一段没有实现。

---

## v3 testbench（`nes_system_v3`）

`tb_nes_system_v3.v` 是本目录第五个自检集成 testbench，也是**第一个真的把 DMA 当成第二个总线主机**的集成 testbench。v2 已经把 `nes_cpu_bus` 的等待路径跑起来（`req / ready / 完成脉冲 / owner`），但那条路上只有 CPU 一个主机；v3 加上 `nes_oam_dma` 与 `nes_cpu_bus` 的 DMA 通道，于是总线上第一次出现**两个主机 + 一个显式仲裁点**。

配套的设计说明在 `docs/modules/system-v3.md`，本节只写 testbench 自身（程序、断言、运行方式、实测输出）以及本次修掉的那个同沿竞争。v0/v1/v2 的文件、行为与本文档前面各节**未被修改**。

### 被测顶层接口增量（相对 v2）

v2 已经把总线与寄存器桥的观测信号提到正式端口上，v3 在此之上再开出 DMA 侧的观测端口。v3 testbench 的层次引用只剩四类：`dut.prg_rom`（装载程序镜像）、`dut.u_bus.ram_array`（读 RAM 计数单元与 DMA 源页）、`dut.u_ppu.*`（读最终状态与 `oam_addr_reg`）、`dut.u_cpu.dbg_*` / `dut.u_apu.dbg_*`（读 CPU/APU 内部状态）。

| 端口 | 宽度 | 含义 |
| --- | --- | --- |
| `bus_hold` | 1 | `oam_dma_cpu_hold \|\| apu_dmc_bus_req`，高时 CPU 被冻结，`nes_cpu_bus` 的 `ce` 拍整拍让给 DMA 分支 |
| `oam_dma_start` | 1 | 完成脉冲：`apu_xfer && apu_we && apu_addr == $4014`，即“CPU 完成了对 `$4014` 的写” |
| `oam_dma_cpu_hold` | 1 | `oam_dma_busy` 的直连，测试里断言两者逐 clk 相等 |
| `oam_dma_cpu_read_req` / `oam_dma_cpu_read_addr` / `oam_dma_cpu_read_ack` / `oam_dma_cpu_rdata` | 1/16/1/8 | OAM DMA 作为 DMA 主机的请求 / 地址 / 应答 / 读数据。`read_ack = dma_ack && !dma_sel` |
| `oam_dma_ppu_reg_cs` / `_we` / `_addr` / `_din` | 1/1/3/8 | OAM DMA 对 PPU 寄存器口的驱动，与 CPU 侧的 `ppu_xfer` 在顶层做源选择 |
| `oam_dma_busy` / `oam_dma_done` | 1 各一 | 引擎是否在 `ST_IDLE` 之外；`done` 只在最后一个 `$2004` 写周期为高 |
| `oam_dma_page` | 8 | 顶层影子寄存器 `oam_dma_page_q`，记的是**本次 `$4014` 写的数据** |
| `oam_dma_page_latch` | 8 | `nes_oam_dma` 内部的 `dbg_page`，即引擎实际锁到的源页 |
| `oam_dma_base_addr` / `oam_dma_cur_addr` / `oam_dma_index` | 8 各三 | 顶层影子 `OAMADDR` / 引擎当前 OAM 游标 / 字节下标 |
| `oam_dma_align_left` / `oam_dma_addr_wr` | 2/1 | 对齐相位剩余拍数 / 引擎是否驱动 `$2003`（`OAMADDR_WRITE=0`，必须恒为 0） |
| `oam_dma_cycle_count` | 16 | 引擎的 `ce` 计数 |
| `apu_dmc_bus_req` / `apu_dmc_addr` / `apu_dmc_ack` / `apu_dmc_rdata` | 1/16/1/8 | DMC DMA 侧的同一组握手，`apu_dmc_ack = dma_ack && dma_sel` |
| `dma_sel` / `dma_ack` / `dma_din` / `dma_wait` / `dma_active` / `dma_unimpl` / `dma_owner` | 1 各六 / 2 | `nes_cpu_bus` 的 DMA 通道。`dma_owner` 0=IDLE、1=OAM、2=DMC |
| `ppu_port_cs` / `ppu_port_we` / `ppu_port_addr` / `ppu_port_din` | 1/1/3/8 | 源选择之后**真正**接到 `nes_ppu2c02` 的那组口 |

### `$4014` 源页的同沿竞争与修法

这是本次修复的核心，也是 v3 testbench 存在的理由。

`$4014` 的写数据就是 DMA 源页号。顶层把它锁存在 `oam_dma_page_q`，`nes_oam_dma` 在 `ST_IDLE` 看到 `start` 的那一个沿采样 `src_page`：

```verilog
assign oam_dma_start = apu_xfer && apu_we && (apu_addr == APU_REG_OAMDMA);

always @(posedge clk or posedge reset) begin
    if (reset)              oam_dma_page_q <= 8'h00;
    else if (oam_dma_start) oam_dma_page_q <= apu_dout;
end
```

```verilog
ST_IDLE: if (start) begin
    page_q      <= src_page;
    read_addr_q <= {src_page, 8'h00};
end
```

两个寄存器在**同一个 `posedge clk` 上更新**，都只看到沿前的值，因此 `nes_oam_dma` 锁到的是**上一页**。后果是每次 DMA 都用上一页搬运（第一次 `$00`、第二次 `$00`、第三次 `$05`），而所有“地址顺序 / ack 数量 / `$2004` 写入顺序”的断言**都不会**报错——地址确实自洽，只有页号是错的。

修法是**旁路而不是延时**：`nes_oam_dma` 只在 `start` 为高的那一个沿采样 `src_page`，而“沿前的正确页号”此刻就在 `apu_dout` 上，所以把它直接喂进去：

```verilog
.start    (oam_dma_start),
.src_page (oam_dma_start ? apu_dout : oam_dma_page),
```

`oam_dma_page_q` **保留**：它是 testbench 断言“顶层记住的页”与“引擎锁到的页”必须一致的唯一可观测量（`oam_dma_page` / `oam_dma_page_latch`），也是 `oam_dma_page` 调试端口的语义来源。修法不删寄存器，只把引擎的采样源在 `start` 那一拍换成正确的那个值；其余所有拍 `src_page = oam_dma_page`，与旧行为逐拍相同。详细推导（以及为什么不把 `start` 延后一拍拍）见 `docs/modules/system-v3.md` 第 5 节。

对应的 testbench 断言写成**即时 `$fatal`**，而不是计数器加结算期汇总：

```verilog
if (oam_dma_busy !== 1'b0 && oam_dma_page !== oam_dma_page_latch)
    $fatal(1, "the source page latch disagreed with the engine, page=%02x latch=%02x",
           oam_dma_page, oam_dma_page_latch);
```

这类同沿竞争一旦发生，后面 768 个字节的内容比较全部是垃圾值，汇总式断言要么误报一堆无关的“内容不符”，要么被前面的失败掩盖。实测：把 `.src_page` 退回 `oam_dma_page` 的临时副本，第一次 DMA 一开始就报

```text
FATAL: tb/system/tb_nes_system_v3.v:1461: the source page latch disagreed with the engine, page=02 latch=00
       Time: 5140855000
```

### PRG 程序

镜像由 testbench 用 `emit` / `lda_imm` / `lda_abs` / `sta_abs` / `sta_abs_x` / `ppu_set_addr` / `ppu_fill8` / `jsr_abs` 等任务逐字节装配，相对分支的位移由 `bne_to`（回跳）与 `bne_list_add` + `bne_list_patch`（前跳，先占位后回填）自动算出。表 `$8900` / `$8A00` 是 DMA 源页 `$0200` / `$0500` 的内容源（前 4 字节固定、其余按 `n` 的奇偶填出可区分的图案），testbench 用同一个生成器同时写进 `prg_rom` 和期望数组，因此“CPU 拷进 RAM 的”与“DMA 从 RAM 搬进 OAM 的”必须逐字节相等。

| 区段 | 地址 | 字节 | 内容 |
| --- | --- | --- | --- |
| 主程序 | `$8000-$8073` | 116 | 关渲染、清计数与标记单元、配 APU pulse1、NROM-128 镜像探针、open bus 探针、三次 DMA 结束后的开 NMI、自跳 |
| NMI 服务例程 | `$8400-$8418` | 25 | 首次进入 `JSR $8600` 做 PPU 初始化与三次 OAM DMA，之后只累加 `$0010` 并 `RTI` |
| IRQ 服务例程 | `$8500-$850F` | 16 | `LDA $4015` / `STA $4015` ack，累加 `$0011`，`RTI` |
| PPU/DMA 初始化子程序 | `$8600-$8703` | 260 | `$0200`→`$0200+256`、`$0500`→`$0500+256` 两段拷贝（256 + 256 字节），再写 CHR / nametable / palette / `OAMADDR` / 三次 `$4014` / `$2004` 回读校验 |
| 失败死循环 | `$8800-$8802` | 3 | 任何一处探针不通过就跳进来 |
| DMA 源表 1 / 2 | `$8900` / `$8A00` | 各 256 | 3 次 DMA 的源镜像 |
| 向量 | `$FFFA/$FFFB` | | `$8400`（NMI） |
| 向量 | `$FFFC/$FFFD` | | `$8000`（reset） |
| 向量 | `$FFFE/$FFFF` | | `$8500`（IRQ） |

三次 DMA 的参数与期望效果：

| 传输 | `OAMADDR` 基址 | `$4014` 页 | 效果 | 检查方式 |
| --- | --- | --- | --- | --- |
| 1 | `$00` | `$02` | `oam[0..255] = table1[0..255]` | 全部 256 字节 + 4 个标记单元 |
| 2 | `$F0` | `$05` | `oam[$F0..$FF] = table2[0..15]`，`oam[$00..$EF] = table2[16..255]`（OAMADDR 回卷） | 全部 256 字节 + 前后游标断言 |
| 3 | `$00` | `$02` | 恢复 `table1`，最终 OAM 内容回到 table1 | 全部 256 字节 + CPU 侧 `LDA $2004` 回读 |

`$2004` 的回读是这套 testbench 里**唯一一条程序自证的 DMA 正确性判据**：DMA1 之后 `LDA $2004` 必须读到 `oam[0] = table1[0] = $20`，DMA2 之后必须读到 `oam[$F0] = table2[0] = $A0`（DMA2 从 `$F0` 起了 256 字节，`$00-$EF` 已经被回卷覆盖，所以读到的是表头），两次都用 `CMP` / `BNE $8800` 判死。程序自证的通过之后，testbench 才去逐字节比对 `oam_ram`。

### 三处过时期望值的修正

修好 RTL 之后，testbench 里有三条期望值本身是过期的。这三条都**不是**放宽总线或栈地址断言，总线的地址白名单、`$8000-$FFFF` 的 PC 范围断言、`$01F0-$01FF` 的栈地址断言**一条都没有改**。

1. **`RTI` 期间 `dbg_pc` 落在 `nmi_end` / `irq_end` 上是合法的。** `nmi_end` / `irq_end` 是 `RTI` 指令自身的地址（`emit(8'h40); nmi_end = pc;`），`RTI` 的取指、三个出栈周期、返回地址恢复都在 `dbg_pc == nmi_end` 这一个值上停留，所以“跑过服务例程”的判据必须用 `dbg_pc > nmi_end`（严格大于）而不是 `dbg_pc > nmi_end - 1`。`init_end` 那一条保持 `init_end - 1`（`RTS` 之后 PC 直接跳回，不会停留），不动。
2. **`OPEN_BUS_CELL` 被程序写了两次。** `build_main` 里 `STA $0017` 出现两次：主程序开头清零一次，`LDA $4020` 之后把 open bus 探针存回去一次。期望值从 1 改为 2。`check_owner_accounting` 仍然断言终值等于 `probe_opcode`（`$4020` 返回上一次完成传输的 sticky 字节 `$40`），所以“写了两次”不等于“少了一次有效探针”。
3. **`jsr_frame` 只统计 `$01F9`。** `JSR` 压栈是 `$01F9 <- PCH`、`$01F8 <- PCL`，`RTS` 从同一对地址读回；`$01F9` 的写恰好对应一次 `JSR`，`$01F8` 只是这次 `JSR` 的另一半。原先 `$01F8/$01F9` 一起计数会让 `jsr_frame` 变成 2，`check_interrupts` 里的 `jsr_frame != 1` 因此失败。现在 `$01F9` 单独计数、$01F8 移进**合法栈写白名单**（`$01F0-$01FF` 本来就全部合法，白名单只表示“不计入 `jsr_frame`”）。`stk_rd` / `stk_wr` 对 `$01F0-$01FF` 的逐地址统计保持不变。

另外两处是 v3 才有的判据调整，与上面三条同源：

4. **`dma_active_err` 改成“active 一旦拉高必须保持到 ack”。** `nes_cpu_bus` 的 `dma_active = dma_grant && dma_active_r`，而 `dma_active_r` 在看到请求的那一个 `ce` 沿**之后**才置 1，`dma_ready` 又要求它为 1 才可能给 `dma_ack`。所以请求的第一个 `ce` 拍上 `dma_active` 必然还是 0——这是正常的一拍状态机延迟。原先的 `req && !ack && !dma_active → err` 会在 768 个字节上稳定失败。新判据用 `dma_active_seen` 记录“已经进过等待”，之后只要 `dma_active` 还高着而 `dma_ack` 没来就计错，即“进入等待后不允许中途退出等待”。这条更强也更准确：`dma_active_r` 被 `!dma_grant` 分支提前清掉这类真实握手漏洞仍会被抓住。
5. **`dma_page_latch_err` 提前变成 `$fatal`。** 原来它在每个 `clk` 上累加，等 4 帧跑完才在 `check_dma_transfers` 里汇总报出来；改成在累加的那一行就地 `$fatal`（见上面 `$4014` 一节）。

### 断言覆盖

1. **复位**：`ppu_dot`/`ppu_scanline` 为 `0:0`，`frame_done`/`vblank`/`nmi_o`/`apu_irq_o`/`audio_sample_valid` 全低，`bus_active` 低、`bus_wait_count` 为 0、`bus_req`/`bus_fire`/`bus_hold` 低，`oam_dma_busy`/`oam_dma_cpu_hold`/`dma_ack`/`apu_dmc_bus_req` 低，CPU 处于 `ST_RESET_0`，`oam_addr_q` 与 `oam_dma_page_q` 为 `$00`，APU `dbg_frame_count` 为 0。
2. **owner 译码与全覆盖账**：`prg_rd + ram_rd + ram_wr + ppu_rd + ppu_wr + apu_rd + apu_wr + open_rd + cartram_rd + prg_wr` 必须精确等于总完成次数。open bus 读恰好 1 次、CART_RAM 读恰好 1 次、落进 PRG 的写必须为 0，非白名单 RAM 地址的写立刻失败。
3. **等待路径**：在每个 `ce_cpu` 拍上统计本次事务的停顿次数，`RAM`/`PPU`/`APU_IO`/`CART_*` 必须恰好 1 拍、`OWNER_OPEN` 必须 0 拍；`bus_stall` 必须等于 `bus_req && !bus_fire`；完成拍上 `bus_wait_count` 必须为 0、`bus_active` 必须为 1（open bus 窗口则必须为 0）；open bus 读数必须等于上一次完成传输的 `bus_din`。
4. **`ce` 门控**：每个 `div_phase == 1` 的沿采样一次 `bus_active` 与 `bus_wait_count`；其余任何 `clk` 沿上这两个寄存器发生变化就立刻 `$fatal`。
5. **DMA 仲裁点**：`bus_hold === (oam_dma_cpu_hold || apu_dmc_bus_req)` 与 `oam_dma_cpu_hold === oam_dma_busy` 逐 clk 相等；`bus_hold` 期间 `bus_fire`/`bus_req`/`ppu_reg_cs`/`apu_reg_cs` 全为 0；`dma_wait === (req && !ack)`；`dma_active` 一旦拉高必须保持到 `dma_ack`；`dma_sel`/`apu_dmc_bus_req`/`oam_dma_addr_wr`/`dma_unimpl` 全程为 0。
6. **CPU 冻结**：每次 DMA 的 `bus_hold` 窗口内 `dbg_state` 与 `dbg_pc` 逐 clk 不得变化（`dma_freeze_fail`）。
7. **DMA 协议**：`dma_ack` 必须带 `bus_hold`、不得与 `bus_fire` 同拍、不得连续两拍；`oam_dma_cpu_read_ack` 必须为高且 `dma_owner == 0`；`oam_dma_cpu_rdata` 必须等于 `dma_din`；每次 ack 的 `oam_dma_cpu_read_addr` 必须等于 `{page, byte_index}` 且 `dma_din` 必须等于该地址的 `ram_array` 内容；`oam_dma_index` 必须等于字节下标。
8. **`$2004` 写顺序**：每个 `oam_dma_ppu_reg_cs` 拍上 `ppu_reg_addr == $2004`、`ppu_reg_we == 1`、不得连续两拍；`oam_dma_ppu_reg_dout` 必须等于上一次被 ack 的 `dma_din`，且等于 `{page, wr_index}` 处的 `ram_array` 内容（3 × 256 全部比对）。
9. **`$2003` 影子**：`oam_dma_base_addr` 逐 clk 等于 `dut.u_ppu.oam_addr_reg`；`oam_dma_cur_addr` 在 `busy` 期间逐 clk 等于 `dut.u_ppu.oam_addr_reg`。
10. **端口 mux**：`ppu_port_cs === (oam_dma_ppu_reg_cs || ppu_reg_cs)` 逐 clk 成立；`oam_dma_ppu_reg_cs` 与 `ppu_reg_cs` 不得同时为高；`ppu_reg_cs` / `apu_reg_cs` 不得连续两拍为高且必须蕴含 `bus_fire` 与正确的 owner；`apu_reg_addr` 不得超过 `$17`；`cart_req` 不得出现在卡带窗口之外；`cart_ack` 恒 1。
11. **PPU 寄存器桥**：写按 `reg_addr` 精确分解——`$2000` 2 次、`$2001` 2 次、`$2003` 3 次、`$2006` 18 次、`$2007` 45 次、`$2002` 与其它 0 次；**`$2004` 写 0 次**（OAM 只由 DMA 与 testbench 预填决定）；读 2 次且两次都是 `$2004`；IRQ 服务例程里出现任何 PPU 寄存器传输即失败。
12. **APU 寄存器桥**：写 `$4000-$4003` 各 1 次、`$4017` 1 次、`$4014` 3 次（3 次 DMA 触发）、`$4015` `1 + IRQ 次数` 次、其它 0 次；读只有 `$4015`，次数等于 IRQ 次数；NMI 服务例程与初始化子程序里出现任何 `$4014` 以外的 APU 寄存器传输即失败；写 `$4015` 次数 == 读 `$4015` 次数（每次读都被 ack）。
13. **NMI 链路**：逐 clk 断言 `nmi_o === vblank && PPUCTRL[7]`；每个 `nmi_o` 上升沿必须落在 `(241,1)`；NMI 上升沿数、`$FFFA` 向量取指数、`$0010` 的写入次数（除主程序那一次清零）与 `ram_array[$010]` 的终值四者必须互相相等。
14. **IRQ 链路**：逐 clk 断言 `apu_irq_o === (dbg_frame_irq | dbg_dmc_irq)` 且 `dbg_irq_pending === apu_irq_o`；`dbg_dmc_irq` 抬起来即失败；上升沿数 == 下降沿数 == `$FFFE` 向量取指数 == `$4015` ack 次数；仿真结束时 `apu_irq_o == 0`、`dbg_nmi_pending == 0`。
15. **CPU 状态**：无非法指令；`dbg_state` 为 5 时 `bus_addr == $FFFC`、为 6 时 `$FFFD`；进入 7 时 `dbg_pc == $8000`；该窗口之后第一次总线事务的 `dbg_opcode == $58`；PC 永远在 `$8000-$8802` 之内，且四段已编程代码之间的四段空隙（`$8074-$83FF`、`$841A-$84FF`、`$8511-$85FF`、`$8704-$87FF`）以及 `$8800` 失败死循环落进来都失败；在 handler 内且还没进 `RTI` 序列时 `I` 标志必须为 1、`sp` 不得超过 `$FA`；在主程序里取指时 `I` 必须为 0、`sp` 必须为 `$FD`。
16. **栈**：`$01F0-$01FF` 逐地址记账（`stk_rd` / `stk_wr`），非白名单 RAM 写立刻失败；`$01F9` 的写次数（`jsr_frame`）必须为 1，即唯一一次 `JSR $8600`。
17. **音频**：`audio_sample_valid` 只在 `div_phase == 1` 为高且不得缺失，脉冲总数等于 APU 的 `ce` 脉冲总数；每个脉冲 `left == right`；`dbg_tnd_sum` 必须全程为 0（只有 pulse1 被使能）；非零样本数 > 0，峰值 4895；服务 handler 期间的 `ce` 脉冲数与同期 sample 脉冲数相等；`dbg_pulse1_length` 终值精确为 160（`$4000[5]` halt 使长度不递减），`dbg_pulse1_mute` 为 0，`dbg_dmc_irq` 为 0。
18. **CPU 真的改写了 PPU 状态**：最终 `PPUCTRL = $80`、`PPUMASK = $1E`、`v = $0000`、`t = $0000`、`fine_x = 0`、`w = 0`、`oam_addr_reg = $00`，`chr[0..7] = $FF`、`chr[8..15] = $00`、`chr[16..23] = $00`、`chr[24..31] = $FF`、`chr[32..39] = $FF`、`chr[40..47] = $00`，`nametable[1] = $01`，`palette[00..02] = $0F/$21/$32`、`palette[11] = $16`。
19. **帧与 NMI 不被 DMA 破坏**：`frame_done` 恰好 4 次且都落在 `(0,0)`；相邻间隔恰好 `262 × 341 × 4 = 357368` 个 `clk`；vblank 窗口等式逐 clk 成立，上升/下降沿各 4 次；被检查帧的 `pixel_valid` 采样点上坐标必须等于 `ppu_dot`/`ppu_scanline`，`pixel_index` 必须等于期望值，整帧计数必须是 61440 / 61312 / 64 / 64。
20. **全局超时**：`#40000000`（40 ms，约 11 帧）兜底；4 帧需要约 14.3 ms，落在超时之内。

### 运行

```powershell
$tmp = Join-Path $env:TEMP 'op_fpga_emu'
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
$v3 = @(
  'rtl\nes_core\system\nes_system_v3.v',
  'rtl\nes_core\bus\nes_cpu_bus.v',
  'rtl\nes_core\ppu\nes_ppu2c02.v',
  'rtl\nes_core\ppu\nes_ppu_sprite.v',
  'rtl\nes_core\ppu\nes_oam_dma.v',
  'rtl\nes_core\cpu\nes_cpu6502.v',
  'rtl\nes_core\apu\nes_apu_pulse.v',
  'rtl\nes_core\apu\nes_apu_triangle.v',
  'rtl\nes_core\apu\nes_apu_noise.v',
  'rtl\nes_core\apu\nes_apu_dmc.v',
  'rtl\nes_core\apu\nes_apu_length_lut.v',
  'rtl\nes_core\apu\nes_apu2a03.v'
)
& 'C:\iverilog\bin\iverilog.exe' -g2001 -s nes_system_v3 -o (Join-Path $tmp 'nes_system_v3_core.vvp') $v3
& 'C:\iverilog\bin\iverilog.exe' -g2012 -s tb_nes_system_v3 -o (Join-Path $tmp 'tb_nes_system_v3.vvp') ($v3 + 'tb\system\tb_nes_system_v3.v')
& 'C:\iverilog\bin\vvp.exe' (Join-Path $tmp 'tb_nes_system_v3.vvp')
```

第一条是纯顶层 elaboration（`-g2001`，只编译 RTL），确认 `nes_system_v3` 本身不依赖 testbench 特性。源文件列表必须显式包含 `nes_cpu_bus.v`、`nes_ppu_sprite.v`、`nes_oam_dma.v` 与全部五个 APU 通道/查找表文件，`iverilog` 不会自动去找。`tools/sim_all.ps1` 目前没有登记 v3 的 system 目标，本次没有改动它（本次只改了 RTL、`tb/system` 的 testbench 与文档），上面三条命令是直接调用。

实测输出（Icarus Verilog 12.0，Windows，10 ns 时钟）：

```text
RESET ppu=0:0 oamaddr=0 frame/vblank/nmi/irq/sample low, bus idle, bus_hold=0, dma idle PASS
CPU reset FFFC/FFFD -> PC=8000 first opcode=58, illegal opcodes=0 PASS
WAIT every ram/ppu/apu/cart transfer took exactly one ce of stall, dbg_wait_count stayed 0, only the open bus window completed immediately
WAIT cpu transfers=58794 stalled=58793 immediate=1 (all open bus reads) PASS
BUS owner accounting prg_rd=57589 ram_rd=560 ram_wr=556 ppu_rd=2 ppu_wr=70 apu_rd=3 apu_wr=12 open_rd=1 cartram_rd=1 prg_wr=0, $4020 returned the sticky bus value 40 PASS
DMABUS bus_hold = oam_dma_cpu_hold || apu_dmc_bus_req, the oam>dmc grant never needed the dmc path, no cpu transfer and no register access inside any dma window, cpu state and pc frozen for all 3 transfers PASS
DMAHOLD per transfer ce held=512/512/512, clk held=6145/6145/6145, align clks=0/0/0, 256 acks and 256 $2004 writes each PASS
OAMDMA transfer 1 base=00 page=02 gives oam[0..255]=table1[0..255] in order, transfer 2 base=f0 page=05 gives oam[f0..ff]=table2[0..15] and oam[00..ef]=table2[16..255] (oamaddr wrap), transfer 3 base=00 page=02 restores table1, the cpu readback of $2004 saw the dma result PASS
PPUREG writes ctrl=2 mask=2 vaddr=18 vdata=45 oamaddr=3 oamdata=0 status=0 other=0, cpu reads oamdata=2, the cpu never drives $2004, no ppu access inside the irq handler PASS
APUREG writes $4000-$4003=1 each, $4017=1, $4014=3 (oam dma triggers), $4015=4, reads $4015=3, $4014 writes are the only apu access inside the nmi handler PASS
PPUSTATE ctrl=80 mask=1E v=0000 t=0000 w=0 oamaddr=00, chr[0:7]=ff [8:15]=00 [16:23]=00 [24:31]=ff [32:39]=ff [40:47]=00, nt[1]=01, pal=0f,21,32 and 11=16 PASS
PRG main $8000-$8073 (116 bytes), nmi handler $8400-$8418, irq handler $8500-$850f, init routine $8600-$8703 (260 bytes), fail loop $8800, tables $8900 and $8a00, vectors fffa=$8400 fffc=$8000 fffe=$8500
IRQ nmi rises=4 entries=4 ram[0010]=04, apu irq rises=3 falls=3 entries=3 ram[0011]=03, the oam dma ran inside the nmi handler PASS
AUDIO ce pulses=119124 sample strobes=119124 nonzero=59252 peak=4895, strobes inside handlers=17402/17402, pulse1 length=160 PASS
FRAME frame_done=4 period=357368clk vblank rises=4 falls=4, checked frame pixels=61440 index1=61312 index2=64 sprite6=64 PASS
PASS nes_system_v3
```

仿真时间 14.295 ms（4 帧）。任何 `$fatal` 命中会让 vvp 以非零退出码结束并打印失败条件、时间点与相关寄存器值。

### 变异验证

为确认断言不是空跑，对 `nes_system_v3.v` 的副本（不改动仓库文件）做了单点变异：

| 变异 | 结果（vvp 退出码 1 的断言） |
| --- | --- |
| `.src_page` 退回 `oam_dma_page`（即本次修掉的同沿竞争） | `the source page latch disagreed with the engine, page=02 latch=00`，`t=5140855000` |

### v3 testbench 绕过的问题

- **`$2002` 轮询会截断 vblank 窗口**：本 testbench 同样用 NMI 进入 vblank 做初始化，因此 `ppu_rd == 2`（两次都是 `$2004`），程序从不读 `$2002`，所以 vblank 窗口等式可以断言到**每一个** `clk` 沿。轮询式程序做不到这一点，窗口等式必须退化成“只在窗口内为高 + 上升沿只在 `(241,1)`”。
- **CPU RTL 的零页 `INC` 缺陷**：`decode_mode` 把 `$E6` 误列在 `AM_ZP`（本文档前面已记录）。本程序与服务例程的计数器全部用 `LDA / CLC / ADC #$01 / STA` 实现，绕开这条指令。
- **对齐相位不被区分**：`nes_oam_dma` 的起始对齐相位来自它内部的 `parity_q`（总 `clk` 奇偶），而不是 CPU 周期奇偶，因为 v3 不实现 `OAMADDR_WRITE`（真机 DMA 期间写 `$2003` 的那一拍）。实测三个传输的 `align clks` 全为 0，即它们落在同一边界上，因此 testbench 不覆盖“对齐相位跨 DMA 不对齐”这个失效模式。
- **栈的逐地址计数没有被断言**：`stk_rd` / `stk_wr` 对 `$01F0-$01FF` 记账了，但除了 `$01F9` 的写次数（`jsr_frame`）之外没有对它们的**总量**做 `$fatal` 断言；v2 的 testbench 有更细的栈断言，v3 把它简化成了合法白名单 + `jsr_frame`。v3 的栈覆盖因此弱于 v2。

### v3 明确未实现

以下是**被测顶层 `nes_system_v3`** 的范围限制，不是 testbench 的缺陷；完整清单见 `docs/modules/system-v3.md` 第 7 节：

- **DMC DMA 通路存在但从未被激励**：`apu_dmc_bus_req` 进了 `bus_hold` 与 `dma_req_dmc`，`dma_sel` 也会译码到 `apu_dmc_ack`，但本程序从不写 `$4010-$4013`，testbench 断言 `apu_dmc_bus_req` 与 `dma_sel` 全程为 0、`dbg_dmc_irq` 永不抬升。**没有**任何保护阻止未来程序启动 DMC 后撞上一个未验证的握手。
- **`OAMADDR_WRITE = 0`**：DMA 不驱动 `$2003`，`$2003` 的影子在顶层维护；代价是起始对齐相位跟随 `clk` 奇偶而不是 CPU 周期奇偶。
- **mapper**：`$8000-$FFFF` 没有 mapper 寄存器、没有 bank 切换、没有 mapper IRQ，`PRG_SIZE_BYTES` 只是容量参数（默认 16 KiB，NROM-128 行为）。
- **`$6000-$7FFF` 没有 PRG RAM**：owner 是 `CART_RAM`，读回 `$00`、写丢弃。**`$4018-$5FFF`** 读 `$00`、写忽略。
- **sprite 0 hit / overflow**：`nes_ppu_sprite` 在系统里且精灵渲染工作（被检查帧 `sprite6 = 64`），但 `dbg_sprite0_hit` / `dbg_sprite_overflow` 悬空，v3 TB 不覆盖。
- **音频输出通路**：没有 FIFO、没有抽取/重采样、没有 WM8978 接口。`audio_sample_valid` 是 `ce_cpu` 速率的 strobe，不是音频速率；左右声道取同一个 `mixed_sample`。
- **上板频率与跨时钟域**：v3 保留 12 拍 `div_phase` 作为仿真相位，全部模块在同一 `clk` 域，未解决 `docs/modules/system-v2.md` 记录的真实频率问题，也没有 owner 侧 ack 回到 `clk` 域的同步逻辑。

---

## v4 testbench（`nes_system_v4`）

`tb_nes_system_v4.v` 是本目录第六个自检集成 testbench，也是**第一个把标准手柄接进系统的**集成 testbench。v3 已经把 DMA 当成第二个总线主机、把 owner/ready/valid 与完成脉冲跑起来；v4 在这套接线上只加一个 `nes_controller` 和一次总线 override，DMA / PPU / APU / NMI / IRQ / NROM / 等待总线**逐拍保持 v3 的行为**，并额外把 3 个新端口开出来。

配套的设计说明在 `docs/modules/system-v4.md`（含"C 模拟器怎么把 SDL 事件变成 controller bit 数组"与"硬件并联输入 + 4021 + 总线 override 的对应"），本节只写 testbench 自身。v0/v1/v2/v3 的文件、行为与本文档前面各节**未被修改**。

### 被测顶层接口增量（相对 v3）

v3 的 80 个端口在 v4 里全部保留、一个都没删。v4 只**新增**三个：

| 端口 | 方向 | 宽度 | 含义 |
| --- | --- | --- | --- |
| `buttons1` | in | 8 | 1P 按钮位图，**bit0..bit7 = A, B, Select, Start, Up, Down, Left, Right**（NESdev 的 `$4016` 串行输出顺序，不是本项目定的） |
| `buttons2` | in | 8 | 2P 按钮位图，位序同上 |
| `controller_data` | out | 1 | 串行数据线，**高 = 按下**。它直接驱动 CPU 读数据 mux 的 bit0 |

`controller_data` 被插在 `apu_reg_addr` 与 `cart_req` 之间，只是为了读端口表时和它 override 的那个窗口挨在一起；命名端口连接，顺序无关。

testbench 在顶层把 `buttons1`/`buttons2` 接成常量 `8'hA5` / `8'h5A`，**不依赖任何外部硬件、按键或激励文件**：

```text
buttons1 = 8'b1010_0101   A=1 B=0 Select=1 Start=0 Up=0 Down=1 Left=0 Right=1
buttons2 = 8'b0101_1010   两个口在 8 个方向上完全相反，任何"两个口读串了"的缺陷立刻可见
```

层次引用只有四类，和 v3 同源：`dut.prg_rom`（装载程序镜像与 DMA 源表）、`dut.u_bus.ram_array`（读结果单元与 DMA 源页）、`dut.u_ppu.*` / `dut.u_apu.dbg_*`（读最终状态）、以及 v4 新增的 `dut.latch_strobe_q` / `dut.apu_ctrl_xfer` / `dut.apu_we` / `dut.apu_addr` / `dut.u_controller.dbg_*` / `dut.u_apu.reg_wr_frame`（证明 `$4017` 写真的进了帧计数器，而不只是"端口说有访问"）。

### controller override 的边界

override 是**按地址 + 方向**划的，不是整段地址：

| 访问 | controller 做什么 | `apu_reg_cs` |
| --- | --- | --- |
| `$4016` 读 | port 1 移位，串行位进 `cpu_din[0]` | 0 |
| `$4016` 写 | 加载共享 `/PL` | 0 |
| `$4017` 读 | port 2 移位，串行位进 `cpu_din[0]` | 0 |
| **`$4017` 写** | **不参与** | **1**（`reg_wr_frame` 成立） |
| `$4000-$4015` 其余 | 不参与 | 1 |

即 override 集合是"**读 `$4017` + 全部 `$4016`**"。写 `$4017` 必须继续送到 APU 帧计数器（v3 的程序正是靠 `STA $4017` 配帧计数器，对应判据是 `apu_wr_frame == 1`），而共享 `/PL` 仍然只由 `$4016` 的写加载。边界表达式是 `apu_addr_ctrl_owned = apu_addr_ctrl1 || (apu_addr_ctrl2 && !apu_we)`，`apu_port_cs = apu_xfer && !apu_addr_ctrl_owned`；`!apu_we` 那一项同时保护了读数据 mux（`cpu_din` 的覆盖条件是 `apu_ctrl_xfer`），否则 `$4017` 写周期上 `cpu_din` 会被换成串行位、紧接着的取指读到垃圾操作码。

### 程序：控制器测试在前，回归在后

`$8000` 起 489 字节，reset vector 指向 `$8000`：

| 区段 | 地址 | 字节 | 内容 |
| --- | --- | --- | --- |
| 主程序 | `$8000-$81E8` | 489 | 清 6 个计数/标志单元、**port 1 的写 1/写 0 + 8 次读 + 第 9 次读 + 9 次逐位比较**、**port 2 的同样一遍**、`LDA #$00 / STA $4017` 配帧计数器、配 APU pulse1、`$0200` 拷贝、DMA、CHR/nametable/palette、`$2003=0` + `$4014` + `$2004` 回读、`PPUMASK=$1E` + `PPUCTRL=$80`、自跳 |
| NMI 服务例程 | `$8400-$8409` | 10 | `LDA $0010 / CLC / ADC #$01 / STA $0010 / RTI` |
| IRQ 服务例程 | `$8500-$850F` | 16 | `LDA $4015 / STA $4015`（读即清 frame IRQ）、累加 `$0011`、`RTI` |
| 失败死循环 ×3 | `$8800` / `$8810` / `$8820` | 各 3 | 分别为 port 1 读错、port 2 读错、`$2004` 回读错 |
| DMA 源表 | `$8900-$89FF` | 256 | `[0..3] = $20,$02,$00,$08`（一个精灵），其余全 `$FF`（Y=255，任何扫描线都算不出来） |
| 向量 | `$FFFA/$FFFB` | | `$8400`（NMI） |
| 向量 | `$FFFC/$FFFD` | | `$8000`（reset） |
| 向量 | `$FFFE/$FFFF` | | `$8500`（IRQ） |

一个端口的完整序列（`k = 0..7`）：

```text
        A9 01        LDA #$01
        8D 16 40     STA $4016          ; /PL 拉高
        A9 00        LDA #$00
        8D 16 40     STA $4016          ; /PL 拉低，快照冻结
        A2 00        LDX #$00
loop:   AD 16 40     LDA $4016          ; 读第 k 位
        9D 20 00     STA $0020,X        ; 存进 RAM（端口 1 用 $0020，端口 2 用 $0028）
        E8           INX
        E0 08        CPX #$08
        D0 F5        BNE loop
        AD 16 40     LDA $4016          ; 第 9 次读，期望 1
        8D 18 00     STA $0018           （端口 2 存 $0019）
        <trampoline: JMP over1 / JMP $8800>
        AD 20 00     LDA $0020+k        ; 逐位比较
        C9 <bit>     CMP #BUTTONS1[k]
        D0 <back>    BNE trampoline     ; 9 条，全部**向后**跳到 trampoline
over1:  ...
```

几个 testbench 自己踩过、值得记下来的点：

- **`LDA $4016` 对 `$40xx` 窗口只产生一次完成传输。** `nes_cpu6502` 的 `ST_ABS_LO`/`ST_ABS_HI` 是**用 `bus_addr = pc_reg` 从程序计数器取操作数字节**的，不走 `addr_reg`。所以 `LDA $4016` 的高字节取数在 PRG 里而不是在 `$4017`——否则一次 `LDA $4016` 会顺带把 port 2 也移一位，整个设计从第一拍就是错的。
- **失败跳转必须用"组内 trampoline + 向后 `BNE`"，不能用 `BNE` 直接跳 `$8800`。** 8 位有符号位移从 `$80xx` 到 `$8800` 差约 2 KB，装不下。本 testbench 的做法是：每组比较**之前**放一段 `JMP overN`（跳过失败块）+ `JMP $88xx`，组里的 9 条 `BNE` 全部**向后**跳到那个 `JMP $88xx`，正常路径由 `JMP overN` 跳过失败块。这三条（跳过块必须在组前、`BNE` 目标必须跳过"跳过块"本身而落在 `JMP $88xx` 上、组内最后一条 `BNE` 的位移不能是 0）任何一条写错，症状都是"程序跳进失败循环"或"在比较组里死循环"而不是清晰的比较失败。
- **`$4017` 要写，而且必须真的进 APU。** 程序在两个口的 8 次读都验完之后执行 `LDA #$00 / STA $4017`（bit7=0 -> 4 步；bit6=0 -> 不禁止 frame IRQ），TB 断言 `apu_wr_frame == 1`，并且层次统计 APU 实例内部的 `dut.u_apu.reg_wr_frame` 被拉高的 clk 恰好 1 次。`apu_reg_cs` 的泄漏判据因此是"`$16` 任意方向，或 `$17` 且 `apu_reg_we` 为 0"才算泄漏——`$17` 的写必须让 `apu_reg_cs` 为高且 `apu_reg_we` 为高。
- **期望的 `oam_addr_reg` 终值是 `$01` 而不是 `$00`。** 一次 DMA 256 次 `$2004` 写把游标从 `$00` 绕回 `$00`，紧接着程序自己 `LDA $2004` 读一次 → `$01`。v3 之所以是 `$00` 是因为它最后一次 DMA 之后没有再读 `$2004`。
- **`$0020-$002F` 的写入分类**用两条互不重叠的区间（`$0020-$0027` 记 port 1、`$0028-$002F` 记 port 2），加上 `$0200-$02FF` 记 DMA 源镜像拷贝、`$01F0-$01FF` 记栈，其余任何 RAM 写立刻 `$fatal`。

### 期望画面

与 v3 完全相同的一套配置（`PPUCTRL=$80`、`PPUMASK=$1E`、`nametable[1]=1`、`chr[0:7]=$FF` / `[8:15]=$00` / `[16:23]=$00` / `[24:31]=$FF` / `[32:39]=$FF` / `[40:47]=$00`、`palette[00..02]=$0F/$21/$32`、`palette[11]=$16`、OAM 由 DMA 从 `$02` 页搬入），因此被检查帧的像素账也是同一组：61440 个可见像素，其中 64 个索引 2、64 个索引 6、61312 个索引 1。**DMA 源表 `[4..255]` 这次固定填 `$FF`**（v3 用生成器填），因此只有 1 个精灵在屏，不存在"多个随机 Y 的精灵是否溢出"的额外变量。

断言按 `frame_done` 计：第 1 次 `frame_done` 之后打开检查、到第 2 次之后关闭，被检查的正好是一整帧。`pixel_valid`、坐标、vblank 窗口等式、`nmi_o` 电平和 `frame_done` 位置在**每一个** `clk` 沿上检查。因为程序从不读 `$2002`（`ppu_rd == 1` 且那一次是 `$2004`），vblank 窗口等式可以断言到逐 clk。

### 断言覆盖

1. **复位**：`ppu_dot`/`ppu_scanline` 为 `0:0`，`frame_done`/`vblank`/`nmi_o`/`apu_irq_o`/`audio_sample_valid` 全低，`bus_active` 低、`bus_req`/`bus_fire`/`bus_hold` 低，`oam_dma_busy`/`apu_dmc_bus_req` 低，CPU 处于 `ST_RESET_0`，`PPUMASK = $00`，**`latch_strobe_q = 0` 且两个读计数器都是 0**，APU `dbg_frame_count` 为 0。
2. **CPU reset 序列**：`dbg_state` 为 5 时 `bus_addr == $FFFC`、为 6 时 `$FFFD`；进入 7 时 `dbg_pc == $8000`；该窗口之后第一次总线事务的 `dbg_opcode == $58`；全程 `dbg_illegal` 为 0。
3. **strobe 电平不变量**（逐 clk）：`latch_strobe_q` 必须**恒等于**"最近一次完成的 `$4016` 写的 bit0"。任何其他来源改动它都会让 `strobe_err` 非零。
4. **每口一个读计数器**（逐 clk）：`dbg_cnt1`/`dbg_cnt2` 必须恒等于"各自已完成的读次数（饱和于 9）"。**唯一的例外是 `$4016` 写完成后的那一拍**——`latch_strobe_q` 在该沿更新，而 `nes_controller` 要到下一个沿才装载，因此 `pending_reload` 那一拍跳过比较。这是被测设计的**真实一拍延迟**（`docs/modules/system-v4.md` 第 2.1 节），不是被放过的缺陷。
5. **`/PL` 的一拍延迟与共享语义**：在第二次 `$4016` 写（port 2 测试开始）的前后各取一次快照，断言 `cnt=9 sr=$FF latch=$A5` 变成 `cnt=0 sr=$A5 latch=$A5`。
6. **每一次完成的控制器读**：逐位比较 `bus_din[0]` 与期望序列（`$A5` 的 8 位、1、`$5A` 的 8 位、1，共 18 次），断言 `bus_din[7:1] == 0`，并断言 `bus_din[0] === controller_data`（数据输出真的在驱动读 mux）。
7. **`apu_reg_cs` 不泄漏**：每一次完成的 `$4016` 传输、以及每一次 `$4017` 的**读**上 `apu_reg_cs` 必须为 0（`ctrl_cs_err`）；任何时刻 `apu_reg_cs` 为高时 `apu_reg_addr` 不得是 `$16`、也不得是 `$17` 的读（逐 clk `$fatal`）。反向地，`$4017` 的**写**必须让 `apu_reg_cs` 与 `apu_reg_we` 同时为高（`apu_wr_frame == 1`，且 `dut.u_apu.reg_wr_frame` 恰好为高 1 拍）。`apu_reg_cs` 仍必须蕴含 `bus_fire` 与 `sel_apu_io`、不得连续两拍为高、`apu_reg_addr` 不得超过 `$17`。
8. **端口计数**：`$4016` 写恰好 4 次、读 `$4016` 与 `$4017` 各恰好 9 次；两个读计数器的峰值都是 9；仿真结束时 `dbg_cnt2 = 9`（最后读的是 port 2）、`dbg_cnt1 = 0`（被共享 strobe 清掉）、`dbg_latch1 = $A5`、`dbg_latch2 = $5A`、`dbg_sr2 = $FF`、`dbg_sr1 = $A5`（被第二次 strobe 重新装载）。
9. **RAM 里的结果**：`$0020-$0027` 逐格等于 `BUTTONS1[k]`、`$0028-$002F` 逐格等于 `BUTTONS2[k]`、`$0018` 与 `$0019` 都是 `$01`；这 18 个单元各被写恰好一次，`$0018`/`$0019` 各被写 2 次（清零 + 存第 9 次读）。这些断言**同时**被程序自己的 `CMP`/`BNE` 覆盖（跳 `$8800`/`$8810`），两条独立路径。
10. **等待路径**：每个 `ce_cpu` 拍上统计本次事务的停顿次数，非 open bus 的 owner 必须恰好 1 拍；`bus_stall === (bus_req && !bus_fire)`；完成拍上 `bus_wait_count` 必须为 0、`bus_active` 必须为 1。本程序一次 open bus 读都没有，所以 `immediate_count == open_rd == 0`，即**全部 29525 次传输都恰好停顿 1 拍，控制器读也不例外**。
11. **`ce` 门控**：每个 `div_phase == 1` 的沿采样一次 `bus_active` 与 `bus_wait_count`；其余任何 `clk` 沿上这两个寄存器变化就立刻 `$fatal`。
12. **总线周期全覆盖账**：`prg_rd + ram_rd + ram_wr + ppu_rd + ppu_wr + apu_rd + apu_wr + open_rd + cartram_rd + prg_wr` 必须精确等于总完成次数；`apu_rd` 与 `apu_wr` 各自再分解一次（读 = `$4015` 数 + `$4016` 数 + `$4017` 数；写 = 4（`$4000-$4003`）+ `$4016` 数 4 + `$4017` 数 1 + `$4015` 数 + `$4014` 数 1）。落进 PRG 的写必须为 0。
13. **PRG 读路径**：每次 PRG 读都断言 `cart_din === dut.prg_rom[bus_addr[13:0]]`（NROM-128 折叠）。
14. **RAM 写白名单**：非 `$0010/$0011/$0013/$0014/$0018/$0019`、非 `$0020-$002F`、非 `$0200-$02FF`、非 `$01F0-$01FF` 的任何 RAM 写立刻 `$fatal`。
15. **DMA 仲裁点**：`bus_hold === (oam_dma_cpu_hold || apu_dmc_bus_req)` 与 `oam_dma_cpu_hold === oam_dma_busy` 逐 clk 相等；`bus_hold` 期间 `bus_fire`/`bus_req`/`ppu_reg_cs`/`apu_reg_cs` 全为 0；`dma_wait === (req && !ack)`；`dma_active` 一旦拉高必须保持到 `dma_ack`；`dma_sel`/`apu_dmc_bus_req`/`oam_dma_addr_wr`/`dma_unimpl` 全程为 0；源页锁存与引擎锁存逐 clk 相等（v3 的那条同沿竞争在这里仍然是即时 `$fatal`）。
16. **CPU 冻结**：每次 DMA 的 `bus_hold` 窗口内 `dbg_state` 与 `dbg_pc` 逐 clk 不得变化。
17. **DMA 协议**：256 次 `dma_ack`、256 次 `$2004` 写，每次 ack 的地址必须是 `{8'h02, 下标}` 且数据等于 `ram_array` 对应格，每次 `$2004` 写的数据必须等于上一次被 ack 的读数据；ack 不得连续两拍、不得与 `bus_fire` 同拍、必须带 `bus_hold`；`dma_owner == 0`。
18. **OAM 内容**：256 字节逐字节等于源表；`$0200-$02FF` 仍然是那份源表（证明"CPU 拷进 RAM 的"与"DMA 从 RAM 搬进 OAM 的"是同一份）；两个标记单元分别是 `$01`。
19. **PPU 寄存器桥**：写按 `reg_addr` 精确分解——`$2000` 2 次、`$2001` 2 次、`$2003` 1 次、`$2006` 18 次、`$2007` 45 次、`$2004` 与 `$2002` 各 0 次；读恰好 1 次且是 `$2004`；IRQ 服务例程里出现任何 PPU 寄存器传输即失败。
20. **APU 寄存器桥**：写 `$4000-$4003` 各 1 次、`$4015` 为 `1 + IRQ 次数`、**`$4017` 为 1**（必须真的进帧计数器）、`$4014` 为 1；读只有 `$4015`，次数等于 IRQ 次数；`$4015` 写次数 == 读次数（每次读都被 ack）。
21. **NMI 链路**：逐 clk 断言 `nmi_o === vblank && PPUCTRL[7]`；每个 `nmi_o` 上升沿必须落在 `(241,1)`；NMI 上升沿数、`$FFFA` 向量取指数、`$0010` 的写入次数（除主程序那一次清零）与 `ram_array[$010]` 终值四者必须互相相等。
22. **IRQ 链路**：逐 clk 断言 `apu_irq_o === (dbg_frame_irq | dbg_dmc_irq)` 且 `dbg_irq_pending === apu_irq_o`；`dbg_dmc_irq` 抬起来即失败；`dbg_frame_count` 全程不得超过 29829（证明程序写 `$4017 = $00` 之后帧计数器确实被留在 4 步模式）；上升沿数 == 下降沿数 == `$FFFE` 向量取指数 == `$4015` ack 次数；仿真结束时 `apu_irq_o == 0`、`dbg_nmi_pending == 0`。
23. **音频**：`audio_sample_valid` 只在 `div_phase == 1` 为高且不得缺失，脉冲总数等于 `ce` 脉冲总数（59562）；每个脉冲 `left == right`；`dbg_tnd_sum` 全程为 0；非零样本数 > 0，峰值 4895；`dbg_pulse1_length` 终值精确 160、`dbg_pulse1_mute` 为 0。
24. **CPU 状态与 PC 范围**：无非法指令；PC 永远在四段已编程代码（主程序 / NMI 例程 / IRQ 例程）加三个失败死循环之内，落在任何空隙都是失败；**落进 `$8800`/`$8810`/`$8820` 分别是三类失败**（1P 读错 / 2P 读错 / `$2004` 回读错），失败消息带最近 4 笔完成传输的地址与数据；handler 内 `I` 标志必须为 1、`sp` 不得超过 `$FA`；主程序里取指时 `I` 必须为 0、`sp` 必须为 `$FD`。
25. **帧与像素**：`frame_done` 恰好 2 次且都落在 `(0,0)`；相邻间隔恰好 `262 × 341 × 4 = 357368` 个 `clk`；vblank 窗口等式逐 clk 成立，上升/下降沿各 2 次；被检查帧的 `pixel_valid` 采样点上坐标必须等于 `ppu_dot`/`ppu_scanline`，`pixel_index` 必须等于期望值，整帧计数必须是 61440 / 61312 / 64 / 64。
26. **全局超时**：`#40000000`（40 ms，约 11 帧）兜底；2 帧需要约 7.147 ms。

### 运行

```powershell
$tmp = Join-Path $env:TEMP 'op_fpga_emu'
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
$v4 = @(
  'rtl\nes_core\system\nes_system_v4.v',
  'rtl\nes_core\controller\nes_controller.v',
  'rtl\nes_core\bus\nes_cpu_bus.v',
  'rtl\nes_core\ppu\nes_ppu2c02.v',
  'rtl\nes_core\ppu\nes_ppu_sprite.v',
  'rtl\nes_core\ppu\nes_oam_dma.v',
  'rtl\nes_core\cpu\nes_cpu6502.v',
  'rtl\nes_core\apu\nes_apu_pulse.v',
  'rtl\nes_core\apu\nes_apu_triangle.v',
  'rtl\nes_core\apu\nes_apu_noise.v',
  'rtl\nes_core\apu\nes_apu_dmc.v',
  'rtl\nes_core\apu\nes_apu_length_lut.v',
  'rtl\nes_core\apu\nes_apu2a03.v'
)
& 'C:\iverilog\bin\iverilog.exe' -g2001 -s nes_system_v4 -o (Join-Path $tmp 'nes_system_v4_core.vvp') $v4
& 'C:\iverilog\bin\iverilog.exe' -g2012 -s tb_nes_system_v4 -o (Join-Path $tmp 'tb_nes_system_v4.vvp') ($v4 + 'tb\system\tb_nes_system_v4.v')
& 'C:\iverilog\bin\vvp.exe' (Join-Path $tmp 'tb_nes_system_v4.vvp')
```

第一条是纯顶层 elaboration（`-g2001`，只编译 RTL），确认 `nes_system_v4` 本身不依赖 testbench 特性。源文件列表必须显式包含 `nes_controller.v`、`nes_cpu_bus.v`、`nes_ppu_sprite.v`、`nes_oam_dma.v` 与全部五个 APU 通道/查找表文件，`iverilog` 不会自动去找。`tools/sim_all.ps1` 没有登记 v4 的 system 目标，本次没有改动它（本次只改了 RTL、`tb/system` 的 testbench 与文档），上面三条命令是直接调用。没有对应的 ModelSim `.do` 脚本。

`nes_system_v4.v` 与 `nes_controller.v` 本身**零 warning**（上面那条命令不带 `-Wall`，输出为空）。加 `-Wall` 时会出现 8 条 `@* is sensitive to all N words in array ...` 警告，全部来自 `nes_ppu_sprite.v` 与 `nes_ppu2c02.v` 里的存储数组，与 v3 用同一条命令得到的 8 条**逐条相同**，不是 v4 引入的。

实测输出（Icarus Verilog 12.0，Windows，10 ns 时钟）：

```text
RESET ppu=0:0, frame/vblank/nmi/irq/sample low, bus idle, dma idle, controller strobe low and both read counters clear PASS
CPU reset FFFC/FFFD -> PC=8000 first opcode=58, illegal opcodes=0 PASS
CONTROLLER $4016 written 1 then 0 four times, 8 reads of $4016 rebuilt a5 in ram 0020-0027 and 8 reads of $4017 rebuilt 5a in ram 0028-002f, the 9th read of each port returned 1, both latches hold the live bitmaps and both shift registers ended at ff PASS
CONTROLLERBUS every completed $4016 transfer and every $4017 read bypassed apu_reg_cs, the $4017 write still drove apu_reg_cs with reg_we high, every read put exactly one serial bit on the cpu read data bus, the /PL level tracked the last write bit0 on every clk, and each port advanced its own shift register exactly once per completed read PASS
CONTROLLERPL the shared /PL took effect on the clock after the completed $4016 write: port 1 went cnt=9 sr=ff latch=a5 -> cnt=0 sr=a5 latch=a5, so the second port starts from a fresh snapshot of its own bitmap PASS
WAIT every ram/ppu/apu/cart transfer took exactly one ce of stall, dbg_wait_count stayed 0, the controller reads took the same wait path PASS
WAIT cpu transfers=29525 stalled=29525 immediate=0 PASS
BUS owner accounting prg_rd=28821 ram_rd=310 ram_wr=294 ppu_rd=1 ppu_wr=68 apu_rd=19 apu_wr=12 open_rd=0 cartram_rd=0 prg_wr=0 PASS
DMABUS bus_hold = oam_dma_cpu_hold || apu_dmc_bus_req, the controller reads sit outside every dma window, no cpu transfer and no register access during the hold, cpu state and pc frozen for the whole transfer PASS
OAMDMA one transfer base=00 page=02 put table1 into oam[0..255] in order, the program read $2004 back and saw 20, and the ram source page still holds the copy PASS
PPUREG writes ctrl=2 mask=2 vaddr=18 vdata=45 oamaddr=1 oamdata=0 status=0 other=0, reads oamdata=1, no ppu access inside the irq handler PASS
APUREG writes $4000-$4003=1 each, $4015=2 (1 enable + 1 acks), $4014=1, $4017=1 reached the frame counter inside the apu instance while only the $4017 read belongs to controller2, reads $4015=1 PASS
PPUSTATE ctrl=80 mask=1E v=0000 t=0000 w=0 oamaddr=01, chr[0:7]=ff [8:15]=00 [16:23]=00 [24:31]=ff [32:39]=ff [40:47]=00, nt[1]=01, pal=0f,21,32 and 11=16 PASS
PRG main $8000-$81e8 (489 bytes), nmi handler $8400-$8409, irq handler $8500-$850f, fail loops $8800/$8810/$8820, table $8900, vectors fffa=$8400 fffc=$8000 fffe=$8500
IRQ nmi rises=2 entries=2 ram[0010]=02, apu irq rises=1 falls=1 entries=1 ram[0011]=01 PASS
AUDIO ce pulses=59562 sample strobes=59562 nonzero=29568 peak=4895, pulse1 length=160 not muted, dmc stayed idle PASS
FRAME frame_done=2 period=357368clk vblank rises=2 falls=2, checked frame pixels=61440 index1=61312 index2=64 sprite6=64 PASS
PASS nes_system_v4
```

仿真时间 7.147 ms（2 帧），本机 vvp 实测约 52 s。任何 `$fatal` 命中会让 vvp 以非零退出码结束并打印失败条件、时间点与相关寄存器值。

### 变异验证

为确认断言不是空跑，对 `nes_system_v4.v` 的副本（**仓库里的 RTL 未被修改**）做了 7 处定向变异：

| 变异 | 结果 |
| --- | --- |
| `cpu_din` 的控制器 mux 换成常量（`assign cpu_din = bus_cpu_din;`） | `the controller data output does not drive the read mux, din=00 out=1` |
| `apu_port_cs` 完全不 gate（`assign apu_port_cs = apu_xfer;`） | `apu_reg_cs leaked onto the controller address 4016`（第一次 `$4016` 传输就 `$fatal`，Time 12165000） |
| **override 退回"整段 `$4016/$4017` 读写全 gate"**（`apu_addr_ctrl_owned = apu_addr_ctrl1 \|\| apu_addr_ctrl2`，即本次修掉的那处回归） | `the port 2 read counter disagreed with the completed reads 702777 times`。`$4017` 写周期上 `cpu_din` 被换成串行位，紧接着的取指读到垃圾操作码，程序跑飞；`apu_wr_frame` / `apu_frame_pulse` 也会在结算期报 `$4017` 写次数为 0 |
| `ctrl_read_select` 两个口接反 | `the port 1 controller read failed`，程序跳进 `$8800` |
| 读选通改成请求级（`apu_req` 而不是 `apu_xfer`） | `the port 1 controller read failed`，程序跳进 `$8800`（一次读移两位） |
| `latch_strobe_q` 改成边沿触发（加 `&& !latch_strobe_q`） | `the port 1 controller read failed`，程序跳进 `$8800`（`/PL` 永远拉不起来） |
| 只把 `u_apu` 的 `reg_cs` 换回 `apu_xfer`（端口仍 gate） | **等价变异**：本程序读 `$4016/$4017` 在 APU 内部没有副作用（`reg_wr_frame` / `reg_rd_status` 只匹配 `$17` 写 / `$15` 读），写 `$4016` 也不匹配任何一个 `reg_wr_*`，所以"端口说没有访问而 APU 内部照旧处理"这半边差异在本程序里不可观测。**它是一条真实的隐患**，现在由 `apu_frame_pulse == 1`（层次观察 `dut.u_apu.reg_wr_frame`）盯着：一旦 APU 实例的 `reg_cs` 与 `apu_reg_cs` 脱钩，这条判据立刻失败 |

6 处被 testbench 抓到，1 处是等价变异。三个"程序跳进失败循环"的变异都同时被**程序自证的 `CMP`/`BNE`** 和 TB 的**逐 clk 不变量**（`strobe_err` / `cnt1_err` / 逐位 `ctrl_data_err`）覆盖，两条路径的失败时间点不同，可以据此区分是哪一层先发现的。

### v4 testbench 绕过的问题

- **`$2002` 轮询会截断 vblank 窗口**：本 testbench 的程序从不读 `$2002`（`ppu_rd == 1` 且是 `$2004`），所以 vblank 窗口等式断言到**每一个** `clk` 沿。轮询式程序做不到这一点，窗口等式必须退化成"只在窗口内为高 + 上升沿只在 `(241,1)`"。
- **CPU RTL 的零页 `INC` 缺陷**：`decode_mode` 把 `$E6` 误列在 `AM_ZP`（本文档前面已记录）。本程序与服务例程的计数器全部用 `LDA / CLC / ADC #$01 / STA` 实现；读位循环用 `INX / CPX #$08 / BNE`，不用 `INC`。
- **`/PL` 的电平敏感性在系统级不可区分**：按任务要求，TB 顶层给的是**固定** `buttons1`/`buttons2`，因此"电平装载 vs 边沿装载"在系统级是等价变异（两次快照时刻的 `buttons` 相同）。第 5 条断言仍然把"`/PL` 生效比写完成晚一个 clk"钉死（靠的是计数器与移位寄存器的状态变化，不是靠 `buttons` 变化）。真正的电平敏感性由 `tb/controller/tb_nes_controller.v` 的 `test_strobe_reload` 覆盖。
- **栈的逐地址计数没有被断言**：`stk_rd` / `stk_wr` 对 `$01F0-$01FF` 记账了，但除了"非白名单 RAM 写立刻 `$fatal`"之外没有对总量做断言（v3 也是这样，v2 有更细的栈断言）。v4 的栈覆盖因此弱于 v2。
- **变址寻址的边界没有单独覆盖**：`STA $0020,X` / `LDA $8900,X` 的 X 只在 0..7 与 0..255 两段使用，没有覆盖跨页（`$02FF` 之后进 `$0300`）的情况。跨页由 `$0200-$02FF` 白名单间接兜住（越界就 `$fatal`）。
- **DMC DMA 完全没被激励**，与 v3 同。

### v4 明确未实现

以下是**被测顶层 `nes_system_v4`** 的范围限制，不是 testbench 的缺陷；完整清单与理由见 `docs/modules/system-v4.md` 第 5 节：

- **读 `$4017` 出来的只有手柄那一位**：`nes_apu2a03` 的 `reg_dout` 在 `reg_addr == 5'h17` 的读上给 `$00`（`3'd5` 分支只对 `5'h15` 组装状态），而 v4 把 `$4017` 的读整个交给 controller2，所以 CPU 从 `$4017` 读到的就是 `{7'b0, controller_data}`。真机上 `$4017` 读的 bit0 是 open-bus 里的手柄位、bit6/bit7 来自帧计数器状态位；**帧计数器状态位没有被建模**，这与 open bus 那一条是同一个缺口（open bus 的建模属于总线层，本次没改 `nes_cpu_bus`）。
- **open bus 上没有手柄那一位**：`nes_cpu_bus` 的 `open_bus_q` 在控制器读之后拿到的是 APU 的 `$00` 而不是串行位，所以 `$4018-$5FFF` 读 `$00`（本程序一次都不读）。
- **`$4016` 的 bit6/bit7 扩展口**（Zapper、四玩家）没有建模，读回值只有 bit0 有效。
- **第 9 次及以后的读**按 `EXTRA_READ = 2'd0` 返回恒 1（两个口都验过）；v4 没有把 `EXTRA_READ` 提成顶层参数。
- **手柄的物理层**（消抖、鬼键、CDC、无手柄检测）不在本顶层内，见"4 个板载按键"那一节：缺的是"谁来产生这 8 个稳定 bit"，属于 `rtl/platform/ep4ce10/` 的范围，`nes_system_v4` 与 `nes_controller` 都不需要改。
- **DMC DMA 通路存在但从未被激励**、**`OAMADDR_WRITE = 0`**、**mapper**、**`$6000-$7FFF` 无 PRG RAM**、**sprite 0 hit / overflow 未覆盖**、**音频输出通路**、**上板频率与跨时钟域**——全部与 v3 相同，v4 没有改动其中任何一条。

## v5 testbench（`nes_system_v5`）

`tb_nes_system_v5.v` 例化**三个** `nes_system_v5`（共用一个 `clk`），是本目录第一个同时覆盖多个 mapper 的集成 testbench。前面的小节里那句"本目录有五个 testbench"和开头的表格停留在 v3，v4 与 v5 各自成节（与 v4 的做法一致），本节只补 v5。

顶层接口合同、mapper 接线、软件 mapper dispatch/指针数组到 bank 寄存器与地址 mux 的对应关系、以及"v5 只完成 PRG/mirroring/mapper IRQ 接线、外部 CHR bank 留给下一阶段"的完整说明，见 [`docs/modules/system-v5.md`](../../docs/modules/system-v5.md)。本节只写 testbench 本身。

### 三个实例

| 实例 | `MAPPER_SELECT` | 关键参数 | PRG 签名 | 程序入口 | 覆盖 |
| --- | --- | --- | --- | --- | --- |
| `nrom_dut` | 0（NROM） | `NROM_PRG_SIZE_BYTES=32768`、`HEADER_MIRRORING=3'd1`（vertical） | `0x40 + (off>>14)`：下窗口 `40`、上窗口 `41` | `$8000` | NROM bank 映射：`$8040`/`$BFFF` → `40`，`$C000`/`$FFF0` → `41` |
| `uxrom_dut` | 2（UxROM） | `UxROM_BANK_BITS=3`、`UxROM_BUS_CONFLICT=2'd1` | bank0 = `FF`，bank1..7 = `0x40+bank` | `$C000`（固定最后一个 bank） | bank 寄存器 + bus conflict + header mirroring + controller + OAM DMA + APU + 可等待总线 |
| `mmc3_dut` | 4（MMC3） | `HEADER_MIRRORING=3'd0` | `0x50 + (off>>13)`：16 个 8 KiB bank | `$E000`（固定最后一个 8 KiB bank） | R6/R7 切换 + prg mode + `$A000` mirroring + IRQ 寄存器 + IRQ 进 CPU |

三个程序都不依赖任何外部 ROM 文件：PRG 由 TB 用签名填满，程序、失败 trampoline 与向量由 TB 用 `emit` 系列任务写进对应实例的 `prg_rom`。唯一的层次预填是 UxROM 实例的 4 个字节（`ram[0200..0203] = 11 22 33 44`，OAM DMA 的源页），以及三个实例各自的 RAM 完成标志位。

TB 自带**独立于 DUT 的 bank 模型**（`nrom_exp_off` / `uxrom_exp_off` / `mmc3_exp_off`）：UxROM 的模型自己按 conflict 模式 1 算 `cpu_dout & prg_rom[本次写地址]`，MMC3 的模型自己按 `$8000`/`$8001` 跟踪 `bank_select`/`R6`/`R7`/`prg_mode`。因此断言不构成自证。

### 程序布局与 ±127 分支约束

6502 的相对分支位移是带符号 8 bit，可达范围只有 `-128..+127`。TB 的 `bne_to` / `bne_flush` 在算出位移后立刻 `check_disp`，越界直接 `$fatal("branch displacement %0d at %04h does not fit in a signed byte")`。因此失败块不能直接放在程序末尾：每个程序被切成若干"块"，每块结尾是

```text
        JMP <下一块>          ; 3 字节，绝对跳转不受 ±127 限制
fail:   JMP <远端失败块>      ; 3 字节，块内所有 BNE 都跳到这里
```

本次开发真实踩过一次：最初 `bne_to` 直接写 `target - (here+2)`，`$8014 → $8200` 算出 `0x01EA`，截成 8 bit 后是 `0xEA`，而 `0xEA` 作为带符号字节是 **-22**，分支落回 `$8000`，程序在开头死循环。CPU RTL 的 `add_signed_offset` 是正确的（`{{8{offset[7]}}, offset}`），错的是 TB 的位移计算——现在越界会当场 `$fatal`。

### 断言覆盖要点

1. **复位**：三个 CPU 处于 `ST_RESET_0`，`mapper_irq`/`irq_line`/`apu_irq_o`/`mapper_write_pulse` 全低；`mapper_id` 分别是 0/2/4；NROM 的 header mirroring 是 vertical 且 `nametable_map == 8'b01000100`；MMC3 复位 bank map 是 `R6=0 R7=1` 且 `irq_enabled=0`。
2. **PRG 读路径**：每一次 cart 读都比对三件事——`mapper_prg_bank_offset` 等于 TB 模型、`cart_din` 等于 `prg_rom[模型]`、CPU 读到的 `bus_din` 等于 `prg_rom[模型]`。三个实例合计 1775 次读、17 次写全部匹配。
3. **`prg_readback`**：每个 `clk` 断言等于 `prg_rom[mapper_prg_bank_offset]`，即它跟随当前 bank 而不是固定值。
4. **mapper 写脉冲**：脉冲数 == 完成的 cart 写数；每个脉冲宽度恰好 1 个 `clk`（相邻两拍都高即失败）；脉冲拍的 `mapper_write_addr`/`mapper_write_data` 等于那次写自己的地址/数据。
5. **可等待总线**：每个 `ce` 断言 `bus_stall == bus_req && !bus_fire`；每次完成传输的 stall 拍数恰好是 1（open bus 窗口是 0）；`dbg_wait_count` 在完成沿恒 0。
6. **IRQ 线或**：每个 `clk` 断言 `irq_line == (mapper_irq | apu_irq)` 且 `u_cpu.dbg_irq_pending == irq_line`。三个程序都写 `$4017 = $40`（5 步 + 禁止 frame IRQ），所以 `apu_irq_o` 全程为 0——这让"线或里的 mapper 那一项"是可以被单独观察的。
7. **MMC3 IRQ 寄存器**：`$C000` 写 7 → `mmc3_irq_latch == 7`；`$C001` 之后 `mmc3_irq_reload` **保持 1** 且 `mmc3_irq_counter` 保持 0（因为 `ppu_a12` 在 v5 绑 0，计数器永远不被时钟）；`$E001` 使能、`$E000` 禁止并 ack；`mapper_irq` 全程为 0。
8. **mapper IRQ 进 CPU**：`force` 压住 `u_mapper.u_mmc3.irq_enabled_r`/`irq_pending_r` 为 1，断言 `mapper_irq=1 → irq_line=1 → dbg_irq_pending=1`，CPU 走 7 周期入口、从 `$FFFE` 取向量、跳到 `$E200` 的服务例程、例程把 `ram[0013]` 加 1 后 `RTI`；`irq_entries`（`$FFFE` 的 cart 读次数）≥ 1。恢复时**先 `force` 成 0 再 `release`**（见下）。
9. **UxROM bus conflict**：4 次 `$8000` 写全部让 `bus_conflict` 为高（模式 1 是组合比较，不看模式都报冲突）；两次写 `$00` 与 `prg_readback` 与运算后仍是 bank 0；两次写 `$43`/`$45` 因为读回字节是 `FF` 而干净地锁存 bank 3 / bank 5；程序随后从 `$8000` 读回 `43`、`45`，而固定窗口 `$F000` 始终是 `47`。
10. **MMC3 bank 切换**：复位态 `$8000`→`50`（R6=0）、`$A000`→`51`（R7=1）、`$C000`→`5E`（倒数第二个 8 KiB）、`$F000`→`5F`（最后一个）；写 `R6=5` 后 `$8000`→`55`；写 `R7=3` 后 `$A000`→`53` 且 `$8000` 仍是 `55`；`$8000` 的 bit6 置 1 后 `$8000`→`5E`、`$C000`→`55`（prg mode 交换）。
11. **mirroring**：NROM/UxROM 的 `mapper_mirroring` 等于 header 值；MMC3 的 `$A000` 写入让 horizontal 与 vertical **两种模式都被观测到**，`nametable_map` 随模式在 `8'b01010000`/`8'b01000100` 之间变化。
12. **保留路径回归**（UxROM 实例）：`$4016` 8 次读在 `ram[0020..0027]` 重建 `A5`、`$4017` 8 次读在 `ram[0028..002F]` 重建 `5A`、两个口的第 9 次读都是 `1`、`$4016`/`$4017` 的读从不拉起 `apu_reg_cs`；`$4014` 触发一次、`dma_ack` 256 次、`$2004` 写 256 次、`oam[0..3] == 11 22 33 44`、程序读 `$2004` 看到 `11`；pulse1 开着且 sample 非零、DMC 全程不请求总线。
13. **CPU 卫生**：三个 CPU 全程没有非法指令，PC 从不进入各自的失败块（逐 `clk` 判定），三个完成标志都写进 RAM 后才结算。

### 固定期望输出

```text
RESET three systems idle, mapper ids 0/2/4, nrom header mirroring vertical, mmc3 reset banks r6=0 r7=1 and irq disabled PASS
CPU all three programs ran, the reset vectors reached 8000/c000/e000, no illegal opcodes and no program entered its fail loop PASS
PRG every cart read of all three systems matched the independent tb bank model on cart_din and on the cpu read data, prg_readback followed the same word on every clk, and every completed cart write produced exactly one single clk mapper write pulse carrying that address and data PASS
PRG nrom rd=704 wr=0, uxrom rd=380 wr=4, mmc3 rd=691 wr=13, bus transfers nrom=713 uxrom=457 mmc3=713 PASS
MIRROR the mapper mirroring outputs followed the ines header for nrom and uxrom and the a000 register for mmc3, both horizontal and vertical were observed, and nametable_map tracked the mode PASS
MIRROR the ppu still runs with the compile time MIRROR_VERTICAL=0 because nes_ppu2c02 has no runtime mirroring port, so v5 observes the mode but does not apply it inside the ppu yet PASS
UXROM four 8000 writes under conflict mode 1: the two 00 writes AND against a live prg_readback and hold bank 0, the 43 and 45 writes latch bank 5 because the readback byte is ff, so 8000 reads back 43 then 45 while f000 stays 47 in the fixed last bank PASS
MMC3 8000/8001 selected r6=5 then r7=3 and the 8000 bit6 mode bit swapped the 8000 and a000 windows, every prg read of the program matched the model PASS
MMC3IRQ c000 latched 07, c001 set reload and it stayed set because ppu_a12 is tied low in v5 so the counter never clocked, e001 enabled and e000 disabled and acked, and the mapper irq line stayed low for the whole program PASS
IRQOR apu_irq_o stayed low in all three systems, irq_line always equalled mapper_irq | apu_irq and the cpu dbg_irq_pending followed the same wire, so the or is the only irq mux in v5 PASS
IRQFORCE forcing the mmc3 irq_enabled/irq_pending registers drove mapper_irq=1 -> irq_line=1 -> cpu dbg_irq_pending=1, the cpu took the 7 cycle entry, fetched fffe, and the line fell again after release PASS
MMC3IRQENTRY the irq vector came from the fixed last bank window, the handler at e200 incremented ram[0013] to 01 and returned with rti PASS
CONTROLLER the uxrom system rebuilt a5 in ram 0020-0027 from eight 4016 reads and 5a in ram 0028-002f from eight 4017 reads, both 9th reads returned 1, and no 4016/4017 read ever asserted apu_reg_cs PASS
OAMDMA the uxrom 4014 write transferred 256 bytes from page 02 into oam[0..255], the program read 2004 back and saw 11, and the ack/write accounting closed at 256 each PASS
AUDIO the uxrom system kept pulse1 running with 1510 sample strobes and 278 non zero samples, dmc never requested the bus, and the frame irq stayed inhibited by 4017=40 PASS
WAIT every cart, ram, ppu and apu transfer in all three systems still took exactly one ce of stall, bus_stall followed bus_req && !bus_fire on every cpu enable and dbg_wait_count stayed 0, so the waitable bus from v4 is preserved PASS
PASS nes_system_v5
```

仿真时间 181.236 µs（远短于 v4 的 7.147 ms，因为本 testbench 不检查像素、程序只跑一遍），但**墙钟时间反而比 v4 长**：三个完整系统同时跑，而且每个 `clk` 都要做三次 128 KiB 的 `prg_rom` 读（`prg_readback` 判据）。本机 vvp 实测约 59 s（v4 约 51 s）。

### 运行

```powershell
$tmp = Join-Path $env:TEMP 'op_fpga_emu'
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
$v5 = @(
  'rtl\nes_core\system\nes_system_v5.v',
  'rtl\nes_core\controller\nes_controller.v',
  'rtl\nes_core\bus\nes_cpu_bus.v',
  'rtl\nes_core\ppu\nes_ppu2c02.v',
  'rtl\nes_core\ppu\nes_ppu_sprite.v',
  'rtl\nes_core\ppu\nes_oam_dma.v',
  'rtl\nes_core\cpu\nes_cpu6502.v',
  'rtl\nes_core\apu\nes_apu_pulse.v',
  'rtl\nes_core\apu\nes_apu_triangle.v',
  'rtl\nes_core\apu\nes_apu_noise.v',
  'rtl\nes_core\apu\nes_apu_dmc.v',
  'rtl\nes_core\apu\nes_apu_length_lut.v',
  'rtl\nes_core\apu\nes_apu2a03.v',
  'rtl\nes_core\mapper\nes_mapper.v',
  'rtl\nes_core\mapper\nes_mapper_nrom.v',
  'rtl\nes_core\mapper\nes_mapper_uxrom.v',
  'rtl\nes_core\mapper\nes_mapper_cnrom.v',
  'rtl\nes_core\mapper\nes_mapper_mmc1.v',
  'rtl\nes_core\mapper\nes_mapper_mmc3.v'
)
& 'C:\iverilog\bin\iverilog.exe' -g2001 -s nes_system_v5 -o (Join-Path $tmp 'nes_system_v5_core.vvp') $v5
& 'C:\iverilog\bin\iverilog.exe' -g2012 -s tb_nes_system_v5 -o (Join-Path $tmp 'tb_nes_system_v5.vvp') ($v5 + 'tb\system\tb_nes_system_v5.v')
& 'C:\iverilog\bin\vvp.exe' (Join-Path $tmp 'tb_nes_system_v5.vvp')
```

第一条是纯顶层 elaboration（`-g2001`，只编译 RTL），确认 `nes_system_v5` 不依赖 testbench 特性。源文件列表必须显式包含六个 mapper 文件与全部 APU 通道/查找表文件。`tools/sim_all.ps1` 没有登记 v5 的 system 目标（本次没有改动它）。没有对应的 ModelSim `.do` 脚本。

**v4 回归**（本次同时跑，确认 v5 没有动到 v4 用的任何文件）：

```powershell
$v4 = @(
  'rtl\nes_core\system\nes_system_v4.v',
  'rtl\nes_core\controller\nes_controller.v',
  'rtl\nes_core\bus\nes_cpu_bus.v',
  'rtl\nes_core\ppu\nes_ppu2c02.v',
  'rtl\nes_core\ppu\nes_ppu_sprite.v',
  'rtl\nes_core\ppu\nes_oam_dma.v',
  'rtl\nes_core\cpu\nes_cpu6502.v',
  'rtl\nes_core\apu\nes_apu_pulse.v',
  'rtl\nes_core\apu\nes_apu_triangle.v',
  'rtl\nes_core\apu\nes_apu_noise.v',
  'rtl\nes_core\apu\nes_apu_dmc.v',
  'rtl\nes_core\apu\nes_apu_length_lut.v',
  'rtl\nes_core\apu\nes_apu2a03.v'
)
& 'C:\iverilog\bin\iverilog.exe' -g2012 -s tb_nes_system_v4 -o (Join-Path $tmp 'tb_nes_system_v4.vvp') ($v4 + 'tb\system\tb_nes_system_v4.v')
& 'C:\iverilog\bin\vvp.exe' (Join-Path $tmp 'tb_nes_system_v4.vvp')
```

实测 `PASS nes_system_v4`（输出与本文档 v4 一节记录的完全一致，7.147 ms / 约 51 s）。

### 变异验证

对 `nes_system_v5.v` 的**副本**（仓库里的 RTL 未被修改）做三处定向变异：

| 变异 | 结果 |
| --- | --- |
| `prg_index = mapper_prg_bank_offset` → `prg_index = {1'b0, cart_addr[15:0]}`（忽略 bank） | `global timeout`——三个 CPU 连 reset vector 都读错（向量落在数组高半区），程序永远到不了完成标志 |
| `mapper_we = cart_wr_pending_q` → `mapper_we = cart_we`（请求级而不是完成沿） | `uxrom prg offset disagreed with the tb bank model 3 times`——请求级的 `cpu_we` 在等待拍就先改了一次 bank |
| `irq_line = mapper_irq \| apu_irq` → `irq_line = apu_irq`（去掉线或） | `the mapper irq did not reach the combined irq line` |

三处全部被抓。第一处是靠全局超时抓到的，诊断信息不如后两处具体。

### v5 testbench 绕过的问题

- **`release` 不会恢复寄存器的驱动值。** `force` 一个由 `always` 块驱动的寄存器再 `release`，寄存器保持强制期间的值，要等下一次驱动才变。因此恢复 MMC3 IRQ 状态时 TB 先 `force` 成 0 再 `release`；否则 `mapper_irq` 会永远停在 1（本次开发真实遇到的现象，报 `the mapper irq is still high after the force was released`）。
- **`force` 压 mapper 内部寄存器是本 testbench 唯一的"造 IRQ"手段。** 因为 v5 把 `ppu_a12` 绑 0，五个 mapper 里没有任何一个能自己把 `irq` 拉起来（NROM/UxROM/CNROM/MMC1 的 `irq` 恒 0，MMC3 只在 `a12_filtered` 时置 pending）。所以"mapper IRQ 到 CPU 的完整链路"在系统级只能靠 `force` 触发；**A12 沿触发 IRQ 本身**由 `tb/mapper/tb_nes_mapper_mmc3.v` 覆盖。
- **程序不做像素检查。** v5 的三个程序都在第一帧之前跑完，只验 mapper 接线与保留路径的握手；背景/精灵像素级回归由 v4 的 testbench 承担（它仍然通过）。
- **MMC1（`MAPPER_SELECT=1`）与 CNROM（`=3`）没有实例。** 两者在 RTL 里可例化，寄存器语义由 `tb/mapper/tb_nes_mapper_mmc1.v`、`tb/mapper/tb_nes_mapper.v` 覆盖；系统级只例化了 0/2/4 三个。
- **层次引用极多**（`dut.u_mapper.u_uxrom.bank_select`、`dut.u_mapper.mmc3_prg_bank6`、`dut.u_ppu.oam_ram`、`dut.u_bus.ram_array`、`dut.u_apu.dbg_frame_irq`…）。与 v0–v4 一致：RTL 里这些名字一旦重命名，testbench 会编译失败。
- **`MAPPER_SELECT` 是 elaboration 期参数**，一个实例整场仿真只有一个 mapper；三个实例并跑不能证明"换 mapper 不需要重新综合"这件事，只证明了三条总线互不串扰。

### v5 明确未实现

以下是被测顶层 `nes_system_v5` 的范围限制，完整清单与理由见 `docs/modules/system-v5.md` 第 8 节：

- **外部 CHR bank 没有接 PPU**：`chr_bank_offset` 在端口上但 PPU 仍用内部 8 KiB CHR RAM，`ppu_addr`/`ppu_a12` 绑 0，因此 CNROM 与 MMC1 的 CHR banking 在系统级不可观测。
- **MMC3 IRQ 计数器在系统级无法被时钟**（`ppu_a12` 绑 0），"A12 沿触发 IRQ"只在 `tb/mapper` 层覆盖。
- **PPU 侧 mirroring 没接**：`nes_ppu2c02` 只有编译期参数 `MIRROR_VERTICAL`，没有运行期端口，v5 不假装接上；四屏的 4 KiB nametable RAM 同样没有。
- **PRG RAM / `$6000-$7FFF` 没有存储阵列**：UxROM 的 WRAM、MMC1 的 `prg_bank[4]`、MMC3 的 `$8000` bit5 与 `$A001` 只到"寄存器"这一层。
- **MMC1 串行移位寄存器在系统级没有被程序驱动过**。
- 与 v4 相同的缺口：`$4017` 读只回手柄位、open bus 上没有手柄位、`$4016` bit6/bit7 扩展口、第 9 次以后读恒 1、手柄物理层、DMC DMA 未激励、`OAMADDR_WRITE=0`、音频输出通路、上板频率与跨时钟域。
