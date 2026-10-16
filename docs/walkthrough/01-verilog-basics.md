# 01 Verilog 基础：从 C 思维切到硬件思维

这一篇只讲**读懂本仓库 RTL 所必需**的 Verilog。目标不是让你会写所有语法，而是让你看到 `rtl/` 里的任意一行都能说出：它在描述什么硬件。

前置：你会写一点 C（变量、if、case、数组、函数调用）就够了。

---

## 1. 最重要的思维转变：没有"一行一行执行"

C 程序是一条语句接一条语句执行的：第 3 行跑完才跑第 4 行。

Verilog 描述的是**电路**，所有东西**同时存在、同时工作**：

```verilog
wire a = b & c;
wire d = b | e;
```

这不是"先算 a、再算 d"，而是"有两个与门/或门，b、c、e 一变，a、d 立刻跟着变"。这叫**组合逻辑**（combinational logic）：输出只取决于当前输入，没有记忆。

只有当你明确写"在时钟上升沿更新"时，硬件才**记住**上一次的值，这叫**时序逻辑**（sequential logic）：

```verilog
always @(posedge clk)
    q <= d;          // 每个 clk 上升沿，把 d 的值存进 q
```

这就是一个 D 触发器。**分清"组合"和"时序"是读任何 RTL 的第一步。** 本项目里：

- `assign ... = ...;` → 组合逻辑。
- `always @*` → 组合逻辑。
- `always @(posedge clk)` → 时序逻辑（寄存器）。

---

## 2. 模块：电路的"一盒零件"

一个 `.v` 文件通常就是一个模块，对应硬件里的一块电路板/一个零件：

```verilog
module nes_mapper_nrom (
    input  wire [15:0] cpu_addr,       // 输入端口
    output wire [2:0]  mirroring       // 输出端口
);
    // ... 内部逻辑 ...
endmodule
```

- `module 名字 (...) ;` 到 `endmodule` 是范围。
- 端口就是这根零件的"引脚"。`input` 是外面给的，`output` 是往外面送的。
- `[15:0]` 是位宽：16 根线捆成一组，`cpu_addr[0]` 是最低位，`cpu_addr[15]` 是最高位。

硬件是**并行**的，所以一个模块里可以把所有端口都当成"同时可读写的引脚"，没有先后顺序。

---

## 3. wire 和 reg：不要被名字骗了

初学者最容易卡在这里。记住一句话：

> **`wire` 和 `reg` 不是"数据类型"，而是"这根线由谁驱动"的区别。**

- `wire`：**必须被别的东西连续驱动**。它像一根导线，`assign` 或某个模块的输出一直推着它。不能"存值"。
- `reg`：**在过程块里被赋值**（`always` 块里 `<=` 或 `=`）。它**不一定**是寄存器——在 `always @*` 里它就是组合逻辑的一根中间线。

对照本项目的 `nes_vga_timing.v`：

```verilog
wire [9:0] h_next;          // 组合：下一拍 hcount 应该变成多少
assign h_next = h_last ? 10'd0 : (hcount + 10'd1);

reg  [9:0] hcount;          // 真的寄存器：每个时钟沿更新
always @(posedge clk)
    hcount <= h_next;
```

`h_next` 是 `wire`（组合算出来的值），`hcount` 是 `reg`（被时钟存住的值）。这是本项目**无处不在**的模式，第 02 篇会专门讲。

---

## 4. assign：一行就是一根线

```verilog
assign de_next = (h_next >= P_DX0) && (h_next < P_DX1) &&
                 (v_next >= P_DY0) && (v_next < P_DY1);
```

- `assign` 只能写组合逻辑，右边一变左边立刻变。
- `&&` 是逻辑与，`&` 是按位与；`||` / `|` 同理。
- 比较 `>=`、`<`、`==` 都是组合运算，会综合成比较器。

---

## 5. always @*：另一种写组合逻辑的方式

当一个组合逻辑用 `assign` 写太长时，用 `always @*`（"星号"表示敏感列表交给工具自动推断）：

```verilog
always @* begin
    case (cpu_addr[15:13])
        3'b000: cpu_din = cpu_ram[ram_index];   // 像 RAM
        3'b001: cpu_din = ppu_reg_dout;         // 像 PPU 寄存器
        default: cpu_din = prg_rom[prg_index];  // 像卡带 ROM
    endcase
end
```

（这是 `nes_system_v0.v` 里的真实代码，意思是"看地址最高 3 位，决定数据从哪个部件读"。）

要点：
- `always @*` 里用**阻塞赋值 `=`**（见第 7 节）。
- **必须给所有分支都赋值**，否则工具会以为"有些情况下要记住旧值"，于是推断出一个你并不想要的**锁存器（latch）**。所以 `case` 一定要有 `default`，`if` 往往要配 `else`。

---

## 6. always @(posedge clk)：寄存器，硬件里的"记忆"

```verilog
always @(posedge clk) begin
    if (reset) begin
        hcount <= 10'd0;
    end else if (ce) begin
        hcount <= h_next;
    end
end
```

读法（**这三行就是本项目所有寄存器的通用骨架**）：

1. `posedge clk`：只在时钟上升沿这一瞬间执行一次。
2. `if (reset)` 优先：复位时把寄存器清成已知值。
3. `else if (ce)`：只有 `ce` 为 1 时才更新；`ce=0` 时**保持不变**（冻结）。
4. `<=` 是"下一拍生效"的意思（第 7 节）。

---

## 7. 阻塞 `=` 与非阻塞 `<=`：一句话规则

- **时序块（`always @(posedge clk)`）里用非阻塞 `<=`。**
- **组合块（`always @*`）里用阻塞 `=`。**

为什么？看一个反例（**错误写法**）：

```verilog
// 错！这不是两个触发器串联，而是自己覆盖自己
always @(posedge clk) begin
    a = b;
    b = a;      // 此刻 a 已经被上面那行改成新值了
end
```

用 `<=` 才是"所有右边先同时算好，再一起写进左边"：

```verilog
always @(posedge clk) begin
    a <= b;     // 用的是这一拍开始时的 a、b
    b <= a;     // 所以这是交换，不是覆盖
end
```

`<=` 正好对应硬件的真相：所有触发器在同一个时钟沿**同时**更新。

---

## 8. 复位：同步 vs 异步

- **异步复位**：`always @(posedge clk or posedge reset)`。`reset` 拉高的**瞬间**就清，不等时钟。

```verilog
always @(posedge clk or posedge reset) begin
    if (reset) sr1_q <= 8'h00;
    else       sr1_q <= sr1_next;
end
```

- **同步复位**：`always @(posedge clk)`，`reset` 只是一个普通的 `if` 条件，要等到时钟沿才生效。

```verilog
always @(posedge clk) begin
    if (reset) chr_rdata <= 8'h00;   // 等下一个 clk 沿才清
    else       ...
end
```

本仓库两种都有，**看敏感列表里有没有 `or posedge reset`** 即可区分。本项目约定复位是**高有效**（`reset=1` 表示复位），而板子上是低有效按键，那个反转在平台层做。

---

## 9. ce（clock enable）：为什么不用门控时钟

新手常想"要用 12 分频，那我把时钟分出来不就行了"。本项目不这么做，而是**保持一个连续时钟 + 一个使能信号 `ce`**：

```verilog
always @(posedge clk) begin
    if (reset) ...
    else if (ce) begin    // ce 高才更新
        ...
    end
end
```

`ce` 高 = "这一拍允许更新"，`ce=0` = "冻结"。好处：时钟网络是干净的（EDA 工具和时序分析都喜欢），而且冻结点一目了然。本项目里 `ce_cpu`、`ce_ppu`、`ce_sample` 就是这么来的。

---

## 10. 位运算工具箱（本项目高频）

| 写法 | 含义 | 例子 |
|---|---|---|
| `x[3]` | 取某一位 | `cpu_addr[15]` 只有一根线 |
| `x[7:4]` | 取一段（切片） | `buttons[7:4]` 是高 4 位 |
| `{a, b}` | 拼接 | `{7'b0, data_bit}` = 8 位，高 7 位补 0 |
| `{8{x}}` | 复制 | `{{(PRG_ADDR_BITS-14){1'b0}}, cpu_addr[13:0]}` 高位补零 |
| `x[7:4] +: 4` | 从第 4 位往上的 4 位（上升区间） | 变量位宽的切片 |
| `a ? b : c` | 三目：a 为真取 b，否则取 c | `h_last ? 0 : hcount+1` |
| `8'hFF` | 常数：8 位、十六进制 FF | `'h` 是十六进制，`'b` 二进制，`'d` 十进制 |

**拼接是"左边是高位"**：`{fill_one, sr1_q[7:1]}` 里 `fill_one` 变成新值的 bit7。

---

## 11. parameter 与 localparam：给常数起名字

```verilog
module nes_controller #(
    parameter [1:0] EXTRA_READ = 2'd0     // 可以在例化时被外面改
)(
    ...
);
    localparam [3:0] CNT_SAT = 4'd9;      // 模块内部专用，外面改不了
```

- `parameter`：**可配置**的常量，例化时能覆盖（本项目大量用它做位宽和默认值）。
- `localparam`：模块内部常量。
- 用常量而不是到处写魔法数字，可读性完全不同。

---

## 12. generate：按参数决定要不要造某块电路

```verilog
generate
  if (PRG_ENABLE != 0) begin : g_prg
      reg [7:0] prg_rom [0:PRG_SIZE_BYTES-1];
      // ...
  end else begin : g_prg_off
      // 这块不造，减少资源
  end
endgenerate
```

（`nes_cart_rom.v` 用它按参数决定是否生成 PRG 或 CHR 存储阵列。）`begin : 名字` 是给这块生成的电路起名，例化/编译时要用。

---

## 13. 存储器：数组就是 RAM/ROM

```verilog
reg [7:0] cpu_ram [0:2047];   // 2048 个 8 位字，就是 2 KiB RAM
reg [7:0] prg_rom [0:16383];  // 16 KiB ROM
```

- 前面是"字宽"，后面是"深度"。
- 读：`cpu_ram[addr]`（组合读）或放在时钟块里（同步读）。
- 写：只能在 `always @(posedge clk)` 里写。
- ROM 常用 `initial $readmemh("file.hex", prg_rom);` 在"时间 0"灌内容——综合工具把它变成 BRAM 的初始值。见 `nes_cart_rom.v`。

---

## 14. 综合 vs 仿真：两件事

- **综合（synthesis）**：把 Verilog 变成 FPGA 里的真实电路（LUT、触发器、BRAM）。
- **仿真（simulation）**：用软件假装时间在走，检查逻辑对不对。本项目全部可复现证据都在仿真里。

仿真里可以写 `#10`（等 10ns）、`$display`、`$fatal` 这些只在 testbench 里用的东西——它们**综合不出来**，所以只出现在 `tb/` 下。

---

## 15. testbench 长什么样

testbench 也是 Verilog，但它不对应硬件，只负责"给激励 + 检查"：

```verilog
`timescale 1ns/1ps                    // 时间单位/精度
module tb_demo;
    reg clk = 0;
    reg reset = 1;
    wire [7:0] out;

    always #10 clk = ~clk;            // 每 10ns 翻一次 -> 20ns 周期（50MHz）

    dut u_dut (.clk(clk), .reset(reset), .out(out));   // 例化被测模块

    initial begin
        reset = 1; #100;
        reset = 0; #100;
        if (out !== 8'h00) $fatal(1, "out 不是 0，实际 %h", out);   // 断言失败就报错退出
        $display("PASS");
        $finish;
    end
endmodule
```

要点：
- `dut u_dut (...)`：例化被测模块，名字 `dut` 是习惯（device under test）。
- `.端口(信号)`：把 testbench 的信号接到模块端口。
- `$fatal` 让仿真非零退出——`tools/sim_all.ps1` 就是靠这个判断 PASS/FAIL。
- `$display("PASS ...")` 是被动目标检查的常见输出。

---

## 16. 新手最容易踩的 8 个坑

1. **组合块忘了赋所有分支** → 推断出 latch。`case` 要有 `default`。
2. **时序块里用了 `=`** → 仿真和硬件行为可能不一致。用 `<=`。
3. **位宽不匹配被静默截断** → 例如把 17 位地址塞进 14 位，高位直接丢。本仓库用 `{{(N-M){1'b0}}, x}` 显式补零。
4. **跨时钟域直接传多位信号** → 会采到"半新半旧"的值。要么格雷码（见 `nes_cdc_fifo.v`），要么打两拍同步（单比特）。
5. **读存储器以为是组合** → 同步 BRAM 有一拍延迟，要提前一拍给地址。
6. **复位极性搞反** → 本项目核内 `reset` 高有效，板级低有效。
7. **门控时钟** → 本项目一律用 `ce`，不切时钟。
8. **忘了 `ce` 会冻结状态机** → 冻结是好事（不丢数据），但要记得它会让时序"变慢"。

---

## 17. 学完这篇做什么

下一篇 [`02-project-conventions.md`](02-project-conventions.md) 讲本仓库**固定的几种句式**（`_q`/`_next`、复位块、`case` 状态机），学会之后你就能直接打开任意一个模块读。然后从 [`10-mapper-nrom.md`](10-mapper-nrom.md) 开始第一款真正的模块精读。
