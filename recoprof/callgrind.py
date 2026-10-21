"""Parse callgrind output files into per-function exclusive/inclusive costs and call counts.

Reads the callgrind format directly (name and position compression, call edges), so several dump files (one per art
event with --dump-before) can be summed. Standard library only.
"""
from __future__ import annotations

import gzip
import os
import re
from collections import defaultdict
from dataclasses import dataclass, field

_NAMED = re.compile(r"^\((\d+)\)(?:\s(.*))?$")


@dataclass
class Profile:
    """Costs summed over one or more dumps, keyed by function key (see _key)."""
    events: str = "Ir"
    total: int = 0
    self_cost: dict = field(default_factory=lambda: defaultdict(int))
    incl_calls: dict = field(default_factory=lambda: defaultdict(int))   # cost of calls made, excl. direct recursion
    ncalls: dict = field(default_factory=lambda: defaultdict(int))       # times called (from calls= lines)
    obj: dict = field(default_factory=dict)
    src: dict = field(default_factory=dict)
    edges: dict = field(default_factory=lambda: defaultdict(int))        # (caller, callee) -> inclusive cost
    lines: dict = field(default_factory=lambda: defaultdict(int))        # (func, file, line) -> self cost
    dumps: list = field(default_factory=list)                            # (path, part, trigger, total)

    def inclusive(self, k: str) -> int:
        return self.self_cost.get(k, 0) + self.incl_calls.get(k, 0)

    def hot_line(self, k: str):
        """(file, line, self cost) of the line with the largest self cost in function k, or None."""
        if not hasattr(self, "_hot"):
            self._hot = {}
            for (f, fil, ln), v in self.lines.items():
                b = self._hot.get(f)
                if b is None or v > b[2]:
                    self._hot[f] = (fil, ln, v)
        return self._hot.get(k)

    def functions(self):
        return set(self.self_cost) | set(self.incl_calls) | set(self.ncalls)


def _open(path: str):
    return gzip.open(path, "rt", errors="replace") if path.endswith(".gz") else open(path, errors="replace")


def _key(name: str, obj: str) -> str:
    # bare addresses ("0x...") are only unique within an object
    return f"{name} [{os.path.basename(obj)}]" if name.startswith("0x") else name


def _cost(fields: list[str], npos: int) -> int:
    return int(fields[npos]) if len(fields) > npos and fields[npos][0].isdigit() else 0


def _pos(tok: str, last: int) -> int:
    # position compression: absolute (decimal or 0x hex), +n / -n relative to the previous line, * = same
    if tok == "*":
        return last
    if tok[0] in "+-":
        return last + int(tok, 0)
    return int(tok, 0)


def read(paths, prof: Profile | None = None) -> Profile:
    """Add the costs of each callgrind file in paths (plain or .gz) to prof (a new Profile if None)."""
    prof = prof or Profile()
    for path in paths:
        names = {"fn": {}, "fl": {}, "ob": {}}
        npos = 1
        part = trigger = ""
        dump_total = 0
        ob = fl = fn = fi = ""
        lastpos = []
        cob = cfn = None
        pending_call = 0          # >0: the next cost line is the inclusive cost of a call (count = pending_call)

        def resolve(kind: str, val: str) -> str:
            m = _NAMED.match(val)
            if not m:
                return val
            i, nm = m.group(1), m.group(2)
            if nm is not None:
                names[kind][i] = nm
                return nm
            return names[kind].get(i, f"({i})")

        with _open(path) as fh:
            for line in fh:
                if not line or line[0] == "#" or line == "\n":
                    continue
                c = line[0]
                if c.isdigit() or c in "+-*":          # cost line
                    f = line.split()
                    v = _cost(f, npos)
                    if len(lastpos) != npos:
                        lastpos = [0] * npos
                    for j in range(min(npos, len(f))):
                        lastpos[j] = _pos(f[j], lastpos[j])
                    if pending_call:
                        callee = _key(cfn, cob if cob is not None else ob)
                        caller = _key(fn, ob)
                        prof.ncalls[callee] += pending_call
                        if callee != caller:
                            prof.incl_calls[caller] += v
                        prof.edges[(caller, callee)] += v
                        pending_call = 0
                        cob = cfn = None
                    else:
                        k = _key(fn, ob)
                        prof.self_cost[k] += v
                        dump_total += v
                        if v and npos > 1:
                            prof.lines[(k, fi or fl, lastpos[npos - 1])] += v
                    continue
                key, _, val = line.rstrip("\n").partition("=")
                if key == "fn":
                    fn = resolve("fn", val)
                    fi = fl
                    k = _key(fn, ob)
                    prof.obj.setdefault(k, ob)
                    prof.src.setdefault(k, fl)
                elif key in ("fl", "fi", "fe"):
                    name = resolve("fl", val)
                    if key == "fl":
                        fl = name
                    fi = name
                elif key == "ob":
                    ob = resolve("ob", val)
                elif key == "cob":
                    cob = resolve("ob", val)
                elif key in ("cfi", "cfl"):
                    resolve("fl", val)
                elif key == "cfn":
                    cfn = resolve("fn", val)
                elif key == "calls":
                    pending_call = int(val.split()[0]) or 1
                elif line.startswith("positions:"):
                    npos = len(line.split(":", 1)[1].split())
                elif line.startswith("events:"):
                    prof.events = line.split(":", 1)[1].split()[0]
                elif line.startswith("part:"):
                    part = line.split(":", 1)[1].strip()
                elif line.startswith("desc: Trigger:"):
                    trigger = line.split(":", 2)[2].strip()
        prof.total += dump_total
        prof.dumps.append((path, part, trigger, dump_total))
    return prof
