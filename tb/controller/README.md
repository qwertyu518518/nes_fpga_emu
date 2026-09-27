# NES controller testbench

`tb_nes_controller.v` 是 `rtl/nes_core/controller/nes_controller.v` 的自检 testbench。它不下载 ROM、不读外部文件：8 个按钮就是两根 8 位输入总线，testbench 直接驱动它们。

## 三个实例

TB 同时实例化**三份** DUT，共享同一组输入、同一根 `latch_strobe`、同一个 `read_strobe` 脉冲和同一个 `read_select`：

| 实例 | `EXTRA_READ` | 8 次之后的返回值 |
| --- | --- | --- |
| `dut` | `2'd0` | 恒 1 |
| `dut_hold` | `2'd1` | 保持快照的第 8 位 |
| `dut_zero` | `2'd2` | 恒 0 |

`dut` 接全部 debug 输出；`dut_hold` / `dut_zero` 只接 `data_bit`、`data_out`、`dbg_sr1`、`dbg_cnt1`、`dbg_past8`。这样**一次时钟沿就同时验证三种策略**，也保证三个实例看到的激励逐拍完全相同。`dut` 上挂了三个别名（`bit_tie` / `byte_tie` / `*_tie`）纯粹是为了让断言消息可读。

## 时序纪律

TB 的信号变化都发生在 `posedge clk` 之后 `#1`，因此 `latch_strobe` / `read_strobe` 在被采样沿之前有完整的建立时间。三个基础 task：

| task | 作用 |
| --- | --- |
| `apply_reset` | 拉高 `reset` 3 拍，在 negedge 相位释放，回到 `posedge+1` 相位 |
| `hold_latch(n)` | `latch_strobe` 保持 **n 个时钟沿**为高，然后拉低并空一拍 |
| `sample_read(sel)` | 置 `read_select=sel`、`read_strobe=1`，`#1` 后采样 `data_bit`（**这就是 CPU 在这个读周期里看到的值，必须在移位沿之前**），等一个 `posedge` 完成移位，拉低 `read_strobe`，再等一个 `posedge` 保证它有完整一拍低电平 |

`sample_read` 最后那个"多等一拍"不是可有可无的：少了它，两次连续调用之间 `read_strobe` 会在同一个 delta 里 0→1，等价于**一次读移两位**。这个 bug 在开发过程中真实出现过，第一次失败是 `tag 0 port 0: tie word got fe expected 00`。

## 参考模型

8 次读的期望值就是位图本身：**第一次读 = word bit0 = `buttons[0]` = A**。所以 `read8(sel, expected, ...)` 逐位比较三个实例的输出与 `expected`；`read_bits(sel, n, expected, ...)` 用于只读窗口内剩下的 `n` 位（`expected` 的 bit0 是本次调用的第一次读）；`read8_past8_tie` 单独校验 `EXTRA_READ=0` 越界后的 8 次读全为 1。

## 断言覆盖

`tb_nes_controller.v` 使用 `$fatal` 断言并逐行打印 PASS，覆盖：

1. **RESET / 异步性**（`test_reset`）：复位后 `dbg_sr1/sr2`、`dbg_latch1/latch2`、`dbg_cnt1/cnt2` 全 0、`dbg_past8=0`、三个实例的 `data_bit` 和 `data_out` 全 0。`latch_strobe=0` 时把 `buttons` 设成 `8'hFF`，`data_bit` 必须**不跟随**（证明读的是快照不是活线）。随后在**非时钟沿**上拉 `reset`，`#1` 后立即检查 `data_bit`/`dbg_cnt1`/`dbg_sr1` 已清零（证明异步）；释放后 `data_bit` 保持 0；再做一次 `hold_latch` 确认复位后功能正常。
2. **全部 256 种按钮组合 × 两个端口**（`test_all_256_combinations`）：`combo` 从 `0` 到 `255`，`buttons = combo`、`buttons2 = ~combo`（因此 2P 也遍历了全部 256 个值，而且两口永远不同）。每轮断言：并装载寄存器、移位寄存器、计数器清零、`dbg_past8=0`；然后 port 1 读 8 次得到 `combo`，port 2 读 8 次得到 `~combo`，三个 `EXTRA_READ` 实例都必须一致；读完 port 1 后 `dbg_cnt2` 仍为 0（**读一路不推动另一路**），`dbg_past8` 跟随刚读完的那一路。
3. **串行位序**（`test_bit_order`）：对 `idx = 0..7`，只置 `buttons[idx]`，断言 8 次读里**只有第 `idx` 次**为 1（0-based），并且三个 `EXTRA_READ` 实例在窗口内逐位相同。这一条把 `A,B,Select,Start,Up,Down,Left,Right` 的顺序钉死。
4. **strobe 重载**（`test_strobe_reload`）：
   - 读了 3 次之后换一组按钮再 `hold_latch`，计数器归零、8 次读得到**新**快照（不是接续旧序列）。
   - 读了 2 次之后**用同一组按钮**再 `hold_latch`，移位寄存器必须被重新装成 `0x0F`，8 次读得到完整的 `0x0F`（证明是重载而不是"什么都不做"）。
   - **电平敏感装载**：`latch_strobe` 保持为高，中途把 `buttons` 从 `0x00` 改成 `0x01`，`data_bit` 必须**在下一个时钟沿之前**就变成 1（组合路径）；再等一个 `posedge`，`dbg_sr1` 和 `dbg_latch1` 必须都变成 `0x01`；再把 `buttons` 改回 `0x00`，`data_bit` 立刻回 0，而 `dbg_sr1`/`dbg_latch1` **不变**（寄存器只在时钟沿动）。
   - **共享 strobe**：同一个高 strobe 期间 `dbg_sr2`/`dbg_latch2` 已经是 `buttons2 = 0x81`。
   - **高 strobe 下的读不推进**：连做 5 次读，每次都返回当前 `buttons[0]`，而 `dbg_cnt1` 保持 0、`dbg_sr1`/`dbg_latch1` 保持当前 `buttons`。
   - **释放 strobe 冻结快照**：置 `buttons = 0xA5`，等一个 `posedge`（装载），再拉低 `latch_strobe`，移位寄存器停在 `0xA5`；之后 8 次读得到 `0xA5`（1P）和 `0x81`（2P）。
5. **快照语义**（`test_snapshot_semantics`）：`latch_strobe=0` 期间把 `buttons` 从 `0x00` 改成 `0xFF`，`data_bit` 保持 0，8 次读得到 `0x00`。这是"拍照"语义的另一半，和第 4 条的 live 路径正好相反。
6. **8 次之后的策略**（`test_after_eight_reads`）：`buttons = 0x02`（bit7=0）读 8 次后再读 12 次，`EXTRA_READ=0/1/2` 分别必须是 `1/0/0`；同时断言 `dbg_sr` 终值是 `FF/00/00`、`dbg_past8` 三个实例都拉高、计数器**饱和于 9**。然后用 `0x80`（bit7=1）再读 6 次，把 `1/1/0` 分离出来；`0xFF` 再读 4 次得到 `1/1/0`，`0x00` 再读 4 次得到 `1/0/0`——这两组把三种模式两两区分开。最后 `0x3C`：读完 8 次后再读 8 次（`EXTRA_READ=0` 全 1），然后**重新 `hold_latch`**，8 次读又回到 `0x3C` 且 `dbg_cnt1=8`，证明越界之后重载能恢复干净的读窗口。
7. **双端口**（`test_dual_port`）：
   - **交错读**：`buttons=0x0F` / `buttons2=0xF0`，8 轮 `port1, port2` 交错，两路各自按自己的位序推进，最后两个计数器都是 8。
   - **一路耗尽不污染另一路**：读完 port 1 的 8 次后，`dbg_cnt2=0`、`dbg_sr2=dbg_latch2=0xC3`，`dbg_past8=1`（跟着 port 1）；再读完 port 2，`dbg_cnt1` 仍是 8。
   - **中途切换**：`buttons=0xA5` / `buttons2=0x5A`，port 1 读 2 位（`dbg_cnt1=2`）→ 完整读 port 2 的 8 位（`dbg_cnt1` 仍是 2）→ port 1 **从第 3 位继续**读 6 位得到 `0x29`（= 原 `0xA5` 的 bit2..bit7）→ 越界读 8 次全 1。
8. **纯组合选择无副作用**（`test_select_and_idle_isolation`）：`buttons=0x69` / `buttons2=0x96`，`hold_latch` 之后 20 拍只翻 `read_select` 和 `clk`、不发读选通，两个计数器必须一直是 0，`data_bit` 必须精确等于被选中那一路的 bit0。
9. **读选通宽度 = 读取次数**（`test_pulse_width`）：`read_strobe` 连续 3 拍高，`dbg_cnt1` 必须是 3、`dbg_sr1` 必须是 `0xF0`；再读 5 位得到窗口剩下的 `0x10`，再读 8 次全 1（2P 完整读得到 `0x18`）。
10. **中途复位**（`test_reset_midstream`）：读了 5 次后在非时钟沿拉 `reset`，`#1` 后 `data_bit`/`dbg_cnt1`/`dbg_sr1`/`dbg_latch1` 必须立刻清零；释放后重新 `hold_latch` + 读 8 次，1P 得到 `0x18`、2P 得到 `0x81`，功能完好。
11. **多拍 strobe 与背靠背读**（`test_repeated_strobes`）：`hold_latch(3)`（strobe 连续 3 拍高）后两个端口各自读满 8 次（`0xE7` / `0x1E`），再越界读 8 次全 1。

`sample_read` 在**每一次**读上都会检查 `data_out == {7'b0, data_bit}`（三个实例各一遍），所以"bit7:1 恒为 0"这条合同是被上万次读覆盖的，不是只查了一次。

顶部还有 `global timeout`（4000 us 仿真时间）兜底断言。

## 运行

在仓库根目录执行，输出放在临时目录，不向仓库写文件：

```powershell
$tmp = Join-Path $env:TEMP 'op_fpga_emu'
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
& 'C:\iverilog\bin\iverilog.exe' -g2001 -Wall -s nes_controller -o (Join-Path $tmp 'nes_controller_core.vvp') 'rtl\nes_core\controller\nes_controller.v'
& 'C:\iverilog\bin\iverilog.exe' -g2012 -s tb_nes_controller -o (Join-Path $tmp 'tb_nes_controller.vvp') 'rtl\nes_core\controller\nes_controller.v' 'tb\controller\tb_nes_controller.v'
& 'C:\iverilog\bin\vvp.exe' (Join-Path $tmp 'tb_nes_controller.vvp')
```

核心是 Verilog-2001 源码，可以单独用 `-g2001 -Wall` elaborate（**零 warning**）。testbench 使用 `$fatal`，因此 Icarus 入口使用 `-g2012`，与仓库现有 PPU/APU testbench 相同。

下面是本版本的完整期望输出，逐行对应一个 test task；vvp 退出码 0，仿真时间 95.136 us，实测运行约 0.05 s：

```text
CONTROLLER reset values and asynchronous clear PASS
CONTROLLER all 256 button combinations on both ports PASS
CONTROLLER serial order A,B,Select,Start,Up,Down,Left,Right PASS
CONTROLLER strobe reload, level-sensitive latch and shared $4016/$4017 strobe PASS
CONTROLLER reads return the latched snapshot, not the live buttons PASS
CONTROLLER read-9-and-beyond strategies for all three EXTRA_READ modes PASS
CONTROLLER two ports, independent shift registers, shared strobe PASS
CONTROLLER read_select and clock alone are side-effect free PASS
CONTROLLER one read per asserted cycle, pulse width equals read count PASS
CONTROLLER reset aborts a partial read and the port still works PASS
CONTROLLER repeated strobe cycles and back to back reads PASS
PASS nes_controller
```

任何 `$fatal` 命中会让 vvp 以非零退出码结束，并把检查名、实际值、期望值和（多数情况下）出错的 tag 打印到 stdout。

作为置信度检查，对 RTL 的**临时副本**（仓库里的 RTL 未被修改）做了 19 处定向变异：移位方向反了（1P 和 2P 各一处）、并装载不再进移位寄存器（1P 和 2P 各一处）、`read_select` 被忽略（1P 和 2P 各一处）、`read_strobe` 在高 strobe 下不再被屏蔽、strobe 不清计数器、strobe 不装 2P、`last` 不在第 8 次后冻结、计数器饱和值改成 15、`fill_one` 恒 1、`hold_last` 恒 0、去掉高 strobe 下的 live-A 路径、`data_out[0]` 取反、`data_out[7:1]` 填 `0x40`、复位改成同步、复位不清移位寄存器、`dbg_past8` 差一位。**18 处被 testbench 立即抓到**，第一次失败的位置和预期一致（例如移位方向反了立刻是 `tag 0 port 0: tie word got fe expected 00`，`read_select` 被忽略立刻是 `combo 0: reading port 1 advanced the port 2 counter`）。

剩下 1 处（把 `read1` 里的 `!latch_strobe` 去掉）是**等价变异**而不是覆盖空洞：`always` 块里是 `else if (latch_now) ... else ...` 的结构，读分支只可能在 `latch_strobe=0` 的 `else` 里被求值，所以那一项在当前结构下本来就是冗余的。

`tools/sim_all.ps1` 没有 controller 目标，ModelSim 也没有对应的 `run_controller_tb.do`；这两个脚本不在本任务的写入范围内，没有改。
