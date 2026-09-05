#!/usr/bin/env python3
"""
Read a VCD.

This is the surviving half of what used to be wavedraw.py, which both parsed a
VCD and drew SVG waveforms by hand. The drawing half is gone - WaveDrom renders
the figures now, and it does it in the notation hardware engineers already read.
What is still needed is a way to get sampled values out of a recording, which is
this.
"""

import re

# ---------------------------------------------------------------- VCD parsing


class Vcd:
    def __init__(self, path):
        txt = open(path).read().split("\n")
        self.ids = {}          # id -> list of hierarchical names
        self.widths = {}       # id -> width
        scope, start = [], None
        for i, line in enumerate(txt):
            s = line.strip()
            if s.startswith("$scope"):
                scope.append(s.split()[2])
            elif s.startswith("$upscope"):
                scope.pop()
            elif s.startswith("$var"):
                p = s.split()
                sid, name = p[3], p[4]
                self.ids.setdefault(sid, []).append(".".join(scope + [name]))
                self.widths[sid] = int(p[2])
            elif s.startswith("$enddefinitions"):
                start = i
                break
        self.by_name = {}
        for sid, names in self.ids.items():
            for n in names:
                self.by_name[n] = sid

        # value-change stream: time -> {id: value}
        self.times = []
        self.changes = []
        cur, t = {}, 0
        for line in txt[start + 1:]:
            if not line:
                continue
            if line[0] == "#":
                if cur:
                    self.times.append(t)
                    self.changes.append(cur)
                    cur = {}
                t = int(line[1:])
            elif line[0] in "01xzXZ":
                cur[line[1:]] = line[0]
            elif line[0] in "bB":
                v, sid = line[1:].split(" ", 1)
                cur[sid.strip()] = v
        if cur:
            self.times.append(t)
            self.changes.append(cur)

    def sample(self, names, t_from, t_to, step):
        """Return [(t, {name: value})] sampled every `step` from t_from."""
        sids = {n: self.by_name[n] for n in names if n in self.by_name}
        state, out, idx = {}, [], 0
        for t in range(0, t_to + step, step):
            while idx < len(self.times) and self.times[idx] <= t:
                state.update(self.changes[idx])
                idx += 1
            if t >= t_from:
                out.append((t, {n: state.get(s, "x") for n, s in sids.items()}))
        return out


def val(raw, width):
    if raw in ("x", "z", "X", "Z") or raw is None:
        return None
    if width == 1:
        return int(raw, 2) if raw in "01" else None
    try:
        return int(raw, 2)
    except ValueError:
        return None
