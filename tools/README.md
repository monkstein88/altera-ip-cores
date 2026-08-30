# tools

Repository-level checks. Each core also has its own — see the table below.

| File | Purpose |
|---|---|
| `check_docs.py` | Verifies the root README, the licensing, and every internal link, against the repository |

```bash
python3 tools/check_docs.py        # 270 claims, no dependencies
```

## Why the root README needs checking too

Each core already checks its own documents. Both firewalls carry a
`doc/tools/check_facts.py` that re-derives every register offset, bit position,
parameter range and assertion count quoted anywhere under `doc/` — including
their own `README.md` — from the RTL and the committed simulation artefacts.

Nothing checked the **root** README, and it drifted. A fourth core was added and
the root document went on saying "three cores" in five places, listed three
directories in its layout, and carried a Licence section reading *"the two
firewalls are MIT licensed"* and *"if you take only the firewalls, only the MIT
licence applies"* — leaving the new core in a licensing gap.

That last one is why this exists. A stale sentence about how many cores there
are is embarrassing; an unclear licence grant is the one claim in a repository
a reader is entitled to rely on.

## What it checks

- every component directory (one holding a `_hw.tcl` at its own top level) is
  linked from the component table, appears in the layout block, and is named in
  the Licence section
- a directory **with** a `NOTICE` is excluded from the MIT grant; one **without**
  is placed under it — so adding a core cannot silently leave it unlicensed
- the catalog group and version in each table row match what the `_hw.tcl`
  actually declares
- a count written in prose ("four cores") matches how many exist
- every `_hw.tcl` names files that exist, and declares a `TOP_LEVEL` that some
  listed file actually defines
- the SDRAM performance figures agree between the core README and the
  benchmark README — they are measured, not derivable, so agreeing with each
  other is the check available
- every relative link and heading anchor in all 24 markdown files resolves

## What it is not

It cannot tell you a sentence is *wrong*, only that it disagrees with something
else in the repository. Prose is not checkable: an existence check — "does this
catalog group appear somewhere in the README" — passes even when the document
contradicts itself elsewhere, because one correct mention hides an incorrect
one. That is why the group and version claims were moved into a parsable table
cell instead of being left in prose.

Every check here was verified by fault injection: the bug it is meant to catch
was reintroduced, and the check was confirmed to fail. Two of them did not, the
first time — the `_hw.tcl` pattern did not allow for Tcl's backslash line
continuations and so silently checked nothing at all, and the performance
comparison was picking up the look-ahead ablation table further down the page.
A check that has never failed has not been tested.
