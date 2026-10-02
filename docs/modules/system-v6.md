# 系统集成 v6：把 PPU 的外部 CHR 读通路接到 mapper 的 bank 偏移输出上

本文是 `rtl/nes_core/system/nes_system_v6.v` 的接口与接线合同。它最初是 `nes_system_v5.v` 的**字节级副本加一个小 delta**：PPU 用 `.EXTERNAL_CHR(1'b1)` 例化，v5 里那根绑常数的 `mapper_ppu_addr` 改由 PPU 的本地 CHR 地址驱动，顶层多出三个 CHR 端口。后来 `$2007` 外部 CHR **写**通路也补进了同一个模块（`5cc36e7`、`576cc74`），顶层 CHR 端口增加到六个。再后来 `$2007` 外部 CHR **读**通路也补了进来——它**不新增顶层端口**，只多了一根模块内部的读臂线网 `ppu_chr_rd_arm`，所以"顶层 CHR 端口增加到六个"这句话今天仍然成立，表头那句"小 delta"只对**读**通路成立。核心问题只有四个：

1. mapper 的 `chr_bank_offset` 是"CHR 空间里的**绝对字节偏移**"，而 PPU 发出来的是"**单个 8 KiB 窗口里**的本地地址"。这两个数怎么组合，才既不给 mapper 加第二个加法器、又不制造组合环？读地址与写地址共用这一条总线时，仲裁规则是什么？
2. 本地地址的 pattern-table 选择位到底是 `chr_addr[13]` 还是 `chr_addr[12]`？这个问题的答案决定了"把 `ppu_addr[13]` 丢进 mapper"到底丢的是 bank 位还是 PPU 内部译码位。
3. 外部 CHR 存储器要满足什么时序合同？`chr_req` 上没有应答信号，存储器能不能"这一拍不给"？
4. v6 做到了哪一步、哪一步明确留给下一阶段？`$2007` 写外部 CHR、`$2007` 读外部 CHR 这两步做完了没有，边界在哪里？

`docs/modules/system-v5.md` 写清 v5 顶层的 mapper 接线、软件 mapper 的 dispatch 与指针数组到 bank 寄存器的对应关系、`prg_readback` 驱动的 bus conflict 与 mapper IRQ 线或；`docs/modules/ppu-external-chr.md` 写清 PPU 侧 `g_chr_external` 分支的取数流水、dot 预算与等价性陷阱。本文不重复那两份，只写 v6 **新加的那一根线**、**地址合同**，以及**为什么是这样**。

行为权威是 NESdev 的 mapper/NROM/MMC1/MMC3 说明与 pattern table 说明。`[源码观察]` 标记的内容只是克隆仓库的写法，不是规格。

---

## 1. v6 相对 v5 的增量

| 项 | v5 | v6 |
| --- | --- | --- |
| PPU 例化 | `nes_ppu2c02 #(.MIRROR_VERTICAL(1'b0))`，默认 `EXTERNAL_CHR = 1'b0` | 同一份例化，加 `.EXTERNAL_CHR(1'b1)` |
| `mapper_ppu_addr` | `wire [13:0] mapper_ppu_addr = 14'h0000;`（常量） | `wire [13:0] mapper_ppu_addr = ppu_chr_we ? ppu_chr_waddr : ppu_chr_addr;`（读地址与写地址的组合仲裁，**写优先**） |
| `mapper_ppu_we` / `mapper_ppu_dout` | `1'b0` / `8'h00` | 接 PPU 的 `chr_we` / `chr_wdata`。外部分支不再绑 0：`chr_we` 是 `$2007` 写的组合单 `clk` 选通，`chr_wdata` 是 `reg_din` |
| `mapper_ppu_a12` | `1'b0` | `1'b0`（**不变**，见第 6 节）。TB 侧**为了验证**而 force 上去过一条建模的 A12 流，但**生产 RTL 里这一行一个字节都没改**（`nes_system_v6.v:302`；读臂那一轮之前是 `:259`），而且 TB 在 force 窗口的**两侧**都断言它读回 0 |
| 顶层 CHR 端口 | 无 | 新增 `chr_rdata[7:0]`（in）、`chr_req`（out）、`chr_final_addr[CHR_ADDR_BITS-1:0]`（out，默认 17 bit）；写通路再加 `chr_waddr[13:0]`（out）、`chr_we`（out）、`chr_wdata[7:0]`（out）。**读臂那一轮没有再加顶层端口**——`chr_rd_arm` 是 PPU 的输入、由 v6 在模块内部生成（`ppu_chr_rd_arm`，`:255`、赋值 `:296-297`、接进 PPU 在 `:537`） |
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

`chr_waddr` 是 `v_addr` 的**第 14 位与第 13 位都为 0 时的低 14 位**（条件写就是 `v_addr < 15'h2000`，`nes_ppu2c02.v:813`；写通路落地那一轮结束时是 `:712`），所以写地址的 bit 13 结构上恒 0，位 12 仍然是 pattern-table 选择位。

## 2. 接线：读三根线、写三根线、两个输出端口

### 2.1 PPU 侧

```verilog
wire        ppu_chr_req;
wire [13:0] ppu_chr_addr;
wire        ppu_chr_rd_arm;   // 读臂那一轮新增：$2007 CHR 读的请求，模块内部生成
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
    .chr_rd_arm(ppu_chr_rd_arm),
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

**读端口的合同（读臂那一轮）**：`chr_rdata` 早就是顶层输入，`chr_rd_arm` **不是**顶层端口——它由 v6 在模块内部生成，`ppu_chr_rd_arm = sel_ppu && !cpu_we && (ppu_addr == 3'd7) && cpu_bus_ready && (div_phase == 4'd8);`（`:296-297`）。**为什么必须落在 `div_phase == 8`**：外部 CHR 存储器在**每一个 `ce_ppu` 沿**寄存 `chr_rdata`（`ce_ppu` 在 `div_phase` 0 / 4 / 8 触发），而 CPU 在 `div_phase == 0` 锁存 `bus_din`，所以地址必须**提前整整一个 `ce`** 上总线。`v_addr` 只在 `$2007` 那一拍变，所以在这个窗口里是稳的——**提前量恰好零余量**，`v_addr → chr_addr → mapper → chr_final_addr → chr_rdata` 链上任何一处插一个寄存器都会打断它。

**两个方向项都必须用 CPU 侧的那几个，不能用 PPU 侧的**：`sel_ppu`（`nes_cpu_bus.v:129`）**承重**——`ppu_addr` 本身只是 `cpu_addr[2:0]`（`nes_cpu_bus.v:189`），没有 `sel_ppu` 的话一次 `$4007` 的 APU-IO 读会被译码成 `$2007`，把 `v_addr` 送上 CHR 总线。方向项是 `!cpu_we` 而**不是** `!ppu_we`：`ppu_we = ppu_req && cpu_we`（`nes_cpu_bus.v:239`）而 `ppu_req` 在 `div_phase == 8` 上**结构上恒为 0**（`nes_cpu6502.v:215` 让 `cpu_active = ce && !bus_hold && !reset`、`:755` 在 `!cpu_active` 时强制 `bus_req = 1'b0`，而 `nes_cpu_bus.v:238` 的 `ppu_req` 一路依赖 `bus_req`），所以 `!ppu_we` 会**恒真**、什么也不限定。**首版就是用 `ppu_req` + `!ppu_we` 写的，结果读臂从来没有抬起过**，每个 `$2007` CHR 读都返回 PPU 内部那条失效保护的 `8'h00`，新 testbench 在**第一个**读拍上就失败。**这一段必须记下来，否则会被重新引入。**

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

TB 在最后一帧的 **21,002** 次请求上量到**本地 `chr_addr[13]` 为 1 的次数是 0**（写通路那一轮是 20,960，差额是读臂现在也是请求拍），而**本地 `chr_addr[12]` 为 1 的次数是 16,768**——后者是**读通路那一轮之前**的数字，本轮没有单独留存。所以"pattern-table 选择落在 bit 12"这件事是被测出来的，不是推出来的。

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
| `chr_req` | out | 1 | PPU 请求一个外部 CHR 字节。**无背压、无应答**。**（已按事实更新）读臂那一轮起 `$2007` CHR 读也抬它，所以"`chr_req` 从不在连续两个 `ce` 上为高"不再是全局性质**：那 625,396 个 `ce` 上的 0 次是**读臂那一轮之前**的测量；现在实测有 **171** 组连续对（见 5.1 的 P0-8），"两拍都不是读臂"的连续对仍是 **0** |
| `chr_final_addr` | out | `CHR_ADDR_BITS`（默认 17） | **映射后的最终 CHR 字节地址**，等于 `mapper_chr_bank_offset`。**没有任何模块读它**，它只用于观测与 TB 建模 |
| `chr_waddr` | out | 14 | `$2007` 写外部 CHR 的**本地**地址 = 递增前的 `v_addr[13:0]`；`v_addr >= $2000` 时为 `14'h0000`。只在 `chr_we` 为高时有意义 |
| `chr_we` | out | 1 | `$2007` 写外部 CHR 的**组合单 `clk` 选通**。复位期间为 0。**不登记**：下游必须按脉冲用 |
| `chr_wdata` | out | 8 | 写进 `$2007` 的那个字节（`reg_din`），与 `chr_waddr` / `chr_we` 同拍有效 |

`chr_waddr` / `chr_we` / `chr_wdata` **不再**是"故意不导出"的常量。`mapper_chr_ram_we` 是 mapper 侧那根：它是**过了 `chr_ram_enable` 与 bit 13 门控之后**的选通，CHR-ROM 板上应当恒为低，TB 在 CHR-RAM/CHR-ROM 对照板上量到的正是这一根。

其余端口与 v5 逐条相同（`clk`、`reset`、`pixel_*`、`frame_done`、`vblank`、`nmi_o`、`apu_irq_o`、`audio_sample_*`、`cpu_cycle`、`ppu_dot`、`ppu_scanline`、`prg_readback`、`mapper_*`、`irq_line` 等）。`mapper_ppu_a12` 仍绑 0。

## 5. `tb/system/tb_nes_system_v6.v` 怎么测

**6,597** 行，同一个 `clk` 上**五个** DUT 实例。本机实测运行时间 **约 259.7 s**（回归目标 `system-v6`，`-g2012` 编译 + `vvp`；**读臂那一轮的实测值**，比读臂之前的 259.1 s 高 **0.9%**；P1-11 加入前 208.4 s，加入后 255.4 s）。多出的约 48 s 是 P1-11 的速率核对：它要求一整帧被两个 `frame_done` 边沿夹住，而窗口从帧中间打开，所以等待约 2.0 帧；相位 2b/2c 只额外贡献约 14,500 `clk`。实例从三个增加到五个，全部是为了 `$2007` 写外部 CHR 服务的；读臂那一轮**没有**增加实例，只增加了 W3 组断言。

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
| **P0-1** | 复位与身份：复位窗口内 `chr_req`、`chr_final_addr`、`chr_we`、`chr_waddr` 恒 0；两个实例的 `dbg_mapper_id` 都是 0 | `reset clks=4`；`chr requests=62801`（读臂那一轮；读臂之前是 62678，差额 123 是读臂带来的请求拍）；`max chr_final_addr = 0x0000101f`（仍 `<= 0x1FFF`） |
| **P0-2** | **地址翻译**：`chr_final_addr` 逐拍等于 TB 侧独立模型 `(tb_chr_bank_model << 13) \| (ab_v6.u_ppu.chr_addr & 0x1FFF)`；并检查 `local[12:0] == final[12:0]`、`final[16:13] == 0` | `checked=62779`、`err=0`（读臂那一轮；读臂之前是 62656）——写通路打通以后那 22 个撞上写拍的读拍被排除在外（改用写模型核对），所以这个计数在剩下的读拍上仍然是精确的 |
| **P0-2** | **cart 写脉冲**：TB 模型只从导出的 `cart_xfer && bus_we` 起拍，预测**下一 clk** 的地址/数据 | 3 次 cart 写 → 3 个 `mapper_write_pulse`，地址/数据错 **0**、宽度错 **0** |
| **P0-3** | **bit 13 被丢弃**：`chr_final_addr[13]` 在最后一帧的每一次请求上都为 0 | **21,002** 次请求中置位 **0** 次（读臂那一轮；读臂之前是 20,960）；同一批请求里本地 `chr_addr[12]` 置位 **16,768** 次——后者是**读臂那一轮之前**的数字，本轮没有单独留存 |
| **P0-3** | **非空洞探针**：如实报告"没有激励能把 `chr_addr[13]` 抬起"，并把这条限制写成显式说明而不是删掉断言 | 见 3.2 |
| **P0-4** | **整帧 A/B**：`ab_v6` 与 `ab_v5` 在**每一个 `ce`** 上比 `pixel_index`；可见像素比较与不加门的全 `ce` 比较同时做 | 可见像素 **184,320** 次（3 帧 × 240 × 256）、**0** 分歧；全 `ce` **268,026** 次、**0** 分歧；帧周期 **357,368 clk**（读臂那一轮**逐字未变**） |
| **P0-5** | **A/B 非空洞**：最后一帧按 `pixel_index` 分类计数，并与 v5 侧逐像素比对 | index 2 = **64**、index 6 = **64**、index 1 = **61,312**、其它 = **0**、不匹配 = **0**（64+64+61312 = 61440 = 240×256） |
| **P0-6** | **CHR 模型自身可信**：TB 把 `chr_rdata` 与 DUT 内部锁存逐拍对着模型核 | 寄存读 `chr_rdata` 对 **62,801** 拍（读臂那一轮；读臂之前是 62,678）、取数单元 `bg_lo`/`bg_hi` 锁存对 **50,102** 拍，各 **0 错**。CHR 模型现在**运行中被程序写过**，所以地址本身刚被写过的拍被**数出来**并跳过（**23** / **18** 拍，是**打印出来的**计数而不是静默跳过），别的什么都没跳过 |
| **P0-7** | **MMC3 bank 切换**（在 `chr_mmc3` 上） | 见 5.2 |
| **P0-8** | **（已按事实更新）无总线碰撞被重新界定，不是被削弱**：`chr_rd_win` 现在直接喂 `chr_req`，所以"`chr_req` 从不在连续两个 `ce` 上为高"**按构造**就会被违反；`mask_reg[3]` 也不能用来推广它（mask 门的是像素不是总线：实测 `PPUMASK=$00` 仍产生 **3,069** 组连续对、读限制在 240–260 仍产生 **369** 组）。现在断言被重新表述在**可以合法相撞的那些拍**上：每一组连续对按**第二拍是哪个 master 赢**归属（用 PPU 自己选 `chr_addr` 的表达式），并断言**两拍都没有读臂**的连续对为 **0**——那正是旧不变式覆盖的"取数对取数"性质；另外断言没有两个读臂相邻 | `chr_req` 连续两 `ce` 为高：`ab_v6` **171** 组（读臂那一轮）、`chr_mmc3` **0 of 625396**（它的程序不发 `$2007` 读，`m_req_consec == 0` **逐字保留**）。171 组里 **89** 组第二拍由读臂赢（80 背景 / 9 精灵）、**82** 组由取数赢（82 背景 / 0 精灵）、**0** 组两拍都没有读臂。两个取数单元同 `ce` 碰撞：**586074** 与 **586226** 个采样拍里 **0** 与 **0** 次（不变） |

P0-2 的模型**不是**从输出反推的：本地那一项是**从 PPU 自己的 `chr_addr` 端口层次化读出**的，不是从 `chr_final_addr` 拆出来的。所以这条断言不是自证。

#### 5.1.1 写侧：P0-2 WRITE-TRANSLATION / P0-3 WRITE-STREAM / P0-8 WRITE-STROBE

写通路复用 mapper 那条观察总线，所以它必须被单独钉住——`chr_we` 不抬高 `chr_req`，读侧那 **62,779** 拍（读臂那一轮；读臂之前是 62,656）的翻译检查对写地址的覆盖率是 **0**。TB 因此在每个 `$2007` 写拍上重建期望最终地址 `(tb_chr_bank_model << 13) | (chr_waddr & 0x1FFF)`，并断言 `chr_waddr == 递增前的 u_ppu.v_addr`、`chr_waddr[13] == 0`、`local[12:0] == final[12:0]`、`final[16:13] == 0`、`chr_wdata == reg_din`。bit 13 的断言也从"只在请求拍上做"扩展到写拍。

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

#### 5.1.3 读侧整板证据：W3 组

**这一小节是 `$2007` 读臂那一轮新增的。** 数字全部来自 `-Mode system-v6` 的那次通过运行；逐条教学与合同见 [`docs/ppu_chr_external_write.md`](../ppu_chr_external_write.md) §8.1 与 [`docs/modules/ppu-external-chr.md`](ppu-external-chr.md) 11.3.9。

| 断言 | 内容 | 实测 |
| --- | --- | --- |
| **W3-1 ARMED-ALWAYS** | 读拍与读臂一对一；每个读拍都看到 `chr_rd_armed_q=1`；每个读臂都在**下一个** `ce_ppu` 被一个读拍消费掉；没有背靠背两个读臂 | 读拍 **396** / 读臂 **396**；`chr_rd_armed_q` 违例 **0**、悬空 **0**、背靠背两臂 **0**。**这条杀掉的是"结构上死掉的通路"**——不抬的读臂不会留下读拍，读拍没有读臂也过不了 |
| **W3-2 ROUND-TRIP** | 期望值由 TB 自己的 bank 模型与 PPU 自己的 `v_addr` 重建，**从不**用 `chr_rdata` 自己当期望；一个读的偏斜是**测出来的** | 读拍核对 **395**、错 **0**（本轮第一个 `$2007` 读没有前驱，被排除 **1**）；臂捕获核对 **396**、错 **0**、因写竞争跳过 **0**。偏斜的原因：`reg_cs` 只在**完成**那次两拍 `$2007` 访问的那一拍为高，而 `read_buffer_reg` 在**同一个沿**上被重新填，所以 CPU 在第 N 次访问上收到第 N−1 次的字节——**这就是真 2C02 的读缓冲** |
| **W3-3 CROSSES-THE-MAPPER** | 读地址真的离开 PPU、真的过 mapper 翻译（不是私有旁路），且**不抬** store enable、**不与**写 strobe 的捕获沿重合 | 396 个臂拍上 `chr_addr == u_ppu.v_addr[13:0]` 错 **0**、`chr_final_addr == (tb_chr_bank_model<<13)\|(v_addr[13:0]&0x1fff)` 错 **0**；`mapper_chr_ram_we` 高 **0**、`chr_we` **0**。读臂的方向项是 `!cpu_we` 而不是 `!ppu_we`——`ppu_we = ppu_req && cpu_we` 而 `ppu_req` 在 `div_phase == 8` 结构上恒 0，所以 `!ppu_we` 会恒真、什么也不限定 |
| **W3-4 VALUE-TRACKS-CHR-CONTENT** | 32 个回读字节逐个与**各自实例**的 CHR 内存比 | 四块板错 **0**；窗口 `$0000` 在 ab_v6 / ab_v5 / chr_rom 上读回 `ff`、在 chr_ram_b 上读回 `00` → **32** 个单元里 **24** 个不同。**诚实限制**：chr_rom 的回读**不**与 ab_v6 逐字节不同（不可能——它预载的就是程序上传的那张图）；被测的是**来源**：`chr_mem[$0000]` 运行前哨兵 `$00`、现在 `$FF`，而 ROM 板运行前后都是 `$FF`，且 96 个写全被拒、128 KiB 改 **0** 字节 |
| **W3-5 UNWRITTEN-ADDRESS** | `$1040` 在可达 pattern 表内、且在上传触及的每个地址之外 | 8 个字节在 ab_v6 上全读回 `$00`（错 **0**）；在 ab_v6 / ab_v5 / chr_rom 上逐个可证与 `$1020` 刚写入的字节**不同**（各 **8/8**）。**诚实限制**：chr_ram_b **0/8 退化**（run B 的 ON 常量与 TB 装载值都是 `$00`），那块板改由窗口 `$0000` 分开；`chr_mmc3` **不发任何 `$2007` 读** |
| **W3-6 SENTINEL-SURVIVES** | 四个读窗口在程序 `ram[0015]` 标志处快照、结束时重读 | **0 / 32** 字节移动；`chr_mem[$2000+d]` 的 **48** 个字节仍持哨兵（错 0）；ROM 板 128 KiB 与运行前快照**逐字节相同** |
| **W3-7 MODEL-CREDIBILITY** | **不新增模型**，复用 P0-6 已有的按 `ce` 影子 | 请求拍 **146,797** 错 **0**、取数单元锁存 **117,164** 错 **0**；因写竞争跳过 23 / 18。读臂是请求拍的一种，所以它就在这些数字里面 |
| **W3-8 CROSS-DUT-VALUE-AB** | **最强的一条**：同一份程序、两个**完全不同**的存储机制必须给出同一个字节 | ab_v5 用 PPU 自己的内部 `chr_ram` 回答同一批 `$2007` 读（**无外部端口、无 mapper、无总线**），ab_v6 用顶层一个 128 KiB 寄存阵列经 `mapper_ppu_addr` 回答；32 个持有回读字节的 RAM 单元**逐字节相同**，不同的单元 **0** |
| **W3-9 COLLISION-IS-REAL** | 撞车必须真的发生过，否则"从不争用"的设计会静默通过 | 396 个臂里 **107** 个与在飞的取数请求撞在同一个 `ce`（背景 **71**、精灵 **36**）；落点 **378** 个在 vblank 扫描线 240–260（loop B、渲染开）、**18** 个在外面（loop A、`PPUMASK=$00`），跨扫描线 93..255 |
| **W3-9b** | P0-8 从另一侧独立核对 | 171 组连续 `chr_req` 对里 **89** 组第二拍由读臂赢（80 背景 / 9 精灵）、**82** 组在读臂之后由取数赢（82 背景 / 0 精灵）、**0** 组两拍都没有读臂 |
| **W3-10 INVISIBILITY-PROVEN** | 每个臂在**臂拍本身**对着写明的不可见集合核对；任何违例当场 `$fatal` 而不是事后计数 | 396 个臂违例 **0**；`P0-4` 仍是 **184,320** 次可见像素比较 **0** 分歧 + **268,026** 次全 `ce` 比较 **0** 分歧 |

**未变的既有数字**：`P0-4` 184,320/0、`P0-5` index2=64 index6=64 index1=61,312 other=0 mismatches=0、`P0-2` 写拍 96/96/0、`P0-7` chr beats total=146556、四条 `P1-11 A12-*`。**合法变化**的只有请求类总数（读臂现在也是请求拍），已在 5.1 的表里逐条标出。

**一个程序布局变化**：`NMI_HANDLER` 从 `$8A10` 移到 `$8B80`，因为 loop B 约 **250** 字节、handler 必须保持连续。这会改变 `P1-6` 与 `PRG …` 打印出来的地址，两者**仍然自洽**。

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
- **P1-1 RATE（2x 速率修正，2026-10-03 新增）**：这个版本的 P1-1 除了那条恒等式 `bus_stall == req && !fire`（任何等待值都满足，所以它本身证明不了速率）之外，还**测量**速率。每两个 `frame_done` 之间数 `ce_ppu`、`ce_cpu`、完成的 `bus_fire`、DMA 占用与 stalled 的 `ce_cpu`，并要求：(a) DMA 没插手的帧里 `ce_ppu == 89342`（= 262×341，而 89342 是 4 `clk` 点周期的整数倍，所以窗口内容与相位无关）、`fires == ce_cpu`、`fires ∈ {89342/3, (89342+1)/3}`；(b) 全部帧里 stalled 的 `ce_cpu` 总数为 0；(c) 逐 `clk` 的**零 stall 不变式**：有请求、`!bus_hold`、`wait_need <= 1` 时必须已经 `bus_fire`。实测：`ce_ppu=89342 ce_cpu=29780 completed bus fires=29780 stalled=0`，`fires/ce_cpu = 1000‰`，逐 `clk` 不变式 88,831 次机会 **0** 次违反。修正前同样的代码读出 `fires=14890`（正好一半）与 44,416 次违反。**零 stall 不变式在 `tb/bus` 里也有一份**，三个 `nes_cpu_bus` 实例各数一遍"机会数/违反数"，其中 `READ_WAIT_CYCLES=1` 那个实例就是 v2..v6 的实际配置。
- **P1-2 OAM DMA 的成本（同样新增）**：`oam_dma_cycle_count` 之前在六个实例上都没接出来，现在接在 `ab_v6` 上并断言落在推导出的区间 `[6145, 6146]`（= `1 + align(1..2) + 256 × (23 clk 读 + 1 clk 写)`）。另外**按拍**数出 OAM DMA 真正占掉的 CPU 周期（`oam_dma_cpu_hold` 为高的那些 `ce_cpu`），实测 **512**，真机预算是 513/514，所以它在预算之内。**已声明的差距**：这个 RTL 把 256 次 `$2004` 写直接打在 PPU 端口上而不走 CPU 总线，于是写不占 CPU 周期；读又要 2 个 `ce_cpu`，因为 DMA 侧的地址和请求在同一个 `clk` 才同时有效、拿不到 CPU 那 11 `clk` 的提前量。两个事实相消得到 512，**这正是 2x 缺陷在这个指标上一直看不出来的原因**：一个正确实现同样会读出 256 + 256 = 512，但理由完全不同。要补上这个差距需要让 DMA 端口先摆地址再提请求，或者让 `nes_oam_dma` 把写走 CPU 总线，两者都不在这次改动的可写范围内。
- **P1-2 OAM DMA**：`$4014` 1 次启动、256 次 ack、256 次 `$2004` 写、**0 次 MMIO 命中**；并且一条 **v6 特有风险**被专门检查——`$2004` 在**外部 CHR 的 PPU** 里仍然落进 `oam_ram`（`oam_ram[0..3] = 11 22 33 44`，256 字节全部与源页相同）。这条如果漏了，"DMA 被 CHR 读抢走"的失败模式会非常难查。
- **P1-3 mirroring**：iNES 头的 horizontal 模式被观测到并被导出，但 `nes_ppu2c02` **没有运行期 mirroring 端口**，两个实例都以 `MIRROR_VERTICAL=0` elaboration——**模式被观测，没有被应用**。
- **P1-4 IRQ 线或**：每个 `clk` 上 `irq_line == (mapper_irq | apu_irq)`、`dbg_irq_pending == irq_line`；NROM 的 `mapper_irq` 与被 `$4017 = $40` 禁止的 `apu_irq_o` 的高电平 clk 数都被记下。
- **P1-5 MMC3 A12 与 `force`**：在 `chr_mmc3` 上——`$C000` 锁存 `0x07`，`$C001` 置 reload 且**一直保持 1**，计数器**仍是 0**（`a12` 滤波器一次都没触发，因为 `mapper_ppu_a12` 在 `nes_system_v6` 里硬绑 0），`$E001` 然后 `$E000` 让 `irq_enabled=0`，`mapper_irq` 在整个程序的每一个 clk 上都是低。然后 `force` 压寄存器，走通 `mapper_irq → irq_line → dbg_irq_pending`，**7 个 `bus_fire` 周期的入口**、`$FFFE` 取向量、handler 把 `ram[0013]` 递增。**`irq_pending_r` 在这一条里是被 force 成 1 的**，所以计数器 → pending 那段逻辑在系统级没有任何真实 RTL 覆盖。
- **P1-11 MMC3 扫描线 IRQ 在建模 A12 刺激下自时钟**（`check_p1_5` 的最后一条语句，**不是**新回归目标）：TB 把一个**建模的** A12 流 force 到生产网 `chr_mmc3.mapper_ppu_a12`（`nes_system_v6.v:302` 那一行**一个字没改**；读臂那一轮之前这一行是 `:259`），并断言它到达 RTL 真正采样的端口 `chr_mmc3.u_mapper.u_mmc3.ppu_a12`。**`irq_pending_r` 在这里从头到尾没有被 force**——2b 里唯一被 force 的是使能位 `irq_enabled_r`，pending 必须由 RTL 从 `irq_counter_next == 0` 产生（`nes_mapper_mmc3.v:193-194`）。四个阶段：**(2a)** IRQ 仍被禁止时计数器就在跑，跨 **482** 个被接受边沿走 7,6,5,4,3,2,1,0、**0** 序列错，`irq_pending` 与 `mapper_irq` 全程 **0** `clk` 为高；**速率核对**每个 `frame_done` 整帧恰好 **241** 次上升、`mmc3_a12_filtered` 接受 **241/241**、最小边沿间隔 **1364 clk** 对 `MMC3_A12_COOLDOWN` 需要的 **3**、高电平窗口在 **241** 条线上都恰好 240 `clk`、21 条 vblank 线上 **0** `clk`；**(2b)** 线在被接受边沿 **496** 拉起 = 使能时记录的边沿序号 **488** + **8**（使能被钉在计数器的 reload 点 `00` 上，所以"恰好 8"成立；免相位的形式 `delta == (c == 0 ? 8 : c)` 作为第二条独立断言也过），随后 **1** 次入口恰好 **7** 个 `bus_fire` 周期、`fffe` 取 **2** 次、PC 停在 `8a30` **24** `clk`、`ram[0013]` `01 → 02`；**(2c)** 在 `irq_pending_r` 仍 1 的情况下把使能位 force 成 0（**只有 RTL 能进入的组合**）→ `mapper_irq` 与 `irq_line` 组合落下，随后释放，生产网与端口**两侧**都读回 0、之后 400 `clk` 滤波器一次没触发。**声明边界**见 `tb/system/README.md` 的"### P1-11"一节：PPU 没有 VRAM 地址总线所以**没有真实 A12**，这个 0 **保持为真**；注入的是**刺激模型**而不是对这块板硬件的预测；**241 是引用的文献值**，不是对真实硬件的测量；依赖精灵的 A12 变化**没有**被建模；**没有**任何真实卡带或 NESdev test ROM 的证据。
- **P1-6 NMI**：`nmi_o == vblank && ppuctrl[7]` 逐 clk 断言。**（读臂那一轮的布局变化）** `NMI_HANDLER` 从 `$8A10` 移到 `$8B80`，因为 loop B 约 250 字节、handler 必须保持连续——所以 `P1-6` 与 `PRG …` 打印出来的地址**变了**，两者**仍然自洽**；具体打印值见 `tb/system/README.md`。
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
3. **`$2007` 读外部 CHR 的字节值是对的**（读臂那一轮新增，5.1.3）：它经过 mapper 翻译（`chr_final_addr` 逐臂核对错 0）、不抬 store enable、不与写 strobe 的捕获沿重合，并且 ab_v5 的内部 `chr_ram` 与 ab_v6 的顶层 128 KiB 阵列对同一批 `$2007` 读给出**逐字节相同**的答案。
4. **不证明任何真实存储器能满足 1 拍寄存读。** TB 的 CHR 模型是零时序代价的。读臂那一轮**还多了一条义务**：仲裁多出来的那一级落在 `chr_addr` 上，而 `chr_addr` 是通往 CHR 地址的**唯一**通路，所以地址建立时间必须按真实 BRAM/SDRAM 的 `tACC` 预算**重新核对**。
5. **不证明渲染开着时帧中 `$2007` CHR 读是安全的。** 把地址放上总线要花掉一个 `ce` 的地址时间，并**可能顶掉一个**在飞的取数字节——一个背景 tile（8 像素里 1 个 pattern 字节）或一个精灵 slot 平面（某一行上的 8 像素），**范围限定在被读的那条扫描线**。在扫描线 240–260 或关渲染时可以证明像素不可见（W3-10 逐臂核对、违例 0）；**扫描线 261 明确不安全**（它的 dot 340 背景取数与 dot 259–290 的精灵预取喂的是第 0 行）。实测有 **107** / 396 个臂真的撞上了在飞的取数（W3-9）。
6. **不证明读写竞争的行为。** 同址同拍的写/读冲突在 TB 模型里是 undefined、建模成 read-first；读臂让这个选择**第一次对程序可见**，而它仍然是一个**建模选择**，必须由真实存储器回答。
7. **不证明硬件行为。** 没有任何综合、Fitter、TimeQuest、引脚或上板证据；本机没有安装 Quartus。`ppu_ext_chr` 端口是纯 RTL 端口，不是引脚。片上 CHR 阵列的 BRAM 推断也没有被验证过。
8. **不证明 MMC3 的 bit 7 bank 编号可用**——`CHR_ADDR_BITS = 17` 把它们截掉了（见 3.4）。
9. **不证明渲染中途写 CHR 是安全的**——读/写仲裁冲突被测量出来了，但没有被修掉，见第 6 节。
10. **不证明 MMC3 扫描线 IRQ 在真实卡带上的任何行为。** P1-11 证明的是"MMC3 计数器 / reload / pending 状态机与 `mapper_irq → irq_line → CPU` 入口链在被喂进一条**形状标准**的建模 A12 流时内部一致"。它**不**证明：(a) `mapper_ppu_a12` 在 RTL 里不再是 0（它仍然是 0，而且 PPU 没有 VRAM 地址总线所以**根本没有真实 A12**）；(b) 注入的模型预测了 `chr_mmc3` 这块板——那块板跑 `PPUCTRL = $00`，真实硬件每帧把计数器时钟 **0** 次；(c) 每帧 241 这个数字——它是 NESdev 的**文献值**，不是对真实硬件的测量；(d) 依赖精灵的 A12 变化——真实硬件上它可以让每条扫描线被时钟多达 4 次，而它**没有**被建模、**也不能**被建模，因为精灵 pattern 地址是 OAM 相关的；(e) 任何真实卡带——没有跑过 MMC3 游戏，也没有跑过 `nes-test-roms/mmc3_irq_tests` 的任何二进制，在 harness 有真实 ROM 装载之前也跑不了。

## 6. v6 明确未实现

以下是被测顶层 `nes_system_v6` 的范围限制，不是 testbench 的缺陷：

- **`$2007` 对外部 CHR 的读已实现，但它会占掉总线上一个取数拍。** 读臂那一轮把这一条从"完全没通"改成了"通了、但有代价"：返回的字节在 mapper 翻译后的地址上永远正确，然而把它放上总线要花掉一个 `ce` 的地址时间，并**可能顶掉一个**在飞的取数字节（一个背景 tile 或一个精灵 slot 平面，限定在那条扫描线）。**渲染开着时帧中 `$2007` CHR 读不宣称安全**，扫描线 261 明确不安全。读臂**不**抬 `mapper_chr_ram_we`、**不**与 `chr_we` 的捕获沿重合（各 0 个臂拍），但它**会**抬 `chr_req`，所以 CHR 存储器合同多了一条义务：**在每一个 `chr_req` 为高的 `ce` 上捕获地址**。失效保护 `chr_rd_armed_q ? chr_rdata : 8'h00` 保留，所以端口没接或读臂漏掉时退化成原来那条**有文档的** `8'h00`。见 5.1.3 与第 8 节。
- **写与取数、以及读臂与取数的仲裁冲突都未修。** `chr_req`（`nes_ppu2c02.v:809`；写通路落地那一轮结束时是 `:709`）**不会**被写抑制，`bg_fetch_due`（`:700`，写通路落地那一轮结束时是 `:604`）也没有扫描线/掩码门控，所以同一个 `ce` 上两者可以同时为高。实测 **96 个写拍里有 22 个**与在飞的背景取数撞上；`bg_pa_enable` 为高时 **0** 个（上传期间 `PPUMASK=$00`）。写优先意味着撞上那一拍取数单元锁存的是写地址的字节——**渲染中途做 `$2007` CHR 写会损坏一个 tile 拍**。**读臂那一侧是同一条隐患的第二个实例**：396 个臂里 **107** 个撞上在飞的取数（背景 71 / 精灵 36）。这两条都是已知限制，**不是**被删掉的检查；风险登记册分别是 L-17 与 L-20。
- **片上没有任何 CHR 存储。** 128 KiB CHR 只存在于 testbench 里。真实系统需要外部存储（SDRAM 或 TF），**而 SDRAM 控制器在仓库里还不存在**，TF 也只有命令帧发送器。选通 `chr_we` 是组合的、不登记，所以下游存储器必须自己按单拍脉冲用；片上 CHR 阵列能否被推断成 BRAM 也没有验证过（无 Quartus/Fitter/STA）。
- **`write_toggle` 与 `read_buffer_reg` 的既有行为未动。** `$2007` 写不清 `write_toggle`，写也不清 `read_buffer_reg`。这是**预先存在**的，且被刻意不动：对称地修任何一边都会改变 PPU 的内部分支并波及 10 个以上回归目标，留给专门的一轮。
- **`mapper_ppu_a12` 仍绑 0**（`nes_system_v6.v:302`；读臂那一轮之前是 `:259`），所以 MMC3 的扫描线 IRQ 计数器在系统级**仍然无法自时钟**，这一点**没有被修**；`chr_final_addr[12]` 已经是 PPU 的 pattern-table 选择位而不是 bank 位，所以它**不能**拿来当 A12 用。**根因不是"忘了接线"**：本 PPU **没有 VRAM 地址总线**，所以根本不存在一个可以接出来的真实 A12（见 5.3 的 P1-11）。
  - **但是**状态机不再是无证据的：TB 的 `check_p1_11` 把一条**建模的** A12 流 force 到那根生产网上，计数器 / reload / `irq_pending_r` 与整条 IRQ 入口链因此**由真实 RTL 产生**而不是被 force。**这条证据的类型必须说清楚**——它是**建模刺激下的内部一致性与已发表时序吻合**，不是硬件预测。`chr_mmc3` 跑 `PPUCTRL = $00`，真实硬件每帧把计数器时钟 **0** 次（那个众所周知的 MMC3 陷阱，也是商业游戏必须用 `$2006` 手动打计数器数扫描线的原因）；**每帧 241 是 NESdev 的文献值，不是实测**；依赖精灵的 A12 变化（真实硬件上每条扫描线可达 4 次）**没有**建模、**也不能**建模。完整声明边界见 `tb/system/README.md` 的"### P1-11"一节。
  - **关掉这个缺口的正确路径**：若将来某次改动给 `nes_ppu2c02` 加上**真实的 VRAM 地址总线**，TB 那个 A12 模型就成为它**逐拍 A/B 的参照对象**，模型对不对就从假设变成可测量的量。**那**才是"真实 A12"这个说法开始站得住的时刻。
  - 仍然没有证据的部分：没有任何 MMC3 卡带被跑过，`nes-test-roms/mmc3_irq_tests` 的任何二进制都没有被跑过，harness 也还没有真实 ROM 装载。
- **`CHR_ADDR_BITS = 17` 截断 MMC3 的 CHR bank bit 7**，`0x80`–`0xFF` 别名到 `0x00`–`0x7F`。已接受，不要加宽（见 3.4）。
- **PPU 没有运行期 nametable-mirroring 端口。** v5/v6 都以 `MIRROR_VERTICAL(1'b0)` elaboration；mapper 的 mirroring 输出被观测但**没有被应用**。四屏的 4 KiB nametable RAM 同样没有。
- **CHR 端口上没有背压。** `chr_req` 是无条件请求，没有 ready/ack；一次背景/精灵请求拍的重叠会**静默丢掉**背景那一拍（取数对取数的碰撞 P0-8 实测 **0** 次，但它成立只因为两个窗口不重叠；写侧与读臂侧的冲突都被**测量**出来了，见上面第二条）。
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

`system-v6` 本机 **约 256 s**（P1-11 加入之后；加入前 **208.4 s**，再早的 `$2007` 写通路那一版是 119.3 s）。多出的约 48 s 全部来自 P1-11 的"每帧恰好 241 个上升沿"核对：它需要一整帧被两个 `frame_done` 边沿夹住，而 force 窗口从帧中间打开，所以等待约 2.0 帧；2b/2c 只额外贡献约 14,500 `clk`。全量里最慢的仍然是 `ppu-ext-chr-tb`（约 434–447 s，占全量的主导份额），其次是 `system-v6`。**本轮只保留了总量、最慢目标与新目标的逐项秒数，第 3 名及以后没有单独留存**，所以本文不重复逐目标表。

**P1-11 没有改动任何 RTL，也没有新增回归目标**：它是 `check_p1_5` 内部的一个 task，**门数仍然是 51**。P1-11 之后 `.\tools\sim_all.ps1 -Mode all` 也重跑过并得到 **`Result: PASS (51 of 51)`、0 FAIL**；上面那个 1401.6 s 的全量墙钟与逐目标秒数是 P1-11 **之前**那一轮的留存记录，**本轮没有单独留存逐目标秒数**，所以全量占比仍以那一轮为准。

**读臂那一轮（最近一轮）**：**目标数仍然是 51**——读臂没有新增回归目标。TB 从 5,817 行长到 **6,597** 行。`system-v6` 本机 **约 259.7 s**（读臂之前 259.1 s，**+0.9%**）；`ppu-ext-chr-tb` **402.7 s**，且 `S3` 七个精灵可观测量全部 `= 0`、`A3 verified request addresses=337450 verified latched plane pairs=126546` ——**逐字节未变**，即读臂的加入也没有让渲染行为漂移。`-Wall` 仍然**恰好 9 条** warning（全部是 `@*` 数组敏感性）、**0 条 dangling**——13 处新的 `.chr_rd_arm(1'b0)` 绑 0 保证没有任何实例把这个输入悬空。**这一轮只跑了 `-Mode system-v6` 与 `ppu-ext-chr-tb`；`-Mode all` 还没有重跑**，上面那个 51/51 与 1401.6 s 属于**更早**那一轮，全量门是下一步。

**本机没有安装 Quartus**，所以这一整套数字只是 Icarus Verilog 下的 RTL/TB 内部一致性；它不构成任何综合、引脚、时序或上板证据。
