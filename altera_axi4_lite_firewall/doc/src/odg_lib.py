#!/usr/bin/env python3
"""
Minimal OpenDocument Graphics (.odg) writer.

Hand-rolls the XML rather than using odfpy, because we need precise control
over stroke/fill styles, text alignment inside shapes, dash patterns and
arrow markers - and odfpy's draw support makes several of those awkward.

Everything is emitted in centimetres. A4 landscape = 29.7 x 21.0 cm.
"""

import re
import zipfile
from xml.sax.saxutils import escape


def xtext(s):
    """Escape, and preserve runs of spaces.

    XML collapses consecutive whitespace, so "col      value" renders as
    "col value" and every hand-aligned monospace column in the document
    silently loses its alignment. ODF's answer is <text:s text:c="n"/>.
    """
    s = escape(s)
    return re.sub(r"  +",
                  lambda m: " " + f'<text:s text:c="{len(m.group()) - 1}"/>',
                  s)

NS = (
    'xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0" '
    'xmlns:style="urn:oasis:names:tc:opendocument:xmlns:style:1.0" '
    'xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0" '
    'xmlns:draw="urn:oasis:names:tc:opendocument:xmlns:drawing:1.0" '
    'xmlns:fo="urn:oasis:names:tc:opendocument:xmlns:xsl-fo-compatible:1.0" '
    'xmlns:svg="urn:oasis:names:tc:opendocument:xmlns:svg-compatible:1.0" '
    'xmlns:table="urn:oasis:names:tc:opendocument:xmlns:table:1.0" '
    'xmlns:meta="urn:oasis:names:tc:opendocument:xmlns:meta:1.0" '
    'xmlns:dc="http://purl.org/dc/elements/1.1/" '
    'xmlns:presentation="urn:oasis:names:tc:opendocument:xmlns:presentation:1.0"'
)

PAGE_W, PAGE_H = 29.7, 21.0


def cm(v):
    return f"{v:.3f}cm"


class Odg:
    def __init__(self, title="Drawing"):
        self.title = title
        self.pages = []          # list of (name, [xml fragments])
        self.gstyles = {}        # graphic styles
        self.pstyles = {}        # paragraph styles
        self.tstyles = {}        # text (span) styles
        self._uid = 0

    def uid(self, p="a"):
        self._uid += 1
        return f"{p}{self._uid}"

    # ---------------- style registration ----------------
    def gstyle(self, name, **kw):
        """Graphic style. kw keys map to draw:/svg:/fo: attributes."""
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
        return len(self.pages) - 1

    def add(self, frag, page=-1):
        self.pages[page][1].append(frag)

    # ---------------- primitives ----------------
    def rect(self, x, y, w, h, style, text=None, tstyle=None, pstyle="pC",
             page=-1, corner=None):
        rx = f' draw:corner-radius="{cm(corner)}"' if corner else ""
        body = self._text_body(text, tstyle, pstyle)
        self.add(
            f'<draw:rect draw:style-name="{style}" draw:text-style-name="{pstyle}" '
            f'svg:x="{cm(x)}" svg:y="{cm(y)}" svg:width="{cm(w)}" '
            f'svg:height="{cm(h)}"{rx}>{body}</draw:rect>', page)

    def ellipse(self, x, y, w, h, style, text=None, tstyle=None, pstyle="pC", page=-1):
        body = self._text_body(text, tstyle, pstyle)
        self.add(
            f'<draw:ellipse draw:style-name="{style}" draw:text-style-name="{pstyle}" '
            f'svg:x="{cm(x)}" svg:y="{cm(y)}" svg:width="{cm(w)}" '
            f'svg:height="{cm(h)}">{body}</draw:ellipse>', page)

    def line(self, x1, y1, x2, y2, style, page=-1):
        self.add(
            f'<draw:line draw:style-name="{style}" svg:x1="{cm(x1)}" svg:y1="{cm(y1)}" '
            f'svg:x2="{cm(x2)}" svg:y2="{cm(y2)}"/>', page)

    def polyline(self, pts, style, page=-1):
        xs = [p[0] for p in pts]
        ys = [p[1] for p in pts]
        x0, y0 = min(xs), min(ys)
        w, h = max(max(xs) - x0, 0.001), max(max(ys) - y0, 0.001)
        # viewBox in 1/100 mm
        vb = f"0 0 {int(w*1000)} {int(h*1000)}"
        pl = " ".join(f"{int((px-x0)*1000)},{int((py-y0)*1000)}" for px, py in pts)
        self.add(
            f'<draw:polyline draw:style-name="{style}" svg:x="{cm(x0)}" svg:y="{cm(y0)}" '
            f'svg:width="{cm(w)}" svg:height="{cm(h)}" svg:viewBox="{vb}" '
            f'draw:points="{pl}"/>', page)

    def text(self, x, y, w, h, lines, tstyle="tBody", pstyle="pL", style="gInvis",
             page=-1):
        """lines: str, or list of str, or list of (text, tstyle) tuples."""
        if isinstance(lines, str):
            lines = [lines]
        paras = []
        for ln in lines:
            if isinstance(ln, tuple):
                txt, ts = ln
            else:
                txt, ts = ln, tstyle
            if txt == "":
                paras.append(f'<text:p text:style-name="{pstyle}"/>')
            else:
                paras.append(
                    f'<text:p text:style-name="{pstyle}">'
                    f'<text:span text:style-name="{ts}">{xtext(txt)}</text:span>'
                    f'</text:p>')
        self.add(
            f'<draw:frame draw:style-name="{style}" draw:text-style-name="{pstyle}" '
            f'svg:x="{cm(x)}" svg:y="{cm(y)}" svg:width="{cm(w)}" svg:height="{cm(h)}">'
            f'<draw:text-box>{"".join(paras)}</draw:text-box></draw:frame>', page)

    def _text_body(self, text, tstyle, pstyle):
        if text is None:
            return ""
        lines = text if isinstance(text, list) else [text]
        out = []
        for ln in lines:
            if isinstance(ln, tuple):
                txt, ts = ln
            else:
                txt, ts = ln, (tstyle or "tBody")
            if txt == "":
                out.append(f'<text:p text:style-name="{pstyle}"/>')
            else:
                out.append(f'<text:p text:style-name="{pstyle}">'
                           f'<text:span text:style-name="{ts}">{xtext(txt)}</text:span>'
                           f'</text:p>')
        return "".join(out)

    # ---------------- style XML ----------------
    def _styles_xml(self):
        out = []
        for name, kw in self.gstyles.items():
            props = []
            for k, v in kw.items():
                props.append(f'{k}="{v}"')
            out.append(
                f'<style:style style:name="{name}" style:family="graphic">'
                f'<style:graphic-properties {" ".join(props)}/></style:style>')
        for name, (align, mt, mb) in self.pstyles.items():
            out.append(
                f'<style:style style:name="{name}" style:family="paragraph">'
                f'<style:paragraph-properties fo:text-align="{align}" '
                f'fo:margin-top="{cm(mt)}" fo:margin-bottom="{cm(mb)}"/>'
                f'</style:style>')
        for name, (size, bold, italic, family, color) in self.tstyles.items():
            w = 'fo:font-weight="bold" style:font-weight-asian="bold"' if bold else ""
            i = 'fo:font-style="italic"' if italic else ""
            out.append(
                f'<style:style style:name="{name}" style:family="text">'
                f'<style:text-properties fo:font-family="{family}" '
                f'style:font-name="{family}" fo:font-size="{size}pt" '
                f'fo:color="{color}" {w} {i}/></style:style>')
        return "".join(out)

    def save(self, path):
        content = (
            f'<?xml version="1.0" encoding="UTF-8"?>\n'
            f'<office:document-content {NS} office:version="1.3">'
            f'<office:automatic-styles>{self._styles_xml()}'
            f'<style:style style:name="dp1" style:family="drawing-page"/>'
            f'</office:automatic-styles>'
            f'<office:body><office:drawing>'
        )
        for i, (name, frags) in enumerate(self.pages):
            content += (
                f'<draw:page draw:name="{escape(name)}" draw:style-name="dp1" '
                f'draw:master-page-name="Default">{"".join(frags)}</draw:page>')
        content += '</office:drawing></office:body></office:document-content>'

        # NOTE: the master page's draw:style-name must resolve to a
        # drawing-page style defined *in this file*. Pointing it at the dp1
        # declared in content.xml leaves a dangling reference, and LibreOffice
        # silently falls back to its default A4 *portrait* page - the drawing
        # still renders, just on the wrong page size, which is easy to miss.
        styles = (
            f'<?xml version="1.0" encoding="UTF-8"?>\n'
            f'<office:document-styles {NS} office:version="1.3">'
            f'<office:styles/>'
            f'<office:automatic-styles>'
            f'<style:page-layout style:name="PM1">'
            f'<style:page-layout-properties fo:page-width="{cm(PAGE_W)}" '
            f'fo:page-height="{cm(PAGE_H)}" style:print-orientation="landscape" '
            f'fo:margin-top="0cm" fo:margin-bottom="0cm" fo:margin-left="0cm" '
            f'fo:margin-right="0cm"/></style:page-layout>'
            f'<style:style style:name="dpMaster" style:family="drawing-page">'
            f'<style:drawing-page-properties draw:background-size="full"/>'
            f'</style:style>'
            f'</office:automatic-styles>'
            f'<office:master-styles>'
            f'<style:master-page style:name="Default" style:page-layout-name="PM1" '
            f'draw:style-name="dpMaster"/>'
            f'</office:master-styles></office:document-styles>'
        )

        meta = (
            f'<?xml version="1.0" encoding="UTF-8"?>\n'
            f'<office:document-meta {NS} office:version="1.3">'
            f'<office:meta><dc:title>{escape(self.title)}</dc:title>'
            f'<meta:generator>odg_lib.py</meta:generator></office:meta>'
            f'</office:document-meta>'
        )

        manifest = (
            '<?xml version="1.0" encoding="UTF-8"?>\n'
            '<manifest:manifest '
            'xmlns:manifest="urn:oasis:names:tc:opendocument:xmlns:manifest:1.0" '
            'manifest:version="1.3">'
            '<manifest:file-entry manifest:full-path="/" '
            'manifest:media-type="application/vnd.oasis.opendocument.graphics"/>'
            '<manifest:file-entry manifest:full-path="content.xml" '
            'manifest:media-type="text/xml"/>'
            '<manifest:file-entry manifest:full-path="styles.xml" '
            'manifest:media-type="text/xml"/>'
            '<manifest:file-entry manifest:full-path="meta.xml" '
            'manifest:media-type="text/xml"/>'
            '</manifest:manifest>'
        )

        with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as z:
            # mimetype must be first and stored uncompressed
            zi = zipfile.ZipInfo("mimetype")
            zi.compress_type = zipfile.ZIP_STORED
            z.writestr(zi, "application/vnd.oasis.opendocument.graphics")
            z.writestr("META-INF/manifest.xml", manifest)
            z.writestr("content.xml", content)
            z.writestr("styles.xml", styles)
            z.writestr("meta.xml", meta)
