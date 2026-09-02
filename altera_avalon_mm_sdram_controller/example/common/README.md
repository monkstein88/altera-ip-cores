# example/common

The parts of the demonstrations that are not about a particular board.

| File | What it is |
|---|---|
| `demo_sdram_seq.sv` | The eight test scenarios and their checker. An Avalon-MM traffic pattern generator with a pass/fail verdict, cycle counters and a watchdog |
| `demo_avl_mm_master.sv` | Turns the sequencer's command/response handshake into the controller's legacy `az_`/`za_` slave protocol |
| `key_debounce.sv` | Filters a mechanical button into a single-cycle pulse |
| `hex7seg.sv` | Seven-segment decoder. Used by the DE10-Lite demonstrations; the DE0-Nano has no digits |

## Why these are shared rather than copied

There are four demonstrations - two boards, each with an RTL and a Nios II
version - and the scenarios are the same claim in all of them. A copy per board
would mean four places to fix a scenario, and four chances for them to drift
until "the DE0-Nano fails scenario 5" means something different from "the
DE10-Lite fails scenario 5".

The sequencer is 650 lines and carries the whole definition of what the
demonstrations test. It is the last thing that should be duplicated.

## What made them shareable

Two things had to be parameterised before this was possible, and both were
found by trying:

**`COL_BITS`.** The scenarios are defined in terms of the address decode - one
row, one bank, a row miss on every access - so they have to know where the
column ends and the bank begins. The DE10-Lite's IS42S16320D has a 10-bit
column and the DE0-Nano's IS42S16160B a 9-bit one, so `1024` and `2048` were
written out where `COL_WORDS` and `BANK_STRIDE` belonged. Scenario 3 sweeps one
row on both boards now; it just sweeps a different number of words.

**`ADDR_WIDTH`, properly.** It was already a parameter, but two things ignored
it. The address-bus walk stepped through powers of two up to 2^24 regardless,
which walks off the end of a 24-bit device. And `patt()` sliced `a[24:9]`,
which is not a legal slice of a 24-bit vector at all - Quartus rejects it and
Verilator quietly substitutes zero, so it simulated cleanly and would not
synthesise. Both now follow the width.
