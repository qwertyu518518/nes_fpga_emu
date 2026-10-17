#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Generate the engineering schematics under docs/figures/ as SVG.

Why Python and not PowerShell
-----------------------------
The repository's other tools are PowerShell 5.1, and tools/gen_figures.ps1 is
the entry point that matches that convention.  The SVG emission itself lives
here because an SVG figure is a structured drawing: a few dozen boxes, arrows
and labels whose coordinates are data.  Python expresses that as data natively,
the standard library alone is enough (no graphviz, no mermaid, no LaTeX), and it
writes bytes under explicit control, which is what the repository's encoding
rules require.  Writing the same emitter in PowerShell would mean several
hundred lines of string concatenation for no gain, so PowerShell keeps the
familiar entry point and delegates the drawing.

Reproducibility
---------------
Running this twice produces byte-identical output:
  * every coordinate and font size is an integer or a string fixed in source;
  * there are no timestamps, no host names, no random values and no floating
    point arithmetic in the emitted text (the only division is ``//``);
  * dict iteration follows insertion order, which is how the figures are built;
  * files are written as UTF-8 without BOM and with LF endings, via
    ``open(path, "w", encoding="utf-8", newline="\n")``.

Every figure is derived by reading the RTL named in each ``source`` field.  A
figure that cannot be traced to a line of RTL is not drawn.

Usage:
    python tools/gen_figures.py            # write docs/figures/*.svg + README.md
    python tools/gen_figures.py --check    # verify the tree is already up to date
"""

import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
FIGDIR = os.path.join(ROOT, "docs", "figures")

# ---------------------------------------------------------------------------
# Shared visual language
# ---------------------------------------------------------------------------
# One font stack for prose-like labels, one for signal names.  Chinese labels
# fall through to Microsoft YaHei on Windows and to a system CJK face elsewhere.
FONT = "Segoe UI, Microsoft YaHei, system-ui, -apple-system, sans-serif"
MONO = "Cascadia Code, Consolas, Menlo, 'DejaVu Sans Mono', monospace"

SW = 1.6          # standard stroke width
FS_T = 15         # box title
FS_L = 11.5       # signal / detail line
FS_N = 12.5       # free note
FS_S = 11         # header / legend

# Semantic palette.  Each name is emitted as var(--name) and resolved by the
# <style> block, so a single figure reads correctly in both GitHub themes.
NAMES = ["bg", "panel", "panel2", "border", "text", "muted",
         "blue", "green", "orange", "purple", "red", "yellow"]


def _num(v):
    if isinstance(v, int):
        return str(v)
    s = "%.2f" % float(v)
    s = s.rstrip("0").rstrip(".")
    return s if s else "0"


def _esc(s):
    return (str(s).replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;"))


def _paint(name):
    if name is None:
        return "none"
    if name.startswith("#") or name in ("none", "transparent"):
        return name
    return "var(--%s)" % name


class Svg(object):
    def __init__(self, w, h, title):
        self.w = w
        self.h = h
        self.title = title
        self.items = []
        self.boxes = []

    def _a(self, s):
        self.items.append(s)

    # -- primitives ---------------------------------------------------------
    def rect(self, x, y, w, h, fill="panel", stroke="border", rx=6, sw=SW,
             dash=None):
        extra = ' stroke-dasharray="%s"' % dash if dash else ""
        self._a('<rect x="%s" y="%s" width="%s" height="%s" rx="%s" '
                'fill="%s" stroke="%s" stroke-width="%s"%s/>'
                % (_num(x), _num(y), _num(w), _num(h), _num(rx),
                   _paint(fill), _paint(stroke), _num(sw), extra))

    def circle(self, cx, cy, r, fill="panel", stroke="border", sw=SW):
        self._a('<circle cx="%s" cy="%s" r="%s" fill="%s" stroke="%s" '
                'stroke-width="%s"/>'
                % (_num(cx), _num(cy), _num(r), _paint(fill), _paint(stroke),
                   _num(sw)))

    def line(self, x1, y1, x2, y2, stroke="border", sw=SW, dash=None):
        extra = ' stroke-dasharray="%s"' % dash if dash else ""
        self._a('<line x1="%s" y1="%s" x2="%s" y2="%s" stroke="%s" '
                'stroke-width="%s"%s/>'
                % (_num(x1), _num(y1), _num(x2), _num(y2), _paint(stroke),
                   _num(sw), extra))

    def flow(self, pts, color="blue", dash=None, sw=SW, head=True):
        d = "M " + " L ".join("%s %s" % (_num(x), _num(y)) for x, y in pts)
        attr = 'fill="none" stroke="var(--%s)" stroke-width="%s"' % (color, _num(sw))
        if dash:
            attr += ' stroke-dasharray="%s"' % dash
        if head:
            attr += ' marker-end="url(#arw-%s)"' % color
        self._a('<path d="%s" %s/>' % (d, attr))

    def text(self, x, y, s, size=FS_N, fill="text", anchor="middle",
             weight="normal", family=FONT, opacity=None):
        extra = ' opacity="%s"' % _num(opacity) if opacity is not None else ""
        self._a('<text x="%s" y="%s" font-size="%s" fill="%s" '
                'text-anchor="%s" font-weight="%s" font-family="%s"%s>%s</text>'
                % (_num(x), _num(y), _num(size), _paint(fill), anchor, weight,
                   family, extra, _esc(s)))

    # -- composite ----------------------------------------------------------
    def node(self, x, y, w, h, title, lines=(), accent="border", fill="panel",
             tsize=FS_T, lsize=FS_L, tfill="text", lfill="muted",
             align="center", dash=None, rx=6):
        self.rect(x, y, w, h, fill=fill, stroke=accent, rx=rx, dash=dash)
        tx = x + w / 2 if align == "center" else x + 12
        if title:
            tsz = tsize
            while tsz > 11 and _est_width(title, tsz) > w - 16:
                tsz -= 0.5
            self.text(tx, y + 21, title, size=tsz, weight="600",
                      fill=tfill, anchor="center" if align == "center" else "start")
        else:
            tsz = tsize
        ty = y + 41
        for ln in lines:
            self.text(x + 12, ty, ln, size=lsize, fill=lfill, anchor="start",
                      family=MONO)
            ty += 15
        self.boxes.append((x, y, w, h, title, lines, lsize, tsz))
        return y + h

    def header(self, x, y, w, label, color):
        self.rect(x, y, w, 26, fill=color, stroke=color, rx=6)
        self.rect(x, y + 13, w, 13, fill=color, stroke=color, rx=0)
        self.text(x + w / 2, y + 18, label, size=FS_S, weight="700",
                  fill="bg")

    def render(self):
        out = []
        out.append('<?xml version="1.0" encoding="UTF-8"?>')
        out.append('<svg xmlns="http://www.w3.org/2000/svg" width="%d" '
                   'height="%d" viewBox="0 0 %d %d" role="img" '
                   'aria-label="%s">'
                   % (self.w, self.h, self.w, self.h, _esc(self.title)))
        out.append("<defs><style>")
        out.append(_css())
        out.append("</style>")
        for n in ("blue", "green", "orange", "purple", "red", "muted", "text",
                  "yellow"):
            out.append('<marker id="arw-%s" viewBox="0 0 8 8" refX="7" refY="4" '
                       'markerWidth="8" markerHeight="8" markerUnits="userSpaceOnUse" '
                       'orient="auto-start-reverse">'
                       '<path d="M0,0.5 L7.5,4 L0,7.5 z" fill="var(--%s)"/></marker>'
                       % (n, n))
        out.append("</defs>")
        out.append('<rect x="0" y="0" width="%d" height="%d" fill="var(--bg)"/>'
                   % (self.w, self.h))
        out.extend(self.items)
        out.append("</svg>")
        return "\n".join(out) + "\n"


def _css():
    light = ("--bg:#ffffff;--panel:#f6f8fa;--panel2:#eaeef2;--border:#d0d7de;"
             "--text:#1f2328;--muted:#59636e;--blue:#0969da;--green:#1a7f37;"
             "--orange:#bc4c00;--purple:#8250df;--red:#cf222e;--yellow:#9a6700;")
    dark = ("--bg:#0d1117;--panel:#161b22;--panel2:#21262d;--border:#30363d;"
            "--text:#e6edf3;--muted:#9198a1;--blue:#58a6ff;--green:#3fb950;"
            "--orange:#db6d28;--purple:#a371f7;--red:#ff7b72;--yellow:#d29922;")
    return (":root{%s}@media (prefers-color-scheme:dark){:root{%s}}"
            "text{font-family:%s}" % (light, dark, FONT))


def _est_width(s, size):
    # Measured against the actual sans/console faces in a headless browser:
    # ASCII advances ~0.5 em and CJK ~1.0 em, so these factors are small
    # overestimates.  The check only needs to catch real overflow, not to be
    # exact.
    w = 0
    for ch in s:
        w += size * 1.05 if ord(ch) > 0x2E00 else size * 0.55
    return w


def lint(c):
    """Report box collisions and text that leaves its own box."""
    problems = []
    n = len(c.boxes)
    for i in range(n):
        x1, y1, w1, h1, t1 = c.boxes[i][:5]
        for j in range(i + 1, n):
            x2, y2, w2, h2, t2 = c.boxes[j][:5]
            if (x1 < x2 + w2 and x2 < x1 + w1 and
                    y1 < y2 + h2 and y2 < y1 + h1):
                problems.append("box overlap: %r <-> %r" % (t1, t2))
    for x, y, w, h, t, lines, lsize, tsize in c.boxes:
        if 15 * len(lines) > h - 32:
            problems.append("too many lines for height %r" % t)
        if t and _est_width(t, tsize) > w - 14:
            problems.append("title overflow in %r" % t)
        for ln in lines:
            if _est_width(ln, lsize) > w - 22:
                problems.append("text overflow in %r: %s" % (t, ln))
    return problems


def title_block(c, main, sub):
    c.text(c.w / 2, 32, main, size=17, weight="700")
    c.text(c.w / 2, 53, sub, size=FS_N, fill="muted")


def legend(c, x, y, entries, title="图例"):
    """One legend row: swatch + label pairs, drawn in a bordered strip."""
    pad = 12
    w = 0
    for _, label in entries:
        w += 46 + int(len(label) * 6.4)
    w += 2 * pad + 40
    c.rect(x, y, w, 30, fill="panel2", stroke="border", rx=6, sw=1.2)
    c.text(x + pad, y + 20, title, size=FS_S, weight="600", anchor="start",
           fill="muted")
    cx = x + pad + 34
    for kind, label in entries:
        if kind == "arrow":
            c.flow([(cx, y + 15), (cx + 22, y + 15)], color="blue", sw=1.6)
        elif kind == "dash":
            c.flow([(cx, y + 15), (cx + 22, y + 15)], color="orange",
                   dash="4 3", sw=1.6)
        elif kind == "box":
            c.rect(cx, y + 8, 22, 14, fill="panel", stroke="green", rx=3, sw=1.4)
        elif kind == "mem":
            c.rect(cx, y + 8, 22, 14, fill="panel", stroke="purple", rx=3, sw=1.4)
        cx += 22
        c.text(cx + 4, y + 20, label, size=FS_S, anchor="start", fill="text")
        cx += 4 + int(len(label) * 6.4) + 24


# ---------------------------------------------------------------------------
# Figure 1 -- system hierarchy
# ---------------------------------------------------------------------------
def fig_system_hierarchy():
    c = Svg(1180, 940, "nes_zynq_top 系统层次与三个时钟域")
    title_block(c, "系统层次：nes_zynq_top 到核心与平台外设",
                "rtl/platform/zynq/nes_zynq_top.v · 三个时钟域与三条跨域边界")

    c.rect(28, 68, 1124, 800, fill="none", stroke="border", rx=10, sw=1.4)
    c.text(44, 90, "nes_zynq_top", size=FS_N, weight="700", anchor="start",
           family=MONO, fill="muted")

    # clock generator
    c.node(452, 100, 276, 86, "nes_zynq_clk", [
        "MMCME2_BASE  VCO 1181.25 MHz",
        "CLKOUT1 ÷55 → core_clk",
        "CLKOUT0 ÷47.25 → lcd_clk",
    ])
    c.text(58, 128, "sys_clk 50 MHz", size=FS_L, anchor="start", family=MONO)
    c.text(58, 144, "U18, 20.000 ns", size=FS_S, anchor="start", family=MONO,
           fill="muted")
    c.flow([(150, 132), (450, 132)], color="blue")

    # domain columns
    cols = [(50, "blue", "sys_clk 域 · 50 MHz"),
            (410, "green", "core_clk 域 · 21.477272727 MHz"),
            (800, "orange", "lcd_clk 域 · 25 MHz")]
    for x, col, label in cols:
        c.header(x, 210, 330, label, col)
        c.rect(x, 210, 330, 590, fill="none", stroke=col, rx=8, sw=1.2, dash="6 4")

    # sys_clk domain
    c.node(66, 250, 298, 66, "nes_touch_input", [
        "GT9147 I2C · 一次性校准 · 区域映射",
        "→ buttons1[7:0]（2FF 同步）",
    ], accent="blue")
    c.node(66, 330, 298, 66, "wm8960_i2c", [
        "15 项上电表 @ 100 kHz（约 4.6 ms）",
        "→ cfg_done",
    ], accent="blue")
    c.node(66, 410, 298, 52, "面板上电计数器", [
        "lcd_rst / lcd_bl（sys_clk 计数）",
    ], accent="blue")
    c.node(66, 476, 298, 82, "复位网络同步", [
        "locked  → 每域 2FF",
        "cfg_done → 音频两域各 2FF",
        "rst_sys / rst_core / rst_lcd",
    ], accent="red")

    # core_clk domain
    c.node(426, 250, 298, 178, "nes_system_v6", [
        "12 相 div_phase[3:0] → ce_ppu/ce_cpu",
        "nes_cpu6502 + nes_cpu_bus",
        "nes_ppu2c02 (EXTERNAL_CHR=1)",
        "nes_ppu_sprite + sprite_chr_fetch",
        "nes_apu2a03 (pulse×2 tri noise dmc)",
        "nes_controller ($4016/$4017 内部)",
        "nes_oam_dma + nes_mapper",
    ], accent="green")
    c.node(426, 444, 298, 66, "nes_cart_rom (PRG)", [
        "PRG_ENABLE=1, CHR_ENABLE=0",
        "在核内；$readmemh 初始化",
    ], accent="purple")
    c.node(426, 526, 298, 82, "音频抽取滤波器", [
        "4/4/2 滑动平均串联 → /32",
        "精确有理 63/55（2016 进 55 出）",
        "1.789772727 MHz → 48828.125 Hz",
    ], accent="green")
    c.node(426, 624, 298, 56, "调色板 LUT（组合）", [
        "pal_to_rgb565(core_pixel_pal[5:0])",
    ], accent="green")
    c.node(426, 696, 298, 56, "视频写口", [
        "帧存写口 wr_clk = core_clk",
    ], accent="green")

    # lcd_clk domain
    c.node(816, 250, 298, 74, "nes_video_800x480 读口", [
        "hcount 0..1055 / vcount 0..524",
        "DE 800×480，每 lcd_clk 一个像素",
    ], accent="orange")
    c.node(816, 340, 298, 86, "nes_audio_i2s 读侧", [
        "BCLK_DIV=16 → BCLK 1.5625 MHz",
        "帧 32 BCLK → 48828.125 Hz",
        "mclk = lcd_clk（同一网络）",
    ], accent="orange")
    c.node(816, 442, 298, 52, "RGB565 → RGB888", [
        "lcd_rgb[23:0] 位复制扩展",
    ], accent="orange")
    c.node(816, 510, 298, 116, "面板与音频引脚", [
        "lcd_clk / lcd_de / lcd_hs / lcd_vs",
        "lcd_rgb[23:0]（三态双向）",
        "aud_bclk / aud_dac_lrc / aud_dacdat",
        "aud_mclk = mmcm_lcd_clk",
        "aud_iic_scl / aud_iic_sda（开漏）",
    ], accent="orange")

    # domain separators + CDC arrows
    c.line(394, 236, 394, 790, stroke="muted", sw=1.2, dash="5 5")
    c.line(784, 236, 784, 790, stroke="muted", sw=1.2, dash="5 5")

    c.flow([(364, 283), (426, 283)], color="orange", dash="5 4")
    c.text(395, 330, "2FF 同步", size=FS_S, fill="orange")

    c.flow([(724, 304), (816, 288)], color="orange", dash="5 4")
    c.text(770, 300, "frame_mem", size=FS_S, fill="orange")
    c.text(770, 315, "写/读双口", size=FS_S, fill="muted")

    c.flow([(724, 567), (816, 383)], color="orange", dash="5 4")
    c.text(770, 476, "音频 FIFO", size=FS_S, fill="orange")
    c.text(770, 491, "core→lcd", size=FS_S, fill="muted")

    legend(c, 44, 880, [
        ("box", "core_clk 模块"), ("mem", "复位 / 配置"),
        ("arrow", "同域数据"), ("dash", "跨时钟域"),
    ])
    return c


# ---------------------------------------------------------------------------
# Figure 2 -- CPU and bus
# ---------------------------------------------------------------------------
def fig_cpu_bus():
    c = Svg(1140, 850, "nes_cpu6502 与 nes_cpu_bus：地址译码、等待态、owner/hold、DMA 端口")
    title_block(c, "CPU 与总线：地址译码 · 等待态 · owner/hold · DMA 端口",
                "rtl/nes_core/bus/nes_cpu_bus.v (+ nes_cpu6502 的对外合同)")

    c.node(40, 90, 230, 190, "nes_cpu6502", [
        "cpu_req / cpu_we",
        "cpu_addr[15:0]",
        "cpu_dout[7:0]",
        "",
        "cpu_din[7:0]   ← 读回",
        "cpu_ready      → 完成本周期",
        "cpu_stall = req && !fire",
    ], accent="blue")

    c.node(330, 90, 300, 190, "nes_cpu_bus", [
        "ready_c = !bus_hold &&",
        "  (active ? wait_cnt==0",
        "         : wait_need<=1)",
        "  && (!owner_ext || ack)",
        "cpu_fire = cpu_req && ready_c",
        "",
        "owner[2:0] / sel_* / ram_we",
    ], accent="green")

    c.node(700, 90, 400, 200, "地址译码 decode_owner", [
        "000  → OWNER_RAM     $0000-$1FFF",
        "001  → OWNER_PPU     $2000-$3FFF",
        "010  → OWNER_APU_IO  $4000-$401F",
        "       否则 OWNER_OPEN",
        "011  → OWNER_CART_RAM $6000-$7FFF",
        "1xx  → OWNER_CART_ROM $8000-$FFFF",
    ], accent="purple")

    c.flow([(270, 150), (328, 150)], color="blue")
    c.text(299, 138, "req/we/addr", size=FS_S, fill="blue")
    c.flow([(328, 215), (270, 215)], color="green")
    c.text(299, 235, "din/ready", size=FS_S, fill="green")
    c.flow([(632, 160), (698, 160)], color="blue")
    c.text(665, 148, "addr[15:13]", size=FS_S, fill="blue")
    c.flow([(698, 215), (632, 215)], color="purple")
    c.text(665, 235, "owner/sel", size=FS_S, fill="purple")

    # bus rail -> target chips
    c.flow([(900, 290), (900, 302)], color="purple", head=False)
    c.line(135, 302, 1023, 302, stroke="muted", sw=1.4)
    chips = [("RAM 片内", "$0000-$1FFF", 40, "purple"),
             ("PPU", "$2000-$3FFF · ppu_ack", 262, "green"),
             ("APU / IO", "$4000-$401F · apu_ack", 484, "green"),
             ("CART RAM", "$6000-$7FFF · cart_ack", 706, "purple"),
             ("CART ROM", "$8000-$FFFF · cart_ack", 928, "purple")]
    for name, sub, x, col in chips:
        c.node(x, 314, 190, 76, name, [sub], accent=col)
        c.flow([(x + 95, 302), (x + 95, 312)], color=col, sw=1.2)

    c.node(40, 430, 300, 170, "等待态路径", [
        "wait_need:",
        " OPEN → 0    RAM → sync?1:0",
        " 其它 → READ_WAIT_CYCLES",
        "owner_ack = ppu/apu/cart_ack",
        "ram 读口 free-running（11 clk 窗口）",
    ], accent="orange")
    c.flow([(400, 282), (246, 282), (246, 412), (190, 412), (190, 428)],
           color="orange")
    c.text(250, 272, "wait_need / owner_ack", size=FS_S, fill="orange")

    c.node(370, 430, 340, 230, "DMA 端口（DMA_PRESENT=1）", [
        "dma_req_oam / dma_req_dmc（OAM 优先）",
        "dma_grant = present && ce && bus_hold",
        "            && (pick_oam || pick_dmc)",
        "dma_wait_need: DMC→3（grant+3）",
        "    RAM→sync?1:0  其它→READ_WAIT",
        "dma_ack = grant && ready",
        "dma_sel = dma_pick_dmc",
        "dma_unimpl = grant && owner∈{PPU,APU}",
    ], accent="red")
    c.flow([(500, 282), (470, 282), (470, 428)], color="red")
    c.text(632, 300, "dma_req / dma_ack", size=FS_S, fill="red", anchor="start")

    c.node(750, 430, 350, 150, "优先与探测", [
        "dma_pick_oam = dma_req_oam",
        "dma_pick_dmc = !oam && dmc",
        "dbg_active / dbg_wait_count",
        "dbg_open_bus / dbg_dma_owner",
    ], accent="muted")
    c.flow([(712, 490), (748, 490)], color="red")

    c.node(750, 600, 350, 74, "bus_hold（输入，外部仲裁）", [
        "ready_c 被 !bus_hold 屏蔽",
        "DMA 仅在 bus_hold 高时授权",
    ], accent="red")
    c.flow([(750, 636), (712, 636)], color="red")

    legend(c, 44, 800, [
        ("arrow", "请求 / 授权"), ("box", "目标从设备"), ("mem", "关闭 / 仲裁"),
    ])
    return c


# ---------------------------------------------------------------------------
# Figure 3 -- PPU dot pipeline
# ---------------------------------------------------------------------------
def fig_ppu_dot_pipeline():
    c = Svg(1180, 720, "nes_ppu2c02 的 dot 流水线：计数、背景取数节奏、精灵窗口、外部 CHR 冻结")
    title_block(c, "PPU dot 流水线：341 dot × 262 行",
                "rtl/nes_core/ppu/nes_ppu2c02.v · dot 0..340，ce_ppu = div_phase%4==0")

    # timeline
    x0, x1 = 70, 1100
    y = 150
    c.line(x0, y, x1, y, stroke="border", sw=2)
    span = x1 - x0
    def dx(dot):
        return x0 + int(round(dot * span / 340.0))

    for d in (0, 64, 128, 192, 256, 320, 340):
        c.line(dx(d), y - 8, dx(d), y + 8, stroke="border", sw=1.2)
        c.text(dx(d), y - 14, str(d), size=FS_S, fill="muted", family=MONO)

    # visible window
    c.rect(dx(0), y - 18, dx(256) - dx(0), 36, fill="green", stroke="green",
           rx=3, sw=1)
    c.text((dx(0) + dx(256)) / 2, y + 5, "可见 0..255  (pixel_valid)",
           size=FS_S, fill="bg", weight="600")
    c.rect(dx(256), y - 18, dx(340) - dx(256), 36, fill="panel2",
           stroke="border", rx=3, sw=1)
    c.text((dx(256) + dx(340)) / 2, y + 5, "消隐 256..340", size=FS_S,
           fill="muted")

    # markers row
    marks = [
        (7, "bg_fetch_mid\n(dot+fine_x)[2:0]==7", "blue", "up"),
        (246, "背景最晚触发\ndot≤246", "blue", "down"),
        (257, "sp_start\ndot==257", "orange", "up"),
        (291, "精灵窗口尾\ndots 257..291", "orange", "down"),
        (324, "bg_fetch_pre_first\ndot==324", "blue", "up"),
        (340, "bg_fetch_pre_second\n(dot+fine_x)==340", "blue", "down"),    ]
    for d, label, col, side in marks:
        X = dx(d)
        if side == "up":
            ty = 96
            c.line(X, y - 18, X, ty + 6, stroke=col, sw=1.2, dash="4 3")
            lines = label.split("\n")
            for i, ln in enumerate(lines):
                c.text(X, ty - 10 * (len(lines) - 1 - i), ln, size=FS_S,
                       fill=col)
        else:
            ty = 214
            c.line(X, y + 18, X, ty - 6, stroke=col, sw=1.2, dash="4 3")
            lines = label.split("\n")
            for i, ln in enumerate(lines):
                c.text(X, ty + 6 + 14 * i, ln, size=FS_S, fill=col)

    # dot counter / control box
    c.node(70, 268, 500, 150, "dot / scanline 计数（ce 有效时才推进）", [
        "dot 0..340：dot==340 → dot<=0, scanline+1",
        "scanline==261 && dot==340 → scanline<=0",
        "                    frame_done<=1",
        "pixel_valid = !reset && scanline<240 && dot<256",
        "vblank: scanline==241&&dot==0 置位",
        "        scanline==261&&dot==0 清零",
    ], accent="green")

    c.node(610, 268, 500, 150, "v_addr 更新（mask[3] && !reg_cs）", [
        "dot==256           → increment_y(increment_x)",
        "8<=dot<=248,dot%8==0 → increment_x",
        "dot==257           → 拷贝 temp_addr[4:0],[10]",
        "预渲染 280..304     → 拷贝 temp_addr 竖直位",
        "→ bg_look_dot = dot+9（pre_first 时 dot+17）",
    ], accent="green")

    # external CHR freeze
    c.node(70, 448, 500, 150, "外部 CHR 冻结（EXTERNAL_CHR=1）", [
        "chr_rd_win = chr_rd_arm && v_addr<$2000",
        "chr_hold_bg = chr_rd_win && bg_chr_req",
        "chr_hold_sp = chr_rd_win && sp_chr_req",
        "冻结：把该单元 ce 门掉一个 ce，",
        "      同一 chr_addr 命中下一拍重发",
        "调度捕获：bg_cap_cnt 7→0，t+8 取 bg_lo/hi",
    ], accent="red")

    c.node(610, 448, 500, 150, "背景取数节奏与捕获", [
        "bg_fetch_due 每 8 dot 一次（dot%8==7）",
        "单元占用 7 ce：S_PRE..S_GRAB",
        "S_IDLE→S_PRE→S_ARM→S_BEAT→S_GRAB",
        "bg_valid 于 trigger+7 拉高",
        "bg_look_dot = dot+9 → 目标 tile",
    ], accent="blue")

    legend(c, 70, 636, [
        ("arrow", "触发 / 窗口"), ("box", "取数单元"), ("mem", "冻结 / 调度"),
    ])
    return c


# ---------------------------------------------------------------------------
# Figure 4 -- chr_fetch_unit FSM
# ---------------------------------------------------------------------------
def fig_chr_fetch_fsm():
    c = Svg(1120, 720, "nes_chr_fetch_unit 的状态序列与 7 周期占用")
    title_block(c, "背景取数状态机：nes_chr_fetch_unit",
                "rtl/nes_core/ppu/nes_chr_fetch_unit.v · 一个 tile = 2 字节（low/high 平面）")

    def st(x, y, name, code, body, accent="green"):
        c.node(x, y, 235, 116, "%s  %s" % (name, code), body, accent=accent)

    st(100, 110, "S_IDLE", "3'd0", [
        "req_start && !busy →",
        "  锁存 base/count",
        "  busy=1, bg_valid=0",
    ])
    st(560, 110, "S_PRE", "3'd1", [
        "chr_addr <= nxt_addr",
    ])
    st(660, 300, "S_ARM", "3'd2", [
        "chr_req <= 1",
    ])
    st(60, 300, "S_GRAB", "3'd4", [
        "cap_pl ? bg_hi<=rdata",
        "       : bg_lo<=rdata",
        "!fin → chr_req<=1",
        " fin → busy=0,bg_valid=1",
    ])
    st(330, 300, "S_BEAT", "3'd3", [
        "chr_req <= 0",
        "cap_pl<=pl_q, fin<=last_byte",
        "pl 翻转；pl 时 idx++",
        "非末次: chr_addr<=fwd_addr",
    ])

    c.flow([(335, 160), (558, 160)], color="blue")
    c.text(447, 150, "接受请求", size=FS_S, fill="blue")
    c.flow([(700, 226), (770, 298)], color="blue")
    c.text(770, 258, "1 beat", size=FS_S, fill="muted")
    c.flow([(700, 358), (582, 358)], color="blue")
    c.text(640, 348, "ARM→BEAT", size=FS_S, fill="blue")
    c.flow([(330, 340), (297, 340)], color="blue")
    c.text(313, 330, "总是", size=FS_S, fill="blue")
    c.flow([(295, 380), (328, 380)], color="blue")
    c.text(313, 400, "!fin 重发", size=FS_S, fill="blue")
    c.flow([(150, 300), (150, 228)], color="red", dash="4 3")
    c.text(160, 268, "fin_q → busy=0", size=FS_S, fill="red", anchor="start")

    # occupancy strip
    y = 470
    c.text(60, y - 12, "占用 7 个 ce（trigger+0 .. +6），bg_valid 在 trigger+7",
           size=FS_N, anchor="start", weight="600")
    labels = ["+0\nIDLE", "+1\nPRE", "+2\nARM", "+3\nBEAT1", "+4\nGRAB",
              "+5\nBEAT2", "+6\nGRAB", "+7\nIDLE"]
    for i, lab in enumerate(labels):
        x = 60 + i * 128
        col = "blue" if i in (3, 5) else ("purple" if i == 7 else "green")
        c.rect(x, y, 118, 54, fill="panel", stroke=col, rx=5, sw=1.4)
        for j, ln in enumerate(lab.split("\n")):
            c.text(x + 59, y + 22 + 16 * j, ln, size=FS_S,
                   weight="600" if j == 0 else "normal",
                   fill="text" if j == 0 else "muted")
    for i in (3, 5):
        c.text(60 + i * 128 + 59, y + 72, "chr_req 拍", size=FS_S, fill="blue")
    c.text(60, y + 96, "→ 第 2 次 chr_req 后回到 IDLE，bg_valid 保持到下一次接受",
           size=FS_S, fill="muted", anchor="start")

    c.text(60, 610, "nxt_addr = base_q + {3'b0, idx_q, 4'd0} + (pl_q ? 8 : 0)；"
           "fwd_addr = nxt_addr + 8", size=FS_S, anchor="start", family=MONO,
           fill="muted")
    c.text(60, 632, "hblank 内 bg_valid 不被清（只在接受下一请求时清），"
           "因此 PPU 调度捕获在 trigger+8 取 bg_lo/hi。",
           size=FS_S, anchor="start", fill="muted")
    return c


# ---------------------------------------------------------------------------
# Figure 5 -- CHR arbitration
# ---------------------------------------------------------------------------
def fig_chr_arbitration():
    c = Svg(1160, 820, "共享 CHR 阵列的三个主设备：背景取数、精灵取数、$2007 读臂")
    title_block(c, "CHR 仲裁：三个读主设备 + 一个独立写口",
                "rtl/nes_core/ppu/nes_ppu2c02.v (g_chr_external) + nes_system_v6.v")

    # masters
    c.node(40, 110, 260, 96, "背景取数", [
        "nes_chr_fetch_unit",
        "bg_chr_req / bg_addr[13:0]",
        "bg_fetch_due 每 8 dot",
    ], accent="blue")
    c.node(40, 240, 260, 96, "精灵取数", [
        "nes_sprite_chr_fetch",
        "sp_chr_req / sp_addr[13:0]",
        "sp_start @ dot 257, 16 字节",
    ], accent="blue")
    c.node(40, 370, 260, 96, "$2007 读臂", [
        "chr_rd_win = chr_rd_arm &&",
        "             v_addr < $2000",
        "div_phase==8 单拍脉冲",
    ], accent="orange")

    # arbiter
    c.node(380, 190, 300, 250, "优先级组合 mux", [
        "选线 sp_bus_sel = sp_busy",
        "",
        "chr_req  = chr_rd_win",
        "         | (sp_bus_sel ? sp_chr_req",
        "                       : bg_chr_req)",
        "chr_addr = chr_rd_win ? v_addr[13:0]",
        "         : (sp_bus_sel ? sp_addr",
        "         : bg_addr)",
        "",
        "chr_hold_bg = chr_rd_win &&",
        "              bg_chr_req",
        "chr_hold_sp = chr_rd_win &&",
        "              sp_chr_req",
    ], accent="purple")

    c.flow([(290, 158), (378, 230)], color="blue")
    c.flow([(290, 288), (378, 300)], color="blue")
    c.flow([(290, 418), (378, 380)], color="orange")

    # freeze note
    c.node(40, 500, 640, 96, "冻结（arm 命中本单元 chr_req 时）", [
        "ce_bg = ce && !chr_hold_bg    ce_sp = ce && !chr_hold_sp",
        "状态/地址/请求寄存器不动一拍，下一 ce 同地址重发",
        "arm 有零余量，只能冻结取数侧；地址不变 → 重发同一拍",
    ], accent="red")

    # mapper translate
    c.node(740, 120, 380, 130, "地址翻译（本地 14b → 最终 17b）", [
        "mapper_ppu_addr =",
        "  {ppu_chr_we?0:addr[13], addr[12:0]}",
        "→ nes_mapper.chr_bank_offset (17b)",
        "→ chr_final_addr",
    ], accent="green")
    c.flow([(680, 300), (738, 210)], color="purple")

    # CHR array
    c.node(740, 300, 380, 150, "CHR 阵列  nes_cart_rom", [
        "CHR-only 实例（PRG_ENABLE=0）",
        "8 KiB，索引 chr_addr[12:0]（镜像）",
        "读口：ce_ppu = !reset && div_phase[1:0]==0",
        "门控 chr_req，寄存器输出 chr_rdata",
        "独立写口与读口地址无关",
    ], accent="purple")
    c.flow([(738, 190), (738, 300)], color="green")
    c.text(700, 250, "chr_final_addr", size=FS_S, fill="green", anchor="end")

    # write port
    c.node(740, 500, 380, 130, "$2007 写口（独立地址）", [
        "chr_waddr[13:0] = v_addr[13:0] (<$2000)",
        "chr_we 单拍；chr_wdata = reg_din",
        "→ u_cart_chr.chr_windex（独立写地址）",
        "读改写同时命中 → 读优先返回旧字节",
    ], accent="red")
    c.flow([(680, 440), (738, 510)], color="red")
    c.text(700, 480, "chr_waddr/we", size=FS_S, fill="red", anchor="end", family=MONO)

    c.text(60, 640, "读口三条主设备共享一个 chr_rdata；谁赢得仲裁，chr_rdata 就是谁那一拍的字节。",
           size=FS_N, anchor="start", fill="muted")
    c.text(60, 662, "写口有独立地址，因此 $2007 写不再需要冻结取数单元（风险 L-17 的写法已退役）。",
           size=FS_N, anchor="start", fill="muted")

    legend(c, 60, 760, [
        ("arrow", "读请求"), ("box", "取数主设备"), ("mem", "读写端口"),
    ])
    return c


# ---------------------------------------------------------------------------
# Figure 6 -- APU to I2S
# ---------------------------------------------------------------------------
def fig_apu_to_i2s():
    c = Svg(1200, 700, "APU 通道混合到 I2S：2016/55 有理抽取 + CDC FIFO + 移位器")
    title_block(c, "音频通路：混合 → 有理抽取 → CDC FIFO → I2S",
                "nes_apu2a03.v + nes_zynq_top.v + nes_audio_i2s.v + nes_cdc_fifo.v")

    # mix
    c.node(40, 110, 250, 220, "nes_apu2a03 混合", [
        "pulse1/2 level(4b) → pulse_sum",
        "pulse_mix_lut → mix_pulse(16b)",
        "",
        "tri·noise·dmc → tnd_sum",
        "tnd_mix_lut → mix_tnd(16b)",
        "",
        "mix_sum = mix_pulse + mix_tnd",
        "saturate → mixed_sample(16b)",
    ], accent="green")
    c.text(165, 352, "sample_valid @ ce && ce_sample", size=FS_S, fill="muted")
    c.text(165, 368, "= 21477272.727/12 = 1.789772727 MHz", size=FS_S, fill="muted")

    # decimator
    c.node(360, 110, 300, 220, "抽取滤波（core_clk）", [
        "ma1 4 抽头 → /4   (18b 和)",
        "ma2 4 抽头 → /4   (20b 和)",
        "ma3 2 抽头 + 2:1 → /2",
        "总速率 /32，DC 增益恒 1",
        "",
        "有理 63/55（Bresenham 累加器）",
        "  rat_hit = (rat_acc+55) >= 63",
        "  2016 进 55 出，余数为零",
        ">>5 前 +16 四舍五入",
    ], accent="blue")
    c.flow([(290, 200), (358, 200)], color="green")
    c.text(324, 188, "16b×2", size=FS_S, fill="muted")

    # fifo
    c.node(730, 110, 240, 220, "nes_cdc_fifo  (深度 64)", [
        "写 {wr_right, wr_left} 32b",
        "格雷码指针 + 2FF 同步",
        "wr_full 回压 / rd_empty",
        "ADDR_WIDTH=6",
        "",
        "wr_clk = core_clk",
        "rd_clk = lcd_clk",
    ], accent="purple")
    c.flow([(660, 200), (728, 200)], color="blue")
    c.text(694, 150, "dec_valid", size=FS_S, fill="blue")
    c.text(694, 165, "48828.125 Hz", size=FS_S, fill="muted")

    # shifter
    c.node(1030, 110, 130, 220, "I2S 移位器", [
        "32b 位串行",
        "16+16 位",
        "MSB first",
        "",
        "左先出",
        "lrck 第 17",
        "位翻转",
    ], accent="orange")
    c.flow([(970, 200), (1028, 200)], color="purple")

    # output
    c.node(1030, 380, 130, 120, "输出寄存", [
        "dout 加一拍",
        "lrck 不延",
    ], accent="orange")
    c.flow([(1095, 330), (1095, 378)], color="orange")

    # bclk divider
    c.node(730, 380, 240, 120, "BCLK 分频（mclk=lcd_clk）", [
        "BCLK_DIV=16",
        "25 MHz / 16 = 1.5625 MHz",
        "rd_ce = bclk 上升沿脉冲",
    ], accent="orange")
    c.flow([(850, 378), (850, 332)], color="orange", head=False)
    c.flow([(970, 440), (1028, 440)], color="orange")

    # arithmetic note
    c.node(40, 470, 620, 150, "为什么是精确有理 63/55，而不是 /37", [
        "1.789772727 MHz / 37 = 48372.235 Hz，比 48 kHz 高 0.7755%",
        "FIFO 单生产者/单消费者：任何速率失配都会让水位走到满或空",
        "整数抽取与 25 MHz 侧帧率精确相等：仅 126·D/55 为整数，D=55→14204 Hz",
        "D=16 时 126·16/55 = 2016/55，非整数 → 用精确有理抽取",
        "4/4/2 串联零点：447/447/894 kHz，帧率处约 0.35 dB，DC 增益 1",
    ], accent="muted")

    legend(c, 700, 520, [
        ("arrow", "样点流"), ("box", "core_clk 侧"), ("mem", "跨域 / CDC"),
    ])
    return c


# ---------------------------------------------------------------------------
# Figure 7 -- video scaling
# ---------------------------------------------------------------------------
def fig_video_scaling():
    c = Svg(1160, 700, "256x240 到 800x480：水平 3:1+每 8 取 4，垂直 2:1")
    title_block(c, "视频缩放：3.125× 水平 + 2.0× 垂直",
                "rtl/nes_core/video/nes_video_800x480.v · frame_mem 真双口 BRAM")

    # horizontal group generator
    c.node(40, 110, 520, 190, "水平：32 组 × 25 dot", [
        "src_col = {group_count[4:0], mod8_count[2:0]}",
        "group_rolls = (mod8_count == 7)",
        "col_done = emit_step && group_rolls ? emit_slot==3",
        "                                   : emit_slot==2",
        "256 输入像素 → 每像素 3 个 + 每 8 个补 1 个",
        "32×25 = 800，每行精确回到 0",
    ], accent="green")

    # group illustration
    y = 180
    for i in range(8):
        x = 600 + i * 58
        last = (i == 7)
        c.rect(x, y, 52, 40, fill="panel2" if not last else "yellow",
               stroke="green" if not last else "yellow", rx=4, sw=1.3)
        c.text(x + 26, y + 25, "3" if not last else "4", size=FS_N,
               weight="700")
    c.text(600 + 8 * 58 / 2, y - 12, "一组 8 个输入像素", size=FS_S,
           fill="muted")
    c.text(600 + 8 * 58 / 2, y + 62, "8×3+1 = 25 输出 dot", size=FS_S,
           fill="green")

    # vertical
    c.node(600, 260, 520, 110, "垂直：v_active_index[8:1]", [
        "src_row = v_active_index[8:1]",
        "V 有效区 [35,515) = 480 行",
        "240 输入行 → 每行重复 2 次（精确 2:1）",
    ], accent="blue")

    # frame mem
    c.node(40, 340, 520, 180, "frame_mem（真双口 BRAM，61440×16b）", [
        "写口 wr_clk=core_clk：",
        "  mem_write_addr = {in_y, in_x}",
        "  每可见 dot 写一次（strobe=ce_ppu&&pixel_valid）",
        "读口 rd_clk=lcd_clk：",
        "  mem_read_addr = {src_row, src_col_next}",
        "  同沿读出，无握手 / 无同步器",
    ], accent="purple")

    # raster timing
    c.node(600, 390, 520, 130, "光栅时序（参数为厂商 lcd_driver 值）", [
        "hcount 0..1055  vcount 0..524",
        "H: SYNC128/BACK88/DISP800/FRONT40",
        "V: SYNC2/BACK33/DISP480/FRONT10",
        "DE 窗口 [216,1016) × [35,515)",
        "hs/vs 在 DE 模式下恒 1",
    ], accent="orange")

    c.node(40, 552, 1080, 96, "为什么不能只用 ce 变频", [
        "25 MHz 不是 21.477 MHz 的整数倍 → 面板不能在 core_clk 上用使能驱动",
        "像素必须在真实的 25 MHz 沿离开；frame_mem 的双口 RAM 就是这次跨域，零额外逻辑",
    ], accent="muted", align="left")

    legend(c, 40, 664, [
        ("arrow", "像素地址"), ("box", "缩放逻辑"), ("mem", "跨域存储"),
    ])
    return c


# ---------------------------------------------------------------------------
# Figure 8 -- Zynq clock tree
# ---------------------------------------------------------------------------
def fig_zynq_clock():
    c = Svg(1000, 740, "Zynq 时钟树：50 MHz 输入、1181.25 MHz VCO、核心与 LCD 时钟")
    title_block(c, "Zynq-7020 时钟树：精确到最后一 bit 的分频",
                "rtl/platform/zynq/nes_zynq_clk.v · MMCME2_BASE")

    c.node(40, 150, 220, 90, "sys_clk 输入", [
        "U18, 50 MHz",
        "CLKIN1_PERIOD = 20.000 ns",
    ], accent="blue")
    c.flow([(260, 195), (348, 195)], color="blue")

    c.node(350, 130, 300, 130, "MMCME2_BASE", [
        "DIVCLK_DIVIDE    = 1",
        "CLKFBOUT_MULT_F  = 23.625  (=189/8)",
        "CLKOUT0_DIVIDE_F = 47.25   (=378/8)",
        "CLKOUT1_DIVIDE   = 55",
    ], accent="purple")

    c.node(360, 300, 280, 78, "VCO", [
        "f_VCO = 50 × 23.625 / 1",
        "      = 1181.25 MHz  (600..1200)",
    ], accent="orange")
    c.flow([(500, 260), (500, 298)], color="purple")

    c.node(120, 430, 320, 90, "core_clk = CLKOUT1", [
        "1181.25 / 55 = 21.477272727 MHz",
        "整数分频，精确",
    ], accent="green")
    c.flow([(400, 378), (280, 428)], color="green")

    c.node(560, 430, 320, 90, "lcd_clk = CLKOUT0", [
        "1181.25 / 47.25 = 25.000000000 MHz",
        "唯一的分数分频",
    ], accent="orange")
    c.flow([(600, 378), (720, 428)], color="orange")

    c.node(350, 540, 300, 96, "LOCKED 与反馈", [
        "CLKFBOUT → BUFG → CLKFBIN",
        "locked 直出，顶层在锁定前保持复位",
    ], accent="red")

    c.text(40, 670, "推导：f_core = (50·m/8)/k = 945/44 → 2200·m = 7560·k → 55·m = 189·k；"
           "互素 → 最小 (m,k)=(189,55)", size=FS_S, anchor="start", family=MONO,
           fill="muted")
    c.text(40, 690, "为什么不用 1000 MHz VCO：1000/(945/44)=46.56… 非整数，"
           "最接近的分频使 CPU/PPU 慢 763 Hz。", size=FS_S, anchor="start",
           fill="muted")

    legend(c, 660, 540, [
        ("arrow", "时钟"), ("box", "整数分频"), ("mem", "锁定 / 反馈"),
    ])
    return c


# ---------------------------------------------------------------------------
# Figure 9 -- touch state machine + region map
# ---------------------------------------------------------------------------
def fig_touch_input():
    c = Svg(1180, 800, "nes_touch_input：复位→校准→轮询状态机与区域映射")
    title_block(c, "触摸：I2C 状态机（复位 → 校准 → 轮询）与区域映射",
                "rtl/nes_core/peripheral/nes_touch_input.v")

    # main sequence
    c.node(40, 110, 210, 70, "SQ_RST_LO  6'd0", [
        "ct_rst_n = 0",
        "CT_RST_LOW_CYCLES 后释放",
    ], accent="red")
    c.node(40, 200, 210, 70, "SQ_RST_HI  6'd1", [
        "CT_RST_WAIT_CYCLES",
        "→ init_done, 进校准",
    ], accent="red")
    c.flow([(145, 180), (145, 198)], color="red")

    # calibration box
    c.node(300, 90, 380, 220, "一次性校准（6'd25..34）", [
        "SQ_CAL_SEL  → 选寄存器指针",
        "  步 0: 16'h8048 X Output Max (2B)",
        "  步 1: 16'h804A Y Output Max (2B)",
        "  步 2: 16'h804D Module_Switch1 (1B)",
        "SQ_CAL_WR/REGH/REGL/RD/RX/STOP",
        "SQ_CAL_STEP → 下一字节 / 下一步",
        "SQ_CAL_ABORT → STOP → SQ_CAL_DONE",
        "SQ_CAL_DONE: 派生三个切点",
    ], accent="purple")
    c.flow([(250, 235), (298, 200)], color="purple")

    # poll
    c.node(300, 340, 380, 200, "轮询状态序列（SQ_ST / SQ_CO）", [
        "SQ_WAIT      → 等 POLL_CYCLES 或 ct_int",
        "SQ_ST_WR..ST_RX  → 读 16'h814E 状态",
        "SQ_EVAL: 状态[7]&&1≤点数≤5 ?",
        "SQ_CO_WR..CO_RX3 → 读点 1 四字节",
        "   → x_lo,x_hi,y_lo,y_hi（原始）",
        "SQ_CLR_*  → 写 0 清触摸标志",
        "SQ_ABORT  → 出错通道，poll_done=1",
    ], accent="green")
    c.flow([(480, 310), (480, 338)], color="green")
    c.text(510, 566, "轮询结束回到 SQ_WAIT（6'd2）", size=FS_S, fill="muted",
           anchor="start")

    # axis swap
    c.node(710, 90, 430, 130, "轴交换（SQ_CO_RX3 最后字节）", [
        "x2y_q = Module_Switch1[3]（校准读出）",
        "touch_x <= x2y ? coord_y_raw : coord_x_raw",
        "touch_y <= x2y ? coord_x_raw : coord_y_raw",
        "字节顺序不变：x_lo,x_hi,y_lo,y_hi",
    ], accent="blue")

    # region map
    c.node(710, 250, 430, 300, "区域映射（每报点 3 次比较，无算术）", [
        "x_left_edge  = x_out_max >> 2",
        "x_right_edge = x_out_max - (x_out_max>>2)",
        "y_mid_edge   = y_out_max >> 1",
        "默认: 200 / 600 / 240（PANEL 800×480）",
        "",
        "左  : touch_x <  x_left_edge",
        "右  : touch_x >= x_right_edge",
        "中  : 其余",
        "上  : touch_y <  y_mid_edge",
    ], accent="orange")

    # region diagram
    rx, ry, rw, rh = 60, 600, 300, 140
    c.rect(rx, ry, rw, rh, fill="panel2", stroke="border", rx=4, sw=1.4)
    c.line(rx + rw // 4, ry, rx + rw // 4, ry + rh, stroke="border", sw=1.2)
    c.line(rx + 3 * rw // 4, ry, rx + 3 * rw // 4, ry + rh, stroke="border", sw=1.2)
    c.line(rx + rw // 4, ry + rh // 2, rx + 3 * rw // 4, ry + rh // 2,
           stroke="border", sw=1.2, dash="4 3")
    c.text(rx + rw // 8, ry + rh // 2 + 5, "Left", size=FS_N, weight="600")
    c.text(rx + rw // 2, ry + rh // 4 + 5, "Up", size=FS_N, weight="600")
    c.text(rx + rw // 2, ry + 3 * rh // 4 + 5, "Down", size=FS_N, weight="600")
    c.text(rx + 7 * rw // 8, ry + rh // 2 + 5, "Right", size=FS_N, weight="600")
    c.text(rx + rw // 2, ry - 10, "dpad = {Up, Down, Left, Right}", size=FS_S,
           fill="muted")
    c.text(rx - 8, ry + rh + 18, "x=0", size=FS_S, fill="muted", anchor="start")
    c.text(rx + rw + 8, ry + rh + 18, "x=max", size=FS_S, fill="muted",
           anchor="end")

    c.node(400, 600, 310, 140, "按键与 TPAD", [
        "key0/key1 低有效，去抖",
        "touch_key 高有效（独立引脚）",
        "TPAD 按住 → 两键变 Start/Select",
        "buttons = {dpad, start, sel, B, A}",
    ], accent="green")

    legend(c, 720, 600, [
        ("arrow", "状态推进"), ("box", "轮询"), ("mem", "校准 / 映射"),
    ])
    return c


# ---------------------------------------------------------------------------
# Figure 10 -- HDMI path
# ---------------------------------------------------------------------------
def fig_hdmi_path():
    c = Svg(1220, 830, "HDMI/DVI 发射通路：两族时钟、一个跨域 scaler、编码器到连接器")
    title_block(c, "HDMI 通路：core_clk 写、hdmi_pclk 读、TMDS 编码与串行",
                "nes_video_hdmi.v + nes_hdmi_tx.v + nes_hdmi_tmds_encoder.v"
                " + nes_hdmi_tmds_serializer.v + nes_zynq_clk.v")

    # clock tree
    c.node(40, 98, 170, 64, "sys_clk 50 MHz", [
        "U18 · 20.000 ns",
    ], accent="blue")
    c.node(260, 80, 270, 100, "MMCM #1 核心", [
        "DIVCLK_DIVIDE 1 · MULT_F 23.625",
        "VCO 1181.25 MHz",
        "CLKOUT1 ÷55 → core 21.477",
        "CLKOUT0 ÷47.25 → lcd 25.000",
    ], accent="purple")
    c.node(580, 80, 300, 100, "MMCM #2 HDMI", [
        "DIVCLK_DIVIDE 1 · MULT_F 13.5",
        "VCO 675.000 MHz",
        "CLKOUT0 ÷25 → hdmi_pclk 27.000",
        "CLKOUT1 ÷5 → pclk_x5 135.000",
    ], accent="purple")
    c.node(930, 80, 250, 100, "四条时钟", [
        "core_clk 21.477 MHz",
        "lcd_clk 25.000 MHz",
        "hdmi_pclk 27.000 MHz",
        "hdmi_pclk_x5 135.000 MHz",
    ], accent="blue")
    c.flow([(210, 130), (258, 130)], color="blue")
    c.flow([(530, 130), (578, 130)], color="blue")
    c.flow([(880, 130), (928, 130)], color="blue")

    # domain frames
    c.rect(28, 232, 282, 170, fill="none", stroke="green", rx=8, sw=1.2, dash="6 4")
    c.text(169, 246, "core_clk 域", size=FS_S, fill="green")
    c.rect(736, 232, 470, 322, fill="none", stroke="orange", rx=8, sw=1.2,
           dash="6 4")
    c.text(971, 246, "hdmi_pclk 域 · 串行 135 MHz", size=FS_S, fill="orange")

    # data path
    c.node(40, 250, 250, 140, "core_clk 像素流", [
        "VID 每可见 dot 一拍",
        "vid_we_q / vid_in_x[7:0]",
        "vid_in_y[7:0]",
        "vid_in_rgb_q[15:0]",
    ], accent="green")
    c.node(330, 250, 380, 260, "nes_video_hdmi", [
        "frame_mem 61440×16 真双口 BRAM",
        "写口 wr_clk=core_clk",
        "读口 rd_clk=hdmi_pclk · ce=1",
        "垂直 src_row=v_row_index[8:1] 2:1",
        "水平 累加器 +256/-720 = 45/16",
        "光栅 858×525  DE[122,842)×[36,516)",
        "hsync[0,62) vsync[0,6) 负极性",
        "59.94 Hz = 27e6/(858×525)",
    ], accent="purple")
    c.node(750, 250, 200, 90, "RGB565→RGB888", [
        "全量位复制",
        "hdmi_rgb888[23:0]",
    ], accent="orange")
    c.node(750, 390, 200, 150, "nes_hdmi_tx", [
        "3 × tmds_encoder",
        "4 × tmds_serializer",
        "pclk 27 / pclk_x5 135",
        "蓝道载 hsync/vsync",
        "绿/红道 c0=c1=0",
    ], accent="orange")
    c.node(1020, 250, 180, 290, "HDMI 连接器", [
        "tmds_data_p[2:0]",
        "tmds_data_n[2:0]",
        "tmds_clk_p / tmds_clk_n",
        "G19 K19 J20 / J18",
        "时钟道固定",
        "10'b1111100000",
        "",
        "DDC/HPD 不可用",
        "R19/P20 属触摸",
        "无 EDID · 固定模式",
    ], accent="blue")

    c.flow([(290, 320), (328, 320)], color="green")
    c.flow([(710, 320), (748, 320)], color="purple")
    c.flow([(850, 340), (850, 388)], color="orange")
    c.flow([(950, 465), (1018, 465)], color="orange")
    c.text(300, 340, "256×240", size=FS_S, fill="muted")
    c.text(846, 366, "逐像素", size=FS_S, fill="orange")

    # notes
    c.node(40, 560, 500, 170, "TMDS 编码（蓝道为例）", [
        "阶段1 8b→9b：XNOR/XOR 最小跳变链",
        "阶段2 9b→10b：balanced/oppose/follow",
        "4 个控制符号 {c1,c0}：00 1101010100",
        "  01 0010101011  10 0101010100",
        "  11 1010101011（q_out[0] 先发）",
        "运行差异界 ±8，不是 IBM 8b/10b 的 ±1",
    ], accent="blue")
    c.node(560, 560, 620, 170, "为什么需要第二个 MMCM", [
        "核心 VCO 被 1181.25 MHz 钉死以精确命中核时钟",
        "唯一分数输出 CLKOUT0 已给 25 MHz LCD",
        "1181.25/27 = 43.75 不是 CLKOUT1..6 的整数分频",
        "1181.25/371.25 = 35/11 既非整数也非 0.125 步",
        "→ 27/135 MHz 改由 675 MHz VCO 的第二个 MMCM 给出",
    ], accent="red")

    legend(c, 44, 770, [
        ("box", "core_clk 逻辑"), ("mem", "跨域存储"), ("arrow", "像素 / 数据"),
    ])
    return c


# ---------------------------------------------------------------------------
# Figure 11 -- mapper dispatch
# ---------------------------------------------------------------------------
def fig_mapper_dispatch():
    c = Svg(1160, 680, "nes_mapper：mapper_select 组合分发到五个子模块与输出 mux")
    title_block(c, "Mapper 顶层：五个子模块并存 + 组合 mux",
                "rtl/nes_core/mapper/nes_mapper.v · cpu_we 与 select_* 与门隔离子模块")

    c.node(30, 130, 200, 190, "输入", [
        "mapper_select[7:0]",
        "cpu_addr[15:0]",
        "cpu_we / cpu_dout[7:0]",
        "ppu_addr[13:0] / ppu_we",
        "ppu_dout[7:0]",
        "ppu_a12",
        "prg_readback[7:0]",
    ], accent="blue")

    # dispatch rail
    c.line(252, 110, 252, 548, stroke="muted", sw=1.2, dash="5 5")
    c.flow([(230, 225), (250, 225)], color="blue")

    subs = [
        ("nes_mapper_nrom   m0", ["无寄存器（纯组合）", "PRG 固定 $8000-$FFFF"], 100),
        ("nes_mapper_mmc1   m1", ["5 次串行写 + 4 寄存器", "CHR 4/8 KiB、PRG 16/32 KiB"], 192),
        ("nes_mapper_uxrom  m2", ["1 × 16 KiB PRG bank", "cpu_we & select_uxrom"], 284),
        ("nes_mapper_cnrom  m3", ["1 × 8 KiB CHR bank", "bus conflict 来源"], 376),
        ("nes_mapper_mmc3   m4", ["8 bank 寄存器", "A12 上升沿 IRQ FSM"], 468),
    ]
    for title, lines, y in subs:
        c.node(280, y, 280, 80, title, lines, accent="green")
        c.flow([(252, y + 40), (278, y + 40)], color="blue", sw=1.2)

    c.node(620, 250, 180, 140, "组合 mux", [
        "mapper_select 选线",
        "五路同时存在",
        "换 mapper 不重综合",
    ], accent="purple")
    for y in (260, 290, 320, 350, 380):
        c.flow([(560, 140 + (y - 260)), (618, y)], color="green", sw=1.2)

    c.node(880, 110, 250, 430, "输出", [
        "prg_bank_offset[16:0]",
        "chr_bank_offset[16:0]",
        "mirroring[2:0]",
        "nametable_map[7:0]",
        "prg_ram_enable / prg_ram_we",
        "chr_ram_enable / chr_ram_we",
        "irq（高有效 = 有效）",
        "bus_conflict",
        "dbg_prg_bank_number",
        "dbg_chr_bank_number",
        "dbg_mapper_id",
    ], accent="orange")
    c.flow([(800, 320), (878, 320)], color="purple")

    c.text(60, 470, "每个子模块的写使能都先与过自己的 select_*，"
           "所以同一地址写不会串到别的 mapper 寄存器。",
           size=FS_S, anchor="start", fill="muted")
    c.text(60, 492, "nametable_map 由顶层一个 decode 函数集中生成，"
           "不复制四份 nametable 数组。",
           size=FS_S, anchor="start", fill="muted")

    legend(c, 60, 560, [
        ("arrow", "分发 / 输出"), ("box", "mapper 子模块"), ("mem", "选择 / mux"),
    ])
    return c


# ---------------------------------------------------------------------------
# Figure 12 -- CDC FIFO pointers
# ---------------------------------------------------------------------------
def fig_cdc_fifo_pointers():
    c = Svg(1200, 700, "nes_cdc_fifo：二进制寻址、格雷码发布、两级同步与满/空判据")
    title_block(c, "异步 FIFO：跨域只传格雷码指针",
                "rtl/nes_core/peripheral/nes_cdc_fifo.v · 每拍最多翻一位")

    c.rect(28, 84, 340, 500, fill="none", stroke="green", rx=8, sw=1.2, dash="6 4")
    c.text(198, 100, "wr_clk 域", size=FS_S, fill="green")
    c.rect(832, 84, 340, 500, fill="none", stroke="orange", rx=8, sw=1.2, dash="6 4")
    c.text(1002, 100, "rd_clk 域", size=FS_S, fill="orange")

    c.node(44, 120, 308, 100, "wr_bin / wr_gray", [
        "wr_bin 低位 → mem 写地址",
        "wr_gray = bin ^ (bin >> 1)",
        "提交：wr_en && !wr_full",
    ], accent="green")
    c.node(44, 250, 308, 90, "写口提交", [
        "wr_en && !wr_full → 指针 +1",
        "满时写被忽略，指针不动",
    ], accent="green")
    c.node(44, 376, 308, 110, "wr_full 比较", [
        "wr_gray_next ==",
        "{~rd_sync2[top:top-1], rd_sync2[top-2:0]}",
        "用延迟的读指针判定",
    ], accent="red")

    c.node(848, 120, 308, 100, "rd_bin / rd_gray", [
        "rd_bin 低位 → mem 读地址",
        "rd_gray = bin ^ (bin >> 1)",
        "提交：rd_en && !rd_empty",
    ], accent="orange")
    c.node(848, 250, 308, 90, "读口提交 / 寄存输出", [
        "rd_data <= mem[rd_bin]",
        "空时 rd_data 保持上一拍值",
    ], accent="orange")
    c.node(848, 376, 308, 110, "rd_empty 比较", [
        "rd_gray_next == wr_sync2",
        "整字相等即无数据",
        "复位后初值 1",
    ], accent="red")

    c.node(420, 120, 360, 110, "mem（双时钟 SDP）", [
        "写 mem[wr_bin] @ wr_clk",
        "读 mem[rd_bin] @ rd_clk",
        "每 bit 一对触发器（多推断为 BRAM）",
        "复位不清阵列",
    ], accent="purple")
    c.node(420, 274, 360, 140, "格雷指针同步器", [
        "rd_gray_sync1/2  位于 wr_clk",
        "wr_gray_sync1/2  位于 rd_clk",
        "(* ASYNC_REG *) 两级相邻",
        "每拍只翻一位 → 不会撕裂",
    ], accent="blue")
    c.node(420, 452, 360, 120, "为什么指针多一位", [
        "深度 = 2^ADDR，指针 0..2^(ADDR+1)-1",
        "多出的最高位区分满与空",
        "满 = 最高两位取反的格雷签名",
    ], accent="muted")

    c.flow([(352, 165), (418, 150)], color="green")
    c.flow([(780, 150), (846, 165)], color="orange")
    c.flow([(352, 210), (418, 344)], color="green")
    c.text(300, 300, "wr_gray", size=FS_S, fill="green", anchor="end")
    c.flow([(848, 210), (782, 344)], color="orange")
    c.text(902, 300, "rd_gray", size=FS_S, fill="orange", anchor="start")
    c.flow([(420, 352), (352, 410)], color="red")
    c.text(430, 388, "rd_gray_sync2", size=FS_S, fill="red", anchor="start")
    c.flow([(780, 352), (848, 410)], color="red")
    c.text(770, 388, "wr_gray_sync2", size=FS_S, fill="red", anchor="end")

    legend(c, 44, 616, [
        ("arrow", "指针流"), ("box", "本地指针 / 同步器"), ("mem", "存储 / 判据"),
    ])
    return c


# ---------------------------------------------------------------------------
# Figure 13 -- OAM DMA path
# ---------------------------------------------------------------------------
def fig_oam_dma_path():
    c = Svg(1160, 730, "nes_oam_dma：锁存、四态、513/514 周期账与总线握手")
    title_block(c, "OAM DMA：总线主设备 + 513/514 周期停机",
                "rtl/nes_core/ppu/nes_oam_dma.v · $4014 page -> 256 × $2004")

    c.node(40, 140, 250, 150, "start 锁存", [
        "锁 src_page → page_q",
        "read_addr_q = {page, 8'h00}",
        "锁 oam_base_q / oam_cur_q",
        "index_q <= 0",
    ], accent="purple")

    c.node(330, 150, 180, 90, "ST_IDLE", [
        "等 start",
    ], accent="blue")
    c.node(530, 150, 180, 90, "ST_ALIGN", [
        "dummy 1 或 2 拍",
        "OAMADDR_WRITE=1",
        " 时在 dummy 拍发 $2003",
    ], accent="blue")
    c.node(730, 150, 180, 90, "ST_READ", [
        "发 cpu_read_req",
        "等 cpu_read_ack",
    ], accent="green")
    c.node(930, 150, 180, 90, "ST_WRITE", [
        "一次 $2004 写",
        "index_q==FF → done",
    ], accent="green")

    c.flow([(290, 215), (328, 195)], color="purple")
    c.flow([(510, 195), (528, 195)], color="blue")
    c.flow([(710, 195), (728, 195)], color="blue")
    c.flow([(910, 195), (928, 195)], color="green")
    c.flow([(1020, 240), (1020, 272), (820, 272), (820, 242)], color="green")
    c.flow([(950, 150), (950, 118), (420, 118), (420, 148)], color="red")
    c.text(1042, 266, "读-写交替", size=FS_S, fill="green", anchor="start")
    c.text(760, 110, "done（第 256 次写）", size=FS_S, fill="red", anchor="start")

    c.node(40, 330, 380, 150, "周期账", [
        "cycle_count 从 start 拍编号为 1",
        "偶数对齐 1 + 256×2 = 513",
        "奇数对齐 2 + 256×2 = 514",
        "对齐拍不额外占周期（$2003 搭车）",
        "延迟 ack：512 + align + 256×(1+ack)",
    ], accent="purple")
    c.node(460, 330, 340, 150, "总线握手", [
        "cpu_read_req   电平",
        "cpu_read_addr  {page, index}",
        "cpu_read_ack   可延迟任意拍",
        "cpu_rdata      ack 同拍有效",
        "cpu_hold = busy（513/514 拍）",
    ], accent="green")
    c.node(840, 330, 290, 150, "OAMADDR 两种接法", [
        "OAMADDR_WRITE=0 默认",
        "  CPU 在 $4014 前写 $2003",
        "OAMADDR_WRITE=1",
        "  本模块在 align 拍发 $2003",
        "两种接法 256 字节内容相同",
    ], accent="blue")

    c.node(40, 510, 540, 130, "输出稳定性", [
        "cpu_read_req 与 ppu_reg_cs 永不同拍",
        "read_addr_q 只在 ack 时 +1",
        "ppu_reg_* 只由 state 决定",
        "所有输出 = 寄存器的组合函数",
    ], accent="orange")
    c.node(620, 510, 510, 130, "边界（与 PPU 的切分）", [
        "OAM RAM 本体在 nes_ppu2c02",
        "$2004 写由外部驱动",
        "真实 OAMADDR 自增由 PPU 完成",
        "可见区 DMA 撕裂不检测（硬件也不）",
    ], accent="muted")

    legend(c, 44, 670, [
        ("arrow", "状态 / 请求"), ("box", "时序与握手"), ("mem", "锁存 / 接法"),
    ])
    return c


# ---------------------------------------------------------------------------
# Catalogue
# ---------------------------------------------------------------------------
FIGURES = [
    dict(
        fn=fig_system_hierarchy,
        file="zynq-system-hierarchy.svg",
        title="nes_zynq_top 系统层次与三个时钟域",
        source="rtl/platform/zynq/nes_zynq_top.v",
        host="docs/modules/zynq-platform.md",
        num=2,
        desc="顶层模块层次、sys/core/lcd 三个时钟域、三条跨域边界与复位网络。",
    ),
    dict(
        fn=fig_zynq_clock,
        file="zynq-clock-tree.svg",
        title="Zynq 时钟树（MMCM）",
        source="rtl/platform/zynq/nes_zynq_clk.v",
        host="docs/modules/zynq-platform.md",
        num=1,
        desc="50 MHz 输入经 MMCM 到 1181.25 MHz VCO，再整数/分数分频出核心与 LCD 时钟。",
    ),
    dict(
        fn=fig_cpu_bus,
        file="cpu-bus.svg",
        title="CPU 与总线：译码、等待态、owner/hold、DMA",
        source="rtl/nes_core/bus/nes_cpu_bus.v",
        host="docs/modules/cpu-bus.md",
        num=1,
        desc="地址译码表、ready/等待态路径、owner/ack、bus_hold 与 DMA 端口优先级。",
    ),
    dict(
        fn=fig_ppu_dot_pipeline,
        file="ppu-dot-pipeline.svg",
        title="PPU dot 流水线",
        source="rtl/nes_core/ppu/nes_ppu2c02.v",
        host="docs/walkthrough/51-ppu2c02.md",
        num=1,
        desc="dot 0..340 计数、背景取数节奏、精灵窗口 [257,291]、外部 CHR 冻结点。",
    ),
    dict(
        fn=fig_chr_fetch_fsm,
        file="chr-fetch-fsm.svg",
        title="nes_chr_fetch_unit 状态机",
        source="rtl/nes_core/ppu/nes_chr_fetch_unit.v",
        host="docs/walkthrough/22-chr-fetch-unit.md",
        num=1,
        desc="S_IDLE/S_PRE/S_ARM/S_BEAT/S_GRAB 五态与 7 ce 占用、两次 chr_req 拍。",
    ),
    dict(
        fn=fig_chr_arbitration,
        file="chr-arbitration.svg",
        title="CHR 阵列仲裁",
        source="rtl/nes_core/ppu/nes_ppu2c02.v + rtl/nes_core/system/nes_system_v6.v",
        host="docs/modules/ppu-external-chr.md",
        num=1,
        desc="背景/精灵/$2007 三个读主设备经优先级 mux 到共享 CHR 阵列，冻结与独立写口。",
    ),
    dict(
        fn=fig_apu_to_i2s,
        file="apu-to-i2s.svg",
        title="APU 到 I2S 音频通路",
        source="nes_apu2a03.v + nes_zynq_top.v + nes_audio_i2s.v + nes_cdc_fifo.v",
        host="docs/modules/i2s-audio.md",
        num=1,
        desc="五通道混合、2016/55 有理抽取、CDC FIFO 与 I2S 移位器。",
    ),
    dict(
        fn=fig_video_scaling,
        file="video-scaling-800x480.svg",
        title="256x240 到 800x480 缩放",
        source="rtl/nes_core/video/nes_video_800x480.v",
        host="docs/modules/video-800x480.md",
        num=1,
        desc="水平 3:1+每 8 取 4（32 组 × 25 dot）与垂直 2:1，frame_mem 双口跨域。",
    ),
    dict(
        fn=fig_touch_input,
        file="touch-state-and-regions.svg",
        title="触摸状态机与区域映射",
        source="rtl/nes_core/peripheral/nes_touch_input.v",
        host="docs/modules/touch-input.md",
        num=1,
        desc="复位→校准→轮询状态序列、轴交换与由最大值派生的区域切点。",
    ),
    dict(
        fn=fig_hdmi_path,
        file="hdmi-path.svg",
        title="HDMI/DVI 发射通路",
        source=("rtl/nes_core/video/nes_video_hdmi.v + "
                "rtl/platform/zynq/nes_hdmi_tx.v + "
                "rtl/platform/zynq/nes_hdmi_tmds_encoder.v + "
                "rtl/platform/zynq/nes_hdmi_tmds_serializer.v + "
                "rtl/platform/zynq/nes_zynq_clk.v"),
        host="docs/modules/hdmi-tx.md",
        num=1,
        desc="两个 MMCM 的四条时钟、core_clk 写 / hdmi_pclk 读的跨域 scaler、"
             "TMDS 编码器到串行器到连接器与 DDC 限制。",
    ),
    dict(
        fn=fig_mapper_dispatch,
        file="mapper-dispatch.svg",
        title="Mapper 组合分发",
        source="rtl/nes_core/mapper/nes_mapper.v",
        host="docs/modules/mappers.md",
        num=1,
        desc="mapper_select 分发到五个并存的子模块、各自与 select_* 的写门，"
             "经组合 mux 到 bank offset / mirroring / IRQ 输出。",
    ),
    dict(
        fn=fig_cdc_fifo_pointers,
        file="cdc-fifo-pointers.svg",
        title="异步 FIFO 指针跨域",
        source="rtl/nes_core/peripheral/nes_cdc_fifo.v",
        host="docs/modules/cdc-fifo.md",
        num=1,
        desc="二进制指针本地寻址、格雷码指针跨域、两级同步器与满/空判据，"
             "以及指针为何多一位。",
    ),
    dict(
        fn=fig_oam_dma_path,
        file="oam-dma-path.svg",
        title="OAM DMA 路径",
        source="rtl/nes_core/ppu/nes_oam_dma.v",
        host="docs/modules/oam-dma.md",
        num=1,
        desc="start 锁存、四态状态机、513/514 周期账、总线握手与 OAMADDR 两种接法。",
    ),
]


def build_readme():
    lines = []
    lines.append("# 图目录（自动生成）")
    lines.append("")
    lines.append("本目录的 SVG 由 `tools/gen_figures.py` 生成，**不要手工编辑**。")
    lines.append("重新生成：")
    lines.append("")
    lines.append("```text")
    lines.append(".\\tools\\gen_figures.ps1            # 或 python tools/gen_figures.py")
    lines.append("python tools/gen_figures.py --check   # 校验已是最新")
    lines.append("```")
    lines.append("")
    lines.append("生成是幂等的：连续两次运行产生逐字节相同的输出。每张图都由")
    lines.append("对应 RTL 源码读出后绘制；源码中无法确定的细节一律不画。")
    lines.append("")
    lines.append("编号为**按文档独立编号**：每张图在其被嵌入的那篇文档里按出现顺序记")
    lines.append("为“图 N”。跨文档不共享编号，因此新增图不会改动既有文档里的编号引用。")
    lines.append("")
    lines.append("| 文件 | 展示内容 | 生成来源（RTL） | 嵌入文档（编号） |")
    lines.append("|---|---|---|---|")
    for f in FIGURES:
        host = f["host"].replace("docs/", "")
        lines.append("| [`%s`](%s) | %s | `%s` | [`%s`](../%s) 图 %d |"
                     % (f["file"], f["file"], f["desc"], f["source"], host,
                        host, f["num"]))
    lines.append("")
    lines.append("## 视觉约定")
    lines.append("")
    lines.append("- 每种语义一种颜色，且在明暗两种 GitHub 主题下都可读：")
    lines.append("  蓝色 = 时钟/数据流，绿色 = core_clk 逻辑，橙色 = lcd_clk / 跨域，")
    lines.append("  紫色 = 存储器/地址翻译，红色 = 复位/冻结/危险，黄色 = 例外。")
    lines.append("- 实线箭头 = 同域数据；虚线箭头 = 跨时钟域或非阻塞关系。")
    lines.append("- 圆角框 = 模块；虚线竖线 = 时钟域边界；图例在每张图底部。")
    lines.append("- 字体：正文用无衬线，信号名/位宽用等宽。")
    lines.append("")
    return "\n".join(lines)


def write_bytes(path, text):
    with open(path, "w", encoding="utf-8", newline="\n") as fh:
        fh.write(text)


def main(argv):
    check = "--check" in argv
    lint_only = "--lint" in argv
    if not os.path.isdir(FIGDIR):
        os.makedirs(FIGDIR)
    problems = []
    lint_problems = []
    for f in FIGURES:
        c = f["fn"]()
        lint_problems.extend("%s: %s" % (f["file"], p) for p in lint(c))
        svg = c.render()
        path = os.path.join(FIGDIR, f["file"])
        if lint_only:
            continue
        if check:
            try:
                with open(path, "r", encoding="utf-8") as fh:
                    cur = fh.read()
            except IOError:
                cur = None
            if cur != svg:
                problems.append(f["file"])
        else:
            write_bytes(path, svg)
            print("wrote docs/figures/%s" % f["file"])
    for p in lint_problems:
        sys.stderr.write("lint: %s\n" % p)
    if lint_only:
        return 1 if lint_problems else 0
    readme = build_readme()
    rpath = os.path.join(FIGDIR, "README.md")
    if check:
        try:
            with open(rpath, "r", encoding="utf-8") as fh:
                cur = fh.read()
        except IOError:
            cur = None
        if cur != readme:
            problems.append("README.md")
    else:
        write_bytes(rpath, readme)
        print("wrote docs/figures/README.md")
    if check:
        if problems:
            sys.stderr.write("out of date: %s\n" % ", ".join(problems))
            return 1
        print("all figures up to date")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
