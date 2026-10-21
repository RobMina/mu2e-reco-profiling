#!/bin/bash
# nearestindex_equiv.sh <fix-area> -- compile and run nearestindex_equiv.cc against <fix-area>/KinKal headers (header-only use;
# no KinKal or Offline library, so not a build). ROOT headers come from the environment of the built area AREA (env).
# No `set -u` (setupmu2e-art.sh).
FIX=${1:?usage: $0 <fix-area with the patched KinKal>}
HERE=$(cd "$(dirname "$0")" && pwd)
source "$(dirname "$0")/../env.sh"
BUILT=${AREA:?set AREA to a built muse area (for ROOT and the compiler)}
OUT=$RP_OUT/rca/nearestindex
source /cvmfs/mu2e.opensciencegrid.org/setupmu2e-art.sh >/dev/null 2>&1 || true
cd "$BUILT" && muse setup >/dev/null 2>&1 || true
AREA=$FIX
set -e
mkdir -p "$OUT"
echo "KinKal: $(git -C "$AREA/KinKal" rev-parse --short HEAD) $(git -C "$AREA/KinKal" diff --stat | tail -1)"
g++ -std=c++20 -O3 -Wall -Wextra -I"$AREA" -I"$(root-config --incdir)" "$HERE/nearestindex_equiv.cc" -o "$OUT/nearestindex_equiv"
"$OUT/nearestindex_equiv" | tee "$OUT/nearestindex_equiv.txt"
