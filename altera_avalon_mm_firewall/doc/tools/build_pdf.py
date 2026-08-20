#!/usr/bin/env python3
"""
Typeset a document: Markdown -> HTML -> PDF.

The PDF is the deliverable, the Markdown is the source of truth. Nothing here
invents content - it only adds the page furniture an Intel-style manual has and
Markdown does not: a title page, a table of contents with page numbers, running
headers and footers, numbered figure and table captions, and Note / Caution
callouts.

Layout is CSS paged media (WeasyPrint) rather than LaTeX, so the figure SVGs
render with a real browser engine and the styling is legible to anyone who
wants to change it.

Both documents in doc/ go through this one script, because they should look
like two chapters of the same manual rather than two unrelated PDFs.

Shared verbatim with the AXI4-Lite firewall's generator apart from the
constants below - the styling is the family's, not this core's.

Usage:  python3 build_pdf.py [ug|diagrams|all]      default all
Output: ../<document>.pdf
"""

import html
import os
import re
import sys

import markdown
from weasyprint import HTML

HERE = os.path.dirname(os.path.abspath(__file__))
DOC = os.path.dirname(HERE)

CORE_VER = "1.0"
DOC_DATE = "August 2026"

# name -> (markdown stem, subtitle, doc version, first heading of the body)
#
# `body_start` is where the front matter ends: everything above it - the title
# block and the hand-written contents list - exists for GitHub, which has no
# title page or TOC machinery, and is replaced here by the real thing.
DOCS = {
    "ug": ("avalon_mm_firewall_user_guide", "User Guide", "1.0",
           "\n# 1. About"),
    "diagrams": ("avalon_mm_firewall_block_diagrams",
                 "Block Diagrams and Descriptions", "1.0",
                 "\n# 1. System context"),
}

TITLE = "Avalon-MM Firewall IP Core"

# ---------------------------------------------------------------- preprocess


def split_front_matter(md, body_start):
    """Drop the Markdown title block and hand-written contents list."""
    return md[md.index(body_start):]


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
    object, so a caption is never orphaned at the foot of a page.

    Every table is wrapped, captioned or not. An earlier version opened the
    wrapper only for captioned tables but closed one after every </table>,
    which left ten unbalanced </div> in the block-diagram document - it has no
    table captions at all - and one in the user guide. Browsers and WeasyPrint
    recover from a stray close, so it rendered nearly right; what it actually
    cost was the wrapper's bottom margin, which is why prose there ran flush
    against the table above it.
    """
    def wrap(m):
        cap, table = m.group(1), m.group(2)
        head = f'<p class="caption">{cap}</p>' if cap else ""
        return f'<div class="tblock">{head}{table}</div>'

    html_text = re.sub(
        r"(?:<p><strong>(Table \d+\..*?)</strong></p>\s*)?(<table>.*?</table>)",
        wrap, html_text, flags=re.S)

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
    path = os.path.join(DOC, src.group(1))
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


def css(subtitle):
    return """
@page {
    size: A4;
    margin: 22mm 18mm 20mm 18mm;
    @top-left {
        content: "Avalon-MM Firewall IP Core — """ + subtitle + """";
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
        content: "altera_avalon_mm_firewall";
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
/* A code span inside a superscript would otherwise take the absolute font-size
   from the code rule, cancelling the 70% and flattening 2^TIMEOUT_WIDTH into
   "2 TIMEOUT_WIDTH". Raise/lower explicitly and let the span inherit. */
sub, sup { font-size: 70%; line-height: 0; position: relative; }
sup { vertical-align: super; }
sub { vertical-align: sub; }
sup code, sub code { font-size: inherit; padding: 0; background: none; }
strong { font-weight: bold; }
"""


def build(key):
    stem, subtitle, doc_ver, body_start = DOCS[key]
    src = os.path.join(DOC, stem + ".md")
    out = os.path.join(DOC, stem + ".pdf")

    md = open(src, encoding="utf-8").read()
    body_md = callouts(split_front_matter(md, body_start))
    body = markdown.markdown(
        body_md, extensions=["tables", "fenced_code", "attr_list", "toc"])
    body = captions(body)
    toc, body = build_toc(body)

    title_page = f"""
<div class="title-page">
  <div class="title-band">
    <h1>{TITLE}</h1>
    <div class="sub">{subtitle}</div>
  </div>
  <div class="title-meta"><table>
    <tr><td>IP core</td><td><code>altera_avalon_mm_firewall</code></td></tr>
    <tr><td>Core version</td><td>{CORE_VER}</td></tr>
    <tr><td>Document version</td><td>{doc_ver}</td></tr>
    <tr><td>Date</td><td>{DOC_DATE}</td></tr>
    <tr><td>Target</td><td>Intel FPGA / Quartus Prime, Platform Designer</td></tr>
  </table></div>
  <div class="title-foot">
    Burst-capable access-control and fault-isolation IP core for Avalon-MM.
    Source-available at github.com/monkstein88/altera-ip-cores.
  </div>
</div>"""

    doc = (f'<!DOCTYPE html><html><head><meta charset="utf-8">'
           f'<title>{TITLE} \u2014 {subtitle}</title>'
           f"<style>{css(subtitle)}</style></head><body>"
           f"{title_page}{toc}{body}</body></html>")

    open(os.path.join(HERE, f".render_{key}.html"), "w",
         encoding="utf-8").write(doc)
    HTML(string=doc, base_url=DOC).write_pdf(out)
    print(f"written: {out}")


def main():
    which = sys.argv[1] if len(sys.argv) > 1 else "all"
    for key in (DOCS if which == "all" else [which]):
        build(key)


if __name__ == "__main__":
    sys.exit(main())
