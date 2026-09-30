# PPU 外部 CHR：背景通路已接通并有像素级证据，精灵通路已接线并有像素级证据（覆盖仍有缺口），`$2007` 写通路已实现并有端到端证据，`$2007` 读通路也已实现（但会占掉一个取数拍）

本文记录 `nes_ppu2c02` / `nes_ppu_sprite` / `nes_chr_fetch_unit` / `nes_sprite_chr_fetch` 的**外部 CHR 改造**。它分成三部分，措辞必须和仓库现状严格对应：

- **已实现（背景，有像素级证据）**：外部 CHR 的**背景 pattern 取数通路**已接通——`g_chr_external` 例化 `nes_chr_fetch_unit`，PPU 侧有 `bg_lo_q`/`bg_hi_q`/`bg_ready` 平面锁存，按逐 tile 的流水节拍取数。`tb/ppu/tb_nes_ppu2c02_ext_chr.v`（回归目标 `ppu-ext-chr-tb`）在 5 组配置 × 3 帧下做了 **921,600 次逐 `ce` 逐 dot 的 `pixel_index` + `bg_pa_enable` 比对，全部一致**。**外部 CHR 背景通路第一次有了像素级证据。**
- **已接线并有像素级证据（精灵，覆盖仍有缺口）**：`g_chr_external` 现在也例化 `nes_sprite_chr_fetch`（dot 257 发 `start`），`chr_req`/`chr_addr` 是精灵优先的**组合优先 mux**（无握手），`shadow` 按 slot 解复用喂 `chr_sh`。A/B TB 证明**每行恰好 16 次精灵请求**、**mux 不篡改持有者地址**、**两个窗口不重叠**，并证明**精灵像素的等价性**——七个精灵可观测量在 **552,960** 个比较点上**全部 0 分歧**，其中 **1,708** 个精灵决定像素真的被渲染（透明背景上 **908**、不透明背景前 **564**、不透明背景后 **236**），**6,144** 个 dot 上恰好 8 个精灵在范围内、**2,048** 个 overflow dot（`ad3c17a`）。**逐项都已 A/B 证明的精灵特征**（9 个精灵场景各自隔离一项、各有自己的非空洞 `$fatal`，`case_sp_*` 计数器每组开始时清零，每组 `mismatched_pixels=0`）：8×16 高度（`sp1-8x16-oddtile` 40 / `sp8-8x16-mixprio` 560 个精灵决定像素）、每行 8 个 sprite 上限（`sp8-8x8-limit` 2,048、`sp8-8x16-mixprio` 4,096 个"恰好 8 个在范围内"的 dot）、overflow 标志位（`sp10-overflow` 2,048 个 overflow dot）、水平翻转（`sp1-hflip` 48）、垂直翻转（`sp1-vflip` 56）、双翻转（`sp1-hvflip` 56）**各自独立成立**。**仍未覆盖**：§8.2"用下一行 OAM 计数"那个 overflow **行为**差异（未实现、所以仍不可观测）、这 9 个场景之外没构造出来的优先级组合（透明背景 908 / 前 564 / 后 236 只证明这三类）、CHR 仲裁无握手无背压。（先前记在这里的 shadow **差一行**、8 位 `chr_sh` 只能交付**一个字节**两条**已修掉**，见 `3e218bf`、`c6ea299`。）见第 11 节。
- **已实现（`$2007` 对外部 CHR 的读，读臂那一轮）**：`nes_ppu2c02` 新增 `input wire chr_rd_arm`（第 7 个外部 CHR 端口），`g_chr_external` 里 `$2007` 的 CHR **读**成为 CHR 总线的**第三个 master**（`chr_rd_win` 抬 `chr_req`、并把 `v_addr[13:0]` 送上 `chr_addr`），加一个 set/hold 寄存器 `chr_rd_armed_q` 与 `read_buffer_reg <= chr_rd_armed_q ? chr_rdata : 8'h00;` 这一层**失效保护**。**字节值永远正确**（在 mapper 翻译后的地址上），但把它放上总线会**顶掉一个在飞的取数字节**（一个背景 tile 或一个精灵 slot 平面，限定在那条扫描线），所以**渲染开着时帧中读不宣称安全**。见第 11.3.9 节。
- **仍未实现**：写与取数、**读臂与取数**在共享 CHR 地址总线上的**碰撞抑制**、片上 CHR 存储、运行期 nametable mirroring 端口。
- **已实现**：`$2007` 对外部 CHR 的**写**通路（`5cc36e7` / `576cc74`）。`g_chr_external` 现在驱动 `chr_waddr`（新增的第 6 个外部 CHR 端口）/ `chr_we` / `chr_wdata` 三根线，`nes_system_v6` 上由 `nes_mapper` 的 `chr_ram_we` 门控，**96 个写拍、0 翻译错**，并有哨兵非空洞、字节级核对、自验证对、CHR-RAM/CHR-ROM 忽略对与 MMC3 bank 限定写五组证据。教学文档见 [`docs/ppu_chr_external_write.md`](../ppu_chr_external_write.md)，摘要见第 11.3.2 节。读写两条路现在**都通了**（读见上一条与 11.3.9），**但两条都各自带一个未修的撞车**（写 22/96、读 107/396），见 11.3.2 与 11.3.9。
- **已完成**：`CHR_ADDR_BITS` 从 16 抬到 17（mapper 侧地址不再静默截断），见第 9 节。注意这一项**只修 mapper 输出的地址位宽**，它本身不产生新的可观察行为。**当前架构**是：PPU 侧**不做任何 bank 算术**——`nes_ppu2c02` 导出的是 14 bit **本地** `chr_addr` / `chr_waddr`，其中只有 **13 bit 有效**（bit 12 是 pattern-table 选择位，`chr_addr[13]` 是**声明了但恒 0** 的位），把它翻成最终 17 bit CHR 字节地址是 `nes_mapper` 在 `chr_bank_offset` 上做的事。`nes_system_v6` 上 mapper 的这条**读**通路**已经接通**（`mapper_ppu_addr = ppu_chr_we ? ppu_chr_waddr : ppu_chr_addr`，**写优先、否则读**；`chr_final_addr = mapper_chr_bank_offset`），`$2007` **写**通路也接通了（`5cc36e7` / `576cc74`）。**仍然没接通**的是 `ppu_a12`（仍绑 0），所以 MMC3 的 A12 扫描 IRQ 在系统级依旧不能自时钟——见 11.3.6。

**当前进度、未实现项与证据边界以第 11 节为准。** 第 1-10 节写于背景通路落地之前，其中被实现取代的描述已在原地标注"已按事实更新"。

外部 CHR 的最终目的是把 `nes_mapper` 的 `chr_bank_offset` 接进 PPU，让 CNROM/MMC1 的 CHR 切换和 MMC3 的 A12 扫描 IRQ 在系统级可观测。`nes_system_v6` 已经把 CHR **地址**侧接上（见 11.3.6），但 `ppu_a12` 仍绑 0（v5 的 `ppu_addr` / `ppu_a12` 同样绑 0），所以 A12 那一半在系统级依然不可观测；P1-11 之后 MMC3 扫描 IRQ 的状态机已在 `system-v6` 里于**建模刺激**下有真实 RTL 证据，**那不是硬件预测**。

---

## 1. 已实现：接口骨架

### 1.1 `rtl/nes_core/ppu/nes_ppu2c02.v`

参数：

```verilog
parameter EXTERNAL_CHR = 1'b0
```

**7 个端口**（`chr_rdata` 与 `chr_rd_arm` 是两个输入；读臂那一轮之前是 6 个、`chr_rdata` 是唯一输入）：

| 端口 | 方向 | 位宽 | 说明 |
|---|---|---|---|
| `chr_req` | out | 1 | 取数**或 `$2007` 读**请求，1 拍 `ce` 宽脉冲（**已按事实更新**：读臂那一轮起，`$2007` CHR 读也是 `chr_req` 的一个 master，见 11.3.9） |
| `chr_addr` | out | 14 | 请求期间保持不变的地址（**已按事实更新**：读臂那一轮起，`chr_rd_win` 时它是 `v_addr[13:0]`） |
| `chr_rd_arm` | in | 1 | **`$2007` 对 CHR 的读请求**（**新增**，读臂那一轮；`nes_system_v6` 把它抬在 `div_phase == 8` 的那一拍上，见 11.3.9） |
| `chr_waddr` | out | 14 | `$2007` 写 CHR 的地址（**已按事实更新**：原先不存在；**自增前**的 `v_addr`，非 CHR 时为 `14'h0000`，见 11.3.2） |
| `chr_we` | out | 1 | 写使能，**恰好 1 `clk` 宽**的组合 strobe（**已按事实更新**：原先恒 `1'b0`，见 11.3.2） |
| `chr_wdata` | out | 8 | 写数据（**已按事实更新**：原先恒 `8'h00`；现在是 `reg_din`） |
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
| `ppu_space_read` | `< $2000` 读 `chr_ram[address[12:0]]` | `< $2000` 返回 `8'h00`（**已按事实更新两轮**：先是 `$2007` 读未实现、外部 CHR 的 `$2007` 写已实现；**读臂那一轮起 `$2007` 的 CHR 读不再经过这个函数**——它走 `chr_rd_armed_q ? chr_rdata : 8'h00`，所以这个 `< $2000 → 8'h00` 分支对 `$2007` 已经**不可达**，它现在是 nometable / palette 读旁边的历史残留。见 11.3.2 与 11.3.9） |
| `bg_pattern_low` / `bg_pattern_high` | `chr_ram[bg_pattern_addr]` / `+ 13'd8` | `(bg_ready && bg_pa_enable) ? bg_lo_q : 8'h00` / `bg_hi_q`（**已按事实更新**：不再是绑 `8'h00`） |
| 精灵 CHR 数据通路（**已按事实更新**） | **没有展平总线，`sprite_chr_bus` 这根 65536 bit 网已被删除**（`575e191`）。现在由 `g_sprite_chr_slots`（`:602-607`）用 **8 次迭代、16 次读**把 `chr_ram` 组合读成 128 bit `sprite_chr_slots`：每 slot 16 bit，低平面 = `chr_ram[s_pat_addr]`、高平面 = `chr_ram[s_pat_addr + 13'd8]`，地址取自 `pat_addr_cur_o` 导出的 104 bit `sprite_pat_cur_bus`（`:599-600`、`:631`），经 `.chr_slots(...)` 喂进精灵单元 | **同样不读 `chr_ram`**：字节来自 `sp_shadow` 按 slot 解复用出的 `chr_sh[15:0]`（`:748-750`、`:774`）。两个分支**都**传 `.chr(65536'd0)`（内部 `:617`、外部 `:773`），但内部那一份只是 `PER_SLOT_CHR = 1` 选中的 `g_chr_per_slot` 之外**那条不再被读的默认路径 `g_chr_flat` 的实参** |
| `u_sprite` | `EXTERNAL_CHR=1'b0`、**`PER_SLOT_CHR=1'b1`**（`575e191` 新增）、`chr_sh=16'h0000`、`.chr_slots(sprite_chr_slots)`、`.chr(65536'd0)`、`scanline_sel=scanline` | `EXTERNAL_CHR=1'b1`、`chr_sh=sp_chr_sh`（16 bit，由 shadow 解复用出低/高两个平面）、`.chr(65536'd0)`、`scanline_sel=scanline`（**已按事实更新**：不再绑全 0；`scanline_sel` 仍直连 `scanline` 是**当前正确的接法**，因为"下一行"的重定时已经搬进 `pat_addr_o` 内部，见 11.3.1） |
| `chr_ram` 的 `$2007` 写 | 有 | **没有**（外部模式改成打到外部端口：`chr_waddr` / `chr_we` / `chr_wdata`，见 11.3.2） |
| `chr_req` / `chr_addr` | 不存在（内部模式不发） | 背景 `nes_chr_fetch_unit` 与精灵 `nes_sprite_chr_fetch` 两个 master 的**组合优先 mux**（**已按事实更新**，`nes_ppu2c02.v:807-808`，精灵优先）；`chr_waddr` / `chr_we` / `chr_wdata` **不再绑常数**（`5cc36e7` / `576cc74`），由 `v_addr` 与寄存器译码驱动（`:811-814`） |
| 取数状态机 | 不存在（内部路径纯组合） | **有两个**：`nes_chr_fetch_unit u_chr_fetch`（`:789-803`）与 `nes_sprite_chr_fetch u_sprite_chr_fetch`（`:752-764`） |
| 平面锁存 | 不需要（直接组合读 `chr_ram`） | **有**：`bg_lo_q` / `bg_hi_q` / `bg_ready`（`:690-692`、`:816-827`）与 128 bit `sp_shadow` |
| `$2007` 读 + `increment_v` | 有 | 有 |

**（已按事实更新）`g_chr_external` 的背景取数逻辑已经实现，精灵预取单元也已经例化**，不再是"只把输出绑常数"。`chr_req` / `chr_addr` 由背景 `nes_chr_fetch_unit` 与精灵 `nes_sprite_chr_fetch` 两个 master 的**组合优先 mux** 驱动（`:807-808`），`chr_rdata` 已被真正读进 `bg_lo_q` / `bg_hi_q`（背景）与 `sp_shadow`（精灵），`bg_pattern_low` / `bg_pattern_high` 读的是锁存器。**`$2007` 对外部 CHR 的写通路也已实现**（`5cc36e7` / `576cc74`）：`chr_waddr` / `chr_we` / `chr_wdata` 三根线不再是常数，`chr_we` 是**恰好 1 `clk` 宽的组合 strobe**、`chr_waddr` 是**自增前**的 `v_addr`（逐条推导与证据见 11.3.2 与 [`docs/ppu_chr_external_write.md`](../ppu_chr_external_write.md)）。**（已按事实更新）**原先记在这里的"`sprite_chr_bus = 65536'd0` 仍然绑常数"一条**已随那根网一起作废**：`sprite_chr_bus` 与 8192 次迭代的 `g_chr_flatten` 在 `575e191` 里被删除，`.chr(65536'd0)`（内部 `:617`、外部 `:773`）现在**两个分支都在传**，但它只是 `PER_SLOT_CHR = 1` 选中的 `g_chr_per_slot` 之外**那条不再被读的默认路径 `g_chr_flat` 的实参**——精灵平面字节改由 128 bit `chr_slots` 交付（见上表与 1.2 节）。**因此本段仍然绑常数、且唯一还剩下的是历史残留的只有一条**：`ppu_space_read` 对 `< $2000` 的 `8'h00`——**这一条现在是历史残留而不是活行为**：`$2007` 的 CHR 读在读臂那一轮起改走 `chr_rd_armed_q ? chr_rdata : 8'h00`，不再经过 `ppu_space_read`（见 11.3.9）。**但精灵像素的正确性已经有 A/B 证据**（`ad3c17a`：七个精灵可观测量在 552,960 个比较点上 0 分歧，1,708 个精灵决定像素跨三类优先级），精灵 A/B 里的 9 个精灵场景各自隔离一项、各有自己的非空洞 `$fatal`，8×16 高度、每行 8 个 sprite 上限、overflow 标志位、水平/垂直/双翻转**逐项已被 A/B 证明**（逐条数字见 11.3.1），剩下的缺口只有 §8.2 的 overflow **行为**差异、9 个场景之外没构造出来的优先级组合与仲裁无背压。（先前记在这里的 shadow 差一行、8 位 `chr_sh` 只能交付一个字节两条**已修掉**：`chr_sh` 现在 16 bit 交付两个平面，`pat_addr_o` 改用下一行 scanline。）`nametable_ram` 的 `nt_fetch` 影子数组**已删除**，取数支路直接读 `nametable_ram` 的第二个组合读口。完整接线、取数节拍、像素级证据与仍未实现项见第 11 节。

### 1.2 `rtl/nes_core/ppu/nes_ppu_sprite.v`

| 改动 | 内容 |
|---|---|
| 参数 | `EXTERNAL_CHR`（默认 `1'b0`）；**`PER_SLOT_CHR`（默认 `1'b0`，`575e191` 新增）** |
| 新输入 | `chr_sh[15:0]`：外部模式下当前 slot 的 pattern **两个平面**，`[7:0]` 是低平面、`[15:8]` 是高平面（**已按事实更新**：原为 `chr_sh[7:0]` 单字节，已加宽到 16 bit） |
| 新输入 | `scanline_sel[8:0]`：渲染链使用的 scanline |
| 新输入 | **`chr_slots[127:0]`（`575e191` 新增）**：8 slot × 16 bit，slot `g` 的低平面在 `[{g, 4'b0000} +: 8]`、高平面在 `[{g, 4'b1000} +: 8]`。**只有 `PER_SLOT_CHR = 1` 时被读** |
| 新输出 | `pat_addr_o[103:0]`：8 slot × 13 bit。**已按事实更新**：`g_chr_external` 里它就是 `nes_sprite_chr_fetch` 的 `pat_addr` 输入，不再是"纯观测、无驱动用途" |
| 新输出 | **`pat_addr_cur_o[103:0]`（`575e191` 新增）**：8 slot × 13 bit，每段是**本行**渲染用的 `s_pat_addr`。`PER_SLOT_CHR = 1` 时它被 PPU 拿去索引 `chr_ram` 并组装 `chr_slots`，所以它现在**有驱动用途**；`pat_addr_o`（下一行）与它**不能互换** |
| 分支 | `g_chr_internal` 现在**再分两层**：`PER_SLOT_CHR = 1` 走 `g_chr_per_slot`（`chr_slots[{SLOT_U8, 4'b0000} +: 8]` / `[{SLOT_U8, 4'b1000} +: 8]`），`PER_SLOT_CHR = 0`（**默认**）走 `g_chr_flat`（`chr[{s_pat_addr,3'b000} +: 8]` 取低平面、`+ 13'd64` 取高平面）；`g_chr_external` 取 `chr_sh[7:0]` / `chr_sh[15:8]` 作为低/高平面 |

`pat_addr_o` 每一段是 `s_pat_addr = {s_table, 5'b00000, s_tile, 1'b0, s_fine[2:0]}`，也就是**每个 slot 本行需要的那 1 个字节的地址**（`tile*16 + fine`）。外部预取器照着 `pat_addr_o` 发请求就能拿到正确的 16 个字节。**四处 CHR 地址约定必须指向同一批字节**（已按事实更新：`575e191` 之后内部路径分成两条，这一节从三处变成四处），这一点是接线时踩过的坑：

| 处 | 写法 | 实际指向的字节 |
|---|---|---|
| `nes_ppu_sprite` 内部路径 **`g_chr_flat`**（`PER_SLOT_CHR = 0`，**默认**；`tb_nes_ppu_sprite` 走的就是这条） | `chr[{s_pat_addr, 3'b000} +: 8]`，高平面 `+ 13'd64` | `chr` 是 65536 bit 扁平总线，`{pat,3'b000}` 是**位**索引且每 8 位一个字节 → 字节 `s_pat_addr`；`+13'd64` **位** = **+8 字节** |
| `nes_ppu2c02` 内部路径 **`g_sprite_chr_slots`**（`PER_SLOT_CHR = 1`，**PPU 现在选的就是这条**） | `chr_ram[s_pat_addr]` / `chr_ram[s_pat_addr + 13'd8]`，索引取自 `pat_addr_cur_o` | `chr_ram` 是 `reg [7:0] chr_ram [0:8191]`，**按字节索引**，所以这里 `+ 13'd8` 就是 **+8 字节** |
| `nes_chr_fetch_unit`（背景） | `chr_addr = tile_base + (plane ? 8 : 0)` | 字节 `tile_base` / `tile_base + 8` |
| `nes_sprite_chr_fetch`（精灵） | `chr_addr = pat_addr` / `pat_addr + 8`，`& 14'h3FFF` | 字节 `pat_addr` / `pat_addr + 8` |

**（已按事实更新）这四条现在必须一起读，因为 `575e191` 之后内部路径有两条并存。** 它们**指向同一对字节**（`s_pat_addr` 与 `s_pat_addr + 8`），但**算术不同**：`g_chr_flat` 的 `+13'd64` 是**位**步长（因为索引的是 65536 bit 扁平总线），`g_sprite_chr_slots` 的 `+13'd8` 是**字节**步长（因为索引的是字节数组 `chr_ram`）。`nes_ppu_sprite.v:132-140` 那条"`13'd64` 不能改成 `13'd8`"的告诫**仍然有效、且只对 `g_chr_flat` 有效**——它讲的是位偏移与字节偏移的区别，在 `g_chr_flat` 上把 `13'd64` 改成 `13'd8` 会读到 `s_pat_addr + 1`；**反过来**在 `g_sprite_chr_slots` 上把 `13'd8` 改成 `13'd64`，最小地址 0 会读成字节 64（tile 4 的第 0 行，不是 tile 0 的高平面），最大地址 `8183 + 64 = 8247` 还会**越过 `chr_ram[0:8191]` 的深度**。两条路径各有各的正确写法，不要互相"修正"。

**这里曾有一个真实缺陷**：`nes_sprite_chr_fetch` 的 `plane_byte` 原来输出 `chr_addr = {pat + plane*8, 3'b000}`，把 pattern 地址当**位索引**再左移 3 位，而 `chr_addr` 是**字节**地址 → 地址整整偏 8 倍，同时 `chr_addr[13]` 永远为 0（外部 16 KiB CHR 的上半 8 KiB 取不到）。现已改为按字节算（`pat` / `pat + 8`，14 位回卷），`sprite-fetch-tb` 的独立重算同步更新，并加了一条"14 位地址字段必须被驱动起来否则 `$fatal`"的承重断言。

`scanline_sel` 的存在是因为预取发生在 hblank，而预取要算的是**下一行**的 slot。当前 `nes_ppu2c02` 两个分支都把 `scanline_sel` 接成 `scanline`，并保留了一条 X 兜底：

```verilog
assign scanline_chain = (^scanline_sel === 1'bx) ? scanline : scanline_sel;
```

这条兜底是给 TB 留的：外部模式的 TB 如果不驱动 `scanline_sel`，`pat_addr_o` 不会变成 X，`ppu-core` 的 elaboration 证据不会因为少接一根线而变红。

### 1.3 等价性与兼容性

- **`EXTERNAL_CHR = 0`（默认）时渲染结果与改造前逐位一致。** **（已按事实更新）**这条现在**不再**建立在"`g_chr_flatten` 的 8192 份组合读照抄原样"上——`575e191` 把那个 generate 循环删掉了，理由与实测数字见 [`docs/00-overview/risk-register.md`](../00-overview/risk-register.md) 第 10.4 节（`Error (10106)` 8,192 次迭代超限、Verific `VRFX` 崩溃、以及 8,192 个常量索引读口是 `chr_ram` 无法推断 BRAM 的一个独立原因）。**等价性改由下面这条机制承担**：`g_chr_internal` 现在用 `g_sprite_chr_slots` 的 **8 次迭代、16 次读**，为每个 slot 取回**同样那两个字节、同样那两个地址**——`chr_ram[s_pat_addr]`（低平面）与 `chr_ram[s_pat_addr + 13'd8]`（高平面），正是原展平总线里 `chr[{s_pat_addr, 3'b000} +: 8]` 与 `chr[({s_pat_addr, 3'b000} + 13'd64) +: 8]` 所落的那一对（见 1.2 节那张四行表的算术对照）。**交付的字节相同，位序也相同**（低平面进 `s_plane_lo`、高平面进 `s_plane_hi`，`s_pat = {s_plane_hi[...], s_plane_lo[...]}` 不变），所以**像素与精灵可观测量不变**。

  **两条门禁证据各自压在哪个事实上，不要混着说**：`tools/sim_all.ps1` 的 `ppu-sprite`（top = `tb_nes_ppu_sprite`）之所以仍然全绿，靠的是 **`PER_SLOT_CHR` 默认 `1'b0`**——那个 TB 用命名端口例化、没有覆盖参数（`tb/ppu/tb_nes_ppu_sprite.v:54-70`），所以它**仍在跑 `g_chr_flat` 那条默认路径**，`g_chr_per_slot` 并没有被它覆盖；`ppu-core`（top = `nes_ppu2c02`，elaboration）与 `ppu-integration`（top = `tb_nes_ppu2c02`）走默认 `EXTERNAL_CHR = 0`，因此 elaboration 与集成证据压在**新的每 slot 路径**上；`ppu-ext-chr-tb`（top = `tb_nes_ppu2c02_ext_chr`）则是 A/B 实例，把 `EXTERNAL_CHR = 0` 的内部路径与 `EXTERNAL_CHR = 1` 的外部路径逐 `ce` 逐 dot 比对，**内部那一侧现在跑的正是每 slot 路径**。`system-v0`/`v1`/`v2`/`v3`/`v4`/`v5` 与 `platform-tb` 也全绿，它们同样走内部 CHR 路径。**没有证据的部分不因此扩大**：`PER_SLOT_CHR = 1` 与 `PER_SLOT_CHR = 0` 两条路径**没有**被同一个 testbench 直接对拍过，它们的等价性目前建立在"同一对字节、同一算术"这条推导 + 上面的 A/B 结果上。

- **`reg [7:0] chr_ram [0:8191]` 必须留在 `nes_ppu2c02` 模块作用域，名字不能改。** **11 个** testbench 文件用层次化路径直接读写它（`575e191` 之前这个数字就已经是 11，**删掉展平循环不改变其中任何一条路径**——展平是从 PPU 内部往外送数据，不影响外部按层次名寻址）：

  | testbench | 层次化写法 |
  |---|---|
  | `tb/ppu/tb_nes_ppu2c02.v` | `dut.chr_ram[...]` |
  | `tb/ppu/tb_nes_ppu2c02_ext_chr.v` | `dut_a.chr_ram[...]` / `dut_b.chr_ram[...]` |
  | `tb/ppu/tb_chr_fetch_feasibility.v` | `dut.chr_ram[...]` |
  | `tb/system/tb_nes_system_v0.v` | `dut.u_ppu.chr_ram[...]` |
  | `tb/system/tb_nes_system_v0_nmi.v` | `dut.u_ppu.chr_ram[...]` |
  | `tb/system/tb_nes_system_audio.v` | `dut.u_ppu.chr_ram[...]` |
  | `tb/system/tb_nes_system_v2.v` | `dut.u_ppu.chr_ram[...]` |
  | `tb/system/tb_nes_system_v3.v` | `dut.u_ppu.chr_ram[...]` |
  | `tb/system/tb_nes_system_v4.v` | `dut.u_ppu.chr_ram[...]` |
  | `tb/system/tb_nes_system_v6.v` | `ab_v5.u_ppu.chr_ram[...]`（v5 侧内部 CHR 实例，A 侧 v6 走外部端口） |
  | `tb/platform/tb_nes_ep4ce10_top.v` | `dut.u_nes.u_ppu.chr_ram[i]` |

  把它移进 `g_chr_internal`、改名、或者改成 `logic`，这 11 个 TB 会在 elaboration 阶段直接报错。这是硬性兼容约束，不是风格偏好。**（`chr_ram` 现在仍声明在 `nes_ppu2c02` 模块作用域、`nes_ppu2c02.v:417`，写口 `:637`，这一点在 `575e191` 之后未变。）**

- **`nes_ppu_sprite` 的 `chr` 端口必须仍然是 65536 bit**（`input wire [65535:0] chr`）。`tb/ppu/tb_nes_ppu_sprite.v` 直接用大向量 `chr` 灌 pattern 字节；缩窄它会改变这个 TB 的激励方式。`EXTERNAL_CHR` 分支只是让它不被读，不改它的宽度。**（已按事实更新）**`575e191` 之后 PPU 两个分支都传 `.chr(65536'd0)`，**但这不构成缩窄它的理由**：这个 TB 走 `PER_SLOT_CHR = 0` 的 `g_chr_flat`，**真的在读 `chr`**，所以宽度与位索引语义都仍然是承重约束。

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
| `chr_we` | 1 拍 `clk` 宽的组合 strobe（不是 `ce` 宽） | **已按事实更新**（`5cc36e7` / `576cc74`）：由 `!reset && reg_cs && reg_we && (reg_addr == 3'd7) && (v_addr < 15'h2000)` 组合导出。`reg_cs` 是 `div_phase == 0` 的单 `clk` 脉冲，所以 strobe 与 `g_chr_internal` 的 `chr_ram` 写落在**同一个 `posedge`** 上；`system-v6` 的 P0-8 在 **0** 个连续 `ce` 上测到高，W1 / W2 各自独立复核 |
| `chr_waddr` | strobe 为高时是**自增前**的 `v_addr`（非 CHR 时 `14'h0000`） | 成立（`system-v6` 的 `P0-2 WRITE-TRANSLATION` 在每个写拍上断言 `chr_waddr == u_ppu.v_addr` 自增前、`chr_waddr[13] == 0`） |
| `chr_wdata` | strobe 为高时等于 `reg_din` | 成立（同一拍比对，0 错） |

### 2.2 地址合成（**仍未实现**）

- **chr_bank_offset 是最终 CHR 字节地址，不是"再加一次"的位移。** mapper 侧的 bank 合成是**翻译**模型，不是加法模型：`chr_bank_offset` 直接由 `ppu_addr` 组合产生（`nes_mapper_cnrom.v:41` 的 `(chr_bank_ext << 13) | ppu_addr[12:0]`、`nes_mapper_mmc1.v:65`、`nes_mapper_mmc3.v:135` 同构），memory owner 直接拿它当索引（mapper TB 里的 `chr_rom[chr_bank_offset[15:0]]`）。PPU 侧的 `chr_addr[13:0]` 是**局部**地址，也就是 mapper 应当看到的 `ppu_addr`，PPU **不加任何 bank 偏移**。
  - 写成 `chr_addr_final = chr_bank_offset + ppu_local_addr` 是错的，决定性理由是**组合环**：mapper 的 `chr_bank_offset` 本身就是 `ppu_addr` 的组合函数，一旦系统级把 PPU 的 `chr_addr` 接到 `mapper.ppu_addr`，就得到 `chr_addr -> mapper.ppu_addr -> chr_bank_offset -> chr_addr` 的**零延迟组合环**。`nes_system_v5.v:212` 现在用 `wire [13:0] mapper_ppu_addr = 14'h0000;` 掩盖着这个环，所以它是潜伏的而不是已展开的，但一旦 `ppu_addr` 真正接线就立刻存在。mapper 侧本来就是翻译模型（有 4 个 mapper TB 的期望值保护），PPU 侧加法是唯一异类。
  - **这一条没有实现**——`nes_system_v5` 的 `ppu_addr` 仍绑 0，见 11.3.6。
- **`chr_addr[12]` 是 pattern table 选择位，`chr_addr[13]` 是声明了但恒 0 的一位，所有 mapper 都不看它。** 本地 pattern 空间是**一个 8 KiB / 13 bit** 窗口（`{table, tile[7:0], plane, fine_y[2:0]}` = `$0000-$1FFF`）。背景侧是 PPUCTRL[4]（`bg_tile_base = {control_reg[4], bg_name_target, 4'b0000} + fine_y`，`bg_tile_base` 是 13 bit，所以 `control_reg[4]` 落在 bit 12），精灵侧是 PPUCTRL[5] 经 `s_table`（8x16 的 tile 对选择位，13 bit 的 `s_pat_addr`，同样落在 bit 12）。四个 mapper 表达式都把 `ppu_addr[13]` 丢掉：cnrom/nrom/uxrom 只取 `ppu_addr[12:0]`、mmc1 只取 `ppu_addr[11:0]`、mmc3 只取 `ppu_addr[9:0]`。这是对的——pattern table 选择是 PPU 对同一 8 KiB 的内部译码，卡带不该看见它。
  - 由此得到两条对 TB 和未来 CHR memory owner 的约束：(a) 8 KiB CHR RAM 必须用 `chr_addr[12:0]` 索引，因为 `chr_addr[13]` 从来没有被驱动过（`chr_addr` 是 14 bit 端口但本地窗口只有 13 bit，`[12:0]` 索引是**无损截断**，既没有镜像也没有回绕）——`tb_nes_ppu2c02_ext_chr.v` 的 `chr_mem[addr_b[12:0]]` 与内部模式的 `chr_ram[address[12:0]]` 正是这样；因此精灵侧的 `chr_addr[13]` 恒为 0、pattern-table 选择落在 bit 12，这也正是 mapper 丢掉 `ppu_addr[13]` 无害的原因；(b) 内部模式的 `ppu_space_read` 用 `chr_ram[address[12:0]]` 天然截断掉 bit13，与外部模式不需要"驱动 bit13 = 0"来凑等价性——**原先"外部模式必须驱动 bit13 = 0 才能逐位等价"的说法不成立，已删除**。
  - 精灵侧 tile 编号在 `chr_addr[6:4]`、背景侧在 `chr_addr[11:4]`，这个不对称**只记录不修改**：`ppu-ext-chr-tb` 的期望地址按背景约定且 bit13 恒 0 计算，统一它会让每个精灵请求地址都变并让 A3/S2 失败。

---

## 3. 背景取数：本节是设计推导，实际实现见第 11 节

**（已按事实更新）本节 3.1-3.6 是设计推导，背景取数已经实现，但实现方式与本节的部分设想不同**：不是"整行一次突发 + 行末锁存"（3.4/3.5），而是**逐 tile 的 9 拍流水**（见 11.1.2）；nametable 也没有复制第二份 2 KiB（3.3），改成直接读 `nametable_ram` 的第二个读口。**权威描述是第 11 节**，本节保留推导过程以便理解为什么是这样。

### 3.1 抽 `bg_x_total_f` 支路

当前背景取数是纯组合的：

```verilog
assign bg_x_total = {1'b0, dot} + {6'b0, fine_x} + ({4'b0, temp_addr[4:0]} << 3);
```

外部模式需要的是"下一个 dot"的那一份，所以抽一条**平行的** `bg_x_total_f = bg_x_total + 1` 支路出来，只喂给取数支路。原来的 `bg_x_total` 一根线都不动。

**（已按事实更新）** 实现上没有用 `bg_x_total_f` 这个名字，也没有用 `+1`：取数支路用自己的 `bg_dot_fine = dot + fine_x` 和 `bg_look_dot = dot + 9` 重算窗口起点（`nes_ppu2c02.v:577-587`）。**第 4 节那条 attribute 陷阱的规避原则仍然成立**：`bg_coarse_x` / `bg_coarse_y` / `bg_attribute_byte` / `bg_nametable` 全部留在 `dot` 上不动，只有发请求的那一份用前瞻 dot。

### 3.2 发射条件跟着 `fine_x` 漂移

`bg_pattern_bit = 3'd7 - bg_x_total[2:0]`，所以 tile 边界发生在 `bg_x_total[2:0]` 从 7 回卷到 0 的那一拍，即：

```verilog
发射条件 = (bg_x_total_f[2:0] == 3'd7)
```

**不能**把发射点固定在 dot 8 / 16 / 24 / ...。`fine_x` 非 0 时 tile 边界整体平移，固定发射会让 pattern 的行号和 tile 号错位。`fine_x` 是 `$2005` 写的 3 bit scroll，同一行里恒定，所以边界是"每 8 个 dot 一次、起点随 `fine_x` 平移"。

### 3.3 nametable 需要第二读口

`nametable_ram` 现在只有**一个**读口（`bg_name` 和 `bg_attribute_byte` 各一次组合读）。取数支路要在 `bg_x_total_f` 提前 1 dot 的位置上读同一个 tile 索引，组合上会形成第二个读口。

方案：**复制一份 2 KiB `nametable_ram`** 给取数支路单独用。代价是 2 KiB 片上存储翻倍（16 KiB → 2 份 × 2 KiB = 4 KiB，净增 2 KiB，约 2 个 M9K），换来的是取数支路与渲染支路**完全解耦**，不会出现读口仲裁，也让 `EXTERNAL_CHR = 0` 分支一行都不用改。

**（已按事实更新）复制方案没有被采用。** 实际做法是 `bg_name_target = nametable_ram[mirror_nametable(bg_nt_offset_target)]`（`nes_ppu2c02.v:602`），让 `nametable_ram` 直接带**两个组合读口**：一个给渲染支路（`bg_name` / `bg_attribute_byte`），一个给取数支路。代价是 `nametable_ram` 不能再推断成单口 BRAM；换来的是省掉 2 KiB 片上存储、去掉一条需要复位的影子链，并且两个读口天然看到同一份数据、不可能失同步。

### 3.4 寄存 + valid

```text
chr_req  ──┬─ dot N    : 发 nametable / pattern 请求
           └─ dot N+1  : chr_rdata 有效 → 打进 bg_lo_q / bg_hi_q，bg_valid_q 置 1
```

`bg_lo_q` / `bg_hi_q` 各 8 bit，配 1 bit `bg_valid_q`。渲染时读寄存器而不是读外部端口，所以 `ce` 之间外部总线怎么变化都不影响输出。

**（已按事实更新）寄存 + valid 已实现**，但 valid 的名字和位置与本节设想不同：脉冲来自 `nes_chr_fetch_unit` 的 `bg_valid`（`chr_fetch_bg_valid`），锁存寄存器在 PPU 侧叫 `bg_lo_q` / `bg_hi_q` / `bg_ready`（不是 `bg_valid_q`），见 `nes_ppu2c02.v:692-704`。之所以必须有这层锁存，是因为 `nes_chr_fetch_unit` 的 `bg_valid` 只在第 8 拍高 1 个 `ce`、没有握手，见 11.2。

### 3.5 dot 340 预取下一行的第一个 tile

可见区是 dot 0..255，`bg_shown = mask_reg[3] && ((dot >= 9'd8) || mask_reg[1])`。`mask_reg[1]`（左 8 像素显示）打开时 **dot 0-7 也要出像素**，但取数流水线需要 1 dot 提前量，dot 0 那一拍没有前序请求可用。

所以在**本行 dot 340**（hblank 末尾、下一行开始前）就把下一行的第一个 tile 打进 `bg_lo_q` / `bg_hi_q`。`bg_y_total` 只依赖 `scanline`、`temp_addr[9:5]`、`temp_addr[14:12]`，不依赖 `dot`，所以提前一整行取数不会引入 Y 方向的偏差。

**（已按事实更新）触发点从 dot 340 改成 dot 324。** 实际实现是 `bg_fetch_pre_first = (dot == 9'd324) && mask_reg[1]`，前瞻 `dot + 17` 正好落在下一行 dot 0（`nes_ppu2c02.v:579`、`:583`）。选 324 而不是 340 是因为 `dot 340 + 17 = 357` 会越过下一行的 dot 16，已经不是"第一个 tile"了。`bg_y_total` 不依赖 `dot` 这条理由仍然成立，实现里对应的是 `bg_scanline_nl` / `bg_y_total_nl` / `bg_coarse_y_sum_nl` 这一组"下一行"影子算式（`:588-595`）。

### 3.6 `bg_coarse_y_sum` 必须共用

```verilog
assign bg_coarse_y_sum      = {2'b0, temp_addr[9:5]} + {1'b0, bg_y_total[8:3]};
assign bg_vertical_sections = bg_coarse_y_sum / 7'd30;
assign bg_coarse_y          = bg_coarse_y_sum % 7'd30;
```

这三行**与 `dot` 完全无关**（`bg_y_total` 里没有 `dot`），所以取数支路直接复用同一组 wire。**不复制、不改写、不"顺手优化成查表"。** 一旦复制出第二份 `/30`、`%30`，两处就可能因为综合推断差异取到不同的 `bg_coarse_y`，而且这种错误在 fine scroll 跨 nametable 时才显形，极难定位。

**（已按事实更新）这条原则被执行了，但有一处必要的例外。** 同扫描线内的取数支路直接复用 `bg_coarse_y` / `bg_vertical_sections`（`nes_ppu2c02.v:596-599` 的 `bg_next_line ? ... : ...` 三元选择）；而"下一行第一个 tile"（dot 324 那个请求）**必须**有一份按下一行 `scanline` 重算的 `/30`、`%30`（`bg_coarse_y_sum_nl` / `bg_vertical_sections_nl` / `bg_coarse_y_nl`，`:591-593`），因为它取的是**下一行**的 tile，`scanline` 差 1。这不是"复制同一份算式"，所以不违反本节。TB 逐 `ce` 比对 A/B 的 `dbg_v` / `dbg_t` / `dbg_x` / `dbg_w` 以及全部 921,600 个像素，覆盖了这个跨行切换。

---

## 4. 等价性陷阱：不能把 `dot` 整体 mux 成 `dot+1`

这是本轮改造里**最容易踩、也最难在 TB 里看出来**的一个坑。

直觉写法是：

错误写法（直觉上"把 dot 整体提前一拍"）：

```verilog
assign eff_dot = EXTERNAL_CHR ? (dot + 1) : dot;
```

然后把 `eff_dot` 喂给整条背景通路。这样做会让 **`bg_attribute_byte` 早 1 dot 读**。因为 `bg_coarse_x`、`bg_coarse_x_sum`、`bg_nametable[0]`、`bg_nt_offset`、`bg_attr_offset` 全部由 `bg_x_total` 派生，它们必须和**当前** dot 严格同拍；只有 `bg_pattern_addr` 里的 `bg_name` 需要提前。整体 +1 会让 attribute 的 tile 坐标整体右移 1 个 dot，**每一行的 32 列都会取到错误的 attribute quadrant**（`{bg_coarse_y[1], bg_coarse_x[1]}` 选 2 bit 组）。

正确做法是 3.1 的"只抽前瞻支路"：`bg_coarse_x` / `bg_coarse_y` / `bg_attribute_byte` / `bg_nametable` 全部留在 `dot` 上不动，只有发请求的那一份用前瞻 dot。**（已按事实更新）** 实际实现用的是 `bg_look_dot = dot + 9` 这一组前瞻线（`nes_ppu2c02.v:583-604`），没有整体 mux `dot`。这条陷阱**已经被 921,600 次逐 `ce` 逐 dot 的像素比对证伪过一次**：`ppu-ext-chr-tb` 覆盖 `fine_x = 0/3/7` × `mask[1] = 0/1` × `coarse_x = 0/3/5/12/31` 共 5 组配置（其中 3 组 `mask[1] = 1`），全部一致。`chr-feasibility-tb` 的 Q3 反事实测量（整体 mux `dot+1` 会让 32 个 tile 列里恰好 16 列取错 attribute）仍然有效，是这条陷阱的独立证据。

一个可以自查的判据：把 `fine_x` 设成非 0 值、`mask_reg[1]` 打开，跑一帧混合图。如果第 8/16/24... 列和第 7/15/23... 列的属性组不连续，就是踩了这个坑。**（已按事实更新）这一条现在有自动判据**：`ppu-ext-chr-tb` 逐 `ce` 比对 A/B 的 `pixel_index` 与 `dbg_x`（`temp_addr[4:0]`），踩到这个坑会立刻 `$fatal` 而不是需要人眼看图。

---

## 5. 精灵 shadow 预取（**已接线并有像素级证据，但有两条未处理的限制**）

**（已按事实更新）本节描述的 `dot 257..272` shadow 预取现在已经接进 `g_chr_external`**（`start = (dot == 9'd257)`，`shadow` 按 slot 解复用喂 `chr_sh`），不再是一行 RTL 都没有，**精灵像素的等价性也已经有 A/B 证据**（`ad3c17a`，逐条见 11.3.1 第 1 条）。**剩下两条限制**：(a) **仲裁无握手无背压**；(b) **§8.2 那个"用下一行 OAM 计数"的 overflow **行为**差异未实现、因此仍不可观测**——`$2002` 的 overflow **标志位**一致本身已由 2,048 个 dot 证明，而 8×16 高度、每行 8 个 sprite 上限、水平/垂直/双翻转**都已在 9 个精灵场景里各自 A/B 证明**，剩下的是这 9 个场景没构造出来的优先级组合。（先前记在这里的 shadow **差一行**、8 位 `chr_sh` 只能交付**一个字节**两条**已修掉**，逐条见 11.3.1。）

### 5.1 hblank 只有 85 dot

一行的 dot 0..340，hblank 是 **dot 256..340，共 85 dot**。精灵通路每 dot 组合重算 8 个 slot，但外部模式下它只能读一个 16 bit 端口（`chr_sh`，低/高两个平面各 8 bit；**已按事实更新**：原为 8 bit 单平面），所以必须先取数再渲染。

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

**（已按事实更新）上面的窗口不是设计意图的复述，而是当前实现的实测事实**，推导写在 `nes_ppu2c02.v:16-36` 的模块头注释里：

- 背景的最后一个请求拍在 **dot 250**，从 **dot 253** 起占有总线；
- 精灵从 **dot 257** 发 `start`，`busy` 覆盖 **dot 257..291**，16 次请求落在 **dot 259..290**，`shadow_valid` 在 **dot 292** 抬起；
- 下一个背景预取在 **dot 324**。

因为 **253 < 257** 且 **291 < 324**，两个窗口互不重叠，所以"精灵优先"的优先级顺序**今天不改变任何背景行为**，背景的取数节拍、`bg_lo_q`/`bg_hi_q` 锁存与每一个背景像素与只接一个取数器时**逐位相同**。**但这条不重叠是触发表达式推出来的、不是总线协议给的**：一旦背景触发点、精灵 start dot 或任一取数器的 `ce` 预算发生变化，**背景请求拍会被静默丢弃且没有背压**（没有 ready 信号，`bg_fetch_due` 是脉冲），表现为那一个 tile 窗口显示错误的 tile。任何改动都必须先重推这三个窗口。

- 请求地址来自 `pat_addr_o[slot*13 +: 13]`，高平面地址 = `pat_addr_o + 8`（14 位回卷）——**注意这里的 `+ 8` 是字节**，与 `nes_ppu_sprite` 内部路径的 `+ 13'd64` **位**是同一件事，见 1.2 的三处约定表。
- `scanline_sel` **本应**在 dot 257..291 期间指向**下一行**；`nes_ppu_sprite` 已经为此加了 `scanline_sel` 输入和 `scanline_chain` 的 X 兜底，但 `nes_ppu2c02` 现在两个分支都把 `scanline_sel` 接成 `scanline`（`:659`）——**这现在是刻意的、正确的接法**（见 11.3.1 第 2 条）：预取要"下一行"的 pattern 地址，已经由 `nes_ppu_sprite` 内部独立的 next-line 链在 `pat_addr_o` 上实现（`scanline + 1`、261 回卷到 0），所以 `scanline_sel` 必须留在本行，否则会连 `s_pat_addr` 一起移到下一行、动到 `EXTERNAL_CHR=0` 路径本 dot 渲染的每一个像素。原先这里造成的"差一行"**已修掉**。
- **（已按事实更新）`chr_we` / `chr_waddr` / `chr_wdata` 不再保持 0。** 外部模式下 CPU 通过 `$2007` 写 CHR 的通路已经接上（`5cc36e7` / `576cc74`），逐条合同与证据见 11.3.2。**这一段（5.3）是精灵 shadow 预取的叙事，端口当时留着只是为了不推翻接口**；写通路的实现与本节的调度窗口没有耦合，但它带来了一条新的失败模式——**写与背景取数在共享 CHR 地址总线上会撞**（实测 96 个写拍里 22 拍相撞），见 11.3.2。

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

`nes_mapper.v` 里的 `dbg_chr_bank_number = chr_bank_offset_r[CHR_ADDR_BITS-1:10]`（第 225 行）**没有改**，抬位宽后它自动变成 7 bit，MMC1 的 5 bit bank 和 MMC3 的 1 KiB 窗口都能正确显示。

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
| `iverilog -g2001 -Wall -t null -s nes_system_v5`（完整依赖闭包） | exit 0，零 error；**9 条 PPU 侧 `@*` 数组敏感性 warning**（`nes_ppu_sprite.v:333,334,334,335,340,360` 6 条 + `nes_ppu2c02.v:445,769,774` 3 条），**外加 1 条 `nes_system_v5.v:413` 的 `chr_rdata` 悬空**——`nes_system_v5` 的 PPU 取默认 `EXTERNAL_CHR=0`，那个分支里 `chr_rdata` 没有读者；`chr_rdata` 在 `nes_system_v6` 里才是被 `g_chr_external` 的平面锁存真正读过的（见 11.1）。与本次改动无关 |
| `.\tools\sim_all.ps1 -Mode mapper` | `PASS (4 of 4)` |
| `.\tools\sim_all.ps1 -Mode system` | `PASS (8 of 8)` |

位宽修正本身**零行为变化**：所有原有 offset 期望值都 < 64 KiB，抬到 17 bit 后逐位相同，所以 `mapper-*` 与 `system-v0`..`v5` 的既有断言一条没动也没破。

### 9.4 仍然没有做的部分

**位宽修完不等于外部 CHR 能用。** 下面这些里第 1、2、3 条的状态都变了：

- ~~**外部 CHR 取数逻辑仍然一行都没写**~~ —— **（已按事实更新）背景取数已实现，精灵预取已接线**。`g_chr_external` 现在**同时**例化 `nes_chr_fetch_unit`（背景）与 `nes_sprite_chr_fetch`（精灵），`chr_req` / `chr_addr` 是精灵优先的**组合优先 mux**（`:686-687`，`sp_bus_sel = sp_busy`，**无握手无背压**），`chr_rdata` 被读进 PPU 侧 `bg_lo_q` / `bg_hi_q` / `bg_ready`（背景）与 `sp_shadow`（精灵）；`nt_fetch` 影子数组已删除，改直接读 `nametable_ram` 第二读口。**但** `$2007` 对外部 CHR **读**恒得 0（`$2007` **写**已实现，见 11.3.2）、写与取数在共享地址总线上会撞且**未修**（11.3.2）、片上无任何 CHR 存储，**精灵像素的等价性已经有 A/B 证据但专项覆盖仍有缺口**（`ad3c17a`，见 11.3.1 第 1 条）。接线、取数节拍与像素级证据见第 11.1 节，未实现项见 11.3 节。
- ~~**`chr_bank_offset` 仍然没接进 PPU**~~ —— **（已按事实更新）`nes_system_v6` 上 mapper 的读通路已接通、`$2007` 写通路也接通了。** PPU 侧**不做 bank 算术**：`nes_ppu2c02` 导出 14 bit 的 `chr_addr` / `chr_waddr`（`nes_ppu2c02.v:299` / `:297`），但只有 **13 bit 有效**（bit 12 是 pattern-table 选择位，`chr_addr[13]` 声明了但恒 0），把它翻成最终 17 bit CHR 字节地址是 `nes_mapper` 在 `chr_bank_offset` 上做的事。`nes_system_v6.v:256` 是 `wire [13:0] mapper_ppu_addr = ppu_chr_we ? ppu_chr_waddr : ppu_chr_addr;`（**写优先，否则读**），`nes_system_v6.v:265` 是 `assign chr_final_addr = mapper_chr_bank_offset;`。`nes_system_v5` **没有跟着改**（`nes_system_v5.v:212` 仍是 `wire [13:0] mapper_ppu_addr = 14'h0000;`，且它的 PPU 取默认 `EXTERNAL_CHR=0`）。**仍然没接通**的是 `ppu_a12`：`nes_system_v6.v:259` 仍绑 `1'b0`，MMC3 的 A12 扫描 IRQ 在系统级依旧不能自时钟；`CHR_ADDR_BITS=17` 只覆盖 128 KiB，MMC3 的 8 bit CHR 寄存器 bit 7 仍会截断。证据与仍然开放的部分见 11.3.2 与 11.3.6。
- ~~**没有任何 TB 把 `EXTERNAL_CHR` 设成 `1'b1`**~~ —— **（已按事实更新）现在有了**。`tb/ppu/tb_nes_ppu2c02_ext_chr.v`（回归目标 `ppu-ext-chr-tb`）在同一 testbench 里例化 `EXTERNAL_CHR=1'b0` 与 `EXTERNAL_CHR=1'b1` 两个 `nes_ppu2c02` 做 A/B 比对，5 组配置 × 3 帧、921,600 次逐 `ce` 逐 dot 的 `pixel_index` + `bg_pa_enable` 比对全部一致。**但它那 921,600 次比对只覆盖背景**——精灵像素的等价性已由 `ad3c17a` 另行证明（见 11.3.1 第 1 条），而 `$2007` 外部 CHR **读**、mapper banking 仍未覆盖或未实现，见 11.3。（`$2007` 外部 CHR **写**的端到端证据在 `tb/system/tb_nes_system_v6.v`，回归目标 `system-v6`，见 11.3.2。）
- **5 个 mapper 子模块自己的 `CHR_ADDR_BITS` 默认值仍是 16**（见 9.2 末段）。目前全靠 `nes_mapper.v` 的显式覆盖，没有直接实例化它们的顶层设计，但这是留给下一个人的陷阱。
- **MMC3 8 bit CHR 寄存器上限 256 KiB 仍会截断**。17 bit 只覆盖 128 KiB；写 `0xC0` 以上的 bank 依然会回绕。这是"取 17 而不是 18"这个选择的已知代价，不在本轮范围内。
- 第 10 节的落地顺序因此**只剩第 3-4 步**：第 1 步（抬位宽）与第 2 步（背景取数 + A/B 逐像素等价）都已完成。

---

## 10. 落地顺序（按当前状态）

1. ~~先把 `CHR_ADDR_BITS` 抬到 17~~ —— **已完成**，见第 9 节（实际改了 2 处 RTL 默认值 + 6 处 TB 显式传参 + 1 处新增 `localparam` + 8 处观察线网位宽，另加 2 处模块头注释）。
2. ~~实现背景取数支路（3.1 - 3.6），只接 BG，sprite 仍走 `chr_sh = 8'h00`。用一个"外部 CHR = 内部 `chr_ram` 镜像"的 TB 模型，要求 `EXTERNAL_CHR = 1` 的整帧像素与 `EXTERNAL_CHR = 0` **逐像素相同**。~~ —— **已完成**。实现方式与 3.1-3.6 的设想有出入（逐 tile 流水而非整行突发、nametable 第二读口而非复制、dot 324 而非 dot 340），见 11.1.2；`ppu-ext-chr-tb` 在 5 组配置 × 3 帧下做了 921,600 次逐 `ce` 逐 dot 的 A/B 像素比对，全部一致，见 11.1.3。**这一句描述的是背景落地时的状态**：现在精灵也已接线（`chr_sh` 由 shadow 驱动）**并且精灵像素的等价性已经由 A/B 证明**（`ad3c17a`），见 11.3.1。**
3. 实现精灵 shadow 预取（5.3 - 5.4）。**取数与接线这一步已完成**（`g_chr_external` 例化 `nes_sprite_chr_fetch`、dot 257 发 `start`、`shadow` 解复用喂 `chr_sh`、组合优先 mux、每行 16 次请求已验证），**"整帧逐像素相同"这一步也已由 `ad3c17a` 完成**——A/B TB 已从全 0 透明精灵图案换成非透明图案、加了精灵可见性自检并重跑同一套判据。11.3.1 列的限制里，shadow 差一行、8 位 `chr_sh` 单字节、精灵像素无证据三条**已修掉**（`3e218bf`、`c6ea299`、`ad3c17a`），**只剩仲裁无背压、§8.2 的 overflow **行为**差异（标志位一致已由 2,048 个 dot 证明）与 9 个精灵场景之外的优先级组合三条仍未解决**；8×16 / 每行 8 个上限 / 翻转已由那 9 个场景逐项 A/B 证明。
4. ~~最后在 `nes_system_v5` 里接 `chr_bank_offset` 组合叠加，并同步处理 `tb_nes_system_v5.v:1499-1507` 那条 `ppu_a12` 断言~~ —— **（已按事实更新）它不再"未开始"，但实现的不是"组合叠加加法器"**。地址/banking 通路改在 `nes_system_v6` 上接通，形状是 mapper `ppu_addr` 输入端上**一个写优先的 mux**：`nes_system_v6.v:256` 是 `wire [13:0] mapper_ppu_addr = ppu_chr_we ? ppu_chr_waddr : ppu_chr_addr;`（`ppu_chr_we` 为 1 时走写地址、否则走读地址），`ppu_we` 直接取 `ppu_chr_we`（`:257`），mapper 在 `chr_bank_offset` 上**组合译码**出最终 17 bit CHR 字节地址，`:265` 的 `assign chr_final_addr = mapper_chr_bank_offset;` 把它导出。**"在 PPU 侧做 `chr_addr_final = chr_bank_offset + ppu_local_addr`"这一版被考虑过并否决**：mapper 的 `chr_bank_offset` 本身就是 `ppu_addr` 的组合函数，一旦 PPU 的本地地址真接到 `mapper.ppu_addr` 上，在 PPU 侧再相加就构成 `chr_addr → mapper.ppu_addr → chr_bank_offset → chr_addr` 的**零延迟组合环**（与本仓库 `nes_ppu2c02` 头注释的告诫同类；2.2 与 11.3.6 记录了这个否决理由）。**这一条里真正仍然开放的部分**已收窄为：`ppu_a12` 未接（仍绑 0，MMC3 扫描 IRQ 在系统级**不能自时钟**；**P1-11 之后计数器 / pending 状态机在 `system-v6` 里已有建模刺激下的真实 RTL 证据**，但绑 0 本身未变、且那不是硬件预测——见 11.3.6 与 [`tb/system/README.md`](../../tb/system/README.md) 的"### P1-11"一节）、写与背景取数、以及**读臂与取数**在共享 CHR 地址总线上的碰撞仍未修（写实测 22/96、读实测 107/396）、片上无任何 CHR 存储且 BRAM 推断无综合证据（外加读臂带来的**新地址建立义务**）。**（`$2007` 读外部 CHR 仍返回 0 这一条已作废，见 11.3.9。）**

第 2 步的"逐像素相同"是这个改造唯一有意义的验收标准：它同时覆盖了第 4 节那个 attribute 陷阱和 3.6 那个 `bg_coarse_y` 共用陷阱。

**（已按事实更新）这一条现在有自动判据。** 第 2 步已达成时，`ppu-ext-chr-tb` 逐 `ce` 比对 A/B 的 `pixel_index`、`bg_pa_enable`、`pixel_valid`、`pixel_x`/`pixel_y`、`dot`/`scanline`、`dbg_v`/`dbg_t`/`dbg_x`/`dbg_w`，并逐个核对 337,450 次 `chr_req` 的地址与 126,546 对锁存平面字节。**第 3 步已用非透明精灵图案重跑同一套判据**（`ad3c17a`）；**第 4 步还要另外解决 11.3.3（渲染期 scroll 写）与 11.3.4（复位后第 0 帧 warm-up）。**

---

## 11. 实施进度

本节记录截至当前仓库状态的实际进度。措辞以 `rtl/nes_core/ppu/nes_ppu2c02.v`、`rtl/nes_core/ppu/nes_chr_fetch_unit.v`、`rtl/nes_core/ppu/nes_sprite_chr_fetch.v`、`tb/ppu/tb_nes_ppu2c02_ext_chr.v` 和 `tools/sim_all.ps1` 的实际内容为准，不做美化。

第 1-10 节写于外部 CHR 通路落地**之前**，其中若干处描述已被本节的实现取代（已在原地标注"已按事实更新"并指向本节）。**第 11 节是当前状态的唯一权威描述。**

### 11.1 已实现：背景外部 CHR 取数通路（有像素级证据）

**背景（不含精灵）的外部 CHR 取数已经实现，并且第一次有了像素级等价证据。** 回归目标 `ppu-ext-chr-tb`（`-g2012`，源文件**五条**：`nes_ppu_sprite.v` + `nes_ppu2c02.v` + `nes_chr_fetch_unit.v` + **`nes_sprite_chr_fetch.v`** + `tb\ppu\tb_nes_ppu2c02_ext_chr.v`——`nes_ppu2c02` 的 `g_chr_external` 现在同时例化两个取数单元，少列任何一个都会在 elaboration 阶段报 `Unknown module type`）打印 `PASS tb_nes_ppu2c02_ext_chr`，单目标实测 **162.5 s**、占全量 **16.83%**，仍是当前 `-Mode all` 里最慢的目标（上一轮 821.6 s / 45.26%，更早一轮 143.7 s / 15.0%）。**R-08 关闭后**（`nes_ppu2c02` 不再重复实现 `nes_ppu_sprite` 已有的精灵范围扫描，改为消费新导出的 `cur_slot_o`），这个目标从 821.6 s 降到 162.5 s、占全量从 45.26% 降到 16.83%，全量从 1815.3 s 降到 965.6 s；**A/B 的四行输出逐字节未变**。详见 11.3.8。

#### 11.1.1 接线方式

| 项 | 位置 | 内容 |
|---|---|---|
| 取数状态机 | `nes_ppu2c02.v:670-684` | `g_chr_external` **例化 `nes_chr_fetch_unit u_chr_fetch`**：`req_start = bg_fetch_due`、`tile_base = bg_tile_base`、`chr_req`/`chr_addr` 直接就是 PPU 的两个输出端口、`chr_rdata` 直接就是 PPU 的输入端口 |
| 平面锁存 | `nes_ppu2c02.v:573-575`、`:692-704` | PPU 侧 `bg_lo_q` / `bg_hi_q` / `bg_ready` 三个寄存器，在 `chr_fetch_bg_valid` 那一拍把 `bg_lo`/`bg_hi` 锁进去并把 `bg_ready` 置 1；复位清零 |
| 消费点 | `nes_ppu2c02.v:606-607` | `bg_pattern_low = (bg_ready && bg_pa_enable) ? bg_lo_q : 8'h00`，`bg_pattern_high` 同理 |
| nametable 读口 | `nes_ppu2c02.v:602` | `bg_name_target = nametable_ram[mirror_nametable(bg_nt_offset_target)]`，**直接读 `nametable_ram` 的第二个组合读口** |
| 单口总线的第二个 master | `nes_ppu2c02.v:633-645`、`:686-687` | `g_chr_external` **例化 `nes_sprite_chr_fetch u_sprite_chr_fetch`**（`start = (dot == 9'd257)`），`chr_req`/`chr_addr` 是 `assign chr_req = sp_bus_sel ? sp_chr_req : bg_chr_req;` / `assign chr_addr = sp_bus_sel ? sp_chr_addr_raw : bg_chr_addr_raw;` ——**组合优先 mux、精灵优先、没有握手也没有背压** |
| 仲裁窗口（实测） | `nes_ppu2c02.v:16-36` 模块头注释 | 背景最后一个请求拍在 dot 250、从 dot 253 起占有总线；精灵 `busy` 覆盖 dot 257..291、16 次请求落在 dot 259..290；下一个背景预取在 dot 324。**253 < 257 且 291 < 324，两个窗口不重叠**，所以优先级顺序今天不改变任何背景行为 |
| 背景侧的应对 | `nes_ppu2c02.v:686-687` | 背景拍在 mux 输出上额外被 TB 断言"mux 不得篡改持有者地址"（`chr_addr == bg_chr_addr`），精灵拍同理断言 `chr_addr == sp_chr_addr` 并单独计数，dot 340 断言**每行恰好 16 次** |

**`nt_fetch` 影子数组已删除。** 早期版本在 `g_chr_external` 里另存一份 2 KiB `nt_fetch[0:2047]` 给取数支路专用读口（3.3 节记的旧方案）。现在改成直接读 `nametable_ram`，因此**"影子数组没有复位、也没从 `nametable_ram` 同步、仿真里全 X 直到 CPU 把整张 nametable 写一遍"这条问题不再存在**——取数支路与渲染支路读的是同一份存储。代价是 `nametable_ram` 变成两个组合读口（不能再推断成单口 BRAM），换来的是省掉 2 KiB 片上存储和一条会失同步的影子链。3.3 节描述的"复制一份 2 KiB"**没有被采用**。

#### 11.1.2 取数节拍：流水式，不是每行一次突发

**这一条是本轮实现里最容易做错的地方。** 3.4 / 3.5 设想的是"整行一次取完 + 行末锁存"，实际落地的是**逐 tile 流水**：每个 tile 窗口单独打一次 `req_start`，请求在窗口开始前 9 拍就发出去，取回的字节在窗口开始时已经在 `bg_lo_q` / `bg_hi_q` 里。

可见区的 tile 窗口起点是

```text
b_k = 8k - fine_x          (k = 0, 1, 2, ...)
```

即 `fine_x` 非 0 时整行窗口整体平移。触发条件在 `nes_ppu2c02.v:577-581`：

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

`tb/ppu/tb_nes_ppu2c02_ext_chr.v`（1,199 行，`$finish` 在第 1190 行）在一个 testbench 里例化**两个** `nes_ppu2c02`，共用同一份 `clk` / `ce` / 寄存器激励：

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
| `dbg_sprite0_hit` / `dbg_sprite_overflow` | 逐 `ce` 比（背景落地那一轮是透明精灵图案、两者恒 0；`ad3c17a` 之后 A/B 另加七个精灵可观量的比对，见 11.3.1 第 1 条） |
| `chr_we` / `chr_wdata` | **（已改目标）`A6 $2007-WRITE-STROBE`**，见 11.3.2。原先的"`chr_we` 恒 `1'b0` / `chr_wdata` 恒 `8'h00`"在写通路落地后已经**陈旧**：现在断言"`chr_we` 为高 ⟺ 该拍是真实的 `reg_cs && reg_we && reg_addr == 7` 写周期，且 `chr_wdata == reg_din`"。**这条 TB 故意没有写场景**，所以实测到 0 个 strobe 拍；这是诚实的 0 而不是空洞，原因与端到端证据的位置见 11.3.2 |
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

**（这一段是背景落地那一轮的记录）** 那 921,600 次比对在那一轮没有扩大覆盖范围：四行输出与上一轮**逐字节相同**，新增的断言全部落在接线与总线归属层面。**后续轮次已经把精灵纳入同一条 A/B**（`ad3c17a`）：除 `pixel_index` 之外另比七个精灵可观测量，在 **552,960** 个比较点上**全部 0 分歧**，其中 **1,708** 个精灵决定像素覆盖透明背景 / 不透明背景前 / 不透明背景后三类、**6,144** 个 dot 上恰好 8 个精灵在范围内、**2,048** 个 overflow dot——**逐条数字见 11.3.1 第 1 条**。

### 11.2 `nes_chr_fetch_unit` 接口的三条限制，以及 PPU 侧的对策

`nes_chr_fetch_unit` 本身**没有改**（仍是 6 态 FSM + `bg_lo` / `bg_hi` / `bg_valid` 三个输出口 + 6 bit `tile_count`）。它的接口形状决定了 PPU 侧必须这么接：

| 限制 | 事实 | PPU 侧对策 |
|---|---|---|
| **只暴露最后一个 tile** | `bg_lo` / `bg_hi` 是"行末那个 tile"的寄存器；`tile_count > 1` 时前面 `tile_count-1` 个 tile 的字节确实取回来了，但**没有任何端口把它们交出来** | 因此 `nes_ppu2c02.v:676` 把 `tile_count` **按 1 使用**（`.tile_count(6'd1)`），每个 tile 窗口单独打一次 `req_start`，靠 11.1.2 的 9 拍流水节拍把单 tile 取数摊开到一整行上。`tile_count` 那个"可数到 33"的 6 bit 端口在 PPU 侧**没有用上** |
| **延迟 8 个 `ce`** | `req_start` 被接受的那一拍算第 1 拍，`tile_count = 1` 要走 `S_IDLE → S_PRE → S_ARM → S_BEAT → S_GRAB → S_BEAT → S_GRAB → S_DONE` 共 8 拍，`bg_valid` 才在第 8 拍抬起 | 这 8 拍由流水节拍吸收：请求在 `b_k - 9` 发出，字节在 `b_k - 1` 锁进 `bg_lo_q` / `bg_hi_q`，`b_k` 那一拍已经在用 |
| **`bg_valid` 是脉冲** | `S_DONE` 只执行一拍，`bg_valid <= 1'b1` 下一拍进 `S_IDLE` 就被清掉；`bg_lo` / `bg_hi` 本身保持不变，但**没有"数据仍然有效"的握手** | PPU 侧必须配锁存：`bg_lo_q` / `bg_hi_q` / `bg_ready`（`nes_ppu2c02.v:692-704`）在 `bg_valid` 那一拍把数据接住，之后一直保持到下一次 `bg_valid` |

### 11.3 仍未实现 / 仍未覆盖

**下面每一条都是当前真实状态，不得弱化。**

#### 11.3.1 精灵通路已接线：精灵像素等价性已有证据，剩下两条限制

**精灵预取单元已经接进 `g_chr_external`**；"外部模式能正确渲染精灵"现在**有 A/B 证据**（`ad3c17a`），**但覆盖范围有限**——下面四条限制里第 1、2、3 条已修掉，**剩下两条**必须记下来：第 4 条的仲裁无握手无背压，以及第 1 条末尾那段残留缺口（§8.2 的 overflow **行为**差异、9 个场景之外没构造出来的优先级组合）。

| 项 | 现状 |
|---|---|
| `nes_sprite_chr_fetch` 例化 | **有**，`nes_ppu2c02.v:752-764`，`start = (dot == 9'd257)`（`assign sp_start`，`:744`） |
| `sprite_pat_addr_bus` | **有消费者**——它就是 `u_sprite_chr_fetch` 的 `pat_addr` 输入（`nes_ppu_sprite` 的 `pat_addr_o` 导到 PPU 层再进预取单元，`:785` / `:757`） |
| 内部路径的精灵 CHR 字节（**已按事实更新**） | **`sprite_chr_bus` 这根 65536 bit 展平总线已在 `575e191` 删除**。`g_chr_internal` 现在用 `g_sprite_chr_slots`（`:602-607`）的 **8 次迭代、16 次读**拼出 128 bit `sprite_chr_slots`，经 `.chr_slots(...)`（`:619`）喂进精灵单元的 `g_chr_per_slot` 分支（`.PER_SLOT_CHR(1'b1)`，`:611`）。**外部模式不读 `chr_ram`、也不读 `chr_slots`**：精灵平面字节来自 `sp_shadow` 解复用出的 `chr_sh[15:0]`；两个分支都传 `.chr(65536'd0)`（内部 `:617`、外部 `:773`），而那只是 `g_chr_flat` 这条默认路径的未读实参 |
| `chr_sh` | **不再绑 `8'h00`**，改由 `sp_chr_sh` 驱动（`:750`、`:774`） |
| `dot 257..272` shadow 预取（5.1-5.4） | **已实现**，但窗口实测是 **dot 257 发 start / dot 259..290 发 16 次请求 / dot 291 落 busy / dot 292 抬 `shadow_valid`**，与 5.3 原始设想的 `257..272 / 273..340` 划分不同 |

**第 1、2、3 条已修掉（第 2、3 条在本节，第 1 条见上），剩下两条必须记下来——第 4 条的仲裁，以及第 1 条末尾那段残留缺口（§8.2 的 overflow **行为**差异、9 个场景之外没构造出来的优先级组合）：**

1. **精灵像素的等价性没有证据 —— 已修掉（`ad3c17a`）。** 原先的根因是 A/B TB 用的仍然是透明精灵图案：`tb_nes_ppu2c02_ext_chr.v` 把全部 64 个 OAM 项的 tile 号设成 `8'h00`、attribute 设成 `8'h00`，而 `chr_mem[0..511]`（8×8 tile 0、8×16 的下半、以及 sprite pattern table 0/1 的前 512 字节）全为 `8'h00`，所以**连 A 侧的精灵也全是透明图案**（`chr_ram` 预载成同一批数据），两个实例的 `dbg_sprite0_hit` 与 `dbg_sprite_overflow` 因此逐 `ce` 恒为 0 且互相一致——`mask_reg[4]` 打开时两边画面"必然不同"这一点当时**没有被任何 TB 断言为差异，只是被测试图案绕开了**。现在 OAM 的 tile 号 / attribute 与 CHR 字节已换成**非透明图案**，并加了**精灵可见性自检**先断言 A 侧确实有非背景精灵像素，于是"A/B 一致"不再可能是空的。实测（`iverilog -g2012`，退出码 0，打印 `PASS tb_nes_ppu2c02_ext_chr`）：

   | 证据 | 数字 |
   |---|---|
   | A/B 比较点 | **552,960** |
   | 被比的精灵可观测量 | **7**：`mixed_pixel` / `sprite_pixel` / `sprite_priority` / `raw_sprite0_hit` / `raw_sprite_overflow` / `registered_sprite0_hit` / `registered_sprite_overflow` |
   | **分歧总数** | 七项**全部 0**（`mixed_pixel=0 sprite_pixel=0 sprite_priority=0 raw_sprite0_hit=0 raw_sprite_overflow=0 registered_sprite0_hit=0 registered_sprite_overflow=0`） |
   | 精灵自检 | `sprite_pixel_nonzero_dots=1708`、`sprite_decided_pixels=1708` |
   | 三类优先级都走到 | 透明背景上 **908**、不透明背景前 **564**、不透明背景后 **236**（合 1708） |
   | 恰好 8 个精灵在范围内 | **6,144** 个 dot |
   | overflow | **2,048** 个 dot |
   | 跨扫描线 skew 检查 | B 从 A 的**上一条扫描线**复现的 mixed-pixel 分歧 **0 of 0** |
   | 背景侧数字未变 | `A3 verified request addresses=337450 verified latched plane pairs=126546` |

   **这不是 TB 只用透明图案的"伪一致"**：三类优先级、8 精灵饱和与 overflow 都被真正走到了。**但边界必须一起转述**：这是 `EXTERNAL_CHR=0` 与 `EXTERNAL_CHR=1` 两个实例之间、在 TB 驱动的那几组场景下的 A/B，**不是实机卡带、不是 NESdev test ROM、不是硬件**，而且 8×16 高度、每行 8 个 sprite 上限、水平/垂直/双翻转**都已由 9 个精灵场景各自 A/B 证明**（每组有自己的非空洞 `$fatal`、计数器逐组清零、每组 `mismatched_pixels=0`）——**不要再把它们记成"没有证据"**；仍无证据的只有 §8.2"用下一行 OAM 计数"那个 overflow **行为**差异（未实现、所以仍不可观测；**标志位**一致本身已由 2,048 个 dot 证明），以及这 9 个场景之外没构造出来的优先级组合，见下面第 4 条与 11.5。
2. **shadow 差一行 —— 已修掉。** 原先 `pat_addr_o` 由 `nes_ppu_sprite` 从 `scanline_sel` 算出，而 PPU 两个分支都把 `scanline_sel` 接成 `scanline`（`:659`）；fetch 在同一行的 dot 292 才落地。所以**一行消费的 shadow 原本是上一行 dot 257 锁存的那一份**。`pat_addr_o` 现在改用**下一行**的 scanline 算——`nes_ppu_sprite` 内部为此单建了一条 next-line 链（`scanline + 1`、261 回卷到 0，`pat_addr_o[g*13 +: 13] = nl_pat_addr`），所以 dot 257 发起的预取在 dot 292 落地的正是**下一行**要用的那一份。**`scanline_sel` 仍直连 `scanline` 是刻意的、也是正确的**：同一条链还要选 `s_pat_addr`，而 `s_pat_addr` 是 `EXTERNAL_CHR=0` 路径本 dot 渲染用的值，把 `scanline_sel` 改成下一行会移动每一个内部渲染像素的 pattern 行。修法见 `ad3c17a` / `3e218bf`。
3. **8 位 `chr_sh` 只能交付一个字节 —— 已修掉。** 原先 `nes_ppu_sprite` 的 `g_chr_external` 分支**两个平面都直接取 `chr_sh`**（`assign s_plane_lo = chr_sh; assign s_plane_hi = chr_sh;`），所以 PPU 侧必须二选一，做法是取 `shadow[g*16 +: 8] | shadow[g*16+8 +: 8]`（`:629-631`）——**按位或**——这让精灵轮廓是精确的，但把每一个不透明像素强制成 palette index `3`，高平面实际上**根本没有被交付**。现在 `chr_sh` 已是 **16 bit** 并**真正交付双平面**：`assign s_plane_lo = chr_sh[7:0]; assign s_plane_hi = chr_sh[15:8];`，PPU 侧相应改成拼接而不是按位或（`assign sp_chr_sh = sp_shadow_valid ? {sp_plane_hi, sp_plane_lo} : 16'h0000;`，`:631`），内部路径的 tie-off 也从 `8'h00` 加宽到 `16'h0000`。修法见 `3e218bf`。**`sp_shadow_valid` 门控仍然必须保留**：`nes_sprite_chr_fetch` 的 `shadow` 寄存器**没有复位**，第一行完成之前它是 X，X 送到 `chr_sh` 会让 `slot_opaque` / `sprite_pixel` 变 X 并污染像素。
4. **仲裁无握手、无背压。** `sp_bus_sel = sp_busy` 的组合优先 mux 只在两个窗口不重叠时正确（见 11.1.1）。一旦重叠，**背景请求拍会被静默丢弃**：单元继续计数、`bg_valid` 仍晚 1 拍抬起，于是 `bg_lo_q`/`bg_hi_q` 锁进错误的字节、那个 tile 窗口显示错误的 tile，而**没有任何机制会报告**。反之若改成背景优先，丢的就是精灵的 16 拍，整行精灵图案错位。

**后续做法（下一轮要做的事，按顺序）：**

- ~~把 `tb_nes_ppu2c02_ext_chr.v` 的 OAM tile 号 / attribute 与 `chr_mem[0..511]` 换成**非透明图案**（例如 tile 号打散、attribute 覆盖 palette 组、CHR 字节用可辨识图样），并加一条**精灵可见性自检**——先断言"A 侧在这些 OAM 下确实有非背景精灵像素"（例如 `pixel_index` 落在 palette 3..15 的计数 > 0、或者逐 slot 断言某个 sprite 的 8 个像素等于期望颜色），否则"改图案"可能仍然改出一张全透明的帧，A/B 一致仍然是空的~~ —— **已完成**（`ad3c17a`），见 11.3.1 第 1 条。
- ~~修 shadow 差一行（第 2 条）~~ —— **已完成**，见 11.3.1 第 2 条。
- ~~加宽 `nes_ppu_sprite.v` 的 `chr_sh` 以交付双平面（第 3 条）~~ —— **已完成**，见 11.3.1 第 3 条。
- ~~补精灵专项覆盖：**8×16**、**每行 8 个 sprite 上限**（第 9 个之后的 sprite 不渲染）、**sprite overflow 标志位**、**水平/垂直/双翻转**~~ —— **已完成**：A/B TB 现在跑 **9 个精灵场景**，每组有自己的非空洞 `$fatal`（`case_sp_*` 计数器逐组清零，每组 `mismatched_pixels=0`）——`sp1-8x16-oddtile`（8×16 + 奇 tile 字节，40 个精灵决定像素）、`sp8-8x16-mixprio`（8×16 + 8 精灵 + 混合优先级，560 个、其中"不透明背景后" 80 个）、`sp8-8x8-limit`（每行 8 个精灵，2,048 个"恰好 8 个在范围内"的 dot）、`sp10-overflow`（10 精灵，2,048 个 overflow dot，标志位 A/B 一致）、`sp1-hflip`（48）、`sp1-vflip`（56）、`sp1-hvflip`（56）。**仍未做**：§8.2"用下一行 OAM 计数"的 overflow **行为**差异（未实现，所以不可观测），以及这 9 个场景之外没构造出来的**优先级组合**。
- 第 10 节第 3 步的"整帧逐像素相同"在**精灵打开时**现在已经**成立并被断言**（`ad3c17a`）；下一步要补的是上面那条残留（§8.2 的 overflow **行为**差异、9 个场景之外的优先级组合），以及第 4 条的仲裁无背压。

#### 11.3.2 `$2007` 写 CHR：已实现并有端到端证据；**碰撞**仍未修

**（已按事实更新两次）这一节原来的标题是"`$2007` 写 CHR 仍被丢弃"，那句话现在不成立；后来又在标题里挂了"读回仍返回 0"，那半句在读臂那一轮也不成立了。** 提交 `5cc36e7` / `576cc74` 实现了写通路，端到端证据在 `tb/system/tb_nes_system_v6.v`（回归目标 `system-v6`，**6597** 行）。教学与逐条推导见 [`docs/ppu_chr_external_write.md`](../ppu_chr_external_write.md)。**读通路的对应一节是 11.3.9。**

##### 已实现的部分

`nes_ppu2c02.v:813-816`（写通路落地那一轮结束时是 `:712-715`）：

```verilog
assign chr_waddr = (v_addr < 15'h2000) ? v_addr[13:0] : 14'h0000;
assign chr_we    = !reset && reg_cs && reg_we && (reg_addr == 3'd7)
                   && (v_addr < 15'h2000);
assign chr_wdata = reg_din;
```

`g_chr_internal` 把 `chr_waddr` 绑成 `14'h0000`（`:639`；写通路落地那一轮结束时是 `:543`），`chr_we` / `chr_wdata` 在内部分支**仍然不驱动**（模块头注释 `:266` 记的就是这条合同）。`nes_mapper.v` **一行未改**——它的 `chr_ram_we = chr_ram_enable_r && ppu_we && (ppu_addr[13] == 1'b0)`（`:221`）本来就是对的，`ppu_we` 之前只是恒 0。`nes_system_v6` 把三个信号导出成观测端口并让**写优先**于读共用 mapper 地址总线（`mapper_ppu_addr = ppu_chr_we ? ppu_chr_waddr : ppu_chr_addr`）。

| 证据组 | 断言 | 实测 |
| --- | --- | --- |
| **P0-2 WRITE-TRANSLATION** | 每个写拍从 TB 自己的 bank 模型与 PPU 的**本地** `chr_waddr` 重建期望最终地址 `expected = (tb_chr_bank_model << 13) \| (chr_waddr & 0x1fff)`，并核对 `chr_waddr == ` **自增前**的 `u_ppu.v_addr`、`chr_waddr[13] == 0`、`local[12:0] == final[12:0]`、`final[16:13] == 0`、`chr_wdata == reg_din`。**这一条是新增的**：`chr_we` 从不抬 `chr_req`，所以原先门在 `chr_req` 上的 P0-2 对写地址是**零覆盖** | **96 / 96** 核对，**0** 错 |
| **W1 NROM-CHR-RAM-WRITE** | 96 个 `$2007` 写拍；**总线侧独立统计**的"进入 CHR 半区的 `$2007` 写"数同样 96（相等 → 每一次写恰好产生一个 strobe）；mapper 接受 96/96；写拍翻译错 0；连续两个 `ce` 上 `chr_we` 为高 **0** 拍 | 见左 |
| **W1 SENTINEL（非空洞）** | 每块 CHR-RAM 板跨**每一个 4 KiB 块**预载的是程序所写的**逐位取反**（`ab_v6` 上传 `ff 00 00 ff ff 00` / 预载 `00 ff ff 00 00 ff`；`chr_ram_b` 反过来）。漏掉任一次写，渲染就会显示哨兵那一档 pattern 值，该处逐 `ce` A/B 与具名像素类**两条同时失败**。在程序自己置起的 `ram[0015]` 标志处：96 个字节全部等于程序常量（错 0）、仍持哨兵 **0** 个；`chr_mem[$2000+d]`（超出 PPU 能产生的**每一个**地址，`chr_final_addr` 顶到 `$1FFF`）的 48 个字节**仍是哨兵** | 96/96、0、0；48/48 |
| **W1 SELF-VALIDATING-PAIR** | `chr_ram_b` 跑**字节完全相同的代码**、两份 PRG 镜像只差填充循环读的那两个数据单元，因此上传**互补**的图像。两块板 strobe 拍数必须相等否则 `$fatal`；`chr_ram_b` 错误地仍停在 run A 图像上的字节 **0**。最后一帧按 4 `clk`/dot 采样比较 | **245,760** 个 clk 采样、**0** 处几何差异（两次运行真在锁步）、画面在**全部 245,760** 个采样上**不同**，其中 **15,360** 个落在可见扫描线**最左 16 列**（BG tile 0 / 1 所在处） |
| **CHR-RAM vs CHR-ROM 忽略对（`chr_rom` / `ab_v6`）** | 同一份程序、同一批地址、同一批字节，**只有 `NROM_CHR_RAM` 不同**。配对前提：两块板 strobe 数相等 | **96 vs 96**；`mapper_chr_ram_we` 在 ROM 板 **96** 个写拍上**为低 0 次**（且该板 `chr_ram_enable` 本身是 0），RAM 板上**每一个**都为高；ROM 板 **131,072** 字节里**改变 0** 个；两块板最后一帧渲染出**完全相同**的画面 |
| **W2 MMC3 bank 限定写** | 3 个写拍、3 个被接受、写拍翻译错 0。r0 = `$00` + 本地 `$0040` 的一字节落在 `chr_final_addr $00040`；**同一个本地地址**在 r0 = `$42` 时落在 `$10840`（相距 **67,584** 字节）；第三字节在本地 `$0840`（bit 11 置位）选中 r0 的奇 1 KiB，落在 `$10c40`。跨整个 128 KiB 阵列恰好 **1 / 1 / 1** 个字节改变，别处一个都没有 | 三写三址 |
| **P0-3（重新验证）** | `chr_final_addr[13]` 在 **96** 个写拍上置位 **0** 次；本地 bit 12 在 **16,768** 次读请求上置位 | 0 / 96 |
| **P0-1（重新验证）** | 复位窗口内 `chr_we = 0`、`chr_waddr = 0` | 成立 |
| **P0-7（重新验证）** | **5 步**（3 步原版 `$8001` 写 `$00`/`$01`/`$41` + W2 的 2 次 r0 写 `$00`/`$42`）逐档错 **0**，**四份**预载 bank 图像两两不同仍成立。(a) 翻译 `chr beats total=146556`、逐档 `20961/20961/20956/20961/43581`、`err=0/0/0/0/0`，DUT 的 `chr_final_addr[16:10]` 每档首值 `00000000/00000000/00000040/00000000/00000042`（第 4、5 步就是 W2 那一对，**故意**留在分档统计里，好让每一次写都被分档覆盖）。(b) 具名索引 `1`(1920/1920) / `1`(1920/1920) / `8`(1920/1920) / `1`(1920/1920) / `8`(3843/3843)，strays 全 0。(c) `$41` 档 R0=`$40`，`chr_final_addr[16]==1` 在 **20956/20956** 拍成立 | 5 步、0 错 |
| **P0-8（重新验证）** | `chr_req` 从不在连续两个 `ce` 上为高：`ab_v6` **0 of 625396**、`chr_mmc3` **0 of 625396**；背景与精灵两个取数单元从不在同一 `ce` 上同时要数据：**586074** / **586226** 个采样拍、**0** / **0** 次碰撞。**新增**：`chr_we` 也从不在连续两个 `ce` 上为高（两块板各 **0** 次）；读写仲裁**数出来**而不是假定：写拍与 `chr_req` 拍重合的有 **22 of 96**（`ab_v6`）与 **2 of 3**（`chr_mmc3`），其中背景或精灵开着的有 **0** 个 | 0 / 0 / 0 |

**为什么 `ab_v6` 本身必须是 `NROM_CHR_RAM = 1`**：`mapper_chr_ram_we` 为 0 时写通路在这个 testbench 里结构上是死的（TB 的 `chr_mem` 写入被 `chr_we && mapper_chr_ram_we` 门住），什么都不会被观测到。做成 RAM 板正好让 **P0-4 整帧 A/B 自己变成这条通路最强的检查**——`ab_v5` 的内部 `chr_ram` 与 `ab_v6` 的外部 `chr_mem` 都从哨兵出发、也都只可能因为程序自己的写才变成那张图。

**`ppu-ext-chr-tb` 的 A/B 数字逐字节未变**（`S3` 七个精灵可观测量全部 `= 0`、`A3 verified request addresses=337450 verified latched plane pairs=126546`、`S2 request_beats=159296 … shadow_byte_mismatches=0`）——**写通路的加入没有让 PPU 的渲染行为发生任何漂移**。

##### `ppu-ext-chr-tb` 为什么故意没有写场景

那条 A/B TB 的像素比对把 `EXTERNAL_CHR = 0`（**逐 dot 组合**）与 `EXTERNAL_CHR = 1`（**一次取数提前**）放在一起比。渲染中期写 CHR 会让**两侧结构上不再等价**：内部那一侧立刻看到新字节，外部那一侧要等 1 dot 甚至更久。如果在那里加一个写场景，上面 921,600 / 552,960 那几组 A/B 数字就**不再有意义**——它们会开始测量"两侧架构不同"而不是"外部通路等价"。所以这条 TB 只保留一条**诚实的 0**：`A6 $2007-WRITE-STROBE` 断言"`chr_we` 为高 ⟺ 该拍是真实的 `reg_cs && reg_we && reg_addr == 7` 写周期，且 `chr_wdata == reg_din`"，而本 TB 的 `write_register` 只用地址 6/6/5/5/0/1、`read_status` 只用地址 2，**`reg_addr` 从来不是 7**，所以 strobe 合法地为 0 拍。端到端证明放在 `system-v6`。

##### 仍然开放的一条

- **（b）写/读碰撞在共享 CHR 地址总线上是一个未修的潜伏隐患。** `chr_req` **不被写压制**（`nes_ppu2c02.v:809` 是一组取数单元**加上读臂**的组合 mux；写通路落地那一轮结束时是 `:709`，那时只有两个取数单元），`bg_fetch_due`（`:700`，写通路落地那一轮结束时是 `:604`）也没有扫描线门控也没有 mask 门控，所以两者可以独立地在同一个 `ce` 上为高。实测 **96 个写拍里 22 个**与在飞的背景取数相撞；那一拍 `chr_final_addr` 上是**写地址**，因此改用**写模型**核对（`P0-2 WRITE-READ-ARBITRATION` 把这件事测量出来而不是假定），代价是取数单元那一拍锁到写地址的字节。**本轮那 22 次碰撞 0 次落在 `bg_pa_enable` 为高或精灵打开的 scanline 上**（上传程序跑在 `PPUMASK = $00` 下），所以渲染结果未受影响——**但这不等于已修复**。一个在渲染中期写 CHR 的程序会有**一个 tile 拍**取到错字节。这是硬件形状（2C02 只有一根 CHR 地址总线）而不是接线错误，修法要么压制 `chr_req`（会破坏取数节拍）、要么给总线加握手/背压（本端口**没有**）、要么把上传窗口限制在关渲染时，**三条本轮一条都没做**。**读臂那一侧是同一条隐患的第二个实例**（396 个读臂里 107 个撞上取数），登记为 L-20，见 11.3.9 与风险登记册。

##### 另外三条仍然开放

- **片上没有任何 CHR 存储**：那 128 KiB CHR **只活在 testbench 里**（每个外部实例一份 TB 侧模型）。真实系统需要 SDRAM，而 SDRAM 控制器在仓库里**还不存在**。
- **`ppu_a12` 仍绑 0**（见 11.3.6），所以 MMC3 的 A12 扫描 IRQ 在系统级仍不能自时钟。**P1-11 之后计数器 / pending 状态机与 IRQ 入口链在 `system-v6` 里已有建模刺激下的真实 RTL 证据**（`irq_pending_r` 由 RTL 产生），但**那不是硬件预测**：绑 0 未变、每帧 241 是文献值、依赖精灵的 A12 变化未建模。
- **BRAM 推断没有证明**：没有 Quartus / Fitter / STA。同址同拍的写读冲突在本模型里 undefined、testbench 建模成 read-first；真双口够不够、还是必须 simple dual port，**没有综合数字就不能回答**。

第 8 节 8.1 登记的"`$2007` 写 CHR 后渲染晚 1 dot"现在**第一次有了一条真实通路可以被测量**，但本轮没有为此单独构造场景，所以**它仍然既没有被量化、也没有被验证**。

#### 11.3.3 渲染期间的 `$2005` scroll 写会移动触发相位，TB 未覆盖

外部模式的取数触发相位（`b_k = 8k - fine_x`，请求在 `b_k - 9`）是在**触发的那一拍**用当时的 `fine_x` 和 `temp_addr[4:0]` 算出来的，而**已经在取的那一行**的 tile base 已经进了 `nes_chr_fetch_unit` 的 `base_q`。因此在可见区中间写 `$2005`（改 `fine_x` 或 `coarse_x`）之后：

- 内部路径（`g_chr_internal`）的 `bg_x_total` 是**每拍组合**跟着 `dot` / `fine_x` / `temp_addr` 走的，立刻跟随；
- 外部路径只在下一个触发点重新取相位，**已经锁进 `bg_lo_q` / `bg_hi_q` 的 tile 不会回退重取**。

两者会分叉。`tb_nes_ppu2c02_ext_chr.v` 的 `set_config` 在第 0 帧之前一次性写完 `$2005` / `$2000` / `$2001`，5 组配置之间也不中途改 scroll，**渲染期间写 `$2005` 一条也没有覆盖**。这是当前 A/B 证据的一条明确边界。

#### 11.3.4 复位后需要 1 行 warm-up

复位把 `bg_lo_q` / `bg_hi_q` 清 0、把 `bg_ready` 清 0，而 `bg_ready` 之后**只置位不清零**。复位后第一行前半段（`bg_pa_enable` 已为 1 但流水线还没 priming）拿不到正确 pattern。TB 在 `frame_cnt >= WARMUP_FRAMES` 之后才要求 `bg_ready` 必须为 1（`:368-371`），并**丢弃每组的第 0 帧**。也就是说 **921,600 次比对覆盖的是第 1 / 2 / 3 帧，复位后第 0 帧的背景像素没有被验证**。

#### 11.3.5 非连续 `ce` 下 `chr_req` 脉冲可能被拉长

`nes_chr_fetch_unit` 的 `chr_req` 在 `ce = 0` 时冻结（输出逐拍不动），`ce` 空洞会把 `chr_req` 的高电平**拉长到多个 `clk`**，而不是保持 2.1 节合同里的"1 拍 `ce` 宽脉冲"。这不是 bug，是 `ce` 门控的直接后果。第 4 组配置用 `ce_div = 3`（`ce` 1-in-4）跑通 3 帧，说明真实分频比下流水仍成立；但**没有断言 `chr_req` 的脉宽**。`nes_system_v5` 的 `ce_ppu` 是**连续 1-in-4**（`div_phase` 自由运行），所以这个差异在系统里实际不发生。

#### 11.3.6 mapper 侧的 `chr_bank_offset` **已接通**（`nes_system_v6`）；仍未接通的是 `ppu_a12`

**（已按事实更新）本节原标题是"mapper 侧的 `chr_bank_offset` 仍未接进 PPU"，那句话现在不成立。** 现在 `nes_system_v6` 上 mapper 的 CHR 地址翻译是**接进 PPU 的**：

- **PPU 发的是本地地址，不是 CHR 字节地址。** `nes_ppu2c02` 导出 14 bit 的 `chr_addr` / `chr_waddr`（`nes_ppu2c02.v:299` / `:297`），但只有 **13 bit 有效**：bit 12 是 pattern-table 选择位（背景 `bg_tile_base` 是 13 bit 的 `{control_reg[4], bg_name_target, 4'b0000} + {10'b0, bg_fine_y_target}`；精灵 `s_pat_addr` 是 `{s_table, s_tile, 1'b0, s_fine[2:0]}`），`chr_addr[13]` **声明了但恒 0**（两个取数单元的地址都封顶在 `0x1FFF`——这是结构上限而不是覆盖缺口）。**PPU 侧没有任何 bank 算术**，加法器放在这里是错的：`chr_bank_offset` 本身就是 `ppu_addr` 的组合函数，在 PPU 侧后加会构成零延时组合环。
- **翻译是 `nes_mapper` 做的。** `nes_system_v6.v:256` 的 `wire [13:0] mapper_ppu_addr = ppu_chr_we ? ppu_chr_waddr : ppu_chr_addr;`（**写优先，否则读**）喂进 mapper 的 `ppu_addr`，`ppu_we` 直接取 `ppu_chr_we`（`:257`），mapper 在 `chr_bank_offset` 上产出最终地址，`nes_system_v6.v:265` 的 `assign chr_final_addr = mapper_chr_bank_offset;` 把它导出成 17 bit 的 CHR 字节地址。
- **写通路也接通了**（`5cc36e7` / `576cc74`），由 mapper 的 `chr_ram_we` 门控，实测 96 个写拍、0 翻译错，见 11.3.2。
- **`nes_system_v5` 没有跟着改**：它仍然是 `wire [13:0] mapper_ppu_addr = 14'h0000;`（`nes_system_v5.v:212`）且 PPU 取默认 `EXTERNAL_CHR=0`，所以 v5 及更早的板子上 mapper CHR banking 依旧不可观测。

所以 2.2 节当初设想的"在 PPU 侧做 `chr_addr_final = chr_bank_offset + ppu_local_addr`"**不是实现方式**。实际架构是 mapper 做**组合译码**——`nes_mapper_cnrom.v:41` 是 `(chr_bank_ext << 13) | ppu_addr[12:0]`、`nes_mapper_mmc1.v:65` 是 `(chr_bank_ext << 12) | ppu_addr[11:0]`、`nes_mapper_mmc3.v:135` 是 `(chr_window_ext << 10) | ppu_addr[9:0]`——PPU 发的是 mapper 该译码的那个本地地址。**这是 TB 驱动的 A/B，不是实机卡带、不是 NESdev test ROM、不是硬件。**

仍然开放：

- **`ppu_a12` 仍绑 0**（`nes_system_v6.v:259` 的 `wire mapper_ppu_a12 = 1'b0;`），所以 MMC3 的 A12 扫描 IRQ 在系统级**依旧不能自时钟**。这是"接进 PPU"这件事**尚未做完**的那一半——**而且这一半在 P1-11 之后仍然没有做完**。P1-11 让 MMC3 的计数器 / reload / `irq_pending_r` 状态机与 `mapper_irq → irq_line → CPU` 入口链在一条**建模的** PPU dot A12 流下跑通了真实 RTL（`irq_pending_r` 由 `nes_mapper_mmc3.v:193-194` 产生，TB 只 force 那根 A12 生产网），但**生产 RTL 一行都没改**，绑 0 仍然是事实。**根因**是本 PPU **没有 VRAM 地址总线**：只有 13 bit 的 `bg_pattern_addr`、bit 12 是 `PPUCTRL[4]`，地址进位到不了 bit 12，所以这里**不存在**一个可以接出来的真实 A12。**证据类型**必须原样转述：内部一致性与已发表时序吻合，**不是**硬件行为——`chr_mmc3` 跑 `PPUCTRL = $00` 时真实硬件每帧把计数器时钟 **0** 次，**每帧 241 是 NESdev 的文献值而不是实测**，依赖精灵的 A12 变化**没有**被建模。交叉引用：[`tb/system/README.md`](../../tb/system/README.md) 的"### P1-11"一节、`docs/00-overview/risk-register.md` 第 5 节的 L-18 与 L-19。
- **`CHR_ADDR_BITS = 17` 截断 MMC3 的 CHR bank bit 7**：17 bit 只覆盖 128 KiB，MMC3 的 8 bit CHR 寄存器写 `0xC0` 以上依然会回绕（第 9 节登记的这个已知代价仍然在）。
- **没有运行期 nametable mirroring 端口**（`nes_ppu2c02` 只有编译期参数 `MIRROR_VERTICAL`）。
- `$2007` **读**外部 CHR 已实现（11.3.9）但**渲染开着时帧中读不宣称安全**（一个取数字节可能被顶掉，限定在那条扫描线；扫描线 261 明确不安全）、写与取数及读臂与取数的**碰撞仍未修**（写 22/96、读 107/396）、片上无任何 CHR 存储、BRAM 推断没有综合证据——这四条见 11.3.2、11.3.9 与其后的"另外三条仍然开放"，本节不重复。

**边界不变**：11.1 的像素级等价性仍然是"PPU 内部 CHR 通路 vs 外部 CHR 通路"——`ppu-ext-chr-tb` 的 A/B 根本没有经过 mapper，所以它**不能**被转述为"mapper CHR banking 也被像素级证明了"。mapper 侧的证据在 `system-v6`（`tb/system/tb_nes_system_v6.v`），而且是 TB 自己写的 5 步 `$8001` 程序，**不是实机卡带、不是 NESdev test ROM、不是硬件**。`system-v6` 的整帧 A/B 本身也只是**背景**对比，精灵等价性仍然只由 `ppu-ext-chr-tb` 单独承担。

#### 11.3.7 第 8 节登记的三条行为差异的当前状态

| 差异 | 当前状态 |
|---|---|
| 8.1 `$2007` 写 CHR 后渲染晚 1 dot | **（已按事实更新）写通路已实现**（11.3.2），所以这条差异**现在有了一条真实通路可以被测量**；但本轮没有为它单独构造场景，**既没有被量化也没有被验证**。另有一条相邻的**实测**必须一起转述：外部路径上写拍与在飞背景取数**22/96** 相撞（0 次落在可见渲染期），这是**未修**的隐患（11.3.2 (b)） |
| 8.2 `sprite_overflow` 变成"下一行计数" | **没有实现**。`sprite_overflow_raw` 仍是本行组合量（`nes_ppu_sprite` 侧没改）；A/B 现在逐 `ce` 比对 raw 与 registered 两种 `sprite_overflow`、**0 分歧**，并走过 **2,048 个 overflow dot**（**6,144** 个 dot 上恰好 8 个精灵在范围内），但这条"下一行计数"的**行为差异本身仍然没有实现**，所以它在当前证据里**仍不可观测为差异** |
| 8.3 `$2007` 读 nametable 区间别名到 CHR 前 8 KiB | 行为存在（`ppu_space_read` 的 `< 14'h2000` 判据），但 TB 从不通过 `$2007` 读 nametable，**未验证**。**读臂那一轮没有改变它**：读臂只在 `v_addr < $2000` 时才抬，nametable / palette 的读仍然走 `ppu_space_read`，别名原样保留 |

第 10 节第 2 步要求的"整帧逐像素与内部模式相同"在**背景**上已达成（11.1.3）；第 3 步（精灵）的接线与**等价性都已完成**（`ad3c17a`）——11.3.1 第 1 条那条"透明精灵图案"的障碍已经不在，所以"整帧逐像素相同"在精灵打开时**已经能被证明、而且已经被断言**。剩下的是 §8.2 的 overflow **行为**差异（未实现，标志位一致已证）、9 个精灵场景之外没构造出来的优先级组合，以及仲裁无握手无背压。

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
- 11.3.1 的四条限制在 11.3.8 关闭时**一条都没有因为 11.3.8 而改变**（这一句是那时的记录）；其中 shadow 差一行、8 位 `chr_sh` 单字节、精灵像素无证据三条已在 11.3.8 之后修掉（`3e218bf`、`c6ea299`、`ad3c17a`），**现在只剩仲裁无握手、§8.2 的 overflow **行为**差异（标志位一致已证）与 9 个场景之外的优先级组合三条**。
- 风险登记册里对应条目是 **R-08**，状态为**已关闭（部分）**，面积/时序那一半改挂 R-03 / R-05。

#### 11.3.9 `$2007` 读 CHR：已实现，字节正确；**代价是总线上一个 `ce` 的地址时间与可能一个被顶掉的取数字节**

**这一节是 `$2007` 读臂那一轮新增的。** 11.3.2 与 [`docs/ppu_chr_external_write.md`](../ppu_chr_external_write.md) §8.1 都记了同一件事的合同面，这里只留 PPU 侧的形状与证据索引。

##### 形状

| 项 | 内容 |
|---|---|
| 新端口 | `input wire chr_rd_arm`（第 7 个外部 CHR 端口，`:397`） |
| 三个 master 的组合 mux | `chr_req = chr_rd_win \|\| (sp_bus_sel ? sp_chr_req : bg_chr_req)`、`chr_addr = chr_rd_win ? v_addr[13:0] : (sp_bus_sel ? sp_chr_addr_raw : bg_chr_addr_raw)`（`:807`、`:809-811`）。**读臂优先级最高**，其次精灵、最后背景 |
| CHR 半区判据 | `chr_rd_win = chr_rd_arm && (v_addr < 15'h2000)`（`:807`）——判据仍然是 **15 bit** 的 `v_addr < 15'h2000`，理由与写侧 2.1 节完全一样 |
| set/hold 寄存器 | `chr_rd_armed_q`：`reg_cs && reg_addr == 7` 时清 0，`chr_rd_win` 时置 1（`:832-839`） |
| 失效保护 | `read_buffer_reg <= chr_rd_armed_q ? chr_rdata : 8'h00;`（`:845`）。端口没接或读臂漏掉时退化成原来那条**有文档的** `8'h00`，**不是**悄悄返回一个取数字节 |
| `g_chr_internal` | **一行未改**，所以 v5 及更早的板子继续走本来就能工作的组合 `chr_ram` 通路 |
| 机械改动 | `nes_system_v0..v5` 与三个 PPU testbench 共 13 处 `.chr_rd_arm(1'b0)` 绑 0，所以没有任何实例把这个新输入悬空。`nes_ep4ce10_top` 例化的是 `nes_system_v4`，所以 **EP4CE10 构建不受影响** |

##### 时序：零余量

外部 CHR 存储器在**每一个 `ce_ppu` 沿**寄存 `chr_rdata`（`ce_ppu` 在 `div_phase` 0 / 4 / 8 触发），而 CPU 在 `div_phase == 0` 锁存 `bus_din`。所以地址必须**提前一个 `ce`** 上总线，也就是 `div_phase == 8` 那一拍。`v_addr` 只在 `$2007` 那一拍变，所以它在这个窗口里是稳的。**`nes_system_v6` 因此在唯一一个 `div_phase` 沿前值为 8 的 `clk` 上抬读臂**：`ppu_chr_rd_arm = sel_ppu && !cpu_we && (ppu_addr == 3'd7) && cpu_bus_ready && (div_phase == 4'd8);`（`nes_system_v6.v:296-297`）。`ppu_chr_rd_arm` 是模块内部的一根线网，**不新增顶层端口**（`:255` 声明、`:537` 接进 PPU）。

**必须记下来的首版缺陷（已修）**：首版要求 `ppu_req`，而 **`ppu_req` 在 `div_phase == 8` 上结构上恒为 0**——`nes_cpu6502.v:215` 让 `cpu_active = ce && !bus_hold && !reset`（`ce` 就是 `div_phase == 0`），`nes_cpu6502.v:755` 在 `!cpu_active` 时强制 `bus_req = 1'b0`，而 `nes_cpu_bus.v:238` 的 `ppu_req = cpu_req && !bus_hold && (owner_r == OWNER_PPU)` 一路依赖 `bus_req`。于是读臂**从来没有抬起过**，每个 `$2007` CHR 读都返回失效保护的 `8'h00`，**新加的 testbench 在第一个读拍上就响亮地失败**（不是空洞地通过）。修法：`ppu_req` → `sel_ppu`，`ppu_we` → `cpu_we`。**`sel_ppu` 承重**：`ppu_addr` 本身只是 `cpu_addr[2:0]`（`nes_cpu_bus.v:189`），没有它，一次 `$4007` 的 APU-IO 读会被译码成 `$2007` 并把 `v_addr` 送上 CHR 总线。同理 `!cpu_we` 而不是 `!ppu_we`：`ppu_we = ppu_req && cpu_we`（`nes_cpu_bus.v:239`），而 `ppu_req` 在那一拍恒 0，所以 `!ppu_we` 会**恒真**、什么也不限定。

##### 证据（W3 组，`system-v6`，TB 6,597 行，读臂那一轮）

| 断言 | 内容 | 实测 |
|---|---|---|
| **W3-1 ARMED-ALWAYS** | 读拍与读臂一对一，且每个读拍都看到 `chr_rd_armed_q=1`、每个读臂都在**下一个** `ce_ppu` 被消费掉 | 读拍 **396** / 读臂 **396**；`chr_rd_armed_q` 违例 **0**、悬空 **0**、背靠背两臂 **0** |
| **W3-2 ROUND-TRIP** | 期望值来自 TB 自己的 bank 模型与 PPU 自己的 `v_addr`，**从不**来自 `chr_rdata` | 读拍核对 **395** 错 **0**（本轮第一个 `$2007` 读没有前驱，被排除 **1**）；臂捕获核对 **396** 错 **0**、因写竞争跳过 **0** |
| **W3-3 CROSSES-THE-MAPPER** | 读地址真的离开 PPU、真的过 mapper 翻译，而且**不**抬 store enable、**不**与写 strobe 的捕获沿重合 | 396 个臂拍上 `chr_addr == u_ppu.v_addr[13:0]` 错 **0**、`chr_final_addr == (bank<<13)\|(v_addr[13:0]&0x1fff)` 错 **0**；`mapper_chr_ram_we` 高 **0**、`chr_we` **0** |
| **W3-4 VALUE-TRACKS-CHR-CONTENT** | 32 个回读字节逐个与**各自实例**的 CHR 内存比 | 四块板错 **0**；窗口 `$0000` 在 ab_v6 / ab_v5 / chr_rom 上读回 `ff`、在 chr_ram_b 上读回 `00` → **32** 个单元里 **24** 个不同 |
| **W3-5 UNWRITTEN-ADDRESS** | `$1040` 在可达 pattern 表内、且在上传触及的每个地址之外 | 8 个字节在 ab_v6 上全读回 `$00`（错 0）；在 ab_v6 / ab_v5 / chr_rom 上逐个可证与 `$1020` 刚写入的字节**不同**（各 **8/8**）；chr_ram_b **0/8 退化**（见下） |
| **W3-6 SENTINEL-SURVIVES** | 四个读窗口在程序 `ram[0015]` 标志处快照、结束时重读 | **0 / 32** 字节移动；`chr_mem[$2000+d]` 的 48 个字节仍持哨兵；ROM 板 128 KiB 与运行前快照**逐字节相同** |
| **W3-7 MODEL-CREDIBILITY** | 复用 P0-6 已有的按 `ce` 影子模型，不新增模型 | 请求拍 **146,797** 错 **0**；取数单元锁存 **117,164** 错 **0**；因写竞争跳过 23 / 18 |
| **W3-8 CROSS-DUT-VALUE-AB** | 同一份程序、两个**完全不同**的存储机制必须给出同一个字节 | ab_v5（PPU 内部 `chr_ram`，无外部端口、无 mapper、无总线）与 ab_v6（顶层 128 KiB 阵列经 `mapper_ppu_addr`）的 32 个 RAM 单元**逐字节相同**，不同的单元 **0** |
| **W3-9 COLLISION-IS-REAL** | 撞车必须真的发生过，否则"从不争用"的设计会静默通过 | 396 个臂里 **107** 个与在飞的取数请求撞在同一个 `ce`（背景 **71**、精灵 **36**）；落点 **378** 个在 vblank 扫描线 240–260（loop B、渲染开）、**18** 个在外面（loop A、`PPUMASK=$00`），跨扫描线 93..255 |
| **W3-9b** | P0-8 从另一侧独立核对 | 171 组连续 `chr_req` 对里 **89** 组第二拍由读臂赢（80 背景 / 9 精灵）、**82** 组在读臂之后由取数赢（82 背景 / 0 精灵）、**0** 组两拍都没有读臂 |
| **W3-10 INVISIBILITY-PROVEN** | 每个臂在**臂拍本身**对着写明的不可见集合核对，违例当场 `$fatal` | 396 个臂违例 **0**；`P0-4` 仍是 184,320 次可见像素比较 **0** 分歧 + 268,026 次全 `ce` 比较 **0** 分歧 |

**三条诚实的限制**：(1) chr_rom 的回读**不是**与 ab_v6 逐字节不同——它不可能是，因为 chr_rom 的 CHR 预载的就是程序上传的那张图；被测的是**来源**：`chr_mem[$0000]` 运行前是哨兵 `$00`、现在是 `$FF`，而 ROM 板的 `$0000` 运行前后都是 `$FF`，且那是一块 96 个写全被拒、128 KiB 改动 **0** 字节的板子；(2) chr_ram_b 在 W3-5 上退化（**0/8**），因为 run B 的 ON 常量与 TB 装载值都是 `$00`——那块板改由窗口 `$0000` 分开；(3) `chr_mmc3` **不发任何 `$2007` 读**。

**`P0-8` 是被重新界定、不是被削弱。** 它原先断言 `chr_req` 从不在两个 `ce` 上连续为高；这**不能**靠在 `mask_reg[3]` 上加条件推广（mask 门的是像素不是总线：实测 `PPUMASK=$00` 仍产生 **3,069** 组连续对、读限制在 240–260 仍产生 **369** 组）。现在它把每组连续对归属到**第二拍是哪个 master 赢**（用 PPU 自己选 `chr_addr` 的表达式），并断言**两拍都没有读臂**的连续对为 **0**——那正是旧不变式覆盖的取数对取数性质；另外断言没有两个臂相邻。`m_req_consec == 0` 逐字保留（chr_mmc3 的程序不发 `$2007` 读）。

**未改变的既有数字**：`P0-4` 184,320 / 0、`P0-5` index2=64 index6=64 index1=61,312 other=0 mismatches=0、`P0-2` 写拍 96 / 96 / 0、`P0-7` chr beats total=146556、四条 `P1-11 A12-*`。**合法变化**的只有请求类总数（读臂现在也是请求拍）：P0-1 chr requests 62,678 → **62,801**、P0-2 read 62,656 → **62,779**、P0-3 last frame 20,960 → **21,002**。

**新义务**：(a) 存储器必须在**每一个 `chr_req` 为高的 `ce`** 上捕获地址；(b) 多出来的仲裁级落在 **`chr_addr`** 上，而它是通往 CHR 地址的**唯一**通路，地址建立时间必须按真实 BRAM/SDRAM 的 `tACC` 预算重新核对；(c) **同址同拍读写竞争第一次对程序可见**，TB 建模成 read-first——**这是建模选择，不是被证明的硬件行为**。

**登记**：撞车本身是风险登记册的 **L-20**（L-17 的兄弟条目）；`write_toggle` / `read_buffer_reg` 的既有行为**未动**（见 11.3.2 末与 [`docs/ppu_chr_external_write.md`](../ppu_chr_external_write.md) §9）。

**一个程序布局变化必须一起记**：`NMI_HANDLER` 从 `$8A10` 移到 `$8B80`，因为 loop B 约 250 字节、handler 必须保持连续。这会改变 `P1-6` 与 `PRG …` 打印出来的地址，两者**仍然自洽**。


### 11.4 证据边界（一句话版）

- **可以说**：背景外部 CHR 通路在 5 组配置 × 3 帧下与内部 CHR 路径**逐 `ce` 逐 dot 像素完全一致**（921,600 次 `pixel_index` + `bg_pa_enable` 比对），337,450 次 `chr_req` 的地址被独立重算核对，126,546 对平面字节与 CHR 模型逐字节一致。
- **可以说（本轮新增，仅限接线与总线）**：精灵预取单元已由 `g_chr_external` 例化并在 dot 257 发 `start`；**每行恰好 16 次**精灵 `chr_req`；仲裁是**无握手的组合优先 mux**（精灵优先）**且两个窗口不重叠**（背景 ..253 / 精灵 257..291 / 背景 324..，见 `nes_ppu2c02.v:579` 的 `bg_fetch_pre_first = (dot == 9'd324)`）；**mux 不篡改当前持有者的地址**（背景与精灵两侧都断言过）。
- **可以说（后续轮次新增）**：精灵通路的两个架构阻塞点已解除——`chr_sh` 已加宽到 **16 bit** 并**真正交付低/高两个平面**（不再是按位或、不再把每一个不透明像素强制成 palette `3`），`pat_addr_o` 已改用**下一行** scanline，所以 dot 292 落地的 shadow 正是下一行要用的那一份（**不再差一行**）。这两条改动的理由与边界见 11.3.1 第 2、3 条。
- **可以说（后续轮次新增）**：精灵通路的**像素等价性已有 A/B 证据**。`tb/ppu/tb_nes_ppu2c02_ext_chr.v` 在 `EXTERNAL_CHR=0` 与 `EXTERNAL_CHR=1` 两个实例之间比 **7** 个精灵可观测量（`mixed_pixel` / `sprite_pixel` / `sprite_priority` / `raw_sprite0_hit` / `raw_sprite_overflow` / `registered_sprite0_hit` / `registered_sprite_overflow`），**552,960** 个比较点**全部 0 分歧**；精灵自检显示 **1,708** 个精灵决定像素真的被渲染（透明背景上 **908**、不透明背景前 **564**、不透明背景后 **236**，三类优先级都走到），**6,144** 个 dot 上恰好 8 个精灵在范围内、**2,048** 个 overflow dot，B 从 A 的**上一条扫描线**复现 mixed-pixel 的检查是 **0 of 0**。前提是"换非透明图案 + 精灵可见性自检"，由 `ad3c17a` 补上（`3e218bf` 只解除了 `chr_sh` 单字节与 next-line 两个**架构**阻塞点，**没有**提供这条证据）。**边界**：这是 TB 驱动那几组场景下的 A/B，**不是实机卡带、不是 NESdev test ROM、不是硬件**；逐条数字与限制见 11.3.1 第 1 条。
- **可以说（逐项，已按实测更正）**：精灵 A/B 的 **9 个精灵场景**各自隔离一项、各有自己的非空洞 `$fatal`（`case_sp_*` 计数器逐组清零，每组 `mismatched_pixels=0`），所以 **8×16 高度**（`sp1-8x16-oddtile` 40、`sp8-8x16-mixprio` 560 个精灵决定像素）、**每行 8 个 sprite 上限**（`sp8-8x8-limit` 2,048、`sp8-8x16-mixprio` 4,096 个"恰好 8 个在范围内"的 dot）、**overflow 标志位**（`sp10-overflow` 2,048 个 overflow dot 上 A/B 一致）、**水平翻转**（`sp1-hflip` 48）、**垂直翻转**（`sp1-vflip` 56）、**双翻转**（`sp1-hvflip` 56）**各自独立成立**，不是"整体覆盖里顺带走到"。
- **可以说（`$2007` 写通路那一轮新增，`5cc36e7` / `576cc74`）**：外部 CHR 的 `$2007` **写**通路已实现并有端到端证据。写周期产生**恰好 1 `clk` 宽**的 `chr_we`，地址是**自增前**的 `v_addr`、数据是 `reg_din`；`system-v6`（**5,189** 行）实测 **96** 个写拍、**0** 翻译错，且**总线侧独立统计**的 `$2007` 写数同样 96（每写恰好一个 strobe）。非空洞由**哨兵**（预载程序所写的逐位取反，跨每一个 4 KiB 块）保证、字节级核对 96/96、**自验证对**（同一份代码、互补图像，最后一帧 245,760 个 clk 采样上画面**全部不同**、其中 15,360 个在最左 16 列）、**CHR-RAM/CHR-ROM 忽略对**（同程序同地址同字节，ROM 板 131,072 字节改 0 个、两板画面相同）以及 **MMC3 bank 限定写**（三写落 `$00040` / `$10840` / `$10c40`）交叉锁定。逐条见 11.3.2 与 [`docs/ppu_chr_external_write.md`](../ppu_chr_external_write.md)。**边界**：全部来自 Icarus 下的 RTL/TB 内部一致性，是 **TB 驱动场景**，**不是实机卡带、不是 NESdev test ROM、不是硬件**；`ppu-ext-chr-tb` 的 A/B 数字**逐字节未变**，即写通路的加入没有造成任何渲染漂移。
- **可以说（`$2007` 读通路那一轮新增）**：外部 CHR 的 `$2007` **读**通路已实现。`nes_ppu2c02` 新增 `input wire chr_rd_arm`，`g_chr_external` 里 CHR 读是 `chr_req` / `chr_addr` 的**第三个 master**（`chr_rd_win`），配一个 set/hold 寄存器 `chr_rd_armed_q` 与一层**失效保护** `read_buffer_reg <= chr_rd_armed_q ? chr_rdata : 8'h00;`。**返回的字节在 mapper 翻译后的地址上永远正确**，并且它**经过 mapper**（`chr_final_addr` 逐臂核对，错 0）、**不抬** `mapper_chr_ram_we`（0 个臂拍）、**不与** `chr_we` 的捕获沿重合（0 个臂拍）。W3 组十项检查与全部数字见 11.3.9。
- **不能说**：**渲染开着时帧中 `$2007` CHR 读是安全的**——把地址放上总线要花掉一个 `ce` 的地址时间，并**可能顶掉一个**在飞的取数字节（一个背景 tile = 8 像素里 1 个 pattern 字节，或一个精灵 slot 平面 = 某一行上的 8 像素），**范围限定在被读的那条扫描线**。在扫描线 240–260 或关渲染时可以证明**像素不可见**；**扫描线 261 明确不安全**。**不能说**读写竞争的行为是已证明的（TB 建模成 read-first，那是一个**建模选择**）；**不能说**地址建立时间仍然够（多出来的仲裁级落在 `chr_addr` 上，真实 BRAM/SDRAM 的 `tACC` 预算没有被核对过）；**不能说**片上有 CHR 存储或 BRAM 推断成立。
- **不能说**：外部模式的精灵通路**整体**可用（**像素等价性、8×16 高度、每行 8 个 sprite 上限、overflow 标志位、水平/垂直/双翻转都已逐项 A/B 证明，但 §8.2"用下一行 OAM 计数"的 overflow **行为**差异未实现、所以仍不可观测，9 个场景之外没构造出来的优先级组合不宣称穷尽**，而且仲裁**无握手无背压**）；**写与取数的碰撞已修**（实测 96 个写拍里 **22** 个与在飞背景取数相撞，0 次落在可见渲染期，但**未修**——渲染期写 CHR 会让一个 tile 拍取错）；**读臂与取数的碰撞已修**（396 个臂里 **107** 个撞上，**未修**）；渲染期间改 scroll 可用；mapper CHR banking 端到端（含 A12 扫描 IRQ）可用（**地址/译码通路本身已接通**、`nes_system_v6` 上有端到端证据，不再否认；仍未证明的是 `ppu_a12` 未被真实时钟 → MMC3 扫描 IRQ 不能自时钟、A12 驱动的计数器行为无证据）；`ppu_a12` 已被真实时钟；复位后第 0 帧正确；`chr_req` 在任意 `ce` 分频下都是 1 拍脉冲。
- **不能说**：精灵 slot 选择的**面积与 fmax 可接受**。11.3.8 的关闭**只覆盖"重复逻辑 + 回归时长"**：`nes_ppu2c02` 不再重复实现 `nes_ppu_sprite` 已有的扫描，但**面积与时序仍然没有任何综合证据**，`nes_ppu_sprite` 内部那份 64 项 OAM 范围扫描与 nth-set 优先编码**仍然每 dot 组合重算**。
- **不能说**：任何综合 / STA / fmax / 上板结论。上述全部证据来自 Icarus Verilog 下的 RTL/TB 内部一致性。

### 11.5 下一步（按当前状态）

1. ~~**把 A/B TB 的精灵图案从"全 0 透明"换成非透明图案，并加精灵可见性自检**（先断言 A 侧确实有非背景精灵像素，否则"换图案"可能仍然换出一张全透明的帧），然后重跑同一套 921,600 次比对~~ —— **已完成**（`ad3c17a`）：A/B 在 **552,960** 个比较点上比 7 个精灵可观测量、**全部 0 分歧**，**1,708** 个精灵决定像素跨三类优先级。**已补**精灵专项覆盖：A/B 现在跑 **9 个精灵场景**（`sp1-8x8-x0` / `sp1-8x8-x255` / `sp8-8x8-limit` / `sp10-overflow` / `sp1-hflip` / `sp1-vflip` / `sp1-hvflip` / `sp1-8x16-oddtile` / `sp8-8x16-mixprio`），8×16、每行 8 个上限、overflow 标志位、水平/垂直/双翻转**逐项**已证明。**仍未做**：§8.2 的 overflow **行为**差异与这 9 个场景之外的**优先级组合**。
2. ~~**修 shadow 差一行**（11.3.1 第 2 条）~~ —— **已完成**：`pat_addr_o` 改用下一行 scanline（模块内部的 next-line 链），见 11.3.1 第 2 条。
3. ~~**加宽 `nes_ppu_sprite.v` 的 `chr_sh` 以交付双平面**（11.3.1 第 3 条）~~ —— **已完成**：`chr_sh` 已是 16 bit，见 11.3.1 第 3 条。精灵专项覆盖**已做**（9 个精灵场景，8×16 / 每行 8 个上限 / overflow 标志位 / 翻转逐项 A/B 证明）；**仍未做**的只有 §8.2 的 overflow **行为**差异与 9 个场景之外的优先级组合。
4. ~~**处理精灵 slot 选择的组合开销**（11.3.8 / R-08）~~ —— **已完成**。`nes_ppu_sprite` 导出纯观测输出 `cur_slot_o[3:0]`，`nes_ppu2c02` 改为消费它而不是重算一遍（`sp_nth_set`、64 项扫描 `always` 块、11 个只服务该扫描的 reg 全部删除，`nes_ppu2c02.v` 806 → 752 行）；27 万余 tick 逐 dot 等价、A/B 四行逐字节不变，`ppu-ext-chr-tb` 821.6 s → **162.5 s**、占全量 45.26% → **16.83%**。**但面积与 fmax 仍未测量**，那部分归 R-03 / R-05，见 11.3.8。
5. ~~**`$2007` 对外部 CHR 的写通路**（`chr_we` / `chr_waddr` / `chr_wdata`）~~ —— **已完成**（`5cc36e7` / `576cc74`），逐条见 11.3.2。**仍未做**的是这条通路上剩余的事：**(a)** 写与取数、以及**读臂与取数**在共享 CHR 地址总线上的**碰撞抑制**（写实测 22/96、读实测 107/396 相撞，两条都未修）；**(b)** 片上 CHR 存储与 BRAM 推断证明（要等外部存储方案），以及**新增的地址建立义务**（仲裁级落在 `chr_addr` 上，`tACC` 预算要重新核对）；**(c)** 8.3 的读 nametable 别名要不要接受（**既没实现也没验证**）。§8.1 那条"写后渲染晚 1 dot"现在**可以被测量**了，但写与读两轮都**没有**为它构造场景。**（`$2007` 读 CHR 本身已在读臂那一轮完成，见 11.3.9。）**
6. ~~**mapper 侧 `chr_bank_offset` 组合叠加**（2.2）+ `nes_system_v5` 的 `ppu_addr` 接线~~ —— **（已按事实更新）"组合叠加加法器"这一版已被否决，实际实现的是 mapper `ppu_addr` 输入端上**一个写优先的 mux**（`ppu_chr_we ? ppu_chr_waddr : ppu_chr_addr`），由 mapper 组合译码产出 `chr_bank_offset`、再经 `chr_final_addr = mapper_chr_bank_offset` 导出。**否决"PPU 侧后加"的决定性理由是零延迟组合环**：`chr_bank_offset` 本身是 `ppu_addr` 的组合函数，在 PPU 侧再相加即成 `chr_addr → mapper.ppu_addr → chr_bank_offset → chr_addr`（2.2 / 11.3.6）。**这条里真正还开放的只剩下面这些**：`ppu_a12` 仍绑 0（MMC3 扫描 IRQ 不能自时钟、A12 驱动的计数器行为无证据）、写与取数、以及**读臂与取数**在共享 CHR 地址总线上的**碰撞未修**（写实测 22/96、读实测 107/396）、片上无任何 CHR 存储且 BRAM 推断无综合证据（外加**读臂带来的新地址建立义务**）、`CHR_ADDR_BITS=17` 截断 MMC3 CHR bank bit 7、没有运行期 nametable mirroring 端口。**（`$2007` 读外部 CHR 已不再是开放项——它在读臂那一轮实现，见 11.3.9。）** `tb_nes_system_v5.v:1499-1507` 那条"`ppu_a12` 绑 0"的断言在 `nes_system_v6` 上的对应绑 0 是 `nes_system_v6.v:302`（读臂那一轮之前是 `:259`），**同样仍然开放**。`write_toggle` / `read_buffer_reg` 是既有实现，本条**有意未触碰**。
7. **渲染期间 `$2005` 写的相位处理**（11.3.3）与**复位后第 0 帧的 warm-up**（11.3.4）。

早期版本这一节里的"为什么停在这里"和"两条可选路线（(a) 先用行为模型证明等价性 / (b) 内部 tile 缓存）"已经**部分过期**：路线 (a) 的等价性证明已在 11.1.3 完成（实现顺序是先写 RTL 再写 A/B TB），路线 (b) 的内部 tile 缓存**没有被采用**。**但第 8 节那三条行为差异的人工决策仍然没有记录**——8.1 与 8.3 是否接受、8.2 是否需要重做，都还需要人拍板。

