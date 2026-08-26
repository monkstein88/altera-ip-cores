# Document toolchain

Everything in `doc/` except the two `.md` files is generated. This directory
holds the generators and, more importantly, the checker that stops the
generated output from disagreeing with the design.

```
doc/tools/
├── build_pdf.py            Markdown -> HTML -> PDF, both documents
├── check_facts.py          Re-derives every number in the docs from the RTL
├── diagrams/
│   ├── build_figures.py    The four block diagrams
│   └── svg_lib.py          SVG canvas with real-font text layout
└── waveforms/
    ├── mkwaves.py          Cuts four scenarios out of a VCD
    └── wavedraw.py         VCD parser and SVG waveform renderer
```

`svg_lib.py` and `wavedraw.py` are shared verbatim with the AXI4-Lite
firewall's toolchain. Only the figure definitions and the fact checker are
specific to this core.

## Regenerating everything

```bash
pip install markdown weasyprint            # PDF
cd verification && ./capture.sh            # wave.vcd, needs Verilator
cd ../doc/tools
python3 waveforms/mkwaves.py               # timing figures
python3 diagrams/build_figures.py          # block diagrams
python3 build_pdf.py all                   # both PDFs
python3 check_facts.py                     # the part that matters
```

`check_facts.py` exits non-zero if anything has drifted. Run it after any
change to the RTL, the component description, the driver header or the
documents — it is fast, and it is the only thing standing between this
repository and a set of documents that describe a core that no longer exists.

## Why generate the figures at all

A drawing tool produces a file nobody can diff. The AXI4-Lite sibling's
architecture document used to be a zip of XML, and it sat at a stale version
number and a stale test count long after the core had moved on, because nothing
could see inside it to notice.

So: the block diagrams are Python, and `check_facts.py` reads the register bit
fields straight out of `build_figures.py` and compares them with the RTL. The
timing diagrams are cut from a VCD produced by a real simulation, so if the
design's behaviour changes, either the figure changes with it or `mkwaves.py`
fails to find its markers and says so.

## What check_facts.py actually verifies

304 individual claims, across (283 when no simulation log is present and the
measured-result checks are skipped):

- **Register offsets**, in both directions. The RTL holds *word* offsets and
  every document quotes *byte* offsets; that factor of four is the single most
  likely thing in this core to be got wrong in prose.
- **STATUS bit positions**, derived from the concatenation the RTL actually
  returns — and cross-checked against three independent copies of that layout:
  the driver header's masks, the testbench's localparams, and the generated
  register figure. If the tests and the driver drift apart from the RTL, the
  tests would still pass while checking the wrong bits.
- **Fault codes**, from the package enum through to the driver header and every
  prose table listing them.
- **`RULE_PERM` packing**, from `rule_perm_t` through to the driver and the
  testbench masks.
- **Reset values** — including that `GLOBAL_ENABLE` still resets *set*. A core
  that quietly stopped being secure by default would otherwise pass every
  functional test in the suite.
- **Parameter defaults and ranges**, cross-checked between the RTL module
  header, `hw.tcl` and the user guide's parameter table.
- **Assertion and cover-point counts**, and that every cover point the README
  names actually exists.
- **Assertion FAILURES in the logs.** An SVA failure does not touch the
  testbench's own pass/fail count, so a run can report "0 failed" with
  properties failing underneath it - which is exactly what happened while
  REGISTER_LOOKUP was being brought up.
- **Measured results** — check totals are read out of the simulation logs, not
  transcribed. The Verilator per-run logs are preferred; failing those, the
  Questa transcript is split on the testbench banner and used instead, so the
  totals are still verified on a machine with only one of the two simulators.
  All the logs are gitignored, so when none is present those checks are reported
  as *skipped* rather than silently passing.
- **Throughput guards**, so prose cannot claim better numbers than the
  regression actually enforces.
- **Figure references**, in both directions: every figure a document cites
  exists, and every generated figure is cited by something.
- **File manifest**, including that `hw.tcl` lists the package before the top
  level in both filesets — get that wrong and Quartus fails on the first
  imported type.

## Why not ODF

Tried it on the sibling core; it is how the staleness described above happened.
Markdown renders on GitHub, diffs in review, and can be read by a checker.
The PDF is the deliverable; the Markdown is the source of truth.
