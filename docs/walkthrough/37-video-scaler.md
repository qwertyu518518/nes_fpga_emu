# 37 整帧缓冲参考模型精读：`nes_video_scaler.v`

这一篇读视频链的第一个模块：**把 NES 画出的 256×240 画面，放大成 512×480 送出去**。它真正教的是一个概念——**"整帧缓冲"**：先把一整帧存下来，再从头读出去。还有一个反直觉的结论：这份代码在 EP4CE10 上**不能上板**，只能当"行为参考模型"。

- 源码：[`rtl/nes_core/video/nes_video_scaler.v`](../../rtl/nes_core/video/nes_video_scaler.v)
- 合同与证据：[`../modules/video-scaler.md`](../modules/video-scaler.md)
- 测试目标：`video-tb`（[`tb/video/tb_nes_video_scaler.v`](../../tb/video/tb_nes_video_scaler.v)）、`video-core`（只编译）

---

## 1. 先认识"上游和下游"

```text
PPU 每画一个像素 ──valid/index──►┌──────────────────┐──rgb565/out_x/out_y──► 显示器（真实设计里还没接）
   (256×240)                     │  nes_video_scaler │
                                 │  写口 ─►frame_mem │  读口：自由跑一个 2 倍扫描指针
                                 │  查表 ─►RGB565     │
                                 └──────────────────┘
```

上游 **PPU** 每算完一个可见像素就送来三个数——行、列、调色板索引（`in_pixel_y`、`in_pixel_x`、`in_pixel_index`）；下游 **显示器/VGA** 按 512×480 顺序，一拍收到一个 `rgb565` 加坐标 `out_pixel_x`/`out_pixel_y`；中间是 **`frame_mem`**，一整帧 RGB565 像素先写满、再读出。

> **定位：它只是参考模型。** 本模块没有行/场同步、没有消隐期、也没有 `valid`，所以**不能直接点亮显示器**。它的价值是把"整帧缓冲 + 2 倍放大 = 地址右移"写得足够清楚，供后面写**行缓冲**版本时对答案。取舍见 [`../modules/video-scaler.md`](../modules/video-scaler.md) 第 5 节。

---

## 2. 全文代码（158 行）

```verilog
`timescale 1ns/1ps

module nes_video_scaler (
    input  wire        clk,
    input  wire        reset,
    input  wire        pixel_valid,
    input  wire [7:0]  in_pixel_x,
    input  wire [7:0]  in_pixel_y,
    input  wire [3:0]  in_pixel_index,
    output reg  [9:0]  out_pixel_x,
    output reg  [9:0]  out_pixel_y,
    output reg  [15:0] rgb565,
    output reg         line_ready,
    output reg         frame_ready
);

    localparam [7:0] LINE_LAST = 8'd255;
    localparam [7:0] FRAME_LAST = 8'd239;
    localparam [9:0] SCALE_W_LAST = 10'd511;
    localparam [9:0] SCALE_H_LAST = 10'd479;

    reg [15:0] frame_mem [0:61439];

    reg [7:0] line_count;
    reg [7:0] frame_line_count;

    reg [9:0] scan_x;
    reg [9:0] scan_y;

    wire [9:0] scan_x_next;
    wire [9:0] scan_y_next;
    wire [9:0] scan_line_last;
    wire [15:0] mem_read_addr;

    function [15:0] palette_rgb565;
        input [3:0] color_index;
        begin
            case (color_index)
                6'h00: palette_rgb565 = 16'h630C;
                6'h01: palette_rgb565 = 16'h00F1;
                6'h02: palette_rgb565 = 16'h0884;
                6'h03: palette_rgb565 = 16'h310C;
                6'h04: palette_rgb565 = 16'h4008;
                6'h05: palette_rgb565 = 16'h5807;
                6'h06: palette_rgb565 = 16'h6080;
                6'h07: palette_rgb565 = 16'h7140;
                6'h08: palette_rgb565 = 16'h79E0;
                6'h09: palette_rgb565 = 16'h6A80;
                6'h0A: palette_rgb565 = 16'h5B20;
                6'h0B: palette_rgb565 = 16'h4360;
                6'h0C: palette_rgb565 = 16'h2B21;
                6'h0D: palette_rgb565 = 16'h0AA2;
                6'h0E: palette_rgb565 = 16'h0204;
                6'h0F: palette_rgb565 = 16'h0184;
                6'h10: palette_rgb565 = 16'h0000;
                6'h11: palette_rgb565 = 16'hBDF7;
                6'h12: palette_rgb565 = 16'h039C;
                6'h13: palette_rgb565 = 16'h1C5E;
                6'h14: palette_rgb565 = 16'h6D1E;
                6'h15: palette_rgb565 = 16'h9D1E;
                6'h16: palette_rgb565 = 16'hC55E;
                6'h17: palette_rgb565 = 16'hE59E;
                6'h18: palette_rgb565 = 16'hED38;
                6'h19: palette_rgb565 = 16'hD454;
                6'h1A: palette_rgb565 = 16'hCB8F;
                6'h1B: palette_rgb565 = 16'hA32E;
                6'h1C: palette_rgb565 = 16'h82CC;
                6'h1D: palette_rgb565 = 16'h628C;
                6'h1E: palette_rgb565 = 16'h4A2A;
                6'h1F: palette_rgb565 = 16'h0000;
                6'h20: palette_rgb565 = 16'hFFFF;
                6'h21: palette_rgb565 = 16'h053F;
                6'h22: palette_rgb565 = 16'h3DDF;
                6'h23: palette_rgb565 = 16'h6E3F;
                6'h24: palette_rgb565 = 16'h9E9F;
                6'h25: palette_rgb565 = 16'hC6DF;
                6'h26: palette_rgb565 = 16'hD71F;
                6'h27: palette_rgb565 = 16'hEF3F;
                6'h28: palette_rgb565 = 16'hFF3F;
                6'h29: palette_rgb565 = 16'hFE3B;
                6'h2A: palette_rgb565 = 16'hFD37;
                6'h2B: palette_rgb565 = 16'hF494;
                6'h2C: palette_rgb565 = 16'hEC12;
                6'h2D: palette_rgb565 = 16'hDBAF;
                6'h2E: palette_rgb565 = 16'hC34E;
                6'h2F: palette_rgb565 = 16'h9AEE;
                6'h30: palette_rgb565 = 16'hFEDB;
                6'h31: palette_rgb565 = 16'h05DF;
                6'h32: palette_rgb565 = 16'h6E7F;
                6'h33: palette_rgb565 = 16'h9EDE;
                6'h34: palette_rgb565 = 16'hC71E;
                6'h35: palette_rgb565 = 16'hE77E;
                6'h36: palette_rgb565 = 16'hF7BE;
                6'h37: palette_rgb565 = 16'hFFDF;
                6'h38: palette_rgb565 = 16'hFE3D;
                6'h39: palette_rgb565 = 16'hFD5A;
                6'h3A: palette_rgb565 = 16'hF518;
                6'h3B: palette_rgb565 = 16'hF516;
                6'h3C: palette_rgb565 = 16'hF514;
                6'h3D: palette_rgb565 = 16'hF532;
                6'h3E: palette_rgb565 = 16'hF594;
                6'h3F: palette_rgb565 = 16'hF594;
                default: palette_rgb565 = 16'h0000;
            endcase
        end
    endfunction

    assign scan_line_last = (scan_x == SCALE_W_LAST);
    assign scan_x_next = scan_line_last ? 10'd0 : (scan_x + 10'd1);
    assign scan_y_next = scan_line_last
                       ? ((scan_y == SCALE_H_LAST) ? 10'd0 : (scan_y + 10'd1))
                       : scan_y;
    assign mem_read_addr = {scan_y[8:1], scan_x[8:1]};

    always @(posedge clk) begin
        if (reset) begin
            scan_x <= 10'd0;
            scan_y <= 10'd0;
            out_pixel_x <= 10'd0;
            out_pixel_y <= 10'd0;
            rgb565 <= 16'd0;
        end else begin
            scan_x <= scan_x_next;
            scan_y <= scan_y_next;
            out_pixel_x <= scan_x;
            out_pixel_y <= scan_y;
            rgb565 <= frame_mem[mem_read_addr];
        end
    end

    always @(posedge clk) begin
        if (reset) begin
            line_count <= 8'd0;
            frame_line_count <= 8'd0;
            line_ready <= 1'b0;
            frame_ready <= 1'b0;
        end else begin
            line_ready <= 1'b0;
            frame_ready <= 1'b0;
            if (pixel_valid) begin
                frame_mem[{in_pixel_y, in_pixel_x}] <= palette_rgb565(in_pixel_index);
                if (line_count == LINE_LAST) begin
                    line_count <= 8'd0;
                    line_ready <= 1'b1;
                    if (frame_line_count == FRAME_LAST) begin
                        frame_line_count <= 8'd0;
                        frame_ready <= 1'b1;
                    end else begin
                        frame_line_count <= frame_line_count + 8'd1;
                    end
                end else begin
                    line_count <= line_count + 8'd1;
                end
            end
        end
    end

endmodule
```

整份代码只有两个 `always` 块（都是 `posedge clk` 的时序逻辑）和几条 `assign`：没有状态机，结构比前几篇简单。11 个端口里 6 个 in、5 个 out，**所有输出都声明成 `reg`**，因为它们都在时序块里用 `<=` 赋值（第 01/02 篇的规则：被过程块驱动的信号用 `reg`）。

---

## 3. 逐段精读

### 3.1 常量 `localparam`

四个 `localparam`：`LINE_LAST=255`、`FRAME_LAST=239` 是**源侧**上界（一行第 256 个像素、一帧第 240 行），`SCALE_W_LAST=511`、`SCALE_H_LAST=479` 是**放大后输出侧**上界。`localparam` 是模块内部常量（第 01 篇 11 节），**看常量名就知道它属于哪一侧**。

### 3.2 `frame_mem [0:61439]` —— 整帧缓冲

`reg [15:0] frame_mem [0:61439];` 是全篇核心：前面的 `[15:0]` 是**字宽**（每像素 16 位，存查表后的 **RGB565**，不是 4 位索引），后面的 `[0:61439]` 是**深度**（61440 = `256 × 240`，**正好是 NES 可见区像素总数**）。

所以 `frame_mem` 就是把 256×240 的画面**摊平成一维数组**。这就是"整帧缓冲（full-frame buffer）"：把一整帧都存下来，上游写满它、下游再读出去，两侧解耦。Verilog 的存储器只能是一维（第 01 篇 13 节），所以二维坐标 `(x, y)` 要自己拼成下标 `y*256+x`——后面 3.4 节会看到这个"乘 256"被写成拼接 `{y, x}`。

> **关键代价**：61,440 × 16 = **983,040 bit ≈ 120 KiB**。而 EP4CE10 整片片上存储一共才 **423,936 bit ≈ 51.75 KiB（46 个 M9K）**。**这份内存比整片 FPGA 还大 2.3 倍。** 见第 6 节。

### 3.3 调色板查表 `palette_rgb565`

```verilog
function [15:0] palette_rgb565;
    input [3:0] color_index;
    case (color_index)                     // 共 64 项，见全文（索引 0 → 16'h630C）
        ...
        default: palette_rgb565 = 16'h0000;
    endcase
endfunction
```

这是一个 `function`：**输入 4 位调色板索引，输出 16 位 RGB565 颜色**，本质是一张查表（LUT），和 [`11-alu-lut.md`](11-alu-lut.md) 里的 `case` 查表同类。`function [15:0] palette_rgb565;` 里函数名就是返回值变量；体内给 `palette_rgb565` 赋值，`case` 结束时那个值就是返回值；`default` 保证任何未列出的输入都有值——**组合逻辑必须覆盖所有分支**（第 01 篇 5 节），否则会推断出锁存器。

一个细节：选择量 `color_index` 只有 **4 位**，标签却写成 **6 位**（`6'h00`…`6'h3F`）。Verilog 比较时把 4 位零扩展到 6 位，所以 `4'hA` 只匹配 `6'h0A`，**`6'h10` 以上的标签永远匹配不到**——这张 64 项的表**实际只有前 16 项可用**，恰与 TB 的 16 色覆盖一致。

**这一步是"提前查表"**：调色板索引在**写口**（像素进来时）就换成 RGB565，不是等读出时才查。因为读口每拍只吐一个像素，没时间再查表；软件模拟器相反——它 blit 时才查，因为软件查表很便宜。**"查表放在哪一侧"是软硬件最实质的一处差异。**

### 3.4 读地址：`scan_*` 与 2 倍放大

```verilog
assign scan_line_last = (scan_x == SCALE_W_LAST);                 // 到最右列了？
assign scan_x_next = scan_line_last ? 10'd0 : (scan_x + 10'd1);   // scan_x 右移，越界回 0
assign scan_y_next = scan_line_last ? ((scan_y == SCALE_H_LAST) ? 10'd0 : (scan_y + 10'd1)) : scan_y;
assign mem_read_addr = {scan_y[8:1], scan_x[8:1]};               // 2 倍放大就在这一行
```

前三条是标准"行扫描"计数器：`scan_x` 从 0 数到 511 回 0，每绕一圈 `scan_y` 加 1，数到 479 回 0。**这就是软件 `for (y) for (x)` 双重循环的硬件等价物**——软件靠控制流"遍历"，硬件只能造一个每拍 +1 的寄存器。

最后一行是**整个 2 倍放大**。拆开：`scan_x` 是 10 位但最大 511（9 位有效），`scan_x[8:1]` 取第 8..1 位，即**丢掉最低位 `scan_x[0]`** = **除以 2**——512 列 ÷ 2 = 256 源列，正好 8 位；`scan_y[8:1]` 同理，480 行 ÷ 2 = 240 源行。`{scan_y[8:1], scan_x[8:1]}` 是 16 位拼接：**高 8 位源行号、低 8 位源列号**，等价于 `源y*256+源x`——写成拼接而非乘法，因为**拼接不需要乘法器**。

**为什么右移就是放大？** 源点 `(x, y)` 对应输出点 `(2x, 2y)`、`(2x+1, 2y)`、`(2x, 2y+1)`、`(2x+1, 2y+1)`。这 4 个输出坐标的 `[8:1]` 都等于 `(x, y)`——最低位被丢掉，读的是**同一个地址**。**4 拍读同一个像素，就是 2×2 复制。** 2 倍放大不是"复制数据"，而是让**4 个输出点共用一个源地址**。

### 3.5 读口时序块（VGA 侧）

读口那个 `always @(posedge clk)` 是教科书式的 `_next` + 寄存器模式（第 02 篇 2 节）：`scan_x <= scan_x_next`/`scan_y <= scan_y_next` 推进计数器，`out_pixel_x <= scan_x`/`out_pixel_y <= scan_y` 输出当前坐标，`rgb565 <= frame_mem[mem_read_addr]` 按当前地址同步读。**三个输出是对齐的**：`out_pixel_x`、`out_pixel_y`、`rgb565` 都来自同一个 `scan_*` 当前值，所以下游拿到的一组三元组一定描述同一个源像素。

要记住：**读指针是自由运行的**——每拍 +1，不看 `pixel_valid`，也不看 `line_ready`/`frame_ready`；复位清零后一直绕 512×480 转。输出里**没有 `valid`**：模块假定下游每拍都接收一个像素，消隐期完全不管。这是它还不能点屏的原因。

### 3.6 写口时序块（PPU 侧）与 `line_ready` / `frame_ready`

```verilog
always @(posedge clk) begin
    if (reset) ... else begin
        line_ready <= 1'b0;  frame_ready <= 1'b0;      // 每拍先清零 → 单拍脉冲
        if (pixel_valid) begin
            frame_mem[{in_pixel_y, in_pixel_x}] <= palette_rgb565(in_pixel_index);  // 写口
            if (line_count == LINE_LAST) begin          // 收满 256 个
                line_count <= 8'd0;  line_ready <= 1'b1;
                if (frame_line_count == FRAME_LAST) begin   // 第 240 行
                    frame_line_count <= 8'd0;  frame_ready <= 1'b1;  // 同一拍再拉
                end else frame_line_count <= frame_line_count + 8'd1;
            end else line_count <= line_count + 8'd1;
        end
    end
end
```

逐点说：

- **写地址 `{in_pixel_y, in_pixel_x}`** 和读地址一样是拼接、语义即 `y*256+x`；**写数据 `palette_rgb565(in_pixel_index)`** 写进去的**已经**是 RGB565，不是索引（3.3 节）。
- **`line_ready`**：一行 256 个收齐后拉高**一拍**（`<= 1'b1` 下一拍生效；块开头每拍先清零，所以只维持一拍）。**`frame_ready`**：收满 240 行时在 `line_ready` 的**同一拍**再拉高。
- **`line_count` / `frame_line_count`**：两个 8 位计数器，分别数"这行收了多少个""这帧收了多少行"。

**为什么软件不需要这两个信号？** 软件的 PPU 循环本身就是"跑完 256 个 dot 就 `y++`"，行/帧边界是控制流的一部分；硬件里 PPU 是自由运行的独立时基，帧缓冲只能靠握手知道"这行/这帧收齐了"。**`line_ready`/`frame_ready` 就是硬件版的 `y++` 和帧末标志**，是给下游用的——本模块自己的读指针完全不理它们。还要记住：**`frame_mem` 不在复位列表里**，复位只清指针、计数器和两个脉冲，**不清画面内容**；所以 `reset` 之后读到的还是复位前最后一帧，TB 的 `test_reset_mid_frame` 把这条钉死了。

---

## 4. 端口表

| 端口 | 方向 | 位宽 | 作用 |
|---|---|---|---|
| `clk` / `reset` | in | 1 / 1 | 唯一时钟；高有效同步复位，清指针/计数/脉冲，**不清 `frame_mem`** |
| `pixel_valid` | in | 1 | 写口使能：为 1 才写 `frame_mem` 并推进计数 |
| `in_pixel_x` / `in_pixel_y` | in | 8 / 8 | 上游像素的源列号 (0..255) / 源行号 (0..239) |
| `in_pixel_index` | in | 4 | NES 调色板索引，送进 `palette_rgb565` 查表 |
| `out_pixel_x` / `out_pixel_y` | out | 10 / 10 | 输出（放大后）列号 0..511 / 行号 0..479 |
| `rgb565` | out | 16 | 当前输出像素的颜色（已查表） |
| `line_ready` / `frame_ready` | out | 1 / 1 | 一行 256 像素收齐 / 一帧 240 行收齐，各为单拍脉冲 |

上游=PPU（写口 4 根 + 使能），下游=显示器（读口 4 根 + 两个握手）。

---

## 5. 代入一个输出像素 (x, y) 反推源像素

设下游正在看**输出坐标 `out_pixel_x = 200`、`out_pixel_y = 110`**，一步步倒推它的来源。**第 1 步：输出坐标除以 2（丢最低位）→ 源坐标。** `200`(`1100_1000`) 丢最低位 → `1100_100` = **100**；`110`(`0110_1110`) 丢最低位 → `0110_111` = **55**，即源像素 `(100, 55)`。

**第 2 步：拼成一维下标。** `{55, 100}` = `55 × 256 + 100` = `14080 + 100` = **14180**，所以读的是 `frame_mem[14180]`。

**第 3 步：读出颜色。** 这个内容当初由 PPU 侧用 `frame_mem[{in_pixel_y, in_pixel_x}]` 写入：源点 `(100, 55)` 的写地址同样是 `{55, 100} = 14180`——**写地址与读地址在此重合**，颜色就对上了。

**再看 2×2 复制**：下面 4 个输出坐标的 `x>>1`、`y>>1` 都是 `100`/`55`，读地址都是 14180，因此 `rgb565` 完全相同：

| 输出 (x, y) | x>>1 | y>>1 | 读地址 |
|---|---|---|---|
| (200, 110) | 100 | 55 | 14180 |
| (201, 111) | 100 | 55 | 14180 |

这就是"2 倍放大"的全部机制：**一个源像素被 4 个输出像素共享，靠地址右移实现，没有插值、没有乘法器。**（TB 的 `check_source_pixel(sx, sy)` 正是反过来：数到输出 `(sx*2, sy*2)` 再比颜色，例如 `check_source_pixel(100, 55)` 落在 `(200, 110)`。）

---

## 6. 常见疑问

**Q：为什么不能综合进 EP4CE10？**
A：`frame_mem` 太大：61,440 × 16 = **983,040 bit ≈ 120 KiB**，整片 EP4CE10 片上存储只有 **423,936 bit ≈ 51.75 KiB（46 个 M9K）**，比整片还大 2.3 倍。它会占约 **120 个 M9K 块**（一共只有 46 个），综合直接失败；何况片上还要分给 CPU、APU、mapper ROM、OAM、tile、FIFO。所以它只能当**行为参考模型**，真实设计要换成**行缓冲**或 **SDRAM 帧缓冲**（[`../modules/video-scaler.md`](../modules/video-scaler.md) 第 5 节）。

**Q：`line_ready` / `frame_ready` 谁用？**
A：给**下游**（行缓冲填充器、SDRAM 写 burst、VGA 帧交换）用。本模块读指针自由运行，完全不看它们。`line_ready` 在一行第 256 个 `pixel_valid` 的下一拍拉高、只维持一拍；`frame_ready` 在收满 240 行那拍与 `line_ready` 同一拍拉高。

**Q：为什么输出没有 `valid`、读指针也不停？**
A：这是当前接口的缺口，不是 bug：它把"什么时候输出"的责任推给下游（接 VGA 时序发生器时由发生器判断该不该取这一拍），补上时序发生器才能解决。

---

## 7. 你应该带走的三件事

1. **整帧缓冲 = 一整帧先存后读**：`frame_mem [0:61439]` 就是被摊平的 256×240 画面（`y*256+x` 用 `{y, x}` 拼接）。容量（120 KiB）远超声上存储（51.75 KiB / 46 个 M9K），所以**本模块在 EP4CE10 上只当参考模型，不上板**。
2. **2 倍放大 = 地址右移**：`mem_read_addr = {scan_y[8:1], scan_x[8:1]}`，丢最低位就是 ÷2，4 个输出像素共用一个源地址；整数倍缩放不需要乘法器和插值。
3. **软硬件分工**：`line_ready`/`frame_ready` 是硬件版的 `y++` 和帧末标志，给下游握手；查表被提前到写口。读指针自由运行、无 `valid`，是当前接口最重要的缺口。

下一篇 [`38-video-800x480.md`](38-video-800x480.md) 看行缓冲版本：用**真双口 RAM 跨时钟域**把"整帧"降级为"整行"，`line_ready` 也真正有了用武之地。
