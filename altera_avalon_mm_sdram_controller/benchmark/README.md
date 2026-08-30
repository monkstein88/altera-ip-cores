# SDRAM controller benchmark

A ruler for memory controllers. It drives a controller with identical,
reproducible traffic and reports cycles and bytes, so two controllers can be
compared on numbers rather than on adjectives.

It exists because this project intends to replace the incumbent SDRAM
controller, and "faster" is not a claim you can make about a memory controller
without measuring it first.

## Results: the incumbent

`altera_avalon_new_sdram_controller` (Intel), 4096 operations per pattern,
ISSI IS42S16320D at 100 MHz, 16-bit bus, CAS 3. Theoretical peak 200 MB/s.

| Pattern | Cycles | MB/s | % of peak | Integrity |
|---|---|---|---|---|
| seq write | 4,217 | 194.3 | 97.1% | ok |
| seq read | 4,222 | 194.0 | 97.0% | ok |
| seq read/write | 37,329 | 21.9 | 11.0% | ok |
| **same-row rd/wr** | 37,332 | 21.9 | 11.0% | ok |
| bank stride | 37,351 | 21.9 | 11.0% | ok |
| random | 37,209 | 22.0 | 11.0% | ok |

0 data errors, 0 timing violations.

The first two rows reproduce the 194 MB/s the SDRAM example measures on
hardware, which is the check that this harness is measuring the right thing.

## What the fourth row says

**`same-row rd/wr` is the finding.** Every access is inside a single open row,
so no ACTIVATE or PRECHARGE is needed between them — the only thing changing is
the direction. Throughput still collapses to 21.9 MB/s, identical to fully
random access.

So the 8.9× gap between best and worst case is **not** row thrashing. It is the
read/write turnaround being handled as a full row cycle.

That is visible in the incumbent's RTL, where the fast path requires the
direction to match:

```verilog
assign pending = csn_match && rnw_match && bank_match && row_match && !f_empty;
//                            ^^^^^^^^^
```

Any direction change falls out of the fast path into PRECHARGE → tRP →
ACTIVATE → tRCD, roughly 6–8 dead cycles. The device datasheet says this is
unnecessary within an open row:

> *"data for a fixed-length WRITE burst may be **immediately followed** by a
> subsequent READ command"* — write→read costs 0 cycles
>
> *"at least a **single-cycle delay** should occur between the last read data
> and the WRITE command"* — read→write costs 1 cycle

`bank stride` says the same thing from the other side: walking banks while
staying in one row per bank should be free with four tracked rows, and costs
full row cycles with one.

Sequential is at 97% of the bus and has nothing left to give. **The headroom is
entirely in mixed and scattered traffic.**

## Files

| File | Purpose |
|---|---|
| `sdram_traffic_gen.sv` | Avalon-MM master: six access patterns, cycle counting, address-derived data integrity check |
| `sdram_bench_tb.sv` | Top level — generator → DUT → memory model; prints the table |
| `sdram_timing_check.sv` | JEDEC timing checker bound to the SDRAM command bus |
| `gen_dut.sh` | Generates the incumbent controller via `qsys-generate` |
| `gen_mem_model.sh` | Generates Intel's functional memory model |
| `run_bench.sh` | Generates what is missing, builds, runs |

Intel's controller RTL and memory model are generated, never committed — the
same rule the SDRAM example follows, and the reason `.gen/` is gitignored.

## Running

```bash
export QUARTUS_ROOT=/opt/intelFPGA/18.1     # needs Quartus for the generators
./run_bench.sh                              # measure the incumbent
./run_bench.sh my_ctrl path/to/my_ctrl.v    # measure a replacement
```

Verilator only; no licence required for the simulation itself.

## Why the timing checker is not optional

Intel's memory model is *functional*. Its own generator script says it does not
model tRCD, tRP, tRC, tRAS, tRRD or tWR, does not enforce the refresh interval,
and does not model retention — PRECHARGE and AUTO REFRESH are decoded and then
ignored.

A controller can therefore violate every timing parameter on the part and still
return perfectly correct data in this benchmark. On silicon that is
intermittent corruption at temperature, months later.

`sdram_timing_check.sv` closes that hole. It watches the command bus, tracks
per-bank state, and checks tRC, tRAS, tRP, tRCD, tRRD, tWR and tMRD against the
same nanosecond parameters the controller is configured with — deriving cycles
itself with ceiling division, so it cannot inherit an arithmetic error from the
thing it is checking. It also rejects structural mistakes: a column command to
a closed bank, an ACTIVATE to an already-open one, a refresh with a bank open.

**Verified by fault injection.** Telling the checker the part needs a 100 ns
tRCD makes it report the incumbent's legal 2-cycle delay as a violation:

```
TIMING VIOLATION  tRCD (ACT->RD/WR)  bank 0: 2 cycles elapsed, 11 required
```

which also confirms the incumbent issues its column command exactly tRCD
(15 ns → 2 cycles at 100 MHz) after ACTIVATE.

## Measurement notes

- The cycle counter starts on the **first accepted command**, so the
  controller's 200 µs power-on sequence is not charged against it.
- Writes are posted. A short write run measures the controller's input FIFO
  rather than the memory; 4096 operations is enough that steady state
  dominates. Raise `N_OPS` if you change the controller's buffering.
- Every read pattern is preceded by an unmeasured **priming pass** over the
  identical address sequence, so reads find known contents. Without it the
  integrity check compares against memory nobody wrote.
- Read data is checked against an address-derived value, so a controller that
  returns wrong data quickly cannot score well.
