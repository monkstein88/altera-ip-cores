# Avalon-MM SDRAM Controller

**Status: in progress — benchmark only, no controller yet.**

A from-scratch SDR SDRAM controller for Avalon-MM, intended to replace
[`altera_avalon_new_sdram_controller`](../altera_avalon_new_sdram_controller)
(Intel's, retired from the Quartus catalog and preserved in this repository).

Nothing here replaces it yet. What exists today is the measurement harness,
because the first honest step is to find out what the incumbent actually does.

## What the measurement found

Six access patterns against the incumbent, at 100 MHz on the DE10-Lite's
IS42S16320D. Full detail in [`benchmark/README.md`](benchmark/README.md).

| Pattern | MB/s | % of 200 MB/s peak |
|---|---|---|
| seq write / seq read | 194 | **97%** |
| seq read/write | 21.9 | 11% |
| same-row read/write | 21.9 | 11% |
| bank stride | 21.9 | 11% |
| random | 22.0 | 11% |

Two conclusions, and they point in opposite directions:

**Sequential streaming is finished.** 97% of the theoretical bus limit. The
remaining 3% is refresh. No controller can meaningfully beat this, and any that
claims to should be disbelieved.

**Everything else is 8.9× off the pace, and it is not row thrashing.** The
`same-row read/write` pattern never leaves one open row — no ACTIVATE, no
PRECHARGE between accesses, only the direction alternating — and it is exactly
as slow as fully random access. The incumbent's fast path requires
`rnw_match`, so every direction change is handled as a full row cycle. The
device datasheet says a turnaround inside an open row costs 0 cycles
(write→read) or 1 (read→write).

That is the gap this core is meant to close, and it is worth roughly 3–4× on
mixed CPU traffic — which is what a Nios II running real code generates.

## Planned design

| Feature | Incumbent | Planned |
|---|---|---|
| Open rows tracked | 1 | one per bank (4) |
| Read/write turnaround | full row cycle | 0–1 cycles, row stays open |
| ACTIVATE for the next access | after the current one retires | overlapped with the current burst (tRRD permitting) |
| Refresh | immediate, interrupts streaming | postponed to a burst boundary (JEDEC allows up to 8) |
| Timing parameters | ns, derived with `ceil` | same — plus **tRAS** and **tRRD**, which a per-bank design needs and a single-row design does not |
| Device support | parameterised | parameterised, with named device profiles and a validating `_hw.tcl` |

## Configurability

Timings are parameterised in **nanoseconds** and converted to cycles
internally with ceiling division, never below one cycle. Exposing cycle counts
would push that arithmetic onto every user, and a timing parameter rounded down
is silent data corruption rather than a clean failure.

The intent is that a device profile is a set of nanosecond constants, that
`_hw.tcl` validates a requested configuration (a CAS latency the part cannot
sustain at the requested clock, an address width too small for the geometry),
and that the regression sweeps several device profiles × clock rates rather
than testing one configuration and shipping N untested ones.

## Layout

```
altera_avalon_mm_sdram_controller/
└── benchmark/          the ruler - measures the incumbent and, later, this core
```

`rtl/`, `tb/`, `simulation/`, `doc/` and `example/` will follow the same shape
as the two firewall cores in this repository.
