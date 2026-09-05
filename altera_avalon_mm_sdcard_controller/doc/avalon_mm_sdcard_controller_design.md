# Avalon-MM SD Card Controller — design specification

**Status: design, nothing implemented.** This document is the contract the RTL,
the driver, the Platform Designer component and the documentation are all
written against. It is the first file in the core and the one `check_facts.py`
will eventually re-derive its numbers from.

Catalog name **Avalon-MM SD Card Controller (SPI)** · v1.0 ·
*Memory Interfaces and Controllers / Custom*.

Section references of the form §7.x are to the **SD Physical Layer Simplified
Specification, Version 4.10**; chapter 7 is SPI mode. §10 additionally refers to
the **SD Host Controller Simplified Specification, Version 4.20**. Avalon-MM
behaviour is cited against the **Avalon Interface Specifications**, version
18.1 — the release this repository builds and verifies with.

Neither document is included in this repository. Both are the SD Association's,
and free to download from [sdcard.org](https://www.sdcard.org/downloads/pls/),
which is not the same as free to redistribute. Only facts derived from them
appear here, cited by section number so you can check any of them against your
own copy.

---

## 1. Scope

An SD card controller packaged as a Platform Designer component, driven by a
Nios II/f over Avalon-MM, using **SPI mode** on the card.

It does the SPI **link layer** in hardware — bit shifting, CRC7 and CRC16,
tokens, clock generation, busy polling, multi-block streaming and DMA into
system memory. It does **not** do the card protocol: the identification
sequence, OCR/CID/CSD parsing, capacity and addressing mode, and the choice of
which command to send are all the HAL driver's job.

That line is drawn deliberately. The link layer is timing-critical, repetitive
and stable across spec revisions — exactly what hardware is good at. The
protocol layer is none of those things: it is full of card-specific quirks and
spec-version conditionals, and it is where every SD implementation accumulates
its workarounds. Putting it in a driver means a workaround is a recompile, not
a new bitstream.

### Not in scope

Native 1-bit and 4-bit SD mode. The internal boundary between the sequencer
and the PHY (§4) is drawn so a native PHY can be dropped in later without
disturbing the FIFO, DMA, CSR or driver above it, but no native PHY is being
written now.

UHS-I (SDR50/SDR104/DDR50) is out of reach on this class of hardware
regardless: it requires a 1.8 V signalling switch after CMD11, and the intended
target is 3.3 V MAX 10 I/O.

---

## 2. Performance envelope

SPI mode is single-bit and half the reason for this section is to be honest
about what that costs.

**Line rate.** SPI moves one bit per SPI clock. At 25 MHz — the rate cards are
specified to accept in SPI mode — that is 3.125 MB/s. At 50 MHz, if the card
and the wiring tolerate it, 6.25 MB/s. Native 4-bit High Speed would be
25 MB/s, so this core's ceiling is roughly **8× below** what the native path
could reach. No amount of design skill moves that number.

**What design skill does move** is how close you get to it. A typical
software-driven SPI SD driver achieves 30–60% of line rate, because it stops
the clock between bytes, re-issues a command per block, and polls busy from the
CPU. The target here is **>90%**, from four specific mechanisms:

| Mechanism | What it costs if you skip it |
| --- | --- |
| Continuous shifting, no inter-byte gap | 1–2 idle clocks per byte — up to 25% |
| Multi-block streaming (CMD18/CMD25) | The card's access latency, paid once per block instead of once per transfer |
| Hardware busy polling after write blocks | Up to 250 ms per block spent in a CPU poll loop |
| DMA with a ping-pong block buffer | CPU time, and immunity to interrupt latency — but *not* throughput; see below |
| **Pre-emptive** busy check, not post-wait | A whole card programming time per block, spent waiting for a card that was already finished |

### The memory side is not the bottleneck, and it is worth being clear why

At 50 MHz SPI one bit takes 20 ns, so a byte takes 160 ns and a 32-bit word
takes 640 ns — **64 system clock cycles at 100 MHz**. A 512-byte block occupies
the wire for 82 µs. Against that, any Avalon-MM path is enormously
over-provisioned: even a non-bursting master with 20-cycle latency per word has
threefold margin, and with the ping-pong buffer software in PIO mode has a whole
block time to move 128 words, which a Nios II/f does in roughly 15 µs.

So the DMA is **CPU offload, not throughput**. It buys back 10–20% of the
processor and removes any dependence on interrupt latency; it does not make the
card faster, because the card was never waiting on memory. Likewise `m0`'s
bursting is *system* efficiency — a 128-beat burst costs one SDRAM row
activation instead of 128, so the controller steals far less bandwidth from
everything else — rather than anything the core needs to keep pace.

This is why `USE_DMA` can be turned off at all (§5), and why
`M0_BURST_WIDTH = 1` is a legitimate configuration rather than a broken one.

That last one deserves its own note, because it is the least obvious and it is
free. The naive write loop sends a block, then waits for the card to release
busy before returning. The card is then idle while the host prepares the next
block. Checking busy *immediately before* the next command or data packet
instead — and doing nothing after the previous one — overlaps the card's
programming time with the host's preparation. Chan's MMC/SDC notes call this
out explicitly as the way to "eliminate waste wait time", and it is the
sequencer's default behaviour here rather than an option.

**Per-block arithmetic, multi-block read.** Each block on the wire is one start
token (1 B) + 512 B data + 2 B CRC16 = 515 byte-times, so the framing overhead
alone is 512/515 = **99.4%** efficient. Everything lost beyond that 0.6% is
card wait-states or controller stalls, and controller stalls are the part this
design is responsible for eliminating.

| Configuration | SPI clock | Expected sustained |
| --- | --- | --- |
| Multi-block read, DMA | 25 MHz | ~2.6–2.9 MB/s |
| Multi-block read, DMA | 50 MHz | ~5.2–5.8 MB/s |
| Single-block read per command | 25 MHz | ~1.5–2.2 MB/s |
| Multi-block write, DMA | 25 MHz | card-limited; commonly 1–2 MB/s |

Writes are bounded by the card's internal programming time, not by the bus.
The controller's job on writes is to never *add* to that — issue the next block
the instant the card releases busy.

**Measured.** The full-core regression moves four 512-byte blocks with CMD18
and counts SPI clocks at the pin:

| | |
| --- | --- |
| Bytes transferred | 2048 |
| SPI clocks consumed | 16 696 |
| Achieved | **0.1226 bytes per SPI clock** |
| Theoretical ceiling (8 clocks/byte) | 0.1250 |
| **Fraction of line rate** | **98.1%** |

At 25 MHz that is **3.06 MB/s** against a 3.125 MB/s ceiling. The 1.9% shortfall
is the framing the protocol requires — one start token and two CRC bytes per
block, plus the command and its response — not controller stalls. The shifter's
own unit testbench separately confirms exactly 8.00 SPI clocks per byte at every
divisor, which is the property that makes this possible.

For comparison, the same measurement on a shifter that idles one clock per byte
would read 0.111 bytes/clock — 89% of line rate, with every functional check
still passing.

**A reality check on writes.** Published single-block measurements on real cards
over SPI land around 1 MB/s read and 130–200 kB/s write — far below the line
rate, because a single-block write pays the card's whole internal programming
time per 512 bytes. This is a card property, not a controller property, and it
is the strongest argument in this document for the multi-block path and the
pre-emptive busy check. A controller that only does single-block writes will
measure an order of magnitude below its own bus rate no matter how well it is
built.

---

## 3. Interfaces

### Ports

| Interface | Type | Notes |
| --- | --- | --- |
| `clk`, `reset_n` | clock / reset sink | Single clock domain. No PLL, no CDC. |
| `csr` | Avalon-MM slave | Word-addressed, 32-bit, read latency 1, never asserts waitrequest, zero pending reads. The dullest possible register port — same profile the firewall core uses, and for the same reason: control must stay reachable when the data path is busy or wedged. |
| `m0` | Avalon-MM master | **Present only when `USE_DMA`.** Byte-addressed (SYMBOLS), bursting, reads and writes. Card→host block data is written to memory; host→card block data is read from it. Nothing accesses the controller *through* this port — it is the controller acting as a master. |
| `irq` | interrupt sender | Level, asserted while any enabled sticky bit in `IRQ_STATUS` is set. Write-1-to-clear at the source. |
| `sd` | conduit | The card pins. |

### The conduit

SPI mode uses **no bidirectional signals at all**. Every pin is unidirectional,
which removes the tristate handling that native SD mode would need — no
`inout`, no split `_in`/`_out`/`_oe` triplets, no `ALT_IOBUF` in the example
top level, and nothing that Verilator handles badly.

| Signal | Dir | SD socket pin | SD-mode name |
| --- | --- | --- | --- |
| `sd_clk` | out | 5 | CLK |
| `sd_mosi` | out | 2 | CMD |
| `sd_miso` | in | 7 | DAT0 |
| `sd_cs_n` | out | 1 | DAT3 |
| `sd_cd_n` | in | socket switch | — (present only if `USE_CARD_DETECT`) |
| `sd_wp_n` | in | socket switch | — (present only if `USE_CARD_DETECT`) |

Socket pins 8 and 9 (DAT1, DAT2) are unused in SPI mode and should be pulled
high at the board. So should MISO. This is board wiring, not core logic, but
getting it wrong produces a card that never responds, which is indistinguishable
from a dead core.

---

## 4. Architecture

The organising principle is one sentence: **the shifter must never stall.**

Every structural decision below follows from it. A design that lets the SPI
shifter wait — for the CPU, for a DMA burst, for a CRC pass, for a software
busy poll — gives back exactly the throughput SPI mode has too little of to
spare.

```
        csr (Avalon-MM slave)                    m0 (Avalon-MM master)
              |                                          |
        +-----v------+                            +------v------+
        |    regs    |                            |     dma     |
        |  CSR decode|                            | burst r/w   |
        +-----+------+                            +------+------+
              |                                          |
              |  command / config                        | 32-bit words
              |                                   +------v------+
        +-----v---------------------------+       |    fifo     |
        |             seq                 |<----->| ping-pong   |
        |  command framing, response      |bytes  | 2 x block   |
        |  capture, multi-block loop,     |       +-------------+
        |  token handling, busy polling   |
        +-----+---------------------------+
              |  byte in / byte out / go
        +-----v------+       +----------+
        |  spi_phy   |<----->|   crc    |  CRC7 on command, CRC16 on data,
        | continuous |       |          |  both computed during the shift
        |  shifter   |       +----------+
        +-----+------+
              |
        +-----v------+
        |   clkgen   |  clk / (2 x CLKDIV)
        +-----+------+
              |
         sd_clk / mosi / miso / cs_n
```

### Why each block exists

**`clkgen`** — integer divider off the Avalon clock. No PLL and no second clock
domain, so there is no CDC anywhere in the core. `CLKDIV = 1` gives clk/2,
which is 50 MHz from a 100 MHz system; `CLKDIV = 125` gives 400 kHz, the rate
the card must be identified at. The divider also gates: the SPI clock stops
cleanly when nothing is in flight, which matters because SD requires clock
pulses in specific places during initialisation and forbids them in others.

**`spi_phy`** — a continuously running shift register, not a byte-at-a-time
state machine. It shifts out and in on the same clock (SPI is inherently
full-duplex; during a read the host sends 0xFF and the useful data arrives on
MISO). The critical property is that it presents the next outgoing byte and
accepts the incoming one **without inserting an idle clock between bytes**. At
`CLKDIV = 1` there are only two system-clock cycles per SPI bit, so this block
has no slack and is the one place where careful coding decides whether the
`/2` divider is usable at all.

**`crc`** — CRC7 for command frames and CRC16-CCITT for data blocks, both
updated bit-by-bit as the shift happens. Never a separate pass over a buffer;
a second pass would double the effective cost of every block.

CRC7 is computed in hardware even though SPI mode has CRC checking disabled by
default, because CMD0 and CMD8 are validated by the card regardless. Software
that hardcodes their CRC bytes is software that cannot send any other command
before `CMD59` turns checking on. Computing it always removes the special case.

**`seq`** — the sequencer, and the block that earns most of the performance.
It owns:

- command framing: `0b01`, 6-bit index, 32-bit argument, CRC7, stop bit
- waiting for the response, bounded (`N_CR` is up to 8 byte-times, and a card
  that never answers must not hang the core)
- response capture by type — R1 is one byte, R3 and R7 are one plus four
- the data phase: waiting for the start token, streaming the block, checking
  CRC16, and on write, sending the token and reading back the data-response
- **the multi-block loop**, run entirely in hardware. `BLK_COUNT` blocks stream
  back to back with no CPU involvement and no per-block command
- **busy polling** after each written block, in hardware, resuming the instant
  MISO releases
- optional `AUTO_STOP`: CMD12 after a multi-block read, stop-tran token 0xFD
  after a multi-block write

One interrupt per transfer, not per block. A 1 MB read is one command from
software and one interrupt at the end.

**`fifo`** — ping-pong buffer, two blocks deep by default. One block is on the
wire while the other drains to or fills from memory. This is what decouples the
shifter's constant byte rate from the DMA's bursty one; with a single buffer the
shifter would stall for the duration of every burst.

**`dma`** — the Avalon-MM master, present only when `USE_DMA`. Moves whole
blocks in bursts (128 beats covers a 512-byte block in one burst at the default
`M0_BURST_WIDTH`). Reads from memory for card writes, writes to memory for card
reads. With `USE_DMA` off this block and the `m0` port are absent entirely, and
the FIFO's other client — the `DATA` window in `regs` — carries the data
instead. The FIFO does not know or care which one it is talking to; that is what
makes the parameter cheap.

Four rules from the *Avalon Interface Specifications* (18.1, §3.5.5) constrain
how it is built, and two of them are easy to violate by accident:

1. **A bursting interface that does both reads and writes must burst both
   ways.** `m0` does both — reads for card writes, writes for card reads — so
   there is no "burst the reads, keep the writes simple" shortcut available.
   Both directions get the same burst machinery or neither does.
2. **Never issue a read with all byteenables clear.** The interconnect is
   explicitly permitted to *suppress* such a read, and the slave then never
   responds — a hang with no error anywhere. Intel recommends asserting all
   byteenables for any burst read, and the DMA does so unconditionally.
3. **`waitrequest` freezes the whole command**: `writedata`, `write`,
   `burstcount` and `byteenable` all hold constant while it is asserted.
4. **`constantBurstBehavior` is false** on this port, so address and burstcount
   are held only for the burst's first transaction — matching the firewall core
   beside it, and what Platform Designer defaults to.

**Bursting is never a compatibility requirement.** Qsys inserts a
memory-mapped burst adapter whenever a bursting master meets a slave that
bursts less or not at all, translating the burst into a sequence of
non-bursting transactions. So `m0` connects to anything, and
`M0_BURST_WIDTH = 1` is a configuration choice rather than a compatibility fix.

**Byte and word ordering.** Data arrives MSB-first on MISO. Byte 0 of the block
lands in bits [7:0] of the first 32-bit word written to `m0`, byte 1 in [15:8],
and so on — little-endian, matching Nios II, so a `char*` over the DMA buffer
reads the card's bytes in card order. This is stated here because it is
invisible until it is wrong, and then expensive.

### Protocol constants the RTL encodes

Gathered here because they are what `seq`, `crc` and `spi_phy` are built out of,
and because a wrong constant here is a core that never talks to a card.

| Item | Value | Note |
| --- | --- | --- |
| SPI mode | CPOL=0, CPHA=0 (mode 0) | Clock idles low. Host drives on the falling edge, samples on the rising edge. Mode 3 also works on most cards; the core implements mode 0. |
| Command frame | 6 bytes | `01` + 6-bit index + 32-bit argument + 7-bit CRC + stop bit `1` |
| CRC7 | x⁷+x³+1 (0x89) | Result occupies the upper 7 bits of the last command byte; bit 0 is always 1 |
| CRC16 | CCITT 0x1021, **init 0x0000** | Note the init value — it is *not* the usual CCITT 0xFFFF |
| `N_CR` | 0–8 byte-times (SDC) | Host shifts 0xFF and watches for a byte with bit 7 clear. 1–8 for MMC. |
| Start block token | 0xFE | Single-block read/write, multi-block read, CSD/CID reads |
| Multi-write start token | 0xFC | Each block of a CMD25 stream |
| Stop tran token | 0xFD | Terminates CMD25. Sent alone — no data block, no CRC. |
| Data response token | `xxx0sss1` | `sss` = 010 accepted, 101 CRC error, 110 write error |
| Busy | MISO held low | After a write data-response, and during R1b |
| Power-up | ≥74 clocks, CS and MOSI high | Before CMD0, at 100–400 kHz |
| CMD8 argument | 0x000001AA | R7 echoes the low 12 bits if the card is v2.00+ |
| Byte order | MSB first | On both MOSI and MISO |

### Responses and error tokens

`R1` is one byte, MSB always 0, every other bit an error flag:

| Bit | Meaning |
| --- | --- |
| 0 | In idle state |
| 1 | Erase reset |
| 2 | Illegal command |
| 3 | Communication CRC error |
| 4 | Erase sequence error |
| 5 | Address error |
| 6 | Parameter error |
| 7 | Always 0 — this is how the sequencer finds the response byte |

`R1b` is R1 followed by busy: zero bytes mean busy, the first non-zero byte
means ready. `R2` is two bytes (CMD13 only). `R3` and `R7` are R1 plus a 32-bit
trailer — OCR for CMD58, voltage and check-pattern echo for CMD8.

**The rule that will bite if the sequencer ignores it.** §7.3.2: when R1 comes
back with *Illegal Command* or *Command CRC Error* set, the card sends **only
that one byte** — the 32-bit trailer of an R3 or R7 never arrives. A sequencer
that blindly shifts four more bytes reads garbage and desynchronises the bus for
every subsequent command. `seq` must inspect R1 bits 2 and 3 and abandon the
trailer. This is not a rare path: it is exactly what a v1.x card does in
response to CMD8, which is how the driver detects card version in the first
place.

The **data error token**, sent instead of a data block when a read fails, has a
zero upper nibble and four error bits: `0` Error, `1` CC Error, `2` Card ECC
Failed, `3` Out of range. A zero upper nibble is what distinguishes it from a
start token.

### Sequencing details that each cost a debugging week

1. **The byte after CMD12 is a stuff byte** and must be discarded before the R1
   response is read. `AUTO_STOP` handles this in hardware.
2. **The card's internal write starts one byte after the data response**, so
   eight clocks must be issued before busy means anything.
3. **The card releases MISO synchronously to the clock**, not to CS. The core
   shifts one extra byte after deasserting CS so the card actually lets go of
   the line — which matters the moment anything else shares the SPI bus.
4. **CS may be deasserted while the card is busy.** §7.2.4 is explicit: the card
   tri-states DataOut and keeps programming, and forces the line low again if
   reselected before it finishes. This is what makes the pre-emptive busy check
   legal rather than merely convenient.
5. **A failed block inside a multi-block write is stopped with CMD12, not with
   the stop-tran token.** Two different terminations for the same transfer,
   selected by whether anything went wrong.
6. **CRC is off by default in SPI, but two commands are checked regardless.**
   CMD0 must carry a valid CRC because the card is still in SD mode when it
   arrives (the constant frame is `40 00 00 00 00 95`), and §7.2.2 states CMD8's
   CRC verification is *always* enabled. Computing CRC7 in hardware
   unconditionally removes both special cases — this is the spec citation behind
   that decision in §4.

### The seam for native SD mode

`seq` talks to `spi_phy` through a narrow byte-oriented interface: *give me a
byte, take a byte, tell me when it is done*. A native-mode PHY presents the same
interface with different framing behind it. `fifo`, `dma`, `regs` and the whole
driver ABI above that line are mode-independent. Keeping that seam clean now is
what makes native mode an addition later rather than a rewrite.

---

## 5. Parameters

| Parameter | Default | Range | Purpose |
| --- | --- | --- | --- |
| `FIFO_DEPTH_BYTES` | 1024 | 512, 1024, 2048, 4096, 8192 | Block buffer. 1024 is ping-pong across two 512-byte blocks — the minimum that keeps the shifter fed. Deeper tolerates more interconnect latency, and buys nothing on a lightly loaded system. |
| `USE_DMA` | 1 | 0, 1 | Adds the `m0` master and the DMA engine. With it off, block data moves through the `DATA` window under software control and the core has no master port at all — usable in a system with no suitable memory target, or none to spare. Costs 10–20% of a 100 MHz Nios II/f during transfers and nothing in bus throughput (§2). The FIFO is the same either way; only its client changes. |
| `M0_BURST_WIDTH` | 8 | 1:9 | Ignored unless `USE_DMA`. Max burst is 2^(N-1) beats; 8 gives 128 beats = exactly one 512-byte block per burst. 1 means no bursting, which is a supported configuration and not a degraded one — see §2. Lower it if the interconnect or target memory prefers shorter bursts. |
| `CLKDIV_WIDTH` | 8 | 4:16 | SPI clock is `clk / (2 x CLKDIV)`, `CLKDIV >= 1`. 8 bits spans clk/2 to clk/510 — 50 MHz down to 196 kHz from a 100 MHz clock, covering both the 400 kHz identification rate and full speed. |
| `SAMPLE_DLY` | 0 | 0:7 | Runtime field in `CLKDIV`, not a generate-time parameter. Delays MISO capture past the nominal point to absorb round-trip delay on long wiring. **Bounded by `SAMPLE_DLY <= CLKDIV - 2`** — the SPI half-period is `CLKDIV` system clocks and the nominal capture already sits one clock inside it, so a larger value samples the *next* bit and shifts every byte of the transfer. At `CLKDIV` 1 and 2 the only legal value is 0. Rejected at generation time by the validation callback; the boundary is swept at every divisor by the shifter's unit testbench. |
| `TIMEOUT_WIDTH` | 26 | 16:32 | Bounds every wait. 26 bits at 100 MHz is 0.67 s, which covers the card's 250 ms worst-case write-busy and 100 ms read-access limits with margin. |
| `MAX_BLOCK_BYTES` | 512 | 1:512 | Sets the width of `BLK_SIZE` and the FIFO's addressing. **512 is the spec maximum**, not a convention — §7.2.3 fixes it regardless of `READ_BL_LEN`. SDHC/SDXC only ever accept 512; smaller values are for SDSC partial-block access, and only when the CSD's `READ_BL_PARTIAL` allows it. Values below 512 also serve the 16-byte CSD/CID reads. |
| `USE_CARD_DETECT` | 1 | 0, 1 | Adds `sd_cd_n` / `sd_wp_n` to the conduit and the insert/remove interrupts. Off for sockets without the switches. |
| `USE_CRC` | 1 | 0, 1 | CRC16 generation and checking on data blocks. CRC7 on commands is unconditional (see §4). Turning this off is a debugging aid, not a performance option — the CRC is free, it runs during the shift. |
| `CSR_ADDR_WIDTH` | 5 | 5:8 | In words. The map needs 17 words, so 5 is the minimum. |

---

## 6. Register map

The `csr` port is word-addressed in hardware; the interconnect converts, and
software sees byte offsets. Both are given, because the factor of four is the
easiest mistake to make with an Avalon-MM register peripheral.

| Byte | Word | Name | Access | Purpose |
| --- | --- | --- | --- | --- |
| 0x00 | 0 | `CTRL` | RW | Enable, CS_n override, CRC enable, DMA enable, soft reset |
| 0x04 | 1 | `STATUS` | RO | Live busy/FIFO/card state |
| 0x08 | 2 | `IRQ_ENABLE` | RW | Mask, same bit layout as `IRQ_STATUS` |
| 0x0C | 3 | `IRQ_STATUS` | RW1C | Sticky completion and error bits |
| 0x10 | 4 | `CLKDIV` | RW | SPI clock divider |
| 0x14 | 5 | `TIMEOUT` | RW | Response and data timeout, in `clk` cycles |
| 0x18 | 6 | `CMD_ARG` | RW | 32-bit command argument |
| 0x1C | 7 | `CMD` | RW | Command index, response type, data phase; writing starts it |
| 0x20 | 8 | `RESP0` | RO | R1 in [7:0]; the 32-bit trailer of R3/R7 |
| 0x24 | 9 | `RESP1` | RO | Second response word where one exists |
| 0x28 | 10 | `BLK_SIZE` | RW | Bytes per block, default 512 |
| 0x2C | 11 | `BLK_COUNT` | RW | Blocks in this transfer |
| 0x30 | 12 | `DMA_ADDR` | RW | System byte address, word-aligned |
| 0x34 | 13 | `DMA_CTRL` | RW | Direction, burst length, start, and a **mode** field with only `0 = contiguous` defined — the reserved seam for ADMA2-style descriptor mode (§10) |
| 0x38 | 14 | `DATA` | RW | PIO window — fallback path when `DMA_EN` is clear |
| 0x3C | 15 | `ERR_INFO` | RO | Data-response token, CRC detail, which wait timed out |
| 0x40 | 16 | `CORE_INFO` | RO | Version and build-time configuration |

### `CTRL` (0x00)

| Bit | Name | Purpose |
| --- | --- | --- |
| 0 | `ENABLE` | Master enable. Clear holds the sequencer idle and CS_n high. |
| 1 | `CS_MANUAL` | Software drives CS_n directly. Needed for the power-up sequence, where CS_n must be *high* for at least 74 clocks before CMD0. |
| 2 | `CS_VALUE` | The CS_n level driven while `CS_MANUAL`. |
| 3 | `CRC_EN` | Generate and check CRC16 on data blocks. |
| 4 | `DMA_EN` | Data phase uses `m0`. Clear routes it through the `DATA` window instead. |
| 10:8 | `SW_RESET` | Self-clearing, one bit per domain, following SDHCI's split (§10): bit 8 resets the command path, bit 9 the data path and FIFO, bit 10 everything. None of them clear configuration, so a wedged data phase can be cleared without losing the card's initialised state. |
| 9 | `CLK_RUN` | Free-run the SPI clock with CS_n deasserted, for the >=74-clock power-up. |

### `CMD` (0x1C)

| Bit | Name | Purpose |
| --- | --- | --- |
| 5:0 | `INDEX` | Command index. The core adds the `01` start bits, the CRC7 and the stop bit. |
| 7:6 | `RESP_TYPE` | 0 = R1, 1 = R1b (wait for busy release), 2 = R2, 3 = R3/R7 |
| 8 | `DATA_EN` | This command has a data phase. |
| 9 | `DATA_DIR` | 0 = card to host, 1 = host to card. |
| 10 | `MULTI` | Stream `BLK_COUNT` blocks in hardware. |
| 11 | `AUTO_STOP` | Terminate the multi-block transfer without software: CMD12 after a read, stop-tran token after a write. |
| 31 | `START` | Write 1 to launch. Reads back as busy. |

`IRQ_STATUS` carries `CMD_DONE`, `DATA_DONE`, `DMA_DONE`, the error bits
(`ERR_CMD_TIMEOUT`, `ERR_CMD_CRC`, `ERR_DATA_TIMEOUT`, `ERR_DATA_CRC`,
`ERR_DATA_TOKEN`, `ERR_WRITE`, `ERR_DMA`) and, when `USE_CARD_DETECT`,
`CARD_INSERTED` / `CARD_REMOVED`. Exact bit positions are fixed when the
package is written and are re-derived by `check_facts.py` thereafter.

`CORE_INFO` reports version, `log2(FIFO_DEPTH_BYTES)`, and the feature bits the
driver checks at `init()` — the same belt-and-braces the firewall core uses,
because a BSP is easier to copy between projects than to keep in step with one.

---

## 7. What the driver does

`inc/altera_avalon_mm_sdcard_regs.h` is offsets, masks and accessors, depending
on `<io.h>` and nothing else, usable from an ISR or a BSP with no HAL driver.
Accessors use `IORD_32DIRECT` / `IOWR_32DIRECT`, never `IORD` — `IORD` scales
by `SYSTEM_BUS_WIDTH`, and every register here is 32 bits regardless.

`HAL/` sits on top and owns the protocol:

1. **Power-up** — VDD stable for >=1 ms, then `CLK_RUN` with CS_n *high* for
   >=74 clocks at 400 kHz (§6.4.1.1; the card may use all 74 to get ready)
2. **Idle** — CMD0 with CS_n asserted. Asserting CS during CMD0 is what selects
   SPI mode, and the only way back to SD mode is a power cycle.
3. **Version** — CMD8 (arg 0x000001AA); an illegal-command R1 means v1.x or MMC,
   a valid R7 echoing the voltage and check pattern means v2.00+
4. **CRC on** — CMD59, before ACMD41, as §7.2.2 recommends
5. **Initialise** — ACMD41 polled until *in idle state* clears, HCS set for v2
   cards. Budget 1 s; the spec's own timeout for this is 1 s.
6. **Capacity** — CMD58 reads OCR; CCS decides byte vs block addressing
7. **Identity** — CMD9/CMD10 for CSD/CID, giving card size and `TRAN_SPEED`
8. **Speed up** — raise `CLKDIV` to the working rate
9. **Block length** — CMD16 for SDSC; SDHC/SDXC are fixed at 512 regardless

Then a block API — read, write, multi-block read, multi-block write — that sets
`DMA_ADDR`, `BLK_COUNT` and `CMD` and waits for one interrupt.

Two things the hardware deliberately leaves to the driver, because they need a
follow-up command rather than a bus state machine: after a write, **CMD13**
(`SEND_STATUS`, R2) reports the errors that are only detectable during
programming — address out of range, write-protect violation — and after a write
error, **ACMD22** reports how many blocks were actually written.

`avalon_mm_sdcard_controller_sw.tcl` makes the BSP find all of this by itself:
`hw_class_name` matching the component's `NAME`, `auto_initialize`,
`supported_interrupt_apis "enhanced_interrupt_api"` (absent, the SBT assumes
legacy and the driver will not link), `isr_preemption_supported`, and both HAL
and UCOSII as supported BSP types.

---

## 8. Files

```
rtl/avalon_mm_sdcard_controller_pkg.sv        types, enums, register offsets, SPI tokens
rtl/avalon_mm_sdcard_controller_crc.sv        CRC7 and CRC16-CCITT, computed during the shift
rtl/avalon_mm_sdcard_controller_clkgen.sv     SPI clock divider and gating
rtl/avalon_mm_sdcard_controller_spi_phy.sv    continuous full-duplex shifter
rtl/avalon_mm_sdcard_controller_seq.sv        command, data, multi-block and busy sequencer
rtl/avalon_mm_sdcard_controller_fifo.sv       ping-pong block buffer
rtl/avalon_mm_sdcard_controller_dma.sv        Avalon-MM master, bursting
rtl/avalon_mm_sdcard_controller_regs.sv       CSR decode
rtl/avalon_mm_sdcard_controller_top.sv        top level

tb/avalon_mm_sdcard_controller_tb.sv          self-checking regression
tb/avalon_mm_sdcard_controller_sva.sv         bound assertions and cover points
tb/spi_card_model.sv         SPI-mode card model
tb/avl_mm_mem_model.sv       memory for the DMA master to target
tb/spi_timing_check.sv       SPI bus timing checker
tb/timing_check_selftest.sv  self-test for the checker itself
```

Nine RTL files where the firewall core has three. The core is genuinely larger,
and the split follows the block diagram in §4 so that each file is one box.

`avalon_mm_sdcard_controller_pkg.sv` must be listed **first** in both `_hw.tcl` filesets, and
every file is declared `SYSTEM_VERILOG`, not `VERILOG` — the RTL uses `logic`,
`always_ff`, packed structs and enums, all of which the Verilog-2001 parser
rejects on the first line. Every file carries `` `timescale 1ns/1ps ``, because
mixing timescaled and untimescaled modules is tool-dependent and slang rejects
it outright.

---

## 9. Verification

Simulation only. There is no board demonstration, because the DE10-Lite this
repository's other examples target has no microSD socket — this core follows
`altera_avalon_mm_sdram_controller`'s precedent and says so plainly rather than
implying hardware coverage it does not have.

**The card model is the hard part**, and it is what the whole suite rests on.
It must implement CMD0/CMD8/ACMD41/CMD58/CMD59/CMD9/CMD10/CMD16/CMD17/CMD18/
CMD24/CMD25/CMD12, the R1/R1b/R3/R7 formats, `N_CR` response latency, data
tokens (0xFE start, 0xFC multi-write start, 0xFD stop-tran), data-response
tokens, CRC7 checking and CRC16 generation, busy-on-MISO after writes, and both
SDSC byte addressing and SDHC block addressing. It must also be able to
misbehave on demand: bad CRC, error tokens, never responding, and holding busy
past the timeout.

A timing checker watches the bus independently, and — following the SDRAM
core's precedent — carries a **self-test for the checker**, so a checker that
silently stops checking cannot pass the suite.

**Configurations actually swept.** `run_sim.sh` builds the full-core suite five
times and ANDs the results. These are not cosmetic variations — each reaches a
path the others cannot:

| Configuration | What only it exercises |
| --- | --- |
| `dma` | the reference case |
| `pio` (`USE_DMA=0`) | no master at all; software moves every word through `DATA` on a deadline. The only configuration where the shifter can be starved by the CPU rather than by the interconnect. |
| `sdsc` (`HIGH_CAPACITY=0`) | **byte** addressing. On an SDHC card the block-to-address conversion is the identity, so this is the only place it is tested. |
| `tight` (`FIFO_DEPTH_BYTES=512`) | one block of buffer instead of two, so nothing overlaps and the data path refills mid-transfer. |
| `noburst` (`M0_BURST_WIDTH=1`) | single-beat Avalon transactions throughout. |

The shifter's own testbench separately sweeps `CLKDIV` at 1, 2, 4 and 125 and
`SAMPLE_DLY` across its legal range at each.

Adding the sweep was not bookkeeping. Running only the reference configuration
had left the PIO path and byte addressing entirely unexecuted, and the first run
of the other four found a defect the DMA case cannot reach: neither data
streaming state checked the timeout, so a data phase starved of data hung the
core with no recovery short of a soft reset. With a master attached that cannot
happen, because the DMA always supplies. With software feeding the buffer it
can, and did.

**Throughput is a checked result, not a claim.** The testbench measures
sustained bytes per second for multi-block read and write and asserts it against
a floor derived from `CLKDIV`. That is what stops a refactor from quietly
reintroducing an inter-byte gap — the failure mode that costs 25% and is
invisible in a functional test.

---

## 10. Relationship to the SD Host Controller standard (SDHCI)

The **SD Host Controller Simplified Specification v4.20** — the SDHCI standard —
defines a standard register-level programming model for SD host controllers,
one that Linux, U-Boot and most operating systems already have drivers for. The
obvious question is whether this core should implement it.

**It cannot.** The word "SPI" does not appear once in SDHCI's 234 pages. The
standard describes a *native* SD host exclusively: its Command and Response
registers encode 48- and 136-bit native response formats, Present State reports
CMD and DAT line levels, Host Control selects 1/4/8-bit bus width, and large
parts of the map exist for UHS-I tuning, 1.8 V signalling, preset values and
UHS-II. None of that has an SPI equivalent, and no existing SDHCI driver would
bind to an SPI controller anyway, because every one of them drives native mode.

That is a clean answer rather than a disappointing one: SPI mode is defined in
the Physical Layer specification as a card protocol, and the host side of it has
never been standardised. Any SPI SD controller has its own register map, and so
does this one.

Three things are worth taking from SDHCI regardless.

**ADMA2's descriptor design, for later.** SDHCI's Advanced DMA lets the driver
build a descriptor table in memory and hand the controller a pointer, so one
command transfers a scatter-gather list. Each 64-bit descriptor line (32-bit
addressing) is a 32-bit address, a 16-bit length, and attribute bits: `Valid`,
`End`, `Int`, and an action selecting `Nop`, `Tran` or `Link` — where `Link`
points at a further table, so the list can be unbounded. It is a good design and
solves exactly the problem a filesystem creates: a file's blocks are contiguous
on the card and scattered in memory.

It is **not** in v1.0. The common Nios II case is a contiguous multi-block
buffer, which the simple DMA already handles at full rate, and descriptor
fetching is meaningful RTL. What v1.0 *does* do is leave the seam: `DMA_CTRL`
carries a mode field with only `contiguous` defined, so adding a `descriptor`
mode later is an encoding that was already reserved rather than an ABI break.

**Separate software reset domains.** SDHCI splits its reset into all / CMD line
/ DAT line rather than one blunt reset. That is cheap to implement and much
better to debug with — a stuck data phase can be cleared without losing the
card's initialised state. `CTRL.SW_RESET` becomes a small field rather than a
single bit.

**A deliberate rejection: the two-level interrupt enable.** SDHCI has both a
*Status Enable* and a *Signal Enable* per interrupt, where Status Enable gates
whether the bit is recorded at all and Signal Enable gates whether it drives the
pin. For a general-purpose host serving many drivers that flexibility earns its
keep. Here it would mean two mask registers and a class of bug where software
polls a status bit that can never set. This core records every status bit
unconditionally and uses one `IRQ_ENABLE` to gate the pin, so polling always
works and there is one obvious place to mask an interrupt.

## 11. Open questions

Things deliberately left undecided, to be closed during implementation:

1. ~~SPI mode 0 timing.~~ **Closed.** CPOL=0, CPHA=0 — clock idles low, host
   drives on the falling edge, samples on the rising edge. §7.5 *SPI Bus Timing
   Diagrams* is blank in the Simplified Specification and §7.8 says only that
   bus timing is identical to SD mode, so there are no SPI-specific setup/hold
   numbers to design against; the programmable `SAMPLE_DLY` is the answer to
   that, tunable against real hardware rather than guessed at.

   Simulation then established the bound the specification does not:
   **`SAMPLE_DLY <= CLKDIV - 2`**, because the capture point must stay inside
   the SPI half-period. The practical consequence is that **at 50 MHz there is
   no timing margin to trade at all** — `CLKDIV` 1 and 2 permit only zero delay.
   That is a reason to prefer 25 MHz on anything but a properly laid out socket,
   and it is now enforced by the validation callback rather than left to be
   discovered.
2. ~~`N_CR` bound.~~ **Closed:** 0–8 byte-times for SD cards, 1–8 for MMC. Fixed
   at 8 in hardware, with `TIMEOUT` as the outer bound — no parameter needed.
3. **`CLKDIV = 1`: functionally settled, timing still open.** A cycle-accurate
   model of the shifter (`verification/models/spi_phy_model.py`) confirms
   correct operation at clk/2 — exactly 8.00 SPI clocks per byte and bit-exact
   loopback — but only after fixing a real bug it exposed: gating the clock
   divider on `run` rather than `byte_active` let the SPI clock advance one edge
   before the first byte was loaded, shifting the bit alignment of the whole
   transfer. What remains open is whether the design *closes timing* at clk/2 in
   synthesis, which two system clocks per SPI bit leaves no slack for. If it
   does not, the honest answer is still to make `CLKDIV >= 2` the supported
   range and document 25 MHz as the ceiling.

   ~~Original question:~~ **`CLKDIV = 1` feasibility.** Two system cycles per SPI bit leaves no slack
   in `spi_phy`. If it does not close timing, the honest answer is to make
   `CLKDIV >= 2` the supported range and document 25 MHz as the ceiling.
4. ~~PIO window necessity.~~ **Closed:** the `DATA` window is load-bearing, not
   a bring-up convenience. It is the FIFO's client whenever `USE_DMA` is off,
   which §2's timing budget shows is a legitimate configuration rather than a
   degraded one. It stays, and it is verified as a swept configuration.
5. **Card-side write performance.** Whether `ACMD23` pre-erase before multi-block
   write is worth issuing from the driver, and whether the gain is measurable
   against the model.
