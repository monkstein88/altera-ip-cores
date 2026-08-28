# Avalon-MM Firewall — Quartus / Platform Designer IP core

A **burst-capable access-control and fault-isolation firewall** for Intel/Altera
Quartus and Platform Designer (Qsys). There is no stock "Avalon-MM Firewall" in
the Altera IP catalog, so this is a from-scratch component: synthesisable
SystemVerilog, a Platform Designer wrapper, a self-checking testbench,
SystemVerilog assertions, a Nios II HAL driver, and both a Questa flow with
coverage and a licence-free Verilator flow.

**Component:** `altera_avalon_mm_firewall` · shown in the IP Catalog as
**"Avalon-MM Firewall"** under *Bridges and Adapters / Custom* · v1.0

This is the burst-capable sibling of
[`altera_axi4_lite_firewall`](../altera_axi4_lite_firewall). That core's own
roadmap named "a burst-capable variant, the main one if a DMA engine sits in
front of the firewall" as its most valuable extension. This is that variant,
built natively on Avalon-MM rather than AXI, because Nios II and the mSGDMA
speak Avalon-MM and Platform Designer would otherwise be bridging in both
directions for no benefit.

### Documentation

| Document | What it is |
|---|---|
| [User guide (PDF)](doc/avalon_mm_firewall_user_guide.pdf) | Altera-style: getting started, functional description, parameters, signals, register map, programming model, verification, limitations |
| [User guide (Markdown)](doc/avalon_mm_firewall_user_guide.md) | Same document, readable in the browser |
| [Block diagrams (PDF)](doc/avalon_mm_firewall_block_diagrams.pdf) | Architecture companion: system context, internal architecture, burst handling, register map |
| [Block diagrams (Markdown)](doc/avalon_mm_firewall_block_diagrams.md) | Same document, readable in the browser |
| [DE10-Lite RTL demo](example/de10_lite_rtl/README.md) | Self-checking hardware demonstration: 16 scenarios, no CPU or software. **Verified on a physical board.** Where this core's synthesis and Fmax numbers come from |
| [DE10-Lite Nios II demo](example/de10_lite_nios/README.md) | The same core driven by C on a Nios II/f **at 100 MHz**, inside a generated Platform Designer system. **41/41 checks pass on hardware** |
| This README | Design rationale and the reasoning behind the decisions — the parts a user guide has no room for |

---

## What it does

Sits between a bus master and a peripheral you want to protect:

```
                  ┌──────────────────────────────┐
    Avalon-MM     │                              │    Avalon-MM
 ────────────────▶│  s0                  m0      │───────────────▶
  (from master:   │     avl_mm_firewall_top      │   (to the protected
   Nios II,       │                              │    peripheral)
   mSGDMA, ...)   │          csr        irq      │
                  └───────────┬──────────┬───────┘
                              │          │
                          Avalon-MM   interrupt
                        (config/status) (to Nios II)
```

1. **Access control** — every transaction's address range is checked against a
   software-programmable table of allowed windows, each with independent read,
   write and burst permission. Default-deny: an address matching no rule is
   rejected, as is an address matching a rule but not for the direction or the
   burst length requested.
2. **Fault isolation** — every forwarded transaction is watched for progress.
   If the peripheral stops making any, the firewall completes the transaction
   itself so the master never hangs, and latches into a blocked state that
   walls the peripheral off until software explicitly recovers it.
3. **Violations raise an interrupt** in addition to returning an error
   response.

Control and status live on a **separate** Avalon-MM port (`csr`), so
configuring or inspecting the firewall is never itself subject to firewall
rules, nor blockable by a wedged peripheral.

---

## Repository layout

```
altera_avalon_mm_firewall/
├── README.md                       This file
├── avl_mm_firewall_hw.tcl          Platform Designer component description
├── rtl/
│   ├── avl_mm_firewall_pkg.sv      Response codes, verdict enum, rule layout
│   ├── avl_mm_firewall_top.sv      Datapath: s0, m0, burst-aware checks,
│   │                               timeout / block / freeze logic
│   └── avl_mm_firewall_regs.sv     Rule table, status/IRQ, csr slave
├── tb/
│   ├── avl_mm_firewall_tb.sv       Self-checking testbench + SVA bind
│   └── avl_mm_firewall_sva.sv      SystemVerilog assertions & cover points
├── avl_mm_firewall_sw.tcl          Nios II BSP driver description
├── inc/
│   └── altera_avalon_mm_firewall_regs.h    Register map: offsets, accessors,
│                                           bit masks. Needs only <io.h>
├── HAL/
│   ├── inc/altera_avalon_mm_firewall.h     Driver API + BSP auto-init macros
│   └── src/altera_avalon_mm_firewall.c     Init, rules, ISR, recovery
├── simulation/
│   ├── questa/run_sim.tcl          Compile + run + merged coverage
│   ├── verilator/run_sim.sh        Licence-free regression (slang, lint,
│   │                               parameter sweep, both parameterisations)
│   └── verilator/slangcheck.py     Strict LRM elaboration gate
├── example/                        Two DE10-Lite (MAX 10) demonstrations
│   ├── common/                     The protected peripheral, shared by both
│   ├── de10_lite_rtl/              16 scenarios in synthesisable RTL, no CPU
│   └── de10_lite_nios/             C on a Nios II/f at 100 MHz, in Qsys
└── doc/                            Documents; everything else is generated
    ├── avalon_mm_firewall_user_guide.md / .pdf
    ├── avalon_mm_firewall_block_diagrams.md / .pdf
    ├── figures/                    All figures, all SVG, all generated
    └── tools/                      The generators and the fact checker
```

Simulation outputs (`obj_dir_*/`, `work/`, `*.ucdb`, `coverage_report.txt`,
`run_wresp*.log`) are build artifacts, listed in `.gitignore`, and regenerated
by the run scripts. Do not cite a checked-in one as a current result.

To expose this (and sibling cores) to Platform Designer, add the repository's
**top-level directory** to the IP search path — see the repo root README.

---

## The design decision that matters: a gate, not a buffer

The AXI4-Lite sibling captures each transaction into registers, evaluates it,
then re-drives it downstream. That costs **six cycles per transaction** and
does not generalise to bursts without growing a data FIFO. Its own README is
blunt about the consequence: *"It is not fine for bursting masters. An mSGDMA
gets split into single beats by Platform Designer's burst adapter, and every
beat then pays the full 6-cycle cost."*

This core evaluates combinationally and passes through:

| | Allowed | Denied |
|---|---|---|
| `m0` | `s0` gated by the rule lookup | never touched at all |
| `s0_waitrequest` | `m0_waitrequest`, unmodified | 0 — accepted immediately |
| read data | flows back untouched | synthesised by the firewall |
| added latency | **zero** | — |
| storage in the core | **none** | none |

The measured cost of a 32-beat burst through a zero-wait-state peripheral is
33 cycles for a write and 36 for a read — one beat per cycle plus the
peripheral's own read latency. The regression fails if either exceeds a
guard, so those numbers cannot silently rot.

The price is a combinational path from `s0_address` through `NUM_RULES` address
comparators to `m0_read`/`m0_write` and `s0_waitrequest`. That is the critical
path and it grows with `NUM_RULES` — see *Performance*.

---

## Why bursts are the hard part

Four things change when the protocol can burst, and each one is a way to build
a firewall that looks correct and is not.

**1. A denied transaction must still be COMPLETED.** Avalon-MM has no way to
abort. A denied read burst of N beats must still produce N beats of
`readdatavalid`, or the master waits forever. A denied write burst must still
have all N beats consumed. "Deny" does not mean "ignore" — it means the
firewall becomes the responder and synthesises the whole burst's worth of error
responses itself. Six of the assertions in `tb/avl_mm_firewall_sva.sv` exist
solely to check that every rejection path actually produces the beats it owes.

**2. The whole burst range must be checked, not the start address.** A burst
beginning one beat inside an allowed window and running for 128 beats ends up
well outside it. Checking only `s0_address` builds a firewall that a DMA engine
walks straight through — which is precisely the case this core exists for. Both
the first and the last byte of every transaction are checked against the *same*
matched rule.

Adjacent windows deliberately do **not** merge: a burst spanning two abutting
rules is a range violation even if both permit the access, because permissions
are per-window and the burst would have to satisfy both.

**3. The verdict must be latched for the whole burst.** On beats 2..N of an
Avalon-MM write burst the master does not present a meaningful address, only
`writedata`. Re-evaluating the rule per beat would be evaluating garbage.

**4. Read data cannot be backpressured.** Avalon-MM `readdatavalid` has no
ready signal, so a late beat from an already-timed-out read cannot be held off
— only dropped. The core forwards `m0_readdatavalid` only while beats are
actually owed.

That last point is where the two cores genuinely diverge. The AXI sibling had a
discard mechanism too; there it turned out to be **unreachable dead code** and
was removed in its v1.2, because AXI's `RREADY` lets you absorb a late response
instead. Avalon-MM gives you no such option, so here the same mechanism is
load-bearing and is covered by two assertions.

---

## Rules and priority

| Register | Meaning |
|---|---|
| `RULE_BASE[i]` | first byte of the window, inclusive |
| `RULE_LIMIT[i]` | last byte of the window, inclusive |
| `RULE_PERM[i]` | bit0 READ_ALLOW, bit1 WRITE_ALLOW, bit2 VALID, bit3 BURST_ALLOW |

The **lowest-index valid rule containing the start address wins**. Rules need
not be disjoint; put more specific rules at lower indices if you use
overlapping ranges.

`BURST_ALLOW` is per-window rather than global because "this peripheral cannot
handle bursts" is a property of the peripheral, and a system usually has both
kinds behind one firewall. With it clear, single accesses to that window are
allowed and any `burstcount > 1` is refused.

Verdict priority within a matched rule is **direction before extent**: a write
burst into a read-only window reports `PERM_VIOLATION`, not a confusing burst
error. Only once the direction is permitted does the range check run.

| Verdict | Response | STATUS bit | `FAULT_INFO.TYPE` |
|---|---|---|---|
| unmapped address | DECODEERROR | `ADDR_VIOLATION` | 1 |
| wrong direction | SLAVEERROR | `PERM_VIOLATION` | 2 |
| downstream timeout | SLAVEERROR | `TIMEOUT_ERROR` | 3 |
| burst overran its window | DECODEERROR | `BURST_VIOLATION` | 4 |
| window forbids bursts | SLAVEERROR | `BURST_VIOLATION` | 5 |
| isolated / blocked | SLAVEERROR | *(none — see below)* | — |

A rejection *while blocked* raises no new fault. The timeout that caused the
block already latched one, and re-latching on every subsequent rejected access
would overwrite the `FAULT_ADDR` that actually diagnoses the problem.

---

## Register map (`csr`, byte offsets)

The `csr` port is **word-addressed in hardware** — Platform Designer's default
for an Avalon-MM slave. The byte offsets below are what software uses;
`IOWR_32DIRECT()` and the interconnect handle the divide-by-four.

| Offset | Name | Access | Description |
|---|---|---|---|
| 0x00 | `CTRL` | R/W | bit0 `GLOBAL_ENABLE` (reset **1**), bit1 `AUTO_ISOLATE_EN` (reset **1**), bit2 `MANUAL_ISOLATE` |
| 0x04 | `STATUS` | R, W1C on [3:0] | [0] `ADDR_VIOLATION`, [1] `PERM_VIOLATION`, [2] `TIMEOUT_ERROR`, [3] `BURST_VIOLATION` — all sticky. [4] `ISOLATED`, [5] `BLOCKED`, [6] `WR_BUSY`, [7] `RD_BUSY`, [8] `WR_CMD_STUCK`, [9] `RD_CMD_STUCK` — all live, read-only |
| 0x08 | `IRQ_ENABLE` | R/W | [3:0] enable IRQ per sticky source (reset all enabled) |
| 0x0C | `TIMEOUT_VALUE` | R/W | Cycles **without progress** before a timeout (reset all-ones ⇒ effectively disabled until set) |
| 0x10 | `FAULT_ADDR` | R | Start address of the most recently latched fault |
| 0x14 | `FAULT_INFO` | R | [0] `WAS_WRITE`, [3:1] type, [15:8] burstcount of the faulting transaction (saturating) |
| 0x18 | `CORE_INFO` | R | [7:0] `NUM_RULES`, [12:8] `BURST_WIDTH`, [15:13] log2 bytes per beat, [31:16] version (0x0100 = v1.0) |
| 0x1C | `RECOVERY` | W | bit0 `UNBLOCK`. Self-clearing, reads 0 |
| 0x40 + i·0x10 | `RULE_BASE[i]` | R/W | |
| 0x44 + i·0x10 | `RULE_LIMIT[i]` | R/W | |
| 0x48 + i·0x10 | `RULE_PERM[i]` | R/W | |

`i` runs `0 … NUM_RULES-1` (default 8 rules ⇒ table spans 0x40–0xBF).

`TIMEOUT_VALUE` counts cycles **without progress**, not total transaction
length. That is deliberate: timing a whole burst would force the value to be
scaled by the longest burst in the system, which makes it useless as a hang
detector. A 128-beat burst against a slow peripheral is progress; a peripheral
that has not taken or produced a beat in N cycles is not.

---

## Parameters

| Parameter | Default | Notes |
|---|---|---|
| `ADDR_WIDTH` | 32 | Byte address width of `s0`/`m0` |
| `DATA_WIDTH` | 32 | 8…1024 |
| `BURST_WIDTH` | 8 | Max burst is 2^(BURST_WIDTH−1) beats. 1 means non-bursting |
| `MAX_PENDING_READS` | 4 | Read bursts in flight; sets the outstanding-beat budget and is published to Platform Designer |
| `NUM_RULES` | 8 | All comparators are in the critical path — use the smallest that covers your map |
| `TIMEOUT_WIDTH` | 20 | Max programmable timeout is 2^TIMEOUT_WIDTH − 1 cycles |
| `CSR_ADDR_WIDTH` | 8 | **In words.** Must cover word 0x10 + NUM_RULES·4 |
| `USE_RESPONSE` | 1 | Expose the 2-bit `response` signal (hw.tcl only, not HDL) |
| `USE_WRITE_RESPONSE` | 0 | Expose `writeresponsevalid`. Requires `USE_RESPONSE` |
| `REGISTER_LOOKUP` | 0 | Register the rule lookup. Costs **one cycle per transaction**, not per beat, and roughly halves the critical path — see *Performance* |

Three validation callbacks in `hw.tcl` catch the configurations that elaborate,
simulate and are quietly wrong:

- `CSR_ADDR_WIDTH` too small to reach every rule — high-index rules silently
  unreachable.
- `ADDR_WIDTH` too small for one maximum-length burst to fit in the address
  space — the range check stops meaning anything.
- `USE_WRITE_RESPONSE` without `USE_RESPONSE` — `writeresponsevalid` qualifies
  `response`, so without it there is nothing to qualify.

**`USE_RESPONSE = 0` is a real downgrade, not just fewer wires.** A denied read
still returns the correct number of beats, but they read as zeros with no error
indication; the violation is then visible only through the interrupt and
`STATUS`. `hw.tcl` emits an info message saying so.

---

## Timeout, blocking and recovery

The Avalon-MM hang mode is `waitrequest` stuck high, or `readdatavalid` that
never arrives. On either, the core:

1. **completes the upstream transaction immediately** — synthesising the
   remaining read beats as SLAVEERROR, or consuming and discarding the
   remaining write beats — so the master never hangs;
2. **latches `downstream_broken`**, blocking all further forwarding regardless
   of the isolate bits;
3. **freezes, rather than withdraws**, an `m0` command whose `waitrequest`
   never fell.

### Two kinds of protocol breakage, and why only one is avoidable

Abandoning a forwarded write burst part-way leaves the downstream peripheral
waiting for beats that never come. That is unavoidable — the master upstream
must be released, and Avalon-MM has no burst-abort. It is also why the
peripheral reset in the recovery sequence is not optional.

What **is** avoidable is withdrawing a command whose handshake never completed,
and the core never does it. If `waitrequest` is still high when a transaction is
abandoned, the command is frozen and held asserted until `RECOVERY.UNBLOCK`.
The distinction matters because the first only confuses the peripheral, while
the second can wedge the interconnect between the firewall and the peripheral.

### The recovery sequence

```c
1. stop issuing transactions to s0
2. write 1 to the sticky STATUS bits      /* acknowledge                    */
3. poll STATUS until WR_BUSY and RD_BUSY clear — WITH A BOUND
4. ASSERT the peripheral's reset and HOLD it   /* >= 16 clocks              */
5. write RECOVERY.UNBLOCK                 /* while the reset is asserted    */
6. release the peripheral's reset
7. write 1 to the sticky STATUS bits AGAIN     /* see below                 */
8. resume
```

**Step 7 is not redundant, and leaving it out is subtly worse than it looks.**
Step 2's acknowledge can be overwritten before the sequence finishes. A command
the peripheral never accepted keeps `m0_read`/`m0_write` asserted with
`waitrequest` high, so the no-progress timer keeps expiring and re-latching
`TIMEOUT_ERROR` — re-arming auto-isolate with it — for as long as the command
is frozen. Only `UNBLOCK` at step 5 retires it.

Skip step 7 and a recovery that has genuinely succeeded leaves `STATUS` reading
`TIMEOUT_ERROR | ISOLATED`, and `ISOLATED` still gates the data path: the next
transaction is refused and you have a "recovered" core that answers nothing.
This was found on hardware, where the symptom was a post-recovery write that
silently did not land. `alt_avalon_mm_firewall_recover()` does it for you.

**Steps 5 and 6 are in this order deliberately, and this is where the core
deviates from AMD's published AXI Firewall flow** (which resets, then
unblocks). `UNBLOCK` is what withdraws a frozen command. If the peripheral is
already out of reset when that write lands, it can complete the frozen
command's handshake first — latching a transaction the firewall has already
reported to the master as failed. Withdrawing it while the peripheral cannot
see the bus closes that window completely and costs nothing.

This was not a design insight; it came out of a coverage gap. The cover point
`c_unblock_with_stuck_cmd` sat at **0 hits** with the reset-then-unblock
ordering, because the frozen command was always handshaked away by the
freshly-released peripheral before `UNBLOCK` arrived. The uncoverable branch
was telling us the sequence was wrong.

**Bound the poll in step 3.** `WR_BUSY`/`RD_BUSY` mean *the peripheral owes us
something*, and a peripheral that accepted a command and then died owes it
forever — an unbounded poll hangs exactly when recovery matters. Treat them as
advisory: clear means no late response can still be in flight and the reset is
unambiguously safe; still set means reset anyway and let `UNBLOCK` discard what
is owed. `WR_CMD_STUCK`/`RD_CMD_STUCK` tell you the other case — a command the
peripheral never even accepted, which only `UNBLOCK` can clear.

**Transactions attempted while blocked are answered with an error, not
stalled.** There is no window in which the firewall quietly holds traffic, so
**drivers need a retry path**.

Note also that clearing `STATUS.TIMEOUT_ERROR` releases the auto-isolate latch
but does **not** reopen the downstream. Acknowledging a fault must not
accidentally restart traffic toward a peripheral nobody has reset yet.

---

## Other decisions worth knowing

- **Bypass mode does not override fault isolation.** `CTRL.GLOBAL_ENABLE = 0`
  turns off *access control*, not *isolation*. A peripheral that has already
  wedged the bus stays walled off either way. They are separate jobs and the
  core treats them separately; there is a test for it.
- **A timeout on either channel abandons work on both.** Letting one channel
  keep forwarding into a peripheral the other has just given up on would also
  let a frozen `m0_read` coexist with a live `m0_write`, which Avalon-MM
  forbids.
- **Only one denied read burst is in flight at a time**, and no new read is
  accepted while one is draining. That is what satisfies Avalon-MM's in-order
  read response requirement without a reorder buffer. Denials are errors, so
  the throughput cost is irrelevant; allowed reads pipeline freely.
- **`MAX_PENDING_READS` is a beat budget, not a command limit.** The core
  tracks total outstanding beats and backpressures `s0` beyond
  `MAX_PENDING_READS × max-burst`. It publishes the parameter to Platform
  Designer on both ports so the interconnect sizes its own pipelining to match.
- **The core cannot distinguish which master issued a transaction.** Access
  control is address-range plus direction, not per-master identity. Per-master
  filtering needs a sideband ID signal.
- **Simultaneous read and write fault in the same cycle**: both sticky STATUS
  bits set correctly, but `FAULT_ADDR`/`FAULT_INFO` capture the write side — a
  documented, deterministic tie-break.
- **`csr` is deliberately the dullest possible Avalon-MM port**: word-addressed,
  32-bit, fixed read latency 1, never asserts `waitrequest`. It has to stay
  reachable when the data path is isolated or wedged, so it has no state that
  could get stuck.

---

## Verification

**632 checks pass** — the suite runs four times, and each run is 153 checks with
`USE_WRITE_RESPONSE=0` or 163 with `=1`.
**0 assertion failures. 0 `m0` protocol violations. 22/22 assertions, 11/11
cover points hit, and every assertion has a non-zero pass count** — no property
is passing vacuously.

The suite runs **four** times on purpose, over two independent axes.

`USE_WRITE_RESPONSE` changes the write channel's completion rule (last beat
accepted vs. peripheral answered), which changes the timeout scope, the
abandonment path and the response arbitration against read data. Running only
the default leaves half the write channel unexercised.

`REGISTER_LOOKUP` changes the handshake timing of every command: there is a
stall cycle in one build that does not exist in the other. Running only the
combinational build leaves the whole stall path — and the two properties that
had to be restated for it — unexercised.

### What is covered

- Allowed single and burst read/write with data integrity, up to the maximum
  128-beat burst
- **Burst throughput**, with a regression guard: 32-beat write in 33 cycles,
  32-beat read in 36
- Permission denial in **both directions** — write into a read-only window and
  read from a write-only one. The read direction is the harder case on
  Avalon-MM and had zero coverage until the cover report said so
- Unmapped address, read and write
- **Burst straddle**, read and write: a burst starting inside a window and
  running past its limit, with an explicit watcher proving `m0` is never touched
- **Adjacent windows do not merge**: a burst across two abutting permitted
  rules is still refused
- **Per-rule burst capability**: single accesses allowed, bursts refused, and
  the window's contents proven untouched afterwards
- Pipelined reads: three bursts in flight, returning in issue order
- Wait states on the downstream peripheral
- **Read timeout, command never accepted** (`waitrequest` stuck) → all beats
  returned as SLAVEERROR, `RD_CMD_STUCK` set
- **Read timeout, accepted then silent** — a different branch entirely, where
  the peripheral genuinely owes beats
- **Write timeout, command never accepted** → remaining beats consumed,
  `WR_CMD_STUCK` set
- **Write timeout, accepted then silent** (`USE_WRITE_RESPONSE=1` only) — every
  beat taken downstream and only the write response withheld, so the core has to
  answer for a burst it already forwarded. This is the only path that reaches the
  write-response arm of the abandon logic; it sat at zero coverage until the
  Questa branch report pointed at it
- W1C proven *not* to unblock; the frozen command proven to survive the
  peripheral reset and to be withdrawn only by `UNBLOCK`
- Orphan beats after recovery are discarded
- Manual isolation, bypass mode, and bypass **not** reopening a broken
  downstream
- Interrupt masking, including unmasking an already-latched fault
- Rule reprogramming with the retire-first idiom, and the vacated address
  becoming unmapped again
- Byte enables on both the data path and the `csr` port
- Read-only registers, unmapped offsets, reserved words inside a rule slot
- Reset asserted mid-burst, swept across four offsets
- A continuous `m0` protocol checker counting any command dropped without
  `waitrequest` having fallen

### Assertions

`tb/avl_mm_firewall_sva.sv` binds 22 assertions and 11 cover points into
`avl_mm_firewall_top`, in three groups:

| Group | What it checks |
|---|---|
| **Protocol** | `m0_read`/`m0_write` never concurrent; commands held until `waitrequest` falls with `UNBLOCK` as the single exception; frozen commands hold their address and burstcount; `burstcount` never zero; `readdatavalid` and `writeresponsevalid` never coincide on the shared `response` |
| **Security** | a denied transaction never leaks a command to `m0`; nothing new is issued while blocked; the block latches until `UNBLOCK` |
| **Liveness** | every beat presented upstream is one the core owes; orphan beats are dropped; a denied read is never stalled and always drains; a denied write is never stalled |

The liveness group is the Avalon-specific one. On AXI you can refuse; here you
can only answer, so every rejection path needs proving that it answers.

**Cover directive hits**, measured across both parameterisations:

| Cover point | Hits | Proves |
|---|---|---|
| `c_write_denied` / `c_read_denied` | 2 / 2 | both permission-denial directions reached |
| `c_write_decerr` / `c_read_decerr` | 10 / 4 | both unmapped paths reached |
| `c_burst_range_wr` / `c_burst_range_rd` | 2 / 4 | burst straddle reached on both channels |
| `c_burst_denied` | 2 | a burst refused by `BURST_ALLOW` |
| `c_block_and_recover` | 9 | full block-then-release episodes |
| `c_unblock_with_stuck_cmd` | 2 | an unblock that had to discard a frozen command |
| `c_burst_streaming` / `c_write_streaming` | 318 / 311 | beats actually streaming back-to-back — the throughput claim is not theoretical |

Three of those started at zero and are the reason the suite grew: the
permission-denied *read*, the *write*-side burst straddle, and the unblock with
a stuck command. The third turned out to be a design problem rather than a
missing test — see *Recovery*.

### Running it

**Verilator** (functional tests *and* assertions, no licence — use this for CI):

```bash
pip install pyslang                    # enables the strict elaboration gate
simulation/verilator/run_sim.sh        # slang → lint → parameter sweep → both runs
```

The script also lints the RTL with `-Wall` and nothing waived, then re-lints it
across five parameter configurations. The burst range check, the beat counters
and the `FAULT_INFO` saturation are all parameter-sized, and the combinations
most likely to break are the ones nobody simulates.

**Questa** (adds coverage) — `cd` into `simulation/questa/` first:

```tcl
do run_sim.tcl
```

Elaborates both parameterisations, merges the two coverage databases, and
writes `coverage.ucdb` and `coverage_report.txt` (which includes the assertion
and cover-directive sections).

**Icarus** (functional tests only — `-DICARUS` skips the SVA bind):

```bash
iverilog -g2012 -DICARUS -o tb.out rtl/avl_mm_firewall_pkg.sv \
    rtl/avl_mm_firewall_regs.sv rtl/avl_mm_firewall_top.sv tb/avl_mm_firewall_tb.sv
vvp tb.out
```

### Two testbench hazards worth knowing

Both cost a debugging round and both are documented at the top of
`tb/avl_mm_firewall_tb.sv`.

**Never read a combinational DUT output in the same timestep you drove its
input.** `s0_waitrequest` is combinational from `s0_read`/`s0_write` — the
Avalon spec permits it and this core relies on it. The obvious BFM does
`s0_write = 1; while (s0_waitrequest) tick;` and is wrong: the simulator does
not re-evaluate the netlist after a blocking assignment, so that read returns
the value computed while `s0_write` was still 0 — which is 0, because an idle
slave does not stall. The loop falls through and the beat is silently lost.

The symptom was one beat missing from every burst, but **only** once the
downstream model started inserting wait states; with a zero-wait-state slave
the first beat is accepted anyway and the bug hides completely. The fix is to
sample handshakes through registered flags, so the BFM asks "was my beat taken
at the edge I just crossed?" rather than "is the port ready?".

**Do not derive a slave model's `waitrequest` from a counter updated by the
same cycle's command.** That makes `waitrequest` combinational from a register
changing at the very edge the DUT samples it, and the evaluation order is not
worth relying on. The wait-state generator here is free-running and registered.

---

## Performance

Measured by the in-suite benchmark against a zero-wait-state peripheral model:

| Operation | `REGISTER_LOOKUP=0` | `REGISTER_LOOKUP=1` | Guard |
|---|---|---|---|
| 32-beat write burst | **33** cycles | **34** cycles | fails above 36 |
| 32-beat read burst (command → last beat) | **36** cycles | **37** cycles | fails above 40 |

One beat per cycle plus the peripheral's own read latency, in both modes.
Registering the lookup adds exactly one cycle **per transaction**, not per
beat, so the burst rate itself is untouched. Compare the AXI4-Lite sibling's 6
cycles *per single transaction*: a 32-beat transfer through it costs roughly
192 cycles once Platform Designer's burst adapter has split it into single
beats.

### Fmax, and why `REGISTER_LOOKUP` exists

The critical path is the rule lookup, and it is combinational end to end:

```
avl_mm_firewall_regs|rule_base → NUM_RULES × 2 address comparators
  → priority chain → decide() → rd_deny_beats / m0_* / s0_waitrequest
```

Two comparators per rule, because this core checks the **first and last byte**
of every transaction; every carry chain in them is `ADDR_WIDTH` bits long.
Measured standalone on a MAX 10 `10M50DAF484C7G` (`C7`, slow 1200 mV 85 °C),
with virtual pins:

| Configuration | `REGISTER_LOOKUP=0` | `REGISTER_LOOKUP=1` |
|---|---|---|
| `NUM_RULES=8`, `ADDR_WIDTH=32` (defaults) | 60.77 MHz · 2,649 LEs | **95.85 MHz** · 2,736 LEs |
| `NUM_RULES=5`, `ADDR_WIDTH=12` | 73.44 MHz · 1,183 LEs | **107.43 MHz** · 1,213 LEs |
| `NUM_RULES=2`, `ADDR_WIDTH=12` | 83.31 MHz · 928 LEs | — |

Registering the lookup costs about 90 logic elements and buys 46–58% more
clock. With it on, the path moves off the lookup entirely — it becomes a loop
through the denied-read beat counter and the `waitrequest` handshake, which is
inherent to the zero-latency Avalon-MM handshake and is where the remaining
ceiling sits.

**100 MHz is reachable, but not at the widest settings.** `NUM_RULES=5` with a
12-bit address space clears it comfortably; the 8-rule, 32-bit default lands at
96 MHz. If you need 100 MHz there, the lever that still works is the one the
table shows: fewer rules, or a narrower address space, or both.

### Registering the lookup *increases* bandwidth

The extra cycle is easy to misread as a throughput cost. It is not, because the
clock gains far more than the cycle costs. A 32-beat, 32-bit burst moves 128
bytes:

| Configuration | Cycles | Clock | Time | Bandwidth |
|---|---|---|---|---|
| defaults, `REGISTER_LOOKUP=0` | 36 | 59.28 MHz | 607 ns | 211 MB/s |
| defaults, `REGISTER_LOOKUP=1` | 37 | 95.85 MHz | 386 ns | **332 MB/s** (+57%) |
| `NUM_RULES=5`/`ADDR_WIDTH=12`, off | 36 | 73.44 MHz | 490 ns | 261 MB/s |
| `NUM_RULES=5`/`ADDR_WIDTH=12`, on | 37 | 107.43 MHz | 344 ns | **372 MB/s** (+42%) |

The one case that genuinely pays is a master doing **single accesses**: those go
from 1 cycle to 2, so the +1 is a 100% overhead on the transaction rather than
3%. A CPU poking registers one word at a time sees that; a DMA engine moving
bursts does not. That asymmetry is the reason this is a parameter and not the
only behaviour.

---

## Integration into Platform Designer

1. Add the repository's top-level directory to the Quartus IP search path
   (**Tools ▸ Options ▸ IP Catalog Search Locations**), then **Platform
   Designer ▸ File ▸ Refresh System**. The core appears as *Avalon-MM Firewall*.
2. **Confirm the component packages cleanly for your Quartus version.**
   `hw.tcl` syntax has drifted across releases. If it does not import: open
   Component Editor, add the three files under `rtl/` as synthesis files with
   `avl_mm_firewall_pkg.sv` **first** and `avl_mm_firewall_top.sv` as top level,
   then **Analyze Synthesis Files**. Signal analysis should auto-group the
   `s0_*`/`m0_*`/`csr_*` ports; the one thing it cannot guess is
   `bridgesToMaster` on `s0`, so set that by hand.
3. Insert it in the path between the master and the peripheral. Because `s0`
   declares `bridgesToMaster m0`, **the peripheral's address does not change** —
   `s0`'s address space *is* `m0`'s. Dropping the firewall into an existing
   system moves nothing.
4. Connect `csr` to the CPU's data master and wire `irq` to a CPU interrupt.
5. **Make the protected peripheral's reset software-controllable.** The core
   does not drive it, but recovery from a timeout requires it. A reset bridge
   under software control, or a PIO bit, will do.
6. Program each rule to match the peripheral's actual address decode, and size
   `NUM_RULES`, `BURST_WIDTH` and `CSR_ADDR_WIDTH` accordingly.

---

## Software

The driver follows the standard Altera component layout, so a BSP picks it up
automatically:

| Path | What it is |
|---|---|
| `avl_mm_firewall_sw.tcl` | Driver description. `nios2-bsp-generate-files` scans the IP search path for `*_sw.tcl` and matches `hw_class_name` against the `_hw.tcl`'s `NAME` |
| `inc/altera_avalon_mm_firewall_regs.h` | Register offsets, `IORD_`/`IOWR_` accessors and bit masks. Depends only on `<io.h>`, so it is usable bare-metal with no driver at all |
| `HAL/inc/altera_avalon_mm_firewall.h` | Device struct, driver API, and the `_INSTANCE`/`_INIT` macros the BSP emits |
| `HAL/src/altera_avalon_mm_firewall.c` | Init, rule programming with the retire-first idiom, ISR, recovery |

Without the `_sw.tcl` none of this is found: the `.c` and `.h` would have to be
copied into every application by hand and would then drift from the hardware
they describe. With it, adding the component to a Platform Designer system is
enough.

`auto_initialize` is on, so the BSP emits `ALTERA_AVALON_MM_FIREWALL_INSTANCE`
and `_INIT` into `alt_sys_init.c` for every instance. What that does is
deliberately limited — base address and interrupt numbers from `system.h`, a
`CORE_INFO` version check, geometry read back from the hardware, and the
interrupt registered. It does **not** program the rule table or install the
reset callbacks, because neither can be derived from the hardware. That
division is the safe one: the table resets empty and the hardware is
default-deny, so the state after `alt_sys_init()` is "everything denied" —
exactly what should be true while an application is still starting up.

The driver compiles clean at `-Wall -Wextra -Wpedantic -Werror`.

```c
#include "altera_avalon_mm_firewall.h"

/* Holds the peripheral in reset for >= 16 clocks. A short spin, not usleep():
   the default ISR path calls recover(), which calls this, and usleep() must
   not be called from interrupt context. See the note below the example. */
static void periph_assert_reset(void *ctx)
{
    volatile int i;
    IOWR_ALTERA_AVALON_PIO_DATA(RESET_PIO_BASE, 0);
    for (i = 0; i < 64; i++) { }
}
static void periph_release_reset(void *ctx) { IOWR_ALTERA_AVALON_PIO_DATA(RESET_PIO_BASE, 1); }

static const alt_avalon_mm_firewall_rule my_map[] = {
    /* control registers: CPU may read and write, no bursting            */
    { 0x0001'0000u, 0x0001'00FFu, ALT_AVMM_FW_PERM_READ | ALT_AVMM_FW_PERM_WRITE },
    /* sample buffer: DMA may burst-read, nobody may write               */
    { 0x0002'0000u, 0x0002'FFFFu, ALT_AVMM_FW_PERM_READ | ALT_AVMM_FW_PERM_BURST },
};

/* firewall_0 is constructed and initialised by alt_sys_init() before main().
   `extern` because alt_sys_init.c owns the definition. */
extern alt_avalon_mm_firewall_dev firewall_0;

void firewall_setup(void)
{
    alt_avalon_mm_firewall_set_reset_handlers(&firewall_0, periph_assert_reset,
                                              periph_release_reset, NULL);
    alt_avalon_mm_firewall_configure(&firewall_0, my_map, 2);
    alt_avalon_mm_firewall_set_timeout(&firewall_0, 50000); /* cycles w/o progress */
}
```

Everything not described by a rule is denied. `configure()` retires the unused
rule slots as well as programming the used ones — a stale rule left valid is an
open window nobody remembers opening.

**The reset callbacks can run in interrupt context.** The ISR calls
`alt_avalon_mm_firewall_recover()` on a timeout, and `recover()` calls
`assert_reset` / `release_reset`, so anything blocking in those callbacks —
`usleep()`, a semaphore, a driver call that can sleep — blocks inside the ISR.
`_sw.tcl` also declares `isr_preemption_supported true`, which assumes the ISR
stays short. If your peripheral needs a long or coordinated reset, leave
`on_fault` to set a flag and call `recover()` from a thread instead; the driver
source says the same thing at the call site.

---

## Verification status — what is and is not proven

| Item | Status |
|---|---|
| Functional testbench (632 checks, four parameterisations) | **Passing** under Questa 2024.1 |
| SVA properties | **22/22**, 0 failures, **all non-vacuous** across all four parameterisations |
| Cover directives | **11/11 hit**, counts measured under Questa `-cover sbceft` |
| Strict LRM elaboration | **0 errors** under slang 11 |
| RTL lint | **Clean** at `verilator --lint-only -Wall`, nothing waived, across 5 parameter configurations |
| Burst throughput (33 / 36 cycles) | **Measured**, with in-suite regression guards |
| HAL driver | **Compiles clean** at `-Wall -Wextra -Wpedantic -Werror`; exercised against a stub register model |
| Questa code coverage | **Measured.** `avl_mm_firewall_top` statements 183/185, branches 137/140, expressions 81/86, conditions 33/39; `avl_mm_firewall_regs` statements 110/110. The unhit remainder is defensive code the design forbids reaching — see *Verification* |
| Verilator flow | **Passing** — 632 checks across all four parameterisations, matching Questa exactly. Needs **Verilator 5.050 or newer**: the assertions use `default disable iff`, ranged cycle delays (`##[a:b]`) and consecutive repetition (`[*n]`), none of which 5.020 implements |
| Synthesis results (LE/register count, Fmax) | **Measured** on a MAX 10 `10M50DAF484C7G` (`C7`, slow 1200 mV 85 °C) — see *Performance* for the full table. Standalone at the defaults: 60.77 MHz combinational, **95.85 MHz with `REGISTER_LOOKUP`**; 73.44 → **107.43 MHz** at `NUM_RULES=5`/`ADDR_WIDTH=12`. **100 MHz is reachable with `REGISTER_LOOKUP` at moderate `NUM_RULES`/`ADDR_WIDTH`, but not at the widest defaults**, where the remaining path is the `rd_deny_beats` ↔ `waitrequest` loop |
| `REGISTER_LOOKUP` mode | **Verified** — the full suite runs in both lookup modes (four parameterisations, 632 checks), 22/22 assertions non-vacuous in all of them |
| Behaviour on physical hardware | **Verified on a Terasic DE10-Lite** (MAX 10 `10M50DAF484C7G`): 16/16 scenarios in the [RTL example](example/de10_lite_rtl/README.md) at 50 MHz, and 41/41 checks in the [Nios II example](example/de10_lite_nios/README.md) at 100 MHz |
| Behaviour in a real Platform Designer system | **Verified.** The [Nios II example](example/de10_lite_nios/README.md) runs the core behind generated Qsys interconnect, a pipeline bridge and a Nios II/f data cache, at 100 MHz on hardware |
| Operation at 100 MHz | **Verified on hardware** with `REGISTER_LOOKUP=1` and the parameters sized to the system — see the [Nios II example](example/de10_lite_nios/README.md) |
| `hw.tcl` import into a specific Quartus release | **Verified** for Quartus 18.1.1 Standard: the component packages and generates in Platform Designer, and the BSP picks the driver up from `_sw.tcl`. Other releases untested |
| Wrapping (line-wrap) bursts | **Not supported.** Both interfaces declare `linewrapBursts false`; Platform Designer inserts an adapter if a master needs them |

---

## Roadmap

- **Per-master filtering** via a sideband ID signal — the natural next step,
  and the one thing address-range filtering fundamentally cannot do.
- **Autonomous flushing**, so `WR_BUSY`/`RD_BUSY` are guaranteed to reach zero
  and the bounded poll in the recovery sequence can become unconditional. The
  tracking registers already exist; this is a contained change and the most
  valuable one for anyone writing against this core.
- ~~**Registered lookup option**, as a parameter rather than a fork.~~
  **Done** — `REGISTER_LOOKUP`, default off. See *Performance*: 60.8 → 95.9 MHz
  at the defaults, 73.4 → 107.4 MHz at `NUM_RULES=5`/`ADDR_WIDTH=12`, for about
  90 logic elements and one cycle per transaction. What remains is the path it
  exposed underneath: a loop through the denied-read beat counter and the
  `waitrequest` handshake, which is what now caps the widest configuration at
  96 MHz.
- Rule-hit counters per window, for auditing and profiling access patterns.
- Synthesis numbers (LE/register count, Fmax vs `NUM_RULES`) — currently the
  largest unmeasured item.
- A `debugaccess` qualifier, so a debugger can be exempted from the rules.
