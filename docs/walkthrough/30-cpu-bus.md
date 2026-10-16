# 30 中等规模精读：`nes_cpu_bus.v` 地址译码与等待态

这是"中等规模"的第一篇。它回答一个很朴素的问题：

> **CPU 把一个地址丢到总线上，数据到底从哪个部件来？如果那个部件慢，CPU 要等几拍？**

`nes_cpu_bus` 就是**总线**：一边连着 6502（CPU），另一边连着四种零件（片上 RAM、PPU、APU/IO、卡带），外加第二个主设备 **DMA 引擎**。它替 CPU 做两件事：**译码**（地址归谁）和**等待**（等几拍取数）。

- 源码：[`rtl/nes_core/bus/nes_cpu_bus.v`](../../rtl/nes_core/bus/nes_cpu_bus.v)
- 合同与证据：[`../modules/cpu-bus.md`](../modules/cpu-bus.md)
- 测试目标：`bus-tb`（见 [`tb/bus/tb_nes_cpu_bus.v`](../../tb/bus/tb_nes_cpu_bus.v)）

前置：先读过 [`01-verilog-basics.md`](01-verilog-basics.md) 和 [`02-project-conventions.md`](02-project-conventions.md)。

---

## 1. 先认识"上游和下游"

```text
                     ┌── ram_array（片上 2 KiB RAM）        $0000-$1FFF
                     │
nes_cpu6502 ─req/we─►├── ppu_req/we/addr/dout ─► nes_ppu2c02  $2000-$3FFF
  addr/dout  [nes_cpu_bus] ─ apu_req/we/addr/dout ─► nes_apu2a03 $4000-$4017
        ◄─din/ready─┘├── cart_req/we/addr/dout ► nes_mapper   $6000-$FFFF
                     │
DMA 引擎(OAM/DMC) ─req/addr─►┘──► dma_ack / dma_din
```

- **CPU 侧**：CPU 说"我要读/写某地址"，总线回"数据在这，且这拍就绪"（`cpu_din` / `cpu_ready`）。
- **owner 侧**：PPU/APU/卡带各有请求线（`X_req`）、完成脉冲（`X_xfer`）、应答（`X_ack`）。总线只翻译地址和方向，不碰它们的寄存器语义。
- **DMA 侧**：第二个只读主设备，拉高请求线后总线回 `dma_din` 和 `dma_ack`。

**它不做的事**：不含 OAM/DMC 状态机（在 `nes_oam_dma.v`），不含 PPU/APU 寄存器含义，不含 mapper bank 切换。只做**桥接 + 仲裁**。

---

## 2. 全文（357 行，此处分段摘关键块）

### 2.1 参数（第 3-11 行）

```verilog
module nes_cpu_bus #(
    parameter [7:0] READ_WAIT_CYCLES = 8'd0,     // 外部 owner 最小等待拍数
    parameter integer RAM_ADDR_BITS = 11,        // 11 位 = 2 KiB
    parameter RAM_READ_SYNC = 1'b0,              // 0=组合读 1=同步读
    parameter [7:0] RAM_INIT = 8'h00,
    parameter DMA_PRESENT = 1'b0,                // DMA 端口存在性开关
    parameter [7:0] DMA_MMIO_VALUE = 8'h00,      // DMA 读 PPU/APU 的占位值
    parameter [7:0] DMC_READ_WAIT_CYCLES = 8'd3  // DMC 取数专用等待拍数
)( /* ... 端口见第 4 节 ... */ );
```

### 2.2 常量与译码函数（第 81-103 行）

```verilog
localparam [2:0] OWNER_OPEN=3'd0, OWNER_RAM=3'd1, OWNER_PPU=3'd2;
localparam [2:0] OWNER_APU_IO=3'd3, OWNER_CART_RAM=3'd4, OWNER_CART_ROM=3'd5;
localparam [1:0] DMA_OWNER_OAM=2'd0, DMA_OWNER_DMC=2'd1, DMA_OWNER_IDLE=2'd2;

function [2:0] decode_owner;
    input [15:0] addr;
    begin
        case (addr[15:13])
            3'b000:  decode_owner = OWNER_RAM;
            3'b001:  decode_owner = OWNER_PPU;
            3'b010:  decode_owner = (addr[15:5] == 11'b01000000000) ? OWNER_APU_IO : OWNER_OPEN;
            3'b011:  decode_owner = OWNER_CART_RAM;
            default: decode_owner = OWNER_CART_ROM;
        endcase
    end
endfunction
```

### 2.3 owner 译码与 CPU 读通路（第 105-136、227-301 行摘录）

```verilog
reg [7:0] ram_array [0:(1<<RAM_ADDR_BITS)-1];   // 片上 RAM
reg [7:0] ram_q;                                // 同步读寄存器
reg [7:0] open_bus_q;                           // 开放总线锁存
reg active; reg [7:0] wait_cnt;                 // CPU 等待状态

always @*  owner_r = decode_owner(cpu_addr);    // 纯组合译码
assign owner        = owner_r;
assign sel_ram      = (owner_r == OWNER_RAM);
assign sel_ppu      = (owner_r == OWNER_PPU);
assign sel_apu_io   = (owner_r == OWNER_APU_IO);
assign sel_open_bus = (owner_r == OWNER_OPEN);
assign sel_cart_ram = (owner_r == OWNER_CART_RAM);
assign sel_cart_rom = (owner_r == OWNER_CART_ROM);
assign ram_addr     = cpu_addr[RAM_ADDR_BITS-1:0];   // 折叠线
assign cart_ram_cs  = sel_cart_ram;

assign wait_need = (owner_r == OWNER_OPEN) ? 8'd0 :
                   (owner_r == OWNER_RAM)  ? (RAM_READ_SYNC ? 8'd1 : 8'd0) :
                   READ_WAIT_CYCLES;
assign ram_data  = RAM_READ_SYNC ? ram_q : ram_array[ram_addr];

always @* begin                                  // CPU 读数据 mux
    case (owner_r)
        OWNER_RAM: bus_data_r = ram_data;
        OWNER_PPU: bus_data_r = ppu_din;
        OWNER_APU_IO: bus_data_r = apu_din;
        OWNER_CART_RAM, OWNER_CART_ROM: bus_data_r = cart_din;
        default: bus_data_r = open_bus_q;
    endcase
end
assign cpu_din = bus_data_r;

assign ready_c  = !bus_hold &&
                  ((active ? (wait_cnt == 8'd0) : (wait_need <= 8'd1)) &&
                   (!owner_ext || owner_ack));
assign cpu_ready = ready_c;
assign cpu_fire  = cpu_req && ready_c;
assign cpu_stall = cpu_req && !cpu_fire;
assign ram_we    = ce && cpu_fire && cpu_we && (owner_r == OWNER_RAM);
```

### 2.4 DMA 端口：仲裁与等待（第 152-207 行摘录）

```verilog
assign dma_owner    = decode_owner(dma_addr);          // 同一张译码表
assign dma_ram_data = RAM_READ_SYNC ? dma_ram_q : ram_array[dma_ram_addr];
assign dma_req_present = DMA_PRESENT && !reset && (dma_req_oam || dma_req_dmc);
assign dma_pick_oam = dma_req_oam;
assign dma_pick_dmc = !dma_req_oam && dma_req_dmc;     // OAM 优先于 DMC
assign dma_grant    = DMA_PRESENT && !reset && ce && bus_hold &&
                      (dma_pick_oam || dma_pick_dmc);
assign dma_sel      = dma_pick_dmc;
assign dma_wait_need = dma_pick_dmc ? DMC_READ_WAIT_CYCLES :
                       (dma_owner == OWNER_OPEN) ? 8'd0 :
                       (dma_owner == OWNER_RAM)  ? (RAM_READ_SYNC ? 8'd1 : 8'd0) :
                       dma_ext ? READ_WAIT_CYCLES : 8'd0;
assign dma_ready = dma_grant &&
                   (dma_active_r ? (dma_wait_cnt == 8'd0) : (dma_wait_need == 8'd0)) &&
                   (!dma_ext || dma_ack_src);
assign dma_ack    = dma_grant && dma_ready;
assign dma_unimpl = dma_grant && ((dma_owner == OWNER_PPU) || (dma_owner == OWNER_APU_IO));

always @* begin                                        // DMA 读数据 mux
    case (dma_owner)
        OWNER_RAM: dma_din_r = dma_ram_data;
        OWNER_CART_RAM, OWNER_CART_ROM: dma_din_r = cart_din;
        OWNER_PPU, OWNER_APU_IO: dma_din_r = DMA_MMIO_VALUE;   // 占位值
        default: dma_din_r = open_bus_q;
    endcase
end
```

### 2.5 大时序块：副作用只发生一次（第 303-348 行摘录）

```verilog
always @(posedge clk or posedge reset) begin
    if (reset) begin
        active <= 1'b0; wait_cnt <= 8'd0; open_bus_q <= 8'h00;
        dma_active_r <= 1'b0; dma_wait_cnt <= 8'd0; dma_ram_q <= RAM_INIT;
    end else if (ce && !bus_hold) begin        // ← CPU 分支：hold 时冻结
        if (cpu_fire) begin                    //   完成拍：仅此一次副作用
            active <= 1'b0; wait_cnt <= 8'd0;
            if (cpu_we) begin
                if (owner_r == OWNER_RAM) ram_array[ram_addr] <= cpu_dout;
                open_bus_q <= cpu_dout;
            end else open_bus_q <= bus_data_r;
        end else if (cpu_req && !active) begin  //   新请求：装倒计时
            active <= 1'b1;
            wait_cnt <= (wait_need <= 8'd1) ? 8'd0 : (wait_need - 8'd1);
        end else if (!cpu_req && active) begin  //   撤回：作废
            active <= 1'b0; wait_cnt <= 8'd0;
        end else if (wait_cnt != 8'd0) wait_cnt <= wait_cnt - 8'd1;
    end else if (ce) begin                     // ← DMA 分支：hold 期间才走
        if (dma_grant && dma_ack) begin
            dma_active_r <= 1'b0; dma_wait_cnt <= 8'd0; open_bus_q <= dma_din_r;
        end else if (!dma_grant) begin
            dma_active_r <= 1'b0; dma_wait_cnt <= 8'd0;
        end else if (!dma_active_r) begin
            dma_active_r <= 1'b1;
            dma_wait_cnt <= (dma_wait_need == 8'd0) ? 8'd0 : (dma_wait_need - 8'd1);
        end else if (dma_wait_cnt != 8'd0) dma_wait_cnt <= dma_wait_cnt - 8'd1;
    end
end
```

---

## 3. 逐段精读

### 3.1 参数：等待拍数与 RAM 形态

| 参数 | 默认 | 白话 |
|---|---|---|
| `READ_WAIT_CYCLES` | 0 | 外部 owner 的**最小**等待拍数 |
| `RAM_ADDR_BITS` | 11 | 片上 RAM 地址位宽；11 位 = 2 KiB |
| `RAM_READ_SYNC` | 0 | 0=组合读（0 等待）；1=同步读（读寄存器 `ram_q`） |
| `RAM_INIT` | 0 | 上电时 `ram_array` 填什么 |
| `DMA_PRESENT` | 0 | 有无 DMA 读端口；0 时整块 DMA 逻辑被常量旁路 |
| `DMA_MMIO_VALUE` | 0 | DMA 读 PPU/APU 时返回的占位值 |
| `DMC_READ_WAIT_CYCLES` | 3 | DMC 采样取数专用等待拍数 |

`DMA_PRESENT` 默认 0 是兼容技巧：老顶层不接三个 DMA 输入也能编译，行为跟加端口前逐位相同。下同。

### 3.2 `decode_owner`：一张表回答"归谁"

真正的译码只有这一个函数，看 `addr[15:13]` 分档：

| `addr[15:13]` | 地址范围 | owner | 折叠方式 |
|---|---|---|---|
| `000` | `$0000-$1FFF` | RAM | `addr[10:0]`（四路镜像到 2 KiB） |
| `001` | `$2000-$3FFF` | PPU | `addr[2:0]`（8 个寄存器镜像） |
| `010` 且 `addr[15:5]==512` | `$4000-$401F` | APU_IO | `addr[4:0]` |
| `010` 其余 | `$4020-$5FFF` | OPEN | 不折叠，返回 open bus |
| `011` | `$6000-$7FFF` | CART_RAM | 不折叠 |
| `100`~`111` | `$8000-$FFFF` | CART_ROM | 不折叠 |

关键点：

- **RAM 四路镜像**是硬件的：`$0000/$0800/$1000/$1800` 是同一格。`addr[10:0]` 直接丢高位，不需要比较、加法或取模。
- **`$4000-$401F` 用 `addr[15:5]==11'b01000000000`（512 = `$4000>>5`）判定**，同时排除 `$4020` 以上。
- **`$6000+`/`$8000+` 不折叠**：窗口大小和 bank 交给 mapper，总线只告诉它"这是卡带窗口"。
- **DMA 复用同一函数**：`decode_owner(dma_addr)` 再调一次，两边折叠规则不可能漂移。但 `owner`/`sel_*` 输出**只反映 `cpu_addr`**，不含 DMA 译码。

### 3.3 owner 译码是纯组合、与请求无关

`owner_r` 由 `cpu_addr` 组合算出，**只由地址决定，跟 `cpu_req` 无关**。这样"译码错"和"请求错"能分开定位，也和 `nes_system_v0` 现有的 `sel_*` 观测量一致。`ram_addr = cpu_addr[RAM_ADDR_BITS-1:0]` 就是那根折叠线。

### 3.4 片上 RAM：组合读 vs 同步读

`RAM_READ_SYNC=0` 直接组合读 `ram_array`（LUTRAM，0 等待）；`=1` 读寄存器 `ram_q`，它提前一拍装载：

```verilog
always @(posedge clk or posedge reset) begin
    if (reset)              ram_q <= RAM_INIT;
    else if (RAM_READ_SYNC) ram_q <= ram_array[ram_addr];
end
```

**这个读端口"自由运行"**：不挂 `ce`，每个 `clk` 都发地址。因为 `cpu_addr` 来自 CPU 状态寄存器，只在 `bus_fire` 时前进，整个访问窗口内地址是稳的，提前一拍装载正好拿到要的字节——**这一拍是"白拿的引线"，不是额外 CPU 周期**。DMA 侧的 `dma_ram_q` 不同，只在 `ce` 上装载（DMA 地址没有这个提前量）。

### 3.5 DMA 端口：仲裁 + 按来源算等待

**(a) 仲裁：OAM 优先于 DMC。**

```verilog
assign dma_pick_oam = dma_req_oam;
assign dma_pick_dmc = !dma_req_oam && dma_req_dmc;   // 同拍都高时 OAM 赢
```

真机上 OAM DMA 是 513/514 周期的**整块**偷取，DMC 只是 1/2 周期采样，必须等 OAM 让出总线。优先级做进模块内部，`bus-tb` 才能从外面断言它。

**(b) `dma_grant` 四个门**：`DMA_PRESENT`（存在性）、`!reset`（复位期间惰性）、`ce`（同一条使能）、`bus_hold`（**互斥点**——DMA 引擎就是拉高 hold 的一方，"请求提出 + hold 已高"等于"CPU 已让出总线"）。

**(c) `dma_wait_need` 按请求来源、不是按地址算**：

- **DMC 取数单独用 `DMC_READ_WAIT_CYCLES=3`**：真机每个 DMC 字节占 4 个 CPU 周期（1 让出 + 3 取数）。把这个数与 CPU 路径解耦，避免两个合同耦合。
- **DMA 侧零等待阈值是 `== 0`，不是 CPU 的 `<= 1`**：因为 `dma_addr` 与请求线在**同一个 `clk`** 才有效，`dma_grant` 可能就在地址刚出现那一拍。这里 1 拍是"读操作本身的引线"，不是被浪费的周期。若写成 `<=1` 会读到上一格数据——`bus-tb` 的 "dma ram data on the forced wait config" 专抓这个。

**(d) `DMA_MMIO_VALUE` / `dma_unimpl`**：真机 DMA 从 `$2000-$3FFF` 取数会打断渲染、从 `$4014-$4017` 取数会返回当时 APU 状态，都需要 PPU/APU 侧"被 DMA 读"的专用通路，无法用"地址 + 等待拍数"表达。所以**显式不实现**：返回稳定占位值、0 等待、不拉 `ppu_req`/`apu_req`、置 `dma_unimpl=1`。软件**不得**用 `$2000-$5FFF` 作 OAM DMA 源页。

### 3.6 `cpu_ready`：本模块最易错的一处

```verilog
assign ready_c = !bus_hold &&
                 ((active ? (wait_cnt == 8'd0) : (wait_need <= 8'd1)) &&
                  (!owner_ext || owner_ack));
```

两个"哪张脸"：事务**还没开始**（`!active`）看 `wait_need`；**已经在等**（`active`）看本次剩余的 `wait_cnt`。而没开始时判据是 **`wait_need <= 8'd1`**，不是 `== 0`。关键在"`ce` 是什么"：

> **`ce` 就是 CPU 周期本身。** `nes_system_v2` 及以后 `div_phase` 是 12 相计数器，`ce_cpu=(div_phase==0)`，**一拍 `ce` 占 12 个 `clk`、正好一个 CPU 周期**。所以"等 1 拍 `ce`"和"等 1 个 CPU 周期"是同一个东西，`wait_need <= 1` 就相当于**零等待**，不额外花周期。

于是 `wait_need<=1`（0 或 1）⇒ 请求提出第一拍就完成，`active` 一直是 0；`wait_need>=2`（如 `READ_WAIT_CYCLES=3`）才真正走 `active`/`wait_cnt` 倒计时。

**为什么 1 拍是免费的？** CPU 把地址摆上总线到完成沿之间还有 11 个 `clk`（`div_phase` 1..11），片内读端口自由运行、提前一拍装载正好对上。**这段推理不能搬到 DMA 端口**（见 3.5c），所以 DMA 侧阈值留在 `== 0`。

历史坑：2026-10-03 前写成 `wait_need == 0` 才零等待，于是 `READ_WAIT_CYCLES=1` 让每次访问多花一个 `ce_cpu`，CPU 只跑到真实速率一半，音乐和逻辑差 2 倍。`bus-tb` 的 `check_zero_stall` 就是防这个回归。

### 3.7 大时序块：副作用只发生一次 + hold 冻结

CPU 与 DMA 两套状态机写在**同一个 `always` 块**里，靠 `bus_hold` 互斥：

```text
if (reset)                 ...清零（不清 RAM 内容）
else if (ce && !bus_hold)  ...CPU 分支
else if (ce)               ...DMA 分支（此时 bus_hold 必为高）
```

写在一起是因为 `open_bus_q` 被两条路径共用，分开写就是**多驱动**。CPU 分支四种走向对应合同 4.2，要点：

- **副作用只发生一次**：RAM 写、`open_bus_q` 更新都只在 `cpu_fire`（完成拍）那一个沿执行。
- **撤回即作废**：`!cpu_req && active` 时清状态，不写 RAM、不动 open bus——违反"请求方保持稳定"义务时，模块选择**放弃**而不是**猜测**。
- **`bus_hold` 是冻结不是清零**：`ce && !bus_hold` 不成立时整个 CPU 分支不执行，`active`/`wait_cnt`/`ram_q`/`open_bus_q` 停在原值，DMA 结束后继续原访问。
- **DMA 侧撤销 hold 是作废**（不是冻结）：DMA 引擎是 hold 驱动方，撤销就等于宣布"不做了"。

### 3.8 open bus 跟踪

`open_bus_q` 记录**上一次完成传输放到数据总线上的字节**：CPU 写记 `cpu_dout`，CPU 读记 `bus_data_r`，DMA 读记 `dma_din_r`。读 `$4020+` 时 `bus_data_r` 取的就是它。这是对硬件"数据线残留什么"的近似，和 cNES 的 `g_bus_val`、Obara 的 `mem->bus` 逐位同构。

---

## 4. 端口表

| 端口 | 方向 | 宽度 | 作用 |
|---|---|---|---|
| `clk` / `reset` | in | 1 | `reset` 异步高有效；清等待状态/open bus，**不清 RAM** |
| `ce` | in | 1 | CPU 周期使能（= 一个 CPU 周期） |
| `bus_hold` | in | 1 | 冻结本模块并释放对外请求（DMA 让出点） |
| `cpu_req` / `cpu_we` | in | 1 | 请求有效 / 1=写 0=读 |
| `cpu_addr` / `cpu_dout` | in | 16 / 8 | 完整地址 / 写数据 |
| `cpu_din` | out | 8 | 读数据，**只在 `cpu_ready` 高的那拍有效** |
| `cpu_ready` | out | 1 | 传输将在下一时钟沿完成（纯组合，不依赖 `cpu_req`） |
| `cpu_fire` / `cpu_stall` | out | 1 | 完成脉冲 / `cpu_req && !cpu_fire`（观测） |
| `dma_req_oam` / `dma_req_dmc` | in | 1 | 两条 DMA 请求线（保持到 ack） |
| `dma_addr` | in | 16 | 被授予引擎的地址，等待期保持稳定 |
| `dma_sel` | out | 1 | 0=OAM 拿到端口，1=DMC 拿到 |
| `dma_din` | out | 8 | 读数据，**只在 `dma_ack` 高的那拍有效** |
| `dma_ack` / `dma_wait` | out | 1 | 传输将在下沿完成 / 已受理未完成（观测） |
| `dma_active` / `dma_unimpl` | out | 1 | 正在服务一笔 / DMA 读落 PPU/APU 返回占位值 |
| `sel_ram/ppu/apu_io/open_bus/cart_ram/cart_rom` | out | 1 各 | 六个区域独热译码，只由 `cpu_addr` 决定 |
| `owner` | out | 3 | 0=OPEN 1=RAM 2=PPU 3=APU_IO 4=CART_RAM 5=CART_ROM |
| `ram_addr` / `ram_we` | out | `RAM_ADDR_BITS` / 1 | 折叠后的 RAM 地址 / RAM 写脉冲（对齐完成沿） |
| `ppu_req/we/xfer/wr` + `ppu_addr/ppu_dout/ppu_din/ppu_ack` | out/out/in | 1 各 + 3/8/8/1 | PPU 请求级+完成脉冲、折叠索引 `cpu_addr[2:0]`、写 / 读 / 应答 |
| `apu_req/we/xfer/wr` + `apu_addr/apu_dout/apu_din/apu_ack` | out/out/in | 1 各 + 5/8/8/1 | APU 请求级+完成脉冲、折叠索引 `cpu_addr[4:0]`、写 / 读 / 应答 |
| `cart_req/we/xfer/wr` + `cart_addr/cart_dout/cart_din/cart_ack` | out/out/in | 1 各 + 16/8/8/1 | 卡带请求级+完成脉冲、完整地址（DMA 授予时改 `dma_addr`）、写 / 读 / 应答 |
| `cart_ram_cs` | out | 1 | 当前在 `$6000-$7FFF` PRG-RAM 窗口 |
| `dbg_active` / `dbg_wait_count` / `dbg_open_bus` | out | 1 / 8 / 8 | CPU 事务在等 / CPU 剩余强制等待拍数 / 上一次完成传输的字节 |
| `dbg_dma_owner` / `dbg_dma_wait_count` | out | 2 / 8 | 0=OAM 1=DMC 2=IDLE / DMA 剩余等待拍数 |

`X_req/X_we` 是**级信号**（整个等待期保持），`X_xfer/X_wr` 是**完成脉冲**（只一拍）——这就是"函数调用一次"与"请求持续多拍"的区别（合同 2.2）。

---

## 5. 代入一组地址走一遍译码

设 `RAM_ADDR_BITS=11`、`RAM_READ_SYNC=1`、`READ_WAIT_CYCLES=1`（`v2..v6` 的实际接法）：

| 地址 | `addr[15:13]` | owner | 折叠结果 | 等待 |
|---|---|---|---|---|
| `$0001` | `000` | RAM | `ram_addr=$001` | `wait_need=1` ⇒ `<=1` 零等待 |
| `$2001` | `001` | PPU | `ppu_addr=$01` | `READ_WAIT_CYCLES=1` ⇒ 零等待 |
| `$4014` | `010`，`addr[15:5]=512` | APU_IO | `apu_addr=$14` | 1 ⇒ 零等待 |
| `$4016` | `010`，`addr[15:5]=512` | APU_IO | `apu_addr=$16` | 1 ⇒ 零等待 |
| `$4020` | `010`，`addr[15:5]=513` | OPEN | 无 | `wait_need=0` ⇒ 零等待 |
| `$6000` | `011` | CART_RAM | 不折叠，`cart_ram_cs=1` | 1 ⇒ 零等待 |
| `$8000` | `100`（default） | CART_ROM | 不折叠 | 1 ⇒ 零等待 |

- **`$0001`**：`owner=RAM`，读 `ram_array[1]`；`$0801/$1001/$1801` 折叠到同一个 `ram_addr`——四路镜像。
- **`$2001`**：`owner=PPU`，`ppu_addr=1`（PPUCTRL），总线拉 `ppu_req`，等 `ppu_ack`；`$3FF9` 也折叠到 `ppu_addr=1`。
- **`$4014`**：在 `$4000-$401F`，故 `APU_IO`/`apu_addr=$14`。它其实是 OAM DMA 触发寄存器，真正触发 DMA 的是系统层看到 `$4014` 写。**`$4016`**：`APU_IO`/`apu_addr=$16`（手柄 1）。
- **`$4020`**：`addr[15:5]=513 ≠ 512`，故 `OPEN`，读回 `open_bus_q`。
- **`$6000` / `$8000`**：`owner` 分别是 `CART_RAM`/`CART_ROM`，地址原样交给 mapper（NROM 自行决定 16K/32K 是否镜像）。

注意：这七个地址在 `READ_WAIT_CYCLES=1` 下**全部零等待**（1 拍 ≤ 1）；只有调到 ≥2，外部 owner 才进入 `active` 倒计时。

---

## 6. 常见疑问

**Q：`wait_need <= 1` 不是 bug 吗？1 拍等待怎么就不算等待？**
A：因为这条路径上 `ce` **就是 CPU 周期**（`ce_cpu=(div_phase==0)`，一拍占 12 个 `clk`）。"等 1 拍 `ce`" = "等 1 个 CPU 周期"，而这一拍靠自由运行读端口提前装载白拿。**DMA 侧阈值是 `==0`**，因为 DMA 地址没有提前量。

**Q：`owner`/`sel_*` 为什么不带 `cpu_req`？**
A：它们是纯地址译码，这样"译码错"与"请求错"能分开定位，也和 `nes_system_v0` 现有观测量一致。

**Q：为什么 DMA 读 PPU/APU 不返回真数据？**
A：真机上那会打断渲染 / 返回当时 APU 状态，都需要 PPU/APU 侧专用通路。所以显式返回 `DMA_MMIO_VALUE` 并置 `dma_unimpl=1`、不拉任何 owner 请求——是明确声明的未实现，不是"恰好返回 0"。

**Q：CPU 和 DMA 同时访问卡带谁赢？**
A：靠 `bus_hold` 互斥，DMA 拉高 hold 才拿到总线，此时 CPU 分支冻结。唯一会在 hold 期间改值的对外信号是 `cart_addr`。

**Q：为什么 RAM 复位不清内容？**
A：`reset` 只清等待状态、`open_bus_q`、`ram_q`，**不动 `ram_array`**；上电内容由 `RAM_INIT` 决定。

---

## 7. 你应该带走的三件事

1. **译码 = 一张表 + 一个函数**：`decode_owner(addr)` 看 `addr[15:13]` 把地址归到六个 owner 之一；折叠就是丢高位（RAM 丢 bit11 及以上 → 四路镜像）。
2. **`wait_need <= 1` 是零等待**：因为 `ce` 就是 CPU 周期，1 拍靠自由运行读端口白拿。**DMA 侧阈值却是 `==0`**，因为 DMA 地址没有提前量——这个不对称是 `bus-tb` 的重点回归。
3. **重活都在一个大时序块里**：副作用只在完成拍发生一次；`bus_hold` 冻结（CPU）而非清零；请求撤回即作废；CPU 与 DMA 两套状态机靠 `bus_hold` 互斥。

下一篇 [`31-ines-parser.md`](31-ines-parser.md) 换一个方向：看 `ines_header_parser.v` 怎么一个字节一个字节地"吃"掉 iNES 文件头。
