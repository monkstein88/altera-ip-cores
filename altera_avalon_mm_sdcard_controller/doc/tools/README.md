# doc/tools

Every picture and every PDF under `doc/` is generated. Nothing is hand-drawn or
hand-typeset.

| Tool | Produces | Needs |
|---|---|---|
| `diagrams/build_figures.py` | Four block diagrams, as `.dot` + `.svg` | Graphviz |
| `waveforms/mkwaves.py` | Five timing figures, as `.json` + `.svg` | a recorded VCD; Node for the SVG |
| `waveforms/vcd.py` | VCD reader used by the above | — |
| `waveforms/render.js` | WaveDrom JSON → SVG | Node, `npm install` |
| `build_pdf.py` | Markdown → HTML → PDF | `weasyprint`, `markdown` |
| `check_facts.py` | Nothing — verifies every number in the documents | — |

## Regenerating everything

```bash
python3 doc/tools/diagrams/build_figures.py   # block diagrams
./verification/capture.sh                     # record verification/wave.vcd
cd doc/tools/waveforms && npm install         # once
python3 doc/tools/waveforms/mkwaves.py        # timing figures
python3 doc/tools/build_pdf.py all            # typeset both documents
./verification/check_figures.sh               # confirm the tracked SVGs match
python3 doc/tools/check_facts.py              # confirm every number
```

The SVGs are tracked, so **reading** the documents needs none of these tools.
They are only needed to change a figure.

`check_figures.sh` compares 19 files: the four block diagrams and five timing
figures, each with the generator input beside it. It reports three outcomes,
not two — **PASS** only when all 19 were compared, **FAIL** when one has
drifted, and **INCOMPLETE** with a count when a tool or the recording is
missing, which the roll-ups render as a `PART` row rather than a green one.

That distinction was added after the check spent a long time reporting

```text
*** PASS *** (0 files identical to a fresh render)
```

on a machine with no Graphviz and no recorded VCD: a pass earned by comparing
nothing, and indistinguishable in `check_all.sh` from one that had checked
everything. Absent evidence is not evidence, and a checker that cannot tell the
difference teaches people to ignore it.

## Why Graphviz for the block diagrams

The first version placed every box and every line by hand, in centimetres.
For a row of boxes that is fine. For the sequencer's twenty states it was not:
two convergence lines ran right to left across the whole figure at nearly the
same height, crossed the arrow they were converging with, and clipped a label on
the way past. `S_ABORT` sat at the far right pointing backwards into `S_DONE`.
The diagram could not be followed.

Edge routing is a solved problem. Graphviz does the layout; `build_figures.py`
only says what connects to what, so moving a node reroutes every line.

Two things learned the hard way, both recorded in comments at the point they
matter:

- A `rank=same` group that mixes nodes inside a cluster with nodes outside it
  does not just fail to constrain them — it collapses the cluster's bounding box
  down to whatever is left inside.
- Clusters stack in **reverse** declaration order, so listing read, write and
  PIO in that order prints them upside down.

## Why WaveDrom for the timing figures

Because it is what the notation is for, and the previous hand-rolled renderer
kept meeting problems WaveDrom had already solved — labels wider than their box
painted over their neighbours, notes that ran off the edge of the SVG.

The figures are still generated from a real simulation.
`verification/wave_capture_tb.sv` drives four scenarios and dumps a VCD;
`mkwaves.py` reconstructs the byte stream from `sd_mosi` and `sd_miso` sampled on
`sd_clk` rising edges — where the receiver samples — and emits WaveDrom JSON.
Change the RTL and either the figure changes with it, or `mkwaves.py` stops
finding the token or state it is looking for and exits saying which.

That matters here more than for most cores. SPI-mode SD is full of details a
plausible drawing gets wrong: `N_CR` is a range and not a fixed latency, the
data-response token carries five bits of meaning in eight, and CRC16 is seeded
with zero rather than the `0xFFFF` that "CCITT" implies everywhere else. A
drawing that gets any of those wrong still looks convincing.

One WaveDrom trap, in case you edit the JSON by hand: repeating a character in a
`wave` string does **not** mean "unchanged". Every character is a fresh
transition, so `"0000001"` draws six glitches. Only `.` continues the previous
level.

## Byte-level, with one exception

A bit-level view of a 512-byte block is 4,096 columns wide, and what matters in
this protocol is the sequence of **bytes**: which token arrived, how many idle
bytes passed before the response, what the card answered. So one column is one
byte-time.

`fig_wave_bit` is the exception and shows a single byte at bit level, because
the sampling edge is the one fact a byte-level view cannot express and the one
to get right against real hardware.

## Two things that are deliberately not figures

**The register map.** It was a figure once — the same rows the user guide
carries as a table, drawn as a picture: unselectable, unsearchable, and one more
thing to keep in step. A table should be a table.

**The explanatory notes.** They used to be baked into each figure as a block of
small text. They are prose in the documents now, where they can be edited,
searched, and read at a sensible size.
