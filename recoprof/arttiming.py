"""Read art timing outputs of one reco_profile job dir: TimeReport/MemReport and the TimeTracker summary from log.txt,
per-event times from timing.db, node info from meta.txt."""
from __future__ import annotations

import os
import re
import sqlite3


def meta(d: str) -> dict:
    out = {}
    p = os.path.join(d, "meta.txt")
    if not os.path.exists(p):
        return out
    txt = open(p).read()
    m = re.search(r"cpu=\s*(.*?)\s+ncpu_node", txt)
    out["cpu"] = m.group(1) if m else "?"
    m = re.search(r"exit=(\d+)", txt)
    out["exit"] = int(m.group(1)) if m else None
    return out


def summary(d: str) -> dict:
    """{'cpu': s, 'real': s, 'vmhwm': MB, 'nevt': n, 'modules': {path:label:type: mean s}, 'full': mean s}."""
    out = {"modules": {}}
    p = os.path.join(d, "log.txt")
    if not os.path.exists(p):
        return out
    intt = False
    for line in open(p, errors="replace"):
        if line.startswith("TimeReport CPU"):
            m = re.search(r"CPU = ([\d.]+) Real = ([\d.]+)", line)
            out["cpu"], out["real"] = float(m.group(1)), float(m.group(2))
        elif "MemReport  VmPeak" in line:
            out["vmhwm"] = float(re.search(r"VmHWM = ([\d.]+)", line).group(1))
        elif line.startswith("TrigReport Events total"):
            out["nevt"] = int(re.search(r"total = (\d+)", line).group(1))
        elif line.startswith("Full event"):
            intt = True
            out["full"] = float(line.split()[3])
        elif intt:
            if line.startswith("="):
                intt = False
                continue
            f = line.split()
            if len(f) >= 7 and ":" in f[0]:
                out["modules"][f[0]] = float(f[2])
    return out


def per_event(d: str, exclude=(), skip_first: int = 1) -> dict:
    """{(run, subrun, event): seconds} from timing.db (TimeEvent) in processing order, without the first skip_first
    events (lazy conditions/geometry loading lands in event 1) and without excluded (run, subrun, event) keys."""
    p = os.path.join(d, "timing.db")
    if not os.path.exists(p):
        return {}
    con = sqlite3.connect(p)
    rows = con.execute("SELECT Run, SubRun, Event, Time FROM TimeEvent ORDER BY rowid").fetchall()
    con.close()
    ex = set(exclude)
    return {(r, s, e): t for r, s, e, t in rows[skip_first:] if (r, s, e) not in ex}


def module_events(d: str, event) -> dict:
    """{label: seconds} for one (run, subrun, event) from timing.db (TimeModule)."""
    p = os.path.join(d, "timing.db")
    con = sqlite3.connect(p)
    rows = con.execute("SELECT ModuleLabel, Time FROM TimeModule WHERE Run=? AND SubRun=? AND Event=?", event).fetchall()
    con.close()
    out = {}
    for lab, t in rows:
        out[lab] = out.get(lab, 0.0) + t
    return out


def event_times(db: str) -> dict:
    """{(run, subrun, event): seconds} from a timing.db file (TimeEvent), all events."""
    con = sqlite3.connect(db)
    rows = con.execute("SELECT Run, SubRun, Event, Time FROM TimeEvent").fetchall()
    con.close()
    return {(r, s, e): float(t) for r, s, e, t in rows}


def module_times(db: str) -> dict:
    """{label: {(run, subrun, event): seconds}} from a timing.db file (TimeModule), summed over paths."""
    con = sqlite3.connect(db)
    rows = con.execute("SELECT Run, SubRun, Event, ModuleLabel, Time FROM TimeModule").fetchall()
    con.close()
    out: dict = {}
    for r, s, e, lab, t in rows:
        d = out.setdefault(lab, {})
        d[(r, s, e)] = d.get((r, s, e), 0.0) + float(t)
    return out


def per_event_first(db: str):
    """(run, subrun, event) of the first event processed (carries lazy initialisation), or None."""
    con = sqlite3.connect(db)
    row = con.execute("SELECT Run, SubRun, Event FROM TimeEvent ORDER BY rowid LIMIT 1").fetchone()
    con.close()
    return tuple(row) if row else None
