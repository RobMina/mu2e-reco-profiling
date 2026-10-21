"""Read valgrind memory profiles of one reco_profile job: DHAT JSON (dhat.out[.gz]) and massif (massif.out[.gz])."""
from __future__ import annotations

import gzip
import json
import re

# first frame in an allocation stack that belongs to one of these is the attributed site
SITE_RE = re.compile(r"(mu2e::|KinKal::|art::|fhicl::|T[A-Z]\w*::|TStreamerInfoActions::|ROOT::|cet::|canvas)")


def _open(path: str):
    return gzip.open(path, "rt") if path.endswith(".gz") else open(path)


def _fname(entry: str) -> str:
    """'0xADDR: func(args) (file:line)' -> 'func'; DHAT ftbl entries."""
    m = re.match(r"0x[0-9A-Fa-f]+: (.*?)(?: \((?:in |[^()]*:\d+\)).*)?$", entry)
    name = m.group(1) if m else entry
    return re.sub(r"\(.*", "", name).strip()


def dhat_sites(path: str, nevents: int, top: int = 15) -> dict:
    """Total blocks/bytes and the top allocation sites, each attributed to the first Mu2e/KinKal/art/fhicl/ROOT frame
    of its stack (None if no such frame). Returns {'blocks', 'bytes', 'per_event', 'sites': [(site, blocks, bytes)]}."""
    d = json.load(_open(path))
    ftbl = d["ftbl"]
    names = [_fname(e) for e in ftbl]
    agg: dict = {}
    tb = tbk = 0
    for pp in d["pps"]:
        tb += pp["tb"]
        tbk += pp["tbk"]
        site = next((names[i] for i in pp["fs"] if SITE_RE.search(names[i])), "(no Mu2e/KinKal/art/ROOT frame)")
        a = agg.setdefault(site, [0, 0])
        a[0] += pp["tbk"]
        a[1] += pp["tb"]
    sites = sorted(((k, v[0], v[1]) for k, v in agg.items()), key=lambda x: -x[1])[:top]
    return {"blocks": tbk, "bytes": tb, "per_event": tbk / nevents, "sites": sites}


def massif_peak(path: str, top: int = 6) -> dict:
    """Peak snapshot of a massif.out: heap and extra bytes, snapshot index, and the largest direct children of the
    peak's heap tree (only the detailed/peak snapshots carry a tree)."""
    snaps = []
    cur = None
    lines = _open(path).read().splitlines()
    for i, line in enumerate(lines):
        if line.startswith("snapshot="):
            cur = {"i": int(line.split("=")[1]), "tree": i}
            snaps.append(cur)
        elif cur is not None and line.startswith("mem_heap_B="):
            cur["heap"] = int(line.split("=")[1])
        elif cur is not None and line.startswith("mem_heap_extra_B="):
            cur["extra"] = int(line.split("=")[1])
        elif cur is not None and line.startswith("heap_tree="):
            cur["kind"] = line.split("=")[1]
            cur["line"] = i
    peak = max(snaps, key=lambda s: s.get("heap", 0) + s.get("extra", 0))
    children = []
    if peak.get("kind") in ("peak", "detailed"):
        j = peak["line"] + 1
        root = re.match(r"( *)n(\d+): (\d+)", lines[j])
        depth = len(root.group(1)) + 1 if root else 1
        for line in lines[j + 1:]:
            m = re.match(r"( *)n\d+: (\d+) (.*)", line)
            if not m or line.startswith("#") or line.startswith("snapshot="):
                break
            if len(m.group(1)) == depth:
                children.append((int(m.group(2)), _fname(m.group(3))))
        children = sorted(children, key=lambda x: -x[0])[:top]
    last = snaps[-1]
    return {"snapshot": peak["i"], "nsnap": len(snaps), "heap": peak.get("heap", 0), "extra": peak.get("extra", 0),
            "last_heap": last.get("heap", 0), "children": children}
