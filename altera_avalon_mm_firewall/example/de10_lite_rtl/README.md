# Avalon-MM Firewall — DE10-Lite demonstration

A complete, self-checking hardware demonstration of the
[Avalon-MM Firewall](../../README.md) core, targeting the Terasic **DE10-Lite**
(Intel MAX 10, `10M50DAF484C7G`).

Sixteen scenarios drive the core through its documented behaviour — access
control, both violation types, both timeout shapes, blocking, recovery, and
the burst cases that have no AXI4-Lite analogue at all — and check every
response against the register map. The board shows which scenario is running
and whether it passed.

**Verified on hardware: all 16 scenarios pass on a physical DE10-Lite.**

**No CPU, no Platform Designer system, and no software are required.** The
whole demo is synthesisable RTL.

This is the Avalon-MM counterpart of
[`../../../altera_axi4_lite_firewall/example/de10_lite_rtl/`](../../../altera_axi4_lite_firewall/example/de10_lite_rtl/).
The two are worth reading side by side: the shape is the same, and everything
that differs, differs because Avalon-MM bursts and AXI4-Lite does not.

---

## What you see

```
   HEX5   HEX4        HEX3 HEX2 HEX1 HEX0
   ┌──┐   ┌──┐        ┌──┐ ┌──┐ ┌──┐ ┌──┐
   │ 9│   │ P│        │ F│ │ F│ │ F│ │ F│
   └──┘   └──┘        └──┘ └──┘ └──┘ └──┘
  scenario  verdict     pass bitmap, one bit per scenario
                        0xFFFF = all sixteen passed

   LEDR9  LEDR8 ... LEDR0
    irq   ←── live firewall STATUS ──→
```

- **HEX5** — the scenario currently selected or running, `0`–`F`
- **HEX4** — `P` passed · `F` failed · `-` running · blank = no result yet
- **HEX3–HEX0** — the pass bitmap (default), or the last value the sequencer
  read, selected by `SW[6]`
- **LEDR[8:0]** — the firewall's live `STATUS` register, polled continuously
- **LEDR[9]** — the firewall's `irq` output

### Controls

| Control | Function |
|---|---|
| `KEY1` | System reset |
| `KEY0` | Step mode: run the selected scenario. Auto mode: restart the sweep |
| `SW[3:0]` | Scenario `0`–`F` to run in step mode |
| `SW[5]` | `0` = LEDR shows `STATUS[8:0]` · `1` = shows `STATUS[9:1]` |
| `SW[6]` | `0` = HEX3–0 show the pass bitmap · `1` = show the last observed word |
| `SW[7]` | With `SW[6]=1`: show the upper half of the observed word |
| `SW[8]` | Freeze the auto sweep on the current scenario |
| `SW[9]` | `0` = step mode · `1` = auto sweep |
| `SW[4]` | Unused |

`STATUS` is ten bits and the board has ten LEDs, one of which is spoken for by
`irq`. `SW[5]` slides the window up by one so `RD_CMD_STUCK` (bit 9) can be
seen; scenario `C` checks it programmatically either way.

**Quick start:** program the board, flip `SW[9]` up. The sweep runs all sixteen
scenarios about 170 ms apart, then repeats. Every digit of HEX3–HEX0 reading
`F` means all sixteen passed.

At power-up, before you touch anything, the display reads **`0P0001`**. That is
correct and not a hang: the sequencer runs scenario 0 by itself so that a
scenario you pick later finds a programmed rule table, and then waits for you.

## Testing it without looking at the board

```bash
./run_on_board.sh          # program, then drive and check over JTAG
```

Seven-segment displays cannot be read by a script, so the design carries an
**In-System Sources and Probes** instance that exposes the sequencer's controls
and its pass bitmap over the same USB connection used to program it. The script
drives the sweep, waits for the bitmap to reach `FFFF`, then runs scenario `b`
on its own and checks that only that one ran and left the expected `STATUS`.
Exit status is 0 only if everything passed.

```
--- state at power-up ---
  idle             bitmap=0001 scenario=0 pass=1 valid=1 running=0 status=000
--- auto sweep, driven over JTAG ---
  after sweep      bitmap=FFFF scenario=F pass=1 valid=1 running=0 status=000
--- step mode: run scenario b (write timeout) on its own ---
  scenario b       bitmap=FFFF scenario=B pass=1 valid=1 running=0 status=134
--- step mode: run scenario C (read timeout, both shapes) ---
  scenario C       bitmap=FFFF scenario=C pass=1 valid=1 running=0 status=234
RESULT: PASSED ON HARDWARE
```

Those two `status` values are the live `STATUS` register read off real silicon.
`134` is `TIMEOUT | ISOLATED | BLOCKED | WR_CMD_STUCK` after scenario `b`;
`234` is the same three bits with **`RD_CMD_STUCK`** instead, after `C`. The
probe is 33 bits wide rather than 32 for exactly that reason — `STATUS` is ten
bits, and a 32-bit probe carrying `status[8:0]` could not see bit 9 at all.

`run_on_board.sh` uses **Quartus 18.1** for `quartus_stp` and a newer Quartus
(default `/opt/altera/25.1std`) for programming, because the newer JTAG stack
reads this board's chain more reliably. Set `JTAG_ROOT=$QUARTUS_ROOT` if you
have only one installation.

The probe is behind an `ENABLE_ISSP` macro that only the Quartus project sets,
so simulation never has to resolve the `altsource_probe` megafunction, and the
sources are OR-ed with the physical switches rather than replacing them — the
board behaves exactly as before with nothing attached.

---

## How it is wired

```
    ┌────────────────┐    csr        ┌─────────────────────┐
    │                ├──────────────►│                     │
    │ demo_sequencer │               │ avl_mm_firewall_top │   m0   ┌──────────────────┐
    │                │    s0         │                     ├───────►│ demo_target_slave│
    │  (the driver)  ├──────────────►│    (the IP core)    │        │ (the peripheral  │
    │                │               │                     │        │  being protected)│
    └───────┬────────┘               └──────────┬──────────┘        └────────▲─────────┘
            │                                   │ irq                        │
            │  hang / hang_late / reset ────────┼────────────────────────────┘
            │                                   ▼
            └──────────────────────►  LEDR, HEX0..HEX5
```

`demo_sequencer` plays the part a Nios II driver would play. `demo_target_slave`
is a burst-capable Avalon-MM scratchpad with an injectable fault, because
demonstrating a *fault-isolation* firewall needs something that can actually
fail on cue. It lives in [`../common/`](../common/) so the Nios II example can
share it.

The sequencer runs a **program in a ROM**, not a state machine — sixteen
scenarios of eight to thirty steps is several hundred states, which is
unreadable as an FSM and is a readable listing as microcode. The instruction
set and the full program are in
[`rtl/demo_sequencer.sv`](rtl/demo_sequencer.sv); the program is the part worth
reading, and every `OP_CHK*` in it is a claim about documented core behaviour.

Every scenario is **self-contained**. Before each one the engine runs a fixed
heal sequence (reset the peripheral, acknowledge faults, `RECOVERY.UNBLOCK`,
release), so step mode can run them in any order, any number of times.

### The address map the rules describe

Five windows, and one address covered by no rule. The peripheral itself answers
all of them — only the firewall ever says no, so an error response is
unambiguously the firewall's doing.

| Window | Range | Permissions |
|---|---|---|
| rule 0 | `0x00`–`0x3F` | read + write + burst |
| rule 1 | `0x40`–`0x7F` | read + write + burst |
| rule 2 | `0x80`–`0xAF` | read only, burst |
| rule 3 | `0xB0`–`0xDF` | write only, burst |
| rule 4 | `0xE0`–`0xEF` | read + write, **no bursts** |
| — | `0xF0`+ | no rule → `DECODEERROR` |

Rules 0 and 1 **abut on purpose**, and both permit everything. That is what
makes scenario 9 meaningful.

---

## The sixteen scenarios

| # | Name | What it demonstrates | Expected |
|---|---|---|---|
| `0` | CFG | Programs rules 0–4 and the timeout; reads `CORE_INFO` | `0x01004805` — v1.0, 5 rules, `BURST_WIDTH` 8, 4 bytes/beat |
| `1` | W_OK | Permitted single write is forwarded | `OKAY`, `STATUS` clean |
| `2` | R_OK | And reads back byte-for-byte | `OKAY`, data intact |
| `3` | BW_OK | Permitted **16-beat burst write** | `OKAY`, all 16 beats accepted |
| `4` | BR_OK | **16-beat burst read**, checked beat for beat | `OKAY`, 16 beats, ramp matches |
| `5` | THRU | **Burst throughput measured on silicon** | 16-beat read completes inside the cycle guard |
| `6` | RO_W | Write to the read-only window | `SLAVEERROR` + `PERM_VIOLATION` + `irq`, fault registers name the access |
| `7` | WO_R | Read of the write-only window — **and returns zeros**, not the stored data | `SLAVEERROR`, data = 0 |
| `8` | DEC_R | Burst read of an address matching no rule | `DECODEERROR`, **all 4 beats still returned**, `m0` never touched |
| `9` | STRAD | **Burst across two abutting permitted windows** | `DECODEERROR` + `BURST_VIOLATION`, `m0` never touched |
| `A` | NOBST | Window with `BURST_ALLOW` clear: single access fine, burst refused | `SLAVEERROR` + `BURST_VIOLATION`, contents untouched |
| `b` | TMO_W | Peripheral refuses the command outright | `SLAVEERROR` + `TIMEOUT` + `ISOLATED` + `BLOCKED` + **`WR_CMD_STUCK`** |
| `C` | TMO_R | **Both** read-timeout shapes: accepted-then-silent, then command-never-accepted | `SLAVEERROR` both times; `RD_CMD_STUCK` clear on the first, **set** on the second |
| `d` | BLKD | While blocked, traffic is *rejected, not stalled*, and nothing new reaches the peripheral | `SLAVEERROR`, watcher never fires, no new fault latched |
| `E` | RCVR | The full recovery sequence, done correctly | W1C proven not to unblock; no stale write; traffic healthy after |
| `F` | STALE | The same recovery with the reset released **one step too early** | the failed write lands in the peripheral — hazard reproduced |

### Scenario 9 is the one this core exists for

The burst starts at `0x30`, inside rule 0, and runs eight beats to `0x4F` —
inside rule 1. **Both windows permit read, write and bursts**, so nothing about
this access is forbidden by either rule on its own. It is refused anyway,
because permissions are per-window and adjacent windows deliberately do not
merge.

A watcher on `m0` proves the peripheral was never touched. A firewall that
checked only the start address would have forwarded the whole burst, and a DMA
engine would have walked straight through the window boundary — which is
precisely the case this core was built for and its AXI4-Lite sibling cannot
express.

### Scenarios b and C are the pair to look at

Both are downstream timeouts. Both release the master with `SLAVEERROR` rather
than hanging it, and both latch `TIMEOUT | ISOLATED | BLOCKED`. They differ in
one bit, and that bit is what a driver needs:

- **b** sets `WR_CMD_STUCK` — the peripheral never accepted the command, so the
  core is holding an `m0_write` whose `waitrequest` never fell. Avalon-MM
  forbids withdrawing it; only `RECOVERY.UNBLOCK` retracts it.
- **C** runs *both* read shapes in one scenario. Its first half is the
  accepted-then-silent case: `RD_CMD_STUCK` stays **clear** and the peripheral
  owes beats forever, which is what makes an unbounded poll of the busy bits
  hang exactly when recovery matters. Its second half starves the read command
  outright and **sets `RD_CMD_STUCK`**.

  The starve half is deliberately last, so the scenario *ends* with bit 9 set
  and the board can actually show it under `SW[5]`. `RD_CMD_STUCK` is the only
  STATUS bit no other scenario reaches, and a bit the display can address but
  nothing ever lights is a bit nobody can trust. Scenario `b` ends the same way
  with `WR_CMD_STUCK`, so the two are symmetric.

### Scenario F is the one where `P` means the bad thing happened

`F` deliberately performs the recovery **wrongly**: it releases the peripheral
reset *before* writing `RECOVERY.UNBLOCK`. The frozen `m0_write` from the
timed-out transaction is still asserted, the freshly-released peripheral sees a
perfectly valid command sitting on the bus, completes the handshake, and
commits a write the master was already told had **failed**. The scenario then
reads the location back and finds `0xCAFEF00D` there.

Scenario `E` is the same sequence with the reset **held across** the `UNBLOCK`
write, and reads back `0x00000000` — nothing stale landed.

This is why the core's recovery sequence puts `UNBLOCK` at step 5 and the reset
release at step 6, and why it deviates from AMD's published AXI Firewall flow,
which resets and then unblocks. Two adjacent, deterministic scenarios you can
run on a board.

---

## Building for the board

```bash
cd quartus
/opt/intelFPGA/18.1/quartus/bin/quartus_sh --flow compile de10_lite_avl_mm_firewall_demo
```

Then program `output_files/de10_lite_avl_mm_firewall_demo.sof`, or just run
`./run_on_board.sh`, which does both.

**Quartus 18.1 is required to build.** MAX 10 support was dropped after
Quartus 20.x, so a newer Quartus cannot target this device at all.

The project references the core's RTL directly at `../../../rtl/`, so it always
builds whatever is actually in the repository — there is no private copy of the
core to drift.

> **The pin assignments are identical to the AXI4-Lite demo's**, which were
> diffed against the DE10-Lite Golden Top project on the Terasic System CD; all
> 71 match. Same board, same pins. If your board is a different revision, diff
> again before the first run: a wrong pin on a 3.3 V bank is the one mistake in
> this project that can damage hardware.

---

## Simulating

Both flows run the **board-level** testbench: it drives the DE10-Lite's pins
and reads its LEDs and seven-segment displays, so what it checks is what you
could verify by looking at the board.

```bash
# Questa/ModelSim
cd simulation/questa && vsim -c -do "do run_sim.tcl; quit -f"

# licence-free
cd simulation/verilator && ./run_sim.sh
```

Both compile with `+define+DEMO_TRACE`, so a failing check prints its program
counter, what was observed and what was expected. On the board a failure is one
letter; in simulation it should say why.

**The core's own 20 assertions are bound into the demo's firewall instance**
by the testbench, so the simulation checks the core's protocol, security and
liveness properties while *synthesisable hardware* drives it — the one thing
the core's own suite cannot do. That is not decoration: binding them is what
revealed that no scenario ever starved a read command, so `RD_CMD_STUCK` was
never set and three properties sat vacuous. Scenario C covers both read-timeout
shapes because of it. Compile with `+define+DEMO_NO_SVA` to leave them out.

This does not replace the core's own suite in
[`../../simulation/`](../../simulation/), which binds SVA and collects coverage
against the core in isolation. The two are complementary: this is the only
place the core is driven by *synthesisable hardware* rather than testbench
tasks, through the same RTL that gets programmed into the FPGA.

---

## Measured results

Everything below was produced on this repository's current sources.

### Simulation

| Flow | Result |
|---|---|
| Questa 2024.1, board-level testbench | **91 / 91 checks pass** |
| Core's 20 SVA properties, bound into the demo | **0 failures**, 19 of 20 reached |
| Verilator | **Not run** — not installed on the machine this was built on |

The one property the demo never reaches is `a_no_orphan_readdata`, which needs
read beats arriving *after* the core has abandoned a burst. This peripheral
cannot produce that: its silent mode goes dead and stays dead. The core's own
regression covers it non-vacuously, so it is left there rather than growing a
third fault mode here.

### Synthesis — Quartus Prime 18.1.1 Standard, `10M50DAF484C7G`

0 errors, 20 warnings, no critical warnings. Full compile through the
Assembler; a `.sof` is produced and was programmed to a real board.

| Resource | Used | Device | % |
|---|---|---|---|
| Total logic elements | 5,254 | 49,760 | 11% |
| — combinational functions | 4,277 | 49,760 | 9% |
| — dedicated logic registers | 3,006 | 49,760 | 6% |
| Total pins | 71 | 360 | 20% |
| Total memory bits | 0 | 1,677,312 | 0% |
| Embedded multiplier 9-bit elements | 0 | 288 | 0% |
| PLLs | 0 | 4 | 0% |

The design is pure logic: no block RAM, no multipliers, no PLL. The
232-instruction microcode ROM and the 64-word scratchpad both synthesise into
logic rather than M9Ks, which is where most of the footprint goes.

Broken down by entity:

| Entity | Logic elements | Registers |
|---|---|---|
| **`avl_mm_firewall_top` — the IP core** | **1,059** | **429** |
|  └ `avl_mm_firewall_regs` | 582 | 213 |
| `demo_target_slave` (64-word scratchpad in flops) | 2,333 | 1,920 |
| `demo_sequencer` (incl. both masters and the ROM) | 1,518 | 476 |
|  └ `demo_avl_mm_master` ×2 (`u_ctl` + `u_dat`) | 445 | 241 |
| `altsource_probe` + `sld_hub` (JTAG probe) | 201 | 127 |
| `hex7seg` ×6 | 54 | 0 |
| `key_debounce` | 28 | 21 |

At `NUM_RULES = 5`, `ADDR_WIDTH = 12`, `REGISTER_LOOKUP = 1` the core costs
**1,059 LEs and 429 registers** — under half the demo around it.

### Timing — 50 MHz, slow 1200 mV 85 °C model

| Metric | Value |
|---|---|
| Fmax | **73.75 MHz** |
| Setup slack | **+6.440 ns** |
| Hold slack | **+0.341 ns** |
| Total negative slack | 0.000 |

Timing closes with about **47% margin** over the board's 50 MHz oscillator —
up from 5% before `REGISTER_LOOKUP` was turned on.

**The critical path is inside the IP core**, and getting here took three
changes worth understanding — all of them the core's own documented advice,
now with numbers attached:

- At the core's defaults (`NUM_RULES = 8`, `ADDR_WIDTH = 32`, combinational
  lookup) this design **misses 50 MHz** — Fmax 49.19 MHz, setup slack
  −0.328 ns.
- `NUM_RULES = 5` is what the map actually needs. The core README's *"use the
  smallest that covers your map"* is not stylistic advice.
- `ADDR_WIDTH = 12` is a bigger lever. This core checks the **first and last
  byte** of every transaction, so there are two comparators per rule, and every
  one of those carry chains is `ADDR_WIDTH` bits long. The peripheral occupies
  256 bytes; a 32-bit address space buys nothing and costs margin.
- **`REGISTER_LOOKUP = 1`** is the biggest single win: 52.53 → 73.75 MHz, for
  14 logic elements and 8 registers. This demo is the only place that mode
  runs on real silicon.

With the lookup registered, the worst path starts at the sequencer's own
address register:

```
demo_avl_mm_master|addr_r  →  avl_mm_firewall_top|r_r_contain
```

— the master's address, through the burst extent adder and the rule
comparators, into the lookup's new pipeline register. That is the *first* half
of the split path, and it is what now caps the demo at 73.75 MHz. This is the
demo's ceiling, not the core's: the core alone in this configuration measures
107.43 MHz, and the gap is the sequencer's output path plus the routing
between the two.

### Core Fmax, measured on its own

Synthesised standalone with virtual pins, same device and timing model. These
are the first Fmax numbers this core has had — its README listed synthesis as
*"Not measured"* until this demo was built.

| Configuration | `REGISTER_LOOKUP=0` | `REGISTER_LOOKUP=1` |
|---|---|---|
| `NUM_RULES=8`, `ADDR_WIDTH=32` (defaults) | 60.77 MHz · 2,649 LEs | **95.85 MHz** · 2,736 LEs |
| `NUM_RULES=5`, `ADDR_WIDTH=12` (this demo) | 73.44 MHz · 1,183 LEs | **107.43 MHz** · 1,213 LEs |
| `NUM_RULES=4`, `ADDR_WIDTH=12` | 73.10 MHz · 1,101 LEs | — |
| `NUM_RULES=2`, `ADDR_WIDTH=12` | 83.31 MHz · 928 LEs | — |

Shrinking the configuration alone is not enough to reach 100 MHz: even at two
rules and a 12-bit address space the combinational lookup tops out at 83 MHz on
this `C7` part. `REGISTER_LOOKUP` is what clears it — 107 MHz at this demo's
configuration, 96 MHz at the widest defaults, for about 90 logic elements and
one cycle per transaction. See the core's *Performance* section for the
bandwidth arithmetic; the short version is that the extra cycle costs ~3% on a
32-beat burst and the clock buys back far more.

---

## What is and isn't verified

| Item | Status |
|---|---|
| **All 16 scenarios on a physical DE10-Lite** | **Passing** — driven and read back over JTAG |
| All 16 scenarios, board-level simulation | **Passing** under Questa 2024.1, 91/91 checks |
| Display and LED decode | **Checked** against an independently written glyph table |
| Step mode, auto sweep, scenario selection | **Checked** by driving the pins |
| `STATUS` after a timeout, read off silicon | **Checked** — `0x134` (write) and `0x234` (read, `RD_CMD_STUCK`) over JTAG |
| Core's SVA properties under a hardware driver | **0 failures**, 19 of 20 reached |
| Synthesis for `10M50DAF484C7G` | **Clean**, 0 errors, `.sof` produced and programmed |
| Timing closure at 50 MHz | **Closed**, +6.440 ns setup slack (47% margin) |
| Core resource usage and Fmax | **Measured** — first numbers for this core |
| **Pin assignments** | **Inherited** from the AXI4-Lite demo, which were diffed against the Golden Top; all 71 identical |
| Verilator flow | **Not run** — Verilator is not installed on the build machine |
| `REGISTER_LOOKUP` on real silicon | **Verified** — this demo is built with it on, and all 16 scenarios pass on the board |
| Operation of *this demo* at 100 MHz | **Not achievable.** The demo closes at 73.75 MHz; the limit is the sequencer's address path into the core's lookup register, not the core, which measures 107.43 MHz alone in this configuration |

---

## Files

```
example/de10_lite_rtl/
├── README.md                              This file
├── rtl/
│   ├── de10_lite_avl_mm_firewall_demo.sv  Top level: pins, reset, display, watcher
│   ├── demo_sequencer.sv                  Microcoded engine + the 16-scenario program
│   ├── demo_avl_mm_master.sv              Burst-capable Avalon-MM master, used for both ports
│   ├── hex7seg.sv                         Seven-segment decode
│   └── key_debounce.sv                    Button synchroniser and debouncer
├── tb/
│   └── de10_lite_avl_mm_firewall_demo_tb.sv   Board-level self-checking testbench
├── simulation/
│   ├── questa/run_sim.tcl
│   └── verilator/run_sim.sh
├── board/
│   └── issp_run.tcl                       Drives the demo over JTAG and checks it
├── run_on_board.sh                        Program + run + report
└── quartus/
    ├── de10_lite_avl_mm_firewall_demo.qpf Project
    ├── de10_lite_avl_mm_firewall_demo.qsf Device, pins, source list
    └── de10_lite_avl_mm_firewall_demo.sdc Timing constraints
```

The protected peripheral is shared with the Nios II example and lives in
[`../common/`](../common/).
