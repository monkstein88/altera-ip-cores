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
> It passes 57 self-checking assertions across three testbenches against a
> behavioural SD card model — with the full-core suite run in five
> configurations — plus bound SVA assertions proven live by fault injection,
> 22 checks on the Platform Designer component and three on the HAL driver.
> None of that is a substitute for hardware, and the DE10-Lite this
> repository's other examples target has no microSD socket — see
> [Verification status](#verification-status-what-is-and-is-not-proven).

---

## What it does

| | |
| --- | --- |
| **Card interface** | SPI mode (CPOL=0, CPHA=0), 4 wires, no tristates |
| **Commands** | Any; the hardware frames and CRCs them, software chooses them |
| **Data** | Single and multi-block, both directions, streamed in hardware |
| **CRC** | CRC7 on every command, CRC16 on every data block, computed during the transfer |
| **DMA** | Optional Avalon-MM master, bursting, straight into system memory |
| **Measured throughput** | **98.1% of SPI line rate** — 3.06 MB/s of a possible 3.125 at 25 MHz |
| **Software** | Nios II HAL driver, found automatically by the BSP |

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
preparation and with the DMA refilling the buffer. On a multi-block write that
is most of the difference between the card's rate and the bus's.

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

Nine RTL files, 3127 lines, one per box plus the package and the top level.
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

```c
#include "altera_avalon_mm_sdcard_controller.h"

extern alt_sdcard_dev sdcard;      /* from alt_sys_init.c */

alt_u8 buf[512];

if (alt_sdcard_probe(&sdcard) == ALT_SDCARD_OK) {
    alt_sdcard_read_blocks(&sdcard, 0, buf, 1);
}
```

`block` is a 512-byte block number in both directions. The driver converts to a
byte address for standard-capacity cards, which is the entire reason a caller
does not have to know which kind of card is fitted.

### What is hardware and what is software

The hardware owns the link layer because it is timing-critical, repetitive and
stable across spec revisions. The driver owns the protocol — the identification
sequence, v1.x versus v2.00, byte versus block addressing, CSD parsing, the
ACMD41 retry policy — because that is where every SD implementation accumulates
its card-specific workarounds, and a workaround in a driver is a recompile
rather than a new bitstream.

---

## Verification

Everything here runs without a licence. Verilator 5.050 or newer.

```
./verification/run_all.sh                # everything, roll-up result
```

or individually:

```
simulation/verilator/run_sim.sh          # all three testbenches
simulation/verilator/run_sim.sh phy      # just the shifter
tclsh verification/check_hw_tcl.tcl      # the Platform Designer component
./verification/check_driver_builds.sh    # the HAL driver, and CSD arithmetic
./verification/check_assertions_fire.sh  # prove the assertions can fail
python3 doc/tools/check_facts.py         # every number in these documents
python3 verification/models/crc_reference.py
```

Three of those need **no simulator at all**, which is the point of them: they
catch the dull mechanical faults — a renamed parameter, a port added to an
interface that does not exist, a typo in the driver, a figure in this README
that no longer matches the RTL — which otherwise survive until someone with the
full Quartus toolchain tries to build a project.

| Suite | Checks | What it proves |
| --- | --- | --- |
| `phy` | 12 | Exactly 8.00 SPI clocks per byte at every divisor; bit-exact loopback; the `SAMPLE_DLY` bound |
| `fifo` | 5 | Byte↔word round trip both directions, little-endian order, partial-word flush |
| `core` | 40 | Identification, single and multi-block both directions, CSD/CID, every card-reported failure, `ERR_INFO` contents, reset domains, throughput floor, Avalon conformance |
| `check_hw_tcl.tcl` | 22 | The component executes; parameters and ports exist; validation rejects exactly the bad configurations |
| `check_driver_builds.sh` | 3 | The driver compiles clean under `-Wall -Wextra`; CSD capacity arithmetic for both structure versions; the register header stands alone |
| `check_assertions_fire.sh` | 3 faults | Each injected into a scratch copy and required to be caught by the assertion meant to catch it |
| `check_facts.py` | 89 | Every register offset, parameter default, line count and measured figure in these documents, re-derived from the RTL |
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

### Measured throughput

| | |
| --- | --- |
| Multi-block read, 4 × 512 bytes | 2048 bytes |
| SPI clocks consumed | 16 696 |
| Achieved | **0.1226 bytes per SPI clock** |
| Ceiling (8 clocks/byte) | 0.1250 |
| **Fraction of line rate** | **98.1%** |

At 25 MHz that is **3.06 MB/s** against a 3.125 MB/s ceiling. The 1.9%
shortfall is protocol framing — one start token and two CRC bytes per block,
plus the command and its response — not controller stalls.

The same measurement on a shifter that idles one clock per byte would read
0.111 bytes/clock, and every functional check would still pass.

### Verification status — what is and is not proven

**Proven in simulation:** the SPI link layer against a specification-derived
card model, including every failure the card can report; the Avalon-MM agent and
host against a memory model with wait states and read latency; the register map;
the interrupt behaviour; the throughput; the component description; that the
driver compiles.

**Not proven:**

- **Nothing has run on hardware.** No timing closure, no Fmax figure, no
  resource count, no real card. The DE10-Lite that this repository's other
  examples target has no microSD socket, so a board demonstration needs a
  breakout on the GPIO or Arduino header and its own pinout.
- **`CLKDIV = 1` (50 MHz) is functionally correct but unproven in silicon.**
  Two system clocks per SPI bit leaves the shifter no slack. If it does not
  close timing, the honest answer is to make `CLKDIV >= 2` the supported range
  and document 25 MHz as the ceiling.
- **No real card has been touched.** The model is written to the specification,
  and real cards deviate from it — that is why the protocol layer is in software.
- **The Platform Designer component has not been opened in Quartus.** The Tcl
  executes and its callbacks behave, but property spellings drift between
  releases; see the header of the `_hw.tcl`.
- **Write throughput has no meaningful measurement.** It is bounded by the
  card's internal programming time, which the model does not attempt to
  reproduce faithfully. Published figures for real cards over SPI are 130–200
  kB/s for single-block writes — an order of magnitude below the bus rate, and a
  card property rather than a controller one. It is the strongest argument for
  the multi-block path and the pre-emptive busy check.

---

## Layout

```
rtl/          nine SystemVerilog files, 3127 lines
tb/           card model, memory model, three testbenches, bound SVA
simulation/verilator/run_sim.sh
verification/ hw.tcl checker, driver compile check, assertion fault
              injection, design-time Python models
HAL/, inc/    Nios II driver and the standalone register header
doc/          design specification
*_hw.tcl      Platform Designer component
*_sw.tcl      BSP driver description
```

`doc/avalon_mm_sdcard_controller_design.md` is the design record: why each
decision was made, what the specification requires, and what is still open.

## Licence

MIT — see the repository's [`LICENSE`](../LICENSE).

The SD specifications this core is written against are the SD Association's and
are **not** included here. They are free to download from
[sdcard.org](https://www.sdcard.org/downloads/pls/), which is not the same as
free to redistribute. Every fact taken from them is cited by section number so
you can check it against your own copy.
