# User guide sources

The two deliverables live one level up in `doc/`, next to the block-diagram
document:

* `../axi4_lite_firewall_user_guide.md` — the source of truth, readable on GitHub
* `../axi4_lite_firewall_user_guide.pdf` — typeset output, 37 pages

Edit the Markdown, never the PDF. Image paths in the Markdown are relative to
`doc/`, so they read `ug/figures/...`.

This directory holds only the machinery that produces them.

## Files

| File | Purpose |
|---|---|
| `build_ug.py` | Markdown → HTML → PDF. Title page, TOC with page numbers, headers/footers, captions, Note/Caution callouts. Writes to `../`. |
| `check_facts.py` | Re-derives every number in the guide from the RTL and re-run artefacts, and fails if any has drifted |
| `wave_tb.sv` | Scenario bench producing the four timing captures |
| `wavedraw.py` | VCD parser and SVG waveform renderer |
| `mkwaves.py` | Cuts the four scenarios out of a VCD into `figures/*.svg` |
| `check_figures.py` | Reads the SVGs back and compares their geometry against the VCD |
| `figures/` | `fig_context.png` and `fig_internal.png` are extracted from `../axi4_lite_firewall_block_diagrams.pdf`; the four `.svg` waveforms are generated |

## Rebuilding the PDF

```bash
pip install weasyprint markdown --break-system-packages
python3 build_ug.py          # writes ../axi4_lite_firewall_user_guide.pdf
```

## Regenerating the timing figures

The figures come from a real simulation, so they cannot drift silently from
the RTL. `wave_tb.sv` drives an `int marker` signal that tags four windows:
1 permitted write, 2 denied read, 3 timeout, 4 recovery.

```bash
verilator --binary --trace --top-module wave_tb \
    ../../rtl/axi_firewall_regs.sv ../../rtl/axi_firewall_top.sv wave_tb.sv
./obj_dir/Vwave_tb                       # writes wave.vcd
python3 mkwaves.py wave.vcd figures/
python3 check_figures.py wave.vcd figures/
```

`check_figures.py` parses each SVG's path geometry back into logic levels and
compares them cycle by cycle against the VCD — 548 sampled points across the
four figures. It exits non-zero on any mismatch.

## Regenerating the block-diagram figures

These are page 2 and page 4 of the block-diagram document, cropped free of
page chrome:

```bash
cd ../src && python3 build_doc.py
cd .. && soffice --headless --convert-to pdf --outdir . \
    axi4_lite_firewall_block_diagrams.odg
pdftoppm -r 200 -png -f 2 -l 2 axi4_lite_firewall_block_diagrams.pdf /tmp/ctx
pdftoppm -r 200 -png -f 4 -l 4 axi4_lite_firewall_block_diagrams.pdf /tmp/int
# then crop below the navy header band and above the footer rule
```

## Checking the facts

```bash
python3 check_facts.py
```

Re-derives every register offset, bit position, reset value, parameter range,
port count, assertion pass count, cover hit and FSM transition count quoted in
the guide, from `rtl/*.sv`, `axi_firewall_hw.tcl` and the Questa artefacts —
and fails if any of them no longer agrees.

225 checks pass at the time of writing. The simulation-result group is skipped
with a message if `simulation/questa/coverage_report.txt` and `run.log` are
absent, since both are gitignored build artefacts; run
`simulation/questa/run_sim.tcl` first to enable them.

**Run `check_facts.py` after any RTL change.** It is the only thing standing
between an edit to a register bit and a user guide that quietly lies about it.
