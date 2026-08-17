#!/usr/bin/env python3
"""
Render the user guide's timing figures from a real simulation.

The figures are generated from a VCD rather than drawn by hand, so they cannot
drift away from the RTL: change the design and either the figure changes with
it or the scenario stops matching and this script fails loudly.

Producing the VCD (Verilator; any simulator that writes a VCD will do):

    verilator --binary --trace --top-module wave_tb \\
        ../../rtl/axi_firewall_regs.sv ../../rtl/axi_firewall_top.sv wave_tb.sv
    ./obj_dir/Vwave_tb            # writes wave.vcd

Then:

    python3 mkwaves.py wave.vcd ../figures/

wave_tb.sv drives an `int marker` signal that tags the four windows this
script cuts out: 1 permitted write, 2 denied read, 3 timeout, 4 recovery.
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from wavedraw import Vcd, val, draw          # noqa: E402

VCD = sys.argv[1] if len(sys.argv) > 1 else "wave.vcd"
OUT = os.path.abspath(sys.argv[2] if len(sys.argv) > 2 else "../figures")
V = Vcd(VCD)
os.makedirs(OUT, exist_ok=True)

NAMES = ["wave_tb.marker","wave_tb.s_awvalid","wave_tb.s_awready","wave_tb.s_wvalid","wave_tb.s_wready",
  "wave_tb.s_bvalid","wave_tb.s_bresp","wave_tb.s_bready",
  "wave_tb.s_arvalid","wave_tb.s_arready","wave_tb.s_rvalid","wave_tb.s_rresp","wave_tb.s_rdata",
  "wave_tb.m_awvalid","wave_tb.m_awready","wave_tb.m_wvalid","wave_tb.m_wready","wave_tb.m_bvalid",
  "wave_tb.m_arvalid","wave_tb.m_arready","wave_tb.m_rvalid",
  "wave_tb.dut.downstream_broken","wave_tb.dut.unblock","wave_tb.dut.wr_state","wave_tb.dut.rd_state",
  "wave_tb.c_awvalid","wave_tb.c_wdata","wave_tb.c_awaddr","wave_tb.periph_rst","wave_tb.irq"]
S = V.sample(NAMES, 5000, 1436000, 10000)

def marker_cycle(m):
    for i,(t,d) in enumerate(S):
        if val(d.get("wave_tb.marker"),32)==m: return i
    return None

def bits(name, lo, n):
    return [val(S[lo+c][1].get(name),1) for c in range(n)]

def bus(name, lo, n, width, fmt=lambda v:v):
    out=[]
    for c in range(n):
        v=val(S[lo+c][1].get(name), width)
        out.append(None if v is None else fmt(v))
    return out

RESP={0:"OKAY",2:"SLVERR",3:"DECERR"}
WR={0:"IDLE",1:"EVAL",2:"FWD",3:"RESP"}

# ---------------- Figure: permitted write ----------------
lo, n = marker_cycle(1)+1, 12
draw(f"{OUT}/fig_write_ok.svg",
  "Permitted write - request to response, 6 cycles",
  [("clk","clk",[]),
   ("s_axi_awvalid","bit",bits("wave_tb.s_awvalid",lo,n)),
   ("s_axi_awready","bit",bits("wave_tb.s_awready",lo,n)),
   ("s_axi_wvalid","bit",bits("wave_tb.s_wvalid",lo,n)),
   ("s_axi_wready","bit",bits("wave_tb.s_wready",lo,n)),
   ("wr_state","bus",bus("wave_tb.dut.wr_state",lo,n,2,lambda v:WR[v])),
   ("m_axi_awvalid","bit",bits("wave_tb.m_awvalid",lo,n)),
   ("m_axi_awready","bit",bits("wave_tb.m_awready",lo,n)),
   ("m_axi_bvalid","bit",bits("wave_tb.m_bvalid",lo,n)),
   ("s_axi_bvalid","bit",bits("wave_tb.s_bvalid",lo,n)),
   ("s_axi_bresp","bus",bus("wave_tb.s_bresp",lo,n,2,lambda v:RESP.get(v,v))),
  ], n,
  ["The address matches a valid rule that permits writes, so the transaction is forwarded on m_axi.",
   "Cycle 1: request accepted (AWREADY and WREADY together). Cycle 6: BVALID returns OKAY."])

# ---------------- Figure: denied read ----------------
lo, n = marker_cycle(2)+1, 12
draw(f"{OUT}/fig_read_denied.svg",
  "Permission-denied read - answered locally, nothing reaches the peripheral",
  [("clk","clk",[]),
   ("s_axi_arvalid","bit",bits("wave_tb.s_arvalid",lo,n)),
   ("s_axi_arready","bit",bits("wave_tb.s_arready",lo,n)),
   ("rd_state","bus",bus("wave_tb.dut.rd_state",lo,n,2,lambda v:WR[v])),
   ("m_axi_arvalid","bit",bits("wave_tb.m_arvalid",lo,n)),
   ("s_axi_rvalid","bit",bits("wave_tb.s_rvalid",lo,n)),
   ("s_axi_rresp","bus",bus("wave_tb.s_rresp",lo,n,2,lambda v:RESP.get(v,v))),
   ("s_axi_rdata","bus",bus("wave_tb.s_rdata",lo,n,32,lambda v:f"0x{v:08X}")),
   ("irq","bit",bits("wave_tb.irq",lo,n)),
  ], n,
  ["The address falls in a write-only rule. RD_EVAL rejects it and answers SLVERR from RD_RESP.",
   "m_axi_arvalid never asserts - the peripheral is not touched. RDATA is driven to zero, not left stale.",
   "irq asserts because STATUS.PERM_VIOLATION is sticky and its interrupt is enabled."])

# ---------------- Figure: timeout ----------------
lo, n = marker_cycle(3)+1, 22
draw(f"{OUT}/fig_timeout.svg",
  "Downstream timeout - master answered immediately, VALID left asserted",
  [("clk","clk",[]),
   ("s_axi_awvalid","bit",bits("wave_tb.s_awvalid",lo,n)),
   ("s_axi_awready","bit",bits("wave_tb.s_awready",lo,n)),
   ("wr_state","bus",bus("wave_tb.dut.wr_state",lo,n,2,lambda v:WR[v])),
   ("m_axi_awvalid","bit",bits("wave_tb.m_awvalid",lo,n)),
   ("m_axi_awready","bit",bits("wave_tb.m_awready",lo,n)),
   ("s_axi_bvalid","bit",bits("wave_tb.s_bvalid",lo,n)),
   ("s_axi_bresp","bus",bus("wave_tb.s_bresp",lo,n,2,lambda v:RESP.get(v,v))),
   ("downstream_broken","bit",bits("wave_tb.dut.downstream_broken",lo,n)),
   ("irq","bit",bits("wave_tb.irq",lo,n)),
  ], n,
  ["The peripheral never raises AWREADY. TIMEOUT_VALUE is 12 clocks in this capture.",
   "On expiry the core answers SLVERR upstream so the master never hangs, and latches downstream_broken.",
   "m_axi_awvalid stays asserted: AXI forbids withdrawing VALID before READY. Only UNBLOCK may drop it."])

# ---------------- Figure: recovery ----------------
lo, n = marker_cycle(4)+1, 34
draw(f"{OUT}/fig_recovery.svg",
  "Recovery sequence - acknowledge, reset the peripheral, UNBLOCK",
  [("clk","clk",[]),
   ("downstream_broken","bit",bits("wave_tb.dut.downstream_broken",lo,n)),
   ("m_axi_awvalid","bit",bits("wave_tb.m_awvalid",lo,n)),
   ("periph_rst (yours)","bit",bits("wave_tb.periph_rst",lo,n)),
   ("s_axi_ctrl_awvalid","bit",bits("wave_tb.c_awvalid",lo,n)),
   ("ctrl addr","bus",bus("wave_tb.c_awaddr",lo,n,12,lambda v:f"0x{v:02X}")),
   ("unblock","bit",bits("wave_tb.dut.unblock",lo,n)),
   ("irq","bit",bits("wave_tb.irq",lo,n)),
   ("s_axi_bvalid","bit",bits("wave_tb.s_bvalid",lo,n)),
   ("s_axi_bresp","bus",bus("wave_tb.s_bresp",lo,n,2,lambda v:RESP.get(v,v))),
  ], n,
  ["Write 0x04 acknowledges the fault (irq drops). The peripheral reset is driven by the system, not the core.",
   "Write 0x1C pulses unblock: downstream_broken clears and the stuck m_axi_awvalid is withdrawn in the same event.",
   "The final write completes with OKAY, showing forwarding has reopened."])
print("figures written to", OUT)
