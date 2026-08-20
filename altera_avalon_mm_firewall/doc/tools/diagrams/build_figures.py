#!/usr/bin/env python3
"""
Draw the block diagrams for the Avalon-MM Firewall, as standalone SVGs.

Drawn from code rather than in a drawing tool, for the same reason the timing
figures are cut from a VCD: a diagram nobody can diff is a diagram that goes
stale silently. The register bit fields in particular are checked back against
the RTL by doc/tools/check_facts.py, which can only do that because they are
text.

svg_lib.py is shared verbatim with the AXI4-Lite firewall's generator; only
the figure definitions below are specific to this core.

Usage:  python3 build_figures.py [outdir]      default doc/figures
"""

import os
import sys

from svg_lib import Svg, PAGE_W, PAGE_H       # noqa: F401

CORE = "Avalon-MM Firewall"
VER = "v1.0"

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
box("gDeny",  "#FDECEC", RED, "0.05cm")
box("gAllow", "#E2EFDA", REG_L, "0.05cm")

d.gstyle("gInvis", **{"draw:fill": "none", "draw:stroke": "none",
                      "draw:auto-grow-height": "true",
                      "fo:padding-top": "0cm", "fo:padding-bottom": "0cm",
                      "fo:padding-left": "0cm", "fo:padding-right": "0cm"})


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
arrow("aCtrl",  REG_L, "0.05cm")
arrow("aIrq",   RED, "0.05cm")
arrow("aRst",   AMBER, "0.06cm", dash=True)
arrow("aRed",   RED, "0.05cm")
arrow("aPlain", EXT_L, "0.035cm", end=False)

d.pstyle("pC", "center")
d.pstyle("pL", "start")
d.pstyle("pR", "end")
d.pstyle("pLg", "start", 0.0, 0.12)

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
d.tstyle("tRed",    10, bold=True, color=RED)
d.tstyle("tRedS",   8.5, color=RED)
d.tstyle("tGrn",    8.5, bold=True, color=REG_L)
d.tstyle("tAmber",  8.5, bold=True, color=AMBER)
d.tstyle("tHdrW",   9.5, bold=True, color="#FFFFFF")

M = 1.3


def label(x, y, txt, style="tSmall", w=6.0, align="pC"):
    d.text(x - w / 2, y, w, 0.55, [(txt, style)], pstyle=align)


def table(x, y, cols, rows, rh=0.62, hdr=True, aligns=None, fonts=None):
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


def port(cx_edge, y, txt, w=None, h=0.95, font="tMonoB"):
    w = w or max(1.9, 0.22 * len(txt) + 0.6)
    d.rect(cx_edge - w / 2, y, w, h, "gPort", [(txt, font)])
    return w


# ================================================================ FIGURE 1
d.page("System context")

# --- external master
d.rect(0.9, 6.6, 5.0, 3.4, "gExt",
       [("Bus master", "tBlk"), ("", "tTiny"),
        ("Nios II data master, mSGDMA,", "tBlkS"),
        ("or any Avalon-MM host", "tBlkS")])

# --- the core
CX, CY, CWD, CHT = 8.6, 3.4, 12.0, 11.4
d.rect(CX, CY, CWD, CHT, "gCoreT", [("avl_mm_firewall_top", "tH2c")])
d.text(CX, CY + 0.95, CWD, 0.6,
       [("burst-capable access control  +  fault isolation", "tSmallI")],
       pstyle="pC")

port(CX, 7.6, "s0")
port(CX + CWD, 7.6, "m0")
port(CX + CWD / 2, CY + CHT - 0.95, "csr")

d.text(CX + 0.6, 5.3, CWD - 1.2, 1.8,
       [("A gate, not a buffer.", "tBodyB"),
        ("Permitted traffic passes straight through:", "tSmall"),
        ("no added latency, no data storage.", "tSmall")], pstyle="pC")

d.text(CX + 0.6, 9.4, CWD - 1.2, 2.2,
       [("Refused traffic never reaches m0 —", "tRedS"),
        ("the firewall answers the master itself,", "tRedS"),
        ("beat for beat.", "tRedS")], pstyle="pC")

# --- protected peripheral
d.rect(23.3, 6.6, 5.0, 3.4, "gExt",
       [("Protected peripheral", "tBlk"), ("", "tTiny"),
        ("Avalon-MM agent, bursting", "tBlkS"),
        ("or not", "tBlkS")])

# --- CPU / software
d.rect(11.0, 17.2, 7.2, 2.4, "gReg",
       [("Processor", "tBlk"), ("configures rules, handles irq", "tBlkS")])

# --- reset source
d.rect(21.4, 17.2, 6.9, 2.4, "gExt",
       [("Peripheral reset", "tBlk"),
        ("PIO or reset bridge — YOURS, not the core's", "tBlkS")])

# --- connections
d.line(5.9, 8.08, CX - 0.95, 8.08, "aBusBi")
d.line(CX + CWD + 0.95, 8.08, 23.3, 8.08, "aBusBi")
label(7.2, 7.0, "Avalon-MM", "tTiny", 3.0)
label(22.2, 7.0, "Avalon-MM", "tTiny", 3.0)

d.polyline([(14.6, 17.2), (14.6, CY + CHT + 0.0)], "aBusBi")
label(16.4, 16.0, "csr — never blockable", "tTiny", 5.4)

d.polyline([(17.4, CY + CHT - 0.4), (19.6, CY + CHT - 0.4),
            (19.6, 18.4), (18.2, 18.4)], "aIrq")
label(20.9, 15.2, "irq", "tRedS", 2.0)

d.polyline([(24.9, 17.2), (24.9, 10.0)], "aRst")
label(26.9, 13.4, "reset for recovery", "tAmber", 4.6)

d.rect(0.9, 12.4, 7.0, 4.6, "gNote",
       [("Address map is unchanged", "tBodyB"),
        ("", "tTiny"),
        ("s0 declares bridgesToMaster m0, so", "tSmall"),
        ("s0's address space IS m0's. Inserting", "tSmall"),
        ("the firewall into an existing path", "tSmall"),
        ("moves nothing.", "tSmall")])

d.rect(0.9, 17.6, 7.0, 4.2, "gWarn",
       [("Not optional", "tBodyB"),
        ("", "tTiny"),
        ("Without a software-controllable", "tSmall"),
        ("peripheral reset, recovery from a", "tSmall"),
        ("timeout cannot complete.", "tSmall")])


# ================================================================ FIGURE 2
d.page("Internal architecture")

CX, CY, CWD, CHT = 1.2, 1.0, 27.0, 17.0
d.rect(CX, CY, CWD, CHT, "gCoreT", [("avl_mm_firewall_top", "tH2c")])

# --- s0 / m0 stubs
port(CX, 4.6, "s0", h=1.1)
port(CX + CWD, 4.6, "m0", h=1.1)

# --- the gate itself
d.rect(9.6, 3.6, 10.2, 3.1, "gBlk",
       [("PASS-THROUGH GATE", "tBodyB"),
        ("m0_read/m0_write = s0 gated by the verdict", "tSmall"),
        ("s0_waitrequest = m0_waitrequest, unmodified", "tSmall")])
d.line(2.2, 5.15, 9.6, 5.15, "aBus")
d.line(19.8, 5.15, CX + CWD - 0.95, 5.15, "aBus")

# --- extent calculation
d.rect(3.0, 8.0, 5.6, 2.6, "gBlk",
       [("BURST EXTENT", "tBodyB"),
        ("last = addr + count·bytes − 1", "tMonoS"),
        ("+ wrap detect", "tSmall")])
d.polyline([(5.8, 8.0), (5.8, 6.7)], "aSig", )
d.polyline([(5.8, 6.7), (5.8, 5.15)], "aSig")

# --- rule lookup
d.rect(9.6, 8.0, 10.2, 4.6, "gReg",
       [("RULE LOOKUP  ×2  (read, write)", "tH2g"),
        ("", "tTiny"),
        ("lowest-index valid window containing", "tSmall"),
        ("the FIRST byte wins; the SAME window", "tSmall"),
        ("must also contain the LAST byte", "tSmall"),
        ("", "tTiny"),
        ("purely combinational — this is the critical path", "tSmallI")])
d.line(8.6, 9.3, 9.6, 9.3, "aSig")
d.polyline([(14.7, 8.0), (14.7, 6.7)], "aCtrl")
label(17.6, 7.1, "verdict", "tGrn", 3.0)

# --- deny responder
d.rect(21.2, 8.0, 6.2, 4.6, "gDeny",
       [("DENY RESPONDER", "tRed"),
        ("", "tTiny"),
        ("synthesises one beat", "tSmall"),
        ("per cycle until the", "tSmall"),
        ("burst's debt is paid", "tSmall"),
        ("", "tTiny"),
        ("rd_deny_beats", "tMonoS")])
# The deny responder does not feed the lookup - it feeds the master. Draw it
# as what it is: a path back to s0 that bypasses m0 entirely.
d.polyline([(24.3, 8.0), (24.3, 7.2), (2.2, 7.2), (2.2, 5.8)], "aRed")
label(6.0, 6.5, "refused traffic is answered here, never forwarded", "tRedS", 9.0)

# --- timeout / block
d.rect(3.0, 13.4, 8.4, 3.9, "gBlk",
       [("PROGRESS WATCHDOG", "tBodyB"),
        ("", "tTiny"),
        ("counts cycles WITHOUT PROGRESS,", "tSmall"),
        ("not transaction length", "tSmall"),
        ("", "tTiny"),
        ("on expiry: complete upstream, block,", "tSmall"),
        ("FREEZE any unhandshaked command", "tSmall")])

d.rect(12.6, 13.4, 7.2, 3.9, "gWarn",
       [("downstream_broken", "tMonoB"),
        ("", "tTiny"),
        ("blocks all forwarding", "tSmall"),
        ("regardless of the", "tSmall"),
        ("isolate bits", "tSmall"),
        ("", "tTiny"),
        ("cleared ONLY by UNBLOCK", "tRedS")])
d.line(11.4, 15.3, 12.6, 15.3, "aRed")
d.polyline([(16.2, 13.4), (16.2, 12.6)], "aRed")

# --- register block
d.rect(21.2, 13.4, 6.2, 3.9, "gReg",
       [("REGISTER BLOCK", "tH2g"),
        ("", "tTiny"),
        ("rule table", "tSmall"),
        ("sticky status + irq", "tSmall"),
        ("fault latch", "tSmall"),
        ("recovery", "tSmall")])
# Status flows from the block latch to the register block, not the reverse.
d.line(19.8, 15.3, 21.2, 15.3, "aCtrl")
d.polyline([(24.3, 13.4), (24.3, 12.6)], "aCtrl")

port(CX + CWD / 2, CY + CHT - 0.55, "csr")
d.polyline([(14.7, CY + CHT + 0.4), (14.7, 17.3)], "aCtrl")

d.text(1.6, 18.4, 26.0, 1.0,
       [("There is no data storage anywhere in the data path. "
         "Refused traffic is the only thing the core generates itself.",
         "tSmallI")], pstyle="pC")


# ================================================================ FIGURE 3
d.page("Verdict")

d.text(1.2, 0.8, 22.0, 0.7,
       [("How one transaction is judged", "tH2")], pstyle="pL")
d.text(1.2, 1.6, 22.0, 0.7,
       [("Evaluated combinationally at the first beat, then held for the "
         "whole burst.", "tSmallI")], pstyle="pL")

BX, BW_, BH = 2.0, 8.4, 1.5
DX = 13.4          # x of the deny boxes
STEP = 2.35
y = 2.9

steps = [
    ("downstream blocked or isolated?", "yes → SLAVEERROR", "no new fault is latched"),
    ("GLOBAL_ENABLE = 0 ?", "yes → forward", "bypass skips the rule check only"),
    ("any valid window holds the first byte?", "no → DECODEERROR", "STATUS.ADDR_VIOLATION"),
    ("does that window permit this direction?", "no → SLAVEERROR", "STATUS.PERM_VIOLATION"),
    ("does it also hold the LAST byte?", "no → DECODEERROR", "STATUS.BURST_VIOLATION  type 4"),
    ("if a burst, does it permit bursts?", "no → SLAVEERROR", "STATUS.BURST_VIOLATION  type 5"),
]

for i, (q, verdict, note) in enumerate(steps):
    yy = y + i * STEP
    style = "gAllow" if i == 1 else "gBlk"
    d.rect(BX, yy, BW_, BH, style, [(q, "tBody")])
    d.line(BX + BW_, yy + BH / 2, DX, yy + BH / 2, "aRed" if i != 1 else "aCtrl")
    d.rect(DX, yy, 6.4, BH, "gAllow" if i == 1 else "gDeny",
           [(verdict, "tGrn" if i == 1 else "tRedS")])
    d.text(DX + 6.8, yy + 0.28, 8.0, 0.9, [(note, "tTiny")], pstyle="pL")
    if i < len(steps) - 1:
        d.polyline([(BX + BW_ / 2, yy + BH), (BX + BW_ / 2, yy + STEP)], "aSig")

yy = y + len(steps) * STEP
d.rect(BX, yy, BW_, BH, "gAllow", [("forward to m0", "tBodyB")])
d.polyline([(BX + BW_ / 2, yy - STEP + BH), (BX + BW_ / 2, yy)], "aSig")

d.rect(DX, yy - 0.2, 13.2, 2.0, "gNote",
       [("Direction is checked BEFORE extent, so a write burst into a "
         "read-only window", "tSmall"),
        ("reports a permission violation rather than a confusing burst error.",
         "tSmall")])

d.rect(1.2, yy + 2.6, 25.4, 2.2, "gWarn",
       [("Every refusal still COMPLETES the transaction upstream.", "tBodyB"),
        ("Avalon-MM has no abort: a refused N-beat read must still produce N "
         "beats of readdatavalid, and a refused write must still have all N "
         "beats consumed.", "tSmall")])


# ================================================================ FIGURE 4
d.page("Register map")

BFX, BFW = 1.4, 25.0


def bitfield(x, y, title, fields, width=BFW):
    """fields: list of (label, sublabel, span_fraction)."""
    d.text(x, y, width, 0.5, [(title, "tH2")], pstyle="pL")
    bx, bh = x, 1.35
    for lab, sub, fr in fields:
        w = width * fr
        d.rect(bx, y + 0.55, w, bh, "gCell",
               [(lab, "tMonoB")] + ([(sub, "tBit")] if sub else []))
        bx += w


d.text(BFX, 0.7, BFW, 0.7,
       [("csr register map — byte offsets", "tH2")], pstyle="pL")
d.text(BFX, 1.4, BFW, 0.6,
       [("The port is word-addressed in hardware; the interconnect does the "
         "divide-by-four, so software uses these offsets directly.",
         "tSmallI")], pstyle="pL")

table(BFX, 2.3, [3.2, 5.4, 3.0, 13.4],
      [["Offset", "Name", "Access", "Purpose"],
       ["0x00", "CTRL", "R/W", "enable, auto-isolate, manual isolate"],
       ["0x04", "STATUS", "R / W1C", "four sticky faults, six live status bits"],
       ["0x08", "IRQ_ENABLE", "R/W", "one mask bit per sticky fault"],
       ["0x0C", "TIMEOUT_VALUE", "R/W", "cycles WITHOUT PROGRESS before giving up"],
       ["0x10", "FAULT_ADDR", "R", "start address of the latched fault"],
       ["0x14", "FAULT_INFO", "R", "direction, cause, burst length"],
       ["0x18", "CORE_INFO", "R", "generated parameters and version"],
       ["0x1C", "RECOVERY", "W", "UNBLOCK — the one authorised discard"],
       ["0x40+i·0x10", "RULE_BASE[i]", "R/W", "first byte of window i, inclusive"],
       ["0x44+i·0x10", "RULE_LIMIT[i]", "R/W", "last byte of window i, inclusive"],
       ["0x48+i·0x10", "RULE_PERM[i]", "R/W", "read / write / valid / burst"]],
      fonts=["tMonoS", "tMonoS", "tSmall", "tSmall"])

bitfield(BFX, 11.2, "CTRL  (0x00)", [
    ("31:3", "reserved", 0.34),
    ("2", "MANUAL_ISOLATE", 0.22),
    ("1", "AUTO_ISOLATE_EN   reset 1", 0.22),
    ("0", "GLOBAL_ENABLE   reset 1", 0.22),
])

bitfield(BFX, 13.5, "STATUS  (0x04)   —   bits 3:0 sticky, write 1 to clear", [
    ("9:8", "RD/WR_CMD_STUCK", 0.20),
    ("7:6", "RD/WR_BUSY", 0.16),
    ("5", "BLOCKED", 0.12),
    ("4", "ISOLATED", 0.12),
    ("3", "BURST_VIOLATION", 0.15),
    ("2:0", "TIMEOUT, PERM, ADDR", 0.25),
])

bitfield(BFX, 15.8, "FAULT_INFO  (0x14)", [
    ("31:16", "reserved", 0.26),
    ("15:8", "BURSTCOUNT  saturating", 0.26),
    ("7:4", "reserved", 0.16),
    ("3:1", "1=ADDR 2=PERM 3=TIMEOUT 4=BURST_RANGE 5=BURST_DENIED", 0.20),
    ("0", "WAS_WRITE", 0.12),
])

bitfield(BFX, 18.1, "RULE_PERM[i]  (0x48 + i·0x10)", [
    ("31:4", "reserved", 0.34),
    ("3", "BURST_ALLOW", 0.17),
    ("2", "VALID", 0.16),
    ("1", "WRITE_ALLOW", 0.17),
    ("0", "READ_ALLOW", 0.16),
])

bitfield(BFX, 20.4, "CORE_INFO  (0x18)", [
    ("31:16", "version  0x0100 = v1.0", 0.34),
    ("15:13", "log2 bytes/beat", 0.22),
    ("12:8", "BURST_WIDTH", 0.22),
    ("7:0", "NUM_RULES", 0.22),
])

# ------------------------------------------------------------------ output
NAMES = {0: "fig_context", 1: "fig_internal", 2: "fig_rules", 3: "fig_registers"}
# Every tool under doc/tools resolves paths from its own location rather than
# the caller's cwd, so it works the same run from anywhere.
DOC = os.path.abspath(os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "..", ".."))
outdir = sys.argv[1] if len(sys.argv) > 1 else os.path.join(DOC, "figures")
for p in d.save(outdir, NAMES):
    print("written:", os.path.normpath(p))
