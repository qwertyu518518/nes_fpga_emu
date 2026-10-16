# 61 中间三代 System 顶层精读：`nes_system_v2.v` / `nes_system_v3.v` / `nes_system_v4.v`

前一篇 [`60-system-early.md`](60-system-early.md) 讲 v0 / v1：CPU + PPU + APU 已能一起跑，但顶层**自己**扛着 RAM、地址 mux 和一根常电的 `bus_ready`。这一篇讲**中间三代** v2 / v3 / v4——它们不是三个不同的系统，而是**同一骨架逐版各加一块零件**：

| 版本 | 加进来的零件 | 一句话 |
|---|---|---|
| [v2](../../rtl/nes_core/system/nes_system_v2.v) | `nes_cpu_bus` | 把 RAM / 译码 / 等待态从顶层挪进总线模块，第一次真走等待路径 |
| [v3](../../rtl/nes_core/system/nes_system_v3.v) | `nes_oam_dma` | 总线上出现**第二个主机**和显式 DMA 仲裁点 |
| [v4](../../rtl/nes_core/system/nes_system_v4.v) | `nes_controller` | 把 `$4016` / `$4017` 接成手柄，并在读数据上做一次总线 override |

**读法主线是"相对上一版的 delta"**：v3 相对 v2 加了什么、v4 相对 v3 加了什么。三代共用的部分（12 拍分频、CPU / PPU / APU 例化、帧与音频端口）只在 v2 说一次。

- 合同与证据：[`../modules/system-v2.md`](../modules/system-v2.md)、[`../modules/system-v3.md`](../modules/system-v3.md)、[`../modules/system-v4.md`](../modules/system-v4.md)
- 测试目标：`system-v2` / `system-v3` / `system-v4`（见 [`tools/sim_all.ps1`](../../tools/sim_all.ps1) 与 [`tb/system/README.md`](../../tb/system/README.md) 的 v2 / v3 / v4 三节）
- 先修：总线 [`30-cpu-bus.md`](30-cpu-bus.md)、OAM DMA [`24-oam-dma.md`](24-oam-dma.md)、手柄 [`20-controller.md`](20-controller.md)、精灵 [`52-ppu-sprite.md`](52-ppu-sprite.md)

---

## 1. 先认识"上游和下游"

三个顶层长成同一个样子：一个自由运行的 `clk`，用 `div_phase` 分出节拍，把 CPU / PPU / APU / 总线（以及后加的 DMA、手柄）连在一起。

```text
                    div_phase (0..11)
                         |
       +-----------------+------------------+
       |                 |                  |
    ce_cpu=1          ce_ppu=1/3        ce_sample=1
       |                 |
       |            nes_ppu2c02  (内含 nes_ppu_sprite 精灵通路)
       |                 |  reg_cs = 完成脉冲
       |              ppu_nmi ─────────────► u_cpu.nmi_i
       |
       +--> u_cpu.ce ──► nes_cpu6502 ──req/we/addr/dout──► [nes_cpu_bus]
       +--> u_bus.ce ──► nes_cpu_bus  ◄──din/ready/fire────┘      |
                                  |  ram / ppu / apu / cart 四类 owner
       v3: nes_oam_dma ─ DMA 主机 ─► nes_cpu_bus 的 DMA 通道（与 CPU 争总线）
       v4: nes_controller ─ $4016/$4017 ─► 在 cpu_din 上 override 串行位
```

- **v2 的关键动作**：顶层"自己去 RAM 取数 / 自己看地址 / 自己给 `bus_ready`"整体消失，换成例化一个 `nes_cpu_bus`。顶层从此只做**连线**，不再做译码。
- **v3 的关键动作**：`nes_oam_dma` 成为第二个总线主机，它和 CPU 通过 `bus_hold` + `dma_req/ack` 抢总线。
- **v4 的关键动作**：`nes_controller` 不碰 `nes_cpu_bus`，只在顶层用组合逻辑把 `$4016/$4017` 的访问"截下来"，把串行位塞进 CPU 读数据。

---

## 2. 骨架代码（只贴 delta 关键片段）

不全文照贴三个文件，只贴每一版**新增/改变接线**的那几行。

### 2.1 v2 相对 v1：总线替换

```verilog
nes_cpu_bus #(
    .READ_WAIT_CYCLES(8'd1), .RAM_ADDR_BITS(11),
    .RAM_READ_SYNC(1'b1),    .RAM_INIT(8'h00)
) u_bus (
    .clk(clk), .reset(reset),
    .ce(ce_cpu),                 // <-- 必须是 CPU 使能，不是常电 1
    .bus_hold(bus_hold),         // v2 里 bus_hold = 1'b0
    .cpu_req(cpu_bus_req), .cpu_we(cpu_we),
    .cpu_addr(cpu_addr), .cpu_dout(cpu_dout), .cpu_din(cpu_din),
    .cpu_ready(cpu_bus_ready), .cpu_fire(cpu_bus_fire),   // <-- 直接接 CPU 握手
    .sel_ram(sel_ram), .sel_ppu(sel_ppu), .sel_apu_io(sel_apu_io),
    .sel_open_bus(sel_open_bus), .sel_cart_ram(sel_cart_ram), .sel_cart_rom(sel_cart_rom),
    ...
);

assign bus_hold = 1'b0;          // v2：仲裁点已就位，但没去拉它
```

CPU 与总线的四根握手线两边同名接（`bus_req`/`bus_fire`/`bus_addr`/`bus_we`/`bus_dout`/`bus_din`/`bus_ready`）。PPU / APU 的 `reg_cs` 只用**完成脉冲**：

```verilog
nes_ppu2c02 #(.MIRROR_VERTICAL(1'b0)) u_ppu (
    ...
    .reg_cs(ppu_xfer), .reg_we(ppu_we), .reg_addr(ppu_addr),
    .reg_din(ppu_dout), .reg_dout(ppu_reg_dout),
    ...
);
```

### 2.2 v3 相对 v2：`nes_oam_dma` + DMA 仲裁点

```verilog
nes_cpu_bus #(..., .DMA_PRESENT(1'b1), .DMA_MMIO_VALUE(8'h00)) u_bus (
    ...,
    .dma_req_oam(oam_dma_cpu_read_req), .dma_req_dmc(apu_dmc_bus_req),
    .dma_addr(dma_addr), .dma_sel(dma_sel), .dma_din(dma_din),
    .dma_ack(dma_ack), .dma_wait(dma_wait), .dma_active(dma_active), ...
);

assign bus_hold = oam_dma_cpu_hold || apu_dmc_bus_req;
assign dma_addr = oam_dma_cpu_read_req ? oam_dma_cpu_read_addr : apu_dmc_addr;
assign oam_dma_cpu_read_ack = dma_ack && !dma_sel;
assign apu_dmc_ack           = dma_ack &&  dma_sel;
assign oam_dma_start = apu_xfer && apu_we && (apu_addr == APU_REG_OAMDMA);  // 5'h14
```

`$2003` / `$2004` 两个源共用一组 PPU 寄存器口的组合 mux：

```verilog
assign ppu_port_cs   = oam_dma_ppu_reg_cs ? 1'b1                 : ppu_xfer;
assign ppu_port_we   = oam_dma_ppu_reg_cs ? oam_dma_ppu_reg_we   : ppu_we;
assign ppu_port_addr = oam_dma_ppu_reg_cs ? oam_dma_ppu_reg_addr : ppu_addr;
assign ppu_port_din  = oam_dma_ppu_reg_cs ? oam_dma_ppu_reg_dout : ppu_dout;
```

`$4014` 源页的**同沿竞争修法**——引擎采样源在 `start` 那一拍旁路成沿前的 `apu_dout`：

```verilog
nes_oam_dma #(.OAMADDR_WRITE(1'b0)) u_oam_dma (
    .clk(clk), .reset(reset),
    .start(oam_dma_start),
    .src_page(oam_dma_start ? apu_dout : oam_dma_page),   // <-- 修法
    .oam_addr(oam_dma_base_addr),
    .cpu_read_ack(oam_dma_cpu_read_ack), .cpu_rdata(oam_dma_cpu_rdata),
    .cpu_hold(oam_dma_cpu_hold), .cpu_read_addr(oam_dma_cpu_read_addr),
    .cpu_read_req(oam_dma_cpu_read_req),
    .ppu_reg_cs(oam_dma_ppu_reg_cs), .ppu_reg_we(oam_dma_ppu_reg_we),
    .ppu_reg_addr(oam_dma_ppu_reg_addr), .ppu_reg_dout(oam_dma_ppu_reg_dout),
    ...
);
```

### 2.3 v4 相对 v3：`nes_controller` + 读数据 override

```verilog
localparam [4:0] APU_REG_OAMDMA = 5'h14;
localparam [4:0] APU_REG_CTRL1  = 5'h16;   // $4016
localparam [4:0] APU_REG_CTRL2  = 5'h17;   // $4017

wire apu_addr_ctrl1      = (apu_addr == APU_REG_CTRL1);
wire apu_addr_ctrl2      = (apu_addr == APU_REG_CTRL2);
wire apu_addr_ctrl_owned = apu_addr_ctrl1 || (apu_addr_ctrl2 && !apu_we);
wire apu_ctrl_xfer       = apu_xfer && apu_addr_ctrl_owned;
wire apu_ctrl_read       = apu_ctrl_xfer && !apu_we;
wire apu_port_cs         = apu_xfer && !apu_addr_ctrl_owned;

assign cpu_din = apu_ctrl_xfer ? {7'b0, controller_data} : bus_cpu_din;

reg latch_strobe_q;
always @(posedge clk or posedge reset) begin
    if (reset)                                      latch_strobe_q <= 1'b0;
    else if (apu_xfer && apu_we && apu_addr_ctrl1)  latch_strobe_q <= cpu_dout[0];
end

nes_controller u_controller (
    .clk(clk), .reset(reset),
    .latch_strobe(latch_strobe_q),
    .read_strobe(apu_ctrl_read), .read_select(apu_addr_ctrl2),
    .buttons(buttons1), .buttons2(buttons2),
    .data_bit(controller_data),
    ...
);
```

---

## 3. 逐段精读（按版本分节，突出 delta）

### 3.1 v2：为什么改用 `nes_cpu_bus`

v0 / v1 的顶层把三件事**自己**做掉：一个 2 KiB 的 `cpu_ram`、一个 `case (cpu_addr[15:13])` 的地址 mux、一根 `assign bus_ready = !reset` 的常电。后者意味着**一次访存在一拍内完成**——"等待"机制在 v0/v1 里从没被运行过。v2 把这三件事整体挪进 `nes_cpu_bus`：

| 原本在顶层 | v2 之后在 `nes_cpu_bus` |
|---|---|
| `cpu_ram`（2 KiB） | `ram_array`（`RAM_ADDR_BITS=11`，`$0000-$1FFF` 四路镜像折叠到 2 KiB） |
| `case (cpu_addr[15:13])` 译码 | `decode_owner`：把访问归给六个 owner（`sel_*` 独热） |
| `bus_ready = !reset` | `wait_cnt` / `active` 组成的等待状态机，输出 `cpu_ready` |

顶层从"系统实现者"变成"系统接线员"。`nes_cpu_bus` 自身的合同见 [`30-cpu-bus.md`](30-cpu-bus.md)。

#### 等待态与 `bus_ready` 的关系

`nes_cpu6502` **不是**"每拍前进一格"的微码机，而是**只在 `bus_ready` 为高时才前进一格**的状态机：`cpu_active = ce && !bus_hold && !reset`，`bus_fire = bus_req && bus_ready`。所以 `bus_ready` 必须在 `ce_cpu` 那一拍恰好为高，否则 CPU 永远停在原地。一次事务 = CPU 提 `cpu_req`，总线在某一拍把 `cpu_ready` 拉高，那一拍两边同时"完成"。

本仓库在 `c7ebf00` 之后 `ce_cpu` **就是** CPU 周期，所以 `READ_WAIT_CYCLES=1` 配 `wait_need <= 1` 表示**零等待**：`cpu_ready` 在请求提出的第一拍就已为高，完成沿就是请求沿所在的**同一个** `ce_cpu`。直观记法：**`bus_ready` 不是"再等一拍"，而是"这一拍就绪"**。

#### `ce` 为什么必须接 `ce_cpu`（否则死锁）

`nes_cpu_bus` 的等待状态机只在 `ce` 为高的沿推进，而 `nes_cpu6502` 内部有 `if (!cpu_active) bus_req = 1'b0;`——`cpu_req` 只在 `ce_cpu` 那一拍为高。若把 `ce` 接成常电 1，两条独立理由都会让 CPU 死在 `ST_RESET_0`：

1. `wait_cnt` 在非 `ce_cpu` 拍上照样递减，`ready` 于是出现在 `div_phase ∈ {1,3,5,7,9,11}` 这些 **CPU 不采样**的相位上，两边永不相遇。
2. 请求在非 `ce_cpu` 拍上是撤回的：状态机看到 `!cpu_req && active` 就把事务作废，下个 `ce` 重启、再作废，循环。

所以 v2 把两者接在同一个自由运行的 `clk` 上，只让 `ce` 区分"这一拍算不算 CPU 周期"。这也是 `system-v2` testbench 里"状态只在 `ce=1` 的沿推进"那条断言在守的东西。

#### `bus_hold` 与仲裁点：v2 就位但没拉

v2 里 `assign bus_hold = 1'b0`。`nes_cpu_bus` 内部的 DMA 分支（`else if (ce && bus_hold)`）已写好，但 v2 没有 DMA 主机去拉它，所以这条路径**没被验证**。它的意义是：v3 只需把 `bus_hold` 换成真信号，总线逻辑一行不改。

#### sprite 通路如何内接

v2 的 PPU 例化跟 v0/v1 一样（都是 `nes_ppu2c02`），区别在**PPU 内部**：精灵渲染器 `nes_ppu_sprite`（见 [`52-ppu-sprite.md`](52-ppu-sprite.md)）现在接在 PPU 通路上，和背景一起参与像素合成。顶层不为它单开端口，`nes_ppu2c02` 只把它引成 `pixel_index` 等像素输出，顶层把 `.chr_rd_arm(1'b0)` 悬成 0（这一版不做外部 CHR 预取仲裁）。效果由 `system-v2` testbench 首次验证：它往 OAM 写了一个在屏精灵，逐像素断言被检查帧里有 **64 个 `pixel_index == 6`**（精灵像素）。

### 3.2 v3：`nes_oam_dma` 与 DMA 仲裁点

`nes_oam_dma` 本身的状态机、513/514 拍相位、对齐见 [`24-oam-dma.md`](24-oam-dma.md)。v3 做的是**把它接成总线的第二个主机**。

#### DMA 通道与仲裁

`nes_cpu_bus` 在 v3 打开 `DMA_PRESENT=1'b1`，把 `dma_req_oam` / `dma_req_dmc` 接进来，并输出 `dma_sel` / `dma_ack` / `dma_din` / `dma_wait` / `dma_active` / `dma_owner`。仲裁规则是**纯组合**的：`dma_req_oam` 优先，`dma_req_dmc` 只在 OAM 没请求时成立。因此：

- `dma_sel` 的含义是"这一笔是 DMC 的"；
- `oam_dma_cpu_read_ack = dma_ack && !dma_sel` 与 `apu_dmc_ack = dma_ack && dma_sel` 是同一个 `dma_ack` 上的两个**互斥**译码项，任何一侧都不许把对方的 ack 当成自己的。

#### CPU 冻结信号 `bus_hold`

`assign bus_hold = oam_dma_cpu_hold || apu_dmc_bus_req;`。`oam_dma_cpu_hold` 就是 `nes_oam_dma` 的 `busy`。`bus_hold` 为高的那些 `ce` 拍，`nes_cpu_bus` 整拍让给 DMA 分支：CPU 的 `bus_fire` 恒 0、`dbg_state` / `dbg_pc` 冻结。这就是 v2 的"等待拍归属"语义延伸到 DMA 上——**等待谁由显式仲裁信号决定，而不是由地址译码决定**。

#### `$4014` 译码

`localparam [4:0] APU_REG_OAMDMA = 5'h14;` 配 `assign oam_dma_start = apu_xfer && apu_we && (apu_addr == APU_REG_OAMDMA);`。三个条件缺一不可：**完成脉冲**（`apu_xfer`，不是请求 `apu_req`）、**写方向**（`apu_we`）、**地址等于 `$4014`**。一次 `$4014` 写 = 一次 `oam_dma_start`。

#### `$2003` / `$2004` 端口同沿竞争

`nes_ppu2c02` 的寄存器口只有**一组** `reg_cs/reg_we/reg_addr/reg_din`，但 v3 有两个源要驱动它：CPU（`ppu_xfer`）和 OAM DMA（`oam_dma_ppu_reg_*`），顶层做的是 2.2 节那段**纯组合源选择**。为什么不会打架：`bus_hold = oam_dma_busy` 在 `nes_oam_dma` 离开 `ST_IDLE` 的同一拍拉高，所以 DMA 期间 `ppu_xfer` 恒为 0，两个源**物理上不可能同时有效**。testbench 不接受"靠时序恰好不冲突"，因此同时断言"`ppu_port_cs === (oam_dma_ppu_reg_cs || ppu_reg_cs)`"与"两者不得同时为高"。

`$2003` 还额外在顶层维护了一个影子寄存器 `oam_addr_q`（v3 不让 DMA 引擎驱动 `$2003`，`OAMADDR_WRITE=0`）：

```verilog
always @(posedge clk or posedge reset) begin
    if (reset) oam_addr_q <= 8'h00;
    else if (ppu_port_cs) begin
        if (ppu_port_we) begin
            if      (ppu_port_addr == 3'd3) oam_addr_q <= ppu_port_din;      // $2003 写
            else if (ppu_port_addr == 3'd4) oam_addr_q <= oam_addr_q + 8'd1; // $2004 写
        end else if (ppu_port_addr == 3'd4) oam_addr_q <= oam_addr_q + 8'd1; // $2004 读
    end
end
```

它和 PPU 自己的 `oam_addr_reg` 是两路**独立推进的同构逻辑**，testbench 逐拍断言两者相等；`oam_dma_base_addr = oam_addr_q` 就是喂给 DMA 引擎的起始 `OAMADDR`。

#### `$4014` 源页的同沿竞争（v3 的核心缺陷与修法）

`$4014` 的写数据就是 DMA 源页号。一开始 v3 把它锁存在顶层 `oam_dma_page_q`，但 `nes_oam_dma` 在 `ST_IDLE` 看到 `start` 的**同一个 `posedge clk`** 去采样 `src_page`，两个寄存器都只看到沿前的旧值：

```text
clk N-1 : $4014 写完成，apu_dout = $05
clk N   : 沿前 oam_dma_page_q = $02（上一笔的页）
          沿上 oam_dma_page_q <= $05
          沿上引擎 page_q     <= $02   <-- 拿到的是旧页
```

结果**每次 DMA 都用上一页搬运**，而所有"地址顺序 / ack 数量 / `$2004` 写入顺序"的断言都不会报错——地址是自洽的，只有页号错。修法不是延时，而是**旁路**：`nes_oam_dma` 只在 `start` 那一拍采样 `src_page`，而彼时"沿前的正确页号"恰好在 `apu_dout` 上，于是 `.src_page(oam_dma_start ? apu_dout : oam_dma_page)`。`oam_dma_page_q` 保留下来，作为"顶层记住的页"与"引擎锁到的页"必须一致的唯一观测量。

#### DMC DMA 端口

`apu_dmc_bus_req` 进了 `bus_hold` 与 `dma_req_dmc`，`dma_sel` 也会译码到 `apu_dmc_ack`（`= dma_ack && dma_sel`），`apu_dmc_rdata = dma_din`。但 v3 的 testbench 从不写 `$4010-$4013`，所以断言 `apu_dmc_bus_req` 与 `dma_sel` 全程为 0。**接线在、握手从未被激励**——这是"存在但未验证"的典型。

### 3.3 v4：接入 `nes_controller` 与总线 override

v4 **一个字都没改 `nes_cpu_bus`**：`$4000-$401F` 仍整体译码成 `OWNER_APU_IO`，全部工作在顶层的组合 override 上。

#### 三个新端口

| 端口 | 方向 | 宽度 | 含义 |
|---|---|---|---|
| `buttons1` | in | 8 | 1P 位图，bit0..7 = A, B, Select, Start, Up, Down, Left, Right |
| `buttons2` | in | 8 | 2P 位图，位序同上 |
| `controller_data` | out | 1 | 串行数据线，高 = 按下；直接驱动 CPU 读数据的 bit0 |

#### override 边界：读 `$4017` + 全部 `$4016`

重点是这一行：`wire apu_addr_ctrl_owned = apu_addr_ctrl1 || (apu_addr_ctrl2 && !apu_we);`。它把"属于 controller 的访问"定义成**按地址 + 方向**划的集合：

| 访问 | controller 做什么 | APU `reg_cs` |
|---|---|---|
| `$4016` 读 | port 1 移位，串行位进 `cpu_din[0]` | 0 |
| `$4016` 写 | 加载共享 `/PL`（`latch_strobe_q`） | 0 |
| `$4017` 读 | port 2 移位，串行位进 `cpu_din[0]` | 0 |
| **`$4017` 写** | **不参与** | **1**（进 APU 帧计数器） |
| `$4000-$4015` 其余 | 不参与 | 1 |

#### 写 `$4017` 为什么必须继续进 APU 帧计数器

真机上写 `$4017` 进的是**帧计数器**（4 步 / 5 步、允许 / 禁止 frame IRQ），读 `$4017` 出来的是帧计数器状态 + 手柄 bit0——本来就是两样完全不同的东西。曾经的错误版本把 `$4016/$4017` **整段地址**在两个方向上一起 gate 掉，于是任何用 `STA $4017` 配置帧计数器的程序都会**静默丢失**这条配置。现在的边界把 `!apu_we` 留在 `apu_addr_ctrl_owned` 里，`$4017` 写就照常走 `apu_port_cs` 进 APU。

`!apu_we` 还有第二个作用：**保护读数据 mux**。`cpu_din` 的覆盖条件是 `apu_ctrl_xfer`；若 `$4017` 写也算成 controller 的传输，写周期上 `cpu_din` 会被换成串行位，紧接着那次取指就会读到垃圾操作码、程序跑飞。

#### 四条线 + 一个 mux

| 线 | 表达式 | 极性 / 为什么 |
|---|---|---|
| `/PL` 电平 | `apu_xfer && apu_we && apu_addr == $4016` | 必须是**完成沿**；用请求级信号会让 stalled 的写改两次电平 |
| 读选通 | `apu_ctrl_read = apu_ctrl_xfer && !apu_we`，地址 ∈ `{$4016,$4017}` | **只认完成沿**；一次读只移一位 |
| 端口选择 | `apu_addr_ctrl2` | `$4016` → 0（port 1），`$4017` → 1（port 2） |
| 数据回注 | `cpu_din = apu_ctrl_xfer ? {7'b0, controller_data} : bus_cpu_din` | 在**同一拍**把总线读数据换成那个串行位 |

另外 `nes_controller` 例化里送进去的 APU `reg_cs` 也必须是 gate 过的 `apu_port_cs`，否则"端口说没有访问"而 APU 内部副作用照旧发生——那是一种断言看不见的缺陷。v4 用"层次观察 `dut.u_apu.reg_wr_frame` 恰好被拉高 1 拍"把这条盯住。

#### 一拍延迟：`/PL` 与 4021

`latch_strobe_q` 在 `$4016` 写完成的沿更新，`nes_controller` 在**下一个**时钟沿才装载。这正是真实 4021 的时序：`/PL` 变化后，第一个有效时钟才把并行输入搬进移位寄存器。testbench 在第二次 `/PL` 前后各取一次快照（`cnt=9 sr=$FF latch=$A5` → `cnt=0 sr=$A5`）来断言这一拍。

---

## 4. 端口表（标注版本）

三个顶层的端口是**累加**的：v3 保留 v2 全部端口，v4 保留 v3 全部端口、只新增 3 个。

| 端口（组） | 方向 | 版本 | 作用 |
|---|---|---|---|
| `clk` / `reset` / `cpu_cycle` / `ppu_dot` / `ppu_scanline` | in/out | v0/v1 | 时钟、复位、状态观测 |
| `pixel_valid` / `pixel_x` / `pixel_y` / `pixel_index` / `frame_done` / `vblank` / `nmi_o` | out | v0/v1 | PPU 像素流 / 帧边界 / vblank / NMI |
| `apu_irq_o` / `audio_sample_valid` / `audio_sample_left` / `audio_sample_right` | out | v1 | APU frame IRQ / 采样输出 |
| `bus_owner` / `bus_active` / `bus_wait_count` / `bus_req` / `bus_stall` / `bus_fire` | out | **v2** | 事务归属 / 等待 / 请求 / 停顿 / 完成 |
| `bus_addr` / `bus_we` / `bus_dout` / `bus_din` / `ram_we` | out | **v2** | 总线地址·方向·写·读 + RAM 写脉冲 |
| `sel_ram` / `sel_ppu` / `sel_apu_io` / `sel_open_bus` / `sel_cart_ram` / `sel_cart_rom` | out | **v2** | 六个 owner 独热译码 |
| `ppu_reg_cs` / `_we` / `_addr` / `apu_reg_cs` / `_we` / `_addr` | out | **v2** | PPU / APU 寄存器口（只认完成脉冲） |
| `cart_req` / `cart_xfer` / `cart_addr` / `cart_din` / `cart_ack` | out | **v2** | 卡带 owner 请求 / 完成 / 地址 / 数据 / 应答 |
| `bus_hold` / `oam_dma_start` | out | **v3** | CPU 冻结 / `$4014` 写完成脉冲 |
| `oam_dma_cpu_hold` / `_busy` / `_done` / `_align_left` / `_addr_wr` / `_cycle_count` | out | **v3** | 引擎忙 / 完成 / 对齐 / 是否驱动 `$2003`（恒 0）/ 计数 |
| `oam_dma_cpu_read_req` / `_addr` / `_ack` / `_rdata` | out | **v3** | OAM DMA 作为主机的握手 |
| `oam_dma_ppu_reg_cs` / `_we` / `_addr` / `_dout` | out | **v3** | OAM DMA 对 PPU 寄存器口的驱动 |
| `oam_dma_page` / `_page_latch` / `_base_addr` / `_cur_addr` / `_index` | out | **v3** | 源页 / 引擎锁存页 / `OAMADDR` / 游标 / 下标 |
| `apu_dmc_bus_req` / `_addr` / `_ack` / `_rdata` | out | **v3** | DMC DMA 握手（接线在，未激励） |
| `dma_sel` / `_ack` / `_din` / `_wait` / `_active` / `_unimpl` / `_owner` | out | **v3** | `nes_cpu_bus` DMA 通道观测 |
| `ppu_port_cs` / `_we` / `_addr` / `_din` | out | **v3** | 源选择后真正接 PPU 的那组口 |
| `buttons1` / `buttons2` / `controller_data` | in/out | **v4** | 1P / 2P 位图 + 串行数据线 |

---

## 5. 代入具体走两遍

### 5.1 一次 `$4016` 读（v4）

游戏侧先写 `$4016` 两次（`/PL` 拉高再拉低），再连读 8 次。看第一次真实读 `LDA $4016`：

1. **CPU**：`nes_cpu6502` 以 `cpu_req=1`、`cpu_we=0`、`cpu_addr=$4016` 提出请求。
2. **总线译码**：`nes_cpu_bus` 把 `$4000-$401F` 译成 `OWNER_APU_IO`，`sel_apu_io=1`，`apu_xfer` 在完成拍拉高（零等待，与请求同一 `ce_cpu`）。
3. **override 判定**：`apu_addr_ctrl1=1`、`apu_we=0` → `apu_addr_ctrl_owned=1`、`apu_ctrl_xfer=1`、`apu_ctrl_read=1`、`apu_port_cs=0`。
4. **手柄移位**：`read_strobe=apu_ctrl_read=1`、`read_select=0`（port 1）。`nes_controller` 在这个沿把 `sr1_q` 右移一位、`cnt1_q + 1`；移出前 `sel_sr[0]` 就是要读的那一位。
5. **读数据回注**：`cpu_din = apu_ctrl_xfer ? {7'b0, controller_data} : bus_cpu_din` 选中 controller 支——`bus_din[0]=controller_data`（移位**之前**的那一位），高 7 位恒 0。
6. **CPU 取数**：同一沿 CPU 用沿前的 `bus_din` 更新寄存器，`A` 拿到这一位，随后 `STA $0020,X` 存走。

`$4017` 的读只差 `apu_addr_ctrl2=1`：`read_select=1`，轮到 `sr2_q`。写 `$4016` 则走 `apu_we=1` 分支，只更新 `latch_strobe_q`（`/PL`），不做读数据替换。

### 5.2 一次 `$4014` 写（v3）

CPU 执行 `LDA #$02` / `STA $4014`，把 `$0200` 页搬进 OAM：

1. **CPU**：`cpu_we=1`、`cpu_addr=$4014`、`cpu_dout=$02`。
2. **总线译码**：仍是 `OWNER_APU_IO`；完成拍 `apu_xfer=1`、`apu_we=1`、`apu_addr=5'h14` → `oam_dma_start=1`。
3. **源页锁存（同沿竞争处）**：`nes_oam_dma` 在 `ST_IDLE` 看到 `start`，用 `.src_page(oam_dma_start ? apu_dout : oam_dma_page)` 采到**本拍**的 `apu_dout=$02`（不是顶层旧页），置 `page_q=$02`、`read_addr_q=$0200`，同时离开 `ST_IDLE`。
4. **`bus_hold` 拉高**：引擎 `busy` → `oam_dma_cpu_hold` → `bus_hold=1`，CPU 被冻结，`nes_cpu_bus` 整拍走 DMA 分支。
5. **256 次读**：引擎逐字节提 `oam_dma_cpu_read_req=1`、`oam_dma_cpu_read_addr={page, index}`；总线回 `dma_ack`，`oam_dma_cpu_read_ack = dma_ack && !dma_sel`（`dma_sel=0`，是 OAM 的），`oam_dma_cpu_rdata = dma_din`。引擎拿到字节后经 `oam_dma_ppu_reg_*` 写 `$2004`，顶层 `ppu_port_*` mux 导向 PPU，写 `$2004` 顺带让 `OAMADDR` 加一。
6. **结束**：最后一个字节写完，`oam_dma_done` 拉一拍，`busy` 与 `bus_hold` 落回 0，CPU 从原来那一拍继续。

---

## 6. 常见疑问

**Q：`nes_cpu_bus` 的 `ce` 接常电 1，为什么是"确定性死锁"而不是"偶尔慢一拍"？**
A：因为 `nes_cpu6502` 的 `cpu_req` 只在 `ce_cpu` 那一拍有效。常电 `ce` 下，`ready` 只出现在 CPU 不采样的相位，或事务被"请求撤回"分支反复作废——两者都是每拍必然发生，不是概率事件。

**Q：v2 的 `bus_hold` 恒 0，那还要它干嘛？**
A：仲裁点（`nes_cpu_bus` 的 DMA 分支）已就位，v2 只是没去拉。v3 把 `bus_hold` 换成真信号后，总线逻辑一行不改就多出一个主机。这是"接线点先留好"的价值。

**Q：为什么 `read_strobe` / `/PL` 都用完成脉冲，不用请求级信号？**
A：`nes_cpu_bus` 的请求级信号在整个等待期保持有效，完成脉冲只在完成那一拍为高。用请求级信号会让一次 stalled 的访问做多次副作用（`/PL` 改多次、一次读移多位）。v2 把 PPU/APU 的 `reg_cs` 从请求级换成 `ppu_xfer`/`apu_xfer`，是同一个道理。

**Q：v3 的 `$4014` 源页缺陷为什么"顺序断言抓不到"？**
A：因为它只错**页号**，不错**顺序**：地址确实 `{page, index}` 自洽递增、ack 数正好 256、`$2004` 写入顺序也对。只有把"顶层记住的页"和"引擎锁到的页"引出来逐拍比对（`oam_dma_page` vs `oam_dma_page_latch`），才能一眼抓住。

**Q：v4 的 `$4017` 写为什么不能跟读一起交给 controller？**
A：`$4017` 写进的是 APU 帧计数器配置，读出来的才是手柄位。一起 gate 会让帧计数器配置静默丢失，而且写周期上 `cpu_din` 会被换成串行位，导致紧随的取指读到垃圾操作码。

---

## 7. 你应该带走的三件事

1. **中间三代是"骨架 + 逐版加一块零件"**：v2 把 RAM/译码/等待态挪进 `nes_cpu_bus`（`ce` 必须接 `ce_cpu`，`bus_ready` 是"这拍就绪"不是"再等一拍"），v3 加 `nes_oam_dma` 与显式 DMA 仲裁点，v4 加 `nes_controller` 与一次读数据 override。
2. **总线上的"同沿竞争"要先找出唯一真值**：`$4014` 源页、`$2003/$2004` 端口、`$4000-$401F` 的 owner 都落在同一时钟沿的多个写入上；解法分别是旁路 `apu_dout`、组合 mux（靠 `bus_hold` 保证互斥）、按地址+方向精确划 override 集合。
3. **接线点先留好、边界要写死**：`bus_hold`（v2 恒 0、v3 接真）、`!apu_we`（保护读数据 mux 与帧计数器写）都是"一行之差决定成败"的地方；每一版都用 testbench 的逐拍断言把边界钉住，而不是靠注释。

下一篇 [`62-system-mapper.md`](62-system-mapper.md) 看 v5 / v6：系统里第一次出现 `nes_mapper`、PRG/CHR banking 与外部 CHR 总线。
