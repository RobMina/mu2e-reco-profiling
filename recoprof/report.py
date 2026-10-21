"""Readable tables from callgrind profiles: top functions, attribution to art modules, init vs event split."""
from __future__ import annotations

import os
import re

from .callgrind import Profile

# art calls a module's per-event code through these entry points (art 3.15 / Mu2e modules)
_MODULE_ENTRY = re.compile(r"^mu2e::([A-Za-z0-9_]+)::(produce|filter|analyze)\(art::Event")
_ROOTOUT = re.compile(r"^art::RootOutput(File)?::(write|writeOne|fillBranches)")
_SKIP_SRC = ("/tmp/rlc/spack-stage/", "/localdisk/tmp/")   # build-time paths: shorten


def short_src(path: str, line: int | None = None) -> str:
    """Repository-relative source path (Offline/..., KinKal/..., ROOT include/...), with :line."""
    p = path or "???"
    for marker in ("/Offline/", "/KinKal/", "/include/root/", "/art/", "/canvas/", "/include/c++/"):
        i = p.find(marker)
        if i >= 0:
            p = p[i + 1:]
            break
    else:
        for s in _SKIP_SRC:
            if p.startswith(s):
                p = os.path.basename(p)
    return f"{p}:{line}" if line else p


def short_name(name: str, width: int = 110) -> str:
    """Function name with long template arguments elided."""
    out, depth = [], 0
    for ch in name:
        if ch == "<":
            depth += 1
            if depth == 1:
                out.append("<...>")
            continue
        if ch == ">":
            depth -= 1
            continue
        if depth == 0:
            out.append(ch)
    s = "".join(out)
    return s if len(s) <= width else s[: width - 3] + "..."


def module_entries(prof: Profile) -> dict:
    """{module class: inclusive cost} for every mu2e module produce/filter/analyze entry in the profile."""
    out = {}
    for k in prof.functions():
        m = _MODULE_ENTRY.match(k)
        if m:
            out[m.group(1)] = out.get(m.group(1), 0) + prof.inclusive(k)
        elif _ROOTOUT.match(k):
            out["RootOutput (write)"] = max(out.get("RootOutput (write)", 0), prof.inclusive(k))
    return out


def top_table(prof: Profile, n: int = 40, inclusive: bool = False, min_share: float = 0.0) -> list[dict]:
    """Rows of the n most expensive functions by exclusive (default) or inclusive cost."""
    tot = prof.total or 1
    keys = prof.functions()
    cost = (lambda k: prof.inclusive(k)) if inclusive else (lambda k: prof.self_cost.get(k, 0))
    rows = []
    for k in sorted(keys, key=cost, reverse=True):
        c = cost(k)
        if c / tot < min_share or len(rows) >= n:
            break
        hl = prof.hot_line(k)
        rows.append({
            "function": k, "cost": c, "share": c / tot,
            "self": prof.self_cost.get(k, 0), "incl": prof.inclusive(k), "calls": prof.ncalls.get(k, 0),
            "lib": os.path.basename(prof.obj.get(k, "")),
            "src": short_src(hl[0], hl[1]) if hl else short_src(prof.src.get(k, "")),
        })
    return rows


def markdown_top(rows: list[dict], nevents: int | None = None, title_cost: str = "exclusive") -> str:
    """Markdown table of top_table rows; per-event columns when nevents is given."""
    per = f" / event" if nevents else ""
    head = (f"| # | Function | Library | Hottest line | {title_cost} Ir{per} | Share | Calls{per} | Ir/call |\n"
            "|---|---|---|---|---|---|---|---|\n")
    body = []
    for i, r in enumerate(rows, 1):
        div = nevents or 1
        ipc = r["cost"] / r["calls"] if r["calls"] else 0
        body.append(f"| {i} | `{short_name(r['function'])}` | {r['lib']} | `{r['src']}` | "
                    f"{r['cost'] / div:,.0f} | {100 * r['share']:.1f} % | {r['calls'] / div:,.1f} | {ipc:,.0f} |")
    return head + "\n".join(body) + "\n"


def markdown_modules(prof: Profile, nevents: int | None = None) -> str:
    """Markdown table of per-module inclusive cost (share of the profile total)."""
    tot = prof.total or 1
    mods = sorted(module_entries(prof).items(), key=lambda kv: kv[1], reverse=True)
    per = " / event" if nevents else ""
    lines = [f"| Module class | Inclusive Ir{per} | Share |", "|---|---|---|"]
    for m, c in mods:
        lines.append(f"| `{m}` | {c / (nevents or 1):,.0f} | {100 * c / tot:.1f} % |")
    return "\n".join(lines) + "\n"


def callers(prof: Profile, callee_pattern: str, n: int = 10) -> list[tuple[str, str, int]]:
    """Top (caller, callee, inclusive cost) edges into functions whose name matches callee_pattern."""
    rx = re.compile(callee_pattern)
    rows = [(a, b, v) for (a, b), v in prof.edges.items() if rx.search(b) and not rx.search(a)]
    return sorted(rows, key=lambda r: r[2], reverse=True)[:n]


def chain_up(prof: Profile, func: str, depth: int = 8) -> list[tuple[str, int]]:
    """Follow the most expensive caller edge upwards from func: [(caller, cost into the chain), ...]."""
    out, cur, seen = [], func, {func}
    for _ in range(depth):
        best = max(((a, v) for (a, b), v in prof.edges.items() if b == cur and a not in seen),
                   key=lambda r: r[1], default=None)
        if not best:
            break
        out.append(best)
        cur = best[0]
        seen.add(cur)
    return out


def tree(prof: Profile, root_pattern: str, nevents: int = 1, min_share: float = 0.01, depth: int = 6) -> list[str]:
    """Top-down call tree from the most expensive function matching root_pattern: each line is a callee whose edge cost
    is at least min_share of the root's inclusive cost; shows share of root, Ir/event and calls/event."""
    rx = re.compile(root_pattern)
    roots = sorted((k for k in prof.functions() if rx.search(k)), key=lambda k: -prof.inclusive(k))
    if not roots:
        return [f"no function matches {root_pattern}"]
    root = roots[0]
    rtot = prof.inclusive(root) or 1
    kids = {}
    for (a, b), v in prof.edges.items():
        kids.setdefault(a, []).append((b, v))
    out = [f"{100.0:5.1f}%  {rtot / nevents:>14,.0f} Ir/ev  {short_name(root, 100)}  (self {100 * prof.self_cost.get(root, 0) / rtot:.1f}%)"]
    def walk(fn, d, seen):
        if d > depth:
            return
        for b, v in sorted(kids.get(fn, []), key=lambda x: -x[1]):
            if v / rtot < min_share or b in seen:
                continue
            calls = prof.ncalls.get(b, 0) / nevents
            out.append(f"{100 * v / rtot:5.1f}%  {v / nevents:>14,.0f} Ir/ev  {'  ' * d}{short_name(b, 100 - 2 * d)}"
                       f"  [{calls:,.1f} calls/ev, self {100 * prof.self_cost.get(b, 0) / rtot:.1f}%]")
            walk(b, d + 1, seen | {b})
    walk(root, 1, {root})
    return out
