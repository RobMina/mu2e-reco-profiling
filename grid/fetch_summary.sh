#!/bin/bash
# fetch_summary.sh ARM SUFFIX ID... -- copy meta.txt and log.txt of <id><SUFFIX>/ from $RP_PNFS to $RP_OUT and print one line
# per job: exit code, wall time, art event summary, first exception line. SUFFIX e.g. _smoke, "" (art timing).
ARM=${1:?arm}; SUF=$2; shift 2
source "$(dirname "$0")/../env.sh"
P=$RP_PNFS/$ARM
T=$RP_OUT/$ARM
for id in "$@"; do
  d=$id$SUF; mkdir -p "$T/$d"
  for f in meta.txt log.txt; do timeout 60 ifdh cp "$P/$d/$f" "$T/$d/$f" >/dev/null 2>&1; done
  if [ ! -s "$T/$d/meta.txt" ]; then printf '%-22s not finished (no meta.txt)\n' "$d"; continue; fi
  ex=$(grep -o 'exit=[0-9]* wall=[0-9]*s' "$T/$d/meta.txt" | tail -1)
  ev=$(grep -m1 'TrigReport Events total' "$T/$d/log.txt" 2>/dev/null | sed 's/TrigReport //')
  er=$(grep -m1 -E -- '---- .* BEGIN|Exception|unsupported|Missing parameter' "$T/$d/log.txt" 2>/dev/null | cut -c1-100)
  printf '%-22s %-20s %-40s %s\n' "$d" "${ex:-meta without exit}" "$ev" "$er"
done
