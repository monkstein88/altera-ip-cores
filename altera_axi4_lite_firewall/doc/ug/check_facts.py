#!/usr/bin/env python3
"""
Cross-check every factual table in the user guide against its source.

A user guide that has quietly gone out of date is worse than no user guide,
and none of this is checkable by reading. Every register offset, bit position,
reset value, parameter range, port count, assertion pass count, cover hit and
FSM transition count quoted in the guide is re-derived here from the RTL,
axi_firewall_hw.tcl, the committed Questa coverage report and run log - and
compared. Anything that drifts fails the run.

Usage:  python3 check_facts.py
Exit:   0 if every claim still matches its source, 1 otherwise.
"""
import os
import re
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
UG   = open(f"{ROOT}/doc/axi4_lite_firewall_user_guide.md").read()
TOP  = open(f"{ROOT}/rtl/axi_firewall_top.sv").read()
REGS = open(f"{ROOT}/rtl/axi_firewall_regs.sv").read()
TCL  = open(f"{ROOT}/axi_firewall_hw.tcl").read()
# The Questa artefacts are deliberately gitignored - a stale coverage report
# lying around in a working copy is how wrong numbers get cited as current.
# So they may legitimately be absent. When they are, the checks that depend on
# them are skipped and counted, loudly, rather than silently passing.
def _load(path):
    try:
        return open(path).read()
    except OSError:
        return None

COV = _load(f"{ROOT}/simulation/questa/coverage_report.txt")
LOG = _load(f"{ROOT}/simulation/questa/run.log")
HAVE_RUN = COV is not None and LOG is not None

bad, ok, skipped = [], 0, 0
def chk(cond, msg):
    global ok
    if cond: ok += 1
    else: bad.append(msg)

# ---- 1. register offsets -------------------------------------------------
rtl_off = dict(re.findall(r"OFF_(\w+)\s*=\s*'h([0-9A-Fa-f]+)", REGS))
ug_off  = dict((n, o[2:]) for o, n in
               re.findall(r"\|\s*(0x[0-9A-F]{2})\s*\|\s*`(\w+)`\s*\|", UG))
alias = {"TIMEOUT_VALUE": "TIMEOUT"}
for name, off in ug_off.items():
    key = alias.get(name, name)
    chk(key in rtl_off, f"UG register {name} not found in RTL")
    if key in rtl_off:
        chk(int(rtl_off[key], 16) == int(off, 16),
            f"{name}: UG 0x{off} vs RTL 0x{rtl_off[key]}")
for key in rtl_off:
    inv = {v: k for k, v in alias.items()}
    chk(inv.get(key, key) in ug_off, f"RTL register OFF_{key} missing from UG")

# ---- 2. rule table geometry ---------------------------------------------
chk("RULE_TABLE_BASE = 'h40" in REGS, "rule table base is not 0x40 in RTL")
chk("RULE_STRIDE     = 16" in REGS, "rule stride is not 16 in RTL")
chk("0x40 + i·0x10" in UG, "UG does not state the 0x40 + i*0x10 rule layout")
for sub, name in [("0", "BASE"), ("4", "LIMIT"), ("8", "PERM")]:
    chk(re.search(rf"RULE_SUB_{name}\s*=\s*4'h{sub}", REGS) is not None,
        f"RULE_SUB_{name} sub-offset changed")

# ---- 3. STATUS bit order ------------------------------------------------
m = re.search(r"OFF_STATUS:\s*s_axi_ctrl_rdata <= \{(.*?)\};", REGS, re.S)
fields = [f.strip() for f in m.group(1).replace("\n", " ").split(",")]
want = ["23'b0", "dstat_rd_cmd_stuck", "dstat_wr_cmd_stuck", "dstat_rd_resp_busy",
        "dstat_wr_resp_busy", "dstat_blocked", "isolate_effective",
        "reg_timeout_error", "reg_perm_violation", "reg_addr_violation"]
chk(fields == want, f"STATUS read mux changed: {fields}")
status_tbl = UG.split("**Table 19. STATUS**")[1].split("**Table 20")[0]
ug_status = dict((int(b), n) for b, n in
                 re.findall(r"\|\s*(\d)\s*\|\s*`(\w+)`\s*\|", status_tbl))
for bit, name in [(8, "RD_CMD_STUCK"), (7, "WR_CMD_STUCK"), (6, "RD_RESP_BUSY"),
                  (5, "WR_RESP_BUSY"), (4, "BLOCKED"), (3, "ISOLATED"),
                  (2, "TIMEOUT_ERROR"), (1, "PERM_VIOLATION"), (0, "ADDR_VIOLATION")]:
    chk(ug_status.get(bit) == name,
        f"UG STATUS bit {bit} is {ug_status.get(bit)}, RTL says {name}")

# ---- 4. CTRL bits -------------------------------------------------------
chk("reg_global_enable   <= s_axi_ctrl_wdata[0]" in REGS, "CTRL bit0 != GLOBAL_ENABLE")
chk("reg_auto_isolate_en <= s_axi_ctrl_wdata[1]" in REGS, "CTRL bit1 != AUTO_ISOLATE_EN")
chk("reg_manual_isolate  <= s_axi_ctrl_wdata[2]" in REGS, "CTRL bit2 != MANUAL_ISOLATE")

# ---- 5. reset values ----------------------------------------------------
chk("reg_global_enable   <= 1'b1" in REGS, "GLOBAL_ENABLE reset != 1")
chk("reg_auto_isolate_en <= 1'b1" in REGS, "AUTO_ISOLATE_EN reset != 1")
chk("reg_manual_isolate  <= 1'b0" in REGS, "MANUAL_ISOLATE reset != 0")
chk("reg_irq_enable      <= 3'b111" in REGS, "IRQ_ENABLE reset != 0x7")
chk("reg_timeout_value   <= '1" in REGS, "TIMEOUT_VALUE reset != all ones")
chk("| 0x00 | `CTRL` | R/W | 0x3 |" in UG, "UG CTRL reset is not 0x3")
chk("| 0x08 | `IRQ_ENABLE` | R/W | 0x7 |" in UG, "UG IRQ_ENABLE reset is not 0x7")
chk("| 0x0C | `TIMEOUT_VALUE` | R/W | all ones |" in UG, "UG TIMEOUT reset wrong")

# ---- 6. RULE_PERM layout ------------------------------------------------
chk("rule_perm = {valid, wr_en, rd_en}" in
    open(f"{ROOT}/doc/src/build_doc.py").read(), "block diagram perm layout note gone")
chk("| 2 | `VALID` | R/W | 0 |" in UG, "UG RULE_PERM VALID is not bit 2")
chk("| 1 | `WRITE_ALLOW` | R/W | 0 |" in UG, "UG RULE_PERM WRITE_ALLOW is not bit 1")
chk("| 0 | `READ_ALLOW` | R/W | 0 |" in UG, "UG RULE_PERM READ_ALLOW is not bit 0")

# ---- 7. FAULT_TYPE encoding --------------------------------------------
for v, n in [(0, "NONE"), (1, "ADDR"), (2, "PERM"), (3, "TIMEOUT")]:
    chk(f"FAULT_{n}    = 3'b{v:03b}" in REGS or f"FAULT_{n} = 3'b{v:03b}" in REGS
        or re.search(rf"FAULT_{n}\s*=\s*3'b{v:03b}", REGS) is not None,
        f"FAULT_TYPE {n} != {v} in RTL")
    chk(f"| {v} | `{n}` |" in UG, f"UG FAULT_TYPE {n} not documented as {v}")

# ---- 8. version ---------------------------------------------------------
chk("VERSION16 = 16'h0200" in REGS, "RTL version is not 0x0200")
chk("`0x0200`" in UG, "UG does not state CORE_INFO 0x0200")
chk("set_module_property VERSION 2.0" in TCL or "VERSION 2.0" in TCL,
    "hw.tcl version is not 2.0")

# ---- 9. parameters ------------------------------------------------------
rtl_par = dict(re.findall(r"parameter int (\w+)\s*=\s*(\d+)", TOP))
for p, d in [("ADDR_WIDTH", "32"), ("DATA_WIDTH", "32"), ("CTRL_ADDR_WIDTH", "12"),
             ("NUM_RULES", "8"), ("TIMEOUT_WIDTH", "20")]:
    chk(rtl_par.get(p) == d, f"{p} default is {rtl_par.get(p)}, UG says {d}")
    chk(re.search(rf"\|\s*`{p}`\s*\|\s*Integer\s*\|\s*{d}\s*\|", UG) is not None,
        f"UG parameter row for {p} missing or wrong default")
chk(len(rtl_par) == 5, f"RTL has {len(rtl_par)} parameters, UG documents 5")
for p, rng in [("ADDR_WIDTH", "{8:32}"), ("DATA_WIDTH", "{32 64}"),
               ("CTRL_ADDR_WIDTH", "{8:16}"), ("NUM_RULES", "{1:64}"),
               ("TIMEOUT_WIDTH", "{8:32}")]:
    chk(f"set_parameter_property {p} ALLOWED_RANGES {rng}" in TCL,
        f"hw.tcl range for {p} is not {rng}")

# ---- 10. CTRL_ADDR_WIDTH sizing table -----------------------------------
for nr, hi, need in [(1, "0x4F", 7), (4, "0x7F", 7), (16, "0x13F", 9),
                     (32, "0x23F", 10), (64, "0x43F", 11)]:
    span = 0x40 + nr * 16
    n = 0
    while (1 << n) < span: n += 1
    chk(n == need, f"computed min CTRL_ADDR_WIDTH for {nr} rules is {n}, UG says {need}")
    chk(hex(span - 1).upper().replace("0X", "0x") == hi,
        f"highest byte for {nr} rules is {hex(span-1)}, UG says {hi}")

# ---- 11. TIMEOUT_WIDTH table -------------------------------------------
for w, mx in [(8, 255), (12, 4095), (16, 65535), (20, 1048575),
              (24, 16777215), (32, 4294967295)]:
    chk((1 << w) - 1 == mx, f"2^{w}-1 != {mx}")
    chk(f"| {w}" in UG and f"{mx:,}".replace(",", " ") in UG.replace(",", " "),
        f"UG max-count row for TIMEOUT_WIDTH={w} not found")

# ---- 12. port count -----------------------------------------------------
ports = re.search(r"\) \(\n(.*?)\n\);", TOP, re.S).group(1)
n_ports = len(re.findall(r"^\s*(?:input|output)\s+logic", ports, re.M))
chk(n_ports == 60, f"RTL has {n_ports} ports, UG says 60")
for pref, want in [("s_axi_", 19), ("m_axi_", 19), ("s_axi_ctrl_", 19)]:
    n = len(re.findall(rf"^\s*(?:input|output)\s+logic.*\b{pref}\w+,?\s*$",
                       ports, re.M))
    if pref == "s_axi_":
        n -= len(re.findall(r"^\s*(?:input|output)\s+logic.*\bs_axi_ctrl_\w+,?\s*$",
                            ports, re.M))
    chk(n == want, f"{pref}* has {n} ports, UG says {want}")

# ---- 13. tied-high master response ready --------------------------------
chk("assign m_axi_bready = 1'b1;" in TOP, "m_axi_bready is no longer tied high")
chk("assign m_axi_rready = 1'b1;" in TOP, "m_axi_rready is no longer tied high")

# ---- 14. verification numbers ------------------------------------------
if not HAVE_RUN:
    skipped = 1
else:
  chk("103 passed, 0 failed" in LOG, "run.log does not report 103 passed")
  chk("LATENCY: write request -> BVALID = 6 cycles" in LOG, "write latency != 6")
  chk("LATENCY: read  request -> RVALID = 6 cycles" in LOG, "read latency != 6")
  chk(re.search(r"Assertions\s+14\s+14\s+0\s+100\.00%", COV) is not None,
      "coverage report does not show 14/14 assertions")
  chk(re.search(r"Directives\s+6\s+6\s+0\s+100\.00%", COV) is not None,
      "coverage report does not show 6/6 directives")
  chk("Total Coverage By Instance (filtered view): 85.96%" in COV,
      "total coverage is not 85.96%")
  chk("wr_cycles > 8 || rd_cycles > 8" in open(f"{ROOT}/tb/axi_firewall_tb.sv").read(),
      "TB latency guard is no longer 8 cycles")

  # assertion pass counts quoted in the UG
  for name, passes in [("a_suppress_illegal_write", 4), ("a_suppress_illegal_read", 4),
                       ("a_err_on_blocked_write", 4), ("a_err_on_blocked_read", 4),
                       ("a_awvalid_stability", 23), ("a_arvalid_stability", 23),
                       ("a_bvalid_stability", 6), ("a_rvalid_stability", 6),
                       ("a_m_awvalid_stability", 162), ("a_m_wvalid_stability", 162),
                       ("a_m_arvalid_stability", 119), ("a_no_issue_while_blocked", 382),
                       ("a_no_read_issue_while_blocked", 429),
                       ("a_block_holds_until_unblock", 560)]:
      m = re.search(rf"{name}\s*\n\s*\S+\n\s*0\s+(\d+)\s+(\d+)", COV)
      chk(m is not None and int(m.group(1)) == passes,
          f"{name}: coverage says {m.group(1) if m else '?'} passes, UG says {passes}")
      chk(f"| `{name}` | {passes} |" in UG, f"UG row for {name} not found with {passes}")

  # cover directive hits
  for name, hits in [("c_write_denied", 4), ("c_read_denied", 4), ("c_write_decerr", 3),
                     ("c_read_decerr", 2), ("c_block_and_recover", 5),
                     ("c_unblock_with_stuck_cmd", 3)]:
      m = re.search(rf"{name}\s*\n.*?\n\s*(\d+) Covered", COV, re.S)
      chk(m is not None and int(m.group(1)) == hits,
          f"{name}: coverage says {m.group(1) if m else '?'} hits, UG says {hits}")
      chk(f"| `{name}` | {hits} |" in UG, f"UG row for {name} not found with {hits}")

  # FSM transition hits
  for tr, w, r in [("IDLE -> EVAL", 23, 23), ("EVAL -> FWD", 17, 16),
                   ("EVAL -> RESP", 5, 6), ("EVAL -> IDLE", 1, 1),
                   ("FWD -> RESP", 14, 13), ("FWD -> IDLE", 3, 3),
                   ("RESP -> IDLE", 19, 19)]:
      for pre, want in (("WR", w), ("RD", r)):
          t = tr.replace("IDLE", f"{pre}_IDLE").replace("EVAL", f"{pre}_EVAL") \
                .replace("FWD", f"{pre}_FWD").replace("RESP", f"{pre}_RESP")
          m = re.search(rf"\s(\d+)\s+{re.escape(t)}\s*$", COV, re.M)
          chk(m is not None and int(m.group(1)) == want,
              f"{t}: coverage says {m.group(1) if m else '?'}, UG says {want}")
      ug = tr.replace(" -> ", " → ")
      chk(f"| {ug} | {w} | {r} |" in UG, f"UG FSM row '{ug}' not found as {w}/{r}")

# ---- 15. figures exist and are referenced -------------------------------
# Image paths are relative to doc/, where the guide lives. Assert the expected
# count as well as existence: a path pattern that silently stops matching
# turns this whole section into a no-op that still reports success.
figs = re.findall(r"\(((?:\w+/)*figures/[\w.]+)\)", UG)
chk(len(figs) == 6, f"expected 6 figure references in the guide, found {len(figs)}")
for f in figs:
    chk(os.path.exists(f"{ROOT}/doc/{f}"), f"referenced figure missing: {f}")

# ---- 16. every Table n / Figure n number is used once, in order ---------
nums = [int(n) for n in re.findall(r"\*\*Table (\d+)\.", UG)]
chk(nums == list(range(1, len(nums) + 1)), f"table numbering not sequential: {nums}")
fnums = [int(n) for n in re.findall(r"\*\*Figure (\d+)\.", UG)]
chk(fnums == list(range(1, len(fnums) + 1)), f"figure numbering not sequential: {fnums}")

# ---- 17. internal anchors resolve --------------------------------------
heads = set()
for h in re.findall(r"^#{1,3} (.+)$", UG, re.M):
    t = re.sub(r"[^\w\s-]", "", h.lower())
    heads.add(re.sub(r"[\s-]+", "-", t).strip("-"))
for a in re.findall(r"\]\(#([\w-]+)\)", UG):
    chk(a in heads, f"dangling internal link: #{a}")

print("\n".join("  FAIL: " + b for b in bad) or "  (no failures)")
if skipped:
    print("  SKIPPED: simulation-result checks - run simulation/questa/run_sim.tcl\n"
          "           to produce coverage_report.txt and run.log, then re-run this.")
print(f"\n{ok} checks passed, {len(bad)} failed"
      + (", 1 group skipped" if skipped else ""))
sys.exit(1 if bad else 0)
