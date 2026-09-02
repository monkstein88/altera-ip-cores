# DE10-Lite demonstration — Nios II

A Nios II system with this project's SDRAM controller in it, running a memory
test out of on-chip RAM and reporting over the JTAG UART.

**Status: built — not yet run on hardware.** The Platform Designer system
generates, the software compiles, and Quartus 18.1.1 produces a bitstream that
closes 100 MHz. It has never been programmed into a part.

## Why this exists alongside the RTL example

The [RTL example](../de10_lite_rtl/README.md) drives the controller's Avalon-MM
slave from a hardware sequencer: no CPU, no interconnect, nothing in between,
one 16-bit word at a time. That is the right shape for measuring the
controller, and it is what the benchmark numbers come from.

This one is the shape most people will actually use it in:

* a **Nios II/f with caches**, so the controller sees bursts of a cache line
  rather than isolated words;
* Platform Designer's **interconnect** in the path;
* the **32-to-16 bit width adapter** Qsys inserts, because the CPU is a 32-bit
  master and this slave is 16 bits wide;
* **byte, half-word and word** accesses from C.

Those are the paths where a byte-enable or read-latency mistake shows up as
"the memory works, but not from software". The RTL example cannot reach them —
its sequencer only ever issues 16-bit accesses.

## What the software tests

Nine tests, mirroring the RTL example's scenarios so the two can be compared,
plus three that only a CPU can do:

| Test | What it catches |
|---|---|
| Data bus | a DQ line stuck, open, or shorted to its neighbour |
| Address bus | two address lines swapped, or one stuck — every power-of-two offset across the whole device |
| **Byte enables** | DQM not reaching the chip: a byte write that disturbs its neighbour |
| **32-bit access** | the width adapter putting the two half-words in the wrong order |
| One row | the fastest case — column moves, row and bank do not |
| Row thrash | the worst case — a row miss on every access, compared against the row-hit cost |
| Four banks, staggered rows | the access this controller exists for - and, since it revisits a bank at the row another bank just opened, one a shared open-row register fails |
| **Refresh retention** | data surviving a second of idle, over 120 full refresh periods |
| Full march | every word in the 64 MB device written and verified |

The three in bold are not in the RTL example. Byte enables and 32-bit access
need a CPU to generate them; refresh retention needs *real time* and real
silicon. That was the intent; measurement on the DE0-Nano says the idle is far
too short to detect even a completely disabled refresh - see the
[DE0-Nano notes](../de0_nano_nios/README.md#what-the-board-does-not-prove-the-retention-test-is-too-short).

## Two things the system does on purpose

**Code does not run from the SDRAM.** The reset and exception vectors, the code
and the stack are all in on-chip RAM. A memory test executing out of the memory
it is testing cannot report a failure it has just caused.

**The cache is flushed between every write pass and read pass.** A write
followed by a read of the same address can be answered entirely from the data
cache, which proves nothing about the SDRAM. The tests that are about the wires
— data bus, address bus, byte enables — use the uncached alias instead. Getting
this wrong makes a broken controller look perfect, so `main.c` says which it is
using at each call site rather than leaving it to be assumed.

## Building

```bash
export QUARTUS_ROOT=/opt/intelFPGA/18.1
./build.sh            # everything: system, bitstream, BSP, application
./build.sh qsys       # just the Platform Designer system
./build.sh sw         # just the BSP and the application
./build.sh fpga       # just the Quartus compile
./run_on_board.sh     # program, download, run, report   (NOT DONE HERE)
```

**Quartus 18.1 is required**, for one specific reason: newer Quartus Standard
releases no longer ship the Nios II *processor* IP. In 25.1std the catalog
directory `ip/altera/nios2_ip` is empty, so Platform Designer cannot
instantiate `altera_nios2_gen2`. The SDRAM controller itself is unaffected —
only the CPU is missing.

Results:

| | |
|---|---|
| Logic elements | 5,091 / 49,760 (10%) |
| Registers | 3,003 |
| Memory bits | 1,113,152 / 1,677,312 (66%) |
| Program | 75 KB, in 128 KB of on-chip RAM |
| Setup slack, 100 MHz system clock | **+0.742 ns** |
| Setup slack, SDRAM interface | +2.423 ns |

This used to close with 0.135 ns, which was thin enough to warn about: the CPU
and its caches share a clock with the controller, and the controller was the
critical path at 101 MHz on its own. Registering the controller's row match
moved it to 104.8 MHz and this system to 0.742 ns — see the core
[README](../../README.md#cost-and-speed). There is real margin now, but the
controller is still what will run out of it first if you add to this system.

## The throughput figures are not the controller's

The full march prints MB/s. Those numbers are **CPU-bound, not controller-bound**:
a Nios II/f executing a load, a compare and a branch per word cannot issue
accesses fast enough to saturate the memory. The controller's actual throughput
is in [`benchmark/`](../../benchmark/README.md), measured with a hardware
traffic generator that can.

What the march figure is good for is the *ratio* between the row-hit and
row-miss tests, which is a property of the controller and shows up clearly even
CPU-bound.

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
| `qsys/build_system.tcl` | The system: CPU, on-chip RAM, JTAG UART, timer, PIO, and the controller |
| `rtl/de10_lite_nios_top.sv` | Board wrapper: PLL, reset sequencing, pins |
| `rtl/sdram_pll.sv` | 50 MHz in, 100 MHz plus the −3 ns clock for the SDRAM pins |
| `software/main.c` | The memory test |
| `quartus/` | Project, pin assignments, timing constraints |
