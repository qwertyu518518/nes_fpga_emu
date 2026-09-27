# ============================================================================
# op_fpga_emu.sdc —— TimeQuest 时序约束
# ----------------------------------------------------------------------------
# 状态：**未经 TimeQuest 解析或校验**。本机没有安装 Quartus，本文件里没有任何
#       一条约束被 TimeQuest 读过、报过 slack、或者通过过。打开工程后请以
#       TimeQuest 报告为准，不要把这里的数字当作结果。
#       见 quartus/README.md 的"未验证清单"。
#
# 当前状态 = 状态 A：altpll **尚未生成**，clk_ntsc / clk_vga 是顶层的独立输入
# 端口，因此本文件把它们声明成三个独立输入时钟（create_clock），而不是
# create_generated_clock。生成 PLL 之后必须按本文件末尾的 TODO(PLL) 段改写。
#
# 背景与理由：docs/hardware/12-ntsc-clock-and-pll.md 第 6 节（验证步骤）、
#            docs/hardware/03-clock-reset-cdc.md 第 9 节（SDC 检查顺序）。
#
# SDC 是 Tcl。下面的 proc / foreach / set 都是普通 Tcl，TimeQuest 会原样执行。
# ============================================================================


# ---------------------------------------------------------------------------
# 0. 端口名解析
# ---------------------------------------------------------------------------
# 顶层实体有两种合法选择（见 .qsf 的 TOP_LEVEL_ENTITY 与 README 第 4 节）：
#   A. nes_ep4ce10_top     端口是 clk_sys / reset_n / key0..key3 /
#                          vga_hsync / vga_vsync / vga_r / vga_g / vga_b / ...
#   B. nes_ep4ce10_qsf_if  端口是 sys_clk / sys_rst_n / key[3:0] / vga_hs /
#                          vga_vs / vga_rgb[15:0] / led[3:0] / beep / ...
# 下面的 pick_port 按候选顺序取第一个真实存在的端口名，这样同一份 SDC 对两种
# 顶层都能用；换了顶层只改候选顺序，不需要改约束内容。
# 候选都不存在时直接报错，而不是让 create_clock 拿到空集合后在别处炸掉。
#
# 若 Quartus 对"找不到的端口"打印警告，属于预期现象（B 顶层会找不到 clk_sys）。

proc pick_port {args} {
    foreach p $args {
        if {![catch {get_ports $p} names] && [llength $names] > 0} {
            return $p
        }
    }
    error "op_fpga_emu.sdc: 这些端口一个都不存在: $args"
}

set P_SYS_CLK  [pick_port sys_clk clk_sys]
set P_SYS_RSTN [pick_port sys_rst_n reset_n]
set P_NTSC_CLK [pick_port clk_ntsc]
set P_VGA_CLK  [pick_port clk_vga]


# ---------------------------------------------------------------------------
# 1. 时钟声明
# ---------------------------------------------------------------------------
# 板载 50 MHz 晶振。**未验证**：晶体本身有 ±20~±50 ppm 的偏差，TimeQuest 不会
# 自己知道这一点；如果要收紧板级预算，用 set_clock_uncertainty 显式给值，
# 而不是靠 derive_clock_uncertainty 的自动值。
create_clock -name sys_clk -period 20.000 [get_ports $P_SYS_CLK]

# NTSC 主时钟 21.477272 MHz = 1e9 / 21477272 = 46.5608 ns。
# 这是 3.579545 MHz 色度副载波 × 6，是 NES 主时钟，不是 CPU 时钟：核内
# div_phase 再分出 ce_cpu = /12（1.789773 MHz）与 ce_ppu = /4（5.369318 MHz）。
#
# TODO(PLL)：现在是"独立输入端口"，altpll 生成后这两行必须删除，改为
# derive_pll_clocks + 由 TimeQuest 从 IP 自动推出的 generated clock，
# 实际周期以 IP 的 VCO/分频参数为准。见 docs/hardware/12-ntsc-clock-and-pll.md
# 第 3.3、6.2、6.3 节，以及本文件末尾 TODO(PLL)。
create_clock -name clk_ntsc -period 46.5608 [get_ports $P_NTSC_CLK]

# VGA 像素时钟 25 MHz = 800 × 525 = 420000 拍/帧 → 59.52 Hz。
# TODO(PLL)：同上，altpll 生成后删除本行，改为 derived/generated clock。
create_clock -name clk_vga -period 40.000 [get_ports $P_VGA_CLK]

# 自动给每条时钟加不确定度（抖动 + 偏差 + 建立保持余量的粗略估计）。
derive_clock_uncertainty


# ---------------------------------------------------------------------------
# 2. I/O 标准
# ---------------------------------------------------------------------------
# 【厂商例程观察】厂商例程用 "2.5 V" 作为工程级 IO 约束起点。
# **未验证**：引脚所在 bank 的 VCCIO 必须与所选电平匹配，不同 bank 可能不同；
# 按键/LED/蜂鸣器/VGA 是否真的经电平转换、是否需要 3.3-V LVTTL，必须查原理图。
# 这里的写法是"两个顶层都覆盖"：B 顶层按总线名展开每一位，A 顶层按单根端口名。
set IO_STD "2.5 V"

proc io_standard {std names} {
    foreach name $names {
        set nodes [get_ports $name]
        if {[llength $nodes] == 0} {
            set nodes [get_ports "${name}\[*\]"]
        }
        foreach n $nodes {
            set_instance_assignment -name IO_STANDARD $std -to $n
        }
    }
}

io_standard $IO_STD $P_SYS_CLK $P_SYS_RSTN $P_NTSC_CLK $P_VGA_CLK
io_standard $IO_STD vga_hs vga_hsync
io_standard $IO_STD vga_vs vga_vsync
io_standard $IO_STD beep
io_standard $IO_STD key key0 key1 key2 key3
io_standard $IO_STD vga_rgb vga_r vga_g vga_b
io_standard $IO_STD led


# ---------------------------------------------------------------------------
# 3. 异步声明（状态 A 专用）
# ---------------------------------------------------------------------------
# 状态 A 里三个时钟都是独立输入端口，彼此之间没有任何已声明的相位关系。
# 不显式声明的话，TimeQuest 会把域间路径当成未约束端点报出来（而
# docs/hardware/12-ntsc-clock-and-pll.md 第 6.3 节要求未约束端点为 0 或每条
# 都有书面解释）。
#
# TODO(PLL)：**altpll 生成后必须删掉本段。** 那时 clk_ntsc / clk_vga 是 sys_clk
# 的 derived/generated clock，三者不再是"外部互不相关的输入"，Phase Alignment
# 关系由 IP 参数决定。到那时再删掉本段并补上第 5 节末尾 TODO(PLL) 里列的按键
# CDC false_path，否则会漏约束。
set_clock_groups -asynchronous \
    -group {sys_clk} \
    -group {clk_ntsc} \
    -group {clk_vga}


# ---------------------------------------------------------------------------
# 4. false_path：只给两处真正的异步路径
# ---------------------------------------------------------------------------
# (a) 板级异步复位 -> 各域复位同步器的第一级。
#     sys_rst_n 是低有效异步输入：断言本来就是异步的，恢复/移除（recovery /
#     removal）分析在这里没有可约束的对象；复位释放由每个域自己的两级同步器
#     完成（rst_*_q 由 2'b11 逐拍移出 0），那一段是同域同步路径，不该被砍掉。
#     连带效果：也覆盖了 nes_ep4ce10_qsf_if 里 LED 心跳计数器的异步复位。
#     docs/hardware/03-clock-reset-cdc.md 第 5.2 节。
set_false_path -from [get_ports $P_SYS_RSTN]

# 更精确的替代写法（只砍第一级同步器，恢复/移除交给工具报）——**未验证**，
# 寄存器名与层级分隔符要按你的 Quartus 版本在 Node Finder 里确认：
#   set_false_path -to [get_registers {*|rst_sys_q[0]}]
#   set_false_path -to [get_registers {*|rst_ntsc_q[0]}]
#   set_false_path -to [get_registers {*|rst_vga_q[0]}]

# (b) NTSC -> VGA 的 1 bit toggle CDC：行缓冲写域的源寄存器 -> 读域同步器第一级。
#     这是 docs/hardware/12-ntsc-clock-and-pll.md 第 5.1 节列出的"本项目唯一
#     真正过跨域同步器的视频信号"。像素数据本身不出双口 RAM，不需要同步器。
#     寄存器名来自 rtl/nes_core/video/nes_line_buffer_vga.v（line_ready_toggle /
#     toggle_meta / toggle_sync / toggle_seen）。
set_false_path -from [get_registers {*line_ready_toggle}] \
               -to   [get_registers {*toggle_meta}]

# ⚠ false_path **不等于**解决亚稳态（docs/hardware/12-ntsc-clock-and-pll.md
# 第 6.3 节）。下面这条同步器第一级的 max_delay（亚稳态窗口预算）**未验证**，
# 取值方法与是否启用要显式决定后再取消注释：
#   set_max_delay -datapath_only -from [get_registers {*line_ready_toggle}] \
#                 -to [get_registers {*toggle_meta}] 20.0


# ---------------------------------------------------------------------------
# 5. 尚未写的约束（全部是 TODO，不是遗漏）
# ---------------------------------------------------------------------------
# · 输入延迟：key[3:0] / sys_rst_n 的板级走线延迟、上拉与抖动。
#   没有它，TimeQuest 会把输入到首级同步器的路径按 0 延迟算（乐观）。
#   TODO：查原理图走线长度后给 set_input_delay，或明确记录"按 0 处理 + 风险"。
# · 输出延迟：vga_hs / vga_vs / vga_rgb[15:0] / led / beep 是 FPGA 输出到连接器
#   或无源负载，没有外部器件 AC 参数可依。
#   TODO：VGA 侧按"接收端是显示器/电阻网络，无外部时序要求"记录为不约束，
#   还是给一个保守的 set_output_delay，需要显式决定。
# · ce_cpu / ce_ppu 的多周期路径：核内 div_phase 12 拍才动一次的寄存器
#   （/12 的 CPU 域、/4 的 PPU 域）若不告知 STA，TimeQuest 会按 46.5608 ns
#   去要求一条实际有 558.7 ns / 186.2 ns 余量的路径，产生假失败，也可能掩盖
#   真实问题。见 docs/hardware/12-ntsc-clock-and-pll.md 第 6.3 节。
#   **本文件故意没写**：写多周期约束需要逐个寄存器确认更新频率，写错比不写更糟。
#   TODO(PLL) 状态 B 另外还要补：删除第 3 段的 set_clock_groups 之后，
#   按键的 50 MHz -> NTSC 两级同步器（key_stable_q -> btn_meta_q）需要自己的
#   false_path，否则那条跨域路径会变成被错误约束的同步路径：
#   set_false_path -from [get_registers {*key_stable_q}] \
#                  -to   [get_registers {*btn_meta_q}]


# ---------------------------------------------------------------------------
# 6. TODO(PLL)：状态 A -> 状态 B 的改写清单
# ---------------------------------------------------------------------------
# altpll 在 MegaWizard 里生成、加入工程（.qip）之后，按 docs/hardware/
# 12-ntsc-clock-and-pll.md 第 6.2、6.3 节做这些改动：
#   1. 删掉第 1 节里 clk_ntsc / clk_vga 的两条 create_clock。
#   2. 删掉第 3 节的 set_clock_groups（三个时钟不再是外部独立输入）。
#   3. 顶层（或 nes_ep4ce10_qsf_if）里实例化 PLL，把 clk_ntsc / clk_vga 从输入
#      端口改成内部连线，locked 参与复位组合（sys_rst_n & locked 后各域同步释放）。
#   4. 加 derive_pll_clocks，让 TimeQuest 从 IP 自动识别每路输出为 generated
#      clock；再用 report_clock_info 确认每一条的周期与 IP 实际分频一致。
#   5. 补第 5 节的按键 CDC false_path 与 ce_cpu/ce_ppu 多周期约束。
#   6. 把 IP 文件里真实的 VCO 频率、每路 multiply_by / divide_by / counter /
#      duty_cycle 抄回 docs/hardware/12-ntsc-clock-and-pll.md 第 3.3 节，替换
#      那里标着【计算示例（未验证）】的候选值。
#   在完成 1~4 之前，本文件的三个 create_clock 只是"为了让工程能跑起来"的
#   占位，不代表器件上真的有这三颗时钟。
