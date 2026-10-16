# 63 EP4CE10 平台顶层精读：`nes_ep4ce10_top.v` + PLL 存根 + 引脚层

前面 [60](60-system-early.md)～[62](62-system-mapper.md) 讲的 `nes_system_v4` 是**厂商无关的 NES 核**：它只知道一个 `clk`、一个 `reset`、`buttons1/2`，吐出像素流和音频样点。可 FPGA 板子上没有"一个时钟"这回事——板载只有一颗 50 MHz 晶振，显示器要 25 MHz，NES 核要 21.477272 MHz。这一篇讲的就是**把核接到真实板子上的那一层**。

它回答一个问题：

> **一个 vendor 无关的 NES 核，怎么和三个时钟、四路按键、VGA 连接器拼在一起，并且能综合、能仿真？**

这一层一共三个文件：

| 文件 | 角色 | 综合吗 |
|---|---|---|
| [`rtl/platform/ep4ce10/nes_ep4ce10_top.v`](../../rtl/platform/ep4ce10/nes_ep4ce10_top.v) | **平台顶层**：三时钟引入、复位、按键消抖、视频链、音频直通 | 是 |
| [`rtl/platform/ep4ce10/nes_ep4ce10_pll_stub.v`](../../rtl/platform/ep4ce10/nes_ep4ce10_pll_stub.v) | **PLL 存根**：仿真用替身，不是真 PLL | **否** |
| [`rtl/platform/ep4ce10/nes_ep4ce10_qsf_if.v`](../../rtl/platform/ep4ce10/nes_ep4ce10_qsf_if.v) | **引脚封装层**：拼 RGB565、驱动 LED、包住顶层 | 是 |

- 合同与证据：[`../hardware/13-platform-top.md`](../hardware/13-platform-top.md)（软件 `main`/framebuffer/SDL 事件循环与硬件接线的逐条对应）
- 时钟来源与误差：[`../hardware/12-ntsc-clock-and-pll.md`](../hardware/12-ntsc-clock-and-pll.md)
- testbench 与目标：[`../../tb/platform/tb_nes_ep4ce10_top.v`](../../tb/platform/tb_nes_ep4ce10_top.v)（目标 `platform-tb`）、[`../../tb/platform/README.md`](../../tb/platform/README.md)；纯编译目标 `platform-core` / `qsf-if-core`，见 [`tools/sim_all.ps1`](../../tools/sim_all.ps1) 的 `platform` 组

前置：[`36-line-buffer.md`](36-line-buffer.md)、[`12-vga-timing.md`](12-vga-timing.md)、[`20-controller.md`](20-controller.md)。本篇**不覆盖**：Quartus 工程、`.qsf`/`.sdc`、真实 `altpll`、TF/SDRAM/WM8978 驱动。

---

## 1. 先认识"上游和下游"

```text
  （板载 50 MHz）─► [ 未生成的 altpll IP ] ─► clk_ntsc / clk_vga
                     （仿真时用 nes_ep4ce10_pll_stub 顶替）
  key0..3 ─► [ nes_ep4ce10_qsf_if ]  ← 最外层：引脚名 / LED / 拼 RGB565
                   └── [ nes_ep4ce10_top ]  ← 三时钟、复位、消抖、视频链
                            ├── nes_system_v4        （NES 核，clk_ntsc）
                            ├── nes_line_buffer_vga  （写 clk_ntsc / 读 clk_vga）
                            └── nes_vga_timing       （VGA 光栅，clk_vga）
                   VGA 引脚 ◄── hsync/vsync/de/rgb    audio ──►（待接 WM8978）
```

- **上游**：`clk_sys`/`clk_ntsc`/`clk_vga` 三个时钟、`reset_n`、四路按键，全部从端口进来。
- **本层做**：复位同步、按键消抖、把一个 4 分频写使能喂给行缓冲、把核的像素接进视频链、把 RGB565 拆成 5/6/5。
- **下游**：VGA 引脚、LED、音频端口。
- **`pll_stub` 不在顶层里被例化**：它只是"接口替身"，让没有 Quartus 的机器也能编译出一份端口清单。

---

## 2. 骨架代码

### 2.1 `nes_ep4ce10_pll_stub.v`（全文，核心就 3 行 `assign`）

```verilog
module nes_ep4ce10_pll_stub #(
    parameter integer IN_FREQ_HZ = 50_000_000,
    parameter integer NTSC_FREQ_HZ = 21_477_272,
    parameter integer VGA_FREQ_HZ  = 25_000_000
) (
    input  wire clk_in, reset_n,
    output wire clk_ntsc, clk_vga, locked
);
    assign clk_ntsc = clk_in;
    assign clk_vga  = clk_in;
    assign locked   = 1'b1;
endmodule
```

三个频率参数**只用于文档化目标频率**，模块内部一个都没用：它把 `clk_in` 原样送到两路输出，`locked` 恒 1。**频率是错的**，所以只能占位，不能跑功能仿真。

### 2.2 `nes_ep4ce10_qsf_if.v`（关键片段）

```verilog
module nes_ep4ce10_qsf_if (
    input  wire sys_clk, sys_rst_n, clk_ntsc, clk_vga,
    input  wire [3:0] key,
    output wire vga_hs, vga_vs,
    output wire [15:0] vga_rgb,
    output wire [3:0] led,
    output wire beep
);
    wire vga_de_i;  wire [4:0] vga_r, vga_b;  wire [5:0] vga_g;

    reg [24:0] hb_cnt_q;                        // LED 心跳计数器（详见 3.6）
    always @(posedge clk_vga or negedge sys_rst_n) begin
        if (!sys_rst_n) hb_cnt_q <= 25'd0;
        else            hb_cnt_q <= hb_cnt_q + 25'd1;
    end
    assign led[0] = ~hb_cnt_q[24];              // 慢闪
    assign led[1] = vga_de_i;  assign led[2] = vga_hs;  assign led[3] = vga_vs;
    assign beep   = 1'b0;

    nes_ep4ce10_top u_dut (
        .clk_sys(sys_clk), .clk_ntsc(clk_ntsc), .clk_vga(clk_vga), .reset_n(sys_rst_n),
        .key0(key[0]), .key1(key[1]), .key2(key[2]), .key3(key[3]),
        .vga_hsync(vga_hs), .vga_vsync(vga_vs), .vga_de(vga_de_i),
        .vga_r(vga_r), .vga_g(vga_g), .vga_b(vga_b),
        .audio_valid(), .audio_left()           /* 音频端口未引出 */
    );

    assign vga_rgb = {vga_r, vga_g, vga_b};
endmodule
```

（例化端口在源码里每个独占一行。）这层做三件事：**LED 心跳**、**RGB565 拼接**、**端口改名**（`sys_clk`→`clk_sys`，`sys_rst_n`→`reset_n`）。

### 2.3 `nes_ep4ce10_top.v` 的关键片段

```verilog
module nes_ep4ce10_top #(
    parameter integer CLK_SYS_HZ = 50_000_000,
    parameter integer DEBOUNCE_US = 16_000,
    parameter integer DEBOUNCE_CYCLES = (CLK_SYS_HZ / 1_000_000) * DEBOUNCE_US,
    parameter integer PPU_CLOCK_ENABLE_DIV = 4,
    parameter integer PRG_SIZE_BYTES = 16384
) (
    input  wire clk_sys, clk_ntsc, clk_vga, reset_n,
    input  wire key0, key1, key2, key3,
    output wire vga_hsync, vga_vsync, vga_de,
    output wire [4:0] vga_r,  output wire [5:0] vga_g,  output wire [4:0] vga_b,
    output wire audio_valid,  output wire [15:0] audio_left
);
    localparam integer DEBOUNCE_CNT_BITS = (DEBOUNCE_CYCLES > 1) ? $clog2(DEBOUNCE_CYCLES) : 1;
    localparam [DEBOUNCE_CNT_BITS-1:0] DEBOUNCE_LIMIT = DEBOUNCE_CYCLES - 1;
```

**复位同步器**（三域各一份，只列 `clk_sys`）与 **PPU dot 使能**：

```verilog
    reg [1:0] rst_sys_q;
    always @(posedge clk_sys or negedge reset_n) begin
        if (!reset_n) rst_sys_q <= 2'b11;                 // 异步断言（高有效 11）
        else          rst_sys_q <= {rst_sys_q[0], 1'b0};  // 同步释放（逐拍移入 0）
    end
    wire rst_sys = rst_sys_q[1];

    localparam integer PPU_CE_BITS = (PPU_CLOCK_ENABLE_DIV > 1) ? $clog2(PPU_CLOCK_ENABLE_DIV) : 1;
    reg [PPU_CE_BITS-1:0] ppu_ce_div_q;
    always @(posedge clk_ntsc or posedge rst_ntsc) begin
        if (rst_ntsc) ppu_ce_div_q <= {PPU_CE_BITS{1'b0}};
        else          ppu_ce_div_q <= ppu_ce_div_q + 1'b1;
    end
    wire ppu_ce = (ppu_ce_div_q == {PPU_CE_BITS{1'b0}});  // 每 4 拍高一次
```

**按键：`clk_sys` 域两级同步 + 计数消抖 + 再同步进 `clk_ntsc`**：

```verilog
    wire [3:0] key_async = {key3, key2, key1, key0};
    reg [3:0] key_meta_q, key_sync_q, key_candidate_q, key_stable_q;
    reg [DEBOUNCE_CNT_BITS-1:0] key_cnt_q;

    always @(posedge clk_sys or negedge reset_n) begin
        if (!reset_n) begin key_meta_q <= 4'b1111; key_sync_q <= 4'b1111; end
        else          begin key_meta_q <= key_async; key_sync_q <= key_meta_q; end
    end
    always @(posedge clk_sys or negedge reset_n) begin
        if (!reset_n) begin key_candidate_q <= 4'b1111; key_stable_q <= 4'b1111; end
        else if (key_sync_q == key_candidate_q) key_cnt_q <= 0;       // 没变化：清计数
        else if (key_cnt_q == DEBOUNCE_LIMIT) begin                   // 稳定够久：确认
            key_candidate_q <= key_sync_q; key_stable_q <= key_sync_q; key_cnt_q <= 0;
        end else key_cnt_q <= key_cnt_q + 1'b1;
    end
```

**视频链三个例化**（`nes_system_v4` → `nes_line_buffer_vga` → `nes_vga_timing`）与 **输出拆分**：

```verilog
    nes_system_v4 #(.PRG_SIZE_BYTES(PRG_SIZE_BYTES)) u_nes (
        .clk(clk_ntsc), .reset(rst_ntsc), .buttons1(buttons1), .buttons2(buttons2),
        .pixel_valid(ppu_pixel_valid), .pixel_x(ppu_pixel_x), .pixel_index(ppu_pixel_index),
        .audio_sample_valid(nes_audio_valid), .audio_sample_left(nes_audio_left) /* 其余略 */);

    nes_line_buffer_vga #(.REPEAT_LINE(1)) u_lb (
        .wr_clk(clk_ntsc), .wr_reset(rst_ntsc), .wr_ce(ppu_ce), .wr_x(ppu_pixel_x),
        .wr_pixel_valid(ppu_pixel_valid), .wr_index(ppu_pixel_index), .line_done(lb_line_done),
        .rd_clk(clk_vga), .rd_reset(rst_vga), .rd_ce(1'b1) /* 其余略 */);

    nes_vga_timing u_vga (.clk(clk_vga), .reset(rst_vga), .ce(1'b1) /* 其余略 */);

    assign vga_r = vga_rgb565[15:11];   // 5 bit R
    assign vga_g = vga_rgb565[10:5];    // 6 bit G
    assign vga_b = vga_rgb565[4:0];     // 5 bit B
    assign audio_valid = nes_audio_valid;
    assign audio_left  = nes_audio_left;
```

---

## 3. 逐段精读

### 3.1 三个时钟怎么进来的，为什么 `pll_stub` 只是替身

顶层有**三个时钟端口**，频率与用途各不相同（[`../hardware/12-ntsc-clock-and-pll.md`](../hardware/12-ntsc-clock-and-pll.md) 第 1 节）：

| 端口 | 频率 | 谁提供 | 驱动什么 |
|---|---:|---|---|
| `clk_sys` | 50 MHz | 板载晶振 `PIN_E1` | **只**用于按键两级同步 + 16 ms 消抖计数 |
| `clk_ntsc` | 21.477272 MHz | `altpll`（**本模块不含**） | NES 核 + 行缓冲写口 + `ppu_ce` |
| `clk_vga` | 25 MHz | `altpll`（**本模块不含**） | VGA 光栅 + 行缓冲读口 + RGB 输出 |

关键点：**本顶层自己不做 PLL**，`clk_ntsc`/`clk_vga` 是从端口进来的，由 EP4CE10 的 `altpll` IP 在 Quartus 里生成后引进。所以顶层文件里没有任何 vendor primitive（没有 `altpll`、没有 `lpm_*`），能在没有 Quartus 的机器上编译。

`pll_stub` **不是** PLL：它把 `clk_in` 原样送到两路输出（`clk_ntsc` 与 `clk_vga` 会是**同一个频率**，真实硬件上是错的）、`locked` 恒 1。它的存在只是把"顶层需要两个时钟输出 + 一个 `locked`"这个**接口固定下来**，让 Icarus 仿真和端口清单有个可编译的替身；综合时用 Quartus MegaWizard 生成的 `altpll` 把它换掉。一句话：**`pll_stub` 是"仿真替身 + 接口合同"，不是时钟方案。**

### 3.2 复位：异步断言、同步释放

`reset_n` 是板级**低有效**输入，三个域各有一份**结构相同**的同步器：

```verilog
    always @(posedge clk_sys or negedge reset_n) begin
        if (!reset_n) rst_sys_q <= 2'b11;                 // 异步断言
        else          rst_sys_q <= {rst_sys_q[0], 1'b0};  // 同步释放
    end
    wire rst_sys = rst_sys_q[1];                          // 高有效本地复位
```

逐拍看释放过程（`reset_n` 从低变高）：

| 时刻 | `rst_sys_q` | `rst_sys` | 说明 |
|---|---|---|---|
| 断言瞬间 | `2'b11` | 1 | 异步置位，进复位 |
| 释放后第 1 沿 | `{1,0}=2'b10` | 1 | 还在复位 |
| 释放后第 2 沿 | `{0,0}=2'b00` | 0 | **复位释放** |

三条要点：**1）** 敏感列表带 `negedge reset_n` → 断言**异步**，`reset_n` 一低立刻进复位；**2）** 释放**同步**，`0` 逐拍移入，2 拍后 `q[1]` 才变 0，避免释放落在时钟沿附近产生亚稳；**3）** 输出取 `q[1]` 且**高有效**（1 = 复位），分别喂 `nes_system_v4.reset`、行缓冲 `wr_reset`/`rd_reset`、`nes_vga_timing.reset`。

**三个域的复位互不驱动**：NTSC 域的复位不接到 VGA 域上，各自留在本域。TB 抓到过真缺陷：曾因移位方向与输出极性不匹配，导致释放后**永久停在复位**，核与 VGA 一直不动。

### 3.3 按键：两级同步 + 计数消抖 + 再同步

机械按键有 5~20 ms 抖动，且按键在 50 MHz 域、核在 21.48 MHz 域，两者**没有整数关系**，所以消抖放在 `clk_sys` 域做，做完再同步进 `clk_ntsc`。整条链**三段**：

1. **`clk_sys` 域两级同步**：`key_meta_q <= key_async; key_sync_q <= key_meta_q;`——把异步按键收进本域，第 1 级可能亚稳、第 2 级稳定。
2. **`clk_sys` 域计数消抖**：`key_candidate_q` 是"上次确认的电平"。输入与它相等 → 计数清 0；不等 → 计数加 1；加到 `DEBOUNCE_LIMIT`（= `DEBOUNCE_CYCLES - 1`）时才把 `key_candidate_q`/`key_stable_q` 更新成输入并清计数。中途抖回去 → 计数清 0 重来。默认 `DEBOUNCE_US=16000`、`CLK_SYS_HZ=50 MHz` → `800000` 拍 = **16 ms**。
3. **`clk_ntsc` 域两级同步**：`btn_meta_q <= key_stable_q; btn_sync_q <= btn_meta_q;`——跨的是**电平不是脉冲**（慢速电平时长足够，两级同步稳定；脉冲在慢域可能整丢）。

最后映射到 `buttons1`（位序是 NES 手柄规格）：

```verilog
    wire [3:0] btn_pressed = ~btn_sync_q;   // 按键低有效，取反成"按下 = 1"
    wire [7:0] buttons1 = {4'b1111, btn_pressed[3], btn_pressed[2], btn_pressed[1], btn_pressed[0]};
    wire [7:0] buttons2 = 8'hFF;
```

`buttons1[0]=A(key0)`、`[1]=B(key1)`、`[2]=Select(key2)`、`[3]=Start(key3)`；`[7:4]` 恒 1 表示"未按下"，`buttons2` 第二手柄恒 `0xFF`。TB 抓到过另一个真缺陷：`buttons1` 拼接顺序写反，A/B/Select/Start 落到了 `[7:4]`。

### 3.4 `ppu_ce`：4 分频写使能，相位必须与核内 `div_phase` 一致

这是本顶层**最贵的坑之一**（[`../hardware/13-platform-top.md`](../hardware/13-platform-top.md) 第 4 节）。`ppu_ce` 是自由运行的 4 分频使能，喂给 `nes_line_buffer_vga` 的 `wr_ce`：

```verilog
    always @(posedge clk_ntsc or posedge rst_ntsc) begin
        if (rst_ntsc) ppu_ce_div_q <= 0;
        else          ppu_ce_div_q <= ppu_ce_div_q + 1'b1;
    end
    wire ppu_ce = (ppu_ce_div_q == 0);   // 每 4 拍高一次
```

**为什么不能常 1？** PPU 的 `pixel_valid`/`pixel_x` 是**组合输出**，同一个 dot 在 4 拍内保持不变。若 `wr_ce` 恒 1：x=255 会被写 **4 次**，`line_done`/`line_ready_toggle` 在行末翻转 **4 次**——偶数次后 `toggle` **回到原值**，读端**永远看不到"新的一行"**，画面全黑。

**为什么相位必须与核内 `div_phase` 一致？** 核内 `nes_system_v4` 也用 `div_phase`（12 拍）分出 `ce_ppu = /4`。顶层这个 `ppu_ce_div_q` 是**另一个** 4 分频，但它与核内 `div_phase` **由同一个 `rst_ntsc` 复位**、从**同一条 `clk_ntsc` 沿**开始计数，所以**永远同相**。若相差 1~3 拍，被漏掉的恰好是**每行第一个 dot**（x=0）——行缓冲的 `x = 0` 单元永不被写，读端第一列输出残留值。TB 用两条断言钉死相位：`pixel_x` 严格按 0..255 递增、每行 341 个 dot。

> 注意 `ppu_ce_div_q` 用**异步复位**（`or posedge rst_ntsc`），核内则是同步复位——但断言时 `rst_ntsc` 拉高的瞬间两者都归零，释放后从同一沿计数，因此仍同相。

### 3.5 视频链与输出拆分

本顶层把三个已验证的模块串起来，自己**不做**任何像素运算（数据流见第 5 节）：

- **`nes_system_v4`**：NES 核，跑在 `clk_ntsc`，`reset = rst_ntsc`，`PRG_SIZE_BYTES` 由顶层透传（NROM 期集成，16 KiB PRG）。
- **`nes_line_buffer_vga`**：跨域枢纽。写口 `clk_ntsc`（`wr_ce = ppu_ce`），读口 `clk_vga`（`rd_ce = 1'b1`），`REPEAT_LINE = 1` 表示垂直 2 倍放大。
- **`nes_vga_timing`**：自由运行光栅，跑在 `clk_vga`，`ce = 1'b1`，不存像素，缺像素输出黑；`line_read_sync` 悬空。
- **跨域真正过同步器的只有 1 bit**：`line_ready_toggle`。`pixel_x`/`pixel_index` 留在双口 RAM 里不过同步器（[`36-line-buffer.md`](36-line-buffer.md) 3.5 节）。
- 输出拆成 **RGB 5/6/5**（纯位切片，无换算）：`vga_r = rgb565[15:11]`、`vga_g = [10:5]`、`vga_b = [4:0]`。

**音频只做两行直通**：`audio_valid = nes_audio_valid`、`audio_left = nes_audio_left`。`audio_valid` 是 **1 拍宽 strobe**，速率 = `ce_cpu` = 1.789773 MHz，**不是音频采样率**（44.1/48 kHz）；`audio_left` 是**无符号幅度**。接 WM8978 需要"异步 FIFO + MCLK 域 + 重采样"，本顶层**有意不做**，只留端口；`audio_sample_right` 存在但顶层未引出。

### 3.6 `qsf_if`：RGB565 拼接与 LED

`qsf_if` 是"引脚名那一层"，三点值得记：

1. **拼 RGB565**：顶层输出拆开的 `vga_r/g/b`，`qsf_if` 用 `{vga_r, vga_g, vga_b}` 拼回 16 位 `vga_rgb`，正好回到行缓冲内部的 RGB565 格式——这只是**位拼接**。
2. **LED 心跳**（`clk_vga` 域 25-bit 计数器）：`led[0] = ~hb_cnt_q[24]`（约 `2^25/25 MHz ≈ 1.34 s` 翻转，肉眼可见的慢闪）；`led[1] = vga_de_i`、`led[2] = vga_hs`、`led[3] = vga_vs`（把关键时序直接接灯，板级调试最有用）；`beep = 1'b0`。
3. **它没有例化任何 PLL**：`clk_ntsc`/`clk_vga` 是**输入端口**，说明真实 PLL 在它**之上/之外**。真正上板层次是"`altpll` + `qsf_if`（内含 `top`）"，`pll_stub` 只是仿真时顶替 `altpll` 的那块。

注意 **端口改名**：`qsf_if` 用 `sys_clk`/`sys_rst_n`，接 `top` 时变成 `clk_sys`/`reset_n`——命名不同，信号是同一根。

### 3.7 本层不含什么（有意不做）

| 项目 | 状态 | 说明 |
|---|---|---|
| `altpll` IP | **未生成** | 只有 `pll_stub` 占位；参数需 Quartus MegaWizard + TimeQuest 确认 |
| `.qsf` 引脚分配 | **待补** | `clk_sys`→`PIN_E1`、`reset_n`→`PIN_M1`、按键与 VGA 引脚待填 |
| `.sdc` 时序约束 | **待补** | `ce_ppu` 控制的寄存器需 4 拍多周期约束，否则 STA 报假失败 |
| TF 卡 / SDRAM / WM8978 / 完整手柄 | 未实现 | 本层不含任何存储器实例与外设驱动，板载 4 键只够 P0 |

**本顶层不含任何 vendor primitive、存储器实例、TF/SDRAM/WM8978 驱动**——这正是它能被纯 Icarus 编译（`platform-core`/`qsf-if-core` 两个 elaboration 目标）的原因。

---

## 4. 端口表

### 4.1 `nes_ep4ce10_top`

| 端口 | 方向 | 位宽 | 域 | 作用 |
|---|---|---|---|---|
| `clk_sys` | in | 1 | — | 50 MHz，仅按键消抖 |
| `clk_ntsc` | in | 1 | — | 21.477272 MHz，NES 核 |
| `clk_vga` | in | 1 | — | 25 MHz，VGA |
| `reset_n` | in | 1 | — | 板级**低有效**复位 |
| `key0..key3` | in | 1 | `clk_sys` | 四路按键，**低有效** |
| `vga_hsync`/`vga_vsync`/`vga_de` | out | 1 | `clk_vga` | VGA 同步与数据有效 |
| `vga_r` / `vga_g` / `vga_b` | out | 5/6/5 | `clk_vga` | RGB565 拆出的三段 |
| `audio_valid` | out | 1 | `clk_ntsc` | 1 拍 strobe，速率 = `ce_cpu` |
| `audio_left` | out | 16 | `clk_ntsc` | 无符号音频幅度 |

主要参数：`CLK_SYS_HZ=50_000_000`、`DEBOUNCE_US=16_000`、`PPU_CLOCK_ENABLE_DIV=4`、`PRG_SIZE_BYTES=16384`。

### 4.2 `nes_ep4ce10_pll_stub`（替身）

| 端口 | 方向 | 位宽 | 作用 |
|---|---|---|---|
| `clk_in` | in | 1 | 输入时钟（原样透传） |
| `reset_n` | in | 1 | 复位（**stub 里未使用**） |
| `clk_ntsc` / `clk_vga` | out | 1 | `= clk_in`（频率是错的） |
| `locked` | out | 1 | 恒 `1'b1` |

### 4.3 `nes_ep4ce10_qsf_if`

| 端口 | 方向 | 位宽 | 作用 |
|---|---|---|---|
| `sys_clk` | in | 1 | 板载时钟（接 `top.clk_sys`） |
| `sys_rst_n` | in | 1 | 板级复位（接 `top.reset_n`） |
| `clk_ntsc` / `clk_vga` | in | 1 | 两个 PLL 时钟（**在此层之上引入**） |
| `key` | in | 4 | 四路按键 |
| `vga_hs` / `vga_vs` | out | 1 | 行/场同步（直通） |
| `vga_rgb` | out | 16 | `{vga_r, vga_g, vga_b}` = RGB565 |
| `led` | out | 4 | 心跳 + `de` + `hs` + `vs` |
| `beep` | out | 1 | 恒 0 |

---

## 5. 一个像素从 PPU 到 VGA 引脚走一遍

设 PPU 正在输出第 3 行第 7 个像素，逐段看它怎么走到引脚：

| 步骤 | 域 | 发生什么 |
|---|---|---|
| 1 | `clk_ntsc` | PPU 组合输出 `pixel_valid=1`、`pixel_x=7`、`pixel_index`，在 4 拍内保持不变 |
| 2 | `clk_ntsc` | `ppu_ce` 高那一拍，行缓冲写口把 `pixel_index` 查成 RGB565、写进 `line_mem[{wr_bank,7}]` |
| 3 | `clk_ntsc` | 写到 `pixel_x=255` 那拍，行缓冲翻 `wr_bank`、翻 `line_ready_toggle`（单 bit 电平） |
| 4 | `clk_vga` | 读端两级同步 `line_ready_toggle`，`toggle_new=1` 时开始扫描 |
| 5 | `clk_vga` | `read_x` 逐个 0..511，`read_rgb565 = line_mem[{rd_bank, read_x>>1}]`（水平 2 倍） |
| 6 | `clk_vga` | `nes_vga_timing` 在 `de` 窗口内、本行已对齐、`px_valid=1` 时把 `px_rgb565` 锁到 `rgb565` |
| 7 | `clk_vga` | 顶层拆成 `vga_r=[15:11]`、`vga_g=[10:5]`、`vga_b=[4:0]`；`qsf_if` 再拼回 16 位 `vga_rgb` 送引脚 |

**这一路穿过两个异步时钟域**：像素数据在行缓冲双口 RAM 里完成跨域，跨域控制只有 `line_ready_toggle` 一个 bit。`de` 窗口外（含帧边界）由 `nes_vga_timing` 输出黑。

---

## 6. 常见疑问

**Q：顶层为什么有三个时钟，而不是"一个时钟 + 使能"？**
A：因为 50 MHz 与 NTSC 的三个频率（21.477272/5.369318/1.789773 MHz）**没有整数关系**，靠 clock enable 从 50 MHz 分频会让 CPU 偏 +3.47% 或 -6.88%（[`../hardware/12-ntsc-clock-and-pll.md`](../hardware/12-ntsc-clock-and-pll.md) 第 4.1 节）。方案是"NES 域一颗 21.48 MHz 主时钟（核内再 `/4`、`/12`）+ VGA 域独立 25 MHz"。25 ÷ 5.369318 也无理，两域必须靠行缓冲在数据层解耦。

**Q：`pll_stub` 频率是错的，为什么还留着？**
A：它把"顶层需要 `clk_ntsc`/`clk_vga`/`locked`"这个**接口合同**固定住，让没有 Quartus 的机器也能编译整份 RTL、检查端口清单。TB 用**理想时钟**（21.477272/25/50 MHz）驱动顶层，根本不例化 `pll_stub`；综合时用真 `altpll` 替换它。

**Q：`ppu_ce` 和核内 `div_phase` 是两个计数器，怎么保证同相？**
A：两者**由同一个 `rst_ntsc` 复位**、从**同一条 `clk_ntsc` 沿**开始计数，都是自由运行 4 分频，因此永远同相——这是"构造保证"，不靠测量。若相差 1~3 拍，被漏掉的恰好是每行第一个 dot。

**Q：按键为什么在 `clk_sys` 域消抖，而不是 NES 域？**
A：因为 50 MHz 与 21.48 MHz 无整数关系，在 NES 域做消抖需要另一个间接计时基准。放 50 MHz 域用一个干净的 `DEBOUNCE_CYCLES` 计数器最直接；消抖后的**电平**再过两级同步进 NES 域即可。

**Q：`buttons1[7:4]` 为什么恒 1，`qsf_if` 为何没有音频输出？**
A：NES 手柄 8 次串行读依次是 A、B、Select、Start、Up、Down、Left、Right，板载 4 键只够前 4 个，高 4 位用 1 表示"未按下"（配合 `nes_controller` 的 `fill_one`），`buttons2` 整柄未接恒 `8'hFF`。音频端口在 `qsf_if` 里接到了悬空——这是**有意留空**，WM8978 的接法（I2S/MCLK 域）属后续工作。

---

## 7. 你应该带走的三件事

1. **平台顶层三件大事**：把三个时钟引进来（PLL 在顶层之外，`pll_stub` 只是仿真替身）、各域**异步断言同步释放**复位、把核的像素流经行缓冲跨域接到 VGA 时序。
2. **两个必须钉住的点**：`wr_ce` 必须是 PPU dot 使能（4 拍一次，常 1 会让 toggle 翻转偶数次、画面全黑）；这个 4 分频必须与核内 `div_phase` **同相**（同一个 `rst_ntsc` 复位），否则漏掉每行第一个 dot。
3. **按键三段链**：`clk_sys` 域两级同步 → 计数消抖（16 ms）→ 再两级同步进 `clk_ntsc` → 取反映射成 `buttons1[3:0]`。本层**有意不做** vendor primitive、存储器、外设驱动、`altpll` IP、`.qsf`/`.sdc`。

下一篇 [`64-zynq-top.md`](64-zynq-top.md) 看**另一块板子**上的同型顶层：`nes_zynq_top.v` 怎么用 Xilinx MMCM 产生 `core_clk`/`lcd_clk`、怎么组织三域复位、怎么把调色板 LUT 与触摸 lane 接进面板——同一个"平台层"概念，换一套 vendor 时钟与引脚。
