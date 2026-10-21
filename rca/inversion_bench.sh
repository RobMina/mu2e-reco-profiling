#!/bin/bash
# inversion_bench.sh [dump.txt ...] (env AREA=<built muse area>, for the compiler and ROOT) -- compile and run inversion_bench.cc (ROOT SMatrix headers only, no library, not a
# build) with the area's compiler and flags close to the release (-O3, x86-64-v2), then the same binary
# under callgrind for instructions per call. Outputs in $RP_OUT/rca/inversion/.
# No `set -u` (setupmu2e-art.sh).
HERE=$(cd "$(dirname "$0")" && pwd)
source "$(dirname "$0")/../env.sh"
AREA=${AREA:?set AREA to a built muse area}
OUT=$RP_OUT/rca/inversion
source /cvmfs/mu2e.opensciencegrid.org/setupmu2e-art.sh >/dev/null 2>&1 || true
cd "$AREA" && muse setup >/dev/null 2>&1 || true
set -e
mkdir -p "$OUT"
echo "host=$(hostname) cpu=$(grep -m1 'model name' /proc/cpuinfo | cut -d: -f2) root=$(root-config --version) gcc=$(g++ -dumpversion)"
g++ -std=c++20 -O3 -march=x86-64-v2 -Wall -Wextra -I"$(root-config --incdir)" "$HERE/inversion_bench.cc" -o "$OUT/inversion_bench"
"$OUT/inversion_bench" "$@" | tee "$OUT/inversion_bench.txt"

# instructions per call (10,000 matrices each), comparable with the reco callgrind Ir/call of InvertBunchKaufman
cd "$OUT"
for f in runBK runChol; do
  valgrind --tool=callgrind --callgrind-out-file=cg_$f.out --toggle-collect="$f*" "$OUT/inversion_bench" --irpercall >/dev/null 2>cg_$f.err
  ir=$(grep -E "^(summary|totals):" cg_$f.out | head -1 | awk '{print $2}')
  echo "callgrind $f: $ir Ir for 10000 copies+inversions = $((ir / 10000)) Ir/call"
done
echo INVERSION_BENCH_DONE
