# Mu2e reconstruction profiling, October 2026: findings, fixes and results

*R. Mina, 21 October 2026, updated 26 October 2026. Where Mu2e Offline reconstruction spends its CPU and memory, the
fixes made from the profiles, what they measured, and the leads that are still open.*

## Summary

- **Where the time goes.** Field-on reco is dominated by track fitting: the LoopHelix fits are 48 % (on-spill) to
  62 % (off-spill cosmics) of all instructions on head. Output writing (zlib) is 13-20 % of MC reco and about 65 % of
  KPP data reco. Pattern recognition is small (about 2.5 % on-spill).
- **Seven fixes merged.** The first five (KinKal#227, Offline#2042, #2043, #2044, #2048) together, on the same events,
  cut reco by **10-12 % instructions per event** on every workload measured. Heap allocations fell 26 %, and a 245 s
  off-spill event now takes 0.1 s.
- **The sixth, KinKal#229 (Cholesky inversion), merged on 2026-10-22.** On top of the first five it cuts a further
  **11.5 % (on-spill) and 14.2 % (off-spill) instructions per event**, with physics output statistically unchanged.
  Both KinKal fixes are in **KinKal v3.9.0** (23 October 2026), which envset p109 carries.
- **The seventh, Production#588 (merged 2026-10-24), writes reco output with ZSTD level 5** instead of art's default
  zlib level 7: CPU **-3.9 % on-spill MC and -21.6 % KPP data reco**, files 3-6 % smaller, reading back 13-16 % faster,
  output lossless.
- **Largest open leads:** MC truth matching spending time in `std::regex` (about 4-7 % of on-spill MC), the
  calorimeter template fit (5-8 % of on-spill), and fewer KinKal weight/parameter conversions (the remaining 4-5 %
  after #229).

## What was measured

| Item | Value |
|---|---|
| Baseline arm (`kkmain`, 2026-10-15) | Offline `ce894a55e`, KinKal v3.8.0, envset p108, Production `0d1c3703`; built `-O3 -g -fno-omit-frame-pointer` |
| Re-run arm (`head1019`, 2026-10-19) | Offline main `813ec61e0` + #2042, KinKal main `14fd2235a` (with #227), Production `efebc0a2a` |
| Phase 1 (module level) | 43 FermiGrid jobs: art TimeTracker + MemoryTracker; each test runs its baseline first **on the same node** (grid CPU models differ by up to 2x, so times are only compared within one job; null jobs agree to 0.3 %) |
| Phase 2 (function level) | valgrind 3.23 callgrind on full workloads (instruction counts do not depend on the node), massif (heap), DHAT (allocation churn), plus single-event runs for outliers |
| Re-run on head | 51 grid jobs, the same events as the baseline, so the two arms compare directly |

Workloads (all `MDC2025` digis unless noted):

| Id | Workload | Job configuration |
|---|---|---|
| A2 | on-spill CE + 1BB pileup | `recoMC/OnSpill.fcl` |
| A5 | off-spill cosmics (CentralHelix + four LoopHelix fits) | `recoMC/OffSpill.fcl` |
| A6 | extracted cosmics, field off (KinematicLine) | `recoMC/Extracted.fcl`, extracted v04 |
| A8 | KPP real data, run 124155 (KinematicLine) | data reco on the unpacked raw file |

## Where reco spends its time (head of main, `head1019`)

Instructions per event, callgrind:

| Workload | `kkmain` | `head1019` | Change |
|---|---|---|---|
| A2 on-spill CE+1BB (400 events) | 1,053 M | 928 M | **-11.9 %** |
| A5 off-spill cosmics (400 events, different event ranges) | 1,335 M | 1,169 M | -12.4 % (indicative) |
| A6 extracted MC (1,500 events) | 61.5 M | 54.2 M | **-11.8 %** |
| A8 KPP data (1,500 events) | 114.0 M | 102.7 M | **-10.0 %** |

Hottest functions (exclusive share of event-processing instructions):

<!-- widths: 30 8 8 8 8 38 -->
| Function | A2 | A5 | A6 | A8 | Note |
|---|---|---|---|---|---|
| `InvertBunchKaufman` behind KinKal `FitData::invert` | **14.9 %** | **17.7 %** | **14.1 %** | 2.9 % | now the top function wherever a fit runs; addressed by KinKal#229 (merged 2026-10-22, not in this profile) |
| zlib (largest entry, under `RootOutput`) | 4.2 % | 6.0 % | 6.7 % | **22.8 %** | the whole write is 13-20 % of MC and ~65 % of A8; reco output is ZSTD 5 since Production#588 (merged 2026-10-24, not in this profile) |
| libm `sin`/`cos` | 5.6 % | 9.3 % | 6.7 % | 2.2 % | POCA trigonometry in `LoopHelix` |
| calo template fit `myfcn` | 4.5 % | - | 3.2 % | - | Minuit numerical derivatives |
| `std::regex` (art `Ptr` type names) | 3.9 % | - | 2.9 % | - | calo truth matching, `CompressDigiMCs` |
| `PiecewiseTrajectory::nearestIndex` | 1.8 % | 2.7 % | 1.2 % | - | was 10.4 % / 16.1 % / 1.9 % before KinKal#227 |

Configuration costs (phase 1, same-node ratios against the baseline; these change physics, so they are measurements,
not proposals):

| Option | Effect on CPU |
|---|---|
| Background-hit flagging off | 2.4x (flagging pays for itself many times over) |
| LoopHelix B-field correction off | -22 to -26 % |
| ANN meta-iterations 9 -> 3 | -23 to -26 % |
| No output module | -15 % (on-spill) |
| `BCorrTolerance` 1e-4 -> 1e-3 | -16 % |
| Pattern-recognition family choice | -7 to -28 % |
| 4 threads | at most 1.12x throughput: process-level parallelism fills a node better |

Memory: the heap is about 765 MB on-spill, 885 MB off-spill and 260 MB extracted. It is reached during initialisation
and stays flat through the event loop (no leak); half of it (387 MB) is the B-field map. Peak RSS (1.1-1.3 GB) is not
a constraint. On-spill reco made 548k heap allocations per event before the fixes and 406k after.

## Defects found by the profiling

1. **`KLTruthSeed` aborted the job on 2.0 % of extracted MC events** (577 of 28,764, "Inversion failure"). The truth
   state nearest a reco piece could be a stopped muon's end point (|p| = 0), which gives a KinematicLine with
   t0 = NaN. Fixed by Offline#2042.
2. **One off-spill event spent 245 s in a single LoopHelix fit** (21 % of its whole job). The seed accepted straw hits
   from the wrong helix turn, which stretched the fit range to 780 us; the domain walk and the linear piece search
   then cost O(N^2) over ~157k domains. Fixed by Offline#2044. The linear search itself was fixed by KinKal#227.

## Fixes and their results

<!-- widths: 13 28 26 22 11 -->
| PR | Change | Measured gain | Effect on output | State |
|---|---|---|---|---|
| [KFTrack/KinKal#227](https://github.com/KFTrack/KinKal/pull/227) | `PiecewiseTrajectory::nearestIndex`: binary search (`std::lower_bound`) instead of a linear scan over pieces (1,233 -> 193 instructions per call) | same host, same events: A2 CPU -5.1 %, median event -4.8 %; A5 mean event -15.8 %, median -9.8 %; every fit module -9 to -13 % | bitwise identical (A2 2,000 events; A5 CentralHelix 10k events) | merged 2026-10-17; in KinKal v3.9.0 |
| [Mu2e/Offline#2043](https://github.com/Mu2e/Offline/pull/2043) | `StrawResponse::interpolateCalib`: stack buffers instead of two `std::vector` per call (22 % of all heap allocations) | A2 CPU -2.9 %; removes 22 % of heap allocations per event | bitwise identical (2,000 events) | merged 2026-10-17 |
| [Mu2e/Offline#2044](https://github.com/Mu2e/Offline/pull/2044) | LoopHelix seed: new `MaxSeedStrawHitDt` cut (200 ns) drops seed straw hits whose closest approach is far from their measured time | A5 same-host CPU -7.5 %; the outlier event 29-245 s -> 0.09 s | CE+1BB bitwise identical; off-spill pass counts identical | merged 2026-10-17 |
| [Mu2e/Offline#2042](https://github.com/Mu2e/Offline/pull/2042) | `KKTruthSeed`: skip zero-momentum MC trajectory points and non-finite truth pieces | robustness: the job no longer aborts. The diagnostic it enables costs +7 % of extracted MC reco | no change except that the affected events now get a truth seed | merged 2026-10-21 |
| [Mu2e/Offline#2048](https://github.com/Mu2e/Offline/pull/2048) | `MakeCrvRecoPulses`: dedicated Levenberg-Marquardt fit of the 3-parameter Gumbel on its samples instead of `TGraph::Fit` + Minuit2 per pulse | `CrvRecoPulsesFinder` 3.1-3.6x fewer instructions, **4.3-4.9x faster**; A8 share 12.0 % -> 3.7 % | statistical: pulse PE and time within 1e-4 to 1e-3; failed-fit flag agreement 99.98-99.99 % | merged 2026-10-19 |
| [KFTrack/KinKal#229](https://github.com/KFTrack/KinKal/pull/229) | `FitData::invert`: Cholesky (`SMatrix::InvertChol`) for the symmetric positive-definite 6x6 matrices, with Bunch-Kaufman as a fallback (taken by 0.08-0.10 % of calls) | ~811 instead of ~3,300 instructions per inversion; reco **-11.5 % (A2) / -14.2 % (A5)** instructions per event; LoopHelixFit -22 to -24 %; same-host A2 event mean -16 %, median -3.4 % | statistical A/B: truth-matched efficiency ratio 1.0002 (CE+1BB, 24,950 events), 1.0000 (off-spill CentralHelix), 0.9999 (extracted KinematicLine); every per-track mean shift within 1.1 sigma; KinKal unit tests 26/26 | merged 2026-10-22; in KinKal v3.9.0 |
| [Mu2e/Production#588](https://github.com/Mu2e/Production/pull/588) | Reco output (`Reconstruction.Output`, `RegrowOutput`) written with ZSTD level 5 (`compressionLevel : 505`) instead of art's default zlib level 7; chosen from four settings measured with this harness (zlib 1 and LZ4 4 save more CPU but make files 3-19 % larger) | through the real job configurations, same events, same host: `recoMC/OnSpill.fcl` 500 events CPU -3.9 %, `reco/Extracted.fcl` KPP data 2,000 events -21.6 %; files -2.7 % / -5.7 %; full read-back -13 % / -16 % | lossless: EventNtuples bit-identical (481 leaves on-spill, 152 KPP); one job reads a mix of zlib and ZSTD inputs | merged 2026-10-24 |

How the fixes were validated: changes that should not alter output had to be bitwise identical (every leaf of the
EventNtuple, `--rtol 0`). Changes that alter the last digits of a fit (#2048, #229) were compared statistically on
the same events: yields, truth-matched efficiency, and per-track parameter means and widths.

KinKal v3.9.0 (23 October 2026) contains #227 and #229; Offline main builds against it since moving to envset p109
(23 October).

## Open leads, ranked by ceiling

A ceiling is the Amdahl bound: the share of instructions the targeted code holds. Real gains are a fraction of it.

<!-- widths: 3 26 30 14 11 16 -->
| # | Lead | Evidence | Ceiling | Owner | Effect on output |
|---|---|---|---|---|---|
| 1 | Faster KinKal weight/parameter conversions | **first step merged: KinKal#229** (above; the inversion falls from 14.9 % / 17.7 % to 4.3 % / 5.2 % of A2 / A5). A further step would skip re-converting states that did not change (`DomainWall::process`, `Material::process` call `FitState::wData()`) | the remaining ~4-5 % plus the conversions saved by caching | KinKal | statistical |
| 2 | Resolve MC `art::Ptr`s once per collection (`CaloHitTruthMatch`, `CompressDigiMCs`), or cache `uniform_type_name` in art | `CaloHitTruthMatch` 7.7 % of A2, 96 % of it in `std::regex` (1,420 lookups per event); 4.6 % of allocations | ~7 % of on-spill MC | Offline or art | bitwise |
| 3 | Calo template fit: analytic gradient, skip the Hessian when unused, reuse one `TMinuit` per module | `CaloRecoDigiMaker` 11 % of A2: 41 % numerical derivatives, 26 % numerical Hessian; a new `TMinuit` per fit = 3.5 % of allocations | ~5-8 % of on-spill | Offline (calo) | statistical (bitwise for `TMinuit` reuse alone) |
| 4 | CentralHelix DS-material extrapolation: a bounding test before each `stepIntersect` | the CRV extrapolation is 20 % of a CentralHelix-only job | most of that 20 %, in CentralHelix jobs | Offline, KinKal | bitwise if conservative |
| 5 | POCA trigonometry: one `sincos` per time in `LoopHelix::localPosition`/`localDirection` | libm 5.6-9.3 %; ~190k `localPosition` calls per event | a few % | KinKal | bitwise if the values match |
| 6 | Drop unused input products at read (`source.inputCommands`) | lazy SimParticle reads are 72 % of `SelectRecoMC` (6.4 % of A2) | part of 6 % | Production | bitwise if nothing downstream needs them |
| 7 | Memory: B-field map in single precision, or only the maps a job needs | 387 MB of the ~765 MB heap | 200-350 MB RSS per job (matters for multi-schedule jobs and HPC nodes) | Offline | needs a fit A/B |

Output compression, lead 2 in the first version of this report, is done (Production#588, above). Still to measure:
the libm entries (debug symbols for libm); DHAT on off-spill and extracted (only on-spill has allocation data); the
remaining 4-6 s off-spill events, which come from a mechanism different from the one #2044 fixed.

## Repository layout

| Path | What |
|---|---|
| `tests.txt` | every profiling job: `id base db variants input N [threads]` |
| `pairs.txt` | the baseline each test is paired with on the same node |
| `inputs.txt` | inputs I1-I7: the `MDC2025` digi files and the KPP raw file, by dCache path |
| `fcl/base_*.fcl` | one per reco flavour, thin wrappers of `Production/JobConfig/{reco,recoMC}` |
| `fcl/v_*.fcl` | one configuration change each (stackable, e.g. `ch_only,ch_bfcorr`) |
| `fcl/db_*.fcl`, `fcl/prof_*.fcl` | conditions matching each input; TimeTracker/MemoryTracker or the valgrind variant |
| `fcl/kpp/` | KPP run-124155 unpack and reco configuration ([README](fcl/kpp/README.md)) |
| `setup_area.sh` | clones a muse work area for one arm or fix from GitHub at its pinned commits |
| `env.sh` | output locations (`RP_OUT`, `RP_PNFS`) and search paths, sourced by every script |
| `check_fcl.sh`, `run_profile.sh` | resolve every job configuration; run one job interactively |
| `grid/` | `submit_profile.sh` (dry run by default) and the worker `grid_profile.sh`; `fetch_*.sh` copy results back |
| `recoprof/` | analysis of the outputs: callgrind summaries and call chains, paired-timing tables, arm comparisons, memory, exact ntuple comparison ([README](recoprof/README.md)) |
| `rca/` | reproductions of the two defects and of the fixes' checks, and the fixes as patches ([README](rca/README.md)) |
| `tools/build_kinkal_into_area.sh` | builds a KinKal checkout into a muse area, for the KinKal arms |

## Reproducing or extending the profiles

Run on a Mu2e interactive node with `/cvmfs` and the grid tools; nothing here needs anything outside this repository
and the public Mu2e repositories, except the KPP calibration set for the three KPP data tests
([fcl/kpp/README.md](fcl/kpp/README.md)).

1. **Make and build an area** for the arm (`kkmain`, `head1019`, or a fix such as `fix_invchol`):

   ```bash
   ./setup_area.sh head1019 /exp/mu2e/app/users/$USER/head1019     # prints the build command
   ```

2. **Check every job configuration** resolves (`fhicl-dump` only, no event processing):

   ```bash
   ./check_fcl.sh /exp/mu2e/app/users/$USER/head1019
   ```

3. **Submit to the grid.** Make the code tarball once (`muse tarball` in the area), then run the job waves; every
   art-timing job runs its paired baseline first on the same node. Outputs go to `$RP_PNFS/<arm>/` (default
   `/pnfs/mu2e/scratch/users/$USER/reco_profile`); prestage the inputs in `inputs.txt` first.

   ```bash
   grid/submit_profile.sh --arm head1019 --code Code.tar.bz2 --wave 1             # dry run; add --submit
   grid/submit_profile.sh --arm head1019 --wave 3 --submit                        # configuration tests
   grid/submit_profile.sh --arm head1019 --tool callgrind --nevents 400 --dump run --tag full --tests A2-ce --submit
   grid/submit_profile.sh --arm head1019 --tool massif --nevents 200 --tests A2-ce --tag mem --submit
   grid/submit_profile.sh --arm head1019 --tool dhat --nevents 200 --tests A2-ce --tag mem --submit
   grid/fetch_arm.sh head1019                                                      # pnfs -> $RP_OUT/head1019
   ```

   `run_profile.sh <area> <test-id>` runs a single job interactively instead.

4. **Read the results** with `recoprof`:

   ```bash
   python3 -m recoprof pairtable $RP_OUT/head1019 --out pairs.md            # each test vs its same-node baseline
   python3 -m recoprof cgsummary $RP_OUT/head1019/A2-ce_callgrind_full --n 40 --out A2.md
   python3 -m recoprof armcompare $RP_OUT/kkmain $RP_OUT/head1019 --out arms.md
   python3 -m recoprof memcompare $RP_OUT/kkmain $RP_OUT/head1019 --out mem.md
   ```

5. **Test a fix:** make its area (`./setup_area.sh fix_invchol <dir>`), build it, and compare against the arm it was
   made from on the same node: `recoprof abtiming` on the two TimeTracker databases for timing,
   `recoprof abidentical` on the two EventNtuples for changes that must not alter output.

The callgrind instruction counts of a new release compare directly with the numbers above; times only compare
within a paired job.

Questions and suggestions are welcome, as are owners for the open leads.
