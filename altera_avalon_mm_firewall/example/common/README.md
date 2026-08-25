# Shared demo hardware

Hardware used by the DE10-Lite examples. It lives here rather than in either
one so there is a single copy to keep correct.

| File | What it is |
|---|---|
| `demo_target_slave.sv` | The peripheral the firewall protects: a burst-capable Avalon-MM scratchpad with injectable faults |
| `demo_target_slave_hw.tcl` | Platform Designer component wrapper for it, used by the Nios II example |

## Why a custom peripheral rather than an on-chip RAM

A demonstration of an *access-control* firewall could use any slave. A
demonstration of a **fault-isolation** firewall cannot: it needs a peripheral
that stops responding on command. An on-chip RAM always answers, which makes
the timeout, isolation and recovery scenarios — the half of the core that
matters most — unreachable.

It also has to **burst**. This core exists because its AXI4-Lite sibling could
not, so a demo peripheral that only accepted single accesses would leave the
whole point undemonstrated. `demo_target_slave` takes burst writes at one beat
per cycle and returns burst reads at one beat per cycle, with zero wait states,
which is what lets scenario 5 measure the core's throughput claim on silicon.

## Two failure modes, and why both exist

The firewall reports them through *different* `STATUS` bits, and that
distinction is the whole reason both are here:

| Mode | Behaviour | Firewall reports |
|---|---|---|
| `hang=1, hang_late=0` | `waitrequest` stuck high | `WR_CMD_STUCK` / `RD_CMD_STUCK` — the command was never accepted, so the core is left holding a command Avalon-MM forbids it to withdraw. Only `RECOVERY.UNBLOCK` may retract it |
| `hang=1, hang_late=1` | accepts the command, then goes silent | `WR_BUSY` / `RD_BUSY` — the peripheral owes beats or a write response forever, which is the case that makes an unbounded poll hang |

`W_DEAD` and `R_DEAD` are trap states with no exit but a reset. That is
deliberate and is the point being made: nothing the firewall does can revive a
wedged peripheral, which is why resetting it is step 4 of a software sequence
rather than something the core does for you.

## Two resets

`resetn` is the system reset. `soft_resetn` is the peripheral's own reset,
under software control — driven by the sequencer in the RTL example and by a
PIO in the Nios II example, in both cases exactly as a driver would. They are
ANDed internally.

They are separate because Platform Designer needs a genuine reset sink to tie
into the system reset network, so the software-controlled one cannot simply
*be* `resetn`. Either reset clears the scratchpad, which is what lets the
recovery scenarios distinguish "no stale write landed" (reads back 0) from "a
stale write landed" (reads back the orphaned data) with no ambiguity.

### `waitrequest` is held while the peripheral is in reset

This one is not decoration, and getting it wrong quietly destroys the two
recovery scenarios. A peripheral held in reset must not complete handshakes.
If `waitrequest` stays low while the state machine is held clear, a command the
firewall froze on the bus gets handshaked away and silently swallowed — so the
correct recovery order and the incorrect one produce *identical* results, both
reading back zero, and the hazard the sequence exists to avoid becomes
invisible.

That is not hypothetical: this model was written without the term, and
scenario F failed with exactly that symptom until it was added.

## Using the component

Add this directory to the Quartus IP search path, or pass it to
`qsys-script`/`qsys-generate` with `--search-path`. The example build scripts
do the latter, so neither depends on your global IP settings.
