# altera-ip-cores

IP components for Intel/Altera **Quartus Prime** and **Platform Designer (Qsys)**.

Three of them are original work. The fourth is a vendor core preserved from a
Quartus release that no longer ships it.

The two firewalls carry full documentation, self-checking testbenches and
demonstrations verified on physical hardware. The SDRAM controller is newer:
measured in simulation against the vendor core it replaces, packaged for
Platform Designer, but **not yet run on a board**.

The three original cores are **MIT licensed**; the vendor core keeps Intel's
own terms — see [Licence](#licence).

---

## What's here

| Component | Catalog name · version · group | What it is | Status |
|---|---|---|---|
| [`altera_avalon_mm_firewall`](altera_avalon_mm_firewall/README.md) | **Avalon-MM Firewall** · v1.0 · *Bridges and Adapters / Custom* | Burst-capable access-control and fault-isolation firewall for Avalon-MM. Default-deny address windows with per-window read/write/burst permission, whole-burst range checking, downstream timeout detection and an explicit software recovery sequence | **Verified on hardware.** 632 checks, 22 assertions, 11 cover points |
| [`altera_axi4_lite_firewall`](altera_axi4_lite_firewall/README.md) | **AXI4-Lite Firewall** · v2.0 · *Bridges and Adapters / Custom* | The same idea on AXI4-Lite: single transactions, capture-and-redrive rather than pass-through | **Verified on hardware.** 103 checks, 14 assertions, 6 cover points |
| [`altera_avalon_mm_sdram_controller`](altera_avalon_mm_sdram_controller/README.md) | **Avalon-MM SDRAM Controller (per-bank rows)** · v1.0 · *Memory Interfaces and Controllers / Custom* | SDR SDRAM controller that keeps one open row *per bank* and treats a read/write turnaround as the datasheet does, rather than as a full row cycle. Drop-in replacement for the vendor core below | **Simulation only — not yet on hardware.** 3.6–8.9× the vendor core on mixed and scattered traffic, 0 data errors, 0 timing violations |
| [`altera_avalon_new_sdram_controller`](altera_avalon_new_sdram_controller/README.md) | **SDRAM Controller Intel FPGA IP** · v20.1 · *Memory Interfaces and Controllers / SDRAM* | Intel's own SDRAM controller, kept here because current Quartus releases no longer ship it | Vendor IP, unhidden so it is usable — see *Provenance*. **Demo verified on hardware:** all 64 MB written and read back at 194 MB/s |

The two firewalls appear in the IP Catalog under **Bridges and Adapters /
Custom**, the two SDRAM controllers under **Memory Interfaces and Controllers**
— the new one in *Custom*, Intel's in *SDRAM*.

### Verified on hardware means verified on hardware

Every demonstration here was built, programmed and run on a physical DE10-Lite
(Intel MAX 10, `10M50DAF484C7G`), and each reports its own pass/fail over JTAG
rather than asking you to read LEDs:

| | Avalon-MM Firewall | AXI4-Lite Firewall | SDRAM Controller Intel FPGA IP |
|---|---|---|---|
| RTL demo — no CPU, no software | 16/16 scenarios at 50 MHz | 16/16 scenarios at 50 MHz | 8/8 scenarios at **100 MHz** |
| Nios II/f demo — C, in a generated Qsys system | 41/41 checks at **100 MHz** | 33/33 checks at 100 MHz | — |

**`altera_avalon_mm_sdram_controller` is deliberately absent from that table.**
It has never been on a board. What it has is a measurement harness that
reproduces the hardware-verified 194 MB/s of the core it replaces, and a
Platform Designer component checked against a real Quartus installation. Both
are simulation, and neither is a substitute for a board.

The Avalon core's demos are the source of its published resource and Fmax
numbers: 60.77 MHz with the combinational rule lookup, 95.85 MHz with
`REGISTER_LOOKUP` enabled, at the core's default parameters on a `C7` part.

The SDRAM demo writes and verifies **all 33,554,432 words** of the board's
64 MB chip and times the transfer: **194 MB/s sequential**, 97% of the 200 MB/s
theoretical peak for a 16-bit bus at 100 MHz, against 22 MB/s when every access
is forced to miss its row.

---

## Adding the cores to Platform Designer

1. Clone this repository.
2. In Quartus, open **Platform Designer (Qsys)**.
3. Go to **Tools ▸ Options ▸ IP Search Path**.
4. Click **Add…** and select the **top level of your clone** — the
   `altera-ip-cores` directory itself.
5. **File ▸ Refresh System.** All four cores appear in the IP Catalog — the
   two firewalls under *Bridges and Adapters / Custom*, the new SDRAM
   controller under *Memory Interfaces and Controllers / Custom*, and Intel's
   under *Memory Interfaces and Controllers / SDRAM*.

> Intel shipped the SDRAM controller with `HIDE_FROM_QUARTUS` and
> `HIDE_FROM_SOPC` set, which kept it out of the catalog. Both are `false`
> here, so it now appears as **SDRAM Controller Intel FPGA IP** under *Memory
> Interfaces and Controllers / SDRAM* — confirmed in Platform Designer, with
> the component resolved from this repository. See *Provenance*.
>
> If your Quartus still ships its own copy, the catalog offers **both
> versions** — right-click gives *Add version 20.1…* (this repository)
> alongside your installation's. 18.1 Standard, for instance, still carries a
> live copy under `ip/altera/sopc_builder_ip/`, so both appear. Check which
> version you are adding.
>
> By 25.1 Standard the IP is genuinely gone: it survives only as an entry in
> `quartus/common/misc/outdated_ip/`, with no `_hw.tcl` anywhere in the
> installation. That is the gap this copy fills. Unlike the firewalls'
> examples, this core is not MAX 10 specific — it instantiates for any family
> your Quartus supports.

### To open a Nios II example's system in the GUI, add two more paths

Each firewall's protected peripheral is consumed two different ways, and only
one of them goes through the IP catalog:

| Example | How it gets the demo peripheral | Needs a search path? |
|---|---|---|
| `de10_lite_rtl` | plain RTL — the `.qsf` lists `../../common/demo_*.sv` | **no** |
| `de10_lite_nios` | a Qsys component — `add_instance tgt demo_*` | **yes** |

So the RTL demos build and simulate from a clone with no IP settings at all.
Only the Nios II systems resolve the peripheral through Platform Designer, and
only they need:

```
<clone>/altera_avalon_mm_firewall/example/common
<clone>/altera_axi4_lite_firewall/example/common
```

**Why the top-level path is not enough:** Platform Designer does not scan a
search-path directory to unlimited depth. Each core's `_hw.tcl` sits one level
below the top of the clone and is found; the demo peripherals sit three levels
below it, in `<core>/example/common/`, and are not. Nothing about the
components themselves is different — both declare the same *Bridges and
Adapters / Custom* group as the firewalls beside them, and neither is hidden.
It is purely how far the scan reaches.

Without those paths the catalog looks correct — the firewalls are there — and
opening a Nios II system fails to resolve `demo_avl_mm_target_slave` or
`demo_axi4_lite_target_slave`.

> This affects the **GUI only**. Each Nios II example's `build.sh` passes the
> paths it needs to `qsys-script` directly, so building one from the command
> line works without touching your global IP settings. The RTL demos have no
> `build.sh` — they are ordinary Quartus projects, compiled with
> `quartus_sh --flow compile`.

### Nios II software

**Both firewalls** ship a Nios II HAL driver and a `*_sw.tcl`, so
`nios2-bsp-generate-files` finds the driver on the same IP search path and
compiles it into your BSP automatically. Adding the component to the system is
the whole integration step — there is nothing to copy by hand.

| Core | Driver | BSP description |
|---|---|---|
| `altera_avalon_mm_firewall` | `HAL/src/altera_avalon_mm_firewall.c` | `avl_mm_firewall_sw.tcl` |
| `altera_axi4_lite_firewall` | `HAL/src/altera_axi4_lite_firewall.c` | `axi4_lite_firewall_sw.tcl` |

Both set `auto_initialize`, so the BSP constructs every instance in
`alt_sys_init.c` and runs it before `main()`: base address and interrupt from
`system.h`, a version check against `CORE_INFO`, and the ISR registered. What
that deliberately does *not* do is program the rule table or install the
peripheral-reset callbacks — neither can be derived from the hardware. That
division is the safe one: the table resets empty and the hardware is
default-deny, so the state after `alt_sys_init()` is *everything denied*.

---

## Tool requirements

Everything here was built and hardware-verified with **Quartus Prime 18.1
Standard**, and programmed with **25.1 Standard**, whose JTAG server reads the
DE10-Lite's chain more reliably. The scripts default to exactly that split.

Two separate constraints decide what else will work:

**MAX 10** — needed by both examples, and a **Standard / Lite** feature. It is
*not* dropped in current releases: 18.1 Standard and 25.1 Standard both list it
among their 14 device families. Quartus Prime **Pro** does not support MAX 10
at all, in any version.

**The Nios II processor** — needed only by the `de10_lite_nios` examples, and
discontinued. Intel's guidance is that Nios II software development continues
in **Standard 23.1 or earlier** (Pro dropped it after 23.4, and Pro 24.1
removed the Nios II software binaries entirely). Consistent with that,
`altera_nios2_gen2` resolves under 18.1 here, and `build.sh` does **not**
resolve it under 25.1 Standard — the system fails to generate with *"No module
type named altera_nios2_gen2"*.

| | MAX 10 | RTL demos | Nios II examples |
|---|---|---|---|
| Quartus Prime 18.1 Standard | yes | **verified on hardware** | **verified on hardware** |
| Quartus Prime 25.1 Standard | yes | **verified on hardware** | no — `altera_nios2_gen2` does not resolve |
| Quartus Prime 26.1 Pro | no | no | no |

So the **RTL** demos work on current Standard releases: the Avalon one was
compiled with 25.1 Standard and its bitstream programmed and swept on the
board, all 16 scenarios passing. The **Nios II** examples need Standard 23.1 or
earlier; 18.1 is what this repository uses and verifies.

The cores' own RTL is plain synthesisable SystemVerilog with no device
primitives, no vendor attributes and no inferred memory, so it is not tied to a
family or a release. Only the examples are.

For simulation, both firewalls' regressions run under **Questa/ModelSim**
(coverage and assertions), **Verilator 5.050 or newer** (licence-free — older
releases do not implement the SVA the assertions use), and **Icarus**
(functional tests only — a `-DICARUS` define skips the SVA bind). The SDRAM
example carries a Questa testbench that runs against Intel's functional memory
model, generated on demand from your own Quartus installation. Each core's
README documents its flows and what each one does and does not cover.

---

## Layout

```
altera-ip-cores/
├── altera_avalon_mm_firewall/          Avalon-MM Firewall: rtl, tb, doc,
│   ├── HAL/ inc/ *_sw.tcl             HAL driver the BSP picks up itself,
│   ├── example/de10_lite_rtl/         and two hardware demos
│   └── example/de10_lite_nios/
├── altera_axi4_lite_firewall/          AXI4-Lite Firewall, same shape
│   ├── HAL/ inc/ *_sw.tcl
│   ├── example/de10_lite_rtl/
│   └── example/de10_lite_nios/
├── altera_avalon_mm_sdram_controller/  SDRAM controller, per-bank open rows
│   ├── rtl/                            the controller
│   ├── benchmark/                      the ruler it and Intel's are measured on
│   └── tools/                          Platform Designer component check
├── altera_avalon_new_sdram_controller/ Intel's SDRAM controller, unhidden
│   └── example/de10_lite_rtl/          plus one hardware demo
└── tools/check_docs.py                 checks this file against the repository
```

Each core's own `README.md` is the real documentation: design rationale,
register map, parameters, verification status and known limitations. The
firewalls additionally carry a full user guide and an architecture document, in
Markdown and PDF, under `doc/`.

### The documentation is checked, not just written

Numbers in these documents are re-derived from the repository rather than
trusted, because they have drifted before:

```bash
python3 tools/check_docs.py                                  # 270 claims - this file, licensing, links
python3 altera_axi4_lite_firewall/doc/tools/check_facts.py   # 309 claims
python3 altera_avalon_mm_firewall/doc/tools/check_facts.py   # 312 claims
altera_avalon_mm_sdram_controller/tools/check_component.sh   # 10 checks, needs Quartus
```

The firewalls' checkers re-derive every register offset, bit position,
parameter range and assertion count quoted anywhere in their documents from the
RTL and the committed simulation artefacts. `tools/check_docs.py` does the same
for this file — including that every core is named in the Licence section, and
that a directory with a `NOTICE` is excluded from the MIT grant while one
without is placed under it. See [`tools/README.md`](tools/README.md).

---

## Provenance

**`altera_avalon_mm_firewall`, `altera_axi4_lite_firewall` and
`altera_avalon_mm_sdram_controller` are original work.** There is no stock
Avalon-MM or AXI firewall in the Intel FPGA IP catalog; both firewalls were
written from scratch, and each core's README explains the reasoning behind its
design decisions.

The SDRAM controller is also written from scratch. It is a *replacement* for
the vendor core in the next directory, not a derivative of it: it shares that
core's slave port, conduit and default address map so it can be substituted
without disturbing a system, and shares none of its RTL. Intel's controller is
generated on demand for the benchmark to measure against, and that generated
output is never committed — see
[`altera_avalon_mm_sdram_controller/benchmark/README.md`](altera_avalon_mm_sdram_controller/benchmark/README.md).

**`altera_avalon_new_sdram_controller` is Intel's own IP**, copyright
© 2001–2020 Intel Corporation, and is licensed separately — see *Licence*
below. It was obtained via the Trenz Electronic forum.

It is preserved here because Quartus stopped shipping it. What was checked:
18.1 Standard still carries a live copy under `ip/altera/sopc_builder_ip/`,
while 25.1 Standard has **no copy at any depth** — only an entry in
`quartus/common/misc/outdated_ip/` marking it retired. The component itself is
version 20.1, which is the last version this repository's copy came from.

**Two properties are changed from Intel's original**, and the change is marked
as such in the file. `HIDE_FROM_SOPC` and `HIDE_FROM_QUARTUS` were `true`,
which is what kept the component out of the Platform Designer catalog: Intel
was retiring it from the catalog in 20.1, so it stayed instantiable for
existing designs but was hidden from new ones. Both are `false` here, because a
core you cannot find is not a core you can use. Nothing else in the `_hw.tcl`,
and nothing in the Perl generators or the generated RTL, is altered — the
component still produces the same 722-line controller with the same SDRAM pin
set.

### Licence

Three of the four directories are **MIT licensed** — free to use, modify and
redistribute, including commercially, provided the copyright notice travels
with them. See [`LICENSE`](LICENSE).

| Directory | Licence |
|---|---|
| `altera_avalon_mm_firewall/` | MIT — RTL, testbenches, documentation, HAL driver, DE10-Lite examples |
| `altera_axi4_lite_firewall/` | MIT — same |
| `altera_avalon_mm_sdram_controller/` | MIT — RTL, Platform Designer component, benchmark harness, documentation |
| `altera_avalon_new_sdram_controller/` | **Intel's own terms, not MIT** — see below |

`altera_avalon_new_sdram_controller/` is the only exception. It is **excluded
from that licence** and is not the author's to relicense. It stays under Intel's own terms — the Intel
Program License Subscription Agreement / Intel FPGA IP License Agreement
referenced in its file headers, which in substance restrict use to programming
devices manufactured and sold by Intel/Altera or their authorised distributors.
See [`altera_avalon_new_sdram_controller/NOTICE`](altera_avalon_new_sdram_controller/NOTICE),
which also records the modification made to it here.

If you take everything except `altera_avalon_new_sdram_controller/`, only the
MIT licence applies.

One caveat for the new SDRAM controller: its benchmark can *generate* Intel's
controller and memory model from your own Quartus installation, to measure
against. That generated output is Intel's, under Intel's terms, and is
gitignored rather than committed. Nothing Intel-derived ships in this
repository outside `altera_avalon_new_sdram_controller/`.
