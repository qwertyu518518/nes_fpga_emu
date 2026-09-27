# iNES/NES2.0 头解析（`ines_header_parser`）：从软件 loader 的 `fread` 到硬件配置寄存器

本文说明 `rtl/nes_core/cart/ines_header_parser.v` 的接口合同、字段映射、格式判定规则、容量算术的位宽账、字节索引 FSM 的时序账，并回答一个和 `oam-dma.md` 同源的教学问题：

> 一个用 C 写的软件模拟器（一次 `fread` 加一次位运算）和一个用 Verilog 写的硬件实现（一个 16 拍的字节索引 FSM 加一组配置寄存器），究竟是不是**同一套行为的两种写法**？

结论：**字段含义和容量算术是同一套行为；"谁在什么时候把第几个字节搬到哪"完全不是。** 软件模拟器里 `fread` 一次拿到 16 个字节、位运算立刻出结果、不需要时钟、不需要握手；硬件必须真的一个字节一个字节地把头搬进寄存器，必须真的有一个"搬完了没有"的握手，而且必须真的用外部传入的文件长度去做边界检查。`ines_header_parser.v` 实现的是后者。

行为权威是 NESdev 的 iNES / NES 2.0 文件格式说明。参考的克隆仓库只作为"别人怎么实现"的观察：

```text
.slim/clonedeps/repos/caseif__cNES/src/loader.c       load_rom() 的 fread/magic/flag6/flag7/flag8..flag12 解析
.slim/clonedeps/repos/ObaraEmmanuel__NES/src/mappers/mapper.c  load_data() 的 "NES\x1A" 识别与 INES/NES2/ARCHAIC_INES 判定
```

`[源码观察]` 标记的内容只是这两个仓库的写法，不是规格；本文没有用任何"看起来像规格"的措辞描述它们。

---

## 1. 模块边界

`ines_header_parser` 只做**一件事**：把 16 个字节的 ROM 头变成一组配置寄存器。它不读文件、不搬 PRG/CHR 数据、不持有 ROM、不驱动 mapper。

| 归本模块 | 不归本模块 |
| --- | --- |
| 16 字节头的搬运与锁存 | 文件 I/O（`fread`/`fseek`/`ftell`）、SD/TF/SPI Flash 读时序 |
| magic、格式位、mapper ID、submapper 的判定 | mapper 的创建与 bank 译码（`nes_mapper`） |
| PRG/CHR 容量（字节）换算 | PRG/CHR 数据搬进 SDRAM/BRAM 的搬运引擎 |
| trainer 标志与它造成的 512 字节偏移 | trainer **内容**的解释（它是真实的 256×16 bit 图形数据） |
| battery/four-screen/mirroring/timing 标志 | NVRAM 的持久化介质（`sram.bin` 之类） |
| `expected_size` 与外部 `actual_size` 的比较 | 文件尾部的额外数据（padding、存档快照等） |

这个边界和 `docs/nes-study/03-ines-format.md` 第 13.1 节"文件加载器属于仿真/平台侧，不属于每个 CPU cycle 的核心逻辑"一致，也和本仓库 `rtl/nes_core/` 不含任何文件 I/O 逻辑的事实一致。

---

## 2. 接口合同

### 2.1 输入

| 信号 | 方向 | 语义 |
| --- | --- | --- |
| `clk` / `reset` | in | `reset` **异步**高有效，把状态机和全部输出寄存器清零。 |
| `start` | in | 1 拍脉冲。`ST_IDLE` 采样到它就开始一次解析；`busy` 期间再拉高**被忽略**（见第 5 节）。 |
| `header[127:0]` | in | 16 字节头。**字节 0 在最低位**：`header[8*i +: 8]` 是文件偏移 `i`。`start` 之后 16 拍内必须保持稳定（见第 5.1 节）。 |
| `actual_size[31:0]` | in | 文件真实字节数，由外部（`ftell`、SD 卡目录项、Flash 长度表）算出来传进来。模块**不**去读文件，所以长度检查只能靠这个输入。 |

`header` 的字节序约定值得强调：RTL 里 `header[7:0] == 8'h4E`、`header[31:24] == 8'h1A`，也就是说**这个 128 位字是"字节 0 在低位"的**，和"把 16 个字节拼成一个十六进制字"的直觉相反。`tb_ines_header_parser` 用 `load_ines(b0..b7, tail)` 任务显式按 `{tail, b7, ..., b0}` 拼装就是为了让这一点在测试里不可误读。

### 2.2 输出

| 信号 | 位宽 | 语义 |
| --- | --- | --- |
| `busy` | 1 | 一次解析正在进行（`state != ST_IDLE`）。 |
| `done` | 1 | **1 拍脉冲**，译码那一拍为高；所有输出寄存器在它之后的沿生效。 |
| `valid` | 1 | `error == ERR_NONE`。为 0 时除了 `error` 和 `dbg_*`，其余字段内容不可信。 |
| `error` | 4 | 见第 6 节的错误码表与优先级。 |
| `nes2` | 1 | 按 NES 2.0 解析（`byte7[3:2] == 2'b10`）。 |
| `dirty_ines` | 1 | 非 NES2 但也不是 clean iNES（"archaic / dirty iNES"），见第 4.3 节。 |
| `mapper_id` | 12 | `{byte8[3:0], byte7[7:4], byte6[7:4]}`（NES2）或 `{4'b0, byte7[7:4], byte6[7:4]}`（clean iNES）或 `{8'b0, byte6[7:4]}`（dirty 掩码后）。 |
| `submapper_id` | 4 | NES2 的 `byte8[7:4]`；非 NES2 恒为 0。 |
| `prg_size_bytes` | 26 | `prg_blocks * 16384`。 |
| `chr_size_bytes` | 26 | `chr_blocks * 8192`。为 0 表示"用 CHR RAM"，不是"没有 CHR"。 |
| `mirroring` | 2 | `00` = horizontal，`01` = vertical。`four_screen` 单独一路输出，不折叠进这里。 |
| `four_screen` / `trainer` / `battery` | 1 | `byte6[3]` / `byte6[2]` / `byte6[1]`。 |
| `prg_ram_shift` / `chr_ram_shift` | 4 | NES2 的 `byte10[3:0]` / `byte11[3:0]`，容量是 `64 << shift`。非 NES2 用参数 `INES_DEFAULT_RAM_SHIFT`（默认 7，即 8 KiB）。 |
| `cpu_ppu_timing` | 2 | NES2 的 `byte12[1:0]`。非 NES2 恒为 0。 |
| `prg_rom_exponent` / `chr_rom_exponent` | 1 | NES2 的 `byte9[7:4] != 0` / `byte9[3:2] != 0`，即 ×2/×3 倍率标记。 |
| `prg_ram_exponent` / `chr_ram_exponent` | 1 | NES2 的 `byte10[7:6] != 0` / `byte11[7:6] != 0`。 |
| `expected_size` | 28 | `16 + (trainer ? 512 : 0) + prg_size_bytes + chr_size_bytes`。 |
| `size_trailing` | 1 | `actual_size > expected_size`：**不**是错误，只是文件尾部有多余数据。 |
| `dbg_byte_index` | 4 | 当前字节索引，取字节阶段可见。 |
| `dbg_header` | 128 | 锁存下来的原始头，**不受 magic 失败清零**，供诊断。 |

### 2.3 输出保持合同

所有输出寄存器只在 `done` 那一拍更新，之后一直保持到下一次 `done`。因此：

- `start` 之后、下一次 `done` 之前，`valid`/`mapper_id`/`prg_size_bytes` 仍然是**上一次**解析的结果；
- 复位是唯一的清零手段。

这条合同让集成层可以把 `done` 当作"配置寄存器组已更新"的唯一事件，其余逻辑不需要关心解析过程的中间状态。

---

## 3. 字段位图到硬件信号的映射

```text
byte   bit    字段                     硬件信号
0..3   -      magic 4E 45 53 1A        只进 error 判定，不外露
4      -      PRG ROM 16 KiB 块数      prg_size_bytes（NES2 时被 byte9[3:0] 扩展）
5      -      CHR ROM 8 KiB 块数       chr_size_bytes（NES2 时被 byte9[7:4] 扩展）
6      0      mirroring                mirroring[0]
6      1      battery                 battery
6      2      trainer                 trainer + expected_size 的 +512
6      3      four screen             four_screen
6      7:4   mapper 低四位           mapper_id[3:0]
7      3:2    格式标识                 nes2 / dirty_ines / clean iNES
7      7:4    mapper 高四位           mapper_id[7:4]
8      3:0    mapper 最高四位          mapper_id[11:8]（仅 NES2）
8      7:4    submapper               submapper_id（仅 NES2）
9      3:0    PRG ROM size MSB         prg_size_bytes（仅 NES2）
9      2:3    CHR ROM 倍率标记        chr_rom_exponent（仅 NES2）
9      4:7    CHR ROM size MSB / PRG 倍率标记  chr_size_bytes / prg_rom_exponent
10     3:0    PRG RAM shift           prg_ram_shift（仅 NES2）
10     6:7    PRG RAM 倍率标记        prg_ram_exponent（仅 NES2）
11     3:0    CHR RAM shift           chr_ram_shift（仅 NES2）
11     6:7    CHR RAM 倍率标记        chr_ram_exponent（仅 NES2）
12     1:0    CPU/PPU timing          cpu_ppu_timing（仅 NES2）
12..15 -      其余扩展位              不解释，保留在 dbg_header
```

`[格式观察]` `byte7[6:7]` 的 VS Unisystem / PlayChoice、`byte7[1:0]`、以及 NES 2.0 里 byte 12 的高位和 byte 13–15，本模块**都不解释**。这是有意的：`docs/nes-study/03-ines-format.md` 第 6 节已经指出这些位"不要默认为全零，保留原始值供诊断"，而它们对本仓库当前支持的 mapper（NROM/UxROM/CNROM/MMC1/MMC3）没有行为影响。原始值随时可以从 `dbg_header` 读出来。

---

## 4. 格式判定

### 4.1 magic

`byte0..3` 必须是 `4E 45 53 1A`。RTL 写成四个独立的字节比较而不是一个 32 位比较——这不是风格问题：`32'h4E45531A` 这个常数的 bit 顺序和"字节 0 在低位"的约定正好相反（`header[31:0]` 的值是 `32'h1A53454E`），写成一次比较时非常容易把首字节写反。本文初版就踩了这个坑，testbench 当时是整屏 `error==1` 才把它暴露出来的。

magic 失败时 `keep_d = 0`，**所有解析出来的字段一律清零**，但 `error` 和 `dbg_header` 保留：这是"头不可信就不要外给出错容量"的具体实现，也是 `docs/nes-study/03-ines-format.md` 第 12 节误区 10 的直接对策。

### 4.2 NES2 检测

```verilog
nes2_d = (byte7[3:2] == 2'b10);
```

注意判据的**值**是 `2'b10` 不是 `2'b01`：掩码是 `byte7 & 0x0C == 0x08`，而 `0x08` 在 bit3:2 上就是 `2'b10`。

`[源码观察]` cNES 用位域 `unsigned int nes2:2` 放在 byte 7 的 bit3–2 并判 `flag7.nes2 == 2`；Obara 用 `header[7] & 0x0C` 判 `== 0x08`。两者与本模块一致。

### 4.3 clean iNES 与 dirty iNES 掩码

```verilog
clean_ines_d = (byte7[3:2] == 2'b00) && (byte12..15 == 0);
dirty_d      = !nes2_d && !clean_ines_d;
```

三种判定的后果：

| 判定 | mapper ID | byte8–15 的用途 | RAM shift | `valid` |
| --- | --- | --- | --- | --- |
| NES 2.0 | `{byte8[3:0], byte7[7:4], byte6[7:4]}` | NES 2.0 扩展字段 | `byte10/11[3:0]` | 取决于其它检查 |
| clean iNES | `{4'b0, byte7[7:4], byte6[7:4]}` | 不用 | 参数默认值 | 取决于其它检查 |
| dirty iNES | `{8'b0, byte6[7:4]}` | 不用 | 参数默认值 | 取决于其它检查 |

**"掩码"到底掩掉了什么**，这是本模块最需要讲清楚的一条：`byte7` 的 bit7–4 在 iNES 里的正式含义是 mapper 高四位，但大量早期 dump（以及一些 mapper 自己写坏的头）把这半个字节挪作他用，常见的就是 `byte7` 的 bit3–2 里躺着 `2'b01` 或 `2'b11` 这种既不是 `00` 也不是 NES 2.0 标识的值。把这种头当 clean iNES 解，就会把 `byte7[7:4]` 当成 mapper 高四位读出一个完全错误的 mapper ID（例如 `byte7 = 0xF4` 会被读成 mapper 0xF4 而不是 0x4）。因此 dirty 路径**只信 `byte6[7:4]`**。

`[源码观察]` Obara 的 `load_data()` 正是这个形状：

```c
uint8_t mapnum = header[7] & 0x0C;
if (mapnum == 0x08) { mapper->format = NES2; }
...
if (mapnum == 0x00 && last_4_zeros) { mapper->format = INES; }
else if (mapnum == 0x04)             { mapper->format = ARCHAIC_INES; }
else if (mapnum != 0x08)             { mapper->format = ARCHAIC_INES; }

mapper->mapper_num = (header[6] & 0xF0) >> 4;
if (mapper->format == INES)  { mapper->mapper_num |= header[7] & 0xF0; ... }
if (mapper->format == NES2)  { mapper->mapper_num |= header[7] & 0xF0;
                               mapper->mapper_num |= ((header[8] & 0xf) << 8); ... }
```

注意 `mapper_num |= header[7] & 0xF0` **只出现在 INES 和 NES2 两个分支里**，ARCHAIC_INES 分支没有这一句——掩码就是这样实现的：不是"报错拒绝"，而是"降级到只信一半的字段"。

这条规则是**兼容策略，不是规格**。NESdev 的 iNES 规范说 byte 7 的 bit3–2 是保留位、bit4–7 是 mapper 高四位；现实文件里保留位不总是 0。本模块的选择是：保留位非 0 时**接受文件**（`valid` 可以是 1）但**降级解析**（`dirty_ines = 1`），让上层决定要不要在诊断信息里提示用户。

### 4.4 exponent notation 标记

NES 2.0 的 `byte9` 用同一组 bit 表达两件事：`byte9[3:0]` 是 PRG ROM size 的高位、`byte9[7:4]` 是 CHR ROM size 的高位；而 ×2/×3 的倍率标记分别占 `byte9[3:2]`（CHR）和 `byte9[7:4]`（PRG）。本模块按常见实现判"非零即倍率"：

```text
prg_rom_exponent = nes2 && (byte9[7:4] != 0)
chr_rom_exponent = nes2 && (byte9[3:2] != 0)
```

因为容量算术（`blocks << 14` / `blocks << 13`）隐含"倍率是 1"，所以任何一个倍率标记成立就报 `ERR_EXPONENT`，**`valid = 0`**：宁可不认，也不给出一个乘错的容量。

`[格式观察]` 这个判据有一个无法回避的后果：`byte9[7:4]` 非零时，本意是 CHR ROM size 的高位还是 PRG 倍率，字面上无法区分。本模块采用"NES2.0 的实现里普遍采用的那一种"，代价是**一个 CHR size MSB 非零的 NES2 文件会被报成 `ERR_EXPONENT`**。这是格式自身的歧义，不是解析器的 bug；`chr_rom_exponent` / `prg_rom_exponent` 两个独立标志的意义就在于让上层能区分到底是哪一位非零，进而决定是"不支持这种倍率"还是"要按 CHR MSB 解"。

---

## 5. 字节索引 FSM 与时序账

### 5.1 三个状态

| 状态 | 拍数 | 做什么 |
| --- | --- | --- |
| `ST_IDLE` | 1（采样 `start` 后） | 清 `hdr_q`、`byte_index=0`、锁存 `actual_size` 到 `size_q` |
| `ST_FETCH` | 16 | 一拍搬一个字节：`hdr_q[byte_offset +: 8] <= header[byte_offset +: 8]`，`byte_index` 加一 |
| `ST_DECODE` | 1 | 用 `hdr_q`/`size_q` 组合算出全部字段与错误码，一次性写进输出寄存器 |

从 `start` 被采样到 `done` 结束一共 **18 个时钟沿**，`busy` 高 17 拍（`done` 那一拍 `busy` 仍是 1）。

### 5.2 为什么一个 128 位并行口还要走 16 拍

因为真实的头不是并行出现的。软件里是 `fread` 一次读 16 字节；硬件里 ROM 存在 SD 卡/TF 卡/SPI Flash/配置比特流里，字节是一个拍一个拍从字节通道出来的。把 16 拍 FSM 写成"宽数据总线 + 一拍一个字节"的形状，有三个好处：

1. **和真实接口同构**。以后接 SD/TF 控制器时，只要把 `header` 换成"控制器读数据寄存器"，FSM 一行都不用改。
2. **不依赖"16 字节已经同时到齐"这个假设**。如果模块一拍锁存整个 128 位字，集成层就必须保证 `header` 在同一个周期里稳定，而总线读通常有一拍延迟。
3. **可观测**。`dbg_byte_index` 让"到底读了几个字节、顺序对不对"能被 testbench 逐拍断言，而不是只看最终结果。

**代价是接口合同**：`header` 必须在 `start` 之后的 16 拍内保持稳定。硬件里这意味着必须先在数据寄存器里放好整个头（或接一个小的头缓存），不能边搬边改。这个代价在 18 个时钟的配置阶段里完全可以接受。

`hdr_q[byte_offset +: 8] <= header[byte_offset +: 8]` 用的是可变 part-select：综合出来是 16 选 1 的字节 mux 加一个 128 位寄存器，比 16 个独立的移位寄存器省寄存器，但代价是必须靠"一次写一个字节"来串起来——这正是 FSM 存在的理由。

### 5.3 `start` 在 `busy` 期间被忽略

`ST_FETCH` 和 `ST_DECODE` 分支里都没有 `start` 判断，所以 `start` 在解析期间保持为高不会重启解析。`tb_ines_header_parser` 的 `test_start_ignored_while_busy` 专门把 `start` 拉高 5 拍，断言仍然只有一次 `done`、17 拍 `busy`、16 次取字节、结果不变。

`reset` 是唯一的中止手段。软件里这对应"直接放弃这次 `fload`"，硬件里对应配置阶段的硬复位。

---

## 6. 容量算术的位宽账

```text
prg_blocks = 12 bit   （NES2: {byte9[3:0], byte4}；否则 {4'b0, byte4}）
chr_blocks = 12 bit   （NES2: {byte9[7:4], byte5}；否则 {4'b0, byte5}）

prg_size_bytes = 26 bit  = prg_blocks << 14   (最大 4095 × 16 KiB = 67,092,480)
chr_size_bytes = 26 bit  = chr_blocks << 13   (最大 4095 ×  8 KiB = 33,546,240)
expected_size  = 28 bit  = 16 + trainer×512 + prg + chr
                              (最大 16+512+67,092,480+33,546,240 = 100,639,248)
```

三处容易写错的地方：

1. **PRG 是 16 KiB 块、CHR 是 8 KiB 块**。用同一个移位量会让 CHR 容量整整翻倍。`docs/nes-study/03-ines-format.md` 的误区 1 和误区 2 就是这条。本文初版的 `chr_size_d` 一开始写成了 `{chr_blocks, 14'd0}`，被 testbench 的 `mmc1 chr size` 抓住（对照实验表第 2 行）。
2. **块数是 12 位不是 8 位**，因为 NES 2.0 给了高位扩展。容量因此需要 26 位。
3. **`expected_size` 要 28 位**而不是 26 位：两个 26 位容量相加再加 512，最高会越过 `2^26`。用 26 位存总和会静默溢出，正好把"文件短于声明"这种最该报错的场合变成"看起来正好"。

`64 << prg_ram_shift` 用的 `prg_ram_shift` 只有 4 位，最大 `64 << 15 = 2,097,152`，**不会溢出**，所以本模块不需要为 RAM 容量做上限检查。这和 cNES 在 `flag10.prg_ram_shift_count > 20` 上报错不同：`[源码观察]` cNES 的判据 "> 20"对应的是它自己用的更大字段宽度，而 byte 10/11 的 RAM shift 只有 4 位，`> 20` 这个判断在本仓库的字段定义下恒为假。本模块选择不搬这个判据，因为在本仓库的位宽下它没有意义。

---

## 7. 错误码与优先级

| `error` | 名称 | 条件 |
| --- | --- | --- |
| `0` | `ERR_NONE` | 全部检查通过 |
| `1` | `ERR_MAGIC` | `byte0..3` 不是 `4E 45 53 1A` |
| `2` | `ERR_PRG_ZERO` | 合并后的 `prg_blocks == 0` |
| `3` | `ERR_EXPONENT` | 四个 exponent 标志任一为 1 |
| `4` | `ERR_SIZE_SHORT` | `actual_size < expected_size` |
| `5`–`15` | 保留 | 本模块不使用 |

优先级是**从 magic 开始逐级下降**的固定顺序：

```text
MAGIC > PRG_ZERO > EXPONENT > SIZE_SHORT
```

理由：magic 错的时候其余字段全是垃圾，报任何一个更"具体"的错都是误导；`prg_blocks == 0` 说明头本身非法（真实卡带至少有 16 KiB PRG），比"文件长度对不上"更根本；exponent 说明容量算术的前提不成立；最后才是长度。`tb_ines_header_parser` 对每一级越级组合都有专门样本（magic 错 + PRG 为 0 + 长度 0 → `error==1`；PRG 为 0 + 长度短 → `error==2`；exponent + 长度短 → `error==3`）。

`size_trailing`（`actual_size > expected_size`）**不是错误**。很多 ROM 在有效数据后面还挂着调色板、存档快照或对齐 padding，把它判成错误会误伤。`valid` 仍然是 1，尾部数据怎么处理是 loader 的策略。

---

## 8. 软件 loader 是怎么做的

### 8.1 cNES 的 `load_rom()`

`[源码观察]` `.slim/clonedeps/repos/caseif__cNES/src/loader.c` 的顺序是：

```c
size_t read_bytes = fread(buffer, 16, 1, file);          /* 一次读 16 字节      */
if (read_bytes == 0) { ... return NULL; }                 /* 短读 = 失败        */

uint32_t magic = endian_swap(*((uint32_t*) buffer));       /* 小端序，字节 0 在低位 */
if (magic != NES_MAGIC) { ... return NULL; }

size_t prg_size = buffer[4];
size_t chr_size = buffer[5];

Flag6 flag6 = {0}; memcpy(&flag6, &(buffer[6]), 1);
Flag7 flag7 = {0}; memcpy(&flag7, &(buffer[7]), 1);
uint16_t mapper_id = (flag7.mapper_high << 4) | flag6.mapper_low;

if (flag7.nes2 == 2) {                                    /* byte7 的 bit3:2 == 2 */
    mapper_id |= flag8.mapper_highest << 8;
    prg_size  |= flag9.prg_rom_size_msb << 8;
    chr_size  |= flag9.chr_rom_size_msb << 8;
    prg_ram_size = flag10.prg_ram_shift_count > 0 ? (64 << flag10.prg_ram_shift_count) : 0;
    timing_mode  = flag12.timing_mode;
} else {
    if (strstr(file_name, "(Europe)") || strstr(file_name, "(PAL)")) timing_mode = TIMING_MODE_PAL;
}

Mapper *mapper = _create_mapper(mapper_id, submapper_id);
if (flag6.has_trainer) { printf("ROMs with trainers are not supported\n"); return NULL; }

prg_data = malloc(prg_size * 0x4000);
if ((read_items = fread(prg_data, 0x4000, prg_size, file)) != prg_size) { ... return NULL; }
```

三个值得记住的对应关系：

| cNES 里的写法 | 本模块里的对应物 |
| --- | --- |
| `fread(buffer, 16, 1, file)` | 16 拍 `ST_FETCH` + `hdr_q` |
| `read_items != prg_size` | `actual_size` vs `expected_size` → `ERR_SIZE_SHORT` |
| `flag7.nes2 == 2` | `nes2_d = (byte7[3:2] == 2'b10)` |
| `(flag7.mapper_high << 4) \| flag6.mapper_low` | `mapper_id = {4'b0, f7[7:4], f6[7:4]}` |
| `flag9.prg_rom_size_msb << 8` | `prg_blocks = {f9[3:0], f4}` |
| `has_trainer` 直接失败 | 只上报 `trainer` 标志并把 512 字节计入 `expected_size`，是否拒绝是上层策略 |

**本模块和 cNES 有意的三处不同**：

1. cNES 遇到 trainer 直接失败；本模块只报标志。理由：`docs/nes-study/03-ines-format.md` 第 6.2 节已经指出"trainer 是 ROM 数据布局的一部分，解析器应在正确的偏移处处理它；是否支持其内容是模拟器能力问题"。本模块保证 PRG 的文件起点被算对（`expected_size` 里的 512），不替上层决定支不支持。
2. cNES 不检查文件总长度，只检查"PRG 块读够了没有"；本模块把 16 字节头 + trainer + PRG + CHR 全部算进 `expected_size` 再和 `actual_size` 一次比完，因为硬件侧需要在**搬数据之前**就知道边界。
3. cNES 非 NES2 时用文件名猜 PAL；本模块对非 NES2 一律给 `cpu_ppu_timing = 0`。`[源码观察]` 文件名启发式是 cNES 的策略，`docs/nes-study/03-ines-format.md` 第 12 节误区 8 明确写了"文件名启发式不能替代 header、制式和测试 ROM"。本模块不做这件事；真要按文件名覆盖 timing，应该在 loader 层覆盖这个配置寄存器，而不是让解析器去猜。

### 8.2 Obara 的 `load_data()`

`[源码观察]` Obara 走的是另一条路：`load_file()` 先把整个文件读进 `ROMData`，`load_data()` 再在内存里识别 `"NESM\x1A"`（NSF）、`"NSFE"`、`"NES\x1A"`，然后按第 4.3 节引用的 `INES` / `NES2` / `ARCHAIC_INES` 三分法处理。**"把文件长度作为已知信息传进解析器"这一点上，Obara 的形态天然满足**——整个文件都在内存里，`rom_data->size` 直接可用；本模块的 `actual_size` 输入就是这一形态的硬件等价物。

---

## 9. 硬件怎么用这些输出

### 9.1 配置寄存器接线

解析结果是一组**配置寄存器**，接法如下（`nes_mapper` 现有的参数名见 `rtl/nes_core/mapper/nes_mapper.v`）：

```text
ines_header_parser                 nes_mapper（参数或寄存器）
  valid ────────────────────────> 使能：valid=0 时禁止启动 CPU
  error[3:0] ───────────────────> 诊断寄存器 / 错误码 LED
  nes2, dirty_ines ─────────────> 诊断寄存器
  mapper_id[11:0] ──────────────> mapper 选择（注意 12 位 -> 8 位的映射，见下）
  prg_size_bytes[25:0] ─────────> ROM 搬运长度 / PRG base address 高位
  chr_size_bytes[25:0] ─────────> CHR base address 高位
  mirroring[1:0], four_screen ──> HEADER_MIRRORING = four_screen ? 3'd4 : {1'b0, mirroring}
  trainer ──────────────────────> PRG 起始文件偏移 = trainer ? 512 : 0
  battery ──────────────────────> NVRAM 使能 / 存档文件名
  prg_ram_shift, chr_ram_shift ─> PRG RAM / CHR RAM 深度 = 64 << shift
  cpu_ppu_timing[1:0] ──────────> 制式选择（NTSC / PAL / 多制式 / Dendy）
  expected_size, size_trailing ─> 诊断
  done ─────────────────────────> 单拍脉冲：搬运引擎开始填 PRG/CHR
```

两处需要注意的**宽度落差**：

1. **`mapper_id` 是 12 位，`nes_mapper` 的 `mapper_select` 是 8 位。** 本仓库当前实现的 mapper 只有 0/1/2/3/4 五种（`nes_mapper.v` 的 `select_nrom/select_mmc1/select_uxrom/select_cnrom/select_mmc3`），所以集成层应当显式做 `mapper_id[7:0]` 截断并对"超出已实现范围"报错，而不是让一个 12 位值直接落到 8 位寄存器上再靠 `default` 分支处理——那样 `0x10B` 和 `0x10` 会撞成同一个 mapper。
2. **`mirroring` 是 2 位原始位、`four_screen` 是独立 1 位。** `nes_mapper` 的 `HEADER_MIRRORING` 是 3 位编码，其 `nametable_map_decode` 里 `3'd4` 解出 `8'b11100100`，也就是四张 nametable 全部不同（four-screen）。合并时**必须**让 four-screen 优先于 mirroring，因为 real four-screen 卡带会额外带 1 KiB nametable RAM，不能当作普通 mirroring 折叠掉（`docs/nes-study/03-ines-format.md` 误区 6）。

### 9.2 ROM base address 的算术

把 `prg_size_bytes` / `chr_size_bytes` / `trainer` 变成实际地址：

```text
文件布局（NROM 32K + CHR 8K + trainer 的例子）：
  0x00000  ┌──────────────┐
  0x00010  │ PRG ROM      │ 32 KiB
  0x08010  ├──────────────┤
  0x08110  │ CHR ROM      │  8 KiB
  0x0A110  └──────────────┘

SDRAM 里的目标布局：
  PRG_BASE + 0      <- 文件偏移 0x00010（trainer 之后）
  CHR_BASE + 0      <- 文件偏移 0x08010
```

对应的算术（这就是 `prg_size_bytes` 必须是字节数而不是块数的原因）：

```text
prg_file_offset = 16 + (trainer ? 512 : 0)          /* 16 位头 + trainer */
chr_file_offset = prg_file_offset + prg_size_bytes
prg_dst_offset  = 0
chr_dst_offset  = prg_size_bytes                    /* PRG 和 CHR 连续存放 */

搬运引擎的每拍地址：
  file_addr = rom_base + file_offset + byte_index
  dst_addr  = prg_dst_base + dst_offset  + byte_index
```

`trainer` 只影响 `file_offset`，不影响 `dst_offset`：**trainer 数据不搬进 SDRAM**（或者搬到一块单独的区域），PRG 必须落在偏移 0，这样 mapper 的 `prg_bank_offset` 才能和 `nes_mapper_nrom` 里 `cpu_addr[14:0]` 的直接拼接对上，不需要额外的减法。

### 9.3 启动顺序

```text
配置阶段（一次，18 拍 + 搬运时间）
  reset 释放
    -> 读 ROM 文件前 16 字节到 header，准备 actual_size
    -> start 拉高一拍
    -> 等待 done
    -> if (!valid) 报错并停在这里，不要启动 CPU
    -> 写 nes_mapper 的配置寄存器（mapper 选择、mirroring、RAM 深度）
    -> 启动 PRG/CHR 搬运引擎
    -> 搬运完成
运行阶段
  -> CPU 从 $FFFC 取向量，mapper 只处理 bank 译码，不再看 header
```

`[RTL 建议]` 这条顺序和 `docs/nes-study/03-ines-format.md` 第 13.3 节一致：**先只验证 header 字段和长度，再验证固定映射，最后才加 bank/mirroring/IRQ**。本模块提供的 `valid` 就是那个"配置阶段全部通过"的单一信号，运行阶段只处理已经验证过的元数据。

---

## 10. 明确未实现 / 未建模

- **exponent notation 的实际倍率**：模块只上报四个标志并报 `ERR_EXPONENT`，不按 ×2/×3 放大容量。
- **`byte9[7:4]` 的二义性**：按"NES2.0 实现的普遍做法"判成 PRG 倍率，代价是 CHR size MSB 非零的文件被拒。见第 4.4 节。
- **VS Unisystem / PlayChoice / console type / PRG-RAM 与 CHR-RAM 的 NVRAM shift / byte12 高位 / byte13–15**：不解释，保留在 `dbg_header`。
- **trainer 内容**：不解释、不搬运，只报标志并修正文件偏移。
- **文件 I/O 与 `actual_size` 的来源**：`ftell`/`fseek`、SD 卡目录项、Flash 长度表都在模块之外。
- **短读/IO 错误**：`actual_size` 由外部算好后传入，模块不区分"文件短"和"读失败"。
- **`INES_DEFAULT_RAM_SHIFT` 是策略不是规格**：默认 7（8 KiB）是绝大多数模拟器对非 NES2 文件的默认策略，不是 iNES 规范的规定；改这个参数不改变任何位图解释。
- **PRG/CHR 数据的搬运与 bank 译码**：见 `nes_mapper` 与第 9.2 节。
- **未接进 `nes_system_*`**：本模块是配置阶段的旁路模块，没有被 `rtl/nes_core/system/` 里的任何顶层实例化，也没有对应的 `tools/sim_all.ps1` 条目和 ModelSim `.do` 脚本。这两个脚本不在本任务的写入范围内，没有改。
- **综合与时序**：没有跑过 Quartus 综合。`{byte_index, 3'b000}` 的可变 part-select 写和 26/28 位加法是这个模块里仅有的两处"面积/时序上值得看一眼"的地方。
