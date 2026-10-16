# 02 本项目代码的固定写法：学会这几种句式就能读懂全部模块

Verilog 能写出的风格无穷无尽。好消息是：**本仓库的代码高度统一**，只要认出下面几种"句式"，`rtl/` 下 44 个文件读起来会像同一种语言。这一篇把它们一次讲完，并给出"怎么读一个新模块"的固定步骤。

---

## 1. 铁律：一个时钟，处处 `ce`

整个厂商无关核心**只有一个时钟 `clk`**，不同部件用 `ce`（clock enable）决定"这一拍要不要动"。

```verilog
// nes_system_v0.v
assign ce_ppu = !reset && (div_phase[1:0] == 2'b00);   // 每 4 拍高一次
assign ce_cpu = !reset && (div_phase == 4'd0);          // 每 12 拍高一次
```

- 你**永远不会**在本项目里看到 `always @(posedge clk_ppu)` 或门控时钟；只有 `always @(posedge clk)` 配 `if (ce)`。
- 所以读任何模块，先找它的 `ce` 是从哪来的、多久高一次。

`ce` 的作用是"冻结"：`ce=0` 时状态机不动、计数不加、输出保持。这在 `nes_chr_fetch_unit.v`、`nes_vga_timing.v` 里都是被断言的合同。

---

## 2. 王牌句式：`_next` 组合 + `_q` 寄存器

这是本项目**出现最多的模式**，读懂它就赢了一半：

```verilog
// 第一步：组合地算"下一拍的值"（wire，无记忆）
wire [9:0] h_next = h_last ? 10'd0 : (hcount + 10'd1);

// 第二步：在时钟沿把它打进寄存器（reg，有记忆）
always @(posedge clk) begin
    if (reset)   hcount <= 10'd0;
    else if (ce) hcount <= h_next;
end
```

命名约定：

| 后缀 | 含义 | 常见类型 |
|---|---|---|
| `_q` | 寄存器的**当前值**（已经存住的值） | `reg` |
| `_next` | 组合算出的**下一拍值** | `wire` |
| `_d` | 有时指"数据输入" | — |
| `_o` | 输出端口 | — |

读代码时心里默念："`hcount` 现在是值 A，`h_next` 是它下一拍要变成的值。" 这样任何计数器/状态机都能一眼看懂。

---

## 3. 寄存器块的两种骨架

**异步复位**（敏感列表里带 `or posedge reset`）：

```verilog
always @(posedge clk or posedge reset) begin
    if (reset) begin
        sr1_q <= 8'h00;
        cnt1_q <= 4'd0;
    end else if (latch_now) begin     // 复位 > 装载 > 移位
        ...
    end else begin
        ...
    end
end
```

**同步复位**：

```verilog
always @(posedge clk) begin
    if (reset) chr_rdata <= 8'h00;
    else if (prg_en) ...
end
```

不管哪种，**优先级都是从上往下**：`reset` 最高，然后是各种使能。

---

## 4. 状态机骨架：`case (state)`

```verilog
localparam [2:0] S_IDLE = 3'd0;
localparam [2:0] S_PRE  = 3'd1;
// ...

reg [2:0] state;

always @(posedge clk) begin
    if (reset) begin
        state <= S_IDLE;
        // ... 所有寄存器清零 ...
    end else if (ce) begin
        case (state)
            S_IDLE: begin
                if (req_start && !busy) begin
                    state <= S_PRE;        // 下一拍去 S_PRE
                end
            end
            S_PRE: begin
                chr_addr <= nxt_addr;      // 做一件事
                state    <= S_ARM;
            end
            // ...
            default: state <= S_IDLE;      // 永远不会走到，但必须有
        endcase
    end
end
```

读法：
1. 先看 `localparam` 列出的状态名，知道有几步。
2. 再看每个 `case` 分支：**它做了什么、下一步去哪**。
3. `state <= 某状态` 是"下一拍进入"。**同一个 `case` 里不会既进又出**，所以每拍只走一步，非常清晰。

---

## 5. 组合优先 mux：`? :` 与 `case` 做"选择"

很多"总线归属"是组合逻辑一句话：

```verilog
// nes_cpu_bus / nes_system 里常见
assign sel_buttons = read_select ? buttons2 : buttons;
```

```verilog
// nes_ppu2c02 的 CHR 仲裁（谁赢谁把地址放上总线）
assign chr_req = chr_rd_win || (sp_bus_sel ? sp_chr_req : bg_chr_req);
```

要点：这类 `? :` 是**纯组合**，没有时钟；"优先"只表示"谁的条件先满足"。

---

## 6. 参数化位宽与补零

本项目大量使用参数化位宽，读的时候只看"最终宽度"：

```verilog
// nes_mapper_nrom.v：把 14 位 cpu_addr 送到 PRG_ADDR_BITS 位
assign prg_bank_offset = NROM_MIRROR_16K
    ? {{(PRG_ADDR_BITS-14){1'b0}}, cpu_addr[13:0]}   // 高位补 PRG_ADDR_BITS-14 个 0
    : {{(PRG_ADDR_BITS-15){1'b0}}, cpu_addr[14:0]};
```

`{{(N){1'b0}}, x}` 读作："先复制 N 个 0，再拼上 x"。总宽度 = N + x 的宽度。

**看到位宽不匹配时，先怀疑是不是被有意截断**——本项目经常这样（例如 CHR 只用低 13 位），而且会在文档里写明"这是接受的截断"。

---

## 7. `dbg_*` 端口：给仿真用的"示波器"

你会看到很多 `output wire dbg_xxx`。它们**不是功能端口**，只是把内部状态引出来方便 testbench 观察：

```verilog
assign dbg_sr1          = sr1_q;
assign dbg_selected_cnt = sel_cnt;
```

规则：`dbg_*` 只能**看**，不能反过来影响逻辑（合同里明确禁止）。

---

## 8. 例化：命名端口，永远别用位置

```verilog
nes_mapper_nrom #(
    .PRG_ADDR_BITS(PRG_ADDR_BITS),      // 传参数
    .NROM_PRG_RAM(NROM_PRG_RAM)
) u_nrom (
    .cpu_addr(cpu_addr),                // 接端口
    .prg_bank_offset(prg_offset_nrom),
    .irq(irq_nrom)
);
```

- `#(...)` 传 `parameter`，`(...)` 接端口。
- `u_xxx` 是实例名（`u_` 前缀 = unit）。
- `.端口(信号)` 是**命名连接**：信号名可以和端口名不同（例如 `.cpu_we(we_mmc1)`）。
- **悬空输出**写 `.busy()`（括号空着）表示"不用它"。

---

## 9. 怎么读一个陌生模块（固定 6 步）

1. **看文件头注释**。本项目每个 `.v` 的头注释就是一篇小文档，列出设计要点、取舍、引用来源。
2. **看端口表**：哪些 in、哪些 out、哪些是 `dbg_*`。
3. **分组合 / 时序**：扫一遍所有 `assign` 和 `always`，标出哪些是 `@*`（组合）、哪些是 `@(posedge clk)`（寄存器）。
4. **找 `ce`**：寄存器的更新时机是什么。
5. **找状态机 / 计数器**：搜索 `case (`、`state`、`_q <=`。
6. **回到 `../modules/<同名>.md`** 看合同与证据对得上没有。

---

## 10. 把它跑起来：`sim_all.ps1`

```text
.\tools\sim_all.ps1 -Mode controller-tb   # 跑单个目标
.\tools\sim_all.ps1 -Mode controller      # 跑一组
.\tools\sim_all.ps1 -Mode all             # 全量（慢）
```

脚本做两件事：先 **elaborate**（只编译，确认能综合/编译），再 **run**（跑 testbench，靠 `$fatal` 判断 PASS/FAIL）。每个模块文档都会告诉你它的目标 id。

ModelSim 用户另有 `tb/*/run_*_tb.do`，但本项目**权威门禁是 `sim_all.ps1`**。

---

## 11. 小结：一张"读码速查表"

| 你看到的 | 它是什么 | 怎么读 |
|---|---|---|
| `assign x = ...;` | 组合逻辑 | 右边一变左边立刻变 |
| `always @* ... case` | 组合逻辑（分支选择） | 必须有 default |
| `always @(posedge clk)` | 寄存器 | 只在时钟沿更新 |
| `if (reset)` | 复位，优先级最高 | 清成已知值 |
| `if (ce)` | 使能 | 低=冻结 |
| `_q` / `_next` | 当前值 / 下一拍值 | "下一拍变成 who" |
| `case (state)` | 状态机 | 每拍走一步 |
| `{a, b, c[3:0]}` | 拼接 | 左=高位 |
| `{{N{1'b0}}, x}` | 补零到指定宽度 | N + 宽度(x) |
| `dbg_*` | 只读观测 | 不影响逻辑 |
| `u_xxx #(...) (...)` | 例化子模块 | 命名连接 |

下一篇开始实战，从最简单的纯组合模块 [`10-mapper-nrom.md`](10-mapper-nrom.md) 起步。
