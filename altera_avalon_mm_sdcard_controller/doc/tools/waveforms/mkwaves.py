#!/usr/bin/env python3
"""
Render the user guide's timing figures from a real simulation.

The figures are generated from a VCD rather than drawn by hand, so they cannot
drift away from the RTL: change the design and either the figure changes with
it, or the scenario stops matching and this script fails loudly. A hand-drawn
timing diagram just quietly becomes fiction - and SPI-mode SD is exactly the
kind of protocol where that happens, because it is full of details a plausible
drawing gets wrong: N_CR is a range and not a fixed latency, the data-response
token carries five bits of meaning in eight, and CRC16 is seeded with zero
rather than the 0xFFFF that "CCITT" implies everywhere else.

The bench lives in verification/wave_capture_tb.sv; this module only renders
what it captured.

    ./verification/capture.sh                     # writes verification/wave.vcd
    python3 doc/tools/waveforms/mkwaves.py

WHY THESE FIGURES ARE BYTE-LEVEL
--------------------------------
A bit-level view of a 512-byte block is 4,096 columns wide, and the interesting
structure of this protocol is not in the bits - it is in the sequence of BYTES:
which token arrived, how many idle bytes passed before the response, what the
card answered. So this renderer reconstructs bytes from sd_mosi and sd_miso by
sampling them on sd_clk rising edges - which is where the receiver samples,
CPOL=0/CPHA=0 - and draws one column per byte-time.

One figure is the exception. fig_wave_bit shows a single byte at bit level,
because the sampling edge is the one fact a byte-level view cannot express and
the one an integrator has to get right when they wire this to a real card.

Written figures:
    fig_wave_bit        one byte at bit level, showing the sampling edge
    fig_wave_cmd        a command frame and its R1 response, with N_CR
    fig_wave_read       the start of a block read: R1, wait, 0xFE, data
    fig_wave_write      the end of a block write: CRC, data-response, busy
    fig_wave_crcerr     a block whose CRC16 does not match, and the abort
"""

import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from wavedraw import Vcd, val, draw          # noqa: E402

# Every tool under doc/tools resolves paths from its own location rather than
# the caller's cwd, so it works the same run from anywhere.
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

# The sequencer's state encoding, from rtl/..._seq.sv. Keeping the list here
# rather than parsing the RTL would be a place for the two to drift, so
# check_facts.py compares them.
STATES = [
    "IDLE", "PRE_BUSY", "PRE_BUSY_W", "CMD", "RESP_WAIT", "RESP_TRAIL",
    "R1B_BUSY", "DAT_START", "RD_TOKEN", "RD_DATA", "RD_CRC", "WR_TOKEN",
    "WR_DATA", "WR_CRC", "WR_RESP", "WR_TAIL", "BLOCK_END", "STOP_TRAN",
    "DONE", "ABORT",
]

# -----------------------------------------------------------------------------
# Sampling
#
# The bench runs `always #5 clk = ~clk` on a 1ns/1ps timescale, so a host cycle
# is 10,000 VCD ticks and the first negedge lands at 5,000. sd_clk is clk/2 at
# CLKDIV=1, so an SPI bit is 20,000 ticks. Sampling every 5,000 catches every
# sd_clk edge with a sample to spare, which is what the byte reconstruction
# below needs.
# -----------------------------------------------------------------------------
STEP = 5_000
NAMES = [f"{TB}.{n}" for n in (
    "marker", "sd_clk", "sd_cs_n", "sd_mosi", "sd_miso", "irq",
    "m0_address", "m0_write", "m0_writedata", "m0_burstcount", "m0_waitrequest",
)] + [
    f"{TB}.dut.u_seq.state",
    f"{TB}.dut.u_fifo.level_bytes",
]

missing = [n for n in NAMES if n not in V.by_name]
if missing:
    sys.exit("error: signals absent from the VCD - the bench changed?\n  " +
             "\n  ".join(missing))

S = V.sample(NAMES, 0, V.times[-1] if V.times else 0, STEP)


def g(rec, sig, width=1):
    return val(rec.get(f"{TB}.{sig}" if "." not in sig or sig.startswith("dut")
                       else f"{TB}.{sig}", "x"), width)


def sig(rec, name, width=1):
    return val(rec.get(name, "x"), width)


# -----------------------------------------------------------------------------
# Byte reconstruction
#
# Walk the samples, find sd_clk rising edges, and shift MOSI and MISO into two
# 8-bit accumulators. A byte is complete on the eighth edge. Bit numbering is
# MSB first, which is what SD SPI mode uses and what the shifter implements.
#
# Bytes are counted only while CS is asserted. The core free-runs 0xFF with CS
# high before a command (S_PRE_BUSY), and including that in the byte stream
# would put a run of meaningless 0xFF at the head of every figure.
# -----------------------------------------------------------------------------
class Byte:
    __slots__ = ("t0", "t1", "mosi", "miso", "state", "irq", "level",
                 "m0_write", "m0_addr", "marker", "aborted")

    def __init__(self, **kw):
        self.marker = 0
        for k, v in kw.items():
            setattr(self, k, v)


def reconstruct():
    out = []
    prev_clk = None
    nbits = 0
    acc_o = acc_i = 0
    t0 = None
    # per-byte aggregates: a byte spans 16 host cycles, so "did the DMA write
    # during this byte" is more useful in a byte-level figure than the value of
    # m0_write at one instant.
    saw_m0w = False
    m0_addr = None
    # S_ABORT is transient - the sequencer enters it, raises dma_abort, and
    # routes on to S_DONE within a cycle or two. Sampling the state once per
    # byte therefore never lands on it, and a figure drawn from that sample
    # says the core went straight from RD_CRC to DONE, which would tell the
    # reader the error path was not taken. So the abort is recorded as "was it
    # entered at any point during this byte" rather than "is it the state now".
    saw_abort = False
    for t, rec in S:
        clk = sig(rec, f"{TB}.sd_clk")
        cs = sig(rec, f"{TB}.sd_cs_n")
        if cs != 0:
            prev_clk, nbits, acc_o, acc_i, t0 = clk, 0, 0, 0, None
            saw_m0w, m0_addr, saw_abort = False, None, False
            continue
        if sig(rec, f"{TB}.dut.u_seq.state", 5) == STATES.index("ABORT"):
            saw_abort = True
        if sig(rec, f"{TB}.m0_write") == 1 and \
                sig(rec, f"{TB}.m0_waitrequest") == 0:
            saw_m0w = True
            if m0_addr is None:
                m0_addr = sig(rec, f"{TB}.m0_address", 32)
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
                    m0_addr=m0_addr,
                    aborted=1 if saw_abort else 0))
                nbits, acc_o, acc_i = 0, 0, 0
                saw_m0w, m0_addr, saw_abort = False, None, False
        prev_clk = clk
    return out


BYTES = reconstruct()
if not BYTES:
    sys.exit("error: no complete SPI bytes found in the VCD")


def marker_at(t):
    """The scenario marker in force at VCD time t."""
    last = 0
    for tt, rec in S:
        if tt > t:
            break
        m = sig(rec, f"{TB}.marker", 32)
        if m is not None:
            last = m
    return last


# Tag every byte with its scenario, once, rather than rescanning per byte.
_mk, _i = 0, 0
for b in BYTES:
    while _i < len(S) and S[_i][0] <= b.t1:
        m = sig(S[_i][1], f"{TB}.marker", 32)
        if m is not None:
            _mk = m
        _i += 1
    b.marker = _mk


def scenario(n):
    return [b for b in BYTES if getattr(b, "marker", 0) == n]


def st(b):
    return STATES[b.state] if b.state is not None and b.state < len(STATES) \
        else "?"


def hx(v):
    return "--" if v is None else f"{v:02X}"


def rows_for(bs, extra=()):
    """Standard byte-level rows for a run of reconstructed bytes.

    'byte' rather than 'bus' for the two wire rows, so that a run of equal
    bytes is drawn as a run of cells and the reader can count the frame. The
    state row uses 'bus', where merging is exactly what is wanted: a state that
    holds for six byte-times should read as one wide cell.
    """
    r = [("MOSI  host to card", "byte", [hx(b.mosi) for b in bs]),
         ("MISO  card to host", "byte", [hx(b.miso) for b in bs]),
         ("sequencer state", "bus", [st(b) for b in bs])]
    r.extend(extra)
    return r


def find(bs, pred, start=0):
    for i in range(start, len(bs)):
        if pred(bs[i]):
            return i
    return None


# =============================================================================
# 1. One byte at bit level
#
# The only figure here that is not byte-level, and the reason it exists: an
# integrator wiring this to a real card needs to know which edge the data is
# sampled on, and no byte-level view can say. CPOL=0, CPHA=0 - MOSI changes on
# the falling edge, both ends sample on the rising edge.
# =============================================================================
def fig_bit():
    # A byte from the command frame, chosen because its bits are not all the
    # same - an 0xFF or 0x00 would make a figure that demonstrates nothing.
    bs = scenario(1)
    i = find(bs, lambda b: b.mosi not in (0x00, 0xFF))
    if i is None:
        sys.exit("error: no non-trivial command byte found for fig_wave_bit")
    b = bs[i]
    # Re-sample this one byte at host-cycle resolution. t0 is the first rising
    # edge; back off half an SPI period so the figure opens before it.
    t_from, t_to = b.t0 - 10_000, b.t1 + 20_000
    fine = [rec for t, rec in S if t_from <= t <= t_to]
    n = len(fine)
    rows = [
        ("sd_clk", "bit", [sig(r, f"{TB}.sd_clk") for r in fine]),
        ("sd_mosi", "bit", [sig(r, f"{TB}.sd_mosi") for r in fine]),
        ("sd_miso", "bit", [sig(r, f"{TB}.sd_miso") for r in fine]),
        ("sd_cs_n", "bit", [sig(r, f"{TB}.sd_cs_n") for r in fine]),
    ]
    return draw(os.path.join(OUT, "fig_wave_bit.svg"), rows, n, notes=[
        f"One byte on the wire: MOSI = 0x{b.mosi:02X}, MISO = 0x{b.miso:02X}, "
        "most significant bit first.",
        "CPOL = 0, CPHA = 0. MOSI changes on the falling edge of sd_clk; both "
        "ends sample on the rising edge.",
        "Each column is one host clock. At CLKDIV = 1 the SPI clock is clk/2, "
        "so one SPI bit is two columns.",
    ])


# =============================================================================
# 2. A command frame and its R1 response
# =============================================================================
def fig_cmd():
    bs = scenario(1)
    i = find(bs, lambda b: b.mosi & 0xC0 == 0x40)      # the 01 start bits
    if i is None:
        sys.exit("error: no command frame found in scenario 1")
    j = find(bs, lambda b: b.miso != 0xFF, i)          # the response byte
    if j is None:
        sys.exit("error: no R1 response found in scenario 1")
    w = bs[max(0, i - 1):j + 3]
    ncr = j - (i + 6)
    return draw(os.path.join(OUT, "fig_wave_cmd.svg"), rows_for(w), len(w),
                notes=[
        "CMD0 GO_IDLE_STATE. Six bytes out: 0x40 | index, four argument bytes, "
        "then CRC7 shifted up one with the stop bit in bit 0.",
        f"The card answered {ncr} byte-times after the frame. The "
        "specification allows N_CR to be anything from 0 to 8, so the core "
        "polls for a byte with bit 7 clear rather than waiting a fixed time.",
        "R1 = 0x01 is In Idle State, which is the correct answer to CMD0 and "
        "not an error.",
        "MISO reads 0xFF whenever the card is not driving it - the line is "
        "pulled up, and the host clocks 0xFF out to generate the clock.",
    ])


# =============================================================================
# 3. The start of a block read
# =============================================================================
def fig_read():
    bs = scenario(2)
    i = find(bs, lambda b: b.miso == 0xFE)             # the start token
    if i is None:
        sys.exit("error: no 0xFE data token found in scenario 2")
    w = bs[max(0, i - 4):i + 10]
    return draw(os.path.join(OUT, "fig_wave_read.svg"), rows_for(w, extra=[
        ("FIFO bytes", "bus", [str(b.level) for b in w]),
    ]), len(w), notes=[
        "CMD17 READ_SINGLE_BLOCK, after the R1. The card may take as long as "
        "it likes before the block arrives, so the core sits in RD_TOKEN "
        "clocking 0xFF until it sees a token.",
        "0xFE is the start-of-block token. Anything with the top four bits "
        "clear is a data error token instead, and the core reports it in "
        "ERR_INFO rather than treating the byte as data.",
        "The 512 data bytes follow immediately, then a two-byte CRC16. The "
        "FIFO count rises as they land; the DMA drains it in parallel, which "
        "is why the count does not simply climb to 512.",
    ])


# =============================================================================
# 4. The end of a block write
# =============================================================================
def fig_write():
    bs = scenario(3)
    # The data-response token: the first byte after the block whose bit 4 is
    # clear. Its shape is xxx0sss1 - five bits of meaning in eight.
    i = find(bs, lambda b: st(b) == "WR_RESP" and b.miso is not None
             and (b.miso & 0x11) == 0x01)
    if i is None:
        sys.exit("error: no data-response token found in scenario 3")
    w = bs[max(0, i - 5):i + 8]
    tok = bs[i].miso
    sss = (tok >> 1) & 0x7
    meaning = {0b010: "accepted", 0b101: "CRC error",
               0b110: "write error"}.get(sss, "reserved")
    nbusy = len([b for b in bs[i + 1:] if b.miso == 0x00])
    return draw(os.path.join(OUT, "fig_wave_write.svg"), rows_for(w), len(w),
                notes=[
        "CMD24 WRITE_BLOCK, at the end of the block: the last data bytes, the "
        "two CRC16 bytes, then the card's data-response token.",
        f"The token is 0x{tok:02X}. Only five bits carry meaning - the shape is "
        f"xxx0sss1, and sss = 0b{sss:03b} is \"{meaning}\". Comparing the whole "
        "byte against a constant is the classic way to get this wrong.",
        f"The card then held MISO low for {nbusy} byte-times while it "
        "programmed the block. The core reports this as CARD_BUSY in STATUS "
        "and will not start the next command until it lifts.",
    ])


# =============================================================================
# 5. A block whose CRC16 does not match
# =============================================================================
def fig_crcerr():
    bs = scenario(4)
    i = find(bs, lambda b: st(b) == "RD_CRC")
    if i is None:
        sys.exit("error: scenario 4 never reached RD_CRC")
    j = find(bs, lambda b: st(b) in ("ABORT", "DONE"), i)
    end = (j + 3) if j is not None else (i + 6)
    w = bs[max(0, i - 4):end]
    # No irq row here, deliberately. irq is already high through the whole data
    # phase because DMA_DONE fires each time the DMA drains a burst, so the row
    # is a flat 1 and shows the reader nothing about the error. That is not a
    # defect and it is worth knowing: the pin says "something happened", and
    # only IRQ_STATUS says what. The note below says so instead.
    return draw(os.path.join(OUT, "fig_wave_crcerr.svg"), rows_for(w, extra=[
        ("S_ABORT entered", "bit", [b.aborted for b in w]),
    ]), len(w), notes=[
        "The same read as the previous figure, with the card corrupting the "
        "CRC16. The two CRC bytes arrive in RD_CRC exactly as they would if "
        "they were right - nothing on the wire says otherwise.",
        "The core folds the final byte into the running CRC16 combinationally "
        "and checks the result against zero, so the mismatch is known at the "
        "end of the last CRC byte rather than a byte later. That is why the "
        "check is written that way.",
        "S_ABORT is transient - it raises dma_abort and routes on to S_DONE "
        "within a cycle or two, which is why it never appears in the state row "
        "and needs a row of its own. IRQ_STATUS bit 12 (ERR_DAT_CRC) is set, "
        "and any DMA still in flight is drained rather than cut off mid-burst - "
        "an Avalon master that stops issuing beats mid-burst hangs the "
        "interconnect.",
        "There is no irq row because it would be a flat 1: DMA_DONE has already "
        "raised the pin during the data phase. The pin says something happened; "
        "only IRQ_STATUS says what, which is why a handler must read it rather "
        "than infer the cause from the interrupt alone.",
    ])


written = [fig_bit(), fig_cmd(), fig_read(), fig_write(), fig_crcerr()]
for p in written:
    print("wrote", p)
