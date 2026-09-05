#!/usr/bin/env python3
"""
Draw the block diagrams for the Avalon-MM SD Card Controller.

    python3 build_figures.py [outdir]        default doc/figures

Writes one .dot and one .svg per figure. Both are tracked: the .dot is the
source you edit, the .svg is what the documents embed.

-----------------------------------------------------------------------------
WHY GRAPHVIZ AND NOT HAND-PLACED COORDINATES
-----------------------------------------------------------------------------
The first version of these figures placed every box and every line by hand, in
centimetres, using the svg_lib the other cores' diagrams use. For a diagram that
is a row of boxes that works. For the sequencer's state machine it did not: two
convergence lines ran right to left across the whole figure at nearly the same
height, crossed the arrow they were converging with, and clipped a label on the
way past. S_ABORT sat at the far right pointing backwards into S_DONE. Nobody
could trace a path through it.

Edge routing is a solved problem and solving it again by eye is a bad trade.
Graphviz does the layout; this file only says what connects to what. Move a node
and every line reroutes itself, which is the whole point.

The register map used to be a figure here too. It was a table drawn as a
picture - the same rows the user guide already carries as a real table, but
unselectable, unsearchable and impossible to keep in step. It is gone. A table
should be a table.
"""

import os
import shutil
import subprocess
import sys

OUT = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "..", "..", "figures"))

# --------------------------------------------------------------------- style
#
# One palette, shared with the other cores' figures so the set still looks like
# one set: ink blue for structure, green for the sequencer and its arcs, grey
# for anything outside the core, red for the error path.
INK, INK_F = "#1F3864", "#DCE6F1"
GRN, GRN_F = "#375623", "#E2EFDA"
EXT, EXT_F = "#595959", "#F2F2F2"
RED, RED_F = "#C00000", "#FDECEC"
OK, OK_F = "#2E7D32", "#E8F5E9"
CORE, CORE_F = "#843C0C", "#FDE9D9"

HEAD = """digraph {name} {{
  bgcolor="white";
  fontname="DejaVu Sans"; fontsize=11;
  node [fontname="DejaVu Sans", fontsize=10.5, shape=box,
        style="filled,rounded", penwidth=1.4, margin="0.18,0.09"];
  edge [fontname="DejaVu Sans", fontsize=9, fontcolor="#555555",
        penwidth=1.3, arrowsize=0.75];
"""


def blk(fill, line):
    return f'fillcolor="{fill}", color="{line}"'


FIGS = {}


def fig(name, body, **attrs):
    a = "\n".join(f"  {k}={v};" for k, v in attrs.items())
    FIGS[name] = HEAD.format(name=name) + a + "\n" + body + "\n}\n"


# =============================================================================
# 1. System context - what the core connects to
# =============================================================================
fig("fig_context", f"""
  node [{blk(EXT_F, EXT)}];
  cpu  [label="Nios II\\nor any Avalon-MM master"];
  mem  [label="System memory\\nSDRAM or on-chip RAM"];
  card [label="SD card\\nfour wires plus power"];
  clk  [label="clk / reset_n", shape=box, style="filled", height=0.3];

  node [{blk(CORE_F, CORE)}, penwidth=2];
  core [label="avalon_mm_sdcard_controller\\nSD / SDHC / SDXC, SPI mode",
        fontsize=12, fontcolor="{CORE}"];

  edge [color="{INK}"];
  cpu  -> core [label="  csr\\l  17 registers\\l", dir=both];
  core -> mem  [label="  m0\\l  block data\\l", dir=both];
  core -> cpu  [label="  irq  ", style=dashed, constraint=false];
  core -> card [label="  sd\\l  clk mosi miso cs_n\\l", dir=both];
  clk  -> core [color="{EXT}", style=dotted, arrowhead=none];

  {{ rank=same; cpu; core; card; }}
""", rankdir="LR", ranksep="1.1", nodesep="0.5")

# =============================================================================
# 2. Internal structure - what is inside, and what talks to what
# =============================================================================
fig("fig_internal", f"""
  compound=true;

  subgraph cluster_core {{
    label="avalon_mm_sdcard_controller";
    fontcolor="{CORE}"; fontsize=12; color="{CORE}"; penwidth=2;
    style=rounded; bgcolor="{CORE_F}"; margin=16;

    node [{blk(INK_F, INK)}];
    regs [label="regs\\nregister file"];
    fifo [label="fifo\\nbytes to words"];
    phy  [label="spi_phy\\ncontinuous shifter"];
    crc  [label="crc\\nCRC7 + CRC16"];
    ckg  [label="clkgen\\nSPI clock"];

    node [{blk(GRN_F, GRN)}, penwidth=1.8];
    seq  [label="seq\\nprotocol engine"];

    node [{blk("#FFFFFF", EXT)}, style="filled,rounded,dashed"];
    dma  [label="dma\\nAvalon master\\n(USE_DMA)"];

    edge [color="{INK}"];
    regs -> seq  [label="  commands  ", dir=both];
    seq  -> fifo [label="  block data  ", dir=both];
    fifo -> dma  [dir=both];
    seq  -> phy  [label="  a byte at a time  ", dir=both];
    ckg  -> phy  [label="  strobes  ", color="{EXT}"];
    phy  -> crc  [label="  every byte  ", dir=both];
    regs -> dma  [label="  address  ", color="{GRN}", style=dashed,
                  constraint=false];

    // Two lanes, forced - and forced from INSIDE the cluster. Left to right
    // the core is a chain, but it forks at the sequencer: block data leaves
    // through the FIFO and the master, single bytes leave through the shifter.
    // Without these ranks dot interleaves the two and draws the CRC unit past
    // the memory, as though it were downstream of it.
    //
    // A rank group that mixes nodes inside the cluster with nodes outside it
    // does not merely fail, it collapses the cluster's bounding box down to
    // whatever is left - so host, ram and pins are deliberately not here.
    // crc and clkgen are satellites of the shifter, not stages after it, so
    // they share its column rather than taking a rank of their own. Given a
    // rank to themselves the CRC unit sits between the shifter and the pins
    // and the SPI wire has to detour around it.
    {{ rank=same; fifo; phy; ckg; crc; }}
  }}

  node [{blk(EXT_F, EXT)}, style=filled];
  host [label="CPU"];
  ram  [label="memory"];
  pins [label="SD card"];

  edge [color="{INK}"];
  host -> regs [label="  csr  ", dir=both];
  dma  -> ram  [label="  m0  ", dir=both];
  phy  -> pins [label="  sd  ", dir=both];

  // Both of these are outside the cluster, so grouping them is safe - and it
  // is what stops the SD card being drawn adrift below the core with its wire
  // running diagonally across the corner of the box.
  {{ rank=same; ram; pins; }}
""", rankdir="LR", ranksep="0.75", nodesep="0.45")

# =============================================================================
# 3. Sequencer states
#
# The figure that forced the rewrite. Twenty states with two branches that
# rejoin - exactly the shape hand placement cannot keep tidy.
# =============================================================================
fig("fig_states", f"""
  // States are drawn without the RTL's S_ prefix: it is repeated twenty times,
  // carries nothing, and in the timing figures a prefixed name does not fit a
  // one-column box. The prose names them in full.
  node [{blk(GRN_F, GRN)}, fontname="DejaVu Sans Mono", fontsize=10];
  edge [color="{GRN}"];

  IDLE  [label="IDLE", {blk(EXT_F, EXT)}];
  PRE   [label="PRE_BUSY"];
  CMD   [label="CMD"];
  RESP  [label="RESP_WAIT"];
  TRAIL [label="RESP_TRAIL"];
  R1B   [label="R1B_BUSY"];
  DAT   [label="DAT_START"];

  RDT [label="RD_TOKEN"]; RDD [label="RD_DATA"]; RDC [label="RD_CRC"];
  WRT [label="WR_TOKEN"]; WRD [label="WR_DATA"]; WRC [label="WR_CRC"];
  WRR [label="WR_RESP"];  WRL [label="WR_TAIL"];

  BEND [label="BLOCK_END"];
  PREW [label="PRE_BUSY_W"];
  STOP [label="STOP_TRAN"];
  DONE [label="DONE",  {blk(OK_F, OK)}, penwidth=2];
  ABRT [label="ABORT", {blk(RED_F, RED)}, penwidth=2];

  IDLE -> PRE  [label="  CMD written"];
  PRE  -> CMD  [label="  MISO high"];
  CMD  -> RESP;
  RESP -> TRAIL [label="  R2/R3/R7"];
  RESP -> R1B   [label="  R1b"];
  TRAIL -> DAT;
  R1B  -> DAT;
  RESP -> DAT  [label="  R1"];
  RESP -> DONE [label="  no data phase  ", constraint=false];

  DAT -> RDT [label="  read"];
  DAT -> WRT [label="  write"];
  RDT -> RDD [label="  0xFE"];
  RDD -> RDC; RDC -> BEND;
  WRT -> WRD; WRD -> WRC; WRC -> WRR; WRR -> WRL; WRL -> BEND;

  BEND -> PREW [label="  more blocks"];
  PREW -> WRT  [constraint=false, style=dashed];
  BEND -> STOP [label="  multi-block\\l  write ends\\l"];
  BEND -> DONE [label="  finished  "];
  STOP -> DONE;
  ABRT -> DONE [color="{RED}", fontcolor="{RED}", label="  abort the DMA,\\l  then drain it\\l"];
  DONE -> IDLE [style=dotted, color="{EXT}", constraint=false];

  any [label="any state", shape=plaintext, style="", fontsize=9,
       fontcolor="{RED}"];
  any -> ABRT [color="{RED}", style=dashed,
               label="  error or timeout  ", fontcolor="{RED}"];

  {{ rank=same; RDT; WRT; }}
  {{ rank=same; DONE; ABRT; any; }}
""", rankdir="TB", ranksep="0.42", nodesep="0.35")

# =============================================================================
# 4. Where a block's bytes go
# =============================================================================
fig("fig_datapath", f"""
  node [{blk(INK_F, INK)}];
  edge [color="{OK}", penwidth=1.8];

  // Declared bottom-first: dot stacks clusters in reverse declaration
  // order, so listing read, write, PIO in the obvious order prints them
  // upside down.
  subgraph cluster_pio {{
    label="Read with USE_DMA = 0 — the CPU moves every word";
    fontcolor="{RED}"; color="{RED}"; style=rounded; margin=12;
    p0 [label="SD card", {blk(EXT_F, EXT)}];
    p1 [label="spi_phy"];
    p2 [label="fifo"];
    p3 [label="CPU\\nreads the DATA\\nregister, on a deadline",
        {blk(RED_F, RED)}];
    edge [color="{RED}"];
    p0 -> p1 -> p2 -> p3;
  }}
  subgraph cluster_wr {{
    label="Write — memory to card"; fontcolor="{OK}"; color="{OK}";
    style=rounded; margin=12;
    w0 [label="memory", {blk(EXT_F, EXT)}];
    w1 [label="dma\\nbursts words"];
    w2 [label="fifo\\nunpacks a word\\ninto 4 bytes"];
    w3 [label="spi_phy\\none byte per\\n8 SPI clocks"];
    w4 [label="SD card", {blk(EXT_F, EXT)}];
    w0 -> w1 -> w2 -> w3 -> w4;
  }}

  subgraph cluster_rd {{
    label="Read — card to memory"; fontcolor="{OK}"; color="{OK}";
    style=rounded; margin=12;
    r0 [label="SD card", {blk(EXT_F, EXT)}];
    r1 [label="spi_phy\\none byte per\\n8 SPI clocks"];
    r2 [label="fifo\\npacks 4 bytes\\ninto a word"];
    r3 [label="dma\\nbursts words"];
    r4 [label="memory", {blk(EXT_F, EXT)}];
    r0 -> r1 -> r2 -> r3 -> r4;
  }}

""", rankdir="LR", ranksep="0.5", nodesep="0.35")

# =============================================================================
if not shutil.which("dot"):
    sys.exit("error: graphviz not found - install it (apt install graphviz)")

os.makedirs(OUT, exist_ok=True)
for name, src in FIGS.items():
    dot_path = os.path.join(OUT, name + ".dot")
    svg_path = os.path.join(OUT, name + ".svg")
    with open(dot_path, "w", encoding="utf-8") as f:
        f.write(src)
    r = subprocess.run(["dot", "-Tsvg", dot_path, "-o", svg_path],
                       capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit(f"error: dot failed on {name}\n{r.stderr}")
    if r.stderr.strip():
        print(f"  note ({name}): {r.stderr.strip()}")
    print("wrote", svg_path)
