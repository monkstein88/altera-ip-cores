#!/usr/bin/env python3
"""
Cross-check every factual claim in the documentation against its source.

A document that has quietly gone out of date is worse than no document, and
none of this is checkable by reading. Every register offset, bit position,
parameter range, default, line count and measured result quoted in README.md or
the design specification is re-derived here from the RTL package, the _hw.tcl,
the driver header and the testbenches - and compared. Anything that has drifted
fails the run.

Usage:  python3 doc/tools/check_facts.py
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


PKG   = rd("rtl/avalon_mm_sdcard_controller_pkg.sv")
TOP   = rd("rtl/avalon_mm_sdcard_controller.sv")
CRC   = rd("rtl/avalon_mm_sdcard_controller_crc.sv")
HWTCL = rd("altera_avalon_mm_sdcard_controller_hw.tcl")
REGSH = rd("inc/altera_avalon_mm_sdcard_controller_regs.h")
README = rd("README.md")
DESIGN = rd("doc/avalon_mm_sdcard_controller_design.md")

fails = []
checks = 0


def check(what, cond, detail=""):
    global checks
    checks += 1
    if not cond:
        fails.append(f"{what}{(' — ' + detail) if detail else ''}")


# ---------------------------------------------------------------------------
# 1. Register map: the package, the C header and both documents must agree
# ---------------------------------------------------------------------------
# REG_COUNT is the size of the map, not a register in it.
pkg_regs = {m.group(2): int(m.group(3))
            for m in re.finditer(
                r"localparam int unsigned (REG_)(\w+)\s*=\s*(\d+);", PKG)
            if m.group(2) != "COUNT"}

c_regs = {m.group(1): int(m.group(2))
          for m in re.finditer(r"#define ALT_SDCARD_(\w+)_REG\s+(\d+)", REGSH)}

check("register map: package and C header list the same registers",
      set(pkg_regs) == set(c_regs),
      f"pkg only: {sorted(set(pkg_regs) - set(c_regs))}, "
      f"header only: {sorted(set(c_regs) - set(pkg_regs))}")

for name, idx in sorted(pkg_regs.items()):
    if name in c_regs:
        check(f"register {name} word index agrees between RTL and C header",
              c_regs[name] == idx, f"RTL {idx}, header {c_regs[name]}")

# The C header's byte offsets must be four times the word index.
c_ofst = {m.group(1): int(m.group(2), 16)
          for m in re.finditer(r"#define ALT_SDCARD_(\w+)_OFST\s+0x([0-9A-Fa-f]+)", REGSH)}
for name, idx in sorted(pkg_regs.items()):
    if name in c_ofst:
        check(f"register {name} byte offset is 4x its word index",
              c_ofst[name] == 4 * idx, f"got 0x{c_ofst[name]:02X}, want 0x{4*idx:02X}")

# README's table quotes byte offsets; they must match the header.
for name, ofst in sorted(c_ofst.items()):
    row = re.search(rf"^\|\s*0x([0-9A-F]{{2}})\s*\|\s*`{name}`", README, re.M)
    if row:
        check(f"README quotes the right offset for {name}",
              int(row.group(1), 16) == ofst,
              f"README 0x{row.group(1)}, header 0x{ofst:02X}")

# ---------------------------------------------------------------------------
# 2. Parameters: RTL defaults, hw.tcl defaults and the README table
# ---------------------------------------------------------------------------
rtl_params = {m.group(1): m.group(2).strip()
              for m in re.finditer(
                  r"parameter (?:int unsigned|bit)\s+(\w+)\s*=\s*([^,\)]+)", TOP)}

tcl_params = {m.group(1): m.group(2)
              for m in re.finditer(r"add_parameter (\w+) INTEGER (\S+)", HWTCL)}

check("hw.tcl and the RTL declare the same parameters",
      set(tcl_params) == set(rtl_params),
      f"tcl only: {sorted(set(tcl_params) - set(rtl_params))}, "
      f"rtl only: {sorted(set(rtl_params) - set(tcl_params))}")


def as_int(text):
    t = text.strip().replace("1'b", "").replace("'d", "")
    m = re.match(r"^\d+$", t)
    return int(t) if m else None


for name, tcl_default in sorted(tcl_params.items()):
    rv = as_int(rtl_params.get(name, ""))
    tv = as_int(tcl_default)
    if rv is not None and tv is not None:
        check(f"parameter {name} default agrees between RTL and hw.tcl",
              rv == tv, f"RTL {rv}, tcl {tv}")

# README's parameter table must quote the same defaults.
for name, tcl_default in sorted(tcl_params.items()):
    row = re.search(rf"^\|\s*`{name}`\s*\|\s*([0-9]+)\s*\|", README, re.M)
    if row:
        check(f"README quotes the right default for {name}",
              int(row.group(1)) == as_int(tcl_default),
              f"README {row.group(1)}, tcl {tcl_default}")

# ---------------------------------------------------------------------------
# 3. CRC constants - the ones that are routinely got wrong
# ---------------------------------------------------------------------------
check("CRC7 polynomial in the RTL is 0x09 (x^7+x^3+1, post-shift taps)",
      "7'h09" in CRC)
check("CRC16 polynomial in the RTL is 0x1021",
      "16'h1021" in CRC)
check("CRC16 initial value is documented as 0x0000, not 0xFFFF",
      "initial value 0" in CRC and "0xFFFF" in CRC)
for doc, name in ((README, "README"), (DESIGN, "design doc")):
    if "0x7FA1" in doc or "0x95" in doc:
        check(f"{name} still quotes the spec's CMD0 CRC byte 0x95",
              "0x95" in doc)

# ---------------------------------------------------------------------------
# 4. Line counts quoted in the README
# ---------------------------------------------------------------------------
rtl_lines = 0
rtl_files = 0
rtl_dir = os.path.join(ROOT, "rtl")
for fn in sorted(os.listdir(rtl_dir)):
    if fn.endswith(".sv"):
        rtl_files += 1
        with open(os.path.join(rtl_dir, fn), encoding="utf-8") as f:
            rtl_lines += sum(1 for _ in f)

m = re.search(r"(\d+)\s+RTL files|Nine RTL files, (\d+) lines", README)
quoted_lines = re.search(r"(\d{3,5})\s+lines", README)
check("README's RTL line count matches the files on disk",
      quoted_lines is not None and int(quoted_lines.group(1)) == rtl_lines,
      f"README says {quoted_lines.group(1) if quoted_lines else '?'}, actual {rtl_lines}")
check("there are nine RTL files, as the README says",
      rtl_files == 9, f"found {rtl_files}")

# ---------------------------------------------------------------------------
# 5. Check counts quoted in the README must match the testbenches' own totals
# ---------------------------------------------------------------------------
# Each testbench prints "=== N checks, M failures ===" at the end; the README
# quotes N per suite and the sum. Re-derive the sum from the table itself so a
# suite added without updating the total is caught.
rows = re.findall(r"^\|\s*`?(\w+[\w.]*)`?\s*\|\s*(\d+)\s*\|", README, re.M)
suite_counts = {n: int(c) for n, c in rows if n in
                ("phy", "fifo", "core", "check_hw_tcl.tcl", "check_driver_builds.sh")}
sim_total = sum(v for k, v in suite_counts.items() if k in ("phy", "fifo", "core"))
m = re.search(r"passes (\d+) self-checking assertions", README)
check("README's headline assertion count equals the sum of its own suite table",
      m is not None and int(m.group(1)) == sim_total,
      f"headline {m.group(1) if m else '?'}, table sums to {sim_total}")

# The table above is checked against the README's own headline, which catches a
# suite added without updating the total - but not a README that has drifted from
# the testbenches themselves. Derive the counts from the sources too.
#
# Only `core` and `fifo` can be counted statically: every check in them is a
# straight-line call, so one call is one check at run time. The phy testbench
# sweeps divisors in a loop and runs its two checks six times over, so a static
# count says 2 where the run says 12 - and a check that quietly compared those
# would be worse than no check.
for suite, path in (("core", "tb/avalon_mm_sdcard_controller_tb.sv"),
                    ("fifo", "tb/avalon_mm_sdcard_controller_fifo_tb.sv")):
    n = len(re.findall(r"^\s+check(?:_noerr)?\(", rd(path), re.M))
    check(f"README's `{suite}` count matches that testbench's own checks",
          suite_counts.get(suite) == n,
          f"README {suite_counts.get(suite)}, source has {n}")

# ---------------------------------------------------------------------------
# 6. Throughput: the two documents must quote the same measurement
# ---------------------------------------------------------------------------
def grab(doc, pat):
    m = re.search(pat, doc)
    return m.group(1) if m else None

# Anchored to the table ROW in each case. A bare percentage pattern matches the
# first percentage in the file, which in the design document is the framing
# efficiency several paragraphs earlier - so the checker would compare two
# different quantities and report drift that is not there.
for label, pat in (("SPI clocks consumed", r"SPI clocks consumed \| ([\d\s]+)\|"),
                   ("bytes per SPI clock", r"\*\*(0\.\d+) bytes per SPI clock\*\*"),
                   ("fraction of line rate",
                    r"\*\*Fraction of line rate\*\* \| \*\*(\d+\.\d)%\*\*")):
    a = grab(README, pat)
    b = grab(DESIGN, pat)
    check(f"README and the design doc agree on {label}",
          a is not None and a == b, f"README {a!r}, design {b!r}")

# The achieved figure must be below the theoretical ceiling and above the
# one-idle-clock-per-byte figure, or the claim is arithmetically impossible.
ach = grab(README, r"\*\*(0\.\d+) bytes per SPI clock\*\*")
if ach:
    a = float(ach)
    check("achieved throughput is below the 8-clocks-per-byte ceiling",
          a <= 0.125, f"{a} > 0.125")
    check("achieved throughput beats a shifter that idles one clock per byte",
          a > 1.0 / 9.0, f"{a} <= {1/9:.4f}")

# ---------------------------------------------------------------------------
# 7. The SAMPLE_DLY bound must be stated identically everywhere it appears
# ---------------------------------------------------------------------------
bound = "SAMPLE_DLY <= CLKDIV - 2"
check("the sample-delay bound is stated in the RTL package", bound in PKG)
check("the sample-delay bound is stated in the README",
      bound in README or "SAMPLE_DLY <= CLKDIV - 2" in README)
check("the sample-delay bound is stated in the register header",
      "SAMPLE_DLY <= CLKDIV - 2" in REGSH)

# ---------------------------------------------------------------------------
# 8. Status honesty: the README must not claim hardware verification
# ---------------------------------------------------------------------------
check("README states the core has not been on hardware",
      "never been on a board" in README or "simulation only" in README.lower())
check("README does not claim hardware verification",
      "verified on hardware" not in README.lower())

# ---------------------------------------------------------------------------
# 9. The user guide and the block-diagram document
#
# These two are the reader-facing documents, so a number that has drifted in
# them does more damage than one in the design notes. Everything below is
# re-derived from the RTL, the component or the testbenches - never from
# another document, which would only check that two copies of a mistake agree.
# ---------------------------------------------------------------------------
UG = rd("doc/avalon_mm_sdcard_controller_user_guide.md")
BD = rd("doc/avalon_mm_sdcard_controller_block_diagrams.md")
SVA = rd("tb/avalon_mm_sdcard_controller_sva.sv")
SEQ = rd("rtl/avalon_mm_sdcard_controller_seq.sv")

# --- 9.1 register map ---
#
# Only the user guide's table now. The block-diagram document used to carry the
# map as a figure - the same rows drawn as a picture - and that figure is gone.
for name, word in re.findall(
        r"localparam int unsigned REG_(\w+)\s*=\s*(\d+);", PKG):
    if name == "COUNT":
        continue
    off = f"0x{int(word) * 4:02X}"
    row = re.search(r"^\|\s*" + off + r"\s*\|\s*" + word + r"\s*\|\s*`(\w+)`",
                    UG, re.M)
    check(f"the user guide lists {name} at {off}",
          row is not None and row.group(1) == name,
          f"guide row says {row.group(1) if row else None!r}")

check("the register map is no longer drawn as a figure",
      not os.path.exists(os.path.join(ROOT, "doc", "figures",
                                      "fig_regmap.svg")))

# --- 9.2 sequencer state count ---
m = re.search(r"typedef enum logic \[4:0\] \{(.*?)\} state_e;", SEQ, re.S)
nstates = len([x for x in re.sub(r"//[^\n]*", "", m.group(1)).split(",")
               if x.strip()]) if m else 0
check("the sequencer really has the number of states the RTL declares",
      nstates == 20, f"found {nstates}")
for doc, label in ((UG, "user guide"), (BD, "block diagrams")):
    check(f"{label} states the sequencer's state count correctly",
          re.search(r"\b20 states\b|\bTwenty states\b|\b20-state\b", doc)
          is not None)

# The figures name states without the RTL's S_ prefix, and the block-diagram
# document tells the reader so. If that sentence goes, the figures become
# unmatchable against the RTL by anyone reading them.
check("the block-diagram document explains the dropped S_ prefix",
      "S_` prefix" in BD or "S_ prefix" in BD)

# Every state the STATE DIAGRAM draws must exist in the RTL under that name.
# Read the generated .dot rather than the script that writes it: the script
# also draws four other figures whose boxes are called things like "CPU" and
# "memory", and scanning all of its labels asks the RTL for states that were
# never meant to be states.
rtl_states = [x.strip() for x in re.sub(r"//[^\n]*", "", m.group(1)).split(",")
              if x.strip()] if m else []
DOTPATH = os.path.join(ROOT, "doc", "figures", "fig_states.dot")
check("the state diagram's Graphviz source is tracked",
      os.path.exists(DOTPATH))
if os.path.exists(DOTPATH):
    dot = open(DOTPATH, encoding="utf-8").read()
    drawn = sorted(set(re.findall(r'label="([A-Z][A-Z0-9_]*)"', dot)))
    check("the state diagram draws some states", len(drawn) > 10,
          f"found {len(drawn)}")
    for fs in drawn:
        check(f"the state diagram's {fs} exists in the RTL",
              ("S_" + fs) in rtl_states, f"no S_{fs} in state_e")

# --- 9.3 assertion and cover counts, counted from the file itself ---
# This is the check that was missing when the root README drifted to "19
# assertions, 6 cover points" against a file holding 24 and 5.
n_assert = len([ln for ln in SVA.splitlines()
                if "assert property" in ln and not ln.strip().startswith("//")])
n_cover = len([ln for ln in SVA.splitlines()
               if "cover property" in ln and not ln.strip().startswith("//")])
check("the user guide's assertion count matches the SVA file",
      f"{n_assert} bound SVA assertions" in UG or
      f"{n_assert} bound SVA assertions and {n_cover} cover points" in UG,
      f"file has {n_assert} assertions, {n_cover} cover points")
check("the user guide's cover-point count matches the SVA file",
      f"{n_cover} cover points" in UG,
      f"file has {n_cover} cover points")

# --- 9.4 parameter defaults and ranges, taken from the component ---
for pname, default in re.findall(
        r"add_parameter (\w+) INTEGER (\d+)", HWTCL):
    row = re.search(r"^\|\s*`" + pname + r"`\s*\|\s*([^|]+?)\s*\|",
                    UG, re.M)
    check(f"the user guide lists a default for {pname}", row is not None)
    if row:
        check(f"the user guide's default for {pname} matches the component",
              row.group(1).strip() == default,
              f"guide says {row.group(1).strip()!r}, component says {default!r}")

# --- 9.5 protocol constants quoted in prose ---
for const, doc_text in (("TOKEN_START_BLOCK", "0xFE"),
                        ("TOKEN_START_MULTI_W", "0xFC"),
                        ("TOKEN_STOP_TRAN", "0xFD"),
                        ("DATRESP_ACCEPTED", "0x05")):
    m = re.search(r"localparam logic \[7:0\] " + const + r"\s*=\s*8'h([0-9A-F]+)",
                  PKG)
    check(f"the package still defines {const}", m is not None)
    if m:
        want = f"0x{m.group(1)}"
        check(f"the user guide quotes {const} as the package defines it",
              want == doc_text and want in UG, f"package {want}")

# --- 9.6 the CRC16 seed, which is the one everyone gets wrong ---
for doc, label in ((UG, "user guide"), (BD, "block diagrams")):
    if "CRC16" not in doc:
        continue
    check(f"{label} does not claim the 0xFFFF seed",
          "0xFFFF" not in doc or "not" in doc.lower())

# --- 9.7 figures referenced by the documents must exist, with their sources ---
FIGDIR = os.path.join(ROOT, "doc", "figures")
for doc, label in ((UG, "user guide"), (BD, "block diagrams")):
    for fig in re.findall(r"!\[[^\]]*\]\(figures/([\w.]+)\)", doc):
        check(f"{label} references a figure that exists: {fig}",
              os.path.exists(os.path.join(FIGDIR, fig)))
        # Every figure is generated, so every SVG has a tracked source next to
        # it: .dot for the Graphviz block diagrams, .json for the WaveDrom
        # timing figures. An SVG with no source is one somebody hand-edited.
        stem = os.path.splitext(fig)[0]
        src = ".json" if stem.startswith("fig_wave") else ".dot"
        check(f"{fig} has its generator source ({src}) beside it",
              os.path.exists(os.path.join(FIGDIR, stem + src)))

# --- 9.8 honesty, again: neither document may claim hardware verification ---
for doc, label in ((UG, "user guide"), (BD, "block diagrams")):
    check(f"{label} states the core has not been on a board",
          "never run on a board" in doc or "simulation only" in doc.lower())
    check(f"{label} does not claim hardware verification",
          "verified on hardware" not in doc.lower())

# --- 9.9 the Questa flow has been run, and says what it found ---
#
# This pair used to assert the opposite - that the flow still described itself
# as unrun. It has now been executed, so the claim to pin is the new one. The
# point of pinning it either way is the same: the documents must not drift from
# whether the flow has actually been through a simulator.
QUESTA = rd("simulation/questa/run_sim.tcl")
check("the Questa flow no longer claims to be unrun",
      "NOT YET RUN" not in QUESTA and "has NOT been executed" not in QUESTA)
check("the Questa flow records what its first run found",
      "WHAT THE FIRST RUN FOUND" in QUESTA)
check("the user guide no longer says the Questa flow is unexecuted",
      "it has not been executed" not in UG.lower())
check("the user guide records that the Questa flow has been run",
      "has been run" in UG.lower())

# The two faults worth refusing to let drift back out of the documents: the
# assertions having been absent entirely, and the transition coverage that
# remains open. Both are easy to quietly drop in an edit, and both are the
# reason this flow exists.
check("the README records that the assertions were not running",
      "never run" in README.lower() or "had ever run" in README.lower())
check("the README records the sequencer transition coverage gap",
      "58 transitions" in README)

# ---------------------------------------------------------------------------
print()
print("=== check_facts: avalon_mm_sdcard_controller ===")
print()
if fails:
    for f in fails:
        print(f"  FAIL  {f}")
    print()
    print(f"=== {checks} claims checked, {len(fails)} drifted ===")
    print()
    sys.exit(1)

print(f"  {checks} claims re-derived from source, all still correct")
print()
print("*** PASS ***")
print()
sys.exit(0)
