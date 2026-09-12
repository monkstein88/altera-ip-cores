#!/usr/bin/env python3
"""
Cross-check this repository's top-level README against the cores it describes.

    python3 tools/check_readme.py

Exit 0 if every claim still matches its source, 1 otherwise.

-----------------------------------------------------------------------------
WHY THIS EXISTS
-----------------------------------------------------------------------------
Each core carries a doc/tools/check_facts.py that re-derives every number in
ITS OWN documentation from ITS OWN RTL. None of them reads this file. The
README said so itself:

    "Those scripts check their own core and nothing above it. This file is the
     one document in the repository that no tool polices, which is exactly how
     it came to describe the SDRAM controller as never having reached a board,
     two paragraphs after a table saying it had."

That was written after the first time it drifted. It then drifted again: the SD
card controller's status cell claimed 19 assertions and 6 cover points against a
file holding 24 and 5. Nothing caught it, because nothing was looking.

This script looks. It does not try to check prose - most of what this README
says is judgement, and a checker that pretends otherwise would be theatre. It
checks the things that are mechanically derivable and that go stale silently:
counts, file existence, and links.

-----------------------------------------------------------------------------
WHAT IT DOES NOT CHECK
-----------------------------------------------------------------------------
Measured results - throughput, Fmax, board pass counts - are not re-derivable
from the tree. They came from hardware runs and from simulations whose logs are
not tracked. Each core's own check_facts.py holds those against that core's
README, which is the right place for them; this script deliberately does not
duplicate that and does not pretend to verify them.
"""

import os
import re
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                    ".."))
README = open(os.path.join(ROOT, "README.md"), encoding="utf-8").read()

fails = []
checks = 0


def check(what, cond, detail=""):
    global checks
    checks += 1
    if not cond:
        fails.append(f"{what}{(' — ' + detail) if detail else ''}")


def rd(rel):
    p = os.path.join(ROOT, rel)
    if not os.path.exists(p):
        return ""
    with open(p, encoding="utf-8") as f:
        return f.read()


# The four cores that are this repository's own work. The vendor core is
# deliberately not in this list: it has no testbench, no doc/ and no
# check_facts.py, and asserting otherwise would be asserting something false.
ORIGINAL = [
    "altera_avalon_mm_firewall",
    "altera_axi4_lite_firewall",
    "altera_avalon_mm_sdram_controller",
    "altera_avalon_mm_sdcard_controller",
]
VENDOR = "altera_avalon_new_sdram_controller"
ALL_CORES = ORIGINAL + [VENDOR]

# ---------------------------------------------------------------------------
# 1. Every core exists, and is a Platform Designer component
# ---------------------------------------------------------------------------
for core in ALL_CORES:
    check(f"{core}/ exists", os.path.isdir(os.path.join(ROOT, core)))
    check(f"{core} has a README", os.path.exists(
        os.path.join(ROOT, core, "README.md")))
    hw = [f for f in os.listdir(os.path.join(ROOT, core))
          if f.endswith("_hw.tcl")] if os.path.isdir(
              os.path.join(ROOT, core)) else []
    check(f"{core} has a _hw.tcl", len(hw) == 1, f"found {hw}")

# "All five cores appear in the IP Catalog" - so there must be five components.
ncomp = sum(1 for c in ALL_CORES
            if os.path.isdir(os.path.join(ROOT, c))
            and any(f.endswith("_hw.tcl") for f in os.listdir(
                os.path.join(ROOT, c))))
m = re.search(r"All (\w+) cores appear in the IP Catalog", README)
WORDS = {"four": 4, "five": 5, "six": 6}
check("the README's catalog count matches the number of components",
      m is not None and WORDS.get(m.group(1)) == ncomp,
      f"README says {m.group(1) if m else '?'}, tree has {ncomp}")

# ---------------------------------------------------------------------------
# 2. Every relative link resolves
#
# A dead link in the front page of a public repository is the first thing a
# reader hits and the last thing anyone notices.
# ---------------------------------------------------------------------------
for target in re.findall(r"\]\(([^)#][^)]*)\)", README):
    if target.startswith(("http://", "https://", "mailto:")):
        continue
    path = target.split("#", 1)[0]
    if not path:
        continue
    check(f"link resolves: {path}", os.path.exists(os.path.join(ROOT, path)))

# ---------------------------------------------------------------------------
# 3. Assertion and cover-point counts in the status cells
#
# This is the check that was missing when the SD card controller's cell said 19
# and 6 against a file holding 24 and 5. Counted from the bound SVA file rather
# than trusted from any document.
# ---------------------------------------------------------------------------
def sva_counts(core):
    d = os.path.join(ROOT, core, "tb")
    if not os.path.isdir(d):
        return None
    a = c = 0
    for f in sorted(os.listdir(d)):
        if "sva" not in f or not f.endswith(".sv"):
            continue
        for ln in open(os.path.join(d, f), encoding="utf-8"):
            if ln.strip().startswith("//"):
                continue
            a += ln.count("assert property")
            c += ln.count("cover property")
    return a, c


for core in ORIGINAL:
    counts = sva_counts(core)
    check(f"{core} has a bound SVA file", counts is not None and counts[0] > 0)
    if not counts:
        continue
    a, c = counts
    # Find this core's row in the "What's here" table and read any assertion or
    # cover-point figure out of it. A row that does not quote them is fine -
    # not every row does - but one that quotes a wrong number is not.
    row = next((ln for ln in README.splitlines()
                if ln.startswith("| [`" + core + "`]")), None)
    check(f"{core} has a row in the What's here table", row is not None)
    if not row:
        continue
    ma = re.search(r"(\d+) assertions", row)
    mc = re.search(r"(\d+) cover points", row)
    if ma:
        check(f"{core}'s assertion count matches its SVA file",
              int(ma.group(1)) == a, f"README {ma.group(1)}, file {a}")
    if mc:
        check(f"{core}'s cover-point count matches its SVA file",
              int(mc.group(1)) == c, f"README {mc.group(1)}, file {c}")

# ---------------------------------------------------------------------------
# 4. "All four original cores additionally carry a full user guide and an
#    architecture or block-diagram document, in Markdown and PDF, under doc/ —
#    each with a check_facts.py"
#
# This claim was FALSE for most of the SD card controller's life: it had a
# design record and nothing else. It is true now, and this is what keeps it so.
# ---------------------------------------------------------------------------
claim = ("original cores additionally carry a full user guide and an "
         "architecture or")
check("the README still makes the user-guide claim", claim in README.replace(
    "\n", " ").replace("  ", " "))

for core in ORIGINAL:
    d = os.path.join(ROOT, core, "doc")
    files = os.listdir(d) if os.path.isdir(d) else []
    check(f"{core} has a user guide in Markdown",
          any(f.endswith("_user_guide.md") for f in files))
    check(f"{core} has a user guide in PDF",
          any(f.endswith("_user_guide.pdf") for f in files))
    check(f"{core} has a block-diagram or architecture document",
          any(f.endswith(("_block_diagrams.md", "_architecture.md"))
              for f in files))
    check(f"{core} has that document in PDF",
          any(f.endswith(("_block_diagrams.pdf", "_architecture.pdf"))
              for f in files))
    check(f"{core} has a check_facts.py",
          os.path.exists(os.path.join(d, "tools", "check_facts.py")))

# ---------------------------------------------------------------------------
# 5. The simulator table's Questa column
#
# A cell that claims a Questa flow must be backed by a file. A cell that claims
# none must not be.
# ---------------------------------------------------------------------------
# The row has to be found in THIS table and not merely in the file. More than
# one table is keyed by core name - the BSP driver table is too - and a bare
# "first line starting with the core name" lookup silently landed on that one,
# where the cells mean something else entirely. It then hit a length guard and
# skipped, so every check below reported nothing at all while looking green.
# Locate the table by its header and take only the rows that follow it.
def table_rows(header_start):
    lines = README.splitlines()
    for i, ln in enumerate(lines):
        if ln.startswith(header_start):
            rows = []
            for r in lines[i + 2:]:          # skip the |---|---| separator
                if not r.startswith("|"):
                    break
                rows.append(r)
            return rows
    return []


SIMROWS = table_rows("| Core | Verilator | Questa/ModelSim | Icarus |")
check("the simulator table was found", len(SIMROWS) == len(ORIGINAL),
      f"found {len(SIMROWS)} rows, expected {len(ORIGINAL)}")

for core in ORIGINAL:
    row = next((ln for ln in SIMROWS
                if ln.startswith("| `" + core + "` |")), None)
    check(f"{core} has a row in the simulator table", row is not None)
    if not row:
        continue
    cells = [c.strip() for c in row.strip("|").split("|")]
    check(f"{core}'s simulator row has four columns", len(cells) == 4,
          f"got {len(cells)}: {cells}")
    if len(cells) < 3:
        continue
    questa_claimed = cells[2] not in ("—", "-", "")
    has_flow = os.path.exists(
        os.path.join(ROOT, core, "simulation", "questa", "run_sim.tcl"))
    check(f"{core}'s Questa cell matches whether the flow exists",
          questa_claimed == has_flow,
          f"cell {cells[2]!r}, run_sim.tcl present: {has_flow}")
    # The file is the authority, and the cell must agree with it in BOTH
    # directions.
    #
    # This once guarded only one of them - a cell must not claim an unrun flow
    # had been run - on the reasoning that overclaiming is the dangerous
    # direction. It is, but underclaiming is not free: the SD card controller's
    # flow was run, its own tcl said so, and this table went on calling it
    # "never executed" for two commits with the whole suite green. A table that
    # can be wrong in a flattering direction and a table that can be wrong in a
    # modest one are both just a table that can be wrong.
    if has_flow:
        tcl = rd(os.path.join(core, "simulation", "questa", "run_sim.tcl"))
        unrun = "NOT YET RUN" in tcl or "has NOT been executed" in tcl
        cell_says_unrun = ("never executed" in cells[2]
                           or "not run" in cells[2].lower())
        check(f"{core}'s Questa cell agrees with whether the flow has run",
              unrun == cell_says_unrun,
              f"flow declares itself unrun: {unrun}; cell says unrun: "
              f"{cell_says_unrun} ({cells[2]!r})")

    verilator_claimed = cells[1] not in ("—", "-", "")
    check(f"{core}'s Verilator cell matches whether the flow exists",
          verilator_claimed == os.path.exists(
              os.path.join(ROOT, core, "simulation", "verilator",
                           "run_sim.sh")))

# ---------------------------------------------------------------------------
# 6. The layout tree names real directories
# ---------------------------------------------------------------------------
tree = re.search(r"## Layout\s*\n+```\n(.*?)```", README, re.S)
check("the README has a layout tree", tree is not None)
if tree:
    for line in tree.group(1).splitlines():
        m = re.search(r"([A-Za-z0-9_][A-Za-z0-9_./]*)/\s", line)
        if not m:
            continue
        name = m.group(1)
        # Only top-level core directories are unambiguous from the tree's
        # drawing characters; nested entries are indented under whichever core
        # precedes them and are not worth reconstructing here.
        if name in ALL_CORES:
            check(f"the layout tree names a real directory: {name}",
                  os.path.isdir(os.path.join(ROOT, name)))

# ---------------------------------------------------------------------------
# 7. Honesty about the SD card controller
#
# It is the one core with no hardware demonstration. Two places say so, and
# they must not drift apart from each other or from the core's own README.
# ---------------------------------------------------------------------------
SD = "altera_avalon_mm_sdcard_controller"
sd_row = next((ln for ln in README.splitlines()
               if ln.startswith("| [`" + SD + "`]")), None)
check("the SD card controller's status cell says simulation only",
      sd_row is not None and "never on a board" in sd_row.lower())
check("the README still names it as absent from the hardware table",
      "has no board demonstration at all" in README)
check("the hardware results table does not list the SD card controller",
      "SD Card Controller |" not in README)
check("the core's own README agrees it has not been on a board",
      "never been on a board" in rd(f"{SD}/README.md"))

# The check COUNT this file quotes for that core, against the count the core's
# own README quotes - which its check_facts.py in turn re-derives from the
# testbench sources. Chaining it that way rather than counting here keeps one
# definition of the number and still catches a drift at either end.
#
# This is not hypothetical tidying. The assertion and cover-point figures in that
# row were already checked and the surrounding ones were not, so "57 checks" and
# "193 documentation claims" sat stale through two commits that changed both
# while the suite reported green - exactly the fault this file exists to prevent.
sd_readme = rd(f"{SD}/README.md")
m_core = re.search(r"passes (\d+) self-checking assertions", sd_readme)
m_top  = re.search(r"(\d+) checks with the full-core suite", sd_row or "")
check("the SD card controller's check count matches its own README",
      m_core is not None and m_top is not None
      and m_core.group(1) == m_top.group(1),
      f"top-level {m_top.group(1) if m_top else '?'}, "
      f"core README {m_core.group(1) if m_core else '?'}")

# The same figure appears again in the prose that explains why the core is absent
# from the hardware table. Two places quoting one number is two places to forget.
m_prose = re.search(r"What it does have is (\d+) self-checking", README)
check("the absent-core paragraph quotes the same check count",
      m_prose is not None and m_core is not None
      and m_prose.group(1) == m_core.group(1),
      f"paragraph {m_prose.group(1) if m_prose else '?'}, "
      f"core README {m_core.group(1) if m_core else '?'}")

# The documentation-claim count quoted for that core. It has drifted twice - 193
# to 199 to 203 to 219 - because nothing compared it against the checker that
# produces it. check_facts.py needs no simulator and runs in about a second, so
# run it and read its own total rather than restating the number by hand.
import subprocess
_cf = subprocess.run([sys.executable, os.path.join(ROOT, SD, "doc", "tools", "check_facts.py")],
                     capture_output=True, text=True, cwd=os.path.join(ROOT, SD))
_m_ran = re.search(r"(\d+) claims (?:re-derived|checked)", _cf.stdout)
_m_quoted = re.search(r"(\d+) documentation claims", sd_row or "")
check("the SD card controller's documentation-claim count matches check_facts.py",
      _m_ran is not None and _m_quoted is not None
      and _m_ran.group(1) == _m_quoted.group(1),
      f"top-level {_m_quoted.group(1) if _m_quoted else '?'}, "
      f"check_facts.py {_m_ran.group(1) if _m_ran else '?'}")

# The Questa column is covered by the generic per-core check above, which is
# now bidirectional - no SD-specific version is needed.

# The synthesis figures, against the core's own README rather than restated from
# memory. This file quoted a check count and a documentation-claim count that had
# been wrong for two commits, so numbers about that core get pinned here now.
# The two documents word these differently - a table row in the core's README, a
# sentence here - so each needs its own pattern. Comparing the captured numbers is
# the point, not the phrasing.
# The phrase "N logic cells" is reserved for the CURRENT figure. Historical
# numbers - the 10118 the buffer used to cost - are written without it, so that
# this check can be about every occurrence rather than the first one and still
# leave room to say what the number used to be.
#
# EVERY occurrence in this file, not the first one. Both figures are quoted twice
# here - once in the What's here row and once in the prose - and a check that
# looked only at the first would pass while the second drifted. That is precisely
# how the stale check count survived, so it is not a hypothetical.
for label, pat_top, pat_core in (
        ("logic-cell count", r"(\d+) logic cells", r"Logic cells \| (\d+) /"),
        ("Fmax", r"\*\*(\d+)\.\d+ MHz\*\*", r"\*\*(\d+)\.\d+ MHz\*\*")):
    tops   = re.findall(pat_top, README)
    m_core = re.search(pat_core, sd_readme)
    check(f"the top-level quotes the SD card controller's {label} at all",
          len(tops) > 0 and m_core is not None)
    if tops and m_core:
        bad = sorted({t for t in tops if t != m_core.group(1)})
        check(f"every {label} the top-level quotes matches the core's README",
              not bad,
              f"core README {m_core.group(1)}, top-level also has {', '.join(bad)}")

# The core deliberately infers one memory block, so the blanket claim that no core
# does must not come back - it cost 10118 logic cells to avoid.
#
# Matched as the original SENTENCE rather than as the phrase. The prose that
# retired the claim quotes it in order to say it was given up, so a bare
# substring test fails on the very text that fixed it.
check("the top-level does not claim the cores infer no memory",
      "no vendor attributes and no inferred memory" not in README)
check("the top-level says which core infers memory",
      "infer one memory block" in README)

# ---------------------------------------------------------------------------
print()
print("=== check_readme: altera-ip-cores ===")
print()
if fails:
    for f in fails:
        print(f"  FAIL  {f}")
    print()
    print(f"=== {checks} claims checked, {len(fails)} drifted ===")
    print()
    sys.exit(1)

print(f"  {checks} claims re-derived from the tree, all still correct")
print()
print("*** PASS ***")
print()
sys.exit(0)
