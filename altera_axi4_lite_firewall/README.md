# AXI4-Lite Firewall — Quartus / Platform Designer IP core

A custom **access-control + fault-isolation firewall** for Intel/Altera
Quartus and Platform Designer (Qsys). There is no stock "AXI Firewall" in the
Altera IP catalog (unlike Xilinx's Vivado isolation flow), so this is a
from-scratch component: synthesizable Verilog-2001, a Platform Designer
component wrapper, a self-checking testbench, SystemVerilog assertions, and a
Questa flow with coverage collection.

**Component:** `altera_axi4_lite_firewall` · displayed in the IP Catalog as
**"AXI4-Lite Firewall"** under *Bridges and Adapters / Custom* · v1.1

---

## What it does

Sits between a bus master and a peripheral you want to protect:

```
                  ┌──────────────────────────────┐
   AXI4-Lite      │                              │    AXI4-Lite
 ────────────────▶│  s_axi            m_axi      │───────────────▶
  (from master,   │      axi_firewall_top        │   (to protected
   e.g. Nios II)  │                              │    peripheral)
                  │       s_axi_ctrl    irq      │
                  └───────────┬──────────┬───────┘
                              │          │
                       AXI4-Lite      interrupt
                    (config/status)  (to Nios II)
```

1. **Access control** — every transaction's address is checked against a
   software-programmable table of allowed address ranges, each with
   independent read/write permission. Default-deny: an address matching no
   rule is rejected (DECERR), as is an address matching a rule but not for
   the direction requested (SLVERR).
2. **Fault isolation** — every forwarded transaction is watched by a timeout
   counter. If the peripheral never responds, the firewall synthesizes an
   error response itself (so the master never hangs) and — if auto-isolate is
   enabled — latches into an ISOLATED state that rejects all further
   transactions without touching the peripheral again, until software
   acknowledges the fault.
3. **Violations raise an interrupt** to the CPU in addition to returning
   SLVERR/DECERR.

Control/status live on a **separate** AXI4-Lite port (`s_axi_ctrl`), so
configuring or inspecting the firewall is never itself subject to firewall
rules, nor blockable by an isolated peripheral.

---

## Repository layout

```
altera_axi4_lite_firewall/
├── README.md                       This file
├── axi_firewall_hw.tcl             Platform Designer component description
├── rtl/
│   ├── axi_firewall_top.v          Datapath: s_axi, m_axi, permission checks,
│   │                               timeout / isolate FSMs
│   └── axi_firewall_regs.v         Rule table, status/IRQ, control AXI4-Lite slave
├── tb/
│   ├── axi_firewall_tb.v           Self-checking testbench (40 checks) + SVA bind
│   └── axi_firewall_sva.sv         SystemVerilog assertions & cover points
└── simulation/questa/
    └── run_sim.tcl                  Compile + elaborate + run + save coverage

Simulation outputs (`work/`, `*.ucdb`, `coverage_report.txt`, `modelsim.ini`,
`transcript`, `*.wlf`) are build artifacts and are gitignored - `run_sim.tcl`
regenerates them.
```

To expose this (and sibling cores) to Platform Designer, add the repository's
**top-level directory** to the IP search path — see the repo root README.

---

## Parameters

| Parameter | Default | Notes |
|---|---|---|
| `ADDR_WIDTH` | 32 | Data-path address width |
| `DATA_WIDTH` | 32 | Data-path data width (32 or 64) |
| `CTRL_ADDR_WIDTH` | 12 | Control port address width; must cover `0x40 + NUM_RULES*16` bytes |
| `NUM_RULES` | 8 | Number of address-range rules |
| `TIMEOUT_WIDTH` | 20 | Max programmable timeout is `2^TIMEOUT_WIDTH − 1` clk cycles |
| `RESET_HOLD_CYCLES` | 16 | How long `m_axi_resetn` is held low during downstream recovery. Must exceed the protected peripheral's minimum reset pulse width. |

`CTRL_ADDR_WIDTH` must be wide enough to reach the whole rule table
(`0x40 + NUM_RULES*16` bytes). A validation callback in `hw.tcl` enforces
this — previously an undersized control port silently made high-index rules
unreachable.

---

## Register map (`s_axi_ctrl`, 32-bit registers, word-aligned)

| Offset | Name | Access | Description |
|---|---|---|---|
| 0x00 | CTRL | R/W | bit0 `GLOBAL_ENABLE` (default **1**, secure-by-default); bit1 `AUTO_ISOLATE_EN` (default 1); bit2 `MANUAL_ISOLATE` |
| 0x04 | STATUS | R, W1C on [2:0] | bit0 `ADDR_VIOLATION`, bit1 `PERM_VIOLATION`, bit2 `TIMEOUT_ERROR` (sticky, write-1-to-clear); bit3 `ISOLATED` (live, read-only — `MANUAL_ISOLATE` OR the internal auto-isolate latch) |
| 0x08 | IRQ_ENABLE | R/W | bits 0/1/2 enable IRQ for ADDR / PERM / TIMEOUT (default all enabled) |
| 0x0C | TIMEOUT_VALUE | R/W | Round-trip timeout in clk cycles (default all-ones ⇒ effectively disabled until set) |
| 0x10 | FAULT_ADDR | R | Address of the most recently latched fault |
| 0x14 | FAULT_INFO | R | bit0 `WAS_WRITE` (0 ⇒ the fault came from a read); bits[3:1] type (1=ADDR, 2=PERM, 3=TIMEOUT) |
| 0x18 | CORE_INFO | R | bits[7:0] `NUM_RULES` as generated; bits[31:16] version (0x0100 = v1.0) |
| 0x40 + i·0x10 | `RULE_BASE[i]` | R/W | Inclusive base address of range *i* |
| 0x44 + i·0x10 | `RULE_LIMIT[i]` | R/W | Inclusive top address of range *i* |
| 0x48 + i·0x10 | `RULE_PERM[i]` | R/W | bit0 `READ_ALLOW`, bit1 `WRITE_ALLOW`, bit2 `VALID` (rule ignored entirely if 0) |

`i` runs `0 … NUM_RULES-1` (default 8 rules ⇒ table spans 0x40–0xBF).

Clearing `STATUS.TIMEOUT_ERROR` also releases the auto-isolate latch — this is
deliberate: recovering from isolation requires acknowledging why it happened,
not just flipping a bit blind.

---

## Design decisions worth knowing

- **AXI4-Lite carries no ID field**, so this core cannot distinguish *which
  master* issued a transaction — only what address it targets and whether
  it's a read or a write. Access control is address-range + direction, not
  per-master identity. Per-master filtering needs full AXI4 (which carries
  `AWID`/`ARID`) or a sideband master-ID signal.
- **Rule priority**: the lowest-index valid rule containing the address wins.
  Rules need not be non-overlapping — put more specific rules at lower
  indices if you use overlapping ranges.
- **In-flight transactions aren't aborted by ISOLATE.** Work already
  forwarded to `m_axi` finishes or times out normally; only *new*
  transactions are blocked immediately. Aborting mid-flight isn't
  well-defined in AXI once the address phase is accepted.
- **`m_axi_bready` / `m_axi_rready` are tied high permanently.** The point of
  an isolation core is that a wedged peripheral can never stall anything
  upstream — including itself. A late response is absorbed rather than
  leaving a channel stuck. See *Timeout recovery* for how the core avoids
  mistaking an absorbed late response for a current one.
- **Timeout recovery never withdraws an asserted `m_axi_*VALID`** (v1.1).
  AXI requires VALID to hold until READY; withdrawing it can wedge the
  interconnect between the firewall and the peripheral, not just the
  peripheral. See below.
- **Timeout covers the whole round trip** (address issue → response), so it
  also catches a peripheral that never even raises AWREADY/ARREADY, not just
  one that accepts and then goes quiet.
- **Simultaneous read+write fault in the same cycle**: both sticky STATUS
  bits set correctly, but `FAULT_ADDR`/`FAULT_INFO` capture the write side —
  a documented, deterministic tie-break.
- **Single-outstanding transaction per channel** (no pipelining). Standard
  for AXI4-Lite control traffic and keeps the FSMs simple; see *Performance*
  below before putting a DMA engine behind it.

---

## Timeout recovery and `m_axi_resetn`

When a forwarded transaction times out, the core:

1. reports **SLVERR upstream immediately**, so the master never hangs;
2. latches an internal *downstream-broken* state that blocks **all** further
   forwarding — independently of `CTRL.AUTO_ISOLATE_EN`, which governs only
   the visible `ISOLATED` status bit;
3. **leaves the stuck `m_axi_*VALID` asserted**, because AXI forbids
   withdrawing it before the handshake.

Software recovers by writing 1 to `STATUS.TIMEOUT_ERROR`. That pulses
`m_axi_resetn` low for `RESET_HOLD_CYCLES`, flushing the peripheral — the
only point at which the stuck VALID is dropped, since AXI state is moot
while a device is in reset. Forwarding then reopens automatically.

A transaction arriving during the reset pulse is **stalled**, not rejected —
a bounded wait of at most `RESET_HOLD_CYCLES`, so recovery is invisible to
the master and needs no retry logic.

> **`m_axi_resetn` must be connected to the protected peripheral's reset.**
> It is what guarantees a peripheral left mid-transaction cannot later emit
> a stale response that gets mis-attributed to a subsequent transaction.
> Measured: with the reset connected, 0 of 25 tested timing offsets show
> mis-attribution; with it left unconnected, 1 of 25 does.

The core additionally arms a one-shot response-discard flag, but only in the
case where a response is *provably* still owed (the address handshake
completed and the response never arrived). It is deliberately not armed when
the address handshake never completed: a compliant peripheral owes nothing
there, and an orphaned response is indistinguishable from a legitimate one
without transaction IDs, which AXI4-Lite does not have. The discard flag is a
narrow safety net; `m_axi_resetn` is the actual fix.

## Performance

Measured in simulation against a zero-wait-state downstream slave
(`tb/` latency benchmark, best case):

| Operation | Cycles |
|---|---|
| Single write (request asserted → BVALID) | **6** |
| Single read (request asserted → RVALID) | **6** |

This is a single-outstanding, non-pipelined design, so cost is per
transaction and does not amortize. That's fine for register-style peripherals
a CPU pokes occasionally.

**It is not fine for bursting masters.** An mSGDMA (or any burst-capable
Avalon-MM master) gets split into single beats by Platform Designer's burst
adapter, and every beat then pays the full 6-cycle cost — roughly 6× the
cycles of a native burst path. If a DMA engine sits in front of this core,
use a burst-capable AXI4 variant instead (see *Roadmap*).

---

## Verification

### Test suite — 50/50 passing

`tb/axi_firewall_tb.v` is self-checking and needs no Quartus licence; it runs
under Icarus Verilog as well as Questa. The SVA bind is wrapped in
`` `ifndef ICARUS ``, so the Icarus command below works unmodified. Coverage:

- Allowed read and write, with data integrity checks
- Permission denial on writes (SLVERR + sticky status + IRQ assertion)
- Unmapped address on writes (DECERR + sticky status)
- **Read-denial path** (tests J–M): permission-denied read, unmapped read,
  denied reads returning zeroed RDATA rather than stale data, and reads
  blocked while ISOLATED — with an explicit watcher asserting `m_axi_arvalid`
  never fires during isolation
- `FAULT_INFO.WAS_WRITE` correctness in both directions, and `FAULT_ADDR`
  capture from the read path
- Downstream timeout → auto-isolate → immediate block of the next access,
  with an explicit watcher asserting `m_axi_awvalid` never fires
- W1C recovery, IRQ masking, manual isolation, global bypass mode
- **Read-side timeout** (test N): hung peripheral on a read → SLVERR,
  `TIMEOUT_ERROR`, `FAULT_INFO.WAS_WRITE = 0`
- **Downstream recovery** (tests O–P): `m_axi_resetn` asserted while broken,
  forwarding blocked with an explicit watcher on `m_axi_arvalid`, reset
  released after acknowledgement, traffic correct afterwards
- **Master-side AXI protocol checking**: a checker counts any
  `m_axi_*VALID` dropped without a handshake outside the reset window, and
  fails the run if any occur
- Register-map sweep including unmapped offsets, and staggered
  AW/W channel arrival on the control port

### Assertions

`tb/axi_firewall_sva.sv` is bound into `axi_firewall_top` and checks:

- **Containment** — a violation never leaks `AWVALID`/`ARVALID` downstream
- **Liveness** — each violation gets an error response *on its own channel*
  (B for writes, R for reads) within 10 cycles
- **Handshake stability** — VALID holds until READY on all four `s_axi`
  channels **and on the `m_axi` side** (added v1.1: the master side was
  previously unchecked, which is why the timeout path's protocol violation
  survived a full assertion + coverage run)
- **No transaction issued while the peripheral is held in reset**
- **Cover points** — that the write- and read-denial paths were actually
  *reached*, not merely never violated

The bind passes the **per-direction** fault pulses:

```verilog
.wr_violation(wr_fault_addr_violation | wr_fault_perm_violation),
.rd_violation(rd_fault_addr_violation | rd_fault_perm_violation)
```

Not the merged `fault_*_violation` wires — those OR both directions together,
which would make any read-channel assertion wait forever on `BVALID`.

### Running it

**Icarus** (functional tests only — `-DICARUS` skips the SVA bind, which
Icarus cannot compile):

```bash
iverilog -g2005 -DICARUS -o tb.out rtl/axi_firewall_regs.v rtl/axi_firewall_top.v tb/axi_firewall_tb.v
vvp tb.out
```

**Questa** (full flow with assertions and coverage) — `cd` into
`simulation/questa/` first:

```tcl
do run_sim.tcl
```

That compiles RTL + SVA + testbench with `+cover=sbceft`, runs to completion,
then writes `coverage.ucdb` and `coverage_report.txt`.

### Coverage status

From the last full Questa run (`simulation/questa/coverage_report.txt`),
**before** the read-denial tests were added:

| Metric (instance `dut`) | Result |
|---|---|
| FSM states | 8 / 8 — 100% |
| FSM transitions | 9 / 14 — 64.28% |
| Statements | 96.61% (`u_regs`) · 75.80% (`dut`) |
| Branches | 78.72% (`u_regs`) · 79.62% (`dut`) |
| Conditions | 83.33% (`u_regs`) · 55.55% (`dut`) |
| Toggle | 34.76% (`u_regs`) · 41.20% (`dut`) |

The uncovered FSM transitions were:

| Transition | Cause | Status |
|---|---|---|
| `RD_EVAL → RD_RESP` | **Real gap** — every denial test was a write, so the read-denial path was never entered | **Closed** by tests J–M |
| read-path timeout branch | Never exercised — the only hang test was a write | **Closed** by test N |
| `WR_EVAL → WR_IDLE` | Reset asserted mid-transaction | Open |
| `WR_FWD → WR_IDLE` | Reset asserted mid-transaction | Open |
| `RD_EVAL → RD_IDLE` | Reset asserted mid-transaction | Open |
| `RD_FWD → RD_IDLE` | Reset asserted mid-transaction | Open |

`RD_EVAL → RD_RESP` mattered: the read path has its own FSM, its own rule
lookup port (`chk_r_*`), and its own fault signals, and the
`fault_addr_value` mux had never selected its read branch. All 15 new checks
passed on the first run, so the RTL was correct — it was simply unverified.

The four remaining misses are all reset-asserted-mid-transaction cases. Worth
a deliberate test if you want them closed; they are not functional holes.

**Re-run `run_sim.tcl` to regenerate coverage with tests J–M included** — the
numbers above predate them, and the committed `coverage_report.txt` /
`coverage.ucdb` have not yet been refreshed.

---

## Integration into Platform Designer

1. Add the repository's top-level directory to the Quartus IP search path
   (**Tools ▸ Options ▸ IP Catalog Search Locations**), then **Platform
   Designer ▸ File ▸ Refresh System**. The core appears as *AXI4-Lite
   Firewall*.
2. **Confirm the component packages cleanly for your Quartus version.**
   `hw.tcl` syntax has drifted across releases (Standard vs Pro, version to
   version). If it doesn't import: open Component Editor, add both files
   under `rtl/` as synthesis files with `axi_firewall_top.v` as top level,
   and click **Analyze Synthesis Files**. Every port follows the
   `s_axi_*` / `m_axi_*` / `s_axi_ctrl_*` convention with standard AXI4-Lite
   suffixes, so signal analysis should auto-group them into three AXI4-Lite
   interfaces; fix anything it misses in *Signals & Interfaces*, then
   **Finish** to regenerate a `hw.tcl` correct for your toolchain.
3. Instantiate it in your system.
4. **No manual bridge is needed.** Nios II is Avalon-MM natively, but per
   Intel's Platform Designer documentation you can connect AXI and Avalon
   interfaces without explicitly instantiated bridges — the interconnect
   provides the bridging logic. Connect the master's `data_master` directly
   to `s_axi` and `s_axi_ctrl`, and `m_axi` directly to the protected
   peripheral (Avalon-MM or AXI4-Lite either way). An explicit *AXI Bridge
   Intel FPGA IP* is available if you ever want to trade concurrency for less
   interconnect logic, but it's optional.
5. **Connect `m_axi_reset` (the `m_axi_resetn` output) to the protected
   peripheral's reset input.** This is required, not optional — see
   *Timeout recovery* above. If the peripheral shares a reset with other
   logic, give it a dedicated reset so the firewall can flush it
   independently.
6. Wire `irq` to a CPU interrupt input.
7. Connect `clock` / `reset` to your system clock and reset network.
8. Program each rule's base/limit to match the peripheral's actual address
   decode, and size `NUM_RULES` / `CTRL_ADDR_WIDTH` for how many ranges you
   need.

---

## Software reference (Nios II HAL style)

```c
#include "sys/alt_irq.h"
#include "io.h"

/* Exact macro name comes from system.h; it follows the instance name
   Platform Designer assigns, e.g. ALTERA_AXI4_LITE_FIREWALL_0_S_AXI_CTRL_BASE */
#define FW_BASE        ALTERA_AXI4_LITE_FIREWALL_0_S_AXI_CTRL_BASE

#define FW_CTRL        0x00
#define FW_STATUS      0x04
#define FW_IRQ_ENABLE  0x08
#define FW_TIMEOUT     0x0C
#define FW_FAULT_ADDR  0x10
#define FW_FAULT_INFO  0x14
#define FW_CORE_INFO   0x18
#define FW_RULE(i, r)  (0x40 + (i)*0x10 + (r))   /* r: 0=BASE 4=LIMIT 8=PERM */

#define FW_PERM_READ   0x1
#define FW_PERM_WRITE  0x2
#define FW_PERM_VALID  0x4

#define FW_STAT_ADDR_VIOL  0x1
#define FW_STAT_PERM_VIOL  0x2
#define FW_STAT_TIMEOUT    0x4
#define FW_STAT_ISOLATED   0x8   /* read-only, live */
#define FW_STAT_STICKY     0x7   /* the W1C-able bits */

/* Rules are three separate registers, so updating a rule that is currently
   VALID leaves a transient window where BASE is new but LIMIT is still old.
   Always clear VALID first when reconfiguring a live rule:
       IOWR_32DIRECT(FW_BASE, FW_RULE(i,8), 0);       // retire the rule
       IOWR_32DIRECT(FW_BASE, FW_RULE(i,0), new_base);
       IOWR_32DIRECT(FW_BASE, FW_RULE(i,4), new_limit);
       IOWR_32DIRECT(FW_BASE, FW_RULE(i,8), perms | FW_PERM_VALID);
   At init this is unnecessary - VALID is 0 out of reset. */

void firewall_init(void)
{
    /* Rule 0: 0x1000-0x1FFF, read + write allowed */
    IOWR_32DIRECT(FW_BASE, FW_RULE(0, 0), 0x1000);
    IOWR_32DIRECT(FW_BASE, FW_RULE(0, 4), 0x1FFF);
    IOWR_32DIRECT(FW_BASE, FW_RULE(0, 8),
                  FW_PERM_VALID | FW_PERM_WRITE | FW_PERM_READ);

    /* Round-trip budget in clk cycles - tune for your clock and peripheral */
    IOWR_32DIRECT(FW_BASE, FW_TIMEOUT, 50000);
}

static void firewall_isr(void *context)
{
    alt_u32 status = IORD_32DIRECT(FW_BASE, FW_STATUS);

    if (status & FW_STAT_STICKY) {
        alt_u32 addr = IORD_32DIRECT(FW_BASE, FW_FAULT_ADDR);
        alt_u32 info = IORD_32DIRECT(FW_BASE, FW_FAULT_INFO);
        int was_write = info & 0x1;
        int type      = (info >> 1) & 0x7;   /* 1=ADDR 2=PERM 3=TIMEOUT */

        (void)addr; (void)was_write; (void)type;   /* log / handle */

        /* W1C. Clearing TIMEOUT also releases auto-isolate AND starts the
           downstream recovery pulse on m_axi_resetn. No wait or retry is
           needed: transactions arriving during the pulse are stalled, not
           rejected. */
        IOWR_32DIRECT(FW_BASE, FW_STATUS, status & FW_STAT_STICKY);
    }
}
```

---

## Verification status — what is and isn't proven

| Item | Status |
|---|---|
| Functional testbench (40 checks) | Run and passing under Icarus Verilog |
| Best-case latency (6 cycles r/w) | Measured in simulation |
| SVA properties | **Written and reviewed, still never executed** — Icarus cannot run SVA. Re-run `run_sim.tcl` and check the assertion report. The master-side properties added in v1.1 are equally unrun; their plain-Verilog equivalent in the testbench does pass. |
| Coverage figures above | From a run **predating** tests J–P; needs regeneration |
| Synthesis results (LE/register count, Fmax) | **Not measured.** The combinational rule lookup scales with `NUM_RULES` and is the likeliest critical path; if it limits Fmax, registering that lookup with an extra pipeline stage is the standard fix |
| Behaviour inside a real Platform Designer system | **Not verified end to end.** The testbench models a well-behaved AXI4-Lite slave, not Platform Designer's generated interconnect |

---

## Roadmap / possible extensions

- **Burst-capable AXI4 variant** — the main one, if a DMA engine (mSGDMA)
  sits in front of the firewall. See *Performance*.
- **Per-master (per-ID) filtering** — requires full AXI4 or a sideband ID
  signal; not expressible in AXI4-Lite.
- Reset-during-transaction tests, to close the four remaining FSM transitions.
- `AWPROT`/`ARPROT`-based filtering (privileged / secure / instruction-vs-data).
  Both are already captured and forwarded; a per-rule qualifier would be cheap.
- Separate fault-address latches per fault type instead of one shared latch.
- Rule-hit counters per range, for auditing and profiling access patterns.
