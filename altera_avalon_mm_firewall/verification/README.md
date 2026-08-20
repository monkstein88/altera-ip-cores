# Standalone benches

Benches that are not part of the regression suite. They check nothing; they
exist to produce artefacts or to measure something the suite cannot.

| File | What it is |
|---|---|
| `wave_capture_tb.sv` | Drives the four scenarios the user guide's timing figures are rendered from, and dumps `wave.vcd` |
| `capture.sh` | Builds and runs it |

```bash
./capture.sh                                   # writes wave.vcd
python3 ../doc/tools/waveforms/mkwaves.py      # renders the figures
```

The figures are generated from a real VCD rather than drawn so that they cannot
drift away from the RTL. Change the design and either the figure changes with
it, or `mkwaves.py` fails to find its markers and says so loudly. A hand-drawn
timing diagram just quietly becomes fiction.

`wave_capture_tb.sv` sets `TIMEOUT_VALUE` to 10 cycles purely so the timeout
figure fits on a page. A real system uses thousands.
