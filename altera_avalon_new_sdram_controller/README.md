# SDRAM Controller Intel FPGA IP

Intel's own SDRAM controller — an Avalon-MM slave that drives a single-data-rate
SDRAM chip — preserved here because Quartus stopped shipping it.

**This is not original work.** It is Intel's IP, redistributed under Intel's
terms, with two properties changed so it appears in the Platform Designer
catalog. See [`NOTICE`](NOTICE) for the licence and the modification, and the
repository [root README](../README.md#licence) for how it sits alongside the
MIT-licensed firewalls.

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
testbench, which is the cheap way to check your geometry and timing before
committing to hardware.

### For the DE10-Lite

The board this repository's firewall examples target carries an **ISSI
IS42S16320D**: 64 MB, organised 32M × 16. That geometry is

```
dataWidth      16
numberOfBanks   4
rowWidth       13          (8192 rows)
columnWidth    10          (1024 columns)
```

which is 4 × 8192 × 1024 × 16 bits = 512 Mbit = 64 MB, as it should be. CAS
latency and the timing values come from the IS42S16320D datasheet for your
clock — the `-7` speed grade part on this board is commonly run at CAS 3.

> **Not verified here.** Those settings follow from the part's organisation,
> but no SDRAM system was built or run on hardware in this repository. What
> *was* checked is that the component instantiates and generates: a minimal
> system containing it produces a 722-line controller carrying the full SDRAM
> pin set. Treat the geometry as a starting point and confirm against the
> board's own reference design.

---

## Documentation

Intel's own documentation for this IP is the *Embedded Peripherals IP User
Guide*, in the chapter on the SDRAM Controller Core. It covers the register
interface, the timing parameters and the sharing of pins via a tristate bridge
in far more detail than is worth repeating here.

---

## Files

Everything in this directory is Intel's, apart from `NOTICE`:

```
altera_avalon_new_sdram_controller_hw.tcl   Platform Designer component
altera_avalon_new_sdram_controller.qprs     preset file
embedded_ip_hwtcl_common.tcl                shared hw.tcl helpers
em_sdram.pm, em_sdram_qsys.pm               the generators (Perl)
em_new_sdram_controller.pl, generate_rtl.pl
em_altera_sodimm.pl, embedded_ip_generate_common.pm
NOTICE                                      licence + the change made here
```

The RTL is not checked in — the Perl generators produce it at Qsys generation
time from the parameters you set.
