# Regenerating the block-diagram document

`../axi4_lite_firewall_block_diagrams.odg` is generated, not hand-drawn, so it
can be kept in step with the RTL by editing the script rather than nudging
shapes in LibreOffice.

```bash
cd doc/src
python3 build_doc.py                 # writes the .odg here
soffice --headless --convert-to pdf axi4_lite_firewall_block_diagrams.odg
```

`odg_lib.py` is a small OpenDocument Graphics writer - boxes, lines,
polylines, text frames and tables, all positioned in centimetres on a
29.7 x 21.0 cm landscape page. `build_doc.py` holds the content.

The output is a normal Draw file: every shape is a real `draw:rect`,
`draw:line` or `draw:polyline`, so it can also just be edited by hand if you
prefer. If you do that, the script and the file will drift apart - regenerate
or edit, not both.

Two things that will bite if you extend the script:

- `wire x = expr;` versus `logic x = expr;` has an ODF analogue: a
  `draw:frame` with a fixed `svg:height` clips, while `draw:auto-grow-height`
  lets text run off the page. Both fail silently. Render and look at every
  page after a change.
- XML collapses runs of spaces, so hand-aligned monospace columns lose their
  alignment unless emitted as `<text:s text:c="n"/>`. `xtext()` handles this.
