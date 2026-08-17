#!/usr/bin/env python3
"""
Typeset the user guide: Markdown -> HTML -> PDF.

The PDF is the deliverable, but the Markdown is the source of truth. Nothing
in this script invents content - it only adds the page furniture an Intel user
guide has and Markdown does not: a title page, a table of contents with page
numbers, running headers and footers, numbered figure and table captions, and
Note / Caution callouts.

Layout is done with CSS paged media (WeasyPrint) rather than LaTeX so the
figure SVGs render with the same engine that produced them, and so the styling
is legible to anyone who wants to change it.

Usage:  python3 build_ug.py
Output: axi4_lite_firewall_user_guide.pdf   (beside this script)
"""

import html
import os
import re
import sys

import markdown
from weasyprint import HTML

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(HERE, "axi4_lite_firewall_user_guide.md")
OUT = os.path.join(HERE, "axi4_lite_firewall_user_guide.pdf")

TITLE = "AXI4-Lite Firewall IP Core"
SUBTITLE = "User Guide"
CORE_VER = "2.0"
DOC_VER = "1.0"
DOC_DATE = "August 2026"

# ---------------------------------------------------------------- preprocess


def split_front_matter(md):
    """Drop the Markdown title block and hand-written contents list.

    The PDF grows a real title page and an auto-numbered TOC, so keeping the
    Markdown ones would duplicate both. The Markdown keeps them because it is
    also read directly on GitHub, where there is no such machinery.
    """
    i = md.index("\n# 1. About")
    return md[i:]


CALLOUT = re.compile(
    r"(?:^> \*\*(Note|Caution):\*\*[^\n]*\n(?:^> [^\n]*\n)*)", re.M)


def callouts(md):
    """Turn '> **Note:** ...' blockquotes into styled divs.

    Done before the Markdown pass, on raw text, because the blockquote body
    still needs normal inline Markdown (code spans, links, emphasis) and the
    easiest way to keep that is to leave the body alone and only replace the
    fence.
    """
    def sub(m):
        block = m.group(0)
        kind = "note" if "**Note:**" in block else "caution"
        body = "\n".join(l[2:] if l.startswith("> ") else l[1:]
                         for l in block.rstrip("\n").split("\n"))
        body = body.replace("**Note:** ", "").replace("**Caution:** ", "")
        label = "Note" if kind == "note" else "Caution"
        inner = markdown.markdown(body, extensions=["tables", "attr_list"])
        return (f'\n<div class="callout {kind}">'
                f'<div class="callout-label">{label}</div>'
                f'<div class="callout-body">{inner}</div></div>\n\n')
    return CALLOUT.sub(sub, md)


def captions(html_text):
    """Attach the '**Table n. ...**' / '**Figure n. ...**' paragraphs to their
    object, so a caption is never orphaned at the foot of a page."""
    # Table captions precede their table.
    html_text = re.sub(
        r"<p><strong>(Table \d+\..*?)</strong></p>\s*<table>",
        lambda m: (f'<div class="tblock"><p class="caption">'
                   f'{m.group(1)}</p><table>'),
        html_text, flags=re.S)
    html_text = html_text.replace("</table>", "</table></div>")

    # Figure captions precede their image. Python-Markdown emits the img
    # attributes alphabetically (alt before src), so match on the whole tag
    # rather than assuming an order.
    def fig(m):
        cap, img = m.group(1), m.group(2)
        cls = "wide" if is_wide(img) else "inline"
        return (f'<figure class="{cls}">{img}'
                f'<figcaption>{cap}</figcaption></figure>')

    html_text = re.sub(
        r"<p><strong>(Figure \d+\..*?)</strong></p>\s*<p>(<img\b[^>]*/?>)</p>",
        fig, html_text, flags=re.S)
    return html_text


WIDE_PX = 900


def is_wide(img_tag):
    """A timing diagram wider than WIDE_PX pixels is unreadable squeezed into
    a 174 mm portrait column, so it gets its own landscape page. Measured from
    the file's intrinsic width rather than guessed from the filename."""
    src = re.search(r'src="([^"]+)"', img_tag)
    if not src:
        return False
    path = os.path.join(HERE, src.group(1))
    try:
        if path.endswith(".svg"):
            head = open(path, encoding="utf-8").read(400)
            w = re.search(r'width="(\d+(?:\.\d+)?)"', head)
            return bool(w) and float(w.group(1)) > WIDE_PX
        from PIL import Image
        with Image.open(path) as im:
            # Raster block diagrams are downsampled from 200 dpi renders and
            # stay legible; only judge vector figures by pixel width.
            return im.size[0] / im.size[1] > 2.2
    except OSError:
        return False


def build_toc(html_text):
    """Number-free TOC built from the h1/h2 already in the document.

    Section numbers are part of the heading text ('# 4. Parameters'), so the
    TOC just mirrors them. Page numbers come from CSS target-counter, which
    resolves after layout - that is the whole reason for going through
    paged-media CSS rather than emitting a static list.
    """
    entries = []
    def tag(m):
        lvl, attrs, text = m.group(1), m.group(2), m.group(3)
        hid = re.search(r'id="([^"]+)"', attrs)
        if not hid:
            slug = re.sub(r"[^a-z0-9]+", "-", text.lower()).strip("-")
            attrs += f' id="{slug}"'
            hid_val = slug
        else:
            hid_val = hid.group(1)
        entries.append((int(lvl), hid_val, re.sub("<[^>]+>", "", text)))
        return f"<h{lvl}{attrs}>{text}</h{lvl}>"

    html_text = re.sub(r"<h([12])([^>]*)>(.*?)</h\1>", tag, html_text, flags=re.S)

    rows = "\n".join(
        f'<li class="toc{lvl}"><a href="#{hid}">{html.escape(txt)}</a></li>'
        for lvl, hid, txt in entries)
    toc = ('<section class="toc"><h1 class="unnumbered">Contents</h1>'
           f'<ul>{rows}</ul></section>')
    return toc, html_text


CSS = """
@page {
    size: A4;
    margin: 22mm 18mm 20mm 18mm;
    @top-left {
        content: "AXI4-Lite Firewall IP Core — User Guide";
        font: 8pt "Liberation Sans", sans-serif; color: #5A6B85;
        vertical-align: bottom; padding-bottom: 3mm;
        border-bottom: 0.4pt solid #C9D3E4; width: 100%;
    }
    @top-right {
        content: "v""" + CORE_VER + """";
        font: 8pt "Liberation Sans", sans-serif; color: #5A6B85;
        vertical-align: bottom; padding-bottom: 3mm;
        border-bottom: 0.4pt solid #C9D3E4;
    }
    @bottom-left {
        content: "altera_axi4_lite_firewall";
        font: 8pt "Liberation Sans", sans-serif; color: #808080;
    }
    @bottom-right {
        content: counter(page);
        font: 8pt "Liberation Sans", sans-serif; color: #808080;
    }
}
@page :first { margin: 0; @top-left { content: ""; border: none; }
               @top-right { content: ""; border: none; }
               @bottom-left { content: ""; } @bottom-right { content: ""; } }

html { font: 9.6pt/1.45 "Liberation Serif", serif; color: #1A1A1A; }
body { margin: 0; }

/* ---------------------------------------------------------- title page */
.title-page { page: first; height: 297mm; position: relative;
              page-break-after: always; }
.title-band { background: #1F3864; color: #fff; padding: 42mm 18mm 14mm 18mm; }
/* The global h1 rule paints navy on navy and forces a page break; both have
   to be undone here or the title vanishes into its own banner. */
.title-band h1 { font: bold 30pt "Liberation Sans", sans-serif;
                 margin: 0 0 4mm 0; letter-spacing: -0.4pt;
                 color: #ffffff; border: none; padding: 0;
                 page-break-before: auto; }
.title-band .sub { font: 17pt "Liberation Sans", sans-serif; opacity: .85; }
.title-meta { padding: 12mm 18mm; font: 10pt "Liberation Sans", sans-serif; }
.title-meta table { border: none; width: auto; }
.title-meta td { border: none; padding: 1.6mm 12mm 1.6mm 0; }
.title-meta td:first-child { color: #5A6B85; }
.title-foot { position: absolute; bottom: 18mm; left: 18mm; right: 18mm;
              font: 8.5pt "Liberation Sans", sans-serif; color: #808080;
              border-top: 0.4pt solid #C9D3E4; padding-top: 3mm; }

/* ---------------------------------------------------------------- TOC */
.toc { page-break-after: always; }
.toc ul { list-style: none; padding: 0; margin: 0;
          font: 10pt "Liberation Sans", sans-serif; }
.toc li { margin: 0; padding: 1.1mm 0; }
.toc li a { text-decoration: none; color: #1A1A1A; }
.toc li a::after { content: target-counter(attr(href), page);
                   float: right; color: #5A6B85; }
.toc .toc1 { font-weight: bold; margin-top: 3mm;
             border-bottom: 0.3pt solid #E4EAF3; }
.toc .toc2 { padding-left: 7mm; font-size: 9.2pt; }
.toc .toc2 a { color: #404040; }

/* ------------------------------------------------------------ headings */
h1 { font: bold 17pt "Liberation Sans", sans-serif; color: #1F3864;
     margin: 0 0 5mm 0; padding-bottom: 2.5mm;
     border-bottom: 1.6pt solid #1F3864;
     page-break-before: always; page-break-after: avoid; }
h1.unnumbered { page-break-before: auto; }
h2 { font: bold 12.5pt "Liberation Sans", sans-serif; color: #1F3864;
     margin: 7mm 0 2.5mm 0; page-break-after: avoid; }
h3 { font: bold 10.5pt "Liberation Sans", sans-serif; color: #2E4A7D;
     margin: 5mm 0 2mm 0; page-break-after: avoid; }
p { margin: 0 0 2.6mm 0; text-align: justify; }
ul, ol { margin: 0 0 3mm 0; padding-left: 6mm; }
li { margin-bottom: 1.2mm; }

/* -------------------------------------------------------------- tables */
.tblock { page-break-inside: avoid; margin: 4mm 0 5mm 0; }
p.caption { font: bold 9pt "Liberation Sans", sans-serif; color: #1F3864;
            margin: 0 0 1.5mm 0; text-align: left;
            page-break-after: avoid; }
table { border-collapse: collapse; width: 100%;
        font: 8.6pt/1.32 "Liberation Sans", sans-serif; }
th { background: #1F3864; color: #fff; text-align: left; font-weight: bold;
     padding: 1.6mm 2mm; border: 0.4pt solid #1F3864; }
td { padding: 1.4mm 2mm; border: 0.4pt solid #C9D3E4; vertical-align: top; }
tbody tr:nth-child(even) td { background: #F4F7FB; }

/* ------------------------------------------------------------- figures */
figure { margin: 4mm 0 5mm 0; page-break-inside: avoid; text-align: center; }
/* The block diagrams are A4-landscape renders and the waveforms are wide
   SVGs; both have to be told to fit the text column, and capped in height so
   a figure plus its caption still fits one portrait page. */
figure img { max-width: 100%; max-height: 205mm; width: auto; height: auto; }

/* A timing diagram 30-odd cycles wide is unreadable squeezed into a 174 mm
   column, so it gets a rotated page to itself. */
@page landscape { size: A4 landscape; }
figure.wide { page: landscape; page-break-before: always;
              page-break-after: always; margin: 0; }
figure.wide img { max-width: 100%; max-height: 150mm; }
figcaption { font: bold 9pt "Liberation Sans", sans-serif; color: #1F3864;
             margin-top: 2mm; text-align: left; }

/* ------------------------------------------------------------ callouts */
.callout { margin: 3.5mm 0; padding: 2.5mm 3mm; page-break-inside: avoid;
           border-left: 2.2mm solid; font-size: 9.2pt; }
.callout p { margin: 0 0 1.6mm 0; }
.callout p:last-child { margin-bottom: 0; }
.callout-label { font: bold 9pt "Liberation Sans", sans-serif;
                 margin-bottom: 1.2mm; }
.note { background: #F0F5FC; border-color: #1F3864; }
.note .callout-label { color: #1F3864; }
.caution { background: #FFF8E6; border-color: #C08A00; }
.caution .callout-label { color: #9A6C00; }

/* ---------------------------------------------------------------- code */
code { font: 8.8pt "Liberation Mono", monospace; background: #F2F4F8;
       padding: 0.2mm 0.8mm; border-radius: 1pt; }
/* A code span in a header row would otherwise be white text on the pale code
   background, i.e. invisible. */
th code { background: rgba(255,255,255,0.18); color: #fff; }
pre { background: #F7F9FC; border: 0.4pt solid #DCE4F0; border-left: 1.6mm solid #1F3864;
      padding: 2.5mm 3mm; margin: 3mm 0 4mm 0; overflow-wrap: break-word;
      page-break-inside: avoid; }
pre code { background: none; padding: 0; font-size: 8.2pt; line-height: 1.35; }
a { color: #2E4A7D; text-decoration: none; }
hr { display: none; }
sub, sup { font-size: 70%; }
strong { font-weight: bold; }
"""


def main():
    md = open(SRC, encoding="utf-8").read()
    body_md = callouts(split_front_matter(md))
    body = markdown.markdown(
        body_md, extensions=["tables", "fenced_code", "attr_list", "toc"])
    body = captions(body)
    toc, body = build_toc(body)

    title_page = f"""
<div class="title-page">
  <div class="title-band">
    <h1>{TITLE}</h1>
    <div class="sub">{SUBTITLE}</div>
  </div>
  <div class="title-meta"><table>
    <tr><td>IP core</td><td><code>altera_axi4_lite_firewall</code></td></tr>
    <tr><td>Core version</td><td>{CORE_VER}</td></tr>
    <tr><td>Document version</td><td>{DOC_VER}</td></tr>
    <tr><td>Date</td><td>{DOC_DATE}</td></tr>
    <tr><td>Target</td><td>Intel FPGA / Quartus Prime, Platform Designer</td></tr>
  </table></div>
  <div class="title-foot">
    Access-control and fault-isolation IP core for AXI4-Lite.
    Source-available at github.com/monkstein88/altera-ip-cores.
  </div>
</div>"""

    doc = (f'<!DOCTYPE html><html><head><meta charset="utf-8">'
           f'<title>{TITLE} User Guide</title>'
           f"<style>{CSS}</style></head><body>"
           f"{title_page}{toc}{body}</body></html>")

    debug = os.path.join(HERE, ".ug_render.html")
    open(debug, "w", encoding="utf-8").write(doc)
    HTML(string=doc, base_url=HERE).write_pdf(OUT)
    print(f"written: {OUT}")


if __name__ == "__main__":
    sys.exit(main())
