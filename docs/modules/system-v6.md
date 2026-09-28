# 系统集成 v6：把 PPU 的外部 CHR 读通路接到 mapper 的 bank 偏移输出上

本文是 `rtl/nes_core/system/nes_system_v6.v` 的接口与接线合同。它最初是 `nes_system_v5.v` 的**字节级副本加一个小 delta**：PPU 用 `.EXTERNAL_CHR(1'b1)` 例化，v5 里那根绑常数的 `mapper_ppu_addr` 改由 PPU 的本地 CHR 地址驱动，顶层多出三个 CHR 端口。后来 `$2007` 外部 CHR **写**通路也补进了同一个模块（`5cc36e7`、`576cc74`），顶层 CHR 端口增加到六个，表头那句"小 delta"只对**读**通路成立。核心问题只有四个：

1. mapper 的 `chr_bank_offset` 是"CHR 空间里的**绝对字节偏移**"，而 PPU 发出来的是"**单个 8 KiB 窗口里**的本地地址"。这两个数怎么组合，才既不给 mapper 加第二个加法器、又不制造组合环？读地址与写地址共用这一条总线时，仲裁规则是什么？
2. 本地地址的 pattern-table 选择位到底是 `chr_addr[13]` 还是 `chr_addr[12]`？这个问题的答案决定了"把 `ppu_addr[13]` 丢进 mapper"到底丢的是 bank 位还是 PPU 内部译码位。
3. 外部 CHR 存储器要满足什么时序合同？`chr_req` 上没有应答信号，存储器能不能"这一拍不给"？
4. v6 做到了哪一步、哪一步明确留给下一阶段？`$2007` 写外部 CHR 这一步做完了没有，边界在哪里？

`docs/modules/system-v5.md` 写清 v5 顶层的 mapper 接线、软件 mapper 的 dispatch 与指针数组到 bank 寄存器的对应关系、`prg_readback` 驱动的 bus conflict 与 mapper IRQ 线或；`docs/modules/ppu-external-chr.md` 写清 PPU 侧 `g_chr_external` 分支的取数流水、dot 预算与等价性陷阱。本文不重复那两份，只写 v6 **新加的那一根线**、**地址合同**，以及**为什么是这样**。

行为权威是 NESdev 的 mapper/NROM/MMC1/MMC3 说明与 pattern table 说明。`[源码观察]` 标记的内容只是克隆仓库的写法，不是规格。

---

## 1. v6 相对 v5 的增量

| 项 | v5 | v6 |
| --- | --- | --- |
| PPU 例化 | `nes_ppu2c02 #(.MIRROR_VERTICAL(1'b0))`，默认 `EXTERNAL_CHR = 1'b0` | 同一份例化，加 `.EXTERNAL_CHR(1'b1)` |
| `mapper_ppu_addr` | `wire [13:0] mapper_ppu_addr = 14'h0000;`（常量） | `wire [13:0] mapper_ppu_addr = ppu_chr_we ? ppu_chr_waddr : ppu_chr_addr;`（读地址与写地址的组合仲裁，**写优先**） |
| `mapper_ppu_we` / `mapper_ppu_dout` | `1'b0` / `8'h00` | 接 PPU 的 `chr_we` / `chr_wdata`。外部分支不再绑 0：`chr_we` 是 `$2007` 写的组合单 `clk` 选通，`chr_wdata` 是 `reg_din` |
| `mapper_ppu_a12` | `1'b0` | `1'b0`（**不变**，见第 6 节） |
| 顶层 CHR 端口 | 无 | 新增 `chr_rdata[7:0]`（in）、`chr_req`（out）、`chr_final_addr[CHR_ADDR_BITS-1:0]`（out，默认 17 bit）；写通路再加 `chr_waddr[13:0]`（out）、`chr_we`（out）、`chr_wdata[7:0]`（out） |
| CHR | PPU 内部 8 KiB CHR RAM | **PPU 不再取自己的 CHR**，全部取数走外部 CHR 端口；`$2007` 写外部 CHR 也走这条端口 |
| `chr_final_addr` | 无 | `assign chr_final_addr = mapper_chr_bank_offset;` |
| controller / DMA / APU / mapper IRQ / 可等待 bus / mirroring | 全部在 | 一字未改，与 v5 逐行相同 |

**这张表是累计 delta**：v6 当初只接了读侧三个端口，`mapper_ppu_we` / `mapper_ppu_dout` 确实接的是常量（见 1.1）。`$2007` 外部 CHR 写通路补进 `nes_system_v6.v` 与 `nes_ppu2c02.v` 之后，上面四行才是今天的样子。**`nes_mapper.v` 自始至终一个字节都没改**——写通路复用的是它本来就有的 `ppu_we` / `ppu_dout` 观察通道（`nes_mapper.v:221`）。

**一句话**：v6 不改 CPU、不改 bus，只把 PPU 的 CHR 端口接到 mapper 观察窗口的那几根线上，并把 mapper 的 CHR 偏移导出成顶层端口；mapper 一行未动。

### 1.1 `mapper_ppu_we` / `mapper_ppu_dout`：先接常量，后接真实的 `$2007` 写脉冲

**历史记录**：v5 把这两根线绑 0 是因为"没有 CHR 写通路"。v6 初版接上它们，看起来像是"写通路也接好了"——**这正是它当时容易被误读的地方**。接上去的语义只有一条：mapper 的 CHR 观察通道**在语义上完整**了，将来 PPU 一旦实现 `$2007` 写外部 CHR，mapper 的 `chr_ram_we` / `chr_ram_enable` 侧就已经有正确的位，不需要再回头改顶层。

**现状**：`$2007` 外部 CHR 写通路已经实现（`5cc36e7`、`576cc74`），这两根线不再是常量。`nes_ppu2c02` 的 `g_chr_external` 分支现在直接给出 `chr_we` / `chr_wdata`，顶层原样导出。**那条"接 0 就是一次可删的连接"的预测成立了，而且没有回头改顶层一行。**

写侧组合逻辑全貌、以及为什么地址必须取**递增前**的 `v_addr`、为什么 `chr_we` 只能是组合单 `clk` 选通而不登记：`docs/ppu_chr_external_write.md` 第 2、3 节。这里只留接线合同：

```verilog
wire [13:0] ppu_chr_waddr;   // PPU 递增前的 v_addr[13:0]
wire        ppu_chr_we;      // $2007 写的组合单 clk 选通
wire [7:0]  ppu_chr_wdata;   // reg_din
```

`chr_waddr` 是 `v_addr` 的**第 14 位与第 13 位都为 0 时的低 14 位**（条件写就是 `v_addr < 15'h2000`，`nes_ppu2c02.v:712`），所以写地址的 bit 13 结构上恒 0，位 12 仍然是 pattern-table 选择位。

## 2. 接线：读三根线、写三根线、两个输出端口

### 2.1 PPU 侧

```verilog
wire        ppu_chr_req;
wire [13:0] ppu_chr_addr;
wire [13:0] ppu_chr_waddr;
wire        ppu_chr_we;
wire [7:0]  ppu_chr_wdata;

nes_ppu2c02 #(
    .MIRROR_VERTICAL(1'b0),     // 与 v0..v5 相同，见 docs/modules/system-v5.md 第 2.4 节
    .EXTERNAL_CHR(1'b1)         // 唯一的 delta
) u_ppu (
    ...,
    .chr_req  (ppu_chr_req),
    .chr_addr (ppu_chr_addr),
    .chr_waddr(ppu_chr_waddr),
    .chr_we   (ppu_chr_we),
    .chr_wdata(ppu_chr_wdata),
    .chr_rdata(chr_rdata)       // 顶层输入，直接进 PPU
);
```

`chr_req` 与 `chr_final_addr` 直接就是顶层输出端口。**`chr_waddr` / `chr_we` / `chr_wdata` 也导出为顶层输出端口**（`nes_system_v6.v:160-162`）——它们不再是常量，导出它们是有真实信号的；当初"故意不导出"的判断只对恒 0 的那一版成立。写端口的合同：

| 端口 | 宽度 | 语义 |
| --- | --- | --- |
| `chr_waddr` | 14 | **递增前**的 `v_addr[13:0]`；`v_addr >= $2000` 时驱动 `14'h0000`，此时 `chr_we` 为 0，所以那是一个 dummy 值 |
| `chr_we` | 1 | 组合单 `clk` 选通：`!reset && reg_cs && reg_we && (reg_addr == 3'd7) && (v_addr < 15'h2000)` |
| `chr_wdata` | 8 | `reg_din`，即 CPU 写进 `$2007` 的那个字节 |

外部 CHR 存储器**必须自己观察这三个信号**：`nes_system_v6` 只导出选通，不含任何存储阵列。`chr_we` 不登记，所以下游必须按单拍脉冲来用。

### 2.2 mapper 侧

```verilog
wire [13:0] mapper_ppu_addr = ppu_chr_we ? ppu_chr_waddr : ppu_chr_addr;  // 写优先仲裁
wire        mapper_ppu_we   = ppu_chr_we;
wire [7:0]  mapper_ppu_dout = ppu_chr_wdata;
wire        mapper_ppu_a12  = 1'b0;              // 仍然绑 0

assign chr_final_addr = mapper_chr_bank_offset;
```

读地址与写地址共用这一根 14 bit 总线，仲裁是**一行组合 mux、写在 v6 里、写在 mapper 之外**：写优先。选择器必须在**地址与 `ppu_we` 之间保持一致**，否则 mapper 会拿写数据去写一个读地址（或者反过来），而 PPU 的读通路不会因此报错——这类错误在 A/B 像素比较里表现为"偶尔一个 tile 错"，很难查。TB 把这条 mux 的每一拍都单独断言（见 5.1 的 P0-2 WRITE-TRANSLATION）。

`nes_mapper` 的 CHR 侧本来就是纯组合的（`docs/modules/mappers.md` 第 2.2 节）：五个子模块各有一条 `chr_bank_offset` 组合式，`nrom` 是恒 0 的常量，其余按各自的 bank 寄存器与 `ppu_addr` 的低位拼出来。所以 v6 **不需要给 mapper 加任何一个新的端口**——`ppu_addr` / `ppu_we` / `ppu_dout` 这条观察通道本来就在，v5 只是喂了 0。**`nes_mapper.v` 没有为写通路改过一行**：`chr_ram_we = chr_ram_enable_r && ppu_we && (ppu_addr[13] == 1'b0)`（`nes_mapper.v:221`）早就是对的，只是 `ppu_we` 从来没为 1 过。顶层导出的 `mapper_chr_ram_we` 因此是**过了 mapper 门控之后**的权威选通，也就是 CHR-ROM 板应该恒为低的那一根。

### 2.3 没有组合环

这是本设计里最容易踩的一类坑，值得单独说。组合环有两条可能的路径：

```text
路径 A（会成环）：chr_addr_out ──▶ mapper ──▶ chr_bank_offset ──▶ chr_addr_in
路径 B（安全）：  chr_addr_out ──▶ mapper ──▶ chr_bank_offset ──▶ 顶层输出端口（无人读回）
```

- `chr_rdata` 是本模块的**输入**端口，它进 PPU 之后只到寄存器，**不参与地址计算**；`chr_final_addr` 是**输出**端口，仓库里没有任何模块读它。两条都没有把 mapper 的输出接回 PPU 的输入，所以**不存在组合环**。
- 换句话说，mapper 的输出是**最终地址**，PPU 在它之后**不再加任何东西**。这是一条**前馈（feed-forward）通路**，不是"后置加法器"。

这个区别有实际后果：假如将来有人把 `chr_final_addr` 改成 `assign chr_final_addr = ppu_chr_addr + mapper_chr_bank_offset;`（一个看起来很自然、其实完全错误的写法），地址会被**折两遍**，而且组合环立刻出现。TB 的 P0-2 断言（见第 5 节）用 TB 侧独立模型逐拍比对 `chr_final_addr`，就是为了把这条语义钉死。

## 3. CHR 地址合同：本窗口 13 bit、选择位是 bit 12、最终 17 bit

这是 v6 最需要写清的一段，因为它的正确性完全依赖三个数字之间的位宽关系。

### 3.1 本地地址是 8 KiB、13 bit

pattern 的字节地址在 PPU 内部是

```text
{table, tile[7:0], plane, fine_y[2:0]}   =  $0000 .. $1FFF      （13 bit）
```

- **背景**：`bg_tile_base` 是 13 bit（`nes_ppu2c02.v` 的 `bg_tile_base` 定义与它在 `bg_look_dot` 处的用法），所以 `PPUCTRL[4]`（背景 pattern table 选择）落在**位 12**。
- **精灵**：`s_pat_addr = {s_table, s_tile, 1'b0, s_fine[2:0]}` 是 13 bit，所以 `PPUCTRL[5]` 也落在**位 12**。
- 两个取数单元都把这个数放在**低 13 位**：背景是 `nes_chr_fetch_unit` 的 13 bit `tile_base`，精灵是 `nes_sprite_chr_fetch` 的 `pat_addr[g*13 +: 13]`。两者的 tile 编号也一致，**都在 `chr_addr[11:4]`**（8×8 时是 256 个 tile 的完整空间，8×16 时是 128 对 tile）。

**纠正一条旧说法**：早先的文档与注释写过"背景与精灵之间存在一个不可消除的不对称，不要试图统一它们"。那是过时的，现在两边编号方式相同。精灵侧不再需要特殊的窗口尺寸处理。

### 3.2 `chr_addr[13]` 是声明了但恒 0 的一位

`chr_addr` 是 14 bit 的端口（`nes_ppu2c02` 的 `chr_addr[13:0]`），但地址本身只有 13 bit。**位 13 没有任何地址可以承载它**：

- 背景侧 `nes_chr_fetch_unit` 在 PPU 里被接成 `.tile_count(6'd1)`，它的 `tile_base` 是 13 bit 的 `{table, tile, 4'b0000} + fine_y`，最大 `0x1FF7`，再加 8 得到 `nxt_addr <= 0x1FFF`；
- 精灵侧 `nes_sprite_chr_fetch` 的 `plane_byte` 在一个 bit3 恒 0 的 13 bit `pat_addr` 上最多加 8，同样顶到 `0x1FFF`。

TB 在最后一帧的 20,960 次请求上量到**本地 `chr_addr[13]` 为 1 的次数是 0**，而**本地 `chr_addr[12]` 为 1 的次数是 16,768**。所以"pattern-table 选择落在 bit 12"这件事是被测出来的，不是推出来的。

因此：**每个 mapper 丢掉 `ppu_addr[13]` 是完全无害的**，而它们各自把**位 12** 当成自己的窗口选择输入（`nrom`/`uxrom`/`cnrom` 用 `ppu_addr[12:0]`，`mmc1` 用 `ppu_addr[11:0]`，`mmc3` 用 `ppu_addr[9:0]`）。这正是硬件应有的分工：pattern table 选择是 PPU 对**同一块 8 KiB** 的内部译码，卡带不需要看见它。

**写侧同理，结论也是"无害"**：`chr_waddr` 另一个 14 bit 端口，它的 bit 13 由条件本身结构性地为 0（`chr_waddr` 只在 `v_addr < 15'h2000` 时有意义，此时 `v_addr[14:13] == 0`）。所以 `chr_ram_we` 里那个 `ppu_addr[13] == 1'b0` 的门（`nes_mapper.v:221`）在写拍上**从不生效**，它仍然是读侧那条不变式的延续。TB 在写拍上也逐拍检查 `chr_waddr[13] == 0`（P0-3 WRITE-STREAM），把它从"推导出来的"变成"测出来的"。

**读地址与写地址不要混**：本节讲的是 `chr_addr`（读，`chr_req` 有效时才有意义）。`chr_waddr` 是另一根线，语义见 2.1。

### 3.3 8 KiB CHR 用 `[12:0]` 索引，截断是无损的

外部 CHR 存储器的窗口是 8 KiB，所以它用 `chr_final_addr[12:0]`（或等价地本地地址的低 13 位）做索引。因为地址**永远不超过 `0x1FFF`**，这次截断**不产生镜像、不产生回绕**——它和"16 KiB 窗口里丢掉一位"是完全不同的事情。这也是"P0-3 断言 `chr_final_addr[13] == 0`"没有实际约束力的原因，TB 把这一点如实写进了它自己的输出（P0-3 NONVACUITY-PROBE），而不是假装这条断言有区分力。

**教学点**：位宽修一次、语义就变一次。把"16 KiB CHR + 位 13 是选择位"这套描述原封不动搬到 8 KiB 的真实实现上，会得出"mapper 丢掉了 pattern table 选择"这种**正好相反**的结论。

### 3.4 最终地址 17 bit，以及它截断了什么

`CHR_ADDR_BITS` 默认 17（128 KiB），原样转发给 `nes_mapper`。这个宽度**正好覆盖 MMC1**（MMC1 的 CHR 窗口最大 32 KiB，加上 8 KiB 的本地窗口），但**截断了 MMC3 CHR bank 的 bit 7**：MMC3 的 1 KiB CHR 窗口选择寄存器是 8 bit，bit 7 落在 `chr_final_addr[16]` 之外。

后果是明确的、可预测的：MMC3 的 bank `0x80`–`0xFF` 会**别名**到 `0x00`–`0x7F` 的地址上。**这是已知的、已接受的限制，不要为了它把 `CHR_ADDR_BITS` 调大**——调大只会在没有任何 CHR 存储接上的今天多出一堆常量，而真正的容量问题要等外部存储方案定下来（见第 6 节）。

### 3.5 时序合同：1 拍寄存读，没有背压

外部 CHR 端口的合同是：

1. **地址提前一个 `ce`**：两个取数单元都在发 `chr_req` 的**前一拍**就把 `chr_addr` 装好（`nes_chr_fetch_unit` 的 `S_PRE`、`nes_sprite_chr_fetch` 的 `S_PRE`），所以 `chr_req` 拉高那一拍地址已经正确。
2. **`chr_rdata` 必须在下一个 `ce` 有效沿给出上一拍地址的字节**，也就是"**寄存器输出**"而不是"组合读"。TB 的 CHR 模型就是这么写的（`chr_rdata_q <= chr_mem[chr_final_addr]` 在 `ce_ppu` 上寄存），所以这条合同是**被断言出来的**而不是假定的。
3. **背靠背 2 个 `ce` 一字节**：`S_BEAT` 发请求、`S_GRAB` 取数，下一个字节的地址在同一拍用 `fwd_addr` 预置。
4. **`chr_req` 上没有 ready / ack / valid 握手。** 它是一个"请在下一个 `ce` 给我数据"的无条件请求。**存储器不能"这一拍不给"**，也没有任何机制让它合法地拖延。

第 4 条是这套接口最重要的边界，也是它为什么不能直接接到 SDRAM：真实 SDRAM 的 CAS / 突发 / 刷新延迟是若干个 `ce`，而这个端口每 2 个 `ce` 就要求一个字节。TB 里的 CHR 模型是**零时序代价**的，所以 `system-v6` 证明的是**地址与协议合同**，不是"任何真实存储器能满足这个截止期"。

## 4. 顶层端口清单

| 端口 | 方向 | 位宽 | 合同 |
| --- | --- | --- | --- |
| `chr_rdata` | in | 8 | 上一 `ce` 的 `chr_final_addr` 对应的 CHR 字节。**复位期间与整个复位窗口内 TB 绑 0** |
| `chr_req` | out | 1 | PPU 请求一个外部 CHR 字节。**无背压、无应答**。`ab_v6` 上实测在 625,396 个 `ce` 中**从未**在连续两个 `ce` 上同时为高 |
| `chr_final_addr` | out | `CHR_ADDR_BITS`（默认 17） | **映射后的最终 CHR 字节地址**，等于 `mapper_chr_bank_offset`。**没有任何模块读它**，它只用于观测与 TB 建模 |
| `chr_waddr` | out | 14 | `$2007` 写外部 CHR 的**本地**地址 = 递增前的 `v_addr[13:0]`；`v_addr >= $2000` 时为 `14'h0000`。只在 `chr_we` 为高时有意义 |
| `chr_we` | out | 1 | `$2007` 写外部 CHR 的**组合单 `clk` 选通**。复位期间为 0。**不登记**：下游必须按脉冲用 |
| `chr_wdata` | out | 8 | 写进 `$2007` 的那个字节（`reg_din`），与 `chr_waddr` / `chr_we` 同拍有效 |

`chr_waddr` / `chr_we` / `chr_wdata` **不再**是"故意不导出"的常量。`mapper_chr_ram_we` 是 mapper 侧那根：它是**过了 `chr_ram_enable` 与 bit 13 门控之后**的选通，CHR-ROM 板上应当恒为低，TB 在 CHR-RAM/CHR-ROM 对照板上量到的正是这一根。

其余端口与 v5 逐条相同（`clk`、`reset`、`pixel_*`、`frame_done`、`vblank`、`nmi_o`、`apu_irq_o`、`audio_sample_*`、`cpu_cycle`、`ppu_dot`、`ppu_scanline`、`prg_readback`、`mapper_*`、`irq_line` 等）。`mapper_ppu_a12` 仍绑 0。

## 5. `tb/system/tb_nes_system_v6.v` 怎么测

5,189 行，同一个 `clk` 上**五个** DUT 实例。本机实测运行时间 **208.4 s**（回归目标 `system-v6`，`-g2012` 编译 + `vvp`）。实例从三个增加到五个，全部是为了 `$2007` 写外部 CHR 服务的。

| 实例 | 顶层 | `MAPPER_SELECT` | CHR | 程序 | 角色 |
| --- | --- | --- | --- | --- | --- |
| `ab_v6` | `nes_system_v6` | 0（NROM） | 顶层 CHR 端口 + **自己 128 KiB 的 CHR 模型**（寄存读），`NROM_CHR_RAM=1` | 主程序 | **被测对象**：读侧 A/B + `$2007` 写侧主证据 |
| `ab_v5` | `nes_system_v5` | 0（NROM） | PPU 内部 8 KiB CHR，**层次预载** | 同一份主程序镜像 | **A/B 参照**：像素与寄存器状态的比较对象 |
| `chr_mmc3` | `nes_system_v6` | 4（MMC3） | 自己 128 KiB 的 CHR 模型（寄存读），`MMC3_CHR_RAM=1` | **另一份**程序镜像 | MMC3 bank 切换证明 + A12/IRQ 证明 + MMC3 写侧（W2） |
| `chr_rom` | `nes_system_v6` | 0（NROM） | 同一份 CHR 模型，**`NROM_CHR_RAM=0`** | 与 `ab_v6` **同一份**镜像 | **CHR-RAM / CHR-ROM 忽略对照**：证明写信号生成了、到达了 mapper、并且被 `chr_ram_enable` 挡住 |
| `chr_ram_b` | `nes_system_v6` | 0（NROM） | 同一份 CHR 模型，`NROM_CHR_RAM=1` | 与 `ab_v6` **字节相同**的代码，只有**两个 PRG 数据单元互换** | **自验证对**：从相反的哨兵值出发，必须画出不同画面 |

**为什么 `chr_mmc3` 用另一份程序**：P0-2 的 cart 写计数和 P1-9 的 PPUCTRL 终值是 NROM 专用的，而 P0-7 与 P1-5 需要额外的 `$8001`/`$C000`/`$E000` 写，那些写会改掉这两个数字。把两种激励混在一个实例里，断言就变成互相打架。

**CHR 图像的两条来路（读侧预载 + 写侧上传并存）。** 这是 v6 相对 v4 的一个硬性 testbench 差异，而**写侧**已经通了：程序**用 `$2007` 把 48 字节三 tile 图像写进外部 CHR RAM**，TB 侧则**继续层次预载**整张 128 KiB 图像。两条路都要保留，因为 P0-4 的像素 A/B 是"读侧预载图 + 渲染"，而 W1/PAIR 测的是"写侧上传图 + 渲染"。

**这条区别有个非空洞问题要回答**：如果预载图像恰好和程序要写的图像相同，那么"写通路失效"会**画不出任何差别**，测试就是空的。所以每个 CHR-RAM 板都预载**程序将要写的内容的精确反相**（`ab_v6` 写 `ff/00/00/ff/ff/00` 就预载它的反相，反之亦然）：丢一次写就会改变渲染出来的图案值，A/B 立刻失败。`chr_ram_b` 就是这个思路的整板版本——两份字节相同的代码、两个互换的数据单元、相反的哨兵，最后要求两幅画面**必须不同**。

### 5.1 P0 组：外部 CHR 通路本身

| 断言 | 内容 | 实测 |
| --- | --- | --- |
| **P0-1** | 复位与身份：复位窗口内 `chr_req`、`chr_final_addr`、`chr_we`、`chr_waddr` 恒 0；两个实例的 `dbg_mapper_id` 都是 0 | `reset clks=4`；`chr requests=62678`；`max chr_final_addr = 0x0000101f`（仍 `<= 0x1FFF`） |
| **P0-2** | **地址翻译**：`chr_final_addr` 逐拍等于 TB 侧独立模型 `(tb_chr_bank_model << 13) \| (ab_v6.u_ppu.chr_addr & 0x1FFF)`；并检查 `local[12:0] == final[12:0]`、`final[16:13] == 0` | `checked=62656`、`err=0`——写通路打通以后那 22 个撞上写拍的读拍被排除在外（改用写模型核对），所以这个计数在剩下的读拍上仍然是精确的 |
| **P0-2** | **cart 写脉冲**：TB 模型只从导出的 `cart_xfer && bus_we` 起拍，预测**下一 clk** 的地址/数据 | 3 次 cart 写 → 3 个 `mapper_write_pulse`，地址/数据错 **0**、宽度错 **0** |
| **P0-3** | **bit 13 被丢弃**：`chr_final_addr[13]` 在最后一帧的每一次请求上都为 0 | 20,960 次请求中置位 **0** 次；同一批请求里本地 `chr_addr[12]` 置位 **16,768** 次 |
| **P0-3** | **非空洞探针**：如实报告"没有激励能把 `chr_addr[13]` 抬起"，并把这条限制写成显式说明而不是删掉断言 | 见 3.2 |
| **P0-4** | **整帧 A/B**：`ab_v6` 与 `ab_v5` 在**每一个 `ce`** 上比 `pixel_index`；可见像素比较与不加门的全 `ce` 比较同时做 | 可见像素 **184,320** 次（3 帧 × 240 × 256）、**0** 分歧；全 `ce` **268,026** 次、**0** 分歧；帧周期 **357,368 clk** |
| **P0-5** | **A/B 非空洞**：最后一帧按 `pixel_index` 分类计数，并与 v5 侧逐像素比对 | index 2 = **64**、index 6 = **64**、index 1 = **61,312**、其它 = **0**、不匹配 = **0**（64+64+61312 = 61440 = 240×256） |
| **P0-6** | **CHR 模型自身可信**：TB 把 `chr_rdata` 与 DUT 内部锁存逐拍对着模型核 | 寄存读 `chr_rdata` 对 **62,678** 拍、取数单元 `bg_lo`/`bg_hi` 锁存对 **50,102** 拍，各 **0 错**。CHR 模型现在**运行中被程序写过**，所以地址本身刚被写过的拍被**数出来**并跳过（**23** / **18** 拍，是**打印出来的**计数而不是静默跳过），别的什么都没跳过 |
| **P0-7** | **MMC3 bank 切换**（在 `chr_mmc3` 上） | 见 5.2 |
| **P0-8** | **无总线碰撞**：`chr_req` 从不在连续两个 `ce` 上为高；背景与精灵两个取数单元从不在同一 `ce` 上同时要数据 | `chr_req` 连续两 `ce` 为高：`ab_v6` **0 of 625396**、`chr_mmc3` **0 of 625396**。两个取数单元同 `ce` 碰撞：**586074** 与 **586226** 个采样拍里 **0** 与 **0** 次 |

P0-2 的模型**不是**从输出反推的：本地那一项是**从 PPU 自己的 `chr_addr` 端口层次化读出**的，不是从 `chr_final_addr` 拆出来的。所以这条断言不是自证。

#### 5.1.1 写侧：P0-2 WRITE-TRANSLATION / P0-3 WRITE-STREAM / P0-8 WRITE-STROBE

写通路复用 mapper 那条观察总线，所以它必须被单独钉住——`chr_we` 不抬高 `chr_req`，读侧那 62,656 拍的翻译检查对写地址的覆盖率是 **0**。TB 因此在每个 `$2007` 写拍上重建期望最终地址 `(tb_chr_bank_model << 13) | (chr_waddr & 0x1FFF)`，并断言 `chr_waddr == 递增前的 u_ppu.v_addr`、`chr_waddr[13] == 0`、`local[12:0] == final[12:0]`、`final[16:13] == 0`、`chr_wdata == reg_din`。bit 13 的断言也从"只在请求拍上做"扩展到写拍。

| 断言 | 内容 | 实测（NROM CHR-RAM 板 `ab_v6`） |
| --- | --- | --- |
| **P0-2 WRITE-TRANSLATION** | 写拍逐拍翻译，并核对写地址/数据来自 PPU 自己的 `v_addr` / `reg_din` | 写拍 **96**、被翻译检查 **96**、**0 错**；CHR-RAM 板上 mapper 拒绝 **0** 次 |
| **P0-2** | **选通计数独立闭合**：`chr_we` 的拍数必须等于 bus 侧独立计出来的"写进 CHR 半空间的 `$2007` 写"次数 | 两侧都等于 **96**——**每次写恰好产生一个选通**，不多不少 |
| **P0-3 WRITE-STREAM** | bit-13 断言扩展到写拍 | `chr_final_addr[13]` 在全程写拍上置位 **0** 次 |
| **P0-8 WRITE-STROBE** | 写侧不占连续两拍，并与读侧仲裁的冲突次数**测量出来**而不是假定 | `chr_we` 在两个 `ce` 上连续为高：两块板各 **0** 次；写拍与 `chr_req` 拍重合的 **96** 个写拍里 **22** 个（`ab_v6`）、**3** 个写拍里 **2** 个（`chr_mmc3`），其中背景或精灵开着的有 **0** 个 |

**"22 次碰撞"是一个已记录的已知限制，不是被删掉的检查**（详见第 6 节与 `docs/ppu_chr_external_write.md` 第 4 节）。

#### 5.1.2 写侧整板证据：W1 / PAIR / W2

数字全部来自 TB 输出，实测、口径如下：

| 断言 | 内容 | 实测 |
| --- | --- | --- |
| **W1 NROM-CHR-RAM-WRITE** | 程序把 48 字节三 tile 图像写进渲染器**两个半边**都读的位置（`chr_mem[$0000+off]` 给精灵、`chr_mem[$1000+off]` 给背景） | 写拍 **96**、bus 侧独立计数 **96**（相等）、mapper 接受 **96**、翻译错 **0**、连续两拍 **0**；到达程序置位的标志时，外部 CHR 模型的全部字节都等于程序自己给的值 |
| **W1** | **非空洞哨兵**：CHR-RAM 板预载的是程序所写内容的**精确反相** | 丢一次写就会改变渲染图案值并让 A/B 失败 |
| **W1 SELF-VALIDATING-PAIR** | `ab_v6`（上传 `ff/00/00/ff/ff/00`）与 `chr_ram_b`（上传 `00/ff/ff/00/00/ff`）跑**同一份字节相同的代码**，唯一差别是填充循环读的两个 PRG 数据单元内容 | 选通拍数相等（**96** vs **96**）；最终帧 **245,760** 个 clk 采样上两幅画面**处处不同** |
| **PAIR CHR-RAM-vs-CHR-ROM** | 同一程序、同一地址、同一字节，只是 `NROM_CHR_RAM` 不同——即"CHR-ROM 卡带 + 同样代码"的行为等价性 | 选通 **96** vs **96**（完全一致）；CHR-ROM 板上 `mapper_chr_ram_we` 在 **96** 个写拍里 **0** 次为高；该板 128 KiB 中 **0** / **131,072** 字节改变；两板渲染出**完全相同**的画面 |
| **W2 MMC3-CHR-RAM-WRITE** | MMC3 的写必须被 bank 限定：同一个本地 `$0040`，R0=`$00` 落到 `$00040`，R0=`$42` 落到 `$10840` | `chr_we beats=3`、bus 侧 **3**、mapper 接受 **3**、写拍翻译错 **0**、连续两 `ce` **0**；两个落点相距 **67,584** 字节——证明写通路走的是 mapper 的 bank 偏移，而不是裸本地地址。共享端口上的读/写仲裁有 **2 of 3** 拍撞上读拍，**0** 拍落在可见渲染期 |

**PAIR 的价值在于它不是"没崩就算过"**：写信号必须先**生成**、再**到达 mapper**、然后被 `chr_ram_enable` **在一个具名门控上**拒绝，缺任何一环这个对照都不成立。

**如果要用 MMC3 写 CHR，有一个会咬人的地址译码细节**：同一个本地 `$0040` 想分别落到 R0 和 R2，靠的是 `$2006` 写的**位 12**——`nes_mapper_mmc3.v:110-112` 的 `chr_window_base = ppu_addr[12] ? {1'b1, ppu_addr[11:10]} : {2'b00, ppu_addr[11]}`，所以**位 12 置位选的是窗口 4-7（R2..R5）**。**`$2006 = $1000` 不会到 R0**——R0/R1 需要位 12 为 0。详细推导见 `docs/ppu_chr_external_write.md` 第 7 节。

### 5.2 P0-7：MMC3 证明

程序在 vblank 里对 `$8001` 写**五次**（`$00` / `$01` / `$41` 三步原版，加 W2 引入的 `$00` / `$42` 两步），落点的 scanline/dot 是 **241/71、241/75、241/79、241/65、241/69**——dot 全部**低于 257**，也就是 35 个 `ce` 的精灵 shadow 构建窗口开始之前，因此五次写都不会污染被观测的窗口。写进去的值让 R0 寄存器依次成为 `00` / `00` / `40` / `00` / `42`：

| 项 | 实测 |
| --- | --- |
| 五次 `$8001` 写后的 R0 寄存器 | `00` / `00` / `40` / `00` / `42` |
| (a) 逐拍核对 `chr_final_addr` | `chr beats total=146556`（`chr_mmc3` 上 `chr_req` 的全程总数，**不等于**逐档之和）；逐档 `20961 / 20961 / 20956 / 20961 / 43581`，`err=0 / 0 / 0 / 0 / 0` |
| (a) DUT 的 `chr_final_addr[16:10]` 每档首值 | `00000000 / 00000000 / 00000040 / 00000000 / 00000042`——与上面那排 R0 寄存器逐档对应 |
| (b) 具名 tile-0 像素索引 | `1`(1920/1920) → `1`(1920/1920) → `8`(1920/1920) → `1`(1920/1920) → `8`(3843/3843)，strays 全 0 |
| (c) `$41` 那一档的 `chr_final_addr[16]` | R0 = `$40`，所以 `chr_final_addr[16]==1` 在 **20956 / 20956** 拍成立——**位 16 是 17 bit 地址里的真实一位**，16 bit 的 TB 下标做不出来 |

第 4、5 步就是 W2 那一对 bank 写，**故意**留在分档统计里，好让逐档分桶继续覆盖每一次 `$8001` 写；它们因此也要满足和前三步同一条具名索引规则。`ppuctrl` 全程是 `$00`，所以 `PPUCTRL[4]/[5]` 从来没有移动过窗口。

**第二步为什么不变**：`nes_mapper_mmc3.v:208` 把 R0 锁成 `{data[7:1], 1'b0}`，所以 `$00` 与 `$01` 是**同一个 1 KiB bank**——bit 0 是"奇/偶 1 KiB 选择"，它落在本地 `chr_addr[11]` 上而不在寄存器里（真实 MMC3 是 2 KiB 粒度）。TB 记录这一点的方式是**把相等测量出来**（断言 DUT 自己的 `chr_final_addr[16:10]` 在这两步逐位相同——上面那排首值 `00000000` 与 `00000000` 就是这条断言的实测形态），而不是把期望值改小。**四份**预载 bank 图像（reg `$00` @ `0x0000`、reg `$00` 图像 2 @ `0x0800`、reg `$40` @ `0x10000`、W2 图像 @ `0x10800`）两两不同，所以"第二档没有新画面"来自寄存器选中了同一块 bank，**与图像无关**。

### 5.3 P1 组：在 v6 实例上重新证明 v5 的不变量

**P1 组不是"沿用 v5 的结论"，而是在 v6 实例上重新测一遍**，因为 `EXTERNAL_CHR` 改变了 PPU 的读通路，任何"v5 说过所以 v6 没问题"的推理都不成立。实测：

- **P1-1 可等待总线**：每个 `ce_cpu` 上 `bus_stall == req && !fire`（0 错），`dbg_wait_count` 全程 0；每次 cart 读在 `mapper_prg_bank_offset`、`cart_din`、`bus_din` 三处对上 TB 侧独立 PRG bank 模型。另有一条 **CHR 端口结构上不在 CPU 总线上**的检查（按 `bus_owner` 分解：CPU 总线空闲时的 CHR 请求数、DMA 持总线时的 CHR 请求数、按 open/ram/ppu/apu/cartrom 分类）。
- **P1-2 OAM DMA**：`$4014` 1 次启动、256 次 ack、256 次 `$2004` 写、**0 次 MMIO 命中**；并且一条 **v6 特有风险**被专门检查——`$2004` 在**外部 CHR 的 PPU** 里仍然落进 `oam_ram`（`oam_ram[0..3] = 11 22 33 44`，256 字节全部与源页相同）。这条如果漏了，"DMA 被 CHR 读抢走"的失败模式会非常难查。
- **P1-3 mirroring**：iNES 头的 horizontal 模式被观测到并被导出，但 `nes_ppu2c02` **没有运行期 mirroring 端口**，两个实例都以 `MIRROR_VERTICAL=0` elaboration——**模式被观测，没有被应用**。
- **P1-4 IRQ 线或**：每个 `clk` 上 `irq_line == (mapper_irq | apu_irq)`、`dbg_irq_pending == irq_line`；NROM 的 `mapper_irq` 与被 `$4017 = $40` 禁止的 `apu_irq_o` 的高电平 clk 数都被记下。
- **P1-5 MMC3 A12 与 `force`**：在 `chr_mmc3` 上——`$C000` 锁存 `0x07`，`$C001` 置 reload 且**一直保持 1**，计数器**仍是 0**（`a12` 滤波器一次都没触发，因为 `mapper_ppu_a12` 在 `nes_system_v6` 里硬绑 0），`$E001` 然后 `$E000` 让 `irq_enabled=0`，`mapper_irq` 在整个程序的每一个 clk 上都是低。然后 `force` 压寄存器，走通 `mapper_irq → irq_line → dbg_irq_pending`，**7 个 `bus_fire` 周期的入口**、`$FFFE` 取向量、handler 把 `ram[0013]` 递增。
- **P1-6 NMI**：`nmi_o == vblank && ppuctrl[7]` 逐 clk 断言。
- **P1-7 controller**、**P1-8 音频**（sample strobe 与非零样点、DMC 不请求总线、frame IRQ 被禁止）、**P1-9 PPU 寄存器**（v6/v5 双侧 `ctrl`/`mask`/`v`/`t`/`w`/`fine_x`/`oamaddr`/`nt[1]`/`palette` 对照，并确认 `$2005`/`$2006` 没有漂移）、**P1-10 CPU**（reset 向量、首个操作码、0 个非法 opcode、没进失败块）、**BUS owner accounting**（每一类传输的计数与总传输数闭合）。

### 5.4 A/B 证明了什么、没证明什么

**证明了**（且只证明这些）：

1. 在 NROM（CHR bank 项恒 0）下，v6 的外部 CHR 通路产出的**每一个可见像素**与 v5 的内部 CHR 通路一致，3 帧共 184,320 次，外加 268,026 个不加门的 `ce` 全等。
2. 这个比较**不是空的**（P0-5 给出像素分类分布：非 backdrop 像素 128 个 + 61,312 个另一类）。
3. mapper 的 CHR 偏移是**纯前馈**的：TB 逐拍比对 `(bank << 13) | local`，所以"顶层再加一次"这种错误改法会被抓。
4. MMC3 的 CHR bank 切换在系统级**真的换了画面**，且位 16 是真实的地址位。
5. **`$2007` 写外部 CHR 真的落了地**：NROM CHR-RAM 板上 96 个写拍全部翻译正确、mapper 一个都没拒，且 **bus 侧独立计数也是 96**——每次写恰好一个选通。`chr_ram_b` 从相反哨兵出发、与 `ab_v6` 在最终帧 245,760 个采样上处处不同，排除了"两板都渲染自己哨兵"的假通过。CHR-ROM 板上同样的 96 个写拍在 `chr_ram_enable` 具名门控处被拒、0 字节改变、画面与 CHR-RAM 板一致——这就是 CHR-ROM 卡带的行为。

**没有证明**：

1. **不证明精灵像素的等价性。** `ab_v5` 与 `ab_v6` 的 A/B 是**背景**对比；精灵在两个实例上用的都是 TB 预载的图案，A/B 覆盖不到"外部模式精灵画错"这类缺陷。PPU 侧的 `ppu-ext-chr-tb` 仍然用全 0 透明精灵图案。
2. **不证明任何真实存储器能满足 1 拍寄存读。** TB 的 CHR 模型是零时序代价的。
3. **不证明 `$2007` 读回外部 CHR**——写通了，读仍然返回 0，见第 6 节第一条。
4. **不证明硬件行为。** 没有任何综合、Fitter、TimeQuest、引脚或上板证据；本机没有安装 Quartus。`ppu_ext_chr` 端口是纯 RTL 端口，不是引脚。片上 CHR 阵列的 BRAM 推断也没有被验证过。
5. **不证明 MMC3 的 bit 7 bank 编号可用**——`CHR_ADDR_BITS = 17` 把它们截掉了（见 3.4）。
6. **不证明渲染中途写 CHR 是安全的**——读/写仲裁冲突被测量出来了，但没有被修掉，见第 6 节。

## 6. v6 明确未实现

以下是被测顶层 `nes_system_v6` 的范围限制，不是 testbench 的缺陷：

- **`$2007` 对外部 CHR 的读仍然返回 0。** 外部分支的 `ppu_space_read` 对 `address < 14'h2000` 直接返回 `8'h00`（`nes_ppu2c02.v:557-561`）。**写通了，读回没有通。** `chr_rdata` 走的是**取数单元**那条通路，不是 `$2007` 那条。
- **读/写仲裁冲突未修。** `chr_req`（`nes_ppu2c02.v:709`）**不会**被写抑制，`bg_fetch_due`（`:604`）也没有扫描线/掩码门控，所以同一个 `ce` 上两者可以同时为高。实测 **96 个写拍里有 22 个**与在飞的背景取数撞上；`bg_pa_enable` 为高时 **0** 个（上传期间 `PPUMASK=$00`）。写优先意味着撞上那一拍取数单元锁存的是写地址的字节——**渲染中途做 `$2007` CHR 写会损坏一个 tile 拍**。这是已知限制，不是被删掉的检查。
- **片上没有任何 CHR 存储。** 128 KiB CHR 只存在于 testbench 里。真实系统需要外部存储（SDRAM 或 TF），**而 SDRAM 控制器在仓库里还不存在**，TF 也只有命令帧发送器。选通 `chr_we` 是组合的、不登记，所以下游存储器必须自己按单拍脉冲用；片上 CHR 阵列能否被推断成 BRAM 也没有验证过（无 Quartus/Fitter/STA）。
- **`write_toggle` 与 `read_buffer_reg` 的既有行为未动。** `$2007` 写不清 `write_toggle`，写也不清 `read_buffer_reg`。这是**预先存在**的，且被刻意不动：对称地修任何一边都会改变 PPU 的内部分支并波及 10 个以上回归目标，留给专门的一轮。
- **`mapper_ppu_a12` 仍绑 0**，所以 MMC3 的扫描线 IRQ 计数器在系统级**仍然无法自时钟**；系统级只能覆盖到 latch / reload / enable / disable / ack 与 IRQ 线。`chr_final_addr[12]` 已经是 PPU 的 pattern-table 选择位而不是 bank 位，所以它**不能**拿来当 A12 用。
- **`CHR_ADDR_BITS = 17` 截断 MMC3 的 CHR bank bit 7**，`0x80`–`0xFF` 别名到 `0x00`–`0x7F`。已接受，不要加宽（见 3.4）。
- **PPU 没有运行期 nametable-mirroring 端口。** v5/v6 都以 `MIRROR_VERTICAL(1'b0)` elaboration；mapper 的 mirroring 输出被观测但**没有被应用**。四屏的 4 KiB nametable RAM 同样没有。
- **CHR 端口上没有背压。** `chr_req` 是无条件请求，没有 ready/ack；一次背景/精灵请求拍的重叠会**静默丢掉**背景那一拍（读侧 P0-8 实测 0 次，但它成立只因为两个窗口不重叠；写侧见上面第二条，冲突是被测量出来的）。
- **PRG RAM / `$6000-$7FFF` 没有存储阵列**、**MMC1 的串行移位寄存器在系统级没有被程序驱动过**、**MAPPER_SELECT 仍是 elaboration 期参数**、`chr_final_addr` 没有被任何模块实例化使用——与 v5 相同，见 `docs/modules/system-v5.md` 第 8 节。
- 其余与 v5 相同的总线与 CPU 缺口（`$4017` 读只回手柄位、open bus 上没有手柄位、`$4016` bit6/bit7 扩展口、第 9 次以后读恒 1、DMC DMA 未激励、`OAMADDR_WRITE=0`、音频输出通路）见 `docs/modules/system-v5.md` 第 8 节。

## 7. 运行

回归目标已经登记在 `tools/sim_all.ps1` 的 `-Mode system-v6`（同时进了 `-Mode all` 的固定顺序第 38 位，紧跟 `system-v5`）。等价的直接调用：

```powershell
$tmp = Join-Path $env:TEMP 'op_fpga_emu'
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
$v6 = @(
  'rtl\nes_core\system\nes_system_v6.v',
  'rtl\nes_core\system\nes_system_v5.v',
  'rtl\nes_core\ppu\nes_ppu2c02.v',
  'rtl\nes_core\ppu\nes_ppu_sprite.v',
  'rtl\nes_core\ppu\nes_chr_fetch_unit.v',
  'rtl\nes_core\ppu\nes_sprite_chr_fetch.v',
  'rtl\nes_core\ppu\nes_oam_dma.v',
  'rtl\nes_core\controller\nes_controller.v',
  'rtl\nes_core\bus\nes_cpu_bus.v',
  'rtl\nes_core\cpu\nes_cpu6502.v',
  'rtl\nes_core\apu\nes_apu_length_lut.v',
  'rtl\nes_core\apu\nes_apu_pulse.v',
  'rtl\nes_core\apu\nes_apu_triangle.v',
  'rtl\nes_core\apu\nes_apu_noise.v',
  'rtl\nes_core\apu\nes_apu_dmc.v',
  'rtl\nes_core\apu\nes_apu2a03.v',
  'rtl\nes_core\mapper\nes_mapper.v',
  'rtl\nes_core\mapper\nes_mapper_nrom.v',
  'rtl\nes_core\mapper\nes_mapper_uxrom.v',
  'rtl\nes_core\mapper\nes_mapper_cnrom.v',
  'rtl\nes_core\mapper\nes_mapper_mmc1.v',
  'rtl\nes_core\mapper\nes_mapper_mmc3.v',
  'tb\system\tb_nes_system_v6.v'
)
& 'C:\iverilog\bin\iverilog.exe' -g2012 -s tb_nes_system_v6 -o (Join-Path $tmp 'tb_nes_system_v6.vvp') $v6
& 'C:\iverilog\bin\vvp.exe' (Join-Path $tmp 'tb_nes_system_v6.vvp')
```

**源文件列表必须包含 `nes_system_v5.v`**：TB 的 `ab_v5` A/B 参照实例要能 elaborate 起来，缺了它整条目标编译不过。`nes_ppu2c02.v` 的外部分支**同时**例化 `nes_chr_fetch_unit` 与 `nes_sprite_chr_fetch`，这两个文件也必须显式列出。

testbench 用 `$fatal` 判定，因此入口用 `-g2012`。`#120000000`（120 ms）有全局超时兜底：CPU 卡死、漏掉一个 `frame_done` 或某个 `wait()` 挂住都会走到那里 `$fatal("global timeout")`，而不是无限挂起。`vvp` 非零退出即失败。没有对应的 ModelSim `.do` 脚本。

testbench 本身的断言清单、固定期望输出摘要与它绕过的问题见 [`tb/system/README.md`](../../tb/system/README.md) 的"v6 testbench"一节。

## 8. 回归与耗时

`.\tools\sim_all.ps1 -Mode all` 在本机实测 **`Result: PASS (51 of 51)`**、0 FAIL、墙钟 **1401.6 s**（约 23.4 min）。目标数从 50 变成 51，新增的只有 `system-v6` 一个。

`system-v6` 本机 **208.4 s**（加入 `$2007` 写通路、实例从三个增加到五个之后；写通路之前是 119.3 s）。全量里最慢的仍然是 `ppu-ext-chr-tb`（约 434–447 s，占全量的主导份额），其次是 `system-v6`。**本轮只保留了总量、最慢目标与新目标的逐项秒数，第 3 名及以后没有单独留存**，所以本文不重复逐目标表。

**本机没有安装 Quartus**，所以这一整套数字只是 Icarus Verilog 下的 RTL/TB 内部一致性；它不构成任何综合、引脚、时序或上板证据。
