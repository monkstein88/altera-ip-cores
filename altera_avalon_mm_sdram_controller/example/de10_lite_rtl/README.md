# DE10-Lite demonstration — RTL only

A Platform Designer system containing nothing but a clock source and this
project's SDRAM controller, driven by plain RTL. No CPU, no software: a
sequencer walks a set of memory-test scenarios, checks every word it reads back,
and reports over JTAG and on the seven-segment displays.

**Status: simulated, compiled, and closing timing — not yet run on hardware.**
The design builds through Quartus 18.1.1 Standard for the DE10-Lite's MAX 10,
fits in 6% of the device, meets its 100 MHz constraint with 0.430 ns of setup
slack, and produces a `.sof`. It has never been programmed into a part, so
everything below that describes a *running board* is describing what the design
is for, not what has been observed. The simulation and compilation results are
real and reproducible.

## What it is, and what it is a copy of

This is deliberately the *same demonstration* as
[`altera_avalon_new_sdram_controller/example/de10_lite_rtl`](../../../altera_avalon_new_sdram_controller/example/de10_lite_rtl),
with one line changed: the Platform Designer system instantiates
`altera_avalon_mm_sdram_controller` instead of Intel's controller.

That is the point. The claim this core makes is that it is a drop-in
replacement — same slave port, same conduit, same default address map — and the
most direct way to show it is to take a working demonstration of the other core
and swap the component. Same sequencer, same master, same pin assignments, same
timing constraints, same scenarios, same checks.

```tcl
add_instance sdram altera_avalon_mm_sdram_controller
apply_preset sdram "ISSI IS42S16320D-7 - DE10-Lite 64 MByte"
```

The eighteen hand-typed parameter values the other example carries are gone,
replaced by the preset. The clock is not set at all — the component takes it
from the clock source it is connected to.

## Running the simulation

```bash
export QUARTUS_ROOT=/opt/intelFPGA/18.1     # first run only, to generate the system
./simulation/verilator/run_sim.sh
```

Generating the Platform Designer system needs `qsys-generate`, which is part of
a Quartus installation but needs no licence. After that it is Verilator alone.

Current result: **58 checks passed, 0 failed, 0 timing violations, 0 illegal
device accesses.**

The nine phases are the ones the original demonstration had, with the last four
being the ones worth reading: the memory contents are inspected directly, the
documented address decode is re-derived from observed ACTIVATE commands, a word
is corrupted mid-run to prove the checker is not passing vacuously, and the
watchdog is provoked with a stalled bus.

## Two things this version checks that the original could not

**The device model has a row open per bank.** Intel's generated model keeps a
single open-row register for the whole device, so any ACTIVATE clobbers every
bank's row. Against a controller that holds a row open per bank it services
column commands from whichever row was activated last, and reports data
corruption for a completely legal command stream — see
[`../../benchmark/README.md`](../../benchmark/README.md). This example uses
[`../../tb/sdram_device_model.sv`](../../tb/sdram_device_model.sv), which
behaves like the part on the board. A useful side effect: no memory model has to
be generated from Quartus, so the simulation is licence-free.

**The command stream is checked against JEDEC timing.** Neither device model
enforces timing, so `sdram_timing_check` is bound to the memory bus and checks
tRC, tRAS, tRP, tRCD, tRRD, tWR and tMRD against the same nanosecond figures the
preset carries. The demonstration this was copied from had no equivalent: it
could have driven the part illegally and still printed ALL TESTS PASSED. Its
count is reported in the summary and failing it fails the run, because a checker
whose result nobody reads cannot fail.

## Pin assignments and constraints

All 110 pin assignments were checked line by line against the pin table in the
**DE10-Lite User Manual** (System CD v2.2.0): every one matches.

Worth knowing if you compare this against Terasic's own demonstrations: the
`SDRAM_RTL_Test` project on that System CD assigns **twelve HEX3/HEX4 segment
pins differently from its own user manual**. The pins are the same set, permuted
between the two digits, so its displays show scrambled segments. This project
follows the manual, which is why a diff against that demo shows twelve
differences that are not errors here.

The timing constraints - the -3 ns DRAM_CLK shift, the 5.9/3.0 ns input delays,
the 1.6/-0.9 ns output delays and the shift-window multicycle - are Terasic's
own figures for this board, and match their SDC exactly. The `t_AC` 5.4 ns and
`t_OH` 2.7 ns behind the input delays are the ISSI IS42S16320D -7 datasheet
values at CAS 3.

## Building for the board

```bash
export QUARTUS_ROOT=/opt/intelFPGA/18.1
./build.sh qsys        # generate the Platform Designer system
./build.sh fpga        # synthesise, fit, time and assemble
./run_on_board.sh      # program and read the result over JTAG  (NOT DONE HERE)
```

`build.sh fpga` completes with 0 errors and produces a bitstream:

| | |
|---|---|
| Logic elements | 2,805 / 49,760 (6%) |
| Registers | 1,602 |
| Pins | 110 / 360 |
| Setup slack, 100 MHz system clock | **+0.430 ns** |
| Setup slack, SDRAM interface | +1.996 ns |
| f_MAX | 104.5 MHz |

`run_on_board.sh` is the step that has never been run. Until someone programs a
board there is no hardware result for this core, and refresh and retention stay
unproven - no functional model forgets.

## Files

| Path | What it is |
|---|---|
| `qsys/build_system.tcl` | The system: clock source, controller, preset. The one file that differs from the original in substance |
| `rtl/de10_lite_sdram_demo.sv` | Top level: PLL, sequencer, master, displays, JTAG probes |
| `rtl/demo_sdram_seq.sv` | The scenarios and their checker |
| `rtl/demo_avl_mm_master.sv` | Avalon-MM master |
| `rtl/sdram_pll.sv` | 50 MHz in, 100 MHz plus a phase-shifted clock for the SDRAM pins |
| `tb/de10_lite_sdram_demo_tb.sv` | Board-level testbench, nine phases |
| `simulation/verilator/run_sim.sh` | Generates the system if needed, builds, runs |
| `quartus/` | Project, pin assignments, timing constraints |
| `board/issp_run.tcl` | Reads the result over JTAG after programming |

The generated Platform Designer output is not committed: it is reproducible
from the component with `./build.sh qsys`.
