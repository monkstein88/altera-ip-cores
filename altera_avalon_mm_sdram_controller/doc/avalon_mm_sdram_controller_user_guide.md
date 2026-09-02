# Avalon-MM SDRAM Controller — User Guide

**Core version 1.0 · Document version 1.0 · August 2026**

An SDR SDRAM controller for Avalon-MM that keeps one open row per bank, and a
drop-in replacement for the SDRAM Controller Intel FPGA IP.

The companion document is
[Block Diagrams and Descriptions](avalon_mm_sdram_controller_block_diagrams.md).

## Contents

1. About this core
2. Getting started
3. Functional description
4. Parameters
5. Signals
6. Address map
7. Performance
8. Verification
9. Limitations and known gaps
10. Revision history

---

# 1. About this core

## 1.1 Features

- **One open row per bank.** Four rows held open at once rather than one, so an
  access that changes bank costs no row command.
- **Read/write turnaround without a row cycle.** 0 cycles write→read, CAS+1
  read→write, as the device datasheet describes.
- **Look-ahead row activation.** The row for the *next* buffered access is
  opened or closed while the current one is still being served.
- **Postponed refresh.** Up to `REF_MAX_PEND` refreshes are deferred to a
  quiet moment, then forced through.
- **Parameterised in time, not cycles.** Device timings are picoseconds;
  cycles are derived inside the HDL.
- **Drop-in.** Same `s1` slave, same `wire` conduit, same default address map
  as the core it replaces.

## 1.2 What it is for

Mixed and scattered traffic — which is what a CPU generates. Sequential
streaming was already at 97% of the bus limit before this core existed and is
not where the headroom was. See section 7.

## 1.3 Status

**Verified in simulation, synthesised, and closing timing — but never run on a
board.** The core compiles through Quartus 18.1.1 Standard for the DE10-Lite's
MAX 10, fits, meets a 100 MHz constraint with 0.208 ns of setup slack, and
produces a bitstream. It has not been programmed into a part. Resource and
f_MAX figures are in section 7.4 and are reproducible.

---

# 2. Getting started

## 2.1 Adding the component

Add the repository to the IP search path — **Tools ▸ Options ▸ IP Search
Path**, or `--search-path` on the command line — and the component appears in
the IP Catalog under **Memory Interfaces and Controllers / Custom** as
*Avalon-MM SDRAM Controller (per-bank rows)*.

## 2.2 Start from a preset

Select the preset for your part rather than typing timings in:

```tcl
add_instance sdram altera_avalon_mm_sdram_controller
apply_preset sdram "ISSI IS42S16320D-7 - DE10-Lite 64 MByte"
```

A preset carries the geometry, the timings and the refresh figures for one
device, taken from its datasheet once. Two are supplied:

| Preset name | Part | Size | Banks x rows x cols x bits |
|---|---|---|---|
| `ISSI IS42S16320D-7 - DE10-Lite 64 MByte` | IS42S16320D-7 | 64 MB | 4 x 8192 x 1024 x 16 |
| `ISSI IS42S16160B-7 - DE0-Nano 32 MByte` | IS42S16160B-7 | 32 MB | 4 x 8192 x 512 x 16 |

Only parts whose timing has been checked against a datasheet *and* exercised
through `benchmark/` and the testbench are supplied; adding one is a block of
XML in `altera_avalon_mm_sdram_controller.qprs`. Because a preset is a
datasheet transcribed, both are held in place from two directions:
`doc/tools/check_facts.py` compares each preset against the copy the benchmark
and testbench carry, and the regression simulates each part's geometry and
timings rather than only linting them.

> **Caution:** There is deliberately no "generic SDRAM" preset. A timing
> constant that is one speed grade optimistic produces a design that passes
> every simulation, works on the bench, and corrupts data once the board is
> warm.

## 2.3 Connecting it

| Interface | Connect to |
|---|---|
| `clk`, `reset` | Your clock source. **The clock rate is read from it**, so no frequency is typed in anywhere |
| `s1` | The master, or the interconnect |
| `wire` | Export to the top level, and constrain the SDRAM pins |

## 2.4 What is checked at generation time

The component refuses, or warns about, four configurations that would otherwise
build and be wrong on hardware:

| Condition | Result |
|---|---|
| `SA_BITS` too small for `ROW_BITS`, or below 11 | Error |
| tRAS longer than tRC, or tRRD longer than tRC | Error |
| A refresh interval the controller cannot sustain | Error |
| `ADDR_MAP` set to conventional | Warning — every address moves |

It also reports the memory size and the exact cycle counts the HDL will derive
at your clock, so they can be read against the datasheet:

```
Info: Memory: 64 MByte - 4 banks x 8192 rows x 1024 columns x 16 bits.
Info: At 143.000 MHz the HDL will use: tRC=9 tRAS=6 tRP=3 tRCD=3 tRRD=3
      tWR=3 tRFC=9 cycles, CAS=3, one refresh every 1118 cycles.
```

---

# 3. Functional description

## 3.1 Initialisation

After reset the controller holds `za_waitrequest` high and runs the JEDEC
power-up sequence: wait `T_INIT_US`, PRECHARGE ALL, `INIT_REFS` AUTO REFRESH
commands, then LOAD MODE REGISTER. Only then is a transfer accepted.

The mode register is written with burst length 1, sequential burst type, and
the configured CAS latency.

## 3.2 Serving a transfer

One command is issued per cycle, chosen in priority order — see Figure 3 in the
block-diagram document. In summary: serve the head if its row is open, close
the row if it is the wrong one, open the bank if it is closed, otherwise
prepare the next access.

## 3.3 Read/write turnaround

A READ issued at cycle *T* has the device driving DQ at *T+CAS*. A WRITE drives
DQ in its own cycle, so the earliest safe write is *T+CAS+1*. The other
direction is free — the datasheet permits write data to be immediately followed
by a READ command.

This is why mixed traffic settles at about 79 MB/s rather than 194: a
write/read pair costs five cycles at CAS 3, and two accesses per five cycles is
80 MB/s. That is the device, not the scheduler.

## 3.4 Refresh

A timer accumulates outstanding refreshes at the interval implied by
`REF_ROWS` and `REF_PERIOD_MS`. They are issued when the command buffer is
empty, or forced once `REF_MAX_PEND` have accumulated. A refresh precharges
every bank, so all open rows are lost and reopened as needed.

## 3.5 Byte enables

`az_be_n` is active low and is driven onto `zs_dqm` for writes. DQM is held low
at all other times, which satisfies the SDR read-output enable requirement.

---

# 4. Parameters

## 4.1 Geometry

| Parameter | Type | Default | Range | Description |
|---|---|---|---|---|
| `DATA_BITS` | Integer | 16 | 8, 16, 32 | SDRAM data bus width. One DQM bit per byte lane |
| `ROW_BITS` | Integer | 13 | 10:15 | Row address width |
| `COL_BITS` | Integer | 10 | 8:11 | Column address width. Column bit 10 steps over A10 |
| `BANK_BITS` | Integer | 2 | 1, 2, 3 | Bank address width. Also how many rows can be open at once |
| `SA_BITS` | Integer | 13 | 11:15 | Address pins on the device. At least `ROW_BITS`, and at least 11 |
| `ADDR_W` | Integer | 25 | derived | Avalon word address width — row + column + bank. Do not override |

## 4.2 Device timing

Given in **picoseconds** in the HDL and in **nanoseconds** in Platform
Designer, which scales them. See section 4.5 for why.

| Parameter | Default | Description |
|---|---|---|
| `T_RC_PS` | 60 000 | ACTIVATE to ACTIVATE, same bank |
| `T_RAS_PS` | 37 000 | ACTIVATE to PRECHARGE, same bank |
| `T_RP_PS` | 15 000 | PRECHARGE to ACTIVATE, same bank |
| `T_RCD_PS` | 15 000 | ACTIVATE to READ or WRITE |
| `T_RRD_PS` | 14 000 | ACTIVATE to ACTIVATE, different bank |
| `T_WR_PS` | 14 000 | Write recovery: last write data to PRECHARGE |
| `T_MRD_PS` | 14 000 | LOAD MODE REGISTER to next command |
| `T_RFC_PS` | 60 000 | AUTO REFRESH to next ACTIVATE or REFRESH |
| `CAS_LAT` | 3 | CAS latency, 2 or 3 |

## 4.3 Initialisation and refresh

| Parameter | Default | Range | Description |
|---|---|---|---|
| `T_INIT_US` | 100 | 1:10000 | Power-up wait before the first command, microseconds |
| `INIT_REFS` | 8 | 2:15 | AUTO REFRESH commands during initialisation |
| `REF_ROWS` | 8192 | 512:32768 | Rows the device refreshes per period |
| `REF_PERIOD_MS` | 64 | 1:1000 | Refresh period, milliseconds |
| `REF_MAX_PEND` | 8 | 1:8 | Refreshes that may be postponed. 1 refreshes immediately |

## 4.4 Controller options

| Parameter | Default | Range | Description |
|---|---|---|---|
| `CLK_KHZ` | 100 000 | derived | Taken from the connected clock source. Every timing is converted against it |
| `ADDR_MAP` | 0 | 0, 1 | 0 = compatible with the Intel core, 1 = conventional `{row, bank, column}` |
| `FIFO_DEPTH` | 8 | 2, 4, 8, 16, 32 | Buffered commands. Also what look-ahead looks into |
| `LOOKAHEAD` | 1 | 0, 1 | Open or close the next access's row early |
| `RD_EXTRA_LAT` | 0 | 0:3 | Extra read-capture delay. Zero is correct for a direct connection |

## 4.5 Why picoseconds, and why not cycles

Cycle counts are deliberately not exposed. A timing parameter rounded the wrong
way is silent data corruption at temperature months later, not a clean failure,
and pushing that arithmetic onto every integrator guarantees someone gets it
wrong.

Picoseconds rather than a `real` number of nanoseconds because **Platform
Designer emits a FLOAT parameter into the generated Verilog as a quoted
string** — `.T_RC_NS("60.0")`. Assigned to a `parameter real`, that string is
its ASCII bytes read as a number: 60.0 arrives as 909127216.0, and a 6-cycle
tRC becomes 90 million. Integers cross the tool boundary intact.

> **Caution:** If you add a parameter to this core, check the generated wrapper
> and confirm it arrives unquoted.

---

# 5. Signals

20 ports.

## 5.1 Clock and reset

| Signal | Direction | Width | Description |
|---|---|---|---|
| `clk` | Input | 1 | All logic is in this domain |
| `reset_n` | Input | 1 | Asynchronous assert, synchronous deassert |

## 5.2 `s1` — Avalon-MM slave

Word-addressed, `isMemoryDevice`, variable read latency with `readdatavalid`.

| Signal | Direction | Width | Avalon role |
|---|---|---|---|
| `az_addr` | Input | `ADDR_W` | `address` (words) |
| `az_be_n` | Input | `DATA_BITS/8` | `byteenable_n` |
| `az_cs` | Input | 1 | `chipselect` |
| `az_data` | Input | `DATA_BITS` | `writedata` |
| `az_rd_n` | Input | 1 | `read_n` |
| `az_wr_n` | Input | 1 | `write_n` |
| `za_data` | Output | `DATA_BITS` | `readdata` |
| `za_valid` | Output | 1 | `readdatavalid` |
| `za_waitrequest` | Output | 1 | `waitrequest` |

## 5.3 `wire` — SDRAM conduit

| Signal | Direction | Width |
|---|---|---|
| `zs_addr` | Output | `SA_BITS` |
| `zs_ba` | Output | `BANK_BITS` |
| `zs_cas_n` | Output | 1 |
| `zs_cke` | Output | 1 |
| `zs_cs_n` | Output | 1 |
| `zs_dq` | Bidir | `DATA_BITS` |
| `zs_dqm` | Output | `DATA_BITS/8` |
| `zs_ras_n` | Output | 1 |
| `zs_we_n` | Output | 1 |

---

# 6. Address map

See Figure 4. At the default geometry, `ADDR_MAP 0` gives
`bank = {addr[24], addr[10]}`, `row = addr[23:11]`, `column = addr[9:0]`.

The Avalon address is a **word** address, matching the core this replaces, so a
system's existing address assignments carry over unchanged.

---

# 7. Performance

Measured on `benchmark/`, identical stimulus, both controllers. ISSI
IS42S16320D at 100 MHz, 16-bit bus, CAS 3, 4096 operations per pattern.
Theoretical peak 200 MB/s.

| Pattern | Intel's core | This core | Speedup |
|---|---|---|---|
| seq write | 194.3 | 198.3 | 1.02× |
| seq read | 194.0 | 196.1 | 1.01× |
| seq read/write | 21.9 | 78.9 | 3.6× |
| same-row rd/wr | 21.9 | 78.9 | 3.6× |
| bank+row walk | 21.9 | 65.5 | 3.0× |
| **4-bank same row** | 21.9 | **194.7** | **8.9×** |
| random | 22.0 | 44.5 | 2.0× |

0 data errors, 0 timing violations, both controllers.

Sequential streaming was already finished and is essentially unchanged. The
gain is entirely in mixed and scattered traffic.

> **Note:** These are simulation figures. The first two rows reproduce the
> 194 MB/s the SDRAM example measured on hardware, which is the check that the
> harness measures the right thing — but no figure in this table has itself
> been observed on a board.

## 7.4 Resources and f_MAX

Quartus 18.1.1 Standard, MAX 10 `10M50DAF484C7G`, Slow 1200 mV 85 °C model.
Both controllers synthesised standalone under the same constraints.

| | Intel's core | This core |
|---|---|---|
| Logic elements | 353 | 1,345 |
| Registers | 225 | 787 |
| f_MAX | 115.2 MHz | 104.8 MHz |

The complete DE10-Lite demonstration — this controller plus sequencer, master,
PLL, seven-segment displays and JTAG probes — occupies 3,099 logic elements and
1,778 registers, 6% of the device, and closes its 100 MHz constraint with
0.208 ns of setup slack. The SDRAM interface paths close with 1.763 ns. The
DE0-Nano demonstration, on a Cyclone IV E, occupies 3,123 logic elements and
closes with 1.011 ns.

> **Caution:** the throughput table in 7.3 assumes 100 MHz for both
> controllers. Cycle counts are a property of the scheduler; megabytes per
> second are not. This core reaches 104.8 MHz and the core it replaces reaches
> 115, so the ratios hold at 100 MHz and below and stop holding above it. A
> system already running Intel's controller above 104.8 MHz cannot substitute
> this one without lowering its clock.

The critical path is the loop from the registered command-buffer head, through
the scheduler's priority chain, through the pop decision, and back into that
register. Buffering the FIFO output is what made 100 MHz reachable at all: with
the head taken combinationally from the array, the multiplexer and the entire
priority chain shared one cycle, and f_MAX was 83 MHz.

---

# 8. Verification

| Flow | What it covers | Status |
|---|---|---|
| `simulation/verilator/run_sim.sh` | Lint of RTL, checker and model; timing-checker self-test; testbench across 13 configurations including three clock rates and both supplied parts; lint in 4 geometries; Quartus Analysis & Synthesis | **22 checks, 2158 testbench assertions, passing** |
| `tb/avalon_mm_sdram_controller_tb.sv` | 166 checks per configuration, asserting on the command stream as well as the data | Passing |
| `tb/avalon_mm_sdram_controller_sva.sv` | Avalon protocol, command legality, DQ contention, row bookkeeping | Passing |
| `tb/sdram_timing_check.sv` | tRC, tRAS, tRP, tRCD, tRRD, tWR, tMRD, tRFC, read-to-write turnaround, refresh interval | Passing, with a 23-check threshold self-test |
| `benchmark/` | Throughput against the core being replaced | Passing |
| `example/de10_lite_rtl` | Board-level demonstration, 9 phases | 61 checks passing in simulation |
| `simulation/questa/run_sim.tcl` | Coverage and assertion non-vacuity, same 13 configurations | 22 assertion instances, **none vacuous**, 100% FSM state and transition |
| Quartus | Synthesis, fit, timing closure, bitstream | 100 MHz met with 1.011 ns slack (DE0-Nano), 0.208 ns (DE10-Lite) |
| Hardware | Retention and refresh on silicon | **Not run — no board** |

## 8.1 The testbench checks the mechanism, not only the data

A controller that closed and reopened a row before every access would return
correct data and pass any integrity check. So the testbench counts commands:
four banks with one row open each, accessed in rotation, is asserted to cost
exactly four ACTIVATEs and zero PRECHARGEs.

## 8.2 Proven by fault injection

Six faults were introduced into the controller and each was caught by the layer
meant to catch it:

| Fault | Caught by |
|---|---|
| Byte enables ignored | Directed test |
| Read/write turnaround removed | SVA |
| tRCD gate removed | Timing checker |
| ACTIVATE forgets its row | SVA |
| Refresh never forced under load | SVA |
| Read data captured a cycle late | Directed test |

---

# 9. Limitations and known gaps

| Limitation | Detail |
|---|---|
| **Never run on hardware** | The design synthesises, fits, meets timing and produces a bitstream, but has not been programmed into a part. Retention and refresh on silicon are unproven |
| **No bursting** | The slave is non-bursting; every transfer is one word. Bursts would amortise the read/write turnaround and are the main remaining performance work |
| **No reordering** | Transfers are served in order. A reorder buffer grouping same-direction accesses is the other half of that work |
| **One chip select** | Multi-device configurations are not supported |
| **Single clock domain** | No clock-crossing on the slave port |
| **Two device presets** | The DE10-Lite's IS42S16320D-7 and the DE0-Nano's IS42S16160B-7. Others need datasheet figures |
| **f_MAX headroom is thin** | 104.8 MHz standalone against a 100 MHz target. The critical path now starts at the tRC counter and runs through `act_ok_v` and the priority chain into the row bookkeeping; the counters could be given registered reaches-zero flags the way the row match already has one, and beyond that shortening the chain means splitting it across two cycles |

---

# 10. Revision history

| Document version | Core version | Date | Change |
|---|---|---|---|
| 1.0 | 1.0 | August 2026 | First release |
