#!/usr/bin/env python3
"""
Draw the block diagrams for the Avalon-MM SDRAM Controller, as standalone SVGs.

Uses the same svg_lib as the firewall cores' diagrams - same cm coordinate
system, same style names - so the figures across this repository look like they
belong to the same set.

SVG, not a drawing program's file format, for the reason recorded in
doc/tools/README.md: a zip of XML cannot be reviewed in a diff, cannot be
grepped for a stale claim, and cannot be checked by a script. Every number that
appears in these figures also appears in the RTL, and check_facts.py compares
them.

Usage:  python3 build_figures.py [outdir]      default doc/figures
"""

import os
import sys

from svg_lib import Svg, PAGE_W, PAGE_H

CORE = "Avalon-MM SDRAM Controller"
VER = "v1.0"

# ---------------------------------------------------------------- palette
INK      = "#1F3864"   # primary line / bus
INK_FILL = "#DCE6F1"
CORE_L   = "#843C0C"   # the controller itself
CORE_F   = "#FDE9D9"
REG_L    = "#375623"   # scheduler / control
REG_F    = "#E2EFDA"
EXT_L    = "#595959"   # external things
EXT_F    = "#F2F2F2"
RED      = "#C00000"   # the thing being fixed
AMBER    = "#BF8F00"
GREEN    = "#2E7D32"   # the fix
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
box("gSched", REG_F, REG_L)
box("gSchedT", REG_F, REG_L, valign="top")
box("gExt",   EXT_F, EXT_L)
box("gExtT",  EXT_F, EXT_L, valign="top")
box("gWhite", "#FFFFFF", GREY, "0.02cm", valign="top")
box("gHdr",   HDR_F, HDR_F, "0.02cm")
box("gCell",  "#FFFFFF", GREY, "0.02cm")
box("gCellA", "#F7F9FC", GREY, "0.02cm")
box("gOpen",  "#E8F5E9", GREEN, "0.05cm")
box("gShut",  "#FDECEC", RED, "0.05cm")
box("gNote",  "#FFF9E6", AMBER, "0.04cm", valign="top")
box("gPort",  "#FFFFFF", INK, "0.04cm")

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
arrow("aRed",   RED, "0.055cm")
arrow("aGreen", GREEN, "0.055cm")
arrow("aPlain", EXT_L, "0.035cm", end=False)
arrow("aDash",  EXT_L, "0.035cm", end=False, dash=True)

d.pstyle("pC", "center")
d.pstyle("pL", "start")
d.pstyle("pR", "end")

d.tstyle("tH",      15, bold=True, color=INK)
d.tstyle("tBody",   10, color="#000000")
d.tstyle("tSmall",   8.5, color="#000000")
d.tstyle("tTiny",    7.5, color=EXT_L)
d.tstyle("tBold",   10, bold=True, color="#000000")
d.tstyle("tCore",   12, bold=True, color=CORE_L)
d.tstyle("tSched",  10, bold=True, color=REG_L)
d.tstyle("tHdrW",    9.5, bold=True, color="#FFFFFF")
d.tstyle("tRed",     9.5, bold=True, color=RED)
d.tstyle("tGreen",   9.5, bold=True, color=GREEN)
d.tstyle("tMono",    9, color="#000000", family="DejaVu Sans Mono")
d.tstyle("tMonoS",   8, color=EXT_L, family="DejaVu Sans Mono")

# save() takes a dict of page index -> file stem, so the helper builds one.
NAMES = {}


def page(name):
    NAMES[d.page(name)] = name


# =============================================================================
# 1. System context
# =============================================================================
page("fig_context")

d.text(1.0, 0.6, 20, 1.0, ["System context"], "tH", "pL")

d.rect(1.0, 2.4, 5.6, 2.6, "gExt",
       ["Avalon-MM master", "", "Nios II, DMA, or plain RTL"], "tBody", "pC")

d.rect(9.0, 2.0, 8.0, 3.4, "gCore",
       ["avalon_mm_sdram_controller", "", "one open row per bank"], "tCore", "pC")

d.rect(19.4, 2.4, 6.0, 2.6, "gExt",
       ["SDR SDRAM device", "", "4 banks x 8192 rows", "x 1024 columns x 16 bits"],
       "tBody", "pC")

d.polyline([(6.6, 3.7), (9.0, 3.7)], "aBusBi")
d.text(6.5, 2.9, 2.6, 0.8, ["s1", "word-addressed"], "tTiny", "pC")

d.polyline([(17.0, 3.7), (19.4, 3.7)], "aBusBi")
d.text(16.9, 2.9, 2.6, 0.8, ["wire", "conduit"], "tTiny", "pC")

d.rect(9.0, 6.2, 8.0, 1.5, "gExt",
       ["clk / reset_n", "", "the clock rate is taken from the connected clock source"],
       "tSmall", "pC")
d.polyline([(13.0, 6.2), (13.0, 5.4)], "aSig")

d.rect(1.0, 8.4, 24.4, 2.2, "gNote",
       "The same three interfaces the SDRAM Controller Intel FPGA IP presents: a "
       "word-addressed Avalon-MM memory slave named s1 carrying the legacy "
       "az_/za_ signals, a conduit named wire carrying the SDRAM pins, and a "
       "clock and reset sink. Swapping one component for the other in an "
       "existing Platform Designer system leaves every connection and every "
       "address assignment alone.", "tSmall", "pL")

# =============================================================================
# 2. What is different: rows held open
# =============================================================================
page("fig_banks")

d.text(1.0, 0.6, 24, 1.0, ["One open row, or one per bank"], "tH", "pL")

# --- the old way ---
d.text(1.0, 2.0, 11.5, 0.7, ["Single open row"], "tRed", "pL")
d.rect(1.0, 2.9, 11.5, 0.9, "gExt", "one row register for the whole device",
       "tSmall", "pC")

for i, (nm, st) in enumerate([("bank 0", "gOpen"), ("bank 1", "gShut"),
                              ("bank 2", "gShut"), ("bank 3", "gShut")]):
    x = 1.0 + i * 2.95
    d.rect(x, 4.2, 2.7, 1.3, st, nm, "tSmall", "pC")

d.text(1.0, 5.8, 11.5, 2.4,
       ["An access to any other bank must close the open row and open a new "
        "one: PRECHARGE, tRP, ACTIVATE, tRCD. So must a read after a write, "
        "because the fast path also requires the direction to match."],
       "tSmall", "pL")

# --- this core ---
d.text(14.0, 2.0, 11.5, 0.7, ["One open row per bank"], "tGreen", "pL")
d.rect(14.0, 2.9, 11.5, 0.9, "gSched", "row_open[4], open_row[4]", "tMono", "pC")

for i in range(4):
    x = 14.0 + i * 2.95
    d.rect(x, 4.2, 2.7, 1.3, "gOpen", f"bank {i}", "tSmall", "pC")

d.text(14.0, 5.8, 11.5, 2.4,
       ["Four rows stay open at once. An access to another bank needs no row "
        "command at all, and a read/write turnaround inside an open row costs "
        "0 cycles write-to-read and CAS+1 read-to-write, with no row command "
        "either way."],
       "tSmall", "pL")

d.rect(1.0, 8.8, 24.5, 1.9, "gNote",
       "This is the whole design, and it is measurable rather than arguable. "
       "Four banks with one row open in each, accessed in rotation, needs "
       "exactly four ACTIVATEs and no PRECHARGE - which is what the testbench "
       "asserts, and what takes that access pattern from 21.9 MB/s to "
       "195.5 MB/s.", "tSmall", "pL")

# =============================================================================
# 3. Internal architecture
# =============================================================================
page("fig_internal")

d.text(1.0, 0.6, 24, 1.0, ["Internal architecture"], "tH", "pL")

d.rect(0.8, 1.9, 25.0, 9.9, "gCoreT", "  avalon_mm_sdram_controller",
       "tCore", "pL")

# ---- command path, left to right ----
d.rect(1.4, 3.6, 3.8, 1.5, "gPort", ["s1 slave", "az_ / za_"], "tSmall", "pC")
d.rect(6.0, 3.6, 4.0, 1.5, "gBlk",  ["command FIFO", "FIFO_DEPTH deep"], "tSmall", "pC")
d.polyline([(5.2, 4.35), (6.0, 4.35)], "aBus")

# The scheduler's rules, one per line and short enough not to wrap.
d.rect(10.8, 2.9, 7.0, 3.4, "gSchedT",
       ["  scheduler", "",
        "  row open     ->  column command",
        "  wrong row    ->  PRECHARGE",
        "  bank closed  ->  ACTIVATE",
        "  otherwise    ->  look ahead one"],
       "tSmall", "pL")
d.polyline([(10.0, 4.35), (10.8, 4.35)], "aBus")

d.rect(18.6, 3.6, 3.2, 1.5, "gBlk", ["command", "registers"], "tSmall", "pC")
d.polyline([(17.8, 4.35), (18.6, 4.35)], "aBus")

d.rect(22.6, 3.6, 2.6, 1.5, "gPort", ["wire", "conduit"], "tSmall", "pC")
d.polyline([(21.8, 4.35), (22.6, 4.35)], "aBus")

# ---- state the scheduler consults ----
d.rect(10.8, 7.0, 3.3, 1.5, "gSched", ["row_open[ ]", "open_row[ ]"], "tSmall", "pC")
d.rect(14.5, 7.0, 3.3, 1.5, "gSched", ["timing gates", "per bank"], "tSmall", "pC")
d.polyline([(12.45, 7.0), (12.45, 6.3)], "aCtrl")
d.polyline([(16.15, 7.0), (16.15, 6.3)], "aCtrl")

d.rect(10.8, 9.2, 7.0, 1.3, "gSched",
       "refresh timer - postponed up to REF_MAX_PEND", "tSmall", "pC")
d.polyline([(14.3, 9.2), (14.3, 8.5)], "aCtrl")

# ---- read return, routed clear of everything else ----
d.rect(18.6, 7.0, 3.2, 1.5, "gBlk", ["read pipeline", "CAS_LAT deep"], "tSmall", "pC")
# DQ arrives from the conduit
d.polyline([(23.9, 5.1), (23.9, 7.75), (21.8, 7.75)], "aBus")
d.text(21.6, 6.1, 2.6, 0.7, ["DQ"], "tTiny", "pC")
# and leaves along the bottom, below every other block
d.polyline([(18.6, 7.75), (18.2, 7.75), (18.2, 11.1),
            (3.3, 11.1), (3.3, 5.1)], "aBus")
d.text(6.0, 10.4, 11.0, 0.6, ["read data, returned in order"], "tTiny", "pL")

d.rect(0.8, 12.3, 25.0, 1.6, "gNote",
       "Every SDRAM output is registered, so a command decided in one cycle is "
       "sampled by the device in the next. The timing counters are loaded "
       "accordingly; getting that off by one is either a wasted cycle on every "
       "row change, or a violation.", "tSmall", "pL")

# =============================================================================
# 4. Address map
# =============================================================================
page("fig_addrmap")

d.text(1.0, 0.6, 24, 1.0, ["Address map"], "tH", "pL")

d.text(1.0, 2.0, 24, 0.7,
       ["ADDR_MAP 0 - compatible (default). The map the SDRAM Controller "
        "Intel FPGA IP uses."], "tBold", "pL")


def field(x, y, w, label, sub, style="gCell"):
    d.rect(x, y, w, 1.1, style, label, "tMono", "pC")
    d.text(x, y + 1.15, w, 0.6, [sub], "tTiny", "pC")


X0 = 1.0
field(X0,        2.9, 3.2, "ba[1]",     "addr[24]")
field(X0 + 3.4,  2.9, 9.0, "row",       "addr[23:11]")
field(X0 + 12.6, 2.9, 3.2, "ba[0]",     "addr[10]")
field(X0 + 16.0, 2.9, 8.5, "column",    "addr[9:0]")

d.text(1.0, 4.9, 24.0, 1.4,
       ["The bank bits are SPLIT: bank[0] sits directly above the column, so a "
        "purely ascending address alternates bank every 1024 words and advances "
        "the row every 2048. Even a perfectly sequential stream changes bank "
        "constantly - which a one-open-row design pays for and this one does not."],
       "tSmall", "pL")

d.text(1.0, 6.7, 24, 0.7,
       ["ADDR_MAP 1 - conventional. New designs only."], "tBold", "pL")

field(X0,        7.6, 12.4, "row",    "addr[24:12]")
field(X0 + 12.8, 7.6, 3.2,  "bank",   "addr[11:10]")
field(X0 + 16.4, 7.6, 8.1,  "column", "addr[9:0]")

d.rect(1.0, 9.6, 24.5, 1.6, "gNote",
       "Selecting the conventional map moves every address in memory. It is the "
       "right choice for a new design and the wrong one for replacing the Intel "
       "core in a system that already exists, which is why the component's "
       "validation warns about it at generation time.", "tSmall", "pL")

# =============================================================================
outdir = sys.argv[1] if len(sys.argv) > 1 else os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "..", "..", "figures")
outdir = os.path.abspath(outdir)
os.makedirs(outdir, exist_ok=True)

for p in d.save(outdir, NAMES):
    print("wrote", p)
