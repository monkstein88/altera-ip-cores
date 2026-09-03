# DE10-Lite demonstration — RTL only

A Platform Designer system containing nothing but a clock source and this
project's SDRAM controller, driven by plain RTL. No CPU, no software: a
sequencer walks a set of memory-test scenarios, checks every word it reads back,
and reports over JTAG and on the seven-segment displays.

**Status: verified on hardware.** Programmed into a Terasic DE10-Lite and run
over USB: **all eight scenarios pass**, including refresh retention and a full
64 MByte march over every one of 33,554,432 words. On silicon it reaches
**199.8 MB/s** where every access is a row hit — 99.9% of a 16-bit bus at
100 MHz — and 34.4 MB/s where every access is a row miss.

## What it printed on the board

```
--- auto sweep: all 8 scenarios ---
  after sweep            bitmap=FF scen=7 pass=1 valid=1 run=0 done=8 err=0

  per-scenario result:
    0 data bus walk        PASS      4 bank toggle          PASS
    1 address bus walk     PASS      5 row thrash           PASS
    2 byte enables         PASS      6 refresh retention    PASS
    3 column sweep         PASS      7 full 64 MB march     PASS

--- throughput, measured on silicon ---
  scenario                    words     wr cyc   write MB/s    read MB/s
  3 column sweep               1024       1025        199.8        198.6
  4 bank toggle                2048       6135         66.8         65.3
  5 row thrash                  256       1487         34.4         32.2
  7 full 64 MB march       33554432   34144600        196.5        196.5

--- scenario 6 on its own: refresh retention (12 s idle) ---
  PASS: 8 MByte survived 12 s of no access at all

PASS: all 8 scenarios passed in the sweep (bitmap = FF)
```

The row-miss cost is lower here than on the DE0-Nano — 1,487 cycles for 256
words against 1,734 — because the parts are not the same. The IS42S16320D-7
has the shorter tRC of the two, and the preset follows the datasheet rather
than being copied across.

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

Current result: **61 checks passed, 0 failed, 0 timing violations, 0 illegal
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
./run_on_board.sh      # program and read the result over JTAG
```

`build.sh fpga` completes with 0 errors and produces a bitstream:

| | |
|---|---|
| Logic elements | 3,320 / 49,760 (7%) |
| Registers | 1,875 |
| Pins | 110 / 360 |
| Setup slack, 100 MHz system clock | **+1.037 ns** |
| Setup slack, SDRAM interface | +2.370 ns |
| f_MAX | 111.9 MHz |

**That margin is the fitter's, not the RTL's.** Five builds of identical RTL
at different fitter seeds measured 0.249, 0.770, 0.734, 0.451 and 0.472 ns at
default effort - a 0.52 ns spread on a 10 ns period, with the shipped seed
landing on the unlucky end. The project now sets high fitter effort, which
measured 1.037, 0.553, 0.970, 1.000 and 1.127 over the same seeds: the worst
case roughly doubles. See the `.qsf` for the numbers and the reasoning.

`run_on_board.sh` is what produced the transcript above. It needs no one
looking at the board: it programs the part, drives every scenario over JTAG,
checks that the design ran the scenario it was asked for, and exits non-zero if
anything failed.

## Files

| Path | What it is |
|---|---|
| `qsys/build_system.tcl` | The system: clock source, controller, preset. The one file that differs from the original in substance |
| `rtl/de10_lite_sdram_demo.sv` | Top level: PLL, sequencer, master, displays, JTAG probes |
| `../common/demo_sdram_seq.sv` | The scenarios and their checker, shared with the other three examples |
| `../common/demo_avl_mm_master.sv` | Avalon-MM master, shared |
| `rtl/sdram_pll.sv` | 50 MHz in, 100 MHz plus a phase-shifted clock for the SDRAM pins |
| `tb/de10_lite_sdram_demo_tb.sv` | Board-level testbench, nine phases |
| `simulation/verilator/run_sim.sh` | Generates the system if needed, builds, runs |
| `quartus/` | Project, pin assignments, timing constraints |
| `board/issp_run.tcl` | Reads the result over JTAG after programming |

The generated Platform Designer output is not committed: it is reproducible
from the component with `./build.sh qsys`.
