# Block-diagram toolchain

The four block diagrams are drawn from code, not by hand, so they are text:
they diff, they grep, and a reviewer can see what changed.

## What this makes

| Figure | Contents |
|---|---|
| `../../figures/fig_context.svg` | System context — where the core sits and what must be connected |
| `../../figures/fig_internal.svg` | Internal architecture — datapaths, register block, recovery |
| `../../figures/fig_fsm.svg` | The two datapath state machines |
| `../../figures/fig_registers.svg` | Register bit fields |

The first two also appear in the user guide.

## Files

| File | Purpose |
|---|---|
| `build_figures.py` | Page content and layout for all four diagrams |
| `svg_lib.py` | Minimal SVG canvas: cm coordinates, style registration, shapes, real-font text layout |

## Rebuilding

```bash
pip install pillow --break-system-packages     # for font metrics
python3 build_figures.py                       # -> ../../figures/
```

`pillow` is optional. Without it `svg_lib` falls back to a per-character width
estimate and lines wrap slightly differently; the diagrams still come out.

## Checking

These figures have no self-check of their own — they are layout, not data. What
they *claim* is verified: `../check_facts.py` confirms that the register
offsets, bit positions and permission encoding drawn here still match the RTL,
and that the diagram document quoting them agrees with the user guide.

Visual review is a render:

```bash
python3 -c "import webbrowser; webbrowser.open('../../figures/fig_context.svg')"
```

## Notes on `svg_lib.py`

The API deliberately mirrors the `odg_lib` it replaced, so the drawing code
ported across unedited: same cm coordinate system, same `gstyle`/`pstyle`/
`tstyle` registration, same `rect`/`ellipse`/`line`/`polyline`/`text`
primitives.

Two things ODF did for free had to be written:

* **Text layout.** SVG has no auto-wrap and no vertical alignment inside a
  shape. `svg_lib` measures with the real Liberation TTF so wrapping matches
  what renders, and preserves runs of spaces — the diagrams hand-align
  monospace columns with them.
* **Cropping.** The drawing code inherits an A4-landscape coordinate system
  from when each diagram was a printed page. Each figure is cropped to the
  bounds of what was actually drawn, so it carries no empty page margin into
  the document. That is also why a label may sit at a negative coordinate: it
  overhangs the old page edge and costs nothing.
