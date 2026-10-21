#!/bin/bash
# check_fcl.sh <area> [test-id ...] -- compose each test's job.fcl and resolve it with fhicl-dump only (no mu2e job, no
# build). Needs a built area (fhicl-dump and the generated trig-config fcl exist only after the build). Writes to /tmp.
AREA=$1; shift
source "$(dirname "$0")/env.sh"
HERE=$RP_HOME
source /cvmfs/mu2e.opensciencegrid.org/setupmu2e-art.sh >/dev/null 2>&1 || true
setup muse >/dev/null 2>&1; cd "$AREA" || exit 2; muse setup >/dev/null 2>&1 || true
[ "$MUSE_WORK_DIR" != "$AREA" ] && { echo "FATAL: muse setup did not take"; exit 3; }
rp_paths
T=/tmp/$USER/reco_profile_check; mkdir -p $T
IDS="$*"; [ -z "$IDS" ] && IDS=$(awk '!/^#/ && NF {print $1}' "$HERE/tests.txt")
for id in $IDS; do
  read -r _ BASE DB VARS _ < <(awk -v id="$id" '$1==id' "$HERE/tests.txt")
  { echo "#include \"base_$BASE.fcl\""; [ "$VARS" != "-" ] && for v in ${VARS//,/ }; do echo "#include \"v_$v.fcl\""; done
    echo "#include \"db_$DB.fcl\""; echo "#include \"prof_services.fcl\""; } >| $T/$id.fcl
  if fhicl-dump -c $T/$id.fcl >| $T/$id.cfg 2>&1; then echo "OK   $id"; else echo "FAIL $id: $(grep -m1 -iE 'error|cannot|not found' $T/$id.cfg)"; fi
done
