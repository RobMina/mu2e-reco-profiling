"""recoprof CLI.

  python3 -m recoprof cgtree <file> --root <regex> [--min-share 0.02] [--depth 6] [--nevents N]
      Top-down inclusive call tree of the most expensive function matching the regex (e.g. a module's produce).

  python3 -m recoprof abtiming CAND_timing.db --compare BASE_timing.db [--exclude r:s:e ...] [--modules REGEX] [--out f.md]
      Same-event A/B of two art TimeTracker databases: per-event mean, median and 1 %-trimmed mean ratios over the events
      both runs hold (first event and --exclude dropped), and per-module mean/median changes.

  python3 -m recoprof cgsummary <dir-or-files> [--n 40] [--skip-events 1] [--out report.md]
      Split a callgrind run into initialisation (part 1), events (parts 2..N-1, summed) and end-of-job (final dump),
      and write markdown tables: totals per part, per-module inclusive cost, top functions exclusive and inclusive.
      --skip-events K moves the first K event dumps into a separate "warm-up" part: the first event carries lazy
      conditions/DB loading (A2 pilot: 5.7 G Ir vs ~1.2 G for later events), which is initialisation, not event cost.

Run from analysis/reco_profile (python3 -m recoprof ...) with any python3 >= 3.9; no third-party packages.
"""
from __future__ import annotations

import argparse
import glob
import os
import re
import sys

from . import arttiming, callgrind, report


def _dumps(target: list[str]) -> list[str]:
    files = []
    for t in target:
        files += sorted(glob.glob(os.path.join(t, "callgrind.out.*"))) if os.path.isdir(t) else [t]
    return [f for f in files if not f.endswith(".txt")]


def _part(path: str) -> int:
    # callgrind.out.<pid>.<part>[.gz]; the un-numbered final dump is the last part
    m = re.search(r"callgrind\.out\.\d+\.(\d+)(\.gz)?$", path)
    return int(m.group(1)) if m else 10**9


def cgsummary(args) -> int:
    files = sorted(_dumps(args.target), key=_part)
    if not files:
        print("no callgrind.out.* files found", file=sys.stderr)
        return 2
    init = [f for f in files if _part(f) == 1]
    # run-granularity dumps (DUMP=run): .1 = init, final = all events + end job (end job ~1 %); no warm-up split
    if args.nevents:
        args.skip_events = 0
    final = [f for f in files if _part(f) == 10**9]
    events = [f for f in files if f not in init and f not in final]
    if args.nevents and not events:
        events, final = final, []
    warm, events = events[: args.skip_events], events[args.skip_events:]
    out = []
    pi = callgrind.read(init) if init else None
    pe = callgrind.read(events) if events else None
    pf = callgrind.read(final) if final else None
    pw = callgrind.read(warm) if warm else None
    ne = args.nevents or len(events)
    out.append(f"# Callgrind summary: {os.path.commonpath(files)}\n")
    out.append("| Part | Dumps | Ir | Ir / event |\n|---|---|---|---|")
    for lab, p, n in (("initialisation", pi, len(init)), (f"warm-up events (first {len(warm)})", pw, len(warm)),
                      ("events", pe, ne), ("end of job", pf, len(final))):
        if p:
            out.append(f"| {lab} | {n} | {p.total:,} | {p.total / ne:,.0f} |" if lab == "events"
                       else f"| {lab} | {n} | {p.total:,} | - |")
    if pe:
        per = sorted(((_part(path), t) for path, _, _, t in pe.dumps))
        out.append("\nPer-event Ir: " + ", ".join(f"{t / 1e6:,.0f}M" for _, t in per))
        out.append(f"\n## Events: cost per art module (inclusive, {ne} events)\n")
        out.append(report.markdown_modules(pe, ne))
        out.append(f"\n## Events: top {args.n} functions, exclusive\n")
        out.append(report.markdown_top(report.top_table(pe, args.n), ne))
        out.append(f"\n## Events: top {args.n} functions, inclusive\n")
        out.append(report.markdown_top(report.top_table(pe, args.n, inclusive=True), ne, "inclusive"))
    if pw:
        out.append(f"\n## Warm-up events: top 15 functions, exclusive\n")
        out.append(report.markdown_top(report.top_table(pw, 15)))
    if pi:
        out.append(f"\n## Initialisation: top {min(args.n, 25)} functions, exclusive\n")
        out.append(report.markdown_top(report.top_table(pi, min(args.n, 25))))
    text = "\n".join(out) + "\n"
    if args.out:
        with open(args.out, "w") as fh:
            fh.write(text)
        print(f"wrote {args.out}")
    else:
        print(text)
    return 0


def cgcallers(args) -> int:
    files = sorted(_dumps(args.target), key=_part)
    ev = [f for f in files if _part(f) not in (1, 10**9)][args.skip_events:]
    if not ev:  # run-granularity dumps (DUMP=run): the final dump holds all events
        ev = [f for f in files if _part(f) == 10**9]
    p = callgrind.read(ev)
    ne = args.nevents or len(ev) or 1
    print(f"{len(ev)} dump(s), {ne} event(s), total {p.total:,} Ir")
    for a, b, v in report.callers(p, args.pattern, args.n):
        print(f"{v / ne:>14,.0f} Ir/ev {100 * v / p.total:5.1f} %  {report.short_name(a, 90)}  ->  {report.short_name(b, 50)}")
    if args.chain:
        top = report.callers(p, args.pattern, 1)
        if top:
            print("\nmost expensive chain upwards from", report.short_name(top[0][1], 80))
            for a, v in report.chain_up(p, top[0][1], args.chain):
                print(f"  {v / ne:>14,.0f} Ir/ev  {report.short_name(a, 110)}")
    return 0


def _pairs(path: str) -> dict:
    out = {}
    for line in open(path):
        f = line.split()
        if f and not f[0].startswith("#") and len(f) >= 2 and f[1] != "-":
            out[f[0]] = f[1]
    return out


def pairtable(args) -> int:
    """Test vs its same-node baseline: CPU ratio, per-event mean ratio with/without excluded events, top module deltas."""
    pairs = _pairs(args.pairs)
    excl = [tuple(int(x) for x in e.split(":")) for e in (args.exclude or [])]
    ids = args.ids or sorted(pairs)
    rows = ["| Test | Baseline | CPU model | CPU test / base (s) | CPU/event ratio | Event-time ratio (no 1st ev., no outliers) | "
            "Largest module changes (test - base, ms/ev) | VmHWM test / base (MB) |",
            "|---|---|---|---|---|---|---|---|"]
    for t in ids:
        b = pairs.get(t)
        td = os.path.join(args.root, t)
        bd = os.path.join(td, f"base_{b}") if b else None
        if not b or not os.path.isdir(td) or not os.path.isdir(bd):
            continue
        ts, bs, tm = arttiming.summary(td), arttiming.summary(bd), arttiming.meta(td)
        if "cpu" not in ts or "cpu" not in bs or tm.get("exit") not in (0, None):
            rows.append(f"| {t} | {b} | {tm.get('cpu', '?')} | failed (exit {tm.get('exit')}) | - | - | - | - |")
            continue
        te, be = arttiming.per_event(td, excl), arttiming.per_event(bd, excl)
        mr = (sum(te.values()) / len(te)) / (sum(be.values()) / len(be)) if te and be else float("nan")
        mods = set(ts["modules"]) | set(bs["modules"])
        d = sorted(((ts["modules"].get(m, 0) - bs["modules"].get(m, 0), m) for m in mods), key=lambda x: -abs(x[0]))
        dtxt = "; ".join(f"{':'.join(m.split(':')[1:])} {1e3 * v:+.1f}" for v, m in d[:args.nmod] if abs(v) > 1e-4)
        cr = (ts["cpu"] / ts.get("nevt", 1)) / (bs["cpu"] / bs.get("nevt", 1))
        rows.append(f"| {t} | {b} | {tm.get('cpu', '?')} | {ts['cpu']:.0f} / {bs['cpu']:.0f} | {cr:.3f} | "
                    f"{mr:.3f} | {dtxt} | {ts.get('vmhwm', 0):.0f} / {bs.get('vmhwm', 0):.0f} |")
    text = "\n".join(rows) + "\n"
    if args.out:
        open(args.out, "w").write(text)
        print(f"wrote {args.out}")
    else:
        print(text)
    return 0


def _ratio(root: str, t: str, b: str):
    """(CPU/event ratio test/base, cpu model) for one paired job, or None."""
    td = os.path.join(root, t)
    bd = os.path.join(td, f"base_{b}")
    if not os.path.isdir(bd):
        return None
    ts, bs, tm = arttiming.summary(td), arttiming.summary(bd), arttiming.meta(td)
    if "cpu" not in ts or "cpu" not in bs or tm.get("exit") not in (0, None):
        return None
    return (ts["cpu"] / ts.get("nevt", 1)) / (bs["cpu"] / bs.get("nevt", 1)), tm.get("cpu", "?")


def _shares(d: str) -> dict:
    """{module label:type: share of the summed module means} from the TimeTracker summary of one job."""
    mods = arttiming.summary(d).get("modules", {})
    agg = {}
    for k, v in mods.items():
        f = k.split(":")
        key = ":".join(f[1:]) if len(f) > 2 else k
        agg[key] = agg.get(key, 0.0) + v
    tot = sum(agg.values())
    return {k: v / tot for k, v in agg.items()} if tot > 0 else {}


def armcompare(args) -> int:
    """Two arms side by side: each test's same-node ratio in both arms, and per-module time shares of unpaired jobs."""
    pairs = _pairs(args.pairs)
    la, lb = os.path.basename(args.arm_a.rstrip("/")), os.path.basename(args.arm_b.rstrip("/"))
    out = [f"## Same-node ratios (test / its paired baseline, CPU per event): {la} vs {lb}", "",
           f"| Test | Baseline | {la} ratio | {lb} ratio | {lb} / {la} | CPU model {la} | CPU model {lb} |",
           "|---|---|---|---|---|---|---|"]
    for t in sorted(pairs):
        b = pairs[t]
        ra, rb = _ratio(args.arm_a, t, b), _ratio(args.arm_b, t, b)
        if not ra and not rb:
            continue
        fa = f"{ra[0]:.3f}" if ra else "-"
        fb = f"{rb[0]:.3f}" if rb else "-"
        ch = f"{rb[0] / ra[0]:.3f}" if ra and rb else "-"
        out.append(f"| {t} | {b} | {fa} | {fb} | {ch} | {ra[1] if ra else '-'} | {rb[1] if rb else '-'} |")
    for t in args.share_ids:
        sa, sb = _shares(os.path.join(args.arm_a, t)), _shares(os.path.join(args.arm_b, t))
        if not sa or not sb:
            continue
        ma, mb = arttiming.meta(os.path.join(args.arm_a, t)), arttiming.meta(os.path.join(args.arm_b, t))
        out += ["", f"## {t}: module share of the summed TimeTracker module means "
                f"({la}: {ma.get('cpu', '?')}; {lb}: {mb.get('cpu', '?')})", "",
                f"| Module | {la} share | {lb} share | change (points) |", "|---|---|---|---|"]
        keys = sorted(set(sa) | set(sb), key=lambda k: -max(sa.get(k, 0), sb.get(k, 0)))[:args.nmod]
        for k in keys:
            out.append(f"| {k} | {100 * sa.get(k, 0):.1f} % | {100 * sb.get(k, 0):.1f} % | "
                       f"{100 * (sb.get(k, 0) - sa.get(k, 0)):+.1f} |")
    text = "\n".join(out) + "\n"
    if args.out:
        open(args.out, "w").write(text)
        print(f"wrote {args.out}")
    else:
        print(text)
    return 0


def memcompare(args) -> int:
    """massif peak heap and DHAT allocation sites, one or more arms side by side (markdown)."""
    from . import memprof
    labels = [os.path.basename(a.rstrip("/")) for a in args.arms]
    out = ["## Peak heap (massif)", "", "| Workload | " + " | ".join(f"{l} peak heap (MB, + extra)" for l in labels)
           + " | " + " | ".join(f"{l} last snapshot (MB)" for l in labels) + " |",
           "|---|" + "---|" * (2 * len(labels))]
    tops = {}
    for t in args.massif_ids:
        row, last = [], []
        for a in args.arms:
            p = os.path.join(a, f"{t}_massif_mem", "massif.out.gz")
            if not os.path.exists(p):
                row.append("-"); last.append("-"); continue
            m = memprof.massif_peak(p)
            row.append(f"{m['heap'] / 1e6:.0f} (+{m['extra'] / 1e6:.0f}), snapshot {m['snapshot']}/{m['nsnap'] - 1}")
            last.append(f"{m['last_heap'] / 1e6:.0f}")
            tops[(t, a)] = m["children"]
        out.append(f"| {t} | " + " | ".join(row) + " | " + " | ".join(last) + " |")
    for t in args.massif_ids:
        for a, l in zip(args.arms, labels):
            ch = tops.get((t, a))
            if ch:
                out += ["", f"### {t} {l}: largest holders at the peak", "", "| MB | Allocated in |", "|---|---|"]
                out += [f"| {b / 1e6:.0f} | `{n[:110]}` |" for b, n in ch]
    out += ["", f"## Allocation churn (DHAT, {args.dhat_id}, {args.dhat_nevents} events + initialisation)", ""]
    res = {}
    for a, l in zip(args.arms, labels):
        p = os.path.join(a, f"{args.dhat_id}_dhat_mem", "dhat.out.gz")
        if os.path.exists(p):
            res[l] = memprof.dhat_sites(p, args.dhat_nevents, top=args.nsites)
    if res:
        out += ["| Arm | Blocks | Blocks / event (averaged) | Bytes (GB) |", "|---|---|---|---|"]
        out += [f"| {l} | {r['blocks']:,} | {r['per_event'] / 1e3:.0f}k | {r['bytes'] / 1e9:.2f} |" for l, r in res.items()]
        allsites = []
        for r in res.values():
            allsites += [s[0] for s in r["sites"] if s[0] not in allsites]
        out += ["", "| Site (first Mu2e/KinKal/art/fhicl/ROOT frame) | " + " | ".join(f"{l} blocks/event" for l in res)
                + " |", "|---|" + "---|" * len(res)]
        for site in allsites:
            cells = []
            for r in res.values():
                v = next((x for x in r["sites"] if x[0] == site), None)
                cells.append(f"{v[1] / args.dhat_nevents / 1e3:.1f}k ({100 * v[1] / r['blocks']:.1f} %)" if v else "< top")
            out.append(f"| `{site[:100]}` | " + " | ".join(cells) + " |")
    text = "\n".join(out) + "\n"
    if args.out:
        open(args.out, "w").write(text)
        print(f"wrote {args.out}")
    else:
        print(text)
    return 0


def cgtree(args) -> int:
    files = sorted(_dumps(args.target), key=_part)
    ev = [f for f in files if _part(f) not in (1, 10**9)][args.skip_events:]
    if not ev:
        ev = [f for f in files if _part(f) == 10**9]
    p = callgrind.read(ev)
    ne = args.nevents or len(ev) or 1
    for line in report.tree(p, args.root, ne, args.min_share, args.depth):
        print(line)
    return 0


def _stats(v: list) -> tuple:
    v = sorted(v)
    n = len(v)
    k = n // 100
    trim = v[k:n - k] if n - 2 * k > 0 else v
    med = v[n // 2] if n % 2 else 0.5 * (v[n // 2 - 1] + v[n // 2])
    return sum(v) / n, med, sum(trim) / len(trim)


def abtiming(args) -> int:
    """Same-event timing A/B from two TimeTracker dbs (outliers excluded by key)."""
    excl = {tuple(int(x) for x in e.split(":")) for e in (args.exclude or [])}
    ce, be = arttiming.event_times(args.cand), arttiming.event_times(args.compare)
    first = set()
    for db in (args.cand, args.compare):
        k = arttiming.per_event_first(db)
        if k:
            first.add(k)
    keys = sorted((set(ce) & set(be)) - excl - first)
    if not keys:
        print("no common events")
        return 1
    rows = [f"events compared: {len(keys)} (cand {len(ce)}, base {len(be)}; excluded {len(excl)} + first event)", "",
            "| Quantity | Base (ms) | Cand (ms) | Cand / base |", "|---|---|---|---|"]
    cs, bs = _stats([ce[k] for k in keys]), _stats([be[k] for k in keys])
    for name, c, b in zip(("event mean", "event median", "event 1%-trimmed mean"), cs, bs):
        rows.append(f"| {name} | {1e3 * b:.2f} | {1e3 * c:.2f} | {c / b:.4f} |")
    paired = sorted(ce[k] / be[k] for k in keys if be[k] > 0)
    rows.append(f"| median of per-event ratios | | | {paired[len(paired) // 2]:.4f} |")
    cm, bm = arttiming.module_times(args.cand), arttiming.module_times(args.compare)
    pat = re.compile(args.modules) if args.modules else None
    mrows = []
    for lab in sorted(set(cm) & set(bm)):
        if pat and not pat.search(lab):
            continue
        cv = [cm[lab].get(k, 0.0) for k in keys]
        bv = [bm[lab].get(k, 0.0) for k in keys]
        (cmean, cmed, _), (bmean, bmed, _) = _stats(cv), _stats(bv)
        mrows.append((bmean, lab, bmean, cmean, bmed, cmed))
    mrows.sort(reverse=True)
    rows += ["", "| Module | Base mean (ms) | Cand mean (ms) | Mean ratio | Base median (ms) | Cand median (ms) | Median ratio |",
             "|---|---|---|---|---|---|---|"]
    for _, lab, bmean, cmean, bmed, cmed in mrows[:args.nmod]:
        mr = cmean / bmean if bmean > 0 else float("nan")
        dr = cmed / bmed if bmed > 0 else float("nan")
        rows.append(f"| {lab} | {1e3 * bmean:.3f} | {1e3 * cmean:.3f} | {mr:.4f} | {1e3 * bmed:.3f} | {1e3 * cmed:.3f} | {dr:.4f} |")
    text = "\n".join(rows) + "\n"
    if args.out:
        open(args.out, "w").write(text)
    print(text)
    return 0


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(prog="recoprof")
    sub = ap.add_subparsers(dest="cmd", required=True)
    a = sub.add_parser("cgsummary", help="callgrind run -> markdown summary")
    a.add_argument("target", nargs="+", help="directory with callgrind.out.* files, or the files")
    a.add_argument("--n", type=int, default=40)
    a.add_argument("--skip-events", type=int, default=1, help="first K event dumps reported as warm-up (default 1)")
    a.add_argument("--nevents", type=int, help="run-granularity dumps: number of events in the run dump (per-event columns)")
    a.add_argument("--out")
    a.set_defaults(func=cgsummary)
    c = sub.add_parser("cgcallers", help="who calls the functions matching a regex (event dumps)")
    c.add_argument("target", nargs="+")
    c.add_argument("--pattern", required=True)
    c.add_argument("--n", type=int, default=12)
    c.add_argument("--chain", type=int, default=10, help="follow the top caller chain this many levels up")
    c.add_argument("--skip-events", type=int, default=1)
    c.add_argument("--nevents", type=int, help="events in a run-granularity dump (per-event columns)")
    c.set_defaults(func=cgcallers)
    g = sub.add_parser("cgtree", help="top-down call tree of one function (module produce, ...)")
    g.add_argument("target", nargs="+")
    g.add_argument("--root", required=True, help="regex; the most expensive matching function is the root")
    g.add_argument("--min-share", type=float, default=0.02, help="drop edges below this share of the root (default 0.02)")
    g.add_argument("--depth", type=int, default=6)
    g.add_argument("--nevents", type=int)
    g.add_argument("--skip-events", type=int, default=1)
    g.set_defaults(func=cgtree)
    t = sub.add_parser("pairtable", help="art-timing test vs same-node baseline table (markdown)")
    t.add_argument("root", help="arm dir with <id>/ and <id>/base_<bid>/")
    t.add_argument("--pairs", default=os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "pairs.txt"))
    t.add_argument("--ids", nargs="*")
    t.add_argument("--exclude", nargs="*", help="run:subrun:event keys dropped from the per-event mean ratio")
    t.add_argument("--nmod", type=int, default=4)
    t.add_argument("--out")
    t.set_defaults(func=pairtable)
    m = sub.add_parser("armcompare", help="two arms side by side: same-node ratios and module shares (markdown)")
    m.add_argument("arm_a", help="reference arm dir")
    m.add_argument("arm_b", help="new arm dir")
    m.add_argument("--pairs", default=os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "pairs.txt"))
    m.add_argument("--share-ids", nargs="*", default=["A2-ce", "A5-cosoff", "A6-ext", "A8-kpp"])
    m.add_argument("--nmod", type=int, default=12)
    m.add_argument("--out")
    m.set_defaults(func=armcompare)
    q = sub.add_parser("memcompare", help="massif peak heap and DHAT allocation sites, arms side by side (markdown)")
    q.add_argument("arms", nargs="+", help="arm dirs with <id>_massif_mem/ and <id>_dhat_mem/")
    q.add_argument("--massif-ids", nargs="*", default=["A2-ce", "A5-cosoff", "A6-ext"])
    q.add_argument("--dhat-id", default="A2-ce")
    q.add_argument("--dhat-nevents", type=int, default=200)
    q.add_argument("--nsites", type=int, default=14)
    q.add_argument("--out")
    q.set_defaults(func=memcompare)
    b = sub.add_parser("abtiming", help="same-event timing A/B of two TimeTracker dbs (markdown)")
    b.add_argument("cand", help="candidate timing.db")
    b.add_argument("--compare", required=True, help="baseline timing.db")
    b.add_argument("--exclude", nargs="*", help="run:subrun:event keys to drop (e.g. a known outlier)")
    b.add_argument("--modules", help="regex on module labels for the module table")
    b.add_argument("--nmod", type=int, default=12, help="module rows, most expensive in base first")
    b.add_argument("--out")
    b.set_defaults(func=abtiming)
    i = sub.add_parser("abidentical", help="exact leaf-by-leaf comparison of two EventNtuple files (exit 0 = identical)")
    i.add_argument("cand", help="candidate ntuple")
    i.add_argument("--compare", required=True, help="baseline ntuple")
    i.add_argument("--tree", help="tree path, e.g. EventNtuple/ntuple (default: every tree in both files)")
    i.add_argument("--rtol", type=float, default=0.0)
    i.add_argument("--max-report", type=int, default=30)
    i.add_argument("--show-values", type=int, default=0)
    i.set_defaults(func=lambda a: _abidentical(a))
    args = ap.parse_args(argv)
    return args.func(args)


def _abidentical(a):
    from . import abidentical
    abidentical.run([a.cand], None, compare=[a.compare], tree=a.tree, rtol=a.rtol,
                    max_report=a.max_report, show_values=a.show_values)
    return 0


if __name__ == "__main__":
    sys.exit(main())
