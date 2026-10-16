# 卡带 ROM（PRG + CHR）：把两个 `$readmemh` 数组落进 bitstream

本文说明 `rtl/nes_core/cart/nes_cart_rom.v` 的接口合同、时序模型和设计取舍，并回答一个和 `controller.md` 同源的教学问题：

> 一个用 C 写的软件模拟器把 `.nes` 文件 `fread` 进 `uint8_t prg_rom[]` / `uint8_t chr_rom[]`，和一个用 Verilog 写、用 `$readmemh` 把同一份内容在**综合期**灌进 BRAM 的模块，究竟是不是同一套行为的两种写法？

结论：**"CPU/PPU 看到的字节序列"完全相同；"这些字节什么时候、从哪里进入硬件"完全不同。** 软件模拟器的 ROM 是运行期从文件系统读进来的，重启程序就能换卡带；本模块的 ROM 内容**就是 bitstream 的一部分**，换卡带要重新综合。`nes_cart_rom.v` 实现的是后者，而且它是整个设计里**唯一**承载卡带内容的地方。

行为权威是 NESdev 的卡带/映射器章节和 iNES 格式说明；`.slim/clonedeps/repos/` 下的克隆仓库只作为"别人怎么建模"的观察，不作为规格。以下所有事实以 `nes_cart_rom.v` 的文件头注释为准，逐条对应到源码。

---

## 1. 为什么 ROM 必须进 bitstream

Zynq 板上 **TF 卡和 QSPI flash 挂在 PS 的 MIO 引脚上，PL 够不着**。PL 没有卡带读取通路，没有 boot loader，也没有任何运行期"从外部把 bytes 读进 ROM 数组"的机制。所以：

- **不在 bitstream 里的 ROM，就是 PL 看不见的 ROM。**
- 仓库里长期只有合成的占位数据（`prg_placeholder.hex` / `chr_placeholder.hex`），它们是确定性的可复现内容，不是某个具体游戏。

这条约束也解释了为什么本模块要负责"内容从哪来"：它是设计里唯一的字节来源。像 `ines_header_parser.v` 这种模块**不进 bitstream**——它只被自己的 testbench 例化，`header` 还是一个 128 bit **输入**端口，就算接上也仍然要有人把 16 字节喂给它。详见 `docs/tools/nes2hex.md` 第 4 节。

---

## 2. 一个模块，不是两个；谁例化哪一半

PRG 和 CHR 是**两个数组、两种端口形状**，但本模块把它们放在一起。理由（文件头原话）：

1. 它们共享**同一个时钟、同一个复位、同一套文件初始化惯用法、同一个"内容从哪来"的答案**。拆成两个模块只会把初始化惯用法复制一遍，并让板级集成者手里多一份要保持一致的参数。
2. 它们**从不被一起使用、也不仲裁**：PRG 是 CPU 侧一 clk 寄存读，CHR 是 PPU 外部总线上被 `ce_ppu` 门控的读/写。

关键点在于**层次**：两个一半分别由不同层例化，因为 Verilog 的层次化引用**只能向下**。

| 一半 | 例化者 | 参数 | 位置 |
| --- | --- | --- | --- |
| PRG | `nes_system_v6`（`u_prg_rom`） | `PRG_ENABLE=1`, `CHR_ENABLE=0` | `nes_system_v6.v:556-576` |
| CHR | 平台顶层 `nes_zynq_top`（`u_cart_chr`） | `PRG_ENABLE=0`, `CHR_ENABLE=1` | `nes_zynq_top.v:606-624` |

为什么 PRG 必须**在核内**例化：`prg_rom` 曾经在 `nes_system_v6` 里声明却没有任何驱动，Vivado 于是把它**溶解掉**（日志 `Synth 8-3848`），贡献 0 逻辑、0 存储；而"从父层去驱动子层的数组"在 Verilog 里不可行，因为层次化引用只能指向下方。核内自己例化并读 `prg_rdata` 才是唯一出路。CHR 相反：`chr_rdata` 已经是核的一个**输入端口**，核只把它透出去，所以 CHR 一半可以坐在核**上方**，由平台顶层提供。

`nes_zynq_top.v:150-161` 明确记着这条分工，并强调 **`ce_ppu` 必须原样使用**，不能在顶层重新生成 `div_phase`：本模块的 CHR 读通路是相位敏感的，一个 1~3 拍错位的 enable 会**悄悄返回上一拍的图案字节**而不报任何错。

---

## 3. 端口合同

```verilog
module nes_cart_rom #(
    parameter integer PRG_SIZE_BYTES = 131072,
    parameter integer PRG_ADDR_BITS  = 17,
    parameter integer PRG_ENABLE     = 1,
    parameter integer CHR_ENABLE     = 1,
    parameter integer CHR_SIZE_BYTES = 8192,
    parameter integer CHR_LOCAL_BITS = 13,
    parameter integer CHR_ADDR_BITS  = 17,
    parameter PRG_INIT_FILE = "rtl/nes_core/cart/prg_placeholder.hex",
    parameter CHR_INIT_FILE = "rtl/nes_core/cart/chr_placeholder.hex"
)(...);
```

| 信号 | 方向 | 合同 |
| --- | --- | --- |
| `clk` | in | 核时钟 21.477272727 MHz。本模块不产生也不消费 `ce`，只对端口给的电平取样。 |
| `reset` | in | 高有效**同步**复位。只清两个输出寄存器，见第 4 节。 |
| `prg_en` | in | PRG 读使能。为低时 `prg_rdata` **保持**上一个字节（不是返回 0）；因此只有在地址也被保持的地方才安全地用它门控（省动态功耗）。 |
| `prg_addr` | in | `[PRG_ADDR_BITS-1:0]` = 17 位。核内由 `mapper_prg_bank_offset` 驱动，正好是同一宽度。 |
| `prg_rdata` | out | `[7:0]`，**一 clk 寄存读**。 |
| `ce_ppu` | in | PPU dot 使能，核导出的那一个。CHR 读的唯一门控。 |
| `chr_req` | in | CHR 读请求，是 `chr_addr` 有效的**唯一限定**（总线在 beat 之外地址是陈旧的）。 |
| `chr_addr` | in | `[CHR_ADDR_BITS-1:0]` = 17 位，mapper 翻译后的 `chr_final_addr`。 |
| `chr_rdata` | out | `[7:0]`，在 **`ce_ppu` 沿**寄存。 |
| `chr_waddr` | in | `[13:0]`，`$2007` 写地址（PPU **自增前**的 `v_addr[13:0]`）。 |
| `chr_we` | in | 一 clk 宽的 `$2007` 写 strobe。 |
| `chr_wdata` | in | `$2007` 写数据。 |
| `chr_ram_enable` | in | 核的 `mapper_chr_ram_enable`。写只有在它为高时才真正到达数组。 |

注意：`chr_rdata` 是核的**输入**，`chr_req`/`chr_addr`（=`chr_final_addr`）/`chr_waddr`/`chr_we`/`chr_wdata` 是核的**输出**。上层把核的输出接进本模块、把本模块的 `chr_rdata` 接回核的输入即可，**`nes_system_v6` 一行都不用改**。这条总线是**单主多路复用**的：谁赢了 `chr_req`，谁就是那一拍把地址放上 `chr_addr` 的人，本模块没有仲裁要做。

---

## 4. BRAM 初始化惯用法：`$readmemh` + `initial`，以及为什么不能复位数组

两个数组各由一条 `initial` 在时间 0 灌入口：

```verilog
reg [7:0] prg_rom [0:PRG_SIZE_BYTES-1];
initial
    $readmemh(PRG_INIT_FILE, prg_rom);
```

这是可综合 BRAM 初始化的标准惯用法：综合工具把它转成 BRAM 的 INIT 内容，于是 ROM 内容**就是 bitstream**。

三条必读的性质：

1. **复位清不掉数组。** 复位是同步的，只把 `prg_rdata` / `chr_rdata` 置 `8'h00`。数组内容在 bitstream 里，逻辑根本无法在运行期改变它——这不是"没做"，是"做不到"，也是"不需要"：真实卡带 ROM 同样是只读、上电即在。
2. **`$readmemh` 给的条目少于数组深度时，剩下的在 fabric 里是未定义的。** 所以主机侧**必须**把镜像补满到完整声明深度（用 `00`）。一个 16 KiB 游戏在 128 KiB 数组里是 87.5% 填充，这是预期结果。见 `docs/tools/nes2hex.md` 第 7 节。
3. **找不到文件、或文件长度不对时，Vivado 会静默把数组优化掉。** `nes_zynq_top.v:244-251` 记着这条：Block RAM Tile 数会从 50 掉到 **0**，而设计仍然过时序、仍然落位全部引脚——一份"看起来完美但不携带卡带"的 bitstream。对应的检查是 `report_utilization` 报 50 个 Block RAM Tile 而不是 0。

---

## 5. PRG 通路：一 clk 寄存读，靠地址稳定 12 clk 换正确字节

核是这样读 PRG 的：

```verilog
assign prg_readback = prg_rom[prg_index];                       // 组合
assign cart_din = (cart_addr[15] == 1'b1) ? prg_rom[prg_index] : 8'h00;
```

看起来是**组合读**，而块 RAM 有一 clk 读延迟，回答不了一个组合读。但它**不需要**回答：

- `mapper_prg_bank_offset` 是 `nes_cpu6502` 的 `bus_addr` 的 `always @*` 函数，`bus_addr` 只在 `ce_cpu` 为高（每 12 clk 一次的 posedge）时才动。
- 所以 PRG 地址在 `div_phase 1..11` 加上接下来的 `div_phase 0` 共 **12 clk 内完全不动**。
- CPU 在"前沿 `div_phase == 0`"的那个 posedge 锁存 `bus_din`，于是它取到的正是本模块**早一 clk**、在**同一个地址**上寄存下来的字节。

映射器的总线冲突比较同理安全：`mapper_we` 是寄存过的 `cart_wr_pending_q`，与锁存过的 `cart_wr_addr_q` 在同一拍为高，而写本身要到**下一个** posedge 才到达 `bank_select`——比较与读取之间地址没有移动。

`prg_en` 只为功耗存在：为低时 `prg_rdata` **保持**而不返回 0，所以只能在地址也被保持的地方门控它。

---

## 6. CHR 读延迟合同：逐 clk 讲清 arm / consume，以及为什么必须 `ce_ppu` 门控

这条是本模块最不能破的合同，也是全文重点。`nes_ppu2c02.v` 的文件头声明：

```text
v_addr -> chr_addr -> mapper -> chr_final_addr -> CHR memory -> chr_rdata
```

这条链**零余量**：`chr_rdata` 在每个 `ce_ppu` 沿被寄存，链中任何位置插一级寄存器都**不会报错**，只会**静默返回上一个图案字节**。下面是可审计的算术：

- `clk` = 21.477272727 MHz，`div_phase` 跑 0..11，每 clk 自增一次。
- `ce_ppu = (div_phase[1:0] == 2'b00)`，所以 `ce_ppu` 在 **`div_phase` 0、4、8** 时为高：一个 PPU dot 是 4 clk，12 clk 里 enable 高 3 次。`ce` **沿**是"结束 `div_phase` 0 / 4 / 8"的那三个 posedge。
- **arm**：`nes_system_v6` 在"前沿 `div_phase == 8`"的**那一 clk** 抬 `ppu_chr_rd_arm`，于是 `div_phase 8` 期间 `chr_req` 为高、`chr_addr` 携带 `v_addr[13:0]`。`div_phase 8` 本身就是一个 `ce_ppu` beat。
- **本模块**：在那个沿锁存 `chr_addr`，于是从 `div_phase 9` 开始 `chr_rdata` 就保持 `chr_rom[chr_addr[12:0]]`。
- **consume**：PPU 的读缓冲在 arm 之后的**下一个 `ce` 沿**被装载，也就是"结束**下一个 dot** 的 `div_phase 0`"的那个沿——因为 arm 沿与它之间隔着 `div_phase 9, 10, 11, 0`。
- **窗口**：从地址在 `div_phase 8` 上总线，到 `div_phase 0` 沿的 consume，是 **5 个 clk**（8、9、10、11、0）；读本身只花 **1** 个 clk（arm 沿）；**余量 4 个 clk = 186 ns**，而且字节在这整段窗口里**一直保持**，因为 `div_phase 9` 到 consume 之间没有任何东西重新锁存它。

**为什么读必须门控在 `ce_ppu`、而不是 `clk`：** 一个每 `clk` 都读的版本会在 `div_phase 9` 末尾**再次**锁存 `chr_addr`——那时取数单元（它们在每个 `ce` 沿寄存自己的 `chr_addr`）已经把某个取数地址放上了总线——于是会在 CPU 消费前 **3 clk** 用取数字节覆盖掉已 arm 的字节。这就是**陈旧字节失败模式，而且没有任何东西会报告它**。

门控在 `ce_ppu && chr_req` 还尊重了总线的两条已记录性质：

- `chr_addr` 在 beat 之外是陈旧的，所以 `chr_req` 是地址的**唯一**限定。
- 当一个 `$2007` arm 紧挨着一个取数 beat 时，`chr_req` **可以连续两个 `ce` 为高**，两个 beat 都要被服务，各自返回各自地址的字节。

实现就是一行：

```verilog
if (ce_ppu && chr_req)
    chr_rdata <= chr_rom[chr_rindex];
```

---

## 7. `PRG_ENABLE` / `CHR_ENABLE`：避免 CHR hex 被读两遍

板子在上方例化本模块一次、两个一半都开；核在内部再例化一次，只开 PRG。若没有这两个开关，核的实例会**再建一份 8 KiB CHR 数组并再 `$readmemh` 一遍**——CHR hex 被读两次、多推断出 8 KiB 内容。

生成块的做法是：**被关掉的那一半，数组根本不声明**（它在 `generate` 里面），所以任何东西都无法推断它；同时那一半的输出寄存器**仍然被驱动**，只在复位下驱动，因此没有任何输出会悬空。

```verilog
if (PRG_ENABLE != 0) begin : g_prg
    reg [7:0] prg_rom [0:PRG_SIZE_BYTES-1];
    ...
end else begin : g_prg_off
    always @(posedge clk) if (reset) prg_rdata <= 8'h00;
end
```

CHR 一半同理（`g_chr` / `g_chr_off`）。核的实例把 PRG 之外的 CHR 端口全部接常量（`ce_ppu(1'b0)`、`chr_req(1'b0)`……），见 `nes_system_v6.v:568-575`。

---

## 8. 尺寸与别名：`[12:0]` 精确、`[16:13]` 是接受的别名

参数与调用方的不变量：

- `PRG_SIZE_BYTES = 131072`（128 KiB），`PRG_ADDR_BITS = 17`。调用方保证 `1 << PRG_ADDR_BITS == PRG_SIZE_BYTES`，这正是防止 `prg_addr` 越界索引的原因。这两个数**照抄** `nes_system_v6` 自己的参数，而不是用 `$clog2` 派生——因为 `$clog2` 是 Verilog-2005，而本文件要在 `-g2001` 和 `-g2012` 下都能编译。
- `CHR_SIZE_BYTES = 8192`（8 KiB），`CHR_LOCAL_BITS = 13`。mapper 翻译出的 17 位 `chr_final_addr` 只用 `[12:0]` 索引，**高于 bit 12 的 bank 位全部被丢弃**。

这对谁精确、对谁是别名：

| 卡带 | CHR 大小 | `[12:0]` 索引的结果 |
| --- | --- | --- |
| NROM / UxROM | 8 KiB | **精确** |
| CNROM | 32 KiB | 别名，bank 折到 0..7 |
| MMC1 | 至多 64 KiB | 别名 |
| MMC3 | 至多 64 KiB | 别名 |

这和 `nes_system_v6` 已经记录的 MMC3 CHR bank bit 7 在 `CHR_ADDR_BITS = 17` 上被截断是**同一类已接受限制**。加宽的办法就是抬高 `CHR_LOCAL_BITS` 和 `CHR_SIZE_BYTES`——**纯粹是改参数**。testbench **显式断言**了这个别名，而不是把它留给意外。

---

## 9. CHR-RAM vs CHR-ROM 的写语义

CHR 总线的写半边是 `chr_waddr` / `chr_we` / `chr_wdata`，**只有在 `chr_ram_enable` 为高时才被承认**：

```verilog
if (chr_ram_enable && chr_we)
    chr_rom[chr_windex] <= chr_wdata;
```

`chr_ram_enable` 就是核的 `mapper_chr_ram_enable`。核侧 `mapper_chr_ram_we`（`nes_mapper.v:221`）= `chr_ram_enable && ppu_we && (ppu_addr[13] == 1'b0)`，本模块实现的 `chr_ram_enable && chr_we` 就是这个表达式（`ppu_we == chr_we`，`ppu_addr == chr_waddr`）。`ppu_addr[13] == 0` 这一项已被隐含：`chr_waddr` 只在 PPU 的 `v_addr < $2000` 保护下才有意义，它强制 `v_addr[14:13] == 0`。

两条后果：

- `chr_ram_enable` 为高（CHR-RAM 卡带）：`$2007` 写会真正进入数组，写位置是 `chr_windex = chr_waddr[12:0]`。
- `chr_ram_enable` 为低（CHR-ROM 卡带）：写**不只是**在总线口被丢掉，它**根本到不了数组**。所以 CHR ROM 无法被 `$2007` 写改变，内容**永远是 `$readmemh` 放进去的东西**。

写数据落在低 13 位，所以在别名意义下**每个 bank 都会看到同一个字节**——testbench 对此也断言了。

---

## 10. 主机侧：`tools/nes2hex.ps1`

`tools/nes2hex.ps1` 把 iNES `.nes` 转成本模块需要的两个 `$readmemh` 镜像，**不改任何 RTL**，输出是纯 ASCII hex。要点（完整见 `docs/tools/nes2hex.md`）：

- 头**被剥掉**，镜像是**纯 PRG / 纯 CHR**，不含 16 字节 iNES 头、不含 512 字节 trainer。`prg_rom[0]` 必须是 `$8000` 处取到的字节，不是头字节 `0x4E`。
- 输出**总是补满到完整深度**（PRG 131072 字、CHR 8192 字），因为短 `$readmemh` 会留下未定义内容。
- CHR ROM 超过 8 KiB 时**只输出前 8192 字节并警告、不拒绝**，这是在配合第 8 节的别名限制；PRG 超过深度则**一律拒绝**，因为它按 bank 索引，截尾会改变每个 CPU 窗口读的是哪个 bank。
- 任一项校验失败都**在打开任何输出文件之前**退出（码 2），不留半截文件。

注意换 ROM 等于换 elaboration 期参数（`MAPPER_SELECT`、`PRG_SIZE_BYTES`、各 `*_CHR_RAM`……），**必须重新综合并重出 bitstream**。

---

## 11. 明确未实现 / 未建模

- **没有卡带读取通路。** 没有 TF/QSPI/外部 ROM 的运行期装载，PL 够不着那些引脚。ROM 内容 = bitstream。
- **没有动态换 ROM。** `PRG_SIZE_BYTES`、`CHR_LOCAL_BITS`、mapper 参数都是 elaboration 期常量，一个实例整场只有一份深度、一个 mapper。
- **没有综合/时序证据（除 XDC 约束外）。** 本模块**没有**专属的时序约束或上板测量；`nes_zynq_top.xdc` 里没有任何针对本模块的 `set_input_delay`/`set_output_delay` 或 dedicated 约束，只有通用的时钟定义（`sys_clk` / `lcd_clk`，`core_clk` 由 MMCM 派生，见 XDC 注释）。第 6 节的 186 ns 余量是**算术**，不是实测。
- **容量与 EP4CE10 资源的关系（M9K 预算）。** 两个数组合计 `131072 + 8192 = 139264` 字节 = `1,114,112` bit，而 EP4CE10 整片片上存储只有 **46 块 M9K / 423,936 bit / 约 52,992 byte**（见 `docs/hardware/00-index.md:106`、`docs/hardware/04-memory-and-fifo.md:7`）。**卡带 ROM 本身就约等于整片器件片上存储的 2.6 倍**，所以在这颗器件上 ROM 无法与设计其余部分共存于 M9K——本模块的容量假设站在 Zynq-7020 目标上。Zynq 侧实测占用是 **50 个 RAMB36E1 tile**（`docs/ppu_chr_external_write.md:253`）。
- **testbench 未覆盖：** 未用真实 `nes_cpu_bus` 驱动；未与 PPU 端到端联通真实取数流水线；`PRG_ADDR_BITS` 非 `$clog2(PRG_SIZE_BYTES)` 的非法组合没有专门的失败断言（那是调用方的不变量）。

---

## 12. 证据入口

本模块由 `tb/cart/tb_nes_cart_rom.v` 把关，`tools/sim_all.ps1` 里的目标 id 是 **`cart-rom-tb`**（`tools/sim_all.ps1:483-490`，Group `cart`）。该 testbench 复刻了 `nes_system_v6` 的 `clk / div_phase / ce_ppu` 生成器（不自己另定 PPU dot），断言了：

- **复位内容**：两个输出在复位期间读 `8'h00`，期间的请求不被服务。
- **PRG**：对**全部 131072 个地址**逐拍扫描并与 bench 自读的同一份 hex 模型比对；一个"零建立时间看不出变化"的演示，证明读是寄存的、不是组合的；`prg_en` 保持与释放两种情况。
- **CHR**：对全部 8192 个地址按 `ce` beat 扫描一遍，再用一个与 8192 互质的步长扫第二遍；`$2007` arm 在 `div_phase 8`、consume 在 `div_phase 0`；**每个 beat** 断言 `consume_phase == (arm_phase + 4) mod 12`；连续两个 `ce` beat；一个落在上一 beat 窗口内**单个非 `ce` clk** 的请求必须被完全忽略；bank 位别名；`chr_ram_enable` 为 0（忽略）与 1（服务）的写；跨帧边界的读。
- **模型的性质**：非未定义、无相邻相等字节、两个 64 KiB PRG bank 不相同——这些性质正是让"一 clk 偏斜"可被检测的前提。

运行仓库根目录下的 `.\tools\sim_all.ps1 -Mode all` 是权威门；`cart-rom-tb` 必须 PASS。
