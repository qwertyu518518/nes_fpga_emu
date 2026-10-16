# 52 精灵精读：`nes_ppu_sprite.v`

上一篇 [`51-ppu2c02.md`](51-ppu2c02.md) 讲了 PPU 的像素流水线。这一篇讲它里面最"反常识"的一块：**精灵（sprite）**。

软件模拟器里，精灵是"逐扫描线评估 + 移位寄存器 + 每 dot 挪一位"。而本项目的 `nes_ppu_sprite.v` 把这套东西整个换掉了：它是一个**每个 dot 都从头重算一遍的纯组合电路**，没有 secondary OAM、没有评估窗口、没有移位寄存器。这一篇就一步步讲清楚它是怎么做到的，以及为什么这样做是对的。

- 源码：[`rtl/nes_core/ppu/nes_ppu_sprite.v`](../../rtl/nes_core/ppu/nes_ppu_sprite.v)
- 合同与证据：[`../modules/ppu-sprites.md`](../modules/ppu-sprites.md)（术语、与真实 2C02 的差异、未实现清单都在那里）
- 自检 testbench：[`tb/ppu/tb_nes_ppu_sprite.v`](../../tb/ppu/tb_nes_ppu_sprite.v)
- 测试目标：`ppu-sprite`（见 [`tools/sim_all.ps1`](../../tools/sim_all.ps1)）

---

## 1. 定位与上下游

精灵通路的任务只有一句话：**在当前扫描线、当前 dot 上，屏幕这个像素该不该画精灵？画哪个精灵的哪个像素？**

```text
   upstream (nes_ppu2c02)                            本模块                  下游
oam_ram ─► sprite_oam_bus(2048b) ─┐
ctrl / mask / scanline / dot ─────┼─► [nes_ppu_sprite] ─► sprite_pixel(4)
chr_ram / 外部 shadow ────────────┘                       sprite_priority(4)
                                                          sprite0_hit / sprite_overflow
                    cur_slot_o(4)、pat_addr_o(104) ─────► 上层 CHR 预取
```

关键点：

- 上游 `nes_ppu2c02` 把 256 字节的 OAM 拍平成一根 **2048 位**总线（`sprite_oam_bus`），本模块**只读不写**。
- 本模块**不产生最终颜色**。`sprite_pixel` 只是"精灵 palette 组号 + pattern 值"，`sprite_priority` 只是"这个精灵在背景前还是后"。真正合成由上层做。
- **整份模块是纯组合逻辑**。端口上有 `clk`、`ce`，但文件里没有任何 `always @(posedge clk)`——它们只是给例化模板留的占位，本模块不用。

---

## 2. 骨架代码

下面是本模块最关键的几段（**不是全文**），先建立印象，第 3 节逐段拆。

### 2.1 端口与"可见区"门控

```verilog
module nes_ppu_sprite #(
    parameter EXTERNAL_CHR = 1'b0,
    parameter PER_SLOT_CHR = 1'b0
)(
    input  wire           clk, reset, ce,
    input  wire [2047:0]  oam,          // 64 项 x 4 字节，扁平
    input  wire [65535:0] chr,          // 8 KiB CHR
    input  wire [15:0]    chr_sh,       // 外部单行两平面（EXTERNAL_CHR=1 用）
    input  wire [127:0]   chr_slots,    // 8 slot x 两平面（PER_SLOT_CHR=1 用）
    input  wire [7:0]     ctrl, mask,
    input  wire [8:0]     scanline, scanline_sel, dot,
    input  wire [3:0]     bg_pixel,
    output reg  [3:0]     sprite_pixel, sprite_priority,
    output reg            sprite0_hit, sprite_overflow,
    output wire [103:0]   pat_addr_o, pat_addr_cur_o,
    output wire [3:0]     cur_slot_o
);

wire [8:0] sprite_height = ctrl[5] ? 9'd16 : 9'd8;      // 8x16 / 8x8
wire       frame_active  = !reset && (scanline < 9'd240);
wire       pixel_active  = frame_active && (dot < 9'd256)
                           && ((dot >= 9'd8) || mask[2]);
```

### 2.2 范围比较：哪些 OAM 项"在本行"

```verilog
always @* begin
    in_range = 64'd0;
    range_count = 7'd0;
    for (si = 0; si < 64; si = si + 1) begin
        scan_addr = {1'b0, si[5:0], 2'b00};      // si*4 = OAM 字节基址
        scan_bit  = {3'b000, scan_addr} << 3;    // si*32 = 位偏移
        scan_y    = (scan_addr > 9'd255) ? 8'h00 : oam[scan_bit +: 8];
        scan_row  = {1'b0, scanline} - {2'b0, scan_y};
        scan_hit  = (scan_row < {1'b0, sprite_height});
        in_range[si] = scan_hit;
        if (scan_hit) range_count = range_count + 7'd1;
    end
end
```

### 2.3 优先级：共享 popcount + 两级"最低置位"挑选

```verilog
// cnt[b] = 严格小于 b 的置位个数（前缀 popcount）
assign cnt_cur[pc] = cnt_cur[pc-1] + {6'd0, in_range[pc-1]};

// 第 pc 个"在范围内"的 OAM 项标出来
assign cur_marks[pc][pb] = in_range[pb]
    && (cnt_cur[pb] == {4'b0000, pc[2:0]});

// 取最低置位下标 = 第 g 个命中项
assign s_idx = first_set64(cur_marks[g]);
```

### 2.4 一个 slot 的图案取数与像素组合

```verilog
assign s_table = ctrl[5] ? s_tile_byte[0] : ctrl[3];
assign s_tile  = ctrl[5] ? {s_tile_byte[7:1], s_row[3]} : s_tile_byte[7:0];
assign s_fine  = slot_attr[g][7] ? ({1'b0, sprite_height} - 10'd1 - s_row) : s_row;
assign s_pat_addr = {s_table, s_tile, 1'b0, s_fine[2:0]};
assign s_plane_lo = chr[{s_pat_addr, 3'b000} +: 8];             // 低平面
assign s_plane_hi = chr[({s_pat_addr, 3'b000} + 13'd64) +: 8];  // 高平面
assign s_xoff = {2'b00, dot[7:0]} - {2'b00, slot_x[g]};
assign s_xbit = slot_attr[g][6] ? s_xoff[2:0] : (3'd7 - s_xoff[2:0]);
assign s_pat  = {s_plane_hi[s_xbit], s_plane_lo[s_xbit]};       // {高, 低}
assign slot_opaque[g] = (SLOT_U8 < range_count) && (s_xoff[9:3] == 8'd0)
                        && (s_pat != 2'b00);
```

### 2.5 优先级链、sprite0 hit、overflow

```verilog
for (j = 0; j < 8; j = j + 1)
    if (!found && slot_opaque[j]) begin
        sprite_pixel    = {slot_attr[j][1:0], slot_pat[j][1:0]};
        sprite_priority = {4{slot_attr[j][5]}};
        found = 1'b1;
    end

if (pixel_active && slot_opaque[0] && (bg_pixel != 4'h0))
    sprite0_hit = 1'b1;

if (frame_active && (range_count > 7'd8))
    sprite_overflow = 1'b1;
```

### 2.6 `cur_slot_o`：纯观测

```verilog
cur_slot = 4'h8;
for (k = 0; k < 8; k = k + 1) begin
    cur_xoff  = {2'b00, dot[7:0]} - {2'b00, slot_x[k[2:0]]};
    cur_cover = (k[2:0] < {1'b0, range_count}) && (cur_xoff[9:3] == 8'd0);
    if (cur_cover && (cur_slot == 4'h8)) cur_slot = {1'b0, k[2:0]};
end
if (!(frame_active && (dot < 9'd256))) cur_slot = 4'h8;
assign cur_slot_o = cur_slot;
```

---

## 3. 逐段精读

### 3.1 文件头：先记住"没有什么"

文件头很长，最重要的一句是：**"Nothing here is registered."** 没有 secondary OAM、没有评估窗口（dot 65..256）、没有 fetch 窗口（dot 257..320）、没有 X 倒计数器、没有 8 组移位寄存器。软件模拟器必须串行地把 64 个精灵筛成 8 个，硬件本来就有一排并行比较器，所以这里**每个 dot 都把整条通路重算一遍**。模块只回答"当前 dot 的输出是什么"，不记忆任何历史，因此不需要时钟。

### 3.2 高度与可见区（`sprite_height` / `frame_active` / `pixel_active`）

- `sprite_height`：**`PPUCTRL[5]` 是这个模块里唯一影响"精灵多高"的寄存器位**。1 = 8×16，0 = 8×8。
- `frame_active`：`scanline < 240` 才算可见区，所以 scanline 240..511 一律输出 0（vblank 和 pre-render 行被整个屏蔽）。
- `pixel_active`：可见区里再看 dot。`dot < 256` 是横向可见；`dot >= 8 || mask[2]` 处理**左 8 像素裁剪**——只有 `PPUMASK[2]` 为 1 时 dot 0..7 才让精灵出现。
- 三者都为假时，`sprite_pixel` / `sprite_priority` 被强制清 0。

### 3.3 `scanline_chain` 与 `scanline_next`

```verilog
wire [8:0] scanline_chain = (^scanline_sel === 1'bx) ? scanline : scanline_sel;
wire [8:0] scanline_next  = (scanline == 9'd261) ? 9'd0 : (scanline + 9'd1);
```

- `scanline_chain`：真正的渲染行。`(^x === 1'bx)` 是"`scanline_sel` 这几位全是 X"的检测（仿真里没接的信号是 X）；是 X 就退回用 `scanline`。
- `scanline_next`：下一行号（261 → 0 回绕），只用来生成 **下一行** 的图案地址 `pat_addr_o` 供上层提前预取，**不影响本 dot 的像素输出**。

### 3.4 范围比较（第 2.2 段）

逐行拆：

- `scan_addr = {1'b0, si[5:0], 2'b00}`：OAM 项 `si`（0..63）的字节基址 = `si*4`（`si<<2`）。
- `scan_bit = {3'b000, scan_addr} << 3`：换算成 2048 位总线上的**位**偏移 = `si*32`。
- `scan_y`：取这一项的 Y 字节。`scan_addr > 255` 的保护是防越界（OAM 项 63 正好顶到边界）。
- `scan_row = {1'b0, scanline} - {2'b0, scan_y}`：**10 位无符号减法**。这就是 `line_y` 与 `sprite_y` 的关系，命中条件是

  ```text
  sprite_y <= line_y < sprite_y + sprite_height
  ```

  即 `scan_row = line_y - sprite_y ∈ [0, height-1]`。
- 为什么用 10 位减法？当 `sprite_y > line_y`（精灵在这一行下面）时，无符号减法**回绕成一个很大的数**，`scan_row < height` 自然为假，于是"不在范围内"。这省掉一个 `line_y >= sprite_y` 的比较器——`Y=$FF` 的"隐藏精灵"手法也因此天然有效。
- `in_range[si]`：64 位向量，第 `si` 位 = "OAM 项 si 覆盖本行"；`range_count` 是置位个数，即"本行一共几个精灵在范围内"。

> 范围扫描有两份几乎一样的代码——`in_range`（本行，用于渲染）和 `nl_in_range`（`scanline_next` 行，用于预取）。**这是有意的重复**，因为 `s_pat_addr` 必须按本行算，不能把本行行号换成下一行。

### 3.5 共享 popcount + 两级挑选（第 2.3 段）

问题：**怎么按 OAM 顺序取前 8 个命中项？** 朴素做法是"对每个 slot 各扫一遍 64 项数置位"，但那是 64 级深的串行链，实测是瓶颈。这里改成**共享前缀 popcount + 两级"最低置位"挑选**：

- `cnt_cur[b]` = **严格小于 `b`** 的置位个数（`cnt_cur[0] = 0`）。它只取决于向量本身，8 个 slot 共用一份。
- `cur_marks[pc]` 是 64 位向量：第 `pb` 位为 1 ⟺ `in_range[pb]` 且它前面正好有 `pc` 个命中。于是 **`cur_marks[pc]` 里最低的置位下标，就是"第 `pc+1` 个命中项"的 OAM 下标**。

`first_set64` 取"最低置位下标"，分两级：

```verilog
nzx[0] = (v[7:0] != 0); ... nzx[7] = (v[63:56] != 0);
sel = first_nz8(nzx);                                // 先选第一个非空字节
first_set64 = {sel, first_nz8(v >> {sel,3'b000})};   // 再选字节内第一个 bit
```

两级都是 8 路优先，所以深度是固定的 **8+3 级**，而不是 64 级串行链。`first_nz8` 是一个 8 路 `if-else` 优先级编码（低位优先）。

> 等价性说明：原来的串行写法"数到第 pick 个置位就停"，和这里"`cnt == pick` 且置位"逐位一致（文件头有完整论证）。这不是近似，是同一逻辑的两种写法。

### 3.6 8 个 slot 的地址生成（第 2.4 段的上半）

每个 slot 先用 `first_set64(cur_marks[g])` 拿到自己负责的 OAM 项号，再取这一项的四个字节：

```verilog
assign s_idx  = first_set64(cur_marks[g]);
assign s_addr = {1'b0, s_idx, 2'b00};             // 项号 -> 字节基址
assign s_y        = oam[s_bit0 +: 8];             // +0
assign s_tile_byte= oam[(s_bit0 + 12'd8) +: 8];   // +1 字节
assign slot_attr[g] = oam[(s_bit0 + 12'd16) +: 8];// +2 字节
assign slot_x[g]  = oam[(s_bit0 + 12'd24) +: 8];  // +3 字节
```

（实际代码每一项都带 `> 9'd255` 的越界保护，这里省略。）`slot_x[g]` 就是精灵的水平位置，后面算 `s_xoff` 要用。

### 3.7 8×16、翻转、fine-x、图案拼接

- **8×16（`ctrl[5]=1`）**：图案表由 **tile 号的 bit0** 选（`s_tile_byte[0]`），`PPUCTRL[3]` 被忽略。tile 号用 `{tile[7:1], row[3]}`：上半张（row 0..7）读偶数 tile，下半张（row 8..15）读下一个 tile。**用拼接而不是加法**，所以不会进位/回绕。8×16 一个精灵覆盖上下两块相邻 tile（一个 32 字节块）。
- **8×8（`ctrl[5]=0`）**：表由 `ctrl[3]` 选，tile 号就是整个 tile 字节，覆盖 0..255 全部 tile。
- **垂直翻转（`attr[7]`）**：`s_fine = height-1 - s_row`，把行号在精灵高度内镜像（8×8 是 `7-row`，8×16 是 `15-row`）。
- `s_pat_addr = {s_table, s_tile, 1'b0, s_fine[2:0]}` 是 13 位图案字节地址：最高位是表，中间 8 位是 tile 号，bit3 恒 0（tile 16 字节对齐），低 3 位是 tile 内行。

取两个平面：

```verilog
assign s_plane_lo = chr[{s_pat_addr, 3'b000} +: 8];             // 字节 s_pat_addr
assign s_plane_hi = chr[({s_pat_addr, 3'b000} + 13'd64) +: 8];  // 字节 s_pat_addr+8
```

- `{s_pat_addr, 3'b000}` 把字节地址换算成**位**偏移（×8）。这是对 65536 位 `chr` 的**变址部分选**，所以基地址是位 `s_pat_addr*8`，也就是字节 `s_pat_addr`。
- 高平面比低平面多 **`13'd64` 位 = 8 字节**：2C02 图案表里一个 tile 占 16 字节（plane0 在 0..7，plane1 在 8..15），所以同一行的高平面在 `s_pat_addr+8`。**不能改成 `13'd8`**（那是下一行，会把两平面都读成 plane0）。

### 3.8 水平翻转与 x 窗口

- `s_xoff = dot - sprite_x`，同样是 10 位无符号减法。`s_xoff[9:3] == 0` ⟺ `0 <= dot - sprite_x <= 7`，即 dot 落在精灵的 8 像素窗口内。
- `s_xoff[2:0]` 是**窗口内的 fine-x**（0..7）。
- `attr[6]` 是**水平翻转**：不翻转时 `s_xbit = 7 - fine`（**最左像素取 bit7**，MSB first）；翻转时 `s_xbit = fine`（最左像素取 bit0）。
- `s_pat = {s_plane_hi[s_xbit], s_plane_lo[s_xbit]}`：**高平面做 bit1、低平面做 bit0**，拼成 2 位图案值。

> 注意背景是 **LSB first**（fine-x 从 bit0 起），精灵是 **MSB first**。同一张 tile 当背景和当精灵看，左右是镜像的。

### 3.9 `slot_opaque`：一个 slot 到底画不画

```verilog
assign slot_opaque[g] = (SLOT_U8 < range_count)     // slot 真实存在
                     && (s_xoff[9:3] == 8'd0)        // dot 在 8 像素窗口内
                     && (s_pat != 2'b00);            // 图案值非 0（不透明）
```

三个条件缺一不可：

1. **`SLOT_U8 < range_count`**：当命中的精灵**不足 8 个**时，`first_set64` 对空向量返回 0（垃圾下标），所以"slot g 是否存在"必须由计数单独判断。这也是"8 精灵上限"的另一半——**超出的精灵不是被画成透明，而是根本没有对应 slot**。
2. **水平窗口**：dot 必须落在 `sprite_x .. sprite_x+7`。
3. **不透明**：图案值为 `2'b00` 表示透明，不画。

### 3.10 像素组合、精灵优先级、sprite0 hit、overflow

**优先级链**（第 2.5 段）：`j` 从 0 到 7 扫，第一个 `slot_opaque[j]` 胜出（`!found &&` 保证只取第一个）。因为 `slot_index[g]` 是递增的 OAM 下标，所以 **`j` 小 = OAM 下标小 = 优先**——这正是硬件"同一像素上 OAM 下标小的精灵赢"的规则。胜出后：

```verilog
sprite_pixel    = {slot_attr[j][1:0], slot_pat[j][1:0]};  // 高 2 位 palette 组，低 2 位 pattern
sprite_priority = {4{slot_attr[j][5]}};                   // 4 位全等于 attr[5]
```

- `sprite_pixel` **不是** `$3Fxx` 索引，也不是 RGB，只是 palette 组号 + pattern 值，最终颜色留给上层。
- `sprite_priority` 只是胜出 slot 的 **`attr[5]`**（1 = 这个精灵在背景后面）。**背景/精灵谁赢不在这个模块里决定。**

**sprite0 hit**：`pixel_active && slot_opaque[0] && (bg_pixel != 4'h0)`，即"可见像素上，slot 0 不透明，且背景像素也不透明"。注意 **`slot_opaque[0]` 是 slot 0，不是 OAM 项 0**——若 OAM 项 0 不在范围内，slot 0 会被下一个在范围内的精灵占据。

**overflow**：`frame_active && (range_count > 8)`。**计数语义**：本行命中精灵超过 8 个就置位。不受 `dot`、不受 `mask` 影响（只在 `frame_active` 内）。

### 3.11 `cur_slot_o`：纯观测输出

`cur_slot_o` 报告"当前 dot 位于哪一个 slot 的 8 像素窗口上"：

- **只按位置判定**：`k < range_count`（slot 存在）且 x 窗口覆盖 dot。**它不看 `s_pat`、也不看 `mask`**，所以即使这个 slot 这一像素是透明的、或被左 8 裁剪，`cur_slot_o` 依旧报它。
- 取**最低**（OAM 顺序最靠前）的覆盖 slot；没有一个覆盖就返回哨兵 **`4'h8`**。
- `dot >= 256`、vblank、reset 时**无条件** `4'h8`。

**为什么它是纯观测输出？** 因为它不依赖任何图案数据（`chr_sh`/`s_pat`），也就**不会形成组合环**：

```text
如果 cur_slot_o 由"胜出 slot"决定：
   chr_sh → s_pat → slot_opaque → cur_slot_o → chr_sh   ← 会成环
所以它只取位置规则（slot_opaque 的前两项），与图案无关。
```

**上层怎么用它？** 在 `nes_ppu2c02` 的 `EXTERNAL_CHR=1` 路径里，`cur_slot_o` 接到 `sp_slot`：

```verilog
assign sp_base_lo = {sp_slot[2:0], 4'b0000};
assign sp_base_hi = {sp_slot[2:0], 4'b1000};
assign sp_plane_lo = (sp_slot == 4'h8) ? 8'h00 : sp_shadow[sp_base_lo +: 8];
assign sp_plane_hi = (sp_slot == 4'h8) ? 8'h00 : sp_shadow[sp_base_hi +: 8];
assign sp_chr_sh   = sp_shadow_valid ? {sp_plane_hi, sp_plane_lo} : 16'h0000;
```

上层用 `cur_slot_o` 去 shadow 缓存里索引"这个 slot 的行字节"，拼成 `{sp_plane_hi, sp_plane_lo}`（高平面在高位）再回送给模块的 `chr_sh`。**它没有在这里重跑一遍 64 项扫描**——那会重复本模块已经做过的范围扫描和 8 次挑选。`4'h8` 哨兵只在 dot≥256 / vblank / reset 出现，而那些状态下本模块早已把 `sprite_pixel` 等强制为 0、根本不看 `chr_sh`，所以替换成 0 不改变任何输出。

---

## 4. 端口表

| 端口 | 方向 | 位宽 | 作用 |
|---|---|---|---|
| `clk` | in | 1 | **未使用**（纯组合）。 |
| `ce` | in | 1 | **未使用**。时序由 `scanline`/`dot` 外部给定。 |
| `reset` | in | 1 | 高有效，只参与 `frame_active`；置位时四个输出全 0。 |
| `oam` | in | 2048 | primary OAM 256 B；项 n 的 Y/tile/attr/X 在 `oam[n*32 +: 8]`、`+8`、`+16`、`+24`。 |
| `chr` | in | 65536 | 8 KiB CHR；字节 n 在 `chr[n*8 +: 8]`。 |
| `chr_sh` | in | 16 | `EXTERNAL_CHR=1` 时某 slot 一行的两平面：`[7:0]`=低平面，`[15:8]`=高平面。 |
| `chr_slots` | in | 128 | `PER_SLOT_CHR=1` 时 8 slot × 两平面（每 slot `g*16`）。 |
| `ctrl` | in | 8 | PPUCTRL。**只用 bit5**（1=8×16）和 **bit3**（8×8 表选择）。 |
| `mask` | in | 8 | PPUMASK。**只用 bit2**（1=显示左 8 像素的精灵）。 |
| `scanline` | in | 9 | 渲染行；`>=240` 视为不可见。 |
| `scanline_sel` | in | 9 | 优先的渲染行（未接时回退 `scanline`）。 |
| `dot` | in | 9 | 水平位置；`>=256` 视为不可见；x 计算只用 `dot[7:0]`。 |
| `bg_pixel` | in | 4 | 背景 palette 索引（0=透明）。**只影响 `sprite0_hit`**。 |
| `sprite_pixel` | out | 4 | `{attr[1:0], pat[1:0]}`：高 2 位 palette 组号，低 2 位 pattern 值。 |
| `sprite_priority` | out | 4 | 4 位全等于胜出 slot 的 `attr[5]`（1=在背景后面）。 |
| `sprite0_hit` | out | 1 | `pixel_active && slot_opaque[0] && bg_pixel!=0`。 |
| `sprite_overflow` | out | 1 | `frame_active && range_count > 8`。 |
| `pat_addr_o` | out | 104 | 8 slot × 13 位 **下一行**图案字节地址（供上层预取）。 |
| `pat_addr_cur_o` | out | 104 | 8 slot × 13 位**本行**图案字节地址。 |
| `cur_slot_o` | out | 4 | 观测：本 dot 所在的 slot（0..7）或 `4'h8`。 |

---

## 5. 走一遍：一个像素点上，背景 vs 精灵

设 `scanline = 32`、`dot = 32`，`ctrl=8'h00`（8×8），`mask=8'h1C`（bit2=1，左 8 不裁），`bg_pixel = 4'h0`。OAM 项 0：`Y=32, tile=1, attr=0, X=32`；CHR tile 1 的 row0 低平面 = `8'h80`。

1. **门控**：`scanline<240` → `frame_active=1`；`dot<256` 且 `dot>=8` → `pixel_active=1`。
2. **范围扫描**：64 项逐个算 `scan_row = 32 - Y`；只有项 0 的 `sprite_y=32` 使 `scan_row=0 < 8`，故 `in_range[0]=1`、`range_count=1`。
3. **选 slot**：`cur_marks[0]` 只有 bit0 置位 → `s_idx=0`，slot 0 指向 OAM 项 0。slot 1..7 因 `range_count=1`、`SLOT_U8 < 1` 不成立 → 不存在。
4. **取图案**：`s_row = 32-32 = 0`；8×8 用 `s_table=ctrl[3]=0`、`s_tile=1`；`s_fine=0`（未翻转）；`s_pat_addr = 13'h10`。读字节 16 = `8'h80`（低平面），字节 24（高平面，此处为 0）。
5. **x 与像素**：`s_xoff = 32-32 = 0` → `s_xoff[9:3]=0`（窗口内），fine-x=0；未翻转 → `s_xbit=7`；`s_pat = {hi[7], lo[7]} = 2'b01`。
6. **透明度/优先级**：`slot_opaque[0] = 1`。优先级链取 slot 0：`sprite_pixel = {attr[1:0]=2'b00, pat[1:0]=2'b01} = 4'h1`，`sprite_priority = 4'h0`。
7. **sprite0 hit**：`bg_pixel=0` 故 `sprite0_hit=0`（若上层给 `bg_pixel!=0` 就置 1）。
8. **overflow**：`range_count=1` 不 >8，`sprite_overflow=0`。
9. **cur_slot_o**：slot 0 覆盖 dot → `cur_slot_o=4'd0`。

**背景 vs 精灵的最终决定发生在模块之外**：本模块交出 `sprite_pixel/4'h1` 与 `sprite_priority/4'h0`；上层 `nes_ppu2c02` 拿着 `bg_pixel` 和这两个值，按"背景透明 → 显示精灵；背景不透明且 `sprite_priority=1` → 显示背景；否则精灵赢"合成最终颜色。

---

## 6. 常见疑问

**Q：为什么叫"每 dot 组合重算"？**
A：因为它**没有任何寄存器**。每个 dot 到来时，64 路比较、8 个 slot 挑选、图案取数、优先级全部当场算一遍。软件模拟器必须"评估一次、fetch 一次、移位 8 次"，硬件本来就并行，所以不需要时间表。

**Q：`first_set64` 对空向量返回 0，会不会画出幽灵精灵？**
A：不会——`slot_opaque` 的第一项 `SLOT_U8 < range_count` 把这些"垃圾下标"挡掉了。当命中不足 8 个时，多出来的 slot 直接判为不存在。

**Q：sprite0 hit 为什么用 `slot_opaque[0]` 而不是"OAM 项 0"？**
A：本模块从 OAM 项 0 开始扫，slot 0 通常就是 OAM 项 0；但若 OAM 项 0 不在本行范围内，slot 0 会被下一个在范围内的精灵占据。这是与真实硬件最容易被误解的一处差异，TB 里专门有 `slot 0 substitutes the first in range sprite` 把它钉住。

**Q：`sprite_priority` 是"会不会盖住背景"吗？**
A：不是。它只是胜出 slot 的 `attr[5]`。真正"背景透明则精灵一定显示"这一支留给了上层，本模块不给结论。

**Q：overflow 为什么用计数而不是复刻硬件的 bug？**
A：真实 2C02 的 overflow 很脏（评估状态机的 `m` 递增 bug 会让第 9 个之后一串精灵误置位，还和 `OAMADDR` 有关）。本模块是"功能级组合模型"，直接实现成"命中 > 8"，可预测、可断言。

---

## 7. 你应该带走的三件事

1. **"选哪些精灵"是一个并行优先级编码器，不是状态机**。`in_range` 64 位向量 + 共享前缀 popcount + `first_set64` 两级挑选，8 个 slot 各取"第 g 个命中项"，`SLOT_U8 < range_count` 负责"存在性"和 8 精灵上限。
2. **本模块只给原料，不给成品**。`sprite_pixel` 是 palette 组号+pattern 值，`sprite_priority` 是 `attr[5]`；背景/精灵的合成、灰度、最终颜色都在上层。`sprite0_hit` / `sprite_overflow` 只是两个状态标志。
3. **`cur_slot_o` 是纯观测输出**，只按位置判定、不含图案信息，专为上层 CHR 预取而设，**绝不能**由"胜出 slot"驱动（否则 `chr_sh → s_pat → slot_opaque → cur_slot_o → chr_sh` 成环）。上层 `nes_ppu2c02` 正是直接消费它、不再重跑扫描。

下一篇 [`53-apu-channels.md`](53-apu-channels.md) 换到声音侧，看 APU 的脉冲/三角/噪声三个通道怎么把寄存器变成采样流。
