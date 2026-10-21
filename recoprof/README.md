# recoprof

Extraction of reco profiling results. Standard library only (python3 >= 3.9), except `abidentical` (numpy, uproot,
awkward). Run from the repository root.

| Command | What |
|---|---|
| `python3 -m recoprof cgsummary <dir> [--n 40] [--skip-events 1] [--out f.md]` | callgrind run (one dump per event, `.1` = init, final = end job) -> markdown: Ir per part, per-module inclusive cost, top-N exclusive and inclusive functions with library, hottest source line, calls/event, Ir/call |
| `python3 -m recoprof cgcallers <dir> --pattern <regex> [--chain 10]` | callers of the matching functions and the most expensive call chain upwards |
| `python3 -m recoprof abtiming CAND_timing.db --compare BASE_timing.db [--exclude run:subrun:event ...] [--modules REGEX] [--out f.md]` | same-event A/B of two TimeTracker dbs (one host): event mean/median/trimmed-mean ratios and per-module mean/median, first event and listed outliers dropped |
| `python3 -m recoprof memcompare <arm> [<arm> ...] [--massif-ids ...] [--dhat-id A2-ce --dhat-nevents 200] [--out f.md]` | massif peak heap (and largest holders at the peak) and DHAT blocks per event by site (first Mu2e/KinKal/art/fhicl/ROOT frame of each stack), arms side by side; `memprof.py` |
| `python3 -m recoprof armcompare <arm-a> <arm-b> [--share-ids ...] [--out f.md]` | two arms side by side: each test's same-node CPU/event ratio in both arms (ratios are comparable across arms; absolute times are not), and per-module shares of the summed TimeTracker module means for the unpaired A jobs |
| `python3 -m recoprof abidentical CAND.root --compare BASE.root [--tree EventNtuple/ntuple] [--rtol 0]` | exact leaf-by-leaf comparison of two EventNtuple files, for changes that must not alter output (exit 0 = identical); `abidentical.py` |
| `python3 -m recoprof pairtable <arm-dir> [--exclude run:subrun:event ...] [--out f.md]` | art-timing tests vs their same-node baselines (`<id>/base_<bid>/`, `pairs.txt`): CPU/event ratio, event-time ratio without the first event and excluded events, largest module changes, VmHWM |

Modules: `callgrind.py` (parser: name and position compression, call edges, line costs; totals checked against
`callgrind_annotate` on the A2 pilot: identical per-function exclusive sums), `arttiming.py` (log.txt TimeReport/
MemReport/TimeTracker, timing.db, meta.txt), `report.py` (tables, module attribution, caller chains).
