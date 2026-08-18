#!/usr/bin/env python3
"""
Draw the four block diagrams for the AXI4-Lite Firewall, as standalone SVGs.

Ported from the old .odg generator. The drawing code is unchanged - same cm
coordinate system, same styles - because svg_lib deliberately mirrors the
odg_lib API. What changed is the output: four text figures instead of one
zipped-XML document, and the surrounding prose now lives in
doc/axi4_lite_firewall_block_diagrams.md rather than on facing pages.

The page chrome (title band, footer, page number) is gone: it belonged to a
printed page, and these are figures embedded in a document that has its own.

Usage:  python3 build_figures.py [outdir]      default doc/figures
"""

import os
import sys

from svg_lib import Svg, PAGE_W, PAGE_H

CORE = "AXI4-Lite Firewall"
VER = "v2.0"

# ---------------------------------------------------------------- palette
INK      = "#1F3864"   # primary line / bus
INK_FILL = "#DCE6F1"
CORE_L   = "#843C0C"   # the firewall core itself
CORE_F   = "#FDE9D9"
REG_L    = "#375623"   # register block / control
REG_F    = "#E2EFDA"
EXT_L    = "#595959"   # external things
EXT_F    = "#F2F2F2"
RED      = "#C00000"   # irq / error
AMBER    = "#BF8F00"   # peripheral reset
GREY     = "#808080"
HDR_F    = "#1F3864"

d = Svg(f"{CORE} {VER} - block diagrams")

# ---------------------------------------------------------------- styles
def box(name, fill, line, width="0.05cm", valign="middle", dash=None):
    kw = {"draw:fill": "solid", "draw:fill-color": fill,
          "draw:stroke": "dash" if dash else "solid",
          "svg:stroke-width": width, "svg:stroke-color": line,
          "draw:textarea-vertical-align": valign,
          "draw:auto-grow-height": "false", "draw:auto-grow-width": "false",
          "fo:padding-top": "0.1cm", "fo:padding-bottom": "0.1cm",
          "fo:padding-left": "0.15cm", "fo:padding-right": "0.15cm"}
    if dash:
        kw["draw:stroke-dash"] = dash
    d.gstyle(name, **kw)

box("gCore",  CORE_F, CORE_L, "0.08cm")
box("gCoreT", CORE_F, CORE_L, "0.08cm", valign="top")
box("gBlk",   INK_FILL, INK)
box("gBlkT",  INK_FILL, INK, valign="top")
box("gReg",   REG_F, REG_L)
box("gRegT",  REG_F, REG_L, valign="top")
box("gExt",   EXT_F, EXT_L)
box("gExtT",  EXT_F, EXT_L, valign="top")
box("gWhite", "#FFFFFF", GREY, "0.02cm", valign="top")
box("gHdr",   HDR_F, HDR_F, "0.02cm")
box("gCell",  "#FFFFFF", GREY, "0.02cm")
box("gCellA", "#F7F9FC", GREY, "0.02cm")
box("gNote",  "#FFF9E6", AMBER, "0.04cm", valign="top")
box("gWarn",  "#FDECEC", RED, "0.04cm", valign="top")
box("gPort",  "#FFFFFF", INK, "0.04cm")
box("gState", "#FFFFFF", INK, "0.05cm")

d.gstyle("gInvis", **{"draw:fill": "none", "draw:stroke": "none",
                      "draw:auto-grow-height": "true",
                      "fo:padding-top": "0cm", "fo:padding-bottom": "0cm",
                      "fo:padding-left": "0cm", "fo:padding-right": "0cm"})
d.gstyle("gBand", **{"draw:fill": "solid", "draw:fill-color": HDR_F,
                     "draw:stroke": "none"})

def arrow(name, color, width="0.06cm", end=True, start=False, dash=False):
    kw = {"draw:stroke": "dash" if dash else "solid",
          "svg:stroke-width": width, "svg:stroke-color": color,
          "draw:fill": "none"}
    if dash:
        kw["draw:stroke-dash"] = "Dash_20__28_Rounded_29_"
    if end:
        kw.update({"draw:marker-end": "Arrow", "draw:marker-end-width": "0.32cm"})
    if start:
        kw.update({"draw:marker-start": "Arrow", "draw:marker-start-width": "0.32cm"})
    d.gstyle(name, **kw)

arrow("aBus",   INK, "0.09cm")
arrow("aBusBi", INK, "0.09cm", start=True)
arrow("aSig",   INK, "0.045cm")
arrow("aSigBi", INK, "0.045cm", start=True)
arrow("aCtrl",  REG_L, "0.05cm")
arrow("aIrq",   RED, "0.05cm")
arrow("aRst",   AMBER, "0.06cm")
arrow("aPlain", EXT_L, "0.035cm", end=False)
arrow("aState", INK, "0.045cm")
arrow("aRedS",  RED, "0.045cm")

# paragraph + text styles
d.pstyle("pC", "center")
d.pstyle("pL", "start")
d.pstyle("pR", "end")
d.pstyle("pLg", "start", 0.0, 0.12)

d.tstyle("tTitle",  30, bold=True, color="#FFFFFF")   # sits on the dark band
d.tstyle("tSub",    13, color=EXT_L)
d.tstyle("tH1",     19, bold=True, color="#FFFFFF")
d.tstyle("tH1n",    19, bold=True, color=HDR_F)
d.tstyle("tH2",     12, bold=True, color=HDR_F)
d.tstyle("tH2c",    12, bold=True, color=CORE_L)
d.tstyle("tH2g",    12, bold=True, color=REG_L)
d.tstyle("tBlk",    11, bold=True)
d.tstyle("tBlkS",   9)
d.tstyle("tBody",   10)
d.tstyle("tBodyB",  10, bold=True)
d.tstyle("tSmall",  8.5)
d.tstyle("tSmallI", 8.5, italic=True, color=EXT_L)
d.tstyle("tTiny",   7.5, color=EXT_L)
d.tstyle("tBit",    6.5, color=EXT_L)
d.tstyle("tMono",   9,  family="Liberation Mono")
d.tstyle("tMonoB",  9,  bold=True, family="Liberation Mono")
d.tstyle("tMonoS",  8,  family="Liberation Mono")
d.tstyle("tMonoW",  8.5, bold=True, family="Liberation Mono", color="#FFFFFF")
d.tstyle("tRed",    10, bold=True, color=RED)
d.tstyle("tRedS",   8.5, color=RED)
d.tstyle("tAmber",  8.5, bold=True, color=AMBER)
d.tstyle("tHdrW",   9.5, bold=True, color="#FFFFFF")

# ---------------------------------------------------------------- helpers
M = 1.3                      # side margin
CW = PAGE_W - 2 * M          # content width

def chrome(title, num, subtitle=None):
    """Was the printed page's title band and footer; now only reports where
    content starts, so the page bodies below port over unedited. The figures
    are cropped to their drawn extent, so the space this leaves at the top
    costs nothing."""
    return 2.75 if subtitle else 2.35

def hline(y, x0=M, x1=PAGE_W - M):
    d.line(x0, y, x1, y, "aPlain")

def label(x, y, txt, style="tSmall", w=6.0, align="pC"):
    d.text(x - w / 2, y, w, 0.55, [(txt, style)], pstyle=align)

def table(x, y, cols, rows, rh=0.62, hdr=True, aligns=None, fonts=None):
    """cols: list of widths. rows: list of list of str (row 0 = header)."""
    aligns = aligns or ["pL"] * len(cols)
    fonts = fonts or ["tSmall"] * len(cols)
    cy = y
    for r, row in enumerate(rows):
        cx = x
        for c, cell in enumerate(row):
            if hdr and r == 0:
                st, fo = "gHdr", "tHdrW"
            else:
                st = "gCell" if r % 2 else "gCellA"
                fo = fonts[c]
            d.rect(cx, cy, cols[c], rh, st,
                   [(cell, fo)] if cell else None, pstyle=aligns[c])
            cx += cols[c]
        cy += rh
    return cy

def bullets(x, y, w, items, lead=0.0):
    """items: list of (bold_lead, text) or plain str."""
    lines = []
    for it in items:
        if isinstance(it, tuple):
            lines.append((f"•  {it[0]}", "tBodyB"))
            for sub in it[1].split("\n"):
                lines.append((f"     {sub}", "tBody"))
            lines.append(("", "tBody"))
        elif it == "":
            lines.append(("", "tBody"))
        else:
            lines.append((f"•  {it}", "tBody"))
    d.text(x, y, w, 0.0, lines, pstyle="pLg")


# ================================================================ PAGE 2
d.page("System context")
y0 = chrome("1.  System context", 2,
            "Where the core sits, and what must be connected to it.")

# --- external master
d.rect(0.9, 7.4, 4.9, 3.6, "gExt",
       [("Bus master", "tBlk"), ("", "tTiny"),
        ("e.g. Nios II data_master", "tBlkS")])

# --- the core
CX, CY, CWD, CHT = 8.4, 4.3, 12.4, 10.6
d.rect(CX, CY, CWD, CHT, "gCoreT",
       [("axi_firewall_top", "tH2c")])
d.text(CX, CY + 0.95, CWD, 0.6,
       [("access control  +  fault isolation", "tSmallI")], pstyle="pC")

# Port stubs straddling the core boundary. Width is set per stub from the
# label length - a fixed 1.8 cm clipped "s_axi_ctrl".
def port(cx_edge, y, txt, w=None, h=0.95, font="tMonoB"):
    w = w or max(1.9, 0.22 * len(txt) + 0.6)
    d.rect(cx_edge - w / 2, y, w, h, "gPort", [(txt, font)])
    return w

port(CX, 5.7, "s_axi")
port(CX, 11.9, "s_axi_ctrl", w=2.9)
port(CX + CWD, 5.7, "m_axi")
# clear of the inner summary blocks, which end at y = 11.7
# v2.0: no peripheral reset output. The core has four interfaces.
# irq sits clear above the core so it cannot collide with the core's title
d.rect(CX + CWD - 5.0, CY - 1.25, 2.0, 0.95, "gPort", [("irq", "tMonoB")])
d.line(CX + CWD - 4.0, CY - 0.3, CX + CWD - 4.0, CY, "aPlain")

# inner summary blocks
d.rect(CX + 0.9, 6.9, 4.6, 1.5, "gBlk",
       [("Rule check", "tBlkS"), ("range + direction", "tTiny")])
d.rect(CX + 6.7, 6.9, 4.6, 1.5, "gBlk",
       [("Timeout watch", "tBlkS"), ("round trip", "tTiny")])
d.rect(CX + 0.9, 8.8, 4.6, 1.5, "gReg",
       [("Rule table", "tBlkS"), ("NUM_RULES entries", "tTiny")])
d.rect(CX + 6.7, 8.8, 4.6, 1.5, "gReg",
       [("Status / IRQ", "tBlkS"), ("sticky, W1C", "tTiny")])
d.rect(CX + 0.9, 10.7, 10.4, 1.0, "gBlk",
       [("Isolate + downstream recovery", "tBlkS")])

# --- protected peripheral
d.rect(23.6, 7.4, 5.2, 3.6, "gExt",
       [("Protected", "tBlk"), ("peripheral", "tBlk"), ("", "tTiny"),
        ("AXI4-Lite or Avalon-MM", "tBlkS")])

# --- data path arrows
# The sub-labels sit at 6.8, clear of the port stubs, which end at y = 6.65.
# At 6.45 they ran under the stub and "data path" came out as "data pa".
d.line(5.8, 6.2, CX - 0.95, 6.2, "aBusBi")
label(7.1, 5.35, "AXI4-Lite", "tSmall", 3.2)
label(7.1, 6.8, "data path", "tTiny", 3.2)

d.line(CX + CWD + 0.95, 6.2, 23.6, 6.2, "aBusBi")
label(23.0, 5.35, "AXI4-Lite", "tSmall", 3.2)
label(23.0, 6.8, "forwarded", "tTiny", 3.2)

# --- control path
d.polyline([(3.35, 11.0), (3.35, 12.4), (CX - 1.45, 12.4)], "aBusBi")
label(5.0, 12.5, "AXI4-Lite  config / status", "tSmall", 5.4)
d.text(1.0, 13.6, 6.6, 0.0,
       [("Separate port on purpose: configuring or inspecting the firewall "
         "must never be blockable by a firewall rule, nor by an isolated "
         "peripheral.", "tTiny")], pstyle="pLg")

# --- irq
d.polyline([(CX + CWD - 5.0, CY - 0.78), (3.35, CY - 0.78), (3.35, 7.4)],
           "aIrq")
d.text(6.0, CY - 1.35, 9.5, 0.5,
       [("irq   (level, cleared by W1C on STATUS)", "tRedS")], pstyle="pC")

# --- peripheral reset: software's job in v2.0, not the core's
d.rect(21.6, 12.2, 7.4, 3.1, "gNote", None)
d.text(21.9, 12.4, 6.8, 0.0,
       [("Peripheral reset (yours)", "tAmber"),
        ("Recovering from a timeout requires resetting the protected "
         "peripheral before writing RECOVERY.UNBLOCK. v2.0 removed the reset "
         "output, so this is now a software step.", "tTiny")],
       pstyle="pLg")
d.polyline([(25.3, 12.2), (25.3, 11.0)], "aRst")

# --- clock / reset
d.rect(0.9, 16.6, 4.9, 1.5, "gExt", [("clock / reset", "tBlkS"),
                                     ("system clock domain", "tTiny")])
d.polyline([(3.35, 16.6), (3.35, 15.6), (CX + CWD / 2, 15.6),
            (CX + CWD / 2, CY + CHT)], "aSig")
label(11.0, 15.65, "clk, resetn  (single clock domain, synchronous reset)",
      "tTiny", 10.0)

# --- legend
d.rect(17.2, 16.4, 11.5, 3.0, "gWhite", None)
d.text(17.5, 16.55, 11.0, 0.0, [("Legend", "tH2")], pstyle="pL")
lg = 17.6
d.line(lg, 17.55, lg + 1.5, 17.55, "aBus")
d.text(lg + 1.8, 17.28, 3.4, 0.5, [("AXI4-Lite bus", "tTiny")], pstyle="pL")
d.line(lg, 18.25, lg + 1.5, 18.25, "aIrq")
d.text(lg + 1.8, 17.98, 3.4, 0.5, [("interrupt", "tTiny")], pstyle="pL")
d.line(lg, 18.95, lg + 1.5, 18.95, "aRst")
d.text(lg + 1.8, 18.68, 3.4, 0.5, [("reset (software)", "tTiny")], pstyle="pL")
d.line(lg + 5.9, 17.55, lg + 7.4, 17.55, "aSig")
d.text(lg + 7.7, 17.28, 3.2, 0.5, [("clock / control", "tTiny")], pstyle="pL")
d.rect(lg + 5.9, 18.0, 1.5, 0.55, "gReg", None)
d.text(lg + 7.7, 17.98, 3.2, 0.5, [("register block", "tTiny")], pstyle="pL")
d.rect(lg + 5.9, 18.7, 1.5, 0.55, "gExt", None)
d.text(lg + 7.7, 18.68, 3.2, 0.5, [("outside the core", "tTiny")], pstyle="pL")

# ================================================================ PAGE 4
d.page("Internal architecture")
chrome("2.  Internal architecture", 4,
       "Inside axi_firewall_top: two independent datapaths, one register "
       "block, one recovery controller.")

OX, OY, OW, OH = 0.8, 3.4, 28.1, 14.7
d.rect(OX, OY, OW, OH, "gCoreT", None)
d.text(OX + 0.35, OY + 0.12, 8.0, 0.6, [("axi_firewall_top", "tH2c")],
       pstyle="pL")

# Layout note: the datapaths own the left third, the register block the right
# half, and the 4 cm channel between them carries only the lookup and fault
# signals. m_axi leaves along the bottom-right, under the register block,
# where there is clear horizontal room for its labels.
WX, WY, WW, WH = 4.3, 4.5, 8.3, 4.6      # write datapath
RX, RY = 4.3, 9.5                         # read datapath
GX, GY, GW, GH = 16.9, 4.5, 11.2, 9.4     # register block
VX, VY, VW, VH = 4.3, 14.5, 8.3, 3.0      # recovery

d.rect(WX, WY, WW, WH, "gBlkT", [("Write datapath", "tH2")])
d.text(WX + 0.3, WY + 0.8, WW - 0.6, 0.0, [
    ("wr_state:  IDLE → EVAL → FWD → RESP", "tMonoS"),
    ("", "tTiny"),
    ("captures AWADDR / WDATA, applies the", "tSmall"),
    ("rule verdict, forwards or synthesises an", "tSmall"),
    ("error response, and runs the round-trip", "tSmall"),
    ("timeout counter wr_timeout_cnt.", "tSmall"),
], pstyle="pLg")

d.rect(RX, RY, WW, WH, "gBlkT", [("Read datapath", "tH2")])
d.text(RX + 0.3, RY + 0.8, WW - 0.6, 0.0, [
    ("rd_state:  IDLE → EVAL → FWD → RESP", "tMonoS"),
    ("", "tTiny"),
    ("mirrors the write path with its own", "tSmall"),
    ("capture registers, its own lookup port", "tSmall"),
    ("and its own fault signals. Denied reads", "tSmall"),
    ("drive RDATA to zero.", "tSmall"),
], pstyle="pLg")

d.rect(VX, VY, VW, VH, "gWhite", None)
d.text(VX + 0.3, VY + 0.12, VW - 0.6, 0.0, [
    ("Downstream recovery", "tH2"),
    ("downstream_broken, cleared only by RECOVERY.UNBLOCK", "tMonoS"),
    ("Blocks forwarding regardless of AUTO_ISOLATE_EN.", "tSmall"),
    ("Tracks WR/RD_RESP_BUSY and WR/RD_CMD_STUCK.", "tSmall"),
], pstyle="pLg")

d.rect(GX, GY, GW, GH, "gRegT", None)
d.text(GX + 0.35, GY + 0.12, 8.0, 0.6, [("axi_firewall_regs", "tH2g")],
       pstyle="pL")
d.rect(GX + 0.4, GY + 0.85, GW - 0.8, 1.25, "gWhite",
       [("AXI4-Lite control slave", "tBlkS"),
        ("single-outstanding, backpressured", "tTiny")])
d.rect(GX + 0.4, GY + 2.3, GW - 0.8, 2.1, "gWhite",
       [("Rule table  [0 .. NUM_RULES-1]", "tBlkS"), ("", "tTiny"),
        ("rule_base / rule_limit / rule_perm", "tMonoS"),
        ("rule_perm = {valid, wr_en, rd_en}", "tMonoS")])
d.rect(GX + 0.4, GY + 4.6, 5.0, 1.85, "gWhite",
       [("Lookup port W", "tBlkS"), ("combinational,", "tTiny"),
        ("lowest index wins", "tTiny")])
d.rect(GX + 5.8, GY + 4.6, 5.0, 1.85, "gWhite",
       [("Lookup port R", "tBlkS"), ("combinational,", "tTiny"),
        ("independent of W", "tTiny")])
d.rect(GX + 0.4, GY + 6.65, GW - 0.8, 2.25, "gWhite",
       [("Control / status / IRQ", "tBlkS"), ("", "tTiny"),
        ("CTRL   STATUS (sticky, W1C)   IRQ_ENABLE", "tMonoS"),
        ("TIMEOUT_VALUE   FAULT_ADDR   FAULT_INFO", "tMonoS")])

# ---- channel routing
#
# The 4.3 cm gap between the datapaths and the register block carries five
# signal groups. Each gets its own vertical lane, and every label is placed
# in a band where no lane is active - otherwise a routing line draws straight
# through the text. Lanes, left to right:
#     x = 13.0   m_axi bundle (both datapaths merge onto it)
#     x = 14.7   unblock
#     x = 15.9   fault_*
LANE_M, LANE_ACK, LANE_FLT = 13.0, 14.7, 15.9

# Short labels here, expanded underneath: the full names wrap at this
# channel width and the second line lands on the arrow.
d.line(WX + WW, 6.6, GX, 6.6, "aSigBi")
d.text(WX + WW + 0.15, 6.02, GX - WX - WW - 0.3, 0.5,
       [("chk_w_*", "tMonoS")], pstyle="pC")

d.line(RX + WW, 11.6, GX, 11.6, "aSigBi")
d.text(13.25, 11.02, 2.5, 0.5, [("chk_r_*", "tMonoS")], pstyle="pC")

d.polyline([(WX + WW, 8.3), (LANE_FLT, 8.3), (LANE_FLT, 13.3), (GX, 13.3)],
           "aSig")
d.text(12.75, 7.72, 3.0, 0.5, [("fault_*", "tMonoS")], pstyle="pL")

d.polyline([(GX, 12.6), (LANE_ACK, 12.6), (LANE_ACK, 15.9), (VX + VW, 15.9)],
           "aCtrl")
d.text(12.75, 15.32, 1.9, 0.5, [("unblock", "tMonoS")], pstyle="pL")

d.polyline([(VX + VW, 16.55), (16.6, 16.55), (16.6, 7.55), (RX + WW, 7.55)],
           "aCtrl")
d.text(4.5, 17.62, 11.4, 0.5,
       [("forward_blocked, global_enable, isolate_effective, timeout_value",
         "tMonoS")], pstyle="pL")

# ---- external ports
d.rect(1.0, 5.9, 2.7, 0.95, "gPort", [("s_axi", "tMonoB")])
d.text(1.0, 6.8, 2.7, 0.5, [("write", "tTiny")], pstyle="pC")
d.line(3.7, 6.37, WX, 6.37, "aBus")
d.rect(1.0, 10.9, 2.7, 0.95, "gPort", [("s_axi", "tMonoB")])
d.text(1.0, 11.8, 2.7, 0.5, [("read", "tTiny")], pstyle="pC")
d.line(3.7, 11.37, RX, 11.37, "aBus")

d.rect(GX + GW - 3.4, OY - 1.25, 3.4, 0.95, "gPort", [("s_axi_ctrl", "tMonoB")])
d.line(GX + GW - 1.7, OY - 0.3, GX + GW - 1.7, GY, "aBus")
d.rect(GX + 0.6, OY - 1.25, 2.2, 0.95, "gPort", [("irq", "tMonoB")])
d.line(GX + 1.7, GY, GX + 1.7, OY - 0.3, "aIrq")

# m_axi is one physical port, so both datapaths merge onto a single bus that
# leaves along the bottom right - under the register block, where there is
# clear horizontal room for the channel list.
#
# It gets a port stub like every other interface. It previously had only a
# text label on the line, which made it the one interface drawn differently
# from the rest and read as though the core had no master port at all.
M_AXI_Y = 14.45
m_w = port(28.9, M_AXI_Y - 0.475, "m_axi")
d.polyline([(WX + WW, 8.75), (LANE_M, 8.75), (LANE_M, M_AXI_Y),
            (28.9 - m_w / 2, M_AXI_Y)], "aBus")
d.polyline([(RX + WW, 13.75), (LANE_M, 13.75)], "aBus")
d.text(17.4, 13.87, 9.6, 0.5,
       [("(AW, W, B, AR, R)", "tMonoS")], pstyle="pL")
d.text(17.4, 16.45, 11.0, 0.5,
       [("(v2.0: no peripheral reset output)", "tSmallI")], pstyle="pL")


# ================================================================ PAGE 6
d.page("Datapath state machines")
chrome("3.  Datapath state machines", 6,
       "Both FSMs are enum-typed, so Questa names the states in its coverage "
       "report. All 14 transitions are covered by the test suite.")

def fsm(x0, title, pre):
    d.text(x0, 3.0, 12.6, 0.6, [(title, "tH2")], pstyle="pL")
    sw, sh = 3.4, 1.35
    cx = x0 + 1.4
    # states start below the title so the "reset from any state" arrow, which
    # runs 0.8 cm above the first state, cannot strike through the heading
    ys = [4.75, 7.6, 10.45, 13.3]
    names = [f"{pre}_IDLE", f"{pre}_EVAL", f"{pre}_FWD", f"{pre}_RESP"]
    subs = ["wait, capture request", "apply the verdict",
            "drive m_axi, count timeout", "hold response for master"]
    for n, s, yy in zip(names, subs, ys):
        d.rect(cx, yy, sw, sh, "gState", [(n, "tMonoB"), (s, "tTiny")])
    # straight-through transitions
    for a, b in zip(ys[:-1], ys[1:]):
        d.line(cx + sw / 2, a + sh, cx + sw / 2, b, "aState")
    d.text(cx + sw / 2 + 0.2, ys[0] + sh + 0.05, 5.0, 0.5,
           [("request accepted", "tTiny")], pstyle="pL")
    d.text(cx + sw / 2 + 0.2, ys[1] + sh + 0.05, 5.0, 0.5,
           [("allowed  →  forward", "tTiny")], pstyle="pL")
    d.text(cx + sw / 2 + 0.2, ys[2] + sh + 0.05, 5.0, 0.5,
           [("response or timeout", "tTiny")], pstyle="pL")
    # EVAL -> RESP bypass (denied)
    d.polyline([(cx + sw, ys[1] + sh / 2), (cx + sw + 1.9, ys[1] + sh / 2),
                (cx + sw + 1.9, ys[3] + sh / 2), (cx + sw, ys[3] + sh / 2)],
               "aRedS")
    d.text(cx + sw + 2.1, ys[1] + 1.5, 4.4, 0.0,
           [("denied", "tRedS"),
            ("DECERR: no rule", "tTiny"),
            ("SLVERR: direction,", "tTiny"),
            ("isolated, or broken", "tTiny")], pstyle="pLg")
    # RESP -> IDLE return
    d.polyline([(cx, ys[3] + sh / 2), (cx - 1.05, ys[3] + sh / 2),
                (cx - 1.05, ys[0] + sh / 2), (cx, ys[0] + sh / 2)], "aState")
    # Right-aligned so it sits clear of the return line at cx-1.05 rather than
    # straddling it. The figure is cropped to its drawn extent, so overhanging
    # the old A4 left margin costs nothing.
    d.text(cx - 2.9, 8.75, 1.75, 0.0, [("handshake", "tTiny"),
                                       ("complete", "tTiny")], pstyle="pR")
    # reset
    d.polyline([(cx + sw + 1.0, ys[0] - 0.8), (cx + sw / 2 + 0.9, ys[0] - 0.8),
                (cx + sw / 2 + 0.9, ys[0])], "aState")
    d.text(cx + sw + 1.15, ys[0] - 1.08, 4.6, 0.5,
           [("resetn low, from any state", "tTiny")], pstyle="pL")

fsm(1.0, "Write datapath  (wr_state)", "WR")
fsm(16.0, "Read datapath  (rd_state)", "RD")

# ================================================================ PAGE 8
d.page("Register map")
chrome("4.  Register map and rule table", 8,
       "All registers are 32 bit and word aligned on s_axi_ctrl. Reset "
       "values are shown; the core comes up secure by default.")


# --- bit field diagrams
# Sub-labels are the longest strings on the page, so they set the minimum
# field width. 6.5 pt plus generous fractions on the single-bit fields keeps
# ADDR_VIOLATION and AUTO_ISOLATE_EN inside their boxes.
BFX, BFW = M, 13.2

def bitfield(x, y, title, fields, width=BFW):
    """fields: list of (label, sublabel, span_fraction)."""
    d.text(x, y, width, 0.5, [(title, "tH2")], pstyle="pL")
    bx, bh = x, 1.35
    for lab, sub, fr in fields:
        w = width * fr
        d.rect(bx, y + 0.55, w, bh, "gCell",
               [(lab, "tMonoB")] + ([(sub, "tBit")] if sub else []))
        bx += w

bitfield(BFX, 3.0, "CTRL  (0x00)", [
    ("31:3", "reserved", 0.28),
    ("2", "MANUAL_ISOLATE", 0.24),
    ("1", "AUTO_ISOLATE_EN", 0.24),
    ("0", "GLOBAL_ENABLE", 0.24),
])

bitfield(BFX, 5.3, "STATUS  (0x04)   -   bits 2:0 sticky, write 1 to clear", [
    ("8:7", "RD/WR_CMD_STUCK", 0.24),
    ("6:5", "RD/WR_RESP_BUSY", 0.24),
    ("4", "BLOCKED", 0.13),
    ("3", "ISOLATED", 0.13),
    ("2:0", "the three sticky bits", 0.26),
])

bitfield(BFX, 7.6, "FAULT_INFO  (0x14)", [
    ("31:4", "reserved", 0.34),
    ("3:1", "type: 1=ADDR 2=PERM 3=TIMEOUT", 0.42),
    ("0", "WAS_WRITE", 0.24),
])

bitfield(BFX, 9.9, "RULE_PERM[i]  (0x48 + i·0x10)", [
    ("31:3", "reserved", 0.34),
    ("2", "VALID", 0.20),
    ("1", "WRITE_ALLOW", 0.23),
    ("0", "READ_ALLOW", 0.23),
])

bitfield(BFX, 12.2, "CORE_INFO  (0x18)", [
    ("31:16", "version  0x0200 = v2.0", 0.44),
    ("15:8", "reserved", 0.28),
    ("7:0", "NUM_RULES", 0.28),
])
# ------------------------------------------------------------------ output
NAMES = {0: "fig_context", 1: "fig_internal", 2: "fig_fsm", 3: "fig_registers"}
# Every tool under doc/tools resolves paths from its own location rather than
# the caller's cwd, so it works the same run from anywhere.
DOC = os.path.abspath(os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "..", ".."))
outdir = sys.argv[1] if len(sys.argv) > 1 else os.path.join(DOC, "figures")
for p in d.save(outdir, NAMES):
    print("written:", os.path.normpath(p))
