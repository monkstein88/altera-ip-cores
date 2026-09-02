# DE0-Nano demonstration — Nios II

A Nios II system with this project's SDRAM controller in it, running a memory
test out of on-chip RAM and reporting over the JTAG UART.

This is the [DE10-Lite Nios example](../de10_lite_nios/README.md) on a
different board and a different part — same software, same tests, resized to a
device with a third of the on-chip memory.

**Status: built — not yet run on hardware.** The Platform Designer system
generates, the software compiles, and Quartus 18.1.1 produces a bitstream that
closes 100 MHz. It has never been programmed into a part.

## Why this exists alongside the RTL example

The [RTL example](../de0_nano_rtl/README.md) drives the controller's Avalon-MM
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
| Four banks, one row each | the access this controller exists for |
| **Refresh retention** | data surviving a second of idle, over 120 full refresh periods |
| Full march | every word in the 32 MB device written and verified |

The three in bold are not in the RTL example. Byte enables and 32-bit access
need a CPU to generate them; refresh retention needs *real time* and real
silicon — no functional model forgets, which is why the simulation cannot
settle it and this is the test worth running on a board.

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
| Logic elements | 4,868 / 22,320 (22%) |
| Registers | 2,979 |
| Memory bits | 300,672 / 608,256 (49%) |
| Program | 16 KB, in 32 KB of on-chip RAM |
| Setup slack, 100 MHz system clock | **+0.945 ns** |
| Setup slack, SDRAM interface | +3.477 ns |

## This board is much tighter on memory, and it took two goes to fit

The EP4CE22 has **608,256 memory bits in 66 M9K blocks**, against the MAX 10
10M50's 1,677,312. The DE10-Lite version of this system does not fit here, and
the reason it does not is worth writing down because the first error message
points at the wrong thing.

* 128 KB of on-chip RAM plus 4 KB/2 KB caches needs 1,113,152 bits — 183% of
  the device. Obvious enough.
* Dropping to 64 KB brings it to 562,816 bits, **93% of the device** — and it
  still does not fit, with `Can't place all RAM cells`. The binding constraint
  is the *number* of blocks, not the total bits: a 32-bit-wide RAM uses one
  M9K per 256 words, so 64 KB claims 64 of the 66 and leaves nothing for the
  caches or the JTAG UART FIFOs.
* 32 KB uses half the blocks and fits with room to spare.

The program had to shrink too. 75 KB of newlib `printf` does not go in 32 KB,
so this BSP is built with the **small C library** and `-Os`, which brings it to
16 KB and leaves 14 KB for stack and heap. The reduced `printf` handles
`%d %u %x %s %c` and not floats, which is all the test uses.

## The throughput figures are not the controller's

The full march prints MB/s. Those numbers are **CPU-bound, not controller-bound**:
a Nios II/f executing a load, a compare and a branch per word cannot issue
accesses fast enough to saturate the memory. The controller's actual throughput
is in [`benchmark/`](../../benchmark/README.md), measured with a hardware
traffic generator that can.

What the march figure is good for is the *ratio* between the row-hit and
row-miss tests, which is a property of the controller and shows up clearly even
CPU-bound.

## Files

| Path | What it is |
|---|---|
| `qsys/build_system.tcl` | The system: CPU, on-chip RAM, JTAG UART, timer, PIO, and the controller |
| `rtl/de0_nano_nios_top.sv` | Board wrapper: PLL, reset sequencing, pins |
| `rtl/sdram_pll.sv` | 50 MHz in, 100 MHz plus the −1667 ps clock for the SDRAM pins |
| `software/main.c` | The memory test |
| `quartus/` | Project, pin assignments, timing constraints |
