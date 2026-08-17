# Document generators

`doc/` holds two documents. Both are Markdown source plus a generated PDF, and
both go through the same builder so they read as two parts of one manual:

| Document | Source | Output |
|---|---|---|
| User guide | `../axi4_lite_firewall_user_guide.md` | `../axi4_lite_firewall_user_guide.pdf` |
| Block diagrams | `../axi4_lite_firewall_block_diagrams.md` | `../axi4_lite_firewall_block_diagrams.pdf` |

Edit the Markdown, never the PDF. Every figure in `../figures/` is generated —
nothing there is hand-drawn.

## Files

| File | Purpose |
|---|---|
| `build_pdf.py` | Markdown → HTML → PDF. Title page, TOC with page numbers, running headers/footers, captions, Note/Caution callouts, landscape pages for wide figures. |
| `build_figures.py` | Draws the four block diagrams as standalone SVGs |
| `svg_lib.py` | Minimal SVG canvas: cm coordinates, styles, shapes, real-font text layout |
| `check_facts.py` | Re-derives every number in **both** documents from the RTL and fails if any has drifted |

The timing diagrams have their own toolchain in `../ug/`, because they are
generated from a simulation rather than drawn.

## Rebuilding

```bash
pip install weasyprint markdown pillow --break-system-packages

python3 build_figures.py      # -> ../figures/fig_{context,internal,fsm,registers}.svg
python3 build_pdf.py          # -> both PDFs
python3 build_pdf.py ug       # or just one
python3 check_facts.py        # 268 checks
```

`build_pdf.py` needs no LibreOffice, no LaTeX and no network.

## Why SVG and Markdown, not ODF

This used to be a nine-page `.odg` built by `odg_lib.py`, exported to PDF
through LibreOffice. That was replaced because a zip of XML cannot be reviewed
or verified:

* `git diff` on an `.odg` says `Bin 16524 -> 16538 bytes`
* you cannot grep it for a stale claim
* a checker cannot read it

That last point was not hypothetical. The document sat at
**v1.2 / 0x0102 / 80 tests / 12 assertions** long after the core reached v2.0,
and nothing in the repository could have noticed. `check_facts.py` now verifies
its register offsets, reset values, FSM transition counts, latency figures and
verification totals against the RTL and the committed Questa artefacts — and
cross-checks that the two documents do not contradict each other.

SVG keeps what ODF was actually good at — absolute positioning for diagrams —
while staying text. It also renders natively in the PDF as vector rather than
being rasterised through a LibreOffice export.

## Notes on `svg_lib.py`

The API deliberately mirrors the old `odg_lib`, so the drawing code ported
across unedited: same cm coordinate system, same `gstyle`/`pstyle`/`tstyle`
registration, same `rect`/`ellipse`/`line`/`polyline`/`text` primitives.

Two things ODF did for free had to be written:

* **Text layout.** SVG has no auto-wrap and no vertical alignment inside a
  shape. `svg_lib` measures text with the real Liberation TTF via PIL, so
  wrapping matches what renders. Without PIL it falls back to a per-character
  estimate and lines wrap slightly differently.
* **Cropping.** The drawing code inherits an A4-landscape coordinate system
  from when each diagram was a printed page. Each figure is cropped to the
  bounds of what was actually drawn, so it carries no empty page margin into
  the document.
