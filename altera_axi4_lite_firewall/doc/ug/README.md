# Timing-figure toolchain

The user guide's four timing diagrams are rendered from a real simulation
rather than drawn by hand, so they cannot drift away from the RTL: change the
design and either the figure changes with it or the scenario stops matching and
the build fails loudly.

The documents themselves and their PDF builder live in [`../src/`](../src).

## Files

| File | Purpose |
|---|---|
| `wave_tb.sv` | Scenario bench. Drives an `int marker` signal tagging four windows: 1 permitted write, 2 denied read, 3 timeout, 4 recovery. |
| `wavedraw.py` | VCD parser and SVG waveform renderer |
| `mkwaves.py` | Cuts the four scenarios out of a VCD into `../figures/*.svg` |
| `check_figures.py` | Reads the SVGs back and compares their geometry against the VCD |

## Regenerating

```bash
verilator --binary --trace --top-module wave_tb \
    ../../rtl/axi_firewall_regs.sv ../../rtl/axi_firewall_top.sv wave_tb.sv
./obj_dir/Vwave_tb                        # writes wave.vcd

python3 mkwaves.py wave.vcd ../figures/
python3 check_figures.py wave.vcd ../figures/
```

Any simulator that writes a VCD will do; Verilator is just the licence-free
option.

## Checking

`check_figures.py` parses each SVG's path geometry back into logic levels and
compares them cycle by cycle against the VCD — **548 sampled points** across the
four figures. It exits non-zero on any mismatch, and skips with a message if the
VCD is absent (`*.vcd` is gitignored; the figures are committed, the trace is
not).

This is the check a hand-drawn waveform cannot have, and the reason these are
generated in the first place.
