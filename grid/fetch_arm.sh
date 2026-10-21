#!/bin/bash
# fetch_arm.sh ARM -- copy every job's results of an arm from $RP_PNFS to $RP_OUT (env.sh)
# ($RP_PNFS/<ARM>/<id>[/base_<bid>]/ -> $RP_OUT/<ARM>/...), skipping .art and staged inputs.
# Reads the pnfs mount directly (cp, not ifdh): fine for these KB-MB summaries and callgrind dumps.
ARM=${1:?arm}
source "$(dirname "$0")/../env.sh"
P=$RP_PNFS/$ARM
T=$RP_OUT/$ARM
mkdir -p "$T" || exit 1
n=0
for d in "$P"/*/; do
  id=$(basename "$d"); case "$id" in aux) continue ;; esac
  for sub in "$d" "$d"base_*/; do
    [ -d "$sub" ] || continue
    rel=${sub#"$P"/}; mkdir -p "$T/$rel"
    for f in "$sub"*; do
      [ -f "$f" ] || continue
      case "$f" in *.art) continue ;; esac
      cp -p "$f" "$T/$rel" && n=$((n+1))
    done
  done
done
echo "copied $n files to $T ($(du -sh "$T" | cut -f1))"
