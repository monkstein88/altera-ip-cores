#!/usr/bin/env python3
"""
Draw the block diagrams for the Avalon-MM SD Card Controller, as standalone SVGs.

Uses the same svg_lib as the other cores' diagrams - same cm coordinate system,
same style names - so the figures across this repository look like they belong
to the same set.

SVG, not a drawing program's file format, for the reason recorded in
doc/tools/README.md: a zip of XML cannot be reviewed in a diff, cannot be
grepped for a stale claim, and cannot be checked by a script. Every number that
appears in these figures also appears in the RTL, and check_facts.py compares
them.

Usage:  python3 build_figures.py [outdir]      default doc/figures
"""

import os
import sys

from svg_lib import Svg

CORE = "Avalon-MM SD Card Controller"
VER = "v1.0"

# ---------------------------------------------------------------- palette
INK      = "#1F3864"   # primary line / bus
INK_FILL = "#DCE6F1"
CORE_L   = "#843C0C"   # the controller itself
CORE_F   = "#FDE9D9"
REG_L    = "#375623"   # sequencer / control
REG_F    = "#E2EFDA"
EXT_L    = "#595959"   # external things
EXT_F    = "#F2F2F2"
RED      = "#C00000"
AMBER    = "#BF8F00"
GREEN    = "#2E7D32"
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
box("gSeq",   REG_F, REG_L)
box("gSeqT",  REG_F, REG_L, valign="top")
box("gExt",   EXT_F, EXT_L)
box("gExtT",  EXT_F, EXT_L, valign="top")
box("gWhite", "#FFFFFF", GREY, "0.02cm", valign="top")
box("gHdr",   HDR_F, HDR_F, "0.02cm")
box("gCell",  "#FFFFFF", GREY, "0.02cm")
box("gCellA", "#F7F9FC", GREY, "0.02cm")
box("gOK",    "#E8F5E9", GREEN, "0.05cm")
box("gErr",   "#FDECEC", RED, "0.05cm")
box("gNote",  "#FFF9E6", AMBER, "0.04cm", valign="top")
box("gOpt",   "#FFFFFF", EXT_L, "0.04cm", dash="Dash_20__28_Rounded_29_")


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
arrow("aOpt",   EXT_L, "0.05cm", dash=True)

d.pstyle("pC", "center")
d.pstyle("pL", "start")
d.pstyle("pR", "end")

d.tstyle("tH",      15, bold=True, color=INK)
d.tstyle("tBody",   10, color="#000000")
d.tstyle("tSmall",   8.5, color="#000000")
d.tstyle("tTiny",    7.5, color=EXT_L)
d.tstyle("tBold",   10, bold=True, color="#000000")
d.tstyle("tCore",   12, bold=True, color=CORE_L)
d.tstyle("tSeq",    10, bold=True, color=REG_L)
d.tstyle("tHdrW",    9.5, bold=True, color="#FFFFFF")
d.tstyle("tRed",     9.5, bold=True, color=RED)
d.tstyle("tGreen",   9.5, bold=True, color=GREEN)
d.tstyle("tMono",    9, color="#000000", family="DejaVu Sans Mono")
d.tstyle("tMonoS",   8, color=EXT_L, family="DejaVu Sans Mono")
d.tstyle("tMonoW",   8.5, bold=True, color="#FFFFFF", family="DejaVu Sans Mono")

NAMES = {}


def page(name):
    NAMES[d.page(name)] = name


# =============================================================================
# 1. System context
# =============================================================================
page("fig_context")

d.text(1.0, 0.6, 20, 1.0, ["System context"], "tH", "pL")

d.rect(1.0, 2.2, 5.4, 2.0, "gExt",
       ["Nios II", "", "or any Avalon-MM master"], "tBody", "pC")
d.rect(1.0, 4.8, 5.4, 1.8, "gExt",
       ["System memory", "", "SDRAM, on-chip RAM"], "tBody", "pC")

d.rect(8.6, 2.0, 8.4, 4.6, "gCore",
       ["avalon_mm_sdcard_controller", "", "SD / SDHC / SDXC in SPI mode"],
       "tCore", "pC")

d.rect(19.4, 2.6, 5.6, 2.4, "gExt",
       ["SD card", "", "four wires plus power"], "tBody", "pC")

# csr
d.polyline([(6.4, 3.0), (8.6, 3.0)], "aBusBi")
d.text(6.3, 2.2, 2.4, 0.8, ["csr", "17 words"], "tTiny", "pC")

# m0
d.polyline([(8.6, 5.6), (6.4, 5.6)], "aBusBi")
d.text(6.3, 4.8, 2.4, 0.8, ["m0", "bursting master"], "tTiny", "pC")

# irq
d.polyline([(8.6, 4.3), (6.4, 4.3)], "aSig")
d.text(6.3, 3.5, 2.4, 0.8, ["irq"], "tTiny", "pC")

# conduit
d.polyline([(17.0, 3.8), (19.4, 3.8)], "aBusBi")
d.text(16.9, 3.0, 2.4, 0.8, ["sd", "conduit"], "tTiny", "pC")

d.rect(8.6, 7.6, 8.4, 1.3, "gExt", ["clk / reset_n"], "tSmall", "pC")
d.polyline([(12.8, 7.6), (12.8, 6.6)], "aSig")

d.rect(1.0, 9.6, 24.0, 2.6, "gNote",
       "Two Avalon-MM interfaces, not one. csr is the slave software programs; "
       "m0 is a master the core uses to move block data to and from memory "
       "itself, so a 512-byte block costs the CPU one command rather than 128 "
       "loads and stores. m0 is optional - set USE_DMA to 0 and the interface "
       "disappears from the component, leaving software to move every word "
       "through the DATA window. The SPI conduit is four wires: clk, mosi, "
       "miso and cs_n, plus card-detect and write-protect when USE_CARD_DETECT "
       "is set.", "tSmall", "pL")

# =============================================================================
# 2. Internal structure
# =============================================================================
page("fig_internal")

d.text(1.0, 0.6, 24, 1.0, ["Internal structure"], "tH", "pL")

d.rect(1.4, 1.8, 18.6, 7.6, "gCoreT",
       ["avalon_mm_sdcard_controller"], "tCore", "pL")

# --- row 1: register file, sequencer, shifter
d.rect(2.2, 3.2, 4.4, 2.2, "gBlk",
       ["_regs", "", "17-word CSR", "readLatency 1"], "tSmall", "pC")
d.rect(7.4, 3.2, 5.6, 2.2, "gSeq",
       ["_seq", "", "20-state protocol engine", "commands, tokens, timeouts"],
       "tSmall", "pC")
d.rect(13.8, 3.2, 5.0, 2.2, "gBlk",
       ["_spi_phy", "", "continuous shifter", "one-deep prefetch"],
       "tSmall", "pC")

# --- row 2: master, buffer, and the two helpers that hang off the shifter
d.rect(2.2, 6.4, 4.4, 1.7, "gOpt",
       ["_dma", "USE_DMA", "bursting master"], "tSmall", "pC")
d.rect(7.4, 6.4, 5.6, 1.7, "gBlk",
       ["_fifo", "", "word store + byte packer"], "tSmall", "pC")
d.rect(13.8, 6.4, 2.3, 1.7, "gBlk", ["_crc"], "tSmall", "pC")
d.rect(16.5, 6.4, 2.3, 1.7, "gBlk", ["_clkgen"], "tSmall", "pC")

# --- the pins, outside the core boundary
d.rect(20.8, 3.2, 3.8, 2.2, "gExt",
       ["sd conduit", "", "clk mosi", "miso cs_n"], "tSmall", "pC")

# --- host-side interfaces, leaving the core's left edge
d.polyline([(0.4, 3.9), (2.2, 3.9)], "aBusBi")          # csr
d.text(0.3, 3.1, 2.0, 0.7, ["csr"], "tTiny", "pL")
d.polyline([(2.2, 5.0), (0.4, 5.0)], "aSig")            # irq
d.text(0.3, 5.1, 2.0, 0.7, ["irq"], "tTiny", "pL")
d.polyline([(2.2, 7.25), (0.4, 7.25)], "aBusBi")        # m0
d.text(0.3, 7.35, 2.0, 0.7, ["m0"], "tTiny", "pL")

# --- internal connections
d.polyline([(6.6, 4.3), (7.4, 4.3)], "aBusBi")          # regs <-> seq
d.polyline([(13.0, 4.3), (13.8, 4.3)], "aBusBi")        # seq <-> phy
d.polyline([(18.8, 4.3), (20.8, 4.3)], "aBusBi")        # phy -> pins
d.polyline([(4.4, 5.4), (4.4, 6.4)], "aCtrl")           # regs -> dma config
d.polyline([(6.6, 7.25), (7.4, 7.25)], "aBusBi")        # dma <-> fifo
d.polyline([(10.2, 5.4), (10.2, 6.4)], "aBusBi")        # seq <-> fifo
d.polyline([(14.9, 6.4), (14.9, 5.4)], "aBusBi")        # crc <-> phy
d.polyline([(17.6, 6.4), (17.6, 5.4)], "aPlain")        # clkgen -> phy

d.text(10.6, 5.45, 3.2, 0.7, ["bytes"], "tTiny", "pL")
d.text(13.9, 5.45, 3.0, 0.7, ["every byte"], "tTiny", "pL")
d.text(17.7, 5.45, 3.0, 0.7, ["strobes"], "tTiny", "pL")

d.rect(0.4, 9.9, 24.2, 2.4, "gNote",
       "The shifter runs continuously while a transfer is in progress, with a "
       "one-deep prefetch, so the next byte is already queued before the "
       "current one finishes and the SPI clock never pauses between bytes. That "
       "is where the measured 98.1% of line rate comes from - 16,696 SPI clocks "
       "to move 2,048 bytes, against a theoretical 16,384. The CRC units are "
       "byte-wise rather than bit-serial for the same reason: a bit-serial CRC "
       "cannot keep up with a shifter that never stops. _crc computes CRC7 over "
       "command frames and CRC16 over data blocks; _clkgen divides the host "
       "clock to clk / (2 x CLKDIV) and hands the shifter a rising and a "
       "falling strobe rather than a second clock domain.", "tSmall", "pL")

# =============================================================================
# 3. Register map
# =============================================================================
page("fig_regmap")

d.text(1.0, 0.6, 24, 1.0, ["Register map"], "tH", "pL")

REGS = [
    ("0x00", "CTRL",       "RW",   "enable, CS control, CRC, DMA, soft resets"),
    ("0x04", "STATUS",     "RO",   "busy flags, FIFO level, card present, error"),
    ("0x08", "IRQ_ENABLE", "RW",   "mask, one bit per source"),
    ("0x0C", "IRQ_STATUS", "RW1C", "pending events and errors"),
    ("0x10", "CLKDIV",     "RW",   "SPI clock = clk / (2 x CLKDIV)"),
    ("0x14", "TIMEOUT",    "RW",   "cycles without progress before giving up"),
    ("0x18", "CMD_ARG",    "RW",   "the command's 32-bit argument"),
    ("0x1C", "CMD",        "RW",   "index, response type, data flags; write starts"),
    ("0x20", "RESP0",      "RO",   "R1, or the low word of a longer response"),
    ("0x24", "RESP1",      "RO",   "R3 / R7 trailer"),
    ("0x28", "BLK_SIZE",   "RW",   "bytes per block, up to MAX_BLOCK_BYTES"),
    ("0x2C", "BLK_COUNT",  "RW",   "blocks in this transfer"),
    ("0x30", "DMA_ADDR",   "RW",   "byte address in system memory"),
    ("0x34", "DMA_CTRL",   "RW",   "mode; only contiguous is defined"),
    ("0x38", "DATA",       "RW",   "PIO window into the FIFO"),
    ("0x3C", "ERR_INFO",   "RO",   "last tokens, last R1, phase that failed"),
    ("0x40", "CORE_INFO",  "RO",   "build-time configuration, read-only"),
]

y = 2.0
d.rect(1.0, y, 2.4, 0.75, "gHdr", "Offset", "tHdrW", "pC")
d.rect(3.4, y, 4.6, 0.75, "gHdr", "Name", "tHdrW", "pL")
d.rect(8.0, y, 2.0, 0.75, "gHdr", "Access", "tHdrW", "pC")
d.rect(10.0, y, 14.4, 0.75, "gHdr", "Purpose", "tHdrW", "pL")
y += 0.75

for i, (off, name, acc, why) in enumerate(REGS):
    st = "gCellA" if i % 2 else "gCell"
    d.rect(1.0, y, 2.4, 0.62, st, off, "tMonoS", "pC")
    d.rect(3.4, y, 4.6, 0.62, st, name, "tMono", "pL")
    d.rect(8.0, y, 2.0, 0.62, st, acc, "tTiny", "pC")
    d.rect(10.0, y, 14.4, 0.62, st, why, "tSmall", "pL")
    y += 0.62

d.rect(1.0, y + 0.5, 23.4, 1.8, "gNote",
       "Seventeen words, so CSR_ADDR_WIDTH must be at least 5. The slave has a "
       "read latency of 1. Writing CMD with bit 31 set is what launches an "
       "operation; the write is ignored while the sequencer is busy, which is "
       "correct - a second command must not corrupt a transfer in flight - but "
       "it means software has to check STATUS first rather than assume the "
       "write took.", "tSmall", "pL")

# =============================================================================
# 4. Sequencer states
# =============================================================================
page("fig_states")

d.text(1.0, 0.6, 24, 1.0, ["Sequencer states"], "tH", "pL")

# --- command phase, common to every operation
d.text(1.0, 1.7, 8.0, 0.6, ["Command phase"], "tGreen", "pL")
d.rect(1.0, 2.4, 3.4, 1.1, "gSeq", "S_IDLE", "tMono", "pC")
d.rect(5.4, 2.4, 3.8, 1.1, "gSeq", "S_PRE_BUSY", "tMono", "pC")
d.rect(10.2, 2.4, 3.4, 1.1, "gSeq", "S_CMD", "tMono", "pC")
d.rect(14.6, 2.4, 4.0, 1.1, "gSeq", "S_RESP_WAIT", "tMono", "pC")
d.rect(19.6, 2.4, 4.2, 1.1, "gSeq", "S_RESP_TRAIL", "tMono", "pC")

d.polyline([(4.4, 2.95), (5.4, 2.95)], "aCtrl")
d.polyline([(9.2, 2.95), (10.2, 2.95)], "aCtrl")
d.polyline([(13.6, 2.95), (14.6, 2.95)], "aCtrl")
d.polyline([(18.6, 2.95), (19.6, 2.95)], "aCtrl")

# R1b commands wait for the card to lift busy before anything else happens.
d.rect(14.6, 4.1, 4.0, 1.0, "gSeq", "S_R1B_BUSY", "tMono", "pC")
d.polyline([(16.6, 3.5), (16.6, 4.1)], "aCtrl")
d.text(18.7, 4.3, 5.0, 0.6, ["R1b only"], "tTiny", "pL")

# the branch into the data phase
d.polyline([(21.7, 3.5), (21.7, 5.7), (2.9, 5.7), (2.9, 6.4)], "aCtrl")
d.text(9.0, 5.75, 6.0, 0.6, ["if CMD.DATA_EN"], "tTiny", "pL")

# --- read branch
d.text(1.0, 6.4, 6.0, 0.6, ["Read path"], "tGreen", "pL")
d.rect(1.0, 7.0, 3.8, 1.1, "gSeq", "S_DAT_START", "tMono", "pC")
d.rect(5.8, 7.0, 3.8, 1.1, "gSeq", "S_RD_TOKEN", "tMono", "pC")
d.rect(10.6, 7.0, 3.4, 1.1, "gSeq", "S_RD_DATA", "tMono", "pC")
d.rect(15.0, 7.0, 3.4, 1.1, "gSeq", "S_RD_CRC", "tMono", "pC")
d.polyline([(4.8, 7.55), (5.8, 7.55)], "aCtrl")
d.polyline([(9.6, 7.55), (10.6, 7.55)], "aCtrl")
d.polyline([(14.0, 7.55), (15.0, 7.55)], "aCtrl")

# --- write branch
d.text(1.0, 8.5, 6.0, 0.6, ["Write path"], "tGreen", "pL")
d.rect(1.0, 9.1, 3.8, 1.1, "gSeq", "S_WR_TOKEN", "tMono", "pC")
d.rect(5.8, 9.1, 3.4, 1.1, "gSeq", "S_WR_DATA", "tMono", "pC")
d.rect(10.2, 9.1, 3.4, 1.1, "gSeq", "S_WR_CRC", "tMono", "pC")
d.rect(14.6, 9.1, 3.6, 1.1, "gSeq", "S_WR_RESP", "tMono", "pC")
d.rect(19.2, 9.1, 3.6, 1.1, "gSeq", "S_WR_TAIL", "tMono", "pC")
d.polyline([(4.8, 9.65), (5.8, 9.65)], "aCtrl")
d.polyline([(9.2, 9.65), (10.2, 9.65)], "aCtrl")
d.polyline([(13.6, 9.65), (14.6, 9.65)], "aCtrl")
d.polyline([(18.2, 9.65), (19.2, 9.65)], "aCtrl")

# S_DAT_START feeds whichever branch CMD.DATA_DIR selected.
d.polyline([(2.9, 8.1), (2.9, 9.1)], "aCtrl")

# --- both branches converge on the block boundary
d.rect(1.0, 11.2, 3.8, 1.1, "gSeq", "S_BLOCK_END", "tMono", "pC")
d.rect(5.8, 11.2, 4.4, 1.1, "gSeq", "S_PRE_BUSY_W", "tMono", "pC")
d.rect(11.2, 11.2, 3.8, 1.1, "gSeq", "S_STOP_TRAN", "tMono", "pC")
d.rect(16.0, 11.2, 3.2, 1.1, "gOK", "S_DONE", "tMono", "pC")
d.rect(20.6, 11.2, 3.2, 1.1, "gErr", "S_ABORT", "tMono", "pC")

# RD_CRC and WR_TAIL both fall into S_BLOCK_END, routed round the right edge.
d.polyline([(18.4, 7.55), (24.6, 7.55), (24.6, 10.9), (2.9, 10.9),
            (2.9, 11.2)], "aCtrl")
d.polyline([(22.8, 9.65), (23.9, 9.65), (23.9, 10.75), (2.9, 10.75),
            (2.9, 11.2)], "aCtrl")

d.polyline([(4.8, 11.75), (5.8, 11.75)], "aCtrl")
d.text(4.3, 10.95, 5.0, 0.6, ["more blocks"], "tTiny", "pL")
d.polyline([(10.2, 11.75), (11.2, 11.75)], "aCtrl")
d.polyline([(15.0, 11.75), (16.0, 11.75)], "aCtrl")
d.polyline([(20.6, 11.75), (19.2, 11.75)], "aRed")

d.rect(1.0, 13.4, 23.6, 2.6, "gNote",
       "Twenty states. Error exits are not drawn - every state has one, and "
       "they all converge on S_ABORT, which is the point of having it. What "
       "matters is where S_ABORT goes: not straight to S_IDLE but through "
       "S_DONE, so the DMA is told to abort and then allowed to drain. An "
       "Avalon master that simply stops issuing beats part-way through a burst "
       "hangs the interconnect, so abandoning a transfer is more work than not "
       "starting one. S_PRE_BUSY free-runs 0xFF with CS high before every "
       "command, which is why the shifter is always already running when a "
       "sending state is entered - a fact the assertion suite depends on and "
       "documents.", "tSmall", "pL")

# =============================================================================
# 5. Data path: where a block's bytes go
# =============================================================================
page("fig_datapath")

d.text(1.0, 0.6, 24, 1.0, ["Where a block's bytes go"], "tH", "pL")

d.text(1.0, 1.9, 24, 0.7, ["Read: card to memory"], "tGreen", "pL")
d.rect(1.0, 2.7, 4.0, 1.5, "gExt", ["SD card"], "tSmall", "pC")
d.rect(6.0, 2.7, 4.4, 1.5, "gBlk", ["_spi_phy", "byte at a time"], "tSmall", "pC")
d.rect(11.4, 2.7, 4.4, 1.5, "gBlk", ["_fifo", "packs 4 bytes"], "tSmall", "pC")
d.rect(16.8, 2.7, 4.4, 1.5, "gBlk", ["_dma", "bursts words"], "tSmall", "pC")
d.rect(22.2, 2.7, 3.6, 1.5, "gExt", ["memory"], "tSmall", "pC")
for x0, x1 in ((5.0, 6.0), (10.4, 11.4), (15.8, 16.8), (21.2, 22.2)):
    d.polyline([(x0, 3.45), (x1, 3.45)], "aGreen")

d.text(1.0, 5.0, 24, 0.7, ["Write: memory to card"], "tGreen", "pL")
d.rect(1.0, 5.8, 3.6, 1.5, "gExt", ["memory"], "tSmall", "pC")
d.rect(5.6, 5.8, 4.4, 1.5, "gBlk", ["_dma", "bursts words"], "tSmall", "pC")
d.rect(11.0, 5.8, 4.4, 1.5, "gBlk", ["_fifo", "unpacks 4 bytes"], "tSmall", "pC")
d.rect(16.4, 5.8, 4.4, 1.5, "gBlk", ["_spi_phy", "byte at a time"], "tSmall", "pC")
d.rect(21.8, 5.8, 4.0, 1.5, "gExt", ["SD card"], "tSmall", "pC")
for x0, x1 in ((4.6, 5.6), (10.0, 11.0), (15.4, 16.4), (20.8, 21.8)):
    d.polyline([(x0, 6.55), (x1, 6.55)], "aGreen")

d.text(1.0, 8.1, 24, 0.7, ["Without the DMA (USE_DMA = 0)"], "tRed", "pL")
d.rect(1.0, 8.9, 4.0, 1.5, "gExt", ["SD card"], "tSmall", "pC")
d.rect(6.0, 8.9, 4.4, 1.5, "gBlk", ["_spi_phy"], "tSmall", "pC")
d.rect(11.4, 8.9, 4.4, 1.5, "gBlk", ["_fifo"], "tSmall", "pC")
d.rect(16.8, 8.9, 4.8, 1.5, "gExt", ["CPU", "reads DATA, word at a time"],
       "tSmall", "pC")
for x0, x1 in ((5.0, 6.0), (10.4, 11.4), (15.8, 16.8)):
    d.polyline([(x0, 9.65), (x1, 9.65)], "aRed")

d.rect(1.0, 11.2, 24.8, 2.4, "gNote",
       "The FIFO is word-wide with a byte packer on the card side, because the "
       "two ends run at different widths and different rates: the shifter moves "
       "one byte per eight SPI clocks, the master moves four bytes per host "
       "cycle. Sizing it at two blocks rather than one is what lets the DMA "
       "drain block N while the shifter is receiving block N+1, which is where "
       "multi-block throughput comes from. In PIO mode the CPU is on a "
       "deadline: with no master to keep the buffer moving, software that is "
       "slow to service the DATA window starves the shifter and the stall "
       "timeout fires.", "tSmall", "pL")

# =============================================================================
outdir = sys.argv[1] if len(sys.argv) > 1 else os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "..", "..", "figures")
outdir = os.path.abspath(outdir)
os.makedirs(outdir, exist_ok=True)

for p in d.save(outdir, NAMES):
    print("wrote", p)
