#!/bin/bash
# inversion_fallback_count.sh AREA NEV [WORKLOAD] -- count how often FitData::invert takes the Bunch-Kaufman fallback in reco
# (Cholesky refused) versus all calls, with gdb breakpoints and no rebuild: ignore-count on InvertBunchKaufman and
# InvertChol's decomposer. WORKLOAD A2 (I2) or A5 (I4). One job per node.
# Output: $RP_OUT/rca/inversion/fallback_<WORKLOAD>_<area>.txt
AREA=${1:?area}; NEV=${2:-5}; WL=${3:-A2}
source "$(dirname "$0")/../env.sh"
H=$RP_HOME
OUT=$RP_OUT/rca/inversion
source /cvmfs/mu2e.opensciencegrid.org/setupmu2e-art.sh >/dev/null 2>&1
cd "$AREA" && muse setup >/dev/null 2>&1
[ "$MUSE_WORK_DIR" = "$AREA" ] || { echo "FATAL: muse setup did not take ($MUSE_WORK_DIR)"; exit 3; }
rp_paths
mkdir -p "$OUT" && cd "$OUT" || exit 2
case "$WL" in
  A2) IN=$(awk '$1=="I2"{print $2}' "$H/inputs.txt"); BASE=onspill_mc; DB=v1_3 ;;
  A5) IN=$(awk '$1=="I4"{print $2}' "$H/inputs.txt"); BASE=offspill_mc; DB=v1_5 ;;
esac
TAG=${WL}_$(basename "$AREA")
printf '#include "base_%s.fcl"\n#include "db_%s.fcl"\nservices.TFileService.fileName : "/dev/null"\n' "$BASE" "$DB" >| fb_$TAG.fcl
for o in LoopHelixOutput CentralHelixOutput; do printf 'outputs.%s.fileName : "/dev/null"\n' $o >> fb_$TAG.fcl; done
# breakpoints that only count (a hit count with no stop), printed at exit
cat >| fb_$TAG.gdb <<'EOF2'
set pagination off
set confirm off
set breakpoint pending on
rbreak ^void ROOT::Math::Inverter<6u, 6u>::InvertBunchKaufman<double>
rbreak ^ROOT::Math::CholeskyDecompHelpers::_decomposer<double, 6u
ignore 1 100000000
ignore 2 100000000
run
info breakpoints
quit
EOF2
gdb -q -batch -x fb_$TAG.gdb --args mu2e -c fb_$TAG.fcl -s "$IN" -n "$NEV" >| fb_$TAG.log 2>&1
echo "gdb exit=$?"
grep -E "breakpoint already hit|^[0-9]+ +breakpoint" fb_$TAG.log | tee fallback_$TAG.txt
