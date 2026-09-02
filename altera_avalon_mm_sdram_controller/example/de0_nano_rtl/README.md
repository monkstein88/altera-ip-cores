# DE0-Nano demonstration — RTL only

A Platform Designer system containing nothing but a clock source and this
project's SDRAM controller, driven by plain RTL. No CPU, no software: a
sequencer walks a set of memory-test scenarios, checks every word it reads
back, and reports over JTAG and on the LEDs.

**Status: RUN ON HARDWARE. All eight scenarios pass on a real DE0-Nano.**

```
0 data bus walk      PASS     4 bank toggle        PASS
1 address bus walk   PASS     5 row thrash         PASS
2 byte enables       PASS     6 refresh retention  PASS
3 column sweep       PASS     7 full 32 MB march   PASS
```

Measured on the board, at 100 MHz on a 16-bit bus whose ceiling is 200 MB/s:

| Scenario | Words | Write cycles | Write MB/s | Read MB/s |
|---|---|---|---|---|
| 3 column sweep — every access a row hit | 512 | 513 | **199.6** | 197.3 |
| 4 bank toggle — alternating bank *and* row | 1,024 | 4,064 | 50.4 | 48.9 |
| 5 row thrash — every access a row miss | 256 | 1,734 | **29.5** | 27.6 |
| 7 full 32 MB march | 16,777,216 | 17,149,074 | 195.7 | 195.7 |

**99.8% of the bus on row hits, and 6.8× that cost when every access misses.**
The simulation predicted scenario 5 at exactly 1,734 cycles for 256 words; the
silicon returned exactly 1,734. Verilator and the part agree cycle for cycle.

Scenario 4 sits between the two extremes on purpose. It used to walk a block
across the bank bit and report 199.8 MB/s, but every address in that walk was
in row 0 — which meant a controller with one shared open-row register passed
it, measured, on this board. It now alternates bank *and* row so that each
bank is revisited at the row the other one just opened, which is the access
per-bank tracking exists for and costs a row miss most of the time. The lower
number is the test doing its job.

Scenario 6 idles 250 ms and then re-reads 4,096 words. That is *not* proof
that refresh works: with refresh disabled outright this scenario still passed
on this board, because a cell at room temperature holds its charge for tens of
seconds. What enforces the refresh interval is the `tREFI` check in the core
testbench. See the [DE0-Nano Nios notes](../de0_nano_nios/README.md) for the
measurement.

## What it is, and what it is a copy of

This is the [DE10-Lite demonstration](../de10_lite_rtl/README.md) on a
different board and a different part. The sequencer, the master and the
scenarios are the *same files* — they live in [`../common`](../common/README.md)
and are shared, not copied. What changes here is the pinout, the clocking, the
address width and how the result is displayed.

## What is different, and why

| | DE10-Lite | DE0-Nano |
|---|---|---|
| Device | MAX 10 `10M50DAF484C7G` | Cyclone IV E `EP4CE22F17C6` |
| SDRAM | ISSI IS42S16320D-7, 64 MB | ISSI IS42S16160B-7, 32 MB |
| Column | 10 bits | **9 bits** |
| Word address | 25 bits | **24 bits** |
| tRC / tRAS / tRP / tRCD | 60 / 37 / 15 / 15 ns | **67.5 / 45 / 20 / 20 ns** |
| DRAM_CLK phase | −3000 ps | **−1667 ps** |
| Display | six 7-segment digits, 10 LEDs | **8 LEDs** |

None of those are cosmetic. The narrower column means a row holds half as many
words, so the scenarios that sweep a row or cross a bank move half as far —
which is why the sequencer takes `COL_BITS` rather than assuming 1024. The
slower row timings mean the row-changing scenarios genuinely take longer. And
the phase shift belongs to the board's layout: −1667 ps is Terasic's figure for
this one, and copying the DE10-Lite's −3000 would be a real mistake.

## Board controls

```
KEY[1]   reset
KEY[0]   start the selected scenario, or an auto sweep if SW[3] is up
SW[2:0]  scenario select, 0-7
SW[3]    auto: sweep every scenario in order

LED[7:0] pass bitmap, one bit per scenario
         - or all eight blinking together if the PLL has not locked
```

Eight LEDs and no digits, so the board shows the bitmap and nothing else.
Everything the DE10-Lite puts on its digits — scenario number, pass/fail,
failing address, cycle counters — is in the JTAG probe, which is what
`run_on_board.sh` reads in any case. The one state worth distinguishing on the
board itself is "the PLL has not locked", because then nothing else means
anything; it blinks rather than lighting a pattern, because any static pattern
is also a legal pass bitmap.

The DE10-Lite's `freeze` switch — stop an auto sweep at the first failure —
has no spare switch here and is reachable over JTAG only.

## Running the simulation

```bash
export QUARTUS_ROOT=/opt/intelFPGA/18.1     # first run only, to generate the system
./simulation/verilator/run_sim.sh
```

Current result: **61 checks passed, 0 failed, 0 timing violations, 0 illegal
device accesses** — the same nine phases as the DE10-Lite, against this part's
geometry and timings.

Generating the Platform Designer system needs `qsys-generate`, which is part of
a Quartus installation but needs no licence. After that it is Verilator alone.

## Building for the board

```bash
export QUARTUS_ROOT=/opt/intelFPGA/18.1
./build.sh qsys        # generate the Platform Designer system
./build.sh fpga        # synthesise, fit, time and assemble
./run_on_board.sh      # program and read the result over JTAG  (NOT DONE HERE)
```

`build.sh fpga` completes with 0 errors:

| | |
|---|---|
| Logic elements | 3,123 / 22,320 (14%) |
| Registers | 1,780 |
| Pins | 54 / 154 |
| Setup slack, 100 MHz system clock | **+1.011 ns** |
| Setup slack, SDRAM interface | +3.398 ns |
| f_MAX | 111.5 MHz |

## Pin assignments and constraints

Pin assignments come from `DE0_Nano.qsf` on the DE0-Nano System CD v1.2.8 and
were checked against the pin table in the DE0-Nano User Manual.

**One constraint here is an assumption, and it is flagged in the SDC.** Terasic
does not constrain the SDRAM interface on this board at all — their
`DE0_Nano.sdc` creates the clock, derives PLL clocks and uncertainty, and
stops. There is no generated clock on DRAM_CLK and no I/O delay on any DRAM
pin. So the device half of the constraints is derived from the IS42S16160B
datasheet on the board's own System CD, and the 0.4 ns trace delay is carried
over from the DE10-Lite because no DE0-Nano equivalent exists to take it from.
Confirm it against the board layout before trusting timing closure on hardware.

## A note on which Quartus drives the JTAG

Three tools touch the board, and they do not all come from the same install:

| Step | Which Quartus | Why |
|---|---|---|
| Programming, `jtagconfig`, `quartus_stp` | **25.1** (`JTAG_ROOT`) | The 18.1 JTAG server reads this board's chain only intermittently. `JTAG chain broken` appears from an unchanged, working setup, and a replug does not reliably fix it. The 25.1 stack reads it every time |
| `nios2-download` | **18.1** (`QUARTUS_ROOT`) | It shells out to `nios2-elf-objcopy`, and only 18.1 ships the Nios II GNU toolchain. The 25.1 one fails with `command not found` and still exits 0 |
| `nios2-terminal` | **25.1** (`JTAG_ROOT`) | The 18.1 terminal connects to the JTAG UART and then reads nothing at all - the program is running and printing, and the output never arrives |

The scripts here do this split for you. If you have only one installation, set
`JTAG_ROOT=$QUARTUS_ROOT` and expect the flakiness above.

This is the same split the firewall cores in this repository document, and it
was rediscovered the hard way here before their READMEs were consulted.

## Files

| Path | What it is |
|---|---|
| `qsys/build_system.tcl` | The system: clock source, controller, DE0-Nano preset |
| `rtl/de0_nano_sdram_demo.sv` | Top level: PLL, sequencer, master, LEDs, JTAG probes |
| `rtl/sdram_pll.sv` | 50 MHz in, 100 MHz plus the −1667 ps clock for the SDRAM pins |
| `../common/` | The sequencer, the master and the debouncer, shared with the other examples |
| `tb/de0_nano_sdram_demo_tb.sv` | Board-level testbench, nine phases |
| `simulation/verilator/run_sim.sh` | Generates the system if needed, builds, runs |
| `quartus/` | Project, pin assignments, timing constraints |
| `board/issp_run.tcl` | Reads the result over JTAG after programming |

The generated Platform Designer output is not committed: it is reproducible
from the component with `./build.sh qsys`.
