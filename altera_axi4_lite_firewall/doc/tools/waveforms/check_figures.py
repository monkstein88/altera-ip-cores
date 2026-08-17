#!/usr/bin/env python3
"""
Verify that every timing figure still matches the simulation it came from.

A figure that has silently drifted from the RTL is worse than no figure, and
"it looks right" does not scale to four diagrams and forty-odd signals. This
reads each SVG back, recovers the logic level the renderer drew in each cycle
from the path geometry, and compares it against the same sample taken straight
from the VCD.

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

VCD = sys.argv[1] if len(sys.argv) > 1 else "wave.vcd"
FIGS = sys.argv[2] if len(sys.argv) > 2 else os.path.join(DOC, "figures")

# figure -> (marker, cycles, [(row label, VCD signal)])
# Only single-bit rows are checked; bus rows are verified by their text, which
# is compared separately below.
CASES = {
    "fig_write_ok.svg": (1, 12, [
        ("s_axi_awvalid", "wave_capture_tb.s_awvalid"),
        ("s_axi_awready", "wave_capture_tb.s_awready"),
        ("s_axi_wvalid",  "wave_capture_tb.s_wvalid"),
        ("s_axi_wready",  "wave_capture_tb.s_wready"),
        ("m_axi_awvalid", "wave_capture_tb.m_awvalid"),
        ("m_axi_awready", "wave_capture_tb.m_awready"),
        ("m_axi_bvalid",  "wave_capture_tb.m_bvalid"),
        ("s_axi_bvalid",  "wave_capture_tb.s_bvalid"),
    ]),
    "fig_read_denied.svg": (2, 12, [
        ("s_axi_arvalid", "wave_capture_tb.s_arvalid"),
        ("s_axi_arready", "wave_capture_tb.s_arready"),
        ("m_axi_arvalid", "wave_capture_tb.m_arvalid"),
        ("s_axi_rvalid",  "wave_capture_tb.s_rvalid"),
        ("irq",           "wave_capture_tb.irq"),
    ]),
    "fig_timeout.svg": (3, 22, [
        ("s_axi_awvalid",     "wave_capture_tb.s_awvalid"),
        ("s_axi_awready",     "wave_capture_tb.s_awready"),
        ("m_axi_awvalid",     "wave_capture_tb.m_awvalid"),
        ("m_axi_awready",     "wave_capture_tb.m_awready"),
        ("s_axi_bvalid",      "wave_capture_tb.s_bvalid"),
        ("downstream_broken", "wave_capture_tb.dut.downstream_broken"),
        ("irq",               "wave_capture_tb.irq"),
    ]),
    "fig_recovery.svg": (4, 34, [
        ("downstream_broken",  "wave_capture_tb.dut.downstream_broken"),
        ("m_axi_awvalid",      "wave_capture_tb.m_awvalid"),
        ("periph_rst (yours)", "wave_capture_tb.periph_rst"),
        ("s_axi_ctrl_awvalid", "wave_capture_tb.c_awvalid"),
        ("unblock",            "wave_capture_tb.dut.unblock"),
        ("irq",                "wave_capture_tb.irq"),
        ("s_axi_bvalid",       "wave_capture_tb.s_bvalid"),
    ]),
}

ALL = sorted({sig for _, _, rows in CASES.values() for _, sig in rows} |
             {"wave_capture_tb.marker"})


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

    Bit rows are one <path> of horizontal segments at either the high or the
    low y for that row. Find the path whose points all sit on those two
    levels, then sample it at each cycle's mid-x.
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
        print(f"  SKIPPED: {VCD} not present. Regenerate it as described in\n"
              f"           mkwaves.py, then re-run this check.")
        return 0
    v = Vcd(VCD)
    s = v.sample(ALL, 5000, 1436000, 10000)
    marker = [val(d.get("wave_capture_tb.marker"), 32) for _, d in s]

    checked = mismatched = 0
    problems = []

    for fname, (mk, ncycles, rows) in CASES.items():
        path = os.path.join(FIGS, fname)
        if not os.path.exists(path):
            problems.append(f"{fname}: missing")
            continue
        svg = open(path, encoding="utf-8").read()
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
                want = val(s[lo + c][1].get(sig), 1)
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
