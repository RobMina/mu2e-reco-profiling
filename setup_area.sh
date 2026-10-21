#!/bin/bash
# setup_area.sh <arm> <dir> -- clone the source trees of one profiling arm from GitHub at its pinned commits into the
# new muse work area <dir>, apply the arm's patch if it has one, and print the build command. Runs no muse command.
#
# Arms:
#   kkmain    baseline of the first profile (2026-10-15): Offline ce894a55e, KinKal v3.8.0 (from the envset)
#   head1019  re-run on head (2026-10-19): Offline main 813ec61e0 + Mu2e/Offline#2042 (c240f2c53), KinKal main 14fd2235a
#   fix_klts | fix_lhseed | fix_interp      kkmain + one Offline patch from rca/patches/
#   fix_nidx                                kkmain + the KinKal nearestIndex patch (KinKal built into the area)
#   fix_invchol                             head1019 + the KinKal Cholesky patch (KinKal built into the area)
#
# KinKal: envset p108 ships KinKal v3.8.0, so kkmain and the Offline-only fixes use it as is. Arms with a KinKal
# checkout need tools/build_kinkal_into_area.sh after `muse build` (the script prints it).
# No `set -u` (setupmu2e-art.sh has unbound variables).
ARM=${1:?usage: $0 <arm> <dir>}; DIR=${2:?usage: $0 <arm> <dir>}
HERE=$(cd "$(dirname "$0")" && pwd)

declare -A URL=(
  [Offline]=https://github.com/Mu2e/Offline
  [Production]=https://github.com/Mu2e/Production
  [EventNtuple]=https://github.com/Mu2e/EventNtuple
  [mu2e-trig-config]=https://github.com/Mu2e/mu2e-trig-config
  [KinKal]=https://github.com/KFTrack/KinKal
)
# pinned commits per base arm
declare -A KKMAIN=(
  [Offline]=ce894a55e6af689753d690efe48fcbc7496ec0aa
  [Production]=0d1c3703784eeaca224366471f77f3b3dd8bdf1f
  [EventNtuple]=8b15a1c3aa86b931b6ad95dfaf8f67114cb51e1e
  [mu2e-trig-config]=ccc5ff59f0d05e42b23b2ad6a7689b3f53d8ea3f
  [KinKal]=71cc7d928d27b04d3475ac47bea29709481f32f4
)
declare -A HEAD1019=(
  [Offline]=813ec61e0e
  [Production]=efebc0a2acb13f188d6c56dfd69c5144bc8ee770
  [EventNtuple]=3f5abca5301fe195500e95f7d860b70d0a347565
  [mu2e-trig-config]=32aec90c3fbadddceb48cc1e31553cf7a04a0905
  [KinKal]=14fd2235a14423e4ce232076e86a51e30aa71ea3
)
OFFLINE_MERGE=""; PATCH=""; PATCH_REPO=""; KINKAL=0
case "$ARM" in
  kkmain)      BASE=KKMAIN ;;
  head1019)    BASE=HEAD1019; OFFLINE_MERGE=c240f2c538; KINKAL=1 ;;
  fix_klts)    BASE=KKMAIN; PATCH=klts_zero_momentum.patch;   PATCH_REPO=Offline ;;
  fix_lhseed)  BASE=KKMAIN; PATCH=lh_seed_range.patch;        PATCH_REPO=Offline ;;
  fix_interp)  BASE=KKMAIN; PATCH=interpcalib_stack.patch;    PATCH_REPO=Offline ;;
  fix_nidx)    BASE=KKMAIN; PATCH=nearestindex_bsearch.patch; PATCH_REPO=KinKal; KINKAL=1 ;;
  fix_invchol) BASE=HEAD1019; OFFLINE_MERGE=c240f2c538; PATCH=fitdata_invert_chol.patch; PATCH_REPO=KinKal; KINKAL=1 ;;
  *) echo "unknown arm $ARM"; exit 2 ;;
esac
declare -n SHA=$BASE

[ -e "$DIR" ] && { echo "$DIR exists -- not touching it"; exit 1; }
set -e
mkdir -p "$DIR"; cd "$DIR"
REPOS="Offline Production EventNtuple mu2e-trig-config"; [ $KINKAL = 1 ] && REPOS="$REPOS KinKal"
for p in $REPOS; do
  git clone -q "${URL[$p]}" "$p"
  git -C "$p" checkout -q "${SHA[$p]}"
  printf '  %-18s %s\n' "$p" "$(git -C "$p" rev-parse --short HEAD)"
done
if [ -n "$OFFLINE_MERGE" ]; then
  # Mu2e/Offline#2042 on top of main, as in the head1019 arm (merged upstream 2026-10-21)
  git -C Offline -c user.name=reco-profiling -c user.email=none merge -q --no-edit "$OFFLINE_MERGE"
  echo "  Offline + $OFFLINE_MERGE -> $(git -C Offline rev-parse --short HEAD)"
fi
if [ -n "$PATCH" ]; then
  git -C "$PATCH_REPO" apply "$HERE/rca/patches/$PATCH"
  echo "  applied rca/patches/$PATCH to $PATCH_REPO:"; git -C "$PATCH_REPO" --no-pager diff --stat
fi
echo
echo "Build (on a build node):"
echo "  cd $DIR && source /cvmfs/mu2e.opensciencegrid.org/setupmu2e-art.sh && setup muse && muse setup && muse build -j 32"
[ $KINKAL = 1 ] && echo "  bash $HERE/tools/build_kinkal_into_area.sh $DIR"
echo SETUP_AREA_DONE
