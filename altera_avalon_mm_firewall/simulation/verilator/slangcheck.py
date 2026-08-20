#!/usr/bin/env python3
"""Strict LRM elaboration check using slang. Independent of Verilator."""
import sys
import pyslang
from pyslang import driver as D

label, files = sys.argv[1], sys.argv[2:]
d = D.Driver()
d.addStandardArgs()
d.parseCommandLine("slangcheck " + " ".join(files))
d.processOptions()
d.parseAllSources()
comp = d.createCompilation()
diags = list(comp.getAllDiagnostics())
eng = pyslang.DiagnosticEngine(d.sourceManager)
cli = pyslang.TextDiagnosticClient()
eng.addClient(cli)
errs = 0
for dg in diags:
    sev = str(eng.getSeverity(dg.code, dg.location))
    if 'Error' in sev or 'Fatal' in sev:
        errs += 1
    eng.issue(dg)
txt = cli.getString().strip()
print(f"--- {label}: {errs} error(s), {len(diags)-errs} note/warning(s)")
if txt:
    print(txt)
sys.exit(1 if errs else 0)
