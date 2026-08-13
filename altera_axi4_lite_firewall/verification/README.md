# Supplementary verification

`orphan_response_tb.sv` is not part of the main suite — it's a standalone
measurement of what step 4 of the recovery sequence is worth, and the reason
resetting the peripheral before `RECOVERY.UNBLOCK` is mandatory rather than
advisory.

It runs a genuine timeout (peripheral never handshakes, then latches the
request anyway — deliberately non-compliant, the nastiest orphan source),
recovers, then issues a legitimate write while the orphaned response lands at a
swept offset. If the master ever sees the orphan's SLVERR instead of its own
OKAY, the stale response was mis-attributed.

## Running it

**Verilator** (no licence required):

```bash
cd verification
for H in 1 0; do
  verilator --binary --timing -Wno-TIMESCALEMOD -GRESET_PERIPHERAL=$H \
      --top-module orphan_tb -o oz$H -Mdir obj_$H \
      ../rtl/axi_firewall_regs.sv ../rtl/axi_firewall_top.sv orphan_response_tb.sv
  ./obj_$H/oz$H
done
```

**Icarus:**

```bash
# correct: software resets the peripheral before unblocking
iverilog -g2012 -Porphan_tb.RESET_PERIPHERAL=1 -o o1.out \
    ../rtl/axi_firewall_regs.sv ../rtl/axi_firewall_top.sv orphan_response_tb.sv
vvp o1.out
# => 0 of 25 offsets affected

# skipped: software unblocks without resetting the peripheral
iverilog -g2012 -Porphan_tb.RESET_PERIPHERAL=0 -o o0.out \
    ../rtl/axi_firewall_regs.sv ../rtl/axi_firewall_top.sv orphan_response_tb.sv
vvp o0.out
# => 1 of 25 offsets affected  (at k=3)
```

## Result

| Wiring | Offsets mis-attributed |
|---|---|
| Reset performed (`RESET_PERIPHERAL=1`) | **0 of 25** |
| Reset skipped (`RESET_PERIPHERAL=0`) | **1 of 25**, at k=3 |

Measured under Verilator 5.48 against v2.0 RTL. The delta between the two runs
is exactly the protection step 4 provides — and, since v2.0 moved that step
into software, exactly what a driver costs you by skipping it.

> **v2.0 note.** The core no longer owns a peripheral reset output, so this
> bench measures a software mistake rather than a wiring one. The numbers are
> unchanged, which is the point: the reset was always what provided the
> protection, and moving it into the driver moved the risk with it.
