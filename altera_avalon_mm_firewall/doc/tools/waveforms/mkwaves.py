#!/usr/bin/env python3
"""
Render the user guide's timing figures from a real simulation.

The figures are generated from a VCD rather than drawn by hand, so they cannot
drift away from the RTL: change the design and either the figure changes with
it, or the scenario stops matching and this script fails loudly. A hand-drawn
timing diagram just quietly becomes fiction.

The bench lives in verification/wave_capture_tb.sv; this module only renders
what it captured.

    cd verification && ./capture.sh          # writes wave.vcd
    cd doc/tools/waveforms
    python3 mkwaves.py ../../../verification/wave.vcd

Any simulator that writes a VCD will do. wave_capture_tb.sv drives an `int
marker` signal tagging the four windows this script cuts out:
    1 permitted write burst   2 refused read burst
    3 read timeout            4 recovery
"""

import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from wavedraw import Vcd, val, draw          # noqa: E402

# Every tool under doc/tools resolves paths from its own location rather than
# the caller's cwd, so it works the same run from anywhere.
DOC = os.path.abspath(os.path.join(HERE, "..", ".."))

VCD = sys.argv[1] if len(sys.argv) > 1 else os.path.join(
    DOC, "..", "verification", "wave.vcd")
OUT = os.path.abspath(sys.argv[2] if len(sys.argv) > 2
                      else os.path.join(DOC, "figures"))

TB = "wave_capture_tb"
V = Vcd(VCD)
os.makedirs(OUT, exist_ok=True)

NAMES = [f"{TB}.{n}" for n in (
    "marker", "s_addr", "s_read", "s_write", "s_wdata", "s_burst", "s_wait",
    "s_rdata", "s_rdv", "s_resp",
    "m_addr", "m_read", "m_write", "m_wdata", "m_burst", "m_wait",
    "m_rdv", "periph_rst_n", "irq",
    "c_write", "c_addr",
)] + [f"{TB}.dut.{n}" for n in (
    "downstream_broken", "unblock", "rd_deny_beats", "rd_fwd_beats",
    "wr_beats_left", "rd_stuck",
)]

# Sample every clock period. The bench uses `always #5 clk = ~clk` with a
# 1ns/1ps timescale, so one cycle is 10000 VCD ticks; the first edge lands at
# 5000.
S = V.sample(NAMES, 5000, 10_000_000, 10000)


def marker_cycle(m):
    for i, (_t, d) in enumerate(S):
        if val(d.get(f"{TB}.marker"), 32) == m:
            return i
    raise SystemExit(
        f"mkwaves: marker {m} never appears in {VCD}.\n"
        "         The capture bench and this renderer have gone out of step - "
        "regenerate wave.vcd, and if the scenario really has changed, update "
        "the figure definitions here rather than hand-editing the SVG.")


def bits(name, lo, n):
    return [val(S[lo + c][1].get(f"{TB}.{name}"), 1) for c in range(n)]


def bus(name, lo, n, width, fmt=lambda v: v):
    out = []
    for c in range(n):
        v = val(S[lo + c][1].get(f"{TB}.{name}"), width)
        out.append(None if v is None else fmt(v))
    return out


RESP = {0: "OKAY", 2: "SLVERR", 3: "DECERR"}
hexw = lambda w: (lambda v: f"0x{v:0{w}X}")


# ------------------------------------------------- Figure: permitted burst
lo, n = marker_cycle(1) + 1, 14
draw(f"{OUT}/fig_burst_ok.svg",
     [("clk", "clk", []),
      ("s0_write",        "bit", bits("s_write", lo, n)),
      ("s0_burstcount",   "bus", bus("s_burst", lo, n, 8)),
      ("s0_writedata",    "bus", bus("s_wdata", lo, n, 32, hexw(8))),
      ("s0_waitrequest",  "bit", bits("s_wait", lo, n)),
      ("m0_write",        "bit", bits("m_write", lo, n)),
      ("m0_address",      "bus", bus("m_addr", lo, n, 32, hexw(8))),
      ("m0_writedata",    "bus", bus("m_wdata", lo, n, 32, hexw(8))),
      ("m0_waitrequest",  "bit", bits("m_wait", lo, n)),
      ("wr_beats_left",   "bus", bus("dut.wr_beats_left", lo, n, 8)),
      ], n,
     ["A 4-beat write burst into a window that permits writes and bursts.",
      "m0 is s0 gated by the rule lookup: the same beats, the same cycle, no buffering. "
      "s0_waitrequest is m0_waitrequest unmodified, so the core adds no latency at all.",
      "The address is meaningful only on the first beat; wr_beats_left is what holds "
      "the burst together, and the verdict formed at beat 1 governs all four."])

# --------------------------------------------------- Figure: refused burst
lo, n = marker_cycle(2) + 1, 14
draw(f"{OUT}/fig_burst_denied.svg",
     [("clk", "clk", []),
      ("s0_read",         "bit", bits("s_read", lo, n)),
      ("s0_burstcount",   "bus", bus("s_burst", lo, n, 8)),
      ("s0_waitrequest",  "bit", bits("s_wait", lo, n)),
      ("m0_read",         "bit", bits("m_read", lo, n)),
      ("rd_deny_beats",   "bus", bus("dut.rd_deny_beats", lo, n, 16)),
      ("s0_readdatavalid", "bit", bits("s_rdv", lo, n)),
      ("s0_readdata",     "bus", bus("s_rdata", lo, n, 32, hexw(8))),
      ("s0_response",     "bus", bus("s_resp", lo, n, 2, lambda v: RESP.get(v, v))),
      ("irq",             "bit", bits("irq", lo, n)),
      ], n,
     ["A 4-beat read burst into a write-only window. m0_read never asserts - the "
      "protected peripheral is not touched at all.",
      "The command is ACCEPTED immediately (waitrequest stays low) rather than stalled: "
      "stalling it would move the hang from the peripheral into the firewall.",
      "Avalon-MM has no way to refuse, so the core owes the master four beats and "
      "synthesises them itself. rd_deny_beats is that debt counting down. "
      "Data is driven to zero, not left stale."])

# -------------------------------------------------------- Figure: timeout
lo, n = marker_cycle(3) + 1, 20
draw(f"{OUT}/fig_timeout.svg",
     [("clk", "clk", []),
      ("s0_read",         "bit", bits("s_read", lo, n)),
      ("s0_waitrequest",  "bit", bits("s_wait", lo, n)),
      ("m0_read",         "bit", bits("m_read", lo, n)),
      ("m0_waitrequest",  "bit", bits("m_wait", lo, n)),
      ("downstream_broken", "bit", bits("dut.downstream_broken", lo, n)),
      ("rd_stuck",        "bit", bits("dut.rd_stuck", lo, n)),
      ("rd_deny_beats",   "bus", bus("dut.rd_deny_beats", lo, n, 16)),
      ("s0_readdatavalid", "bit", bits("s_rdv", lo, n)),
      ("s0_response",     "bus", bus("s_resp", lo, n, 2, lambda v: RESP.get(v, v))),
      ("irq",             "bit", bits("irq", lo, n)),
      ], n,
     ["The peripheral holds m0_waitrequest high forever. TIMEOUT_VALUE is 10 cycles "
      "in this capture; a real system uses thousands.",
      "On expiry the core completes the transaction upstream itself - four SLAVEERROR "
      "beats - so the master never hangs, and latches downstream_broken.",
      "m0_read STAYS ASSERTED. Avalon-MM forbids withdrawing a command before "
      "waitrequest falls; rd_stuck records that the core is holding one. Only "
      "RECOVERY.UNBLOCK may drop it."])

# ------------------------------------------------------- Figure: recovery
lo, n = marker_cycle(4) + 1, 34
draw(f"{OUT}/fig_recovery.svg",
     [("clk", "clk", []),
      ("downstream_broken", "bit", bits("dut.downstream_broken", lo, n)),
      ("rd_stuck",        "bit", bits("dut.rd_stuck", lo, n)),
      ("m0_read",         "bit", bits("m_read", lo, n)),
      ("periph reset (yours)", "bit", bits("periph_rst_n", lo, n)),
      ("csr_write",       "bit", bits("c_write", lo, n)),
      ("csr_address",     "bus", bus("c_addr", lo, n, 8, lambda v: f"0x{v:02X}")),
      ("unblock",         "bit", bits("dut.unblock", lo, n)),
      ("irq",             "bit", bits("irq", lo, n)),
      ("m0_write",        "bit", bits("m_write", lo, n)),
      ], n,
     ["Word 0x01 (byte 0x04) acknowledges the fault and irq drops. The peripheral "
      "reset is driven by the system, not by the core.",
      "Word 0x07 (byte 0x1C) pulses unblock WHILE THE PERIPHERAL IS STILL IN RESET. "
      "downstream_broken and rd_stuck clear together, and the held m0_read is "
      "withdrawn where the peripheral cannot observe it.",
      "Doing this after releasing the reset would let the peripheral handshake the "
      "held command first - latching a transaction already reported as failed.",
      "The write burst at the end shows forwarding has reopened."])

print("figures written to", OUT)
