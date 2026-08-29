#!/usr/bin/env python3
"""
Verify that every timing figure still matches the simulation it came from.

Generating a figure from a VCD stops it being *drawn* wrong. It does not stop
it being *rendered* wrong, and it does not notice if someone edits the SVG by
hand. "It looks right" does not scale to four diagrams and forty-odd signals.

This reads each SVG back, recovers the logic level the renderer drew in every
cycle from the path geometry, and compares it against the same sample taken
straight from the VCD. That is the check the AXI4-Lite core has had since its
figures were generated; this core shipped without it.

Usage:  python3 check_figures.py [wave.vcd] [figures dir]
Exit:   0 if every sampled point matches, 1 otherwise.
"""

import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from wavedraw import Vcd, val, ROW, LEFT, CW, TOP   # noqa: E402

# Every tool under doc/tools resolves paths from its own location rather than
# the caller's cwd, so it works the same run from anywhere.
DOC = os.path.abspath(os.path.join(HERE, "..", ".."))

VCD = sys.argv[1] if len(sys.argv) > 1 else os.path.join(
    DOC, "..", "verification", "wave.vcd")
FIGS = sys.argv[2] if len(sys.argv) > 2 else os.path.join(DOC, "figures")

TB = "wave_capture_tb"

# figure -> (marker, cycles, [(row label as drawn, VCD signal below TB)])
#
# Only single-bit rows are checked. Bus rows carry formatted text rather than a
# two-level path, so their geometry says nothing; they are covered by the
# renderer's own formatting and by check_facts.py on the surrounding prose.
CASES = {
    "fig_burst_ok.svg": (1, 14, [
        ("s0_write",         "s_write"),
        ("s0_waitrequest",   "s_wait"),
        ("m0_write",         "m_write"),
        ("m0_waitrequest",   "m_wait"),
    ]),
    "fig_burst_denied.svg": (2, 14, [
        ("s0_read",          "s_read"),
        ("s0_waitrequest",   "s_wait"),
        ("m0_read",          "m_read"),
        ("s0_readdatavalid", "s_rdv"),
        ("irq",              "irq"),
    ]),
    "fig_timeout.svg": (3, 20, [
        ("s0_read",           "s_read"),
        ("s0_waitrequest",    "s_wait"),
        ("m0_read",           "m_read"),
        ("m0_waitrequest",    "m_wait"),
        ("downstream_broken", "dut.downstream_broken"),
        ("rd_stuck",          "dut.rd_stuck"),
        ("s0_readdatavalid",  "s_rdv"),
        ("irq",               "irq"),
    ]),
    "fig_recovery.svg": (4, 34, [
        ("downstream_broken",    "dut.downstream_broken"),
        ("rd_stuck",             "dut.rd_stuck"),
        ("m0_read",              "m_read"),
        ("periph reset (yours)", "periph_rst_n"),
        ("csr_write",            "c_write"),
        ("unblock",              "dut.unblock"),
        ("irq",                  "irq"),
        ("m0_write",             "m_write"),
    ]),
}

ALL = sorted({f"{TB}.{s}" for _, _, rows in CASES.values() for _, s in rows}
             | {f"{TB}.marker"})


def row_index(svg, label):
    """Recover which row a label was drawn on from its text baseline.

    The renderer places a label at y = TOP + r*ROW + ROW/2 + 4, so the row
    index falls straight out of the baseline. Matching on geometry rather than
    document order means a reordered row list cannot fool the check.
    """
    m = re.search(r'<text x="\d+" y="([\d.]+)"[^>]*text-anchor="end"[^>]*>'
                  + re.escape(label) + "</text>", svg)
    if not m:
        return None
    return round((float(m.group(1)) - 4 - ROW / 2 - TOP) / ROW)


def levels_from_path(svg, r, ncycles):
    """Read back the drawn level for each cycle of row r.

    A bit row is one <path> of horizontal segments at either the high or the
    low y for that row. Find the path whose points all sit on those two levels,
    then sample it at each cycle's mid-x.
    """
    y = TOP + r * ROW
    yh, yl = y + 5, y + ROW - 8
    for d in re.findall(r'<path d="([^"]+)" fill="none" stroke="#1F3864"', svg):
        pts = [(float(a), float(b))
               for a, b in re.findall(r"[ML]([\d.]+),([\d.]+)", d)]
        if not pts or not all(abs(py - yh) < .01 or abs(py - yl) < .01
                              for _, py in pts):
            continue
        out = []
        for c in range(ncycles):
            mid = LEFT + c * CW + CW / 2
            lvl = None
            for i in range(len(pts) - 1):
                (x0, y0), (x1, y1) = pts[i], pts[i + 1]
                if abs(y0 - y1) < .01 and x0 <= mid <= x1:
                    lvl = 1 if abs(y0 - yh) < .01 else 0
                    break
            out.append(lvl)
        return out
    return None


def main():
    if not os.path.exists(VCD):
        print(f"  SKIPPED: {VCD} not present. Run verification/capture.sh,\n"
              f"           then re-run this check.")
        return 0

    v = Vcd(VCD)
    # Same sampling the renderer uses: one point per clock, first edge at 5000.
    s = v.sample(ALL, 5000, 10_000_000, 10000)
    marker = [val(d.get(f"{TB}.marker"), 32) for _, d in s]

    checked = mismatched = 0
    problems = []

    for fname, (mk, ncycles, rows) in CASES.items():
        path = os.path.join(FIGS, fname)
        if not os.path.exists(path):
            problems.append(f"{fname}: missing")
            continue
        svg = open(path, encoding="utf-8").read()
        if mk not in marker:
            problems.append(f"{fname}: marker {mk} never set in the VCD")
            continue
        lo = marker.index(mk) + 1

        for label, sig in rows:
            r = row_index(svg, label)
            if r is None:
                problems.append(f"{fname}: no row labelled {label!r}")
                continue
            drawn = levels_from_path(svg, r, ncycles)
            if drawn is None:
                problems.append(f"{fname}/{label}: no waveform path found")
                continue
            for c in range(ncycles):
                want = val(s[lo + c][1].get(f"{TB}.{sig}"), 1)
                checked += 1
                if drawn[c] != want:
                    mismatched += 1
                    problems.append(
                        f"{fname}/{label} cycle {c}: figure={drawn[c]} vcd={want}")

    for p in problems[:25]:
        print("  " + p)
    print(f"\n{checked} sampled points checked, {mismatched} mismatched, "
          f"{len(problems)} problem(s)")
    ok = not problems
    print("figures match the simulation:", ok)
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
