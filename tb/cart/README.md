# iNES/NES2.0 头解析 testbench

`tb_ines_header_parser.v` 是 `rtl/nes_core/cart/ines_header_parser.v` 的自检 testbench。它自己构造 16 字节头、自己给出 `actual_size`，不加载 ROM 文件，不读外部数据，不需要 test ROM。期望值全部由 TB 依据 iNES/NES2.0 字段语义**独立算出**，不读 DUT 的任何内部译码输出，所以断言不构成自证。

接口合同、字段位图、格式判定（含 dirty iNES 掩码）、容量算术的位宽账、错误码优先级，以及软件 loader 的 `fread` 流程与硬件配置寄存器/ROM base address 的对应关系，见 [`docs/modules/ines-loader.md`](../../docs/modules/ines-loader.md)。iNES/NES2.0 文件格式本身的研究见 [`docs/nes-study/03-ines-format.md`](../../docs/nes-study/03-ines-format.md)。

## 文件

| 文件 | 顶层 | 覆盖 |
|---|---|---|
| `tb_ines_header_parser.v` | `tb_ines_header_parser` | 字节索引 FSM 时序（16 拍取字节 + 1 拍译码）、clean iNES 解析、flags6 逐位（mirroring/battery/trainer/four-screen/mapper 低四位）、trainer 造成的 PRG 起点偏移、dirty iNES 掩码（三种非零格式位组合）、NES2.0 的 9 位 mapper + submapper + size MSB 扩展 + RAM shift + timing、NES2.0 exponent notation 四个标志、magic 四个字节各自出错与出错时字段清零、PRG size 为 0、`actual_size` 短/长/相等/0/0xFFFFFFFF、`start` 在 busy 期间被忽略、输出保持与重新解析、异步复位清空与复位后重解析 |

## 运行

RTL 和 testbench 都用 `-g2001`，输出放在临时目录：

```powershell
$tmp = Join-Path $env:TEMP 'op_fpga_emu'
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
& 'C:\iverilog\bin\iverilog.exe' -g2001 -Wall -s tb_ines_header_parser -o (Join-Path $tmp 'tb_ines_header_parser.vvp') 'rtl\nes_core\cart\ines_header_parser.v' 'tb\cart\tb_ines_header_parser.v'
& 'C:\iverilog\bin\vvp.exe' (Join-Path $tmp 'tb_ines_header_parser.vvp')
```

RTL 也可以不带 testbench 单独 elaborate：

```powershell
& 'C:\iverilog\bin\iverilog.exe' -g2001 -Wall -s ines_header_parser -o (Join-Path $tmp 'ines_header_parser.vvp') 'rtl\nes_core\cart\ines_header_parser.v'
```

加 `-Wall` 编译 RTL + testbench 均无告警。`tb_ines_header_parser` 同时实例化两个 DUT（`dut` 与 `INES_DEFAULT_RAM_SHIFT=0` 的 `dut_alt`），共用 `start`/`header`/`actual_size`，用来覆盖默认 RAM shift 参数；两者 `done` 逐拍一致由常驻监视器断言。

## 固定期望输出

```text
byte index fsm walks 16 header bytes and decodes in 17 cycles PASS
clean ines header mapper mirroring sizes and default ram shift PASS
flags6 mirroring battery trainer four screen and mapper nibble PASS
trainer offset prg base and battery flag PASS
dirty ines header mask on format bits and flags7 high nibble PASS
nes2 mapper submapper size msb ram shift and timing PASS
nes2 exponent notation flags for rom and ram sizes PASS
magic check and field zeroing on bad magic PASS
zero prg rom size error beats length check PASS
actual_size versus expected_size short and trailing bytes PASS
start held high during a parse does not restart the fsm PASS
outputs hold between parses and a restart re-decodes PASS
asynchronous reset clears decode state and reparses PASS
CHECKS 232
PASS tb_ines_header_parser magic/nes2/dirty-mask/sizes/error-priority
```

失败时 `expect*` 任务会打印 `FAIL <标签>: got <实际> expected <期望>`，并以 `FAIL tb_ines_header_parser with n failing checks` 收尾。工具缺失、编译错误、testbench 全局超时同样是失败。

## 断言覆盖要点

### 字节索引 FSM 的时序账

常驻监视器在每个 `busy` 且 `!done` 的时钟沿把 `dbg_byte_index` 记进 `idx_log`，在每次 `done` 时累加 `done_count`，并逐拍比较两个实例的 `done`。每个用例断言：

- `busy_cycles == 17`（16 拍取字节 + 1 拍译码），`done_count == 1`；
- `idx_log_count == 16`，且 `idx_log[0..15] == 0..15`，即字节顺序严格是文件偏移 0→15；
- `start` 被采样的下一拍 `busy=1`、`done=0`、`dbg_byte_index==0`；
- 译码结束后 `busy=0`、`done=0`、`dbg_byte_index==0`；
- `dbg_header` 与 TB 呈现的 128 位头逐位相同（证明 16 次可变 part-select 写入没有错位）。

### 字段语义

- clean iNES：`4E 45 53 1A / 01 00 / 40 00` → mapper 4、horizontal、PRG 16384、CHR 0（CHR RAM）、默认 shift 7/7、expected 16400。
- flags6 逐位：`0x02` 只置 battery、`0x01` 置 vertical、`0x04` 置 trainer 并把 `expected_size` 变成 16912、`0x08` 置 four-screen 而 `mirroring` 仍是原始位、`0xA7` 同时置 vertical+battery+trainer+mapper 低四位 `0xA`。
- trainer：`0x1F` + PRG 2 块 + CHR 1 块 → `expected_size == 16+512+32768+8192 == 41488`，`actual_size` 必须等于它才 `valid`。
- NES2.0：`byte7=0x08` 触发 NES2，mapper 合成 12 位 `{byte8[3:0], byte7[7:4], byte6[7:4]} = 0x40B`，submapper 3，PRG 用 `byte9[3:0]` 扩展到 12,582,912 字节，CHR 24,576 字节，shift 7/8，timing 2。
- exponent notation 四个标志分别用 `byte9=0x10`（PRG ROM）、`byte9=0x04`（CHR ROM）、`byte10=0x40`（PRG RAM）、`byte11=0x80`（CHR RAM）单独触发，并断言 `error==3`。

### 错误优先级

错误码按 `MAGIC > PRG_ZERO > EXPONENT > SIZE_SHORT` 仲裁，每个越级组合都有专门样本：

- magic 四个字节各错一次；`magic` 错 + PRG 为 0 + `actual_size=0` → `error==1`；
- `magic` 错时 `mapper_id`/`prg_size_bytes`/`chr_size_bytes`/`nes2`/`dirty_ines`/`mirroring`/`four_screen`/`trainer`/`battery`/两个 shift/`timing`/`expected_size`/`size_trailing` 全部为 0，而 `dbg_header` 仍保留原始字节供诊断；
- PRG 为 0 且 `actual_size` 也短 → `error==2`（不是 4）；
- exponent 触发且 `actual_size` 也短 → `error==3`（不是 4）。

### 文件长度

`expected_size` 分别用 41488（带 trainer）、16400（不带 trainer）、8208（CHR 只有 1 块）三组值断言；`actual_size` 覆盖 `expected-1`（`ERR_SIZE_SHORT`）、`0`、`expected+1`（`valid` 且 `size_trailing=1`）、`0xFFFFFFFF`（`valid` 且 `size_trailing=1`）、`expected`（`valid` 且 `size_trailing=0`）。

### 控制流

- `start` 在整个 16 拍取字节期间保持为高：仍然只有一次 `done`、17 拍 `busy`、16 次取字节、结果不被重启。
- 一次解析完成后输出保持上一次结果（`valid`、mapper、size 在下一次取字节期间都不动），第二次 `start` 后重新译码。
- 异步复位把 20 个输出/调试信号全部清零（含 `dbg_header` 和 `dbg_byte_index`），保持 40 ns 不回弹，复位后重新解析正常。

## 对照实验（证明断言不构成自证）

对 RTL 副本做下列改动（**不修改仓库文件**，只改临时副本）重跑，全部被 TB 抓住：

| 改动 | 被抓住的失败检查行数 | 首个失败标签 |
|---|---|---|
| `nes2_d` 判成 `f7[3:2] == 2'b01` | 30 | `archaic format 0100 flagged dirty` |
| CHR 容量改成 `{chr_blocks, 14'd0}`（8192 变 16384） | 19 | `mmc1 trainer battery four screen valid` |
| mapper 高低位 nibble 换位 | 11 | `nrom128 mapper from flags6 and flags7` |
| 去掉 trainer 的 512 字节 | 9 | `f6 trainer adds 512 to expected size` |
| 去掉 exponent notation 检查 | 6 | `prg exponent error` |
| dirty iNES 不掩码 `byte7[7:4]` | 4 | `dirty tail masks flags7 high nibble` |
| `size_short` 比较差 1 字节 | 4 | `one byte short error` |

## 明确未覆盖

- 真实 ROM、test ROM、综合、时序收敛、板上行为。
- 与 `nes_mapper` 的接线：`nes_mapper` 的 `mapper_select` 是 8 位，`HEADER_MIRRORING` 是 3 位且用 `3'd4` 表示 four-screen；把本模块的 12 位 `mapper_id` 映射到 8 位选择、以及 `HEADER_MIRRORING = four_screen ? 3'd4 : {1'b0, mirroring}` 的接法见 `docs/modules/ines-loader.md`，本 testbench 不实例化 `nes_mapper`。
- ROM base address 的计算：PRG/CHR 数据的搬运、`prg_ram_shift`/`chr_ram_shift` 得到的字节数到 BRAM 深度参数的换算。
- 文件 I/O：`fread` 的返回值语义、短读、`ftell`/`fseek` 得到的 `actual_size`。
- exponent notation（×2/×3）的实际容量计算：模块只上报标志并报 `ERR_EXPONENT`，不支持按倍率放大。
- VS Unisystem / PlayChoice（`byte7[6:7]`）、`byte7[1:0]`、`byte13`–`byte15`：模块不解释这些位（原始值保留在 `dbg_header` 里）。
- 非 NES2 文件的 NTSC/PAL 选择：模块对非 NES2 一律输出 `cpu_ppu_timing = 0`，用文件名猜 PAL 是 loader 的策略选择，不是 header 字段。
- trainer 的**内容**：模块只报 `trainer` 标志并把 512 字节计入 `expected_size`，不解释也不跳过 trainer 数据本身。
