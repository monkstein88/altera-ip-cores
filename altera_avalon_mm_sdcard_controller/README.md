# Avalon-MM SD Card Controller (SPI) — Quartus / Platform Designer IP core

An SD card controller in **SPI mode**, packaged as a Platform Designer
component and driven by a Nios II over Avalon-MM. It does the SPI link layer in
hardware — framing, CRC7 and CRC16, tokens, bus timing, multi-block streaming,
busy polling and DMA into system memory — and leaves the card protocol to a HAL
driver the BSP picks up by itself.

**Catalog name:** *Avalon-MM SD Card Controller (SPI)* · v1.0 ·
*Memory Interfaces and Controllers / Custom*

> **Status: simulation only. This core has never been on a board.**
>
> It passes 91 self-checking assertions across three testbenches against a
> behavioural SD card model — with the full-core suite run in five
> configurations — plus bound SVA assertions proven live by fault injection,
> 22 checks on the Platform Designer component, and the HAL driver itself run
> against the RTL: 97 checks, in four builds. None of that is a substitute for
> hardware, and the DE10-Lite this repository's other examples target has no
> microSD socket — see
> [Verification status](#verification-status--what-is-and-is-not-proven).

---

## What it does

| | |
| --- | --- |
| **Card interface** | SPI mode (CPOL=0, CPHA=0), 4 wires, no tristates |
| **Commands** | Any; the hardware frames and CRCs them, software chooses them |
| **Data** | Single and multi-block, both directions, streamed in hardware |
| **CRC** | CRC7 on every command, CRC16 on every data block, computed during the transfer |
| **DMA** | Optional Avalon-MM master, bursting, straight into system memory |
| **Measured throughput** | **98.1% of SPI line rate** — 3.07 MB/s of a possible 3.125 at 25 MHz |
| **Software** | Nios II HAL driver, found automatically by the BSP: identifies the card on first use, notices card changes, retries CRC errors. FatFs disk I/O layer alongside |

### What it is not

**It is not native SD mode.** SPI is single-bit and caps out around 3.1 MB/s at
25 MHz, or 6.25 MB/s at 50 MHz if the card and wiring allow it. Native 4-bit
High Speed would be 25 MB/s. That ceiling is a property of the protocol, not of
this design, and nothing in the RTL moves it.

The internal boundary between the sequencer and the PHY is drawn so a native
PHY could be dropped in later without disturbing the FIFO, DMA, CSR or driver
above it — but no native PHY exists today.

UHS-I (SDR50/SDR104/DDR50) is out of reach on this class of hardware regardless:
it needs a 1.8 V signalling switch after CMD11, and the target is 3.3 V I/O.

---

## The design decision that matters: the shifter must never stall

SPI mode gives you about 3.1 MB/s and no amount of design skill changes that.
What *is* in the design's gift is how much of it you actually reach — and the
gap between a careless implementation and a careful one is large. Typical
software-driven SPI SD drivers manage 30–60% of line rate.

Everything structural in this core serves one goal:

| Mechanism | What it costs to skip |
| --- | --- |
| Continuous shifting, **no idle clock between bytes** | 1–2 clocks per byte — up to 25% |
| Multi-block streaming in hardware (CMD18/CMD25) | The card's access latency, paid per block instead of per transfer |
| Hardware busy polling, **pre-emptive** | A whole card programming time per block |
| CRC computed byte-by-byte during the transfer | A second pass over every block |
| FIFO + DMA | Not throughput — CPU time, and immunity to interrupt latency |

The one that is least obvious is the **pre-emptive busy check**. The naive write
loop sends a block, then waits for the card to finish programming. The card is
then idle while the host prepares the next one. This sequencer instead waits for
busy to clear *immediately before* the next packet and not at all after the
previous one, so the card's programming time overlaps with the host's
preparation and with the DMA refilling the buffer.

**How much that is worth has not been demonstrated.** This section used to say it
was "most of the difference between the card's rate and the bus's" on a
multi-block write. Measured against the card model with a realistic programming
time, streaming four blocks is **1.01×** faster than four single-block writes —
in SPI clocks and in elapsed time, in all five configurations. The saving is
exactly the framing of the three commands the stream avoids. The programming time
is paid once per block on either path, and both paths use the pre-emptive check,
so the RTL has no variant to compare it against. Whatever the real gain is, it
comes from effects the model does not simulate — see
[what is and is not proven](#verification-status--what-is-and-is-not-proven).

### Eight clocks per byte is a measured property, not an aspiration

The shifter's unit testbench counts SPI clocks at the pin and requires **exactly
8.00 per byte** at every divisor, including clk/2 where two system clocks per
bit leaves no slack at all.

This is not a rounding target. A shifter that inserts one idle clock at each
byte boundary transfers every byte correctly, passes every functional test, and
runs at 8/9 of the rate — 89% instead of 99% over a 512-byte block. Nothing
except a cycle count catches it, which is why the count is an assertion.

---

## Architecture

```
        csr (Avalon-MM agent)                    m0 (Avalon-MM host)
              |                                          |
        +-----v------+                            +------v------+
        |    regs    |                            |     dma     |
        | CSR, IRQ,  |                            | burst r/w   |
        | PIO window |                            +------+------+
        +-----+------+                                   |
              |  command / config                        | 32-bit words
              |                                   +------v------+
        +-----v---------------------------+       |    fifo     |
        |             seq                 |<----->| byte <-> word|
        |  command framing, response      |bytes  +-------------+
        |  capture, multi-block loop,     |
        |  tokens, pre-emptive busy       |
        +-----+---------------------------+
              |  byte in / byte out
        +-----v------+       +----------+
        |  spi_phy   |------>|   crc    |  CRC7 on commands,
        | continuous |       | byte-wise|  CRC16 on data blocks
        |  shifter   |       +----------+
        +-----+------+
              |
        +-----v------+
        |   clkgen   |  clk / (2 x CLKDIV), CPOL=0
        +-----+------+
              |
         sd_clk / mosi / miso / cs_n
```

Nine RTL files, 3439 lines, one per box plus the package and the top level.
Single clock domain throughout — no PLL, no CDC, nothing that behaves
differently in simulation than on hardware.

### Why the CRCs are byte-wise and not bit-serial

A bit-serial CRC tapped off the shifter is the obvious structure and it is
subtly wrong. SPI transmit and receive are offset by half a bit — data is driven
on the falling edge and captured on the rising one — so a byte is *received* one
rising edge before its eighth falling edge has driven the last transmitted bit.
A transmit CRC fed from falling edges and windowed by a state that changes on
the receive tick consumes only seven of the eight bits of the final byte of a
block.

The result is a CRC16 that is wrong in exactly one block per transfer, on the
last byte. Feeding whole bytes at the point the sequencer knows they are payload
removes the coupling entirely, and costs eight unrolled XOR stages at one byte
per eight SPI clocks — which is nothing.

---

## Register map (`csr`, byte offsets)

The port is word-addressed in hardware; the interconnect converts and software
sees byte offsets. Both are in `inc/altera_avalon_mm_sdcard_controller_regs.h`.

| Offset | Name | Access | Purpose |
| --- | --- | --- | --- |
| 0x00 | `CTRL` | RW | Enable, CS override, CRC enable, DMA enable, clock free-run, soft reset |
| 0x04 | `STATUS` | RO | Busy flags, FIFO level, card present / write-protected |
| 0x08 | `IRQ_ENABLE` | RW | Interrupt mask, same layout as `IRQ_STATUS` |
| 0x0C | `IRQ_STATUS` | RW1C | Sticky completion and error events |
| 0x10 | `CLKDIV` | RW | SPI clock divider and MISO sample delay |
| 0x14 | `TIMEOUT` | RW | Bound on every wait, in `clk` cycles |
| 0x18 | `CMD_ARG` | RW | 32-bit command argument |
| 0x1C | `CMD` | RW | Index, response type, data phase; **writing launches it** |
| 0x20 | `RESP0` | RO | R1 in [7:0] |
| 0x24 | `RESP1` | RO | The 32-bit trailer of R3 / R7 |
| 0x28 | `BLK_SIZE` | RW | Bytes per block (512 for SDHC/SDXC) |
| 0x2C | `BLK_COUNT` | RW | Blocks in this transfer |
| 0x30 | `DMA_ADDR` | RW | System byte address, word-aligned |
| 0x34 | `DMA_CTRL` | RW | Transfer mode |
| 0x38 | `DATA` | RW | PIO window, used when the DMA is disabled |
| 0x3C | `ERR_INFO` | RO | Last data-response token, last R1, data error token, failing phase |
| 0x40 | `CORE_INFO` | RO | Version and build-time configuration |

**`CMD` writes are ignored while `STATUS.CMD_BUSY` is set.** That is deliberate —
a second command must not corrupt a transfer in flight — but it means software
that writes without checking loses the command silently. Polling afterwards does
not catch it either: busy is already clear, so the poll returns immediately for
a command that never happened. The HAL driver waits for idle before every write.

**A `DATA` access the buffer cannot serve is now reported.** A write with the
buffer full, or a read with it empty, is refused — which is the only correct
thing to do, since there is no room for the word or no word to give. It used to
be refused *silently*, so the only evidence was wrong bytes at the far end of
the transfer. `IRQ_STATUS.ERR_PIO` (bit 18) says it happened. This was the one
hazard in the map with no error bit; the analogous case, a `CMD` write while
busy, is at least documented above.

**Bits 16 and 17 are events, not errors.** The error mask is bits 8–15 and 18,
deliberately not 8–17. Including the card-detect bits made `STATUS.ERROR`
assert because a card was fitted — from the first cycle after reset, since an
already-present card reads as an insertion — and made the driver reset the data
path on a card event.

**One interrupt mask, not two.** `IRQ_STATUS` records every event
unconditionally and `IRQ_ENABLE` gates only the pin, so polling always works.
SDHCI splits this into separate Status Enable and Signal Enable registers; here
that would add a second mask and a class of bug where software polls a bit that
can never set.

---

## Parameters

| Parameter | Default | Range | Notes |
| --- | --- | --- | --- |
| `FIFO_DEPTH_BYTES` | 1024 | 512–8192 | 1024 holds two blocks, so one is on the wire while the other moves to memory |
| `M0_BURST_WIDTH` | 8 | 1–9 | 2^(N−1) beats; 8 = 128 = one 512-byte block. **1 is supported, not degraded** |
| `CLKDIV_WIDTH` | 8 | 4–16 | SPI clock is clk/(2·CLKDIV), set at run time |
| `TIMEOUT_WIDTH` | 26 | 16–32 | 0.67 s at 100 MHz; covers the spec's 250 ms write-busy limit |
| `MAX_BLOCK_BYTES` | 512 | 16–512 | **512 is the spec maximum**, not a convention (§7.2.3) |
| `CSR_ADDR_WIDTH` | 5 | 5–8 | In words; the map occupies 17 |
| `ADDR_WIDTH` | 32 | 16–32 | `m0` byte address width |
| `USE_DMA` | 1 | 0/1 | Off removes `m0` entirely; costs 10–20% of a Nios II/f, no throughput |
| `USE_CARD_DETECT` | 1 | 0/1 | Adds `cd_n` / `wp_n` and the insert/remove interrupts |
| `USE_CRC` | 1 | 0/1 | Bring-up aid only; the CRC is free |

### The one runtime constraint worth knowing before you pick a clock rate

`CLKDIV[18:16]` is a MISO **sample delay**, for absorbing round-trip delay on
long wiring. It is bounded:

```
SAMPLE_DLY <= CLKDIV - 2
```

The SPI half-period is `CLKDIV` system clocks wide and the nominal capture point
already sits one clock inside it, so a larger delay walks the sample onto the
*next* bit and shifts every byte of the transfer. The failure is total and
silent — the bus looks alive, the byte count is right, every byte is wrong.

**At `CLKDIV` 1 and 2 the only legal delay is zero.** In other words, at 50 MHz
there is no timing margin to trade at all, which is a reason to prefer 25 MHz on
anything but a properly laid out socket. The specification is no help here:
§7.5, *SPI Bus Timing Diagrams*, is blank in the Simplified Specification.

---

## Pin connections

SPI mode uses **no bidirectional signals**, which is one of its few genuine
advantages over native SD mode: no `inout`, no in/out/oe triplets, no IO buffer
in the top level, and nothing that behaves differently in simulation.

| Conduit signal | Direction | microSD pin | SD-mode name |
| --- | --- | --- | --- |
| `sd_clk` | out | 5 | CLK |
| `sd_mosi` | out | 2 | CMD |
| `sd_miso` | in | 7 | DAT0 |
| `sd_cs_n` | out | 1 | DAT3 |
| `sd_cd_n` | in | socket switch | — |
| `sd_wp_n` | in | socket switch | — |

Pins 8 and 9 (DAT1, DAT2) are unused in SPI mode and should be pulled high at
the board, as should MISO. Getting that wrong produces a card that never
responds, which is indistinguishable from a dead core.

---

## Software

Adding the component to a Platform Designer system is the whole integration
step. `altera_avalon_mm_sdcard_controller_sw.tcl` sets `auto_initialize`, so the
BSP constructs every instance in `alt_sys_init.c` and runs `alt_sdcard_init()`
before `main()`: base address and interrupt from `system.h`, a version check
against `CORE_INFO`, and the ISR registered.

**What auto-initialisation deliberately does not do is identify the card.**
Identification takes hundreds of milliseconds — the specification allows a full
second for ACMD41 alone — it can fail for reasons the application needs to know
about, and there may be no card in the socket. Doing it before `main()` would
produce an application that cannot boot without a card present.

So the block calls do it themselves, the first time they need to, and the
shortest correct program is a read:

```c
#include "altera_avalon_mm_sdcard_controller.h"

extern alt_sdcard_dev sdcard;      /* from alt_sys_init.c */

alt_u32 buf[128];                  /* one 512-byte block */

int r = alt_sdcard_read_blocks(&sdcard, 0, buf, 1);
```

`block` is a 512-byte block number in both directions. The driver converts to a
byte address for standard-capacity cards, which is the entire reason a caller
does not have to know which kind of card is fitted. `alt_sdcard_probe()`
identifies the card explicitly, for an application that wants that — and its
failure — at a moment of its own choosing.

| Function | |
| --- | --- |
| `alt_sdcard_read_blocks`, `alt_sdcard_write_blocks` | Block access, identifying the card first if none is |
| `alt_sdcard_probe` | Identify the card now |
| `alt_sdcard_check` | Has the socket changed? Reads the switch and the latched events; sends nothing |
| `alt_sdcard_poll` | `alt_sdcard_check`, then CMD13: is the card still answering? |
| `alt_sdcard_generation` | Counts identifications, so it changes whenever the card behind the block calls might have |
| `alt_sdcard_command` | Any command; `ALT_SDCARD_RESP_AUTO` takes the response format from the index |
| `alt_sdcard_block_count`, `alt_sdcard_present`, `alt_sdcard_write_protected` | What they say |
| `alt_sdcard_reset_datapath` | Clear a wedged data path without losing the card's identification |
| `alt_sdcard_set_event_handler` | A callback from the ISR; installing one enables the card-detect interrupts |
| `alt_sdcard_instance` | The n-th controller, for code that is not handed a device |

### Card changes

A card can be pulled and another fitted between any two calls, and the new one
may be a different capacity class — which changes the unit a block number is
sent in. So the driver never carries an identification across a change it can
see.

With a card-detect switch, the switch and the latched `CARD_INSERT` and
`CARD_REMOVE` events are checked at the start of every call. The events are what
catch a fast swap, out and back in between two calls, which the switch alone
reads as "present" both times. Without a switch there is nothing to read, but a
card inserted behind the driver's back is still in SD mode and cannot answer: it
shows up as a timeout, and a card that times out is forgotten.

The call that finds a change fails — `ALT_SDCARD_ERR_CHANGED`, or
`ALT_SDCARD_ERR_NO_CARD` — and the next call identifies whatever is there.
Failing once is deliberate. A caller holding anything it learned from the old
card, a filesystem's allocation table for one, must not have its next write land
on the new card.

### Retries, and what is not retried

A CRC error means the link corrupted something, not that the card refused. A
command whose CRC fails is not executed, a read can simply be repeated, and a
written block the card rejected on CRC was never programmed. Those are retried
inside the call, `retries` times — 2 by default. Nothing else is: a timeout, an
error the card reported, or a write it refused for any other reason goes back to
the caller at once.

### Buffers

Any buffer works. With the DMA, a word-aligned one moves in a single multi-block
stream; a misaligned one, which the DMA cannot address, goes a block at a time
through a bounce buffer on the stack — correct, and slower. A transfer longer
than `BLK_COUNT`'s 16 bits is issued in pieces, and an address past the end of
the card is refused rather than sent, since on a standard-capacity card the byte
address would otherwise wrap to near block 0.

### FatFs

[`software/fatfs/diskio_altera_sdcard.c`](software/fatfs/diskio_altera_sdcard.c)
is FatFs's disk I/O layer — `disk_status`, `disk_initialize`, `disk_read`,
`disk_write` and `disk_ioctl` — on top of the block API. Add it to the
application in place of the template `diskio.c` FatFs ships. FatFs itself is not
included, and the BSP does not build the file, so a system without FatFs never
needs its headers.

What it adds is one rule: **a mounted volume is tied to the card it was mounted
from.** The block API identifies a new card by itself, which is convenient for a
program reading blocks and dangerous under a filesystem holding the old card's
allocation table in memory. So the glue refuses transfers with `RES_NOTRDY` on
anything but the identification `disk_initialize` accepted, and reports
`STA_NOINIT` after a change, which makes FatFs drop the volume and mount it
afresh. On a socket without a switch, `disk_status` asks the card with CMD13:
FatFs answers enough from its cache that waiting for a transfer to fail is not
enough.

### What is hardware and what is software

The hardware owns the link layer because it is timing-critical, repetitive and
stable across spec revisions. The driver owns the protocol — the identification
sequence, v1.x versus v2.00, byte versus block addressing, CSD parsing, the
ACMD41 retry policy — because that is where every SD implementation accumulates
its card-specific workarounds, and a workaround in a driver is a recompile
rather than a new bitstream.

---

## Verification

Everything here runs on open-source tools. Verilator 5.050 or newer.

```
./verification/run_all.sh                # everything, roll-up result
```

or individually:

```
simulation/verilator/run_sim.sh          # all three testbenches, and the driver
simulation/verilator/run_sim.sh phy      # just the shifter
simulation/verilator/run_sim.sh driver   # just the HAL driver against the RTL
tclsh verification/check_hw_tcl.tcl      # the Platform Designer component
./verification/check_driver_builds.sh    # the HAL driver and FatFs glue build
./verification/check_assertions_fire.sh  # prove the assertions can fail
./verification/check_figures.sh          # every figure matches its generator
python3 doc/tools/check_facts.py         # every number in these documents
python3 verification/models/crc_reference.py
```

Four of those need **no simulator at all**, which is the point of them: they
catch the dull mechanical faults — a renamed parameter, a port added to an
interface that does not exist, a typo in the driver, a diagram or a figure that no
longer matches the RTL — which otherwise survive until someone with the
full Quartus toolchain tries to build a project.

| Suite | Checks | What it proves |
| --- | --- | --- |
| `phy` | 18 | Exactly 8.00 SPI clocks per byte at every divisor; bit-exact loopback; the `SAMPLE_DLY` bound; every received byte paired with the byte sent alongside it |
| `fifo` | 5 | Byte↔word round trip both directions, little-endian order, partial-word flush |
| `core` | 68 | Identification, single and multi-block both directions, CSD/CID, every card-reported failure, `ERR_INFO` contents, every per-state timeout escape, soft reset from inside a transfer, the response window at five clock settings, read throughput floor, the multi-block write saving, Avalon conformance |
| `driver` | 97 | The HAL driver itself against the RTL, in four builds and on a slow processor: identification on first use, both capacity classes, CRC retries, card removal and swaps with and without a switch, interrupts, misaligned buffers, transfer splitting, the FatFs glue |
| `check_hw_tcl.tcl` | 22 | The component executes; parameters and ports exist; validation rejects exactly the bad configurations |
| `check_driver_builds.sh` | 4 | The driver compiles clean under `-Wall -Wextra`; CSD capacity arithmetic for both structure versions; the FatFs glue compiles clean with 32- and 64-bit sector numbers; the register header stands alone |
| `check_assertions_fire.sh` | 5 faults | Each injected into a scratch copy and required to be caught by the assertion meant to catch it |
| `check_figures.sh` | 19 files | The 9 figures and their generator inputs, each re-rendered and compared byte for byte, because a stale picture is worse than a missing one. Needs `graphviz` for the block diagrams and Node plus a recorded `wave.vcd` for the timing figures; short of those it reports **INCOMPLETE** with a count, rather than passing on what it could not look at |
| `check_facts.py` | 261 | Every register offset, parameter default, line count and measured figure in these documents, re-derived from the RTL |
| `check_synthesis.sh` | 5 configs | The RTL through Quartus for the DE10-Lite part in the default, `tight`, `big`, `nodma` and `noburst` configurations: each synthesises, fits and meets a 100 MHz clock, holds area and Fmax to a budget, and puts **exactly** `FIFO_DEPTH_BYTES` × 8 bits in a memory block — so a buffer that slips back into registers fails by name rather than by growing |
| `check_qsys.sh` | 7 | The component in **real** Platform Designer: it loads, its interfaces are the expected six, `USE_DMA=0` genuinely removes `m0`, and a system containing it generates |
| lint | 10 configs | `-Wall` clean across every parameter that changes what is built |

**The full-core suite runs five times**, and the exit status is the AND across
all of them:

| Configuration | What only it reaches |
| --- | --- |
| `dma` | the reference case |
| `pio` | no master; software moves every word through `DATA` on a deadline |
| `sdsc` | **byte** addressing — the identity on an SDHC card, so untested anywhere else |
| `tight` | one block of buffer, so the data path refills mid-transfer |
| `noburst` | single-beat Avalon transactions throughout |

Adding that sweep was not bookkeeping. The first run of the four non-default
configurations found a defect the DMA case cannot reach: neither data-streaming
state checked the timeout, so a data phase starved of data hung the core with no
recovery short of a soft reset. With a master attached that cannot happen — the
DMA always supplies. With software feeding the buffer it can, and did.

### What the card model does that matters

`tb/spi_card_model.sv` is written to the specification rather than to the DUT.
It implements CMD0/8/9/10/12/13/16/17/18/24/25/55/58/59 and ACMD41, the R1/R1b/
R2/R3/R7 formats, `N_CR` response latency, all four token types, CRC7 checking
and CRC16 generation, busy on MISO, and both capacity classes.

It is also a card that can be **removed**. It ignores everything until it has
had its 74 power-up clocks, stays in SD mode — silent on MISO — until CMD0
selects SPI, and accepts nothing but identification commands until ACMD41 has
finished. Pulling it is a power cycle that keeps its flash. A model that skipped
those would let a driver pass that never sent the power-up clocks, and let a card
swapped in behind a driver's back look ready for block access.

It also **misbehaves on demand**: no response, an R1 with the CRC-error or
illegal-command bit set, a data error token instead of a block, a block with a
corrupt CRC16, a write rejected with either error token, and busy that outlasts
any timeout. A card model that only ever works correctly proves the DUT handles
the happy path, which was never the part in doubt.

One behaviour is modelled *unconditionally* rather than as an injected fault:
§7.3.2's rule that when R1 reports Illegal Command or Command CRC Error, the
card sends **only that byte** — the 32-bit trailer of an R3 or R7 never arrives.
A host that reads it anyway desynchronises the bus for every subsequent command,
and this is not an exotic path: it is exactly what a v1.x card does to CMD8,
which is how a driver detects card version in the first place. The regression
checks it by issuing a further command afterwards and confirming it still works.

### Running the driver against the RTL

Every suite above drives the registers from SystemVerilog written to do what the
driver does. [`tb/driver/`](tb/driver/driver_tests.c) runs the driver itself —
`HAL/src` compiled with gcc, unmodified, and linked into the Verilator model —
with a few hundred lines of C++ standing in for the processor: every `IORD` and
`IOWR` is one Avalon-MM transfer on `csr`, and nothing else moves simulated
time. The socket holds two cards, one of each capacity class, that can be
swapped between calls or in the middle of one; with the DMA, the master reads
and writes the driver's own buffers. It runs under Verilator only.

It runs in four builds — with and without the DMA, with and without a
card-detect switch — and again with a slow processor. Its first run found two
faults that every suite above had passed:

- **The driver's power-up wait was a CPU loop.** 200 000 empty iterations: a few
  milliseconds on a Nios II/f, which is ample at 400 kHz, but a count of loop
  iterations is not a count of clocks. In the harness, where a loop takes no
  time, it gave the card none, and identification failed on every card. The
  wait is now counted in bus transfers, each of which spans at least one clock
  cycle whatever the processor.
- **The sequencer opened the response window a byte early at 25 MHz.** It
  counted six receive ticks after a command and took them for the six frame
  bytes. At `CLKDIV` 1 and 2, and at large sample delays, the first belongs to a
  byte of idle fill instead, so the window opened while the CRC byte was still
  going out. On an idle card that byte is `0xFF`, which is why nothing noticed.
  It cost a byte of the `N_CR` allowance, so a card answering at the
  specification's maximum of 8 timed out; and after an auto CMD12 the card is
  still streaming, so a data byte was read as the response — one with bit 7
  clear and Illegal Command or CRC Error set failed a good read. The stuff byte
  after CMD12, which the design record described as handled, had only passed
  because the card model sent `0xFF` there.

  The shifter now tags each received byte with whether the byte sent alongside
  it was queued or fill, the sequencer counts only queued ones, and CMD12's stuff
  byte is dropped unread. The core suite checks `N_CR` 8 and 9, and a CMD12
  against a card streaming R1-shaped data, at five clock settings; the card
  model carries data into the stuff byte; and a new assertion, proven by fault
  injection, requires the whole frame to have left the prefetch before the
  window opens.

Every behaviour the driver and the FatFs glue gained was then checked the other
way round: removed from the source one at a time — 38 mutations, each run in all
four builds — to confirm that some check fails. Twelve went unnoticed at first.
Three turned out to be code no card that follows the specification can reach,
and were removed rather than kept on trust. One, reading R2 as R1, cannot be seen
in this core at all, so the check now aims at the R3 entry, whose mistake can.
The rest had no test that could see them and have one now — one needed the
harness to swap cards on a chosen register write, in the middle of a single
call. The sweep now catches all 38.

That work led to a last RTL change. `RESP0` and `RESP1` are cleared when a
command starts, where they used to keep the previous command's response — which
is how a response read in the wrong format could pass unnoticed.

The FatFs glue is linked in too, against stand-ins for FatFs's two headers, so
the suite needs no copy of FatFs. It was also run once against **FatFs R0.15
itself**, outside the repository, in all four builds: format, mount, write,
swap cards under an open file, format the other card, swap back and read the
first file. That run found a hole in the glue's first version — on a socket
without a switch it waited for a transfer to fail, and FatFs answered a
directory lookup from its cache about a card it had never read. That run is not
repeatable from this repository.

### Measured throughput

| | |
| --- | --- |
| Multi-block read, 4 × 512 bytes | 2048 bytes |
| SPI clocks consumed | 16 696 |
| Achieved | **0.1227 bytes per SPI clock** |
| Ceiling (8 clocks/byte) | 0.1250 |
| **Fraction of line rate** | **98.1%** |

At 25 MHz that is **3.07 MB/s** against a 3.125 MB/s ceiling. The 1.9%
shortfall is protocol framing — one start token and two CRC bytes per block,
plus the command and its response — not controller stalls.

The same measurement on a shifter that idles one clock per byte would read
0.111 bytes/clock, and every functional check would still pass.

### What Questa added, and what it found

Everything above runs on open source tools. `simulation/questa/run_sim.tcl`
runs the same seven configurations under Questa for the two things no other
flow here provides: coverage, and **non-vacuity** — how many times each
assertion passed for a real reason rather than because its antecedent never
held.

Running it for the first time was not a formality. It found four faults, and
the most serious was in the flow itself:

- **None of the assertions had ever run.** The binds sit at compilation-unit
  scope, so without `-mfcu -cuname` the four SVA modules compiled, `vlog`
  warned once, and none of them elaborated. Seven configurations passed
  reporting no assertion failures because there were no assertions, and the
  assertion report was zero bytes. The verdict now requires every assertion by
  name before it may report a pass — absence of a failure is not evidence.
- **The RTL would not compile at all.** A signal was consumed in a port
  connection fifty lines before it was declared, which makes it an implicit
  one-bit net and the real declaration a duplicate. Verilator resolved it to
  the full eight bits and linted clean under `-Wall`.
- **One assertion could never fail.** `a_no_push_when_full` had a consequent of
  literal `1'b1` — its name promised it caught a push into a full buffer and
  its body permitted exactly that. Repaired, it passes for a real reason and
  the property does hold.
- **The read side of the memory backpressure was never exercised.** A read
  burst presents its command for exactly one accepted cycle, and the memory
  model only stalled *after* accepting one, so `waitrequest` was never asserted
  while a read was outstanding. Its write-side twin passed 254 times and hid
  it. The model now stalls the first beat of every command.

What it left open has since been worked through. The sequencer reaches **all 20
of its states and 40 of its 58 transitions**, and the 18 that remain are
accounted for rather than merely unreached:

- **Sixteen are one statement.** `if (srst) state <= S_IDLE` is counted once per
  source state. Three of them are exercised, taking a reset mid-command,
  mid-read and mid-write, which is where a driver actually uses one and where
  the core has to come back usable. Reaching the other thirteen means thirteen
  precisely-timed resets to exercise a single line, which is coverage
  arithmetic rather than verification.
- **Two are defensive and structurally unreachable.** The timeouts in
  `S_RD_DATA` and `S_WR_CRC` cannot fire as the sequencer is wired. A receive
  state free-runs the shifter, so a byte lands every eight SPI clocks and the
  no-progress counter is cleared before it can expire; and the CRC state's two
  bytes come from a register with no buffer dependency, so it cannot be starved
  at all. Both are kept, and both now say so at the branch, because the
  guarantee each rests on lives in a different module.

The four timeout escapes that **are** reachable are now tested, each checked for
the `phase_e` it reports: busy before a command, busy between the blocks of a
multi-block write, an R1b whose busy never lifts, and a write data phase starved
of data. That last one is the sequel to a defect this core already had — the
configuration sweep once found that neither data-streaming state checked its
timeout at all — and until now nothing exercised the fix.

### Verification status — what is and is not proven

**Proven in simulation:** the SPI link layer against a specification-derived
card model, including every failure the card can report; the Avalon-MM agent and
host against a memory model with wait states and read latency; the register map;
the interrupt behaviour; the throughput; the component description; the HAL
driver running against the RTL, with and without the DMA and a card-detect
switch, through card removals and swaps; and the FatFs glue as FatFs calls it.

**Proven in Quartus**, on the `10M50DAF484C7G` the DE10-Lite carries, with
Quartus Prime 18.1 Standard — the release the hardware examples will be built
with:

| | |
| --- | --- |
| Logic cells | 1715 / 49 760 — **3.4%** |
| Registers | 898 |
| Memory | one M9K, 8192 bits |
| Fmax | **108.41 MHz**, slow 85 °C corner |
| Slack at 100 MHz | **+0.776 ns** — it meets the clock |

`verification/check_synthesis.sh` runs Analysis & Synthesis, the Fitter and the
Timing Analyzer across five configurations and holds each to a budget, so a
change that makes the core bigger or slower fails there rather than being noticed
whenever somebody next looks:

| Configuration | Logic cells | Memory bits | Fmax |
| --- | --- | --- | --- |
| default, 1 KB buffer | 1715 | 8 192 | 108.41 MHz |
| `FIFO_DEPTH_BYTES=512` | 1712 | 4 096 | 117.03 MHz |
| `FIFO_DEPTH_BYTES=8192` | 1751 | 65 536 | 103.58 MHz |
| `USE_DMA=0` | 1518 | 8 192 | 119.80 MHz |
| `M0_BURST_WIDTH=1` | 1700 | 8 192 | 117.72 MHz |

The fixes described under
[Running the driver against the RTL](#running-the-driver-against-the-rtl) cost
13 logic cells and 10 registers in the default build: the same release measures
the previous RTL at 1702 cells, 888 registers and 112.01 MHz. Fmax moved by
between −4 and +2 MHz across the five builds, in both directions, for changes of
a dozen cells. That is the fitter's placement rather than the logic, and it is
why the check holds a floor rather than a figure. The figures this table carried
before were Quartus 25.1 Standard's, which for the same RTL are a few MHz
higher.

The 8 KB row is worth a second look. `FIFO_DEPTH_BYTES` has always been
documented as accepting 512 to 8192, and until the buffer was moved into a memory
block the top of that range **did not fit on the part** — the fitter needed
66 430 registers against 49 760 available. It is now 36 logic cells more than the
default. `verification/check_qsys.sh` loads the component into real Platform
Designer, checks the elaboration callback genuinely removes `m0`, and generates
a system from it.

**`CLKDIV = 1` is settled.** With Fmax at 108.41 MHz the core meets a 100 MHz
system clock, so clk/2 — 50 MHz SPI — is reachable on this part. The design
record's fallback of restricting `CLKDIV >= 2` is not needed.

**Not proven:**

- **Nothing has run on a board, and no real card has been touched.** Synthesis,
  fitting and timing are all closed on the target part, but that is not the same
  as a working transfer. The DE10-Lite has no microSD socket, so a demonstration
  needs a breakout on the GPIO or Arduino header and its own pinout. The card
  model is written to the specification, and real cards deviate from it — which
  is why the protocol layer is in software.
- **The write path's advantage is unproven.** The card model now holds busy for
  a settable programming time, and with 256 byte-times of it — about 82 µs at
  25 MHz, the low end of a real card's 1–4 ms — four blocks streamed take 22 824
  SPI clocks against 23 056 as four single-block writes: **1.01×**. The 232-clock
  saving is the three avoided command frames with their response latency, and
  nothing else, because programming is paid per block either way.

  So the multi-block path and the pre-emptive busy check are justified by
  argument, not by measurement. The argument is that a real card has costs this
  model does not: per-transfer access and allocation time, which a stream pays
  once; and host preparation time slow enough for the pre-emptive check to
  overlap with, which a DMA that has the next block ready at once never provides.
  Published figures for real cards over SPI are 130–200 kB/s for single-block
  writes, an order of magnitude below the bus, so the room is there. Whether this
  design captures it needs a real card, and a variant of the RTL without the
  pre-emptive check to compare against.

---

## Layout

```
rtl/          nine SystemVerilog files, 3439 lines
tb/           card model, memory model, three testbenches, bound SVA,
              and driver/: the HAL driver run against the RTL
simulation/verilator/run_sim.sh
simulation/questa/run_sim.tcl   coverage and non-vacuity
verification/ hw.tcl checker, driver compile check, assertion fault
              injection, wave capture, design-time Python models
HAL/, inc/    Nios II driver and the standalone register header
software/     FatFs disk I/O glue - not built by the BSP
doc/          user guide, block diagrams, design specification, figures
*_hw.tcl      Platform Designer component
*_sw.tcl      BSP driver description
```

## Documentation

| Document | Markdown | PDF |
|---|---|---|
| User guide | [`doc/avalon_mm_sdcard_controller_user_guide.md`](doc/avalon_mm_sdcard_controller_user_guide.md) | [PDF](doc/avalon_mm_sdcard_controller_user_guide.pdf) |
| Block diagrams and descriptions | [`doc/avalon_mm_sdcard_controller_block_diagrams.md`](doc/avalon_mm_sdcard_controller_block_diagrams.md) | [PDF](doc/avalon_mm_sdcard_controller_block_diagrams.pdf) |
| Design record | [`doc/avalon_mm_sdcard_controller_design.md`](doc/avalon_mm_sdcard_controller_design.md) | — |

The design record is the *why*: each decision, what the specification requires,
and what is still open. The user guide is the *how*. The block-diagram document
carries the pictures — Graphviz for the block diagrams, WaveDrom for the
timing figures, and every one generated rather than drawn:

```bash
python3 doc/tools/diagrams/build_figures.py   # block diagrams, via Graphviz
./verification/capture.sh                     # record verification/wave.vcd
cd doc/tools/waveforms && npm install         # once, for WaveDrom
python3 doc/tools/waveforms/mkwaves.py        # timing figures, cut from the VCD
python3 doc/tools/build_pdf.py all            # typeset both documents
```

The timing figures come out of a real simulation, so they cannot drift away from
the RTL: change the design and either the figure changes with it, or `mkwaves.py`
fails saying which token or state it could no longer find. A hand-drawn timing
diagram just quietly becomes fiction, and SPI-mode SD is full of details — `N_CR`
is a range, the data-response token carries five bits of meaning in eight, CRC16
is seeded with zero and not 0xFFFF — that a plausible drawing gets wrong.

## Licence

MIT — see the repository's [`LICENSE`](../LICENSE).

The SD specifications this core is written against are the SD Association's and
are **not** included here. They are free to download from
[sdcard.org](https://www.sdcard.org/downloads/pls/), which is not the same as
free to redistribute. Every fact taken from them is cited by section number so
you can check it against your own copy.
