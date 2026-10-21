"""abidentical -- exact leaf-by-leaf comparison of two EventNtuple (or any TTree) files.

For a change that must NOT alter output: an opt-in feature at its default config, a refactor, a rebuild. Any
nonzero difference in a readable numeric leaf fails. (`abstats` is the statistical comparison, for changes that
are expected to move numbers.)

EventNtuple branches are record-typed (e.g. `trk`, `trksegs`) and some are complex Assns that uproot cannot
deserialize. This recurses into record fields down to numeric leaves and compares those exactly (values and
per-event multiplicity). Branches unreadable in BOTH files are skipped (structurally identical by construction); a
branch readable in only one file is a failure. Trees are taken at their highest cycle: a file can also hold an
earlier AutoSave cycle.

  python3 -m recoprof abidentical CAND.root --compare BASE.root [--tree EventNtuple/ntuple] [--rtol 0]
                                  [--max-report 30] [--show-values N]

Needs numpy, uproot and awkward (the other recoprof commands use the standard library only).

Exit 0 = identical, 1 = differences.
"""


def _imports():
    global np, uproot, ak
    import numpy as np
    import uproot
    import awkward as ak


def _all_trees(f):
    out = {}
    for k in f.keys(recursive=True, cycle=False):
        v = f[k]
        if getattr(v, "classname", "") == "TTree":
            out[k] = v
    return out


def _leaf_arrays(a, prefix):
    """{leaf_name: array} for every non-record leaf of an awkward array."""
    flds = getattr(a, "fields", [])
    if not flds:
        return {prefix: a}
    out = {}
    for f in flds:
        out.update(_leaf_arrays(a[f], f"{prefix}.{f}"))
    return out


def _cmp_values(a, b, rtol):
    try:
        na = ak.to_numpy(ak.flatten(a, axis=None))
        nb = ak.to_numpy(ak.flatten(b, axis=None))
    except Exception as ex:
        return None, f"flatten failed: {ex}"
    if na.shape != nb.shape:
        return False, f"n={na.shape} vs {nb.shape}"
    if na.dtype.kind in "fc" and rtol > 0:
        return bool(np.allclose(na, nb, rtol=rtol, atol=0, equal_nan=True)), ""
    if np.array_equal(na, nb):
        return True, ""
    if na.dtype.kind in "fc" and np.array_equal(np.nan_to_num(na), np.nan_to_num(nb)):
        return True, ""
    return False, f"{int(np.sum(na != nb))}/{na.size} values differ"


def _differing_values(a, b, n):
    """First n differing values of two same-shape leaves, as (entry, A value, B value)."""
    entry = ak.flatten(ak.broadcast_arrays(ak.local_index(a, axis=0), a)[0], axis=None)
    na = ak.to_numpy(ak.flatten(a, axis=None))
    nb = ak.to_numpy(ak.flatten(b, axis=None))
    bad = ((na != nb) & ~(np.isnan(na) & np.isnan(nb))) if na.dtype.kind in "fc" else (na != nb)
    return [(int(entry[i]), na[i], nb[i]) for i in np.nonzero(bad)[0][:n]]


def _multiplicity(a):
    try:
        return ak.to_numpy(ak.num(a, axis=1))
    except Exception:
        return None


def _read(tree, br):
    try:
        return tree[br].array()
    except Exception:
        return None


def run(inputs, outdir, compare=None, tree=None, rtol=0.0, max_report=30, show_values=0, **kw):
    _imports()
    if not compare:
        raise SystemExit("abidentical needs the BEFORE arm: --compare BASE.root")
    path_a, path_b = compare[0], inputs[0]
    ta, tb = _all_trees(uproot.open(path_a)), _all_trees(uproot.open(path_b))
    if tree and (tree not in ta or tree not in tb):
        print(f"FAIL: tree {tree} missing (A:{tree in ta} B:{tree in tb})")
        raise SystemExit(1)
    names = [tree] if tree else sorted(set(ta) & set(tb))

    fails, nleaf, nbranch, nskip = [], 0, 0, 0
    for tn in names:
        a, b = ta[tn], tb[tn]
        if a.num_entries != b.num_entries:
            fails.append(f"[{tn}] entry count {a.num_entries} vs {b.num_entries}")
            continue
        ba, bb = set(a.keys(recursive=False)), set(b.keys(recursive=False))
        fails += [f"[{tn}] top branch only in {'A' if m in ba else 'B'}: {m}" for m in sorted(ba ^ bb)]
        for br in sorted(ba & bb):
            nbranch += 1
            av, bv = _read(a, br), _read(b, br)
            if av is None and bv is None:
                nskip += 1
                continue
            if (av is None) != (bv is None):
                fails.append(f"[{tn}].{br}: readable in only one file")
                continue
            ma, mb = _multiplicity(av), _multiplicity(bv)
            if ma is not None and mb is not None and not np.array_equal(ma, mb):
                fails.append(f"[{tn}].{br}: per-event multiplicity differs")
            la, lb = _leaf_arrays(av, br), _leaf_arrays(bv, br)
            for lf in sorted(set(la) & set(lb)):
                eq, note = _cmp_values(la[lf], lb[lf], rtol)
                if eq is None:
                    nskip += 1
                elif eq:
                    nleaf += 1
                else:
                    fails.append(f"[{tn}].{lf}: DIFF {note}")
                    if show_values > 0 and "values differ" in note:
                        fails += [f"      entry {e}: A={x!r} B={y!r}" for e, x, y in
                                  _differing_values(la[lf], lb[lf], show_values)]

    print(f"\n=== {names} ===\nA = {path_a}\nB = {path_b}\nrtol = {rtol}")
    print(f"compared {nleaf} numeric leaves across {nbranch} branches; {nskip} unreadable-in-both skipped")
    if not fails:
        print("RESULT: IDENTICAL  (every numeric leaf matches bit-for-bit)")
        raise SystemExit(0)
    print(f"RESULT: {len(fails)} differences")
    for line in fails[:max_report]:
        print("  " + line)
    if len(fails) > max_report:
        print(f"  ... and {len(fails) - max_report} more")
    raise SystemExit(1)
