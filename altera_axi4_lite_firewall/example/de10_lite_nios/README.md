# AXI4-Lite Firewall — Nios II/f example (DE10-Lite)

The [AXI4-Lite Firewall](../../README.md) core driven by **software on a Nios II/f
processor**, inside a real Platform Designer system, on a Terasic **DE10-Lite**
(Intel MAX 10, `10M50DAF484C7G`) running at **100 MHz from an on-chip PLL**.

**Verified on hardware: 33 / 33 checks pass on a physical DE10-Lite.**

This is the companion to [`../de10_lite_rtl/`](../de10_lite_rtl/), which drives
the same core from a hardware sequencer with no CPU at all. The two are
complementary, and the difference is the point:

| | `de10_lite_rtl` | `de10_lite_nios` (here) |
|---|---|---|
| Drives the core from | a hardware sequencer | C on a Nios II/f |
| Interconnect | direct, point to point | generated Qsys, Avalon→AXI bridged |
| Clock | 50 MHz | 100 MHz (PLL) |
| `ADDR_WIDTH` | 32 | 12 |
| Results appear on | HEX displays and LEDs | the JTAG UART |
| Answers the question | does the core behave? | does it *integrate*? |

Only this example can answer the second question, because only this one puts
the core behind Platform Designer's interconnect and a data cache.

---

## Running it

```bash
./build.sh          # Qsys system, BSP, application, bitstream (~2 min)
./run_on_board.sh   # program, download, run, report
```

`run_on_board.sh` is non-interactive and exits non-zero if any check fails, so
it can be driven remotely over the board's USB connection. That matters here:
half the scenarios involve deliberately wedging a peripheral, which is not
something you can see by looking at the board.

```
=== looking for a board ===
1) USB-Blaster [3-1]
  031050DD   10M50DA(.|ES)/10M50DC
=== programming the FPGA ===
Info (209007): Configuration succeeded -- 1 device(s) configured
=== downloading the software ===
Downloaded 75KB in 0.3s ... Verified OK
=== capturing the JTAG UART ===
 passed : 33
 failed : 0
 *** ALL CHECKS PASSED ***
PASSED: every check passed on hardware.
```

`LEDR[9:0]` shows the firewall's live `STATUS`, written by software over a PIO.

### Two Quartus installations

`build.sh` uses Quartus 18.1 because newer Quartus Standard releases no longer
ship the **Nios II processor IP**: on 25.1std `ip/altera/nios2_ip/` is empty, so
Platform Designer cannot instantiate `altera_nios2_gen2`. The Nios II *software*
tools are still there (`nios2eds/sdk2/bin`), and so is MAX 10 device support —
it is only the CPU component that is gone.

`run_on_board.sh` uses 18.1 for `nios2-download` and `nios2-terminal`, but a
**newer Quartus for the JTAG stack** (`JTAG_ROOT`, default
`/opt/altera/25.1std`). That split is a workaround, not tidiness: on this
setup the 18.1 JTAG server reads the board's chain only intermittently —
`JTAG chain broken`, `Server error` and `cable not detected` all appear from
one unchanged configuration — while the 25.1 tools read it every time. If you
have only one installation, set `JTAG_ROOT=$QUARTUS_ROOT`; expect flakiness if
that one is 18.1.

> **Nios II/f, not /e.** Nios II/f is the higher-performance core, and the one
> this example uses. Set `impl` to `Tiny` in `qsys/build_system.tcl` to build
> with Nios II/e instead — its lack of a data cache also makes the
> uncached-access discussion below moot.

---

## The system

```
                    ┌──────────────── firewall_sys (Platform Designer) ──────────────┐
                    │                                                                │
  MAX10_CLK1_50 ───▶│ ALTPLL ──100 MHz──▶ everything                                 │
     (50 MHz)       │                                                                │
                    │  Nios II/f ──┬─▶ on-chip RAM (128 KB)                          │
                    │   4K I$/2K D$ ├─▶ JTAG UART, sysid, timer                      │
                    │              ├─▶ pio_led ──────────────────────────▶ LEDR      │
                    │              ├─▶ pio_fault ──┐                                 │
                    │              ├─▶ fw.s_axi_ctrl                                 │
                    │              └─▶ fw.s_axi ──▶│ AXI4-Lite Firewall │            │
                    │                              │        m_axi       │            │
                    │                              └────────▶ demo_target_slave      │
                    │                                 hang/hang_late/soft_resetn ◀───┘
                    └────────────────────────────────────────────────────────────────┘
```

The system is built by **`qsys/build_system.tcl`**, not committed as a
hand-edited `.qsys`. The script is the source of truth: it is reviewable in a
diff, and it does not pin the Quartus version that happened to write it.

The generated `firewall_sys.qsys` **is** tracked, so you can open the system in
the Platform Designer GUI straight from a clone without building anything
first, and `./build.sh clean` leaves it alone. If you change the system in the
GUI, port the change back into `build_system.tcl` — otherwise the next
`./build.sh qsys` reverts it.

One wrinkle worth knowing: the ALTPLL wizard writes a timestamp-derived MIF
name into the `.qsys` on every run, which would make the tracked file show a
one-line diff after each regeneration. `build.sh` pins that field, so
regenerating an unchanged system produces an unchanged file.

### Three things that are easy to get wrong

**1. Rules are written in firewall-side addresses, not CPU addresses.**
Platform Designer hands an AXI slave the offset within its own span. A CPU
access to `FW_S_AXI_BASE + 0x10` reaches the core as address `0x010`, and the
core forwards `0x010` to `m_axi`. So the rule table holds `0x000`, `0x010`,
`0x020` — not `0x23000`. Getting this backwards fills the table with values no
transaction can ever match, and every access returns DECERR.

**2. The peripheral must sit at 0 in the `m_axi` address space.** The firewall
forwards addresses unchanged, so the protected peripheral's base in its
master's space has to line up. `build_system.tcl` assigns it explicitly rather
than letting Qsys pick, because an auto-assignment that happens to be right
can move on the next regeneration.

**3. Nios II/f has a data cache.** Every access to the firewall and to the
protected peripheral must bypass it, or writes sit in the cache and the
hardware never sees them. The driver uses `IORD_32DIRECT`/`IOWR_32DIRECT`,
which set address bit 31 to force an uncached access — that is why it does not
use plain `volatile` pointers. On Nios II/e, which has no data cache, the
choice is invisible; here it is the difference between working and not.

---

## What the software checks

33 checks, in four groups. All of them are claims about the register map in
[the user guide](../../doc/axi4_lite_firewall_user_guide.md), asserted against
real silicon.

| Group | What it establishes |
|---|---|
| **Access control** | permitted read/write pass and round-trip intact; read-only and write-only regions enforced in both directions; unmapped addresses denied by default; a denied read returns **zeros**, not the peripheral's data; the fault registers capture address, direction and type |
| **Fault isolation** | a wedged peripheral produces a timeout instead of a lockup — *the CPU keeps running*; `ISOLATED`, `BLOCKED` and `WR_CMD_STUCK` set; traffic while blocked is rejected rather than stalled; acknowledging alone does **not** reopen the downstream |
| **Recovery** | the full v2.0 sequence, with the peripheral held in reset across `UNBLOCK`; no stale write lands; traffic resumes correctly |
| **The other timeout shape** | accept-then-silent sets `RD_RESP_BUSY` and leaves `RD_CMD_STUCK` clear — the case where an unbounded poll would hang, and the reason the driver bounds it |
| **Bypass** | `CTRL.GLOBAL_ENABLE` = 0 forwards unchecked; restoring it denies again |

### Two bugs the hardware found that simulation could not

Both were in the *test program*, not the core, and both are only reachable
with a real processor:

**The ISR was destroying its own evidence.** The obvious interrupt handler
calls `firewall_ack()` so the level-sensitive `irq` deasserts. That also
clears the sticky `STATUS` bits — and on hardware the ISR wins the race
against the code about to read them. On the first hardware run *every*
sticky-bit check failed and *every* live-bit check passed, which is what
pointed at the handler. The fix is to **mask** the interrupt
(`IRQ_ENABLE = 0`) rather than acknowledge it: the interrupt stops
re-entering, and the fault is still there to be read.

**Stores are posted.** A Nios II/f store returns before the transaction
reaches the firewall, so reading `STATUS` immediately afterwards can look at
the core before the offending write has been evaluated. `probe_write()` reads
back from the same slave first, which forces the write to complete — Avalon
keeps one master's accesses to one slave in order. Reads need no such flush;
the processor stalls until data returns.

Neither is a defect in the core. Both are exactly the kind of thing a
testbench cannot find, because a testbench has no cache, no interrupt latency
and no posted writes.

---

## Measured results

Quartus Prime 18.1.1 Standard, `10M50DAF484C7G`, 100 MHz, full compile, 0 errors.

| Resource | Used | Device | % |
|---|---|---|---|
| Total logic elements | 5,863 | 49,760 | 12% |
| — combinational functions | 5,169 | 49,760 | 10% |
| — dedicated logic registers | 3,344 | 49,760 | 7% |
| Total memory bits | 1,112,128 | 1,677,312 | 66% |
| Embedded multipliers (9-bit) | 6 | 288 | 2% |
| PLLs | 1 | 4 | 25% |
| Pins | 23 | 360 | 6% |

By entity:

| Entity | Logic elements | Registers |
|---|---|---|
| **`axi_firewall_top`** (`ADDR_WIDTH` = 12) | **1,391** | **544** |
| └ `axi_firewall_regs` | 1,050 | 327 |
| `firewall_sys_cpu` (Nios II/f) | 2,594 | 1,526 |
| `demo_target_slave` | 726 | 598 |

The core is 1,391 LEs here against **1,908** in the RTL example, for the same
`NUM_RULES` = 8. The only difference is `ADDR_WIDTH`, 12 versus 32 — which is
direct evidence that the rule table and its comparators dominate the core's
area, as the user guide predicts.

### Timing — 100 MHz, slow 1200 mV 85 °C

| Metric | Value |
|---|---|
| Fmax | **112.57 MHz** |
| Setup slack | **+1.117 ns** |
| Hold slack | **+0.224 ns** |
| Total negative slack | 0.000 |

**Timing closes at 100 MHz, and it needed no RTL change** — but it does need
the optimisation settings in the `.qsf`. At Quartus defaults this design
reaches 95.27 MHz and misses by 0.496 ns, on the firewall's read-side rule
lookup (`captured_araddr` → `s_axi_rdata`). `High Performance Effort` plus
physical synthesis closes the gap. If you raise `NUM_RULES` the priority chain
lengthens and that may stop being enough; the structural fix at that point is
to register the lookup and accept one more cycle of latency in EVAL, as the
user guide describes.

---

## What is and isn't verified

| Item | Status |
|---|---|
| Platform Designer import of `axi_firewall_hw.tcl` | **Works.** All six interfaces and five parameters are recognised — this was previously listed as never attempted |
| Behaviour inside generated Qsys interconnect | **Verified** — Avalon-MM master through an Avalon-to-AXI bridge |
| **All 33 checks on a physical DE10-Lite** | **Passing** |
| Nios II/f BSP and application | **Built and run** — 75 KB ELF, `ALT_CPU_FREQ` = 100 MHz |
| Timing closure at 100 MHz | **Met**, +1.117 ns |
| Pin assignments | **Diffed against the DE10-Lite Golden Top — all match** |
| Driver host tests | **30/30** (`software/test/`) |
| `NUM_RULES` other than 8, `ADDR_WIDTH` other than 12 | **Not swept** in this system |

---

## Files

```
example/de10_lite_nios/
├── README.md                   This file
├── build.sh                    Qsys system -> BSP -> application -> bitstream
├── run_on_board.sh             Program, run and check, non-interactively
├── qsys/
│   ├── build_system.tcl        The system, as a reviewable script (source of truth)
│   └── firewall_sys.qsys       Generated from it, and tracked so the GUI can open it
├── rtl/
│   └── de10_lite_nios_top.sv   Board wrapper: clock, PLL reset sequencing, fault wiring
├── quartus/                    Project, pin assignments, 100 MHz constraints
└── software/
    ├── main.c                  The 33-check application
    └── test/                   30 host tests for the driver's ordering
```

**There is no copy of the driver here.** It comes from the component's
[`axi4_lite_firewall_sw.tcl`](../../axi4_lite_firewall_sw.tcl), which the BSP
generator finds on the IP search path and matches to the hardware by
`hw_class_name`. Adding the firewall to a Platform Designer system is enough:
the BSP compiles `drivers/src/altera_axi4_lite_firewall.c` and puts the headers
on the include path.

That also means `alt_sys_init.c` constructs and initialises the device before
`main()` runs — it emits

```c
ALTERA_AXI4_LITE_FIREWALL_INSTANCE ( FW, fw);
ALTERA_AXI4_LITE_FIREWALL_INIT ( FW, fw);
```

so `main.c` only declares `extern alt_axi4_lite_firewall_dev fw;`. The
"Core found: v2.0, 8 rules" line it prints is read back out of that structure,
which is how the program proves auto-initialisation actually ran.

> **The application overrides the driver's ISR, on purpose.** The driver's
> default ISR acknowledges the sticky STATUS bits, which is right for an
> application — the irq is level sensitive and would otherwise re-enter
> forever. It is wrong for *this* program, whose checks read those bits back:
> acknowledging destroys the evidence. `main.c` registers its own handler,
> which masks instead of acknowledging. Registering a second handler on the
> same irq replaces the first, so that is all it takes.

The protected peripheral is shared with the RTL example and lives in
[`../common/`](../common/).
