# Supplementary verification

`orphan_response_tb.v` is not part of the main suite — it's a standalone
proof for the timeout-recovery fix, kept because its result is the reason
`m_axi_resetn` is mandatory.

It runs a genuine timeout (peripheral never handshakes, then latches the
request anyway — deliberately non-compliant, the nastiest orphan source),
recovers, then issues a legitimate write while the orphaned response lands
at a swept offset.

```bash
# supported wiring: peripheral honours m_axi_resetn
iverilog -g2005 -Porphan_tb.HONOUR_RESET=1 -o o1.out \
    ../rtl/axi_firewall_regs.v ../rtl/axi_firewall_top.v orphan_response_tb.v
vvp o1.out
# => 0 of 25 offsets affected

# unsupported wiring: peripheral ignores m_axi_resetn
iverilog -g2005 -Porphan_tb.HONOUR_RESET=0 -o o0.out \
    ../rtl/axi_firewall_regs.v ../rtl/axi_firewall_top.v orphan_response_tb.v
vvp o0.out
# => 1 of 25 offsets affected
```

The delta between the two runs is exactly the protection `m_axi_resetn`
provides.
