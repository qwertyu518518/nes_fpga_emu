# PPU 外部 CHR：背景通路已接通并有像素级证据，精灵通路已接线但没有像素证据，mapper 侧仍未接

本文记录 `nes_ppu2c02` / `nes_ppu_sprite` / `nes_chr_fetch_unit` / `nes_sprite_chr_fetch` 的**外部 CHR 改造**。它分成三部分，措辞必须和仓库现状严格对应：

- **已实现（背景，有像素级证据）**：外部 CHR 的**背景 pattern 取数通路**已接通——`g_chr_external` 例化 `nes_chr_fetch_unit`，PPU 侧有 `bg_lo_q`/`bg_hi_q`/`bg_ready` 平面锁存，按逐 tile 的流水节拍取数。`tb/ppu/tb_nes_ppu2c02_ext_chr.v`（回归目标 `ppu-ext-chr-tb`）在 5 组配置 × 3 帧下做了 **921,600 次逐 `ce` 逐 dot 的 `pixel_index` + `bg_pa_enable` 比对，全部一致**。**外部 CHR 背景通路第一次有了像素级证据。**
- **已接线但没有像素证据（精灵）**：`g_chr_external` 现在也例化 `nes_sprite_chr_fetch`（dot 257 发 `start`），`chr_req`/`chr_addr` 是精灵优先的**组合优先 mux**（无握手），`shadow` 按 slot 解复用喂 `chr_sh`。A/B TB 证明**每行恰好 16 次精灵请求**、**mux 不篡改持有者地址**、**两个窗口不重叠**。**但精灵像素的等价性一条证据都没有**——TB 用的仍是全 0 透明精灵图案；而且 shadow **差一行**、8 位 `chr_sh` 只能交付**一个字节**。见第 11 节。
- **仍未实现**：`$2007` 对外部 CHR 的写通路（`chr_we` 恒 0）、mapper 侧 `chr_bank_offset` 接进 PPU。
- **已完成**：`CHR_ADDR_BITS` 从 16 抬到 17（mapper 侧地址不再静默截断），见第 9 节。注意这**只修地址，不修 banking**——`chr_bank_offset` 仍然没接进 PPU。

**当前进度、未实现项与证据边界以第 11 节为准。** 第 1-10 节写于背景通路落地之前，其中被实现取代的描述已在原地标注"已按事实更新"。

外部 CHR 的最终目的是把 `nes_mapper` 的 `chr_bank_offset` 接进 PPU，让 CNROM/MMC1 的 CHR 切换和 MMC3 的 A12 扫描 IRQ 在系统级可观测。现在 `nes_system_v5` 里 `ppu_addr` / `ppu_a12` 仍然绑 0，所以这些在系统级依然不可观测。

---

## 1. 已实现：接口骨架

### 1.1 `rtl/nes_core/ppu/nes_ppu2c02.v`

参数：

```verilog
parameter EXTERNAL_CHR = 1'b0
```

5 个新端口（`chr_rdata` 是唯一输入）：

| 端口 | 方向 | 位宽 | 说明 |
|---|---|---|---|
| `chr_req` | out | 1 | 取数请求，1 拍 `ce` 宽脉冲 |
| `chr_addr` | out | 14 | 请求期间保持不变的地址 |
| `chr_we` | out | 1 | 写使能（本轮不用，见 5.3） |
| `chr_wdata` | out | 8 | 写数据（本轮不用） |
| `chr_rdata` | in | 8 | 读回数据 |

CHR 通路被 `generate` 包成两个互斥分支：

```verilog
generate
    if (!EXTERNAL_CHR) begin : g_chr_internal
    end else begin : g_chr_external
    end
endgenerate
```

两个分支各自包含的内容：

| | `g_chr_internal` | `g_chr_external` |
|---|---|---|
| `ppu_space_read` | `< $2000` 读 `chr_ram[address[12:0]]` | `< $2000` **返回 `8'h00`**（未实现外部 CHR 的 `$2007` 读写） |
| `bg_pattern_low` / `bg_pattern_high` | `chr_ram[bg_pattern_addr]` / `+ 13'd8` | `(bg_ready && bg_pa_enable) ? bg_lo_q : 8'h00` / `bg_hi_q`（**已按事实更新**：不再是绑 `8'h00`） |
| `sprite_chr_bus` | `g_chr_flatten` 8192 份 `chr_ram` 组合拼成 65536 bit | `65536'd0`（内部路径的展平总线在外部模式下用不到） |
| `u_sprite` | `EXTERNAL_CHR=1'b0`、`chr_sh=8'h00`、`scanline_sel=scanline` | `EXTERNAL_CHR=1'b1`、`chr_sh=sp_chr_sh`（由 shadow 解复用）、`scanline_sel=scanline`（**已按事实更新**：不再绑 `8'h00`，但 `scanline_sel` 仍直连 `scanline`，见 11.3.1） |
| `chr_ram` 的 `$2007` 写 | 有 | **没有** |
| `chr_req` / `chr_addr` | 不存在（内部模式不发） | 背景 `nes_chr_fetch_unit` 与精灵 `nes_sprite_chr_fetch` 两个 master 的**组合优先 mux**（**已按事实更新**，`nes_ppu2c02.v:582-583`，精灵优先）；`chr_we` / `chr_wdata` 绑常数 `1'b0` / `8'h00` |
| 取数状态机 | 不存在（内部路径纯组合） | **有两个**：`nes_chr_fetch_unit u_chr_fetch`（`:386-400`）与 `nes_sprite_chr_fetch u_sprite_chr_fetch`（`:530-542`） |
| 平面锁存 | 不需要（直接组合读 `chr_ram`） | **有**：`bg_lo_q` / `bg_hi_q` / `bg_ready`（`:326-328`、`:405-417`）与 128 bit `sp_shadow` |
| `$2007` 读 + `increment_v` | 有 | 有 |

**（已按事实更新）`g_chr_external` 的背景取数逻辑已经实现，精灵预取单元也已经例化**，不再是"只把输出绑常数"。`chr_req` / `chr_addr` 由背景 `nes_chr_fetch_unit` 与精灵 `nes_sprite_chr_fetch` 两个 master 的**组合优先 mux** 驱动（`:582-583`），`chr_rdata` 已被真正读进 `bg_lo_q` / `bg_hi_q`（背景）与 `sp_shadow`（精灵），`bg_pattern_low` / `bg_pattern_high` 读的是锁存器。仍然绑常数的是 `chr_we = 1'b0` / `chr_wdata = 8'h00`（外部 CHR 只读），`sprite_chr_bus` 仍绑 `65536'd0`（内部路径的展平总线在外部模式下用不到）。**但精灵像素的正确性没有任何证据**：A/B TB 用的仍是全 0 透明精灵图案，且 shadow 差一行、8 位 `chr_sh` 只能交付一个字节。`nametable_ram` 的 `nt_fetch` 影子数组**已删除**，取数支路直接读 `nametable_ram` 的第二个组合读口。完整接线、取数节拍、像素级证据与仍未实现项见第 11 节。

### 1.2 `rtl/nes_core/ppu/nes_ppu_sprite.v`

| 改动 | 内容 |
|---|---|
| 参数 | `EXTERNAL_CHR`（默认 `1'b0`） |
| 新输入 | `chr_sh[7:0]`：外部模式下当前 slot 的 pattern 字节 |
| 新输入 | `scanline_sel[8:0]`：渲染链使用的 scanline |
| 新输出 | `pat_addr_o[103:0]`：8 slot × 13 bit。**已按事实更新**：`g_chr_external` 里它就是 `nes_sprite_chr_fetch` 的 `pat_addr` 输入，不再是"纯观测、无驱动用途" |
| 分支 | `g_chr_internal` 用 `chr[{s_pat_addr,3'b000} +: 8]` 取低平面、`+64` 取高平面；`g_chr_external` 两个平面都直接取 `chr_sh` |

`pat_addr_o` 每一段是 `s_pat_addr = {s_table, 5'b00000, s_tile, 1'b0, s_fine[2:0]}`，也就是**每个 slot 本行需要的那 1 个字节的地址**（`tile*16 + fine`）。外部预取器照着 `pat_addr_o` 发请求就能拿到正确的 16 个字节。**三处 CHR 地址约定必须指向同一批字节**，这一点是接线时踩过的坑：

| 处 | 写法 | 实际指向的字节 |
|---|---|---|
| `nes_ppu_sprite` 内部路径 | `chr[{s_pat_addr, 3'b000} +: 8]`，高平面 `+ 13'd64` | `chr` 是 65536 bit 扁平总线，`{pat,3'b000}` 是**位**索引且每 8 位一个字节 → 字节 `s_pat_addr`；`+13'd64` **位** = **+8 字节** |
| `nes_chr_fetch_unit`（背景） | `chr_addr = tile_base + (plane ? 8 : 0)` | 字节 `tile_base` / `tile_base + 8` |
| `nes_sprite_chr_fetch`（精灵） | `chr_addr = pat_addr` / `pat_addr + 8`，`& 14'h3FFF` | 字节 `pat_addr` / `pat_addr + 8` |

**这里曾有一个真实缺陷**：`nes_sprite_chr_fetch` 的 `plane_byte` 原来输出 `chr_addr = {pat + plane*8, 3'b000}`，把 pattern 地址当**位索引**再左移 3 位，而 `chr_addr` 是**字节**地址 → 地址整整偏 8 倍，同时 `chr_addr[13]` 永远为 0（外部 16 KiB CHR 的上半 8 KiB 取不到）。现已改为按字节算（`pat` / `pat + 8`，14 位回卷），`sprite-fetch-tb` 的独立重算同步更新，并加了一条"14 位地址字段必须被驱动起来否则 `$fatal`"的承重断言。

`scanline_sel` 的存在是因为预取发生在 hblank，而预取要算的是**下一行**的 slot。当前 `nes_ppu2c02` 两个分支都把 `scanline_sel` 接成 `scanline`，并保留了一条 X 兜底：

```verilog
assign scanline_chain = (^scanline_sel === 1'bx) ? scanline : scanline_sel;
```

这条兜底是给 TB 留的：外部模式的 TB 如果不驱动 `scanline_sel`，`pat_addr_o` 不会变成 X，`ppu-core` 的 elaboration 证据不会因为少接一根线而变红。

### 1.3 等价性与兼容性

- **`EXTERNAL_CHR = 0`（默认）时与改造前逐位一致。** `g_chr_internal` 分支的表达式、`g_chr_flatten` 的 8192 份组合读、`chr_ram` 写、`$2007` 读全部照抄原样，只是被挪进了 `generate` 里。`tools/sim_all.ps1` 的 `ppu-core`（编译）、`ppu-sprite`、`ppu-integration` 三个目标全绿，`system-v0`/`v1`/`v2`/`v3`/`v4`/`v5` 与 `platform-tb` 也全绿。

- **`reg [7:0] chr_ram [0:8191]` 必须留在 `nes_ppu2c02` 模块作用域，名字不能改。** 8 个 testbench 用层次化路径直接读写它：

  | testbench | 层次化写法 |
  |---|---|
  | `tb/ppu/tb_nes_ppu2c02.v` | `dut.chr_ram[...]` |
  | `tb/system/tb_nes_system_v0.v` | `dut.u_ppu.chr_ram[...]` |
  | `tb/system/tb_nes_system_v0_nmi.v` | `dut.u_ppu.chr_ram[...]` |
  | `tb/system/tb_nes_system_audio.v` | `dut.u_ppu.chr_ram[...]` |
  | `tb/system/tb_nes_system_v2.v` | `dut.u_ppu.chr_ram[...]` |
  | `tb/system/tb_nes_system_v3.v` | `dut.u_ppu.chr_ram[...]` |
  | `tb/system/tb_nes_system_v4.v` | `dut.u_ppu.chr_ram[...]` |
  | `tb/platform/tb_nes_ep4ce10_top.v` | `dut.u_nes.u_ppu.chr_ram[i]` |

  把它移进 `g_chr_internal`、改名、或者改成 `logic`，这 8 个 TB 会在 elaboration 阶段直接报错。这是硬性兼容约束，不是风格偏好。

- **`nes_ppu_sprite` 的 `chr` 端口必须仍然是 65536 bit**（`input wire [65535:0] chr`）。`tb/ppu/tb_nes_ppu_sprite.v` 直接用大向量 `chr` 灌 pattern 字节；缩窄它会改变这个 TB 的激励方式。`EXTERNAL_CHR` 分支只是让它不被读，不改它的宽度。

---

## 2. 时序合同与地址合成

2.1 的节拍合同**已落地并被 TB 断言**（`chr-fetch-tb` 的 1 拍地址预取断言 + `ppu-ext-chr-tb` 的 921,600 次逐 `ce` 比对）；2.2 的地址合成**仍未落地**。

### 2.1 节拍合同

| 项 | 规则 | 现状 |
|---|---|---|
| `ce_ppu` | 每 4 个 `clk` 一次（`nes_system_v5` 的 `div_phase` 给出） | 合同成立；`ppu-ext-chr-tb` 第 4 组配置用 `ce_div = 3` 实测过 |
| `chr_req` | 1 拍 `ce` 宽的脉冲，不是 `ce` 电平 | `ce` 连续时成立；**`ce` 有空洞时脉冲会被拉长到多个 `clk`**（`nes_chr_fetch_unit` 的 `ce` 门控直接后果），见 11.3.5 |
| `chr_addr` | 在 `chr_req` 期间寄存保持，请求结束后可以变 | 成立（`chr-fetch-tb` 的 A4 在全部 66 个请求拍上断言地址提前一个 `ce` 就是对的） |
| `chr_rdata` | 在**下一个** `ce` 有效，即同步读、1 dot 延迟 | 成立（TB 的 CHR 模型是 1 拍延迟存储器） |
| `chr_we` / `chr_wdata` | 本轮恒 0（见 5.3） | 成立，且被 `ppu-ext-chr-tb` 逐 `ce` 断言恒为 `1'b0` / `8'h00` |

### 2.2 地址合成（**仍未实现**）

- mapper 侧的 bank offset 由**组合**方式叠加：`chr_addr_final = chr_bank_offset + ppu_local_addr`。PPU 只负责给出 `ppu_local_addr[13:0]`，不负责 bank 选择。**这一条没有实现**——`nes_system_v5` 的 `ppu_addr` 仍绑 0，见 11.3.6。
- **`chr_addr[13]` 驱动 0。** 内部模式的 `ppu_space_read` 用的是 `chr_ram[address[12:0]]`，只有 13 bit，也就是 8 KiB 镜像；外部模式驱动 bit13 = 0 才能和它**逐位等价**。这条不是为了省一根线，是等价性要求。**当前成立**：`nes_chr_fetch_unit` 的 `chr_addr` 由 13 bit `tile_base` 加 8 bit 以内的平面偏移构成，bit13 恒 0（TB 的期望地址也只算到 `base + 8`）。

---

## 3. 背景取数：本节是设计推导，实际实现见第 11 节

**（已按事实更新）本节 3.1-3.6 是设计推导，背景取数已经实现，但实现方式与本节的部分设想不同**：不是"整行一次突发 + 行末锁存"（3.4/3.5），而是**逐 tile 的 9 拍流水**（见 11.1.2）；nametable 也没有复制第二份 2 KiB（3.3），改成直接读 `nametable_ram` 的第二个读口。**权威描述是第 11 节**，本节保留推导过程以便理解为什么是这样。

### 3.1 抽 `bg_x_total_f` 支路

当前背景取数是纯组合的：

```verilog
assign bg_x_total = {1'b0, dot} + {6'b0, fine_x} + ({4'b0, temp_addr[4:0]} << 3);
```

外部模式需要的是"下一个 dot"的那一份，所以抽一条**平行的** `bg_x_total_f = bg_x_total + 1` 支路出来，只喂给取数支路。原来的 `bg_x_total` 一根线都不动。

**（已按事实更新）** 实现上没有用 `bg_x_total_f` 这个名字，也没有用 `+1`：取数支路用自己的 `bg_dot_fine = dot + fine_x` 和 `bg_look_dot = dot + 9` 重算窗口起点（`nes_ppu2c02.v:330-340`）。**第 4 节那条 attribute 陷阱的规避原则仍然成立**：`bg_coarse_x` / `bg_coarse_y` / `bg_attribute_byte` / `bg_nametable` 全部留在 `dot` 上不动，只有发请求的那一份用前瞻 dot。

### 3.2 发射条件跟着 `fine_x` 漂移

`bg_pattern_bit = 3'd7 - bg_x_total[2:0]`，所以 tile 边界发生在 `bg_x_total[2:0]` 从 7 回卷到 0 的那一拍，即：

```verilog
发射条件 = (bg_x_total_f[2:0] == 3'd7)
```

**不能**把发射点固定在 dot 8 / 16 / 24 / ...。`fine_x` 非 0 时 tile 边界整体平移，固定发射会让 pattern 的行号和 tile 号错位。`fine_x` 是 `$2005` 写的 3 bit scroll，同一行里恒定，所以边界是"每 8 个 dot 一次、起点随 `fine_x` 平移"。

### 3.3 nametable 需要第二读口

`nametable_ram` 现在只有**一个**读口（`bg_name` 和 `bg_attribute_byte` 各一次组合读）。取数支路要在 `bg_x_total_f` 提前 1 dot 的位置上读同一个 tile 索引，组合上会形成第二个读口。

方案：**复制一份 2 KiB `nametable_ram`** 给取数支路单独用。代价是 2 KiB 片上存储翻倍（16 KiB → 2 份 × 2 KiB = 4 KiB，净增 2 KiB，约 2 个 M9K），换来的是取数支路与渲染支路**完全解耦**，不会出现读口仲裁，也让 `EXTERNAL_CHR = 0` 分支一行都不用改。

**（已按事实更新）复制方案没有被采用。** 实际做法是 `bg_name_target = nametable_ram[mirror_nametable(bg_nt_offset_target)]`（`nes_ppu2c02.v:355`），让 `nametable_ram` 直接带**两个组合读口**：一个给渲染支路（`bg_name` / `bg_attribute_byte`），一个给取数支路。代价是 `nametable_ram` 不能再推断成单口 BRAM；换来的是省掉 2 KiB 片上存储、去掉一条需要复位的影子链，并且两个读口天然看到同一份数据、不可能失同步。

### 3.4 寄存 + valid

```text
chr_req  ──┬─ dot N    : 发 nametable / pattern 请求
           └─ dot N+1  : chr_rdata 有效 → 打进 bg_lo_q / bg_hi_q，bg_valid_q 置 1
```

`bg_lo_q` / `bg_hi_q` 各 8 bit，配 1 bit `bg_valid_q`。渲染时读寄存器而不是读外部端口，所以 `ce` 之间外部总线怎么变化都不影响输出。

**（已按事实更新）寄存 + valid 已实现**，但 valid 的名字和位置与本节设想不同：脉冲来自 `nes_chr_fetch_unit` 的 `bg_valid`（`chr_fetch_bg_valid`），锁存寄存器在 PPU 侧叫 `bg_lo_q` / `bg_hi_q` / `bg_ready`（不是 `bg_valid_q`），见 `nes_ppu2c02.v:405-417`。之所以必须有这层锁存，是因为 `nes_chr_fetch_unit` 的 `bg_valid` 只在第 8 拍高 1 个 `ce`、没有握手，见 11.2。

### 3.5 dot 340 预取下一行的第一个 tile

可见区是 dot 0..255，`bg_shown = mask_reg[3] && ((dot >= 9'd8) || mask_reg[1])`。`mask_reg[1]`（左 8 像素显示）打开时 **dot 0-7 也要出像素**，但取数流水线需要 1 dot 提前量，dot 0 那一拍没有前序请求可用。

所以在**本行 dot 340**（hblank 末尾、下一行开始前）就把下一行的第一个 tile 打进 `bg_lo_q` / `bg_hi_q`。`bg_y_total` 只依赖 `scanline`、`temp_addr[9:5]`、`temp_addr[14:12]`，不依赖 `dot`，所以提前一整行取数不会引入 Y 方向的偏差。

**（已按事实更新）触发点从 dot 340 改成 dot 324。** 实际实现是 `bg_fetch_pre_first = (dot == 9'd324) && mask_reg[1]`，前瞻 `dot + 17` 正好落在下一行 dot 0（`nes_ppu2c02.v:332`、`:336`）。选 324 而不是 340 是因为 `dot 340 + 17 = 357` 会越过下一行的 dot 16，已经不是"第一个 tile"了。`bg_y_total` 不依赖 `dot` 这条理由仍然成立，实现里对应的是 `bg_scanline_nl` / `bg_y_total_nl` / `bg_coarse_y_sum_nl` 这一组"下一行"影子算式（`:341-348`）。

### 3.6 `bg_coarse_y_sum` 必须共用

```verilog
assign bg_coarse_y_sum      = {2'b0, temp_addr[9:5]} + {1'b0, bg_y_total[8:3]};
assign bg_vertical_sections = bg_coarse_y_sum / 7'd30;
assign bg_coarse_y          = bg_coarse_y_sum % 7'd30;
```

这三行**与 `dot` 完全无关**（`bg_y_total` 里没有 `dot`），所以取数支路直接复用同一组 wire。**不复制、不改写、不"顺手优化成查表"。** 一旦复制出第二份 `/30`、`%30`，两处就可能因为综合推断差异取到不同的 `bg_coarse_y`，而且这种错误在 fine scroll 跨 nametable 时才显形，极难定位。

**（已按事实更新）这条原则被执行了，但有一处必要的例外。** 同扫描线内的取数支路直接复用 `bg_coarse_y` / `bg_vertical_sections`（`nes_ppu2c02.v:349-352` 的 `bg_next_line ? ... : ...` 三元选择）；而"下一行第一个 tile"（dot 324 那个请求）**必须**有一份按下一行 `scanline` 重算的 `/30`、`%30`（`bg_coarse_y_sum_nl` / `bg_vertical_sections_nl` / `bg_coarse_y_nl`，`:344-346`），因为它取的是**下一行**的 tile，`scanline` 差 1。这不是"复制同一份算式"，所以不违反本节。TB 逐 `ce` 比对 A/B 的 `dbg_v` / `dbg_t` / `dbg_x` / `dbg_w` 以及全部 921,600 个像素，覆盖了这个跨行切换。

---

## 4. 等价性陷阱：不能把 `dot` 整体 mux 成 `dot+1`

这是本轮改造里**最容易踩、也最难在 TB 里看出来**的一个坑。

直觉写法是：

错误写法（直觉上"把 dot 整体提前一拍"）：

```verilog
assign eff_dot = EXTERNAL_CHR ? (dot + 1) : dot;
```

然后把 `eff_dot` 喂给整条背景通路。这样做会让 **`bg_attribute_byte` 早 1 dot 读**。因为 `bg_coarse_x`、`bg_coarse_x_sum`、`bg_nametable[0]`、`bg_nt_offset`、`bg_attr_offset` 全部由 `bg_x_total` 派生，它们必须和**当前** dot 严格同拍；只有 `bg_pattern_addr` 里的 `bg_name` 需要提前。整体 +1 会让 attribute 的 tile 坐标整体右移 1 个 dot，**每一行的 32 列都会取到错误的 attribute quadrant**（`{bg_coarse_y[1], bg_coarse_x[1]}` 选 2 bit 组）。

正确做法是 3.1 的"只抽前瞻支路"：`bg_coarse_x` / `bg_coarse_y` / `bg_attribute_byte` / `bg_nametable` 全部留在 `dot` 上不动，只有发请求的那一份用前瞻 dot。**（已按事实更新）** 实际实现用的是 `bg_look_dot = dot + 9` 这一组前瞻线（`nes_ppu2c02.v:336-357`），没有整体 mux `dot`。这条陷阱**已经被 921,600 次逐 `ce` 逐 dot 的像素比对证伪过一次**：`ppu-ext-chr-tb` 覆盖 `fine_x = 0/3/7` × `mask[1] = 0/1` × `coarse_x = 0/3/5/12/31` 共 5 组配置（其中 3 组 `mask[1] = 1`），全部一致。`chr-feasibility-tb` 的 Q3 反事实测量（整体 mux `dot+1` 会让 32 个 tile 列里恰好 16 列取错 attribute）仍然有效，是这条陷阱的独立证据。

一个可以自查的判据：把 `fine_x` 设成非 0 值、`mask_reg[1]` 打开，跑一帧混合图。如果第 8/16/24... 列和第 7/15/23... 列的属性组不连续，就是踩了这个坑。**（已按事实更新）这一条现在有自动判据**：`ppu-ext-chr-tb` 逐 `ce` 比对 A/B 的 `pixel_index` 与 `dbg_x`（`temp_addr[4:0]`），踩到这个坑会立刻 `$fatal` 而不是需要人眼看图。

---

## 5. 精灵 shadow 预取（**已接线，但有三条未处理的限制**）

**（已按事实更新）本节描述的 `dot 257..272` shadow 预取现在已经接进 `g_chr_external`**（`start = (dot == 9'd257)`，`shadow` 按 slot 解复用喂 `chr_sh`），不再是一行 RTL 都没有。但**精灵像素的等价性没有证据**：A/B TB 仍用全 0 透明精灵图案，且 shadow **差一行**、8 位 `chr_sh` 只能交付**一个字节**、仲裁**无握手无背压**。逐条见 11.3.1。

### 5.1 hblank 只有 85 dot

一行的 dot 0..340，hblank 是 **dot 256..340，共 85 dot**。精灵通路每 dot 组合重算 8 个 slot，但外部模式下它只能读一个 8 bit 端口（`chr_sh`），所以必须先取数再渲染。

### 5.2 整 tile 缓存放不下

一个 slot 渲染一整行需要 pattern 的 lo / hi 两个平面的全部 8 行。整 tile 缓存约需 **160 B**，折合 `160 / 85 = 1.88` 次访问/dot，超过 1 拍 1 次的预算。移位寄存器方案（每 dot 左移、逐位补 0）也需要同样的 160 B 在 85 dot 内灌完，同样放不下。

**所以只缓存"本行要用的那 1 个字节"。** 8 slot × 2 plane × 1 B = **16 B = 128 bit**，正好一个 `reg [127:0] sprite_chr_shadow`。

### 5.3 预取调度

```text
dot 257        单元打 start（busy 从这一拍起为 1）
dot 259..290   逐 slot 发 16 次请求（slot0.lo, slot0.hi, slot1.lo, ...）
               → 打进 shadow[slot*16 +: 16]
dot 291        busy 落下，背景重新占有总线（背景从 dot 253 起持有，
               下一个背景预取在 dot 324）
dot 292        shadow_valid 抬起
dot 1..256     渲染期，u_sprite 只读 shadow latch
```

**（已按事实更新）上面的窗口不是设计意图的复述，而是当前实现的实测事实**，推导写在 `nes_ppu2c02.v:16-48` 的模块头注释里：

- 背景的最后一个请求拍在 **dot 250**，从 **dot 253** 起占有总线；
- 精灵从 **dot 257** 发 `start`，`busy` 覆盖 **dot 257..291**，16 次请求落在 **dot 259..290**，`shadow_valid` 在 **dot 292** 抬起；
- 下一个背景预取在 **dot 324**。

因为 **253 < 257** 且 **291 < 324**，两个窗口互不重叠，所以"精灵优先"的优先级顺序**今天不改变任何背景行为**，背景的取数节拍、`bg_lo_q`/`bg_hi_q` 锁存与每一个背景像素与只接一个取数器时**逐位相同**。**但这条不重叠是触发表达式推出来的、不是总线协议给的**：一旦背景触发点、精灵 start dot 或任一取数器的 `ce` 预算发生变化，**背景请求拍会被静默丢弃且没有背压**（没有 ready 信号，`bg_fetch_due` 是脉冲），表现为那一个 tile 窗口显示错误的 tile。任何改动都必须先重推这三个窗口。

- 请求地址来自 `pat_addr_o[slot*13 +: 13]`，高平面地址 = `pat_addr_o + 8`（14 位回卷）——**注意这里的 `+ 8` 是字节**，与 `nes_ppu_sprite` 内部路径的 `+ 13'd64` **位**是同一件事，见 1.2 的三处约定表。
- `scanline_sel` **本应**在 dot 257..291 期间指向**下一行**；`nes_ppu_sprite` 已经为此加了 `scanline_sel` 输入和 `scanline_chain` 的 X 兜底，但 `nes_ppu2c02` 现在两个分支都把 `scanline_sel` 接成 `scanline`（`:556`），**所以预取拿到的是本行的 slot**——这就是 11.3.1 里的"差一行"。
- **`chr_we` / `chr_wdata` 保持 0。** 外部模式下 CPU 通过 `$2007` 写 CHR RAM 的通路不接（见 6.2），所以外部 CHR 在这一版里是只读的。留着端口是为了不推翻接口。

### 5.4 pre-render 行

**scanline 261（pre-render 行）发的请求取的是 scanline 0 的 slot。** 精灵通路在 261 上 `frame_active = (scanline < 240)` 为 0、不渲染，但 261 的 hblank 是为下一帧第 0 行做的准备。这一条如果不写对，**整帧第 0 行的 8 个精灵会显示上一帧残留或全 0**，而且只在精灵 Y = 0 的游戏里显形。

---

## 6. 时序预算

### 6.1 每行访问数

| 阶段 | 可用 dot | 访问次数 | 占用率 |
|---|---|---|---|
| 可见区背景 | 256 | 66（33 tile × 2 plane） | 25.8% |
| hblank 精灵 shadow | 85 | 16（8 slot × 2 plane） | 18.8% |
| 合计 | 341 | 82 B/行 | 24.0% |

背景的 66 次 = 32 个可见 tile + 1 个预取 tile，每个 tile 2 个 plane。精灵的 16 次 = 8 个 slot × 2 个 plane，每个 1 B。

### 6.2 帧级带宽

```text
82 B/行 × 262 行 × 60 Hz ≈ 1.29 MB/s
```

最坏情形（8 个 slot 各取 8×16 整 tile，即 256 B，加背景 66 B、精灵 shadow 16 B，约 338 B/行）在同一量级，设计记录值 **≈ 5.37 MB/s**。

### 6.3 相对 SDRAM 的余量

EP4CE10 的 SDRAM 按 100 MB/s 峰值算，1.29 MB/s 是 **77×** 余量，5.37 MB/s 是 **18.6×** 余量。

即便按 21.477 MHz × 16 bit 的窄桥算（峰值 43 MB/s，考虑仲裁和突发效率后实际吞吐约 22 MB/s），最坏情形仍留有 **4.2× 余量**。因此外部 CHR 走 SDRAM 在带宽上**不是瓶颈**，瓶颈只在 85 dot / 16 次访问的**时序密度**上。

---

## 7. 明确拒绝的方案

| 方案 | 拒绝理由 |
|---|---|
| **组合多口外部 CHR** | 保持现有"每 dot 组合重算 8 个 slot"的结构，需要 8 × 2 + 2 = **18 个并发读口**。组合 SRAM 不能映射到 BRAM，只能靠阵列复制：按本 PPU 的 8 KiB 片上 CHR RAM 算是 18 × 8 KiB = 144 KiB ≈ **128 M9K**；按 mapper 满映射 64 KiB 算是 18 × 64 KiB = 1152 KiB ≈ **1024 M9K**。EP4CE10 全部片上存储只有 46 M9K（423,936 bit），差 2.8× 到 22×。外部 SDRAM 也没有 1 dot 内的组合读时序。 |
| **整 tile 缓存 + 移位寄存器** | 每 slot 缓存 lo/hi 两平面的全部 8 行约需 160 B，85 dot 内要灌 160 B，即 1.88 访问/dot，超预算。见 5.2。 |
| **在 `nes_system_v5` 放 128 KiB `chr_rom`** | 128 KiB = 1,048,576 bit ≈ **114 M9K**，是全器件 46 M9K 的 2.5×。`PRG_SIZE_BYTES` 已经是 128 KiB，再加 128 KiB CHR 直接放不下。 |
| **本轮接真实 `ppu_a12`** | `tb/system/tb_nes_system_v5.v:1499-1507` 的断言**正是"`ppu_a12` 绑 0"的可观测证据**：`$C000` latch 07 + `$C001` reload 之后 IRQ 计数器不自计时、`$E001` 使能 / `$E000` 禁用并 ack 后 `mapper_irq` 全程为低。接上真实 `ppu_a12` 会让这条断言变红，把"设计还没做"变成"回归变红"。 |
| **把 `MIRROR_VERTICAL` 改成运行期端口** | 与外部 CHR 无关，是另一件事。`nes_ppu2c02` 现在的 mirroring 是 elaboration 期参数，`tb/system/tb_nes_system_v5.v:1475` 明确把它登记为"PPU 仍跑编译期 `MIRROR_VERTICAL=0`，v5 只观测不施加"。改端口会牵动所有 system TB 的 nametable 期望值，应该单独一轮做。 |

---

## 8. 已知行为差异（必须登记）

外部模式落地后，下面三条与内部模式**不等价**。它们是可接受的取舍，但必须写在这里，不能装作没有。

### 8.1 `$2007` 写 CHR RAM 后晚 1 dot

内部模式下 `chr_ram[v_addr[12:0]] <= reg_din` 在同一个 `clk` 沿生效，渲染的组合读立刻看到新值。外部模式下写入要先经过 SDRAM、再等 1 dot 同步读回来，**渲染看到新值晚 1 dot**。表现是"CPU 刚写完 CHR 就改 pattern"的那 1 个 dot 用旧字节。

### 8.2 `sprite_overflow` 变成"下一行计数"

内部模式下 `sprite_overflow` 是组合信号，由本行 `scanline` 的 OAM 范围比较直接得出。外部模式下 overflow 需要本行的 slot 预取结果，而预取在 hblank 才发生，所以它是**用下一行的 OAM 算出来的**。

好消息是这**不改变 `$2002` 的读值**：`nes_ppu2c02` 只在 `if (ce)` 里把 `sprite_overflow_raw` 打进粘滞的 `sprite_overflow_reg`，`$2002` 读的是这个寄存器。代价是置位点整体后移一行（真实硬件是 dot 64..256 评估窗口，本仓库本来就更早，见 README 的"明确未实现"）。

### 8.3 `$2007` 读 `$2000-$3FFF` 别名到 `$0000-$1FFF`

外部模式下 nametable 和 CHR 共用同一个取数端口，而端口地址的 CHR 判据是 `address < 14'h2000`、bit13 绑 0。于是 `$2007` 读 nametable 区（`$2000-$3EFF`）时，取回的字节是 CHR 空间里同一索引的值，也就是**别名到了 `$0000-$1FFF`**。palette 区（`$3F00+`，走 `palette_underlay_address`）不受影响。

后果：CPU 无法在外部模式下用 `$2007` 回读 nametable 内容。游戏极少这么干（nametable 一般只写不读），所以接受。

---

## 9. 已完成：`CHR_ADDR_BITS` 从 16 抬到 17

**这一条已执行。** 下面记录问题、改了哪几处、验收断言是什么，以及仍然没有做的部分。

### 9.1 问题

`nes_mapper.v` 的 `CHR_ADDR_BITS` 默认原来是 16，`nes_system_v5.v` 也是 16。两个 mapper 子模块在这个宽度里左移（`rtl/nes_core/mapper/nes_mapper_mmc1.v:65` 和 `rtl/nes_core/mapper/nes_mapper_mmc3.v:135`）：

```verilog
assign chr_bank_offset = (chr_bank_ext << 12) | {{(CHR_ADDR_BITS-12){1'b0}}, ppu_addr[11:0]};

assign chr_bank_offset = (chr_window_ext << 10) | {{(CHR_ADDR_BITS-10){1'b0}}, ppu_addr[9:0]};
```

MMC1 的 `chr_bank_ext` 是 5 bit（`chr_bank4k_select`，32 个 4 KiB bank = 128 KiB），`<< 12` 需要 17 bit；MMC3 的 `chr_window_ext` 是 8 bit（`chr_window_bank`），`<< 10` 需要 18 bit，但 MMC3 的 CHR 窗口实际只用 1 KiB 粒度的低 6 位，17 bit 够用。

在 16 位里左移会**静默截断**：

| mapper | 表达式 | 截断后果 |
|---|---|---|
| MMC1 | `chr_bank4k_select << 12` | bank ≥ 16（4 KiB 粒度）别名回低 64 KiB，128 KiB CHR 的上半段永远取不到 |
| MMC3 | `chr_window_bank << 10` | bank ≥ 0x40 别名回低 64 KiB |

### 9.2 改了哪几处

改动是纯位宽修正，不含任何架构决策，不改任何表达式。

RTL（2 处默认值 + 2 处模块头注释）：

| 位置 | 改动 |
|---|---|
| `rtl/nes_core/mapper/nes_mapper.v:10` | `parameter integer CHR_ADDR_BITS = 16,` → `= 17,` |
| `rtl/nes_core/mapper/nes_mapper.v:3-8` | 新增模块头注释，写明 17 bit = 128 KiB 是 MMC1 5 bit 4 KiB bank（最大 `0x1F000`）和 MMC3 8 bit 1 KiB 寄存器（`0x00-0xBF000`）的下界，调回 16 会重新引入别名 |
| `rtl/nes_core/system/nes_system_v5.v:11` | `parameter integer CHR_ADDR_BITS = 16,` → `= 17,`（它往下原样传给 `nes_mapper`） |
| `rtl/nes_core/system/nes_system_v5.v:3-9` | 新增模块头注释，写明该值只是地址偏移宽度、外部 CHR 取数仍未接线 |

TB 显式传参与观察线网（全部由 grep 逐处确认，不靠推测）：

| 位置 | 改动 |
|---|---|
| `tb/mapper/tb_nes_mapper.v:71`、`:126` | 两处 `.CHR_ADDR_BITS(16)` → `(17)`（`dut` 的 `nes_mapper` 与 `u_uxrom_reject` 的 `nes_mapper_uxrom`） |
| `tb/mapper/tb_nes_mapper.v:19`、`:50` | `wire [15:0] chr_bank_offset;` / `reject_chr_bank_offset;` → `[16:0]` |
| `tb/mapper/tb_nes_mapper_mmc1.v:50` | `.CHR_ADDR_BITS(16)` → `(17)` |
| `tb/mapper/tb_nes_mapper_mmc1.v:17` | `wire [15:0] chr_bank_offset;` → `[16:0]` |
| `tb/mapper/tb_nes_mapper_mmc3.v:63`、`:118` | 两处 `.CHR_ADDR_BITS(16)` → `(17)`（`dut` 的 `nes_mapper` 与 `u_mmc3_fall` 的 `nes_mapper_mmc3`） |
| `tb/mapper/tb_nes_mapper_mmc3.v:18` | `wire [15:0] chr_bank_offset;` → `[16:0]` |
| `tb/mapper/tb_nes_mapper_nrom128.v:42` | `.CHR_ADDR_BITS(16)` → `(17)` |
| `tb/mapper/tb_nes_mapper_nrom128.v:17` | `wire [15:0] chr_bank_offset;` → `[16:0]` |
| `tb/system/tb_nes_system_v5.v:7` | 新增 `localparam CHR_ADDR_BITS  = 17;`，与已有的 `localparam PRG_ADDR_BITS  = 17;`（`:6`）同一套写法，宽度单点定义 |
| `tb/system/tb_nes_system_v5.v:69`、`:120`、`:163` | `wire [15:0] nrom/uxrom/mmc3_mapper_chr_bank_offset;` → `wire [CHR_ADDR_BITS-1:0] ...` |

`tb/system/tb_nes_system_v5.v` **不显式传** `CHR_ADDR_BITS`，它吃的是 `nes_system_v5` 的新默认值 17；TB 里那个 `localparam` 单独定义为 17，两者不一致时 `iverilog` 会在 port 连接处报宽度不匹配，正好把漂移暴露出来。

`nes_mapper.v` 里的 `dbg_chr_bank_number = chr_bank_offset_r[CHR_ADDR_BITS-1:10]`（第 219 行）**没有改**，抬位宽后它自动变成 7 bit，MMC1 的 5 bit bank 和 MMC3 的 1 KiB 窗口都能正确显示。

5 个 mapper 子模块（`nes_mapper_nrom/cnrom/uxrom/mmc1/mmc3.v`）自己的 `CHR_ADDR_BITS` 默认值**仍然是 16，没有改**：它们不是独立可综合的顶层，`nes_mapper.v` 的每个实例都用 `.CHR_ADDR_BITS(CHR_ADDR_BITS)` 显式覆盖，TB 里唯一的直接实例 `u_mmc3_fall` 也已经显式传 17。改这 5 个文件不在本轮授权范围内，登记为遗留项。

### 9.3 验收断言

新增 `expect_distinct17` 任务（比较两个 17 bit 值是否不同，相同即判失败）加一个 `test_chr_bank_addr_bits17` 用例，两个 TB 各一条，核心断言都是**"写 bank A 与 bank B 之后 `chr_bank_offset` 必须不同"**：

| TB | 用例 | 断言 |
|---|---|---|
| `tb/mapper/tb_nes_mapper_mmc1.v:495` | `test_chr_bank_addr_bits17` | chr mode 0 下串行写 `$A000` 为 bank `0x00` → offset `17'h00000`；再写为 bank `0x10` → offset `17'h10000`；`expect_distinct17("chr bank 0 and 0x10 offsets differ", ...)`；`ppu_addr=14'h0FFF` 时 `17'h10FFF` |
| `tb/mapper/tb_nes_mapper_mmc3.v:504` | `test_chr_bank_addr_bits17` | `select_bank(0, 8'h00)` → offset `17'h00000`；`select_bank(0, 8'h40)` → offset `17'h10000`；`expect_distinct17("R0 bank 0x00 and 0x40 offsets differ", ...)`；`ppu_addr=14'h03FF` 时 `17'h103FF` |

这两条是这次修正的核心证据，因为它们**在 16 位下必然失败**：两个 offset 会一起被截断成同一个值。已实测确认（在临时副本里把 `CHR_ADDR_BITS` 退回 16，仓库文件未动）：

```
# MMC1 @ 16 bit
FAIL chr mode0 bank0x10 offset 10000: got 00000 expected 10000
FAIL chr bank 0 and 0x10 offsets differ: both chr_bank_offset are 00000
FAIL chr bank0x10 top of 4K window: got 00fff expected 10fff
FAIL tb_nes_mapper_mmc1 with 3 failing checks

# MMC3 @ 16 bit
FAIL R0 bank 0x40 offset 10000: got 00000 expected 10000
FAIL R0 bank 0x00 and 0x40 offsets differ: both chr_bank_offset are 00000
FAIL R0 bank 0x40 top of 2K window: got 003ff expected 103ff
FAIL tb_nes_mapper_mmc3 with 3 failing checks
```

17 位下两条都通过（`MMC1 chr bank 0x10 needs 17-bit offset PASS` / `MMC3 chr bank 0x40 needs 17-bit offset PASS`），并且**没有发现别的地方还在截断**——offset 的三个期望值（基址、窗口顶、跨 64 KiB 边界）都精确命中，说明 `chr_bank_ext`/`chr_window_ext` 的零扩展拼接和左移在 17 位里没有二次丢失。

其余回归（全绿）：

| 检查 | 结果 |
|---|---|
| `iverilog -g2001 -Wall -t null -s nes_mapper`（含 5 个子模块） | exit 0，零 error、零 warning |
| `iverilog -g2001 -Wall -t null -s nes_system_v5`（完整依赖闭包） | exit 0，零 error；仅 8 条 PPU 侧既有 warning（`@*` 对数组敏感，以及**当时**的 `nes_ppu2c02` 的 `chr_rdata` 悬空——`chr_rdata` 现在已被 `g_chr_external` 的平面锁存真正读过，见 11.1），与本次改动无关 |
| `.\tools\sim_all.ps1 -Mode mapper` | `PASS (4 of 4)` |
| `.\tools\sim_all.ps1 -Mode system` | `PASS (8 of 8)` |

位宽修正本身**零行为变化**：所有原有 offset 期望值都 < 64 KiB，抬到 17 bit 后逐位相同，所以 `mapper-*` 与 `system-v0`..`v5` 的既有断言一条没动也没破。

### 9.4 仍然没有做的部分

**位宽修完不等于外部 CHR 能用。** 下面这些里只有第 1、3 条的状态变了：

- ~~**外部 CHR 取数逻辑仍然一行都没写**~~ —— **（已按事实更新）背景取数已实现，精灵预取已接线**。`g_chr_external` 现在**同时**例化 `nes_chr_fetch_unit`（背景）与 `nes_sprite_chr_fetch`（精灵），`chr_req` / `chr_addr` 是精灵优先的**组合优先 mux**（`:582-583`，`sp_bus_sel = sp_busy`，**无握手无背压**），`chr_rdata` 被读进 PPU 侧 `bg_lo_q` / `bg_hi_q` / `bg_ready`（背景）与 `sp_shadow`（精灵）；`nt_fetch` 影子数组已删除，改直接读 `nametable_ram` 第二读口。**但** `chr_we = 1'b0` / `chr_wdata = 8'h00`、`$2007` 对外部 CHR 读恒得 0 / 写被丢弃，**精灵像素的等价性仍然没有证据**。接线、取数节拍与像素级证据见第 11.1 节，未实现项见 11.3 节。
- **`chr_bank_offset` 仍然没接进 PPU**。`nes_system_v5` 的 `ppu_addr`/`ppu_a12` 仍绑 0，所以 CNROM/MMC1 的 CHR 切换在系统级依旧不可观测，MMC3 的 A12 扫描 IRQ 计数器在系统级依旧无法被时钟。这次抬位宽只是把 mapper 输出的**地址**修对，没有产生任何新的可观察行为。**这一条完全没有变**，见 11.3.6。
- ~~**没有任何 TB 把 `EXTERNAL_CHR` 设成 `1'b1`**~~ —— **（已按事实更新）现在有了**。`tb/ppu/tb_nes_ppu2c02_ext_chr.v`（回归目标 `ppu-ext-chr-tb`）在同一 testbench 里例化 `EXTERNAL_CHR=1'b0` 与 `EXTERNAL_CHR=1'b1` 两个 `nes_ppu2c02` 做 A/B 比对，5 组配置 × 3 帧、921,600 次逐 `ce` 逐 dot 的 `pixel_index` + `bg_pa_enable` 比对全部一致。**但它只覆盖背景**——精灵、`$2007` 外部 CHR 写、mapper banking 都仍未覆盖或未实现，见 11.3。
- **5 个 mapper 子模块自己的 `CHR_ADDR_BITS` 默认值仍是 16**（见 9.2 末段）。目前全靠 `nes_mapper.v` 的显式覆盖，没有直接实例化它们的顶层设计，但这是留给下一个人的陷阱。
- **MMC3 8 bit CHR 寄存器上限 256 KiB 仍会截断**。17 bit 只覆盖 128 KiB；写 `0xC0` 以上的 bank 依然会回绕。这是"取 17 而不是 18"这个选择的已知代价，不在本轮范围内。
- 第 10 节的落地顺序因此**只剩第 3-4 步**：第 1 步（抬位宽）与第 2 步（背景取数 + A/B 逐像素等价）都已完成。

---

## 10. 落地顺序（按当前状态）

1. ~~先把 `CHR_ADDR_BITS` 抬到 17~~ —— **已完成**，见第 9 节（实际改了 2 处 RTL 默认值 + 6 处 TB 显式传参 + 1 处新增 `localparam` + 8 处观察线网位宽，另加 2 处模块头注释）。
2. ~~实现背景取数支路（3.1 - 3.6），只接 BG，sprite 仍走 `chr_sh = 8'h00`。用一个"外部 CHR = 内部 `chr_ram` 镜像"的 TB 模型，要求 `EXTERNAL_CHR = 1` 的整帧像素与 `EXTERNAL_CHR = 0` **逐像素相同**。~~ —— **已完成**。实现方式与 3.1-3.6 的设想有出入（逐 tile 流水而非整行突发、nametable 第二读口而非复制、dot 324 而非 dot 340），见 11.1.2；`ppu-ext-chr-tb` 在 5 组配置 × 3 帧下做了 921,600 次逐 `ce` 逐 dot 的 A/B 像素比对，全部一致，见 11.1.3。**这一句描述的是背景落地时的状态**：现在精灵也已接线（`chr_sh` 由 shadow 驱动），但精灵像素的等价性仍然没有证据，见 11.3.1。**
3. 实现精灵 shadow 预取（5.3 - 5.4）。**取数与接线这一步已完成**（`g_chr_external` 例化 `nes_sprite_chr_fetch`、dot 257 发 `start`、`shadow` 解复用喂 `chr_sh`、组合优先 mux、每行 16 次请求已验证），**但"整帧逐像素相同"这一步没有做，也没有证据**——11.3.1 列的四条限制（精灵像素无证据 / shadow 差一行 / 8 位 `chr_sh` 单字节 / 仲裁无背压）必须先解决，然后把 A/B TB 从全 0 透明精灵图案换成**非透明图案**再重跑同一套判据，并补精灵可见性自检与 8×16 / 每行 8 个上限 / overflow / 翻转的覆盖。
4. 最后在 `nes_system_v5` 里接 `chr_bank_offset` 组合叠加，并同步处理 `tb_nes_system_v5.v:1499-1507` 那条 `ppu_a12` 断言。**未开始。**

第 2 步的"逐像素相同"是这个改造唯一有意义的验收标准：它同时覆盖了第 4 节那个 attribute 陷阱和 3.6 那个 `bg_coarse_y` 共用陷阱。

**（已按事实更新）这一条现在有自动判据。** 第 2 步已达成时，`ppu-ext-chr-tb` 逐 `ce` 比对 A/B 的 `pixel_index`、`bg_pa_enable`、`pixel_valid`、`pixel_x`/`pixel_y`、`dot`/`scanline`、`dbg_v`/`dbg_t`/`dbg_x`/`dbg_w`，并逐个核对 337,450 次 `chr_req` 的地址与 126,546 对锁存平面字节。**第 3 步要用非透明精灵图案重跑同一套判据；第 4 步还要另外解决 11.3.3（渲染期 scroll 写）与 11.3.4（复位后第 0 帧 warm-up）。**

---

## 11. 实施进度

本节记录截至当前仓库状态的实际进度。措辞以 `rtl/nes_core/ppu/nes_ppu2c02.v`、`rtl/nes_core/ppu/nes_chr_fetch_unit.v`、`rtl/nes_core/ppu/nes_sprite_chr_fetch.v`、`tb/ppu/tb_nes_ppu2c02_ext_chr.v` 和 `tools/sim_all.ps1` 的实际内容为准，不做美化。

第 1-10 节写于外部 CHR 通路落地**之前**，其中若干处描述已被本节的实现取代（已在原地标注"已按事实更新"并指向本节）。**第 11 节是当前状态的唯一权威描述。**

### 11.1 已实现：背景外部 CHR 取数通路（有像素级证据）

**背景（不含精灵）的外部 CHR 取数已经实现，并且第一次有了像素级等价证据。** 回归目标 `ppu-ext-chr-tb`（`-g2012`，源文件**五条**：`nes_ppu_sprite.v` + `nes_ppu2c02.v` + `nes_chr_fetch_unit.v` + **`nes_sprite_chr_fetch.v`** + `tb\ppu\tb_nes_ppu2c02_ext_chr.v`——`nes_ppu2c02` 的 `g_chr_external` 现在同时例化两个取数单元，少列任何一个都会在 elaboration 阶段报 `Unknown module type`）打印 `PASS tb_nes_ppu2c02_ext_chr`，单目标实测 **162.5 s**、占全量 **16.83%**，仍是当前 `-Mode all` 里最慢的目标（上一轮 821.6 s / 45.26%，更早一轮 143.7 s / 15.0%）。**R-08 关闭后**（`nes_ppu2c02` 不再重复实现 `nes_ppu_sprite` 已有的精灵范围扫描，改为消费新导出的 `cur_slot_o`），这个目标从 821.6 s 降到 162.5 s、占全量从 45.26% 降到 16.83%，全量从 1815.3 s 降到 965.6 s；**A/B 的四行输出逐字节未变**。详见 11.3.8。

#### 11.1.1 接线方式

| 项 | 位置 | 内容 |
|---|---|---|
| 取数状态机 | `nes_ppu2c02.v:386-400` | `g_chr_external` **例化 `nes_chr_fetch_unit u_chr_fetch`**：`req_start = bg_fetch_due`、`tile_base = bg_tile_base`、`chr_req`/`chr_addr` 直接就是 PPU 的两个输出端口、`chr_rdata` 直接就是 PPU 的输入端口 |
| 平面锁存 | `nes_ppu2c02.v:326-328`、`:405-417` | PPU 侧 `bg_lo_q` / `bg_hi_q` / `bg_ready` 三个寄存器，在 `chr_fetch_bg_valid` 那一拍把 `bg_lo`/`bg_hi` 锁进去并把 `bg_ready` 置 1；复位清零 |
| 消费点 | `nes_ppu2c02.v:359-360` | `bg_pattern_low = (bg_ready && bg_pa_enable) ? bg_lo_q : 8'h00`，`bg_pattern_high` 同理 |
| nametable 读口 | `nes_ppu2c02.v:355` | `bg_name_target = nametable_ram[mirror_nametable(bg_nt_offset_target)]`，**直接读 `nametable_ram` 的第二个组合读口** |
| 单口总线的第二个 master | `nes_ppu2c02.v:530-542`、`:582-583` | `g_chr_external` **例化 `nes_sprite_chr_fetch u_sprite_chr_fetch`**（`start = (dot == 9'd257)`），`chr_req`/`chr_addr` 是 `assign chr_req = sp_bus_sel ? sp_chr_req : bg_chr_req;` / `assign chr_addr = sp_bus_sel ? sp_chr_addr : bg_chr_addr;` ——**组合优先 mux、精灵优先、没有握手也没有背压** |
| 仲裁窗口（实测） | `nes_ppu2c02.v:16-48` 模块头注释 | 背景最后一个请求拍在 dot 250、从 dot 253 起占有总线；精灵 `busy` 覆盖 dot 257..291、16 次请求落在 dot 259..290；下一个背景预取在 dot 324。**253 < 257 且 291 < 324，两个窗口不重叠**，所以优先级顺序今天不改变任何背景行为 |
| 背景侧的应对 | `nes_ppu2c02.v:582-583` | 背景拍在 mux 输出上额外被 TB 断言"mux 不得篡改持有者地址"（`chr_addr == bg_chr_addr`），精灵拍同理断言 `chr_addr == sp_chr_addr` 并单独计数，dot 340 断言**每行恰好 16 次** |

**`nt_fetch` 影子数组已删除。** 早期版本在 `g_chr_external` 里另存一份 2 KiB `nt_fetch[0:2047]` 给取数支路专用读口（3.3 节记的旧方案）。现在改成直接读 `nametable_ram`，因此**"影子数组没有复位、也没从 `nametable_ram` 同步、仿真里全 X 直到 CPU 把整张 nametable 写一遍"这条问题不再存在**——取数支路与渲染支路读的是同一份存储。代价是 `nametable_ram` 变成两个组合读口（不能再推断成单口 BRAM），换来的是省掉 2 KiB 片上存储和一条会失同步的影子链。3.3 节描述的"复制一份 2 KiB"**没有被采用**。

#### 11.1.2 取数节拍：流水式，不是每行一次突发

**这一条是本轮实现里最容易做错的地方。** 3.4 / 3.5 设想的是"整行一次取完 + 行末锁存"，实际落地的是**逐 tile 流水**：每个 tile 窗口单独打一次 `req_start`，请求在窗口开始前 9 拍就发出去，取回的字节在窗口开始时已经在 `bg_lo_q` / `bg_hi_q` 里。

可见区的 tile 窗口起点是

```text
b_k = 8k - fine_x          (k = 0, 1, 2, ...)
```

即 `fine_x` 非 0 时整行窗口整体平移。触发条件在 `nes_ppu2c02.v:330-334`：

```verilog
assign bg_dot_fine    = dot + {6'b0, fine_x};
assign bg_fetch_mid   = (bg_dot_fine[2:0] == 3'd7) && (dot <= 9'd246);
assign bg_look_dot    = bg_fetch_pre_first ? (dot + 9'd17) : (dot + 9'd9);
```

**请求必须在 `b_k - 9` 那一拍发出**：`(b_k - 9) + fine_x ≡ 7 (mod 8)` 成立时 `bg_fetch_mid` 触发，而 `bg_look_dot = dot + 9` 恰好落在窗口起点 `b_k` 上。**不能**把请求固定在 dot 8 / 16 / 24…（第 4 节那条 attribute 陷阱的同源问题：`fine_x` 非 0 时 tile 边界整体平移）。

下一行的第一个窗口单独处理：**在固定的 dot 324 提前 17 拍发出**（`bg_fetch_pre_first = (dot == 9'd324) && mask_reg[1]`，此时 `bg_look_dot = 324 + 17 = 341`，即下一行 dot 0），因为 `mask_reg[1]` 打开时 dot 0..7 也要出像素，而流水需要提前量、dot 0 那一拍没有前序请求可用。跨行时 `bg_target_dot` / `bg_coarse_y_target` / `bg_fine_y_target` / `bg_nametable_target[1]` 全部切到"下一行"那一组（`bg_scanline_nl`、`bg_y_total_nl`、`bg_coarse_y_sum_nl`，scanline 261 取 0），`bg_fetch_pre_second = (bg_dot_fine == 9'd340)` 负责 fine_x 较大时漏掉的溢出窗口。

**每行的 tile 数规则**（TB 用同一算式交叉核对，`tb_nes_ppu2c02_ext_chr.v:532-539` 有一条自检断言要求两种写法恒等）：

```text
tile_count_per_line = (fine_x == 0 ? 30 : 31) + 1 + mask_reg[1]
                   = 31 / 32 / 32 / 33
```

| `fine_x` | `mask_reg[1]` | 每行 tile | 每行 `chr_req` 拍（= 2 × tile） |
|---|---|---|---|
| 0 | 0 | 31 | 62 |
| 0 | 1 | 32 | 64 |
| ≠0 | 0 | 32 | 64 |
| ≠0 | 1 | 33 | 66 |

5 组配置实测打印的正是 `62/line`、`64/line`、`64/line`、`66/line`。

#### 11.1.3 像素级等价证据

`tb/ppu/tb_nes_ppu2c02_ext_chr.v`（648 行，`$finish` 在第 640 行）在一个 testbench 里例化**两个** `nes_ppu2c02`，共用同一份 `clk` / `ce` / 寄存器激励：

| 实例 | 参数 | 外部 CHR 端口 |
|---|---|---|
| `dut_a` | `EXTERNAL_CHR(1'b0)` | 不接（`chr_rdata` 绑 `8'h00`） |
| `dut_b` | `EXTERNAL_CHR(1'b1)` | 全部接出，`chr_rdata` 由 TB 的一拍延迟 CHR 模型驱动（`chr_rdata_q <= chr_mem[addr_b[12:0]]`） |

TB 用**层次化预载**把 `dut_a.chr_ram` / `dut_b.chr_ram` / `chr_mem` 三份写成同一批数据（`chr_mem[0..511] = 8'h00`，其余 `(~k[7:0]) ^ 8'h5A ^ cfg_seed`），nametable 30×32 按 `(row*7 + col*3 + seed) & 8'hFF` 生成，attribute 交替 `1B` / `E4`，palette 32 项线性，64 个 OAM 项 tile 号与 attribute 全为 `8'h00`。

5 组配置：

| case | `PPUCTRL` | `PPUMASK` | `coarse_x` | `fine_x` | `coarse_y` | `ce` |
|---|---|---|---|---|---|---|
| `base-fx0-mask1E` | `00` | `1E` | 0 | 0 | 0 | 每拍 |
| `fx3-cx5` | `00` | `1E` | 5 | 3 | 0 | 每拍 |
| `spr16-cx12` | `20` | `1E` | 12 | 0 | 4 | 每拍 |
| `cx31-fx7-table1` | `10` | `1E` | 31 | 7 | 0 | **1-in-4**（`ce_div = 3`） |
| `left8clip-mask1C` | `00` | `1C` | 3 | 0 | 6 | 每拍 |

每组跑 **1 帧 warm-up + 3 帧比对**（`WARMUP_FRAMES = 1`、`COMPARE_FRAMES = 3`、`TOTAL_FRAMES = 4`），warm-up 那帧不比对像素（原因见 11.4）。

**逐 `ce` 逐 dot 比对的内容**（任何一条不一致立刻 `$fatal`）：

| 比对项 | 说明 |
|---|---|
| `pixel_index` | 可见区（`scanline < 240 && dot < 256`）**每一个 `ce`** 都比，不抽样 |
| `bg_pa_enable` | 每个 `ce` 都比（覆盖整帧，不只可见区） |
| `pixel_valid` / `pixel_x` / `pixel_y` | 每个 `ce` 都比 |
| `dot` / `scanline` | 逐 `ce` 比，任一时刻分叉即 fatal（时基不允许漂） |
| `vblank` / `nmi_o` / `frame_done` | 逐 `ce` 比 |
| `dbg_v` / `dbg_t` / `dbg_x` / `dbg_w` | scroll 内部状态逐 `ce` 比 |
| `dbg_sprite0_hit` / `dbg_sprite_overflow` | 逐 `ce` 比（透明精灵图案下两者恒 0，见 11.3.1 第 1 条） |
| `chr_we` / `chr_wdata` | 必须恒为 `1'b0` / `8'h00` |
| `bg_pattern_low` / `bg_pattern_high` | `bg_pa_enable = 0` 时必须为 `8'h00`；`bg_pa_enable = 1` 且已在比对帧内时 `bg_ready` 必须为 1 |
| `chr_req` 的地址 | 每个请求拍都与"由 A 侧 `fine_x` / `temp_addr` / `bg_y_total` / `bg_coarse_y` / `bg_vertical_sections` **独立重算**出来的期望 tile base + 平面偏移（低平面 +0、高平面 +8）"比对，触发点或地址错开一位即 fatal |
| 锁存字节 | `bg_valid` 脉冲后一拍把 `bg_lo_q` / `bg_hi_q` 与 `chr_mem[lo_addr]` / `chr_mem[hi_addr]` 逐字节比对 |
| 每行计数 | dot 340 逐行核对"tile 取数次数 = 期望 tile 数"与"`chr_req` 拍数 = 2 × tile 数"，并核对"A 侧实际显示的 tile 数 = B 侧取数次数 + 跳过的首 tile 数" |
| 流水不丢触发 | `bg_fetch_due` 与 `chr_fetch_busy` 同时为 1 在比对帧内即 fatal（触发被吞 = 流水线失步） |
| **按总线归属分开校验（本轮新增）** | 每个 `chr_req` 拍先判 `sp_bus_sel`（`tb_nes_ppu2c02_ext_chr.v:438-460`）：精灵拍断言 `chr_addr` 等于 `sp_chr_addr`（**mux 不得篡改持有者地址**）并单独计数；背景拍在原有的独立重算地址断言之外**同样**断言 `chr_addr` 等于 `bg_chr_addr` |
| **每行 16 次精灵请求** | dot 340 断言 `sp_line_req === 16`（`:504-506`），与背景的 `line_req = 2 × tile 数` 分开计 |

**实测输出**：

```text
A1 total compared pixels=921600 nonzero_index=402348 nonzero_A_low_plane_cycles=715080
A2 lines_checked=3930 total_requests=337450 total_plane_latches=32487 (last case 62/line from 31 tiles)
A3 verified request addresses=337450 verified latched plane pairs=126546
PASS tb_nes_ppu2c02_ext_chr
```

| 数字 | 含义 |
|---|---|
| **921,600** | 可见区逐 `ce` 逐 dot 的 `pixel_index` + `bg_pa_enable` 比对次数（5 组 × 3 帧 × 240 × 256 = 5 × 3 × 61440），**全部一致** |
| 402,348 | 其中 `pixel_index != 0` 的次数——**比对不是空的**，43.6% 的像素是非背景色 |
| 715,080 | A 侧低平面 pattern 字节非 0 的 `ce` 数——pattern 数据真的被取回来了，不是全 0 |
| **337,450** | 被逐个核对地址的 `chr_req` 拍数 |
| **126,546** | 被逐字节比对的低/高平面对数 |
| 3,930 | 逐行核对取数次数的行数（5 组 × 3 帧 × 262 行） |
| 421,290 | 各 case 的 `requests` 合计（含精灵拍）——减去 A2 的 337,450 得 **83,840 = 5 帧 × 262 行 × 16**，与精灵请求总量精确吻合 |

**外部 CHR 背景通路第一次有了像素级证据。** 本节取代早期版本里"像素级外部 CHR 等价性一条证据都没有"那句话。

**这 921,600 次比对在本轮没有扩大覆盖范围。** 四行输出与上一轮**逐字节相同**，新增的断言全部落在接线与总线归属层面；被比较的仍然只是背景通路，**精灵像素一条证据都没有**（见 11.3.1）。

### 11.2 `nes_chr_fetch_unit` 接口的三条限制，以及 PPU 侧的对策

`nes_chr_fetch_unit` 本身**没有改**（仍是 6 态 FSM + `bg_lo` / `bg_hi` / `bg_valid` 三个输出口 + 6 bit `tile_count`）。它的接口形状决定了 PPU 侧必须这么接：

| 限制 | 事实 | PPU 侧对策 |
|---|---|---|
| **只暴露最后一个 tile** | `bg_lo` / `bg_hi` 是"行末那个 tile"的寄存器；`tile_count > 1` 时前面 `tile_count-1` 个 tile 的字节确实取回来了，但**没有任何端口把它们交出来** | 因此 `nes_ppu2c02.v:392` 把 `tile_count` **按 1 使用**（`.tile_count(6'd1)`），每个 tile 窗口单独打一次 `req_start`，靠 11.1.2 的 9 拍流水节拍把单 tile 取数摊开到一整行上。`tile_count` 那个"可数到 33"的 6 bit 端口在 PPU 侧**没有用上** |
| **延迟 8 个 `ce`** | `req_start` 被接受的那一拍算第 1 拍，`tile_count = 1` 要走 `S_IDLE → S_PRE → S_ARM → S_BEAT → S_GRAB → S_BEAT → S_GRAB → S_DONE` 共 8 拍，`bg_valid` 才在第 8 拍抬起 | 这 8 拍由流水节拍吸收：请求在 `b_k - 9` 发出，字节在 `b_k - 1` 锁进 `bg_lo_q` / `bg_hi_q`，`b_k` 那一拍已经在用 |
| **`bg_valid` 是脉冲** | `S_DONE` 只执行一拍，`bg_valid <= 1'b1` 下一拍进 `S_IDLE` 就被清掉；`bg_lo` / `bg_hi` 本身保持不变，但**没有"数据仍然有效"的握手** | PPU 侧必须配锁存：`bg_lo_q` / `bg_hi_q` / `bg_ready`（`nes_ppu2c02.v:405-417`）在 `bg_valid` 那一拍把数据接住，之后一直保持到下一次 `bg_valid` |

### 11.3 仍未实现 / 仍未覆盖

**下面每一条都是当前真实状态，不得弱化。**

#### 11.3.1 精灵通路已接线，但精灵像素的等价性完全没有证据

**这一条是当前最重要的限制，不得弱化。** 精灵预取单元**已经接进 `g_chr_external`**，但"外部模式能正确渲染精灵"这句话**没有一条证据支撑**。

| 项 | 现状 |
|---|---|
| `nes_sprite_chr_fetch` 例化 | **有**，`nes_ppu2c02.v:530-542`，`start = (dot == 9'd257)`（`:522`） |
| `sprite_pat_addr_bus` | **有消费者**——它就是 `u_sprite_chr_fetch` 的 `pat_addr` 输入（`nes_ppu_sprite` 的 `pat_addr_o` 导到 PPU 层再进预取单元，`:563` / `:535`） |
| `sprite_chr_bus` | `nes_ppu2c02.v:551` 仍绑 `65536'd0`（内部路径的展平总线在外部模式下用不到；`nes_ppu_sprite` 的 `g_chr_external` 分支不读它） |
| `chr_sh` | **不再绑 `8'h00`**，改由 `sp_chr_sh` 驱动（`:528`、`:552`） |
| `dot 257..272` shadow 预取（5.1-5.4） | **已实现**，但窗口实测是 **dot 257 发 start / dot 259..290 发 16 次请求 / dot 291 落 busy / dot 292 抬 `shadow_valid`**，与 5.3 原始设想的 `257..272 / 273..340` 划分不同 |

**四条必须记下来的限制：**

1. **精灵像素的等价性没有证据 —— 根因是 A/B TB 用的仍然是透明精灵图案。** `tb_nes_ppu2c02_ext_chr.v` 把全部 64 个 OAM 项的 tile 号设成 `8'h00`、attribute 设成 `8'h00`，而 `chr_mem[0..511]`（8×8 tile 0、8×16 的下半、以及 sprite pattern table 0/1 的前 512 字节）全为 `8'h00`，所以 **A 侧的精灵同样全是透明图案**（`chr_ram` 预载成同一批数据）。两个实例的 `dbg_sprite0_hit` 与 `dbg_sprite_overflow` 因此逐 `ce` 恒为 0 且互相一致。**921,600 次像素比对只证明背景通路**；`mask_reg[4]` 打开时外部模式的画面与内部模式**必然不同**，而这一点现在没有被任何 TB 断言为差异，只是被测试图案绕开了。
2. **shadow 差一行。** `pat_addr_o` 由 `nes_ppu_sprite` 从 `scanline_sel` 算出，而 PPU 两个分支都把 `scanline_sel` 接成 `scanline`（`:556`）；fetch 在同一行的 dot 292 才落地。所以**一行消费的 shadow 实际上是上一行 dot 257 锁存的那一份**。修法有两条：`pat_addr_o` 用下一行的 scanline 算（`scanline_sel` 接 `scanline + 1`，scanline 261 取 0），或者 `start` 提前一行发。两者都要改 `nes_ppu_sprite` / 集成层，不是 mux 能解决的。
3. **8 位 `chr_sh` 只能交付一个字节。** `nes_ppu_sprite` 的 `g_chr_external` 分支**两个平面都直接取 `chr_sh`**（`assign s_plane_lo = chr_sh; assign s_plane_hi = chr_sh;`），所以 PPU 侧必须二选一。当前做法是取 `shadow[g*16 +: 8] | shadow[g*16+8 +: 8]`（`:526-528`）——**按位或**——这让精灵轮廓是精确的，但把每一个不透明像素强制成 palette index `3`（低/高平面两位同时为 1），高平面实际上**根本没有被交付**。要真正交付双平面必须加宽 `nes_ppu_sprite.v` 的 `chr_sh`（例如 16 bit，或每 slot 两个 8 bit 端口），**而该模块的端口形状已被 `tb/ppu/tb_nes_ppu_sprite.v` 锁定**，这是一次跨 TB 的改动。`sp_shadow_valid` 门控是必须的：`nes_sprite_chr_fetch` 的 `shadow` 寄存器**没有复位**，第一行完成之前它是 X，X 送到 `chr_sh` 会让 `slot_opaque` / `sprite_pixel` 变 X 并污染像素。
4. **仲裁无握手、无背压。** `sp_bus_sel = sp_busy` 的组合优先 mux 只在两个窗口不重叠时正确（见 11.1.1）。一旦重叠，**背景请求拍会被静默丢弃**：单元继续计数、`bg_valid` 仍晚 1 拍抬起，于是 `bg_lo_q`/`bg_hi_q` 锁进错误的字节、那个 tile 窗口显示错误的 tile，而**没有任何机制会报告**。反之若改成背景优先，丢的就是精灵的 16 拍，整行精灵图案错位。

**后续做法（下一轮要做的事，按顺序）：**

- 把 `tb_nes_ppu2c02_ext_chr.v` 的 OAM tile 号 / attribute 与 `chr_mem[0..511]` 换成**非透明图案**（例如 tile 号打散、attribute 覆盖 palette 组、CHR 字节用可辨识图样），并加一条**精灵可见性自检**——先断言"A 侧在这些 OAM 下确实有非背景精灵像素"（例如 `pixel_index` 落在 palette 3..15 的计数 > 0、或者逐 slot 断言某个 sprite 的 8 个像素等于期望颜色），否则"改图案"可能仍然改出一张全透明的帧，A/B 一致仍然是空的。
- 修 shadow 差一行（第 2 条），修完之后重跑同一套 921,600 次比对。
- 加宽 `nes_ppu_sprite.v` 的 `chr_sh` 以交付双平面（第 3 条），同步改 `tb/ppu/tb_nes_ppu_sprite.v`。
- 补精灵专项覆盖：**8×16**、**每行 8 个 sprite 上限**（第 9 个之后的 sprite 不渲染）、**sprite overflow**、**水平/垂直翻转**。这些在外部模式下都还没有任何证据。
- 第 10 节第 3 步的"整帧逐像素相同"在**精灵打开时**现在仍然不可能成立。

#### 11.3.2 `$2007` 写 CHR 仍被丢弃

`chr_we = 1'b0` / `chr_wdata = 8'h00`（`nes_ppu2c02.v:402-403`），`g_chr_external` 里**没有** `chr_ram` 写 always 块，`ppu_space_read` 对 `address < 14'h2000` 返回 `8'h00`（`:290-291`）。所以：

- 外部模式下 `$2007` **读** CHR 恒得 0；
- 外部模式下 `$2007` **写** CHR 被静默丢弃；
- TB 靠**层次化预载** `dut_b.chr_ram` 喂 CHR（`:329-337`），**完全没有经过 `$2007` 通路**。

第 8 节 8.1 登记的"`$2007` 写 CHR 后渲染晚 1 dot"因此**既没被实现也没被验证**。

#### 11.3.3 渲染期间的 `$2005` scroll 写会移动触发相位，TB 未覆盖

外部模式的取数触发相位（`b_k = 8k - fine_x`，请求在 `b_k - 9`）是在**触发的那一拍**用当时的 `fine_x` 和 `temp_addr[4:0]` 算出来的，而**已经在取的那一行**的 tile base 已经进了 `nes_chr_fetch_unit` 的 `base_q`。因此在可见区中间写 `$2005`（改 `fine_x` 或 `coarse_x`）之后：

- 内部路径（`g_chr_internal`）的 `bg_x_total` 是**每拍组合**跟着 `dot` / `fine_x` / `temp_addr` 走的，立刻跟随；
- 外部路径只在下一个触发点重新取相位，**已经锁进 `bg_lo_q` / `bg_hi_q` 的 tile 不会回退重取**。

两者会分叉。`tb_nes_ppu2c02_ext_chr.v` 的 `set_config` 在第 0 帧之前一次性写完 `$2005` / `$2000` / `$2001`，5 组配置之间也不中途改 scroll，**渲染期间写 `$2005` 一条也没有覆盖**。这是当前 A/B 证据的一条明确边界。

#### 11.3.4 复位后需要 1 行 warm-up

复位把 `bg_lo_q` / `bg_hi_q` 清 0、把 `bg_ready` 清 0，而 `bg_ready` 之后**只置位不清零**。复位后第一行前半段（`bg_pa_enable` 已为 1 但流水线还没 priming）拿不到正确 pattern。TB 在 `frame_cnt >= WARMUP_FRAMES` 之后才要求 `bg_ready` 必须为 1（`:368-371`），并**丢弃每组的第 0 帧**。也就是说 **921,600 次比对覆盖的是第 1 / 2 / 3 帧，复位后第 0 帧的背景像素没有被验证**。

#### 11.3.5 非连续 `ce` 下 `chr_req` 脉冲可能被拉长

`nes_chr_fetch_unit` 的 `chr_req` 在 `ce = 0` 时冻结（输出逐拍不动），`ce` 空洞会把 `chr_req` 的高电平**拉长到多个 `clk`**，而不是保持 2.1 节合同里的"1 拍 `ce` 宽脉冲"。这不是 bug，是 `ce` 门控的直接后果。第 4 组配置用 `ce_div = 3`（`ce` 1-in-4）跑通 3 帧，说明真实分频比下流水仍成立；但**没有断言 `chr_req` 的脉宽**。`nes_system_v5` 的 `ce_ppu` 是**连续 1-in-4**（`div_phase` 自由运行），所以这个差异在系统里实际不发生。

#### 11.3.6 mapper 侧的 `chr_bank_offset` 仍未接进 PPU

**这一条从第 9 节到现在没有变过。** `nes_system_v5` 的 `ppu_addr` / `ppu_a12` 仍绑 0，所以：

- 2.2 节的组合叠加 `chr_addr_final = chr_bank_offset + ppu_local_addr` **没有实现**；
- CNROM / MMC1 的 CHR 切换在系统级依旧不可观测；
- MMC3 的 A12 扫描 IRQ 计数器在系统级依旧不会被时钟；
- `CHR_ADDR_BITS` 已从 16 抬到 17（第 9 节），修的是 mapper 输出的**地址位宽**，**没有产生任何新的可观察行为**。

所以 11.1 的像素级等价性是"PPU 内部 CHR 通路 vs 外部 CHR 通路"，**与 mapper CHR banking 无关**。

#### 11.3.7 第 8 节登记的三条行为差异的当前状态

| 差异 | 当前状态 |
|---|---|
| 8.1 `$2007` 写 CHR 后渲染晚 1 dot | 写通路根本没实现（11.3.2），既谈不上"晚 1 dot"也没有验证 |
| 8.2 `sprite_overflow` 变成"下一行计数" | **没有实现**。`sprite_overflow_raw` 仍是本行组合量（`nes_ppu_sprite` 侧没改）；本轮 TB 逐 `ce` 比对 A/B 的 `dbg_sprite_overflow` 且两者恒 0，所以这条差异在当前证据里**不可观测** |
| 8.3 `$2007` 读 nametable 区间别名到 CHR 前 8 KiB | 行为存在（`ppu_space_read` 的 `< 14'h2000` 判据），但 TB 从不通过 `$2007` 读 nametable，**未验证** |

第 10 节第 2 步要求的"整帧逐像素与内部模式相同"在**背景**上已达成（11.1.3）；第 3 步（精灵）**接线已完成但等价性没有做**，而且因为 11.3.1 的第 1 条（透明精灵图案），"整帧逐像素相同"在精灵打开时**仍然不可能被证明**。

#### 11.3.8 精灵 slot 选择的组合开销（**已解决**：删除 `nes_ppu2c02` 里的重复实现）

**这一条曾是把 `ppu-ext-chr-tb` 顶到全量 45.26% 的直接原因，现在已解决。** 当时的根因不是"扫描本身太贵"，而是 `nes_ppu2c02.v` 的 `g_chr_external` 分支**重复实现**了一份 `nes_ppu_sprite` 内部本来就有的精灵范围扫描：一个本地 `sp_nth_set` 函数加一个 `always` 块，遍历 64 项 `oam_ram` 的 Y 字节算出 `range_count`，再选出当前 `dot` 落在其 8 像素 X 窗口内的最低 slot。

**修法**：`nes_ppu_sprite` 新导出纯观测输出 `cur_slot_o[3:0]`，`nes_ppu2c02` 改为**消费**它。删除了 `sp_nth_set`、那个 64 项扫描 `always` 块，以及 **11 个只服务于该扫描的 reg**。`nes_ppu2c02.v` **806 → 752 行（净删 54 行）**。

##### `cur_slot_o` 契约

| 项 | 内容 |
|---|---|
| 位宽 | **4 bit** |
| `0..7` | 当前 `dot` **位置上**所处的 slot：既在范围内（`g < range_count`）**且**其 8 像素 X 窗口覆盖该 `dot` 的**最低** slot |
| `4'h8` | 该 dot 无精灵覆盖。并且在 `dot >= 256`、`scanline >= 240`、`reset` 拉高时**无条件**输出 `4'h8`（这些位置 `pixel_active` 恒为 0） |
| **必须是位置性的，不能依赖 pattern** | 否则会形成组合环 `chr_sh -> s_pat -> slot_opaque -> cur_slot_o -> chr_sh` |
| 与 `mask` 的关系 | **无关**：它报告位置，不报告左 8 裁剪是否抑制 |
| overflow | **不携带** overflow 信息 |
| 因此可断言的不变量 | 因为它与 `mask` 无关、不携带 overflow、也不依赖 pattern，精灵 TB 断言的是**较弱但正确**的不变量 **`cur_slot_o <= 不透明源 slot`**，**不是**相等 |

##### 验证

| 证据 | 内容 |
|---|---|
| **A/B 零行为漂移** | `tb/ppu/tb_nes_ppu2c02_ext_chr.v` **完全未改动**。修复前后四行输出**逐字节相同**：`A1 total compared pixels=921600`、`A2 lines_checked=3930 total_requests=337450 total_plane_latches=32487`、`A3 verified request addresses=337450 verified latched plane pairs=126546`；每行 16 次精灵请求仍然成立 |
| **逐 dot 等价（27 万余 tick）** | 另用**仓库外**的 scratch harness 把被删掉的那份扫描**逐字抄出来**挂在新 PPU 上逐 dot 比对，覆盖 8×8 / 8×16 / 左 8 裁剪三段共 **27 万余 tick**：覆盖 slot 的 tick 分别 **512 / 1056 / 512** 个，`sp_slot` **全等**、`sp_chr_sh` **逐字节全等**、**0 mismatch** |
| **`cur_slot_o` 契约断言** | `tb/ppu/tb_nes_ppu_sprite.v` **纯追加 3 组断言**（门控情形、`0..7` 编码含间隙与第 9 个精灵被丢弃、与 `slot_opaque` 自洽）；现有 **12 组一字未改** |
| **回归** | `-Mode ppu` **10/10 全绿**；`-Mode all` **50/50 PASS** |

##### 收益

| 项 | 前 | 后 |
|---|---|---|
| `ppu-ext-chr-tb` | 821.6 s | **162.5 s** |
| 占全量 | **45.26%** | **16.83%** |
| 全量 | 1815.3 s（约 30.3 min） | **965.6 s**（墙钟 **966.09 s**，约 **16.1 min**），降幅 **46.8%** |
| 最慢前三 | — | `ppu-ext-chr-tb` 162.5 s（**16.83%**）、`chr-feasibility-tb` 81.3 s（8.42%）、`system-v3` 61.7 s（6.39%），合计 **31.6%** |

**归因必须与机器变快分开。** 本轮机器整体比上一轮**快**约 **1.23 倍**：用 **18 个不含 PPU 的目标**测得机器系数 **0.812**，各项目标比值落在 **0.724~0.928** 带内、**无一变慢**。849.7 s 的节省里 **659.1 s（77.6%）是这次结构修复的收益**，其余 **190.6 s（22.4%）** 是机器变快。**反事实验证**：把其余 49 个目标按 0.812 缩放预测得 **969.3 s**，实测 **965.6 s**，误差 **3.7 s** → **`ppu-ext-chr-tb` 是唯一有结构变化的目标**。

##### 对原诊断的更正（必须读，否则会重复传播）

**`oam_ram` 那条数组敏感度警告从来就不是被删掉的那份扫描发出的。** 它来自 `reg_dout = oam_ram[oam_addr_reg]`，**改动前就存在**（先跑了 baseline 才说的）。改动后警告总数 **7 → 8**，新增的 1 条来自 `nes_ppu_sprite.v` 新加的 `slot_x` `always` 块——代价远小于删掉的那份重复扫描。**原来把这条警告归因到"每 `ce` 一次 64 项扫描"是误判。**

##### 仍然残留的限定词

- **面积与 fmax 从未测量。** 本仓库没有任何综合报告。11.3.8 的关闭**只覆盖"重复逻辑 + 回归时长"**，**不得**被转述为"精灵 slot 选择的面积与时序可接受"。
- `nes_ppu_sprite` 内部那份 64 项 OAM 范围扫描与 nth-set 优先编码**仍然每 dot 组合重算**，只是不再被 PPU 层重复实现一遍。
- 11.1.1 的三个仲裁窗口（背景 ..253 / 精灵 257..291 / 背景 324）**没有被这次改动触动**，所以"无握手、无背压、窗口一旦重叠背景请求拍会被静默丢弃"这条失效模式原样保留。
- 11.3.1 的四条限制（精灵像素无证据 / shadow 差一行 / 8 位 `chr_sh` 单字节 / 仲裁无握手）**一条都没有因为 11.3.8 关闭而改变**。
- 风险登记册里对应条目是 **R-08**，状态为**已关闭（部分）**，面积/时序那一半改挂 R-03 / R-05。


### 11.4 证据边界（一句话版）

- **可以说**：背景外部 CHR 通路在 5 组配置 × 3 帧下与内部 CHR 路径**逐 `ce` 逐 dot 像素完全一致**（921,600 次 `pixel_index` + `bg_pa_enable` 比对），337,450 次 `chr_req` 的地址被独立重算核对，126,546 对平面字节与 CHR 模型逐字节一致。
- **可以说（本轮新增，仅限接线与总线）**：精灵预取单元已由 `g_chr_external` 例化并在 dot 257 发 `start`；**每行恰好 16 次**精灵 `chr_req`；仲裁是**无握手的组合优先 mux**（精灵优先）**且两个窗口不重叠**（背景 ..253 / 精灵 257..291 / 背景 324..，见 `nes_ppu2c02.v:421` 的 `bg_fetch_pre_first = (dot == 9'd324)`）；**mux 不篡改当前持有者的地址**（背景与精灵两侧都断言过）。
- **不能说**：外部模式的精灵通路可用或精灵能正确渲染（**A/B 一致靠 TB 的全 0 透明精灵图案，精灵像素一条证据都没有**）；shadow 不差一行（它现在**就差一行**）；双平面被正确交付（8 位 `chr_sh` 只能给一个字节，当前是低/高平面按位或）；外部 CHR 的 `$2007` 读写可用（写被丢弃、读恒 0）；渲染期间改 scroll 可用；mapper CHR banking 已接通；`ppu_a12` 已被真实时钟；复位后第 0 帧正确；`chr_req` 在任意 `ce` 分频下都是 1 拍脉冲。
- **不能说**：精灵 slot 选择的**面积与 fmax 可接受**。11.3.8 的关闭**只覆盖"重复逻辑 + 回归时长"**：`nes_ppu2c02` 不再重复实现 `nes_ppu_sprite` 已有的扫描，但**面积与时序仍然没有任何综合证据**，`nes_ppu_sprite` 内部那份 64 项 OAM 范围扫描与 nth-set 优先编码**仍然每 dot 组合重算**。
- **不能说**：任何综合 / STA / fmax / 上板结论。上述全部证据来自 Icarus Verilog 下的 RTL/TB 内部一致性。

### 11.5 下一步（按当前状态）

1. **把 A/B TB 的精灵图案从"全 0 透明"换成非透明图案，并加精灵可见性自检**（先断言 A 侧确实有非背景精灵像素，否则"换图案"可能仍然换出一张全透明的帧），然后重跑同一套 921,600 次比对。**这是取得精灵像素等价性证据的前提**。
2. **修 shadow 差一行**（11.3.1 第 2 条）：`scanline_sel` 指向下一行，或者 `start` 提前一行发。
3. **加宽 `nes_ppu_sprite.v` 的 `chr_sh` 以交付双平面**（11.3.1 第 3 条），同步改 `tb/ppu/tb_nes_ppu_sprite.v`；顺带补 8×16 / 每行 8 个上限 / overflow / 翻转的精灵覆盖。
4. ~~**处理精灵 slot 选择的组合开销**（11.3.8 / R-08）~~ —— **已完成**。`nes_ppu_sprite` 导出纯观测输出 `cur_slot_o[3:0]`，`nes_ppu2c02` 改为消费它而不是重算一遍（`sp_nth_set`、64 项扫描 `always` 块、11 个只服务该扫描的 reg 全部删除，`nes_ppu2c02.v` 806 → 752 行）；27 万余 tick 逐 dot 等价、A/B 四行逐字节不变，`ppu-ext-chr-tb` 821.6 s → **162.5 s**、占全量 45.26% → **16.83%**。**但面积与 fmax 仍未测量**，那部分归 R-03 / R-05，见 11.3.8。
5. **`$2007` 对外部 CHR 的写通路**（`chr_we` / `chr_wdata` + 写延迟），以及读回语义（8.3 的别名要不要接受）。
6. **mapper 侧 `chr_bank_offset` 组合叠加**（2.2）+ `nes_system_v5` 的 `ppu_addr` / `ppu_a12` 接线，并同步处理 `tb_nes_system_v5.v:1499-1507` 那条"`ppu_a12` 绑 0"的断言。
7. **渲染期间 `$2005` 写的相位处理**（11.3.3）与**复位后第 0 帧的 warm-up**（11.3.4）。

早期版本这一节里的"为什么停在这里"和"两条可选路线（(a) 先用行为模型证明等价性 / (b) 内部 tile 缓存）"已经**部分过期**：路线 (a) 的等价性证明已在 11.1.3 完成（实现顺序是先写 RTL 再写 A/B TB），路线 (b) 的内部 tile 缓存**没有被采用**。**但第 8 节那三条行为差异的人工决策仍然没有记录**——8.1 与 8.3 是否接受、8.2 是否需要重做，都还需要人拍板。

