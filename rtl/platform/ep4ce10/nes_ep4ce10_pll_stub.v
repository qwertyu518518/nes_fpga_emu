`timescale 1ns/1ps

// ============================================================================
// nes_ep4ce10_pll_stub : PLL 存根（占位，不是 PLL）
// ----------------------------------------------------------------------------
// 本模块不是 altpll，也不实现任何分频、倍频或相移。它存在的唯一目的，是把
// "顶层需要 clk_ntsc 与 clk_vga 两个时钟" 这个接口固定下来，让 Icarus 仿真和
// 端口清单有一个可编译的替身。
//
// 综合时必须用 Quartus MegaWizard 生成的 altpll IP 替换本模块：
//   1. 器件选 EP4CE10F17C8，输入频率填板载晶振实际频率 50 MHz（PIN_E1）。
//   2. clk0 目标约 21.477272 MHz（NTSC NES 主时钟），clk1 目标 25 MHz（VGA）。
//      通道划分、VCO 频率、multiply_by / divide_by / counter / duty_cycle
//      必须由 MegaWizard 与 TimeQuest 确认，候选值与误差见
//      docs/hardware/12-ntsc-clock-and-pll.md 第 3 节，本文不写死数值。
//   3. 生成后打开 IP 文件核对 VCO 频率与每路分频，把实际值回写
//      docs/hardware/12-ntsc-clock-and-pll.md 第 3.3 节，并把 12.3 节的
//      【计算示例（未验证）】替换或确认。
//   4. locked 参与复位组合（各域 sys_rst_n & locked 后在本域同步释放），
//      做法见 docs/hardware/12-ntsc-clock-and-pll.md 第 3.5 节。
//
// 本模块不含任何 vendor primitive（没有 altpll、没有 lpm_*、没有 altera_*），
// 因此可以在没有 Quartus 的机器上编译。它把 clk_in 原样送出，频率不对，
// 仅供占位与端口检查使用，不要用它跑功能仿真。
// ============================================================================

module nes_ep4ce10_pll_stub #(
    parameter integer IN_FREQ_HZ   = 50_000_000,
    parameter integer NTSC_FREQ_HZ = 21_477_272,
    parameter integer VGA_FREQ_HZ  = 25_000_000
) (
    input  wire clk_in,
    input  wire reset_n,
    output wire clk_ntsc,
    output wire clk_vga,
    output wire locked
);

    assign clk_ntsc = clk_in;
    assign clk_vga  = clk_in;
    assign locked   = 1'b1;

endmodule
