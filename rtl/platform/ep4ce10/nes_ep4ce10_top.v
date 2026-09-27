`timescale 1ns/1ps

// ============================================================================
// nes_ep4ce10_top : EP4CE10 开拓者板平台顶层（vendor 无关，可综合）
// ----------------------------------------------------------------------------
// 本文件是 docs/hardware/13-platform-top.md 描述的软件 `main` / framebuffer /
// SDL 事件循环三段式结构在硬件上的对应实现：一个自由运行的 NES 核、一个把 NES
// 像素流送到 VGA 连接器的视频链、一路音频 sample 输出、四路带消抖的按键。
// 详细逐条对应关系见该文档，本节只给出实现必须遵守的顶层约束。
//
// 时钟：本模块不做 PLL。
//   clk_ntsc = 21.477272 MHz（NTSC 色度副载波 3.579545 MHz x 6），是 NES 域唯一
//             时钟。nes_system_v4 内部再用 div_phase 12 拍分配 ce_cpu = /12
//             (1.789773 MHz) 与 ce_ppu = /4 (5.369318 MHz)，因此 CPU:PPU 的 3:1
//             比例由构造保证。CPU 域的 1.789773 MHz / 558.7 ns 是 clk_ntsc 的
//             十二分之一，不是本模块的时钟输入。
//   clk_vga  = 25 MHz，驱动 nes_vga_timing 的 800x525 自由运行光栅与行缓冲读端。
//   clk_sys  = 50 MHz 板载晶振（PIN_E1），只用于按键同步与消抖计数。
//   前两个时钟由 EP4CE10 的 altpll IP 在 Quartus 中生成后从顶层引进来，参数必须
//   由 MegaWizard + TimeQuest 确认，详见 docs/hardware/12-ntsc-clock-and-pll.md
//   第 3、6 节；本模块不含任何 vendor primitive、IP 实例化或引脚分配。
//   rtl/platform/ep4ce10/nes_ep4ce10_pll_stub.v 只是占位，不参与综合。
//
// 时钟域：NTSC 域（NES 核 + 行缓冲写口）与 VGA 域（行缓冲读口 + 时序发生器）
// 真正异步，两域之间只有 line_ready_toggle 一个 bit 过两级同步器，见
// docs/hardware/12-ntsc-clock-and-pll.md 第 5 节。clk_sys 域与 NTSC 域之间只传
// 消抖后的按键电平（4 bit 同时翻转），同样用两级同步器。
//
// 复位：reset_n 低有效。每个域各自做"异步断言、同步释放"，域之间不共用复位
// 寄存器，复位只在各自时钟域内传播。
//
// Mapper：本顶层使用 nes_system_v4，即 NROM 期集成（MAPPER_SELECT = 0 的行为，
// PRG 固定 16 KiB 直接映射，$8000-$BFFF 读 PRG、$C000 以上读 0）。nes_system_v4
// 本身没有 MAPPER_SELECT 参数；需要可选 mapper 的集成见 nes_system_v5。
//
// 手柄：key0..key3 低有效，消抖后取反映射到 buttons1 的低四位，位序按 NES 标准
// 手柄：bit0 = A(key0)、bit1 = B(key1)、bit2 = Select(key2)、bit3 = Start(key3)，
// bit4..7 是扩展位，恒 1 表示"未按下"。第二个端口 buttons2 恒为 0xFF（未接）。
// 完整 8 位手柄需要扩展输入，板载 4 键只够 P0 验证，见
// docs/hardware/09-input-and-pins.md 第 5 节。
//
// 视频链：PPU 像素 -> nes_line_buffer_vga（wr 域 = clk_ntsc，rd 域 = clk_vga）
// -> nes_vga_timing（clk_vga）-> RGB565 转 5/6/5 位宽输出。行缓冲写口的 wr_ce
// 必须是 PPU dot 使能（clk_ntsc 的 4 拍一次），不能常 1：PPU 的 pixel_valid 与
// pixel_x 是组合输出，dot 在 4 拍内保持不变，常 1 会让 x = 255 被写 4 次，
// line_ready_toggle 翻转 4 次后回到原值，读端将永远看不到"新的一行"。
// 顶层用一个自由运行的 4 分频产生该使能。它与核内 div_phase 由同一个 rst_ntsc
// 复位，因此从同一条时钟沿开始计数，**相位必须一致**：若两者相差 1~3 拍，被漏掉的
// 恰好是每行第一个 dot，行缓冲的 x = 0 单元将永远不被写，读端第一列会输出 x。
// tb/platform/tb_nes_ep4ce10_top.v 用"pixel_x 严格按 0..255 递增、每行 341 个 dot"
// 这两条断言把相位钉住。
//
// 音频：audio_sample_valid + audio_sample_left 原样送到顶层端口 audio_valid /
// audio_left。valid 是 clk_ntsc 域宽度 1 拍的 strobe，速率等于 ce_cpu
// (1.789773 MHz)，**不是**音频采样率。WM8978 的接法（异步 FIFO + 12.288 MHz
// MCLK 域 + BCLK/LRC 域）属于后续工作，端口留在这里等它接上来，详见
// docs/hardware/08-wm8978-audio.md。
//
// 未接的东西（本顶层有意不做）：TF 卡、SDRAM、WM8978 I2C 配置、复位按键、
// PLL IP、引脚约束。.sdc 与 .qsf 待补，见 docs/hardware/13-platform-top.md 第 6 节。
// ============================================================================

module nes_ep4ce10_top #(
    parameter integer CLK_SYS_HZ         = 50_000_000,
    parameter integer DEBOUNCE_US        = 16_000,
    parameter integer DEBOUNCE_CYCLES    = (CLK_SYS_HZ / 1_000_000) * DEBOUNCE_US,
    parameter integer PPU_CLOCK_ENABLE_DIV = 4,
    parameter integer PRG_SIZE_BYTES     = 16384
) (
    input  wire        clk_sys,
    input  wire        clk_ntsc,
    input  wire        clk_vga,
    input  wire        reset_n,
    input  wire        key0,
    input  wire        key1,
    input  wire        key2,
    input  wire        key3,
    output wire        vga_hsync,
    output wire        vga_vsync,
    output wire        vga_de,
    output wire [4:0]  vga_r,
    output wire [5:0]  vga_g,
    output wire [4:0]  vga_b,
    output wire        audio_valid,
    output wire [15:0] audio_left
);

    localparam integer DEBOUNCE_CNT_BITS = (DEBOUNCE_CYCLES > 1) ? $clog2(DEBOUNCE_CYCLES) : 1;
    localparam [DEBOUNCE_CNT_BITS-1:0] DEBOUNCE_LIMIT = DEBOUNCE_CYCLES - 1;

    // ----------------------------------------------------------------- 复位
    // rst_sys / rst_ntsc / rst_vga 是各域本地复位的**高有效**信号（1 = 处于复位）。
    // 异步断言（reset_n 低直接置 11）、同步释放（0 从低位逐拍移入，2 拍后到达 q[1]）。
    reg [1:0] rst_sys_q;
    reg [1:0] rst_ntsc_q;
    reg [1:0] rst_vga_q;

    always @(posedge clk_sys or negedge reset_n) begin
        if (!reset_n)
            rst_sys_q <= 2'b11;
        else
            rst_sys_q <= {rst_sys_q[0], 1'b0};
    end

    always @(posedge clk_ntsc or negedge reset_n) begin
        if (!reset_n)
            rst_ntsc_q <= 2'b11;
        else
            rst_ntsc_q <= {rst_ntsc_q[0], 1'b0};
    end

    always @(posedge clk_vga or negedge reset_n) begin
        if (!reset_n)
            rst_vga_q <= 2'b11;
        else
            rst_vga_q <= {rst_vga_q[0], 1'b0};
    end

    wire rst_sys  = rst_sys_q[1];
    wire rst_ntsc = rst_ntsc_q[1];
    wire rst_vga  = rst_vga_q[1];

    // ------------------------------------------------------- 按键：同步 + 消抖
    wire [3:0] key_async = {key3, key2, key1, key0};

    reg [3:0] key_meta_q;
    reg [3:0] key_sync_q;
    reg [3:0] key_candidate_q;
    reg [3:0] key_stable_q;
    reg [DEBOUNCE_CNT_BITS-1:0] key_cnt_q;

    always @(posedge clk_sys or negedge reset_n) begin
        if (!reset_n) begin
            key_meta_q <= 4'b1111;
            key_sync_q <= 4'b1111;
        end else begin
            key_meta_q <= key_async;
            key_sync_q <= key_meta_q;
        end
    end

    always @(posedge clk_sys or negedge reset_n) begin
        if (!reset_n) begin
            key_candidate_q <= 4'b1111;
            key_stable_q    <= 4'b1111;
            key_cnt_q       <= {DEBOUNCE_CNT_BITS{1'b0}};
        end else if (key_sync_q == key_candidate_q) begin
            key_cnt_q <= {DEBOUNCE_CNT_BITS{1'b0}};
        end else if (key_cnt_q == DEBOUNCE_LIMIT) begin
            key_candidate_q <= key_sync_q;
            key_stable_q    <= key_sync_q;
            key_cnt_q       <= {DEBOUNCE_CNT_BITS{1'b0}};
        end else begin
            key_cnt_q <= key_cnt_q + 1'b1;
        end
    end

    reg [3:0] btn_meta_q;
    reg [3:0] btn_sync_q;

    always @(posedge clk_ntsc or negedge reset_n) begin
        if (!reset_n) begin
            btn_meta_q <= 4'b1111;
            btn_sync_q <= 4'b1111;
        end else begin
            btn_meta_q <= key_stable_q;
            btn_sync_q <= btn_meta_q;
        end
    end

    wire [3:0] btn_pressed = ~btn_sync_q;

    wire [7:0] buttons1 = {4'b1111, btn_pressed[3], btn_pressed[2], btn_pressed[1], btn_pressed[0]};
    wire [7:0] buttons2 = 8'hFF;

    // ------------------------------------------------- PPU dot 使能（写口时钟）
    localparam integer PPU_CE_BITS = (PPU_CLOCK_ENABLE_DIV > 1) ?
                                     $clog2(PPU_CLOCK_ENABLE_DIV) : 1;

    reg [PPU_CE_BITS-1:0] ppu_ce_div_q;

    always @(posedge clk_ntsc or posedge rst_ntsc) begin
        if (rst_ntsc)
            ppu_ce_div_q <= {PPU_CE_BITS{1'b0}};
        else
            ppu_ce_div_q <= ppu_ce_div_q + 1'b1;
    end

    wire ppu_ce = (ppu_ce_div_q == {PPU_CE_BITS{1'b0}});

    // ------------------------------------------------------------- NES 核
    wire       ppu_pixel_valid;
    wire [7:0] ppu_pixel_x;
    wire [7:0] ppu_pixel_y;
    wire [3:0] ppu_pixel_index;
    wire       nes_frame_done;
    wire       nes_vblank;
    wire       nes_nmi_o;
    wire       nes_apu_irq_o;
    wire       nes_audio_valid;
    wire [15:0] nes_audio_left;

    nes_system_v4 #(
        .PRG_SIZE_BYTES(PRG_SIZE_BYTES)
    ) u_nes (
        .clk               (clk_ntsc),
        .reset             (rst_ntsc),
        .buttons1          (buttons1),
        .buttons2          (buttons2),
        .pixel_valid       (ppu_pixel_valid),
        .pixel_x           (ppu_pixel_x),
        .pixel_y           (ppu_pixel_y),
        .pixel_index       (ppu_pixel_index),
        .frame_done        (nes_frame_done),
        .vblank            (nes_vblank),
        .nmi_o             (nes_nmi_o),
        .apu_irq_o         (nes_apu_irq_o),
        .audio_sample_valid(nes_audio_valid),
        .audio_sample_left (nes_audio_left)
    );

    // -------------------------------------------------------- 行缓冲（跨域）
    wire        lb_line_ready_toggle;
    wire        lb_line_done;
    wire        lb_line_valid;
    wire        lb_line_read_start;
    wire [8:0]  lb_read_x;
    wire [15:0] lb_rgb565;

    nes_line_buffer_vga #(
        .REPEAT_LINE(1)
    ) u_lb (
        .wr_clk            (clk_ntsc),
        .wr_reset          (rst_ntsc),
        .wr_ce             (ppu_ce),
        .wr_pixel_valid    (ppu_pixel_valid),
        .wr_x              (ppu_pixel_x),
        .wr_index          (ppu_pixel_index),
        .line_ready_toggle (lb_line_ready_toggle),
        .line_done         (lb_line_done),
        .rd_clk            (clk_vga),
        .rd_reset          (rst_vga),
        .rd_ce             (1'b1),
        .frame_line_valid  (lb_line_valid),
        .line_read_start   (lb_line_read_start),
        .read_x            (lb_read_x),
        .read_rgb565       (lb_rgb565)
    );

    // ---------------------------------------------------------- VGA 时序
    wire [15:0] vga_rgb565;
    wire [9:0]  vga_hcount;
    wire [9:0]  vga_vcount;
    wire        vga_active_pixels;
    wire        vga_frame_pulse;

    nes_vga_timing u_vga (
        .clk            (clk_vga),
        .reset          (rst_vga),
        .ce             (1'b1),
        .line_read_start(lb_line_read_start),
        .px_valid       (lb_line_valid),
        .px_rgb565      (lb_rgb565),
        .hsync          (vga_hsync),
        .vsync          (vga_vsync),
        .de             (vga_de),
        .rgb565         (vga_rgb565),
        .hcount         (vga_hcount),
        .vcount         (vga_vcount),
        .active_pixels  (vga_active_pixels),
        .frame_pulse    (vga_frame_pulse),
        .line_read_sync ()
    );

    assign vga_r = vga_rgb565[15:11];
    assign vga_g = vga_rgb565[10:5];
    assign vga_b = vga_rgb565[4:0];

    // ------------------------------------------------------------- 音频
    assign audio_valid = nes_audio_valid;
    assign audio_left  = nes_audio_left;

endmodule
