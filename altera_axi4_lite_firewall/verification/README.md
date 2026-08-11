# Supplementary verification

`orphan_response_tb.sv` is not part of the main suite — it's a standalone
measurement of what `m_axi_resetn` is worth, and the reason connecting it is
mandatory rather than advisory.

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
  verilator --binary --timing -Wno-TIMESCALEMOD -GHONOUR_RESET=$H \
      --top-module orphan_tb -o oz$H -Mdir obj_$H \
      ../rtl/axi_firewall_regs.sv ../rtl/axi_firewall_top.sv orphan_response_tb.sv
  ./obj_$H/oz$H
done
```

**Icarus:**

```bash
# supported wiring: peripheral honours m_axi_resetn
iverilog -g2012 -Porphan_tb.HONOUR_RESET=1 -o o1.out \
    ../rtl/axi_firewall_regs.sv ../rtl/axi_firewall_top.sv orphan_response_tb.sv
vvp o1.out
# => 0 of 25 offsets affected

# unsupported wiring: peripheral ignores m_axi_resetn
iverilog -g2012 -Porphan_tb.HONOUR_RESET=0 -o o0.out \
    ../rtl/axi_firewall_regs.sv ../rtl/axi_firewall_top.sv orphan_response_tb.sv
vvp o0.out
# => 1 of 25 offsets affected  (at k=3)
```

## Result

| Wiring | Offsets mis-attributed |
|---|---|
| `m_axi_resetn` connected (`HONOUR_RESET=1`) | **0 of 25** |
| `m_axi_resetn` left unconnected (`HONOUR_RESET=0`) | **1 of 25**, at k=3 |

Measured under Verilator 5.48 against v1.2 RTL. The delta between the two runs
is exactly the protection `m_axi_resetn` provides.

> **v1.2 note.** Up to v1.1 the core also carried `wr_discard_pending` /
> `rd_discard_pending` one-shot flags, described as a secondary safety net for
> exactly this hazard. They were dead code: the timeout that armed a flag also
> asserted `downstream_broken`, which drops `m_axi_resetn` two cycles later,
> and the reset clause cleared the flag before the FSM could re-enter `*_FWD`
> and ever test it. Questa had already reported both at 0% condition coverage.
> They have been removed, and this testbench's numbers are unchanged by that —
> which is the point: the reset was always doing all the work.
