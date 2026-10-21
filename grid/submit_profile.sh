#!/bin/bash
# submit_profile.sh [--code Code.tar.bz2 | --use-staged] [--arm NAME] [--wave 1|2|3 | --tests id,id,...] [--submit] [--force]
#
# Grid submission of reco_profile tests (one test per grid job, single core except the F3/F4 threading tests).
# Dry run by default: prints what it would stage and submit, and which tests already have done.txt. --submit launches.
#   --code PATH    muse tarball of the arm's area (Code.tar.bz2). Staged once to $PNFS_ROOT/<arm>/Code.tar.bz2.
#                  Build it once, with the user's go-ahead, on mu2ebuild02:  cd <area> && muse tarball
#   --use-staged   reuse $PNFS_ROOT/<arm>/Code.tar.bz2 (default when it exists)
#   --arm NAME     arm label (default kkmain); outputs under $PNFS_ROOT/<arm>/<test-id>/
#   --wave N       1 = baselines A1-A8 except dependent ones + R1; 2 = A9 A10 A8 E6 (need wave-1 outputs);
#                  3 = all B-F tests.   --tests overrides.
#   --force        rerun tests that already have done.txt (worker FORCE=1)
#   --tool T       callgrind | massif | dhat: run the test under valgrind (outputs <id>_<T>/); needs --nevents
#   --nskip K      skip the first K input events (RootInput --nskip; e.g. to start past a known outlier)
#   --tag T        output dir suffix <id>[_<tool>]_<T> (keeps earlier runs of the same test)
#   --dump M       callgrind dumps: event (default, one per event) or run (init / whole run / end job; for long runs)
#   --nevents N    events per job (overrides tests.txt; required with --tool, size from the art-timing job)
#   --lifetime L   jobsub --expected-lifetime (default 8h)
#   --event R:S:E  start at run:subrun:event, 1 event unless --nevents (outputs <id>[_<tool>]_evt<E>/); never paired
#   --smoke        construction check: 2 events per test, no baseline, outputs <id>_smoke/ (never touches <id>/)
#   --nopair       do not run the paired baseline (pairs.txt) on the same node before each art-timing test
# Art-timing tests run their pairs.txt baseline first in the same job (same CPU model and load), outputs
# <id>/base_<baseline>/, so each job costs baseline + test.
# aux.tgz (this repository's tables and fcl, plus $RP_KPP_CALIB if set) is rebuilt and
# staged under a new name (aux/aux_<time>.tgz) on every --submit: fcl edits need no new tarball, and queued jobs of an
# earlier submit keep fetching their own copy.
# Prereqs on the submit host (a GPVM): source setupmu2e-art.sh; muse setup ops; valid token (htgettoken).
# Outputs go to $RP_PNFS/<arm>/ (env.sh).
set -o pipefail
source "$(dirname "$0")/../env.sh"
HERE=$RP_HOME
PNFS_ROOT=$RP_PNFS
ARM=kkmain; CODE=""; WAVE=""; TESTS=""; SUBMIT=0; FORCE=0; TOOL=""; NEV=""; LIFE=8h; PAIR=1; EVENT=""; TAG=""; DUMP=""; NSKIPV=""
while [ $# -gt 0 ]; do
  case "$1" in
    --code) CODE=$2; shift ;; --use-staged) CODE=staged ;; --arm) ARM=$2; shift ;;
    --wave) WAVE=$2; shift ;; --tests) TESTS=$2; shift ;; --submit) SUBMIT=1 ;; --force) FORCE=1 ;;
    --tool) TOOL=$2; shift ;; --nevents) NEV=$2; shift ;; --lifetime) LIFE=$2; shift ;; --nopair) PAIR=0 ;; --event) EVENT=$2; PAIR=0; shift ;; --dump) DUMP=$2; shift ;; --nskip) NSKIPV=$2; shift ;; --tag) TAG=$2; shift ;; --smoke) TAG=smoke; PAIR=0; NEV=2; LIFE=2h ;;
    *) echo "unknown option $1"; exit 2 ;;
  esac; shift
done
case "$WAVE" in
  1) TESTS=${TESTS:-A2-ce,A1-np,A3-ceend,A4-coson,A5-cosoff,A6-ext,A7-kppunp,R1-ce-rep} ;;
  2) TESTS=${TESTS:-A9-rglh,A10-rgkl,A8-kpp,E6-klnocrv-kpp} ;;
  3) TESTS=${TESTS:-$(awk '!/^#/ && NF && $1 ~ /^[B-F]/ && $1 != "E6-klnocrv-kpp" {print $1}' $HERE/tests.txt | paste -sd,)} ;;
esac
[ -z "$TESTS" ] && { echo "give --wave or --tests"; exit 2; }
[ -n "$TOOL" ] && [ -z "$NEV" ] && [ -z "$EVENT" ] && { echo "--tool needs --nevents (valgrind is 20-100x slower)"; exit 2; }

OUTROOT=$PNFS_ROOT/$ARM
PNFS_CODE=$OUTROOT/Code.tar.bz2
PNFS_AUX=$OUTROOT/aux/aux_$(date +%Y%m%d_%H%M%S).tgz   # one per submit: queued jobs keep their own copy
OUT_TOKEN=$(echo "$OUTROOT" | sed 's|^/pnfs/mu2e|/mu2e|')
WRAPPER=$HERE/grid/grid_profile.sh

# classify tests: already done / blocked on a missing upstream output / to submit (by thread count)
declare -A BYTHR; NSUB=0
for id in ${TESTS//,/ }; do
  read -r _ _ _ _ INPUT _ THR < <(awk -v id="$id" '$1==id' $HERE/tests.txt)
  [ -z "$INPUT" ] && { echo "unknown test $id"; exit 2; }
  if [ $FORCE = 0 ] && ifdh ls "$OUTROOT/$id${TOOL:+_$TOOL}${EVENT:+_evt${EVENT##*:}}${TAG:+_$TAG}/done.txt" >/dev/null 2>&1; then echo "done     $id${TOOL:+_$TOOL}${EVENT:+_evt${EVENT##*:}}${TAG:+_$TAG}"; continue; fi
  case "$INPUT" in
    S:*) need=$OUTROOT/${INPUT#S:}/reco.art ;; U:*) need=$OUTROOT/${INPUT#U:}/dig.art ;; *) need="" ;;
  esac
  if [ -n "$need" ] && ! ifdh ls "$need" >/dev/null 2>&1; then echo "blocked  $id (needs $need)"; continue; fi
  b=""; [ -z "$TOOL" ] && [ $PAIR = 1 ] && b=$(awk -v id="$id" '!/^#/ && $1==id {print $2}' $HERE/pairs.txt); [ "$b" = "-" ] && b=""
  t=${THR:-1}; BYTHR[$t]="${BYTHR[$t]:+${BYTHR[$t]},}$id"; NSUB=$((NSUB+1)); echo "submit   $id (threads $t${b:+, baseline $b first})"
done
[ $NSUB = 0 ] && { echo "nothing to submit"; exit 0; }

if [ "$CODE" = "" ] || [ "$CODE" = staged ]; then
  ifdh ls "$PNFS_CODE" >/dev/null 2>&1 || { echo "ERROR: no staged code tarball at $PNFS_CODE; pass --code <Code.tar.bz2>"; exit 2; }
  echo "code     $PNFS_CODE (staged)"
else
  [ -f "$CODE" ] || { echo "ERROR: $CODE not found"; exit 2; }
  echo "code     $CODE -> $PNFS_CODE ($(du -h "$CODE" | cut -f1))"
fi
[ -n "$TAG" ] && echo "tag      $TAG: outputs <id>${TOOL:+_$TOOL}_$TAG/${NSKIPV:+, nskip $NSKIPV}"
[ -n "$EVENT" ] && echo "event    $EVENT (${NEV:-1} event(s) from there)"
[ -n "$TOOL" ] && echo "tool     $TOOL (dump ${DUMP:-event}), ${NEV:-1} events/job, lifetime $LIFE, memory 8000MB"
echo "aux      -> $PNFS_AUX ;  outputs -> $OUTROOT/<id>/ ;  token scope $OUT_TOKEN"

if [ $SUBMIT = 0 ]; then echo "(dry run; add --submit)"; exit 0; fi

ifdh mkdir_p "$OUTROOT" 2>/dev/null
if [ -n "$CODE" ] && [ "$CODE" != staged ]; then
  ifdh rm "$PNFS_CODE" >/dev/null 2>&1; ifdh cp "$CODE" "$PNFS_CODE" || { echo "ERROR: stage code"; exit 1; }
fi
AUXTMP=$(mktemp -d)
mkdir -p $AUXTMP/reco_profile
cp -r $HERE/tests.txt $HERE/inputs.txt $HERE/pairs.txt $HERE/fcl $AUXTMP/reco_profile/ || exit 1
[ -n "$RP_KPP_CALIB" ] && { cp -r "$RP_KPP_CALIB" $AUXTMP/kpp_calib || exit 1; }
tar czf $AUXTMP/aux.tgz -C $AUXTMP --exclude='__pycache__' reco_profile $([ -n "$RP_KPP_CALIB" ] && echo kpp_calib) || exit 1
ifdh mkdir_p "$OUTROOT/aux" 2>/dev/null; ifdh cp $AUXTMP/aux.tgz "$PNFS_AUX" || { echo "ERROR: stage aux"; exit 1; }
rm -rf $AUXTMP

for t in "${!BYTHR[@]}"; do
  L=${BYTHR[$t]}; n=$(echo "$L" | tr , '\n' | wc -l)
  mem=4000; [ "$t" -gt 1 ] && mem=$((2500 + 1500*t)); [ -n "$TOOL" ] && mem=8000
  echo "jobsub: $n job(s), --cpu=$t --memory=${mem}MB : $L"
  jobsub_submit -G mu2e --role=Analysis -N "$n" \
    --cpu="$t" --memory="${mem}MB" --disk=20GB --expected-lifetime=$LIFE \
    --resource-provides=usage_model=DEDICATED,OPPORTUNISTIC --lines='+FERMIHTC_AutoRelease=True' \
    --need-storage-modify="$OUT_TOKEN" \
    -e TESTS="$L" -e CODE_TARBALL="$PNFS_CODE" -e AUX_TARBALL="$PNFS_AUX" -e FORCE="$FORCE" -e PAIR="$PAIR" ${TOOL:+-e TOOL=$TOOL} ${NEV:+-e N=$NEV} ${EVENT:+-e EVENT=$EVENT} ${TAG:+-e TAG=$TAG} ${DUMP:+-e DUMP=$DUMP} ${NSKIPV:+-e NSKIP=$NSKIPV} \
    "file://$WRAPPER" "$OUTROOT"
done
echo "Monitor: jobsub_q -G mu2e --user $USER ; results: $OUTROOT/<id>/"
