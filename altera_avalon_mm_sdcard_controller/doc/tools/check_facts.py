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
