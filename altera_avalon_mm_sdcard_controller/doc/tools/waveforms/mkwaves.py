#!/usr/bin/env python3
"""
Render the documents' timing figures from a recorded simulation.

    ./verification/capture.sh                 # writes verification/wave.vcd
    python3 doc/tools/waveforms/mkwaves.py    # writes doc/figures/fig_wave_*

Writes one .json and one .svg per figure. Both are tracked: the JSON is
WaveDrom source, readable and diffable; the SVG is what the documents embed,
so that building this repository does not require Node.

-----------------------------------------------------------------------------
WHERE THE FIGURES COME FROM
-----------------------------------------------------------------------------
Not from a drawing program. verification/wave_capture_tb.sv drives four
scenarios against the RTL and dumps a VCD; this script reconstructs the SPI byte
stream from sd_mosi and sd_miso sampled on sd_clk rising edges - which is where
the receiver samples - and emits WaveDrom.

Change the design and either the figure changes with it, or this script stops
finding the token or state it is looking for and exits saying which. A hand
drawn timing diagram just quietly becomes wrong, and SPI-mode SD punishes that:
N_CR is a range and not a fixed latency, the data-response token carries five
bits of meaning in eight, CRC16 is seeded with zero rather than the 0xFFFF that
"CCITT" implies everywhere else. A drawing that gets any of those wrong still
looks convincing.

-----------------------------------------------------------------------------
WHY BYTE-LEVEL
-----------------------------------------------------------------------------
A bit-level view of a 512-byte block is 4,096 columns wide, and what matters in
this protocol is the sequence of BYTES: which token arrived, how many idle bytes
passed before the response, what the card answered. So one column is one
byte-time.

fig_wave_bit is the exception and shows a single byte at bit level, because the
sampling edge is the one fact a byte-level view cannot express and the one an
integrator has to get right against real hardware.

The figures carry a title and nothing else. Explanation belongs in the document
around them, not baked into the picture where it cannot be edited or read at a
sensible size.
"""

import json
import os
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from vcd import Vcd, val                       # noqa: E402

DOC = os.path.abspath(os.path.join(HERE, "..", ".."))
CORE = os.path.abspath(os.path.join(DOC, ".."))

VCD = sys.argv[1] if len(sys.argv) > 1 else os.path.join(
    CORE, "verification", "wave.vcd")
OUT = os.path.abspath(sys.argv[2] if len(sys.argv) > 2
                      else os.path.join(DOC, "figures"))

if not os.path.exists(VCD):
    sys.exit(f"error: {VCD} not found - run verification/capture.sh first")

TB = "wave_capture_tb"
V = Vcd(VCD)
os.makedirs(OUT, exist_ok=True)

# The sequencer's state encoding, from rtl/..._seq.sv. check_facts.py compares
# this list against the RTL so the two cannot drift apart.
STATES = [
    "IDLE", "PRE_BUSY", "PRE_BUSY_W", "CMD", "RESP_WAIT", "RESP_TRAIL",
    "R1B_BUSY", "DAT_START", "RD_TOKEN", "RD_DATA", "RD_CRC", "WR_TOKEN",
    "WR_DATA", "WR_CRC", "WR_RESP", "WR_TAIL", "BLOCK_END", "STOP_TRAN",
    "DONE", "ABORT",
]

# The bench runs `always #5 clk = ~clk` on a 1ns/1ps timescale, so a host cycle
# is 10,000 VCD ticks. sd_clk is clk/2 at CLKDIV=1, so an SPI bit is 20,000.
# Sampling every 5,000 catches every sd_clk edge with one to spare.
STEP = 5_000
NAMES = [f"{TB}.{n}" for n in (
    "marker", "sd_clk", "sd_cs_n", "sd_mosi", "sd_miso", "irq",
    "m0_address", "m0_write", "m0_waitrequest",
)] + [
    f"{TB}.dut.u_seq.state",
    f"{TB}.dut.u_fifo.level_bytes",
]

missing = [n for n in NAMES if n not in V.by_name]
if missing:
    sys.exit("error: signals absent from the VCD - the bench changed?\n  " +
             "\n  ".join(missing))

S = V.sample(NAMES, 0, V.times[-1] if V.times else 0, STEP)


def sig(rec, name, width=1):
    return val(rec.get(name, "x"), width)


# ----------------------------------------------------------------------------
# Byte reconstruction
#
# Walk the samples, find sd_clk rising edges, shift MOSI and MISO into two 8-bit
# accumulators, most significant bit first. Bytes are counted only while CS is
# asserted: the core free-runs 0xFF with CS high before a command, and including
# that would put meaningless idle at the head of every figure.
# ----------------------------------------------------------------------------
class Byte:
    __slots__ = ("t0", "t1", "mosi", "miso", "state", "irq", "level",
                 "m0_write", "marker", "aborted")

    def __init__(self, **kw):
        self.marker = 0
        for k, v in kw.items():
            setattr(self, k, v)


def reconstruct():
    out, prev_clk, nbits, acc_o, acc_i, t0 = [], None, 0, 0, 0, None
    saw_m0w = False
    # S_ABORT is transient: the sequencer enters it, raises dma_abort and routes
    # on to S_DONE within a cycle or two. Sampling state once per byte never
    # lands on it, so a figure drawn from that sample says the error path was
    # not taken. Record whether it was entered at any point during the byte.
    saw_abort = False
    abort_code = STATES.index("ABORT")
    for t, rec in S:
        clk = sig(rec, f"{TB}.sd_clk")
        if sig(rec, f"{TB}.sd_cs_n") != 0:
            prev_clk, nbits, acc_o, acc_i, t0 = clk, 0, 0, 0, None
            saw_m0w, saw_abort = False, False
            continue
        if sig(rec, f"{TB}.dut.u_seq.state", 5) == abort_code:
            saw_abort = True
        if sig(rec, f"{TB}.m0_write") == 1 and \
                sig(rec, f"{TB}.m0_waitrequest") == 0:
            saw_m0w = True
        if prev_clk == 0 and clk == 1:
            if nbits == 0:
                t0 = t
            acc_o = ((acc_o << 1) | (sig(rec, f"{TB}.sd_mosi") or 0)) & 0xFF
            acc_i = ((acc_i << 1) | (sig(rec, f"{TB}.sd_miso") or 0)) & 0xFF
            nbits += 1
            if nbits == 8:
                out.append(Byte(
                    t0=t0, t1=t, mosi=acc_o, miso=acc_i,
                    state=sig(rec, f"{TB}.dut.u_seq.state", 5),
                    irq=sig(rec, f"{TB}.irq"),
                    level=sig(rec, f"{TB}.dut.u_fifo.level_bytes", 16),
                    m0_write=1 if saw_m0w else 0,
                    aborted=1 if saw_abort else 0))
                nbits, acc_o, acc_i = 0, 0, 0
                saw_m0w, saw_abort = False, False
        prev_clk = clk
    return out


BYTES = reconstruct()
if not BYTES:
    sys.exit("error: no complete SPI bytes found in the VCD")

# Tag every byte with the scenario in force when it completed.
_mk, _i = 0, 0
for b in BYTES:
    while _i < len(S) and S[_i][0] <= b.t1:
        m = sig(S[_i][1], f"{TB}.marker", 32)
        if m is not None:
            _mk = m
        _i += 1
    b.marker = _mk


def scenario(n):
    return [b for b in BYTES if b.marker == n]


def st(b):
    """State name without the RTL's S_ prefix.

    A state that lasts a single byte-time gets a one-column box, and WaveDrom
    neither clips nor shrinks a label too wide for it - it centres the text and
    lets it run over the neighbours. "S_RD_TOKEN" does exactly that even at
    hscale 2. The prefix carries no information inside a figure whose row is
    already labelled "state", so it goes, here and in the state diagram."""
    return STATES[b.state] if b.state is not None \
        and b.state < len(STATES) else "?"


def find(bs, pred, start=0):
    for i in range(start, len(bs)):
        if pred(bs[i]):
            return i
    return None


# ----------------------------------------------------------------------------
# WaveDrom helpers
#
# A wave string is one character per column. A character starts a new box; "."
# continues the one before it. So a row of bytes, every one of which is its own
# box, is a run of the same character with a data entry each - and a row that
# should merge equal neighbours emits "." for the repeats.
# ----------------------------------------------------------------------------
def byte_row(name, values, ch="2"):
    """One box per column, never merged - so a frame can be counted."""
    return {"name": name, "wave": ch * len(values), "data": list(values)}


def merged_row(name, values, chars="45"):
    """Merge equal neighbours, alternating colour so the joins are visible."""
    wave, data, prev, ci = "", [], object(), 0
    for v in values:
        if v == prev:
            wave += "."
        else:
            wave += chars[ci % len(chars)]
            ci += 1
            data.append(v)
            prev = v
    return {"name": name, "wave": wave, "data": data}


def bit_row(name, values):
    """A per-sample bit row: every column is genuinely a new sample, so each
    one gets its own character."""
    return {"name": name,
            "wave": "".join("x" if v is None else str(v) for v in values)}


def level_row(name, values):
    """A level that holds until it changes.

    Repeating the same character in a wave string does NOT mean "still low" -
    WaveDrom reads every character as a fresh transition and draws an edge at
    each one, so a flat signal comes out as a row of spikes. Only "." continues
    the level before it."""
    wave, prev = "", None
    for v in values:
        c = "x" if v is None else str(int(v))
        wave += "." if c == prev else c
        prev = c
    return {"name": name, "wave": wave}


FIGS = {}


def emit(name, signal, title, hscale=2):
    """hscale 2 by default: a state that lasts one byte-time gets a one-column
    box, and WaveDrom neither clips nor shrinks a label that does not fit - it
    just draws it over the neighbours. "S_RD_TOKEN" in a single column at the
    default scale lands on top of the two states either side of it."""
    FIGS[name] = {"signal": signal, "head": {"text": title},
                  "config": {"hscale": hscale}}


# =============================================================================
# 1. One byte at bit level
# =============================================================================
bs = scenario(1)
i = find(bs, lambda b: b.mosi not in (0x00, 0xFF))
if i is None:
    sys.exit("error: no non-trivial command byte found for fig_wave_bit")
b = bs[i]
fine = [rec for t, rec in S if b.t0 - 10_000 <= t <= b.t1 + 20_000]
emit("fig_wave_bit", [
    bit_row("sd_clk", [sig(r, f"{TB}.sd_clk") for r in fine]),
    bit_row("sd_mosi", [sig(r, f"{TB}.sd_mosi") for r in fine]),
    bit_row("sd_miso", [sig(r, f"{TB}.sd_miso") for r in fine]),
    bit_row("sd_cs_n", [sig(r, f"{TB}.sd_cs_n") for r in fine]),
], f"One byte on the wire — MOSI 0x{b.mosi:02X}, MISO 0x{b.miso:02X}, "
   f"MSB first. One column is one host clock.", hscale=1)

# =============================================================================
# 2. A command frame and its R1 response
# =============================================================================
bs = scenario(1)
i = find(bs, lambda b: b.mosi & 0xC0 == 0x40)
if i is None:
    sys.exit("error: no command frame found in scenario 1")
j = find(bs, lambda b: b.miso != 0xFF, i)
if j is None:
    sys.exit("error: no R1 response found in scenario 1")
NCR = j - (i + 6)
w = bs[max(0, i - 1):j + 3]
emit("fig_wave_cmd", [
    byte_row("MOSI", [f"{x.mosi:02X}" for x in w], "2"),
    byte_row("MISO", [f"{x.miso:02X}" for x in w], "3"),
    {},
    merged_row("state", [st(x) for x in w]),
], "CMD0 — six bytes out, then the card answers")

# =============================================================================
# 3. The start of a block read
# =============================================================================
bs = scenario(2)
i = find(bs, lambda b: b.miso == 0xFE)
if i is None:
    sys.exit("error: no 0xFE data token found in scenario 2")
w = bs[max(0, i - 4):i + 10]
emit("fig_wave_read", [
    byte_row("MOSI", [f"{x.mosi:02X}" for x in w], "2"),
    byte_row("MISO", [f"{x.miso:02X}" for x in w], "3"),
    {},
    merged_row("state", [st(x) for x in w]),
    merged_row("FIFO bytes", [str(x.level) for x in w], "==")
], "CMD17 — the 0xFE token, then data")

# =============================================================================
# 4. The end of a block write
# =============================================================================
bs = scenario(3)
i = find(bs, lambda b: st(b) == "WR_RESP" and b.miso is not None
         and (b.miso & 0x11) == 0x01)
if i is None:
    sys.exit("error: no data-response token found in scenario 3")
TOKEN = bs[i].miso
SSS = (TOKEN >> 1) & 0x7
NBUSY = len([x for x in bs[i + 1:] if x.miso == 0x00])
w = bs[max(0, i - 5):i + 8]
emit("fig_wave_write", [
    byte_row("MOSI", [f"{x.mosi:02X}" for x in w], "2"),
    byte_row("MISO", [f"{x.miso:02X}" for x in w], "3"),
    {},
    merged_row("state", [st(x) for x in w]),
], "CMD24 — CRC16, the data-response token, then the card is busy")

# =============================================================================
# 5. A block whose CRC16 does not match
# =============================================================================
bs = scenario(4)
i = find(bs, lambda b: st(b) == "RD_CRC")
if i is None:
    sys.exit("error: scenario 4 never reached S_RD_CRC")
j = find(bs, lambda b: st(b) in ("ABORT", "DONE"), i)
w = bs[max(0, i - 4):(j + 3) if j is not None else (i + 6)]
emit("fig_wave_crcerr", [
    byte_row("MOSI", [f"{x.mosi:02X}" for x in w], "2"),
    byte_row("MISO", [f"{x.miso:02X}" for x in w], "3"),
    {},
    merged_row("state", [st(x) for x in w]),
    level_row("ABORT entered", [x.aborted for x in w]),
], "A corrupted CRC16, caught at the end of the last CRC byte")

# =============================================================================
# Facts the document quotes, written where check_facts.py can compare them.
# =============================================================================
FACTS = {
    "ncr_bytes": NCR,
    "data_response_token": f"0x{TOKEN:02X}",
    "data_response_sss": f"0b{SSS:03b}",
    "busy_byte_times": NBUSY,
}

for name, src in FIGS.items():
    with open(os.path.join(OUT, name + ".json"), "w", encoding="utf-8") as f:
        json.dump(src, f, indent=1)
        f.write("\n")

with open(os.path.join(OUT, "wave_facts.json"), "w", encoding="utf-8") as f:
    json.dump(FACTS, f, indent=1)
    f.write("\n")

# ---- render, if Node and WaveDrom are available -----------------------------
node = shutil.which("node") or shutil.which("nodejs")
if not node:
    print("wrote the WaveDrom JSON; node not found, so no SVG was rendered")
    print("  install Node, then: cd doc/tools/waveforms && npm install wavedrom onml")
    sys.exit(0)

rc = 0
for name in FIGS:
    j_path = os.path.join(OUT, name + ".json")
    s_path = os.path.join(OUT, name + ".svg")
    r = subprocess.run([node, os.path.join(HERE, "render.js"), j_path, s_path],
                       capture_output=True, text=True)
    if r.returncode != 0:
        sys.stderr.write(r.stderr)
        rc = r.returncode
        break
    print("wrote", s_path)
sys.exit(rc)
