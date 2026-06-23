#!/bin/bash
#SBATCH --account=nems
#SBATCH --partition=u1-compute --qos=batch --nodes=1 --ntasks=1 --cpus-per-task=32 --mem=96G --time=03:00:00
#SBATCH --job-name=consol-tier12 --output=/scratch5/purged/Yi-cheng.Teng/tmp/logs/%x-%j.out
set -u
# §3 consolidation Tier-1/2: rebuild the CPU exes from the M2 source and confirm the CPU result is unchanged
#   (M2 is OpenMP-target-directive-only -> CPU build ignores it -> Tier-1 must be BIT-IDENTICAL to the committed
#    reference; Tier-2 -O2 within round-off). Reference (gpu_b2b_ref, KD=1.5e-5, 4x4x75, 48hr):
#      dic 1.5036917557803020e13  alk 1.6266596567821816e13  no3 1.1316293002204030e11
#      po4 7.5339387331740561e9   o2  1.6808058953017490e12
B=/scratch5/purged/Yi-cheng.Teng/tmp/cefi/builds
EXP=/scratch5/purged/Yi-cheng.Teng/tmp/cefi/exps/OM4.single_column.COBALT.b2b
NVHPC=/apps/spack-2024-12/linux-rocky9-x86_64/gcc-11.4.1/nvhpc-24.11-q3al5tofrsh5c7bcspobulw4rlagljjc/Linux_x86_64/24.11
STK=/scratch5/purged/Yi-cheng.Teng/tmp/stack/install
source /usr/share/lmod/lmod/init/bash 2>/dev/null; module load nvhpc/24.11 2>/dev/null
export PATH="$NVHPC/compilers/bin:$STK/netcdf-fortran/bin:$PATH"
export LD_LIBRARY_PATH="$NVHPC/compilers/lib:$STK/netcdf-fortran/lib:$STK/netcdf-c/lib:$STK/hdf5/lib:${LD_LIBRARY_PATH:-}"
export MAKEFLAGS="-j${SLURM_CPUS_PER_TASK:-16}"
date
echo "===== rebuild CPU exes from M2 source ====="
bash "$B/build_x86cpu_nompi.sh"    >/scratch5/purged/Yi-cheng.Teng/tmp/logs/consol_build_cpuO0.out 2>&1; echo "  Tier-1 (-O0) build rc=$?"
bash "$B/build_x86cpuO2_nompi.sh"  >/scratch5/purged/Yi-cheng.Teng/tmp/logs/consol_build_cpuO2.out 2>&1; echo "  Tier-2 (-O2) build rc=$?"
T1=$B/build/nvhpc-x86-cpu-nompi/ocean_ice/prod/MOM6SIS2
T2=$B/build/nvhpc-x86-cpuO2-nompi/ocean_ice/prod/MOM6SIS2
cd "$EXP"
for tag in tier1 tier2; do
  [ "$tag" = tier1 ] && E=$T1 || E=$T2
  rm -rf RESTART; mkdir -p RESTART; ln -sfn input.nml_48hr input.nml
  "$E" > "out.$tag" 2>&1; echo "  $tag exit=$?"
done
python3 - <<'PY'
import subprocess
ref={'dic':1.5036917557803020e13,'alk':1.6266596567821816e13,'no3':1.1316293002204030e11,
     'po4':7.5339387331740561e9,'o2':1.6808058953017490e12}
def val(tag,name):
    o=subprocess.run(f"grep 'Total {name}:' out.{tag}|tail -1|awk '{{print $3}}'",shell=True,capture_output=True,text=True).stdout.strip()
    try: return float(o.replace('E','e'))
    except: return float('nan')
for tag,crit in (('tier1','BIT-IDENTICAL (exact)'),('tier2','within round-off ~1e-15')):
    print(f"\n== {tag.upper()} ({crit}) vs committed reference ==")
    allok=True
    for k,r in ref.items():
        v=val(tag,k); rel=abs(v-r)/abs(r) if r else abs(v-r)
        ok = (rel==0.0) if tag=='tier1' else (rel<=1e-12)
        allok=allok and ok
        print(f"  {k:5s} {v:24.16e}  rel={rel:.2e}  {'OK' if ok else 'XX'}")
    print(f"  ===== {tag.upper()} VERDICT: {'PASS' if allok else 'FAIL'} =====")
PY
echo "==== DONE $(date) ===="
