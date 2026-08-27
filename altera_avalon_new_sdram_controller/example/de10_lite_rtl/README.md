# SDRAM Controller — DE10-Lite RTL demonstration

A hardware demonstration of `altera_avalon_new_sdram_controller` driving the
**64 MB SDRAM on a Terasic DE10-Lite**, verified on the board.

There is **no CPU**. A hardware sequencer masters the controller's Avalon-MM
slave directly, so what is being measured is the controller and the memory —
no software, no cache, no interconnect in between.

```
  MAX10_CLK1_50 ──► PLL ──┬─► c0  100 MHz  0°      ──► everything on-chip
                          └─► c1  100 MHz −3000 ps ──► DRAM_CLK

  demo_sdram_seq ──► demo_avl_mm_master ──► sdram_sys (s1) ──► IS42S16320D
   (8 scenarios)      (Avalon-MM shim)      (the IP core)      (32M × 16)
```

## Result on hardware

All eight scenarios pass on a physical DE10-Lite, including a write-and-verify
pass over **every one of the 33,554,432 words** in the chip.

```
0 data bus walk        PASS      4 bank toggle          PASS
1 address bus walk     PASS      5 row thrash           PASS
2 byte enables         PASS      6 refresh retention    PASS
3 column sweep         PASS      7 full 64 MB march     PASS
```

Throughput, measured on silicon by counting clocks:

| scenario | words | write MB/s | read MB/s |
|---|---:|---:|---:|
| 3 column sweep — one bank, one row | 1,024 | 195.8 | 193.9 |
| 4 bank toggle — crosses `addr[10]` | 2,048 | 193.8 | 192.9 |
| 5 row thrash — a row miss every access | 256 | **22.2** | **21.7** |
| 7 full 64 MB march | 33,554,432 | **194.0** | **194.0** |

The theoretical peak is 16 bits × 100 MHz = 200 MB/s. Sequential access reaches
**194 MB/s — 97% of peak, 1.03 clocks per word**. Forcing a `PRECHARGE` and
`ACTIVATE` before every single access costs **8.7×**.

That gap is the single most useful number in this example: it is what a row
miss costs on this controller, measured rather than estimated.

---

## Quick start

```bash
./build.sh          # Platform Designer system, then Quartus
./run_on_board.sh   # program the board, then check it over JTAG
./build.sh sim      # simulate against a functional SDRAM model (58 checks)
```

`run_on_board.sh` exits 0 only if every scenario passes. Nobody has to look at
the board — see [Checking it over JTAG](#checking-it-over-jtag).

**Requires** Quartus 18.1 Standard (what this was built and verified with) and
a DE10-Lite on USB. Unlike this repository's Nios examples there is no CPU, so
a newer Quartus Standard that still supports MAX 10 should also work — but the
numbers above come from 18.1.

---

## The address map this demo is built around

The scenario sizes are not arbitrary. They come from the controller's real
address decode, which is **not** the `{bank, row, column}` layout most people
assume. Read out of the generated RTL:

```verilog
assign f_bank    = {f_addr[24], f_addr[10]};
assign row_match = active_addr[23:11] == f_addr[23:11];
assign cas_addr  = {3'b000, f_addr[9:0]};
```

So a 25-bit word address decomposes as:

| bits | meaning |
|---|---|
| `addr[24]` | bank[1] |
| `addr[23:11]` | row[12:0] |
| `addr[10]` | **bank[0]** — below the row, not above it |
| `addr[9:0]` | column[9:0] |

The consequence is worth stating plainly: **walking a linear address range does
not change row every 1024 words.** It changes *bank* at every 1024-word
boundary and only changes *row* every 2048 words.

Scenarios 3, 4 and 5 exist to exercise exactly those three cases and to time
them, which is why their lengths are 1024, 2048 and a stride of 2048.

---

## The scenarios

| # | name | what it proves |
|---|---|---|
| 0 | data bus walk | Walking 1s, walking 0s, all-zero and all-ones at one address, each written and read straight back. Catches a DQ line stuck, open, or shorted to its neighbour. |
| 1 | address bus walk | A distinct word at address 0 and at every power of two up to 2²⁴, written then read back. If two address lines are swapped or one is stuck, two of the 26 addresses collide and the check fails. |
| 2 | byte enables | Half-word writes that must leave the other half untouched — i.e. does DQM actually reach the chip. |
| 3 | column sweep | 1024 words in one bank and one row. Every access after the first is a row hit: the controller's fastest case. |
| 4 | bank toggle | 2048 words from 0, crossing `addr[10]` at word 1024 — same row index, other bank. |
| 5 | row thrash | 256 accesses at stride 2048. Every single one is a row miss in the same bank: `PRECHARGE`, `ACTIVATE`, one word. The worst case. |
| 6 | refresh retention | Write 4096 words, then touch nothing at all for **250 ms**, then read them back. Auto-refresh is the only thing keeping those cells alive across the gap. |
| 7 | full 64 MB march | Every one of 33,554,432 words written, then every one read back and checked. |

**Scenario 7 is the one that validates the geometry.** Get `rowWidth` or
`columnWidth` wrong in the `.qsys` and the address space folds back on itself —
which shows up here and nowhere else, because every other scenario touches too
little of the chip to notice.

### The expected data

Address-derived rather than an LFSR:

```verilog
patt(a) = a[15:0] ^ a[24:9] ^ 16'hA5A5
```

Two reasons. The read pass needs no state shared with the write pass, which is
what lets reads be issued pipelined and checked in order. And a single stuck or
shorted address line always shows up: if two addresses differ in exactly one
bit *k*, then *k*<9 changes the low term only, *k*>15 changes the high term
only, and 9≤*k*≤15 changes both — but at bit positions *k* and *k*−9, which are
never the same bit. The pattern differs in every case.

---

## Board controls

| control | meaning |
|---|---|
| `KEY[1]` | reset |
| `KEY[0]` | start the selected scenario, or an auto sweep if `SW[9]` is up |
| `SW[2:0]` | scenario select, 0–7 |
| `SW[9]` | auto — sweep every scenario in order from a cleared bitmap |
| `SW[8]` | freeze — in a sweep, stop at the first scenario that fails |
| `LEDR[7:0]` | pass bitmap, one bit per scenario |
| `LEDR[8]` | running |
| `LEDR[9]` | PLL locked |
| `HEX5` | scenario number |
| `HEX4` | `P` pass / `F` fail / `-` running |
| `HEX3:HEX2` | pass bitmap in hex |
| `HEX1:HEX0` | low byte of the first failing address; blank if nothing failed |

---

## Checking it over JTAG

The board reports on seven-segment displays, which a script cannot read, and it
counts clocks, which the displays have no room for. An **In-System Sources and
Probes** instance exposes both over the same USB cable used to program the
board, so the demo is regression-testable from a script and the throughput
comes out in MB/s.

```
probe[184:0] = { src_stable[7:0], perf_words[31:0], perf_rd_cycles[31:0],
                 perf_wr_cycles[31:0], fail_actual[15:0], fail_expected[15:0],
                 fail_addr[24:0], −, err_code[2:0], done_count[3:0],
                 pll_locked, running, result_valid, result_pass,
                 cur_scenario[3:0], pass_bitmap[7:0] }

source[7:0]  = { seq_reset, start, freeze, auto, select[3:0] }
```

Three of those fields exist specifically to make hardware testing honest:

- **`done_count`** increments once per completed scenario. A host starts a
  scenario and waits for this counter to *move*, rather than watching `running`
  go high and then low. A level has a race — read it a moment after the start
  pulse and it has not risen yet, so "not running" reads as "already finished"
  and the host takes the *previous* scenario's result. A monotonic counter has
  no such window.
- **`seq_reset`** (source bit 7) forces the sequencer back to idle from
  anywhere. A board that has somehow got stuck does not need re-programming to
  be usable again.
- **`src_stable`** is what the design is *actually acting on* after its input
  filter. Reading it back is how you tell "the board ignored me" from "the
  board did what I asked and the answer is genuinely wrong". See below.

The sequencer also carries a **watchdog**: `running` is derived from the state
register alone, and every scenario has a cycle budget. If one ever fails to
finish, the watchdog fails it and forces a return to idle. `running` can
therefore never stick.

---

## The altsource_probe hazard, and why the source word is filtered

This one is worth reading even if you never use this example, because it
applies to **any** `altsource_probe` where one bit qualifies the others.

`altsource_probe` shifts a new source value in over JTAG **one bit at a time**,
and with `enable_metastability = "NO"` those bits reach the fabric as they
land. There is no holding register between the scan chain and the design. For
a few microseconds the design sees source words that were never written: a
mixture of the old value and the new one.

Here, source bit 6 is a **start edge** and bits `[3:0]` choose **which scenario
to start**. If bit 6 rises while the select bits are still half-updated, the
wrong scenario runs — and the host, comparing against what it asked for, reads
back a result that looks like a hardware failure.

Measured directly on this board before the fix: **asking for scenario 4 ran
scenario 3**, intermittently, with the frequency depending on JTAG timing.

The fix is in RTL. The source word is filtered before anything uses it, exactly
the way `key_debounce` filters a mechanical button: a new value only counts
once it has held still for **256 consecutive clocks** (2.56 µs at 100 MHz) —
far longer than a JTAG update takes to settle, far shorter than any host
notices. See `src_stable` in `rtl/de10_lite_avl_mm_sdram_demo.sv`.

> This is also the root cause of the intermittent step-mode behaviour that
> [the Avalon-MM firewall's RTL demo](../../../altera_avalon_mm_firewall/example/de10_lite_rtl/README.md)
> previously recorded as unexplained. That example has the same construct and
> now carries the same fix; it went from roughly 50% failures to 6/6 clean
> runs.

---

## Simulation

```bash
./build.sh sim
```

58 checks, all passing, under Questa/ModelSim. The flow generates what it
needs, so there is nothing to download.

### Where the memory model comes from

Intel ships a functional SDRAM model generator — but **not** in the SDRAM
controller's own directory. It lives in a separate component,
`altera_sdram_partner_module`, under
`$QUARTUS_ROOT/ip/altera/alt_mem_if/alt_mem_if_mem_models/`.

That is worth knowing, because the controller's `generate_rtl.pl` calls a
`make_sodimm` routine that **is not in its directory and never was** — it is in
the partner module. Setting the controller's `generateSimulationModel`
parameter makes `qsys-generate` reach across and run it.

`simulation/gen_mem_model.sh` calls that generator directly with this board's
geometry, which is faster than regenerating the whole system and leaves the
tracked `.qsys` untouched. The output is Intel's, so it is **not committed** —
it is regenerated from your own Quartus installation, the same way the
controller's RTL is.

### What the model does and does not do

It is a **functional** model: a memory array behind a command decoder. It
decodes `LOAD MODE REGISTER` (picking up CAS latency), `ACTIVATE` (latching
row and bank), `READ` and `WRITE`, and pipelines read data by the CAS latency.

It does **not** model `tRCD`, `tRP`, `tRFC`, `tWR` or `tMRD`, does **not**
enforce the refresh interval, and does **not** model data retention.
`PRECHARGE` and `AUTO REFRESH` are decoded and then ignored.

So simulation proves the controller drives the right commands to the right
addresses and returns the right data. **It cannot tell you your timing
parameters are wrong** — and scenario 6 passes against it for free. The
testbench says so on the console rather than quietly counting it as a win.

If you need timing checks, use a vendor model — see *Vendor models* below.

### What the testbench checks

| phase | what |
|---|---|
| 1 | all 8 scenarios individually: finished, passed, self-reported correctly, `done_count` incremented exactly once |
| 2 | the word counts and cycle counts the block scenarios report |
| 3 | the data really is in the memory, read out of the model's array at the address the sequencer used |
| 4 | byte enables reached the chip — `0x1234` survives the half-word writes |
| 5 | **the documented address decode**, by watching which bank and row the controller `ACTIVATE`s during a known walk |
| 6 | **fault injection** — a word corrupted *between* the write pass and the read pass must be caught, at the right address, with the right expected and actual values |
| 7 | the auto sweep sets every bit of the bitmap |
| 8 | select masking, and `seq_reset` returning the machine to idle mid-run |
| 9 | **the watchdog** — with `waitrequest` held high forever, `running` must not stick |

Phases 5, 6 and 9 are the ones that carry weight. Phase 5 is direct evidence
for the address decode rather than taking the generated RTL's word for it.
Phase 6 exists because "all scenarios passed" is worthless if the comparison
is broken — the check has to be shown to fail when it should. Phase 9 proves
the design cannot wedge.

> **Simulation reproduces silicon cycle-for-cycle.** The write-pass cycle
> counts for scenarios 3, 4 and 5 come out as 1046, 2113 and 2311 in
> simulation — the same numbers measured on the board. The functional model
> gets the controller's *throughput* right even though it models no timing,
> because the controller's own state machine is what paces the transfer.

### Vendor models

If you want real timing checks — `$setuphold`, `$width`, and runtime `tRCD` /
`tRP` / `tRAS` / `tRFC` / `tWR` violations — you need a model from a memory
vendor. Three routes, in order of how easily they can actually be obtained:

1. **Micron** publishes Verilog models for its SDRAM parts, and they are the
   de-facto standard: full `specify` blocks and timing violation reporting.
   The DE10-Lite's part is 512 Mb organised 32M × 16, so the pin- and
   protocol-compatible Micron equivalent is the **MT48LC32M16A2**. These
   models carry a Micron copyright and an "AS IS" disclaimer, so they are
   fine to use locally but should not be committed here — the same reason
   Intel's generated output is not.
2. **ISSI** — the actual vendor of the part on this board. Their site offers
   models on the product pages, but it is behind bot protection; the reliable
   route is to email ISSI or their FAE department and ask for the Verilog
   model for the IS42S16320D.
3. Note the older Micron models state a known limitation of their own:
   *"Doesn't check for 8192 cycle refresh"* — so even a vendor model may not
   verify the refresh interval, which remains a hardware-only result.

Dropping one in is a matter of replacing the `sdram_mem_model` instance in
`tb/de10_lite_avl_mm_sdram_demo_tb.sv`. Note that this testbench is
zero-delay, so a timing-checking model will need its checks relaxed or the
testbench given real clock-to-out delays.

---

## Clocking, and the −3 ns that is not a tuning knob

The SDRAM needs two clocks: the controller runs on 100 MHz at 0°, and the chip
itself is clocked by the same 100 MHz shifted **3 ns early**.

Everything the FPGA drives towards the SDRAM leaves an output register clocked
by `c0` and then spends real time getting there — I/O clock-to-out, board
trace, and the chip's input setup window. If the SDRAM latched on the same edge
as `c0` it would sample those signals while they were still moving. Clocking
the chip early moves its sampling edge back to a point where the previous
cycle's outputs are long settled.

**−3000 ps is Terasic's value for this board**, used in both their
`SDRAM_Nios_Test` and `SDRAM_RTL_Test` demonstrations. It is a property of
*this board's layout*, not of the controller. On different hardware it has to
be re-derived.

Getting it wrong does not produce an obvious failure. The controller
initialises, accepts commands and returns data — the data is simply wrong,
intermittently, in a way that looks like a defective memory chip. Worth knowing
before blaming the IP.

### Why the PLL is in RTL and not in the Qsys system

ALTPLL's second clock output **cannot be enabled from a `qsys-script`**: writing
`PORT_clk1 = PORT_USED` is silently reverted by the megafunction's own
validation and reads back `PORT_UNUSED`, so `c1` never appears as an interface
that could be exported. Terasic's own RTL demo hits the same wall and puts its
PLL at the top level, which is what `rtl/sdram_pll.sv` does. The Qsys system
therefore takes a ready-made 100 MHz clock.

---

## Where the controller settings come from

Every geometry and timing value in `qsys/build_system.tcl` is taken from
Terasic's `SDRAM_Nios_Test` design on the DE10-Lite System CD, which drives the
same chip with the same Intel controller. They are not derived by hand from a
datasheet.

| | |
|---|---|
| part | ISSI IS42S16320D — 64 MB, 32M × 16 |
| geometry | 4 banks × 8192 rows × 1024 columns × 16 bits = 512 Mbit |
| `casLatency` | 3 |
| `refreshPeriod` | 7.8125 µs |
| `TAC` / `TRCD` / `TRFC` / `TRP` / `TWR` | 5.4 / 15.0 / 70.0 / 15.0 / 14.0 ns |
| `TMRD` | 3 |
| `powerUpDelay` | 100 µs, then 2 init refresh commands |

The **39 SDRAM pin assignments** in the `.qsf` are taken verbatim from
`DE10_LITE_Golden_Top.qsf` on the System CD v2.2.0. If your board is a
different revision, diff against that revision's Golden Top before the first
run — a wrong pin on a 3.3 V bank is the one mistake in that file that can
damage hardware.

### The timing constraints are real constraints

Unlike the firewall demos in this repository, this design is not purely
internal: sixteen data lines, thirteen address lines and six command lines
leave the FPGA and have to meet a real device's setup and hold windows. The
board delay figures in the `.sdc` come from Terasic's own DE10-Lite SDRAM
demonstration SDC and describe *this* board together with the IS42S16320D.

`DRAM_CLK` is constrained as a **generated clock leaving the device**, because
that is what it is — the SDRAM's windows are measured against it.

---

## Build results

Quartus 18.1.1 Standard, 10M50DAF484C7G (speed grade 7), worst-case model
(slow 1200 mV, 85 °C):

| | |
|---|---|
| Fmax, system clock | **116.58 MHz** against a 100 MHz requirement |
| Setup slack, system clock | +1.422 ns |
| Hold slack, system clock | +0.412 ns (+0.206 ns at the fast corner) |
| Setup slack, `clk_dram_ext` | +3.640 ns |
| Hold slack, `clk_dram_ext` | +2.886 ns (+2.469 ns at the fast corner) |
| Unconstrained clocks | 0 |
| Logic elements | 1,937 / 49,760 (4%) |
| Registers | 1,107 |
| Pins | 110 / 360 |
| PLLs | 1 / 4 |

The comfortable margin on `clk_dram_ext` is the −3 ns shift doing its job.

### One expected warning

```
Warning (15064): PLL output port clk[1] feeds output pin "DRAM_CLK~output"
via non-dedicated routing
```

`DRAM_CLK` on the DE10-Lite is not a dedicated PLL clock output pin, so this
warning is unavoidable on this board — Terasic's designs produce it too. The
timing analysis accounts for the actual routing delay, and the +3.6 ns setup /
+2.9 ns hold slack above is the answer that matters.

---

## Files

```
qsys/build_system.tcl      Platform Designer system: the controller, nothing else
tb/de10_lite_avl_mm_sdram_demo_tb.sv   board-level testbench, 58 checks
simulation/gen_mem_model.sh            generate Intel's functional SDRAM model
simulation/questa/run_sim.tcl          compile and run the testbench
rtl/sdram_pll.sv           ALTPLL: 50 → 100 MHz, plus the −3 ns DRAM_CLK
rtl/demo_avl_mm_master.sv  Avalon-MM shim (active-low read_n/write_n/byteenable_n)
rtl/demo_sdram_seq.sv      the eight scenarios, the checker, the cycle counters
rtl/de10_lite_avl_mm_sdram_demo.sv   top level, ISSP, board I/O
board/issp_run.tcl         drive and check the demo over JTAG
build.sh                   Qsys + Quartus
run_on_board.sh            program, then check; exit 0 only if everything passed
```

### Two things read out of the controller's generated RTL

Both are documented in `rtl/demo_avl_mm_master.sv`, and neither is obvious from
the interface:

1. **`chipselect` does not qualify the transaction.** The command FIFO is
   written on `(~az_wr_n | ~az_rd_n) & !za_waitrequest` — chip select is not in
   that term at all.
2. **Read data cannot be stalled.** `waitrequest` is wired straight to the
   command FIFO's `full` flag, so it is backpressure on the *command* side
   only. Whatever consumes `readdatavalid` must accept it in the cycle it
   appears. This is also why respecting `waitrequest` is the *only*
   outstanding-read limit a master needs here — there is no separate credit to
   track.

---

## What is and isn't verified

| Item | Status |
|---|---|
| **All 8 scenarios on a physical DE10-Lite** | **Passing** — including all 33,554,432 words written and verified |
| Determinism over JTAG | **5/5 consecutive runs** after the `src_stable` fix, no retries |
| Throughput figures | **Measured on silicon** by counting clocks, not estimated |
| Refresh retention | **Checked** — 4096 words survive 250 ms with no access at all |
| Timing closure at 100 MHz | **Checked** — Fmax 116.58 MHz, 0 unconstrained clocks, both corners |
| SDRAM pin assignments | **Diffed** against `DE10_LITE_Golden_Top.qsf` on the System CD v2.2.0 |
| Controller settings | **Taken from** Terasic's `SDRAM_Nios_Test` for the same chip |
| RTL simulation of the demo | **Passing** — 58/58 checks under Questa against Intel's generated functional model; see *Simulation* |
| Timing parameters (tRCD, tRP, tRFC, …) | **Not simulated** — the functional model does not check them. Hardware is what validates them |
