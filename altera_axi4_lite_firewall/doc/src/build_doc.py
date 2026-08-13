#!/usr/bin/env python3
"""Build the AXI4-Lite Firewall block-diagram + description document (.odg)."""

from odg_lib import Odg, PAGE_W, PAGE_H

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

d = Odg(f"{CORE} {VER} - block diagrams and descriptions")

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
    """Title band + footer. Returns y of first usable content row."""
    d.rect(0, 0, PAGE_W, 1.75, "gBand")
    d.text(M, 0.34, CW - 4, 1.1, [(title, "tH1")], pstyle="pL")
    d.text(PAGE_W - M - 4, 0.52, 4, 0.9,
           [(f"{CORE}  {VER}", "tMonoW")], pstyle="pR")
    if subtitle:
        d.text(M, 2.0, CW, 0.7, [(subtitle, "tSmallI")], pstyle="pL")
    d.line(M, PAGE_H - 1.15, PAGE_W - M, PAGE_H - 1.15, "aPlain")
    d.text(M, PAGE_H - 1.0, CW - 3, 0.6,
           [("altera_axi4_lite_firewall  -  block diagrams and descriptions",
             "tTiny")], pstyle="pL")
    d.text(PAGE_W - M - 3, PAGE_H - 1.0, 3, 0.6, [(f"page {num}", "tTiny")],
           pstyle="pR")
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


# ================================================================ PAGE 1
d.page("Cover")
d.rect(0, 0, PAGE_W, 5.4, "gBand")
d.text(M, 1.15, CW, 2.0, [(CORE, "tTitle")], pstyle="pL")
d.text(M, 3.5, CW, 1.0,
       [("Access-control and fault-isolation IP core for Intel / Altera "
         "Platform Designer", "tH1")], pstyle="pL")

d.text(M, 6.2, 16.5, 0.0, [
    ("What it is", "tH2"), ("", "tBody"),
    ("A synthesisable SystemVerilog core that sits between a bus master and a "
     "peripheral you want to protect. Every transaction is checked against a "
     "software-programmable table of address ranges before it is forwarded, "
     "and every forwarded transaction is watched by a timeout so a wedged "
     "peripheral can never hang the master.", "tBody"),
    ("", "tBody"),
    ("There is no stock AXI firewall in the Altera IP catalog, so this is a "
     "from-scratch component: RTL, Platform Designer wrapper, self-checking "
     "testbench, SystemVerilog assertions, and both a Questa and a "
     "licence-free Verilator flow.", "tBody"),
], pstyle="pLg")

d.rect(18.6, 6.0, 9.8, 7.3, "gRegT", None)
d.text(19.0, 6.2, 9.0, 0.0, [
    ("Verification status", "tH2g"),
    ("Questa 2024.1 and Verilator 5.48", "tSmall"),
    ("", "tTiny"),
    ("Self-checking tests        80 / 80", "tMonoS"),
    ("Assertions                 12 / 12", "tMonoS"),
    ("Cover directives            5 /  5", "tMonoS"),
    ("FSM states                  8 /  8", "tMonoS"),
    ("FSM transitions            14 / 14", "tMonoS"),
    ("m_axi protocol violations        0", "tMonoS"),
    ("", "tTiny"),
    ("Every assertion has a non-zero non-vacuous pass count.", "tTiny"),
], pstyle="pLg")

d.rect(18.6, 13.8, 9.8, 3.3, "gNote", None)
d.text(19.0, 14.0, 9.0, 0.0, [
    ("Not yet verified", "tH2"), ("", "tSmall"),
    ("Quartus analysis of the hw.tcl component, synthesis results "
     "(LE count, Fmax), and behaviour inside a generated Platform Designer "
     "interconnect.", "tSmall"),
], pstyle="pLg")

d.text(M, 13.1, 16.5, 0.0, [
    ("Contents", "tH2"), ("", "tSmall"),
    ("2 - 3     System context: how the core wires into a system", "tMonoS"),
    ("4 - 5     Internal architecture: datapaths, register block, recovery", "tMonoS"),
    ("6 - 7     Datapath state machines", "tMonoS"),
    ("8 - 9     Register map and rule table", "tMonoS"),
], pstyle="pLg")

d.text(M, PAGE_H - 1.9, CW, 0.8,
       [("altera_axi4_lite_firewall   -   component version 1.2   -   "
         "CORE_INFO reports 0x0102", "tTiny")], pstyle="pL")

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
d.line(5.8, 6.2, CX - 0.95, 6.2, "aBusBi")
label(7.1, 5.35, "AXI4-Lite", "tSmall", 3.2)
label(7.1, 6.45, "data path", "tTiny", 3.2)

d.line(CX + CWD + 0.95, 6.2, 23.6, 6.2, "aBusBi")
label(23.0, 5.35, "AXI4-Lite", "tSmall", 3.2)
label(23.0, 6.45, "forwarded", "tTiny", 3.2)

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
         "output, so this is now a software step - see page 5.", "tTiny")],
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

# ================================================================ PAGE 3
d.page("System context - description")
chrome("1.  System context — description", 3)

d.text(M, 2.5, 13.3, 0.0, [
    ("Purpose", "tH2"), ("", "tSmall"),
    ("The core is a bump-in-the-wire between one master and one protected "
     "peripheral. It enforces an allow-list on every transaction and "
     "guarantees the master always gets a response, even when the peripheral "
     "stops answering.", "tBody"),
    ("", "tSmall"),
    ("Access control", "tH2"), ("", "tSmall"),
    ("Each transaction's address is compared against a table of ranges, each "
     "with independent read and write permission. The lowest-index valid rule "
     "containing the address wins; ranges need not be disjoint, so put more "
     "specific rules at lower indices. Default-deny applies:", "tBody"),
    ("", "tTiny"),
    ("  no rule matches            →  DECERR", "tMonoS"),
    ("  rule matches, wrong direction  →  SLVERR", "tMonoS"),
    ("  blocked while ISOLATED         →  SLVERR", "tMonoS"),
    ("", "tSmall"),
    ("A denied read returns zeroed RDATA rather than stale bus data, so a "
     "rejected read cannot leak the result of an earlier permitted one.",
     "tBody"),
], pstyle="pLg")

d.text(15.4, 2.5, 13.0, 0.0, [
    ("Fault isolation", "tH2"), ("", "tSmall"),
    ("Every forwarded transaction is watched by a timeout covering the whole "
     "round trip, address issue to response. That catches a peripheral that "
     "never raises AWREADY/ARREADY as well as one that accepts and then goes "
     "quiet. On expiry the core answers SLVERR upstream immediately, so the "
     "master never hangs, and latches an internal broken state that blocks "
     "all further forwarding until software acknowledges the fault.",
     "tBody"),
    ("", "tSmall"),
    ("Why the control port is separate", "tH2"), ("", "tSmall"),
    ("s_axi_ctrl is a physically distinct AXI4-Lite slave. Recovery requires "
     "writing STATUS, and if that write had to pass through the firewall's "
     "own rule check, or through an isolated peripheral, a fault would be "
     "unrecoverable. Both ports may be driven by the same master.", "tBody"),
], pstyle="pLg")

d.rect(15.4, 11.7, 13.0, 3.6, "gWarn", None)
d.text(15.8, 11.9, 12.2, 0.0, [
    ("Recovery is a software sequence (v2.0)", "tRed"),
    ("ack the fault  →  poll the busy bits (bounded)  →  RESET THE "
     "PERIPHERAL  →  write RECOVERY.UNBLOCK", "tSmall"),
    ("UNBLOCK is what withdraws a stuck VALID. Skipping the reset makes that "
     "a protocol violation on a live bus: measured, 1 of 25 timing offsets "
     "then mis-attributes a stale response, against 0 of 25 when the "
     "sequence is followed.", "tSmall"),
], pstyle="pLg")

y = 15.9
d.text(M, y, 13.3, 0.5, [("Interface summary", "tH2")], pstyle="pL")
table(M, y + 0.6, [3.6, 2.2, 7.5], [
    ["Interface", "Type", "Connects to"],
    ["s_axi", "slave", "the master being policed"],
    ["m_axi", "master", "the protected peripheral"],
    ["s_axi_ctrl", "slave", "rule table, status, IRQ enable"],
    ["irq", "interrupt", "a CPU interrupt input"],
], rh=0.58)

d.text(15.4, y, 13.0, 0.5, [("Known limits", "tH2")], pstyle="pL")
d.text(15.4, y + 0.55, 13.0, 0.0, [
    ("No per-master filtering. AXI4-Lite carries no ID field, so the core "
     "sees only the address and the direction, never who asked. That needs "
     "full AXI4 or a sideband ID signal.", "tSmall"),
    ("Single-outstanding, non-pipelined, no bursts. Fine for register-style "
     "peripherals a CPU pokes occasionally; a burst master pays the full "
     "per-beat cost.", "tSmall"),
    ("ISOLATE blocks new transactions only. Work already forwarded finishes "
     "or times out normally.", "tSmall"),
], pstyle="pLg")

# ================================================================ PAGE 4
d.page("Internal architecture")
chrome("2.  Internal architecture", 4,
       "Inside axi_firewall_top: two independent datapaths, one register "
       "block, one recovery controller.")

OX, OY, OW, OH = 0.8, 3.4, 28.1, 14.2
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
VX, VY, VW, VH = 4.3, 14.5, 8.3, 2.5      # recovery

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
d.text(4.5, 17.12, 11.4, 0.5,
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
# clear horizontal room for a full-length label.
d.polyline([(WX + WW, 8.75), (LANE_M, 8.75), (LANE_M, 14.45), (28.9, 14.45)],
           "aBus")
d.polyline([(RX + WW, 13.75), (LANE_M, 13.75)], "aBus")
d.text(17.4, 13.87, 11.0, 0.5,
       [("m_axi   (AW, W, B, AR, R)", "tMonoS")], pstyle="pL")
d.text(17.4, 16.45, 11.0, 0.5,
       [("(v2.0: no peripheral reset output)", "tSmallI")], pstyle="pL")

d.text(0.8, 17.95, 28.1, 0.0, [
    ("chk_*_  is the rule-lookup bundle:  chk_*_addr out to the register "
     "block, chk_*_match and chk_*_allow back, all combinational within one "
     "cycle.", "tMonoS"),
    ("", "tTiny"),
    ("The two datapaths are fully independent: separate FSMs, separate "
     "capture registers, separate lookup ports, separate fault pulses. A read "
     "and a write can be in flight at the same time. Only FAULT_ADDR / "
     "FAULT_INFO are shared, and if both fault in the same cycle the write "
     "side wins - a documented, deterministic tie-break.", "tSmall"),
], pstyle="pLg")

# ================================================================ PAGE 5
d.page("Internal architecture - description")
chrome("2.  Internal architecture — description", 5)

d.text(M, 2.5, 13.3, 0.0, [
    ("Datapaths", "tH2"), ("", "tSmall"),
    ("Both follow the same four-state shape. IDLE waits for a request and "
     "captures it; EVAL applies the verdict in a single cycle; FWD drives the "
     "master side and runs the timeout counter; RESP holds the response until "
     "the master accepts it.", "tBody"),
    ("", "tSmall"),
    ("EVAL is where policy is decided, in strict priority order: forwarding "
     "blocked (SLVERR), global bypass (forward unconditionally), no rule "
     "match (DECERR), rule matched but direction denied (SLVERR), otherwise "
     "forward.", "tBody"),
    ("", "tSmall"),
    ("Register block", "tH2"), ("", "tSmall"),
    ("Owns the rule table and all software-visible state, and exposes two "
     "independent purely combinational lookup ports so both datapaths get an "
     "answer in the same cycle without contending. The lookup is a priority "
     "chain over NUM_RULES entries - it is the likeliest critical path, and "
     "the standard fix if it limits Fmax is to register it with an extra "
     "pipeline stage.", "tBody"),
], pstyle="pLg")

d.text(15.4, 2.5, 13.0, 0.0, [
    ("Timeout and recovery", "tH2"), ("", "tSmall"),
    ("On expiry the core reports SLVERR upstream, latches "
     "downstream_broken, and deliberately leaves any asserted m_axi_*VALID "
     "asserted. AXI requires VALID to hold until READY; withdrawing it can "
     "wedge the interconnect between the core and the peripheral, not just "
     "the peripheral.", "tBody"),
    ("", "tSmall"),
    ("The stuck VALID is dropped only by RECOVERY.UNBLOCK, which means "
     "software has reset the peripheral and its AXI state is gone. STATUS "
     "exposes RESP_BUSY (the peripheral owes a response) and CMD_STUCK (it "
     "never accepted the command) so a driver can sequence this. Bound the "
     "busy poll: a peripheral that accepted and then died owes a response "
     "forever. A transaction arriving while blocked is rejected, not "
     "stalled, so drivers need a retry path.", "tBody"),
    ("", "tSmall"),
    ("Note that downstream_broken is independent of CTRL.AUTO_ISOLATE_EN. "
     "That bit governs only the visible ISOLATED status; blocking after a "
     "timeout is required for protocol safety and happens either way.",
     "tBody"),
], pstyle="pLg")

y = 12.9
d.text(M, y, CW, 0.5, [("Key internal signals", "tH2")], pstyle="pL")
table(M, y + 0.6, [5.4, 3.2, 18.5], [
    ["Signal", "Direction", "Meaning"],
    ["chk_w_addr / chk_r_addr", "to regs",
     "address presented to the rule lookup, one port per datapath"],
    ["chk_*_match", "from regs",
     "some valid rule contains this address; low means DECERR"],
    ["chk_*_allow", "from regs",
     "that rule permits this direction; low means SLVERR"],
    ["global_enable", "from regs",
     "CTRL bit 0. Low is bypass: forward everything unchecked"],
    ["isolate_effective", "from regs",
     "MANUAL_ISOLATE or the auto-isolate latch"],
    ["forward_blocked", "internal",
     "isolate_effective or downstream_broken - blocks new forwarding"],
    ["wr/rd_resp_busy", "to regs",
     "peripheral accepted the command and still owes a response"],
    ["fault_* pulses", "to regs",
     "single-cycle, per direction; set sticky STATUS and capture FAULT_ADDR"],
    ["unblock", "from regs",
     "pulse on RECOVERY.UNBLOCK; releases the block and discards a stuck VALID"],
], rh=0.56)

# ================================================================ PAGE 6
d.page("Datapath state machines")
chrome("3.  Datapath state machines", 6,
       "Both FSMs are enum-typed, so Questa names the states in its coverage "
       "report. All 14 transitions are covered by the test suite.")

def fsm(x0, title, pre, note):
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
    d.text(x0 - 0.35, 8.75, 1.7, 0.0, [("handshake", "tTiny"),
                                       ("complete", "tTiny")], pstyle="pC")
    # reset
    d.polyline([(cx + sw + 1.0, ys[0] - 0.8), (cx + sw / 2 + 0.9, ys[0] - 0.8),
                (cx + sw / 2 + 0.9, ys[0])], "aState")
    d.text(cx + sw + 1.15, ys[0] - 1.08, 4.6, 0.5,
           [("resetn low, from any state", "tTiny")], pstyle="pL")
    d.text(x0, 15.45, 12.6, 0.0, [(note, "tSmall")], pstyle="pLg")

fsm(1.0, "Write datapath  (wr_state)", "WR",
    "A transaction arriving while the downstream is blocked is answered "
    "SLVERR from EVAL - v2.0 removed the reset pulse, and with it the bounded "
    "window in which arrivals used to be stalled instead. The timeout in FWD "
    "covers both the address phase and the response phase.")
fsm(16.0, "Read datapath  (rd_state)", "RD",
    "Structurally identical, but a separate FSM with its own capture "
    "registers and lookup port. A denied read drives RDATA to zero before "
    "responding, so it cannot return stale data from an earlier permitted "
    "read.")

d.rect(1.0, 17.5, 27.6, 2.1, "gNote", None)
d.text(1.4, 17.7, 26.8, 0.0, [
    ("On a timeout, m_axi_*VALID is deliberately NOT withdrawn.", "tAmber"),
    ("AXI requires VALID to hold until READY. The FSM leaves FWD and answers "
     "the master, but the master-side VALID stays asserted until software "
     "writes RECOVERY.UNBLOCK - the one point where dropping it is "
     "legitimate, because software has just reset the peripheral and its "
     "protocol state no longer means anything.", "tSmall"),
], pstyle="pLg")

# ================================================================ PAGE 7
d.page("Datapath state machines - description")
chrome("3.  Datapath state machines — description", 7)

d.text(M, 2.5, 13.3, 0.0, [
    ("State by state", "tH2"), ("", "tSmall"),
    ("IDLE   waits for a request. The write path needs both AWVALID and "
     "WVALID before asserting either READY - a slave may always add wait "
     "states, so this is compliant and keeps one simple pattern. Address, "
     "protection bits, data and strobes are captured on entry to EVAL.",
     "tBody"),
    ("", "tTiny"),
    ("EVAL   always one cycle. The rule lookup result for the captured "
     "address is already available combinationally, so the verdict costs no "
     "extra cycle. If the downstream is blocked the answer is SLVERR - v2.0 "
     "removed the reset pulse and with it the window in which arrivals were "
     "stalled instead.", "tBody"),
    ("", "tTiny"),
    ("FWD   drives the master side and runs the timeout counter. The counter "
     "starts when forwarding starts and covers the whole round trip, so a "
     "peripheral that never raises AWREADY is caught by the same mechanism "
     "as one that accepts and then goes silent.", "tBody"),
    ("", "tTiny"),
    ("RESP   asserts the response and holds it, with the payload stable, "
     "until the master's READY arrives.", "tBody"),
], pstyle="pLg")

d.text(15.4, 2.5, 13.0, 0.0, [
    ("Response encoding", "tH2"), ("", "tSmall"),
], pstyle="pLg")
table(15.4, 3.35, [6.0, 2.6, 4.4], [
    ["Condition", "Response", "Status bit"],
    ["allowed, peripheral answers", "as returned", "-"],
    ["no valid rule matches", "DECERR", "ADDR_VIOLATION"],
    ["matched, direction denied", "SLVERR", "PERM_VIOLATION"],
    ["blocked while isolated", "SLVERR", "none"],
    ["peripheral timed out", "SLVERR", "TIMEOUT_ERROR"],
], rh=0.58)

d.text(15.4, 7.35, 13.0, 0.0, [
    ("A transaction blocked because the core is isolated returns SLVERR but "
     "sets no status bit and raises no interrupt. Only genuine violations "
     "and timeouts are logged, so a burst of rejected traffic during "
     "isolation cannot bury the fault that caused it.", "tSmall"),
    ("", "tTiny"),
    ("Performance", "tH2"),
    ("Measured against a zero-wait-state peripheral, counting clock edges "
     "from request assertion to response valid:", "tBody"),
    ("", "tTiny"),
    ("  single write   6 cycles", "tMonoS"),
    ("  single read    6 cycles", "tMonoS"),
    ("", "tTiny"),
    ("The suite fails if either exceeds 8, so the figure cannot silently "
     "rot. Cost is per transaction and does not amortise.", "tSmall"),
], pstyle="pLg")

y = 14.3
d.text(M, y, CW, 0.5, [("FSM transition coverage  (Questa 2024.1)", "tH2")],
       pstyle="pL")
table(M, y + 0.6, [7.0, 4.2, 15.9], [
    ["Transition", "Hits", "Exercised by"],
    ["IDLE → EVAL", "19 / 19", "every transaction"],
    ["EVAL → FWD", "13 / 13", "every permitted transaction"],
    ["EVAL → RESP", "5 / 5", "denial tests C, E, J, K, L, M"],
    ["EVAL → IDLE", "1 / 1", "test S - reset asserted during EVAL"],
    ["FWD → RESP", "10 / 10", "normal completion and timeout tests F, N, Q, R"],
    ["FWD → IDLE", "3 / 3", "test S - reset asserted during FWD"],
    ["RESP → IDLE", "15 / 15", "every completed response"],
], rh=0.56)

# ================================================================ PAGE 8
d.page("Register map")
chrome("4.  Register map and rule table", 8,
       "All registers are 32 bit and word aligned on s_axi_ctrl. Reset "
       "values are shown; the core comes up secure by default.")

d.text(M, 3.0, 13.2, 0.5, [("Fixed registers", "tH2")], pstyle="pL")
table(M, 3.6, [2.0, 3.3, 2.1, 5.8], [
    ["Offset", "Name", "Access", "Reset"],
    ["0x00", "CTRL", "R/W", "0x3  (enabled, auto-isolate on)"],
    ["0x04", "STATUS", "R / W1C", "0x0"],
    ["0x08", "IRQ_ENABLE", "R/W", "0x7  (all enabled)"],
    ["0x0C", "TIMEOUT_VALUE", "R/W", "all ones  (effectively disabled)"],
    ["0x10", "FAULT_ADDR", "R", "0x0"],
    ["0x14", "FAULT_INFO", "R", "0x0"],
    ["0x18", "CORE_INFO", "R", "version (0x0200) and NUM_RULES"],
    ["0x1C", "RECOVERY", "W", "bit0 UNBLOCK, self-clearing"],
], rh=0.6)

d.text(M, 9.0, 13.2, 0.5, [("Rule table", "tH2")], pstyle="pL")
table(M, 9.6, [3.9, 3.7, 5.6], [
    ["Offset", "Name", "Description"],
    ["0x40 + i·0x10", "RULE_BASE[i]", "inclusive base address"],
    ["0x44 + i·0x10", "RULE_LIMIT[i]", "inclusive top address"],
    ["0x48 + i·0x10", "RULE_PERM[i]", "permissions and valid bit"],
], rh=0.6)
d.text(M, 12.2, 13.2, 0.0, [
    ("i runs 0 .. NUM_RULES-1. With the default 8 rules the table spans "
     "0x40 - 0xBF. CTRL_ADDR_WIDTH must be wide enough to reach the whole "
     "table; a validation callback in hw.tcl enforces this, because an "
     "undersized control port silently makes high-index rules unreachable.",
     "tSmall"),
], pstyle="pLg")

# --- bit field diagrams
# Sub-labels are the longest strings on the page, so they set the minimum
# field width. 6.5 pt plus generous fractions on the single-bit fields keeps
# ADDR_VIOLATION and AUTO_ISOLATE_EN inside their boxes.
BFX, BFW = 15.2, 13.2

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
    ("31:16", "version  0x0102 = v1.2", 0.44),
    ("15:8", "reserved", 0.28),
    ("7:0", "NUM_RULES", 0.28),
])

d.rect(M, 15.3, 13.2, 4.2, "gNote", None)
d.text(M + 0.35, 15.5, 12.5, 0.0, [
    ("Clearing TIMEOUT_ERROR is not enough on its own", "tAmber"),
    ("", "tTiny"),
    ("It also releases the auto-isolate latch. What it does NOT do, as of "
     "v2.0, is reopen the downstream - that takes an explicit "
     "RECOVERY.UNBLOCK after software has reset the peripheral. A v1.x "
     "driver stops here and then sees every access return SLVERR.",
     "tSmall"),
], pstyle="pLg")

d.rect(BFX, 15.3, BFW, 4.2, "gWarn", None)
d.text(BFX + 0.35, 15.5, BFW - 0.7, 0.0, [
    ("Reconfiguring a live rule", "tRed"),
    ("A rule is three registers, so updating one that is currently VALID "
     "leaves a window where BASE is new but LIMIT is still old. Clear VALID "
     "first (unnecessary at init - VALID is 0 out of reset):", "tSmall"),
    ("write RULE_PERM[i] = 0", "tMonoS"),
    ("write RULE_BASE[i], RULE_LIMIT[i]", "tMonoS"),
    ("write RULE_PERM[i] = perms | VALID", "tMonoS"),
], pstyle="pLg")

# ================================================================ PAGE 9
d.page("Register map - description")
chrome("4.  Register map — description and software notes", 9)

d.text(M, 2.5, 13.3, 0.0, [
    ("Programming model", "tH2"), ("", "tSmall"),
    ("Bring-up is: program the rules, set a timeout, enable interrupts. The "
     "core is secure by default - GLOBAL_ENABLE resets to 1 and the rule "
     "table resets empty, so with no configuration at all every transaction "
     "is denied rather than passed.", "tBody"),
    ("", "tSmall"),
    ("TIMEOUT_VALUE resets to all ones, which is effectively no timeout. Set "
     "it to a real round-trip budget for your clock and peripheral, or fault "
     "isolation will not trigger in any useful time.", "tBody"),
    ("", "tSmall"),
    ("Interrupt handling", "tH2"), ("", "tSmall"),
    ("irq is a level interrupt, asserted while any enabled sticky STATUS bit "
     "is set. Clear at the source by writing 1 to the relevant bit; there is "
     "no separate acknowledge register. This is the standard "
     "memory-mapped-peripheral idiom and works directly with the Nios II HAL "
     "ISR pattern.", "tBody"),
    ("", "tSmall"),
    ("FAULT_ADDR and FAULT_INFO capture the most recent fault of any type. "
     "If a read and a write fault in the same cycle, both sticky bits set "
     "correctly but the capture registers take the write side.", "tBody"),
], pstyle="pLg")

d.text(15.4, 2.5, 13.0, 0.0, [
    ("Control port behaviour", "tH2"), ("", "tSmall"),
    ("s_axi_ctrl is single-outstanding and backpressures correctly: "
     "AWREADY/WREADY are withheld while a BVALID is unacknowledged, and "
     "ARREADY while an RVALID is. A driver that issues one access at a time "
     "sees no difference; one that pipelines simply waits.", "tBody"),
    ("", "tSmall"),
    ("Before v1.2 the port asserted READY on VALID arriving without checking "
     "whether the previous response had been accepted. A pipelined second "
     "access got its handshake taken, was silently dropped, and never "
     "received a response - a lost register write and a wedged channel. If "
     "you are carrying an older copy of this core, that is the one fix worth "
     "taking.", "tBody"),
    ("", "tSmall"),
    ("Writes to reserved or unaligned offsets are ignored and answered OKAY; "
     "reads of them return zero.", "tBody"),
], pstyle="pLg")

y = 13.6
d.text(M, y, CW, 0.5, [("Parameters", "tH2")], pstyle="pL")
table(M, y + 0.6, [5.3, 2.4, 19.4], [
    ["Parameter", "Default", "Notes"],
    ["ADDR_WIDTH", "32", "data-path address width"],
    ["DATA_WIDTH", "32", "data-path data width; 32 or 64. Only 32 has been simulated"],
    ["CTRL_ADDR_WIDTH", "12", "must cover 0x40 + NUM_RULES·16 bytes; checked by hw.tcl"],
    ["NUM_RULES", "8", "rule table depth. Scales the combinational lookup - the likely critical path"],
    ["TIMEOUT_WIDTH", "20", "max programmable timeout is 2^TIMEOUT_WIDTH - 1 clock cycles"],
], rh=0.56)

d.text(M, 18.3, CW, 0.0, [
    ("The suite runs at the default parameter set only. Other configurations "
     "are checked by lint across the parameter space, which proves they "
     "elaborate, not that they work - the rule-table decode is exactly where "
     "an off-by-one would hide.", "tSmallI"),
], pstyle="pLg")

d.save("axi4_lite_firewall_block_diagrams.odg")
print(f"written: {len(d.pages)} pages")
