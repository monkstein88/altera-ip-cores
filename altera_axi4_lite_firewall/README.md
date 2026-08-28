# AXI4-Lite Firewall — Quartus / Platform Designer IP core

A custom **access-control + fault-isolation firewall** for Intel/Altera
Quartus and Platform Designer (Qsys). There is no stock "AXI Firewall" in the
Altera IP catalog (unlike Xilinx's Vivado isolation flow), so this is a
from-scratch component: synthesisable SystemVerilog, a Platform Designer
component wrapper, a self-checking testbench, SystemVerilog assertions, and
both a Questa flow with coverage collection and a licence-free Verilator flow.

**Component:** `altera_axi4_lite_firewall` · displayed in the IP Catalog as
**"AXI4-Lite Firewall"** under *Bridges and Adapters / Custom* · v2.0

### Documentation

| Document | What it is |
|---|---|
| [User guide (PDF)](doc/axi4_lite_firewall_user_guide.pdf) | 40 pages, Altera-style: getting started, functional description with timing diagrams, parameters, signals, register map, programming model, verification, limitations |
| [User guide (Markdown)](doc/axi4_lite_firewall_user_guide.md) | Same document, readable in the browser |
| [Block diagrams (PDF)](doc/axi4_lite_firewall_block_diagrams.pdf) | Architecture companion: system context, internal architecture, FSMs, register map |
| [Block diagrams (Markdown)](doc/axi4_lite_firewall_block_diagrams.md) | Same document, readable in the browser |
| [DE10-Lite RTL demo](example/de10_lite_rtl/README.md) | Self-checking hardware demonstration: 16 scenarios, no CPU or software. **Verified on a physical board.** Where this core's synthesis and Fmax numbers come from |
| [DE10-Lite Nios II demo](example/de10_lite_nios/README.md) | The same core driven by C on a Nios II/f at 100 MHz, inside a generated Platform Designer system. **33/33 checks pass on hardware** |
| This README | Design rationale and the reasoning behind the decisions — the parts a user guide has no room for |

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
├── README.md                     This file
├── axi_firewall_hw.tcl           Platform Designer component description
├── rtl/
│   ├── axi_firewall_top.sv       Datapath: s_axi, m_axi, permission checks,
│   │                             timeout / isolate FSMs
│   └── axi_firewall_regs.sv      Rule table, status/IRQ, control AXI4-Lite slave
├── tb/
│   ├── axi_firewall_tb.sv        Self-checking testbench (103 checks) + SVA bind
│   └── axi_firewall_sva.sv       SystemVerilog assertions & cover points
├── simulation/
│   ├── questa/run_sim.tcl        Compile + run + coverage (incl. assertions)
│   ├── verilator/run_sim.sh      Licence-free regression (assertions, no coverage)
│   └── verilator/slangcheck.py   Strict LRM elaboration gate (see Toolchain)
├── HAL/                          Nios II HAL driver, picked up automatically by
│   ├── inc/                      the BSP - see axi4_lite_firewall_sw.tcl
│   └── src/
├── inc/                          Register map on its own, no driver needed
├── axi4_lite_firewall_sw.tcl     BSP driver description
├── example/                      Two DE10-Lite (MAX 10) demonstrations, both
│   │                             verified on physical hardware
│   ├── common/                   The protected peripheral, shared by both
│   ├── de10_lite_rtl/            No CPU: a hardware sequencer runs 16 self-
│   │                             checking scenarios. 50 MHz
│   └── de10_lite_nios/           Nios II/f at 100 MHz in a Platform Designer
│                                 system, driven by the BSP's copy of the
│                                 HAL driver above. 33 checks
├── verification/                 Standalone benches, outside the main suite
│   ├── orphan_response_tb.sv     Measures the cost of skipping the peripheral
│   │                             reset during recovery - see Timeout recovery
│   ├── wave_capture_tb.sv        Drives the scenarios the user guide's timing
│   │                             figures are rendered from
│   └── README.md                 How to run them, and what they produce
└── doc/                         Documents here; everything else is generated
    ├── axi4_lite_firewall_user_guide.md    User guide, Altera-style - source
    ├── axi4_lite_firewall_user_guide.pdf   of truth and typeset, 40 pages
    ├── axi4_lite_firewall_block_diagrams.md    Architecture companion -
    ├── axi4_lite_firewall_block_diagrams.pdf   same, 15 pages
    ├── figures/                  All 8 figures, all SVG, all generated
    └── tools/                    The generators
        ├── build_pdf.py          Markdown -> HTML -> PDF, both documents
        ├── check_facts.py        Re-derives every number in both documents
        │                         from the RTL; fails if any has drifted
        ├── README.md             How to regenerate, and why not ODF
        ├── diagrams/             Block diagrams, drawn from code
        │   ├── build_figures.py  Content and layout of all four
        │   ├── svg_lib.py        SVG canvas with real-font text layout
        │   └── README.md
        └── waveforms/            Timing diagrams, captured from simulation
            ├── wavedraw.py       VCD parser and SVG waveform renderer
            ├── mkwaves.py        Cuts four scenarios out of a VCD
            ├── check_figures.py  Compares the SVGs back against the VCD
            └── README.md         The bench itself is in verification/

Simulation outputs (`work/`, `obj_dir/`, `*.ucdb`, `coverage_report.txt`,
`modelsim.ini`, `run.log`, `transcript`, `*.wlf`) are build artifacts, listed
in `.gitignore`, and regenerated by the run scripts.
Do not cite a checked-in one as a current result — that is how a transcript
from an older, shorter run once ended up being quoted as the suite's status.
```

To expose this (and sibling cores) to Platform Designer, add the repository's
**top-level directory** to the IP search path — see the repo root README.

---

## Language

Everything is SystemVerilog (IEEE 1800). The RTL sticks to the synthesisable
subset Quartus Prime accepts: `logic`, `always_ff`/`always_comb`, packed
structs, enums, unpacked-array shorthand, `$clog2`, and functions with
`return`. Nothing simulation-only appears in `rtl/`.

What that buys over the Verilog-2001 the core started as:

- **Enum-typed FSM states.** Questa names the states in its FSM coverage
  report instead of showing bare `2'b01` encodings.
- **`always_ff`/`always_comb`** — the tool checks the inferred hardware
  matches the intent, rather than trusting `always @(*)` sensitivity lists.
- **A packed `rule_perm_t` struct** replacing three parallel arrays, so
  `RULE_PERM[2:0]` has one definition rather than being reassembled by hand at
  every read and write site.
- **Width-correct byte-strobe merging.** The Verilog-2001 rule writes hard-wired
  `[31:24]` slices, so any `ADDR_WIDTH` under 32 — which `hw.tcl` has always
  permitted — was an out-of-range part-select. The parameterised
  `merge_addr_field()` function is correct for any `ADDR_WIDTH ≤ 32`, and the
  RTL now lints clean at `verilator --lint-only -Wall` across the whole
  parameter space.
- **`$clog2`** in place of a hand-rolled constant function.
- **Every file carries a `` `timescale ``**, RTL included. Mixing timescaled
  and untimescaled modules in one compilation is tool-dependent (IEEE 1800
  3.14.2.3): slang rejects it, Verilator warns, Questa accepts it silently.
  Quartus ignores the directive for synthesis, so declaring it costs nothing.

> **One conversion hazard worth knowing**, because it cost a debugging round
> here: `wire x = expr;` is a *continuous assignment*, but `logic x = expr;` is
> a variable declaration with an *initialiser* — evaluated once at time 0 and
> never again. A blind `wire`→`logic` sweep silently freezes such signals.
> Write `logic x; assign x = expr;`. The symptom is not a compile error; it is
> a signal stuck at its power-on value.

---

## Toolchain

Three front ends, because they disagree about what is legal and the
disagreements are where bugs hide:

| Tool | Role | Catches |
|---|---|---|
| **Verilator 5.48** | regression + `-Wall` lint | functional bugs, width and lint issues |
| **slang 11** | strict LRM elaboration, no simulation | use-before-declaration, implicit-net collisions, timescale mixing |
| **Questa 2024.1** | coverage, assertion non-vacuity | vacuous assertions, FSM/directive coverage |

That combination exists because each has missed something the others caught.
Verilator ran 99 checks green on code Questa refused to compile — an
identifier connected to a port before its declaration creates an implicit net
that collides with the later declaration, and Verilator resolves the forward
reference instead. slang catches that class in under a second without
simulating, so it belongs in the loop before Questa. Conversely Questa is the
only one of the three that reports assertion non-vacuity, which is how two
permanently-vacuous properties were found.

`simulation/verilator/run_sim.sh` runs the slang check first and stops on
error, so the strict pass happens before anything is built:

```bash
pip install pyslang                    # enables the strict gate
simulation/verilator/run_sim.sh        # slang -> lint -> build -> regression
```

---

## Parameters

| Parameter | Default | Notes |
|---|---|---|
| `ADDR_WIDTH` | 32 | Data-path address width |
| `DATA_WIDTH` | 32 | Data-path data width (32 or 64) |
| `CTRL_ADDR_WIDTH` | 12 | Control port address width; must cover `0x40 + NUM_RULES*16` bytes |
| `NUM_RULES` | 8 | Number of address-range rules |
| `TIMEOUT_WIDTH` | 20 | Max programmable timeout is `2^TIMEOUT_WIDTH − 1` clk cycles |

`CTRL_ADDR_WIDTH` must be wide enough to reach the whole rule table
(`0x40 + NUM_RULES*16` bytes). A validation callback in `hw.tcl` enforces
this — previously an undersized control port silently made high-index rules
unreachable.

---

## Register map (`s_axi_ctrl`, 32-bit registers, word-aligned)

| Offset | Name | Access | Description |
|---|---|---|---|
| 0x00 | CTRL | R/W | bit0 `GLOBAL_ENABLE` (default **1**, secure-by-default); bit1 `AUTO_ISOLATE_EN` (default 1); bit2 `MANUAL_ISOLATE` |
| 0x04 | STATUS | R, W1C on [2:0] | bit0 `ADDR_VIOLATION`, bit1 `PERM_VIOLATION`, bit2 `TIMEOUT_ERROR` (sticky, write-1-to-clear); bit3 `ISOLATED`; bit4 `BLOCKED`; bit5 `WR_RESP_BUSY`; bit6 `RD_RESP_BUSY`; bit7 `WR_CMD_STUCK`; bit8 `RD_CMD_STUCK` — bits [8:3] all live and read-only |
| 0x08 | IRQ_ENABLE | R/W | bits 0/1/2 enable IRQ for ADDR / PERM / TIMEOUT (default all enabled) |
| 0x0C | TIMEOUT_VALUE | R/W | Round-trip timeout in clk cycles (default all-ones ⇒ effectively disabled until set) |
| 0x10 | FAULT_ADDR | R | Address of the most recently latched fault |
| 0x14 | FAULT_INFO | R | bit0 `WAS_WRITE` (0 ⇒ the fault came from a read); bits[3:1] type (1=ADDR, 2=PERM, 3=TIMEOUT) |
| 0x18 | CORE_INFO | R | bits[7:0] `NUM_RULES` as generated; bits[31:16] version (0x0200 = v2.0) |
| 0x1C | RECOVERY | W | bit0 `UNBLOCK` — write 1 to reopen the downstream. Self-clearing, reads 0 |
| 0x40 + i·0x10 | `RULE_BASE[i]` | R/W | Inclusive base address of range *i* |
| 0x44 + i·0x10 | `RULE_LIMIT[i]` | R/W | Inclusive top address of range *i* |
| 0x48 + i·0x10 | `RULE_PERM[i]` | R/W | bit0 `READ_ALLOW`, bit1 `WRITE_ALLOW`, bit2 `VALID` (rule ignored entirely if 0) |

`i` runs `0 … NUM_RULES-1` (default 8 rules ⇒ table spans 0x40–0xBF).

Clearing `STATUS.TIMEOUT_ERROR` releases the auto-isolate latch, but **does
not** reopen the downstream. That takes an explicit `RECOVERY.UNBLOCK`, so
acknowledging a fault cannot accidentally restart traffic toward a peripheral
nobody has reset yet. This is the v2.0 behaviour change — see *Timeout
recovery*.

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
  leaving a channel stuck. Nothing in the core distinguishes an absorbed late
  response from a current one, which is why the recovery sequence exists —
  see *Timeout recovery*.
- **A timeout never withdraws an asserted `m_axi_*VALID`.** AXI requires VALID
  to hold until READY; withdrawing it can wedge the interconnect between the
  firewall and the peripheral, not just the peripheral. The stuck VALID is
  withdrawn at exactly one point — the `RECOVERY.UNBLOCK` write, which means
  software has reset the peripheral and its AXI state is gone. See below.
- **Timeout covers the whole round trip** (address issue → response), so it
  also catches a peripheral that never even raises AWREADY/ARREADY, not just
  one that accepts and then goes quiet.
- **Simultaneous read+write fault in the same cycle**: both sticky STATUS
  bits set correctly, but `FAULT_ADDR`/`FAULT_INFO` capture the write side —
  a documented, deterministic tie-break.
- **Single-outstanding transaction per channel** (no pipelining), on the data
  path *and* on `s_axi_ctrl`. Standard for AXI4-Lite control traffic and keeps
  the FSMs simple; see *Performance* below before putting a DMA engine behind
  it. The control port enforces this with backpressure: `AWREADY`/`WREADY` are
  withheld while a `BVALID` is unacknowledged, and `ARREADY` while an `RVALID`
  is. A master that pipelines simply waits.

---

## Timeout recovery

When a forwarded transaction times out, the core:

1. reports **SLVERR upstream immediately**, so the master never hangs;
2. latches an internal *downstream-broken* state that blocks **all** further
   forwarding — independently of `CTRL.AUTO_ISOLATE_EN`, which governs only
   the visible `ISOLATED` status bit;
3. **leaves the stuck `m_axi_*VALID` asserted**, because AXI forbids
   withdrawing it before the handshake.

Recovery is an explicit software sequence:

```c
1.  stop issuing transactions to s_axi
2.  write 1 to the sticky STATUS bits          /* acknowledge the fault    */
3.  poll STATUS until WR_RESP_BUSY and RD_RESP_BUSY clear — WITH A BOUND
4.  reset the protected peripheral             /* >= 16 clocks             */
5.  write 1 to RECOVERY.UNBLOCK
6.  resume
```

This mirrors the sequence AMD document for their AXI Firewall, which has the
same requirement — their step 4 is *"reset all devices on the side of the
firewall being monitored for faults… for a minimum recommended duration of
16 clock cycles"*. Up to v1.2 this core owned a peripheral reset output and
did steps 4–5 itself. That was safer, but demanded a dedicated reset net per
protected peripheral, which shared reset domains and hard IP often can't give
you.

**Bound the poll in step 3.** The busy bits mean *the peripheral owes us a
response*, and a peripheral that accepted a command and then died owes one
forever — an unbounded poll hangs exactly when recovery matters. Treat them as
advisory: clear means no late response can still be in flight and the reset is
unambiguously safe; stuck means reset anyway and let `UNBLOCK` discard what is
owed. `WR_CMD_STUCK`/`RD_CMD_STUCK` tell you the other case — a command the
peripheral never even accepted, which only `UNBLOCK` can clear.

> **Step 4 is not optional, and it must still be in force during step 5.**
> `UNBLOCK` is what withdraws the stuck `m_axi_*VALID`. If the peripheral has not been reset, that is a protocol
> violation on a live bus, and the peripheral may additionally have latched a
> transaction this core already reported to the master as failed. Measured:
> following the sequence, 0 of 25 tested timing offsets mis-attribute a stale
> response; skipping the reset, 1 of 25 does.
>
> Hold the peripheral in reset *across* the `UNBLOCK` write rather than
> pulsing it beforehand. If the reset is released first, the orphaned command
> is still asserted and the freshly-reset peripheral will accept it — not
> occasionally, but every time. The [DE10-Lite example](example/de10_lite_rtl/README.md)
> reproduces both orderings as adjacent scenarios (`b` and `C`), and
> [its driver](HAL/src/altera_axi4_lite_firewall.c) implements the
> safe one.

A transaction arriving while blocked is **rejected with SLVERR**, not stalled.
Up to v1.2 the reset pulse gave a bounded window in which arrivals could be
held and completed normally, making recovery invisible to the master. With the
reset gone there is no such window, so **drivers need a retry path**.

There is no automatic fallback. Up to v1.1 the core also carried
`wr_discard_pending`/`rd_discard_pending` one-shot flags, described as a narrow
safety net for late responses. They were **dead code** and were removed in
v1.2: Questa had them at 0% condition coverage (`'_1' not hit`) against a suite
that does exercise the timeout path, and the orphan bench reported identical
numbers with and without them.

## Performance

Measured by the latency benchmark in `tb/axi_firewall_tb.sv` against the
zero-wait-state downstream slave model, counting clock edges from request
assertion to response valid:

| Operation | Cycles |
|---|---|
| Single write (request asserted → BVALID) | **6** |
| Single read (request asserted → RVALID) | **6** |

The benchmark runs as part of the suite and fails the run if either exceeds
8 cycles, so the numbers above cannot silently rot.

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

### Test suite — 103/103 passing

`tb/axi_firewall_tb.sv` is self-checking and runs under Questa,
Verilator 5.x (`--timing --assert`), and Icarus Verilog. The SVA
bind is wrapped in `` `ifndef ICARUS ``, so the Icarus command below works
unmodified.

> **Editing the BFM tasks:** every sample and drive happens one delta *after*
> a clock edge (`@(posedge clk); #1;`), and each `*VALID` is held through the
> edge at which its handshake is sampled. This is not style. Driving DUT
> inputs with blocking assignments *at* the edge puts the testbench and the
> DUT's own always blocks in the same active region, and which one wins is
> scheduler-dependent: the pre-v1.2 testbench passed under Questa and Icarus
> and deadlocked on the first control write under Verilator. Switching the
> drives to `<=` does not help — Verilator downgrades non-blocking assignments
> inside `initial` blocks to blocking.

Coverage:

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
- **Downstream recovery** (tests O–P): `STATUS.BLOCKED` and the stuck/busy
  bits after a timeout, forwarding blocked with an explicit watcher on
  `m_axi_arvalid`, W1C alone proven *not* to unblock, then the full
  acknowledge → reset → `UNBLOCK` sequence with traffic correct afterwards
- **Response-phase timeout** (tests Q–R, v1.2): the slave model's `HANG_RESP`
  mode accepts the address and data normally and *then* goes quiet. Tests A–P
  all use `HANG_ADDR`, where the peripheral never raises AWREADY/ARREADY —
  a different branch of both FSMs. The accepted-then-wedged case, which is the
  more realistic failure, had zero coverage before these
- **Reset asserted mid-transaction** (test S, v1.2): sweeps the reset point
  across `*_EVAL` and `*_FWD`, closing the four FSM transitions Questa
  previously reported as uncovered, then checks traffic is correct afterwards
- **Control-port backpressure** (v1.2): a second write issued while `BVALID`
  is unacknowledged, and a second read while `RVALID` is — the regression test
  for the handshake bug described below
- **UNBLOCK semantics** (v2.0): a no-op on a healthy core; a stuck VALID held
  until `UNBLOCK` and withdrawn by nothing else; `BLOCKED` and the stuck bits
  clearing correctly afterwards
- **Data-path response backpressure** (v1.2): `BREADY`/`RREADY` withheld for
  several cycles after the response arrives, checking `BVALID`/`RVALID` hold
  and the payload stays stable. This is what makes `a_bvalid_stability` and
  `a_rvalid_stability` non-vacuous — see *Assertion and coverage results*
- **Master-side AXI protocol checking**: a checker counts any
  `m_axi_*VALID` dropped without a handshake outside the reset window, and
  fails the run if any occur
- **Latency benchmark**, with a regression guard at 8 cycles
- Register-map sweep including unmapped offsets, and staggered
  AW/W channel arrival on the control port (now with an assertion that the
  staggered write actually took effect — it previously checked nothing)

### Assertions

`tb/axi_firewall_sva.sv` is bound into `axi_firewall_top` and checks:

Fourteen assertions and six cover points:

| Property | Checks |
|---|---|
| `a_suppress_illegal_write` / `a_suppress_illegal_read` | a violation never leaks `AWVALID`/`ARVALID` downstream |
| `a_err_on_blocked_write` / `a_err_on_blocked_read` | each violation gets an error response *on its own channel* (B for writes, R for reads) within 10 cycles |
| `a_awvalid_stability` … `a_rvalid_stability` | VALID holds until READY on all four `s_axi` channels |
| `a_m_awvalid_stability` / `a_m_wvalid_stability` / `a_m_arvalid_stability` | same on the `m_axi` side, with the `RECOVERY.UNBLOCK` cycle as the one permitted exception (added v1.1: the master side was previously unchecked, which is why the timeout path's protocol violation survived a full assertion + coverage run) |
| `a_no_issue_while_blocked` / `a_no_read_issue_while_blocked` | no *new* command is issued downstream while blocked — a VALID left over from the abandoned transaction may stay asserted, as AXI requires |
| `a_block_holds_until_unblock` | the block latches: only `UNBLOCK` clears it |

| Cover point | Proves |
|---|---|
| `c_write_denied` / `c_read_denied` | the denial paths were actually *reached*, not merely never violated |
| `c_write_decerr` / `c_read_decerr` | both DECERR paths were reached |
| `c_block_and_recover` | a full block-then-release episode occurred |
| `c_unblock_with_stuck_cmd` | an unblock that had to discard a stuck command — the case where polling the busy bits alone would never have sufficed |

The bind passes the **per-direction** fault pulses:

```verilog
.wr_violation(wr_fault_addr_violation | wr_fault_perm_violation),
.rd_violation(rd_fault_addr_violation | rd_fault_perm_violation)
```

Not the merged `fault_*_violation` wires — those OR both directions together,
which would make any read-channel assertion wait forever on `BVALID`.

### Running it

**Verilator** (functional tests *and* assertions, no licence needed — use this
for CI):

```bash
simulation/verilator/run_sim.sh
```

Exit status is 0 only if every check passed; the script also greps the log for
the result marker, because `$finish`'s argument is a verbosity level and does
not set a process exit code.

**Questa** (adds coverage) — `cd` into `simulation/questa/` first:

```tcl
do run_sim.tcl
```

Compiles RTL + SVA + testbench with `+cover=sbceft`, runs to completion, then
writes `coverage.ucdb`, `coverage_report.txt` (which includes the assertion and
cover-directive sections) and a full `run.log`.

**Icarus** (functional tests only — `-DICARUS` skips the SVA bind, which
Icarus cannot compile). Note `-g2012`, not `-g2005`: the sources are
SystemVerilog now.

```bash
iverilog -g2012 -DICARUS -o tb.out rtl/axi_firewall_regs.sv rtl/axi_firewall_top.sv tb/axi_firewall_tb.sv
vvp tb.out
```

### Assertion and coverage results

Measured under **Questa 2024.1** (`simulation/questa/run_sim.tcl`) and
**Verilator 5.48** (`simulation/verilator/run_sim.sh`) against v2.0. Both
compile with 0 errors and 0 warnings; slang 11 elaborates with 0 errors.

**103/103 checks pass. 0 assertion failures. 0 `m_axi` VALID-drop violations.**

| Metric | Result |
|---|---|
| Assertions | **14 / 14 — 100%**, every one with a non-zero non-vacuous pass count |
| Cover directives | **6 / 6 — 100%** |
| FSM states | **8 / 8 — 100%** |
| FSM transitions | **14 / 14 — 100%** |
| Total coverage by instance (filtered) | 85.96% |

**Cover directive hits:**

| Cover point | Hits |
|---|---|
| `c_write_denied` | 4 |
| `c_read_denied` | 4 |
| `c_write_decerr` | 3 |
| `c_read_decerr` | 2 |
| `c_block_and_recover` | 5 |
| `c_unblock_with_stuck_cmd` | 3 |

`c_block_and_recover` counts recovery *episodes* — five, matching the five
timeouts the suite provokes. The v1.2 equivalent used an unbounded `##[1:$]`
range and reported 123 for two episodes, which is why it was replaced.

**Assertion non-vacuity is the number that matters**, and it is the one worth
reading before trusting any of the above. A property that only ever passes
vacuously has verified nothing while looking green:

| Property | Failures | Real passes | Vacuous |
|---|---|---|---|
| `a_suppress_illegal_write` | 0 | 4 | 1331 |
| `a_suppress_illegal_read` | 0 | 4 | 1331 |
| `a_err_on_blocked_write` | 0 | 4 | 1331 |
| `a_err_on_blocked_read` | 0 | 4 | 1331 |
| `a_awvalid_stability` | 0 | 23 | 1309 |
| `a_arvalid_stability` | 0 | 23 | 1309 |
| `a_bvalid_stability` | 0 | 6 | 1329 |
| `a_rvalid_stability` | 0 | 6 | 1329 |
| `a_m_awvalid_stability` | 0 | 162 | 1171 |
| `a_m_wvalid_stability` | 0 | 162 | 1171 |
| `a_m_arvalid_stability` | 0 | 119 | 1214 |
| `a_no_issue_while_blocked` | 0 | 382 | 953 |
| `a_no_read_issue_while_blocked` | 0 | 429 | 906 |
| `a_block_holds_until_unblock` | 0 | 560 | 775 |

`a_bvalid_stability` and `a_rvalid_stability` were at **zero real passes and
845 vacuous** until v1.2 — their antecedent is `(BVALID && !BREADY)`, and every
BFM task raised `BREADY`/`RREADY` with the request, so a response never had to
wait. They reported zero failures the entire time. Coverage Test 7 is what
makes them fire.

> **Reporting note:** `coverage report -details` *does* include the Assertion
> Coverage and Directive Coverage sections, under the bound SVA instance. What
> omits them is `-codeAll`. And do not try to capture them separately with
> `puts $fh [assertion report ...]`: that command writes to the transcript and
> returns an empty string, so you get a 1-byte file that looks exactly like the
> assertions never ran.

Known coverage history, for context on what the tests are for:

| Gap | Status |
|---|---|
| `RD_EVAL → RD_RESP` — every denial test was a write, so the read-denial path was never entered | Closed by tests J–M |
| Read-path timeout — the only hang test was a write | Closed by test N |
| Response-phase timeout — the slave model only starved AWREADY/ARREADY, so the accepted-then-silent branch of both FSMs was never reached | Closed by tests Q–R (v1.2) |
| `WR_EVAL/WR_FWD/RD_EVAL/RD_FWD → *_IDLE` — reset asserted mid-transaction | Closed by test S (v1.2) |
| `a_bvalid_stability` / `a_rvalid_stability` — 0 real passes, wholly vacuous | Closed by Coverage Test 7 (v1.2) |
| "denied read returns zeros" passing on an accident — the preload was a write, so RDATA already held zero | Closed in v2.0: preload with a real read, and cover the permission-denied branch too |
| `wr_discard_pending`/`rd_discard_pending` at 0% — flagged as untested | Was **unreachable**, not untested. Removed in v1.2; see *Timeout recovery* |

Two lessons in that table. A stubbornly uncoverable branch is sometimes telling
you the branch is dead rather than that your stimulus is weak. And a passing
assertion is not evidence until you have checked it was ever actually
evaluated.

---

## Integration into Platform Designer

1. Add the repository's top-level directory to the Quartus IP search path
   (**Tools ▸ Options ▸ IP Catalog Search Locations**), then **Platform
   Designer ▸ File ▸ Refresh System**. The core appears as *AXI4-Lite
   Firewall*.
2. **Confirm the component packages cleanly for your Quartus version.**
   `hw.tcl` syntax has drifted across releases (Standard vs Pro, version to
   version). If it doesn't import: open Component Editor, add both files
   under `rtl/` as synthesis files with `axi_firewall_top.sv` as top level,
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
5. **Make the protected peripheral's reset software-controllable.** The core
   no longer drives it, but recovery from a timeout still requires it — see
   *Timeout recovery*. A Platform Designer reset bridge under software control,
   or any GPIO-driven reset, will do.
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
#define FW_RECOVERY    0x1C

#define FW_RECOVERY_UNBLOCK  0x1

/* CORE_INFO[31:16] is the core version: 0x0100 = v1.0 ... 0x0200 = v2.0.
   v2.0 is a BREAKING change. The peripheral reset output is gone, and
   clearing STATUS.TIMEOUT_ERROR no longer reopens the downstream - that now
   takes an explicit RECOVERY.UNBLOCK, after software has reset the
   peripheral itself. A v1.x driver will acknowledge a fault and then find
   every subsequent transaction returning SLVERR. Check this field before
   assuming either behaviour. */
#define FW_RULE(i, r)  (0x40 + (i)*0x10 + (r))   /* r: 0=BASE 4=LIMIT 8=PERM */

#define FW_PERM_READ   0x1
#define FW_PERM_WRITE  0x2
#define FW_PERM_VALID  0x4

#define FW_STAT_ADDR_VIOL  0x1
#define FW_STAT_PERM_VIOL  0x2
#define FW_STAT_TIMEOUT    0x4
#define FW_STAT_ISOLATED   0x8    /* read-only, live */
#define FW_STAT_BLOCKED    0x10   /* downstream blocked; needs UNBLOCK */
#define FW_STAT_WR_BUSY    0x20   /* peripheral owes a write response  */
#define FW_STAT_RD_BUSY    0x40   /* peripheral owes a read response   */
#define FW_STAT_WR_STUCK   0x80   /* AWVALID/WVALID never accepted     */
#define FW_STAT_RD_STUCK   0x100  /* ARVALID never accepted            */
#define FW_STAT_STICKY     0x7    /* the W1C-able bits */

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

        /* Acknowledge. W1C on the sticky bits; also releases auto-isolate. */
        IOWR_32DIRECT(FW_BASE, FW_STATUS, status & FW_STAT_STICKY);

        /* A timeout additionally leaves the downstream BLOCKED. Reopening it
           is a deliberate, separate act - see firewall_recover(). */
        if (status & FW_STAT_TIMEOUT)
            firewall_recover();
    }
}

/* Full v2.0 recovery. Do not shorten this: writing UNBLOCK without resetting
   the peripheral makes the core withdraw an asserted VALID on a live bus. */
void firewall_recover(void)
{
    int spins;

    /* Wait for the downstream to go quiet - BOUNDED. A peripheral that
       accepted a command and then died owes a response forever, so an
       unbounded poll hangs exactly when recovery matters. Busy clear means
       no late response can still be in flight; busy stuck means reset anyway
       and let UNBLOCK discard what is owed. */
    for (spins = 0; spins < 1000; spins++) {
        alt_u32 st = IORD_32DIRECT(FW_BASE, FW_STATUS);
        if (!(st & (FW_STAT_WR_BUSY | FW_STAT_RD_BUSY)))
            break;
    }

    /* Reset the protected peripheral. Whatever drives its reset in your
       system - a Platform Designer reset bridge, a PIO - assert it for at
       least 16 clocks. This step is what makes the UNBLOCK below legitimate. */
    peripheral_reset_assert();
    usleep(1);
    peripheral_reset_release();

    /* Declare the downstream AXI state discarded and reopen forwarding. */
    IOWR_32DIRECT(FW_BASE, FW_RECOVERY, FW_RECOVERY_UNBLOCK);

    /* Transactions attempted while blocked were answered SLVERR, not
       stalled, so retry anything that failed since the fault. */
}
```

---

## Verification status — what is and isn't proven

| Item | Status |
|---|---|
| Functional testbench (103 checks) | **Passing under Questa 2024.1 and Verilator 5.48.** Re-run under Icarus after any change; all three are supported |
| SVA properties | **14/14 under Questa 2024.1**, 0 failures, every one with a non-zero *non-vacuous* pass count |
| FSM coverage | **8/8 states, 14/14 transitions** under Questa 2024.1 |
| Cover directives | **6/6** under Questa 2024.1 |
| Best-case latency (6 cycles r/w) | **Measured** by the in-suite benchmark, with a regression guard |
| Control-port single-outstanding backpressure | **Measured** — regression test fails on the pre-v1.2 RTL and passes on v1.2 |
| Cost of skipping the peripheral reset (0/25 vs 1/25) | **Measured** — `verification/orphan_response_tb.sv`, both parameterisations |
| Code coverage figures | **Not quoted** — regenerate with the Questa flow. Toggle and condition coverage in particular are far from 100%, and a single number here would rot |
| Synthesis results (LE/register count, Fmax) | **Measured at `NUM_RULES = 8`** by the [DE10-Lite example](example/de10_lite_rtl/README.md): 1,908 LEs and 768 registers for `axi_firewall_top`, and 60.01 MHz Fmax on a MAX 10 `10M50DAF484C7G` (`C7`, slow 1200 mV 85 °C). The critical path is `captured_awaddr → wr_timeout_cnt` — the combinational rule lookup, as predicted below. **Fmax as a function of `NUM_RULES` is still unmeasured**, as is any other device family |
| Behaviour inside a real Platform Designer system | **Verified.** The [Nios II example](example/de10_lite_nios/README.md) runs the core behind generated Qsys interconnect and an Avalon-to-AXI bridge, on hardware |
| `hw.tcl` import into a specific Quartus release | **Verified for Quartus 18.1.1 Standard.** All six interfaces and five parameters are recognised by Platform Designer |
| Behaviour on physical hardware | **Verified on a Terasic DE10-Lite** (MAX 10 `10M50DAF484C7G`): 16/16 scenarios in the RTL example, 33/33 checks in the Nios II example |

## Changelog

**v2.0 — breaking**

- **Removed the `m_axi_resetn` output** and the `RESET_HOLD_CYCLES`
  parameter. The core no longer resets the protected peripheral; that is now
  step 4 of a documented software sequence. This matches how AMD's AXI
  Firewall works — their recovery flow also requires resetting the monitored
  side, it just never offered to do it for you.
- **Added `RECOVERY.UNBLOCK` (0x1C)** and five live `STATUS` bits:
  `BLOCKED`, `WR_RESP_BUSY`, `RD_RESP_BUSY`, `WR_CMD_STUCK`, `RD_CMD_STUCK`.
- **Clearing `STATUS.TIMEOUT_ERROR` no longer reopens the downstream.** It
  clears the sticky bit and releases auto-isolate; forwarding stays blocked
  until `UNBLOCK`. **A v1.x driver will acknowledge a fault and then see every
  subsequent transaction return SLVERR.**
- **Recovery is no longer invisible to the master.** There is no reset pulse
  to stall arrivals against, so a transaction attempted while blocked is
  answered SLVERR. Drivers need a retry path.
- `UNBLOCK` is now the sole point at which a stuck `m_axi_*VALID` is withdrawn,
  and doing so without having reset the peripheral is a protocol violation on
  a live bus. The orphan bench measures that hazard: 0 of 25 offsets
  mis-attribute when the sequence is followed, 1 of 25 when the reset is
  skipped — the same numbers as v1.2, now attached to a software mistake
  rather than a wiring one.
- `CORE_INFO` version field reads `0x0200`.

**v1.2**

- **Converted to SystemVerilog.** All `.v` sources are now `.sv`; see
  *Language*. `hw.tcl` declares them as `SYSTEM_VERILOG`, not `VERILOG` —
  with the wrong file type Quartus uses the Verilog-2001 parser and fails on
  the first `logic` declaration. Icarus now needs `-g2012`.
- **Fixed: rule writes were broken for `ADDR_WIDTH < 32`**, which `hw.tcl`
  permits. Hard-wired `[31:24]` byte slices are now a parameterised merge.
- **Fixed: `s_axi_ctrl` accepted transfers it could not answer.** `AWREADY`/
  `WREADY` were asserted on VALID arriving without checking whether the
  previous `BVALID` had been accepted, and `ARREADY` likewise against
  `RVALID`. A master pipelining a second access got the handshake taken, the
  access silently dropped, and no response — a lost register write and a
  wedged channel. Now backpressured. Regression tests included; they fail on
  v1.1 RTL.
- **Fixed: `auto_isolate_latch` on a same-cycle timeout and W1C.** A timeout
  landing in the same cycle as a W1C of `STATUS.TIMEOUT_ERROR` left
  `TIMEOUT_ERROR` set but `ISOLATED` clear, disagreeing with the datapath's
  own `downstream_broken` handling.
- **Removed: `wr_discard_pending`/`rd_discard_pending`.** Unreachable; see
  *Timeout recovery*.
- **Fixed: testbench race** that made the suite's result scheduler-dependent.
- **Fixed: two assertions that had never been evaluated.**
  `a_bvalid_stability` and `a_rvalid_stability` sat at 0 real passes and 845
  vacuous attempts, because every BFM task raised `BREADY`/`RREADY` with the
  request so a response never had to wait. Coverage Test 7 stalls each
  response channel. Every property now has a non-zero non-vacuous pass count.
- Added tests Q–S (response-phase timeout, reset mid-transaction), the
  control-port and data-path backpressure regressions, and a latency
  benchmark: 50 → 80 checks. FSM transition coverage 10/14 → **14/14**.
- Added a Verilator flow. Corrected the Questa flow: `coverage report
  -details` already includes the assertion and directive sections, and the
  `puts $fh [assertion report ...]` idiom silently produces an empty file
  because that command returns no string.
- `CORE_INFO` version field now reads `0x0102`.

---

## Roadmap / possible extensions

- **Burst-capable AXI4 variant** — the main one, if a DMA engine (mSGDMA)
  sits in front of the firewall. See *Performance*.
- **Per-master (per-ID) filtering** — requires full AXI4 or a sideband ID
  signal; not expressible in AXI4-Lite.
- **Autonomous flushing**, to remove the bounded-poll caveat. AMD's firewall
  synthesises the missing responses itself when blocked, so its `RESP_BUSY`
  bits are guaranteed to reach zero and a driver can poll them unconditionally.
  Ours means *the peripheral owes us a response*, which for a dead peripheral
  is never satisfied — hence the bound. Absorbing the owed response internally
  would make the bit mean what a driver naturally assumes. The tracking
  registers already exist; this is a contained change and the most valuable
  one for anyone writing against this core.
- **Registering the rule lookup.** Now measured rather than suspected: at
  `NUM_RULES = 8` on a MAX 10 `C7` the critical path is
  `captured_awaddr → wr_timeout_cnt`, and Fmax is 60.01 MHz — about 20% of
  margin at 50 MHz, and less as the rule table grows. An extra pipeline stage
  on that lookup is the standard fix, at the cost of one cycle of latency.
  What is still unmeasured is the shape of the curve: Fmax as a function of
  `NUM_RULES`, and on other device families.
- `AWPROT`/`ARPROT`-based filtering (privileged / secure / instruction-vs-data).
  Both are already captured and forwarded; a per-rule qualifier would be cheap.
- Separate fault-address latches per fault type instead of one shared latch.
- Rule-hit counters per range, for auditing and profiling access patterns.
