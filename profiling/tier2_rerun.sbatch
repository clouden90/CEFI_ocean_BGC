#!/bin/bash
#SBATCH --account=nems
#SBATCH --partition=u1-compute --qos=batch --nodes=1 --ntasks=1 --cpus-per-task=16 --mem=64G --time=01:00:00
#SBATCH --job-name=tier2-rerun --output=/scratch5/purged/Yi-cheng.Teng/tmp/logs/%x-%j.out
set -u
# Tier-2 (-O2 CPU) CLEAN re-run: the first run aborted at init on an FMS field-table parse glitch
# (%CON extra close block). Re-run alone in a freshly-cleaned exp dir to distinguish a transient
# (NFS partial-read) from a reproducible -O2 FMS parser issue. Compare to the committed reference.
EXP=/scratch5/purged/Yi-cheng.Teng/tmp/cefi/exps/OM4.single_column.COBALT.b2b
T2=/scratch5/purged/Yi-cheng.Teng/tmp/cefi/builds/build/nvhpc-x86-cpuO2-nompi/ocean_ice/prod/MOM6SIS2
NVHPC=/apps/spack-2024-12/linux-rocky9-x86_64/gcc-11.4.1/nvhpc-24.11-q3al5tofrsh5c7bcspobulw4rlagljjc/Linux_x86_64/24.11
STK=/scratch5/purged/Yi-cheng.Teng/tmp/stack/install
source /usr/share/lmod/lmod/init/bash 2>/dev/null; module load nvhpc/24.11 2>/dev/null
export PATH="$NVHPC/compilers/bin:$STK/netcdf-fortran/bin:$PATH"
export LD_LIBRARY_PATH="$NVHPC/compilers/lib:$STK/netcdf-fortran/lib:$STK/netcdf-c/lib:$STK/hdf5/lib:${LD_LIBRARY_PATH:-}"
cd "$EXP"
date
echo "=== field_table integrity (md5 + line count + balanced /) ==="
md5sum field_table; wc -l field_table
echo "  open-brace lines: $(grep -c '/$' field_table 2>/dev/null)"
echo "=== clean exp state ==="
rm -rf RESTART; mkdir -p RESTART; rm -f _read_error.nml logfile*.out; ln -sfn input.nml_48hr input.nml
echo "=== Tier-2 (-O2) clean run ==="
"$T2" > out.tier2_rerun 2>&1; rc=$?; echo "  exit=$rc"
grep -iE 'FATAL|extra close block|NaN|imbalance' out.tier2_rerun | head -3 | sed 's/^/  STAB: /'
python3 - <<'PY'
import subprocess
ref={'dic':1.5036917557803020e13,'alk':1.6266596567821816e13,'no3':1.1316293002204030e11,
     'po4':7.5339387331740561e9,'o2':1.6808058953017490e12}
def val(name):
    o=subprocess.run(f"grep 'Total {name}:' out.tier2_rerun|tail -1|awk '{{print $3}}'",shell=True,capture_output=True,text=True).stdout.strip()
    try: return float(o.replace('E','e'))
    except: return float('nan')
print("== TIER-2 (-O2) re-run vs reference (within round-off ~1e-12) ==")
allok=True
for k,r in ref.items():
    v=val(k); rel=abs(v-r)/abs(r) if r else abs(v-r); ok=rel<=1e-12
    allok=allok and ok; print(f"  {k:5s} {v:24.16e}  rel={rel:.2e}  {'OK' if ok else 'XX'}")
print(f"  ===== TIER-2 VERDICT: {'PASS' if allok else 'FAIL/CRASH'} =====")
PY
echo "==== DONE $(date) ===="
