# Document tools

Everything in `doc/` is generated. This directory holds the generators.

```
doc/
├── axi4_lite_firewall_user_guide.md / .pdf        40 pages
├── axi4_lite_firewall_block_diagrams.md / .pdf    15 pages
├── figures/                    all 8 figures, all SVG, all generated
└── tools/
    ├── build_pdf.py            both documents  ->  PDF
    ├── check_facts.py          verifies both documents against the RTL
    ├── diagrams/               block diagrams, drawn from code
    └── waveforms/              timing diagrams, captured from simulation
```

Edit the Markdown, never the PDF. Nothing in `figures/` is hand-drawn.

Every tool resolves paths from its own location, not the caller's working
directory, so all of the commands below work from anywhere.

## What this level makes

| File | Purpose |
|---|---|
| `build_pdf.py` | Markdown → HTML → PDF for both documents: title page, TOC with page numbers, running headers/footers, numbered captions, Note/Caution callouts, landscape plates for wide figures |
| `check_facts.py` | Re-derives every number in **both** documents from the RTL, `axi_firewall_hw.tcl` and the committed Questa artefacts, and fails if any has drifted |

`pypdf` is optional. With it installed, `check_facts.py` also verifies that the
page counts the READMEs quote match the built PDFs — a claim that had been
wrong for two revisions, since nothing could see inside a PDF to check it.
Without it, that one group is skipped and says so.

The two figure toolchains have their own READMEs:
[`diagrams/`](diagrams), [`waveforms/`](waveforms).

## Rebuilding

```bash
pip install weasyprint markdown pillow --break-system-packages
pip install pypdf --break-system-packages   # optional, see Checking

python3 diagrams/build_figures.py    # block diagrams  -> ../figures/
python3 build_pdf.py                 # both PDFs
python3 build_pdf.py ug              # or one:  ug | diagrams
```

No LibreOffice, no LaTeX, no network.

## Checking

```bash
python3 check_facts.py                          # 309 checks (305 without pypdf)
python3 waveforms/check_figures.py wave.vcd     # 548 sampled points
```

**Run `check_facts.py` after any RTL change.** It is the only thing standing
between an edit to a register bit and two documents that quietly lie about it.

It re-derives every register offset, bit position, reset value, parameter
range, port count, assertion pass count, cover hit and FSM transition count
quoted anywhere in `doc/`, and cross-checks that the two documents do not
contradict each other. It also asserts that table and figure numbering is
sequential and that every table is captioned, so inserting a table part-way
through a document cannot silently leave the rest misnumbered. The simulation-result group is skipped with a message if
`simulation/questa/coverage_report.txt` and `run.log` are absent, since both are
gitignored build artefacts.

## Why Markdown and SVG, not ODF

The block-diagram document used to be a nine-page `.odg` built by `odg_lib.py`
and exported through LibreOffice. A zip of XML cannot be reviewed or verified:

* `git diff` reports `Bin 16524 -> 16538 bytes`
* you cannot grep it for a stale claim
* a checker cannot read it

That last point was not hypothetical. The document sat at
**v1.2 / 0x0102 / 80 tests / 12 assertions** long after the core reached v2.0,
and nothing in the repository could have noticed. Moving it to Markdown and SVG
took `check_facts.py` from 225 checks to 268, and it has grown since.

SVG keeps what ODF was actually good at — absolute positioning for diagrams —
while staying text. It also embeds in the PDF as vector rather than as a
rasterised export.
