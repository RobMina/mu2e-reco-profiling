#!/bin/bash
# klts_inversion.sh [run|gdb|gdbvars|gdbstate|scan] (env AREA=<built muse area>) -- reproduce E5: extracted reco + KLTruthSeed on I6, start at the failing event 1400:1974:4985.
#   no arg: plain run with KLTruthSeed debug 1 (log.txt); "gdb": same under gdb, catch throw, backtrace (gdb.txt);
#   "scan": run all of I6 with SkipEvent on StdException, list the failing events (scan.txt);
#   "gdbstate": print each truth state the module builds (gdb3.txt);
#   "gdbvars": catch throw and print the FitData, constraint parameters and hit times (gdb2.cmd, gdb2.txt).
# Input: I6 read in place from /pnfs (prestage first). AREA: a built muse area at the baseline commits. One job per node.
RCA_MODE=${1:-${RCA_MODE:-run}}   # not MODE: setupmu2e-art.sh overwrites it
RCA_EVENT=${RCA_EVENT:-4985}   # event number in run 1400 subrun 1974 (I6)
source "$(dirname "$0")/../env.sh"
AREA=${AREA:?set AREA to a built muse area}
HERE=$RP_HOME
OUT=$RP_OUT/rca/klts_inversion
source /cvmfs/mu2e.opensciencegrid.org/setupmu2e-art.sh >/dev/null 2>&1
cd "$AREA" && muse setup >/dev/null 2>&1
[ "$MUSE_WORK_DIR" = "$AREA" ] || { echo "FATAL: muse setup did not take ($MUSE_WORK_DIR)"; exit 3; }
rp_paths
mkdir -p "$OUT" && cd "$OUT" || exit 2
IN=$(awk '$1=="I6"{print $2}' "$HERE/inputs.txt")
cat > job.fcl <<'EOF'
#include "base_extracted_mc.fcl"
#include "v_kl_truthseed.fcl"
#include "db_v1_5.fcl"
services.TFileService.fileName : "/dev/null"
outputs.KinematicLineOutput.fileName : "/dev/null"
physics.producers.KLTruthSeed.debug : 1
source.firstRun : 1400
source.firstSubRun : 1974
source.firstEvent : RCA_EVENT
EOF
sed -i "s/RCA_EVENT/$RCA_EVENT/" job.fcl
if [ "$RCA_MODE" = gdbvars ]; then
  cat > gdb2.cmd <<'EOF2'
set pagination off
set print elements 64
catch throw
run
frame 1
p vec_.fArray
p mat_.fRep.fArray
frame 3
p time
p params.fitdata_.vec_.fArray
p params.fitdata_.mat_.fRep.fArray
frame 11
p hitTime
p truthHitTimes
quit
EOF2
  gdb -q -batch -x gdb2.cmd --args mu2e -c job.fcl -s "$IN" -n 1 > gdb2.txt 2>&1
  echo "gdb exit=$?"; grep -nE "^\\$[0-9]+ =" gdb2.txt | head -20
elif [ "$RCA_MODE" = scan ]; then
  # how often: all events of I6 with the patched-out exception counted by catching it per event (art keeps going)
  # job.fcl minus the start-event lines (not on FHICL_FILE_PATH, so copy rather than #include)
  grep -vE "^source\.first|KLTruthSeed.debug" job.fcl > scan.fcl
  echo 'services.scheduler.SkipEvent : [ "StdException" ]' >> scan.fcl
  mu2e -c scan.fcl -s "$IN" -n ${NSCAN:--1} > scan.txt 2>&1
  echo "exit=$?"; grep -E "TrigReport Events total|Inversion failure" scan.txt | sort | uniq -c | head
  grep -B4 "Inversion failure" scan.txt | grep -oE "run: [0-9]+ subRun: [0-9]+ event: [0-9]+" | sort -u | head -40
elif [ "$RCA_MODE" = gdbstate ]; then
  # print every truth state the module builds (pos, mom, time) and the resulting KinematicLine params
  # KinematicLine(VEC4 const& pos0, MOM4 const& mom0, int charge, VEC3 const& bnom, TimeRange const&): x86-64 ABI,
  # rdi=this rsi=&pos0 (x,y,z,t) rdx=&mom0 (px,py,pz,m) r8=&trange (begin,end); the module's piece constructor
  cat > gdb3.cmd <<'EOF2'
set pagination off
set breakpoint pending on
break _ZN6KinKal13KinematicLineC2ERKN4ROOT4Math13LorentzVectorINS2_9PxPyPzE4DIdEEEERKNS3_INS2_9PxPyPzM4DIdEEEEiRKNS2_20DisplacementVector3DINS2_11Cartesian3DIdEENS2_26DefaultCoordinateSystemTagEEERKNS_9TimeRangeE
commands
silent
printf "pos=(%.3f,%.3f,%.3f,t=%.4f) mom=(%.6g,%.6g,%.6g,m=%.5g) range=(%.4f,%.4f)\n", ((double*)$rsi)[0], ((double*)$rsi)[1], ((double*)$rsi)[2], ((double*)$rsi)[3], ((double*)$rdx)[0], ((double*)$rdx)[1], ((double*)$rdx)[2], ((double*)$rdx)[3], ((double*)$r8)[0], ((double*)$r8)[1]
continue
end
run
quit
EOF2
  gdb -q -batch -x gdb3.cmd --args mu2e -c job.fcl -s "$IN" -n 1 > gdb3.txt 2>&1
  echo "gdb exit=$?"; grep -E "^pos=" gdb3.txt | tail -3
elif [ "$RCA_MODE" = gdb ]; then
  cat > gdb.cmd <<'EOF'
set pagination off
set print pretty off
catch throw
run
bt 40
frame 0
info frame
quit
EOF
  gdb -q -batch -x gdb.cmd --args mu2e -c job.fcl -s "$IN" -n 1 > gdb.txt 2>&1
  echo "gdb exit=$?"; grep -nE "^#[0-9]+ " gdb.txt | head -40
else
  mu2e -c job.fcl -s "$IN" -n 1 > log.txt 2>&1
  echo "exit=$?"; grep -nE "KKTruthSeed|Inversion|Begin processing|Events total" log.txt | head -20
fi
