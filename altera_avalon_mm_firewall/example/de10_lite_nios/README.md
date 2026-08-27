# Avalon-MM Firewall — Nios II/f example (DE10-Lite)

The [Avalon-MM Firewall](../../README.md) core driven by **software on a Nios II/f
processor**, inside a real Platform Designer system, on a Terasic **DE10-Lite**
(Intel MAX 10, `10M50DAF484C7G`) running at **100 MHz from an on-chip PLL**.

**Verified on hardware: 41 / 41 checks pass on a physical DE10-Lite.**

This is the companion to [`../de10_lite_rtl/`](../de10_lite_rtl/), which drives
the same core from a hardware sequencer with no CPU at all. The two are
complementary, and the difference is the point:

| | `de10_lite_rtl` | `de10_lite_nios` (here) |
|---|---|---|
| Drives the core from | a hardware sequencer | C on a Nios II/f |
| Interconnect | direct, point to point | generated Qsys, with a pipeline bridge |
| Clock | 50 MHz | **100 MHz** (PLL) |
| `ADDR_WIDTH` | 12 | 12 |
| Bursts | 16-beat, exercised throughout | none — a CPU issues single accesses |
| Results appear on | HEX displays and LEDs | the JTAG UART |
| Answers the question | does the core behave? | does it *integrate*? |

Only this example can answer the second question, because only this one puts
the core behind Platform Designer's interconnect and a data cache — and only
this one runs it at 100 MHz.

---

## Running it

```bash
./build.sh          # Qsys system, bitstream, BSP, application
./run_on_board.sh   # program, download, run, report
```

`run_on_board.sh` is non-interactive and exits non-zero if any check fails, so
it can be driven remotely over the board's USB connection. That matters here:
half the checks involve deliberately wedging a peripheral, and none of them can
be seen by looking at the board.

```
=== programming the FPGA ===
Info (209007): Configuration succeeded -- 1 device(s) configured
=== downloading the software ===
Downloaded 76KB in 0.4s (190.0KB/s)   Verified OK
=== capturing the JTAG UART ===
 Avalon-MM Firewall - Nios II/f example, DE10-Lite
 system clock 100000000 Hz
 ...
 passed : 41
 failed : 0
 *** ALL CHECKS PASSED ***
PASSED: every check passed on hardware.
```

`LEDR[9:0]` shows the firewall's live `STATUS`, written by software over a PIO.

### Two Quartus installations

`build.sh` uses **Quartus 18.1** for one specific reason: newer Quartus Standard
releases no longer ship the **Nios II processor IP**. On 25.1std the catalog
directory `ip/altera/nios2_ip/` is empty, so Platform Designer cannot instantiate
`altera_nios2_gen2` and this system will not build there.

Note what is *not* the reason. 25.1std still ships the Nios II **software** tools
(`nios2eds/sdk2/bin`: `nios2-bsp`, `nios2-download`, `nios2-terminal`), and it
still supports **MAX 10** — `quartus/common/devkits/max10_de10_lite` and the
MAX 10 ALTPLL libraries are both present. Only the CPU component is missing.

`run_on_board.sh` uses 18.1 for `nios2-download` and `nios2-terminal` but a
newer Quartus for the JTAG stack (`JTAG_ROOT`, default `/opt/altera/25.1std`),
because the newer JTAG server reads this board's chain more reliably. Set
`JTAG_ROOT=$QUARTUS_ROOT` if you have only one installation.

> **Nios II/f, not /e.** Nios II/f is the higher-performance core and the one
> this example uses. Set `impl` to `Tiny` in `qsys/build_system.tcl` for Nios
> II/e instead — its lack of a data cache also makes the uncached-access
> discussion below moot.

---

## The system

```
                    ┌──────────────── firewall_sys (Platform Designer) ──────────────┐
                    │                                                                │
  MAX10_CLK1_50 ───▶│ ALTPLL ──100 MHz──▶ everything                                 │
     (50 MHz)       │                                                                │
                    │  Nios II/f ──┬─▶ on-chip RAM (128 KB)                          │
                    │   4K I$/2K D$├─▶ JTAG UART, sysid, timer                       │
                    │              ├─▶ pio_led ──────────────────────────▶ LEDR      │
                    │              ├─▶ pio_fault ──┐                                 │
                    │              ├─▶ fw.csr      │                                 │
                    │              └─▶ br ─▶ fw.s0 │ Avalon-MM Firewall │            │
                    │                              │        m0          │            │
                    │                              └────────▶ demo_avl_mm_target_slave
                    │                                 hang/hang_late/soft_resetn ◀───┘
                    └────────────────────────────────────────────────────────────────┘
```

The system is built by **`qsys/build_system.tcl`**, not committed as a
hand-edited `.qsys`. The script is the source of truth: it is reviewable in a
diff, and it does not pin the Quartus version that happened to write it. The
generated `firewall_sys.qsys` **is** tracked, so you can open the system in the
Platform Designer GUI straight from a clone, and `./build.sh clean` leaves it
alone. If you change the system in the GUI, port the change back into
`build_system.tcl` — otherwise the next `./build.sh qsys` reverts it.

### Three things that are easy to get wrong

**1. Rules are written in firewall-side addresses, not CPU addresses.**
`s0` declares `bridgesToMaster m0`, so Platform Designer folds the firewall out
of the address map entirely: the protected peripheral appears to the CPU under
its **own** name, `TGT_BASE`, and an access to `TGT_BASE + 0x10` reaches the
core as address `0x010` — because the peripheral sits at 0 in `m0`'s space. The
rule table therefore holds `0x000`, `0x040`, `0x080`, not `0x23000`. Getting
this backwards fills the table with values no transaction can ever match, and
every access returns `DECODEERROR`.

That the peripheral keeps its own address is the whole point of
`bridgesToMaster`: dropping this firewall into an existing system moves nothing.

**2. The data cache must be bypassed.** Nios II/f has one. Every access to the
firewall and to the protected peripheral goes through `IORD_32DIRECT` /
`IOWR_32DIRECT`, which force an uncached access. A plain `volatile` pointer
would leave writes sitting in the cache where the hardware never sees them.

**3. The peripheral's reset is the integrator's job.** The core does not drive
it, and recovery from a timeout requires it. Here it is `pio_fault` bit 2, and
the two callbacks in `main.c` are what the driver calls during `recover()`.

---

## The driver comes from the BSP, not from this directory

There is no copy of the driver here. `avl_mm_firewall_sw.tcl` in the component
directory declares it, `nios2-bsp-generate-files` finds it on the IP search
path and matches `hw_class_name` against the `_hw.tcl`, and the BSP ends up
with:

```
software/bsp/drivers/inc/altera_avalon_mm_firewall.h
software/bsp/drivers/inc/altera_avalon_mm_firewall_regs.h
software/bsp/drivers/src/altera_avalon_mm_firewall.c
```

`auto_initialize` is set, so the BSP also emits into `alt_sys_init.c`:

```c
ALTERA_AVALON_MM_FIREWALL_INSTANCE ( FW, fw);
...
ALTERA_AVALON_MM_FIREWALL_INIT ( FW, fw);
```

so `fw` is constructed, version-checked and its interrupt registered before
`main()` runs. The application declares `extern alt_avalon_mm_firewall_dev fw;`
and uses it. **Adding the component to the system is the whole integration
step** — that is what shipping a `_sw.tcl` buys, and it is the part the
AXI4-Lite sibling's example could not demonstrate because it carried a private
copy of its driver.

---

## What the checks cover

| Section | What it demonstrates |
|---|---|
| **A** | What `alt_sys_init()` left behind: version checked, geometry read out of `CORE_INFO`, interrupt connected, and **default-deny** with an empty rule table |
| **B** | Programming the table from C through `configure()`, and that it refuses more rules than the hardware has |
| **C** | Permitted traffic through generated interconnect, including the adjacent window |
| **D** | A denied write raises the **interrupt**, the ISR runs, and `FAULT_ADDR` / `FAULT_INFO` name the offending access. The driver decodes the type to a string |
| **E** | Reading a write-only window returns **zeros**, not the stored data |
| **F** | An unmapped address gives `ADDR_VIOLATION` |
| **G** | A downstream timeout: the CPU is **released rather than hung**, `BLOCKED` and `WR_CMD_STUCK` latch, traffic while blocked is *rejected not stalled*, and `recover()` restores the core with nothing stale landing |
| **H** | The other timeout shape — accepted then silent — where `RD_CMD_STUCK` stays **clear** |
| **I** | Bypass mode turns off access control, not isolation |

### Why sections G and H mask the interrupt

The driver's ISR acknowledges the sticky bits and, on a timeout, calls
`recover()` — which resets the peripheral and unblocks the core. Left enabled,
the fault is handled and cleared before the main thread can read a single bit
of it, and every check sees a healthy firewall.

So G and H mask the interrupt and poll instead. That is not a workaround; it is
the pattern the driver header recommends for anything but the simplest
peripheral — *"leave `on_fault` to set a flag and call `recover()` from a
thread"*. Here the thread does the whole job, and the blocked state becomes
observable.

---

## What building this found

Putting the core into Platform Designer for the first time surfaced three
things that simulation could not.

**`USE_WRITE_RESPONSE=1` was unusable in Qsys.** The component's `_hw.tcl`
exposed `writeresponsevalid` but never declared
`maximumPendingWriteTransactions`, and Platform Designer refuses to generate
such an interface: *"Interface with write responses must support at least 1
pending write."* It elaborated and simulated perfectly and failed at system
generation, a long way from where the mistake was. Fixed on `s0`, `m0` and the
demo peripheral.

**Two components shared a name.** Both examples in this repository defined a
`demo_target_slave`, so Qsys resolved the AXI one and rejected the Avalon
parameters. The Avalon one is now `demo_avl_mm_target_slave`.

**`recover()` left `STATUS` dirty.** A command the peripheral never accepted
keeps re-firing the no-progress timeout until `UNBLOCK` retires it, so the
acknowledge at step 2 of the recovery sequence gets overwritten. A recovery
that had genuinely succeeded left `TIMEOUT_ERROR | ISOLATED` set — and
`ISOLATED` still gates the data path, so the *next* write silently did not
land. The driver now acknowledges again after releasing the reset, and the
core's documented sequence has gained a step 7. This one only appears on
hardware, because it needs a peripheral that stays wedged for real time.

---

## Measured results

### Hardware

| Item | Result |
|---|---|
| Checks on a physical DE10-Lite | **41 / 41 pass** |
| System clock, reported by the running CPU | **100 MHz** (`ALT_CPU_FREQ`) |
| BSP driver discovery from `_sw.tcl` | **Works** — no private copy |
| Application build | **Clean** at `-Wall -Wextra` with `nios2-elf-gcc` |

### Synthesis — Quartus Prime 18.1.1 Standard, `10M50DAF484C7G`

0 errors. Full compile through the Assembler.

| Resource | Used | Device | % |
|---|---|---|---|
| Total logic elements | 7,281 | 49,760 | 15% |
| Total registers | 4,614 | — | — |
| Total memory bits | 1,112,128 | 1,677,312 | 66% |
| PLLs | 1 | 4 | 25% |

### Timing — 100 MHz, slow 1200 mV 85 °C

| Metric | Value |
|---|---|
| Fmax (PLL 100 MHz domain) | **105.44 MHz** |
| Setup slack | **+0.516 ns** |
| Hold slack | **+0.236 ns** |
| Total negative slack | 0.000 |

**Timing closes at 100 MHz, and getting there took three things.** None of them
was obvious from simulation, and the path moved twice:

1. **`REGISTER_LOOKUP = 1`.** The combinational rule lookup measures 73.4 MHz
   in this configuration; it cannot run at 100 MHz. This is the parameter that
   exists for exactly this case.
2. **A pipeline bridge in front of `fw.s0`.** With the lookup registered, the
   worst path became `cpu|d_address_tag_field → (generated interconnect) →
   fw|rd_deny_beats` — the CPU's data master through Qsys decode and
   arbitration into the firewall's accept logic. Registering the command and
   response at that boundary is the standard remedy.
3. **`BURST_WIDTH = 5`, `MAX_PENDING_READS = 1`.** The bridge alone got to
   95.7 MHz, and the remaining path was inside the core:
   `rd_fwd_beats → rd_beats_after (add) → rd_gate_allow → waitrequest →
   rd_accept → rd_deny_beats`. That is the outstanding-beat headroom check,
   and its width is `MAX_PENDING_READS × 2^(BURST_WIDTH−1)` — 512 beats and an
   11-bit counter at the defaults. A Nios II data master issues single
   accesses; 512 beats of read capacity is capacity this system cannot use.
   Sizing it to 16 beats with one burst outstanding halves those counters and
   closes the remaining 0.45 ns.

The lesson is the core's own advice generalised: **size the parameters to the
system.** Every one of the three is a configuration choice, not a change to the
core.

---

## What is and isn't verified

| Item | Status |
|---|---|
| **41 checks on a physical DE10-Lite at 100 MHz** | **Passing** |
| Qsys system generation | **Clean**, 0 errors |
| Synthesis for `10M50DAF484C7G` | **Clean**, 0 errors, `.sof` produced and programmed |
| Timing closure at 100 MHz | **Closed**, +0.516 ns setup slack |
| BSP driver discovery and auto-init | **Verified** on hardware |
| Interrupt through generated Qsys interconnect | **Verified** — the ISR runs and decodes the fault |
| Uncached access with a data cache present | **Verified** — Nios II/f with 2 KB D$ |
| Burst behaviour | **Not exercised here.** A Nios II data master issues single accesses; bursts are the [RTL example](../de10_lite_rtl/README.md)'s job |
| An Avalon-MM DMA through the firewall | **Not built.** An mSGDMA in this system would exercise bursts through generated interconnect, and is the obvious next step |

---

## Files

```
example/de10_lite_nios/
├── README.md                    This file
├── build.sh                     Qsys, BSP, application, bitstream
├── run_on_board.sh              Program, download, run, report
├── qsys/
│   ├── build_system.tcl         The system, as a reviewable script
│   └── firewall_sys.qsys        Generated, tracked so the GUI can open it
├── rtl/
│   └── de10_lite_nios_top.sv    Pins, PLL reset ordering, fault conduit
├── software/
│   └── main.c                   The checks. The driver comes from the BSP
└── quartus/
    ├── de10_lite_nios.qpf
    ├── de10_lite_nios.qsf
    └── de10_lite_nios.sdc
```

The protected peripheral is shared with the RTL example and lives in
[`../common/`](../common/).
