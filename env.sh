# env.sh -- sourced by every script in this repository; sets the repository root and the output locations.
#   RP_HOME       this repository (derived from the location of env.sh)
#   RP_OUT        output root for interactive runs        (default /exp/mu2e/data/users/$USER/reco_profile)
#   RP_PNFS       output root for grid jobs (dCache)      (default /pnfs/mu2e/scratch/users/$USER/reco_profile)
#   RP_KPP_CALIB  directory with the KPP run-124155 calibration set (text-file payloads and strawResponse_pass1.fcl);
#                 needed only by the KPP data tests (A7, A8, E6); see fcl/kpp/README.md
# rp_paths prepends the repository fcl directories (and RP_KPP_CALIB) to the search paths; call it after `muse setup`.
RP_HOME=${RP_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}
RP_OUT=${RP_OUT:-/exp/mu2e/data/users/$USER/reco_profile}
RP_PNFS=${RP_PNFS:-/pnfs/mu2e/scratch/users/$USER/reco_profile}
rp_paths() {
  export FHICL_FILE_PATH="$RP_HOME/fcl:$RP_HOME/fcl/kpp${RP_KPP_CALIB:+:$RP_KPP_CALIB}:$FHICL_FILE_PATH"
  [ -n "$RP_KPP_CALIB" ] && export MU2E_SEARCH_PATH="$RP_KPP_CALIB:$MU2E_SEARCH_PATH"
  return 0
}
