# DE10-Lite demonstration — Nios II

A Nios II system with this project's SDRAM controller in it, running a memory
test out of on-chip RAM and reporting over the JTAG UART.

**Status: verified on hardware.** Programmed into a Terasic DE10-Lite and run
over USB: **10 checks, 10 passed**, including the two paths the RTL example
cannot reach — byte enables and 32-bit access through the width adapter — and
refresh retention over 8 MByte idled 12 s.

## What it printed on the board

```
 Avalon-MM SDRAM Controller - Nios II memory test
 64 MByte at 0x08000000, 33554432 16-bit words
=============================================================

  PASS  data bus: walking ones and zeros
        26 power-of-two addresses checked
  PASS  address bus: no aliasing across the whole device
  PASS  byte enables reach DQM: a byte write spares its neighbour
  PASS  32-bit access through the width adapter is coherent
  PASS  one row: write and read back a full row of columns
        1024 words written in 141 us
  PASS  row thrash: every access a row miss, data still correct
        row hit ~137 ns/word, row miss ~511 ns/word
  PASS  a row miss costs more per word than a row hit
  PASS  four banks at staggered rows: per-bank row tracking
        1024 words in 604 us
        idling 12 s over 8 MByte...
  PASS  refresh retention: 8 MByte survives 12 s of idle
        marching 33554432 words (64 MByte)...
  PASS  full march: every word in the device written and verified
        write 18 MB/s, read 13 MB/s
-------------------------------------------------------------
  checks passed : 10
  checks failed : 0
  *** ALL TESTS PASSED ***
```

**The application is built `-Os`, and that is not cosmetic.** It was not, at
first, while the DE0-Nano's was — the two examples share this source and are
compared against each other, so a different optimisation level makes the
comparison meaningless. At `-O0` this board reported 646 ns per row-hit word
against the DE0-Nano's 130, and 3 MB/s on the full march against 18. Same
controller, same clock, same Nios II/f with larger caches: the whole gap was
the compiler. With `-Os` it reports 137 ns/word, and the two boards agree.

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
| **Refresh retention** | 8 MByte idled 12 s - sized from a measured sweep, and proven to catch a disabled refresh |
| Full march | every word in the 64 MB device written and verified |

The three in bold are not in the RTL example. Byte enables and 32-bit access
need a CPU to generate them; refresh retention needs *real time* and real
silicon. The idle was sized by measurement on a DE0-Nano rather than by
reasoning about tREFI - see the
[DE0-Nano notes](../de0_nano_nios/README.md#the-retention-test-and-why-it-idles-for-twelve-seconds).

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
./run_on_board.sh     # program, download, run, report
```

**Quartus 18.1 is required**, for one specific reason: newer Quartus Standard
releases no longer ship the Nios II *processor* IP. In 25.1std the catalog
directory `ip/altera/nios2_ip` is empty, so Platform Designer cannot
instantiate `altera_nios2_gen2`. The SDRAM controller itself is unaffected —
only the CPU is missing.

Results:

| | |
|---|---|
| Logic elements | 5,264 / 49,760 (11%) |
| Registers | 3,003 |
| Memory bits | 1,113,152 / 1,677,312 (66%) |
| Program | 74 KB, in 128 KB of on-chip RAM |
| Setup slack, 100 MHz system clock | **+0.380 ns** |
| Setup slack, SDRAM interface | +2.042 ns |

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
