#!/usr/bin/env python3
"""
Cross-check every factual table in the documentation against its source.

A document that has quietly gone out of date is worse than no document, and
none of this is checkable by reading. Every register offset, bit position,
reset value, parameter range, fault code, assertion count and measured result
quoted in the README, the user guide or the block-diagram document is
re-derived here from the RTL, the package, avl_mm_firewall_hw.tcl, the SVA file
and the driver header - and compared. Anything that has drifted fails the run.

This is also why the block-diagram document is Markdown and its figures are
generated from code. The AXI4-Lite sibling's equivalent used to be a zip of
XML, and it sat at a stale version number long after the core had moved on,
because nothing could see inside it to notice.

Usage:  python3 check_facts.py
Exit:   0 if every claim still matches its source, 1 otherwise.
"""
import os
import re
import sys

ROOT = os.path.abspath(os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "..", ".."))


def rd(path):
    with open(os.path.join(ROOT, path), encoding="utf-8") as f:
        return f.read()


def rd_opt(path):
    try:
        return rd(path)
    except OSError:
        return None


UG   = rd("doc/avalon_mm_firewall_user_guide.md")
BD   = rd("doc/avalon_mm_firewall_block_diagrams.md")
RM   = rd("README.md")
PKG  = rd("rtl/avl_mm_firewall_pkg.sv")
TOP  = rd("rtl/avl_mm_firewall_top.sv")
REGS = rd("rtl/avl_mm_firewall_regs.sv")
TCL  = rd("avl_mm_firewall_hw.tcl")
SVA  = rd("tb/avl_mm_firewall_sva.sv")
TB   = rd("tb/avl_mm_firewall_tb.sv")
DRVH  = rd("HAL/inc/altera_avalon_mm_firewall.h")
DRVC  = rd("HAL/src/altera_avalon_mm_firewall.c")
RGSH  = rd("inc/altera_avalon_mm_firewall_regs.h")
SWTCL = rd("avl_mm_firewall_sw.tcl")
FIGS = rd("doc/tools/diagrams/build_figures.py")

# The simulation logs are deliberately gitignored - a stale one lying around in
# a working copy is exactly how wrong numbers get cited as current. So they may
# legitimately be absent. When they are, the checks that depend on them are
# skipped and counted, loudly, rather than silently passing.
LOG0 = rd_opt("simulation/verilator/run_wresp0.log")
LOG1 = rd_opt("simulation/verilator/run_wresp1.log")
HAVE_RUN = LOG0 is not None and LOG1 is not None

bad, ok, skipped = [], 0, 0


def chk(cond, msg):
    global ok
    if cond:
        ok += 1
    else:
        bad.append(msg)


def skip(msg):
    global skipped
    skipped += 1
    print(f"  skipped: {msg}")


# ---- 1. register offsets ------------------------------------------------
# The RTL holds WORD offsets; every document quotes BYTE offsets. That factor
# of four is the single most likely thing in this core to be got wrong in
# prose, so it is checked in both directions.
rtl_woff = {n: int(v, 16) for n, v in
            re.findall(r"WOFF_(\w+)\s*=\s*'h([0-9A-Fa-f]+)", REGS)}
chk(len(rtl_woff) == 8, f"expected 8 WOFF_* in the RTL, found {len(rtl_woff)}")

ALIAS = {"TIMEOUT_VALUE": "TIMEOUT"}

for doc_name, doc in (("user guide", UG), ("README", RM)):
    found = dict((n, int(o, 16)) for o, n in
                 re.findall(r"\|\s*(0x[0-9A-F]{2})\s*\|\s*`?(\w+)`?\s*\|", doc))
    for name, byte_off in found.items():
        key = ALIAS.get(name, name)
        if key not in rtl_woff:
            continue
        chk(rtl_woff[key] * 4 == byte_off,
            f"{doc_name}: {name} at byte 0x{byte_off:02X} but RTL word "
            f"0x{rtl_woff[key]:X} implies byte 0x{rtl_woff[key]*4:02X}")

# every RTL register must appear in the user guide
for key in rtl_woff:
    doc_name = {"TIMEOUT": "TIMEOUT_VALUE"}.get(key, key)
    chk(f"`{doc_name}`" in UG or f"| {doc_name} |" in UG,
        f"RTL register {key} is not documented in the user guide")

# rule table geometry
rule_word_base = int(re.search(r"RULE_WORD_BASE\s*=\s*'h([0-9A-Fa-f]+)",
                               REGS).group(1), 16)
rule_stride = int(re.search(r"RULE_WORD_STRIDE\s*=\s*(\d+)", REGS).group(1))
chk(rule_word_base * 4 == 0x40,
    f"rule table starts at word 0x{rule_word_base:X} = byte "
    f"0x{rule_word_base*4:X}, documents say 0x40")
chk(rule_stride * 4 == 0x10,
    f"rule stride is {rule_stride} words = {rule_stride*4} bytes, "
    "documents say 0x10")
for doc_name, doc in (("user guide", UG), ("README", RM),
                      ("block diagrams", BD)):
    chk("0x40" in doc and "0x10" in doc,
        f"{doc_name} does not quote the rule table base/stride")

# ---- 2. fault / verdict codes -------------------------------------------
pkg_codes = {n: int(v) for n, v in
             re.findall(r"FW_(\w+)\s*=\s*3'd(\d)", PKG)}
EXPECT = {"ALLOW": 0, "ADDR": 1, "PERM": 2, "TIMEOUT": 3,
          "BURST_RANGE": 4, "BURST_DENIED": 5, "BLOCKED": 6}
chk(pkg_codes == EXPECT,
    f"package verdict codes changed: {pkg_codes} vs expected {EXPECT}")

# the driver header must agree with the package
drv_codes = {n: int(v) for n, v in
             re.findall(r"ALTERA_AVALON_MM_FIREWALL_FAULT_(\w+)\s+(\d)\b", RGSH)}
for name, code in (("ADDR", 1), ("PERM", 2), ("TIMEOUT", 3),
                   ("BURST_RANGE", 4), ("BURST_DENIED", 5)):
    chk(drv_codes.get(name) == code,
        f"regs.h FAULT_{name} = {drv_codes.get(name)}, package says {code}")

# ...and so must every prose table that lists them
for doc_name, doc in (("user guide", UG), ("README", RM),
                      ("block diagrams", BD)):
    for label, code in (("ADDR", 1), ("PERM", 2), ("TIMEOUT", 3)):
        chk(re.search(rf"{label}[^|\n]*\|\s*{code}\s*\|", doc) is not None
            or f"{code}=" in doc or f"{code} = " in doc,
            f"{doc_name}: fault code {code} for {label} not found")
    chk("4" in doc and "5" in doc,
        f"{doc_name}: burst fault codes 4/5 not quoted")

# the generated register figure must agree too - it is text, which is the
# entire reason the diagrams are drawn from code
chk("1=ADDR 2=PERM 3=TIMEOUT 4=BURST_RANGE 5=BURST_DENIED" in FIGS,
    "fig_registers bit field no longer lists the five fault codes in order")

# ---- 3. STATUS bit positions --------------------------------------------
# Derived from the concatenation the RTL actually returns, read MSB-first.
m = re.search(r"WOFF_STATUS:\s*csr_readdata <= \{(.*?)\};", REGS, re.S)
chk(m is not None, "could not find the STATUS read mux in the RTL")
if m:
    fields = [f.strip() for f in m.group(1).split(",")]
    # fields[0] is the reserved zero-fill; the rest are one bit each, MSB first
    bits = list(reversed(fields[1:]))
    SRC = {
        0: "reg_addr_violation", 1: "reg_perm_violation",
        2: "reg_timeout_error", 3: "reg_burst_violation",
        4: "isolate_effective", 5: "dstat_blocked",
        6: "dstat_wr_busy", 7: "dstat_rd_busy",
        8: "dstat_wr_cmd_stuck", 9: "dstat_rd_cmd_stuck",
    }
    for pos, sig in SRC.items():
        chk(pos < len(bits) and bits[pos] == sig,
            f"STATUS[{pos}] is {bits[pos] if pos < len(bits) else 'absent'} "
            f"in the RTL, documents assume {sig}")
    chk(fields[0].strip() == "22'b0",
        f"STATUS reserved fill is {fields[0]}, expected 22'b0 for 10 live bits")

# The driver header's STATUS masks must match those positions.
# regs.h states them as masks, so convert back to positions.
drv_status = {}
for n, v in re.findall(
        r"ALTERA_AVALON_MM_FIREWALL_STATUS_(\w+)_MSK\s+\(0x([0-9A-Fa-f]+)\)",
        RGSH):
    m_ = int(v, 16)
    if n != "STICKY":
        chk(m_ and (m_ & (m_ - 1)) == 0,
            f"regs.h STATUS_{n}_MSK 0x{v} is not a single bit")
        drv_status[n] = m_.bit_length() - 1
DRV_EXPECT = {"ADDR_VIOL": 0, "PERM_VIOL": 1, "TIMEOUT": 2, "BURST_VIOL": 3,
              "ISOLATED": 4, "BLOCKED": 5, "WR_BUSY": 6, "RD_BUSY": 7,
              "WR_CMD_STUCK": 8, "RD_CMD_STUCK": 9}
chk(drv_status == DRV_EXPECT,
    f"regs.h STATUS bit positions {drv_status} differ from {DRV_EXPECT}")
sticky = int(re.search(
    r"STATUS_STICKY_MSK\s+\(0x([0-9A-Fa-f]+)\)", RGSH).group(1), 16)
chk(sticky == 0xF, f"regs.h STICKY mask is 0x{sticky:X}, expected 0xF")

# The testbench's own localparams are a third independent copy - if they drift,
# the tests are checking the wrong bits and would still pass.
tb_status = dict(re.findall(r"ST_(\w+)\s*=\s*(\d+)", TB))
for name, pos in (("ADDR", 0), ("PERM", 1), ("TMO", 2), ("BURST", 3),
                  ("ISOL", 4), ("BLOCK", 5), ("WRBSY", 6), ("RDBSY", 7),
                  ("WRSTUCK", 8), ("RDSTUCK", 9)):
    chk(int(tb_status.get(name, -1)) == pos,
        f"testbench ST_{name} = {tb_status.get(name)}, RTL position is {pos}")

# ---- 4. RULE_PERM layout ------------------------------------------------
m = re.search(r"typedef struct packed \{(.*?)\} rule_perm_t;", PKG, re.S)
chk(m is not None, "rule_perm_t not found in the package")
if m:
    order = re.findall(r"logic\s+(\w+);", m.group(1))
    chk(order == ["burst_en", "valid", "wr_en", "rd_en"],
        f"rule_perm_t packs {order}; documents say "
        "[3]=BURST_ALLOW [2]=VALID [1]=WRITE_ALLOW [0]=READ_ALLOW")

drv_perm = {n: int(v, 16).bit_length() - 1 for n, v in
            re.findall(r"ALTERA_AVALON_MM_FIREWALL_PERM_(\w+)_MSK\s+\(0x(\w+)\)",
                       RGSH)}
chk(drv_perm == {"READ": 0, "WRITE": 1, "VALID": 2, "BURST": 3},
    f"regs.h RULE_PERM bits {drv_perm} disagree with rule_perm_t")

tb_perm = {n: int(v) for n, v in re.findall(r"P_(\w+)\s*=\s*(\d+)", TB)}
chk(tb_perm == {"RD": 1, "WR": 2, "VALID": 4, "BURST": 8},
    f"testbench RULE_PERM masks {tb_perm} disagree with rule_perm_t")

# ---- 5. version ---------------------------------------------------------
ver = re.search(r"VERSION16\s*=\s*16'h([0-9A-Fa-f]{4})", REGS).group(1).upper()
chk(ver == "0100", f"RTL version field is 0x{ver}, documents say 0x0100")
for doc_name, doc in (("user guide", UG), ("README", RM),
                      ("block diagrams", BD), ("figures", FIGS)):
    chk(f"0x{ver}" in doc,
        f"{doc_name} does not quote the RTL version 0x{ver}")
chk(f"VERSION_1_0         0x{ver}" in RGSH,
    f"regs.h version constant is not 0x{ver}")
tcl_ver = re.search(r"set_module_property VERSION ([\d.]+)", TCL).group(1)
chk(tcl_ver == "1.0", f"hw.tcl VERSION is {tcl_ver}, expected 1.0")
chk(int(ver, 16) == 0x0100 and tcl_ver == "1.0",
    "hw.tcl VERSION and the RTL version field disagree")

# ---- 6. CORE_INFO layout ------------------------------------------------
m = re.search(r"WOFF_CORE_INFO:\s*csr_readdata <= \{(.*?)\};", REGS, re.S)
chk(m is not None, "could not find the CORE_INFO read mux in the RTL")
if m:
    body = m.group(1)
    chk("VERSION16" in body, "CORE_INFO no longer carries VERSION16")
    chk("$clog2(DATA_WIDTH/8)" in body,
        "CORE_INFO no longer carries log2(bytes per beat)")
    chk("5'(BURST_WIDTH)" in body, "CORE_INFO no longer carries BURST_WIDTH")
    chk("8'(NUM_RULES)" in body, "CORE_INFO no longer carries NUM_RULES")
for doc_name, doc in (("user guide", UG), ("README", RM)):
    for field in ("NUM_RULES", "BURST_WIDTH"):
        chk(field in doc, f"{doc_name}: CORE_INFO field {field} not documented")

# ---- 7. reset values ----------------------------------------------------
chk("reg_global_enable    <= 1'b1;" in REGS,
    "GLOBAL_ENABLE no longer resets set - the core is no longer secure by default")
chk("reg_auto_isolate_en  <= 1'b1;" in REGS,
    "AUTO_ISOLATE_EN no longer resets set")
chk("reg_irq_enable       <= 4'hF;" in REGS, "IRQ_ENABLE no longer resets to 0xF")
chk("reg_timeout_value    <= '1;" in REGS, "TIMEOUT_VALUE no longer resets all-ones")
for doc_name, doc in (("user guide", UG), ("README", RM)):
    chk("0x0000_0003" in doc or "reset **1**" in doc or "reset 1" in doc,
        f"{doc_name} does not state the CTRL reset value")
chk("0x0000_000F" in UG or "0x0000_000F" in UG.replace("_", ""),
    "user guide does not state the IRQ_ENABLE reset value")
# the figure's own annotation
chk("AUTO_ISOLATE_EN   reset 1" in FIGS and "GLOBAL_ENABLE   reset 1" in FIGS,
    "fig_registers no longer annotates the CTRL reset values")

# ---- 8. parameters ------------------------------------------------------
# Defaults come from the RTL; ranges from hw.tcl. Both are quoted in prose.
rtl_par = {n: v.strip() for n, v in
           re.findall(r"parameter int (\w+)\s*=\s*([^,\n]+)", TOP)}
tcl_def = {n: int(v) for n, v in
           re.findall(r"add_parameter (\w+) INTEGER (\d+)", TCL)}
# USE_RESPONSE is declared HDL_PARAMETER false on purpose: it selects which
# ports the component exposes, not how the RTL behaves. Only the HDL ones are
# required to exist on the module.
tcl_hdl = set(re.findall(
    r"set_parameter_property (\w+) HDL_PARAMETER true", TCL))
for name, val in tcl_def.items():
    if name not in tcl_hdl:
        chk(name not in rtl_par,
            f"{name} is HDL_PARAMETER false in hw.tcl but exists on the module")
        continue
    chk(name in rtl_par,
        f"hw.tcl declares {name} but the RTL module has no such parameter")
    if name in rtl_par:
        chk(rtl_par[name].split()[0] == str(val),
            f"{name}: hw.tcl default {val}, RTL default {rtl_par[name]}")

tcl_rng = dict(re.findall(r"set_parameter_property (\w+) ALLOWED_RANGES \{([^}]*)\}",
                          TCL))
DOC_RANGES = {
    "ADDR_WIDTH": "8:32", "BURST_WIDTH": "1:11", "NUM_RULES": "1:64",
    "TIMEOUT_WIDTH": "8:32", "CSR_ADDR_WIDTH": "5:16",
    "MAX_PENDING_READS": "1:32",
}
for name, rng in DOC_RANGES.items():
    chk(tcl_rng.get(name, "").strip() == rng,
        f"{name}: hw.tcl range '{tcl_rng.get(name)}', documents say '{rng}'")
    lo, hi = rng.split(":")
    row = next((ln for ln in UG.splitlines()
                if ln.startswith("|") and f"`{name}`" in ln), None)
    chk(row is not None, f"user guide has no parameter table row for {name}")
    chk(row is not None and lo in row and hi in row,
        f"user guide parameter table row for {name} does not show {lo}-{hi}")

# every HDL parameter must be documented
for name in rtl_par:
    chk(f"`{name}`" in UG, f"RTL parameter {name} is not in the user guide")
    chk(f"`{name}`" in RM, f"RTL parameter {name} is not in the README")

# ---- 8b. register header vs RTL, and the BSP driver package -------------
# regs.h carries BOTH byte offsets and the word indices the RTL decodes. Both
# are checked, because the factor of four between them is the easiest thing to
# get wrong in this core and neither form is self-evidently right.
h_ofst = {n: int(v, 16) for n, v in re.findall(
    r"ALTERA_AVALON_MM_FIREWALL_(\w+)_OFST\s+0x([0-9A-Fa-f]+)$", RGSH, re.M)}
h_reg = {n: int(v) for n, v in re.findall(
    r"ALTERA_AVALON_MM_FIREWALL_(\w+)_REG\s+(\d+)", RGSH)}
for name, word in rtl_woff.items():
    chk(h_reg.get(name) == word,
        f"regs.h {name}_REG = {h_reg.get(name)}, RTL word offset is {word}")
    chk(h_ofst.get(name) == word * 4,
        f"regs.h {name}_OFST = {h_ofst.get(name)}, RTL implies {word * 4}")
chk(h_ofst.get("RULE_TABLE") == rule_word_base * 4,
    f"regs.h RULE_TABLE_OFST = {h_ofst.get('RULE_TABLE')}, "
    f"RTL implies {rule_word_base * 4}")
h_stride = int(re.search(r"RULE_STRIDE\s+0x([0-9A-Fa-f]+)", RGSH).group(1), 16)
chk(h_stride == rule_stride * 4,
    f"regs.h RULE_STRIDE = 0x{h_stride:X}, RTL implies 0x{rule_stride * 4:X}")

# CTRL reset value, stated in three places now.
h_ctrl_rst = int(re.search(r"CTRL_RESET_VALUE\s+\(0x(\w+)\)", RGSH).group(1), 16)
chk(h_ctrl_rst == 0x3,
    f"regs.h CTRL_RESET_VALUE is 0x{h_ctrl_rst:X}; the RTL resets it to 0x3")

# The driver must be built on the register header, not on private copies.
chk('#include "altera_avalon_mm_firewall_regs.h"' in DRVH,
    "the HAL header does not include the register header")
chk('#include "altera_avalon_mm_firewall.h"' in DRVC,
    "the driver source does not include its own header")
chk("IORD_32DIRECT" not in DRVC and "IOWR_32DIRECT" not in DRVC,
    "the driver bypasses the regs.h accessors with raw IORD_32DIRECT/IOWR_32DIRECT")

# ---- 8c. software package description ------------------------------------
tcl_name = re.search(r"set_module_property NAME (\S+)", TCL).group(1)
sw_class = re.search(r"set_sw_property hw_class_name (\S+)", SWTCL).group(1)
chk(sw_class == tcl_name,
    f"_sw.tcl hw_class_name '{sw_class}' does not match _hw.tcl NAME "
    f"'{tcl_name}' - the BSP would silently generate nothing")

sw_ver = re.search(r"set_sw_property version (\S+)", SWTCL).group(1)
sw_min = re.search(r"set_sw_property min_compatible_hw_version (\S+)",
                   SWTCL).group(1)
chk(sw_ver == tcl_ver,
    f"_sw.tcl version {sw_ver} differs from _hw.tcl VERSION {tcl_ver}")
chk(sw_min == tcl_ver,
    f"_sw.tcl min_compatible_hw_version {sw_min} differs from "
    f"_hw.tcl VERSION {tcl_ver}")

# every file the BSP is told to compile must exist
for src in re.findall(r"add_sw_property (?:c_source|include_source) (\S+)", SWTCL):
    chk(os.path.exists(os.path.join(ROOT, src)),
        f"_sw.tcl lists {src}, which does not exist")

# auto_initialize demands the two macros the BSP emits
if re.search(r"set_sw_property auto_initialize true", SWTCL):
    cls = tcl_name.upper()
    for macro in (f"{cls}_INSTANCE", f"{cls}_INIT"):
        chk(f"#define {macro}(" in DRVH,
            f"_sw.tcl sets auto_initialize but the HAL header does not define "
            f"{macro}, which alt_sys_init.c will reference")

# ---- 9. assertions and cover points -------------------------------------
n_assert = len(re.findall(r"assert property", SVA))
n_cover = len(re.findall(r"cover property", SVA))
for doc_name, doc in (("user guide", UG), ("README", RM)):
    chk(str(n_assert) in doc,
        f"{doc_name} does not quote the assertion count {n_assert}")
    chk(str(n_cover) in doc,
        f"{doc_name} does not quote the cover point count {n_cover}")
chk(f"**{n_assert} assertions and {n_cover} cover points**" in UG,
    f"user guide 8.2 should say '{n_assert} assertions and {n_cover} cover points'")
chk(f"{n_assert} assertions and {n_cover} cover points" in RM,
    f"README should say '{n_assert} assertions and {n_cover} cover points'")

# every cover point named in the README must exist in the SVA file
sva_covers = set(re.findall(r"(c_\w+):\s*cover property", SVA))
for name in re.findall(r"`(c_\w+)`", RM):
    chk(name in sva_covers, f"README cites cover point {name}, which does not exist")
chk(len(sva_covers) == n_cover,
    f"{n_cover} cover properties but {len(sva_covers)} distinct names")

# ---- 10. measured results ----------------------------------------------
if HAVE_RUN:
    n0 = len(re.findall(r"^  PASS", LOG0, re.M))
    n1 = len(re.findall(r"^  PASS", LOG1, re.M))
    tot = n0 + n1
    for doc_name, doc in (("user guide", UG), ("README", RM)):
        chk(str(tot) in doc,
            f"{doc_name} quotes a check total that is not {tot}")
        chk(str(n0) in doc and str(n1) in doc,
            f"{doc_name} does not quote the per-run totals {n0} and {n1}")
    for name, log in (("wresp0", LOG0), ("wresp1", LOG1)):
        chk("*** ALL TESTS PASSED ***" in log,
            f"{name} log does not contain the pass marker")
        chk("FAIL:" not in log, f"{name} log contains failures")
        chk("PROTOCOL VIOLATION" not in log,
            f"{name} log contains protocol violations")
else:
    skip("simulation logs absent - check counts not verified. "
         "Run simulation/verilator/run_sim.sh first.")

# ---- 11. throughput claims ---------------------------------------------
# The guard values in the testbench are the contract; prose must not claim
# better than the bench actually enforces.
g_wr = re.search(r"32-beat write burst takes %0d cycles \(<=(\d+)\)", TB)
g_rd = re.search(r"32-beat read burst takes %0d cycles \(<=(\d+)\)", TB)
chk(g_wr is not None and g_rd is not None,
    "throughput guards not found in the testbench")
if g_wr and g_rd:
    for doc_name, doc in (("user guide", UG), ("README", RM)):
        chk(f"above {g_wr.group(1)}" in doc or g_wr.group(1) in doc,
            f"{doc_name}: write guard {g_wr.group(1)} not quoted")
        chk(f"above {g_rd.group(1)}" in doc or g_rd.group(1) in doc,
            f"{doc_name}: read guard {g_rd.group(1)} not quoted")

# ---- 12. figures referenced actually exist ------------------------------
figdir = os.path.join(ROOT, "doc", "figures")
for doc_name, doc in (("user guide", UG), ("block diagrams", BD)):
    for src in re.findall(r"!\[[^\]]*\]\((figures/[^)]+)\)", doc):
        chk(os.path.exists(os.path.join(ROOT, "doc", src.split("/", 1)[1])
                           if False else os.path.join(figdir,
                                                      os.path.basename(src))),
            f"{doc_name} references {src}, which does not exist")

# every generated figure should be referenced by something
if os.path.isdir(figdir):
    for f in sorted(os.listdir(figdir)):
        if f.endswith(".svg"):
            chk(f in UG or f in BD,
                f"figure {f} is generated but referenced by no document")

# ---- 13. file manifest --------------------------------------------------
for path in ("rtl/avl_mm_firewall_pkg.sv", "rtl/avl_mm_firewall_top.sv",
             "rtl/avl_mm_firewall_regs.sv", "tb/avl_mm_firewall_tb.sv",
             "tb/avl_mm_firewall_sva.sv", "avl_mm_firewall_hw.tcl",
             "avl_mm_firewall_sw.tcl",
             "inc/altera_avalon_mm_firewall_regs.h",
             "HAL/inc/altera_avalon_mm_firewall.h",
             "HAL/src/altera_avalon_mm_firewall.c"):
    chk(os.path.exists(os.path.join(ROOT, path)), f"missing file {path}")
    base = os.path.basename(path)
    chk(base in UG or base in RM,
        f"{base} exists but is listed in neither the user guide nor the README")

# hw.tcl must list the package first in both filesets
for fileset in ("QUARTUS_SYNTH", "SIM_VERILOG"):
    idx_pkg = TCL.find("add_fileset_file avl_mm_firewall_pkg.sv",
                       TCL.find(f"add_fileset {fileset}"))
    idx_top = TCL.find("add_fileset_file avl_mm_firewall_top.sv",
                       TCL.find(f"add_fileset {fileset}"))
    chk(0 < idx_pkg < idx_top,
        f"{fileset}: the package must be listed before the top level")

# ---------------------------------------------------------------- report
print()
if bad:
    print(f"check_facts: {len(bad)} MISMATCH(ES), {ok} ok, {skipped} skipped\n")
    for b in bad:
        print("  FAIL:", b)
    sys.exit(1)

print(f"check_facts: {ok} claims verified, {skipped} skipped, 0 mismatches")
sys.exit(0)
