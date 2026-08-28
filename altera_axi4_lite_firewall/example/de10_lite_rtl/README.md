# AXI4-Lite Firewall — DE10-Lite demonstration

A complete, self-checking hardware demonstration of the
[AXI4-Lite Firewall](../../README.md) core, targeting the Terasic **DE10-Lite**
(Intel MAX 10, `10M50DAF484C7G`).

Sixteen scenarios drive the core through every documented behaviour — access
control, both violation types, both timeout shapes, isolation, recovery,
bypass and interrupt masking — and check every response against the register
map. The board shows which scenario is running and whether it passed.

**Verified on hardware: all 16 scenarios pass on a physical DE10-Lite.**

**No CPU, no Platform Designer system, and no software are required.** The
whole demo is synthesisable RTL.

If you want the opposite — the same core driven by C on a real processor,
through generated Platform Designer interconnect — see
[`../de10_lite_nios/`](../de10_lite_nios/), which runs at 100 MHz on a
Nios II/f and is verified on hardware. The two examples answer different
questions: this one asks whether the core behaves, that one asks whether it
integrates.

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
    irq   ←── live firewall STATUS[8:0] ──→
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
| `SW[6]` | `0` = HEX3–0 show the pass bitmap · `1` = show the last observed word |
| `SW[7]` | With `SW[6]=1`: show the upper half of the observed word |
| `SW[8]` | Freeze the auto sweep on the current scenario |
| `SW[9]` | `0` = step mode · `1` = auto sweep |
| `SW[5:4]` | Unused |

**Quick start:** program the board, flip `SW[9]` up. The sweep runs all sixteen
scenarios about 170 ms apart, then repeats. Every digit of HEX3–HEX0 reading
`F` means all sixteen passed.

At power-up, before you touch anything, the display reads **`0P0001`**. That is
correct and not a hang: the sequencer runs scenario 0 by itself so that a
scenario you pick later finds a programmed rule table, and then waits for you.
`0` is the scenario, `P` its verdict, `0001` the pass bitmap with bit 0 set.

## Testing it without looking at the board

```bash
./run_on_board.sh          # program, then drive and check over JTAG
```

Seven-segment displays cannot be read by a script, so the design carries an
**In-System Sources and Probes** instance that exposes the sequencer's controls
and its pass bitmap over the same USB connection used to program it. The script
drives the sweep, waits for the bitmap to reach `FFFF`, then runs scenario 9 on
its own and checks that only that one ran. Exit status is 0 only if everything
passed.

```
--- state at power-up ---
  idle             bitmap=0001 scenario=0 pass=1 valid=1 running=0 status=000
--- auto sweep, driven over JTAG ---
  after sweep      bitmap=FFFF scenario=0 pass=1 valid=1 running=0 status=000
--- step mode: run scenario 9 (timeout) on its own ---
  scenario 9       bitmap=FFFF scenario=9 pass=1 valid=1 running=0 status=09C
RESULT: PASSED ON HARDWARE
```

That `status=09C` is the live `STATUS` register after scenario 9's timeout:
`TIMEOUT_ERROR | ISOLATED | BLOCKED | WR_CMD_STUCK`, read off real silicon.

The probe is behind a `ENABLE_ISSP` macro that only the Quartus project sets,
so simulation never has to resolve the `altsource_probe` megafunction, and the
sources are OR-ed with the physical switches rather than replacing them — the
board behaves exactly as before with nothing attached.

```
probe[35:0] = { done_count[3:0], status[8:0], running, result_valid,
                result_pass, scenario[3:0], pass_bitmap[15:0] }
source[7:0] = { -, start, freeze, auto_mode, select[3:0] }
```

### Two JTAG hazards this design handles

Both are general to `altsource_probe`, not quirks of this example. They are
worth knowing because each one presents as *the firewall failing*, which is
what neither of them is.

**The source register is not written atomically.** `altsource_probe` shifts a
new source value in over JTAG one bit at a time, and with
`enable_metastability = "NO"` those bits reach the fabric as they land — there
is no holding register between the scan chain and the design. For a few
microseconds the design sees words that were never written: a mixture of the
old value and the new one. Source bit 6 is a **start edge** and bits `[3:0]`
choose **which scenario to start**, so a start edge arriving while the select
bits are still half-updated runs the *wrong scenario*, and the host reports a
wrong scenario number and a wrong `STATUS`.

The fix is `src_stable` in the top level: the source word is filtered the way
`key_debounce` filters a mechanical button, and only counts as a new value once
it has held still for **256 consecutive clocks** (5.1 µs at 50 MHz). This was
isolated on the SDRAM controller example, which has the same construct, by
asking for scenario 4 and watching scenario 3 run.

**`running` is a level, and a JTAG host cannot reliably see it.** A probe read
takes tens of milliseconds while most scenarios finish in microseconds, so the
host asks "did it start?" and the answer is already "it finished" — waiting on
that edge is racing by construction. `done_count` exists for this: it
increments once per completed scenario and never decrements, so the host
records it before the request and waits for it to *move*. Observed directly
here — before `done_count` was added, scenario 9 ran correctly and the script
still called it a failure because `running` was never sampled high.

---

## How it is wired

```
    ┌────────────────┐  s_axi_ctrl   ┌──────────────────┐
    │                ├──────────────►│                  │
    │ demo_sequencer │               │ axi4_lite_firewall_top │  m_axi   ┌──────────────────┐
    │                │    s_axi      │                  ├─────────►│ demo_axi4_lite_target_slave│
    │  (the driver)  ├──────────────►│  (the IP core)   │          │ (the peripheral  │
    │                │               │                  │          │  being protected)│
    └───────┬────────┘               └────────┬─────────┘          └────────▲─────────┘
            │                                 │ irq                         │
            │  hang / hang_late / reset ───────┼─────────────────────────────┘
            │                                 ▼
            └──────────────────────►  LEDR, HEX0..HEX5
```

`demo_sequencer` plays the part a Nios II driver would play. `demo_axi4_lite_target_slave`
is a small AXI4-Lite scratchpad with an injectable fault, because demonstrating
a *fault-isolation* firewall needs something that can actually fail on cue.

The sequencer runs a **program in a ROM**, not a state machine — sixteen
scenarios of eight to twenty-five steps is roughly two hundred states, which is
unreadable as an FSM and is a readable listing as microcode. The instruction
set and the full program are in
[`rtl/demo_sequencer.sv`](rtl/demo_sequencer.sv); the program is the part worth
reading, and every `OP_CHK*` in it is a claim about documented core behaviour.

Every scenario is **self-contained**. Before each one the engine runs a fixed
heal sequence (reset the peripheral, acknowledge faults, `RECOVERY.UNBLOCK`,
release), so step mode can run them in any order, any number of times.

---

## The sixteen scenarios

| # | Name | What it demonstrates | Expected |
|---|---|---|---|
| `0` | CFG | Programs rules 0–2 and the timeout; reads `CORE_INFO` | version `0x0200`, 8 rules |
| `1` | W_OK | Permitted write is forwarded | `OKAY`, `STATUS` clean |
| `2` | R_OK | And reads back byte-for-byte | `OKAY`, data intact |
| `3` | RO_R | Read of the read-only region | `OKAY` |
| `4` | RO_W | Write to it is denied | `SLVERR` + `PERM_VIOLATION` + `irq`, fault registers name the access |
| `5` | WO_W | Write to the write-only region | `OKAY` |
| `6` | WO_R | Read of it is denied — **and returns zeros**, not the stored data | `SLVERR`, `RDATA` = 0 |
| `7` | DEC_W | Write to an address matching no rule | `DECERR` + `ADDR_VIOLATION` |
| `8` | DEC_R | Same on the read side | `DECERR`, `FAULT_INFO.WAS_WRITE` = 0 |
| `9` | TMO_W | Peripheral refuses the command outright | `SLVERR` + `TIMEOUT` + `ISOLATED` + `BLOCKED` + **`WR_CMD_STUCK`** |
| `A` | BLKD | While blocked, traffic is *rejected, not stalled*, and **nothing new reaches the peripheral** | `SLVERR`, downstream-command watcher never fires |
| `b` | RCVR | The full v2.0 recovery, done correctly | W1C proven not to unblock; no stale write; traffic healthy after |
| `C` | STALE | The same recovery with the reset released **one step too early** | the failed write lands in the peripheral — hazard reproduced |
| `d` | TMO_R | Peripheral *accepts* a read then goes silent | `SLVERR` + `TIMEOUT` + **`RD_RESP_BUSY`** (not `RD_CMD_STUCK`) |
| `E` | BYP | `CTRL.GLOBAL_ENABLE = 0` forwards unchecked — shown before, during, after | `DECERR` → `OKAY` → `DECERR` |
| `F` | MASK | `IRQ_ENABLE` gates the interrupt only, not `STATUS` | `SLVERR` recorded, `irq` stays low; unmasking re-raises it |

### Scenarios 9 and d are the pair to look at

Both are downstream timeouts. Both report `SLVERR` upstream and latch
`TIMEOUT | ISOLATED | BLOCKED`. They differ in one bit, and that bit is what a
driver needs:

- **9** sets `WR_CMD_STUCK` — the peripheral never accepted the command, so the
  core is holding a `VALID` nobody took. Polling will never see this clear;
  only `RECOVERY.UNBLOCK` retracts it.
- **d** sets `RD_RESP_BUSY` — the peripheral *did* accept and then died, so it
  owes a response forever. This is the case that makes an unbounded poll of the
  busy bits hang exactly when recovery matters.

### Scenario C is the one where `P` means the bad thing happened

`C` deliberately performs the recovery **wrongly**: it releases the peripheral
reset *before* writing `RECOVERY.UNBLOCK`. The orphaned `AWVALID` from the
timed-out write is still asserted, the freshly-reset peripheral sees a
perfectly valid command sitting on the bus, and commits a write the master was
already told had **failed**. The scenario then reads the location back and
finds `0xCAFEF00D` there.

Scenario `b` is the same sequence with the reset **held across** the `UNBLOCK`
write, and reads back `0x00000000` — nothing stale landed.

This is the hazard the core's `verification/orphan_response_tb.sv` measures as
"0 of 25 offsets vs 1 of 25", reproduced here as two adjacent, deterministic
scenarios you can run on a board.

> **A note on the core's documented sequence.** The core's README presents
> "reset the peripheral" (step 4) and "write `RECOVERY.UNBLOCK`" (step 5) as
> separate steps, which reads as though the reset may be a pulse that ends
> before the `UNBLOCK`. It must not be. Building this demo is what surfaced
> that: with the reset released first, the window is not merely theoretical but
> deterministic. Both the heal sequence here and
> [the driver](../../HAL/src/altera_axi4_lite_firewall.c) hold the
> reset across the `UNBLOCK` write. The core's user guide has not been changed.

---

## Building for the board

```bash
cd quartus
quartus_sh --flow compile de10_lite_axi4_lite_firewall_demo
```

Then program `output_files/de10_lite_axi4_lite_firewall_demo.sof` with the Programmer, or:

```bash
quartus_pgm -m jtag -o "p;output_files/de10_lite_axi4_lite_firewall_demo.sof"
```

The project references the core's RTL directly at `../../../rtl/`, so it always
builds whatever is actually in the repository — there is no private copy of the
core to drift.

> **The pin assignments have been checked.** All 71 were diffed against the
> DE10-Lite Golden Top project on the Terasic System CD and match exactly. If
> your board is a different revision, diff again before the first run: a wrong
> pin on a 3.3 V bank is the one mistake in this project that can damage
> hardware.

---

## Simulating

Both flows run the **board-level** testbench: it drives the DE10-Lite's pins
and reads its LEDs and seven-segment displays, so what it checks is what you
could verify by looking at the board.

```bash
# licence-free
cd simulation/verilator && ./run_sim.sh

# Questa/ModelSim
cd simulation/questa && vsim -c -do run_sim.tcl
```

Both compile with `+define+DEMO_TRACE`, so a failing check prints its program
counter, what was observed and what was expected. On the board a failure is one
letter; in simulation it should say why.

This does not replace the core's own suite in
[`../../simulation/`](../../simulation/), which binds SVA and collects coverage
against the core in isolation. The two are complementary: this is the only
place the core is driven by *synthesisable hardware* rather than testbench
tasks, through the same RTL that gets programmed into the FPGA.

---

## Software

There is none here, and that is the point of this example. The driver and the
Nios II application moved to [`../de10_lite_nios/software/`](../de10_lite_nios/software/),
where they are actually exercised on a processor.

---

## Measured results

Everything below was produced on this repository's current sources.

### Simulation

| Flow | Result |
|---|---|
| Questa 2024.1 | **80 / 80 board-level checks pass** |
| Verilator 5.020 (`--binary --timing`) | **80 / 80** |
| `verilator --lint-only -Wall` | clean, waiving only `DECLFILENAME` and `UNUSEDSIGNAL` — the same two the core's own flow waives |
| Driver host tests | **30 / 30** |
| `nios2-elf-gcc -Wall -Wextra -Wpedantic -Werror` | clean, against the real HAL `io.h` |

### Synthesis — Quartus Prime 18.1.1 Standard, `10M50DAF484C7G`

0 errors. Full compile through the Assembler; a `.sof` is produced.

| Resource | Used | Device | % |
|---|---|---|---|
| Total logic elements | 4,127 | 49,760 | 8% |
| — combinational functions | 3,791 | 49,760 | 8% |
| — dedicated logic registers | 1,951 | 49,760 | 4% |
| Total pins | 71 | 360 | 20% |
| Total memory bits | 0 | 1,677,312 | 0% |
| Embedded multiplier 9-bit elements | 0 | 288 | 0% |
| PLLs | 0 | 4 | 0% |

The design is pure logic: no block RAM, no multipliers, no PLL. The
200-instruction microcode ROM synthesises into logic rather than an M9K, which
is where a good part of `demo_sequencer`'s footprint goes.

Broken down by entity:

| Entity | Logic elements | Registers |
|---|---|---|
| **`axi4_lite_firewall_top` — the IP core** | **1,908** | **768** |
|  └ `axi4_lite_firewall_regs` | 1,657 | 618 |
| `demo_sequencer` (incl. both AXI masters and the 200-instruction ROM) | 1,202 | 401 |
| `demo_axi4_lite_target_slave` | 643 | 577 |
| `altsource_probe` (the JTAG instance, only with `ENABLE_ISSP`) | 70 | 53 |
| `hex7seg` ×6 | 54 | 0 |
| `key_debounce` | 28 | 21 |

The core's README lists synthesis results as *"Not measured"* — the numbers in
bold above are the first measurement, at `NUM_RULES = 8`, and cover the core
alone rather than the demo around it.

> The core figure moved from 1,869 to 1,908 LEs when the JTAG source filter and
> `done_count` were added. **The core's RTL did not change.** Quartus optimises
> across entity boundaries, so logic on the boundary is attributed differently
> once the surrounding design changes. Expect a percent or two of movement in
> any per-entity figure for this reason; the register count, which is not
> subject to that, stayed at 768.

### Timing — 50 MHz, slow 1200 mV 85 °C model

| Metric | Value |
|---|---|
| Fmax | **60.01 MHz** |
| Setup slack | **+3.336 ns** |
| Hold slack | **+0.341 ns** |
| Total negative slack | 0.000 |

Timing closes, with about 20% margin over the board's 50 MHz oscillator.

The critical path is **inside the IP core**:

```
axi4_lite_firewall_top|captured_awaddr[1]  →  axi4_lite_firewall_top|wr_timeout_cnt[*]
```

That is the combinational rule lookup feeding the forward/reject decision that
gates the timeout counter — exactly what the core's README predicted:

> *"The combinational rule lookup scales with `NUM_RULES` and is the likeliest
> critical path; if it limits Fmax, registering that lookup with an extra
> pipeline stage is the standard fix."*

Confirmed, and now with a number attached. At `NUM_RULES = 8` on a `C7` MAX 10
it costs about 18% of margin at 50 MHz; a larger rule table or a faster clock is
where that pipeline stage starts to be needed.

---

## What is and isn't verified

| Item | Status |
|---|---|
| **All 16 scenarios on a physical DE10-Lite** | **Passing** — driven and read back over JTAG |
| Determinism over JTAG | **6/6 fresh-program runs** after the `src_stable` and `done_count` fixes |
| All 16 scenarios, board-level simulation | **Passing** under Questa 2024.1 and Verilator 5.020 |
| Display and LED decode | **Checked** against an independently written glyph table |
| Step mode, auto sweep, scenario selection | **Checked** by driving the pins |
| Synthesis for `10M50DAF484C7G` | **Clean**, 0 errors, `.sof` produced |
| Timing closure at 50 MHz | **Closed**, +3.336 ns setup slack |
| Core resource usage and Fmax | **Measured** — first numbers for this core |
| Driver ordering and bounded poll | **Checked** by host tests against a register model |
| Driver compiles for Nios II | **Checked** with the real toolchain and HAL headers |
| **Pin assignments** | **Verified** — diffed against the DE10-Lite Golden Top project on the System CD; all 71 match exactly |
| Nios II application linked and run | **Not verified** — needs a BSP from your own Platform Designer system |

---

## Files

```
example/de10_lite_rtl/
├── README.md                        This file
├── rtl/
│   ├── de10_lite_axi4_lite_firewall_demo.sv   Top level: pins, reset, display, watcher
│   ├── demo_sequencer.sv            Microcoded engine + the 16-scenario program
│   ├── demo_axi4_lite_master.sv      AXI4-Lite master used for both ports
│   ├── hex7seg.sv                   Seven-segment decode
│   └── key_debounce.sv              Button synchroniser and debouncer
├── tb/
│   └── de10_lite_axi4_lite_firewall_demo_tb.sv  Board-level self-checking testbench
├── simulation/
│   ├── questa/run_sim.tcl
│   └── verilator/run_sim.sh
└── quartus/
    ├── de10_lite_axi4_lite_firewall_demo.qpf  Project
    ├── de10_lite_axi4_lite_firewall_demo.qsf  Device, pins, source list
    └── de10_lite_axi4_lite_firewall_demo.sdc  Timing constraints
```

The protected peripheral is shared with the Nios II example and lives in
[`../common/`](../common/).
