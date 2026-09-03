# DE0-Nano demonstration — Nios II

A Nios II system with this project's SDRAM controller in it, running a memory
test out of on-chip RAM and reporting over the JTAG UART.

This is the [DE10-Lite Nios example](../de10_lite_nios/README.md) on a
different board and a different part — same software, same tests, resized to a
device with a third of the on-chip memory.

**Status: verified on hardware.** Programmed into a Terasic DE0-Nano and run
over USB: **10 checks, 10 passed**, including the two paths the RTL example
cannot reach — byte enables and 32-bit access through the width adapter — and
refresh retention, which needs real silicon and real time. The transcript is
below.

## What it printed on the board

```
 Avalon-MM SDRAM Controller - Nios II memory test
 32 MByte at 0x08000000, 16777216 16-bit words
=============================================================

  PASS  data bus: walking ones and zeros
        25 power-of-two addresses checked
  PASS  address bus: no aliasing across the whole device
  PASS  byte enables reach DQM: a byte write spares its neighbour
  PASS  32-bit access through the width adapter is coherent
  PASS  one row: write and read back a full row of columns
        512 words written in 67 us
  PASS  row thrash: every access a row miss, data still correct
        row hit ~130 ns/word, row miss ~488 ns/word
  PASS  a row miss costs more per word than a row hit
  PASS  four banks at staggered rows: per-bank row tracking
        1024 words in 500 us
        idling 12 s over 8 MByte...
  PASS  refresh retention: 8 MByte survives 12 s of idle
        marching 16777216 words (32 MByte)...
  PASS  full march: every word in the device written and verified
        write 18 MB/s, read 13 MB/s
        (CPU-bound, not the controller's limit - see README)

-------------------------------------------------------------
  checks passed : 10
  checks failed : 0
  *** ALL TESTS PASSED ***
=============================================================
```

Ten checks against nine rows in the table below: row thrash contributes two,
the data comparison and the separate assertion that a miss costs more than a
hit.

The full march reads and writes all 16,777,216 words of the part — every row of
every bank — so a refresh that never reached one of them, or an address line
that aliased, has nowhere to hide.

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
| Four banks, staggered rows | the access this controller exists for - and, since it revisits a bank at the row another bank just opened, one a shared open-row register fails |
| **Refresh retention** | 8 MByte idled 12 s - proven to catch a disabled refresh, see below |
| Full march | every word in the 32 MB device written and verified |

The three in bold are not in the RTL example. Byte enables and 32-bit access
need a CPU to generate them; refresh retention needs *real time* and real
silicon - and, since the idle was measured and lengthened, it does. The
section below has the numbers.

## The retention test, and why it idles for twelve seconds

Measured, not assumed. The controller was rebuilt with **refresh disabled
outright** - the refresh timer never fires, so no AUTO REFRESH command is ever
issued - and programmed into the DE0-Nano. With the test as it originally
stood, 4096 words idled for one second, **every scenario still passed**,
including retention.

Sweeping the idle and the region size gave the shape of it:

| Idle | 4096 words (8 KB) | 4 M words (8 MB) |
|---|---|---|
| 1 s | 0 wrong | 0 wrong |
| 2 s | 0 wrong | 0 wrong |
| 4 s | - | 0 wrong |
| 5 s | 0 wrong | - |
| 8 s | - | **29 wrong** |
| 10 s | 0 wrong | - |
| 20 s | **2 wrong** | - |

A DRAM cell at room temperature holds its charge for tens of seconds. The
64 ms refresh period in the datasheet is a worst-case guarantee over the full
temperature and process range, not a description of a part sitting on a desk.

More cells is a better lever than more time, because the retention
distribution has a long tail: 8 MByte fails at 8 s where 8 KByte survives to
20. So the test now writes **8 MByte and idles 12 s**, which has margin over
the point where loss first appears and still leaves the whole run under half a
minute.

**It now bites.** With refresh disabled the same build reports:

```
        word 1556 lost after idle: 0xa372, expected 0xa332
  FAIL  refresh retention: 8 MByte survives 12 s of idle
```

One flipped bit in one word - which is what charge loss looks like, and what
the old test was 20x too short to see.

What this does *not* do is police the refresh **interval**. No retention test
can: an interval that is merely wrong rather than absent leaves every cell
comfortably inside its retention time. That is the job of the `tREFI` check in
the core testbench, which fails all thirteen configurations immediately.

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
| Logic elements | 5,057 / 22,320 (23%) |
| Registers | 2,987 |
| Memory bits | 300,672 / 608,256 (49%) |
| Program | 16 KB, in 32 KB of on-chip RAM |
| Setup slack, 100 MHz system clock | **+0.957 ns** |
| Setup slack, SDRAM interface | +3.477 ns |

From a clean `./build.sh`. Two clean builds of these same sources gave +0.957
and +1.201 ns, so read the slack as "about a nanosecond", not as a constant -
regenerating the Platform Designer system reshuffles the fit.

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
| `rtl/de0_nano_nios_top.sv` | Board wrapper: PLL, reset sequencing, pins |
| `rtl/sdram_pll.sv` | 50 MHz in, 100 MHz plus the −1667 ps clock for the SDRAM pins |
| `software/main.c` | The memory test |
| `quartus/` | Project, pin assignments, timing constraints |
