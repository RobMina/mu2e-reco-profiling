# rca: reproductions of the defects and the fixes

Each script runs one interactive job on one node from a built muse area, given by the environment variable `AREA`
(make it with `../setup_area.sh`). Outputs go to `$RP_OUT/rca/<name>/` (`../env.sh`). Run each in a fresh shell.

| Script | What it reproduces |
|---|---|
| `klts_inversion.sh [run\|gdb\|gdbvars\|gdbstate\|scan]` (`RCA_EVENT=<event>`) | `KLTruthSeed` throws `Inversion failure` at 1400:1974:4985 (input I6, extracted MC); `scan` lists every failing event of the file. Fixed by Mu2e/Offline#2042 (`patches/klts_zero_momentum.patch`) |
| `lh_domains.sh [run\|gdb\|gdbseed\|gdbhits]` | off-spill event 1430:3819:308303 (input I4): one LoopHelix seed fit builds ~157k B-field domains and spends 245 s in `nearestIndex`. Fixed by Mu2e/Offline#2044 (`patches/lh_seed_range.patch`) and KFTrack/KinKal#227 (`patches/nearestindex_bsearch.patch`) |
| `nearestindex_equiv.sh <fix-area>` (+ `.cc`) | header-only check that the binary-search `nearestIndex` returns the same index as the v3.8.0 linear scan, plus its timing |
| `inversion_dump.sh [NEV] [MAXMAT] [A2\|A5]` | dumps the real 6x6 matrices `KinKal::FitData::invert()` receives in reco (gdb breakpoint, no rebuild) |
| `inversion_bench.sh [dump.txt ...]` (+ `.cc`) | Bunch-Kaufman vs Cholesky on the dumped matrices: agreement, failures, instructions per call under callgrind |
| `inversion_fallback_count.sh <area> <NEV> [A2\|A5]` | how often the Cholesky path of KFTrack/KinKal#229 falls back to Bunch-Kaufman in reco |

`patches/` holds each fix as tested here (the merged PRs may differ in comments):

| Patch | Repository | PR |
|---|---|---|
| `nearestindex_bsearch.patch` | KinKal | KFTrack/KinKal#227 |
| `fitdata_invert_chol.patch` | KinKal | KFTrack/KinKal#229 |
| `interpcalib_stack.patch` | Offline | Mu2e/Offline#2043 |
| `lh_seed_range.patch` | Offline | Mu2e/Offline#2044 |
| `klts_zero_momentum.patch` | Offline | Mu2e/Offline#2042 |

The module and KinKal code are built `-O3`, so most locals are optimised out: the gdb modes read constructor arguments
from registers (x86-64 ABI) or use small gdb-python helpers on frames where the variables survive. The mode variable
is `RCA_MODE`, not `MODE`, because `setupmu2e-art.sh` overwrites `MODE`.
