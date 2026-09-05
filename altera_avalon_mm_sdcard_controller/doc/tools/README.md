# doc/tools

Everything under `doc/` that is a picture or a PDF is generated. Nothing here is
hand-drawn or hand-typeset, and that is the point.

| Tool | Produces |
|---|---|
| `diagrams/build_figures.py` | The five block diagrams, as SVG in `doc/figures/` |
| `diagrams/svg_lib.py` | The drawing library the other cores' diagrams use, so the figures across this repository look like one set |
| `waveforms/mkwaves.py` | The five timing figures, cut out of a recorded simulation |
| `waveforms/wavedraw.py` | VCD reader and waveform renderer |
| `build_pdf.py` | Markdown → HTML → PDF, with title page, TOC, running heads |
| `check_facts.py` | Re-derives every number in the documentation from source and fails if any has drifted |

## Regenerating everything

```bash
python3 doc/tools/diagrams/build_figures.py   # block diagrams
./verification/capture.sh                     # record verification/wave.vcd
python3 doc/tools/waveforms/mkwaves.py        # timing figures, cut from the VCD
python3 doc/tools/build_pdf.py all            # typeset both documents
python3 doc/tools/check_facts.py              # verify every number
```

`build_pdf.py` needs `weasyprint` and `markdown`; the rest need only Python 3.
`capture.sh` needs Verilator.

## Why SVG rather than a drawing program

A drawing program's file is a zip of XML. It cannot be reviewed in a diff,
cannot be grepped for a stale claim, and cannot be checked by a script. Every
number that appears in these figures also appears in the RTL, and
`check_facts.py` compares them — including the register map, which the
block-diagram document carries as a figure rather than a table, so the claim
being checked lives in `build_figures.py`.

## Why the timing figures come from a VCD

Because a hand-drawn timing diagram cannot be checked against anything, and
quietly becomes fiction the first time the RTL changes.

SPI-mode SD is exactly the protocol where that does damage. It is full of
details a plausible-looking drawing gets wrong: `N_CR` is a **range** and not a
fixed latency, the data-response token carries **five bits of meaning in eight**,
and CRC16 is seeded with **zero** rather than the 0xFFFF that "CCITT" implies
everywhere else. A drawing that gets any of those wrong looks entirely
convincing, and a reader has no way to tell.

So `verification/wave_capture_tb.sv` drives four scenarios and dumps a VCD, and
`mkwaves.py` reconstructs the byte stream from `sd_mosi` and `sd_miso` sampled on
`sd_clk` rising edges — which is where the receiver samples — and cuts figures
out of it. Change the design and either the figure changes with it, or
`mkwaves.py` exits with an error naming the token or state it could no longer
find.

## Byte-level, with one exception

A bit-level view of a 512-byte block is 4,096 columns wide, and the structure
worth seeing in this protocol is not in the bits but in the **sequence of
bytes**: which token arrived, how many idle bytes passed before the response,
what the card answered. So the figures are one column per byte-time.

`fig_wave_bit` is the exception, and shows a single byte at bit level, because
the sampling edge is the one fact a byte-level view cannot express and the one
an integrator has to get right when wiring this to a real card.

## Notes on `wavedraw.py`

This copy differs from the firewall cores' in two ways, both forced by
byte-level protocol figures:

- A **`byte` row kind** that draws one cell per column. The shared `bus` kind
  merges runs of equal adjacent values, which is right for an address that holds
  for several cycles and wrong here: a six-byte command frame whose four
  argument bytes are all zero collapses to three cells, and the reader can no
  longer count the frame.
- **Two-pass cell drawing** — every shape first, then every label — because a
  label wider than its own cell was being painted over by the next cell's fill,
  so `RD_TOKEN` in a single byte-time rendered as `RD_TOKE` with nothing to say
  it had been cut. Labels that still do not fit are scaled down rather than
  allowed to collide.

Notes under a figure are also wrapped to the figure's width. They were being
emitted as single unwrapped lines, which ran off the right edge of the SVG and
stopped mid-word.
