#!/usr/bin/env python3
"""
check_facts.py - re-derive every number in doc/ from the RTL and the component.

Run from the core directory:

    python3 doc/tools/check_facts.py

WHY
---
Documentation drifts silently. A parameter default changes, a port is added, a
measured figure is updated in one table and not the other, and every document
goes on stating the old value with complete confidence. Nothing about a
Markdown file objects.

So every number quoted in the user guide, the block-diagram document, the core
README and the figures is re-derived here from the thing it describes - the
RTL, the _hw.tcl, the preset - and compared. If they disagree, this fails.

It cannot check taste or prose. It checks facts.
"""
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
DOC = os.path.dirname(HERE)
ROOT = os.path.dirname(DOC)


def rd(rel):
    with open(os.path.join(ROOT, rel), encoding="utf-8") as f:
        return f.read()


RTL = rd("rtl/avalon_mm_sdram_controller.sv")
TCL = rd("altera_avalon_mm_sdram_controller_hw.tcl")
QPRS = rd("altera_avalon_mm_sdram_controller.qprs")
UG = rd("doc/avalon_mm_sdram_controller_user_guide.md")
BD = rd("doc/avalon_mm_sdram_controller_block_diagrams.md")
RM = rd("README.md")
BENCH = rd("benchmark/README.md")
TB = rd("tb/avalon_mm_sdram_controller_tb.sv")
SVA = rd("tb/avalon_mm_sdram_controller_sva.sv")

fails, passes = [], 0


def chk(cond, msg):
    global passes
    if cond:
        passes += 1
    else:
        fails.append(msg)


# ---------------------------------------------------------- 1. parameters
# Every parameter in the RTL must appear in the user guide with the RTL's
# default, and the guide must not invent parameters that do not exist.
# Two sets: those with a plain numeric default, whose value can be compared,
# and every parameter name, including the ones defaulted to an expression
# (ADDR_W is ROW_BITS + COL_BITS + BANK_BITS). Collecting only the first set
# and then testing the guide against it reports every derived parameter as one
# the RTL does not have.
rtl_params = dict(re.findall(r"parameter int\s+(\w+)\s*=\s*([0-9_]+)\s*[,)]", RTL))
rtl_all = set(re.findall(r"parameter (?:int|bit)\s+(\w+)\s*=", RTL))
chk(len(rtl_params) >= 20,
    f"expected at least 20 integer parameters in the RTL, found {len(rtl_params)}")
chk(rtl_params.keys() <= rtl_all,
    "parameter name collection disagrees with itself")

def ug_row(name):
    """The user guide's table row for a parameter, split into cells.

    Split into CELLS, not searched as a line. Searching the whole row for the
    default value passes whenever that value also appears in the range column -
    "8" is in "2, 4, 8, 16, 32" - so a drifted default reads as correct. That
    is exactly the fault this check exists to catch, and it did not.
    """
    m = re.search(r"^\|\s*`" + re.escape(name) + r"`\s*\|([^\n]*)$", UG, re.M)
    if not m:
        return None
    return [c.strip() for c in m.group(1).split("|")]


def cell_has(cell, val):
    """Does a table cell state this number? Tolerates 60 000 for 60000."""
    return val in {t.replace("\u2009", "").replace(" ", "")
                   for t in re.findall(r"[\d ]+", cell)} or \
           val in re.findall(r"\d+", cell.replace(" ", ""))


for name, dflt in rtl_params.items():
    if name == "ADDR_W":            # derived; the guide says so rather than a number
        chk(f"`{name}`" in UG, f"derived parameter {name} is not mentioned in the UG")
        continue
    chk(f"`{name}`" in UG, f"RTL parameter {name} is not documented in the UG")
    val = str(int(dflt.replace("_", "")))
    cells = ug_row(name)
    chk(cells is not None, f"{name} has no parameter-table row in the UG")
    if cells:
        # EXACTLY the default cell, not "one of the first few numeric cells".
        # The range column almost always contains the default as one of its
        # options - 8 is in "2, 4, 8, 16, 32" - so accepting any nearby cell
        # makes a drifted default indistinguishable from a correct one.
        # The geometry table carries a Type column; the others do not.
        dflt_cell = cells[1] if cells and cells[0] == "Integer" else cells[0]
        chk(cell_has(dflt_cell, val),
            f"UG gives {name} a default of \"{dflt_cell}\", the RTL says {val}")

for name in re.findall(r"^\|\s*`(\w+)`\s*\|\s*Integer", UG, re.M):
    chk(name in rtl_all, f"UG documents parameter {name}, which the RTL does not have")

# ---------------------------------------------------- 2. allowed ranges
# What the component permits must be what the guide says it permits.
for name, rng in re.findall(r"set_parameter_property (\w+) ALLOWED_RANGES \{([^}]*)\}", TCL):
    if name.endswith("_NS"):
        continue                     # the guide gives these in picoseconds
    row = re.search(r"^\|\s*`" + name + r"`\s*\|([^\n]*)$", UG, re.M)
    if not row:
        continue
    nums = re.findall(r"\d+", rng)
    if not nums:
        continue
    lo, hi = nums[0], nums[-1]
    chk(lo in row.group(1) and hi in row.group(1),
        f"UG row for {name} does not show the component's range {rng}: {row.group(1).strip()}")

# ---------------------------------------------------------- 3. port count
ports = re.search(r"\n\) \(\n(.*?)\n\);", RTL, re.S)
chk(ports is not None, "could not find the RTL port list")
n_ports = len(re.findall(r"^\s*(?:input|output|inout)\s", ports.group(1), re.M))
m = re.search(r"^(\d+) ports\.", UG, re.M)
chk(m is not None, "the UG does not state a port count")
if m:
    chk(int(m.group(1)) == n_ports,
        f"UG says {m.group(1)} ports, the RTL has {n_ports}")

# every port name in the RTL must be in the UG's signal tables
for p in re.findall(r"^\s*(?:input|output|inout)\s+(?:logic|wire)\s*(?:\[[^\]]*\]\s*)?(\w+)",
                    ports.group(1), re.M):
    chk(f"`{p}`" in UG, f"RTL port {p} is not in the UG's signal tables")

# ------------------------------------------------------- 4. address map
# The bit positions in the guide and in the figure generator must be the ones
# the RTL actually decodes.
row_bits = int(rtl_params["ROW_BITS"])
col_bits = int(rtl_params["COL_BITS"])
bank_bits = int(rtl_params["BANK_BITS"])
addr_w = row_bits + col_bits + bank_bits

chk(f"`ADDR_W` | Integer | {addr_w}" in UG or f"| {addr_w} | derived" in UG,
    f"the UG does not state the derived ADDR_W of {addr_w}")

# ADDR_MAP 0: bank[0] at COL_BITS, row above it, bank[1] at the top
b1 = col_bits + 1 + row_bits
expect = [f"addr[{b1}]", f"addr[{b1-1}:{col_bits+1}]",
          f"addr[{col_bits}]", f"addr[{col_bits-1}:0]"]
for e in expect:
    chk(e in UG or e in BD,
        f"neither document states {e} for the compatible address map")

# and the RTL must actually do that
chk("b[0] = a[COL_BITS];" in RTL,
    "the RTL no longer places bank[0] directly above the column")
chk("b[i] = a[COL_BITS + ROW_BITS + i];" in RTL,
    "the RTL no longer places the upper bank bits at the top")

# ------------------------------------------------- 5. performance figures
# The same measured table appears in four places. They must agree.
def perf(text):
    rows = {}
    inside = False
    for ln in text.splitlines():
        if ln.startswith("|") and "Intel's core" in ln and ("This core" in ln
                                                            or "Custom core" in ln):
            inside = True
            continue
        if inside:
            if not ln.startswith("|"):
                break
            m = re.match(r"\|\s*\*{0,2}([\w+/ -]+?)\*{0,2}\s*\|\s*([\d.]+)\s*\|"
                         r"\s*\*{0,2}([\d.]+)\*{0,2}\s*\|", ln)
            if m:
                rows[m.group(1).strip()] = (m.group(2), m.group(3))
    return rows


tables = {"user guide": perf(UG), "core README": perf(RM),
          "benchmark README": perf(BENCH)}
for nm, t in tables.items():
    chk(len(t) >= 6, f"could not parse the performance table from the {nm} "
                     f"(found {len(t)} rows)")
ref_name, ref = next(iter(tables.items()))
for nm, t in tables.items():
    for k in set(ref) & set(t):
        chk(ref[k] == t[k],
            f'performance row "{k}" disagrees: {ref_name} {ref[k]} vs {nm} {t[k]}')

# ------------------------------------------------------- 6. the preset
# Every value the preset carries must be legal for the parameter it sets.
for name, val in re.findall(r'<parameter name="(\w+)"\s+value="([^"]+)"', QPRS):
    m = re.search(r"set_parameter_property " + name + r" ALLOWED_RANGES \{([^}]*)\}", TCL)
    chk(re.search(r"add_parameter " + name + r"\b", TCL) is not None,
        f"the preset sets {name}, which the component does not declare")

# CAS latency in the preset must match what the docs quote
cas = re.search(r'name="CAS_LAT"\s+value="(\d+)"', QPRS)
chk(cas is not None, "the preset does not set CAS_LAT")
if cas:
    chk(f"CAS {cas.group(1)}" in UG or f"CAS_LAT` | Integer | {cas.group(1)}" in UG,
        f"the UG does not quote the preset's CAS latency of {cas.group(1)}")

# --------------------------------------------------- 7. verification counts
# The UG quotes how many checks each flow runs. Those come from the sources.
n_sva_assert = len(re.findall(r":\s*assert property", SVA))
n_sva_cover = len(re.findall(r":\s*cover property", SVA))
chk(n_sva_assert > 0, "the SVA file contains no assertions")
chk(n_sva_cover > 0, "the SVA file contains no cover points")

n_tests = len(re.findall(r"start_test\(", TB))
chk(n_tests >= 10, f"expected at least 10 named tests in the testbench, found {n_tests}")

for noun, truth in (("assertions", n_sva_assert), ("cover points", n_sva_cover)):
    for doc_name, doc in (("user guide", UG), ("block diagrams", BD), ("README", RM)):
        for m in re.finditer(r"(\d+)\s+" + noun.replace(" ", r"\s+") + r"\b", doc):
            chk(int(m.group(1)) == truth,
                f"the {doc_name} says {m.group(1)} {noun}, the SVA file has {truth}")

# --------------------------------------------------------- 8. figures
# Every figure referenced must exist, and every figure built must be used.
refs = set(re.findall(r"\]\((figures/[\w.]+)\)", BD)) | \
       set(re.findall(r"\]\((figures/[\w.]+)\)", UG))
for r in sorted(refs):
    chk(os.path.exists(os.path.join(DOC, r)), f"{r} is referenced but does not exist")

built = {f"figures/{f}" for f in os.listdir(os.path.join(DOC, "figures"))
         if f.endswith(".svg")}
for b in sorted(built - refs):
    chk(False, f"{b} is generated but referenced by no document")

# figure numbering must be sequential, and every figure captioned
nums = [int(n) for n in re.findall(r"^\*\*Figure (\d+)\.", BD, re.M)]
chk(nums == list(range(1, len(nums) + 1)),
    f"figure numbering in the block-diagram document is not sequential: {nums}")
chk(len(nums) == len(built),
    f"{len(built)} figures are generated but {len(nums)} are captioned")

# --------------------------------------------------------- 9. status
# Both boards have now run. This rule has been rewritten twice as that changed,
# which is the point of having it: it pins the claim that is easiest to get
# wrong and most misleading when it is.
#
# It began as "nothing may claim a hardware result, there is no board", became
# "a hardware result must name the DE0-Nano, because that is the only one that
# has run", and is now "a hardware result must name the board it happened on".
# Both parts are exercised: the DE0-Nano's IS42S16160B-7 with a 9-bit column
# and 32 MByte, the DE10-Lite's IS42S16320D-7 with a 10-bit column and 64.
#
# What is still worth checking is that a result is ATTRIBUTED. "Passes on
# hardware" with no board named is the sentence that silently becomes false
# when a third part is added. Warnings, negations and the other core's
# measurements are not results and are not matched: the check is deliberately
# narrow, because a rule with false positives is a rule someone deletes.
BOARDS = ("DE0-Nano", "DE10-Lite")
RESULT_ON_HW = re.compile(
    r"[^.\n]*\b(pass(?:ed|es)?|ran|run|measured|verified)\b[^.\n]{0,60}"
    r"\b(on hardware|on a board|on silicon|on the board)\b[^.\n]*", re.I)
for doc_name, doc in (("user guide", UG), ("core README", RM)):
    for m in RESULT_ON_HW.finditer(doc):
        sent = m.group(0)
        if re.search(r"\bnot\b|\bnever\b|\byet\b|\bno\b|\bcannot\b|"
                     r"\bunproven\b|\bwould\b|\bonly\b", sent, re.I):
            continue                      # a caveat, not a claim
        # The documents legitimately cite the 194 MB/s that INTEL's example
        # measured on a board. That is a true, correctly attributed statement
        # about the other core, and a check that flags it is a check someone
        # deletes.
        if re.search(r"SDRAM example|Intel", sent, re.I):
            continue
        near = doc[max(0, m.start()-400):m.start()]
        chk(any(b in sent or b in near for b in BOARDS),
            f"the {doc_name} claims a hardware result without naming the board "
            f"it happened on: \"{sent.strip()[:70]}\"")

    # The mirror image, and the reason this rule exists in both directions: an
    # understated claim is as wrong as an overstated one. "Never been
    # programmed into a part" was true of the whole project, then true only of
    # the DE10-Lite, and is now true of neither. Nothing may say it.
    # "has NOT been programmed" is a different spelling from "has NEVER been
    # programmed", and the first one sat in the user guide's limitations table
    # for a whole commit after both boards had run, because only the second was
    # listed here. Match the negation, not one phrasing of it.
    for m in re.finditer(r"[^.\n]*\b(?:never|not)\s+(?:been\s+)?"
                         r"(?:programmed|run)\b[^.\n]*|"
                         r"[^.\n]*\b(?:never been on a board|"
                         r"not yet run on hardware)\b[^.\n]*", doc, re.I):
        sent = m.group(0)
        chk(False,
            f"the {doc_name} says a design has never been on a board; both "
            f"have now run: \"{sent.strip()[:70]}\"")

# ------------------------------- 9b. the presets and the testbenches agree
# Every preset must name a part the benchmark and the testbench can actually
# be pointed at, and the figures in those testbenches must be the preset's.
# They are separate copies of a datasheet, and a copy nobody checks is exactly
# how one of them drifts.
BENCH_TB = rd("benchmark/sdram_bench_tb.sv")

presets = {}
for blk in re.findall(r"<preset\b.*?</preset>", QPRS, re.S):
    nm = re.search(r'name="([^"]+)"', blk)
    vals = dict(re.findall(r'<parameter name="(\w+)"\s+value="([^"]+)"', blk))
    if nm:
        presets[nm.group(1)] = vals

chk(len(presets) >= 2,
    f"expected at least two device presets, found {len(presets)}")

# A preset name containing a parenthesis or a comma loads and then cannot be
# found by apply_preset - see the .qprs header.
for nm in presets:
    chk(not re.search(r"[(),]", nm),
        f'preset name "{nm}" contains a parenthesis or comma, which '
        f"apply_preset cannot then find")

# The benchmark's PART table, which mirrors the presets.
def bench_part(idx, key):
    """The bench testbench's value for PART==idx, e.g. COL_BITS or T_RC_PS."""
    m = re.search(rf"localparam int\s+{key}\s*=\s*\(PART == 1\)\s*\?\s*"
                  rf"([0-9_]+)\s*:\s*([0-9_]+);", BENCH_TB)
    if not m:
        return None
    return int(m.group(1 if idx == 1 else 2).replace("_", ""))

# Match presets to PART indices by the part number in their name.
part_of = {}
for nm in presets:
    if "IS42S16320D" in nm:
        part_of[0] = nm
    elif "IS42S16160B" in nm:
        part_of[1] = nm

chk(set(part_of) == {0, 1},
    f"the benchmark knows two parts; the presets name {sorted(part_of)}")

for idx, nm in sorted(part_of.items()):
    pv = presets[nm]
    got = bench_part(idx, "COL_BITS")
    chk(got is not None, "could not read COL_BITS from the benchmark's part table")
    if got is not None:
        chk(str(got) == pv.get("COL_BITS"),
            f'"{nm}": preset COL_BITS is {pv.get("COL_BITS")}, '
            f"the benchmark uses {got}")
    for ps_key, ns_key in (("T_RC_PS", "T_RC_NS"), ("T_RAS_PS", "T_RAS_NS"),
                           ("T_RP_PS", "T_RP_NS"), ("T_RCD_PS", "T_RCD_NS"),
                           ("T_RRD_PS", "T_RRD_NS"), ("T_WR_PS", "T_WR_NS"),
                           ("T_MRD_PS", "T_MRD_NS"), ("T_RFC_PS", "T_RFC_NS")):
        got = bench_part(idx, ps_key)
        want = pv.get(ns_key)
        if got is None or want is None:
            chk(False, f'"{nm}": cannot compare {ps_key} against {ns_key}')
        else:
            chk(abs(got - float(want) * 1000.0) < 0.5,
                f'"{nm}": preset {ns_key} is {want} ns, the benchmark uses '
                f"{ps_key} = {got} ps")

# ------------------------------------------- 10. the throughput table is real
# Section 5 above compares the three copies of the performance table against
# EACH OTHER. That is necessary and not sufficient: all three agreed on 197.6
# and 196.0 for a year while the benchmark printed 197.7 and 196.1, because
# nothing ever compared the documents to the tool that produced them.
#
# So run it. The custom core needs no Quartus, so this costs a Verilator build
# and about a second of simulation. Skipped, loudly, if Verilator is missing.
def bench_rows():
    """Run benchmark/ for the custom core and return {pattern: MB/s string}."""
    import shutil, subprocess, tempfile
    if not shutil.which("verilator"):
        return None
    with tempfile.TemporaryDirectory() as td:
        build = subprocess.run(
            ["verilator", "--binary", "--timing", "--assert",
             "-Wno-WIDTHEXPAND", "-Wno-WIDTHTRUNC", "-Wno-DECLFILENAME",
             "-Wno-INITIALDLY", "-Wno-BLKSEQ", "-Wno-PROCASSINIT",
             "-MAKEFLAGS", "VK_PCH_I_FAST= VK_PCH_I_SLOW=",
             "-DDUT_MODULE=avalon_mm_sdram_controller",
             "--top-module", "sdram_bench_tb", "-o", "bench", "-Mdir", td,
             os.path.join(ROOT, "rtl/avalon_mm_sdram_controller.sv"),
             os.path.join(ROOT, "tb/sdram_device_model.sv"),
             os.path.join(ROOT, "benchmark/sdram_traffic_gen.sv"),
             os.path.join(ROOT, "tb/sdram_timing_check.sv"),
             os.path.join(ROOT, "benchmark/sdram_bench_tb.sv")],
            capture_output=True, text=True)
        if build.returncode != 0:
            return {"__build_failed__": build.stderr[-400:]}
        run = subprocess.run([os.path.join(td, "bench")],
                             capture_output=True, text=True)
        rows = {}
        for ln in run.stdout.splitlines():
            # Parsed from the RIGHT, against the fixed trailing columns, not
            # by assuming the pattern column is wide enough for its longest
            # name. It was not: "4-bank same row" ran into the cycle count.
            m = re.match(r"\s{2}(.+?)\s+(\d+)\s+(\d+)\s+([\d.]+)\s+[\d.]+%\s+\S",
                         ln)
            if m:
                rows[m.group(1).strip()] = m.group(4)
        return rows


measured = bench_rows()
if measured is None:
    print("check_facts: note - verilator not found, "
          "the throughput table was compared only against itself")
elif "__build_failed__" in measured:
    chk(False, "the benchmark did not build, so the throughput table is "
               f"unverified: {measured['__build_failed__']}")
else:
    chk(len(measured) >= 6,
        f"the benchmark printed {len(measured)} patterns, expected at least 6")
    for name, (intel, custom) in tables["user guide"].items():
        chk(name in measured,
            f'the documents quote a pattern "{name}" the benchmark does not print')
        if name in measured:
            chk(measured[name] == custom,
                f'"{name}": the documents say {custom} MB/s, '
                f"the benchmark measures {measured[name]}")

# ---------------------------------------------------------------- report
print(f"check_facts: {passes} claims verified, {len(fails)} mismatches")
if fails:
    print()
    for f in fails:
        print(f"  FAIL  {f}")
    sys.exit(1)
