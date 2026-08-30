#!/usr/bin/env python3
"""
check_docs.py - verify the repository's own documentation against the repository.

WHY THIS EXISTS
---------------
Each core already checks its own documents: altera_axi4_lite_firewall and
altera_avalon_mm_firewall both carry a doc/tools/check_facts.py that re-derives
every register offset, bit position, parameter range and assertion count quoted
anywhere under doc/, and fails if any has drifted.

Nothing checked the TOP-LEVEL README, and it drifted. A fourth core was added
and the root document went on saying "three cores" in five places, listed three
directories in its layout, and - the part that actually mattered - carried a
Licence section that said "the two firewalls are MIT licensed" and "if you take
only the firewalls, only the MIT licence applies", leaving the new core in a
licensing gap. That is not a typo; it is the one claim in the repository a
reader is entitled to rely on.

So the root README gets the same treatment the cores get. Every check here is a
claim that can be re-derived from the repository itself.

    python3 tools/check_docs.py
"""
import os, re, subprocess, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
README = open(os.path.join(ROOT, "README.md"), encoding="utf-8").read()

fails, passes = [], 0


def chk(cond, msg):
    global passes
    if cond:
        passes += 1
    else:
        fails.append(msg)


def tracked(pattern):
    out = subprocess.run(["git", "-C", ROOT, "ls-files", pattern],
                         capture_output=True, text=True).stdout.split()
    return [f for f in out if "/db/" not in f]


# ---------------------------------------------------------------- 1. cores
# Every top-level component directory - defined as one holding a _hw.tcl at its
# own top level - must be described, linked and licensed by the root README.
cores = sorted({f.split("/")[0] for f in tracked("*_hw.tcl")
                if f.count("/") == 1})
chk(len(cores) >= 3, f"expected at least 3 component directories, found {cores}")

for c in cores:
    chk(f"[`{c}`]({c}/README.md)" in README,
        f"{c} is not linked from the root README's component table")
    chk(f"{c}/" in README,
        f"{c} does not appear in the root README's layout block")

# A count stated in prose has to match the number of directories that exist.
words = {"one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6}
for m in re.finditer(r"\b(one|two|three|four|five|six)\s+cores\b", README, re.I):
    chk(words[m.group(1).lower()] == len(cores),
        f'root README says "{m.group(0)}" but the repository has {len(cores)}')

# ---------------------------------------------------------- 2. catalog groups
# The group quoted in the README must be the group the component actually
# declares, or the core is not where the reader is told to look for it.
for tcl in tracked("*_hw.tcl"):
    if tcl.count("/") != 1:
        continue
    txt = open(os.path.join(ROOT, tcl), encoding="utf-8").read()
    m = re.search(r"set_module_property\s+GROUP\s+\{?\"?([^\"\}\n]+)", txt)
    chk(m is not None, f"{tcl} declares no GROUP")
    if not m:
        continue
    group = " / ".join(x.strip() for x in m.group(1).strip().split("/"))
    ver = re.search(r"set_module_property\s+VERSION\s+\{?\"?([0-9.]+)", txt)

    # The group and version are compared against the component TABLE ROW, not
    # against the file at large. An existence check - "does this group string
    # appear anywhere in the README" - passes even when the README sends the
    # reader to the wrong subgroup, because the same parent group appears in
    # several rows and one correct mention hides an incorrect one. Prose cannot
    # be checked reliably, so the claim lives in a parsable cell instead.
    core = tcl.split("/")[0]
    row = [ln for ln in README.splitlines()
           if ln.startswith("|") and f"[`{core}`]" in ln]
    chk(len(row) == 1, f"{core} should have exactly one component-table row, "
                       f"found {len(row)}")
    if len(row) != 1:
        continue
    cells = [c.strip() for c in row[0].strip("|").split("|")]
    catalog = cells[1] if len(cells) > 1 else ""
    chk(group in catalog,
        f'{tcl} declares catalog group "{group}", but the root README\'s row '
        f'for {core} says: {catalog}')
    if ver:
        chk(f"v{ver.group(1)}" in catalog,
            f'{tcl} declares VERSION {ver.group(1)}, but the root README\'s '
            f'row for {core} says: {catalog}')

# ------------------------------------------------------------- 3. licensing
# Every component directory must be named in the Licence section, and the
# section must not claim a subset is the whole.
lic = README.split("### Licence")[-1] if "### Licence" in README else ""
chk(lic, "root README has no '### Licence' section")
for c in cores:
    chk(c in lic, f"{c} is not named in the root README's Licence section")

# A directory with a NOTICE is third-party; it must be excluded from MIT, and
# one without must not be.
for c in cores:
    has_notice = os.path.exists(os.path.join(ROOT, c, "NOTICE"))
    near = [ln for ln in lic.splitlines() if c in ln]
    if has_notice:
        chk(any(re.search(r"not MIT|excluded|Intel's own terms", ln, re.I)
                for ln in near),
            f"{c} has a NOTICE (third-party) but the Licence section does not "
            f"exclude it from MIT")
    else:
        chk(any("MIT" in ln for ln in near),
            f"{c} has no NOTICE (so it is ours) but the Licence section does "
            f"not place it under MIT")

chk(not re.search(r"only the firewalls,?\s+only the MIT", lic, re.I),
    "Licence section still says 'if you take only the firewalls' - that "
    "excluded the SDRAM controller from the MIT grant")

# ------------------------------------------------ 4. LICENSE / NOTICE files
chk(os.path.exists(os.path.join(ROOT, "LICENSE")), "no LICENSE at the root")
lic_txt = open(os.path.join(ROOT, "LICENSE"), encoding="utf-8").read()
chk("MIT License" in lic_txt, "root LICENSE is not the MIT licence")
chk(re.search(r"Copyright \(c\) \d{4}", lic_txt) is not None,
    "root LICENSE has no copyright line")

for c in cores:
    n = os.path.join(ROOT, c, "NOTICE")
    if os.path.exists(n):
        t = open(n, encoding="utf-8").read()
        chk("MIT" in t and "does NOT apply" in t.replace("not apply", "NOT apply"),
            f"{c}/NOTICE does not state that the MIT licence does not apply")

# ------------------------------------------------------- 5. internal links
def slug(t):
    t = re.sub(r"[`*_]", "", t).strip().lower()
    t = re.sub(r"[^\w\s-]", "", t)          # GitHub deletes punctuation
    return re.sub(r"\s+", "-", t)


mds = tracked("*.md")
anchors = {}
for f in mds:
    a = set()
    for line in open(os.path.join(ROOT, f), encoding="utf-8"):
        m = re.match(r"^(#{1,6})\s+(.*?)\s*$", line)
        if m:
            a.add(slug(m.group(2)))
    anchors[f] = a

for f in mds:
    d = os.path.dirname(f)
    txt = re.sub(r"```.*?```", "", open(os.path.join(ROOT, f), encoding="utf-8").read(),
                 flags=re.S)
    for m in re.finditer(r"\[([^\]]*)\]\(([^)\s]+)\)", txt):
        tgt = m.group(2)
        if tgt.startswith(("http://", "https://", "mailto:")):
            continue
        path, _, anch = tgt.partition("#")
        key = f
        if path:
            key = os.path.normpath(os.path.join(d, path))
            chk(os.path.exists(os.path.join(ROOT, key)),
                f"{f}: link target does not exist: {tgt}")
            if not os.path.exists(os.path.join(ROOT, key)):
                continue
        if anch and key in anchors:
            chk(anch in anchors[key], f"{f}: no heading '{anch}' in {key}")

# --------------------------------------------- 6. no contradictory counts
# The root README quotes each firewall's assertion and cover-point totals.
# They must match the SVA file they describe.
for core, sva in (("altera_avalon_mm_firewall", "tb/avl_mm_firewall_sva.sv"),
                  ("altera_axi4_lite_firewall", "tb/axi4_lite_firewall_sva.sv")):
    path = os.path.join(ROOT, core, sva)
    if not os.path.exists(path):
        continue
    t = open(path, encoding="utf-8").read()
    n_a = len(re.findall(r"assert property", t))
    n_c = len(re.findall(r"cover property", t))
    row = [ln for ln in README.splitlines() if f"`{core}`" in ln]
    for ln in row:
        for num, noun, truth in ((n_a, "assertions", n_a), (n_c, "cover points", n_c)):
            m = re.search(r"(\d+)\s+" + noun, ln)
            if m:
                chk(int(m.group(1)) == truth,
                    f"root README says {m.group(1)} {noun} for {core}, "
                    f"the SVA file has {truth}")

# ------------------------------------------ 7. component file references
# A _hw.tcl that names a file which is not there produces a component that
# loads in the catalog and fails at generation, a long way from the mistake.
for tcl in tracked("*_hw.tcl"):
    if tcl.count("/") != 1:
        continue
    d = os.path.dirname(tcl)
    txt = open(os.path.join(ROOT, tcl), encoding="utf-8").read()
    # Tcl continues a command with a trailing backslash; join those first, or
    # the patterns below match nothing and quietly check nothing.
    txt = re.sub(r"\\\s*\n\s*", " ", txt)
    for m in re.finditer(r"add_fileset_file\s+\S+\s+\S+\s+PATH\s+(\S+)", txt):
        chk(os.path.exists(os.path.join(ROOT, d, m.group(1))),
            f"{tcl} lists a file that does not exist: {m.group(1)}")
    # the top level it declares must be a module that actually exists
    for m in re.finditer(r"set_fileset_property\s+\w+\s+TOP_LEVEL\s+(\S+)", txt):
        top = m.group(1)
        found = any(re.search(r"^\s*module\s+" + re.escape(top) + r"\b",
                              open(os.path.join(ROOT, d, f), encoding="utf-8",
                                   errors="ignore").read(), re.M)
                    for f in
                    [mm.group(1) for mm in
                     re.finditer(r"add_fileset_file\s+\S+\s+\S+\s+PATH\s+(\S+)", txt)]
                    if os.path.exists(os.path.join(ROOT, d, f)))
        chk(found, f"{tcl} declares TOP_LEVEL {top}, but no listed file "
                   f"defines that module")

# ------------------------------- 8. the SDRAM tables must agree with each other
# The same measured figures appear in the core's README and in the benchmark's.
# Updating one and not the other is the likeliest way for them to drift, and
# neither is derivable from the repository without a Quartus installation, so
# agreeing with each other is the check available.
a = os.path.join(ROOT, "altera_avalon_mm_sdram_controller", "README.md")
b = os.path.join(ROOT, "altera_avalon_mm_sdram_controller", "benchmark", "README.md")
if os.path.exists(a) and os.path.exists(b):
    def perf(path):
        # Only the table headed "Intel's core | Custom core". The look-ahead
        # ablation table below it reuses two of the same row labels with
        # different numbers, so scanning the whole file compares the wrong
        # rows and reports a disagreement that is not one.
        rows, inside = {}, False
        for ln in open(path, encoding="utf-8"):
            if ln.startswith("|") and "Intel's core" in ln and "Custom core" in ln:
                inside = True
                continue
            if inside:
                if not ln.startswith("|"):
                    break
                m = re.match(r"\|\s*\*{0,2}([\w+/ -]+?)\*{0,2}\s*\|\s*"
                             r"([\d.]+)\s*\|\s*\*{0,2}([\d.]+)\*{0,2}\s*\|", ln)
                if m:
                    rows[m.group(1).strip()] = (m.group(2), m.group(3))
        return rows
    pa, pb = perf(a), perf(b)
    chk(pa and pb, "could not parse the SDRAM performance table from both READMEs")
    common = set(pa) & set(pb)
    chk(len(common) >= 6,
        f"the two SDRAM READMEs share only {len(common)} performance rows; "
        f"one of the tables has been edited without the other")
    for k in sorted(common):
        chk(pa[k] == pb[k],
            f'SDRAM performance row "{k}" disagrees between the two READMEs: '
            f"{pa[k]} vs {pb[k]}")

# ---------------------------------------------------------------- report
print(f"check_docs: {passes} claims verified, {len(fails)} mismatches")
if fails:
    print()
    for f in fails:
        print(f"  FAIL  {f}")
    sys.exit(1)
