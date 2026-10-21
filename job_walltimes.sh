#!/bin/bash
# job_walltimes.sh [ARM] -- one line per reco_profile job dir: test and paired-baseline wall time, CPU model, stage times
# (from meta.txt, which the grid worker writes for the test and for base_<id>/).
source "$(dirname "$0")/env.sh"
D=$RP_OUT/${1:-kkmain}
printf '%-34s %8s %8s %6s %6s  %s\n' job test_s base_s stgin stgcd cpu
for d in "$D"/*/; do
  m=$d/meta.txt; [ -f "$m" ] || continue
  w=$(grep -o 'wall=[0-9]*' "$m" | tail -1 | cut -d= -f2)
  b=$(grep -h -o 'wall=[0-9]*' "$d"/base_*/meta.txt 2>/dev/null | tail -1 | cut -d= -f2)
  si=$(grep -o 'stage_input_s=[0-9]*' "$m" | head -1 | cut -d= -f2)
  sc=$(grep -o 'stage_code_s=[0-9]*' "$m" | head -1 | cut -d= -f2)
  cpu=$(grep -o 'cpu=[^n]*' "$m" | head -1 | sed 's/cpu= *//; s/(R)//g; s/ CPU.*//; s/ *$//')
  printf '%-34s %8s %8s %6s %6s  %s\n' "$(basename "$d")" "${w:--}" "${b:--}" "${si:--}" "${sc:--}" "$cpu"
done
