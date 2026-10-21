#!/bin/bash
# Standalone CMake-build the local KinKal in a muse area and install the libs into that area's
# Offline/lib with the spack soname convention, so the muse-built Offline loads the LOCAL KinKal at
# runtime with no relink. Run AFTER `muse build -j 32` has produced the area's Offline/lib.
#
# Version-derived (works for KinKal v3.7.0 and later). The libraries are installed with the spack soname
# convention (.0.0.0, NEEDED entries rewritten), with their rootmaps and pcms beside them.
#
# Usage: build_kinkal_into_area.sh <muse area with a KinKal checkout>
# Run on a build node (heavy compile).
# NB: no `set -u` -- setupmu2e-art.sh references unbound vars and would fatally exit the shell under it.
AREA=${1:?usage: build_kinkal_into_area.sh <area>}
# optional overrides (defaults = the area's own KinKal, build dir and Offline/lib): build another KinKal source into a side lib dir
SRC=${KINKAL_SRC:-$AREA/KinKal}
BLD=${KINKAL_BLD:-$AREA/kinkal_build}
source /cvmfs/mu2e.opensciencegrid.org/setupmu2e-art.sh >/dev/null 2>&1 || true
cd "$AREA" && muse setup >/dev/null 2>&1 || true
set -e
[ -d "$SRC" ] || { echo "ERROR: $SRC missing"; exit 1; }
echo "ROOTSYS=$ROOTSYS"
echo "KinKal: $(git -C "$SRC" rev-parse --short HEAD) $(git -C "$SRC" describe --tags 2>/dev/null) branch $(git -C "$SRC" rev-parse --abbrev-ref HEAD)"

# --- CMake build (matches production stack: cxxstd=20, Release) ---
rm -rf "$BLD"; mkdir -p "$BLD"; cd "$BLD"
cmake "$SRC" -DCMAKE_BUILD_TYPE=Release -DCMAKE_CXX_STANDARD=20 -G "Unix Makefiles" 2>&1 | tail -8
echo "=== compiling KinKal (heavy step) ==="
make -j 32 2>&1 | tail -15

# --- derive the built version from the produced Fit lib (e.g. 3.7.0) ---
FITLIB=$(ls "$BLD"/lib/libKinKal_Fit.so.*.*.* 2>/dev/null | head -1)
[ -n "$FITLIB" ] || { echo "ERROR: no libKinKal_Fit.so.X.Y.Z built"; exit 1; }
VER=$(basename "$FITLIB" | sed 's/^libKinKal_Fit\.so\.//')
echo "=== built KinKal libs, version $VER ==="
ls -la "$BLD"/lib/libKinKal_*.so."$VER"

# --- locate the area's Offline/lib (muse build must have run) ---
DST=$(ls -d "$AREA"/build/*/Offline/lib 2>/dev/null | head -1)
[ -n "$KINKAL_DST" ] && { mkdir -p "$KINKAL_DST"; DST=$KINKAL_DST; }
[ -n "$DST" ] && [ -d "$DST" ] || { echo "ERROR: $AREA/build/*/Offline/lib missing -- run 'muse build -j 32' first"; exit 1; }
echo "=== installing into $DST (soname -> 0.0.0) ==="

LIBS="General Trajectory Geometry Detector Fit MatEnv Examples"
SIBS="General Trajectory Geometry Detector MatEnv Examples"
# clean any prior local-KinKal install
for t in $LIBS; do rm -f "$DST/libKinKal_$t.so" "$DST/libKinKal_$t.so.0.0.0" "$DST"/libKinKal_$t.so.[0-9]*; done
for f in "$BLD"/lib/*.rootmap "$BLD"/lib/*_rdict.pcm; do [ -e "$f" ] && rm -f "$DST/$(basename "$f")"; done
# install each local lib as the spack-named .0.0.0, soname + NEEDED patched to .0.0.0
for t in $LIBS; do
  cp -f "$BLD/lib/libKinKal_$t.so.$VER" "$DST/libKinKal_$t.so.0.0.0"
  patchelf --set-soname "libKinKal_$t.so.0.0.0" "$DST/libKinKal_$t.so.0.0.0"
  for d in $SIBS; do
    patchelf --replace-needed "libKinKal_$d.so.$VER" "libKinKal_$d.so.0.0.0" "$DST/libKinKal_$t.so.0.0.0" 2>/dev/null || true
  done
  ln -sf "libKinKal_$t.so.0.0.0" "$DST/libKinKal_$t.so"
done
# rootmaps + pcms next to the libs (ROOT loads each dict's .pcm from the lib's own dir)
for f in "$BLD"/lib/*.rootmap "$BLD"/lib/*_rdict.pcm; do [ -e "$f" ] && cp -f "$f" "$DST/"; done

echo "=== verify (soname / kinkal NEEDED of Fit) ==="
readelf -d "$DST/libKinKal_Fit.so.0.0.0" | grep -iE "soname|needed" | grep -i kinkal
echo "INSTALL_KINKAL_DONE for $AREA"
