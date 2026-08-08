# AXI4-Lite Firewall for Platform Designer / Nios II

A custom access-control + fault-isolation firewall core for Intel/Altera
Quartus + Platform Designer. There is no stock "AXI Firewall" IP in the
Altera catalog (unlike Xilinx's Vivado isolation flow) — this is a from-
scratch component, delivered as synthesizable Verilog plus a Platform
Designer component wrapper.

## What it does

Sits between a bus master and a peripheral you want to protect:

```
                 ┌─────────────────────────────┐
   AXI4-Lite     │                              │    AXI4-Lite
 ───────────────▶│  s_axi          m_axi        │───────────────▶
  (from master,   │        axi_firewall_top      │   (to protected
   e.g. Nios II   │                              │    peripheral)
   via bridge)    │                              │
                  │         s_axi_ctrl  irq      │
                  └───────────┬──────────┬───────┘
                               │          │
                       AXI4-Lite       interrupt
                    (config/status)   (to Nios II)
```

1. **Access control** — every transaction's address is checked against a
   software-programmable table of allowed address ranges, each with
   independent read/write permission. Default-deny: an address that matches
   no rule is rejected, exactly like an address that matches a rule but not
   for the direction requested.
2. **Fault isolation** — every transaction forwarded to the protected
   peripheral is watched by a timeout counter. If the peripheral never
   responds, the firewall synthesizes an error response back to the master
   itself (so the master never hangs) and — if auto-isolate is enabled —
   latches into an ISOLATED state that immediately rejects all further
   transactions without ever touching the peripheral again, until software
   acknowledges the fault.
3. **Violations raise an interrupt** to Nios II in addition to returning
   SLVERR/DECERR, per your earlier answers.

Control/status live on a **separate** AXI4-Lite port (`s_axi_ctrl`) so that
configuring or inspecting the firewall is never itself subject to firewall
rules or blockable by an isolated peripheral.

## Files

```
axi_firewall/
├── axi_firewall_hw.tcl        Platform Designer component description
├── rtl/
│   ├── axi_firewall_top.v     Datapath: s_axi, m_axi, permission checks, timeout/isolate FSMs
│   └── axi_firewall_regs.v    Rule table, status/IRQ, control AXI4-Lite slave
├── tb/
│   └── axi_firewall_tb.v      Self-checking testbench (21 checks, all passing)
└── README.md                  This file
```

## Why AXI4-Lite-only changes what "access control" means here

You asked for AXI4-Lite specifically. Worth knowing up front: **AXI4-Lite has
no ID field** (that's part of what makes it "Lite" — no bursts, no IDs, no
locked/exclusive access). So this core cannot distinguish *which master*
issued a transaction — only *what address* it targets and whether it's a
read or a write. Access control here is address-range + read/write
permission, not per-master identity.

If you need per-master filtering (e.g. "Nios II can write region X, but a
DMA engine can only read it"), that needs either full AXI4 (which carries
AWID/ARID) or a sideband master-ID signal added to a custom variant of this
core — happy to build that variant if useful; say the word.

## Register map (`s_axi_ctrl`, 32-bit registers, word-aligned)

| Offset | Name | Access | Description |
|---|---|---|---|
| 0x00 | CTRL | R/W | bit0 `GLOBAL_ENABLE` (default **1**, secure-by-default); bit1 `AUTO_ISOLATE_EN` (default 1); bit2 `MANUAL_ISOLATE` (software-forced isolate) |
| 0x04 | STATUS | R, W1C on [2:0] | bit0 `ADDR_VIOLATION`, bit1 `PERM_VIOLATION`, bit2 `TIMEOUT_ERROR` (sticky, clear-on-write-1); bit3 `ISOLATED` (live, read-only — reflects `MANUAL_ISOLATE OR` the internal auto-isolate latch) |
| 0x08 | IRQ_ENABLE | R/W | bit0/1/2 enable irq for ADDR_VIOLATION / PERM_VIOLATION / TIMEOUT_ERROR (default all enabled) |
| 0x0C | TIMEOUT_VALUE | R/W | timeout threshold in clk cycles (default all-ones = effectively disabled until you set it) |
| 0x10 | FAULT_ADDR | R | address of the most recently latched fault |
| 0x14 | FAULT_INFO | R | bit0 `WAS_WRITE`; bits[3:1] fault type (1=ADDR, 2=PERM, 3=TIMEOUT) |
| 0x18 | CORE_INFO | R | bits[7:0] = NUM_RULES as generated; bits[31:16] = version (0x0100 = v1.0) |
| 0x40 + i·0x10 | RULE_BASE\[i\] | R/W | inclusive base address of range *i* |
| 0x44 + i·0x10 | RULE_LIMIT\[i\] | R/W | inclusive top address of range *i* |
| 0x48 + i·0x10 | RULE_PERM\[i\] | R/W | bit0 `READ_ALLOW`, bit1 `WRITE_ALLOW`, bit2 `VALID` (rule ignored entirely if 0) |

`i` runs `0 .. NUM_RULES-1` (default 8 rules ⇒ table spans 0x40–0xBF).
Clearing `STATUS.TIMEOUT_ERROR` also releases the auto-isolate latch — this
is intentional: recovering from isolation requires acknowledging why it
happened, not just flipping a bit blind.

## Design decisions worth knowing about

- **Rule priority**: lowest-index valid rule that contains the address wins;
  rules aren't required to be non-overlapping, so put more specific rules at
  lower indices if you use overlapping ranges.
- **In-flight transactions aren't aborted by ISOLATE.** A transaction already
  forwarded to `m_axi` before isolation triggers is allowed to finish or
  time out normally — only *new* transactions are blocked immediately.
  Aborting mid-flight isn't well-defined in AXI once the address phase has
  been accepted.
- **`m_axi_bready`/`m_axi_rready` are tied high permanently.** The entire
  point of a firewall/isolation core is that a wedged downstream peripheral
  can never stall anything upstream of it — including itself. A late
  response from an already-timed-out transaction is silently absorbed
  instead of leaving a response channel stuck.
- **Timeout covers the whole round trip** (address issue → response), so it
  also catches a peripheral that never even raises AWREADY/ARREADY, not just
  one that accepts and then never responds.
- **Simultaneous read+write fault in the same cycle**: both sticky STATUS
  bits are still set correctly, but `FAULT_ADDR`/`FAULT_INFO` captures the
  write side (documented, deterministic tie-break — a genuinely rare corner
  case, not a silent bug).
- Single-outstanding transaction per channel (no pipelining). This is
  standard for AXI4-Lite control-style traffic and keeps the FSMs simple and
  easy to review; it isn't meant for high-throughput datapaths.

## Integration into Platform Designer

1. Copy the whole `axi_firewall/` folder into your Quartus project (or a
   shared IP library path Quartus searches — **Tools ▸ Options ▸ IP Search
   Path**), then **Platform Designer ▸ File ▸ Refresh System** so it appears
   in the IP Catalog as "AXI4-Lite Firewall".
2. **Verify the component packages cleanly for your Quartus version.**
   `hw.tcl` syntax has drifted across releases (Standard vs Pro, version to
   version). If it doesn't import cleanly: open Component Editor, add the
   two files under `rtl/` as synthesis files with `axi_firewall_top.v` as
   top-level, click **Analyze Synthesis Files**. Every port already follows
   the `s_axi_*` / `m_axi_*` / `s_axi_ctrl_*` naming convention with
   standard AXI4-Lite signal suffixes, so Platform Designer's own signal
   analysis should auto-group them into three AXI4-Lite interfaces; fix up
   anything it misses in the Signals & Interfaces tab, then **Finish** to
   regenerate a `hw.tcl` guaranteed correct for your toolchain.
3. Instantiate it in your system.
4. Nios II is Avalon-MM natively, but you do **not** need to manually insert
   a bridge: per Intel's Platform Designer documentation, "you can make
   connections between AXI and Avalon interfaces without the use of
   explicitly-instantiated bridges; the interconnect provides all necessary
   bridging logic." Just connect Nios II's `data_master` directly to
   `s_axi` and `s_axi_ctrl` in System Contents, and `m_axi` directly to the
   protected peripheral (Avalon-MM or AXI4-Lite, either connects directly).
   An explicit **AXI Bridge Intel FPGA IP** (or **AXI Timeout Bridge**) is
   available in the catalog if you ever want to trade some concurrency for
   less bridging logic in the interconnect, but it's optional.
5. Wire `irq` to a Nios II IRQ input.
6. Connect `clock`/`reset` to your system clock/reset network.
7. Assign each rule's base/limit in software to match the peripheral's
   actual address decode, and size `CTRL_ADDR_WIDTH`/`NUM_RULES` for how
   many ranges you actually need.

## Quick software reference (Nios II HAL style)

```c
#include "sys/alt_irq.h"
#include "io.h"

#define FW_BASE   AXI_FIREWALL_0_S_AXI_CTRL_BASE   // from system.h

#define FW_CTRL        0x00
#define FW_STATUS      0x04
#define FW_IRQ_ENABLE  0x08
#define FW_TIMEOUT     0x0C
#define FW_FAULT_ADDR  0x10
#define FW_RULE(i, r)  (0x40 + (i)*0x10 + (r))  // r: 0=BASE 4=LIMIT 8=PERM

void firewall_init(void) {
    // Rule 0: 0x1000-0x1FFF, read+write allowed
    IOWR_32DIRECT(FW_BASE, FW_RULE(0, 0), 0x1000);
    IOWR_32DIRECT(FW_BASE, FW_RULE(0, 4), 0x1FFF);
    IOWR_32DIRECT(FW_BASE, FW_RULE(0, 8), 0x7);   // VALID|WRITE|READ

    IOWR_32DIRECT(FW_BASE, FW_TIMEOUT, 50000);    // tune for your clock
}

static void firewall_isr(void *context) {
    alt_u32 status = IORD_32DIRECT(FW_BASE, FW_STATUS);
    if (status & 0x7) {
        alt_u32 fault_addr = IORD_32DIRECT(FW_BASE, FW_FAULT_ADDR);
        // ... log / handle ...
        IOWR_32DIRECT(FW_BASE, FW_STATUS, status & 0x7); // W1C
    }
}
```

## Re-running the verification yourself

The testbench needs no Quartus license — it's plain Verilog-2001, verified
here with Icarus Verilog:

```bash
iverilog -g2005 -o tb.out rtl/axi_firewall_regs.v rtl/axi_firewall_top.v tb/axi_firewall_tb.v
vvp tb.out
```

Currently: **21/21 checks pass** — covers allowed read/write, permission
denial (SLVERR + status + irq), unmapped address (DECERR + status),
downstream timeout → auto-isolate → immediate block of the next access
(with an explicit check that `m_axi_awvalid` never even asserts while
isolated), W1C recovery, and global bypass mode.

## Possible extensions

- Per-master filtering via full AXI4 (ID-carrying) or a sideband ID signal
- Separate fault-address latches per fault type instead of one shared latch
- Burst support (would mean moving off AXI4-Lite to full AXI4)
- Rule-hit counters per range, for auditing/profiling access patterns
