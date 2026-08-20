# Shared demo hardware

Hardware used by **both** DE10-Lite examples. It lives here rather than in
either one so there is a single copy to keep correct.

| File | What it is |
|---|---|
| `demo_target_slave.sv` | The peripheral the firewall protects: an AXI4-Lite scratchpad with injectable faults |
| `demo_target_slave_hw.tcl` | Platform Designer component wrapper for it, used by the Nios II example |

## Why a custom peripheral rather than an on-chip RAM

A demonstration of an *access-control* firewall could use any slave. A
demonstration of a **fault-isolation** firewall cannot: it needs a peripheral
that stops responding on command. An on-chip RAM always answers, which makes
the timeout, isolation and recovery scenarios — the half of the core that
matters most — unreachable.

`demo_target_slave` has two failure modes, and the firewall reports them
through *different* `STATUS` bits. That distinction is the whole reason both
exist:

| Mode | Behaviour | Firewall reports |
|---|---|---|
| `hang=1, hang_late=0` | never raises `AWREADY`/`ARREADY` | `WR_CMD_STUCK` / `RD_CMD_STUCK` — the command was never accepted, so the core is left holding a `VALID` only `RECOVERY.UNBLOCK` can retract |
| `hang=1, hang_late=1` | accepts the command, then goes silent | `WR_RESP_BUSY` / `RD_RESP_BUSY` — the peripheral owes a response forever, which is the case that makes an unbounded poll hang |

`W_DEAD` and `R_DEAD` are trap states with no exit but a reset. That is
deliberate and is the point being made: nothing the firewall does can revive a
wedged peripheral, which is why v2.0 made resetting it step 4 of a software
sequence rather than something the core does for you.

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

## Using the component

Add this directory to the Quartus IP search path, or pass it to
`qsys-script`/`qsys-generate` with `--search-path`. Both example build scripts
do the latter, so neither depends on your global IP settings.
