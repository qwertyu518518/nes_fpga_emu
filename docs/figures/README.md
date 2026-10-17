# 图目录（自动生成）

本目录的 SVG 由 `tools/gen_figures.py` 生成，**不要手工编辑**。
重新生成：

```text
.\tools\gen_figures.ps1            # 或 python tools/gen_figures.py
python tools/gen_figures.py --check   # 校验已是最新
```

生成是幂等的：连续两次运行产生逐字节相同的输出。每张图都由
对应 RTL 源码读出后绘制；源码中无法确定的细节一律不画。

编号为**按文档独立编号**：每张图在其被嵌入的那篇文档里按出现顺序记
为“图 N”。跨文档不共享编号，因此新增图不会改动既有文档里的编号引用。

| 文件 | 展示内容 | 生成来源（RTL） | 嵌入文档（编号） |
|---|---|---|---|
| [`zynq-system-hierarchy.svg`](zynq-system-hierarchy.svg) | 顶层模块层次、sys/core/lcd 三个时钟域、三条跨域边界与复位网络。 | `rtl/platform/zynq/nes_zynq_top.v` | [`modules/zynq-platform.md`](../modules/zynq-platform.md) 图 2 |
| [`zynq-clock-tree.svg`](zynq-clock-tree.svg) | 50 MHz 输入经 MMCM 到 1181.25 MHz VCO，再整数/分数分频出核心与 LCD 时钟。 | `rtl/platform/zynq/nes_zynq_clk.v` | [`modules/zynq-platform.md`](../modules/zynq-platform.md) 图 1 |
| [`cpu-bus.svg`](cpu-bus.svg) | 地址译码表、ready/等待态路径、owner/ack、bus_hold 与 DMA 端口优先级。 | `rtl/nes_core/bus/nes_cpu_bus.v` | [`modules/cpu-bus.md`](../modules/cpu-bus.md) 图 1 |
| [`ppu-dot-pipeline.svg`](ppu-dot-pipeline.svg) | dot 0..340 计数、背景取数节奏、精灵窗口 [257,291]、外部 CHR 冻结点。 | `rtl/nes_core/ppu/nes_ppu2c02.v` | [`walkthrough/51-ppu2c02.md`](../walkthrough/51-ppu2c02.md) 图 1 |
| [`chr-fetch-fsm.svg`](chr-fetch-fsm.svg) | S_IDLE/S_PRE/S_ARM/S_BEAT/S_GRAB 五态与 7 ce 占用、两次 chr_req 拍。 | `rtl/nes_core/ppu/nes_chr_fetch_unit.v` | [`walkthrough/22-chr-fetch-unit.md`](../walkthrough/22-chr-fetch-unit.md) 图 1 |
| [`chr-arbitration.svg`](chr-arbitration.svg) | 背景/精灵/$2007 三个读主设备经优先级 mux 到共享 CHR 阵列，冻结与独立写口。 | `rtl/nes_core/ppu/nes_ppu2c02.v + rtl/nes_core/system/nes_system_v6.v` | [`modules/ppu-external-chr.md`](../modules/ppu-external-chr.md) 图 1 |
| [`apu-to-i2s.svg`](apu-to-i2s.svg) | 五通道混合、2016/55 有理抽取、CDC FIFO 与 I2S 移位器。 | `nes_apu2a03.v + nes_zynq_top.v + nes_audio_i2s.v + nes_cdc_fifo.v` | [`modules/i2s-audio.md`](../modules/i2s-audio.md) 图 1 |
| [`video-scaling-800x480.svg`](video-scaling-800x480.svg) | 水平 3:1+每 8 取 4（32 组 × 25 dot）与垂直 2:1，frame_mem 双口跨域。 | `rtl/nes_core/video/nes_video_800x480.v` | [`modules/video-800x480.md`](../modules/video-800x480.md) 图 1 |
| [`touch-state-and-regions.svg`](touch-state-and-regions.svg) | 复位→校准→轮询状态序列、轴交换与由最大值派生的区域切点。 | `rtl/nes_core/peripheral/nes_touch_input.v` | [`modules/touch-input.md`](../modules/touch-input.md) 图 1 |
| [`hdmi-path.svg`](hdmi-path.svg) | 两个 MMCM 的四条时钟、core_clk 写 / hdmi_pclk 读的跨域 scaler、TMDS 编码器到串行器到连接器与 DDC 限制。 | `rtl/nes_core/video/nes_video_hdmi.v + rtl/platform/zynq/nes_hdmi_tx.v + rtl/platform/zynq/nes_hdmi_tmds_encoder.v + rtl/platform/zynq/nes_hdmi_tmds_serializer.v + rtl/platform/zynq/nes_zynq_clk.v` | [`modules/hdmi-tx.md`](../modules/hdmi-tx.md) 图 1 |
| [`mapper-dispatch.svg`](mapper-dispatch.svg) | mapper_select 分发到五个并存的子模块、各自与 select_* 的写门，经组合 mux 到 bank offset / mirroring / IRQ 输出。 | `rtl/nes_core/mapper/nes_mapper.v` | [`modules/mappers.md`](../modules/mappers.md) 图 1 |
| [`cdc-fifo-pointers.svg`](cdc-fifo-pointers.svg) | 二进制指针本地寻址、格雷码指针跨域、两级同步器与满/空判据，以及指针为何多一位。 | `rtl/nes_core/peripheral/nes_cdc_fifo.v` | [`modules/cdc-fifo.md`](../modules/cdc-fifo.md) 图 1 |
| [`oam-dma-path.svg`](oam-dma-path.svg) | start 锁存、四态状态机、513/514 周期账、总线握手与 OAMADDR 两种接法。 | `rtl/nes_core/ppu/nes_oam_dma.v` | [`modules/oam-dma.md`](../modules/oam-dma.md) 图 1 |
| [`ps-rom-load.svg`](ps-rom-load.svg) | AXI 从机与 50 MHz PS 域、bundled-data 跨域桥、核内 PRG 与顶层 CHR 的加载端口、LOAD_EN 三重惰性门与 console hold 同步。 | `rtl/platform/zynq/axi_lite_regs.v + rtl/nes_core/cart/nes_cart_load_bridge.v + rtl/nes_core/cart/nes_cart_rom.v + rtl/platform/zynq/nes_zynq_top.v` | [`modules/ps-rom-load.md`](../modules/ps-rom-load.md) 图 1 |
| [`ps-rom-load-software.svg`](ps-rom-load-software.svg) | BootROM → FSBL → PL 编程 → loader → link_check → SD 读 → iNES 解析 → LOAD_EN 流送 → 释放 console，逐段带仿真/从未运行证据标记。 | `tools/ps/boot.bif + tools/ps/build_ps.tcl + tools/ps/sdk_flow.tcl + tools/ps/app/main.c + rtl/platform/zynq/nes_zynq_top.v` | [`modules/ps-rom-load-software.md`](../modules/ps-rom-load-software.md) 图 1 |
| [`ps-usb-gamepad.svg`](ps-usb-gamepad.svg) | 板级 ULPI PHY / hub / Type-A 与 P4 跳线、PS host 模式与枚举、host-tested 纯解析、GAMEPAD 0x20 → OR → 2FF → buttons1，逐段标出从未运行与板级事实。 | `tools/ps/app/usb_gamepad.c + tools/ps/app/usb_hid.h + tools/ps/app/main.c + tools/ps/build_ps.tcl + rtl/platform/zynq/nes_zynq_top.v` | [`modules/ps-usb-gamepad.md`](../modules/ps-usb-gamepad.md) 图 1 |
| [`cart-rom.svg`](cart-rom.svg) | 两个字节宽数组的 $readmemh 初始化、PRG/CHR 读通路，以及 mapper $2007 与 PS 加载共享的单一 muxed 写语句（if/else 会静默落入 distributed RAM）。 | `rtl/nes_core/cart/nes_cart_rom.v` | [`modules/cart-rom.md`](../modules/cart-rom.md) 图 1 |
| [`controller-poll.svg`](controller-poll.svg) | 并联输入、电平敏感 strobe 快照、两路移位寄存器与 8 次读取的位序，EXTRA_READ 的第 9 次策略与 10 周期轮询。 | `rtl/nes_core/controller/nes_controller.v` | [`modules/controller.md`](../modules/controller.md) 图 1 |
| [`ppu-sprite-parallel.svg`](ppu-sprite-parallel.svg) | 64 路并行范围比较、8× nth_set 优先级编码、CHR 取数与 8 路优先选择链，以及为何没有次 OAM / 评估窗口 / 移位寄存器。 | `rtl/nes_core/ppu/nes_ppu_sprite.v` | [`modules/ppu-sprites.md`](../modules/ppu-sprites.md) 图 1 |

## 视觉约定

- 每种语义一种颜色，且在明暗两种 GitHub 主题下都可读：
  蓝色 = 时钟/数据流，绿色 = core_clk 逻辑，橙色 = lcd_clk / 跨域，
  紫色 = 存储器/地址翻译，红色 = 复位/冻结/危险，黄色 = 例外。
- 实线箭头 = 同域数据；虚线箭头 = 跨时钟域或非阻塞关系。
- 圆角框 = 模块；虚线竖线 = 时钟域边界；图例在每张图底部。
- 两类图形：圆角框 + 箭头 = **拓扑**（谁连到谁）；编号阶段 = **顺序**（启动链一类）。
- 顺序图阶段右侧的圆角证据标签：绿色 = 仿真或 host test 已验，
  红色 = 从未运行，黄色 = 板级事实。
- 字体：正文用无衬线，信号名/位宽用等宽。
