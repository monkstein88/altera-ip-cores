#!/usr/bin/env python3
"""
Minimal SVG canvas writer, drop-in replacement for the old odg_lib.

Why SVG rather than ODF: an .odg is a zip of XML, so `git diff` reports
"Bin 16524 -> 16538 bytes", you cannot grep it for a stale claim, and you
cannot mechanically verify what it says. That is not hypothetical - the
block-diagram document sat at "v1.2 / 0x0102 / 80 tests" long after the core
reached v2.0, and nothing could have caught it. SVG is text: it diffs, it
greps, it renders in a browser and on GitHub, and a checker can parse it.

The API mirrors odg_lib deliberately, so the drawing code ports across
unchanged: same cm coordinate system, same gstyle/pstyle/tstyle registration,
same rect/ellipse/line/polyline/text primitives.

The one thing ODF did for free and SVG does not is text layout. SVG has no
auto-wrap and no vertical alignment inside a shape, so this module measures
text with the real font via PIL and lays it out itself.
"""

import os
import re
from xml.sax.saxutils import escape

PAGE_W, PAGE_H = 29.7, 21.0          # A4 landscape, cm
PX = 37.7952755                       # px per cm at 96 dpi
PT = 96.0 / 72.0                      # px per pt

FONT_DIRS = ["/usr/share/fonts/truetype/liberation",
             "/usr/share/fonts/truetype/liberation2",
             "/usr/share/fonts/TTF", "/Library/Fonts",
             "C:/Windows/Fonts"]
FONT_FILES = {
    ("Liberation Sans", False, False): "LiberationSans-Regular.ttf",
    ("Liberation Sans", True,  False): "LiberationSans-Bold.ttf",
    ("Liberation Sans", False, True):  "LiberationSans-Italic.ttf",
    ("Liberation Sans", True,  True):  "LiberationSans-BoldItalic.ttf",
    ("Liberation Mono", False, False): "LiberationMono-Regular.ttf",
    ("Liberation Mono", True,  False): "LiberationMono-Bold.ttf",
    ("Liberation Mono", False, True):  "LiberationMono-Italic.ttf",
    ("Liberation Mono", True,  True):  "LiberationMono-BoldItalic.ttf",
}

_font_cache = {}


def _font(family, bold, italic, size_px):
    """Load the real TTF so wrapping matches what actually renders.

    Falls back to a per-character estimate if PIL or the fonts are missing;
    the drawing still comes out, lines just wrap slightly differently.
    """
    key = (family, bold, italic, round(size_px, 2))
    if key in _font_cache:
        return _font_cache[key]
    fnt = None
    name = FONT_FILES.get((family, bold, italic))
    if name:
        try:
            from PIL import ImageFont
            for d in FONT_DIRS:
                p = os.path.join(d, name)
                if os.path.exists(p):
                    fnt = ImageFont.truetype(p, max(1, int(round(size_px * 4))))
                    break
        except ImportError:
            fnt = None
    _font_cache[key] = fnt
    return fnt


def text_width(s, family, bold, italic, size_px):
    f = _font(family, bold, italic, size_px)
    if f is not None:
        return f.getlength(s) / 4.0
    # Rough fallback: monospace is a fixed 0.6 em, proportional averages 0.52.
    per = 0.60 if family.endswith("Mono") else 0.52
    return len(s) * per * size_px * (1.05 if bold else 1.0)


class Svg:
    """A multi-page SVG canvas. Each page is saved as its own .svg file."""

    def __init__(self, title="Drawing"):
        self.title = title
        self.pages = []              # (name, [fragments])
        self.bounds = []             # per page: [x0, y0, x1, y1] in px
        self.gstyles = {}
        self.pstyles = {}
        self.tstyles = {}
        self._markers = set()

    # ---------------- style registration (same shape as odg_lib) ----------
    def gstyle(self, name, **kw):
        self.gstyles[name] = kw
        return name

    def pstyle(self, name, align="center", margin_top=0.0, margin_bottom=0.0):
        self.pstyles[name] = (align, margin_top, margin_bottom)
        return name

    def tstyle(self, name, size=10, bold=False, italic=False,
               family="Liberation Sans", color="#000000"):
        self.tstyles[name] = (size, bold, italic, family, color)
        return name

    # ---------------- page ----------------
    def page(self, name):
        self.pages.append((name, []))
        self.bounds.append(None)
        return len(self.pages) - 1

    def add(self, frag, page=-1):
        self.pages[page][1].append(frag)

    def grow(self, x0, y0, x1, y1, page=-1):
        """Extend the page's content bounds, in px.

        Tracked so each figure can be cropped to what was actually drawn. The
        drawing code inherits an A4-landscape coordinate system from the days
        when every diagram was a printed page; a figure embedded in a document
        should not carry that page's empty margins with it.
        """
        b = self.bounds[page]
        if b is None:
            self.bounds[page] = [x0, y0, x1, y1]
        else:
            b[0], b[1] = min(b[0], x0), min(b[1], y0)
            b[2], b[3] = max(b[2], x1), max(b[3], y1)

    # ---------------- style translation ----------------
    def _shape_attrs(self, style):
        """Translate a registered graphic style into SVG paint attributes."""
        kw = self.gstyles.get(style, {})
        fill = "none"
        if kw.get("draw:fill") == "solid":
            fill = kw.get("draw:fill-color", "#FFFFFF")
        stroke = kw.get("svg:stroke-color", "#000000")
        if kw.get("draw:stroke", "solid") == "none":
            stroke, sw = "none", 0.0
        else:
            sw = float(kw.get("svg:stroke-width", "0.05cm").rstrip("cm")) * PX
        a = f'fill="{fill}" stroke="{stroke}"'
        if stroke != "none":
            a += f' stroke-width="{sw:.2f}"'
            if kw.get("draw:stroke") == "dash":
                a += f' stroke-dasharray="{sw*3:.1f},{sw*2:.1f}"'
        return a

    def _valign(self, style):
        return self.gstyles.get(style, {}).get(
            "draw:textarea-vertical-align", "middle")

    def _pad(self, style):
        kw = self.gstyles.get(style, {})
        def g(k, dflt):
            return float(kw.get(k, dflt).rstrip("cm")) * PX
        return g("fo:padding-left", "0.15cm"), g("fo:padding-top", "0.1cm")

    def _line_attrs(self, style):
        """Arrow/line styles carry stroke plus optional end markers."""
        kw = self.gstyles.get(style, {})
        col = kw.get("svg:stroke-color", "#000000")
        sw = float(kw.get("svg:stroke-width", "0.05cm").rstrip("cm")) * PX
        a = f'fill="none" stroke="{col}" stroke-width="{sw:.2f}" ' \
            f'stroke-linejoin="round" stroke-linecap="butt"'
        if kw.get("draw:stroke") == "dash":
            a += f' stroke-dasharray="{sw*3:.1f},{sw*2:.1f}"'
        if "draw:marker-end" in kw:
            mid = self._marker(col)
            a += f' marker-end="url(#{mid})"'
        if "draw:marker-start" in kw:
            mid = self._marker(col)
            a += f' marker-start="url(#{mid}s)"'
        return a

    def _marker(self, colour):
        self._markers.add(colour)
        return "arw" + colour.lstrip("#")

    def _marker_defs(self):
        out = []
        for c in sorted(self._markers):
            mid = "arw" + c.lstrip("#")
            # markerUnits="strokeWidth" would scale the head with the line, but
            # the drawing mixes 0.035 cm signal lines with 0.09 cm buses and the
            # heads then differ by 3x. A fixed head reads better.
            for suffix, path, ref in ((mid, "M0,0 L9,3.2 L0,6.4 Z", 8.6),
                                      (mid + "s", "M9,0 L0,3.2 L9,6.4 Z", 0.4)):
                out.append(
                    f'<marker id="{suffix}" markerUnits="userSpaceOnUse" '
                    f'markerWidth="9" markerHeight="6.4" refX="{ref}" refY="3.2" '
                    f'orient="auto"><path d="{path}" fill="{c}"/></marker>')
        return "".join(out)

    # ---------------- primitives ----------------
    def rect(self, x, y, w, h, style, text=None, tstyle=None, pstyle="pC",
             page=-1, corner=None):
        r = f' rx="{corner*PX:.2f}"' if corner else ""
        self.add(f'<rect x="{x*PX:.2f}" y="{y*PX:.2f}" width="{w*PX:.2f}" '
                 f'height="{h*PX:.2f}"{r} {self._shape_attrs(style)}/>', page)
        self.grow(x*PX, y*PX, (x+w)*PX, (y+h)*PX, page)
        if text is not None:
            self._layout(x, y, w, h, text, tstyle, pstyle,
                         self._valign(style), self._pad(style), page)

    def ellipse(self, x, y, w, h, style, text=None, tstyle=None, pstyle="pC",
                page=-1):
        self.add(f'<ellipse cx="{(x+w/2)*PX:.2f}" cy="{(y+h/2)*PX:.2f}" '
                 f'rx="{w/2*PX:.2f}" ry="{h/2*PX:.2f}" '
                 f'{self._shape_attrs(style)}/>', page)
        self.grow(x*PX, y*PX, (x+w)*PX, (y+h)*PX, page)
        if text is not None:
            self._layout(x, y, w, h, text, tstyle, pstyle, "middle",
                         self._pad(style), page)

    def line(self, x1, y1, x2, y2, style, page=-1):
        self.add(f'<line x1="{x1*PX:.2f}" y1="{y1*PX:.2f}" x2="{x2*PX:.2f}" '
                 f'y2="{y2*PX:.2f}" {self._line_attrs(style)}/>', page)
        self.grow(min(x1, x2)*PX, min(y1, y2)*PX,
                  max(x1, x2)*PX, max(y1, y2)*PX, page)

    def polyline(self, pts, style, page=-1):
        p = " ".join(f"{a*PX:.2f},{b*PX:.2f}" for a, b in pts)
        self.add(f'<polyline points="{p}" {self._line_attrs(style)}/>', page)
        xs = [a for a, _ in pts]; ys = [b for _, b in pts]
        self.grow(min(xs)*PX, min(ys)*PX, max(xs)*PX, max(ys)*PX, page)

    def text(self, x, y, w, h, lines, tstyle="tBody", pstyle="pL",
             style="gInvis", page=-1):
        """lines: str, or list of str, or list of (text, tstyle) tuples."""
        if self.gstyles.get(style, {}).get("draw:fill") == "solid":
            self.add(f'<rect x="{x*PX:.2f}" y="{y*PX:.2f}" width="{w*PX:.2f}" '
                     f'height="{h*PX:.2f}" {self._shape_attrs(style)}/>', page)
            self.grow(x*PX, y*PX, (x+w)*PX, (y+h)*PX, page)
        # A text frame with h=0 means "grow downwards", which ODF did
        # automatically; here it simply means do not vertically centre.
        self._layout(x, y, w, h, lines, tstyle, pstyle,
                     "top" if h <= 0.001 else "top", (0.0, 0.0), page)

    # ---------------- text layout ----------------
    def _layout(self, x, y, w, h, lines, tstyle, pstyle, valign, pad, page):
        if isinstance(lines, str):
            lines = [lines]
        align, _, mb = self.pstyles.get(pstyle, ("start", 0.0, 0.0))
        padx, pady = pad
        avail = w * PX - 2 * padx

        # 1. wrap every paragraph to the available width
        rows = []           # (text, size_px, bold, italic, family, colour, is_last_of_para)
        for ln in lines:
            txt, ts = ln if isinstance(ln, tuple) else (ln, tstyle or "tBody")
            size, bold, italic, family, colour = self.tstyles.get(
                ts, (10, False, False, "Liberation Sans", "#000000"))
            spx = size * PT
            if txt == "":
                rows.append(("", spx, bold, italic, family, colour, True))
                continue
            for i, piece in enumerate(_wrap(txt, avail, family, bold, italic, spx)):
                rows.append((piece, spx, bold, italic, family, colour, False))
            rows[-1] = rows[-1][:6] + (True,)

        if not rows:
            return

        # 2. vertical placement
        lh = [r[1] * 1.30 for r in rows]
        gaps = [mb * PX if rows[i][6] and i < len(rows) - 1 else 0.0
                for i in range(len(rows))]
        total = sum(lh) + sum(gaps)
        if valign == "middle":
            cur = y * PX + (h * PX - total) / 2.0
        elif valign == "bottom":
            cur = y * PX + h * PX - pady - total
        else:
            cur = y * PX + pady

        # 3. emit
        for i, (txt, spx, bold, italic, family, colour, last) in enumerate(rows):
            base = cur + spx * 1.30 * 0.78      # baseline within the line box
            if txt:
                if align == "center":
                    ax, anchor = (x + w / 2) * PX, "middle"
                elif align == "end":
                    ax, anchor = x * PX + w * PX - padx, "end"
                else:
                    ax, anchor = x * PX + padx, "start"
                wt = ' font-weight="bold"' if bold else ""
                it = ' font-style="italic"' if italic else ""
                self.add(
                    f'<text x="{ax:.2f}" y="{base:.2f}" text-anchor="{anchor}" '
                    f'font-family="{family}, sans-serif" font-size="{spx:.2f}"'
                    f'{wt}{it} fill="{colour}" '
                    f'xml:space="preserve">{escape(txt)}</text>', page)
                tw = text_width(txt, family, bold, italic, spx)
                left = ax - (tw / 2 if anchor == "middle" else
                             tw if anchor == "end" else 0)
                self.grow(left, cur, left + tw, cur + lh[i], page)
            cur += lh[i] + gaps[i]

    # ---------------- output ----------------
    def save(self, outdir, names, margin=0.35):
        """Write one SVG per page, cropped to what was drawn.

        names maps page index -> filename stem; margin is in cm.
        """
        os.makedirs(outdir, exist_ok=True)
        written = []
        for i, (pname, frags) in enumerate(self.pages):
            if i not in names:
                continue
            b = self.bounds[i] or [0, 0, PAGE_W * PX, PAGE_H * PX]
            m = margin * PX
            x0, y0 = b[0] - m, b[1] - m
            w, h = (b[2] - b[0]) + 2 * m, (b[3] - b[1]) + 2 * m
            path = os.path.join(outdir, names[i] + ".svg")
            with open(path, "w", encoding="utf-8") as f:
                f.write(
                    f'<svg xmlns="http://www.w3.org/2000/svg" '
                    f'width="{w:.1f}" height="{h:.1f}" '
                    f'viewBox="{x0:.1f} {y0:.1f} {w:.1f} {h:.1f}">\n'
                    f'<title>{escape(pname)}</title>\n'
                    f'<defs>{self._marker_defs()}</defs>\n'
                    f'<rect x="{x0:.1f}" y="{y0:.1f}" width="{w:.1f}" '
                    f'height="{h:.1f}" fill="#FFFFFF"/>\n'
                    f'{"".join(frags)}\n</svg>\n')
            written.append(path)
        return written


def _wrap(txt, avail_px, family, bold, italic, size_px):
    """Greedy word wrap using real font metrics.

    Runs of spaces are preserved: the document hand-aligns monospace columns
    with them, and collapsing whitespace silently destroys that alignment -
    the same trap ODF's <text:s> element existed to avoid.
    """
    if avail_px <= 0 or text_width(txt, family, bold, italic, size_px) <= avail_px:
        return [txt]
    words = re.split(r"(\s+)", txt)
    out, cur = [], ""
    for tok in words:
        trial = cur + tok
        if cur and text_width(trial.rstrip(), family, bold, italic,
                              size_px) > avail_px:
            out.append(cur.rstrip())
            cur = tok.lstrip() if tok.strip() == "" else tok
        else:
            cur = trial
    if cur.strip():
        out.append(cur.rstrip())
    return out or [txt]
