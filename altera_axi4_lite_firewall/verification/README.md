# Supplementary benches

Neither bench here is part of the main suite in `tb/`. Both are standalone,
run by hand, and produce something the regression does not.

| Bench | Produces |
|---|---|
| `orphan_response_tb.sv` | A measurement: how often a stale response is mis-attributed with and without the peripheral reset |
| `wave_capture_tb.sv` | A VCD, from which the user guide's four timing figures are rendered |

---

## `orphan_response_tb.sv`

A standalone measurement of what step 4 of the recovery sequence is worth, and
the reason resetting the peripheral before `RECOVERY.UNBLOCK` is mandatory
rather than advisory.

It runs a genuine timeout (peripheral never handshakes, then latches the
request anyway — deliberately non-compliant, the nastiest orphan source),
recovers, then issues a legitimate write while the orphaned response lands at a
swept offset. If the master ever sees the orphan's SLVERR instead of its own
OKAY, the stale response was mis-attributed.

## Running it

**Verilator** (no licence required):

```bash
cd verification
for H in 1 0; do
  verilator --binary --timing -Wno-TIMESCALEMOD -GRESET_PERIPHERAL=$H \
      --top-module orphan_tb -o oz$H -Mdir obj_$H \
      ../rtl/axi4_lite_firewall_regs.sv ../rtl/axi4_lite_firewall_top.sv orphan_response_tb.sv
  ./obj_$H/oz$H
done
```

**Icarus:**

```bash
# correct: software resets the peripheral before unblocking
iverilog -g2012 -Porphan_tb.RESET_PERIPHERAL=1 -o o1.out \
    ../rtl/axi4_lite_firewall_regs.sv ../rtl/axi4_lite_firewall_top.sv orphan_response_tb.sv
vvp o1.out
# => 0 of 25 offsets affected

# skipped: software unblocks without resetting the peripheral
iverilog -g2012 -Porphan_tb.RESET_PERIPHERAL=0 -o o0.out \
    ../rtl/axi4_lite_firewall_regs.sv ../rtl/axi4_lite_firewall_top.sv orphan_response_tb.sv
vvp o0.out
# => 1 of 25 offsets affected  (at k=3)
```

## Result

| Wiring | Offsets mis-attributed |
|---|---|
| Reset performed (`RESET_PERIPHERAL=1`) | **0 of 25** |
| Reset skipped (`RESET_PERIPHERAL=0`) | **1 of 25**, at k=3 |

Measured under Verilator 5.48 against v2.0 RTL. The delta between the two runs
is exactly the protection step 4 provides — and, since v2.0 moved that step
into software, exactly what a driver costs you by skipping it.

> **v2.0 note.** The core no longer owns a peripheral reset output, so this
> bench measures a software mistake rather than a wiring one. The numbers are
> unchanged, which is the point: the reset was always what provided the
> protection, and moving it into the driver moved the risk with it.

---

## `wave_capture_tb.sv`

Stimulus only — it asserts nothing and has no pass or fail. Its sole output is
a VCD from which the user guide's four timing figures are rendered, so that
those figures come from the real design rather than from someone's memory of
it.

It drives four scenarios back to back, tagging each with an `int marker`
signal so the renderer can find them: **1** permitted write, **2**
permission-denied read, **3** downstream timeout, **4** the recovery sequence.
The bench is deliberately sequential and minimal so each window is a clean
figure.

> **The recovery scenario holds `periph_rst` asserted across the
> `RECOVERY.UNBLOCK` write**, and releases it afterwards. This is not
> incidental: the figure it renders is the user guide's illustration of the
> recovery sequence, so if the bench pulsed the reset before unblocking, the
> figure would depict exactly the mistake the guide warns against. It did,
> until the DE10-Lite example design made the consequence concrete.

```bash
cd verification
verilator --binary --trace --top-module wave_capture_tb \
    ../rtl/axi4_lite_firewall_regs.sv ../rtl/axi4_lite_firewall_top.sv wave_capture_tb.sv
./obj_dir/Vwave_capture_tb            # writes wave.vcd
```

The renderer and its checker live in
[`../doc/tools/waveforms/`](../doc/tools/waveforms):

```bash
cd ../doc/tools/waveforms
python3 mkwaves.py ../../../verification/wave.vcd
python3 check_figures.py ../../../verification/wave.vcd
```

`check_figures.py` parses the rendered SVGs back into logic levels and compares
them against the VCD cycle by cycle — 548 sampled points. A figure that has
drifted from the RTL fails there rather than being noticed in print.

Any simulator that writes a VCD will do; Verilator is just the licence-free
option. `*.vcd` is gitignored — the figures are committed, the trace is not.
