# 系统集成 v3：DMA 仲裁点、`$2003`/`$2004` 端口同沿竞争与 OAM DMA

本文是 `rtl/nes_core/system/nes_system_v3.v` 的接口与接线合同，重点回答 v2 遗留的那个空缺：**总线上多了一个 DMA 主机以后，同一个 `posedge clk` 上有多个寄存器写入同一个地方时，谁赢、为什么、以及同沿竞争具体长什么样**。

`docs/modules/cpu-bus.md` 已经逐条覆盖 `nes_cpu_bus` 自身的 `owner`/ready/valid 合同，`docs/modules/oam-dma.md` 覆盖 `nes_oam_dma` 的状态机与对齐相位，`docs/modules/system-v2.md` 覆盖 v2 的等待路径代价。本文不重复这三份，只写 v3 的增量接线、**同沿竞争的两种形态（地址译码侧、源页锁存侧）**、以及 v3 明确未实现的部分。行为权威是 NESdev 的 CPU 地址图、`$4014` 的 DMA 语义与 OAM DMA 的 513/514 + 1/+2 拍相位；cNES（`caseif__cNES`，commit `7c8c252`）与 Obara（`ObaraEmmanuel__NES`，commit `aa880b9`）只作为“别人怎么写”的观察。

---

## 1. 文件与层次

```text
rtl/nes_core/system/
├── nes_system_v0.v   自带 RAM / 地址 mux / 常电 bus_ready，只有 CPU + PPU(背景)
├── nes_system_v1.v   加 APU v1、$4014 访问记录，仍是常电 bus_ready
├── nes_system_v2.v   加 nes_cpu_bus（真等待）、精灵、owner/ready 观测端口
└── nes_system_v3.v   在 v2 上加 nes_oam_dma 与 DMA 仲裁点（dma_req/ack/wait/active）
```

v3 的内部层次（只画 v2→v3 新增的部分）：

```text
                    nes_cpu_bus.u_bus.dma_req_oam / dma_req_dmc
                              |                  |
                     dma_addr (oam 优先)   dma_sel = 选中 dmc ?
                              \                  /
                    nes_cpu_bus 的 DMA 通道 (与 CPU 通道同一 owner 端口组)
                              |
              dma_ack / dma_din / dma_wait / dma_active
                              |
          +-------------------+-------------------+
          |                                       |
   oam_dma_cpu_read_ack =                    apu_dmc_ack =
   dma_ack && !dma_sel                       dma_ack &&  dma_sel
          |                                       |
    nes_oam_dma.oam_addr(cpu)               nes_apu2a03.dmc_rdata

   bus_hold = oam_dma_cpu_hold || apu_dmc_bus_req
              ^^^^^^^^^^^^^^^^^^   ^^^^^^^^^^^^^
              冻结 CPU             冻结 DMC 发起

   ppu_port_cs/we/addr/din = oam_dma_ppu_reg_* ? oam_dma_* : ppu_xfer_*
   ppu_port_din 的 DMA 通路再与 ppu_port_we 一起喂给 nes_ppu2c02 的 oamdata 写口
```

`dma_owner` 的仲裁规则是纯组合的：`dma_req_oam` 优先，`dma_req_dmc` 只在 OAM 没请求时成立（`nes_cpu_bus` 里的 `dma_pick_oam = dma_req_oam`、`dma_pick_dmc = !dma_req_oam && dma_req_dmc`）。因此 `dma_sel` 就是“这一笔是 DMC 的”，`oam_dma_cpu_read_ack` 与 `apu_dmc_ack` 是同一个 `dma_ack` 上的两个互斥译码项，**任何一侧都不允许把自己的 ack 当成对方的**。

## 2. DMA 仲裁点的接线

`bus_hold` 是 v3 唯一的 CPU 冻结信号：

```verilog
assign bus_hold = oam_dma_cpu_hold || apu_dmc_bus_req;
```

`nes_cpu6502` 内部有 `if (!cpu_active) bus_req = 1'b0;`，所以 `bus_hold` 为高时 CPU 不会撤回也不会推进请求，`bus_fire` 恒为 0；`nes_cpu_bus` 内部则是 `else if (ce && !bus_hold) { ...CPU 通道... } else if (ce) { ...DMA 通道... }`，即 `bus_hold` 高的那些 `ce` 拍整个让给 DMA 分支。这就是 v2 的 `if (bus_stall)` 语义在 DMA 上的延伸：**等待拍的归属由一个显式的仲裁信号决定，而不是由地址译码决定**。

v3 TB 把这条写成断言而不是注释：

| 合同 | 断言 |
| --- | --- |
| `bus_hold === (oam_dma_cpu_hold \|\| apu_dmc_bus_req)` | 逐 clk `$fatal` |
| `oam_dma_cpu_hold === oam_dma_busy` | 逐 clk `$fatal` |
| `bus_hold` 期间没有 `bus_fire`、没有 `bus_req` | `dma_fire_err` / `dma_req_err` |
| `bus_hold` 期间 `dbg_state` 与 `dbg_pc` 冻结 | `dma_freeze_fail` |
| `bus_hold` 期间 `ppu_reg_cs` / `apu_reg_cs` 为 0 | `dma_ppu_cs_err` / `dma_apu_cs_err` |
| 每个 `dma_ack` 都有 `bus_hold`，且不与 `bus_fire` 同拍 | `dma_ack_no_hold` / `dma_ack_with_cpu` |
| `dma_wait === (req && !ack)` | `dma_req_pending_err` |
| `dma_active` 一旦拉高必须保持到 `dma_ack` | `dma_active_err` |
| OAM ack 时 `dma_owner === 0`，ack 不允许连续两拍 | 逐次 `$fatal` / `dma_ack_together` |

### 2.1 `dma_active` 的“首个 ce 允许为 0”

`nes_cpu_bus` 的 `dma_active = dma_grant && dma_active_r`，而 `dma_active_r` 在**看到请求的那一个 `ce` 沿之后**才置 1；`dma_ready` 又要求 `dma_active_r` 为 1 才可能给 `dma_ack`。因此：

```text
clk N   : oam_dma_cpu_read_req 拉高，dma_grant=1，dma_active_r=0 -> dma_active=0，dma_ack=0
clk N+1 : dma_active_r=1                                          -> dma_active=1，dma_ack=1
```

也就是说**请求的第一个 `ce` 拍上 `dma_active` 必然还是 0**。这是状态机的正常一拍延迟，不是缺陷。TB 因此不写“请求且未 ack 时 `dma_active` 必须为 1”（那会在这 768 个字节上稳定失败），而写成 v3 才有的那条更强也更准确的断言：

```verilog
if (dma_active === 1'b0) begin
    dma_active_seen = 1'b0;
end else begin
    if ((dma_active_seen === 1'b1) && (dma_ack === 1'b0))
        dma_active_err = dma_active_err + 1;
    dma_active_seen = 1'b1;
end
```

即**“进入等待后不允许中途退出等待”**：一旦 `dma_active` 拉高，在 `dma_ack` 之前不得掉回 0。这条断言能抓住“`dma_active_r` 被 `!dma_grant` 分支提前清掉”这类真实的握手漏洞，而不会去管那一拍正常的状态机延迟。

## 3. `$2003` 影子寄存器：DMA 期间必须与 PPU 一致

真机上 OAM DMA 结束后 `OAMADDR` 停在 `$00`。v3 不让 DMA 引擎驱动 `$2003`（`nes_oam_dma` 的 `OAMADDR_WRITE` 参数为 0，v3 TB 断言 `oam_dma_addr_wr` 全程为 0），而是在顶层维护一个影子寄存器：

```verilog
always @(posedge clk or posedge reset) begin
    if (reset)                              oam_addr_q <= 8'h00;
    else if (ppu_port_cs) begin
        if (ppu_port_we) begin
            if      (ppu_port_addr == 3'd3) oam_addr_q <= ppu_port_din;
            else if (ppu_port_addr == 3'd4) oam_addr_q <= oam_addr_q + 8'd1;
        end else if (ppu_port_addr == 3'd4) oam_addr_q <= oam_addr_q + 8'd1;
    end
end
```

它与 `nes_ppu2c02` 自己的 `oam_addr_reg` 是**两路独立推进的同构逻辑**，TB 逐 clk 断言 `oam_dma_base_addr === dut.u_ppu.oam_addr_reg`（`dma_shadow_err`）。之所以不用 PPU 的寄存器直接喂给 DMA，是因为 `oam_addr` 必须在 `start` 的那一个沿被采样（见下节），而 PPU 的 `oam_addr_reg` 在同一沿也在变；从顶层先看一眼地址空间比在引擎内部再加一级采样更省一拍对齐逻辑。

## 4. 同沿竞争之一：`$2003` / `$2004` 的端口 mux

`nes_ppu2c02` 的寄存器口只有一组 `reg_cs/reg_we/reg_addr/reg_din`，而 v3 有两个源要驱动它：CPU 侧（`ppu_xfer`）和 OAM DMA 侧（`nes_oam_dma.ppu_reg_cs`）。顶层做的是**纯组合的源选择**：

```verilog
assign ppu_port_cs   = oam_dma_ppu_reg_cs ? 1'b1 : ppu_xfer;
assign ppu_port_we   = oam_dma_ppu_reg_cs ? oam_dma_ppu_reg_we : ppu_we;
assign ppu_port_addr = oam_dma_ppu_reg_cs ? oam_dma_ppu_reg_addr : ppu_addr;
assign ppu_port_din  = oam_dma_ppu_reg_cs ? oam_dma_ppu_reg_dout : ppu_dout;
```

之所以不需要互锁：`bus_hold = oam_dma_cpu_hold = oam_dma_busy` 已经在 `nes_oam_dma` 离开 `ST_IDLE` 的同一拍拉高，因此 DMA 期间 `ppu_xfer` 恒为 0，两个源在物理上不可能同时有效。TB 不接受“靠时序恰好不冲突”这种运气，因此同时断言了两件事：

```verilog
if (ppu_port_cs !== (oam_dma_ppu_reg_cs || ppu_reg_cs)) port_cs_err = port_cs_err + 1;
if (oam_dma_ppu_reg_cs !== 1'b0 && ppu_reg_cs !== 1'b0)   dma_ppu_conflict = dma_ppu_conflict + 1;
```

前者把 mux 的三态语义钉死（`ppu_reg_cs` 恒等于 `ppu_xfer`，不是 `ppu_req`），后者保证“冲突计数为 0”是**结构事实**而不是“没有发生”。DMA 写 `$2004` 的每一个 `clk` 上还额外断言 `ppu_reg_addr == 3'd4`、`ppu_reg_we == 1'b1`，并且 `ppu_reg_cs` 不得连续两拍为高。

另外，DMA 写 `$2004` 与 CPU 读 `$2004` 的区分靠 `ppu_port_we`：CPU 读走 `ppu_port_we = ppu_we = 0`，DMA 写走 `reg_we = 1`，而 OAM 读后写会顺带把 `OAMADDR` 加一。TB 因此在 DMA 侧断言 `oam_dma_ppu_reg_addr == 3'd4` 恒成立、且 `oam_dma_ppu_reg_dout` 必须等于“上一次被 ack 的那次读的 `dma_din`”以及对应源地址上的 `ram_array` 内容（`dma_wr_order_err`）。CPU 侧则断言 `ppu_wr_oamdata == 0`——**CPU 一次 `$2004` 写都没有**，OAM 的内容只由 DMA 与 testbench 预填决定。

## 5. 同沿竞争之二：`$4014` 源页锁存（v3 的核心缺陷与修法）

这是本次修复的真实缺陷，也是 v3 与 v2 唯一的语义分水岭。

### 5.1 症状

`$4014` 的写数据就是 DMA 的源页号。v3 一开始把它锁存在顶层：

```verilog
assign oam_dma_start = apu_xfer && apu_we && (apu_addr == APU_REG_OAMDMA);

always @(posedge clk or posedge reset) begin
    if (reset)                        oam_dma_page_q <= 8'h00;
    else if (oam_dma_start)           oam_dma_page_q <= apu_dout;
end

assign oam_dma_page = oam_dma_page_q;      // 喂给引擎
```

而 `nes_oam_dma` 在 `ST_IDLE` 看到 `start` 的那一个沿做：

```verilog
ST_IDLE: if (start) begin
    page_q      <= src_page;               // 读的是沿前值
    read_addr_q <= {src_page, 8'h00};      // 读的是沿前值
```

两个寄存器在**同一个 `posedge clk` 上更新**，都看到沿前的旧值：

```text
clk N-1 : apu_xfer=1, apu_we=1, apu_addr=$14, apu_dout=$05
clk N   : 沿前 oam_dma_page_q = $02（上一笔的页）
          沿上 oam_dma_page_q <= $05
          沿上 page_q         <= $02   <-- 拿的是旧页
```

结果：**每次 DMA 都用上一页搬运**。三次传输的实测表现是第一次搬 `$00` 页、第二次仍搬 `$00` 页、第三次搬 `$05` 页，OAM 内容与三个标记单元全部对不上，而所有“地址顺序”“ack 数量”“`$2004` 写入顺序”的断言都**不会**报错——因为地址确实是自洽的，只有页号是错的。这类缺陷在 testbench 里只能靠“内容对不对”抓，“顺序对不对”抓不到。

### 5.2 为什么不能简单地“延后一拍拍 `start`”

把 `oam_dma_start` 延到 `clk N+1`（用一个 `start_q`）看似更干净，实际有两个问题：

1. `$4014` 写完成的 `clk N` 与 `bus_hold` 拉高之间会插进一拍空窗，那一拍 `nes_oam_dma` 还在 `ST_IDLE`（`busy=0`、`cpu_hold=0`），而 `nes_cpu_bus` 已经开始准备下一笔 CPU 事务。DMA 引擎的 `busy` 与总线的 `bus_hold` 会脱拍一整拍。
2. 真正需要跨沿传递的是“沿前的写数据”，而 `apu_dout` 在 `clk N+1` 已经换成别的内容了，延后 `start` 反而要**额外**再存一份 `apu_dout`，等价于把同一个寄存器挪个位置，绕不开。

### 5.3 修法：用 mux 绕过，而不是用延时绕过

关键在于 `nes_oam_dma` 只在 `start` 为高的那一个沿采样 `src_page`。既然“沿前的正确页号”此刻就在 `apu_dout` 上，把它直接旁路进去即可：

```verilog
nes_oam_dma u_oam_dma (
    .start    (oam_dma_start),
    .src_page (oam_dma_start ? apu_dout : oam_dma_page),   // <-- 修法
    ...
    .dbg_page (oam_dma_page_latch_wire),
    ...
);
```

- `oam_dma_start` 为高的那一拍，`src_page` 直接等于 `apu_dout`（本次 `$4014` 写的沿前数据），`nes_oam_dma` 在这一沿就锁到正确的页。
- 其余所有拍 `src_page = oam_dma_page = oam_dma_page_q`，与旧行为逐拍相同；`nes_oam_dma` 在 `ST_IDLE` 之外不采样 `src_page`，所以这不影响传输过程。
- `oam_dma_page_q` **保留**：它是 TB 断言“顶层记住的页”与“引擎锁到的页”必须一致的唯一可观测量，也是 `oam_dma_page` 这个调试端口的语义来源。修法不删寄存器，只把引擎的采样源在 `start` 那一拍换成正确的那个值。

### 5.4 怎么把这类缺陷钉死在 testbench 里

v3 TB 的做法是把“顶层影子寄存器”和“引擎内部锁存器”都引出来（`oam_dma_page` / `oam_dma_page_latch`），然后断言它们相等：

```verilog
if (oam_dma_busy !== 1'b0 && oam_dma_page !== oam_dma_page_latch)
    $fatal(1, "the source page latch disagreed with the engine, page=%02x latch=%02x",
           oam_dma_page, oam_dma_page_latch);
```

这条断言与 5.1 的缺陷**逐位对应**：修好之前，第一次 DMA 一开始就报

```text
FATAL: tb/system/tb_nes_system_v3.v:1461: the source page latch disagreed with the engine, page=02 latch=00
       Time: 5140855000
```

它被写成**即时 `$fatal`** 而不是计数器 + 结算期汇总，原因就是这类同沿竞争一旦发生，后面 768 个字节的比较全部是垃圾值，汇总式断言要么误报一堆无关的“内容不符”，要么被前面的失败掩盖。位置越早，根因越清楚。

## 6. TB 期望值的三处修正（不是放宽断言）

修好 RTL 之后，v3 testbench 里有三条期望值本身是过期的，需要按真实 trace 修正。三条都**不是**放宽总线或栈地址断言，而是把过严的边界值改成正确的边界值：

### 6.1 `RTI` 期间 `dbg_pc` 落在 `nmi_end` / `irq_end` 上是合法的

`nmi_end` / `irq_end` 是**`RTI` 指令自身的地址**（`build_nmi_handler` 里 `emit(8'h40); nmi_end = pc;`）。`RTI` 的取指、三个出栈周期、返回地址恢复都在 `dbg_pc == nmi_end` 这一个值上停留，因此“跑过服务例程”的判据必须用 `dbg_pc > nmi_end`（严格大于）而不是 `dbg_pc > nmi_end - 1`：

```verilog
if ((dut.u_cpu.dbg_pc > nmi_end) && (dut.u_cpu.dbg_pc < IRQ_HANDLER))
    $fatal(1, "the cpu ran past the nmi handler, pc=%04h", dut.u_cpu.dbg_pc);
if ((dut.u_cpu.dbg_pc > irq_end) && (dut.u_cpu.dbg_pc < INIT_ROUTINE))
    $fatal(1, "the cpu ran past the irq handler, pc=%04h", dut.u_cpu.dbg_pc);
```

`init_end` 那一条本来就用 `init_end - 1`（`RTS` 的地址不会被 `dbg_pc` 停留，因为 `RTS` 之后 PC 直接跳回），所以不动。总线的地址白名单、`$2000-$FFFF` 的 PC 范围断言、`$01F0-$01FF` 的栈地址断言**一条都没有改**。

### 6.2 `OPEN_BUS_CELL` 被程序写了两次

`build_main` 里 `STA $0017` 出现两次：一次是主程序开头的清零，一次是 `LDA $4020` 之后把 open bus 探针存回去。期望值因此是 2：

```verilog
if (ram_wr_open != 2)
    $fatal(1, "writes to the open bus cell got %0d expected 2", ram_wr_open);
```

与之配套的 `check_owner_accounting` 仍然断言终值等于 `probe_opcode`（`$4020` 返回的上一次完成传输的字节，即 `LDA abs` 取操作数时高字节 `$40` 那笔之后的 sticky 值），所以“写了两次”不等于“少了一次有效的探针”。

### 6.3 `jsr_frame` 只统计 `$01F9`

`JSR` 把返回地址压栈时是 `$01F9 <- PCH`、`$01F8 <- PCL`；`RTS` 从同一对地址读回。也就是说 `$01F9` 的**写**恰好对应一次 `JSR`，而 `$01F8` 的写与读都只是这次 `JSR` 的另一半。v2 的 testbench 把 `$01F8/$01F9` 一起计数，v3 拆开：

```verilog
11'h1F9: jsr_frame = jsr_frame + 1;
11'h1F0, 11'h1F1, 11'h1F2, 11'h1F3, 11'h1F4, 11'h1F5,
11'h1F6, 11'h1F7, 11'h1F8, 11'h1FA, 11'h1FB, 11'h1FC,
11'h1FD, 11'h1FE, 11'h1FF: begin
end
```

`$01F8` 不是被放过，而是被移进**合法栈写白名单**——`$01F0-$01FF` 本来就全部合法（`$01F0-$01FF` 是 6502 的硬件栈页），白名单只是“不把它算成 `jsr_frame` 计数”的意思。`stk_rd` / `stk_wr` 对 `$01F0-$01FF` 的逐地址统计保持不变，因此栈活动仍然被逐字节记账。

## 7. v3 明确未实现

以下是**被测顶层 `nes_system_v3`** 的范围限制，不是 testbench 的缺陷：

- **DMC DMA 通路存在但从未被激励**。`apu_dmc_bus_req` 进了 `bus_hold` 与 `nes_cpu_bus` 的 `dma_req_dmc`，`dma_sel` 也会译码到 `apu_dmc_ack`，但 v3 TB 的程序从不写 `$4010-$4013`，因此断言 `apu_dmc_bus_req` 与 `dma_sel` 全程为 0、`dbg_dmc_irq` 永不抬升。**没有**任何保护阻止未来程序启动 DMC 后把 `$4010` 的 rate 寄存器配成非零而撞上一个未验证的握手。
- **`$4018-$5FFF`**：读 `$00`、写忽略，与 v0/v1/v2 一致。
- **`$6000-$7FFF`**：owner 是 `CART_RAM`，读回 `$00`、写丢弃，没有 PRG RAM。
- **mapper**：没有 mapper 寄存器、没有 bank 切换、没有 mapper IRQ，`PRG_SIZE_BYTES` 只是容量参数（默认 16 KiB，NROM-128 行为）。$8000-$FFFF 的三个向量地址靠 16 KiB 折回到同一段物理存储。
- **`OAMADDR_WRITE = 0`**：v3 不实现真机 DMA 期间“把 `OAMADDR` 写成 0 再由对齐拍写 `$2003`”的那一拍。代价是 DMA 的起始对齐相位由 `nes_oam_dma` 内部的 `parity_q` 给出，跨 DMA 连续调用时对齐相位跟随总 `clk` 奇偶，而不是跟随 CPU 周期奇偶；`xfer_align` 在实测里全程为 0，说明三个传输的起始相位都落在同一边上，本 testbench 不区分相位错误。
- **精灵 DMA 与 sprite 0 hit / overflow**：`nes_ppu_sprite` 在系统里，sprite 渲染本身工作（被检查帧的 `sprite6 = 64`），但 `dbg_sprite0_hit` / `dbg_sprite_overflow` 仍然悬空，v3 TB 不覆盖。
- **音频输出通路**：没有 FIFO、没有抽取/重采样、没有 WM8978 接口。`audio_sample_valid` 是 `ce_cpu` 速率的 strobe，不是音频速率。
- **左右声道差异**：`sample_left` 与 `sample_right` 取同一个 `mixed_sample`。
- **上板频率与跨时钟域**：v3 保留 12 拍 `div_phase` 作为仿真相位，全部模块在同一 `clk` 域，未解决 `docs/modules/system-v2.md` 记录的真实频率问题，也没有 owner 侧 ack 回到 `clk` 域的同步逻辑。
