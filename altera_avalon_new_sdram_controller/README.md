# SDRAM Controller Intel FPGA IP

Intel's own SDRAM controller — an Avalon-MM slave that drives a single-data-rate
SDRAM chip — preserved here because Quartus stopped shipping it.

**This is not original work.** It is Intel's IP, redistributed under Intel's
terms, with two properties changed so it appears in the Platform Designer
catalog. See [`NOTICE`](NOTICE) for the licence and the modification, and the
repository [root README](../README.md#licence) for how it sits alongside the
MIT-licensed cores.

> **There is now a from-scratch replacement for this core** in
> [`altera_avalon_mm_sdram_controller`](../altera_avalon_mm_sdram_controller/README.md).
> It presents the same slave port, the same conduit and the same default
> address map, so it can be substituted without disturbing a system, and it
> keeps one open row *per bank* rather than one for the whole device — worth
> 3.6x to 8.9x on mixed and scattered traffic, measured on the same stimulus.
>
> That core is MIT licensed and shares none of this one's RTL. This directory
> stays because the replacement has not yet been run on hardware and this one
> has, and because a system built against this component should be able to keep
> building.

| | |
|---|---|
| Component name | `altera_avalon_new_sdram_controller` |
| Catalog name | **SDRAM Controller Intel FPGA IP** |
| Catalog group | Memory Interfaces and Controllers / SDRAM |
| Version | 20.1 |
| Author | Intel Corporation |

---

## Why it is here

The IP was retired from the Platform Designer catalog in 20.1 and then dropped
from the tools altogether. Checked against the installations to hand:

| Quartus | Ships the IP? |
|---|---|
| 18.1 Standard | **yes** — live copy under `ip/altera/sopc_builder_ip/` |
| 25.1 Standard | **no** — no `_hw.tcl` at any depth, only an entry in `quartus/common/misc/outdated_ip/` |

So on a current Quartus there is no SDRAM controller in the catalog at all, and
a design that needs one has nowhere to get it. That is the gap this copy fills.
On a Quartus that still ships its own, the catalog will offer **both** versions
— right-click gives *Add version 20.1…* (this copy) alongside the installed one.
Check which you are adding.

Intel's release note for the retirement:
<https://documentation.altera.com/#/link/hco1421698042087/hco1421697689300>

---

## Using it

Add the **repository root** to your IP search path (**Tools ▸ Options ▸ IP
Search Path**), then **File ▸ Refresh System**. It appears under *Memory
Interfaces and Controllers / SDRAM*.

It presents four interfaces:

| Interface | Type | What it is |
|---|---|---|
| `clk` | clock sink | system clock |
| `reset` | reset sink | system reset |
| `s1` | Avalon-MM slave | where your masters connect |
| `wire` | conduit | the SDRAM pins — `zs_addr`, `zs_ba`, `zs_cas_n`, `zs_cke`, `zs_cs_n`, `zs_dq`, `zs_dqm`, `zs_ras_n`, `zs_we_n` |

Export the `wire` conduit to your top level and assign those pins to whatever
your board wires the SDRAM to.

### Parameters worth knowing

The GUI splits these into *Memory Profile* (geometry) and *Timing*. The
geometry must match your chip exactly or nothing works:

| Parameter | Default | Range |
|---|---|---|
| `dataWidth` | 32 | 8, 16, 32, 64 |
| `rowWidth` | 12 | 11–14 |
| `columnWidth` | 8 | 8–14 |
| `numberOfBanks` | 4 | 2, 4 |
| `numberOfChipSelects` | 1 | 1, 2, 4, 8 |
| `casLatency` | 3 | 1, 2, 3 |
| `refreshPeriod` | 15.625 µs | 0–156.25 |

Timing is set from the chip's datasheet: `TAC`, `TRCD`, `TRFC`, `TRP`, `TWR`,
`TMRD`, `powerUpDelay`, `initRefreshCommands`, `initNOPDelay`.

The `model` parameter carries presets for a handful of specific chips —
`single_Micron_MT48LC2M32B2_7_chip`, `single_Alliance_AS4LC1M16S1_10_chip` and
others — or `custom`, which is what you want for anything not on that list.

`generateSimulationModel` adds a functional memory model to the generated
testbench. Two things about it are worth knowing before you rely on it:

- **The generator is not in this directory.** `generate_rtl.pl` calls a
  `make_sodimm` routine that lives in a *separate* Intel component,
  `altera_sdram_partner_module`, under
  `$QUARTUS_ROOT/ip/altera/alt_mem_if/alt_mem_if_mem_models/`. Setting this
  parameter makes `qsys-generate` reach across to it.
- **It is functional, not timing-accurate.** It decodes `LOAD MODE REGISTER`,
  `ACTIVATE`, `READ` and `WRITE` and pipelines read data by the CAS latency,
  but models no `tRCD`/`tRP`/`tRFC`/`tWR`, no refresh interval and no
  retention — `PRECHARGE` and `AUTO REFRESH` are decoded and ignored. It will
  not tell you your timing parameters are wrong.

The example below uses it, and documents how to substitute a vendor model if
you need real timing checks.

### For the DE10-Lite

The board this repository's examples target carries an **ISSI IS42S16320D**:
64 MB, organised 32M × 16. That geometry is

```
dataWidth      16
numberOfBanks   4
rowWidth       13          (8192 rows)
columnWidth    10          (1024 columns)
casLatency      3
```

which is 4 × 8192 × 1024 × 16 bits = 512 Mbit = 64 MB, as it should be.

> **Verified on hardware.** [`example/de10_lite_rtl`](example/de10_lite_rtl/README.md)
> builds exactly this configuration and runs it on a physical DE10-Lite. All
> eight of its scenarios pass, including a write-and-verify pass over **every
> one of the 33,554,432 words** in the chip — which is what actually confirms
> the geometry, because a wrong `rowWidth` or `columnWidth` folds the address
> space back on itself and nothing smaller notices.
>
> The full parameter set, including the timing values, is in that example's
> [`qsys/build_system.tcl`](example/de10_lite_rtl/qsys/build_system.tcl); it is
> taken from Terasic's own `SDRAM_Nios_Test` for the same chip rather than
> derived by hand.

## Example

[`example/de10_lite_rtl`](example/de10_lite_rtl/README.md) — a CPU-less RTL
demonstration on a Terasic DE10-Lite. A hardware sequencer masters `s1`
directly, so what it measures is the controller and the memory with nothing in
between.

Measured on silicon, at 100 MHz on a 16-bit bus (200 MB/s theoretical peak):

| access pattern | throughput |
|---|---:|
| sequential, all 64 MB | **194.0 MB/s** — 97% of peak, 1.03 clocks/word |
| a row miss on every access | **22.2 MB/s** — 8.7× slower |

It ships a Questa testbench too (`./build.sh sim`, 58 checks) that runs
against Intel's functional memory model — generated on demand from your own
Quartus installation, not redistributed here.

It also documents two things about this controller that are not obvious from
its interface and were read out of its generated RTL:

- **The address decode is not `{bank, row, column}`.** It is
  `{bank[1], row[12:0], bank[0], column[9:0]}` — the low bank bit sits *below*
  the row. A linear walk therefore changes bank every 1024 words and row only
  every 2048.
- **`chipselect` does not qualify a transaction**, and **read data cannot be
  stalled** — `waitrequest` is the command FIFO's `full` flag, so it is
  backpressure on the command side only.

---

## Documentation

Intel's own documentation for this IP is the *Embedded Peripherals IP User
Guide*, in the chapter on the SDRAM Controller Core. It covers the register
interface, the timing parameters and the sharing of pins via a tristate bridge
in far more detail than is worth repeating here.

---

## Files

Everything in this directory is Intel's, apart from `NOTICE`, `README.md` and
`example/`:

```
altera_avalon_new_sdram_controller_hw.tcl   Platform Designer component
altera_avalon_new_sdram_controller.qprs     preset file
embedded_ip_hwtcl_common.tcl                shared hw.tcl helpers
em_sdram.pm, em_sdram_qsys.pm               the generators (Perl)
em_new_sdram_controller.pl, generate_rtl.pl
em_altera_sodimm.pl, embedded_ip_generate_common.pm
NOTICE                                      licence + the change made here
example/de10_lite_rtl/                      DE10-Lite demonstration (not Intel's)
```

The RTL is not checked in — the Perl generators produce it at Qsys generation
time from the parameters you set.
