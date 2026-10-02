# nes2hex：把 iNES `.nes` 转成 bitstream 内嵌的两个 hex

`tools/nes2hex.ps1` 把一个 iNES 格式的 `.nes` ROM 转成 `rtl/nes_core/cart/nes_cart_rom.v` 需要的两个 `$readmemh` 镜像。转换器是主机侧工具，**不改任何 RTL**，输出是纯 ASCII hex。

## 为什么需要它

Zynq 板没有卡带读取通路：`nes_cart_rom.v` 的文件头说明 TF 卡和 QSPI flash 都在 PS 的 MIO 引脚上，PL 够不着，所以**不在 bitstream 里的 ROM 就是 PL 看不见的 ROM**。仓库里长期只有合成的占位数据（`prg_placeholder.hex` / `chr_placeholder.hex`），真实游戏因此无法运行。这个工具是"能玩真卡"这条路上主机侧缺的那一环。

## 用法

```powershell
# 最常见：输出到当前目录下的 prg.hex / chr.hex
.\tools\nes2hex.ps1 -RomPath D:\roms\game.nes -OutDir .

# 指定输出文件名
.\tools\nes2hex.ps1 -RomPath game.nes -PrgOut build\prg.hex -ChrOut build\chr.hex

# 只看摘要，不写文件（当前版本仍会写，用 -Quiet 抑制非错误输出）
.\tools\nes2hex.ps1 -RomPath game.nes -OutDir . -Quiet
```

`$Input` 是 PowerShell 的 automatic variable，`param()` 里叫这个名字会在 `-File` 方式下绑定成空串，所以参数名是 `-RomPath`；`-Input` 作为别名保留。

| 参数 | 默认 | 说明 |
|---|---|---|
| `-RomPath` | 必填 | 输入 `.nes`（别名 `-Input`、`-Rom`） |
| `-OutDir` | `.` | 输出目录，默认写 `prg.hex` / `chr.hex` |
| `-PrgOut` / `-ChrOut` | 由 `-OutDir` 推出 | 显式输出路径 |
| `-PrgWords` | `131072` | PRG 目标深度，必须是完整深度 |
| `-ChrWords` | `8192` | CHR 目标深度 |
| `-OverwritePlaceholders` | 关 | 只有显式给出才允许覆盖已提交的占位 hex |
| `-AllowTrailingBytes` | 关 | 文件比头部声明的长度多出尾巴时仍然转换 |
| `-Quiet` | 关 | 只在出错时输出 |

退出码：**0** 成功，**2** 拒绝转换。

## 解析了什么

16 字节 iNES 头，逐项对应 `rtl/nes_core/cart/ines_header_parser.v` 的字段：

- **magic** `4E 45 53 1A`（`:88-91`），不符即拒绝
- **byte 4**：PRG ROM 大小，单位 16 KiB（`:106` `{4'd0, f4}` × 16384）
- **byte 5**：CHR ROM 大小，单位 8 KiB（`:107` × 8192）
- **byte 6**：bit 2 trainer、bit 1 battery、bit 3 four-screen、bit 0 mirroring、bit 7..4 mapper 低半字节
- **byte 7**：bit 7..4 mapper 高半字节
- **NES 2.0 判定** flags 7 `[3:2] == 2'b10`（`:94`）；此时 byte 8/9 提供扩展容量与 exponent
- **mapper 号** = `(byte7 >> 4) << 4 | (byte6 >> 4)`，即 `{f7[7:4], f6[7:4]}`（`:98`）
- **exponent notation**（NES 2.0）直接拒绝，与硬件的 `ERR_EXPONENT`（`:119-123`）一致

**trainer**：flags 6 bit 2 置位时头后面跟 512 字节 trainer（`:111-113`）。这 512 字节被**跳过**，不进任何镜像——它属于 `$7000` 的卡带 RAM，不是 ROM 内容。

## 头是被剥掉的，不是写进 hex 的

这是最容易搞错的一条。**证据**：

1. `ines_header_parser.v` 虽然存在，但**只被它自己的 testbench 例化**（`tb/cart/tb_ines_header_parser.v:53` 和 `:86`）。全仓库没有任何 RTL 例化它——`nes_system_v6.v`、`nes_zynq_top.v`、`nes_ep4ce10_top.v` 都没有。
2. 它的 `header` 是一个 128 bit **输入端口**（`:9`），不是它自己从 ROM 里读的。就算接上去，也仍然要有人把那 16 字节喂给它，而 bitstream 里唯一的字节来源就是那两个 `$readmemh` 数组。
3. `nes_cart_rom.v:173-176` 是 `reg [7:0] prg_rom [0:PRG_SIZE_BYTES-1]; $readmemh(PRG_INIT_FILE, prg_rom);`，索引只有 `prg_addr`，没有任何 header 偏移。
4. `nes_mapper_nrom.v:22-24` 在 `PRG_SIZE_BYTES = 32768` 时给 `prg_bank_offset = cpu_addr[14:0]`，于是 `$8000` 落到 `prg_rom[0]`。数组下标 0 必须是在 `$8000` 取到的那个 PRG 字节，也就是头之后第一个字节，而不是 `0x4E`。

所以镜像里是**纯 PRG** 和**纯 CHR**，不含 16 字节头，也不含 trainer。

## hex 格式

与已提交的两个占位文件逐字节一致（`tools/nes2hex_selftest.ps1` 的 C 组是这条的证明）：

- 每字节两个**小写** hex 数字
- 值之间**一个空格**，无行尾空格、无 tab、无空分隔符
- **每行 64 个值**，所以 `prg_placeholder.hex` 是 2048 行 × 191 字符 = 393216 字节，`chr_placeholder.hex` 是 128 行 × 191 字符 = 24576 字节
- **LF** 行尾，文件末尾有一个 LF，无 BOM

## 为什么要补满深度

`nes_cart_rom.v` 里那条约束是整个工具最重要的行为依据：**一个比数组声明深度短的 `$readmemh`，会让剩下的部分在 fabric 里保持未定义。** 所以输出**总是**补到完整声明深度——PRG 131072 字、CHR 8192 字——用 `00` 填。一个 16 KiB 的游戏在 128 KiB 数组里是 87.5% 填充，这是**预期结果不是缺陷**，工具会把真实大小和填充量一起打印出来。

CHR-RAM 游戏（头部声明 0 个 CHR bank）时，那 8 KiB 数组其实是 RAM，所以 CHR 镜像全 `00`，工具会明确说这一点，并提示可能需要在核上打开 `NROM_CHR_RAM` / `MMC1_CHR_RAM` / `MMC3_CHR_RAM`（mapper 2/3 的 CNROM、UxROM 没有对应的 CHR-RAM 参数）。

## 超过 8 KiB 的 CHR 会被截断，这是有意的

CHR ROM 大于 8192 字节时，工具**只输出前 8192 字节**并打印警告，**不拒绝**。依据是 `nes_cart_rom.v:57-63` 自己记录的行为：`CHR_LOCAL_BITS = 13` 时 mapper 翻译出的 `chr_final_addr` 只用 `[12:0]` 索引，高于 12 的 bank 位被丢弃，对 CNROM（32 KiB）、MMC1（最多 64 KiB）、MMC3（最多 64 KiB）是"折叠到 0..7 的别名"。保留**第一个** bank 意味着 bank 0 就是真正的 bank 0，也就是 mapper 寄存器没写时的取值。bank 1 及以上会显示错误图案——这是已记录在案的限制，加宽 `CHR_LOCAL_BITS` / `CHR_SIZE_BYTES` 才是修法，而那是 RTL/BRAM 改动。

PRG 超过深度**一律拒绝**：`prg_rom` 是按 `mapper_prg_bank_offset` 分 bank 索引的，静默截掉尾部会改变每个 CPU 窗口读的是哪个 bank。

## MAPPER_SELECT 怎么对

核里的 `MAPPER_SELECT`（`nes_mapper.v:139-143`）和 iNES 头里的 mapper 号**不是同一套编号**：

| iNES 头 mapper 号 | 名字 | `MAPPER_SELECT` |
|---|---|---|
| 0 | NROM | `8'd0` |
| 1 | MMC1 | `8'd1` |
| 2 | UxROM | `8'd2` |
| 3 | CNROM | `8'd3` |
| 4 | MMC3 | `8'd4` |

前五个恰好同值，但工具是从头里**算**出 mapper 号再查这张表的，不假设它和某个常量相等。头里的号不在 0..4 时，工具**不给** `MAPPER_SELECT`，只打印 "mapper N is not one of the five mappers"，并说明选错的后果是"能跑但图块渲染错误"。

注意 iNES 头里 3 号 mapper 是 CNROM，本核里也是 `8'd3`；很多 ROM 目录里被称作"MMC3"的那类游戏用的是 4 号。转换器不会替使用者判断这一点，所以它两处都打印：头里的号，和建议的 `MAPPER_SELECT`。

另外两个由头决定、必须一起看的参数：

- `HEADER_MIRRORING` = `3'd0` 横向 / `3'd1` 纵向，four-screen 优先
- **16 KiB 的 NROM 游戏必须把 `NROM_PRG_SIZE_BYTES` 设成 16384**，不能留 32768 的默认值。`nes_mapper_nrom.v:7` 由它推导 `NROM_MIRROR_16K`；留在 32768 会让 16 KiB 镜像同时映到 `$8000-$BFFF` 和 `$C000-$FFFF`，CPU 取到错误的一半

## 拒绝而不是输出错误文件

所有校验都在**打开任何输出文件之前**跑完，两个输出先写临时文件、读回校验一致后才移动到位。所以被拒绝的 ROM**不会留下任何输出**，也不会留下 `.nes2hex-tmp`。下面这些都会打印清楚的错误并以 2 退出：

- magic 不对，或文件短于 16 字节
- 头部声明的大小与实际长度不符（截断，或多出尾巴除非给 `-AllowTrailingBytes`）
- PRG bank 数为 0（对应硬件的 `ERR_PRG_ZERO`）
- PRG 超过 128 KiB，或超过 `-PrgWords`
- NES 2.0 exponent notation（对应硬件的 `ERR_EXPONENT`）
- 输出文件已存在，或输出目录不存在
- 输出文件名是 `prg_placeholder.hex` / `chr_placeholder.hex` 而没有 `-OverwritePlaceholders`

一个"看起来合理但内容错误"的 hex 比一次拒绝糟糕得多。

## 自检

```powershell
.\tools\nes2hex_selftest.ps1
```

**不使用任何受版权保护的 ROM。** 每个输入都在内存里按已知的确定性序列逐字节合成，用真实工具转换，再把产出的 hex 读回来与源字节逐字比对。

- **A 组（round trip）**：NROM 16 KiB/8 KiB、NROM 128 KiB（无需填充）、CHR-RAM（0 CHR bank）、带 trainer、iNES mapper 2（UxROM，64 KiB CHR）、iNES mapper 4（MMC3，32 KiB CHR，四屏 + battery），以及 mapper 7（不支持，必须拒绝给 `MAPPER_SELECT`）
- **B 组（填充）**：16 KiB PRG 必须正好 131072 字，真实数据之后每个字都是 `00`，且前 16384 字仍是真实数据
- **C 组（与占位文件逐字节一致）**：把两个占位 hex 自己的内容反解成字节、重新走一遍转换器，产出的文件必须与已提交的文件**逐字节相同**；另外核对行宽、分隔符、hex 大小写、LF、无 BOM、末尾 LF、行数 == LF 数，以及两个占位文件本身在磁盘上没被改动
- **D 组（拒绝）**：坏 magic、短于 16 字节、截断、大小不符（含 `-AllowTrailingBytes` 的反向验证）、PRG 超 128 KiB、PRG 超过 `-PrgWords`、0 PRG bank、NES2.0 exponent、输出已存在、占位文件保护、输入不存在、输出目录不存在；每一项都断言**非零退出**且**不留任何输出文件**

退出码 0 且打印 `Result: PASS (132 of 132)` 时才算通过（当前 **132** 项，全绿）。

## 换 ROM 后要重新综合

`MAPPER_SELECT`、`PRG_SIZE_BYTES`、`NROM_PRG_SIZE_BYTES`、`HEADER_MIRRORING`、各 `*_CHR_RAM` 都是 **elaboration 期参数**，一个实例整场只有一个 mapper、一份 PRG 深度。换卡带等于换参数，必须重新综合并重出 bitstream。hex 路径方面：CHR 侧 `nes_zynq_top.v` 有 `CHR_INIT_FILE` 参数可以指到别处；**PRG 侧没有这个参数**——`nes_system_v6.v` 用 `nes_cart_rom` 自己的默认值 `rtl/nes_core/cart/prg_placeholder.hex`，相对路径相对于仿真器或 Vivado 的启动目录（`nes_zynq_top.v:245-253` 明确记录了这条限制）。给 PRG 加可重定位的参数要改 `nes_system_v6`，那是有回归门禁的模块，不在本工具范围内。
