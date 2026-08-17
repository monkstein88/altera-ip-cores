# Timing-diagram toolchain

The four timing diagrams are rendered from a real simulation rather than drawn,
so they cannot drift away from the RTL: change the design and either the figure
changes with it or the scenario stops matching and the build fails loudly.

**The bench that produces the trace is not here.** It is
[`verification/wave_capture_tb.sv`](../../../verification), with the repository's
other standalone benches — all SystemVerilog lives under `rtl/`, `tb/` or
`verification/`. This directory holds only the renderer and its checker.

## What this makes

| Figure | Scenario |
|---|---|
| `../../figures/fig_write_ok.svg` | Permitted write, request to response |
| `../../figures/fig_read_denied.svg` | Permission-denied read, answered locally |
| `../../figures/fig_timeout.svg` | Downstream timeout, `VALID` left asserted |
| `../../figures/fig_recovery.svg` | The full recovery sequence |

All four appear in the user guide.

## Files

| File | Purpose |
|---|---|
| `wavedraw.py` | VCD parser and SVG waveform renderer |
| `mkwaves.py` | Cuts the four scenarios out of a VCD |
| `check_figures.py` | Reads the SVGs back and compares their geometry against the VCD |

## Rebuilding

First produce the trace, from `verification/`:

```bash
cd ../../../verification
verilator --binary --trace --top-module wave_capture_tb \
    ../rtl/axi_firewall_regs.sv ../rtl/axi_firewall_top.sv wave_capture_tb.sv
./obj_dir/Vwave_capture_tb            # writes wave.vcd
```

Then render:

```bash
cd ../doc/tools/waveforms
python3 mkwaves.py ../../../verification/wave.vcd     # -> ../../figures/
```

`wave_capture_tb.sv` drives an `int marker` signal tagging the four windows
this renderer looks for: 1 permitted write, 2 denied read, 3 timeout,
4 recovery. Any simulator that writes a VCD will do; Verilator is just the
licence-free option.

## Checking

```bash
python3 check_figures.py ../../../verification/wave.vcd    # 548 sampled points
```

It parses each SVG's path geometry back into logic levels and compares them
cycle by cycle against the VCD. Exits non-zero on any mismatch, and skips with a
message if the VCD is absent — `*.vcd` is gitignored, so the figures are
committed but the trace is not.

This is the check a hand-drawn waveform cannot have, and the reason these are
generated in the first place.
