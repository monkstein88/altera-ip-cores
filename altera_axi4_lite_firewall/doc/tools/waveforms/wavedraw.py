#!/usr/bin/env python3
"""
Render timing diagrams as SVG directly from a VCD.

The figures in the user manual are produced from an actual simulation rather
than drawn by hand, so they cannot drift from the RTL: if the design changes,
regenerating the figure shows the new behaviour or the scenario stops
matching. Values are sampled at each rising clock edge, which is what a
reader of an AXI waveform expects to see.
"""

import re
from xml.sax.saxutils import escape

# ---------------------------------------------------------------- VCD parsing


class Vcd:
    def __init__(self, path):
        txt = open(path).read().split("\n")
        self.ids = {}          # id -> list of hierarchical names
        self.widths = {}       # id -> width
        scope, start = [], None
        for i, line in enumerate(txt):
            s = line.strip()
            if s.startswith("$scope"):
                scope.append(s.split()[2])
            elif s.startswith("$upscope"):
                scope.pop()
            elif s.startswith("$var"):
                p = s.split()
                sid, name = p[3], p[4]
                self.ids.setdefault(sid, []).append(".".join(scope + [name]))
                self.widths[sid] = int(p[2])
            elif s.startswith("$enddefinitions"):
                start = i
                break
        self.by_name = {}
        for sid, names in self.ids.items():
            for n in names:
                self.by_name[n] = sid
                # Verilator wraps the design in a synthetic "TOP" scope, and
                # whether it appears in the VCD depends on the version. Register
                # the stripped spelling too, so a trace from either one resolves
                # the same signal names and the figures do not silently come out
                # blank on a different Verilator.
                if n.startswith("TOP."):
                    self.by_name.setdefault(n[len("TOP."):], sid)

        # value-change stream: time -> {id: value}
        self.times = []
        self.changes = []
        cur, t = {}, 0
        for line in txt[start + 1:]:
            if not line:
                continue
            if line[0] == "#":
                if cur:
                    self.times.append(t)
                    self.changes.append(cur)
                    cur = {}
                t = int(line[1:])
            elif line[0] in "01xzXZ":
                cur[line[1:]] = line[0]
            elif line[0] in "bB":
                v, sid = line[1:].split(" ", 1)
                cur[sid.strip()] = v
        if cur:
            self.times.append(t)
            self.changes.append(cur)

    def sample(self, names, t_from, t_to, step):
        """Return [(t, {name: value})] sampled every `step` from t_from."""
        sids = {n: self.by_name[n] for n in names if n in self.by_name}
        state, out, idx = {}, [], 0
        for t in range(0, t_to + step, step):
            while idx < len(self.times) and self.times[idx] <= t:
                state.update(self.changes[idx])
                idx += 1
            if t >= t_from:
                out.append((t, {n: state.get(s, "x") for n, s in sids.items()}))
        return out


def val(raw, width):
    if raw in ("x", "z", "X", "Z") or raw is None:
        return None
    if width == 1:
        return int(raw, 2) if raw in "01" else None
    try:
        return int(raw, 2)
    except ValueError:
        return None


# ---------------------------------------------------------------- SVG drawing

INK, GRID, BUS, HL = "#1F3864", "#C9D3E4", "#DCE6F1", "#C00000"
ROW, LEFT, CW = 30, 210, 34          # row pitch, label column, cycle width
# No title inside the figure: the document numbers and captions it, and two
# titles for one object is one too many. TOP now only clears the cycle ruler.
TOP, PAD = 22, 10


def draw(path, rows, ncycles, notes=None, highlight=None):
    """rows: list of (label, kind, [values]) - kind 'clk' | 'bit' | 'bus'."""
    w = LEFT + ncycles * CW + 150
    # Bottom padding = the note block (first baseline at +20, 16 px pitch)
    # plus one descender. Anything more shows up as a gap between the figure
    # and its caption once the SVG is placed in the document.
    h = TOP + len(rows) * ROW + 26 + (16 * len(notes or []))
    o = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{w}" height="{h}" '
         f'viewBox="0 0 {w} {h}" font-family="Liberation Sans, DejaVu Sans, sans-serif">',
         f'<rect width="{w}" height="{h}" fill="white"/>']

    # Alternating row bands. Without them a signal's low level sits at the
    # same height as the next row's label and the eye cannot tell which
    # waveform belongs to which name.
    for r in range(len(rows)):
        if r % 2:
            o.append(f'<rect x="{LEFT}" y="{TOP + r*ROW}" width="{ncycles*CW}" '
                     f'height="{ROW}" fill="#F4F7FB"/>')

    # cycle grid + numbers
    for c in range(ncycles + 1):
        x = LEFT + c * CW
        o.append(f'<line x1="{x}" y1="{TOP-6}" x2="{x}" y2="{TOP+len(rows)*ROW}" '
                 f'stroke="{GRID}" stroke-width="1"/>')
        if c < ncycles:
            o.append(f'<text x="{x+CW/2}" y="{TOP-10}" font-size="9" fill="#808080" '
                     f'text-anchor="middle">{c}</text>')

    if highlight:
        for c0, c1, colour in highlight:
            x0, x1 = LEFT + c0 * CW, LEFT + c1 * CW
            o.append(f'<rect x="{x0}" y="{TOP-6}" width="{x1-x0}" '
                     f'height="{len(rows)*ROW+6}" fill="{colour}" opacity="0.18"/>')

    for r, (label, kind, vals) in enumerate(rows):
        y = TOP + r * ROW
        yh, yl = y + 5, y + ROW - 8         # high / low levels
        o.append(f'<text x="{LEFT-8}" y="{y+ROW/2+4}" font-size="10.5" '
                 f'text-anchor="end" fill="#000">{escape(label)}</text>')
        if kind == "clk":
            d = []
            for c in range(ncycles):
                x = LEFT + c * CW
                d.append(f"M{x},{yl} L{x},{yh} L{x+CW/2},{yh} L{x+CW/2},{yl} L{x+CW},{yl}")
            o.append(f'<path d="{" ".join(d)}" fill="none" stroke="{INK}" stroke-width="1.6"/>')
            continue
        if kind == "bit":
            pts, prev = [], None
            for c in range(ncycles):
                x = LEFT + c * CW
                v = vals[c] if c < len(vals) else None
                lvl = yh if v == 1 else yl
                if v is None:
                    prev = None
                    o.append(f'<rect x="{x}" y="{yh}" width="{CW}" height="{yl-yh}" '
                             f'fill="#eeeeee" stroke="#cccccc"/>')
                    continue
                if prev is not None and prev != lvl:
                    pts.append(f"L{x},{lvl}")
                elif prev is None:
                    pts.append(f"M{x},{lvl}")
                pts.append(f"L{x+CW},{lvl}")
                prev = lvl
            o.append(f'<path d="{" ".join(pts)}" fill="none" stroke="{INK}" stroke-width="1.6"/>')
            continue
        # bus
        c = 0
        while c < ncycles:
            v = vals[c] if c < len(vals) else None
            c2 = c
            while c2 + 1 < ncycles and (vals[c2+1] if c2+1 < len(vals) else None) == v:
                c2 += 1
            x0, x1 = LEFT + c * CW, LEFT + (c2 + 1) * CW
            m = 4
            if v is None:
                o.append(f'<rect x="{x0}" y="{yh}" width="{x1-x0}" height="{yl-yh}" '
                         f'fill="#eeeeee" stroke="#cccccc"/>')
            else:
                o.append(f'<path d="M{x0},{(yh+yl)/2} L{x0+m},{yh} L{x1-m},{yh} '
                         f'L{x1},{(yh+yl)/2} L{x1-m},{yl} L{x0+m},{yl} Z" '
                         f'fill="{BUS}" stroke="{INK}" stroke-width="1.2"/>')
                o.append(f'<text x="{(x0+x1)/2}" y="{(yh+yl)/2+4}" font-size="9.5" '
                         f'text-anchor="middle" font-family="Liberation Mono, monospace">'
                         f'{escape(str(v))}</text>')
            c = c2 + 1

    ny = TOP + len(rows) * ROW + 20
    for n in (notes or []):
        o.append(f'<text x="{PAD}" y="{ny}" font-size="10" fill="#404040">{escape(n)}</text>')
        ny += 16
    o.append("</svg>")
    open(path, "w").write("\n".join(o))
    return path
