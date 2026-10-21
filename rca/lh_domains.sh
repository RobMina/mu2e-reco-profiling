#!/bin/bash
# lh_domains.sh [run|gdb|gdbseed|gdbhits] (env AREA=<built muse area>) -- reproduce A5 event 1430:3819:308303 (one LoopHelix seed fit -> ~157k B-field domains).
#   run: the off-spill MC reco (base_offspill_mc) on that event alone, KKUmu at PrintLevel 1, TimeTracker on (log.txt)
#   gdbhits: at each KKFit<LoopHelix>::range call, the straw-hit / xing time spread and outliers (gdbhits.txt)
#   gdb: break in Track<LoopHelix>::createDomains and print the seed range, start piece and the first domain steps
# Input I4 read in place from /pnfs. AREA: a built muse area at the baseline commits. One job per node. RCA_MODE, not MODE (setupmu2e-art.sh).
RCA_MODE=${1:-${RCA_MODE:-run}}
source "$(dirname "$0")/../env.sh"
AREA=${AREA:?set AREA to a built muse area}
HERE=$RP_HOME
OUT=$RP_OUT/rca/lh_domains
source /cvmfs/mu2e.opensciencegrid.org/setupmu2e-art.sh >/dev/null 2>&1
cd "$AREA" && muse setup >/dev/null 2>&1
[ "$MUSE_WORK_DIR" = "$AREA" ] || { echo "FATAL: muse setup did not take ($MUSE_WORK_DIR)"; exit 3; }
rp_paths
mkdir -p "$OUT" && cd "$OUT" || exit 2
IN=$(awk '$1=="I4"{print $2}' "$HERE/inputs.txt")
cat > job.fcl <<'EOF'
#include "base_offspill_mc.fcl"
#include "db_v1_5.fcl"
#include "prof_services.fcl"
services.TimeTracker.dbOutput.filename : ""
services.MemoryTracker.dbOutput.filename : ""
outputs.CentralHelixOutput.fileName : "/dev/null"
outputs.LoopHelixOutput.fileName : "/dev/null"
source.firstRun : 1430
source.firstSubRun : 3819
source.firstEvent : 308303
EOF
case "$RCA_MODE" in
  run)
    mu2e -c job.fcl -s "$IN" -n 1 > log.txt 2>&1
    echo "exit=$?"; grep -E "Begin processing|Events total|KKUmu|KKUe:|KKDe:" log.txt | head -12 ;;
  gdb)
    # createDomains is const: rdi=this, rsi=&ptraj, rdx=&range (begin,end), rcx=&domains. One line per call.
    cat > gdb.cmd <<'EOF2'
set pagination off
set breakpoint pending on
break _ZNK6KinKal5TrackINS_9LoopHelixEE13createDomainsERKNS_18ParticleTrajectoryIS1_EERKNS_9TimeRangeERSt3setISt10shared_ptrINS_6DomainEESt4lessISD_ESaISD_EE
commands
silent
printf "createDomains range=(%.4f, %.4f) span=%.3f ns\n", ((double*)$rdx)[0], ((double*)$rdx)[1], ((double*)$rdx)[1]-((double*)$rdx)[0]
continue
end
run
quit
EOF2
    gdb -q -batch -x gdb.cmd --args mu2e -c job.fcl -s "$IN" -n 1 > gdb.txt 2>&1
    echo "gdb exit=$?"; grep -E "^createDomains" gdb.txt | head -80 ;;
  gdbseed)
    # the seed of each KKUmu/KKDmu/... fit: LoopHelix params as makeSeedTraj returns (break at return of makeSeedTraj
    # is awkward under -O3; instead break in createDomains and read the seed piece's params from ptraj front piece)
    cat > gdbseed.py <<'EOF2'
import gdb
class DomBP(gdb.Breakpoint):
    def stop(self):
        try:
            rng = gdb.parse_and_eval("range")
            arr = rng["range_"]["_M_elems"]
            b = float(arr[0]); e = float(arr[1])
            pt = gdb.parse_and_eval("ptraj")
            dq = pt["pieces_"]
            first = dq["_M_impl"]["_M_start"]["_M_cur"].dereference()["_M_ptr"].dereference()
            p = first["pars_"]["fitdata_"]["vec_"]["fArray"]
            vals = [float(p[i]) for i in range(6)]
            mass = float(first["mass_"]); charge = int(first["charge_"])
            print(f"SEED span={e-b:.1f} rad={vals[0]:.2f} lam={vals[1]:.2f} cx={vals[2]:.2f} cy={vals[3]:.2f} phi0={vals[4]:.3f} t0={vals[5]:.2f} m={mass:.2f} q={charge}")
        except Exception as ex:
            print(f"SEED error {ex}")
        return False
DomBP("_ZNK6KinKal5TrackINS_9LoopHelixEE13createDomainsERKNS_18ParticleTrajectoryIS1_EERKNS_9TimeRangeERSt3setISt10shared_ptrINS_6DomainEESt4lessISD_ESaISD_EE", internal=False)
EOF2
    printf "set pagination off\nset breakpoint pending on\nsource gdbseed.py\nrun\nquit\n" > gdbseed.cmd
    gdb -q -batch -x gdbseed.cmd --args mu2e -c job.fcl -s "$IN" -n 1 > gdbseed.txt 2>&1
    echo "gdb exit=$?"; grep -E "^SEED" gdbseed.txt | head -40 ;;
  gdbhits)
    # Print every straw hit as KKFit<LoopHelix>::makeStrawHits creates it: break in the KKStrawHit constructor
    # (args: rdi=this, rsi=&kkbf, rdx=&pca, rcx=&combohit). PCA layout: ClosestApproach -> tpdata_ (ClosestApproachData):
    # read particleToca from the PCA via a gdb python helper using the debug type, and the hit's correctedTime.
    cat > gdbhits.py <<'EOF2'
import gdb
class HitBP(gdb.Breakpoint):
    def stop(self):
        try:
            pca = gdb.parse_and_eval("pca")
            ptoca = float(pca["tpdata_"]["partCA_"]["fCoordinates"]["fT"])
            stoca = float(pca["tpdata_"]["sensCA_"]["fCoordinates"]["fT"])
            st = int(pca["tpdata_"]["status_"])
            doca = float(pca["tpdata_"]["doca_"])
            ch = gdb.parse_and_eval("chit")
            ct = float(ch["_time"])
            pz = float(pca["tpdata_"]["partCA_"]["fCoordinates"]["fZ"])
            hz = float(ch["_pos"]["fCoordinates"]["fZ"])
            print(f"HIT ptoca={ptoca:.2f} stoca={stoca:.2f} doca={doca:.2f} status={st} chtime={ct:.2f} pocaz={pz:.1f} hitz={hz:.1f} dz={hz-pz:.1f}")
        except Exception as e:
            print(f"HIT error {e}")
        return False
HitBP("mu2e::KKStrawHit<KinKal::LoopHelix>::KKStrawHit", internal=False)
EOF2
    cat > gdbhits.cmd <<'EOF2'
set pagination off
set breakpoint pending on
source gdbhits.py
run
quit
EOF2
    gdb -q -batch -x gdbhits.cmd --args mu2e -c job.fcl -s "$IN" -n 1 > gdbhits.txt 2>&1
    echo "gdb exit=$?"; grep -c "^HIT ptoca" gdbhits.txt; grep -E "^HIT" gdbhits.txt | head -5
    grep -E "^HIT ptoca" gdbhits.txt | awk '{split($2,a,"="); split($6,c,"="); d=a[2]-c[2]; if(d<0)d=-d; if(d>1000) print}' | head -20 ;;
esac
