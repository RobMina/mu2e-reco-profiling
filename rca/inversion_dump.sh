#!/bin/bash
# inversion_dump.sh [NEV] [MAXMAT] [WORKLOAD] -- dump real 6x6 matrices that KinKal::FitData::invert() receives in reco,
# with a gdb breakpoint (no rebuild): one line per call, 21 lower-triangle values of mat_ before inversion.
# WORKLOAD: A2 (on-spill CE+1BB, I2) or A5 (off-spill cosmics, I4); env AREA = a built muse area. One job per node.
# Output: $RP_OUT/rca/inversion/dump_<WORKLOAD>.txt (input of inversion_bench.sh).
RCA_NEV=${1:-2}; RCA_MAX=${2:-100000}; RCA_WL=${3:-A2}
source "$(dirname "$0")/../env.sh"
AREA=${AREA:?set AREA to a built muse area}
HERE=$RP_HOME
OUT=$RP_OUT/rca/inversion
source /cvmfs/mu2e.opensciencegrid.org/setupmu2e-art.sh >/dev/null 2>&1
cd "$AREA" && muse setup >/dev/null 2>&1
[ "$MUSE_WORK_DIR" = "$AREA" ] || { echo "FATAL: muse setup did not take ($MUSE_WORK_DIR)"; exit 3; }
rp_paths
mkdir -p "$OUT" && cd "$OUT" || exit 2
case "$RCA_WL" in
  A2) IN=$(awk '$1=="I2"{print $2}' "$HERE/inputs.txt"); BASE=onspill_mc; DB=v1_3 ;;
  A5) IN=$(awk '$1=="I4"{print $2}' "$HERE/inputs.txt"); BASE=offspill_mc; DB=v1_5 ;;
  *) echo "unknown workload $RCA_WL"; exit 2 ;;
esac
printf '#include "base_%s.fcl"\n#include "db_%s.fcl"\nservices.TFileService.fileName : "/dev/null"\n' "$BASE" "$DB" >| dump_$RCA_WL.fcl
for o in LoopHelixOutput CentralHelixOutput; do printf 'outputs.%s.fileName : "/dev/null"\n' $o >> dump_$RCA_WL.fcl; done
# gdb: at each FitData::invert(), print the 21 packed values of the symmetric matrix (MatRepSym fArray), then continue
cat >| dump_$RCA_WL.gdb <<EOF
set pagination off
set confirm off
set breakpoint pending on
set print elements 32
set print repeats unlimited
break KinKal::FitData::invert
commands
silent
printf "M"
set \$i = 0
while \$i < 21
  printf " %.17g", this->mat_.fRep.fArray[\$i]
  set \$i = \$i + 1
end
printf "\n"
set \$n = \$n + 1
if \$n >= $RCA_MAX
  kill
  quit
end
continue
end
set \$n = 0
run
quit
EOF
gdb -q -batch -x dump_$RCA_WL.gdb --args mu2e -c dump_$RCA_WL.fcl -s "$IN" -n "$RCA_NEV" >| gdb_$RCA_WL.log 2>&1
echo "gdb exit=$?"
grep '^M ' gdb_$RCA_WL.log | cut -c3- >| dump_$RCA_WL.txt
echo "matrices dumped: $(wc -l < dump_$RCA_WL.txt) -> $OUT/dump_$RCA_WL.txt"
grep -m3 -iE "Breakpoint 1 at|No symbol|not defined|error" gdb_$RCA_WL.log
